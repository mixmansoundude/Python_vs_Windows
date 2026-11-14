"""Item 46 Batch 4 (README REQ-024, REQ-016.8 and the per-site requirements; docs/plan-die-fatal-remediation.md): a file the
bootstrapper cannot write in the middle of a run must not end the run.

What really happens in a bootstrap is checked on Windows by tests/selfapps_die_writefail.ps1 (nine `self.softfail.*` rows: the uv
scenario in the real lane, the conda scenario in the conda-full lane, both gating). These rules read the script, run_setup.bat,
batch-check.yml and docs/agent-ndjson.md as text, and run the script's own judging functions through a real pwsh on synthetic runs, so a
reworded log line, a hook that no longer names a real emit call, a judging rule that stops judging or a step that stops gating fails here
with a sentence, before a Windows run is needed. Synthetic cases prove each rule can fail.

The one change to the product in the red commit is a test hook, HP_TEST_FORCE_CONDARC_WRITE_FAIL: set, the .condarc copy in
:conda_create_done gets a destination whose folder does not exist (so it fails the way a locked or full disk would); absent, the copy is
what it was (README REQ-019).
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "tests" / "selfapps_die_writefail.ps1"
BATCH = REPO / "run_setup.bat"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

ROWS = (
    ("self.softfail.control.uv", "REQ-024"),
    ("self.softfail.prep", "REQ-005.8, REQ-024"),
    ("self.softfail.visa", "REQ-008, REQ-024"),
    ("self.softfail.depstage", "REQ-005.1, REQ-024"),
    ("self.softfail.control.conda", "REQ-024"),
    ("self.softfail.pyspec", "REQ-004, REQ-024"),
    ("self.softfail.pyver", "REQ-004, REQ-024"),
    ("self.softfail.condarc.stage", "REQ-006, REQ-024"),
    ("self.softfail.condarc.write", "REQ-006, REQ-024"),
)
# Each failing run: the payload variable the hook names and the file the batch writes it to.
EMIT_HOOKS = (
    ("HP_PREP_REQUIREMENTS", "~prep_requirements.py"),
    ("HP_DETECT_VISA", "~detect_visa.py"),
    ("HP_DETECT_PY", "~detect_python.py"),
    ("HP_PRINT_PYVER", "~print_pyver.py"),
    ("HP_CONDARC", "~condarc"),
)
STEP_UV = "Self-test: a file the bootstrapper cannot write does not end the run (real only)"
STEP_CONDA = "Self-test: a file the bootstrapper cannot write does not end the run, conda path (conda-full only)"


def read(path):
    return Path(path).read_text(encoding="ascii")


def live_lines(text):
    """The lines of a batch file that are not comments (a rem line, a :: line)."""
    return [ln for ln in text.splitlines() if not re.match(r"\s*(rem\b|::)", ln, re.I)]


def script_problems(text, batch):
    problems = []
    for row_id, tag in ROWS:
        sites = len(re.findall(r"id = '%s'" % re.escape(row_id), text))
        tagged = len(re.findall(r"id = '%s'; req = '%s'" % (re.escape(row_id), re.escape(tag)), text))
        if sites == 0 or sites != tagged:
            problems.append("%s must be written with its literal id and req tag %r at every Write-NdjsonRow call site (%d of %d are)" % (row_id, tag, tagged, sites))
    for needle, why in (
        ("call run_setup.bat > ~console.log 2>&1 < nul", "every run starts with standard input closed"),
        ("taskkill.exe /F /T /PID", "a run that hangs is killed as a process tree"),
        ("$lines += ('set \"' + $n + '=\"')", "the wrapper clears every flag of the job (the CI marker too, because :die pauses only without it)"),
        ("-Name IsReadOnly -Value $true", "the dependency list scenario makes requirements.txt read-only"),
        ("'Building standalone executable'", "the lock folder is looked at when the build line is written"),
        ("if (-not $allPass) { exit 1 }\nexit 0", "the script ends with its own exit codes (the pwsh step appends exit $LASTEXITCODE)"),
    ):
        if needle not in text:
            problems.append("selfapps_die_writefail.ps1 lost: %s (%s)" % (needle, why))
    if not re.search(r'call :log "\[INFO\] Building standalone executable', batch):
        problems.append("run_setup.bat no longer writes the build line the script waits for")
    for var, filename in EMIT_HOOKS:
        if not re.search(r'(?m)^\s*call :emit_from_base64 "%s" %s\s*$' % (re.escape(filename), var), batch):
            problems.append("run_setup.bat has no emit call of %s for %s" % (filename, var))
        if "HP_TEST_FORCE_EMIT_FAIL = '%s'" % var not in text:
            problems.append("the script never fails %s" % var)
    if "HP_TEST_FORCE_CONDARC_WRITE_FAIL = '1'" not in text:
        problems.append("the script never sets HP_TEST_FORCE_CONDARC_WRITE_FAIL")
    if "~bootstrap.lock" not in text or "~bootstrap.lock" not in batch:
        problems.append("the lock folder name is not the one run_setup.bat uses")
    return problems


def hook_problems(batch):
    problems = []
    live = live_lines(batch)
    hits = [ln for ln in live if "HP_TEST_FORCE_CONDARC_WRITE_FAIL" in ln]
    if len(hits) != 2:
        problems.append("expected exactly two live lines that read HP_TEST_FORCE_CONDARC_WRITE_FAIL, found %d" % len(hits))
    if not any(ln.startswith("if defined HP_TEST_FORCE_CONDARC_WRITE_FAIL set \"HP_CONDARC_DEST=") for ln in live):
        problems.append("the hook must only change the copy destination, behind `if defined`")
    if not any(re.match(r'copy /y "~condarc" "%HP_CONDARC_DEST%" ', ln) for ln in live):
        problems.append("the .condarc copy no longer goes through HP_CONDARC_DEST")
    return problems


def registry_ids(text):
    ids = set()
    inside = False
    for ln in text.splitlines():
        if ln.startswith("```"):
            inside = not inside
            continue
        if inside and ln.strip():
            ids.add(ln.strip())
    return ids


def registry_problems(text):
    registered = registry_ids(text)
    return ["%s is not in docs/agent-ndjson.md" % row_id for row_id, _tag in ROWS if row_id not in registered]


def step_block(text, name):
    """The text of the workflow step called name, up to the next step or comment at step level; None when absent."""
    marker = '      - name: "%s"' % name
    start = text.find(marker)
    if start < 0:
        return None
    end = len(text)
    for m in re.finditer(r"(?m)^      (- name:|#)", text[start + len(marker):]):
        end = start + len(marker) + m.start()
        break
    return text[start:end]


def workflow_problems(text):
    problems = []
    for name, lane, scenario in ((STEP_UV, "real", "uv"), (STEP_CONDA, "conda-full", "conda")):
        block = step_block(text, name)
        if block is None:
            problems.append("step %r is missing" % name)
            continue
        if "matrix.mode == '%s'" % lane not in block or "!cancelled()" not in block:
            problems.append("step %r must run when not cancelled on the %s lane only" % (name, lane))
        if lane == "conda-full" and "steps.conda_avail.outputs.available == 'true'" not in block:
            problems.append("step %r must wait for the conda availability check like the other conda-full scripts" % name)
        if "continue-on-error" in block:
            problems.append("step %r must gate: no continue-on-error" % name)
        if "SOFTFAIL_SCENARIO: %s" % scenario not in block:
            problems.append("step %r must set SOFTFAIL_SCENARIO: %s" % (name, scenario))
        if "& tests\\selfapps_die_writefail.ps1" not in block:
            problems.append("step %r must run tests\\selfapps_die_writefail.ps1" % name)
    for pattern in ("tests/~selftest_softfail_evidence/*", "tests\\~selftest_softfail_evidence\\*"):
        if pattern not in text:
            problems.append("the test-logs upload lacks the evidence pattern %s" % pattern)
    return problems


# --- the script's own judging functions, run through a real pwsh ---

DRIVER = r"""
$ErrorActionPreference = 'Stop'
# A judging function may use only its parameters and its own locals. Strict mode makes a read of a variable nobody set an error
# (and not $null), and the driver's own variables start with two underscores, so no judge can read one of them by accident.
Set-StrictMode -Version 1.0
$__tokens = $null; $__errs = $null
$__ast = [System.Management.Automation.Language.Parser]::ParseFile($env:DW_SCRIPT, [ref]$__tokens, [ref]$__errs)
if ($__errs.Count -gt 0) { throw ('parse errors: ' + $__errs[0].Message) }
$__want = @('Get-TextCount', 'Get-PauseCounts', 'Get-ErrorLines', 'Get-ControlProblems', 'Get-SoftfailProblems')
$__defs = $__ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $__want -contains $n.Name }, $true)
if (@($__defs).Count -ne $__want.Count) { throw 'a judging function is missing from the script' }
foreach ($__f in $__defs) { Invoke-Expression $__f.Extent.Text }
$__cases = Get-Content -LiteralPath $env:DW_CASES -Raw | ConvertFrom-Json
$__all = New-Object System.Collections.ArrayList
foreach ($__c in $__cases) {
    $__want2 = @{}
    if ($null -ne $__c.want) {
        foreach ($__p in $__c.want.PSObject.Properties) {
            if ($__p.Value -is [System.Array]) { $__want2[$__p.Name] = @($__p.Value) } else { $__want2[$__p.Name] = $__p.Value }
        }
    }
    if ($__c.kind -eq 'control') {
        $__res = Get-ControlProblems -Run $__c.run -MarkerText $__c.marker
    } elseif ($__c.kind -eq 'pause') {
        $__res = Get-PauseCounts -ConsoleText $__c.console -MarkerText $__c.marker
    } else {
        $__res = Get-SoftfailProblems -Run $__c.run -Ctl $__c.ctl -Want $__want2 -MarkerText $__c.marker
    }
    [void]$__all.Add([ordered]@{ name = $__c.name; result = $__res })
}
ConvertTo-Json -InputObject @($__all) -Compress -Depth 8
"""

MARK = "Building standalone executable"
BUILD_LINE = "[INFO] Building standalone executable -- this may take a minute or two...\n"
PRESS = "Press any key to continue . . .\n"
CLEAN_CONSOLE = "[INFO] start\n" + BUILD_LINE + "[INFO] done\n" + PRESS
CLEAN_SETUP = "[INFO] start\n[WARN] Could not write ~prep_requirements.py; skipped.\n" + BUILD_LINE


def run(**over):
    base = {"Console": CLEAN_CONSOLE, "Setup": CLEAN_SETUP, "State": "ok", "Sampled": True, "LockAtMarker": True, "Finished": True}
    base.update(over)
    return base


def control_run(**over):
    base = run(Setup="[INFO] start\n" + BUILD_LINE)
    base.update(over)
    return base


def soft(name, want=None, run_over=None, ctl_over=None):
    return {"name": name, "kind": "soft", "marker": MARK, "run": run(**(run_over or {})), "ctl": control_run(**(ctl_over or {})), "want": want or {}}


def ctl_case(name, **over):
    return {"name": name, "kind": "control", "marker": MARK, "run": control_run(**over)}


PREP_WANT = {"Site": r"\[WARN\] Could not write ~prep_requirements\.py", "State": "control", "Absent": ["can't open file"]}
DEP_WANT = {"Site": r"\[ERROR\] Could not (stage|copy) the dependency list", "ErrorAllowed": r"Could not (stage|copy) the dependency list", "State": "error"}


def run_cases(cases, tmp):
    tmp = Path(tmp)
    cases_file = tmp / "cases.json"
    cases_file.write_text(json.dumps(cases), encoding="ascii")
    driver = tmp / "driver.ps1"
    driver.write_text(DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["DW_SCRIPT"] = str(SCRIPT)
    env["DW_CASES"] = str(cases_file)
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(driver)], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    out = {}
    for item in json.loads(proc.stdout):
        res = item["result"]
        out[item["name"]] = res if not isinstance(res, str) else [res]
    return out


class ScriptShape(unittest.TestCase):
    def test_script_and_batch_agree(self):
        self.assertEqual([], script_problems(read(SCRIPT), read(BATCH)))

    def test_hook_is_a_destination_change_only(self):
        self.assertEqual([], hook_problems(read(BATCH)))

    def test_rows_are_registered(self):
        self.assertEqual([], registry_problems(read(REGISTRY)))

    def test_workflow_steps_gate_on_the_right_lanes(self):
        self.assertEqual([], workflow_problems(read(WORKFLOW)))

    def test_script_is_ascii(self):
        read(SCRIPT)  # raises on a non-ASCII byte


class StaticRulesCanFail(unittest.TestCase):
    def setUp(self):
        self.script = read(SCRIPT)
        self.batch = read(BATCH)
        self.workflow = read(WORKFLOW)

    def mutate(self, text, old, new):
        self.assertEqual(1, text.count(old), "anchor must occur exactly once: " + old)
        return text.replace(old, new)

    def test_a_lost_exit_code_is_found(self):
        bad = self.mutate(self.script, "if (-not $allPass) { exit 1 }\nexit 0", "exit 0")
        self.assertTrue(any("exit codes" in p for p in script_problems(bad, self.batch)))

    def test_open_standard_input_is_found(self):
        bad = self.mutate(self.script, "call run_setup.bat > ~console.log 2>&1 < nul", "call run_setup.bat > ~console.log 2>&1")
        self.assertTrue(any("standard input" in p for p in script_problems(bad, self.batch)))

    def test_a_dropped_row_id_is_found(self):
        bad = self.mutate(self.script, "id = 'self.softfail.depstage'; req = 'REQ-005.1, REQ-024'; pass = [bool]($depProblems.Count -eq 0)",
                          "id = 'self.softfail.depstage'; req = 'REQ-005.1'; pass = [bool]($depProblems.Count -eq 0)")
        self.assertTrue(any("self.softfail.depstage" in p for p in script_problems(bad, self.batch)))

    def test_a_hook_that_names_no_emit_call_is_found(self):
        bad = self.mutate(self.batch, 'call :emit_from_base64 "~detect_visa.py" HP_DETECT_VISA', 'call :emit_from_base64 "~detect_visa2.py" HP_DETECT_VISA')
        self.assertTrue(any("HP_DETECT_VISA" in p for p in script_problems(self.script, bad)))

    def test_a_moved_build_line_is_found(self):
        bad = self.mutate(self.batch, 'call :log "[INFO] Building standalone executable', 'call :log "[INFO] Packaging the program')
        self.assertTrue(any("build line" in p for p in script_problems(self.script, bad)))

    def test_a_missing_hook_in_the_batch_is_found(self):
        bad = self.batch.replace('if defined HP_TEST_FORCE_CONDARC_WRITE_FAIL set "HP_CONDARC_DEST=', 'if defined HP_TEST_FORCE_CONDARC_WRITE_FAILED set "HP_CONDARC_DEST=')
        self.assertTrue(hook_problems(bad))

    def test_a_hook_that_skips_the_copy_is_found(self):
        bad = self.mutate(self.batch, 'copy /y "~condarc" "%HP_CONDARC_DEST%" ', 'copy /y "~condarc" "%ENV_PATH%\\.condarc" ')
        self.assertTrue(any("HP_CONDARC_DEST" in p for p in hook_problems(bad)))

    def test_an_unregistered_row_is_found(self):
        bad = read(REGISTRY).replace("self.softfail.visa\n", "")
        self.assertTrue(any("self.softfail.visa" in p for p in registry_problems(bad)))

    def test_a_step_that_stops_gating_is_found(self):
        marker = '      - name: "%s"\n        if: ${{ !cancelled() && matrix.mode == \'real\' }}\n' % STEP_UV
        bad = self.mutate(self.workflow, marker, marker + "        continue-on-error: true\n")
        self.assertTrue(any("continue-on-error" in p for p in workflow_problems(bad)))

    def test_a_step_on_the_wrong_lane_is_found(self):
        marker = '      - name: "%s"\n        if: ${{ !cancelled() && matrix.mode == \'real\' }}\n' % STEP_UV
        bad = self.mutate(self.workflow, marker, '      - name: "%s"\n        if: ${{ !cancelled() && matrix.mode == \'cache\' }}\n' % STEP_UV)
        self.assertTrue(any("real lane" in p for p in workflow_problems(bad)))

    def test_a_missing_step_is_found(self):
        bad = self.workflow.replace(STEP_CONDA, "Some other step")
        self.assertTrue(any("is missing" in p for p in workflow_problems(bad)))

    def test_a_missing_upload_pattern_is_found(self):
        bad = self.workflow.replace("tests/~selftest_softfail_evidence/*", "tests/~selftest_nothing/*")
        self.assertTrue(any("evidence pattern" in p for p in workflow_problems(bad)))


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesRunThroughPwsh(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        extra_press = "[INFO] start\n" + PRESS + BUILD_LINE + "[INFO] done\n" + PRESS
        two_end = CLEAN_CONSOLE + PRESS
        cases = [
            ctl_case("control_clean"),
            ctl_case("control_lock_missing", LockAtMarker=False),
            ctl_case("control_not_sampled", Sampled=False, LockAtMarker=None),
            ctl_case("control_pause_before", Console=extra_press),
            ctl_case("control_no_end_pause", Console="[INFO] start\n" + BUILD_LINE + "[INFO] done\n"),
            ctl_case("control_state_error", State="error"),
            ctl_case("control_error_line", Setup="[INFO] start\n[ERROR] something broke\n" + BUILD_LINE),
            ctl_case("control_unfinished", Finished=False),
            ctl_case("control_no_marker_in_console", Console="[INFO] start\n" + PRESS),
            {"name": "pause_counts", "kind": "pause", "marker": MARK, "console": extra_press},
            {"name": "pause_counts_no_marker", "kind": "pause", "marker": MARK, "console": PRESS},
            soft("soft_clean", PREP_WANT),
            soft("soft_lock_released", PREP_WANT, run_over={"LockAtMarker": False}),
            soft("soft_pause_midrun", PREP_WANT, run_over={"Console": extra_press}),
            soft("soft_pause_after_build", PREP_WANT, run_over={"Console": two_end}),
            soft("soft_site_missing", PREP_WANT, run_over={"Setup": "[INFO] start\n" + BUILD_LINE}),
            soft("soft_hook_missing", dict(PREP_WANT, Hook="HP_TEST_FORCE_EMIT_FAIL=HP_PREP_REQUIREMENTS: simulating")),
            soft("soft_error_line", PREP_WANT, run_over={"Setup": CLEAN_SETUP + "[ERROR] Could not write ~prep_requirements.py\n"}),
            soft("soft_absent_found", PREP_WANT, run_over={"Setup": CLEAN_SETUP + "python.exe: can't open file '~prep_requirements.py'\n"}),
            soft("soft_present_missing", dict(PREP_WANT, Present=["\\[VISA\\] skipped"])),
            soft("soft_state_error", PREP_WANT, run_over={"State": "error"}),
            soft("soft_unfinished", PREP_WANT, run_over={"Finished": False}),
            soft("soft_not_sampled", PREP_WANT, run_over={"Sampled": False, "LockAtMarker": None}),
            soft("soft_control_dirty", PREP_WANT, ctl_over={"LockAtMarker": False}),
            soft("dep_ok", DEP_WANT, run_over={"State": "error", "Setup": "[INFO] start\n[ERROR] Could not copy the dependency list x.\n" + BUILD_LINE}),
            soft("dep_old_wording_ok", DEP_WANT, run_over={"State": "error", "Setup": "[INFO] start\n[ERROR] Could not stage the dependency list x.\n" + BUILD_LINE}),
            soft("dep_state_ok_is_wrong", DEP_WANT, run_over={"State": "ok", "Setup": "[INFO] start\n[ERROR] Could not copy the dependency list x.\n" + BUILD_LINE}),
            soft("dep_other_error", DEP_WANT, run_over={"State": "error", "Setup": "[INFO] start\n[ERROR] Could not copy the dependency list x.\n[ERROR] other\n" + BUILD_LINE}),
        ]
        cls.out = run_cases(cases, cls.tmp.name)

    def problems(self, name):
        return [p for p in self.out[name]]

    def test_a_clean_control_has_no_problem(self):
        self.assertEqual([], self.problems("control_clean"))

    def test_each_control_rule_can_fail(self):
        expect = {
            "control_lock_missing": "lock folder was missing",
            "control_not_sampled": "never looked at",
            "control_pause_before": "before the build started",
            "control_no_end_pause": "cannot see one",
            "control_state_error": "state error",
            "control_error_line": "[ERROR]",
            "control_unfinished": "did not finish",
            "control_no_marker_in_console": "not in the console log",
        }
        for name, text in expect.items():
            with self.subTest(name):
                self.assertTrue(any(text in p for p in self.problems(name)), self.problems(name))

    def test_pause_counts_split_at_the_build_line(self):
        res = self.out["pause_counts"]
        self.assertEqual((1, 2), (res["Before"], res["Total"]))
        res = self.out["pause_counts_no_marker"]
        self.assertEqual((None, 1), (res["Before"], res["Total"]))

    def test_a_clean_failing_run_has_no_problem(self):
        self.assertEqual([], self.problems("soft_clean"))
        self.assertEqual([], self.problems("dep_ok"))
        self.assertEqual([], self.problems("dep_old_wording_ok"))

    def test_each_soft_rule_can_fail(self):
        expect = {
            "soft_lock_released": "released in the middle",
            "soft_pause_midrun": "before the build started",
            "soft_pause_after_build": "key presses in the whole run",
            "soft_site_missing": "names the failed step",
            "soft_hook_missing": "test hook line",
            "soft_error_line": "an [ERROR] line where a [WARN] line belongs",
            "soft_absent_found": "found in the setup log",
            "soft_present_missing": "missing from the setup log",
            "soft_state_error": "expected ok",
            "soft_unfinished": "did not finish",
            "soft_not_sampled": "never looked at",
            "soft_control_dirty": "control run was not clean",
            "dep_state_ok_is_wrong": "expected error",
            "dep_other_error": "an unexpected [ERROR] line",
        }
        for name, text in expect.items():
            with self.subTest(name):
                self.assertTrue(any(text in p for p in self.problems(name)), self.problems(name))

    def test_a_midrun_pause_is_reported_twice_over(self):
        # One key press before the build is both "before the build" and one more than the control prints in total.
        probs = self.problems("soft_pause_midrun")
        self.assertTrue(any("before the build started" in p for p in probs))
        self.assertTrue(any("key presses in the whole run" in p for p in probs))


if __name__ == "__main__":
    unittest.main()
