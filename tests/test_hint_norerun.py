"""Item 96: the failure hints are read from text the failed run already printed; the program is not started again to
collect them (README REQ-018 and REQ-007).

After a failed EXE verification run, :exe_smokerun_hints used to launch dist\\<env>.exe once more (through the emitted
~exe_hint_rerun.ps1, killed after ten seconds) only to capture its error text. That start was beyond the single automatic
run of REQ-018.1, nobody had consented to it (REQ-018.2), and no line announced it, unlike the verification run
(:warn_user_code_launch main) and the --hidden-import repair loop (:warn_user_code_launch hidden_import).

What really happens in a bootstrap is checked by tests/selfapps_hint_norerun.ps1 (rows self.launch.count.failed_run,
self.hint.datafile.capture, self.launch.count.repaired_run and self.hint.final_failure; real and conda-full lanes). These
rules read run_setup.bat, that script and batch-check.yml as text, and run the script's own counting functions through a
real pwsh, so a reworded log line, a counting rule that stops counting or a step that stops gating fails here with a
sentence, before a Windows run is needed. Synthetic cases prove each rule can fail.

The fix (same item): the hints read text a run already printed. After a repair rebuild that still failed, the repair loop's
last output is handed to the hints (:hidden_import_recover_done moves dist\\~exe_out.txt to the app root); otherwise the hints
build ~exe_out.txt from the verification run's own capture (~run.out.txt and ~run.err.txt). The batch side of that is
pinned below by batch_problems, which reads run_setup.bat as text.
"""
import json
import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_hint_norerun.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

# (row id, the req tag the call site must carry)
ROWS = (
    ("self.launch.count.failed_run", "REQ-018"),
    ("self.hint.datafile.capture", "REQ-007"),
    ("self.launch.count.repaired_run", "REQ-018"),
    ("self.hint.final_failure", "REQ-007"),
)

# The setup-log texts the script counts, and the form they take in the batch (a `call :log` line each).
LOG_TEXTS = (
    "Verifying the built standalone EXE",
    "[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=",
    "[HINT][DATA_FILE] Missing data file detected:",
    "[HINT][HIDDEN_IMPORT]",
    "EXE smokerun: exited",
)

UPLOADS = (
    "tests/~selftest_hint_*/~hint_*.log",
    "tests/~selftest_hint_*/~hint_ledger.jsonl",
    "tests/~selftest_hint_*/~setup.log",
    "tests/~selftest_hint_*/~run.out.txt",
    "tests/~selftest_hint_*/~run.err.txt",
    "tests/~selftest_hint_*/~bootstrap.status.json",
)

STEP_IF = ("if: ${{ !cancelled() && (matrix.mode == 'real' || (matrix.mode == 'conda-full' "
           "&& steps.conda_avail.outputs.available == 'true')) }}")


def lines_of(text):
    return text.replace("\r\n", "\n").split("\n")


def is_comment(line):
    return re.match(r"(?i)\s*(rem\b|::)", line) is not None


def app_code(text, scenario):
    """The Python source of one scenario's program, from its here-string in the script."""
    m = re.search(r"\$appCode\['%s'\] = @'\r?\n(.*?)\r?\n'@" % re.escape(scenario), text, re.S)
    return m.group(1) if m else None


def log_problems(batch_text):
    """Every log text the script counts is still written by a live `call :log` line of the batch."""
    found = []
    logs = [ln for ln in lines_of(batch_text) if "call :log" in ln and not is_comment(ln)]
    for needle in LOG_TEXTS:
        if not any(needle in ln for ln in logs):
            found.append("no live 'call :log' line of run_setup.bat holds %r, so the script's count of it is always 0" % needle)
    if not any("EXE smokerun: exited" in ln and "(non-zero)" in ln for ln in logs):
        found.append("the 'EXE smokerun: exited <n> (non-zero)' line the script looks for is gone")
    return found


