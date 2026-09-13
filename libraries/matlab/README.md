# TRNRun for MATLAB

The TRNRun MATLAB client submits, monitors, and inspects TRNSYS simulations
through the native `trnrunq.exe` and `trnrun.exe` backend. Each
`trnrun.SimulationManager` owns one queue process; the queue provides bounded
concurrency and the manager routes JSON Lines events to MATLAB
`trnrun.Simulation` objects.

## Support status and requirements

- Windows x64
- MATLAB R2021a or newer as a **provisional release floor**
- TRNSYS 17 or 18
- Optional: separately installed Progress Tracker (Type3830) for progress and
  stall monitoring

R2021a compatibility is a target, not a runtime-verified compatibility claim.
The client requires neither Python nor additional MATLAB toolboxes. It is
intended for both desktop MATLAB and noninteractive `matlab -batch` use; the API
does not require a MATLAB GUI.

## Installation

Install the released `TRNRun.mltbx` by opening it in MATLAB. For a source
checkout, add only the `toolbox` directory to the MATLAB path:

```matlab
addpath("C:\path\to\TRNRun\libraries\matlab\toolbox")
```

Do not use `genpath` and do not add `+trnrun`, `bin`, `examples`, or test
directories separately. MATLAB discovers the `+trnrun` package from its parent
directory. A distributed copy resolves its bundled Windows x64 executables
relative to this library rather than relative to the current directory.

To make the path change persistent, put the same `addpath` call in a MATLAB
startup file or use MATLAB's path-management UI.

## Quick start

Use function scope so the cleanup guard runs deterministically:

```matlab
function simulation = run_deck(deck_path)
    matlab_library = "C:\path\to\TRNRun\libraries\matlab\toolbox";
    addpath(matlab_library)

    config = trnrun.SimulationConfig(watch_tmp=false);
    manager = trnrun.SimulationManager(maxConcurrent=1);
    cleanup = onCleanup(@() delete(manager));

    simulation = manager.add(deck_path, config);
    manager.wait();
    manager.shutdown();

    if simulation.succeeded
        fprintf("Completed: %s\n", char(string(simulation.deckPath)));
    else
        fprintf("Failed: %s\n", char(string(simulation.deckPath)));
    end
end
```

`shutdown()` is the normal drain-and-finish path. The `onCleanup` guard is the
fallback for an error or interruption. A successful shutdown is idempotent, so
the later `delete(manager)` call is safe.

## Execution model and backpressure

The MATLAB client is synchronous and does not update simulations in the
background. The calling MATLAB thread pumps queue output only during:

- `manager.add(...)`, until that request receives `QUEUE/ACCEPTED`;
- `manager.wait(...)`, until the selected run or all accepted runs complete; and
- `manager.follow(callback)`, until all accepted runs complete.

`QUEUE/ACCEPTED` means a queue worker picked up the request; it does not mean
TRNSYS launched successfully. `add()` can therefore block when every worker is
occupied. While `wait(simulation)` waits for one manager-owned run, it still
applies updates for the manager's other runs.

Do not poll a `Simulation` with long `pause` calls instead of pumping the
manager. Long gaps between manager calls can fill the queue's stdout pipe and
stall queue and runner progress. The same backpressure can occur when a
`follow` callback is slow. Keep callbacks short and do not call manager methods
from a callback; reentrant manager operations are rejected. Drive a manager
from one MATLAB thread.

## Type3830 and progress tracking

Type3830 is optional and is installed separately from this client. It writes a
`*.tmp` snapshot containing simulation `TIME`, `START`, `STOP`, and `STEP`.
TRNRun reads that file when `watch_tmp=true` and emits `CONFIG` and `PROGRESS`
events.

For a deck that contains a working Type3830:

```matlab
config = trnrun.SimulationConfig( ...
    watch_tmp=true, ...
    wait_for_tmp=true, ...
    stall_timeout_ms=300000, ...
    kill_on_stall=true);
```

For a deck without Type3830, leave `watch_tmp=false`, `wait_for_tmp=false`, and
`stall_timeout_ms=0`. Without a successfully parsed Type3830 snapshot:

- `progress` and `configEvent` remain empty (`[]`);
- stall detection is inactive, even if `stall_timeout_ms` is positive;
- `STALLED` and progress-derived `CANCELLED` outcomes cannot be detected; and
- an otherwise non-fatal early exit can be reported as `DONE`; a fatal TRNSYS
  log entry can still produce `ERROR`.

Setting `wait_for_tmp=true` for a deck without Type3830 causes launch detection
to wait until `detect_timeout_ms` expires (or indefinitely when it is `0`).

`progress.percent` is a fraction from `0` to `1`. `progress.elapsed` and
`progress.eta` are milliseconds; convert them only when formatting output.

