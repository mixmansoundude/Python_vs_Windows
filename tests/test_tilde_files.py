"""Item 111 (README REQ-003.3, REQ-015.7 and REQ-015.8): where the bootstrapper works, what it calls the files a person keeps, and what
deleting its `~` files costs.

REQ-003.3 says the working files and the build output are created in the folder where the bootstrapper was started, REQ-015.7 that
no file the user is meant to keep or share gets a name that starts with `~`, and REQ-015.8 that deleting a `~` file does not lose the
user's work. The README notes of REQ-015 say that no row names the last two: the list of files the user keeps is written by hand in
`self.litter.appfolder`, and no row deletes the `~` files and runs again. tests/selfapps_tilde_files.ps1 (three rows,
self.tilde.workfolder, self.tilde.keepfiles and self.tilde.deletable; contract-uv lane, gating) bootstraps a program in a folder
whose own name starts with `~` (so a name derived from the folder would carry the tilde), reads which files the briefing of that run
tells the user to keep and which EXE it names, checks them, deletes every `~` file and folder as the briefing says is safe and
bootstraps again.

What really happens is shown on Windows by that script. These rules read run_setup.bat, the script, batch-check.yml,
docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, replay the real echo lines of :print_postflight_briefing for the
verified and the unverified variant and hand the console text to the script's own judging functions through a real pwsh (so the
headings, the section names and the EXE line the judge looks for are the ones the batch file prints), and run those functions on
synthetic runs (a run that passes, and one run for each way to be wrong). A renamed file, an EXE name that keeps a tilde, a briefing
that stops listing what to keep, a judge that stops judging or a step that stops gating fails here with a sentence, before a Windows
run is needed. Synthetic cases prove each rule can fail.
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
SCRIPT = REPO / "tests" / "selfapps_tilde_files.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

ROW_REQS = {"self.tilde.workfolder": "REQ-003.3", "self.tilde.keepfiles": "REQ-015.7", "self.tilde.deletable": "REQ-015.8"}
ROW_IDS = tuple(ROW_REQS)
GAP_SHALLS = ("REQ-003.3", "REQ-015.7", "REQ-015.8")
SITES_PER_ID = 3  # the non-Windows skip, the missing batch file and the verdict

FOLDER = "~tilde_work"
EXPECTED_EXE = "_tilde_work.exe"
MARKER = "TILDE_APP_RAN"
USER_FILES = ["app.py", "requirements.txt", "runtime.txt", ".gitignore", ".gitattributes"]

BRIEF_START = ":print_postflight_briefing"
BRIEF_END = ":pfb_dll_hint"
READY_LINE = "echo  Your standalone application is ready:"
EXE_LINE = "echo    dist\\%ENVNAME%.exe"
KEEP_HEADING = "echo  KEEP these files with your project:"
SAFE_HEADING = "echo  SAFE TO DELETE to reclaim disk space:"
LOG_LINE = 'set "LOG=~setup.log"'
STATUS_LINE = 'set "STATUS_FILE=~bootstrap.status.json"'
SANITIZE_PARTS = ("-replace '&', 'and'", "-replace '[^A-Za-z0-9_-]', '_'", "-replace '^-+', '_'")

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~tilde_files_evidence.txt",
    "tests/~selftest_tilde_root/~tilde_work/~tl_console2.log",
    "tests/~selftest_tilde_root/~tilde_work/~setup.log",
    "tests/~selftest_tilde_root/~tilde_work/~bootstrap.status.json",
)
JUDGES = ["Get-Briefing", "ConvertTo-Normalized", "Get-SnapshotChanges", "Get-WorkfolderProblems", "Get-KeepProblems",
          "Get-DeletableProblems", "Get-Excerpt"]


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


def sanitize(name):
    """The environment name run_setup.bat derives from a folder name (the part that matters here: every character outside the safe
    set, the tilde included, becomes an underscore)."""
    san = name.replace("&", "and")
    san = re.sub(r"[^A-Za-z0-9_-]", "_", san)
    return re.sub(r"^-+", "_", san)


def script_value(text, name):
    m = re.search(r"(?m)^\$%s = '([^']*)'\s*$" % re.escape(name), norm(text))
    return m.group(1) if m else None


def script_list(text, name):
    m = re.search(r"(?m)^\$%s = @\(([^)]*)\)\s*$" % re.escape(name), norm(text))
    if not m:
        return None
    return [part.strip().strip("'") for part in m.group(1).split(",") if part.strip()]


# --- the batch file: what the script assumes -------------------------------------------------------------------------------------

def keep_names(body):
    """The first word of each `echo   name  -- text` line between the KEEP heading and the SAFE TO DELETE heading of a block."""
    names, inside = [], False
    for ln in body:
        if ln == KEEP_HEADING:
            inside = True
            continue
        if ln == SAFE_HEADING:
            break
        if inside:
            m = re.match(r"echo\s{2,}(\S+)\s+--\s", ln)
            if m:
                names.append(m.group(1))
    return names


def batch_problems(batch, script):
    """The files and names the script reads, as the batch file writes them."""
    found = []
    live = [ln.strip() for ln in live_bat(lines_of(batch))]
    for text, what in ((LOG_LINE, "the setup log name"), (STATUS_LINE, "the status file name")):
        if live.count(text) != 1:
            found.append("%s: expected exactly one live line %r, found %d" % (what, text, live.count(text)))
    sanitizing = [ln for ln in live if ln.startswith("for /f") and "$san = " in ln]
    if len(sanitizing) != 1:
        found.append("expected exactly one line that derives the environment name from the folder name, found %d" % len(sanitizing))
    else:
        for part in SANITIZE_PARTS:
            if part not in sanitizing[0]:
                found.append("the environment name is no longer derived with %s, so the EXE name of a folder that starts with ~ is not what the script expects" % part)
    folder, exe = script_value(script, "folderName"), script_value(script, "expectedExe")
    if folder is None or exe is None:
        found.append("the script's $folderName and $expectedExe could not be read")
    elif sanitize(folder) + ".exe" != exe:
        found.append("a program folder named %s gives the environment name %s, so the EXE is %s.exe; the script expects %s" % (folder, sanitize(folder), sanitize(folder), exe))
    elif not folder.startswith("~"):
        found.append("the script's program folder %r does not start with ~, so the row cannot show that the EXE name drops the tilde" % folder)
    block = cut_block(batch, BRIEF_START, BRIEF_END)
    if block is None:
        return found + ["the block from %s to %s cannot be cut" % (BRIEF_START, BRIEF_END)]
    body = [ln.strip() for ln in live_bat(block)]
    ready = [i for i, ln in enumerate(body) if ln == READY_LINE]
    exe_line = [i for i, ln in enumerate(body) if ln == EXE_LINE]
    if len(ready) != 1 or len(exe_line) != 1:
        found.append("the success variant must hold exactly one %r and one %r line, found %d and %d" % (READY_LINE, EXE_LINE, len(ready), len(exe_line)))
    elif exe_line[0] != ready[0] + 1:
        found.append("the line that names the EXE must directly follow %r, which is where the script reads it" % READY_LINE)
    keep_heads = [i for i, ln in enumerate(body) if ln == KEEP_HEADING]
    safe_heads = [i for i, ln in enumerate(body) if ln == SAFE_HEADING]
    if len(keep_heads) != 1 or len(safe_heads) != 1 or not keep_heads[0] < safe_heads[0]:
        found.append("the panel must hold the KEEP heading once, then the SAFE TO DELETE heading once (found %d and %d)" % (len(keep_heads), len(safe_heads)))
        return found
    names = keep_names(body)
    if not names:
        found.append("no file is listed between the KEEP heading and the SAFE TO DELETE heading")
    for name in names:
        if name.startswith("~"):
            found.append("the briefing tells the user to keep a file whose name starts with ~: %s" % name)
        if name not in (script_list(script, "userFiles") or []):
            found.append("the briefing tells the user to keep %s, which the script's $userFiles does not hold, so the second row would not compare it" % name)
    safe = body[safe_heads[0] + 1:]
    if not any(re.match(r"echo\s+~\*\s+files\b", ln) for ln in safe):
        found.append("the SAFE TO DELETE list no longer names the ~* files, so the second row would delete what the briefing does not call safe")
    if not any(ln.startswith("echo =") for ln in safe):
        found.append("no closing rule follows the SAFE TO DELETE list")
    in_shared = body.index(":pfb_runapp") < keep_heads[0] if ":pfb_runapp" in body else False
    if not in_shared:
        found.append("the KEEP heading is no longer in the section both variants of the briefing reach, so the unverified variant would not list it")
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
    pairs = re.findall(r"\bid\s*=\s*'(self\.tilde\.[a-z]+)'\s*;?\s*req\s*=\s*'([^']*)'", t)
    if sorted(p[0] for p in pairs) != sorted(list(ROW_IDS) * SITES_PER_ID):
        found.append("every row id must be followed by its literal req tag, found %r" % pairs)
    for row, req in pairs:
        if ROW_REQS.get(row) != req:
            found.append("the row %s must carry the literal req tag %r, found %r" % (row, ROW_REQS.get(row), req))
    if "$marker = 'TILDE_APP_RAN'" not in flat:
        found.append("the program no longer prints TILDE_APP_RAN")
    if "$program = \"import colorama`nprint('$marker', colorama.__version__, flush=True)`n\"" not in flat:
        found.append("the program is no longer one import of colorama and one flushed line (the import is what makes pipreqs write requirements.txt)")
    if "$folderName = '~tilde_work'" not in flat or "$expectedExe = '_tilde_work.exe'" not in flat:
        found.append("the program folder is no longer ~tilde_work with the EXE _tilde_work.exe expected")
    if "$userFiles = @('app.py', 'requirements.txt', 'runtime.txt', '.gitignore', '.gitattributes')" not in flat:
        found.append("the files of the user the second row compares are no longer the program, requirements.txt, runtime.txt and the two git files")
    for name in ("HP_SKIP_AUTOPEP_DISCOVERY", "HP_SKIP_PEP723_WRITEBACK"):
        if "%s = '1'" % name not in flat:
            found.append("the run no longer sets %s to 1 (the folder must hold only what the bootstrapper writes beside the user's program)" % name)
    for name in ("HP_SKIP_PIPREQS", "HP_SKIP_NIVISA", "HP_SKIP_ENTRY_SMOKE", "HP_SKIP_EXE_SMOKERUN", "HP_TEST_FORCE_EMIT_FAIL", "HP_TEST_REPAIR_ANSWER",
                 "HP_TEST_LASTCHANCE_ANSWER", "HP_TEST_CHECKPOINT_ANSWER", "HP_TEST_RTM_ANSWER", "HP_PVW_KNOWN_IDEMPOTENT", "PVW_BUILDER", "PVW_PROVIDER"):
        if "%s = ''" % name not in flat:
            found.append("the run no longer clears %s, so the runner's setting could decide the result" % name)
    if "HP_CI_LANE'] = 'test'" not in flat:
        found.append("a run without the CI marker no longer gets one")
    if "call run_setup.bat app.py > $LogName 2>&1 < nul" not in flat:
        found.append("the bootstrap no longer runs with standard input closed (< nul) and its console in a file")
    if "$runTimeoutMs = 15 * 60 * 1000" not in flat or flat.count("taskkill.exe /F /T /PID $p.Id") != 1:
        found.append("a bootstrap that does not finish is no longer stopped with taskkill /F /T after 15 minutes")
    if "$wrapper = Join-Path $Dir '~tl_launch.cmd'" not in flat:
        found.append("the launch wrapper is no longer a ~ file of the program folder (the deletion has to remove it too)")
    if "-LogName '~tl_console1.log'" not in flat or "-LogName '~tl_console2.log'" not in flat:
        found.append("the two bootstraps no longer write their consoles to ~tl_console1.log and ~tl_console2.log")
    # the order of the whole scenario: lists, first run, lists, deletion, second run
    marks = ["$outsideBefore = ", "$run1 = Invoke-Run -Dir $dir -LogName '~tl_console1.log'", "$outsideAfter = ", "$beside = ",
             "$deleted = Remove-TildeEntries -Dir $dir", "$run2 = Invoke-Run -Dir $dir -LogName '~tl_console2.log'"]
    at = [flat.find(m) for m in marks]
    if -1 in at or at != sorted(at) or len(set(at)) != len(at):
        found.append("the scenario no longer runs in this order: the lists before the first run, the first run, the lists after it, the deletion, the second run")
    if "if ($run1.Finished -and $run1.State -eq 'ok') {" not in flat or "if (@($deleted.Left).Count -eq 0) {" not in flat:
        found.append("the deletion and the second run are no longer guarded by a first run that ended ok and a deletion that left nothing")
    if "if (-not $sub) {" in flat or "foreach ($sub in @('', 'dist', 'build')) {" not in flat or ".Name.StartsWith('~')" not in flat or "-Recurse -Force -ErrorAction Stop" not in flat:
        found.append("Remove-TildeEntries no longer removes every entry that starts with ~ in the folder, dist and build, recursively")
    if ("$workProblems = @(Get-WorkfolderProblems -Run $run1 -Inside $inside -Beside $beside -FolderName $folderName -ExeLeaf $expectedExe "
            "-Outside $outside)") not in flat:
        found.append("the verdict of REQ-003.3 no longer comes from Get-WorkfolderProblems with all its arguments")
    if "$keepProblems = @(Get-KeepProblems -Run $run1 -Briefing $briefing -Present $present -FolderName $folderName -ExpectedExe $expectedExe)" not in flat:
        found.append("the verdict of REQ-015.7 no longer comes from Get-KeepProblems with all its arguments")
    if ("$delProblems = @(Get-DeletableProblems -Run1 $run1 -Run2 $run2 -Removed @($deleted.Removed) -Left @($deleted.Left) -Before $entries1 "
            "-After $entries2 -SeedApp $seedApp -AppNow $appNow -Marker $marker -Out2 $run2.Out -ExeBack $exeBack)") not in flat:
        found.append("the verdict of REQ-015.8 no longer comes from Get-DeletableProblems with all its arguments")
    if "$briefing = Get-Briefing $run1.Console" not in flat:
        found.append("the briefing is no longer read from the console of the first bootstrap")
    for var in ("workPass = ($workProblems.Count -eq 0)", "keepPass = ($keepProblems.Count -eq 0)", "delPass = ($delProblems.Count -eq 0)"):
        if "$" + var not in flat:
            found.append("a row is no longer judged by its list of problems: %s" % var)
    for var in ("pass = $workPass", "pass = $keepPass", "pass = $delPass"):
        if var not in flat:
            found.append("a row no longer writes pass from its own verdict: %s" % var)
    for name in JUDGES:
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the judging function %s is missing" % name)
    if "OSVersion.Platform -ne [System.PlatformID]::Win32NT" not in flat or re.search(r"\$IsWindows\b", flat):
        found.append("the Windows check must use OSVersion.Platform and not $IsWindows")
    if "skip = $true" not in flat:
        found.append("the rows no longer skip off Windows with skip = $true")
    last_row = flat.rfind("id = 'self.tilde.deletable'")
    evidence = flat.find("'~tilde_files_evidence.txt'")
    if evidence < 0 or last_row < 0 or evidence < last_row:
        found.append("the evidence file ~tilde_files_evidence.txt is no longer written after the last row (it must come after every folder was listed)")
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
        if "selfapps_tilde_files.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_tilde_files.ps1"]
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

def simulate(batch, defined, envname="_tilde_work", hp_py=r"C:\Work\~tilde_work\.uv_env\Scripts\python.exe",
             hp_entry=r"C:\Work\~tilde_work\app.py"):
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
        # an argument given as {"__fn": name, "args": {...}} is the result of another judging function (the briefing of a real console)
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


RULE = "=" * 60
APP_TEXT = "import colorama\nprint('TILDE_APP_RAN', colorama.__version__, flush=True)"
GOOD_KEEP = ["requirements.txt", "runtime.txt"]
GOOD_EXE = "dist\\_tilde_work.exe"
PRESENT = ["requirements.txt", "runtime.txt", ".gitignore", ".gitattributes", GOOD_EXE]
USER_ENTRIES = ["app.py=" + APP_TEXT, "requirements.txt=colorama", "runtime.txt=python-3.14.0", ".gitignore=*~\n~*", ".gitattributes=*.bat -text"]
REMOVED = ["~setup.log", "~bootstrap.status.json", "dist\\~exe_out.txt", "~uv_bin"]
INSIDE = ["~setup.log", "~bootstrap.status.json", "dist\\_tilde_work.exe", "dist", ".uv_env"]

SUCCESS_LINES = [
    "[INFO] Entry smoke exit=0",
    "",
    RULE,
    " SETUP COMPLETE",
    RULE,
    " Your standalone application is ready:",
    "   dist\\_tilde_work.exe",
    "",
    " RUNNING YOUR APP",
    "   Double-click dist\\_tilde_work.exe to run it.",
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
CAVEAT_LINES = [ln for ln in SUCCESS_LINES if "Your standalone application is ready" not in ln and "dist\\_tilde_work.exe" not in ln or "Double-click" in ln]


def run_obj(**over):
    r = {"Finished": True, "Exit": 0, "State": "ok"}
    r.update(over)
    return r


def briefing_obj(**over):
    b = {"Keep": list(GOOD_KEEP), "Exe": GOOD_EXE}
    b.update(over)
    return b


def work_args(**over):
    a = dict(Run=run_obj(), Inside=list(INSIDE), Beside=[FOLDER], FolderName=FOLDER, ExeLeaf=EXPECTED_EXE, Outside=[])
    a.update(over)
    return a


def keep_args(**over):
    a = dict(Run=run_obj(), Briefing=briefing_obj(), Present=list(PRESENT), FolderName=FOLDER, ExpectedExe=EXPECTED_EXE)
    a.update(over)
    return a


def del_args(**over):
    a = dict(Run1=run_obj(), Run2=run_obj(), Removed=list(REMOVED), Left=[], Before=list(USER_ENTRIES), After=list(USER_ENTRIES),
             SeedApp=APP_TEXT, AppNow=APP_TEXT, Marker=MARKER, Out2=MARKER + " 0.4.6\r\n", ExeBack=True)
    a.update(over)
    return a


def crlf(lines):
    return "\r\n".join(lines)


def judge_cases():
    c = []
    # --- Get-Briefing
    c.append(case("brief_success", "Get-Briefing", Console=crlf(SUCCESS_LINES)))
    c.append(case("brief_caveat", "Get-Briefing", Console=crlf(CAVEAT_LINES)))
    c.append(case("brief_nothing", "Get-Briefing", Console="[INFO] nothing here\r\n"))
    tilde = list(SUCCESS_LINES)
    tilde.insert(tilde.index("   runtime.txt       -- Python version pin") + 1, "   ~notes.txt        -- notes")
    c.append(case("brief_tilde_name_in_keep", "Get-Briefing", Console=crlf(tilde)))
    gap = list(SUCCESS_LINES)
    gap.insert(gap.index("   dist\\_tilde_work.exe"), "")
    c.append(case("brief_exe_not_on_the_next_line", "Get-Briefing", Console=crlf(gap)))
    c.append(case("brief_lf_only", "Get-Briefing", Console="\n".join(SUCCESS_LINES)))
    tail_only = SUCCESS_LINES[SUCCESS_LINES.index(" SAFE TO DELETE to reclaim disk space:"):]
    c.append(case("brief_only_the_delete_list", "Get-Briefing", Console=crlf(tail_only)))
    # --- ConvertTo-Normalized
    c.append(case("norm_trim_blank_and_endings", "ConvertTo-Normalized", Text="a  \r\n\r\n  b\r\n"))
    c.append(case("norm_lf_without_final_newline", "ConvertTo-Normalized", Text="a\n  b"))
    c.append(case("norm_empty", "ConvertTo-Normalized", Text=""))
    # --- Get-SnapshotChanges
    c.append(case("snap_same", "Get-SnapshotChanges", Before=["a.txt|file:1:10", "d|dir"], After=["a.txt|file:1:10", "d|dir"]))
    c.append(case("snap_new_and_gone", "Get-SnapshotChanges", Before=["a.txt|file:1:10", "gone.txt|file:2:3"], After=["a.txt|file:1:10", "new.txt|file:5:6"]))
    c.append(case("snap_changed_file", "Get-SnapshotChanges", Before=["a.txt|file:1:10"], After=["a.txt|file:2:11"]))
    c.append(case("snap_bar_in_the_name", "Get-SnapshotChanges", Before=["we|rd|file:1:1"], After=["we|rd|file:1:1"]))
    c.append(case("snap_all_gone", "Get-SnapshotChanges", Before=["a|dir", "b|dir"], After=[]))
    # --- Get-WorkfolderProblems
    c.append(case("work_good", "Get-WorkfolderProblems", **work_args()))
    c.append(case("work_unfinished", "Get-WorkfolderProblems", **work_args(Run=run_obj(Finished=False, Exit=-1, State=""))))
    c.append(case("work_state_error", "Get-WorkfolderProblems", **work_args(Run=run_obj(State="error"))))
    c.append(case("work_no_setup_log", "Get-WorkfolderProblems", **work_args(Inside=[n for n in INSIDE if n != "~setup.log"])))
    c.append(case("work_no_status_file", "Get-WorkfolderProblems", **work_args(Inside=[n for n in INSIDE if n != "~bootstrap.status.json"])))
    c.append(case("work_no_exe", "Get-WorkfolderProblems", **work_args(Inside=[n for n in INSIDE if not n.endswith(".exe")])))
    c.append(case("work_entries_beside", "Get-WorkfolderProblems", **work_args(Beside=[FOLDER, "~setup.log", "dist"])))
    c.append(case("work_folder_not_beside", "Get-WorkfolderProblems", **work_args(Beside=[])))
    c.append(case("work_other_entry_instead_of_the_folder", "Get-WorkfolderProblems", **work_args(Beside=["other"])))
    c.append(case("work_outside_changes", "Get-WorkfolderProblems", **work_args(Outside=["tests/~setup.log", "root/dist"])))
    # --- Get-KeepProblems
    c.append(case("keep_good", "Get-KeepProblems", **keep_args()))
    c.append(case("keep_unfinished", "Get-KeepProblems", **keep_args(Run=run_obj(Finished=False, Exit=-1, State=""))))
    c.append(case("keep_state_error", "Get-KeepProblems", **keep_args(Run=run_obj(State="error"))))
    c.append(case("keep_folder_without_tilde", "Get-KeepProblems", **keep_args(FolderName="work")))
    c.append(case("keep_empty_list", "Get-KeepProblems", **keep_args(Briefing=briefing_obj(Keep=[]))))
    c.append(case("keep_without_requirements", "Get-KeepProblems", **keep_args(Briefing=briefing_obj(Keep=["runtime.txt"]))))
    c.append(case("keep_without_runtime", "Get-KeepProblems", **keep_args(Briefing=briefing_obj(Keep=["requirements.txt"]))))
    c.append(case("keep_tilde_name", "Get-KeepProblems", **keep_args(Briefing=briefing_obj(Keep=GOOD_KEEP + ["~notes.txt"]), Present=PRESENT + ["~notes.txt"])))
    c.append(case("keep_file_missing", "Get-KeepProblems", **keep_args(Briefing=briefing_obj(Keep=GOOD_KEEP + ["notes.txt"]))))
    c.append(case("keep_no_gitignore", "Get-KeepProblems", **keep_args(Present=[n for n in PRESENT if n != ".gitignore"])))
    c.append(case("keep_no_gitattributes", "Get-KeepProblems", **keep_args(Present=[n for n in PRESENT if n != ".gitattributes"])))
    c.append(case("keep_no_exe", "Get-KeepProblems", **keep_args(Briefing=briefing_obj(Exe=""))))
    c.append(case("keep_exe_tilde_name", "Get-KeepProblems", **keep_args(Briefing=briefing_obj(Exe="dist\\~tilde_work.exe"), Present=PRESENT + ["dist\\~tilde_work.exe"])))
    c.append(case("keep_exe_wrong_name", "Get-KeepProblems", **keep_args(Briefing=briefing_obj(Exe="dist\\other.exe"), Present=PRESENT + ["dist\\other.exe"])))
    c.append(case("keep_exe_missing", "Get-KeepProblems", **keep_args(Present=[n for n in PRESENT if n != GOOD_EXE])))
    # --- Get-DeletableProblems
    c.append(case("del_good", "Get-DeletableProblems", **del_args()))
    c.append(case("del_run1_unfinished", "Get-DeletableProblems", **del_args(Run1=run_obj(Finished=False, Exit=-1, State=""))))
    c.append(case("del_run1_error", "Get-DeletableProblems", **del_args(Run1=run_obj(State="error"))))
    c.append(case("del_nothing_removed", "Get-DeletableProblems", **del_args(Removed=[])))
    c.append(case("del_no_setup_log_removed", "Get-DeletableProblems", **del_args(Removed=["a", "b", "c"])))
    c.append(case("del_left", "Get-DeletableProblems", **del_args(Left=["~held.txt"])))
    c.append(case("del_run2_unfinished", "Get-DeletableProblems", **del_args(Run2=run_obj(Finished=False, Exit=-1, State=""))))
    c.append(case("del_run2_state", "Get-DeletableProblems", **del_args(Run2=run_obj(State="error"))))
    c.append(case("del_run2_exit", "Get-DeletableProblems", **del_args(Run2=run_obj(Exit=1))))
    c.append(case("del_run2_no_marker", "Get-DeletableProblems", **del_args(Out2="nothing\r\n")))
    c.append(case("del_exe_not_back", "Get-DeletableProblems", **del_args(ExeBack=False)))
    c.append(case("del_user_file_gone", "Get-DeletableProblems", **del_args(After=[e for e in USER_ENTRIES if not e.startswith("requirements.txt=")])))
    c.append(case("del_user_file_different", "Get-DeletableProblems",
                  **del_args(After=[("runtime.txt=python-3.9" if e.startswith("runtime.txt=") else e) for e in USER_ENTRIES])))
    c.append(case("del_app_changed", "Get-DeletableProblems", **del_args(AppNow=APP_TEXT + "\nprint('x')")))
    c.append(case("del_everything_wrong", "Get-DeletableProblems",
                  **del_args(Run2=run_obj(State="error", Exit=2), Out2="", ExeBack=False, After=[], AppNow="")))
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

    def test_the_briefing_of_a_verified_run_names_what_to_keep_and_the_exe(self):
        b = self.r["brief_success"][0]
        self.assertEqual(b["Keep"], GOOD_KEEP)
        self.assertEqual(b["Exe"], GOOD_EXE)

    def test_the_unverified_briefing_lists_the_same_files_and_names_no_exe(self):
        b = self.r["brief_caveat"][0]
        self.assertEqual(b["Keep"], GOOD_KEEP)
        self.assertEqual(b["Exe"], "")

    def test_a_console_without_a_briefing_names_nothing(self):
        b = self.r["brief_nothing"][0]
        self.assertEqual(b["Keep"], [])
        self.assertEqual(b["Exe"], "")

    def test_a_tilde_name_in_the_keep_list_is_read_and_the_delete_list_is_not(self):
        self.assertEqual(self.r["brief_tilde_name_in_keep"][0]["Keep"], GOOD_KEEP + ["~notes.txt"])
        self.assertEqual(self.r["brief_only_the_delete_list"][0]["Keep"], [])

    def test_the_exe_is_the_line_directly_under_the_ready_line_and_nothing_else(self):
        self.assertEqual(self.r["brief_exe_not_on_the_next_line"][0]["Exe"], "")

    def test_a_console_with_only_lf_is_read_the_same(self):
        self.assertEqual(self.r["brief_lf_only"][0], self.r["brief_success"][0])

    def test_normalizing_trims_drops_blank_lines_and_equalizes_the_endings(self):
        self.assertEqual(self.r["norm_trim_blank_and_endings"], ["a\nb"])
        self.assertEqual(self.r["norm_lf_without_final_newline"], ["a\nb"])
        self.assertEqual(self.r["norm_empty"], [""])

    def test_a_snapshot_reports_what_is_new_gone_or_different_and_nothing_else(self):
        self.assertEqual(self.r["snap_same"], [])
        self.assertEqual(self.r["snap_new_and_gone"], ["gone.txt", "new.txt"])
        self.assertEqual(self.r["snap_changed_file"], ["a.txt"])
        self.assertEqual(self.r["snap_bar_in_the_name"], [])
        self.assertEqual(self.r["snap_all_gone"], ["a", "b"])

    def test_a_good_run_has_no_problem(self):
        self.assertEqual(self.r["work_good"], [])
        self.assertEqual(self.r["keep_good"], [])
        self.assertEqual(self.r["del_good"], [])

    def test_a_bootstrap_that_did_not_finish_or_ended_in_error_is_one_problem_and_nothing_else(self):
        self.only("work_unfinished", "the bootstrap did not finish within the time limit")
        self.only("work_state_error", "ended with state [error], not ok, so the build output was not judged")
        self.only("keep_unfinished", "the bootstrap did not finish within the time limit")
        self.only("keep_state_error", "ended with state [error], not ok, so the briefing was not judged")
        self.only("del_run1_unfinished", "the first bootstrap did not finish within the time limit")
        self.only("del_run1_error", "the first bootstrap ended with state [error], not ok, so deleting its files was not judged")

    def test_a_missing_working_file_or_build_output_is_named(self):
        self.only("work_no_setup_log", "the program folder does not hold ~setup.log")
        self.only("work_no_status_file", "the program folder does not hold ~bootstrap.status.json")
        self.only("work_no_exe", "the program folder does not hold dist\\_tilde_work.exe")

    def test_entries_beside_the_program_folder_or_outside_the_scripts_folder_are_named(self):
        self.only("work_entries_beside", "entries were created beside the program folder: ~setup.log, dist")
        self.only("work_folder_not_beside", "the program folder is not in the folder the script made for it")
        found = self.r["work_other_entry_instead_of_the_folder"]
        self.assertTrue(any("entries were created beside the program folder: other" in f for f in found), found)
        self.assertTrue(any("the program folder is not in the folder the script made for it" in f for f in found), found)
        self.only("work_outside_changes", "names were created or changed in the folder of the scripts or in the repository root: tests/~setup.log, root/dist")

    def test_a_program_folder_without_a_tilde_proves_nothing_and_is_named(self):
        found = self.r["keep_folder_without_tilde"]
        self.assertTrue(any("does not start with ~, so the EXE name proves nothing about the tilde" in f for f in found), found)

    def test_a_briefing_that_lists_nothing_to_keep_is_one_problem(self):
        self.only("keep_empty_list", "printed no file under")

    def test_a_briefing_that_stops_telling_the_user_to_keep_requirements_or_runtime_is_named(self):
        self.only("keep_without_requirements", "the briefing no longer tells the user to keep requirements.txt")
        self.only("keep_without_runtime", "the briefing no longer tells the user to keep runtime.txt")

    def test_a_tilde_name_to_keep_and_a_file_that_is_not_there_are_named(self):
        self.only("keep_tilde_name", "names a file to keep that starts with ~: ~notes.txt")
        self.only("keep_file_missing", "the file the briefing says to keep is not in the program folder: notes.txt")

    def test_the_two_git_files_are_required(self):
        self.only("keep_no_gitignore", "the program folder does not hold .gitignore")
        self.only("keep_no_gitattributes", "the program folder does not hold .gitattributes")

    def test_an_exe_that_is_not_named_starts_with_a_tilde_has_another_name_or_is_missing_is_named(self):
        self.only("keep_no_exe", "the briefing does not name the standalone EXE")
        both = self.r["keep_exe_tilde_name"]
        self.assertEqual(len(both), 2, both)
        self.assertTrue(any("starts with ~: ~tilde_work.exe" in f for f in both), both)
        self.assertTrue(any("must give _tilde_work.exe" in f for f in both), both)
        self.only("keep_exe_wrong_name", "the EXE the briefing names is other.exe; a program folder named ~tilde_work must give _tilde_work.exe")
        self.only("keep_exe_missing", "the EXE the briefing names is not in the program folder: dist\\_tilde_work.exe")

    def test_a_deletion_that_took_nothing_or_could_not_finish_is_one_problem(self):
        self.only("del_nothing_removed", "the deletion took away 0 entries and not ~setup.log, so there was nothing to lose")
        self.only("del_no_setup_log_removed", "the deletion took away 3 entries and not ~setup.log")
        self.only("del_left", "some ~ entries could not be removed: ~held.txt")

    def test_a_second_bootstrap_that_did_not_finish_is_one_problem(self):
        self.only("del_run2_unfinished", "the bootstrap after the deletion did not finish within the time limit")

    def test_a_second_bootstrap_that_ends_wrong_is_named_for_each_way(self):
        self.only("del_run2_state", "the bootstrap after the deletion ended with state [error], not ok")
        self.only("del_run2_exit", "the bootstrap after the deletion ended with exit code 1")
        self.only("del_run2_no_marker", "did not print the program's own line (TILDE_APP_RAN)")
        self.only("del_exe_not_back", "the EXE is not in dist after the second run")

    def test_a_file_of_the_user_that_is_gone_or_different_after_the_second_run_is_named(self):
        self.only("del_user_file_gone", "a file of the user is gone after the second run: requirements.txt")
        self.only("del_user_file_different", "a file of the user is different after the second run: runtime.txt")
        self.only("del_app_changed", "the program the user wrote is different after the two runs")

    def test_every_way_to_be_wrong_at_once_is_every_problem(self):
        found = self.r["del_everything_wrong"]
        self.assertGreaterEqual(len(found), 8, found)

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
    """The real echo lines of :print_postflight_briefing, replayed for the verified and the unverified variant, are handed to the
    script's own functions: the headings, section names and the EXE line the judge looks for are the ones the batch file prints."""

    @classmethod
    def setUpClass(cls):
        cls.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        cls.success, _ = simulate(cls.batch, {"HP_PY"})
        cls.caveat, _ = simulate(cls.batch, {"HP_EXE_VERIFY_FAILED", "HP_PY"})
        success_console = crlf(["[INFO] Entry smoke exit=0", ""] + cls.success + [""])
        caveat_console = crlf(["[INFO] Entry smoke exit=3", ""] + cls.caveat + [""])
        tilde_exe = crlf(["[INFO] Entry smoke exit=0", ""] + [ln.replace("dist\\_tilde_work.exe", "dist\\~tilde_work.exe") for ln in cls.success] + [""])
        cases = [
            case("success_briefing", "Get-Briefing", Console=success_console),
            case("caveat_briefing", "Get-Briefing", Console=caveat_console),
            case("keep_real_success", "Get-KeepProblems", Run=run_obj(), Briefing=chain("Get-Briefing", Console=success_console),
                 Present=list(PRESENT), FolderName=FOLDER, ExpectedExe=EXPECTED_EXE),
            case("keep_real_caveat", "Get-KeepProblems", Run=run_obj(), Briefing=chain("Get-Briefing", Console=caveat_console),
                 Present=list(PRESENT), FolderName=FOLDER, ExpectedExe=EXPECTED_EXE),
            case("keep_real_tilde_exe", "Get-KeepProblems", Run=run_obj(), Briefing=chain("Get-Briefing", Console=tilde_exe),
                 Present=PRESENT + ["dist\\~tilde_work.exe"], FolderName=FOLDER, ExpectedExe=EXPECTED_EXE),
        ]
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, JUDGES, cases, d)

    def test_the_replay_follows_the_real_dispatch(self):
        self.assertTrue(any("Your standalone application is ready" in ln for ln in self.success))
        self.assertFalse(any("WITH A CAVEAT" in ln for ln in self.success))
        self.assertTrue(any("WITH A CAVEAT" in ln for ln in self.caveat))
        self.assertFalse(any("Your standalone application is ready" in ln for ln in self.caveat))
        self.assertGreater(len(self.success), 25)

    def test_the_real_verified_briefing_names_the_files_to_keep_and_an_exe_without_a_tilde(self):
        b = self.r["success_briefing"][0]
        self.assertEqual(b["Keep"], GOOD_KEEP)
        self.assertEqual(b["Exe"], GOOD_EXE)

    def test_the_real_unverified_briefing_lists_the_same_files_and_no_exe(self):
        b = self.r["caveat_briefing"][0]
        self.assertEqual(b["Keep"], GOOD_KEEP)
        self.assertEqual(b["Exe"], "")

    def test_the_judge_accepts_the_real_verified_briefing(self):
        self.assertEqual(self.r["keep_real_success"], [])

    def test_the_judge_says_so_when_the_real_briefing_is_the_unverified_one(self):
        found = self.r["keep_real_caveat"]
        self.assertEqual(len(found), 1, found)
        self.assertIn("does not name the standalone EXE", found[0])

    def test_the_judge_notices_a_tilde_in_the_exe_name_the_real_briefing_would_print(self):
        found = self.r["keep_real_tilde_exe"]
        self.assertTrue(any("starts with ~: ~tilde_work.exe" in f for f in found), found)


