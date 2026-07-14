"""Configuration for launching a TRNRun process and converting
configuration values into trnrun.exe CLI arguments.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path


class LogSeverity(str, Enum):
    NOTICE = "Notice"
    WARNING = "Warning"
    FATAL = "Fatal"


def _app_dir() -> Path:
    """Directory containing the running application."""
    return Path(sys.argv[0]).resolve().parent

# Change path using app dir later
def _default_trnrun_path() -> Path:
    return Path(r"C:\Users\alexl\Documents\Project\TRNRun\runner\build\trnrun.exe")


@dataclass
class TRNRunConfig:
    """Configuration used to launch TRNRun."""

    trnrun_path: Path = field(default_factory=_default_trnrun_path)
    trnexe_path: Path = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")

    gui_visibility: str = "hidden"

    wait_for_gui: bool = True
    wait_for_lst: bool = True
    wait_for_tmp: bool = False

    detect_timeout_ms: int = 120_000
    extra_delay_ms: int = 0
    poll_ms: int = 100

    watch_log: bool = True
    watch_tmp: bool = True

    watch_timeout_ms: int = 120_000
    stall_timeout_ms: int = 60_000

    clean_on_success: bool = True

    kill_on_timeout: bool = True
    kill_on_stall: bool = True

    severity: LogSeverity = LogSeverity.NOTICE
    write_log: bool = True

    def to_cli_args(self) -> list[str]:
        """Convert configuration into trnrun.exe command-line arguments."""

        def boolean(value: bool) -> str:
            return "true" if value else "false"

        return [
            f"--trnexePath:{self.trnexe_path}",
            f"--guiVisibility:{self.gui_visibility}",
            f"--waitForGui:{boolean(self.wait_for_gui)}",
            f"--waitForLst:{boolean(self.wait_for_lst)}",
            f"--waitForTmp:{boolean(self.wait_for_tmp)}",
            f"--detectTimeout:{self.detect_timeout_ms}",
            f"--extraDelay:{self.extra_delay_ms}",
            f"--pollMs:{self.poll_ms}",
            f"--watchLog:{boolean(self.watch_log)}",
            f"--watchTmp:{boolean(self.watch_tmp)}",
            f"--watchTimeout:{self.watch_timeout_ms}",
            f"--stallTimeout:{self.stall_timeout_ms}",
            f"--clean:{boolean(self.clean_on_success)}",
            f"--killOnTimeout:{boolean(self.kill_on_timeout)}",
            f"--killOnStall:{boolean(self.kill_on_stall)}",
            f"--severity:{self.severity.value}",
            f"--writeLog:{boolean(self.write_log)}",
        ]


def default_trnrun_config() -> TRNRunConfig:
    return TRNRunConfig()
