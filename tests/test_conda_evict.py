"""Item 122 (README REQ-020.5 and REQ-020.9): a damaged conda is deleted and replaced by a fresh install, and a failed fresh install stops the run.

REQ-020.5 says that after the user answers Y to the question about a damaged conda installation the bootstrapper deletes it, installs
a fresh Miniconda in its place and goes on; REQ-020.9 says that when no conda installation exists after that fresh install the run stops
with exit code 4 and says that the fresh install failed. Until this item the README called both "shown by inspection": the existing rows
reach the answer Y only through the test flag HP_TEST_SKIP_EVICT (which skips the deletion and the download) or stop at a locked file
(REQ-020.6), so nothing ran the deletion followed by the install, and nothing ran the exit code 4.

tests/selfapps_conda_evict.ps1 (rows self.corrupt.conda.evict.install and self.corrupt.conda.evict.installfail; contract-uv lane,
gating) cuts the block :evict_and_rebuild and the subroutine :select_conda_bat out of run_setup.bat, runs them under cmd.exe against a
driver of stubs (three scenarios: the eviction with a fresh install, the control with the test flag set, a fresh install that leaves
nothing) and starts the real bootstrapper once with the damaged installation, the answer Y and no network, which must stop with exit
code 4 after the four log lines of the contract.

What really happens is shown on Windows by that script. These rules read run_setup.bat, the script, batch-check.yml,
docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, and run the script's own judging functions through a real pwsh on
synthetic runs (a run that passes, and one run for each way to be wrong), so a reworded log line, a block that reaches something the
driver does not define, a deletion that moved out of its guard, a scenario that stops being the one the shall names, a judge that stops
judging or a step that stops gating fails here with a sentence, before a Windows run is needed. Synthetic cases prove each rule can fail.
The shared helpers are in tests/judge_support.py, and tests/test_judge_support.py holds the tests of those helpers (the strict driver
among them).
"""
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import (PWSH, after, case, cut_block, drop, enclosing, lines_of, live_bat, live_hash, mutate, norm,  # noqa: E402
                           registry_ids, run_cases, step_block, swap, text_of, variables_in)

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_conda_evict.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
SCRIPT_NAME = "selfapps_conda_evict.ps1"

ROW_REQS = {"self.corrupt.conda.evict.install": "REQ-020.5", "self.corrupt.conda.evict.installfail": "REQ-020.9"}
ROW_IDS = tuple(ROW_REQS)
GAP_SHALLS = ("REQ-020.5", "REQ-020.9")

EVICT_START = ":evict_and_rebuild"
EVICT_END = ":conda_bulk_install"
SELECT_START = ":select_conda_bat"
SELECT_END = ":download_miniconda_exe"

# Every variable the two blocks read or set. The script's driver sets or clears each of them, so none comes from the runner.
KNOWN_EVICT = {"HP_TEST_SKIP_EVICT", "MINICONDA_ROOT", "TEMP", "CONDA_BAT", "HP_CONDA_JUST_INSTALLED", "HP_ENV_STATE_RESULT"}
KNOWN_SELECT = {"CONDA_BAT", "CONDA_MAIN", "CONDA_ALT"}
# The labels the evict block calls: the driver defines the first four, the fifth is the real subroutine cut out beside it.
CALLS_OF_EVICT = [":die", ":download_miniconda_exe", ":log", ":select_conda_bat", ":try_conda_install"]

GUARD = "if not defined HP_TEST_SKIP_EVICT ("
RMDIR = 'rmdir /s /q "%MINICONDA_ROOT%" 2>nul'
EVICTED_LOG = 'call :log "[INFO] Self-healing: corrupt conda evicted from %MINICONDA_ROOT%."'
DIE_LOCKED = 'call :die "[ERROR] Could not delete corrupt conda dir; files may be locked." 3'
DIE_FRESH = 'call :die "[ERROR] Fresh Miniconda install failed after self-healing eviction." 4'
FRESH_GUARD = "if not defined CONDA_BAT ("
SELECT_LINES = [
    'set "CONDA_BAT="',
    'if exist "%CONDA_MAIN%" set "CONDA_BAT=%CONDA_MAIN%"',
    'if not defined CONDA_BAT if exist "%CONDA_ALT%" set "CONDA_BAT=%CONDA_ALT%"',
    'if defined CONDA_BAT if not exist "%CONDA_BAT%" set "CONDA_BAT="',
    "exit /b 0",
]
# The four log texts the real offline run is judged by. Each must stay in exactly one live log or :die line of the batch file.
LOG_TEXTS = (
    "Corrupt conda binary detected at: ",
    "Self-healing: corrupt conda evicted from ",
    "Offline mode: skipping Miniconda download.",
    "Fresh Miniconda install failed after self-healing eviction.",
)

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~conda_evict_evidence.txt",
    "tests/~selftest_condaevict/*/~driver*",
    "tests/~selftest_condaevict/offline/~setup.log",
    "tests/~selftest_condaevict/offline/~bootstrap.status.json",
)
JUDGES = ["Get-LineIndex", "Get-EvictProblems", "Get-OfflineEvictProblems"]


# --- the batch file: what the script assumes about the two blocks -------------------------------------------------------------

