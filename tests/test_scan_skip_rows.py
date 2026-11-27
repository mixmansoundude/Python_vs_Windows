"""Tests for the two rows of README REQ-018.13, Item 124: self.runtime.scan.skipped and self.runtime.scan.fastpath.

REQ-018.13 says the bootstrapper shall not report a standard library module or a module that sits next to the script as missing, and
shall skip the check of REQ-018.10 on the cached-EXE fast path. Until Item 124 the shall was held by unit tests of the helper
(tests/test_runtime_module_scan.py::WhatIsNotReported) and by the fact that the fast path has no interpreter yet; no bootstrap ever
showed either half. tests/selfapps_runtime_modnotfound.ps1 now does, in its third scenario:
  * skipped:  a program that prints tracebacks for three names (a package nobody installed, a standard library module Windows does not
              have, and a module file written next to the script) and exits 0. The console, the closing reminder and the rows written
              to HP_NDJSON must name the package, once, and nothing else; naming it is also what shows the scan ran. The program
              imports the standard library name and also raises the classic "No module named" sentence for it by hand: Python 3.15
              in a frozen EXE words the real failure "Standard library module 'x' was not found" (first run, 45973055196), which the
              scan never reads, so without the hand-raised line the standard library half of the row would pass on nothing.
  * fastpath: the second bootstrap of the same folder, forced through the probe branch so that the cached EXE's traceback reaches the
              console, must say the cached EXE was launched, show the traceback after that line and report nothing.
What this file holds, and why:
  * the script's judging functions run through a real pwsh in strict mode (tests/judge_support.py) on consoles built from the batch
    file's own echo lines, so a reworded warning, reminder or launch line fails HERE, with the judge's problem text, before a Windows
    run; a good console is clean and each wrong one is named once;
  * mutation cases that remove one comparison from a copy of the script and must see the matching wrong console pass, so a judge that
    quietly stopped judging cannot stay green;
  * the batch side of the fast-path skip (the interpreter variable is cleared before the first fast-path call, the scan returns at once
    without one, the fast-path subroutine never calls the scan itself) and the helper run the way the batch runs it, on the fixture's
    own text, with the two rules (standard library names, a module file in the app folder) removed one at a time as controls;
  * the script's literal row ids and tags, the fixture, the second bootstrap's flag and the verdicts, the workflow upload paths and the
    registry, as text.
ASCII only.
"""
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import PWSH, case, cut_block, live_bat, mutate, norm, registry_ids, run_cases, step_block  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "tests" / "selfapps_runtime_modnotfound.ps1"
HELPER = REPO / "tools" / "runtime_module_scan.py"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
ROWS = ("self.runtime.scan.skipped", "self.runtime.scan.fastpath")
TAG = "REQ-018.13"
JUDGES = ["Get-NamedModules", "Get-HeadsUpModules", "Get-ScanSkipProblems", "Get-FastPathScanProblems"]
STAMP = "15.11.2026 12:34:56,78 "  # what :log puts in front of a line: %date% %time%
EXE = "dist\\_selftest_runtime_scan_skips.exe"


# --- the real wording, read from the batch file ---------------------------------------------------------------------------------------

