"""Item 99 (README REQ-012.5, REQ-018.5, REQ-018.14, REQ-018.16, REQ-018.20, REQ-018.21 and REQ-018.22): rows for seven
shalls that had no row able to fail for them (the gaps listed for them in tests/test_req_shall_trace.py until this change).

What really happens in a bootstrap is checked on Windows by two scripts: tests/selfapps_runtime_install_edges.ps1 (rows
self.runtime.install.once, .notoffered, .listing, .stillmissing, .failed and .rebuildfailed; contract-uv lane) and
tests/selfapps_skiphooks_single.ps1 (rows self.launch.warning.throwaway and self.skiphooks.exe_only.panel; real lane).
These rules read run_setup.bat, both scripts, batch-check.yml and docs/agent-ndjson.md as text, and run the scripts' own
judging functions through a real pwsh on synthetic runs, so a reworded log line, a block the driver can no longer cut out of
the batch file, a judging rule that stops judging, an expectation that is quietly weakened or a step that stops gating fails
here with a sentence, before a Windows run is needed. Synthetic cases prove each rule can fail.

The one change to the product is a test hook, HP_TEST_FORCE_RTI_REBUILD_FAIL: set, :rti_rebuild gives PyInstaller an option it
rejects so the rebuild fails the way a broken build does; absent, the command line is what it was.
"""
import ast
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
EDGES = REPO / "tests" / "selfapps_runtime_install_edges.ps1"
SKIP = REPO / "tests" / "selfapps_skiphooks_single.ps1"
INSTALL = REPO / "tests" / "selfapps_runtime_install.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
SHALL_TEST = REPO / "tests" / "test_req_shall_trace.py"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

EDGE_ROWS = (
    ("self.runtime.install.once", "REQ-018.14"),
    ("self.runtime.install.notoffered", "REQ-018.16"),
    ("self.runtime.install.listing", "REQ-018.22"),
    ("self.runtime.install.stillmissing", "REQ-018.20"),
    ("self.runtime.install.failed", "REQ-018.21"),
    ("self.runtime.install.rebuildfailed", "REQ-018.21"),
)
SKIP_NEW_ROWS = (
    ("self.launch.warning.throwaway", "REQ-018.5"),
    ("self.skiphooks.exe_only.panel", "REQ-012.5"),
)
ALL_NEW_IDS = [row_id for row_id, _tag in EDGE_ROWS + SKIP_NEW_ROWS]
# The shalls whose gap entry in tests/test_req_shall_trace.py this change removes.
SHALL_ENTRIES = ("REQ-012.5", "REQ-018.5", "REQ-018.14", "REQ-018.16", "REQ-018.20", "REQ-018.21", "REQ-018.22")

# The programs the three bootstraps run and the names the judging expects: (installable package, package that cannot be installed).
RUN_ARGS = {
    "stillmissing": ("xlsxwriter", "pvw_still_missing_"),
    "failed": ("", "pvw_ghost_pkg_"),
    "rebuildfailed": ("xlsxwriter", ""),
}

# What each driver scenario must show. A weakened expectation (a count lowered, a scenario that stops being the one the shall
# names) would make a row pass vacuously, so the table is pinned here as well as in the script.
GATES = {
    "system_exe": {"sites": ["exe"], "set": {"HP_ENV_MODE": "system", "HP_TEST_RTM_ANSWER": "N"}, "modules": ["xlsxwriter"],
                   "headings": 0, "notoffered": 1, "declined": 0, "packages": "", "choice": False},
    "system_interp": {"sites": ["interpreter"], "set": {"HP_ENV_MODE": "system", "HP_TEST_RTM_ANSWER": "N"}, "modules": ["xlsxwriter"],
                      "headings": 0, "notoffered": 1, "declined": 0, "packages": "", "choice": False},
    "nointerp_exe": {"sites": ["exe"], "set": {"HP_TEST_RTM_ANSWER": "N"}, "modules": ["xlsxwriter"],
                     "headings": 0, "notoffered": 1, "declined": 0, "packages": "", "choice": False},
    "fallback_exe": {"sites": ["exe"], "set": {"HP_ENV_MODE": "uv", "HP_NUITKA_FALLBACK_USED": "1", "HP_TEST_RTM_ANSWER": "N"},
                     "modules": ["xlsxwriter"], "headings": 0, "notoffered": 1, "declined": 0, "packages": "", "choice": False},
    "control_offered": {"sites": ["exe"], "set": {"HP_ENV_MODE": "uv", "HP_TEST_RTM_ANSWER": "N"}, "modules": ["xlsxwriter"],
                        "headings": 1, "notoffered": 0, "declined": 1, "packages": "xlsxwriter", "choice": False},
    "once": {"sites": ["exe", "interpreter"], "set": {"HP_ENV_MODE": "uv", "HP_TEST_RTM_ANSWER": "N"}, "modules": ["xlsxwriter"],
             "headings": 1, "notoffered": 0, "declined": 1, "packages": "", "choice": False},
    "console": {"sites": ["exe"], "set": {"HP_ENV_MODE": "uv"}, "modules": ["xlsxwriter"],
                "headings": 1, "notoffered": 0, "declined": 1, "packages": "", "choice": True},
    "listing": {"sites": ["exe"], "set": {"HP_ENV_MODE": "uv", "HP_TEST_RTM_ANSWER": "N"},
                "modules": ["cv2", "PIL", "pvw_listing_other_"], "headings": 1, "notoffered": 0, "declined": 1,
                "packages": "opencv-python|pillow|pvw_listing_other_", "choice": False},
}

HOOK = "HP_TEST_FORCE_RTI_REBUILD_FAIL"
BAD_VAR = "HP_RTI_TEST_BAD"
BAD_OPTION = "--pvw-test-invalid-option"

# Every text a judging function looks for in the log or the console is written by a live line of the batch, and is written in the
# script too, so a reworded line turns a row red with a sentence here and not with an unexplained missing line on Windows.
# The negative texts (the provider cascade) are here as well: a row that says "no cascade started" is vacuous if the wording of
# the cascade's own lines moved.
BATCH_TEXTS = (
    "Runtime install: not offered for this build or provider.",
    "Runtime install: declined. Nothing was changed.",
    "Runtime install: accepted.",
    "Runtime install: installing %HP_RTI_PKG%",
    "Runtime install: installed %HP_RTI_PKG%.",
    "Runtime install: could not install %HP_RTI_PKG%.",
    "Runtime install: added %%P to requirements.txt.",
    "Runtime install: rebuilding the standalone EXE",
    "[REPAIR] rebuild complete after runtime install.",
    "[ERROR] Runtime install: the rebuild failed",
    "Runtime install: running your program once more to check.",
    "Runtime install: verified.",
    "Runtime install: the program still reports a missing module after the install.",
    "Runtime install: no package could be installed. Nothing else was changed.",
    "Your program needed the module %HP_RTM_MOD% while it was running",
    "Your program asked for packages that are not installed:",
    "Install them now?",
    "echo ***   %%B",
    "REQ-009: cascading provider",
    "REQ-009: cascade approved",
    "REQ-009: cascade consent: accepted",
    "Last chance: cascade approved",
)
SCRIPT_TEXTS = (
    "Runtime install: not offered for this build or provider.",
    "Runtime install: declined. Nothing was changed.",
    "Runtime install: accepted\\.",
    "Runtime install: installing ",
    "Runtime install: installed ",
    "Runtime install: could not install ",
    "Runtime install: added ",
    "Runtime install: rebuilding the standalone EXE",
    "\\[REPAIR\\] rebuild complete after runtime install",
    "\\[ERROR\\] Runtime install: the rebuild failed",
    "Runtime install: running your program once more to check",
    "Runtime install: verified",
    "Runtime install: the program still reports a missing module after the install",
    "Runtime install: no package could be installed\\. Nothing else was changed\\.",
    "Your program needed the module ",
    "Your program asked for packages that are not installed:",
    "Install them now?",
    "REQ-009: cascading provider",
    "REQ-009: cascade approved",
    "REQ-009: cascade consent: accepted",
    "Last chance: cascade approved",
    HOOK,
)

EDGES_STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
EDGES_UPLOADS = (
    "tests/~runtime_install_edges_evidence.txt",
    "tests/~selftest_rtiedge_gate/*/~driver.log",
    "tests/~selftest_rtiedge_gate/*/~driver_console.txt",
    "tests/~selftest_rtiedge_gate/*/~driver_result.txt",
    "tests/~selftest_rtiedge_gate/*/~choice_args.txt",
    "tests/~selftest_rtiedge_*/~edge_*.log",
    "tests/~selftest_rtiedge_*/~setup.log",
    "tests/~selftest_rtiedge_*/~run.out.txt",
    "tests/~selftest_rtiedge_*/~run.err.txt",
    "tests/~selftest_rtiedge_*/requirements.txt",
    "tests/~selftest_rtiedge_*/~sub.ndjson",
    "tests/~selftest_rtiedge_*/~bootstrap.status.json",
    "tests/~selftest_skiphooks_entry_only/~hook_f3.log",
    "tests\\~selftest_skiphooks_entry_only\\~hook_f3.log",
)

ALLOWED_CALLS = {"log", "rti_row", "emit_from_base64", "rti_install_one", "rti_rebuild", "run_exe_smokerun", "verify_no_exe_interpreter"}
YES_ONLY_CALLS = ("rti_install_one", "rti_rebuild", "run_exe_smokerun", "verify_no_exe_interpreter")
PROVIDERS_OFFERED = {"uv", "conda", "venv", "embed"}


def norm(text):
    return text.replace("\r\n", "\n")


def lines_of(text):
    return norm(text).split("\n")


def is_comment(line):
    return re.match(r"(?i)\s*(rem\b|::)", line) is not None


def live_ps(text):
    """Stripped, non-blank, non-comment lines of a PowerShell script."""
    return [ln.strip() for ln in lines_of(text) if ln.strip() and not ln.strip().startswith("#")]


def between(flat, start, end):
    """The text from `start` up to the next occurrence of `end`; None when either is missing."""
    a = flat.find(start)
    if a < 0:
        return None
    b = flat.find(end, a + len(start))
    return None if b < 0 else flat[a:b]


def app_code(text, kind):
    m = re.search(r"\$appCodes\['%s'\] = @'\n(.*?)\n'@" % re.escape(kind), norm(text), re.S)
    return m.group(1) if m else None


def program_names(code):
    """The module names a fixture program asks for, joined the way it joins them at run time."""
    m = re.search(r"for parts in (\(.*\)):\s*$", code, re.M)
    if not m:
        return None
    try:
        return ["".join(p) for p in ast.literal_eval(m.group(1))]
    except (ValueError, SyntaxError, TypeError):
        return None


GATE_LINE = re.compile(
    r"^\(New-Gate -Name '(?P<name>\w+)' -Sites @\((?P<sites>[^)]*)\) -Set \(\[ordered\]@\{(?P<set>[^}]*)\}\) "
    r"-Modules @\((?P<modules>[^)]*)\) -Headings (?P<h>\d+) -NotOffered (?P<n>\d+) -Declined (?P<d>\d+)(?P<rest>.*?)\),?$")


def parse_gates(text):
    gates = {}
    for ln in live_ps(text):
        m = GATE_LINE.match(ln)
        if not m:
            continue
        rest = m.group("rest")
        pk = re.search(r"-Packages '([^']*)'", rest)
        gates[m.group("name")] = {
            "sites": re.findall(r"'([^']*)'", m.group("sites")),
            "set": dict(re.findall(r"(\w+) = '([^']*)'", m.group("set"))),
            "modules": re.findall(r"'([^']*)'", m.group("modules")),
            "headings": int(m.group("h")), "notoffered": int(m.group("n")), "declined": int(m.group("d")),
            "packages": pk.group(1) if pk else "",
            "choice": "-ChoiceRead $true" in rest,
        }
    return gates


