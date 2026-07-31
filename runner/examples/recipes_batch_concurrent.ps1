$RunnerRoot = Split-Path -Path $PSScriptRoot -Parent
$Exe        = Join-Path $RunnerRoot 'build\trnrun.exe'
$DeckDir    = Join-Path $PSScriptRoot 'dck'

if (-not (Test-Path -LiteralPath $Exe)) { throw "trnrun.exe not found at $Exe" }

$DckFiles = @(
    'example_wo_plot_wo_tracking.dck'
    'example_wo_plot_w_tracking.dck'
    'example_w_plot_wo_tracking.dck'
    'example_w_plot_w_tracking.dck'
) | ForEach-Object { Join-Path $DeckDir $_ }

$worker = {
    param($Exe, $Deck)
    $name = [IO.Path]::GetFileName($Deck)
    $host.UI.RawUI.WindowTitle = "trnrun - $name"
    & $Exe $Deck `
        --watchTmp:true `
        --watchTimeout:7200000 `
        --killOnTimeout:true `
        --stallTimeout:300000 `
        --killOnStall:true `
        --clean:true
    if ($LASTEXITCODE) {
        Write-Warning "$name failed with exit code $LASTEXITCODE"
        Read-Host 'Window kept open. Press Enter to close' | Out-Null
    }
}

$DckFiles |
    Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object {
        $cmd     = "& {$worker} '$($Exe -replace "'","''")' '$($_ -replace "'","''")'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        Start-Process powershell.exe -ArgumentList '-NoProfile', '-EncodedCommand', $encoded
        Write-Host "Launched $([IO.Path]::GetFileName($_))"
    }