def bat_text():
    return (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")


def one_live(block, pattern):
    hits = [ln.strip() for ln in live_bat(block) if re.search(pattern, ln)]
    assert len(hits) == 1, "expected one live line matching %r, found %r" % (pattern, hits)
    return hits[0]


def logged_text(line):
    """The text a `call :log "..."` line prints."""
    return re.match(r'call :log "(.*)"$', line).group(1)


def real_warn_line(bat, module):
    block = cut_block(bat, ":report_runtime_missing_module", ":print_runtime_missing_reminder")
    line = one_live(block, r'^call :log "\[WARN\] Your program needed the module ')
    return STAMP + logged_text(line).replace("%HP_RTM_MOD%", module)


def real_reminder_lines(bat, modules):
    block = cut_block(bat, ":print_runtime_missing_reminder", ":rtm_where")
    heading = one_live(block, r"^echo \*\*\* HEADS UP: ")[len("echo "):]
    item = re.search(r"do echo (\*\*\*   %%M)$", one_live(block, r"for /f .* do echo \*\*\*   %%M"))
    tail = one_live(block, r"^echo \*\*\* Add them, ")[len("echo "):].replace("%HP_RTM_WHERE%", "requirements.txt")
    return [heading] + [item.group(1).replace("%%M", m) for m in modules] + [tail]


def real_launch_line(bat):
    block = cut_block(bat, ":try_fast_exe_probe", ":try_fast_exe_discard_check")
    line = one_live(block, r'^call :log "\[INFO\] Launching your program now via the cached standalone EXE')
    return STAMP + logged_text(line).replace("%HP_FAST_EXE%", EXE)


def real_discard_line(bat):
    block = cut_block(bat, ":try_fast_exe_discard_check", ":write_fast_hash")
    line = one_live(block, r'discarding cached EXE and rebuilding')
    return STAMP + logged_text(re.search(r'call :log ".*"', line).group(0)).replace("%HP_SMOKE_RC%", "1")


TRACE = ["Traceback (most recent call last):",
         '  File "PyInstaller\\loader\\pyimod02_importers.py", line 1, in import_module',
         "ModuleNotFoundError: No module named '%s'"]


def trace_lines(*modules):
    out = []
    for m in modules:
        out.extend(t % m if "%s" in t else t for t in TRACE)
    return out


def stderr_of(*modules):
    return "\r\n".join(trace_lines(*modules)) + "\r\n"


SITE_HINT = ". Site initialization is disabled, did you forget to add the site-packages directory to sys.path or to enable your virtual environment?"


def stderr_python315(package, stdlib, sibling):
    """The stderr of the first Windows run of the row (run 45973055196): Python 3.15 inside a frozen EXE. A missing package or module
    keeps the classic sentence, with the site initialization hint behind it (a frozen EXE runs without site); a missing standard
    library module is worded "Standard library module ... was not found" and holds no "No module named" at all."""
    out = []
    for sentence in ("No module named '%s'%s" % (package, SITE_HINT),
                     "Standard library module '%s' was not found" % stdlib,
                     "No module named '%s'%s" % (sibling, SITE_HINT)):
        out.extend([TRACE[0], TRACE[1], "ModuleNotFoundError: " + sentence])
    return "\r\n".join(out) + "\r\n"


def stderr_of_fixture_python315(package, stdlib, sibling):
    """The same run with the fixture's last block, which raises the classic sentence for the standard library name by hand."""
    return stderr_python315(package, stdlib, sibling) + stderr_of(stdlib)


def first_run(bat, **over):
    """The console of the first bootstrap: the tracebacks live-tee'd, one warning, the reminder at the end."""
    parts = dict(
        stderr_modules=("xlsxwriter", "fcntl", "rtmsibling"),
        warned=("xlsxwriter",),
        listed=("xlsxwriter",),
        extra_warn=(),
        eol="\r\n",
    )
    parts.update(over)
    lines = [STAMP + "[INFO] Running entry script smoke test via packaged EXE."]
    lines += trace_lines(*parts["stderr_modules"])
    lines += [STAMP + "[INFO] Entry smoke exit=0"]
    for m in parts["warned"]:
        lines += [real_warn_line(bat, m),
                  STAMP + "[WARN] The program may have kept running anyway. To fix it, add %s, or the package that provides it, to requirements.txt and run this file again." % m]
    for m in parts["extra_warn"]:
        lines += [real_warn_line(bat, m)]
    if parts["listed"] is not None:
        lines += [""] + real_reminder_lines(bat, parts["listed"])
    return parts["eol"].join(lines) + parts["eol"]


def second_run(bat, **over):
    """The console of the second bootstrap: the cached EXE is launched, prints its traceback, and nothing is reported."""
    parts = dict(launch=True, trace=True, before="", after_lines=(), eol="\r\n")
    parts.update(over)
    lines = [STAMP + "[INFO] Python file count: 2"]
    if parts["before"]:
        lines += [parts["before"]]
    if parts["launch"]:
        lines += [real_launch_line(bat)]
    else:
        lines += [STAMP + "[INFO] Fast path: reusing " + EXE]
    if parts["trace"]:
        lines += trace_lines("xlsxwriter")
    lines += ["runtime app ok", STAMP + "[INFO] Entry smoke exit=0", STAMP + "[STATUS] Run Status: SUCCESS (Exit Code: 0)"]
    lines += list(parts["after_lines"])
    return parts["eol"].join(lines) + parts["eol"]


def skip_cases(bat):
    c = []
    ok = dict(StderrText=stderr_of("xlsxwriter", "fcntl", "rtmsibling"), RowModules=["xlsxwriter"])
    c.append(case("skip_good", "Get-ScanSkipProblems", ConsoleText=first_run(bat), **ok))
    c.append(case("skip_good_lf_only", "Get-ScanSkipProblems", ConsoleText=first_run(bat, eol="\n"), **ok))
    # What Python 3.15 prints inside a frozen EXE: the fixture's hand-raised classic line makes the run good, the run without it is the
    # first Windows run of the row (45973055196), whose precondition for the standard library name failed.
    c.append(case("skip_good_python315", "Get-ScanSkipProblems", ConsoleText=first_run(bat),
                  StderrText=stderr_of_fixture_python315("xlsxwriter", "fcntl", "rtmsibling"), RowModules=["xlsxwriter"]))
    c.append(case("skip_stderr_python315_sentence_only", "Get-ScanSkipProblems", ConsoleText=first_run(bat),
                  StderrText=stderr_python315("xlsxwriter", "fcntl", "rtmsibling"), RowModules=["xlsxwriter"]))
    for gone in ("xlsxwriter", "fcntl", "rtmsibling"):
        rest = tuple(m for m in ("xlsxwriter", "fcntl", "rtmsibling") if m != gone)
        c.append(case("skip_stderr_lacks_" + gone, "Get-ScanSkipProblems", ConsoleText=first_run(bat),
                      StderrText=stderr_of(*rest), RowModules=["xlsxwriter"]))
    c.append(case("skip_console_reports_fcntl", "Get-ScanSkipProblems", ConsoleText=first_run(bat, extra_warn=("fcntl",)), **ok))
    c.append(case("skip_console_reports_rtmsibling", "Get-ScanSkipProblems", ConsoleText=first_run(bat, extra_warn=("rtmsibling",)), **ok))
    c.append(case("skip_console_reports_other", "Get-ScanSkipProblems", ConsoleText=first_run(bat, extra_warn=("PIL",)), **ok))
    c.append(case("skip_scan_did_not_run", "Get-ScanSkipProblems", ConsoleText=first_run(bat, warned=(), listed=None),
                  StderrText=stderr_of("xlsxwriter", "fcntl", "rtmsibling"), RowModules=[]))
    c.append(case("skip_named_twice", "Get-ScanSkipProblems", ConsoleText=first_run(bat, extra_warn=("xlsxwriter",)), **ok))
    c.append(case("skip_reminder_lists_fcntl", "Get-ScanSkipProblems", ConsoleText=first_run(bat, listed=("xlsxwriter", "fcntl")), **ok))
    c.append(case("skip_reminder_missing", "Get-ScanSkipProblems", ConsoleText=first_run(bat, listed=None), **ok))
    c.append(case("skip_rows_name_fcntl_too", "Get-ScanSkipProblems", ConsoleText=first_run(bat),
                  StderrText=stderr_of("xlsxwriter", "fcntl", "rtmsibling"), RowModules=["xlsxwriter", "fcntl"]))
    c.append(case("skip_rows_empty", "Get-ScanSkipProblems", ConsoleText=first_run(bat),
                  StderrText=stderr_of("xlsxwriter", "fcntl", "rtmsibling"), RowModules=[]))
    return c


def fast_cases(bat):
    c = []
    c.append(case("fast_good", "Get-FastPathScanProblems", ConsoleText=second_run(bat), RowModules=[]))
    c.append(case("fast_good_lf_only", "Get-FastPathScanProblems", ConsoleText=second_run(bat, eol="\n"), RowModules=[]))
    c.append(case("fast_no_launch_line_with_trace", "Get-FastPathScanProblems", ConsoleText=second_run(bat, launch=False), RowModules=[]))
    c.append(case("fast_plain_fast_path", "Get-FastPathScanProblems", ConsoleText=second_run(bat, launch=False, trace=False), RowModules=[]))
    c.append(case("fast_launched_twice", "Get-FastPathScanProblems",
                  ConsoleText=second_run(bat, before=real_launch_line(bat)), RowModules=[]))
    c.append(case("fast_discarded", "Get-FastPathScanProblems",
                  ConsoleText=second_run(bat, after_lines=(real_discard_line(bat),)), RowModules=[]))
    c.append(case("fast_no_traceback", "Get-FastPathScanProblems", ConsoleText=second_run(bat, trace=False), RowModules=[]))
    before_launch = "\r\n".join(trace_lines("xlsxwriter") + [real_launch_line(bat), "runtime app ok"]) + "\r\n"
    c.append(case("fast_traceback_only_before_launch", "Get-FastPathScanProblems", ConsoleText=before_launch, RowModules=[]))
    c.append(case("fast_reports_module", "Get-FastPathScanProblems",
                  ConsoleText=second_run(bat, after_lines=(real_warn_line(bat, "xlsxwriter"),)), RowModules=[]))
    c.append(case("fast_prints_reminder", "Get-FastPathScanProblems",
                  ConsoleText=second_run(bat, after_lines=tuple([""] + real_reminder_lines(bat, ["xlsxwriter"]))), RowModules=[]))
    c.append(case("fast_writes_row", "Get-FastPathScanProblems", ConsoleText=second_run(bat), RowModules=["xlsxwriter"]))
    return c


def helper_cases(bat):
    warn = real_warn_line(bat, "xlsxwriter")
    return [
        case("named_in_order", "Get-NamedModules",
             ConsoleText="\r\n".join([real_warn_line(bat, "aaa"), STAMP + "[WARN] The program may have kept running anyway.", real_warn_line(bat, "bbb")])),
        case("named_none", "Get-NamedModules", ConsoleText="[INFO] nothing to say\r\n"),
        case("named_one", "Get-NamedModules", ConsoleText=warn + "\r\n"),
        case("listed_in_order", "Get-HeadsUpModules", ConsoleText="\r\n".join(["x"] + real_reminder_lines(bat, ["aaa", "bbb"]) + ["***   not_in_the_list"])),
        case("listed_none", "Get-HeadsUpModules", ConsoleText="\r\n".join(real_reminder_lines(bat, []))),
        case("listed_without_heading", "Get-HeadsUpModules", ConsoleText="***   xlsxwriter\r\n"),
    ]


ALL_CASES = None


def all_cases(bat):
    return skip_cases(bat) + fast_cases(bat) + helper_cases(bat)


# --- the batch side ------------------------------------------------------------------------------------------------------------------

def fast_path_mechanism_problems(bat):
    """Why the scan cannot run on the cached-EXE fast path: no interpreter exists yet, and the scan returns at once without one."""
    found = []
    t = norm(bat)
    lines = t.split("\n")
    scan = cut_block(bat, ":scan_runtime_missing_module", ":report_runtime_missing_module")
    if scan is None:
        return ["the subroutine :scan_runtime_missing_module could not be cut out of run_setup.bat"]
    live = [ln.strip() for ln in live_bat(scan)][1:]
    if not live or live[0] != "if not defined HP_PY exit /b 0":
        found.append("the first live line of :scan_runtime_missing_module must be 'if not defined HP_PY exit /b 0', found %r" % (live[:1],))
    live_all = [(i, ln.strip()) for i, ln in enumerate(lines) if ln.strip() and not re.match(r"(?i)\s*(rem\b|::)", ln)]
    cleared = [i for i, ln in live_all if ln == 'set "HP_PY="']
    first_call = [i for i, ln in live_all if ln == "call :try_fast_exe"]
    if not cleared or not first_call:
        found.append("run_setup.bat has no clear of HP_PY or no top-level call of :try_fast_exe")
        return found
    if not cleared[0] < first_call[0]:
        found.append("HP_PY is not cleared before the first call of :try_fast_exe")
    between = [ln for i, ln in live_all if cleared[0] < i < first_call[0] and re.match(r'(?i)set\s+"HP_PY=[^"]', ln)]
    if between:
        found.append("HP_PY is given a value between its clear and the first fast-path call: %r" % between)
    fast = cut_block(bat, ":try_fast_exe", ":try_fast_exe_probe")
    if fast is None or any("scan_runtime_missing_module" in ln for ln in live_bat(fast)):
        found.append(":try_fast_exe must not call the scan itself")
    probe = cut_block(bat, ":run_failfast_probe", ":report_launch_failure")
    calls = [ln.strip() for ln in live_bat(probe or []) if "scan_runtime_missing_module" in ln]
    if calls != ['call :scan_runtime_missing_module "%HP_PROBE_SITE%" "%HP_PROBE_ERR%"']:
        found.append(":run_failfast_probe must call the scan exactly once, with its site and its stderr file, found %r" % calls)
    return found


class FastPathMechanism(unittest.TestCase):
    def setUp(self):
        self.bat = bat_text()

    def test_the_real_batch_file_is_in_order(self):
        self.assertEqual(fast_path_mechanism_problems(self.bat), [])

    def test_a_scan_that_starts_without_the_interpreter_check_is_reported(self):
        bad = mutate(self.bat, "if not defined HP_PY exit /b 0\nif not exist \"%~2\" exit /b 0\n", "if not exist \"%~2\" exit /b 0\n")
        self.assertTrue(any("first live line" in f for f in fast_path_mechanism_problems(bad)))

    def test_an_interpreter_set_before_the_fast_path_is_reported(self):
        # LF here: read_text has turned the file's CRLF into LF. The top-level call is the one inside the PYCOUNT test.
        anchor = 'if not "%PYCOUNT%"=="0" (\n  call :try_fast_exe\n)\n'
        bad = mutate(self.bat, anchor, 'set "HP_PY=C:\\early\\python.exe"\n' + anchor)
        self.assertTrue(any("HP_PY is given a value" in f for f in fast_path_mechanism_problems(bad)))

    def test_a_fast_path_that_calls_the_scan_itself_is_reported(self):
        bad = mutate(self.bat, 'set "HP_FASTPATH_TOKEN="\nset "HP_FAST_CHECK_PS=~fast_check.ps1"\n',
                     'set "HP_FASTPATH_TOKEN="\ncall :scan_runtime_missing_module fastpath "~run.err.txt"\nset "HP_FAST_CHECK_PS=~fast_check.ps1"\n')
        self.assertTrue(any("must not call the scan itself" in f for f in fast_path_mechanism_problems(bad)))

    def test_a_second_call_of_the_scan_in_the_probe_is_reported(self):
        bad = mutate(self.bat, 'call :scan_runtime_missing_module "%HP_PROBE_SITE%" "%HP_PROBE_ERR%"\n',
                     'call :scan_runtime_missing_module "%HP_PROBE_SITE%" "%HP_PROBE_ERR%"\ncall :scan_runtime_missing_module "%HP_PROBE_SITE%" "%HP_PROBE_ERR%"\n')
        self.assertTrue(any("exactly once" in f for f in fast_path_mechanism_problems(bad)))


# --- the helper, run the way the batch runs it, on the fixture's own text -------------------------------------------------------------

STDLIB_ABSENT_HERE = "fcntl" if os.name == "nt" else "msvcrt"  # a standard library name this interpreter cannot import
PACKAGE_ABSENT = "zz_item124_absent_package"


@unittest.skipUnless(hasattr(sys, "stdlib_module_names"), "the standard library rule needs Python 3.10 or newer")
class HelperOnTheFixtureText(unittest.TestCase):
    """The batch emits the helper into the app folder and starts it there, so the folder is sys.path[0] and a module file next to the
    script is found. The text is what the fixture's tracebacks print; the standard library name is one this machine lacks
    (fcntl on Windows, msvcrt elsewhere), which is what fcntl is on the machine of the row."""

    def run_helper(self, helper_source=None, stderr=None):
        with tempfile.TemporaryDirectory() as d:
            app = Path(d) / "app"
            app.mkdir()
            (app / "rtmsibling.py").write_text("VALUE = 1\n", encoding="ascii")
            text = stderr if stderr is not None else stderr_of(PACKAGE_ABSENT, STDLIB_ABSENT_HERE, "rtmsibling")
            (app / "~run.err.txt").write_text(text, encoding="ascii")
            source = helper_source if helper_source is not None else HELPER.read_text(encoding="utf-8")
            (app / "~runtime_module_scan.py").write_text(source, encoding="utf-8")
            other = Path(d) / "elsewhere"
            other.mkdir()
            proc = subprocess.run([sys.executable, str(app / "~runtime_module_scan.py"), str(app / "~run.err.txt")],
                                  cwd=str(other), capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            return proc.stdout.split()

    def test_only_the_package_nobody_installed_is_named(self):
        self.assertEqual(self.run_helper(), [PACKAGE_ABSENT])

    def test_without_the_standard_library_rule_the_standard_library_name_is_named(self):
        source = mutate(HELPER.read_text(encoding="utf-8"), "top in out or top in stdlib or not _NAME.match(top)", "top in out or not _NAME.match(top)")
        self.assertIn(STDLIB_ABSENT_HERE, self.run_helper(source))

    def test_without_the_search_of_the_app_folder_the_sibling_module_is_named(self):
        source = mutate(HELPER.read_text(encoding="utf-8"), "return importlib.util.find_spec(top) is not None", "return False")
        self.assertIn("rtmsibling", self.run_helper(source))

    def test_the_python_315_run_of_the_fixture_names_only_the_package(self):
        # Both shapes: the stderr of the first Windows run (no classic sentence for the standard library name) and the same run with the
        # fixture's hand-raised classic sentence.
        for text in (stderr_python315(PACKAGE_ABSENT, STDLIB_ABSENT_HERE, "rtmsibling"),
                     stderr_of_fixture_python315(PACKAGE_ABSENT, STDLIB_ABSENT_HERE, "rtmsibling")):
            self.assertEqual(self.run_helper(stderr=text), [PACKAGE_ABSENT], text)

    def test_the_hand_raised_classic_sentence_is_what_gives_the_standard_library_rule_something_to_skip(self):
        source = mutate(HELPER.read_text(encoding="utf-8"), "top in out or top in stdlib or not _NAME.match(top)", "top in out or not _NAME.match(top)")
        first_run_text = stderr_python315(PACKAGE_ABSENT, STDLIB_ABSENT_HERE, "rtmsibling")
        with_the_line = stderr_of_fixture_python315(PACKAGE_ABSENT, STDLIB_ABSENT_HERE, "rtmsibling")
        # Without the rule the first run's text still names nothing but the package: the rule was never exercised, the row passed on nothing.
        self.assertNotIn(STDLIB_ABSENT_HERE, self.run_helper(source, first_run_text))
        # With the classic sentence the same missing rule is visible.
        self.assertIn(STDLIB_ABSENT_HERE, self.run_helper(source, with_the_line))


def fixture_program():
    """The text of $skipApp, the program of the first bootstrap, cut out of the script."""
    m = re.search(r"\$skipApp = @'\n(.*?)\n'@", norm(SCRIPT.read_text(encoding="utf-8")), re.S)
    assert m, "the here-string $skipApp could not be cut out of tests/selfapps_runtime_modnotfound.ps1"
    return m.group(1) + "\n"


@unittest.skipUnless(hasattr(sys, "stdlib_module_names"), "the standard library rule needs Python 3.10 or newer")
class FixtureProgramRunsHere(unittest.TestCase):
    """The program of the first bootstrap run with this interpreter, in a folder that does not hold rtmsibling.py (the frozen EXE cannot
    import it either). Whatever this Python prints for the real imports, its stderr must hold the classic sentence for the standard
    library name, and the helper, run in a folder that does hold the sibling, must name nothing but the package."""

    def run_program(self):
        with tempfile.TemporaryDirectory() as d:
            work = Path(d)
            (work / "app.py").write_text(fixture_program(), encoding="ascii")
            return subprocess.run([sys.executable, str(work / "app.py")], cwd=str(work), capture_output=True, text=True, timeout=60)

    def test_the_program_exits_0_and_prints_the_classic_sentence_for_the_names_it_cannot_import(self):
        proc = self.run_program()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("runtime app ok", proc.stdout)
        self.assertIn("ModuleNotFoundError: No module named 'fcntl'", proc.stderr)
        self.assertIn("ModuleNotFoundError: No module named 'rtmsibling'", proc.stderr)
        if importlib.util.find_spec("xlsxwriter") is None:
            self.assertIn("ModuleNotFoundError: No module named 'xlsxwriter'", proc.stderr)

    def test_the_helper_names_only_the_package_on_that_stderr(self):
        proc = self.run_program()
        with tempfile.TemporaryDirectory() as d:
            app = Path(d) / "app"
            app.mkdir()
            (app / "rtmsibling.py").write_text("VALUE = 1\n", encoding="ascii")
            (app / "~run.err.txt").write_text(proc.stderr, encoding="utf-8")
            (app / "~runtime_module_scan.py").write_text(HELPER.read_text(encoding="utf-8"), encoding="utf-8")
            other = Path(d) / "elsewhere"
            other.mkdir()
            out = subprocess.run([sys.executable, str(app / "~runtime_module_scan.py"), str(app / "~run.err.txt")],
                                 cwd=str(other), capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        named = out.stdout.split()
        self.assertNotIn("fcntl", named)
        self.assertNotIn("rtmsibling", named)
        if importlib.util.find_spec("xlsxwriter") is None:
            self.assertEqual(named, ["xlsxwriter"])


# --- the script as text ------------------------------------------------------------------------------------------------------------

def script_problems(text):
    t = norm(text)
    found = []
    for rid in ROWS:
        tags = re.findall(r"id\s*=\s*'%s'\s*\n\s*req\s*=\s*'([^']*)'" % re.escape(rid), t)
        if len(tags) != 2:
            found.append("%s must be written at 2 sites (the non-Windows skip and the real row) with a literal req tag, found %d" % (rid, len(tags)))
        found += ["%s carries the tag %r, expected %r" % (rid, g, TAG) for g in tags if g != TAG]
    for needle in ('"".join(("xlsx", "writer"))', '"".join(("fc", "ntl"))', '"".join(("rtm", "sibling"))'):
        if t.count(needle) < 1:
            found.append("the fixture of scenario 3 must join the module name %s at run time" % needle)
    if t.count("raise ModuleNotFoundError(\"No module named '\" + stdlib + \"'\")") != 1:
        found.append("the fixture of scenario 3 must raise the classic 'No module named' sentence for the standard library name by hand: "
                      "Python 3.15 words the real failure differently and the scan reads only the classic sentence")
    if t.count("'rtmsibling.py' = 'VALUE = 1'") != 1:
        found.append("scenario 3 must write rtmsibling.py next to the program")
    first = re.search(r"\$skipFirst = @\{(.*?)\}\n", t)
    second = re.search(r"\$skipSecond = @\{(.*)\}\n", t)
    if not first or "FolderName = '~selftest_runtime_scan_skips'" not in first.group(1) or "LogName = '~sk_run1.log'" not in first.group(1):
        found.append("the first bootstrap of scenario 3 must use the folder ~selftest_runtime_scan_skips and the log ~sk_run1.log")
    if not second:
        found.append("the second bootstrap of scenario 3 is missing")
    else:
        for need in ("FolderName = '~selftest_runtime_scan_skips'", "Again = $true", "LogName = '~sk_run2.log'", "NdjsonName = '~sub2.ndjson'",
                     "HP_TEST_FORCE_INTERACTIVE_PROBE = '1'"):
            if need not in second.group(1):
                found.append("the second bootstrap must carry %s" % need)
    if "Get-ScanSkipProblems -ConsoleText $k1.Console -StderrText $k1.ErrText -RowModules @($k1.RowModules)" not in t:
        found.append("the first row must judge the console, stderr and rows of its own run ($k1)")
    if "Get-FastPathScanProblems -ConsoleText $k2.Console -RowModules @($k2.RowModules)" not in t:
        found.append("the second row must judge the console and rows of its own run ($k2)")
    if "$skipPass = ($k1.RunExit -eq 0) -and ($k1.StatusState -eq 'ok') -and ($k1Problems.Count -eq 0)" not in t:
        found.append("$skipPass must require exit 0, state ok and no problem")
    if "$fastPass = ($k2.RunExit -eq 0) -and ($k2.StatusState -eq 'ok') -and ($k2Problems.Count -eq 0)" not in t:
        found.append("$fastPass must require exit 0, state ok and no problem")
    if "if (-not ($modPass -and $pPass -and $skipPass -and $fastPass)) { exit 1 }\nexit 0" not in t:
        found.append("the script must end with exit 1 for any red row and exit 0, and the verdict must include both new rows")
    return found


def shall_list_problems(text):
    return ["REQ-018.13 is still listed in UNTRACED_SHALLS although both rows are tagged with it"] if re.search(r'^\s*"REQ-018\.13":', text, re.M) else []


class ScriptAsText(unittest.TestCase):
    def setUp(self):
        self.text = SCRIPT.read_text(encoding="utf-8")

    def test_the_real_script_and_the_shall_list_are_in_order(self):
        self.assertEqual(script_problems(self.text), [])
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_a_row_that_stops_naming_the_shall_is_reported(self):
        bad = mutate(norm(self.text), "id      = 'self.runtime.scan.fastpath'\n    req     = 'REQ-018.13'\n    pass    = $fastPass",
                     "id      = 'self.runtime.scan.fastpath'\n    req     = 'REQ-018'\n    pass    = $fastPass")
        self.assertTrue(any("self.runtime.scan.fastpath carries the tag" in f for f in script_problems(bad)))

    def test_a_missing_skip_row_is_reported(self):
        bad = mutate(norm(self.text), "        id      = 'self.runtime.scan.skipped'\n        req     = 'REQ-018.13'\n        pass    = $true\n",
                     "        id      = 'self.runtime.scan.skipped_x'\n        req     = 'REQ-018.13'\n        pass    = $true\n")
        self.assertTrue(any("must be written at 2 sites" in f for f in script_problems(bad)))

    def test_a_second_bootstrap_without_the_force_flag_is_reported(self):
        bad = mutate(norm(self.text), "; EnvVars = @{ HP_TEST_FORCE_INTERACTIVE_PROBE = '1' } }", " }")
        self.assertTrue(any("HP_TEST_FORCE_INTERACTIVE_PROBE" in f for f in script_problems(bad)))

    def test_a_second_bootstrap_that_builds_the_folder_again_is_reported(self):
        bad = mutate(norm(self.text), "Again = $true; LogName = '~sk_run2.log'", "LogName = '~sk_run2.log'")
        self.assertTrue(any("Again = $true" in f for f in script_problems(bad)))

    def test_a_fixture_that_names_the_modules_plainly_is_reported(self):
        bad = mutate(norm(self.text), '"".join(("fc", "ntl"))', '"fcntl"')
        self.assertTrue(any("join the module name" in f for f in script_problems(bad)))

    def test_a_fixture_without_the_hand_raised_classic_sentence_is_reported(self):
        bad = mutate(norm(self.text), "raise ModuleNotFoundError(\"No module named '\" + stdlib + \"'\")",
                     "raise ModuleNotFoundError(\"Standard library module '\" + stdlib + \"' was not found\")")
        self.assertTrue(any("raise the classic" in f for f in script_problems(bad)))

    def test_a_missing_sibling_file_is_reported(self):
        bad = mutate(norm(self.text), "ExtraFiles = @{ 'rtmsibling.py' = 'VALUE = 1' }; ", "")
        self.assertTrue(any("rtmsibling.py next to the program" in f for f in script_problems(bad)))

    def test_a_verdict_that_leaves_out_a_row_is_reported(self):
        bad = mutate(norm(self.text), "-and $skipPass -and $fastPass)) { exit 1 }", "-and $skipPass)) { exit 1 }")
        self.assertTrue(any("must end with exit 1" in f for f in script_problems(bad)))

    def test_a_row_that_judges_the_other_runs_console_is_reported(self):
        bad = mutate(norm(self.text), "Get-FastPathScanProblems -ConsoleText $k2.Console", "Get-FastPathScanProblems -ConsoleText $k1.Console")
        self.assertTrue(any("console and rows of its own run" in f for f in script_problems(bad)))

    def test_a_shall_that_is_still_listed_as_a_gap_is_reported(self):
        self.assertTrue(shall_list_problems('    "REQ-018.13": "unit: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-018.130": "unit: x",\n'), [])


class WorkflowAndRegistry(unittest.TestCase):
    def setUp(self):
        self.wf = norm((REPO / ".github" / "workflows" / "batch-check.yml").read_text(encoding="utf-8"))

    def test_the_script_still_runs_on_the_real_lane_and_gates(self):
        step = step_block(self.wf, "selfapps_runtime_modnotfound.ps1")
        self.assertIsNotNone(step)
        self.assertIn("matrix.mode == 'real'", step)
        self.assertNotIn("continue-on-error", step)

    def test_the_logs_of_the_scenario_are_uploaded_in_both_slash_forms(self):
        for name in ("~sk_run1.log", "~sk_run2.log", "~setup.log", "~run.err.txt", "~sub.ndjson", "~sub2.ndjson"):
            self.assertIn("tests/~selftest_runtime_scan_skips/" + name, self.wf, name)
            self.assertIn("tests\\~selftest_runtime_scan_skips\\" + name, self.wf, name)

    def test_the_registry_names_both_rows_on_their_own_line(self):
        ids = registry_ids((REPO / "docs" / "agent-ndjson.md").read_text(encoding="utf-8"))
        for rid in ROWS:
            self.assertIn(rid, ids)


# --- the judges on synthetic consoles -------------------------------------------------------------------------------------------------

@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesOnSyntheticConsoles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bat = bat_text()
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, JUDGES, all_cases(cls.bat), d)

    def only(self, name, *needles):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        for needle in needles:
            self.assertIn(needle, found[0], (name, found))

    def test_a_console_built_from_the_real_echo_lines_is_clean(self):
        for name in ("skip_good", "skip_good_lf_only", "skip_good_python315", "fast_good", "fast_good_lf_only"):
            self.assertEqual(self.r[name], [], name)

    def test_the_skip_judge_names_a_missing_traceback_as_a_broken_precondition(self):
        for gone in ("xlsxwriter", "fcntl", "rtmsibling"):
            self.only("skip_stderr_lacks_" + gone, "precondition", gone)

    def test_the_skip_judge_does_not_take_the_python_315_sentence_for_the_classic_one(self):
        # The stderr of the first Windows run of the row: the standard library name is only in Python 3.15's own sentence, so there is
        # nothing for the scan's standard library rule to skip and the row would pass on nothing.
        self.only("skip_stderr_python315_sentence_only", "precondition", "fcntl", "No module named")

    def test_the_skip_judge_names_a_reported_standard_library_module(self):
        self.only("skip_console_reports_fcntl", "fcntl", "standard library")

    def test_the_skip_judge_names_a_reported_module_next_to_the_script(self):
        self.only("skip_console_reports_rtmsibling", "rtmsibling", "next to the script")

    def test_the_skip_judge_names_any_other_reported_module(self):
        self.only("skip_console_reports_other", "unexpected module", "PIL")

    def test_a_scan_that_did_not_run_is_three_problems(self):
        found = self.r["skip_scan_did_not_run"]
        self.assertEqual(len(found), 3, found)
        self.assertTrue(any("names xlsxwriter as missing 0 time(s)" in f for f in found), found)
        self.assertTrue(any("closing reminder" in f for f in found), found)
        self.assertTrue(any("HP_NDJSON" in f for f in found), found)

    def test_a_package_named_twice_is_one_problem(self):
        self.only("skip_named_twice", "xlsxwriter", "2 time(s)")

    def test_a_reminder_that_lists_more_than_the_package_is_named(self):
        self.only("skip_reminder_lists_fcntl", "closing reminder", "xlsxwriter,fcntl")
        self.only("skip_reminder_missing", "closing reminder", "''")

    def test_rows_that_name_more_or_less_than_the_package_are_named(self):
        self.only("skip_rows_name_fcntl_too", "HP_NDJSON", "xlsxwriter,fcntl")
        self.only("skip_rows_empty", "HP_NDJSON", "''")

    def test_the_fast_path_judge_needs_the_launch_line_and_the_traceback_after_it(self):
        self.only("fast_no_launch_line_with_trace", "precondition", "0 time(s)")
        self.only("fast_launched_twice", "precondition", "2 time(s)")
        self.only("fast_no_traceback", "precondition", "not on the console after the launch line")
        self.only("fast_traceback_only_before_launch", "precondition", "not on the console after the launch line")
        self.assertEqual(len(self.r["fast_plain_fast_path"]), 2, self.r["fast_plain_fast_path"])

    def test_the_fast_path_judge_rejects_a_discarded_cached_exe(self):
        self.only("fast_discarded", "discarded and rebuilt")

    def test_the_fast_path_judge_names_each_way_the_scan_could_have_run(self):
        self.only("fast_reports_module", "xlsxwriter", "skipped on the fast path")
        self.only("fast_prints_reminder", "closing reminder")
        self.only("fast_writes_row", "self.runtime.module_missing")

    def test_the_two_small_readers(self):
        self.assertEqual(self.r["named_in_order"], ["aaa", "bbb"])
        self.assertEqual(self.r["named_none"], [])
        self.assertEqual(self.r["named_one"], ["xlsxwriter"])
        self.assertEqual(self.r["listed_in_order"], ["aaa", "bbb"])
        self.assertEqual(self.r["listed_none"], [])
        self.assertEqual(self.r["listed_without_heading"], [])


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesCanFail(unittest.TestCase):
    """A judge that quietly stopped judging would pass every run, so each comparison is removed from a copy of the script and the one
    console that violates only that comparison must then pass."""

    @classmethod
    def setUpClass(cls):
        cls.bat = bat_text()
        cls.cases = {c["name"]: c for c in all_cases(cls.bat)}

    def run_mutated(self, old, new, name):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, new), encoding="utf-8")
            return run_cases(script, JUDGES, [self.cases[name]], d)[name]

    def test_a_judge_that_ignores_a_reported_standard_library_module_is_caught(self):
        got = self.run_mutated("if ($other -ceq 'fcntl') { [void]$problems.Add('the console reports fcntl, a standard library module, as a missing module') }",
                               "if ($other -ceq 'fcntl') { }", "skip_console_reports_fcntl")
        self.assertEqual(got, [])

    def test_a_judge_that_ignores_a_reported_sibling_module_is_caught(self):
        got = self.run_mutated("elseif ($other -ceq 'rtmsibling') { [void]$problems.Add('the console reports rtmsibling, a module that sits next to the script, as a missing module') }",
                               "elseif ($other -ceq 'rtmsibling') { }", "skip_console_reports_rtmsibling")
        self.assertEqual(got, [])

    def test_a_judge_that_ignores_a_repeated_report_is_caught(self):
        got = self.run_mutated("if ($xlsxCount -ne 1) {", "if ($xlsxCount -lt 1) {", "skip_named_twice")
        self.assertEqual(got, [])

    def test_a_judge_that_ignores_the_reminder_is_caught(self):
        got = self.run_mutated("if ($listedText -cne 'xlsxwriter') {", "if ($false) {", "skip_reminder_lists_fcntl")
        self.assertEqual(got, [])

    def test_a_judge_that_ignores_the_rows_is_caught(self):
        got = self.run_mutated("if ($rowText -cne 'xlsxwriter') {", "if ($false) {", "skip_rows_name_fcntl_too")
        self.assertEqual(got, [])

    def test_a_judge_that_ignores_the_precondition_is_caught(self):
        got = self.run_mutated("if ($StderrText -notmatch (\"ModuleNotFoundError: No module named '\" + $want + \"'\")) {", "if ($false) {", "skip_stderr_lacks_fcntl")
        self.assertEqual(got, [])

    def test_a_judge_that_takes_the_python_315_sentence_for_the_classic_one_is_caught(self):
        got = self.run_mutated("if ($StderrText -notmatch (\"ModuleNotFoundError: No module named '\" + $want + \"'\")) {",
                               "if ($StderrText -notmatch (\"ModuleNotFoundError: (No module named|Standard library module) '\" + $want + \"'\")) {",
                               "skip_stderr_python315_sentence_only")
        self.assertEqual(got, [])

    def test_a_fast_path_judge_that_does_not_need_the_launch_line_is_caught(self):
        got = self.run_mutated("if ($launches -ne 1) {", "if ($false) {", "fast_no_launch_line_with_trace")
        self.assertEqual(got, [])

    def test_a_fast_path_judge_that_accepts_a_repeated_launch_is_caught(self):
        got = self.run_mutated("if ($launches -ne 1) {", "if ($launches -lt 1) {", "fast_launched_twice")
        self.assertEqual(got, [])

    def test_a_fast_path_judge_that_accepts_a_discarded_exe_is_caught(self):
        got = self.run_mutated("if ($ConsoleText -match 'discarding cached EXE and rebuilding') {", "if ($false) {", "fast_discarded")
        self.assertEqual(got, [])

    def test_a_fast_path_judge_that_does_not_need_the_traceback_is_caught(self):
        got = self.run_mutated("if ($traceAt -lt 0) {", "if ($false) {", "fast_no_traceback")
        self.assertEqual(got, [])

    def test_a_fast_path_judge_that_takes_a_traceback_before_the_launch_is_caught(self):
        got = self.run_mutated("for ($i = $launchAt + 1; $i -lt $consoleLines.Count; $i++) {", "for ($i = 0; $i -lt $consoleLines.Count; $i++) {",
                               "fast_traceback_only_before_launch")
        self.assertEqual(got, [])

    def test_a_fast_path_judge_that_ignores_a_reported_module_is_caught(self):
        got = self.run_mutated("foreach ($named in @(Get-NamedModules -ConsoleText $ConsoleText)) {", "foreach ($named in @()) {", "fast_reports_module")
        self.assertEqual(got, [])

    def test_a_fast_path_judge_that_ignores_the_reminder_is_caught(self):
        got = self.run_mutated("if ($ConsoleText -match 'HEADS UP: while your program ran it asked for modules') {", "if ($false) {", "fast_prints_reminder")
        self.assertEqual(got, [])

    def test_a_fast_path_judge_that_ignores_the_rows_is_caught(self):
        got = self.run_mutated("if ($rowText -ne '') {", "if ($false) {", "fast_writes_row")
        self.assertEqual(got, [])


if __name__ == "__main__":
    unittest.main()
