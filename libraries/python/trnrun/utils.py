"""Small utility helpers."""


def format_hhmmss(seconds: float | None) -> str:
    """Convert seconds to HH:MM:SS string. Returns '--:--:--' if None."""
    if seconds is None:
        return "--:--:--"
    # A negative ETA is clamped: floor division would render it as "-1:59:55".
    h, rem = divmod(max(int(seconds), 0), 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def truncate_left(text: str, width: int) -> str:
    """Left-truncate text with an ellipsis to fit a fixed width."""
    if width <= 1:
        return "…"
    if len(text) <= width:
        return f"{text:<{width}}"
    return f"…{text[-(width - 1) :]:<{width - 1}}"
