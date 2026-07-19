# TRNRun: A TRNSYS Simulation Launcher

TRNRun is a comprehensive Python utility to safely and conveniently launch, monitor, and manage TRNSYS simulations using `TRNEXE.exe`. It provides window management, concurrency control, real-time progress tracking, log parsing, and live display updates for multiple simulations running simultaneously.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
  - [trnexe()](#trnexe)
  - [Simulation](#simulation)
  - [SimulationManager](#simulationmanager)
  - [Data Structures](#data-structures)
- [Examples](#examples)
- [Progress Tracking](#progress-tracking)
- [Log Parsing](#log-parsing)
- [Display System](#display-system)
- [Error Handling](#error-handling)
- [Thread Safety](#thread-safety)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)
- [Requirements](#requirements)
- [License](#license)

## Features

### Core Functionality

- **Simple Launcher**: High-level function (`trnexe()`) to launch TRNSYS simulations with comprehensive window control
- **Simulation Management**: Object-oriented interface (`Simulation`) for individual simulations with automatic progress tracking and log parsing
- **Concurrent Execution**: Manage multiple simulations concurrently (`SimulationManager`) with controlled parallelism and thread-safe operations
- **Progress Tracking**: Real-time progress monitoring from Type3830 temporary files (`.tmp` files)
- **Log Parsing**: Automatic parsing of TRNSYS log files (`.log` files) with message categorization (Notice, Warning, Fatal)
- **Live Display**: Rich terminal display showing progress for multiple simulations simultaneously with ASCII progress bars

### Advanced Features

- **Window Management**: Control TRNSYS GUI window behavior (hide, flash, or wait for user)
- **Window Detection**: Automatic detection of TRNSYS windows to prevent concurrent launch conflicts
- **Global Locking**: Optional global lock to serialize TRNEXE launches and prevent resource conflicts
- **Status Tracking**: Comprehensive status system (Pending, Running, Done, Failed, Cancelled)
- **Time Estimation**: Automatic calculation of elapsed time and estimated remaining time
- **Context Managers**: Automatic cleanup and resource management via context manager support
- **Thread Safety**: Thread-safe operations for concurrent simulation management

## Installation

### Prerequisites

- Python >= 3.11
- Windows operating system (uses `pywin32` for window management)
- TRNSYS installed with TRNEXE executable accessible

### Install from PyPI

```sh
pip install trnrun
```

### Install from Source

```sh
git clone <repository-url>
cd TRNRun_cursor
pip install -e .
```

### Dependencies

The package requires:

- `pywin32>=311` - For Windows API access (window management)
- `rich>=14.2.0` - For terminal display and formatting

Optional development dependencies:

- `pytest>=9.0.1` - For running tests
- `ipykernel>=7.1.0` - For Jupyter notebook support

## Quick Start

### Basic Usage with trnexe()

```python
from trnrun import trnexe
from pathlib import Path

# Launch simulation asynchronously
process = trnexe("path/to/your/deck.dck")

# Launch and wait until simulation finishes
process = trnexe("path/to/your/deck.dck", wait_finish=True)
print(f"Simulation finished with return code: {process.returncode}")
```

### Using the Simulation Class

```python
from trnrun import Simulation

# Create and run a simulation
sim = Simulation("path/to/your/deck.dck")
sim.run()

# Monitor progress
while sim.is_alive():
    sim.update()
    print(f"Progress: {sim.progress.percent * 100:.1f}%")
    print(f"Status: {sim.status}")
    print(f"Warnings: {sim.warnings}, Fatals: {sim.fatals}")

# Check final status
print(f"Final status: {sim.status}")
```

### Using SimulationManager for Concurrent Simulations

```python
from trnrun import SimulationManager
from pathlib import Path

# Manage multiple simulations concurrently
with SimulationManager(max_concurrent=5) as manager:
    # Add simulations
    sim1 = manager.add("deck1.dck")
    sim2 = manager.add("deck2.dck")
    sim3 = manager.add("deck3.dck")

    # Wait for all to complete
    manager.wait()

    # Check results
    for sim in manager.finished():
        print(f"{sim.dck_path}: {sim.status}")
```

## API Reference

### trnexe()

High-level function to launch TRNSYS simulations with comprehensive control options.

#### Signature

```python
trnexe(
    deck_file: str | Path,
    *,
    trnexe_path: str | Path = "C:/TRNSYS18/Exe/TrnEXE64.exe",
    window_mode: Literal["hide", "flash", "wait"] = "flash",
    window_detection: bool = True,
    window_timeout: float = 120.0,
    delay: float = 0.01,
    use_lock: bool = True,
    wait_finish: bool = False,
) -> Popen
```

#### Parameters

| Parameter          | Type                          | Default                          | Description                                                                                                                                                                                                                                                       |
| ------------------ | ----------------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deck_file`        | `str` or `Path`               | **Required**                     | Path to the TRNSYS `.dck` deck file. Must exist and be readable.                                                                                                                                                                                                  |
| `trnexe_path`      | `str` or `Path`               | `"C:/TRNSYS18/Exe/TrnEXE64.exe"` | Path to the TRNEXE executable. Must exist and be executable.                                                                                                                                                                                                      |
| `window_mode`      | `"hide"`, `"flash"`, `"wait"` | `"flash"`                        | Controls how the TRNSYS GUI window behaves:<br>- `"hide"`: Hide the window completely (`/h` flag)<br>- `"flash"`: Automatically close after execution (`/n` flag)<br>- `"wait"`: Keep window open and wait for user to close (no flag)                            |
| `window_detection` | `bool`                        | `True`                           | Enable detection of the TRNSYS window after launch. This helps prevent multiple concurrent launches of TRNEXE by detecting when the window appears. If `False`, window detection is skipped entirely.                                                             |
| `window_timeout`   | `float`                       | `120.0`                          | Maximum time (seconds) to wait for the TRNSYS window to appear when `window_detection=True`. Must be positive. If the window doesn't appear within this time, the function continues without error.                                                               |
| `delay`            | `float`                       | `0.01`                           | Optional delay (seconds) after launching TRNSYS and detecting the window. This helps reduce race conditions and ensures the process is fully initialized.                                                                                                         |
| `use_lock`         | `bool`                        | `True`                           | Use a global lock to prevent multiple concurrent launches of TRNEXE initialization. This is recommended when running many simulations to avoid conflicts with TRNSYS shared resources. The lock is acquired before launching and released after window detection. |
| `wait_finish`      | `bool`                        | `False`                          | If `True`, block until the TRNSYS process finishes before returning. If `False`, return immediately after launching.                                                                                                                                              |

#### Returns

- **`subprocess.Popen`**: The TRNSYS process object. You can use this to:
  - Check if the process is running: `process.poll() is None`
  - Get the process ID: `process.pid`
  - Wait for completion: `process.wait()`
  - Get the return code: `process.returncode` (after completion)

#### Raises

- **`FileNotFoundError`**: If the deck file or TRNEXE executable does not exist
- **`RuntimeError`**: If the TRNSYS process cannot be started (e.g., permission issues)
- **`ValueError`**: If `window_mode` is not one of the allowed values, or if `window_timeout` is non-positive

#### Example

```python
from trnrun import trnexe
from pathlib import Path

# Launch with custom settings
process = trnexe(
    "simulation.dck",
    trnexe_path="C:/TRNSYS18/Exe/TrnEXE64.exe",
    window_mode="hide",  # Hide window completely
    window_detection=True,
    window_timeout=60.0,
    use_lock=True,
    wait_finish=False  # Non-blocking
)

# Poll for completion
while process.poll() is None:
    print("Simulation running...")
    time.sleep(1)

print(f"Simulation finished with return code: {process.returncode}")
```

### Simulation

Manages a TRNSYS simulation lifecycle including launching, monitoring, and status tracking. Provides automatic progress tracking, log parsing, and comprehensive status management.

#### Constructor

```python
Simulation(dck_path: str | Path)
```

#### Parameters

- **`dck_path`** (`str` or `Path`): Path to the TRNSYS deck file (`.dck`). Must exist.

#### Initialization Behavior

Upon creation, the `Simulation` object:

1. Validates that the deck file exists (raises `FileNotFoundError` if not)
2. Resolves the path to an absolute path
3. Attempts to clean up any existing `.tmp` and `.log` files from previous runs (warns if deletion fails but continues)

#### Methods

##### `run(**kwargs) -> Self`

Launch the TRNSYS simulation process. Returns `self` for method chaining.

**Parameters** (all optional, same as `trnexe()`):

- `trnexe_path`: Path to TRNEXE executable (default: `"C:/TRNSYS18/Exe/TrnEXE64.exe"`)
- `window_mode`: Window behavior mode (default: `"flash"`)
- `window_detection`: Enable window detection (default: `True`)
- `window_timeout`: Window detection timeout in seconds (default: `120.0`)
- `delay`: Delay after launch in seconds (default: `0.01`)
- `use_lock`: Use global lock (default: `True`)
- `wait_finish`: Block until completion (default: `False`)

**Behavior**:

- If simulation is already running, prints a warning and returns without launching again
- Sets status to `RUNNING`
- Records start time for elapsed time calculation
- Launches the process using `trnexe()`

**Returns**: `Self` (for method chaining)

##### `update() -> SimulationStatus`

Update simulation progress, logs, and status. This method should be called periodically to refresh the simulation state.

**Behavior**:

1. Reads progress from the `.tmp` file (if Type3830 is used)
2. Parses log messages from the `.log` file
3. Updates the status based on:
   - Process state (running or finished)
   - Return code (non-zero indicates failure)
   - Presence of fatal messages in the log
   - Progress completion (partial progress indicates cancellation)

**Returns**: Current `SimulationStatus`

##### `wait(timeout: float | None = None) -> int | None`

Wait for the simulation process to finish.

**Parameters**:

- `timeout` (`float | None`): Maximum time to wait in seconds. If `None`, waits indefinitely.

**Returns**:

- Process return code if process exists and completes
- `None` if no process is associated

**Raises**: `TimeoutError` if timeout is exceeded

##### `is_alive() -> bool`

Check if the simulation process is still running.

**Returns**: `True` if process exists and is still running, `False` otherwise

##### `terminate() -> None`

Terminate the simulation process gracefully by sending a termination signal. Sets status to `CANCELLED`.

**Note**: This sends a SIGTERM-equivalent signal. The process may handle this and exit cleanly.

##### `kill() -> None`

Forcefully terminate the simulation process. Sets status to `CANCELLED`.

**Note**: This forcefully kills the process. Use `terminate()` first for graceful shutdown.

#### Properties

##### `status: SimulationStatus`

Current simulation status. One of:

- `SimulationStatus.PENDING`: Simulation created but not started
- `SimulationStatus.RUNNING`: Simulation is currently running
- `SimulationStatus.DONE`: Simulation completed successfully
- `SimulationStatus.FAILED`: Simulation failed (non-zero return code or fatal messages)
- `SimulationStatus.CANCELLED`: Simulation was cancelled or terminated

##### `progress: SimulationProgress | None`

Current simulation progress information. `None` if progress file doesn't exist or hasn't been read yet.

The `SimulationProgress` object contains:

- `time`: Current simulation time
- `start`: Simulation start time
- `stop`: Simulation stop time
- `step`: Simulation time step
- `percent`: Progress as a fraction (0.0 to 1.0), calculated as `(time - start) / (stop - start)`

**Note**: Progress tracking requires Type3830 to be configured in your TRNSYS deck file to write progress to a `.tmp` file.

##### `log: list[TrnsysLogMessage]`

List of parsed log messages from the TRNSYS `.log` file. Empty list if log file doesn't exist or hasn't been parsed yet.

Messages are sorted by severity (Notice < Warning < Fatal) and then by simulation time.

##### `elapsed_time: float | None`

Elapsed time in seconds since the simulation started. `None` if simulation hasn't been started yet.

##### `remaining_time: float | None`

Estimated remaining time in seconds based on current progress. Calculated as:

```
remaining_time = elapsed_time * (1.0 / progress.percent - 1.0)
```

Returns `None` if:

- Simulation hasn't started
- Progress is not available
- Progress percent is 0 or negative

##### `notices: int`

Number of notice-level messages in the log. Automatically triggers log parsing if not already done.

##### `warnings: int`

Number of warning-level messages in the log. Automatically triggers log parsing if not already done.

##### `fatals: int`

Number of fatal-level messages in the log. Automatically triggers log parsing if not already done.

#### Context Manager

The `Simulation` class supports context manager protocol for automatic cleanup:

```python
with Simulation("deck.dck") as sim:
    sim.run()
    # If an exception occurs, simulation will be terminated
    # After context exits, if still running, it will be terminated
```

**Behavior on exit**:

1. If process is running, calls `terminate()`
2. Waits up to 5 seconds for graceful shutdown
3. If still running after timeout, calls `kill()`

#### Example

```python
from trnrun import Simulation
import time

# Create simulation
sim = Simulation("my_simulation.dck")

# Launch
sim.run(window_mode="hide", wait_finish=False)

# Monitor progress
while sim.is_alive():
    sim.update()

    print(f"Status: {sim.status}")
    if sim.progress:
        print(f"Progress: {sim.progress.percent * 100:.1f}%")
        print(f"Time: {sim.progress.time:.1f} / {sim.progress.stop:.1f}")
    print(f"Elapsed: {sim.elapsed_time:.1f}s")
    if sim.remaining_time:
        print(f"ETA: {sim.remaining_time:.1f}s")
    print(f"Logs: {sim.notices} notices, {sim.warnings} warnings, {sim.fatals} fatals")

    time.sleep(2)

# Final update
sim.update()
print(f"Final status: {sim.status}")
if sim.fatals > 0:
    print("Simulation had fatal errors!")
    for msg in sim.log:
        if msg.level == "Fatal":
            print(f"  {msg}")
```

### SimulationManager

Manage multiple TRNSYS simulations concurrently with thread-safe control and live progress display. Uses a thread pool to limit concurrency and provides automatic display updates.

#### Constructor

```python
SimulationManager(
    *,
    trnexe_path: str | Path = "C:/TRNSYS18/Exe/TrnEXE64.exe",
    window_mode: Literal["hide", "flash", "wait"] = "hide",
    window_detection: bool = True,
    window_timeout: float = 120.0,
    delay: float = 0.01,
    update_interval: float = 0.1,
    max_concurrent: int = None,
)
```

#### Parameters

| Parameter          | Type                          | Default                          | Description                                                                                                                                  |
| ------------------ | ----------------------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `trnexe_path`      | `str` or `Path`               | `"C:/TRNSYS18/Exe/TrnEXE64.exe"` | Path to the TRNEXE executable. Applied to all simulations added to this manager.                                                             |
| `window_mode`      | `"hide"`, `"flash"`, `"wait"` | `"hide"`                         | Window display mode for all simulations. Default is `"hide"` for cleaner concurrent execution.                                               |
| `window_detection` | `bool`                        | `True`                           | Enable window detection for all simulations.                                                                                                 |
| `window_timeout`   | `float`                       | `120.0`                          | Maximum time (seconds) to wait for window detection.                                                                                         |
| `delay`            | `float`                       | `0.01`                           | Delay after launching each simulation.                                                                                                       |
| `update_interval`  | `float`                       | `0.1`                            | Interval (seconds) between display updates while simulations run. Lower values provide smoother updates but use more CPU.                    |
| `max_concurrent`   | `int`                         | `os.cpu_count() - 1`             | Maximum number of simulations to run concurrently. Defaults to number of CPU cores minus one. Set to `None` for unlimited (not recommended). |

#### Methods

##### `add(dck_path: str | Path) -> Simulation`

Create and immediately submit a Simulation for concurrent execution. The simulation is launched in a background thread, respecting the `max_concurrent` limit.

**Parameters**:

- `dck_path`: Path to the TRNSYS DCK file

**Returns**: The `Simulation` instance being managed. You can use this to:

- Access simulation properties (status, progress, log, etc.)
- Manually terminate: `sim.terminate()` or `sim.kill()`
- Check if it's in `active()` or `finished()` lists

**Thread Safety**: This method is thread-safe and can be called from multiple threads.

##### `wait(timeout: float | None = None) -> None`

Block until all simulations complete or timeout expires.

**Parameters**:

- `timeout` (`float | None`): Maximum time to wait in seconds. If `None`, waits indefinitely.

**Behavior**: Waits for all submitted simulations to complete. Does not return until all are done or timeout occurs.

##### `active() -> list[Simulation]`

Return list of simulations that are still running.

**Returns**: List of `Simulation` objects with status `RUNNING` or `PENDING`

**Thread Safety**: This method is thread-safe.

##### `finished() -> list[Simulation]`

Return list of simulations that have completed (status is `DONE`, `FAILED`, or `CANCELLED`).

**Returns**: List of `Simulation` objects that have finished

**Thread Safety**: This method is thread-safe.

##### `shutdown(wait: bool = True, cancel_pending: bool = False) -> None`

Shutdown the manager and cleanup resources.

**Parameters**:

- `wait` (`bool`): If `True`, wait for all running simulations to complete before shutting down the thread pool. If `False`, shutdown immediately.
- `cancel_pending` (`bool`): If `True`, terminate all running simulations before shutting down.

**Behavior**:

- Shuts down the thread pool executor
- If `cancel_pending=True`, calls `terminate()` on all running simulations
- Cancels pending futures that haven't started yet

**Note**: After calling `shutdown()`, you cannot add more simulations. Create a new `SimulationManager` if needed.

##### `clear() -> int`

Remove all completed simulations from tracking. This helps free memory when managing many simulations.

**Returns**: Number of simulations removed

**Thread Safety**: This method is thread-safe.

#### Context Manager

The `SimulationManager` supports context manager protocol for automatic cleanup and display management:

```python
with SimulationManager(max_concurrent=5) as manager:
    # Add simulations
    sim1 = manager.add("deck1.dck")
    sim2 = manager.add("deck2.dck")

    # Wait for completion
    manager.wait()

    # Display automatically updates and cleans up on exit
```

**Behavior on entry**:

- Starts the live display system
- Initializes the refresh thread

**Behavior on exit**:

- If an exception occurred, cancels all pending simulations
- Shuts down the thread pool
- Stops the display refresh thread
- Finalizes the live display

#### Display

The `SimulationManager` automatically displays progress for all simulations in a live-updating terminal display. Each simulation is shown on a separate line with:

- Simulation ID (`[1]`, `[2]`, etc.)
- Deck file path (truncated if too long)
- Status (Pending, Running, Done, Failed, Cancelled)
- Log counts (N: notices, W: warnings, F: fatals)
- Elapsed time (HH:MM:SS format)
- Estimated time remaining (ETA, HH:MM:SS format)
- ASCII progress bar (20 characters wide)
- Simulation time progress (current / total)
- Progress percentage

The display updates automatically at the `update_interval` rate.

#### Example

```python
from trnrun import SimulationManager, SimulationStatus
from pathlib import Path

# Create manager with custom settings
with SimulationManager(
    trnexe_path="C:/TRNSYS18/Exe/TrnEXE64.exe",
    window_mode="hide",
    max_concurrent=4,
    update_interval=0.5
) as manager:
    # Add multiple simulations
    dck_files = [f"sim_{i}.dck" for i in range(10)]
    simulations = [manager.add(dck) for dck in dck_files]

    print(f"Launched {len(simulations)} simulations")

    # Wait for all to complete
    manager.wait()

    # Check results
    finished = manager.finished()
    successful = [s for s in finished if s.status == SimulationStatus.DONE]
    failed = [s for s in finished if s.status == SimulationStatus.FAILED]

    print(f"\nResults:")
    print(f"  Successful: {len(successful)}")
    print(f"  Failed: {len(failed)}")

    # Check for warnings/fatals
    for sim in failed:
        if sim.fatals > 0:
            print(f"\n{sim.dck_path} had {sim.fatals} fatal errors:")
            for msg in sim.log:
                if msg.level == "Fatal":
                    print(f"  {msg.message}")
```

### Data Structures

#### SimulationStatus

Enumeration of possible simulation states.

```python
class SimulationStatus(StrEnum):
    PENDING = "Pending"      # Created but not started
    RUNNING = "Running"       # Currently executing
    DONE = "Done"            # Completed successfully
    FAILED = "Failed"        # Failed (non-zero return code or fatal messages)
    CANCELLED = "Cancelled"  # Terminated or cancelled
```

#### SimulationProgress

Tracks the progress of a simulation over time. Read from Type3830 temporary files.

```python
@dataclass
class SimulationProgress:
    time: float   # Current simulation time
    start: float  # Simulation start time
    stop: float   # Simulation stop time
    step: float   # Simulation time step

    @property
    def percent(self) -> float:
        """Progress as a fraction (0.0 to 1.0)"""
        # Calculated as: (time - start) / (stop - start)
        # Clipped to [0.0, 1.0]
```

**Note**: If the progress file doesn't exist or is invalid, `read_progress()` returns a default `SimulationProgress` with all values set to `-1.0` and `percent` of `0.0`.

#### TrnsysLogMessage

Represents a single message from a TRNSYS log file.

```python
@dataclass
class TrnsysLogMessage:
    level: str        # "Notice", "Warning", or "Fatal"
    time: float       # Simulation time when message was generated
    unit: str         # Unit number that generated the message (empty if not applicable)
    type_number: str  # Type number that generated the message (empty if not applicable)
    message: str      # Main message content
    information: str  # Additional reported information
```

Messages are automatically sorted by severity (Notice < Warning < Fatal) and then by simulation time.

## Examples

### Example 1: Basic trnexe() Usage

```python
from trnrun import trnexe
import time

# Blocking launch
process = trnexe(
    "simulation.dck",
    window_mode="flash",
    wait_finish=True
)
print(f"Finished with return code: {process.returncode}")

# Non-blocking launch
process = trnexe(
    "simulation.dck",
    window_mode="hide",
    wait_finish=False
)

# Poll for completion
while process.poll() is None:
    print("Running...")
    time.sleep(1)
print("Done!")
```

### Example 2: Single Simulation with Monitoring

```python
from trnrun import Simulation
import time

sim = Simulation("my_simulation.dck")
sim.run(window_mode="hide")

# Monitor until completion
while sim.is_alive():
    sim.update()

    if sim.progress:
        print(f"{sim.progress.percent * 100:.1f}% complete")
        print(f"Time: {sim.progress.time:.1f} / {sim.progress.stop:.1f}")

    if sim.warnings > 0:
        print(f"Warning: {sim.warnings} warnings detected")

    time.sleep(2)

# Final check
sim.update()
print(f"Status: {sim.status}")
if sim.status == SimulationStatus.DONE:
    print("Simulation completed successfully!")
```

### Example 3: Multiple Simulations with SimulationManager

```python
from trnrun import SimulationManager, SimulationStatus
from pathlib import Path

dck_folder = Path("simulations")
dck_files = list(dck_folder.glob("*.dck"))

with SimulationManager(max_concurrent=5) as manager:
    # Add all simulations
    simulations = [manager.add(dck) for dck in dck_files]

    print(f"Launched {len(simulations)} simulations")

    # Wait for completion
    manager.wait()

    # Analyze results
    finished = manager.finished()
    done = [s for s in finished if s.status == SimulationStatus.DONE]
    failed = [s for s in finished if s.status == SimulationStatus.FAILED]

    print(f"\nCompleted: {len(done)}")
    print(f"Failed: {len(failed)}")

    # Check for issues
    for sim in failed:
        print(f"\n{sim.dck_path.name}:")
        print(f"  Status: {sim.status}")
        print(f"  Warnings: {sim.warnings}")
        print(f"  Fatals: {sim.fatals}")
```

### Example 4: Error Handling and Recovery

```python
from trnrun import Simulation, SimulationStatus
import time

sim = Simulation("simulation.dck")

try:
    sim.run()

    # Monitor with timeout
    start_time = time.time()
    timeout = 3600  # 1 hour

    while sim.is_alive():
        if time.time() - start_time > timeout:
            print("Timeout reached, terminating...")
            sim.terminate()
            break

        sim.update()

        # Check for fatal errors during execution
        if sim.fatals > 0:
            print("Fatal errors detected, terminating...")
            sim.terminate()
            break

        time.sleep(5)

    # Final update
    sim.update()

    if sim.status == SimulationStatus.FAILED:
        print("Simulation failed:")
        for msg in sim.log:
            if msg.level == "Fatal":
                print(f"  {msg}")

except FileNotFoundError as e:
    print(f"File not found: {e}")
except Exception as e:
    print(f"Error: {e}")
    if sim.is_alive():
        sim.kill()
```

### Example 5: Using Context Managers

```python
from trnrun import Simulation, SimulationManager

# Single simulation with context manager
with Simulation("deck.dck") as sim:
    sim.run()
    # Automatic cleanup on exit or exception

# Multiple simulations with context manager
with SimulationManager(max_concurrent=3) as manager:
    sims = [manager.add(f"sim_{i}.dck") for i in range(10)]
    manager.wait()
    # Automatic cleanup and display shutdown
```

## Progress Tracking

TRNRun can track simulation progress in real-time if your TRNSYS deck file includes Type3830 (Progress Tracker). Type3830 writes progress information to a temporary file (`.tmp`) with the same name as your deck file.

### Progress File Format

The progress file is a CSV-like file with a single line containing four float values:

```
time,start,stop,step
```

For example:

```
1250.5,0.0,8760.0,0.25
```

Where:

- `time`: Current simulation time
- `start`: Simulation start time
- `stop`: Simulation stop time
- `step`: Simulation time step

### Enabling Progress Tracking

To enable progress tracking in your TRNSYS simulation:

1. Add Type3830 to your deck file
2. Configure Type3830 to write to a temporary file with the same name as your deck file but with `.tmp` extension
3. Ensure Type3830 writes progress updates during simulation

### Reading Progress

Progress is automatically read when you call `sim.update()`. The `Simulation` class reads from `{deck_path}.tmp`.

**Note**: If the progress file doesn't exist or is invalid, `progress` will be `None` or contain default values (`-1.0` for all fields, `0.0` for percent).

### Progress Calculation

The progress percentage is calculated as:

```python
percent = (time - start) / (stop - start)
```

This value is automatically clipped to the range `[0.0, 1.0]` to handle edge cases where:

- `time < start` → `percent = 0.0`
- `time > stop` → `percent = 1.0`
- `start == stop` → `percent = 0.0` (avoids division by zero)

## Log Parsing

TRNRun automatically parses TRNSYS log files (`.log`) to extract and categorize messages.

### Log File Format

TRNSYS log files contain messages in the following format:

```
*** Notice at time        :         0.000000
    Generated by Unit     : 1
    Generated by Type     : Type1
    Message               : Simulation started

*** Warning at time       :         125.5
    Generated by Unit     : 5
    Generated by Type     : Type25
    TRNSYS Message    87  : Warning message text
    Reported information  : Additional details

*** Fatal Error at time   :         500.0
    Generated by Unit     : 10
    Generated by Type     : Type50
    TRNSYS Message    102 : Fatal error message
    Reported information  : Error details
```

### Message Categories

Messages are categorized into three levels:

1. **Notice**: Informational messages (lowest severity)
2. **Warning**: Warning messages (medium severity)
3. **Fatal**: Fatal error messages (highest severity)

### Parsing Behavior

- Messages are automatically parsed when you call `sim.update()`
- The parser handles missing or "not applicable" values gracefully
- Messages are sorted by severity (Notice < Warning < Fatal) and then by simulation time
- If the log file doesn't exist, `log` will be an empty list
- The parser uses UTF-8 encoding with error handling (`errors="ignore"`)

### Accessing Log Messages

```python
# Get all messages
all_messages = sim.log

# Get only fatal messages
fatal_messages = [msg for msg in sim.log if msg.level == "Fatal"]

# Get messages at a specific time
time_messages = [msg for msg in sim.log if msg.time == 125.5]

# Print a message
for msg in sim.log:
    print(msg)  # Uses __str__ method for formatted output
```

### Message Properties

Each `TrnsysLogMessage` has:

- `level`: Severity level ("Notice", "Warning", or "Fatal")
- `time`: Simulation time when generated
- `unit`: Unit number (empty string if not applicable)
- `type_number`: Type number (empty string if not applicable)
- `message`: Main message content
- `information`: Additional reported information

## Display System

The `SimulationManager` includes a live display system that shows progress for all simulations in real-time.

### Display Features

- **Live Updates**: Automatically refreshes at the `update_interval` rate
- **Thread-Safe**: Safe to use with concurrent simulations
- **Progress Bars**: ASCII-style progress bars (20 characters wide)
- **Time Formatting**: Elapsed time and ETA in HH:MM:SS format
- **Path Truncation**: Long paths are left-truncated with ellipsis
- **Status Colors**: Status indicators for each simulation state

### Display Format

Each simulation is shown on a separate line:

```
[1]  simulation.dck          │ Status: Running    │ Logs: N:2 W:1 F:0 │ Elapsed: 00:05:23 │ ETA: 00:10:45 │ [##########----------] 1,250 / 8,760 (14%)
```

Where:

- `[1]`: Simulation ID
- `simulation.dck`: Deck file path (truncated if > 64 chars)
- `Status: Running`: Current status
- `Logs: N:2 W:1 F:0`: Notice, Warning, Fatal counts
- `Elapsed: 00:05:23`: Elapsed time
- `ETA: 00:10:45`: Estimated time remaining
- `[##########----------]`: Progress bar
- `1,250 / 8,760 (14%)`: Simulation time progress and percentage

### Display Control

The display is automatically managed when using `SimulationManager` as a context manager:

```python
with SimulationManager() as manager:
    # Display starts automatically
    manager.add("sim1.dck")
    # Display updates automatically
    manager.wait()
    # Display stops automatically on exit
```

You can also manually control the display (advanced usage):

```python
manager = SimulationManager()
with manager.display.live_display():
    # Display is active
    manager.add("sim1.dck")
    manager.wait()
    # Display stops when context exits
```

## Error Handling

### Common Exceptions

#### FileNotFoundError

Raised when:

- Deck file doesn't exist (in `Simulation` constructor or `trnexe()`)
- TRNEXE executable doesn't exist (in `trnexe()`)

**Example**:

```python
try:
    sim = Simulation("nonexistent.dck")
except FileNotFoundError as e:
    print(f"File not found: {e}")
```

#### RuntimeError

Raised when:

- TRNSYS process cannot be started (permission issues, executable problems)

**Example**:

```python
try:
    process = trnexe("deck.dck", trnexe_path="invalid_path.exe")
except RuntimeError as e:
    print(f"Failed to launch: {e}")
```

#### ValueError

Raised when:

- Invalid `window_mode` value
- Invalid `window_timeout` (non-positive)
- Invalid timing parameters in internal functions

**Example**:

```python
try:
    process = trnexe("deck.dck", window_mode="invalid")
except ValueError as e:
    print(f"Invalid parameter: {e}")
```

#### TimeoutError

Raised when:

- `sim.wait(timeout=...)` times out

**Example**:

```python
try:
    sim.wait(timeout=60.0)
except TimeoutError:
    print("Simulation did not complete within timeout")
    sim.terminate()
```

### Error Handling Best Practices

1. **Always check file existence** before creating `Simulation` objects:

```python
from pathlib import Path

dck_path = Path("simulation.dck")
if not dck_path.exists():
    print(f"Error: {dck_path} does not exist")
    return
```

2. **Handle simulation failures**:

```python
sim.update()
if sim.status == SimulationStatus.FAILED:
    print(f"Simulation failed: {sim.fatals} fatal errors")
    for msg in sim.log:
        if msg.level == "Fatal":
            print(f"  {msg.message}")
```

3. **Use context managers** for automatic cleanup:

```python
with Simulation("deck.dck") as sim:
    sim.run()
    # Automatic cleanup on exception
```

4. **Check process state** before operations:

```python
if sim.process is not None and sim.is_alive():
    sim.terminate()
```

## Thread Safety

### SimulationManager Thread Safety

The `SimulationManager` is designed to be thread-safe:

- **`add()`**: Thread-safe, can be called from multiple threads
- **`active()`**: Thread-safe
- **`finished()`**: Thread-safe
- **`clear()`**: Thread-safe
- **`wait()`**: Thread-safe
- **`shutdown()`**: Thread-safe

Internal operations use locks to ensure thread safety.

### Simulation Thread Safety

The `Simulation` class is **not** fully thread-safe for concurrent access. However:

- Multiple `Simulation` objects can be used concurrently (each manages its own process)
- Properties are generally safe to read
- `update()` should not be called concurrently from multiple threads on the same `Simulation` object
- When using `SimulationManager`, each simulation is managed by a single thread, so this is not an issue

### Best Practices

1. **Use SimulationManager** for concurrent simulations (handles thread safety automatically)
2. **Don't share Simulation objects** across threads without synchronization
3. **Use locks** if you need to access a `Simulation` from multiple threads manually

## Best Practices

### 1. Use Appropriate Window Modes

- **`"hide"`**: Best for batch processing and concurrent simulations
- **`"flash"`**: Good for single simulations where you want to see it briefly
- **`"wait"`**: Only for interactive use or debugging

### 2. Set Appropriate Concurrency Limits

```python
# For CPU-bound simulations
max_concurrent = os.cpu_count() - 1

# For I/O-bound simulations
max_concurrent = os.cpu_count() * 2

# For very resource-intensive simulations
max_concurrent = 1
```

### 3. Regular Status Updates

Call `update()` regularly to keep status current:

```python
while sim.is_alive():
    sim.update()
    # Check status, progress, etc.
    time.sleep(1)  # Don't update too frequently
```

### 4. Handle Failures Gracefully

```python
sim.update()
if sim.status == SimulationStatus.FAILED:
    # Log errors, retry, or notify user
    handle_failure(sim)
```

### 5. Clean Up Resources

Always use context managers or call `shutdown()`:

```python
# Good
with SimulationManager() as manager:
    # ...

# Also good
manager = SimulationManager()
try:
    # ...
finally:
    manager.shutdown()
```

### 6. Monitor Progress Efficiently

Don't update too frequently (wastes CPU):

```python
# Good: Update every 2-5 seconds
update_interval = 2.0

# Bad: Update every 0.01 seconds (unless necessary)
update_interval = 0.01
```

### 7. Use Type3830 for Progress Tracking

Enable Type3830 in your TRNSYS deck files to get accurate progress information.

### 8. Check Log Files

Always check for warnings and fatal errors:

```python
if sim.warnings > 0:
    print(f"Warning: {sim.warnings} warnings")
if sim.fatals > 0:
    print(f"Error: {sim.fatals} fatal errors")
    for msg in sim.log:
        if msg.level == "Fatal":
            print(f"  {msg}")
```

## Troubleshooting

### Simulation Not Starting

**Problem**: `trnexe()` or `sim.run()` doesn't start the simulation.

**Solutions**:

1. Check that the TRNEXE path is correct
2. Verify the deck file exists and is readable
3. Check Windows permissions
4. Try running TRNEXE manually to verify it works
5. Check for error messages in the exception

### Progress Not Updating

**Problem**: `sim.progress` is always `None` or shows 0%.

**Solutions**:

1. Verify Type3830 is configured in your deck file
2. Check that Type3830 is writing to `{deck_name}.tmp`
3. Ensure the `.tmp` file is being created during simulation
4. Check file permissions (read access)

### Window Detection Failing

**Problem**: Window detection times out or doesn't work.

**Solutions**:

1. Increase `window_timeout` value
2. Disable window detection: `window_detection=False`
3. Check if TRNSYS window actually appears (try `window_mode="wait"`)
4. Verify TRNSYS version compatibility

### Concurrent Launch Conflicts

**Problem**: Multiple simulations fail to launch concurrently.

**Solutions**:

1. Ensure `use_lock=True` (default)
2. Increase `delay` between launches
3. Reduce `max_concurrent` in `SimulationManager`
4. Check TRNSYS license limitations

### Display Not Updating

**Problem**: Live display doesn't show updates.

**Solutions**:

1. Ensure you're using `SimulationManager` as a context manager
2. Check that `update_interval` is reasonable (not too large)
3. Verify terminal supports Rich library output
4. Check for exceptions in the refresh thread

### Memory Issues with Many Simulations

**Problem**: High memory usage with many simulations.

**Solutions**:

1. Use `manager.clear()` to remove finished simulations
2. Process simulations in batches
3. Reduce `max_concurrent` to limit active simulations
4. Don't store all simulation objects if not needed

### Log Parsing Issues

**Problem**: Log messages not parsed correctly.

**Solutions**:

1. Check log file encoding (should be UTF-8)
2. Verify log file format matches expected TRNSYS format
3. Check for corrupted log files
4. Manually inspect the `.log` file

## Requirements

- **Python**: >= 3.11
- **Operating System**: Windows (uses `pywin32` for window management)
- **TRNSYS**: Installed with TRNEXE executable accessible
- **Dependencies**:
  - `pywin32>=311`
  - `rich>=14.2.0`

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## Support

For issues, questions, or contributions, please use the project's issue tracker.
