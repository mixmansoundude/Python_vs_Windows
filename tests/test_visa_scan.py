"""Item 124 (README REQ-008.5 and REQ-008.6): what the NI-VISA scan reads and what it does not take for an import.

REQ-008.5 says the scan reads every .py file of the program folder and of its subfolders, except files whose names start with ~ and
folders whose names start with ~ or a dot; REQ-008.6 says a module whose name only begins with the letters of pyvisa or visa (pyvista,
vision) is not an import of pyvisa or visa. Until this item the shall-level trace test listed both as unit-only: tests/test_detect_visa.py
runs tools/detect_visa.py on files, so a bootstrapper that never ran the scanner, or read its answer wrongly, would have shown nothing.

tests/selfapps_pyvisa_subfolder.ps1 got two rows (self.nivisa.scan.skips and self.nivisa.scan.lookalike, real and conda-full lanes,
gating). Each is one real bootstrap of a folder with HP_SKIP_NIVISA=1, so a wrong scan can never start a real driver install, and
with the program itself not started. The scanner writes one setup-log line per matching file and the batch file says what it
concluded in an [INFO] line of the console; the two judges read both, so a scan that took a skipped file, a lookalike or nothing is a
red row with the file named.

What really happens is shown on Windows by that script. These rules read the script, run_setup.bat, tools/detect_visa.py,
batch-check.yml, docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, run the script's judging functions through a real
pwsh in strict mode on synthetic runs (a run that passes, and one run for each way to be wrong), build the script's own fixture
folders from its own text and run the real tools/detect_visa.py on them (a scanner that has lost a rule is one a judge reports),
so a reworded line, a fixture that stops holding what the shall needs, a judge that stops judging or an upload that goes missing fails
here with a sentence, before a Windows run is needed. Synthetic cases prove each rule can fail. The shared helpers are in
tests/judge_support.py.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import (HARD_TIMEOUT, PWSH, case, live_bat, live_hash, mutate, norm, registry_ids,  # noqa: E402
                           run_cases, text_of)

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_pyvisa_subfolder.ps1"
DETECT = REPO / "tools" / "detect_visa.py"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"

SKIPS_ROW, SKIPS_REQ = "self.nivisa.scan.skips", "REQ-008.5"
LOOK_ROW, LOOK_REQ = "self.nivisa.scan.lookalike", "REQ-008.6"
ROWS = ((SKIPS_ROW, SKIPS_REQ), (LOOK_ROW, LOOK_REQ))
OLDER_ROWS = ("self.nivisa.subfolder.declined", "self.nivisa.subfolder.accepted", "self.nivisa.topfolder.noprompt",
              "self.nivisa.subfolder.timeout", "self.nivisa.pyvisa.installed")
JUDGES = ["Get-VisaFoundFiles", "Get-VisaLineCount", "Get-ScanSkipsProblems", "Get-ScanLookalikeProblems"]
GAP_SHALLS = (SKIPS_REQ, LOOK_REQ)

# The texts the judges read, each of them one live call :log line of the batch file.
ONLY = "[INFO] Detected pyvisa/visa import only in a subfolder; the NI-VISA install needs your OK."
TOP = "[INFO] Detected pyvisa/visa import; NI-VISA install may be required."
NONE = "[INFO] No pyvisa/visa imports detected."
DISABLED = "[VISA] skipped (disabled)"
NOT_REQUIRED = "[VISA] skipped (not_required)"
LOG_TEXTS = (ONLY, TOP, NONE, DISABLED, NOT_REQUIRED)
FOUND = "[VISA] pyvisa/visa import found in: %s"
STAMP = "Mon 11/16/2026 10:00:00.01 "

WANT = "archive\\2019\\bench\\old_tool.py"
SKIP_PATHS = ["~scratch.py", "~old\\tool.py", ".hidden\\tool.py"]
# tools/detect_visa.py prints a ~ as an underscore (a path is echoed unquoted), so this is what the setup log holds for a skipped file the
# scan took; the judge names the file as it was planted.
PRINTED_TILDE_FILE = "_scratch.py"
PRINTED_TILDE_FOLDER = "_old\\tool.py"

SCAN_ENV_LINE = "$scanEnv = @{ HP_SKIP_NIVISA = '1'; HP_SKIP_ENTRY_SMOKE = '1'; HP_SKIP_EXE_SMOKERUN = '1' }"
NEED_LINES = (
    SCAN_ENV_LINE,
    "$deepFile = 'archive\\2019\\bench\\old_tool.py'",
    "$skipPaths = @('~scratch.py', '~old\\tool.py', '.hidden\\tool.py')",
    "$sk = Invoke-VisaScenario -Name 'scanskips' -Files $scanFiles -EnvSet $scanEnv",
    "$skMissing = @(foreach ($rel in $scanFiles.Keys) { if (-not (Test-Path -LiteralPath (Join-Path $sk.Work $rel))) { $rel } })",
    "$skProblems = @(Get-ScanSkipsProblems -SetupText $sk.Setup -ConsoleText $sk.Console -WantFile $deepFile -NotFiles $skipPaths -MissingFiles $skMissing)",
    "$scanPass = [bool](@($skProblems).Count -eq 0)",
    "$lk = Invoke-VisaScenario -Name 'lookalike' -Files $lookFiles -EnvSet $scanEnv",
    "$lkMissing = @(foreach ($rel in $lookFiles.Keys) { if (-not (Test-Path -LiteralPath (Join-Path $lk.Work $rel))) { $rel } })",
    "$scanWorked = [bool](@(Get-VisaFoundFiles -SetupText $sk.Setup) -ccontains ($deepFile + ' (subfolder)'))",
    "$lkProblems = @(Get-ScanLookalikeProblems -SetupText $lk.Setup -ConsoleText $lk.Console -MissingFiles $lkMissing -ScanShownWorking $scanWorked)",
    "$lookPass = [bool](@($lkProblems).Count -eq 0)",
    "if (-not ($scanPass -and $lookPass)) { exit 1 }",
)
UPLOADS = tuple(
    pattern
    for name in ("scanskips", "lookalike")
    for pattern in ("tests/~selftest_pyvisa_sub_%s/~pyvisa_sub_%s.log" % (name, name),
                    "tests\\~selftest_pyvisa_sub_%s\\~pyvisa_sub_%s.log" % (name, name),
                    "tests/~selftest_pyvisa_sub_%s/~setup.log" % name,
                    "tests\\~selftest_pyvisa_sub_%s\\~setup.log" % name))

# What a scan has to take for an import (the real tools/detect_visa.py pattern) and what only begins like one.
REAL_IMPORT = re.compile(r"(?m)^\s*(?:from|import)\s+(?:py)?visa\b")
TRUNCATED_IMPORT = re.compile(r"(?m)^\s*(?:from|import)\s+(?:py)?vis")


# --- synthetic runs: the texts the batch file and the scanner write ---------------------------------------------------------------

def con(*lines):
    """A console log as the batch file writes it: the date and time in front of every line."""
    return text_of([STAMP + ln for ln in lines])


def setup_with(*lines):
    return text_of(["[INFO] earlier line"] + list(lines) + ["[INFO] later line"])


def console_for(digit):
    """What the batch file says about the scanner's answer, with the line the install step adds when HP_SKIP_NIVISA=1."""
    head = {"2": ONLY, "1": TOP, "0": NONE}[digit]
    tail = NOT_REQUIRED if digit == "0" else DISABLED
    return con("[INFO] Python file count: 3", head, tail, "[INFO] done")


