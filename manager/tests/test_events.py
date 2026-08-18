# ruff: noqa: S101

from __future__ import annotations

import json

from trnrun.events import LogEvent, parse_event


def test_parse_log_uses_canonical_id_keys() -> None:
    """Canonical Nim wire keys retain unit and type identifiers."""
    line = json.dumps(
        {
            "kind": "LOG",
            "timestamp": "2026-08-18T14:23:51",
            "severity": "Warning",
            "time": 10.0,
            "unitID": 5,
            "typeID": 139,
        },
    )

    event = parse_event(line)

    assert isinstance(event, LogEvent)
    assert event.unit_id == 5
    assert event.type_id == 139


def test_parse_log_accepts_legacy_id_key_aliases() -> None:
    """Previously accepted lower-camel ID keys remain compatible."""
    line = json.dumps(
        {
            "kind": "LOG",
            "timestamp": "2026-08-18T14:23:51",
            "severity": "Warning",
            "time": 10.0,
            "unitId": 5,
            "typeId": 139,
        },
    )

    event = parse_event(line)

    assert isinstance(event, LogEvent)
    assert event.unit_id == 5
    assert event.type_id == 139
