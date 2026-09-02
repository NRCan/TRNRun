# TRNRun Queue 3

`trnrunq3` supervises multiple `trnrun.exe` processes with bounded concurrency
and combines their JSON Lines output into one routed stream.

Simulation semantics, options, and outcomes remain owned by `trnrun`. The queue
adds `runId` to each runner event and emits a small `exit` message when that
process ends. Non-JSON lines from the merged child stream are written to stderr.

## Usage

```powershell
trnrunq3 model-a.dck model-b.dck --maxConcurrent:2 --watchTmp:true
```

`--runnerPath` and `--maxConcurrent` configure the queue. Every other option is
forwarded unchanged to each `trnrun` process. Relative runner paths resolve
beside `trnrunq3.exe`.

Use `--` before runner arguments when an argument would otherwise be interpreted
as a queue option such as `--help`:

```powershell
trnrunq3 model.dck -- --help
```

Each active run owns one worker thread because Windows anonymous pipes require a
blocking reader. `src/trnrun.nim` owns one child's process lifecycle and output
stream, while `src/supervisor.nim` schedules runs through one bounded channel.
The coordinator is the sole writer of queue stdout.

## Protocol

A runner event remains top-level and receives only queue routing metadata:

```json
{"kind":"PROGRESS","percent":0.5,"seq":8,"runId":1}
```

Runner `seq` values remain local to each run. The physical JSONL order is the
combined queue order; the queue does not add another sequence number.

Process completion after producing at least one event:

```json
{"type":"exit","runId":1}
```

Queue infrastructure failure or a process that produced no valid event:

```json
{"type":"exit","runId":1,"message":"TRNRun not found: '...'"}
```

The queue intentionally ignores numeric child exit codes. Runner events are the
source of truth for simulation outcomes. A non-JSON child line is treated as a
merged stderr diagnostic and written as `[run N] ...` to queue stderr.

The same normalized, case-insensitive deck path cannot run twice in one queue,
because concurrent runners would race on their shared sidecar files. A rejected
duplicate receives its own failed `exit` message.

Clients should apply runner events to the corresponding `runId` and finalize
process bookkeeping on `exit`. If an exit arrives without a terminal runner
`STATUS`, the client should produce a local `ERROR` for that simulation. If the
queue process itself exits unexpectedly, the client should fail every run that
has not yet received an `exit` message.

## Single-run smoke test

Compile `src/trnrun.nim` as the main module:

```powershell
nim c -r -o:build/trnrun-smoke.exe src/trnrun.nim
```

The local runner path is declared as a raw string in the smoke-test block. The
test launches `examples/dck/example_w_plot_w_tracking.dck` with temporary-file
watching enabled and prints runner output.

## Validation

```powershell
nimble test
```
