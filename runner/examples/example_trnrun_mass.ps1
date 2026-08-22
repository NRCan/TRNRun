<#
.SYNOPSIS
    Stress test trnrun.exe by running N copies of a single .dck file.

.EXAMPLE
    .\run_stress.ps1
    .\run_stress.ps1 -Copies 1000 -MaxConcurrent 50
    .\run_stress.ps1 -Copies 1000 -MaxConcurrent 0 -Force   # all at once, no prompt
#>
param(
    [int]$Copies = 50,
    [int]$MaxConcurrent = 0,     # 0 = unlimited (launch everything at once)
    [switch]$CleanCopies,         # delete the stress\ folder when finished
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ---- Paths ---------------------------------------------------------------------
$RepoRoot  = Join-Path $PSScriptRoot ".."
$ExePath   = Join-Path $RepoRoot "build\trnrun.exe"
$SourceDck = Join-Path $PSScriptRoot "dck\example_wo_plot_w_tracking.dck"

# Staging dir is a SIBLING of dck\ so that relative ASSIGN paths inside the deck
# resolve to exactly the same locations as they do for the original file.
$StageDir  = Join-Path $PSScriptRoot "stress"

# ---- Fixed parameter values (same for every run) -------------------------------
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

# ---- Exit-code meaning ---------------------------------------------------------
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

function Format-ArgValue {
    param($Value)
    if ($Value -is [bool]) { if ($Value) { "true" } else { "false" } }
    else { "$Value" }
}

# ---- Validate ------------------------------------------------------------------

if (-not (Test-Path $ExePath)) {
    Write-Host "ERROR: Executable not found at $ExePath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $SourceDck)) {
    Write-Host "ERROR: Source dck file not found at $SourceDck" -ForegroundColor Red
    exit 1
}

if ($Copies -lt 1) {
    Write-Host "ERROR: -Copies must be at least 1" -ForegroundColor Red
    exit 1
}

$effectiveConcurrency = if ($MaxConcurrent -le 0) { $Copies } else { [Math]::Min($MaxConcurrent, $Copies) }

Write-Host ""
Write-Host "Source deck     : $SourceDck"       -ForegroundColor Cyan
Write-Host "Copies          : $Copies"          -ForegroundColor Cyan
Write-Host "Max concurrent  : $effectiveConcurrency" -ForegroundColor Cyan
Write-Host "Staging folder  : $StageDir"        -ForegroundColor Cyan

# ---- Safety gate ---------------------------------------------------------------

if (-not $Force -and $effectiveConcurrency -gt 100) {
    $resp = Read-Host "This will keep up to $effectiveConcurrency simulations running at once. Continue? (y/n)"
    if ($resp -ne "y") { Write-Host "Aborted."; return }
}

# ---- Stage the copies ----------------------------------------------------------

if (Test-Path $StageDir) {
    if (-not $Force) {
        $resp = Read-Host "Staging folder already exists and will be deleted: $StageDir. Continue? (y/n)"
        if ($resp -ne "y") { Write-Host "Aborted."; return }
    }
    Remove-Item $StageDir -Recurse -Force
}

New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

$baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourceDck)
$pad      = ([string]$Copies).Length

Write-Host ""
Write-Host "Creating $Copies copies of $baseName.dck ..." -ForegroundColor Cyan

$DckFiles = New-Object System.Collections.Generic.List[string]

for ($i = 1; $i -le $Copies; $i++) {
    $name = "{0}_{1}.dck" -f $baseName, ($i.ToString().PadLeft($pad, '0'))
    $dest = Join-Path $StageDir $name
    Copy-Item -LiteralPath $SourceDck -Destination $dest -Force
    $DckFiles.Add($dest)
}

Write-Host "Copies ready." -ForegroundColor Green

# ---- Setup results log ---------------------------------------------------------

$ResultsDir = Join-Path $PSScriptRoot "results"
if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

$ResultsFile = Join-Path $ResultsDir "stress_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

$ParamCsv = ($Keys | ForEach-Object { Format-ArgValue $Params[$_] }) -join ","

$writer = New-Object System.IO.StreamWriter($ResultsFile, $false, (New-Object System.Text.UTF8Encoding($false)))
$writer.AutoFlush = $true
$writer.WriteLine("Index,DckFile," + ($Keys -join ",") + ",ExitCode,Meaning,DurationSec,StartTime")

# ---- Build common arguments ----------------------------------------------------

$cliArgsBase = $Keys | ForEach-Object { "--$_=$(Format-ArgValue $Params[$_])" }

