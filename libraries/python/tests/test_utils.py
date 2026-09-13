# ruff: noqa: D103, S101

import pytest

from trnrun.utils import format_hhmmss, truncate_left


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [
        (None, "--:--:--"),
        (0, "00:00:00"),
        (59.9, "00:00:59"),
        (60, "00:01:00"),
        (3661.9, "01:01:01"),
        (360_000, "100:00:00"),
        (-0.5, "00:00:00"),
        (-5, "00:00:00"),
    ],
)
def test_format_hhmmss(seconds: float | None, expected: str) -> None:
    assert format_hhmmss(seconds) == expected


@pytest.mark.parametrize(
    ("text", "width", "expected"),
    [
        ("abc", -1, ""),
        ("abc", 0, ""),
        ("", 3, "   "),
        ("abc", 3, "abc"),
        ("abc", 5, "abc  "),
        ("abcdef", 4, "…def"),
        ("abcdef", 1, "…"),
        ("ab界", 3, "…界"),
        ("ab界", 2, "… "),
        ("界ab", 3, "…ab"),
    ],
)
def test_truncate_left(text: str, width: int, expected: str) -> None:
    assert truncate_left(text, width) == expected
