"""Item 72 follow-up: the Nuitka builds do NOT keep a static unpack folder, and the finding that says why is recorded.

A Nuitka --onefile EXE unpacks into a fresh temp folder on every launch by default. A static
--onefile-tempdir-spec makes later launches about 3.7 times faster (docs/plan-field-report-2026-10.md), but
tests/selfapps_nuitka_cachesafety.ps1 measured that with the folder cold one of three simultaneous launches
exits 2 ("failed to open ... for writing"), so run_setup.bat's two Nuitka command lines carry no such flag. The
rules below read run_setup.bat, the script, the workflow and the cold-storage entry as plain text (no PowerShell
or YAML parser) so they run on every lane. Synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_nuitka_cachesafety.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
COLD_STORAGE = REPO / "docs" / "agent-cold-storage.md"

ROW = "self.nuitka.cachesafety"
PROD_FLAGS = "-m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist"


def lines_of(text):
    return text.splitlines()


def nuitka_command_lines(batch_text):
    return [ln for ln in lines_of(batch_text) if re.match(r'^\s*"%HP_PY%" -m nuitka ', ln)]


def batch_problems(batch_text):
    """The two Nuitka command lines carry the production flags and no static unpack folder anywhere in the file."""
    found = []
    cmds = nuitka_command_lines(batch_text)
    if len(cmds) != 2:
        found.append("expected 2 Nuitka command lines, found %d" % len(cmds))
    for ln in cmds:
        if PROD_FLAGS not in ln:
            found.append("a Nuitka command line does not start with the flags the safety script builds with: %s" % ln.strip()[:110])
    for needle in ("onefile-tempdir-spec", "HP_NUITKA_CACHE_ARG", ":nuitka_cache_arg"):
        if needle in batch_text:
            found.append(
                "run_setup.bat mentions %s: a static Nuitka unpack folder failed cold concurrent launches "
                "(Item 72, run 40043297712). Do not add it until self.nuitka.cachesafety reports adoptable "
                "true; see docs/agent-cold-storage.md" % needle
            )
    return found


def statement(script_text, variable):
    """The text of `$variable = [bool](...)` up to its closing parenthesis (parentheses balanced, strings ignored)."""
    m = re.search(r"(?:\$|\.)%s\s*=\s*\[bool\]\(" % re.escape(variable), script_text)
    if not m:
        return None
    depth = 1
    i = m.end()
    while i < len(script_text) and depth:
        c = script_text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    return script_text[m.end():i - 1]


def script_problems(script_text):
    found = []
    if len(re.findall(r"\bid\s*=\s*['\"]%s['\"]" % re.escape(ROW), script_text)) != 1:
        found.append("the script does not emit %s exactly once as a literal id" % ROW)
    tail = script_text.rstrip().splitlines()[-4:]
    if not any(re.match(r"^\s*exit 0\s*$", ln) for ln in tail):
        found.append("the script does not end with exit 0")
    # The exact guard, not any `if (...) { exit 1 }`: `if ($false) { exit 1 }` would satisfy a looser pattern.
    if not re.search(r"^\s*if \(-not \$safePass\)\s*\{\s*exit 1\s*\}\s*$", script_text, re.MULTILINE):
        found.append("the script has no 'if (-not $safePass) { exit 1 }'")
    if PROD_FLAGS not in script_text:
        found.append("the script's $prodFlags is not the production flag text")
    if "--onefile-tempdir-spec=" not in script_text:
        found.append("the script no longer builds with the static spec it measures")
    safe = statement(script_text, "safePass")
    if safe is None:
        found.append("the script has no $safePass = [bool](...) statement")
    else:
        for needed in ("warmConcurrentOk", "afterColdOk", "overlapOk", "killRecoveryOk", "partialKills", "baselineOk"):
            if needed not in safe:
                found.append("$safePass does not require %s" % needed)
        for recorded in ("coldConcurrentOk", "updateWhileRunningOk"):
            if recorded in safe:
                found.append("$safePass asserts %s, which is a recorded finding (it would turn the row red on every run)" % recorded)
    if not re.search(r"updateWhileRunningTested\s*=\s*\[bool\]\$dSafe\.updateOldStillRunningAfter", script_text):
        found.append("the update scenario does not require the old build to still run after the new one finished")
    adopt = statement(script_text, "adoptable")
    if adopt is None:
        found.append("the script has no $dSafe.adoptable = [bool](...) statement")
    else:
        for needed in ("safePass", "coldConcurrentOk", "updateWhileRunningOk"):
            if needed not in adopt:
                found.append("adoptable does not require %s" % needed)
    return found


def step_problems(workflow_text):
    lines = lines_of(workflow_text)
    idx = [i for i, ln in enumerate(lines) if "selfapps_nuitka_cachesafety.ps1" in ln and "&" in ln]
    if len(idx) != 1:
        return ["expected exactly 1 step running selfapps_nuitka_cachesafety.ps1, found %d" % len(idx)]
    start = idx[0]
    while start > 0 and not re.match(r"^      - name:", lines[start]):
        start -= 1
    block = "\n".join(lines[start:idx[0] + 1])
    found = []
    # An active `if:` line (not a comment, not another key's text) that tests the lane.
    if not re.search(r"^\s+if:\s*\$\{\{\s*matrix\.mode == 'uv'\s*\}\}\s*$", block, re.MULTILINE):
        found.append("the step is not restricted to the uv lane")
    if not re.search(r"^\s+continue-on-error:\s*true\s*$", block, re.MULTILINE):
        found.append("the step is not non-gating (continue-on-error: true)")
    return found


def cold_storage_problems(text):
    found = []
    if "self.nuitka.cachesafety" not in text:
        found.append("docs/agent-cold-storage.md has no entry naming self.nuitka.cachesafety")
    if "adoptable" not in text:
        found.append("docs/agent-cold-storage.md does not say the trigger is adoptable true")
    return found


GOOD_BATCH = """\
:try_nuitka_tier_a
"%HP_PY%" -m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist -o "%ENVNAME%.exe" "%HP_ENTRY%" >> "%LOG%" 2>&1
exit /b 0