SK_SETUP = setup_with(FOUND % (WANT + " (subfolder)"))
SK_CONSOLE = console_for("2")
LK_SETUP = setup_with()
LK_CONSOLE = console_for("0")


def sk(**over):
    args = dict(SetupText=SK_SETUP, ConsoleText=SK_CONSOLE, WantFile=WANT, NotFiles=SKIP_PATHS, MissingFiles=[])
    args.update(over)
    return args


def lk(**over):
    args = dict(SetupText=LK_SETUP, ConsoleText=LK_CONSOLE, MissingFiles=[], ScanShownWorking=True)
    args.update(over)
    return args


# case name -> the sentence its one problem holds
SKIPS_ONE = {
    "sk_missing_fixture_file": "precondition: the folder of the run no longer holds ~old\\tool.py",
    "sk_deep_file_not_named": "the scan did not name " + WANT + " (subfolder)",
    "sk_took_tilde_file": "the scan took ~scratch.py for an import",
    "sk_took_tilde_folder": "the scan took ~old\\tool.py for an import",
    "sk_took_dot_folder": "the scan took .hidden\\tool.py for an import",
    "sk_unplanted_file": "the scan named a file nobody planted as a match: main.py (top folder)",
    "sk_console_only_line_missing": "the console shows the line '%s' 0 time(s), expected 1" % ONLY,
    "sk_console_only_line_twice": "the console shows the line '%s' 2 time(s), expected 1" % ONLY,
    "sk_console_top_line": "the console says an import sits next to run_setup.bat",
    "sk_console_none_line": "the console says no import was detected although %s holds one" % WANT,
    "sk_not_disabled": "precondition: the console shows '%s' 0 time(s), expected 1" % DISABLED,
}
LOOK_ONE = {
    "lk_missing_fixture_file": "precondition: the folder of the run no longer holds plots\\view.py",
    "lk_scan_not_shown_working": "precondition: the scan of self.nivisa.scan.skips did not name its file",
    "lk_found_top": "the scan took lookalikes.py (top folder) for an import of pyvisa or visa",
    "lk_found_sub": "the scan took plots\\view.py (subfolder) for an import of pyvisa or visa",
    "lk_console_none_missing": "the console shows the line '%s' 0 time(s), expected 1" % NONE,
    "lk_console_none_twice": "the console shows the line '%s' 2 time(s), expected 1" % NONE,
    "lk_console_detected_top": "the console says an import was detected: '%s'" % TOP,
    "lk_console_detected_sub": "the console says an import was detected: '%s'" % ONLY,
    "lk_not_required_missing": "the console shows '%s' 0 time(s), expected 1" % NOT_REQUIRED,
}
SKIPS_EVERYTHING_WRONG = (
    "precondition: the folder of the run no longer holds main.py",
    "the scan did not name " + WANT + " (subfolder)",
    "the scan took ~scratch.py for an import",
    "the console shows the line '%s' 0 time(s), expected 1" % ONLY,
    "the console says an import sits next to run_setup.bat",
    "the console says no import was detected although %s holds one" % WANT,
    "precondition: the console shows '%s' 0 time(s), expected 1" % DISABLED,
)
LOOK_EVERYTHING_WRONG = (
    "precondition: the folder of the run no longer holds main.py",
    "precondition: the scan of self.nivisa.scan.skips did not name its file",
    "the scan took lookalikes.py (top folder) for an import of pyvisa or visa",
    "the scan took plots\\view.py (subfolder) for an import of pyvisa or visa",
    "the console shows the line '%s' 0 time(s), expected 1" % NONE,
    "the console says an import was detected: '%s'" % TOP,
    "the console says an import was detected: '%s'" % ONLY,
    "the console shows '%s' 0 time(s), expected 1" % NOT_REQUIRED,
)


