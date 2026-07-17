# TRNRun - Runner

`trnrun.exe` provides a monitored execution layer around the TRNSYS executable (`TrnEXE64.exe` / `TrnEXE.exe`) to provide reliable,
automated execution of TRNSYS simulations from the command line. It serializes launches detection
across the machine, verifies that the simulation has initialized successfully, treams progress, status, and log output as line-delimited JSON events, and exits with a code describing the outcome, making
it suitable for integration into scripts, parsers, and
job-orchestration tools.

## Requirements

- Windows
- TRNSYS v17 or v18.
- _Optional: Progress Tracker (Type3830)_

## Installation

`trnrun-runner` is written in [Nim](https://nim-lang.org/) and built as a standalone executable
(`trnrun.exe`) used by the TRNRun tools.

### Prebuilt binary

Download the latest `trnrun.exe` from the **Releases** page of this repository and
place it somewhere accessible from your system.

### Build from source

To build `trnrun.exe` locally, install:

- [Nim](https://nim-lang.org/install.html) compiler
- [Zig](https://ziglang.org/download/) (used as the C compiler)

From the `runner` directory, run:

```powershell
nimble zigbuild
```

## Quick start

```bash
# Run a deck
trnrun "C:\path\to\deck.dck"

# Show the TRNSYS window and close it automatically when the run finishes
trnrun "C:\path\to\deck.dck" --guiVisibility:auto

# Full monitoring: progress and ETA (requires Type3830 in the deck)
trnrun "C:\path\to\deck.dck" --watchTmp:true
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

Every event is emitted as a self-contained JSON object on a single line
([JSON Lines](https://jsonlines.org/)), written to stdout. With `--writeLog:true`, the same lines are appended to `<deckFile>.jsonl`.

### Events

```json
{"kind":"STATUS","timestamp":"ISO-8601","status":"PENDING|LAUNCHING|RUNNING|DONE|CANCELLED|ERROR|TIMEOUT|STALLED"}
{"kind":"CONFIG","timestamp":"ISO-8601","start":"hour","stop":"hour","step":"hour"}
{"kind":"PROGRESS","timestamp":"ISO-8601","time":"hour","percent":"0-1","elapsed":"milliseconds","eta":"milliseconds"}
{"kind":"LOG","timestamp":"ISO-8601","severity":"Notice|Warning|Fatal","time":"hour","unitID":"OPTIONAL[INT]","typeID":"OPTIONAL[INT]","messageCode":"OPTIONAL[INT]","message":"OPTIONAL[STRING]","information":"OPTIONAL[STRING]"}
```

- `elapsed` and `eta` are in milliseconds; `percent` is in `[0, 1]`; `time`, `start`, `stop`,
  and `step` are simulation hours.
- `CONFIG` is emitted once, on the first successful `*.tmp` read.

### Simulation states

Reported as `STATUS` events:

| Status      | Meaning                                                                  |
| ----------- | ------------------------------------------------------------------------ |
| `PENDING`   | Waiting to acquire the global mutex.                                     |
| `LAUNCHING` | Mutex acquired; TrnEXE is being started.                                 |
| `RUNNING`   | Startup detection passed; the simulation is being monitored.             |
| `DONE`      | Completed successfully.                                                  |
| `CANCELLED` | The process exited before simulation time reached 100 %.                 |
| `ERROR`     | Failed to launch, died during startup, or logged a fatal error.          |
| `TIMEOUT`   | Exceeded `--watchTimeout` (or `--detectTimeout` with `--killOnTimeout`). |
| `STALLED`   | Simulation time stopped advancing for longer than `--stallTimeout`.      |

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

| Exit code | Meaning                                                                      |
| --------- | ---------------------------------------------------------------------------- |
| `0`       | Simulation completed successfully                                            |
| `1`       | Fatal error during execution                                                 |
| `2`       | Usage or validation error (unknown flag, bad value, missing deck/executable) |
| 124       | Runtime timeout exceeded (--watchTimeout)                                    |
| 125       | Simulation stalled (--stallTimeout)                                          |
| `130`     | Simulation was cancelled                                                     |

## Command-line reference

Flags use `--name:value` (or `--name=value`).

### Core settings

| Option            | Type     | Default                        | Description                                                                                                                    |
| ----------------- | -------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `--deckFile`      | `String` | `""` (opens file dialog)       | Path to the TRNSYS deck (`.dck` / `.trd`). Can also be passed as the first positional argument.                                |
| `--trnexePath`    | `String` | `C:\TRNSYS18\Exe\TrnEXE64.exe` | Path to the TRNSYS executable (`TrnEXE64.exe` or `TrnEXE.exe`).                                                                |
| `--guiVisibility` | `String` | `hidden`                       | TRNSYS window behavior. Accepts `keep`/`keepOpen`, `auto`/`autoClose`, `min`/`minimized`, `minAuto`/`minimizedAuto`, `hidden`. |

`guiVisibility` modes:

| Mode                    | Window    | After the run |
| ----------------------- | --------- | ------------- |
| `keep/keepOpen`         | visible   | stays open    |
| `auto/autoClose`        | visible   | closes        |
| `min/minimized`         | minimized | stays open    |
| `minAuto/minimizedAuto` | minimized | closes        |
| `hidden`                | none      | closes        |

### Launch detection

Launch detection determines when TRNSYS startup has completed, allowing the global mutex to be released and another simulation to start.

| Option            | Type      | Default | Description                                               |
| ----------------- | --------- | ------- | --------------------------------------------------------- |
| `--waitForGui`    | `Boolean` | `true`  | Wait for a TRNSYS GUI.                                    |
| `--waitForLst`    | `Boolean` | `true`  | Wait for a specific string in the `*.lst`.                |
| `--waitForTmp`    | `Boolean` | `false` | Wait for the `*.tmp` file to appear. (Requires Type3830.) |
| `--detectTimeout` | `Integer` | `0`     | timeout in ms for the detection stages; `0` = unlimited.  |
| `--extraDelay`    | `Integer` | `0`     | Additional delay in ms after detection passes             |

### Runtime monitoring

| Option            | Type      | Default | Description                                                                                                 |
| ----------------- | --------- | ------- | ----------------------------------------------------------------------------------------------------------- |
| `--pollMs`        | `Integer` | `100`   | Polling interval in ms for the output files and the process.                                                |
| `--watchLog`      | `Boolean` | `true`  | Stream `*.log` entries as `LOG` events.                                                                     |
| `--watchTmp`      | `Boolean` | `false` | Stream `*.tmp` updates as `CONFIG`/`PROGRESS` events. (Requires Type3830.)                                  |
| `--watchTimeout`  | `Integer` | `0`     | Maximum monitoring duration in ms; `0` = unlimited.                                                         |
| `--stallTimeout`  | `Integer` | `0`     | Maximum wall-clock time in ms without simulation progress advancing; `0` = disabled. Requires `--watchTmp`. |
| `--killOnTimeout` | `Boolean` | `false` | Kill the TRNSYS process on a detection or watch timeout. If `false`, the runner waits for it to exit.       |
| `--killOnStall`   | `Boolean` | `false` | Kill the TRNSYS process when a stall is detected. If `false`, the runner waits for it to exit.              |

### Logging & cleanup

| Option       | Type      | Default  | Description                                                         |
| ------------ | --------- | -------- | ------------------------------------------------------------------- |
| `--severity` | `String`  | `Notice` | Minimum log severity to emit. Accepts `Notice`, `Warning`, `Fatal`. |
| `--writeLog` | `Boolean` | `false`  | Also append every event to `<deckFile>.jsonl`.                      |
| `--clean`    | `Boolean` | `false`  | On a successful run, delete `*.tmp`, `*.log`, `*.lst`, and `*.PTI`. |

## Recipes

### Batch runs

Run multiple TRNSYS simulations one at a time. Each simulation is monitored
for timeout and stalled execution, temporary files are cleaned after completion, and the exit code
is checked to identify failed runs.

```powershell
$trnrun = "C:\Path\To\trnrun.exe"

foreach ($deck in Get-ChildItem .\decks\*.dck) {
    & $trnrun $deck.FullName `
        --watchTmp:true `
        --watchTimeout:7200000 `
        --killOnTimeout:true `
        --stallTimeout:300000 `
        --killOnStall:true `
        --clean:true

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$($deck.Name) failed with exit code $LASTEXITCODE"
    }
}
```

### Concurrent Batch runs

Launch multiple TRNSYS simulations in parallel, with each simulation running as an independent process. Each process is independently monitored for runtime limits and stalled execution,
temporary artifacts are cleaned after completion, and failures are reported through the exit code.

```powershell
$trnrun = "C:\Path\To\trnrun.exe"

foreach ($deck in Get-ChildItem .\dck\*.dck) {
    $deckPath = $deck.FullName

    wt new-tab powershell -NoExit -Command {
        param($exe, $deck)

        & $exe $deck `
            --watchTmp:true `
            --watchTimeout:7200000 `
            --killOnTimeout:true `
            --stallTimeout:300000 `
            --killOnStall:true `
            --clean:true

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "$([System.IO.Path]::GetFileName($deck)) failed with exit code $LASTEXITCODE"
        }
    } -ArgumentList $trnrun, $deckPath
}
```

### Live progress with `jq`

```bash
trnrun deck.dck --watchTmp:true |
  jq -r '
    select(.kind == "PROGRESS") |
    (.percent * 30 | floor) as $filled |
    "[" + ("#" * $filled) + ("-" * (30-$filled)) + "] " +
    ((.percent * 100) | floor | tostring) + "% ETA " +
    ((.eta / 1000) | round | tostring) + "s"
  ' |
  ForEach-Object {
      Write-Host "`r$(' ' * 60)`r$_" -NoNewline
  }
```
