import hashlib
import json
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    """Require both native executables in Windows distributions."""

    def initialize(self, version: str, build_data: dict[str, object]) -> None:
        """Validate bundled executables and configure distributable wheels."""
        if version == "editable":
            return

        bin_dir = Path(self.root) / "trnrun" / "bin"
        executables = [bin_dir / "trnrun.exe", bin_dir / "trnrunq.exe"]
        manifest_path = bin_dir / "runtime-manifest.json"
        required = [*executables, manifest_path]
        missing = [artifact for artifact in required if not artifact.exists()]
        if missing:
            missing_names = ", ".join(artifact.name for artifact in missing)
            raise FileNotFoundError(
                f"Missing bundled runtime artifact(s): {missing_names}",
            )

        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
        package_version = self.metadata.version
        if manifest.get("version") != package_version:
            raise ValueError(
                f"Runtime version {manifest.get('version')!r} does not match package version {package_version!r}",
            )
        artifacts = manifest.get("artifacts")
        if not isinstance(artifacts, dict):
            raise TypeError("Runtime manifest is missing its artifacts object")
        for executable in executables:
            metadata = artifacts.get(executable.name)
            if not isinstance(metadata, dict) or not isinstance(metadata.get("sha256"), str):
                raise TypeError(f"Runtime manifest has no SHA-256 for {executable.name}")
            actual = hashlib.sha256(executable.read_bytes()).hexdigest()
            if actual != metadata["sha256"].lower():
                raise ValueError(f"Runtime checksum mismatch for {executable.name}")

        build_data["pure_python"] = False
        build_data["tag"] = "py3-none-win_amd64"
