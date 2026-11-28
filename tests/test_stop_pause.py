"""Item 130 (README REQ-016.8): the terminal window stays open at the end of a run, whether it succeeded or failed, except with the CI marker.

REQ-016.8 says that at the end of a run, whether it succeeded or failed, the terminal window stays open until the user presses a
key, except in a run that carries the CI marker. :die and :success each have `if not defined HP_CI_LANE ( pause )` before their
`exit /b`, but every CI lane carries HP_CI_LANE, so no row ever reached a pause and tests/test_req_shall_trace.py listed the shall as
read from the code. Reading the code found stops that end with `exit /b 1` and no pause (the system-folder guard, the stop for a
dragged file from another folder of REQ-011, and both `Workspace path invalid` exits, the second of which a double-click on a script
on a network share reaches; the two `errorlevel 11` returns of :determine_entry's callers are unreachable after that pre-flight and
got the same pause for consistency). tests/selfapps_stop_pause.ps1 (seven rows, self.stoppause.success, .die, .usage, .req011, .sysdir, .unc and
.marker; contract-uv lane, gating) runs run_setup.bat for real without HP_CI_LANE and with standard input held open, and judges what
the console log and the process did.

What really happens is shown on Windows by that script. These rules read run_setup.bat, the script, batch-check.yml,
docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, and run the script's own judging function through a real pwsh on
synthetic runs (a run that passes, and one run for each way to be wrong), so a reworded stop message, a scenario that stops being the
one the shall names, a scrub that lets the runner's marker through, a judge that stops judging or a step that stops gating fails here
with a sentence, before a Windows run is needed. Synthetic cases prove each rule can fail.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_stop_pause.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

ROW_IDS = (
    "self.stoppause.success", "self.stoppause.die", "self.stoppause.usage", "self.stoppause.req011",
    "self.stoppause.sysdir", "self.stoppause.unc", "self.stoppause.marker",
)
ROW_REQ = "REQ-016.8"
GAP_SHALL = "REQ-016.8"

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = ("tests/~stop_pause_evidence.txt",)
JUDGES = ["Get-StopPauseProblems"]

# The scenario table of the script, line by line: what each folder holds, what follows run_setup.bat, which variable is set after the
# scrub, the stop's own message and the exit code of the stop. A changed line is a changed scenario, which needs this list changed too.
SCENARIO_LINES = (
    "@{ Name = 'success'; Kind = 'empty'; Arguments = ''; Extra = @{}; Pattern = 'No Python files detected'; WantExit = 0 }",
    "@{ Name = 'die'; Kind = 'program'; Arguments = ''; Extra = @{ PVW_PROVIDER = 'zzz' }; Pattern = 'PVW_PROVIDER has a value this bootstrapper does not accept'; WantExit = 1 }",
    "@{ Name = 'usage'; Kind = 'program'; Arguments = 'nosuchfile'; Extra = @{}; Pattern = 'The first argument must be one of your Python files'; WantExit = 1 }",
    "@{ Name = 'req011'; Kind = 'program'; Arguments = ('\"' + (Join-Path $extDir 'external.py') + '\"'); Extra = @{}; Pattern = 'REQ-011: Dragged files must reside in the bootstrapper root folder'; WantExit = 1 }",
    "@{ Name = 'sysdir'; Kind = 'sysdir'; Arguments = ''; Extra = @{}; Pattern = 'located inside a Windows system folder'; WantExit = 1 }",
    "@{ Name = 'unc'; Kind = 'unc'; Arguments = ''; Extra = @{}; Pattern = 'Workspace path invalid'; WantExit = 1 }",
)

# Stops of run_setup.bat that already pause and are the controls of the rows: (what it is, the unique live line that starts the
# search, the exit line the pause must stand directly in front of). The search goes forward from the anchor to the first `exit /b`.
CONTROL_SITES = (
    ("the end of a run through :success (row success)", ":success", "exit /b 0"),
    ("the end of a run through :die (row die)", ":die", "exit /b %RC%"),
    ("the usage stop for a first argument that names no file (row usage)", ":entry_arg_usage", "exit /b 1"),
)

# The stops that had no pause until Item 130: (what it is, the live line that starts the search, the exit line the pause must stand
# directly in front of, how many such anchors the file holds). Each occurrence is checked.
FIXED_SITES = (
    ("the Workspace path invalid stops (a missing folder, then a folder that cmd cannot enter, row unc)",
     "echo [ERROR] Workspace path invalid: %~dp0", "exit /b 1", 2),
    ("the system-folder guard (row sysdir)",
     'call :log "[ERROR] System-directory guard: script root is under a Windows system folder; aborting."', "exit /b 1"),
    ("the REQ-011 pre-flight stop for a dragged file from another folder (row req011)",
     'if not "%~1"=="" if /i not "%~dp1"=="%~dp0" (', "exit /b 1"),
    ("the two returns of an entry check that reports REQ-011 (errorlevel 11, unreachable after the pre-flight)",
     "if errorlevel 11 (", "exit /b 1", 2),
)


def norm(text):
    return text.replace("\r\n", "\n")


def lines_of(text):
    return norm(text).split("\n")


def is_bat_comment(line):
    return re.match(r"(?i)\s*(rem\b|::)", line) is not None


def live_bat(lines):
    return [ln for ln in lines if ln.strip() and not is_bat_comment(ln)]


def live_hash(text):
    """The lines of a PowerShell or Python file that are not blank and not a comment line, stripped."""
    return [ln.strip() for ln in norm(text).split("\n") if ln.strip() and not ln.strip().startswith("#")]


def scenario_patterns(text):
    """The stop messages the script looks for, in the order of its scenario table."""
    return re.findall(r"Pattern = '([^']*)'", norm(text))


# --- the batch file: what the script assumes about the stops ------------------------------------------------------------------

PAUSE_TAIL = re.compile(r"(?i)if\s+not\s+defined\s+HP_CI_LANE\s*(?:\(\s*)?pause\s*(?:\))?\s*$")


def pause_site_problems(batch, sites):
    """For each (what, anchor, exit line): the first live `exit /b` line after the unique anchor line is the stop's exit, and the last
    three live lines in front of it end with a pause that the CI marker switches off."""
    found = []
    live = [ln.strip() for ln in live_bat(lines_of(batch))]
    for site in sites:
        what, anchor, exit_line = site[:3]
        wanted = site[3] if len(site) > 3 else 1
        starts = [i for i, ln in enumerate(live) if ln == anchor]
        if len(starts) != wanted:
            found.append("%s: expected exactly %d live line(s) %r, found %d" % (what, wanted, anchor, len(starts)))
            continue
        for start in starts:
            at = next((j for j in range(start + 1, len(live)) if live[j].lower().startswith("exit /b")), None)
            if at is None:
                found.append("%s: no exit line follows %r" % (what, anchor))
                continue
            if live[at] != exit_line:
                found.append("%s: the first exit after %r is %r, expected %r" % (what, anchor, live[at], exit_line))
                continue
            window = " ".join(live[max(0, at - 3):at])
            if not PAUSE_TAIL.search(window):
                found.append("%s: the window can close before the message is read, because no `if not defined HP_CI_LANE pause` stands "
                             "directly in front of %r" % (what, exit_line))
    return found


def premise_problems(batch, script_text):
    """Every stop message the script waits for is a live line of the batch file, so a reworded message fails here with a sentence and
    not as a row that says the run never reached its stop. The controls that already pause keep their pause."""
    found = []
    live = [ln.strip() for ln in live_bat(lines_of(batch))]
    patterns = scenario_patterns(script_text)
    if len(patterns) != len(SCENARIO_LINES):
        found.append("the script's scenario table holds %d patterns, expected %d" % (len(patterns), len(SCENARIO_LINES)))
    for pattern in patterns:
        if not any(re.search(pattern, ln) for ln in live):
            found.append("no live line of run_setup.bat matches the stop message %r the script waits for" % pattern)
    found.extend(pause_site_problems(batch, CONTROL_SITES))
    if len([ln for ln in live if ln == "pause"]) < 2:
        found.append("run_setup.bat no longer holds the plain pause lines of :success and :die")
    return found


# --- the script ---------------------------------------------------------------------------------------------------------------

def script_problems(text):
    t = norm(text)
    live = live_hash(t)
    flat = "\n".join(live)
    found = []
    pairs = re.findall(r"\bid = '(self\.stoppause\.[a-z0-9]+)'; req = '([^']*)'", t)
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if sorted(ids) != sorted(list(ROW_IDS) * 2):
        found.append("each row id must be a literal at exactly two Write-NdjsonRow call sites (the shared one and its own), found %r" % ids)
    if sorted(p[0] for p in pairs) != sorted(list(ROW_IDS) * 2):
        found.append("every row id must be followed by its literal req tag, found %r" % pairs)
    if any(p[1] != ROW_REQ for p in pairs):
        found.append("every row must carry the literal req tag %r, found %r" % (ROW_REQ, [p[1] for p in pairs]))
    for line in SCENARIO_LINES:
        if line not in live:
            found.append("the scenario table no longer holds: %s" % line)
    for need in (
        "$psi.RedirectStandardInput = $true",
        "if (($n -like 'HP_*') -or ($n -like 'PVW_*') -or ($n -eq 'NOINPUT')) { $psi.EnvironmentVariables.Remove($n) }",
        "if ($Marker) { $psi.EnvironmentVariables['HP_CI_LANE'] = 'test' }",
        "if ($Marker) { $p.StandardInput.Close() }",
        "$deadline = $started.AddMilliseconds(240000)",
        "Start-Sleep -Seconds 5",
        "$res.AliveAfterPause = (-not $p.HasExited)",
        "try { $p.StandardInput.WriteLine(''); $p.StandardInput.Flush(); $p.StandardInput.Close() } catch { $res.Error = [string]$_.Exception.Message }",
        "if ($p.WaitForExit(60000)) { $res.Finished = $true }",
        "& taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null",
        "if ((Read-SharedText -Path $consolePath) -match 'Press any key to continue') { $res.PauseSeen = $true; break }",
    ):
        if need not in live:
            found.append("the script no longer holds the line: %s" % need)
    scrub = flat.find("$psi.EnvironmentVariables.Remove($n)")
    marker = flat.find("$psi.EnvironmentVariables['HP_CI_LANE'] = 'test'")
    extra = flat.find("foreach ($k in $Scenario.Extra.Keys)")
    if min(scrub, marker, extra) < 0 or not (scrub < marker < extra):
        found.append("the variables of the runner must be removed first, then the marker set, then the scenario's own variables, in that order")
    for launch in (
        "'set \"STOP_LANE=undefined\"',",
        "'if defined HP_CI_LANE set \"STOP_LANE=defined\"',",
        "'>\"~stop_lane.txt\" echo %STOP_LANE%',",
        "('call ' + $batchCall + $argText + ' > ~stop_console.txt 2>&1'),",
        "'exit /b %ERRORLEVEL%'",
    ):
        if launch not in live:
            found.append("the launch file no longer holds the line: %s" % launch)
    for need in (
        "$uncDir = '\\\\localhost\\' + $Matches[1] + '$\\' + $Matches[2]",
        "$reached = ([string]$seen).Trim() -ceq $token",
        "$res.SkipReason = 'unc-share-unavailable'",
        "$batchCall = '\"' + (Join-Path $uncDir 'run_setup.bat') + '\"'",
    ):
        if need not in flat:
            found.append("the unc route no longer holds: %s" % need)
    if "$winTemp = Join-Path $env:WINDIR 'Temp'" not in flat:
        found.append("the system-folder scenario no longer runs from a folder under %WINDIR%\\Temp")
    call = "$problems = @(Get-StopPauseProblems"
    if call not in flat:
        found.append("the verdict no longer comes from Get-StopPauseProblems")
    else:
        for need in ("-ExpectPause (-not $Marker)", "-StopPattern $Scenario.Pattern", "-ConsoleText $run.Console", "-LaneText $run.Lane",
                     "-WantLane $wantLane", "-Finished ([bool]$run.Finished)", "-PauseSeen ([bool]$run.PauseSeen)",
                     "-AliveAfterPause ([bool]$run.AliveAfterPause)", "-ExitCode $run.ExitCode", "-WantExit ([int]$Scenario.WantExit)"):
            if need not in flat:
                found.append("the verdict no longer hands %s to Get-StopPauseProblems" % need)
    if "$wantLane = if ($Marker) { 'defined' } else { 'undefined' }" not in flat:
        found.append("the run's own record of HP_CI_LANE is no longer compared with defined (marker runs) and undefined (the others)")
    for n, var in enumerate(("success", "die", "usage", "req011", "sysdir", "unc")):
        if "$%s = Get-StopResult -Scenario $scenarios[%d] -Marker $false" % (var, n) not in re.sub(r"\s+=", " =", flat.replace("  ", " ")):
            found.append("the run of %s without the marker is no longer started from scenario %d of the table" % (var, n))
        if "$pass = [bool](@($%s.Problems).Count -eq 0)" % var not in flat:
            found.append("the row of %s is no longer judged by its list of problems" % var)
    if "foreach ($s in $scenarios) { $markerRuns += , (Get-StopResult -Scenario $s -Marker $true) }" not in flat:
        found.append("the marker row no longer runs every scenario with HP_CI_LANE set")
    if "$pass = [bool]($markerProblems.Count -eq 0)" not in flat:
        found.append("the marker row is no longer judged by its list of problems")
    for need in ("$markerSkipped = @($markerRuns | Where-Object { $_.Skipped })", "$markerDetails['skip'] = $true",
                 "$markerDetails['reason'] = [string]$markerSkipped[0].Details.reason"):
        if need not in flat:
            found.append("the marker row no longer records a skipped run on the row itself (skip and reason): %s" % need)
    if flat.count("pass = $pass") < 7:
        found.append("the seven rows no longer write pass = $pass")
    for name in JUDGES:
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the judging function %s is missing" % name)
    if "OSVersion.Platform -ne [System.PlatformID]::Win32NT" not in flat or re.search(r"\$IsWindows\b", flat):
        found.append("the Windows check must use OSVersion.Platform and not $IsWindows")
    if "skip = $true" not in flat:
        found.append("the rows no longer skip off Windows with skip = $true")
    if "if (-not $allPass) { exit 1 }" not in flat:
        found.append("the script no longer exits 1 for a red row")
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0")
    if any(ord(ch) > 127 for ch in text):
        found.append("the script holds a character that is not ASCII")
    return found


# --- the workflow, the registry and the shall list ----------------------------------------------------------------------------

def step_block(text):
    lines = norm(text).split("\n")
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if "selfapps_stop_pause.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_stop_pause.ps1"]
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


def registry_ids(text):
    """The ids on their own line inside a fenced block, which is what tools/check_ndjson_registry.py reads (prose does not count)."""
    ids, inside = set(), False
    for ln in norm(text).split("\n"):
        if ln.startswith("```"):
            inside = not inside
        elif inside and ln.strip():
            ids.update(part.strip(",") for part in ln.split() if part.strip(","))
    return ids


def registry_problems(text):
    have = registry_ids(text)
    return ["%s is not in docs/agent-ndjson.md" % row for row in ROW_IDS if row not in have]


def shall_list_problems(text):
    """The shall the rows trace is no longer listed as a gap (the shall-level ratchet only warns about a stale entry)."""
    if re.search(r'^\s*"%s":' % re.escape(GAP_SHALL), text, re.M):
        return ["%s is still listed in UNTRACED_SHALLS although a row is tagged with it" % GAP_SHALL]
    return []


# --- the script's judging function, run through a real pwsh -------------------------------------------------------------------

DRIVER = r"""
$ErrorActionPreference = 'Stop'
# A judging function may use only its parameters and its own locals. Strict mode makes a read of a variable nobody set an error
# (and not $null), and the driver's own variables start with two underscores, so no judge can read one of them by accident.
Set-StrictMode -Version 1.0
$__tokens = $null; $__errs = $null
$__ast = [System.Management.Automation.Language.Parser]::ParseFile($env:CC_SCRIPT, [ref]$__tokens, [ref]$__errs)
if ($__errs.Count -gt 0) { throw ('parse errors: ' + $__errs[0].Message) }
$__want = @($env:CC_WANT -split ',')
$__defs = $__ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $__want -contains $n.Name }, $true)
if (@($__defs).Count -ne $__want.Count) { throw 'a judging function is missing from the script' }
foreach ($__f in $__defs) { Invoke-Expression $__f.Extent.Text }
$__cases = Get-Content -LiteralPath $env:CC_CASES -Raw | ConvertFrom-Json
$__all = New-Object System.Collections.ArrayList
foreach ($__c in $__cases) {
    $__h = @{}
    foreach ($__p in $__c.args.PSObject.Properties) { $__h[$__p.Name] = $__p.Value }
    $__r = @(& $__c.fn @__h)
    [void]$__all.Add([ordered]@{ name = $__c.name; result = $__r })
}
ConvertTo-Json -InputObject @($__all) -Compress -Depth 8
"""


def run_cases(script, want, cases, tmp):
    """Run the named functions of a script on the cases; returns {case name: list of what the function returned}."""
    tmp = Path(tmp)
    cases_file = tmp / "cases.json"
    cases_file.write_text(json.dumps(cases), encoding="ascii")
    driver = tmp / "driver.ps1"
    driver.write_text(DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["CC_SCRIPT"] = str(script)
    env["CC_WANT"] = ",".join(want)
    env["CC_CASES"] = str(cases_file)
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(driver)], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return {item["name"]: item["result"] for item in json.loads(proc.stdout)}


def case(name, fn, **args):
    return {"name": name, "fn": fn, "args": args}


PATTERN = "REQ-011: Dragged files must reside in the bootstrapper root folder"
STOP_TEXT = "[ERROR] REQ-011: Dragged files must reside in the bootstrapper root folder for environment cleanliness.\r\n"
PROMPT_TEXT = "Press any key to continue . . .\r\n"


def pause_args(**over):
    args = dict(Name="req011", ExpectPause=True, StopPattern=PATTERN, ConsoleText=STOP_TEXT + PROMPT_TEXT, LaneText="undefined\r\n",
                WantLane="undefined", Finished=True, PauseSeen=True, AliveAfterPause=True, ExitCode=1, WantExit=1)
    args.update(over)
    return args


def marker_args(**over):
    args = dict(Name="req011 (marker)", ExpectPause=False, StopPattern=PATTERN, ConsoleText=STOP_TEXT, LaneText="defined\r\n",
                WantLane="defined", Finished=True, PauseSeen=False, AliveAfterPause=False, ExitCode=1, WantExit=1)
    args.update(over)
    return args


def judge_cases():
    j = "Get-StopPauseProblems"
    c = []
    # --- a run without the marker: it must print the stop, then the prompt, wait, and end after a key
    c.append(case("pause_good", j, **pause_args()))
    c.append(case("pause_good_exit_zero", j, **pause_args(Name="success", StopPattern="No Python files detected",
                                                           ConsoleText="No Python files detected; skipping environment bootstrap.\r\n" + PROMPT_TEXT,
                                                           ExitCode=0, WantExit=0)))
    c.append(case("pause_lane_defined", j, **pause_args(LaneText="defined\r\n")))
    c.append(case("pause_no_stop_message", j, **pause_args(ConsoleText=PROMPT_TEXT)))
    c.append(case("pause_never_printed_but_ended", j, **pause_args(ConsoleText=STOP_TEXT, PauseSeen=False, AliveAfterPause=False)))
    c.append(case("pause_never_ended", j, **pause_args(ConsoleText=STOP_TEXT, PauseSeen=False, AliveAfterPause=False, Finished=False, ExitCode=-1)))
    c.append(case("pause_before_stop", j, **pause_args(ConsoleText=PROMPT_TEXT + STOP_TEXT)))
    c.append(case("pause_not_waiting", j, **pause_args(AliveAfterPause=False)))
    c.append(case("pause_no_end_after_key", j, **pause_args(Finished=False, ExitCode=-1)))
    c.append(case("pause_wrong_exit", j, **pause_args(ExitCode=0)))
    # --- a run with the marker: no prompt, and it ends by itself
    c.append(case("marker_good", j, **marker_args()))
    c.append(case("marker_lane_undefined", j, **marker_args(LaneText="undefined\r\n")))
    c.append(case("marker_prompt_printed", j, **marker_args(ConsoleText=STOP_TEXT + PROMPT_TEXT)))
    c.append(case("marker_not_finished", j, **marker_args(Finished=False, ExitCode=-1)))
    c.append(case("marker_wrong_exit", j, **marker_args(ExitCode=0)))
    c.append(case("marker_no_stop_message", j, **marker_args(ConsoleText="")))
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

    def test_a_run_that_printed_the_stop_then_the_prompt_waited_and_ended_with_its_exit_code_has_no_problem(self):
        self.assertEqual(self.r["pause_good"], [])
        self.assertEqual(self.r["pause_good_exit_zero"], [])

    def test_a_run_with_the_marker_that_printed_no_prompt_and_ended_by_itself_has_no_problem(self):
        self.assertEqual(self.r["marker_good"], [])

    def test_a_run_that_did_not_see_the_lane_it_was_meant_for_says_the_run_is_not_the_one_the_row_means(self):
        self.only("pause_lane_defined", "saw HP_CI_LANE as 'defined', expected 'undefined'")
        self.only("marker_lane_undefined", "saw HP_CI_LANE as 'undefined', expected 'defined'")

    def test_a_console_without_the_stops_own_message_says_the_run_never_reached_the_stop(self):
        self.only("pause_no_stop_message", "the console does not hold the stop's own message")
        found = self.r["marker_no_stop_message"]
        self.assertEqual(len(found), 1, found)
        self.assertIn("never reached the stop", found[0])

    def test_a_run_that_ended_with_no_prompt_is_the_window_that_closes_before_the_message_can_be_read(self):
        self.only("pause_never_printed_but_ended", "the run ended with no 'Press any key to continue', so the window would close")

    def test_a_run_that_neither_ended_nor_paused_is_one_problem_and_no_exit_code_complaint(self):
        self.only("pause_never_ended", "the run neither ended nor paused within the limit")

    def test_a_prompt_that_comes_before_the_stops_message_is_named(self):
        self.only("pause_before_stop", "the pause comes before the stop's message")

    def test_a_run_that_was_gone_five_seconds_after_the_prompt_did_not_wait_for_a_key(self):
        self.only("pause_not_waiting", "no longer running five seconds after the prompt, so it did not wait for a key")

    def test_a_run_that_did_not_end_after_a_key_was_sent_is_named(self):
        self.only("pause_no_end_after_key", "the run did not end after a key was sent")

    def test_a_wrong_exit_code_is_named_for_both_kinds_of_run(self):
        self.only("pause_wrong_exit", "the exit code is '0', expected 1")
        self.only("marker_wrong_exit", "the exit code is '0', expected 1")

    def test_a_prompt_in_a_run_that_carries_the_marker_is_the_pause_the_shall_switches_off(self):
        self.only("marker_prompt_printed", "holds 'Press any key to continue' although the run carries the CI marker")

    def test_a_marker_run_that_did_not_end_by_itself_is_named(self):
        self.only("marker_not_finished", "the run did not end by itself within the limit")


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgeDriverIsStrict(unittest.TestCase):
    """The driver runs each judging function alone and in strict mode, so a judge that reads a variable it does not own fails
    loudly instead of reading $null (or a variable of the driver) and quietly passing."""

    def run_probe(self, body, args):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "judge.ps1"
            script.write_text("function Get-Probe {\n    param($Value)\n%s\n}\n" % body, encoding="ascii")
            return run_cases(script, ["Get-Probe"], [{"name": "probe", "fn": "Get-Probe", "args": args}], d)["probe"]

    def test_a_judge_that_uses_only_its_own_values_runs(self):
        self.assertEqual(self.run_probe("    $own = $Value + 1\n    return $own", {"Value": 41}), [42])

    def test_a_judge_that_reads_a_variable_nobody_set_fails(self):
        with self.assertRaises(AssertionError) as ctx:
            self.run_probe("    return $neverSetByAnyone", {"Value": 1})
        self.assertIn("pwsh failed", str(ctx.exception))

    def test_a_judge_cannot_read_a_variable_of_the_driver(self):
        for name in ("cases", "c", "h", "want", "all", "ast", "defs", "tokens", "errs", "r", "p", "f"):
            with self.subTest(name=name):
                with self.assertRaises(AssertionError):
                    self.run_probe("    return $%s" % name, {"Value": 1})

    def test_the_judge_does_not_read_the_scripts_own_variables(self):
        # the script's judge names $work, $here, $nd and $batchPath nowhere: run it with a call that would fail if it read one
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        body = text[text.index("function Get-StopPauseProblems {"):text.index("# the scenarios")]
        for name in ("$work", "$here", "$nd", "$batchPath", "$scenarios", "$evidencePath", "$winTemp", "$extDir", "$repo"):
            self.assertNotRegex(body, re.escape(name) + r"\b", "the judge reads %s of the script" % name)


# --- the rules on the real files ----------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_every_stop_message_the_script_waits_for_is_a_live_line_and_the_controls_still_pause(self):
        self.assertEqual(premise_problems(self.batch, self.script), [])

    def test_the_script_has_its_rows_scenarios_scrub_keys_launch_judge_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_every_stop_that_ends_a_run_early_pauses_unless_the_marker_is_set(self):
        self.assertEqual(pause_site_problems(self.batch, FIXED_SITES), [])

    def test_the_shall_is_no_longer_listed_as_a_gap(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        self.assertEqual(len(judge_cases()), 16)
        self.assertEqual(len(scenario_patterns(self.script)), 6)
        self.assertEqual(sum(site[3] if len(site) > 3 else 1 for site in FIXED_SITES), 6)
        self.assertEqual(len(registry_ids(REGISTRY.read_text(encoding="utf-8")) & set(ROW_IDS)), 7)
        self.assertGreater(len(live_bat(lines_of(self.batch))), 1000)

    def test_every_judge_the_driver_is_asked_for_is_a_function_of_the_script(self):
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))

    def test_the_script_uses_literal_ids_and_the_stop_messages_it_waits_for_are_ascii(self):
        self.assertTrue(all(ord(ch) < 128 for ch in self.script))
        for pattern in scenario_patterns(self.script):
            self.assertTrue(pattern.isascii())


def mutate(text, old, new):
    # exactly once: with two matches the case would edit the first one, which may be another block of the file, and the pin under
    # test would never see the change
    assert text.count(old) == 1, "the synthetic case needs the text to hold %r exactly once, found %d" % (old[:60], text.count(old))
    return text.replace(old, new, 1)


class BatchRulesCanFail(unittest.TestCase):
    """Each rule about run_setup.bat is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")

    def problems(self, batch):
        return premise_problems(batch, self.script)

    def test_a_reworded_stop_message_is_reported_with_the_message(self):
        # the REQ-011 text is in two places (the pre-flight stop and :determine_entry), so every copy is reworded
        bad = self.batch.replace("Dragged files must reside in the bootstrapper root folder", "A dragged file must be in the bootstrapper folder")
        self.assertNotEqual(bad, self.batch)
        self.assertTrue(any("stop message" in f and "REQ-011" in f for f in self.problems(bad)), self.problems(bad))
        bad = self.batch.replace("The first argument must be one of your Python files", "Give the name of one of your Python files")
        self.assertTrue(any("stop message" in f and "first argument" in f for f in self.problems(bad)), self.problems(bad))
        bad = self.batch.replace("PVW_PROVIDER has a value this bootstrapper does not accept", "PVW_PROVIDER is not accepted")
        self.assertTrue(any("stop message" in f and "PVW_PROVIDER" in f for f in self.problems(bad)), self.problems(bad))
        bad = self.batch.replace("located inside a Windows system folder", "under a system folder")
        self.assertTrue(any("stop message" in f and "system folder" in f for f in self.problems(bad)), self.problems(bad))
        bad = self.batch.replace("Workspace path invalid", "Workspace folder invalid")
        self.assertTrue(any("stop message" in f and "Workspace" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_control_that_loses_its_pause_is_reported(self):
        usage = norm(self.batch)
        bad = mutate(usage, "call :release_lock\nif not defined HP_CI_LANE pause\nexit /b 1\n:entry_arg_checked", "call :release_lock\nexit /b 1\n:entry_arg_checked")
        self.assertTrue(any("usage stop" in f and "can close before the message is read" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(usage, "rem REQ-016: retain terminal window on error so user can read the message.\nif not defined HP_CI_LANE (\n  pause\n)\nexit /b %RC%",
                     "rem REQ-016: retain terminal window on error so user can read the message.\nexit /b %RC%")
        self.assertTrue(any(":die" in f and "can close before the message is read" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(usage, "rem REQ-016: retain terminal window on success so user can read the output.\nif not defined HP_CI_LANE (\n  pause\n)\nexit /b 0",
                     "rem REQ-016: retain terminal window on success so user can read the output.\nexit /b 0")
        self.assertTrue(any(":success" in f and "can close before the message is read" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_pause_that_no_longer_depends_on_the_marker_is_reported(self):
        bad = mutate(norm(self.batch), "call :release_lock\nif not defined HP_CI_LANE pause\nexit /b 1\n:entry_arg_checked", "call :release_lock\npause\nexit /b 1\n:entry_arg_checked")
        self.assertTrue(any("usage stop" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_site_that_is_missing_or_that_has_a_different_exit_is_reported(self):
        gone = norm(self.batch).replace("\n:entry_arg_usage\n", "\n:entry_arg_usagex\n")
        self.assertTrue(any("expected exactly 1 live line" in f for f in self.problems(gone)), self.problems(gone))
        other = mutate(norm(self.batch), "if not defined HP_CI_LANE pause\nexit /b 1\n:entry_arg_checked", "if not defined HP_CI_LANE pause\nexit /b 2\n:entry_arg_checked")
        self.assertTrue(any("the first exit after" in f for f in self.problems(other)), self.problems(other))

    def test_a_stop_site_helper_accepts_the_one_line_and_the_block_form_and_refuses_a_pause_that_stands_further_away(self):
        sites = (("x", ":s", "exit /b 1"),)
        self.assertEqual(pause_site_problems("a\n:s\nif not defined HP_CI_LANE pause\nexit /b 1\n", sites), [])
        self.assertEqual(pause_site_problems("a\n:s\nif not defined HP_CI_LANE ( pause )\nexit /b 1\n", sites), [])
        self.assertEqual(pause_site_problems("a\n:s\nif not defined HP_CI_LANE (\n  pause\n)\nexit /b 1\n", sites), [])
        self.assertTrue(pause_site_problems("a\n:s\nif not defined HP_CI_LANE pause\necho a\necho b\necho c\nexit /b 1\n", sites))
        self.assertTrue(pause_site_problems("a\n:s\npause\nexit /b 1\n", sites))
        self.assertTrue(pause_site_problems("a\n:s\nexit /b 1\n", sites))
        self.assertTrue(pause_site_problems("a\n:s\nrem if not defined HP_CI_LANE pause\nexit /b 1\n", sites))

    def test_a_pause_that_follows_the_exit_is_not_a_pause(self):
        self.assertTrue(pause_site_problems("a\n:s\nexit /b 1\nif not defined HP_CI_LANE pause\n", (("x", ":s", "exit /b 1"),)))

    def fixed_problems(self, batch):
        return pause_site_problems(batch, FIXED_SITES)

    def lose(self, old, new):
        """The real file with one stop's pause taken out; the anchor holds the neighbouring lines so it occurs exactly once."""
        return mutate(norm(self.batch), old, new)

    def test_each_stop_that_lost_its_pause_is_reported_by_name(self):
        PAUSE = "  if not defined HP_CI_LANE pause\n"
        cases = (
            ("Workspace path invalid stops", 'if not exist "%~dp0" (\n  echo [ERROR] Workspace path invalid: %~dp0\n' + PAUSE,
             'if not exist "%~dp0" (\n  echo [ERROR] Workspace path invalid: %~dp0\n'),
            ("Workspace path invalid stops", 'if errorlevel 1 (\n  echo [ERROR] Workspace path invalid: %~dp0\n' + PAUSE,
             'if errorlevel 1 (\n  echo [ERROR] Workspace path invalid: %~dp0\n'),
            ("system-folder guard", 'aborting."\n' + PAUSE + "  exit /b 1\n", 'aborting."\n  exit /b 1\n'),
            ("REQ-011 pre-flight", "  call :release_lock\n" + PAUSE + "  exit /b 1\n)\nrem derived requirement: CLAUDE.md Item 67",
             "  call :release_lock\n  exit /b 1\n)\nrem derived requirement: CLAUDE.md Item 67"),
            ("errorlevel 11", '  call :write_status "error" 1 %PYCOUNT%\n' + PAUSE + "  exit /b 1\n)\nif errorlevel 1 (\n",
             '  call :write_status "error" 1 %PYCOUNT%\n  exit /b 1\n)\nif errorlevel 1 (\n'),
            ("errorlevel 11", '  call :write_status "error" 1 %PYCOUNT%\n' + PAUSE + "  exit /b 1\n)\nif errorlevel 1 call :die",
             '  call :write_status "error" 1 %PYCOUNT%\n  exit /b 1\n)\nif errorlevel 1 call :die'),
        )
        for name, old, new in cases:
            with self.subTest(name=name, old=old[:50]):
                bad = self.fixed_problems(self.lose(old, new))
                self.assertEqual(len(bad), 1, bad)
                self.assertIn(name, bad[0])
                self.assertIn("can close before the message is read", bad[0])

    def test_a_stop_that_pauses_without_asking_for_the_marker_is_reported(self):
        bad = self.fixed_problems(self.lose('aborting."\n  if not defined HP_CI_LANE pause\n', 'aborting."\n  pause\n'))
        self.assertTrue(any("system-folder guard" in f for f in bad), bad)

    def test_a_stop_that_moved_or_that_has_a_new_twin_is_reported(self):
        gone = norm(self.batch).replace("Workspace path invalid:", "Workspace folder invalid:")
        self.assertTrue(any("expected exactly 2 live line(s)" in f for f in self.fixed_problems(gone)), self.fixed_problems(gone))
        twin = norm(self.batch) + "\nif errorlevel 11 (\n  exit /b 1\n)\n"
        self.assertTrue(any("expected exactly 2 live line(s)" in f for f in self.fixed_problems(twin)), self.fixed_problems(twin))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the workflow, the registry and the shall list is shown to fail on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def problems(self, text):
        return script_problems(text)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "id = 'self.stoppause.sysdir'; req = 'REQ-016.8'; pass = $pass\n    desc = 'The system-folder guard",
                     "id = $rowId; req = 'REQ-016.8'; pass = $pass\n    desc = 'The system-folder guard")
        self.assertTrue(any("literal" in f for f in self.problems(bad)))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "id = 'self.stoppause.unc'; req = 'REQ-016.8'; pass = $pass", "id = 'self.stoppause.unc'; req = 'REQ-016'; pass = $pass")
        self.assertTrue(any("req tag" in f for f in self.problems(bad)))

    def test_a_scenario_that_changes_its_arguments_pattern_or_exit_code_is_caught(self):
        for old, new in (("Arguments = 'nosuchfile'", "Arguments = ''"), ("Extra = @{ PVW_PROVIDER = 'zzz' }", "Extra = @{}"),
                         ("Pattern = 'located inside a Windows system folder'; WantExit = 1", "Pattern = 'located inside a Windows system folder'; WantExit = 0"),
                         ("Kind = 'unc'", "Kind = 'program'"), ("Kind = 'empty'", "Kind = 'program'")):
            with self.subTest(old=old):
                self.assertTrue(any("scenario table" in f for f in self.problems(mutate(self.script, old, new))))

    def test_a_scrub_that_lets_the_runners_marker_through_is_caught(self):
        bad = mutate(self.script, "if (($n -like 'HP_*') -or ($n -like 'PVW_*') -or ($n -eq 'NOINPUT')) { $psi.EnvironmentVariables.Remove($n) }",
                     "if (($n -like 'PVW_*') -or ($n -eq 'NOINPUT')) { $psi.EnvironmentVariables.Remove($n) }")
        self.assertTrue(any("no longer holds the line" in f for f in self.problems(bad)))

    def test_a_marker_set_before_the_scrub_is_caught(self):
        early = mutate(self.script, "        $names = @($psi.EnvironmentVariables.Keys | ForEach-Object { [string]$_ })\n",
                       "        if ($Marker) { $psi.EnvironmentVariables['HP_CI_LANE'] = 'test' }\n        $names = @($psi.EnvironmentVariables.Keys | ForEach-Object { [string]$_ })\n")
        self.assertTrue(any("removed first, then the marker set" in f for f in self.problems(early)) or any("exactly" in f for f in self.problems(early)), self.problems(early))

    def test_standard_input_that_is_not_held_open_or_no_key_and_no_wait_are_caught(self):
        for old, new in (("$psi.RedirectStandardInput = $true", "$psi.RedirectStandardInput = $false"),
                         ("if ($Marker) { $p.StandardInput.Close() }", "$p.StandardInput.Close()"),
                         ("            Start-Sleep -Seconds 5\n", "            Start-Sleep -Seconds 0\n"),
                         ("$p.StandardInput.WriteLine('');", "$p.StandardInput.Write('');"),
                         ("$res.AliveAfterPause = (-not $p.HasExited)", "$res.AliveAfterPause = $true")):
            with self.subTest(old=old):
                self.assertTrue(any("no longer holds the line" in f for f in self.problems(mutate(self.script, old, new))))

    def test_a_missing_kill_or_a_changed_limit_is_caught(self):
        bad = mutate(self.script, "& taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null", "")
        self.assertTrue(any("taskkill" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$deadline = $started.AddMilliseconds(240000)", "$deadline = $started.AddMilliseconds(24000000)")
        self.assertTrue(any("240000" in f for f in self.problems(bad)))

    def test_a_launch_file_that_stops_recording_the_marker_or_the_console_is_caught(self):
        bad = mutate(self.script, "'if defined HP_CI_LANE set \"STOP_LANE=defined\"',", "'rem no record',")
        self.assertTrue(any("launch file" in f for f in self.problems(bad)))
        bad = mutate(self.script, "' > ~stop_console.txt 2>&1'", "' > nul 2>&1'")
        self.assertTrue(any("launch file" in f for f in self.problems(bad)))

    def test_a_unc_route_without_its_probe_or_its_skip_is_caught(self):
        bad = mutate(self.script, "$reached = ([string]$seen).Trim() -ceq $token", "$reached = $true")
        self.assertTrue(any("unc route" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$res.SkipReason = 'unc-share-unavailable'", "$res.SkipReason = ''")
        self.assertTrue(any("unc route" in f for f in self.problems(bad)))

    def test_a_marker_row_that_stops_recording_a_skipped_run_is_caught(self):
        bad = mutate(self.script, "$markerDetails['skip'] = $true", "$markerDetails['skipped'] = $true")
        self.assertTrue(any("skipped run on the row itself" in f for f in self.problems(bad)))

    def test_a_verdict_that_stops_handing_the_judge_what_it_needs_is_caught(self):
        bad = mutate(self.script, "-AliveAfterPause ([bool]$run.AliveAfterPause)", "-AliveAfterPause $true")
        self.assertTrue(any("-AliveAfterPause" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$pass = [bool](@($sysdir.Problems).Count -eq 0)", "$pass = $true")
        self.assertTrue(any("row of sysdir" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$pass = [bool]($markerProblems.Count -eq 0)", "$pass = $true")
        self.assertTrue(any("marker row" in f for f in self.problems(bad)))

    def test_a_marker_row_that_runs_fewer_scenarios_is_caught(self):
        bad = mutate(self.script, "foreach ($s in $scenarios) { $markerRuns += , (Get-StopResult -Scenario $s -Marker $true) }",
                     "foreach ($s in @($scenarios[0])) { $markerRuns += , (Get-StopResult -Scenario $s -Marker $true) }")
        self.assertTrue(any("every scenario" in f for f in self.problems(bad)))

    def test_a_script_without_its_exit_codes_is_caught(self):
        bad = mutate(self.script, "if (-not $allPass) { exit 1 }\nexit 0\n", "exit 0\n")
        self.assertTrue(any("exits 1 for a red row" in f for f in self.problems(bad)))
        bad = mutate(self.script, "if (-not $allPass) { exit 1 }\nexit 0\n", "if (-not $allPass) { exit 1 }\n")
        self.assertTrue(any("does not end with exit 0" in f for f in self.problems(bad)))

    def test_isWindows_and_a_non_ascii_character_are_caught(self):
        bad = mutate(self.script, "if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {", "if (-not $IsWindows) {")
        self.assertTrue(any("OSVersion.Platform" in f for f in self.problems(bad)))
        self.assertTrue(any("ASCII" in f for f in self.problems(self.script + "\n# caf\u00e9\n")))

    def test_a_step_that_is_not_contract_uv_only_is_caught(self):
        block = step_block(self.workflow)
        self.assertIsNotNone(block)
        other = self.workflow.replace(block, block.replace("matrix.mode == 'contract-uv'", "matrix.mode == 'real'"))
        self.assertTrue(any("contract-uv" in f for f in workflow_problems(other)))

    def test_a_step_that_cannot_fail_is_caught(self):
        block = step_block(self.workflow)
        bad = self.workflow.replace(block, block.replace("        shell: pwsh\n", "        shell: pwsh\n        continue-on-error: true\n", 1))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(bad)))

    def test_a_missing_step_or_upload_is_caught(self):
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\selfapps_stop_pause.ps1"])
        bad = self.workflow.replace("tests/~stop_pause_evidence.txt", "")
        self.assertTrue(any("~stop_pause_evidence" in f for f in workflow_problems(bad)))

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        self.assertTrue(registry_problems(text.replace("self.stoppause.unc\n", "self.stoppause.uncx\n")))
        self.assertTrue(registry_problems("```\n" + " ".join(ROW_IDS[:-1]) + "\n```\nprose: self.stoppause.marker\n"))

    def test_a_shall_that_is_still_listed_as_a_gap_is_caught(self):
        self.assertTrue(shall_list_problems('    "REQ-016.8": "inspection: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-016.80": "gap: x",\n'), [])


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesCanFail(unittest.TestCase):
    """A judge that quietly stops judging would pass every scenario, so the cases are run against mutated copies of the script."""

    def run_mutated(self, old, new, names):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, new), encoding="utf-8")
            wanted = [c for c in judge_cases() if c["name"] in names]
            return run_cases(script, JUDGES, wanted, d)

    def says(self, got, name, needle):
        return any(needle in f for f in got[name])

    def test_a_judge_that_forgets_the_lane_the_run_saw_is_caught(self):
        got = self.run_mutated("    if ($seenLane -ne $WantLane) {", "    if ($false) {", ["pause_lane_defined", "marker_lane_undefined"])
        self.assertFalse(self.says(got, "pause_lane_defined", "saw HP_CI_LANE"))
        self.assertFalse(self.says(got, "marker_lane_undefined", "saw HP_CI_LANE"))

    def test_a_judge_that_forgets_the_stops_own_message_is_caught(self):
        got = self.run_mutated("    if (-not $stop.Success) {", "    if ($false) {", ["pause_no_stop_message"])
        self.assertFalse(self.says(got, "pause_no_stop_message", "never reached the stop"))

    def test_a_judge_that_forgets_a_missing_prompt_is_caught(self):
        got = self.run_mutated("        if (-not $PauseSeen) {", "        if ($false) {", ["pause_never_printed_but_ended", "pause_never_ended"])
        self.assertFalse(self.says(got, "pause_never_printed_but_ended", "ended with no 'Press any key"))
        self.assertFalse(self.says(got, "pause_never_ended", "neither ended nor paused"))

    def test_a_judge_that_cannot_tell_a_run_that_ended_from_one_that_did_not_is_caught(self):
        got = self.run_mutated("\n            if ($Finished) {\n                [void]$out.Add(\"${tag}: the run ended with no", "\n            if ($true) {\n                [void]$out.Add(\"${tag}: the run ended with no",
                               ["pause_never_ended"])
        self.assertFalse(self.says(got, "pause_never_ended", "neither ended nor paused"))
        got = self.run_mutated("\n            if ($Finished) {\n                [void]$out.Add(\"${tag}: the run ended with no", "\n            if ($false) {\n                [void]$out.Add(\"${tag}: the run ended with no",
                               ["pause_never_printed_but_ended"])
        self.assertFalse(self.says(got, "pause_never_printed_but_ended", "ended with no 'Press any key"))

    def test_a_judge_that_forgets_a_prompt_before_the_stop_is_caught(self):
        got = self.run_mutated("            if ($stop.Success -and ($pauseAt -ge 0) -and ($pauseAt -lt $stop.Index)) {", "            if ($false) {", ["pause_before_stop"])
        self.assertFalse(self.says(got, "pause_before_stop", "comes before"))

    def test_a_judge_that_forgets_that_the_run_must_wait_is_caught(self):
        got = self.run_mutated("            if (-not $AliveAfterPause) {", "            if ($false) {", ["pause_not_waiting"])
        self.assertFalse(self.says(got, "pause_not_waiting", "did not wait for a key"))

    def test_a_judge_that_forgets_that_the_run_must_end_after_the_key_is_caught(self):
        got = self.run_mutated("            if (-not $Finished) {\n                [void]$out.Add(\"${tag}: the run did not end after a key was sent\")",
                               "            if ($false) {\n                [void]$out.Add(\"${tag}: the run did not end after a key was sent\")", ["pause_no_end_after_key"])
        self.assertFalse(self.says(got, "pause_no_end_after_key", "did not end after a key"))

    def test_a_judge_that_forgets_a_prompt_in_a_marker_run_is_caught(self):
        got = self.run_mutated("\n        if ($pauseAt -ge 0) {\n", "\n        if ($false) {\n", ["marker_prompt_printed"])
        self.assertFalse(self.says(got, "marker_prompt_printed", "carries the CI marker"))

    def test_a_judge_that_forgets_that_a_marker_run_must_end_by_itself_is_caught(self):
        got = self.run_mutated("        if (-not $Finished) {\n            [void]$out.Add(\"${tag}: the run did not end by itself", "        if ($false) {\n            [void]$out.Add(\"${tag}: the run did not end by itself",
                               ["marker_not_finished"])
        self.assertFalse(self.says(got, "marker_not_finished", "did not end by itself"))

    def test_a_judge_that_forgets_the_exit_code_is_caught(self):
        got = self.run_mutated("        if (([string]$ExitCode) -ne ([string]$WantExit)) {", "        if ($false) {", ["pause_wrong_exit", "marker_wrong_exit"])
        self.assertFalse(self.says(got, "pause_wrong_exit", "the exit code is"))
        self.assertFalse(self.says(got, "marker_wrong_exit", "the exit code is"))

    def test_a_judge_that_judges_the_exit_code_of_a_run_that_did_not_end_is_caught(self):
        got = self.run_mutated("\n    if ($Finished) {\n        if (([string]$ExitCode)", "\n    if ($true) {\n        if (([string]$ExitCode)", ["pause_never_ended"])
        self.assertTrue(self.says(got, "pause_never_ended", "the exit code is"))


MARKER_BLOCK_FIRST = "$markerProblems = @()"
MARKER_BLOCK_LAST = "if ($markerProblems.Count -gt 0) { $markerDetails['problems'] = @($markerProblems) }"

MARKER_DRIVER = r"""
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
function New-Run($name, $skipped, [bool]$bad) {
    if ($skipped) {
        return [pscustomobject]@{ Problems = @(); Skipped = $true
            Details = [ordered]@{ scenario = $name; marker = $true; skip = $true; reason = 'unc-share-unavailable'; uncPath = '' } }
    }
    $list = @()
    if ($bad) { $list = @("${name}: a prompt") }
    return [pscustomobject]@{ Problems = $list; Skipped = $false
        Details = [ordered]@{ scenario = $name; marker = $true; finished = $true; pauseSeen = $false; exitCode = 1; laneSeen = 'defined' } }
}
$markerRuns = @()
foreach ($n in @('success', 'die', 'usage', 'req011', 'sysdir')) { $markerRuns += , (New-Run $n $false ($env:MB_BAD -eq $n)) }
$markerRuns += , (New-Run 'unc' ($env:MB_SKIP -eq '1') $false)
__BLOCK__
ConvertTo-Json -InputObject $markerDetails -Compress -Depth 6
"""


def marker_block(text):
    """The lines of the script that turn the six marker runs into the details of the marker row."""
    t = norm(text)
    start = t.index(MARKER_BLOCK_FIRST)
    end = t.index(MARKER_BLOCK_LAST) + len(MARKER_BLOCK_LAST)
    return t[start:end]


def run_marker_block(block, skip, bad=""):
    with tempfile.TemporaryDirectory() as d:
        driver = Path(d) / "marker_driver.ps1"
        driver.write_text(MARKER_DRIVER.replace("__BLOCK__", block), encoding="ascii")
        env = dict(os.environ)
        env["MB_SKIP"] = "1" if skip else "0"
        env["MB_BAD"] = bad
        proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(driver)], env=env,
                              capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return json.loads(proc.stdout.strip().splitlines()[-1])


@unittest.skipUnless(PWSH, "pwsh not available")
class MarkerRowRecordsASkip(unittest.TestCase):
    """CodeRabbit, PR #546: when the administrative share is unavailable the marker run of the unc scenario is skipped, and the registry
    promises that the marker row itself says so (skip and reason). The real aggregation lines run here on synthetic runs."""

    def setUp(self):
        self.block = marker_block(SCRIPT.read_text(encoding="utf-8"))

    def test_a_skipped_unc_run_is_recorded_on_the_row_itself(self):
        d = run_marker_block(self.block, skip=True)
        self.assertIs(d.get("skip"), True, d)
        self.assertEqual(d.get("reason"), "unc-share-unavailable", d)
        self.assertEqual(d.get("skippedScenarios"), ["unc"], d)
        self.assertNotIn("problems", d)
        self.assertEqual(len(d["runs"]), 6)

    def test_a_run_that_did_not_skip_records_no_skip(self):
        d = run_marker_block(self.block, skip=False)
        self.assertNotIn("skip", d)
        self.assertNotIn("reason", d)
        self.assertNotIn("problems", d)

    def test_a_skip_does_not_hide_the_failure_of_another_marker_run(self):
        d = run_marker_block(self.block, skip=True, bad="die")
        self.assertIs(d.get("skip"), True, d)
        self.assertEqual(d.get("problems"), ["die: a prompt"], d)

    def test_without_the_recording_lines_the_skip_is_not_on_the_row(self):
        bad = mutate(self.block, "    $markerDetails['skip'] = $true\n", "")
        d = run_marker_block(bad, skip=True)
        self.assertNotIn("skip", d)


if __name__ == "__main__":
    unittest.main()
