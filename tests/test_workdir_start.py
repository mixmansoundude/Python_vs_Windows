"""Item 101 (README REQ-003.6): every run of the user's program starts with the folder that holds its entry file as the
working folder.

Item 38 moved the verification run, the cached-EXE run and the interpreter runs to the app folder. Two starts of the program
still ran from dist\\ (`pushd dist`): the verification run of the optimized build (:offer_optimized_build) and the runs of the
--hidden-import repair loop (:hidden_import_recover). A program that opens a file by a relative name saw a different set of
files in those runs, so a repair could fail, or succeed, for a reason the real run does not share.

What really happens in a bootstrap is checked by tests/selfapps_workdir.ps1 (rows self.workdir.verify, .fastpath, .interpreter,
.repair and .optbuild; conda-full lane). These rules read run_setup.bat, that script, batch-check.yml and docs/agent-ndjson.md
as text, and run the script's own judging functions through a real pwsh, so a reworded log line, a launch site that goes back to
dist\\, a judging rule that stops judging or a step that stops gating fails here with a sentence, before a Windows run is needed.
Synthetic cases prove each rule can fail.

The fix (same item): the two launch lines no longer `pushd dist`; they hand PowerShell the absolute path of the EXE through an
environment variable (the same reasoning as :try_fast_exe_probe and :run_exe_smokerun: an absolute path is unambiguous, and the
-Command text holds no path that a folder name could break), so the program starts in the folder the batch file is in, which is
the app folder.
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
SCRIPT = REPO / "tests" / "selfapps_workdir.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

# The rows carry the shall id. tests/test_req_trace.py rejects a tag the README lacks, and RealFiles checks the README still holds it.
README_TEXT = (REPO / "README.md").read_text(encoding="utf-8", errors="replace")
TAG = "REQ-003.6"
ROWS = (
    "self.workdir.verify",
    "self.workdir.fastpath",
    "self.workdir.interpreter",
    "self.workdir.repair",
    "self.workdir.optbuild",
)

# The setup-log or console texts the script's preconditions look for, and a needle that a live `call :log` line of the batch
# must hold for each, so a reworded line turns a row red with a sentence here and not with an unexplained missing precondition.
PROOFS = (
    ("post-execution checkpoint \\(exe\\): accepted", "post-execution checkpoint (%HP_CHECKPOINT_SITE%): accepted"),
    ("Fast path: reusing", "Fast path: reusing"),
    ("Repair loop: accepted", "Repair loop: accepted"),
    ("\\[REPAIR\\]\\[HIDDEN_IMPORT\\] Adding --hidden-import=colorama", "[REPAIR][HIDDEN_IMPORT] Adding --hidden-import="),
    ("PVW_BUILDER=both: building the optimized version now without asking",
     "PVW_BUILDER=both: building the optimized version now without asking"),
    ("Optimized build succeeded and verified", "Optimized build succeeded and verified"),
)

UPLOADS = (
    "tests/~selftest_workdir_*/~workdir_*.log",
    "tests/~selftest_workdir_*/~workdir_ledger.jsonl",
    "tests/~selftest_workdir_*/~setup.log",
    "tests/~selftest_workdir_*/~run.out.txt",
    "tests/~selftest_workdir_*/~run.err.txt",
    "tests/~selftest_workdir_*/~bootstrap.status.json",
)

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'conda-full' && steps.conda_avail.outputs.available == 'true' }}"

# Old comment wording of the two deferrals; the fix removes it because it would now be false.
STALE_WORDS = (
    "still runs from dist",
    "deferred follow-up rather than folded into this",
    "Re-derive whether to unify this too",
)


def lines_of(text):
    return text.replace("\r\n", "\n").split("\n")


def is_comment(line):
    return re.match(r"(?i)\s*(rem\b|::)", line) is not None


def app_code(text, kind):
    """The Python source of one program, from its here-string in the script."""
    m = re.search(r"\$appCode\['%s'\] = @'\r?\n(.*?)\r?\n'@" % re.escape(kind), text, re.S)
    return m.group(1) if m else None


def between(flat, start, end):
    """The text from the line `start` up to the next occurrence of `end`; None when either is missing."""
    a = flat.find(start)
    if a < 0:
        return None
    b = flat.find(end, a + len(start))
    return None if b < 0 else flat[a:b]


def script_problems(text):
    found = []
    live = [ln.strip() for ln in lines_of(text) if ln.strip() and not ln.strip().startswith("#")]
    for row_id in ROWS:
        pattern = r"Write-NdjsonRow \(\[ordered\]@\{\s*id = '%s'; req = '%s'" % (re.escape(row_id), re.escape(TAG))
        if not re.search(pattern, text):
            found.append("%s is not a literal id with req '%s' at a Write-NdjsonRow call" % (row_id, TAG))

    # both programs write the ledger line FIRST, from an absolute path, so a start that fails at once is still seen
    for kind in ("ledger", "repair"):
        code = app_code(text, kind)
        if code is None:
            found.append("the %s program is not a here-string of the script" % kind)
            continue
        if 'os.environ["WORKDIR_LEDGER"]' not in code:
            found.append("%s: the program does not read the ledger path from WORKDIR_LEDGER" % kind)
        for needle, why in (("os.path.samefile", "compare the working folder with the entry folder (a short 8.3 name or letter case must not fool it)"),
                            ('"frozen"', "say whether the EXE or the interpreter started the program"),
                            ('"dataFound"', "say whether the data file next to the .py file can be opened by its relative name"),
                            ("WORKDIR_EXPECT", "read the entry folder from WORKDIR_EXPECT")):
            if needle not in code:
                found.append("%s: the ledger line does not %s" % (kind, why))
    repair = app_code(text, "repair") or ""
    if 'open("workdir_data.txt"' in repair and "WORKDIR_LEDGER" in repair:
        if repair.index("WORKDIR_LEDGER") > repair.index('open("workdir_data.txt"'):
            found.append("repair: the ledger line is written after the program can already fail on the data file")
    else:
        found.append("repair: the program no longer reads workdir_data.txt after writing the ledger line")
    if "importlib.import_module('colorama')" not in repair:
        found.append("repair: the program no longer imports colorama by a runtime string")
    if "-Requirements 'colorama'" not in text:
        found.append("the repair scenario does not install colorama through requirements.txt")
    if "WORKDIR_LEDGER = (Join-Path $Dir '~workdir_ledger.jsonl')" not in text:
        found.append("the ledger path handed to the program is not an absolute path under the scenario folder")

    # what each scenario does
    wants = (
        ("HP_TEST_CHECKPOINT_ANSWER = 'Y'", "the verify scenario no longer accepts the post-execution checkpoint, so its interpreter start is never made"),
        ("HP_TEST_REPAIR_ANSWER = 'Y'", "the repair scenario no longer answers yes to the repair question, so the loop never starts the program"),
        ("PVW_BUILDER = 'both'", "the optbuild scenario no longer sets PVW_BUILDER=both, so the optimized build is never started"),
        ("HP_TEST_FORCE_PYINSTALLER_FAIL = '1'", "the interpreter scenario no longer forces PyInstaller to fail"),
        ("HP_TEST_FORCE_NUITKA_FAIL = '1'", "the interpreter scenario no longer forces Nuitka to fail"),
        ("-StubCode $stubNuitka", "the optbuild scenario no longer puts the stub nuitka.py next to the program"),
    )
    for needle, why in wants:
        if needle not in text:
            found.append(why)
    for site, minimum in (("verify", 2), ("fastpath", 1), ("interpreter", 1), ("repair", 3), ("optbuild", 2)):
        if not re.search(r"Get-WorkdirProblems -Site '%s'[^\n]*-MinStarts %d\b" % (site, minimum), text):
            found.append("%s: the row no longer requires at least %d recorded start(s)" % (site, minimum))
    for pattern, _needle in PROOFS:
        if pattern not in text:
            found.append("the script no longer looks for %r in the log, so a precondition went missing" % pattern)

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


def log_problems(batch_text):
    """Every log text the script's preconditions look for is still written by a live `call :log` line of the batch."""
    found = []
    logs = [ln for ln in lines_of(batch_text) if "call :log" in ln and not is_comment(ln)]
    for _pattern, needle in PROOFS:
        if not any(needle in ln for ln in logs):
            found.append("no live 'call :log' line of run_setup.bat holds %r, so the script's precondition on it can never be met" % needle)
    return found


