"""tools/req_coverage.py: the per-requirement pass/fail map that the diagnostics site shows (req_coverage.json).

A row's `req` field is the literal tag from the test script. A row that proves several shalls lists them with commas
(`REQ-009, REQ-018.27`); the map must credit each one, or the page would show the whole list as one odd key and the
single requirement as missing. The cases below fail on the old code, which used the whole string as the key.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

import req_coverage as rc  # noqa: E402


def _write(folder: Path, name: str, *rows) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / name).write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")


def test_a_row_counts_for_its_own_requirement(tmp_path: Path) -> None:
    _write(tmp_path, "a.ndjson", {"id": "a", "req": "REQ-001", "pass": True}, {"id": "b", "req": "REQ-002", "pass": False})
    assert rc.compute_coverage(tmp_path) == {"REQ-001": "pass", "REQ-002": "fail"}


def test_one_failing_row_fails_the_requirement_and_rows_without_a_tag_are_ignored(tmp_path: Path) -> None:
    _write(tmp_path, "a.ndjson", {"req": "REQ-001", "pass": True}, {"req": "REQ-001", "pass": False}, {"id": "x", "pass": False})
    assert rc.compute_coverage(tmp_path) == {"REQ-001": "fail"}


def test_a_comma_list_credits_every_requirement_it_names(tmp_path: Path) -> None:
    _write(
        tmp_path,
        "a.ndjson",
        {"id": "a", "req": "REQ-009, REQ-018.27", "pass": False},
        {"id": "b", "req": "REQ-018.27,REQ-018.28", "pass": True},
    )
    assert rc.compute_coverage(tmp_path) == {"REQ-009": "fail", "REQ-018.27": "fail", "REQ-018.28": "pass"}


def test_stray_commas_add_no_empty_key_and_folders_and_bad_lines_are_walked(tmp_path: Path) -> None:
    _write(tmp_path / "lane" / "deep", "b.ndjson", {"req": "REQ-005.1.3,", "pass": True})
    (tmp_path / "bad.ndjson").write_text("not json\n\n{\"req\": \"REQ-001\", \"pass\": true}\n", encoding="utf-8")
    assert rc.compute_coverage(tmp_path) == {"REQ-001": "pass", "REQ-005.1.3": "pass"}
