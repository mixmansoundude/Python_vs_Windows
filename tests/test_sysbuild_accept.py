"""Item 123 (README REQ-007.17 and REQ-007.20): the answer Y to the system-Python build question builds the EXE, and every message
about it says EXE or names the tool.

REQ-007.17 says that when the user agrees to the build question under REQ-007.16 the bootstrapper builds the EXE as it does for every
other provider; REQ-007.20 says that every message about the build, the check run of the executable or its failure names the artifact
and the tool in plain words, so a reader can tell it is about the optional one-file program and not about the environment, which is
already installed. Until this item the README said that no scenario answered yes to the build question and that no check read every
message, and the existing rows of tests/selfapps_sysbuild.ps1 answer N or let the CI marker decline.

tests/selfapps_sysbuild_accept.ps1 (rows self.sysbuild.accept and self.sysbuild.wording; contract-uv lane, gating) bootstraps one folder
for real with a private virtual environment as the system Python (its Scripts folder first on PATH), every other tier failed by decree
and the answers Y to both questions, and judges the console twice: the sequence of the accepted build, and, through tools/exe_wording.py
`console`, the wording of every log line of that run. tests/test_exe_wording.py holds every message of run_setup.bat to the wording rule
without running anything.

What really happens is shown on Windows by that script. These rules read run_setup.bat, the script, batch-check.yml,
docs/agent-ndjson.md and tests/test_req_shall_trace.py as text and run the script's own judging functions through a real pwsh on
synthetic runs (a run that passes, and one run for each way to be wrong), so a reworded log line, a consent gate that moved behind
the CI marker, a scenario that stops answering Y, a judge that stops judging, a floor that was lowered or a step that stops gating
fails here with a sentence, before a Windows run is needed. Synthetic cases prove each rule can fail. The shared helpers are in
tests/judge_support.py.
"""
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import (PWSH, after, case, drop, lines_of, live_bat, live_hash, mutate, norm, registry_ids,  # noqa: E402
                           run_cases, step_block, swap, text_of)

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_sysbuild_accept.ps1"
TOOL = REPO / "tools" / "exe_wording.py"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
SCRIPT_NAME = "selfapps_sysbuild_accept.ps1"

ROW_REQS = {"self.sysbuild.accept": "REQ-007.17", "self.sysbuild.wording": "REQ-007.20"}
ROW_IDS = tuple(ROW_REQS)
GAP_SHALLS = ("REQ-007.17", "REQ-007.20")

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~sysbuild_accept_evidence.txt",
    "tests/~selftest_sysbuild_accept/~sysbuild_accept.log",
    "tests/~selftest_sysbuild_accept/~setup.log",
    "tests/~selftest_sysbuild_accept/~bootstrap.status.json",
    "tests/~selftest_sysbuild_accept/~wording_judge.err.txt",
)
JUDGES = ["Find-ConsoleLine", "Measure-ConsoleLines", "Get-AcceptProblems", "Get-WordingProblems"]
# about two thirds of the first real run (48 timestamped lines, 9 about the build, 7 naming the EXE, 2 exempt, run 43740185058 after the rewording)
FLOORS = {"minTimestamped": 30, "minTriggered": 6, "minNamed": 4, "minExempt": 1}

# The console lines of the accepted build, in the order the run must show them: (key, label the judge prints, text of the line,
# whether the line must be there exactly once). The texts are the live `call :log` lines of run_setup.bat.
EXE = "_selftest_sysbuild_accept.exe"
LEAF = "~selftest_sysbuild_accept_venv"
PROGRAM = "sysbuild-accept-app-line-7731"
STEPS = (
    ("tried", "the system tier was tried", "[WARN] Attempting system Python fallback (degraded)...", True),
    ("consent", "the REQ-014 consent was accepted", "[INFO] REQ-014: System Python consent: user accepted.", True),
    ("selected", "the system tier was selected", "[INFO] System fallback using ", True),
    ("provider", "the provider line says System Python", "[BOOT] REQ-009: Selected Python provider: System Python (degraded).", True),
    ("buildconsent", "the REQ-007 build consent was accepted", "[INFO] REQ-007: system-Python EXE build consent: accepted.", True),
    ("building", "the build started", "[INFO] Building standalone executable -- this may take a minute or two...", True),
    ("produced", "PyInstaller produced the EXE", "[INFO] PyInstaller produced dist\\" + EXE, True),
    ("checkexe", "the check run went through the packaged EXE", "[INFO] Running entry script smoke test via packaged EXE.", True),
    ("exit0", "the check run exited 0", "[INFO] Entry smoke exit=0", False),
    ("success", "the check run reported success", "[STATUS] Run Status: SUCCESS (Exit Code: 0)", False),
)
# The lines of the declined path, which the accepted run must not show: (label the judge prints, text).
NEVER = (
    ("the build consent was declined", "system-Python EXE build consent: declined."),
    ("the build was skipped as not consented", "system-Python EXE build not consented"),
    ("the program was only checked through the interpreter", "Running entry script smoke test via system interpreter."),
    ("the check run failed", "[STATUS] Run Status: FAILED"),
    ("the panel is the caveat panel", "SETUP COMPLETE -- WITH A CAVEAT"),
)

# The `call :log` texts of the accepted path as the batch file spells them, each of which must be in exactly one live line. Two differ from
# the console: the interpreter path is a variable (the line stops at the space before it) and so is the name of the EXE. The line that
# holds the exit code of the check run is pinned as a whole line (three other lines print an exit code of another run).
BATCH_LOG_TEXTS = (
    "[WARN] Attempting system Python fallback (degraded)...",
    "[INFO] REQ-014: System Python consent: user accepted.",
    "[INFO] System fallback using ",
    "[BOOT] REQ-009: Selected Python provider: System Python (degraded).",
    "[INFO] REQ-007: system-Python EXE build consent: accepted.",
    "[INFO] Building standalone executable -- this may take a minute or two...",
    "[INFO] PyInstaller produced dist\\%ENVNAME%.exe",
    "[INFO] Running entry script smoke test via packaged EXE.",
)
# The one text of the declined path that the batch file spells with a variable.
IN_BATCH = {"Running entry script smoke test via system interpreter.": "Running entry script smoke test via %HP_ENV_MODE% interpreter."}
# What the script holds as a quoted literal for a console text that ends in the name of the EXE: the part before the name.
ENDS_IN_EXE_NAME = "[INFO] PyInstaller produced dist\\"
EXIT_LINE = 'call :log "[INFO] Entry smoke exit=%HP_EXE_EXIT%"'
SUCCESS_PAIR = ('if "%HP_EXE_EXIT%"=="0" (', 'call :log "[STATUS] Run Status: SUCCESS (Exit Code: 0)"')
READY_PAIR = ("echo Your standalone application is ready:", "echo dist\\%ENVNAME%.exe")


# --- the batch file: what the script assumes about the path it runs ------------------------------------------------------------

