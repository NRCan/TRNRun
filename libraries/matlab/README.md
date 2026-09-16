<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="../..assets/trnrun-black.svg">
    <img alt="TRNRun" src="./assets/trnrun-black.svg">
  </picture>
</p>

Thin MATLAB wrapper for running and monitoring
[TRNSYS](https://www.trnsys.com/) batch simulations. The
library uses the `trnrun.exe` runner and `trnrunq.exe` queue included in
the distributed toolbox.

## Requirements

- Windows x64
- MATLAB R2021a or newer as a provisional release floor
- TRNSYS 17 or 18
- Optional: [Type3830 Progress Tracker](../../components/type3830/) for
  progress and stall monitoring

## Installation

Install with MATLAB's Add-On Explorer:

```text
Home > Add-Ons > Get Add-Ons > Search "TRNRun" > Install
```

Or with a package downloaded from
[GitHub Releases](https://github.com/NRCan/TRNRun/releases):

```matlab
matlab.addons.toolbox.installToolbox("C:\path\to\trnrun-v<version>-win_amd64.mltbx");
```

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

## `trnrun.SimulationConfig`

`SimulationConfig` defines how one deck is launched and monitored.

### Executables and window

- _`trnrun_path`_ (`string`, default: bundled `trnrun.exe`)

  Path to the `trnrun.exe` executable.

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
are submitted, monitored, and displayed. It is synchronous and intended for use
from one thread. Simulation state advances only while `add()`, `wait()`,
`follow()`, or `shutdown()` reads queue output.

### Parameters

- _`maxConcurrent`_ (`double`, default: logical processor count minus one, at
  least `1`)

  Maximum number of runners that may execute concurrently. Additional
  submissions wait for a worker.

- _`refreshInterval`_ (`double`, default: `1.0`)

  Minimum seconds between progress-window updates while events are being read.
  Set to `0` or a negative value to disable all built-in display output.

- _`trnrunqPath`_ (`string`, default: bundled `trnrunq.exe`)

  Path to the `trnrunq.exe` executable.

A manager with every parameter set explicitly:

```matlab
manager = trnrun.SimulationManager( ...
    maxConcurrent=4, ...
    refreshInterval=1.0, ...
    trnrunqPath="C:\path\to\trnrunq.exe");
```

### Methods and properties

- _`simulations`_ (`trnrun.Simulation` array)

  Snapshot of all queue-accepted simulations in submission order.

- _`succeeded`_ (`trnrun.Simulation` array)

  Snapshot of accepted simulations that completed successfully.

- _`failed`_ (`trnrun.Simulation` array)

  Snapshot of accepted simulations that completed without succeeding. Pending
  and running simulations are not included.

- _`simulation = add(deckFile, config)`_

  Validate and submit `deckFile` using a copy of `config`. Blocks until a queue
  worker accepts the request and returns its `trnrun.Simulation`. If every
  worker is occupied, this may not return until an earlier simulation finishes.

- _`wait()`_

  Process events until every accepted simulation completes. There is no
  client-side timeout.

- _`wait(simulation)`_

  Return when one manager-owned simulation completes while continuing to
  process updates from other runs. Passing a finished simulation returns
  immediately; a simulation owned by another manager is rejected.

- _`follow(callback)`_

  Follow every unfinished simulation. After applying each new event, call
  `callback(updatedSimulation)` with the simulation affected by that event.
  Return when all simulations are finished.

- _`follow(callback, simulation)`_

  Follow one manager-owned simulation. Events for every run are still processed,
  but `callback(updatedSimulation)` is called only when the selected simulation
  is updated. Return when the selected simulation is finished; if it is already
  finished, return immediately.

Previously consumed events are not replayed by either form.

- _`shutdown()`_

  Close queue input, finish accepted work, and reap the queue process. A
  successful shutdown is idempotent and leaves simulation results readable.


Live progress appears in one resizable, read-only window, and completed
summaries are appended to the Command Window. Closing the progress window
stops live display updates without stopping simulations.

Example manager workflow with every method and property:

```matlab
function [first, second] = manager_example()
    config = trnrun.SimulationConfig(watch_tmp=true);
    manager = trnrun.SimulationManager(maxConcurrent=2);

    first = manager.add("C:\path\to\first.dck", config);
    second = manager.add("C:\path\to\second.dck", config);

    manager.follow(@report_update, first);
    manager.wait();

    fprintf("Simulations: %d\n", numel(manager.simulations));
    fprintf("Succeeded: %d\n", numel(manager.succeeded));
    fprintf("Failed: %d\n", numel(manager.failed));
    fprintf("Session diagnostics: %d\n", ...
        numel(manager.sessionDiagnostics));
    fprintf("First succeeded: %d\n", first.succeeded);
    fprintf("Second succeeded: %d\n", second.succeeded);

    manager.shutdown();
end

function report_update(simulation)
    if ~isempty(simulation.status)
        fprintf("%s: %s\n", ...
            char(simulation.deckPath), char(string(simulation.status.status)));
    end
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
  `percent` is a fraction from `0` to `1`; `elapsed` and `eta` are milliseconds.

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

Runnable examples are available in [`toolbox/examples`](toolbox/examples) or [TRNRun repository](https://github.com/NRCan/TRNRun/tree/main/libraries/matlab/toolbox/examples).:

- [`example_single.m`](toolbox/examples/example_single.m) runs one deck with
  Type3830 progress reporting.
- [`example_manager.m`](toolbox/examples/example_manager.m) runs copied decks
  with bounded concurrency.

Set `toolbox/examples` as the current folder, then run:

```matlab
simulation = example_single();
```

or

```matlab
simulations = example_manager();
```
