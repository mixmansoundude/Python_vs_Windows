"""Item 76: the dependency-source record is a bootstrapper-internal file, so its name takes a tilde.

README REQ-015 says the bootstrapper's own working files take a tilde so the standard ignores
(`~*`) keep them out of the user's git history. `dependency_source.txt` was the one non-tilde file
the bootstrapper wrote into the user's folder. The rename is only safe if the writer and every CI
step that collects the file move together, otherwise the diagnostics bundle silently loses it.
These checks are static text scans of run_setup.bat and batch-check.yml.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OLD = "dependency_source.txt"
NEW = "~dependency_source.txt"


def _text(rel: str) -> str:
    return (REPO_ROOT / rel).read_text(encoding="utf-8", errors="replace")


def _bare_mentions(text: str) -> int:
    """Count mentions of the old name that are not already the tilde name."""
    return len(re.findall(r"(?<!~)\bdependency_source\.txt", text))


def test_batch_writes_the_tilde_name():
    bat = _text("run_setup.bat")
    writers = re.findall(r'echo dependency_source=%DEP_SOURCE%>\s*"([^"]+)"', bat)
    assert writers == [NEW], "the :success writer must create %s, found %r" % (NEW, writers)


def test_batch_never_mentions_the_old_name():
    assert _bare_mentions(_text("run_setup.bat")) == 0


def test_ci_collects_the_tilde_name_everywhere_it_collected_the_old_one():
    yml = _text(".github/workflows/batch-check.yml")
    assert _bare_mentions(yml) == 0, "batch-check.yml still collects the old name"
    # the test-logs upload list, the publish_diag file list, and the publish copy pair
    assert yml.count(NEW) >= 3
