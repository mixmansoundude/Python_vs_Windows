"""Shall-level traceability ratchet (docs/plan-test-suite-gaps.md, gap T5, second half).

tests/test_req_trace.py proves every README requirement NUMBER (REQ-018) is tagged on some NDJSON row. This
file goes one level down. Every numbered shall of a converted README section (a line such as
`- **REQ-018.27** [major] The bootstrapper **shall** ...`) must be named by the `req` tag of at least one row
(`req = 'REQ-018.27'` in tests/*.ps1 or batch-check.yml; a row that proves several shalls lists them with
commas, `req = 'REQ-018.1,REQ-018.5'`), or sit in UNTRACED_SHALLS below with a reason that says what is missing.
A new shall therefore cannot be added to the README without a row or an explicit, reviewed entry, and the
entries are the list of known holes, in one place that a test keeps honest.

Reason prefixes (the checker needs one of them, so every entry says which kind of hole it is):

* `gap:` free text naming the clause that no row, unit test or inspection proves, or the way the code
  disagrees with the shall. The usual fix is a new row (tag it, then delete the entry).
* `unit:` `tests/test_x.py::Name` and then free text. No behavior row exists, but that unit test class or
  function proves the shall (pure functions, static wording pins). The checker verifies the file exists and
  defines `Name`, so a renamed test cannot leave a dead pointer.
* `inspection:` `path :: literal` and then free text. The README itself names inspection as the method.
  The checker verifies the file contains the literal.

When to tag a row with a sub-id: the row, with the unit tests that run next to it in `self.pytest.unit`,
shows the shall's response in a representative condition and no clause of the shall is left without any
proof. A clause with no proof at all, or a README shall the code does not meet, is a `gap:` entry and the
partial rows keep their number-level tag (REQ-018). Do not tag a row to make the list shorter.

The tag scan is static text, like tests/test_req_trace.py: a tag built from a variable is invisible, so keep
it a literal at the row's call site. A stale entry (its shall is tagged by a row now) emits a warning
instead of failing, so a lane that adds the missing tag is never blocked by this file; delete the entry when
you see the warning. The checks are pure functions so the synthetic cases below prove each rule can fail
without touching the repository.
"""
from __future__ import annotations

import re
import warnings
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent

# Same patterns as tests/test_req_trace.py (TAG, SHALL_LINE, CRIT_TAG); each test file stays self-contained.
TAG = re.compile(r"""\breq\s*=\s*['"]([^'"\r\n]+)['"]""")
SHALL_LINE = re.compile(r"^[ \t]*- \*\*(REQ-\d{3}[a-z]?\.\d+(?:\.\d+)*)\*\*(.*)$", re.MULTILINE)
CRIT_TAG = re.compile(r"\[(critical|major|minor)\]")
SHALL_ID = re.compile(r"^REQ-\d{3}[a-z]?\.\d+(?:\.\d+)*$")

PREFIXES = ("gap:", "unit:", "inspection:")

# Shall id -> reason it has no tagged row. Delete an entry when a row is tagged with the shall's id.
UNTRACED_SHALLS: Dict[str, str] = {}


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def readme_shalls(readme_text: str) -> Dict[str, str]:
    """Shall id -> criticality, for every numbered line that carries a criticality tag, wherever it sits. A group
    heading (a numbered line without a tag) holds no shall. The id need not match the section it sits in: the
    REQ-005.1 and REQ-009 shalls live inside the REQ-003 section."""
    found: Dict[str, str] = {}
    for m in SHALL_LINE.finditer(readme_text):
        crit = CRIT_TAG.search(m.group(2))
        if crit:
            found[m.group(1)] = crit.group(1)
    return found


def row_tags(tag_texts: Iterable[str]) -> Set[str]:
    """Every shall-shaped id (REQ-018.27, REQ-005.1.3) that a `req` tag names, commas split."""
    tags: Set[str] = set()
    for text in tag_texts:
        for raw in TAG.findall(text):
            for part in raw.split(","):
                part = part.strip()
                if SHALL_ID.match(part):
                    tags.add(part)
    return tags


def _pointer_problem(shall: str, reason: str, root: Path) -> Optional[str]:
    """A `unit:` or `inspection:` entry must point at something that exists, so it cannot rot unnoticed."""
    if reason.startswith("unit:"):
        words = reason[len("unit:"):].split()
        pointer = words[0] if words else ""
        path_text, _, name = pointer.partition("::")
        if not path_text.startswith("tests/") or not name:
            return "%s: a unit: entry starts with tests/test_x.py::Name, got %r" % (shall, pointer)
        path = root / path_text
        if not path.is_file():
            return "%s: unit: entry points at %s, which does not exist" % (shall, path_text)
        if not re.search(r"^[ \t]*(?:class|def)[ \t]+%s\b" % re.escape(name), _read(path), re.MULTILINE):
            return "%s: unit: entry points at %s::%s, but that file defines no such class or function" % (shall, path_text, name)
    elif reason.startswith("inspection:"):
        path_text, sep, literal = reason[len("inspection:"):].strip().partition(" :: ")
        literal = literal.split("\n")[0].strip()
        if not sep or not path_text.strip() or not literal:
            return "%s: an inspection: entry reads 'path :: literal text', got %r" % (shall, reason)
        path = root / path_text.strip()
        if not path.is_file():
            return "%s: inspection: entry points at %s, which does not exist" % (shall, path_text.strip())
        if literal not in _read(path):
            return "%s: inspection: entry says %s contains %r, but it does not" % (shall, path_text.strip(), literal)
    return None