def batch_problems(batch, script_text):
    """README REQ-007.16, REQ-007.17 and REQ-014 in the batch file: both consent gates take the test answer before the CI marker, an
    accepted build consent returns at once, every log text of the accepted path is in exactly one live line, the texts of the declined
    path still exist (so their absence proves something), the panel names the EXE on the line under the ready line, and the system
    tier ends in the state the script reads."""
    found = []
    live = [ln.strip() for ln in live_bat(lines_of(batch))]
    squashed = [" ".join(ln.split()) for ln in live]

    def count(text):
        return sum(1 for ln in live if ln == text)

    def log_hits(text):
        return [ln for ln in live if ln.startswith("call :log ") and text in ln]

    for text in BATCH_LOG_TEXTS:
        n = len(log_hits(text))
        if n != 1:
            found.append("the text '%s' must be in exactly one live call :log line of the batch file, found %d" % (text, n))
    if count(EXIT_LINE) != 1:
        found.append("the line %s must exist exactly once, found %d" % (EXIT_LINE, count(EXIT_LINE)))
    pairs = [i for i in range(len(live) - 1) if live[i] == SUCCESS_PAIR[0] and live[i + 1] == SUCCESS_PAIR[1]]
    if len(pairs) != 1:
        found.append("the success line of the check run must follow %s directly, found %d such pair(s)" % (SUCCESS_PAIR[0], len(pairs)))
    elif EXIT_LINE in live and live.index(EXIT_LINE) > pairs[0]:
        found.append("the line of the exit code of the check run must come before its success line")
    # the declined path's texts exist, or the judge's check that they are absent from the accepted console proves nothing; the
    # interpreter line is the one the batch file spells with a variable and it exists exactly once
    for label, text in NEVER:
        spelled = IN_BATCH.get(text, text)
        hits = [ln for ln in live if spelled in ln and (ln.startswith("call :log ") or ln.startswith("echo "))]
        if not hits:
            found.append("the text '%s' (%s) is no longer in a live call :log or echo line, so the judge's check that it is absent proves nothing" % (spelled, label))
        elif text in IN_BATCH and len(hits) != 1:
            found.append("the interpreter check line '%s' must exist exactly once, found %d" % (spelled, len(hits)))

    # the script looks for every text it judges, as a quoted literal (the name of the EXE is appended to the one that ends in it)
    flat = norm(script_text)
    for text in tuple(t for _, _, t, _ in STEPS) + tuple(t for _, t in NEVER):
        literal = ENDS_IN_EXE_NAME if text.startswith(ENDS_IN_EXE_NAME) else text
        if "'" + literal not in flat:
            found.append("the script no longer looks for the text '%s'" % literal)

    # the two gates: the test answer is tested before the CI marker, or the CI marker declines the build the row asks for
    for answer, marker, choice in (("if defined HP_TEST_SYSBUILD_ANSWER (", ") else if defined HP_CI_LANE (", 'if /I "%HP_SYSBUILD_CHOICE%"=="Y" ('),
                                   ("if defined HP_TEST_SYSCON_ANSWER (", ") else if defined HP_CI_LANE (", 'if /I "%HP_SYSCON_CHOICE:~0,1%"=="y" (')):
        at = [i for i, ln in enumerate(live) if ln == answer]
        if len(at) != 1:
            found.append("the line %s must exist exactly once, found %d" % (answer, len(at)))
            continue
        nxt = live[at[0] + 1:at[0] + 3]
        if len(nxt) < 2 or not nxt[0].startswith("set ") or nxt[1] != marker:
            found.append("after %s the gate must set the answer and then test the CI marker (%s); found %r" % (answer, marker, nxt))
        if count(choice) != 1:
            found.append("the line %s must exist exactly once, found %d" % (choice, count(choice)))
        else:
            following = live[live.index(choice) + 1:live.index(choice) + 3]
            if len(following) < 2 or not following[0].startswith("call :log ") or following[1] != "exit /b 0":
                found.append("after %s the gate must log the acceptance and exit /b 0 at once; found %r" % (choice, following))
    # the accepted question of the build gate is Y exactly: a default of Y would accept in every CI lane
    if 'set "HP_SYSBUILD_RAW=n"' not in live:
        found.append('the CI marker no longer answers n to the build question (set "HP_SYSBUILD_RAW=n")')

    # the panel
    ready = [i for i, ln in enumerate(squashed) if ln == READY_PAIR[0]]
    if len(ready) != 1:
        found.append("the panel line %r must exist exactly once, found %d" % (READY_PAIR[0], len(ready)))
    elif squashed[ready[0] + 1:ready[0] + 2] != [READY_PAIR[1]]:
        found.append("the line under %r must be %r, found %r" % (READY_PAIR[0], READY_PAIR[1], squashed[ready[0] + 1:ready[0] + 2]))

    # the system tier and its state
    if count('set "HP_BOOTSTRAP_STATE=degraded_env"') != 1:
        found.append('the system tier must set HP_BOOTSTRAP_STATE=degraded_env on exactly one line, found %d' % count('set "HP_BOOTSTRAP_STATE=degraded_env"'))
    if count('where python >nul 2>&1 && set "HP_SYS_CMD=python"') != 1:
        found.append("the system interpreter is no longer found by where python, which the private interpreter of the run relies on")
    if count('"%HP_SYS_CMD%" -c "import sys;print(sys.executable)" > "%HP_SYS_TMP%" 2>nul') != 1:
        found.append("the system interpreter is no longer taken from sys.executable, which the row reads on the console line System fallback using")
    if count('if "%HP_TEST_FORCE_CONDA_FAIL%"=="1" goto :hp_test_conda_fail') != 1:
        found.append("the conda tier no longer fails by HP_TEST_FORCE_CONDA_FAIL on one line")
    if count('if "%HP_TEST_FORCE_VENV_FAIL%"=="1" (') != 1:
        found.append("the venv tier no longer fails by HP_TEST_FORCE_VENV_FAIL on one line")
    if count('"%HP_PY%" -m pip install -q pyinstaller >> "%LOG%" 2>&1') != 1:
        found.append("PyInstaller is no longer installed by exactly one pip line that the system tier reaches")
    derive = [ln for ln in live if "-replace '[^A-Za-z0-9_-]', '_'" in ln]
    if len(derive) != 1:
        found.append("the name of the EXE is no longer derived from the folder name by exactly one live line, found %d" % len(derive))
    return found


# --- the script ----------------------------------------------------------------------------------------------------------------

