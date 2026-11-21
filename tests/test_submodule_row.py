"""Tests for the row of README REQ-018.19, Item 124: self.runtime.install.submodules.

REQ-018.19 says that on a yes under REQ-018.14, when the run has an EXE, the bootstrapper rebuilds the EXE with --hidden-import and
--collect-submodules for each installed module. Until Item 124 only the first flag was shown by behavior (self.runtime.install.accept is
clean only if the rebuilt EXE holds the package) and the second was pinned as text (tests/test_runtime_module_scan.py). The runtime scan
cannot tell the difference: it reports a TOP-LEVEL name that is not installed, so a submodule that is missing from the EXE of an installed
package reads as verified. tests/selfapps_runtime_install.ps1 now has a fifth bootstrap whose program loads pytz and pytz.reference by
names it joins at run time, answered yes, and a control build of the same program with --hidden-import alone: the check run of the
bootstrapper's own rebuild must hold both names, the control must hold the package and lack the submodule, and the row is red otherwise.
What this file holds, and why:
  * the script's judging functions (Get-SubmoduleProblems, Get-OutputExcerpt) run through a real pwsh in strict mode
    (tests/judge_support.py) on synthetic runs: a good run is clean and each wrong one is named by its own words;
  * mutation cases that remove one comparison from a copy of the script and must see the matching wrong run pass, so a judge that
    quietly stopped judging cannot stay green; one more loosens the anchored `loaded pytz` test, because `loaded pytz.reference` also
    starts with it;
  * the batch side the control depends on (:rti_add_hidden adds exactly the two flags the control halves, the rebuild line passes both
    accumulators), so a third flag added to the rebuild makes the control out of date HERE;
  * the script as text: literal row id and tag at both sites, the program joins its two names at run time, the control line carries the
    first flag only, the judge is called with the keys of its own parameters, the verdict includes the row;
  * the workflow upload paths and gating step, the registry line, and the shall list.
ASCII only.
"""
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import PWSH, case, cut_block, live_bat, mutate, norm, registry_ids, run_cases, step_block  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "tests" / "selfapps_runtime_install.ps1"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
ROW = "self.runtime.install.submodules"
TAG = "REQ-018.19"
JUDGES = ["Get-SubmoduleProblems", "Get-OutputExcerpt"]
FOLDER = "~selftest_runtime_install_submodules"
UPLOADED = ("~install_submodules_bootstrap.log", "~setup.log", "~run.err.txt", "~run.out.txt", "~sub.ndjson", "requirements.txt",
            "~control_build.log", "~control_out.txt", "~control_err.txt")


def lf(text):
    return text.replace("\r\n", "\n")


# --- synthetic runs --------------------------------------------------------------------------------------------------------------------

CHECK_OUT = "loaded pytz\r\nloaded pytz.reference\r\nsubmodule app done\r\n"
CONTROL_OUT = "loaded pytz\r\nsubmodule app done\r\n"
MISSING = "ModuleNotFoundError: No module named 'pytz.reference'"
CONTROL_ERR = "\r\n".join(["Traceback (most recent call last):", '  File "importlib\\__init__.py", line 126, in import_module', MISSING]) + "\r\n"
GOOD = dict(
    BootstrapExit=0, FirstRunNamedModule=True, Installed=True, EnvHasModule=True, Rebuilt=True, RowState="verified", StatusState="ok",
    CheckOut=CHECK_OUT, CheckErr="", ControlBuilt=True, ControlOut=CONTROL_OUT, ControlErr=CONTROL_ERR,
)


def judge(name, **over):
    args = dict(GOOD)
    args.update(over)
    return case(name, "Get-SubmoduleProblems", **args)


