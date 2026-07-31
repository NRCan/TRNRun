"""Windows Job Object support, so TRNSYS children never outlive us.

Provides `assign_to_job`, which places each freshly spawned TRNRun child into a
process-wide, kill-on-close Job Object. If this process is killed outright, an
orphaned `trnrun.exe` (and the `TrnEXE64.exe` it drives) keeps running and holds
a licence seat; `KILL_ON_JOB_CLOSE` makes Windows kill the job's members once
the last handle closes, which happens automatically when we die. On non-Windows
platforms it is a no-op, so callers never need to branch.
"""

from __future__ import annotations

import ctypes
import logging
import subprocess
import sys
from threading import Lock
from typing import cast

logger = logging.getLogger(__name__)


# -----------------------------------------------------------------
# Module State
# -----------------------------------------------------------------
IS_WINDOWS = sys.platform == "win32"

_job_lock = Lock()
_job_handle: int | None = None
_job_failed = False


# -----------------------------------------------------------------
# Windows Job Object
# -----------------------------------------------------------------
if IS_WINDOWS:
    from ctypes import wintypes

    # -----------------------------------------------------------------
    # Constants
    # -----------------------------------------------------------------
    _JobObjectExtendedLimitInformation = 9
    _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000

    # -----------------------------------------------------------------
    # Structures
    # -----------------------------------------------------------------
    class _IO_COUNTERS(ctypes.Structure):
        _fields_ = [
            ("ReadOperationCount", ctypes.c_ulonglong),
            ("WriteOperationCount", ctypes.c_ulonglong),
            ("OtherOperationCount", ctypes.c_ulonglong),
            ("ReadTransferCount", ctypes.c_ulonglong),
            ("WriteTransferCount", ctypes.c_ulonglong),
            ("OtherTransferCount", ctypes.c_ulonglong),
        ]

    class _JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", wintypes.LARGE_INTEGER),
            ("PerJobUserTimeLimit", wintypes.LARGE_INTEGER),
            ("LimitFlags", wintypes.DWORD),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", wintypes.DWORD),
            ("Affinity", ctypes.c_size_t),  # ULONG_PTR
            ("PriorityClass", wintypes.DWORD),
            ("SchedulingClass", wintypes.DWORD),
        ]

    class _JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
        _fields_ = [
            ("BasicLimitInformation", _JOBOBJECT_BASIC_LIMIT_INFORMATION),
            ("IoInfo", _IO_COUNTERS),
            ("ProcessMemoryLimit", ctypes.c_size_t),
            ("JobMemoryLimit", ctypes.c_size_t),
            ("PeakProcessMemoryUsed", ctypes.c_size_t),
            ("PeakJobMemoryUsed", ctypes.c_size_t),
        ]

    # -----------------------------------------------------------------
    # kernel32 Bindings
    # -----------------------------------------------------------------
    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    _kernel32.CreateJobObjectW.argtypes = [wintypes.LPVOID, wintypes.LPCWSTR]
    _kernel32.CreateJobObjectW.restype = wintypes.HANDLE

    _kernel32.SetInformationJobObject.argtypes = [
        wintypes.HANDLE,
        ctypes.c_int,
        wintypes.LPVOID,
        wintypes.DWORD,
    ]
    _kernel32.SetInformationJobObject.restype = wintypes.BOOL

    _kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    _kernel32.AssignProcessToJobObject.restype = wintypes.BOOL

    _kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    _kernel32.CloseHandle.restype = wintypes.BOOL

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------
    def _raise_last_error(call: str) -> None:
        """Raise `OSError` for the thread's last Win32 error, tagged with `call`."""
        err = ctypes.get_last_error()
        raise OSError(err, f"{call} failed: {ctypes.FormatError(err)}")

    def _create_job() -> int:
        """Create an unnamed job that kills its members when closed."""
        handle = _kernel32.CreateJobObjectW(None, None)
        if not handle:
            _raise_last_error("CreateJobObjectW")

        info = _JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        info.BasicLimitInformation.LimitFlags = _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE

        ok = _kernel32.SetInformationJobObject(
            handle,
            _JobObjectExtendedLimitInformation,
            ctypes.byref(info),
            ctypes.sizeof(info),
        )
        if not ok:
            _kernel32.CloseHandle(handle)
            _raise_last_error("SetInformationJobObject")

        return int(handle)


# -----------------------------------------------------------------
# Job Assignment
# -----------------------------------------------------------------
def _get_job() -> int | None:
    """Return the process-wide job handle, or `None` off Windows or on creation failure."""
    global _job_handle, _job_failed

    if not IS_WINDOWS:
        return None

    with _job_lock:
        if _job_handle is not None or _job_failed:
            return _job_handle
        try:
            _job_handle = _create_job()
        except OSError:
            _job_failed = True
            logger.warning(
                "could not create a Job Object; TRNSYS processes may be orphaned if this process is killed",
                exc_info=True,
            )
        return _job_handle


def assign_to_job(process: subprocess.Popen[str]) -> bool:
    """Assign a freshly spawned process to the kill-on-close job.

    Best effort: a failure is logged and reported through the return value,
    never raised, because losing orphan cleanup is not a reason to fail a
    simulation.

    Parameters
    ----------
    process : subprocess.Popen
        A freshly spawned child whose `_handle` is still valid.

    Returns
    -------
    bool
        `True` if the process was assigned to the job; `False` on any
        platform or error where it was not.
    """
    job = _get_job()
    if job is None:
        return False

    try:
        handle = int(cast("int", process._handle))  # ty: ignore[unresolved-attribute]  # pyright: ignore[reportAttributeAccessIssue]
        if not _kernel32.AssignProcessToJobObject(job, handle):
            _raise_last_error("AssignProcessToJobObject")
    except (OSError, AttributeError, TypeError, ValueError):
        logger.warning(
            "could not assign pid %s to the Job Object; it may be orphaned",
            process.pid,
            exc_info=True,
        )
        return False
    return True