# --- the rules on the real files ---------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_batch_file_writes_the_names_and_the_briefing_the_script_reads(self):
        self.assertEqual(batch_problems(self.batch, self.script), [])

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
        self.assertEqual(len(judge_cases()), 57)
        self.assertEqual(sanitize("~tilde_work"), "_tilde_work")

    def test_every_judge_the_driver_is_asked_for_is_a_function_of_the_script(self):
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))

    def test_the_files_of_the_user_the_script_compares_are_the_ones_the_briefing_and_the_bootstrapper_leave(self):
        self.assertEqual(script_list(self.script, "userFiles"), USER_FILES)


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

    def problems(self, batch, script=None):
        return batch_problems(batch, self.script if script is None else script)

    def test_a_renamed_setup_log_or_status_file_is_reported(self):
        bad = mutate(self.batch, 'set "LOG=~setup.log"\n', 'set "LOG=setup.log"\n')
        self.assertTrue(any("the setup log name" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'set "STATUS_FILE=~bootstrap.status.json"\n', 'set "STATUS_FILE=%~dp0~bootstrap.status.json"\n')
        self.assertTrue(any("the status file name" in f for f in self.problems(bad)), self.problems(bad))

    def test_an_environment_name_that_keeps_the_tilde_is_reported(self):
        bad = mutate(self.batch, "-replace '[^A-Za-z0-9_-]', '_'", "-replace '[^A-Za-z0-9_~-]', '_'")
        found = self.problems(bad)
        self.assertTrue(any("is no longer derived with -replace '[^A-Za-z0-9_-]', '_'" in f for f in found), found)

    def test_a_second_line_that_derives_the_environment_name_is_reported(self):
        bad = self.batch + '\nfor /f "usebackq delims=" %%I in (`x $san = 1`) do set "Y=%%I"\n'
        self.assertTrue(any("exactly one line that derives the environment name" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_script_whose_folder_and_exe_disagree_is_reported(self):
        bad = mutate(norm(self.script), "$expectedExe = '_tilde_work.exe'", "$expectedExe = '~tilde_work.exe'")
        self.assertTrue(any("the script expects ~tilde_work.exe" in f for f in self.problems(self.batch, bad)), self.problems(self.batch, bad))
        bad = mutate(norm(self.script), "$folderName = '~tilde_work'", "$folderName = 'tilde_work'")
        bad = mutate(bad, "$expectedExe = '_tilde_work.exe'", "$expectedExe = 'tilde_work.exe'")
        self.assertTrue(any("does not start with ~" in f for f in self.problems(self.batch, bad)), self.problems(self.batch, bad))
        self.assertTrue(any("could not be read" in f for f in self.problems(self.batch, "param()\n")))

    def test_an_exe_line_that_keeps_a_tilde_or_moves_is_reported(self):
        bad = mutate(self.batch, "echo    dist\\%ENVNAME%.exe\n", "echo    dist\\~%ENVNAME%.exe\n")
        self.assertTrue(any("exactly one" in f and "standalone application" in f for f in self.problems(bad)), self.problems(bad))
        moved = mutate(self.batch, "echo  Your standalone application is ready:\necho    dist\\%ENVNAME%.exe\n",
                       "echo  Your standalone application is ready:\necho.\necho    dist\\%ENVNAME%.exe\n")
        self.assertTrue(any("directly follow" in f for f in self.problems(moved)), self.problems(moved))

    def test_a_missing_or_reordered_heading_is_reported(self):
        # the headings are also in :print_no_exe_briefing, so the anchors run on into the lines only this panel has
        bad = mutate(self.batch, "echo  KEEP these files with your project:\necho    requirements.txt  -- packages your app depends on\necho    runtime.txt       -- Python version pin\necho.\necho  SAFE TO DELETE to reclaim disk space:\necho    .*_env\\ folders   -- environment directories\necho    ~* files          -- tilde-prefix work files (e.g. ~setup.log)\necho    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n",
                     "echo  SAFE TO DELETE to reclaim disk space:\necho    .*_env\\ folders   -- environment directories\necho    ~* files          -- tilde-prefix work files (e.g. ~setup.log)\necho    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n")
        found = self.problems(bad)
        self.assertTrue(any("the panel must hold the KEEP heading once" in f for f in found), found)

    def test_a_tilde_name_in_the_keep_list_is_reported(self):
        bad = mutate(self.batch, "echo    runtime.txt       -- Python version pin\necho.\necho  SAFE TO DELETE to reclaim disk space:\necho    .*_env\\ folders   -- environment directories\necho    ~* files          -- tilde-prefix work files (e.g. ~setup.log)\necho    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n",
                     "echo    runtime.txt       -- Python version pin\necho    ~notes.txt        -- notes\necho.\necho  SAFE TO DELETE to reclaim disk space:\necho    .*_env\\ folders   -- environment directories\necho    ~* files          -- tilde-prefix work files (e.g. ~setup.log)\necho    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n")
        found = self.problems(bad)
        self.assertTrue(any("keep a file whose name starts with ~: ~notes.txt" in f for f in found), found)

    def test_a_file_to_keep_that_the_script_does_not_compare_is_reported(self):
        bad = mutate(self.batch, "echo    runtime.txt       -- Python version pin\necho.\necho  SAFE TO DELETE to reclaim disk space:\necho    .*_env\\ folders   -- environment directories\necho    ~* files          -- tilde-prefix work files (e.g. ~setup.log)\necho    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n",
                     "echo    runtime.txt       -- Python version pin\necho    notes.txt         -- notes\necho.\necho  SAFE TO DELETE to reclaim disk space:\necho    .*_env\\ folders   -- environment directories\necho    ~* files          -- tilde-prefix work files (e.g. ~setup.log)\necho    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n")
        found = self.problems(bad)
        self.assertTrue(any("tells the user to keep notes.txt, which the script's $userFiles does not hold" in f for f in found), found)

    def test_a_delete_list_that_stops_naming_the_tilde_files_is_reported(self):
        tail = "echo    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n"
        bad = mutate(self.batch, "echo    ~* files          -- tilde-prefix work files (e.g. ~setup.log)\n" + tail, tail)
        self.assertTrue(any("no longer names the ~* files" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_panel_without_a_closing_rule_is_reported(self):
        bad = mutate(self.batch, "echo    build\\            -- PyInstaller build cache\necho ============================================================\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n",
                     "echo    build\\            -- PyInstaller build cache\necho.\nif defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat\n")
        self.assertTrue(any("no closing rule follows the SAFE TO DELETE list" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_block_that_cannot_be_cut_is_reported(self):
        bad = mutate(self.batch, "\n:print_postflight_briefing\n", "\n:print_postflight_briefingx\n")
        self.assertTrue(any("cannot be cut" in f for f in self.problems(bad)), self.problems(bad))
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the workflow, the registry and the shall list is shown to fail on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def problems(self, text):
        return script_problems(text)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "    id      = 'self.tilde.keepfiles'\n    req     = 'REQ-015.7'\n", "    id      = $rowId\n    req     = 'REQ-015.7'\n")
        self.assertTrue(any("literal at exactly 3" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "    id      = 'self.tilde.deletable'\n    req     = 'REQ-015.8'\n", "    id      = 'self.tilde.deletable'\n    req     = 'REQ-015'\n")
        self.assertTrue(any("req tag" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_program_that_stops_importing_a_package_or_changes_its_line_is_caught(self):
        bad = mutate(self.script, "import colorama`nprint(", "import sys`nprint(")
        self.assertTrue(any("import of colorama" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$marker = 'TILDE_APP_RAN'\n", "$marker = 'APP_RAN'\n")
        self.assertTrue(any("prints TILDE_APP_RAN" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_program_folder_or_exe_name_that_changes_is_caught(self):
        bad = mutate(self.script, "$folderName = '~tilde_work'\n", "$folderName = 'tilde_work'\n")
        self.assertTrue(any("no longer ~tilde_work" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_list_of_the_users_files_that_changes_is_caught(self):
        bad = mutate(self.script, "$userFiles = @('app.py', 'requirements.txt', 'runtime.txt', '.gitignore', '.gitattributes')", "$userFiles = @('app.py')")
        self.assertTrue(any("files of the user the second row compares" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_skip_hook_that_is_no_longer_cleared_or_set_is_caught(self):
        bad = mutate(self.script, "HP_SKIP_ENTRY_SMOKE = ''; ", "")
        self.assertTrue(any("no longer clears HP_SKIP_ENTRY_SMOKE" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "HP_SKIP_PIPREQS = ''; ", "HP_SKIP_PIPREQS = '1'; ")
        self.assertTrue(any("no longer clears HP_SKIP_PIPREQS" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "HP_SKIP_PEP723_WRITEBACK = '1'", "HP_SKIP_PEP723_WRITEBACK = ''")
        self.assertTrue(any("no longer sets HP_SKIP_PEP723_WRITEBACK" in f for f in self.problems(bad)), self.problems(bad))

    def test_open_standard_input_a_missing_limit_and_a_missing_kill_are_caught(self):
        bad = mutate(self.script, "2>&1 < nul\")", "2>&1\")")
        self.assertTrue(any("standard input closed" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$runTimeoutMs = 15 * 60 * 1000", "$runTimeoutMs = 0")
        self.assertTrue(any("taskkill /F /T" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_wrapper_or_console_log_that_is_no_longer_a_tilde_file_is_caught(self):
        bad = mutate(self.script, "$wrapper = Join-Path $Dir '~tl_launch.cmd'", "$wrapper = Join-Path $Dir 'tl_launch.cmd'")
        self.assertTrue(any("launch wrapper" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "-LogName '~tl_console2.log'", "-LogName 'tl_console2.log'")
        self.assertTrue(any("~tl_console2.log" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_scenario_that_runs_in_another_order_is_caught(self):
        bad = mutate(self.script, "$deleted = Remove-TildeEntries -Dir $dir\n", "$deleted = [pscustomobject]@{ Removed = @(); Left = @() }\n$ignored = Remove-TildeEntries -Dir $dir\n")
        self.assertTrue(any("no longer runs in this order" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "if ($run1.Finished -and $run1.State -eq 'ok') {", "if ($true) {")
        self.assertTrue(any("no longer guarded" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_deletion_that_stops_removing_every_tilde_entry_is_caught(self):
        bad = mutate(self.script, "foreach ($sub in @('', 'dist', 'build')) {", "foreach ($sub in @('')) {")
        self.assertTrue(any("Remove-TildeEntries no longer removes" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "Remove-Item -LiteralPath $e.FullName -Recurse -Force -ErrorAction Stop", "Remove-Item -LiteralPath $e.FullName -Force -ErrorAction Stop")
        self.assertTrue(any("Remove-TildeEntries no longer removes" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_verdict_that_stops_using_the_judges_is_caught(self):
        bad = mutate(self.script, "-FolderName $folderName -ExeLeaf $expectedExe -Outside $outside)", "-FolderName $folderName -ExeLeaf $expectedExe -Outside @())")
        self.assertTrue(any("REQ-003.3 no longer comes from" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "-FolderName $folderName -ExpectedExe $expectedExe)", "-FolderName 'x' -ExpectedExe $expectedExe)")
        self.assertTrue(any("REQ-015.7 no longer comes from" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "-Out2 $run2.Out -ExeBack $exeBack)", "-Out2 $marker -ExeBack $exeBack)")
        self.assertTrue(any("REQ-015.8 no longer comes from" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$briefing = Get-Briefing $run1.Console", "$briefing = Get-Briefing $run1.Setup")
        self.assertTrue(any("console of the first bootstrap" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.script, "$delPass = ($delProblems.Count -eq 0)", "$delPass = $true")
        self.assertTrue(any("judged by its list of problems" in f for f in self.problems(bad)), self.problems(bad))

    def test_an_evidence_file_written_before_the_last_row_is_caught(self):
        bad = mutate(self.script, "'~tilde_files_evidence.txt'", "'~tilde_files_other.txt'")
        self.assertTrue(any("evidence file" in f for f in self.problems(bad)), self.problems(bad))

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
        self.assertIsNotNone(block)
        bad = self.workflow.replace(block, block.replace("        shell: pwsh\n", "        shell: pwsh\n        continue-on-error: true\n", 1))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(bad)))

    def test_a_missing_step_or_upload_is_caught(self):
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\selfapps_tilde_files.ps1"])
        for pattern in UPLOADS:
            bad = self.workflow.replace(pattern, "")
            self.assertTrue(any(pattern in f for f in workflow_problems(bad)), pattern)

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        self.assertTrue(registry_problems(text.replace("self.tilde.deletable", "self.tilde.deletablex")))
        self.assertTrue(registry_problems("```\nself.tilde.workfolder\nself.tilde.keepfiles\n```\nprose: self.tilde.deletable\n"))

    def test_a_shall_that_is_still_listed_as_a_gap_is_caught(self):
        for shall in GAP_SHALLS:
            self.assertTrue(shall_list_problems('    "%s": "gap: x",\n' % shall), shall)
        self.assertEqual(shall_list_problems('    "REQ-015.70": "gap: x",\n'), [])


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

    def gone(self, got, name, needle):
        self.assertFalse(any(needle in f for f in got[name]), got[name])

    # --- Get-Briefing and the small helpers
    def test_a_briefing_reader_that_does_not_stop_at_the_delete_list_is_caught(self):
        got = self.run_mutated("            if ($line -match 'SAFE TO DELETE') { $inKeep = $false }", "            if ($false) { $inKeep = $false }",
                               ["brief_only_the_delete_list", "brief_success"])
        self.assertNotEqual(got["brief_success"][0]["Keep"], GOOD_KEEP)

    def test_a_briefing_reader_that_never_finds_the_keep_list_is_caught(self):
        got = self.run_mutated("if ($line -match 'KEEP these files with your project:') { $inKeep = $true; continue }",
                               "if ($false) { $inKeep = $true; continue }", ["brief_success"])
        self.assertEqual(got["brief_success"][0]["Keep"], [])

    def test_a_briefing_reader_that_takes_the_exe_from_any_line_is_caught(self):
        got = self.run_mutated("            $m2 = [regex]::Match([string]$all[$i + 1], '^\\s+(dist\\\\\\S+\\.exe)\\s*$')",
                               "            $m2 = [regex]::Match([string]$all[$i + 2], '^\\s+(dist\\\\\\S+\\.exe)\\s*$')", ["brief_exe_not_on_the_next_line", "brief_success"])
        self.assertEqual(got["brief_success"][0]["Exe"], "")

    def test_a_normalizer_that_keeps_blank_lines_or_spaces_is_caught(self):
        got = self.run_mutated("        if ($t) { [void]$out.Add($t) }", "        [void]$out.Add($t)", ["norm_trim_blank_and_endings"])
        self.assertNotEqual(got["norm_trim_blank_and_endings"], ["a\nb"])
        got = self.run_mutated("        $t = ([string]$l).Trim()", "        $t = ([string]$l)", ["norm_trim_blank_and_endings"])
        self.assertNotEqual(got["norm_trim_blank_and_endings"], ["a\nb"])

    def test_a_snapshot_comparison_that_ignores_a_changed_file_or_a_removed_one_is_caught(self):
        got = self.run_mutated("    foreach ($k in @($a.Keys)) { if ((-not $b.ContainsKey($k)) -or ($b[$k] -ne $a[$k])) { [void]$changed.Add($k) } }",
                               "    foreach ($k in @($a.Keys)) { if (-not $b.ContainsKey($k)) { [void]$changed.Add($k) } }", ["snap_changed_file"])
        self.assertEqual(got["snap_changed_file"], [])
        got = self.run_mutated("    foreach ($k in @($b.Keys)) { if (-not $a.ContainsKey($k)) { [void]$changed.Add($k) } }",
                               "    foreach ($k in @($b.Keys)) { if ($false) { [void]$changed.Add($k) } }", ["snap_all_gone"])
        self.assertEqual(got["snap_all_gone"], [])

    # --- Get-WorkfolderProblems
    def test_a_workfolder_judge_that_forgets_a_bootstrap_that_never_finished_is_caught(self):
        old = ("    if (-not $Run.Finished) { return @('the bootstrap did not finish within the time limit') }\n"
               "    if ($Run.State -ne 'ok') { return @(('the bootstrap ended with state [{0}], not ok, so the build output was not judged' -f $Run.State)) }")
        got = self.run_mutated(old, old.replace("if (-not $Run.Finished) {", "if ($false) {"), ["work_unfinished"])
        self.gone(got, "work_unfinished", "did not finish")

    def test_a_workfolder_judge_that_forgets_a_failed_bootstrap_is_caught(self):
        old = "    if ($Run.State -ne 'ok') { return @(('the bootstrap ended with state [{0}], not ok, so the build output was not judged' -f $Run.State)) }"
        got = self.run_mutated(old, old.replace("if ($Run.State -ne 'ok') {", "if ($false) {"), ["work_state_error"])
        self.assertEqual(got["work_state_error"], [])

    def test_a_workfolder_judge_that_forgets_a_missing_file_is_caught(self):
        got = self.run_mutated("        if (@($Inside) -notcontains $need) {", "        if ($false) {", ["work_no_setup_log", "work_no_exe"])
        self.assertEqual(got["work_no_setup_log"], [])
        self.assertEqual(got["work_no_exe"], [])

    def test_a_workfolder_judge_that_forgets_entries_beside_the_folder_is_caught(self):
        got = self.run_mutated("    if ($others.Count -gt 0) {", "    if ($false) {", ["work_entries_beside"])
        self.assertEqual(got["work_entries_beside"], [])

    def test_a_workfolder_judge_that_forgets_a_missing_program_folder_is_caught(self):
        got = self.run_mutated("    if (@($Beside) -notcontains $FolderName) {", "    if ($false) {", ["work_folder_not_beside"])
        self.gone(got, "work_folder_not_beside", "is not in the folder the script made for it")

    def test_a_workfolder_judge_that_forgets_changes_outside_is_caught(self):
        got = self.run_mutated("    if (@($Outside).Count -gt 0) {", "    if ($false) {", ["work_outside_changes"])
        self.assertEqual(got["work_outside_changes"], [])

    # --- Get-KeepProblems
    def test_a_keep_judge_that_forgets_a_bootstrap_that_never_finished_is_caught(self):
        old = ("    if (-not $Run.Finished) { return @('the bootstrap did not finish within the time limit') }\n"
               "    if ($Run.State -ne 'ok') { return @(('the bootstrap ended with state [{0}], not ok, so the briefing was not judged' -f $Run.State)) }")
        got = self.run_mutated(old, old.replace("if (-not $Run.Finished) {", "if ($false) {"), ["keep_unfinished"])
        self.gone(got, "keep_unfinished", "did not finish")

    def test_a_keep_judge_that_forgets_a_failed_bootstrap_is_caught(self):
        old = "    if ($Run.State -ne 'ok') { return @(('the bootstrap ended with state [{0}], not ok, so the briefing was not judged' -f $Run.State)) }"
        got = self.run_mutated(old, old.replace("if ($Run.State -ne 'ok') {", "if ($false) {"), ["keep_state_error"])
        self.assertEqual(got["keep_state_error"], [])

    def test_a_keep_judge_that_forgets_a_folder_without_a_tilde_is_caught(self):
        got = self.run_mutated("    if (-not $FolderName.StartsWith('~')) {", "    if ($false) {", ["keep_folder_without_tilde"])
        self.assertEqual(got["keep_folder_without_tilde"], [])

    def test_a_keep_judge_that_forgets_an_empty_list_is_caught(self):
        got = self.run_mutated("    if ($keep.Count -eq 0) {", "    if ($false) {", ["keep_empty_list"])
        self.gone(got, "keep_empty_list", "printed no file under")

    def test_a_keep_judge_that_forgets_a_file_the_briefing_stopped_naming_is_caught(self):
        got = self.run_mutated("        if ($keep -notcontains $need) {", "        if ($false) {", ["keep_without_requirements", "keep_without_runtime"])
        self.assertEqual(got["keep_without_requirements"], [])
        self.assertEqual(got["keep_without_runtime"], [])

    def test_a_keep_judge_that_forgets_a_tilde_name_to_keep_is_caught(self):
        got = self.run_mutated("        if ($name.StartsWith('~')) {", "        if ($false) {", ["keep_tilde_name"])
        self.gone(got, "keep_tilde_name", "names a file to keep that starts with ~")

    def test_a_keep_judge_that_forgets_a_file_that_is_not_there_is_caught(self):
        got = self.run_mutated("        elseif (@($Present) -notcontains $name) {", "        elseif ($false) {", ["keep_file_missing"])
        self.assertEqual(got["keep_file_missing"], [])

    def test_a_keep_judge_that_forgets_the_git_files_is_caught(self):
        old = "    foreach ($name in @('.gitignore', '.gitattributes')) {\n        if (@($Present) -notcontains $name) {"
        got = self.run_mutated(old, old.replace("if (@($Present)", "if ($false -and @($Present)"), ["keep_no_gitignore", "keep_no_gitattributes"])
        self.assertEqual(got["keep_no_gitignore"], [])
        self.assertEqual(got["keep_no_gitattributes"], [])

    def test_a_keep_judge_that_forgets_a_briefing_without_the_exe_is_caught(self):
        # without the guard the judge reads an empty path, which PowerShell refuses: the case cannot pass quietly
        with self.assertRaises(AssertionError):
            self.run_mutated("    if (-not $exe) {", "    if ($false) {", ["keep_no_exe"])

    def test_a_keep_judge_that_forgets_a_tilde_in_the_exe_name_is_caught(self):
        got = self.run_mutated("        if ($leaf.StartsWith('~')) {", "        if ($false) {", ["keep_exe_tilde_name"])
        self.gone(got, "keep_exe_tilde_name", "starts with ~: ~tilde_work.exe")

    def test_a_keep_judge_that_forgets_the_expected_exe_name_is_caught(self):
        got = self.run_mutated("        if ($leaf -ne $ExpectedExe) {", "        if ($false) {", ["keep_exe_wrong_name"])
        self.assertEqual(got["keep_exe_wrong_name"], [])

    def test_a_keep_judge_that_forgets_an_exe_that_is_not_there_is_caught(self):
        got = self.run_mutated("        if (@($Present) -notcontains $exe) {", "        if ($false) {", ["keep_exe_missing"])
        self.assertEqual(got["keep_exe_missing"], [])

    # --- Get-DeletableProblems
    def test_a_deletion_judge_that_forgets_a_first_bootstrap_that_never_finished_is_caught(self):
        got = self.run_mutated("    if (-not $Run1.Finished) {", "    if ($false) {", ["del_run1_unfinished"])
        self.gone(got, "del_run1_unfinished", "did not finish")

    def test_a_deletion_judge_that_forgets_a_failed_first_bootstrap_is_caught(self):
        got = self.run_mutated("    if ($Run1.State -ne 'ok') {", "    if ($false) {", ["del_run1_error"])
        self.assertEqual(got["del_run1_error"], [])

    def test_a_deletion_judge_that_forgets_a_deletion_that_took_nothing_is_caught(self):
        got = self.run_mutated("    if (@($Removed).Count -lt 3 -or @($Removed) -notcontains '~setup.log') {", "    if ($false) {", ["del_nothing_removed", "del_no_setup_log_removed"])
        self.assertEqual(got["del_nothing_removed"], [])
        self.assertEqual(got["del_no_setup_log_removed"], [])

    def test_a_deletion_judge_that_forgets_an_entry_that_could_not_be_removed_is_caught(self):
        got = self.run_mutated("    if (@($Left).Count -gt 0) {", "    if ($false) {", ["del_left"])
        self.assertEqual(got["del_left"], [])

    def test_a_deletion_judge_that_forgets_a_second_bootstrap_that_never_finished_is_caught(self):
        got = self.run_mutated("    if (-not $Run2.Finished) {", "    if ($false) {", ["del_run2_unfinished"])
        self.gone(got, "del_run2_unfinished", "did not finish")

    def test_a_deletion_judge_that_forgets_a_failed_second_bootstrap_is_caught(self):
        got = self.run_mutated("    if ($Run2.State -ne 'ok') {", "    if ($false) {", ["del_run2_state"])
        self.assertEqual(got["del_run2_state"], [])

    def test_a_deletion_judge_that_forgets_the_exit_code_of_the_second_bootstrap_is_caught(self):
        got = self.run_mutated("    if ($Run2.Exit -ne 0) {", "    if ($false) {", ["del_run2_exit"])
        self.assertEqual(got["del_run2_exit"], [])

    def test_a_deletion_judge_that_forgets_the_programs_own_line_is_caught(self):
        got = self.run_mutated("    if (-not ([string]$Out2).Contains($Marker)) {", "    if ($false) {", ["del_run2_no_marker"])
        self.assertEqual(got["del_run2_no_marker"], [])

    def test_a_deletion_judge_that_forgets_an_exe_that_did_not_come_back_is_caught(self):
        got = self.run_mutated("    if (-not $ExeBack) {", "    if ($false) {", ["del_exe_not_back"])
        self.assertEqual(got["del_exe_not_back"], [])

    def test_a_deletion_judge_that_forgets_a_file_of_the_user_that_is_gone_is_caught(self):
        got = self.run_mutated("        if (-not $a.ContainsKey($k)) {", "        if ($false) {", ["del_user_file_gone"])
        self.gone(got, "del_user_file_gone", "is gone after the second run")

    def test_a_deletion_judge_that_forgets_a_file_of_the_user_that_changed_is_caught(self):
        got = self.run_mutated("        elseif ($a[$k] -ne $b[$k]) {", "        elseif ($false) {", ["del_user_file_different"])
        self.assertEqual(got["del_user_file_different"], [])

    def test_a_deletion_judge_that_forgets_a_changed_program_is_caught(self):
        got = self.run_mutated("    if ($AppNow -ne $SeedApp) {", "    if ($false) {", ["del_app_changed"])
        self.assertEqual(got["del_app_changed"], [])


if __name__ == "__main__":
    unittest.main()
