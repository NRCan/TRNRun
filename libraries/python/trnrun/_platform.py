r"""Where Windows and other platforms differ: how the bundled executables run, and their paths.

Windows runs the bundled executables directly; elsewhere they run through Wine.
``launch`` starts one either way. Under Wine, trnrund, TRNRun and TRNSYS all
run inside one prefix, so only Python sees Linux paths: ``to_trnrund`` converts
paths on their way to trnrund, and ``from_trnrund`` converts them back. On
Windows they change nothing but make the first absolute.

Environment variables: ``TRNRUN_WINE`` names the Wine command (default
``wine``), ``WINEPREFIX`` the prefix (default ``~/.wine``).
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any

ON_WINDOWS = sys.platform == "win32"
_WINDOWS_PATH = re.compile(r"^[A-Za-z]:[\\/]")
# -nolisten unix: abstract socket only, since /tmp/.X11-unix may not be writable, as under WSLg;
# Xvfb would then reject every display. X clients on Linux try the abstract socket first.
_XVFB_OPTIONS = ("-nolisten", "tcp", "-nolisten", "unix", "-screen", "0", "1280x1024x24")


def in_prefix(path: str | Path) -> bool:
    r"""Tell whether ``path`` is, off Windows, already in Windows form, such as ``C:\TRNSYS18``.

    Such a path names a file in the Wine prefix, where Wine ignores case, so
    Python cannot tell whether it exists.
    """
    return not ON_WINDOWS and _WINDOWS_PATH.match(os.fspath(path)) is not None


def to_trnrund(path: str | Path) -> str:
    r"""Return ``path`` absolute, as trnrund needs it.

    On Windows, the absolute path. Elsewhere, the path Wine sees: ``/a/b`` is
    ``Z:\a\b``, since Wine maps ``Z:`` to ``/``; a path already in Windows form,
    such as ``C:\TRNSYS18\Exe\TrnEXE64.exe``, is returned unchanged.
    """
    if in_prefix(path):
        return os.fspath(path)
    absolute = str(Path(path).absolute())
    return absolute if ON_WINDOWS else "Z:" + absolute.replace("/", "\\")


def from_trnrund(path: str) -> Path:
    r"""Return an absolute path trnrund sent as a local one.

    Unchanged on Windows. Elsewhere, ``Z:\a\b`` is ``/a/b``, and another drive
    is in the prefix: ``C:\TRNSYS18`` is ``$WINEPREFIX/dosdevices/c:/TRNSYS18``.
    """
    if ON_WINDOWS:
        return Path(path)
    windows = PureWindowsPath(path)
    if windows.drive.upper() == "Z:":
        root = PurePosixPath("/")
    else:
        prefix = os.environ.get("WINEPREFIX") or Path.home() / ".wine"
        root = PurePosixPath(prefix, "dosdevices", windows.drive.lower())
    return Path(root.joinpath(*windows.parts[1:]))  # parts[0] is the drive and root, such as "Z:\\".


def wine_command() -> str:
    """Return the Wine executable: ``$TRNRUN_WINE``, else ``wine`` from PATH.

    Raises
    ------
    FileNotFoundError
        If neither is found.
    """
    wine = shutil.which(os.environ.get("TRNRUN_WINE", "wine"))
    if wine is None:
        msg = "Wine not found: trnrun needs Wine off Windows; install it, or set TRNRUN_WINE to its path"
        raise FileNotFoundError(msg)
    return wine


def wine_env() -> dict[str, str]:
    """Return this process's environment, with Wine made quiet.

    ``WINEDEBUG=-all`` matters: Wine's messages, such as a TRNSYS DLL that fails
    to load, would otherwise land in TRNRun's event stream.
    """
    env = dict(os.environ)
    env["WINEDEBUG"] = "-all"
    _ = env.setdefault("WINEDLLOVERRIDES", "mscoree,mshtml=")  # No Mono or Gecko install dialog.
    return env


def launch(args: list[str], **options: Any) -> tuple[subprocess.Popen[str], subprocess.Popen[bytes] | None]:
    """Start the bundled Windows executable ``args[0]``: directly on Windows, through Wine elsewhere.

    On Windows, it runs without a console window. Elsewhere, Wine needs an X
    display even for hidden windows: without one, TRNSYS quits at once and
    TRNRun reports it DONE. When the ``DISPLAY`` environment variable is unset,
    so there is no X display, a private Xvfb is started for the process.

    Parameters
    ----------
    args : list of str
        Executable, as a local path, and its arguments.
    **options
        ``subprocess.Popen`` options, in text mode.

    Returns
    -------
    tuple
        The process, and the private Xvfb, or None on Windows or when an X
        display was set. The caller stops the Xvfb once the process has exited.

    Raises
    ------
    FileNotFoundError
        If the executable, or off Windows, Wine or Xvfb when needed, is missing.
    """
    if not Path(args[0]).is_file():  # Wine itself would start, and only print an error.
        msg = f"Executable not found: {args[0]}"
        raise FileNotFoundError(msg)
    if ON_WINDOWS:
        return subprocess.Popen(args, creationflags=subprocess.CREATE_NO_WINDOW, **options), None
    command = [wine_command(), *args]
    env = wine_env()
    xvfb = None
    if not env.get("DISPLAY"):
        xvfb, env["DISPLAY"] = _start_xvfb()
    try:
        return subprocess.Popen(command, env=env, **options), xvfb
    except BaseException:
        if xvfb is not None:  # Nobody else holds it yet to stop it.
            xvfb.terminate()
            _ = xvfb.wait()
        raise


def _start_xvfb() -> tuple[subprocess.Popen[bytes], str]:
    """Start Xvfb on a free display number; return it and its ``DISPLAY`` value, such as ``:99``.

    Raises
    ------
    FileNotFoundError
        If Xvfb is not installed.
    OSError
        If Xvfb exits without reporting a display.
    """
    xvfb = shutil.which("Xvfb")
    if xvfb is None:
        msg = "No X display for Wine: the DISPLAY environment variable is unset and Xvfb is not installed; install Xvfb (apt install xvfb)"
        raise FileNotFoundError(msg)
    read_fd, write_fd = os.pipe()
    try:
        # -displayfd: Xvfb picks a free display and writes its number once it accepts clients.
        process = subprocess.Popen(
            [xvfb, "-displayfd", str(write_fd), *_XVFB_OPTIONS],
            pass_fds=(write_fd,),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    finally:
        os.close(write_fd)
    with os.fdopen(read_fd) as reader:
        number = reader.readline().strip()  # Empty once Xvfb exits, since it held the only write end.
    if not number:
        _ = process.wait()
        msg = f"Xvfb exited with code {process.returncode} before reporting a display"
        raise OSError(msg)
    return process, f":{number}"
