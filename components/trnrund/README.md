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
{"cmd":"changes","since":0}
{"cmd":"remove","runId":"1"}
{"cmd":"shutdown"}
```

Each reply contains `ok`. Failed requests contain `error`.

Poll with `changes`. Every change to a simulation, including its submission,
gets the next `revision`, a counter that only grows. `changes` returns the
current `revision` and the `simulations` changed after `since`, each with only
the `logs` that arrived after it. Pass the `revision` of the previous reply as
the next `since`, and each poll costs what changed, not the number of runs:

```json
{"ok":true,"revision":42,"simulations":[{"runId":"1","state":"RUNNING","revision":42,"logStart":3,"logs":[...],...}]}
```

Every simulation in a reply reports the `logStart` index of its `logs`, so a
client can place them; asking again from an older `since` repeats entries but
never skips one, and `since` 0, the default, returns everything. Once a
simulation shows `state == "FINISHED"`, it holds the final logs, and `remove`
frees the run. The `succeeded` field distinguishes success from other finished
outcomes. See [`src/protocol.nim`](src/protocol.nim) for request fields and
defaults.

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
