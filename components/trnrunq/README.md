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
trnrunq --maxConcurrent:4 --maxPending:16
```

When omitted, `--maxConcurrent` defaults to one fewer than the available logical
processors, with a minimum of one. `--maxPending` defaults to `0`, which leaves
the pending channel unbounded. A positive value bounds that channel and blocks
the queue input thread while it is full.

### PowerShell examples

The repository includes two examples that expect both `trnrun.exe` and
`trnrunq.exe` to be built in their sibling `build` directories:

```powershell
cd ..\trnrun
nimble bin
cd ..\trnrunq
nimble bin

# Submit the complete workload immediately.
.\examples\example_concurrent.ps1

# Submit one request every two seconds.
.\examples\example_delayed.ps1
```

Both scripts create ten temporary copies of the sample deck, allow up to five
simultaneous runs, and pass `--guiVisibility=auto` and `--watchTmp=true` to
`trnrun.exe`. Edit the constants at the top of each script to change the copy
count, concurrency limit, or delayed submission interval.

## Request protocol

Write one JSON object per line to queue stdin:

```json
{"runId":"building-a","deckFile":"C:\\models\\building-a.dck","runnerPath":"C:\\bin\\trnrun.exe","runnerArgs":["--guiVisibility:auto","--watchTmp:true"]}
```

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `runId` | string | yes | Caller-generated routing identifier passed to `trnrun`; must be unique. |
| `deckFile` | string | yes | `.dck` or `.trd` file to run. |
| `runnerPath` | string | yes | Runner executable for this request. |
| `runnerArgs` | array of strings | no | Additional runner arguments. |

With `--maxPending:0`, requests are accepted as fast as they are written and
queued until a worker is free. A positive `--maxPending` allows that many accepted
requests in the pending channel. Further requests are not acknowledged until a
worker frees channel capacity. Running requests do not count toward the pending
limit.

EOF on stdin ends submission. Requests already accepted by the queue continue to
completion, after which queue stdout closes.

## Output protocol

Queue stdout is a line-oriented JSON protocol: every non-empty line is one JSON
object. After a request enters the worker pool, the queue writes and flushes an
acknowledgment:

```json
{"kind":"QUEUE","timestamp":"2026-06-19T19:37:15","event":"ACCEPTED","runId":"building-a"}
```

The acknowledgment means the queue parsed the request, secured pending-channel
capacity, and took ownership of it. A worker resolves and starts the runner,
which owns deck validation. A worker may emit runner events before
`QUEUE/ACCEPTED`, so wrappers
must register the `runId` before writing the request and route events independently
of acknowledgment order.

Every merged child stdout/stderr line is forwarded unchanged. `runnerPath` must
therefore reference a compatible `trnrun` executable that emits the documented
JSONL protocol and attaches the requested `runId`. For example:

```json
{"kind":"STATUS","timestamp":"2026-06-19T19:37:15","status":"RUNNING","message":"","seq":4,"runId":"building-a"}
```

`trnrunq` does not parse or reinterpret child output. This keeps the queue a thin
transport and leaves simulation-event ownership with `trnrun`.

After all child output, every accepted request receives exactly one completion
event:

```json
{"kind":"QUEUE","event":"COMPLETED","timestamp":"2026-06-19T19:37:17","runId":"building-a","exitCode":0}
```

`exitCode` is an integer when a child was launched and JSON `null` when runner
resolution or launch failed first. The queue does not interpret runner statuses;
wrappers
must verify that a valid terminal `STATUS` preceded completion. A silent child or
native crash therefore still completes, with its exit code available for wrapper
policy.

Output from different runs may be interleaved, but complete lines are never
mixed together and lines from one run retain their order. If validation or launch
fails, the queue emits a terminal `STATUS/ERROR` followed by `QUEUE/COMPLETED`.
The queue does not track identifiers; wrappers must provide a unique `runId` for
each request so interleaved events remain unambiguous.

There is no queue stderr protocol. Command-line and fatal process diagnostics may
be written there for humans, but wrappers must not parse stderr or use it as run
state.

## Wrapper responsibilities

A wrapper should:

1. Start one dedicated queue-stdout reader before submitting work.
2. Generate a unique `runId`, register it before writing the request, route all
   events by `runId`, and resolve submission waiters from `QUEUE/ACCEPTED`.
3. Generate and write requests incrementally rather than retaining the complete
   workload.
4. Set a positive `--maxPending` when submission backpressure is required, and
   keep reading stdout while the queue input thread is blocked on capacity.
5. Treat queue EOF before acknowledgment or completion as a run failure.
6. Close queue stdin after generating the final request.
7. Finalize each accepted run from its `QUEUE/COMPLETED` metadata, applying
   wrapper policy when no terminal status was observed.

## Concurrency model

`serve(maxConcurrent, maxPending)` creates a fixed pool of worker threads.
Requests cross a `Channel` that is unbounded when `maxPending` is `0`; a positive
value bounds accepted requests stored in the channel and blocks its input thread
while the channel is full. `QUEUE/ACCEPTED` is emitted after `send` secures channel
capacity; a worker may receive that request first. Workers write complete lines
under one output lock. At stdin EOF, one stop sentinel is queued after all
accepted requests and passed from worker to worker; channel order guarantees
every pending request runs before any worker stops. Circulating one sentinel also
prevents shutdown from filling a bounded pending channel.

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
