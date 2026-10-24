# TRNRun Daemon 2

`trnrund2.exe` runs TRNSYS simulations through `trnrun.exe` for one client,
with at most `--workers` running at once and the rest queued. Simulation state
lives in memory only.

```
trnrund2 [options]
```

| Option          | Meaning                                                        |
| --------------- | -------------------------------------------------------------- |
| `-h, --help`    | Show help and exit                                             |
| `-v, --version` | Show version and exit                                          |
| `--trnrun:PATH` | TRNRun executable (default: `trnrun.exe` beside trnrund2)      |
| `--workers:N`   | Simulations run at once, at least 1 (default: `max(CPUs - 1, 1)`) |

Exit codes: `0` stdin closed (or help/version shown), `1` fatal error, `2` bad
command line or missing TRNRun.

## Protocol

The client writes one JSON request per line to stdin, then reads exactly one
JSON response line from stdout before sending the next request. stdout carries
nothing else; diagnostics go to stderr. Closing stdin cancels every simulation
and exits. If the daemon itself dies, even by crashing, Windows kills
every TRNRun and TrnEXE it started.

Every response has `ok`. When `ok` is `false` it also has `error`, a message
for humans.

| Request                                   | Response when `ok` is true             |
| ----------------------------------------- | -------------------------------------- |
| `{"cmd":"ready"}`                         | `{"ok":true}`                          |
| `{"cmd":"add","deckFile":"C:/run/a.dck"}` | `{"ok":true,"simId":1}`                |
| `{"cmd":"get","simId":1}`                 | `{"ok":true,"simulation":{...}}`       |
| `{"cmd":"list","state":"RUNNING"}`        | `{"ok":true,"simulations":[{...}]}`    |
| `{"cmd":"cancel","simId":1}`              | `{"ok":true}`                          |
| `{"cmd":"release","simId":1}`             | `{"ok":true}`                          |

- `add` accepts an existing `.dck` or `.trd` file, relative paths resolved
  from the daemon's working directory, plus optional `label` (string) and
  `trnrunArgs` (TRNRun options such as `["--guiVisibility:min"]`). Each option
  is checked against TRNRun's own option parser, so an unknown option or bad
  value is refused at `add`. A deck path, `--deckFile`, `--help` and
  `--version` are refused too. `add` answers once the simulation is queued,
  which is not when it starts or finishes. A simId is never reused.
- `cancel` stops a `QUEUED` or `RUNNING` simulation; it refuses one that is
  `FINISHED` or unknown.
- `release` forgets a `FINISHED` simulation and its logs; it refuses one that
  is still `QUEUED` or `RUNNING` (cancel it first) or unknown.
- `get` refuses an unknown simId.
- `list` returns every simulation not released yet in `state` (`QUEUED`,
  `RUNNING` or `FINISHED`), oldest first, each as `get` returns it but without
  its `logs` key; the log counts stay. Add `"withLogs":true` to include logs.
  Polling `list` with `FINISHED`, then releasing what it returns, collects a
  batch in one request per poll; use `get` or `withLogs` for the logs you need.

## Simulations

`get` returns every field below. A value TRNRun has not reported yet is `null`.

```json
{"simId":1,"label":null,"state":"FINISHED","trnrunStatus":"DONE",
 "trnrunMessage":"","percent":1.0,"simTime":8760.0,"elapsedMs":5321.0,
 "etaMs":0.0,"notices":2,"warnings":1,"fatals":0,"succeeded":true,"exitCode":0,
 "error":null,"submittedAt":"2026-10-22T14:03:12.345Z",
 "startedAt":"2026-10-22T14:03:12.351Z","finishedAt":"2026-10-22T14:03:17.702Z",
 "deckFile":"C:\\run\\a.dck","trnrunArgs":[],"startTime":0.0,"stopTime":8760.0,
 "timeStep":1.0,"setting":{...},"logs":[{"severity":"Warning","time":12.0,
 "unitId":5,"typeId":56,"messageCode":null,"message":"...","information":null}]}
```

| Field | Meaning |
| ----- | ------- |
| `state` | `QUEUED` waiting for a worker, `RUNNING` TRNRun started, `FINISHED` done, failed or cancelled |
| `succeeded` | Set once `FINISHED`: true only with TRNRun status `DONE`, exit code 0 and no `error` |
| `trnrunStatus`, `trnrunMessage` | TRNRun's last status; `CANCELLED` when cancelled, `ERROR` when TRNRun could not start or exited without a final status |
| `percent`, `simTime`, `elapsedMs`, `etaMs` | Last TRNRun progress; `percent` is in `[0, 1]`, times in simulation hours |
| `startTime`, `stopTime`, `timeStep` | Simulation period, in simulation hours |
| `notices`, `warnings`, `fatals`, `logs` | TRNSYS log entries, counted and kept oldest first |
| `setting` | TRNRun settings applied to the run |
| `exitCode` | TRNRun's exit code; `null` if it was cancelled or never started |
| `error` | Why the daemon failed or cancelled the run, such as `Interrupted: cancelled by the client` |
| `submittedAt`, `startedAt`, `finishedAt` | UTC ISO 8601 timestamps |

## Layout

| Path                 | Role                                                       |
| -------------------- | ---------------------------------------------------------- |
| `src/trnrund2.nim`   | Entry point and the serve loop tying client and scheduler       |
| `src/cli.nim`        | Parses the command line: options, help and version         |
| `src/pipe.nim`       | stdin reader thread and stdout responses                   |
| `src/protocol.nim`   | Request line to response line; all JSON lives here         |
| `src/validate.nim`   | Checks deck and TRNRun paths, and `trnrunArgs`             |
| `src/scheduler.nim`       | Queue, worker limit, which simulation runs where           |
| `src/trnrun.nim`     | Launches one TRNRun, reads its output lines, kills it      |
| `src/job.nim`        | Kill-on-close Job Object: TRNRun never outlives the daemon |
| `src/simulation.nim` | One simulation's record and how events and exits update it |
| `src/events.nim`     | Parses TRNRun's JSON event lines                           |

## Build, tests and examples

```
nimble build   # build/trnrund2.exe
nimble test
```

Tests use the test executable itself as a fake TRNRun; no TRNSYS needed.

The PowerShell scripts in `examples/` drive `build/trnrund2.exe` with
`../trnrun/build/trnrun.exe` and TRNSYS 18, running 10 copies of a sample deck
5 at a time:

- `example_concurrent.ps1` adds every simulation at once and lets the daemon queue them.
- `example_waiting.ps1` adds the next one only once the previous has started.
- `example_percent.ps1` does the same while printing each simulation's progress.