# ---- Launch with throttling ----------------------------------------------------

$runStart  = Get-Date
$queue     = New-Object System.Collections.Generic.Queue[object]
$running   = New-Object System.Collections.Generic.List[object]
$durations = New-Object System.Collections.Generic.List[double]
$tally     = @{}

$index = 0
foreach ($dck in $DckFiles) {
    $index++
    $queue.Enqueue([PSCustomObject]@{ Index = $index; Dck = $dck })
}

$launched  = 0
$completed = 0
$failures  = 0

try {
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {

        # --- fill the slots ---
        while ($queue.Count -gt 0 -and $running.Count -lt $effectiveConcurrency) {

            $item    = $queue.Dequeue()
            $cliArgs = @("--deckFile=$($item.Dck)") + $cliArgsBase

            $proc = Start-Process -FilePath $ExePath -ArgumentList $cliArgs -PassThru

            $running.Add([PSCustomObject]@{
                Index = $item.Index
                Name  = [System.IO.Path]::GetFileNameWithoutExtension($item.Dck)
                Dck   = $item.Dck
                Start = Get-Date
                Proc  = $proc
            })

            $launched++
        }

        Start-Sleep -Milliseconds 200

        # --- reap the finished ones (iterate backwards; we remove as we go) ---
        for ($i = $running.Count - 1; $i -ge 0; $i--) {

            $run = $running[$i]
            if (-not $run.Proc.HasExited) { continue }

            $running.RemoveAt($i)
            $completed++

            $duration = (Get-Date) - $run.Start
            $seconds  = [math]::Round($duration.TotalSeconds, 1)
            $exitCode = $run.Proc.ExitCode
            $durations.Add($duration.TotalSeconds)

            $meaning = if ($ExitCodeMeaning.ContainsKey($exitCode)) {
                $ExitCodeMeaning[$exitCode]
            } else {
                "Unknown($exitCode)"
            }

            if ($tally.ContainsKey($meaning)) { $tally[$meaning]++ } else { $tally[$meaning] = 1 }

            if ($exitCode -ne 0) {
                $failures++
                Write-Host "[$completed/$Copies] $($run.Name): FAIL ($exitCode - $meaning)" -ForegroundColor Red
            }

            $writer.WriteLine(
                "$($run.Index),$($run.Name),$ParamCsv,$exitCode,$meaning,$seconds,$($run.Start.ToString('s'))"
            )

            $run.Proc.Dispose()
        }

        # --- progress line ---
        if ($completed -gt 0 -and ($completed % 25 -eq 0 -or $completed -eq $Copies)) {
            Write-Host ("Progress: {0}/{1} done, {2} failed, {3} running, {4} queued" -f `
                $completed, $Copies, $failures, $running.Count, $queue.Count) -ForegroundColor DarkGray
        }
    }
}
finally {
    # If the script is interrupted, don't leave orphans behind.
    foreach ($run in $running) {
        if (-not $run.Proc.HasExited) {
            Write-Host "Killing leftover process $($run.Name) (PID $($run.Proc.Id))" -ForegroundColor Yellow
            try { $run.Proc.Kill() } catch { }
        }
    }
    $writer.Close()
}

# ---- Summary -------------------------------------------------------------------

$elapsed = (Get-Date) - $runStart

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host "Launched : $launched" -ForegroundColor Yellow
Write-Host "Completed: $completed   Failures: $failures" -ForegroundColor Yellow
Write-Host "Elapsed  : $($elapsed.ToString())" -ForegroundColor Yellow

if ($durations.Count -gt 0) {
    $stats = $durations | Measure-Object -Minimum -Maximum -Average
    Write-Host ("Duration : min {0}s / avg {1}s / max {2}s" -f `
        [math]::Round($stats.Minimum,1), [math]::Round($stats.Average,1), [math]::Round($stats.Maximum,1)) -ForegroundColor Yellow
}

Write-Host "Exit codes:" -ForegroundColor Yellow
foreach ($k in ($tally.Keys | Sort-Object)) {
    Write-Host ("  {0,-16} {1}" -f $k, $tally[$k]) -ForegroundColor Yellow
}

Write-Host "Results saved to: $ResultsFile" -ForegroundColor Yellow
Write-Host "==================================================================" -ForegroundColor Yellow

# ---- Optional cleanup ----------------------------------------------------------

if ($CleanCopies) {
    Write-Host "Removing staging folder: $StageDir" -ForegroundColor DarkGray
    Remove-Item $StageDir -Recurse -Force
}
