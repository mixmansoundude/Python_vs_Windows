"""Requirement traceability ratchet (docs/plan-test-suite-gaps.md, gap T5).

Makes "every requirement has a test" a mechanical check instead of a reading exercise:

* every requirement number the README (or run_setup.bat) mentions must be tagged on at least one
  NDJSON row (`req = 'REQ-nnn'` in tests/*.ps1 or batch-check.yml), or sit in NO_ROW_TAG_YET below
  with a reason;
* a requirement number that run_setup.bat uses but the README never mentions must sit in
  NOT_IN_README below, so a new undocumented requirement cannot slip in unnoticed;
* a `req` tag that names no known requirement (a typo) fails;
* a converted README section (one that opens with a `**Goal.**` paragraph) must word the goal with
  "should", must hold at least one numbered shall of its own, and every tagged numbered line in it must
  say **shall** (AGENTS.md, "Writing README requirements").

The tag scan is static text, like tools/check_ndjson_registry.py: a tag built from a variable is
invisible here, so keep the tag a literal at the row's call site. Stale exemptions (an entry that
now has a tagged row, or a README section) emit a warning instead of failing, so a lane that adds
the missing tag or section is never blocked by this file; delete the entry when you see the warning.

The checker is a pure function (`trace_problems`) so the synthetic cases below prove each rule can
fail without touching the repository.
"""
from __future__ import annotations

import re
import warnings
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent

NUM = re.compile(r"REQ-(\d{3})")
TAG = re.compile(r"""\breq\s*=\s*['"]([^'"\r\n]+)['"]""")
SUBTAG = re.compile(r"^REQ-(\d{3})([a-z]?)(?:\.(\d+))?$")
# Tags that name something other than a README requirement number. REQ-AV is the AV-safe build path
# (docs/prd-av-safe-build-path.md); CLAUDE.md-Item-* tags point at a backlog item.
FREE_TAGS = ("N/A", "REQ-AV")
FREE_TAG_PREFIXES = ("CLAUDE.md-Item-",)

# Requirement number -> why no NDJSON row carries its tag yet. Delete an entry when its row is tagged.
NO_ROW_TAG_YET: Dict[str, str] = {
    "019": "policy requirement with no runtime behavior; gap T6 (tests/test_flag_inventory.py) is its mechanical half",
    "026": "argv passthrough has no batch-level row yet; docs/plan-test-suite-gaps.md gap T1 proposes it",
    "027": "behavior covered by rows tagged REQ-003 (self.exe.build.xfail) and untagged failfast rows",
}

# Requirement number -> why the README has no mention yet although run_setup.bat uses it.
NOT_IN_README: Dict[str, str] = {
    "024": "concurrent-instance lock: log lines and tests exist, no README section",
    "025": "free-disk-space warning: log line and test exist, no README section",
}


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _sub_in_readme(readme_text: str, num: str, sub: str) -> bool:
    return re.search(r"REQ-%s\.%s(?!\d)" % (num, re.escape(sub)), readme_text) is not None


def trace_problems(
    readme_text: str,
    batch_text: str,
    tag_texts: Iterable[str],
    no_row_tag_yet: Dict[str, str],
    not_in_readme: Dict[str, str],
) -> Tuple[List[str], List[str]]:
    """Return (problems, stale_exemptions). Problems fail the test; stale exemptions only warn."""
    readme_nums = set(NUM.findall(readme_text))
    batch_nums = set(NUM.findall(batch_text))
    known = readme_nums | batch_nums

    tagged: set = set()
    bad_tags: List[str] = []
    for text in tag_texts:
        for tag in TAG.findall(text):
            if tag in FREE_TAGS or tag.startswith(FREE_TAG_PREFIXES):
                continue
            m = SUBTAG.match(tag)
            if not m:
                bad_tags.append(tag)
                continue
            num, _letter, sub = m.group(1), m.group(2), m.group(3)
            if num not in known:
                bad_tags.append(tag)
                continue
            if sub is not None and not _sub_in_readme(readme_text, num, sub):
                bad_tags.append(tag)
                continue
            tagged.add(num)

    problems: List[str] = []
    for num in sorted(known - tagged):
        if num not in no_row_tag_yet:
            problems.append(
                "REQ-%s is mentioned in the README or run_setup.bat but no NDJSON row is tagged "
                "req = 'REQ-%s'. Tag the row that covers it, or add it to NO_ROW_TAG_YET with a reason." % (num, num)
            )
    for num in sorted(batch_nums - readme_nums):
        if num not in not_in_readme:
            problems.append(
                "REQ-%s is used in run_setup.bat but the README never mentions it. Add a README "
                "section, or add it to NOT_IN_README with a reason." % num
            )
    for tag in sorted(set(bad_tags)):
        problems.append("row tag %r names no requirement the README or run_setup.bat knows (typo?)" % tag)

    stale: List[str] = []
    for num in sorted(no_row_tag_yet):
        if num in tagged:
            stale.append("NO_ROW_TAG_YET has REQ-%s but a row is tagged now; delete the entry in tests/test_req_trace.py" % num)
        elif num not in known:
            stale.append("NO_ROW_TAG_YET has REQ-%s but nothing mentions it; delete the entry in tests/test_req_trace.py" % num)
    for num in sorted(not_in_readme):
        if num in readme_nums:
            stale.append("NOT_IN_README has REQ-%s but the README mentions it now; delete the entry in tests/test_req_trace.py" % num)
        elif num not in batch_nums:
            stale.append("NOT_IN_README has REQ-%s but run_setup.bat no longer uses it; delete the entry in tests/test_req_trace.py" % num)
    return problems, stale


