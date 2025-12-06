from __future__ import annotations

import json
from pathlib import Path

import pytest


def _load_ndjson_rows(path: Path) -> list[dict]:
    rows: list[dict] = []
    if not path.exists():
        return rows
    for line in path.read_text(encoding="ascii", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


def test_envsmoke_exe_fast_path_log_and_signal() -> None:
    ndjson_path = Path("tests/~test-results.ndjson")
    rows = _load_ndjson_rows(ndjson_path)
    fastpath_row = next((row for row in rows if row.get("id") == "self.env.fastpath.secondRun"), None)
    if fastpath_row is None:
        pytest.skip("envsmoke fast path row missing")

    log_path = Path("tests/~envsmoke/~envsmoke_bootstrap.log")
    if not log_path.exists():
        pytest.skip("envsmoke bootstrap log missing")

    text = log_path.read_text(encoding="ascii", errors="ignore")
    assert "Fast path: reusing dist\\_envsmoke.exe" in text
    assert text.count("PyInstaller produced dist\\_envsmoke.exe") == 1
    assert fastpath_row.get("pass") is True
