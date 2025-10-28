"""Sanity checks for PowerShell colon formatting in the diagnostics poller."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


@pytest.mark.skipif(shutil.which("pwsh") is None, reason="PowerShell not available")
def test_poll_public_diag_handles_colon_logging(tmp_path: Path) -> None:
    """Invoke the poller once to ensure colon-adjacent logging stays parse-safe."""
    artifacts_root = REPO_ROOT / "_artifacts"
    existed_before = artifacts_root.exists()

    env = os.environ.copy()
    env["CI_DIAG_URL"] = "http://127.0.0.1:9"
    env["OUT_DIR"] = str(tmp_path / "inputs")
    env["MAX_ATTEMPTS"] = "1"
    env["BASE_DELAY_SEC"] = "0.1"
    env["GITHUB_ENV"] = str(tmp_path / "env.txt")

    proc = subprocess.run(
        ["pwsh", "-NoLogo", "-File", str(REPO_ROOT / "scripts" / "poll_public_diag.ps1")],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )

    assert proc.returncode == 0, proc.stderr
    assert "Attempt 1: failed to fetch diagnostics page" in proc.stdout
    assert (REPO_ROOT / "_artifacts" / "iterate" / "iterate_gate.json").exists()

    if not existed_before:
        shutil.rmtree(artifacts_root, ignore_errors=True)
