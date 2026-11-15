"""Item 115: README REQ-003.2 (the Miniconda that conda uses is the one under %PUBLIC%\\Documents\\Miniconda3) shown by one row.

`self.env.smoke.minicondafolder` (tests/selfapps_envsmoke.ps1, every lane that runs that script) reads the setup log of the
envsmoke bootstrap: when conda was the selected provider, the interpreter the bootstrap printed has to sit in an environment
folder of the Miniconda under PUBLIC and its conda.bat has to be there. A GitHub runner image holds a Miniconda of its own
(C:\\Miniconda3), which the script's search for conda.bat falls back to, so the printed interpreter path is what shows which
one was used. In a lane where uv is the provider the row skips; with HP_FORCE_CONDA_ONLY=1 (conda-full) a missing provider
line fails it.

This file pins what the row assumes of run_setup.bat (the folder, the environment path, the provider line, the Interpreter
line), runs the script's judging function through a real pwsh on synthetic runs that must be red (skipped where pwsh is
absent), and pins the literal id and tag. Synthetic cases prove each rule can fail.
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
SCRIPT = REPO / "tests" / "selfapps_envsmoke.ps1"
README = REPO / "README.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120

ROW = "self.env.smoke.minicondafolder"
TAG = "REQ-003.2"
# Each must be a live line of the batch, exactly once (the first two) or at least once (the environment path is set in three places).
BAT_ONCE = (
    'set "MC=%PUBLIC%\\Documents\\Miniconda3"',
    'set "CONDA_MAIN=%MC%\\condabin\\conda.bat"',
    'set "CONDA_ALT=%MC%\\Scripts\\conda.bat"',
    'set "MINICONDA_ROOT=%MC%"',
    'call :log "[BOOT] REQ-009: Selected Python provider: Conda (Portable)."',
    "echo Interpreter: %HP_PY%",
)
ENV_PATH_LINE = 'set "ENV_PATH=%MINICONDA_ROOT%\\envs\\%ENVNAME%"'


def batch_problems(text):
    found = []
    lines = [l.strip() for l in text.split("\n")]
    for wanted in BAT_ONCE:
        n = sum(1 for l in lines if l == wanted)
        if n != 1:
            found.append("the line %s occurs %d times, the row assumes exactly 1" % (wanted, n))
    if sum(1 for l in lines if l == ENV_PATH_LINE) < 1:
        found.append("no line sets ENV_PATH to the envs folder of MINICONDA_ROOT: %s" % ENV_PATH_LINE)
    return found


def script_problems(text):
    found = []
    pair = re.compile(r"id='%s'\s*\r?\n\s*req='%s'" % (re.escape(ROW), re.escape(TAG)))
    n = len(pair.findall(text))
    if n != 1:
        found.append("%s: the id with the tag %r occurs %d times, expected 1" % (ROW, TAG, n))
    for needle in (
        "function Get-CondaFolderProblems",
        "Get-CondaFolderProblems -CondaSelected $folderCondaSelected -ForcedConda $folderForced",
        "Selected Python provider: Conda (Portable)",
        "$env:HP_FORCE_CONDA_ONLY -eq '1'",
        "[Environment]::GetEnvironmentVariable('PUBLIC')",
        "'\\Documents\\Miniconda3'",
    ):
        if needle not in text:
            found.append("the script no longer holds %r" % needle)
    return found


DRIVER = r"""
# The judging function is cut out of the script by name and run in a scope that has nothing else: strict mode (an unset
# variable is an error and not $null), and the driver's own variables start with two underscores.
Set-StrictMode -Version 1.0
$__tokens = $null; $__errs = $null
$__ast = [System.Management.Automation.Language.Parser]::ParseFile($env:MF_SCRIPT, [ref]$__tokens, [ref]$__errs)
if ($__errs.Count -gt 0) { throw ('parse errors: ' + $__errs[0].Message) }
$__defs = $__ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CondaFolderProblems' }, $true)
if (@($__defs).Count -ne 1) { throw 'the judging function is missing from the script' }
foreach ($__f in $__defs) { Invoke-Expression $__f.Extent.Text }
$__cases = Get-Content -LiteralPath $env:MF_CASES -Raw | ConvertFrom-Json
$__all = New-Object System.Collections.ArrayList
foreach ($__c in $__cases) {
    $__h = @{}
    foreach ($__p in $__c.args.PSObject.Properties) { $__h[$__p.Name] = $__p.Value }
    $__r = @(Get-CondaFolderProblems @__h)
    [void]$__all.Add([ordered]@{ name = $__c.name; problems = @($__r) })
}
ConvertTo-Json -InputObject @($__all) -Compress -Depth 8
"""

PUBLIC = "C:\\Users\\Public"
GOOD_PY = "C:\\Users\\Public\\Documents\\Miniconda3\\envs\\_envsmoke\\python.exe"


def _case(name, **over):
    args = {"CondaSelected": True, "ForcedConda": True, "PublicRoot": PUBLIC, "InterpreterPath": GOOD_PY,
            "CondaBatExists": True, "EnvName": "_envsmoke"}
    args.update(over)
    return {"name": name, "args": args}


def run_cases(cases, tmp):
    tmp = Path(tmp)
    (tmp / "cases.json").write_text(json.dumps(cases), encoding="ascii")
    (tmp / "driver.ps1").write_text(DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["MF_SCRIPT"] = str(SCRIPT)
    env["MF_CASES"] = str(tmp / "cases.json")
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(tmp / "driver.ps1")], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return {item["name"]: item["problems"] for item in json.loads(proc.stdout)}


@unittest.skipIf(PWSH is None, "pwsh is not installed here")
class JudgingRunsInPwsh(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cases = [
            _case("good"),
            _case("good_trailing_backslash_and_case", PublicRoot="c:\\users\\public\\",
                  InterpreterPath="C:\\USERS\\PUBLIC\\Documents\\Miniconda3\\envs\\_EnvSmoke\\python.exe"),
            _case("runner_miniconda", InterpreterPath="C:\\Miniconda3\\envs\\_envsmoke\\python.exe"),
            _case("base_not_an_env", InterpreterPath="C:\\Users\\Public\\Documents\\Miniconda3\\python.exe"),
            _case("another_env", InterpreterPath="C:\\Users\\Public\\Documents\\Miniconda3\\envs\\other\\python.exe"),
            _case("env_name_prefix_only", InterpreterPath="C:\\Users\\Public\\Documents\\Miniconda3\\envs\\_envsmoke2\\python.exe"),
            _case("no_interpreter_line", InterpreterPath=""),
            _case("no_conda_bat", CondaBatExists=False),
            _case("no_public", PublicRoot=""),
            _case("uv_lane_skips", CondaSelected=False, ForcedConda=False, InterpreterPath="C:\\w\\.uv_env\\Scripts\\python.exe", CondaBatExists=False),
            _case("forced_but_not_selected", CondaSelected=False, ForcedConda=True),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            cls.out = run_cases(cases, tmp)

    def test_good_runs_have_no_problem(self):
        self.assertEqual(self.out["good"], [])
        self.assertEqual(self.out["good_trailing_backslash_and_case"], [])
        self.assertEqual(self.out["uv_lane_skips"], [])

    def test_each_bad_run_is_red_for_its_own_reason(self):
        for name in ("runner_miniconda", "base_not_an_env", "another_env", "env_name_prefix_only"):
            self.assertTrue(any("is not under" in p for p in self.out[name]), name)
        self.assertTrue(any("no Interpreter line" in p for p in self.out["no_interpreter_line"]))
        self.assertTrue(any("conda.bat" in p for p in self.out["no_conda_bat"]))
        self.assertTrue(any("PUBLIC is not set" in p for p in self.out["no_public"]))
        self.assertTrue(any("forced" in p for p in self.out["forced_but_not_selected"]))


class BatchSide(unittest.TestCase):
    def test_the_folder_and_the_log_lines_are_what_the_row_reads(self):
        self.assertEqual(batch_problems(BAT.read_text(encoding="utf-8", errors="replace")), [])


class ScriptSide(unittest.TestCase):
    def test_script_holds_its_row_and_parts(self):
        self.assertEqual(script_problems(SCRIPT.read_text(encoding="utf-8")), [])

    def test_script_is_crlf_ascii(self):
        raw = SCRIPT.read_bytes()
        self.assertTrue(all(b < 128 for b in raw), "non-ASCII byte in the script")
        self.assertNotIn(b"\n", raw.replace(b"\r\n", b""), "a bare LF in a .ps1 file")

    def test_the_registry_lists_the_row(self):
        ids, _many = check_ndjson_registry.parse_doc_registry(REPO / "docs" / "agent-ndjson.md")
        self.assertIn(ROW, ids)

    def test_the_readme_names_the_row(self):
        self.assertIn(ROW, README.read_text(encoding="utf-8"))

    def test_the_shall_with_a_row_is_no_longer_listed_as_untraced(self):
        self.assertNotIn('"%s":' % TAG, SHALL_TRACE.read_text(encoding="utf-8"),
                         "%s has a row now; delete its UNTRACED_SHALLS entry" % TAG)


class SyntheticRulesCanFail(unittest.TestCase):
    def test_a_moved_miniconda_folder_is_reported(self):
        text = BAT.read_text(encoding="utf-8", errors="replace").replace('set "MC=%PUBLIC%\\Documents\\Miniconda3"', 'set "MC=%PUBLIC%\\Documents\\Conda"')
        self.assertTrue(batch_problems(text))

    def test_a_reworded_provider_line_or_interpreter_line_is_reported(self):
        text = BAT.read_text(encoding="utf-8", errors="replace")
        self.assertTrue(batch_problems(text.replace("Selected Python provider: Conda (Portable).", "Selected Python provider: conda.")))
        self.assertTrue(batch_problems(text.replace("echo Interpreter: %HP_PY%", "echo Python: %HP_PY%")))

    def test_a_changed_environment_path_is_reported(self):
        text = BAT.read_text(encoding="utf-8", errors="replace").replace(ENV_PATH_LINE, 'set "ENV_PATH=%MINICONDA_ROOT%\\%ENVNAME%"')
        self.assertTrue(batch_problems(text))

    def test_a_script_without_the_row_the_tag_or_the_function_is_reported(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(script_problems(text.replace(ROW, "self.env.smoke.other")))
        self.assertTrue(script_problems(text.replace("req='REQ-003.2'", "req='REQ-003.9'")))
        self.assertTrue(script_problems(text.replace("function Get-CondaFolderProblems", "function Get-Other")))
        self.assertTrue(script_problems(text.replace("'\\Documents\\Miniconda3'", "'\\Documents\\Conda'")))


if __name__ == "__main__":
    unittest.main()