def driver_defined_names(script_text):
    """The variables the driver batch file sets or clears before it calls the block."""
    body = between(norm(script_text), "function New-OfferDriver", "$gateWork = ")
    if body is None:
        return None
    return set(re.findall(r'set "(\w+)=', body))


def edges_problems(text):
    """The script that runs the six edge rows keeps its rows, tags, scenarios, programs, closed input and exit codes."""
    text = norm(text)
    found = []
    live = live_ps(text)
    ids_block = between(text, "$allIds = @(\n", "\n)\n") or ""
    map_block = between(text, "$reqOf = @{\n", "\n}\n") or ""
    for row_id, tag in EDGE_ROWS:
        if len(re.findall(r"id = '%s'; req = '%s'; pass = " % (re.escape(row_id), re.escape(tag)), text)) != 1:
            found.append("%s is not written exactly once as a literal id with req '%s' at a Write-NdjsonRow call" % (row_id, tag))
        if "'%s'" % row_id not in ids_block:
            found.append("%s is not in the $allIds list of the skip path" % row_id)
        if "'%s' = '%s'" % (row_id, tag) not in map_block:
            found.append("%s has no entry '%s' in the $reqOf map of the skip path" % (row_id, tag))

    wants = (
        ("call ~driver.bat > ~driver_console.txt 2>&1 < nul", "the driver's launch file does not close standard input (< nul)"),
        ('call run_setup.bat > $consoleName 2>&1 < nul', "the bootstrap's launch file does not close standard input (< nul)"),
        ("taskkill.exe /F /T", "a run past the time limit is not stopped with taskkill /F /T"),
        ("Get-BatBlock -StartLabel ':runtime_install_offer' -EndLabel ':rti_install_one'", "the script no longer cuts the offer block between :runtime_install_offer and :rti_install_one"),
        ("'^(\\s*)choice\\s+'", "the driver no longer replaces the block's choice line with the recorded stub"),
        ("':choice_stub', '>\"%CHOICE_ARGS%\" echo %*', 'exit /b 2'", "the choice stub no longer records its arguments and answers with errorlevel 2 (a no)"),
        ("':log', 'setlocal'", "the driver has no :log stub"),
        ("':rti_row', '>>\"%RESULT%\" echo ROW=%~1'", "the driver has no :rti_row stub that records the state"),
        ("':emit_from_base64', 'copy /y \"%SCAN_MASTER%\" \"%~1\"", "the driver has no :emit_from_base64 stub that supplies the real helper"),
        ("'~runtime_missing_modules.txt'", "the driver folder gets no ~runtime_missing_modules.txt, so the block returns before it asks"),
        ('set "HP_TEST_RTM_ANSWER=Y"', "the bootstrap scenarios no longer answer yes through HP_TEST_RTM_ANSWER, so the offer is never taken"),
        ('set "HP_PVW_KNOWN_IDEMPOTENT="', "the bootstrap scenarios no longer clear HP_PVW_KNOWN_IDEMPOTENT inherited from the runner"),
        ('set "%s="' % HOOK, "the bootstrap scenarios no longer clear %s inherited from the runner" % HOOK),
        ("-ExtraSet @('set \"%s=1\"')" % HOOK, "the rebuildfailed scenario no longer sets %s" % HOOK),
        ("Get-OrderProblems $smRun.Console", "the once row no longer judges the order of the question in the real yes run"),
        ("Get-GateRow -Names @('once', 'console')", "the once row no longer uses the once and console scenarios"),
        ("Get-GateRow -Names @('system_exe', 'system_interp', 'nointerp_exe', 'fallback_exe', 'control_offered')", "the notoffered row no longer uses its five scenarios"),
        ("Get-GateRow -Names @('listing')", "the listing row no longer uses the listing scenario"),
        ("~runtime_install_edges_evidence.txt", "the evidence file the workflow uploads is no longer written"),
    )
    for needle, why in wants:
        if needle not in text:
            found.append(why)
    if "*>" in text:
        found.append("a *> redirect appears; cmd.exe has no such operator, use > file 2>&1 inside a cmd string")
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0 (last line: %r)" % (live[-1] if live else ""))
    if "if (-not $allPass) { exit 1 }" not in live:
        found.append("the script never exits 1 when a row is red")

    gates = parse_gates(text)
    for name, want in GATES.items():
        got = gates.get(name)
        if got is None:
            found.append("the gate scenario %s is missing or no longer on one New-Gate line" % name)
        elif got != want:
            found.append("the gate scenario %s differs from what its shall needs in: %s" % (name, ", ".join(k for k in want if got.get(k) != want[k])))
    for name in sorted(set(gates) - set(GATES)):
        found.append("the gate scenario %s is not one this test knows; add it to GATES with its expectation" % name)

    args = {kind: (good, ghost) for kind, good, ghost in re.findall(r"Get-RunRow -Kind '(\w+)' -Good '([^']*)' -Ghost '([^']*)'", text)}
    for kind, want in RUN_ARGS.items():
        if args.get(kind) != want:
            found.append("%s: the row judges the names %r, expected %r" % (kind, args.get(kind), want))
        if "Invoke-EdgeBootstrap -Kind '%s'" % kind not in text:
            found.append("%s: no bootstrap is started for this kind" % kind)
        code = app_code(text, kind)
        if code is None:
            found.append("the %s program is not a here-string of the script" % kind)
            continue
        try:
            compile(code, kind, "exec")
        except SyntaxError as exc:
            found.append("the %s program does not compile: %s" % (kind, exc))
            continue
        if 'importlib.import_module("".join(parts))' not in code:
            found.append("%s: the program no longer imports by a name joined at run time, so a static scan could install the package first" % kind)
        if "except ImportError" not in code or "traceback.print_exc()" not in code:
            found.append("%s: the program no longer catches its own ImportError and prints the traceback" % kind)
        if re.search(r"(?m)^\s*(import|from)\s+(xlsxwriter|pvw_)", code):
            found.append("%s: the program imports the missing module by name, which a static scan sees" % kind)
        if '"edge app ok"' not in code:
            found.append("%s: the program no longer ends by printing its marker and exiting 0" % kind)
        if program_names(code) != [n for n in want if n]:
            found.append("%s: the program asks for %r, the row judges %r" % (kind, program_names(code), [n for n in want if n]))
    return found


def skip_problems(text):
    """The skip-hook script keeps the two new rows, the rebuild scenario and its exit condition."""
    text = norm(text)
    found = []
    live = live_ps(text)
    real = (
        ("self.skiphooks.entry_only", "REQ-012.1, REQ-012.2", "$entryPass"),
        ("self.skiphooks.exe_only", "REQ-012.3, REQ-012.4", "$exePass"),
        ("self.launch.warning.throwaway", "REQ-018.5", "$warnPass"),
        ("self.skiphooks.exe_only.panel", "REQ-012.5", "$panelPass"),
    )
    for row_id, tag, var in real:
        if len(re.findall(r"id = '%s'; req = '%s'; pass = \[bool\]%s" % (re.escape(row_id), re.escape(tag), re.escape(var)), text)) != 1:
            found.append("%s is not written once as a literal id with req '%s' and pass from %s" % (row_id, tag, var))
    if len(re.findall(r"id = 'self\.launch\.warning\.throwaway'; req = 'REQ-018\.5'; pass = \$true;", text)) != 1:
        found.append("the non-Windows skip path no longer writes the throwaway row (pass true, req REQ-018.5)")
    if len(re.findall(r"id = 'self\.launch\.warning\.throwaway'; req = 'REQ-018\.5'; pass = \$false;", text)) != 1:
        found.append("the missing-batch-file path no longer writes the throwaway row (pass false, req REQ-018.5)")
    if text.count("'self.skiphooks.exe_only.panel'") < 3:
        found.append("the panel row is not in both skip-path id lists and written as a real row")
    wants = (
        ("'~hook_f3.log'", "the rebuild scenario (F3) no longer writes its own console log"),
        ("Add-Content -LiteralPath (Join-Path $dirF 'ledger_app.py')", "F3 no longer changes the program so the cached EXE is stale"),
        ("($wF1.Count -eq 1) -and $wF1.Before -and ($wF2.Count -eq 0) -and ($wF3.Count -eq 1) -and $wF3.Before", "the throwaway row no longer requires one warning before the output on a build and on a rebuild, and none on a repeat"),
        ("($linesF1.Count -eq 1) -and ($linesF2.Count -eq 2) -and ($linesF3.Count -eq 3)", "the throwaway row no longer requires exactly one verification run per build (ledger lines 1, 2, 3)"),
        ("$rebuiltF3 = $logF3 -match [regex]::Escape('Building standalone executable')", "the rebuild scenario no longer proves a rebuild happened"),
        ("function Get-WarningFacts", "Get-WarningFacts is missing"),
        ("Note: EXE verification was skipped by request (HP_SKIP_EXE_SMOKERUN).", "the panel row no longer looks for the neutral note"),
        ("SETUP COMPLETE -- WITH A CAVEAT", "the panel row no longer looks for the caveat heading"),
        ("couldn't fully verify it runs as a standalone program", "the panel row no longer looks for the caveat sentence"),
        ("BUT WE CAN'T CONFIRM", "the panel row no longer looks for the cannot-confirm heading"),
        ("$panelPass = ($exitG1 -eq 0) -and $exeG1 -and $exeSkipLogged -and $panelHeading -and $panelNote -and", "the panel row no longer requires the plain heading and the note"),
        ("(-not $caveatHeading) -and (-not $caveatSentence) -and (-not $cantConfirm)", "the panel row no longer requires the absence of the caveat"),
    )
    for needle, why in wants:
        if needle not in text:
            found.append(why)
    facts = between(text, "function Get-WarningFacts", "\nfunction Show-Evidence") or ""
    for half in ("Verifying the built standalone EXE", "do not start real work in it"):
        if half not in facts:
            found.append("Get-WarningFacts no longer looks for %r" % half)
    if "if (-not ($entryPass -and $exePass -and $warnPass -and $panelPass)) { exit 1 }" not in live:
        found.append("the script's exit 1 no longer covers all four rows")
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0 (last line: %r)" % (live[-1] if live else ""))
    if "*>" in text:
        found.append("a *> redirect appears; cmd.exe has no such operator")
    return found


def install_problems(text):
    """The accept row of the main road also names REQ-018.20, and says where the other half is."""
    found = []
    if not re.search(r"id\s+=\s+'self\.runtime\.install\.accept'\s+req\s+=\s+'REQ-018\.17, REQ-018\.20'", norm(text)):
        found.append("the accept row no longer carries req 'REQ-018.17, REQ-018.20'")
    if "self.runtime.install.stillmissing" not in text:
        found.append("the header no longer points at the row for the other half of REQ-018.20")
    return found


