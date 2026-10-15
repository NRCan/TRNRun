"""Windows Job Object support, so TRNSYS children never outlive us.

Provides `assign_to_job`, which places each freshly spawned trnrund into a
process-wide, kill-on-close Job Object. If this process is killed outright, an
orphaned `trnrund.exe` (and the `trnrun.exe` and `TrnEXE64.exe` it drives) can
keep running and hold a licence seat; `KILL_ON_JOB_CLOSE` makes Windows kill the
job's members, descendants included, once the last handle closes, which happens
automatically when we die. The package is Windows-only.
"""

import ctypes
import subprocess
from ctypes import wintypes
from threading import Lock
from typing import cast

# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
_JobObjectExtendedLimitInformation = 9
_JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000


# -----------------------------------------------------------------
# Structures
# -----------------------------------------------------------------
class _IO_COUNTERS(ctypes.Structure):  # noqa: N801 - Win32 name
    _fields_ = [  # noqa: RUF012 - ctypes layout
        ("ReadOperationCount", ctypes.c_ulonglong),
        ("WriteOperationCount", ctypes.c_ulonglong),
        ("OtherOperationCount", ctypes.c_ulonglong),
        ("ReadTransferCount", ctypes.c_ulonglong),
        ("WriteTransferCount", ctypes.c_ulonglong),
        ("OtherTransferCount", ctypes.c_ulonglong),
    ]


class _JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):  # noqa: N801 - Win32 name
    _fields_ = [  # noqa: RUF012 - ctypes layout
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


class _JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):  # noqa: N801 - Win32 name
    _fields_ = [  # noqa: RUF012 - ctypes layout
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
# Module State
# -----------------------------------------------------------------
_job_lock = Lock()
_job_handle: int | None = None
_job_failed = False


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


def _get_job() -> int | None:
    """Return the process-wide job handle, or `None` if it could not be created."""
    global _job_handle, _job_failed  # noqa: PLW0603 - one job per process

    with _job_lock:
        if _job_handle is not None or _job_failed:
            return _job_handle
        try:
            _job_handle = _create_job()
        except OSError:
            _job_failed = True  # TRNSYS processes may be orphaned if this process is killed.
        return _job_handle


# -----------------------------------------------------------------
# Job Assignment
# -----------------------------------------------------------------
def assign_to_job(process: subprocess.Popen[str]) -> bool:
    """Assign a freshly spawned process to the kill-on-close job.

    Best effort: a failure is reported through the return value, never raised, because losing orphan cleanup is not a reason to fail a
    simulation.

    Parameters
    ----------
    process : subprocess.Popen
        A freshly spawned child whose `_handle` is still valid.

    Returns
    -------
    bool
        `True` if the process was assigned to the job; `False` on any error.
    """
    job = _get_job()
    if job is None:
        return False

    try:
        handle = int(cast("int", process._handle))  # noqa: SLF001  # ty: ignore[unresolved-attribute]  # pyright: ignore[reportAttributeAccessIssue]
        if not _kernel32.AssignProcessToJobObject(job, handle):
            _raise_last_error("AssignProcessToJobObject")
    except (OSError, AttributeError, TypeError, ValueError):
        return False
    return True
