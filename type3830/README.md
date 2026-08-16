# TRNRun Progress Tracker (Type3830)

`Type3830` is a custom TRNSYS component that exposes simulation progress to external applications. It periodically writes the simulation `TIME`, `START`, `STOP`, and `STEP` values to a temporary (`*.tmp`) file that can be monitored while TRNSYS is running.

The component is designed for the [TRNRun](../README.md) runner, but any application that supports the text format described below can use it.

## Requirements

- TRNSYS17 or TRNSYS18

## Installation

1. Download the package for your TRNSYS version:
   - `Type3830-TRNSYS17-v<version>`
   - `Type3830-TRNSYS18-v<version>`
2. Extract the package directly into the corresponding TRNSYS installation directory.
3. Confirm that the following files were installed:

```text
<TRNSYS>/
├── Studio/Proformas/Utility (NRCan)/Progress Tracker/
│   ├── Type3830.bmp
│   └── Type3830.tmf
└── UserLib/
    ├── DebugDLLs/type3830.dll
    └── ReleaseDLLs/type3830.dll
```

Restart TRNSYS Studio after installation to make the **Progress Tracker** proforma available.

## Configuration

### Parameters

| #   | Name              | Description                                                                                                                      |
| --- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Logical unit      | Integer file reference assigned by TRNSYS Studio. It must be `10` or greater, assigned to an open file, and not used elsewhere.  |
| 2   | Printing interval | Simulation-time interval between updates, in hours. It must be greater than `0` and at least as long as the simulation timestep. |

Use a printing interval of one hour or longer when fine-grained updates are unnecessary, as shorter intervals increase file I/O.

### Progress file

The component creates a temporary (`*.tmp`) file containing one comma-separated record with four floating-point values and no header:

```text
TIME, START, STOP, STEP
```

| Position | Variable | Description                      |
| -------- | -------- | -------------------------------- |
| 1        | `TIME`   | Current simulation time          |
| 2        | `START`  | Configured simulation start time |
| 3        | `STOP`   | Configured simulation stop time  |
| 4        | `STEP`   | Configured simulation timestep   |

Each value is written with six digits after the decimal point

Example:

```text
123.000000,0.000000,8760.000000,0.250000
```