def judge_cases():
    c = []
    gf, gc, gs, gl = JUDGES
    # --- Get-VisaFoundFiles: the scanner's lines of the setup log, in order
    c.append(case("found_two", gf, SetupText=text_of(["[INFO] a", FOUND % "a\\b.py (subfolder)", "[INFO] b", FOUND % "c.py (top folder)"])))
    c.append(case("found_none", gf, SetupText=text_of(["[INFO] a", "[INFO] b"])))
    c.append(case("found_empty", gf, SetupText=""))
    c.append(case("found_trailing_spaces", gf, SetupText=(FOUND % "a.py (subfolder)") + "   \r\n"))
    c.append(case("found_lf_only", gf, SetupText=(FOUND % "a.py (subfolder)") + "\n" + (FOUND % "b.py (top folder)") + "\n"))
    c.append(case("found_other_place_name", gf, SetupText=text_of([FOUND % "a.py (elsewhere)"])))
    c.append(case("found_text_after_the_place", gf, SetupText=text_of([FOUND % "a.py (subfolder) and more"])))
    c.append(case("found_the_consoles_own_lines_are_not_found_lines", gf, SetupText=con(ONLY, TOP, DISABLED)))
    # --- Get-VisaLineCount: lines that are exactly this text, after the date and time or alone
    line = DISABLED
    c.append(case("count_prefixed", gc, Text=con(line), Line=line))
    c.append(case("count_bare", gc, Text=text_of([line]), Line=line))
    c.append(case("count_twice", gc, Text=con(line, "x", line), Line=line))
    c.append(case("count_glued_to_a_word", gc, Text=text_of(["x" + line]), Line=line))
    c.append(case("count_text_after", gc, Text=text_of([line + " again"]), Line=line))
    c.append(case("count_trailing_spaces_trimmed", gc, Text=line + "   \r\n", Line=line))
    c.append(case("count_case_matters", gc, Text=text_of(["[visa] skipped (disabled)"]), Line=line))
    c.append(case("count_empty", gc, Text="", Line=line))
    c.append(case("count_lf_only", gc, Text=STAMP + line + "\n" + STAMP + line + "\n", Line=line))
    # --- Get-ScanSkipsProblems (REQ-008.5)
    c.append(case("sk_good", gs, **sk()))
    c.append(case("sk_missing_fixture_file", gs, **sk(MissingFiles=["~old\\tool.py"])))
    c.append(case("sk_deep_file_not_named", gs, **sk(SetupText=setup_with())))
    c.append(case("sk_took_tilde_file", gs, **sk(SetupText=setup_with(FOUND % (WANT + " (subfolder)"), FOUND % (PRINTED_TILDE_FILE + " (top folder)")))))
    c.append(case("sk_took_tilde_folder", gs, **sk(SetupText=setup_with(FOUND % (WANT + " (subfolder)"), FOUND % (PRINTED_TILDE_FOLDER + " (subfolder)")))))
    c.append(case("sk_took_dot_folder", gs, **sk(SetupText=setup_with(FOUND % (WANT + " (subfolder)"), FOUND % ".hidden\\tool.py (subfolder)"))))
    c.append(case("sk_unplanted_file", gs, **sk(SetupText=setup_with(FOUND % (WANT + " (subfolder)"), FOUND % "main.py (top folder)"))))
    c.append(case("sk_console_only_line_missing", gs, **sk(ConsoleText=con("[INFO] Python file count: 3", DISABLED))))
    c.append(case("sk_console_only_line_twice", gs, **sk(ConsoleText=con(ONLY, ONLY, DISABLED))))
    c.append(case("sk_console_top_line", gs, **sk(ConsoleText=con(ONLY, TOP, DISABLED))))
    c.append(case("sk_console_none_line", gs, **sk(ConsoleText=con(ONLY, NONE, DISABLED))))
    c.append(case("sk_not_disabled", gs, **sk(ConsoleText=con(ONLY, "[INFO] done"))))
    c.append(case("sk_two_skipped_files_taken", gs, **sk(SetupText=setup_with(FOUND % (WANT + " (subfolder)"), FOUND % (PRINTED_TILDE_FILE + " (top folder)"),
                                                                           FOUND % (PRINTED_TILDE_FOLDER + " (subfolder)")))))
    c.append(case("sk_everything_wrong", gs, **sk(MissingFiles=["main.py"], SetupText=setup_with(FOUND % (PRINTED_TILDE_FILE + " (top folder)")),
                                                  ConsoleText=con(TOP, NONE))))
    # --- Get-ScanLookalikeProblems (REQ-008.6)
    c.append(case("lk_good", gl, **lk()))
    c.append(case("lk_missing_fixture_file", gl, **lk(MissingFiles=["plots\\view.py"])))
    c.append(case("lk_scan_not_shown_working", gl, **lk(ScanShownWorking=False)))
    c.append(case("lk_found_top", gl, **lk(SetupText=setup_with(FOUND % "lookalikes.py (top folder)"))))
    c.append(case("lk_found_sub", gl, **lk(SetupText=setup_with(FOUND % "plots\\view.py (subfolder)"))))
    c.append(case("lk_console_none_missing", gl, **lk(ConsoleText=con("[INFO] Python file count: 3", NOT_REQUIRED))))
    c.append(case("lk_console_none_twice", gl, **lk(ConsoleText=con(NONE, NONE, NOT_REQUIRED))))
    c.append(case("lk_console_detected_top", gl, **lk(ConsoleText=con(NONE, TOP, NOT_REQUIRED))))
    c.append(case("lk_console_detected_sub", gl, **lk(ConsoleText=con(NONE, ONLY, NOT_REQUIRED))))
    c.append(case("lk_not_required_missing", gl, **lk(ConsoleText=con(NONE, "[INFO] done"))))
    c.append(case("lk_two_files_taken", gl, **lk(SetupText=setup_with(FOUND % "lookalikes.py (top folder)", FOUND % "plots\\view.py (subfolder)"))))
    c.append(case("lk_everything_wrong", gl, **lk(MissingFiles=["main.py"], ScanShownWorking=False,
                                                  SetupText=setup_with(FOUND % "lookalikes.py (top folder)", FOUND % "plots\\view.py (subfolder)"),
                                                  ConsoleText=con(TOP, ONLY))))
    return c