def batch_problems(batch_text):
    """The batch side of the fix: no launch site of the program runs from dist."""
    found = []
    flat = batch_text.replace("\r\n", "\n")
    live = [ln for ln in flat.split("\n") if not is_comment(ln)]

    pushes = [ln for ln in live if re.match(r'(?i)\s*pushd\s+"?dist\b', ln)]
    if pushes:
        found.append("run_setup.bat still changes into dist (%d live pushd line(s)); a start of the program from there sees other files" % len(pushes))

    launches = [ln for ln in live if "Process]::Start" in ln]
    if len(launches) != 2:
        found.append("expected the 2 inline launch lines (optimized-build verification, repair loop), found %d" % len(launches))
    for ln in launches:
        m = re.search(r"\$si\.FileName=\$env:(HP_[A-Z0-9_]+)", ln)
        if not m:
            found.append("a launch line hands the EXE to PowerShell by anything but an absolute path in an environment variable: %s" % ln.strip()[:90])
            continue
        var = m.group(1)
        # the variable must be set earlier, from %CD% (the app folder) and dist
        before = "\n".join(live[:live.index(ln)])
        if not re.search(r'(?m)^set "%s=%%CD%%\\dist\\' % re.escape(var), before):
            found.append('%s is not set to "%%CD%%\\dist\\..." on a live line before the launch that reads it' % var)
        if "WorkingDirectory" in ln:
            found.append("a launch line sets a WorkingDirectory; the program must inherit the app folder")
    repair_line = next((ln for ln in launches if "~exe_out.txt" in ln), None)
    if repair_line is None:
        found.append("the repair loop's launch no longer captures the program's output in ~exe_out.txt")
    elif "Set-Content -Path 'dist\\~exe_out.txt'" not in repair_line:
        found.append("the repair loop must write the captured output to dist\\~exe_out.txt (the scan and the hand-over read that file)")

    for label, start, end in (("the optimized-build verification", "\n:offer_optimized_build\n", "\n:try_fast_exe\n"),
                              ("the repair loop", "\n:hidden_import_recover\n", "\n:warn_user_code_launch\n")):
        body = between(flat, start, end)
        if body is None:
            found.append("%s: the subroutine labels %r ... %r were not found" % (label, start.strip(), end.strip()))
            continue
        for ln in body.split("\n"):
            if is_comment(ln):
                continue
            if re.match(r"(?i)\s*(pushd|popd|cd|chdir)\b", ln):
                found.append("%s changes the working folder: %s" % (label, ln.strip()[:80]))

    for word in STALE_WORDS:
        if word in flat:
            found.append("a comment of run_setup.bat still says %r, which the fix makes false" % word)
    return found