def judge_cases():
    return [
        judge("good"),
        judge("good_lf_only", CheckOut=lf(CHECK_OUT), ControlOut=lf(CONTROL_OUT), ControlErr=lf(CONTROL_ERR)),
        judge("exit_nonzero", BootstrapExit=1),
        judge("first_run_silent", FirstRunNamedModule=False),
        judge("not_installed", Installed=False),
        judge("env_lacks_package", EnvHasModule=False),
        judge("not_rebuilt", Rebuilt=False),
        judge("row_state_declined", RowState="declined"),
        judge("row_state_missing", RowState=""),
        judge("status_error", StatusState="error"),
        # the check run holds the submodule and not the package: only the anchored test tells `loaded pytz` from `loaded pytz.reference`
        judge("check_lacks_package", CheckOut="loaded pytz.reference\r\nsubmodule app done\r\n"),
        judge("check_lacks_submodule_silent", CheckOut="loaded pytz\r\nsubmodule app done\r\n"),
        # what a rebuild without --collect-submodules really prints: the load is missing AND the traceback is on the error output
        judge("check_lacks_submodule_real", CheckOut="loaded pytz\r\nsubmodule app done\r\n", CheckErr=CONTROL_ERR),
        judge("check_stderr_names_module", CheckErr="ModuleNotFoundError: No module named 'foo'\r\n"),
        judge("check_not_finished", CheckOut="loaded pytz\r\nloaded pytz.reference\r\n"),
        judge("control_not_built", ControlBuilt=False, ControlOut="", ControlErr=""),
        judge("control_lacks_package", ControlOut="submodule app done\r\n"),
        # a control that holds the submodule but still reports it missing is not real, it only isolates the comparison on the output
        judge("control_holds_submodule_isolated", ControlOut=CHECK_OUT, ControlErr=CONTROL_ERR),
        # the realistic one: the submodule is in the control EXE, so nothing is printed on its error output either
        judge("control_holds_submodule_real", ControlOut=CHECK_OUT, ControlErr=""),
        judge("control_silent_on_submodule", ControlErr=""),
        judge("control_reports_other_module", ControlErr="ModuleNotFoundError: No module named 'pytz.other'\r\n"),
    ]


def excerpt_cases():
    return [
        case("excerpt_joins", "Get-OutputExcerpt", Text="a\r\n\r\n  b  \r\nc\r\n"),
        case("excerpt_ascii", "Get-OutputExcerpt", Text="caf\u00e9 \u201cq\u201d"),
        case("excerpt_cut", "Get-OutputExcerpt", Text="x" * 400),
        case("excerpt_cut_small", "Get-OutputExcerpt", Text="x" * 40, Max=10),
        case("excerpt_empty", "Get-OutputExcerpt", Text=""),
        case("excerpt_blank_only", "Get-OutputExcerpt", Text="\r\n \r\n"),
    ]


def all_cases():
    return judge_cases() + excerpt_cases()


# --- the batch side the control depends on ---------------------------------------------------------------------------------------