:offer_optimized_build
"%HP_PY%" -m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist -o "%HP_OPTBUILD_TMP%" "%HP_ENTRY%" >> "%LOG%" 2>&1
exit /b 0
"""

GOOD_SCRIPT = """\
$prodFlags = '-m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist'
$spec = "--onefile-tempdir-spec={CACHE_DIR}/PVW/safety-$safeToken"
Write-SafetyRow ([ordered]@{ id = 'self.nuitka.cachesafety'; pass = $safePass })
$safePass = [bool]($dSafe.nuitkaUsable -and $built -and $dSafe.baselineOk -and
                   $dSafe.warmConcurrentOk -and $dSafe.afterColdOk -and
                   $dSafe.overlapOk -and $dSafe.killRecoveryOk -and ($dSafe.partialKills -ge 1))
$dSafe.updateWhileRunningTested = [bool]$dSafe.updateOldStillRunningAfter
$dSafe.adoptable = [bool]($safePass -and $dSafe.coldConcurrentOk -and $dSafe.updateWhileRunningOk)
if (-not $safePass) { exit 1 }
exit 0
"""

GOOD_STEP = """      - name: "Self-test: Nuitka unpack cache safety finding (uv lane, non-gating)"
        if: ${{ matrix.mode == 'uv' }}
        continue-on-error: true
        shell: pwsh
        run: |
          & tests\\selfapps_nuitka_cachesafety.ps1
