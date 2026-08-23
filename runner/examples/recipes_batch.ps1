$RunnerRoot = Split-Path -Path $PSScriptRoot -Parent
$ExecutablePath = Join-Path $RunnerRoot 'build\trnrun.exe'
$DeckDirectory = Join-Path $PSScriptRoot 'dck'

if (-not (Test-Path -LiteralPath $ExecutablePath)) {
    throw "trnrun.exe not found at $ExecutablePath"
}

$DeckFiles = @(
    'example_wo_plot_wo_tracking.dck'
    'example_wo_plot_w_tracking.dck'
    'example_w_plot_wo_tracking.dck'
    'example_w_plot_w_tracking.dck'
) | ForEach-Object { Join-Path $DeckDirectory $_ }

foreach ($DeckFile in $DeckFiles | Where-Object { Test-Path -LiteralPath $_ }) {
    $DeckName = [IO.Path]::GetFileName($DeckFile)
    Write-Host "Running $DeckName"
    & $ExecutablePath $DeckFile `
        --watchTmp:true `
        --watchTimeout:7200000 `
        --killOnTimeout:true `
        --stallTimeout:300000 `
        --killOnStall:true `
        --clean:true
    if ($LASTEXITCODE) {
        Write-Warning "$DeckName failed with exit code $LASTEXITCODE"
    }
}
