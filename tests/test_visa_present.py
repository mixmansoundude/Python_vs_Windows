"""Item 122 (README REQ-008.2 and REQ-008.15): an NI-VISA driver that is already installed is neither downloaded nor installed again,
and the Python pyvisa package is installed whichever way the subfolder question was answered.

REQ-008.2 says the bootstrapper does not download or install the NI-VISA driver when it is already installed; REQ-008.15 says it
installs the Python pyvisa package whether the answer to the question of REQ-008.7 is yes or no. Until this item the shall-level
trace test listed both as gaps: no hosted runner has the driver (a real install attempt there ends with installer exit code -125202),
the registry value cannot be written without a permanent change to HKLM, so the branch for a present driver never ran, and no row
listed the packages of the environment after either answer.

tests/selfapps_visa_present.ps1 (rows self.nivisa.present.noinstall, .subfolder and .control; contract-uv lane, gating) cuts the block
from :visa_wanted to :visa_done out of run_setup.bat and runs it three times under cmd.exe against a driver of stubs (the registry
look, the two downloads, the installer and the subfolder question are recording stubs; :log writes one ledger line), with the driver
there from the start, the same with the import only in a subfolder, and a control that finds the driver absent and installs it.
tests/selfapps_pyvisa_subfolder.ps1 got a fifth row, self.nivisa.pyvisa.installed (real and conda-full lanes, gating), which reads
the pip freeze that its declined and its accepted real bootstrap wrote.

What really happens is shown on Windows by those scripts. These rules read run_setup.bat, the two scripts, batch-check.yml,
docs/agent-ndjson.md and tests/test_req_shall_trace.py as text, build the driver the script writes from the real block and check its
shape, and run the scripts' own judging functions through a real pwsh on synthetic runs (a run that passes, and one run for each
way to be wrong), so a reworded log line, a block that reaches something the driver does not define, a registry look that moved, a
scenario that stops being the one the shall names, a judge that stops judging or a step that stops gating fails here with a sentence,
before a Windows run is needed. Synthetic cases prove each rule can fail. The shared helpers are in tests/judge_support.py.
"""
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import (PWSH, after, case, cut_block, drop, drop_last, enclosing, lines_of, live_bat, live_hash, mutate,  # noqa: E402
                           norm, registry_ids, run_cases, step_block, swap, text_of, variables_in)

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
PRESENT = REPO / "tests" / "selfapps_visa_present.ps1"
PYVISA = REPO / "tests" / "selfapps_pyvisa_subfolder.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"
PRESENT_NAME = "selfapps_visa_present.ps1"
PYVISA_NAME = "selfapps_pyvisa_subfolder.ps1"

PRESENT_ROWS = ("self.nivisa.present.noinstall", "self.nivisa.present.subfolder", "self.nivisa.present.control")
PRESENT_REQ = "REQ-008.2"
PYVISA_ROW = "self.nivisa.pyvisa.installed"
PYVISA_REQ = "REQ-008.15"
OLDER_PYVISA_ROWS = ("self.nivisa.subfolder.declined", "self.nivisa.subfolder.accepted", "self.nivisa.topfolder.noprompt",
                     "self.nivisa.subfolder.timeout")
GAP_SHALLS = (PRESENT_REQ, PYVISA_REQ)

VISA_START = ":visa_wanted"
VISA_END = ":visa_done"
GATE_LABEL = ":visa_subfolder_gate"
INSTALLER_LABEL = ":run_installer_timeout"
BLOCK_LABELS = [":visa_wanted", ":visa_post_check", ":visa_cleanup"]

REG_LINE = 'reg query "HKLM\\SOFTWARE\\National Instruments\\NI-VISA" /v "CurrentVersion" >nul 2>&1'
SKIP_TEST = 'if "%HP_SKIP_NIVISA%"=="1" ('
GATE_LINE = 'if "%NEED_VISA%"=="2" call :visa_subfolder_gate'
NEED_TEST = 'if not "%NEED_VISA%"=="1" goto visa_done'
INSTALLER_SET = 'set "NIVISA_INSTALLER=~ni-visa-runtime.exe"'
CLEANUP_LINES = [":visa_cleanup", 'if exist "%NIVISA_INSTALLER%" del "%NIVISA_INSTALLER%" >nul 2>&1']
MAIN_GOTOS = ('if "%NEED_VISA%"=="1" goto visa_wanted', 'if "%NEED_VISA%"=="2" goto visa_wanted')
PRESENT_BRANCH = ["if not errorlevel 1 (", 'call :log "[VISA] present"', "goto visa_done", ")"]
SUCCESS_BRANCH = ["if not errorlevel 1 (", 'call :log "[VISA] install_success"', "goto visa_cleanup", ")"]

# The two registry lines of the block with the line after them, as the batch file has them (used as unique anchors).
FIRST_LOOK = REG_LINE + '\nif not errorlevel 1 (\n  call :log "[VISA] present"\n  goto visa_done\n)\n'
SECOND_LOOK = ":visa_post_check\n" + REG_LINE + '\nif not errorlevel 1 (\n  call :log "[VISA] install_success"\n  goto visa_cleanup\n)\n'

# Every variable the block reads or sets. The script's driver sets or clears each of them but ERRORLEVEL, so none comes from the runner.
KNOWN_BLOCK = {"ERRORLEVEL", "HP_NIVISA_WAIT_SECS", "HP_SKIP_NIVISA", "HP_VISA_DLSIZE", "HP_VISA_DLVIA", "HP_VISA_INSTALLER_RC",
               "HP_VISA_MAXRETRY", "HP_VISA_PE", "HP_VISA_PINGN", "HP_VISA_RETRY", "LOG", "NEED_VISA", "NIVISA_INSTALLER"}
HEAD_CLEARS = ("HP_SKIP_NIVISA", "HP_NIVISA_WAIT_SECS", "NIVISA_INSTALLER", "HP_VISA_DLVIA", "HP_VISA_DLSIZE", "HP_VISA_PE",
               "HP_VISA_INSTALLER_RC", "HP_VISA_PINGN", "HP_VISA_MAXRETRY", "HP_VISA_RETRY")
# The labels the block calls (the driver defines all three) and the ones it goes to.
CALLS_OF_BLOCK = [":log", ":run_installer_timeout", ":visa_subfolder_gate"]
GOTOS_OF_BLOCK = ["visa_cleanup", "visa_done", "visa_post_check"]

# The four log texts the judges read; each must stay in exactly one live call :log line of the batch file.
LOG_TEXTS = ("[VISA] present", "[VISA] download method: ", "[VISA] installer exit code: ", "[VISA] install_success")
# The [VISA] log lines the block writes today. The present judge looks for the ones that say a driver was downloaded, installed or
# skipped (SAID), so a new wording has to be added here on purpose, after a look at that regex.
BLOCK_LOG_PREFIXES = ('[VISA] skipped (disabled)"', '[VISA] present"', '[VISA] install_failed (download)"', "[VISA] download method: ",
                      "[VISA] installer file size: ", "[VISA] installer PE check: ", "[VISA] installer exit code: ",
                      '[VISA] install_success"', "[VISA] post-check waiting; ", "[VISA] install_failed (post_check_timeout) ")
SAID = r"^LOG \[VISA\] (download method|installer|install_|skipped)"
JUDGED_STRINGS = ("'LOG [VISA] present'", "'LOG [VISA] download method: curl'", "'LOG [VISA] installer exit code: 0'",
                  "'LOG [VISA] install_success'", "'LOG [[]VISA] install_failed*'", "'" + SAID + "'")
FREEZE_CAPTURED = 'if "%HP_DEP_INST_RC%"=="0" call :log "[INFO] DEP_INSTALLED_CAPTURED=1"'
FREEZE_UV = '"%HP_UV_EXE%" pip freeze --python "%HP_PY%" > "~dependency_installed.txt" 2>nul'
FREEZE_PIP = '"%HP_PY%" -m pip freeze > "~dependency_installed.txt" 2>nul'

SCENARIOS = {
    "noinstall": {"Name": "noinstall", "Kind": "present", "NeedVisa": "1", "RegMode": "present"},
    "subfolder": {"Name": "subfolder", "Kind": "present", "NeedVisa": "2", "RegMode": "present"},
    "control": {"Name": "control", "Kind": "install", "NeedVisa": "1", "RegMode": "absent_then_present"},
}
SCENARIO_LINES = (
    "Name = 'noinstall'; Kind = 'present'; NeedVisa = '1'; RegMode = 'present'",
    "Name = 'subfolder'; Kind = 'present'; NeedVisa = '2'; RegMode = 'present'",
    "Name = 'control'; Kind = 'install'; NeedVisa = '1'; RegMode = 'absent_then_present'",
)

# What follows the block in the driver the script writes: the exit label with its three ledger lines, :log, and the four stubs.
EXPECTED_TAIL = [
    ":visa_done",
    '>>"%LEDGER%" echo FINISHED NEED_VISA=%NEED_VISA%',
    'if exist "~ni-visa-runtime.exe" >>"%LEDGER%" echo INSTALLER_FILE=present',
    'if not exist "~ni-visa-runtime.exe" >>"%LEDGER%" echo INSTALLER_FILE=absent',
    '>>"%LEDGER%" echo END',
    "exit /b 0",
    ":log",
    "setlocal",
    'set "MSG=%~1"',
    '>>"%LEDGER%" echo LOG %MSG%',
    "endlocal",
    "exit /b 0",
    ":stub_reg_query",
    '>>"%LEDGER%" echo REG',
    'if "%REG_MODE%"=="present" exit /b 0',
    'if exist "%FLAG_REG%" exit /b 0',
    '>"%FLAG_REG%" echo seen',
    "exit /b 1",
    ":stub_curl",
    '>>"%LEDGER%" echo CURL %*',
    '>"%NIVISA_INSTALLER%" echo MZ',
    "exit /b 0",
    ":stub_ps_download",
    '>>"%LEDGER%" echo PSDL',
    "exit /b 1",
    ":run_installer_timeout",
    '>>"%LEDGER%" echo INSTALL %*',
    "exit /b 0",
    ":visa_subfolder_gate",
    '>>"%LEDGER%" echo GATE',
    'set "NEED_VISA=1"',
    "exit /b 0",
]

STEP_IF_CONTRACT = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~visa_present_evidence.txt",
    "tests/~selftest_visapresent/*/~driver*",
    "tests/~selftest_pyvisa_sub_declined/~dependency_installed.txt",
    "tests/~selftest_pyvisa_sub_accepted/~dependency_installed.txt",
)
JUDGES_PRESENT = ["Get-StubCalls", "Get-PresentProblems", "Convert-VisaBlock", "New-PresentDriver"]
JUDGES_PYVISA = ["Get-PyvisaLine", "Get-PyvisaFreezeProblems"]


# --- the batch file: what the script assumes about the block ---------------------------------------------------------------------

