"""Item 110 (README REQ-018.36): the verification run of the optimized build ends after 30 seconds and leaves nothing running.

The prompt of :offer_optimized_build and the log line of PVW_BUILDER=both tell the user that building starts the program once more
"for up to 30 seconds" (README REQ-018.8, REQ-018.35 and REQ-018.36). The shall behind that sentence is carried by one inline
PowerShell line of :offer_optimized_build in run_setup.bat. The first version of the line waited 30 seconds, called Process.Kill() on
the process it started and then read the output without a limit. A Nuitka onefile EXE is two processes, the bootstrap that is started
and the program it starts; Kill() ends the first, the second keeps the output pipes open, and the read waited until the program ended
by itself, so a program that keeps printing held the bootstrapper for as long as it ran and was left running behind it. The repair
loop's line had the same defect until Item 106 (tests/test_repair_cap.py); this line was found with it and left (CLAUDE.md Item 110).
The line now ends the whole process tree with taskkill /F /T, keeps Kill() as the fallback when taskkill cannot be started, and waits
for each pipe for at most 5 seconds.

What really happens is shown on Windows by tests/selfapps_optbuild_cap.ps1 (row self.optbuild.cap; contract-uv lane, gating): it cuts
the real lines out of run_setup.bat, runs them under cmd.exe against a stand-in with the same shape as the real program (a .cmd that
starts a PowerShell program which keeps printing), and reads the program's own clock and the process list. These rules read
run_setup.bat, the script, batch-check.yml and docs/agent-ndjson.md as text, run the script's own judging function through a real pwsh
on synthetic runs (a run that passes, and one run for each way to be wrong), and run the line's own PowerShell text through pwsh
against stand-in programs on a POSIX host, with the first version of the line as the control that must show the defect. A reworded
line, a stop that no longer ends the tree, a read without a limit, a scenario that stops being the one the shall names, a judge that
stops judging or a step that stops gating fails here with a sentence, before a Windows run is needed. Synthetic cases prove each rule
can fail. The shared helpers are in tests/judge_support.py.
"""
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import (PWSH, HARD_TIMEOUT, case, cut_block, lines_of, live_bat, live_hash, mutate, norm,  # noqa: E402
                           registry_ids, run_cases, step_block, variables_in)

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_optbuild_cap.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SCRIPT_NAME = "selfapps_optbuild_cap.ps1"

ROW_ID = "self.optbuild.cap"
ROW_REQ = "REQ-018.36"
JUDGES = ["Get-OptCapProblems"]

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~optbuild_cap_evidence.txt",
    "tests/~selftest_optbuildcap/*/~driver*",
    "tests/~selftest_optbuildcap/*/~optcap_ledger.txt",
)

# The two lines of the batch file the script cuts the block between, and the one line inside it that runs the program.
CUT_START = 'set "HP_OPTBUILD_VERIFY_EXIT=-1"'
CUT_END = 'if not "%HP_OPTBUILD_VERIFY_EXIT%"=="0" ('
EXE_LINE = 'set "HP_OPTBUILD_EXE=%CD%\\dist\\%HP_OPTBUILD_TMP%"'
# Every variable the cut block reads or sets; the script's driver sets or clears each of them (CD is the scenario folder).
KNOWN_VARIABLES = {"HP_OPTBUILD_VERIFY_EXIT", "HP_OPTBUILD_EXE", "HP_OPTBUILD_TMP", "CD"}

# The pieces of the PowerShell text of the line, in the order they must stand in it.
START_READS = "$so=$p.StandardOutput.ReadToEndAsync();$se=$p.StandardError.ReadToEndAsync();"
WAIT = "$done=$p.WaitForExit(30000);"
TREE_EXE = "$k.FileName=$env:SystemRoot+'\\System32\\taskkill.exe'"
TREE_ARGS = "$k.Arguments='/F /T /PID '+$p.Id"
TREE_KILL = "[System.Diagnostics.Process]::Start($k).WaitForExit(5000)"
FALLBACK_KILL = "try{$p.Kill()}catch{}"
BOUNDED_READS = "try{[void]$so.Wait(5000);[void]$se.Wait(5000)}catch{};"
RESULT_TAIL = "if($done){$p.ExitCode}else{-1}"
APP_ARGS = "if($env:HP_APP_ARGS){$si.Arguments=$env:HP_APP_ARGS};"
# The characters that must not appear in that text: a quote ends it, % and ! are expanded, ^ is cmd's escape, < > & are operators.
CMD_CHARACTERS = '"%^!<>&'

# The line as it stands after the fix: the PowerShell text between -Command " and the quote in front of the backtick. The cases that
# mutate the line use it as their fixture, so they run the same way before and after the fix.
GOOD_TEXT = (
    "$si=New-Object System.Diagnostics.ProcessStartInfo;$si.FileName=$env:HP_OPTBUILD_EXE;" + APP_ARGS +
    "$si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;"
    "$p=[System.Diagnostics.Process]::Start($si);" + START_READS + WAIT +
    "if(-not $done){try{$k=New-Object System.Diagnostics.ProcessStartInfo;" + TREE_EXE + ";" + TREE_ARGS +
    ";$k.UseShellExecute=$false;$k.CreateNoWindow=$true;$k.RedirectStandardOutput=$true;$k.RedirectStandardError=$true;[void]" +
    TREE_KILL + "}catch{};" + FALLBACK_KILL + "};" + BOUNDED_READS + RESULT_TAIL
)
BAT_HEAD = 'for /f "usebackq delims=" %%X in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "'
BAT_TAIL = '"`) do set "HP_OPTBUILD_VERIFY_EXIT=%%X"'

# The first version of the line (Item 110, before the fix): Kill() of the process it started and then both results read without a
# limit. It is the control of the stand-in: the defect has to show here, or the stand-in proves nothing about the fix.
FIRST_VERSION_OF_THE_LINE = (
    "$si=New-Object System.Diagnostics.ProcessStartInfo;$si.FileName=$env:HP_OPTBUILD_EXE;" + APP_ARGS +
    "$si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;"
    "$p=[System.Diagnostics.Process]::Start($si);" + START_READS + WAIT +
    "if(-not $done){try{$p.Kill()}catch{}};$so.Result|Out-Null;$se.Result|Out-Null;" + RESULT_TAIL
)


def inline_command(line):
    """The PowerShell text of a `for /f ... in (`powershell ... -Command "<text>"`) ...` line: what stands between -Command " and the
    quote that closes it in front of the backtick. cmd reads the line first, so this text may hold none of CMD_CHARACTERS. Raises
    ValueError when the line has another shape."""
    marker = '-Command "'
    start = line.index(marker) + len(marker)
    end = line.rindex('"`)')
    if end < start:
        raise ValueError("the closing quote comes before the opening one")
    return line[start:end]


# --- the PowerShell text of the line -----------------------------------------------------------------------------------------------

