<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
    <img alt="TRNRun" src="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
  </picture>
</p>

A thin MATLAB wrapper for running and monitoring
[TRNSYS](https://www.trnsys.com/) batch simulations. The library drives the
[`trnrund.exe`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund)
daemon, which runs each simulation through `trnrun.exe`. When you install the
toolbox, MATLAB downloads both executables from the matching GitHub release.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Run a batch](#run-a-batch)
- [`trnrun.SimulationSettings`](#trnrunsimulationsettings)
- [`trnrun.SimulationManager`](#trnrunsimulationmanager)
- [`trnrun.Simulation`](#trnrunsimulation)
- [`trnrun.Daemon`](#trnrundaemon)
- [Examples](#examples)
- [Development](#development)

## Requirements

- Windows x64
- MATLAB R2021a or newer
- TRNSYS 17 or 18
- Optional: [Type3830 Progress Tracker](https://github.com/NRCan/TRNRun/tree/main/components/type3830)
  for progress, ETA, cancellation, and stall detection

## Installation

Install with MATLAB's Add-On Explorer:

```text
Home > Add-Ons > Get Add-Ons > Search "TRNRun" > Install
```

Or download the `.mltbx` from
[GitHub Releases](https://github.com/NRCan/TRNRun/releases) and double-click it
in MATLAB's Current Folder browser.

## Quick start

```matlab
function simulation = run_deck(deck_path)
    manager = trnrun.SimulationManager(workers=1);
    simulation = manager.add(deck_path, trnrun.SimulationSettings(watchTmp=true), ...
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

The manager owns one `trnrund.exe`. Deleting the manager, including when a
function returns, closes trnrund, which cancels every unfinished simulation.

## Run a batch

```matlab
function simulations = run_batch(deck_folder)
    decks = dir(fullfile(deck_folder, "*.dck"));
    settings = trnrun.SimulationSettings(watchTmp=true);
    manager = trnrun.SimulationManager(workers=4);

    for deck = decks'
        manager.add(fullfile(deck.folder, deck.name), settings);
    end
    manager.wait();

    simulations = manager.simulations;
    fprintf("%d of %d succeeded\n", nnz([simulations.succeeded]), numel(simulations));
end
```

trnrund queues every deck at once and runs `workers` of them at a time. To
add the next deck only after the previous one has started, use
`waitFor="RUNNING"`.

## `trnrun.SimulationSettings`

A value class holding the TRNRun options for a simulation. Each property is the
[`trnrun.exe` flag](https://github.com/NRCan/TRNRun/tree/main/components/trnrun)
of the same name, such as `watchTmp` for `--watchTmp`. A property left empty is
not passed, so TRNRun's default applies. trnrund checks the values when a run
is added.

```matlab
settings = trnrun.SimulationSettings( ...
    trnexePath="C:\TRNSYS18\Exe\TrnEXE64.exe", ...
    guiVisibility="hidden", ...   % keep, auto, min, minAuto or hidden
    waitForGui=true, ...
    waitForLst=true, ...
    waitForTmp=true, ...          % requires Type3830
    detectTimeout=300000, ...     % ms
    extraDelay=0, ...             % ms
    pollMs=100, ...
    watchLog=true, ...
    watchTmp=true, ...            % requires Type3830
    watchTimeout=0, ...           % ms; 0 disables
    stallTimeout=60000, ...       % ms; 0 disables
    clean=false, ...              % delete TRNSYS outputs after success
    killOnTimeout=true, ...
    killOnStall=true, ...
    severity="Notice", ...        % Notice, Warning or Fatal
    writeEvents=false);
```

`settings.cliArgs()` returns the flags as passed, such as
`{'--watchTmp:true'}`. If `trnexePath` is set, it must exist; it is made
absolute from the current folder.

## `trnrun.SimulationManager`

```matlab
manager = trnrun.SimulationManager( ...
    workers=4, ...             % default: logical processors minus one
    refreshInterval=1, ...     % seconds between window redraws; <= 0 disables output
    pollInterval=0.1, ...      % seconds between refreshes while blocking
    trnrundPath="C:\path\to\trnrund.exe", ...  % default: installed
    trnrunPath="C:\path\to\trnrun.exe");       % default: installed
```

Nothing runs in the background. Simulations and the progress window update only
while a manager method runs.

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

- _`simulations`_ (`trnrun.Simulation` array)

  Every simulation the manager has seen, oldest first.

- _`daemon`_ (`trnrun.Daemon`)

  The trnrund this manager owns, for direct requests.

## `trnrun.Simulation`

A handle object holding one simulation as trnrund last reported it. Its
properties are trnrund's
[simulation fields](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#simulation-fields).
A value TRNRun has not reported yet is `missing` text, `NaN`, or `NaT`.

| Property | Type | Meaning |
| --- | --- | --- |
| `simId` | `double` | Assigned by trnrund, never reused |
| `label`, `deckFile`, `trnrunArgs` | `string` | What it was added with; `deckFile` is absolute |
| `state` | `string` | `QUEUED`, `RUNNING`, or `FINISHED` |
| `trnrunStatus`, `trnrunMessage` | `string` | Latest TRNRun status, such as `DONE` or `STALLED`, and its detail |
| `percent`, `simTime`, `elapsedMs`, `etaMs` | `double` | Latest progress; `percent` is from `0` to `1` |
| `startTime`, `stopTime`, `timeStep` | `double` | Simulation period, in simulated hours |
| `setting` | `struct` | Settings TRNRun applied |
| `notices`, `warnings`, `fatals` | `double` | Log entries so far, by severity |
| `logs` | `struct` array | Log entries, oldest first, once finished |
| `succeeded` | `logical` | Finished with `DONE`, exit code `0`, and no error |
| `exitCode` | `double` | TRNRun's exit code |
| `error` | `string` | Why trnrund failed or cancelled it |
| `submittedAt`, `startedAt`, `finishedAt` | `datetime` | UTC |

## `trnrun.Daemon`

The thin client for trnrund, with one method per
[trnrund command](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#request-protocol).
Use it directly when you want your own polling loop:

```matlab
daemon = trnrun.Daemon(workers=2);
simId = daemon.add("C:\models\building-a.dck", trnrun.SimulationSettings(watchTmp=true));
simulation = daemon.simulation(simId, withLogs=true);
running = daemon.simulations(["QUEUED", "RUNNING"]);
daemon.cancel(simId);
daemon.release(simId);   % only once FINISHED
response = daemon.request(struct("cmd", "ready"));
```

A refused request raises `trnrun:RequestError` with trnrund's message. If
trnrund stops answering, `trnrun:DaemonExited` is raised with its exit code
and stderr.

## Examples

Set `toolbox/examples` as the current folder, then run:

- `simulation = example_single();` runs one deck with Type3830 progress.
- `simulations = example_manager();` runs ten copies of a deck, five at a
  time.

## Development

From this folder, in MATLAB R2023a or newer:

```matlab
buildtool test      % run the tests in tests/
buildtool           % package dist/trnrun-v<version>-win_amd64.mltbx
```

The manager tests run the real `trnrund.exe` from `toolbox/bin`. Python plays
TRNRun, as it does in the Python library's tests. Without the executable or
a Python interpreter (see `pyenv`), those tests are skipped.