def script_problems(text):
    found = []
    lines = lines_of(text)
    live = [ln.strip() for ln in lines if ln.strip() and not ln.strip().startswith("#")]
    for row_id, req in ROWS:
        pattern = r"Write-NdjsonRow \(\[ordered\]@\{\s*id = '%s'; req = '%s'" % (re.escape(row_id), re.escape(req))
        if not re.search(pattern, text):
            found.append("%s is not a literal id with req '%s' at a Write-NdjsonRow call" % (row_id, req))
    # both programs write the ledger line FIRST, from an absolute path, so a start that fails at once is still counted
    for scenario in ("plain", "repaired"):
        code = app_code(text, scenario)
        if code is None:
            found.append("the %s program is not a here-string of the script" % scenario)
            continue
        if 'os.environ["HINT_LEDGER"]' not in code:
            found.append("%s: the program does not read the ledger path from HINT_LEDGER" % scenario)
        elif code.index("HINT_LEDGER") > code.index("hint_missing_data.json"):
            found.append("%s: the ledger line is written after the program can already fail" % scenario)
        if "sys.frozen" not in code and '"frozen"' not in code:
            found.append("%s: the ledger line does not say whether the EXE or the interpreter started the program" % scenario)
    if "HINT_LEDGER = (Join-Path $dir '~hint_ledger.jsonl')" not in text:
        found.append("the ledger path handed to the program is not an absolute path under the scenario folder")
    if "colorama" not in (app_code(text, "repaired") or ""):
        found.append("the repaired program no longer imports colorama by a runtime string")
    if "$Requirements 'colorama'" not in text and "-Requirements 'colorama'" not in text:
        found.append("the repaired scenario does not install colorama through requirements.txt")
    # the counting rule itself
    if not re.search(r"^\s*\$allowed = \$Announced \+ \$Rebuilds\s*$", text, re.M):
        found.append("the accounting is no longer starts <= announced + rebuilds")
    if "'Verifying the built standalone EXE'" not in text:
        found.append("the script no longer counts the announcements of the verification run and the repair loop")
    if "Adding --hidden-import=" not in text:
        found.append("the script no longer counts the rebuilds of the repair loop")
    # the scenario folder is fresh, stdin is closed, a hang is a red row
    if "call run_setup.bat > $consoleName 2>&1 < nul" not in text:
        found.append("the wrapper line that starts the bootstrapper does not close standard input (< nul)")
    if "*>" in text:
        found.append("a *> redirect appears; cmd.exe has no such operator, use > file 2>&1 inside a cmd string")
    if "taskkill.exe /F /T" not in text:
        found.append("a run past the time limit is not stopped with taskkill /F /T")
    if "HP_SKIP_PIPREQS" not in text:
        found.append("the scenarios no longer skip the pipreqs scan")
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0 (last line: %r)" % (live[-1] if live else ""))
    if "if (-not $allPass) { exit 1 }" not in live:
        found.append("the script never exits 1 when a row is red")
    return found


def between(flat, start, end):
    """The text from the line `start` up to the next occurrence of `end`; None when either is missing."""
    a = flat.find(start)
    if a < 0:
        return None
    b = flat.find(end, a + len(start))
    return None if b < 0 else flat[a:b]