## Timeouts, stalls, and process termination

Timeout and stall settings report conditions; they do not necessarily bound a
blocking manager call.

- `detect_timeout_ms` defaults to `300000` ms and is shared by launch-readiness
  checks. `0` means unlimited. Detection holds the machine-wide launch mutex, so
  an unlimited deadline can let a wedged deck delay other launches.
- `watch_timeout_ms` defaults to `0` (unlimited).
- `stall_timeout_ms` defaults to `0` (disabled) and requires `watch_tmp=true`
  plus a successfully parsed Type3830 snapshot.
- `kill_on_timeout=false` means detection continues into runtime monitoring
  after a detection timeout; after a watch timeout, the runner waits for TRNSYS
  to exit.
- `kill_on_stall=false` means a stalled runner waits for TRNSYS to exit.
- Enable `kill_on_timeout=true` or `kill_on_stall=true` when the corresponding
  condition should terminate the owned TRNSYS process.

A runner terminal `STATUS` can therefore arrive before `QUEUE/COMPLETED`.
`isFinished` becomes true only when completion is received, and queue capacity
is not released early. `wait()` and normal `shutdown()` have no client-side
timeout and can wait indefinitely when a timed-out or stalled process is not
killed.

## Cleanup and object lifetime

Call `manager.shutdown()` on the normal path. It closes queue input, drains all
remaining output, waits for submitted work, and reaps the queue process. After a
successful shutdown:

- another `shutdown()` is harmless;
- new submissions are rejected; and
- simulations and result snapshots remain readable.

`delete(manager)` is non-throwing, best-effort resource cleanup. If graceful
shutdown did not happen, deletion may terminate the manager's owned queue and
its descendants, including unfinished TRNSYS runs. It does not kill unrelated
TRNSYS processes by executable name. Use `onCleanup(@() delete(manager))` to
preserve an original MATLAB exception while providing this fallback.

Function scope matters: the cleanup guard is destroyed predictably when the
function returns or unwinds. Leaving a manager and guard in the base workspace
and clearing them later is not a substitute for normal `shutdown()`.

## API naming

Public class names match the Python client. `Simulation` properties and methods
use `camelCase`, including `deckPath`, `isFinished`, `applyEvent`, and `logTable`.
Its log-table columns also use camelCase. Manager options and properties use
camelCase; `SimulationConfig` options retain `snake_case`. MATLAB constructors
use name-value arguments:

```matlab
config = trnrun.SimulationConfig(watch_tmp=true, severity="Warning");
manager = trnrun.SimulationManager(maxConcurrent=4, refreshInterval=0.5);
```

Use `watch_tmp` for configuration and `maxConcurrent`, `refreshInterval`, and
`trnrunqPath` for manager options. Read manager diagnostics through
`sessionDiagnostics`. The former snake_case manager options/properties and
`Simulation` member names have been replaced, not aliased; callers must migrate
to camelCase. Event payload names
and the internal Display API remain unchanged.

Shared `Simulation` members follow Python's terminology with camelCase spelling:
`completion_event` → `completionEvent`, `has_terminal_status` → `hasTerminalStatus`,
and `mark_completed` → `markCompleted`. Names such as `status`, `progress`, `logs`,
and `succeeded` are identical. Constructor arguments likewise map `deck_path`
and `sim_id` to `deckPath` and `simId`. Unlike Python, MATLAB imposes no log limit.
All public simulation properties are readable by callers; stored values have
private write access, while derived values are computed by getters. MATLAB stores
all logs directly in a struct array and provides table helpers rather than
duplicating Python's private backing fields or containers.

Paths may be MATLAB strings or character vectors. Relative deck and executable
paths are resolved against the caller's current working directory at submission
time. Configuration is a value object: every submission receives an independent
snapshot, so later caller changes do not alter an accepted run. Simulations are
handle objects and reflect updates applied by their manager. Event structs and
log snapshots are returned by value.

## `trnrun.SimulationManager`

```matlab
manager = trnrun.SimulationManager( ...
    maxConcurrent=4, ...
    refreshInterval=1.0);
```

| Option | Default | Description |
| --- | --- | --- |
| `maxConcurrent` | logical processor count minus one, at least `1` | Maximum number of active runners owned by the queue. |
| `refreshInterval` | `1.0` | Minimum seconds between Command Window redraws while calls pump events. A non-positive value disables built-in rendering. |
| `trnrunqPath` | bundled `bin/trnrunq.exe` | Queue executable override, primarily for development and testing. |

