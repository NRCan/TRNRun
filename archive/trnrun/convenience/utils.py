"""Small utility helpers."""

from rich.segment import Segment


def format_hhmmss(seconds: float | None) -> str:
    """Convert seconds to HH:MM:SS string. Returns '--:--:--' if None."""
    if seconds is None:
        return "--:--:--"
    # A negative ETA is clamped: floor division would render it as "-1:59:55".
    h, rem = divmod(max(int(seconds), 0), 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def truncate_left(text: str, width: int) -> str:
    """Pad or left-truncate to width terminal cells; return empty for width <= 0.

    Rich replaces a partially cut wide character with a space.
    """
    if width <= 0:
        return ""
    segment = Segment(text)
    length = segment.cell_length
    if length <= width:
        return text + " " * (width - length)
    return "…" + segment.split_cells(length - width + 1)[1].text
