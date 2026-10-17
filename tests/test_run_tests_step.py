"""Item 84: the CI step that runs run_tests.bat must pass its exit code through.

The step used to read ~bootstrap.status.json after run_tests.bat finished and exit 0 whenever the state was
no_python_files. That state is true in every lane (this repository has no .py files at its root), so the
step turned every run_tests.bat failure into success. Rows with pass:false were still caught by the later
"Gate on NDJSON results" step, but a script that crashed after writing some green rows (rows missing, exit
code 1) kept the lane green.

The text rules below read batch-check.yml as plain text (no YAML dependency, same style as
test_flag_inventory.py). Synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
CONTRACT = REPO / "tests" / "selfapps_runtests_contract.ps1"


def step_block(text):
    """Return the text of the step whose env sets SCRIPT: run_tests.bat, or None."""
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if re.search(r"^\s+SCRIPT:\s*run_tests\.bat\s*$", block, re.MULTILINE):
            return block
    return None


def problems(block):
    found = []
    if block is None:
        return ["no step sets SCRIPT: run_tests.bat"]
    if re.search(r"mapping to SUCCESS|map(s|ping)? .*to success", block, re.IGNORECASE):
        found.append("the step still maps a failing run_tests.bat to success")
    if re.search(r"\bexit 0\b", block):
        found.append("the step contains an exit 0 (a success exit would hide run_tests.bat's code)")
    last = [ln.strip() for ln in block.splitlines() if ln.strip()][-1]
    if last != "exit $rc":
        found.append("the step does not end with exit $rc (last line: %r)" % last)
    if not re.search(r"^\s*\$rc\s*=\s*\$LASTEXITCODE\s*$", block, re.MULTILINE):
        found.append("the step never assigns $rc = $LASTEXITCODE")
    return found


GOOD = """      - name: Run tests (run_tests.bat)
        env:
          SCRIPT: run_tests.bat
        run: |
          & cmd /c $env:SCRIPT *>&1 | Tee-Object -FilePath $stdoutPath
          $rc = $LASTEXITCODE
          exit $rc
"""

SWALLOW = """      - name: Run tests (map empty repo to success)
        env:
          SCRIPT: run_tests.bat
        run: |
          & cmd /c $env:SCRIPT *>&1 | Tee-Object -FilePath $stdoutPath
          $rc = $LASTEXITCODE
          if ($status.state -eq 'no_python_files') {
            Write-Host "Runner rc=$rc on empty repo; mapping to SUCCESS by CI contract."
            exit 0
          }
          exit $rc
"""


class RunTestsStepPassesExitCodeThrough(unittest.TestCase):
    def test_workflow_step(self):
        block = step_block(WORKFLOW.read_text(encoding="utf-8"))
        self.assertEqual(problems(block), [])

    def test_good_shape_is_clean(self):
        self.assertEqual(problems(step_block(GOOD)), [])

    def test_swallowing_step_is_caught(self):
        found = problems(step_block(SWALLOW))
        self.assertTrue(any("maps a failing" in f for f in found), found)
        self.assertTrue(any("exit 0" in f for f in found), found)

    def test_missing_final_exit_is_caught(self):
        no_exit = GOOD.replace("          exit $rc\n", "          Write-Host done\n")
        self.assertTrue(any("does not end with exit $rc" in f for f in problems(step_block(no_exit))))

    def test_rc_not_taken_from_lastexitcode_is_caught(self):
        zero = GOOD.replace("$rc = $LASTEXITCODE", "$rc = 0")
        self.assertTrue(any("never assigns $rc" in f for f in problems(step_block(zero))))

    def test_lastexitcode_only_mentioned_is_caught(self):
        mention = GOOD.replace("$rc = $LASTEXITCODE", "$rc = 0  # ignores $LASTEXITCODE")
        self.assertTrue(any("never assigns $rc" in f for f in problems(step_block(mention))))

    def test_missing_step_is_caught(self):
        self.assertEqual(problems(step_block("      - name: other\n        run: x\n")), ["no step sets SCRIPT: run_tests.bat"])


def exit_problems(text):
    """The contract script must end with an explicit exit, 1 when a row is red and 0 otherwise.

    It runs copies of run_tests.bat whose last scenario exits 1 on purpose. GitHub Actions appends
    exit $LASTEXITCODE to every pwsh step, so a script that does not set its own exit code hands that 1 to the
    step and fails the lane with every row green (the canary run on PR #496 did exactly that on all eight lanes).
    """
    found = []
    lines = [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.strip().startswith("#")]
    if not lines or lines[-1] != "exit 0":
        found.append("the script does not end with exit 0 (last line: %r)" % (lines[-1] if lines else ""))
    if not any(re.match(r"if \(.*\) \{ exit 1 \}$", ln) for ln in lines):
        found.append("the script never exits 1 when a row is red")
    return found


LEAKY_SCRIPT = """$k = Invoke-RunTestsScenario -Name 'x'
Write-NdjsonRow ([ordered]@{ id = 'self.runtests.x'; pass = [bool]$kPass })

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"""

ENDS_RIGHT = LEAKY_SCRIPT + """if (-not ($gPass -and $kPass)) { exit 1 }
exit 0
"""


class ContractScriptSetsItsOwnExitCode(unittest.TestCase):
    def test_contract_script(self):
        self.assertEqual(exit_problems(CONTRACT.read_text(encoding="utf-8")), [])

    def test_ending_in_cleanup_is_caught(self):
        found = exit_problems(LEAKY_SCRIPT)
        self.assertTrue(any("does not end with exit 0" in f for f in found), found)
        self.assertTrue(any("never exits 1" in f for f in found), found)

    def test_explicit_exits_are_clean(self):
        self.assertEqual(exit_problems(ENDS_RIGHT), [])

    def test_exit_zero_without_a_red_row_exit_is_caught(self):
        found = exit_problems(LEAKY_SCRIPT + "exit 0\n")
        self.assertEqual(found, ["the script never exits 1 when a row is red"])


if __name__ == "__main__":
    unittest.main()
