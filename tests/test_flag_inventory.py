"""Flag-inventory ratchet (README REQ-019, docs/plan-test-suite-gaps.md gap T6).

REQ-019 says env-var flags are scaffolding, never a gate. Whether a flag *enables* a Prime Directive
behavior needs a human reading, but three mechanical halves can be enforced:

1. every `HP_TEST_*` hook that run_setup.bat reads is set or named by at least one file under tests/
   or .github/workflows/ (AGENTS.md "Branch coverage policy": a hook with no test is an unproven
   branch). UNTESTED_HOOKS below lists the known gaps (none today; HP_TEST_DISABLE_LOCK, the last one, was
   removed because no test ever set it);
2. every exact `HP_*`/`PVW_*` name in the README's "Advanced Environment Variables" table exists
   in run_setup.bat or tools/ (a documented flag no code reads is a false promise);
3. every `PVW_*` super-user override that run_setup.bat reads is documented in the README, AGENTS.md,
   or a docs/*.md file.

The scans are static text, so a name built by string concatenation is invisible. Stale entries in
UNTESTED_HOOKS warn instead of failing, so a lane that adds the missing test is never blocked by
this file; delete the entry when you see the warning. The checks are pure functions so the
synthetic cases below prove each rule can fail without touching the repository.
"""
from __future__ import annotations

import re
import warnings
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent

# A name must end in a letter or digit: prefix mentions in prose ("HP_TEST_", "HP_CI_") are not names.
HOOK = re.compile(r"\bHP_TEST_[A-Z0-9_]*[A-Z0-9]\b")
FLAG = re.compile(r"\b(?:HP|PVW)_[A-Z0-9_]*[A-Z0-9]\b")
PVW = re.compile(r"\bPVW_[A-Z0-9_]*[A-Z0-9]\b")
ENV_SECTION_HEADING = "## Advanced Environment Variables"

# Hook name -> why no test sets it. Delete an entry when a test uses the hook (or the hook is removed).
UNTESTED_HOOKS: Dict[str, str] = {}


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def untested_hooks(bat_text: str, reference_texts: Iterable[str], known_gaps: Dict[str, str]) -> Tuple[List[str], List[str]]:
    """Rule 1. Return (problems, stale)."""
    referenced: Set[str] = set()
    for text in reference_texts:
        referenced |= set(HOOK.findall(text))
    hooks = set(HOOK.findall(bat_text))
    problems = [
        "%s is read by run_setup.bat but no file under tests/ or .github/workflows/ names it. "
        "Add a test that sets it, or list it in UNTESTED_HOOKS with a reason." % name
        for name in sorted(hooks - referenced)
        if name not in known_gaps
    ]
    stale = []
    for name in sorted(known_gaps):
        if name in referenced:
            stale.append("UNTESTED_HOOKS has %s but a test names it now; delete the entry in tests/test_flag_inventory.py" % name)
        elif name not in hooks:
            stale.append("UNTESTED_HOOKS has %s but run_setup.bat no longer reads it; delete the entry in tests/test_flag_inventory.py" % name)
    return problems, stale


def env_section_flags(readme_text: str) -> Set[str]:
    start = readme_text.find(ENV_SECTION_HEADING)
    if start < 0:
        raise AssertionError("README no longer has a %r heading; update tests/test_flag_inventory.py" % ENV_SECTION_HEADING)
    end = readme_text.find("\n## ", start + len(ENV_SECTION_HEADING))
    section = readme_text[start : end if end >= 0 else len(readme_text)]
    return set(FLAG.findall(section))


def documented_but_unread(readme_text: str, code_texts: Iterable[str]) -> List[str]:
    """Rule 2."""
    code = "\n".join(code_texts)
    names = sorted(env_section_flags(readme_text))
    return [
        "%s is in the README's Advanced Environment Variables table but neither run_setup.bat nor tools/ mentions it" % name
        for name in names
        if re.search(r"\b%s\b" % re.escape(name), code) is None
    ]


def undocumented_overrides(bat_text: str, doc_texts: Iterable[str]) -> List[str]:
    """Rule 3."""
    docs = "\n".join(doc_texts)
    return [
        "%s is read by run_setup.bat but the README, AGENTS.md and docs/*.md never mention it" % name
        for name in sorted(set(PVW.findall(bat_text)))
        if re.search(r"\b%s\b" % re.escape(name), docs) is None
    ]


