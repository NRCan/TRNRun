from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        exe = Path(self.root) / "trnrun" / "bin" / "trnrun.exe"
        if not exe.exists():
            raise FileNotFoundError(
                f"{exe} not found — run `nimble deploy` in runner/ before building",
            )
        build_data["pure_python"] = False
        build_data["tag"] = "py3-none-win_amd64"
