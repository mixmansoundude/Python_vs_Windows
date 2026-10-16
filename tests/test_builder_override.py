"""Item 71: the PVW_BUILDER super-user override (auto|pyinstaller|nuitka|both).

run_setup.bat cannot run on Linux, so these are static scans that pin the places the override has to
take effect and the order they must appear in; tests/selfapps_pvw_builder.ps1 proves the behavior on
Windows. The order matters because a guard that sits after the action it is meant to prevent does
nothing: the fallback guard must come before the Nuitka install, and the offer guard before the prompt.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BAT = (REPO_ROOT / "run_setup.bat").read_text(encoding="utf-8", errors="replace")


def _between(start_label: str, end_label: str) -> str:
    """Text from one label line to another. Subroutines here have inner labels, so the end is named."""
    start = BAT.find("\n:%s\n" % start_label)
    end = BAT.find("\n:%s\n" % end_label, start + 1)
    assert start != -1 and end != -1, "labels :%s / :%s not found" % (start_label, end_label)
    return BAT[start:end]


def test_parse_sets_a_default_and_each_choice():
    default = BAT.find('set "HP_BUILDER=auto"')
    assert default != -1, "HP_BUILDER must default to auto"
    for choice in ("pyinstaller", "nuitka", "both"):
        line = 'if /I "%%PVW_BUILDER%%"=="%s" set "HP_BUILDER=%s"' % (choice, choice)
        assert BAT.find(line) > default, "missing or misplaced parse line for %s" % choice


def test_unrecognized_value_warns_without_echoing_it():
    warn = "PVW_BUILDER is not one of auto, pyinstaller, nuitka or both; using auto."
    assert BAT.count(warn) == 1
    line = next(l for l in BAT.splitlines() if warn in l)
    assert "%PVW_BUILDER%" not in line.split("call :log", 1)[1], "the unrecognized value must not be echoed"


def test_fallback_guard_comes_before_the_nuitka_install():
    body = _between("try_nuitka_tier_a", "die")
    guard = body.find('if /I "%HP_BUILDER%"=="pyinstaller"')
    install = body.find("-q nuitka")
    assert guard != -1 and install != -1
    assert guard < install, "the pyinstaller guard must run before Nuitka is installed"
    assert "exit /b 1" in body[guard:install], "the guard must return failure so the caller reports the PyInstaller failure"


def test_nuitka_choice_skips_pyinstaller_in_the_build_block():
    start = BAT.find('if /I "%HP_BUILDER%"=="nuitka" (')
    forced = BAT.find("if defined HP_TEST_FORCE_PYINSTALLER_FAIL (")
    assert start != -1 and forced != -1 and start < forced
    block = BAT[start:forced]
    assert "call :try_nuitka_tier_a" in block
    assert "reason=builder_nuitka" in block
    assert "-m PyInstaller" not in block, "the nuitka branch must not run PyInstaller"


def test_offer_guards_come_before_the_prompt():
    body = _between("offer_optimized_build", "try_fast_exe")
    prompt = body.find("echo *** Your app is ready. ***")
    assert prompt != -1
    pyi = body.find('if /I "%HP_BUILDER%"=="pyinstaller" exit /b 0')
    both = body.find('if /I "%HP_BUILDER%"=="both" goto')
    assert -1 < pyi < prompt, "pyinstaller must skip the offer before it is shown"
    assert -1 < both < prompt, "both must start the build before the prompt is shown"
    assert "PVW_BUILDER=both: building the optimized version now without asking." in body, (
        "the both choice must say it starts without asking"
    )
    assert "starts your program once more for up to 30 seconds" in body[body.find(":optbuild_both"):], (
        "the both choice must say it runs the program once more"
    )


def test_fast_path_explains_why_no_build_ran():
    body = _between("try_fast_exe", "write_fast_hash")
    assert "PVW_BUILDER=%HP_BUILDER%: the cached EXE is still fresh" in body


def test_override_is_documented_in_the_interconnect_map():
    text = (REPO_ROOT / "docs" / "agent-interconnect.md").read_text(encoding="utf-8", errors="replace")
    assert re.search(r"\bPVW_BUILDER\b", text), "PVW_BUILDER needs an entry in docs/agent-interconnect.md"
    for choice in ("auto", "pyinstaller", "nuitka", "both"):
        assert choice in text[text.find("PVW_BUILDER"):], "the interconnect entry must name the choice %s" % choice
