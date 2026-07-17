# TRNRun - Runner

`trnrun.exe` wraps the TRNSYS executable (`TrnEXE64.exe` / `TrnEXE.exe`) to provide reliable,
automated execution of TRNSYS simulations from the command line. It serializes launches
across the machine, verifies that the simulation has started successfully, streams progress
and log output as line-delimited JSON, and exits with a code describing the outcome, making
it suitable both for interactive use and for integration into scripts, parsers, and
job-orchestration tools.

## Contents

- [Why](#why)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Output](#output)
- [Exit codes](#exit-codes)
- [Command-line reference](#command-line-reference)
- [Recipes](#recipes)
- [Caveats](#caveats)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgments](#acknowledgments)

## Why

Automating TRNSYS around `TrnEXE` directly presents some challenges: safe concurrent runs are
not fully supported, process startup does not guarantee that the simulation is running, progress is
only visible in the GUI, and diagnostics are written to `.log` file. `trnrun.exe` addresses each of these.

## Requirements

- Windows
- TRNSYS v17 or TRNSYS v18.
- *Optional: Progress Tracker (Type3830)*

## Installation

### Prebuilt binary

Download `trnrun.exe` from the **Releases** page of this repository.

### From source

See [Building](#building).

## Quick start

```bash
# Run a deck; the TRNSYS window stays hidden (default)
trnrun "C:\path\to\deck.dck"

# Show the TRNSYS window and close it automatically when the run finishes
trnrun "C:\path\to\deck.dck" --guiVisibility:auto

# Full monitoring: progress, ETA, and stall detection (deck must include Type3830)
trnrun "C:\path\to\deck.dck" --watchTmp:true --stallTimeout:120000 --killOnStall:true
```

The deck may be passed as the first positional argument or via `--deckFile`. If neither is
supplied, a native file picker opens for selecting a `.dck` / `.trd` file.

If TRNSYS is not installed at the default location (`C:\TRNSYS18\Exe\TrnEXE64.exe`), specify
the path to `TrnEXE64.exe` / `TrnEXE.exe` with `--trnexePath`.

```bash
trnrun --help      # full usage
trnrun --version   # version information
```

## Output

Every event is a self-contained JSON object on a single line
([JSON Lines](https://jsonlines.org/)), written to stdout. With `--writeLog:true`, the same lines are appended to `<deckFile>.jsonl`.

### Events

```json
{"kind":"STATUS","timestamp":"ISO-8601","status":"PENDING|LAUNCHING|RUNNING|DONE|CANCELLED|ERROR|TIMEOUT|STALLED"}
{"kind":"CONFIG","timestamp":"ISO-8601","start":"hour","stop":"hour","step":"hour"}
{"kind":"PROGRESS","timestamp":"ISO-8601","time":"hour","percent":"[0, 1]","elapsed":"milliseconds","eta":"milliseconds"}
{"kind":"LOG","timestamp":"ISO-8601","severity":"Notice|Warning|Fatal","time":"hour","unitID":"OPTIONAL[INT]","typeID":"OPTIONAL[INT]","messageCode":"OPTIONAL[INT]","message":"OPTIONAL[STRING]","information":"OPTIONAL[STRING]"}
```

- `elapsed` and `eta` are in milliseconds; `percent` is in `[0, 1]`; `time`, `start`, `stop`,
  and `step` are simulation hours.
- `CONFIG` is emitted once, on the first successful `*.tmp` read.
- Optional `LOG` fields are omitted when TRNSYS reports them as not applicable/available.

### Simulation states

Reported as `STATUS` events:

| Status | Meaning |
| --- | --- |
| `PENDING` | Waiting to acquire the global launch mutex. |
| `LAUNCHING` | Mutex acquired; TrnEXE is being started. |
| `RUNNING` | Launch detection passed; the simulation is being monitored. |
| `DONE` | Completed successfully. |
| `CANCELLED` | The process exited before simulation time reached 100 %. |
| `ERROR` | Failed to launch, died during startup, or logged a fatal error. |
| `TIMEOUT` | Exceeded `--watchTimeout` (or `--detectTimeout` with `--killOnTimeout`). |
| `STALLED` | Simulation time stopped advancing for longer than `--stallTimeout`. |

> `CANCELLED` and `STALLED` require `--watchTmp:true` (Type3830), since both are derived from
> simulation progress. Without it, an early exit is reported as `DONE`.

### Example

```json
{"kind":"STATUS","timestamp":"2026-06-19T19:37:13","status":"PENDING"}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:14","status":"LAUNCHING"}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:15","status":"RUNNING"}
{"kind":"CONFIG","timestamp":"2026-06-19T19:37:15","start":0.0,"stop":10000.0,"step":0.1}
{"kind":"LOG","timestamp":"2026-06-19T19:37:15","severity":"Notice","time":0.0,"message":"\"Type169.dll\" was found but did not contain any components from the input file."}
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:15","time":221.6,"percent":0.0222,"elapsed":287.0,"eta":12664.26}
[...]
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:23","time":10000.0,"percent":1.0,"elapsed":8663.0,"eta":0.0}
{"kind":"LOG","timestamp":"2026-06-19T19:37:23","severity":"Warning","time":10000.0,"unitID":5,"typeID":139,"message":"Furnace fan mass balance failed during 100000 timesteps. Please check the connections."}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:23","status":"DONE"}
```

## Exit codes

The exit code mirrors the final simulation state, so scripts can branch without parsing JSON:

| Exit code | Meaning |
| --- | --- |
| `0` | Simulation completed successfully |
| `1` | Fatal error during execution |
| `2` | Usage or validation error (unknown flag, bad value, missing deck/executable) |
| `124` | Simulation exceeded runtime limit |
| `125` | Simulation stalled (no progress detected) |
| `130` | Simulation was cancelled |

## Command-line reference

Flags use `--name:value` (or `--name=value`). Booleans accept `true` / `false`.

### Core settings

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `--deckFile` | `String` | `""` (opens file dialog) | Path to the TRNSYS deck (`.dck` / `.trd`). Can also be passed as the first positional argument. |
| `--trnexePath` | `String` | `C:\TRNSYS18\Exe\TrnEXE64.exe` | Path to the TRNSYS executable (`TrnEXE64.exe` or `TrnEXE.exe`). |
| `--guiVisibility` | `String` | `hidden` | TRNSYS window behavior. Accepts `keep`/`keepopen`, `auto`/`autoclose`, `min`/`minimized`, `minauto`/`minimizedauto`, `hidden`. |

`guiVisibility` modes:

| Mode | Window | After the run |
| --- | --- | --- |
| `keep` | visible | stays open |
| `auto` | visible | closes |
| `min` | minimized | stays open |
| `minauto` | minimized | closes |
| `hidden` | none | n/a |

The minimized modes are synthesized: TrnEXE has no switch for them, so the window is launched
visible and then minimized via Win32 without stealing focus. Plotter windows that TRNSYS opens
later in the run are not re-minimized.

### Launch detection

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `--waitForGui` | `Boolean` | `true` | Wait for a TRNSYS top-level window before releasing the launch mutex. |
| `--waitForLst` | `Boolean` | `true` | Wait for the `*.lst` component-order header, indicating the deck parsed successfully. |
| `--waitForTmp` | `Boolean` | `false` | Wait for the `*.tmp` file to appear. (Requires Type3830.) |
| `--detectTimeout` | `Integer` | `0` | Shared timeout in ms across all enabled detection stages; `0` = unlimited. |
| `--extraDelay` | `Integer` | `0` | Additional delay in ms after detection passes, before monitoring starts. |

### Runtime monitoring

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `--pollMs` | `Integer` | `100` | Polling interval in ms for the output files and the process. |
| `--watchLog` | `Boolean` | `true` | Stream `*.log` entries as `LOG` events. |
| `--watchTmp` | `Boolean` | `false` | Stream `*.tmp` updates as `CONFIG`/`PROGRESS` events. (Requires Type3830.) |
| `--watchTimeout` | `Integer` | `0` | Maximum monitoring duration in ms; `0` = unlimited. Values below `pollMs` are raised to `pollMs`. |
| `--stallTimeout` | `Integer` | `0` | Maximum time in ms simulation time may go without advancing; `0` = disabled. Requires `--watchTmp`. Values below `pollMs` are raised to `pollMs`. |
| `--killOnTimeout` | `Boolean` | `false` | Kill the TRNSYS process on a detection or watch timeout. If `false`, the runner waits for it to exit. |
| `--killOnStall` | `Boolean` | `false` | Kill the TRNSYS process when a stall is detected. If `false`, the runner waits for it to exit. |

### Logging & cleanup

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `--severity` | `String` | `Notice` | Minimum log severity to emit. Accepts `Notice`, `Warning`, `Fatal`. Fatal entries always end the run, even when filtered out. |
| `--writeLog` | `Boolean` | `true` | Also append every event to `<deckFile>.jsonl`. |
| `--clean` | `Boolean` | `false` | On a successful run, delete `*.tmp`, `*.log`, `*.lst`, and `*.PTI`. |

### Meta

| Option | Description |
| --- | --- |
| `-h`, `--help` | Show usage and exit. |
| `-v`, `--version` | Show version and exit. |

## Recipes

### Unattended batch runs

Cap the runtime, terminate stalled runs, clean up simulation artifacts, and branch on the
exit code:

```powershell
foreach ($deck in Get-ChildItem .\decks\*.dck) {
    trnrun $deck.FullName --watchTmp:true `
        --watchTimeout:7200000 --killOnTimeout:true `
        --stallTimeout:300000 --killOnStall:true `
        --clean:true
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$($deck.Name) failed with exit code $LASTEXITCODE"
    }
}
```

### Live progress with `jq`

```bash
trnrun building.dck --watchTmp:true |
  jq -r 'select(.kind == "PROGRESS") | "\(.percent * 100 | floor) %  ETA \(.eta / 1000 | round) s"'
```

### Warnings and errors only

```bash
trnrun building.dck --severity:Warning
```

Fatal entries still end the run, even when filtered out of the output.

## Caveats

- **Windows only.** The runner is built directly on Win32 primitives (job objects, named
  mutexes, window management); there is no non-Windows build.
- **One simulation per machine at a time, by design.** Concurrent invocations queue on the
  global mutex and report `PENDING` until the lock is acquired.
- **Progress-based features need Type3830.** Without the `*.tmp` file there is no
  `CONFIG`/`PROGRESS` stream, no stall detection, and no way to distinguish a cancelled run
  from a completed one.

## Development

`runner` is written in [Nim](https://nim-lang.org/) and built as a standalone executable
(`trnrun.exe`) used by the TRNRun tools.

### Building

You need the [Nim](https://nim-lang.org/install.html) compiler and
[Zig](https://ziglang.org/download/) (used as the C compiler). From the `runner` directory:

```powershell
nimble zigbuild
```

### Module layout

| Module | Responsibility |
| --- | --- |
| `runner.nim` | CLI entry point; parses flags and maps the result to an exit code. |
| `simulate.nim` | Orchestrates the lifecycle: VALIDATION → LAUNCH → RUNNING → COMPLETED. |
| `wait.nim` | Readiness detection (GUI / `.lst` / `.tmp`) and GUI minimization. |
| `monitor.nim` | Poll loop; parses `.tmp` and `.log` into `CONFIG`/`PROGRESS`/`LOG` events. |
| `mutex.nim` | Machine-wide named mutex serializing TRNSYS launches. |
| `job.nim` | Windows job object binding child processes to the runner's lifetime. |
| `filedialog.nim` | Native `GetOpenFileNameW` deck picker. |

## Contributing

Issues and pull requests are welcome. When reporting a bug, please include the output of
`trnrun --version`, your TRNSYS version, the exact command line you used, and the emitted
events (the `<deckFile>.jsonl` file is ideal for this).

## License

<!-- TODO: choose a license, add a LICENSE file, and update the badge at the top. -->
This project is distributed under the terms of the [LICENSE](LICENSE) file.

## Acknowledgments

[TRNSYS](https://www.trnsys.com/) is a commercial simulation environment; this project is an
independent wrapper and is not affiliated with or endorsed by the developers or distributors
of TRNSYS. Built with [Nim](https://nim-lang.org/) and [Zig](https://ziglang.org/).
