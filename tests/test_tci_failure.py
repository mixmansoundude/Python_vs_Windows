"""Item 46 Batch 6: a failed Miniconda install must not end the run.

`:tci_both_failed` used to end in `call :die`. `:die` is the end-of-run routine (state `error`, status file written,
lock released, a key press unless the CI marker is set), but both callers of `:try_conda_install` go on: the main flow
tries embedded Python, venv and system next, and the uv to conda cascade keeps the build it already has. The behavior
is proven on Windows by `tests/selfapps_conda_install_fail.ps1` (rows `self.conda.installfail.*`); this file pins what
CI cannot show cheaply: the script's shape (literal ids and tags, closed standard input, a process-tree kill, its own
exit codes), the log texts it looks for (still written by live lines of `run_setup.bat`), the two gating workflow
steps, the registry lines and the batch block itself.

Every rule has a synthetic case that makes it fail (a mutation on an anchor that occurs exactly once).
"""
import re
import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "tests" / "selfapps_conda_install_fail.ps1"
BATCH = REPO / "run_setup.bat"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"

ROW_TAGS = {
    "self.conda.installfail.control": "REQ-024",
    "self.conda.installfail.lock": "REQ-024",
    "self.conda.installfail.nopause": "REQ-009",
    "self.conda.installfail.cascade": "REQ-009",
}


def code_lines(text):
    return [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.strip().startswith("#")]


def script_problems(text):
    """Rules about the script itself."""
    found = []
    rows = dict(re.findall(r"id = '(self\.conda\.installfail\.[a-z]+)'; req = '([^']+)'", text))
    if rows != ROW_TAGS:
        found.append("row ids and tags are %r, expected %r" % (rows, ROW_TAGS))
    ids = re.findall(r"id = '(self\.conda\.installfail\.[a-z]+)'", text)
    if len(ids) != len(set(ids)):
        found.append("a row id is written at more than one call site: %r" % ids)
    for line in re.findall(r"^\s*#.*req\s*=\s*'", text, re.MULTILINE):
        found.append("a comment contains the req = '...' shape, which the trace readers count as a tag: %r" % line.strip())
    lines = code_lines(text)
    if not lines or lines[-1] != "exit 0":
        found.append("the script does not end with exit 0 (last line: %r)" % (lines[-1] if lines else ""))
    if sum(1 for ln in lines if re.match(r"if \(.*\) \{ exit 1 \}$", ln)) < 2:
        found.append("the script does not exit 1 when a row is red in both scenarios")
    launches = [ln for ln in lines if "run_setup.bat" in ln and ("call run_setup.bat" in ln) and ">" in ln]
    if len(launches) < 2:
        found.append("expected a fallback and a cascade launch line, found %d" % len(launches))
    for ln in launches:
        if "< nul" not in ln:
            found.append("a launch of the bootstrapper does not close standard input: %r" % ln)
    if len(re.findall(r"taskkill\.exe /F /T /PID", text)) < 2:
        found.append("every scenario needs a process-tree kill (taskkill /F /T /PID), found fewer than two")
    for needle in ('\'set "HP_OFFLINE_MODE=1"\'', '\'set "HP_TEST_FORCE_UV_FAIL=1"\'', '\'set "HP_TEST_NOT_ELEVATED=1"\'',
                   '\'set "HP_TEST_FORCE_JUSTME_FAIL=1"\'', "HP_TEST_NOT_ELEVATED       = '1'", "HP_TEST_FORCE_JUSTME_FAIL  = '1'",
                   "HP_TEST_LASTCHANCE_ANSWER  = 'C'", "HP_MINICONDA_URL           = $stubUrl"):
        if needle not in text:
            found.append("the script no longer sets %s" % needle)
    if "set \"' + $n + '=\"'" not in text:
        found.append("the fallback wrapper does not clear each HP_*/PVW_*/NOINPUT variable with set \"NAME=\"")
    if "$lockAtVenv = [bool](Test-Path -LiteralPath $lockDir)" not in text:
        found.append("the lock folder is no longer looked at once when the venv line appears")
    return found