def block_problems(batch, script_text):
    """README REQ-008.2 in the batch file: the block looks at the registry before anything else is done about the driver, a present
    driver ends the block before the question, the download and the installer, the lines the script replaces are where it expects
    them, and the block reaches only what the driver defines."""
    found = []
    stripped = [ln.strip() for ln in lines_of(batch)]
    for label in (VISA_START, VISA_END, GATE_LABEL, INSTALLER_LABEL):
        n = sum(1 for ln in stripped if ln == label)
        if n != 1:
            found.append("the label %s appears %d time(s); expected exactly once" % (label, n))
    if found:
        return found
    cut = cut_block(batch, VISA_START, VISA_END)
    if cut is None:
        return ["the block from %s to %s cannot be cut" % (VISA_START, VISA_END)]
    raw = live_bat(cut)
    body = [ln.strip() for ln in raw]

    labels = [ln for ln in body if ln.startswith(":")]
    if labels != BLOCK_LABELS:
        found.append("the block's labels are %r, the script's driver was written for %r" % (labels, BLOCK_LABELS))
    calls = sorted(set(re.findall(r"(?i)\bcall\s+(:[A-Za-z_][A-Za-z0-9_]*)", "\n".join(body))))
    if calls != CALLS_OF_BLOCK:
        found.append("the block calls %r; the driver defines %r" % (calls, CALLS_OF_BLOCK))
    gotos = sorted(set(m.lstrip(":") for m in re.findall(r"(?i)\bgoto\s+(:?[A-Za-z_][A-Za-z0-9_]*)", "\n".join(body))))
    if gotos != GOTOS_OF_BLOCK:
        found.append("the block goes to %r; the driver was written for %r" % (gotos, GOTOS_OF_BLOCK))
    unknown = sorted(variables_in(cut) - KNOWN_BLOCK)
    if unknown:
        found.append("the block reads or sets %s, which the driver of tests/%s does not define or clear" % (", ".join(unknown), PRESENT_NAME))
    driver_sets = set(re.findall(r"'set \"([A-Za-z_][A-Za-z0-9_]*)=", norm(script_text)))
    missing = sorted(name for name in KNOWN_BLOCK - {"ERRORLEVEL"} if name not in driver_sets)
    if missing:
        found.append("the driver of tests/%s does not set or clear %s" % (PRESENT_NAME, ", ".join(missing)))

    def index_of(text, what):
        hits = [i for i, ln in enumerate(body) if ln == text]
        if len(hits) != 1:
            found.append("%s: expected exactly one live line %r in the block, found %d" % (what, text, len(hits)))
            return None
        return hits[0]

    # the two looks at the registry: the check before the install and the poll after it
    regs = [i for i, ln in enumerate(body) if re.match(r"(?i)reg\s+query\s", ln)]
    first = second = None
    if len(regs) != 2:
        found.append("the block holds %d live line(s) that start with reg query; the driver replaces exactly 2 (the look before the "
                     "install and the poll after it)" % len(regs))
    else:
        first, second = regs
        for i in regs:
            if body[i] != REG_LINE:
                found.append("the registry look %r is not the one the row pins, %r" % (body[i], REG_LINE))
        if body[first + 1:first + 5] != PRESENT_BRANCH:
            found.append("the first look at the registry is no longer followed by the branch that logs [VISA] present and goes to visa_done")
        if body[second - 1:second] != [":visa_post_check"] or body[second + 1:second + 5] != SUCCESS_BRANCH:
            found.append("the second look at the registry is no longer the poll after the installer (label :visa_post_check, then the "
                         "branch that logs [VISA] install_success and goes to visa_cleanup)")

    skip = index_of(SKIP_TEST, "the disabled check")
    gate = index_of(GATE_LINE, "the subfolder question")
    need = index_of(NEED_TEST, "the test that NEED_VISA is 1")
    name = index_of(INSTALLER_SET, "the name of the installer file")
    index_of('set "HP_VISA_DLVIA=curl"', "the mark of the curl download")
    index_of('set "HP_VISA_DLVIA=powershell"', "the mark of the PowerShell download")
    index_of('call :log "[VISA] download method: %HP_VISA_DLVIA%"', "the log line of the download method")
    if gate is not None and need is not None and need != gate + 1:
        found.append("the test that NEED_VISA is 1 must follow the subfolder question directly")

    # exactly one curl line, at column 0, because the script's driver replaces only such a line
    curl_at = [i for i, ln in enumerate(body) if re.match(r"(?i)curl\s", ln)]
    curl_col0 = [ln for ln in raw if re.match(r"(?i)curl\s", ln)]
    curl = None
    if len(curl_at) != 1 or len(curl_col0) != 1:
        found.append("the block must hold exactly one curl line and it must start at column 0, because the driver replaces only such a "
                     "line (found %d, %d of them at column 0)" % (len(curl_at), len(curl_col0)))
    else:
        curl = curl_at[0]
        if '-o "%NIVISA_INSTALLER%"' not in body[curl]:
            found.append("the curl line no longer writes to -o \"%NIVISA_INSTALLER%\"")
        if body[curl + 1:curl + 2] != ["if errorlevel 1 ("]:
            found.append("the curl line is no longer followed directly by if errorlevel 1 (, the fallback to the PowerShell download")

    # the PowerShell lines: the download (one, inside the fallback) and the probe of the first two bytes
    ps = [i for i, ln in enumerate(body) if re.match(r"(?i)powershell\s", ln)]
    web = [i for i in ps if re.search(r"Invoke-WebRequest", body[i])]
    if len(ps) != 2 or len(web) != 1:
        found.append("the block holds %d powershell line(s), %d of them with Invoke-WebRequest; the driver was written for 2 and 1 (the "
                     "download and the probe of the first two bytes)" % (len(ps), len(web)))
    elif enclosing(body, web[0]) != ["if errorlevel 1 ("]:
        found.append("the PowerShell download must sit inside if errorlevel 1 (, found it inside %r" % (enclosing(body, web[0]),))

    installer = [i for i, ln in enumerate(body) if ln.startswith("call :run_installer_timeout ")]
    call = None
    if len(installer) != 1:
        found.append("the block holds %d call(s) of :run_installer_timeout, expected 1" % len(installer))
    else:
        call = installer[0]
        if body[call + 1:call + 3] != ['set "HP_VISA_INSTALLER_RC=%ERRORLEVEL%"', 'call :log "[VISA] installer exit code: %HP_VISA_INSTALLER_RC%"']:
            found.append("the installer call is no longer followed directly by the capture of its exit code and the log line of it")

    order = [("the disabled check", skip), ("the first look at the registry", first), ("the subfolder question", gate),
             ("the test that NEED_VISA is 1", need), ("the name of the installer file", name), ("the curl download", curl),
             ("the installer call", call), ("the second look at the registry", second)]
    known = [(label, at) for label, at in order if at is not None]
    for (n1, a1), (n2, a2) in zip(known, known[1:]):
        if a1 > a2:
            found.append("%s must come before %s, or the rows' reasoning about the order of the block does not hold" % (n1, n2))

    if body[-2:] != CLEANUP_LINES:
        found.append("the block no longer ends with the label :visa_cleanup and the line that deletes the installer file")
    for ln in body:
        m = re.match(r'call :log "(\[VISA\] .*)', ln)
        if m and not any(m.group(1).startswith(prefix) for prefix in BLOCK_LOG_PREFIXES):
            found.append("the block logs an unknown [VISA] line %r; the judge of the present rows reads such lines with a regex that "
                         "was written for the known ones" % m.group(1))
    return found


def flow_problems(batch, script_text):
    """The lines of the main flow that reach the block, the log texts the judges read, and the pip freeze the pyvisa row reads."""
    found = []
    live = [ln.strip() for ln in live_bat(lines_of(batch))]

    def count(text):
        return sum(1 for ln in live if ln == text)

    for text in MAIN_GOTOS:
        if count(text) != 1:
            found.append("the main flow no longer reaches the block by exactly one line %r" % text)
    if sum(1 for ln in live if re.search(r"(?i)\bgoto\s+:?visa_wanted\b", ln)) != 2:
        found.append("more or fewer than two lines go to :visa_wanted, so the block is reached by a path the script does not run")
    if count(GATE_LINE) != 1:
        found.append("the subfolder question is no longer asked by exactly one line %r" % GATE_LINE)
    for text in LOG_TEXTS:
        hits = [ln for ln in live if text in ln and ln.startswith("call :log ")]
        if len(hits) != 1:
            found.append("the text %r must be in exactly one live call :log line of the batch file, found %d" % (text, len(hits)))
    failed = [ln for ln in live if "[VISA] install_failed" in ln and ln.startswith("call :log ")]
    if len(failed) != 2:
        found.append("the batch file holds %d live [VISA] install_failed log line(s), expected 2 (the download and the poll); the control "
                     "judge counts them" % len(failed))
    wanted = live.index(VISA_START) if live.count(VISA_START) == 1 else None
    for text, what in ((FREEZE_CAPTURED, "the log line DEP_INSTALLED_CAPTURED=1"), (FREEZE_UV, "the uv pip freeze into ~dependency_installed.txt"),
                       (FREEZE_PIP, "the pip freeze into ~dependency_installed.txt")):
        n = count(text)
        if n != 1:
            found.append("%s: expected exactly one live line %r, found %d" % (what, text, n))
        elif wanted is not None and live.index(text) > wanted:
            found.append("%s must come before the NI-VISA block, so the list of packages exists whatever the answer to the question was" % what)
    flat = norm(script_text)
    for text in JUDGED_STRINGS:
        if text not in flat:
            found.append("the script no longer holds the judged text %s" % text)
    return found


# --- the scripts -----------------------------------------------------------------------------------------------------------------

def present_script_problems(text):
    t = norm(text)
    live = live_hash(t)
    flat = "\n".join(live)
    found = []
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if sorted(ids) != sorted(list(PRESENT_ROWS) * 2):
        found.append("each row id must be a literal at exactly two Write-NdjsonRow call sites (the shared one and its own), found %r" % ids)
    pairs = re.findall(r"\bid = '(self\.nivisa\.present\.[a-z]+)'; req = '([^']*)'", t)
    if sorted(p[0] for p in pairs) != sorted(list(PRESENT_ROWS) * 2):
        found.append("every row id must be followed by its literal req tag, found %r" % pairs)
    for rid, req in pairs:
        if req != PRESENT_REQ:
            found.append("the row %s must carry the literal req tag %r, found %r" % (rid, PRESENT_REQ, req))
    if len(re.findall(r"\breq\s*=\s*'", t)) != len(re.findall(r"\breq\s*=\s*'", flat)):
        found.append("a comment holds the shape req = '...', which the requirement-trace tests would count as a tag")
    for line in SCENARIO_LINES:
        if line not in flat:
            found.append("the scenario list no longer holds: %s" % line)
    if "-StartLabel ':visa_wanted' -EndLabel ':visa_done'" not in flat:
        found.append("the script no longer cuts the block from :visa_wanted to :visa_done out of run_setup.bat")
    guard = "if (($converted.Counts['reg'] -ne 2) -or ($converted.Counts['curl'] -ne 1) -or ($converted.Counts['psdl'] -ne 1)) {"
    if guard not in flat:
        found.append("the script no longer refuses to run a driver whose block does not hold 2 reg query lines, 1 curl line and 1 PowerShell download")
    if "call ~driver.bat > ~driver_console.txt 2>&1 < nul" not in flat:
        found.append("the driver no longer runs with standard input closed (< nul) and its console in ~driver_console.txt")
    # the number ends at a digit boundary: -LimitMs 1800000 is a different limit and must not pass as 180000
    for pattern, shown in ((r"-LimitMs 180000(?!\d)", "-LimitMs 180000"), (r"taskkill\.exe /F /T /PID \$p\.Id", "taskkill.exe /F /T /PID $p.Id")):
        if not re.search(pattern, flat):
            found.append("a run that outlives its limit is no longer stopped: %s is missing" % shown)
    call = "$found = @(Get-PresentProblems"
    if call not in flat:
        found.append("the scenarios are no longer judged by Get-PresentProblems")
    else:
        args = flat.split(call, 1)[1].split("\n", 1)[0]
        for need in ("-Scenario $Scenario.Name", "-Kind $Scenario.Kind", "-Finished ([bool]$launch.Finished)", "-LedgerText $ledger",
                     "-NeedVisa $Scenario.NeedVisa"):
            if need not in args:
                found.append("the verdict no longer hands %s to Get-PresentProblems" % need)
    for var in ("noinstall", "subfolder", "control"):
        if "$pass = [bool](@($%s.Problems).Count -eq 0)" % var not in flat:
            found.append("the row of %s is no longer judged by its list of problems" % var)
    if flat.count("pass = $pass") != 3 or flat.count("if (-not $pass) { $allPass = $false }") != 3:
        found.append("the three rows no longer each write pass = $pass after the same red-row bookkeeping")
    for need in ("~visa_present_evidence.txt", "~selftest_visapresent", "'call :stub_reg_query'", "'call :stub_ps_download'",
                 "-replace '^curl\\s+', 'call :stub_curl '"):
        if need not in flat:
            found.append("the script no longer holds %s" % need)
    for name in JUDGES_PRESENT:
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the judging function %s is missing" % name)
    if "OSVersion.Platform -ne [System.PlatformID]::Win32NT" not in flat or re.search(r"\$IsWindows\b", flat):
        found.append("the Windows check must use OSVersion.Platform and not $IsWindows")
    if "skip = $true" not in flat or "reason = 'non-windows-host'" not in flat:
        found.append("the rows no longer skip off Windows with skip = $true")
    if "if (-not $allPass) { exit 1 }" not in flat:
        found.append("the script no longer exits 1 for a red row")
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0")
    if any(ord(ch) > 127 for ch in text):
        found.append("the script holds a character that is not ASCII")
    return found


