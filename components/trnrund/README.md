# TRNRun Daemon

`trnrund.exe` is a Windows command-line daemon that runs TRNSYS simulations
through
[TRNRun Runner](https://github.com/NRCan/TRNRun/tree/main/components/trnrun)
on behalf of one client application. The client sends JSON requests over stdin
and reads one JSON response per request from stdout. It:

- queues simulations and limits how many `trnrun.exe` processes run at once
- keeps each simulation's progress, result, and TRNSYS logs in memory until the
  client releases it
- validates decks and runner options when a simulation is added
- kills every runner it started when stdin closes or the daemon dies

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Settings](#settings)
- [Request protocol](#request-protocol)
- [Simulation fields](#simulation-fields)
- [Exit codes](#exit-codes)
- [Examples](#examples)
- [See also](#see-also)

## Requirements

### Runtime

- Windows x64
- [`trnrun.exe`](https://github.com/NRCan/TRNRun/tree/main/components/trnrun)
  executable
- TRNSYS 17 or 18 for actual simulation runs

### Development

- [Nim](https://nim-lang.org/install.html) 2.2.12 or newer
- [Zig](https://ziglang.org/download/) 0.17.0 as the Windows C compiler and
  resource compiler
- [just](https://github.com/casey/just) for repository-root recipes

## Installation

Download and extract `trnrund-v<version>-win_amd64.zip` from
[GitHub Releases](https://github.com/NRCan/TRNRun/releases). The daemon does not
bundle the runner; place `trnrun.exe` beside `trnrund.exe` or pass its path with
`--trnrun`.

Or build from source, run the following from the repository root:

```powershell
Set-Location components/trnrund
nimble bin
```

The executable is written to `components/trnrund/build/trnrund.exe` relative to
the repository root. `nimble test` runs the tests against a fake runner, so it
needs neither TRNRun nor TRNSYS.

## Quick start

Start the daemon with redirected stdin and stdout, then send one request and
read one response at a time:

```powershell
$StartInfo = [Diagnostics.ProcessStartInfo]::new('trnrund.exe', '--workers:4')
$StartInfo.UseShellExecute = $false
$StartInfo.RedirectStandardInput = $true
$StartInfo.RedirectStandardOutput = $true
$Daemon = [Diagnostics.Process]::Start($StartInfo)

function Send-Request([hashtable] $Request) {
    $Daemon.StandardInput.WriteLine(($Request | ConvertTo-Json -Compress))
    $Daemon.StandardOutput.ReadLine() | ConvertFrom-Json
}

$SimId = (Send-Request @{ cmd = 'add'; deckFile = 'C:\models\building-a.dck' }).simId
do {
    Start-Sleep -Seconds 1
    $Simulation = (Send-Request @{ cmd = 'get'; simId = $SimId }).simulation
} while ($Simulation.state -ne 'FINISHED')
Send-Request @{ cmd = 'release'; simId = $SimId } | Out-Null

$Daemon.StandardInput.Close()
$Daemon.WaitForExit()
```

For option and version information:

```powershell
trnrund --help
trnrund --version
```

## Settings

Options accept either `--name:value` or `--name=value`.

- _`--trnrun`_ (`string`, default: `trnrun.exe` beside `trnrund.exe`)

  Path to the runner executable used for every simulation. The file must exist
  when the daemon starts.

- _`--workers`_ (`integer`, default: `max(logical processors - 1, 1)`)

  Maximum number of simulations running at once. The value must be at least
  `1`. Further simulations wait in the queue.

## Request protocol

Write one JSON object per line to daemon stdin, then read exactly one JSON
response line from stdout before sending the next request. Stdout carries
nothing else; diagnostics go to stderr.

```json
{"cmd":"add","deckFile":"C:\\models\\building-a.dck","label":"building-a","trnrunArgs":["--guiVisibility:min"]}
{"ok":true,"simId":1}
```

Every response contains `ok`. When `ok` is `false`, it also contains `error`, a
human-readable message.

Closing stdin cancels every simulation and exits. If the daemon itself dies,
even by crashing, Windows kills every `trnrun.exe` and `TrnEXE` it started.

### Commands

- _`ready`_

  Answers `{"ok":true}`. Use it to confirm the daemon is up.

- _`add`_ (`deckFile`, optional `label` and `trnrunArgs`)

  Queues a simulation and answers `{"ok":true,"simId":1}`. `deckFile` is an
  existing `.dck` or `.trd` file; relative paths resolve from the daemon's
  working directory. `label` is any string returned with the simulation.
  `trnrunArgs` is an array of runner options such as `["--watchTmp:true"]`.
  Each option is checked by the runner's own option parser, so an unknown
  option or bad value is refused here; a deck path, `--deckFile`, `--help`, and
  `--version` are refused too. The response confirms queuing only, not that the
  simulation started or finished. A `simId` is never reused.

- _`get`_ (`simId`)

  Answers `{"ok":true,"simulation":{...}}` with every
  [simulation field](#simulation-fields). Refuses an unknown `simId`.

- _`list`_ (`state`, optional `withLogs`)

  Answers `{"ok":true,"simulations":[...]}` with every simulation not yet
  released in `state` (`QUEUED`, `RUNNING`, or `FINISHED`), oldest first. Each
  is shaped as `get` returns it, but without `logs` unless `withLogs` is
  `true`; the log counts stay. Polling `FINISHED` and releasing what it returns
  collects a batch in one request per poll.

- _`cancel`_ (`simId`)

  Stops a `QUEUED` or `RUNNING` simulation and answers `{"ok":true}`. Refuses
  one that is `FINISHED` or unknown.

- _`release`_ (`simId`)

  Forgets a `FINISHED` simulation and its logs and answers `{"ok":true}`.
  Refuses one that is still `QUEUED` or `RUNNING` (cancel it first) or unknown.

## Simulation fields

`get` returns the object below. A value the runner has not reported yet is
`null`.

```json
{"simId":1,"label":"building-a","state":"FINISHED","trnrunStatus":"DONE","trnrunMessage":"","percent":1.0,"simTime":8760.0,"elapsedMs":5321.0,"etaMs":0.0,"notices":2,"warnings":1,"fatals":0,"succeeded":true,"exitCode":0,"error":null,"submittedAt":"2026-10-22T14:03:12.345Z","startedAt":"2026-10-22T14:03:12.351Z","finishedAt":"2026-10-22T14:03:17.702Z","deckFile":"C:\\models\\building-a.dck","trnrunArgs":["--guiVisibility:min"],"startTime":0.0,"stopTime":8760.0,"timeStep":1.0,"setting":{...},"logs":[{"severity":"Warning","time":12.0,"unitId":5,"typeId":56,"messageCode":null,"message":"...","information":null}]}
```

- _`simId`_, _`label`_, _`deckFile`_, _`trnrunArgs`_

  The identifier assigned by `add` and the values the client sent with it.
  `deckFile` is the resolved absolute path.

- _`state`_ (`string`)

  `QUEUED` while waiting for a worker, `RUNNING` once the runner started, and
  `FINISHED` once it completed, failed, or was cancelled.

- _`succeeded`_ (`boolean`)

  Set once `FINISHED`. `true` only with runner status `DONE`, exit code `0`,
  and no `error`.

- _`trnrunStatus`_, _`trnrunMessage`_ (`string`)

  The runner's last
  [`STATUS`](https://github.com/NRCan/TRNRun/tree/main/components/trnrun#status-events)
  event. `CANCELLED` when cancelled, `ERROR` when the runner could not start or
  exited without a final status.

- _`percent`_, _`simTime`_, _`elapsedMs`_, _`etaMs`_ (`number`)

  The runner's last
  [`PROGRESS`](https://github.com/NRCan/TRNRun/tree/main/components/trnrun#progress-events)
  event. `percent` is in `[0, 1]` and `simTime` is in simulation hours.

- _`startTime`_, _`stopTime`_, _`timeStep`_ (`number`)

  Simulation period from the runner's
  [`CONFIG`](https://github.com/NRCan/TRNRun/tree/main/components/trnrun#config-events)
  event, in simulation hours.

- _`setting`_ (`object`)

  The runner's
  [`SETTING`](https://github.com/NRCan/TRNRun/tree/main/components/trnrun#setting-events)
  event: the effective settings applied to the run.

- _`notices`_, _`warnings`_, _`fatals`_ (`integer`), _`logs`_ (`array`)

  TRNSYS
  [`LOG`](https://github.com/NRCan/TRNRun/tree/main/components/trnrun#log-events)
  entries, counted by severity and kept oldest first.

- _`exitCode`_ (`integer`)

  The runner's
  [exit code](https://github.com/NRCan/TRNRun/tree/main/components/trnrun#exit-codes);
  `null` if it was cancelled or never started.

- _`error`_ (`string`)

  Why the daemon failed or cancelled the run, such as
  `Interrupted: cancelled by the client`.

- _`submittedAt`_, _`startedAt`_, _`finishedAt`_ (`string`)

  UTC ISO 8601 timestamps with millisecond precision.

## Exit codes

| Exit code | Meaning |
| --- | --- |
| `0` | Stdin closed and every simulation was cancelled. Help and version also return `0`. Individual simulations may still have failed. |
| `1` | Unexpected fatal failure. |
| `2` | Invalid option, positional argument, or missing runner executable. |

Simulation outcomes do not become the daemon exit code. Inspect each
simulation's `succeeded`, `trnrunStatus`, and `exitCode` instead.

## Examples

PowerShell examples are available in
[`examples`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund/examples).
They expect
`build/trnrund.exe` and `../trnrun/build/trnrun.exe` to exist and use the
default TRNSYS 18 executable path.

- [`example_concurrent.ps1`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/examples/example_concurrent.ps1)
  adds every simulation at once and lets the daemon queue them.
- [`example_waiting.ps1`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/examples/example_waiting.ps1)
  adds the next simulation only once the previous one has started.
- [`example_percent.ps1`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/examples/example_percent.ps1)
  does the same while printing each simulation's progress.

All scripts create ten temporary deck copies and allow up to five simultaneous
runs.

## See also

- [TRNRun Runner](https://github.com/NRCan/TRNRun/tree/main/components/trnrun):
  runs a single TRNSYS simulation and reports its lifecycle as a JSON Lines
  event stream.
- [TRNRun Queue](https://github.com/NRCan/TRNRun/tree/main/components/trnrunq):
  runs batches of simulations through a bounded pool of runners and merges
  their events into a single stream.