def line_text_problems(text):
    """The pins on the line's PowerShell text: both reads start before the wait, the wait is 30 seconds, then the whole process tree
    is ended (taskkill /F /T on the id of the process it started, at most 5 seconds) with Kill() as the fallback, then each pipe is
    waited for at most 5 seconds and never read without a limit, and the last thing printed is the exit code, or -1 for a run that
    did not finish."""
    wait = text.find(WAIT)
    if wait < 0:
        return ["the PowerShell text of the line no longer waits for the process with $done=$p.WaitForExit(30000)"]
    found = []
    starts = text.find(START_READS)
    if starts < 0 or starts > wait:
        found.append("the two asynchronous reads of the program's output no longer start before the 30 second wait, so a program "
                     "that fills a pipe could block on it")
    tree = text.find(TREE_KILL)
    arguments = text.find(TREE_ARGS)
    if tree < wait or arguments < wait or arguments > tree or TREE_EXE not in text:
        found.append("the stop after the 30 second wait no longer ends the whole process tree: taskkill.exe from System32 with /F /T /PID "
                     "and the id of the process the line started, waited for at most 5 seconds")
    fallback = text.find(FALLBACK_KILL)
    if fallback < 0 or fallback < tree:
        found.append("the process the line started is no longer killed as the fallback after the taskkill attempt ($p.Kill())")
    reads = text.find(BOUNDED_READS)
    if reads < 0 or text.count("Wait(5000)") != 2:
        found.append("the output is no longer waited for through two waits of at most 5 seconds ([void]$so.Wait(5000);[void]$se.Wait(5000)), "
                     "so a program that keeps a pipe open could hold the line until it ends by itself")
    elif reads < max(fallback, tree):
        found.append("the output is waited for before the process is stopped, so a program that keeps printing is waited for and not stopped")
    if ".Result" in text:
        found.append("the output is read with .Result, which waits without a limit for a pipe that a program below the process keeps open")
    if text.count("ReadToEndAsync") != 2:
        found.append("the output of the run is no longer read through the two asynchronous reads that keep the pipes empty")
    if not text.endswith(RESULT_TAIL):
        found.append("a run that did not finish within 30 seconds no longer gives the exit code -1, as the last thing the line prints")
    if "$si.FileName=$env:HP_OPTBUILD_EXE;" not in text or APP_ARGS not in text:
        found.append("the line no longer starts the file named by HP_OPTBUILD_EXE with the arguments of HP_APP_ARGS")
    held = "".join(sorted(set(CMD_CHARACTERS) & set(text)))
    if held:
        found.append("the PowerShell text of the line holds the cmd character(s) %s, which cmd reads before PowerShell does" % held)
    return found


# --- the batch file: what the script assumes about the block ---------------------------------------------------------------------------

def block_problems(batch):
    """README REQ-018.36 in the batch file: the block the script cuts out exists once, reaches only what its driver defines, holds one
    live line that waits 30 seconds, treats a result that is not 0 as a failed verification and keeps the original EXE."""
    stripped = [ln.strip() for ln in lines_of(batch)]
    found = []
    for label in (":offer_optimized_build", ":optbuild_cleanup"):
        n = sum(1 for ln in stripped if ln == label)
        if n != 1:
            found.append("the label %s appears %d time(s); expected exactly once" % (label, n))
    for line in (CUT_START, CUT_END):
        n = sum(1 for ln in stripped if ln == line)
        if n != 1:
            found.append("the line %s appears %d time(s); the script cuts the block between it and the other line, so each must stand once" % (line, n))
    if found:
        return found
    block = cut_block(batch, CUT_START, CUT_END)
    if block is None:
        return ["the block from %s to %s cannot be cut" % (CUT_START, CUT_END)]
    body = [ln.strip() for ln in live_bat(block)]
    reach = sorted(variables_in(block) - KNOWN_VARIABLES)
    if reach:
        found.append("the block reads or sets %s, which the script's driver does not define" % ", ".join(reach))
    jumps = [ln for ln in body if re.match(r"(?i)(call|goto)\b", ln) or ln.startswith(":")]
    if jumps:
        found.append("the block calls or jumps (%s), which the script's driver has no label for" % jumps[0][:40])
    if EXE_LINE not in body:
        found.append("the block no longer names the EXE by %s, so the stand-in in dist would not be the one it starts" % EXE_LINE)
    runs = [ln for ln in body if "WaitForExit(30000)" in ln]
    if len(runs) != 1:
        found.append("the block must hold exactly one live line with WaitForExit(30000), the 30 second cap; found %d" % len(runs))
    else:
        try:
            found.extend(line_text_problems(inline_command(runs[0])))
        except ValueError:
            found.append("the line that runs the program is no longer a for /f line that hands PowerShell one -Command \"...\" text")
        at = body.index(runs[0])
        if not body[at - 1] == EXE_LINE:
            found.append("the line that runs the program no longer stands directly under the line that names the EXE")
        if body[at + 1:at + 3] != ['set "HP_OPTBUILD_EXE="', 'if not defined HP_OPTBUILD_VERIFY_EXIT set "HP_OPTBUILD_VERIFY_EXIT=-1"']:
            found.append("a run whose result could not be read no longer counts as -1 right after the line (the default line must follow it)")
    # what a result other than 0 does, in the real file, after the cut: the original EXE is kept
    at = stripped.index(CUT_END)
    after = [ln for ln in stripped[at + 1:at + 6] if ln and not re.match(r"(?i)rem\b", ln)]
    if len(after) < 2 or not after[0].startswith('call :log "[WARN] Optimized build verification did not pass (exit %HP_OPTBUILD_VERIFY_EXIT%)') \
            or after[1] != "goto :optbuild_cleanup":
        found.append("a result other than 0 no longer logs the failed verification and goes to :optbuild_cleanup, which keeps the original EXE")
    return found


# --- the script --------------------------------------------------------------------------------------------------------------------------

SCENARIO_RE = re.compile(r"\[pscustomobject\]@\{ Name = '(\w+)'; Ticks = (\d+); ExpectExit = '(-?\d+)'; ExpectDone = \$(true|false); "
                         r"MinTicks = (\d+); MinSpan = (\d+); MaxSpan = (\d+); MaxSeconds = (\d+) \}")
JUDGE_ARGS = ("-Finished ([bool]$run.Finished)", "-Seconds ([int]$run.Seconds)", "-ResultText $run.Result", "-LedgerText $run.Ledger",
              "-LeftoverChecked ([bool]$run.LeftoverChecked)", "-Leftover @($run.Leftover)", "-ExpectExit $Scenario.ExpectExit",
              "-ExpectDone ([bool]$Scenario.ExpectDone)", "-MinTicks ([int]$Scenario.MinTicks)", "-MinSpan ([double]$Scenario.MinSpan)",
              "-MaxSpan ([double]$Scenario.MaxSpan)", "-MaxSeconds ([int]$Scenario.MaxSeconds)")


