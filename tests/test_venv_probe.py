"""Item 113: README REQ-023 (venv fallback canary probe) shown with the real probe command, and the harness that does it.

`tests/selfapps_venv_probe.ps1` cuts `:try_venv_fallback` out of `run_setup.bat`, wraps it in a small driver and runs it with
cmd.exe against a compiled stub that plays both the system Python (`-m venv` builds `.venv\\Scripts\\python.exe` as a copy of
itself) and the interpreter inside the venv (its `-c "import sys"` exits with the code the scenario chose). The behavior is the
script's `self.venvprobe.*` rows. What they can prove depends on the block staying what the script assumes, and on the script's
own judging being right. This file pins both, so a change that moves a label, reads a variable the driver does not set or
rewords a logged line fails here with a message that names the script to update, and not after a two and a half hour run.

It reads text only, and runs the script's judging functions through a real pwsh on synthetic ledgers (skipped where pwsh is
absent), so a rule that cannot go red would be found here. Synthetic cases prove each rule can fail.
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
SCRIPT = REPO / "tests" / "selfapps_venv_probe.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
README = REPO / "README.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

# id -> req tag, literal in the script at two places (Write-AllRows and the real row).
ROWS = {
    "self.venvprobe.command": "REQ-023.1",
    "self.venvprobe.nofile": "REQ-023.1",
    "self.venvprobe.declines": "REQ-023.2, REQ-023.3",
    "self.venvprobe.crash": "REQ-023.2, REQ-023.3",
}
STEP_NAME = "Self-test: venv fallback probe with the real command (real only)"

# The cut: from the line that is exactly the first to the line that is exactly the second, each present exactly once.
BLOCK = (":try_venv_fallback", ":try_system_fallback")
BLOCK_LABELS = {":try_venv_fallback", ":venv_create_retry", ":venv_create_ok", ":venv_create_pip_ready", ":venv_canary_fail", ":venv_canary_ok"}
# Labels the block may reach outside itself. The script's driver defines each one.
EXTERNAL_LABELS = {":log", ":resolve_system_python", ":download_get_pip"}
# Variables the block reads that the driver sets (or the system always has).
DRIVER_VARIABLES = {"LOG", "HP_SYS_CMD", "HP_SYS_ARGS", "CD", "ERRORLEVEL"}
# Variables the block reads that the script leaves undefined on purpose: a test hook, or what the real get-pip step would set.
ABSENT_BY_DESIGN = {"HP_TEST_FORCE_VENV_FAIL", "HP_TEST_FORCE_VENV_CREATE_FAIL", "HP_TEST_FORCE_VENV_CANARY_FAIL", "HP_GETPIP_PY"}

PROBE_LINE = '"%HP_PY%" -c "import sys" >nul 2>&1'
CREATE_LINE = '"%HP_SYS_CMD%" -m venv .\\.venv >> "%LOG%" 2>&1'
# The texts the script's judging looks for exactly: the live `call :log` line of run_setup.bat that writes each one.
LOG_TEXTS = (
    "[WARN] venv fallback: interpreter created but failed canary probe (import sys).",
    "[WARN] venv fallback: interpreter missing after creation.",
    "[INFO] venv fallback ready: %HP_PY%",
    "[BOOT] REQ-009: Selected Python provider: Local venv (fallback).",
)


def _bat_lines():
    return [l.rstrip("\r") for l in BAT.read_text(encoding="utf-8", errors="replace").split("\n")]


def cut_block(lines, start, end):
    s = next((i for i, l in enumerate(lines) if l.strip() == start), None)
    if s is None:
        return None
    e = next((j for j in range(s + 1, len(lines)) if lines[j].strip() == end), None)
    if e is None:
        return None
    return lines[s:e]


def label_problems(lines):
    """Each cut line has to exist exactly once, or the script's Get-BatBlock takes the wrong one."""
    found = []
    trimmed = [l.strip() for l in lines]
    for edge in BLOCK:
        n = trimmed.count(edge)
        if n != 1:
            found.append("the line %r occurs %d times, the script needs exactly one" % (edge, n))
    return found


