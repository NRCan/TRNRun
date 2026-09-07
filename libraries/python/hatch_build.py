from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    """Require both native executables in Windows distributions."""

    def initialize(self, _version: str, build_data: dict[str, object]) -> None:
        """Validate bundled executables and configure the wheel tag."""
        bin_dir = Path(self.root) / "trnrun" / "bin"
        executables = [bin_dir / "trnrun.exe", bin_dir / "trnrunq.exe"]
        missing = [executable for executable in executables if not executable.exists()]
        if missing:
            missing_names = ", ".join(executable.name for executable in missing)
            raise FileNotFoundError(
                f"Missing bundled executable(s): {missing_names}",
            )
        build_data["pure_python"] = False
        build_data["tag"] = "py3-none-win_amd64"
