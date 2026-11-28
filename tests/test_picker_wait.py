"""Item 133 (README REQ-002.15 and REQ-002.22): the entry picker keeps its question open for 30 seconds and then takes the default.

REQ-002.15 says that after the numbered list of REQ-002.14 the bootstrapper waits 30 seconds for a number; REQ-002.22 says that when
nothing is typed in that time it uses the alphabetical default. Until this item the README called the 30 seconds "read from the batch
file" (tests/test_picker_gate.py, class PickerWait): every row that reaches the picker sets the test setting HP_TEST_FORCE_PICKER,
which shortens the wait to 2 seconds and is the only way past the CI marker, so no row ever waited the real time.

tests/selfapps_picker_wait.ps1 (rows self.entry.picker.wait.control and self.entry.picker.wait; contract-uv lane, gating) bootstraps a
folder with two ambiguous programs with none of the three non-interactivity signals, on a console of its own (a hidden console window,
or a pipe that stays open and silent: a calibration with a bare timed choice says which one holds a wait open), types nothing and
measures from the line "If you do nothing, the alphabetically-first file is used" in the console log to the line "Picker entry
selected" in the setup log. The control run does the same with the test setting and must measure about 2 seconds, so the 30 seconds of
the real run are the product's and not the harness's.

What really happens is shown on Windows by that script. These rules read run_setup.bat, the script, batch-check.yml,
docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, run tools/find_entry.py on the two programs the script writes, and run
the script's own judging functions through a real pwsh on synthetic runs (a run that passes, and one run for each way to be wrong), so a
reworded line the harness waits for, a picker that moved its wait or its answer, a harness that closes standard input (which would make
the question end at once and the row meaningless), a judge that stops judging or a step that stops gating fails here with a sentence,
before a Windows run is needed. Synthetic cases prove each rule can fail. The shared helpers are in tests/judge_support.py.
"""
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import (PWSH, case, cut_block, lines_of, live_bat, live_hash, mutate, norm, registry_ids, run_cases,  # noqa: E402
                           step_block)

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_picker_wait.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
README = REPO / "README.md"
FIND_ENTRY = REPO / "tools" / "find_entry.py"
SCRIPT_NAME = "selfapps_picker_wait.ps1"

ROW_REQS = {"self.entry.picker.wait.control": "REQ-002.15", "self.entry.picker.wait": "REQ-002.15, REQ-002.22"}
ROW_IDS = tuple(ROW_REQS)
GAP_SHALLS = ("REQ-002.15",)

PICK_START = ":pick_entry_interactive"
PICK_END = ":pick_menu_line"

GATES = (
    "if defined NOINPUT exit /b 0",
    "if defined HP_NONINTERACTIVE exit /b 0",
    "if defined HP_CI_LANE if not defined HP_TEST_FORCE_PICKER exit /b 0",
)
MENU_ECHO_TEXT = "Multiple Python files detected"
START_ECHO = "echo   If you do nothing, the alphabetically-first file is used: %HP_ENTRY%"
T30 = 'set "HP_PICK_T=30"'
FORCE = 'if defined HP_TEST_FORCE_PICKER set "HP_PICK_T=2"'
CHOICE = ('choice /C 123456789 /N /T %HP_PICK_T% /D %HP_PICK_DEFAULT% /M "Type a number 1-%HP_PICK_N%, or wait %HP_PICK_T%s for the default '
          '[%HP_PICK_DEFAULT%]: "')
AFTER_CHOICE = 'set "HP_PICK_SEL=%ERRORLEVEL%"'
SELECTED_LOG = 'call :log "[INFO] REQ-002: Picker entry selected: %HP_ENTRY%"'
CALL_SITE = 'if defined HP_ENTRY if "%HP_FIND_RC%"=="3" call :pick_entry_interactive'
# Between the line the clock starts at and the choice, only these may stand; between the choice and the line the clock stops at, nothing
# that waits or asks may stand, or the measured time would not be the choice's.
BETWEEN_START_AND_CHOICE = {"echo.", T30, FORCE}
WAITING_COMMANDS = ("pause", "timeout", "ping", "choice", "set /p", "sleep", "call :pick")

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~selftest_picker_wait/*/~pw_console.log",
    "tests/~selftest_picker_wait/*/~setup.log",
    "tests/~selftest_picker_wait/*/~pw_env*.txt",
    "tests/~selftest_picker_wait/*/~cal.*",
)
JUDGES = ["Get-CalibrationProblems", "Get-PickerFacts", "Get-WaitProblems"]


# --- the batch file: what the script assumes about the picker -----------------------------------------------------------------

def batch_problems(batch):
    """README REQ-002.15 and REQ-002.22 in the batch file: the order of the lines the harness's clock reads, the choice that holds the
    wait, the three signals that the real run leaves unset, and the call site."""
    found = []
    stripped = [ln.strip() for ln in lines_of(batch)]
    for label in (PICK_START, PICK_END):
        n = sum(1 for ln in stripped if ln == label)
        if n != 1:
            found.append("the label %s appears %d time(s); expected exactly once" % (label, n))
    if found:
        return found
    block = cut_block(batch, PICK_START, PICK_END)
    if block is None:
        return ["the block from %s to %s cannot be cut" % (PICK_START, PICK_END)]
    body = [ln.strip() for ln in live_bat(block)]

    def index_of(text, what):
        hits = [i for i, ln in enumerate(body) if ln == text]
        if len(hits) != 1:
            found.append("%s: expected exactly one live line %r in the picker, found %d" % (what, text, len(hits)))
            return None
        return hits[0]

    gates = [index_of(g, "the signal line") for g in GATES]
    menu_hits = [i for i, ln in enumerate(body) if ln.startswith("echo ") and MENU_ECHO_TEXT in ln]
    if len(menu_hits) != 1:
        found.append("the list heading: expected exactly one live echo line with %r, found %d" % (MENU_ECHO_TEXT, len(menu_hits)))
    menu = menu_hits[0] if len(menu_hits) == 1 else None
    start = index_of(START_ECHO, "the line the harness's clock starts at")
    t30 = index_of(T30, "the 30 second setting")
    force = index_of(FORCE, "the test setting's shortening")
    choice = index_of(CHOICE, "the timed choice")
    after_choice = index_of(AFTER_CHOICE, "the line that keeps the answer")
    selected = index_of(SELECTED_LOG, "the line the harness's clock stops at")
    chain = [("the signal lines", max([g for g in gates if g is not None], default=None)), ("the list heading", menu),
             ("the line the clock starts at", start), ("the 30 second setting", t30), ("the test setting's shortening", force),
             ("the timed choice", choice), ("the line that keeps the answer", after_choice), ("the line the clock stops at", selected)]
    known = [(name, at) for name, at in chain if at is not None]
    for (n1, a1), (n2, a2) in zip(known, known[1:]):
        if a1 >= a2:
            found.append("%s must come before %s, or the harness's clock reads the wrong span" % (n1, n2))
    if start is not None and choice is not None and start < choice:
        stray = [ln for ln in body[start + 1:choice] if ln not in BETWEEN_START_AND_CHOICE]
        if stray:
            found.append("lines between the one the clock starts at and the choice would be inside the measured time: %r" % stray)
    if choice is not None and selected is not None and choice < selected:
        waiting = [ln for ln in body[choice + 1:selected] if ln.lower().startswith(WAITING_COMMANDS)]
        if waiting:
            found.append("a command that waits or asks stands between the choice and the line the clock stops at: %r" % waiting)
    if body.count("set /p") or any(ln.lower().startswith("set /p") for ln in body):
        found.append("the picker reads with set /p; the harness's measurement and the 30 second wait are about the timed choice")
    live = [ln.strip() for ln in live_bat(lines_of(batch))]
    if live.count(CALL_SITE) != 1:
        found.append("the picker must be called by exactly one line (%s), found %d" % (CALL_SITE, live.count(CALL_SITE)))
    return found