def block_problems(block):
    """What the cut-out block reaches outside itself that the driver does not provide."""
    found = []
    labels = {l.strip() for l in block if l.strip().startswith(":") and not l.strip().startswith("::")}
    if labels != BLOCK_LABELS:
        found.append("the block's labels are %s, the script's driver was written for %s" % (sorted(labels), sorted(BLOCK_LABELS)))
    assigned = set()
    for l in block:
        for m in re.finditer(r'set(?:\s+/a)?\s+"?([A-Za-z_][A-Za-z0-9_]*)[=+]', l, re.I):
            assigned.add(m.group(1))
    allowed = DRIVER_VARIABLES | ABSENT_BY_DESIGN | assigned
    for l in block:
        s = l.strip()
        if s.lower().startswith("rem "):
            continue
        for m in re.finditer(r"(?:goto|call)\s+(:[A-Za-z0-9_]+)", s, re.I):
            target = m.group(1)
            if target.lower() != ":eof" and target not in labels and target not in EXTERNAL_LABELS:
                found.append("reaches %s, which the driver does not define" % target)
        for v in re.findall(r"%([A-Za-z_][A-Za-z0-9_]*)(?::[^%]*)?%", s):
            if v not in allowed:
                found.append("uses %%%s%%, which the driver does not set and the script does not leave out on purpose" % v)
    return found


def shape_problems(block):
    """The order of the pieces the rows' verdicts read: creation, the interpreter check, the hook, the probe, the two exits."""
    found = []
    trimmed = [l.strip() for l in block]

    def at(text, start=0):
        return next((i for i in range(start, len(trimmed)) if trimmed[i] == text), None)

    create = at(CREATE_LINE)
    if create is None:
        found.append("no line creates the venv with %s (the script's stub answers `-m venv .\\.venv`)" % CREATE_LINE)
    pip_ready = at(":venv_create_pip_ready")
    probes = [i for i, l in enumerate(trimmed) if l == PROBE_LINE]
    if len(probes) != 1:
        found.append("the probe line %s occurs %d times, the rows expect exactly one" % (PROBE_LINE, len(probes)))
    elif pip_ready is None or probes[0] < pip_ready:
        found.append("the probe line does not come after :venv_create_pip_ready")
    elif block[probes[0]] != PROBE_LINE:
        found.append("the probe line is indented, so it sits inside a parenthesized block and its errorlevel is read at parse time")
    hook = at('if "%HP_TEST_FORCE_VENV_CANARY_FAIL%"=="1" goto :venv_canary_fail')
    if hook is None or (probes and hook > probes[0]):
        found.append("the canary hook is gone or sits after the probe, the rows assume it is absent and before the probe")
    exists = [i for i, l in enumerate(trimmed) if l == 'if not exist "%HP_PY%" (']
    if not exists or (probes and min(exists) > probes[0]):
        found.append("the check that the interpreter file exists no longer comes before the probe")
    fail = at(":venv_canary_fail")
    ok = at(":venv_canary_ok")
    if fail is None or ok is None or fail > ok:
        found.append(":venv_canary_fail and :venv_canary_ok are missing or out of order")
    else:
        tail = trimmed[fail:ok]
        if 'set "HP_PY="' not in tail or "exit /b 1" not in tail:
            found.append(":venv_canary_fail does not clear HP_PY and return 1")
        if tail.index('set "HP_PY="') > tail.index("exit /b 1") if ('set "HP_PY="' in tail and "exit /b 1" in tail) else False:
            found.append(":venv_canary_fail returns before it clears HP_PY")
        after = trimmed[ok:]
        for needed in ('set "HP_ENV_MODE=venv"', "exit /b 0"):
            if needed not in after:
                found.append(":venv_canary_ok does not hold %s" % needed)
    return found


def log_problems(bat_text):
    """Each text the script's judging looks for is written by a live call :log line of the batch."""
    found = []
    live = [l for l in bat_text.split("\n") if re.match(r"^\s*call :log ", l)]
    for wanted in LOG_TEXTS:
        if not any(('"%s"' % wanted) in l for l in live):
            found.append("no live `call :log` line of run_setup.bat holds exactly %r" % wanted)
    return found


