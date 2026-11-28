"""Tests for the two rows of README REQ-018.6, Item 124: self.launch.cap.silent and self.launch.cap.output.

REQ-018.6 says the bootstrapper shall force-stop the verification run of a new build only if the run has produced no output 30 seconds
after it started, and that any output, a prompt that waits for input included, shall keep the run going for as long as it needs.
tests/test_exe_smokerun.py holds both halves on the helper alone (tools/exe_smokerun.ps1, the wait cut to a fraction of a second by a
test-only override). No row ran what production runs: the 30 second wait, an EXE the bootstrapper built, and the console the user
reads. tests/selfapps_launch_cap.ps1 does, in two default bootstraps of one-file programs:
  * silent: a program that prints nothing for 75 seconds. The EXE the runner started must be stopped about 30 seconds after it started
            (the runner prints the id of the process it started, the script opens that process and reads its own start and end time)
            and the console must say exit -1 and TIMED OUT.
  * output: a program that prints a prompt with input() and waits. The script holds the bootstrap's standard input open and writes the
            answer 46 seconds after the program's first ledger line; the prompt must be on the console, the EXE the runner started
            must still be alive past the 30 second mark and the run must end by itself with exit 0 and SUCCESS.
What this file holds, and why:
  * the script's judging functions run through a real pwsh in strict mode (tests/judge_support.py) on consoles built from the batch
    file's own log lines and the helper's own Process ID line, so a reworded status line fails HERE, with the judge's problem text,
    before a Windows run; a good run is clean and each wrong one is named once, and the facts a real console yields make both judges
    clean while the same facts fail the judge of the other scenario;
  * mutation cases that remove one comparison from a copy of the script and must see the matching wrong run pass, so a judge that
    quietly stopped judging cannot stay green (the anchor of each case must occur exactly once inside the function it is about);
  * the two programs of the scenarios, run on a POSIX host (the sleep patched out, the frozen flag set): the silent one prints nothing
    and sleeps well past the upper bound of its window, the other prints the prompt and the reply the script looks for and writes its
    ledger lines in the order the facts function reads;
  * the script's literal row ids and tags, the numbers that tie the two scenarios together (the cap, the answer delay, the shortest
    wait that proves the run was not stopped), the removal of the test-only wait override, the standard input of the bootstrap, the
    process watching, the verdicts and the exit lines, the workflow step and its uploads, the registry and the shall list, as text.
ASCII only.
"""
import concurrent.futures
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import HARD_TIMEOUT, PWSH, case, cut_block, live_bat, mutate, norm, registry_ids, run_cases, step_block  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "tests" / "selfapps_launch_cap.ps1"
HELPER = REPO / "tools" / "exe_smokerun.ps1"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
ROWS = ("self.launch.cap.silent", "self.launch.cap.output")
TAG = "REQ-018.6"
JUDGES = ["Get-LaunchCapProcessId", "Get-LaunchCapLogFacts", "Get-LaunchCapLedgerFacts", "Get-SilentCapProblems",
          "Get-OutputCapProblems", "Get-LaunchCapExcerpt"]
STAMP = "20.11.2026 09:12:34,56 "  # what :log puts in front of a line: %date% %time%
PROMPT = "Launch cap name? "
REPLY = "Launch cap reply: Sample"


# --- the real wording, read from the batch file and from the helper ------------------------------------------------------------------

