$QueueRoot = Split-Path -Path $PSScriptRoot -Parent
$QueuePath = Join-Path $QueueRoot 'build\trnrunq.exe'
$RunnerPath = Join-Path $QueueRoot '..\trnrun\build\trnrun.exe'
$SourceDeck = Join-Path $PSScriptRoot 'dck\example_wo_plot_w_tracking.dck'
$RunDirectory = Join-Path ([IO.Path]::GetTempPath()) "trnrunq-example-$PID"

if (-not (Test-Path -LiteralPath $QueuePath)) {
    throw "trnrunq.exe not found at $QueuePath"
}
if (-not (Test-Path -LiteralPath $RunnerPath)) {
    throw "trnrun.exe not found at $RunnerPath"
}
if (-not (Test-Path -LiteralPath $SourceDeck)) {
    throw "Deck file not found at $SourceDeck"
}

New-Item -ItemType Directory -Path $RunDirectory | Out-Null
try {
    Write-Host 'Submitting 10 copies every 5 seconds with max concurrency 5'

    1..10 | ForEach-Object {
        if ($_ -gt 1) {
            Start-Sleep -Seconds 5
        }

        $RunId = 'example-{0:D2}' -f $_
        $DeckFile = Join-Path $RunDirectory "$RunId.dck"

        # Each run needs its own deck because TRNRun writes sidecars beside it.
        Copy-Item -LiteralPath $SourceDeck -Destination $DeckFile

        @{
            runId = $RunId
            deckFile = $DeckFile
            runnerPath = $RunnerPath
            runnerArgs = @('--watchTmp=true')
        } | ConvertTo-Json -Compress
    } | & $QueuePath '--maxConcurrent=5'

    if ($LASTEXITCODE) {
        throw "trnrunq failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $RunDirectory -Recurse -Force
}