def script_problems(text):
    t = norm(text)
    live = live_hash(t)
    flat = "\n".join(live)
    joined = re.sub(r"\s*`\n\s*", " ", flat)
    compact = re.sub(r"[ \t]+", " ", joined)
    found = []
    pairs = re.findall(r"\bid = '(self\.sysbuild\.[a-z]+)'; req = '([^']*)'", t)
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if sorted(ids) != sorted(list(ROW_IDS) * 2):
        found.append("each row id must be a literal at exactly two Write-NdjsonRow call sites (the shared one and its own), found %r" % ids)
    if sorted(p[0] for p in pairs) != sorted(list(ROW_IDS) * 2):
        found.append("every row id must be followed by its literal req tag, found %r" % pairs)
    for rid, req in pairs:
        if req != ROW_REQS.get(rid):
            found.append("the row %s must carry the literal req tag %r, found %r" % (rid, ROW_REQS.get(rid), req))
    for need in ("$appName = '~selftest_sysbuild_accept'", "$venvName = '~selftest_sysbuild_accept_venv'", "$programLine = 'sysbuild-accept-app-line-7731'",
                 "$consoleName = '~sysbuild_accept.log'", "$exeName = ($appName -replace '[^A-Za-z0-9_-]', '_') + '.exe'"):
        if need not in compact:
            found.append("the script no longer holds %s" % need)
    if "& $basePython -m venv $venvDir" not in compact:
        found.append("the private interpreter is no longer made by python -m venv")
    # the launch file: the runner's own settings are cleared first, then only the settings of this scenario are made
    clear = compact.find("foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }")
    first_set = compact.find("'set \"HP_OFFLINE_MODE=1\"'")
    if clear < 0:
        found.append("the run no longer clears every HP_ and PVW_ variable of the runner first")
    elif first_set >= 0 and clear > first_set:
        found.append("the variables of the runner are cleared after the run's own are set, so the clear would remove them")
    for name in ("HP_OFFLINE_MODE=1", "HP_TEST_FORCE_CONDA_FAIL=1", "HP_TEST_FORCE_VENV_FAIL=1", "HP_TEST_SYSCON_ANSWER=Y", "HP_TEST_SYSBUILD_ANSWER=Y"):
        if "'set \"%s\"'" % name not in compact:
            found.append("the run no longer sets %s" % name)
    if "HP_TEST_SYSBUILD_ANSWER=N" in compact:
        found.append("the run answers N to the build question, which is the declined scenario of tests/selfapps_sysbuild.ps1 and not this one")
    if "('set \"HP_CI_LANE=' + $ciLaneValue + '\"')" not in compact:
        found.append("the run no longer sets HP_CI_LANE, so the elective offers after the build would wait for an answer")
    if "('set \"PATH=' + (Join-Path $venvDir 'Scripts') + ';%PATH%\"')" not in compact:
        found.append("the run no longer puts the private interpreter first on PATH, so it would not be the system Python of the run")
    if "('call run_setup.bat > ' + $consoleName + ' 2>&1 < nul')" not in compact:
        found.append("the bootstrap no longer runs with standard input closed (< nul) and its console in the log the judges read")
    # the numbers end at a digit boundary: -LimitMs 9000000 is a different limit and must not pass as 900000
    for pattern, shown in ((r"-LimitMs 900000(?!\d)", "-LimitMs 900000"), (r"-LimitMs 60000(?!\d)", "-LimitMs 60000")):
        if not re.search(pattern, compact):
            found.append("a run that outlives its limit is no longer stopped at the limit: %s is missing" % shown)
    if len(re.findall(r"taskkill\.exe /F /T /PID \$p\.Id", compact)) < 2:
        found.append("a run that outlives its limit is no longer stopped with its whole process tree: taskkill.exe /F /T /PID $p.Id must be in both helpers")
    # the floors that stop the wording row from passing on a console that never reached the build
    for name, floor in FLOORS.items():
        m = re.search(r"\$%s\s*=\s*(\d+)" % name, compact)
        if not m:
            found.append("the floor $%s is missing" % name)
        elif int(m.group(1)) < floor:
            found.append("the floor $%s is %s; it must stay at %d or more, the least a run that reached the build shows" % (name, m.group(1), floor))
    # the verdicts hand each judge what it needs
    call = "$acceptProblems = @(Get-AcceptProblems"
    if call not in compact:
        found.append("the run is no longer judged by Get-AcceptProblems")
    else:
        args = compact.split(call, 1)[1].split("\n", 1)[0]
        for need in ("-Finished ([bool]$launch.Finished)", "-ExitText $exitText", "-ConsoleText $console", "-StatusText $statusTxt", "-RunOutText $runOut",
                     "-VenvLeaf $venvName", "-ExeName $exeName", "-ProgramLine $programLine", "-ExeExists ([bool]$exeExists)",
                     "-DirectFinished ([bool]$direct.Finished)", "-DirectExitText ([string]$direct.ExitCode)", "-DirectOutText $directOut"):
            if need not in args:
                found.append("the verdict no longer hands %s to Get-AcceptProblems" % need)
    call = "$wordingProblems = @(Get-WordingProblems"
    if call not in compact:
        found.append("the console is no longer judged by Get-WordingProblems")
    else:
        args = compact.split(call, 1)[1].split("\n", 1)[0]
        for need in ("-JudgeRan ([bool]$judgeRan)", "-JudgeError $judgeError", "-JudgeExit ([int]$judgeExit)", "-JsonText $judgeJson",
                     "-MinTimestamped $minTimestamped", "-MinTriggered $minTriggered", "-MinNamed $minNamed", "-MinExempt $minExempt"):
            if need not in args:
                found.append("the verdict no longer hands %s to Get-WordingProblems" % need)
    if "$toolPath = Join-Path $repo 'tools\\exe_wording.py'" not in compact:
        found.append("the wording judge is no longer tools\\exe_wording.py")
    if "& $basePython -I $toolPath console --file $consolePath" not in compact:
        found.append("the wording judge no longer reads the console of the run with exe_wording.py console --file")
    for var in ("acceptProblems", "wordingProblems"):
        if "$pass = [bool](@($%s).Count -eq 0)" % var not in compact:
            found.append("the row of %s is no longer judged by its list of problems" % var)
    if compact.count("pass = $pass") < 2:
        found.append("the two rows no longer write pass = $pass")
    for name in JUDGES:
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the judging function %s is missing" % name)
    if "OSVersion.Platform -ne [System.PlatformID]::Win32NT" not in compact or re.search(r"\$IsWindows\b", compact):
        found.append("the Windows check must use OSVersion.Platform and not $IsWindows")
    if "skip = $true" not in compact:
        found.append("the rows no longer skip off Windows with skip = $true")
    if "if (-not $allPass) { exit 1 }" not in compact:
        found.append("the script no longer exits 1 for a red row")
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0")
    if any(ord(ch) > 127 for ch in text):
        found.append("the script holds a character that is not ASCII")
    return found


# --- the workflow, the registry and the shall list ------------------------------------------------------------------------------

def workflow_problems(text):
    block = step_block(text, SCRIPT_NAME)
    if block is None:
        return ["no step runs tests\\%s" % SCRIPT_NAME]
    found = []
    if STEP_IF not in block and "matrix.mode == 'contract-uv' && !cancelled()" not in block:
        found.append("the step is not limited to the contract-uv lane with !cancelled()")
    if "shell: pwsh" not in block:
        found.append("the step does not use shell: pwsh")
    if "continue-on-error" in block:
        found.append("the step has continue-on-error, so it cannot hold a pull request")
    flat = norm(text)
    for pattern in UPLOADS:
        if pattern not in flat:
            found.append("the artifact upload does not list %s" % pattern)
    return found


def registry_problems(text):
    have = registry_ids(text)
    return ["%s is not in docs/agent-ndjson.md" % row for row in ROW_IDS if row not in have]


def shall_list_problems(text):
    """The shalls the rows trace are no longer listed as gaps (the shall-level ratchet only warns about a stale entry)."""
    return ["%s is still listed in UNTRACED_SHALLS although a row is tagged with it" % shall
            for shall in GAP_SHALLS if re.search(r'^\s*"%s":' % re.escape(shall), text, re.M)]


# --- the script's judging functions, run through a real pwsh ---------------------------------------------------------------------

STAMP = "Sat 11/14/2026  9:05:03.10 "
STATUS = '{"state":"degraded_env","exitCode":0,"pyFiles":1}'
LINES = {key: STAMP + text for key, _, text, _ in STEPS}
LINES["selected"] = STAMP + "[INFO] System fallback using C:\\w\\" + LEAF + "\\Scripts\\python.exe"
READY = " Your standalone application is ready:"
UNDER = "   dist\\" + EXE

GOOD_CONSOLE = [
    STAMP + "[INFO] Python file count: 1",
    LINES["tried"],
    "*** WARNING: System Python Execution ***",
    LINES["consent"],
    LINES["selected"],
    LINES["provider"],
    "*** The standalone EXE build installs PyInstaller into your system Python. ***",
    LINES["buildconsent"],
    LINES["building"],
    LINES["produced"],
    LINES["checkexe"],
    PROGRAM,
    LINES["exit0"],
    LINES["success"],
    "",
    "============================================================",
    " SETUP COMPLETE",
    "============================================================",
    READY,
    UNDER,
    "",
]


def accept_args(console=None, **over):
    args = dict(Finished=True, ExitText="0\r\n", ConsoleText=text_of(GOOD_CONSOLE if console is None else console), StatusText=STATUS,
                RunOutText=PROGRAM + "\r\n", VenvLeaf=LEAF, ExeName=EXE, ProgramLine=PROGRAM, ExeExists=True, DirectFinished=True,
                DirectExitText="0", DirectOutText=PROGRAM + "\r\n")
    args.update(over)
    return args


