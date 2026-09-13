# ruff: noqa: S101, SLF001

from __future__ import annotations

import logging
import subprocess
from types import SimpleNamespace
from typing import cast
from unittest.mock import MagicMock, Mock

import pytest

from trnrun import job


@pytest.fixture(autouse=True)
def reset_job_state(monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep process-wide job state isolated between tests."""
    monkeypatch.setattr(job, "_job_handle", None)
    monkeypatch.setattr(job, "_job_failed", False)


def test_get_job_is_noop_off_windows(monkeypatch: pytest.MonkeyPatch) -> None:
    """A non-Windows caller should not try to create a Job Object."""
    create_job = Mock()
    monkeypatch.setattr(job, "IS_WINDOWS", False)
    monkeypatch.setattr(job, "_create_job", create_job, raising=False)

    assert job._get_job() is None
    create_job.assert_not_called()


def test_get_job_creates_and_caches_one_handle(monkeypatch: pytest.MonkeyPatch) -> None:
    """The first Windows call should create the process-wide job exactly once."""
    create_job = Mock(return_value=123)
    monkeypatch.setattr(job, "IS_WINDOWS", True)
    monkeypatch.setattr(job, "_create_job", create_job, raising=False)

    assert job._get_job() == 123
    assert job._get_job() == 123
    create_job.assert_called_once_with()


def test_get_job_does_not_retry_a_previous_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    """A failed creation should be cached to avoid repeated Win32 calls and logs."""
    create_job = Mock(side_effect=OSError("creation failed"))
    monkeypatch.setattr(job, "IS_WINDOWS", True)
    monkeypatch.setattr(job, "_create_job", create_job, raising=False)

    assert job._get_job() is None
    assert job._get_job() is None
    assert job._job_failed is True
    create_job.assert_called_once_with()


def test_get_job_logs_creation_failure(
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """Job creation errors should be reported without escaping to the caller."""
    monkeypatch.setattr(job, "IS_WINDOWS", True)
    monkeypatch.setattr(job, "_create_job", Mock(side_effect=OSError("denied")), raising=False)

    with caplog.at_level(logging.WARNING, logger=job.__name__):
        assert job._get_job() is None

    assert "could not create a Job Object" in caplog.text
    assert caplog.records[-1].exc_info is not None


def test_assign_to_job_returns_false_when_no_job(monkeypatch: pytest.MonkeyPatch) -> None:
    """Assignment should be a no-op when no process-wide job is available."""
    kernel32 = SimpleNamespace(AssignProcessToJobObject=Mock())
    monkeypatch.setattr(job, "_get_job", Mock(return_value=None))
    monkeypatch.setattr(job, "_kernel32", kernel32, raising=False)
    child = cast("subprocess.Popen[str]", cast("object", SimpleNamespace(pid=41, _handle=99)))

    assert job.assign_to_job(child) is False
    kernel32.AssignProcessToJobObject.assert_not_called()


def test_assign_to_job_uses_native_process_handle(monkeypatch: pytest.MonkeyPatch) -> None:
    """A valid child handle should be converted to an integer and assigned."""
    assign = Mock(return_value=True)
    monkeypatch.setattr(job, "_get_job", Mock(return_value=123))
    monkeypatch.setattr(job, "_kernel32", SimpleNamespace(AssignProcessToJobObject=assign), raising=False)
    child = cast("subprocess.Popen[str]", cast("object", SimpleNamespace(pid=41, _handle="99")))

    assert job.assign_to_job(child) is True
    assign.assert_called_once_with(123, 99)


def test_assign_to_job_handles_win32_failure(
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """A failed Win32 assignment should be logged and reported as best effort."""
    raise_last_error = Mock(side_effect=OSError("assignment failed"))
    monkeypatch.setattr(job, "_get_job", Mock(return_value=123))
    monkeypatch.setattr(
        job,
        "_kernel32",
        SimpleNamespace(AssignProcessToJobObject=Mock(return_value=False)),
        raising=False,
    )
    monkeypatch.setattr(job, "_raise_last_error", raise_last_error, raising=False)
    child = cast("subprocess.Popen[str]", cast("object", SimpleNamespace(pid=41, _handle=99)))

    with caplog.at_level(logging.WARNING, logger=job.__name__):
        assert job.assign_to_job(child) is False

    raise_last_error.assert_called_once_with("AssignProcessToJobObject")
    assert "could not assign pid 41" in caplog.text
    assert caplog.records[-1].exc_info is not None


@pytest.mark.parametrize(
    "process",
    [
        pytest.param(SimpleNamespace(pid=41), id="missing-handle"),
        pytest.param(SimpleNamespace(pid=41, _handle=None), id="non-integer-handle"),
        pytest.param(SimpleNamespace(pid=41, _handle="invalid"), id="invalid-handle"),
    ],
)
def test_assign_to_job_handles_unusable_process_handles(
    monkeypatch: pytest.MonkeyPatch,
    process: SimpleNamespace,
) -> None:
    """Missing or invalid private handles should not make assignment raise."""
    assign = Mock()
    monkeypatch.setattr(job, "_get_job", Mock(return_value=123))
    monkeypatch.setattr(job, "_kernel32", SimpleNamespace(AssignProcessToJobObject=assign), raising=False)
    child = cast("subprocess.Popen[str]", cast("object", process))

    assert job.assign_to_job(child) is False
    assign.assert_not_called()


@pytest.mark.skipif(not job.IS_WINDOWS, reason="Win32 bindings are only defined on Windows")
def test_raise_last_error_includes_call_and_win32_message(monkeypatch: pytest.MonkeyPatch) -> None:
    """The Win32 helper should preserve the error number and operation name."""
    monkeypatch.setattr(job.ctypes, "get_last_error", Mock(return_value=5))
    monkeypatch.setattr(job.ctypes, "FormatError", Mock(return_value="Access is denied."))

    with pytest.raises(OSError, match="CreateJobObjectW failed") as error:
        job._raise_last_error("CreateJobObjectW")

    assert error.value.errno == 5
    assert "CreateJobObjectW failed: Access is denied." in str(error.value)


@pytest.mark.skipif(not job.IS_WINDOWS, reason="Win32 bindings are only defined on Windows")
def test_create_job_enables_kill_on_close(monkeypatch: pytest.MonkeyPatch) -> None:
    """A newly created job should receive the kill-on-close limit flag."""
    kernel32 = MagicMock()
    kernel32.CreateJobObjectW.return_value = 123
    kernel32.SetInformationJobObject.return_value = True
    monkeypatch.setattr(job, "_kernel32", kernel32)

    assert job._create_job() == 123

    kernel32.CreateJobObjectW.assert_called_once_with(None, None)
    set_info_args = kernel32.SetInformationJobObject.call_args.args
    assert set_info_args[0] == 123
    assert set_info_args[1] == job._JobObjectExtendedLimitInformation
    assert set_info_args[2]._obj.BasicLimitInformation.LimitFlags == job._JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    assert set_info_args[3] == job.ctypes.sizeof(job._JOBOBJECT_EXTENDED_LIMIT_INFORMATION())
    kernel32.CloseHandle.assert_not_called()


@pytest.mark.skipif(not job.IS_WINDOWS, reason="Win32 bindings are only defined on Windows")
def test_create_job_reports_creation_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    """A null job handle should be converted to an OSError."""
    kernel32 = MagicMock()
    kernel32.CreateJobObjectW.return_value = 0
    raise_last_error = Mock(side_effect=OSError("creation failed"))
    monkeypatch.setattr(job, "_kernel32", kernel32)
    monkeypatch.setattr(job, "_raise_last_error", raise_last_error)

    with pytest.raises(OSError, match="creation failed"):
        job._create_job()

    raise_last_error.assert_called_once_with("CreateJobObjectW")
    kernel32.SetInformationJobObject.assert_not_called()


@pytest.mark.skipif(not job.IS_WINDOWS, reason="Win32 bindings are only defined on Windows")
def test_create_job_closes_handle_when_configuration_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    """A partially created job should not leak its handle if setup fails."""
    kernel32 = MagicMock()
    kernel32.CreateJobObjectW.return_value = 123
    kernel32.SetInformationJobObject.return_value = False
    raise_last_error = Mock(side_effect=OSError("configuration failed"))
    monkeypatch.setattr(job, "_kernel32", kernel32)
    monkeypatch.setattr(job, "_raise_last_error", raise_last_error)

    with pytest.raises(OSError, match="configuration failed"):
        job._create_job()

    kernel32.CloseHandle.assert_called_once_with(123)
    raise_last_error.assert_called_once_with("SetInformationJobObject")