def batch_problems(batch_text):
    """The batch side of the fix: the hints read printed text and never start the program."""
    found = []
    flat = batch_text.replace("\r\n", "\n")
    live = [ln for ln in flat.split("\n") if not is_comment(ln)]
    for needle in ("HP_EXE_HINT_RERUN", "exe_hint_rerun", "HP_HINT_RERUN"):
        if any(needle in ln for ln in live):
            found.append("run_setup.bat still uses %s, the helper that started the EXE again to collect hints" % needle)
    calls = [ln for ln in live if "call :exe_smokerun_hints" in ln]
    if len(calls) != 1 or not calls[0].lstrip().startswith('if not "%HP_EXE_EXIT%"=="-1" call :exe_smokerun_hints'):
        found.append("the hints must be called once, and only for an exit code other than -1: %r" % calls)

    # :exe_smokerun_hints
    body = between(flat, "\n:exe_smokerun_hints\n", "\nexit /b 0\n")
    if body is None:
        found.append(":exe_smokerun_hints is missing or no longer ends with exit /b 0 at the start of a line")
    else:
        code = [ln for ln in body.split("\n") if not is_comment(ln)]
        for ln in code:
            if re.search(r"Process\]::Start|Start-Process|ProcessStartInfo|emit_from_base64|\bpushd\b|\bstart\b\s+\"", ln):
                found.append(":exe_smokerun_hints starts or prepares a program: %s" % ln.strip()[:80])
            if "%ENVNAME%.exe" in ln and not ln.lstrip().startswith("if not exist"):
                found.append(":exe_smokerun_hints names the EXE other than in its existence check: %s" % ln.strip()[:80])
        text = "\n" + "\n".join(code)
        want = ('if exist "~exe_out.txt" goto :hint_source_ready',
                'if exist "~run.out.txt" type "~run.out.txt" >> "~exe_out.txt"',
                'if exist "~run.err.txt" type "~run.err.txt" >> "~exe_out.txt"',
                "\n:hint_source_ready",
                'set "HP_HINT_FILE=~exe_out.txt"')
        positions = [text.find(w) for w in want]
        for w, pos in zip(want, positions):
            if pos < 0:
                found.append(":exe_smokerun_hints lost the line %s" % w.strip())
        if all(pos >= 0 for pos in positions) and positions != sorted(positions):
            found.append(":exe_smokerun_hints reads its sources in the wrong order (hand-over, then the two captures, then the label)")

    # :run_exe_smokerun clears an older ~exe_out.txt before it launches
    pre = between(flat, "\n:run_exe_smokerun\n", 'call :emit_from_base64 "~exe_smokerun.ps1" HP_EXE_SMOKERUN')
    if pre is None:
        found.append(":run_exe_smokerun or its helper emit line is missing")
    elif not re.search(r'^if exist "~exe_out\.txt" del "~exe_out\.txt"', pre, re.M):
        found.append(":run_exe_smokerun does not delete an older ~exe_out.txt before the launch, so a hand-over of an earlier tier could be read")

    # :hidden_import_recover_done hands the loop's last output over only after a rebuild that still failed
    done = between(flat, "\n:hidden_import_recover_done\n", 'set "HP_HIDDEN_ITER="')
    if done is None:
        found.append(":hidden_import_recover_done is missing or no longer ends in set HP_HIDDEN_ITER=")
    else:
        code = [ln.strip() for ln in done.split("\n") if not is_comment(ln)]
        text = "\n".join(code)
        clear = 'if exist "~exe_out.txt" del "~exe_out.txt" >nul 2>&1'
        keep = ('if %HP_HIDDEN_ITER% GEQ 1 if not "%HP_EXE_EXIT%"=="0" if not "%HP_EXE_EXIT%"=="-1" set "HP_HID_KEEP_OUT=1"')
        move = 'if defined HP_HID_KEEP_OUT if exist "dist\\~exe_out.txt" move /y "dist\\~exe_out.txt" "~exe_out.txt" >nul 2>&1'
        drop = 'if exist "dist\\~exe_out.txt" del "dist\\~exe_out.txt" >nul 2>&1'
        for what, line in (("clear an older hand-over", clear), ("decide the hand-over (rebuilt, and still failing)", keep),
                           ("move the loop output to the app root", move), ("drop the loop output in dist", drop)):
            if line not in text:
                found.append(":hidden_import_recover_done does not %s: %s" % (what, line))
        if clear in text and keep in text and move in text and drop in text:
            if not text.index(clear) < text.index(keep) < text.index(move) < text.index(drop):
                found.append(":hidden_import_recover_done runs its hand-over steps in the wrong order (clear, decide, move, drop)")
    return found


def step_block(text):
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if "selfapps_hint_norerun.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_hint_norerun.ps1"]
    found = []
    if STEP_IF not in block:
        found.append("the step is not limited to the real and conda-full lanes with !cancelled()")
    if "shell: pwsh" not in block:
        found.append("the step does not use shell: pwsh")
    if "continue-on-error" in block:
        found.append("the step has continue-on-error, so it cannot hold a pull request")
    for pattern in UPLOADS:
        if pattern not in text:
            found.append("the artifact upload does not list %s" % pattern)
    return found


# --- the script's own counting functions, run through a real pwsh ---

DRIVER = r"""
$ErrorActionPreference = 'Stop'
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:HN_SCRIPT, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) { throw ('parse errors: ' + $errs[0].Message) }
$want = 'Get-Accounting', 'Get-LogCounts', 'Get-StartProblems', 'Get-HintProblems', 'Get-Excerpt', 'Read-Ledger'
$defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)
if (@($defs).Count -ne $want.Count) { throw 'a counting function is missing from the script' }
foreach ($f in $defs) { Invoke-Expression $f.Extent.Text }
$cases = Get-Content -LiteralPath $env:HN_CASES -Raw | ConvertFrom-Json
$all = New-Object System.Collections.ArrayList
foreach ($c in $cases) {
    $h = @{}
    foreach ($p in $c.args.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $r = & $c.fn @h
    if ($r -is [System.Collections.IDictionary]) { $res = $r } else { $res = @($r) }
    [void]$all.Add([ordered]@{ name = $c.name; result = $res })
}
ConvertTo-Json -InputObject @($all) -Compress -Depth 8
"""