def judge_result(**stats):
    base = {"lines": 60, "timestamped": 30, "triggered": 8, "named": 6, "exempt": 2, "violations": 0}
    base.update(stats)
    return json.dumps({"ok": base["violations"] == 0, "stats": base, "problems": []})


def wording_args(json_text=None, **over):
    args = dict(JudgeRan=True, JudgeError="", JudgeExit=0, JsonText=judge_result() if json_text is None else json_text,
                MinTimestamped=FLOORS["minTimestamped"], MinTriggered=FLOORS["minTriggered"], MinNamed=FLOORS["minNamed"],
                MinExempt=FLOORS["minExempt"])
    args.update(over)
    return args


def failing_json(n):
    problems = ["console line talks about building or verifying and does not name the EXE or the tool: line %d" % i for i in range(n)]
    return json.dumps({"ok": False, "stats": {"lines": 60, "timestamped": 30, "triggered": 8, "named": 6, "exempt": 2, "violations": n},
                       "problems": problems})


def judge_cases():
    c = []
    ac, wd = "Get-AcceptProblems", "Get-WordingProblems"
    # --- Find-ConsoleLine and Measure-ConsoleLines
    c.append(case("find_case_blind_substring", "Find-ConsoleLine", Lines=["a", "xBx", "c"], Fragment="b", From=0))
    c.append(case("find_missing", "Find-ConsoleLine", Lines=["a"], Fragment="x", From=0))
    c.append(case("find_from_skips_the_first", "Find-ConsoleLine", Lines=["x", "x"], Fragment="x", From=1))
    c.append(case("measure_counts_lines", "Measure-ConsoleLines", Lines=["a", "ab", "b"], Fragment="a"))
    c.append(case("measure_case_blind", "Measure-ConsoleLines", Lines=["A"], Fragment="a"))
    c.append(case("measure_none", "Measure-ConsoleLines", Lines=["a"], Fragment="z"))
    # --- Get-AcceptProblems: a clean run, and the things that go wrong around it
    c.append(case("accept_good", ac, **accept_args()))
    c.append(case("accept_unfinished", ac, **accept_args(Finished=False)))
    c.append(case("accept_wrong_exit", ac, **accept_args(ExitText="1\r\n")))
    for key, _, _, once in STEPS:
        c.append(case("accept_missing_" + key, ac, **accept_args(drop(GOOD_CONSOLE, LINES[key]))))
        if once:
            c.append(case("accept_twice_" + key, ac, **accept_args(after(GOOD_CONSOLE, LINES[key], LINES[key]))))
    c.append(case("accept_exit_and_success_lines_may_repeat", ac, **accept_args(after(after(GOOD_CONSOLE, LINES["exit0"], LINES["exit0"]),
                                                                                       LINES["success"], LINES["success"]))))
    c.append(case("accept_out_of_order", ac, **accept_args(after(drop(GOOD_CONSOLE, LINES["tried"]), LINES["consent"], LINES["tried"]))))
    c.append(case("accept_not_the_private_interpreter", ac, **accept_args(swap(GOOD_CONSOLE, LINES["selected"],
                                                                               STAMP + "[INFO] System fallback using C:\\Python314\\python.exe"))))
    for n, (_, text) in enumerate(NEVER):
        c.append(case("accept_never_%d" % n, ac, **accept_args(GOOD_CONSOLE + [STAMP + "[INFO] " + text])))
    c.append(case("accept_no_ready_line", ac, **accept_args(drop(GOOD_CONSOLE, READY))))
    c.append(case("accept_other_exe_under_the_ready_line", ac, **accept_args(swap(GOOD_CONSOLE, UNDER, "   dist\\other.exe"))))
    c.append(case("accept_no_exe", ac, **accept_args(ExeExists=False)))
    c.append(case("accept_run_output_without_the_line", ac, **accept_args(RunOutText="")))
    c.append(case("accept_status_empty", ac, **accept_args(StatusText="")))
    c.append(case("accept_status_state_ok", ac, **accept_args(StatusText='{"state":"ok","exitCode":0,"pyFiles":1}')))
    c.append(case("accept_status_exit_code_1", ac, **accept_args(StatusText='{"state":"degraded_env","exitCode":1,"pyFiles":1}')))
    c.append(case("accept_status_not_json", ac, **accept_args(StatusText="not json")))
    c.append(case("accept_direct_unfinished", ac, **accept_args(DirectFinished=False, DirectExitText="-1", DirectOutText="")))
    c.append(case("accept_direct_exit_1", ac, **accept_args(DirectExitText="1")))
    c.append(case("accept_direct_no_line", ac, **accept_args(DirectOutText="")))
    # --- Get-WordingProblems
    c.append(case("wording_good", wd, **wording_args()))
    c.append(case("wording_judge_did_not_run", wd, **wording_args(JudgeRan=False, JudgeError="the console log of the run does not exist")))
    c.append(case("wording_empty_output", wd, **wording_args(json_text="", JudgeExit=2)))
    c.append(case("wording_not_json", wd, **wording_args(json_text="Traceback (most recent call last):", JudgeExit=1)))
    c.append(case("wording_no_stats", wd, **wording_args(json_text='{"ok": true}')))
    c.append(case("wording_ok_but_exit_1", wd, **wording_args(JudgeExit=1)))
    c.append(case("wording_not_ok_names_no_line", wd, **wording_args(json_text=json.dumps(
        {"ok": False, "stats": {"lines": 60, "timestamped": 30, "triggered": 8, "named": 6, "exempt": 2, "violations": 1}, "problems": []}), JudgeExit=1)))
    c.append(case("wording_two_violations", wd, **wording_args(json_text=failing_json(2), JudgeExit=1)))
    c.append(case("wording_many_violations", wd, **wording_args(json_text=failing_json(25), JudgeExit=1)))
    c.append(case("wording_low_timestamped", wd, **wording_args(json_text=judge_result(timestamped=5))))
    c.append(case("wording_low_triggered", wd, **wording_args(json_text=judge_result(triggered=2))))
    c.append(case("wording_low_named", wd, **wording_args(json_text=judge_result(named=1))))
    c.append(case("wording_low_exempt", wd, **wording_args(json_text=judge_result(exempt=0))))
    return c


def step_needles():
    out = {}
    for key, label, text, once in STEPS:
        out["accept_missing_" + key] = "the console has no line for " + label
        if once:
            out["accept_twice_" + key] = "the console has 2 lines for %s, expected exactly 1" % label
    return out


