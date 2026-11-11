"""Hatch build hook: check the bundled executables and tag the wheel for its platforms.

The wheel bundles Windows executables, so it installs on x86-64 Windows and on
x86-64 Linux, where the package runs them through Wine. One wheel carries both
tags; any other platform refuses it rather than installing something that cannot run.
"""

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
        build_data["tag"] = f"py3-none-{'.'.join(PLATFORMS)}"