def shall_problems(
    readme_text: str,
    tag_texts: Iterable[str],
    untraced: Dict[str, str],
    root: Path = REPO_ROOT,
) -> Tuple[List[str], List[str]]:
    """Return (problems, stale). Problems fail the test; stale entries only warn."""
    shalls = readme_shalls(readme_text)
    tagged = row_tags(tag_texts)
    problems: List[str] = []
    stale: List[str] = []

    for shall in sorted(shalls, key=_sort_key):
        if shall in tagged or shall in untraced:
            continue
        problems.append(
            "%s [%s] has no row tagged req = '%s' and no UNTRACED_SHALLS entry. Tag the row that proves it "
            "(a literal tag at the row's call site, several shalls separated by commas), or add an entry to "
            "tests/test_req_shall_trace.py that says what is missing (gap:, unit: or inspection:)."
            % (shall, shalls[shall], shall)
        )
    for shall in sorted(untraced, key=_sort_key):
        reason = untraced[shall]
        if shall not in shalls:
            problems.append(
                "UNTRACED_SHALLS has %s but the README holds no such numbered shall; delete the entry or fix the id" % shall
            )
            continue
        if not reason.startswith(PREFIXES):
            problems.append("%s: the UNTRACED_SHALLS reason must start with gap:, unit: or inspection:, got %r" % (shall, reason[:40]))
            continue
        pointer = _pointer_problem(shall, reason, root)
        if pointer:
            problems.append(pointer)
        if shall in tagged:
            stale.append("UNTRACED_SHALLS has %s but a row is tagged with it now; delete the entry in tests/test_req_shall_trace.py" % shall)
    return problems, stale


def _sort_key(shall: str) -> Tuple[str, Tuple[int, ...]]:
    head, _, tail = shall.partition(".")
    return head, tuple(int(n) for n in tail.split("."))


def _repo_tag_sources() -> List[Path]:
    sources = [p for p in sorted((REPO_ROOT / "tests").glob("*.ps1")) if not p.name.startswith("~")]
    sources.append(REPO_ROOT / ".github" / "workflows" / "batch-check.yml")
    return sources


def test_every_readme_shall_has_a_row_or_a_listed_reason() -> None:
    problems, stale = shall_problems(
        _read(REPO_ROOT / "README.md"),
        [_read(p) for p in _repo_tag_sources()],
        UNTRACED_SHALLS,
    )
    for message in stale:
        warnings.warn(message, stacklevel=1)
    assert not problems, "\n" + "\n".join(problems)


# --- synthetic cases: each rule must be able to fail ------------------------------------------

README = (
    "## [REQ-018] Runs\n\n**Goal.** The bootstrapper should run the program once.\n\n"
    "- **REQ-018.1** [critical] The bootstrapper **shall** start the program at most once.\n"
    "- **REQ-018.2** [major] The bootstrapper **shall** ask first.\n"
    "- **REQ-018.3** Failure handling\n"
    "  - **REQ-018.3.1** [minor] The bootstrapper **shall** say so.\n"
    "  - **REQ-009.1** [major] The bootstrapper **shall** build once, although the id belongs to another section.\n"
    "\n## [REQ-005] Old section\n\nNo goal paragraph here, and a note that names REQ-018.2 in prose.\n"
)
BASE = "req = 'REQ-018.1'\nreq = 'REQ-018.3.1'\nreq = 'REQ-009.1'\n"
ALL_TAGS = (BASE + "req = 'REQ-018.2'\n",)


def _check(readme=README, tags=ALL_TAGS, untraced=None, root=REPO_ROOT):
    return shall_problems(readme, tags, untraced or {}, root)


def test_clean_synthetic_input_has_no_problems() -> None:
    assert _check() == ([], [])


def test_only_tagged_numbered_lines_are_shalls_wherever_they_sit() -> None:
    assert readme_shalls(README) == {
        "REQ-018.1": "critical",
        "REQ-018.2": "major",
        "REQ-018.3.1": "minor",
        "REQ-009.1": "major",
    }


