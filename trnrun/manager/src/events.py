"""Typed events emitted by TRNRun on stdout, and their JSONL parsers.

TRNRun.exe writes one JSON object per line. ``parse_event`` turns a single
line into a typed event; ``stream_events`` does the same for an entire
stream of lines.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from typing import Final, cast


# ---------------------------------------------------------------------------
# EXCEPTIONS
# ---------------------------------------------------------------------------
class EventParseError(ValueError):
    """Raised when a JSON line cannot be parsed into a TRNRun event."""


# ---------------------------------------------------------------------------
# EVENTS
# ---------------------------------------------------------------------------
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


# Union of every event TRNRun can emit on stdout.
type TrnRunEvent = StatusEvent | ProgressEvent | ConfigEvent | LogEvent


# ---------------------------------------------------------------------------
# VALIDATION HELPERS
# ---------------------------------------------------------------------------
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


# ---------------------------------------------------------------------------
# EVENT PARSERS
# ---------------------------------------------------------------------------
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


def _parse_log(data: dict[str, object]) -> LogEvent:
    """Parse a LOG event."""
    return LogEvent(
        severity=_require_str(data, "severity"),
        timestamp=_require_str(data, "timestamp"),
        time=_optional_float(data, "time"),
        unit_id=_optional_int(data, "unitId"),
        type_id=_optional_int(data, "typeId"),
        message_code=_optional_int(data, "messageCode"),
        message=_optional_str(data, "message"),
        information=_optional_str(data, "information"),
    )


# Dispatch table mapping an event's "kind" to its parser.
_PARSERS: Final[dict[str, Callable[[dict[str, object]], TrnRunEvent]]] = {
    "STATUS": _parse_status,
    "PROGRESS": _parse_progress,
    "CONFIG": _parse_config,
    "LOG": _parse_log,
}


# ---------------------------------------------------------------------------
# PARSING
# ---------------------------------------------------------------------------
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

    Raises
    ------
    EventParseError
        If ``line`` is not valid JSON, the value is not a JSON object,
        the ``kind`` is unknown, or a field is missing or has the
        wrong type.
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

    Raises
    ------
    EventParseError
        If a line fails to parse and ``skip_invalid`` is false.
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
