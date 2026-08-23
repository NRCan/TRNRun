param(
    [switch]$Force
)

# Paths
$RunnerRoot = Join-Path $PSScriptRoot '..'
$ExecutablePath = Join-Path $RunnerRoot 'build\trnrun.exe'

# Decks
$DeckFiles = @(
    (Join-Path $PSScriptRoot 'dck\example_wo_plot_wo_tracking.dck')
    (Join-Path $PSScriptRoot 'dck\example_wo_plot_w_tracking.dck')
    (Join-Path $PSScriptRoot 'dck\example_w_plot_wo_tracking.dck')
    (Join-Path $PSScriptRoot 'dck\example_w_plot_w_tracking.dck')
)

# CLI options
$CliOptions = [ordered]@{
    guiVisibility = 'auto'
    waitForGui = $true
    waitForLst = $true
    waitForTmp = $false
    detectTimeout = 0
    extraDelay = 0
    watchLog = $true
    watchTmp = $true
    watchTimeout = 0
    stallTimeout = 0
    pollMs = 100
    clean = $false
    killOnTimeout = $true
    killOnStall = $true
    severity = 'Notice'
    writeEvents = $true
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

$CliOptionNames = @($CliOptions.Keys)

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

# Validate deck files
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
[int]$TotalRuns = $DeckFiles.Count

Write-Host "Deck files: $($DeckFiles.Count)" -ForegroundColor Cyan
Write-Host "Total runs: $TotalRuns" -ForegroundColor Cyan

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
    "example_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
(
    'DckFile,' +
    ($CliOptionNames -join ',') +
    ',ExitCode,Meaning,DurationSec,StartTime'
) | Out-File -FilePath $ResultsFile -Encoding UTF8

$RunNumber = 0
$FailureCount = 0
$BatchStartedAt = Get-Date
$BaseArguments = $CliOptionNames | ForEach-Object {
    "--$_=$(Format-ArgValue $CliOptions[$_])"
}

foreach ($DeckFile in $DeckFiles) {
    $RunNumber++
    $DeckName = [System.IO.Path]::GetFileNameWithoutExtension($DeckFile)

    $CliArguments = @("--deckFile=$DeckFile") + $BaseArguments
    $ArgumentsDisplay = $CliArguments -join ' '

    Write-Host ''
    Write-Host '==================================================================' `
        -ForegroundColor Cyan
    Write-Host "[$RunNumber/$TotalRuns] dck=$DeckName" -ForegroundColor Cyan
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
        "$DeckName," +
        (($CliOptionNames | ForEach-Object {
            Format-ArgValue $CliOptions[$_]
        }) -join ',') +
        ",$ExitCode,$ExitMeaning,$([math]::Round($Duration.TotalSeconds,1)),$StartedAt"
    $CsvRow | Out-File -FilePath $ResultsFile -Append -Encoding UTF8
}

$Elapsed = (Get-Date) - $BatchStartedAt
Write-Host ''
Write-Host '==================================================================' -ForegroundColor Yellow
Write-Host `
    "All runs complete: $RunNumber run(s), $FailureCount failure(s). Elapsed: $($Elapsed.ToString())" `
    -ForegroundColor Yellow
Write-Host "Results saved to: $ResultsFile" -ForegroundColor Yellow
Write-Host '==================================================================' -ForegroundColor Yellow
