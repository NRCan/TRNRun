"""Configuration for launching a TRNRun process."""


from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
# Queue and runner executables are bundled inside this package under `bin/`.
_PACKAGE_DIR = Path(__file__).resolve().parent
BUNDLED_TRNRUN_PATH = _PACKAGE_DIR / "bin" / "trnrun.exe"
BUNDLED_TRNRUNQ_PATH = _PACKAGE_DIR / "bin" / "trnrunq.exe"

DEFAULT_TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")


# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
@dataclass
class SimulationConfig:
    r"""Configuration used to launch TRNRun.

    Except for `trnrun_path`, each field maps to a `trnrun.exe` command-line
    flag (noted below as `--flag`). Flags are passed as `--name:value`.
    Relative executable paths are interpreted from Python's working directory.
    These defaults mirror trnrun's own CLI defaults: the detection timeout is
    300 seconds, the
    watch/stall timeouts are `0` (unlimited/disabled), progress tracking
    (`watch_tmp`) is off, and `clean_on_success`, `write_events`, and both
    kill-on-* behaviors are disabled.

    Attributes
    ----------
    trnrun_path : str or Path, default `BUNDLED_TRNRUN_PATH`
        Path to the `trnrun.exe` executable to invoke. Defaults to the copy
        bundled with this package.
    trnexe_path : str or Path, default `DEFAULT_TRNEXE_PATH`
        Path to the TRNSYS executable (`TrnEXE64.exe` or `TrnEXE.exe`),
        passed as `--trnexePath`. trnrun's own fallback is
        `C:\TRNSYS18\Exe\TrnEXE64.exe`; set this if TRNSYS is installed
        elsewhere.
    gui_visibility : str, default `"hidden"`
        TRNSYS window behavior, passed as `--guiVisibility` (case-insensitive).
        One of:

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
        Wait for the component-order header in the `*.lst` file during
        launch detection (`--waitForLst`).
    wait_for_tmp : bool, default `False`
        Wait for the `*.tmp` file to appear during launch detection
        (`--waitForTmp`). Requires a Progress Tracker (Type3830) in the deck.
    detect_timeout_ms : int, default `300000`
        Shared timeout in milliseconds for the launch-detection stages
        (`--detectTimeout`). `0` means unlimited. If `kill_on_timeout` is
        enabled and TRNSYS is still running, expiration yields `TIMEOUT`;
        otherwise the runner proceeds to runtime monitoring.
        Detection holds the session-wide launch mutex. This deadline excludes
        the subsequent `extra_delay_ms` and is not a total mutex-hold limit.
    extra_delay_ms : int, default `0`
        Additional delay in milliseconds applied after detection passes
        (`--extraDelay`).
    poll_ms : int, default `100`
        Polling interval in milliseconds for the output files and the process
        (`--pollMs`). The runner clamps this to at least 1 and raises positive
        watch/stall timeouts shorter than this interval to this interval.
    watch_log : bool, default `True`
        Stream `*.log` entries as `LOG` events (`--watchLog`).
    watch_tmp : bool, default `False`
        Stream `*.tmp` updates as `CONFIG`/`PROGRESS` events
        (`--watchTmp`). Requires Type3830. This also gates progress-derived
        outcomes: without it, `CANCELLED` and `STALLED` cannot be detected.
        An early exit without another detected failure is reported as `DONE`.
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
        (`--killOnTimeout`). If `False`, detection proceeds into monitoring;
        after a watch timeout, the runner waits for TRNSYS to exit.
    kill_on_stall : bool, default `False`
        Kill the TRNSYS process when a stall is detected (`--killOnStall`).
        If `False`, the runner waits for it to exit.
    severity : str, default `"Notice"`
        Minimum log severity to emit (`--severity`), one of `"Notice"`,
        `"Warning"`, or `"Fatal"` (case-insensitive).
    write_events : bool, default `False`
        Write every emitted event to `<deckFile>.jsonl`, replacing any existing
        file when the run starts (`--writeEvents`).

    Notes
    -----
    Boolean fields require actual booleans, not strings or integers. The native
    runner parses other options and clamps negative timeouts and delays to zero.
    Stall detection is inactive unless `watch_tmp=True`. `validate()` checks
    executable files; `SimulationManager` calls it before submission.
    """

    trnrun_path: str | Path = BUNDLED_TRNRUN_PATH
    trnexe_path: str | Path = DEFAULT_TRNEXE_PATH
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
        """Check both executable files, then store their absolute paths.

        Raises
        ------
        FileNotFoundError
            If `trnrun_path` or `trnexe_path` is not a file.
        """
        runner = Path(self.trnrun_path).absolute()
        trnexe = Path(self.trnexe_path).absolute()
        if not runner.is_file():
            raise FileNotFoundError(f"TRNRun executable not found: {runner}")
        if not trnexe.is_file():
            raise FileNotFoundError(f"TrnEXE executable not found: {trnexe}")
        # The queue resolves relative runner paths beside itself, not from our cwd.
        self.trnrun_path = runner
        self.trnexe_path = trnexe

    def to_cli_args(self) -> list[str]:
        """Return unquoted argv entries; call `validate()` before launching.

        Does not mutate the configuration or require installed executables.
        Boolean values are checked here to avoid silently coercing strings.
        """
        def boolean(value: object) -> str:
            if type(value) is not bool:
                raise TypeError(f"Expected a boolean, got {value!r}")
            return "true" if value else "false"

        return [
            f"--trnexePath:{Path(self.trnexe_path).absolute()}",
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