def run_cases(cases, tmp):
    """Run the counting functions of the script on the cases; returns {case name: result}."""
    tmp = Path(tmp)
    cases_file = tmp / "cases.json"
    cases_file.write_text(json.dumps(cases), encoding="ascii")
    driver = tmp / "driver.ps1"
    driver.write_text(DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["HN_SCRIPT"] = str(SCRIPT)
    env["HN_CASES"] = str(cases_file)
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(driver)], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return {item["name"]: item["result"] for item in json.loads(proc.stdout)}


FINISHED = {"Finished": True}
GOOD_COUNTS = {"announced": 2, "rebuilds": 0, "failedRun": True, "repairColorama": False, "dataFileHint": True, "importHint": False}
REPAIRED_COUNTS = {"announced": 2, "rebuilds": 1, "failedRun": True, "repairColorama": True, "dataFileHint": True, "importHint": False}


def acc(starts, announced, rebuilds):
    allowed = announced + rebuilds
    return {"starts": starts, "announced": announced, "rebuilds": rebuilds, "allowed": allowed,
            "unannounced": max(0, starts - allowed)}


SETUP_LOG = "\n".join((
    "2026-10-31 10:00:00 [WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent",
    "2026-10-31 10:00:01 [WARN] EXE smokerun: exited 1 (non-zero)",
    "2026-10-31 10:00:02 [WARN] Verifying the built standalone EXE (PyInstaller) now: it is force-stopped after about 30 seconds",
    "2026-10-31 10:00:03 [REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama --collect-submodules=colorama; rebuilding EXE (iter 1/3).",
    "2026-10-31 10:00:04 [REPAIR][HIDDEN_IMPORT] PyInstaller rebuild failed; stopping recovery.",
    "2026-10-31 10:00:05 [HINT][DATA_FILE] Missing data file detected: hint_missing_data.json",
    "2026-10-31 10:00:06 [HINT][HIDDEN_IMPORT] Hidden import likely missing: other",
))

