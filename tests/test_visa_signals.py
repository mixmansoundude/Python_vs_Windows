"""Item 111 (README REQ-008.14): NOINPUT or HP_NONINTERACTIVE alone answers the NI-VISA subfolder question with no, without waiting.

REQ-008.14 says that in a run with NOINPUT or HP_NONINTERACTIVE set the question of REQ-008.7 is treated as answered with no and the
run does not wait. :visa_subfolder_gate in run_setup.bat tests four signals in a fixed order before it reads the console (a test
answer, the CI marker, NOINPUT, HP_NONINTERACTIVE). Every real bootstrap of tests/selfapps_pyvisa_subfolder.ps1 carries the CI
marker, so the last two tests could be deleted without a row turning red. tests/selfapps_visa_signals.ps1 (three rows,
self.nivisa.signals.noinput, .nonint and .control; contract-uv lane, gating) cuts the real block out of run_setup.bat, sets one
signal at a time under cmd.exe with a stub in place of the console read, and judges what the block did.

What really happens is shown on Windows by that script. These rules read run_setup.bat, the script, batch-check.yml,
docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, and run the script's own judging functions through a real pwsh on
synthetic runs (a run that passes, and one run for each way to be wrong), so a reworded log line, a signal that is no longer tested
before the console read, a block that reaches something the driver does not define, a scenario that stops being the one the shall
names, a judge that stops judging or a step that stops gating fails here with a sentence, before a Windows run is needed.
Synthetic cases prove each rule can fail.
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
SCRIPT = REPO / "tests" / "selfapps_visa_signals.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

ROW_IDS = ("self.nivisa.signals.noinput", "self.nivisa.signals.nonint", "self.nivisa.signals.control")
ROW_REQ = "REQ-008.14"
GAP_SHALL = "REQ-008.14"

GATE_START = ":visa_subfolder_gate"
GATE_END = ":dll_bundle_recover"
GATE_LABELS = [":visa_subfolder_gate", ":visa_gate_from_override", ":visa_gate_remembered", ":visa_gate_accept", ":visa_gate_decline"]

# Every variable the block reads or sets. The script's driver sets or clears each of them, so none comes from the runner.
KNOWN_VARIABLES = {
    "HP_VISA_DECISION", "HP_VISA_WHERE", "HP_VISA_CHOICE", "HP_VISA_RAW", "HP_VISA_T", "HP_TEST_VISA_ANSWER",
    "HP_TEST_FORCE_INTERACTIVE_VISA", "HP_CI_LANE", "NOINPUT", "HP_NONINTERACTIVE", "NEED_VISA",
}
# The lines of the block, in the order the signals are tested (each exactly once, each live).
HEADING_LINE_START = "echo *** The NI-VISA driver looks needed only by a file in a subfolder:"
TEST_ANSWER_LINE = "if defined HP_TEST_VISA_ANSWER goto :visa_gate_from_override"
CI_LINE = "if defined HP_CI_LANE if not defined HP_TEST_FORCE_INTERACTIVE_VISA goto :visa_gate_decline"
NOINPUT_LINE = "if defined NOINPUT goto :visa_gate_decline"
NONINT_LINE = "if defined HP_NONINTERACTIVE goto :visa_gate_decline"
TIMER_LINE = 'set "HP_VISA_T=30"'
ACCEPT_LOG = 'call :log "[INFO] NI-VISA install for a subfolder-only import: accepted."'
DECLINE_LOG = 'call :log "[VISA] skipped (subfolder_only)"'

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~visa_signals_evidence.txt",
    "tests/~selftest_visasignals/*/~driver*",
    "tests/~selftest_visasignals/*/~choice_args.txt",
)
JUDGES = ["Get-VisaDecision", "Get-SignalProblems"]


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


def cut_block(text, start, end):
    """Lines from the line that is exactly `start` up to, not including, the line that is exactly `end`."""
    lines = lines_of(text)
    s = next((i for i, ln in enumerate(lines) if ln.strip() == start), None)
    if s is None:
        return None
    e = next((j for j in range(s + 1, len(lines)) if lines[j].strip() == end), None)
    if e is None:
        return None
    return lines[s:e]


def variables_in(lines):
    """Names of the variables the live lines read (%X%, %X:~0,1%, defined X) or set (set "X=)."""
    names = set()
    for ln in live_bat(lines):
        names.update(re.findall(r"%([A-Za-z_][A-Za-z0-9_]*)(?::[^%]*)?%", ln))
        names.update(re.findall(r"(?i)\bdefined\s+([A-Za-z_][A-Za-z0-9_]*)", ln))
        names.update(re.findall(r'(?i)\bset\s+"?([A-Za-z_][A-Za-z0-9_]*)=', ln))
    return names


def script_patterns(text):
    """The three regular expressions the script looks for in the console and the log, as written in the script."""
    found = dict(re.findall(r"\$(headingPattern|acceptedPattern|declinedPattern)\s*=\s*'([^']*)'", norm(text)))
    return found


def label_section(body, label):
    """The live lines of one label up to the next label (label line excluded)."""
    start = body.index(label)
    out = []
    for ln in body[start + 1:]:
        if ln.startswith(":"):
            break
        out.append(ln)
    return out


# --- the batch file: what the script assumes about the gate -----------------------------------------------------------------

def gate_problems(batch, script_text):
    """README REQ-008.14 in the batch file: the two signals are tested before the console is read, the read is the one timed
    choice, the two decisions are logged and remembered as the script reads them, and the block reaches only what the driver defines."""
    found = []
    stripped = [ln.strip() for ln in lines_of(batch)]
    for label in (GATE_START, GATE_END):
        n = sum(1 for ln in stripped if ln == label)
        if n != 1:
            found.append("the label %s appears %d time(s); expected exactly once" % (label, n))
    if found:
        return found
    block = cut_block(batch, GATE_START, GATE_END)
    if block is None:
        return ["the block from %s to %s cannot be cut" % (GATE_START, GATE_END)]
    body = [ln.strip() for ln in live_bat(block)]

    labels = [ln for ln in body if ln.startswith(":")]
    if labels != GATE_LABELS:
        found.append("the block's labels are %r, the script's driver was written for %r" % (labels, GATE_LABELS))
    calls = sorted(set(re.findall(r"(?i)\bcall\s+(:[A-Za-z_][A-Za-z0-9_]*)", "\n".join(body))))
    if calls != [":log"]:
        found.append("the block calls %r; the driver defines only :log" % (calls,))
    for target in sorted(set(re.findall(r"(?i)\bgoto\s+(:[A-Za-z_][A-Za-z0-9_]*)", "\n".join(body)))):
        if target not in labels:
            found.append("the block goes to %s, which is not a label of the block, so the driver cannot run it" % target)
    unknown = sorted(variables_in(block) - KNOWN_VARIABLES)
    if unknown:
        found.append("the block reads or sets %s, which the driver of tests/selfapps_visa_signals.ps1 does not define or clear" % ", ".join(unknown))
    driver_sets = set(re.findall(r"'set \"([A-Za-z_][A-Za-z0-9_]*)=", norm(script_text)))
    missing = sorted(KNOWN_VARIABLES - driver_sets)
    if missing:
        found.append("the driver of tests/selfapps_visa_signals.ps1 does not set or clear %s" % ", ".join(missing))

    def index_of(text, what):
        hits = [i for i, ln in enumerate(body) if ln == text]
        if len(hits) != 1:
            found.append("%s: expected exactly one live line %r, found %d" % (what, text, len(hits)))
            return None
        return hits[0]

    heading_hits = [i for i, ln in enumerate(body) if ln.startswith(HEADING_LINE_START)]
    if len(heading_hits) != 1:
        found.append("the question's heading line (%s ...) must appear once, found %d" % (HEADING_LINE_START, len(heading_hits)))
    heading = heading_hits[0] if len(heading_hits) == 1 else None
    test_answer = index_of(TEST_ANSWER_LINE, "the test answer")
    ci = index_of(CI_LINE, "the CI marker")
    noinput = index_of(NOINPUT_LINE, "NOINPUT")
    nonint = index_of(NONINT_LINE, "HP_NONINTERACTIVE")
    timer = index_of(TIMER_LINE, "the wait of 30 seconds")
    choices = [i for i, ln in enumerate(body) if re.match(r"(?i)choice\s", ln)]
    if len(choices) != 1:
        found.append("the block must hold exactly one live choice line, found %d" % len(choices))
        choice = None
    else:
        choice = choices[0]
        line = body[choice]
        if not re.search(r"(?i)/C\s+YN(\s|$)", line):
            found.append("the choice line no longer offers exactly Y and N (/C YN)")
        if not re.search(r"(?i)/T\s+%HP_VISA_T%(\s|$)", line):
            found.append("the choice line no longer waits for %HP_VISA_T%, the 30 seconds set above it (/T %HP_VISA_T%)")
        if not re.search(r"(?i)/D\s+N(\s|$)", line):
            found.append("the choice line no longer defaults to N after the wait (/D N)")
    order = [("the heading", heading), ("the test answer", test_answer), ("the CI marker", ci), ("NOINPUT", noinput),
             ("HP_NONINTERACTIVE", nonint), ("the timer", timer), ("the console read", choice)]
    known = [(name, at) for name, at in order if at is not None]
    for (n1, a1), (n2, a2) in zip(known, known[1:]):
        if a1 > a2:
            found.append("%s must come before %s, or a run with a signal reaches the console read first" % (n1, n2))
    if choice is not None:
        for name, at in order[1:5]:
            if at is not None and at > choice:
                found.append("%s must come before the console read, or a run with that signal waits for an answer nobody can give" % name)

    accept = label_section(body, ":visa_gate_accept") if ":visa_gate_accept" in body else []
    decline = label_section(body, ":visa_gate_decline") if ":visa_gate_decline" in body else []
    if accept.count('set "HP_VISA_DECISION=Y"') != 1 or accept.count(ACCEPT_LOG) != 1 or accept.count('set "NEED_VISA=1"') != 1:
        found.append("the accepting branch no longer sets HP_VISA_DECISION=Y, logs the accepted line and sets NEED_VISA=1, once each")
    if decline.count('set "HP_VISA_DECISION=N"') != 1 or decline.count(DECLINE_LOG) != 1:
        found.append("the declining branch no longer sets HP_VISA_DECISION=N and logs the skipped line, once each")
    if any("NEED_VISA" in ln for ln in decline):
        found.append("the declining branch changes NEED_VISA, which the script reads as 2 for a decline")

    patterns = script_patterns(script_text)
    if sorted(patterns) != ["acceptedPattern", "declinedPattern", "headingPattern"]:
        found.append("the script no longer names its three patterns ($headingPattern, $acceptedPattern, $declinedPattern)")
    else:
        if sum(1 for ln in body if re.search(patterns["headingPattern"], ln)) != 1:
            found.append("the script's heading pattern no longer matches exactly one live line of the block")
        if sum(1 for ln in body if re.search(patterns["acceptedPattern"], ln)) != 1:
            found.append("the script's accepted pattern no longer matches exactly one live line of the block")
        if sum(1 for ln in body if re.search(patterns["declinedPattern"], ln)) != 1:
            found.append("the script's declined pattern no longer matches exactly one live line of the block")
    return found


# --- the script ------------------------------------------------------------------------------------------------------------------

def script_problems(text):
    t = norm(text)
    live = live_hash(t)
    flat = "\n".join(live)
    found = []
    pairs = re.findall(r"\bid = '(self\.nivisa\.signals\.[a-z]+)'; req = '([^']*)'", t)
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if sorted(ids) != sorted(list(ROW_IDS) * 2):
        found.append("each row id must be a literal at exactly two Write-NdjsonRow call sites (the shared one and its own), found %r" % ids)
    if sorted(p[0] for p in pairs) != sorted(list(ROW_IDS) * 2):
        found.append("every row id must be followed by its literal req tag, found %r" % pairs)
    if any(p[1] != ROW_REQ for p in pairs):
        found.append("every row must carry the literal req tag %r, found %r" % (ROW_REQ, [p[1] for p in pairs]))
    for scenario in ("Name = 'noinput'; Signal = 'set \"NOINPUT=1\"'; ExpectRead = $false",
                     "Name = 'nonint'; Signal = 'set \"HP_NONINTERACTIVE=1\"'; ExpectRead = $false",
                     "Name = 'control'; Signal = ''; ExpectRead = $true"):
        if scenario not in flat:
            found.append("the scenario list no longer holds: %s" % scenario)
    clears = ("HP_CI_LANE", "NOINPUT", "HP_NONINTERACTIVE", "HP_TEST_VISA_ANSWER", "HP_TEST_FORCE_INTERACTIVE_VISA", "HP_VISA_DECISION")
    for name in clears:
        if "'set \"%s=\"'" % name not in flat:
            found.append("the driver no longer clears %s before the scenario's signal is set" % name)
    if "'set \"NOINPUT=\"'" in flat and "$Scenario.Signal" in flat and flat.index("$Scenario.Signal") < flat.index("'set \"NOINPUT=\"'"):
        found.append("the signal is set before the variables are cleared, so the clear would remove it")
    if "'set \"CHOICE_RC=1\"'" not in flat:
        found.append("the stub for the console read no longer answers Y (errorlevel 1), so a read in spite of a signal would not show")
    if "$1call :choice_stub " not in flat or "':choice_stub', '>>\"%CHOICE_ARGS%\" echo %*', 'exit /b %CHOICE_RC%'" not in flat:
        found.append("the console read is no longer replaced by the recording stub")
    if "call ~driver.bat > ~driver_console.txt 2>&1 < nul" not in flat:
        found.append("the driver no longer runs with standard input closed (< nul) and its console in ~driver_console.txt")
    if "-LimitMs 180000" not in flat or "taskkill.exe /F /T /PID $p.Id" not in flat:
        found.append("a driver that outlives its limit is no longer stopped with taskkill /F /T after 180000 ms")
    if "-StartLabel ':visa_subfolder_gate' -EndLabel ':dll_bundle_recover'" not in flat:
        found.append("the script no longer cuts :visa_subfolder_gate up to :dll_bundle_recover out of run_setup.bat")
    for need in ("'call :visa_subfolder_gate'", "'>>\"%RESULT%\" echo NEED_VISA=%NEED_VISA%'", "'>>\"%RESULT%\" echo DECISION=%HP_VISA_DECISION%'",
                 "'>\"%RESULT%\" echo START'", "'>>\"%RESULT%\" echo END'"):
        if need not in flat:
            found.append("the driver no longer writes %s" % need)
    call = "$found = @(Get-SignalProblems"
    if call not in flat:
        found.append("the verdict no longer comes from Get-SignalProblems")
    else:
        args = flat.split(call, 1)[1]
        for need in ("-Finished ([bool]$run.Finished)", "-ChoiceArgsText $run.ChoiceArgs", "-HeadingPattern $headingPattern",
                     "-AcceptedPattern $acceptedPattern", "-DeclinedPattern $declinedPattern", "-ExpectRead ([bool]$Scenario.ExpectRead)"):
            if need not in args.split("\n", 2)[0] + "\n" + args.split("\n", 2)[1]:
                found.append("the verdict no longer hands %s to Get-SignalProblems" % need)
    for var in ("noinput", "nonint", "control"):
        if "$pass = [bool](@($%s.Problems).Count -eq 0)" % var not in flat:
            found.append("the row of %s is no longer judged by its list of problems" % var)
    if flat.count("pass = $pass") < 3:
        found.append("the three rows no longer write pass = $pass")
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


# --- the workflow, the registry and the shall list --------------------------------------------------------------------------

def step_block(text):
    lines = norm(text).split("\n")
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if "selfapps_visa_signals.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_visa_signals.ps1"]
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


