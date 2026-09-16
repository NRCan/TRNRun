# TRNRun Runner

`trnrun.exe` is a Windows command-line runner for the TRNSYS executables
`TrnEXE64.exe` and `TrnEXE.exe`. It is designed for scripts and orchestration
systems that need reliable lifecycle signals:

- serializes launch and readiness detection across concurrent runners
- monitors TRNSYS sidecar files for logs and optional Type3830 progress
- emits a machine-readable JSON Lines event stream

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Settings](#settings)
- [Output protocol](#output-protocol)
- [Exit codes](#exit-codes)
- [Examples](#examples)

## Requirements

### Runtime

- Windows x64
- TRNSYS 17 or 18
- Optional: [Type3830 Progress Tracker](../type3830/) for progress, ETA,
  cancellation, and stall detection

### Development

- [Nim](https://nim-lang.org/install.html) 2.2.10 or newer
- [Zig](https://ziglang.org/download/) as the Windows C compiler and resource
  compiler
- [just](https://github.com/casey/just) for repository-root recipes

## Installation

Download and extract `trnrun-v<version>-win_amd64.zip` from
[GitHub Releases](https://github.com/NRCan/TRNRun/releases).

Or build from source, run the following from the repository root:

```powershell
Set-Location components/trnrun
nimble bin
```

The executable is written to `components/trnrun/build/trnrun.exe` relative to
the repository root.

## Quick start

Run a deck with the default hidden-window settings:

```powershell
trnrun "C:\path\to\deck.dck"
```

If TRNSYS is installed somewhere other than the default TRNSYS 18 path, select
its executable explicitly:

```powershell
trnrun "C:\path\to\deck.dck" `
    --trnexePath:"C:\TRNSYS17\Exe\TrnEXE.exe"
```

Enable Type3830 progress with timeout and stall detection:

```powershell
trnrun "C:\path\to\deck.dck" `
    --watchTmp:true `
    --watchTimeout:300000 `
    --stallTimeout:300000 `
    --killOnTimeout:true `
    --killOnStall:true
```

Running `trnrun` without a deck opens the native file picker. For all options
and version information:

```powershell
trnrun --help
trnrun --version
```

## Settings

Options accept either `--name:value` or `--name=value`. Boolean options require
an explicit `true` or `false`. All timeout, delay, and polling values are in
milliseconds.

### Deck, executable, and window

- _`--deckFile`_ (`string`, default: not set)

  Path to an existing `.dck` or `.trd` file. The deck path can also be passed
  directly without `--deckFile`. With no deck, open the native file picker.

- _`--runID`_ (`string`, default: empty)

  Opaque identifier included as `runID` on every subsequently emitted event.
  The field is omitted when the value is empty.

- _`--trnexePath`_ (`string`, default:
  `C:\TRNSYS18\Exe\TrnEXE64.exe`)

  Path to the executable launched for the simulation.

- _`--guiVisibility`_ (`string`, default: `hidden`)

  Controls the TRNSYS window. Values are:

  - `keep` / `keepOpen`: visible and left open after the simulation.
  - `auto` / `autoClose`: visible and closed after the simulation.
  - `min` / `minimized`: minimized and left open afterward.
  - `minAuto` / `minimizedAuto`: minimized and closed afterward.
  - `hidden`: hidden and closed after the simulation.

### Launch detection

Launch detection runs while holding the session-wide TRNSYS launch mutex.
Enabled checks execute in this order: GUI, `.lst`, then `.tmp`.

- _`--waitForGui`_ (`boolean`, default: `true`)

  Wait for a top-level window owned by `TrnEXE` with a recognized TRNSYS window
  class.

- _`--waitForLst`_ (`boolean`, default: `true`)

  Wait for the component-order header in the deck's `.lst` file.

- _`--waitForTmp`_ (`boolean`, default: `false`)

  Wait for the deck's `.tmp` file to exist.

- _`--detectTimeout`_ (`integer`, default: `300000`)

  Shared readiness deadline in milliseconds. `0` means unlimited. A timeout
  stops readiness detection. With `--killOnTimeout:true`, the process is killed
  and the run reports `TIMEOUT`; otherwise the runner enters runtime monitoring.

- _`--extraDelay`_ (`integer`, default: `0`)

  Delay in milliseconds after readiness succeeds. It is outside the detection
  deadline but still holds the launch mutex.

### Runtime monitoring

- _`--pollMs`_ (`integer`, default: `100`)

  Polling interval in milliseconds for process state and watched sidecars.

- _`--watchLog`_ (`boolean`, default: `true`)

  Stream parsed TRNSYS `.log` entries as `LOG` events.

- _`--watchTmp`_ (`boolean`, default: `false`)

  Read Type3830 `.tmp` snapshots and emit `CONFIG` and `PROGRESS` events.

- _`--watchTimeout`_ (`integer`, default: `0`)

  Maximum runtime-monitoring duration in milliseconds. `0` means unlimited.
  This clock starts when monitoring begins; mutex waiting and launch detection
  do not count toward it.

- _`--stallTimeout`_ (`integer`, default: `0`)

  Maximum milliseconds without forward simulation-time progress. `0` disables
  stall detection. Requires `--watchTmp:true` and a valid Type3830 snapshot.

- _`--killOnTimeout`_ (`boolean`, default: `false`)

  Kill the TRNSYS process after a detection or monitoring timeout. When
  false, a runtime `TIMEOUT` event is emitted before the runner waits for natural
  process exit.

- _`--killOnStall`_ (`boolean`, default: `false`)

  Kill the TRNSYS process after detecting a stall. When false, a `STALLED`
  event is emitted before the runner waits for natural process exit.

After a runtime timeout or stall, monitoring stops permanently. If killing is
disabled, later `tmp` updates, `log` entries, child exit state, and fatal messages
written during the natural-exit wait are not examined and cannot change the
reported outcome.

### Logging and cleanup

- _`--severity`_ (`string`, default: `Notice`)

  Minimum emitted `LOG` severity: `Notice`, `Warning`, or `Fatal`.

- _`--writeEvents`_ (`boolean`, default: `false`)

  Mirror stdout events to a file beside the deck, replacing its extension with
  `.jsonl`. For example, `model.dck` writes `model.jsonl`. The file is truncated
  when the run starts.

- _`--clean`_ (`boolean`, default: `false`)

  Delete `.tmp`, `.log`, `.lst`, and `.PTI` sidecars after a successful run.
  Stale copies are always removed before launch, regardless of this option.

### Full example

A run with every option set explicitly:

```powershell
trnrun --deckFile:"C:\path\to\deck.dck" `
    --runID:batch-42 `
    --trnexePath:"C:\TRNSYS18\Exe\TrnEXE64.exe" `
    --guiVisibility:hidden `
    --waitForGui:true `
    --waitForLst:true `
    --waitForTmp:true `
    --detectTimeout:300000 `
    --extraDelay:0 `
    --pollMs:100 `
    --watchLog:true `
    --watchTmp:true `
    --watchTimeout:300000 `
    --stallTimeout:300000 `
    --killOnTimeout:true `
    --killOnStall:true `
    --severity:Notice `
    --writeEvents:false `
    --clean:true
```

## Output protocol

Events are written to stdout as one JSON object per line
([JSON Lines](https://jsonlines.org/)). Stdout is flushed after every event so a
parent process can react immediately. Treat stdout as the machine-readable
protocol; human-facing writer diagnostics may be sent to stderr.

For a successfully validated run, the lifecycle is:

```text
SETTING → PENDING → LAUNCHING → RUNNING → terminal STATUS
```

`CONFIG`, `PROGRESS`, and `LOG` events can appear after `RUNNING`. Validation or
file-selection failures emit only a terminal `STATUS` event. Exactly one of
`DONE`, `CANCELLED`, `ERROR`, `TIMEOUT`, or `STALLED` terminates the event
stream.

### Common fields

Every event contains `kind`, `timestamp`, and `seq`. Events also contain `runID`
when the caller supplies one.

- _`kind`_ (`string`)

  Event discriminator. Use it to select the remaining payload schema:
  `SETTING`, `STATUS`, `CONFIG`, `PROGRESS`, or `LOG`.

- _`timestamp`_ (`string`)

  Local wall-clock time when the event was created, formatted as
  `yyyy-MM-ddTHH:mm:ss`. The value has second precision.

- _`seq`_ (`integer`)

  Per-run sequence number added by the event sink. It starts at `1` and
  increments once for every emitted event, allowing consumers to preserve order
  and detect missing lines.

- _`runID`_ (`string`, optional)

  Opaque caller-provided identifier used to correlate events with an external
  request. It is included only when a non-empty `--runID` was supplied.

### `SETTING` events

Reports the effective settings used by the runner after normalization.

- _`trnexePath`_ (`string`)

  Resolved absolute path to the executable launched for the simulation.

- _`guiVisibility`_ (`string`)

  Canonical mode: `keepOpen`, `autoClose`, `minimized`, `minimizedAuto`, or
  `hidden`.

- _`waitForGui`_ (`boolean`)

  Whether launch detection waits for a recognized TRNSYS window.

- _`waitForLst`_ (`boolean`)

  Whether launch detection waits for the `.lst` component header.

- _`waitForTmp`_ (`boolean`)

  Whether launch detection waits for the Type3830 `.tmp` file to exist.

- _`detectTimeoutMs`_ (`integer`)

  Normalized shared launch-detection deadline in milliseconds. `0` is unlimited.

- _`extraDelayMs`_ (`integer`)

  Normalized delay after readiness checks in milliseconds.

- _`watchLog`_ (`boolean`)

  Whether parsed log entries are emitted as `LOG` events.

- _`watchTmp`_ (`boolean`)

  Whether Type3830 snapshots are monitored for configuration and progress.

- _`watchTimeoutMs`_ (`integer`)

  Normalized runtime-monitoring deadline in milliseconds. `0` is unlimited.

- _`stallTimeoutMs`_ (`integer`)

  Normalized no-progress deadline in milliseconds. `0` disables stall
  detection.

- _`pollMs`_ (`integer`)

  Effective process and sidecar polling interval in milliseconds.

- _`cleanOnSuccess`_ (`boolean`)

  Whether sidecars are deleted after a `DONE` outcome.

- _`killOnTimeout`_ (`boolean`)

  Whether the owned process is killed after a timeout.

- _`killOnStall`_ (`boolean`)

  Whether the owned process is killed after a stall.

- _`severity`_ (`string`)

  Minimum emitted log severity: `Notice`, `Warning`, or `Fatal`.

- _`writeEvents`_ (`boolean`)

  Whether JSONL mirroring is active. This becomes `false` if the event file
  could not be opened.

### `STATUS` events

Reports a lifecycle transition or terminal outcome.

- _`status`_ (`string`)

  One of `PENDING`, `LAUNCHING`, `RUNNING`, `DONE`, `CANCELLED`, `ERROR`,
  `TIMEOUT`, or `STALLED`.

| Status      | Meaning                                                                                                                    |
| ----------- | -------------------------------------------------------------------------------------------------------------------------- |
| `PENDING`   | Waiting to acquire the launch mutex.                                                                                       |
| `LAUNCHING` | Launch mutex acquired; stale cleanup, process creation, readiness, extra delay, and optional minimization are in progress. |
| `RUNNING`   | Runtime monitoring has started. The child may already have exited if it finished during readiness detection.               |
| `DONE`      | Process exited without a detected fatal condition or incomplete valid TMP snapshot.                                        |
| `CANCELLED` | File selection was cancelled, or the process exited with a valid TMP snapshot below 100%.                                  |
| `ERROR`     | Usage, validation, launch, mutex, Job Object, readiness, monitoring, or fatal-log failure.                                 |
| `TIMEOUT`   | Readiness detection timed out with `killOnTimeout` enabled, or runtime monitoring timed out.                               |
| `STALLED`   | Simulation time failed to advance for longer than `stallTimeout`.                                                          |

> [!IMPORTANT]
> `CANCELLED` and `STALLED` require `--watchTmp:true` and at least one valid
> Type3830 snapshot. Without a valid snapshot, a non-fatal early process exit is
> reported as `DONE`; in that configuration, `DONE` means no failure was
> detected, not that 100% completion was independently verified.

- _`message`_ (`string`)

  Additional error, cancellation, timeout, or cleanup detail. The field is
  always present and is `""` when no detail is needed.

### `CONFIG` events

Reports fixed Type3830 simulation-time settings. It is emitted once when the
first valid `.tmp` snapshot is parsed and requires `--watchTmp:true`.

- _`start`_ (`number`, simulation hours)

  Configured simulation start time.

- _`stop`_ (`number`, simulation hours)

  Configured simulation stop time.

- _`step`_ (`number`, simulation hours)

  Configured simulation time step.

### `PROGRESS` events

Reports Type3830 progress. The first valid snapshot emits a progress event after
`CONFIG`; later events are emitted only when simulation time changes.

- _`time`_ (`number`, simulation hours)

  Current simulation time, rounded to two decimals.

- _`percent`_ (`number`, fraction)

  Completion from `0` to `1`, rounded to four decimals.

- _`elapsed`_ (`number`, milliseconds)

  Wall-clock time since TrnEXE launch, rounded to two decimals.

- _`eta`_ (`number`, milliseconds)

  Estimated remaining wall-clock time, rounded to two decimals.

### `LOG` events

Reports one parsed TRNSYS log entry when `--watchLog:true` and the entry meets
the configured severity threshold.

- _`severity`_ (`string`)

  Log severity: `Notice`, `Warning`, or `Fatal`.

- _`time`_ (`number`, simulation hours)

  Simulation time associated with the entry, rounded to two decimals.

- _`unitID`_ (`integer`, optional)

  TRNSYS unit that emitted the entry.

- _`typeID`_ (`integer`, optional)

  TRNSYS component type associated with the entry.

- _`messageCode`_ (`integer`, optional)

  Numeric TRNSYS message identifier.

- _`message`_ (`string`, optional)

  Human-readable message text.

- _`information`_ (`string`, optional)

  Additional information attached to the message.

Optional fields are omitted when unavailable; they are not emitted as `null`.

### Example stream

```json
{"kind":"SETTING","timestamp":"2026-06-19T19:37:13","trnexePath":"C:\\TRNSYS18\\Exe\\TrnEXE64.exe","guiVisibility":"hidden","waitForGui":true,"waitForLst":true,"waitForTmp":false,"detectTimeoutMs":300000,"extraDelayMs":0,"watchLog":true,"watchTmp":true,"watchTimeoutMs":0,"stallTimeoutMs":0,"pollMs":100,"cleanOnSuccess":false,"killOnTimeout":false,"killOnStall":false,"severity":"Notice","writeEvents":false,"seq":1}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:13","status":"PENDING","message":"","seq":2}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:14","status":"LAUNCHING","message":"","seq":3}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:15","status":"RUNNING","message":"","seq":4}
{"kind":"CONFIG","timestamp":"2026-06-19T19:37:15","start":0.0,"stop":8760.0,"step":0.25,"seq":5}
{"kind":"PROGRESS","timestamp":"2026-06-19T19:37:15","time":24.0,"percent":0.0027,"elapsed":287.0,"eta":104468.0,"seq":6}
{"kind":"LOG","timestamp":"2026-06-19T19:37:15","severity":"Warning","time":24.0,"unitID":5,"typeID":139,"messageCode":101,"message":"Example warning","information":"Example details","seq":7}
{"kind":"STATUS","timestamp":"2026-06-19T19:37:16","status":"DONE","message":"","seq":8}
```

## Exit codes

| Exit code | Status      | Meaning                                                                                                      |
| --------- | ----------- | ------------------------------------------------------------------------------------------------------------ |
| `0`       | `DONE`      | Simulation completed without a detected failure. Help and version also return `0` without emitting an event. |
| `1`       | `ERROR`     | Lifecycle failure caught during launch, monitoring, mutex, Job Object, or fatal-log handling.                |
| `2`       | `ERROR`     | Usage, input validation, or unexpected top-level CLI failure.                                                |
| `124`     | `TIMEOUT`   | Runtime timeout, or readiness timeout with `killOnTimeout=true`.                                             |
| `125`     | `STALLED`   | Progress stall exceeded `stallTimeout`.                                                                      |
| `130`     | `CANCELLED` | Incomplete tracked simulation or cancelled file selection.                                                   |

## Examples

PowerShell examples are available in [`examples`](examples). They expect
`build/trnrun.exe` to exist and use the default TRNSYS 18 executable path.

- [`example_single.ps1`](examples/example_single.ps1) runs one deck.
- [`example_sequential.ps1`](examples/example_sequential.ps1) runs decks one at
  a time.
- [`example_concurrent.ps1`](examples/example_concurrent.ps1) launches
  independent runners concurrently.

For bounded concurrent workloads with one merged event stream, use
[TRNRun Queue](../trnrunq/) instead of managing independent runner processes
directly.
