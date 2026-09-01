"""Ensure runtime dependencies exist (used by start.bat / cli entrypoint)."""

from __future__ import annotations

import importlib.util
import subprocess
import sys

REQUIRED = ["curl_cffi", "pyotp"]


def _missing() -> list[str]:
    gone = []
    for mod in REQUIRED:
        if importlib.util.find_spec(mod) is None:
            gone.append(mod)
    return gone


def ensure_deps() -> None:
    """Install missing runtime dependencies into the current interpreter."""
    gone = _missing()
    if not gone:
        return
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "-q", "-U", *gone],
    )
    still = _missing()
    if still:
        raise RuntimeError(f"failed to install dependencies: {still}")
