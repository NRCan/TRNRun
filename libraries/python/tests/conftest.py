from __future__ import annotations

from pathlib import Path

import pytest

from trnrun.config import BUNDLED_TRNRUND_PATH

_TRNRUND_BUILD = Path(__file__).resolve().parents[3] / "components" / "trnrund" / "build"


@pytest.fixture
def fake_trnrun() -> Path:
    """Return trnrund's fake TRNRun, skipping unless it and the bundled daemon exist.

    Build it with `nimble test` in `components/trnrund`, and deploy the daemon
    with `just trnrund-deploy`.
    """
    candidates = (_TRNRUND_BUILD / "tests" / "fake_trnrun.exe", _TRNRUND_BUILD / "fake_trnrun.exe")
    fake = next((path for path in candidates if path.is_file()), None)
    if fake is None or not BUNDLED_TRNRUND_PATH.is_file():
        pytest.skip("needs the bundled trnrund.exe and trnrund's fake_trnrun.exe")
    return fake
