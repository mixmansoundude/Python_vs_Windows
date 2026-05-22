"""Warn if PowerShell strings risk scoped-variable colon parsing."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


@pytest.mark.skipif(
    shutil.which("bash") is None or sys.platform == "win32",
    reason="bash not available or Git Bash login-shell unreliable on Windows CI",
)
@pytest.mark.parametrize("glob", ["scripts", "tools"])
def test_powershell_colon_scan_warn_only(glob: str) -> None:
    cmd = [
        "bash",
        "-lc",
        (
            "egrep -R '\\$[A-Za-z_][A-Za-z0-9_]*:' "
            f"{glob} | grep -Ev '\\$(script|global|local|private|env|using):' || true"
        ),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO_ROOT)
    assert result.returncode == 0
    if result.stdout.strip():
        print("[colon-scan] Potential colon-adjacent variables:\n" + result.stdout)
