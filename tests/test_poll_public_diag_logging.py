"""Sanity checks for PowerShell colon formatting in the diagnostics poller."""

from __future__ import annotations

import json
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


@pytest.mark.skipif(shutil.which("pwsh") is None, reason="PowerShell not available")
def test_poll_public_diag_default_budget(tmp_path: Path) -> None:
    """Default polling still fails open quickly when diagnostics never materialize."""

    artifacts_root = REPO_ROOT / "_artifacts"
    existed_before = artifacts_root.exists()

    env = os.environ.copy()
    env["CI_DIAG_URL"] = "http://127.0.0.1:9"
    env["OUT_DIR"] = str(tmp_path / "inputs")
    env["GITHUB_ENV"] = str(tmp_path / "env.txt")
    env.pop("MAX_ATTEMPTS", None)
    env.pop("BASE_DELAY_SEC", None)

    proc = subprocess.run(
        ["pwsh", "-NoLogo", "-File", str(REPO_ROOT / "scripts" / "poll_public_diag.ps1")],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )

    assert proc.returncode == 0, proc.stderr
    assert "Missing inputs:" in proc.stdout

    gate_path = artifacts_root / "iterate" / "iterate_gate.json"
    assert gate_path.exists()

    gate = json.loads(gate_path.read_text(encoding="utf-8"))
    assert gate["proceed"] is True
    assert gate["note"] == "fail-open via public diagnostics poller"
    assert gate["found_inputs"] == {"ci": None, "tests": None}
    assert set(gate["missing_inputs"]) == {
        "ci_test_results.ndjson",
        "tests~test-results.ndjson",
    }

    env_path = Path(env["GITHUB_ENV"])
    env_entries = dict(
        line.split("=", 1) for line in env_path.read_text(encoding="utf-8").splitlines()
    )
    assert env_entries.get("GATE_NDJSON_FOUND") == "false"

    if not existed_before:
        shutil.rmtree(artifacts_root, ignore_errors=True)
