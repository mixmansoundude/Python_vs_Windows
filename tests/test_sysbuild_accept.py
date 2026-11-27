"""Item 123 (README REQ-007.17 and REQ-007.20): the answer Y to the system-Python build question builds the EXE, and every message
about it says EXE or names the tool.

REQ-007.17 says that when the user agrees to the build question under REQ-007.16 the bootstrapper builds the EXE as it does for every
other provider; REQ-007.20 says that every message about the build, the check run of the executable or its failure names the artifact
and the tool in plain words, so a reader can tell it is about the optional one-file program and not about the environment, which is
already installed. Until this item the README said that no scenario answered yes to the build question and that no check read every
message, and the existing rows of tests/selfapps_sysbuild.ps1 answer N or let the CI marker decline.

tests/selfapps_sysbuild_accept.ps1 (rows self.sysbuild.accept and self.sysbuild.wording; contract-uv lane, gating) bootstraps one folder
for real with a private virtual environment as the system Python (its Scripts folder first on PATH), a PUBLIC folder of its own (the
bootstrapper puts the Miniconda folder under PUBLIC first on PATH, so one left in the runner's shared Public folder by an earlier
scenario would be taken for the system Python, run 44708489835), every other tier failed by decree and the answers Y to both
questions, and judges the console twice: the sequence of the accepted build, and, through tools/exe_wording.py
`console`, the wording of every log line of that run. tests/test_exe_wording.py holds every message of run_setup.bat to the wording rule
without running anything.

What really happens is shown on Windows by that script. These rules read run_setup.bat, the script, batch-check.yml,
docs/agent-ndjson.md, tests/test_req_shall_trace.py, CLAUDE.md, the agent docs and the demo (they must say what the stand-in system
Python does not verify, and the demo must show the offer the batch file prints) as text and run the script's own judging functions
through a real pwsh on
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
from judge_support import (PWSH, after, case, drop, label_section, lines_of, live_bat, live_hash, mutate, norm,  # noqa: E402
                           registry_ids, run_cases, step_block, swap, text_of)

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_sysbuild_accept.ps1"
TOOL = REPO / "tools" / "exe_wording.py"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
DEMO = REPO / "docs" / "demo-bootstrapper-output.md"
CLAUDE_MD = REPO / "CLAUDE.md"
INTERCONNECT = REPO / "docs" / "agent-interconnect.md"
LESSONS = REPO / "docs" / "agent-lessons-learned.md"
CLOSED_BACKLOG = REPO / "docs" / "agent-closed-backlog.md"
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
JUDGES = ["Find-ConsoleLine", "Measure-ConsoleLines", "Get-AcceptProblems", "Get-IsolationProblems", "Get-WordingProblems"]
# Two more functions of the script are judged in classes of their own and are not in JUDGES: the driver stops a whole class when one of the
# functions it is asked for is missing, and the other judges are not to be reported red for a function a later change adds.
EXTRA_FUNCTIONS = ("Get-CompletionProblems", "Reset-Folder")
# about two thirds of the first real run (48 timestamped lines, 9 about the build, 7 naming the EXE, 2 exempt, run 43740185058 after the rewording)
FLOORS = {"minTimestamped": 30, "minTriggered": 6, "minNamed": 4, "minExempt": 1}

# The console lines of the accepted build, in the order the run must show them: (key, label the judge prints, text of the line,
# whether the line must be there exactly once). The texts are the live `call :log` lines of run_setup.bat.
EXE = "_selftest_sysbuild_accept.exe"
LEAF = "~selftest_sysbuild_accept_venv"
PROGRAM = "sysbuild-accept-app-line-7731"
PUBLIC = "C:\\w\\~selftest_sysbuild_accept_public"
VENV_PYTHON = "C:\\w\\" + LEAF + "\\Scripts\\python.exe"
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
    # The line under the test of the test answer is the one that takes THAT answer (a gate whose next line was any `set ` line passed
    # the first version of this rule: CodeRabbit, PR 537), and the CI marker is tested right after it.
    for answer, assignment, marker, choice in (
            ("if defined HP_TEST_SYSBUILD_ANSWER (", 'set "HP_SYSBUILD_RAW=%HP_TEST_SYSBUILD_ANSWER%"', ") else if defined HP_CI_LANE (",
             'if /I "%HP_SYSBUILD_CHOICE%"=="Y" ('),
            ("if defined HP_TEST_SYSCON_ANSWER (", 'set "HP_SYSCON_CHOICE=%HP_TEST_SYSCON_ANSWER%"', ") else if defined HP_CI_LANE (",
             'if /I "%HP_SYSCON_CHOICE:~0,1%"=="y" (')):
        at = [i for i, ln in enumerate(live) if ln == answer]
        if len(at) != 1:
            found.append("the line %s must exist exactly once, found %d" % (answer, len(at)))
            continue
        nxt = live[at[0] + 1:at[0] + 3]
        if len(nxt) < 2 or nxt[0] != assignment or nxt[1] != marker:
            found.append("after %s the next live line must be %s, then the CI marker test (%s); found %r" % (answer, assignment, marker, nxt))
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
    # the run's own PUBLIC (run 44708489835): the bootstrapper puts %PUBLIC%\Documents\Miniconda3 first on PATH whether or not it exists, so
    # the folder must be the run's own and empty, set before the bootstrap starts, recorded by the launch file and judged
    if "$publicDir = $appDir + '_public'" not in compact:
        found.append("the folder of the run's own PUBLIC is no longer named from the folder of the program")
    set_public = compact.find("('set \"PUBLIC=' + $publicDir + '\"')")
    record = compact.find("'set PUBLIC>\"~accept_public.txt\"'")
    start_batch = compact.find("('call run_setup.bat > '")
    if set_public < 0:
        found.append("the run no longer gives the bootstrapper a PUBLIC of its own, so a Miniconda left in the runner's shared Public folder "
                     "could become the system Python of the run")
    if record < 0:
        found.append("the launch file no longer records the PUBLIC the bootstrapper saw with set PUBLIC>\"~accept_public.txt\"")
    if set_public >= 0 and record >= 0 and set_public > record:
        found.append("the PUBLIC is recorded before it is set, so the record would show the runner's")
    if record >= 0 and start_batch >= 0 and record > start_batch:
        found.append("the PUBLIC is recorded after the bootstrapper started")
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
                     "-VenvPython $venvPython", "-ExeName $exeName", "-ProgramLine $programLine", "-ExeExists ([bool]$exeExists)",
                     "-DirectFinished ([bool]$direct.Finished)", "-DirectExitText ([string]$direct.ExitCode)", "-DirectOutText $directOut"):
            if need not in args:
                found.append("the verdict no longer hands %s to Get-AcceptProblems" % need)
    if "$isolationProblems = @(Get-IsolationProblems -PublicRecord $publicRecord -PublicWanted $publicDir)" not in compact:
        found.append("the PUBLIC the bootstrapper saw is no longer judged by Get-IsolationProblems against the folder the run set")
    combine = compact.find("$acceptProblems = @($isolationProblems) + @($acceptProblems)")
    if combine < 0:
        found.append("the row of self.sysbuild.accept no longer includes the problems of the PUBLIC the bootstrapper saw")
    elif combine > compact.find("$pass = [bool](@($acceptProblems).Count -eq 0)"):
        found.append("the problems of the PUBLIC are added to the row of self.sysbuild.accept after its verdict was taken")
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
    # the functions that are judged in classes of their own (a missing one stops the class, so they are not in JUDGES)
    for name in EXTRA_FUNCTIONS:
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the function %s is missing" % name)
    # the folders of the run are cleared by Reset-Folder, and a folder that cannot be cleared ends the run with a reported failure before
    # anything is built (CodeRabbit, PR 537: the first version silenced the removal errors, and New-Item -Force does not empty a folder)
    calls = ("$resetProblem = Reset-Folder -Path $venvDir", "Reset-Folder -Path $appDir -Create", "Reset-Folder -Path $publicDir -Create")
    at = [compact.find(c) for c in calls]
    for c, i in zip(calls, at):
        if i < 0:
            found.append("the folder of the run is no longer cleared by %s" % c)
    stop = compact.find("if ($resetProblem) {")
    if stop < 0:
        found.append("a folder that could not be cleared no longer stops the run: if ($resetProblem) { is missing")
    else:
        if any(0 <= i > stop for i in at):
            found.append("a folder of the run is cleared after the test of the clearing, so a failure of it is not seen")
        body = compact[stop:].split("\n}", 1)[0]
        for need in ("Write-AllRows -Pass $false", "exit 1"):
            if need not in body:
                found.append("a folder that could not be cleared no longer ends the run with a red row and exit 1: %s is missing" % need)
        venv_at = compact.find("& $basePython -m venv $venvDir")
        if 0 <= venv_at < stop:
            found.append("the private interpreter is made before the folders were cleared")
    if re.search(r"Remove-Item[^\n]*SilentlyContinue", compact):
        found.append("a Remove-Item of the script silences its errors, so a folder that cannot be removed is used with its old content")
    reset_body = compact.split("function Reset-Folder {", 1)[-1].split("\nfunction ", 1)[0]
    if "Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop" not in reset_body:
        found.append("Reset-Folder no longer removes the folder with -ErrorAction Stop")
    # the launch file records PUBLIC with `set PUBLIC>file`: an `echo PUBLIC=%PUBLIC%` is cut at an ampersand of the folder name, which
    # cmd.exe takes for a command separator, and a `set` prints the value as it is (nothing may sit between the name and the >)
    if "echo PUBLIC=%PUBLIC%" in compact:
        found.append("the launch file records the PUBLIC with echo, which cmd.exe cuts at an ampersand of the folder name")
    # the interpreter is compared as a whole path and not by the name of its folder
    if "-VenvPython $venvPython" not in compact.split("$acceptProblems = @(Get-AcceptProblems", 1)[-1].split("\n", 1)[0]:
        found.append("the verdict no longer hands -VenvPython $venvPython to Get-AcceptProblems, so the interpreter is not compared as a whole path")
    # the wording row is judged only for a run that went through the accepted build
    wire = "$completionProblems = @(Get-CompletionProblems -Finished ([bool]$launch.Finished) -ConsoleText $console)"
    merge = "$wordingProblems = @($completionProblems) + @($wordingProblems)"
    verdict = compact.find("$pass = [bool](@($wordingProblems).Count -eq 0)")
    if wire not in compact:
        found.append("the wording row is no longer judged for a run that completed the accepted build: Get-CompletionProblems is not called")
    if merge not in compact:
        found.append("the problems of an incomplete run are no longer part of the row of self.sysbuild.wording")
    elif 0 <= verdict < compact.find(merge):
        found.append("the problems of an incomplete run are added to the row of self.sysbuild.wording after its verdict was taken")
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
    # the step is found by the script's name, so the name alone proves nothing: a line that calls the script must be live (CodeRabbit, PR 537)
    calls = [ln.strip() for ln in block.split("\n") if ln.strip() and not ln.strip().startswith("#")]
    if not any(re.match(r"&\s+(?:\.\\)?tests\\" + re.escape(SCRIPT_NAME) + r"(?![\w.\-])", ln) for ln in calls):
        found.append("the step has no live line that runs tests\\%s (a comment or an echo that names it does not run it)" % SCRIPT_NAME)
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


# --- the stand-in system Python and the demo: what the documents say about them (CodeRabbit, PR 537) ---------------------------------
#
# The row bootstraps with a virtual environment of the runner's python as the system Python. That is a stand-in, and a document that says
# its layout "differs only in the path" from a python.org installation claims more than the row shows: a venv has no registry entries and
# no py launcher and keeps prefixes of its own. So every place that describes the stand-in says what it does not verify, and none says that
# the two differ only in the path. The demo shows the optimized-build offer the way the batch file prints it.

OVERCLAIM = re.compile(r"differs?\s+(?:from\s+(?:\S+\s+){1,4})?only\s+in\s+(?:the|its)\s+path", re.IGNORECASE)
NOT_VERIFIED = "does not verify"
LIMIT_WORDS = ("folder layout", "registry", "py launcher")
DEMO_SCENARIOS = {5: False, 35: True}  # scenario number: whether it also shows the answer no with its log line


def read_text(path):
    return norm(path.read_text(encoding="utf-8"))


def collapse(text):
    return " ".join(text.split())


def line_with(text, needle):
    """The one line that holds `needle` (collapsed), or None when no line or more than one line holds it."""
    hits = [ln for ln in text.split("\n") if needle in ln]
    return collapse(hits[0]) if len(hits) == 1 else None


def bullet_of(text, marker):
    """The list item that starts with `marker`, up to the next line that is not indented (collapsed), or None when the marker is not there
    exactly once."""
    if text.count(marker) != 1:
        return None
    body = text[text.index(marker):]
    end = re.search(r"\n(?! )", body)
    return collapse(body[:end.start()] if end else body)


def slice_of(text, start, stop):
    """The text from `start` up to `stop` (collapsed), or None when `start` is not there exactly once or `stop` does not follow it."""
    if text.count(start) != 1:
        return None
    at = text.index(start)
    end = text.find(stop, at + len(start))
    return collapse(text[at:end]) if end >= 0 else None


def script_header(text):
    """The comment block at the top of the script (up to `param()`), without the comment marks."""
    head = norm(text).split("\nparam()", 1)[0]
    return "\n".join(re.sub(r"^\s*#+ ?", "", ln) for ln in head.split("\n"))


def limits_paragraph(text):
    """The paragraph of the script header that starts with `Limits, stated`, up to the blank comment line (collapsed), or None."""
    lines = script_header(text).split("\n")
    start = next((i for i, ln in enumerate(lines) if ln.startswith("Limits, stated")), None)
    if start is None:
        return None
    end = next((j for j in range(start + 1, len(lines)) if not lines[j].strip()), len(lines))
    return collapse(" ".join(lines[start:end]))


def stand_in_passages():
    """Every place that describes the stand-in system Python: (name, its text or None when it was not found, the words it must hold)."""
    script = read_text(SCRIPT)
    return [
        ("CLAUDE.md", line_with(read_text(CLAUDE_MD), "selfapps_sysbuild_accept.ps1 Item 123"), (NOT_VERIFIED,)),
        ("docs/agent-interconnect.md", bullet_of(read_text(INTERCONNECT), "- **The system Python is a stand-in.**"), (NOT_VERIFIED,)),
        ("docs/agent-lessons-learned.md", bullet_of(read_text(LESSONS), '- **A scenario that installs into "the system Python"'), (NOT_VERIFIED,)),
        ("docs/agent-closed-backlog.md", bullet_of(read_text(CLOSED_BACKLOG), "- **Stated limits (also in the script's header and the registry entry).**"),
         (NOT_VERIFIED,)),
        ("docs/agent-ndjson.md", slice_of(read_text(REGISTRY), "Stated limits:", "Evidence"), (NOT_VERIFIED,)),
        ("the Limits paragraph of the script header", limits_paragraph(script), (NOT_VERIFIED,) + LIMIT_WORDS),
        ("the script header", script_header(script), ()),
    ]


def stand_in_problems(passages):
    found = []
    for name, text, needed in passages:
        if text is None:
            found.append("%s: the passage was not found (its first words were reworded or moved), so this pin would prove nothing" % name)
            continue
        claim = OVERCLAIM.search(text)
        if claim:
            found.append("%s: says the stand-in differs from a python.org installation only in its path (%r); a venv also has no registry entries "
                         "and no py launcher, so say what the stand-in does not verify" % (name, claim.group(0)))
        for word in needed:
            if word not in text.lower():
                found.append("%s: does not say %r" % (name, word))
    return found


def demo_section(demo, number):
    """The text of `### Scenario N:` up to the next scenario heading, or None when the demo has no such scenario."""
    head = re.search(r"(?m)^### Scenario %d:.*$" % number, demo)
    if not head:
        return None
    nxt = re.search(r"(?m)^### Scenario %d:" % (number + 1), demo[head.end():])
    return demo[head.start():head.end() + nxt.start()] if nxt else demo[head.start():]


def optimized_build_offer(batch):
    """What :offer_optimized_build prints before its question (the text of each `echo *** ` line) and the text of the log line of the answer
    no. ([], "") when the label is not in the batch file."""
    body = [ln.strip() for ln in live_bat(lines_of(batch))]
    try:
        section = label_section(body, ":offer_optimized_build")
    except ValueError:
        return [], ""
    echoes = []
    for ln in section:
        if ln == 'set "HP_OPTBUILD_RAW="':
            break
        if ln.startswith("echo *** "):
            echoes.append(ln[len("echo "):])
    declined = ""
    for ln in section:
        hit = re.match(r'call :log "(\[INFO\] Optimized build: declined\..*)"$', ln)
        if hit:
            declined = hit.group(1)
            break
    return echoes, declined


def demo_problems(section, number, echoes, declined):
    """Scenario `number` of the demo must show every line the offer prints and, when `declined` is given, the log line of the answer no."""
    if section is None:
        return ["the demo has no Scenario %d, so the optimized-build offer is not compared with the batch file" % number]
    if len(echoes) < 4:
        return ["only %d echo line(s) of the optimized-build offer were read from the batch file, so the demo is not compared" % len(echoes)]
    shown = {ln.strip() for ln in section.split("\n")}
    return ["Scenario %d does not show the line %r of the optimized-build offer" % (number, line)
            for line in list(echoes) + ([declined] if declined else []) if line not in shown]


# --- the script's judging functions, run through a real pwsh ---------------------------------------------------------------------

STAMP = "Sat 11/14/2026  9:05:03.10 "
STATUS = '{"state":"degraded_env","exitCode":0,"pyFiles":1}'
LINES = {key: STAMP + text for key, _, text, _ in STEPS}
LINES["selected"] = STAMP + "[INFO] System fallback using " + VENV_PYTHON
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
                RunOutText=PROGRAM + "\r\n", VenvPython=VENV_PYTHON, ExeName=EXE, ProgramLine=PROGRAM, ExeExists=True, DirectFinished=True,
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


def isolation_args(record=None, **over):
    args = dict(PublicRecord="PUBLIC=" + PUBLIC + "\r\n" if record is None else record, PublicWanted=PUBLIC)
    args.update(over)
    return args


def failing_json(n):
    problems = ["console line talks about building or verifying and does not name the EXE or the tool: line %d" % i for i in range(n)]
    return json.dumps({"ok": False, "stats": {"lines": 60, "timestamped": 30, "triggered": 8, "named": 6, "exempt": 2, "violations": n},
                       "problems": problems})


LABELS = {key: label for key, label, _, _ in STEPS}
COMPLETION_MARKERS = (("completion_no_build_line", LABELS["produced"]), ("completion_no_success_line", LABELS["success"]),
                      ("completion_no_panel", "the post-flight panel"))


def completion_args(console=None, **over):
    args = dict(Finished=True, ConsoleText=text_of(GOOD_CONSOLE if console is None else console))
    args.update(over)
    return args


def completion_cases():
    """Get-CompletionProblems: the wording row is judged only for a run that went through the accepted build (CodeRabbit, PR 537)."""
    cp = "Get-CompletionProblems"
    return [
        case("completion_good", cp, **completion_args()),
        case("completion_unfinished", cp, **completion_args(Finished=False)),
        case("completion_no_build_line", cp, **completion_args(drop(GOOD_CONSOLE, LINES["produced"]))),
        case("completion_no_success_line", cp, **completion_args(drop(GOOD_CONSOLE, LINES["success"]))),
        case("completion_no_panel", cp, **completion_args(drop(GOOD_CONSOLE, READY))),
        case("completion_cut_after_the_start_of_the_build", cp, **completion_args(GOOD_CONSOLE[:GOOD_CONSOLE.index(LINES["building"]) + 1])),
    ]


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
    # the interpreter is the private one by its whole path: the same folder name under another parent and a folder whose name only starts
    # with it are other interpreters, and the case of the path does not matter on Windows (CodeRabbit, PR 537)
    c.append(case("accept_same_leaf_other_parent", ac, **accept_args(swap(GOOD_CONSOLE, LINES["selected"],
                                                                        STAMP + "[INFO] System fallback using C:\\other\\" + LEAF + "\\Scripts\\python.exe"))))
    c.append(case("accept_backup_folder_of_the_leaf", ac, **accept_args(swap(GOOD_CONSOLE, LINES["selected"],
                                                                           STAMP + "[INFO] System fallback using C:\\w\\" + LEAF + ".bak\\Scripts\\python.exe"))))
    c.append(case("accept_interpreter_path_case_blind", ac, **accept_args(swap(GOOD_CONSOLE, LINES["selected"],
                                                                             STAMP + "[INFO] System fallback using " + VENV_PYTHON.upper()))))
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
    # --- Get-IsolationProblems: the run was given a PUBLIC of its own
    iso = "Get-IsolationProblems"
    c.append(case("isolation_good", iso, **isolation_args()))
    c.append(case("isolation_case_blind", iso, **isolation_args("PUBLIC=" + PUBLIC.upper() + "\r\n")))
    c.append(case("isolation_trailing_space", iso, **isolation_args("PUBLIC=" + PUBLIC + " \r\n")))
    c.append(case("isolation_runner_public", iso, **isolation_args("PUBLIC=C:\\Users\\Public\r\n")))
    c.append(case("isolation_parent_folder", iso, **isolation_args("PUBLIC=C:\\w\r\n")))
    c.append(case("isolation_no_record", iso, **isolation_args("")))
    c.append(case("isolation_empty_value", iso, **isolation_args("PUBLIC=\r\n")))
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
    "accept_not_the_private_interpreter": "the system interpreter of the run is 'C:\\Python314\\python.exe', not the private one '" + VENV_PYTHON + "'",
    "accept_same_leaf_other_parent": "the system interpreter of the run is",
    "accept_backup_folder_of_the_leaf": "the system interpreter of the run is",
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
    "isolation_runner_public": "the bootstrapper saw PUBLIC 'C:\\Users\\Public', expected '" + PUBLIC + "' (a folder of its own)",
    "isolation_parent_folder": "the bootstrapper saw PUBLIC 'C:\\w', expected '" + PUBLIC + "' (a folder of its own)",
    "isolation_no_record": "the launch file recorded no PUBLIC",
    "isolation_empty_value": "the launch file recorded no PUBLIC",
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
CLEAN = ("accept_good", "accept_exit_and_success_lines_may_repeat", "accept_interpreter_path_case_blind", "wording_good", "isolation_good",
         "isolation_case_blind", "isolation_trailing_space")
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

    def test_a_system_interpreter_that_is_not_the_private_one_names_both_paths(self):
        """The line must name the private interpreter's own path: the same folder name under another parent, or a folder whose name only
        starts with it, is another interpreter (CodeRabbit, PR 537)."""
        for name, used in (("accept_same_leaf_other_parent", "C:\\other\\" + LEAF + "\\Scripts\\python.exe"),
                           ("accept_backup_folder_of_the_leaf", "C:\\w\\" + LEAF + ".bak\\Scripts\\python.exe"),
                           ("accept_not_the_private_interpreter", "C:\\Python314\\python.exe")):
            with self.subTest(case=name):
                self.only(name, "the system interpreter of the run is")
                self.assertIn("'" + used + "'", self.r[name][0])
                self.assertIn("'" + VENV_PYTHON + "'", self.r[name][0])

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

    def test_every_place_that_describes_the_stand_in_says_what_it_does_not_verify_and_none_claims_the_layouts_differ_only_in_the_path(self):
        passages = stand_in_passages()
        self.assertEqual(len(passages), 7, [p[0] for p in passages])
        for entry in passages:
            with self.subTest(passage=entry[0]):
                self.assertEqual(stand_in_problems([entry]), [])

    def test_the_demo_shows_the_optimized_build_offer_the_batch_file_prints(self):
        echoes, declined = optimized_build_offer(self.batch)
        self.assertGreaterEqual(len(echoes), 4, echoes)
        self.assertTrue(declined.startswith("[INFO] Optimized build: declined."), declined)
        demo = read_text(DEMO)
        for number, answers_no in sorted(DEMO_SCENARIOS.items()):
            with self.subTest(scenario=number):
                self.assertEqual(demo_problems(demo_section(demo, number), number, echoes, declined if answers_no else ""), [])
        self.assertIn("[Extrapolated Branch]", demo_section(demo, 35))

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        self.assertEqual(len(BATCH_LOG_TEXTS), 8, BATCH_LOG_TEXTS)
        # every case is accounted for: the helpers, the clean runs, the one-problem runs, the two-problem runs and the one cut at twenty
        names = [cs["name"] for cs in judge_cases()]
        self.assertEqual(len(names), len(set(names)))
        accounted = set(ONE_PROBLEM) | set(TWO_PROBLEMS) | set(CLEAN) | set(HELPERS) | {"wording_many_violations"}
        self.assertEqual(sorted(set(names) - accounted), [])
        self.assertEqual(sorted(accounted - set(names)), [])
        self.assertEqual(len(names), 6 + len(CLEAN) + len(ONE_PROBLEM) + 3 + 1)
        self.assertEqual(len(ONE_PROBLEM), 52)
        self.assertEqual(len(names), 69)

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

    def test_a_gate_whose_set_line_takes_the_wrong_answer_is_reported_for_both_gates(self):
        """The line after the test of the test answer must be the one that takes THAT answer: a gate whose next line is any `set ` line
        passed the first version of the rule (CodeRabbit, PR 537)."""
        for old, new in (('  set "HP_SYSBUILD_RAW=%HP_TEST_SYSBUILD_ANSWER%"\n', '  set "HP_SYSBUILD_RAW=n"\n'),
                         ('  set "HP_SYSBUILD_RAW=%HP_TEST_SYSBUILD_ANSWER%"\n', '  set "HP_SYSBUILD_RAW=%HP_TEST_SYSCON_ANSWER%"\n'),
                         ('  set "HP_SYSCON_CHOICE=%HP_TEST_SYSCON_ANSWER%"\n', '  set "HP_SYSCON_CHOICE=n"\n'),
                         ('  set "HP_SYSCON_CHOICE=%HP_TEST_SYSCON_ANSWER%"\n', '  set "HP_SYSCON_CHOICE=%HP_TEST_SYSBUILD_ANSWER%"\n')):
            with self.subTest(old=old, new=new):
                found = self.problems(mutate(self.batch, old, new))
                self.assertTrue(any("the next live line must be" in f for f in found), found)

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


class DocRulesCanFail(unittest.TestCase):
    """The rules about what the documents and the demo say are shown to fail on synthetic passages and on a synthetic batch file."""

    GOOD = "the stand-in does not verify the folder layout, the registry entries or the py launcher of a python.org installation."

    def test_each_spelling_of_the_overclaim_is_one_problem(self):
        for text in ("the layout differs from python.org's only in the path.",
                     "a real system Python differs only in the path; the bootstrapper takes sys.executable",
                     "not the python.org layout, which differs only in the path.",
                     "it DIFFERS   only\n in the path",
                     "the venv differs from the python.org layout only in its path"):
            with self.subTest(text=text):
                found = stand_in_problems([("doc", text, ())])
                self.assertEqual(len(found), 1, found)
                self.assertIn("only in its path", found[0])
                self.assertTrue(found[0].startswith("doc: "), found)

    def test_a_passage_without_the_words_it_must_hold_is_one_problem_per_word(self):
        self.assertEqual(stand_in_problems([("doc", "the layout is another one.", (NOT_VERIFIED,))]), ["doc: does not say 'does not verify'"])
        found = stand_in_problems([("header", "the stand-in does not verify the registry entries.", (NOT_VERIFIED,) + LIMIT_WORDS)])
        self.assertEqual(found, ["header: does not say 'folder layout'", "header: does not say 'py launcher'"])
        self.assertEqual(stand_in_problems([("header", self.GOOD, (NOT_VERIFIED,) + LIMIT_WORDS)]), [])
        self.assertEqual(stand_in_problems([("header", self.GOOD.upper(), (NOT_VERIFIED,) + LIMIT_WORDS)]), [])

    def test_a_passage_that_was_not_found_is_reported_and_not_passed(self):
        found = stand_in_problems([("doc", None, (NOT_VERIFIED,))])
        self.assertEqual(len(found), 1, found)
        self.assertIn("was not found", found[0])

    def test_the_pieces_that_cut_a_passage_out_of_a_document_say_when_they_find_none(self):
        self.assertIsNone(line_with("a\nb\n", "x"))
        self.assertIsNone(line_with("x\nx\n", "x"))
        self.assertEqual(line_with("a\n  b  c \n", "b"), "b c")
        text = "- **Mark.** one\n  two\n- **Other.** three\n"
        self.assertEqual(bullet_of(text, "- **Mark.**"), "- **Mark.** one two")
        self.assertIsNone(bullet_of(text, "- **Nope.**"))
        self.assertIsNone(bullet_of(text + text, "- **Mark.**"))
        self.assertEqual(slice_of("pre Stated: x y. Evidence z", "Stated:", "Evidence"), "Stated: x y.")
        self.assertIsNone(slice_of("pre Stated: x y.", "Stated:", "Evidence"))
        self.assertIsNone(slice_of("none", "Stated:", "Evidence"))
        head = "# ASCII only\n# first\n#\n# Limits, stated so that\n#   more words\n#\n# next paragraph registry\nparam()\n$x = 1\n"
        self.assertEqual(limits_paragraph(head), "Limits, stated so that more words")
        self.assertIsNone(limits_paragraph("# nothing\nparam()\n"))
        self.assertNotIn("$x", script_header(head))

    def test_a_demo_that_misses_a_line_of_the_offer_is_one_problem_naming_it(self):
        echoes = ["*** one ***", "*** two ***", "*** three ***", "*** four ***"]
        declined = "[INFO] Optimized build: declined. Nothing was built."
        section = "### Scenario 9: x\n\n```\n" + "\n".join("  " + e for e in echoes) + "\n" + declined + "\n```\n"
        self.assertEqual(demo_problems(section, 9, echoes, declined), [])
        self.assertEqual(demo_problems(section, 9, echoes, ""), [])
        for gone in echoes + [declined]:
            with self.subTest(gone=gone):
                found = demo_problems(section.replace(gone, "x"), 9, echoes, declined)
                self.assertEqual(len(found), 1, found)
                self.assertIn(gone, found[0])
        found = demo_problems(section.replace(declined, "[INFO] Optimized build: declined."), 9, echoes, declined)
        self.assertEqual(len(found), 1, found)
        self.assertIn("Nothing was built.", found[0])
        found = demo_problems(None, 9, echoes, declined)
        self.assertEqual(len(found), 1, found)
        self.assertIn("not compared", found[0])
        found = demo_problems(section, 9, echoes[:3], declined)
        self.assertEqual(len(found), 1, found)
        self.assertIn("not compared", found[0])

    def test_a_scenario_is_cut_at_the_next_scenario_heading(self):
        demo = "### Scenario 4: a\nA\n### Scenario 5: b\nB\n### Scenario 6: c\nC\n"
        self.assertEqual(demo_section(demo, 5), "### Scenario 5: b\nB\n")
        self.assertEqual(demo_section(demo, 6), "### Scenario 6: c\nC\n")
        self.assertIsNone(demo_section(demo, 7))

    def test_the_offer_is_read_from_the_batch_file_as_the_echo_lines_before_the_question_and_the_log_line_of_the_answer_no(self):
        batch = "\r\n".join([":offer_optimized_build", "echo.", "echo *** one ***", "echo *** two ***", "rem echo *** gone ***",
                             'set "HP_OPTBUILD_RAW="', "echo *** after the question ***",
                             'call :log "[INFO] Optimized build: declined. Nothing was built."', ":next", "echo *** other label ***", ""])
        self.assertEqual(optimized_build_offer(batch), (["*** one ***", "*** two ***"], "[INFO] Optimized build: declined. Nothing was built."))
        self.assertEqual(optimized_build_offer("echo hi\r\n"), ([], ""))


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

    def test_a_run_that_stops_recording_its_public_or_judging_it_is_caught(self):
        bad = mutate(self.script, "    'set PUBLIC>\"~accept_public.txt\"',\n", "")
        self.assertTrue(any("no longer records the PUBLIC the bootstrapper saw" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "-PublicRecord $publicRecord -PublicWanted $publicDir)", "-PublicRecord '' -PublicWanted $publicDir)")
        self.assertTrue(any("no longer judged by Get-IsolationProblems" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$acceptProblems = @($isolationProblems) + @($acceptProblems)\n", "")
        self.assertTrue(any("no longer includes the problems of the PUBLIC" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$publicDir   = $appDir + '_public'\n", "$publicDir   = $appDir\n")
        self.assertTrue(any("no longer named from the folder of the program" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_run_that_does_not_get_a_public_of_its_own_is_caught(self):
        set_line = "    ('set \"PUBLIC=' + $publicDir + '\"'),\n"
        record_line = "    'set PUBLIC>\"~accept_public.txt\"',\n"
        self.assertEqual(self.script.count(set_line), 1)
        bad = mutate(self.script, set_line, "")
        self.assertTrue(any("no longer gives the bootstrapper a PUBLIC of its own" in f for f in self.problems(bad)), self.problems(bad))
        late = mutate(self.script, set_line + record_line, record_line + set_line)
        self.assertTrue(any("recorded before it is set" in f for f in self.problems(late)), self.problems(late))
        # the folder is made empty by Reset-Folder; a run that stops clearing it, or makes it without emptying it, is caught
        clear = "if (-not $resetProblem) { $resetProblem = Reset-Folder -Path $publicDir -Create }\n"
        bad = mutate(self.script, clear, "")
        found = self.problems(bad)
        self.assertTrue(any("no longer cleared by Reset-Folder -Path $publicDir -Create" in f for f in found), found)
        bad = mutate(self.script, clear, "New-Item -ItemType Directory -Force -Path $publicDir | Out-Null\n")
        found = self.problems(bad)
        self.assertTrue(any("no longer cleared by Reset-Folder -Path $publicDir -Create" in f for f in found), found)

    def test_a_launch_file_that_records_the_public_with_echo_is_caught(self):
        """An echo of PUBLIC=%PUBLIC% is cut at an ampersand of the folder name, which cmd.exe takes for a command separator (CodeRabbit,
        PR 537); set PUBLIC> prints the value as it is."""
        bad = mutate(self.script, "    'set PUBLIC>\"~accept_public.txt\"',\n", "    '>\"~accept_public.txt\" echo PUBLIC=%PUBLIC%',\n")
        found = self.problems(bad)
        self.assertTrue(any("records the PUBLIC with echo" in f for f in found), found)
        self.assertTrue(any("no longer records the PUBLIC the bootstrapper saw with set PUBLIC>" in f for f in found), found)

    def test_folders_that_are_no_longer_cleared_or_whose_failure_is_not_seen_are_caught(self):
        """CodeRabbit, PR 537: the first version removed the folders with -ErrorAction SilentlyContinue and made them with New-Item -Force,
        which does not empty a folder; a folder that cannot be cleared must end the run with a red row before anything is built."""
        for call in ("$resetProblem = Reset-Folder -Path $venvDir\n",
                     "if (-not $resetProblem) { $resetProblem = Reset-Folder -Path $appDir -Create }\n",
                     "if (-not $resetProblem) { $resetProblem = Reset-Folder -Path $publicDir -Create }\n"):
            with self.subTest(call=call):
                found = self.problems(mutate(self.script, call, ""))
                self.assertTrue(any("is no longer cleared by" in f for f in found), found)
        found = self.problems(mutate(self.script, "if ($resetProblem) {\n", "if ($resetProblemX) {\n"))
        self.assertTrue(any("no longer stops the run: if ($resetProblem) { is missing" in f for f in found), found)
        found = self.problems(mutate(self.script, "    exit 1\n}\n\n$venvOut = @(& $basePython -m venv $venvDir 2>&1)", "}\n\n$venvOut = @(& $basePython -m venv $venvDir 2>&1)"))
        self.assertTrue(any("no longer ends the run with a red row and exit 1: exit 1 is missing" in f for f in found), found)
        found = self.problems(mutate(self.script, "Write-AllRows -Pass $false -Desc 'system-Python EXE build accepted: a folder left by an earlier run could not be cleared'",
                                     "Write-Host 'system-Python EXE build accepted: a folder left by an earlier run could not be cleared'"))
        self.assertTrue(any("no longer ends the run with a red row and exit 1: Write-AllRows -Pass $false is missing" in f for f in found), found)
        # the clearing after the private interpreter was made would remove it again
        moved = mutate(self.script, "$venvOut = @(& $basePython -m venv $venvDir 2>&1)\n", "")
        moved = mutate(moved, "$resetProblem = Reset-Folder -Path $venvDir\n",
                       "$venvOut = @(& $basePython -m venv $venvDir 2>&1)\n$resetProblem = Reset-Folder -Path $venvDir\n")
        self.assertTrue(any("made before the folders were cleared" in f for f in self.problems(moved)), self.problems(moved))
        # a removal that silences its errors is the defect itself
        quiet = mutate(self.script, "Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop", "Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue")
        found = self.problems(quiet)
        self.assertTrue(any("silences its errors" in f for f in found), found)
        self.assertTrue(any("Reset-Folder no longer removes the folder with -ErrorAction Stop" in f for f in found), found)

    def test_a_verdict_that_stops_handing_the_whole_interpreter_path_to_the_judge_is_caught(self):
        """The interpreter is compared as a whole path, so the verdict must hand the judge the path and not the name of its folder."""
        bad = mutate(self.script, "-VenvPython $venvPython -ExeName $exeName", "-VenvPython $venvName -ExeName $exeName")
        self.assertTrue(any("-VenvPython $venvPython" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_wording_row_that_is_not_judged_for_a_completed_build_is_caught(self):
        """CodeRabbit, PR 537: a console cut off before the end of the build has fewer lines to judge and every line can follow the rule."""
        wire = "$completionProblems = @(Get-CompletionProblems -Finished ([bool]$launch.Finished) -ConsoleText $console)\n"
        merge = "$wordingProblems = @($completionProblems) + @($wordingProblems)\n"
        found = self.problems(mutate(self.script, wire, ""))
        self.assertTrue(any("Get-CompletionProblems is not called" in f for f in found), found)
        found = self.problems(mutate(self.script, merge, ""))
        self.assertTrue(any("no longer part of the row of self.sysbuild.wording" in f for f in found), found)
        late = mutate(self.script, merge, "")
        late = mutate(late, "$pass = [bool](@($wordingProblems).Count -eq 0)\n", "$pass = [bool](@($wordingProblems).Count -eq 0)\n" + merge)
        found = self.problems(late)
        self.assertTrue(any("added to the row of self.sysbuild.wording after its verdict was taken" in f for f in found), found)

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

    def test_a_step_that_only_names_the_script_without_running_it_is_caught(self):
        """The step is found by the script's name, so a comment or an echo that holds the name must not stand in for the line that runs it
        (CodeRabbit, PR 537)."""
        block = step_block(self.workflow, SCRIPT_NAME)
        run_line = "          & tests\\" + SCRIPT_NAME
        self.assertEqual(block.count(run_line), 1, "the step runs the script on one line")
        for new in ("          # & tests\\" + SCRIPT_NAME, "          echo tests\\" + SCRIPT_NAME, "          Write-Host 'tests\\" + SCRIPT_NAME + "'"):
            with self.subTest(line=new):
                bad = self.workflow.replace(block, block.replace(run_line, new))
                found = workflow_problems(bad)
                self.assertTrue(any("no live line that runs" in f for f in found), found)

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
class ResetFolderBehavior(unittest.TestCase):
    """Reset-Folder makes a folder of the run empty, or says why it could not (CodeRabbit, PR 537). The first version of the script removed
    the folders with -ErrorAction SilentlyContinue and made them with New-Item -Force, which does not empty a folder, so a folder that could
    not be removed was used with its old content and nothing said so. The function runs on real folders."""

    @classmethod
    def setUpClass(cls):
        tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(tmp.cleanup)
        base = Path(tmp.name)
        cls.base = base
        (base / "full_create" / "sub").mkdir(parents=True)
        (base / "full_create" / "a.txt").write_text("a", encoding="ascii")
        (base / "full_create" / "sub" / "b.txt").write_text("b", encoding="ascii")
        (base / "full_plain").mkdir()
        (base / "full_plain" / "c.txt").write_text("c", encoding="ascii")
        (base / "a_file").write_text("not a folder", encoding="ascii")
        cases = [
            case("reset_missing_plain", "Reset-Folder", Path=str(base / "missing_plain")),
            case("reset_missing_create", "Reset-Folder", Path=str(base / "missing_create"), Create=True),
            case("reset_full_create", "Reset-Folder", Path=str(base / "full_create"), Create=True),
            case("reset_full_plain", "Reset-Folder", Path=str(base / "full_plain")),
            case("reset_under_a_file", "Reset-Folder", Path=str(base / "a_file" / "child"), Create=True),
        ]
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, ["Reset-Folder"], cases, d)

    def run_mutated(self, old, new, **args):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, new), encoding="utf-8")
            return run_cases(script, ["Reset-Folder"], [case("mutated", "Reset-Folder", **args)], d)["mutated"]

    def test_a_missing_folder_is_left_missing_or_made_and_a_full_one_is_removed_or_made_empty(self):
        for name in ("reset_missing_plain", "reset_missing_create", "reset_full_create", "reset_full_plain"):
            with self.subTest(case=name):
                self.assertEqual(self.r[name], [""])
        self.assertFalse((self.base / "missing_plain").exists())
        self.assertTrue((self.base / "missing_create").is_dir())
        self.assertTrue((self.base / "full_create").is_dir())
        self.assertEqual(list((self.base / "full_create").iterdir()), [])
        self.assertFalse((self.base / "full_plain").exists())

    def test_a_folder_that_cannot_be_made_is_reported_with_its_path(self):
        found = self.r["reset_under_a_file"]
        self.assertEqual(len(found), 1, found)
        self.assertIn("could not be made", found[0])
        self.assertIn("a_file", found[0])

    def test_a_folder_that_cannot_be_removed_is_reported_and_so_is_one_that_is_still_there(self):
        remove = "Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop"
        with tempfile.TemporaryDirectory() as d:
            victim = Path(d) / "victim"
            victim.mkdir()
            (victim / "x.txt").write_text("x", encoding="ascii")
            found = self.run_mutated(remove, "throw 'locked by another program'", Path=str(victim))
            self.assertEqual(len(found), 1, found)
            self.assertIn("could not be removed", found[0])
            self.assertIn("locked by another program", found[0])
            self.assertIn(str(victim), found[0])
            found = self.run_mutated(remove, "[void]0", Path=str(victim))
            self.assertEqual(len(found), 1, found)
            self.assertIn("is still there after it was removed", found[0])

    def test_a_folder_that_does_not_exist_after_it_was_made_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            found = self.run_mutated("[void][System.IO.Directory]::CreateDirectory($Path)", "[void]0", Path=str(Path(d) / "made"), Create=True)
        self.assertEqual(len(found), 1, found)
        self.assertIn("does not exist after it was made", found[0])


@unittest.skipUnless(PWSH, "pwsh not available")
class CompletionJudge(unittest.TestCase):
    """Get-CompletionProblems: the wording row is judged only for a run that went through the accepted build (CodeRabbit, PR 537)."""

    FUNCTIONS = ["Measure-ConsoleLines", "Get-CompletionProblems"]

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, cls.FUNCTIONS, completion_cases(), d)

    def test_a_console_of_the_accepted_build_has_no_problem(self):
        self.assertEqual(self.r["completion_good"], [])

    def test_a_bootstrapper_that_did_not_finish_is_reported(self):
        found = self.r["completion_unfinished"]
        self.assertEqual(len(found), 1, found)
        self.assertTrue(found[0].startswith("console wording of the accepted build: "), found)
        self.assertIn("the bootstrapper did not finish within the time limit", found[0])

    def test_each_marker_of_a_completed_build_is_required_on_its_own(self):
        for name, label in COMPLETION_MARKERS:
            with self.subTest(case=name):
                found = self.r[name]
                self.assertEqual(len(found), 1, found)
                self.assertIn("the console has no line for " + label, found[0])
                self.assertIn("did not complete the accepted build", found[0])

    def test_a_console_that_stops_after_the_start_of_the_build_gives_the_three_problems(self):
        found = self.r["completion_cut_after_the_start_of_the_build"]
        self.assertEqual(len(found), 3, found)

    def test_a_judge_that_stops_checking_is_caught(self):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        for comparison, name, needle in (("$Finished -eq $false", "completion_unfinished", "did not finish within the time limit"),
                                         ("$found -lt 1", "completion_no_build_line", "the console has no line for")):
            with self.subTest(comparison=comparison):
                self.assertTrue(any(needle in f for f in self.r[name]), (name, self.r[name]))
                old = "if (" + comparison + ") {"
                self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
                with tempfile.TemporaryDirectory() as d:
                    script = Path(d) / "mutated.ps1"
                    script.write_text(text.replace(old, "if ($false) {"), encoding="utf-8")
                    got = run_cases(script, self.FUNCTIONS, [cs for cs in completion_cases() if cs["name"] == name], d)
                self.assertFalse(any(needle in f for f in got[name]), (name, got[name]))


@unittest.skipUnless(sys.platform == "win32" and PWSH, "needs cmd.exe and pwsh")
class LaunchFileRecordsPublic(unittest.TestCase):
    """The launch file records the PUBLIC the bootstrapper saw with a line that cmd.exe cannot split (CodeRabbit, PR 537): in a folder
    name that holds an ampersand, as in C:\\Build&QA, an `echo PUBLIC=%PUBLIC%` is cut at the ampersand and the judge then saw
    PUBLIC=C:\\Build. This runs the script's own record line under cmd.exe on a PUBLIC like that and hands what it wrote to the judge."""

    def test_the_recorded_public_is_the_whole_value_when_the_folder_name_holds_an_ampersand(self):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        records = re.findall(r"(?m)^\s*'([^'\n]*~accept_public\.txt[^'\n]*)',?\s*$", text)
        self.assertEqual(len(records), 1, records)
        wanted = "C:\\Build&QA\\~selftest_public"
        with tempfile.TemporaryDirectory() as d:
            launch = Path(d) / "launch.cmd"
            launch.write_bytes(text_of(["@echo off", 'set "PUBLIC=%s"' % wanted, records[0]]).encode("ascii"))
            subprocess.run("cmd.exe /d /c call launch.cmd", cwd=d, capture_output=True, text=True, timeout=60)
            recorded = (Path(d) / "~accept_public.txt").read_text(encoding="ascii", errors="replace")
            got = run_cases(SCRIPT, ["Get-IsolationProblems"],
                            [case("recorded", "Get-IsolationProblems", PublicRecord=recorded, PublicWanted=wanted)], d)
        self.assertEqual(got["recorded"], [], (recorded, got["recorded"]))


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
            ("$used -ine $VenvPython.Trim()", "accept_not_the_private_interpreter", "not the private one"),
            ("$n -gt 0", "accept_never_0", "saying the build consent was declined"),
            ("$readyAt -lt 0", "accept_no_ready_line", "no post-flight panel line"),
            ("$next -ine $want", "accept_other_exe_under_the_ready_line", "the line under the ready line of the panel is"),
            ("-not $ExeExists", "accept_no_exe", "does not exist after the run"),
            ("$RunOutText.IndexOf($ProgramLine, [System.StringComparison]::Ordinal) -lt 0", "accept_run_output_without_the_line", "~run.out.txt does not hold"),
            ("$state -ne 'degraded_env'", "accept_status_state_ok", "expected degraded_env"),
            ("$code -ne '0'", "accept_status_exit_code_1", "exitCode '1', expected 0"),
            ("$seen -eq ''", "isolation_empty_value", "the launch file recorded no PUBLIC"),
            ("$seen -ine $want", "isolation_runner_public", "the bootstrapper saw PUBLIC"),
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