def block_problems(batch, script_text):
    """README REQ-020.5 and REQ-020.9 in the batch file: the deletion and the install sit behind the test flag's guard, they run in
    the order the script's ledger reads, the failure of the fresh install ends with exit code 4, and the blocks reach only what the
    driver defines."""
    found = []
    stripped = [ln.strip() for ln in lines_of(batch)]
    for label in (EVICT_START, EVICT_END, SELECT_START, SELECT_END):
        n = sum(1 for ln in stripped if ln == label)
        if n != 1:
            found.append("the label %s appears %d time(s); expected exactly once" % (label, n))
    if found:
        return found
    evict = cut_block(batch, EVICT_START, EVICT_END)
    select = cut_block(batch, SELECT_START, SELECT_END)
    if evict is None:
        found.append("the block from %s to %s cannot be cut" % (EVICT_START, EVICT_END))
    if select is None:
        found.append("the block from %s to %s cannot be cut" % (SELECT_START, SELECT_END))
    if found:
        return found
    ebody = [ln.strip() for ln in live_bat(evict)]
    sbody = [ln.strip() for ln in live_bat(select)]

    labels = [ln for ln in ebody if ln.startswith(":")]
    if labels != [EVICT_START]:
        found.append("the eviction block's labels are %r, the script's driver was written for one label, %r" % (labels, EVICT_START))
    if sbody != [SELECT_START] + SELECT_LINES:
        found.append("the lines of %s are %r, the script's driver and the judge were written for %r" % (SELECT_START, sbody, [SELECT_START] + SELECT_LINES))
    calls = sorted(set(re.findall(r"(?i)\bcall\s+(:[A-Za-z_][A-Za-z0-9_]*)", "\n".join(ebody + sbody))))
    if calls != CALLS_OF_EVICT:
        found.append("the blocks call %r; the driver defines :log, :die, :download_miniconda_exe and :try_conda_install, the rest is cut out beside them: %r" % (calls, CALLS_OF_EVICT))
    gotos = sorted(set(re.findall(r"(?i)\bgoto\s+(:?[A-Za-z_][A-Za-z0-9_]*)", "\n".join(ebody + sbody))))
    if gotos != [":after_conda_bat_validation"]:
        found.append("the blocks go to %r; the driver was written for exactly one jump, to :after_conda_bat_validation" % (gotos,))
    unknown = sorted((variables_in(evict) - KNOWN_EVICT) | (variables_in(select) - KNOWN_SELECT))
    if unknown:
        found.append("the blocks read or set %s, which the driver of tests/%s does not define or clear" % (", ".join(unknown), SCRIPT_NAME))
    driver_sets = set(re.findall(r"'set \"([A-Za-z_][A-Za-z0-9_]*)=", norm(script_text)))
    missing = sorted((KNOWN_EVICT | KNOWN_SELECT) - driver_sets)
    if missing:
        found.append("the driver of tests/%s does not set or clear %s" % (SCRIPT_NAME, ", ".join(missing)))

    def index_of(text, what):
        hits = [i for i, ln in enumerate(ebody) if ln == text]
        if len(hits) != 1:
            found.append("%s: expected exactly one live line %r in the eviction block, found %d" % (what, text, len(hits)))
            return None
        return hits[0]

    rmdir = index_of(RMDIR, "the deletion of the damaged folder")
    die_locked = index_of(DIE_LOCKED, "the report of a folder that could not be deleted")
    evicted = index_of(EVICTED_LOG, "the log line of the eviction")
    clear_bat = index_of('set "CONDA_BAT="', "the clearing of CONDA_BAT")
    clear_just = index_of('set "HP_CONDA_JUST_INSTALLED="', "the clearing of HP_CONDA_JUST_INSTALLED")
    clear_state = index_of('set "HP_ENV_STATE_RESULT="', "the clearing of HP_ENV_STATE_RESULT")
    download = index_of("call :download_miniconda_exe", "the download")
    install = index_of("call :try_conda_install", "the install")
    select_call = index_of("call :select_conda_bat", "the selection of the fresh conda.bat")
    die_fresh = index_of(DIE_FRESH, "the report of a failed fresh install")
    just = index_of('set "HP_CONDA_JUST_INSTALLED=1"', "the mark that conda was just installed")
    jump = index_of("goto :after_conda_bat_validation", "the jump back to the validation")
    order = [("the deletion", rmdir), ("the report of a folder that could not be deleted", die_locked), ("the log line of the eviction", evicted),
             ("the clearing of CONDA_BAT", clear_bat), ("the download", download), ("the install", install),
             ("the selection of the fresh conda.bat", select_call), ("the report of a failed fresh install", die_fresh),
             ("the mark that conda was just installed", just), ("the jump back to the validation", jump)]
    known = [(name, at) for name, at in order if at is not None]
    for (n1, a1), (n2, a2) in zip(known, known[1:]):
        if a1 > a2:
            found.append("%s must come before %s, or the ledger of the script reads the wrong order" % (n1, n2))
    for name, at in (("the clearing of HP_CONDA_JUST_INSTALLED", clear_just), ("the clearing of HP_ENV_STATE_RESULT", clear_state)):
        if at is not None and evicted is not None and download is not None and not evicted < at < download:
            found.append("%s must sit between the log line of the eviction and the download" % name)

    def inside(at, want, what):
        if at is not None and enclosing(ebody, at) != want:
            found.append("%s must sit inside %r, found it inside %r" % (what, want, enclosing(ebody, at)))

    exist_root = 'if exist "%MINICONDA_ROOT%" ('
    exist_installer = 'if exist "%TEMP%\\miniconda.exe" ('
    inside(rmdir, [GUARD], "the deletion")
    inside(die_locked, [GUARD, exist_root], "the report of a folder that could not be deleted")
    inside(download, [GUARD], "the download")
    inside(install, [GUARD, exist_installer], "the install")
    inside(die_fresh, [FRESH_GUARD], "the report of a failed fresh install")
    inside(just, [], "the mark that conda was just installed")
    inside(jump, [], "the jump back to the validation")
    for at, code, what in ((die_locked, "3", "a folder that could not be deleted"), (die_fresh, "4", "a failed fresh install")):
        if at is not None and ebody[at + 1:at + 2] != ["exit /b " + code]:
            found.append("the report of %s is no longer followed directly by exit /b %s, so the run stops with another code or goes on" % (what, code))
    if ebody.count(GUARD) != 2:
        found.append("the block holds %d line(s) %r, expected 2 (the deletion and the download with the install)" % (ebody.count(GUARD), GUARD))
    return found


def flow_problems(batch, script_text):
    """The lines of the main flow the real offline run goes through, and the log texts its judge reads."""
    found = []
    live = [ln.strip() for ln in live_bat(lines_of(batch))]

    def count(text):
        return sum(1 for ln in live if ln == text)

    if count('if /I "%HP_HEAL_CHOICE%"=="Y" goto :evict_and_rebuild') != 1:
        found.append('the answer Y no longer reaches :evict_and_rebuild by exactly one line (if /I "%HP_HEAL_CHOICE%"=="Y" goto :evict_and_rebuild)')
    if sum(1 for ln in live if re.search(r"(?i)\bgoto\s+:evict_and_rebuild\b", ln)) != 1:
        found.append("more than one line goes to :evict_and_rebuild, so the block is reached by a path the script does not run")
    if count(":after_conda_bat_validation") != 1:
        found.append("the label :after_conda_bat_validation does not appear exactly once")
    answer = "if defined HP_TEST_HEAL_ANSWER goto :heal_prompt"
    ci = "if defined HP_CI_LANE goto :corrupt_ci_exit"
    if count(answer) != 1 or count(ci) != 1 or (answer in live and ci in live and live.index(answer) > live.index(ci)):
        found.append("the test answer must be tested exactly once and before the CI marker, or the real offline run is declined by the CI marker")
    pair = [i for i in range(len(live) - 1) if live[i] == 'call "%CONDA_BAT%" info >nul 2>&1' and live[i + 1] == "if errorlevel 1 goto :conda_binary_corrupt"]
    if len(pair) != 1:
        found.append("the health check no longer is the pair call conda.bat info and if errorlevel 1 goto :conda_binary_corrupt, found %d" % len(pair))
    for text in LOG_TEXTS:
        hits = [ln for ln in live if text in ln and (ln.startswith("call :log ") or ln.startswith("call :die "))]
        if len(hits) != 1:
            found.append("the text %r must be in exactly one live call :log or call :die line of the batch file, found %d" % (text, len(hits)))
    for text in ("Could not delete corrupt conda dir", "user declined rebuild"):
        if not any(text in ln and ln.startswith("call :die ") for ln in live):
            found.append("the text %r is no longer in a call :die line, so the judge's check that it is absent proves nothing" % text)
    flat = norm(script_text)
    for text in LOG_TEXTS + ("Could not delete corrupt conda dir", "user declined rebuild"):
        if "'" + text not in flat:
            found.append("the script no longer looks for the text %r" % text)
    return found


# --- the script ----------------------------------------------------------------------------------------------------------------

