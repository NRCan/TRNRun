# TRNRun daemon

`trnrund` is a Windows daemon that runs TRNRun simulations for one client. A
fixed worker pool executes simulations while the scheduler owns their state
and limits concurrency.

## Build and test

Requires Nim 2.2.10 or later and a configured C compiler for tests. Release
builds use Zig, which must be on `PATH`. Run these commands from this directory:

```sh
nimble test
nimble bin
```

`nimble test` builds a fake TRNRun child, the daemon, and all test executables
under `build/tests`, then runs the CLI, validation, simulation, protocol,
scheduler, worker-pool, and executable integration suites. Tests do not require
TRNSYS. `nimble bin` builds the release executable at `build/trnrund.exe`.

`nimble dist` assembles a distributable package; `nimble deploy` also copies it
to the repository's MATLAB and Python manager directories.

## Usage

```sh
build/trnrund.exe --trnrun:C:/path/to/trnrun.exe --maxConcurrent:2
```

By default, the daemon uses `trnrun.exe` beside its executable and runs at most
`max(CPUs - 1, 1)` simulations concurrently. Explicit relative TRNRun paths and
relative deck paths resolve from the daemon's working directory. Decks must be
existing `.dck` or `.trd` files; extensions are case-insensitive.

The client sends one JSON object per stdin line and receives one JSON reply
per stdout line, in request order:

```json
{"cmd":"add","runId":"1","deckFile":"model.dck"}
{"cmd":"snapshot","runId":"1"}
{"cmd":"collect","runId":"1"}
{"cmd":"shutdown"}
```

Each reply contains `ok`. Failed requests contain `error`; successful snapshot
and collect requests contain `simulation`, and collect also contains `logs`.
Wait for `simulation.state == "FINISHED"` before collecting a run. The
`succeeded` field distinguishes success from other finished outcomes.

Other commands are `snapshots`, `logs`, and `remove`. See
[`src/protocol.nim`](src/protocol.nim) for request fields and slicing semantics.

## Shutdown and failures

- The `shutdown` command acknowledges immediately, cancels runs not yet
  dispatched, waits for submitted runs to finish, and joins the workers.
- Closing stdin exits immediately, without waiting for running simulations.
- A kill-on-close Windows Job Object terminates remaining TRNRun descendants
  when the daemon exits.
- Startup and fatal diagnostics go to stderr; stdout is reserved for replies
  while serving requests. Exit codes are `0` for normal exit, `1` for fatal
  failures, and `2` for invalid options or startup validation errors.

Running simulations cannot be cancelled through the protocol. Graceful
shutdown can therefore wait indefinitely for TRNRun. Channels intentionally
remain open because of the documented Nim 2.2 ORC channel-close workaround.
