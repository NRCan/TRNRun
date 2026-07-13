# TRNRun Runner

Command-line executable for launching, monitoring, and reporting TRNSYS simulations.

It wraps the TRNSYS `TRNEXE.exe` executable, launching, monitoring, and reporting simulation execution through structured JSON events.

## Dependencies

Required:

- TRNSYS v17 or TRNSYS v18

Optional:

- Progress Tracker (Type3830) TRNSYS component
  - Enables `*.tmp` progress file detection
  - Enables simulation progress tracking
  - Enables stall detection

## Key Features

- **Safe Execution**: Ensures safe execution by preventing concurrent TRNSYS instances during process launch.
- **Continuous Runtime Monitoring**: Streams logs and simulation progress in real time.
- **Structured Output**: Emits structured JSON status events to stdout, designed for piping into downstream parsers or job orchestration tools, with an option to also write directly to a `*.jsonl` file.
- **Simulation State**: Detects and reports completion, crashes, errors, timeouts, and stalls based on runtime signals.

## Usage

The recommended way to launch TRNRun runner is via the command line. If launched directly without passing a deck file as a positional argument or via the --deckFile flag, it will open a file dialog prompting you to select a TRNSYS deck file.

```bash
trnrun "path/to/deck.dck" --guiVisibility=AutoClose
```

## Simulation State

- **PENDING**: Simulation is waiting to acquire the mutex lock.
- **LAUNCHING**: Simulation has acquired the mutex lock and is launching.
- **RUNNING**: Simulation has fully launched and is now running.
- **DONE**: Simulation has completed successfully.
- **CANCELLED**: Simulation was cancelled before completion.
- **ERROR**: Simulation encountered a fatal error during execution.
- **TIMEOUT**: Simulation exceeded the allowed runtime.
- **STALLED**: Simulation is stalled and not making progress.

## Outputs

TRNRun runner emits JSON events derived from TRNEXE execution and file parsing

Schema:

```json
{"kind":"STATUS","timestamp":"ISO-8601","status":"PENDING|LAUNCHING|RUNNING|DONE|CANCELLED|ERROR|TIMEOUT|STALLED"}
{"kind":"CONFIG","timestamp":"ISO-8601","start":"hour","stop":"hour","step":"hour"}
{"kind":"PROGRESS","timestamp":"ISO-8601","time":"hour","percent":"[0, 1]","elapsed":"milliseconds","eta":"milliseconds"}
{"kind":"LOG","timestamp":"ISO-8601","severity":"Notice|Warning|Fatal","time":"hour","unitID":"OPTIONAL[INT]","typeID":"OPTIONAL[INT]","messageCode":"OPTIONAL[INT]","message":"OPTIONAL[STRING]","information":"OPTIONAL[STRING]"}
```

Example:

```json
{"kind":"STATUS","timestamp":"2026-06-19T19:48:18","status":"PENDING"}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:14","status":"LAUNCHING"}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:15","status":"RUNNING"}
{"kind":"CONFIG","timestamp":"2026-06-19T19:37:15","start":0.0,"stop":10000.0,"step":0.1}
{"kind":"LOG","timestamp":"2026-06-19T19:37:15","severity":"Notice","time":0.0,"message":"\"Type169.dll\" was found but did not contain any components from the input file."}
{"kind":"LOG","timestamp":"2026-06-19T19:37:15","severity":"Notice","time":0.0,"message":"\"Type82Lib64.dll\" was found but did not contain any components from the input file."}
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:15","time":221.6,"percent":0.0222,"elapsed":287.0,"eta":12664.26}
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:15","time":350.6,"percent":0.0351,"elapsed":396.0,"eta":10898.92}
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:15","time":481.6,"percent":0.0482,"elapsed":507.0,"eta":10020.41}
[...]
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:23","time":9884.1,"percent":0.9884,"elapsed":8553.0,"eta":100.29}
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:23","time":10000.0,"percent":1.0,"elapsed":8663.0,"eta":0.0}
{"kind":"LOG","timestamp":"2026-06-19T19:37:23","severity":"Warning","time":10000.0,"unitID":5,"typeID":139,"message":"Furnace fan mass balance failed during 100000 timesteps. Please check the connections."}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:23","status":"DONE"}
```

