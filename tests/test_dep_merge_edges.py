"""Item 106 (README REQ-005.1.6, REQ-005.1.12, REQ-005.1.13 and REQ-005.1.14): the edges of the dependency-list merge.

Four shalls of the merge had no row able to fail for them: a failed install records nothing, so the next run sees the same
changes again (REQ-005.1.6); a PEP 723 header the user wrote is only added to, never removed from (REQ-005.1.12); and when the
merge cannot run, the bootstrapper warns, uses the highest ranked list alone and still finishes the run (REQ-005.1.13 and
REQ-005.1.14). tests/selfapps_dep_merge_edges.ps1 (four rows, self.depmerge.failed.records, .header.userwrote,
.fallback.emit and .fallback.helper; contract-uv lane, gating) runs seven real bootstraps of small folders for them.

What really happens is shown on Windows by that script. These rules read run_setup.bat, tools/dep_merge.py, the script,
batch-check.yml, docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, run the real helper on the inputs of each
scenario (the report and the error line it writes are what the script's fact patterns must recognise), and run the script's own
judging functions through a real pwsh on synthetic runs, so a reworded log line, a merge flow that no longer falls back, a
scenario that stops being the one the shall names, a judge that stops judging or a step that stops gating fails here with a
sentence, before a 40 minute Windows run is needed. Synthetic cases prove each rule can fail.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
HELPER = REPO / "tools" / "dep_merge.py"
SCRIPT = REPO / "tests" / "selfapps_dep_merge_edges.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

# (row id, the README requirements the row names, exactly as the script writes the tag)
ROWS = (
    ("self.depmerge.failed.records", "REQ-005.1.6"),
    ("self.depmerge.header.userwrote", "REQ-005.1.12"),
    ("self.depmerge.fallback.emit", "REQ-005.1.13, REQ-005.1.14"),
    ("self.depmerge.fallback.helper", "REQ-005.1.13, REQ-005.1.14"),
)
GAP_SHALLS = ("REQ-005.1.6", "REQ-005.1.12", "REQ-005.1.13", "REQ-005.1.14")

# The call that decides each row (the judge), in the order the rows are written. The verdict of a row is the problems of its judge.
JUDGE_CALLS = (
    "$problems = @(Get-FailedRecordsProblems -R1 $r1 -R2 $r2 -R3 $r3)",
    "$problems = @(Get-UserHeaderProblems -R1 $ru1 -R2 $ru2)",
    "$problems = @(Get-FallbackProblems -Variant 'emit' -R $rx)",
    "$problems = @(Get-FallbackProblems -Variant 'helper' -R $rh)",
)

# The variables every bootstrap of the script sets (value) or clears (empty), so the runner's own settings cannot decide for it.
RUN_VARIABLES = (
    "HP_SKIP_ENTRY_SMOKE = '1'", "HP_SKIP_EXE_SMOKERUN = '1'", "HP_SKIP_AUTOPEP_DISCOVERY = '1'", "HP_SKIP_NIVISA = '1'",
    "HP_SKIP_PIPREQS = ''", "HP_SKIP_PEP723_WRITEBACK = ''", "HP_TEST_FORCE_EMIT_FAIL = ''",
)

# Every fact the script reads from a run, the text that makes it true as the real run prints it, where the text is written and the
# anchor that has to stay a live line there. (fact, sample, which log, source file, anchor)
# A line the batch file writes through :log reaches the console AND the setup log with a time stamp in front; the helper's report
# is shown with type, so it reaches the console and the setup log as it is.
STAMP = "Fri 11/13/2026 19:40:00.12 "
FACT_CASES = (
    ("removedTermcolor", "[INFO] Removed termcolor: you removed it from requirements.txt since the last run, so it is removed everywhere.",
     "Console", "helper", "[INFO] Removed %s: you removed it from %s since the last run, so it is removed everywhere."),
    ("removedIniconfig", "[INFO] Removed iniconfig: you removed it from the PEP 723 header and requirements.txt since the last run, so it is removed everywhere.",
     "Console", "helper", "[INFO] Removed %s: you removed it from %s since the last run, so it is removed everywhere."),
    ("headerRemovedLogged", STAMP + "[INFO] Removed iniconfig from the PEP 723 header.",
     "Console", "batch", 'call :log "[INFO] Removed %~1 from the PEP 723 header."'),
    ("staysHeader", "[WARN] iniconfig was removed from requirements.txt but the PEP 723 header still lists it, so it stays. Remove it there too.",
     "Console", "helper", "[WARN] %s was removed from %s but %s still lists it, so it stays. Remove it there too."),
    ("installFailed", STAMP + "[WARN] uv pip install -r requirements.txt failed; some packages may be missing.",
     "Console", "batch", 'call :log "[WARN] uv pip install -r requirements.txt failed; some packages may be missing."'),
    ("writebackSkippedInstall", STAMP + "[INFO] REQ-005.11: PEP 723 write-back skipped (dependency install did not fully succeed).",
     "Console", "batch", 'call :log "[INFO] REQ-005.11: PEP 723 write-back skipped (dependency install did not fully succeed)."'),
    ("writebackSkippedFlag", STAMP + "[INFO] REQ-005.11: PEP 723 write-back skipped (HP_SKIP_PEP723_WRITEBACK set).",
     "Console", "batch", 'call :log "[INFO] REQ-005.11: PEP 723 write-back skipped (HP_SKIP_PEP723_WRITEBACK set)."'),
    ("writebackSucceeded", STAMP + "[INFO] REQ-005.11: PEP 723 header write-back succeeded via uv add --script.",
     "Console", "batch", 'call :log "[INFO] REQ-005.11: PEP 723 header write-back succeeded via uv add --script."'),
    ("recordedLine", STAMP + "[INFO] Dependency lists recorded for the next run: later changes to them are treated as yours.",
     "Console", "batch", 'call :log "[INFO] Dependency lists recorded for the next run: later changes to them are treated as yours."'),
    ("mergedLine", "[INFO] Dependency lists merged: requirements.txt 1, pyproject.toml 1; 2 packages.",
     "Console", "helper", "[INFO] Dependency lists merged: %s; %d packages."),
    ("couldNotMergeConsole", "*** [WARN] The dependency lists could not be merged, so only the highest ranked one is used: the PEP 723 header, then pyproject.toml, then requirements.txt.",
     "Console", "batch", "echo *** [WARN] The dependency lists could not be merged, so only the highest ranked one is used"),
    ("couldNotMergeSetup", STAMP + "[WARN] The dependency lists could not be merged; using the highest ranked list only.",
     "Setup", "batch", 'call :log "[WARN] The dependency lists could not be merged; using the highest ranked list only."'),
    ("forcedEmitFailure", STAMP + "[TEST] HP_TEST_FORCE_EMIT_FAIL=HP_DEP_MERGE: simulating embedded helper write failure.",
     "Setup", "batch", 'call :log "[TEST] HP_TEST_FORCE_EMIT_FAIL=%VAR%: simulating embedded helper write failure."'),
    ("helperError", "dep_merge: [WinError 32] The process cannot access the file because it is being used by another process: '~requirements.merge.tmp'",
     "Setup", "helper", 'sys.stderr.write("dep_merge: %s\\n"'),
)
FACT_NAMES = [case[0] for case in FACT_CASES]

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~selftest_dmedge_*/~dme_*.log",
    "tests/~selftest_dmedge_*/~setup.log",
    "tests/~selftest_dmedge_*/~dep_base.*.txt",
    "tests/~selftest_dmedge_*/requirements.txt",
    "tests/~selftest_dmedge_*/app.py",
    "tests/~selftest_dmedge_*/~bootstrap.status.json",
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
    """The lines of a PowerShell or Python file that are not blank and not a comment line."""
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


# --- the batch file and the helper: what the script assumes about them --------------------------------------------------------

def label_problems(batch):
    lines = [ln.strip() for ln in lines_of(batch)]
    found = []
    for label in (":dep_merge_inputs", ":dm_merge", ":dm_fallback", ":dm_single", ":dm_copy_one", ":dep_merge_snapshot",
                  ":dep_merge_header_remove", ":emit_from_base64", ":pep723_writeback"):
        n = sum(1 for ln in lines if ln == label)
        if n != 1:
            found.append("the label %s appears %d time(s); expected exactly once" % (label, n))
    return found


def flow_problems(batch):
    """README REQ-005.1.13 and .14 in the batch file: any failure of the merge helper, whether it could not be written, could not
    run or ended with an error, goes to :dm_fallback, which warns on the console and in the setup log, falls through to the old
    single-list copy and returns to the caller, which goes on."""
    found = []
    merge = cut_block(batch, ":dm_merge", ":dm_fallback")
    if merge is None:
        return ["the block from :dm_merge to :dm_fallback cannot be cut"]
    body = [ln.strip() for ln in live_bat(merge)]
    emit = 'call :emit_from_base64 "~dep_merge.py" HP_DEP_MERGE'
    at = body.index(emit) if emit in body else -1
    if at < 0:
        found.append("the merge block no longer emits the helper with %r" % emit)
    elif at + 1 >= len(body) or body[at + 1] != "if errorlevel 1 goto :dm_fallback":
        found.append("a helper that cannot be written (the emit above failed) no longer goes straight to :dm_fallback")
    wipe = next((ln for ln in body if ln.startswith("for %%F in (") and "~requirements.merge.tmp" in ln), None)
    if wipe is None or 'del "%%F"' not in wipe:
        found.append("no live line deletes ~requirements.merge.tmp (with del) before the helper runs, the file the helper writes its result to")
    run = '"%HP_PY%" "~dep_merge.py" >> "%LOG%" 2>&1'
    order = ['set "HP_DM_RC=%ERRORLEVEL%"', 'if "%HP_DM_RC%"=="1" goto :dm_single', 'if not "%HP_DM_RC%"=="0" goto :dm_fallback']
    if run not in body:
        found.append("the helper is no longer run as %r, so its error line no longer reaches the setup log" % run)
    else:
        rest = body[body.index(run) + 1:]
        positions = [rest.index(o) if o in rest else -1 for o in order]
        if -1 in positions or positions != sorted(positions):
            found.append("after the helper runs, the result is no longer read and sent on as: %s" % "; ".join(order))
        if wipe is not None and body.index(wipe) > body.index(run):
            found.append("the temporary file is deleted after the helper ran instead of before")
    fall = cut_block(batch, ":dm_fallback", ":dm_single")
    if fall is None:
        found.append("the block from :dm_fallback to :dm_single cannot be cut")
    else:
        lines = [ln.strip() for ln in live_bat(fall)]
        warn = [ln for ln in lines if ln.startswith("echo *** [WARN] The dependency lists could not be merged, so only the highest ranked one is used")]
        logged = [ln for ln in lines if ln == 'call :log "[WARN] The dependency lists could not be merged; using the highest ranked list only."']
        if len(warn) != 1:
            found.append(":dm_fallback has %d console warning line(s); expected exactly 1" % len(warn))
        if len(logged) != 1:
            found.append(":dm_fallback has %d setup log line(s); expected exactly 1" % len(logged))
        for ln in lines:
            if re.match(r"(?i)(exit\b|goto\b|call :die\b)", ln) or "call :die" in ln.lower():
                found.append(":dm_fallback stops or jumps (%r), but the run has to go on with the highest ranked list" % ln[:60])
    single = cut_block(batch, ":dm_single", ":dm_copy_one")
    if single is None:
        found.append("the block from :dm_single to :dm_copy_one cannot be cut")
    else:
        lines = [ln.strip() for ln in live_bat(single)]
        want = ['if defined HP_PYPROJ_ACTIVE call :dm_copy_one "~requirements.pyproject.txt"', 'if defined PEP723_ACTIVE call :dm_copy_one "%PEP723_REQ%"', "exit /b 0"]
        if lines[1:] != want:
            found.append(":dm_single is not the copy of the highest ranked list (pyproject.toml, then the header) followed by exit /b 0: %s" % lines[1:])
    live = [ln.strip() for ln in live_bat(lines_of(batch))]
    calls = [i for i, ln in enumerate(live) if ln == "call :dep_merge_inputs"]
    if len(calls) != 1:
        found.append("the merge is called %d times from the main flow; expected once" % len(calls))
    else:
        for ln in live[calls[0] + 1:calls[0] + 3]:
            if re.search(r"(?i)errorlevel|exit\b|goto\b|call :die", ln) and not ln.startswith("set "):
                found.append("the call of :dep_merge_inputs is followed by %r, which may stop the run after a failed merge" % ln[:60])
    hook = 'call :log "[TEST] HP_TEST_FORCE_EMIT_FAIL=%VAR%: simulating embedded helper write failure."'
    emit_live = live
    if emit_live.count(hook) != 1 or emit_live[emit_live.index(hook) + 1] != "exit /b 1":
        found.append("the forced write failure of a payload is no longer a logged line followed by exit /b 1 in :emit_from_base64")
    return found


def snapshot_problems(batch):
    """README REQ-005.1.6 and .12 in the batch file: nothing is recorded after a failed install or after a header that was ours
    and was not brought up to date, and a header record exists only when this run wrote the header."""
    found = []
    block = cut_block(batch, ":dep_merge_snapshot", ":determine_entry")
    if block is None:
        return ["the block from :dep_merge_snapshot to :determine_entry cannot be cut"]
    body = [ln.strip() for ln in live_bat(block)]
    marks = {
        "install": "if defined HP_DM_INSTALL_FAILED exit /b 0",
        "errorstate": 'if /I "%HP_BOOTSTRAP_STATE%"=="error" exit /b 0',
        "hdrnotupdated": "if defined HP_DM_HAD_HDR_BASE if not defined HP_DM_HDR_WRITTEN exit /b 0",
        "first_copy": 'if exist "requirements.txt" copy /y "requirements.txt" "~dep_base.requirements.txt" >nul 2>&1',
        "hdr_record": 'if defined HP_DM_HDR_WRITTEN call :extract_pep723_requirements "%HP_ENTRY%" "~dep_base.pep723.txt"',
        "recorded": 'call :log "[INFO] Dependency lists recorded for the next run: later changes to them are treated as yours."',
    }
    index = {}
    for key, text in marks.items():
        if body.count(text) != 1:
            found.append("the snapshot block has %d live line(s) %r; expected exactly 1" % (body.count(text), text[:80]))
        else:
            index[key] = body.index(text)
    if len(index) == len(marks):
        for before, after in (("install", "first_copy"), ("errorstate", "first_copy"), ("hdrnotupdated", "first_copy"),
                              ("first_copy", "hdr_record"), ("hdr_record", "recorded")):
            if index[before] > index[after]:
                found.append("%s comes after %s in :dep_merge_snapshot; the guards have to come before anything is recorded" % (before, after))
    writers = [ln for ln in body if "~dep_base.pep723.txt" in ln and "del " not in ln]
    if writers != [marks["hdr_record"]]:
        found.append("the header record is written by %d line(s) other than the one guarded by HP_DM_HDR_WRITTEN: %s" % (len(writers) - 1, writers))
    sites = [i for i, ln in enumerate(live_bat(lines_of(batch))) if ln.strip() == 'set "HP_DM_INSTALL_FAILED=1"']
    if len(sites) < 5:
        found.append("only %d live line(s) set HP_DM_INSTALL_FAILED; every install failure site (conda, venv, uv, embed, system) has to set it" % len(sites))
    live = [ln.strip() for ln in live_bat(lines_of(batch))]
    failed = 'call :log "[WARN] uv pip install -r requirements.txt failed; some packages may be missing."'
    uv_sites = [i for i, ln in enumerate(live) if ln == failed and i > 0 and live[i - 1] == 'set "HP_DM_INSTALL_FAILED=1"']
    if len(uv_sites) != 1:
        found.append("the uv install failure line follows 'set HP_DM_INSTALL_FAILED=1' %d time(s); expected exactly 1" % len(uv_sites))
    return found


def source_problems(batch, helper):
    """Every text the script's facts look for is still written by a live line of the batch file or the helper."""
    found = []
    live_batch = [ln.strip() for ln in live_bat(lines_of(batch))]
    live_helper = live_hash(helper)
    for fact, _sample, _log, where, anchor in FACT_CASES:
        lines = live_batch if where == "batch" else live_helper
        if not any(anchor in ln for ln in lines):
            found.append("%s: no live line of %s holds %r" % (fact, "run_setup.bat" if where == "batch" else "tools/dep_merge.py", anchor))
    if not any(ln.startswith("sys.exit(3)") for ln in live_helper):
        found.append("the helper no longer exits 3 after an error, the code that sends the batch file to :dm_fallback")
    if not any(ln.startswith("except Exception as exc") for ln in live_helper):
        found.append("the helper no longer turns every error into its own error line")
    if not any(ln == 'tmp = "~requirements.merge.tmp"' for ln in live_helper):
        found.append("the helper no longer writes its result to ~requirements.merge.tmp")
    return found


