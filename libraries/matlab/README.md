<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
    <img alt="TRNRun" src="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
  </picture>
</p>

A thin MATLAB wrapper for running and monitoring
[TRNSYS](https://www.trnsys.com/) batch simulations. The toolbox includes the
[`trnrun.exe`](https://github.com/NRCan/TRNRun/tree/main/components/trnrun) runner and the
[`trnrund.exe`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund)
daemon.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Run a batch](#run-a-batch)
- [`SimulationSettings`](#simulationsettings)
- [`SimulationManager`](#simulationmanager)
- [`Simulation`](#simulation)
- [`Daemon`](#daemon)
- [Examples](#examples)

## Requirements

- Windows x64
- MATLAB R2021a or newer
- TRNSYS 17 or 18
- Optional: [Type3830 Progress Tracker](https://github.com/NRCan/TRNRun/tree/main/components/type3830)
  for progress, ETA, cancellation, and stall detection

## Installation

Install `TRNRun` from the `.mltbx` file:

1. Download `trnrun-v<version>-win_amd64.mltbx` from the latest
   [GitHub Release](https://github.com/NRCan/TRNRun/releases/latest).
2. Double-click the `.mltbx` or run:

   ```matlab
   matlab.addons.install("C:\Users\me\Downloads\trnrun-v<version>-win_amd64.mltbx");
   ```

3. Confirm the install. TRNRun now appears under
   **Home > Add-Ons > Manage Add-Ons**.

## Quick start

```matlab
function simulation = run_deck(deck_path)
    import trnrun.*
    manager = SimulationManager(workers=1);
    simulation = manager.add(deck_path, SimulationSettings(watchTmp=true), ...
        waitFor="FINISHED");

    if simulation.succeeded
        fprintf("Completed: %s\n", simulation.deckFile);
    else
        fprintf("Failed: %s (%s)\n", simulation.deckFile, simulation.trnrunStatus);
    end
end
```

Running simulations appear in a progress window. When a simulation finishes,
it is printed once to the Command Window. Closing the window stops the live
updates but not the simulations.

## Run a batch

```matlab
function simulations = run_batch(deck_folder)
    import trnrun.*
    decks = dir(fullfile(deck_folder, "*.dck"));
    settings = SimulationSettings(watchTmp=true);
    manager = SimulationManager(workers=4);

    for deck = decks'
        manager.add(fullfile(deck.folder, deck.name), settings, waitFor="RUNNING");
    end
    manager.wait();

    simulations = manager.simulations;
    fprintf("%d of %d succeeded\n", nnz([simulations.succeeded]), numel(simulations));
end
```

## `SimulationSettings`

`SimulationSettings` defines how one deck is launched and monitored.
Each property that is set becomes the
[`trnrun.exe` option](https://github.com/NRCan/TRNRun/tree/main/components/trnrun#settings)
of the same name, such as `watchTmp` for `--watchTmp`. A property left empty is
not passed, so the runner's default, listed below, applies. trnrund checks the
values when the simulation is added.

```matlab
import trnrun.*
settings = SimulationSettings(watchTmp=true, pollMs=10);
manager.add(deck, settings);
```

### Executable and window

- _`trnexePath`_ (`string`, default: `C:\TRNSYS18\Exe\TrnEXE64.exe`)

  Path to the `TrnEXE64.exe` or `TrnEXE.exe` executable. A relative path
  resolves from MATLAB's current folder. A missing file raises an error before
  the simulation is queued.

- _`guiVisibility`_ (`string`, default: `"hidden"`)

  Controls the TRNSYS simulation window:

  - `keep`: show the window and leave it open after the simulation.
  - `auto`: show the window and close it after the simulation.
  - `min`: minimize the window and leave it open afterward.
  - `minAuto`: minimize the window and close it afterward.
  - `hidden`: hide the window and close it after the simulation.

### Launch detection

- _`waitForGui`_ (`logical`, default: `true`)

  Wait for a recognized TRNSYS simulation window as part of the
  launch-readiness checks.

- _`waitForLst`_ (`logical`, default: `true`)

  Wait for the component-order header in the deck's `.lst` file.

- _`waitForTmp`_ (`logical`, default: `false`)

  Wait for a Type3830 `.tmp` file. Do not enable this for a deck without
  Type3830, or launch detection will wait until its deadline.

- _`detectTimeout`_ (`double`, default: `300000`)

  Maximum time, in milliseconds, to wait for launch readiness. Set to `0` to
  wait indefinitely. The runner holds the launch mutex for the current Windows
  session until detection completes.

- _`extraDelay`_ (`double`, default: `0`)

  Additional delay in milliseconds after all enabled readiness checks pass.

### Runtime monitoring

- _`pollMs`_ (`double`, default: `100`)

  Polling interval in milliseconds for the TRNSYS process and output files.

- _`watchLog`_ (`logical`, default: `true`)

  Read the deck's `.log` file and report its entries as `logs`.

- _`watchTmp`_ (`logical`, default: `false`)

  Read Type3830 `.tmp` updates and report the simulation period and progress.
  Required for progress-based `CANCELLED` and `STALLED` outcomes. Without
  Type3830 in the deck, an early exit is reported as `DONE`.

- _`watchTimeout`_ (`double`, default: `0`)

  Maximum runtime-monitoring duration in milliseconds. `0` means unlimited.

- _`stallTimeout`_ (`double`, default: `0`)

  Maximum milliseconds without simulation-time progress. `0` disables stall
  detection. Requires `watchTmp=true` and a valid Type3830 snapshot.

- _`killOnTimeout`_ (`logical`, default: `false`)

  Terminate the TRNSYS process when launch detection or runtime monitoring
  times out. If disabled, a detection timeout proceeds to runtime monitoring;
  after a runtime-monitoring timeout, the runner stops polling and waits for
  the process to exit.

- _`killOnStall`_ (`logical`, default: `false`)

  Terminate the TRNSYS process after detecting a stall. Without it, the runner
  waits for the process to exit.

### Output and cleanup

- _`clean`_ (`logical`, default: `false`)

  Delete `.tmp`, `.log`, `.lst`, and `.PTI` sidecar files after a successful
  run.

- _`severity`_ (`string`, default: `"Notice"`)

  Minimum reported log severity: `Notice`, `Warning`, or `Fatal`.

- _`writeEvents`_ (`logical`, default: `false`)

  Mirror the runner events to a `.jsonl` file beside the deck, replacing any
  existing file when the run starts.

A configuration with every property set explicitly:

```matlab
import trnrun.*
settings = SimulationSettings( ...
    trnexePath="C:\TRNSYS18\Exe\TrnEXE64.exe", ...
    guiVisibility="hidden", ...
    waitForGui=true, ...
    waitForLst=true, ...
    waitForTmp=true, ...
    detectTimeout=300000, ...
    extraDelay=0, ...
    pollMs=100, ...
    watchLog=true, ...
    watchTmp=true, ...
    watchTimeout=300000, ...
    stallTimeout=300000, ...
    clean=true, ...
    killOnTimeout=true, ...
    killOnStall=true, ...
    severity="Notice", ...
    writeEvents=false);
```

## `SimulationManager`

`SimulationManager` owns one `trnrund.exe` and keeps a
`Simulation` per run up to date. Nothing runs in the background.
Simulations and the progress window update only while a manager method runs.

### Parameters

- _`workers`_ (`double`, default: logical processor count minus one, at least `1`)

  Maximum number of simulations running at once. Additional simulations wait
  in the queue.

- _`refreshInterval`_ (`double`, default: `1`)

  Seconds between progress-window redraws. `0` or less disables the window
  and the Command Window output.

- _`pollInterval`_ (`double`, default: `0.1`)

  Seconds between refreshes while `add` or `wait` block.

- _`trnrundPath`_ (`string`, default: installed `trnrund.exe`)

  Path to the `trnrund.exe` executable.

- _`trnrunPath`_ (`string`, default: installed `trnrun.exe`)

  Path to the `trnrun.exe` executable.

An explicitly configured manager:

```matlab
import trnrun.*
manager = SimulationManager( ...
    workers=4, ...
    refreshInterval=1, ...
    pollInterval=0.1, ...
    trnrundPath="C:\path\to\trnrund.exe", ...
    trnrunPath="C:\path\to\trnrun.exe");
```

### Methods and properties

- _`simulation = add(deckFile, settings, label=..., waitFor=...)`_

  Queues `deckFile`; a relative path resolves from the current folder.
  `settings` is optional. A `label` is shown instead of the deck path.
  `waitFor` blocks until the simulation is at least `"QUEUED"` (the default,
  which returns at once), `"RUNNING"`, or `"FINISHED"`. A simulation that ends
  without starting, such as a cancelled one, counts as past `"RUNNING"`.

- _`wait(simulations, until="FINISHED", timeout=Inf)`_

  Blocks until every simulation reaches `until`, calling `refresh` every
  `pollInterval` seconds. With no simulations given, it waits for every
  simulation added. Raises `trnrun:Timeout` once `timeout` seconds have passed.

- _`refresh()`_

  Updates every running and finished simulation from trnrund once and redraws
  the window. Each finished simulation gets its logs, then trnrund releases it.

- _`cancel(simulations)`_

  Stops queued or running simulations and leaves finished ones unchanged. The
  next `refresh` shows them `FINISHED` with status `CANCELLED`.

- _`simulations`_ (`Simulation` array)

  Every simulation the manager has seen, oldest first.

- _`daemon`_ (`Daemon`)

  The trnrund this manager owns, for direct requests.

Deleting the manager, or clearing its last reference, stops `trnrund.exe`,
cancelling unfinished runs, and closes the progress window.

Example manager workflow with every method and property:

```matlab
import trnrun.*

manager = SimulationManager(workers=2);
settings = SimulationSettings(watchTmp=true);

first = manager.add("C:\path\to\first.dck", settings, waitFor="RUNNING");
second = manager.add("C:\path\to\second.dck", settings, label="second");

manager.wait(first);
fprintf("First status: %s\n", first.trnrunStatus);

manager.cancel(second);
manager.wait(timeout=60);
manager.refresh();
fprintf("Simulations: %d\n", numel(manager.simulations));
fprintf("First succeeded: %d\n", first.succeeded);
fprintf("Second status: %s\n", second.trnrunStatus);

delete(manager);
```

## `Simulation`

`SimulationManager.add()` returns a `Simulation` handle for one run, which the
manager updates in place on each refresh. Its properties are trnrund's
[simulation fields](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#simulation-fields).
A value TRNRun has not reported yet is `missing` text, `NaN`, or `NaT`.

### Properties

- _`simId`_ (`double`)

  Identifier assigned by trnrund, never reused.

- _`deckFile`_ (`string`)

  Absolute path to the submitted deck.

- _`label`_ (`string`)

  Label it was added with; `missing` if none.

- _`trnrunOptions`_ (`struct`)

  Runner options it was added with, such as `struct('watchTmp', true)`.

- _`state`_ (`string`)

  `QUEUED` while waiting for a worker, `RUNNING` once the runner started, and
  `FINISHED` once it completed, failed, or was cancelled.

- _`trnrunStatus`_, _`trnrunMessage`_ (`string`)

  Latest runner status, such as `DONE` or `STALLED`, and its detail.

- _`succeeded`_ (`logical`)

  `true` only once finished with status `DONE`, exit code `0`, and no
  `error`.

- _`exitCode`_ (`double`)

  Runner exit code; `NaN` if it was cancelled or never started.

- _`error`_ (`string`)

  Why trnrund failed or cancelled the run.

- _`simTime`_, _`percent`_, _`elapsedMs`_, _`etaMs`_ (`double`)

  Latest Type3830 progress. `simTime` is in simulated hours, `percent` is a
  fraction from `0` to `1`, and `elapsedMs` and `etaMs` are milliseconds.

- _`startTime`_, _`stopTime`_, _`timeStep`_ (`double`)

  Simulation period reported by Type3830, in simulated hours.

- _`setting`_ (`struct`)

  Settings the runner applied, its defaults included, keyed by the runner's
  option names.

- _`notices`_, _`warnings`_, _`fatals`_ (`double`)

  Number of log entries so far, by severity.

- _`logs`_ (`struct` array)

  Log entries, oldest first; filled in once the simulation finishes.

- _`submittedAt`_, _`startedAt`_, _`finishedAt`_ (`datetime`)

  UTC times; `startedAt` stays `NaT` for a simulation that never started.

An example inspecting every property:

```matlab
import trnrun.*

manager = SimulationManager(workers=1);
simulation = manager.add("C:\path\to\deck.dck", SimulationSettings(watchTmp=true));
manager.wait(simulation);
delete(manager);

fprintf("ID: %d\n", simulation.simId);
fprintf("Deck: %s\n", simulation.deckFile);
fprintf("Label: %s\n", simulation.label);
fprintf("Runner options: %s\n", jsonencode(simulation.trnrunOptions));
fprintf("State: %s\n", simulation.state);
fprintf("Status: %s %s\n", simulation.trnrunStatus, simulation.trnrunMessage);
fprintf("Succeeded: %d\n", simulation.succeeded);
fprintf("Exit code: %g\n", simulation.exitCode);
fprintf("Error: %s\n", simulation.error);
fprintf("Progress: %g at %g h\n", simulation.percent, simulation.simTime);
fprintf("Elapsed: %g ms, ETA: %g ms\n", simulation.elapsedMs, simulation.etaMs);
fprintf("Period: %g to %g by %g h\n", simulation.startTime, simulation.stopTime, simulation.timeStep);
disp(simulation.setting);
fprintf("Notices: %d\n", simulation.notices);
fprintf("Warnings: %d\n", simulation.warnings);
fprintf("Fatals: %d\n", simulation.fatals);
fprintf("Logs: %d entries\n", numel(simulation.logs));
fprintf("Times: %s, %s, %s\n", string(simulation.submittedAt), ...
    string(simulation.startedAt), string(simulation.finishedAt));
```

## `Daemon`

`Daemon` is a thin client with one method per
[trnrund command](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#request-protocol),
for applications that do their own polling. It takes the `workers`,
`trnrundPath`, and `trnrunPath` parameters of
[`SimulationManager`](#parameters).

### Methods

- _`simId = add(deckFile, settings, label=...)`_

  Queue `deckFile` and return its `simId`, as for `SimulationManager.add`.

- _`simulation = simulation(simId, withLogs=false)`_

  Return one simulation, without `logs` unless `withLogs` is `true`.

- _`simulations = simulations(state, withLogs=false)`_

  Return every unreleased simulation in `state`, oldest first. `state` may be
  several states, such as `["QUEUED", "RUNNING"]`.

- _`cancel(simId)`_

  Stop a queued or running simulation; one already finished is left unchanged.

- _`release(simId)`_

  Forget a finished simulation and its logs.

- _`response = request(request)`_

  Send any raw trnrund request struct and return its decoded response.

- _`close()`_

  Stop `trnrund.exe`, killing unfinished runs. Deleting the daemon, or
  clearing its last reference, does the same.

`trnrun:RequestError` is raised when trnrund refuses a request, such as for a
missing deck, an unknown `simId`, or releasing an unfinished run, and
`trnrun:DaemonExited`, with trnrund's exit code and stderr, when it no longer
answers. Simulation outcomes do not raise: inspect each simulation's
`succeeded`, `trnrunStatus`, and `exitCode` instead.

Example daemon workflow with every method:

```matlab
import trnrun.*

daemon = Daemon(workers=2);
settings = SimulationSettings(watchTmp=true);

first = daemon.add("C:\path\to\first.dck", settings);
second = daemon.add("C:\path\to\second.dck", settings, label="second");

disp(daemon.simulation(first));
fprintf("Running: %d\n", numel(daemon.simulations("RUNNING")));

daemon.cancel(second);
cancelled = daemon.simulation(second);
while cancelled.state ~= "FINISHED"
    pause(0.1);
    cancelled = daemon.simulation(second);
end
cancelled = daemon.simulation(second, withLogs=true);
fprintf("Second status: %s, %d log entries\n", cancelled.trnrunStatus, numel(cancelled.logs));
daemon.release(second);

try
    daemon.release(first);
catch exception
    if exception.identifier ~= "trnrun:RequestError"
        rethrow(exception);
    end
    fprintf("First not finished: %s\n", exception.message);
end

raw = daemon.request(struct("cmd", "simulations", "state", "RUNNING"));
disp(raw);

daemon.close();
```

## Examples

The examples run `decks/slow_wo_plot_w_tracking.dck` from a clone of this
repository. Set `libraries/matlab/examples` as
the current folder, then run:

- `simulation = example_single();` runs one deck with Type3830 progress.
- `simulations = example_manager();` runs ten copies of a deck, five at a
  time.
- `simulation = example_daemon();` runs one deck with `Daemon` and
  polls it itself.