def hook_problems(batch_text):
    """:rti_rebuild's test hook: set, it adds an option PyInstaller rejects; absent, the command line is unchanged."""
    flat = norm(batch_text)
    body = between(flat, "\n:rti_rebuild\n", "\n:rti_add_hidden\n")
    if body is None:
        return ["the labels :rti_rebuild and :rti_add_hidden were not found in run_setup.bat"]
    live = [ln.strip() for ln in body.split("\n") if ln.strip() and not is_comment(ln)]
    cmds = [i for i, ln in enumerate(live) if "-m PyInstaller" in ln]
    if len(cmds) != 1:
        return ["expected exactly one PyInstaller command line in :rti_rebuild, found %d" % len(cmds)]
    ci = cmds[0]
    found = []
    sets = [i for i, ln in enumerate(live) if ln == 'if defined %s set "%s=%s"' % (HOOK, BAD_VAR, BAD_OPTION)]
    clears = [i for i, ln in enumerate(live) if ln == 'set "%s="' % BAD_VAR]
    if len(sets) != 1:
        found.append("the invalid option is not set by exactly one line guarded by %s (found %d)" % (HOOK, len(sets)))
    if not any(i < ci for i in clears):
        found.append("%s is not cleared before the hook may set it, so a value from the calling terminal would break a real rebuild" % BAD_VAR)
    if not any(i > ci for i in clears):
        found.append("%s is not cleared after the command, so a later rebuild in the same run would inherit it" % BAD_VAR)
    before = [i for i in clears if i < ci]
    if sets and before and not (max(before) < sets[0] < ci):
        found.append("the hook's set line does not sit between the clear and the PyInstaller command")
    cmd = live[ci]
    if cmd.count("%" + BAD_VAR + "%") != 1:
        found.append("the PyInstaller command does not carry %%%s%% exactly once" % BAD_VAR)
    elif "%HP_PYI_HID_COLLECT% %" + BAD_VAR + '% --name "%ENVNAME%"' not in cmd:
        found.append("%%%s%% is not between the accumulated flags and --name, so it would be read as part of the program path" % BAD_VAR)
    if not any(ln.startswith("if defined %s call :log" % HOOK) and "[TEST] %s" % HOOK in ln for ln in live):
        found.append("the hook does not log a [TEST] line when it is set, so the failure it makes looks like a real one")
    return found


def offer_problems(batch_text, driver_names):
    """:runtime_install_offer up to :rti_install_one can be cut out and run by the driver, and keeps the shape the shalls need."""
    lines = lines_of(batch_text)
    starts = [i for i, ln in enumerate(lines) if ln.strip() == ":runtime_install_offer"]
    ends = [i for i, ln in enumerate(lines) if ln.strip() == ":rti_install_one"]
    if len(starts) != 1 or len(ends) != 1 or not starts[0] < ends[0]:
        return ["the labels :runtime_install_offer and :rti_install_one must each exist once, in that order (the script cuts the block between them)"]
    if driver_names is None:
        return ["the driver function New-OfferDriver was not found in the script"]
    block = lines[starts[0] + 1:ends[0]]
    live = [ln.strip() for ln in block if ln.strip() and not is_comment(ln)]
    found = []

    # the driver can run it: every label it jumps to is inside the cut, every call is a stub or a yes-only step
    labels = {m.group(1) for m in (re.match(r"^:(\w+)\s*$", ln) for ln in live) if m}
    for ln in live:
        for target in re.findall(r"(?i)\bgoto\s+:(\w+)", ln):
            if target.lower() != "eof" and target not in labels:
                found.append("the block jumps to :%s, which is outside the cut the driver runs: %s" % (target, ln[:70]))
        for called in re.findall(r"(?i)\bcall\s+:(\w+)", ln):
            if called not in ALLOWED_CALLS:
                found.append("the block calls :%s, which the driver does not define: %s" % (called, ln[:70]))
    # variables the block reads are set by it or defined/cleared by the driver
    set_names = set(re.findall(r'(?i)\bset\s+"?(\w+)=', "\n".join(live)))
    reads, tested = set(), set()
    for ln in live:
        stripped = ln.replace("%%", "")
        reads.update(re.findall(r"%([A-Za-z_]\w*)(?::[^%]*)?%", stripped))
        tested.update(re.findall(r"(?i)\bif\s+(?:not\s+)?defined\s+(\w+)", stripped))
    for name in sorted(reads | tested):
        if name not in set_names and name not in driver_names:
            found.append("the block reads %s, which neither it nor the driver sets or clears" % name)

    def index_of(needle):
        hits = [i for i, ln in enumerate(live) if ln == needle]
        return hits[0] if len(hits) == 1 else None

    # asked once per invocation: the first guard, the offered flag set before the question, and no path into a yes but one
    if not live or live[0] != "if defined HP_RTI_OFFERED exit /b 0":
        found.append("the first line of the block is no longer the once-per-bootstrap guard 'if defined HP_RTI_OFFERED exit /b 0'")
    heading = next((i for i, ln in enumerate(live) if ln.startswith("echo") and "Your program asked for packages that are not installed:" in ln), None)
    offered = [i for i, ln in enumerate(live) if ln == 'set "HP_RTI_OFFERED=1"']
    if heading is None:
        found.append("the question's heading is no longer an echo line of the block")
    elif len(offered) < 2 or offered[0] > heading:
        found.append("HP_RTI_OFFERED is not set before the question is printed (and again where the offer is not made), so a second call could ask again")
    accepted = [i for i, ln in enumerate(live) if ln == 'if /I "%HP_RTI_CHOICE%"=="Y" goto :rti_accepted']
    if len(accepted) != 1 or sum(1 for ln in live if re.search(r"(?i)\bgoto\s+:rti_accepted\b", ln)) != 1:
        found.append("the only way into :rti_accepted must be the single line that tests HP_RTI_CHOICE for Y")
    label_at = next((i for i, ln in enumerate(live) if ln == ":rti_accepted"), None)
    for called in YES_ONLY_CALLS:
        for i, ln in enumerate(live):
            if re.search(r"(?i)\bcall\s+:%s\b" % called, ln) and (label_at is None or i < label_at):
                found.append("the block calls :%s before :rti_accepted, so a no could reach it: %s" % (called, ln[:70]))

    # the gate: test answer, then the three signals, then the console; each signal declines without reading
    order = []
    for key, needle in (("test answer", "if defined HP_TEST_RTM_ANSWER goto :rti_gate_override"), ("HP_CI_LANE", "if defined HP_CI_LANE goto :rti_gate_decline"),
                        ("NOINPUT", "if defined NOINPUT goto :rti_gate_decline"), ("HP_NONINTERACTIVE", "if defined HP_NONINTERACTIVE goto :rti_gate_decline"),
                        ("console", "goto :rti_gate_interactive")):
        at = index_of(needle)
        if at is None:
            found.append("the gate line for %s is missing or appears more than once: %s" % (key, needle))
        order.append(at)
    if None not in order and order != sorted(order):
        found.append("the gate lines are not in the order test answer, HP_CI_LANE, NOINPUT, HP_NONINTERACTIVE, console")
    if heading is not None and order and order[0] is not None and heading > order[0]:
        found.append("the question is printed after the gate that may answer it")

    # the console read: one choice line, bounded by 30 seconds and defaulting to N, with a way out for a missing choice.exe
    choices = [i for i, ln in enumerate(live) if re.match(r"(?i)choice\s", ln)]
    if len(choices) != 1:
        found.append("expected exactly one live choice line in the block, found %d (the driver replaces that one line)" % len(choices))
    else:
        ln = live[choices[0]]
        for pattern, why in ((r"(?i)/C\s+YN(\s|$)", "offer exactly Y and N (/C YN)"), (r"(?i)/T\s+30(\s|$)", "wait 30 seconds (/T 30)"),
                             (r"(?i)/D\s+N(\s|$)", "default to N after the wait (/D N)")):
            if not re.search(pattern, ln):
                found.append("the console choice line does not %s: %s" % (why, ln[:90]))
        interactive = next((i for i, x in enumerate(live) if x == ":rti_gate_interactive"), None)
        where = next((i for i, x in enumerate(live) if x.startswith("where choice")), None)
        if interactive is None or where is None or not interactive < where < choices[0]:
            found.append("the choice line does not come after :rti_gate_interactive and the 'where choice' check")
        resolve = next((i for i, x in enumerate(live) if x == ":rti_gate_resolve"), len(live))
        if not any(x == "if errorlevel 2 goto :rti_gate_decline" for x in live[choices[0] + 1:resolve]):
            found.append("a no from the choice line (errorlevel 2) no longer goes to the decline label")

    # which providers are offered; the not-offered and declined paths
    offered_modes = set(re.findall(r'if /I "%HP_ENV_MODE%"=="(\w+)" set "HP_RTI_PROVIDER_OK=1"', "\n".join(live)))
    if offered_modes != PROVIDERS_OFFERED:
        found.append("the block offers providers %s, expected %s (a system Python and no provider are not offered)" % (sorted(offered_modes), sorted(PROVIDERS_OFFERED)))
    for needle in ("if not defined HP_RTI_PROVIDER_OK goto :rti_not_offered",
                   'if /I "%HP_RTI_SITE%"=="exe" if defined HP_NUITKA_FALLBACK_USED goto :rti_not_offered'):
        if index_of(needle) is None:
            found.append("the not-offered line is missing or appears more than once: %s" % needle)
    at = next((i for i, x in enumerate(live) if x == ":rti_not_offered"), None)
    if at is None or live[at + 1:at + 5] != ['set "HP_RTI_OFFERED=1"', 'call :log "[INFO] Runtime install: not offered for this build or provider."',
                                             "call :rti_row not_offered", "exit /b 0"]:
        found.append(":rti_not_offered no longer sets the flag, logs the not-offered line, records not_offered and returns")
    at = next((i for i, x in enumerate(live) if x == ":rti_gate_resolve"), None)
    if at is None or live[at + 1:at + 5] != ['if /I "%HP_RTI_CHOICE%"=="Y" goto :rti_accepted', 'call :log "[INFO] Runtime install: declined. Nothing was changed."',
                                             "call :rti_row declined", "goto :rti_cleanup"]:
        found.append(":rti_gate_resolve no longer sends only a yes on, and logs and records every other answer as declined")
    return found


def text_problems(batch_text, edges_text):
    """The texts the judging looks for are written by live lines of the batch and are in the script."""
    found = []
    live = [ln for ln in lines_of(batch_text) if not is_comment(ln) and ("call :log" in ln or ln.lstrip().lower().startswith("echo")
                                                                         or re.search(r"(?i)\bdo echo\b", ln) or "echo " in ln)]
    for needle in BATCH_TEXTS:
        if not any(needle in ln for ln in live):
            found.append("no live 'call :log' or echo line of run_setup.bat holds %r, so the script's judging of it can never be met" % needle)
    for needle in SCRIPT_TEXTS:
        if needle not in edges_text:
            found.append("the edge script no longer looks for %r" % needle)
    return found


def warning_batch_problems(batch_text):
    """The throwaway warning and the post-flight panel are still written the way the two rows read them."""
    found = []
    live = [ln for ln in lines_of(batch_text) if not is_comment(ln)]
    variants = [ln for ln in live if "call :log" in ln and "Verifying the built standalone EXE" in ln]
    if len(variants) != 4:
        found.append("expected the four wordings of the verification warning, found %d" % len(variants))
    for ln in variants:
        if "do not start real work in it" not in ln:
            found.append("a verification warning no longer says not to start real work in it: %s" % ln.strip()[:90])
    if not any("(PyInstaller)" in ln and "if it stays completely silent" in ln for ln in variants):
        found.append("the wording that the EXE verification run (the main caller) prints is gone")
    for needle in ("echo    Note: EXE verification was skipped by request (HP_SKIP_EXE_SMOKERUN).", "echo  SETUP COMPLETE -- WITH A CAVEAT",
                   "echo  We packaged your app, but couldn't fully verify it runs as a", "echo  standalone program. Your Python environment was set up and the",
                   "echo  SETUP COMPLETE -- BUT WE CAN'T CONFIRM YOUR LAST RUN WORKED"):
        if not any(needle in ln for ln in live):
            found.append("no live line of run_setup.bat holds %r" % needle)
    return found


