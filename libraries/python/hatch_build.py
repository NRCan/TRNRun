import subprocess
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    """Validate native executables included in Windows wheels."""

    def initialize(self, version: str, build_data: dict[str, object]) -> None:
        """Validate bundled executables and configure the wheel tag."""
        if version == "editable":
            return

        bin_dir = Path(self.root) / "trnrun" / "bin"
        executables = [
            bin_dir / "trnrun.exe",
            bin_dir / "trnrunq.exe",
        ]

        missing = [executable for executable in executables if not executable.is_file()]
        if missing:
            missing_names = ", ".join(executable.name for executable in missing)
            raise FileNotFoundError(
                f"Missing bundled executable(s): {missing_names}",
            )

        package_version = self.metadata.version

        for executable in executables:
            result = subprocess.run([executable, "--version"], check=True, capture_output=True, text=True)
            executable_version = result.stdout.strip()

            if executable_version != package_version:
                raise ValueError(
                    f"{executable.name} version ",
                    f"{executable_version!r} does not match package ",
                    f"version {package_version!r}",
                )

        build_data["pure_python"] = False
        build_data["tag"] = "py3-none-win_amd64"
