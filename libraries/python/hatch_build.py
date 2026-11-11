"""Hatch build hook: check the bundled executables and tag the wheel for its platform.

Every wheel bundles the same Windows executables. ``TRNRUN_WHEEL_PLATFORM`` picks
the tag: ``win_amd64`` (default), or ``manylinux_2_17_x86_64``, where the
package runs them through Wine.
"""

import os
import subprocess
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

PLATFORMS = ("win_amd64", "manylinux_2_17_x86_64")


class CustomBuildHook(BuildHookInterface):
    """Validate native executables included in the wheels."""

    def initialize(self, version: str, build_data: dict[str, object]) -> None:
        """Validate bundled executables and configure the wheel tag."""
        if version == "editable":
            return

        platform = os.environ.get("TRNRUN_WHEEL_PLATFORM", PLATFORMS[0])
        if platform not in PLATFORMS:
            message = f"TRNRUN_WHEEL_PLATFORM must be one of {', '.join(PLATFORMS)}, got {platform!r}"
            raise ValueError(message)

        bin_dir = Path(self.root) / "trnrun" / "bin"
        executables = [
            bin_dir / "trnrun.exe",
            bin_dir / "trnrund.exe",
        ]

        missing = [executable for executable in executables if not executable.is_file()]
        if missing:
            missing_names = ", ".join(executable.name for executable in missing)
            raise FileNotFoundError(
                f"Missing bundled executable(s): {missing_names}",
            )

        package_version = self.metadata.version

        # Runs the executables, so every wheel is built on Windows.
        for executable in executables:
            result = subprocess.run([executable, "--version"], check=True, capture_output=True, text=True, timeout=30)
            executable_version = result.stdout.strip()

            if executable_version != package_version:
                message = f"{executable.name} version {executable_version!r} does not match package version {package_version!r}"
                raise ValueError(message)

        build_data["pure_python"] = False
        build_data["tag"] = f"py3-none-{platform}"
