"""Requirement traceability ratchet (docs/plan-test-suite-gaps.md, gap T5).

Makes "every requirement has a test" a mechanical check instead of a reading exercise:

* every requirement number the README (or run_setup.bat) mentions must be tagged on at least one
  NDJSON row (`req = 'REQ-nnn'` in tests/*.ps1 or batch-check.yml), or sit in NO_ROW_TAG_YET below
  with a reason;
* a requirement number that run_setup.bat uses but the README never mentions must sit in
  NOT_IN_README below, so a new undocumented requirement cannot slip in unnoticed;
* a `req` tag that names no known requirement (a typo) fails.

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