# --- the script's judging functions, run through a real pwsh ------------------------------------------------------------------

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


HEADING = "The NI-VISA driver looks needed only by a file in a subfolder:"
ACCEPTED = r"NI-VISA install for a subfolder-only import: accepted\."
DECLINED = r"\[VISA\] skipped \(subfolder_only\)"
CONSOLE = "\r\n*** The NI-VISA driver looks needed only by a file in a subfolder: subfolder\\old_program.py ***\r\n"
READ = '/C YN /N /T 30 /D N /M "  Install the NI-VISA driver now? [Y/N, defaults to N after 30s] "\r\n'
SIGNAL_RESULT = "START\r\nNEED_VISA=2\r\nDECISION=N\r\nEND\r\n"
SIGNAL_LOG = "[VISA] skipped (subfolder_only)\r\n"
CONTROL_RESULT = "START\r\nNEED_VISA=1\r\nDECISION=Y\r\nEND\r\n"
CONTROL_LOG = "[INFO] NI-VISA install for a subfolder-only import: accepted.\r\n"


def signal_args(scenario="noinput", **over):
    args = dict(Scenario=scenario, Finished=True, ResultText=SIGNAL_RESULT, LogText=SIGNAL_LOG, ConsoleText=CONSOLE, ChoiceArgsText="",
                HeadingPattern=HEADING, AcceptedPattern=ACCEPTED, DeclinedPattern=DECLINED, ExpectRead=False)
    args.update(over)
    return args


