"""Item 114: README REQ-004.3 and REQ-004.4 shown by two rows of tests/selfapps_contract_uv.ps1, and the judging behind them.

`self.contract.uv.pyver.conflict` bootstraps a folder whose runtime.txt names 3.12 and whose pyproject.toml asks for 3.13 or
newer (and, as the control, the same pyproject.toml alone) and requires the 3.12.x interpreter; `self.contract.uv.pyver.nopin`
bootstraps a folder with neither file and compares the interpreter with the one a plain `uv venv --seed` gives. Both run in
the contract-uv lane. This file pins what the rows assume of run_setup.bat (the two log lines and the version-less uv call),
runs the script's judging functions through a real pwsh on synthetic runs that must be red (skipped where pwsh is absent),
and pins the script's literal ids, tags and the helper that now writes both files or neither. Synthetic cases prove each
rule can fail.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools import check_ndjson_registry

REPO = Path(__file__).resolve().parent.parent
BAT = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_contract_uv.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
README = REPO / "README.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120

ROWS = {
    "self.contract.uv.pyver.conflict": "REQ-004.3",
    "self.contract.uv.pyver.nopin": "REQ-004.4",
}
WITH_VERSION_LOG = '[INFO] uv: creating venv at .uv_env with Python %HP_UV_PY_DISP%...'
NO_VERSION_LOG = '[INFO] uv: creating venv at .uv_env...'
NO_VERSION_CALL = '"%HP_UV_EXE%" venv --seed "%HP_UV_ENV_PATH%" >> "%LOG%" 2>&1'
STEP_NAME = "Self-test: uv contract assertions (contract-uv* only)"


def _bat():
    return BAT.read_text(encoding="utf-8", errors="replace")


def batch_problems(text):
    """The two log lines the rows read, and the uv call made when no version was asked for, each as a live line."""
    found = []
    lines = [l.strip() for l in text.split("\n")]
    for wanted in (WITH_VERSION_LOG, NO_VERSION_LOG):
        n = sum(1 for l in lines if l == 'call :log "%s"' % wanted)
        if n != 1:
            found.append("`call :log \"%s\"` occurs %d times, the rows read it once" % (wanted, n))
    n = sum(1 for l in lines if l == NO_VERSION_CALL)
    if n != 1:
        found.append("the version-less uv call %s occurs %d times, expected exactly 1" % (NO_VERSION_CALL, n))
    order = [i for i, l in enumerate(lines) if l in ('call :log "%s"' % NO_VERSION_LOG, NO_VERSION_CALL)]
    if len(order) == 2 and not (order[0] < order[1]):
        found.append("the version-less log line has to come before the version-less uv call")
    if not any(l == '"%HP_UV_EXE%" venv --seed --python "%HP_UV_PY_REQ%" "%HP_UV_ENV_PATH%" >> "%LOG%" 2>&1' for l in lines):
        found.append("the uv call that forwards a version is gone, the conflict row reads its log line")
    return found


def script_problems(text):
    found = []
    for row, tag in ROWS.items():
        pair = re.compile(r"id\s*=\s*'%s'\s*\r?\n\s*req\s*=\s*'%s'" % (re.escape(row), re.escape(tag)))
        n = len(pair.findall(text))
        if n != 1:
            found.append("%s: the id with the tag %r occurs %d times, expected 1" % (row, tag, n))
    for needle in (
        "function Get-ConflictProblems",
        "function Get-NoPinProblems",
        "function Get-PyMinor",
        "function Get-PyvenvVersion",
        "-RuntimePython '3.12' -RequiresPython '>=3.13'",
        "-Name '~uv_pyver_conflict_control' -RequiresPython '>=3.13'",
        "$env:UV_PYTHON_PREFERENCE = 'only-managed'",
        "& $uvBin venv --seed $refDir",
    ):
        if needle not in text:
            found.append("the script no longer holds %r" % needle)
    # The helper writes each file on its own condition, so a scenario can hold both or neither.
    helper = re.search(r"function Invoke-UvPyverScenario \{.*?\n\}\r?\n", text, re.S)
    if not helper:
        found.append("Invoke-UvPyverScenario is missing")
    else:
        body = helper.group(0)
        if "} else {" in body.split("$scenarioLog")[0]:
            found.append("Invoke-UvPyverScenario writes runtime.txt or pyproject.toml with an else, so it cannot write both")
        if body.count("if ($RuntimePython) {") != 1 or body.count("if ($RequiresPython) {") != 1:
            found.append("Invoke-UvPyverScenario no longer writes each file on its own condition")
    if "uv-not-acquired" not in text.split("self.contract.uv.pyver.conflict")[1]:
        found.append("the new rows no longer fail when uv was not acquired")
    if not text.rstrip().endswith("if ($script:AnyRowFailed) { exit 1 }\nexit 0".replace("\n", "\r\n")) and not text.rstrip().endswith("if ($script:AnyRowFailed) { exit 1 }\nexit 0"):
        found.append("the script does not end with its own exit 1 / exit 0")
    return found


def step_problems(text):
    found = []
    marker = '- name: "%s"' % STEP_NAME
    if marker not in text:
        return ["the workflow has no step named %r" % STEP_NAME]
    block = text[text.index(marker):]
    block = block[:block.index("\n      - name:", 10)] if "\n      - name:" in block[10:] else block
    if "matrix.mode == 'contract-uv'" not in block:
        found.append("the step does not run in the contract-uv lane")
    if "& tests\\selfapps_contract_uv.ps1" not in block:
        found.append("the step does not run tests\\selfapps_contract_uv.ps1")
    return found


DRIVER = r"""
# The judging functions are cut out of the script by name and run in a scope that has nothing else: strict mode (an unset
# variable is an error and not $null), and the driver's own variables start with two underscores.
Set-StrictMode -Version 1.0
$__tokens = $null; $__errs = $null
$__ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PY_SCRIPT, [ref]$__tokens, [ref]$__errs)
if ($__errs.Count -gt 0) { throw ('parse errors: ' + $__errs[0].Message) }
$__want = @($env:PY_WANT -split ',')
$__defs = $__ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $__want -contains $n.Name }, $true)
if (@($__defs).Count -ne $__want.Count) { throw 'a judging function is missing from the script' }
foreach ($__f in $__defs) { Invoke-Expression $__f.Extent.Text }
$__cases = Get-Content -LiteralPath $env:PY_CASES -Raw | ConvertFrom-Json
$__all = New-Object System.Collections.ArrayList
foreach ($__c in $__cases) {
    $__h = @{}
    foreach ($__p in $__c.args.PSObject.Properties) { $__h[$__p.Name] = [string]$__p.Value }
    $__r = @(& $__c.fn @__h)
    [void]$__all.Add([ordered]@{ name = $__c.name; problems = @($__r) })
}
ConvertTo-Json -InputObject @($__all) -Compress -Depth 8
"""
WANT = "Get-PyMinor,Get-ConflictProblems,Get-NoPinProblems"


def run_cases(cases, tmp):
    tmp = Path(tmp)
    (tmp / "cases.json").write_text(json.dumps(cases), encoding="ascii")
    (tmp / "driver.ps1").write_text(DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["PY_SCRIPT"] = str(SCRIPT)
    env["PY_WANT"] = WANT
    env["PY_CASES"] = str(tmp / "cases.json")
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(tmp / "driver.ps1")], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return {item["name"]: item["problems"] for item in json.loads(proc.stdout)}


LOG_312 = "[INFO] uv: creating venv at .uv_env with Python 3.12...\r\n[INFO] uv: venv created"
LOG_NEWER = "[INFO] uv: creating venv at .uv_env with Python 3.12 or newer..."
LOG_NONE = "[INFO] uv: creating venv at .uv_env...\r\n[INFO] uv: venv created"


def _conflict(name, control, conflict, log):
    return {"name": name, "fn": "Get-ConflictProblems",
            "args": {"ControlVersion": control, "ConflictVersion": conflict, "ConflictLog": log}}


def _nopin(name, bootstrap, reference, log):
    return {"name": name, "fn": "Get-NoPinProblems",
            "args": {"BootstrapVersion": bootstrap, "ReferenceVersion": reference, "BootstrapLog": log}}


@unittest.skipIf(PWSH is None, "pwsh is not installed here")
class JudgingRunsInPwsh(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cases = [
            _conflict("conflict_good", "3.15.0", "3.12.10", LOG_312),
            _conflict("conflict_pyproject_won", "3.15.0", "3.15.0", LOG_312),
            _conflict("conflict_control_not_newer", "3.12.10", "3.12.10", LOG_312),
            _conflict("conflict_no_control", "", "3.12.10", LOG_312),
            _conflict("conflict_no_interpreter", "3.15.0", "", LOG_312),
            _conflict("conflict_floor", "3.15.0", "3.12.10", LOG_NEWER),
            _conflict("conflict_no_line", "3.15.0", "3.12.10", "[INFO] uv: venv created"),
            _nopin("nopin_good", "3.15.0", "3.15.0", LOG_NONE),
            _nopin("nopin_differs", "3.12.10", "3.15.0", LOG_NONE),
            _nopin("nopin_no_reference", "3.15.0", "", LOG_NONE),
            _nopin("nopin_no_bootstrap", "", "3.15.0", LOG_NONE),
            _nopin("nopin_forwarded", "3.15.0", "3.15.0", LOG_312),
            _nopin("nopin_no_line", "3.15.0", "3.15.0", "[INFO] uv: venv created"),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            cls.out = run_cases(cases, tmp)

    def test_the_good_runs_have_no_problem(self):
        self.assertEqual(self.out["conflict_good"], [])
        self.assertEqual(self.out["nopin_good"], [])

    def test_each_bad_conflict_run_is_red_for_its_own_reason(self):
        self.assertTrue(any("expected 3.12.x" in p for p in self.out["conflict_pyproject_won"]))
        self.assertTrue(any("control" in p for p in self.out["conflict_control_not_newer"]))
        self.assertTrue(any("control" in p for p in self.out["conflict_no_control"]))
        self.assertTrue(any("expected 3.12.x" in p for p in self.out["conflict_no_interpreter"]))
        self.assertTrue(any("3.12 or newer" in p for p in self.out["conflict_floor"]))
        self.assertTrue(any("forwards 3.12" in p for p in self.out["conflict_no_line"]))

    def test_each_bad_nopin_run_is_red_for_its_own_reason(self):
        self.assertTrue(any("plain uv venv gives" in p for p in self.out["nopin_differs"]))
        self.assertTrue(any("reference" in p for p in self.out["nopin_no_reference"]))
        self.assertTrue(any("no .uv_env interpreter" in p for p in self.out["nopin_no_bootstrap"]))
        self.assertTrue(any("forwards a version" in p for p in self.out["nopin_forwarded"]))
        self.assertTrue(any("without a version" in p for p in self.out["nopin_no_line"]))


def _lines():
    return _bat()


class BatchSide(unittest.TestCase):
    def test_the_logged_lines_and_the_uv_calls_are_what_the_rows_read(self):
        self.assertEqual(batch_problems(_bat()), [])


class ScriptSide(unittest.TestCase):
    def test_script_holds_its_rows_and_parts(self):
        self.assertEqual(script_problems(SCRIPT.read_text(encoding="utf-8")), [])

    def test_script_is_crlf_ascii(self):
        raw = SCRIPT.read_bytes()
        self.assertTrue(all(b < 128 for b in raw), "non-ASCII byte in the script")
        self.assertNotIn(b"\n", raw.replace(b"\r\n", b""), "a bare LF in a .ps1 file")

    def test_the_registry_lists_the_rows(self):
        ids, _many = check_ndjson_registry.parse_doc_registry(REPO / "docs" / "agent-ndjson.md")
        for row in ROWS:
            self.assertIn(row, ids)

    def test_the_readme_names_the_rows(self):
        text = README.read_text(encoding="utf-8")
        for row in ROWS:
            self.assertIn(row, text, row)

    def test_the_shalls_with_a_row_are_no_longer_listed_as_untraced(self):
        text = SHALL_TRACE.read_text(encoding="utf-8")
        for shall in ROWS.values():
            self.assertNotIn('"%s":' % shall, text, "%s has a row now; delete its UNTRACED_SHALLS entry" % shall)

    def test_the_step_runs_the_script_in_the_contract_lane(self):
        self.assertEqual(step_problems(WORKFLOW.read_text(encoding="utf-8")), [])


class SyntheticRulesCanFail(unittest.TestCase):
    def test_a_reworded_log_line_is_reported(self):
        text = _bat().replace("[INFO] uv: creating venv at .uv_env...\"", "[INFO] uv: making the venv\"")
        self.assertTrue(batch_problems(text))
        text = _bat().replace("with Python %HP_UV_PY_DISP%...", "with Python %HP_UV_PY_DISP%")
        self.assertTrue(batch_problems(text))

    def test_a_changed_version_less_call_is_reported(self):
        self.assertTrue(batch_problems(_bat().replace('venv --seed "%HP_UV_ENV_PATH%" >>', 'venv "%HP_UV_ENV_PATH%" >>')))

    def test_a_script_without_a_row_a_tag_or_the_exit_is_reported(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(script_problems(text.replace("self.contract.uv.pyver.nopin", "self.contract.uv.pyver.other")))
        self.assertTrue(script_problems(text.replace("req     = 'REQ-004.3'", "req     = 'REQ-004.9'")))
        self.assertTrue(script_problems(text.replace("exit 0", "")))
        self.assertTrue(script_problems(text.replace("-Name '~uv_pyver_conflict_control' -RequiresPython '>=3.13'", "-Name '~uv_pyver_conflict_control' -RequiresPython '>=3.9'")))

    def test_a_helper_that_cannot_write_both_files_is_reported(self):
        text = SCRIPT.read_text(encoding="utf-8")
        mutated = text.replace("    }\r\n    if ($RequiresPython) {", "    } else {", 1) if "    }\r\n    if ($RequiresPython) {" in text else text.replace("    }\n    if ($RequiresPython) {", "    } else {", 1)
        self.assertNotEqual(text, mutated)
        self.assertTrue(any("else" in p or "own condition" in p for p in script_problems(mutated)))

    def test_a_step_on_another_lane_or_script_is_reported(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertTrue(step_problems(text.replace(STEP_NAME, "Renamed step")))
        marker = '- name: "%s"\n        if: ${{ matrix.mode == \'contract-uv\' || matrix.mode == \'contract-uv-fail\' }}' % STEP_NAME
        self.assertIn(marker, text)
        self.assertTrue(step_problems(text.replace(marker, marker.replace("contract-uv'", "uv'", 1), 1)))


if __name__ == "__main__":
    unittest.main()