## Command-Line Options

### Core Settings

| Option          | Type     | Default                          | Description                                                                                       |
| --------------- | -------- | -------------------------------- | ------------------------------------------------------------------------------------------------- |
| --deckFile      | `String` | `""` (Open File Dialog)          | Path to the TRNSYS deck file. Can also be passed as the first positional argument.                |
| --trnexePath    | `String` | `"C:\TRNSYS18\Exe\TrnEXE64.exe"` | Path to the TRNSYS executable (`TrnEXE64.exe` or `TrnEXE.exe`).                                   |
| --guiVisibility | `String` | `hidden`                         | Controls the TRNSYS window behavior. Accepts: `Keep`/`KeepOpen`, `Auto`/`AutoClose`, or `Hidden`. |

### Launch Detection Options

| Option          | Type      | Default | Description                                                                                                                                                             |
| --------------- | --------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| --waitForGui    | `Boolean` | `true`  | Enables detection of the TRNSYS GUI window before releasing the global mutex lock.                                                                                      |
| --waitForLst    | `Boolean` | `true`  | Enables detection of the `*.lst` file before releasing the global mutex lock.                                                                                           |
| --waitForTmp    | `Boolean` | `false` | Enables detection of the `*.tmp` file before releasing the global mutex lock. (Required `ProgressTracker-Type3830`)                                                     |
| --detectTimeout | `Integer` | `0`     | Timeout in milliseconds for detecting the TRNSYS GUI, `*.lst` and/or `*.tmp` files before automatically releasing the global mutex lock. Value of `0` means no timeout. |
| --extraDelay    | `Integer` | `0`     | Additional delay in milliseconds before launching the TRNSYS simulation.                                                                                                |

### Runtime Monitoring

| --pollMs | `Integer` | `100` | Frequency in milliseconds at which polling is performed. |
| --watchLog | `Boolean` | `true` | Enables monitoring of the simulation `*.log` file. |
| --watchTmp | `Boolean` | `false` | Enables monitoring of the simulation `*.tmp` file. (Required `ProgressTracker-Type3830`) |
| --watchTimeout | `Integer` | `0` | Timeout in milliseconds for monitoring the simulation `*.tmp` & `*.log` file. Value of `0` means no timeout. |
| --stallTimeout | `Integer` | `0` | Maximum time in milliseconds allowed without simulation progress before considering it stalled. Value of `0` means no timeout. (Required `ProgressTracker-Type3830`) |
| --killOnTimeout | `Boolean` | `false` | If `true`, forcefully kills the TRNSYS process if the `watchTimeout` limit is reached. |
| --killOnStall | `Boolean` | `false` | If `true`, forcefully kills the TRNSYS process if the `stallTimeout` limit is reached. |

### Logging & Cleanup

| --severity | `String` | Notice | Sets the logging minimum severity level. Accepts: `Notice`, `Warning`, `Fatal`. |
| --writeLog | `Boolean` | `true` | If `true`, writes the json logs to a file `*.jsonl`. |
| --clean | `Boolean` | `false` | If `true`, cleans `*.lst`, `*.tmp`, `*.log` if simulation completed successfully. |

## Exit Codes

| Exit Code | Meaning                                   |
| --------- | ----------------------------------------- |
| `0`       | Simulation completed successfully         |
| `1`       | Fatal error during execution              |
| `124`     | Simulation exceeded runtime limit         |
| `125`     | Simulation stalled (no progress detected) |
| `130`     | Simulation was cancelled                  |

## Build

TRNRun Runner is written in Nim and is built as a standalone executable used by the TRNRun tools.

Requirements:

- Nim compiler
- Zig C compiler

Build:

From the `runner` directory:

```powershell
nimble zigbuild
```