FOUND_CASE_COUNT = 8
COUNT_CASE_COUNT = 9
SKIPS_CASE_COUNT = 1 + len(SKIPS_ONE) + 2   # good + one problem each + two wrong in two ways + everything wrong
LOOK_CASE_COUNT = 1 + len(LOOK_ONE) + 2
JUDGE_CASE_COUNT = FOUND_CASE_COUNT + COUNT_CASE_COUNT + SKIPS_CASE_COUNT + LOOK_CASE_COUNT


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesOnSyntheticRuns(unittest.TestCase):
    """The four judging functions of tests/selfapps_pyvisa_subfolder.ps1 on synthetic runs, alone and in strict mode."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, JUDGES, judge_cases(), d)

    def only(self, name, needle):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        self.assertIn(needle, found[0], (name, found))

    def test_the_scanner_lines_are_read_in_order_with_their_place(self):
        self.assertEqual(self.r["found_two"], ["a\\b.py (subfolder)", "c.py (top folder)"])
        self.assertEqual(self.r["found_trailing_spaces"], ["a.py (subfolder)"])
        self.assertEqual(self.r["found_lf_only"], ["a.py (subfolder)", "b.py (top folder)"])

    def test_a_line_that_is_not_the_scanners_is_not_a_found_file(self):
        for name in ("found_none", "found_empty", "found_other_place_name", "found_text_after_the_place",
                     "found_the_consoles_own_lines_are_not_found_lines"):
            with self.subTest(case=name):
                self.assertEqual(self.r[name], [])

    def test_a_line_is_counted_after_the_date_and_time_or_alone_and_never_as_the_end_of_a_longer_word(self):
        self.assertEqual(self.r["count_prefixed"], [1])
        self.assertEqual(self.r["count_bare"], [1])
        self.assertEqual(self.r["count_twice"], [2])
        self.assertEqual(self.r["count_trailing_spaces_trimmed"], [1])
        self.assertEqual(self.r["count_lf_only"], [2])
        for name in ("count_glued_to_a_word", "count_text_after", "count_case_matters", "count_empty"):
            with self.subTest(case=name):
                self.assertEqual(self.r[name], [0])

    def test_a_good_run_of_each_scenario_has_no_problem(self):
        self.assertEqual(self.r["sk_good"], [])
        self.assertEqual(self.r["lk_good"], [])

    def test_each_wrong_skips_run_is_one_problem_with_its_own_sentence(self):
        for name, needle in SKIPS_ONE.items():
            with self.subTest(case=name):
                self.only(name, needle)

    def test_each_wrong_lookalike_run_is_one_problem_with_its_own_sentence(self):
        for name, needle in LOOK_ONE.items():
            with self.subTest(case=name):
                self.only(name, needle)

    def test_two_skipped_files_taken_are_two_problems_one_for_each_file(self):
        found = self.r["sk_two_skipped_files_taken"]
        self.assertEqual(len(found), 2, found)
        self.assertIn("the scan took ~scratch.py for an import", found[0])
        self.assertIn("the scan took ~old\\tool.py for an import", found[1])
        found = self.r["lk_two_files_taken"]
        self.assertEqual(len(found), 2, found)

    def test_a_run_that_is_wrong_in_every_way_names_every_way(self):
        for name, sentences in (("sk_everything_wrong", SKIPS_EVERYTHING_WRONG), ("lk_everything_wrong", LOOK_EVERYTHING_WRONG)):
            with self.subTest(case=name):
                found = self.r[name]
                self.assertEqual(len(found), len(sentences), found)
                for sentence in sentences:
                    self.assertTrue(any(sentence in f for f in found), (sentence, found))


# --- the fixtures of the script, built from its own text, and the real scanner on them -----------------------------------------------

FIXTURE_DRIVER = r"""
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
$__tokens = $null; $__errs = $null
$__ast = [System.Management.Automation.Language.Parser]::ParseFile($env:CC_SCRIPT, [ref]$__tokens, [ref]$__errs)
if ($__errs.Count -gt 0) { throw ('parse errors: ' + $__errs[0].Message) }
$__names = @('mainPlain', 'archived', 'deepFile', 'skipPaths', 'scanFiles', 'lookFiles')
$__assigns = $__ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $__names -contains $n.Left.VariablePath.UserPath }, $true)
if (@($__assigns).Count -ne $__names.Count) { throw ('expected ' + $__names.Count + ' assignments, found ' + @($__assigns).Count) }
foreach ($__a in $__assigns) { Invoke-Expression $__a.Extent.Text }
$__out = [ordered]@{ scanFiles = [ordered]@{}; lookFiles = [ordered]@{}; deepFile = [string]$deepFile; skipPaths = @($skipPaths) }
foreach ($__k in $scanFiles.Keys) { $__out.scanFiles[[string]$__k] = [string]$scanFiles[$__k] }
foreach ($__k in $lookFiles.Keys) { $__out.lookFiles[[string]$__k] = [string]$lookFiles[$__k] }
ConvertTo-Json -InputObject $__out -Compress -Depth 5
"""


def script_fixture(tmp, script=SCRIPT):
    """The two fixtures of the script (relative path with backslashes -> text, as PowerShell evaluates it) and its two lists."""
    driver = Path(tmp) / "fixture.ps1"
    driver.write_text(FIXTURE_DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["CC_SCRIPT"] = str(script)
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(driver)], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return json.loads(proc.stdout)


def build_folder(root, files):
    """The files as the script writes them: Set-Content with Ascii adds one line end after the text."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    for rel, text in files.items():
        target = root / rel.replace("\\", "/")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((text + "\r\n").encode("ascii"))
    return root


def run_scanner(source, folder):
    """The scanner's answer (stdout) and the lines it writes to stderr, run from the folder like the batch file runs it."""
    proc = subprocess.run([sys.executable, "-I", str(source)], cwd=str(folder), capture_output=True, text=True, timeout=HARD_TIMEOUT)
    assert proc.returncode == 0, proc.stderr
    return proc.stdout, [ln for ln in proc.stderr.split("\n") if ln.strip()]


# One rule of the real scanner broken at a time: (the text that must occur once, its replacement, the sentence the judge answers with)
SCANNER_BREAKS = {
    "reads_tilde_files": ("if not name.endswith('.py') or name.startswith('~'):", "if not name.endswith('.py'):",
                          "the scan took ~scratch.py for an import"),
    "walks_tilde_folders": ("if not item.startswith(('~', '.'))]", "if not item.startswith('.')]",
                            "the scan took ~old\\tool.py for an import"),
    "walks_dot_folders": ("if not item.startswith(('~', '.'))]", "if not item.startswith('~')]",
                          "the scan took .hidden\\tool.py for an import"),
    "reads_no_subfolder": ("dirs[:] = [item for item in dirs if not item.startswith(('~', '.'))]", "dirs[:] = []",
                           "the scan did not name " + WANT + " (subfolder)"),
    "stops_after_one_level": ("        dirs[:] = [item for item in dirs if not item.startswith(('~', '.'))]\n",
                              "        dirs[:] = [item for item in dirs if not item.startswith(('~', '.'))]\n"
                              "        if os.path.relpath(current, ROOT).count(os.sep) >= 1:\n            dirs[:] = []\n",
                              "the scan did not name " + WANT + " (subfolder)"),
}
LOOKALIKE_BREAK = ('r"(?m)^\\s*(?:from|import)\\s+(?:py)?visa\\b",', 'r"(?m)^\\s*(?:from|import)\\s+(?:py)?vis",',
                   "for an import of pyvisa or visa")


