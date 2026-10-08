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

# Polls the runs changed since the previous poll, each with only its new logs.
$Revision = 0
$States = @{}
$LogCounts = @{}
$Finished = @{}
function Update-Runs {
    $Changes = Send-Request @{ cmd = 'changes'; since = $script:Revision }
    $script:Revision = $Changes.revision
    foreach ($Simulation in $Changes.simulations) {
        $RunId = $Simulation.runId
        $LogCounts[$RunId] += $Simulation.logs.Count
        if ($States[$RunId] -ne $Simulation.state) {
            $States[$RunId] = $Simulation.state
            Write-Host "${RunId}: $($Simulation.state)"
        }
        # A run is done once its state is FINISHED. That reply carries its last
        # logs, and remove frees its runId.
        if ($Simulation.state -eq 'FINISHED') {
            $Finished[$RunId] = $Simulation
            Send-Request @{ cmd = 'remove'; runId = $RunId } | Out-Null
        }
    }
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

    Write-Host "Running $RunCount copies with max concurrency $ConcurrencyLimit"

    # Adding every run at once lets the daemon queue the surplus and start each
    # as a worker frees; see example_waiting.ps1 to keep that queue client-side.

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
    }

    Update-Runs
    while ($Finished.Count -lt $RunCount) {
        Start-Sleep -Seconds $PollSeconds
        Update-Runs
    }

    $FailureCount = 0
    foreach ($RunId in $Finished.Keys | Sort-Object) {
        $Simulation = $Finished[$RunId]
        $Verdict = if ($Simulation.succeeded) { 'PASS' } else { 'FAIL' }
        Write-Host (
            "$Verdict - ${RunId}: $($Simulation.status.status), " +
            "$($LogCounts[$RunId]) logs, $($Simulation.warnings) warnings"
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