| Member | Description |
| --- | --- |
| `add(deckFile, config)` | Validate and submit one deck, wait for worker acceptance, and return its `Simulation`. |
| `wait()` | Pump events until every accepted run receives queue completion. It has no client-side timeout. |
| `wait(simulation)` | Pump all events until one owned simulation completes. Rejects a simulation from another manager. |
| `follow(callback)` | Apply each new update, then invoke the callback with the updated simulation. Updates already consumed are not replayed. |
| `simulations` | Accepted simulations in submission order. |
| `succeeded` | Completed simulations whose latest terminal status is exactly `DONE`. |
| `failed` | Completed simulations that did not succeed. |
| `sessionDiagnostics` | Read-only string array of retained session diagnostics (up to 200 entries). |
| `shutdown()` | Close input, drain output, finish remaining work, and reap the queue. |

The default concurrency uses Windows `NUMBER_OF_PROCESSORS`, independently of
MATLAB's computational-thread limit, and falls back to one runner if unavailable.
Input validation uses MATLAB's built-in validation errors. Passing an empty
`trnrun.Simulation` array to `wait` is equivalent to omitting the argument.

Each manager owns a separate live queue. Python and MATLAB use the same native
backend implementation, but they do not share a queue process or manager state.
Do not run two clients against the same physical deck at the same time because
its `.tmp`, `.log`, `.lst`, and other sidecar files can collide.

## `trnrun.Simulation`

| Property | Description |
| --- | --- |
| `id` | Manager-local numeric simulation ID; the wire `runID` is kept as a string. |
| `deckPath` | Absolute submitted deck path. |
| `config` | Independent configuration snapshot for this run. |
| `status` | Latest status event, or `[]`. |
| `progress` | Latest progress event, or `[]`. Requires Type3830 monitoring. |
| `configEvent` | Latest simulation start/stop/step event, or `[]`. |
| `settingEvent` | Latest normalized runner settings event, or `[]`. |
| `completionEvent` | `QUEUE/COMPLETED` event, or `[]` if completion was not received. Its `exitCode` is `NaN` when the wire value is null or omitted. |
| `logs` | All log events, oldest first, with no retention limit. |
| `logCount` | Total log events received. |
| `notices`, `warnings`, `fatals` | Severity totals over all received log events. |
| `state` | `'pending'` before acceptance, `'running'` after acceptance, or `'finished'` after queue completion. |
| `isRunning` | Whether queue completion has not yet arrived, including pending simulations. |
| `isAccepted` | Whether a queue worker accepted the request. |
| `isFinished` | Whether `QUEUE/COMPLETED` arrived. |
| `hasTerminalStatus` | Whether the latest status is a canonical terminal status. |
| `succeeded` | Whether the run completed and its latest status is exactly `DONE`. |

Simulation identity (`id`, `deckPath`, `config`) is immutable.
The constructor accepts `deckPath`, `config`, and `simId`; there is no log-capacity
argument. All log events are retained in memory, so memory usage grows with log volume.
Unknown severities contribute to `logCount`, but not the three named severity totals.

To summarise a whole batch, read the properties above directly from
`manager.simulations`, which returns the simulations in submission order:

```matlab
simulations = manager.simulations;
failed = simulations(~[simulations.succeeded]);
fprintf("%d of %d runs failed\n", numel(failed), numel(simulations));
```

`simulation.logTable()` returns retained log events as a table, oldest first,
without changing their fields or values. With no retained logs it returns
`table()` because no log schema is available.

Canonical terminal statuses are `DONE`, `ERROR`, `CANCELLED`, `TIMEOUT`, and
`STALLED`. Completion and outcome are separate: an exit code of zero does not
create a status, and a completed run without terminal `STATUS/DONE` is failed.
A queue failure raises a MATLAB exception; unfinished simulations remain
unfinished and are not assigned synthetic outcomes or automatically retried.

Parsed event text, including timestamps, uses string scalars. Event fields
retain their wire names, including `runID`, `unitID`, `typeID`, `messageCode`,
and `exitCode`. Optional numeric fields use `NaN`; optional text uses a missing
string, except `STATUS.message`, which defaults to `""`. No completion event
(`completionEvent = []`) is distinct from a received completion event with an
unknown exit code (`completionEvent.exitCode = NaN`). Queue lifecycle values
are the canonical uppercase `ACCEPTED` and `COMPLETED`.

## `trnrun.SimulationConfig`

Defaults match the native runner contract.

