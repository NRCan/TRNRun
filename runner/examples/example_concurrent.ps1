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

$Worker = {
    param($ExecutablePath, $DeckFile)

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

    $CliArguments = @("--deckFile=$DeckFile") + $CliOptions

    $DeckName = [IO.Path]::GetFileName($DeckFile)
    $Host.UI.RawUI.WindowTitle = "trnrun - $DeckName"
    & $ExecutablePath $CliArguments
    if ($LASTEXITCODE) {
        Write-Warning "$DeckName failed with exit code $LASTEXITCODE"
        Read-Host 'Window kept open. Press Enter to close' | Out-Null
    }
}

$DeckFiles |
    Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object {
        $Command =
            "& {$Worker} '$($ExecutablePath -replace "'", "''")' " +
            "'$($_ -replace "'", "''")'"
        $EncodedCommand = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($Command)
        )
        Start-Process powershell.exe `
            -ArgumentList '-NoProfile', '-EncodedCommand', $EncodedCommand
        Write-Host "Launched $([IO.Path]::GetFileName($_))"
    }
