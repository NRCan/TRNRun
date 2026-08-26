"""Configuration for launching a TRNRun process."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path

# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
# `trnrun.exe` is bundled inside this package under `bin/`.
_PACKAGE_DIR = Path(__file__).resolve().parent
BUNDLED_TRNRUN_PATH = _PACKAGE_DIR / "bin" / "trnrun.exe"

DEFAULT_TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")


# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
@dataclass
class SimulationConfig:
    r"""Configuration used to launch TRNRun.

    Each field maps to a `trnrun.exe` command-line flag (noted below as
    `--flag`). Flags are passed as `--name:value`. These defaults mirror
    trnrun's own CLI defaults: the detection timeout is 300 seconds, the
    watch/stall timeouts are `0` (unlimited/disabled), progress tracking
    (`watch_tmp`) is off, and `clean_on_success`, `write_events`, and both
    kill-on-* behaviors are disabled.

    Attributes
    ----------
    trnrun_path : Path, default `BUNDLED_TRNRUN_PATH`
        Path to the `trnrun.exe` executable to invoke. Defaults to the copy
        bundled with this package.
    trnexe_path : Path, default `DEFAULT_TRNEXE_PATH`
    Path to the TRNSYS executable (`TrnEXE64.exe` or `TrnEXE.exe`),
    passed as `--trnexePath`. trnrun's own fallback is
    `C:\\TRNSYS18\\Exe\\TrnEXE64.exe`; set this if TRNSYS is installed
        elsewhere.
    gui_visibility : str, default `"hidden"`
    TRNSYS window behavior, passed as `--guiVisibility`. One of:

        - `keep`/`keepOpen`    - visible, stays open after the run.
        - `auto`/`autoClose`   - visible, closes after the run.
        - `min`/`minimized`    - minimized, stays open after the run.
        - `minAuto`/`minimizedAuto` - minimized, closes after the run.
        - `hidden`               - no window, closes after the run.

    wait_for_gui : bool, default `True`
        Wait for a TRNSYS GUI as part of launch detection (`--waitForGui`).
        Launch detection determines when startup has completed so the global
        mutex can be released for the next simulation.
    wait_for_lst : bool, default `True`
    Wait for a specific string to appear in the `*.lst` file during
    launch detection (`--waitForLst`).
    wait_for_tmp : bool, default `False`
    Wait for the `*.tmp` file to appear during launch detection
    (`--waitForTmp`). Requires a Progress Tracker (Type3830) in the deck.
    detect_timeout_ms : int, default `300000`
        Timeout in milliseconds for the launch-detection stages
        (`--detectTimeout`). `0` means unlimited. Combined with
        `kill_on_timeout`, exceeding this yields a `TIMEOUT` status.
        Detection runs while TRNRun holds the session-wide launch mutex, so
        this also caps how long one deck can block other runners.
    extra_delay_ms : int, default `0`
        Additional delay in milliseconds applied after detection passes
        (`--extraDelay`).
    poll_ms : int, default `100`
        Polling interval in milliseconds for the output files and the process
        (`--pollMs`).
    watch_log : bool, default `True`
    Stream `*.log` entries as `LOG` events (`--watchLog`).
    watch_tmp : bool, default `False`
    Stream `*.tmp` updates as `CONFIG`/`PROGRESS` events
    (`--watchTmp`). Requires Type3830. This also gates progress-derived
    outcomes: without it, `CANCELLED` and `STALLED` cannot be detected
    and an early exit is reported as `DONE` instead.
    watch_timeout_ms : int, default `0`
        Maximum runtime-monitoring duration in milliseconds
        (`--watchTimeout`). `0` means unlimited. Exceeding it corresponds
        to a `TIMEOUT` status / exit code 124.
    stall_timeout_ms : int, default `0`
        Maximum wall-clock time in milliseconds with no simulation-time
        progress before the run is considered stalled (`--stallTimeout`).
        `0` disables the check. Requires `watch_tmp=True`. A stall yields a
        `STALLED` status / exit code 125.
    clean_on_success : bool, default `False`
    On a successful run, delete the `*.tmp`, `*.log`, `*.lst`, and
    `*.PTI` artifacts (`--clean`).
    kill_on_timeout : bool, default `False`
        Kill the TRNSYS process on a detection or watch timeout
        (`--killOnTimeout`). If `False`, the runner waits for it to exit.
    kill_on_stall : bool, default `False`
    Kill the TRNSYS process when a stall is detected (`--killOnStall`).
    If `False`, the runner waits for it to exit.
    severity : str, default `"Notice"`
    Minimum log severity to emit (`--severity`), one of `"Notice"`,
    `"Warning"`, or `"Fatal"`.
    write_events : bool, default `False`
    Write every emitted event to `<deckFile>.jsonl`, replacing any existing
    file when the run starts (`--writeEvents`).
    """

    trnrun_path: Path = BUNDLED_TRNRUN_PATH
    trnexe_path: Path = DEFAULT_TRNEXE_PATH
    gui_visibility: str = "hidden"
    wait_for_gui: bool = True
    wait_for_lst: bool = True
    wait_for_tmp: bool = False
    detect_timeout_ms: int = 300_000
    extra_delay_ms: int = 0
    poll_ms: int = 100
    watch_log: bool = True
    watch_tmp: bool = False
    watch_timeout_ms: int = 0
    stall_timeout_ms: int = 0
    clean_on_success: bool = False
    kill_on_timeout: bool = False
    kill_on_stall: bool = False
    severity: str = "Notice"
    write_events: bool = False

    def validate(self) -> None:
        """Check that both executables exist.

        Raises
        ------
        FileNotFoundError
            If `trnrun_path` or `trnexe_path` is not a file.
        """
        if not self.trnrun_path.is_file():
            raise FileNotFoundError(f"TRNRun executable not found: {self.trnrun_path}")
        if not self.trnexe_path.is_file():
            raise FileNotFoundError(f"TrnEXE executable not found: {self.trnexe_path}")

    def to_cli_args(self) -> list[str]:
        """Convert configuration into `trnrun.exe` command-line arguments."""

        def boolean(value: bool) -> str:
            return "true" if value else "false"

        return [
            f"--trnexePath:{self.trnexe_path}",
            f"--guiVisibility:{self.gui_visibility}",
            f"--waitForGui:{boolean(self.wait_for_gui)}",
            f"--waitForLst:{boolean(self.wait_for_lst)}",
            f"--waitForTmp:{boolean(self.wait_for_tmp)}",
            f"--detectTimeout:{self.detect_timeout_ms}",
            f"--extraDelay:{self.extra_delay_ms}",
            f"--pollMs:{self.poll_ms}",
            f"--watchLog:{boolean(self.watch_log)}",
            f"--watchTmp:{boolean(self.watch_tmp)}",
            f"--watchTimeout:{self.watch_timeout_ms}",
            f"--stallTimeout:{self.stall_timeout_ms}",
            f"--clean:{boolean(self.clean_on_success)}",
            f"--killOnTimeout:{boolean(self.kill_on_timeout)}",
            f"--killOnStall:{boolean(self.kill_on_stall)}",
            f"--severity:{self.severity}",
            f"--writeEvents:{boolean(self.write_events)}",
        ]