def pyvisa_script_problems(text):
    t = norm(text)
    live = live_hash(t)
    flat = "\n".join(live)
    found = []
    ids = re.findall(r"\bid\s*=\s*['\"]([A-Za-z0-9][A-Za-z0-9_.-]*)['\"]", t)
    if ids.count(PYVISA_ROW) != 2:
        found.append("the row id %s must be a literal at exactly two Write-NdjsonRow call sites (the skip and its own), found %d" % (PYVISA_ROW, ids.count(PYVISA_ROW)))
    for rid in OLDER_PYVISA_ROWS:
        if rid not in ids:
            found.append("the older row %s is no longer written by the script" % rid)
    reqs = re.findall(r"id\s*=\s*'self\.nivisa\.pyvisa\.installed'[;\s]*req\s*=\s*'([^']*)'", t)
    if reqs != [PYVISA_REQ, PYVISA_REQ]:
        found.append("the row %s must be followed by the literal req tag %r at both sites, found %r" % (PYVISA_ROW, PYVISA_REQ, reqs))
    if len(re.findall(r"\breq\s*=\s*'", t)) != len(re.findall(r"\breq\s*=\s*'", flat)):
        found.append("a comment holds the shape req = '...', which the requirement-trace tests would count as a tag")
    for need in ("$subFiles = @{ 'main.py' = $mainPlain; 'archive\\old_tool.py' = $archived; 'requirements.txt' = 'pyvisa' }",
                 "$dFreeze = Read-Text (Join-Path $d.Work '~dependency_installed.txt')",
                 "$aFreeze = Read-Text (Join-Path $a.Work '~dependency_installed.txt')",
                 "Get-PyvisaFreezeProblems -Label 'declined' -AnswerShown ([bool]$dSkipped) -SetupText $d.Setup -FreezeText $dFreeze",
                 "Get-PyvisaFreezeProblems -Label 'accepted' -AnswerShown ([bool]($aAcceptedLine -and $aNotDeclined)) -SetupText $a.Setup -FreezeText $aFreeze",
                 "$pyPass = [bool](@($pyProblems).Count -eq 0)",
                 "if (-not ($dPass -and $aPass -and $tPass -and $oPass -and $pyPass)) { exit 1 }"):
        if need not in flat:
            found.append("the script no longer holds: %s" % need)
    if not re.search(r"pass\s*=\s*\$pyPass", flat):
        found.append("the row of %s no longer writes pass = $pyPass" % PYVISA_ROW)
    for name in JUDGES_PYVISA + ["Read-Text"]:
        if not re.search(r"(?m)^function %s \{" % re.escape(name), t):
            found.append("the function %s is missing" % name)
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0")
    if any(ord(ch) > 127 for ch in text):
        found.append("the script holds a character that is not ASCII")
    return found


# --- the workflow, the registry and the shall list ------------------------------------------------------------------------------

def workflow_problems(text):
    found = []
    block = step_block(text, PRESENT_NAME)
    if block is None:
        found.append("no step runs tests\\%s" % PRESENT_NAME)
    else:
        if STEP_IF_CONTRACT not in block:
            found.append("the step of %s is not limited to the contract-uv lane with !cancelled()" % PRESENT_NAME)
        if "shell: pwsh" not in block:
            found.append("the step of %s does not use shell: pwsh" % PRESENT_NAME)
        if "continue-on-error" in block:
            found.append("the step of %s has continue-on-error, so it cannot hold a pull request" % PRESENT_NAME)
    block = step_block(text, PYVISA_NAME)
    if block is None:
        found.append("no step runs tests\\%s" % PYVISA_NAME)
    else:
        for need in ("!cancelled()", "matrix.mode == 'real'", "matrix.mode == 'conda-full'"):
            if need not in block:
                found.append("the step of %s no longer holds %s, so it is not the gating step of the real and conda-full lanes" % (PYVISA_NAME, need))
        if "shell: pwsh" not in block:
            found.append("the step of %s does not use shell: pwsh" % PYVISA_NAME)
        if "continue-on-error" in block:
            found.append("the step of %s has continue-on-error, so it cannot hold a pull request" % PYVISA_NAME)
    flat = norm(text)
    for pattern in UPLOADS:
        if pattern not in flat:
            found.append("the artifact upload does not list %s" % pattern)
    return found


def registry_problems(text):
    have = registry_ids(text)
    return ["%s is not in docs/agent-ndjson.md" % row for row in PRESENT_ROWS + (PYVISA_ROW,) if row not in have]


def shall_list_problems(text):
    """The shalls the rows trace are no longer listed as gaps (the shall-level ratchet only warns about a stale entry)."""
    return ["%s is still listed in UNTRACED_SHALLS although a row is tagged with it" % shall
            for shall in GAP_SHALLS if re.search(r'^\s*"%s":' % re.escape(shall), text, re.M)]


def driver_problems(driver, converted, scenario):
    """The shape of the driver the script writes (a list of lines) for one scenario: the clears and the two scenario values in its
    head, the converted block line for line, the tail the judge reads, every label once and every target defined, and no live line
    that would reach the real registry or the network."""
    gotos = [i for i, ln in enumerate(driver) if ln.strip() == "goto :visa_wanted"]
    if len(gotos) != 1:
        return ["the driver holds %d line(s) goto :visa_wanted, expected exactly one" % len(gotos)]
    found = []
    g = gotos[0]
    head = driver[:g + 1]
    if head[:2] != ["@echo off", "setlocal"]:
        found.append("the driver does not start with @echo off and setlocal")
    if g < 1 or driver[g - 1] != '>"%LEDGER%" echo START':
        found.append("the driver does not write START to the ledger directly before it enters the block")
    for name, tail in (("LEDGER", "~driver_ledger.txt"), ("LOG", "~driver.log"), ("FLAG_REG", "~reg_seen.flag")):
        hits = [ln for ln in head if re.match(r'^set "%s=.*[\\/]%s"$' % (name, re.escape(tail)), ln)]
        if len(hits) != 1:
            found.append("the driver's head holds %d line(s) that set %s to a path ending in %s, expected 1" % (len(hits), name, tail))
    for name, value in (("REG_MODE", scenario["RegMode"]), ("NEED_VISA", scenario["NeedVisa"])):
        want = 'set "%s=%s"' % (name, value)
        if head.count(want) != 1:
            found.append("the driver's head does not hold %s exactly once" % want)
    for name in HEAD_CLEARS:
        want = 'set "%s="' % name
        if head.count(want) != 1:
            found.append("the driver's head does not clear %s with %s exactly once, so the runner's value could decide" % (name, want))
    if driver[g + 1:g + 1 + len(converted)] != converted:
        found.append("the lines after goto :visa_wanted are not the converted block of run_setup.bat, line for line")
    if driver[g + 1 + len(converted):] != EXPECTED_TAIL:
        found.append("the driver's last lines (the exit label, :log and the stubs) are not the ones the judge reads")
    labels = [ln.strip() for ln in driver if re.match(r"^:[A-Za-z_]", ln.strip())]
    for label in sorted(set(labels)):
        if labels.count(label) != 1:
            found.append("the label %s is defined %d times in the driver" % (label, labels.count(label)))
    text = "\n".join(driver)
    targets = set(re.findall(r"(?i)\bcall\s+(:[A-Za-z_][A-Za-z0-9_]*)", text))
    targets |= set(":" + m.lstrip(":") for m in re.findall(r"(?i)\bgoto\s+(:?[A-Za-z_][A-Za-z0-9_]*)", text))
    for target in sorted(targets):
        if target not in labels:
            found.append("the driver calls or goes to %s, which it does not define" % target)
    for ln in driver:
        s = ln.strip()
        if re.match(r"(?i)(reg\s+query|curl)\s", s) or re.search(r"(?i)Invoke-WebRequest", s):
            found.append("a live line of the driver would reach the real registry or the network: %r" % s)
    return found


# --- the judging functions, run through a real pwsh -------------------------------------------------------------------------------

CURL_ARGS = ('-L --silent --fail --retry 3 --retry-delay 5 --max-time 120 -o "~ni-visa-runtime.exe" '
             '"https://download.ni.com/support/nipkg/products/ni-v/ni-visa/21.5/online/ni-visa_21.5_online.exe"')
INSTALL_ARGS = '"~ni-visa-runtime.exe" "--quiet --accept-eulas --prevent-reboot --prevent-activation" 5400000 "NI-VISA"'
LOG_PRESENT = "LOG [VISA] present"
LOG_METHOD = "LOG [VISA] download method: curl"
LOG_RC = "LOG [VISA] installer exit code: 0"
LOG_SUCCESS = "LOG [VISA] install_success"
NOINSTALL = ["START", "REG", LOG_PRESENT, "FINISHED NEED_VISA=1", "INSTALLER_FILE=absent", "END"]
SUBFOLDER = ["START", "REG", LOG_PRESENT, "FINISHED NEED_VISA=2", "INSTALLER_FILE=absent", "END"]
CONTROL = ["START", "REG", "CURL " + CURL_ARGS, LOG_METHOD, "LOG [VISA] installer file size: 4 bytes", "LOG [VISA] installer PE check: PE_OK",
           "INSTALL " + INSTALL_ARGS, LOG_RC, "REG", LOG_SUCCESS, "FINISHED NEED_VISA=1", "INSTALLER_FILE=absent", "END"]
LEDGERS = {"noinstall": NOINSTALL, "subfolder": SUBFOLDER, "control": CONTROL}

REAL_REG = 'reg query "HKLM\\SOFTWARE\\National Instruments\\NI-VISA" /v "CurrentVersion" >nul 2>&1'
CONVERT_SAMPLE = [
    "rem reg query is only text in a comment",
    REAL_REG,
    "if not errorlevel 1 (",
    '  call :log "[VISA] present"',
    ")",
    'curl -L --silent --fail -o "%NIVISA_INSTALLER%" "https://example.invalid/x.exe" 2>> "%LOG%"',
    "if errorlevel 1 (",
    '  powershell -NoProfile -Command "try { Invoke-WebRequest -Uri u -OutFile f } catch { exit 1 }" 2>> "%LOG%"',
    ")",
    'powershell -NoProfile -Command "try { $fs=[System.IO.File]::OpenRead(f) } catch { 1 }" > "~visa_pe.txt" 2>nul',
]
CONVERT_SAMPLE_OUT = [
    "rem reg query is only text in a comment",
    "call :stub_reg_query",
    "if not errorlevel 1 (",
    '  call :log "[VISA] present"',
    ")",
    'call :stub_curl -L --silent --fail -o "%NIVISA_INSTALLER%" "https://example.invalid/x.exe" 2>> "%LOG%"',
    "if errorlevel 1 (",
    "call :stub_ps_download",
    ")",
    'powershell -NoProfile -Command "try { $fs=[System.IO.File]::OpenRead(f) } catch { 1 }" > "~visa_pe.txt" 2>nul',
]


def present_args(name, lines, **over):
    sc = SCENARIOS[name]
    args = dict(Scenario=name, Kind=sc["Kind"], Finished=True, LedgerText=text_of(lines), NeedVisa=sc["NeedVisa"])
    args.update(over)
    return args


