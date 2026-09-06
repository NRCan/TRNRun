from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        bin_dir = Path(self.root) / "trnrun" / "bin"
        executables = [bin_dir / "trnrun.exe", bin_dir / "trnrunq.exe"]
        missing = [exe for exe in executables if not exe.exists()]
        if missing:
            missing_names = ", ".join(exe.name for exe in missing)
            raise FileNotFoundError(
                f"Missing bundled executable(s): {missing_names}",
            )
        build_data["pure_python"] = False
        build_data["tag"] = "py3-none-win_amd64"