def script_problems(text):
    """Literal ids and tags (the registry check and the trace tests read them as text), the stub and the exits."""
    found = []
    for row, tag in ROWS.items():
        pair = re.compile(r"id\s*=\s*'%s'\s*[;\n]\s*req\s*=\s*'%s'" % (re.escape(row), re.escape(tag)))
        n = len(pair.findall(text))
        if n != 2:
            found.append("%s: the id with the tag %r occurs %d times, expected 2 (Write-AllRows and the real row)" % (row, tag, n))
    for needle in (
        "Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe",
        "taskkill /F /T /PID",
        "'^(HP_|PVW_|VP_|NOINPUT$|NoDefaultCurrentDirectoryInExePath$)'",
        "'non-windows-host'",
        "Get-BatBlock -StartLine ':try_venv_fallback' -EndLine ':try_system_fallback'",
        "'call :try_venv_fallback'",
        "'-c|import sys'",
        "'-m|venv|.\\.venv'",
        "foreach ($code in @('1', '2', '255'))",
        "foreach ($code in @('-1', '-1073741515', '-1073741819'))",
        "args[0] == \"-m\" && args[1] == \"venv\"",
        "VP_PROBE_EXIT",
        "VP_VENV_MODE",
    ):
        if needle not in text:
            found.append("the script no longer holds %r" % needle)
    if not text.rstrip().endswith("if ($script:AnyRowFailed) { exit 1 }\nexit 0"):
        found.append("the script does not end with its own exit 1 / exit 0")
    return found


def step_problems(text):
    found = []
    marker = '- name: "%s"' % STEP_NAME
    if marker not in text:
        return ["the workflow has no step named %r" % STEP_NAME]
    i = text.index(marker)
    nxt = text.find("\n      - name:", i + 1)
    block = text[i:nxt]
    if "continue-on-error" in block:
        found.append("the step has continue-on-error, so a red row would not fail the lane")
    if "selfapps_venv_probe.ps1" not in block:
        found.append("the step does not run the script")
    if "matrix.mode == 'real'" not in block:
        found.append("the step is not on the real lane")
    for other in ("justme-test", "conda-full", "contract-uv", "uv-dl-fallback", "'uv'", "'cache'"):
        if other in block.split("run:")[0]:
            found.append("the step's condition also names %s; the script is written for one lane" % other)
    if "tests/~selftest_venvprobe/**" not in text:
        found.append("the artifact upload does not collect tests/~selftest_venvprobe/**")
    return found


# --- the script's own judging functions, run through a real pwsh ---

DRIVER = r"""
$ErrorActionPreference = 'Stop'
# A judging function may use only its parameters and its own locals. Strict mode makes a read of a variable nobody set an error
# (and not $null), and the driver's own variables start with two underscores, so no judge can read one of them by accident.
Set-StrictMode -Version 1.0
$__tokens = $null; $__errs = $null
$__ast = [System.Management.Automation.Language.Parser]::ParseFile($env:VP_SCRIPT, [ref]$__tokens, [ref]$__errs)
if ($__errs.Count -gt 0) { throw ('parse errors: ' + $__errs[0].Message) }
$__want = @($env:VP_WANT -split ',')
$__defs = $__ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $__want -contains $n.Name }, $true)
if (@($__defs).Count -ne $__want.Count) { throw 'a judging function is missing from the script' }
foreach ($__f in $__defs) { Invoke-Expression $__f.Extent.Text }
$__cases = Get-Content -LiteralPath $env:VP_CASES -Raw | ConvertFrom-Json
$__all = New-Object System.Collections.ArrayList
foreach ($__c in $__cases) {
    $__h = @{}
    foreach ($__p in $__c.args.PSObject.Properties) { $__h[$__p.Name] = $__p.Value }
    $__r = @(& $__c.fn @__h)
    [void]$__all.Add([ordered]@{ name = $__c.name; result = $__r[0] })
}
ConvertTo-Json -InputObject @($__all) -Compress -Depth 8
"""

