"""Settings for launching the trnrund and TRNRun processes."""

from dataclasses import dataclass, fields
from pathlib import Path
from typing import ClassVar, cast


@dataclass
class SimulationSettings:
    r"""TRNRun options for a simulation, with named, typed fields.

    Each field maps to a trnrun.exe command-line flag (noted below as
    ``--flag``), passed as ``--name:value``. A field left at ``None`` is not
    passed, so TRNRun's own default applies; run ``trnrun.exe --help`` for
    them. ``SimulationSettings()`` therefore passes nothing. The trnrun.exe
    executable itself is chosen per ``Daemon``, since one daemon runs every
    simulation with the same runner. Relative paths are interpreted from
    Python's working directory.

    Attributes
    ----------
    trnexe_path : str or Path, optional
        Path to the TRNSYS executable (TrnEXE64.exe or TrnEXE.exe), passed as
        ``--trnexePath``. Set it unless your installation matches TRNRun's
        default.
    gui_visibility : str, optional
        TRNSYS window behavior (``--guiVisibility``, case-insensitive):
        ``keep``/``keepOpen`` stays visible and open;
        ``auto``/``autoClose`` stays visible and closes after the run;
        ``min``/``minimized`` stays minimized and open;
        ``minAuto``/``minimizedAuto`` stays minimized and closes after the run;
        ``hidden`` has no window and closes after the run.
    wait_for_gui : bool, optional
        Wait for a TRNSYS GUI during launch detection (``--waitForGui``).
        Detection determines when startup has completed so the global launch
        mutex can be released for the next simulation.
    wait_for_lst : bool, optional
        Wait for the component-order header in the *.lst file during launch
        detection (``--waitForLst``).
    wait_for_tmp : bool, optional
        Wait for the *.tmp file during launch detection (``--waitForTmp``).
        Requires a Progress Tracker (Type3830) in the deck.
    detect_timeout_ms : int, optional
        Shared launch-detection timeout in milliseconds (``--detectTimeout``).
        0 means unlimited. If kill_on_timeout is enabled and TRNSYS is still
        running, expiration yields TIMEOUT; otherwise detection proceeds into
        monitoring. Detection holds the session-wide launch mutex. This
        deadline excludes extra_delay_ms and is not a total mutex-hold limit.
    extra_delay_ms : int, optional
        Additional delay after detection passes (``--extraDelay``), in
        milliseconds.
    poll_ms : int, optional
        Output-file and process polling interval (``--pollMs``), in
        milliseconds. The runner clamps it to at least 1 and raises positive
        watch/stall timeouts shorter than this interval to this interval.
    watch_log : bool, optional
        Stream *.log entries as LOG events (``--watchLog``).
    watch_tmp : bool, optional
        Stream *.tmp updates as CONFIG/PROGRESS events (``--watchTmp``).
        Requires Type3830. Also gates progress-derived CANCELLED and STALLED
        outcomes. Without it, an early exit without another detected failure
        is reported as DONE.
    watch_timeout_ms : int, optional
        Runtime-monitoring timeout (``--watchTimeout``), in milliseconds.
        0 means unlimited. Expiration corresponds to TIMEOUT / exit code 124.
    stall_timeout_ms : int, optional
        Maximum wall-clock milliseconds without simulation-time progress
        (``--stallTimeout``). 0 disables the check. Requires watch_tmp=True.
        A stall yields STALLED / exit code 125.
    clean_on_success : bool, optional
        Delete *.tmp, *.log, *.lst, and *.PTI artifacts on success (``--clean``).
    kill_on_timeout : bool, optional
        Kill TRNSYS on a detection/watch timeout (``--killOnTimeout``).
        Otherwise detection proceeds into monitoring; after a watch timeout,
        the runner waits for TRNSYS to exit.
    kill_on_stall : bool, optional
        Kill TRNSYS when a stall is detected (``--killOnStall``).
        Otherwise the runner waits for TRNSYS to exit.
    severity : str, optional
        Minimum emitted log severity (``--severity``): Notice, Warning, or
        Fatal, case-insensitive.
    write_events : bool, optional
        Write emitted events to a .jsonl file beside the deck
        (``--writeEvents``). For example, model.dck writes model.jsonl,
        replacing any existing file when the run starts.

    Notes
    -----
    Boolean fields require actual booleans, not strings or integers. trnrund
    checks the other values with TRNRun's own parser when a run is added.
    ``to_cli_args()`` checks that a set ``trnexe_path`` exists, so a missing
    installation fails before runs are queued.
    """

    trnexe_path: str | Path | None = None
    gui_visibility: str | None = None
    wait_for_gui: bool | None = None
    wait_for_lst: bool | None = None
    wait_for_tmp: bool | None = None
    detect_timeout_ms: int | None = None
    extra_delay_ms: int | None = None
    poll_ms: int | None = None
    watch_log: bool | None = None
    watch_tmp: bool | None = None
    watch_timeout_ms: int | None = None
    stall_timeout_ms: int | None = None
    clean_on_success: bool | None = None
    kill_on_timeout: bool | None = None
    kill_on_stall: bool | None = None
    severity: str | None = None
    write_events: bool | None = None

    # TRNRun flag of each field.
    _FLAGS: ClassVar[dict[str, str]] = {
        "trnexe_path": "trnexePath",
        "gui_visibility": "guiVisibility",
        "wait_for_gui": "waitForGui",
        "wait_for_lst": "waitForLst",
        "wait_for_tmp": "waitForTmp",
        "detect_timeout_ms": "detectTimeout",
        "extra_delay_ms": "extraDelay",
        "poll_ms": "pollMs",
        "watch_log": "watchLog",
        "watch_tmp": "watchTmp",
        "watch_timeout_ms": "watchTimeout",
        "stall_timeout_ms": "stallTimeout",
        "clean_on_success": "clean",
        "kill_on_timeout": "killOnTimeout",
        "kill_on_stall": "killOnStall",
        "severity": "severity",
        "write_events": "writeEvents",
    }
    _BOOLEANS: ClassVar[frozenset[str]] = frozenset(
        {
            "wait_for_gui",
            "wait_for_lst",
            "wait_for_tmp",
            "watch_log",
            "watch_tmp",
            "clean_on_success",
            "kill_on_timeout",
            "kill_on_stall",
            "write_events",
        },
    )

    def to_cli_args(self) -> list[str]:
        """Return unquoted argv entries for the fields that are set, with trnexe_path made absolute."""
        args: list[str] = []
        for settings_field in fields(self):
            name = settings_field.name
            value = cast("object", getattr(self, name))
            if value is None:
                continue
            if name in self._BOOLEANS:
                if type(value) is not bool:
                    raise TypeError(f"{name} must be True, False or None, got {value!r}")
                value = "true" if value else "false"
            elif name == "trnexe_path":
                trnexe = Path(str(value)).absolute()
                if not trnexe.is_file():
                    raise FileNotFoundError(f"TrnEXE executable not found: {trnexe}")
                value = trnexe
            args.append(f"--{self._FLAGS[name]}:{value}")
        return args


