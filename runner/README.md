# TRNRun - Runner

`trnrun.exe` provides a monitored command-line execution layer around the TRNSYS
executables `TrnEXE64.exe` and `TrnEXE.exe`. It serializes launch and readiness
detection within the current Windows logon session, verifies startup signals,
streams progress, status, and log output as JSON Lines, and exits with a code
describing the outcome.

This makes the runner suitable for scripts, parsers, and job-orchestration tools.

## Requirements

- Windows.
- TRNSYS 17 or 18.
- Optional: Progress Tracker (Type3830) for progress and stall monitoring.

## Installation

The runner is written in [Nim](https://nim-lang.org/) and built as the standalone
`trnrun.exe` executable used by the TRNRun tools.

### Prebuilt binary

Download the latest `trnrun.exe` from the **Releases** page of this repository and
place it somewhere accessible from your system.

### Build from source

To build `trnrun.exe` locally, install:

- [Nim](https://nim-lang.org/install.html) 2.2.10 or newer.
- [Zig](https://ziglang.org/download/), used as the C compiler.

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

The deck may be passed as the first positional argument or via `--deckFile`. If
neither is supplied, a native file picker opens for selecting a `.dck` or `.trd`
file.

If TRNSYS is not installed at the default location
(`C:\TRNSYS18\Exe\TrnEXE64.exe`), specify the path to `TrnEXE64.exe` or
`TrnEXE.exe` with `--trnexePath`.

```bash
trnrun --help      # full usage
trnrun --version   # version information
```

## Output

Every event is emitted to stdout as a self-contained JSON object on one line
([JSON Lines](https://jsonlines.org/)). With `--writeEvents:true`, the same lines
are mirrored to a file whose extension is replaced with `.jsonl`, truncating any
existing file when the run starts. For example, `model.dck` produces
`model.jsonl`, not `model.dck.jsonl`.

### Events

Representative event shapes, using the actual JSON value types:

```json
{"kind":"SETTING","timestamp":"2026-06-19T19:37:13","trnexePath":"C:\\TRNSYS18\\Exe\\TrnEXE64.exe","guiVisibility":"hidden","waitForGui":true,"waitForLst":true,"waitForTmp":false,"detectTimeoutMs":300000,"extraDelayMs":0,"watchLog":true,"watchTmp":true,"watchTimeoutMs":0,"stallTimeoutMs":0,"pollMs":100,"cleanOnSuccess":false,"killOnTimeout":false,"killOnStall":false,"severity":"Notice","writeEvents":false,"seq":1}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:13","status":"PENDING","seq":2}
{"kind":"CONFIG","timestamp":"2026-06-19T19:37:15","start":0.0,"stop":8760.0,"step":0.25,"seq":3}
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:15","time":24.0,"percent":0.0027,"elapsed":287.0,"eta":105576.7,"seq":4}
{"kind":"LOG","timestamp":"2026-06-19T19:37:15","severity":"Warning","time":24.0,"unitID":5,"typeID":139,"messageCode":101,"message":"Example warning","information":"Example details","seq":5}
```

- Timestamps use `yyyy-MM-ddTHH:mm:ss` at second precision. They contain no UTC
  offset.
- `elapsed` and `eta` are milliseconds; `percent` is in `[0, 1]`; `time`,
  `start`, `stop`, and `step` are simulation hours.
- `seq` starts at `1` and increments once per emitted event, allowing consumers
  to order lines and detect dropped events.
- `SETTING` is always first and records the configured runner settings.
- `CONFIG` is emitted on the first successful `.tmp` snapshot.
- Optional `LOG` fields (`unitID`, `typeID`, `messageCode`, `message`, and
  `information`) are omitted when absent; they are never emitted as `null`.

### Simulation states

Reported as `STATUS` events:

| Status      | Meaning                                                                  |
| ----------- | ------------------------------------------------------------------------ |
| `PENDING`   | Waiting to acquire the launch mutex for the current Windows logon session. |
| `LAUNCHING` | Mutex acquired; TrnEXE is being started.                                  |
| `RUNNING`   | The runner entered runtime monitoring.                                     |
| `DONE`      | Completed successfully.                                                   |
| `CANCELLED` | The process exited and its last TMP snapshot was below 100 percent.        |
| `ERROR`     | TrnEXE failed to launch or a fatal log entry was detected.                 |
| `TIMEOUT`   | Exceeded `--watchTimeout` (or `--detectTimeout` with `--killOnTimeout`).  |
| `STALLED`   | Simulation time stopped advancing for longer than `--stallTimeout`.       |

> `CANCELLED` and `STALLED` require `--watchTmp:true` and at least one
> successfully parsed Type3830 `.tmp` snapshot. Without a snapshot, an
> otherwise non-fatal early exit is reported as `DONE`; a fatal log entry can
> still produce `ERROR`. Stall detection remains disabled until a snapshot is
> available.

### Example

```json
{"kind":"SETTING","timestamp":"2026-06-19T19:37:13","trnexePath":"C:\\TRNSYS18\\Exe\\TrnEXE64.exe","guiVisibility":"hidden","waitForGui":true,"waitForLst":true,"waitForTmp":false,"detectTimeoutMs":300000,"extraDelayMs":0,"watchLog":true,"watchTmp":true,"watchTimeoutMs":0,"stallTimeoutMs":0,"pollMs":100,"cleanOnSuccess":false,"killOnTimeout":false,"killOnStall":false,"severity":"Notice","writeEvents":false,"seq":1}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:13","status":"PENDING","seq":2}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:14","status":"LAUNCHING","seq":3}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:15","status":"RUNNING","seq":4}
{"kind":"CONFIG","timestamp":"2026-06-19T19:37:15","start":0.0,"stop":10000.0,"step":0.1,"seq":5}
{"kind":"LOG","timestamp":"2026-06-19T19:37:15","severity":"Notice","time":0.0,"message":"\"Type169.dll\" was found but did not contain any components from the input file.","seq":6}
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:15","time":221.6,"percent":0.0222,"elapsed":287.0,"eta":12664.26,"seq":7}
[...]
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:23","time":10000.0,"percent":1.0,"elapsed":8663.0,"eta":0.0,"seq":185}
{"kind":"LOG","timestamp":"2026-06-19T19:37:23","severity":"Warning","time":10000.0,"unitID":5,"typeID":139,"message":"Furnace fan mass balance failed during 100000 timesteps. Please check the connections.","seq":186}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:23","status":"DONE","seq":187}
```

## Exit codes

| Exit code | Meaning                                                                      |
| --------- | ---------------------------------------------------------------------------- |
| `0`       | Simulation completed successfully.                                            |
| `1`       | Fatal error during execution.                                                 |
| `2`       | Usage or validation error (unknown flag, bad value, missing deck/executable). |
| `124`     | Runtime timeout exceeded (`--watchTimeout`).                                  |
| `125`     | Simulation stalled (`--stallTimeout`).                                        |
| `130`     | Simulation was cancelled.                                                     |

## Command-line reference

Flags use `--name:value` (or `--name=value`).

### Core settings

| Option            | Type     | Default                        | Description                                                                                                                    |
| ----------------- | -------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `--deckFile`      | `string` | not set (opens file dialog)      | Path to a TRNSYS deck (`.dck` or `.trd`); may also be the first positional argument.                                              |
| `--trnexePath`    | `string` | `C:\TRNSYS18\Exe\TrnEXE64.exe` | Path to the TRNSYS executable (`TrnEXE64.exe` or `TrnEXE.exe`).                                                                  |
| `--guiVisibility` | `string` | `hidden`                         | Window behavior. Accepts `keep`/`keepopen`, `auto`/`autoclose`, `min`/`minimized`, `minauto`/`minimizedauto`, or `hidden`. |

`guiVisibility` modes:

| Mode                    | Window    | After the run |
| ----------------------- | --------- | ------------- |
| `keep` / `keepopen`          | visible   | stays open    |
| `auto` / `autoclose`         | visible   | closes        |
| `min` / `minimized`          | minimized | stays open    |
| `minauto` / `minimizedauto`  | minimized | closes        |
| `hidden`                     | none      | closes        |

### Launch detection

Launch detection determines when TRNSYS startup has completed, allowing the
session-scoped launch mutex to be released so another simulation can start.

| Option            | Type      | Default | Description                                               |
| ----------------- | --------- | ------- | --------------------------------------------------------- |
| `--waitForGui`    | `boolean` | `true`  | Wait for a recognized TRNSYS top-level window.                            |
| `--waitForLst`    | `boolean` | `true`  | Wait for the component-order header in the `.lst` file.                   |
| `--waitForTmp`    | `boolean` | `false` | Wait for the `.tmp` file to appear; requires Type3830.                    |
| `--detectTimeout` | `integer` | `300000` | Shared readiness deadline in milliseconds. `0` means unlimited, which lets one wedged deck hold the session launch mutex. |
| `--extraDelay`    | `integer` | `0`     | Additional delay in milliseconds after all readiness stages pass.        |

### Runtime monitoring

| Option            | Type      | Default | Description                                                                                                 |
| ----------------- | --------- | ------- | ----------------------------------------------------------------------------------------------------------- |
| `--pollMs`        | `integer` | `100`   | Polling interval in milliseconds for output files and the process.                                                   |
| `--watchLog`      | `boolean` | `true`  | Stream `.log` entries as `LOG` events.                                                                               |
| `--watchTmp`      | `boolean` | `false` | Stream Type3830 `.tmp` updates as `CONFIG` and `PROGRESS` events.                                                     |
| `--watchTimeout`  | `integer` | `0`     | Maximum monitoring duration in milliseconds; `0` means unlimited.                                                    |
| `--stallTimeout`  | `integer` | `0`     | Maximum time without progress; `0` disables it. Requires `--watchTmp:true` and a successful TMP snapshot.           |
| `--killOnTimeout` | `boolean` | `false` | Kill TrnEXE on timeout. If false, detection continues into monitoring; after a watch timeout, the runner waits for process exit. |
| `--killOnStall`   | `boolean` | `false` | Kill TrnEXE when a stall is detected. If false, the runner waits for it to exit.                                     |

### Logging and cleanup

| Option       | Type      | Default  | Description                                                         |
| ------------ | --------- | -------- | ------------------------------------------------------------------- |
| `--severity`    | `string`  | `Notice` | Minimum emitted log severity: `Notice`, `Warning`, or `Fatal`.                  |
| `--writeEvents` | `boolean` | `false`  | Mirror events to `.jsonl`, replacing the deck extension and existing file.     |
| `--clean`       | `boolean` | `false`  | After success, delete the deck's `.tmp`, `.log`, `.lst`, and `.PTI` sidecars. |

## Recipes

### Batch runs

Decks run one at a time in your current console, so output from each run appears
in order and you only ever have one simulation competing for the machine. Each
run gets its own runtime and stall monitoring and cleans up its temp artifacts on
completion; a non-zero exit is reported as a warning and the loop continues to
the next deck.

```powershell
$Exe      = 'C:\path\to\trnrun.exe'
$DckFiles = Get-ChildItem 'C:\path\to\dck\*.dck' | ForEach-Object FullName

foreach ($Deck in $DckFiles) {
    $name = [IO.Path]::GetFileName($Deck)
    Write-Host "Running $name"
    & $Exe $Deck `
        --watchTmp:true `
        --watchTimeout:7200000 `
        --killOnTimeout:true `
        --stallTimeout:300000 `
        --killOnStall:true `
        --clean:true
    if ($LASTEXITCODE) {
        Write-Warning "$name failed with exit code $LASTEXITCODE"
    }
}
```

### Concurrent batch runs

Each deck runs in its own `powershell.exe` window as an independent process, so
runs proceed in parallel and one failure doesn't stop the rest. Every process
gets its own runtime and stall monitoring, cleans up its temp artifacts on
completion, and leaves its window open on non-zero exit so you can read the error.

```powershell
$Exe      = 'C:\path\to\trnrun.exe'
$DckFiles = Get-ChildItem 'C:\path\to\dck\*.dck' | ForEach-Object FullName

$worker = {
    param($Exe, $Deck)
    $name = [IO.Path]::GetFileName($Deck)
    $host.UI.RawUI.WindowTitle = "trnrun - $name"
    & $Exe $Deck `
        --watchTmp:true `
        --watchTimeout:7200000 `
        --killOnTimeout:true `
        --stallTimeout:300000 `
        --killOnStall:true `
        --clean:true
    if ($LASTEXITCODE) {
        Write-Warning "$name failed with exit code $LASTEXITCODE"
        Read-Host 'Window kept open. Press Enter to close' | Out-Null
    }
}

$DckFiles |
    Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object {
        $cmd     = "& {$worker} '$($Exe -replace "'","''")' '$($_ -replace "'","''")'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        Start-Process powershell.exe -ArgumentList '-NoProfile', '-EncodedCommand', $encoded
        Write-Host "Launched $([IO.Path]::GetFileName($_))"
    }
```
