"""Item 106 (README REQ-018.7): the re-verification run inside the --hidden-import repair loop ends after 30 seconds.

REQ-018.7 says the loop's own run of the EXE is ended after 30 seconds whatever output it produces (the main verification run,
REQ-018.6, is the one that lets any output keep the program alive). The shall is carried by one inline PowerShell line of
:hidden_import_loop in run_setup.bat: a WaitForExit(30000), a Kill() and two reads of what the process printed that come after the
kill. No row ever ran a program that keeps printing through it, and a PyInstaller onefile EXE is two processes, so a stop of the
first can leave the second holding the pipes the loop reads. tests/selfapps_repair_cap.ps1 (one row, self.repair.cap; contract-uv
lane, gating) bootstraps a program that needs a package it loads by a runtime string and then prints a line a second for 100
seconds, and judges the result by the program's own ledger and by the process list.

What really happens is shown on Windows by that script. These rules read run_setup.bat, the script, batch-check.yml,
docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, and run the script's own judging functions through a real pwsh on
synthetic runs (a run that passes, and one run for each way to be wrong), so a reworded log line, a loop that no longer stops the
process, a scenario that stops being the one the shall names, a judge that stops judging or a step that stops gating fails here
with a sentence, before a 40 minute Windows run is needed. Synthetic cases prove each rule can fail.
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
SCRIPT = REPO / "tests" / "selfapps_repair_cap.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

ROW_ID = "self.repair.cap"
ROW_REQ = "REQ-018.7"
GAP_SHALL = "REQ-018.7"

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~selftest_repaircap/~cap_console.log",
    "tests/~selftest_repaircap/~cap_ledger.jsonl",
    "tests/~selftest_repaircap/~setup.log",
    "tests/~selftest_repaircap/~bootstrap.status.json",
)

# The two lines of the batch file the script's log facts rest on, as they stand there (variables not yet expanded).
REPAIR_NEEDLE = "Adding --hidden-import="
STATUS_NEEDLE = "Run Status: TIMED OUT"

# The variables the bootstrap sets for the one run of the script: the repair answered yes, and three optional steps that do not
# belong to this scenario skipped. The two skip hooks that would stop the verification run, and so the loop, must NOT be set.
RUN_VARIABLES = (
    "HP_SKIP_PIPREQS = '1'", "HP_SKIP_AUTOPEP_DISCOVERY = '1'", "HP_SKIP_NIVISA = '1'", "HP_TEST_REPAIR_ANSWER = 'Y'",
)
FORBIDDEN_VARIABLES = ("HP_SKIP_ENTRY_SMOKE", "HP_SKIP_EXE_SMOKERUN", "HP_CI_SKIP_ENV", "HP_TEST_FORCE_UV_FAIL")

JUDGES = ["Get-CapLogFacts", "Get-CapStarts", "Get-RepairCapProblems", "Get-CapExcerpt"]


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


# --- the batch file: what the script assumes about the loop ------------------------------------------------------------------

def log_message(batch, needle):
    """The text of the one live `call :log "..."` line that holds the needle, the variables not yet expanded."""
    hits = [ln.strip() for ln in live_bat(lines_of(batch)) if needle in ln and ln.strip().startswith('call :log "') and ln.strip().endswith('"')]
    assert len(hits) == 1, "%r: expected one live call :log line, found %d" % (needle, len(hits))
    return hits[0][len('call :log "'):-1]


def loop_problems(batch):
    """README REQ-018.7 in the batch file: the loop's run of the EXE waits 30 seconds, stops the process it started and only
    then reads what it printed, a run that did not finish counts as -1, and the two log lines the script reads are live."""
    found = []
    stripped = [ln.strip() for ln in lines_of(batch)]
    for label in (":hidden_import_recover", ":hidden_import_loop", ":hidden_import_recover_done", ":hidden_import_consent"):
        n = sum(1 for ln in stripped if ln == label)
        if n != 1:
            found.append("the label %s appears %d time(s); expected exactly once" % (label, n))
    if found:
        return found
    block = cut_block(batch, ":hidden_import_loop", ":hidden_import_recover_done")
    if block is None:
        return ["the block from :hidden_import_loop to :hidden_import_recover_done cannot be cut"]
    body = [ln.strip() for ln in live_bat(block)]
    runs = [ln for ln in body if "WaitForExit(30000)" in ln]
    if len(runs) != 1:
        found.append("the loop must hold exactly one live line with WaitForExit(30000), the 30 second cap; found %d" % len(runs))
    else:
        run = runs[0]
        wait = run.index("WaitForExit(30000)")
        kill = run.find("$p.Kill()")
        read = run.find("$so.Result")
        if kill < 0 or kill < wait:
            found.append("the line that waits 30 seconds no longer stops the process it started after the wait ($p.Kill())")
        if read < 0 or read < kill:
            found.append("the output is read before the process is stopped, so a program that keeps printing is waited for and not stopped")
        if "if($done){$p.ExitCode}else{-1}" not in run:
            found.append("a run that did not finish within 30 seconds no longer gives the exit code -1")
        if "ReadToEndAsync" not in run:
            found.append("the output of the run is no longer read through the two asynchronous reads that the cap relies on")
        if "$env:HP_HIR_EXE" not in run or "'dist\\~exe_out.txt'" not in run:
            found.append("the run no longer starts the EXE named by HP_HIR_EXE and no longer writes dist\\~exe_out.txt")
    # the same default line exists in :run_exe_smokerun, so the pin is on this block only: after the run, before the 0 test
    default_line = 'if not defined HP_EXE_EXIT set "HP_EXE_EXIT=-1"'
    zero_line = 'if "%HP_EXE_EXIT%"=="0" goto :hidden_import_recover_done'
    if default_line not in body or zero_line not in body or not body.index(default_line) < body.index(zero_line):
        found.append("a loop run whose result could not be read no longer counts as the cap's -1 (the default line must come before the test for 0)")
    repair = [ln for ln in body if ln.startswith('call :log "[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=')]
    if len(repair) != 1:
        found.append("the loop must log '[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=' once through a live call :log line; found %d" % len(repair))
    elif "%HP_NEXT_HIDDEN%" not in repair[0]:
        found.append("the repair line no longer names the module (%HP_NEXT_HIDDEN%) that the script looks for")
    live_all = [ln.strip() for ln in live_bat(lines_of(batch))]
    status_lines = [ln for ln in live_all if ln.startswith('call :log "[STATUS] Run Status: TIMED OUT (hit the ~30s verification cap')]
    if len(status_lines) != 1:
        found.append("the timeout status line must be written once by a live call :log line; found %d" % len(status_lines))
    else:
        at = live_all.index(status_lines[0])
        if live_all[at - 1] != ') else if "%HP_EXE_EXIT%"=="-1" (':
            found.append("the timeout status line is no longer the branch taken for HP_EXE_EXIT -1")
    # the question comes before the loop (Item 97), so the one extra start the script needs is the consented one
    consent_at = [i for i, ln in enumerate(stripped) if ln == "call :hidden_import_consent"]
    loop_at = stripped.index(":hidden_import_loop")
    if len(consent_at) != 1 or consent_at[0] > loop_at:
        found.append("the loop's consent question no longer comes once and before :hidden_import_loop")
    return found


# --- the script ------------------------------------------------------------------------------------------------------------------

def script_problems(text):
    t = norm(text)
    live = live_hash(t)
    flat = "\n".join(live)
    found = []
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if ids != [ROW_ID] * 3:
        found.append("the row id must be the literal %r at each of the three Write-NdjsonRow call sites, found %r" % (ROW_ID, ids))
    tags = re.findall(r"\bid = '%s'; req = '([^']*)'" % re.escape(ROW_ID), t)
    if tags != [ROW_REQ] * 3:
        found.append("the row must carry the literal req tag %r at each of the three call sites, found %r" % (ROW_REQ, tags))
    if "$capSeconds = 30" not in flat:
        found.append("the script no longer judges against a cap of 30 seconds ($capSeconds = 30)")
    if "$runTimeoutMs = 15 * 60 * 1000" not in flat:
        found.append("the bootstrap no longer has the 15 minute limit that turns a hang into a red row")
    if "taskkill.exe /F /T /PID $p.Id" not in flat:
        found.append("a bootstrap that outlives its limit is no longer stopped with taskkill /F /T")
    if "call run_setup.bat > ~cap_console.log 2>&1 < nul" not in flat:
        found.append("the bootstrap no longer runs with standard input closed (< nul) and its console in ~cap_console.log")
    for variable in RUN_VARIABLES:
        if variable not in flat:
            found.append("the bootstrap no longer sets %s" % variable)
    for name in FORBIDDEN_VARIABLES:
        if re.search(r"\b%s\b" % name, flat):
            found.append("the script sets %s, which would stop the verification run and so the loop the row is about" % name)
    if "CAP_LEDGER = (Join-Path $dir '~cap_ledger.jsonl')" not in flat or 'os.environ["CAP_LEDGER"]' not in flat:
        found.append("the program no longer writes its ledger to the absolute path the script reads (CAP_LEDGER)")
    if "SetEnvironmentVariable($k, $saved[$k])" not in flat:
        found.append("the variables set for the bootstrap are no longer restored afterwards")
    # the program: a ledger line first, a package loaded by a runtime string, and far longer output than the cap
    app = re.search(r"\$appCode = @'\n(.*?)\n'@", t, re.S)
    if app is None:
        found.append("the program text (the $appCode here-string) cannot be found")
    else:
        code = app.group(1)
        start_at = code.find('note("start"')
        import_at = code.find("importlib.import_module('colorama')")
        if start_at < 0 or import_at < 0 or start_at > import_at:
            found.append("the program must write its ledger line before it imports colorama by a runtime string")
        if re.search(r"(?m)^\s*(import|from)\s+colorama\b", code):
            found.append("the program imports colorama by a plain statement, so PyInstaller bundles it and the loop never runs")
        count = re.search(r"for i in range\(1, (\d+)\):", code)
        nap = re.search(r"time\.sleep\((\d+)\)", code)
        if count is None or nap is None or (int(count.group(1)) - 1) * int(nap.group(1)) < 90:
            found.append("the program must print for far longer than the cap (at least 90 seconds), or a run that was not stopped looks the same as one that was")
        if 'print("tick", i, flush=True)' not in code:
            found.append("the program no longer prints a flushed line every second, so the run is not one that keeps producing output")
        if 'note("done")' not in code:
            found.append("the program no longer writes the done line that tells a run that ended by itself")
    if "Get-ProcessesUnder -Folder (Join-Path $dir 'dist')" not in flat:
        found.append("the process list is no longer read for the scenario's dist folder")
    else:
        read_at = flat.index("Get-ProcessesUnder -Folder (Join-Path $dir 'dist')")
        stop_at = flat.find("Stop-Process -Id $o.ProcessId")
        if stop_at < 0 or stop_at < read_at:
            found.append("a program left alive must be read from the process list before it is stopped, not after")
    for need in ("-Finished ([bool]$run.Finished)", "-Starts $starts", "-RepairLogged ([bool]$facts.repairLogged)",
                 "-TimedOutAfterRepair ([bool]$facts.timedOutAfterRepair)", "-OrphanCheckRan ([bool]$run.OrphanCheckRan)",
                 "-Orphans @($run.Orphans)", "-CapSeconds $capSeconds"):
        if "$problems = @(Get-RepairCapProblems" not in flat or need not in flat.split("$problems = @(Get-RepairCapProblems", 1)[1].split("\n", 1)[0]:
            found.append("the verdict no longer hands %s to Get-RepairCapProblems" % need)
    if "$pass = ($problems.Count -eq 0)" not in flat:
        found.append("the verdict is no longer taken from the list of problems ($pass = ($problems.Count -eq 0))")
    if "pass = [bool]$pass" not in flat:
        found.append("the row's pass field is no longer the verdict")
    for name in ("Get-CapLogFacts", "Get-CapStarts", "Get-RepairCapProblems", "Get-CapExcerpt"):
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the judging function %s is missing" % name)
    if "OSVersion.Platform -ne [System.PlatformID]::Win32NT" not in flat or re.search(r"\$IsWindows\b", flat):
        found.append("the Windows check must use OSVersion.Platform and not $IsWindows")
    if "skip = $true" not in flat:
        found.append("the row no longer skips off Windows with skip = $true")
    if "if (-not $pass) { exit 1 }" not in flat:
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
        if "selfapps_repair_cap.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_repair_cap.ps1"]
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
            ids.add(ln.strip().split()[0])
    return ids


def registry_problems(text):
    return [] if ROW_ID in registry_ids(text) else ["%s is not in docs/agent-ndjson.md" % ROW_ID]


def shall_list_problems(text):
    """The shall the row traces is no longer listed as a gap (the shall-level ratchet only warns about a stale entry)."""
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


def ledger_line(event, pid, t, **more):
    row = {"ev": event, "pid": pid, "t": t}
    row.update(more)
    return row


def start_summary(pid=1, frozen=True, imported=True, ticks=29, done=False, span=29.4):
    return {"ProcessId": pid, "Frozen": frozen, "Imported": imported, "Ticks": ticks, "Done": done, "Span": span}


def cap_args(**over):
    args = dict(Finished=True, Starts=[start_summary()], RepairLogged=True, TimedOutAfterRepair=True, OrphanCheckRan=True,
                Orphans=[], CapSeconds=30)
    args.update(over)
    return args


def setup_samples():
    """The two lines the script reads from the setup log, taken from the live lines of run_setup.bat with the variables filled in."""
    batch = BATCH.read_text(encoding="utf-8", errors="replace")
    stamp = "2026-11-13 10:00:00.00 "
    repair = log_message(batch, REPAIR_NEEDLE).replace("%HP_NEXT_HIDDEN%", "colorama").replace("%HP_HIDDEN_ITER%", "1")
    timeout = log_message(batch, STATUS_NEEDLE)
    return stamp + repair, stamp + timeout


def judge_cases():
    repair, timeout = setup_samples()
    c = []
    # --- Get-CapLogFacts: the two facts the verdict rests on
    c.append(case("facts_both", "Get-CapLogFacts", SetupText="noise\n%s\nmore\n%s\n" % (repair, timeout)))
    c.append(case("facts_repair_only", "Get-CapLogFacts", SetupText="%s\n" % repair))
    c.append(case("facts_timeout_only", "Get-CapLogFacts", SetupText="%s\n" % timeout))
    c.append(case("facts_timeout_before_repair", "Get-CapLogFacts", SetupText="%s\n%s\n" % (timeout, repair)))
    c.append(case("facts_neither", "Get-CapLogFacts", SetupText="[INFO] nothing about a repair\n"))
    c.append(case("facts_other_module", "Get-CapLogFacts", SetupText="%s\n%s\n" % (repair.replace("colorama", "numpy"), timeout)))
    c.append(case("facts_other_cap", "Get-CapLogFacts", SetupText="%s\n%s\n" % (repair, timeout.replace("~30s", "~60s"))))
    c.append(case("facts_success_status", "Get-CapLogFacts",
                  SetupText="%s\n2026-11-13 10:01:00.00 [STATUS] Run Status: SUCCESS (Exit Code: 0)\n" % repair))
    # --- Get-CapStarts: one summary per process id that wrote to the ledger
    two = [
        ledger_line("start", 10, 100.0, frozen=True),
        ledger_line("start", 11, 110.0, frozen=True),
        ledger_line("start", 12, 150.0, frozen=True),
        ledger_line("imported", 12, 150.25, name="colorama"),
        ledger_line("tick", 12, 150.5, n=1),
        ledger_line("tick", 12, 151.5, n=2),
        ledger_line("tick", 12, 179.5, n=30),
    ]
    c.append(case("starts_three", "Get-CapStarts", Ledger=two))
    c.append(case("starts_empty", "Get-CapStarts", Ledger=[]))
    c.append(case("starts_skips_lines_that_are_not_ledger_lines", "Get-CapStarts",
                  Ledger=[{"parseError": "not json"}, {"ev": "start", "pid": 3}, ledger_line("start", 4, 5.0, frozen=True)]))
    c.append(case("starts_not_frozen", "Get-CapStarts", Ledger=[ledger_line("start", 7, 1.0, frozen=False), ledger_line("imported", 7, 1.5)]))
    c.append(case("starts_done", "Get-CapStarts",
                  Ledger=[ledger_line("start", 8, 1.0, frozen=True), ledger_line("imported", 8, 1.1), ledger_line("done", 8, 101.0)]))
    c.append(case("starts_interleaved_pids", "Get-CapStarts",
                  Ledger=[ledger_line("start", 1, 1.0, frozen=True), ledger_line("start", 2, 2.0, frozen=True),
                          ledger_line("tick", 1, 3.0), ledger_line("tick", 2, 4.0), ledger_line("tick", 1, 5.0)]))
    # --- Get-RepairCapProblems: the verdict
    c.append(case("cap_good", "Get-RepairCapProblems", **cap_args()))
    c.append(case("cap_good_ignores_runs_that_failed_at_the_import", "Get-RepairCapProblems",
                  **cap_args(Starts=[start_summary(pid=1, imported=False, ticks=0, span=0.0), start_summary(pid=2, imported=False, ticks=0, span=0.0),
                                     start_summary(pid=3)])))
    c.append(case("cap_unfinished", "Get-RepairCapProblems", **cap_args(Finished=False)))
    c.append(case("cap_no_repair_logged", "Get-RepairCapProblems", **cap_args(RepairLogged=False, TimedOutAfterRepair=False)))
    c.append(case("cap_no_run_past_the_import", "Get-RepairCapProblems",
                  **cap_args(Starts=[start_summary(pid=1, imported=False, ticks=0, span=0.0)])))
    c.append(case("cap_no_starts_at_all", "Get-RepairCapProblems", **cap_args(Starts=[])))
    c.append(case("cap_not_timed_out_after_repair", "Get-RepairCapProblems", **cap_args(TimedOutAfterRepair=False)))
    c.append(case("cap_run_done_by_itself", "Get-RepairCapProblems", **cap_args(Starts=[start_summary(ticks=100, done=True, span=99.0)])))
    c.append(case("cap_done_within_the_window", "Get-RepairCapProblems", **cap_args(Starts=[start_summary(ticks=29, done=True, span=29.0)])))
    c.append(case("cap_span_over_the_window", "Get-RepairCapProblems", **cap_args(Starts=[start_summary(ticks=45, span=45.1)])))
    c.append(case("cap_span_at_the_upper_edge", "Get-RepairCapProblems", **cap_args(Starts=[start_summary(ticks=45, span=45.0)])))
    c.append(case("cap_span_under_the_window", "Get-RepairCapProblems", **cap_args(Starts=[start_summary(ticks=9, span=9.9)])))
    c.append(case("cap_span_at_the_lower_edge", "Get-RepairCapProblems", **cap_args(Starts=[start_summary(ticks=10, span=10.0)])))
    c.append(case("cap_orphan_check_did_not_run", "Get-RepairCapProblems", **cap_args(OrphanCheckRan=False)))
    c.append(case("cap_orphan_left", "Get-RepairCapProblems", **cap_args(Orphans=[{"ProcessId": 5, "Name": "app.exe"}])))
    c.append(case("cap_two_orphans", "Get-RepairCapProblems",
                  **cap_args(Orphans=[{"ProcessId": 5, "Name": "app.exe"}, {"ProcessId": 6, "Name": "app.exe"}])))
    c.append(case("cap_orphans_not_counted_when_the_check_did_not_run", "Get-RepairCapProblems",
                  **cap_args(OrphanCheckRan=False, Orphans=[{"ProcessId": 5, "Name": "app.exe"}])))
    c.append(case("cap_two_runs_one_bad", "Get-RepairCapProblems",
                  **cap_args(Starts=[start_summary(pid=1), start_summary(pid=2, ticks=100, done=True, span=99.0)])))
    c.append(case("cap_the_cap_is_a_parameter", "Get-RepairCapProblems", **cap_args(CapSeconds=60)))
    c.append(case("cap_a_run_of_the_interpreter_is_not_counted", "Get-RepairCapProblems",
                  **cap_args(Starts=[start_summary(frozen=False)])))
    # --- Get-CapExcerpt
    noisy = ["unrelated line", "[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama", "caf\u00e9 [ERROR] bad", "x" * 40 + " Run Status: TIMED OUT " + "y" * 200]
    c.append(case("excerpt_keeps_only_the_explaining_lines", "Get-CapExcerpt", Text="\r\n".join(noisy)))
    c.append(case("excerpt_is_capped", "Get-CapExcerpt", Text="\n".join("[ERROR] line %d" % i for i in range(60)), Max=5))
    return c


def sentences(found):
    return " | ".join(found)


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

    def test_a_run_that_was_stopped_near_the_cap_and_left_nothing_behind_has_no_problem(self):
        self.assertEqual(self.r["cap_good"], [])
        self.assertEqual(self.r["cap_good_ignores_runs_that_failed_at_the_import"], [])
        self.assertEqual(self.r["cap_span_at_the_upper_edge"], [])
        self.assertEqual(self.r["cap_span_at_the_lower_edge"], [])

    def test_a_bootstrap_that_did_not_finish_is_one_problem_and_nothing_else(self):
        self.only("cap_unfinished", "the bootstrap did not finish within the time limit")

    def test_the_two_log_lines_are_read_in_order(self):
        self.assertEqual(self.r["facts_both"], [{"repairLogged": True, "timedOutAfterRepair": True}])
        self.assertEqual(self.r["facts_repair_only"], [{"repairLogged": True, "timedOutAfterRepair": False}])
        self.assertEqual(self.r["facts_timeout_only"], [{"repairLogged": False, "timedOutAfterRepair": False}])
        self.assertEqual(self.r["facts_timeout_before_repair"], [{"repairLogged": True, "timedOutAfterRepair": False}])
        self.assertEqual(self.r["facts_neither"], [{"repairLogged": False, "timedOutAfterRepair": False}])
        self.assertEqual(self.r["facts_success_status"], [{"repairLogged": True, "timedOutAfterRepair": False}])

    def test_the_repair_must_name_colorama_and_the_status_must_name_the_30_second_cap(self):
        self.assertEqual(self.r["facts_other_module"], [{"repairLogged": False, "timedOutAfterRepair": False}])
        self.assertEqual(self.r["facts_other_cap"], [{"repairLogged": True, "timedOutAfterRepair": False}])

    def test_a_ledger_becomes_one_summary_per_process(self):
        three = self.r["starts_three"]
        self.assertEqual([s["ProcessId"] for s in three], [10, 11, 12])
        self.assertEqual([s["Frozen"] for s in three], [True, True, True])
        self.assertEqual([s["Imported"] for s in three], [False, False, True])
        self.assertEqual([s["Ticks"] for s in three], [0, 0, 3])
        self.assertEqual([s["Done"] for s in three], [False, False, False])
        self.assertEqual([round(s["Span"], 2) for s in three], [0.0, 0.0, 29.5])
        self.assertEqual(self.r["starts_empty"], [])

    def test_lines_that_are_not_ledger_lines_start_nothing(self):
        got = self.r["starts_skips_lines_that_are_not_ledger_lines"]
        self.assertEqual([s["ProcessId"] for s in got], [4])

    def test_only_a_start_line_that_says_frozen_marks_the_exe_and_done_marks_a_run_that_ended(self):
        self.assertEqual([s["Frozen"] for s in self.r["starts_not_frozen"]], [False])
        self.assertEqual([(s["Done"], round(s["Span"], 1)) for s in self.r["starts_done"]], [(True, 100.0)])
        inter = self.r["starts_interleaved_pids"]
        self.assertEqual([(s["ProcessId"], s["Ticks"], round(s["Span"], 1)) for s in inter], [(1, 2, 4.0), (2, 1, 2.0)])

    def test_a_loop_that_found_nothing_to_repair_is_named(self):
        self.only("cap_no_repair_logged", "no [REPAIR][HIDDEN_IMPORT] line for colorama")
        self.only("cap_no_run_past_the_import", "no start of the EXE got past the import of colorama")
        self.only("cap_no_starts_at_all", "no start of the EXE got past the import of colorama")
        self.only("cap_a_run_of_the_interpreter_is_not_counted", "no start of the EXE got past the import of colorama")

    def test_a_run_the_loop_did_not_report_as_timed_out_is_named(self):
        self.only("cap_not_timed_out_after_repair", "does not report the loop as timed out after the repair")

    def test_a_program_that_ended_by_itself_or_kept_printing_is_a_run_nobody_stopped(self):
        self.only("cap_run_done_by_itself", "ended by itself")
        self.only("cap_done_within_the_window", "ended by itself")
        self.only("cap_span_over_the_window", "was still printing 45.1 s after its first line")

    def test_a_program_that_stopped_too_early_was_not_stopped_by_the_cap(self):
        self.only("cap_span_under_the_window", "stopped printing only 9.9 s after its first line")

    def test_only_the_bad_run_of_two_is_named(self):
        self.only("cap_two_runs_one_bad", "ended by itself")

    def test_the_window_follows_the_cap_it_is_given(self):
        self.only("cap_the_cap_is_a_parameter", "stopped printing only 29.4 s after its first line, less than 40 s")

    def test_a_process_left_behind_is_named_and_a_check_that_did_not_run_is_not_an_empty_answer(self):
        self.only("cap_orphan_left", "1 process(es) of the program were still running")
        self.only("cap_two_orphans", "2 process(es) of the program were still running")
        self.only("cap_orphan_check_did_not_run", "the list of running processes could not be read")
        self.only("cap_orphans_not_counted_when_the_check_did_not_run", "the list of running processes could not be read")

    def test_the_excerpt_keeps_the_explaining_lines_as_short_ascii(self):
        got = self.r["excerpt_keeps_only_the_explaining_lines"]
        self.assertEqual(len(got), 3, got)
        self.assertTrue(all(len(line) <= 150 and all(ord(ch) < 128 for ch in line) for line in got), got)
        self.assertIn("caf? [ERROR] bad", got)
        self.assertEqual(len(self.r["excerpt_is_capped"]), 5)


class LogFactsMatchTheRealText(unittest.TestCase):
    """The script reads two lines of the setup log; they are taken from the live lines of run_setup.bat, so a reworded line fails
    here and not on a Windows run."""

    def test_the_two_lines_are_live_call_log_lines_and_name_what_the_script_reads(self):
        batch = BATCH.read_text(encoding="utf-8", errors="replace")
        repair = log_message(batch, REPAIR_NEEDLE)
        self.assertIn("[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=%HP_NEXT_HIDDEN%", repair)
        timeout = log_message(batch, STATUS_NEEDLE)
        self.assertTrue(timeout.startswith("[STATUS] Run Status: TIMED OUT (hit the ~30s verification cap"), timeout)

    def test_the_log_line_does_not_carry_characters_that_log_would_mis_echo(self):
        # :log echoes unquoted, so neither text may hold a shell operator (a missing line would make the script's fact false)
        repair, timeout = setup_samples()
        for text in (repair, timeout):
            self.assertIsNone(re.search(r"[<>|&^]", text), text)


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

    def test_the_loop_waits_30_seconds_stops_the_process_and_only_then_reads_its_output(self):
        self.assertEqual(loop_problems(self.batch), [])

    def test_the_script_has_its_row_judges_variables_program_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_row_is_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shall_is_no_longer_listed_as_a_gap(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        block = cut_block(self.batch, ":hidden_import_loop", ":hidden_import_recover_done")
        self.assertGreater(len(live_bat(block)), 20)
        self.assertEqual(len(judge_cases()), 36)

    def test_every_judge_the_driver_is_asked_for_is_a_function_of_the_script(self):
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))


def mutate(text, old, new):
    # exactly once: with two matches the case would edit the first one, which may be another block of the file, and the pin under
    # test would never see the change
    assert text.count(old) == 1, "the synthetic case needs the text to hold %r exactly once, found %d" % (old[:60], text.count(old))
    return text.replace(old, new, 1)


class BatchRulesCanFail(unittest.TestCase):
    """Each rule about run_setup.bat is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")

    def test_a_label_that_is_missing_or_duplicated_is_reported(self):
        gone = mutate(self.batch, "\n:hidden_import_loop\n", "\n:hidden_import_loopx\n")
        self.assertTrue(any("appears 0 time(s)" in f for f in loop_problems(gone)))
        twice = self.batch + "\n:hidden_import_consent\n"
        self.assertTrue(any("appears 2 time(s)" in f for f in loop_problems(twice)))
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))

    def test_a_cap_that_is_not_30_seconds_is_caught(self):
        bad = mutate(self.batch, "$done=$p.WaitForExit(30000);if(-not $done){try{$p.Kill()}catch{}};($so.Result+$se.Result)",
                     "$done=$p.WaitForExit(300000);if(-not $done){try{$p.Kill()}catch{}};($so.Result+$se.Result)")
        self.assertTrue(any("WaitForExit(30000)" in f for f in loop_problems(bad)), loop_problems(bad))

    def test_a_run_that_is_not_stopped_after_the_wait_is_caught(self):
        bad = mutate(self.batch, "$done=$p.WaitForExit(30000);if(-not $done){try{$p.Kill()}catch{}};($so.Result+$se.Result)",
                     "$done=$p.WaitForExit(30000);($so.Result+$se.Result)")
        self.assertTrue(any("no longer stops the process" in f for f in loop_problems(bad)), loop_problems(bad))

    def test_a_read_that_comes_before_the_stop_is_caught(self):
        bad = mutate(self.batch, "$done=$p.WaitForExit(30000);if(-not $done){try{$p.Kill()}catch{}};($so.Result+$se.Result)|Set-Content",
                     "$done=$p.WaitForExit(30000);($so.Result+$se.Result)|Set-Content")
        bad = mutate(bad, "-Encoding ASCII;if($done){$p.ExitCode}else{-1}\"`) do set \"HP_EXE_EXIT=%%X\"",
                     "-Encoding ASCII;if(-not $done){try{$p.Kill()}catch{}};if($done){$p.ExitCode}else{-1}\"`) do set \"HP_EXE_EXIT=%%X\"")
        self.assertTrue(any("before the process is stopped" in f for f in loop_problems(bad)), loop_problems(bad))

    def test_a_run_that_does_not_report_minus_one_when_it_did_not_finish_is_caught(self):
        bad = mutate(self.batch, "-Encoding ASCII;if($done){$p.ExitCode}else{-1}\"`) do set \"HP_EXE_EXIT=%%X\"",
                     "-Encoding ASCII;$p.ExitCode\"`) do set \"HP_EXE_EXIT=%%X\"")
        self.assertTrue(any("exit code -1" in f for f in loop_problems(bad)), loop_problems(bad))

    def test_an_unset_result_that_is_not_the_caps_minus_one_is_caught(self):
        bad = mutate(self.batch, 'if not defined HP_EXE_EXIT set "HP_EXE_EXIT=-1"\nif "%HP_EXE_EXIT%"=="0" goto :hidden_import_recover_done\n',
                     'if "%HP_EXE_EXIT%"=="0" goto :hidden_import_recover_done\n')
        self.assertTrue(any("result could not be read" in f for f in loop_problems(bad)), loop_problems(bad))
        # moved after the test for 0 it can no longer help: the order is part of the rule
        moved = mutate(self.batch, 'if not defined HP_EXE_EXIT set "HP_EXE_EXIT=-1"\nif "%HP_EXE_EXIT%"=="0" goto :hidden_import_recover_done\n',
                       'if "%HP_EXE_EXIT%"=="0" goto :hidden_import_recover_done\nif not defined HP_EXE_EXIT set "HP_EXE_EXIT=-1"\n')
        self.assertTrue(any("result could not be read" in f for f in loop_problems(moved)), loop_problems(moved))

    def test_a_reworded_repair_line_or_status_line_is_caught(self):
        bad = mutate(self.batch, 'call :log "[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=%HP_NEXT_HIDDEN% --collect-submodules',
                     'call :log "[REPAIR][HIDDEN_IMPORT] Rebuilding with --hidden-import=%HP_NEXT_HIDDEN% --collect-submodules')
        self.assertTrue(any("Adding --hidden-import=" in f for f in loop_problems(bad)), loop_problems(bad))
        bad = mutate(self.batch, 'call :log "[STATUS] Run Status: TIMED OUT (hit the ~30s verification cap;',
                     'call :log "[STATUS] Run Status: TIMED OUT (hit the verification cap;')
        self.assertTrue(any("timeout status line" in f for f in loop_problems(bad)), loop_problems(bad))

    def test_a_status_line_that_is_not_the_branch_of_minus_one_is_caught(self):
        bad = mutate(self.batch, ') else if "%HP_EXE_EXIT%"=="-1" (\n  call :log "[STATUS] Run Status: TIMED OUT', ') else if "%HP_EXE_EXIT%"=="2" (\n  call :log "[STATUS] Run Status: TIMED OUT')
        self.assertTrue(any("branch taken for HP_EXE_EXIT -1" in f for f in loop_problems(bad)), loop_problems(bad))

    def test_a_consent_question_that_moved_behind_the_loop_is_caught(self):
        bad = mutate(self.batch, "\ncall :hidden_import_consent\nif not defined HP_HIC_ALLOWED exit /b 0\n", "\nif not defined HP_HIC_ALLOWED exit /b 0\n")
        self.assertTrue(any("consent question" in f for f in loop_problems(bad)), loop_problems(bad))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the workflow and the registry is shown to fail on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def problems(self, text):
        return script_problems(text)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "id = 'self.repair.cap'; req = 'REQ-018.7'; pass = [bool]$pass", "id = $rowId; req = 'REQ-018.7'; pass = [bool]$pass")
        self.assertTrue(any("row id must be the literal" in f for f in self.problems(bad)))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "req = 'REQ-018.7'; pass = [bool]$pass", "req = 'REQ-018'; pass = [bool]$pass")
        self.assertTrue(any("req tag" in f for f in self.problems(bad)))

    def test_a_cap_or_a_limit_that_changed_is_caught(self):
        bad = mutate(self.script, "$capSeconds = 30", "$capSeconds = 3")
        self.assertTrue(any("cap of 30 seconds" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$runTimeoutMs = 15 * 60 * 1000", "$runTimeoutMs = 0")
        self.assertTrue(any("15 minute limit" in f for f in self.problems(bad)))

    def test_open_standard_input_and_a_missing_kill_are_caught(self):
        bad = mutate(self.script, "2>&1 < nul'", "2>&1'")
        self.assertTrue(any("standard input" in f for f in self.problems(bad)))
        bad = mutate(self.script, "& taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null", "")
        self.assertTrue(any("taskkill" in f for f in self.problems(bad)))

    def test_a_missing_answer_or_a_skip_hook_that_would_stop_the_loop_is_caught(self):
        bad = mutate(self.script, "HP_TEST_REPAIR_ANSWER = 'Y'", "HP_TEST_REPAIR_ANSWER = 'N'")
        self.assertTrue(any("HP_TEST_REPAIR_ANSWER" in f for f in self.problems(bad)))
        bad = mutate(self.script, "HP_SKIP_NIVISA = '1'", "HP_SKIP_NIVISA = '1'; HP_SKIP_EXE_SMOKERUN = '1'")
        self.assertTrue(any("HP_SKIP_EXE_SMOKERUN" in f and "stop the verification run" in f for f in self.problems(bad)))

    def test_a_program_that_stops_being_the_one_the_shall_names_is_caught(self):
        bad = mutate(self.script, "    time.sleep(1)\n", "    time.sleep(0)\n")
        self.assertTrue(any("far longer than the cap" in f for f in self.problems(bad)))
        bad = mutate(self.script, "for i in range(1, 101):", "for i in range(1, 11):")
        self.assertTrue(any("far longer than the cap" in f for f in self.problems(bad)))
        bad = mutate(self.script, "mod = importlib.import_module('colorama')", "import colorama\nmod = colorama")
        self.assertTrue(any("plain statement" in f for f in self.problems(bad)))
        bad = mutate(self.script, "note(\"start\", frozen=bool(getattr(sys, \"frozen\", False)))\nmod = importlib.import_module('colorama')",
                     "mod = importlib.import_module('colorama')\nnote(\"start\", frozen=bool(getattr(sys, \"frozen\", False)))")
        self.assertTrue(any("ledger line before it imports" in f for f in self.problems(bad)))
        bad = mutate(self.script, 'note("done")\n', "")
        self.assertTrue(any("done line" in f for f in self.problems(bad)))

    def test_a_process_list_that_reads_the_wrong_folder_or_too_late_is_caught(self):
        bad = mutate(self.script, "$left = Get-ProcessesUnder -Folder (Join-Path $dir 'dist')", "$left = Get-ProcessesUnder -Folder $dir")
        self.assertTrue(any("dist folder" in f for f in self.problems(bad)))
        # a leftover stopped before the list is read is never counted: the stop has to come after the read
        bad = mutate(self.script, "        $left = Get-ProcessesUnder -Folder (Join-Path $dir 'dist')\n",
                     "        foreach ($o in @($left.Found)) { try { Stop-Process -Id $o.ProcessId -Force -ErrorAction Stop } catch { } }\n        $left = Get-ProcessesUnder -Folder (Join-Path $dir 'dist')\n")
        self.assertTrue(any("before it is stopped" in f for f in self.problems(bad)))

    def test_a_verdict_that_hands_the_judge_a_different_cap_or_is_not_the_problem_list_is_caught(self):
        bad = mutate(self.script, "-CapSeconds $capSeconds)", "-CapSeconds 3000)")
        self.assertTrue(any("-CapSeconds $capSeconds" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$pass = ($problems.Count -eq 0)", "$pass = $true")
        self.assertTrue(any("$pass = ($problems.Count -eq 0)" in f for f in self.problems(bad)))

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
        block = step_block(self.workflow)
        self.assertIsNotNone(block)
        other = self.workflow.replace(block, block.replace("matrix.mode == 'contract-uv'", "matrix.mode == 'real'"))
        self.assertTrue(any("contract-uv" in f for f in workflow_problems(other)))

    def test_a_step_that_cannot_fail_is_caught(self):
        block = step_block(self.workflow)
        bad = self.workflow.replace(block, block.replace("        shell: pwsh\n", "        shell: pwsh\n        continue-on-error: true\n", 1))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(bad)))

    def test_a_missing_step_or_upload_is_caught(self):
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\selfapps_repair_cap.ps1"])
        bad = self.workflow.replace("tests/~selftest_repaircap/~cap_ledger.jsonl", "")
        self.assertTrue(any("~cap_ledger" in f for f in workflow_problems(bad)))

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        self.assertTrue(registry_problems(text.replace(ROW_ID, "self.repair.capx")))
        self.assertTrue(registry_problems("```\nself.repair.gate.once\n```\nprose: %s\n" % ROW_ID))

    def test_a_shall_that_is_still_listed_as_a_gap_is_caught(self):
        self.assertTrue(shall_list_problems('    "REQ-018.7": "gap: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-018.70": "gap: x",\n'), [])


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

    def test_a_judge_that_forgets_a_run_that_ended_by_itself_is_caught(self):
        got = self.run_mutated("        if ($run.Done -eq $true) {", "        if ($false) {", ["cap_done_within_the_window"])
        self.assertEqual(got["cap_done_within_the_window"], [])

    def test_a_judge_that_forgets_the_upper_edge_is_caught(self):
        got = self.run_mutated("        } elseif ($run.Span -gt $upper) {", "        } elseif ($false) {", ["cap_span_over_the_window"])
        self.assertEqual(got["cap_span_over_the_window"], [])

    def test_a_judge_that_forgets_the_lower_edge_is_caught(self):
        got = self.run_mutated("        } elseif ($run.Span -lt $lower) {", "        } elseif ($false) {", ["cap_span_under_the_window"])
        self.assertEqual(got["cap_span_under_the_window"], [])

    def test_a_judge_that_forgets_the_leftover_process_is_caught(self):
        got = self.run_mutated("    } elseif (@($Orphans).Count -gt 0) {", "    } elseif ($false) {", ["cap_orphan_left"])
        self.assertEqual(got["cap_orphan_left"], [])

    def test_a_judge_that_forgets_the_timeout_line_is_caught(self):
        got = self.run_mutated("    if ($RepairLogged -and (-not $TimedOutAfterRepair)) {", "    if ($false) {", ["cap_not_timed_out_after_repair"])
        self.assertEqual(got["cap_not_timed_out_after_repair"], [])

    def test_a_judge_that_counts_runs_of_the_interpreter_is_caught(self):
        got = self.run_mutated("($_.Frozen -eq $true) -and ($_.Imported -eq $true)", "($_.Imported -eq $true)", ["cap_a_run_of_the_interpreter_is_not_counted"])
        self.assertEqual(got["cap_a_run_of_the_interpreter_is_not_counted"], [])

    def test_a_fact_that_ignores_the_order_of_the_two_lines_is_caught(self):
        got = self.run_mutated(" -and ($timeout.Index -gt $repair.Index)", "", ["facts_timeout_before_repair"])
        self.assertEqual(got["facts_timeout_before_repair"], [{"repairLogged": True, "timedOutAfterRepair": True}])

    def test_a_summary_that_stops_counting_ticks_is_caught(self):
        got = self.run_mutated("            $acc['Ticks'] = [int]$acc['Ticks'] + 1", "            $acc['Ticks'] = 0", ["starts_three"])
        self.assertEqual([s["Ticks"] for s in got["starts_three"]], [0, 0, 0])


if __name__ == "__main__":
    unittest.main()