def workflow_problems(text):
    flat = norm(text)
    found = []
    lines = flat.split("\n")
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    block = None
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        chunk = "\n".join(lines[start:end])
        if "selfapps_runtime_install_edges.ps1" in chunk:
            block = chunk
            break
    if block is None:
        return ["no step runs tests\\selfapps_runtime_install_edges.ps1"]
    if EDGES_STEP_IF not in block:
        found.append("the step is not limited to the contract-uv lane with !cancelled()")
    if "shell: pwsh" not in block:
        found.append("the step does not use shell: pwsh")
    if "continue-on-error" in block:
        found.append("the step has continue-on-error, so it cannot hold a pull request")
    for pattern in EDGES_UPLOADS:
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
            ids.add(ln.strip())
    return ids


def registry_problems(text):
    registered = registry_ids(text)
    return ["%s is not in docs/agent-ndjson.md" % row_id for row_id in ALL_NEW_IDS if row_id not in registered]


def shall_entry_problems(text):
    keys = set(re.findall(r'(?m)^\s+"(REQ-\d{3}[a-z]?\.\d+(?:\.\d+)*)":', text))
    return ["tests/test_req_shall_trace.py still lists %s as an untraced shall although a row now carries its tag" % k for k in SHALL_ENTRIES if k in keys]


# --- the scripts' own judging functions, run through a real pwsh ---

DRIVER = r"""
$ErrorActionPreference = 'Stop'
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:ER_SCRIPT, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) { throw ('parse errors: ' + $errs[0].Message) }
$want = @($env:ER_WANT -split ',')
$defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)
if (@($defs).Count -ne $want.Count) { throw 'a judging function is missing from the script' }
foreach ($f in $defs) { Invoke-Expression $f.Extent.Text }
$cases = Get-Content -LiteralPath $env:ER_CASES -Raw | ConvertFrom-Json
$all = New-Object System.Collections.ArrayList
foreach ($c in $cases) {
    $h = @{}
    foreach ($p in $c.args.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $r = @(& $c.fn @h)
    if ($r.Count -eq 1 -and ($r[0].PSObject.TypeNames -contains 'System.Management.Automation.PSCustomObject')) { $res = $r[0] } else { $res = $r }
    [void]$all.Add([ordered]@{ name = $c.name; result = $res })
}
ConvertTo-Json -InputObject @($all) -Compress -Depth 8
"""


def run_cases(script, want, cases, tmp):
    """Run the named functions of a script on the cases; returns {case name: result}."""
    tmp = Path(tmp)
    cases_file = tmp / "cases.json"
    cases_file.write_text(json.dumps(cases), encoding="ascii")
    driver = tmp / "driver.ps1"
    driver.write_text(DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["ER_SCRIPT"] = str(script)
    env["ER_WANT"] = ",".join(want)
    env["ER_CASES"] = str(cases_file)
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(driver)], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return {item["name"]: item["result"] for item in json.loads(proc.stdout)}


HEADING = "*** Your program asked for packages that are not installed: ***"
QUESTION = "*** Install them now? That adds them to this program's own environment and to requirements.txt. ***"
CHOICE_OK = '/C YN /N /T 30 /D N /M "  Install and check? [Y/N, defaults to N after 30s] "'


def console(*packages, headings=1):
    one = "\n".join(["", HEADING] + ["***   %s" % p for p in packages] + [QUESTION, "*** It rebuilds the EXE if there is one, and runs your program one more time to check. ***", ""])
    return one * headings


def result(*lines):
    return "\n".join(("START",) + lines + ("END",)) + "\n"


def drop(text, needle):
    """The text without the lines that hold the needle; a case that drops nothing is a mistake in the case."""
    kept = [ln for ln in text.split("\n") if needle not in ln]
    assert len(kept) < len(text.split("\n")), "case builder: no line holds " + needle
    return "\n".join(kept)


RES_DECLINED = result("ROW=declined", "CALL1 site=exe offered=1")
RES_ONCE = result("ROW=declined", "CALL1 site=exe offered=1", "CALL2 site=interpreter offered=1")
RES_NOT = result("ROW=not_offered", "CALL1 site=exe offered=1")
LOG_DECLINED = "[INFO] Runtime install: declined. Nothing was changed.\n"
LOG_NOT = "[INFO] Runtime install: not offered for this build or provider.\n"


def gate(name, **over):
    args = {"Name": "x", "Finished": True, "Result": RES_DECLINED, "Log": LOG_DECLINED, "Console": console("xlsxwriter"),
            "ChoiceArgs": "", "Headings": 1, "NotOffered": 0, "Declined": 1, "Calls": 1, "Packages": "", "ChoiceRead": False}
    args.update(over)
    return {"name": name, "fn": "Get-GateProblems", "args": args}


SM_SETUP = "\n".join((
    "[WARN] Your program needed the module xlsxwriter while it was running, and that module is not installed.",
    "[WARN] Your program needed the module pvw_still_missing_ while it was running, and that module is not installed.",
    "[INFO] Runtime install: accepted.",
    "[INFO] Runtime install: installing xlsxwriter into the uv environment.",
    "[INFO] Runtime install: installed xlsxwriter.",
    "[INFO] Runtime install: installing pvw_still_missing_ into the uv environment.",
    "[WARN] Runtime install: could not install pvw_still_missing_.",
    "[INFO] Runtime install: added xlsxwriter to requirements.txt.",
    "[INFO] Runtime install: rebuilding the standalone EXE with the new packages. This may take a minute or two...",
    "[REPAIR] rebuild complete after runtime install.",
    "[INFO] Runtime install: running your program once more to check.",
    "[INFO] Entry smoke exit=0",
    "[WARN] Runtime install: the program still reports a missing module after the install.",
))
SM_ERR = "Traceback (most recent call last):\nModuleNotFoundError: No module named 'pvw_still_missing_'\n"
FD_SETUP = "\n".join((
    "[WARN] Your program needed the module pvw_ghost_pkg_ while it was running, and that module is not installed.",
    "[INFO] Runtime install: accepted.",
    "[INFO] Runtime install: installing pvw_ghost_pkg_ into the uv environment.",
    "[WARN] Runtime install: could not install pvw_ghost_pkg_.",
    "[WARN] Runtime install: no package could be installed. Nothing else was changed.",
))
RB_SETUP = "\n".join((
    "[WARN] Your program needed the module xlsxwriter while it was running, and that module is not installed.",
    "[INFO] Runtime install: accepted.",
    "[INFO] Runtime install: installing xlsxwriter into the uv environment.",
    "[INFO] Runtime install: installed xlsxwriter.",
    "[INFO] Runtime install: added xlsxwriter to requirements.txt.",
    "[INFO] Runtime install: rebuilding the standalone EXE with the new packages. This may take a minute or two...",
    "[TEST] HP_TEST_FORCE_RTI_REBUILD_FAIL: the rebuild command gets an option PyInstaller rejects.",
    "[ERROR] Runtime install: the rebuild failed, so the standalone EXE may not include the new packages.",
))
GOOD_RUN = {
    "stillmissing": {"Kind": "stillmissing", "Good": "xlsxwriter", "Ghost": "pvw_still_missing_", "Finished": True,
                     "Console": console("pvw_still_missing_", "xlsxwriter"), "Setup": SM_SETUP, "ErrText": SM_ERR,
                     "ReqText": "xlsxwriter\r\n", "RowState": "still_missing", "RowSite": "exe", "SmokeRuns": 2, "EnvHasGood": True},
    "failed": {"Kind": "failed", "Good": "", "Ghost": "pvw_ghost_pkg_", "Finished": True, "Console": console("pvw_ghost_pkg_"),
               "Setup": FD_SETUP, "ErrText": "", "ReqText": "", "RowState": "install_failed", "RowSite": "exe", "SmokeRuns": 1, "EnvHasGood": False},
    "rebuildfailed": {"Kind": "rebuildfailed", "Good": "xlsxwriter", "Ghost": "", "Finished": True, "Console": console("xlsxwriter"),
                      "Setup": RB_SETUP, "ErrText": "", "ReqText": "xlsxwriter\n", "RowState": "rebuild_failed", "RowSite": "exe",
                      "SmokeRuns": 1, "EnvHasGood": True},
}


def run_case(name, kind, **over):
    args = dict(GOOD_RUN[kind])
    args.update(over)
    return {"name": name, "fn": "Get-RunProblems", "args": args}


ORDER_OK = "\n".join((HEADING, "***   xlsxwriter", QUESTION, "[INFO] Runtime install: accepted.", "[INFO] Runtime install: installing xlsxwriter into the uv environment.",
                      "[INFO] Runtime install: added xlsxwriter to requirements.txt.", "[INFO] Runtime install: rebuilding the standalone EXE with the new packages.", ""))