SECTION = re.compile(r"^## \[REQ-(\d{3}[a-z]?)\][^\n]*$", re.MULTILINE)
GOAL = re.compile(r"^\*\*Goal\.\*\*(.*?)(?:\n\s*\n|\Z)", re.MULTILINE | re.DOTALL)
SHALL_LINE = re.compile(r"^\s*- \*\*REQ-(\d{3}[a-z]?)\.(\d+(?:\.\d+)*)\*\*(.*)$", re.MULTILINE)
CRIT_TAG = re.compile(r"\[(?:critical|major|minor)\]")


def goal_problems(readme_text: str) -> List[str]:
    """Rules for a converted README section: a goal worded with 'should', at least one numbered shall,
    every tagged numbered line carrying 'shall', and every numbered line carrying 'shall' tagged. Sections without a `**Goal.**` paragraph are not
    converted yet and are left alone."""
    problems: List[str] = []
    marks = list(SECTION.finditer(readme_text))
    for i, mark in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(readme_text)
        body = readme_text[mark.end():end]
        goal = GOAL.search(body)
        if not goal:
            continue
        num = mark.group(1)
        text = goal.group(1)
        if not re.search(r"\bshould\b", text):
            problems.append("REQ-%s: the goal paragraph must be worded with 'should'" % num)
        if re.search(r"\bshalls?\b", text):
            problems.append("REQ-%s: the goal paragraph must not use 'shall'; a goal is not a requirement" % num)
        own = [m for m in SHALL_LINE.finditer(body) if m.group(1) == num]
        if not any("shall" in m.group(3) for m in own):
            problems.append("REQ-%s: a converted section needs at least one numbered shall (REQ-%s.1, ...)" % (num, num))
        for m in own:
            tagged = bool(CRIT_TAG.search(m.group(3)))
            if tagged and not re.search(r"\*\*shall(?: not)?\*\*", m.group(3)):
                problems.append("REQ-%s.%s: a tagged requirement line must say **shall**" % (num, m.group(2)))
            if not tagged and re.search(r"\bshall\b", m.group(3)):
                problems.append("REQ-%s.%s: a numbered shall needs a criticality tag [critical], [major] or [minor]" % (num, m.group(2)))
    return problems


def _repo_tag_sources() -> List[Path]:
    sources = [
        p for p in sorted((REPO_ROOT / "tests").glob("*.ps1")) if not p.name.startswith("~")
    ]
    sources.append(REPO_ROOT / ".github" / "workflows" / "batch-check.yml")
    return sources


def test_repository_requirement_trace() -> None:
    problems, stale = trace_problems(
        _read(REPO_ROOT / "README.md"),
        _read(REPO_ROOT / "run_setup.bat"),
        [_read(p) for p in _repo_tag_sources()],
        NO_ROW_TAG_YET,
        NOT_IN_README,
    )
    for message in stale:
        warnings.warn(message, stacklevel=1)
    assert not problems, "\n" + "\n".join(problems)


def test_repository_goals_and_shalls() -> None:
    problems = goal_problems(_read(REPO_ROOT / "README.md"))
    assert not problems, "\n" + "\n".join(problems)


# --- synthetic cases: each rule must be able to fail ------------------------------------------

README = "## [REQ-001] One\n## [REQ-002] Two\nREQ-005.1 and REQ-005.11 are sub-requirements of REQ-005.\n"
BATCH = "rem REQ-001 REQ-002 REQ-005\n"


def _check(readme=README, batch=BATCH, tags=("req = 'REQ-001'\nreq = 'REQ-002'\nreq = 'REQ-005.11'",), no_tag=None, not_readme=None):
    return trace_problems(readme, batch, tags, no_tag or {}, not_readme or {})


def test_clean_synthetic_input_has_no_problems() -> None:
    problems, stale = _check()
    assert problems == [] and stale == []


def test_untagged_readme_requirement_fails() -> None:
    problems, _ = _check(tags=("req = 'REQ-001'\nreq = 'REQ-005.11'",))
    assert any("REQ-002" in p for p in problems)


def test_exemption_silences_the_gap_and_goes_stale_when_tagged() -> None:
    problems, stale = _check(tags=("req = 'REQ-001'\nreq = 'REQ-005'",), no_tag={"002": "pending"})
    assert problems == [] and stale == []
    problems, stale = _check(no_tag={"002": "pending"})
    assert problems == [] and any("REQ-002" in s for s in stale)