def script_problems(text):
    t = norm(text)
    flat = "\n".join(live_hash(t))
    found = []
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if ids != [ROW_ID] * 3:
        found.append("the row id must be the literal %r at each of the three Write-NdjsonRow call sites, found %r" % (ROW_ID, ids))
    tags = re.findall(r"\bid = '%s'; req = '([^']*)'" % re.escape(ROW_ID), t)
    if tags != [ROW_REQ] * 3:
        found.append("the row must carry the literal req tag %r at each of the three call sites, found %r" % (ROW_REQ, tags))
    if "-StartLine 'set \"HP_OPTBUILD_VERIFY_EXIT=-1\"' -EndLine 'if not \"%HP_OPTBUILD_VERIFY_EXIT%\"==\"0\" ('" not in flat:
        found.append("the script no longer cuts the block between %s and %s" % (CUT_START, CUT_END))
    if "'set \"HP_OPTBUILD_TMP=optcap_stand_in.cmd\"'" not in flat:
        found.append("the driver no longer names the stand-in program through HP_OPTBUILD_TMP")
    if "call ~driver.bat > ~driver_console.txt 2>&1 < nul" not in flat:
        found.append("the driver no longer runs with standard input closed (< nul) and its console in ~driver_console.txt")
    if "-LimitMs 150000" not in flat:
        found.append("the driver no longer has the 150 second limit that turns a line that does not return into a red row")
    if "& taskkill.exe /F /T /PID $p.Id" not in flat:
        found.append("a driver that outlives its limit is no longer stopped with taskkill /F /T")
    scenarios = {m.group(1): m.groups()[1:] for m in SCENARIO_RE.finditer(t)}
    if sorted(scenarios) != ["cap", "exit"]:
        found.append("the script must hold the two scenarios cap and exit, each as one [pscustomobject] line; found %s" % sorted(scenarios))
    else:
        ticks, expect_exit, expect_done, min_ticks, min_span, max_span, max_seconds = scenarios["cap"]
        if int(ticks) < 90 or int(ticks) <= int(max_seconds):
            found.append("the cap scenario must print for far longer than the cap (at least 90 lines, more than its time limit), "
                         "or a run that was not stopped looks the same as one that was")
        if expect_exit != "-1" or expect_done != "false":
            found.append("the cap scenario must expect the exit code -1 and a program that never reached its last line")
        if int(min_span) < 10 or int(max_span) > 50 or int(max_seconds) >= 100:
            found.append("the cap scenario must hold the program's own clock to 10 to 50 seconds and the driver to under 100")
        ticks, expect_exit, expect_done, min_ticks, min_span, max_span, max_seconds = scenarios["exit"]
        if int(ticks) > 10 or expect_exit != "0" or expect_done != "true":
            found.append("the exit scenario is the control: a program that ends by itself must give 0 and reach its last line")
    # the program: a flushed line a second to the pipe and a ledger line, a last line only for a program that ends by itself
    for need in ("'    [Console]::Out.Flush()',", "'    Start-Sleep -Seconds 1',", "(''done '' + (Get-Stamp))", "(''tick '' + $i + '' '' + (Get-Stamp))",
                 "'powershell -NoProfile -ExecutionPolicy Bypass -File \"%OPTCAP_HOLDER%\"',"):
        if need not in flat:
            found.append("the stand-in program no longer holds %s" % need)
    if "Get-CimInstance -ClassName Win32_Process" not in flat or "$cl.Contains($Marker)" not in flat:
        found.append("the process list is no longer read through CIM for the processes whose command line names the holder script")
    else:
        read_at = flat.index("[void]$found.Add(")
        stop_at = flat.find("Stop-Process -Id $proc.ProcessId")
        if stop_at < 0 or stop_at < read_at:
            found.append("a program left running must be recorded before it is stopped, not after")
    if "$left = Get-LeftoverProcesses -Marker $holder" not in flat:
        found.append("the process list is no longer read for the holder script of the scenario")
    call = flat.split("$found = @(Get-OptCapProblems", 1)
    if len(call) != 2:
        found.append("the verdict no longer calls Get-OptCapProblems")
    else:
        args = " ".join(call[1].split("Add-Evidence", 1)[0].split())
        for need in JUDGE_ARGS:
            if need not in args:
                found.append("the verdict no longer hands %s to Get-OptCapProblems" % need)
    if "$pass = [bool]($problemsAll.Count -eq 0)" not in flat:
        found.append("the verdict is no longer taken from the list of problems ($pass = [bool]($problemsAll.Count -eq 0))")
    if not re.search(r"(?m)^function Get-OptCapProblems \{", t):
        found.append("the judging function Get-OptCapProblems is missing")
    if "OSVersion.Platform -ne [System.PlatformID]::Win32NT" not in flat or re.search(r"\$IsWindows\b", flat):
        found.append("the Windows check must use OSVersion.Platform and not $IsWindows")
    if "skip = $true" not in flat:
        found.append("the row no longer skips off Windows with skip = $true")
    if "if (-not $pass) { exit 1 }" not in flat:
        found.append("the script no longer exits 1 for a red row")
    live = live_hash(t)
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0")
    if any(ord(ch) > 127 for ch in text):
        found.append("the script holds a character that is not ASCII")
    return found


# --- the workflow and the registry -------------------------------------------------------------------------------------------------------

def workflow_problems(text):
    block = step_block(text, SCRIPT_NAME)
    if block is None:
        return ["no step runs tests\\%s" % SCRIPT_NAME]
    found = []
    if STEP_IF not in block:
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
    return [] if ROW_ID in registry_ids(text) else ["%s is not in docs/agent-ndjson.md" % ROW_ID]


# --- the judging function, run through a real pwsh -----------------------------------------------------------------------------------------

STAMP = 1700000000000


def ledger_text(ticks, span, done=False):
    """A ledger as the stand-in program writes it: a start line, `ticks` lines whose clock runs `span` seconds from the first to the last,
    and a done line when the program ended by itself."""
    rows = ["start 4242 %d" % STAMP]
    first = STAMP + 1500
    for i in range(ticks):
        at = first + (round(i * span * 1000 / (ticks - 1)) if ticks > 1 else 0)
        rows.append("tick %d %d" % (i + 1, at))
    if done:
        rows.append("done %d" % (first + round(span * 1000) + 1000))
    return "\r\n".join(rows) + "\r\n"


def result_text(code="-1", end=True, with_code=True):
    rows = ["START"]
    if with_code:
        rows.append("VERIFY_EXIT=%s" % code)
    if end:
        rows.append("END")
    return "\r\n".join(rows) + "\r\n"


def cap_args(**over):
    """A run of the cap scenario that is good: ended near the cap, nothing left running."""
    args = dict(Scenario="cap", Finished=True, Seconds=34, ResultText=result_text("-1"), LedgerText=ledger_text(29, 28.0),
                LeftoverChecked=True, Leftover=[], ExpectExit="-1", ExpectDone=False, MinTicks=10, MinSpan=15, MaxSpan=50, MaxSeconds=75)
    args.update(over)
    return args


def exit_args(**over):
    """A run of the exit scenario that is good: the program ended by itself with 0."""
    args = dict(Scenario="exit", Finished=True, Seconds=6, ResultText=result_text("0"), LedgerText=ledger_text(3, 2.0, done=True),
                LeftoverChecked=True, Leftover=[], ExpectExit="0", ExpectDone=True, MinTicks=3, MinSpan=0, MaxSpan=20, MaxSeconds=60)
    args.update(over)
    return args


