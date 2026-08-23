$RunnerRoot = Join-Path $PSScriptRoot '..'
$ExecutablePath = Join-Path $RunnerRoot 'build\trnrun.exe'
$DeckFile = Join-Path `
    $RunnerRoot `
    'tests\dck\test_wo_plot_w_tracking.dck'

$CliArguments = @(
    "--deckFile=$DeckFile"
    '--guiVisibility=auto'
    '--watchTmp=true'
    '--detectTimeout=0'
    '--pollMs=100'
    '--extraDelay=0'
)

$ExitCodeMeanings = @{
    0 = 'Done'
    1 = 'Fatal'
    2 = 'User Error'
    124 = 'Timeout'
    125 = 'Stalled'
    130 = 'Cancelled'
}

if (-not (Test-Path $ExecutablePath)) {
    Write-Host `
        "ERROR: Executable not found at $ExecutablePath" `
        -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $DeckFile)) {
    Write-Host "ERROR: Deck file not found at $DeckFile" -ForegroundColor Red
    exit 1
}

Write-Host 'Running:' -ForegroundColor Cyan
Write-Host "  $ExecutablePath $($CliArguments -join ' ')" `
    -ForegroundColor DarkGray
Write-Host ''

$StartedAt = Get-Date
# Run synchronously and stream native output to the console.
& $ExecutablePath @CliArguments
$ExitCode = $LASTEXITCODE
$Duration = (Get-Date) - $StartedAt

$ExitMeaning = if ($ExitCodeMeanings.ContainsKey($ExitCode)) {
    $ExitCodeMeanings[$ExitCode]
} else {
    "Unknown($ExitCode)"
}
$ResultColor = if ($ExitCode -eq 0) { 'Green' } else { 'Red' }

Write-Host ''
Write-Host `
    "Exit code: $ExitCode ($ExitMeaning)  Duration: $([math]::Round($Duration.TotalSeconds,1))s" `
    -ForegroundColor $ResultColor