def present_cases():
    c = []
    gp, sc, cv = "Get-PresentProblems", "Get-StubCalls", "Convert-VisaBlock"
    # --- Get-StubCalls
    c.append(case("calls_control", sc, LedgerText=text_of(CONTROL)))
    c.append(case("calls_empty", sc, LedgerText=""))
    c.append(case("calls_log_lines_are_not_calls", sc, LedgerText=text_of(["LOG REG", "LOG CURL x", "LOG INSTALL y", "LOG PSDL", "LOG GATE"])))
    c.append(case("calls_trimmed", sc, LedgerText="  REG  \r\n\tGATE\t\r\n"))
    c.append(case("calls_prefix_words_are_not_calls", sc, LedgerText=text_of(
        ["CURLY", "CURLING x", "INSTALLED", "INSTALLER_FILE=absent", "REGISTRY", "REG_MODE=present", "GATEWAY", "PSDLX"])))
    c.append(case("calls_bare_curl_and_install", sc, LedgerText=text_of(["CURL", "INSTALL"])))
    c.append(case("calls_with_arguments", sc, LedgerText=text_of(["CURL -L x", 'INSTALL "a" b'])))
    c.append(case("calls_exact_tokens_only", sc, LedgerText=text_of(["REG x", "PSDL x", "GATE x"])))
    c.append(case("calls_every_token", sc, LedgerText=text_of(["REG", "PSDL", "GATE", "CURL x", "INSTALL y"])))
    # --- Get-PresentProblems: the driver is there from the start
    c.append(case("present_good", gp, **present_args("noinstall", NOINSTALL)))
    c.append(case("subfolder_good", gp, **present_args("subfolder", SUBFOLDER)))
    c.append(case("unfinished", gp, **present_args("noinstall", NOINSTALL, Finished=False)))
    c.append(case("no_start", gp, **present_args("noinstall", drop(NOINSTALL, "START"))))
    c.append(case("no_end", gp, **present_args("noinstall", drop(NOINSTALL, "END"))))
    c.append(case("need_visa_changed", gp, **present_args("noinstall", swap(NOINSTALL, "FINISHED NEED_VISA=1", "FINISHED NEED_VISA=2"))))
    c.append(case("gate_asked", gp, **present_args("noinstall", after(NOINSTALL, "START", "GATE"))))
    c.append(case("installer_left", gp, **present_args("noinstall", swap(NOINSTALL, "INSTALLER_FILE=absent", "INSTALLER_FILE=present"))))
    c.append(case("no_registry_look", gp, **present_args("noinstall", drop(NOINSTALL, "REG"))))
    c.append(case("two_looks", gp, **present_args("noinstall", after(NOINSTALL, "REG", "REG"))))
    c.append(case("no_present_line", gp, **present_args("noinstall", drop(NOINSTALL, LOG_PRESENT))))
    c.append(case("present_twice", gp, **present_args("noinstall", after(NOINSTALL, LOG_PRESENT, LOG_PRESENT))))
    c.append(case("curl", gp, **present_args("noinstall", after(NOINSTALL, "REG", "CURL " + CURL_ARGS))))
    c.append(case("psdl", gp, **present_args("noinstall", after(NOINSTALL, "REG", "PSDL"))))
    c.append(case("install", gp, **present_args("noinstall", after(NOINSTALL, "REG", "INSTALL " + INSTALL_ARGS))))
    c.append(case("said_download", gp, **present_args("noinstall", after(NOINSTALL, LOG_PRESENT, LOG_METHOD))))
    c.append(case("said_skipped", gp, **present_args("noinstall", after(NOINSTALL, LOG_PRESENT, "LOG [VISA] skipped (disabled)"))))
    c.append(case("said_install_success", gp, **present_args("noinstall", after(NOINSTALL, LOG_PRESENT, LOG_SUCCESS))))
    c.append(case("said_installer_exit", gp, **present_args("noinstall", after(NOINSTALL, LOG_PRESENT, LOG_RC))))
    c.append(case("subfolder_gate_asked", gp, **present_args(
        "subfolder", swap(after(SUBFOLDER, "START", "GATE"), "FINISHED NEED_VISA=2", "FINISHED NEED_VISA=1"))))
    # --- Get-PresentProblems: the control, where the driver is absent at the first look
    c.append(case("control_good", gp, **present_args("control", CONTROL)))
    c.append(case("control_wrong_calls", gp, **present_args("control", drop(CONTROL, "CURL " + CURL_ARGS))))
    c.append(case("control_second_look_missing", gp, **present_args("control", drop_last(CONTROL, "REG"))))
    c.append(case("control_present_logged", gp, **present_args("control", after(CONTROL, "REG", LOG_PRESENT))))
    c.append(case("control_no_method_line", gp, **present_args("control", drop(CONTROL, LOG_METHOD))))
    c.append(case("control_method_powershell", gp, **present_args("control", swap(CONTROL, LOG_METHOD, "LOG [VISA] download method: powershell"))))
    c.append(case("control_no_exit_code_line", gp, **present_args("control", drop(CONTROL, LOG_RC))))
    c.append(case("control_exit_code_1", gp, **present_args("control", swap(CONTROL, LOG_RC, "LOG [VISA] installer exit code: 1"))))
    c.append(case("control_no_success", gp, **present_args("control", drop(CONTROL, LOG_SUCCESS))))
    c.append(case("control_success_twice", gp, **present_args("control", after(CONTROL, LOG_SUCCESS, LOG_SUCCESS))))
    c.append(case("control_install_failed", gp, **present_args(
        "control", after(CONTROL, LOG_SUCCESS, "LOG [VISA] install_failed (post_check_timeout) installer_rc=0"))))
    c.append(case("control_success_before_second_look", gp, **present_args(
        "control", after(drop(CONTROL, LOG_SUCCESS), LOG_RC, LOG_SUCCESS))))
    c.append(case("control_installer_left", gp, **present_args("control", swap(CONTROL, "INSTALLER_FILE=absent", "INSTALLER_FILE=present"))))
    c.append(case("control_need_visa_changed", gp, **present_args("control", swap(CONTROL, "FINISHED NEED_VISA=1", "FINISHED NEED_VISA=2"))))
    c.append(case("control_gate_asked", gp, **present_args("control", after(CONTROL, "START", "GATE"))))
    # --- Convert-VisaBlock
    c.append(case("convert_sample", cv, Block=CONVERT_SAMPLE))
    c.append(case("convert_indented_reg", cv, Block=['  reg query "K" >nul 2>&1']))
    c.append(case("convert_indented_curl_unchanged", cv, Block=["  curl -L x"]))
    c.append(case("convert_case_blind", cv, Block=['REG QUERY "K" >nul', "CURL -L x", 'Powershell -Command "invoke-webrequest u"']))
    c.append(case("convert_pe_probe_unchanged", cv, Block=[CONVERT_SAMPLE[-1]]))
    c.append(case("convert_empty", cv, Block=[]))
    c.append(case("convert_counts_two_of_each", cv, Block=['reg query "K"', "reg query K", "curl -L a", "curl -L b",
                                                          'powershell -Command "Invoke-WebRequest a"', 'powershell -Command "Invoke-WebRequest b"']))
    return c


# One problem each, and the words that problem must hold.
ONE_PROBLEM = {
    "unfinished": "the driver did not finish within the time limit",
    "no_start": "the driver did not write START exactly once",
    "no_end": "the driver did not reach its end, so the block ended the run early",
    "need_visa_changed": "the ledger does not hold 'FINISHED NEED_VISA=1' exactly once",
    "gate_asked": "the block asked the question of the subfolder gate 1 time(s), expected none",
    "installer_left": "the installer file ~ni-visa-runtime.exe is left after the block, expected it gone",
    "no_registry_look": "the block looked at the registry 0 time(s), expected once",
    "two_looks": "the block looked at the registry 2 time(s), expected once",
    "no_present_line": "the log holds 0 '[VISA] present' line(s), expected 1",
    "present_twice": "the log holds 2 '[VISA] present' line(s), expected 1",
    "curl": "downloaded the installer with curl 1 time(s) although the driver is installed",
    "psdl": "downloaded the installer with PowerShell 1 time(s) although the driver is installed",
    "install": "started the installer 1 time(s) although the driver is installed",
    "said_download": "the log says the driver was downloaded, installed or skipped although it was present: " + LOG_METHOD,
    "said_skipped": "the log says the driver was downloaded, installed or skipped although it was present: LOG [VISA] skipped (disabled)",
    "said_install_success": "the log says the driver was downloaded, installed or skipped although it was present: " + LOG_SUCCESS,
    "said_installer_exit": "the log says the driver was downloaded, installed or skipped although it was present: " + LOG_RC,
    "control_wrong_calls": "the block's calls were 'REG INSTALL REG', expected 'REG CURL INSTALL REG'",
    "control_second_look_missing": "the block's calls were 'REG CURL INSTALL', expected 'REG CURL INSTALL REG'",
    "control_present_logged": "the log holds 1 '[VISA] present' line(s) although the registry answered absent at the first look",
    "control_no_method_line": "the log holds 0 'download method: curl' line(s), expected 1",
    "control_method_powershell": "the log holds 0 'download method: curl' line(s), expected 1",
    "control_no_exit_code_line": "the log holds 0 'installer exit code: 0' line(s), expected 1",
    "control_exit_code_1": "the log holds 0 'installer exit code: 0' line(s), expected 1",
    "control_no_success": "the log holds 0 'install_success' line(s), expected 1",
    "control_success_twice": "the log holds 2 'install_success' line(s), expected 1",
    "control_install_failed": "the log holds 1 'install_failed' line(s), expected none",
    "control_success_before_second_look": "the success was logged before the second look at the registry",
    "control_installer_left": "the installer file ~ni-visa-runtime.exe is left after the block, expected it gone",
    "control_need_visa_changed": "the ledger does not hold 'FINISHED NEED_VISA=1' exactly once",
}

# The cases of the present script's judges: 9 of Get-StubCalls, 3 clean runs, the one-problem runs above, 2 runs with two problems
# each (named in their own tests) and 7 of Convert-VisaBlock. A case added or dropped changes the sum on purpose.
PRESENT_CASE_COUNT = 9 + 3 + len(ONE_PROBLEM) + 2 + 7


