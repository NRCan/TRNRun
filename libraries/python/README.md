# TRNRun for Python

Run TRNSYS simulations from Python through
[`trnrund`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund), which
the wheel bundles with `trnrun.exe`. Two levels:

- **`Daemon`**: a thin client. One method per trnrund command, returning
  simulations as typed `Simulation` records. For applications that do
  their own polling.
- **`SimulationManager`**: launches many simulations, blocks as you choose, and shows
  them live in the terminal. For scripts.

Requires Windows x64, Python 3.12+, and TRNSYS 17 or 18 for real runs.

## Daemon

```python
from trnrun import Daemon, SimulationSettings

with Daemon(workers=4) as daemon:
    sim_id = daemon.add("building-a.dck", SimulationSettings(gui_visibility="min"), label="a")
    sim = daemon.simulation(sim_id)          # Simulation(sim_id=1, deck='building-a.dck', state=QUEUED, ...)
    running = daemon.simulations("RUNNING")  # without logs unless with_logs=True
    daemon.cancel(sim_id)                    # a FINISHED one is left unchanged
    daemon.release(sim_id)                   # FINISHED only: trnrund forgets it
```

`request(dict)` sends any raw trnrund request and returns its raw response
dict, for anything the typed methods don't cover.

`Simulation` is a dataclass of trnrund's
[simulation fields](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#simulation-fields)
in snake_case: `state` and `status` are `SimulationState` and
`SimulationStatus` enums, progress (`sim_time`, `percent`, `elapsed_ms`,
`eta_ms`) and config (`start_time`, `stop_time`, `time_step`) are None until
TRNRun reports them, `logs` are `LogEvent`s, and timestamps are `datetime`s. `parse_simulation` turns a raw simulation dict
into one.
Runner options are a `SimulationSettings`, which names and types every TRNRun
option (`SimulationSettings(watch_tmp=True, trnexe_path=...)`;
`help(SimulationSettings)` lists them); trnrund checks their values when the
simulation is added. A field left at None keeps TRNRun's default; a missing
`trnexe_path` raises `FileNotFoundError` before queuing. `Simulation.trnrun_args`
holds the flags they became.
Requests are thread-safe: they take turns. Closing, or leaving the `with`
block, kills every unfinished run.

Errors: `RequestError` when trnrund refuses a request (missing deck, unknown
`simId`, releasing an unfinished run...), `DaemonExitedError` when it no longer
answers. Both subclass `TrnrunError`.

## SimulationManager

```python
from trnrun import SimulationManager, SimulationSettings

with SimulationManager(workers=4) as manager:
    for deck in decks:
        manager.add(deck, SimulationSettings(watch_tmp=True))
    manager.wait()

for sim in manager.simulations.values():
    print(sim.sim_id, sim.succeeded, sim.warnings)
```

`add` returns a `Simulation`, which the manager updates in place on each
refresh; `dataclasses.replace(sim)` takes a snapshot. `logs` are filled in once
it finishes. `wait_for` picks how `add` blocks:

| `wait_for`   | `add` returns                                              |
| ------------ | ---------------------------------------------------------- |
| `None`       | at once (default)                                          |
| `"QUEUED"`   | at once: trnrund has queued it before it answers           |
| `"RUNNING"`  | once it started, so the next one is added only then        |
| `"FINISHED"` | once it finished: one at a time                            |

`wait(*sims, until="FINISHED", timeout=None)` blocks the same way on any
simulations, by default all of them.

The terminal shows one live line per running simulation and prints each
finished one once. Nothing runs in the background: the display moves while
`add` or `wait` block, or when you call `refresh()`. Pass `display=False` to
turn it off. To stop one run, `manager.daemon.cancel(sim.sim_id)`.

## Development

```powershell
uv sync
uv run pytest
```

Tests run the bundled `trnrun/bin/trnrund.exe` with Python as the runner, so
they need neither TRNRun nor TRNSYS.
