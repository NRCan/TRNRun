# Requires Python 3 on PATH; sqlite3 is part of Python's standard library.
$ErrorActionPreference = 'Stop'
Get-Command python -ErrorAction Stop | Out-Null

$RunCount = 10
$ConcurrencyLimit = 5
$PollSeconds = 1

$DaemonRoot = Split-Path -Path $PSScriptRoot -Parent
$DaemonPath = Join-Path $DaemonRoot 'build\trnrund.exe'
$RunnerPath = Join-Path $DaemonRoot '..\trnrun\build\trnrun.exe'
$SourceDeck = Join-Path $PSScriptRoot 'dck\example_wo_plot_w_tracking.dck'
$RunDirectory = Join-Path ([IO.Path]::GetTempPath()) "trnrund-example-$PID"
$DatabasePath = Join-Path $RunDirectory 'runs.sqlite3'

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

# Reads the runs changed since the last revision seen, with their log counts.
# Reading never consumes anything, so any number of clients can read at once.
$QueryCode = @'
import json, pathlib, sqlite3, sys
uri = pathlib.Path(sys.argv[1]).as_uri() + '?mode=ro'
revision = int(sys.argv[2])
db = sqlite3.connect(uri, uri=True)
db.row_factory = sqlite3.Row
rows = db.execute('''SELECT run_id, revision, state, trnrun_status, succeeded, warnings,
    notices + warnings + fatals AS log_count
    FROM runs WHERE revision > ? ORDER BY revision''', (revision,)).fetchall()
db.close()
if rows:
    revision = rows[-1]['revision']
print(json.dumps(dict(simulations=[dict(row) for row in rows], revision=revision)))
'@
$Revision = 0
$States = @{}
$LogCounts = @{}
$Finished = @{}
function Update-Runs {
    if ($Daemon.HasExited) {
        throw "trnrund exited unexpectedly with code $($Daemon.ExitCode)"
    }
    $Json = & python -c $QueryCode $DatabasePath $script:Revision
    if ($LASTEXITCODE -ne 0) {
        throw 'Database query failed'
    }
    $Changes = $Json | ConvertFrom-Json
    $script:Revision = $Changes.revision
    foreach ($Simulation in $Changes.simulations) {
        $RunId = $Simulation.run_id
        $LogCounts[$RunId] = $Simulation.log_count
        if ($States[$RunId] -ne $Simulation.state) {
            $States[$RunId] = $Simulation.state
            Write-Host "${RunId}: $($Simulation.state)"
        }
        # FINISHED is saved together with the final logs.
        if ($Simulation.state -eq 'FINISHED') {
            $Finished[$RunId] = $Simulation
        }
    }
}

New-Item -ItemType Directory -Path $RunDirectory | Out-Null
$Daemon = $null
try {
    $StartInfo = [Diagnostics.ProcessStartInfo]::new($DaemonPath)
    $StartInfo.Arguments = "--trnrun:`"$RunnerPath`" --maxConcurrent:$ConcurrencyLimit --database:`"$DatabasePath`""
    $StartInfo.UseShellExecute = $false
    $StartInfo.RedirectStandardInput = $true
    $StartInfo.RedirectStandardOutput = $true
    $Daemon = [Diagnostics.Process]::Start($StartInfo)
    $DatabasePath = (Send-Request @{ cmd = 'ready' }).databasePath

    Write-Host (
        "Submitting $RunCount copies one at a time, each once the previous is " +
        "accepted, with max concurrency $ConcurrencyLimit"
    )

    # Wait until each run leaves QUEUED before adding another. This limits the
    # daemon to one queued run while the client decides what to submit next.
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

        Update-Runs
        while (-not $States.ContainsKey($RunId) -or $States[$RunId] -eq 'QUEUED') {
            Start-Sleep -Seconds $PollSeconds
            Update-Runs
        }
    }

    while ($Finished.Count -lt $RunCount) {
        Start-Sleep -Seconds $PollSeconds
        Update-Runs
    }

    $FailureCount = 0
    foreach ($RunId in $Finished.Keys | Sort-Object) {
        $Simulation = $Finished[$RunId]
        $Verdict = if ($Simulation.succeeded) { 'PASS' } else { 'FAIL' }
        Write-Host (
            "$Verdict - ${RunId}: $($Simulation.trnrun_status), " +
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