EDGE_CASES = [
    # one driver run of the real block
    gate("gate_ok_declined"),
    gate("gate_ok_once", Result=RES_ONCE, Calls=2),
    gate("gate_ok_notoffered", Result=RES_NOT, Log=LOG_NOT, Console="", Headings=0, NotOffered=1, Declined=0),
    gate("gate_ok_console", ChoiceArgs=CHOICE_OK, ChoiceRead=True),
    gate("gate_ok_listing", Console=console("pvw_listing_other_", "pillow", "opencv-python"), Packages="opencv-python|pillow|pvw_listing_other_"),
    gate("gate_unfinished", Finished=False),
    gate("gate_no_end", Result="START\nCALL1 site=exe offered=1\nROW=declined\n"),
    # the two comparisons the first version of the script could never fail (a local named like its parameter)
    gate("gate_calls_mismatch", Calls=2),
    gate("gate_headings_mismatch", Console=console("xlsxwriter", headings=2)),
    gate("gate_notoffered_log_missing", Result=RES_NOT, Log="", Console="", Headings=0, NotOffered=1, Declined=0),
    gate("gate_notoffered_row_missing", Result=result("CALL1 site=exe offered=1"), Log=LOG_NOT, Console="", Headings=0, NotOffered=1, Declined=0),
    gate("gate_offered_when_it_should_not", Headings=0, NotOffered=1, Declined=0),
    gate("gate_extra_row", Result=result("ROW=declined", "ROW=verified", "CALL1 site=exe offered=1")),
    gate("gate_declined_log_missing", Log=""),
    gate("gate_declined_row_missing", Result=result("CALL1 site=exe offered=1")),
    gate("gate_choice_not_read", ChoiceRead=True),
    gate("gate_choice_no_t30", ChoiceArgs='/C YN /N /D N /M "x"', ChoiceRead=True),
    gate("gate_choice_t300", ChoiceArgs='/C YN /N /T 300 /D N /M "x"', ChoiceRead=True),
    gate("gate_choice_default_y", ChoiceArgs='/C YN /N /T 30 /D Y /M "x"', ChoiceRead=True),
    gate("gate_choice_other_keys", ChoiceArgs='/C YNA /N /T 30 /D N /M "x"', ChoiceRead=True),
    gate("gate_choice_read_but_decided", ChoiceArgs=CHOICE_OK, ChoiceRead=False),
    gate("gate_pkg_mismatch", Console=console("opencv-python"), Packages="opencv-python|pillow"),
    gate("gate_pkg_no_heading", Result=result("CALL1 site=exe offered=1"), Log="", Console="", Headings=0, NotOffered=0, Declined=0, Packages="xlsxwriter"),
    # the packages the prompt lists
    {"name": "pp_sorted", "fn": "Get-PromptPackages", "args": {"Console": console("pvw_listing_other_", "pillow", "opencv-python")}},
    {"name": "pp_no_heading", "fn": "Get-PromptPackages", "args": {"Console": "***   xlsxwriter\n" + QUESTION + "\n"}},
    {"name": "pp_no_question", "fn": "Get-PromptPackages", "args": {"Console": HEADING + "\n***   xlsxwriter\n"}},
    {"name": "pp_noise", "fn": "Get-PromptPackages",
     "args": {"Console": "\n".join((HEADING, "***   good", "***   two words", "**   short", "*** a ***", "***  one space less", QUESTION, "***   late", ""))}},
    # the order of the question and the changes, in a real yes run
    {"name": "order_ok", "fn": "Get-OrderProblems", "args": {"Console": ORDER_OK}},
    {"name": "order_heading_twice", "fn": "Get-OrderProblems", "args": {"Console": ORDER_OK + ORDER_OK}},
    {"name": "order_no_heading", "fn": "Get-OrderProblems", "args": {"Console": drop(ORDER_OK, "asked for packages")}},
    {"name": "order_install_first", "fn": "Get-OrderProblems",
     "args": {"Console": "[INFO] Runtime install: installing xlsxwriter into the uv environment.\n" + HEADING + "\n"
                          "[INFO] Runtime install: added xlsxwriter to requirements.txt.\n[INFO] Runtime install: rebuilding the standalone EXE\n"}},
    {"name": "order_edit_first", "fn": "Get-OrderProblems",
     "args": {"Console": "[INFO] Runtime install: added xlsxwriter to requirements.txt.\n" + HEADING + "\n"
                          "[INFO] Runtime install: installing xlsxwriter\n[INFO] Runtime install: rebuilding the standalone EXE\n"}},
    {"name": "order_rebuild_first", "fn": "Get-OrderProblems",
     "args": {"Console": "[INFO] Runtime install: rebuilding the standalone EXE\n" + HEADING + "\n"
                          "[INFO] Runtime install: installing xlsxwriter\n[INFO] Runtime install: added xlsxwriter to requirements.txt.\n"}},
    {"name": "order_nothing_installs", "fn": "Get-OrderProblems", "args": {"Console": drop(ORDER_OK, "installing")}},
    {"name": "order_no_edit", "fn": "Get-OrderProblems", "args": {"Console": drop(ORDER_OK, "added xlsxwriter")}},
    {"name": "order_no_rebuild", "fn": "Get-OrderProblems", "args": {"Console": drop(ORDER_OK, "rebuilding")}},
    # one real bootstrap per kind
    run_case("sm_ok", "stillmissing"),
    run_case("sm_unfinished", "stillmissing", Finished=False),
    run_case("sm_first_run_names_nothing", "stillmissing", Setup=drop(SM_SETUP, "needed the module pvw_still_missing_")),
    run_case("sm_question_lists_one", "stillmissing", Console=console("xlsxwriter")),
    run_case("sm_not_accepted", "stillmissing", Setup=drop(SM_SETUP, "Runtime install: accepted.")),
    run_case("sm_cascade_started", "stillmissing", Setup=SM_SETUP + "\n[INFO] REQ-009: cascading provider uv to conda; re-attempting dependencies."),
    run_case("sm_cascade_approved", "stillmissing", Setup=SM_SETUP + "\n[INFO] Last chance: cascade approved; will re-attempt under the next provider tier, conda."),
    run_case("sm_not_installed_line", "stillmissing", Setup=drop(SM_SETUP, "installed xlsxwriter.")),
    run_case("sm_no_edit_line", "stillmissing", Setup=drop(SM_SETUP, "added xlsxwriter")),
    run_case("sm_requirements_lacks_it", "stillmissing", ReqText=""),
    run_case("sm_requirements_holds_ghost", "stillmissing", ReqText="xlsxwriter\npvw_still_missing_\n"),
    run_case("sm_env_lacks_it", "stillmissing", EnvHasGood=False),
    run_case("sm_ghost_install_not_reported", "stillmissing", Setup=drop(SM_SETUP, "could not install pvw_still_missing_")),
    run_case("sm_not_rebuilt", "stillmissing", Setup=drop(SM_SETUP, "rebuild complete")),
    run_case("sm_no_check_run", "stillmissing", Setup=drop(SM_SETUP, "running your program once more")),
    run_case("sm_no_still_missing_line", "stillmissing", Setup=drop(SM_SETUP, "still reports a missing module")),
    run_case("sm_says_verified", "stillmissing", Setup=SM_SETUP + "\n[INFO] Runtime install: verified. The program no longer reports a missing module."),
    run_case("sm_wrong_state", "stillmissing", RowState="verified"),
    run_case("sm_wrong_site", "stillmissing", RowSite="interpreter"),
    run_case("sm_one_run_only", "stillmissing", SmokeRuns=1),
    run_case("sm_check_run_error_lacks_ghost", "stillmissing", ErrText=""),
    run_case("sm_check_run_misses_good", "stillmissing", ErrText=SM_ERR + "ModuleNotFoundError: No module named 'xlsxwriter'\n"),
    run_case("fd_ok", "failed"),
    run_case("fd_unfinished", "failed", Finished=False),
    run_case("fd_rebuilt", "failed", Setup=FD_SETUP + "\n[INFO] Runtime install: rebuilding the standalone EXE with the new packages."),
    run_case("fd_ran_again", "failed", Setup=FD_SETUP + "\n[INFO] Runtime install: running your program once more to check."),
    run_case("fd_two_runs", "failed", SmokeRuns=2),
    run_case("fd_wrong_state", "failed", RowState="declined"),
    run_case("fd_no_stop_line", "failed", Setup=drop(FD_SETUP, "no package could be installed")),
    run_case("fd_ghost_in_requirements", "failed", ReqText="pvw_ghost_pkg_\n"),
    run_case("fd_cascade", "failed", Setup=FD_SETUP + "\n[INFO] REQ-009: cascade consent: accepted."),
    run_case("rb_ok", "rebuildfailed"),
    run_case("rb_unfinished", "rebuildfailed", Finished=False),
    run_case("rb_hook_not_shown", "rebuildfailed", Setup=drop(RB_SETUP, "HP_TEST_FORCE_RTI_REBUILD_FAIL")),
    run_case("rb_no_rebuild_line", "rebuildfailed", Setup=drop(RB_SETUP, "rebuilding the standalone EXE")),
    run_case("rb_failure_not_reported", "rebuildfailed", Setup=drop(RB_SETUP, "the rebuild failed")),
    run_case("rb_rebuild_completed", "rebuildfailed", Setup=RB_SETUP + "\n[REPAIR] rebuild complete after runtime install."),
    run_case("rb_checked_after", "rebuildfailed", Setup=RB_SETUP + "\n[INFO] Runtime install: running your program once more to check."),
    run_case("rb_wrong_state", "rebuildfailed", RowState="verified"),
    run_case("rb_two_runs", "rebuildfailed", SmokeRuns=2),
    run_case("unknown_kind", "failed", Kind="other"),
    # the excerpt
    {"name": "excerpt", "fn": "Get-Excerpt",
     "args": {"Text": "[INFO] Runtime install: accepted.\n[INFO] unrelated\n[WARN] Runtime install: caf\u00e9 failed\n" + "[INFO] Runtime install: long " + "x" * 300 + "\n",
              "Pattern": "Runtime install"}},
    {"name": "excerpt_max", "fn": "Get-Excerpt", "args": {"Text": "Runtime install a\nRuntime install b\nRuntime install c\n", "Pattern": "Runtime install", "Max": 2}},
    {"name": "count", "fn": "Get-Count", "args": {"Text": "ab ab\nab", "Pattern": "ab"}},
]

WARN_OK = "\n".join((
    "2026-11-07 10:00:00 [INFO] Building standalone executable",
    "2026-11-07 10:00:01 [WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent for about 30 seconds it will be "
    "force-stopped. Either way, do not start real work in it yet or any unsaved work will be lost.",
    "ledger-ok",
    "2026-11-07 10:00:05 [INFO] Entry smoke exit=0",
))
WARN_CASES = [
    {"name": "warn_ok", "fn": "Get-WarningFacts", "args": {"Log": WARN_OK, "Marker": "ledger-ok"}},
    {"name": "warn_crlf", "fn": "Get-WarningFacts", "args": {"Log": WARN_OK.replace("\n", "\r\n"), "Marker": "ledger-ok"}},
    {"name": "warn_after_output", "fn": "Get-WarningFacts",
     "args": {"Log": "\n".join(("ledger-ok", WARN_OK.split("\n")[1])), "Marker": "ledger-ok"}},
    {"name": "warn_missing", "fn": "Get-WarningFacts", "args": {"Log": drop(WARN_OK, "Verifying the built"), "Marker": "ledger-ok"}},
    {"name": "warn_twice", "fn": "Get-WarningFacts", "args": {"Log": WARN_OK + "\n" + WARN_OK.split("\n")[1], "Marker": "ledger-ok"}},
    {"name": "warn_first_half_only", "fn": "Get-WarningFacts",
     "args": {"Log": WARN_OK.replace("do not start real work in it", "wait"), "Marker": "ledger-ok"}},
    {"name": "warn_second_half_only", "fn": "Get-WarningFacts",
     "args": {"Log": WARN_OK.replace("Verifying the built standalone EXE", "Checking the built program"), "Marker": "ledger-ok"}},
    {"name": "warn_no_output", "fn": "Get-WarningFacts", "args": {"Log": drop(WARN_OK, "ledger-ok"), "Marker": "ledger-ok"}},
]