class ScannerPrintedForm(unittest.TestCase):
    """The setup log holds what the scanner printed, not what was planted: a ~ is printed as an underscore, because the batch file echoes a
    path unquoted. The skip judge looks for that printed form (a first version looked for the planted name and answered a taken skipped
    file with the less specific sentence about a file nobody planted, which the real scanner showed)."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("detect_visa_under_test", DETECT)
        cls.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.mod)

    def test_a_tilde_is_printed_as_an_underscore_and_a_dot_folder_and_the_deep_file_are_printed_as_they_are(self):
        self.assertEqual(self.mod.safe(SKIP_PATHS[0]), PRINTED_TILDE_FILE)
        self.assertEqual(self.mod.safe(SKIP_PATHS[1]), PRINTED_TILDE_FOLDER)
        self.assertEqual(self.mod.safe(SKIP_PATHS[2]), SKIP_PATHS[2])
        self.assertEqual(self.mod.safe(WANT), WANT)

    def test_the_two_printed_names_in_this_file_are_the_planted_names_with_the_tilde_replaced(self):
        self.assertEqual(PRINTED_TILDE_FILE, SKIP_PATHS[0].replace("~", "_"))
        self.assertEqual(PRINTED_TILDE_FOLDER, SKIP_PATHS[1].replace("~", "_"))


@unittest.skipUnless(PWSH, "pwsh not available")
class RealScannerOnTheScriptsFixtures(unittest.TestCase):
    """The script's own fixture folders, and the real tools/detect_visa.py (and copies of it with one rule broken) on them."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        root = Path(cls.tmp.name)
        cls.fx = script_fixture(root)
        cls.skips_dir = build_folder(root / "skips", cls.fx["scanFiles"])
        cls.look_dir = build_folder(root / "look", cls.fx["lookFiles"])
        cls.detect = DETECT.read_text(encoding="utf-8")

    def broken_scanner(self, old, new):
        path = Path(self.tmp.name) / ("scanner_%d.py" % abs(hash((old, new))))
        path.write_text(mutate(self.detect, old, new), encoding="utf-8")
        return path

    def judged(self, name, fn, **args):
        with tempfile.TemporaryDirectory() as d:
            return run_cases(SCRIPT, JUDGES, [case(name, fn, **args)], d)[name]

    # --- what the fixtures hold
    def test_the_skips_fixture_holds_a_deep_import_and_one_skipped_file_of_each_kind_that_each_hold_a_real_import(self):
        files = self.fx["scanFiles"]
        deep = self.fx["deepFile"]
        self.assertEqual(deep, WANT)
        self.assertGreaterEqual(deep.count("\\"), 3, "the wanted import must sit three folders down")
        self.assertRegex(files[deep], REAL_IMPORT)
        self.assertEqual(self.fx["skipPaths"], SKIP_PATHS)
        kinds = {"file": False, "tilde_folder": False, "dot_folder": False}
        for rel in self.fx["skipPaths"]:
            self.assertIn(rel, files)
            self.assertRegex(files[rel], REAL_IMPORT, "a skipped file must hold an import, or taking it would show nothing: " + rel)
            parts = rel.split("\\")
            if len(parts) == 1 and parts[0].startswith("~"):
                kinds["file"] = True
            elif parts[0].startswith("~"):
                kinds["tilde_folder"] = True
            elif parts[0].startswith("."):
                kinds["dot_folder"] = True
        self.assertEqual(kinds, {"file": True, "tilde_folder": True, "dot_folder": True})
        by_rule = sorted(rel for rel in files if any(p.startswith(("~", ".")) for p in rel.split("\\")))
        self.assertEqual(by_rule, sorted(SKIP_PATHS), "every file the rule skips is listed, and nothing else is")

    def test_the_skips_fixture_has_a_program_without_an_import_and_a_requirements_file(self):
        files = self.fx["scanFiles"]
        self.assertIn("main.py", files)
        self.assertNotRegex(files["main.py"], REAL_IMPORT)
        self.assertEqual(files["requirements.txt"], "pyvisa")

    def test_the_lookalike_fixture_holds_only_names_that_begin_like_the_package_and_none_of_them_is_one(self):
        files = self.fx["lookFiles"]
        self.assertEqual(files["requirements.txt"], "pyvisa")
        lookalikes = {rel: text for rel, text in files.items() if rel.endswith(".py") and rel != "main.py"}
        self.assertIn("lookalikes.py", lookalikes, "one lookalike sits next to run_setup.bat")
        self.assertTrue(any("\\" in rel for rel in lookalikes), "one lookalike sits in a subfolder")
        blob = "\n".join(lookalikes.values())
        for module in ("pyvista", "vision", "pyviscoelastic"):
            self.assertRegex(blob, r"(?m)^\s*(?:from|import)\s+%s\b" % module)
        for rel, text in files.items():
            self.assertNotRegex(text, REAL_IMPORT, rel)
        for rel, text in lookalikes.items():
            self.assertRegex(text, TRUNCATED_IMPORT, "a lookalike file must be one a prefix-only scan would take: " + rel)

    # --- the real scanner
    def test_the_real_scanner_names_the_deep_file_alone_and_answers_2(self):
        out, err = run_scanner(DETECT, self.skips_dir)
        self.assertEqual(out, "2")
        self.assertEqual(err, [FOUND % (WANT + " (subfolder)")])

    def test_the_real_scanner_names_no_lookalike_and_answers_0(self):
        out, err = run_scanner(DETECT, self.look_dir)
        self.assertEqual(out, "0")
        self.assertEqual(err, [])

    def test_the_judges_accept_what_the_real_scanner_wrote_and_the_batch_file_would_say(self):
        out, err = run_scanner(DETECT, self.skips_dir)
        self.assertEqual(self.judged("skips", "Get-ScanSkipsProblems", SetupText=text_of(err), ConsoleText=console_for(out), WantFile=WANT,
                                     NotFiles=SKIP_PATHS, MissingFiles=[]), [])
        out_look, err_look = run_scanner(DETECT, self.look_dir)
        self.assertEqual(self.judged("look", "Get-ScanLookalikeProblems", SetupText=text_of(err_look), ConsoleText=console_for(out_look),
                                     MissingFiles=[], ScanShownWorking=bool(err)), [])

    # --- a scanner with one rule broken is one the judges report
    def test_a_scanner_that_has_lost_one_of_the_skip_rules_or_the_walk_is_reported_with_the_file_named(self):
        for name, (old, new, needle) in SCANNER_BREAKS.items():
            with self.subTest(broken=name):
                out, err = run_scanner(self.broken_scanner(old, new), self.skips_dir)
                found = self.judged(name, "Get-ScanSkipsProblems", SetupText=text_of(err), ConsoleText=console_for(out), WantFile=WANT,
                                    NotFiles=SKIP_PATHS, MissingFiles=[])
                self.assertTrue(any(needle in f for f in found), (name, needle, found, err))

    def test_a_scanner_that_takes_a_prefix_for_the_package_is_reported_for_each_lookalike_file(self):
        old, new, needle = LOOKALIKE_BREAK
        out, err = run_scanner(self.broken_scanner(old, new), self.look_dir)
        self.assertEqual(out, "1", err)
        found = self.judged("look_broken", "Get-ScanLookalikeProblems", SetupText=text_of(err), ConsoleText=console_for(out), MissingFiles=[],
                            ScanShownWorking=True)
        self.assertGreaterEqual(len(err), 2, err)
        self.assertGreaterEqual(len([f for f in found if needle in f]), 2, found)
        self.assertTrue(any("the console says an import was detected" in f for f in found), found)

    def test_the_scanner_text_and_the_judges_agree_on_the_line_the_scanner_writes(self):
        self.assertIn("'[VISA] pyvisa/visa import found in: %s (%s)\\n' % (safe(rel), 'top folder' if top else 'subfolder')", self.detect)
        self.assertIn("if len(found) == 3:", self.detect)