CASES = [
    # the accounting: one start more than announced + rebuilds is a silent start
    {"name": "acc_silent_start", "fn": "Get-Accounting", "args": {"Starts": 3, "Announced": 2, "Rebuilds": 0}},
    {"name": "acc_all_announced", "fn": "Get-Accounting", "args": {"Starts": 2, "Announced": 2, "Rebuilds": 0}},
    {"name": "acc_repaired_silent", "fn": "Get-Accounting", "args": {"Starts": 4, "Announced": 2, "Rebuilds": 1}},
    {"name": "acc_repaired_ok", "fn": "Get-Accounting", "args": {"Starts": 3, "Announced": 2, "Rebuilds": 1}},
    {"name": "acc_fewer_starts", "fn": "Get-Accounting", "args": {"Starts": 1, "Announced": 2, "Rebuilds": 0}},
    {"name": "acc_none", "fn": "Get-Accounting", "args": {"Starts": 0, "Announced": 2, "Rebuilds": 0}},
    # what the setup log is counted for
    {"name": "counts", "fn": "Get-LogCounts", "args": {"SetupText": SETUP_LOG}},
    {"name": "counts_empty", "fn": "Get-LogCounts", "args": {"SetupText": ""}},
    # start rows: each rule
    {"name": "start_ok_plain", "fn": "Get-StartProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": GOOD_COUNTS, "Accounting": acc(2, 2, 0)}},
    {"name": "start_ok_repaired", "fn": "Get-StartProblems",
     "args": {"Scenario": "repaired", "Run": FINISHED, "Counts": REPAIRED_COUNTS, "Accounting": acc(3, 2, 1)}},
    {"name": "start_unfinished", "fn": "Get-StartProblems",
     "args": {"Scenario": "plain", "Run": {"Finished": False}, "Counts": GOOD_COUNTS, "Accounting": acc(0, 0, 0)}},
    {"name": "start_no_failure", "fn": "Get-StartProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": dict(GOOD_COUNTS, failedRun=False), "Accounting": acc(2, 2, 0)}},
    {"name": "start_empty_ledger", "fn": "Get-StartProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": GOOD_COUNTS, "Accounting": acc(0, 2, 0)}},
    {"name": "start_no_announcement", "fn": "Get-StartProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": dict(GOOD_COUNTS, announced=0), "Accounting": acc(1, 0, 0)}},
    {"name": "start_plain_rebuilt", "fn": "Get-StartProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": dict(GOOD_COUNTS, rebuilds=1), "Accounting": acc(3, 2, 1)}},
    {"name": "start_repair_missing", "fn": "Get-StartProblems",
     "args": {"Scenario": "repaired", "Run": FINISHED, "Counts": dict(REPAIRED_COUNTS, repairColorama=False), "Accounting": acc(3, 2, 1)}},
    {"name": "start_silent_plain", "fn": "Get-StartProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": GOOD_COUNTS, "Accounting": acc(3, 2, 0)}},
    {"name": "start_silent_repaired", "fn": "Get-StartProblems",
     "args": {"Scenario": "repaired", "Run": FINISHED, "Counts": REPAIRED_COUNTS, "Accounting": acc(4, 2, 1)}},
    # hint rows: each rule
    {"name": "hint_ok_plain", "fn": "Get-HintProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": GOOD_COUNTS, "RequireNoImportHint": False}},
    {"name": "hint_ok_repaired", "fn": "Get-HintProblems",
     "args": {"Scenario": "repaired", "Run": FINISHED, "Counts": REPAIRED_COUNTS, "RequireNoImportHint": True}},
    {"name": "hint_unfinished", "fn": "Get-HintProblems",
     "args": {"Scenario": "plain", "Run": {"Finished": False}, "Counts": GOOD_COUNTS, "RequireNoImportHint": False}},
    {"name": "hint_no_failure", "fn": "Get-HintProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": dict(GOOD_COUNTS, failedRun=False), "RequireNoImportHint": False}},
    {"name": "hint_no_datafile", "fn": "Get-HintProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": dict(GOOD_COUNTS, dataFileHint=False), "RequireNoImportHint": False}},
    {"name": "hint_stale_import", "fn": "Get-HintProblems",
     "args": {"Scenario": "repaired", "Run": FINISHED, "Counts": dict(REPAIRED_COUNTS, importHint=True), "RequireNoImportHint": True}},
    {"name": "hint_import_allowed_when_not_required", "fn": "Get-HintProblems",
     "args": {"Scenario": "plain", "Run": FINISHED, "Counts": dict(GOOD_COUNTS, importHint=True), "RequireNoImportHint": False}},
    {"name": "hint_repair_missing", "fn": "Get-HintProblems",
     "args": {"Scenario": "repaired", "Run": FINISHED, "Counts": dict(REPAIRED_COUNTS, repairColorama=False), "RequireNoImportHint": True}},
]


class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_script_has_its_rows_programs_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_log_lines_the_script_counts_are_still_written(self):
        self.assertEqual(log_problems(self.batch), [])

    def test_the_step_gates_both_lanes_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_hints_read_printed_text_and_never_start_the_program(self):
        self.assertEqual(batch_problems(self.batch), [])

    def test_the_hint_helper_and_its_tests_are_gone(self):
        for gone in ("tools/exe_hint_rerun.ps1", "tests/test_exe_hint_rerun.py"):
            self.assertFalse((REPO / gone).exists(), gone + " came back")

    def test_the_rows_are_registered(self):
        registry = (REPO / "docs" / "agent-ndjson.md").read_text(encoding="utf-8")
        for row_id, _req in ROWS:
            self.assertIn(row_id, registry)

    def test_the_script_is_ascii(self):
        self.script.encode("ascii")


