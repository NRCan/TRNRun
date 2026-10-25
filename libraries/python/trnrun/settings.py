"""TRNRun options for a simulation."""

from dataclasses import dataclass, fields
from pathlib import Path
from typing import ClassVar, Literal, cast

from trnrun.simulation import LogSeverity


@dataclass
class SimulationSettings:
    r"""TRNRun options for a simulation; each field that is set becomes one ``--flag:value``.

    A field left at None is not passed, so TRNRun's default applies. See
    ``trnrun.exe --help`` for what each flag does; trnrund validates the values
    when a run is added.

    Attributes
    ----------
    trnexe_path : str or Path, optional
        TRNSYS executable (``--trnexePath``); must exist.
    gui_visibility : str, optional
        TRNSYS window: ``keep``, ``auto``, ``min``, ``minAuto`` or ``hidden`` (``--guiVisibility``).
    wait_for_gui, wait_for_lst, wait_for_tmp : bool, optional
        Launch-detection signals (``--waitForGui``, ``--waitForLst``, ``--waitForTmp``).
    detect_timeout_ms, extra_delay_ms : int, optional
        Launch-detection timeout, and delay after it (``--detectTimeout``, ``--extraDelay``).
    poll_ms : int, optional
        Output-file and process polling interval (``--pollMs``).
    watch_log, watch_tmp : bool, optional
        Report *.log entries and *.tmp progress (``--watchLog``, ``--watchTmp``). watch_tmp needs
        Type3830 in the deck; without it, an early exit is reported as DONE.
    watch_timeout_ms, stall_timeout_ms : int, optional
        Runtime limit, and longest time without progress (``--watchTimeout``, ``--stallTimeout``); 0 disables.
    clean_on_success : bool, optional
        Delete TRNSYS output artifacts after a successful run (``--clean``).
    kill_on_timeout, kill_on_stall : bool, optional
        Kill TRNSYS on a timeout or a stall (``--killOnTimeout``, ``--killOnStall``).
    severity : LogSeverity or str, optional
        Minimum log severity: Notice, Warning or Fatal (``--severity``).
    write_events : bool, optional
        Write the events to a .jsonl file beside the deck (``--writeEvents``).
    """

    trnexe_path: str | Path | None = None
    gui_visibility: Literal["keep", "auto", "min", "minAuto", "hidden"] | None = None
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
    severity: LogSeverity | Literal["Notice", "Warning", "Fatal"] | None = None
    write_events: bool | None = None

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

    def to_cli_args(self) -> list[str]:
        """Build the TRNRun flags of the fields that are set.

        Returns
        -------
        list of str
            Unquoted argv entries such as ``--watchTmp:true``, in field order;
            ``trnexe_path`` is made absolute from Python's working directory.

        Raises
        ------
        FileNotFoundError
            If ``trnexe_path`` is set but is not a file.
        """
        args: list[str] = []
        for settings_field in fields(self):
            name = settings_field.name
            value = cast("object", getattr(self, name))
            if value is None:
                continue
            if isinstance(value, bool):
                value = "true" if value else "false"
            elif name == "trnexe_path":
                trnexe = Path(str(value)).absolute()
                if not trnexe.is_file():
                    raise FileNotFoundError(f"TrnEXE executable not found: {trnexe}")
                value = trnexe
            args.append(f"--{self._FLAGS[name]}:{value}")
        return args