# --- the script: its own rules -------------------------------------------------------------------------------------------

def script_problems(text):
    text = norm(text)
    found = []
    live = live_hash(text)
    for row_id, req in ROWS:
        call = "Write-DmRow -Id '%s' -Tag @{ req = '%s' } -Pass ([bool]$pass)" % (row_id, req)
        if text.count(call) != 1:
            found.append("%s is not written exactly once with a literal id, the tag '%s' and the verdict in $pass" % (row_id, req))
    ids = re.search(r"\$allIds = @\((.*?)\)\n", text)
    got = re.findall(r"'([^']+)'", ids.group(1)) if ids else None
    if got != [r[0] for r in ROWS]:
        found.append("the skip table $allIds holds %s; expected %s" % (got, [r[0] for r in ROWS]))
    req_of = re.search(r"\$reqOf = @\{\n(.*?)\n\}\n", text, re.S)
    pairs = re.findall(r"'([^']+)' = '([^']+)'", req_of.group(1)) if req_of else None
    if pairs != list(ROWS):
        found.append("the skip table $reqOf holds %s; expected %s" % (pairs, list(ROWS)))
    for n, call in enumerate(JUDGE_CALLS):
        row_id = ROWS[n][0]
        if text.count(call) != 1:
            found.append("the judge call %r appears %d time(s); expected exactly once" % (call, text.count(call)))
            continue
        after = text.split(call, 1)[1]
        chain = "\n$pass = ($problems.Count -eq 0)\nif (-not $pass) { $anyRed = $true }\n"
        if not after.startswith(chain):
            found.append("%s: the lines after the judge call are not the verdict ($pass from the problems) and the red flag" % row_id)
        write = "Write-DmRow -Id '%s'" % row_id
        nearest = after.find("Write-DmRow -Id '")
        if nearest < 0 or not after[nearest:].startswith(write):
            found.append("%s: the next row written after its judge call is not its own" % row_id)
    for name in RUN_VARIABLES:
        if text.count(name) != 1:
            found.append("the bootstrap wrapper does not set %s exactly once (the runner's own value must not decide)" % name)
    for needle, why in (
        ('"call run_setup.bat app.py > $logName 2>&1 < nul"', "the launch does not close standard input (< nul)"),
        ("& taskkill.exe /F /T /PID $p.Id", "a run past the time limit is not stopped with taskkill /F /T"),
        ("$runTimeoutMs = 12 * 60 * 1000", "a run has no 12 minute limit"),
        ("$p.WaitForExit($runTimeoutMs)", "the wait is not bounded by the limit"),
        ("function Test-SameNames", "the script has no Test-SameNames"),
        ("function Get-DmFacts", "the script has no Get-DmFacts"),
        ("function Get-FailedRecordsProblems", "the script has no Get-FailedRecordsProblems"),
        ("function Get-UserHeaderProblems", "the script has no Get-UserHeaderProblems"),
        ("function Get-FallbackProblems", "the script has no Get-FallbackProblems"),
        ("'non-windows-host'", "the script has no skip path off Windows"),
        ("[System.IO.File]::WriteAllText((Join-Path $dirF 'requirements.txt'), \"iniconfig`nsix==999.0.0`n\", $utf8)",
         "scenario F no longer replaces requirements.txt by the list without termcolor and with a pin no index can satisfy"),
        ("$f3 = Invoke-Run -Dir $dirF -Label 'f3' -ForceFlow", "the third run of scenario F is not forced through the whole dependency flow"),
        ("$u1 = Invoke-Run -Dir $dirU -Label 'u1' -Env @{ HP_SKIP_PEP723_WRITEBACK = '1' }", "scenario U no longer switches the header write-back off in its first run"),
        ("-Label 'x1' -Env @{ HP_TEST_FORCE_EMIT_FAIL = 'HP_DEP_MERGE' }", "scenario X no longer makes the helper's write fail"),
        ("[System.IO.File]::Open((Join-Path $dirH '~requirements.merge.tmp'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)",
         "scenario H no longer holds ~requirements.merge.tmp open without sharing"),
        ("if ($null -ne $lockH) { $lockH.Dispose() }", "scenario H never releases the lock it holds"),
        ("lockHeld = [bool]($null -ne $lockH)", "the row does not record that the lock was held"),
    ):
        if needle not in text:
            found.append(why)
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0 (last live line: %r)" % (live[-1] if live else ""))
    if "if ($anyRed) { exit 1 }" not in live:
        found.append("the script never exits 1 when a row is red")
    if any(ord(c) > 126 for c in text):
        found.append("the script holds a character that is not ASCII")
    return found


