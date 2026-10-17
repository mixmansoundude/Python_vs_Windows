"""Item 78 slice 1 follow-up: the elevation test must not take the program's redirected stdin.

`:detect_elevation` starts `fsutil dirty query` at the top of every run. A child process shares the
bootstrapper's stdin, and with that call added (and no other difference from a passing run) the uv
lane's interactive round-trip (`self.interactive.stdin.roundtrip`) ended with the built EXE at
end-of-file on its first input(). The behavior is proven by that row; this is the static guard that
keeps the NUL redirect from being dropped. It scans run_setup.bat text only.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _batch_lines() -> list[str]:
    text = (REPO_ROOT / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
    return [ln.strip() for ln in text.splitlines()]


def _live_fsutil_lines() -> list[str]:
    return [ln for ln in _batch_lines() if re.match(r"fsutil\b", ln, re.IGNORECASE)]


def test_the_bootstrapper_starts_fsutil_only_in_detect_elevation():
    assert len(_live_fsutil_lines()) == 1, _live_fsutil_lines()


def test_fsutil_gets_nul_for_stdin():
    for ln in _live_fsutil_lines():
        assert "<nul" in ln.replace(" ", "").lower(), "fsutil must run with <nul: %r" % ln


def test_the_elevation_test_lives_in_one_subroutine():
    # Both the per-run log line and the Miniconda AllUsers branch call it, so there is one test to guard.
    lines = _batch_lines()
    start = lines.index(":detect_elevation")
    end = next(i for i in range(start + 1, len(lines)) if lines[i].lower().startswith("exit /b") and i > start + 3)
    body = lines[start:end + 1]
    assert any(re.match(r"fsutil\b", ln, re.IGNORECASE) for ln in body)