# One problem each, and the words that problem must hold.
ONE_PROBLEM = {
    "accept_unfinished": "the bootstrapper did not finish within the time limit",
    "accept_wrong_exit": "the run ended with exit code '1', expected 0",
    "accept_out_of_order": "the REQ-014 consent was accepted comes before the step that precedes it on the console",
    "accept_not_the_private_interpreter": "the system interpreter of the run is not the private one (the line does not name " + LEAF + ")",
    "accept_never_0": "the console has 1 line(s) saying the build consent was declined",
    "accept_never_1": "the console has 1 line(s) saying the build was skipped as not consented",
    "accept_never_2": "the console has 1 line(s) saying the program was only checked through the interpreter",
    "accept_never_3": "the console has 1 line(s) saying the check run failed",
    "accept_never_4": "the console has 1 line(s) saying the panel is the caveat panel",
    "accept_no_ready_line": "the console has no post-flight panel line 'Your standalone application is ready:'",
    "accept_other_exe_under_the_ready_line": "the line under the ready line of the panel is 'dist\\other.exe', expected 'dist\\" + EXE + "'",
    "accept_no_exe": "dist\\" + EXE + " does not exist after the run",
    "accept_run_output_without_the_line": "~run.out.txt does not hold the program's line",
    "accept_status_state_ok": "~bootstrap.status.json says state 'ok', expected degraded_env",
    "accept_status_exit_code_1": "~bootstrap.status.json says exitCode '1', expected 0",
    "accept_direct_unfinished": "the EXE started on its own did not finish within the time limit",
    "accept_direct_exit_1": "the EXE started on its own exited with '1', expected 0",
    "accept_direct_no_line": "the EXE started on its own did not print the program's line",
    "wording_judge_did_not_run": "the judge did not run: the console log of the run does not exist",
    "wording_empty_output": "the judge printed no result it could be read from (exit code 2)",
    "wording_not_json": "the judge printed no result it could be read from (exit code 1)",
    "wording_no_stats": "the judge printed no result it could be read from (exit code 0)",
    "wording_ok_but_exit_1": "the judge says ok and exits with 1",
    "wording_not_ok_names_no_line": "the judge says not ok and names no line",
    "wording_low_timestamped": "the judge read 5 log lines, expected at least %d" % FLOORS["minTimestamped"],
    "wording_low_triggered": "the judge found 2 lines about the build, expected at least %d" % FLOORS["minTriggered"],
    "wording_low_named": "1 of the lines about the build name the EXE or the tool, expected at least %d" % FLOORS["minNamed"],
    "wording_low_exempt": "0 of the lines about the build matched an exempt entry, expected at least %d" % FLOORS["minExempt"],
}
ONE_PROBLEM.update(step_needles())
# the cases with their own tests below: the three that give two problems (status empty, status not JSON, two violations), the one
# that is cut at twenty (many violations), the clean ones, the ones that repeat a line without a problem and the six small helpers
TWO_PROBLEMS = ("accept_status_empty", "accept_status_not_json", "wording_two_violations")
CLEAN = ("accept_good", "accept_exit_and_success_lines_may_repeat", "wording_good")
HELPERS = ("find_case_blind_substring", "find_missing", "find_from_skips_the_first", "measure_counts_lines", "measure_case_blind", "measure_none")


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgeOnSyntheticRuns(unittest.TestCase):
    """The script's judging functions on runs built here: a clean run passes and each kind of wrong run is reported with its own
    sentence. The functions run alone and in strict mode, so they cannot read the script's variables."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, JUDGES, judge_cases(), d)

    def only(self, name, needle):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        self.assertIn(needle, found[0], (name, found))

    def test_the_two_helpers_find_the_first_line_and_count_the_lines_blind_to_case(self):
        self.assertEqual(self.r["find_case_blind_substring"], [1])
        self.assertEqual(self.r["find_missing"], [-1])
        self.assertEqual(self.r["find_from_skips_the_first"], [1])
        self.assertEqual(self.r["measure_counts_lines"], [2])
        self.assertEqual(self.r["measure_case_blind"], [1])
        self.assertEqual(self.r["measure_none"], [0])

    def test_a_clean_run_has_no_problem_and_the_exit_and_success_lines_may_repeat(self):
        for name in CLEAN:
            with self.subTest(case=name):
                self.assertEqual(self.r[name], [])

    def test_each_wrong_run_below_is_one_problem_with_its_own_sentence(self):
        for name, needle in sorted(ONE_PROBLEM.items()):
            with self.subTest(case=name):
                self.only(name, needle)

    def test_every_step_of_the_sequence_is_judged_for_a_missing_line_and_each_once_line_for_a_second_one(self):
        self.assertEqual(len(step_needles()), len(STEPS) + sum(1 for s in STEPS if s[3]))
        for key, label, text, once in STEPS:
            with self.subTest(step=key):
                self.only("accept_missing_" + key, "the console has no line for " + label)
                self.assertIn("(expected '%s" % text.split("\\")[0], self.r["accept_missing_" + key][0])
                if once:
                    self.only("accept_twice_" + key, "expected exactly 1")

    def test_an_empty_status_file_and_one_that_is_not_json_each_give_the_state_and_the_exit_code_as_two_problems(self):
        for name in ("accept_status_empty", "accept_status_not_json"):
            with self.subTest(case=name):
                found = self.r[name]
                self.assertEqual(len(found), 2, found)
                self.assertTrue(any("says state '', expected degraded_env" in f for f in found), found)
                self.assertTrue(any("says exitCode '', expected 0" in f for f in found), found)

    def test_a_judge_that_names_lines_passes_them_on_each_with_the_row_tag_and_cuts_the_list_at_twenty(self):
        found = self.r["wording_two_violations"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(all(f.startswith("console wording of the accepted build: console line talks about building or verifying") for f in found), found)
        many = self.r["wording_many_violations"]
        self.assertEqual(len(many), 21, many)
        self.assertEqual(many[-1], "console wording of the accepted build: ... and 5 more")

    def test_the_bridge_from_the_tool_to_the_judge_carries_the_fields_the_judge_reads(self):
        """The real output of tools/exe_wording.py console, handed to Get-WordingProblems, is read without a problem for a console that
        follows the rule and with exactly the line that breaks it for one that does not."""
        good = self.tool_run(GOOD_CONSOLE)
        bad = self.tool_run(GOOD_CONSOLE + [STAMP + "[INFO] Rebuilding the cache for the optimizer now."])
        self.assertEqual(good[0], 0, good)
        self.assertEqual(bad[0], 1, bad)
        stats = json.loads(good[1])["stats"]
        self.assertGreaterEqual(stats["timestamped"], 10, stats)
        self.assertGreaterEqual(stats["triggered"], 4, stats)
        self.assertGreaterEqual(stats["named"], 3, stats)
        self.assertGreaterEqual(stats["exempt"], 1, stats)
        floors = dict(MinTimestamped=10, MinTriggered=3, MinNamed=2, MinExempt=1)
        cases = [case("bridge_good", "Get-WordingProblems", JudgeRan=True, JudgeError="", JudgeExit=good[0], JsonText=good[1], **floors),
                 case("bridge_bad", "Get-WordingProblems", JudgeRan=True, JudgeError="", JudgeExit=bad[0], JsonText=bad[1], **floors)]
        with tempfile.TemporaryDirectory() as d:
            got = run_cases(SCRIPT, JUDGES, cases, d)
        self.assertEqual(got["bridge_good"], [])
        self.assertEqual(len(got["bridge_bad"]), 1, got["bridge_bad"])
        self.assertIn("does not name the EXE or the tool: [INFO] Rebuilding the cache for the optimizer now.", got["bridge_bad"][0])

    def tool_run(self, console_lines):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "console.txt"
            path.write_bytes(text_of(console_lines).encode("ascii"))
            proc = subprocess.run([sys.executable, "-I", str(TOOL), "console", "--file", str(path)], capture_output=True, text=True, timeout=120)
        return proc.returncode, proc.stdout.strip()


# --- the rules on the real files -------------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_batch_file_shows_the_accepted_path_the_script_reads_and_keeps_the_declined_lines_the_script_must_not_see(self):
        self.assertEqual(batch_problems(self.batch, self.script), [])

    def test_the_script_has_its_rows_launch_settings_judges_floors_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shalls_are_no_longer_listed_as_gaps(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        self.assertEqual(len(BATCH_LOG_TEXTS), 8, BATCH_LOG_TEXTS)
        # every case is accounted for: the helpers, the clean runs, the one-problem runs, the two-problem runs and the one cut at twenty
        names = [cs["name"] for cs in judge_cases()]
        self.assertEqual(len(names), len(set(names)))
        accounted = set(ONE_PROBLEM) | set(TWO_PROBLEMS) | set(CLEAN) | set(HELPERS) | {"wording_many_violations"}
        self.assertEqual(sorted(set(names) - accounted), [])
        self.assertEqual(sorted(accounted - set(names)), [])
        self.assertEqual(len(names), 6 + 3 + len(ONE_PROBLEM) + 3 + 1)
        self.assertEqual(len(ONE_PROBLEM), 46)
        self.assertEqual(len(names), 59)

    def test_every_judge_the_driver_is_asked_for_is_a_function_of_the_script(self):
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))

    def test_the_log_texts_of_the_declined_path_are_the_ones_tests_selfapps_sysbuild_looks_for(self):
        """The two scripts must describe the same console: what the declined scenario reads as the decline is what this one reads as absent."""
        other = norm((REPO / "tests" / "selfapps_sysbuild.ps1").read_text(encoding="utf-8"))
        for text in ("system-Python EXE build consent: declined.", "system-Python EXE build not consented",
                     "Running entry script smoke test via system interpreter."):
            with self.subTest(text=text):
                self.assertIn(text, other)


class BatchRulesCanFail(unittest.TestCase):
    """Each rule about run_setup.bat is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")

    def problems(self, batch):
        return batch_problems(batch, self.script)

    def test_a_reworded_log_line_of_the_accepted_path_is_reported_for_each_of_the_eight_texts(self):
        for text, new in (("[WARN] Attempting system Python fallback (degraded)...", "[WARN] Trying the system Python (degraded)..."),
                          ("[INFO] REQ-014: System Python consent: user accepted.", "[INFO] REQ-014: the system Python was accepted."),
                          ("[INFO] System fallback using ", "[INFO] System Python is "),
                          ("[BOOT] REQ-009: Selected Python provider: System Python (degraded).", "[BOOT] REQ-009: Provider: System Python (degraded)."),
                          ("[INFO] REQ-007: system-Python EXE build consent: accepted.", "[INFO] REQ-007: the EXE build was agreed."),
                          ("[INFO] Building standalone executable -- this may take a minute or two...", "[INFO] Building the program -- this may take a minute or two..."),
                          ("[INFO] PyInstaller produced dist\\%ENVNAME%.exe", "[INFO] PyInstaller built dist\\%ENVNAME%.exe"),
                          ("[INFO] Running entry script smoke test via packaged EXE.", "[INFO] Running the entry script via the packaged EXE.")):
            with self.subTest(text=text):
                bad = mutate(self.batch, text, new)
                self.assertTrue(any(text in f for f in self.problems(bad)), self.problems(bad))

    def test_a_log_line_that_exists_twice_is_reported(self):
        line = 'call :log "[INFO] System fallback using %HP_PY%"\n'
        bad = mutate(self.batch, line, line + line)
        self.assertTrue(any("'[INFO] System fallback using ' must be in exactly one live call :log line" in f and "found 2" in f for f in self.problems(bad)), self.problems(bad))

    def test_the_exit_line_and_the_success_pair_of_the_check_run_are_pinned(self):
        bad = mutate(self.batch, 'call :log "[INFO] Entry smoke exit=%HP_EXE_EXIT%"\n', 'call :log "[INFO] Entry smoke exit=%HP_EXE_EXIT% ."\n')
        self.assertTrue(any("Entry smoke exit=%HP_EXE_EXIT%" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'if "%HP_EXE_EXIT%"=="0" (\n  call :log "[STATUS] Run Status: SUCCESS (Exit Code: 0)"\n',
                     'if "%HP_EXE_EXIT%"=="0" (\n  rem x\n  echo.\n  call :log "[STATUS] Run Status: SUCCESS (Exit Code: 0)"\n')
        self.assertTrue(any("success line of the check run must follow" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_declined_path_line_that_vanishes_is_reported(self):
        bad = mutate(self.batch, 'call :log "[INFO] REQ-007: system-Python EXE build consent: declined."\n',
                     'call :log "[INFO] REQ-007: the EXE build was not agreed."\n')
        self.assertTrue(any("system-Python EXE build consent: declined." in f and "proves nothing" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'call :log "[INFO] Running entry script smoke test via %HP_ENV_MODE% interpreter."\n',
                     'call :log "[INFO] Running entry script smoke test via the interpreter."\n')
        found = self.problems(bad)
        self.assertTrue(any("%HP_ENV_MODE% interpreter." in f and "proves nothing" in f for f in found), found)
        line = 'call :log "[INFO] Running entry script smoke test via %HP_ENV_MODE% interpreter."\n'
        found = self.problems(mutate(self.batch, line, line + line))
        self.assertTrue(any("the interpreter check line" in f and "found 2" in f for f in found), found)

    def test_a_test_answer_tested_after_the_ci_marker_is_reported_for_both_gates(self):
        bad = mutate(self.batch, 'if defined HP_TEST_SYSBUILD_ANSWER (\n  set "HP_SYSBUILD_RAW=%HP_TEST_SYSBUILD_ANSWER%"\n) else if defined HP_CI_LANE (\n  set "HP_SYSBUILD_RAW=n"\n',
                     'if defined HP_CI_LANE (\n  set "HP_SYSBUILD_RAW=n"\n) else if defined HP_TEST_SYSBUILD_ANSWER (\n  set "HP_SYSBUILD_RAW=%HP_TEST_SYSBUILD_ANSWER%"\n')
        self.assertTrue(any("if defined HP_TEST_SYSBUILD_ANSWER (" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'if defined HP_TEST_SYSCON_ANSWER (\n  set "HP_SYSCON_CHOICE=%HP_TEST_SYSCON_ANSWER%"\n) else if defined HP_CI_LANE (\n  set "HP_SYSCON_CHOICE=n"\n',
                     'if defined HP_CI_LANE (\n  set "HP_SYSCON_CHOICE=n"\n) else if defined HP_TEST_SYSCON_ANSWER (\n  set "HP_SYSCON_CHOICE=%HP_TEST_SYSCON_ANSWER%"\n')
        self.assertTrue(any("if defined HP_TEST_SYSCON_ANSWER (" in f for f in self.problems(bad)), self.problems(bad))

    def test_an_accepted_build_consent_that_no_longer_returns_at_once_is_reported(self):
        bad = mutate(self.batch, '  call :log "[INFO] REQ-007: system-Python EXE build consent: accepted."\n  exit /b 0\n',
                     '  call :log "[INFO] REQ-007: system-Python EXE build consent: accepted."\n  echo.\n  exit /b 0\n')
        self.assertTrue(any("must log the acceptance and exit /b 0 at once" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_ci_marker_that_stops_declining_the_build_question_is_reported(self):
        bad = mutate(self.batch, 'set "HP_SYSBUILD_RAW=n"\n', 'set "HP_SYSBUILD_RAW=y"\n')
        self.assertTrue(any('set "HP_SYSBUILD_RAW=n"' in f for f in self.problems(bad)), self.problems(bad))

    def test_a_panel_that_stops_naming_the_exe_under_the_ready_line_is_reported(self):
        bad = mutate(self.batch, "echo  Your standalone application is ready:\necho    dist\\%ENVNAME%.exe\n",
                     "echo  Your standalone application is ready:\necho    Your program.\necho    dist\\%ENVNAME%.exe\n")
        self.assertTrue(any("the line under" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "echo  Your standalone application is ready:\n", "echo  Your application is ready:\n")
        self.assertTrue(any("must exist exactly once, found 0" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_system_tier_that_ends_in_another_state_or_resolves_another_interpreter_is_reported(self):
        bad = mutate(self.batch, 'set "HP_BOOTSTRAP_STATE=degraded_env"\n', 'set "HP_BOOTSTRAP_STATE=system_env"\n')
        self.assertTrue(any("degraded_env" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'where python >nul 2>&1 && set "HP_SYS_CMD=python"\n', 'where py >nul 2>&1 && set "HP_SYS_CMD=python"\n')
        self.assertTrue(any("where python" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_tier_that_no_longer_fails_by_its_flag_is_reported(self):
        bad = mutate(self.batch, 'if "%HP_TEST_FORCE_CONDA_FAIL%"=="1" goto :hp_test_conda_fail\n', "")
        self.assertTrue(any("HP_TEST_FORCE_CONDA_FAIL" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'if "%HP_TEST_FORCE_VENV_FAIL%"=="1" (\n', 'if "%HP_TEST_FORCE_VENV_FAIL%"=="2" (\n')
        self.assertTrue(any("HP_TEST_FORCE_VENV_FAIL" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_pyinstaller_install_that_moves_or_a_name_derivation_that_changes_is_reported(self):
        bad = mutate(self.batch, '"%HP_PY%" -m pip install -q pyinstaller >> "%LOG%" 2>&1\n', '"%HP_PY%" -m pip install -q pyinstaller==6 >> "%LOG%" 2>&1\n')
        self.assertTrue(any("pip line" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "-replace '[^A-Za-z0-9_-]', '_'", "-replace '[^A-Za-z0-9_]', '_'")
        self.assertTrue(any("derived from the folder name" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_script_that_stops_looking_for_a_text_is_reported(self):
        bad = mutate(norm(self.script), "'[INFO] Entry smoke exit=0'", "'[INFO] Entry smoke finished'")
        self.assertTrue(any("[INFO] Entry smoke exit=0" in f for f in batch_problems(self.batch, bad)))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the workflow, the registry and the shall list is shown to fail on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def problems(self, text):
        return script_problems(text)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "id = 'self.sysbuild.accept'; req = 'REQ-007.17'; pass = $pass", "id = $rowId; req = 'REQ-007.17'; pass = $pass")
        self.assertTrue(any("literal" in f for f in self.problems(bad)))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "id = 'self.sysbuild.wording'; req = 'REQ-007.20'; pass = $pass", "id = 'self.sysbuild.wording'; req = 'REQ-007'; pass = $pass")
        self.assertTrue(any("req tag" in f for f in self.problems(bad)))

    def test_a_run_that_answers_n_or_loses_a_setting_is_caught(self):
        bad = mutate(self.script, "'set \"HP_TEST_SYSBUILD_ANSWER=Y\"'", "'set \"HP_TEST_SYSBUILD_ANSWER=N\"'")
        found = self.problems(bad)
        self.assertTrue(any("answers N to the build question" in f for f in found), found)
        self.assertTrue(any("no longer sets HP_TEST_SYSBUILD_ANSWER=Y" in f for f in found), found)
        for name in ("HP_OFFLINE_MODE=1", "HP_TEST_FORCE_CONDA_FAIL=1", "HP_TEST_FORCE_VENV_FAIL=1", "HP_TEST_SYSCON_ANSWER=Y"):
            with self.subTest(name=name):
                bad = mutate(self.script, "'set \"%s\"'" % name, "'rem %s'" % name)
                self.assertTrue(any("no longer sets " + name in f for f in self.problems(bad)))
        bad = mutate(self.script, "('set \"HP_CI_LANE=' + $ciLaneValue + '\"')", "'rem lane'")
        self.assertTrue(any("HP_CI_LANE" in f for f in self.problems(bad)))

    def test_a_private_interpreter_that_is_not_first_on_the_path_or_not_made_is_caught(self):
        bad = mutate(self.script, "('set \"PATH=' + (Join-Path $venvDir 'Scripts') + ';%PATH%\"')", "('set \"PATH=%PATH%;' + (Join-Path $venvDir 'Scripts') + '\"')")
        self.assertTrue(any("first on PATH" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$venvOut = @(& $basePython -m venv $venvDir 2>&1)", "$venvOut = @(& $basePython -m ensurepip 2>&1)")
        self.assertTrue(any("python -m venv" in f for f in self.problems(bad)))

    def test_the_runners_settings_cleared_too_late_or_not_at_all_are_caught(self):
        bad = mutate(self.script, "foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }\n", "")
        self.assertTrue(any("clears every HP_ and PVW_ variable" in f for f in self.problems(bad)))
        late = mutate(self.script, "foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }\n", "")
        late = mutate(late, "Write-CrLf -Path (Join-Path $appDir '~accept_launch.cmd') -Lines $launchLines.ToArray()\n",
                      "foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }\nWrite-CrLf -Path (Join-Path $appDir '~accept_launch.cmd') -Lines $launchLines.ToArray()\n")
        self.assertTrue(any("cleared after" in f for f in self.problems(late)), self.problems(late))

    def test_open_standard_input_and_a_missing_kill_or_limit_are_caught(self):
        bad = mutate(self.script, "('call run_setup.bat > ' + $consoleName + ' 2>&1 < nul')", "('call run_setup.bat > ' + $consoleName + ' 2>&1')")
        self.assertTrue(any("standard input" in f for f in self.problems(bad)))
        kill = "& taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null"
        self.assertEqual(self.script.count(kill), 2, "one kill line in each of the two helpers")
        bad = self.script.replace(kill, "", 1)
        self.assertTrue(any("process tree" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-LimitMs 900000", "-LimitMs 9000000")
        self.assertTrue(any("-LimitMs 900000" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-LimitMs 60000", "-LimitMs 600000")
        self.assertTrue(any("-LimitMs 60000" in f for f in self.problems(bad)))

    def test_a_floor_that_was_lowered_or_removed_is_caught(self):
        for name, floor in FLOORS.items():
            with self.subTest(name=name):
                m = re.search(r"\$%s\s*=\s*(\d+)" % name, self.script)
                self.assertIsNotNone(m)
                low = self.script.replace(m.group(0), "$%s = %d" % (name, floor - 1), 1)
                self.assertTrue(any("floor $%s" % name in f for f in self.problems(low)), self.problems(low))
        gone = mutate(self.script, "$minNamed       = 4\n", "")
        self.assertTrue(any("floor $minNamed is missing" in f for f in self.problems(gone)))

    def test_a_verdict_that_stops_handing_a_judge_what_it_needs_is_caught(self):
        bad = mutate(self.script, "-ExeName $exeName -ProgramLine $programLine", "-ExeName '' -ProgramLine $programLine")
        self.assertTrue(any("-ExeName $exeName" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-DirectOutText $directOut)", "-DirectOutText '')")
        self.assertTrue(any("-DirectOutText $directOut" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-MinNamed $minNamed -MinExempt $minExempt)", "-MinNamed 0 -MinExempt $minExempt)")
        self.assertTrue(any("-MinNamed $minNamed" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$pass = [bool](@($wordingProblems).Count -eq 0)", "$pass = $true")
        self.assertTrue(any("row of wordingProblems" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$pass = [bool](@($acceptProblems).Count -eq 0)", "$pass = $true")
        self.assertTrue(any("row of acceptProblems" in f for f in self.problems(bad)))

    def test_a_wording_judge_that_moved_or_stopped_reading_the_console_is_caught(self):
        bad = mutate(self.script, "& $basePython -I $toolPath console --file $consolePath", "& $basePython -I $toolPath check")
        self.assertTrue(any("exe_wording.py console --file" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$toolPath = Join-Path $repo 'tools\\exe_wording.py'", "$toolPath = Join-Path $repo 'tools\\other.py'")
        self.assertTrue(any("tools\\exe_wording.py" in f for f in self.problems(bad)))

    def test_a_script_without_its_exit_codes_is_caught(self):
        bad = mutate(self.script, "if (-not $allPass) { exit 1 }\nexit 0\n", "exit 0\n")
        self.assertTrue(any("exits 1 for a red row" in f for f in self.problems(bad)))
        bad = mutate(self.script, "if (-not $allPass) { exit 1 }\nexit 0\n", "if (-not $allPass) { exit 1 }\n")
        self.assertTrue(any("does not end with exit 0" in f for f in self.problems(bad)))

    def test_isWindows_and_a_non_ascii_character_are_caught(self):
        bad = mutate(self.script, "if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {", "if (-not $IsWindows) {")
        self.assertTrue(any("OSVersion.Platform" in f for f in self.problems(bad)))
        self.assertTrue(any("ASCII" in f for f in self.problems(self.script + "\n# caf\u00e9\n")))

    def test_a_judge_that_is_missing_is_caught(self):
        bad = mutate(self.script, "function Get-WordingProblems {", "function Get-WordingProblemsX {")
        self.assertTrue(any("Get-WordingProblems is missing" in f for f in self.problems(bad)))

    def test_a_step_that_is_not_contract_uv_only_is_caught(self):
        block = step_block(self.workflow, SCRIPT_NAME)
        self.assertIsNotNone(block)
        other = self.workflow.replace(block, block.replace("matrix.mode == 'contract-uv'", "matrix.mode == 'real'"))
        self.assertTrue(any("contract-uv" in f for f in workflow_problems(other)))

    def test_a_step_that_cannot_fail_is_caught(self):
        block = step_block(self.workflow, SCRIPT_NAME)
        bad = self.workflow.replace(block, block.replace("        shell: pwsh\n", "        shell: pwsh\n        continue-on-error: true\n", 1))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(bad)))

    def test_a_missing_step_or_upload_is_caught(self):
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\" + SCRIPT_NAME])
        for pattern in UPLOADS:
            with self.subTest(pattern=pattern):
                bad = self.workflow.replace(pattern, "")
                self.assertTrue(any(pattern in f for f in workflow_problems(bad)))

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        self.assertTrue(registry_problems(text.replace("self.sysbuild.wording", "self.sysbuild.wordingx")))
        self.assertTrue(registry_problems("```\nself.sysbuild.accept\n```\nprose: self.sysbuild.wording\n"))

    def test_a_shall_that_is_still_listed_as_a_gap_is_caught(self):
        self.assertTrue(shall_list_problems('    "REQ-007.17": "gap: x",\n'))
        self.assertTrue(shall_list_problems('    "REQ-007.20": "gap: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-007.170": "gap: x",\n'), [])


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesCanFail(unittest.TestCase):
    """A judge that quietly stops judging would pass every scenario, so the cases are run against mutated copies of the script: each
    comparison replaced by $false must make the case that depends on it come out without its sentence."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.base = run_cases(SCRIPT, JUDGES, judge_cases(), d)

    def run_mutated(self, old, new, names):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, new), encoding="utf-8")
            wanted = [cs for cs in judge_cases() if cs["name"] in names]
            return run_cases(script, JUDGES, wanted, d)

    def silenced(self, comparison, name, needle, crash=None):
        """Replacing `if (<comparison>) {` by `if ($false) {` must remove the sentence `needle` from the answer for case `name`. A judge
        that goes on to read what is not there may stop with PowerShell's own error instead; that counts as the sentence being gone only
        for the error text the case names in `crash`."""
        self.assertTrue(any(needle in f for f in self.base[name]), (name, needle, self.base[name]))
        try:
            got = self.run_mutated("if (" + comparison + ") {", "if ($false) {", [name])
        except AssertionError as err:
            self.assertIsNotNone(crash, (name, str(err)))
            self.assertIn(crash, str(err))
            return
        self.assertFalse(any(needle in f for f in got[name]), (name, needle, got[name]))

    def test_a_judge_that_forgets_a_bootstrapper_that_never_finished_is_caught(self):
        self.silenced("-not $Finished", "accept_unfinished", "did not finish within the time limit")

    def test_the_comparisons_of_the_sequence_each_matter(self):
        for comparison, name, needle in (
            ("$n -lt 1", "accept_missing_building", "the console has no line for the build started"),
            ("$once -and $n -ne 1", "accept_twice_building", "expected exactly 1"),
            ("$at -le $prev", "accept_out_of_order", "comes before the step that precedes it"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_the_comparisons_around_the_sequence_each_matter(self):
        for comparison, name, needle in (
            ("$exit -ne '0'", "accept_wrong_exit", "the run ended with exit code"),
            ("($fallbackAt -ge 0) -and ($lines[$fallbackAt].IndexOf($VenvLeaf, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)",
             "accept_not_the_private_interpreter", "is not the private one"),
            ("$n -gt 0", "accept_never_0", "saying the build consent was declined"),
            ("$readyAt -lt 0", "accept_no_ready_line", "no post-flight panel line"),
            ("$next -ine $want", "accept_other_exe_under_the_ready_line", "the line under the ready line of the panel is"),
            ("-not $ExeExists", "accept_no_exe", "does not exist after the run"),
            ("$RunOutText.IndexOf($ProgramLine, [System.StringComparison]::Ordinal) -lt 0", "accept_run_output_without_the_line", "~run.out.txt does not hold"),
            ("$state -ne 'degraded_env'", "accept_status_state_ok", "expected degraded_env"),
            ("$code -ne '0'", "accept_status_exit_code_1", "exitCode '1', expected 0"),
            ("-not $DirectFinished", "accept_direct_unfinished", "did not finish within the time limit"),
            ("$DirectExitText.Trim() -ne '0'", "accept_direct_exit_1", "exited with '1'"),
            ("$DirectOutText.IndexOf($ProgramLine, [System.StringComparison]::Ordinal) -lt 0", "accept_direct_no_line", "did not print the program's line"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_the_comparisons_of_the_wording_judge_each_matter(self):
        for comparison, name, needle in (
            ("-not $JudgeRan", "wording_judge_did_not_run", "the judge did not run"),
            ("($parsed.ok -eq $true) -and ($JudgeExit -ne 0)", "wording_ok_but_exit_1", "says ok and exits with"),
            ("($parsed.ok -ne $true) -and ($problems.Count -eq 0)", "wording_not_ok_names_no_line", "says not ok and names no line"),
            ("$shown -ge 20", "wording_many_violations", "... and 5 more"),
            ("$got.timestamped -lt $MinTimestamped", "wording_low_timestamped", "log lines, expected at least"),
            ("$got.triggered -lt $MinTriggered", "wording_low_triggered", "lines about the build, expected at least"),
            ("$got.named -lt $MinNamed", "wording_low_named", "name the EXE or the tool, expected at least"),
            ("$got.exempt -lt $MinExempt", "wording_low_exempt", "matched an exempt entry"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)
        # without that guard the judge reads statistics that are not there and PowerShell stops it with its own error: the answer is lost
        self.silenced("($null -eq $parsed) -or ($null -eq $parsed.PSObject.Properties['stats']) -or ($null -eq $parsed.PSObject.Properties['ok'])",
                      "wording_no_stats", "printed no result it could be read from", crash="Cannot index into a null array")

    def test_a_line_finder_that_matches_the_wrong_way_is_caught(self):
        got = self.run_mutated("if ($Lines[$i].IndexOf($Fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $i }",
                               "if ($Lines[$i] -ceq $Fragment) { return $i }", ["find_case_blind_substring"])
        self.assertEqual(got["find_case_blind_substring"], [-1])


if __name__ == "__main__":
    unittest.main()