@unittest.skipUnless(PWSH, "pwsh not available")
class CountingFunctions(unittest.TestCase):
    """The script's pure functions, run in a real pwsh on synthetic runs: a red row must be able to appear."""

    @classmethod
    def setUpClass(cls):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            cls.r = run_cases(CASES, tmp)

    def test_a_start_beyond_the_announced_ones_is_counted_as_unannounced(self):
        self.assertEqual(self.r["acc_silent_start"]["unannounced"], 1)
        self.assertEqual(self.r["acc_silent_start"]["allowed"], 2)
        self.assertEqual(self.r["acc_repaired_silent"]["unannounced"], 1)
        self.assertEqual(self.r["acc_repaired_silent"]["allowed"], 3)

    def test_announced_starts_and_the_run_after_each_rebuild_are_allowed(self):
        self.assertEqual(self.r["acc_all_announced"]["unannounced"], 0)
        self.assertEqual(self.r["acc_repaired_ok"]["unannounced"], 0)

    def test_fewer_starts_than_allowed_is_never_negative(self):
        self.assertEqual(self.r["acc_fewer_starts"]["unannounced"], 0)
        self.assertEqual(self.r["acc_none"]["unannounced"], 0)

    def test_the_setup_log_is_counted_for_announcements_rebuilds_and_hints(self):
        c = self.r["counts"]
        self.assertEqual(c["announced"], 2)
        self.assertEqual(c["rebuilds"], 1, "only the Adding line counts as a rebuild, not the failed-rebuild line")
        self.assertTrue(c["failedRun"])
        self.assertTrue(c["repairColorama"])
        self.assertTrue(c["dataFileHint"])
        self.assertTrue(c["importHint"])

    def test_an_empty_setup_log_counts_nothing(self):
        c = self.r["counts_empty"]
        self.assertEqual((c["announced"], c["rebuilds"]), (0, 0))
        self.assertFalse(any((c["failedRun"], c["repairColorama"], c["dataFileHint"], c["importHint"])))

    def test_runs_that_account_for_every_start_have_no_start_problems(self):
        self.assertEqual(self.r["start_ok_plain"], [])
        self.assertEqual(self.r["start_ok_repaired"], [])

    def test_a_silent_start_is_a_start_problem(self):
        self.assertTrue(any("nobody announced" in p and "3 time" in p for p in self.r["start_silent_plain"]), self.r["start_silent_plain"])
        self.assertTrue(any("nobody announced" in p and "4 time" in p for p in self.r["start_silent_repaired"]), self.r["start_silent_repaired"])

    def test_each_precondition_is_a_start_problem_when_missing(self):
        self.assertTrue(any("did not finish" in p for p in self.r["start_unfinished"]))
        self.assertTrue(any("did not fail" in p for p in self.r["start_no_failure"]))
        self.assertTrue(any("ledger is empty" in p for p in self.r["start_empty_ledger"]))
        self.assertTrue(any("no announcement" in p for p in self.r["start_no_announcement"]))
        self.assertTrue(any("expected none" in p for p in self.r["start_plain_rebuilt"]))
        self.assertTrue(any("never added --hidden-import=colorama" in p for p in self.r["start_repair_missing"]))

    def test_a_hint_row_passes_only_with_the_hint_it_expects(self):
        self.assertEqual(self.r["hint_ok_plain"], [])
        self.assertEqual(self.r["hint_ok_repaired"], [])
        self.assertTrue(any("data-file hint" in p for p in self.r["hint_no_datafile"]))
        self.assertTrue(any("did not fail" in p for p in self.r["hint_no_failure"]))
        self.assertTrue(any("did not finish" in p for p in self.r["hint_unfinished"]))
        self.assertTrue(any("never added" in p for p in self.r["hint_repair_missing"]))

    def test_a_stale_import_hint_after_a_repair_is_a_hint_problem(self):
        self.assertTrue(any("hidden import is likely missing" in p for p in self.r["hint_stale_import"]), self.r["hint_stale_import"])
        self.assertEqual(self.r["hint_import_allowed_when_not_required"], [])