# --- the script, the batch file, the workflow, the registry and the shall list ------------------------------------------------------

def script_problems(text):
    """The rules about tests/selfapps_pyvisa_subfolder.ps1 that keep the two rows honest."""
    t = norm(text)
    live = live_hash(t)
    flat = "\n".join(live)
    found = []
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    for row, req in ROWS:
        if ids.count(row) != 2:
            found.append("the row id %s must be a literal at exactly two Write-NdjsonRow call sites (the skip and its own), found %d" % (row, ids.count(row)))
        reqs = re.findall(r"id\s*=\s*'%s'[;\s]*req\s*=\s*'([^']*)'" % re.escape(row), t)
        if reqs != [req, req]:
            found.append("the row %s must be followed by the literal req tag %r at both sites, found %r" % (row, req, reqs))
    for row in OLDER_ROWS:
        if row not in ids:
            found.append("the older row %s is no longer written by the script" % row)
    if len(re.findall(r"\breq\s*=\s*'", t)) != len(re.findall(r"\breq\s*=\s*'", flat)):
        found.append("a comment holds the shape req = '...', which the requirement-trace tests would count as a tag")
    for need in NEED_LINES:
        if need not in flat:
            found.append("the script no longer holds: %s" % need)
    if not re.search(r"pass\s*=\s*\$scanPass", flat):
        found.append("the row %s no longer writes pass = $scanPass" % SKIPS_ROW)
    if not re.search(r"pass\s*=\s*\$lookPass", flat):
        found.append("the row %s no longer writes pass = $lookPass" % LOOK_ROW)
    names = re.search(r"\$names = @\(([^)]*)\)", t)
    for var in ("HP_SKIP_ENTRY_SMOKE", "HP_SKIP_EXE_SMOKERUN", "HP_SKIP_NIVISA", "HP_TEST_VISA_ANSWER"):
        if not names or "'%s'" % var not in names.group(1):
            found.append("the variables a scenario clears before it runs no longer include %s, so an earlier scenario's value could leak" % var)
    order = [t.find("Invoke-VisaScenario -Name '%s'" % name) for name in ("scanskips", "lookalike", "accepted")]
    if min(order) < 0 or order != sorted(order):
        found.append("the two scan scenarios must run before the accepted one (it may really install the driver); found at %r" % order)
    env_line = next((ln for ln in live if ln.startswith("$scanEnv = ")), "")
    if "HP_TEST_VISA_ANSWER" in env_line or "HP_CI_LANE" in env_line:
        found.append("the scan scenarios must not set an answer or a lane, only the three variables that stop the run before the install")
    for name in JUDGES + ["Invoke-VisaScenario"]:
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the function %s is missing" % name)
    if "exit 1" not in flat or not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0 after an exit 1 for a red row")
    if any(ord(ch) > 127 for ch in text):
        found.append("the script holds a character that is not ASCII")
    return found


def batch_problems(batch, detect):
    """The texts the judges read are live lines of the batch file (each exactly once), and the hooks the scenarios set are read by it."""
    found = []
    live = [ln.strip() for ln in live_bat(batch.replace("\r\n", "\n").split("\n"))]
    for text in LOG_TEXTS:
        line = 'call :log "%s"' % text
        n = sum(1 for ln in live if line in ln)
        if n != 1:
            found.append("the log text %r is written by %d live call :log line(s), the judges expect 1" % (text, n))
    for name in ("HP_SKIP_NIVISA", "HP_SKIP_ENTRY_SMOKE", "HP_SKIP_EXE_SMOKERUN"):
        if not any(name in ln for ln in live):
            found.append("no live line of run_setup.bat reads %s" % name)
    if "'[VISA] pyvisa/visa import found in: %s (%s)\\n'" not in detect:
        found.append("tools/detect_visa.py no longer writes the line the judges read")
    return found


def workflow_problems(text):
    flat = norm(text)
    return ["the artifact upload does not list %s" % pattern for pattern in UPLOADS if pattern not in flat]


def registry_problems(text):
    have = registry_ids(text)
    return ["%s is not in docs/agent-ndjson.md" % row for row, _ in ROWS if row not in have]


def shall_list_problems(text):
    return ["%s is still listed in UNTRACED_SHALLS although a row is tagged with it" % shall
            for shall in GAP_SHALLS if re.search(r'^\s*"%s":' % re.escape(shall), text, re.M)]


