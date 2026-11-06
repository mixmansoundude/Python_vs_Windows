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
UNTRACED_SHALLS: Dict[str, str] = {
    "REQ-003.1": "gap: rows are tagged REQ-003 (selfapps_unc, selfapps_justme, selfapps_exefail) but none names this shall; the Windows 10 (1809) floor and the curl and PowerShell it relies on are shown only by the runners",
    "REQ-003.2": "gap: selfapps_justme and the provider rows install Miniconda under %PUBLIC%\\Documents\\Miniconda3 and are tagged REQ-003; none asserts the install folder as this shall",
    "REQ-003.3": "gap: self.litter.appfolder (selftest.ps1) proves what the bootstrapper leaves in the folder, but no row asserts that the working files and the build output are created in the folder where it was started",
    "REQ-003.6": "gap: self.exe.smokerun.cwd_consistency (tagged REQ-018) shows the verification run of a fresh build and the cached-EXE fast path agree on a program that opens a relative config.json; the optimized build's verification run and the --hidden-import repair re-run still start the program from dist (the pushd dist sites of run_setup.bat, deferred by backlog Item 38), and no row covers the interpreter run, the post-execution checkpoint or the failure-hint capture; the code gaps and their rows are with the thread that owns the 96/97 bundle",
    "REQ-005.1.6": "gap: self.depmerge.later.baseline shows the requirements.txt and header records exist after a clean run; no row shows that a failed or partial install records nothing, so the next run sees the same changes again",
    "REQ-005.1.12": "gap: tests/test_dep_merge.py LaterRun.test_a_header_we_did_not_write_keeps_a_package_alive pins the merge half (an unrecorded header keeps its package in the merged list); no row shows the header file itself is never removed from",
    "REQ-005.1.13": "gap: tests/test_dep_merge.py InternalError pins the helper's exit 3; no row or test makes the merge fail and shows the highest ranked input used alone with the [WARN] (:dm_fallback)",
    "REQ-005.1.14": "gap: same missing scenario as REQ-005.1.13; no row shows the run going on after a merge that could not run",
    "REQ-007.12": "unit: tests/test_collect_submodules.py::GatingMatrix a curated package is collected only when the program uses it and the interpreter has it installed, so an unused library never enters the build",
    "REQ-007.17": "gap: no row answers yes to the system-Python build question; doing so would install PyInstaller into the runner's own system Python (self.sysbuild.decline, .nuitka_prompt and .ci_marker stop at the question)",
    "REQ-007.20": "gap: no check reads every message of the build step; self.exe.build.xfail reads the PyInstaller failure messages, and the word executable in the other messages is not searched",
    "REQ-008.2": "gap: no lane has the NI-VISA driver installed (the hosted runners reach install_failed with installer exit code -125202), so the [VISA] present branch is never taken by a row and no row shows that a present driver is neither downloaded nor installed again; faking the registry value would need a write to HKLM",
    "REQ-008.5": "unit: tests/test_detect_visa.py::VisaDetection a nested folder is scanned (result 2, a match below a subfolder), folders starting with ~ or . and files starting with ~ are skipped, a file that is not .py is skipped",
    "REQ-008.6": "unit: tests/test_detect_visa.py::VisaDetection import pyvista, import vision and import pyviscoelastic are not matches, a dotted submodule import of pyvisa still is",
    "REQ-008.12": "inspection: run_setup.bat :: set \"HP_VISA_T=30\"\nthe wait of the timed choice in :visa_subfolder_gate; self.nivisa.subfolder.timeout shortens it to 2 seconds with a test setting to stay fast, so no row waits the full 30 seconds",
    "REQ-008.14": "gap: no row runs the subfolder-only question with NOINPUT or HP_NONINTERACTIVE as the only signal (selfapps_pyvisa_subfolder.ps1 sets HP_CI_LANE when none is set, and self.offers.* covers only the four elective offers of REQ-018.9); only the CI marker is shown to skip the wait",
    "REQ-008.15": "gap: self.nivisa.subfolder.declined and .accepted do not list the packages of the environment; no row shows the Python pyvisa package installed after either answer",
    "REQ-012.5": "gap: no row reads the console panel; self.skiphooks.exe_only reads the setup log only, so the neutral note 'EXE verification was skipped by request' and the absence of the unverified caveat are never asserted",
    "REQ-013.1": "inspection: run_setup.bat :: if not \"%HP_TEST_CONDA_DL_FALLBACK%\"==\"1\" call :check_net_after_dl_fail\nthe call after a failed primary Miniconda download (the uv download has the same call, behind HP_TEST_UV_DL_FALLBACK); self.ux.connectivity.online reaches the check by a forced call and the self.dl.* rows skip it by design (the failure is the test's own), so no row makes a real primary download fail and watches the check run before the secondary URL",
    "REQ-013.3": "gap: self.ux.connectivity.online reaches the reachable branch and retries the whole scenario, but no row makes the first ICMP echo or the first HTTPS request fail and the second answer, so the repeat of each probe is never asserted (a counter loop in :check_net_after_dl_fail that the forced offline outcome skips)",
    "REQ-013.10": "gap: self.ux.connectivity.offline.conda.skip passes when no Miniconda download was attempted, which is every lane that has Miniconda installed, so the skip line is never required; a row would need a run with no Miniconda (a fresh PUBLIC folder, as selfapps_provider_memory does) and offline mode chosen",
    "REQ-013.11": "gap: no row requires the 'Offline mode: skipping get-pip.py download' line; the venv and embed rows that set HP_OFFLINE_MODE carve the get-pip.py download out of the skip with a test hook, so no row requires the line",
    "REQ-013.12": "gap: no row has an installed Miniconda or uv, chooses offline mode and shows the installed one used without a download; self.ux.connectivity.offline.uv.skip and .conda.skip look at the skip lines only",
    "REQ-013.14": "gap: the --retry 3 flag of the curl calls in :download_miniconda_exe, :download_get_pip and :embed_dl_retry is never asserted, by a row or a static scan; a stub curl that fails twice would show it",
    "REQ-013.15": "gap: the PowerShell second method (Invoke-WebRequest) of the same three downloads is never asserted; self.dl.conda.fallback and self.dl.uv.fallback make both methods fail on the primary URL without checking that the second method ran",
    "REQ-013.17": "gap: self.embed.dl.retry fails the download once (HP_TEST_FORCE_EMBED_DL_FAIL_ONCE); no hook makes the checksum check or the extraction fail, so the second download after those two failures is never asserted",
    "REQ-013.18": "gap: self.embed.version.swap, .floor, .ceiling and .range (REQ-009) show the folder replacement succeed; no row makes it fail and shows the second and third attempt with the pause between them",
    "REQ-015.7": "gap: self.litter.appfolder (REQ-015.6) lists the files the user keeps under their own names, but its allow list is written by hand in the row; no row asserts that each file the bootstrapper writes for the user to keep or share (requirements.txt, runtime.txt, the EXE in dist) is free of the tilde",
    "REQ-015.8": "gap: no row deletes every file whose name starts with ~ in a program folder and shows that the next run still finishes with state ok and leaves the user's own files as they were",
    "REQ-016.6": "gap: self.postflight.runline.verbatim (REQ-016.5) reads the briefing of a run whose EXE was verified; the briefing of a run whose EXE could not be verified (the caveat rows) is never searched for the command",
    "REQ-016.7": "gap: tests/selfapps_gui_timeout_hint.ps1 and tests/selfapps_hidden_import*.ps1 reach the caveat briefing and keep the number-level tag; none of them asserts the sentence that the environment was set up and packaging finished without a fatal error, or the absence of a claim that the dependency installation was verified",
    "REQ-016.8": "inspection: run_setup.bat :: rem REQ-016: retain terminal window on success so user can read the output.\nthe pause that ends :success, and the one in :die (rem REQ-016: retain terminal window on error), each behind if not defined HP_CI_LANE; every CI lane carries the marker, so no row reaches a pause and the shall is read from the code",
    "REQ-018.5": "gap: the warning is :warn_user_code_launch; self.cascade.timed matches only its dependency-incomplete note and the harness row batch.smoke.kill_warn only the hidden-import wording, so no row asserts the throwaway-check warning before the verification run",
    "REQ-018.6": "unit: tests/test_exe_smokerun.py::ActivityAwareStop output before the deadline keeps the run going past 30 seconds, with or without a trailing newline; KillTimeout in the same file shows a silent hang is stopped and 30000 ms is the default",
    "REQ-018.7": "gap: the 30 second cap on the --hidden-import re-verification run is an inline PowerShell WaitForExit(30000) in :hidden_import_recover that no row or unit test reads",
    "REQ-018.13": "unit: tests/test_runtime_module_scan.py::WhatIsNotReported standard library names and a module next to the script are not reported; the cached-EXE skip is the scan's no-interpreter return",
    "REQ-018.14": "gap: self.runtime.install.accept and .decline show the question comes before the install, the edit and the rebuild; no row shows it is asked once per invocation (HP_RTI_OFFERED across a cascade tier) or the 30 second limit (the CI gate answers or declines first)",
    "REQ-018.16": "gap: no row runs a system Python, a missing interpreter or a fallback-built EXE through the offer; the 'Runtime install: not offered' line and the not_offered state are never asserted",
    "REQ-018.19": "unit: tests/test_runtime_module_scan.py::BatchCallSites the rebuild adds --hidden-import and --collect-submodules for each installed module and puts both on the PyInstaller command line; self.runtime.install.accept shows the first flag by behavior (the check run is clean only if the EXE holds the package), nothing runs the second flag",
    "REQ-018.20": "gap: self.runtime.install.accept shows the check run and the verified line; the other branch (the output still names the module, state still_missing) has no row",
    "REQ-018.21": "gap: no row makes the install or the rebuild fail, so the install_failed and rebuild_failed states and the absence of a provider cascade after them are never asserted",
    "REQ-018.22": "gap: tests/test_runtime_module_scan.py PackagesAndAppend pins the module-to-package table (cv2, PIL) and the unchanged-name rule; no row asserts that the prompt lists every package it would install",
    "REQ-018.30": "unit: tests/test_window_confirm.py::WindowQuestionWiring the question says the check stops the program after about 30 seconds (static wording pin)",
    "REQ-020.5": "gap: self.corrupt.conda.heal.accept reaches the Y branch with the deletion and the Miniconda download skipped (HP_TEST_SKIP_EVICT), and self.corrupt.conda.real_locked shows a deletion that fails; no row deletes a damaged installation, installs a fresh Miniconda in its place and shows the run continuing (a 150 MB download)",
    "REQ-020.9": "gap: no row makes the fresh Miniconda install fail after the eviction, so exit code 4 and the 'Fresh Miniconda install failed after self-healing eviction.' line are never asserted",
    "REQ-023.1": "inspection: run_setup.bat :: \"%HP_PY%\" -c \"import sys\"\nthe probe command that :try_venv_fallback runs after the venv is created; self.venv.canary_fail forces the probe's failure with a hook that jumps past the command, so no row makes the real command fail",
}


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