class EachRuleCanFail(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_a_row_id_that_is_not_literal_is_caught(self):
        text = self.script.replace("id = 'self.hint.final_failure'; req = 'REQ-007'", "id = $finalId; req = 'REQ-007'")
        self.assertTrue(any("self.hint.final_failure" in f for f in script_problems(text)))

    def test_a_row_that_stops_naming_its_requirement_is_caught(self):
        text = self.script.replace("id = 'self.launch.count.failed_run'; req = 'REQ-018'",
                                   "id = 'self.launch.count.failed_run'; req = 'N/A'")
        self.assertTrue(any("self.launch.count.failed_run" in f for f in script_problems(text)))

    def test_a_relative_ledger_path_is_caught(self):
        text = self.script.replace("HINT_LEDGER = (Join-Path $dir '~hint_ledger.jsonl')", "HINT_LEDGER = '~hint_ledger.jsonl'")
        self.assertTrue(any("absolute path" in f for f in script_problems(text)))

    def test_a_program_that_fails_before_it_writes_the_ledger_is_caught(self):
        text = self.script.replace("import json\nimport os\nimport sys\n", "import json\nimport os\nimport sys\nopen(\"hint_missing_data.json\")\n", 1)
        if text == self.script:  # CRLF checkout
            text = self.script.replace("import json\r\nimport os\r\nimport sys\r\n",
                                       "import json\r\nimport os\r\nimport sys\r\nopen(\"hint_missing_data.json\")\r\n", 1)
        self.assertNotEqual(text, self.script, "the synthetic case needs the program text to change")
        self.assertTrue(any("after the program can already fail" in f for f in script_problems(text)))

    def test_a_program_that_no_longer_reads_the_ledger_path_is_caught(self):
        text = self.script.replace('os.environ["HINT_LEDGER"]', 'os.environ["OTHER_LEDGER"]')
        self.assertTrue(any("does not read the ledger path" in f for f in script_problems(text)))

    def test_a_repaired_program_without_colorama_is_caught(self):
        text = self.script.replace("importlib.import_module('colorama')", "importlib.import_module('json')")
        self.assertTrue(any("colorama" in f for f in script_problems(text)))

    def test_a_changed_accounting_rule_is_caught(self):
        text = self.script.replace("$allowed = $Announced + $Rebuilds", "$allowed = $Announced + $Rebuilds + 1")
        self.assertTrue(any("starts <= announced + rebuilds" in f for f in script_problems(text)))

    def test_open_standard_input_is_caught(self):
        text = self.script.replace(" 2>&1 < nul", " 2>&1")
        self.assertTrue(any("standard input" in f for f in script_problems(text)))

    def test_a_star_redirect_is_caught(self):
        text = self.script + "\ncmd /c \"call run_setup.bat *> log\"\n"
        self.assertTrue(any("*>" in f for f in script_problems(text)))

    def test_a_missing_time_limit_kill_is_caught(self):
        text = self.script.replace("taskkill.exe /F /T", "taskkill.exe /F")
        self.assertTrue(any("taskkill" in f for f in script_problems(text)))

    def test_a_script_without_its_exit_codes_is_caught(self):
        no_one = self.script.replace("if (-not $allPass) { exit 1 }", "")
        self.assertTrue(any("never exits 1" in f for f in script_problems(no_one)))
        no_zero = self.script.rstrip().rsplit("exit 0", 1)[0]
        self.assertTrue(any("does not end with exit 0" in f for f in script_problems(no_zero)))

    def test_a_reworded_log_line_is_caught(self):
        text = self.batch.replace("Missing data file detected:", "Data file not found:")
        self.assertTrue(any("Missing data file detected" in f for f in log_problems(text)))
        text = self.batch.replace("(non-zero)", "(failed)")
        self.assertTrue(any("(non-zero)" in f for f in log_problems(text)))

    def test_a_log_text_that_only_a_comment_holds_is_caught(self):
        lines = [("rem " + ln if "[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=" in ln else ln) for ln in lines_of(self.batch)]
        found = log_problems("\n".join(lines))
        self.assertTrue(any("Adding --hidden-import=" in f for f in found), found)

    def test_a_step_that_is_not_both_lanes_is_caught(self):
        block = step_block(self.workflow)
        mutated = self.workflow.replace(block, block.replace("matrix.mode == 'conda-full'", "matrix.mode == 'uv'"))
        self.assertTrue(any("real and conda-full" in f for f in workflow_problems(mutated)))

    def test_a_step_that_cannot_fail_is_caught(self):
        block = step_block(self.workflow)
        mutated = self.workflow.replace(block, block.replace("shell: pwsh", "shell: pwsh\n        continue-on-error: true"))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(mutated)))

    def test_a_missing_step_is_caught(self):
        mutated = self.workflow.replace("selfapps_hint_norerun.ps1", "something_else.ps1")
        self.assertEqual(workflow_problems(mutated), ["no step runs tests\\selfapps_hint_norerun.ps1"])

    def test_a_missing_upload_pattern_is_caught(self):
        mutated = self.workflow.replace("tests/~selftest_hint_*/~hint_ledger.jsonl", "tests/~selftest_hint_*/~other.jsonl")
        self.assertTrue(any("~hint_ledger.jsonl" in f for f in workflow_problems(mutated)))

    # the batch side: each pin fails on a synthetic change
    def _batch_without(self, old, new=""):
        self.assertTrue(old in self.batch, "the synthetic case needs the batch text to hold " + old[:40])
        return self.batch.replace(old, new)

    def test_a_helper_payload_that_comes_back_is_caught(self):
        text = self.batch + '\r\nset "HP_EXE_HINT_RERUN=QUFB"\r\n'
        self.assertTrue(any("HP_EXE_HINT_RERUN" in f for f in batch_problems(text)))

    def test_a_hint_that_starts_the_program_again_is_caught(self):
        text = self._batch_without('set "HP_HINT_FILE=~exe_out.txt"',
                                   'powershell -NoProfile -Command "[System.Diagnostics.Process]::Start(\'x\')"\r\nset "HP_HINT_FILE=~exe_out.txt"')
        self.assertTrue(any("starts or prepares a program" in f for f in batch_problems(text)))

    def test_a_hint_that_names_the_exe_in_a_launch_is_caught(self):
        text = self._batch_without('set "HP_HINT_FILE=~exe_out.txt"',
                                   'call "dist\\%ENVNAME%.exe" >> "~exe_out.txt" 2>&1\r\nset "HP_HINT_FILE=~exe_out.txt"')
        self.assertTrue(any("names the EXE" in f for f in batch_problems(text)))

    def test_hints_that_no_longer_read_the_captures_are_caught(self):
        text = self._batch_without('if exist "~run.err.txt" type "~run.err.txt" >> "~exe_out.txt"')
        self.assertTrue(any("~run.err.txt" in f for f in batch_problems(text)))

    def test_hints_that_read_the_handover_last_are_caught(self):
        text = self._batch_without('if exist "~exe_out.txt" goto :hint_source_ready',
                                   'rem the hand-over check moved')
        self.assertTrue(any("hint_source_ready" in f for f in batch_problems(text)))

    def test_a_second_call_of_the_hints_is_caught(self):
        text = self.batch + '\r\nif not "%HP_EXE_EXIT%"=="-1" call :exe_smokerun_hints\r\n'
        self.assertTrue(any("called once" in f for f in batch_problems(text)))

    def test_a_smoke_run_that_keeps_an_older_handover_is_caught(self):
        old = 'rem Item 96: the failure hints read ~exe_out.txt, which the repair loop below may leave for them. Clear any older one.\nif exist "~exe_out.txt" del "~exe_out.txt" >nul 2>&1\n'
        text = self._batch_without(old)
        self.assertTrue(any("older ~exe_out.txt" in f for f in batch_problems(text)))

    def test_a_handover_after_any_rebuild_state_is_caught(self):
        text = self._batch_without('if %HP_HIDDEN_ITER% GEQ 1 if not "%HP_EXE_EXIT%"=="0"',
                                   'if %HP_HIDDEN_ITER% GEQ 0 if not "%HP_EXE_EXIT%"=="0"')
        self.assertTrue(any("decide the hand-over" in f for f in batch_problems(text)))

    def test_a_handover_that_is_never_moved_is_caught(self):
        text = self._batch_without('move /y "dist\\~exe_out.txt" "~exe_out.txt"', 'copy /y "dist\\~exe_out.txt" "~exe_out.txt"')
        self.assertTrue(any("move the loop output" in f for f in batch_problems(text)))

    def test_a_handover_that_leaves_the_old_one_in_place_is_caught(self):
        lines = self.batch.split("\r\n") if "\r\n" in self.batch else self.batch.split("\n")
        newline = "\r\n" if "\r\n" in self.batch else "\n"
        keep = 'if exist "~exe_out.txt" del "~exe_out.txt" >nul 2>&1'
        first = next(i for i, ln in enumerate(lines) if ln == "set \"HP_HID_KEEP_OUT=\"")
        self.assertEqual(lines[first - 1], keep, "the synthetic case needs the clear line right before it")
        del lines[first - 1]
        self.assertTrue(any("clear an older hand-over" in f for f in batch_problems(newline.join(lines))))

    def test_a_loop_output_left_in_dist_is_caught(self):
        text = self._batch_without('if exist "dist\\~exe_out.txt" del "dist\\~exe_out.txt" >nul 2>&1')
        self.assertTrue(any("drop the loop output" in f for f in batch_problems(text)))

    def test_a_handover_below_the_counter_reset_is_caught(self):
        # the pin reads up to the first reset of HP_HIDDEN_ITER, so a hand-over placed after it would see an empty counter
        text = self._batch_without("\n:hidden_import_recover_done\n", '\n:hidden_import_recover_done\nset "HP_HIDDEN_ITER="\n')
        self.assertTrue(any("decide the hand-over" in f for f in batch_problems(text)))


if __name__ == "__main__":
    unittest.main()
