"""tools/req_trace_table.py: the requirement-to-row status table that docs/plan-test-suite-gaps.md keeps a copy of.

The tool only reports (tests/test_req_trace.py is the gate), so these cases prove it reports each situation
correctly: a shall named by a sub-id tag, one named by nothing, a requirement tagged only by its number, a number
with no numbered shall, a shall sitting in another number's section, a row id found before or after the tag, and
a tag with no id in its row.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

import req_trace_table as rtt  # noqa: E402

README = """\
## [REQ-001] Converted

**Goal.** The bootstrapper should do the thing.

- **REQ-001.1** [major] The bootstrapper **shall** do one.
- **REQ-001.2** [major] The bootstrapper **shall** do two.
- A plain bullet that is not a numbered shall.

## [REQ-002] Not converted yet

- The bootstrapper shall do something old.

## [REQ-003] Converted too

**Goal.** The bootstrapper should do more.

- **REQ-003.1** [minor] The bootstrapper **shall** do three.
"""

TAGS = """\
Write-NdjsonRow ([ordered]@{
  id = 'row.one'
  req = 'REQ-001.1'
})
Write-NdjsonRow ([ordered]@{
  id = 'row.section'
  req = 'REQ-001'
  pass = $true
})
Write-NdjsonRow ([ordered]@{
  req = 'REQ-003'
  id = 'row.id.after'
})
"""


def test_shalls_are_grouped_by_their_own_number_and_plain_bullets_are_ignored() -> None:
    shalls, without = rtt.readme_shalls(README)
    assert shalls == {"001": ["REQ-001.1", "REQ-001.2"], "003": ["REQ-003.1"]}
    assert without == ["002"]


def test_a_shall_inside_another_numbers_section_counts_under_its_own_number() -> None:
    text = "## [REQ-003] Platform\n\n- **REQ-009.9** [major] The bootstrapper **shall** remember.\n"
    shalls, without = rtt.readme_shalls(text)
    assert shalls == {"009": ["REQ-009.9"]}
    assert without == ["003"]


def test_tag_finds_the_row_id_before_or_after_it() -> None:
    tags = rtt.row_tags([TAGS])
    assert tags["REQ-001.1"] == {"row.one"}
    assert tags["REQ-001"] == {"row.section"}
    assert tags["REQ-003"] == {"row.id.after"}


def test_a_tag_with_no_id_near_it_is_kept_as_unlocated() -> None:
    far = "req = 'REQ-009'\n" + "\n" * 20 + "id = 'too.far'\n"
    assert rtt.row_tags([far]) == {"REQ-009": {"?"}}


def test_report_names_the_gap_and_counts() -> None:
    report = rtt.build_report(README, [TAGS])
    assert "| REQ-001 | 2 | 1 | 1 | 1 |" in report
    assert "| REQ-003 | 1 | 0 | 1 | 1 |" in report
    assert "1 of 3 numbered shalls are named by at least one row tag." in report
    assert "Shalls no row names: REQ-001.2, REQ-003.1." in report
    assert "have no numbered shall yet: REQ-002." in report


def test_report_with_every_shall_named_says_none() -> None:
    tags = TAGS + "id = 'row.two'\nreq = 'REQ-001.2'\nid = 'row.three'\nreq = 'REQ-003.1'\n"
    report = rtt.build_report(README, [tags])
    assert "Shalls no row names: none." in report


def test_repository_report_is_consistent_and_ascii() -> None:
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8", errors="replace")
    report = rtt.build_report(readme, rtt.repo_tag_texts())
    report.encode("ascii")
    shalls, _ = rtt.readme_shalls(readme)
    lines = report.splitlines()
    table = [ln for ln in lines if ln.startswith("| REQ-")]
    assert len(table) == len(shalls)
    not_named = sum(int(ln.split("|")[4]) for ln in table)
    gap_line = next(ln for ln in lines if ln.startswith("Shalls no row names:"))
    listed = 0 if gap_line.endswith("none.") else len(gap_line[len("Shalls no row names: "):-1].split(", "))
    assert not_named == listed