WANT = "Get-ProbeFacts,Get-ProbeProblems,Get-ProbeVerdict,Test-ScenarioOk"


def run_cases(cases, tmp):
    """Run the script's judging functions on the cases; returns {case name: result}."""
    tmp = Path(tmp)
    cases_file = tmp / "cases.json"
    cases_file.write_text(json.dumps(cases), encoding="ascii")
    driver = tmp / "driver.ps1"
    driver.write_text(DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["VP_SCRIPT"] = str(SCRIPT)
    env["VP_WANT"] = WANT
    env["VP_CASES"] = str(cases_file)
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(driver)], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return {item["name"]: item["result"] for item in json.loads(proc.stdout)}


VENV = "C:\\w\\.venv\\Scripts\\python.exe"
CREATE = "CALL|C:\\w\\python.exe|-m|venv|.\\.venv"
PROBE = "CALL|%s|-c|import sys" % VENV
READY = "LOG: [INFO] venv fallback ready: %s" % VENV
SELECTED = "LOG: [BOOT] REQ-009: Selected Python provider: Local venv (fallback)."
WARN = "LOG: [WARN] venv fallback: interpreter created but failed canary probe (import sys)."
MISSING = "LOG: [WARN] venv fallback: interpreter missing after creation."
HEALTHY = [CREATE, PROBE, READY, SELECTED, "RC=0", "HPPY=" + VENV, "HPENV=venv"]
DECLINED = [CREATE, PROBE, WARN, "RC=1", "HPPY=", "HPENV="]
NOFILE = [CREATE, MISSING, "RC=1", "HPPY=C:\\w\\.venv\\Scripts\\python.exe", "HPENV="]


def _case(name, kind, lines):
    return {"name": name, "fn": "Get-ProbeVerdict", "args": {"Kind": kind, "Lines": lines}}


def _replace(lines, old, new):
    assert old in lines, old
    return [new if l == old else l for l in lines]


