"""Tests for ``trnrun.job``: the kill-on-close Windows Job Object."""

import ctypes
import subprocess
from collections.abc import Iterator
from ctypes import wintypes
from typing import cast

import pytest

from tests.helpers import PYTHON
from trnrun import job

_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
_kernel32.IsProcessInJob.argtypes = [wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)]
_kernel32.IsProcessInJob.restype = wintypes.BOOL


def _handle(process: subprocess.Popen[str]) -> int:
    """Return the Win32 handle of ``process``."""
    return int(cast("int", process._handle))  # ty: ignore[unresolved-attribute]  # pyright: ignore[reportAttributeAccessIssue]


def _in_job(process: subprocess.Popen[str], job_handle: int) -> bool:
    """Return whether ``process`` belongs to the job ``job_handle``."""
    result = wintypes.BOOL()
    assert _kernel32.IsProcessInJob(_handle(process), job_handle, ctypes.byref(result))
    return bool(result.value)


class _Kernel32:
    """kernel32 with a replaced AssignProcessToJobObject."""

    def __init__(self, kernel32: object, assign: object) -> None:
        """Wrap ``kernel32``, replacing only the assignment."""
        self._kernel32: object = kernel32
        self.AssignProcessToJobObject: object = assign

    def __getattr__(self, name: str) -> object:
        """Forward every other function to the wrapped kernel32."""
        return getattr(self._kernel32, name)


@pytest.fixture
def sleeper() -> Iterator[subprocess.Popen[str]]:
    """Start a child that runs until it is killed."""
    process = subprocess.Popen([PYTHON, "-c", "import time; time.sleep(60)"], text=True)
    yield process
    process.kill()
    _ = process.wait()


@pytest.fixture
def fresh_job(monkeypatch: pytest.MonkeyPatch) -> None:
    """Forget the process-wide job, so the test creates its own; restored afterwards."""
    monkeypatch.setattr(job, "_job_handle", None)
    monkeypatch.setattr(job, "_job_failed", False)


def test_assign_to_job_adds_the_process_to_the_shared_job(sleeper: subprocess.Popen[str]) -> None:
    """Put a spawned child in the process-wide job."""
    assert job.assign_to_job(sleeper)

    job_handle = job._get_job()
    assert job_handle is not None
    assert _in_job(sleeper, job_handle)


def test_get_job_creates_one_job_per_process() -> None:
    """Reuse the same job for every child."""
    assert job._get_job() == job._get_job()


def test_closing_the_job_kills_its_members(sleeper: subprocess.Popen[str]) -> None:
    """Kill every member once the last job handle closes, as when this process dies."""
    job_handle = job._create_job()
    try:
        assert job._kernel32.AssignProcessToJobObject(job_handle, _handle(sleeper))
    finally:
        assert job._kernel32.CloseHandle(job_handle)

    _ = sleeper.wait(timeout=10)


@pytest.mark.usefixtures("fresh_job")
def test_job_creation_failure_is_tried_once_and_never_raised(
    monkeypatch: pytest.MonkeyPatch,
    sleeper: subprocess.Popen[str],
) -> None:
    """Run without orphan cleanup when no job can be created, and do not retry."""
    calls: list[None] = []

    def fail() -> int:
        """Fail like CreateJobObjectW."""
        calls.append(None)
        raise OSError(5, "Access is denied")

    monkeypatch.setattr(job, "_create_job", fail)

    assert job.assign_to_job(sleeper) is False
    assert job.assign_to_job(sleeper) is False

    assert len(calls) == 1


def test_assign_failure_is_never_raised() -> None:
    """Report a process without a usable handle through the return value."""

    class NoHandle:
        """A process-like object without the ``_handle`` Popen keeps."""

        pid: int = 1234

    assert job.assign_to_job(cast("subprocess.Popen[str]", NoHandle())) is False


def test_assign_failure_from_windows_is_never_raised(
    monkeypatch: pytest.MonkeyPatch,
    sleeper: subprocess.Popen[str],
) -> None:
    """Report a failed AssignProcessToJobObject through the return value."""

    def refuse(_job: int, _process: int) -> bool:
        """Fail like AssignProcessToJobObject with ERROR_ACCESS_DENIED."""
        ctypes.set_last_error(5)
        return False

    monkeypatch.setattr(job, "_kernel32", _Kernel32(job._kernel32, refuse))

    assert job.assign_to_job(sleeper) is False


def test_raise_last_error_names_the_call() -> None:
    """Tag the Win32 error with the failing call."""
    ctypes.set_last_error(5)

    with pytest.raises(OSError, match="SomeCall failed") as raised:
        job._raise_last_error("SomeCall")

    assert raised.value.errno == 5
