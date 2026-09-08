"""Typed runner and queue events emitted on stdout, and their parsers.

TRNRun writes one JSON object per line. ``parse_event`` turns a single
line into a typed event, which is also how a ``--writeEvents`` ``.jsonl``
file is read back. Queue lifecycle objects are one more ``kind`` in
``TrnRunEvent`` and go through the same parser. ``parse_stream_line``
decodes the merged queue stdout stream, where runner and queue events
arrive interleaved and tagged with a ``runId``.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass
from typing import Final, Literal, cast


# -----------------------------------------------------------------
# Exceptions
# -----------------------------------------------------------------
class EventParseError(ValueError):
    """Raised when a runner or queue event cannot be parsed."""


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
    message : str
        Optional outcome or failure detail reported by TRNRun.
    """

    status: str
    timestamp: str
    message: str = ""


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


@dataclass(frozen=True)
class QueueEvent:
    """Queue admission or completion after all child output.

    ``exit_code`` is None for acceptance, or when runner resolution or
    launch failed before completion.
    """

    event: str
    run_id: str
    timestamp: str
    exit_code: int | None = None


type TrnRunEvent = StatusEvent | ProgressEvent | ConfigEvent | SettingEvent | LogEvent | QueueEvent

TERMINAL_STATUSES: Final[frozenset[str]] = frozenset(
    {"DONE", "ERROR", "CANCELLED", "TIMEOUT", "STALLED"},
)


def is_terminal_status(status: str) -> bool:
    """Return whether a status is an exact canonical terminal value."""
    return status in TERMINAL_STATUSES


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


def _optional_int(data: dict[str, object], key: str) -> int | None:
    """Return an optional integer field, treating JSON null as absent."""
    return None if data.get(key) is None else _require_int(data, key)


# -----------------------------------------------------------------
# Event Parsers
# -----------------------------------------------------------------
def _parse_status(data: dict[str, object]) -> StatusEvent:
    """Parse a STATUS event."""
    return StatusEvent(
        status=_require_str(data, "status"),
        timestamp=_require_str(data, "timestamp"),
        message=_optional_str(data, "message") or "",
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
        unit_id=_optional_int(data, "unitID"),
        type_id=_optional_int(data, "typeID"),
        message_code=_optional_int(data, "messageCode"),
        message=_optional_str(data, "message"),
        information=_optional_str(data, "information"),
    )


def _parse_queue(data: dict[str, object]) -> QueueEvent:
    """Parse a QUEUE event."""
    return QueueEvent(
        event=_require_str(data, "event"),
        run_id=_require_str(data, "runId"),
        timestamp=_require_str(data, "timestamp"),
        exit_code=_optional_int(data, "exitCode"),
    )


# Dispatch table mapping an event's "kind" to its parser.
_PARSERS: Final[dict[str, Callable[[dict[str, object]], TrnRunEvent]]] = {
    "STATUS": _parse_status,
    "PROGRESS": _parse_progress,
    "CONFIG": _parse_config,
    "SETTING": _parse_setting,
    "LOG": _parse_log,
    "QUEUE": _parse_queue,
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

    return parse_event_data(data)


def parse_stream_line(line: str) -> tuple[str, TrnRunEvent] | None:
    """Decode one queue stdout line into its run id and typed event.

    Parameters
    ----------
    line : str
        A single line of queue stdout, carrying either a queue lifecycle
        object or one runner event tagged with its ``runId``.

    Returns
    -------
    tuple of (str, TrnRunEvent), or None
        The run id and its typed event, or None for a line that carries no
        routable event: blank lines and the non-JSON diagnostics a runner may
        write straight to its own stdout.

    Raises
    ------
    EventParseError
        If the line holds a routable event whose payload is malformed.
    """
    stripped = line.strip()
    if not stripped:
        return None

    try:
        value = cast("object", json.loads(stripped))
    except json.JSONDecodeError:
        return None

    if not isinstance(value, dict):
        return None

    data = cast("dict[str, object]", value)
    run_id = data.get("runId")
    kind = data.get("kind")
    if not isinstance(run_id, str) or not isinstance(kind, str):
        return None

    return run_id, parse_event_data(data)


def parse_event_data(data: dict[str, object]) -> TrnRunEvent:
    """Parse an already decoded event object."""
    kind = _require_str(data, "kind").upper()

    try:
        parser = _PARSERS[kind]
    except KeyError as e:
        raise EventParseError(f"unknown event kind '{kind}'") from e

    return parser(data)