# --- the workflow, the registry and the shall list --------------------------------------------------------------------------

def step_block(text):
    lines = norm(text).split("\n")
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if "selfapps_dep_merge_edges.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_dep_merge_edges.ps1"]
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
    registered = registry_ids(text)
    return ["%s is not in docs/agent-ndjson.md" % row_id for row_id, _req in ROWS if row_id not in registered]


def shall_list_problems(text):
    """The shalls the rows trace are no longer listed as gaps (the shall-level ratchet only warns about a stale entry)."""
    return ["%s is still listed in UNTRACED_SHALLS although a row is tagged with it" % shall
            for shall in GAP_SHALLS if re.search(r'^\s*"%s":' % re.escape(shall), text, re.M)]


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

JUDGES = ["Test-SameNames", "Get-DmFacts", "Get-FailedRecordsProblems", "Get-UserHeaderProblems", "Get-FallbackProblems"]


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


def facts(**on):
    """All facts of a run, false except the named ones (the judges read every one, and strict mode 1.0 would not stop a missing one)."""
    out = {name: False for name in FACT_NAMES}
    for key, value in on.items():
        assert key in out, key
        out[key] = value
    return out


def f_first(**over):
    run = dict(Finished=True, Exit=0, State="ok", ReqNames=["termcolor", "iniconfig"], HdrNames=["termcolor", "iniconfig"],
               Facts=facts(recordedLine=True, mergedLine=True), RecReq=["termcolor", "iniconfig"], RecPy=["iniconfig"],
               RecHdr=["termcolor", "iniconfig"])
    run.update(over)
    return run


def f_failed(**over):
    run = dict(Finished=True, Facts=facts(removedTermcolor=True, installFailed=True, writebackSkippedInstall=True, mergedLine=True),
               RecReqKept=True, RecPyKept=True, RecHdrKept=True)
    run.update(over)
    return run


def u_first(**over):
    run = dict(Finished=True, Exit=0, State="ok", Facts=facts(writebackSkippedFlag=True, mergedLine=True), HeaderTextSame=True,
               RecReq=["termcolor", "iniconfig"], HdrRecordExists=False)
    run.update(over)
    return run


def u_second(**over):
    run = dict(Finished=True, Exit=0, State="ok", Facts=facts(writebackSucceeded=True, staysHeader=True, mergedLine=True),
               HdrNames=["iniconfig", "termcolor"], ReqNames=["iniconfig", "termcolor"])
    run.update(over)
    return run


def fb_run(variant, **over):
    on = {"couldNotMergeConsole": True, "couldNotMergeSetup": True}
    on["forcedEmitFailure" if variant == "emit" else "helperError"] = True
    run = dict(Finished=True, Exit=0, State="ok", Facts=facts(**on), ReqNames=["iniconfig"], Installed=["iniconfig", "uv"])
    run.update(over)
    return run


def with_facts(run, **on):
    """The same run with some facts changed (the base facts of the run stay)."""
    merged = dict(run["Facts"])
    for key, value in on.items():
        assert key in merged, key
        merged[key] = value
    out = dict(run)
    out["Facts"] = merged
    return out


def case(name, fn, **args):
    return {"name": name, "fn": fn, "args": args}


