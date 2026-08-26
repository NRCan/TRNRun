$RunnerRoot = Split-Path -Path $PSScriptRoot -Parent
$ExecutablePath = Join-Path $RunnerRoot 'build\trnrun.exe'
$DeckFile = Join-Path $PSScriptRoot 'dck\example_wo_plot_w_tracking.dck'

if (-not (Test-Path -LiteralPath $ExecutablePath)) {
    throw "trnrun.exe not found at $ExecutablePath"
}
if (-not (Test-Path -LiteralPath $DeckFile)) {
    throw "Deck file not found at $DeckFile"
}

# Runner settings. Time values are milliseconds.
$CliOptions = @(
    '--trnexePath=C:\TRNSYS18\Exe\TrnEXE64.exe'
    '--guiVisibility=hidden' # keep | auto | min | minauto | hidden
    '--waitForGui=true'
    '--waitForLst=true'
    '--waitForTmp=false'
    '--detectTimeout=300000'
    '--extraDelay=0'
    '--watchLog=true'
    '--watchTmp=true'
    '--watchTimeout=7200000'
    '--stallTimeout=300000'
    '--pollMs=100'
    '--clean=true'
    '--killOnTimeout=true'
    '--killOnStall=true'
    '--severity=Notice' # Notice | Warning | Fatal
    '--writeEvents=false'
)

Write-Host "Running $([IO.Path]::GetFileName($DeckFile))"
& $ExecutablePath "--deckFile=$DeckFile" $CliOptions

if ($LASTEXITCODE) {
    Write-Warning "Simulation failed with exit code $LASTEXITCODE"
}