def bat_text():
    return (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")


def verdict_block(bat):
    block = cut_block(bat, ":run_exe_smokerun", ":smokerun_launch_failed")
    assert block is not None, "the verdict of the EXE verification run could not be cut out of run_setup.bat"
    return block


def one_live(block, pattern):
    """The one live line of the block that matches the pattern, stripped (the pattern sees the stripped line)."""
    hits = [ln.strip() for ln in live_bat(block) if re.search(pattern, ln.strip())]
    assert len(hits) == 1, "expected one live line matching %r, found %r" % (pattern, hits)
    return hits[0]


def logged_text(line):
    """The text a `call :log "..."` line prints."""
    return re.match(r'call :log "(.*)"$', line).group(1)


def real_running_line(bat):
    return STAMP + logged_text(one_live(verdict_block(bat), r'^call :log "\[INFO\] Running entry script smoke test via packaged EXE\."$'))


def real_warn_exit_line(bat, code):
    line = one_live(verdict_block(bat), r'^call :log "\[WARN\] EXE smokerun: exited %HP_EXE_EXIT% \(non-zero\)"$')
    return STAMP + logged_text(line).replace("%HP_EXE_EXIT%", str(code))


def real_ok_line(bat):
    return STAMP + logged_text(one_live(verdict_block(bat), r'^call :log "\[INFO\] EXE smokerun: exited 0 \(ok\)"$'))


def real_exit_line(bat, code):
    line = one_live(verdict_block(bat), r'^call :log "\[INFO\] Entry smoke exit=%HP_EXE_EXIT%"$')
    return STAMP + logged_text(line).replace("%HP_EXE_EXIT%", str(code))


STATUS_PATTERNS = {
    "SUCCESS": r'^call :log "\[STATUS\] Run Status: SUCCESS ',
    "TIMED OUT": r'^call :log "\[STATUS\] Run Status: TIMED OUT ',
    "FAILED": r'^call :log "\[STATUS\] Run Status: FAILED ',
}


def real_status_line(bat, kind):
    line = one_live(verdict_block(bat), STATUS_PATTERNS[kind])
    return STAMP + logged_text(line).replace("%HP_EXE_EXIT%", "1")


def real_process_line(pid):
    """The line ~exe_smokerun.ps1 prints right after Start(); it is written by the helper, so it has no :log stamp."""
    text = norm(HELPER.read_text(encoding="utf-8"))
    m = re.search(r'^Write-Host "(\[INFO\] Process ID \$\(\$p\.Id\)\. .*)"\s*$', text, re.M)
    assert m, "the helper no longer prints its Process ID line the way the script reads it"
    return m.group(1).replace("$($p.Id)", str(pid))


def console_of(lines, eol="\r\n"):
    return eol.join(lines) + eol


def silent_console(bat, pid=4321, code=-1, status="TIMED OUT", eol="\r\n", process_line=True, exit_line=True):
    """The console of the bootstrap of the program that prints nothing: the runner starts the EXE, force-stops it and reports it."""
    lines = [real_running_line(bat)]
    if process_line:
        lines.append(real_process_line(pid))
    if code != 0:
        lines.append(real_warn_exit_line(bat, code))
    else:
        lines.append(real_ok_line(bat))
    if exit_line:
        lines.append(real_exit_line(bat, code))
    if status:
        lines.append(real_status_line(bat, status))
    return console_of(lines, eol)


def output_console(bat, pid=4321, code=0, status="SUCCESS", eol="\r\n", prompt=True, reply=True, same_line=True, process_line=True,
                   exit_line=True, extra_exit=None):
    """The console of the bootstrap of the program with a prompt. The runner tees the program's output in chunks, and the prompt has no
    line end, so on a real console the reply follows the prompt on the same line; the facts must not depend on that."""
    lines = [real_running_line(bat)]
    if process_line:
        lines.append(real_process_line(pid))
    shown = ""
    if prompt:
        shown += PROMPT
    if prompt and reply and not same_line:
        lines.append(shown)
        shown = ""
    if reply:
        shown += REPLY
    if shown:
        lines.append(shown)
    lines.append(real_ok_line(bat) if code == 0 else real_warn_exit_line(bat, code))
    if extra_exit is not None:
        lines.append(real_exit_line(bat, extra_exit))
    if exit_line:
        lines.append(real_exit_line(bat, code))
    if status:
        lines.append(real_status_line(bat, status))
    return console_of(lines, eol)


# --- cases for the judging functions -------------------------------------------------------------------------------------------------

SILENT_GOOD = dict(Finished=True, Started=True, ProcId=4321, LifetimeSeconds=31.4, ExitText="-1", TimedOutLine=True, CapSeconds=30)
OUTPUT_GOOD = dict(Finished=True, Started=True, AnswerSent=True, Answered=True, AnswerDelaySeconds=46.4, PromptSeenSeconds=2.8,
                   ReplySeen=True, ProcId=4321, LifetimeSeconds=48.1, ExitText="0", TimedOutLine=False, SuccessLine=True,
                   CapSeconds=30, MinWaitSeconds=44)


def silent(name, **over):
    args = dict(SILENT_GOOD)
    args.update(over)
    return case(name, "Get-SilentCapProblems", **args)


def output(name, **over):
    args = dict(OUTPUT_GOOD)
    args.update(over)
    return case(name, "Get-OutputCapProblems", **args)


def ev(kind, t, **more):
    row = {"ev": kind, "t": t}
    row.update(more)
    return row


LEDGER_GOOD = [ev("start", 1000.0, frozen=True), ev("answered", 1046.4, name="Sample"), ev("done", 1046.5)]


def silent_cases():
    c = [silent("silent_good"),
         silent("silent_good_at_the_lower_bound", LifetimeSeconds=28.0),
         silent("silent_good_at_the_upper_bound", LifetimeSeconds=45.0),
         silent("silent_not_finished", Finished=False),
         silent("silent_not_started", Started=False),
         silent("silent_no_process_id", ProcId=0, LifetimeSeconds=-1.0),
         silent("silent_no_process_id_with_a_lifetime", ProcId=0),
         silent("silent_not_watched", LifetimeSeconds=-1.0),
         silent("silent_stopped_too_early", LifetimeSeconds=10.0),
         silent("silent_just_under_the_lower_bound", LifetimeSeconds=27.9),
         silent("silent_never_stopped", LifetimeSeconds=60.0),
         silent("silent_just_over_the_upper_bound", LifetimeSeconds=45.1),
         silent("silent_no_exit_line", ExitText=""),
         silent("silent_exit_zero", ExitText="0"),
         silent("silent_exit_one", ExitText="1"),
         silent("silent_no_timed_out_line", TimedOutLine=False),
         silent("silent_everything_wrong", Started=False, ProcId=0, LifetimeSeconds=-1.0, ExitText="", TimedOutLine=False)]
    return c


def output_cases():
    c = [output("output_good"),
         output("output_good_at_the_lower_bounds", AnswerDelaySeconds=44.0, LifetimeSeconds=44.0, PromptSeenSeconds=30.0),
         output("output_not_finished_answer_lost", Finished=False, Answered=False, AnswerDelaySeconds=-1.0),
         output("output_not_finished", Finished=False, AnswerSent=False, Answered=False, AnswerDelaySeconds=-1.0),
         output("output_not_started", Started=False),
         output("output_never_answered", Answered=False, AnswerDelaySeconds=-1.0),
         output("output_answered_too_early", AnswerDelaySeconds=20.0),
         output("output_answered_just_too_early", AnswerDelaySeconds=43.9),
         output("output_prompt_never_seen", PromptSeenSeconds=-1.0),
         output("output_prompt_seen_late", PromptSeenSeconds=35.0),
         output("output_reply_not_seen", ReplySeen=False),
         output("output_no_process_id", ProcId=0, LifetimeSeconds=-1.0),
         output("output_no_process_id_with_a_lifetime", ProcId=0),
         output("output_not_watched", LifetimeSeconds=-1.0),
         output("output_stopped_at_the_cap", LifetimeSeconds=31.0),
         output("output_just_under_the_wait", LifetimeSeconds=43.9),
         output("output_no_exit_line", ExitText=""),
         output("output_exit_minus_one", ExitText="-1"),
         output("output_exit_one", ExitText="1"),
         output("output_timed_out_line", TimedOutLine=True),
         output("output_no_success_line", SuccessLine=False),
         output("output_everything_wrong", Started=False, Answered=False, AnswerDelaySeconds=-1.0, PromptSeenSeconds=-1.0,
                ReplySeen=False, ProcId=0, LifetimeSeconds=-1.0, ExitText="", TimedOutLine=True, SuccessLine=False)]
    return c


def fact_cases(bat):
    two_exits = console_of([real_running_line(bat), real_exit_line(bat, -1), real_exit_line(bat, 0), real_status_line(bat, "SUCCESS")])
    return [
        case("facts_silent", "Get-LaunchCapLogFacts", ConsoleText=silent_console(bat), Prompt="", Reply=""),
        case("facts_silent_lf_only", "Get-LaunchCapLogFacts", ConsoleText=silent_console(bat, eol="\n"), Prompt="", Reply=""),
        case("facts_output", "Get-LaunchCapLogFacts", ConsoleText=output_console(bat), Prompt=PROMPT, Reply=REPLY),
        case("facts_output_separate_lines", "Get-LaunchCapLogFacts", ConsoleText=output_console(bat, same_line=False), Prompt=PROMPT, Reply=REPLY),
        case("facts_output_lf_only", "Get-LaunchCapLogFacts", ConsoleText=output_console(bat, eol="\n"), Prompt=PROMPT, Reply=REPLY),
        case("facts_output_without_reply", "Get-LaunchCapLogFacts", ConsoleText=output_console(bat, reply=False), Prompt=PROMPT, Reply=REPLY),
        case("facts_output_without_prompt", "Get-LaunchCapLogFacts", ConsoleText=output_console(bat, prompt=False, reply=False), Prompt=PROMPT, Reply=REPLY),
        case("facts_failed", "Get-LaunchCapLogFacts", ConsoleText=silent_console(bat, code=1, status="FAILED"), Prompt="", Reply=""),
        case("facts_last_exit_line_wins", "Get-LaunchCapLogFacts", ConsoleText=two_exits, Prompt="", Reply=""),
        case("facts_no_exit_line", "Get-LaunchCapLogFacts", ConsoleText=silent_console(bat, exit_line=False, status=None), Prompt="", Reply=""),
        case("facts_empty_console", "Get-LaunchCapLogFacts", ConsoleText="", Prompt=PROMPT, Reply=REPLY),
    ]


def pid_cases(bat):
    return [
        case("pid_silent", "Get-LaunchCapProcessId", ConsoleText=silent_console(bat, pid=4321)),
        case("pid_output_lf_only", "Get-LaunchCapProcessId", ConsoleText=output_console(bat, pid=777, eol="\n")),
        case("pid_none", "Get-LaunchCapProcessId", ConsoleText=silent_console(bat, process_line=False)),
        case("pid_first_line_wins", "Get-LaunchCapProcessId", ConsoleText=console_of([real_process_line(11), real_process_line(22)])),
        case("pid_too_large_to_be_one", "Get-LaunchCapProcessId", ConsoleText="[INFO] Process ID 99999999999. If it seems stuck\r\n"),
        case("pid_other_text", "Get-LaunchCapProcessId", ConsoleText="[INFO] Process ID is unknown\r\n[INFO] Process ID 5 without a point\r\n"),
    ]


def ledger_cases():
    frozen_late = [ev("start", 900.0, frozen=False), ev("start", 1000.0, frozen=True), ev("start", 1100.0, frozen=True),
                   ev("answered", 1046.4, name="Sample"), ev("answered", 1060.0, name="again")]
    return [
        case("ledger_good", "Get-LaunchCapLedgerFacts", Ledger=LEDGER_GOOD),
        case("ledger_empty", "Get-LaunchCapLedgerFacts", Ledger=[]),
        case("ledger_interpreter_start_only", "Get-LaunchCapLedgerFacts", Ledger=[ev("start", 900.0, frozen=False)]),
        case("ledger_start_without_flag", "Get-LaunchCapLedgerFacts", Ledger=[ev("start", 900.0)]),
        case("ledger_first_frozen_start_and_first_answer", "Get-LaunchCapLedgerFacts", Ledger=frozen_late),
        case("ledger_silent_program_woke", "Get-LaunchCapLedgerFacts", Ledger=[ev("start", 1000.0, frozen=True), ev("woke", 1075.2)]),
        case("ledger_unparsed_line_is_skipped", "Get-LaunchCapLedgerFacts",
             Ledger=[{"parseError": "not json"}, ev("start", 1000.0, frozen=True), {"ev": "start"}, {"t": 1.0}]),
        case("ledger_event_names_are_case_sensitive", "Get-LaunchCapLedgerFacts", Ledger=[ev("Start", 1000.0, frozen=True), ev("ANSWERED", 1050.0)]),
    ]


def excerpt_cases():
    text = "\r\n".join([
        "20.11.2026 09:12:34,56 [INFO] Python file count: 1",
        "20.11.2026 09:12:35,00 [WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent",
        "[INFO] Process ID 4321. If it seems stuck",
        "Launch cap name? \u00e9\u00e8 ok",
        "20.11.2026 09:12:36,00 [INFO] Entry smoke exit=0",
        "20.11.2026 09:12:36,10 [STATUS] Run Status: SUCCESS (Exit Code: 0)",
        "[INFO] " + "x" * 200 + " Entry smoke",
        "nothing to see here",
    ])
    return [
        case("excerpt_keeps_the_lines_that_explain_a_run", "Get-LaunchCapExcerpt", Text=text),
        case("excerpt_is_cut_at_the_limit", "Get-LaunchCapExcerpt", Text=text, Max=2),
        case("excerpt_of_nothing", "Get-LaunchCapExcerpt", Text=""),
    ]


def all_cases(bat):
    return silent_cases() + output_cases() + fact_cases(bat) + pid_cases(bat) + ledger_cases() + excerpt_cases()


# --- the script as text ------------------------------------------------------------------------------------------------------------

def number_after(text, pattern):
    m = re.search(pattern, text)
    return int(m.group(1)) if m else None


def program_text(text, name):
    m = re.search(r"\$%s = @'\n(.*?)\n'@" % re.escape(name), norm(text), re.S)
    return m.group(1) + "\n" if m else None


def script_problems(text):
    t = norm(text)
    found = []
    if not t.isascii():
        found.append("the script holds a character that is not ASCII")
    for rid in ROWS:
        tags = re.findall(r"id\s*=\s*'%s'\s*;\s*req\s*=\s*'([^']*)'" % re.escape(rid), t)
        if len(tags) != 3:
            found.append("%s must be written at 3 sites (the non-Windows skip, the missing batch file and the real row) with a literal req tag, found %d"
                         % (rid, len(tags)))
        found += ["%s carries the tag %r, expected %r" % (rid, g, TAG) for g in tags if g != TAG]
    cap = number_after(t, r"\n\$capSeconds = (\d+)\n")
    after = number_after(t, r"\n\$answerAfterSeconds = (\d+)\n")
    wait = number_after(t, r"\n\$minWaitSeconds = (\d+)\n")
    sleep = number_after(program_text(t, "silentCode") or "", r"time\.sleep\((\d+)\)")
    if cap != 30:
        found.append("the cap the rows hold the bootstrapper to must be 30 seconds, as REQ-018.6 says, found %r" % (cap,))
    if None in (cap, after, wait, sleep):
        found.append("the cap, the answer delay, the shortest wait and the sleep of the silent program must be plain numbers in the script")
    else:
        if after < cap + 10:
            found.append("the answer must be written at least 10 seconds after the cap, or the row cannot tell a run that was stopped at the cap from one that was not")
        if wait < cap + 10:
            found.append("the shortest wait that proves the run was not stopped must be at least 10 seconds past the cap")
        if wait >= after:
            found.append("the shortest wait must be less than the answer delay, since the program is answered after that long")
        if sleep < cap + 15 + 10:
            found.append("the silent program must sleep at least 10 seconds past the upper bound of its window (cap + 15), or it could end by itself inside the window")
    if "\n$runTimeoutMs = 15 * 60 * 1000\n" not in t:
        found.append("the bootstrap needs a 15 minute watchdog so that a hang is a red row")
    if t.count("& taskkill.exe /F /T /PID $proc.Id") != 1:
        found.append("the watchdog must end the whole process tree with taskkill /F /T /PID")
    if t.count("Remove-Item -LiteralPath 'Env:HP_SMOKERUN_KILL_MS'") != 1:
        found.append("the test-only wait override HP_SMOKERUN_KILL_MS must be removed for the bootstrap, the rows are about the production wait")
    if t.count("[Environment]::SetEnvironmentVariable('HP_SMOKERUN_KILL_MS', $killMsBefore)") != 1:
        found.append("the wait override removed for the bootstrap must be restored")
    for name in ("HP_SKIP_ENTRY_SMOKE", "HP_SKIP_EXE_SMOKERUN"):
        if re.search(r"^[^#\n]*%s" % name, t, re.M):
            found.append("%s must not appear in a live line: the verification run is what the rows are about" % name)
    for need in ("HP_SKIP_PIPREQS = '1'", "HP_SKIP_AUTOPEP_DISCOVERY = '1'", "HP_SKIP_NIVISA = '1'"):
        if need not in t:
            found.append("the bootstrap must set %s (no dependency discovery, no driver step)" % need)
    if t.count("$psi.RedirectStandardInput = $true") != 1:
        found.append("the bootstrap must be started with a redirected standard input that the script keeps")
    if t.count("if (-not $needInput) { $proc.StandardInput.Close() }") != 1:
        found.append("the scenario without an answer must close the standard input at once")
    if t.count("$proc.StandardInput.WriteLine($Answer)") != 1:
        found.append("the answer must be written to the standard input exactly once")
    if t.count("Invoke-LaunchCapRun -Name 'silent' -AppCode $silentCode -Answer ''") != 1:
        found.append("the silent scenario must be run with no answer")
    if t.count("Invoke-LaunchCapRun -Name 'output' -AppCode $outputCode -Answer $answerText") != 1:
        found.append("the output scenario must be run with the answer")
    if t.count("[System.Diagnostics.Process]::GetProcessById($id)") != 1 or t.count("($handle.ExitTime - $handle.StartTime).TotalSeconds") != 1:
        found.append("the life of the EXE the runner started must be read from that process's own start and end time")
    prompt = re.search(r"\n\$promptText = '([^']*)'\n", t)
    reply = re.search(r"\n\$replyText = '([^']*)'\n", t)
    answer = re.search(r"\n\$answerText = '([^']*)'\n", t)
    if not (prompt and reply and answer):
        found.append("the prompt, the reply and the answer must be plain strings in the script")
    else:
        if prompt.group(1) != PROMPT or reply.group(1) != REPLY or reply.group(1) != "Launch cap reply: " + answer.group(1):
            found.append("the prompt, the reply and the answer must agree with what the program of the output scenario prints")
    silent_line = next((ln for ln in t.split("\n") if ln.startswith("$silentProblems = @(Get-SilentCapProblems")), None)
    output_line = next((ln for ln in t.split("\n") if ln.startswith("$outputProblems = @(Get-OutputCapProblems")), None)
    if silent_line is None or output_line is None:
        found.append("both rows need their verdict line")
    else:
        for var in ("$silentRun.Finished", "$silentLedger.Started", "$silentRun.ProcId", "$silentRun.LifetimeSeconds",
                    "$silentFacts.ExitText", "$silentFacts.TimedOutLine"):
            if var not in silent_line:
                found.append("the silent verdict must judge %s" % var)
        if re.search(r"\$output(Run|Facts|Ledger)\b", silent_line):
            found.append("the silent verdict reads a value of the other scenario")
        for var in ("$outputRun.Finished", "$outputLedger.Started", "$outputRun.AnswerSent", "$outputLedger.AnsweredT", "$answerDelay",
                    "$outputRun.PromptSeenSeconds", "$outputFacts.ReplySeen", "$outputRun.ProcId", "$outputRun.LifetimeSeconds",
                    "$outputFacts.ExitText", "$outputFacts.TimedOutLine", "$outputFacts.SuccessLine"):
            if var not in output_line:
                found.append("the output verdict must judge %s" % var)
        if re.search(r"\$silent(Run|Facts|Ledger)\b", output_line):
            found.append("the output verdict reads a value of the other scenario")
    if not t.rstrip("\n").endswith("if ((-not $silentPass) -or (-not $outputPass)) { exit 1 }\nexit 0"):
        found.append("the script must end with exit 1 for any red row and exit 0, and the verdict must include both rows")
    return found


def shall_list_problems(text):
    return ["REQ-018.6 is still listed in UNTRACED_SHALLS although both rows are tagged with it"] if re.search(r'^\s*"REQ-018\.6":', text, re.M) else []


def helper_problems(text):
    """What the rows assume of tools/exe_smokerun.ps1: the production wait is 30000 ms, the kill is conditional on no output, and the
    process id is printed right after the start."""
    t = norm(text)
    found = []
    if t.count("\n$killMs = 30000\n") != 1:
        found.append("the helper's default wait must be 30000 ms (the rows pin the cap at 30 seconds)")
    if "if ($env:HP_SMOKERUN_KILL_MS) { $killMs = [int]$env:HP_SMOKERUN_KILL_MS }" not in t:
        found.append("the only way to change the wait must be the HP_SMOKERUN_KILL_MS override the script removes")
    if "(-not $sawOutput)" not in t:
        found.append("the helper must force-stop only a run that produced no output")
    if not re.search(r'^Write-Host "\[INFO\] Process ID \$\(\$p\.Id\)\. ', t, re.M):
        found.append("the helper must print its Process ID line in the form the script reads")
    return found


class ScriptAsText(unittest.TestCase):
    def setUp(self):
        self.text = SCRIPT.read_text(encoding="utf-8")
        self.t = norm(self.text)

    def test_the_real_script_the_helper_and_the_shall_list_are_in_order(self):
        self.assertEqual(script_problems(self.text), [])
        self.assertEqual(helper_problems(HELPER.read_text(encoding="utf-8")), [])
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def has_problem(self, text, needle):
        found = script_problems(text)
        self.assertTrue(any(needle in f for f in found), (needle, found))

    def test_a_row_that_stops_naming_the_shall_is_reported(self):
        bad = mutate(self.t, "id = 'self.launch.cap.output'; req = 'REQ-018.6'; pass = [bool]$outputPass",
                     "id = 'self.launch.cap.output'; req = 'REQ-018'; pass = [bool]$outputPass")
        self.has_problem(bad, "self.launch.cap.output carries the tag")

    def test_a_missing_real_row_is_reported(self):
        bad = mutate(self.t, "id = 'self.launch.cap.silent'; req = 'REQ-018.6'; pass = [bool]$silentPass",
                     "id = 'self.launch.cap.silent_x'; req = 'REQ-018.6'; pass = [bool]$silentPass")
        self.has_problem(bad, "must be written at 3 sites")

    def test_a_cap_other_than_the_shalls_is_reported(self):
        self.has_problem(mutate(self.t, "\n$capSeconds = 30\n", "\n$capSeconds = 25\n"), "must be 30 seconds")

    def test_an_answer_that_comes_too_soon_after_the_cap_is_reported(self):
        self.has_problem(mutate(self.t, "\n$answerAfterSeconds = 46\n", "\n$answerAfterSeconds = 35\n"), "at least 10 seconds after the cap")

    def test_a_shortest_wait_that_is_not_past_the_cap_is_reported(self):
        self.has_problem(mutate(self.t, "\n$minWaitSeconds = 44\n", "\n$minWaitSeconds = 32\n"), "at least 10 seconds past the cap")

    def test_a_shortest_wait_longer_than_the_answer_delay_is_reported(self):
        self.has_problem(mutate(self.t, "\n$minWaitSeconds = 44\n", "\n$minWaitSeconds = 48\n"), "less than the answer delay")

    def test_a_silent_program_that_could_end_inside_its_window_is_reported(self):
        self.has_problem(mutate(self.t, "time.sleep(75)", "time.sleep(40)"), "must sleep at least 10 seconds past")

    def test_a_missing_watchdog_is_reported(self):
        self.has_problem(mutate(self.t, "\n$runTimeoutMs = 15 * 60 * 1000\n", "\n$runTimeoutMs = 0\n"), "15 minute watchdog")
        self.has_problem(mutate(self.t, "& taskkill.exe /F /T /PID $proc.Id", "& taskkill.exe /F /PID $proc.Id"), "whole process tree")

    def test_a_wait_override_that_is_left_in_place_is_reported(self):
        self.has_problem(mutate(self.t, "Remove-Item -LiteralPath 'Env:HP_SMOKERUN_KILL_MS' -ErrorAction SilentlyContinue", "$null = 0"),
                         "must be removed for the bootstrap")

    def test_a_wait_override_that_is_not_restored_is_reported(self):
        self.has_problem(mutate(self.t, "[Environment]::SetEnvironmentVariable('HP_SMOKERUN_KILL_MS', $killMsBefore)", "$null = 0"),
                         "must be restored")

    def test_a_skip_hook_for_the_verification_run_is_reported(self):
        bad = mutate(self.t, "HP_SKIP_PIPREQS = '1';", "HP_SKIP_PIPREQS = '1'; HP_SKIP_EXE_SMOKERUN = '1';")
        self.has_problem(bad, "HP_SKIP_EXE_SMOKERUN must not appear")

    def test_a_bootstrap_with_discovery_left_on_is_reported(self):
        self.has_problem(mutate(self.t, "HP_SKIP_NIVISA = '1'", "HP_SKIP_NIVISA = '0'"), "HP_SKIP_NIVISA = '1'")

    def test_an_input_that_is_not_redirected_is_reported(self):
        self.has_problem(mutate(self.t, "$psi.RedirectStandardInput = $true", "$psi.RedirectStandardInput = $false"), "redirected standard input")

    def test_a_silent_scenario_that_leaves_its_input_open_is_reported(self):
        self.has_problem(mutate(self.t, "if (-not $needInput) { $proc.StandardInput.Close() }", "$null = 0"), "close the standard input at once")

    def test_an_answer_written_twice_is_reported(self):
        bad = mutate(self.t, "$proc.StandardInput.WriteLine($Answer)", "$proc.StandardInput.WriteLine($Answer); $proc.StandardInput.WriteLine($Answer)")
        self.has_problem(bad, "exactly once")

    def test_scenarios_that_swap_their_answers_are_reported(self):
        self.has_problem(mutate(self.t, "-Name 'silent' -AppCode $silentCode -Answer ''", "-Name 'silent' -AppCode $silentCode -Answer $answerText"),
                         "silent scenario must be run with no answer")
        self.has_problem(mutate(self.t, "-Name 'output' -AppCode $outputCode -Answer $answerText", "-Name 'output' -AppCode $outputCode -Answer ''"),
                         "output scenario must be run with the answer")

    def test_a_life_that_is_not_read_from_the_process_is_reported(self):
        self.has_problem(mutate(self.t, "($handle.ExitTime - $handle.StartTime).TotalSeconds", "($exitMs - $pidMs) / 1000.0"), "own start and end time")

    def test_a_prompt_that_disagrees_with_the_program_is_reported(self):
        self.has_problem(mutate(self.t, "\n$promptText = 'Launch cap name? '\n", "\n$promptText = 'Name? '\n"), "must agree with what the program")
        self.has_problem(mutate(self.t, "\n$answerText = 'Sample'\n", "\n$answerText = 'Other'\n"), "must agree with what the program")

    def test_a_verdict_that_reads_the_other_scenario_is_reported(self):
        self.has_problem(mutate(self.t, "-ExitText ([string]$silentFacts.ExitText)", "-ExitText ([string]$outputFacts.ExitText)"),
                         "silent verdict reads a value of the other scenario")
        self.has_problem(mutate(self.t, "-TimedOutLine ([bool]$outputFacts.TimedOutLine) -SuccessLine", "-TimedOutLine ([bool]$silentFacts.TimedOutLine) -SuccessLine"),
                         "output verdict reads a value of the other scenario")

    def test_a_verdict_that_leaves_out_a_value_is_reported(self):
        self.has_problem(mutate(self.t, " -ProcId ([int]$silentRun.ProcId) -LifetimeSeconds ([double]$silentRun.LifetimeSeconds)", " -LifetimeSeconds ([double]$silentRun.LifetimeSeconds)"),
                         "silent verdict must judge $silentRun.ProcId")
        self.has_problem(mutate(self.t, " -SuccessLine ([bool]$outputFacts.SuccessLine)", ""), "output verdict must judge $outputFacts.SuccessLine")

    def test_a_script_that_ends_without_its_exit_lines_is_reported(self):
        self.has_problem(mutate(self.t, "if ((-not $silentPass) -or (-not $outputPass)) { exit 1 }", "if (-not $silentPass) { exit 1 }"), "must end with exit 1")

    def test_a_character_that_is_not_ascii_is_reported(self):
        self.has_problem(self.t + "# caf\u00e9\n", "not ASCII")

    def test_a_helper_that_changed_its_default_wait_is_reported(self):
        text = norm(HELPER.read_text(encoding="utf-8"))
        bad = mutate(text, "\n$killMs = 30000\n", "\n$killMs = 20000\n")
        self.assertTrue(any("30000" in f for f in helper_problems(bad)))
        bad = mutate(text, "if ($env:HP_SMOKERUN_KILL_MS) { $killMs = [int]$env:HP_SMOKERUN_KILL_MS }", "$null = 0")
        self.assertTrue(any("override" in f for f in helper_problems(bad)))

    def test_a_shall_that_is_still_listed_as_a_gap_is_reported(self):
        self.assertTrue(shall_list_problems('    "REQ-018.6": "unit: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-018.60": "unit: x",\n'), [])
        self.assertEqual(shall_list_problems('    "REQ-018.7": "unit: x",\n'), [])


class WorkflowAndRegistry(unittest.TestCase):
    def setUp(self):
        self.wf = norm((REPO / ".github" / "workflows" / "batch-check.yml").read_text(encoding="utf-8"))

    def test_the_script_runs_on_the_contract_uv_lane_and_gates(self):
        step = step_block(self.wf, "selfapps_launch_cap.ps1")
        self.assertIsNotNone(step)
        self.assertIn("matrix.mode == 'contract-uv'", step)
        self.assertIn("!cancelled()", step)
        self.assertIn("shell: pwsh", step)
        self.assertIn("& tests\\selfapps_launch_cap.ps1", step)
        self.assertNotIn("continue-on-error", step)

    def test_the_logs_of_both_scenarios_are_uploaded(self):
        for pattern in ("tests/~selftest_launchcap_*/~lc_*", "tests/~selftest_launchcap_*/~setup.log",
                        "tests/~selftest_launchcap_*/~bootstrap.status.json"):
            self.assertEqual(self.wf.count("            " + pattern + "\n"), 1, pattern)

    def test_the_two_folders_the_pattern_matches_are_the_two_scenarios(self):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(text.count("'~selftest_launchcap_' + $Name"), 1)
        self.assertEqual(sorted(re.findall(r"Invoke-LaunchCapRun -Name '([a-z]+)'", text)), ["output", "silent"])
        self.assertEqual(text.count("'~lc_console.log'"), 1)
        self.assertEqual(text.count("'~lc_ledger.jsonl'"), 1)

    def test_the_registry_names_both_rows_on_their_own_line(self):
        ids = registry_ids((REPO / "docs" / "agent-ndjson.md").read_text(encoding="utf-8"))
        for rid in ROWS:
            self.assertTrue(rid in ids, "%s is not on a line of its own inside a fenced block of docs/agent-ndjson.md" % rid)


# --- the judges on synthetic runs ---------------------------------------------------------------------------------------------------

@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesOnSyntheticRuns(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bat = bat_text()
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, JUDGES, all_cases(cls.bat), d)

    def only(self, name, *needles):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        for needle in needles:
            self.assertIn(needle, found[0], (name, found))

    # --- the silent program ---

    def test_a_silent_run_that_was_stopped_near_the_cap_is_clean(self):
        for name in ("silent_good", "silent_good_at_the_lower_bound", "silent_good_at_the_upper_bound"):
            self.assertEqual(self.r[name], [], name)

    def test_a_silent_run_that_did_not_finish_is_one_problem(self):
        self.only("silent_not_finished", "did not finish")

    def test_a_silent_run_with_no_start_from_the_exe_is_named(self):
        self.only("silent_not_started", "no start line from the built EXE")

    def test_a_silent_run_without_a_process_id_is_named_once(self):
        self.only("silent_no_process_id", "no Process ID line")
        self.only("silent_no_process_id_with_a_lifetime", "no Process ID line")

    def test_a_silent_run_whose_process_could_not_be_watched_is_named(self):
        self.only("silent_not_watched", "could not be watched")

    def test_a_silent_run_that_was_stopped_too_early_is_named_with_its_seconds(self):
        self.only("silent_stopped_too_early", "10.0 s", "before the 30 second mark")
        self.only("silent_just_under_the_lower_bound", "27.9 s")

    def test_a_silent_run_that_was_never_stopped_is_named_with_its_seconds(self):
        self.only("silent_never_stopped", "60.0 s", "more than 45 s", "not force-stopped at 30 seconds")
        self.only("silent_just_over_the_upper_bound", "45.1 s")

    def test_a_silent_run_with_the_wrong_console_outcome_is_named(self):
        self.only("silent_no_exit_line", "no Entry smoke exit line")
        self.only("silent_exit_zero", "exited with 0 and not -1")
        self.only("silent_exit_one", "exited with 1 and not -1")
        self.only("silent_no_timed_out_line", "TIMED OUT status line")

    def test_a_silent_run_with_everything_wrong_names_each_thing(self):
        self.assertEqual(len(self.r["silent_everything_wrong"]), 4, self.r["silent_everything_wrong"])

    # --- the program with a prompt ---

    def test_a_run_that_waited_for_its_answer_is_clean(self):
        for name in ("output_good", "output_good_at_the_lower_bounds"):
            self.assertEqual(self.r[name], [], name)

    def test_a_run_that_did_not_finish_says_whether_the_answer_arrived(self):
        self.only("output_not_finished_answer_lost", "did not finish", "never reached the program")
        self.only("output_not_finished", "did not finish")
        self.assertNotIn("never reached", self.r["output_not_finished"][0])

    def test_a_run_with_no_start_from_the_exe_is_named(self):
        self.only("output_not_started", "no start line from the built EXE")

    def test_a_program_that_was_not_answered_or_answered_too_soon_is_named(self):
        self.only("output_never_answered", "never answered")
        self.only("output_answered_too_early", "answered only 20.0 s", "less than the 44 s")
        self.only("output_answered_just_too_early", "43.9 s")

    def test_a_prompt_that_is_missing_or_late_is_named(self):
        self.only("output_prompt_never_seen", "never showed the prompt")
        self.only("output_prompt_seen_late", "35.0 s", "after the 30 second mark")
        self.only("output_reply_not_seen", "never showed the program reply")

    def test_a_run_without_a_process_id_or_a_lifetime_is_named(self):
        self.only("output_no_process_id", "no Process ID line")
        self.only("output_no_process_id_with_a_lifetime", "no Process ID line")
        self.only("output_not_watched", "could not be watched")

    def test_an_exe_that_was_stopped_before_the_answer_is_named_with_its_seconds(self):
        self.only("output_stopped_at_the_cap", "31.0 s", "before the program had been answered", "stopped a run that had printed a prompt")
        self.only("output_just_under_the_wait", "43.9 s")

    def test_an_output_run_with_the_wrong_console_outcome_is_named(self):
        self.only("output_no_exit_line", "no Entry smoke exit line")
        self.only("output_exit_minus_one", "exited with -1 and not 0")
        self.only("output_exit_one", "exited with 1 and not 0")
        self.only("output_timed_out_line", "TIMED OUT although the program had printed a prompt")
        self.only("output_no_success_line", "no SUCCESS status line")

    def test_an_output_run_with_everything_wrong_names_each_thing(self):
        # A run with no answer has no answer delay to judge, and a run with no Process ID line has no lifetime to judge, so those two
        # comparisons stay quiet and eight things are named, each by its own words.
        got = self.r["output_everything_wrong"]
        self.assertEqual(len(got), 8, got)
        joined = " | ".join(got)
        for fragment in ("no start line from the built EXE", "never answered", "never showed the prompt", "never showed the program reply",
                         "no Process ID line", "no Entry smoke exit line", "TIMED OUT although", "no SUCCESS status line"):
            self.assertIn(fragment, joined)

    # --- the facts a console yields ---

    def test_the_facts_of_the_silent_console_built_from_the_real_lines(self):
        for name in ("facts_silent", "facts_silent_lf_only"):
            got = self.r[name][0]
            self.assertEqual(got["ExitText"], "-1", name)
            self.assertTrue(got["TimedOutLine"], name)
            self.assertFalse(got["SuccessLine"], name)
            self.assertFalse(got["PromptSeen"], name)
            self.assertFalse(got["ReplySeen"], name)

    def test_the_facts_of_the_output_console_do_not_depend_on_where_the_lines_break(self):
        for name in ("facts_output", "facts_output_separate_lines", "facts_output_lf_only"):
            got = self.r[name][0]
            self.assertEqual(got["ExitText"], "0", name)
            self.assertTrue(got["SuccessLine"], name)
            self.assertFalse(got["TimedOutLine"], name)
            self.assertTrue(got["PromptSeen"], name)
            self.assertTrue(got["ReplySeen"], name)

    def test_a_missing_prompt_or_reply_is_a_missing_fact(self):
        got = self.r["facts_output_without_reply"][0]
        self.assertTrue(got["PromptSeen"])
        self.assertFalse(got["ReplySeen"])
        got = self.r["facts_output_without_prompt"][0]
        self.assertFalse(got["PromptSeen"])
        self.assertFalse(got["ReplySeen"])

    def test_a_failed_run_is_neither_timed_out_nor_a_success(self):
        got = self.r["facts_failed"][0]
        self.assertEqual(got["ExitText"], "1")
        self.assertFalse(got["TimedOutLine"])
        self.assertFalse(got["SuccessLine"])

    def test_the_last_exit_line_is_the_outcome(self):
        self.assertEqual(self.r["facts_last_exit_line_wins"][0]["ExitText"], "0")

    def test_no_exit_line_gives_an_empty_code_and_no_status(self):
        for name in ("facts_no_exit_line", "facts_empty_console"):
            got = self.r[name][0]
            self.assertEqual(got["ExitText"], "", name)
            self.assertFalse(got["TimedOutLine"], name)
            self.assertFalse(got["SuccessLine"], name)
        self.assertFalse(self.r["facts_empty_console"][0]["PromptSeen"])

    def test_the_process_id_is_read_from_the_helpers_own_line(self):
        self.assertEqual(self.r["pid_silent"], [4321])
        self.assertEqual(self.r["pid_output_lf_only"], [777])
        self.assertEqual(self.r["pid_none"], [0])
        self.assertEqual(self.r["pid_first_line_wins"], [11])
        self.assertEqual(self.r["pid_too_large_to_be_one"], [0])
        self.assertEqual(self.r["pid_other_text"], [0])

    def test_the_ledger_facts(self):
        got = self.r["ledger_good"][0]
        self.assertEqual((got["Started"], got["StartT"], got["AnsweredT"], got["WokeT"]), (True, 1000, 1046.4, -1))
        got = self.r["ledger_empty"][0]
        self.assertEqual((got["Started"], got["StartT"], got["AnsweredT"], got["WokeT"]), (False, -1, -1, -1))
        for name in ("ledger_interpreter_start_only", "ledger_start_without_flag", "ledger_event_names_are_case_sensitive"):
            got = self.r[name][0]
            self.assertFalse(got["Started"], name)
            self.assertEqual(got["StartT"], -1, name)
        self.assertEqual(self.r["ledger_event_names_are_case_sensitive"][0]["AnsweredT"], -1)

    def test_the_first_frozen_start_and_the_first_answer_are_the_ones_taken(self):
        got = self.r["ledger_first_frozen_start_and_first_answer"][0]
        self.assertEqual((got["Started"], got["StartT"], got["AnsweredT"]), (True, 1000, 1046.4))

    def test_a_program_that_woke_after_its_sleep_is_recorded(self):
        got = self.r["ledger_silent_program_woke"][0]
        self.assertEqual((got["Started"], got["StartT"], got["WokeT"]), (True, 1000, 1075.2))

    def test_an_unparsed_or_incomplete_ledger_line_is_skipped(self):
        got = self.r["ledger_unparsed_line_is_skipped"][0]
        self.assertEqual((got["Started"], got["StartT"]), (True, 1000))

    def test_the_excerpt_keeps_the_lines_that_explain_a_run_in_plain_ascii(self):
        got = self.r["excerpt_keeps_the_lines_that_explain_a_run"]
        self.assertEqual(len(got), 6, got)
        self.assertTrue(all(len(line) <= 150 and line.isascii() for line in got), got)
        self.assertTrue(any("Launch cap name? ??" in line for line in got), got)
        self.assertFalse(any("Python file count" in line for line in got), got)
        self.assertFalse(any("nothing to see" in line for line in got), got)

    def test_the_excerpt_stops_at_its_limit_and_of_nothing_is_nothing(self):
        self.assertEqual(len(self.r["excerpt_is_cut_at_the_limit"]), 2, self.r["excerpt_is_cut_at_the_limit"])
        self.assertEqual(self.r["excerpt_of_nothing"], [])


@unittest.skipUnless(PWSH, "pwsh not available")
class FactsOfARealConsoleDecideTheVerdict(unittest.TestCase):
    """The facts function and the judges are separate functions, and the script feeds the first one's answer to the second. A console
    built from the real lines must give facts that make its own judge clean and the other scenario's judge red, so the two rows cannot
    both pass on one console and a reworded status line cannot go unseen."""

    @classmethod
    def setUpClass(cls):
        cls.bat = bat_text()
        with tempfile.TemporaryDirectory() as d:
            facts = run_cases(SCRIPT, ["Get-LaunchCapLogFacts", "Get-LaunchCapProcessId"], [
                case("silent_facts", "Get-LaunchCapLogFacts", ConsoleText=silent_console(cls.bat), Prompt="", Reply=""),
                case("output_facts", "Get-LaunchCapLogFacts", ConsoleText=output_console(cls.bat), Prompt=PROMPT, Reply=REPLY),
                case("silent_pid", "Get-LaunchCapProcessId", ConsoleText=silent_console(cls.bat, pid=4321)),
                case("output_pid", "Get-LaunchCapProcessId", ConsoleText=output_console(cls.bat, pid=4322)),
            ], d)
        cls.s, cls.o = facts["silent_facts"][0], facts["output_facts"][0]
        cls.spid, cls.opid = facts["silent_pid"][0], facts["output_pid"][0]
        silent_args = dict(Finished=True, Started=True, ProcId=cls.spid, LifetimeSeconds=31.4, ExitText=cls.s["ExitText"],
                           TimedOutLine=cls.s["TimedOutLine"], CapSeconds=30)
        output_args = dict(OUTPUT_GOOD, ProcId=cls.opid, ReplySeen=cls.o["ReplySeen"], ExitText=cls.o["ExitText"],
                           TimedOutLine=cls.o["TimedOutLine"], SuccessLine=cls.o["SuccessLine"])
        # the silent console's facts handed to the output judge, and the other way round
        crossed_to_output = dict(OUTPUT_GOOD, ProcId=cls.spid, ReplySeen=cls.s["ReplySeen"], ExitText=cls.s["ExitText"],
                                 TimedOutLine=cls.s["TimedOutLine"], SuccessLine=cls.s["SuccessLine"])
        crossed_to_silent = dict(SILENT_GOOD, ProcId=cls.opid, ExitText=cls.o["ExitText"], TimedOutLine=cls.o["TimedOutLine"])
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, ["Get-SilentCapProblems", "Get-OutputCapProblems"], [
                case("silent_own", "Get-SilentCapProblems", **silent_args),
                case("output_own", "Get-OutputCapProblems", **output_args),
                case("silent_facts_to_output", "Get-OutputCapProblems", **crossed_to_output),
                case("output_facts_to_silent", "Get-SilentCapProblems", **crossed_to_silent),
            ], d)

    def test_each_console_makes_its_own_judge_clean(self):
        self.assertEqual(self.r["silent_own"], [])
        self.assertEqual(self.r["output_own"], [])

    def test_the_process_ids_are_the_ones_the_helper_printed(self):
        self.assertEqual((self.spid, self.opid), (4321, 4322))

    def test_the_facts_of_one_console_fail_the_judge_of_the_other(self):
        self.assertTrue(any("not 0" in p for p in self.r["silent_facts_to_output"]), self.r["silent_facts_to_output"])
        self.assertTrue(any("TIMED OUT although" in p for p in self.r["silent_facts_to_output"]), self.r["silent_facts_to_output"])
        self.assertTrue(any("no SUCCESS status line" in p for p in self.r["silent_facts_to_output"]), self.r["silent_facts_to_output"])
        self.assertTrue(any("not -1" in p for p in self.r["output_facts_to_silent"]), self.r["output_facts_to_silent"])
        self.assertTrue(any("no TIMED OUT status line" in p for p in self.r["output_facts_to_silent"]), self.r["output_facts_to_silent"])