def script_problems(text):
    t = norm(text)
    live = live_hash(t)
    flat = "\n".join(live)
    found = []
    pairs = re.findall(r"\bid = '(self\.corrupt\.conda\.evict\.[a-z]+)'; req = '([^']*)'", t)
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if sorted(ids) != sorted(list(ROW_IDS) * 2):
        found.append("each row id must be a literal at exactly two Write-NdjsonRow call sites (the shared one and its own), found %r" % ids)
    if sorted(p[0] for p in pairs) != sorted(list(ROW_IDS) * 2):
        found.append("every row id must be followed by its literal req tag, found %r" % pairs)
    for rid, req in pairs:
        if req != ROW_REQS.get(rid):
            found.append("the row %s must carry the literal req tag %r, found %r" % (rid, ROW_REQS.get(rid), req))
    for scenario in ("Name = 'evict'; Kind = 'evict'; Skip = $false; Install = 'creates'",
                     "Name = 'control'; Kind = 'control'; Skip = $true; Install = 'creates'",
                     "Name = 'nofresh'; Kind = 'nofresh'; Skip = $false; Install = 'nothing'"):
        if scenario not in flat:
            found.append("the scenario list no longer holds: %s" % scenario)
    for need in ("-StartLabel ':evict_and_rebuild' -EndLabel ':conda_bulk_install'", "-StartLabel ':select_conda_bat' -EndLabel ':download_miniconda_exe'"):
        if need not in flat:
            found.append("the script no longer cuts %s out of run_setup.bat" % need)
    for need in ("'goto :evict_and_rebuild'", "'>\"%LEDGER%\" echo START'", "'>>\"%LEDGER%\" echo CONTINUED'", "'>>\"%LEDGER%\" echo END'",
                 "':after_conda_bat_validation'", "'>>\"%LEDGER%\" echo CONDA_BAT=%CONDA_BAT%'", "'>>\"%LEDGER%\" echo JUST_INSTALLED=%HP_CONDA_JUST_INSTALLED%'",
                 "'>>\"%LEDGER%\" echo ENV_STATE_RESULT=%HP_ENV_STATE_RESULT%'", "'call \"%CONDA_BAT%\" info >nul 2>&1'", "'>>\"%LEDGER%\" echo INFO_RC=%ERRORLEVEL%'",
                 "'>>\"%LEDGER%\" echo DIE code=%~2 msg=%~1'", "'>>\"%LEDGER%\" echo LOG %MSG%'", "':download_miniconda_exe'", "':try_conda_install'",
                 "':die'", "':log'", "'if \"%STUB_INSTALL%\"==\"creates\" call :stub_fresh'", r"""'>"%MINICONDA_ROOT%\condabin\conda.bat" echo @exit /b 0'""",
                 "-Lines @('@exit /b 1')", "'set \"HP_ENV_STATE_RESULT=stale\"'", "('set \"HP_TEST_SKIP_EVICT=' + $skip + '\"')"):
        if need not in flat:
            found.append("the driver or the damaged installation no longer holds %s" % need)
    if "call ~driver.bat > ~driver_console.txt 2>&1 < nul" not in flat:
        found.append("the driver no longer runs with standard input closed (< nul) and its console in ~driver_console.txt")
    if "call run_setup.bat > ~driver_console.txt 2>&1 < nul" not in flat:
        found.append("the real bootstrap no longer runs with standard input closed (< nul) and its console in ~driver_console.txt")
    # the numbers end at a digit boundary: -LimitMs 4800000 is a different limit and must not pass as 480000
    for pattern, shown in ((r"-LimitMs 180000(?!\d)", "-LimitMs 180000"), (r"-LimitMs 480000(?!\d)", "-LimitMs 480000"),
                           (r"taskkill\.exe /F /T /PID \$p\.Id", "taskkill.exe /F /T /PID $p.Id")):
        if not re.search(pattern, flat):
            found.append("a run that outlives its limit is no longer stopped: %s is missing" % shown)
    for name in ("HP_FORCE_CONDA_ONLY=1", "HP_OFFLINE_MODE=1", "HP_TEST_HEAL_ANSWER=Y"):
        if "'set \"%s\"'" % name not in flat:
            found.append("the real bootstrap no longer sets %s" % name)
    if "foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }" not in flat:
        found.append("the real bootstrap no longer clears every HP_ and PVW_ variable of the runner first")
    elif "'set \"HP_FORCE_CONDA_ONLY=1\"'" in flat and flat.index("(Get-ClearLines)") > flat.index("'set \"HP_FORCE_CONDA_ONLY=1\"'"):
        found.append("the variables of the runner are cleared after the real bootstrap's own are set, so the clear would remove them")
    for need in ("('set \"PUBLIC=' + (Join-Path $dir 'pub') + '\"')", "('set \"TEMP=' + (Join-Path $dir 'tmp') + '\"')"):
        if need not in flat:
            found.append("the real bootstrap no longer runs with a private folder: %s is missing" % need)
    call = "$found = @(Get-EvictProblems"
    if call not in flat:
        found.append("the driver scenarios are no longer judged by Get-EvictProblems")
    else:
        args = flat.split(call, 1)[1].split("\n", 1)[0]
        for need in ("-Kind $Scenario.Kind", "-Finished ([bool]$launch.Finished)", "-ExitText $exitText", "-LedgerText $ledger",
                     "-CondaMainPath $conda", "-RootPath $root"):
            if need not in args:
                found.append("the verdict no longer hands %s to Get-EvictProblems" % need)
    call = "$found = @(Get-OfflineEvictProblems"
    if call not in flat:
        found.append("the real bootstrap is no longer judged by Get-OfflineEvictProblems")
    else:
        args = flat.split(call, 1)[1][:600]
        for need in ("-Finished ([bool]$launch.Finished)", "-ExitText $exitText", "-ConsoleText $console", "-SetupText $setup", "-FakeBatPath $fakeBat",
                     "-RootPath $root", "-RootExists ([bool]$rootExists)", "-StubExists ([bool]$stubExists)", "-InstallerExists ([bool]$installerExists)"):
            if need not in args:
                found.append("the verdict no longer hands %s to Get-OfflineEvictProblems" % need)
    if "$installProblems = @($evict.Problems) + @($control.Problems)" not in flat:
        found.append("the install row is no longer judged by both the eviction and the control scenario")
    if "$failProblems = @($nofresh.Problems) + @($offline.Problems)" not in flat:
        found.append("the installfail row is no longer judged by both the stub scenario and the real offline bootstrap")
    for var in ("installProblems", "failProblems"):
        if "$pass = [bool](@($%s).Count -eq 0)" % var not in flat:
            found.append("the row of %s is no longer judged by its list of problems" % var)
    if flat.count("pass = $pass") < 2:
        found.append("the two rows no longer write pass = $pass")
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


# --- the workflow, the registry and the shall list ------------------------------------------------------------------------------

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
    """The shalls the rows trace are no longer listed as gaps (the shall-level ratchet only warns about a stale entry)."""
    return ["%s is still listed in UNTRACED_SHALLS although a row is tagged with it" % shall
            for shall in GAP_SHALLS if re.search(r'^\s*"%s":' % re.escape(shall), text, re.M)]


# --- the script's judging functions, run through a real pwsh ---------------------------------------------------------------------

ROOT = "C:\\w\\evict\\pub\\Documents\\Miniconda3"
CONDA = ROOT + "\\condabin\\conda.bat"
LOG_EVICTED = "LOG [INFO] Self-healing: corrupt conda evicted from " + ROOT + "."
LEDGER_DIE_FRESH = "DIE code=4 msg=[ERROR] Fresh Miniconda install failed after self-healing eviction."
LEDGER_DIE_LOCKED = "DIE code=3 msg=[ERROR] Could not delete corrupt conda dir; files may be locked."

EVICT = ["START", "PRE damaged=present", "PRE nested=present", LOG_EVICTED, "DOWNLOAD root=absent", "INSTALL root=absent",
         "INSTALL installer=present", "CONTINUED", "CONDA_BAT=" + CONDA, "JUST_INSTALLED=1", "ENV_STATE_RESULT=",
         "POST damaged=absent", "POST nested=absent", "POST fresh=present", "POST installer=absent", "INFO_RC=0", "END"]
CONTROL = ["START", "PRE damaged=present", "PRE nested=present", LOG_EVICTED, "CONTINUED", "CONDA_BAT=" + CONDA, "JUST_INSTALLED=1",
           "ENV_STATE_RESULT=", "POST damaged=present", "POST nested=present", "POST fresh=absent", "POST installer=absent",
           "INFO_RC=1", "END"]
NOFRESH = ["START", "PRE damaged=present", "PRE nested=present", LOG_EVICTED, "DOWNLOAD root=absent", "INSTALL root=absent",
           "INSTALL installer=present", LEDGER_DIE_FRESH]

SETUP_LINES = [
    "[2026-11-14 12:00:00.00] [ERROR] Corrupt conda binary detected at: " + CONDA,
    "[2026-11-14 12:00:01.00] [INFO] Self-healing: corrupt conda evicted from " + ROOT + ".",
    "[2026-11-14 12:00:01.50] [INFO] REQ-013: Offline mode: skipping Miniconda download.",
    "[2026-11-14 12:00:02.00] [ERROR] Fresh Miniconda install failed after self-healing eviction.",
]
CONSOLE_FAIL = "Sat 11/14/2026 12:00:02.00 [ERROR] Fresh Miniconda install failed after self-healing eviction.\r\n"


