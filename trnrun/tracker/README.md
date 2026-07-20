# TRNRun - Progress Tracker (Type3830)

Custom TRNSYS component that exports simulation TIME, START, STOP, and STEP to a temporary file `***.tmp` for external monitoring.

## Purpose

`Type3830` provides a lightweight interface between TRNSYS simulations and external applications by periodically writing simulation progress information to a temporary file.

The generated file can be monitored by external tools such as the TRNRun simulation runner `trnrun.exe` to track simulation status and progress in real time.

## Requirement

- TRNSYS v17 or TRNSYS v18

## Installation

Download the appropriate release from the Releases page and extract it into your TRNSYS installation directory (e.g., `C:\TRNSYS18`).

## Configuration

### Parameters

| Name           | Description                                                                                                                                              | Options                |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| Logical Unit   | Logical unit number used for file output. Automatically assigned by TRNSYS.                                                                              | -                      |
| Print Interval | Time interval between successive writes to the output file. Must be ≥ simulation timestep. Recommended value: 1 hour or larger to reduce I/O operations. | Positive float (hours) |

### Output

Creates a temporary file (`*.tmp`) containing the current simulation progress.

The file contains a single line with the following values:

| Variable | Description              |
| -------- | ------------------------ |
| TIME     | Current simulation time  |
| START    | Simulation start time    |
| STOP     | Simulation stop time     |
| STEP     | Simulation timestep size |

Example:

```
123.00000, 0.00000, 8760.000000, 0.250000
```
