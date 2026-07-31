param(
    [int64]$StartAt = 0,
    [switch]$Force
)

# ---- Path to the compiled CLI -------------------------------------------------
$RepoRoot = Join-Path $PSScriptRoot ".."
$ExePath = Join-Path $RepoRoot "build\trnrun.exe"

# ---- Deck files to test --------------------------------------------------------
$DckFiles = @(
    (Join-Path $RepoRoot "tests\dck\test_wo_plot_wo_tracking.dck"),
    (Join-Path $RepoRoot "tests\dck\test_wo_plot_w_tracking.dck"),
    (Join-Path $RepoRoot "tests\dck\test_w_plot_wo_tracking.dck"),
    (Join-Path $RepoRoot "tests\dck\test_w_plot_w_tracking.dck")
)

# ---- Parameter value sets -------------------------------------------------------
$ParamValues = [ordered]@{
    guiVisibility  = @("hidden")
    waitForGui     = @($true)
    waitForLst     = @($true)
    waitForTmp     = @($true, $false)
    detectTimeout  = @(0)
    extraDelay     = @(0)
    watchLog       = @($true, $false)
    watchTmp       = @($true, $false)
    watchTimeout   = @(0)
    stallTimeout   = @(0)
    pollMs         = @(10)
    clean          = @($false)
    killOnTimeout  = @($true, $false)
    killOnStall    = @($true, $false)
    severity       = @("Notice")
    writeLog       = @($false)
}

# ---- Exit-code meaning (mirrors exitCode() in main.nim) ------------------------
$ExitCodeMeaning = @{
    0   = "Done"
    1   = "Fatal"
    2   = "User Error"
    124 = "Timeout"
    125 = "Stalled"
    130 = "Cancelled"
}

# =================================================================================
# Combinatorics engine — no need to edit below this line
# =================================================================================

$Keys = @($ParamValues.Keys)
[int64]$TotalParamCombos = 1
foreach ($k in $Keys) { $TotalParamCombos *= [int64]$ParamValues[$k].Count }

$DckFiles = $DckFiles | Where-Object {
    if (Test-Path $_) { $true } else { Write-Host "WARNING: dck file not found, skipping: $_" -ForegroundColor Yellow; $false }
}
[int64]$TotalRuns = $TotalParamCombos * $DckFiles.Count

function Format-ArgValue {
    param($Value)
    if ($Value -is [bool]) { if ($Value) { "true" } else { "false" } } else { "$Value" }
}

# Decode a combo index (0-based) into a parameter hashtable via mixed-radix.
function Get-ComboFromIndex {
    param([int64]$Index)
    $combo = [ordered]@{}
    $remaining = $Index
    foreach ($key in $Keys) {
        $size = $ParamValues[$key].Count
        $valIndex = [int]($remaining % $size)
        $combo[$key] = $ParamValues[$key][$valIndex]
        $remaining = [int64]([math]::Floor($remaining / $size))
    }
    return $combo
}

Write-Host "Total parameter combinations: $TotalParamCombos" -ForegroundColor Cyan
Write-Host "Deck files:                   $($DckFiles.Count)" -ForegroundColor Cyan
Write-Host "Total runs:                   $TotalRuns" -ForegroundColor Cyan

# ---- Safety gate before launching potentially huge numbers of processes ---------
if (-not $Force -and $TotalRuns -gt 500) {
    $resp = Read-Host "This will launch $TotalRuns simulation runs sequentially. Continue? (y/n)"
    if ($resp -ne "y") { Write-Host "Aborted."; return }
}

if (-not (Test-Path $ExePath)) {
    Write-Host "ERROR: Executable not found at $ExePath" -ForegroundColor Red
    exit 1
}

# ---- Setup results log -----------------------------------------------------------
$ResultsDir = Join-Path $PSScriptRoot "results"
if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}
$ResultsFile = Join-Path $ResultsDir "test_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
("DckFile,ComboIndex," + ($Keys -join ",") + ",ExitCode,Meaning,DurationSec,StartTime") |
    Out-File -FilePath $ResultsFile -Encoding UTF8

$count = 0
$failures = 0
$runStart = Get-Date

foreach ($dck in $DckFiles) {
    $dckName = [System.IO.Path]::GetFileNameWithoutExtension($dck)

    for ($ci = 0; $ci -lt $TotalParamCombos; $ci++) {
        $count++
        if ($count -le $StartAt) { continue }  # resume support

        $combo = Get-ComboFromIndex -Index $ci
        $cliArgs = @("--deckFile=$dck") + ($Keys | ForEach-Object { "--$_=$(Format-ArgValue $combo[$_])" })
        $argsDisplay = $cliArgs -join " "

        Write-Host ""
        Write-Host "==================================================================" -ForegroundColor Cyan
        $pct = [math]::Round(100 * $count / $TotalRuns, 2)
        Write-Host "[$count/$TotalRuns ($pct%)] dck=$dckName combo=$ci" -ForegroundColor Cyan
        Write-Host $argsDisplay -ForegroundColor DarkGray
        Write-Host "==================================================================" -ForegroundColor Cyan

        $start = Get-Date
        $proc = Start-Process -FilePath $ExePath -ArgumentList $cliArgs -NoNewWindow -Wait -PassThru
        $duration = (Get-Date) - $start
        $exitCode = $proc.ExitCode
        $meaning = if ($ExitCodeMeaning.ContainsKey($exitCode)) { $ExitCodeMeaning[$exitCode] } else { "Unknown($exitCode)" }

        if ($exitCode -eq 0) {
            Write-Host "-> Exit code: $exitCode ($meaning)  Duration: $([math]::Round($duration.TotalSeconds,1))s" -ForegroundColor Green
        } else {
            Write-Host "-> Exit code: $exitCode ($meaning)  Duration: $([math]::Round($duration.TotalSeconds,1))s" -ForegroundColor Red
            $failures++
        }

        $row = "$dckName,$ci," + (($Keys | ForEach-Object { Format-ArgValue $combo[$_] }) -join ",") + ",$exitCode,$meaning,$([math]::Round($duration.TotalSeconds,1)),$start"
        $row | Out-File -FilePath $ResultsFile -Append -Encoding UTF8
    }
}

$elapsed = (Get-Date) - $runStart
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host "All runs complete: $count run(s), $failures failure(s). Elapsed: $($elapsed.ToString())" -ForegroundColor Yellow
Write-Host "Results saved to: $ResultsFile" -ForegroundColor Yellow
Write-Host "==================================================================" -ForegroundColor Yellow