# --- a judge that quietly stopped judging ---------------------------------------------------------------------------------------------

def func_span(text, name):
    m = re.search(r"^function %s \{\n.*?^\}\n" % re.escape(name), text, re.S | re.M)
    assert m, "the script has no function %s" % name
    return m.start(), m.end()


def mutate_in(text, func, old, new):
    """Replace `old` by `new` inside one function; `old` must occur exactly once in that function (the same text may be in the other one)."""
    start, end = func_span(text, func)
    span = text[start:end]
    assert span.count(old) == 1, "the synthetic case needs %r exactly once inside %s, found %d" % (old, func, span.count(old))
    return text[:start] + span.replace(old, new, 1) + text[end:]


# key -> (function, old text, new text, name of the case that violates only that comparison, the problem the unmutated judge reports)
# A mutated judge may report another problem for the same case (a comparison that falls through to the next), so each case also names
# the sentence of the one the removed comparison reports, which must be gone.
MUTATIONS = {
    "silent_finished": ("Get-SilentCapProblems", "if (-not $Finished) {", "if ($false) {", "silent_not_finished", "did not finish"),
    "silent_started": ("Get-SilentCapProblems", "if (-not $Started) {", "if ($false) {", "silent_not_started", "no start line"),
    "silent_procid": ("Get-SilentCapProblems", "if ($ProcId -le 0) {", "if ($false) {", "silent_no_process_id_with_a_lifetime", "no Process ID line"),
    "silent_watched": ("Get-SilentCapProblems", "} elseif ($LifetimeSeconds -lt 0) {", "} elseif ($false) {", "silent_not_watched", "could not be watched"),
    "silent_early": ("Get-SilentCapProblems", "if ($LifetimeSeconds -lt $lower) {", "if ($false) {", "silent_stopped_too_early", "before the 30 second mark"),
    "silent_late": ("Get-SilentCapProblems", "} elseif ($LifetimeSeconds -gt $upper) {", "} elseif ($false) {", "silent_never_stopped", "not force-stopped"),
    "silent_exit_missing": ("Get-SilentCapProblems", "if ($ExitText -eq '') {", "if ($false) {", "silent_no_exit_line", "no Entry smoke exit line"),
    "silent_exit_wrong": ("Get-SilentCapProblems", "} elseif ($ExitText -ne '-1') {", "} elseif ($false) {", "silent_exit_zero", "and not -1"),
    "silent_timed_out": ("Get-SilentCapProblems", "if (-not $TimedOutLine) {", "if ($false) {", "silent_no_timed_out_line", "TIMED OUT status line"),
    "silent_window_upper": ("Get-SilentCapProblems", "$upper = $CapSeconds + 15", "$upper = $CapSeconds + 600", "silent_never_stopped", "not force-stopped"),
    "silent_window_lower": ("Get-SilentCapProblems", "$lower = $CapSeconds - 2", "$lower = $CapSeconds - 600", "silent_stopped_too_early", "before the 30 second mark"),
    "output_answer_lost": ("Get-OutputCapProblems", "if ($AnswerSent -and (-not $Answered)) {", "if ($false) {", "output_not_finished_answer_lost", "never reached the program"),
    "output_finished": ("Get-OutputCapProblems", "if (-not $Finished) {", "if ($false) {", "output_not_finished", "did not finish"),
    "output_started": ("Get-OutputCapProblems", "if (-not $Started) {", "if ($false) {", "output_not_started", "no start line"),
    "output_answered": ("Get-OutputCapProblems", "if (-not $Answered) {", "if ($false) {", "output_never_answered", "never answered"),
    "output_answer_soon": ("Get-OutputCapProblems", "} elseif ($AnswerDelaySeconds -lt $MinWaitSeconds) {", "} elseif ($false) {", "output_answered_too_early", "answered only"),
    "output_prompt_missing": ("Get-OutputCapProblems", "if ($PromptSeenSeconds -lt 0) {", "if ($false) {", "output_prompt_never_seen", "never showed the prompt"),
    "output_prompt_late": ("Get-OutputCapProblems", "} elseif ($PromptSeenSeconds -gt $CapSeconds) {", "} elseif ($false) {", "output_prompt_seen_late", "after the 30 second mark"),
    "output_reply": ("Get-OutputCapProblems", "if (-not $ReplySeen) {", "if ($false) {", "output_reply_not_seen", "never showed the program reply"),
    "output_procid": ("Get-OutputCapProblems", "if ($ProcId -le 0) {", "if ($false) {", "output_no_process_id_with_a_lifetime", "no Process ID line"),
    "output_watched": ("Get-OutputCapProblems", "} elseif ($LifetimeSeconds -lt 0) {", "} elseif ($false) {", "output_not_watched", "could not be watched"),
    "output_stopped": ("Get-OutputCapProblems", "} elseif ($LifetimeSeconds -lt $MinWaitSeconds) {", "} elseif ($false) {", "output_stopped_at_the_cap", "before the program had been answered"),
    "output_exit_missing": ("Get-OutputCapProblems", "if ($ExitText -eq '') {", "if ($false) {", "output_no_exit_line", "no Entry smoke exit line"),
    "output_exit_wrong": ("Get-OutputCapProblems", "} elseif ($ExitText -ne '0') {", "} elseif ($false) {", "output_exit_minus_one", "and not 0"),
    "output_timed_out": ("Get-OutputCapProblems", "if ($TimedOutLine) {", "if ($false) {", "output_timed_out_line", "TIMED OUT although"),
    "output_success": ("Get-OutputCapProblems", "if (-not $SuccessLine) {", "if ($false) {", "output_no_success_line", "no SUCCESS status line"),
}


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesCanFail(unittest.TestCase):
    """A judge that quietly stopped judging would pass every run, so each comparison is removed from a copy of the script and the one
    run that violates only that comparison must then not be reported for it. The mutated copies run in parallel (one pwsh each), and a
    case whose anchor is missing fails its own test."""

    @classmethod
    def setUpClass(cls):
        cls.bat = bat_text()
        cls.cases = {c["name"]: c for c in all_cases(cls.bat)}
        cls.base = norm(SCRIPT.read_text(encoding="utf-8"))
        cls.tmp = tempfile.TemporaryDirectory()
        cls.results = {}

        def one(key):
            func, old, new, case_name, _needle = MUTATIONS[key]
            try:
                folder = Path(cls.tmp.name) / key
                folder.mkdir()
                script = folder / "mutated.ps1"
                script.write_text(mutate_in(cls.base, func, old, new), encoding="utf-8")
                return key, run_cases(script, [func], [cls.cases[case_name]], folder)[case_name]
            except BaseException as exc:  # reported by the test of the key
                return key, exc

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for key, outcome in pool.map(one, sorted(MUTATIONS)):
                cls.results[key] = outcome

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def blind(self, key):
        outcome = self.results[key]
        if isinstance(outcome, BaseException):
            raise outcome
        needle = MUTATIONS[key][4]
        self.assertFalse(any(needle in p for p in outcome), (key, outcome))

    def test_every_mutation_has_its_case_and_its_needle_in_the_real_judge(self):
        with tempfile.TemporaryDirectory() as d:
            real = run_cases(SCRIPT, ["Get-SilentCapProblems", "Get-OutputCapProblems"],
                             [self.cases[v[3]] for v in MUTATIONS.values()
                              if v[3].startswith(("silent_", "output_"))], d)
        for key, (func, _old, _new, case_name, needle) in sorted(MUTATIONS.items()):
            # the unmutated judge must report the problem the removed comparison is about, or the mutation case proves nothing
            self.assertTrue(any(needle in p for p in real[case_name]), (key, case_name, needle, real[case_name]))

    def test_a_silent_judge_that_ignores_a_run_that_did_not_finish_is_caught(self):
        self.blind("silent_finished")

    def test_a_silent_judge_that_ignores_a_missing_start_is_caught(self):
        self.blind("silent_started")

    def test_a_silent_judge_that_ignores_a_missing_process_id_is_caught(self):
        self.blind("silent_procid")

    def test_a_silent_judge_that_ignores_an_unwatched_process_is_caught(self):
        self.blind("silent_watched")

    def test_a_silent_judge_that_accepts_a_stop_before_the_cap_is_caught(self):
        self.blind("silent_early")

    def test_a_silent_judge_that_accepts_a_run_that_was_never_stopped_is_caught(self):
        self.blind("silent_late")

    def test_a_silent_judge_that_ignores_a_missing_exit_line_is_caught(self):
        self.blind("silent_exit_missing")

    def test_a_silent_judge_that_accepts_any_exit_code_is_caught(self):
        self.blind("silent_exit_wrong")

    def test_a_silent_judge_that_ignores_the_timed_out_line_is_caught(self):
        self.blind("silent_timed_out")

    def test_a_silent_judge_with_a_window_that_has_no_upper_bound_is_caught(self):
        self.blind("silent_window_upper")

    def test_a_silent_judge_with_a_window_that_has_no_lower_bound_is_caught(self):
        self.blind("silent_window_lower")

    def test_an_output_judge_that_ignores_a_lost_answer_is_caught(self):
        self.blind("output_answer_lost")

    def test_an_output_judge_that_ignores_a_run_that_did_not_finish_is_caught(self):
        self.blind("output_finished")

    def test_an_output_judge_that_ignores_a_missing_start_is_caught(self):
        self.blind("output_started")

    def test_an_output_judge_that_ignores_an_unanswered_program_is_caught(self):
        self.blind("output_answered")

    def test_an_output_judge_that_accepts_an_answer_that_came_too_soon_is_caught(self):
        self.blind("output_answer_soon")

    def test_an_output_judge_that_ignores_a_missing_prompt_is_caught(self):
        self.blind("output_prompt_missing")

    def test_an_output_judge_that_accepts_a_late_prompt_is_caught(self):
        self.blind("output_prompt_late")

    def test_an_output_judge_that_ignores_a_missing_reply_is_caught(self):
        self.blind("output_reply")

    def test_an_output_judge_that_ignores_a_missing_process_id_is_caught(self):
        self.blind("output_procid")

    def test_an_output_judge_that_ignores_an_unwatched_process_is_caught(self):
        self.blind("output_watched")

    def test_an_output_judge_that_accepts_an_exe_stopped_before_the_answer_is_caught(self):
        self.blind("output_stopped")

    def test_an_output_judge_that_ignores_a_missing_exit_line_is_caught(self):
        self.blind("output_exit_missing")

    def test_an_output_judge_that_accepts_any_exit_code_is_caught(self):
        self.blind("output_exit_wrong")

    def test_an_output_judge_that_ignores_the_timed_out_line_is_caught(self):
        self.blind("output_timed_out")

    def test_an_output_judge_that_ignores_a_missing_success_line_is_caught(self):
        self.blind("output_success")

    def run_changed(self, func, old, new, case_name):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(mutate_in(self.base, func, old, new), encoding="utf-8")
            return run_cases(script, [func], [self.cases[case_name]], d)[case_name]

    def test_a_facts_function_that_takes_the_first_exit_line_is_caught(self):
        got = self.run_changed("Get-LaunchCapLogFacts", "$exits[$exits.Count - 1]", "$exits[0]", "facts_last_exit_line_wins")
        self.assertEqual(got[0]["ExitText"], "-1")

    def test_a_facts_function_that_takes_a_start_of_the_interpreter_is_caught(self):
        got = self.run_changed("Get-LaunchCapLedgerFacts", "($names -contains 'frozen') -and ($entry.frozen -eq $true)", "$true",
                               "ledger_first_frozen_start_and_first_answer")
        self.assertEqual(got[0]["StartT"], 900)

    def test_a_facts_function_that_takes_the_last_frozen_start_is_caught(self):
        got = self.run_changed("Get-LaunchCapLedgerFacts", "if ((-not $started) -and ", "if (", "ledger_first_frozen_start_and_first_answer")
        self.assertEqual(got[0]["StartT"], 1100)

    def test_a_facts_function_that_takes_the_last_answer_is_caught(self):
        got = self.run_changed("Get-LaunchCapLedgerFacts", "if ($answeredT -lt 0) { $answeredT = [double]$entry.t }", "$answeredT = [double]$entry.t",
                               "ledger_first_frozen_start_and_first_answer")
        self.assertEqual(got[0]["AnsweredT"], 1060)

    def test_a_process_id_reader_that_casts_instead_of_parsing_is_caught(self):
        # A cast throws on a number that does not fit an int, which ends the driver with an error and not with the answer 0.
        with self.assertRaises(AssertionError):
            self.run_changed("Get-LaunchCapProcessId", "[void][int]::TryParse($m.Groups[1].Value, [ref]$id)", "$id = [int]$m.Groups[1].Value",
                             "pid_too_large_to_be_one")


