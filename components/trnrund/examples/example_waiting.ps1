$RunCount = 10
$ConcurrencyLimit = 5
$PollSeconds = 1

$DaemonRoot = Split-Path -Path $PSScriptRoot -Parent
$DaemonPath = Join-Path $DaemonRoot 'build\trnrund.exe'
$RunnerPath = Join-Path $DaemonRoot '..\trnrun\build\trnrun.exe'
$SourceDeck = Join-Path $PSScriptRoot 'dck\example_wo_plot_w_tracking.dck'
$RunDirectory = Join-Path ([IO.Path]::GetTempPath()) "trnrund-example-$PID"

$DaemonPath, $RunnerPath, $SourceDeck | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
        throw "Required file not found: $_"
    }
}

# trnrund answers each request line with one reply line, in request order.
function Send-Request([hashtable] $Request) {
    $Daemon.StandardInput.WriteLine(($Request | ConvertTo-Json -Compress))
    $Line = $Daemon.StandardOutput.ReadLine()
    if ($null -eq $Line) {
        throw 'trnrund closed its output'
    }

    $Reply = $Line | ConvertFrom-Json
    if (-not $Reply.ok) {
        throw "$($Request.cmd) failed: $($Reply.error)"
    }
    $Reply
}

New-Item -ItemType Directory -Path $RunDirectory | Out-Null
$Daemon = $null
try {
    $StartInfo = [Diagnostics.ProcessStartInfo]::new($DaemonPath)
    $StartInfo.Arguments = "--trnrun:`"$RunnerPath`" --maxConcurrent:$ConcurrencyLimit"
    $StartInfo.UseShellExecute = $false
    $StartInfo.RedirectStandardInput = $true
    $StartInfo.RedirectStandardOutput = $true
    $Daemon = [Diagnostics.Process]::Start($StartInfo)

    Write-Host (
        "Submitting $RunCount copies one at a time, each once the previous is " +
        "accepted, with max concurrency $ConcurrencyLimit"
    )

    # Waiting for ACCEPTED keeps the daemon queue empty: a run is only added
    # once the previous one holds a worker, so the client decides what runs next.
    $States = @{}
    1..$RunCount | ForEach-Object {
        $RunId = 'example-{0:D2}' -f $_
        $DeckFile = Join-Path $RunDirectory "$RunId.dck"

        # Each run needs its own deck because TRNRun writes sidecars beside it.
        Copy-Item -LiteralPath $SourceDeck -Destination $DeckFile

        Send-Request @{
            cmd = 'add'
            runId = $RunId
            deckFile = $DeckFile
            trnrunArgs = @(
                '--guiVisibility:auto'
                '--watchTmp:true'
            )
        } | Out-Null

        $State = (Send-Request @{ cmd = 'snapshot'; runId = $RunId }).simulation.state
        if ($State -eq 'QUEUED') {
            Write-Host "${RunId}: QUEUED, waiting for a free worker"
        }
        while ($State -eq 'QUEUED') {
            Start-Sleep -Seconds $PollSeconds
            $State = (Send-Request @{ cmd = 'snapshot'; runId = $RunId }).simulation.state
        }
        $States[$RunId] = $State
        Write-Host "${RunId}: $State"
    }

    # A run is done once its state is FINISHED; collect returns it with its
    # logs and frees its runId.
    $Collected = @{}
    while ($Collected.Count -lt $RunCount) {
        foreach ($Simulation in (Send-Request @{ cmd = 'snapshots' }).simulations) {
            if ($States[$Simulation.runId] -ne $Simulation.state) {
                $States[$Simulation.runId] = $Simulation.state
                Write-Host "$($Simulation.runId): $($Simulation.state)"
            }
            if ($Simulation.state -eq 'FINISHED') {
                $Collected[$Simulation.runId] =
                    Send-Request @{ cmd = 'collect'; runId = $Simulation.runId }
            }
        }
        if ($Collected.Count -lt $RunCount) {
            Start-Sleep -Seconds $PollSeconds
        }
    }

    $FailureCount = 0
    foreach ($RunId in $Collected.Keys | Sort-Object) {
        $Simulation = $Collected[$RunId].simulation
        $Verdict = if ($Simulation.succeeded) { 'PASS' } else { 'FAIL' }
        Write-Host (
            "$Verdict - ${RunId}: $($Simulation.status.status), " +
            "$($Collected[$RunId].logs.Count) logs, $($Simulation.warnings) warnings"
        )
        if (-not $Simulation.succeeded) {
            $FailureCount++
        }
    }

    Send-Request @{ cmd = 'shutdown' } | Out-Null
    $Daemon.WaitForExit()
    if ($Daemon.ExitCode) {
        throw "trnrund failed with exit code $($Daemon.ExitCode)"
    }
    if ($FailureCount) {
        throw "$FailureCount of $RunCount runs failed"
    }
}
finally {
    # Killing trnrund also kills its TRNRun children through its job object.
    if ($Daemon -and -not $Daemon.HasExited) {
        $Daemon.Kill()
        $Daemon.WaitForExit()
    }
    Remove-Item -LiteralPath $RunDirectory -Recurse -Force
}