@unittest.skipUnless(PWSH, "pwsh not available")
class PresentJudgesOnSyntheticRuns(unittest.TestCase):
    """The script's judging functions on runs built here: a clean run passes and each kind of wrong run is reported with its own
    sentence. The functions run alone and in strict mode, so they cannot read the script's variables."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(PRESENT, JUDGES_PRESENT, present_cases(), d)

    def only(self, name, needle):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        self.assertIn(needle, found[0], (name, found))

    def test_the_stub_calls_are_the_exact_tokens_in_ledger_order(self):
        self.assertEqual(self.r["calls_control"], ["REG", "CURL", "INSTALL", "REG"])
        self.assertEqual(self.r["calls_empty"], [])
        self.assertEqual(self.r["calls_trimmed"], ["REG", "GATE"])
        self.assertEqual(self.r["calls_bare_curl_and_install"], ["CURL", "INSTALL"])
        self.assertEqual(self.r["calls_with_arguments"], ["CURL", "INSTALL"])
        self.assertEqual(self.r["calls_every_token"], ["REG", "PSDL", "GATE", "CURL", "INSTALL"])

    def test_a_log_line_or_a_word_that_only_starts_like_a_token_is_not_a_call(self):
        for name in ("calls_log_lines_are_not_calls", "calls_prefix_words_are_not_calls", "calls_exact_tokens_only"):
            with self.subTest(case=name):
                self.assertEqual(self.r[name], [])

    def test_a_clean_run_of_each_scenario_has_no_problem(self):
        for name in ("present_good", "subfolder_good", "control_good"):
            with self.subTest(case=name):
                self.assertEqual(self.r[name], [])

    def test_each_wrong_run_below_is_one_problem_with_its_own_sentence(self):
        for name, needle in sorted(ONE_PROBLEM.items()):
            with self.subTest(case=name):
                self.only(name, needle)

    def test_a_driver_that_did_not_finish_or_never_started_or_never_ended_is_one_problem_and_nothing_else(self):
        for name in ("unfinished", "no_start", "no_end"):
            with self.subTest(case=name):
                self.assertEqual(len(self.r[name]), 1, self.r[name])

    def test_a_subfolder_question_asked_before_the_look_is_named_for_the_question_and_for_the_changed_need_visa(self):
        found = self.r["subfolder_gate_asked"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(any("the ledger does not hold 'FINISHED NEED_VISA=2' exactly once" in f for f in found), found)
        self.assertTrue(any("asked the question of the subfolder gate 1 time(s), expected none" in f for f in found), found)

    def test_a_question_asked_in_the_control_is_named_for_the_question_and_for_the_call_order(self):
        found = self.r["control_gate_asked"]
        self.assertEqual(len(found), 2, found)
        self.assertTrue(any("the block's calls were 'GATE REG CURL INSTALL REG', expected 'REG CURL INSTALL REG'" in f for f in found), found)
        self.assertTrue(any("asked the question of the subfolder gate 1 time(s), expected none" in f for f in found), found)

    def test_every_problem_names_its_scenario(self):
        self.assertTrue(self.r["gate_asked"][0].startswith("NI-VISA present noinstall: "), self.r["gate_asked"])
        self.assertTrue(self.r["subfolder_gate_asked"][0].startswith("NI-VISA present subfolder: "), self.r["subfolder_gate_asked"])
        self.assertTrue(self.r["control_wrong_calls"][0].startswith("NI-VISA present control: "), self.r["control_wrong_calls"])

    def test_the_conversion_replaces_the_registry_looks_the_curl_line_and_the_web_request_and_nothing_else(self):
        got = self.r["convert_sample"][0]
        self.assertEqual(got["Lines"], CONVERT_SAMPLE_OUT)
        self.assertEqual(got["Counts"], {"reg": 1, "curl": 1, "psdl": 1})

    def test_the_conversion_counts_every_replaced_line(self):
        self.assertEqual(self.r["convert_counts_two_of_each"][0]["Counts"], {"reg": 2, "curl": 2, "psdl": 2})
        self.assertEqual(self.r["convert_counts_two_of_each"][0]["Lines"],
                         ["call :stub_reg_query", "call :stub_reg_query", "call :stub_curl -L a", "call :stub_curl -L b",
                          "call :stub_ps_download", "call :stub_ps_download"])
        self.assertEqual(self.r["convert_empty"][0]["Lines"], [])
        self.assertEqual(self.r["convert_empty"][0]["Counts"], {"reg": 0, "curl": 0, "psdl": 0})

    def test_an_indented_registry_look_is_replaced_and_an_indented_curl_line_is_left_alone(self):
        self.assertEqual(self.r["convert_indented_reg"][0]["Lines"], ["call :stub_reg_query"])
        self.assertEqual(self.r["convert_indented_curl_unchanged"][0]["Lines"], ["  curl -L x"])
        self.assertEqual(self.r["convert_indented_curl_unchanged"][0]["Counts"], {"reg": 0, "curl": 0, "psdl": 0})

    def test_the_conversion_is_blind_to_case_like_cmd_and_leaves_the_probe_of_the_first_two_bytes_alone(self):
        self.assertEqual(self.r["convert_case_blind"][0]["Lines"], ["call :stub_reg_query", "call :stub_curl -L x", "call :stub_ps_download"])
        self.assertEqual(self.r["convert_case_blind"][0]["Counts"], {"reg": 1, "curl": 1, "psdl": 1})
        self.assertEqual(self.r["convert_pe_probe_unchanged"][0]["Lines"], [CONVERT_SAMPLE[-1]])
        self.assertEqual(self.r["convert_pe_probe_unchanged"][0]["Counts"], {"reg": 0, "curl": 0, "psdl": 0})


# --- the pyvisa row's two judging functions -----------------------------------------------------------------------------------

CAPTURED = "[2026-11-14 12:00:00.00] [INFO] DEP_INSTALLED_CAPTURED=1\r\n"
LONG_LINE = "pyvisa @ " + "a" * 200


def pyvisa_cases():
    c = []
    gl, gp = "Get-PyvisaLine", "Get-PyvisaFreezeProblems"
    # --- Get-PyvisaLine
    c.append(case("line_plain", gl, FreezeText="numpy==2.0\r\npyvisa==1.14.1\r\nrequests==2\r\n"))
    c.append(case("line_case_kept", gl, FreezeText="PyVISA==1.14.1\n"))
    c.append(case("line_at", gl, FreezeText="PyVISA @ file:///C:/x/pyvisa.whl\r\n"))
    c.append(case("line_bare", gl, FreezeText="pyvisa\n"))
    c.append(case("line_leading_spaces", gl, FreezeText="   pyvisa==1\n"))
    c.append(case("line_crlf", gl, FreezeText="a==1\r\npyvisa==1.0\r\n"))
    c.append(case("line_first_of_two", gl, FreezeText="pyvisa==1\npyvisa==2\n"))
    c.append(case("line_non_ascii", gl, FreezeText="pyvisa @ file:///C:/caf" + chr(233) + "/x\n"))
    c.append(case("line_cut_at_120", gl, FreezeText=LONG_LINE + "\n"))
    c.append(case("line_pyvisa_py", gl, FreezeText="pyvisa-py==0.7\n"))
    c.append(case("line_underscore", gl, FreezeText="pyvisa_py==1\n"))
    c.append(case("line_digit", gl, FreezeText="pyvisa2==1\n"))
    c.append(case("line_pyvisa_py_caps", gl, FreezeText="PyVISA-py==0.7\n"))
    c.append(case("line_not_at_the_start", gl, FreezeText="notpyvisa==1\n"))
    c.append(case("line_skips_the_other_package", gl, FreezeText="pyvisa-py==0.7\npyvisa==1.14\n"))
    c.append(case("line_empty", gl, FreezeText=""))
    # --- Get-PyvisaFreezeProblems
    c.append(case("freeze_good", gp, Label="declined", AnswerShown=True, SetupText=CAPTURED, FreezeText="pyvisa==1.14.1\r\n"))
    c.append(case("freeze_answer_not_shown", gp, Label="declined", AnswerShown=False, SetupText=CAPTURED, FreezeText="pyvisa==1.14.1\r\n"))
    c.append(case("freeze_not_captured", gp, Label="accepted", AnswerShown=True, SetupText="[INFO] other\r\n", FreezeText="pyvisa==1.14.1\r\n"))
    c.append(case("freeze_capture_failed", gp, Label="accepted", AnswerShown=True, SetupText="[WARN] DEP_INSTALLED_CAPTURE_FAILED=1\r\n",
                  FreezeText="pyvisa==1.14.1\r\n"))
    c.append(case("freeze_empty", gp, Label="declined", AnswerShown=True, SetupText=CAPTURED, FreezeText=""))
    c.append(case("freeze_whitespace_only", gp, Label="declined", AnswerShown=True, SetupText=CAPTURED, FreezeText="  \r\n \r\n"))
    c.append(case("freeze_no_pyvisa_line", gp, Label="accepted", AnswerShown=True, SetupText=CAPTURED, FreezeText="numpy==2\r\npyvisa-py==0.7\r\n"))
    c.append(case("freeze_everything_wrong_gives_one_problem", gp, Label="declined", AnswerShown=False, SetupText="", FreezeText=""))
    c.append(case("freeze_conda_style_line", gp, Label="accepted", AnswerShown=True, SetupText=CAPTURED,
                  FreezeText="PyVISA @ file:///home/conda/feedstock_root/build_artifacts/pyvisa_1\r\n"))
    return c


PYVISA_LINE_COUNT = 16
PYVISA_FREEZE_COUNT = 9
PYVISA_CASE_COUNT = PYVISA_LINE_COUNT + PYVISA_FREEZE_COUNT


@unittest.skipUnless(PWSH, "pwsh not available")
class PyvisaJudgesOnSyntheticRuns(unittest.TestCase):
    """Get-PyvisaLine and Get-PyvisaFreezeProblems of tests/selfapps_pyvisa_subfolder.ps1 on synthetic lists, in strict mode."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(PYVISA, JUDGES_PYVISA, pyvisa_cases(), d)

    def only(self, name, needle):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        self.assertIn(needle, found[0], (name, found))

    def test_the_line_is_the_first_one_that_names_the_pyvisa_package(self):
        self.assertEqual(self.r["line_plain"], ["pyvisa==1.14.1"])
        self.assertEqual(self.r["line_crlf"], ["pyvisa==1.0"])
        self.assertEqual(self.r["line_first_of_two"], ["pyvisa==1"])
        self.assertEqual(self.r["line_bare"], ["pyvisa"])
        self.assertEqual(self.r["line_leading_spaces"], ["pyvisa==1"])
        self.assertEqual(self.r["line_skips_the_other_package"], ["pyvisa==1.14"])

    def test_the_letter_case_of_the_name_is_matched_blind_and_kept_in_the_answer(self):
        self.assertEqual(self.r["line_case_kept"], ["PyVISA==1.14.1"])
        self.assertEqual(self.r["line_at"], ["PyVISA @ file:///C:/x/pyvisa.whl"])

    def test_another_package_whose_name_only_starts_with_pyvisa_is_not_the_package(self):
        for name in ("line_pyvisa_py", "line_underscore", "line_digit", "line_pyvisa_py_caps", "line_not_at_the_start", "line_empty"):
            with self.subTest(case=name):
                self.assertEqual(self.r[name], [""])

    def test_the_line_is_printable_ascii_and_cut_at_120_characters(self):
        self.assertEqual(self.r["line_non_ascii"], ["pyvisa @ file:///C:/caf?/x"])
        self.assertEqual(self.r["line_cut_at_120"], [LONG_LINE[:120]])
        self.assertEqual(len(self.r["line_cut_at_120"][0]), 120)

    def test_a_good_run_has_no_problem_and_a_conda_style_line_counts(self):
        self.assertEqual(self.r["freeze_good"], [])
        self.assertEqual(self.r["freeze_conda_style_line"], [])

    def test_each_wrong_run_is_one_problem_with_its_own_sentence_and_its_label(self):
        self.only("freeze_answer_not_shown", "declined: the run does not show the answer to the subfolder question")
        self.only("freeze_not_captured", "accepted: the setup log does not say that the installed packages were captured")
        self.only("freeze_capture_failed", "accepted: the setup log does not say that the installed packages were captured")
        self.only("freeze_empty", "declined: ~dependency_installed.txt is missing or empty")
        self.only("freeze_whitespace_only", "declined: ~dependency_installed.txt is missing or empty")
        self.only("freeze_no_pyvisa_line", "accepted: the list of installed packages has no pyvisa line")

    def test_the_first_failed_condition_ends_the_judgement_so_that_a_run_with_everything_wrong_is_one_problem(self):
        self.only("freeze_everything_wrong_gives_one_problem", "the run does not show the answer to the subfolder question")


# --- the driver the script writes from the real block ------------------------------------------------------------------------------

@unittest.skipUnless(PWSH, "pwsh not available")
class DriverFromRealBlock(unittest.TestCase):
    """The real block is converted and wrapped by the script's own functions (through pwsh); the driver for each scenario must have
    the shape the judge assumes. This is the nearest thing to running the script on this host: cmd.exe is Windows only. The folder of the
    drivers is a POSIX path because Join-Path of a drive-qualified path ('C:\\...') fails on a host with no drive C; the shape check takes
    either separator."""

    @classmethod
    def setUpClass(cls):
        batch = BATCH.read_text(encoding="utf-8", errors="replace")
        cls.block = cut_block(batch, VISA_START, VISA_END)
        with tempfile.TemporaryDirectory() as d:
            first = run_cases(PRESENT, JUDGES_PRESENT, [case("convert_real", "Convert-VisaBlock", Block=cls.block)], d)
        cls.converted = first["convert_real"][0]
        cases = [case("driver_" + name, "New-PresentDriver", Dir="/w/visa/" + name, Scenario=scenario, Block=cls.converted["Lines"])
                 for name, scenario in SCENARIOS.items()]
        with tempfile.TemporaryDirectory() as d:
            cls.drivers = run_cases(PRESENT, JUDGES_PRESENT, cases, d)

    def test_the_real_block_has_two_registry_looks_one_curl_line_and_one_web_request_to_replace(self):
        self.assertEqual(self.converted["Counts"], {"reg": 2, "curl": 1, "psdl": 1})
        self.assertEqual(len(self.converted["Lines"]), len(self.block))

    def test_the_converted_block_holds_no_live_registry_query_curl_or_web_request_and_one_probe_of_the_first_two_bytes(self):
        lines = self.converted["Lines"]
        live = [ln.strip() for ln in live_bat(lines)]
        for ln in live:
            self.assertIsNone(re.match(r"(?i)(reg\s+query|curl)\s", ln), ln)
            self.assertIsNone(re.search(r"(?i)Invoke-WebRequest", ln), ln)
        self.assertEqual(sum(1 for ln in live if re.match(r"(?i)powershell\s", ln)), 1)
        self.assertEqual(sum(1 for ln in live if ln == "call :stub_reg_query"), 2)
        self.assertEqual(sum(1 for ln in live if ln == "call :stub_ps_download"), 1)
        self.assertEqual(sum(1 for ln in live if ln.startswith("call :stub_curl ")), 1)

    def test_each_scenario_driver_has_the_shape_the_judge_assumes(self):
        for name, scenario in SCENARIOS.items():
            with self.subTest(scenario=name):
                self.assertEqual(driver_problems(self.drivers["driver_" + name], self.converted["Lines"], scenario), [])

    def test_the_drivers_differ_only_in_their_two_scenario_lines(self):
        base = self.drivers["driver_noinstall"]
        for name in ("subfolder", "control"):
            other = self.drivers["driver_" + name]
            self.assertEqual(len(other), len(base))
            diff = [(a, b) for a, b in zip(base, other) if a != b]
            self.assertTrue(all(a.startswith(("set \"REG_MODE=", "set \"NEED_VISA=", "set \"LEDGER=", "set \"LOG=", "set \"FLAG_REG=")) for a, _ in diff), diff)
        self.assertIn('set "REG_MODE=absent_then_present"', self.drivers["driver_control"])
        self.assertIn('set "REG_MODE=present"', self.drivers["driver_subfolder"])
        self.assertIn('set "NEED_VISA=2"', self.drivers["driver_subfolder"])