def judge_cases():
    c = []
    c.append(case("cap_good", "Get-OptCapProblems", **cap_args()))
    c.append(case("exit_good", "Get-OptCapProblems", **exit_args()))
    c.append(case("cap_span_at_the_upper_edge", "Get-OptCapProblems", **cap_args(LedgerText=ledger_text(51, 50.0))))
    c.append(case("cap_span_at_the_lower_edge", "Get-OptCapProblems", **cap_args(LedgerText=ledger_text(16, 15.0))))
    c.append(case("cap_unfinished", "Get-OptCapProblems", **cap_args(Finished=False)))
    c.append(case("cap_no_end", "Get-OptCapProblems", **cap_args(ResultText=result_text("-1", end=False))))
    c.append(case("cap_no_exit_code", "Get-OptCapProblems", **cap_args(ResultText=result_text(with_code=False))))
    c.append(case("cap_exit_zero", "Get-OptCapProblems", **cap_args(ResultText=result_text("0"))))
    c.append(case("exit_minus_one", "Get-OptCapProblems", **exit_args(ResultText=result_text("-1"))))
    c.append(case("cap_too_few_ticks", "Get-OptCapProblems", **cap_args(LedgerText=ledger_text(4, 20.0))))
    c.append(case("cap_program_ended_by_itself", "Get-OptCapProblems", **cap_args(LedgerText=ledger_text(29, 28.0, done=True))))
    c.append(case("exit_never_done", "Get-OptCapProblems", **exit_args(LedgerText=ledger_text(3, 2.0))))
    c.append(case("cap_span_over", "Get-OptCapProblems", **cap_args(LedgerText=ledger_text(52, 51.0))))
    c.append(case("cap_span_under", "Get-OptCapProblems", **cap_args(LedgerText=ledger_text(10, 9.0))))
    c.append(case("exit_span_over_its_own_limit", "Get-OptCapProblems", **exit_args(LedgerText=ledger_text(3, 21.0, done=True))))
    c.append(case("cap_driver_too_slow", "Get-OptCapProblems", **cap_args(Seconds=76)))
    c.append(case("cap_driver_at_its_limit", "Get-OptCapProblems", **cap_args(Seconds=75)))
    c.append(case("cap_one_left_running", "Get-OptCapProblems", **cap_args(Leftover=["4242 powershell.exe"])))
    c.append(case("cap_two_left_running", "Get-OptCapProblems", **cap_args(Leftover=["4242 powershell.exe", "4243 powershell.exe"])))
    c.append(case("cap_process_list_unreadable", "Get-OptCapProblems", **cap_args(LeftoverChecked=False)))
    c.append(case("cap_unreadable_list_hides_the_leftovers", "Get-OptCapProblems",
                  **cap_args(LeftoverChecked=False, Leftover=["4242 powershell.exe"])))
    # the first version of the line on the real scenario: Kill() ended the stand-in .cmd, the holder kept the pipes, and the read
    # waited until the program ended by itself, so all 100 lines are on its clock, it reached done and the driver took 100 seconds
    c.append(case("cap_first_version_of_the_line", "Get-OptCapProblems",
                  **cap_args(Seconds=101, LedgerText=ledger_text(100, 99.0, done=True))))
    return c


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgeOnSyntheticRuns(unittest.TestCase):
    """The script's judging function on runs built here: a clean run passes and each kind of wrong run is reported with its own
    sentence. The function runs alone and in strict mode, so it cannot read the script's variables."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, JUDGES, judge_cases(), d)

    def only(self, name, needle):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        self.assertIn(needle, found[0], (name, found))

    def test_a_run_that_was_stopped_at_the_cap_and_left_nothing_behind_has_no_problem(self):
        for name in ("cap_good", "exit_good", "cap_span_at_the_upper_edge", "cap_span_at_the_lower_edge", "cap_driver_at_its_limit"):
            self.assertEqual(self.r[name], [], name)

    def test_a_driver_that_did_not_finish_or_did_not_reach_its_end_is_one_problem_and_nothing_else(self):
        self.only("cap_unfinished", "the driver did not finish within the time limit")
        self.only("cap_no_end", "the driver did not reach its end")

    def test_a_missing_or_wrong_exit_code_is_named(self):
        self.only("cap_no_exit_code", "left no exit code")
        self.only("cap_exit_zero", "gave the exit code 0, expected -1")
        self.only("exit_minus_one", "gave the exit code -1, expected 0")

    def test_a_program_that_did_not_run_as_the_scenario_needs_is_named(self):
        self.only("cap_too_few_ticks", "the program printed 4 line(s)")

    def test_a_program_that_ended_by_itself_in_the_cap_scenario_was_not_stopped(self):
        self.only("cap_program_ended_by_itself", "nothing ended it at the cap")

    def test_a_program_that_was_stopped_in_the_exit_scenario_is_named(self):
        self.only("exit_never_done", "never reached its last line")

    def test_the_program_clock_must_be_near_the_cap(self):
        self.only("cap_span_over", "ran for 51 seconds on its own clock")
        self.only("cap_span_under", "ran for only 9 seconds")
        self.only("exit_span_over_its_own_limit", "ran for 21 seconds on its own clock")

    def test_a_driver_that_took_longer_than_the_cap_and_the_stop_allow_is_named(self):
        self.only("cap_driver_too_slow", "the driver took 76 seconds")

    def test_a_process_left_behind_is_named_and_a_list_that_could_not_be_read_is_not_an_empty_answer(self):
        self.only("cap_one_left_running", "1 process(es) of the program were still running")
        self.only("cap_two_left_running", "2 process(es) of the program were still running")
        self.only("cap_process_list_unreadable", "the process list could not be read")
        self.only("cap_unreadable_list_hides_the_leftovers", "the process list could not be read")

    def test_the_first_version_of_the_line_is_red_for_each_of_its_three_symptoms(self):
        found = self.r["cap_first_version_of_the_line"]
        self.assertEqual(len(found), 3, found)
        self.assertTrue(any("nothing ended it at the cap" in f for f in found), found)
        self.assertTrue(any("ran for 99 seconds" in f for f in found), found)
        self.assertTrue(any("the driver took 101 seconds" in f for f in found), found)


# --- the line's own text, run through pwsh against stand-in programs --------------------------------------------------------------------------
# On Windows only the row of tests/selfapps_optbuild_cap.ps1 runs a program below the process the line starts. A POSIX host can still
# run the PowerShell text of the line itself, with its waits shortened, against shell scripts that behave like the two processes of a
# onefile EXE: the bootloader that the line starts and the program it starts, whose output pipes stay open for as long as it runs.

POSIX_PWSH = os.name == "posix" and PWSH is not None

# The bootloader (this script) starts the program as its own child and waits for it; the child prints a line every 0.2 seconds for
# TICKS lines and so keeps both pipes open. The pid files let the test find both processes afterwards.
BOOTLOADER = """#!/bin/sh
echo started
echo $$ > "$PARENT_PID_FILE"
sh -c 'i=0; while [ $i -lt %d ]; do echo tick; sleep 0.2; i=$((i+1)); done' &
echo $! > "$CHILD_PID_FILE"
wait
"""
ONLY_A_PARENT = "#!/bin/sh\necho started\nexec sleep 30\n"
EXITS_BY_ITSELF = "#!/bin/sh\necho hello\nexit 3\n"
EXITS_WITH_THE_NUMBER_OF_ITS_ARGUMENTS = "#!/bin/sh\nexit $#\n"

# What taskkill /F /T /PID <id> does on Windows, and what it was asked: ends the process and every process below it.
STAND_IN_TASKKILL = r"""#!/usr/bin/env python3
import os, signal, subprocess, sys
args = sys.argv[1:]
with open(os.environ["TASKKILL_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
pid = int(args[args.index("/PID") + 1])
below = {}
for row in subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout.split("\n"):
    parts = row.split()
    if len(parts) == 2:
        below.setdefault(int(parts[1]), []).append(int(parts[0]))
def tree(p):
    for child in below.get(p, []):
        yield from tree(child)
    yield p
for victim in list(tree(pid)):
    try:
        os.kill(victim, signal.SIGKILL)
    except OSError:
        pass
"""


def process_running(pid):
    """True while the process exists and is not a zombie that nobody has collected yet."""
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(out) and not out.startswith("Z")


def read_pid(path):
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return None


def run_line_text(text, program, tmp, stand_in=False, wait_ms=500, app_args=None):
    """Run the PowerShell text of the line under pwsh with each wait shortened to wait_ms (the real ones are 30000 and 5000) and the
    program set to `program` (a shell script). With stand_in the host gets a taskkill where $env:SystemRoot\\System32\\taskkill.exe
    is looked for, and without it that file does not exist, so starting taskkill fails as it would on a host without one. Returns a
    dict: lines (what the line printed), seconds, parent and child (the pids the program wrote), child_running (at the moment the
    line returned) and taskkill (its arguments, or None)."""
    tmp = Path(tmp)
    exe = tmp / "program.sh"
    exe.write_text(program)
    exe.chmod(0o755)
    env = dict(os.environ)
    env.pop("SystemRoot", None)
    env.pop("HP_APP_ARGS", None)
    env.update(HP_OPTBUILD_EXE=str(exe), PARENT_PID_FILE=str(tmp / "parent.pid"), CHILD_PID_FILE=str(tmp / "child.pid"),
               TASKKILL_LOG=str(tmp / "taskkill.log"))
    if app_args is not None:
        env["HP_APP_ARGS"] = app_args
    if stand_in:
        root = tmp / "root"  # the file name holds the backslashes, as the line spells the path
        tool = Path(str(root) + "\\System32\\taskkill.exe")
        tool.write_text(STAND_IN_TASKKILL)
        tool.chmod(0o755)
        env["SystemRoot"] = str(root)
    shortened = text.replace("WaitForExit(30000)", "WaitForExit(%d)" % wait_ms).replace("Wait(5000)", "Wait(%d)" % wait_ms) \
        .replace("WaitForExit(5000)", "WaitForExit(%d)" % wait_ms)
    started = time.monotonic()
    done = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-Command", shortened], env=env, capture_output=True, text=True,
                          timeout=HARD_TIMEOUT)
    seconds = time.monotonic() - started
    child = read_pid(tmp / "child.pid")
    running = child is not None and process_running(child)
    if running:
        os.kill(child, 9)  # a stand-in must not outlive the test
    log = tmp / "taskkill.log"
    return {"lines": done.stdout.strip().splitlines(), "stderr": done.stderr.strip(), "seconds": seconds,
            "parent": read_pid(tmp / "parent.pid"), "child": child, "child_running": running,
            "taskkill": log.read_text().strip() if log.exists() else None}


def real_line_text(batch):
    runs = [ln.strip() for ln in live_bat(lines_of(batch)) if "WaitForExit(30000)" in ln and "$env:HP_OPTBUILD_EXE" in ln]
    assert len(runs) == 1, "expected one live line that runs the optimized build, found %d" % len(runs)
    return inline_command(runs[0])


class StandInCases:
    """The behaviour the line must have, as cases against stand-in programs. The two concrete classes below run it on the line as it
    stands in run_setup.bat and on the line as it must read after the fix (GOOD_TEXT), so the fixture is proven to work too."""

    def line_text(self):
        raise NotImplementedError

    def setUp(self):
        self.text = self.line_text()
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.tmp = scratch.name

    def test_a_program_that_ends_by_itself_gives_its_exit_code(self):
        got = run_line_text(self.text, EXITS_BY_ITSELF, self.tmp)
        self.assertEqual(got["lines"], ["3"], got)

    def test_the_arguments_of_the_user_reach_the_program(self):
        got = run_line_text(self.text, EXITS_WITH_THE_NUMBER_OF_ITS_ARGUMENTS, self.tmp, app_args="one two")
        self.assertEqual(got["lines"], ["2"], got)

    def test_a_program_that_only_starts_is_ended_at_the_cap_and_gives_minus_one(self):
        got = run_line_text(self.text, ONLY_A_PARENT, self.tmp)
        self.assertEqual(got["lines"], ["-1"], got)
        self.assertLess(got["seconds"], 15, got)  # the program would have slept for 30 seconds

    def test_the_whole_process_tree_is_ended_with_taskkill_f_t_on_the_id_of_the_process_it_started(self):
        got = run_line_text(self.text, BOOTLOADER % 50, self.tmp, stand_in=True)
        self.assertEqual(got["lines"], ["-1"], got)
        self.assertIsNotNone(got["parent"], got)
        self.assertEqual(got["taskkill"], "/F /T /PID %d" % got["parent"], got)
        self.assertFalse(got["child_running"], "the program the bootloader started was still running when the line returned: %r" % (got,))

    def test_a_program_that_keeps_the_pipes_open_does_not_hold_the_line_when_taskkill_cannot_be_started(self):
        # no taskkill on this host: Kill() ends the process the line started, the program below it lives on with both pipes, and
        # the waits give up at their limit instead of holding the line until it ends (it runs for about ten seconds here)
        got = run_line_text(self.text, BOOTLOADER % 50, self.tmp)
        self.assertEqual(got["lines"], ["-1"], got)
        self.assertIsNone(got["taskkill"], got)
        self.assertTrue(got["child_running"], "the line did not return before the program below the process it started ended: %r" % (got,))
        self.assertLess(got["seconds"], 8, got)


@unittest.skipUnless(POSIX_PWSH, "needs pwsh on a POSIX host: the stand-in programs are shell scripts")
class RealLineThroughPwsh(StandInCases, unittest.TestCase):
    """The PowerShell text of the line as it stands in run_setup.bat."""

    def line_text(self):
        return real_line_text(BATCH.read_text(encoding="utf-8", errors="replace"))


@unittest.skipUnless(POSIX_PWSH, "needs pwsh on a POSIX host: the stand-in programs are shell scripts")
class GoodLineThroughPwsh(StandInCases, unittest.TestCase):
    """The line as the pins below say it must read: the fixture of the mutation cases behaves, so those cases mutate a working line."""

    def line_text(self):
        return GOOD_TEXT


@unittest.skipUnless(POSIX_PWSH, "needs pwsh on a POSIX host: the stand-in programs are shell scripts")
class TheFirstVersionIsTheControl(unittest.TestCase):
    """The stand-in must show the defect of the first version of the line, or its other cases prove nothing about the fix."""

    def test_the_stand_in_reproduces_the_defect_of_the_first_version_of_the_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            # the same program (about 6 seconds of lines) and a cap of half a second: the read after Kill() waits for the program to
            # end by itself, so the line returns only then, and nothing is left running afterwards
            got = run_line_text(FIRST_VERSION_OF_THE_LINE, BOOTLOADER % 30, tmp)
        self.assertEqual(got["lines"], ["-1"], got)
        self.assertGreaterEqual(got["seconds"], 4, got)
        self.assertFalse(got["child_running"], got)

    def test_the_first_version_is_what_the_batch_file_held_before_the_fix_or_is_gone(self):
        # a guard on the fixture itself: it must stay a line without the tree stop and without a limit on its reads
        self.assertEqual(line_text_problems(FIRST_VERSION_OF_THE_LINE)[0].split(" ")[0:3], ["the", "stop", "after"])


# --- the rules on the real files --------------------------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_verification_line_waits_30_seconds_ends_the_process_tree_and_bounds_its_waits(self):
        self.assertEqual(block_problems(self.batch), [])

    def test_the_script_has_its_row_judge_driver_program_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_row_is_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        block = cut_block(self.batch, CUT_START, CUT_END)
        self.assertGreater(len(live_bat(block)), 4)
        self.assertEqual(len(judge_cases()), 22)

    def test_the_judge_the_driver_is_asked_for_is_a_function_of_the_script(self):
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))

    def test_the_fixture_is_a_line_the_pins_accept(self):
        self.assertEqual(line_text_problems(GOOD_TEXT), [])
        self.assertEqual(inline_command(BAT_HEAD + GOOD_TEXT + BAT_TAIL), GOOD_TEXT)

    def test_the_first_version_of_the_line_is_refused_for_both_of_its_faults(self):
        found = line_text_problems(FIRST_VERSION_OF_THE_LINE)
        self.assertTrue(any("whole process tree" in f for f in found), found)
        self.assertTrue(any(".Result" in f for f in found), found)

    def test_the_two_lines_that_wait_30_seconds_end_the_tree_with_the_same_text(self):
        # the repair loop's line (Item 106) and this line stop the program the same way; a change to one is a change to the other
        repair = [ln for ln in live_bat(lines_of(self.batch)) if "$env:HP_HIR_EXE" in ln and "WaitForExit(30000)" in ln]
        self.assertEqual(len(repair), 1)
        stop = GOOD_TEXT[GOOD_TEXT.index("if(-not $done){try{$k="):GOOD_TEXT.index(FALLBACK_KILL) + len(FALLBACK_KILL) + 1]
        self.assertTrue(stop.startswith("if(-not $done){try{$k=New-Object") and stop.endswith("}catch{};try{$p.Kill()}catch{}}"), stop)
        self.assertIn(stop, repair[0])


# --- each rule is shown to fail ------------------------------------------------------------------------------------------------------------------

class LineRulesCanFail(unittest.TestCase):
    """Each rule about the PowerShell text of the line fails on a mutated copy of the good line."""

    def problems(self, old, new):
        return line_text_problems(mutate(GOOD_TEXT, old, new))

    def test_a_cap_that_is_not_30_seconds_is_caught(self):
        found = self.problems(WAIT, WAIT.replace("30000", "300000"))
        self.assertTrue(any("WaitForExit(30000)" in f for f in found), found)

    def test_a_stop_that_ends_only_the_process_and_not_its_tree_is_caught(self):
        found = self.problems(TREE_ARGS, "$k.Arguments='/F /PID '+$p.Id")
        self.assertTrue(any("whole process tree" in f for f in found), found)

    def test_a_taskkill_that_is_never_started_is_caught(self):
        found = self.problems(TREE_KILL, "[void]$k")
        self.assertTrue(any("whole process tree" in f for f in found), found)

    def test_a_taskkill_that_is_not_the_one_in_system32_is_caught(self):
        found = self.problems(TREE_EXE, "$k.FileName='taskkill.exe'")
        self.assertTrue(any("whole process tree" in f for f in found), found)

    def test_a_stop_that_comes_before_the_wait_is_caught(self):
        stop_start = GOOD_TEXT.index("if(-not $done){try{$k=")
        stop_end = GOOD_TEXT.index(BOUNDED_READS)
        stop = GOOD_TEXT[stop_start:stop_end]
        moved = GOOD_TEXT[:stop_start] + GOOD_TEXT[stop_end:]
        moved = moved.replace(WAIT, stop + WAIT, 1)
        self.assertTrue(any("whole process tree" in f for f in line_text_problems(moved)), line_text_problems(moved))

    def test_a_fallback_kill_that_is_removed_or_runs_first_is_caught(self):
        gone = mutate(GOOD_TEXT, "}catch{};" + FALLBACK_KILL + "};", "}catch{}};")
        self.assertTrue(any("fallback" in f for f in line_text_problems(gone)), line_text_problems(gone))
        first = mutate(GOOD_TEXT, "if(-not $done){try{$k=", "if(-not $done){try{$p.Kill()}catch{};try{$k=")
        first = mutate(first, "}catch{};" + FALLBACK_KILL + "};", "}catch{}};")
        self.assertTrue(any("fallback" in f for f in line_text_problems(first)), line_text_problems(first))

    def test_a_read_that_waits_without_a_limit_is_caught(self):
        found = self.problems(BOUNDED_READS, "$so.Result|Out-Null;$se.Result|Out-Null;")
        self.assertTrue(any("at most 5 seconds" in f for f in found) and any(".Result" in f for f in found), found)
        for bounded, unbounded in (("[void]$so.Wait(5000);", "[void]$so.Result;"), ("[void]$se.Wait(5000)}", "[void]$se.Result}")):
            found = self.problems(bounded, unbounded)
            self.assertTrue(any("at most 5 seconds" in f for f in found), (bounded, found))

    def test_a_wait_with_another_limit_is_caught(self):
        found = self.problems("[void]$so.Wait(5000);", "[void]$so.Wait(50000);")
        self.assertTrue(any("at most 5 seconds" in f for f in found), found)

    def test_a_wait_that_comes_before_the_stop_is_caught(self):
        stop_start = GOOD_TEXT.index("if(-not $done){try{$k=")
        stop_end = GOOD_TEXT.index(BOUNDED_READS)
        moved = GOOD_TEXT[:stop_start] + BOUNDED_READS + GOOD_TEXT[stop_start:stop_end] + GOOD_TEXT[stop_end + len(BOUNDED_READS):]
        self.assertTrue(any("before the process is stopped" in f for f in line_text_problems(moved)), line_text_problems(moved))

    def test_reads_that_start_after_the_wait_are_caught(self):
        found = self.problems(START_READS + WAIT, WAIT + START_READS)
        self.assertTrue(any("before the 30 second wait" in f for f in found), found)

    def test_one_read_less_is_caught(self):
        found = self.problems("$se=$p.StandardError.ReadToEndAsync();", "")
        self.assertTrue(any("two asynchronous reads" in f for f in found), found)

    def test_a_run_that_does_not_report_minus_one_when_it_did_not_finish_is_caught(self):
        found = self.problems(RESULT_TAIL, "$p.ExitCode")
        self.assertTrue(any("exit code -1" in f for f in found), found)

    def test_a_line_that_stops_starting_the_named_file_or_passing_the_arguments_is_caught(self):
        self.assertTrue(any("HP_OPTBUILD_EXE" in f for f in self.problems("$si.FileName=$env:HP_OPTBUILD_EXE;", "$si.FileName='x';")))
        self.assertTrue(any("HP_APP_ARGS" in f for f in self.problems(APP_ARGS, "")))

    def test_a_character_cmd_reads_in_the_powershell_text_is_caught(self):
        for ch in CMD_CHARACTERS:
            found = self.problems("$k.UseShellExecute=$false;", "$k.UseShellExecute=$false;$x='" + ch + "';")
            self.assertTrue(any("cmd character" in f and ch in f for f in found), (ch, found))

    def test_a_line_that_is_not_the_for_f_shape_is_reported_by_the_block_rule(self):
        self.assertRaises(ValueError, inline_command, "for /f %%X in ('x') do echo %%X")


def good_batch():
    """The real batch file with the verification line replaced by the good one, so the block rules are tried on a file that is right
    both before and after the fix."""
    real = BATCH.read_text(encoding="utf-8", errors="replace")
    lines = real.split("\n")
    at = [i for i, ln in enumerate(lines) if "$env:HP_OPTBUILD_EXE" in ln and "WaitForExit(30000)" in ln]
    assert len(at) == 1, "expected one line that runs the optimized build, found %d" % len(at)
    lines[at[0]] = BAT_HEAD + GOOD_TEXT + BAT_TAIL + ("\r" if lines[at[0]].endswith("\r") else "")
    return "\n".join(lines)


class BlockRulesCanFail(unittest.TestCase):
    """Each rule about the block in run_setup.bat fails on a mutated copy of a batch file whose line is the good one."""

    def setUp(self):
        self.batch = good_batch()

    def test_the_good_batch_has_no_problem(self):
        self.assertEqual(block_problems(self.batch), [])

    def test_a_label_or_a_cut_line_that_is_missing_or_duplicated_is_reported(self):
        gone = mutate(self.batch, "\n:optbuild_cleanup\n", "\n:optbuild_cleanupx\n")
        self.assertTrue(any("appears 0 time(s)" in f for f in block_problems(gone)))
        twice = self.batch + "\n:offer_optimized_build\n"
        self.assertTrue(any("appears 2 time(s)" in f for f in block_problems(twice)))
        no_end = mutate(self.batch, "\n" + CUT_END + "\n", "\nif not \"%HP_OPTBUILD_VERIFY_EXIT%\"==\"1\" (\n")
        self.assertTrue(any(CUT_END in f for f in block_problems(no_end)), block_problems(no_end))
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))

    def test_a_variable_the_driver_does_not_define_is_caught(self):
        bad = mutate(self.batch, EXE_LINE + "\n", EXE_LINE + "\nset \"HP_OPTBUILD_X=%ENVNAME%\"\n")
        self.assertTrue(any("ENVNAME" in f and "driver does not define" in f for f in block_problems(bad)), block_problems(bad))

    def test_a_call_or_a_jump_in_the_block_is_caught(self):
        bad = mutate(self.batch, EXE_LINE + "\n", EXE_LINE + "\ncall :log \"x\"\n")
        self.assertTrue(any("calls or jumps" in f for f in block_problems(bad)), block_problems(bad))

    def test_an_exe_that_is_not_named_from_the_working_folder_is_caught(self):
        bad = mutate(self.batch, EXE_LINE, 'set "HP_OPTBUILD_EXE=dist\\%HP_OPTBUILD_TMP%"')
        self.assertTrue(any("names the EXE" in f for f in block_problems(bad)), block_problems(bad))

    def test_a_second_line_with_the_cap_is_caught(self):
        extra = "\n" + BAT_HEAD + GOOD_TEXT + BAT_TAIL + "\n"
        bad = mutate(self.batch, "\n" + EXE_LINE + "\n", "\n" + EXE_LINE + extra)
        self.assertTrue(any("exactly one live line" in f for f in block_problems(bad)), block_problems(bad))

    def test_a_line_with_another_shape_is_reported_and_not_raised(self):
        start = BAT_HEAD + "$si=New-Object System.Diagnostics.ProcessStartInfo;$si.FileName=$env:HP_OPTBUILD_EXE;"
        bad = mutate(self.batch, start, start.replace('-Command "$si', "-Command $si"))
        self.assertTrue(any("no longer a for /f line" in f for f in block_problems(bad)), block_problems(bad))

    def test_a_line_that_moved_away_from_the_exe_name_is_caught(self):
        bad = mutate(self.batch, "\n" + EXE_LINE + "\n", "\n" + EXE_LINE + "\nrem a line between\nset \"HP_OPTBUILD_Y=1\"\n")
        found = block_problems(bad)
        self.assertTrue(any("directly under the line that names the EXE" in f for f in found), found)

    def test_a_default_that_does_not_follow_the_line_is_caught(self):
        bad = mutate(self.batch, 'if not defined HP_OPTBUILD_VERIFY_EXIT set "HP_OPTBUILD_VERIFY_EXIT=-1"\n', "")
        self.assertTrue(any("must follow it" in f for f in block_problems(bad)), block_problems(bad))

    def test_a_result_that_is_not_reset_to_minus_one_before_the_start_is_caught(self):
        # the block is cut from that very line, so a start line that sets another value is reported as a missing cut line
        bad = mutate(self.batch, "\n" + CUT_START + "\n", "\nset \"HP_OPTBUILD_VERIFY_EXIT=0\"\n")
        found = block_problems(bad)
        self.assertTrue(any(CUT_START in f and "appears 0 time(s)" in f for f in found), found)

    def test_a_failed_verification_that_swaps_the_exe_anyway_is_caught(self):
        bad = mutate(self.batch, "  goto :optbuild_cleanup\n)\nrem Verified good", "  rem nothing\n)\nrem Verified good")
        self.assertTrue(any("keeps the original EXE" in f for f in block_problems(bad)), block_problems(bad))
        bad = mutate(self.batch, 'call :log "[WARN] Optimized build verification did not pass (exit %HP_OPTBUILD_VERIFY_EXIT%)',
                     'call :log "[WARN] Optimized build verification passed (exit %HP_OPTBUILD_VERIFY_EXIT%)')
        self.assertTrue(any("keeps the original EXE" in f for f in block_problems(bad)), block_problems(bad))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the workflow and the registry fails on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def problems(self, text):
        return script_problems(text)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "id = 'self.optbuild.cap'; req = 'REQ-018.36'; pass = $pass", "id = $rowId; req = 'REQ-018.36'; pass = $pass")
        self.assertTrue(any("row id must be the literal" in f for f in self.problems(bad)))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "req = 'REQ-018.36'; pass = $pass", "req = 'REQ-018'; pass = $pass")
        self.assertTrue(any("req tag" in f for f in self.problems(bad)))

    def test_a_cut_that_moved_or_a_stand_in_that_is_not_named_is_caught(self):
        bad = mutate(self.script, "-EndLine 'if not \"%HP_OPTBUILD_VERIFY_EXIT%\"==\"0\" ('", "-EndLine 'if not defined HP_OPTBUILD_VERIFY_EXIT ('")
        self.assertTrue(any("no longer cuts the block" in f for f in self.problems(bad)))
        bad = mutate(self.script, "'set \"HP_OPTBUILD_TMP=optcap_stand_in.cmd\"'", "'set \"HP_OPTBUILD_TMP=x.cmd\"'")
        self.assertTrue(any("stand-in program through HP_OPTBUILD_TMP" in f for f in self.problems(bad)))

    def test_open_standard_input_a_missing_limit_and_a_missing_kill_are_caught(self):
        bad = mutate(self.script, "2>&1 < nul'", "2>&1'")
        self.assertTrue(any("standard input" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-LimitMs 150000", "-LimitMs 0")
        self.assertTrue(any("150 second limit" in f for f in self.problems(bad)))
        bad = mutate(self.script, "& taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null", "")
        self.assertTrue(any("taskkill" in f for f in self.problems(bad)))

    def test_scenarios_that_stop_being_the_ones_the_shall_names_are_caught(self):
        bad = mutate(self.script, "Ticks = 100;", "Ticks = 10;")
        self.assertTrue(any("far longer than the cap" in f for f in self.problems(bad)))
        bad = mutate(self.script, "ExpectExit = '-1'; ExpectDone = $false;", "ExpectExit = '0'; ExpectDone = $false;")
        self.assertTrue(any("expect the exit code -1" in f for f in self.problems(bad)))
        bad = mutate(self.script, "MaxSpan = 50;", "MaxSpan = 500;")
        self.assertTrue(any("10 to 50 seconds" in f for f in self.problems(bad)))
        bad = mutate(self.script, "ExpectExit = '0'; ExpectDone = $true;", "ExpectExit = '-1'; ExpectDone = $true;")
        self.assertTrue(any("is the control" in f for f in self.problems(bad)))
        bad = mutate(self.script, "[pscustomobject]@{ Name = 'exit';", "[pscustomobject]@{ Name = 'exitx';")
        self.assertTrue(any("two scenarios" in f for f in self.problems(bad)))

    def test_a_stand_in_program_that_stops_being_a_program_that_keeps_printing_is_caught(self):
        bad = mutate(self.script, "        '    [Console]::Out.Flush()',\n", "")
        self.assertTrue(any("stand-in program no longer holds" in f and "Flush" in f for f in self.problems(bad)))
        bad = mutate(self.script, "        '    Start-Sleep -Seconds 1',\n", "")
        self.assertTrue(any("Start-Sleep" in f for f in self.problems(bad)))
        bad = mutate(self.script, "        'powershell -NoProfile -ExecutionPolicy Bypass -File \"%OPTCAP_HOLDER%\"',\n", "        'start /b x',\n")
        self.assertTrue(any("OPTCAP_HOLDER" in f for f in self.problems(bad)))

    def test_a_process_list_that_is_not_read_through_cim_or_is_stopped_too_early_is_caught(self):
        bad = mutate(self.script, "Get-CimInstance -ClassName Win32_Process", "Get-Process")
        self.assertTrue(any("through CIM" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$left = Get-LeftoverProcesses -Marker $holder", "$left = Get-LeftoverProcesses -Marker $dir")
        self.assertTrue(any("holder script of the scenario" in f for f in self.problems(bad)))
        bad = mutate(self.script, "                [void]$found.Add(('' + $proc.ProcessId + ' ' + $proc.Name))\n                try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch { }\n",
                     "                try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch { }\n                [void]$found.Add(('' + $proc.ProcessId + ' ' + $proc.Name))\n")
        self.assertTrue(any("recorded before it is stopped" in f for f in self.problems(bad)))

    def test_a_verdict_that_hands_the_judge_something_else_or_is_not_the_problem_list_is_caught(self):
        bad = mutate(self.script, "-MaxSeconds ([int]$Scenario.MaxSeconds))", "-MaxSeconds 3000)")
        self.assertTrue(any("-MaxSeconds ([int]$Scenario.MaxSeconds)" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$pass = [bool]($problemsAll.Count -eq 0)", "$pass = $true")
        self.assertTrue(any("$pass = [bool]" in f for f in self.problems(bad)))

    def test_a_script_without_its_exit_codes_is_caught(self):
        bad = mutate(self.script, "if (-not $pass) { exit 1 }\nexit 0\n", "exit 0\n")
        self.assertTrue(any("exits 1 for a red row" in f for f in self.problems(bad)))
        bad = mutate(self.script, "if (-not $pass) { exit 1 }\nexit 0\n", "if (-not $pass) { exit 1 }\n")
        self.assertTrue(any("does not end with exit 0" in f for f in self.problems(bad)))

    def test_isWindows_and_a_non_ascii_character_are_caught(self):
        bad = mutate(self.script, "if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {", "if (-not $IsWindows) {")
        self.assertTrue(any("OSVersion.Platform" in f for f in self.problems(bad)))
        self.assertTrue(any("ASCII" in f for f in self.problems(self.script + "\n# caf\u00e9\n")))

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
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\%s" % SCRIPT_NAME])
        bad = self.workflow.replace("tests/~selftest_optbuildcap/*/~optcap_ledger.txt", "")
        self.assertTrue(any("~optcap_ledger" in f for f in workflow_problems(bad)))

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        self.assertTrue(registry_problems(text.replace(ROW_ID, "self.optbuild.capx")))
        self.assertTrue(registry_problems("```\nself.repair.cap\n```\nprose: %s\n" % ROW_ID))


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgeCanFail(unittest.TestCase):
    """A judge that quietly stops judging would pass every scenario, so the cases are run against mutated copies of the script."""

    def run_mutated(self, old, new, names):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, new), encoding="utf-8")
            wanted = [c for c in judge_cases() if c["name"] in names]
            return run_cases(script, JUDGES, wanted, d)

    def test_a_judge_that_forgets_a_driver_that_did_not_finish_is_caught(self):
        got = self.run_mutated("    if (-not $Finished) {", "    if ($false) {", ["cap_unfinished"])
        self.assertEqual(got["cap_unfinished"], [])

    def test_a_judge_that_forgets_a_driver_that_did_not_reach_its_end_is_caught(self):
        got = self.run_mutated("    if ($ResultText -notmatch '(?m)^END\\s*$') {", "    if ($false) {", ["cap_no_end"])
        self.assertEqual(got["cap_no_end"], [])

    def test_a_judge_that_forgets_the_exit_code_is_caught(self):
        got = self.run_mutated("    } elseif ($exitMatch.Groups[1].Value -ne $ExpectExit) {", "    } elseif ($false) {", ["cap_exit_zero", "exit_minus_one"])
        self.assertEqual(got["cap_exit_zero"], [])
        self.assertEqual(got["exit_minus_one"], [])

    def test_a_judge_that_forgets_a_missing_exit_code_is_caught(self):
        got = self.run_mutated("    if (-not $exitMatch.Success) {", "    if ($false) {", ["cap_no_exit_code"])
        # the second branch still reports the empty code as a wrong one, so what must be gone is the sentence about the missing code
        self.assertFalse(any("left no exit code" in f for f in got["cap_no_exit_code"]), got)

    def test_a_judge_that_forgets_too_few_lines_is_caught(self):
        got = self.run_mutated("    if ($ticks.Count -lt $MinTicks) {", "    if ($false) {", ["cap_too_few_ticks"])
        self.assertEqual(got["cap_too_few_ticks"], [])

    def test_a_judge_that_forgets_a_program_that_ended_by_itself_is_caught(self):
        got = self.run_mutated("    if ((-not $ExpectDone) -and $done) {", "    if ($false) {", ["cap_program_ended_by_itself"])
        self.assertEqual(got["cap_program_ended_by_itself"], [])

    def test_a_judge_that_forgets_a_program_that_never_ended_is_caught(self):
        got = self.run_mutated("    if ($ExpectDone -and -not $done) {", "    if ($false) {", ["exit_never_done"])
        self.assertEqual(got["exit_never_done"], [])

    def test_a_judge_that_forgets_the_upper_edge_is_caught(self):
        got = self.run_mutated("        if ($span -gt $MaxSpan) {", "        if ($false) {", ["cap_span_over", "exit_span_over_its_own_limit"])
        self.assertEqual(got["cap_span_over"], [])
        self.assertEqual(got["exit_span_over_its_own_limit"], [])

    def test_a_judge_that_forgets_the_lower_edge_is_caught(self):
        got = self.run_mutated("        if ((-not $ExpectDone) -and $span -lt $MinSpan) {", "        if ($false) {", ["cap_span_under"])
        self.assertEqual(got["cap_span_under"], [])

    def test_a_judge_that_forgets_how_long_the_driver_took_is_caught(self):
        got = self.run_mutated("    if ($Seconds -gt $MaxSeconds) {", "    if ($false) {", ["cap_driver_too_slow"])
        self.assertEqual(got["cap_driver_too_slow"], [])

    def test_a_judge_that_forgets_a_process_left_running_is_caught(self):
        got = self.run_mutated("    } elseif ($Leftover.Count -gt 0) {", "    } elseif ($false) {", ["cap_one_left_running", "cap_two_left_running"])
        self.assertEqual(got["cap_one_left_running"], [])
        self.assertEqual(got["cap_two_left_running"], [])

    def test_a_judge_that_takes_an_unreadable_process_list_for_an_empty_one_is_caught(self):
        got = self.run_mutated("    if (-not $LeftoverChecked) {", "    if ($false) {", ["cap_process_list_unreadable"])
        self.assertEqual(got["cap_process_list_unreadable"], [])


if __name__ == "__main__":
    unittest.main()