class RealFiles(unittest.TestCase):
    def setUp(self):
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.detect = DETECT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_script_has_its_two_rows_its_scenarios_its_judges_and_its_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_texts_the_judges_read_are_live_lines_of_the_batch_file_and_the_scanner(self):
        self.assertEqual(batch_problems(self.batch, self.detect), [])

    def test_the_uploads_name_the_two_scenario_logs(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shalls_are_no_longer_listed_as_unit_only(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        # the counts are written out: a case that is dropped from a table must be dropped here too, on purpose
        names = [c["name"] for c in judge_cases()]
        self.assertEqual(len(names), 8 + 9 + 14 + 12)
        self.assertEqual(len(set(names)), len(names), "case names are unique")
        self.assertEqual(len(SKIPS_ONE), 11)
        self.assertEqual(len(LOOK_ONE), 9)
        self.assertEqual(len(UPLOADS), 8)
        self.assertEqual(len(NEED_LINES), 13)
        for name in list(SKIPS_ONE) + list(LOOK_ONE):
            self.assertIn(name, names, "every sentence of a table has a case that produces it")

    def test_every_judge_is_a_function_of_the_script(self):
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the batch file, the workflow, the registry and the shall list is shown to fail on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.detect = DETECT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def has(self, found, needle):
        self.assertTrue(any(needle in f for f in found), (needle, found))

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "    id      = 'self.nivisa.scan.skips'", "    id      = $rowId")
        self.has(script_problems(bad), "self.nivisa.scan.skips must be a literal")
        bad = mutate(self.script, "    id      = 'self.nivisa.scan.lookalike'", "    id      = $rowId")
        self.has(script_problems(bad), "self.nivisa.scan.lookalike must be a literal")

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "    req     = 'REQ-008.5'", "    req     = 'REQ-008'")
        self.has(script_problems(bad), "literal req tag 'REQ-008.5'")
        bad = mutate(self.script, "    req     = 'REQ-008.6'", "    req     = 'REQ-008'")
        self.has(script_problems(bad), "literal req tag 'REQ-008.6'")

    def test_a_comment_that_holds_the_shape_of_a_tag_is_caught(self):
        bad = self.script.replace("# Emits:", "# req = 'REQ-008.5' is a tag shape\n# Emits:", 1)
        self.has(script_problems(bad), "a comment holds the shape req")

    def test_an_older_row_that_the_script_stops_writing_is_caught(self):
        bad = self.script.replace("self.nivisa.topfolder.noprompt", "self.nivisa.topfolder.other")
        self.has(script_problems(bad), "self.nivisa.topfolder.noprompt is no longer written")

    def test_a_changed_hand_over_or_a_changed_variable_set_is_caught(self):
        for old, new in (("-WantFile $deepFile", "-WantFile 'x.py'"),
                         ("-NotFiles $skipPaths", "-NotFiles @()"),
                         ("-ScanShownWorking $scanWorked", "-ScanShownWorking $true"),
                         ("-EnvSet $scanEnv\n$skMissing", "-EnvSet @{}\n$skMissing"),
                         ("$lk = Invoke-VisaScenario -Name 'lookalike' -Files $lookFiles -EnvSet $scanEnv",
                          "$lk = Invoke-VisaScenario -Name 'lookalike' -Files $lookFiles -EnvSet @{}"),
                         ("HP_SKIP_NIVISA = '1'; HP_SKIP_ENTRY_SMOKE", "HP_SKIP_ENTRY_SMOKE"),
                         ("HP_SKIP_EXE_SMOKERUN = '1' }\n$deepFile", "HP_TEST_VISA_ANSWER = 'Y' }\n$deepFile")):
            with self.subTest(old=old):
                self.has(script_problems(mutate(self.script, old, new)), "the script no longer holds")

    def test_a_verdict_that_stops_deciding_the_row_or_the_exit_code_is_caught(self):
        bad = mutate(self.script, "    pass    = $scanPass", "    pass    = $true")
        self.has(script_problems(bad), "no longer writes pass = $scanPass")
        bad = mutate(self.script, "    pass    = $lookPass", "    pass    = $true")
        self.has(script_problems(bad), "no longer writes pass = $lookPass")
        bad = mutate(self.script, "if (-not ($scanPass -and $lookPass)) { exit 1 }\n", "")
        self.has(script_problems(bad), "the script no longer holds: if (-not ($scanPass -and $lookPass)) { exit 1 }")
        bad = mutate(self.script, "$pyPass)) { exit 1 }\nexit 0\n", "$pyPass)) { exit 1 }\n")
        self.has(script_problems(bad), "does not end with exit 0")

    def test_scenarios_that_do_not_clear_what_they_must_or_run_after_the_accepted_one_are_caught(self):
        bad = mutate(self.script, "'HP_SKIP_ENTRY_SMOKE', 'HP_SKIP_EXE_SMOKERUN')", "'HP_SKIP_ENTRY_SMOKE')")
        self.has(script_problems(bad), "no longer include HP_SKIP_EXE_SMOKERUN")
        bad = mutate(self.script, "'HP_SKIP_NIVISA', ", "")
        self.has(script_problems(bad), "no longer include HP_SKIP_NIVISA")
        # an accepted scenario that starts before the scan scenarios, and a scan scenario that is gone
        bad = mutate(self.script, "$sk = Invoke-VisaScenario -Name 'scanskips'",
                     "$early = Invoke-VisaScenario -Name 'accepted' -Files $subFiles -EnvSet @{}\n$sk = Invoke-VisaScenario -Name 'scanskips'")
        self.has(script_problems(bad), "must run before the accepted one")
        bad = mutate(self.script, "-Name 'lookalike'", "-Name 'lookalikes'")
        self.has(script_problems(bad), "must run before the accepted one")

    def test_a_scan_scenario_that_sets_an_answer_is_caught(self):
        bad = mutate(self.script, SCAN_ENV_LINE, "$scanEnv = @{ HP_SKIP_NIVISA = '1'; HP_SKIP_ENTRY_SMOKE = '1'; HP_SKIP_EXE_SMOKERUN = '1'; HP_TEST_VISA_ANSWER = 'Y' }")
        self.has(script_problems(bad), "must not set an answer or a lane")

    def test_a_judge_that_is_missing_is_caught(self):
        for name in JUDGES:
            with self.subTest(judge=name):
                bad = mutate(self.script, "function %s {" % name, "function %sX {" % name)
                self.has(script_problems(bad), "the function %s is missing" % name)

    def test_a_non_ascii_character_is_caught(self):
        self.has(script_problems(self.script + "\n# caf" + chr(233) + "\n"), "ASCII")

    def test_a_reworded_log_text_a_second_writer_or_a_lost_hook_is_caught(self):
        for text in LOG_TEXTS:
            with self.subTest(text=text):
                bad = self.batch.replace('call :log "%s"' % text, 'call :log "%sx"' % text)
                self.assertNotEqual(bad, self.batch)
                self.has(batch_problems(bad, self.detect), "the log text %r is written by 0" % text)
                twice = self.batch.replace('call :log "%s"' % text, 'call :log "%s"\r\ncall :log "%s"' % (text, text), 1)
                self.has(batch_problems(twice, self.detect), "the log text %r is written by 2" % text)
        for name in ("HP_SKIP_NIVISA", "HP_SKIP_ENTRY_SMOKE", "HP_SKIP_EXE_SMOKERUN"):
            with self.subTest(hook=name):
                stripped = "\n".join(ln for ln in norm(self.batch).split("\n") if name not in ln or ln.strip().lower().startswith("rem"))
                self.has(batch_problems(stripped, self.detect), "no live line of run_setup.bat reads %s" % name)

    def test_a_scanner_line_that_changed_is_caught(self):
        bad = mutate(self.detect, "'[VISA] pyvisa/visa import found in: %s (%s)\\n'", "'[VISA] import found in: %s (%s)\\n'")
        self.has(batch_problems(self.batch, bad), "no longer writes the line the judges read")

    def test_a_missing_upload_is_caught(self):
        for pattern in UPLOADS:
            with self.subTest(pattern=pattern):
                self.has(workflow_problems(self.workflow.replace(pattern, "")), pattern)

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        for row, _ in ROWS:
            with self.subTest(row=row):
                self.assertTrue(registry_problems(text.replace(row, row + "x")))
        self.assertTrue(registry_problems("```\nself.nivisa.scan.skips\n```\nprose: self.nivisa.scan.lookalike\n"))

    def test_a_shall_that_is_still_listed_as_unit_only_is_caught(self):
        self.assertTrue(shall_list_problems('    "REQ-008.5": "unit: x",\n'))
        self.assertTrue(shall_list_problems('    "REQ-008.6": "unit: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-008.50": "gap: x",\n    "REQ-008.60": "gap: y",\n'), [])


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesCanFail(unittest.TestCase):
    """A judge that quietly stops judging would pass every scenario, so the cases are run against mutated copies of the script: each
    comparison replaced by $false must remove the sentence of the case that depends on it, and each pattern that is changed must make
    the case that depends on it come out differently."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.base = run_cases(SCRIPT, JUDGES, judge_cases(), d)

    def mutated_run(self, old, new, names):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "mutated.ps1"
            path.write_text(text.replace(old, new), encoding="utf-8")
            wanted = [cs for cs in judge_cases() if cs["name"] in names]
            return run_cases(path, JUDGES, wanted, d)

    def silenced(self, comparison, name, needle):
        """Replacing `if (<comparison>) {` by `if ($false) {` must remove the sentence `needle` from the answer for case `name`."""
        self.assertTrue(any(needle in f for f in self.base[name]), (name, needle, self.base[name]))
        got = self.mutated_run("if (" + comparison + ") {", "if ($false) {", [name])
        self.assertFalse(any(needle in f for f in got[name]), (name, needle, got[name]))

    def changes(self, old, new, names):
        got = self.mutated_run(old, new, names)
        for name in names:
            self.assertNotEqual(got[name], self.base[name], (old, new, name))

    def test_the_comparisons_of_the_skips_judge_each_matter(self):
        for comparison, name, needle in (
            ("-not ($found -ccontains $wantLine)", "sk_deep_file_not_named", "the scan did not name"),
            ("$f.StartsWith($printed + ' (', [System.StringComparison]::Ordinal)", "sk_took_tilde_file", "the scan took ~scratch.py for an import"),
            ("-not $known", "sk_unplanted_file", "nobody planted"),
            ("$nOnly -ne 1", "sk_console_only_line_missing", "expected 1"),
            ("(Get-VisaLineCount -Text $ConsoleText -Line $top) -gt 0", "sk_console_top_line", "next to run_setup.bat"),
            ("(Get-VisaLineCount -Text $ConsoleText -Line $none) -gt 0", "sk_console_none_line", "no import was detected"),
            ("$nDisabled -ne 1", "sk_not_disabled", "precondition: the console shows"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_the_comparisons_of_the_lookalike_judge_each_matter(self):
        for comparison, name, needle in (
            ("-not $ScanShownWorking", "lk_scan_not_shown_working", "did not name its file"),
            ("$nNone -ne 1", "lk_console_none_missing", "expected 1"),
            ("(Get-VisaLineCount -Text $ConsoleText -Line $text) -gt 0", "lk_console_detected_top", "an import was detected"),
            ("$nReq -ne 1", "lk_not_required_missing", "not_required"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_the_precondition_of_a_fixture_file_that_went_missing_matters_in_both_judges(self):
        self.changes('[void]$problems.Add("precondition: the folder of the run no longer holds $m, so the scan had nothing to read or to skip")',
                     "$null = $m", ["sk_missing_fixture_file"])
        self.changes('[void]$problems.Add("precondition: the folder of the run no longer holds $m, so the scan had nothing to read")',
                     "$null = $m", ["lk_missing_fixture_file"])

    def test_every_pattern_of_the_scanner_line_and_the_counter_matters(self):
        for old, new, names in (
            ("(top folder|subfolder)", "(top folder)", ["found_two", "sk_good"]),
            ("$l = $raw.TrimEnd()\n        if ($l -match", "$l = $raw\n        if ($l -match", ["found_trailing_spaces"]),
            ("$out.Add($Matches[1] + ' (' + $Matches[2] + ')')", "$out.Add($Matches[1])", ["found_two", "sk_good"]),
            ("-or ($l.Substring($l.Length - $Line.Length - 1, 1) -eq ' ')", "-or $true", ["count_glued_to_a_word"]),
            ("[System.StringComparison]::Ordinal)) { continue }", "[System.StringComparison]::OrdinalIgnoreCase)) { continue }", ["count_case_matters"]),
            ("$l = $raw.TrimEnd()\n        if (-not $l.EndsWith", "$l = $raw\n        if (-not $l.EndsWith", ["count_trailing_spaces_trimmed"]),
            ("[regex]::Replace($n, '[^A-Za-z0-9._\\- \\\\]', '_')", "$n", ["sk_took_tilde_file", "sk_took_tilde_folder"]),
        ):
            with self.subTest(old=old):
                self.changes(old, new, names)


if __name__ == "__main__":
    unittest.main()
