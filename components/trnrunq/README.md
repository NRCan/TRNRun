# TRNRun Queue

`trnrunq.exe` is a Windows process supervisor for running batches of TRNSYS
simulations through [TRNRun Runner](../trnrun/). It reads JSON Lines requests
from stdin, dispatches them to a bounded worker pool, and writes all queue and
simulation events to one stdout stream. Its responsibilities are to:

- accept simulation requests incrementally without loading the full batch
- limit the number of `trnrun.exe` processes running at the same time
- report when each request is accepted and completed
- forward runner events unchanged and identify each run by `runID`

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Settings](#settings)
- [Request protocol](#request-protocol)
- [Output protocol](#output-protocol)
- [Exit codes](#exit-codes)
- [Examples](#examples)

## Requirements

### Runtime

- Windows x64
- [`trnrun.exe`](../trnrun/) executable
- TRNSYS 17 or 18 for actual simulation runs

### Development

- [Nim](https://nim-lang.org/install.html) 2.2.10 or newer
- [Zig](https://ziglang.org/download/) as the Windows C compiler and resource
  compiler
- [just](https://github.com/casey/just) for repository-root recipes

## Installation

Download and extract `trnrunq-v<version>-win_amd64.zip` from
[GitHub Releases](https://github.com/NRCan/TRNRun/releases). The queue does not
bundle the runner; install `trnrun.exe` separately and provide its path in each
request.

Or build from source, run the following from the repository root:

```powershell
Set-Location components/trnrunq
nimble bin
```

The executable is written to `components/trnrunq/build/trnrunq.exe` relative to
the repository root.

## Quick start

### Single run

Create one request, serialize it as a JSON line, and pipe it into the queue:

```powershell
$Request = @{
    runID = 'building-a'
    deckFile = 'C:\models\building-a.dck'
    runnerPath = 'C:\bin\trnrun.exe'
    runnerArgs = @('--watchTmp:true')
}
$RequestJson = ConvertTo-Json -InputObject $Request -Compress

$RequestJson | trnrunq
```

### Batch

Generate one request per deck and limit the batch to four simultaneous runs:

```powershell
$Decks = Get-ChildItem 'C:\models\*.dck'

$RequestsJson = foreach ($Deck in $Decks) {
    $Request = @{
        runID = $Deck.BaseName
        deckFile = $Deck.FullName
        runnerPath = 'C:\bin\trnrun.exe'
        runnerArgs = @('--watchTmp:true')
    }
    ConvertTo-Json -InputObject $Request -Compress
}

$RequestsJson | trnrunq --maxConcurrent:4
```

For option and version information:

```powershell
trnrunq --help
trnrunq --version
```

## Settings

Options accept either `--name:value` or `--name=value`.

- _`--maxConcurrent`_ (`integer`, default: `max(logical processors - 1, 1)`)

  Maximum number of runner processes active at once. The value must be at least
  `1`.

## Request protocol

Write one JSON object per line to queue stdin:

```json
{"runID":"building-a","deckFile":"C:\\models\\building-a.dck","runnerPath":"C:\\bin\\trnrun.exe","runnerArgs":["--guiVisibility:auto","--watchTmp:true"]}
```

- _`runID`_ (`string`, required)

  Non-empty caller-generated identifier used to route all events for the
  request.

- _`deckFile`_ (`string`, required)

  Path to an existing `.dck` or `.trd` file.

- _`runnerPath`_ (`string`, required)

  Path to the compatible runner executable used for this request.

- _`runnerArgs`_ (`array of strings`, default: `[]`)

  Additional command-line arguments forwarded to the runner.

EOF on stdin ends submission. All successfully submitted requests, including the
request waiting in the handoff slot, are picked up and run to completion before
queue stdout closes.

### Acceptance and backpressure

A request is acknowledged only when a worker picks it up:

```text
stdin → one-slot handoff → QUEUE/ACCEPTED → runner → QUEUE/COMPLETED
```

`QUEUE/ACCEPTED` confirms worker pickup only. It does not confirm that the deck
or runner exists, that the runner launched, or that the simulation started.

## Output protocol

Queue lifecycle events and merged child output are written to stdout one complete
line at a time and flushed immediately. Output from different runs may
interleave, but lines are never mixed together and lines from a single runner
retain their order.


### `QUEUE` events

The queue emits two lifecycle events for each request:

- `ACCEPTED` when a worker picks up the request
- `COMPLETED` after the runner exits or a pre-launch failure occurs

```json
{"kind":"QUEUE","event":"ACCEPTED","timestamp":"2026-06-19T19:37:15","runID":"building-a"}
{"kind":"QUEUE","event":"COMPLETED","timestamp":"2026-06-19T19:37:17","runID":"building-a","exitCode":0}
```

Both events contain `kind`, `event`, `timestamp`, and `runID`. `COMPLETED` also
contains the runner's `exitCode`, or `null` if the runner could not be launched.
A completed request is not necessarily a successful simulation; use the runner's
terminal `STATUS` and [exit code](../trnrun/#exit-codes) to determine the outcome.

### Runner events

Between `ACCEPTED` and `COMPLETED`, child output is forwarded unchanged. Valid
runner events use the schemas documented by
[TRNRun Runner](../trnrun/#output-protocol) and include the request's `runID`.
If validation or launch fails, the queue emits a synthetic `STATUS/ERROR` event
and completes the request with `exitCode:null`.

### Example stream

Events for concurrent requests may interleave:

```json
{"kind":"QUEUE","event":"ACCEPTED","timestamp":"2026-06-19T19:37:13","runID":"building-a"}
{"kind":"QUEUE","event":"ACCEPTED","timestamp":"2026-06-19T19:37:13","runID":"building-b"}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:14","status":"RUNNING","message":"","seq":4,"runID":"building-a"}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:14","status":"RUNNING","message":"","seq":4,"runID":"building-b"}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:16","status":"DONE","message":"","seq":8,"runID":"building-b"}
{"kind":"QUEUE","event":"COMPLETED","timestamp":"2026-06-19T19:37:16","runID":"building-b","exitCode":0}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:17","status":"DONE","message":"","seq":9,"runID":"building-a"}
{"kind":"QUEUE","event":"COMPLETED","timestamp":"2026-06-19T19:37:17","runID":"building-a","exitCode":0}
```

## Exit codes

| Exit code | Meaning |
| --- | --- |
| `0` | The queue read stdin to EOF and drained all submitted requests. Help and version also return `0`. Individual runners may still have failed. |
| `1` | Queue infrastructure or another unexpected fatal failure. |
| `2` | Invalid queue option, invalid concurrency, positional argument, or malformed request input. |

Runner exit codes do not become the queue process exit code. Inspect each
`QUEUE/COMPLETED.exitCode` and terminal runner `STATUS` instead.

## Examples

PowerShell examples are available in [`examples`](examples). They expect
`build/trnrunq.exe` and `../trnrun/build/trnrun.exe` to exist and use the default
TRNSYS 18 executable path.

- [`example_concurrent.ps1`](examples/example_concurrent.ps1) submits the full
  batch immediately.
- [`example_delayed.ps1`](examples/example_delayed.ps1) submits one request every
  two seconds.

Both scripts create ten temporary deck copies, allow up to five simultaneous
runs.
