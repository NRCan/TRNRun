"""Typed events emitted by TRNRun on stdout, and their JSONL parsers.

TRNRun writes one JSON object per line. ``parse_event`` turns a single
line into a typed event; ``stream_events`` does the same for an entire
stream of lines.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from typing import Final, cast


# -----------------------------------------------------------------
# Exceptions
# -----------------------------------------------------------------
class EventParseError(ValueError):
    """Raised when a JSON line cannot be parsed into a TRNRun event."""


# -----------------------------------------------------------------
# Events
# -----------------------------------------------------------------
@dataclass(frozen=True)
class StatusEvent:
    """A STATUS event reporting the run's current state.

    Attributes
    ----------
    status : str
        State reported by TRNRun.
    timestamp : str
        Timestamp attached to the event by TRNRun.
    """

    status: str
    timestamp: str


@dataclass(frozen=True)
class ProgressEvent:
    """A PROGRESS event reporting run completion and timing.

    Attributes
    ----------
    time : float
        Current simulation time.
    percent : float
        Completion of the run as a fraction from 0 to 1.
    elapsed : float
        Wall-clock milliseconds elapsed since the run started.
    eta : float
        Estimated wall-clock milliseconds remaining.
    timestamp : str
        Timestamp attached to the event by TRNRun.
    """

    time: float
    percent: float
    elapsed: float
    eta: float
    timestamp: str


@dataclass(frozen=True)
class ConfigEvent:
    """A CONFIG event reporting the run's sweep parameters.

    Attributes
    ----------
    start : float
        Simulation start time.
    stop : float
        Simulation stop time.
    step : float
        Simulation time step.
    timestamp : str
        Timestamp attached to the event by TRNRun.
    """

    start: float
    stop: float
    step: float
    timestamp: str


@dataclass(frozen=True)
class SettingEvent:
    """A SETTING event reporting the configured runner settings.

    Wire-protocol field names are converted from camelCase to snake_case.
    Protocol metadata such as ``kind`` and ``seq`` is not retained.
    """

    timestamp: str
    trnexe_path: str
    gui_visibility: str
    wait_for_gui: bool
    wait_for_lst: bool
    wait_for_tmp: bool
    detect_timeout_ms: int
    extra_delay_ms: int
    watch_log: bool
    watch_tmp: bool
    watch_timeout_ms: int
    stall_timeout_ms: int
    poll_ms: int
    clean_on_success: bool
    kill_on_timeout: bool
    kill_on_stall: bool
    severity: str
    write_events: bool


@dataclass(frozen=True)
class LogEvent:
    """A LOG event carrying a severity-tagged message.

    Only ``severity`` and ``timestamp`` are guaranteed; the remaining
    fields depend on what TRNRun attaches to the message.

    Attributes
    ----------
    severity : str
        Severity tag, e.g. ``"notice"``, ``"warning"`` or ``"fatal"``.
    timestamp : str
        Timestamp attached to the event by TRNRun.
    time : float or None
        Simulation time at which the message was produced.
    unit_id : int or None
        Unit that emitted the message.
    type_id : int or None
        Type of the unit that emitted the message.
    message_code : int or None
        Numeric code identifying the message.
    message : str or None
        Human-readable message text.
    information : str or None
        Additional detail attached to the message.
    """

    severity: str
    timestamp: str
    time: float | None = None
    unit_id: int | None = None
    type_id: int | None = None
    message_code: int | None = None
    message: str | None = None
    information: str | None = None


type TrnRunEvent = StatusEvent | ProgressEvent | ConfigEvent | SettingEvent | LogEvent


# -----------------------------------------------------------------
# Validation Helpers
# -----------------------------------------------------------------
def _required(data: dict[str, object], key: str) -> object:
    """Return a required field, raising ``EventParseError`` if missing."""
    try:
        return data[key]
    except KeyError as e:
        raise EventParseError(f"missing required field '{key}'") from e


def _require_str(data: dict[str, object], key: str) -> str:
    """Return a required string field."""
    value = _required(data, key)

    if not isinstance(value, str):
        raise EventParseError(f"field '{key}' must be a string")

    return value


def _require_bool(data: dict[str, object], key: str) -> bool:
    """Return a required boolean field."""
    value = _required(data, key)

    if not isinstance(value, bool):
        raise EventParseError(f"field '{key}' must be a boolean")

    return value


def _require_float(data: dict[str, object], key: str) -> float:
    """Return a required numeric field as a float, rejecting booleans."""
    value = _required(data, key)

    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EventParseError(f"field '{key}' must be a number")

    return float(value)


def _require_int(data: dict[str, object], key: str) -> int:
    """Return a required integer field, rejecting booleans."""
    value = _required(data, key)

    if isinstance(value, bool) or not isinstance(value, int):
        raise EventParseError(f"field '{key}' must be an integer")

    return value


def _optional_str(data: dict[str, object], key: str) -> str | None:
    """Return an optional string field, treating JSON null as absent."""
    return None if data.get(key) is None else _require_str(data, key)


def _optional_float(data: dict[str, object], key: str) -> float | None:
    """Return an optional numeric field, treating JSON null as absent."""
    return None if data.get(key) is None else _require_float(data, key)


def _optional_int(data: dict[str, object], key: str, *aliases: str) -> int | None:
    """Return the first present optional integer field, treating null as absent."""
    for candidate in (key, *aliases):
        if candidate in data:
            return None if data[candidate] is None else _require_int(data, candidate)

    return None


# -----------------------------------------------------------------
# Event Parsers
# -----------------------------------------------------------------
def _parse_status(data: dict[str, object]) -> StatusEvent:
    """Parse a STATUS event."""
    return StatusEvent(
        status=_require_str(data, "status"),
        timestamp=_require_str(data, "timestamp"),
    )


def _parse_progress(data: dict[str, object]) -> ProgressEvent:
    """Parse a PROGRESS event."""
    return ProgressEvent(
        time=_require_float(data, "time"),
        percent=_require_float(data, "percent"),
        elapsed=_require_float(data, "elapsed"),
        eta=_require_float(data, "eta"),
        timestamp=_require_str(data, "timestamp"),
    )


def _parse_config(data: dict[str, object]) -> ConfigEvent:
    """Parse a CONFIG event."""
    return ConfigEvent(
        start=_require_float(data, "start"),
        stop=_require_float(data, "stop"),
        step=_require_float(data, "step"),
        timestamp=_require_str(data, "timestamp"),
    )


def _parse_setting(data: dict[str, object]) -> SettingEvent:
    """Parse a SETTING event."""
    return SettingEvent(
        timestamp=_require_str(data, "timestamp"),
        trnexe_path=_require_str(data, "trnexePath"),
        gui_visibility=_require_str(data, "guiVisibility"),
        wait_for_gui=_require_bool(data, "waitForGui"),
        wait_for_lst=_require_bool(data, "waitForLst"),
        wait_for_tmp=_require_bool(data, "waitForTmp"),
        detect_timeout_ms=_require_int(data, "detectTimeoutMs"),
        extra_delay_ms=_require_int(data, "extraDelayMs"),
        watch_log=_require_bool(data, "watchLog"),
        watch_tmp=_require_bool(data, "watchTmp"),
        watch_timeout_ms=_require_int(data, "watchTimeoutMs"),
        stall_timeout_ms=_require_int(data, "stallTimeoutMs"),
        poll_ms=_require_int(data, "pollMs"),
        clean_on_success=_require_bool(data, "cleanOnSuccess"),
        kill_on_timeout=_require_bool(data, "killOnTimeout"),
        kill_on_stall=_require_bool(data, "killOnStall"),
        severity=_require_str(data, "severity"),
        write_events=_require_bool(data, "writeEvents"),
    )


def _parse_log(data: dict[str, object]) -> LogEvent:
    """Parse a LOG event."""
    return LogEvent(
        severity=_require_str(data, "severity"),
        timestamp=_require_str(data, "timestamp"),
        time=_optional_float(data, "time"),
        unit_id=_optional_int(data, "unitID", "unitId"),
        type_id=_optional_int(data, "typeID", "typeId"),
        message_code=_optional_int(data, "messageCode"),
        message=_optional_str(data, "message"),
        information=_optional_str(data, "information"),
    )


# Dispatch table mapping an event's "kind" to its parser.
_PARSERS: Final[dict[str, Callable[[dict[str, object]], TrnRunEvent]]] = {
    "STATUS": _parse_status,
    "PROGRESS": _parse_progress,
    "CONFIG": _parse_config,
    "SETTING": _parse_setting,
    "LOG": _parse_log,
}


# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------
def parse_event(line: str) -> TrnRunEvent:
    """Parse one JSON-encoded TRNRun event.

    Parameters
    ----------
    line : str
        A single line of TRNRun stdout containing one JSON object.

    Returns
    -------
    TrnRunEvent
        The typed event corresponding to the object's ``kind``.

    """
    try:
        value = cast("object", json.loads(line))
    except json.JSONDecodeError as e:
        raise EventParseError(f"invalid JSON: {e}") from e

    if not isinstance(value, dict):
        raise EventParseError("event must be a JSON object")

    data = cast("dict[str, object]", value)

    kind = _require_str(data, "kind").upper()

    try:
        parser = _PARSERS[kind]
    except KeyError as e:
        raise EventParseError(f"unknown event kind '{kind}'") from e

    return parser(data)


def stream_events(
    lines: Iterable[str],
    *,
    skip_invalid: bool = False,
) -> Iterator[TrnRunEvent]:
    """Yield parsed events from a JSONL stream, skipping blank lines.

    Parameters
    ----------
    lines : Iterable[str]
        Lines of TRNRun stdout, one JSON object per line.
    skip_invalid : bool, optional
        If true, silently drop lines that fail to parse instead of
        raising. Defaults to False.

    Yields
    ------
    TrnRunEvent
        One typed event per successfully parsed line.
    """
    for raw_line in lines:
        line = raw_line.strip()

        if not line:
            continue

        try:
            yield parse_event(line)
        except EventParseError:
            if not skip_invalid:
                raise
