$RepoRoot = Join-Path $PSScriptRoot ".."
$ExePath = Join-Path $RepoRoot "build\trnrun.exe"
$DeckFile = Join-Path $RepoRoot "tests\dck\test_wo_plot_w_tracking.dck"

$Args = @(
    "--deckFile=$DeckFile"
    "--guiVisibility=auto",
    "--watchTmp=true",
    "--detectTimeout=0",
    "--pollMs=100",
    "--extraDelay=0"
)



$ExitCodeMeaning = @{
    0   = "Done"
    1   = "Fatal"
    2   = "User Error"
    124 = "Timeout"
    125 = "Stalled"
    130 = "Cancelled"
}

if (-not (Test-Path $ExePath)) {
    Write-Host "ERROR: Executable not found at $ExePath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $DeckFile)) {
    Write-Host "ERROR: Deck file not found at $DeckFile" -ForegroundColor Red
    exit 1
}

Write-Host "Running:" -ForegroundColor Cyan
Write-Host "  $ExePath $($Args -join ' ')" -ForegroundColor DarkGray
Write-Host ""

$start = Get-Date
& $ExePath @Args          # streams stdout/stderr straight to console, no buffering
$exitCode = $LASTEXITCODE
$duration = (Get-Date) - $start

$meaning = if ($ExitCodeMeaning.ContainsKey($exitCode)) { $ExitCodeMeaning[$exitCode] } else { "Unknown($exitCode)" }
$color = if ($exitCode -eq 0) { "Green" } else { "Red" }

Write-Host ""
Write-Host "Exit code: $exitCode ($meaning)  Duration: $([math]::Round($duration.TotalSeconds,1))s" -ForegroundColor $color