class DriverRulesCanFail(unittest.TestCase):
    """Each rule about the driver is shown to fail on a broken copy of a good one (built by hand from the converted sample block, so
    no pwsh is needed)."""

    def setUp(self):
        self.converted = ["call :stub_reg_query", "if not errorlevel 1 (", '  call :log "[VISA] present"', "  goto visa_done", ")"]
        self.scenario = SCENARIOS["control"]
        head = ["@echo off", "setlocal", 'set "LEDGER=C:\\w\\visa\\control\\~driver_ledger.txt"', 'set "LOG=C:\\w\\visa\\control\\~driver.log"',
                'set "FLAG_REG=C:\\w\\visa\\control\\~reg_seen.flag"', 'set "REG_MODE=absent_then_present"', 'set "NEED_VISA=1"']
        head += ['set "%s="' % name for name in HEAD_CLEARS]
        head += ['>"%LEDGER%" echo START', "goto :visa_wanted"]
        # the converted sample has no :visa_wanted label of its own, so the good driver here carries it as the first block line
        self.converted = [":visa_wanted"] + self.converted
        self.good = head + self.converted + list(EXPECTED_TAIL)

    def problems(self, driver):
        return driver_problems(driver, self.converted, self.scenario)

    def test_the_good_driver_has_no_problem(self):
        self.assertEqual(self.problems(self.good), [])

    def test_a_driver_that_enters_the_block_twice_or_never_is_reported(self):
        gone = [ln for ln in self.good if ln != "goto :visa_wanted"]
        self.assertTrue(any("holds 0 line(s) goto :visa_wanted" in f for f in self.problems(gone)))
        twice = self.good + ["goto :visa_wanted"]
        self.assertTrue(any("holds 2 line(s) goto :visa_wanted" in f for f in self.problems(twice)))

    def test_a_driver_without_its_start_line_or_head_is_reported(self):
        self.assertTrue(any("START" in f for f in self.problems(drop(self.good, '>"%LEDGER%" echo START'))))
        self.assertTrue(any("@echo off and setlocal" in f for f in self.problems(self.good[1:])))

    def test_a_driver_with_a_changed_ledger_path_or_scenario_value_is_reported(self):
        bad = swap(self.good, 'set "LEDGER=C:\\w\\visa\\control\\~driver_ledger.txt"', 'set "LEDGER=C:\\w\\visa\\control\\~other.txt"')
        self.assertTrue(any("set LEDGER to a path ending in ~driver_ledger.txt" in f for f in self.problems(bad)))
        bad = drop(self.good, 'set "REG_MODE=absent_then_present"')
        self.assertTrue(any('set "REG_MODE=absent_then_present"' in f for f in self.problems(bad)))
        # the stub of the gate in the tail sets NEED_VISA to 1 as well, so the line of the head is changed by its position
        bad = list(self.good)
        bad[bad.index('set "NEED_VISA=1"')] = 'set "NEED_VISA=2"'
        self.assertTrue(any('set "NEED_VISA=1"' in f for f in self.problems(bad)))

    def test_a_driver_that_forgets_to_clear_a_variable_the_block_reads_is_reported(self):
        for name in HEAD_CLEARS:
            with self.subTest(variable=name):
                bad = drop(self.good, 'set "%s="' % name)
                self.assertTrue(any("does not clear %s" % name in f for f in self.problems(bad)), self.problems(bad))

    def test_a_block_that_is_not_the_converted_one_is_reported(self):
        bad = swap(self.good, "call :stub_reg_query", "call :stub_reg_queryx")
        self.assertTrue(any("not the converted block" in f for f in self.problems(bad)))

    def test_a_changed_tail_is_reported(self):
        bad = swap(self.good, '>>"%LEDGER%" echo CURL %*', '>>"%LEDGER%" echo CURLX %*')
        self.assertTrue(any("the driver's last lines" in f for f in self.problems(bad)))

    def test_a_label_defined_twice_or_a_call_of_a_label_that_is_not_defined_is_reported(self):
        bad = self.good + [":log", "exit /b 0"]
        self.assertTrue(any("the label :log is defined 2 times" in f for f in self.problems(bad)))
        converted = self.converted + ["call :stub_curl -L x"]
        driver = self.good[:len(self.good) - len(EXPECTED_TAIL)] + ["call :stub_curl -L x"] + list(EXPECTED_TAIL)
        bad = swap(driver, ":stub_curl", ":stub_curlx")
        self.assertTrue(any("calls or goes to :stub_curl, which it does not define" in f for f in driver_problems(bad, converted, self.scenario)))

    def test_a_live_line_that_would_reach_the_registry_or_the_network_is_reported(self):
        for line in ('reg query "K" >nul', "curl -L x", 'powershell -Command "Invoke-WebRequest u"', "  REG QUERY K"):
            with self.subTest(line=line):
                converted = self.converted + [line]
                driver = self.good[:len(self.good) - len(EXPECTED_TAIL)] + [line] + list(EXPECTED_TAIL)
                found = driver_problems(driver, converted, self.scenario)
                self.assertTrue(any("would reach the real registry or the network" in f for f in found), found)


# --- the rules on the real files -------------------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.present = PRESENT.read_text(encoding="utf-8")
        self.pyvisa = PYVISA.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_block_looks_before_it_asks_downloads_or_installs_and_reaches_only_what_the_driver_defines(self):
        self.assertEqual(block_problems(self.batch, self.present), [])

    def test_the_main_flow_reaches_the_block_the_log_texts_the_judges_read_are_live_and_the_freeze_comes_first(self):
        self.assertEqual(flow_problems(self.batch, self.present), [])

    def test_the_present_script_has_its_rows_scenarios_driver_judges_and_exit_codes(self):
        self.assertEqual(present_script_problems(self.present), [])

    def test_the_pyvisa_script_has_its_fifth_row_its_judges_and_its_exit_codes(self):
        self.assertEqual(pyvisa_script_problems(self.pyvisa), [])

    def test_the_steps_gate_their_lanes_and_upload_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shalls_are_no_longer_listed_as_gaps(self):
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        block = cut_block(self.batch, VISA_START, VISA_END)
        # 59 live lines today; a block that grows or shrinks makes the driver's run a different run, so re-read the script's driver
        self.assertEqual(len(live_bat(block)), 59)
        self.assertEqual(sorted(KNOWN_BLOCK), sorted(variables_in(block)))
        self.assertEqual(set(HEAD_CLEARS) | {"LOG", "NEED_VISA"}, KNOWN_BLOCK - {"ERRORLEVEL"})
        # 51 cases = 9 of Get-StubCalls + 3 clean runs + 30 wrong runs with one problem each (ONE_PROBLEM) + 2 with two problems each
        # + 7 of Convert-VisaBlock; a judge case added or dropped changes the sum on purpose.
        self.assertEqual(len(present_cases()), PRESENT_CASE_COUNT)
        self.assertEqual(len(present_cases()), 51)
        self.assertEqual(len(ONE_PROBLEM), 30)
        self.assertEqual(len(pyvisa_cases()), PYVISA_CASE_COUNT)
        self.assertEqual(len(pyvisa_cases()), 25)
        self.assertEqual(len(set(c["name"] for c in present_cases())), 51)
        self.assertEqual(len(set(c["name"] for c in pyvisa_cases())), 25)

    def test_every_judge_the_drivers_are_asked_for_is_a_function_of_its_script(self):
        for name in JUDGES_PRESENT:
            self.assertRegex(norm(self.present), r"(?m)^function %s \{" % re.escape(name))
        for name in JUDGES_PYVISA:
            self.assertRegex(norm(self.pyvisa), r"(?m)^function %s \{" % re.escape(name))

    def test_every_scenario_of_the_script_has_a_ledger_here_and_a_row(self):
        self.assertEqual(sorted(LEDGERS), sorted(SCENARIOS))
        self.assertEqual(len(PRESENT_ROWS), len(SCENARIOS))
        for line in SCENARIO_LINES:
            self.assertIn(line, norm(self.present))