def step_block(text):
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if "selfapps_workdir.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_workdir.ps1"]
    found = []
    if STEP_IF not in block:
        found.append("the step is not limited to the conda-full lane with !cancelled() and the conda availability check")
    if "shell: pwsh" not in block:
        found.append("the step does not use shell: pwsh")
    if "continue-on-error" in block:
        found.append("the step has continue-on-error, so it cannot hold a pull request")
    for pattern in UPLOADS:
        if pattern not in text:
            found.append("the artifact upload does not list %s" % pattern)
    return found


def registry_problems(text):
    return ["%s is not in docs/agent-ndjson.md" % row_id for row_id in ROWS if row_id not in text]


# --- the script's own judging functions, run through a real pwsh ---

DRIVER = r"""
$ErrorActionPreference = 'Stop'
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:WD_SCRIPT, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) { throw ('parse errors: ' + $errs[0].Message) }
$want = 'Get-ShortPath', 'Get-WorkdirProblems', 'Get-StartKinds', 'Get-ProofGap', 'Get-Excerpt'
$defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)
if (@($defs).Count -ne $want.Count) { throw 'a judging function is missing from the script' }
foreach ($f in $defs) { Invoke-Expression $f.Extent.Text }
$cases = Get-Content -LiteralPath $env:WD_CASES -Raw | ConvertFrom-Json
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
    """Run the judging functions of the script on the cases; returns {case name: result}."""
    tmp = Path(tmp)
    cases_file = tmp / "cases.json"
    cases_file.write_text(json.dumps(cases), encoding="ascii")
    driver = tmp / "driver.ps1"
    driver.write_text(DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["WD_SCRIPT"] = str(SCRIPT)
    env["WD_CASES"] = str(cases_file)
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(driver)], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return {item["name"]: item["result"] for item in json.loads(proc.stdout)}


def start(frozen=True, same=True, data=True, cwd="C:\\w\\tests\\~selftest_workdir_x"):
    return {"scenario": "x", "frozen": frozen, "cwd": cwd, "same": same, "dataFound": data}


GOOD = [start(), start(frozen=False)]
IN_DIST = start(same=False, data=False, cwd="C:\\w\\tests\\~selftest_workdir_repair\\dist")
LOG = "\n".join((
    "2026-11-06 10:00:00 [INFO] Chosen entry: app.py",
    "2026-11-06 10:00:01 [WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent",
    "2026-11-06 10:00:02 [INFO] REQ-018: post-execution checkpoint (exe): accepted; running a second time via the interpreter.",
    "2026-11-06 10:00:03 [INFO] Repair loop: accepted. Your program will be started again.",
    "2026-11-06 10:00:04 [REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama --collect-submodules=colorama; rebuilding EXE (iter 1/3).",
    "2026-11-06 10:00:05 [INFO] Something unrelated that must not be kept",
    "2026-11-06 10:00:06 [ERROR] caf\u00e9 failed",
))

CASES = [
    # the judge: each rule
    {"name": "ok", "fn": "Get-WorkdirProblems",
     "args": {"Site": "verify", "Finished": True, "Ledger": GOOD, "MinStarts": 2, "Proofs": []}},
    {"name": "ok_no_proofs_given", "fn": "Get-WorkdirProblems",
     "args": {"Site": "verify", "Finished": True, "Ledger": GOOD, "MinStarts": 2, "Proofs": ["", ""]}},
    {"name": "unfinished", "fn": "Get-WorkdirProblems",
     "args": {"Site": "repair", "Finished": False, "Ledger": GOOD, "MinStarts": 2, "Proofs": ["a proof gap"]}},
    {"name": "outside", "fn": "Get-WorkdirProblems",
     "args": {"Site": "repair", "Finished": True, "Ledger": [start(), IN_DIST, start()], "MinStarts": 3, "Proofs": []}},
    {"name": "no_data", "fn": "Get-WorkdirProblems",
     "args": {"Site": "optbuild", "Finished": True, "Ledger": [start(), start(data=False)], "MinStarts": 2, "Proofs": []}},
    {"name": "too_few_starts", "fn": "Get-WorkdirProblems",
     "args": {"Site": "repair", "Finished": True, "Ledger": [start()], "MinStarts": 3, "Proofs": []}},
    {"name": "empty_ledger", "fn": "Get-WorkdirProblems",
     "args": {"Site": "fastpath", "Finished": True, "Ledger": [], "MinStarts": 1, "Proofs": []}},
    {"name": "unreadable_line", "fn": "Get-WorkdirProblems",
     "args": {"Site": "interpreter", "Finished": True, "Ledger": [{"parseError": "{not json"}], "MinStarts": 1, "Proofs": []}},
    {"name": "proof_gap", "fn": "Get-WorkdirProblems",
     "args": {"Site": "repair", "Finished": True, "Ledger": [start(), start(), start()], "MinStarts": 3,
              "Proofs": ["the repair loop was not accepted", ""]}},
    {"name": "same_not_true", "fn": "Get-WorkdirProblems",
     "args": {"Site": "verify", "Finished": True, "Ledger": [start(same=False), start()], "MinStarts": 2, "Proofs": []}},
    # the kinds of start
    {"name": "kinds", "fn": "Get-StartKinds",
     "args": {"Ledger": [start(), start(frozen=False), IN_DIST, start(data=False)]}},
    {"name": "kinds_empty", "fn": "Get-StartKinds", "args": {"Ledger": []}},
    # a precondition read from a log
    {"name": "proof_present", "fn": "Get-ProofGap",
     "args": {"Text": LOG, "Pattern": "Repair loop: accepted", "Sentence": "not accepted"}},
    {"name": "proof_absent", "fn": "Get-ProofGap",
     "args": {"Text": LOG, "Pattern": "Optimized build succeeded and verified", "Sentence": "not verified"}},
    {"name": "proof_empty_text", "fn": "Get-ProofGap",
     "args": {"Text": "", "Pattern": "Repair loop: accepted", "Sentence": "not accepted"}},
    # paths in a row
    {"name": "path_dist", "fn": "Get-ShortPath", "args": {"Path": "C:\\w\\a\\b\\c\\dist"}},
    {"name": "path_short", "fn": "Get-ShortPath", "args": {"Path": "C:\\dist"}},
    {"name": "path_empty", "fn": "Get-ShortPath", "args": {"Path": ""}},
    {"name": "path_non_ascii", "fn": "Get-ShortPath", "args": {"Path": "C:\\Users\\Z\u00e9\\w\\dist"}},
    # the excerpt
    {"name": "excerpt", "fn": "Get-Excerpt", "args": {"Text": LOG}},
    {"name": "excerpt_max", "fn": "Get-Excerpt", "args": {"Text": LOG, "Max": 2}},
]


class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_script_has_its_rows_programs_scenarios_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_log_lines_the_script_looks_for_are_still_written(self):
        self.assertEqual(log_problems(self.batch), [])

    def test_the_step_gates_the_conda_full_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_no_start_of_the_program_runs_from_dist(self):
        self.assertEqual(batch_problems(self.batch), [])

    def test_the_script_is_ascii(self):
        self.script.encode("ascii")

    def test_the_readme_holds_the_shall_the_rows_are_tagged_with(self):
        self.assertIn("**%s**" % TAG, README_TEXT)

    def test_the_checks_are_not_vacuous_on_the_real_batch(self):
        flat = self.batch.replace("\r\n", "\n")
        for start, end in (("\n:offer_optimized_build\n", "\n:try_fast_exe\n"), ("\n:hidden_import_recover\n", "\n:warn_user_code_launch\n")):
            body = between(flat, start, end)
            self.assertIsNotNone(body, start)
            self.assertGreater(len(body.split("\n")), 30, start)
            self.assertTrue(any("Process]::Start" in ln and not is_comment(ln) for ln in body.split("\n")), start)


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgingFunctions(unittest.TestCase):
    """The script's pure functions, run in a real pwsh on synthetic runs: a red row must be able to appear."""

    @classmethod
    def setUpClass(cls):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            cls.r = run_cases(CASES, tmp)

    def test_starts_in_the_entry_folder_with_the_data_file_have_no_problems(self):
        self.assertEqual(self.r["ok"], [])
        self.assertEqual(self.r["ok_no_proofs_given"], [], "empty proof strings are 'nothing missing', not problems")

    def test_a_start_in_dist_is_named_with_its_folder_and_its_missing_data_file(self):
        problems = self.r["outside"]
        self.assertTrue(any("start 2 ran in ...\\~selftest_workdir_repair\\dist" in p and "not in the folder that holds the program" in p
                            for p in problems), problems)
        self.assertTrue(any("start 2 could not open workdir_data.txt" in p for p in problems), problems)
        self.assertFalse(any("start 1" in p or "start 3" in p for p in problems), "only the start in dist is a problem")

    def test_a_start_that_cannot_open_the_data_file_is_a_problem_even_in_the_right_folder(self):
        self.assertEqual(len(self.r["no_data"]), 1, self.r["no_data"])
        self.assertIn("start 2 could not open workdir_data.txt", self.r["no_data"][0])
        self.assertTrue(any("start 1 ran in" in p for p in self.r["same_not_true"]), "same must be exactly true")

    def test_a_row_cannot_pass_without_the_starts_it_needs(self):
        self.assertTrue(any("shows 1 start(s) but at least 3 are expected" in p for p in self.r["too_few_starts"]), self.r["too_few_starts"])
        self.assertTrue(any("shows 0 start(s) but at least 1 are expected" in p for p in self.r["empty_ledger"]), self.r["empty_ledger"])

    def test_a_bootstrap_that_did_not_finish_is_one_problem_and_nothing_else(self):
        self.assertEqual(len(self.r["unfinished"]), 1)
        self.assertIn("did not finish within the time limit", self.r["unfinished"][0])

    def test_a_ledger_line_that_is_not_json_is_a_problem(self):
        self.assertTrue(any("not a readable ledger line" in p for p in self.r["unreadable_line"]), self.r["unreadable_line"])

    def test_a_missing_precondition_is_a_problem_of_its_site(self):
        self.assertEqual(self.r["proof_gap"], ["repair: the repair loop was not accepted"])

    def test_starts_are_counted_by_kind(self):
        k = self.r["kinds"]
        self.assertEqual((k["frozen"], k["interpreter"], k["outside"], k["noData"]), (3, 1, 1, 2))
        k = self.r["kinds_empty"]
        self.assertEqual((k["frozen"], k["interpreter"], k["outside"], k["noData"]), (0, 0, 0, 0))

    def test_a_precondition_is_met_only_when_the_log_shows_it(self):
        self.assertEqual(self.r["proof_present"], [""])
        self.assertEqual(self.r["proof_absent"], ["not verified"])
        self.assertEqual(self.r["proof_empty_text"], ["not accepted"])

    def test_paths_are_cut_to_their_end_and_printable_ascii(self):
        self.assertEqual(self.r["path_dist"], ["...\\c\\dist"])
        self.assertEqual(self.r["path_short"], ["C:\\dist"])
        self.assertEqual(self.r["path_empty"], ["(empty)"])
        self.assertEqual(self.r["path_non_ascii"], ["...\\w\\dist"])

    def test_the_excerpt_keeps_the_lines_that_explain_a_row_and_nothing_else(self):
        ex = self.r["excerpt"]
        self.assertEqual(len(ex), 6, ex)
        self.assertTrue(any("Chosen entry" in ln for ln in ex))
        self.assertTrue(any("Repair loop: accepted" in ln for ln in ex))
        self.assertFalse(any("unrelated" in ln for ln in ex))
        self.assertTrue(all(all(32 <= ord(c) < 127 for c in ln) for ln in ex), "the excerpt is printable ASCII only")
        self.assertEqual(len(self.r["excerpt_max"]), 2)


