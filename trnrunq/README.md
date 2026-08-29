# TRNRun Queue

`trnrunq.exe` runs multiple `trnrun.exe` simulations with a bounded concurrency
limit and combines their event streams into one JSON Lines stream. Consumers do
not need to create threads, supervise child processes, or merge their output.

## Build

Install Nim 2.2.10 or newer and Zig, then run:

```powershell
nimble bin
```

## Usage

```powershell
trnrunq model-a.dck model-b.dck --maxConcurrent:2 --watchTmp:true
```

Queue options are consumed by `trnrunq`; all other options are forwarded to
every runner:

```text
--runnerPath:PATH     trnrun.exe path; defaults to trnrun.exe beside trnrunq
--maxConcurrent:N    maximum simultaneous runner processes
```

Decks are positional arguments. Use `--` before runner arguments only when an
argument would otherwise be interpreted as a deck:

```powershell
trnrunq model-a.dck model-b.dck -- --watchTmp:true
```

## Output contract

Every stdout line is a JSON object. Human-readable diagnostics go to stderr.
Child events retain their runner-local `seq` and receive three routing fields:

- `jobId`: stable identifier assigned in input order, starting at `1`.
- `deckFile`: normalized absolute deck path.
- `queueSeq`: global ordering in the combined queue stream.

The queue emits `QUEUED` before a valid job reaches a worker. Runner events then
report `PENDING`, `LAUNCHING`, `RUNNING`, and a terminal status.

Terminal statuses are:

- `DONE`
- `CANCELLED`
- `ERROR`
- `TIMEOUT`
- `STALLED`

Every accepted job produces exactly one terminal status while `trnrunq` remains
alive. If a runner cannot start, crashes, or exits without a terminal event,
`trnrunq` emits an `ERROR` status on its behalf.

Example combined output:

```json
{"kind":"STATUS","timestamp":"2026-08-29T12:00:00","status":"QUEUED","source":"trnrunq","jobId":"1","deckFile":"C:\\models\\a.dck","queueSeq":1}
{"kind":"STATUS","timestamp":"2026-08-29T12:00:00","status":"PENDING","seq":2,"jobId":"1","deckFile":"C:\\models\\a.dck","queueSeq":3}
{"kind":"PROGRESS","timestamp":"2026-08-29T12:00:05","percent":0.5,"seq":8,"jobId":"1","deckFile":"C:\\models\\a.dck","queueSeq":15}
{"kind":"STATUS","timestamp":"2026-08-29T12:00:10","status":"DONE","exitCode":0,"seq":14,"jobId":"1","deckFile":"C:\\models\\a.dck","queueSeq":27}
```

Queue-owned failures carry a human-readable `error` message:

```json
{"kind":"STATUS","timestamp":"2026-08-29T12:00:00","status":"ERROR","source":"trnrunq","exitCode":2,"error":"Deck file does not exist: 'C:\\models\\missing.dck'","jobId":"2","deckFile":"C:\\models\\missing.dck","queueSeq":4}
```

The queue rejects duplicate normalized deck paths because concurrent runs would
race on the same `.tmp`, `.log`, `.lst`, `.PTI`, and optional `.jsonl` sidecars.

## Exit codes

| Code | Meaning |
| ---: | ------- |
| `0` | Every job completed with `DONE`. |
| `1` | At least one job completed unsuccessfully. |
| `2` | Invalid `trnrunq` command usage. |