def test_requirement_used_by_batch_but_missing_from_readme_fails() -> None:
    problems, _ = _check(batch=BATCH + "rem REQ-024\n", tags=("req = 'REQ-001'\nreq = 'REQ-002'\nreq = 'REQ-005'\nreq = 'REQ-024'",))
    assert any("REQ-024" in p and "README" in p for p in problems)
    problems, _ = _check(
        batch=BATCH + "rem REQ-024\n",
        tags=("req = 'REQ-001'\nreq = 'REQ-002'\nreq = 'REQ-005'\nreq = 'REQ-024'",),
        not_readme={"024": "no section yet"},
    )
    assert problems == []


def test_not_in_readme_exemption_goes_stale_when_readme_adds_it() -> None:
    _, stale = _check(readme=README + "REQ-024 lock\n", batch=BATCH + "REQ-024\n", tags=("req = 'REQ-001'\nreq = 'REQ-002'\nreq = 'REQ-005'\nreq = 'REQ-024'",), not_readme={"024": "x"})
    assert any("NOT_IN_README" in s and "REQ-024" in s for s in stale)


def test_tag_typo_and_unknown_subrequirement_fail() -> None:
    problems, _ = _check(tags=("req = 'REQ-001'\nreq = 'REQ-002'\nreq = 'REQ-005'\nreq = 'REQ-0O5'",))
    assert any("REQ-0O5" in p for p in problems)
    problems, _ = _check(tags=("req = 'REQ-001'\nreq = 'REQ-002'\nreq = 'REQ-005.99'",))
    assert any("REQ-005.99" in p for p in problems)
    problems, _ = _check(tags=("req = 'REQ-001'\nreq = 'REQ-002'\nreq = 'REQ-777'",))
    assert any("REQ-777" in p for p in problems)


def test_subtag_prefix_is_not_confused_with_longer_subrequirement() -> None:
    # README only has REQ-005.11; a tag REQ-005.1 must not pass just because ".11" starts with ".1".
    problems, _ = _check(readme="## [REQ-005] x\nREQ-005.11 only\n", batch="REQ-005\n", tags=("req = 'REQ-005.1'",))
    assert any("REQ-005.1" in p for p in problems)


def test_free_tags_are_accepted() -> None:
    tags = ("req = 'REQ-001'\nreq = 'REQ-002'\nreq = 'REQ-005'\nreq = 'REQ-AV'\nreq = 'N/A'\nreq = 'CLAUDE.md-Item-48'",)
    problems, _ = _check(tags=tags)
    assert problems == []


GOOD_SECTION = (
    "## [REQ-021] Pre-flight\n\n**Goal.** The bootstrapper should report a syntax error early.\n\n"
    "- **REQ-021.1** [major] The bootstrapper **shall** check the entry file.\n"
)


def test_converted_section_with_goal_and_shall_is_clean() -> None:
    assert goal_problems(GOOD_SECTION) == []


def test_section_without_a_goal_paragraph_is_not_checked() -> None:
    assert goal_problems("## [REQ-005] Old\n\nThe bootstrapper shall do things.\n") == []


def test_goal_without_any_shall_fails() -> None:
    problems = goal_problems("## [REQ-021] Pre-flight\n\n**Goal.** The bootstrapper should report errors.\n\n> notes only\n")
    assert any("REQ-021" in p and "at least one numbered shall" in p for p in problems)


def test_goal_worded_with_shall_or_without_should_fails() -> None:
    problems = goal_problems(GOOD_SECTION.replace("should report", "shall report"))
    assert any("'should'" in p for p in problems) and any("not use 'shall'" in p for p in problems)
    problems = goal_problems(GOOD_SECTION.replace("should report", "reports"))
    assert any("'should'" in p for p in problems)


def test_shall_for_another_requirement_does_not_count() -> None:
    other = GOOD_SECTION.replace("REQ-021.1", "REQ-022.1")
    assert any("at least one numbered shall" in p for p in goal_problems(other))


def test_tagged_line_without_shall_fails() -> None:
    bad = GOOD_SECTION + "- **REQ-021.2** [major] The bootstrapper will report the error.\n"
    assert any("REQ-021.2" in p and "**shall**" in p for p in goal_problems(bad))


def test_numbered_shall_without_a_criticality_tag_fails() -> None:
    bad = GOOD_SECTION + "- **REQ-021.2** The bootstrapper **shall** report the error.\n"
    assert any("REQ-021.2" in p and "criticality tag" in p for p in goal_problems(bad))


def test_group_heading_without_a_tag_needs_no_shall() -> None:
    grouped = GOOD_SECTION + "- **REQ-021.3** Failure of the check\n  - **REQ-021.3.1** [major] The bootstrapper **shall** continue.\n"
    assert goal_problems(grouped) == []