def marker_problems(batch, script_text):
    """The three texts the harness looks for are lines of the batch file, and the prompt text it checks is the choice's own."""
    found = []
    t = norm(script_text)
    flat = re.sub(r"[ \t]+", " ", t)
    markers = dict(re.findall(r"\$(menuMarker|startMarker|selectedMarker) = '([^']*)'", flat))
    if sorted(markers) != ["menuMarker", "selectedMarker", "startMarker"]:
        return ["the script no longer defines its three markers: found %r" % sorted(markers)]
    live = [ln.strip() for ln in live_bat(lines_of(batch))]
    menu = [ln for ln in live if ln.startswith("echo ") and markers["menuMarker"] in ln]
    if len(menu) != 1:
        found.append("the marker %r is in %d live echo line(s) of the batch file, expected 1" % (markers["menuMarker"], len(menu)))
    expected_start = "echo   If you do nothing, the alphabetically-first file is used: %HP_ENTRY%"
    start_text = markers["startMarker"]
    if "echo " + re.sub(r"^", "  ", start_text.replace("a_app.py", "%HP_ENTRY%")) not in live and expected_start not in live:
        found.append("the start marker %r no longer matches the echo line of the batch file" % start_text)
    if not start_text.endswith(": a_app.py") or not start_text.startswith("If you do nothing, the alphabetically-first file is used"):
        found.append("the start marker must be the batch file's text with HP_ENTRY filled in as a_app.py, found %r" % start_text)
    chosen = [ln for ln in live if ln.startswith("call :log ") and markers["selectedMarker"] in ln]
    if len(chosen) != 1:
        found.append("the marker %r is in %d live call :log line(s) of the batch file, expected 1" % (markers["selectedMarker"], len(chosen)))
    prompt = re.search(r'/M "([^"]*)"', CHOICE).group(1)
    for wait in (30, 2):
        expected = "or wait %ds for the default [1]" % wait
        filled = prompt.replace("%HP_PICK_T%", str(wait)).replace("%HP_PICK_DEFAULT%", "1")
        if expected not in filled:
            found.append("the prompt of the choice, filled in for a wait of %d, does not hold %r" % (wait, expected))
    if "'or wait ' + $ExpectedWait + 's for the default [1]'" not in flat:
        found.append("the script no longer builds the prompt text it looks for from the expected wait")
    return found


def premise_problems(script_text):
    """The two programs the script writes make find_entry choose a_app.py with exit code 3, which is what makes the batch file offer
    the picker, and nothing in them is preferred or guarded."""
    t = norm(script_text)
    a = re.search(r'\$appA = "([^"]*)`n"', t)
    b = re.search(r'\$appB = "([^"]*)`n"', t)
    if not a or not b:
        return ["the script no longer defines $appA and $appB as one-line programs"]
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "a_app.py").write_text(a.group(1).replace("`", "") + "\n", encoding="ascii")
        (Path(d) / "b_app.py").write_text(b.group(1).replace("`", "") + "\n", encoding="ascii")
        proc = subprocess.run([sys.executable, str(FIND_ENTRY)], cwd=d, capture_output=True, text=True)
    found = []
    if proc.stdout.strip() != "a_app.py":
        found.append("find_entry chose %r for the two programs, expected a_app.py" % proc.stdout.strip())
    if proc.returncode != 3:
        found.append("find_entry ended with exit code %d for the two programs, expected the ambiguous code 3" % proc.returncode)
    for name in ("a_app.py", "b_app.py"):
        if "'%s'" % name not in t and "'" + name + "'" not in t and name not in t:
            found.append("the script no longer writes %s" % name)
    return found


# --- the script ----------------------------------------------------------------------------------------------------------------

