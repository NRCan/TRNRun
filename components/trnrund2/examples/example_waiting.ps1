$ErrorActionPreference = 'Stop'

$RunCount = 10
$ConcurrencyLimit = 5
$PollSeconds = 1

$DaemonRoot = Split-Path -Path $PSScriptRoot -Parent
$DaemonPath = Join-Path $DaemonRoot 'build\trnrund2.exe'
$RunnerPath = Join-Path $DaemonRoot '..\trnrun\build\trnrun.exe'
$SourceDeck = Join-Path $PSScriptRoot 'dck\example_wo_plot_w_tracking.dck'
$RunDirectory = Join-Path ([IO.Path]::GetTempPath()) "trnrund2-example-$PID"

$DaemonPath, $RunnerPath, $SourceDeck | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
        throw "Required file not found: $_"
    }
}

# trnrund2 answers each request line with exactly one response line before
# reading the next, and writes nothing else to stdout.
function Send-Request([hashtable] $Request) {
    $Daemon.StandardInput.WriteLine(($Request | ConvertTo-Json -Compress))
    $Line = $Daemon.StandardOutput.ReadLine()
    if ($null -eq $Line) {
        throw 'trnrund2 closed its output'
    }
    $Reply = $Line | ConvertFrom-Json
    if (-not $Reply.ok) {
        throw "$($Request.cmd) failed: $($Reply.error)"
    }
    $Reply
}

# Asks for each unfinished simulation's latest state, keeps the finished ones,
# then releases them so trnrund2 no longer holds them in memory.
$Pending = [Collections.Generic.List[int]]::new()
$States = @{}
$Finished = @{}
function Update-Runs {
    foreach ($SimId in @($Pending)) {
        $Simulation = (Send-Request @{ cmd = 'get'; simId = $SimId }).simulation
        $Name = $Simulation.label
        if ($States[$Name] -ne $Simulation.state) {
            $States[$Name] = $Simulation.state
            Write-Host "${Name}: $($Simulation.state)"
        }
        if ($Simulation.state -eq 'FINISHED') {
            $Finished[$Name] = $Simulation
            Send-Request @{ cmd = 'release'; simId = $SimId } | Out-Null
            $Pending.Remove($SimId) | Out-Null
        }
    }
}

New-Item -ItemType Directory -Path $RunDirectory | Out-Null
$Daemon = $null
try {
    $StartInfo = [Diagnostics.ProcessStartInfo]::new($DaemonPath)
    $StartInfo.Arguments = "--trnrun:`"$RunnerPath`" --workers:$ConcurrencyLimit"
    $StartInfo.UseShellExecute = $false
    $StartInfo.RedirectStandardInput = $true
    $StartInfo.RedirectStandardOutput = $true
    $Daemon = [Diagnostics.Process]::Start($StartInfo)

    Write-Host (
        "Submitting $RunCount copies one at a time, each once the previous has " +
        "started, with max concurrency $ConcurrencyLimit"
    )

    # add replies with the simId the daemon assigned, not when the run starts.
    # This example names runs by label. Wait for its state
    # to leave QUEUED before adding another, keeping at most one queued run.
    1..$RunCount | ForEach-Object {
        $Name = 'example-{0:D2}' -f $_
        $DeckFile = Join-Path $RunDirectory "$Name.dck"

        # Each run needs its own deck because TRNRun writes sidecars beside it.
        Copy-Item -LiteralPath $SourceDeck -Destination $DeckFile

        $Pending.Add((Send-Request @{
            cmd = 'add'
            label = $Name
            deckFile = $DeckFile
            trnrunArgs = @(
                '--guiVisibility:auto'
                '--watchTmp:true'
            )
        }).simId)

        Update-Runs
        while (-not $States.ContainsKey($Name) -or $States[$Name] -eq 'QUEUED') {
            Start-Sleep -Seconds $PollSeconds
            Update-Runs
        }
    }

    while ($Finished.Count -lt $RunCount) {
        Start-Sleep -Seconds $PollSeconds
        Update-Runs
    }

    $FailureCount = 0
    foreach ($Name in $Finished.Keys | Sort-Object) {
        $Simulation = $Finished[$Name]
        $Verdict = if ($Simulation.succeeded) { 'PASS' } else { 'FAIL' }
        Write-Host (
            "$Verdict - ${Name}: $($Simulation.trnrunStatus), " +
            "$($Simulation.logs.Count) logs, " +
            "$($Simulation.warnings) warnings"
        )
        if (-not $Simulation.succeeded) {
            $FailureCount++
        }
    }

    # trnrund2 exits once its stdin closes; nothing else is left to read.
    $Daemon.StandardInput.Close()
    $Daemon.StandardOutput.ReadToEnd() | Out-Null
    $Daemon.WaitForExit()
    if ($Daemon.ExitCode) {
        throw "trnrund2 failed with exit code $($Daemon.ExitCode)"
    }
    if ($FailureCount) {
        throw "$FailureCount of $RunCount runs failed"
    }
}
finally {
    # Killing trnrund2 also kills its TRNRun children through its job object.
    if ($Daemon -and -not $Daemon.HasExited) {
        $Daemon.Kill()
        $Daemon.WaitForExit()
    }
    Remove-Item -LiteralPath $RunDirectory -Recurse -Force
}
