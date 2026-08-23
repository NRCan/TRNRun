param(
    [int64]$StartAt = 0,
    [switch]$Force
)

# Paths
$RunnerRoot = Join-Path $PSScriptRoot '..'
$ExecutablePath = Join-Path $RunnerRoot 'build\trnrun.exe'

# Decks
$DeckFiles = @(
    (Join-Path $RunnerRoot 'tests\dck\test_wo_plot_wo_tracking.dck')
    (Join-Path $RunnerRoot 'tests\dck\test_wo_plot_w_tracking.dck')
    (Join-Path $RunnerRoot 'tests\dck\test_w_plot_wo_tracking.dck')
    (Join-Path $RunnerRoot 'tests\dck\test_w_plot_w_tracking.dck')
)

# Parameter matrix
$ParameterValues = [ordered]@{
    guiVisibility = @('hidden')
    waitForGui = @($true)
    waitForLst = @($true)
    waitForTmp = @($true, $false)
    detectTimeout = @(0)
    extraDelay = @(0)
    watchLog = @($true, $false)
    watchTmp = @($true, $false)
    watchTimeout = @(0)
    stallTimeout = @(0)
    pollMs = @(10)
    clean = @($false)
    killOnTimeout = @($true, $false)
    killOnStall = @($true, $false)
    severity = @('Notice')
    writeEvents = @($false)
}

# Exit-code meanings reported by trnrun
$ExitCodeMeanings = @{
    0 = 'Done'
    1 = 'Fatal'
    2 = 'User Error'
    124 = 'Timeout'
    125 = 'Stalled'
    130 = 'Cancelled'
}

$ParameterNames = @($ParameterValues.Keys)
[int64]$TotalParameterCombinations = 1
foreach ($ParameterName in $ParameterNames) {
    $TotalParameterCombinations *=
        [int64]$ParameterValues[$ParameterName].Count
}

$DeckFiles = $DeckFiles | Where-Object {
    if (Test-Path $_) {
        $true
    } else {
        Write-Host `
            "WARNING: dck file not found, skipping: $_" `
            -ForegroundColor Yellow
        $false
    }
}
[int64]$TotalRuns = $TotalParameterCombinations * $DeckFiles.Count

function Format-ArgValue {
    param($Value)

    if ($Value -is [bool]) {
        if ($Value) {
            'true'
        } else {
            'false'
        }
    } else {
        "$Value"
    }
}

# Decode a zero-based combination index through the parameter matrix.
function Get-CombinationFromIndex {
    param([int64]$Index)

    $Combination = [ordered]@{}
    $RemainingIndex = $Index
    foreach ($ParameterName in $ParameterNames) {
        $ValueCount = $ParameterValues[$ParameterName].Count
        $ValueIndex = [int]($RemainingIndex % $ValueCount)
        $Combination[$ParameterName] =
            $ParameterValues[$ParameterName][$ValueIndex]
        $RemainingIndex =
            [int64]([math]::Floor($RemainingIndex / $ValueCount))
    }
    return $Combination
}

Write-Host "Total parameter combinations: $TotalParameterCombinations" `
    -ForegroundColor Cyan
Write-Host "Deck files:                   $($DeckFiles.Count)" `
    -ForegroundColor Cyan
Write-Host "Total runs:                   $TotalRuns" `
    -ForegroundColor Cyan

# Safety gate
if (-not $Force -and $TotalRuns -gt 500) {
    $Response = Read-Host `
        "This will launch $TotalRuns simulation runs sequentially. Continue? (y/n)"
    if ($Response -ne 'y') {
        Write-Host 'Aborted.'
        return
    }
}

if (-not (Test-Path $ExecutablePath)) {
    Write-Host `
        "ERROR: Executable not found at $ExecutablePath" `
        -ForegroundColor Red
    exit 1
}

# Results log
$ResultsDirectory = Join-Path $PSScriptRoot 'results'
if (-not (Test-Path $ResultsDirectory)) {
    New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
}
$ResultsFile = Join-Path `
    $ResultsDirectory `
    "test_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
(
    'DckFile,ComboIndex,' +
    ($ParameterNames -join ',') +
    ',ExitCode,Meaning,DurationSec,StartTime'
) | Out-File -FilePath $ResultsFile -Encoding UTF8

$RunOrdinal = 0
$FailureCount = 0
$BatchStartedAt = Get-Date

foreach ($DeckFile in $DeckFiles) {
    $DeckName = [System.IO.Path]::GetFileNameWithoutExtension($DeckFile)

    for (
        $CombinationIndex = 0
        $CombinationIndex -lt $TotalParameterCombinations
        $CombinationIndex++
    ) {
        $RunOrdinal++
        if ($RunOrdinal -le $StartAt) {
            continue # Resume support counts candidates across all decks.
        }

        $Combination = Get-CombinationFromIndex -Index $CombinationIndex
        $CliArguments = @("--deckFile=$DeckFile") +
            ($ParameterNames | ForEach-Object {
                "--$_=$(Format-ArgValue $Combination[$_])"
            })
        $ArgumentsDisplay = $CliArguments -join ' '

        Write-Host ''
        Write-Host '==================================================================' `
            -ForegroundColor Cyan
        $PercentComplete = [math]::Round(
            100 * $RunOrdinal / $TotalRuns,
            2
        )
        Write-Host `
            "[$RunOrdinal/$TotalRuns ($PercentComplete%)] dck=$DeckName combo=$CombinationIndex" `
            -ForegroundColor Cyan
        Write-Host $ArgumentsDisplay -ForegroundColor DarkGray
        Write-Host '==================================================================' `
            -ForegroundColor Cyan

        $StartedAt = Get-Date
        $Process = Start-Process `
            -FilePath $ExecutablePath `
            -ArgumentList $CliArguments `
            -NoNewWindow `
            -Wait `
            -PassThru
        $Duration = (Get-Date) - $StartedAt
        $ExitCode = $Process.ExitCode
        $ExitMeaning = if ($ExitCodeMeanings.ContainsKey($ExitCode)) {
            $ExitCodeMeanings[$ExitCode]
        } else {
            "Unknown($ExitCode)"
        }

        if ($ExitCode -eq 0) {
            Write-Host `
                "-> Exit code: $ExitCode ($ExitMeaning)  Duration: $([math]::Round($Duration.TotalSeconds,1))s" `
                -ForegroundColor Green
        } else {
            Write-Host `
                "-> Exit code: $ExitCode ($ExitMeaning)  Duration: $([math]::Round($Duration.TotalSeconds,1))s" `
                -ForegroundColor Red
            $FailureCount++
        }

        $CsvRow =
            "$DeckName,$CombinationIndex," +
            (($ParameterNames | ForEach-Object {
                Format-ArgValue $Combination[$_]
            }) -join ',') +
            ",$ExitCode,$ExitMeaning,$([math]::Round($Duration.TotalSeconds,1)),$StartedAt"
        $CsvRow | Out-File -FilePath $ResultsFile -Append -Encoding UTF8
    }
}

$Elapsed = (Get-Date) - $BatchStartedAt
Write-Host ''
Write-Host '==================================================================' -ForegroundColor Yellow
Write-Host `
    "All runs complete: $RunOrdinal run(s), $FailureCount failure(s). Elapsed: $($Elapsed.ToString())" `
    -ForegroundColor Yellow
Write-Host "Results saved to: $ResultsFile" -ForegroundColor Yellow
Write-Host '==================================================================' -ForegroundColor Yellow