def script_problems(text):
    t = norm(text)
    live = live_hash(t)
    flat = re.sub(r"[ \t]+", " ", "\n".join(live))
    found = []
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if sorted(ids) != sorted(ROW_IDS):
        found.append("each row id must be a literal at exactly one Write-NdjsonRow call site, found %r" % ids)
    pairs = re.findall(r"\bid = '(self\.entry\.picker\.wait[a-z.]*)'; req = '([^']*)'", t)
    pairs += re.findall(r"id = '(self\.entry\.picker\.wait[a-z.]*)'; req = '([^']*)'", t.replace("\n", " "))
    if not pairs:
        pairs = re.findall(r"id = '(self\.entry\.picker\.wait[a-z.]*)'\s*;\s*req = '([^']*)'", t)
    for rid, req in ROW_REQS.items():
        if (rid, req) not in pairs:
            found.append("the row %s must carry the literal req tag %r" % (rid, req))
    for need in ("$timeLimitSec = 900\n", "-WindowStyle Hidden", "$psi.RedirectStandardInput = $true", "$psi.UseShellExecute = $false",
                 "$psi.CreateNoWindow = $true", "& taskkill.exe /F /T /PID $Started.Proc.Id", "'call run_setup.bat > ~pw_console.log 2>&1'",
                 "'choice /C 123456789 /N /T 5 /D 1 /M \"cal: \" > ~cal.out 2>&1'", "foreach ($m in @('console', 'pipe'))",
                 "Start-Sleep -Milliseconds 200", "if ($sw.Elapsed.TotalSeconds -ge $timeLimitSec)",
                 "-SetLines @('set \"HP_TEST_FORCE_PICKER=1\"') -Expected 2", "-SetLines @() -Expected 30",
                 "-ExpectFlags @('HP_TEST_FORCE_PICKER') -Expected 2", "-ExpectFlags @() -Expected 30",
                 "$_ -match '^(HP_|PVW_)' -or $_ -ieq 'NOINPUT'", "$item.Name -match '^(HP_|PVW_)' -or $item.Name -ieq 'NOINPUT'"):
        if need not in flat:
            found.append("the script no longer holds %s" % need)
    for need in ("$seconds -lt 4.0", "$Seconds -lt 4.0", "$Seconds -gt 20.0", "$WaitSec -lt ($Expected - 1)", "$WaitSec -gt ($Expected + 8)"):
        if need.lower() in flat.lower():
            break
    else:
        found.append("the bounds of the judges are no longer the pinned ones")
    for need in ("$Seconds -lt 4.0", "$Seconds -gt 20.0", "$WaitSec -lt ($Expected - 1)", "$WaitSec -gt ($Expected + 8)"):
        if need not in flat:
            found.append("the judge no longer compares with %s" % need)
    # The question must be open on a real console or an open pipe: closing standard input would end it at once.
    if re.search(r"<\s*nul", flat, re.I):
        found.append("the script closes standard input (< nul) somewhere; the picker's question must stay open, which is what the row measures")
    if "RedirectStandardInput = $true" not in flat or "$holder = $proc.StandardInput" not in flat:
        found.append("the pipe method no longer keeps its standard input open through a holder")
    if "$Started.Holder.Dispose()" not in flat:
        found.append("the pipe method no longer releases its holder after the process is stopped")
    # the flags
    if "Remove-Item -LiteralPath ('Env:' + $name)" not in flat:
        found.append("the runner's HP_, PVW_ and NOINPUT variables are no longer removed from the process")
    if "[Environment]::SetEnvironmentVariable($name, $scrubbed[$name])" not in flat:
        found.append("the variables that were removed are no longer restored in finally")
    if "set \"' + $_ + '=\"'" not in flat:
        found.append("the wrapper no longer clears the removed variables itself")
    for need in ("'set HP_> ~pw_env.txt 2>nul'", "'set PVW_>> ~pw_env.txt 2>nul'", "'set NOINPUT>> ~pw_env.txt 2>nul'"):
        if need not in flat:
            found.append("the wrapper no longer lists the flags the bootstrap started with: %s is missing" % need)
    order = [flat.find("$clearLines +"), flat.find("$SetLines +"), flat.find("$listAfter +")]
    if min(order) < 0 or order != sorted(order):
        found.append("the wrapper must clear the flags, then apply the scenario's setting, then list them (the listing is the verdict)")
    # the judges and how they are called
    call_args = {
        "Get-CalibrationProblems": ("-Method $Method", "-Finished ([bool]$finished)", "-Seconds ([double]$seconds)", "-RcText $rc"),
        "Get-PickerFacts": ("-Console $consoleText", "-SetupLog $setupText", "-ExpectedWait $Expected", "-MenuMarker $menuMarker",
                            "-StartMarker $startMarker", "-SelectedMarker $selectedMarker"),
        "Get-WaitProblems": ("-HarnessOk $HarnessOk", "-EnvDumped ([bool]$Run.EnvDumped)", "-FlagsSeen @($Run.FlagsSeen)",
                             "-ExpectFlags $ExpectFlags", "-MenuSeen ([bool]$Run.Facts.menuSeen)", "-PromptSeen ([bool]$Run.Facts.promptSeen)",
                             "-Selected ([string]$Run.Facts.selected)", "-ExpectSelected 'a_app.py'", "-WaitSec ([double]$Run.WaitSec)",
                             "-Expected $Expected", "-TimedOut ([bool]$Run.TimedOut)"),
    }
    for name, needs in call_args.items():
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the judging function %s is missing" % name)
        position = flat.find("(%s " % name)
        if position < 0:
            position = flat.find("= %s " % name)
        if position < 0:
            found.append("%s is no longer called" % name)
            continue
        args = flat[position:position + 900]
        for need in needs:
            if need not in args:
                found.append("the call of %s no longer hands %s" % (name, need))
    if "$harnessOk = ($method -ne '')" not in flat:
        found.append("the harness is no longer judged by whether a method passed the calibration")
    if "if ($method -eq '' -and @($c.Problems).Count -eq 0) { $method = $c.Method }" not in flat:
        found.append("the first method whose calibration has no problem is no longer the one used")
    for var in ("controlPass", "rowPass"):
        if "$%s = [bool]($harnessOk -and" % var not in flat:
            found.append("the row of %s is no longer false when no harness method held a wait open" % var)
    for var in ("controlPass", "rowPass"):
        if "pass = $%s" % var not in flat:
            found.append("the row of %s no longer writes pass = $%s" % (var, var))
    if "OSVersion.Platform -ne [System.PlatformID]::Win32NT" not in flat or re.search(r"\$IsWindows\b", flat):
        found.append("the Windows check must use OSVersion.Platform and not $IsWindows")
    if "skip = $true" not in flat:
        found.append("the rows no longer skip off Windows with skip = $true")
    if "if (-not $allPass) { exit 1 }" not in flat:
        found.append("the script no longer exits 1 for a red row")
    # a stop before the rows must never be silent (CodeRabbit, PR #548): every id not written is written red after the main block
    for rid in ROW_IDS:
        if "$rowsWritten['%s'] = $true" % rid not in flat:
            found.append("the row %s is no longer recorded as written" % rid)
    if not re.search(r"\} catch \{\s*\$crashMessage = [^\n]*\n\s*\$allPass = \$false\s*\} finally \{", flat):
        found.append("an unexpected stop in the main block is no longer caught and counted as a red run")
    # the work folder and the flag scrub sit INSIDE the guarded block, so a stop in them is a red row per id and never an absence
    guard_open = flat.find("$crashMessage = ''\ntry {")
    guard_close = flat.find("} catch {\n$crashMessage =")
    for need in ("New-Item -ItemType Directory -Force -Path $workRoot -ErrorAction Stop", "Remove-Item -LiteralPath ('Env:' + $name)",
                 "$parentStillSet = @($scrubbed.Keys"):
        at = flat.find(need)
        if guard_open < 0 or guard_close < 0 or not (guard_open < at < guard_close):
            found.append("the setup line %s is not inside the guarded block, so a stop in it would leave no row" % need)
    after = flat.rsplit("} finally {", 1)[-1]  # the main block's finally is the last one; two functions have their own
    if not re.search(r"foreach \(\$rowId in \$allIds\) \{\s*if \(-not \$rowsWritten\.ContainsKey\(\$rowId\)\) \{\s*\$allPass = \$false\s*Write-NdjsonRow", after):
        found.append("an id the script has not written is no longer written as a failing row after the main block")
    if after.find("pass = $false; desc = 'Entry picker wait: the script stopped before this row was written'") < 0:
        found.append("the row for a script that stopped early is no longer red with its reason")
    if after.find("foreach ($rowId in $allIds)") > after.find("if (-not $allPass) { exit 1 }") or after.find("foreach ($rowId in $allIds)") < 0:
        found.append("the rows for a script that stopped early must be written before the exit code is decided")
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0")
    if any(ord(ch) > 127 for ch in text):
        found.append("the script holds a character that is not ASCII")
    return found


# --- the workflow, the registry, the shall list and the README ------------------------------------------------------------------

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
    have = registry_ids(text)
    return ["%s is not in docs/agent-ndjson.md" % row for row in ROW_IDS if row not in have]


def shall_list_problems(text):
    """The shall the row traces is no longer listed as a unit-only entry (the shall-level ratchet only warns about a stale entry)."""
    return ["%s is still listed in UNTRACED_SHALLS although a row is tagged with it" % shall
            for shall in GAP_SHALLS if re.search(r'^\s*"%s":' % re.escape(shall), text, re.M)]