class EachRuleCanFail(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    # --- the script
    def test_a_row_id_that_is_not_literal_is_caught(self):
        text = self.script.replace("id = 'self.workdir.optbuild'; req = '%s'" % TAG, "id = $optId; req = '%s'" % TAG)
        self.assertTrue(any("self.workdir.optbuild" in f for f in script_problems(text)))

    def test_a_row_that_stops_naming_its_requirement_is_caught(self):
        text = self.script.replace("id = 'self.workdir.repair'; req = '%s'" % TAG, "id = 'self.workdir.repair'; req = 'N/A'")
        self.assertTrue(any("self.workdir.repair" in f for f in script_problems(text)))

    def test_a_relative_ledger_path_is_caught(self):
        text = self.script.replace("WORKDIR_LEDGER = (Join-Path $Dir '~workdir_ledger.jsonl')", "WORKDIR_LEDGER = '~workdir_ledger.jsonl'")
        self.assertTrue(any("absolute path" in f for f in script_problems(text)))

    def test_a_program_that_fails_before_it_writes_the_ledger_is_caught(self):
        old = 'with open(os.environ["WORKDIR_LEDGER"], "a") as f:'
        code = app_code(self.script, "repair")
        self.assertIn(old, code)
        text = self.script.replace(code, code.replace(old, 'open("workdir_data.txt", "r").read()\n' + old, 1), 1)
        self.assertTrue(any("after the program can already fail" in f for f in script_problems(text)), script_problems(text))

    def test_a_program_that_no_longer_reads_the_ledger_path_is_caught(self):
        text = self.script.replace('os.environ["WORKDIR_LEDGER"]', 'os.environ["OTHER_LEDGER"]')
        self.assertTrue(any("does not read the ledger path" in f for f in script_problems(text)))

    def test_a_program_that_compares_paths_as_text_is_caught(self):
        text = self.script.replace("os.path.samefile(cwd, expect)", "cwd == expect")
        self.assertTrue(any("8.3" in f for f in script_problems(text)))

    def test_a_program_that_no_longer_says_who_started_it_is_caught(self):
        text = self.script.replace('"frozen": bool(getattr(sys, "frozen", False)),', "")
        self.assertTrue(any("EXE or the interpreter" in f for f in script_problems(text)))

    def test_a_repair_program_without_colorama_is_caught(self):
        text = self.script.replace("importlib.import_module('colorama')", "importlib.import_module('json')")
        self.assertTrue(any("colorama" in f for f in script_problems(text)))

    def test_a_scenario_that_stops_giving_its_consent_is_caught(self):
        for old, word in (("HP_TEST_REPAIR_ANSWER = 'Y'", "repair question"), ("HP_TEST_CHECKPOINT_ANSWER = 'Y'", "checkpoint"),
                          ("PVW_BUILDER = 'both'", "PVW_BUILDER=both")):
            text = self.script.replace(old, old.replace("'Y'", "'N'").replace("'both'", "'auto'"))
            self.assertTrue(any(word in f for f in script_problems(text)), old)

    def test_a_scenario_that_stops_forcing_the_interpreter_is_caught(self):
        text = self.script.replace("HP_TEST_FORCE_NUITKA_FAIL = '1'", "HP_TEST_FORCE_NUITKA_FAIL = '0'")
        self.assertTrue(any("Nuitka" in f for f in script_problems(text)))

    def test_a_row_that_stops_requiring_its_starts_is_caught(self):
        text = self.script.replace("-Site 'repair' -Finished ([bool]$rRun.Finished) -Ledger $rLedger -MinStarts 3",
                                   "-Site 'repair' -Finished ([bool]$rRun.Finished) -Ledger $rLedger -MinStarts 1")
        self.assertTrue(any("repair: the row no longer requires at least 3" in f for f in script_problems(text)), script_problems(text))

    def test_a_precondition_that_is_dropped_is_caught(self):
        text = self.script.replace("Optimized build succeeded and verified", "Optimized build")
        self.assertTrue(any("precondition" in f for f in script_problems(text)))

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

    # --- the log lines
    def test_a_reworded_log_line_is_caught(self):
        text = self.batch.replace("Repair loop: accepted", "Repair loop: allowed")
        self.assertTrue(any("Repair loop: accepted" in f for f in log_problems(text)))
        text = self.batch.replace("Optimized build succeeded and verified", "Optimized build is ready")
        self.assertTrue(any("Optimized build succeeded and verified" in f for f in log_problems(text)))

    def test_a_log_text_that_only_a_comment_holds_is_caught(self):
        lines = [("rem " + ln if "Fast path: reusing" in ln and "call :log" in ln else ln) for ln in lines_of(self.batch)]
        found = log_problems("\n".join(lines))
        self.assertTrue(any("Fast path: reusing" in f for f in found), found)

    # --- the workflow step
    def test_a_step_that_is_not_the_conda_full_lane_is_caught(self):
        block = step_block(self.workflow)
        mutated = self.workflow.replace(block, block.replace("matrix.mode == 'conda-full'", "matrix.mode == 'uv'"))
        self.assertTrue(any("conda-full lane" in f for f in workflow_problems(mutated)))

    def test_a_step_that_cannot_fail_is_caught(self):
        block = step_block(self.workflow)
        mutated = self.workflow.replace(block, block.replace("shell: pwsh", "shell: pwsh\n        continue-on-error: true"))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(mutated)))

    def test_a_missing_step_is_caught(self):
        mutated = self.workflow.replace("selfapps_workdir.ps1", "something_else.ps1")
        self.assertEqual(workflow_problems(mutated), ["no step runs tests\\selfapps_workdir.ps1"])

    def test_a_missing_upload_pattern_is_caught(self):
        mutated = self.workflow.replace("tests/~selftest_workdir_*/~workdir_ledger.jsonl", "tests/~selftest_workdir_*/~other.jsonl")
        self.assertTrue(any("~workdir_ledger.jsonl" in f for f in workflow_problems(mutated)))

    def test_an_unregistered_row_is_caught(self):
        registry = REGISTRY.read_text(encoding="utf-8").replace("self.workdir.optbuild", "self.workdir.other")
        self.assertEqual(registry_problems(registry), ["self.workdir.optbuild is not in docs/agent-ndjson.md"])

    # --- the batch: each pin fails on a synthetic change (a good batch is built from the real one, or from a small stand-in)
    GOOD_BATCH = "\n".join((
        "@echo off",
        ":offer_optimized_build",
        'set "HP_OPTBUILD_EXE=%CD%\\dist\\%HP_OPTBUILD_TMP%"',
        'for /f "usebackq delims=" %%X in (`powershell -NoProfile -Command "$si=New-Object System.Diagnostics.ProcessStartInfo;$si.FileName=$env:HP_OPTBUILD_EXE;$p=[System.Diagnostics.Process]::Start($si);$p.ExitCode"`) do set "HP_OPTBUILD_VERIFY_EXIT=%%X"',
        "exit /b 0",
        ":try_fast_exe",
        "exit /b 0",
        ":hidden_import_recover",
        'set "HP_HIR_EXE=%CD%\\dist\\%ENVNAME%.exe"',
        'for /f "usebackq delims=" %%X in (`powershell -NoProfile -Command "$si=New-Object System.Diagnostics.ProcessStartInfo;$si.FileName=$env:HP_HIR_EXE;$p=[System.Diagnostics.Process]::Start($si);($so.Result)|Set-Content -Path \'dist\\~exe_out.txt\' -Encoding ASCII;$p.ExitCode"`) do set "HP_EXE_EXIT=%%X"',
        "exit /b 0",
        ":warn_user_code_launch",
        "exit /b 0",
        "",
    ))

    def test_the_synthetic_good_batch_is_clean(self):
        self.assertEqual(batch_problems(self.GOOD_BATCH), [])

    def _mutate(self, old, new):
        self.assertIn(old, self.GOOD_BATCH, "the synthetic case needs the text to hold " + old[:40])
        return self.GOOD_BATCH.replace(old, new, 1)

    def test_a_pushd_dist_is_caught(self):
        text = self._mutate(":hidden_import_recover\n", ":hidden_import_recover\npushd dist\n")
        found = batch_problems(text)
        self.assertTrue(any("changes into dist" in f for f in found), found)
        self.assertTrue(any("repair loop changes the working folder" in f for f in found), found)

    def test_a_pushd_dist_in_the_optimized_build_is_caught(self):
        text = self._mutate(":offer_optimized_build\n", ":offer_optimized_build\npushd dist\n")
        self.assertTrue(any("optimized-build verification changes the working folder" in f for f in batch_problems(text)))

    def test_a_cd_into_another_folder_is_caught(self):
        text = self._mutate(":offer_optimized_build\n", ":offer_optimized_build\ncd /d dist\n")
        self.assertTrue(any("optimized-build verification changes the working folder" in f for f in batch_problems(text)))

    def test_a_pushd_that_only_a_comment_holds_is_not_a_finding(self):
        text = self._mutate(":hidden_import_recover\n", ":hidden_import_recover\nrem pushd dist was removed by Item 101\n")
        self.assertEqual(batch_problems(text), [])

    def test_a_bare_relative_exe_name_is_caught(self):
        text = self._mutate("$si.FileName=$env:HP_HIR_EXE", "$si.FileName='%ENVNAME%.exe'")
        self.assertTrue(any("absolute path in an environment variable" in f for f in batch_problems(text)))

    def test_an_environment_variable_that_is_never_set_is_caught(self):
        text = self._mutate('set "HP_HIR_EXE=%CD%\\dist\\%ENVNAME%.exe"', 'set "HP_OTHER=1"')
        self.assertTrue(any("HP_HIR_EXE is not set" in f for f in batch_problems(text)))

    def test_an_environment_variable_set_to_a_path_outside_dist_is_caught(self):
        text = self._mutate('set "HP_OPTBUILD_EXE=%CD%\\dist\\%HP_OPTBUILD_TMP%"', 'set "HP_OPTBUILD_EXE=%HP_OPTBUILD_TMP%"')
        self.assertTrue(any("HP_OPTBUILD_EXE is not set" in f for f in batch_problems(text)))

    def test_a_working_directory_on_a_launch_is_caught(self):
        text = self._mutate("$si.FileName=$env:HP_OPTBUILD_EXE;", "$si.FileName=$env:HP_OPTBUILD_EXE;$si.WorkingDirectory='dist';")
        self.assertTrue(any("WorkingDirectory" in f for f in batch_problems(text)))

    def test_a_capture_file_that_moves_out_of_dist_is_caught(self):
        text = self._mutate("Set-Content -Path 'dist\\~exe_out.txt'", "Set-Content -Path '~exe_out.txt'")
        self.assertTrue(any("dist\\~exe_out.txt" in f for f in batch_problems(text)))

    def test_a_third_launch_is_caught(self):
        extra = '\nfor /f %%X in (`powershell -Command "[System.Diagnostics.Process]::Start($x)"`) do echo %%X\n'
        found = batch_problems(self.GOOD_BATCH + extra)
        self.assertTrue(any("expected the 2 inline launch lines" in f for f in found), found)

    def test_the_old_deferral_comment_is_caught(self):
        text = self.GOOD_BATCH + "\nrem the verification of the build still runs from dist\\ (current working directory)\n"
        self.assertTrue(any("still runs from dist" in f for f in batch_problems(text)))

    def test_a_missing_subroutine_is_caught(self):
        text = self.GOOD_BATCH.replace(":try_fast_exe", ":something_else")
        self.assertTrue(any("subroutine labels" in f for f in batch_problems(text)))


if __name__ == "__main__":
    unittest.main()