# --- repository inputs -----------------------------------------------------------------------

def _tests_and_workflows() -> List[str]:
    paths = [p for p in sorted((REPO_ROOT / "tests").iterdir()) if p.is_file() and not p.name.startswith("~")]
    paths += sorted((REPO_ROOT / ".github" / "workflows").glob("*.yml"))
    # This file's own docstring and tables name hooks; they must not count as a test using them.
    paths = [p for p in paths if p.name != Path(__file__).name]
    return [_read(p) for p in paths]


def _tools_texts() -> List[str]:
    return [_read(p) for p in sorted((REPO_ROOT / "tools").iterdir()) if p.is_file()]


def _doc_texts() -> List[str]:
    paths = [REPO_ROOT / "README.md", REPO_ROOT / "AGENTS.md"] + sorted((REPO_ROOT / "docs").glob("*.md"))
    return [_read(p) for p in paths]


def test_every_batch_hook_has_a_test() -> None:
    problems, stale = untested_hooks(_read(REPO_ROOT / "run_setup.bat"), _tests_and_workflows(), UNTESTED_HOOKS)
    for message in stale:
        warnings.warn(message, stacklevel=1)
    assert not problems, "\n" + "\n".join(problems)


def test_documented_flags_exist_in_code() -> None:
    problems = documented_but_unread(_read(REPO_ROOT / "README.md"), [_read(REPO_ROOT / "run_setup.bat")] + _tools_texts())
    assert not problems, "\n" + "\n".join(problems)


def test_super_user_overrides_are_documented() -> None:
    problems = undocumented_overrides(_read(REPO_ROOT / "run_setup.bat"), _doc_texts())
    assert not problems, "\n" + "\n".join(problems)


# --- synthetic cases: each rule must be able to fail ------------------------------------------

BAT = 'if defined HP_TEST_FORCE_A echo a\nif defined HP_TEST_FORCE_B echo b\nset "PVW_OVERRIDE_X="\n'


def test_hook_without_a_test_fails_and_exemption_silences_it() -> None:
    problems, stale = untested_hooks(BAT, ["set HP_TEST_FORCE_A=1"], {})
    assert len(problems) == 1 and "HP_TEST_FORCE_B" in problems[0] and stale == []
    problems, stale = untested_hooks(BAT, ["set HP_TEST_FORCE_A=1"], {"HP_TEST_FORCE_B": "pending"})
    assert problems == [] and stale == []


def test_exemption_goes_stale_when_a_test_uses_the_hook_or_the_hook_is_removed() -> None:
    _, stale = untested_hooks(BAT, ["HP_TEST_FORCE_A HP_TEST_FORCE_B"], {"HP_TEST_FORCE_B": "pending"})
    assert any("HP_TEST_FORCE_B" in s and "names it now" in s for s in stale)
    _, stale = untested_hooks(BAT, ["HP_TEST_FORCE_A"], {"HP_TEST_FORCE_B": "pending", "HP_TEST_GONE": "x"})
    assert any("HP_TEST_GONE" in s and "no longer reads" in s for s in stale)


def test_prefix_mentions_are_not_hook_names() -> None:
    problems, _ = untested_hooks("rem the HP_TEST_ family and HP_TEST_FORCE_ prefix\n", [], {})
    assert problems == []


def test_documented_flag_missing_from_code_fails() -> None:
    readme = "## Advanced Environment Variables (reference)\n| `HP_REAL_FLAG=1` | x |\n| `HP_GONE_FLAG=1` | y |\n\n## Next\nHP_OTHER_SECTION\n"
    problems = documented_but_unread(readme, ["set HP_REAL_FLAG=1"])
    assert len(problems) == 1 and "HP_GONE_FLAG" in problems[0]


def test_env_section_lookup_fails_loudly_when_the_heading_moves() -> None:
    try:
        env_section_flags("## Something else\nHP_X\n")
    except AssertionError as exc:
        assert "Advanced Environment Variables" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("expected AssertionError")


def test_undocumented_override_fails() -> None:
    assert undocumented_overrides(BAT, ["nothing here"]) != []
    assert undocumented_overrides(BAT, ["use PVW_OVERRIDE_X to point at a tool"]) == []