def readme_problems(text):
    flat = " ".join(norm(text).split())
    found = []
    if "so no row waits the full time" in flat:
        found.append("the README still says that no row waits the full time (REQ-002.15 note)")
    if "self.entry.picker.wait" not in flat:
        found.append("the README note of REQ-002.15 does not name the row that measures the full wait")
    return found


# --- the script's judging functions, run through a real pwsh ----------------------------------------------------------------------

MENU = "Multiple Python files detected -- no clear entry point, so please choose one to run:"
START = "If you do nothing, the alphabetically-first file is used: a_app.py"
PROMPT_30 = "Type a number 1-2, or wait 30s for the default [1]: "
PROMPT_2 = "Type a number 1-2, or wait 2s for the default [1]: "
SETUP_SELECTED = "[2026-11-28 10:00:00.00] [INFO] REQ-002: Picker entry selected: a_app.py\r\n"


def console_of(prompt):
    return "\r\n".join(["[2026-11-28 10:00:00.00] [INFO] starting", MENU, "  [1] a_app.py", "  [2] b_app.py", "  " + START, prompt]) + "\r\n"


def cal_args(**over):
    args = dict(Method="console", Finished=True, Seconds=5.2, RcText="1\r\n")
    args.update(over)
    return args


def facts_args(**over):
    args = dict(Console=console_of(PROMPT_30), SetupLog=SETUP_SELECTED, ExpectedWait=30, MenuMarker=MENU_ECHO_TEXT, StartMarker=START,
                SelectedMarker="Picker entry selected: ")
    args.update(over)
    return args


def wait_args(**over):
    args = dict(Label="real", HarnessOk=True, EnvDumped=True, FlagsSeen=[], ExpectFlags=[], MenuSeen=True, PromptSeen=True,
                Selected="a_app.py", ExpectSelected="a_app.py", WaitSec=30.4, Expected=30, TimedOut=False)
    args.update(over)
    return args


def judge_cases():
    c = []
    cal, fac, wai = "Get-CalibrationProblems", "Get-PickerFacts", "Get-WaitProblems"
    # --- Get-CalibrationProblems
    c.append(case("cal_good", cal, **cal_args()))
    c.append(case("cal_unfinished", cal, **cal_args(Finished=False, Seconds=40.0, RcText="")))
    c.append(case("cal_returned_at_once", cal, **cal_args(Seconds=0.2)))
    c.append(case("cal_low_edge_passes", cal, **cal_args(Seconds=4.0)))
    c.append(case("cal_just_below_low_edge", cal, **cal_args(Seconds=3.9)))
    c.append(case("cal_high_edge_passes", cal, **cal_args(Seconds=20.0)))
    c.append(case("cal_just_above_high_edge", cal, **cal_args(Seconds=20.1)))
    c.append(case("cal_wrong_answer", cal, **cal_args(RcText="255\r\n")))
    c.append(case("cal_no_answer", cal, **cal_args(RcText="")))
    # --- Get-PickerFacts
    c.append(case("facts_good", fac, **facts_args()))
    c.append(case("facts_nothing", fac, **facts_args(Console="", SetupLog="")))
    c.append(case("facts_prompt_for_another_wait", fac, **facts_args(Console=console_of(PROMPT_2))))
    c.append(case("facts_default_line_missing", fac, **facts_args(Console=console_of(PROMPT_30).replace(START, "x"))))
    c.append(case("facts_no_menu", fac, **facts_args(Console=console_of(PROMPT_30).replace(MENU_ECHO_TEXT, "x"))))
    c.append(case("facts_other_file_selected", fac, **facts_args(SetupLog=SETUP_SELECTED.replace("a_app.py", "b_app.py"))))
    c.append(case("facts_forced_wait", fac, **facts_args(Console=console_of(PROMPT_2), ExpectedWait=2)))
    # --- Get-WaitProblems
    c.append(case("wait_good", wai, **wait_args()))
    c.append(case("wait_forced_good", wai, **wait_args(Label="forced", FlagsSeen=["HP_TEST_FORCE_PICKER"], ExpectFlags=["HP_TEST_FORCE_PICKER"],
                                                       WaitSec=2.4, Expected=2)))
    c.append(case("wait_no_harness", wai, **wait_args(HarnessOk=False, WaitSec=-1.0)))
    c.append(case("wait_env_not_dumped", wai, **wait_args(EnvDumped=False)))
    c.append(case("wait_flag_that_must_not_be_there", wai, **wait_args(FlagsSeen=["HP_CI_LANE"])))
    c.append(case("wait_flag_that_is_missing", wai, **wait_args(Label="forced", ExpectFlags=["HP_TEST_FORCE_PICKER"], WaitSec=2.4, Expected=2)))
    c.append(case("wait_flags_in_another_order_and_case", wai, **wait_args(FlagsSeen=["b_flag", "A_FLAG"], ExpectFlags=["a_flag", "B_FLAG"])))
    c.append(case("wait_no_menu", wai, **wait_args(MenuSeen=False)))
    c.append(case("wait_no_prompt", wai, **wait_args(PromptSeen=False)))
    c.append(case("wait_other_file", wai, **wait_args(Selected="b_app.py")))
    c.append(case("wait_nothing_selected", wai, **wait_args(Selected="", WaitSec=-1.0, TimedOut=True)))
    c.append(case("wait_not_measured_time_limit", wai, **wait_args(WaitSec=-1.0, TimedOut=True)))
    c.append(case("wait_not_measured_run_ended", wai, **wait_args(WaitSec=-1.0, TimedOut=False)))
    c.append(case("wait_too_short", wai, **wait_args(WaitSec=12.0)))
    c.append(case("wait_low_edge_passes", wai, **wait_args(WaitSec=29.0)))
    c.append(case("wait_just_below_low_edge", wai, **wait_args(WaitSec=28.9)))
    c.append(case("wait_high_edge_passes", wai, **wait_args(WaitSec=38.0)))
    c.append(case("wait_just_above_high_edge", wai, **wait_args(WaitSec=38.1)))
    c.append(case("wait_forced_but_full_time", wai, **wait_args(Label="forced", FlagsSeen=["HP_TEST_FORCE_PICKER"], ExpectFlags=["HP_TEST_FORCE_PICKER"],
                                                                WaitSec=30.5, Expected=2)))
    c.append(case("wait_forced_but_no_wait", wai, **wait_args(Label="forced", FlagsSeen=["HP_TEST_FORCE_PICKER"], ExpectFlags=["HP_TEST_FORCE_PICKER"],
                                                              WaitSec=0.2, Expected=2)))
    return c