def control_args(**over):
    args = signal_args("control", ResultText=CONTROL_RESULT, LogText=CONTROL_LOG, ChoiceArgsText=READ, ExpectRead=True)
    args.update(over)
    return args


def judge_cases():
    c = []
    # --- Get-VisaDecision
    c.append(case("decision_accepted", "Get-VisaDecision", ResultText="START\r\nNEED_VISA=1\r\nEND\r\n"))
    c.append(case("decision_declined", "Get-VisaDecision", ResultText="START\r\nNEED_VISA=2\r\nEND\r\n"))
    c.append(case("decision_unknown", "Get-VisaDecision", ResultText="START\r\nEND\r\n"))
    c.append(case("decision_other_value", "Get-VisaDecision", ResultText="START\r\nNEED_VISA=3\r\nEND\r\n"))
    c.append(case("decision_not_a_prefix", "Get-VisaDecision", ResultText="START\r\nXNEED_VISA=1\r\nNEED_VISA=12\r\nEND\r\n"))
    # --- Get-SignalProblems: a signal row
    c.append(case("signal_good_noinput", "Get-SignalProblems", **signal_args("noinput")))
    c.append(case("signal_good_nonint", "Get-SignalProblems", **signal_args("nonint")))
    c.append(case("signal_unfinished", "Get-SignalProblems", **signal_args(Finished=False)))
    c.append(case("signal_no_end", "Get-SignalProblems", **signal_args(ResultText="START\r\n")))
    c.append(case("signal_heading_twice", "Get-SignalProblems", **signal_args(ConsoleText=CONSOLE + CONSOLE)))
    c.append(case("signal_heading_missing", "Get-SignalProblems", **signal_args(ConsoleText="")))
    c.append(case("signal_read_but_declined", "Get-SignalProblems", **signal_args(ChoiceArgsText=READ)))
    c.append(case("signal_read_and_accepted", "Get-SignalProblems", **signal_args(ResultText=CONTROL_RESULT, LogText=CONTROL_LOG, ChoiceArgsText=READ)))
    c.append(case("signal_accepted_without_a_read", "Get-SignalProblems", **signal_args(ResultText="START\r\nNEED_VISA=1\r\nDECISION=N\r\nEND\r\n")))
    c.append(case("signal_decision_unknown", "Get-SignalProblems", **signal_args(ResultText="START\r\nDECISION=N\r\nEND\r\n")))
    c.append(case("signal_remembered_y", "Get-SignalProblems", **signal_args(ResultText="START\r\nNEED_VISA=2\r\nDECISION=Y\r\nEND\r\n")))
    c.append(case("signal_no_decline_line", "Get-SignalProblems", **signal_args(LogText="")))
    c.append(case("signal_decline_line_twice", "Get-SignalProblems", **signal_args(LogText=SIGNAL_LOG + SIGNAL_LOG)))
    c.append(case("signal_accepted_line", "Get-SignalProblems", **signal_args(LogText=SIGNAL_LOG + CONTROL_LOG)))
    # --- Get-SignalProblems: the control
    c.append(case("control_good", "Get-SignalProblems", **control_args()))
    c.append(case("control_unfinished", "Get-SignalProblems", **control_args(Finished=False)))
    c.append(case("control_no_read", "Get-SignalProblems", **control_args(ChoiceArgsText="")))
    c.append(case("control_read_twice", "Get-SignalProblems", **control_args(ChoiceArgsText=READ + READ)))
    c.append(case("control_wrong_wait", "Get-SignalProblems", **control_args(ChoiceArgsText=READ.replace("/T 30", "/T 300"))))
    c.append(case("control_wrong_default", "Get-SignalProblems", **control_args(ChoiceArgsText=READ.replace("/D N", "/D Y"))))
    c.append(case("control_wrong_keys", "Get-SignalProblems", **control_args(ChoiceArgsText=READ.replace("/C YN", "/C YNA"))))
    c.append(case("control_declined_despite_y", "Get-SignalProblems",
                  **control_args(ResultText="START\r\nNEED_VISA=2\r\nDECISION=Y\r\nEND\r\n")))
    c.append(case("control_remembered_n", "Get-SignalProblems",
                  **control_args(ResultText="START\r\nNEED_VISA=1\r\nDECISION=N\r\nEND\r\n")))
    c.append(case("control_no_accepted_line", "Get-SignalProblems", **control_args(LogText="")))
    c.append(case("control_declined_line", "Get-SignalProblems", **control_args(LogText=CONTROL_LOG + SIGNAL_LOG)))
    return c


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

    def test_the_decision_is_the_value_the_block_left_in_need_visa(self):
        self.assertEqual(self.r["decision_accepted"], ["accepted"])
        self.assertEqual(self.r["decision_declined"], ["declined"])
        self.assertEqual(self.r["decision_unknown"], ["unknown"])
        self.assertEqual(self.r["decision_other_value"], ["unknown"])
        self.assertEqual(self.r["decision_not_a_prefix"], ["unknown"])

    def test_a_signal_run_that_declined_without_reading_the_console_has_no_problem(self):
        self.assertEqual(self.r["signal_good_noinput"], [])
        self.assertEqual(self.r["signal_good_nonint"], [])

    def test_the_control_that_read_once_with_the_30_second_default_and_honored_y_has_no_problem(self):
        self.assertEqual(self.r["control_good"], [])

    def test_a_driver_that_did_not_finish_or_did_not_reach_its_end_is_one_problem_and_nothing_else(self):
        self.only("signal_unfinished", "the driver did not finish within the time limit")
        self.only("control_unfinished", "the driver did not finish within the time limit")
        self.only("signal_no_end", "the driver did not reach its end")

    def test_a_heading_that_is_missing_or_printed_twice_is_named(self):
        self.only("signal_heading_twice", "heading was printed 2 time(s), expected 1")
        self.only("signal_heading_missing", "heading was printed 0 time(s), expected 1")

    def test_a_read_of_the_console_in_spite_of_a_signal_is_named_even_when_the_run_still_declined(self):
        self.only("signal_read_but_declined", "read the console 1 time(s) in spite of the signal, so it would have waited")

    def test_a_block_that_reads_the_console_in_spite_of_a_signal_takes_the_stubs_y_and_is_named_for_all_of_it(self):
        found = self.r["signal_read_and_accepted"]
        self.assertEqual(len(found), 5, found)
        self.assertTrue(any("in spite of the signal" in f for f in found), found)
        self.assertTrue(any("accepted although a signal says nobody can answer" in f for f in found), found)
        self.assertTrue(any("remembered decision is not N" in f for f in found), found)
        self.assertTrue(any("0 declined line(s), expected 1" in f for f in found), found)
        self.assertTrue(any("1 accepted line(s), expected 0" in f for f in found), found)

    def test_each_other_wrong_signal_run_is_one_problem(self):
        self.only("signal_accepted_without_a_read", "accepted although a signal says nobody can answer")
        self.only("signal_decision_unknown", "the gate unknown, expected declined")
        self.only("signal_remembered_y", "the remembered decision is not N")
        self.only("signal_no_decline_line", "0 declined line(s), expected 1")
        self.only("signal_decline_line_twice", "2 declined line(s), expected 1")
        self.only("signal_accepted_line", "1 accepted line(s), expected 0")

    def test_a_control_that_never_reached_the_console_read_says_the_signal_rows_prove_nothing(self):
        found = self.r["control_no_read"]
        self.assertTrue(any("never reached its choice line, so the signal rows prove nothing" in f for f in found), found)

    def test_a_control_that_read_twice_or_with_other_arguments_is_named(self):
        self.only("control_read_twice", "read the console 2 times, expected once")
        self.only("control_wrong_wait", "does not wait for 30 seconds (/T 30)")
        self.only("control_wrong_default", "does not default to N after the wait (/D N)")
        self.only("control_wrong_keys", "does not offer exactly Y and N (/C YN)")

    def test_a_control_whose_y_was_not_honored_is_named(self):
        self.only("control_declined_despite_y", "the answer Y was not honored: the gate declined, expected accepted")
        self.only("control_remembered_n", "the remembered decision is not Y")
        self.only("control_no_accepted_line", "0 accepted line(s), expected 1")
        self.only("control_declined_line", "1 declined line(s), expected 0")


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