def test_a_shall_without_a_row_or_an_entry_fails_and_names_its_criticality() -> None:
    problems, _ = _check(tags=(BASE,))
    assert len(problems) == 1 and "REQ-018.2 [major]" in problems[0]
    problems, _ = _check(tags=("req = 'REQ-018.1'\nreq = 'REQ-018.2'\nreq = 'REQ-018.3.1'\n",))
    assert len(problems) == 1 and "REQ-009.1 [major]" in problems[0]


def test_a_number_level_tag_does_not_trace_a_shall() -> None:
    problems, _ = _check(tags=(BASE + "req = 'REQ-018'\n",))
    assert any("REQ-018.2" in p for p in problems)


def test_a_parent_tag_does_not_trace_a_longer_id_and_the_reverse() -> None:
    problems, _ = _check(tags=("req = 'REQ-018.1'\nreq = 'REQ-018.2'\nreq = 'REQ-018.3'\nreq = 'REQ-009.1'\n",))
    assert any("REQ-018.3.1" in p for p in problems)


def test_a_comma_list_traces_every_shall_it_names() -> None:
    assert _check(tags=("req = 'REQ-018.1, REQ-018.2'\nreq = 'REQ-018.3.1,REQ-009.1'\n",)) == ([], [])
    assert row_tags(("req = 'REQ-009,REQ-018.27'",)) == {"REQ-018.27"}


def test_an_entry_silences_the_shall_and_goes_stale_when_a_row_names_it() -> None:
    gap = {"REQ-018.2": "gap: the prompt does not name the risk"}
    problems, stale = _check(tags=(BASE,), untraced=gap)
    assert problems == [] and stale == []
    problems, stale = _check(untraced=gap)
    assert problems == [] and any("REQ-018.2" in s for s in stale)


def test_an_entry_for_a_shall_the_readme_lacks_fails() -> None:
    problems, _ = _check(untraced={"REQ-018.99": "gap: gone"})
    assert any("REQ-018.99" in p and "no such numbered shall" in p for p in problems)
    # A group heading is not a shall either, so an entry for it is a typo.
    problems, _ = _check(untraced={"REQ-018.3": "gap: heading"})
    assert any("REQ-018.3" in p and "no such numbered shall" in p for p in problems)


def test_an_entry_without_a_known_reason_prefix_fails() -> None:
    problems, _ = _check(tags=(BASE,), untraced={"REQ-018.2": "later"})
    assert any("must start with gap:, unit: or inspection:" in p for p in problems)


def test_unit_pointer_must_exist(tmp_path: Path) -> None:
    (tmp_path / "tests").mkdir()
    (tmp_path / "tests" / "test_x.py").write_text("class WhatItProves:\n    pass\n\ndef test_other():\n    pass\n", encoding="utf-8")

    def run(reason):
        return _check(tags=(BASE,), untraced={"REQ-018.2": reason}, root=tmp_path)[0]

    assert run("unit: tests/test_x.py::WhatItProves static wording pin") == []
    assert run("unit: tests/test_x.py::test_other it does") == []
    assert any("defines no such class" in p for p in run("unit: tests/test_x.py::Renamed it did"))
    assert any("does not exist" in p for p in run("unit: tests/test_gone.py::WhatItProves"))
    assert any("starts with tests/test_x.py::Name" in p for p in run("unit: nothing to point at"))
    assert any("starts with tests/test_x.py::Name" in p for p in run("unit: README.md::Section"))


def test_inspection_pointer_must_contain_its_literal(tmp_path: Path) -> None:
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "rule.md").write_text("## Flags are scaffolding\nre-read any new flag\n", encoding="utf-8")

    def run(reason):
        return _check(tags=(BASE,), untraced={"REQ-018.2": reason}, root=tmp_path)[0]

    assert run("inspection: docs/rule.md :: Flags are scaffolding") == []
    assert any("does not" in p for p in run("inspection: docs/rule.md :: a sentence that is not there"))
    assert any("does not exist" in p for p in run("inspection: docs/missing.md :: Flags"))
    assert any("reads 'path :: literal text'" in p for p in run("inspection: docs/rule.md"))


def test_multi_level_ids_are_exact() -> None:
    tags = ("req = 'REQ-018.1'\nreq = 'REQ-018.2'\nreq = 'REQ-018.3.10'\nreq = 'REQ-009.1'\n",)
    problems, _ = _check(tags=tags)
    assert any("REQ-018.3.1 " in p for p in problems)


def test_the_repository_entries_are_ordered_and_unique_by_construction() -> None:
    # A duplicate key in the dict literal would silently keep the last reason; compare against the file text.
    text = _read(Path(__file__))
    keys = re.findall(r'^    "(REQ-\d{3}[a-z]?\.\d+(?:\.\d+)*)": "', text, re.MULTILINE)
    assert len(keys) == len(set(keys)), "a shall id appears twice in UNTRACED_SHALLS"
    assert keys == sorted(keys, key=_sort_key), "keep UNTRACED_SHALLS ordered by shall id"