def _drop(lines, old):
    assert old in lines, old
    return [l for l in lines if l != old]


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgingRunsInPwsh(unittest.TestCase):
    """The three kinds of scenario, each with a good run (no problem) and a run for every rule that has to be able to fail."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="vp_judge_")
        probe_late = [CREATE, "CALL|C:\\w\\python.exe|-c|import sys", PROBE, READY, SELECTED, "RC=0", "HPPY=" + VENV, "HPENV=venv"]
        cases = [
            _case("healthy_ok", "healthy", HEALTHY),
            _case("healthy_two_probes", "healthy", [CREATE, PROBE, PROBE, READY, SELECTED, "RC=0", "HPPY=" + VENV, "HPENV=venv"]),
            _case("healthy_no_probe", "healthy", _drop(HEALTHY, PROBE)),
            _case("healthy_probe_before_create", "healthy", [PROBE, CREATE, READY, SELECTED, "RC=0", "HPPY=" + VENV, "HPENV=venv"]),
            _case("healthy_ready_before_probe", "healthy", [CREATE, READY, PROBE, SELECTED, "RC=0", "HPPY=" + VENV, "HPENV=venv"]),
            _case("healthy_selected_before_probe", "healthy", [CREATE, SELECTED, PROBE, READY, "RC=0", "HPPY=" + VENV, "HPENV=venv"]),
            _case("healthy_no_ready", "healthy", _drop(HEALTHY, READY)),
            _case("healthy_not_selected", "healthy", _drop(HEALTHY, SELECTED)),
            _case("healthy_warned", "healthy", HEALTHY[:2] + [WARN] + HEALTHY[2:]),
            _case("healthy_rc1", "healthy", _replace(HEALTHY, "RC=0", "RC=1")),
            _case("healthy_hppy_empty", "healthy", _replace(HEALTHY, "HPPY=" + VENV, "HPPY=")),
            _case("healthy_env_unset", "healthy", _replace(HEALTHY, "HPENV=venv", "HPENV=")),
            _case("healthy_extra_venv_run", "healthy", [CREATE, "CALL|%s|-V|" % VENV, PROBE, READY, SELECTED, "RC=0", "HPPY=" + VENV, "HPENV=venv"]),
            _case("healthy_created_twice", "healthy", [CREATE, CREATE, PROBE, READY, SELECTED, "RC=0", "HPPY=" + VENV, "HPENV=venv"]),
            _case("healthy_getpip_reached", "healthy", [CREATE, "LOG: download_get_pip was reached", PROBE, READY, SELECTED, "RC=0", "HPPY=" + VENV, "HPENV=venv"]),
            _case("healthy_late_probe_text", "healthy", probe_late),
            _case("declined_ok", "declined", DECLINED),
            _case("declined_no_warning", "declined", _drop(DECLINED, WARN)),
            _case("declined_warning_before_probe", "declined", [CREATE, WARN, PROBE, "RC=1", "HPPY=", "HPENV="]),
            _case("declined_no_probe", "declined", _drop(DECLINED, PROBE)),
            _case("declined_selected_anyway", "declined", [CREATE, PROBE, READY, SELECTED, "RC=0", "HPPY=" + VENV, "HPENV=venv"]),
            _case("declined_ready_line", "declined", DECLINED[:2] + [WARN, READY] + DECLINED[3:]),
            _case("declined_selected_line", "declined", DECLINED[:2] + [WARN, SELECTED] + DECLINED[3:]),
            _case("declined_rc0", "declined", _replace(DECLINED, "RC=1", "RC=0")),
            _case("declined_hppy_leaks", "declined", _replace(DECLINED, "HPPY=", "HPPY=" + VENV)),
            _case("declined_env_set", "declined", _replace(DECLINED, "HPENV=", "HPENV=venv")),
            _case("nofile_ok", "nofile", NOFILE),
            _case("nofile_probed", "nofile", [CREATE, PROBE, MISSING, "RC=1", "HPPY=", "HPENV="]),
            _case("nofile_no_warning", "nofile", _drop(NOFILE, MISSING)),
            _case("nofile_selected", "nofile", [CREATE, MISSING, READY, SELECTED, "RC=1", "HPPY=", "HPENV="]),
            _case("nofile_rc0", "nofile", _replace(NOFILE, "RC=1", "RC=0")),
            _case("nofile_env_set", "nofile", _replace(NOFILE, "HPENV=", "HPENV=venv")),
            _case("unknown_kind", "other", HEALTHY),
            _case("empty_ledger", "healthy", []),
        ]
        cls.res = run_cases(cases, cls.tmp)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def problems(self, name):
        return self.res[name]["problems"]

    def assertHas(self, name, text):
        self.assertTrue(any(text in p for p in self.problems(name)), "%s: no problem mentions %r in %r" % (name, text, self.problems(name)))

    def test_good_runs_have_no_problem(self):
        for name in ("healthy_ok", "declined_ok", "nofile_ok"):
            self.assertEqual(self.problems(name), [], name)

    def test_facts_of_a_healthy_run(self):
        f = self.res["healthy_ok"]["facts"]
        self.assertEqual((f["creates"], f["probeCalls"], f["venvCalls"], f["rc"], f["hpEnvMode"]), (1, 1, 1, "0", "venv"))
        self.assertTrue(f["hpPyEndsInVenv"])
        self.assertLess(f["createAt"], f["probeAt"])
        self.assertLess(f["probeAt"], f["readyAt"])

    def test_healthy_rules_can_fail(self):
        self.assertHas("healthy_two_probes", "expected exactly once")
        self.assertHas("healthy_no_probe", "expected exactly once")
        self.assertHas("healthy_probe_before_create", "before the creation")
        self.assertHas("healthy_ready_before_probe", "ready before the probe")
        self.assertHas("healthy_selected_before_probe", "selected before the probe")
        self.assertHas("healthy_no_ready", "no \"venv fallback ready\" line")
        self.assertHas("healthy_not_selected", "not reported as the selected provider")
        self.assertHas("healthy_warned", "reported as having failed the probe")
        self.assertHas("healthy_rc1", "expected 0")
        self.assertHas("healthy_hppy_empty", "HP_PY does not name")
        self.assertHas("healthy_env_unset", "HP_ENV_MODE")
        self.assertHas("healthy_extra_venv_run", "started 2 times")
        self.assertHas("healthy_created_twice", "created 2 times")
        self.assertHas("healthy_getpip_reached", "get-pip.py retry path")

    def test_declined_rules_can_fail(self):
        self.assertHas("declined_no_warning", "no warning said")
        self.assertHas("declined_warning_before_probe", "before the probe ran")
        self.assertHas("declined_no_probe", "expected exactly once")
        for name in ("declined_selected_anyway", "declined_ready_line"):
            self.assertHas(name, "ready")
        self.assertHas("declined_selected_anyway", "selected provider")
        self.assertHas("declined_selected_line", "selected provider")
        self.assertHas("declined_selected_anyway", "no warning said")
        self.assertHas("declined_rc0", "expected 1")
        self.assertHas("declined_hppy_leaks", "HP_PY still names")
        self.assertHas("declined_env_set", "HP_ENV_MODE")

    def test_nofile_rules_can_fail(self):
        self.assertHas("nofile_probed", "probed 1 times")
        self.assertHas("nofile_no_warning", "no warning said")
        self.assertHas("nofile_selected", "selected provider")
        self.assertHas("nofile_rc0", "expected 1")
        self.assertHas("nofile_env_set", "HP_ENV_MODE")

    def test_the_bug_the_rows_exist_for_is_red(self):
        # What the batch did for a probe that exited with a negative code: probed once, then selected and returned 0.
        problems = self.problems("declined_selected_anyway")
        self.assertGreaterEqual(len(problems), 4, problems)

    def test_unknown_kind_and_empty_ledger_are_problems(self):
        self.assertHas("unknown_kind", "unknown scenario kind")
        self.assertHas("empty_ledger", "created 0 times")

    def test_scenario_verdict(self):
        cases = [
            {"name": "ok", "fn": "Test-ScenarioOk", "args": {"Scenario": {"timedOut": False, "driverExit": 0, "problems": []}}},
            {"name": "problem", "fn": "Test-ScenarioOk", "args": {"Scenario": {"timedOut": False, "driverExit": 0, "problems": ["x"]}}},
            {"name": "timeout", "fn": "Test-ScenarioOk", "args": {"Scenario": {"timedOut": True, "driverExit": 0, "problems": []}}},
            {"name": "exit", "fn": "Test-ScenarioOk", "args": {"Scenario": {"timedOut": False, "driverExit": 1, "problems": []}}},
        ]
        with tempfile.TemporaryDirectory() as t:
            res = run_cases(cases, t)
        self.assertEqual((res["ok"], res["problem"], res["timeout"], res["exit"]), (True, False, False, False))


def _lines():
    return _bat_lines()


class BatchSide(unittest.TestCase):
    def test_cut_lines_exist_exactly_once(self):
        self.assertEqual(label_problems(_lines()), [])

    def test_the_block_reaches_only_what_the_driver_defines(self):
        block = cut_block(_lines(), *BLOCK)
        self.assertIsNotNone(block)
        self.assertEqual(block_problems(block), [])

    def test_the_block_keeps_the_shape_the_rows_read(self):
        self.assertEqual(shape_problems(cut_block(_lines(), *BLOCK)), [])

    def test_the_script_looks_for_text_the_batch_writes(self):
        self.assertEqual(log_problems("\n".join(_lines())), [])


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

    def test_the_shall_with_a_row_is_no_longer_listed_as_untraced(self):
        text = SHALL_TRACE.read_text(encoding="utf-8")
        self.assertNotIn('"REQ-023.1":', text, "REQ-023.1 has a row now (self.venvprobe.command); delete its UNTRACED_SHALLS entry")

    def test_step_is_a_gating_real_lane_step(self):
        self.assertEqual(step_problems(WORKFLOW.read_text(encoding="utf-8")), [])


class SyntheticRulesCanFail(unittest.TestCase):
    def test_a_moved_label_is_reported(self):
        lines = [l for l in _lines() if l.strip() != ":try_system_fallback"]
        self.assertTrue(label_problems(lines))

    def test_a_duplicated_cut_line_is_reported(self):
        self.assertTrue(label_problems(_lines() + [":try_venv_fallback"]))

    def test_a_new_variable_in_the_block_is_reported(self):
        block = cut_block(_lines(), *BLOCK) + ["echo %HP_BRAND_NEW%"]
        self.assertTrue(any("HP_BRAND_NEW" in p for p in block_problems(block)))

    def test_a_new_goto_target_or_label_is_reported(self):
        block = cut_block(_lines(), *BLOCK)
        self.assertTrue(any(":elsewhere" in p for p in block_problems(block + ["goto :elsewhere"])))
        self.assertTrue(block_problems(block + [":a_new_label"]))

    def test_a_moved_probe_is_reported(self):
        block = cut_block(_lines(), *BLOCK)
        self.assertTrue(shape_problems([l.replace(PROBE_LINE, '"%HP_PY%" -c "pass" >nul 2>&1') for l in block]))
        self.assertTrue(shape_problems(block + [PROBE_LINE]))
        self.assertTrue(shape_problems([("  " + l) if l == PROBE_LINE else l for l in block]))

    def test_a_dropped_hp_py_clear_is_reported(self):
        block = cut_block(_lines(), *BLOCK)
        fail = next(i for i, l in enumerate(block) if l.strip() == ":venv_canary_fail")
        mutated = [l for i, l in enumerate(block) if not (i > fail and l.strip() == 'set "HP_PY="')]
        self.assertNotEqual(block, mutated)
        self.assertTrue(any("clear HP_PY" in p for p in shape_problems(mutated)))

    def test_a_probe_before_the_file_check_is_reported(self):
        block = cut_block(_lines(), *BLOCK)
        mutated = [l.replace('if not exist "%HP_PY%" (', 'if not exist "%HP_PYX%" (') for l in block]
        self.assertTrue(any("file exists" in p for p in shape_problems(mutated)))

    def test_a_reworded_log_line_is_reported(self):
        text = "\n".join(_lines()).replace("failed canary probe (import sys).", "failed the probe.")
        self.assertTrue(any("canary probe" in p for p in log_problems(text)))

    def test_script_without_a_row_or_the_exit_is_reported(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(script_problems(text.replace("self.venvprobe.crash", "self.venvprobe.other")))
        self.assertTrue(script_problems(text.replace("exit 0", "")))
        self.assertTrue(script_problems(text.replace("req = 'REQ-023.1'", "req = 'REQ-023.9'")))
        self.assertTrue(script_problems(text.replace("'-1073741515', ", "")))

    def test_script_cutting_another_block_is_reported(self):
        text = SCRIPT.read_text(encoding="utf-8").replace("-EndLine ':try_system_fallback'", "-EndLine ':elsewhere'")
        self.assertTrue(script_problems(text))

    def test_step_with_continue_on_error_or_another_lane_is_reported(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        marker = '- name: "%s"\n' % STEP_NAME
        self.assertIn(marker, text)
        self.assertTrue(step_problems(text.replace(marker, marker + "        continue-on-error: true\n", 1)))
        self.assertTrue(step_problems(text.replace("tests/~selftest_venvprobe/**", "tests/~selftest_other/**")))
        self.assertTrue(step_problems(text.replace(STEP_NAME, "Renamed step")))
        cond = "matrix.mode == 'real' && !cancelled() }}\n        shell: pwsh\n        run: |\n          & tests\\selfapps_venv_probe.ps1"
        self.assertIn(cond, text)
        self.assertTrue(step_problems(text.replace(cond, "(matrix.mode == 'real' || matrix.mode == 'justme-test') && !cancelled() }}\n        shell: pwsh\n        run: |\n          & tests\\selfapps_venv_probe.ps1", 1)))


if __name__ == "__main__":
    unittest.main()
