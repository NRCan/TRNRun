# TRNRun Daemon

`trnrund.exe` is a Windows daemon that runs TRNSYS simulations through
[TRNRun Runner](https://github.com/NRCan/TRNRun/tree/main/components/trnrun)
on behalf of one client application. It reads requests as JSON Lines from
stdin, runs them on a bounded pool of `trnrun.exe` processes, keeps their
progress, results, and logs in memory, and answers for them on stdout. The
JSON protocol below is the whole interface: a client sends requests and reads
their replies, nothing else.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Settings](#settings)
- [Request protocol](#request-protocol)
- [Runs and logs](#runs-and-logs)
- [Following runs](#following-runs)
- [Shutdown and failures](#shutdown-and-failures)
- [Exit codes](#exit-codes)
- [Examples](#examples)
- [See also](#see-also)

## Requirements

### Runtime

- Windows 10 or later, x64
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
[GitHub Releases](https://github.com/NRCan/TRNRun/releases). The daemon does
not bundle the runner; install `trnrun.exe` beside `trnrund.exe` or provide its
path with `--trnrun`.

Or build from source:

```powershell
Set-Location components/trnrund
nimble install -d
nimble bin
```

The executable is written to `components/trnrund/build/trnrund.exe` relative
to the repository root.

## Quick start

Start the daemon with a runner and a concurrency limit:

```powershell
trnrund --trnrun:"C:\bin\trnrun.exe" --maxConcurrent:2
```

Then write one request per line to its stdin:

```json
{"id":1,"cmd":"ready"}
{"id":2,"cmd":"add","deckFile":"C:\\models\\building-a.dck","trnrunArgs":["--watchTmp:true"],"waitFor":"FINISHED"}
{"id":3,"cmd":"shutdown"}
```

Close stdin to make the daemon exit.

For option and version information:

```powershell
trnrund --help
trnrund --version
```

## Settings

Options accept either `--name:value` or `--name=value`. Relative TRNRun and
deck paths resolve from the daemon's working directory.

- _`--trnrun`_ (`path`, default: `trnrun.exe` beside `trnrund.exe`)

  TRNRun executable used for every run. It must be an existing file.

- _`--maxConcurrent`_ (`integer`, default: `max(logical processors - 1, 1)`)

  Maximum number of simulations running at once. The value must be at least
  `1`.

## Request protocol

The client writes one JSON request per line to stdin. The daemon writes one
reply per request to stdout, and nothing else. Replies come in request order,
except for an [`add`](#add) that waits for its run: its reply comes once its
run gets there, and later replies are not held behind it. stderr gets one
line only, before a fatal exit. The protocol version is `2`, reported by
[`ready`](#ready).

A request may include an `id` (any JSON value). The reply echoes it as its
first field, so a client can match each reply to its request. Only an `add`
with `waitFor` waits on a simulation; every other request replies at once.

Runs and their logs live in memory: they are lost when the daemon exits, and
run IDs start at 1 on each start. `runId` only grows within one daemon and is
never reused.

Each command below shows a request line and its reply line, with the run and
log objects shortened. The `cmd` field picks the command:

- [`ready`](#ready): get the protocol version.
- [`add`](#add): queue a simulation.
- [`get`](#get): read one run with all its logs.
- [`release`](#release): delete a finished run the client has saved.
- [`cancel`](#cancel): stop one run.
- [`shutdown`](#shutdown): stop new work.

### `ready`

Reports the protocol and daemon versions and the concurrency limit, so a
client can check that it speaks the same protocol.

```jsonc
// stdin
{"id":1,"cmd":"ready"}
// stdout
{"id":1,"ok":true,"protocolVersion":2,"version":"0.9.0","maxConcurrent":4}
```

- **stdin**: no fields besides `cmd`.
- **stdout**:
  - `protocolVersion`: changes whenever a command, field, or object changes
    what clients read.
  - `version`: the daemon's version.
  - `maxConcurrent`: most simulations running at once.

### `add`

Queues a simulation as `QUEUED`, starts it at once if a slot is free, and
replies with its `runId` and [run](#runs).

```jsonc
// stdin
{"id":2,"cmd":"add","deckFile":"model.dck","trnrunArgs":["--watchTmp:true"],"label":"case A"}
// stdout
{"id":2,"ok":true,"runId":7,"run":{"runId":7,"label":"case A","state":"RUNNING"}}
```

- **stdin**:
  - `deckFile`: an existing `.dck` or `.trd` file; extensions are
    case-insensitive.
  - `trnrunArgs` (optional): TRNRun options, such as `--watchTmp:true`. `add`
    checks them with TRNRun's own parser and rejects the run if TRNRun would
    refuse one, so a typo fails at once instead of when the run starts. The
    daemon passes the deck and `runId` itself, so `trnrunArgs` cannot hold a
    deck path, `--deckFile`, `--runId`, `--help`, or `--version`.
  - `label` (optional): a text tag kept with the run, for the client's own
    use. It does not need to be unique.
  - `waitFor` (optional, default `QUEUED`): when to reply. `QUEUED` replies at
    once, `RUNNING` once the run starts, and `FINISHED` once it finishes. A
    later state also counts, so a run cancelled or failed before it started
    answers a `RUNNING` wait. An `add` that waits must have an `id`.
- **stdout**:
  - `runId`: the ID the daemon assigned.
  - `run`: the run as it is when the reply is sent, so a `FINISHED` wait
    returns the outcome without a separate `get`.

A waiting `add` still gets its reply after a `shutdown`, once its run
finishes or is cancelled. When stdin closes, waiting adds get no reply.

### `get`

Replies with one run and all its logs.

```jsonc
// stdin
{"id":3,"cmd":"get","runId":7}
// stdout
{"id":3,"ok":true,"run":{"runId":7,"state":"FINISHED","logs":[{"severity":"Notice","simTime":0}]}}
```

- **stdin**:
  - `runId`: the run to read. An unknown or released `runId` is rejected.
- **stdout**:
  - `run`: the [run](#runs), with every log entry so far in `logs`.

### `release`

Deletes a finished run, with its logs, once the client has saved what it
needs. The daemon keeps every run until it is released, so a long batch
should release its runs as they finish.

```jsonc
// stdin
{"id":5,"cmd":"release","runId":7}
// stdout
{"id":5,"ok":true}
```

- **stdin**:
  - `runId`: the run to delete. It must be `FINISHED`, or the request is
    rejected. An unknown or already released `runId` is skipped, so a client
    can safely send the same request again.
- **stdout**: no fields besides `ok`.

A released run is unknown afterwards: `get` and `cancel` reject it.

### `cancel`

Stops one queued or running run.

```jsonc
// stdin
{"id":6,"cmd":"cancel","runId":7}
// stdout
{"id":6,"ok":true}
```

- **stdin**:
  - `runId`: the run to stop. Only an unknown or released `runId` is
    rejected.
- **stdout**: no fields besides `ok`, once the cancel is recorded.

### `shutdown`

Stops accepting runs and cancels queued ones. The daemon keeps answering
requests, so a client can collect the last results, and exits only when stdin
closes.

```jsonc
// stdin
{"id":7,"cmd":"shutdown","cancelRunning":false}
// stdout
{"id":7,"ok":true}
```

- **stdin**:
  - `cancelRunning` (optional, default `false`): kill running runs instead of
    letting them finish.
- **stdout**: no fields besides `ok`, at once.

### Errors

A rejected request, such as malformed JSON, an unknown `cmd`, or invalid
fields, gets `ok: false` and an `error` message, with its `id` if it had one:

```jsonc
// stdin
{"id":8,"cmd":"cancel","runId":99}
// stdout
{"id":8,"ok":false,"error":"Unknown runId: 99"}
```

## Runs and logs

### Runs

A run object has these fields. A value TRNRun has not reported yet is `null`,
as are `exitCode` until TRNRun exits and `error` when there is none.

| Field | Type | Meaning |
| ------ | ---- | ------- |
| `runId` | integer | Assigned by the daemon and returned by `add` |
| `label` | string | The `label` it was added with, or `null` |
| `state` | string | `QUEUED`, `RUNNING`, or `FINISHED` |
| `trnrunStatus`, `trnrunMessage` | string | TRNRun's latest `STATUS`; not `state`. `PENDING`, `LAUNCHING`, or `RUNNING` while it runs, then `DONE`, `CANCELLED`, `ERROR`, `TIMEOUT`, or `STALLED` |
| `percent`, `simTime`, `elapsedMs`, `etaMs` | number | TRNRun's latest `PROGRESS` |
| `notices`, `warnings`, `fatals` | integer | Log entries so far, by severity |
| `succeeded` | boolean | `true` if it finished with `DONE`, exit code 0, and no error, else `false`; `null` until `FINISHED` |
| `exitCode` | integer | TRNRun's exit code |
| `error` | string | Execution error reported by the daemon |
| `submittedAt`, `startedAt`, `finishedAt` | string | Timestamps, see [Timestamps](#timestamps) |
| `deckFile` | string | Absolute deck path |
| `trnrunArgs` | array of strings | The `trnrunArgs` it was added with |
| `startTime`, `stopTime`, `timeStep` | number | TRNRun's `CONFIG`: simulated hours |
| `setting` | object | TRNRun's latest `SETTING` event, without its `kind` and `timestamp` |
| `logs` | array of objects | Every [log entry](#logs) so far, oldest first |

`setting` holds the options trnrund knows, one key per TRNRun option; its keys
change only with the protocol version.

### Logs

A log object is one TRNRun `LOG` event of its run:

| Field | Type | Meaning |
| ------ | ---- | ------- |
| `severity` | string | `Notice`, `Warning`, or `Fatal` |
| `simTime` | number | Simulated time of the entry |
| `unitId`, `typeId`, `messageCode` | integer | TRNSYS unit, type, and message code; `null` if none |
| `message`, `information` | string | TRNSYS text; `null` if none |

### Timestamps

The timestamps are UTC ISO 8601 text with milliseconds, such as
`2026-10-09T14:03:12.345Z`, which sort chronologically as text. `startedAt` is
`null` until TRNRun starts, and stays `null` for a run that never did;
`finishedAt` is `null` until the run is `FINISHED`.

### Completion

A run is done once `state` is `FINISHED`, after TRNRun exits. Do not use
`trnrunStatus` `DONE` or `percent` `1` instead: TRNRun can report them before
it exits, and output may still follow. `FINISHED` includes failed and
cancelled runs; `succeeded` tells them apart, and its logs are then complete.
A `FINISHED` run never changes again.

## Following runs

A client polls: it remembers the `runId` each `add` replied with, and sends
`get` for each unfinished run every second or so. Each reply is one
consistent view of the run and all its logs. Once a run is `FINISHED`, its
logs are complete, so the client can save it and `release` it. The daemon's
memory then stays flat however long the batch.

## Shutdown and failures

- [`cancel`](#cancel) finishes a queued run as `FINISHED` and `CANCELLED`,
  with the error `Not started: cancelled by the client`, before its reply. A
  running run has its TRNRun killed, and TRNRun's own Job Object then stops
  TrnEXE; the run becomes `FINISHED` and `CANCELLED` shortly after the reply,
  with the error `Interrupted: cancelled by the client`, a `null` exit code,
  and its slot freed for the next queued run. A finished run is left
  unchanged, so a run that finishes just before its cancel keeps its real
  outcome. If TRNRun reported a terminal status, such as `DONE`, just before
  it was killed, that status is kept, but `succeeded` is still false.
- [`shutdown`](#shutdown) finishes queued runs as `FINISHED` and `CANCELLED`,
  with the error `Not started: the daemon shut down`. Running runs finish, or
  with `cancelRunning` are killed with the error
  `Interrupted: the daemon shut down`. The daemon keeps answering every
  request: `get`, `release`, and `cancel` work, `shutdown` can be sent
  again with `cancelRunning`, and `add` is rejected.
- The daemon exits only when stdin closes, also during a `shutdown`, without
  waiting for running simulations: it kills them, and their state is lost
  with every other run's. The same happens if stdout can no longer be
  written. A client that wants the final results collects them before it
  closes stdin.
- However the daemon exits, a client still reading stdout gets every reply
  left to write; one that is not reading holds the exit up for at most a
  second. TRNRun children do not inherit the daemon's stdin, stdout, or
  stderr.
- A kill-on-close Windows Job Object terminates remaining TRNRun descendants
  when the daemon exits, even if it crashes.
- A run whose TRNRun cannot be started finishes at once, from `QUEUED`, with
  the launch error and a daemon `ERROR` status.

## Exit codes

| Exit code | Meaning |
| --- | --- |
| `0` | Normal exit after stdin closed. Help and version also return `0`. Individual runs may still have failed. |
| `1` | Fatal failure: an unexpected fault in the daemon. |
| `2` | Invalid option or startup validation error. |

Run outcomes do not become the daemon's exit code. Read `succeeded` and
`exitCode` in each run instead.

## Examples

PowerShell examples are available in
[`examples`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund/examples).
They expect `build/trnrund.exe` and `../trnrun/build/trnrun.exe` to exist, and
poll each run with `get`. Real simulations need TRNSYS.

- [`example_concurrent.ps1`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/examples/example_concurrent.ps1)
  submits the full batch immediately.
- [`example_waiting.ps1`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/examples/example_waiting.ps1)
  waits for each run to leave `QUEUED` before submitting the next.
- [`example_percent.ps1`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/examples/example_percent.ps1)
  does the same and also prints progress.

The scripts name runs with `label` and release them once finished.

[`tests/manual_daemon.nim`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/tests/manual_daemon.nim)
runs 20 copies of a deck through real TRNSYS; adjust its configuration for your
installation.

## See also

- [TRNRun Runner](https://github.com/NRCan/TRNRun/tree/main/components/trnrun):
  runs a single TRNSYS simulation and reports its lifecycle as a JSON Lines
  event stream.
- [TRNRun Queue](https://github.com/NRCan/TRNRun/tree/main/components/trnrunq):
  runs batches of simulations through a bounded pool of runners and merges
  their events into a single stream.