# Texts the rows search for, and the kind of line of run_setup.bat that has to write them.
LOG_TEXTS = [
    "Miniconda install failed (AllUsers skipped -- not elevated; JustMe also failed)",
    "HP_TEST_FORCE_JUSTME_FAIL=1; simulating JustMe install failure",
    "Attempting venv fallback",
    "REQ-009: cascade to conda unavailable (Miniconda not installed); keeping current build.",
    "cascading provider uv to conda",
    "Last chance: cascade approved",
]


def batch_text_problems(batch):
    found = []
    live = [ln for ln in batch.splitlines() if re.match(r"\s*(?:\(|if |else |\) else \()?.*call :(?:log|die) ", ln)]
    for text in LOG_TEXTS:
        if not any(text in ln for ln in live):
            found.append("no live call :log or call :die line writes %r any more" % text)
    # The script reads the pause from the console text; its words must be what pause prints on Windows.
    return found


def tci_block(batch):
    """The lines of :tci_both_failed up to the next label."""
    lines = batch.splitlines()
    start = [i for i, ln in enumerate(lines) if ln.strip() == ":tci_both_failed"]
    if len(start) != 1:
        return None
    out = []
    for ln in lines[start[0] + 1:]:
        if ln.startswith(":"):
            break
        out.append(ln)
    return out


def tci_problems(batch):
    """The block itself: it reports and returns, it never ends the run."""
    block = tci_block(batch)
    if block is None:
        return ["the label :tci_both_failed must exist exactly once"]
    found = []
    live = [ln for ln in block if not ln.lstrip().lower().startswith("rem ")]
    if any("call :die" in ln for ln in live):
        found.append(":tci_both_failed still calls :die (state error, status written, lock released, key press), "
                     "but both callers go on with the next provider or keep the build")
    for text in ("Miniconda install failed (both AllUsers and JustMe).",
                 "Miniconda install failed (AllUsers skipped -- not elevated; JustMe also failed)."):
        if not any("call :log" in ln and text in ln for ln in live):
            found.append("the block no longer reports %r with call :log" % text)
    if not any(ln.strip() == "goto :eof" for ln in live):
        found.append("the block no longer returns to its caller with goto :eof")
    return found


def step_blocks(text):
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    out = []
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        out.append("\n".join(lines[start:end]))
    return out


def workflow_problems(text):
    found = []
    blocks = [b for b in step_blocks(text) if "selfapps_conda_install_fail.ps1" in b]
    if len(blocks) != 2:
        return ["expected two workflow steps that run selfapps_conda_install_fail.ps1, found %d" % len(blocks)]
    fallback = [b for b in blocks if "CONDA_INSTALL_FAIL_SCENARIO" not in b]
    cascade = [b for b in blocks if "CONDA_INSTALL_FAIL_SCENARIO: cascade" in b]
    if len(fallback) != 1 or len(cascade) != 1:
        return ["one step must run the default (fallback) scenario and one CONDA_INSTALL_FAIL_SCENARIO: cascade"]
    if "matrix.mode == 'real'" not in fallback[0]:
        found.append("the fallback step must run on the real lane")
    if "matrix.mode == 'contract-uv'" not in cascade[0]:
        found.append("the cascade step must run on the contract-uv lane")
    for b in blocks:
        if "continue-on-error" in b:
            found.append("a step of this script has continue-on-error: it gates from its first run")
        if "!cancelled()" not in b:
            found.append("a step of this script lost its !cancelled() condition")
        if "shell: pwsh" not in b:
            found.append("a step of this script does not run under pwsh")
    if "tests/~selftest_installfail_evidence/*" not in text or "tests\\~selftest_installfail_evidence\\*" not in text:
        found.append("the test-logs upload no longer collects tests/~selftest_installfail_evidence")
    return found


