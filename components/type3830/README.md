# TRNRun Progress Tracker

`Type3830` is a custom TRNSYS component that makes simulation progress available
to external applications. It writes the current simulation time and configured
time range to a small `.tmp` file while a deck is running. Its responsibilities
are to:

- publish simulation progress at a configurable interval
- provide the start time, stop time, and timestep needed to calculate completion
- leave a final progress snapshot when the simulation ends

The component is designed for [TRNRun Runner](../trnrun/), which converts these
snapshots into `CONFIG` and `PROGRESS` events and uses them for cancellation and
stall detection. Other applications can read the same text format directly.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Progress file](#progress-file)
- [Examples](#examples)

## Requirements

### Runtime

- Windows
- TRNSYS 17 (32-bit) or TRNSYS 18 (64-bit)

### Development

- [Nim](https://nim-lang.org/install.html) 2.2.10 or newer
- [Zig](https://ziglang.org/download/) as the Windows C compiler
- The TRNSYS import library for each target being built:
  - `C:\Trnsys17\Exe\TRNDll.lib` for TRNSYS 17
  - `C:\TRNSYS18\Exe\TRNDll64.lib` for TRNSYS 18
- [just](https://github.com/casey/just) for repository-root recipes

## Installation

Download the package matching your TRNSYS version from
[GitHub Releases](https://github.com/NRCan/TRNRun/releases):

- `Type3830-TRNSYS17-v<version>.zip`
- `Type3830-TRNSYS18-v<version>.zip`

Extract the package directly into the corresponding TRNSYS installation
directory. The package installs the following files:

```text
<TRNSYS>/
├── Studio/Proformas/Utility (NRCan)/Progress Tracker/
│   ├── Type3830.bmp
│   └── Type3830.tmf
└── UserLib/
    ├── DebugDLLs/type3830.dll
    └── ReleaseDLLs/type3830.dll
```

Restart TRNSYS Studio after installation to make the **Progress Tracker**
proforma available.

To build both TRNSYS packages from source, run the following from the repository
root:

```powershell
Set-Location components/type3830
nimble dist
```

The packages are written to `components/type3830/dist`. Building both requires
TRNSYS 17 and 18 at the default paths listed above.

## Quick start

1. Add **Utility (NRCan) > Progress Tracker** to the deck in TRNSYS Studio.
2. Set the printing interval in simulation hours. The default is `1` hour.
3. Run the deck with Type3830 monitoring enabled:

```powershell
trnrun "C:\path\to\deck.dck" --watchTmp:true
```

## Configuration

Type3830 has two parameters and no inputs or outputs.

- _`Logical unit`_ (`integer`, automatically assigned)

  TRNSYS file reference used by the `.tmp` output.

- _`Printing interval`_ (`number`, default: `1` hour)

  Simulation-time interval between progress updates. It must be greater than `0`.

Use a printing interval of one hour or longer when fine-grained progress is not
needed. Shorter intervals increase file I/O without changing the simulation
calculation.

## Progress file

Type3830 creates a `.tmp` file beside the deck with the same base name. The file
contains the latest progress snapshot as one comma-separated record with no
header:

```text
TIME,START,STOP,STEP
```

- _`TIME`_ (`number`, simulation hours)

  Current simulation time.

- _`START`_ (`number`, simulation hours)

  Configured simulation start time.

- _`STOP`_ (`number`, simulation hours)

  Configured simulation stop time.

- _`STEP`_ (`number`, simulation hours)

  Configured simulation timestep.

Each value is written with six digits after the decimal point:

```text
123.000000,0.000000,8760.000000,0.250000
```

## Examples

Example decks are available in [`examples`](examples). They expect Type3830 to
be installed for the corresponding TRNSYS version.

- [`type3830-trnsys17.dck`](examples/type3830-trnsys17.dck) demonstrates the
  TRNSYS 17 component.
- [`type3830-trnsys18.dck`](examples/type3830-trnsys18.dck) demonstrates the
  TRNSYS 18 component.