# One problem each, and the words that problem must hold.
ONE_PROBLEM = {
    "cal_unfinished": "the calibration choice did not return within its time limit",
    "cal_returned_at_once": "returned after 0.2 s, so it did not wait for the 5 seconds it was given",
    "cal_just_below_low_edge": "returned after 3.9 s",
    "cal_just_above_high_edge": "took 20.1 s for a wait of 5 seconds",
    "cal_wrong_answer": "left the answer [255",
    "cal_no_answer": "left the answer []",
    "wait_no_harness": "no harness method held a timed choice open in the calibration",
    "wait_env_not_dumped": "the environment listing was not written",
    "wait_flag_that_must_not_be_there": "the run started with the flags [HP_CI_LANE], expected []",
    "wait_flag_that_is_missing": "the run started with the flags [], expected [HP_TEST_FORCE_PICKER]",
    "wait_no_menu": "the numbered list was never printed",
    "wait_no_prompt": "the prompt of the choice does not say that it waits 30 seconds",
    "wait_other_file": "the picker selected [b_app.py], expected the alphabetical default [a_app.py]",
    "wait_not_measured_time_limit": "the picker had not answered within the time limit",
    "wait_not_measured_run_ended": "the run ended before the picker's wait could be measured",
    "wait_too_short": "the question was open for 12 s, expected about 30 s (at least 29)",
    "wait_just_below_low_edge": "the question was open for 28.9 s",
    "wait_just_above_high_edge": "the question was open for 38.1 s, expected about 30 s (at most 38)",
    "wait_forced_but_full_time": "the question was open for 30.5 s, expected about 2 s (at most 10)",
    "wait_forced_but_no_wait": "the question was open for 0.2 s, expected about 2 s (at least 1)",
}
CLEAN_CASES = ("cal_good", "cal_low_edge_passes", "cal_high_edge_passes", "wait_good", "wait_forced_good", "wait_low_edge_passes",
               "wait_high_edge_passes", "wait_flags_in_another_order_and_case")


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

    def test_a_clean_run_and_each_edge_that_is_still_inside_has_no_problem(self):
        for name in CLEAN_CASES:
            with self.subTest(case=name):
                self.assertEqual(self.r[name], [])

    def test_each_wrong_run_below_is_one_problem_with_its_own_sentence(self):
        for name, needle in sorted(ONE_PROBLEM.items()):
            with self.subTest(case=name):
                self.only(name, needle)

    def test_an_unfinished_calibration_is_one_problem_and_nothing_else(self):
        self.assertEqual(len(self.r["cal_unfinished"]), 1)

    def test_a_missing_harness_is_one_problem_whatever_else_the_run_shows(self):
        self.assertEqual(len(self.r["wait_no_harness"]), 1)

    def test_a_pick_that_never_happened_names_the_missing_pick_and_the_missing_measurement(self):
        found = self.r["wait_nothing_selected"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(any("the picker selected []" in f for f in found), found)
        self.assertTrue(any("had not answered within the time limit" in f for f in found), found)

    def test_the_facts_of_a_good_console_and_log_are_the_four_expected_values(self):
        good = self.r["facts_good"][0]
        self.assertEqual(good, {"menuSeen": True, "defaultLine": True, "promptSeen": True, "selected": "a_app.py"})
        self.assertEqual(self.r["facts_forced_wait"][0]["promptSeen"], True)

    def test_each_fact_turns_false_for_its_own_reason(self):
        self.assertEqual(self.r["facts_nothing"][0], {"menuSeen": False, "defaultLine": False, "promptSeen": False, "selected": ""})
        self.assertEqual(self.r["facts_prompt_for_another_wait"][0]["promptSeen"], False)
        self.assertEqual(self.r["facts_default_line_missing"][0]["defaultLine"], False)
        self.assertEqual(self.r["facts_default_line_missing"][0]["promptSeen"], True)
        self.assertEqual(self.r["facts_no_menu"][0]["menuSeen"], False)
        self.assertEqual(self.r["facts_other_file_selected"][0]["selected"], "b_app.py")


# --- the rules on the real files -------------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_picker_keeps_the_order_the_clock_reads_and_the_choice_that_holds_the_wait(self):
        self.assertEqual(batch_problems(self.batch), [])

    def test_the_texts_the_harness_waits_for_are_lines_of_the_batch_file(self):
        self.assertEqual(marker_problems(self.batch, self.script), [])

    def test_the_two_programs_make_find_entry_choose_a_app_with_exit_code_3(self):
        self.assertEqual(premise_problems(self.script), [])

    def test_the_script_has_its_rows_harness_judges_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shall_is_no_longer_listed_as_a_unit_only_entry(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_readme_names_the_row_that_measures_the_full_wait(self):
        self.assertEqual(readme_problems(README.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        block = cut_block(self.batch, PICK_START, PICK_END)
        self.assertGreater(len(live_bat(block)), 30)
        # 36 cases = 9 of the calibration + 7 of the facts + 20 of the wait problems; one added or dropped changes the sum on purpose.
        self.assertEqual(len(judge_cases()), 9 + 7 + 20)
        self.assertEqual(len(ONE_PROBLEM) + len(CLEAN_CASES), 28)
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))


class BatchRulesCanFail(unittest.TestCase):
    """Each rule about run_setup.bat is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")

    def problems(self, batch):
        return batch_problems(batch)

    def test_a_missing_or_duplicated_label_is_reported(self):
        gone = mutate(self.batch, "\n:pick_menu_line\n", "\n:pick_menu_linex\n")
        self.assertTrue(any("appears 0 time(s)" in f for f in self.problems(gone)), self.problems(gone))
        twice = self.batch + "\n:pick_menu_line\n"
        self.assertTrue(any("appears 2 time(s)" in f for f in self.problems(twice)), self.problems(twice))

    def test_a_changed_wait_is_reported(self):
        bad = mutate(self.batch, T30, 'set "HP_PICK_T=20"')
        self.assertTrue(any("the 30 second setting" in f and "found 0" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_changed_test_setting_is_reported(self):
        bad = mutate(self.batch, FORCE, 'if defined HP_TEST_FORCE_PICKER set "HP_PICK_T=5"')
        self.assertTrue(any("the test setting's shortening" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_choice_with_another_time_or_default_is_reported(self):
        bad = mutate(self.batch, "choice /C 123456789 /N /T %HP_PICK_T% /D %HP_PICK_DEFAULT%", "choice /C 123456789 /N /T 10 /D %HP_PICK_DEFAULT%")
        self.assertTrue(any("the timed choice" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "choice /C 123456789 /N /T %HP_PICK_T% /D %HP_PICK_DEFAULT%", "choice /C 123456789 /N /T %HP_PICK_T% /D 1")
        self.assertTrue(any("the timed choice" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_signal_line_that_is_missing_is_reported(self):
        for gate in GATES:
            with self.subTest(gate=gate):
                bad = mutate(self.batch, gate + "\n", "")
                self.assertTrue(any("the signal line" in f and "found 0" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_signal_line_after_the_list_is_reported(self):
        gate = GATES[1]
        moved = mutate(self.batch, gate + "\n", "")
        moved = mutate(moved, "set \"HP_PICK_I=0\"\nset \"HP_PICK_DEFAULT=1\"\n", "set \"HP_PICK_I=0\"\nset \"HP_PICK_DEFAULT=1\"\n" + gate + "\n")
        self.assertTrue(any("the signal lines must come before the list heading" in f for f in self.problems(moved)), self.problems(moved))

    def test_a_start_line_that_moved_after_the_choice_is_reported(self):
        moved = mutate(self.batch, START_ECHO + "\n", "")
        moved = mutate(moved, AFTER_CHOICE + "\n", AFTER_CHOICE + "\n" + START_ECHO + "\n")
        found = self.problems(moved)
        self.assertTrue(any("must come before the timed choice" in f or "must come before the 30 second setting" in f for f in found), found)

    def test_a_reworded_start_or_selected_line_is_reported(self):
        bad = mutate(self.batch, START_ECHO, "echo   Otherwise the first file is used: %HP_ENTRY%")
        self.assertTrue(any("the line the harness's clock starts at" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, SELECTED_LOG, 'call :log "[INFO] REQ-002: Entry chosen: %HP_ENTRY%"')
        self.assertTrue(any("the line the harness's clock stops at" in f for f in self.problems(bad)), self.problems(bad))
        self.assertTrue(any("Picker entry selected: " in f for f in marker_problems(bad, self.script)), marker_problems(bad, self.script))

    def test_a_command_that_waits_inside_the_measured_span_is_reported(self):
        bad = mutate(self.batch, 'set "HP_PICK_T=30"\n', 'set "HP_PICK_T=30"\ntimeout /t 3 >nul\n')
        self.assertTrue(any("would be inside the measured time" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, AFTER_CHOICE + "\n", AFTER_CHOICE + "\npause\n")
        self.assertTrue(any("waits or asks stands between the choice" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_picker_that_reads_with_set_p_is_reported(self):
        bad = mutate(self.batch, AFTER_CHOICE + "\n", AFTER_CHOICE + "\nset /p HP_PICK_X=x\n")
        self.assertTrue(any("set /p" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_second_or_missing_call_site_is_reported(self):
        bad = mutate(self.batch, CALL_SITE + "\n", "")
        self.assertTrue(any("exactly one line" in f and "found 0" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, CALL_SITE + "\n", CALL_SITE + "\n" + CALL_SITE + "\n")
        self.assertTrue(any("exactly one line" in f and "found 2" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_prompt_that_no_longer_says_the_wait_is_reported(self):
        bad = mutate(self.batch, "or wait %HP_PICK_T%s for the default", "or wait for the default")
        self.assertTrue(any("the timed choice" in f for f in self.problems(bad)), self.problems(bad))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")

    def has(self, text, needle):
        return any(needle in f for f in script_problems(text))

    def test_a_row_id_that_stops_being_a_literal_is_reported(self):
        bad = mutate(self.script, "id = 'self.entry.picker.wait.control'; req = 'REQ-002.15'; pass = $controlPass",
                     "id = $controlId; req = 'REQ-002.15'; pass = $controlPass")
        self.assertTrue(self.has(bad, "each row id must be a literal"))

    def test_a_changed_req_tag_is_reported(self):
        bad = mutate(self.script, "id = 'self.entry.picker.wait'; req = 'REQ-002.15, REQ-002.22'", "id = 'self.entry.picker.wait'; req = 'REQ-002.15'")
        self.assertTrue(self.has(bad, "must carry the literal req tag 'REQ-002.15, REQ-002.22'"))

    def test_closing_standard_input_is_reported(self):
        bad = mutate(self.script, "'call run_setup.bat > ~pw_console.log 2>&1'", "'call run_setup.bat > ~pw_console.log 2>&1 < nul'")
        found = script_problems(bad)
        self.assertTrue(any("closes standard input" in f for f in found), found)
        self.assertTrue(any("'call run_setup.bat > ~pw_console.log 2>&1'" in f for f in found), found)

    def test_a_pipe_that_is_no_longer_held_open_is_reported(self):
        bad = mutate(self.script, "$holder = $proc.StandardInput", "$holder = $null")
        self.assertTrue(self.has(bad, "keeps its standard input open through a holder"))

    def test_a_missing_process_tree_stop_is_reported(self):
        bad = mutate(self.script, "& taskkill.exe /F /T /PID $Started.Proc.Id 2>&1 | Out-Null", "$Started.Proc.Kill()")
        self.assertTrue(self.has(bad, "taskkill.exe /F /T /PID"))

    def test_a_changed_time_limit_is_reported(self):
        bad = mutate(self.script, "$timeLimitSec = 900", "$timeLimitSec = 9000")
        self.assertTrue(self.has(bad, "$timeLimitSec = 900"))

    def test_a_changed_bound_is_reported(self):
        bad = mutate(self.script, "if ($WaitSec -gt ($Expected + 8))", "if ($WaitSec -gt ($Expected + 15))")
        self.assertTrue(self.has(bad, "$WaitSec -gt ($Expected + 8)"))
        bad = mutate(self.script, "if ($Seconds -lt 4.0)", "if ($Seconds -lt 1.0)")
        self.assertTrue(self.has(bad, "$Seconds -lt 4.0"))

    def test_a_control_that_expects_the_full_time_is_reported(self):
        bad = mutate(self.script, "-SetLines @('set \"HP_TEST_FORCE_PICKER=1\"') -Expected 2", "-SetLines @('set \"HP_TEST_FORCE_PICKER=1\"') -Expected 30")
        self.assertTrue(self.has(bad, "-SetLines @('set \"HP_TEST_FORCE_PICKER=1\"') -Expected 2"))

    def test_a_real_run_with_a_setting_is_reported(self):
        bad = mutate(self.script, "-SetLines @() -Expected 30", "-SetLines @('set \"HP_TEST_FORCE_PICKER=1\"') -Expected 30")
        self.assertTrue(self.has(bad, "-SetLines @() -Expected 30"))

    def test_flags_that_are_not_removed_or_restored_are_reported(self):
        bad = mutate(self.script, "{ Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }", "{ $null = $name }")
        self.assertTrue(self.has(bad, "no longer removed from the process"))
        bad = mutate(self.script, "[Environment]::SetEnvironmentVariable($name, $scrubbed[$name])", "$null = $name")
        self.assertTrue(self.has(bad, "no longer restored in finally"))

    def test_a_wrapper_that_lists_before_it_clears_is_reported(self):
        bad = mutate(self.script, "@('@echo off') + $listBefore + $clearLines + $SetLines + $listAfter", "@('@echo off') + $listBefore + $listAfter + $clearLines + $SetLines")
        self.assertTrue(self.has(bad, "must clear the flags, then apply the scenario's setting, then list them"))

    def test_a_harness_that_is_not_the_first_passing_method_is_reported(self):
        bad = mutate(self.script, "if ($method -eq '' -and @($c.Problems).Count -eq 0) { $method = $c.Method }", "$method = $c.Method")
        self.assertTrue(self.has(bad, "the first method whose calibration has no problem is no longer the one used"))

    def test_a_row_that_stays_green_without_a_harness_is_reported(self):
        bad = mutate(self.script, "$rowPass = [bool]($harnessOk -and", "$rowPass = [bool](")
        self.assertTrue(self.has(bad, "no longer false when no harness method held a wait open"))

    def test_a_judge_that_loses_an_argument_is_reported(self):
        bad = mutate(self.script, "-PromptSeen ([bool]$Run.Facts.promptSeen) ", "")
        self.assertTrue(self.has(bad, "the call of Get-WaitProblems no longer hands -PromptSeen"))
        bad = mutate(self.script, "-RcText $rc", "-RcText ''")
        self.assertTrue(self.has(bad, "the call of Get-CalibrationProblems no longer hands -RcText $rc"))

    def test_a_script_that_no_longer_exits_with_its_own_code_is_reported(self):
        bad = mutate(self.script, "if (-not $allPass) { exit 1 }", "")
        self.assertTrue(self.has(bad, "no longer exits 1"))
        self.assertTrue(self.has(self.script.rstrip() + "\n# end\nexit 2\n", "does not end with exit 0"))

    def test_the_windows_check_with_isWindows_is_reported(self):
        bad = mutate(self.script, "[System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT", "-not $IsWindows")
        self.assertTrue(self.has(bad, "must use OSVersion.Platform"))

    def test_a_non_ascii_character_is_reported(self):
        self.assertTrue(self.has(self.script + "\n# \u00e9\n", "not ASCII"))

    def test_a_reworded_marker_is_reported_against_the_batch_file(self):
        bad = mutate(self.script, "$menuMarker     = 'Multiple Python files detected'", "$menuMarker     = 'Several Python files'")
        self.assertTrue(any("is in 0 live echo line" in f for f in marker_problems(self.batch, bad)), marker_problems(self.batch, bad))
        bad = mutate(self.script, "'or wait ' + $ExpectedWait + 's for the default [1]'", "'wait ' + $ExpectedWait + 's'")
        self.assertTrue(any("builds the prompt text" in f for f in marker_problems(self.batch, bad)), marker_problems(self.batch, bad))

    def test_programs_that_are_not_ambiguous_are_reported(self):
        bad = mutate(self.script, '$appB = "print(\'entry-b\')`n"', '$appB = "if __name__ == \'__main__\': print(\'entry-b\')`n"')
        found = premise_problems(bad)
        self.assertTrue(any("find_entry chose" in f for f in found), found)


FALLBACK_START = "# Every id that was not written above"
FALLBACK_END = "if (-not $allPass) { exit 1 }"


def fallback_block(text):
    t = norm(text)
    a = t.find(FALLBACK_START)
    b = t.find(FALLBACK_END)
    if a < 0 or b < a:
        raise AssertionError("the block that writes the rows of a script that stopped early was not found")
    return t[a:b]


def run_fallback(text, written, crash):
    """Run the real fallback block under pwsh with a recording Write-NdjsonRow; returns (allPass, rows)."""
    keys = "".join("$rowsWritten['%s'] = $true\n" % w for w in written)
    driver = (
        "$ErrorActionPreference = 'Stop'\n"
        "$allIds = @('self.entry.picker.wait.control', 'self.entry.picker.wait')\n"
        "$rowsWritten = @{}\n" + keys +
        "$crashMessage = '%s'\n$allPass = $true\n$script:rows = @()\n"
        "function Write-NdjsonRow { param([hashtable]$Row) $script:rows += ,$Row }\n" % crash
        + fallback_block(text) + "\n"
        "$out = [ordered]@{ allPass = $allPass; rows = @($script:rows | ForEach-Object { [ordered]@{ id = $_['id']; pass = $_['pass']; req = $_['req']; "
        "crash = $_['details']['crash'] } }) }\n"
        "$out | ConvertTo-Json -Depth 5 -Compress\n")
    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp) / "fallback.ps1"
        f.write_text(driver, encoding="ascii")
        proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(f)], capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    import json
    out = json.loads(proc.stdout.strip().splitlines()[-1])
    rows = out["rows"]
    if isinstance(rows, dict):
        rows = [rows]
    return out["allPass"], rows


@unittest.skipUnless(PWSH, "pwsh not available")
class ARowThatWasNotWrittenIsWrittenRed(unittest.TestCase):
    """CodeRabbit, PR #548: an absent row cannot be red, and the expected-row list only protects an id after green runs listed it."""

    def setUp(self):
        self.script = SCRIPT.read_text(encoding="utf-8")

    def test_both_rows_written_adds_nothing(self):
        all_pass, rows = run_fallback(self.script, list(ROW_IDS), "")
        self.assertTrue(all_pass)
        self.assertEqual(rows, [])

    def test_one_row_written_adds_a_red_row_for_the_other(self):
        all_pass, rows = run_fallback(self.script, ["self.entry.picker.wait.control"], "boom (script line 7)")
        self.assertFalse(all_pass)
        self.assertEqual([(r["id"], r["pass"]) for r in rows], [("self.entry.picker.wait", False)])
        self.assertEqual(rows[0]["crash"], "boom (script line 7)")

    def test_no_row_written_adds_a_red_row_for_each(self):
        all_pass, rows = run_fallback(self.script, [], "boom")
        self.assertFalse(all_pass)
        self.assertEqual([(r["id"], r["pass"]) for r in rows], [(i, False) for i in ROW_IDS])
        self.assertTrue(all(r["req"] == "REQ-002.15" for r in rows))

    def test_a_fallback_that_stops_marking_the_run_red_is_shown(self):
        bad = mutate(self.script, "        $allPass = $false\n        Write-NdjsonRow", "        Write-NdjsonRow")
        all_pass, _ = run_fallback(bad, [], "boom")
        self.assertTrue(all_pass, "the mutated block must show the defect: rows written but the run not red")
        self.assertTrue(any("is no longer written as a failing row" in f for f in script_problems(bad)), script_problems(bad))

    def test_a_fallback_that_writes_a_green_row_is_shown(self):
        bad = mutate(self.script, "pass = $false; desc = 'Entry picker wait: the script stopped before this row was written'",
                     "pass = $true; desc = 'Entry picker wait: the script stopped before this row was written'")
        _, rows = run_fallback(bad, [], "boom")
        self.assertTrue(all(r["pass"] for r in rows))
        self.assertTrue(any("is no longer red with its reason" in f for f in script_problems(bad)), script_problems(bad))

    def test_a_fallback_that_rewrites_a_written_row_is_shown(self):
        bad = mutate(self.script, "if (-not $rowsWritten.ContainsKey($rowId)) {", "if ($true) {")
        _, rows = run_fallback(bad, list(ROW_IDS), "")
        self.assertEqual(len(rows), 2)
        self.assertTrue(any("no longer written as a failing row" in f for f in script_problems(bad)), script_problems(bad))

    def test_a_script_that_stops_recording_its_rows_is_reported(self):
        bad = mutate(self.script, "    $rowsWritten['self.entry.picker.wait.control'] = $true\n", "")
        self.assertTrue(any("is no longer recorded as written" in f for f in script_problems(bad)), script_problems(bad))

    def test_a_script_that_no_longer_catches_an_unexpected_stop_is_reported(self):
        bad = mutate(self.script, "} catch {\n    $crashMessage =", "} catch {\n    $crashMessageX =")
        self.assertTrue(any("is no longer caught and counted" in f for f in script_problems(bad)), script_problems(bad))

    def test_rows_written_after_the_exit_are_reported(self):
        a = self.script.find(FALLBACK_START)
        b = self.script.find(FALLBACK_END)
        block = self.script[a:b]
        bad = self.script[:a] + self.script[b:].replace(FALLBACK_END, FALLBACK_END + "\n" + block, 1)
        self.assertTrue(any("before the exit code is decided" in f for f in script_problems(bad)), script_problems(bad))


GUARD_START = "$allPass = $true"


def run_guarded(text, workroot):
    """Run the real guarded block and the fallback under pwsh; its first statements are the setup, which is made to fail."""
    t = norm(text)
    a = t.find(GUARD_START)
    b = t.find(FALLBACK_END)
    if a < 0 or b < a:
        raise AssertionError("the guarded block was not found")
    driver = (
        "$ErrorActionPreference = 'Stop'\n"
        "$allIds = @('self.entry.picker.wait.control', 'self.entry.picker.wait')\n"
        "$here = '/nowhere'\n$timeLimitSec = 900\n$scrubbed = @{}\n$parentStillSet = @()\n"
        "$workRoot = '%s'\n$script:rows = @()\n"
        "function Write-NdjsonRow { param([hashtable]$Row) $script:rows += ,$Row }\n"
        "function Invoke-Calibration { param([string]$Method) throw 'the setup must have stopped the run before any calibration' }\n" % workroot
        + t[a:b] + "\n"
        "$out = [ordered]@{ allPass = $allPass; rows = @($script:rows | ForEach-Object { [ordered]@{ id = $_['id']; pass = $_['pass']; "
        "crash = $_['details']['crash'] } }) }\n"
        "$out | ConvertTo-Json -Depth 5 -Compress\n")
    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp) / "guarded.ps1"
        f.write_text(driver, encoding="ascii")
        proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(f)], capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    import json
    out = json.loads(proc.stdout.strip().splitlines()[-1])
    rows = out["rows"]
    if isinstance(rows, dict):
        rows = [rows]
    return out["allPass"], rows