class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.edges = EDGES.read_text(encoding="utf-8")
        self.skip = SKIP.read_text(encoding="utf-8")
        self.install = INSTALL.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_edge_script_has_its_rows_scenarios_programs_and_exit_codes(self):
        self.assertEqual(edges_problems(self.edges), [])

    def test_the_skip_hook_script_has_its_two_new_rows_the_rebuild_scenario_and_its_exit_code(self):
        self.assertEqual(skip_problems(self.skip), [])

    def test_the_accept_row_of_the_main_road_also_names_the_check_run_shall(self):
        self.assertEqual(install_problems(self.install), [])

    def test_the_rebuild_test_hook_leaves_the_real_command_line_alone(self):
        self.assertEqual(hook_problems(self.batch), [])

    def test_the_offer_block_can_be_cut_out_and_keeps_the_shape_the_shalls_need(self):
        self.assertEqual(offer_problems(self.batch, driver_defined_names(self.edges)), [])

    def test_the_texts_the_judging_looks_for_are_written_by_live_lines(self):
        self.assertEqual(text_problems(self.batch, self.edges), [])

    def test_the_throwaway_warning_and_the_panel_are_written_the_way_the_rows_read_them(self):
        self.assertEqual(warning_batch_problems(self.batch), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_shall_gap_entries_are_gone(self):
        self.assertEqual(shall_entry_problems(SHALL_TEST.read_text(encoding="utf-8")), [])

    def test_the_new_files_are_ascii(self):
        for path in (EDGES, SKIP, INSTALL, Path(__file__)):
            path.read_bytes().decode("ascii")

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        lines = lines_of(self.batch)
        start = next(i for i, ln in enumerate(lines) if ln.strip() == ":runtime_install_offer")
        end = next(i for i, ln in enumerate(lines) if ln.strip() == ":rti_install_one")
        self.assertGreater(end - start, 60, "the cut block is suspiciously short")
        self.assertGreaterEqual(len(parse_gates(self.edges)), 8)
        self.assertGreater(len(driver_defined_names(self.edges)), 10)
        for kind in RUN_ARGS:
            self.assertIsNotNone(app_code(self.edges, kind), kind)


@unittest.skipUnless(PWSH, "pwsh not available")
class EdgeJudgingFunctions(unittest.TestCase):
    """The edge script's pure functions, run in a real pwsh on synthetic runs: a red row must be able to appear."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as tmp:
            cls.r = run_cases(EDGES, ("Get-Count", "Get-Excerpt", "Get-PromptPackages", "Get-GateProblems", "Get-OrderProblems", "Get-RunProblems"),
                              EDGE_CASES, tmp)

    def has(self, case, *words):
        problems = self.r[case]
        self.assertTrue(any(all(w in p for w in words) for p in problems), "%s: expected a problem holding %r, got %r" % (case, words, problems))

    def test_a_run_that_shows_what_the_scenario_expects_has_no_problems(self):
        for case in ("gate_ok_declined", "gate_ok_once", "gate_ok_notoffered", "gate_ok_console", "gate_ok_listing"):
            self.assertEqual(self.r[case], [], case)

    def test_a_driver_that_hangs_or_ends_early_is_one_problem_and_nothing_else(self):
        self.assertEqual(len(self.r["gate_unfinished"]), 1)
        self.assertIn("did not finish within the time limit", self.r["gate_unfinished"][0])
        self.assertEqual(len(self.r["gate_no_end"]), 1)
        self.assertIn("did not reach its end", self.r["gate_no_end"][0])

    def test_a_wrong_number_of_calls_or_headings_is_a_problem(self):
        # the first version of the script overwrote its parameters with these counts, so neither comparison could ever fail
        self.has("gate_calls_mismatch", "made 1 call(s) of the block, expected 2")
        self.has("gate_headings_mismatch", "heading was printed 2 time(s), expected 1")

    def test_a_not_offered_state_needs_the_log_line_and_the_row_state(self):
        self.has("gate_notoffered_log_missing", "the log says the offer was not made 0 time(s), expected 1")
        self.has("gate_notoffered_row_missing", "not_offered was recorded 0 time(s), expected 1")
        self.has("gate_offered_when_it_should_not", "expected 1")

    def test_a_declined_state_needs_the_log_line_and_the_row_state(self):
        self.has("gate_declined_log_missing", "the log says the offer was declined 0 time(s), expected 1")
        self.has("gate_declined_row_missing", "declined was recorded 0 time(s), expected 1")

    def test_a_block_that_goes_somewhere_else_records_an_extra_state(self):
        self.has("gate_extra_row", "2 row state(s) were recorded, expected 1")

    def test_the_console_branch_must_reach_a_choice_line_that_waits_30_seconds_and_defaults_to_no(self):
        self.has("gate_choice_not_read", "never reached its choice line")
        self.has("gate_choice_no_t30", "/T 30")
        self.has("gate_choice_t300", "/T 30")
        self.has("gate_choice_default_y", "/D N")
        self.has("gate_choice_other_keys", "/C YN")
        self.has("gate_choice_read_but_decided", "the console was read")

    def test_the_package_list_must_match_and_a_prompt_without_a_heading_lists_nothing(self):
        self.has("gate_pkg_mismatch", "the prompt lists [opencv-python], expected [opencv-python, pillow]")
        self.has("gate_pkg_no_heading", "the prompt lists [], expected [xlsxwriter]")
        self.assertEqual(self.r["pp_sorted"], ["opencv-python", "pillow", "pvw_listing_other_"])
        self.assertEqual(self.r["pp_no_heading"], [])
        self.assertEqual(self.r["pp_no_question"], [])
        self.assertEqual(self.r["pp_noise"], ["good"], "only a line with exactly three spaces and one name, before the question, is a package")

    def test_the_question_must_come_once_and_before_every_change(self):
        self.assertEqual(self.r["order_ok"], [])
        self.has("order_heading_twice", "printed 2 time(s) in the whole run, expected once")
        self.has("order_no_heading", "printed 0 time(s)")
        self.has("order_install_first", "a package was installed before the question was asked")
        self.has("order_edit_first", "requirements.txt was edited before the question was asked")
        self.has("order_rebuild_first", "the EXE was rebuilt before the question was asked")
        self.has("order_nothing_installs", "never says it installs a package")
        self.has("order_no_edit", "never says it adds a package to requirements.txt")
        self.has("order_no_rebuild", "never says it rebuilds the EXE")

    def test_a_bootstrap_that_shows_what_its_kind_expects_has_no_problems(self):
        for case in ("sm_ok", "fd_ok", "rb_ok"):
            self.assertEqual(self.r[case], [], case)

    def test_a_bootstrap_that_did_not_finish_is_one_problem_and_nothing_else(self):
        for case in ("sm_unfinished", "fd_unfinished", "rb_unfinished"):
            self.assertEqual(len(self.r[case]), 1, case)
            self.assertIn("did not finish within the time limit", self.r[case][0])

    def test_a_fixture_that_does_not_reproduce_the_symptom_cannot_pass(self):
        self.has("sm_first_run_names_nothing", "never named the missing module pvw_still_missing_")
        self.has("sm_question_lists_one", "the question lists [xlsxwriter], expected [pvw_still_missing_, xlsxwriter]")
        self.has("sm_not_accepted", "never says the question was answered yes")

    def test_a_provider_cascade_after_the_step_is_a_problem(self):
        self.has("sm_cascade_started", "the log shows a provider cascade", "REQ-009: cascading provider")
        self.has("sm_cascade_approved", "the log shows a provider cascade", "Last chance: cascade approved")
        self.has("fd_cascade", "the log shows a provider cascade", "REQ-009: cascade consent: accepted")

    def test_the_installable_package_must_be_installed_listed_and_in_the_environment(self):
        self.has("sm_not_installed_line", "never says xlsxwriter was installed")
        self.has("sm_no_edit_line", "never says xlsxwriter was added to requirements.txt")
        self.has("sm_requirements_lacks_it", "requirements.txt has no xlsxwriter line")
        self.has("sm_env_lacks_it", "xlsxwriter is not in the program's environment")

    def test_the_package_that_cannot_be_installed_must_be_reported_and_never_listed(self):
        self.has("sm_ghost_install_not_reported", "never says pvw_still_missing_ could not be installed")
        self.has("sm_requirements_holds_ghost", "requirements.txt holds pvw_still_missing_")
        self.has("fd_ghost_in_requirements", "requirements.txt holds pvw_ghost_pkg_")

    def test_a_check_run_that_still_names_a_module_must_not_be_called_verified(self):
        self.has("sm_not_rebuilt", "the EXE was not rebuilt after the install")
        self.has("sm_no_check_run", "never says the program runs once more to check")
        self.has("sm_no_still_missing_line", "does not say the program still reports a missing module")
        self.has("sm_says_verified", "says verified although the program still asks for pvw_still_missing_")
        self.has("sm_wrong_state", "the recorded state is [verified], expected still_missing")
        self.has("sm_wrong_site", "the offer was made at the [interpreter] site, expected exe")
        self.has("sm_one_run_only", "expected the first run and the check run")
        self.has("sm_check_run_error_lacks_ghost", "the check run's error output does not name pvw_still_missing_")
        self.has("sm_check_run_misses_good", "the check run still misses xlsxwriter")

    def test_a_failed_install_stops_the_step_there(self):
        self.has("fd_rebuilt", "the EXE was rebuilt after the install failed")
        self.has("fd_ran_again", "the program ran again after the install failed")
        self.has("fd_two_runs", "expected exactly the first run")
        self.has("fd_wrong_state", "the recorded state is [declined], expected install_failed")
        self.has("fd_no_stop_line", "does not say that no package could be installed and nothing else was changed")

    def test_a_failed_rebuild_stops_the_step_there_and_must_be_the_rebuild_asked_for(self):
        self.has("rb_hook_not_shown", "never shows the test hook")
        self.has("rb_no_rebuild_line", "never says the EXE is rebuilt")
        self.has("rb_failure_not_reported", "does not report the failed rebuild")
        self.has("rb_rebuild_completed", "the log says the rebuild completed")
        self.has("rb_checked_after", "the program ran again after the rebuild failed")
        self.has("rb_wrong_state", "the recorded state is [verified], expected rebuild_failed")
        self.has("rb_two_runs", "expected exactly the first run")

    def test_an_unknown_kind_is_a_problem(self):
        self.has("unknown_kind", "unknown kind")

    def test_the_excerpt_keeps_matching_lines_as_short_printable_ascii(self):
        ex = self.r["excerpt"]
        self.assertEqual(len(ex), 3, ex)
        self.assertTrue(all(all(32 <= ord(c) < 127 for c in ln) and len(ln) <= 160 for ln in ex), ex)
        self.assertTrue(any("caf?" in ln for ln in ex), ex)
        self.assertEqual(len(self.r["excerpt_max"]), 2)

    def test_the_counter_counts_matches(self):
        self.assertEqual(self.r["count"], [3])


@unittest.skipUnless(PWSH, "pwsh not available")
class WarningFacts(unittest.TestCase):
    """What the skip-hook script reads from a console log about the throwaway warning."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as tmp:
            cls.r = run_cases(SKIP, ("Get-WarningFacts",), WARN_CASES, tmp)

    def test_one_warning_before_the_programs_output_is_what_a_good_run_shows(self):
        for case in ("warn_ok", "warn_crlf"):
            facts = self.r[case]
            self.assertEqual((facts["Count"], facts["WarnLine"], facts["OutputLine"], facts["Before"]), (1, 2, 3, True), case)

    def test_a_warning_after_the_output_is_not_before_it(self):
        facts = self.r["warn_after_output"]
        self.assertEqual((facts["Count"], facts["Before"]), (1, False))

    def test_no_warning_and_a_repeated_warning_are_counted(self):
        self.assertEqual((self.r["warn_missing"]["Count"], self.r["warn_missing"]["Before"], self.r["warn_missing"]["WarnLine"]), (0, False, -1))
        self.assertEqual(self.r["warn_twice"]["Count"], 2)

    def test_a_line_with_only_one_half_of_the_warning_is_not_the_warning(self):
        self.assertEqual(self.r["warn_first_half_only"]["Count"], 0)
        self.assertEqual(self.r["warn_second_half_only"]["Count"], 0)

    def test_a_warning_with_no_output_after_it_is_not_before_the_output(self):
        facts = self.r["warn_no_output"]
        self.assertEqual((facts["Count"], facts["OutputLine"], facts["Before"]), (1, -1, False))


def mutate(text, old, new):
    # exactly once: with two matches the case would edit the first one, which may be another block of the file (the choice line
    # of :hidden_import_consent looks like the one of :runtime_install_offer), and the pin under test would never see the change
    assert text.count(old) == 1, "the synthetic case needs the text to hold %r exactly once, found %d" % (old[:60], text.count(old))
    return text.replace(old, new, 1)


class EachRuleCanFail(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.edges = EDGES.read_text(encoding="utf-8")
        self.skip = SKIP.read_text(encoding="utf-8")
        self.install = INSTALL.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")
        self.names = driver_defined_names(self.edges)

    # --- the edge script
    def test_a_row_id_that_is_not_literal_is_caught(self):
        text = mutate(self.edges, "id = 'self.runtime.install.listing'; req = 'REQ-018.22'", "id = $listingId; req = 'REQ-018.22'")
        self.assertTrue(any("self.runtime.install.listing" in f for f in edges_problems(text)))

    def test_a_row_that_stops_naming_its_requirement_is_caught(self):
        text = mutate(self.edges, "id = 'self.runtime.install.failed'; req = 'REQ-018.21'", "id = 'self.runtime.install.failed'; req = 'N/A'")
        self.assertTrue(any("self.runtime.install.failed" in f and "REQ-018.21" in f for f in edges_problems(text)))

    def test_a_skip_path_tag_that_drifts_is_caught(self):
        text = mutate(self.edges, "'self.runtime.install.once' = 'REQ-018.14'", "'self.runtime.install.once' = 'REQ-018.99'")
        self.assertTrue(any("$reqOf" in f and "once" in f for f in edges_problems(text)))

    def test_a_row_missing_from_the_skip_path_list_is_caught(self):
        text = mutate(self.edges, "'self.runtime.install.once', 'self.runtime.install.notoffered', ", "'self.runtime.install.notoffered', ")
        self.assertTrue(any("$allIds" in f and "once" in f for f in edges_problems(text)))

    def test_open_standard_input_is_caught(self):
        for old in ("call ~driver.bat > ~driver_console.txt 2>&1 < nul", "call run_setup.bat > $consoleName 2>&1 < nul"):
            text = mutate(self.edges, old, old.replace(" < nul", ""))
            self.assertTrue(any("standard input" in f for f in edges_problems(text)), old)

    def test_a_star_redirect_is_caught(self):
        self.assertTrue(any("*>" in f for f in edges_problems(self.edges + '\ncmd /c "call run_setup.bat *> log"\n')))

    def test_a_missing_time_limit_kill_is_caught(self):
        text = mutate(self.edges, "taskkill.exe /F /T", "taskkill.exe /F")
        self.assertTrue(any("taskkill" in f for f in edges_problems(text)))

    def test_a_script_without_its_exit_codes_is_caught(self):
        no_one = mutate(self.edges, "if (-not $allPass) { exit 1 }", "")
        self.assertTrue(any("never exits 1" in f for f in edges_problems(no_one)))
        no_zero = self.edges.rstrip().rsplit("exit 0", 1)[0]
        self.assertTrue(any("does not end with exit 0" in f for f in edges_problems(no_zero)))

    def test_a_choice_stub_that_answers_yes_is_caught(self):
        text = mutate(self.edges, "'>\"%CHOICE_ARGS%\" echo %*', 'exit /b 2'", "'>\"%CHOICE_ARGS%\" echo %*', 'exit /b 0'")
        self.assertTrue(any("choice stub" in f for f in edges_problems(text)))

    def test_a_scenario_that_stops_answering_yes_or_clearing_the_runner_is_caught(self):
        text = mutate(self.edges, 'set "HP_TEST_RTM_ANSWER=Y"', 'set "HP_TEST_RTM_ANSWER=N"')
        self.assertTrue(any("answer yes" in f for f in edges_problems(text)))
        text = mutate(self.edges, 'set "HP_PVW_KNOWN_IDEMPOTENT="', "rem")
        self.assertTrue(any("HP_PVW_KNOWN_IDEMPOTENT" in f for f in edges_problems(text)))
        text = mutate(self.edges, "-ExtraSet @('set \"%s=1\"')" % HOOK, "-ExtraSet @()")
        self.assertTrue(any(HOOK in f for f in edges_problems(text)))

    def test_a_weakened_gate_expectation_is_caught(self):
        text = mutate(self.edges, "(New-Gate -Name 'fallback_exe' -Sites @('exe') -Set ([ordered]@{ HP_ENV_MODE = 'uv'; HP_NUITKA_FALLBACK_USED = '1'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 0 -NotOffered 1",
                      "(New-Gate -Name 'fallback_exe' -Sites @('exe') -Set ([ordered]@{ HP_ENV_MODE = 'uv'; HP_NUITKA_FALLBACK_USED = '1'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 0 -NotOffered 0")
        self.assertTrue(any("fallback_exe" in f and "notoffered" in f for f in edges_problems(text)), edges_problems(text))

    def test_a_scenario_that_stops_being_the_one_its_shall_names_is_caught(self):
        text = mutate(self.edges, "-Set ([ordered]@{ HP_ENV_MODE = 'system'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 0 -NotOffered 1 -Declined 0),\n    (New-Gate -Name 'system_interp'",
                      "-Set ([ordered]@{ HP_ENV_MODE = 'uv'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 0 -NotOffered 1 -Declined 0),\n    (New-Gate -Name 'system_interp'")
        self.assertTrue(any("system_exe" in f and "set" in f for f in edges_problems(text)), edges_problems(text))

    def test_a_missing_gate_scenario_is_caught(self):
        text = mutate(self.edges, "(New-Gate -Name 'console' ", "(New-Gate -Name 'consoleX' ")
        found = edges_problems(text)
        self.assertTrue(any("console is missing" in f for f in found), found)
        self.assertTrue(any("consoleX" in f for f in found), found)

    def test_a_program_that_can_be_scanned_statically_is_caught(self):
        code = app_code(self.edges, "failed")
        text = mutate(self.edges, code, "import pvw_ghost_pkg_\n" + code)
        self.assertTrue(any("failed" in f and "static scan" in f for f in edges_problems(text)), edges_problems(text))
        text = mutate(self.edges, code, code.replace('importlib.import_module("".join(parts))', 'importlib.import_module("pvw_ghost_pkg_")'))
        self.assertTrue(any("failed" in f and "joined at run time" in f for f in edges_problems(text)))

    def test_a_program_and_a_judging_call_that_name_different_modules_are_caught(self):
        text = mutate(self.edges, "-Ghost 'pvw_still_missing_'", "-Ghost 'pvw_other_'")
        found = edges_problems(text)
        self.assertTrue(any("stillmissing" in f for f in found), found)

    def test_a_program_that_does_not_compile_is_caught(self):
        code = app_code(self.edges, "rebuildfailed")
        text = mutate(self.edges, code, code.replace("def on_click():", "def on_click(:"))
        self.assertTrue(any("does not compile" in f for f in edges_problems(text)))

    def test_a_missing_driver_is_caught(self):
        text = mutate(self.edges, "function New-OfferDriver", "function New-Other")
        self.assertIsNone(driver_defined_names(text))
        self.assertTrue(any("driver function" in f for f in offer_problems(self.batch, None)))

    # --- the hook in the batch
    def test_a_hook_that_always_applies_is_caught(self):
        text = mutate(self.batch, 'if defined %s set "%s=%s"' % (HOOK, BAD_VAR, BAD_OPTION), 'set "%s=%s"' % (BAD_VAR, BAD_OPTION))
        self.assertTrue(any("guarded by" in f for f in hook_problems(text)), hook_problems(text))

    def test_a_hook_variable_that_is_not_cleared_is_caught(self):
        text = self.batch.replace('set "%s="\r\n' % BAD_VAR, "rem x\r\n").replace('set "%s="\n' % BAD_VAR, "rem x\n")
        found = hook_problems(text)
        self.assertTrue(any("not cleared before" in f for f in found), found)
        self.assertTrue(any("not cleared after" in f for f in found), found)

    def test_a_hook_variable_that_moves_off_the_command_line_is_caught(self):
        text = mutate(self.batch, " %" + BAD_VAR + "% --name ", " --name ")
        self.assertTrue(any("exactly once" in f for f in hook_problems(text)))
        text = mutate(self.batch, "%HP_PYI_HID_COLLECT% %" + BAD_VAR + "% --name", "%" + BAD_VAR + "% %HP_PYI_HID_COLLECT% --name")
        self.assertTrue(any("between the accumulated flags and --name" in f for f in hook_problems(text)))

    def test_a_hook_that_does_not_say_it_is_set_is_caught(self):
        text = mutate(self.batch, "[TEST] %s: the rebuild command gets" % HOOK, "the rebuild command gets")
        self.assertTrue(any("[TEST] line" in f for f in hook_problems(text)))

    def test_a_second_pyinstaller_line_is_caught(self):
        text = mutate(self.batch, "\n:rti_add_hidden\n", '\n"%HP_PY%" -m PyInstaller --name x y\n:rti_add_hidden\n')
        self.assertTrue(any("exactly one PyInstaller command line" in f for f in hook_problems(text)))

    def test_a_hook_comment_that_only_a_comment_holds_is_not_the_hook(self):
        text = mutate(self.batch, 'if defined %s set "%s=%s"' % (HOOK, BAD_VAR, BAD_OPTION), 'rem if defined %s set "%s=%s"' % (HOOK, BAD_VAR, BAD_OPTION))
        self.assertTrue(any("guarded by" in f for f in hook_problems(text)))

    # --- the cut block
    def test_a_block_that_calls_something_the_driver_lacks_is_caught(self):
        text = mutate(self.batch, 'call :rti_row declined\ngoto :rti_cleanup', 'call :rti_row declined\ncall :something_new\ngoto :rti_cleanup')
        self.assertTrue(any("calls :something_new" in f for f in offer_problems(text, self.names)))

    def test_a_block_that_jumps_outside_the_cut_is_caught(self):
        text = mutate(self.batch, "if not defined HP_RTI_HAVE_PKG goto :rti_cleanup", "if not defined HP_RTI_HAVE_PKG goto :elsewhere")
        self.assertTrue(any("jumps to :elsewhere" in f for f in offer_problems(text, self.names)))

    def test_a_block_that_reads_a_variable_the_driver_never_defines_is_caught(self):
        text = mutate(self.batch, 'if exist "~runtime_install_pkgs.txt" del "~runtime_install_pkgs.txt" >nul 2>&1',
                      'if exist "%HP_NEW_INPUT%" del "~runtime_install_pkgs.txt" >nul 2>&1')
        self.assertTrue(any("reads HP_NEW_INPUT" in f for f in offer_problems(text, self.names)))
        text = mutate(self.batch, "if not defined HP_RTM_FOUND exit /b 0", "if not defined HP_NEW_FLAG exit /b 0")
        self.assertTrue(any("reads HP_NEW_FLAG" in f for f in offer_problems(text, self.names)))

    def test_a_labels_pair_that_moves_is_caught(self):
        text = mutate(self.batch, "\n:rti_install_one\n", "\n:rti_install_two\n")
        self.assertTrue(any("must each exist once" in f for f in offer_problems(text, self.names)))

    def test_the_once_per_bootstrap_guard_must_stay_first_and_the_flag_set_before_the_question(self):
        text = mutate(self.batch, "if defined HP_RTI_OFFERED exit /b 0\nif defined HP_RTI_VERIFYING exit /b 0", "if defined HP_RTI_VERIFYING exit /b 0")
        self.assertTrue(any("once-per-bootstrap guard" in f for f in offer_problems(text, self.names)))
        text = mutate(self.batch, 'set "HP_RTI_OFFERED=1"\nset "HP_RTI_LIST="', 'set "HP_RTI_LIST="')
        self.assertTrue(any("HP_RTI_OFFERED is not set before the question" in f for f in offer_problems(text, self.names)))

    def test_a_second_way_into_a_yes_is_caught(self):
        text = mutate(self.batch, "if not defined HP_RTI_HAVE_PKG goto :rti_cleanup", "if not defined HP_RTI_HAVE_PKG goto :rti_accepted")
        self.assertTrue(any("only way into :rti_accepted" in f for f in offer_problems(text, self.names)))

    def test_a_yes_only_step_reached_before_the_yes_is_caught(self):
        # the same emit line also sits in :scan_runtime_missing_module, so the anchor names the line before it (only the offer has that one)
        anchor = 'if exist "~runtime_install_ok.txt" del "~runtime_install_ok.txt" >nul 2>&1\n'
        text = mutate(self.batch, anchor, anchor + 'call :rti_rebuild\n')
        self.assertTrue(any("calls :rti_rebuild before :rti_accepted" in f for f in offer_problems(text, self.names)))

    def test_a_gate_that_reorders_or_loses_a_signal_is_caught(self):
        text = mutate(self.batch, "if defined NOINPUT goto :rti_gate_decline\n", "")
        self.assertTrue(any("NOINPUT" in f for f in offer_problems(text, self.names)))
        text = mutate(self.batch, "if defined HP_CI_LANE goto :rti_gate_decline\nif defined NOINPUT goto :rti_gate_decline\n",
                      "if defined NOINPUT goto :rti_gate_decline\nif defined HP_CI_LANE goto :rti_gate_decline\n")
        self.assertTrue(any("not in the order" in f for f in offer_problems(text, self.names)))

    def test_a_question_printed_after_the_gate_is_caught(self):
        heading = "echo *** Your program asked for packages that are not installed: ***\n"
        text = mutate(self.batch, heading, "")
        text = mutate(text, 'goto :rti_gate_interactive\n:rti_gate_override', 'goto :rti_gate_interactive\n' + heading + ':rti_gate_override')
        found = offer_problems(text, self.names)
        self.assertTrue(any("printed after the gate" in f or "HP_RTI_OFFERED is not set before" in f for f in found), found)

    def test_a_console_read_without_the_30_second_default_is_caught(self):
        # the repair consent has an identical choice line earlier in the file, so the anchor includes this question's own words
        anchor = 'choice /C YN /N /T 30 /D N /M "  Install and check?'
        for old, new, word in (("/T 30", "/T 300", "wait 30 seconds"), ("/D N", "/D Y", "default to N"), ("/C YN", "/C YNA", "exactly Y and N")):
            text = mutate(self.batch, anchor, anchor.replace(old, new))
            self.assertTrue(any(word in f for f in offer_problems(text, self.names)), old)

    def test_a_second_choice_line_is_caught(self):
        text = mutate(self.batch, "if errorlevel 2 goto :rti_gate_decline\nset \"HP_RTI_CHOICE=Y\"",
                      "if errorlevel 2 goto :rti_gate_decline\nchoice /C YN /N /T 30 /D N\nset \"HP_RTI_CHOICE=Y\"")
        self.assertTrue(any("exactly one live choice line" in f for f in offer_problems(text, self.names)))

    def test_a_no_from_choice_that_goes_on_is_caught(self):
        text = mutate(self.batch, "if errorlevel 2 goto :rti_gate_decline\nset \"HP_RTI_CHOICE=Y\"", "set \"HP_RTI_CHOICE=Y\"")
        self.assertTrue(any("errorlevel 2" in f for f in offer_problems(text, self.names)))

    def test_a_system_python_that_is_offered_is_caught(self):
        text = mutate(self.batch, 'if /I "%HP_ENV_MODE%"=="embed" set "HP_RTI_PROVIDER_OK=1"',
                      'if /I "%HP_ENV_MODE%"=="embed" set "HP_RTI_PROVIDER_OK=1"\nif /I "%HP_ENV_MODE%"=="system" set "HP_RTI_PROVIDER_OK=1"')
        self.assertTrue(any("offers providers" in f for f in offer_problems(text, self.names)))

    def test_a_not_offered_path_that_stops_saying_so_is_caught(self):
        text = mutate(self.batch, 'call :log "[INFO] Runtime install: not offered for this build or provider."\ncall :rti_row not_offered',
                      'call :rti_row not_offered')
        self.assertTrue(any(":rti_not_offered" in f for f in offer_problems(text, self.names)))
        text = mutate(self.batch, 'if /I "%HP_RTI_SITE%"=="exe" if defined HP_NUITKA_FALLBACK_USED goto :rti_not_offered\n', "")
        self.assertTrue(any("HP_NUITKA_FALLBACK_USED" in f for f in offer_problems(text, self.names)))

    def test_a_declined_path_that_stops_recording_is_caught(self):
        text = mutate(self.batch, "call :rti_row declined\n", "")
        self.assertTrue(any(":rti_gate_resolve" in f for f in offer_problems(text, self.names)))

    # --- the texts
    def test_a_reworded_log_line_is_caught(self):
        for needle in ("Runtime install: not offered for this build or provider.", "Runtime install: the program still reports a missing module after the install.",
                       "[REPAIR] rebuild complete after runtime install.", "REQ-009: cascading provider"):
            text = self.batch.replace(needle, needle.replace("Runtime", "Run time").replace("REQ-009", "REQ-0099").replace("[REPAIR]", "[REPAIRED]"))
            self.assertTrue(any(needle in f for f in text_problems(text, self.edges)), needle)

    def test_a_text_that_only_a_comment_holds_is_caught(self):
        lines = [("rem " + ln if "Runtime install: verified." in ln and "call :log" in ln else ln) for ln in lines_of(self.batch)]
        self.assertTrue(any("Runtime install: verified." in f for f in text_problems("\n".join(lines), self.edges)))

    def test_a_script_that_stops_looking_for_a_text_is_caught(self):
        text = self.edges.replace("Runtime install: the program still reports a missing module after the install", "Runtime install: still missing")
        self.assertTrue(any("still reports a missing module" in f for f in text_problems(self.batch, text)))

    def test_a_reworded_warning_or_panel_is_caught(self):
        text = self.batch.replace("do not start real work in it", "wait for it")
        self.assertTrue(any("not to start real work" in f for f in warning_batch_problems(text)))
        text = self.batch.replace("Note: EXE verification was skipped by request", "Note: EXE check skipped")
        self.assertTrue(any("Note: EXE verification was skipped by request" in f for f in warning_batch_problems(text)))
        text = self.batch.replace("SETUP COMPLETE -- WITH A CAVEAT", "SETUP FINISHED -- WITH A CAVEAT")
        self.assertTrue(any("WITH A CAVEAT" in f for f in warning_batch_problems(text)))

    # --- the skip-hook script
    def test_a_skip_hook_row_that_is_not_literal_or_loses_its_tag_is_caught(self):
        text = mutate(self.skip, "id = 'self.skiphooks.exe_only.panel'; req = 'REQ-012.5'", "id = 'self.skiphooks.exe_only.panel'; req = 'REQ-012'")
        self.assertTrue(any("exe_only.panel" in f for f in skip_problems(text)))
        text = mutate(self.skip, "id = 'self.launch.warning.throwaway'; req = 'REQ-018.5'; pass = [bool]$warnPass", "id = $id; req = 'REQ-018.5'; pass = [bool]$warnPass")
        self.assertTrue(any("throwaway" in f for f in skip_problems(text)))

    def test_an_old_skip_hook_tag_that_drifts_is_caught(self):
        text = mutate(self.skip, "req = 'REQ-012.3, REQ-012.4'", "req = 'REQ-012'")
        self.assertTrue(any("self.skiphooks.exe_only is not written once" in f for f in skip_problems(text)))

    def test_a_skip_path_that_forgets_the_new_rows_is_caught(self):
        text = mutate(self.skip, "id = 'self.launch.warning.throwaway'; req = 'REQ-018.5'; pass = $true;", "id = 'self.launch.warning.throwaway'; req = 'REQ-018.5'; pass = $false;")
        self.assertTrue(any("non-Windows skip path" in f for f in skip_problems(text)))

    def test_a_rebuild_scenario_that_is_dropped_is_caught(self):
        text = mutate(self.skip, "Add-Content -LiteralPath (Join-Path $dirF 'ledger_app.py')", "Add-Content -LiteralPath (Join-Path $dirF 'other.py')")
        self.assertTrue(any("cached EXE is stale" in f for f in skip_problems(text)))

    def test_a_weakened_warning_expectation_is_caught(self):
        text = mutate(self.skip, "($wF2.Count -eq 0)", "($wF2.Count -ge 0)")
        self.assertTrue(any("one warning before the output" in f for f in skip_problems(text)))
        text = mutate(self.skip, "($linesF3.Count -eq 3)", "($linesF3.Count -ge 3)")
        self.assertTrue(any("one verification run per build" in f for f in skip_problems(text)))

    def test_a_panel_row_that_stops_demanding_the_heading_is_caught(self):
        text = mutate(self.skip, "$panelHeading -and $panelNote -and", "$panelNote -and")
        self.assertTrue(any("plain heading and the note" in f for f in skip_problems(text)))
        text = mutate(self.skip, "(-not $caveatHeading) -and (-not $caveatSentence) -and (-not $cantConfirm)", "$true")
        self.assertTrue(any("absence of the caveat" in f for f in skip_problems(text)))

    def test_an_exit_condition_that_forgets_a_row_is_caught(self):
        text = mutate(self.skip, "if (-not ($entryPass -and $exePass -and $warnPass -and $panelPass)) { exit 1 }", "if (-not ($entryPass -and $exePass)) { exit 1 }")
        self.assertTrue(any("exit 1" in f for f in skip_problems(text)))

    def test_a_warning_function_that_stops_looking_for_both_halves_is_caught(self):
        text = mutate(self.skip, "$line.Contains('do not start real work in it')", "$true")
        self.assertTrue(any("do not start real work in it" in f for f in skip_problems(text)))

    def test_an_accept_row_that_loses_the_second_tag_is_caught(self):
        text = mutate(self.install, "req     = 'REQ-018.17, REQ-018.20'", "req     = 'REQ-018.17'")
        self.assertTrue(any("REQ-018.20" in f for f in install_problems(text)))

    # --- the workflow
    def test_a_missing_edge_step_is_caught(self):
        mutated = self.workflow.replace("selfapps_runtime_install_edges.ps1", "something_else.ps1")
        self.assertEqual(workflow_problems(mutated), ["no step runs tests\\selfapps_runtime_install_edges.ps1"])

    def test_a_step_on_another_lane_is_caught(self):
        mutated = mutate(self.workflow, EDGES_STEP_IF, "if: ${{ !cancelled() && matrix.mode == 'real' }}")
        self.assertTrue(any("contract-uv lane" in f for f in workflow_problems(mutated)))

    def test_a_step_that_cannot_fail_is_caught(self):
        mutated = mutate(self.workflow, "          & tests\\selfapps_runtime_install_edges.ps1", "          & tests\\selfapps_runtime_install_edges.ps1\n        continue-on-error: true")
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(mutated)))

    def test_a_missing_upload_pattern_is_caught(self):
        mutated = mutate(self.workflow, "tests/~runtime_install_edges_evidence.txt", "tests/~other_evidence.txt")
        self.assertTrue(any("~runtime_install_edges_evidence.txt" in f for f in workflow_problems(mutated)))
        mutated = self.workflow.replace("tests/~selftest_skiphooks_entry_only/~hook_f3.log", "tests/~selftest_skiphooks_entry_only/~other.log")
        self.assertTrue(any("~hook_f3.log" in f for f in workflow_problems(mutated)))

    # --- the registry and the shall list
    def test_an_unregistered_row_is_caught(self):
        registry = mutate(REGISTRY.read_text(encoding="utf-8"), "\nself.skiphooks.exe_only.panel\n", "\nself.skiphooks.other\n")
        self.assertEqual(registry_problems(registry), ["self.skiphooks.exe_only.panel is not in docs/agent-ndjson.md"])

    def test_an_id_that_only_the_prose_names_is_not_registered(self):
        prose_only = "`self.runtime.install.once` is described here.\n\n```\nself.something.else\n```\n"
        self.assertEqual(len(registry_problems(prose_only)), len(ALL_NEW_IDS))

    def test_a_gap_entry_that_stays_is_caught(self):
        text = SHALL_TEST.read_text(encoding="utf-8") + '\n    "REQ-018.21": "gap: still no row",\n'
        self.assertEqual(len(shall_entry_problems(text)), 1)


if __name__ == "__main__":
    unittest.main()