def bat_text():
    return (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")


def batch_problems(bat):
    """The control builds with the first flag of :rti_add_hidden and leaves out the second, so it is the rebuild minus --collect-submodules
    only while :rti_add_hidden adds exactly those two flags and the rebuild line passes both accumulators."""
    found = []
    add = cut_block(bat, ":rti_add_hidden", ":rti_row")
    want = [":rti_add_hidden",
            'set "HP_PYI_HIDDEN_IMPORTS=%HP_PYI_HIDDEN_IMPORTS% --hidden-import=%~1"',
            'set "HP_PYI_HID_COLLECT=%HP_PYI_HID_COLLECT% --collect-submodules=%~1"',
            "exit /b 0"]
    if add is None:
        found.append(":rti_add_hidden could not be cut out of run_setup.bat")
    elif [ln.strip() for ln in live_bat(add)] != want:
        found.append(":rti_add_hidden must hold exactly the --hidden-import and the --collect-submodules line, found %r" % ([ln.strip() for ln in live_bat(add)],))
    rebuild = cut_block(bat, ":rti_rebuild", ":rti_add_hidden")
    pyi = [ln for ln in live_bat(rebuild or []) if "-m PyInstaller" in ln]
    if len(pyi) != 1:
        found.append(":rti_rebuild must hold exactly one PyInstaller command line, found %d" % len(pyi))
    else:
        for need in ("%HP_PYI_HIDDEN_IMPORTS%", "%HP_PYI_HID_COLLECT%", "--onefile", "--clean", "--log-level WARN"):
            if need not in pyi[0]:
                found.append("the PyInstaller line of :rti_rebuild must carry %s" % need)
    return found


class BatchSide(unittest.TestCase):
    def setUp(self):
        self.bat = bat_text()

    def test_the_real_batch_file_is_in_order(self):
        self.assertEqual(batch_problems(self.bat), [])

    def test_a_third_flag_in_the_accumulator_line_is_reported(self):
        bad = mutate(self.bat, '--collect-submodules=%~1"\n', '--collect-submodules=%~1 --collect-all=%~1"\n')
        self.assertTrue(any("exactly the --hidden-import" in f for f in batch_problems(bad)))

    def test_a_missing_second_flag_is_reported(self):
        bad = mutate(self.bat, 'set "HP_PYI_HID_COLLECT=%HP_PYI_HID_COLLECT% --collect-submodules=%~1"\n', "")
        self.assertTrue(any("exactly the --hidden-import" in f for f in batch_problems(bad)))

    def test_a_rebuild_that_drops_the_second_accumulator_is_reported(self):
        bad = mutate(self.bat, " %HP_PYI_HIDDEN_IMPORTS% %HP_PYI_HID_COLLECT% %HP_RTI_TEST_BAD%", " %HP_PYI_HIDDEN_IMPORTS% %HP_RTI_TEST_BAD%")
        self.assertTrue(any("%HP_PYI_HID_COLLECT%" in f for f in batch_problems(bad)))


# --- the script as text ------------------------------------------------------------------------------------------------------------

def function_text(t, name):
    m = re.search(r"(?m)^function %s \{\n(.*?)\n^\}" % re.escape(name), t, re.S)
    return m.group(1) if m else None


def script_problems(text):
    t = norm(text)
    found = []
    tags = re.findall(r"id\s*=\s*'%s'\s*\n\s*req\s*=\s*'([^']*)'" % re.escape(ROW), t)
    if len(tags) != 2:
        found.append("%s must be written at 2 sites (the non-Windows skip and the real row) with a literal req tag, found %d" % (ROW, len(tags)))
    found += ["%s carries the tag %r, expected %r" % (ROW, g, TAG) for g in tags if g != TAG]

    app = re.search(r"\$submoduleAppCode = @'\n(.*?)\n'@", t, re.S)
    if not app:
        found.append("the program of the row ($submoduleAppCode) is missing")
    else:
        body = app.group(1)
        if "pytz" in body or "reference" in body:
            found.append("the program must not write pytz or reference in one piece, or a static scan sees the import")
        for need in ('"".join(("pyt", "z"))', '"".join(("refer", "ence"))', "importlib.import_module(name)", "traceback.print_exc()",
                     'print("loaded " + name)', 'print("submodule app done")'):
            if need not in body:
                found.append("the program of the row must hold %s" % need)

    for need in ("$s = Invoke-InstallScenario -Name 'submodules' -Answer 'Y' -AppSource $submoduleAppCode -Module 'pytz'",
                 "$ctl = Invoke-ControlBuild -WorkDir $s.WorkDir -Module 'pytz'",
                 "CheckOut = [string]$s.OutText; CheckErr = [string]$s.ErrText",
                 "ControlBuilt = [bool]$ctl.Built; ControlOut = [string]$ctl.Out; ControlErr = [string]$ctl.Err",
                 "$sProblems = @(Get-SubmoduleProblems @sArgs)",
                 "$sPass = ($sProblems.Count -eq 0)"):
        if t.count(need) != 1:
            found.append("the scenario must hold exactly once: %s" % need)

    ctl = function_text(t, "Invoke-ControlBuild")
    if ctl is None:
        found.append("Invoke-ControlBuild is missing")
    else:
        lines = [ln for ln in ctl.split("\n") if "-m PyInstaller" in ln]
        if len(lines) != 1:
            found.append("Invoke-ControlBuild must start PyInstaller exactly once, found %d" % len(lines))
        else:
            if '"--hidden-import=$Module"' not in lines[0]:
                found.append("the control must be built with the first flag, --hidden-import=<module>")
            if "collect" in lines[0].lower():
                found.append("the control must be built WITHOUT --collect-submodules, or it shows nothing")
            for need in ("--onefile", "--clean", "--log-level WARN"):
                if need not in lines[0]:
                    found.append("the control must carry %s like the rebuild does" % need)
        if ".uv_env\\Scripts\\python.exe" not in ctl:
            found.append("the control must be built by the environment the bootstrapper built (.uv_env\\Scripts\\python.exe)")

    judge_fn = re.search(r"(?m)^function Get-SubmoduleProblems \{\n\s*param\((.*?)\)\n", t, re.S)
    keys = re.search(r"\$sArgs = @\{\n(.*?)\n\}\n", t, re.S)
    if not judge_fn or not keys:
        found.append("Get-SubmoduleProblems or its argument table $sArgs could not be read")
    else:
        names = sorted(re.findall(r"\$([A-Za-z]+)", judge_fn.group(1)))
        given = sorted(re.findall(r"([A-Za-z]+) = ", keys.group(1)))
        if names != given:
            found.append("the keys of $sArgs %r are not the parameters of Get-SubmoduleProblems %r" % (given, names))

    if "if (-not ($aPass -and $dPass -and $pPass -and $ePass -and $wPass -and $rPass -and $sPass)) { exit 1 }\nexit 0" not in t:
        found.append("the script must end with exit 1 for any red row and exit 0, and the verdict must include the new row")
    return found


def shall_list_problems(text):
    return ["REQ-018.19 is still listed in UNTRACED_SHALLS although the row is tagged with it"] if re.search(r'^\s*"REQ-018\.19":', text, re.M) else []


class ScriptAsText(unittest.TestCase):
    def setUp(self):
        self.text = norm(SCRIPT.read_text(encoding="utf-8"))

    def test_the_real_script_and_the_shall_list_are_in_order(self):
        self.assertEqual(script_problems(self.text), [])
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_a_row_that_stops_naming_the_shall_is_reported(self):
        bad = mutate(self.text, "id      = 'self.runtime.install.submodules'\n    req     = 'REQ-018.19'\n    pass    = $sPass",
                     "id      = 'self.runtime.install.submodules'\n    req     = 'REQ-018'\n    pass    = $sPass")
        self.assertTrue(any("carries the tag" in f for f in script_problems(bad)))

    def test_a_missing_skip_row_is_reported(self):
        bad = mutate(self.text, "        id      = 'self.runtime.install.submodules'\n        req     = 'REQ-018.19'\n        pass    = $true\n",
                     "        id      = 'self.runtime.install.submodules_x'\n        req     = 'REQ-018.19'\n        pass    = $true\n")
        self.assertTrue(any("must be written at 2 sites" in f for f in script_problems(bad)))

    def test_a_program_that_names_the_package_plainly_is_reported(self):
        bad = mutate(self.text, '"".join(("pyt", "z"))', '"pytz"')
        self.assertTrue(any("one piece" in f or "must hold" in f for f in script_problems(bad)))

    def test_a_program_that_names_the_submodule_plainly_is_reported(self):
        bad = mutate(self.text, '"".join(("refer", "ence"))', '"reference"')
        self.assertTrue(any("one piece" in f or "must hold" in f for f in script_problems(bad)))

    def test_a_control_that_gets_the_second_flag_is_reported(self):
        bad = mutate(self.text, '--log-level WARN "--hidden-import=$Module" --distpath', '--log-level WARN "--hidden-import=$Module" "--collect-submodules=$Module" --distpath')
        self.assertTrue(any("WITHOUT --collect-submodules" in f for f in script_problems(bad)))

    def test_a_control_that_loses_the_first_flag_is_reported(self):
        bad = mutate(self.text, '--log-level WARN "--hidden-import=$Module" --distpath', "--log-level WARN --distpath")
        self.assertTrue(any("first flag" in f for f in script_problems(bad)))

    def test_a_control_built_by_another_interpreter_is_reported(self):
        bad = mutate(self.text, "$py       = Join-Path $WorkDir '.uv_env\\Scripts\\python.exe'", "$py       = 'python'")
        self.assertTrue(any(".uv_env" in f for f in script_problems(bad)))

    def test_an_argument_table_that_lost_a_key_is_reported(self):
        bad = mutate(self.text, "EnvHasModule = [bool]$s.EnvHasModule; ", "")
        self.assertTrue(any("keys of $sArgs" in f for f in script_problems(bad)))

    def test_a_judge_that_is_not_given_the_check_run_output_is_reported(self):
        bad = mutate(self.text, "CheckOut = [string]$s.OutText; CheckErr = [string]$s.ErrText", "CheckOut = [string]$ctl.Out; CheckErr = [string]$ctl.Err")
        self.assertTrue(any("exactly once" in f for f in script_problems(bad)))

    def test_a_verdict_that_leaves_out_the_row_is_reported(self):
        bad = mutate(self.text, "-and $rPass -and $sPass)) { exit 1 }", "-and $rPass)) { exit 1 }")
        self.assertTrue(any("must end with exit 1" in f for f in script_problems(bad)))

    def test_a_shall_that_is_still_listed_as_a_gap_is_reported(self):
        self.assertTrue(shall_list_problems('    "REQ-018.19": "unit: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-018.190": "unit: x",\n'), [])


class WorkflowAndRegistry(unittest.TestCase):
    def setUp(self):
        self.wf = norm((REPO / ".github" / "workflows" / "batch-check.yml").read_text(encoding="utf-8"))

    def test_the_script_still_runs_on_the_real_lane_and_gates(self):
        step = step_block(self.wf, "& tests\\selfapps_runtime_install.ps1")
        self.assertIsNotNone(step)
        self.assertIn("matrix.mode == 'real'", step)
        self.assertNotIn("continue-on-error", step)

    def test_the_files_of_the_scenario_are_uploaded_in_both_slash_forms(self):
        for name in UPLOADED:
            self.assertIn("tests/" + FOLDER + "/" + name, self.wf, name)
            self.assertIn("tests\\" + FOLDER + "\\" + name, self.wf, name)

    def test_the_registry_names_the_row_on_its_own_line(self):
        ids = registry_ids((REPO / "docs" / "agent-ndjson.md").read_text(encoding="utf-8"))
        self.assertIn(ROW, ids)


# --- the judges on synthetic runs -----------------------------------------------------------------------------------------------------

@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesOnSyntheticRuns(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, JUDGES, all_cases(), d)

    def only(self, name, *needles):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        for needle in needles:
            self.assertIn(needle, found[0], (name, found))

    def test_a_run_of_the_expected_shape_is_clean(self):
        self.assertEqual(self.r["good"], [])
        self.assertEqual(self.r["good_lf_only"], [])

    def test_a_run_that_did_not_start_from_the_symptom_or_did_not_install_is_named(self):
        self.only("exit_nonzero", "exit code 1")
        self.only("first_run_silent", "never reported pytz as missing")
        self.only("not_installed", "pytz was installed")
        self.only("env_lacks_package", "program's own environment")
        self.only("not_rebuilt", "EXE was rebuilt")

    def test_a_row_state_or_status_that_is_not_the_expected_one_is_named(self):
        self.only("row_state_declined", "state declined", "expected verified")
        self.only("row_state_missing", "expected verified")
        self.only("status_error", "state error", "expected ok")

    def test_a_check_run_that_lacks_the_package_is_not_taken_for_one_that_holds_it(self):
        self.only("check_lacks_package", "did not load pytz,", "does not hold the package")

    def test_a_check_run_that_lacks_the_submodule_names_the_missing_flag(self):
        self.only("check_lacks_submodule_silent", "pytz.reference", "--collect-submodules")
        found = self.r["check_lacks_submodule_real"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(any("did not load pytz.reference" in f for f in found), found)
        self.assertTrue(any("No module named" in f for f in found), found)

    def test_a_check_run_that_names_another_missing_module_or_stops_early_is_named(self):
        self.only("check_stderr_names_module", "No module named")
        self.only("check_not_finished", "never printed its last line")

    def test_a_control_that_was_not_built_is_one_problem_and_nothing_else_is_asked_of_it(self):
        self.only("control_not_built", "did not produce an EXE")

    def test_a_control_without_the_package_proves_nothing_and_says_so(self):
        self.only("control_lacks_package", "did not load pytz", "proves nothing")

    def test_a_control_that_holds_the_submodule_says_the_fixture_is_out_of_date(self):
        self.only("control_holds_submodule_isolated", "already holds pytz.reference", "no longer shows")
        found = self.r["control_holds_submodule_real"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(any("already holds pytz.reference" in f for f in found), found)
        self.assertTrue(any("did not report pytz.reference as missing" in f for f in found), found)

    def test_a_control_that_does_not_report_the_submodule_missing_is_named(self):
        self.only("control_silent_on_submodule", "did not report pytz.reference as missing")
        self.only("control_reports_other_module", "did not report pytz.reference as missing")

    def test_the_excerpt_is_one_printable_ascii_line_cut_short(self):
        self.assertEqual(self.r["excerpt_joins"], ["a | b | c"])
        self.assertEqual(self.r["excerpt_ascii"], ["caf? ?q?"])
        self.assertEqual(self.r["excerpt_cut"], ["x" * 300])
        self.assertEqual(self.r["excerpt_cut_small"], ["x" * 10])
        self.assertEqual(self.r["excerpt_empty"], [""])
        self.assertEqual(self.r["excerpt_blank_only"], [""])


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesCanFail(unittest.TestCase):
    """A judge that quietly stopped judging would pass every run, so each comparison is removed from a copy of the script and the one
    synthetic run that violates only that comparison must then be clean."""

    @classmethod
    def setUpClass(cls):
        cls.cases = {c["name"]: c for c in all_cases()}

    def run_mutated(self, old, new, name):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, new), encoding="utf-8")
            return run_cases(script, JUDGES, [self.cases[name]], d)[name]

    def removed(self, test, old, name):
        self.assertEqual(self.run_mutated(old, "if ($false) {", name), [], test)

    def test_a_judge_that_ignores_the_exit_code_is_caught(self):
        self.removed("exit", "if ($BootstrapExit -ne 0) {", "exit_nonzero")

    def test_a_judge_that_ignores_a_silent_first_run_is_caught(self):
        self.removed("first run", "if (-not $FirstRunNamedModule) {", "first_run_silent")

    def test_a_judge_that_ignores_a_missing_install_line_is_caught(self):
        self.removed("install", "if (-not $Installed) {", "not_installed")

    def test_a_judge_that_ignores_the_environment_is_caught(self):
        self.removed("environment", "if (-not $EnvHasModule) {", "env_lacks_package")

    def test_a_judge_that_ignores_a_missing_rebuild_line_is_caught(self):
        self.removed("rebuild", "if (-not $Rebuilt) {", "not_rebuilt")

    def test_a_judge_that_ignores_the_row_state_is_caught(self):
        self.removed("row state", "if ($RowState -ne 'verified') {", "row_state_declined")

    def test_a_judge_that_ignores_the_status_is_caught(self):
        self.removed("status", "if ($StatusState -ne 'ok') {", "status_error")

    def test_a_judge_that_does_not_need_the_package_in_the_check_run_is_caught(self):
        self.removed("check package", r"if ($CheckOut -notmatch '(?m)^loaded pytz\s*$') {", "check_lacks_package")

    def test_a_judge_that_takes_the_submodule_load_for_the_package_load_is_caught(self):
        # `loaded pytz.reference` starts with `loaded pytz`: without the end anchor a check run that holds only the submodule would pass
        got = self.run_mutated(r"if ($CheckOut -notmatch '(?m)^loaded pytz\s*$') {", r"if ($CheckOut -notmatch '(?m)^loaded pytz') {", "check_lacks_package")
        self.assertEqual(got, [])

    def test_a_judge_that_does_not_need_the_submodule_in_the_check_run_is_caught(self):
        self.removed("check submodule", r"if ($CheckOut -notmatch '(?m)^loaded pytz\.reference\s*$') {", "check_lacks_submodule_silent")

    def test_a_judge_that_ignores_the_error_output_of_the_check_run_is_caught(self):
        self.removed("check stderr", "if ($CheckErr -match 'No module named') {", "check_stderr_names_module")

    def test_a_judge_that_does_not_need_the_last_line_is_caught(self):
        self.removed("last line", r"if ($CheckOut -notmatch '(?m)^submodule app done\s*$') {", "check_not_finished")

    def test_a_judge_that_does_not_need_a_built_control_is_caught(self):
        got = self.run_mutated("if (-not $ControlBuilt) {", "if ($false) {", "control_not_built")
        self.assertFalse(any("did not produce an EXE" in p for p in got), got)

    def test_a_judge_that_does_not_need_the_package_in_the_control_is_caught(self):
        self.removed("control package", r"if ($ControlOut -notmatch '(?m)^loaded pytz\s*$') {", "control_lacks_package")

    def test_a_judge_that_accepts_a_control_that_holds_the_submodule_is_caught(self):
        self.removed("control submodule", r"if ($ControlOut -match '(?m)^loaded pytz\.reference\s*$') {", "control_holds_submodule_isolated")

    def test_a_judge_that_does_not_need_the_control_to_report_the_submodule_is_caught(self):
        self.removed("control report", """if ($ControlErr -notmatch "No module named 'pytz\\.reference'") {""", "control_silent_on_submodule")


if __name__ == "__main__":
    unittest.main()
