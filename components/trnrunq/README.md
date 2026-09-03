# TRNRun Queue

`trnrunq.exe` is a standalone, bounded-concurrency launcher for `trnrun.exe`. It
reads requests incrementally from stdin, so a wrapper can generate any number of
simulations without building the complete workload in memory.

## Requirements

- Windows.
- A compatible `trnrun.exe` executable.

## Installation

The queue is written in [Nim](https://nim-lang.org/) and built as a standalone
executable. To build it from source, install Nim 2.2.10 or newer and
[Zig](https://ziglang.org/download/), then run from the `trnrunq` directory:

```powershell
nimble bin
```

Use `nimble dist` to also assemble the executable, README, and license under
`dist/`.

## Usage

```powershell
trnrunq --maxConcurrent:4
```

When omitted, `--maxConcurrent` defaults to one fewer than the available logical
processors, with a minimum of one.

## Request protocol

Write one JSON object per line to queue stdin:

```json
{"runId":"building-a","deckFile":"C:\\models\\building-a.dck","runnerPath":"C:\\bin\\trnrun.exe","runnerArgs":["--watchTmp:true"]}
```

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `runId` | string | yes | Opaque identifier passed to `trnrun`. |
| `deckFile` | string | yes | `.dck` or `.trd` file to run. |
| `runnerPath` | string | yes | Runner executable for this request. |
| `runnerArgs` | array of strings | no | Additional runner arguments. |

Requests are accepted as fast as they are written and queued until a worker is
free, so submission never waits on execution. A wrapper that needs to bound its
own memory can submit one request and wait for its initial runner `STATUS`
before generating the next, while still allowing up to `--maxConcurrent`
simulations to run.

EOF on stdin ends submission. Requests already accepted by the queue continue to
completion, after which queue stdout closes.

## Output protocol

Every merged child stdout/stderr line is forwarded unchanged to queue stdout.
For example:

```json
{"kind":"STATUS","timestamp":"2026-06-19T19:37:15","status":"RUNNING","message":"","seq":4,"runId":"building-a"}
```

Output from different runs may be interleaved, but complete lines are never
mixed together and lines from one run retain their order. The queue does not
parse child output, add completion events, reject duplicate submissions, require
output, or interpret child exit codes. If a request cannot launch its runner,
the queue emits a terminal `STATUS/ERROR` event for that `runId`.

There is no queue stderr protocol. Command-line and fatal process diagnostics may
still be written to stderr for humans, but wrappers must not use them as run
results. A wrapper must reconcile any run without a terminal status when queue
stdout reaches EOF.

## Wrapper responsibilities

A wrapper should:

1. Start one dedicated queue-stdout reader before submitting work.
2. Route valid runner events to simulations by `runId`.
3. Generate and write requests incrementally rather than retaining the complete
   workload.
4. Wait for an initial `RUNNING` or `ERROR` status when submission backpressure
   is required. Waiting for terminal `DONE` before submitting the next request
   would make execution sequential.
5. Close queue stdin after generating the final request.
6. Continue reading stdout through EOF and mark runs without terminal statuses
   according to wrapper policy.

## Concurrency model

`serve(maxConcurrent)` creates a fixed pool of worker threads. Requests cross an
unbounded `Channel`, and workers write child lines under one output lock. At
stdin EOF, one stop sentinel per worker is queued after all accepted requests;
channel order guarantees every pending request runs before any worker stops.

One thread per concurrent run is required rather than chosen: `osproc` exposes
child stdout as a blocking read on an anonymous pipe, which supports neither
`select` nor Windows IOCP, so following N children concurrently needs N blocked
readers.

The channel is deliberately not closed explicitly. Nim 2.2 with ORC can crash
when closing a `Channel` that transported moved strings, so process teardown
reclaims this process-lifetime channel.

## Validation

Run the automated tests:

```powershell
nimble test
```

For a manual integration run against installed TRNSYS, build both executables
and run 50 staged copies of the slow deck with a concurrency limit of 5:

```powershell
cd ..\trnrun
nimble bin
cd ..\trnrunq
nimble bin
nim r tests/manual_queue.nim
```

Edit the constants at the top of `tests/manual_queue.nim` to change the TRNSYS
executable, source deck, copy count, concurrency, or runner settings.
