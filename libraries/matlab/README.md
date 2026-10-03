<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
    <img alt="TRNRun" src="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
  </picture>
</p>

Thin MATLAB wrapper for running and monitoring
[TRNSYS](https://www.trnsys.com/) batch simulations. The
library uses the `trnrun.exe` runner and `trnrunq.exe` queue. MATLAB downloads
and installs both native clients from the matching GitHub release when the
toolbox is installed.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Run a batch](#run-a-batch)
- [Submit without waiting for acceptance](#submit-without-waiting-for-acceptance)
- [`trnrun.SimulationConfig`](#trnrunsimulationconfig)
- [`trnrun.SimulationManager`](#trnrunsimulationmanager)
- [`trnrun.Simulation`](#trnrunsimulation)
- [Examples](#examples)

## Requirements

- Windows x64
- MATLAB R2021a or newer
- TRNSYS 17 or 18
- Optional: [Type3830 Progress Tracker](https://github.com/NRCan/TRNRun/tree/main/components/type3830) for
  progress and stall monitoring

## Installation

Install with MATLAB's Add-On Explorer:

```text
Home > Add-Ons > Get Add-Ons > Search "TRNRun" > Install
```

Or download the package from
[GitHub Releases](https://github.com/NRCan/TRNRun/releases), navigate to it in
MATLAB's Current Folder browser, and double-click the `.mltbx` file. Follow the
installer prompts to install the toolbox and both native clients.

## Quick start

```matlab
function simulation = run_deck(deck_path)
    config = trnrun.SimulationConfig(watch_tmp=true);
    manager = trnrun.SimulationManager(maxConcurrent=1);

    simulation = manager.add(deck_path, config);
    manager.wait(simulation);

    if simulation.succeeded
        fprintf("Completed: %s\n", char(simulation.deckPath));
    else
        fprintf("Failed: %s\n", char(simulation.deckPath));
    end

    manager.shutdown();
end
```

## Run a batch

```matlab
function simulations = run_batch(deck_folder)
    decks = dir(fullfile(deck_folder, "*.dck"));
    deck_paths = fullfile(string({decks.folder}), string({decks.name}));
    config = trnrun.SimulationConfig(watch_tmp=true);

    manager = trnrun.SimulationManager(maxConcurrent=4);

    for deck_path = deck_paths
        manager.add(deck_path, config);
    end

    manager.wait();
    simulations = manager.simulations;
    fprintf("%d succeeded, %d failed\n", numel(manager.succeeded), numel(manager.failed));

    manager.shutdown();
end
```

## Submit without waiting for acceptance

Use `blocking=false` when submissions must not wait for queue acceptance (for
example, when all workers are occupied). The returned handles start in the
`pending` state. Call `poll()` from your own loop to apply ready updates; it
returns immediately with the number of applied updates, or `0` if none are
ready.

```matlab
manager = trnrun.SimulationManager(maxConcurrent=2);
config = trnrun.SimulationConfig(watch_tmp=true);

first = manager.add("C:\path\to\first.dck", config, blocking=false);
second = manager.add("C:\path\to\second.dck", config, blocking=false);

while ~isempty(manager.active)
    count = manager.poll();
    if count == 0
        pause(0.1); % Let the queue make progress without busy-spinning.
    end
end

fprintf("%d submitted, %d accepted, %d succeeded\n", ...
    numel(manager.submitted), numel(manager.simulations), ...
    numel(manager.succeeded));
manager.shutdown();
```

`poll()` does not run in the background: MATLAB-visible state, results and
built-in display updates remain stale until `poll()`, `wait()`, or
`shutdown()` reads queue output. The transport can still wait briefly while
sending a request; `blocking=false` only skips the wait for `QUEUE/ACCEPTED`.
If you do not need to integrate with an event loop, `manager.wait()` also
finishes pending submissions.

## `trnrun.SimulationConfig`

`SimulationConfig` defines how one deck is launched and monitored.

### Executables and window

- _`trnrun_path`_ (`string`, default: MATLAB-managed `trnrun.exe`)

  Path to the `trnrun.exe` executable downloaded with the toolbox.

- _`trnexe_path`_ (`string`, default:
  `C:\TRNSYS18\Exe\TrnEXE64.exe`)

  Path to the `TrnEXE64.exe` or `TrnEXE.exe` executable.

- _`gui_visibility`_ (`string`, default: `"hidden"`)

  Controls the TRNSYS simulation window. Values are case-insensitive:

  - `keep` / `keepOpen`: show the window and leave it open after the simulation.
  - `auto` / `autoClose`: show the window and close it after the simulation.
  - `min` / `minimized`: minimize the window and leave it open afterward.
  - `minAuto` / `minimizedAuto`: minimize the window and close it afterward.
  - `hidden`: hide the window and close it after the simulation.

### Launch detection

- _`wait_for_gui`_ (`logical`, default: `true`)

  Wait for a recognized TRNSYS simulation window as part of launch-readiness
  checks.

- _`wait_for_lst`_ (`logical`, default: `true`)

  Wait for the component-order header in the deck's `.lst` file.

- _`wait_for_tmp`_ (`logical`, default: `false`)

  Wait for a Type3830 `.tmp` file. Do not enable this for a deck without
  Type3830, or launch detection waits until its deadline.

- _`detect_timeout_ms`_ (`double`, default: `300000`)

  Maximum time, in milliseconds, to wait for launch readiness. Set to `0` to
  wait indefinitely. The runner holds the launch mutex until detection
  completes.

- _`extra_delay_ms`_ (`double`, default: `0`)

  Additional delay in milliseconds after all enabled readiness checks pass.

### Runtime monitoring

- _`poll_ms`_ (`double`, default: `100`)

  Positive integer polling interval in milliseconds for the TRNSYS process and
  output files. MATLAB rejects zero and negative values.

- _`watch_log`_ (`logical`, default: `true`)

  Read the deck's `.log` file and emit parsed `LOG` events.

- _`watch_tmp`_ (`logical`, default: `false`)

  Read Type3830 `.tmp` updates and emit configuration and progress events.
  Required for progress-based `CANCELLED` and `STALLED` outcomes.

- _`watch_timeout_ms`_ (`double`, default: `0`)

  Nonnegative integer runtime-monitoring duration in milliseconds. `0` means
  unlimited.

- _`stall_timeout_ms`_ (`double`, default: `0`)

  Maximum milliseconds without simulation-time progress. `0` disables stall
  detection. Requires `watch_tmp=true` and a valid Type3830 snapshot.

- _`kill_on_timeout`_ (`logical`, default: `false`)

  Terminate the owned TRNSYS process when launch detection or runtime
  monitoring times out. If disabled, a detection timeout proceeds to runtime
  monitoring; after a runtime-monitoring timeout, `trnrun.exe` waits for the
  process to exit.

- _`kill_on_stall`_ (`logical`, default: `false`)

  Terminate the owned TRNSYS process after detecting a stall. If disabled,
  `trnrun.exe` waits for the process to exit.


### Output and cleanup

- _`clean_on_success`_ (`logical`, default: `false`)

  Delete `.tmp`, `.log`, `.lst`, and `.PTI` sidecar files after a successful
  run.

- _`severity`_ (`string`, default: `"Notice"`)

  Minimum emitted log severity: `Notice`, `Warning`, or `Fatal`,
  case-insensitively.

- _`write_events`_ (`logical`, default: `false`)

  Mirror emitted runner events to a `.jsonl` file beside the deck, replacing
  any existing file when the run starts.

A configuration with every property set explicitly:

```matlab
config = trnrun.SimulationConfig( ...
    trnrun_path="C:\path\to\trnrun.exe", ...
    trnexe_path="C:\TRNSYS18\Exe\TrnEXE64.exe", ...
    gui_visibility="hidden", ...
    wait_for_gui=true, ...
    wait_for_lst=true, ...
    wait_for_tmp=true, ...
    detect_timeout_ms=300000, ...
    extra_delay_ms=0, ...
    poll_ms=100, ...
    watch_log=true, ...
    watch_tmp=true, ...
    watch_timeout_ms=300000, ...
    stall_timeout_ms=300000, ...
    clean_on_success=true, ...
    kill_on_timeout=true, ...
    kill_on_stall=true, ...
    severity="Notice", ...
    write_events=false);
```

## `trnrun.SimulationManager`

`trnrun.SimulationManager` owns one queue process and controls how simulations
are submitted, monitored, and displayed. It is intended for use from one
thread. Simulation state advances only while blocking `add()`, `poll()`,
`wait()`, or `shutdown()` reads queue output. Non-blocking `add()`
submits without processing updates.

### Parameters

- _`maxConcurrent`_ (`double`, default: logical processor count minus one, at
  least `1`)

  Maximum number of runners that may execute concurrently. Additional
  submissions wait for a worker.

- _`refreshInterval`_ (`double`, default: `1.0`)

  Minimum seconds between progress-window updates while events are being read.
  Set to `0` or a negative value to disable all built-in display output.

- _`trnrunqPath`_ (`string`, default: MATLAB-managed `trnrunq.exe`)

  Path to the `trnrunq.exe` executable downloaded with the toolbox.

A manager with every parameter set explicitly:

```matlab
manager = trnrun.SimulationManager( ...
    maxConcurrent=4, ...
    refreshInterval=1.0, ...
    trnrunqPath="C:\path\to\trnrunq.exe");
```

### Methods and properties

- _`submitted`_ (`trnrun.Simulation` array)

  Snapshot of all successfully submitted handles in submission order, including
  those not yet accepted by the queue and those already finished. Failed sends
  are excluded.

- _`active`_ (`trnrun.Simulation` array)

  Snapshot of unfinished submitted handles, including pending requests that
  have not yet received `QUEUE/ACCEPTED`.

- _`simulations`_ (`trnrun.Simulation` array)

  Snapshot of all queue-accepted simulations in submission order.

- _`succeeded`_ (`trnrun.Simulation` array)

  Snapshot of accepted simulations that completed successfully.

- _`failed`_ (`trnrun.Simulation` array)

  Snapshot of accepted simulations that completed without succeeding. Pending
  and running simulations are not included.

- _`simulation = add(deckFile, config, blocking=true)`_

  Validate and submit `deckFile` using a copy of `config`. The default
  `blocking=true` preserves the two-argument behavior: return its
  `trnrun.Simulation` only after `QUEUE/ACCEPTED`. If every worker is occupied,
  this may wait until an earlier simulation finishes. With `blocking=false`,
  return the handle immediately after `transport.send` succeeds without waiting
  for acceptance or reading updates; its initial state is `pending`. The send
  itself may still take time. Acceptance is not a prerequisite for inclusion in
  `submitted` or `active`.

- _`count = poll()`_

  Non-blockingly consume currently ready queue output and apply its events.
  Return the number of updates actually applied, or `0` when none are ready.
  Malformed, unroutable, duplicate and post-completion events do not count;
  they may be retained in `sessionDiagnostics`. A premature queue EOF with
  unfinished runs raises an error rather than treating those runs as failures.
  Do not call `poll()` reentrantly from another manager operation or after
  shutdown starts.

- _`wait()`_

  Process events until every unfinished submitted simulation completes,
  including requests still pending acceptance. There is no client-side timeout.

- _`wait(simulation)`_

  Return when one manager-owned simulation completes while continuing to
  process updates from other runs. Passing a finished simulation returns
  immediately; a simulation owned by another manager is rejected.


- _`shutdown()`_

  Close queue input, drain pending and accepted work, and reap the queue process. A
  successful shutdown is idempotent and leaves simulation results readable.


Live progress appears in one resizable, read-only window, and completed
summaries are appended to the Command Window. Closing the progress window
stops live display updates without stopping simulations.

Example manager workflow with every method and property:

```matlab
function [first, second] = manager_example()
    config = trnrun.SimulationConfig(watch_tmp=true);
    manager = trnrun.SimulationManager(maxConcurrent=2);

    first = manager.add("C:\path\to\first.dck", config, blocking=false);
    second = manager.add("C:\path\to\second.dck", config, blocking=false);

    manager.poll();
    manager.wait(first);
    manager.wait();

    fprintf("Submitted: %d\n", numel(manager.submitted));
    fprintf("Active: %d\n", numel(manager.active));
    fprintf("Simulations: %d\n", numel(manager.simulations));
    fprintf("Succeeded: %d\n", numel(manager.succeeded));
    fprintf("Failed: %d\n", numel(manager.failed));
    fprintf("Session diagnostics: %d\n", ...
        numel(manager.sessionDiagnostics));
    fprintf("First succeeded: %d\n", first.succeeded);
    fprintf("Second succeeded: %d\n", second.succeeded);

    manager.shutdown();
end
```

## `trnrun.Simulation`

`SimulationManager.add()` returns a `trnrun.Simulation` handle containing the
current state and results of one run. The manager updates this object as it
processes queue events; applications normally inspect it rather than
constructing or updating it directly.

### Identity and configuration

- _`id`_ (`double`)

  Manager-assigned simulation identifier. The queue uses its string form as the
  run ID.

- _`deckPath`_ (`string`)

  Absolute path to a manager-submitted deck. A directly constructed
  `Simulation` stores the supplied path unchanged.

- _`config`_ (`trnrun.SimulationConfig`)

  Independent configuration snapshot used for this run.

### Events

- _`status`_ (`struct` or `[]`)

  Latest runner status, or `[]` before the first status event. Terminal status
  values are `DONE`, `ERROR`, `CANCELLED`, `TIMEOUT`, and `STALLED`.

- _`progress`_ (`struct` or `[]`)

  Latest Type3830 progress event, or `[]` when progress has not been reported.
  `percent` is a fraction from `0` to `1`; `elapsedMs` and `etaMs` are milliseconds.

- _`configEvent`_ (`struct` or `[]`)

  Latest simulation-time configuration event, containing `start`, `stop`, and
  `step`, or `[]` before Type3830 reports it.

- _`settingEvent`_ (`struct` or `[]`)

  `trnrun.exe` settings reported when the simulation starts, or `[]`
  before they are received.

- _`completionEvent`_ (`struct` or `[]`)

  Queue completion metadata, including `exitCode`, or `[]` until the queue
  finishes the request. Manager-parsed events use `NaN` when the wire
  `exitCode` is null or omitted.

- _`logs`_ (`struct` array)

  All log events in arrival order. MATLAB does not impose a retention limit, so
  memory use grows with log volume.

### State and outcome

- _`isRunning`_ (`logical`)

  Whether the simulation is pending or running and has not received queue
  completion.

- _`isAccepted`_ (`logical`)

  Whether a queue worker has accepted the request.

- _`isFinished`_ (`logical`)

  Whether the queue has reported completion for the request.

- _`hasTerminalStatus`_ (`logical`)

  Whether the runner has reported one of the canonical terminal statuses.

- _`succeeded`_ (`logical`)

  Whether the queue completed the request and the latest runner status is
  exactly `DONE`.

### Log counters

- _`logCount`_ (`double`)

  Total number of received log events.

- _`notices`_ (`double`)

  Number of received `Notice` log events.

- _`warnings`_ (`double`)

  Number of received `Warning` log events.

- _`fatals`_ (`double`)

  Number of received `Fatal` log events.

- _`logTable()`_

  Return all retained logs as a table in arrival order without changing their
  fields or values. With no logs, it returns `table()` because no schema is
  available.

An example inspecting the documented properties and the log-table helper:

```matlab
function inspect_simulation(simulation)
    fprintf("ID: "); disp(simulation.id)
    fprintf("Deck: "); disp(simulation.deckPath)
    fprintf("Config: "); disp(simulation.config)
    fprintf("Running: "); disp(simulation.isRunning)
    fprintf("Accepted: "); disp(simulation.isAccepted)
    fprintf("Finished: "); disp(simulation.isFinished)
    fprintf("Terminal status received: "); disp(simulation.hasTerminalStatus)
    fprintf("Succeeded: "); disp(simulation.succeeded)
    fprintf("Status: "); disp(simulation.status)
    fprintf("Progress: "); disp(simulation.progress)
    fprintf("Simulation config event: "); disp(simulation.configEvent)
    fprintf("Runner settings: "); disp(simulation.settingEvent)
    fprintf("Queue completion: "); disp(simulation.completionEvent)
    fprintf("Logs: "); disp(simulation.logs)
    fprintf("Log table: "); disp(simulation.logTable())
    fprintf("Log count: "); disp(simulation.logCount)
    fprintf("Notices: "); disp(simulation.notices)
    fprintf("Warnings: "); disp(simulation.warnings)
    fprintf("Fatals: "); disp(simulation.fatals)
end
```

## Examples

Runnable examples are available in the
[TRNRun repository](https://github.com/NRCan/TRNRun/tree/main/libraries/matlab/toolbox/examples).

- [`example_single.m`](https://github.com/NRCan/TRNRun/blob/main/libraries/matlab/toolbox/examples/example_single.m)
  runs one deck with Type3830 progress reporting.
- [`example_manager.m`](https://github.com/NRCan/TRNRun/blob/main/libraries/matlab/toolbox/examples/example_manager.m)
  runs copied decks with bounded concurrency.

Set `toolbox/examples` as the current folder, then run:

```matlab
simulation = example_single();
```

or

```matlab
simulations = example_manager();
```