# --- the rules on the real files ---------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_gate_tests_both_signals_before_it_reads_the_console_and_logs_and_remembers_its_decisions(self):
        self.assertEqual(gate_problems(self.batch, self.script), [])

    def test_the_script_has_its_rows_scenarios_driver_judges_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shall_is_no_longer_listed_as_a_gap(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        block = cut_block(self.batch, GATE_START, GATE_END)
        self.assertGreater(len(live_bat(block)), 25)
        self.assertEqual(len(judge_cases()), 30)
        self.assertEqual(sorted(KNOWN_VARIABLES), sorted(variables_in(block) | {"HP_VISA_DECISION"}))

    def test_every_judge_the_driver_is_asked_for_is_a_function_of_the_script(self):
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))

    def test_the_real_texts_the_judge_reads_match_the_patterns_in_the_script(self):
        patterns = script_patterns(self.script)
        block = "\n".join(cut_block(self.batch, GATE_START, GATE_END))
        self.assertRegex(block, patterns["headingPattern"])
        self.assertRegex(block, patterns["acceptedPattern"])
        self.assertRegex(block, patterns["declinedPattern"])


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
        return gate_problems(batch, self.script)

    def test_a_label_that_is_missing_or_duplicated_is_reported(self):
        gone = mutate(self.batch, "\n:visa_subfolder_gate\n", "\n:visa_subfolder_gatex\n")
        self.assertTrue(any("appears 0 time(s)" in f for f in self.problems(gone)))
        twice = self.batch + "\n:dll_bundle_recover\n"
        self.assertTrue(any("appears 2 time(s)" in f for f in self.problems(twice)))
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))

    def test_a_signal_that_is_no_longer_tested_is_reported(self):
        bad = mutate(self.batch, "if defined NOINPUT goto :visa_gate_decline\n", "")
        self.assertTrue(any("NOINPUT" in f and "expected exactly one live line" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "if defined HP_NONINTERACTIVE goto :visa_gate_decline\n", "")
        self.assertTrue(any("HP_NONINTERACTIVE" in f and "expected exactly one live line" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_signal_that_no_longer_declines_is_reported(self):
        bad = mutate(self.batch, "if defined NOINPUT goto :visa_gate_decline\n", "if defined NOINPUT goto :visa_gate_accept\n")
        self.assertTrue(any("NOINPUT" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_signal_tested_after_the_console_read_is_reported(self):
        bad = mutate(self.batch, "if defined NOINPUT goto :visa_gate_decline\nif defined HP_NONINTERACTIVE goto :visa_gate_decline\n", "")
        bad = mutate(bad, "if errorlevel 2 goto :visa_gate_decline\nif not errorlevel 1 goto :visa_gate_decline\ngoto :visa_gate_accept\n",
                     "if errorlevel 2 goto :visa_gate_decline\nif not errorlevel 1 goto :visa_gate_decline\nif defined NOINPUT goto :visa_gate_decline\n"
                     "if defined HP_NONINTERACTIVE goto :visa_gate_decline\ngoto :visa_gate_accept\n")
        found = self.problems(bad)
        self.assertTrue(any("must come before the console read" in f for f in found), found)

    def test_a_console_read_that_waits_longer_or_defaults_to_yes_is_reported(self):
        bad = mutate(self.batch, 'set "HP_VISA_T=30"\n', 'set "HP_VISA_T=300"\n')
        self.assertTrue(any("the wait of 30 seconds" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "choice /C YN /N /T %HP_VISA_T% /D N /M", "choice /C YN /N /T %HP_VISA_T% /D Y /M")
        self.assertTrue(any("defaults to N" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "choice /C YN /N /T %HP_VISA_T% /D N /M", "choice /C YN /N /T 90 /D N /M")
        self.assertTrue(any("%HP_VISA_T%" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_second_console_read_is_reported(self):
        bad = mutate(self.batch, "goto :visa_gate_accept\n:visa_gate_from_override\n", "choice /C YN /N /T 5 /D N\ngoto :visa_gate_accept\n:visa_gate_from_override\n")
        self.assertTrue(any("exactly one live choice line, found 2" in f for f in self.problems(bad)), self.problems(bad))

    def test_the_ci_marker_and_test_answer_lines_are_pinned_too(self):
        bad = mutate(self.batch, "if defined HP_CI_LANE if not defined HP_TEST_FORCE_INTERACTIVE_VISA goto :visa_gate_decline\n", "")
        self.assertTrue(any("the CI marker" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "if defined HP_TEST_VISA_ANSWER goto :visa_gate_from_override\n", "")
        self.assertTrue(any("the test answer" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_block_that_calls_something_the_driver_does_not_define_is_reported(self):
        bad = mutate(self.batch, 'set "NEED_VISA=1"\nexit /b 0\n:visa_gate_decline\n', 'set "NEED_VISA=1"\ncall :cleanup_visa\nexit /b 0\n:visa_gate_decline\n')
        self.assertTrue(any(":cleanup_visa" in f and "driver defines only :log" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_block_that_reads_a_new_variable_is_reported(self):
        bad = mutate(self.batch, 'if defined NOINPUT goto :visa_gate_decline\n', 'if defined NOINPUT goto :visa_gate_decline\nif defined HP_VISA_EXTRA goto :visa_gate_decline\n')
        self.assertTrue(any("HP_VISA_EXTRA" in f and "does not define or clear" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_goto_out_of_the_block_is_reported(self):
        bad = mutate(self.batch, "if defined NOINPUT goto :visa_gate_decline\n", "if defined NOINPUT goto :after_visa_gate\n")
        self.assertTrue(any(":after_visa_gate" in f and "not a label of the block" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_new_label_inside_the_block_is_reported(self):
        bad = mutate(self.batch, "\n:visa_gate_remembered\n", "\n:visa_gate_remembered\n:visa_gate_extra\n")
        self.assertTrue(any("the block's labels are" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_reworded_decision_line_or_a_changed_remembered_value_is_reported(self):
        bad = mutate(self.batch, 'call :log "[VISA] skipped (subfolder_only)"', 'call :log "[VISA] skipped (every match is in a subfolder)"')
        self.assertTrue(any("declining branch" in f or "declined pattern" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'call :log "[INFO] NI-VISA install for a subfolder-only import: accepted."',
                     'call :log "[INFO] NI-VISA install for a subfolder-only import: will install."')
        self.assertTrue(any("accepting branch" in f or "accepted pattern" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'set "HP_VISA_DECISION=N"', 'set "HP_VISA_DECISION=no"')
        self.assertTrue(any("declining branch" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'call :log "[VISA] skipped (subfolder_only)"\nexit /b 0\n', 'call :log "[VISA] skipped (subfolder_only)"\nset "NEED_VISA=0"\nexit /b 0\n')
        self.assertTrue(any("changes NEED_VISA" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_heading_that_is_reworded_is_reported(self):
        bad = mutate(self.batch, "echo *** The NI-VISA driver looks needed only by a file in a subfolder:", "echo *** The NI-VISA driver may be needed by a file in a subfolder:")
        found = self.problems(bad)
        self.assertTrue(any("heading line" in f for f in found) and any("heading pattern" in f for f in found), found)


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the workflow, the registry and the shall list is shown to fail on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def problems(self, text):
        return script_problems(text)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "id = 'self.nivisa.signals.noinput'; req = 'REQ-008.14'; pass = $pass", "id = $rowId; req = 'REQ-008.14'; pass = $pass")
        self.assertTrue(any("literal" in f for f in self.problems(bad)))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "id = 'self.nivisa.signals.nonint'; req = 'REQ-008.14'; pass = $pass", "id = 'self.nivisa.signals.nonint'; req = 'REQ-008'; pass = $pass")
        self.assertTrue(any("req tag" in f for f in self.problems(bad)))

    def test_a_scenario_that_changes_its_signal_or_stops_being_the_control_is_caught(self):
        bad = mutate(self.script, "Signal = 'set \"NOINPUT=1\"'", "Signal = 'set \"NOINPUT=\"'")
        self.assertTrue(any("scenario list" in f for f in self.problems(bad)))
        bad = mutate(self.script, "Signal = 'set \"HP_NONINTERACTIVE=1\"'", "Signal = 'set \"HP_NONINTERACTIVE=1\"; set \"NOINPUT=1\"'")
        self.assertTrue(any("scenario list" in f for f in self.problems(bad)))
        bad = mutate(self.script, "Name = 'control'; Signal = ''; ExpectRead = $true", "Name = 'control'; Signal = 'set \"NOINPUT=1\"'; ExpectRead = $true")
        self.assertTrue(any("scenario list" in f for f in self.problems(bad)))

    def test_a_driver_that_stops_clearing_a_variable_or_sets_the_signal_before_clearing_is_caught(self):
        bad = mutate(self.script, "'set \"HP_CI_LANE=\"', 'set \"NOINPUT=\"', 'set \"HP_NONINTERACTIVE=\"'", "'set \"NOINPUT=\"', 'set \"HP_NONINTERACTIVE=\"'")
        self.assertTrue(any("no longer clears HP_CI_LANE" in f for f in self.problems(bad)))
        early = mutate(self.script, "    $lines = New-Object System.Collections.ArrayList\n    foreach ($l in @(\n        '@echo off', 'setlocal',",
                       "    $lines = New-Object System.Collections.ArrayList\n    if ($Scenario.Signal) { [void]$lines.Add($Scenario.Signal) }\n    foreach ($l in @(\n        '@echo off', 'setlocal',")
        self.assertTrue(any("signal is set before the variables are cleared" in f for f in self.problems(early)))

    def test_a_stub_that_answers_n_or_a_console_read_that_is_not_replaced_is_caught(self):
        bad = mutate(self.script, "'set \"CHOICE_RC=1\"'", "'set \"CHOICE_RC=2\"'")
        self.assertTrue(any("answers Y" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$1call :choice_stub ", "$1call :other_stub ")
        self.assertTrue(any("recording stub" in f for f in self.problems(bad)))

    def test_open_standard_input_and_a_missing_kill_are_caught(self):
        bad = mutate(self.script, "2>&1 < nul'", "2>&1'")
        self.assertTrue(any("standard input" in f for f in self.problems(bad)))
        bad = mutate(self.script, "& taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null", "")
        self.assertTrue(any("taskkill" in f for f in self.problems(bad)))

    def test_a_cut_that_moved_or_a_driver_line_that_vanished_is_caught(self):
        bad = mutate(self.script, "-StartLabel ':visa_subfolder_gate' -EndLabel ':dll_bundle_recover'", "-StartLabel ':visa_subfolder_gate' -EndLabel ':log'")
        self.assertTrue(any("cuts :visa_subfolder_gate" in f for f in self.problems(bad)))
        bad = mutate(self.script, "'>>\"%RESULT%\" echo DECISION=%HP_VISA_DECISION%',\n", "")
        self.assertTrue(any("DECISION=%HP_VISA_DECISION%" in f for f in self.problems(bad)))

    def test_a_verdict_that_stops_handing_the_judge_what_it_needs_is_caught(self):
        bad = mutate(self.script, "-ExpectRead ([bool]$Scenario.ExpectRead))", "-ExpectRead $false)")
        self.assertTrue(any("-ExpectRead" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$pass = [bool](@($control.Problems).Count -eq 0)", "$pass = $true")
        self.assertTrue(any("row of control" in f for f in self.problems(bad)))

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
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\selfapps_visa_signals.ps1"])
        bad = self.workflow.replace("tests/~selftest_visasignals/*/~choice_args.txt", "")
        self.assertTrue(any("~choice_args" in f for f in workflow_problems(bad)))

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        self.assertTrue(registry_problems(text.replace("self.nivisa.signals.control", "self.nivisa.signals.controlx")))
        self.assertTrue(registry_problems("```\nself.nivisa.signals.noinput self.nivisa.signals.nonint\n```\nprose: self.nivisa.signals.control\n"))

    def test_a_shall_that_is_still_listed_as_a_gap_is_caught(self):
        self.assertTrue(shall_list_problems('    "REQ-008.14": "gap: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-008.140": "gap: x",\n'), [])


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

    def test_a_judge_that_forgets_a_driver_that_never_finished_is_caught(self):
        got = self.run_mutated("if (-not $Finished) {", "if ($false) {", ["signal_unfinished"])
        self.assertNotEqual(got["signal_unfinished"], ["NI-VISA question noinput: the driver did not finish within the time limit"])

    def test_a_judge_that_forgets_a_driver_that_stopped_early_is_caught(self):
        got = self.run_mutated("if ($ResultText -notmatch '(?m)^END\\s*$') {", "if ($false) {", ["signal_no_end"])
        self.assertTrue(any("the gate unknown" in f or "remembered decision" in f for f in got["signal_no_end"]), got)

    def test_a_judge_that_forgets_the_heading_is_caught(self):
        got = self.run_mutated("if ($headings -ne 1) {", "if ($false) {", ["signal_heading_twice"])
        self.assertEqual(got["signal_heading_twice"], [])

    def test_a_judge_that_forgets_a_console_read_in_spite_of_a_signal_is_caught(self):
        got = self.run_mutated("        if ($readLines.Count -gt 0) {", "        if ($false) {", ["signal_read_but_declined"])
        self.assertEqual(got["signal_read_but_declined"], [])

    def test_a_judge_that_forgets_a_signal_run_that_accepted_is_caught(self):
        got = self.run_mutated("        if ($decision -ne 'declined') {", "        if ($false) {", ["signal_accepted_without_a_read"])
        self.assertEqual(got["signal_accepted_without_a_read"], [])

    def test_a_judge_that_forgets_the_remembered_decision_of_a_signal_run_is_caught(self):
        got = self.run_mutated("        if ($ResultText -notmatch '(?m)^DECISION=N\\s*$') {", "        if ($false) {", ["signal_remembered_y"])
        self.assertEqual(got["signal_remembered_y"], [])

    def test_a_judge_that_forgets_the_decline_line_is_caught(self):
        got = self.run_mutated("        if ($declinedLines -ne 1) {", "        if ($false) {", ["signal_no_decline_line"])
        self.assertEqual(got["signal_no_decline_line"], [])

    def test_a_judge_that_forgets_an_accepted_line_in_a_signal_run_is_caught(self):
        got = self.run_mutated("        if ($acceptedLines -ne 0) {", "        if ($false) {", ["signal_accepted_line"])
        self.assertEqual(got["signal_accepted_line"], [])

    def test_a_judge_that_forgets_a_control_that_never_read_is_caught(self):
        got = self.run_mutated("        if ($readLines.Count -eq 0) {", "        if ($false) {", ["control_no_read"])
        self.assertFalse(any("never reached its choice line" in f for f in got["control_no_read"]), got)

    def test_a_judge_that_forgets_a_second_read_is_caught(self):
        got = self.run_mutated("        } elseif ($readLines.Count -ne 1) {", "        } elseif ($false) {", ["control_read_twice"])
        self.assertFalse(any("expected once" in f for f in got["control_read_twice"]), got)

    def test_a_judge_that_forgets_one_of_the_choice_arguments_is_caught(self):
        got = self.run_mutated("            if ($readLines[0] -notmatch '(?i)/T\\s+30(\\s|$)') {", "            if ($false) {", ["control_wrong_wait"])
        self.assertEqual(got["control_wrong_wait"], [])
        got = self.run_mutated("            if ($readLines[0] -notmatch '(?i)/D\\s+N(\\s|$)') {", "            if ($false) {", ["control_wrong_default"])
        self.assertEqual(got["control_wrong_default"], [])
        got = self.run_mutated("            if ($readLines[0] -notmatch '(?i)/C\\s+YN(\\s|$)') {", "            if ($false) {", ["control_wrong_keys"])
        self.assertEqual(got["control_wrong_keys"], [])

    def test_a_judge_that_forgets_that_the_control_must_accept_is_caught(self):
        got = self.run_mutated("        if ($decision -ne 'accepted') {", "        if ($false) {", ["control_declined_despite_y"])
        self.assertEqual(got["control_declined_despite_y"], [])

    def test_a_judge_that_forgets_the_remembered_decision_of_the_control_is_caught(self):
        got = self.run_mutated("        if ($ResultText -notmatch '(?m)^DECISION=Y\\s*$') {", "        if ($false) {", ["control_remembered_n"])
        self.assertEqual(got["control_remembered_n"], [])

    def test_a_decision_that_reads_a_prefix_is_caught(self):
        got = self.run_mutated("if ($ResultText -match '(?m)^NEED_VISA=1\\s*$') { return 'accepted' }", "if ($ResultText -match 'NEED_VISA=1') { return 'accepted' }", ["decision_not_a_prefix"])
        self.assertEqual(got["decision_not_a_prefix"], ["accepted"])


if __name__ == "__main__":
    unittest.main()