def judge_cases():
    c = []
    # --- scenario F, REQ-005.1.6
    c.append(case("f_good", "Get-FailedRecordsProblems", R1=f_first(), R2=f_failed(), R3=f_failed()))
    c.append(case("f_r1_unfinished", "Get-FailedRecordsProblems", R1=f_first(Finished=False), R2=f_failed(), R3=f_failed()))
    c.append(case("f_r3_unfinished", "Get-FailedRecordsProblems", R1=f_first(), R2=f_failed(), R3=f_failed(Finished=False)))
    c.append(case("f_first_run_exit_1", "Get-FailedRecordsProblems", R1=f_first(Exit=1), R2=f_failed(), R3=f_failed()))
    c.append(case("f_first_run_state_error", "Get-FailedRecordsProblems", R1=f_first(State="error"), R2=f_failed(), R3=f_failed()))
    c.append(case("f_first_requirements_short", "Get-FailedRecordsProblems", R1=f_first(ReqNames=["termcolor"]), R2=f_failed(), R3=f_failed()))
    c.append(case("f_first_header_missing", "Get-FailedRecordsProblems", R1=f_first(HdrNames=[]), R2=f_failed(), R3=f_failed()))
    c.append(case("f_first_not_recorded_line", "Get-FailedRecordsProblems", R1=with_facts(f_first(), recordedLine=False), R2=f_failed(), R3=f_failed()))
    c.append(case("f_first_record_requirements_missing", "Get-FailedRecordsProblems", R1=f_first(RecReq=None), R2=f_failed(), R3=f_failed()))
    c.append(case("f_first_record_pyproject_wrong", "Get-FailedRecordsProblems", R1=f_first(RecPy=["iniconfig", "termcolor"]), R2=f_failed(), R3=f_failed()))
    c.append(case("f_first_record_header_missing", "Get-FailedRecordsProblems", R1=f_first(RecHdr=None), R2=f_failed(), R3=f_failed()))
    for run in ("R2", "R3"):
        other = "R3" if run == "R2" else "R2"
        base = {other: f_failed()}
        c.append(case("f_%s_no_removal_seen" % run.lower(), "Get-FailedRecordsProblems", R1=f_first(), **dict(base, **{run: with_facts(f_failed(), removedTermcolor=False)})))
        c.append(case("f_%s_install_did_not_fail" % run.lower(), "Get-FailedRecordsProblems", R1=f_first(), **dict(base, **{run: with_facts(f_failed(), installFailed=False)})))
        c.append(case("f_%s_recorded_after_failure" % run.lower(), "Get-FailedRecordsProblems", R1=f_first(), **dict(base, **{run: with_facts(f_failed(), recordedLine=True)})))
        c.append(case("f_%s_requirements_record_changed" % run.lower(), "Get-FailedRecordsProblems", R1=f_first(), **dict(base, **{run: f_failed(RecReqKept=False)})))
        c.append(case("f_%s_pyproject_record_changed" % run.lower(), "Get-FailedRecordsProblems", R1=f_first(), **dict(base, **{run: f_failed(RecPyKept=False)})))
        c.append(case("f_%s_header_record_changed" % run.lower(), "Get-FailedRecordsProblems", R1=f_first(), **dict(base, **{run: f_failed(RecHdrKept=False)})))
    c.append(case("f_r2_writeback_not_skipped", "Get-FailedRecordsProblems", R1=f_first(), R2=with_facts(f_failed(), writebackSkippedInstall=False), R3=f_failed()))
    c.append(case("f_r3_writeback_not_judged", "Get-FailedRecordsProblems", R1=f_first(), R2=f_failed(), R3=with_facts(f_failed(), writebackSkippedInstall=False)))
    # --- scenario U, REQ-005.1.12
    c.append(case("u_good", "Get-UserHeaderProblems", R1=u_first(), R2=u_second()))
    c.append(case("u_r1_unfinished", "Get-UserHeaderProblems", R1=u_first(Finished=False), R2=u_second()))
    c.append(case("u_r2_unfinished", "Get-UserHeaderProblems", R1=u_first(), R2=u_second(Finished=False)))
    c.append(case("u_first_exit_1", "Get-UserHeaderProblems", R1=u_first(Exit=1), R2=u_second()))
    c.append(case("u_first_writeback_not_switched_off", "Get-UserHeaderProblems", R1=with_facts(u_first(), writebackSkippedFlag=False), R2=u_second()))
    c.append(case("u_first_header_text_changed", "Get-UserHeaderProblems", R1=u_first(HeaderTextSame=False), R2=u_second()))
    c.append(case("u_first_record_of_requirements_missing", "Get-UserHeaderProblems", R1=u_first(RecReq=None), R2=u_second()))
    c.append(case("u_first_header_record_exists", "Get-UserHeaderProblems", R1=u_first(HdrRecordExists=True), R2=u_second()))
    c.append(case("u_second_exit_1", "Get-UserHeaderProblems", R1=u_first(), R2=u_second(Exit=1)))
    c.append(case("u_second_state_error", "Get-UserHeaderProblems", R1=u_first(), R2=u_second(State="error")))
    c.append(case("u_second_writeback_did_not_run", "Get-UserHeaderProblems", R1=u_first(), R2=with_facts(u_second(), writebackSucceeded=False)))
    c.append(case("u_second_no_stays_line", "Get-UserHeaderProblems", R1=u_first(), R2=with_facts(u_second(), staysHeader=False)))
    c.append(case("u_second_removed_everywhere_line", "Get-UserHeaderProblems", R1=u_first(), R2=with_facts(u_second(), removedIniconfig=True)))
    c.append(case("u_second_removed_from_header", "Get-UserHeaderProblems", R1=u_first(), R2=with_facts(u_second(), headerRemovedLogged=True)))
    c.append(case("u_second_header_lost_iniconfig", "Get-UserHeaderProblems", R1=u_first(), R2=u_second(HdrNames=["termcolor"])))
    c.append(case("u_second_header_lost_termcolor", "Get-UserHeaderProblems", R1=u_first(), R2=u_second(HdrNames=["iniconfig"])))
    c.append(case("u_second_requirements_short", "Get-UserHeaderProblems", R1=u_first(), R2=u_second(ReqNames=["termcolor"])))
    # --- scenarios X and H, REQ-005.1.13 and REQ-005.1.14
    for variant in ("emit", "helper"):
        c.append(case("fb_%s_good" % variant, "Get-FallbackProblems", Variant=variant, R=fb_run(variant)))
        c.append(case("fb_%s_unfinished" % variant, "Get-FallbackProblems", Variant=variant, R=fb_run(variant, Finished=False)))
        c.append(case("fb_%s_merged_line" % variant, "Get-FallbackProblems", Variant=variant, R=with_facts(fb_run(variant), mergedLine=True)))
        c.append(case("fb_%s_no_console_warn" % variant, "Get-FallbackProblems", Variant=variant, R=with_facts(fb_run(variant), couldNotMergeConsole=False)))
        c.append(case("fb_%s_no_setup_warn" % variant, "Get-FallbackProblems", Variant=variant, R=with_facts(fb_run(variant), couldNotMergeSetup=False)))
        c.append(case("fb_%s_requirements_both" % variant, "Get-FallbackProblems", Variant=variant, R=fb_run(variant, ReqNames=["iniconfig", "termcolor"])))
        c.append(case("fb_%s_requirements_none" % variant, "Get-FallbackProblems", Variant=variant, R=fb_run(variant, ReqNames=None)))
        c.append(case("fb_%s_iniconfig_not_installed" % variant, "Get-FallbackProblems", Variant=variant, R=fb_run(variant, Installed=["uv"])))
        c.append(case("fb_%s_termcolor_installed" % variant, "Get-FallbackProblems", Variant=variant, R=fb_run(variant, Installed=["iniconfig", "termcolor"])))
        c.append(case("fb_%s_exit_1" % variant, "Get-FallbackProblems", Variant=variant, R=fb_run(variant, Exit=1)))
        c.append(case("fb_%s_state_error" % variant, "Get-FallbackProblems", Variant=variant, R=fb_run(variant, State="error")))
    c.append(case("fb_emit_forced_failure_not_logged", "Get-FallbackProblems", Variant="emit", R=with_facts(fb_run("emit"), forcedEmitFailure=False)))
    c.append(case("fb_helper_error_not_logged", "Get-FallbackProblems", Variant="helper", R=with_facts(fb_run("helper"), helperError=False)))
    # the other variant's precondition does not count: a helper run with only the forced-write line is not a helper failure
    c.append(case("fb_helper_only_forced_line", "Get-FallbackProblems", Variant="helper", R=with_facts(fb_run("helper"), helperError=False, forcedEmitFailure=True)))
    # --- Test-SameNames
    c.append(case("names_same", "Test-SameNames", Actual=["Termcolor", "iniconfig"], Expected=["iniconfig", "termcolor"]))
    c.append(case("names_extra", "Test-SameNames", Actual=["termcolor", "iniconfig", "six"], Expected=["iniconfig", "termcolor"]))
    c.append(case("names_missing", "Test-SameNames", Actual=["termcolor"], Expected=["iniconfig", "termcolor"]))
    c.append(case("names_none", "Test-SameNames", Actual=None, Expected=["iniconfig"]))
    c.append(case("names_empty_is_not_none", "Test-SameNames", Actual=[], Expected=[]))
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

    def has(self, name, needle):
        found = self.r[name]
        self.assertTrue(any(needle in f for f in found), (name, needle, found))

    def only(self, name, needle):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        self.assertIn(needle, found[0], (name, found))

    def test_a_clean_run_of_every_scenario_has_no_problem(self):
        for name in ("f_good", "u_good", "fb_emit_good", "fb_helper_good"):
            self.assertEqual(self.r[name], [], name)

    def test_a_run_that_did_not_finish_is_one_problem_and_nothing_else(self):
        self.only("f_r1_unfinished", "F1: the bootstrap did not finish")
        self.only("f_r3_unfinished", "F3: the bootstrap did not finish")
        self.only("u_r1_unfinished", "U1: the bootstrap did not finish")
        self.only("u_r2_unfinished", "U2: the bootstrap did not finish")
        self.only("fb_emit_unfinished", "emit: the bootstrap did not finish")
        self.only("fb_helper_unfinished", "helper: the bootstrap did not finish")

    def test_scenario_f_names_the_first_run_before_it_judges_the_failed_ones(self):
        self.only("f_first_run_exit_1", "F1: the first run did not end ok")
        self.only("f_first_run_state_error", "F1: the first run did not end ok")
        self.only("f_first_requirements_short", "F1: requirements.txt does not hold the merged list")
        self.only("f_first_header_missing", "F1: the PEP 723 header does not hold the merged list")
        self.only("f_first_not_recorded_line", "F1: the run did not say that it recorded the lists")
        self.only("f_first_record_requirements_missing", "F1: ~dep_base.requirements.txt is missing")
        self.only("f_first_record_pyproject_wrong", "F1: ~dep_base.pyproject.txt is missing or does not hold")
        self.only("f_first_record_header_missing", "F1: ~dep_base.pep723.txt is missing")

    def test_a_failed_install_that_records_anything_is_named_for_each_record_and_run(self):
        for run in ("R2", "R3"):
            tag = run.lower()
            label = {"R2": "F2", "R3": "F3"}[run]
            self.only("f_%s_no_removal_seen" % tag, "%s: the merge did not report the removal of termcolor" % label)
            self.only("f_%s_install_did_not_fail" % tag, "%s: the install did not fail" % label)
            self.only("f_%s_recorded_after_failure" % tag, "%s: the run said it recorded the lists" % label)
            self.only("f_%s_requirements_record_changed" % tag, "%s: ~dep_base.requirements.txt changed" % label)
            self.only("f_%s_pyproject_record_changed" % tag, "%s: ~dep_base.pyproject.txt changed" % label)
            self.only("f_%s_header_record_changed" % tag, "%s: ~dep_base.pep723.txt changed" % label)

    def test_the_skipped_write_back_is_required_of_the_first_failed_run_only(self):
        self.only("f_r2_writeback_not_skipped", "F2: the header write-back was not reported as skipped")
        self.assertEqual(self.r["f_r3_writeback_not_judged"], [])

    def test_scenario_u_requires_a_header_nobody_recorded_and_a_write_back_that_really_ran(self):
        self.only("u_first_exit_1", "U1: the first run did not end ok")
        self.only("u_first_writeback_not_switched_off", "U1: the header write-back was not reported as switched off")
        self.only("u_first_header_text_changed", "U1: the header text changed")
        self.only("u_first_record_of_requirements_missing", "U1: ~dep_base.requirements.txt is missing")
        self.only("u_first_header_record_exists", "U1: a record of the header exists")
        self.only("u_second_exit_1", "U2: the second run did not end ok")
        self.only("u_second_state_error", "U2: the second run did not end ok")
        self.only("u_second_writeback_did_not_run", "U2: the header write-back did not run and succeed")

    def test_scenario_u_requires_that_nothing_is_taken_out_of_the_users_header(self):
        self.only("u_second_no_stays_line", "U2: the console did not say that iniconfig stays")
        self.only("u_second_removed_everywhere_line", "U2: the console says iniconfig was removed everywhere")
        self.only("u_second_removed_from_header", "U2: iniconfig was removed from the PEP 723 header")
        self.only("u_second_header_lost_iniconfig", "U2: the header does not hold iniconfig (kept) and termcolor (added)")
        self.only("u_second_header_lost_termcolor", "U2: the header does not hold iniconfig (kept) and termcolor (added)")
        self.only("u_second_requirements_short", "U2: requirements.txt does not hold both packages again")

    def test_a_merge_that_cannot_run_must_warn_use_one_list_and_finish_the_run(self):
        for variant in ("emit", "helper"):
            self.only("fb_%s_merged_line" % variant, "%s: the console says the lists were merged" % variant)
            self.only("fb_%s_no_console_warn" % variant, "%s: the console has no [WARN]" % variant)
            self.only("fb_%s_no_setup_warn" % variant, "%s: the setup log has no [WARN]" % variant)
            self.only("fb_%s_requirements_both" % variant, "%s: requirements.txt is not the highest ranked list alone" % variant)
            self.only("fb_%s_requirements_none" % variant, "%s: requirements.txt is not the highest ranked list alone" % variant)
            self.only("fb_%s_iniconfig_not_installed" % variant, "%s: the highest ranked list's package (iniconfig) was not installed" % variant)
            self.only("fb_%s_termcolor_installed" % variant, "%s: termcolor was installed" % variant)
            self.only("fb_%s_exit_1" % variant, "%s: the run did not end ok (exit code 1" % variant)
            self.only("fb_%s_state_error" % variant, "%s: the run did not end ok" % variant)

    def test_each_variant_needs_its_own_proof_that_the_merge_was_made_to_fail(self):
        self.only("fb_emit_forced_failure_not_logged", "emit: the setup log has no line for the forced failure")
        self.only("fb_helper_error_not_logged", "helper: the setup log has no error line from the merge helper")
        self.only("fb_helper_only_forced_line", "helper: the setup log has no error line from the merge helper")

    def test_names_are_compared_without_case_or_order_and_a_missing_list_is_not_an_empty_one(self):
        self.assertEqual(self.r["names_same"], [True])
        self.assertEqual(self.r["names_extra"], [False])
        self.assertEqual(self.r["names_missing"], [False])
        self.assertEqual(self.r["names_none"], [False])
        self.assertEqual(self.r["names_empty_is_not_none"], [True])


