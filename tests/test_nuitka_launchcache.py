"""Item 72 (b): the Nuitka launch-cache experiment must measure the build the bootstrapper really makes.

tests/selfapps_nuitka_launchcache.ps1 builds with a copy of the bootstrapper's own Nuitka flags. If the
two Nuitka command lines in run_setup.bat change and the script's copy does not, the numbers it reports
describe a different build than the user gets. These rules read the files as plain text (no PowerShell or
YAML parser), so they run on every lane; synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_nuitka_launchcache.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"

ROW_ID = "self.nuitka.launchcache"


def script_flags(script_text):
    m = re.search(r"^\$prodFlags\s*=\s*'([^']+)'\s*$", script_text, re.MULTILINE)
    return m.group(1) if m else None


def nuitka_command_lines(batch_text):
    return [ln for ln in batch_text.splitlines() if re.match(r'^\s*"%HP_PY%" -m nuitka ', ln)]


def flag_problems(flags, lines):
    if flags is None:
        return ["the script has no $prodFlags line"]
    found = []
    if len(lines) != 2:
        found.append("expected 2 Nuitka command lines in run_setup.bat, found %d" % len(lines))
    for ln in lines:
        if flags not in ln:
            found.append("a Nuitka command line does not carry the script's flags: %s" % ln.strip()[:120])
    return found


def step_problems(workflow_text):
    """The experiment's step must exist, run on the uv lane only and be non-gating."""
    lines = workflow_text.splitlines()
    idx = [i for i, ln in enumerate(lines) if "selfapps_nuitka_launchcache.ps1" in ln and "&" in ln]
    if len(idx) != 1:
        return ["expected exactly 1 step running selfapps_nuitka_launchcache.ps1, found %d" % len(idx)]
    start = idx[0]
    while start > 0 and not re.match(r"^      - name:", lines[start]):
        start -= 1
    block = "\n".join(lines[start:idx[0] + 1])
    found = []
    if "matrix.mode == 'uv'" not in block:
        found.append("the step is not restricted to the uv lane")
    if not re.search(r"^\s+continue-on-error:\s*true\s*$", block, re.MULTILINE):
        found.append("the step is not non-gating (continue-on-error: true)")
    return found


GOOD_STEP = """      - name: "Self-test: Nuitka onefile launch cache experiment (uv lane, non-gating)"
        if: ${{ matrix.mode == 'uv' }}
        continue-on-error: true
        shell: pwsh
        run: |
          & tests\\selfapps_nuitka_launchcache.ps1
"""


class FlagsMatchBatch(unittest.TestCase):
    def test_real_files_agree(self):
        flags = script_flags(SCRIPT.read_text(encoding="ascii"))
        lines = nuitka_command_lines(BATCH.read_text(encoding="ascii", errors="replace"))
        self.assertEqual(flag_problems(flags, lines), [])

    def test_a_changed_batch_line_is_caught(self):
        flags = "-m nuitka --onefile --remove-output"
        lines = ['"%HP_PY%" -m nuitka --onefile --remove-output -o a.exe', '"%HP_PY%" -m nuitka --onefile -o b.exe']
        self.assertEqual(len(flag_problems(flags, lines)), 1)

    def test_a_third_command_line_is_caught(self):
        flags = "-m nuitka --onefile"
        lines = ['"%HP_PY%" -m nuitka --onefile a'] * 3
        self.assertIn("expected 2", flag_problems(flags, lines)[0])

    def test_a_missing_flags_line_is_caught(self):
        self.assertEqual(flag_problems(script_flags("no flags here"), []), ["the script has no $prodFlags line"])


class WorkflowStep(unittest.TestCase):
    def test_real_workflow_step_is_uv_only_and_non_gating(self):
        self.assertEqual(step_problems(WORKFLOW.read_text(encoding="utf-8")), [])

    def test_a_gating_step_is_caught(self):
        self.assertEqual(
            step_problems(GOOD_STEP.replace("        continue-on-error: true\n", "")),
            ["the step is not non-gating (continue-on-error: true)"],
        )

    def test_a_step_on_every_lane_is_caught(self):
        self.assertEqual(
            step_problems(GOOD_STEP.replace("        if: ${{ matrix.mode == 'uv' }}\n", "")),
            ["the step is not restricted to the uv lane"],
        )

    def test_a_missing_step_is_caught(self):
        self.assertIn("found 0", step_problems("      - name: other\n        run: echo hi\n")[0])


class RowIsEmittedByTheScript(unittest.TestCase):
    def test_script_emits_the_registered_row(self):
        self.assertIn("id = '%s'" % ROW_ID, SCRIPT.read_text(encoding="ascii"))

    def test_script_ends_with_its_own_exit_codes(self):
        # A pwsh step appends exit $LASTEXITCODE, so the last native command's code would otherwise leak.
        tail = [ln.strip() for ln in SCRIPT.read_text(encoding="ascii").splitlines() if ln.strip()][-2:]
        self.assertEqual(tail, ["if (-not $pass) { exit 1 }", "exit 0"])


if __name__ == "__main__":
    unittest.main()