@unittest.skipUnless(PWSH, "pwsh not available")
class ASetupThatStopsBeforeTheRowsIsWrittenRed(unittest.TestCase):
    """CodeRabbit, PR #548 (second round): the work folder and the flag scrub used to run before the guarded block."""

    def setUp(self):
        self.script = SCRIPT.read_text(encoding="utf-8")
        # an empty path: Test-Path -LiteralPath refuses it with a terminating binding error on every host (New-Item -Force below a
        # plain file did not fail under pwsh on Linux), and it is the first statement of the setup
        self.bad_root = ""

    def test_a_setup_that_stops_gives_two_red_rows_with_the_reason(self):
        all_pass, rows = run_guarded(self.script, self.bad_root)
        self.assertFalse(all_pass)
        self.assertEqual([(r["id"], r["pass"]) for r in rows], [(i, False) for i in ROW_IDS])
        self.assertTrue(all(r["crash"] for r in rows), rows)
        self.assertTrue(all("calibration" not in r["crash"] for r in rows), rows)

    def test_the_old_shape_with_the_setup_before_the_guard_is_shown(self):
        line = "    New-Item -ItemType Directory -Force -Path $workRoot -ErrorAction Stop | Out-Null\n"
        bad = mutate(self.script, line, "")
        bad = mutate(bad, "$crashMessage = ''\ntry {", "New-Item -ItemType Directory -Force -Path $workRoot -ErrorAction Stop | Out-Null\n$crashMessage = ''\ntry {")
        self.assertTrue(any("is not inside the guarded block" in f for f in script_problems(bad)), script_problems(bad))

    def test_a_scrub_before_the_guard_is_shown(self):
        line = "    foreach ($name in @($scrubbed.Keys)) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }\n"
        bad = mutate(self.script, line, "")
        bad = mutate(bad, "$crashMessage = ''\ntry {", "foreach ($name in @($scrubbed.Keys)) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }\n$crashMessage = ''\ntry {")
        self.assertTrue(any("is not inside the guarded block" in f for f in script_problems(bad)), script_problems(bad))

    def test_the_restore_in_finally_cannot_end_the_script_before_the_fallback(self):
        flat = norm(self.script)
        self.assertIn("try { [Environment]::SetEnvironmentVariable($name, $scrubbed[$name]) } catch { }", flat)