class FactsMatchTheRealText(unittest.TestCase):
    """Get-DmFacts on the real words of the batch file and of the helper: each fact is true for its own text, false for an empty
    run, and no other fact is true for it (a pattern that matched everything would make every precondition meaningless)."""

    @classmethod
    def setUpClass(cls):
        cases = [case("empty", "Get-DmFacts", Console="", Setup="")]
        for fact, sample, which, _where, _anchor in FACT_CASES:
            args = {"Console": "", "Setup": ""}
            args[which] = sample
            cases.append(case("fact_" + fact, "Get-DmFacts", **args))
        cases.append(case("everything", "Get-DmFacts", Console="\n".join(c[1] for c in FACT_CASES if c[2] == "Console"),
                          Setup="\n".join(c[1] for c in FACT_CASES if c[2] == "Setup")))
        # a console line is not a setup log line: the same text in the other log does not count
        for fact, sample, which, _where, _anchor in FACT_CASES:
            other = "Setup" if which == "Console" else "Console"
            args = {"Console": "", "Setup": ""}
            args[other] = sample
            cases.append(case("wronglog_" + fact, "Get-DmFacts", **args))
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, ["Get-DmFacts"], cases, d)

    def test_an_empty_run_has_no_fact(self):
        self.assertEqual(self.r["empty"][0], {name: False for name in FACT_NAMES})

    def test_each_text_makes_its_own_fact_true_and_no_other(self):
        for fact, _sample, _which, _where, _anchor in FACT_CASES:
            with self.subTest(fact=fact):
                got = self.r["fact_" + fact][0]
                self.assertTrue(got[fact], got)
                # the removal report of the header-and-requirements case is also a removal of iniconfig and not of termcolor
                self.assertEqual([k for k, v in got.items() if v and k != fact], [], got)

    def test_all_texts_together_make_every_fact_true(self):
        self.assertEqual(self.r["everything"][0], {name: True for name in FACT_NAMES})

    def test_the_setup_log_facts_are_not_read_from_the_console_and_the_reverse(self):
        for fact, _sample, which, _where, _anchor in FACT_CASES:
            if fact in ("couldNotMergeSetup", "forcedEmitFailure", "helperError", "couldNotMergeConsole"):
                with self.subTest(fact=fact):
                    self.assertFalse(self.r["wronglog_" + fact][0][fact])


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


# --- the real helper on the inputs of each scenario ------------------------------------------------------------------------