def registry_problems(doc):
    found = []
    fenced = []
    inside = False
    for ln in doc.splitlines():
        if ln.startswith("```"):
            inside = not inside
            continue
        if inside:
            fenced.append(ln.strip())
    for rid in ROW_TAGS:
        if rid not in fenced:
            found.append("%s is not on a fenced line of docs/agent-ndjson.md" % rid)
    return found


def mutate(text, anchor, replacement):
    assert text.count(anchor) == 1, "anchor must occur exactly once: %r (found %d)" % (anchor, text.count(anchor))
    return text.replace(anchor, replacement)


class ScriptShape(unittest.TestCase):
    def setUp(self):
        self.text = SCRIPT.read_text(encoding="utf-8")

    def test_script(self):
        self.assertEqual(script_problems(self.text), [])

    def test_script_is_ascii(self):
        self.text.encode("ascii")

    def test_wrong_tag_is_caught(self):
        bad = mutate(self.text, "id = 'self.conda.installfail.lock'; req = 'REQ-024'", "id = 'self.conda.installfail.lock'; req = 'REQ-099'")
        self.assertTrue(any("row ids and tags" in f for f in script_problems(bad)))

    def test_renamed_id_is_caught(self):
        bad = mutate(self.text, "id = 'self.conda.installfail.cascade'", "id = 'self.conda.installfail.cascaded'")
        self.assertTrue(any("row ids and tags" in f for f in script_problems(bad)))

    def test_comment_with_tag_shape_is_caught(self):
        bad = mutate(self.text, "# derived requirement: ids stay literal", "# example: req = 'REQ-001' would count\n# derived requirement: ids stay literal")
        self.assertTrue(any("req = '...' shape" in f for f in script_problems(bad)))

    def test_open_standard_input_is_caught(self):
        bad = mutate(self.text, "$lines += 'call run_setup.bat app.py > ~console.log 2>&1 < nul'", "$lines += 'call run_setup.bat app.py > ~console.log 2>&1'")
        self.assertTrue(any("close standard input" in f for f in script_problems(bad)))

    def test_missing_kill_is_caught(self):
        bad = mutate(self.text, "& taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null\n        $null = $proc.WaitForExit(30000)\n    }\n} finally {",
                     "$null = $proc.WaitForExit(30000)\n    }\n} finally {")
        self.assertTrue(any("process-tree kill" in f for f in script_problems(bad)))

    def test_missing_final_exit_is_caught(self):
        bad = mutate(self.text, "if (-not $pass) { exit 1 }\nexit 0\n", "if (-not $pass) { exit 1 }\n")
        self.assertTrue(any("does not end with exit 0" in f for f in script_problems(bad)))

    def test_missing_red_exit_is_caught(self):
        bad = mutate(self.text, "    if (-not ($ctlPass -and $lockPass -and $pausePass)) { exit 1 }\n", "")
        self.assertTrue(any("exit 1 when a row is red" in f for f in script_problems(bad)))

    def test_dropped_hook_is_caught(self):
        bad = mutate(self.text, "$lines += 'set \"HP_TEST_FORCE_JUSTME_FAIL=1\"'", "$lines += 'rem'")
        self.assertTrue(any("HP_TEST_FORCE_JUSTME_FAIL=1" in f for f in script_problems(bad)))

    def test_lock_look_removed_is_caught(self):
        bad = mutate(self.text, "$lockAtVenv = [bool](Test-Path -LiteralPath $lockDir)", "$lockAtVenv = $true")
        self.assertTrue(any("looked at once" in f for f in script_problems(bad)))

    def test_flag_clearing_removed_is_caught(self):
        bad = mutate(self.text, "foreach ($n in $flagNames) { $lines += ('set \"' + $n + '=\"') }", "")
        self.assertTrue(any("does not clear each" in f for f in script_problems(bad)))