class BatchRulesCanFail(unittest.TestCase):
    """Each rule about run_setup.bat is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = PRESENT.read_text(encoding="utf-8")

    def problems(self, batch):
        return block_problems(batch, self.script)

    def flow(self, batch):
        return flow_problems(batch, self.script)

    def has(self, found, needle):
        self.assertTrue(any(needle in f for f in found), (needle, found))

    def test_a_label_that_is_missing_or_duplicated_is_reported(self):
        self.has(self.problems(mutate(self.batch, "\n:visa_wanted\n", "\n:visa_wantedx\n")), "appears 0 time(s)")
        self.has(self.problems(self.batch + "\n:visa_done\n"), "appears 2 time(s)")
        self.has(self.problems(mutate(self.batch, "\n:visa_subfolder_gate\n", "\n:visa_subfolder_gatex\n")), "appears 0 time(s)")
        self.has(self.problems(mutate(self.batch, "\n:run_installer_timeout\n", "\n:run_installer_timeoutx\n")), "appears 0 time(s)")

    def test_labels_in_the_wrong_order_are_reported_as_a_block_that_cannot_be_cut(self):
        bad = mutate(self.batch, "\n:visa_wanted\n", "\n:visa_wantedx\n") + "\n:visa_wanted\n"
        self.has(self.problems(bad), "cannot be cut")

    def test_a_missing_or_changed_first_look_at_the_registry_is_reported(self):
        self.has(self.problems(mutate(self.batch, FIRST_LOOK, 'if not errorlevel 1 (\n  call :log "[VISA] present"\n  goto visa_done\n)\n')),
                 "the block holds 1 live line(s) that start with reg query")
        self.has(self.problems(mutate(self.batch, FIRST_LOOK, FIRST_LOOK.replace("NI-VISA\"", "NI-VISA2\""))), "is not the one the row pins")
        self.has(self.problems(mutate(self.batch, FIRST_LOOK, FIRST_LOOK.replace("/v \"CurrentVersion\"", "/v \"Version\""))), "is not the one the row pins")

    def test_a_present_driver_that_no_longer_ends_the_block_is_reported(self):
        bad = mutate(self.batch, FIRST_LOOK, FIRST_LOOK.replace("  goto visa_done\n", ""))
        self.has(self.problems(bad), "the first look at the registry is no longer followed by the branch")
        bad = mutate(self.batch, FIRST_LOOK, FIRST_LOOK.replace('  call :log "[VISA] present"\n', ""))
        self.has(self.problems(bad), "the first look at the registry is no longer followed by the branch")

    def test_a_changed_poll_after_the_installer_is_reported(self):
        self.has(self.problems(mutate(self.batch, SECOND_LOOK, SECOND_LOOK.replace("goto visa_cleanup", "goto visa_done"))),
                 "the second look at the registry is no longer the poll")
        self.has(self.problems(mutate(self.batch, SECOND_LOOK, SECOND_LOOK.replace(":visa_post_check\n", ""))),
                 "the second look at the registry is no longer the poll")

    def test_a_question_asked_before_the_look_or_a_missing_gate_line_is_reported(self):
        moved = mutate(self.batch, GATE_LINE + "\n", "")
        moved = mutate(moved, FIRST_LOOK, GATE_LINE + "\n" + FIRST_LOOK)
        found = self.problems(moved)
        self.has(found, "must come before")
        self.has(found, "the test that NEED_VISA is 1 must follow the subfolder question directly")
        self.has(self.problems(mutate(self.batch, GATE_LINE + "\n", "")), "the subfolder question: expected exactly one live line")

    def test_a_missing_test_of_need_visa_is_reported(self):
        self.has(self.problems(mutate(self.batch, NEED_TEST + "\n", "")), "the test that NEED_VISA is 1: expected exactly one live line")

    def test_a_download_before_the_test_of_need_visa_is_reported(self):
        moved = mutate(self.batch, NEED_TEST + "\n" + INSTALLER_SET + "\n", INSTALLER_SET + "\n" + NEED_TEST + "\n")
        self.has(self.problems(moved), "the test that NEED_VISA is 1 must follow the subfolder question directly")

    def test_a_curl_line_the_driver_would_not_replace_is_reported(self):
        bad = mutate(self.batch, "\ncurl -L --silent --fail --retry 3", "\n  curl -L --silent --fail --retry 3")
        self.has(self.problems(bad), "the block must hold exactly one curl line and it must start at column 0")
        bad = mutate(self.batch, "\ncurl -L --silent --fail --retry 3 --retry-delay 5 --max-time 120 -o \"%NIVISA_INSTALLER%\"",
                     "\ncurl -L --silent --fail --retry 3 --retry-delay 5 --max-time 120 -o \"other.exe\"")
        self.has(self.problems(bad), "no longer writes to -o")
        bad = mutate(self.batch, "2>> \"%LOG%\"\nif errorlevel 1 (\n  set \"HP_VISA_DLVIA=powershell\"", "2>> \"%LOG%\"\nrem\nif errorlevel 1 (\n  set \"HP_VISA_DLVIA=powershell\"")
        self.assertEqual(bad.count("rem\nif errorlevel 1"), 1)
        self.assertEqual(self.problems(bad), [])

    def test_a_second_powershell_line_or_a_web_request_outside_the_fallback_is_reported(self):
        bad = mutate(self.batch, 'set "HP_VISA_PE="\n', 'set "HP_VISA_PE="\npowershell -NoProfile -Command "Get-Date"\n')
        self.has(self.problems(bad), "the block holds 3 powershell line(s)")
        bad = mutate(self.batch, "  set \"HP_VISA_DLVIA=powershell\"\n", "  set \"HP_VISA_DLVIA=powershell\"\n  rem x\n")
        self.assertEqual(self.problems(bad), [])
        bad = mutate(self.batch, "if errorlevel 1 (\n  set \"HP_VISA_DLVIA=powershell\"", "if 1==1 (\n  set \"HP_VISA_DLVIA=powershell\"")
        self.has(self.problems(bad), "the curl line is no longer followed directly by if errorlevel 1 (")
        self.has(self.problems(bad), "the PowerShell download must sit inside if errorlevel 1 (")

    def test_an_installer_call_that_changed_or_lost_its_exit_code_capture_is_reported(self):
        bad = mutate(self.batch, 'set "HP_VISA_INSTALLER_RC=%ERRORLEVEL%"\n', "")
        self.has(self.problems(bad), "the installer call is no longer followed directly by the capture of its exit code")
        bad = mutate(self.batch, 'call :run_installer_timeout "%NIVISA_INSTALLER%" "--quiet', 'call :run_installer_timeout2 "%NIVISA_INSTALLER%" "--quiet')
        self.has(self.problems(bad), "call(s) of :run_installer_timeout, expected 1")

    def test_a_block_that_calls_something_the_driver_does_not_define_is_reported(self):
        bad = mutate(self.batch, "\n:visa_cleanup\n", "\ncall :visa_extra\n:visa_cleanup\n")
        self.has(self.problems(bad), "the block calls")
        self.has(self.problems(bad), "the driver defines")

    def test_a_block_that_reads_a_new_variable_is_reported(self):
        bad = mutate(self.batch, 'set "HP_VISA_RETRY=0"\n:visa_post_check\n', 'set "HP_VISA_RETRY=0"\nif defined HP_VISA_EXTRA set "HP_VISA_RETRY=1"\n:visa_post_check\n')
        self.has(self.problems(bad), "HP_VISA_EXTRA")
        self.has(self.problems(bad), "does not define or clear")

    def test_a_new_goto_or_label_in_the_block_is_reported(self):
        bad = mutate(self.batch, 'set "HP_VISA_RETRY=0"\n:visa_post_check\n', 'set "HP_VISA_RETRY=0"\n:visa_extra\n:visa_post_check\n')
        self.has(self.problems(bad), "the block's labels are")
        bad = mutate(self.batch, 'set "HP_VISA_RETRY=0"\n:visa_post_check\n', 'set "HP_VISA_RETRY=0"\ngoto visa_extra\n:visa_post_check\n')
        self.has(self.problems(bad), "the block goes to")

    def test_a_block_that_loses_its_cleanup_is_reported(self):
        bad = mutate(self.batch, ':visa_cleanup\nif exist "%NIVISA_INSTALLER%" del "%NIVISA_INSTALLER%" >nul 2>&1\n:visa_done', ":visa_cleanup\n:visa_done")
        self.has(self.problems(bad), "the block no longer ends with the label :visa_cleanup")

    def test_a_block_that_logs_an_unknown_visa_line_is_reported(self):
        bad = mutate(self.batch, 'set "HP_VISA_PINGN=6"\n', 'call :log "[VISA] waiting for the installer"\nset "HP_VISA_PINGN=6"\n')
        self.has(self.problems(bad), "the block logs an unknown [VISA] line")

    def test_a_main_flow_that_no_longer_reaches_the_block_is_reported(self):
        bad = mutate(self.batch, 'if "%NEED_VISA%"=="2" goto visa_wanted\n', 'if "%NEED_VISA%"=="2" goto visa_done\n')
        self.has(self.flow(bad), "the main flow no longer reaches the block by exactly one line")
        bad = mutate(self.batch, 'if "%NEED_VISA%"=="2" goto visa_wanted\n', 'if "%NEED_VISA%"=="2" goto visa_wanted\nif "%NEED_VISA%"=="3" goto visa_wanted\n')
        self.has(self.flow(bad), "more or fewer than two lines go to :visa_wanted")

    def test_a_reworded_log_text_is_reported_for_each_of_the_four_texts(self):
        for text, new in (("[VISA] present", "[VISA] found"), ("[VISA] download method: ", "[VISA] downloaded by: "),
                          ("[VISA] installer exit code: ", "[VISA] installer returned: "), ("[VISA] install_success", "[VISA] install_done")):
            with self.subTest(text=text):
                bad = mutate(self.batch, text, new)
                self.has(self.flow(bad), repr(text))

    def test_a_new_install_failed_line_or_a_missing_one_is_reported(self):
        bad = mutate(self.batch, 'call :log "[VISA] install_failed (download)"\n', "")
        self.has(self.flow(bad), "the batch file holds 1 live [VISA] install_failed log line(s), expected 2")
        bad = mutate(self.batch, 'set "HP_VISA_PINGN=6"\n', 'call :log "[VISA] install_failed (other)"\nset "HP_VISA_PINGN=6"\n')
        self.has(self.flow(bad), "the batch file holds 3 live [VISA] install_failed log line(s), expected 2")

    def test_a_pip_freeze_that_changed_moved_after_the_block_or_lost_its_log_line_is_reported(self):
        bad = mutate(self.batch, FREEZE_CAPTURED + "\n", "")
        self.has(self.flow(bad), "the log line DEP_INSTALLED_CAPTURED=1: expected exactly one live line")
        moved = mutate(self.batch, FREEZE_CAPTURED + "\n", "")
        moved = mutate(moved, "\n:visa_done\n", "\n:visa_done\n" + FREEZE_CAPTURED + "\n")
        self.has(self.flow(moved), "the log line DEP_INSTALLED_CAPTURED=1 must come before the NI-VISA block")
        bad = mutate(self.batch, FREEZE_PIP, FREEZE_PIP.replace("pip freeze", "pip list"))
        self.has(self.flow(bad), "the pip freeze into ~dependency_installed.txt: expected exactly one live line")
        bad = mutate(self.batch, FREEZE_UV, FREEZE_UV.replace("pip freeze", "pip list"))
        self.has(self.flow(bad), "the uv pip freeze into ~dependency_installed.txt: expected exactly one live line")

    def test_a_script_that_stops_looking_for_a_log_text_is_reported(self):
        for text in JUDGED_STRINGS:
            with self.subTest(text=text):
                script = norm(self.script)
                self.assertIn(text, script)
                # a text can be matched in two places of the script (the count and the order), so every occurrence is changed
                bad = script.replace(text, text.replace("VISA", "VISX") if "VISA" in text else text + "x")
                self.assertNotEqual(bad, script)
                self.has(flow_problems(self.batch, bad), "the script no longer holds the judged text")


class ScriptRulesCanFail(unittest.TestCase):
    """Each rule about the two scripts, the workflow, the registry and the shall list is shown to fail on a mutated copy."""

    def setUp(self):
        self.present = norm(PRESENT.read_text(encoding="utf-8"))
        self.pyvisa = norm(PYVISA.read_text(encoding="utf-8"))
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def has(self, found, needle):
        self.assertTrue(any(needle in f for f in found), (needle, found))

    def test_a_row_id_that_is_not_literal_is_caught(self):
        bad = mutate(self.present, "id = 'self.nivisa.present.noinstall'; req = 'REQ-008.2'; pass = $pass", "id = $rowId; req = 'REQ-008.2'; pass = $pass")
        self.has(present_script_problems(bad), "literal")
        bad = mutate(self.pyvisa, "    id      = 'self.nivisa.pyvisa.installed'", "    id      = $rowId")
        self.has(pyvisa_script_problems(bad), "must be a literal")

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        bad = mutate(self.present, "id = 'self.nivisa.present.control'; req = 'REQ-008.2'; pass = $pass", "id = 'self.nivisa.present.control'; req = 'REQ-008'; pass = $pass")
        self.has(present_script_problems(bad), "req tag")
        bad = mutate(self.pyvisa, "    req     = 'REQ-008.15'", "    req     = 'REQ-008'")
        self.has(pyvisa_script_problems(bad), "literal req tag")

    def test_a_comment_that_holds_the_shape_of_a_tag_is_caught(self):
        bad = self.present.replace("# Emits:", "# req = 'REQ-008.2' is a tag shape\n# Emits:", 1)
        self.has(present_script_problems(bad), "a comment holds the shape req")
        bad = self.pyvisa.replace("# Emits:", "# req = 'REQ-008.15' is a tag shape\n# Emits:", 1)
        self.has(pyvisa_script_problems(bad), "a comment holds the shape req")

    def test_a_scenario_that_changes_stops_being_the_one_the_shall_names_is_caught(self):
        for old, new in (("NeedVisa = '1'; RegMode = 'present' }", "NeedVisa = '2'; RegMode = 'present' }"),
                         ("Name = 'control'; Kind = 'install'; NeedVisa = '1'; RegMode = 'absent_then_present'", "Name = 'control'; Kind = 'install'; NeedVisa = '1'; RegMode = 'present'"),
                         ("Name = 'subfolder'; Kind = 'present'; NeedVisa = '2'", "Name = 'subfolder'; Kind = 'present'; NeedVisa = '1'")):
            with self.subTest(old=old):
                bad = self.present.replace(old, new, 1)
                self.assertNotEqual(bad, self.present)
                self.has(present_script_problems(bad), "the scenario list no longer holds")

    def test_a_cut_that_moved_or_a_converter_that_lost_a_replacement_is_caught(self):
        bad = mutate(self.present, "-EndLabel ':visa_done'", "-EndLabel ':log'")
        self.has(present_script_problems(bad), "no longer cuts the block")
        bad = mutate(self.present, "'call :stub_ps_download'", "'call :stub_ps'")
        self.has(present_script_problems(bad), "'call :stub_ps_download'")
        bad = mutate(self.present, "-replace '^curl\\s+', 'call :stub_curl '", "-replace '^curl\\s+', 'call :curl '")
        self.has(present_script_problems(bad), "call :stub_curl")

    def test_a_script_that_would_run_a_block_with_the_wrong_counts_is_caught(self):
        bad = mutate(self.present, "$converted.Counts['reg'] -ne 2", "$converted.Counts['reg'] -ne 3")
        self.has(present_script_problems(bad), "no longer refuses to run a driver")

    def test_open_standard_input_and_a_missing_kill_are_caught(self):
        bad = mutate(self.present, "call ~driver.bat > ~driver_console.txt 2>&1 < nul", "call ~driver.bat > ~driver_console.txt 2>&1")
        self.has(present_script_problems(bad), "standard input")
        bad = mutate(self.present, "& taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null", "")
        self.has(present_script_problems(bad), "taskkill")
        bad = mutate(self.present, "-LimitMs 180000", "-LimitMs 1800000")
        self.has(present_script_problems(bad), "-LimitMs 180000")

    def test_a_verdict_that_stops_handing_the_judge_what_it_needs_is_caught(self):
        bad = mutate(self.present, "-NeedVisa $Scenario.NeedVisa)", "-NeedVisa '1')")
        self.has(present_script_problems(bad), "-NeedVisa $Scenario.NeedVisa")
        bad = mutate(self.present, "-LedgerText $ledger -NeedVisa", "-LedgerText '' -NeedVisa")
        self.has(present_script_problems(bad), "-LedgerText $ledger")
        bad = mutate(self.present, "$pass = [bool](@($control.Problems).Count -eq 0)", "$pass = $true")
        self.has(present_script_problems(bad), "the row of control is no longer judged")
        bad = mutate(self.present, "$found = @(Get-PresentProblems", "$found = @(Get-Other")
        self.has(present_script_problems(bad), "no longer judged by Get-PresentProblems")

    def test_a_script_without_its_exit_codes_or_with_isWindows_or_a_non_ascii_character_is_caught(self):
        bad = mutate(self.present, "if (-not $allPass) { exit 1 }\nexit 0\n", "exit 0\n")
        self.has(present_script_problems(bad), "exits 1 for a red row")
        bad = mutate(self.present, "if (-not $allPass) { exit 1 }\nexit 0\n", "if (-not $allPass) { exit 1 }\n")
        self.has(present_script_problems(bad), "does not end with exit 0")
        bad = mutate(self.present, "if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {", "if (-not $IsWindows) {")
        self.has(present_script_problems(bad), "OSVersion.Platform")
        self.has(present_script_problems(self.present + "\n# caf" + chr(233) + "\n"), "ASCII")
        self.has(pyvisa_script_problems(self.pyvisa + "\n# caf" + chr(233) + "\n"), "ASCII")

    def test_a_judge_that_is_missing_is_caught(self):
        bad = mutate(self.present, "function Get-PresentProblems {", "function Get-PresentProblemsX {")
        self.has(present_script_problems(bad), "Get-PresentProblems is missing")
        bad = mutate(self.pyvisa, "function Get-PyvisaFreezeProblems {", "function Get-PyvisaFreezeProblemsX {")
        self.has(pyvisa_script_problems(bad), "Get-PyvisaFreezeProblems is missing")

    def test_a_pyvisa_script_that_loses_its_hand_overs_or_its_exit_condition_is_caught(self):
        bad = mutate(self.pyvisa, "-AnswerShown ([bool]$dSkipped)", "-AnswerShown $true")
        self.has(pyvisa_script_problems(bad), "Get-PyvisaFreezeProblems -Label 'declined'")
        bad = mutate(self.pyvisa, "(Join-Path $a.Work '~dependency_installed.txt')", "(Join-Path $a.Work '~dependency.txt')")
        self.has(pyvisa_script_problems(bad), "$aFreeze = Read-Text")
        bad = mutate(self.pyvisa, "-and $oPass -and $pyPass)) { exit 1 }", "-and $oPass)) { exit 1 }")
        self.has(pyvisa_script_problems(bad), "exit 1 }")
        bad = mutate(self.pyvisa, "'requirements.txt' = 'pyvisa' }\n$topFiles", "'requirements.txt' = 'numpy' }\n$topFiles")
        self.has(pyvisa_script_problems(bad), "$subFiles")
        bad = mutate(self.pyvisa, "    pass    = $pyPass", "    pass    = $true")
        self.has(pyvisa_script_problems(bad), "no longer writes pass = $pyPass")

    def test_an_older_row_that_the_script_stops_writing_is_caught(self):
        bad = self.pyvisa.replace("self.nivisa.topfolder.noprompt", "self.nivisa.topfolder.other")
        self.has(pyvisa_script_problems(bad), "self.nivisa.topfolder.noprompt is no longer written")

    def test_a_step_that_is_not_contract_uv_only_is_caught(self):
        block = step_block(self.workflow, PRESENT_NAME)
        self.assertIsNotNone(block)
        other = self.workflow.replace(block, block.replace("matrix.mode == 'contract-uv'", "matrix.mode == 'real'"))
        self.has(workflow_problems(other), "contract-uv")

    def test_a_step_that_cannot_fail_is_caught(self):
        for name in (PRESENT_NAME, PYVISA_NAME):
            with self.subTest(step=name):
                block = step_block(self.workflow, name)
                bad = self.workflow.replace(block, block.replace("        shell: pwsh\n", "        shell: pwsh\n        continue-on-error: true\n", 1))
                self.has(workflow_problems(bad), "continue-on-error")

    def test_a_pyvisa_step_that_leaves_a_lane_is_caught(self):
        block = step_block(self.workflow, PYVISA_NAME)
        self.assertIsNotNone(block)
        bad = self.workflow.replace(block, block.replace("matrix.mode == 'real' || ", ""))
        self.has(workflow_problems(bad), "matrix.mode == 'real'")
        bad = self.workflow.replace(block, block.replace("!cancelled() && ", ""))
        self.has(workflow_problems(bad), "!cancelled()")

    def test_a_missing_step_or_upload_is_caught(self):
        found = workflow_problems("name: x\n")
        self.has(found, "no step runs tests\\" + PRESENT_NAME)
        self.has(found, "no step runs tests\\" + PYVISA_NAME)
        for pattern in UPLOADS:
            with self.subTest(pattern=pattern):
                self.has(workflow_problems(self.workflow.replace(pattern, "")), pattern)

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        text = REGISTRY.read_text(encoding="utf-8")
        for row in PRESENT_ROWS + (PYVISA_ROW,):
            with self.subTest(row=row):
                self.assertTrue(registry_problems(text.replace(row, row + "x")))
        self.assertTrue(registry_problems("```\nself.nivisa.present.noinstall\n```\nprose: self.nivisa.present.subfolder, self.nivisa.present.control\n"))

    def test_a_shall_that_is_still_listed_as_a_gap_is_caught(self):
        self.assertTrue(shall_list_problems('    "REQ-008.2": "gap: x",\n'))
        self.assertTrue(shall_list_problems('    "REQ-008.15": "gap: x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-008.20": "gap: x",\n    "REQ-008.150": "gap: y",\n'), [])


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesCanFail(unittest.TestCase):
    """A judge that quietly stops judging would pass every scenario, so the cases are run against mutated copies of the scripts: each
    comparison replaced by $false must make the case that depends on it come out without its sentence, and each pattern or token that
    is changed must make the case that depends on it come out differently."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.base = run_cases(PRESENT, JUDGES_PRESENT, present_cases(), d)
        with tempfile.TemporaryDirectory() as d:
            cls.pybase = run_cases(PYVISA, JUDGES_PYVISA, pyvisa_cases(), d)

    def mutated_run(self, script, judges, cases, old, new, names):
        text = norm(script.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "mutated.ps1"
            path.write_text(text.replace(old, new), encoding="utf-8")
            wanted = [cs for cs in cases if cs["name"] in names]
            return run_cases(path, judges, wanted, d)

    def silenced(self, comparison, name, needle):
        """Replacing `if (<comparison>) {` by `if ($false) {` must remove the sentence `needle` from the answer for case `name`."""
        self.assertTrue(any(needle in f for f in self.base[name]), (name, needle, self.base[name]))
        got = self.mutated_run(PRESENT, JUDGES_PRESENT, present_cases(), "if (" + comparison + ") {", "if ($false) {", [name])
        self.assertFalse(any(needle in f for f in got[name]), (name, needle, got[name]))

    def changes(self, old, new, names):
        """The mutation must change the answer of every case in `names`."""
        got = self.mutated_run(PRESENT, JUDGES_PRESENT, present_cases(), old, new, names)
        for name in names:
            self.assertNotEqual(got[name], self.base[name], (old, new, name))

    def test_the_comparisons_of_the_common_part_each_matter(self):
        for comparison, name, needle in (
            ("-not $Finished", "unfinished", "did not finish within the time limit"),
            ("$nStart -ne 1", "no_start", "did not write START exactly once"),
            ("$nEnd -ne 1", "no_end", "did not reach its end"),
            ("$nFinished -ne 1", "need_visa_changed", "the ledger does not hold 'FINISHED NEED_VISA="),
            ("$nGate -ne 0", "gate_asked", "asked the question of the subfolder gate"),
            ("$nFileGone -ne 1", "installer_left", "is left after the block"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_the_comparisons_of_the_present_part_each_matter(self):
        for comparison, name, needle in (
            ("$nReg -ne 1", "no_registry_look", "looked at the registry"),
            ("$nPresent -ne 1", "no_present_line", "'[VISA] present' line(s), expected 1"),
            ("$nCurl -ne 0", "curl", "with curl"),
            ("$nPsdl -ne 0", "psdl", "with PowerShell"),
            ("$nInstall -ne 0", "install", "started the installer"),
            ("$said.Count -gt 0", "said_download", "the log says the driver was downloaded"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_the_comparisons_of_the_control_part_each_matter(self):
        for comparison, name, needle in (
            ("$calledSeq -ne 'REG CURL INSTALL REG'", "control_wrong_calls", "the block's calls were"),
            ("$nPresent -ne 0", "control_present_logged", "although the registry answered absent"),
            ("$nMethod -ne 1", "control_no_method_line", "'download method: curl' line(s)"),
            ("$nRc -ne 1", "control_no_exit_code_line", "'installer exit code: 0' line(s)"),
            ("$nSuccess -ne 1", "control_no_success", "'install_success' line(s)"),
            ("$nFailed -ne 0", "control_install_failed", "'install_failed' line(s)"),
            ("($regAt.Count -eq 2) -and ($successAt -ge 0) -and ($successAt -lt $regAt[1])", "control_success_before_second_look",
             "the success was logged before the second look"),
        ):
            with self.subTest(comparison=comparison):
                self.silenced(comparison, name, needle)

    def test_a_judge_that_forgets_which_kind_of_run_it_judges_is_caught(self):
        # every run judged as the control: a clean run where the driver is installed is no longer clean
        self.changes("if ($Kind -eq 'present') {", "if ($Kind -eq 'presentx') {", ["present_good", "subfolder_good"])
        # every run judged as one where the driver is installed: a clean control is no longer clean
        self.changes("if ($Kind -eq 'present') {", "if ($Kind -ne 'presentx') {", ["control_good"])

    def test_a_success_that_is_compared_with_the_wrong_look_is_caught(self):
        self.changes("($successAt -lt $regAt[1])", "($successAt -gt $regAt[1])", ["control_success_before_second_look", "control_good"])

    def test_every_token_of_the_stub_calls_matters(self):
        for old, new, names in (
            ("($l -eq 'REG')", "($l -eq 'REGX')", ["calls_control"]),
            ("($l -eq 'PSDL')", "($l -eq 'PSDLX')", ["calls_every_token"]),
            ("($l -eq 'GATE')", "($l -eq 'GATEX')", ["calls_every_token"]),
            ("($l -eq 'CURL') -or ", "", ["calls_bare_curl_and_install"]),
            ("($l -like 'CURL *')", "($l -like 'CURL*')", ["calls_prefix_words_are_not_calls"]),
            ("($l -eq 'INSTALL') -or ", "", ["calls_bare_curl_and_install"]),
            ("($l -like 'INSTALL *')", "($l -like 'INSTALL*')", ["calls_prefix_words_are_not_calls"]),
            ("$l = $raw.Trim()", "$l = $raw", ["calls_trimmed"]),
        ):
            with self.subTest(old=old):
                self.changes(old, new, names)

    def test_every_pattern_of_the_conversion_matters(self):
        for old, new, names in (
            ("'^\\s*reg\\s+query\\s'", "'^reg\\s+query\\s'", ["convert_indented_reg"]),
            ("'^curl\\s'", "'^\\s*curl\\s'", ["convert_indented_curl_unchanged"]),
            ("'^\\s*powershell\\s.*Invoke-WebRequest'", "'^\\s*powershell\\s'", ["convert_pe_probe_unchanged", "convert_sample"]),
            ("'call :stub_curl '", "'call :stub_curl'", ["convert_sample"]),
            ("$counts['reg'] = $counts['reg'] + 1", "$counts['reg'] = 1", ["convert_counts_two_of_each"]),
            ("$counts['curl'] = $counts['curl'] + 1", "$counts['curl'] = 1", ["convert_counts_two_of_each"]),
            ("$counts['psdl'] = $counts['psdl'] + 1", "$counts['psdl'] = 1", ["convert_counts_two_of_each"]),
        ):
            with self.subTest(old=old):
                self.changes(old, new, names)

    def pychanges(self, old, new, names):
        got = self.mutated_run(PYVISA, JUDGES_PYVISA, pyvisa_cases(), old, new, names)
        for name in names:
            self.assertNotEqual(got[name], self.pybase[name], (old, new, name))

    def test_every_pattern_of_the_pyvisa_line_matters(self):
        for old, new, names in (
            ("'^pyvisa(\\s*==|\\s*@|\\s|$)'", "'pyvisa'", ["line_pyvisa_py", "line_not_at_the_start"]),
            ("$clean.Length -gt 120", "$clean.Length -gt 500", ["line_cut_at_120"]),
            ("'[^\\x20-\\x7E]'", "'[^\\x20-\\xFF]'", ["line_non_ascii"]),
            ("$l = $raw.Trim()", "$l = $raw", ["line_leading_spaces"]),
        ):
            with self.subTest(old=old):
                self.pychanges(old, new, names)

    def test_every_comparison_of_the_pyvisa_judge_matters(self):
        for comparison, name, needle in (
            ("-not $AnswerShown", "freeze_answer_not_shown", "does not show the answer"),
            ("$SetupText.IndexOf('DEP_INSTALLED_CAPTURED=1', [System.StringComparison]::Ordinal) -lt 0", "freeze_not_captured", "were captured"),
            ("[string]::IsNullOrWhiteSpace($FreezeText)", "freeze_empty", "missing or empty"),
            ("-not $line", "freeze_no_pyvisa_line", "has no pyvisa line"),
        ):
            with self.subTest(comparison=comparison):
                self.assertTrue(any(needle in f for f in self.pybase[name]), (name, self.pybase[name]))
                got = self.mutated_run(PYVISA, JUDGES_PYVISA, pyvisa_cases(), "if (" + comparison + ") {", "if ($false) {", [name])
                self.assertFalse(any(needle in f for f in got[name]), (name, got[name]))


if __name__ == "__main__":
    unittest.main()
