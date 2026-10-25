# TRNRun Daemon

`trnrund.exe` is a Windows command-line daemon that runs TRNSYS simulations
through
[TRNRun Runner](https://github.com/NRCan/TRNRun/tree/main/components/trnrun)
on behalf of one client application. The client sends JSON requests over stdin
and reads one JSON response per request from stdout. It:

- queues simulations and limits how many `trnrun.exe` processes run at once
- keeps each simulation's progress, result, and TRNSYS logs in memory until the
  client releases it

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
- Optional: [Type3830 Progress Tracker](https://github.com/NRCan/TRNRun/tree/main/components/type3830) for progress, ETA, cancellation, and stall detection

### Development

- [Nim](https://nim-lang.org/install.html) 2.2.12
- [Zig](https://ziglang.org/download/) 0.17.0 as the Windows C compiler and
  resource compiler
- [just](https://github.com/casey/just) for repository-root recipes

## Installation

Download and extract `trnrund-v<version>-win_amd64.zip` from
[GitHub Releases](https://github.com/NRCan/TRNRun/releases). 

Or build from source, run the following from the repository root:

```powershell
Set-Location components/trnrund
nimble bin
```

The executable is written to `components/trnrun/build/trnrun.exe` relative to
the repository root.

## Quick start

Start the daemon with redirected stdin and stdout, then send one request and
read one response at a time:

```powershell
$Daemon = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{
    FileName = 'trnrund.exe'
    UseShellExecute = $false
    RedirectStandardInput = $true
    RedirectStandardOutput = $true
})

$Daemon.StandardInput.WriteLine('{"cmd":"add","deckFile":"C:\\models\\building-a.dck"}')
$SimId = ($Daemon.StandardOutput.ReadLine() | ConvertFrom-Json).simId
do {
    Start-Sleep -Seconds 1
    $Daemon.StandardInput.WriteLine('{"cmd":"simulation","simId":' + $SimId + '}')
    $Simulation = ($Daemon.StandardOutput.ReadLine() | ConvertFrom-Json).simulation
} while ($Simulation.state -ne 'FINISHED')

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

The client writes one JSON request per line to stdin, then reads exactly one
reply line from stdout before sending the next.

Closing stdin cancels every simulation and exits. If the daemon itself dies,
even by crashing, Windows kills every `trnrun.exe` and `TrnEXE` it started.

Each command below shows a request line and its reply line.

The `cmd` field picks the command:

- [`ready`](#ready): check the daemon is up.
- [`add`](#add): queue a simulation.
- [`simulation`](#simulation): get one simulation.
- [`simulations`](#simulations): get every simulation in a state.
- [`cancel`](#cancel): stop one simulation.
- [`release`](#release): forget one finished simulation.

### `ready`

Confirms the daemon is up and reading requests.

```jsonc
// stdin
{"cmd":"ready"}
// stdout
{"ok":true}
```

- **stdin**: no fields besides `cmd`.
- **stdout**: no fields besides `ok`.

### `add`

Queues a simulation, starts it at once if a worker is free, and replies with
its `simId`. The reply does not mean the simulation has started; read `state`
with [`simulation`](#simulation).

```jsonc
// stdin
{"cmd":"add","deckFile":"C:\\models\\building-a.dck","trnrunArgs":["--guiVisibility:min"],"label":"building-a"}
// stdout
{"ok":true,"simId":1}
```

- **stdin**:
  - `deckFile`: an existing `.dck` or `.trd` file; relative paths resolve from
    the daemon's working directory.
  - `trnrunArgs` (optional): runner options, such as `--watchTmp:true`.
  - `label` (optional): a text tag returned with the simulation, for the
    client's own use. It does not need to be unique.
- **stdout**:
  - `simId`: the ID the daemon assigned, an integer never reused.

### `simulation`

Returns one simulation that is not yet released.

```jsonc
// stdin
{"cmd":"simulation","simId":1,"withLogs":false}
// stdout
{"ok":true,"simulation":{"simId":1,"label":"building-a","state":"RUNNING",...}}
```

- **stdin**:
  - `simId`: the simulation to get.
  - `withLogs` (optional, default `false`): include `logs`. The log counts are
    always included.
- **stdout**:
  - `simulation`: every [simulation field](#simulation-fields), without `logs`
    unless `withLogs` is `true`.

### `simulations`

Returns every simulation not yet released in one state, oldest first. Polling
`FINISHED` and releasing what it returns collects a batch in one request per
poll.

```jsonc
// stdin
{"cmd":"simulations","state":"FINISHED","withLogs":false}
// stdout
{"ok":true,"simulations":[{"simId":1,"label":"building-a","state":"FINISHED",...}]}
```

- **stdin**:
  - `state`: `QUEUED`, `RUNNING`, or `FINISHED`.
  - `withLogs` (optional, default `false`): include `logs`, as for
    [`simulation`](#simulation).
- **stdout**:
  - `simulations`: an array of simulations, each shaped as
    [`simulation`](#simulation) returns it.

### `cancel`

Stops one `QUEUED` or `RUNNING` simulation.

```jsonc
// stdin
{"cmd":"cancel","simId":1}
// stdout
{"ok":true}
```

- **stdin**:
  - `simId`: the simulation to stop. One already `FINISHED` is left unchanged
    and still answered `ok`, so a client racing the finish needs no special
    case; read its outcome with [`simulation`](#simulation). An unknown one is
    refused.
- **stdout**: no fields besides `ok`.

### `release`

Forgets one `FINISHED` simulation.

```jsonc
// stdin
{"cmd":"release","simId":1}
// stdout
{"ok":true}
```

- **stdin**:
  - `simId`: the simulation to forget. One that is still `QUEUED` or
    `RUNNING` (cancel it first) or unknown is refused.
- **stdout**: no fields besides `ok`.

### Errors

A refused request, such as malformed JSON, an unknown `cmd`, or invalid
fields, gets `ok: false` and an `error` message for humans:

```jsonc
// stdin
{"cmd":"release","simId":1}
// stdout
{"ok":false,"error":"Cannot release simulation 1: it is RUNNING"}
```

## Simulation fields

`simulation` with `withLogs` returns the object below. A value the runner has
not reported yet is `null`.

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

## See also

- [TRNRun Runner](https://github.com/NRCan/TRNRun/tree/main/components/trnrun):
  runs a single TRNSYS simulation and reports its lifecycle as a JSON Lines
  event stream.
- [TRNRun Queue](https://github.com/NRCan/TRNRun/tree/main/components/trnrunq):
  runs batches of simulations through a bounded pool of runners and merges
  their events into a single stream.