| Option | Default | Description |
| --- | --- | --- |
| `trnrun_path` | bundled `bin/trnrun.exe` | Runner executable used by the queue. |
| `trnexe_path` | `C:\TRNSYS18\Exe\TrnEXE64.exe` | TRNSYS executable. |
| `gui_visibility` | `"hidden"` | `keep`/`keepOpen`, `auto`/`autoClose`, `min`/`minimized`, `minAuto`/`minimizedAuto`, or `hidden` (case-insensitive). |
| `wait_for_gui` | `true` | Include a recognized TRNSYS window in launch detection. |
| `wait_for_lst` | `true` | Wait for the component-order header in the `.lst` file. |
| `wait_for_tmp` | `false` | Wait for a Type3830 `.tmp` file during launch detection. |
| `detect_timeout_ms` | `300000` | Shared launch-detection deadline in milliseconds; `0` is unlimited. |
| `extra_delay_ms` | `0` | Delay after readiness checks pass, in milliseconds. |
| `poll_ms` | `100` | Native file/process polling interval in milliseconds; clamped to at least `1`. |
| `watch_log` | `true` | Emit TRNSYS `.log` entries. |
| `watch_tmp` | `false` | Emit Type3830 configuration/progress events. |
| `watch_timeout_ms` | `0` | Runtime-monitoring deadline in milliseconds; `0` is unlimited. |
| `stall_timeout_ms` | `0` | No-progress deadline in milliseconds; `0` disables it. |
| `clean_on_success` | `false` | Delete `.tmp`, `.log`, `.lst`, and `.PTI` artifacts after success. |
| `kill_on_timeout` | `false` | Kill the owned TRNSYS process after detection/watch timeout. |
| `kill_on_stall` | `false` | Kill the owned TRNSYS process after a detected stall. |
| `severity` | `"Notice"` | Minimum emitted log severity: `Notice`, `Warning`, or `Fatal` (case-insensitive). |
| `write_events` | `false` | Replace and write `<deckFile>.jsonl` with emitted runner events. |

Logical options accept a logical scalar or the numeric values `0` and `1`, which
property validation converts to `false` and `true`; other numeric or string
substitutes are rejected. Configuration times are milliseconds; the manager's
`refreshInterval` is in seconds. The native runner clamps negative timeout/delay values to zero and
raises positive watch/stall timeouts shorter than `poll_ms` to the polling
interval.

## Examples

The examples add only their parent `libraries/matlab/toolbox` directory to the MATLAB
path and resolve their decks relative to the example file, so they run from any
current directory. Do not add package or example subdirectories to the MATLAB path.

| Example | Purpose |
| --- | --- |
| [`example_single.m`](toolbox/examples/example_single.m) | Run one deck with Type3830 progress reporting. |
| [`example_manager.m`](toolbox/examples/example_manager.m) | Copy the example deck and run the copies with bounded concurrency. |

Both mirror the Python clients' `example_single.py` and `example_manager.py`.
`example_manager.m` writes its deck copies to `toolbox/examples/runs` and uses
the default `C:\TRNSYS18\Exe\TrnEXE64.exe`; edit those constants for another
installation. For example:

```matlab
cd("C:\path\to\TRNRun\libraries\matlab\toolbox\examples")
simulation = example_single();
simulations = example_manager();
```

These examples document the intended API and behavior. They do not constitute a
claim that MATLAB or TRNSYS runtime verification has been performed.

## Development and packaging

The layout follows [MathWorks Toolbox Best Practices](https://github.com/mathworks/toolboxdesign):

- `toolbox/`: all distributable code, executables, documentation, examples, and licenses.
- `toolbox/functionSignatures.json`: tab-completion hints for the public API.
- `buildfile.m`: `buildtool` tasks for packaging and cleaning.
- `images/TRNRun.jpg`: toolbox icon applied when packaging.
- `dist/`: generated `.mltbx` files, ignored by Git.

Run the build tasks from `libraries/matlab` in MATLAB R2023a or newer:

```matlab
buildtool                 % default: package dist/TRNRun.mltbx
buildtool clean           % remove dist/
```

**Packaging requires MATLAB R2023a or newer.** `buildfile.m` builds a
`matlab.addons.toolbox.ToolboxOptions` object describing the toolbox and passes
it to `packageToolbox`; there is no MATLAB Project or `.prj` file involved. The
toolbox version is read from `toolbox/+trnrun/version.m`, so that file is the
single source of truth. Only `toolbox/` is distributed, and only its root is
added to the installed path.

`buildtool package` archives whatever `toolbox/` already contains. The
repository `justfile` stages the license, README and native executables into it
first, so `just matlab` is the command that produces a complete archive.

**Recipients only need the generated `dist/TRNRun.mltbx`.** They do not need the
packaging tools. R2021a remains the provisional runtime target; building on a
newer release does not verify older-release compatibility.

Build the native executables, then copy `trnrun.exe` and `trnrunq.exe` into
`toolbox/bin` before packaging. They are build artifacts and are not committed.
TRNSYS and Type3830 are not bundled. `buildfile.m` reads the packaged version
from `toolbox/+trnrun/version.m`, so that file is the only place to change it
when preparing a release.

There is currently no automated test suite. Verify installation and a real
TRNSYS run on R2021a before claiming compatibility with that release.
