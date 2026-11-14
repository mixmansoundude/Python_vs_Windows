"""Item 111 (README REQ-016.6 and REQ-016.7): the post-flight briefing of a run whose EXE could not be verified.

REQ-016.6 says the briefing shows the command that runs the program with the prepared interpreter whether or not the EXE could be
verified, and REQ-016.7 says that briefing carries a caveat (the environment was set up and packaging finished without a fatal error)
and never claims that the installation of the dependencies was verified. The briefing of a verified run is read by
self.postflight.runline.verbatim (REQ-016.5); the caveat variant was reached only by rows about other things that keep the
number-level tag. tests/selfapps_caveat_briefing.ps1 (two rows, self.caveat.runline and self.caveat.sentences; contract-uv lane,
gating) bootstraps a program that exits with 3, reads the caveat briefing from the console, runs the printed command as printed and
judges the sentences.

What really happens is shown on Windows by that script. These rules read run_setup.bat, the script, batch-check.yml,
docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, replay the real echo lines of :print_postflight_briefing for both
variants and hand the console text to the script's own judging functions through a real pwsh (so the headings, the section names and
the command line the judge looks for are the ones the batch file prints), and run those functions on synthetic runs (a run that
passes, and one run for each way to be wrong). A reworded heading or sentence, a command line that moves into the success-only part of
the panel, a log line that changes, a judge that stops judging or a step that stops gating fails here with a sentence, before a
Windows run is needed. Synthetic cases prove each rule can fail.
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
SCRIPT = REPO / "tests" / "selfapps_caveat_briefing.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

ROW_REQS = {"self.caveat.runline": "REQ-016.6", "self.caveat.sentences": "REQ-016.7"}
ROW_IDS = tuple(ROW_REQS)
GAP_SHALLS = ("REQ-016.6", "REQ-016.7")
SITES_PER_ID = 3  # the non-Windows skip, the missing batch file and the verdict

BRIEF_START = ":print_postflight_briefing"
BRIEF_END = ":pfb_dll_hint"
BRIEF_LABELS = [":print_postflight_briefing", ":pfb_caveat", ":pfb_runapp", ":pfb_runapp_noninterp", ":pfb_log_caveat"]
DISPATCH_LINE = "if defined HP_EXE_VERIFY_FAILED goto :pfb_caveat"
SUCCESS_HEADING = "echo  SETUP COMPLETE"
CAVEAT_HEADING = "echo  SETUP COMPLETE -- WITH A CAVEAT"
READY_LINE = "echo  Your standalone application is ready:"
CAVEAT_SENTENCE_LINES = [
    "echo  We packaged your app, but couldn't fully verify it runs as a",
    "echo  standalone program. Your Python environment was set up and the",
    "echo  packaging step completed without a fatal error.",
]
DIRECT_LINE = "echo    You can also run it directly via the interpreter at any time:"
COMMAND_LINE = 'echo      "%HP_PY%" "%HP_ENTRY%"'
NOPY_GUARD = "if not defined HP_PY goto :pfb_runapp_noninterp"
CLOSE_DISPATCH = "if defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat"
WARN_LOG = 'call :log "[WARN] REQ-016: Post-flight briefing printed; EXE unverified, advised direct run."'
INFO_LOG = 'call :log "[INFO] REQ-016: Post-flight briefing printed."'

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~selftest_caveat/~cv_*",
    "tests/~selftest_caveat/~setup.log",
    "tests/~selftest_caveat/~bootstrap.status.json",
)
JUDGES = ["Get-CaveatPanel", "Get-CaveatRunlineProblems", "Get-CaveatSentenceProblems", "Get-Excerpt"]


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


def squash(text):
    """Runs of spaces and tabs made one space, so a pin does not depend on the alignment of a table of rows."""
    return re.sub(r"[ \t]+", " ", text)


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


def section(body, start_label, end_label):
    """The live lines between two labels of the block (labels excluded)."""
    a = body.index(start_label)
    b = body.index(end_label)
    return body[a + 1:b]


# --- the batch file: what the script assumes about the briefing ------------------------------------------------------------------

def briefing_problems(batch):
    """README REQ-016.6 and REQ-016.7 in the batch file: the caveat variant is chosen by a failed verification, carries the three
    sentence lines, falls into the run section both variants share, which holds the command, and the log line tells the two apart."""
    found = []
    stripped = [ln.strip() for ln in lines_of(batch)]
    for label in (BRIEF_START, BRIEF_END):
        n = sum(1 for ln in stripped if ln == label)
        if n != 1:
            found.append("the label %s appears %d time(s); expected exactly once" % (label, n))
    if found:
        return found
    block = cut_block(batch, BRIEF_START, BRIEF_END)
    if block is None:
        return ["the block from %s to %s cannot be cut" % (BRIEF_START, BRIEF_END)]
    body = [ln.strip() for ln in live_bat(block)]

    labels = [ln for ln in body if ln.startswith(":")]
    if labels != BRIEF_LABELS:
        found.append("the block's labels are %r, the script's judges were written for %r" % (labels, BRIEF_LABELS))
        return found

    def only(text, what, within=None):
        pool = body if within is None else within
        hits = [i for i, ln in enumerate(pool) if ln == text]
        if len(hits) != 1:
            found.append("%s: expected exactly one live line %r, found %d" % (what, text, len(hits)))
            return None
        return hits[0]

    dispatch = only(DISPATCH_LINE, "the dispatch of the caveat variant")
    success = only(SUCCESS_HEADING, "the heading of the success variant")
    ready = only(READY_LINE, "the success wording the script looks for")
    jump = only("goto :pfb_runapp", "the jump that keeps the success variant out of the caveat")
    caveat_label = body.index(":pfb_caveat")
    runapp_label = body.index(":pfb_runapp")
    nopy_label = body.index(":pfb_runapp_noninterp")
    logcaveat_label = body.index(":pfb_log_caveat")
    if None not in (dispatch, success, ready, jump):
        if not (dispatch < success < ready < jump < caveat_label):
            found.append("the dispatch, the success heading, its ready line and the jump over the caveat must come in this order before :pfb_caveat")

    caveat = section(body, ":pfb_caveat", ":pfb_runapp")
    if caveat[:1] != [CAVEAT_HEADING]:
        found.append("the first live line of the caveat section is no longer %r" % CAVEAT_HEADING)
    sentence_at = [caveat.index(s) if s in caveat else None for s in CAVEAT_SENTENCE_LINES]
    if None in sentence_at or sentence_at != sorted(sentence_at):
        found.append("the caveat section no longer holds the three sentence lines of REQ-016.7, in order: %r" % (CAVEAT_SENTENCE_LINES,))
    if READY_LINE in caveat or SUCCESS_HEADING in caveat:
        found.append("the caveat section carries the success wording, so a run could print both")
    for ln in caveat:
        if re.match(r"(?i)echo\b", ln) and ln not in CAVEAT_SENTENCE_LINES and ln != CAVEAT_HEADING and not re.match(r"echo\s+=+$", ln):
            found.append("the caveat section prints a line the script's sentence judge has not seen: %r" % ln)

    shared = section(body, ":pfb_runapp", ":pfb_runapp_noninterp")
    direct = only(DIRECT_LINE, "the line that introduces the command", shared)
    command = only(COMMAND_LINE, "the command that runs the program with the prepared interpreter", shared)
    guard = only(NOPY_GUARD, "the guard for a missing interpreter", shared)
    if None not in (direct, command, guard) and not (guard < direct < command):
        found.append("the guard for a missing interpreter, the introducing line and the command must come in this order in the section both variants reach")
    if COMMAND_LINE in body[:caveat_label] or COMMAND_LINE in caveat:
        found.append("the command also appears before the section both variants reach")
    if "RUNNING YOUR APP" not in " ".join(shared) or not any(ln.startswith("echo") and "RUNNING YOUR APP" in ln for ln in shared):
        found.append("the section both variants reach no longer carries the RUNNING YOUR APP heading the script reads the caveat up to")

    tail = body[nopy_label + 1:]
    safe = [i for i, ln in enumerate(tail) if "SAFE TO DELETE" in ln]
    if len(safe) != 1:
        found.append("the section both variants reach must hold exactly one SAFE TO DELETE line, found %d" % len(safe))
    else:
        rules = [i for i, ln in enumerate(tail) if re.match(r"echo\s+=+$", ln) and i > safe[0]]
        if not rules:
            found.append("no closing rule follows SAFE TO DELETE, so the script cannot tell where the panel ends")

    after = body[nopy_label + 1:logcaveat_label]
    if CLOSE_DISPATCH not in after:
        found.append("the closing dispatch to the log line of the caveat variant is missing: %r" % CLOSE_DISPATCH)
    elif after.index(CLOSE_DISPATCH) + 1 >= len(after) or after[after.index(CLOSE_DISPATCH) + 1] != INFO_LOG:
        found.append("the success log line must directly follow the closing dispatch")
    if after.count(INFO_LOG) != 1:
        found.append("the success log line %r must appear exactly once" % INFO_LOG)
    logtail = body[logcaveat_label + 1:]
    if logtail[:2] != [WARN_LOG, "exit /b 0"]:
        found.append("the caveat variant's log section no longer is the WARN line of the log contract followed by exit /b 0")

    calls = sorted(set(re.findall(r"(?i)\bcall\s+(:[A-Za-z_][A-Za-z0-9_]*)", "\n".join(body))))
    if calls != [":log", ":pfb_dll_hint", ":pfb_gui_hint"]:
        found.append("the block calls %r; the simulation in tests/test_caveat_briefing.py knows :log and the two hint subroutines" % (calls,))
    return found


# --- the script ------------------------------------------------------------------------------------------------------------------

def script_problems(text):
    t = norm(text)
    live = live_hash(t)
    flat = squash("\n".join(live))
    found = []
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if sorted(ids) != sorted(list(ROW_IDS) * SITES_PER_ID):
        found.append("each row id must be a literal at exactly %d Write-NdjsonRow call sites, found %r" % (SITES_PER_ID, ids))
    pairs = re.findall(r"\bid\s*=\s*'(self\.caveat\.[a-z]+)'\s*;?\s*req\s*=\s*'([^']*)'", t)
    if sorted(p[0] for p in pairs) != sorted(list(ROW_IDS) * SITES_PER_ID):
        found.append("every row id must be followed by its literal req tag, found %r" % pairs)
    for row, req in pairs:
        if ROW_REQS.get(row) != req:
            found.append("the row %s must carry the literal req tag %r, found %r" % (row, ROW_REQS.get(row), req))
    if "$marker = 'CAVEAT_APP_RAN'" not in flat or "$wantExit = 3" not in flat:
        found.append("the program no longer prints CAVEAT_APP_RAN and exits with 3 (the run must fail the verification)")
    if "$program = \"import sys`nprint('$marker', flush=True)`nsys.exit($wantExit)`n\"" not in flat:
        found.append("the program is no longer one line printed and sys.exit with the exit code")
    for name in ("HP_SKIP_PIPREQS", "HP_SKIP_AUTOPEP_DISCOVERY", "HP_SKIP_NIVISA"):
        if "%s = '1'" % name not in flat:
            found.append("the run no longer sets %s to 1 (nothing to scan or install for a standard library program)" % name)
    for name in ("HP_SKIP_ENTRY_SMOKE", "HP_SKIP_EXE_SMOKERUN", "HP_TEST_FORCE_EMIT_FAIL", "HP_TEST_REPAIR_ANSWER", "HP_TEST_LASTCHANCE_ANSWER",
                 "HP_TEST_CHECKPOINT_ANSWER", "HP_TEST_RTM_ANSWER", "HP_PVW_KNOWN_IDEMPOTENT", "PVW_BUILDER", "PVW_PROVIDER"):
        if "%s = ''" % name not in flat:
            found.append("the run no longer clears %s, so the runner's setting could decide the result" % name)
    if "HP_CI_LANE'] = 'test'" not in flat:
        found.append("a run without the CI marker no longer gets one")
    if "call run_setup.bat app.py > $logName 2>&1 < nul" not in flat:
        found.append("the bootstrap no longer runs with standard input closed (< nul) and its console in a file")
    if "$runTimeoutMs = 15 * 60 * 1000" not in flat or flat.count("taskkill.exe /F /T /PID $p.Id") != 2:
        found.append("the bootstrap and the replay are no longer both stopped with taskkill /F /T after a time limit (15 minutes and 120 seconds)")
    if "$p.WaitForExit(120000)" not in flat:
        found.append("the replay of the printed command has no 120 second limit")
    if flat.count("-WorkingDirectory $Dir") != 2:
        found.append("the bootstrap and the replay must both start in the program folder (-WorkingDirectory $Dir)")
    if "Set-Content -LiteralPath $cmdPath -Value @('@echo off', $Line, 'echo PVW_RC=%errorlevel%') -Encoding ASCII" not in flat:
        found.append("the printed command is no longer written as printed to a .cmd file whose last line prints its errorlevel")
    if "'call ~cv_runline.cmd'" not in flat:
        found.append("the replay no longer runs the .cmd file")
    if "(?m)^PVW_RC=(-?\\d+)\\s*$" not in flat:
        found.append("the exit code of the replay is no longer read from the PVW_RC line")
    if "$panel = Get-CaveatPanel $run.Console" not in flat:
        found.append("the panel is no longer read from the console of the bootstrap")
    if "Invoke-Replay -Dir $dir -Line $panel.Printed" not in flat:
        found.append("the replay no longer runs the command the briefing printed")
    if ("$runlineProblems = @(Get-CaveatRunlineProblems -Run $run -Panel $panel -ExeExists $exeExists -Replay $replay "
            "-Marker $marker -WantExit $wantExit)") not in flat:
        found.append("the verdict of REQ-016.6 no longer comes from Get-CaveatRunlineProblems with all its arguments")
    if "$sentenceProblems = @(Get-CaveatSentenceProblems -Panel $panel -Setup $run.Setup)" not in flat:
        found.append("the verdict of REQ-016.7 no longer comes from Get-CaveatSentenceProblems")
    if "$runlinePass = ($runlineProblems.Count -eq 0)" not in flat or "$sentencePass = ($sentenceProblems.Count -eq 0)" not in flat:
        found.append("a row is no longer judged by its list of problems")
    if "pass = $runlinePass" not in flat or "pass = $sentencePass" not in flat:
        found.append("the two rows no longer write pass from their own verdict")
    for name in JUDGES:
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the judging function %s is missing" % name)
    if "OSVersion.Platform -ne [System.PlatformID]::Win32NT" not in flat or re.search(r"\$IsWindows\b", flat):
        found.append("the Windows check must use OSVersion.Platform and not $IsWindows")
    if "skip = $true" not in flat:
        found.append("the rows no longer skip off Windows with skip = $true")
    if "if ($anyRed) { exit 1 }" not in flat:
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
        if "selfapps_caveat_briefing.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_caveat_briefing.ps1"]
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
    """The shalls the rows trace are no longer listed as gaps (the shall-level ratchet only warns about a stale entry)."""
    return ["%s is still listed in UNTRACED_SHALLS although a row is tagged with it" % shall
            for shall in GAP_SHALLS if re.search(r'^\s*"%s":' % re.escape(shall), text, re.M)]


# --- the real echo lines of the briefing, replayed -----------------------------------------------------------------------------

def simulate(batch, defined, envname="_selftest_caveat", hp_py=r"C:\Work\_selftest_caveat\.uv_env\Scripts\python.exe",
             hp_entry=r"C:\Work\_selftest_caveat\app.py"):
    """What :print_postflight_briefing prints and logs when exactly the named variables are defined. It follows the labels, the
    `if [not] defined X (goto|call|echo)` lines, `goto`, `call :log`, `exit /b` and `echo`; the two hint subroutines are not entered."""
    block = cut_block(batch, BRIEF_START, BRIEF_END)
    live = [ln.rstrip("\r") for ln in block if ln.strip() and not is_bat_comment(ln)]
    index = {ln.strip(): i for i, ln in enumerate(live) if ln.startswith(":")}
    subs = {"ENVNAME": envname, "HP_PY": hp_py, "HP_ENTRY": hp_entry}
    printed, logged = [], []
    i, steps = 1, 0
    while i < len(live):
        steps += 1
        assert steps < 2000, "the simulation of :print_postflight_briefing does not end"
        ln = live[i].rstrip()
        i += 1
        if ln.startswith(":"):
            continue
        m = re.match(r"(?i)if\s+(not\s+)?defined\s+(\S+)\s+(.*)$", ln)
        if m:
            negated, var, rest = bool(m.group(1)), m.group(2), m.group(3)
            if (var in defined) == negated:
                continue
            ln = rest
        g = re.match(r"(?i)goto\s+(:\S+)$", ln)
        if g:
            i = index[g.group(1)] + 1
            continue
        lg = re.match(r'(?i)call\s+:log\s+"(.*)"$', ln)
        if lg:
            logged.append(lg.group(1))
            continue
        if re.match(r"(?i)call\s+:", ln):
            continue
        if re.match(r"(?i)exit\s+/b", ln):
            break
        if re.match(r"(?i)echo\.$", ln):
            printed.append("")
            continue
        e = re.match(r"(?i)echo\s", ln)
        assert e, "the simulation does not know the line %r" % ln
        text = ln[5:]
        for name in re.findall(r"%([A-Za-z_][A-Za-z0-9_]*)%", text):
            assert name in subs, "the simulation does not know the variable %%%s%% of the line %r" % (name, ln)
        text = re.sub(r"%([A-Za-z_][A-Za-z0-9_]*)%", lambda mm: subs[mm.group(1)], text)
        printed.append(text)
    return printed, logged


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
    foreach ($__p in $__c.args.PSObject.Properties) {
        $__v = $__p.Value
        # an argument given as {"__fn": name, "args": {...}} is the result of another judging function (the panel of a real console)
        if (($__v -is [System.Management.Automation.PSCustomObject]) -and ($null -ne $__v.PSObject.Properties['__fn'])) {
            $__inner = @{}
            foreach ($__q in $__v.args.PSObject.Properties) { $__inner[$__q.Name] = $__q.Value }
            $__v = & $__v.__fn @__inner
        }
        $__h[$__p.Name] = $__v
    }
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


def chain(fn, **args):
    return {"__fn": fn, "args": args}


MARKER = "CAVEAT_APP_RAN"
PRINTED = r'"C:\W\.uv_env\Scripts\python.exe" "C:\W\app.py"'
GOOD_SENTENCE = "Your Python environment was set up and the packaging step completed without a fatal error."
GOOD_CAVEAT = "We packaged your app, but couldn't fully verify it runs as a standalone program. " + GOOD_SENTENCE
WARN_TEXT = "[WARN] REQ-016: Post-flight briefing printed; EXE unverified, advised direct run."
INFO_TEXT = "[INFO] REQ-016: Post-flight briefing printed."
SETUP = "Sat 11/14/2026  0:41:02.12 " + WARN_TEXT + "\r\n"
RULE = "=" * 60

CAVEAT_LINES = [
    "[INFO] Entry smoke exit=3",
    "",
    RULE,
    " SETUP COMPLETE -- WITH A CAVEAT",
    RULE,
    " We packaged your app, but couldn't fully verify it runs as a",
    " standalone program. Your Python environment was set up and the",
    " packaging step completed without a fatal error.",
    "",
    " RUNNING YOUR APP",
    "   Double-click dist\\app.exe to run it.",
    "   You can also run it directly via the interpreter at any time:",
    "     " + PRINTED,
    "     Running that interpreter with no script opens an interactive Python prompt.",
    "     To run pip, use the interpreter's -m option, for example:",
    r'       "C:\W\.uv_env\Scripts\python.exe" -m pip list',
    "",
    "   STARTUP MAY BE SLOW: a one-file .exe unpacks itself each time it",
    "",
    " KEEP these files with your project:",
    "   requirements.txt  -- packages your app depends on",
    "   runtime.txt       -- Python version pin",
    "",
    " SAFE TO DELETE to reclaim disk space:",
    "   .*_env\\ folders   -- environment directories",
    "   ~* files          -- tilde-prefix work files (e.g. ~setup.log)",
    "   build\\            -- PyInstaller build cache",
    RULE,
    "",
]
SUCCESS_LINES = [
    "",
    RULE,
    " SETUP COMPLETE",
    RULE,
    " Your standalone application is ready:",
    "   dist\\app.exe",
    "",
    " RUNNING YOUR APP",
    "   You can also run it directly via the interpreter at any time:",
    "     " + PRINTED,
    "",
    " SAFE TO DELETE to reclaim disk space:",
    RULE,
    "",
]


def crlf(lines):
    return "\r\n".join(lines)


def run_obj(**over):
    run = {"Finished": True, "Exit": 0, "State": "ok"}
    run.update(over)
    return run


def panel_obj(**over):
    p = {"Found": True, "Ready": False, "Lines": [], "Caveat": GOOD_CAVEAT, "Printed": PRINTED}
    p.update(over)
    return p


def replay_obj(**over):
    r = {"Finished": True, "Exit": 3, "Output": MARKER + "\r\nPVW_RC=3\r\n"}
    r.update(over)
    return r


def runline_args(**over):
    args = dict(Run=run_obj(), Panel=panel_obj(), ExeExists=True, Replay=replay_obj(), Marker=MARKER, WantExit=3)
    args.update(over)
    return args


def sentence_args(**over):
    args = dict(Panel=panel_obj(), Setup=SETUP)
    args.update(over)
    return args


def judge_cases():
    c = []
    # --- Get-CaveatPanel
    c.append(case("panel_caveat", "Get-CaveatPanel", Console=crlf(CAVEAT_LINES)))
    c.append(case("panel_success", "Get-CaveatPanel", Console=crlf(SUCCESS_LINES)))
    c.append(case("panel_none", "Get-CaveatPanel", Console="[INFO] nothing here\r\n"))
    no_command = [ln for ln in CAVEAT_LINES if ln != "     " + PRINTED and "directly via the interpreter" not in ln]
    c.append(case("panel_without_the_command", "Get-CaveatPanel", Console=crlf(no_command)))
    pip_first = [ln for ln in CAVEAT_LINES if ln != "     " + PRINTED]
    c.append(case("panel_pip_line_only", "Get-CaveatPanel", Console=crlf(pip_first)))
    # a line that starts with a double quote ABOVE the introducing line: the command is the first such line BELOW it, so a reader that
    # takes the first quoted line anywhere in the panel returns this one instead
    early = list(CAVEAT_LINES)
    early.insert(early.index("   You can also run it directly via the interpreter at any time:"), '   "an earlier line that starts with a quote"')
    c.append(case("panel_quoted_line_before_the_intro", "Get-CaveatPanel", Console=crlf(early)))
    cut = CAVEAT_LINES[:CAVEAT_LINES.index(" SAFE TO DELETE to reclaim disk space:")]
    c.append(case("panel_cut_before_safe_to_delete", "Get-CaveatPanel", Console=crlf(cut)))
    c.append(case("panel_lf_only", "Get-CaveatPanel", Console="\n".join(CAVEAT_LINES)))
    # --- Get-CaveatRunlineProblems
    c.append(case("run_good", "Get-CaveatRunlineProblems", **runline_args()))
    c.append(case("run_unfinished", "Get-CaveatRunlineProblems", **runline_args(Run=run_obj(Finished=False))))
    c.append(case("run_no_caveat", "Get-CaveatRunlineProblems", **runline_args(Panel=panel_obj(Found=False, Printed=""))))
    c.append(case("run_success_wording_too", "Get-CaveatRunlineProblems", **runline_args(Panel=panel_obj(Ready=True))))
    c.append(case("run_no_command", "Get-CaveatRunlineProblems", **runline_args(Panel=panel_obj(Printed=""))))
    c.append(case("run_command_one_path", "Get-CaveatRunlineProblems", **runline_args(Panel=panel_obj(Printed=r'"C:\W\.uv_env\Scripts\python.exe"'))))
    c.append(case("run_command_unquoted_script", "Get-CaveatRunlineProblems",
                  **runline_args(Panel=panel_obj(Printed=r'"C:\W\.uv_env\Scripts\python.exe" app.py'))))
    c.append(case("run_command_with_arguments", "Get-CaveatRunlineProblems",
                  **runline_args(Panel=panel_obj(Printed=r'"C:\W\.uv_env\Scripts\python.exe" "C:\W\app.py" --x'))))
    c.append(case("run_no_interpreter", "Get-CaveatRunlineProblems", **runline_args(ExeExists=False)))
    c.append(case("run_replay_unfinished", "Get-CaveatRunlineProblems", **runline_args(Replay=replay_obj(Finished=False, Exit=-1, Output=""))))
    c.append(case("run_replay_wrong_exit", "Get-CaveatRunlineProblems", **runline_args(Replay=replay_obj(Exit=0))))
    c.append(case("run_replay_no_marker", "Get-CaveatRunlineProblems", **runline_args(Replay=replay_obj(Output="PVW_RC=3\r\n"))))
    c.append(case("run_replay_both_wrong", "Get-CaveatRunlineProblems", **runline_args(Replay=replay_obj(Exit=1, Output="error\r\n"))))
    # --- Get-CaveatSentenceProblems
    c.append(case("sent_good", "Get-CaveatSentenceProblems", **sentence_args()))
    c.append(case("sent_no_panel", "Get-CaveatSentenceProblems", **sentence_args(Panel=panel_obj(Found=False, Caveat=""))))
    c.append(case("sent_sentence_missing", "Get-CaveatSentenceProblems",
                  **sentence_args(Panel=panel_obj(Caveat="We packaged your app, but couldn't fully verify it runs as a standalone program."))))
    c.append(case("sent_sentence_reworded", "Get-CaveatSentenceProblems",
                  **sentence_args(Panel=panel_obj(Caveat=GOOD_CAVEAT.replace("without a fatal error", "with no problems")))))
    c.append(case("sent_claims_dependencies_verified", "Get-CaveatSentenceProblems",
                  **sentence_args(Panel=panel_obj(Caveat=GOOD_CAVEAT + " Your dependencies were installed and verified."))))
    c.append(case("sent_claims_installation_checked", "Get-CaveatSentenceProblems",
                  **sentence_args(Panel=panel_obj(Caveat=GOOD_CAVEAT + " The installation of your packages was checked."))))
    c.append(case("sent_claims_confirmed", "Get-CaveatSentenceProblems",
                  **sentence_args(Panel=panel_obj(Caveat=GOOD_CAVEAT + " All dependencies are confirmed."))))
    c.append(case("sent_negated_claim_is_fine", "Get-CaveatSentenceProblems",
                  **sentence_args(Panel=panel_obj(Caveat=GOOD_CAVEAT + " We could not verify the installation of your dependencies."))))
    c.append(case("sent_no_warn_line", "Get-CaveatSentenceProblems", **sentence_args(Setup="[INFO] something else\r\n")))
    c.append(case("sent_info_line_too", "Get-CaveatSentenceProblems", **sentence_args(Setup=SETUP + "x " + INFO_TEXT + "\r\n")))
    c.append(case("sent_info_line_only", "Get-CaveatSentenceProblems", **sentence_args(Setup="x " + INFO_TEXT + "\r\n")))
    # --- Get-Excerpt
    c.append(case("excerpt_last_lines", "Get-Excerpt", Text="a\r\nb\r\nc\r\nd\r\n", Lines=2))
    c.append(case("excerpt_non_ascii", "Get-Excerpt", Text="caf\u00e9 ok\r\n", Lines=5))
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

    def test_the_panel_of_a_caveat_console_is_found_with_its_command_and_sentences(self):
        panel = self.r["panel_caveat"][0]
        self.assertTrue(panel["Found"])
        self.assertFalse(panel["Ready"])
        self.assertEqual(panel["Printed"], PRINTED)
        self.assertEqual(panel["Caveat"], GOOD_CAVEAT)
        self.assertIn("SETUP COMPLETE -- WITH A CAVEAT", panel["Lines"][0])
        self.assertRegex(panel["Lines"][-1], r"^=+$")
        self.assertTrue(any("SAFE TO DELETE" in ln for ln in panel["Lines"]))
        self.assertFalse(any("[INFO] Entry smoke" in ln for ln in panel["Lines"]), "lines before the heading are not part of the panel")

    def test_a_console_of_the_success_variant_has_no_caveat_panel_and_says_so(self):
        panel = self.r["panel_success"][0]
        self.assertFalse(panel["Found"])
        self.assertTrue(panel["Ready"])
        self.assertEqual(panel["Printed"], "")

    def test_a_console_without_any_briefing_has_no_panel_and_is_not_ready(self):
        panel = self.r["panel_none"][0]
        self.assertFalse(panel["Found"])
        self.assertFalse(panel["Ready"])

    def test_the_command_is_the_first_quoted_line_after_the_introducing_line_and_nothing_else(self):
        self.assertEqual(self.r["panel_without_the_command"][0]["Printed"], "")
        self.assertEqual(self.r["panel_pip_line_only"][0]["Printed"], r'"C:\W\.uv_env\Scripts\python.exe" -m pip list',
                         "the first quoted line under the introducing line is the one the script replays, so the pip example is only taken when the command is gone")

    def test_a_quoted_line_above_the_introducing_line_is_not_the_command(self):
        self.assertEqual(self.r["panel_quoted_line_before_the_intro"][0]["Printed"], PRINTED)

    def test_a_panel_without_a_safe_to_delete_line_runs_to_the_end_and_a_console_with_only_lf_is_read(self):
        cut = self.r["panel_cut_before_safe_to_delete"][0]
        self.assertTrue(cut["Found"])
        self.assertEqual(cut["Printed"], PRINTED)
        lf = self.r["panel_lf_only"][0]
        self.assertTrue(lf["Found"])
        self.assertEqual(lf["Printed"], PRINTED)

    def test_a_good_caveat_run_has_no_problem(self):
        self.assertEqual(self.r["run_good"], [])
        self.assertEqual(self.r["sent_good"], [])

    def test_a_bootstrap_that_did_not_finish_or_never_printed_a_caveat_is_one_problem_and_nothing_else(self):
        self.only("run_unfinished", "the bootstrap did not finish within the time limit")
        self.only("run_no_caveat", "no caveat briefing was printed")
        self.only("sent_no_panel", "no caveat briefing was printed")

    def test_the_success_wording_next_to_the_caveat_is_named(self):
        self.only("run_success_wording_too", "carries the success wording of the briefing")

    def test_a_briefing_without_the_command_is_one_problem(self):
        self.only("run_no_command", "does not show the command that runs the program with the prepared interpreter")

    def test_a_command_that_is_not_two_quoted_paths_is_named(self):
        self.only("run_command_one_path", "is not an interpreter path and a script path, each in double quotes")
        self.only("run_command_unquoted_script", "is not an interpreter path and a script path, each in double quotes")
        self.only("run_command_with_arguments", "is not an interpreter path and a script path, each in double quotes")

    def test_an_interpreter_that_does_not_exist_is_named(self):
        self.only("run_no_interpreter", "the interpreter named by the printed command does not exist on disk")

    def test_a_replay_that_hung_ended_with_another_exit_code_or_lost_the_program_line_is_named(self):
        self.only("run_replay_unfinished", "run as printed, did not finish within the time limit")
        self.only("run_replay_wrong_exit", "ended with exit code 0; the program exits with 3")
        self.only("run_replay_no_marker", "did not print the program's own line (CAVEAT_APP_RAN)")
        both = self.r["run_replay_both_wrong"]
        self.assertEqual(len(both), 2, both)

    def test_a_caveat_without_the_required_sentence_is_named(self):
        self.only("sent_sentence_missing", "does not say that the environment was set up and that the packaging step completed without a fatal error")
        self.only("sent_sentence_reworded", "does not say that the environment was set up and that the packaging step completed without a fatal error")

    def test_a_sentence_that_claims_the_dependencies_or_their_installation_were_verified_is_named(self):
        self.only("sent_claims_dependencies_verified", "claims that the dependencies or their installation were verified")
        self.only("sent_claims_installation_checked", "claims that the dependencies or their installation were verified")
        self.only("sent_claims_confirmed", "claims that the dependencies or their installation were verified")

    def test_a_negated_sentence_about_the_installation_is_not_a_claim(self):
        self.assertEqual(self.r["sent_negated_claim_is_fine"], [])

    def test_a_setup_log_without_the_warn_line_or_with_the_success_line_is_named(self):
        self.only("sent_no_warn_line", "does not carry the WARN line of the log contract")
        self.only("sent_info_line_too", "carries the success line of the log contract")
        both = self.r["sent_info_line_only"]
        self.assertEqual(len(both), 2, both)

    def test_the_excerpt_keeps_the_last_lines_and_turns_everything_but_ascii_into_a_question_mark(self):
        self.assertEqual(self.r["excerpt_last_lines"], ["d", ""])
        self.assertEqual(self.r["excerpt_non_ascii"][0], "caf? ok")


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
        for name in ("cases", "c", "h", "p", "v", "q", "inner", "want", "all", "ast", "defs", "tokens", "errs", "r", "f"):
            with self.subTest(name=name):
                with self.assertRaises(AssertionError):
                    self.run_probe("    return $%s" % name, {"Value": 1})

    def test_an_argument_can_be_the_result_of_another_function(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "judge.ps1"
            script.write_text("function Get-Make {\n    param([int]$N)\n    return [pscustomobject]@{ Twice = $N * 2 }\n}\n"
                              "function Get-Use {\n    param($Made)\n    return $Made.Twice\n}\n", encoding="ascii")
            got = run_cases(script, ["Get-Make", "Get-Use"], [case("use", "Get-Use", Made=chain("Get-Make", N=21))], d)
        self.assertEqual(got["use"], [42])


# --- the real briefing through the judges --------------------------------------------------------------------------------------

class RealBriefingThroughTheJudges(unittest.TestCase):
    """The real echo lines of :print_postflight_briefing, replayed for the caveat and the success variant, are handed to the script's
    own functions: the headings, section names and the command line the judge looks for are the ones the batch file prints."""

    @classmethod
    def setUpClass(cls):
        cls.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        cls.caveat, cls.caveat_log = simulate(cls.batch, {"HP_EXE_VERIFY_FAILED", "HP_PY"})
        cls.success, cls.success_log = simulate(cls.batch, {"HP_PY"})
        cls.nopy, cls.nopy_log = simulate(cls.batch, {"HP_EXE_VERIFY_FAILED"})
        caveat_console = crlf(["[INFO] Entry smoke exit=3", ""] + cls.caveat + [""])
        setup = "Sat 11/14/2026  0:41:02.12 " + "".join(cls.caveat_log) + "\r\n"
        cls.printed = '"C:\\Work\\_selftest_caveat\\.uv_env\\Scripts\\python.exe" "C:\\Work\\_selftest_caveat\\app.py"'
        panel = chain("Get-CaveatPanel", Console=caveat_console)
        cases = [
            case("caveat_panel", "Get-CaveatPanel", Console=caveat_console),
            case("success_panel", "Get-CaveatPanel", Console=crlf(["", ""] + cls.success + [""])),
            case("nopy_panel", "Get-CaveatPanel", Console=crlf(cls.nopy)),
            case("sentences", "Get-CaveatSentenceProblems", Panel=panel, Setup=setup),
            case("runline", "Get-CaveatRunlineProblems", Run=run_obj(), Panel=panel, ExeExists=True, Replay=replay_obj(), Marker=MARKER, WantExit=3),
            case("runline_without_interpreter", "Get-CaveatRunlineProblems", Run=run_obj(),
                 Panel=chain("Get-CaveatPanel", Console=crlf(cls.nopy)), ExeExists=True, Replay=replay_obj(), Marker=MARKER, WantExit=3),
            case("sentences_success_log", "Get-CaveatSentenceProblems", Panel=panel,
                 Setup="Sat 11/14/2026  0:41:02.12 " + "".join(cls.success_log) + "\r\n"),
        ]
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, JUDGES, cases, d)

    def test_the_replay_follows_the_real_dispatch_and_prints_the_two_variants(self):
        self.assertTrue(any("SETUP COMPLETE -- WITH A CAVEAT" in ln for ln in self.caveat))
        self.assertFalse(any("Your standalone application is ready" in ln for ln in self.caveat))
        self.assertTrue(any("Your standalone application is ready" in ln for ln in self.success))
        self.assertFalse(any("WITH A CAVEAT" in ln for ln in self.success))
        self.assertEqual(self.caveat_log, ["[WARN] REQ-016: Post-flight briefing printed; EXE unverified, advised direct run."])
        self.assertEqual(self.success_log, ["[INFO] REQ-016: Post-flight briefing printed."])
        self.assertGreater(len(self.caveat), 25)

    def test_the_real_caveat_panel_is_found_with_its_command_sentences_and_closing_rule(self):
        panel = self.r["caveat_panel"][0]
        self.assertTrue(panel["Found"])
        self.assertFalse(panel["Ready"])
        self.assertEqual(panel["Printed"], self.printed)
        self.assertIn(GOOD_SENTENCE, panel["Caveat"])
        self.assertRegex(panel["Lines"][-1], r"^=+$")
        self.assertTrue(any("SAFE TO DELETE" in ln for ln in panel["Lines"]))
        self.assertGreater(len(panel["Lines"]), 25)

    def test_the_real_success_variant_is_not_taken_for_a_caveat(self):
        panel = self.r["success_panel"][0]
        self.assertFalse(panel["Found"])
        self.assertTrue(panel["Ready"])

    def test_without_an_interpreter_the_real_caveat_shows_no_command_and_the_judge_says_so(self):
        panel = self.r["nopy_panel"][0]
        self.assertTrue(panel["Found"])
        self.assertEqual(panel["Printed"], "")
        found = self.r["runline_without_interpreter"]
        self.assertEqual(len(found), 1, found)
        self.assertIn("does not show the command", found[0])

    def test_the_judges_accept_the_real_caveat_briefing_and_its_log_line(self):
        self.assertEqual(self.r["runline"], [])
        self.assertEqual(self.r["sentences"], [])

    def test_the_judge_notices_the_success_log_line_of_the_other_variant(self):
        found = self.r["sentences_success_log"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(any("does not carry the WARN line" in f for f in found), found)
        self.assertTrue(any("carries the success line" in f for f in found), found)


# --- the rules on the real files ---------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_briefing_has_the_shape_the_script_judges(self):
        self.assertEqual(briefing_problems(self.batch), [])

    def test_the_script_has_its_rows_program_driver_judges_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shalls_are_no_longer_listed_as_gaps(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        block = cut_block(self.batch, BRIEF_START, BRIEF_END)
        self.assertGreater(len(live_bat(block)), 40)
        self.assertEqual(len(judge_cases()), 34)

    def test_every_judge_the_driver_is_asked_for_is_a_function_of_the_script(self):
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))

    def test_the_log_lines_of_the_contract_are_live_log_calls(self):
        live = [ln.strip() for ln in live_bat(lines_of(self.batch))]
        self.assertEqual(live.count(WARN_LOG), 1)
        self.assertEqual(live.count(INFO_LOG), 1)

    def test_the_briefing_is_printed_when_the_exe_exists_and_the_cached_exe_was_not_reused(self):
        text = norm(self.batch)
        self.assertIn('if not defined HP_FASTPATH_USED (\n  if exist "dist\\%ENVNAME%.exe" (\n    call :print_postflight_briefing\n', text)


def mutate(text, old, new):
    # exactly once: with two matches the case would edit the first one, which may be another block of the file, and the pin under
    # test would never see the change
    assert text.count(old) == 1, "the synthetic case needs the text to hold %r exactly once, found %d" % (old[:60], text.count(old))
    return text.replace(old, new, 1)


class BatchRulesCanFail(unittest.TestCase):
    """Each rule about run_setup.bat is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")

    def problems(self, batch):
        return briefing_problems(batch)

    def test_a_label_that_is_missing_or_duplicated_is_reported(self):
        gone = mutate(self.batch, "\n:print_postflight_briefing\n", "\n:print_postflight_briefingx\n")
        self.assertTrue(any("appears 0 time(s)" in f for f in self.problems(gone)))
        twice = self.batch + "\n:pfb_dll_hint\n"
        self.assertTrue(any("appears 2 time(s)" in f for f in self.problems(twice)))
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))

    def test_a_new_label_in_the_block_is_reported(self):
        bad = mutate(self.batch, "\n:pfb_runapp_noninterp\n", "\n:pfb_runapp_noninterp\n:pfb_extra\n")
        self.assertTrue(any("the block's labels are" in f for f in self.problems(bad)))

    def test_a_dispatch_that_no_longer_follows_a_failed_verification_is_reported(self):
        bad = mutate(self.batch, "if defined HP_EXE_VERIFY_FAILED goto :pfb_caveat\n", "if defined HP_EXE_FAILED goto :pfb_caveat\n")
        self.assertTrue(any("the dispatch of the caveat variant" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_reworded_heading_is_reported(self):
        bad = mutate(self.batch, "echo  SETUP COMPLETE -- WITH A CAVEAT\n", "echo  SETUP COMPLETE - WITH A CAVEAT\n")
        self.assertTrue(any("the first live line of the caveat section" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "echo  Your standalone application is ready:\n", "echo  Your standalone application is complete:\n")
        self.assertTrue(any("the success wording the script looks for" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_caveat_sentence_that_changes_or_a_new_line_in_the_caveat_is_reported(self):
        bad = mutate(self.batch, "echo  packaging step completed without a fatal error.\n", "echo  packaging step completed without any error.\n")
        self.assertTrue(any("three sentence lines of REQ-016.7" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "echo  packaging step completed without a fatal error.\n",
                     "echo  packaging step completed without a fatal error.\necho  Your dependencies were installed and verified.\n")
        self.assertTrue(any("has not seen" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_missing_jump_over_the_caveat_is_reported(self):
        bad = mutate(self.batch, "goto :pfb_runapp\n:pfb_caveat\n", ":pfb_caveat\n")
        found = self.problems(bad)
        self.assertTrue(any("the jump that keeps the success variant out of the caveat" in f for f in found), found)

    def test_a_command_that_moves_into_the_caveat_or_disappears_is_reported(self):
        bad = mutate(self.batch, 'echo      "%HP_PY%" "%HP_ENTRY%"\n', "")
        self.assertTrue(any("the command that runs the program" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'echo      "%HP_PY%" "%HP_ENTRY%"\n', 'echo      "%HP_PY%" "%HP_ENTRY%"\necho      "%HP_PY%" "%HP_ENTRY%"\n')
        self.assertTrue(any("the command that runs the program" in f for f in self.problems(bad)), self.problems(bad))
        moved = mutate(self.batch, 'echo      "%HP_PY%" "%HP_ENTRY%"\n', "")
        moved = mutate(moved, "echo  packaging step completed without a fatal error.\n",
                       'echo  packaging step completed without a fatal error.\necho      "%HP_PY%" "%HP_ENTRY%"\n')
        found = self.problems(moved)
        self.assertTrue(any("has not seen" in f or "the command that runs the program" in f for f in found), found)

    def test_a_missing_introducing_line_or_guard_is_reported(self):
        bad = mutate(self.batch, "echo    You can also run it directly via the interpreter at any time:\n", "")
        self.assertTrue(any("the line that introduces the command" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "if not defined HP_PY goto :pfb_runapp_noninterp\n", "")
        self.assertTrue(any("the guard for a missing interpreter" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_panel_without_a_closing_rule_or_without_safe_to_delete_is_reported(self):
        bad = mutate(self.batch, "echo    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n",
                     "echo    build\\            -- PyInstaller build cache\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n")
        self.assertTrue(any("no closing rule follows SAFE TO DELETE" in f for f in self.problems(bad)), self.problems(bad))
        # the same heading line is also in :print_no_exe_briefing, so the anchor runs on into the lines only the caveat panel has
        tail = "echo    ~* files          -- tilde-prefix work files (e.g. ~setup.log)\necho    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n"
        bad = mutate(self.batch, "echo  SAFE TO DELETE to reclaim disk space:\necho    .*_env\\ folders   -- environment directories\n" + tail,
                     "echo  Safe to remove:\necho    .*_env\\ folders   -- environment directories\n" + tail)
        self.assertTrue(any("exactly one SAFE TO DELETE line" in f for f in self.problems(bad)), self.problems(bad))

    def test_log_lines_that_change_or_swap_are_reported(self):
        bad = mutate(self.batch, 'call :log "[WARN] REQ-016: Post-flight briefing printed; EXE unverified, advised direct run."',
                     'call :log "[INFO] REQ-016: Post-flight briefing printed; EXE unverified, advised direct run."')
        self.assertTrue(any("WARN line of the log contract" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'call :log "[INFO] REQ-016: Post-flight briefing printed."\n', "")
        self.assertTrue(any("success log line" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "if defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n", "")
        self.assertTrue(any("closing dispatch" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_call_the_simulation_does_not_know_is_reported(self):
        bad = mutate(self.batch, "if defined HP_DLL_HINT_STATE call :pfb_dll_hint\n", "if defined HP_DLL_HINT_STATE call :pfb_dll_hint\ncall :pfb_new_hint\n")
        self.assertTrue(any(":pfb_new_hint" in f for f in self.problems(bad)), self.problems(bad))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the workflow, the registry and the shall list is shown to fail on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def problems(self, text):
        return script_problems(text)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "    id      = 'self.caveat.runline'\n    req     = 'REQ-016.6'\n", "    id      = $rowId\n    req     = 'REQ-016.6'\n")
        self.assertTrue(any("literal at exactly 3" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "    id      = 'self.caveat.sentences'\n    req     = 'REQ-016.7'\n", "    id      = 'self.caveat.sentences'\n    req     = 'REQ-016'\n")
        self.assertTrue(any("req tag" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_program_that_exits_0_or_prints_something_else_is_caught(self):
        bad = mutate(self.script, "$wantExit = 3\n", "$wantExit = 0\n")
        self.assertTrue(any("exits with 3" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$marker = 'CAVEAT_APP_RAN'\n", "$marker = 'APP_RAN'\n")
        self.assertTrue(any("exits with 3" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "sys.exit($wantExit)`n", "pass`n")
        self.assertTrue(any("sys.exit with the exit code" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_skip_hook_that_is_no_longer_cleared_is_caught(self):
        bad = mutate(self.script, "HP_SKIP_ENTRY_SMOKE = ''; ", "")
        self.assertTrue(any("no longer clears HP_SKIP_ENTRY_SMOKE" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "HP_SKIP_EXE_SMOKERUN = ''; ", "HP_SKIP_EXE_SMOKERUN = '1'; ")
        self.assertTrue(any("no longer clears HP_SKIP_EXE_SMOKERUN" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "HP_SKIP_NIVISA = '1'", "HP_SKIP_NIVISA = ''")
        self.assertTrue(any("no longer sets HP_SKIP_NIVISA" in f for f in self.problems(bad)), self.problems(bad))

    def test_open_standard_input_a_missing_limit_and_a_missing_kill_are_caught(self):
        bad = mutate(self.script, "2>&1 < nul\")", "2>&1\")")
        self.assertTrue(any("standard input closed" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$runTimeoutMs = 15 * 60 * 1000", "$runTimeoutMs = 0")
        self.assertTrue(any("taskkill /F /T" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "if ($p.WaitForExit(120000)) {", "if ($p.WaitForExit()) {")
        self.assertTrue(any("120 second limit" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_replay_that_stops_running_the_printed_command_as_printed_is_caught(self):
        bad = mutate(self.script, "@('@echo off', $Line, 'echo PVW_RC=%errorlevel%')", "@('@echo off', 'echo ' + $Line, 'echo PVW_RC=%errorlevel%')")
        self.assertTrue(any("written as printed" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$replay = Invoke-Replay -Dir $dir -Line $panel.Printed", "$replay = Invoke-Replay -Dir $dir -Line $exePath")
        self.assertTrue(any("no longer runs the command the briefing printed" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "-WorkingDirectory $Dir -NoNewWindow -PassThru -RedirectStandardOutput", "-NoNewWindow -PassThru -RedirectStandardOutput")
        self.assertTrue(any("program folder" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_verdict_that_stops_using_the_judges_is_caught(self):
        bad = mutate(self.script, "-Replay $replay -Marker $marker -WantExit $wantExit)", "-Replay $replay -Marker $marker -WantExit 0)")
        self.assertTrue(any("REQ-016.6 no longer comes from" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$sentencePass = ($sentenceProblems.Count -eq 0)", "$sentencePass = $true")
        self.assertTrue(any("judged by its list of problems" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$panel = Get-CaveatPanel $run.Console", "$panel = Get-CaveatPanel $run.Setup")
        self.assertTrue(any("console of the bootstrap" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_script_without_its_exit_codes_is_caught(self):
        bad = mutate(self.script, "if ($anyRed) { exit 1 }\nexit 0\n", "exit 0\n")
        self.assertTrue(any("exits 1 for a red row" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "if ($anyRed) { exit 1 }\nexit 0\n", "if ($anyRed) { exit 1 }\n")
        self.assertTrue(any("does not end with exit 0" in f for f in self.problems(bad)), self.problems(bad))

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
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\selfapps_caveat_briefing.ps1"])
        bad = self.workflow.replace("tests/~selftest_caveat/~cv_*", "")
        self.assertTrue(any("~cv_" in f for f in workflow_problems(bad)))

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        self.assertTrue(registry_problems(text.replace("self.caveat.sentences", "self.caveat.sentencesx")))
        self.assertTrue(registry_problems("```\nself.caveat.runline\n```\nprose: self.caveat.sentences\n"))

    def test_a_shall_that_is_still_listed_as_a_gap_is_caught(self):
        self.assertTrue(shall_list_problems('    "REQ-016.6": "gap: x",\n'))
        self.assertTrue(shall_list_problems('    "REQ-016.7": "gap: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-016.60": "gap: x",\n'), [])


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

    def test_a_judge_that_forgets_a_bootstrap_that_never_finished_is_caught(self):
        got = self.run_mutated("if (-not $Run.Finished) {", "if ($false) {", ["run_unfinished"])
        self.assertEqual(got["run_unfinished"], [])

    def test_a_judge_that_forgets_the_missing_caveat_is_caught(self):
        old = "so the run never reached the state under test') }\n    if ($Panel.Ready) {"
        got = self.run_mutated(old, "so the run never reached the state under test') }\n    if ($false) {", ["run_success_wording_too"])
        self.assertEqual(got["run_success_wording_too"], [])
        got = self.run_mutated("if (-not $Panel.Found) { return @('no caveat briefing was printed (the heading SETUP COMPLETE -- WITH A CAVEAT is not on the console), so the run never reached the state under test') }\n    if ($Panel.Ready) {",
                               "if ($false) { return @('x') }\n    if ($Panel.Ready) {", ["run_no_caveat"])
        self.assertNotEqual(got["run_no_caveat"], ["no caveat briefing was printed (the heading SETUP COMPLETE -- WITH A CAVEAT is not on the console), so the run never reached the state under test"])

    def test_a_judge_that_forgets_the_success_wording_is_caught(self):
        got = self.run_mutated("    if ($Panel.Ready) {", "    if ($false) {", ["run_success_wording_too"])
        self.assertEqual(got["run_success_wording_too"], [])

    def test_a_judge_that_forgets_the_missing_command_is_caught(self):
        got = self.run_mutated("    if (-not $Panel.Printed) {", "    if ($false) {", ["run_no_command"])
        self.assertNotIn("does not show the command", " ".join(got["run_no_command"]))

    def test_a_judge_that_forgets_the_shape_of_the_command_is_caught(self):
        got = self.run_mutated("""    if (-not ($Panel.Printed -match '^"([^"]+)"\\s+"([^"]+)"$')) {""", "    if ($false) {", ["run_command_one_path"])
        self.assertEqual(got["run_command_one_path"], [])

    def test_a_judge_that_forgets_the_interpreter_is_caught(self):
        got = self.run_mutated("    if (-not $ExeExists) {", "    if ($false) {", ["run_no_interpreter"])
        self.assertEqual(got["run_no_interpreter"], [])

    def test_a_judge_that_forgets_a_replay_that_never_finished_is_caught(self):
        got = self.run_mutated("    if (-not $Replay.Finished) {", "    if ($false) {", ["run_replay_unfinished"])
        self.assertFalse(any("did not finish" in f for f in got["run_replay_unfinished"]), got)

    def test_a_judge_that_forgets_the_exit_code_of_the_replay_is_caught(self):
        got = self.run_mutated("        if ($Replay.Exit -ne $WantExit) {", "        if ($false) {", ["run_replay_wrong_exit"])
        self.assertEqual(got["run_replay_wrong_exit"], [])

    def test_a_judge_that_forgets_the_programs_own_line_is_caught(self):
        got = self.run_mutated("        if (-not ([string]$Replay.Output).Contains($Marker)) {", "        if ($false) {", ["run_replay_no_marker"])
        self.assertEqual(got["run_replay_no_marker"], [])

    def test_a_judge_that_forgets_the_required_sentence_is_caught(self):
        old = "    if (-not [regex]::IsMatch($Panel.Caveat, 'Your Python environment was set up and the packaging step completed without a fatal error\\.')) {"
        got = self.run_mutated(old, "    if ($false) {", ["sent_sentence_missing"])
        self.assertEqual(got["sent_sentence_missing"], [])

    def test_a_judge_that_forgets_a_claim_of_verification_is_caught(self):
        got = self.run_mutated("        if ($claims -and (-not $negated)) {", "        if ($false) {", ["sent_claims_dependencies_verified"])
        self.assertEqual(got["sent_claims_dependencies_verified"], [])

    def test_a_judge_that_flags_every_negated_sentence_too_is_caught(self):
        got = self.run_mutated("        if ($claims -and (-not $negated)) {", "        if ($claims) {", ["sent_negated_claim_is_fine"])
        self.assertNotEqual(got["sent_negated_claim_is_fine"], [])

    def test_a_judge_that_forgets_the_warn_line_is_caught(self):
        old = "    if (-not [regex]::IsMatch($Setup, '\\[WARN\\] REQ-016: Post-flight briefing printed; EXE unverified, advised direct run\\.')) {"
        got = self.run_mutated(old, "    if ($false) {", ["sent_no_warn_line"])
        self.assertEqual(got["sent_no_warn_line"], [])

    def test_a_judge_that_forgets_the_success_log_line_is_caught(self):
        old = "    if ([regex]::IsMatch($Setup, '\\[INFO\\] REQ-016: Post-flight briefing printed\\.')) {"
        got = self.run_mutated(old, "    if ($false) {", ["sent_info_line_too"])
        self.assertEqual(got["sent_info_line_too"], [])

    def test_a_panel_that_stops_reading_the_command_is_caught(self):
        old = "if ($afterDirect -and (-not $printed) -and $line.TrimStart().StartsWith('\"')) { $printed = $line.Trim() }"
        got = self.run_mutated(old, "if ($false) { $printed = $line.Trim() }", ["panel_caveat"])
        self.assertEqual(got["panel_caveat"][0]["Printed"], "")

    def test_a_panel_that_reads_the_pip_example_before_the_introducing_line_is_caught(self):
        got = self.run_mutated("if ($afterDirect -and (-not $printed) -and", "if ((-not $printed) -and", ["panel_caveat", "panel_quoted_line_before_the_intro"])
        self.assertEqual(got["panel_caveat"][0]["Printed"], PRINTED, "on the real panel the first quoted line IS the command, so only the case with an earlier quoted line can tell the two readers apart")
        self.assertNotEqual(got["panel_quoted_line_before_the_intro"][0]["Printed"], PRINTED)

    def test_a_panel_that_stops_reading_the_success_wording_is_caught(self):
        got = self.run_mutated("[regex]::IsMatch($Console, 'Your standalone application is ready:')", "$false", ["panel_success"])
        self.assertFalse(got["panel_success"][0]["Ready"])


if __name__ == "__main__":
    unittest.main()
