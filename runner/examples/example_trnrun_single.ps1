param(
    [switch]$Force
)

# ---- Path to the compiled CLI -------------------------------------------------
$RepoRoot = Join-Path $PSScriptRoot ".."
$ExePath = Join-Path $RepoRoot "build\trnrun.exe"

# ---- Deck files to test --------------------------------------------------------
$DckFiles = @(
    (Join-Path $PSScriptRoot "dck\example_wo_plot_wo_tracking.dck"),
    (Join-Path $PSScriptRoot "dck\example_wo_plot_w_tracking.dck"),
    (Join-Path $PSScriptRoot "dck\example_w_plot_wo_tracking.dck"),
    (Join-Path $PSScriptRoot "dck\example_w_plot_w_tracking.dck")
)

# ---- Fixed parameter values (same for every dck file) --------------------------
$Params = [ordered]@{
    guiVisibility  = "Auto"
    waitForGui     = $true
    waitForLst     = $true
    waitForTmp     = $false
    detectTimeout  = 0
    extraDelay     = 0
    watchLog       = $true
    watchTmp       = $true
    watchTimeout   = 0
    stallTimeout   = 0
    pollMs         = 100
    clean          = $false
    killOnTimeout  = $true
    killOnStall    = $true
    severity       = "Notice"
    writeEvents    = $true
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
# No need to edit below this line
# =================================================================================

$Keys = @($Params.Keys)

$DckFiles = $DckFiles | Where-Object {
    if (Test-Path $_) { $true } else { Write-Host "WARNING: dck file not found, skipping: $_" -ForegroundColor Yellow; $false }
}
[int]$TotalRuns = $DckFiles.Count

function Format-ArgValue {
    param($Value)
    if ($Value -is [bool]) { if ($Value) { "true" } else { "false" } } else { "$Value" }
}

Write-Host "Deck files: $($DckFiles.Count)" -ForegroundColor Cyan
Write-Host "Total runs: $TotalRuns" -ForegroundColor Cyan

# ---- Safety gate (harmless here since this is only ever 4 runs, kept for parity) -
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
$ResultsFile = Join-Path $ResultsDir "example_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
("DckFile," + ($Keys -join ",") + ",ExitCode,Meaning,DurationSec,StartTime") |
    Out-File -FilePath $ResultsFile -Encoding UTF8

$count = 0
$failures = 0
$runStart = Get-Date

$cliArgsBase = $Keys | ForEach-Object { "--$_=$(Format-ArgValue $Params[$_])" }

foreach ($dck in $DckFiles) {
    $count++
    $dckName = [System.IO.Path]::GetFileNameWithoutExtension($dck)

    $cliArgs = @("--deckFile=$dck") + $cliArgsBase
    $argsDisplay = $cliArgs -join " "

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "[$count/$TotalRuns] dck=$dckName" -ForegroundColor Cyan
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

    $row = "$dckName," + (($Keys | ForEach-Object { Format-ArgValue $Params[$_] }) -join ",") + ",$exitCode,$meaning,$([math]::Round($duration.TotalSeconds,1)),$start"
    $row | Out-File -FilePath $ResultsFile -Append -Encoding UTF8
}

$elapsed = (Get-Date) - $runStart
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host "All runs complete: $count run(s), $failures failure(s). Elapsed: $($elapsed.ToString())" -ForegroundColor Yellow
Write-Host "Results saved to: $ResultsFile" -ForegroundColor Yellow
Write-Host "==================================================================" -ForegroundColor Yellow
