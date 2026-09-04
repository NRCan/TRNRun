$RunCount = 10
$ConcurrencyLimit = 5
$SubmissionIntervalSeconds = 2

$QueueRoot = Split-Path -Path $PSScriptRoot -Parent
$QueuePath = Join-Path $QueueRoot 'build\trnrunq.exe'
$RunnerPath = Join-Path $QueueRoot '..\trnrun\build\trnrun.exe'
$SourceDeck = Join-Path $PSScriptRoot 'dck\example_wo_plot_w_tracking.dck'
$RunDirectory = Join-Path ([IO.Path]::GetTempPath()) "trnrunq-example-$PID"

$QueuePath, $RunnerPath, $SourceDeck | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
        throw "Required file not found: $_"
    }
}

New-Item -ItemType Directory -Path $RunDirectory | Out-Null
try {
    Write-Host (
        "Submitting $RunCount copies every $SubmissionIntervalSeconds seconds " +
        "with max concurrency $ConcurrencyLimit"
    )

    1..$RunCount | ForEach-Object {
        if ($_ -gt 1) {
            Start-Sleep -Seconds $SubmissionIntervalSeconds
        }

        $RunId = 'example-{0:D2}' -f $_
        $DeckFile = Join-Path $RunDirectory "$RunId.dck"

        Copy-Item -LiteralPath $SourceDeck -Destination $DeckFile

        @{
            runId = $RunId
            deckFile = $DeckFile
            runnerPath = $RunnerPath
            runnerArgs = @(
                '--guiVisibility=auto'
                '--watchTmp=true'
            )
        } | ConvertTo-Json -Compress
    } | & $QueuePath "--maxConcurrent=$ConcurrencyLimit" "--maxPending=$ConcurrencyLimit"

    if ($LASTEXITCODE) {
        throw "trnrunq failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $RunDirectory -Recurse -Force
}