def evict_args(kind, lines, **over):
    args = dict(Kind=kind, Finished=True, ExitText=("4" if kind == "nofresh" else "0") + "\r\n", LedgerText=text_of(lines),
                CondaMainPath=CONDA, RootPath=ROOT)
    args.update(over)
    return args


def offline_args(**over):
    args = dict(Finished=True, ExitText="4\r\n", ConsoleText=CONSOLE_FAIL, SetupText=text_of(SETUP_LINES), FakeBatPath=CONDA, RootPath=ROOT,
                RootExists=False, StubExists=False, InstallerExists=False)
    args.update(over)
    return args


def judge_cases():
    c = []
    ev, ct, nf = "Get-EvictProblems", "Get-EvictProblems", "Get-EvictProblems"
    # --- Get-LineIndex
    c.append(case("index_found_case_blind", "Get-LineIndex", Lines=["a", "B", "c"], Text="b"))
    c.append(case("index_missing", "Get-LineIndex", Lines=["a"], Text="x"))
    c.append(case("index_first_of_two", "Get-LineIndex", Lines=["x", "a", "a"], Text="a"))
    c.append(case("index_whole_line_only", "Get-LineIndex", Lines=["ab", "a"], Text="a"))
    # --- Get-EvictProblems: the eviction with a fresh install
    c.append(case("evict_good", ev, **evict_args("evict", EVICT)))
    c.append(case("evict_unfinished", ev, **evict_args("evict", EVICT, Finished=False)))
    c.append(case("evict_no_start", ev, **evict_args("evict", drop(EVICT, "START"))))
    c.append(case("evict_wrong_exit", ev, **evict_args("evict", EVICT, ExitText="3\r\n")))
    c.append(case("evict_precondition_missing", ev, **evict_args("evict", swap(EVICT, "PRE damaged=present", "PRE damaged=absent"))))
    c.append(case("evict_no_log_line", ev, **evict_args("evict", drop(EVICT, LOG_EVICTED))))
    c.append(case("evict_log_line_twice", ev, **evict_args("evict", after(EVICT, LOG_EVICTED, LOG_EVICTED))))
    c.append(case("evict_download_into_present_root", ev, **evict_args("evict", swap(EVICT, "DOWNLOAD root=absent", "DOWNLOAD root=present"))))
    c.append(case("evict_install_without_installer", ev, **evict_args("evict", swap(EVICT, "INSTALL installer=present", "INSTALL installer=absent"))))
    c.append(case("evict_wrong_order", ev, **evict_args("evict", after(drop(EVICT, LOG_EVICTED), "INSTALL installer=present", LOG_EVICTED))))
    c.append(case("evict_died", ev, **evict_args("evict", after(EVICT, LOG_EVICTED, LEDGER_DIE_LOCKED))))
    c.append(case("evict_no_continue", ev, **evict_args("evict", EVICT[:7])))
    c.append(case("evict_continued_before_install", ev, **evict_args("evict", after(drop(EVICT, "CONTINUED"), LOG_EVICTED, "CONTINUED"))))
    c.append(case("evict_conda_bat_empty", ev, **evict_args("evict", swap(EVICT, "CONDA_BAT=" + CONDA, "CONDA_BAT="))))
    c.append(case("evict_just_installed_unset", ev, **evict_args("evict", swap(EVICT, "JUST_INSTALLED=1", "JUST_INSTALLED="))))
    c.append(case("evict_state_not_cleared", ev, **evict_args("evict", swap(EVICT, "ENV_STATE_RESULT=", "ENV_STATE_RESULT=stale"))))
    c.append(case("evict_damaged_left", ev, **evict_args("evict", swap(EVICT, "POST damaged=absent", "POST damaged=present"))))
    c.append(case("evict_nested_left", ev, **evict_args("evict", swap(EVICT, "POST nested=absent", "POST nested=present"))))
    c.append(case("evict_no_fresh_installation", ev, **evict_args("evict", swap(EVICT, "POST fresh=present", "POST fresh=absent"))))
    c.append(case("evict_installer_left", ev, **evict_args("evict", swap(EVICT, "POST installer=absent", "POST installer=present"))))
    c.append(case("evict_info_fails", ev, **evict_args("evict", swap(EVICT, "INFO_RC=0", "INFO_RC=1"))))
    # --- Get-EvictProblems: the control with the test flag set
    c.append(case("control_good", ct, **evict_args("control", CONTROL)))
    c.append(case("control_called_the_stubs", ct, **evict_args("control", after(CONTROL, LOG_EVICTED, "DOWNLOAD root=present"))))
    c.append(case("control_deleted_the_damaged_file", ct, **evict_args("control", swap(CONTROL, "POST damaged=present", "POST damaged=absent"))))
    c.append(case("control_info_ok", ct, **evict_args("control", swap(CONTROL, "INFO_RC=1", "INFO_RC=0"))))
    # --- Get-EvictProblems: a fresh install that leaves nothing
    c.append(case("nofresh_good", nf, **evict_args("nofresh", NOFRESH)))
    c.append(case("nofresh_wrong_exit", nf, **evict_args("nofresh", NOFRESH, ExitText="0\r\n")))
    c.append(case("nofresh_no_report", nf, **evict_args("nofresh", drop(NOFRESH, LEDGER_DIE_FRESH))))
    c.append(case("nofresh_code_3", nf, **evict_args("nofresh", swap(NOFRESH, LEDGER_DIE_FRESH, LEDGER_DIE_LOCKED))))
    c.append(case("nofresh_reported_twice", nf, **evict_args("nofresh", NOFRESH + [LEDGER_DIE_FRESH])))
    c.append(case("nofresh_reported_before_install",
                  nf, **evict_args("nofresh", after(drop(NOFRESH, LEDGER_DIE_FRESH), LOG_EVICTED, LEDGER_DIE_FRESH))))
    c.append(case("nofresh_went_on", nf, **evict_args("nofresh", NOFRESH + ["CONTINUED", "END"])))
    c.append(case("nofresh_no_install_tried",
                  nf, **evict_args("nofresh", ["START", "PRE damaged=present", "PRE nested=present", LOG_EVICTED, "DOWNLOAD root=absent", LEDGER_DIE_FRESH])))
    # --- Get-OfflineEvictProblems
    off = "Get-OfflineEvictProblems"
    c.append(case("offline_good", off, **offline_args()))
    c.append(case("offline_unfinished", off, **offline_args(Finished=False)))
    c.append(case("offline_wrong_exit", off, **offline_args(ExitText="2\r\n")))
    c.append(case("offline_exit_zero", off, **offline_args(ExitText="0\r\n")))
    c.append(case("offline_no_corrupt_line", off, **offline_args(SetupText=text_of(SETUP_LINES[1:]))))
    c.append(case("offline_no_evicted_line", off, **offline_args(SetupText=text_of(SETUP_LINES[:1] + SETUP_LINES[2:]))))
    c.append(case("offline_no_skip_line", off, **offline_args(SetupText=text_of(SETUP_LINES[:2] + SETUP_LINES[3:]))))
    c.append(case("offline_no_fail_line", off, **offline_args(SetupText=text_of(SETUP_LINES[:3]))))
    c.append(case("offline_skip_line_twice", off, **offline_args(SetupText=text_of(SETUP_LINES + [SETUP_LINES[2]]))))
    c.append(case("offline_wrong_order", off, **offline_args(SetupText=text_of([SETUP_LINES[0], SETUP_LINES[2], SETUP_LINES[1], SETUP_LINES[3]]))))
    c.append(case("offline_console_without_failure", off, **offline_args(ConsoleText="")))
    c.append(case("offline_locked_line", off, **offline_args(
        SetupText=text_of(SETUP_LINES + ["[2026-11-14 12:00:03.00] [ERROR] Could not delete corrupt conda dir; files may be locked."]))))
    c.append(case("offline_declined_line", off, **offline_args(
        SetupText=text_of(SETUP_LINES + ["[2026-11-14 12:00:03.00] [ERROR] Corrupt conda env; user declined rebuild."]))))
    c.append(case("offline_root_left", off, **offline_args(RootExists=True)))
    c.append(case("offline_stub_left", off, **offline_args(StubExists=True)))
    c.append(case("offline_installer_left", off, **offline_args(InstallerExists=True)))
    return c