# --- the two programs --------------------------------------------------------------------------------------------------------------

RUNNER = """\
import runpy
import sys
import time

sys.frozen = True  # what a PyInstaller EXE has; the ledger line carries it
slept = []
time.sleep = lambda seconds: slept.append(seconds)
runpy.run_path(sys.argv[1], run_name="__main__")
print("SLEPT " + repr(slept), file=sys.stderr)
"""


def run_program(code, stdin_text=""):
    with tempfile.TemporaryDirectory() as d:
        folder = Path(d)
        (folder / "app.py").write_text(code, encoding="ascii")
        (folder / "runner.py").write_text(RUNNER, encoding="ascii")
        ledger = folder / "ledger.jsonl"
        env = {"LC_LEDGER": str(ledger), "PATH": ""}
        proc = subprocess.run([sys.executable, "-I", str(folder / "runner.py"), str(folder / "app.py")], input=stdin_text, env=env,
                              capture_output=True, text=True, timeout=HARD_TIMEOUT)
        rows = [json.loads(line) for line in ledger.read_text(encoding="ascii").splitlines() if line.strip()] if ledger.exists() else []
        return proc, rows


class TheTwoPrograms(unittest.TestCase):
    def setUp(self):
        self.text = SCRIPT.read_text(encoding="utf-8")

    def test_the_silent_program_prints_nothing_and_sleeps_past_its_window(self):
        code = program_text(self.text, "silentCode")
        self.assertIsNotNone(code)
        compile(code, "silentCode", "exec")
        proc, rows = run_program(code)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "", "a program that is to be silent must print nothing")
        self.assertEqual(proc.stderr.strip(), "SLEPT [75]", proc.stderr)
        self.assertEqual([r["ev"] for r in rows], ["start", "woke"], rows)
        self.assertIs(rows[0]["frozen"], True)
        self.assertLess(rows[0]["t"], rows[1]["t"] + 1)
        self.assertGreater(75, 30 + 15, "the sleep must outlast the upper bound of the window the judge allows")

    def test_the_program_with_a_prompt_prints_what_the_script_looks_for(self):
        code = program_text(self.text, "outputCode")
        self.assertIsNotNone(code)
        compile(code, "outputCode", "exec")
        proc, rows = run_program(code, stdin_text="Sample\n")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, PROMPT + REPLY + "\n", "the prompt has no line end, the reply follows it")
        self.assertEqual([r["ev"] for r in rows], ["start", "answered", "done"], rows)
        self.assertIs(rows[0]["frozen"], True)
        self.assertEqual(rows[1]["name"], "Sample")

    def test_the_program_with_a_prompt_does_not_get_past_the_prompt_without_an_answer(self):
        code = program_text(self.text, "outputCode")
        proc, rows = run_program(code, stdin_text="")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("EOFError", proc.stderr)
        self.assertEqual([r["ev"] for r in rows], ["start"], rows)

    def test_both_programs_write_their_first_ledger_line_before_anything_else(self):
        for name in ("silentCode", "outputCode"):
            code = program_text(self.text, name)
            first = next(i for i, ln in enumerate(code.split("\n")) if ln.startswith('note("start"'))
            later = [i for i, ln in enumerate(code.split("\n")) if ln.startswith(("time.sleep", "name = input"))]
            self.assertTrue(later and first < min(later), name)

    def test_the_programs_use_nothing_outside_the_standard_library(self):
        for name in ("silentCode", "outputCode"):
            code = program_text(self.text, name)
            imported = set(re.findall(r"^import (\w+)", code, re.M)) | set(re.findall(r"^from (\w+) import", code, re.M))
            self.assertTrue(imported <= set(sys.stdlib_module_names) if hasattr(sys, "stdlib_module_names") else imported <= {"json", "os", "sys", "time"}, (name, imported))


if __name__ == "__main__":
    unittest.main()