class BatchSide(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")

    def test_log_texts_are_still_written(self):
        self.assertEqual(batch_text_problems(self.batch), [])

    def test_missing_log_text_is_caught(self):
        bad = mutate(self.batch, "Attempting venv fallback...", "Trying a venv...")
        self.assertTrue(any("Attempting venv fallback" in f for f in batch_text_problems(bad)))


class WorkflowSide(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_steps(self):
        self.assertEqual(workflow_problems(self.text), [])

    def test_wrong_lane_is_caught(self):
        bad = mutate(self.text, "      - name: \"Self-test: a failed Miniconda install keeps the lock and does not wait for a key (real only)\"\n        if: ${{ !cancelled() && matrix.mode == 'real' }}",
                     "      - name: \"Self-test: a failed Miniconda install keeps the lock and does not wait for a key (real only)\"\n        if: ${{ !cancelled() && matrix.mode == 'uv' }}")
        self.assertTrue(any("real lane" in f for f in workflow_problems(bad)))

    def test_continue_on_error_is_caught(self):
        bad = mutate(self.text, "        env:\n          CONDA_INSTALL_FAIL_SCENARIO: cascade\n",
                     "        continue-on-error: true\n        env:\n          CONDA_INSTALL_FAIL_SCENARIO: cascade\n")
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(bad)))

    def test_missing_scenario_env_is_caught(self):
        bad = mutate(self.text, "          CONDA_INSTALL_FAIL_SCENARIO: cascade\n", "          OTHER: cascade\n")
        self.assertTrue(workflow_problems(bad))

    def test_missing_evidence_is_caught(self):
        bad = mutate(self.text, "            tests/~selftest_installfail_evidence/*\n", "")
        self.assertTrue(any("test-logs upload" in f for f in workflow_problems(bad)))


class RegistrySide(unittest.TestCase):
    def test_ids_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_unfenced_id_is_caught(self):
        doc = "```\nself.conda.installfail.control\nself.conda.installfail.lock\nself.conda.installfail.nopause\n```\nself.conda.installfail.cascade\n"
        self.assertEqual(len(registry_problems(doc)), 1)


@unittest.skipUnless(shutil.which("pwsh"), "pwsh is not installed")
class JudgingHelpersRunThroughPwsh(unittest.TestCase):
    """Get-Between decides the key-press rows; run the real function on synthetic console text."""

    @classmethod
    def setUpClass(cls):
        text = SCRIPT.read_text(encoding="utf-8")
        m = re.search(r"^function Get-Between \{.*?^\}\n", text, re.MULTILINE | re.DOTALL)
        assert m, "Get-Between not found at the start of a line"
        cls.func = m.group(0)

    def run_ps(self, text, a, b):
        script = self.func + "\n$r = Get-Between -Text $env:T -From $env:A -To $env:B\nif ($null -eq $r) { 'NULL' } else { 'GOT:' + $r }\n"
        import os
        env = dict(os.environ, T=text, A=a, B=b)
        out = subprocess.run(["pwsh", "-NoProfile", "-Command", script], capture_output=True, text=True, env=env, timeout=60)
        return out.stdout.rstrip("\r\n")

    def test_window_between_markers(self):
        self.assertEqual(self.run_ps("x FAIL y Press any key z VENV w", "FAIL", "VENV"), "GOT:FAIL y Press any key z ")

    def test_missing_first_marker_is_null(self):
        self.assertEqual(self.run_ps("x y VENV", "FAIL", "VENV"), "NULL")

    def test_missing_second_marker_is_null(self):
        self.assertEqual(self.run_ps("x FAIL y", "FAIL", "VENV"), "NULL")

    def test_out_of_order_markers_are_null(self):
        self.assertEqual(self.run_ps("VENV then FAIL", "FAIL", "VENV"), "NULL")


if __name__ == "__main__":
    unittest.main()
