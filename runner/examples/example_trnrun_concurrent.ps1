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
    guiVisibility  = "Hidden"
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
    writeLog       = $true
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

    if ($Value -is [bool]) {
        if ($Value) { "true" } else { "false" }
    }
    else {
        "$Value"
    }
}

# ---- Validate deck files -------------------------------------------------------

$DckFiles = $DckFiles | Where-Object {
    if (Test-Path $_) {
        $true
    }
    else {
        Write-Host "WARNING: dck file not found, skipping: $_" -ForegroundColor Yellow
        $false
    }
}

[int]$TotalRuns = $DckFiles.Count

Write-Host "Deck files: $TotalRuns" -ForegroundColor Cyan
Write-Host "Concurrent runs: $TotalRuns" -ForegroundColor Cyan


# ---- Safety gate ---------------------------------------------------------------

if (-not $Force -and $TotalRuns -gt 500) {
    $resp = Read-Host "This will launch $TotalRuns simulation runs concurrently. Continue? (y/n)"

    if ($resp -ne "y") {
        Write-Host "Aborted."
        return
    }
}


# ---- Check executable ----------------------------------------------------------

if (-not (Test-Path $ExePath)) {
    Write-Host "ERROR: Executable not found at $ExePath" -ForegroundColor Red
    exit 1
}


# ---- Setup results log ----------------------------------------------------------

$ResultsDir = Join-Path $PSScriptRoot "results"

if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

$ResultsFile = Join-Path $ResultsDir "example_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

(
    "DckFile," +
    ($Keys -join ",") +
    ",ExitCode,Meaning,DurationSec,StartTime"
) | Out-File -FilePath $ResultsFile -Encoding UTF8


# ---- Build common arguments ----------------------------------------------------

$cliArgsBase = $Keys | ForEach-Object {
    "--$_=$(Format-ArgValue $Params[$_])"
}


# ---- Launch simulations --------------------------------------------------------

$runStart = Get-Date
$Processes = @()

$count = 0

foreach ($dck in $DckFiles) {

    $count++

    $dckName = [System.IO.Path]::GetFileNameWithoutExtension($dck)

    $cliArgs = @("--deckFile=$dck") + $cliArgsBase

    Write-Host ""
    Write-Host "Launching [$count/$TotalRuns] $dckName" -ForegroundColor Cyan
    Write-Host ($cliArgs -join " ") -ForegroundColor DarkGray


    $start = Get-Date

    $proc = Start-Process `
        -FilePath $ExePath `
        -ArgumentList $cliArgs `
        -PassThru


    $Processes += [PSCustomObject]@{
        Name  = $dckName
        Dck   = $dck
        Start = $start
        Proc  = $proc
    }
}


# ---- Wait for simulations ------------------------------------------------------

$failures = 0
$completed = 0


foreach ($run in $Processes) {

    $run.Proc.WaitForExit()

    $completed++

    $duration = (Get-Date) - $run.Start
    $exitCode = $run.Proc.ExitCode


    $meaning = if ($ExitCodeMeaning.ContainsKey($exitCode)) {
        $ExitCodeMeaning[$exitCode]
    }
    else {
        "Unknown($exitCode)"
    }


    Write-Host ""

    if ($exitCode -eq 0) {

        Write-Host `
            "[$completed/$TotalRuns] $($run.Name): PASS ($([math]::Round($duration.TotalSeconds,1))s)" `
            -ForegroundColor Green

    }
    else {

        Write-Host `
            "[$completed/$TotalRuns] $($run.Name): FAIL ($exitCode - $meaning)" `
            -ForegroundColor Red

        $failures++
    }


    $row =
        "$($run.Name)," +
        (($Keys | ForEach-Object {
            Format-ArgValue $Params[$_]
        }) -join ",") +
        ",$exitCode,$meaning,$([math]::Round($duration.TotalSeconds,1)),$($run.Start)"


    $row | Out-File -FilePath $ResultsFile -Append -Encoding UTF8
}


# ---- Summary -------------------------------------------------------------------

$elapsed = (Get-Date) - $runStart

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host `
    "All runs complete: $completed run(s), $failures failure(s)." `
    "Elapsed: $($elapsed.ToString())" `
    -ForegroundColor Yellow
Write-Host "Results saved to: $ResultsFile" -ForegroundColor Yellow
Write-Host "==================================================================" -ForegroundColor Yellow