def run_helper(files, dirs=()):
    """Run tools/dep_merge.py in a fresh folder holding the files (and empty folders); returns (exit code, stderr, files after)."""
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        for name, text in files.items():
            (root / name).write_text(text, encoding="utf-8", newline="\n")
        for name in dirs:
            (root / name).mkdir()
        proc = subprocess.run([sys.executable, "-I", str(HELPER)], cwd=str(root), capture_output=True, text=True, timeout=60)
        after = {}
        for entry in root.iterdir():
            if entry.is_file():
                after[entry.name] = entry.read_text(encoding="utf-8", errors="replace")
        return proc.returncode, proc.stderr, after


def names_of(text):
    return sorted(re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", ln).group(0).lower() for ln in text.splitlines() if ln.strip() and not ln.startswith("#"))


# What the batch file leaves in the folder after a good first run of scenario F (the merged list, the three records), and the
# folder of the next runs after the user changed requirements.txt (termcolor deleted, a pin nobody can install added).
F_AFTER_FIRST = {
    "~dep_base.requirements.txt": "termcolor\niniconfig\n", "~dep_base.pyproject.txt": "iniconfig\n",
    "~dep_base.pep723.txt": "termcolor>=3.2.0\niniconfig>=2.3.0\n",
}
F_FAILED_RUN = dict(F_AFTER_FIRST, **{
    "requirements.txt": "iniconfig\nsix==999.0.0\n", "~requirements.pyproject.txt": "iniconfig\n",
    "~requirements.pep723.txt": "termcolor>=3.2.0\niniconfig>=2.3.0\n",
})
# Scenario U: the header is the user's own (no record), the user deleted iniconfig from requirements.txt since the first run.
U_SECOND_RUN = {
    "requirements.txt": "termcolor\n", "~requirements.pep723.txt": "iniconfig\n", "~dep_base.requirements.txt": "termcolor\niniconfig\n",
}


class RealHelperOnTheScenarioInputs(unittest.TestCase):
    """What tools/dep_merge.py really says about the inputs of each scenario, and what the script's facts make of it."""

    @classmethod
    def setUpClass(cls):
        cls.first = run_helper({"requirements.txt": "termcolor\n", "~requirements.pyproject.txt": "iniconfig\n"})
        cls.failed = run_helper(F_FAILED_RUN)
        cls.failed_again = run_helper(F_FAILED_RUN)
        cls.user = run_helper(U_SECOND_RUN)
        cls.tmp_blocked = run_helper({"requirements.txt": "termcolor\n", "~requirements.pyproject.txt": "iniconfig\n"},
                                     dirs=("~requirements.merge.tmp",))
        cases = []
        for key in ("first", "failed", "failed_again", "user"):
            report = getattr(cls, key)[2].get("~dep_merge.report.txt", "")
            cases.append(case("facts_" + key, "Get-DmFacts", Console=report, Setup=report))
        cases.append(case("facts_tmp_blocked", "Get-DmFacts", Console="", Setup=cls.tmp_blocked[1]))
        with tempfile.TemporaryDirectory() as d:
            cls.facts = run_cases(SCRIPT, ["Get-DmFacts"], cases, d)

    def test_the_first_run_of_scenario_f_merges_both_lists(self):
        rc, err, after = self.first
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(names_of(after["requirements.txt"]), ["iniconfig", "termcolor"])
        self.assertTrue(self.facts["facts_first"][0]["mergedLine"])
        self.assertFalse(self.facts["facts_first"][0]["removedTermcolor"])

    def test_the_failed_run_of_scenario_f_reports_the_removal_of_termcolor_and_names_it_for_the_header(self):
        rc, err, after = self.failed
        self.assertEqual((rc, err), (0, ""))
        self.assertTrue(self.facts["facts_failed"][0]["removedTermcolor"], after.get("~dep_merge.report.txt"))
        self.assertFalse(self.facts["facts_failed"][0]["removedIniconfig"])
        self.assertEqual(after["~dep_merge.removed.txt"].split(), ["termcolor"])
        self.assertEqual(names_of(after["requirements.txt"]), ["iniconfig", "six"])
        self.assertIn("~dep_merge.changed.txt", after, "a changed list must keep the dep-check from skipping the install")

    def test_a_run_that_recorded_nothing_sees_the_same_removal_again(self):
        # the premise of scenario F: the helper looks only at the lists and the records, so unchanged records give the same answer
        self.assertEqual(self.failed[2]["~dep_merge.report.txt"], self.failed_again[2]["~dep_merge.report.txt"])
        self.assertEqual(self.failed[2]["~dep_merge.removed.txt"], self.failed_again[2]["~dep_merge.removed.txt"])

    def test_scenario_u_keeps_the_package_the_users_header_lists(self):
        rc, err, after = self.user
        self.assertEqual((rc, err), (0, ""))
        facts_user = self.facts["facts_user"][0]
        self.assertTrue(facts_user["staysHeader"], after.get("~dep_merge.report.txt"))
        self.assertFalse(facts_user["removedIniconfig"])
        self.assertEqual(names_of(after["requirements.txt"]), ["iniconfig", "termcolor"])
        self.assertEqual(after["~dep_merge.removed.txt"].split(), [], "nothing may be removed from a header nobody recorded")

    def test_a_temporary_file_the_helper_cannot_write_makes_it_fail_with_the_name_in_its_error_line(self):
        rc, err, _after = self.tmp_blocked
        self.assertEqual(rc, 3)
        self.assertRegex(err, r"(?m)^dep_merge: .*requirements\.merge\.tmp")
        self.assertTrue(self.facts["facts_tmp_blocked"][0]["helperError"], err)
        self.assertFalse(self.facts["facts_first"][0]["helperError"])


# --- the rules on the real files ---------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.helper = HELPER.read_text(encoding="utf-8")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_labels_exist_once(self):
        self.assertEqual(label_problems(self.batch), [])

    def test_a_merge_that_cannot_run_falls_back_warns_and_lets_the_run_go_on(self):
        self.assertEqual(flow_problems(self.batch), [])

    def test_nothing_is_recorded_after_a_failed_install_and_a_header_record_needs_our_own_write(self):
        self.assertEqual(snapshot_problems(self.batch), [])

    def test_every_text_the_script_looks_for_is_still_written(self):
        self.assertEqual(source_problems(self.batch, self.helper), [])

    def test_the_script_has_its_rows_judges_variables_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shalls_are_no_longer_listed_as_gaps(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        merge = cut_block(self.batch, ":dm_merge", ":dm_fallback")
        self.assertGreater(len(live_bat(merge)), 8)
        snapshot = cut_block(self.batch, ":dep_merge_snapshot", ":determine_entry")
        self.assertGreater(len(live_bat(snapshot)), 12)
        self.assertEqual(len(FACT_CASES), 14)
        self.assertEqual(len(judge_cases()), 72)

    def test_every_fact_of_the_script_has_a_case_here(self):
        facts_text = re.search(r"function Get-DmFacts \{(.*?)\n\}\n", norm(self.script), re.S).group(1)
        in_script = re.findall(r"^\s+(\w+)\s+= \[regex\]::IsMatch", facts_text, re.M)
        self.assertEqual(in_script, FACT_NAMES)


def mutate(text, old, new):
    # exactly once: with two matches the case would edit the first one, which may be another block of the file, and the pin under
    # test would never see the change
    assert text.count(old) == 1, "the synthetic case needs the text to hold %r exactly once, found %d" % (old[:60], text.count(old))
    return text.replace(old, new, 1)


class BatchRulesCanFail(unittest.TestCase):
    """Each rule about run_setup.bat and the helper is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.helper = HELPER.read_text(encoding="utf-8")

    def test_a_missing_or_duplicated_label_is_reported_not_skipped(self):
        gone = mutate(self.batch, "\n:dm_fallback\n", "\n:dm_fallbak\n")
        self.assertTrue(any("appears 0 time(s)" in f for f in label_problems(gone)))
        twice = self.batch + "\n:dm_single\n"
        self.assertTrue(any("appears 2 time(s)" in f for f in label_problems(twice)))
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))

    def test_a_helper_that_cannot_be_written_must_go_to_the_fallback(self):
        bad = mutate(self.batch, 'call :emit_from_base64 "~dep_merge.py" HP_DEP_MERGE\nif errorlevel 1 goto :dm_fallback\n',
                     'call :emit_from_base64 "~dep_merge.py" HP_DEP_MERGE\n')
        self.assertTrue(any("cannot be written" in f for f in flow_problems(bad)), flow_problems(bad))

    def test_the_helpers_error_line_must_reach_the_setup_log(self):
        bad = mutate(self.batch, '"%HP_PY%" "~dep_merge.py" >> "%LOG%" 2>&1\n', '"%HP_PY%" "~dep_merge.py" >> "%LOG%" 2>nul\n')
        self.assertTrue(any("no longer run as" in f for f in flow_problems(bad)), flow_problems(bad))

    def test_any_result_but_nothing_to_merge_and_success_must_go_to_the_fallback(self):
        bad = mutate(self.batch, 'if not "%HP_DM_RC%"=="0" goto :dm_fallback\n', "")
        self.assertTrue(any("the result is no longer read" in f for f in flow_problems(bad)), flow_problems(bad))
        swapped = mutate(self.batch, 'if "%HP_DM_RC%"=="1" goto :dm_single\nif not "%HP_DM_RC%"=="0" goto :dm_fallback\n',
                         'if not "%HP_DM_RC%"=="0" goto :dm_fallback\nif "%HP_DM_RC%"=="1" goto :dm_single\n')
        self.assertTrue(any("the result is no longer read" in f for f in flow_problems(swapped)), flow_problems(swapped))

    def test_the_temporary_file_must_be_cleared_before_the_helper_runs(self):
        bad = mutate(self.batch, " ~dep_merge.changed.txt ~requirements.merge.tmp) do if exist", " ~dep_merge.changed.txt) do if exist")
        self.assertTrue(any("~requirements.merge.tmp" in f for f in flow_problems(bad)), flow_problems(bad))

    def test_a_fallback_that_stops_the_run_is_caught(self):
        bad = mutate(self.batch, 'call :log "[WARN] The dependency lists could not be merged; using the highest ranked list only."\n',
                     'call :log "[WARN] The dependency lists could not be merged; using the highest ranked list only."\nexit /b 1\n')
        self.assertTrue(any("stops or jumps" in f for f in flow_problems(bad)), flow_problems(bad))
        dies = mutate(self.batch, 'call :log "[WARN] The dependency lists could not be merged; using the highest ranked list only."\n',
                      'call :log "[WARN] The dependency lists could not be merged; using the highest ranked list only."\ncall :die "[ERROR] x"\n')
        self.assertTrue(any("stops or jumps" in f for f in flow_problems(dies)), flow_problems(dies))

    def test_a_fallback_without_its_console_warning_or_its_log_line_is_caught(self):
        bad = mutate(self.batch, "echo *** [WARN] The dependency lists could not be merged, so only the highest ranked one is used",
                     "echo *** [WARN] The lists could not be merged, so only the highest ranked one is used")
        self.assertTrue(any("console warning" in f for f in flow_problems(bad)), flow_problems(bad))
        bad = mutate(self.batch, '[WARN] The dependency lists could not be merged; using the highest ranked list only."',
                     '[WARN] The lists could not be merged; using the highest ranked list only."')
        self.assertTrue(any("setup log line" in f for f in flow_problems(bad)), flow_problems(bad))

    def test_a_single_list_copy_that_changed_is_caught(self):
        bad = mutate(self.batch, 'if defined PEP723_ACTIVE call :dm_copy_one "%PEP723_REQ%"\nexit /b 0\n:dm_copy_one',
                     'exit /b 0\n:dm_copy_one')
        self.assertTrue(any(":dm_single is not the copy" in f for f in flow_problems(bad)), flow_problems(bad))

    def test_a_call_site_that_may_stop_the_run_after_a_failed_merge_is_caught(self):
        bad = mutate(self.batch, "\ncall :dep_merge_inputs\n", "\ncall :dep_merge_inputs\nif errorlevel 1 exit /b 1\n")
        self.assertTrue(any("may stop the run" in f for f in flow_problems(bad)), flow_problems(bad))

    def test_the_forced_write_failure_of_a_payload_must_stay_a_logged_failure(self):
        bad = mutate(self.batch, 'call :log "[TEST] HP_TEST_FORCE_EMIT_FAIL=%VAR%: simulating embedded helper write failure."\n  exit /b 1\n',
                     'call :log "[TEST] HP_TEST_FORCE_EMIT_FAIL=%VAR%: simulating embedded helper write failure."\n  exit /b 0\n')
        self.assertTrue(any("forced write failure" in f for f in flow_problems(bad)), flow_problems(bad))

    def test_a_snapshot_that_records_after_a_failed_install_is_caught(self):
        bad = mutate(self.batch, "if defined HP_DM_INSTALL_FAILED exit /b 0\n", "")
        self.assertTrue(any("HP_DM_INSTALL_FAILED" in f for f in snapshot_problems(bad)), snapshot_problems(bad))
        late = mutate(self.batch, "if defined HP_DM_INSTALL_FAILED exit /b 0\nif /I \"%HP_BOOTSTRAP_STATE%\"==\"error\" exit /b 0\n",
                      "if /I \"%HP_BOOTSTRAP_STATE%\"==\"error\" exit /b 0\n")
        self.assertTrue(snapshot_problems(late), "removing the guard in front of the state check must be reported")
        # the guard after the first copy is not a guard
        moved = mutate(self.batch, "if defined HP_DM_INSTALL_FAILED exit /b 0\n", "")
        moved = mutate(moved, 'if exist "~dep_merge.removed.txt" del "~dep_merge.removed.txt" >nul 2>&1\nif exist "~dep_merge.changed.txt" del',
                       'if defined HP_DM_INSTALL_FAILED exit /b 0\nif exist "~dep_merge.removed.txt" del "~dep_merge.removed.txt" >nul 2>&1\nif exist "~dep_merge.changed.txt" del')
        self.assertTrue(any("comes after" in f for f in snapshot_problems(moved)), snapshot_problems(moved))

    def test_a_header_record_that_is_written_without_our_own_write_is_caught(self):
        bad = mutate(self.batch, 'if defined HP_DM_HDR_WRITTEN call :extract_pep723_requirements "%HP_ENTRY%" "~dep_base.pep723.txt"\n',
                     'call :extract_pep723_requirements "%HP_ENTRY%" "~dep_base.pep723.txt"\n')
        self.assertTrue(snapshot_problems(bad), snapshot_problems(bad))
        bad = mutate(self.batch, "if defined HP_DM_HAD_HDR_BASE if not defined HP_DM_HDR_WRITTEN exit /b 0\n", "")
        self.assertTrue(any("HP_DM_HAD_HDR_BASE" in f for f in snapshot_problems(bad)), snapshot_problems(bad))

    def test_an_install_failure_site_that_forgets_the_flag_is_caught(self):
        bad = mutate(self.batch, '        set "HP_DM_INSTALL_FAILED=1"\n        call :log "[WARN] uv pip install -r requirements.txt failed; some packages may be missing."\n',
                     '        call :log "[WARN] uv pip install -r requirements.txt failed; some packages may be missing."\n')
        self.assertTrue(any("uv install failure line" in f for f in snapshot_problems(bad)), snapshot_problems(bad))

    def test_a_reworded_text_is_caught_in_the_batch_file_and_in_the_helper(self):
        bad = mutate(self.batch, "PEP 723 write-back skipped (dependency install did not fully succeed)", "PEP 723 write-back skipped (the install failed)")
        self.assertTrue(any("writebackSkippedInstall" in f for f in source_problems(bad, self.helper)), source_problems(bad, self.helper))
        bad_helper = mutate(self.helper, "you removed it from %s since the last run", "you deleted it from %s since the last run")
        self.assertTrue(any("removedTermcolor" in f for f in source_problems(self.batch, bad_helper)), source_problems(self.batch, bad_helper))
        bad_helper = mutate(self.helper, "        sys.exit(3)\n", "        sys.exit(1)\n")
        self.assertTrue(any("exits 3" in f for f in source_problems(self.batch, bad_helper)), source_problems(self.batch, bad_helper))
        bad_helper = mutate(self.helper, '    tmp = "~requirements.merge.tmp"\n', '    tmp = "~requirements.tmp"\n')
        self.assertTrue(any("~requirements.merge.tmp" in f for f in source_problems(self.batch, bad_helper)), source_problems(self.batch, bad_helper))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the workflow and the registry is shown to fail on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def problems(self, text):
        return script_problems(text)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "Write-DmRow -Id 'self.depmerge.failed.records' -Tag", "Write-DmRow -Id $rowIdF -Tag")
        self.assertTrue(any("self.depmerge.failed.records" in f for f in self.problems(bad)))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "-Tag @{ req = 'REQ-005.1.12' }", "-Tag @{ req = 'REQ-005.1' }")
        self.assertTrue(any("self.depmerge.header.userwrote" in f and "REQ-005.1.12" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-Tag @{ req = 'REQ-005.1.13, REQ-005.1.14' } -Pass ([bool]$pass) -Desc 'REQ-005.1: when the merge helper cannot be written",
                     "-Tag @{ req = 'REQ-005.1.13' } -Pass ([bool]$pass) -Desc 'REQ-005.1: when the merge helper cannot be written")
        self.assertTrue(any("self.depmerge.fallback.emit" in f for f in self.problems(bad)))

    def test_a_skip_table_that_drifts_is_caught(self):
        bad = mutate(self.script, "'self.depmerge.fallback.helper')\n$reqOf", "'self.depmerge.fallback.helperx')\n$reqOf")
        self.assertTrue(any("$allIds" in f for f in self.problems(bad)))
        bad = mutate(self.script, "'self.depmerge.failed.records' = 'REQ-005.1.6';", "'self.depmerge.failed.records' = 'REQ-005.1';")
        self.assertTrue(any("$reqOf" in f for f in self.problems(bad)))

    def test_a_verdict_that_is_not_taken_from_the_problems_is_caught(self):
        bad = mutate(self.script, "$problems = @(Get-UserHeaderProblems -R1 $ru1 -R2 $ru2)\n$pass = ($problems.Count -eq 0)\n",
                     "$problems = @(Get-UserHeaderProblems -R1 $ru1 -R2 $ru2)\n$pass = $true\n")
        self.assertTrue(any("self.depmerge.header.userwrote" in f and "verdict" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$problems = @(Get-FallbackProblems -Variant 'helper' -R $rh)\n$pass = ($problems.Count -eq 0)\nif (-not $pass) { $anyRed = $true }\n",
                     "$problems = @(Get-FallbackProblems -Variant 'helper' -R $rh)\n$pass = ($problems.Count -eq 0)\n")
        self.assertTrue(any("self.depmerge.fallback.helper" in f for f in self.problems(bad)))

    def test_a_judge_call_that_judges_the_wrong_variant_is_caught(self):
        bad = mutate(self.script, "Get-FallbackProblems -Variant 'emit' -R $rx", "Get-FallbackProblems -Variant 'helper' -R $rx")
        self.assertTrue(any("Get-FallbackProblems -Variant 'emit'" in f for f in self.problems(bad)))

    def test_a_run_that_lets_the_runners_settings_decide_is_caught(self):
        bad = mutate(self.script, "HP_SKIP_PEP723_WRITEBACK = ''; ", "")
        self.assertTrue(any("HP_SKIP_PEP723_WRITEBACK" in f for f in self.problems(bad)))
        bad = mutate(self.script, "HP_SKIP_NIVISA = '1'", "HP_SKIP_NIVISA = '0'")
        self.assertTrue(any("HP_SKIP_NIVISA" in f for f in self.problems(bad)))

    def test_open_standard_input_a_missing_kill_and_a_missing_limit_are_caught(self):
        bad = mutate(self.script, "2>&1 < nul", "2>&1")
        self.assertTrue(any("standard input" in f for f in self.problems(bad)))
        bad = mutate(self.script, "& taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null", "")
        self.assertTrue(any("taskkill" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$runTimeoutMs = 12 * 60 * 1000", "$runTimeoutMs = 0")
        self.assertTrue(any("12 minute" in f for f in self.problems(bad)))

    def test_scenarios_that_stop_being_the_ones_the_shalls_name_are_caught(self):
        bad = mutate(self.script, "\"iniconfig`nsix==999.0.0`n\"", "\"iniconfig`nsix==1.0.0`n\"")
        self.assertTrue(any("scenario F" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-Label 'f3' -ForceFlow", "-Label 'f3'")
        self.assertTrue(any("third run" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-Label 'u1' -Env @{ HP_SKIP_PEP723_WRITEBACK = '1' }", "-Label 'u1'")
        self.assertTrue(any("scenario U" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-Env @{ HP_TEST_FORCE_EMIT_FAIL = 'HP_DEP_MERGE' }", "-Env @{ }")
        self.assertTrue(any("scenario X" in f for f in self.problems(bad)))

    def test_a_lock_that_shares_or_is_never_released_is_caught(self):
        bad = mutate(self.script, "[System.IO.FileShare]::None", "[System.IO.FileShare]::Read")
        self.assertTrue(any("scenario H" in f for f in self.problems(bad)))
        bad = mutate(self.script, "if ($null -ne $lockH) { $lockH.Dispose() }", "")
        self.assertTrue(any("never releases" in f for f in self.problems(bad)))

    def test_a_script_without_its_exit_codes_is_caught(self):
        bad = mutate(self.script, "if ($anyRed) { exit 1 }\nexit 0\n", "exit 0\n")
        self.assertTrue(any("exits 1" in f for f in self.problems(bad)))
        bad = mutate(self.script, "if ($anyRed) { exit 1 }\nexit 0\n", "if ($anyRed) { exit 1 }\n")
        self.assertTrue(any("does not end with exit 0" in f for f in self.problems(bad)))

    def test_a_non_ascii_character_is_caught(self):
        self.assertTrue(any("ASCII" in f for f in self.problems(self.script + "\n# caf\u00e9\n")))

    def test_a_step_that_is_not_contract_uv_only_is_caught(self):
        bad = mutate(self.workflow, "          & tests\\selfapps_dep_merge_edges.ps1", "          & tests\\selfapps_dep_merge_edges.ps1")
        block = step_block(bad)
        self.assertIsNotNone(block)
        other = bad.replace(block, block.replace("matrix.mode == 'contract-uv'", "matrix.mode == 'real'"))
        self.assertTrue(any("contract-uv" in f for f in workflow_problems(other)))

    def test_a_step_that_cannot_fail_is_caught(self):
        block = step_block(self.workflow)
        bad = self.workflow.replace(block, block.replace("        shell: pwsh\n", "        shell: pwsh\n        continue-on-error: true\n", 1))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(bad)))

    def test_a_missing_step_or_upload_is_caught(self):
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\selfapps_dep_merge_edges.ps1"])
        bad = self.workflow.replace("tests/~selftest_dmedge_*/~dep_base.*.txt", "")
        self.assertTrue(any("~dep_base" in f for f in workflow_problems(bad)))

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        row = ROWS[2][0]
        self.assertTrue(any(row in f for f in registry_problems(text.replace(row, "self.depmerge.fallback.emitx"))))
        self.assertTrue(any(row in f for f in registry_problems("```\nself.depmerge.failed.records\n```\nprose: %s\n" % row)))

    def test_a_shall_that_is_still_listed_as_a_gap_is_caught(self):
        self.assertTrue(shall_list_problems('    "REQ-005.1.6": "gap: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-005.1.60": "gap: x",\n'), [])


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

    def test_a_judge_that_stops_comparing_the_records_is_caught(self):
        got = self.run_mutated("        if (-not $r.RecReqKept) {", "        if ($false) {", ["f_r2_requirements_record_changed"])
        self.assertEqual(got["f_r2_requirements_record_changed"], [])

    def test_a_judge_that_forgets_the_failed_install_is_caught(self):
        got = self.run_mutated("        if (-not $r.Facts.installFailed) {", "        if ($false) {", ["f_r2_install_did_not_fail"])
        self.assertEqual(got["f_r2_install_did_not_fail"], [])

    def test_a_judge_that_forgets_that_nothing_may_be_taken_out_of_the_header_is_caught(self):
        got = self.run_mutated("    if ($R2.Facts.headerRemovedLogged) {", "    if ($false) {", ["u_second_removed_from_header"])
        self.assertEqual(got["u_second_removed_from_header"], [])

    def test_a_judge_that_forgets_the_fallback_warning_is_caught(self):
        got = self.run_mutated('    if (-not $R.Facts.couldNotMergeConsole) {', '    if ($false) {', ["fb_emit_no_console_warn"])
        self.assertEqual(got["fb_emit_no_console_warn"], [])

    def test_a_judge_that_forgets_the_run_must_still_end_ok_is_caught(self):
        got = self.run_mutated("    if (($R.Exit -ne 0) -or ($R.State -cne 'ok')) {", "    if ($false) {", ["fb_helper_exit_1", "fb_helper_state_error"])
        self.assertEqual(got["fb_helper_exit_1"], [])
        self.assertEqual(got["fb_helper_state_error"], [])

    def test_a_name_comparison_that_ignores_extra_names_is_caught(self):
        got = self.run_mutated("    return ((@($a) -join ',') -ceq (@($e) -join ','))", "    return $true", ["names_extra", "names_missing"])
        self.assertEqual(got["names_extra"], [True])
        self.assertEqual(got["names_missing"], [True])


if __name__ == "__main__":
    unittest.main()