"""

GOOD_COLD = "Nuitka unpack cache. Trigger: uv-lane row self.nuitka.cachesafety reports adoptable true.\n"


class RunSetupStaysFlagFree(unittest.TestCase):
    def test_real_batch_has_no_static_unpack_folder(self):
        self.assertEqual(batch_problems(BATCH.read_text(encoding="ascii", errors="replace")), [])

    def test_good_fixture_is_clean(self):
        self.assertEqual(batch_problems(GOOD_BATCH), [])

    def test_the_flag_on_a_command_line_is_caught(self):
        bad = GOOD_BATCH.replace("--output-dir=dist -o \"%ENVNAME%.exe\"", "--output-dir=dist --onefile-tempdir-spec={CACHE_DIR}/PVW/x -o \"%ENVNAME%.exe\"")
        self.assertTrue(any("onefile-tempdir-spec" in p for p in batch_problems(bad)))

    def test_the_old_subroutine_is_caught(self):
        bad = GOOD_BATCH + ":nuitka_cache_arg\nexit /b 0\n"
        self.assertTrue(any(":nuitka_cache_arg" in p for p in batch_problems(bad)))

    def test_changed_production_flags_are_caught(self):
        bad = GOOD_BATCH.replace("--remove-output", "--remove-output --lto=yes", 1)
        self.assertTrue(any("does not start with the flags" in p for p in batch_problems(bad)))

    def test_a_third_command_line_is_caught(self):
        bad = GOOD_BATCH + '"%HP_PY%" -m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist -o "x.exe" "y.py"\n'
        self.assertIn("found 3", batch_problems(bad)[0])


class ScriptRules(unittest.TestCase):
    def test_real_script_is_wired(self):
        self.assertTrue(SCRIPT.exists(), "tests/selfapps_nuitka_cachesafety.ps1 is missing")
        self.assertEqual(script_problems(SCRIPT.read_text(encoding="ascii")), [])

    def test_good_script_is_clean(self):
        self.assertEqual(script_problems(GOOD_SCRIPT), [])

    def test_a_missing_row_is_caught(self):
        self.assertTrue(any("exactly once" in p for p in script_problems(GOOD_SCRIPT.replace("self.nuitka.cachesafety", "self.nuitka.other"))))

    def test_a_missing_exit_is_caught(self):
        self.assertTrue(any("exit 0" in p for p in script_problems(GOOD_SCRIPT.replace("exit 0\n", ""))))

    def test_a_missing_failure_exit_is_caught(self):
        self.assertTrue(any("exit 1" in p for p in script_problems(GOOD_SCRIPT.replace("if (-not $safePass) { exit 1 }\n", ""))))

    def test_an_update_scenario_without_the_overlap_check_is_caught(self):
        bad = GOOD_SCRIPT.replace("$dSafe.updateWhileRunningTested = [bool]$dSafe.updateOldStillRunningAfter\n", "$dSafe.updateWhileRunningTested = $true\n")
        self.assertTrue(any("still run after" in p for p in script_problems(bad)), script_problems(bad))

    def test_a_vacuous_failure_exit_is_caught(self):
        bad = GOOD_SCRIPT.replace("if (-not $safePass) { exit 1 }", "if ($false) { exit 1 }")
        self.assertTrue(any("exit 1" in p for p in script_problems(bad)), script_problems(bad))

    def test_drifted_flags_are_caught(self):
        self.assertTrue(any("prodFlags" in p for p in script_problems(GOOD_SCRIPT.replace("--remove-output ", ""))))

    def test_a_missing_spec_is_caught(self):
        self.assertTrue(any("static spec" in p for p in script_problems(GOOD_SCRIPT.replace("--onefile-tempdir-spec=", "--other="))))

    def test_a_weakened_pass_condition_is_caught(self):
        bad = GOOD_SCRIPT.replace("$dSafe.killRecoveryOk -and ", "")
        self.assertTrue(any("killRecoveryOk" in p for p in script_problems(bad)))

    def test_asserting_the_recorded_cold_finding_is_caught(self):
        bad = GOOD_SCRIPT.replace("$dSafe.warmConcurrentOk -and", "$dSafe.warmConcurrentOk -and $dSafe.coldConcurrentOk -and")
        self.assertTrue(any("recorded finding" in p for p in script_problems(bad)))

    def test_adoptable_without_the_cold_result_is_caught(self):
        bad = GOOD_SCRIPT.replace("$safePass -and $dSafe.coldConcurrentOk -and $dSafe.updateWhileRunningOk", "$safePass")
        self.assertTrue(any("adoptable does not require" in p for p in script_problems(bad)))


class StepAndDocs(unittest.TestCase):
    def test_real_workflow_step_is_uv_only_and_non_gating(self):
        self.assertEqual(step_problems(WORKFLOW.read_text(encoding="utf-8")), [])

    def test_good_step_is_clean(self):
        self.assertEqual(step_problems(GOOD_STEP), [])

    def test_a_gating_step_is_caught(self):
        self.assertEqual(step_problems(GOOD_STEP.replace("        continue-on-error: true\n", "")), ["the step is not non-gating (continue-on-error: true)"])

    def test_a_step_on_every_lane_is_caught(self):
        self.assertEqual(step_problems(GOOD_STEP.replace("        if: ${{ matrix.mode == 'uv' }}\n", "")), ["the step is not restricted to the uv lane"])

    def test_a_commented_out_condition_is_caught(self):
        bad = GOOD_STEP.replace("        if: ${{ matrix.mode == 'uv' }}\n", "        # if: ${{ matrix.mode == 'uv' }}\n")
        self.assertEqual(step_problems(bad), ["the step is not restricted to the uv lane"])

    def test_a_condition_on_another_lane_is_caught(self):
        bad = GOOD_STEP.replace("matrix.mode == 'uv'", "matrix.mode == 'real'")
        self.assertEqual(step_problems(bad), ["the step is not restricted to the uv lane"])

    def test_a_missing_step_is_caught(self):
        self.assertIn("found 0", step_problems("      - name: other\n        run: echo hi\n")[0])

    def test_cold_storage_names_the_revisit_trigger(self):
        self.assertEqual(cold_storage_problems(COLD_STORAGE.read_text(encoding="utf-8")), [])

    def test_good_cold_storage_text_is_clean(self):
        self.assertEqual(cold_storage_problems(GOOD_COLD), [])

    def test_cold_storage_without_the_row_is_caught(self):
        self.assertTrue(cold_storage_problems("nothing here"))


if __name__ == "__main__":
    unittest.main()