class WorkflowAndListsCanFail(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_a_step_that_is_missing_is_reported(self):
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\%s" % SCRIPT_NAME])

    def test_a_step_on_another_lane_or_with_continue_on_error_is_reported(self):
        block = step_block(self.workflow, SCRIPT_NAME)
        self.assertIsNotNone(block)
        bad = self.workflow.replace(STEP_IF, "if: ${{ !cancelled() && matrix.mode == 'real' }}") if self.workflow.count(STEP_IF) == 1 else None
        if bad is None:
            bad = mutate(self.workflow, block, block.replace(STEP_IF, "if: ${{ !cancelled() && matrix.mode == 'real' }}"))
        self.assertTrue(any("not limited to the contract-uv lane" in f for f in workflow_problems(bad)), workflow_problems(bad))
        bad = mutate(self.workflow, block, block.replace("        shell: pwsh\n", "        shell: pwsh\n        continue-on-error: true\n"))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(bad)), workflow_problems(bad))

    def test_a_missing_upload_pattern_is_reported(self):
        bad = mutate(self.workflow, "            " + UPLOADS[0] + "\n", "")
        self.assertTrue(any(UPLOADS[0] in f for f in workflow_problems(bad)), workflow_problems(bad))

    def test_an_unregistered_row_is_reported(self):
        self.assertEqual(len(registry_problems("```\nself.entry.picker.wait\n```\n")), 1)
        self.assertEqual(registry_problems("```\nself.entry.picker.wait, self.entry.picker.wait.control\n```\n"), [])
        self.assertEqual(len(registry_problems("self.entry.picker.wait, self.entry.picker.wait.control\n")), 2)

    def test_a_shall_that_is_still_listed_is_reported(self):
        listed = '    "REQ-002.15": "unit: tests/test_picker_gate.py::PickerWait something",\n'
        self.assertEqual(len(shall_list_problems(listed)), 1)
        self.assertEqual(shall_list_problems('    "REQ-002.150": "x",\n'), [])

    def test_a_readme_that_still_says_no_row_waits_is_reported(self):
        self.assertEqual(len(readme_problems("so no row waits the full time. self.entry.picker.wait")), 1)
        self.assertEqual(len(readme_problems("a note without the row")), 1)
        self.assertEqual(readme_problems("the row self.entry.picker.wait measures the full wait"), [])


if __name__ == "__main__":
    unittest.main()
