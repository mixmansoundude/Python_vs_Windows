"""Item 80: a Nuitka build that fails because Nuitka does not support the Python in use is reported plainly.

run_setup.bat cannot run on Linux, so these are static scans of the batch and of the scenarios that prove the behavior
on Windows (tests/selfapps_pvw_builder.ps1: nuitka_unsupported, nuitka_failother, both_unsupported). The pieces that have
to agree are the pattern the count looks for, the lines the stubs print, the sentence the run says, and the order of the
mark, the Nuitka command and the check around each of the two Nuitka command lines. Synthetic text proves each rule can fail.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BAT = (REPO_ROOT / "run_setup.bat").read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
SCENARIOS = (REPO_ROOT / "tests" / "selfapps_pvw_builder.ps1").read_text(encoding="utf-8", errors="replace")

SENTENCE_HEAD = "[WARN] The fallback build system says it does not support this Python version yet"
VS_HINT_MARK = "Desktop development with C++"
NUITKA_CMD = "-m nuitka --onefile"

# What Nuitka prints (the first from the CI log of 2026-10-09, the second from run 40118071438, Nuitka 4.3.1 on 3.15.1).
REAL_UNSUPPORTED = "FATAL: The Python version '3.15' is not supported by Nuitka '4.2.2'"
REAL_EXPERIMENTAL = (
    "Nuitka:WARNING: The Python version '3.15' is only experimentally supported by Nuitka '4.3.1', "
    "but an upcoming release will change that. In the mean time use Python version '3.14' instead or newer Nuitka."
)


def _count_pattern(bat: str) -> str:
    """The findstr /r pattern :nuitka_unsupported_count passes, as a Python regex (findstr's . and * mean the same)."""
    start = bat.index("\n:nuitka_unsupported_count\n")
    m = re.search(r'findstr /r /c:"([^"]+)"', bat[start:bat.index("\n:die\n", start)])
    assert m, ":nuitka_unsupported_count must call findstr /r /c:\"...\""
    return m.group(1)


def _counts(pattern: str, line: str) -> bool:
    return re.search(pattern, line) is not None


def _sentence(bat: str) -> str:
    line = next((l for l in bat.splitlines() if SENTENCE_HEAD in l), None)
    assert line is not None, "the plain sentence is missing"
    return line


def _command_sites(bat: str) -> list[int]:
    return [i for i, l in enumerate(bat.splitlines()) if NUITKA_CMD in l and "-m nuitka" in l and not l.lstrip().lower().startswith("rem")]


def _check_site(lines: list[str], at: int) -> list[str]:
    """Problems with the mark/command/check order around one Nuitka command line (an empty list is a pass)."""
    problems = []
    if lines[at - 1].strip() != "call :nuitka_unsupported_mark":
        problems.append("the line before the Nuitka command must be call :nuitka_unsupported_mark")
    if lines[at + 1].strip() != "if errorlevel 1 (":
        problems.append("the Nuitka command must be followed by if errorlevel 1 (")
        return problems
    end = next((j for j in range(at + 2, len(lines)) if lines[j].strip() == ")"), None)
    if end is None:
        return problems + ["failure block never closes"]
    block = lines[at + 2:end]
    texts = [b.strip() for b in block]
    if "call :nuitka_unsupported_check" not in texts:
        problems.append("the failure block must call :nuitka_unsupported_check")
        return problems
    hint = [i for i, b in enumerate(texts) if VS_HINT_MARK in b]
    if len(hint) != 1:
        problems.append("exactly one Visual Studio hint line is expected in the failure block, found %d" % len(hint))
        return problems
    if texts.index("call :nuitka_unsupported_check") > hint[0]:
        problems.append("the check must run before the hint line")
    if not texts[hint[0]].startswith("if not defined HP_NUI_UNSUPPORTED call :log "):
        problems.append("the hint must be guarded by if not defined HP_NUI_UNSUPPORTED")
    return problems


def test_exactly_two_nuitka_command_lines_each_marked_and_checked():
    lines = BAT.splitlines()
    sites = _command_sites(BAT)
    assert len(sites) == 2, "the batch has exactly two Nuitka command lines (tests/test_nuitka_cachesafety.py), found %d" % len(sites)
    for at in sites:
        assert _check_site(lines, at) == [], "line %d: %r" % (at + 1, _check_site(lines, at))


def test_site_check_can_fail():
    good = [
        "call :nuitka_unsupported_mark",
        '"%HP_PY%" -m nuitka --onefile --x',
        "if errorlevel 1 (",
        '  call :log "[WARN] did not complete"',
        "  call :nuitka_unsupported_check",
        "  if not defined HP_NUI_UNSUPPORTED call :log \"[WARN] Hint: 'Desktop development with C++'\"",
        "  exit /b 1",
        ")",
    ]
    assert _check_site(good, 1) == []
    no_mark = ["rem x"] + good[1:]
    assert any("mark" in p for p in _check_site(no_mark, 1))
    no_check = [l for l in good if "unsupported_check" not in l]
    assert any("must call" in p for p in _check_site(no_check, 1))
    unguarded = [l.replace("if not defined HP_NUI_UNSUPPORTED ", "") for l in good]
    assert any("guarded" in p for p in _check_site(unguarded, 1))
    swapped = good[:3] + [good[5], good[4]] + good[6:]
    assert any("before the hint" in p for p in _check_site(swapped, 1))


def test_the_count_matches_what_nuitka_says_and_nothing_else():
    pattern = _count_pattern(BAT)
    assert _counts(pattern, REAL_UNSUPPORTED)
    assert _counts(pattern, "Nuitka:FATAL: " + REAL_UNSUPPORTED.split("FATAL: ", 1)[1] + ".")
    # a Python that still builds (experimental support) is not a failure to explain
    assert not _counts(pattern, REAL_EXPERIMENTAL)
    # the bootstrapper's own sentence must never be counted, or the next run would read this run's answer
    assert not _counts(pattern, _sentence(BAT))
    assert "is not supported by Nuitka" not in _sentence(BAT)


def test_count_pattern_check_can_fail():
    # a pattern that dropped the version words would count the experimental warning's neighbours; one that matched the
    # plain "supported" wording would count the warning itself
    assert _counts("is not supported by Nuitka", "Option --x is not supported by Nuitka on this platform")
    assert not _counts(_count_pattern(BAT), "Option --x is not supported by Nuitka on this platform")
    assert _counts("supported by Nuitka", REAL_EXPERIMENTAL)


def test_the_count_uses_no_pipe_and_reads_the_setup_log():
    count = BAT[BAT.index("\n:nuitka_unsupported_count\n"):BAT.index("\n:die\n")]
    line = next(l for l in count.splitlines() if l.startswith("for /f"))
    assert "^|" not in line and "|" not in line.replace("^>", ""), "no pipe: the for loop counts the lines itself"
    assert '"%LOG%"' in line, "the count must read the setup log"
    assert "2^>nul" in line, "a missing log must not print an error"


def test_the_sentence_is_safe_for_log_and_does_not_send_the_user_to_visual_studio():
    line = _sentence(BAT)
    text = line.split('call :log "', 1)[1].rsplit('"', 1)[0]
    assert not re.search(r"[<>|&%^()]", text), "call :log echoes unquoted: %r" % text
    assert VS_HINT_MARK not in text
    assert text.isascii()


def test_check_is_fail_safe_without_a_mark():
    body = BAT[BAT.index("\n:nuitka_unsupported_check\n"):BAT.index("\n:nuitka_unsupported_count\n")]
    assert "if not defined HP_NUI_BEFORE exit /b 0" in body, "no mark means nothing may be claimed"
    # the flag is cleared first, so a result from an earlier failure never carries over
    assert body.index('set "HP_NUI_UNSUPPORTED="') < body.index("call :nuitka_unsupported_count")


def test_scenarios_use_lines_the_count_agrees_with():
    pattern = _count_pattern(BAT)
    unsupported = re.search(r"\$stubLine = \"([^\"]*is not supported by Nuitka[^\"]*)\"", SCENARIOS)
    assert unsupported and _counts(pattern, unsupported.group(1)), "the stub of nuitka_unsupported/both_unsupported must be counted"
    other = re.search(r"\$stubLine = '([^']*)'", SCENARIOS)
    assert other and not _counts(pattern, other.group(1)), "the stub of nuitka_failother must not be counted"
    stale = re.search(r"\$staleLine = \"([^\"]*)\"", SCENARIOS)
    assert stale and _counts(pattern, stale.group(1)), "the stale line seeded by nuitka_failother must be one the count would take"
    assert "does not support this Python version yet" in SCENARIOS
    assert "does not support this Python version yet" in _sentence(BAT)
