"""Configuration for launching a TRNRun process."""

from dataclasses import dataclass
from pathlib import Path

DEFAULT_TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")


@dataclass
class SimulationConfig:
    r"""Configuration used to launch TRNRun.

    Each field maps to a trnrun.exe command-line flag (noted below as
    ``--flag``). Flags are passed as ``--name:value``. The trnrun.exe
    executable itself is chosen per ``Daemon``, since one daemon runs every
    simulation with the same runner. Relative paths are interpreted from
    Python's working directory.

    These defaults mirror the native runner: the detection timeout is 300
    seconds, watch/stall timeouts are 0 (unlimited/disabled), progress tracking
    is off, and cleanup, event-file output, and kill-on-* behaviors are off.
    ``Daemon.add()`` calls ``to_cli_args()`` when given this configuration,
    sending every field explicitly.

    Attributes
    ----------
    trnexe_path : str or Path, default DEFAULT_TRNEXE_PATH
        Path to the TRNSYS executable (TrnEXE64.exe or TrnEXE.exe), passed as
        ``--trnexePath``. The native fallback is
        ``C:\TRNSYS18\Exe\TrnEXE64.exe``; change this for another installation.
    gui_visibility : str, default "hidden"
        TRNSYS window behavior (``--guiVisibility``, case-insensitive):
        ``keep``/``keepOpen`` stays visible and open;
        ``auto``/``autoClose`` stays visible and closes after the run;
        ``min``/``minimized`` stays minimized and open;
        ``minAuto``/``minimizedAuto`` stays minimized and closes after the run;
        ``hidden`` has no window and closes after the run.
    wait_for_gui : bool, default True
        Wait for a TRNSYS GUI during launch detection (``--waitForGui``).
        Detection determines when startup has completed so the global launch
        mutex can be released for the next simulation.
    wait_for_lst : bool, default True
        Wait for the component-order header in the *.lst file during launch
        detection (``--waitForLst``).
    wait_for_tmp : bool, default False
        Wait for the *.tmp file during launch detection (``--waitForTmp``).
        Requires a Progress Tracker (Type3830) in the deck.
    detect_timeout_ms : int, default 300000
        Shared launch-detection timeout in milliseconds (``--detectTimeout``).
        0 means unlimited. If kill_on_timeout is enabled and TRNSYS is still
        running, expiration yields TIMEOUT; otherwise detection proceeds into
        monitoring. Detection holds the session-wide launch mutex. This
        deadline excludes extra_delay_ms and is not a total mutex-hold limit.
    extra_delay_ms : int, default 0
        Additional delay after detection passes (``--extraDelay``), in
        milliseconds.
    poll_ms : int, default 100
        Output-file and process polling interval (``--pollMs``), in
        milliseconds. The runner clamps it to at least 1 and raises positive
        watch/stall timeouts shorter than this interval to this interval.
    watch_log : bool, default True
        Stream *.log entries as LOG events (``--watchLog``).
    watch_tmp : bool, default False
        Stream *.tmp updates as CONFIG/PROGRESS events (``--watchTmp``).
        Requires Type3830. Also gates progress-derived CANCELLED and STALLED
        outcomes. Without it, an early exit without another detected failure
        is reported as DONE.
    watch_timeout_ms : int, default 0
        Runtime-monitoring timeout (``--watchTimeout``), in milliseconds.
        0 means unlimited. Expiration corresponds to TIMEOUT / exit code 124.
    stall_timeout_ms : int, default 0
        Maximum wall-clock milliseconds without simulation-time progress
        (``--stallTimeout``). 0 disables the check. Requires watch_tmp=True.
        A stall yields STALLED / exit code 125.
    clean_on_success : bool, default False
        Delete *.tmp, *.log, *.lst, and *.PTI artifacts on success (``--clean``).
    kill_on_timeout : bool, default False
        Kill TRNSYS on a detection/watch timeout (``--killOnTimeout``).
        Otherwise detection proceeds into monitoring; after a watch timeout,
        the runner waits for TRNSYS to exit.
    kill_on_stall : bool, default False
        Kill TRNSYS when a stall is detected (``--killOnStall``).
        Otherwise the runner waits for TRNSYS to exit.
    severity : str, default "Notice"
        Minimum emitted log severity (``--severity``): Notice, Warning, or
        Fatal, case-insensitive.
    write_events : bool, default False
        Write emitted events to a .jsonl file beside the deck
        (``--writeEvents``). For example, model.dck writes model.jsonl,
        replacing any existing file when the run starts.

    Notes
    -----
    Boolean fields require actual booleans, not strings or integers. The
    native runner parses other options and clamps negative timeouts/delays
    to zero. Stall detection is inactive unless watch_tmp=True.
    ``to_cli_args()`` checks that the TRNSYS executable exists before
    submission, so missing installations fail before runs are queued.
    """

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

    def to_cli_args(self) -> list[str]:
        """Return unquoted argv entries, with trnexe_path made absolute.

        Does not mutate the configuration. Boolean values are checked here
        to avoid silently coercing strings.

        Raises
        ------
        FileNotFoundError
            If trnexe_path is not a file.
        TypeError
            If a boolean field holds another type.
        """
        def boolean(value: object) -> str:
            if type(value) is not bool:
                raise TypeError(f"Expected a boolean, got {value!r}")
            return "true" if value else "false"

        trnexe = Path(self.trnexe_path).absolute()
        if not trnexe.is_file():
            raise FileNotFoundError(f"TrnEXE executable not found: {trnexe}")

        return [
            f"--trnexePath:{trnexe}",
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