# One problem each, and the words that problem must hold.
ONE_PROBLEM = {
    "evict_unfinished": "the driver did not finish within the time limit",
    "evict_no_start": "the driver did not write START exactly once",
    "evict_wrong_exit": "ended with exit code '3', expected 0",
    "evict_precondition_missing": "the precondition 'PRE damaged=present' is not in the ledger exactly once",
    "evict_no_log_line": "the log holds 0 line(s) saying the corrupt conda was evicted",
    "evict_log_line_twice": "the log holds 2 line(s) saying the corrupt conda was evicted",
    "evict_download_into_present_root": "the ledger does not hold 'DOWNLOAD root=absent' exactly once",
    "evict_install_without_installer": "the ledger does not hold 'INSTALL installer=present' exactly once",
    "evict_wrong_order": "the order is not eviction, download, install",
    "evict_died": "the block called :die 1 time(s), expected none",
    "evict_no_continue": "the run did not continue at the line after the block exactly once",
    "evict_continued_before_install": "the run continued before the install was tried",
    "evict_conda_bat_empty": "the run did not continue with CONDA_BAT set to " + CONDA,
    "evict_just_installed_unset": "HP_CONDA_JUST_INSTALLED is not 1 after the block",
    "evict_state_not_cleared": "HP_ENV_STATE_RESULT was not cleared",
    "evict_damaged_left": "the ledger does not hold 'POST damaged=absent' exactly once",
    "evict_nested_left": "the ledger does not hold 'POST nested=absent' exactly once",
    "evict_no_fresh_installation": "the ledger does not hold 'POST fresh=present' exactly once",
    "evict_installer_left": "the ledger does not hold 'POST installer=absent' exactly once",
    "evict_info_fails": "conda.bat info after the block did not answer 0",
    "control_called_the_stubs": "the download or install subroutine was called 1 time(s) although nothing was evicted",
    "control_deleted_the_damaged_file": "the ledger does not hold 'POST damaged=present' exactly once",
    "control_info_ok": "conda.bat info after the block did not answer 1",
    "nofresh_wrong_exit": "ended with exit code '0', expected 4",
    "nofresh_code_3": "the run did not stop once with the failure of the fresh install and the code 4",
    "nofresh_reported_before_install": "the failure was reported before the install was tried",
    "nofresh_went_on": "the run went on after the failure of the fresh install instead of stopping",
    "offline_unfinished": "the bootstrapper did not finish within the time limit",
    "offline_wrong_exit": "the run ended with exit code '2', expected 4",
    "offline_exit_zero": "the run ended with exit code '0', expected 4",
    "offline_no_corrupt_line": "the setup log holds 0 line(s) for the damaged installation is named, expected 1",
    "offline_no_evicted_line": "the setup log holds 0 line(s) for the eviction is logged, expected 1",
    "offline_no_skip_line": "the setup log holds 0 line(s) for the missing download is logged, expected 1",
    "offline_no_fail_line": "the setup log holds 0 line(s) for the failure of the fresh install is reported, expected 1",
    "offline_skip_line_twice": "the setup log holds 2 line(s) for the missing download is logged, expected 1",
    "offline_wrong_order": "the missing download is logged comes before the step that precedes it",
    "offline_console_without_failure": "the console does not show that the fresh install failed",
    "offline_locked_line": "the setup log says files may be locked",
    "offline_declined_line": "the setup log says the user declined",
    "offline_root_left": "the folder of the damaged installation is still there",
    "offline_stub_left": "the damaged conda.bat is still there",
    "offline_installer_left": "an installer file is left in the private temp folder",
}


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

    def test_the_line_index_is_the_first_whole_line_and_blind_to_case(self):
        self.assertEqual(self.r["index_found_case_blind"], [1])
        self.assertEqual(self.r["index_missing"], [-1])
        self.assertEqual(self.r["index_first_of_two"], [1])
        self.assertEqual(self.r["index_whole_line_only"], [1])

    def test_a_clean_run_of_each_scenario_has_no_problem(self):
        for name in ("evict_good", "control_good", "nofresh_good", "offline_good"):
            with self.subTest(case=name):
                self.assertEqual(self.r[name], [])

    def test_each_wrong_run_below_is_one_problem_with_its_own_sentence(self):
        for name, needle in sorted(ONE_PROBLEM.items()):
            with self.subTest(case=name):
                self.only(name, needle)

    def test_a_driver_that_did_not_finish_or_never_started_is_one_problem_and_nothing_else(self):
        self.assertEqual(len(self.r["evict_unfinished"]), 1)
        self.assertEqual(len(self.r["offline_unfinished"]), 1)
        self.assertEqual(len(self.r["evict_no_start"]), 1)

    def test_a_failed_fresh_install_that_was_never_reported_is_named_twice_for_the_two_things_it_lacks(self):
        found = self.r["nofresh_no_report"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(any("the run did not stop once with the failure of the fresh install and the code 4" in f for f in found), found)
        self.assertTrue(any("the block called :die 0 time(s), expected 1" in f for f in found), found)

    def test_a_failure_reported_twice_is_named_for_the_count_of_the_line_and_of_the_calls(self):
        found = self.r["nofresh_reported_twice"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(any("the run did not stop once with the failure" in f for f in found), found)
        self.assertTrue(any("the block called :die 2 time(s), expected 1" in f for f in found), found)

    def test_a_block_that_never_tried_the_install_lacks_both_of_its_ledger_lines(self):
        found = self.r["nofresh_no_install_tried"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(any("'INSTALL root=absent'" in f for f in found), found)
        self.assertTrue(any("'INSTALL installer=present'" in f for f in found), found)


# --- the rules on the real files -------------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_two_blocks_delete_behind_the_flag_install_in_order_and_stop_with_code_4_when_nothing_is_left(self):
        self.assertEqual(block_problems(self.batch, self.script), [])

    def test_the_main_flow_reaches_the_block_by_the_answer_y_and_the_log_texts_the_offline_judge_reads_are_live(self):
        self.assertEqual(flow_problems(self.batch, self.script), [])

    def test_the_script_has_its_rows_scenarios_driver_judges_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shalls_are_no_longer_listed_as_gaps(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        evict = cut_block(self.batch, EVICT_START, EVICT_END)
        select = cut_block(self.batch, SELECT_START, SELECT_END)
        self.assertGreater(len(live_bat(evict)), 20)
        self.assertEqual(len(live_bat(select)), 6)
        # 53 cases = 4 of the line index + 4 clean runs + 42 wrong runs with one problem each (ONE_PROBLEM) + 3 wrong runs
        # with two problems each (named in their own tests above); a judge case added or dropped changes the sum on purpose.
        self.assertEqual(len(judge_cases()), 4 + 4 + len(ONE_PROBLEM) + 3)
        self.assertEqual(len(judge_cases()), 53)
        self.assertEqual(len(ONE_PROBLEM), 42)
        self.assertEqual(sorted(KNOWN_EVICT), sorted(variables_in(evict)))
        self.assertEqual(sorted(KNOWN_SELECT), sorted(variables_in(select)))

    def test_every_judge_the_driver_is_asked_for_is_a_function_of_the_script(self):
        for name in JUDGES:
            self.assertRegex(norm(self.script), r"(?m)^function %s \{" % re.escape(name))


class BatchRulesCanFail(unittest.TestCase):
    """Each rule about run_setup.bat is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")

    def problems(self, batch):
        return block_problems(batch, self.script)

    def flow(self, batch):
        return flow_problems(batch, self.script)

    def test_a_label_that_is_missing_or_duplicated_is_reported(self):
        gone = mutate(self.batch, "\n:evict_and_rebuild\n", "\n:evict_and_rebuildx\n")
        self.assertTrue(any("appears 0 time(s)" in f for f in self.problems(gone)))
        twice = self.batch + "\n:conda_bulk_install\n"
        self.assertTrue(any("appears 2 time(s)" in f for f in self.problems(twice)))
        gone = mutate(self.batch, "\n:select_conda_bat\n", "\n:select_conda_batx\n")
        self.assertTrue(any("appears 0 time(s)" in f for f in self.problems(gone)))
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))

    def test_labels_in_the_wrong_order_are_reported_as_a_block_that_cannot_be_cut(self):
        bad = mutate(self.batch, "\n:conda_bulk_install\n", "\n:conda_bulk_installx\n") + "\n:conda_bulk_install\n"
        bad = mutate(bad, "\n:evict_and_rebuild\n", "\n:evict_and_rebuildx\n") + "\n:evict_and_rebuild\n"
        self.assertTrue(any("cannot be cut" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_deletion_that_is_missing_or_moved_out_of_its_guard_is_reported(self):
        bad = mutate(self.batch, '  rmdir /s /q "%MINICONDA_ROOT%" 2>nul\n', "")
        self.assertTrue(any("the deletion of the damaged folder" in f and "found 0" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "if not defined HP_TEST_SKIP_EVICT (\n  rmdir", "if 1==1 (\n  rmdir")
        found = self.problems(bad)
        self.assertTrue(any("the deletion must sit inside" in f for f in found), found)
        self.assertTrue(any("expected 2" in f for f in found), found)

    def test_a_download_or_install_outside_the_flags_guard_is_reported(self):
        bad = mutate(self.batch, "if not defined HP_TEST_SKIP_EVICT (\n  call :download_miniconda_exe", "if 1==1 (\n  call :download_miniconda_exe")
        found = self.problems(bad)
        self.assertTrue(any("the download must sit inside" in f for f in found), found)
        bad = mutate(self.batch, '  if exist "%TEMP%\\miniconda.exe" (\n    call :try_conda_install\n  )\n', "  call :try_conda_install\n")
        found = self.problems(bad)
        self.assertTrue(any("the install must sit inside" in f for f in found), found)

    def test_a_missing_or_reordered_log_line_or_clearing_is_reported(self):
        bad = mutate(self.batch, 'call :log "[INFO] Self-healing: corrupt conda evicted from %MINICONDA_ROOT%."\n', "")
        self.assertTrue(any("the log line of the eviction" in f and "found 0" in f for f in self.problems(bad)), self.problems(bad))
        moved = mutate(self.batch, 'call :log "[INFO] Self-healing: corrupt conda evicted from %MINICONDA_ROOT%."\n', "")
        moved = mutate(moved, 'set "HP_CONDA_JUST_INSTALLED=1"\ngoto :after_conda_bat_validation\n',
                       'call :log "[INFO] Self-healing: corrupt conda evicted from %MINICONDA_ROOT%."\nset "HP_CONDA_JUST_INSTALLED=1"\ngoto :after_conda_bat_validation\n')
        found = self.problems(moved)
        self.assertTrue(any("the log line of the eviction" in f and "must come before" in f for f in found), found)
        bad = mutate(self.batch, 'set "CONDA_BAT="\nset "HP_CONDA_JUST_INSTALLED="\nset "HP_ENV_STATE_RESULT="\n',
                     'set "HP_CONDA_JUST_INSTALLED="\nset "HP_ENV_STATE_RESULT="\n')
        self.assertTrue(any("the clearing of CONDA_BAT" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'set "CONDA_BAT="\nset "HP_CONDA_JUST_INSTALLED="\nset "HP_ENV_STATE_RESULT="\n',
                     'set "CONDA_BAT="\nset "HP_CONDA_JUST_INSTALLED="\n')
        self.assertTrue(any("the clearing of HP_ENV_STATE_RESULT" in f and "found 0" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_failure_report_that_stops_ending_with_exit_code_4_is_reported(self):
        bad = mutate(self.batch, DIE_FRESH + "\n  exit /b 4\n", DIE_FRESH + "\n  exit /b 0\n")
        self.assertTrue(any("exit /b 4" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, DIE_FRESH + "\n  exit /b 4\n", DIE_FRESH + "\n")
        self.assertTrue(any("exit /b 4" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, DIE_LOCKED + "\n    exit /b 3\n", DIE_LOCKED + "\n")
        self.assertTrue(any("exit /b 3" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_failure_report_with_another_code_or_text_is_reported(self):
        bad = mutate(self.batch, DIE_FRESH, 'call :die "[ERROR] Fresh Miniconda install failed after self-healing eviction." 5')
        self.assertTrue(any("the report of a failed fresh install" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, "[ERROR] Fresh Miniconda install failed after self-healing eviction.", "[ERROR] The fresh Miniconda could not be installed.")
        self.assertTrue(any("the report of a failed fresh install" in f for f in self.problems(bad)), self.problems(bad))
        self.assertTrue(any("Fresh Miniconda install failed after self-healing eviction." in f for f in self.flow(bad)), self.flow(bad))

    def test_a_failure_report_outside_its_condition_is_reported(self):
        bad = mutate(self.batch, "if not defined CONDA_BAT (\n  call :die \"[ERROR] Fresh", "if 1==1 (\n  call :die \"[ERROR] Fresh")
        self.assertTrue(any("the report of a failed fresh install must sit inside" in f for f in self.problems(bad)), self.problems(bad))

    def test_the_selection_of_the_fresh_conda_bat_is_pinned_line_by_line(self):
        bad = mutate(self.batch, 'if not defined CONDA_BAT if exist "%CONDA_ALT%" set "CONDA_BAT=%CONDA_ALT%"\n', "")
        self.assertTrue(any("the lines of :select_conda_bat are" in f for f in self.problems(bad)), self.problems(bad))
        bad = mutate(self.batch, 'if defined CONDA_BAT if not exist "%CONDA_BAT%" set "CONDA_BAT="\n', "")
        self.assertTrue(any("the lines of :select_conda_bat are" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_block_that_calls_something_the_driver_does_not_define_is_reported(self):
        bad = mutate(self.batch, 'set "HP_CONDA_JUST_INSTALLED=1"\ngoto :after_conda_bat_validation\n',
                     'call :cleanup_conda\nset "HP_CONDA_JUST_INSTALLED=1"\ngoto :after_conda_bat_validation\n')
        self.assertTrue(any(":cleanup_conda" in f and "the driver defines" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_block_that_reads_a_new_variable_is_reported(self):
        bad = mutate(self.batch, 'set "HP_CONDA_JUST_INSTALLED=1"\ngoto :after_conda_bat_validation\n',
                     'if defined HP_EXTRA_FLAG set "CONDA_BAT="\nset "HP_CONDA_JUST_INSTALLED=1"\ngoto :after_conda_bat_validation\n')
        self.assertTrue(any("HP_EXTRA_FLAG" in f and "does not define or clear" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_goto_out_of_the_block_is_reported(self):
        bad = mutate(self.batch, "goto :after_conda_bat_validation\n:conda_bulk_install", "goto :after_env_mode_selection\n:conda_bulk_install")
        self.assertTrue(any("the blocks go to" in f for f in self.problems(bad)), self.problems(bad))

    def test_a_new_label_inside_the_block_is_reported(self):
        bad = mutate(self.batch, 'call :select_conda_bat\nif not defined CONDA_BAT (', 'call :select_conda_bat\n:evict_extra\nif not defined CONDA_BAT (')
        self.assertTrue(any("the eviction block's labels are" in f for f in self.problems(bad)), self.problems(bad))

    def test_an_answer_y_that_no_longer_reaches_the_block_is_reported(self):
        bad = mutate(self.batch, 'if /I "%HP_HEAL_CHOICE%"=="Y" goto :evict_and_rebuild\n', 'if /I "%HP_HEAL_CHOICE%"=="Y" goto :corrupt_ci_exit\n')
        self.assertTrue(any("no longer reaches :evict_and_rebuild" in f for f in self.flow(bad)), self.flow(bad))
        bad = mutate(self.batch, 'if /I "%HP_HEAL_CHOICE%"=="Y" goto :evict_and_rebuild\n',
                     'if /I "%HP_HEAL_CHOICE%"=="Y" goto :evict_and_rebuild\nif /I "%HP_HEAL_CHOICE%"=="A" goto :evict_and_rebuild\n')
        self.assertTrue(any("more than one line goes to :evict_and_rebuild" in f for f in self.flow(bad)), self.flow(bad))

    def test_a_test_answer_tested_after_the_ci_marker_is_reported(self):
        bad = mutate(self.batch, "if defined HP_TEST_HEAL_ANSWER goto :heal_prompt\nif defined HP_CI_LANE goto :corrupt_ci_exit\n",
                     "if defined HP_CI_LANE goto :corrupt_ci_exit\nif defined HP_TEST_HEAL_ANSWER goto :heal_prompt\n")
        self.assertTrue(any("before the CI marker" in f for f in self.flow(bad)), self.flow(bad))

    def test_a_health_check_that_is_no_longer_the_pair_is_reported(self):
        bad = mutate(self.batch, '  call "%CONDA_BAT%" info >nul 2>&1\n  if errorlevel 1 goto :conda_binary_corrupt\n',
                     '  call "%CONDA_BAT%" info >nul 2>&1\n  if errorlevel 2 goto :conda_binary_corrupt\n')
        self.assertTrue(any("the health check no longer is the pair" in f for f in self.flow(bad)), self.flow(bad))

    def test_a_reworded_log_line_is_reported_for_each_of_the_four_texts(self):
        for text, new in (("Corrupt conda binary detected at: ", "Damaged conda binary found at: "),
                          ("Self-healing: corrupt conda evicted from ", "Self-healing: damaged conda removed from "),
                          ("Offline mode: skipping Miniconda download.", "Offline mode: no Miniconda download."),
                          ("Fresh Miniconda install failed after self-healing eviction.", "Fresh Miniconda install did not work.")):
            with self.subTest(text=text):
                bad = mutate(self.batch, text, new)
                self.assertTrue(any(text in f for f in self.flow(bad)), self.flow(bad))


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the script, the workflow, the registry and the shall list is shown to fail on a mutated copy."""

    def setUp(self):
        self.script = norm(SCRIPT.read_text(encoding="utf-8"))
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def problems(self, text):
        return script_problems(text)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.script, "id = 'self.corrupt.conda.evict.install'; req = 'REQ-020.5'; pass = $pass", "id = $rowId; req = 'REQ-020.5'; pass = $pass")
        self.assertTrue(any("literal" in f for f in self.problems(bad)))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.script, "id = 'self.corrupt.conda.evict.installfail'; req = 'REQ-020.9'; pass = $pass", "id = 'self.corrupt.conda.evict.installfail'; req = 'REQ-020'; pass = $pass")
        self.assertTrue(any("req tag" in f for f in self.problems(bad)))

    def test_a_scenario_that_changes_stops_being_the_control_or_stops_failing_the_install_is_caught(self):
        bad = mutate(self.script, "Name = 'control'; Kind = 'control'; Skip = $true; Install = 'creates'", "Name = 'control'; Kind = 'control'; Skip = $false; Install = 'creates'")
        self.assertTrue(any("scenario list" in f for f in self.problems(bad)))
        bad = mutate(self.script, "Name = 'nofresh'; Kind = 'nofresh'; Skip = $false; Install = 'nothing'", "Name = 'nofresh'; Kind = 'nofresh'; Skip = $false; Install = 'creates'")
        self.assertTrue(any("scenario list" in f for f in self.problems(bad)))
        bad = mutate(self.script, "Name = 'evict'; Kind = 'evict'; Skip = $false; Install = 'creates'", "Name = 'evict'; Kind = 'evict'; Skip = $true; Install = 'creates'")
        self.assertTrue(any("scenario list" in f for f in self.problems(bad)))

    def test_a_cut_that_moved_or_a_driver_line_that_vanished_is_caught(self):
        bad = mutate(self.script, "-StartLabel ':evict_and_rebuild' -EndLabel ':conda_bulk_install'", "-StartLabel ':evict_and_rebuild' -EndLabel ':log'")
        self.assertTrue(any("cuts" in f and ":conda_bulk_install" in f for f in self.problems(bad)))
        bad = mutate(self.script, "'goto :evict_and_rebuild'", "'call :evict_and_rebuild'")
        self.assertTrue(any("goto :evict_and_rebuild" in f for f in self.problems(bad)))
        bad = mutate(self.script, "'>>\"%LEDGER%\" echo INFO_RC=%ERRORLEVEL%',\n", "")
        self.assertTrue(any("INFO_RC" in f for f in self.problems(bad)))

    def test_a_driver_that_no_longer_damages_the_installation_is_caught(self):
        bad = mutate(self.script, "-Lines @('@exit /b 1')", "-Lines @('@exit /b 0')")
        self.assertTrue(any("damaged installation" in f for f in self.problems(bad)))

    def test_open_standard_input_and_a_missing_kill_are_caught(self):
        bad = mutate(self.script, "call ~driver.bat > ~driver_console.txt 2>&1 < nul", "call ~driver.bat > ~driver_console.txt 2>&1")
        self.assertTrue(any("standard input" in f for f in self.problems(bad)))
        bad = mutate(self.script, "call run_setup.bat > ~driver_console.txt 2>&1 < nul", "call run_setup.bat > ~driver_console.txt 2>&1")
        self.assertTrue(any("real bootstrap no longer runs with standard input closed" in f for f in self.problems(bad)))
        bad = mutate(self.script, "& taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null", "")
        self.assertTrue(any("taskkill" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-LimitMs 480000", "-LimitMs 4800000")
        self.assertTrue(any("-LimitMs 480000" in f for f in self.problems(bad)))

    def test_a_real_bootstrap_that_loses_a_setting_or_clears_the_runners_variables_too_late_is_caught(self):
        bad = mutate(self.script, "        'set \"HP_OFFLINE_MODE=1\"',\n", "")
        self.assertTrue(any("HP_OFFLINE_MODE=1" in f for f in self.problems(bad)))
        bad = mutate(self.script, "'set \"HP_TEST_HEAL_ANSWER=Y\"'", "'set \"HP_TEST_HEAL_ANSWER=N\"'")
        self.assertTrue(any("HP_TEST_HEAL_ANSWER=Y" in f for f in self.problems(bad)))
        bad = mutate(self.script, "    foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }\n", "")
        self.assertTrue(any("clears every HP_ and PVW_ variable" in f for f in self.problems(bad)))
        late = mutate(self.script, "    foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }\n", "")
        late = mutate(late, "        'call run_setup.bat > ~driver_console.txt 2>&1 < nul',\n", "        'call run_setup.bat > ~driver_console.txt 2>&1 < nul',\n")
        late = mutate(late, "    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines $launchLines.ToArray()\n",
                      "    foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }\n    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines $launchLines.ToArray()\n")
        self.assertTrue(any("cleared after" in f for f in self.problems(late)), self.problems(late))
        bad = mutate(self.script, "('set \"PUBLIC=' + (Join-Path $dir 'pub') + '\"')", "('set \"PUBLIC=C:\\Users\\Public\"')")
        self.assertTrue(any("private folder" in f for f in self.problems(bad)))

    def test_a_verdict_that_stops_handing_the_judge_what_it_needs_is_caught(self):
        bad = mutate(self.script, "-CondaMainPath $conda -RootPath $root)", "-CondaMainPath '' -RootPath $root)")
        self.assertTrue(any("-CondaMainPath $conda" in f for f in self.problems(bad)))
        bad = mutate(self.script, "-InstallerExists ([bool]$installerExists))", "-InstallerExists $false)")
        self.assertTrue(any("-InstallerExists" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$installProblems = @($evict.Problems) + @($control.Problems)", "$installProblems = @($evict.Problems)")
        self.assertTrue(any("install row is no longer judged by both" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$failProblems = @($nofresh.Problems) + @($offline.Problems)", "$failProblems = @($nofresh.Problems)")
        self.assertTrue(any("installfail row is no longer judged by both" in f for f in self.problems(bad)))
        bad = mutate(self.script, "$pass = [bool](@($failProblems).Count -eq 0)", "$pass = $true")
        self.assertTrue(any("row of failProblems" in f for f in self.problems(bad)))

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
        bad = mutate(self.script, "function Get-OfflineEvictProblems {", "function Get-OfflineEvictProblemsX {")
        self.assertTrue(any("Get-OfflineEvictProblems is missing" in f for f in self.problems(bad)))

    def test_a_script_that_stops_looking_for_a_log_text_is_caught(self):
        bad = mutate(self.script, "'Offline mode: skipping Miniconda download.'", "'Offline mode: skipping download.'")
        self.assertTrue(any("Offline mode: skipping Miniconda download." in f for f in flow_problems(self.batch, bad)))

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
        self.assertEqual(workflow_problems("name: x\n"), ["no step runs tests\\" + SCRIPT_NAME])
        bad = self.workflow.replace("tests/~selftest_condaevict/offline/~setup.log", "")
        self.assertTrue(any("~setup.log" in f for f in workflow_problems(bad)))

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        self.assertTrue(registry_problems(text.replace("self.corrupt.conda.evict.installfail", "self.corrupt.conda.evict.installfailx")))
        self.assertTrue(registry_problems("```\nself.corrupt.conda.evict.install\n```\nprose: self.corrupt.conda.evict.installfail\n"))

    def test_a_shall_that_is_still_listed_as_a_gap_is_caught(self):
        self.assertTrue(shall_list_problems('    "REQ-020.5": "gap: x",\n'))
        self.assertTrue(shall_list_problems('    "REQ-020.9": "gap: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-020.50": "gap: x",\n'), [])


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

    def silenced(self, comparison, name, needle):
        """Replacing `if (<comparison>) {` by `if ($false) {` must remove the sentence `needle` from the answer for case `name`."""
        self.assertTrue(any(needle in f for f in self.base[name]), (name, needle, self.base[name]))
        got = self.run_mutated("if (" + comparison + ") {", "if ($false) {", [name])
        self.assertFalse(any(needle in f for f in got[name]), (name, needle, got[name]))

    def test_a_judge_that_forgets_a_driver_that_never_finished_is_caught(self):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        old = 'if (-not $Finished) { [void]$out.Add("${tag}: the driver did not finish within the time limit")'
        self.assertEqual(text.count(old), 1)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, old.replace("if (-not $Finished) {", "if ($false) {")), encoding="utf-8")
            got = run_cases(script, JUDGES, [cs for cs in judge_cases() if cs["name"] == "evict_unfinished"], d)
        self.assertNotEqual(got["evict_unfinished"], self.base["evict_unfinished"])

    def test_a_judge_that_forgets_a_bootstrapper_that_never_finished_is_caught(self):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        old = 'if (-not $Finished) { [void]$out.Add("${tag}: the bootstrapper did not finish within the time limit")'
        self.assertEqual(text.count(old), 1)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, old.replace("if (-not $Finished) {", "if ($false) {")), encoding="utf-8")
            got = run_cases(script, JUDGES, [cs for cs in judge_cases() if cs["name"] == "offline_unfinished"], d)
        self.assertNotEqual(got["offline_unfinished"], self.base["offline_unfinished"])

    def test_the_comparisons_of_the_eviction_judge_each_matter(self):
        for comparison, name, needle in (
            ("(& $count 'START') -ne 1", "evict_no_start", "did not write START exactly once"),
            ("$exit -ne $wantExit", "evict_wrong_exit", "ended with exit code"),
            ("(& $count $pre) -ne 1", "evict_precondition_missing", "the precondition"),
            ("$nEvicted -ne 1", "evict_no_log_line", "saying the corrupt conda was evicted"),
            ("$nCalls -ne 0", "control_called_the_stubs", "although nothing was evicted"),
            ("(& $count $call) -ne 1", "evict_download_into_present_root", "'DOWNLOAD root=absent'"),
            ("-not ($iEvicted -lt $iDownload -and $iDownload -lt $iInstall)", "evict_wrong_order", "the order is not eviction, download, install"),
            ("$nDie -ne 0", "evict_died", "expected none"),
            ("(& $count 'CONTINUED') -ne 1 -or (& $count 'END') -ne 1", "evict_no_continue", "did not continue at the line after the block"),
            ("$iInstall3 -ge 0 -and $iContinued -lt $iInstall3", "evict_continued_before_install", "continued before the install"),
            ("(& $count ('CONDA_BAT=' + $CondaMainPath)) -ne 1", "evict_conda_bat_empty", "did not continue with CONDA_BAT set to"),
            ("(& $count 'JUST_INSTALLED=1') -ne 1", "evict_just_installed_unset", "HP_CONDA_JUST_INSTALLED is not 1"),
            ("(& $count 'ENV_STATE_RESULT=') -ne 1", "evict_state_not_cleared", "HP_ENV_STATE_RESULT was not cleared"),
            ("(& $count $post) -ne 1", "evict_damaged_left", "'POST damaged=absent'"),
            ("(& $count ('INFO_RC=' + $wantInfo)) -ne 1", "evict_info_fails", "did not answer 0"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_the_comparisons_of_the_failed_install_judge_each_matter(self):
        for comparison, name, needle in (
            ("(& $count $dieLine) -ne 1", "nofresh_code_3", "did not stop once with the failure of the fresh install and the code 4"),
            ("$nDie -ne 1", "nofresh_no_report", "the block called :die 0 time(s), expected 1"),
            ("$iDie -ge 0 -and $iInstall2 -ge 0 -and $iDie -lt $iInstall2", "nofresh_reported_before_install", "reported before the install was tried"),
            ("(& $count 'CONTINUED') -ne 0 -or (& $count 'END') -ne 0", "nofresh_went_on", "went on after the failure"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_the_comparisons_of_the_offline_judge_each_matter(self):
        for comparison, name, needle in (
            ("$exit -ne '4'", "offline_wrong_exit", "expected 4"),
            ("$n -ne 1", "offline_no_evicted_line", "the setup log holds 0 line(s)"),
            ("$ConsoleText.IndexOf('Fresh Miniconda install failed after self-healing eviction.', $ordinal) -lt 0", "offline_console_without_failure", "the console does not show"),
            ("$SetupText.IndexOf('Could not delete corrupt conda dir', $ordinal) -ge 0", "offline_locked_line", "files may be locked"),
            ("$SetupText.IndexOf('user declined rebuild', $ordinal) -ge 0", "offline_declined_line", "the user declined"),
            ("$RootExists", "offline_root_left", "the folder of the damaged installation is still there"),
            ("$StubExists", "offline_stub_left", "the damaged conda.bat is still there"),
            ("$InstallerExists", "offline_installer_left", "an installer file is left"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_a_judge_that_forgets_the_order_of_the_setup_log_is_caught(self):
        self.assertTrue(any("comes before the step that precedes it" in f for f in self.base["offline_wrong_order"]))
        got = self.run_mutated("} elseif ($first -lt $last) {", "} elseif ($false) {", ["offline_wrong_order"])
        self.assertEqual(got["offline_wrong_order"], [])

    def test_a_line_index_that_matches_a_prefix_is_caught(self):
        got = self.run_mutated("if ($Lines[$i] -ieq $Text) { return $i }", "if ($Lines[$i] -ilike ($Text + '*')) { return $i }", ["index_whole_line_only"])
        self.assertEqual(got["index_whole_line_only"], [0])


if __name__ == "__main__":
    unittest.main()