@dataclass
class DaemonSettings:
    r"""trnrund options for a daemon, with named, typed fields.

    Each field maps to a trnrund.exe command-line flag (noted below as
    ``--flag``), passed as ``--name:value``. A field left at ``None`` is not
    passed, so trnrund's own default applies; run ``trnrund.exe --help`` for
    them. ``Daemon`` builds one from its parameters, so callers keep passing
    those. Relative paths are interpreted from Python's working directory.

    Attributes
    ----------
    trnrun_path : str or Path, optional
        TRNRun executable every run is started with (``--trnrun``). trnrund
        defaults to the trnrun.exe beside it.
    max_concurrent : int, optional
        Simulations run at once (``--maxConcurrent``), at least 1. trnrund
        defaults to one less than the CPU count, at least 1.
    database_path : str or Path, optional
        SQLite database holding every run's state and logs (``--database``).
        It is created if missing, but its directory must exist. trnrund
        defaults to trnrund.sqlite3 in its working directory.

    Notes
    -----
    trnrund checks the values when it starts, and exits with a usage error
    for a missing TRNRun or a max_concurrent below 1.
    """

    trnrun_path: str | Path | None = None
    max_concurrent: int | None = None
    database_path: str | Path | None = None

    # trnrund flag of each field.
    _FLAGS: ClassVar[dict[str, str]] = {
        "trnrun_path": "trnrun",
        "max_concurrent": "maxConcurrent",
        "database_path": "database",
    }
    _PATHS: ClassVar[frozenset[str]] = frozenset({"trnrun_path", "database_path"})

    def to_cli_args(self) -> list[str]:
        """Return unquoted argv entries for the fields that are set, with paths made absolute."""
        args: list[str] = []
        for settings_field in fields(self):
            name = settings_field.name
            value = cast("object", getattr(self, name))
            if value is None:
                continue
            if name in self._PATHS:
                value = Path(str(value)).absolute()
            args.append(f"--{self._FLAGS[name]}:{value}")
        return args
