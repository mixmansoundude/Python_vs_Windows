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


if __name__ == "__main__":
    unittest.main()
