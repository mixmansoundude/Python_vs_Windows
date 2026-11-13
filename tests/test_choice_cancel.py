"""Item 105 (README REQ-005.10, REQ-008.11, REQ-018.15 and REQ-018.2): a timed yes/no question that the user interrupts with
Ctrl+C or Ctrl+Break is a no, never a yes.

choice.exe leaves errorlevel 1 for the first key it lists (Y), 2 for the second (N), 255 for an error and 0 for Ctrl+C or
Ctrl+Break, after which cmd.exe asks "Terminate batch job (Y/N)?" and a person who answers N lets the batch file go on with
errorlevel 0. "if errorlevel 2" is true for 2 and above, so it catches 255 and not 0, and three timed gates of run_setup.bat
(:cascade_consent_gate, :visa_subfolder_gate and :runtime_install_offer) sent errorlevel 2 to the decline and every smaller
number to the yes: an interrupted question was taken for an explicit yes to a provider cascade, to a 30 to 45 minute NI-VISA
driver install and to a package install with a rebuild and one more run of the program. The question in front of the
--hidden-import repair (:hidden_import_consent, Item 97) has a second line, "if not errorlevel 1", and is the control.

What really happens is checked on Windows by tests/selfapps_choice_cancel.ps1 (four rows, self.consent.cancel.*, contract-uv
lane): it cuts each real block out of run_setup.bat, runs it under cmd.exe with closed standard input once per answer (Y, N,
Ctrl+C, an error) and requires that only Y accepts. These rules read run_setup.bat, that script, batch-check.yml and
docs/agent-ndjson.md as text and run the script's own judging functions through a real pwsh on synthetic runs, so a block the
driver can no longer cut out of the batch file, a reworded heading or log line, a console read the stub no longer replaces, a
scenario that stops being the one the shall names, a judge that stops judging or a step that stops gating fails here with a
sentence, before a Windows run is needed. Synthetic cases prove each rule can fail.
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
SCRIPT = REPO / "tests" / "selfapps_choice_cancel.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner

# (row id, README requirement the row names, the gate it judges)
ROWS = (
    ("self.consent.cancel.cascade", "REQ-005.10", "cascade"),
    ("self.consent.cancel.visa", "REQ-008.11", "visa"),
    ("self.consent.cancel.install", "REQ-018.15", "install"),
    ("self.consent.cancel.repair", "REQ-018.2", "repair"),
)

# The answers choice.exe can leave and whether the gate may accept: only 1 (Y). A scenario that answers something else than the
# number it is named for (the cancel scenario answering 2, say) would pass without testing Ctrl+C, so the table is pinned here
# as well as in the script.
ANSWERS = (("yes", 1, True), ("no", 2, False), ("cancel", 0, False), ("error", 255, False))

# The four questions: the labels the real block is cut between, the heading it prints before it asks, the two log lines of its
# decisions (regular expressions, as the script holds them) and what the driver records after calling it.
GATES = {
    "cascade": {
        "Start": ":cascade_consent_gate", "End": ":visa_subfolder_gate",
        "Heading": r"Some dependencies could not be installed under the current Python provider\.",
        "Accepted": r"REQ-009: cascade consent: accepted\.", "Declined": r"REQ-009: cascade consent: declined\.",
        "Call": ["call :cascade_consent_gate", '>>"%RESULT%" echo RC=%ERRORLEVEL%'],
    },
    "visa": {
        "Start": ":visa_subfolder_gate", "End": ":dll_bundle_recover",
        "Heading": r"The NI-VISA driver looks needed only by a file in a subfolder:",
        "Accepted": r"NI-VISA install for a subfolder-only import: accepted\.", "Declined": r"\[VISA\] skipped \(subfolder_only\)",
        "Call": ["call :visa_subfolder_gate", '>>"%RESULT%" echo NEED_VISA=%NEED_VISA%'],
    },
    "install": {
        "Start": ":runtime_install_offer", "End": ":rti_install_one",
        "Heading": r"Your program asked for packages that are not installed:",
        "Accepted": r"Runtime install: accepted\.", "Declined": r"Runtime install: declined\. Nothing was changed\.",
        "Call": ["call :runtime_install_offer exe", '>>"%RESULT%" echo OFFERED=%HP_RTI_OFFERED%'],
    },
    "repair": {
        "Start": ":hidden_import_consent", "End": ":run_exe_smokerun",
        "Heading": r"The check run of your program failed, exit code",
        "Accepted": r"Repair loop: accepted\.", "Declined": r"Repair loop: declined\.",
        "Call": ["call :hidden_import_consent", 'if defined HP_HIC_ALLOWED >>"%RESULT%" echo ALLOWED=yes',
                 'if not defined HP_HIC_ALLOWED >>"%RESULT%" echo ALLOWED=no'],
    },
}

# The label each question sends a declined or interrupted read to (the fix of Item 105 is the guard lines that reach it).
DECLINE_LABELS = {
    "cascade": ":cascade_consent_ci_decline",
    "visa": ":visa_gate_decline",
    "install": ":rti_gate_decline",
    "repair": ":hic_gate_declined",
}

# What the driver defines for the cut-out blocks: the labels it holds stubs for and the variables it sets itself.
STUB_LABELS = [":log", ":rti_row", ":rti_install_one", ":rti_rebuild", ":run_exe_smokerun", ":verify_no_exe_interpreter",
               ":emit_from_base64", ":choice_stub"]
DRIVER_VARIABLES = {"LOG", "RESULT", "CHOICE_ARGS", "SCAN_MASTER", "CHOICE_RC", "HP_PY"}

# What the verdict the driver records reads in the real block: a live line of each of these has to stay in the block.
VERDICT_LINES = {
    "cascade": (),
    "visa": ('set "NEED_VISA=1"',),
    "install": ('set "HP_RTI_OFFERED=1"', "call :rti_install_one"),
    "repair": ('set "HP_HIC_ALLOWED=1"',),
}

STEP_IF = "if: ${{ !cancelled() && matrix.mode == 'contract-uv' }}"
UPLOADS = (
    "tests/~choice_cancel_evidence.txt",
    "tests/~selftest_choicecancel/*/~driver*",
    "tests/~selftest_choicecancel/*/~choice_args.txt",
)


def norm(text):
    return text.replace("\r\n", "\n")


def lines_of(text):
    return norm(text).split("\n")


def is_comment(line):
    return re.match(r"(?i)\s*(rem\b|::)", line) is not None


def live(lines):
    return [ln for ln in lines if ln.strip() and not is_comment(ln)]


def is_echo(line):
    return not is_comment(line) and re.search(r"(?i)(^|\s)echo\b", line) is not None


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


# --- the script read as text -------------------------------------------------------------------------------------------

def ps_strings(text):
    """The single-quoted PowerShell strings of a piece of text (a doubled quote is one quote)."""
    return [m.replace("''", "'") for m in re.findall(r"'((?:[^']|'')*)'", text)]


def script_gates(script):
    """The $gates table of the script: {key: {Start, End, Heading, Accepted, Declined, Setup, Call}}, or None."""
    parts = norm(script).split("$gates = @(", 1)
    if len(parts) != 2:
        return None
    region = parts[1].split("\n)\n", 1)[0]
    gates = {}
    for chunk in re.findall(r"\[pscustomobject\]@\{(.*?)\n    \}", region, re.S):
        def one(name):
            m = re.search(r"\b%s = '((?:[^']|'')*)'" % name, chunk)
            return m.group(1).replace("''", "'") if m else None
        setup = re.search(r"Setup = @\((.*?)\)\s*\n\s*Call = ", chunk, re.S)
        call = re.search(r"Call = @\((.*)\)\s*$", chunk, re.S)
        gates[one("Key")] = {
            "Start": one("Start"), "End": one("End"), "Heading": one("Heading"), "Accepted": one("Accepted"),
            "Declined": one("Declined"), "Setup": ps_strings(setup.group(1)) if setup else [],
            "Call": ps_strings(call.group(1)) if call else [],
        }
    return gates


def setup_names(gate):
    """The variables the gate's setup lines set or clear."""
    if not gate:
        return set()
    return {m.group(1) for s in gate["Setup"] for m in [re.match(r'set "(\w+)=', s)] if m}


def driver_facts(script):
    """What New-ChoiceDriver defines for a cut-out block: the variables it sets and the labels it holds stubs for."""
    m = re.search(r"function New-ChoiceDriver \{(.*?)\n\}\n", norm(script), re.S)
    body = m.group(1) if m else ""
    return {"found": m is not None, "vars": set(re.findall(r'set "(\w+)=', body)), "labels": re.findall(r"'(:[A-Za-z0-9_]+)'", body)}


# --- the batch file: what the script's assumptions need from it ---------------------------------------------------------

def order_problems(text):
    """Both labels of each gate exist exactly once and the start comes first."""
    lines = [ln.strip() for ln in lines_of(text)]
    found = []
    for key, g in GATES.items():
        where = []
        for label in (g["Start"], g["End"]):
            hits = [i for i, ln in enumerate(lines) if ln == label]
            if len(hits) != 1:
                found.append("%s: label %s appears %d time(s); expected exactly once, or the block cannot be cut out" % (key, label, len(hits)))
                break
            where.append(hits[0])
        else:
            if where[0] >= where[1]:
                found.append("%s: label %s does not come before %s" % (key, g["Start"], g["End"]))
    return found


def block_problems(block, driver, setup):
    """What a cut-out block reaches outside itself. Empty means the driver and the gate's setup define everything it reads, so a
    variable of the runner (HP_CI_LANE, say) cannot decide for it."""
    found = []
    own = {ln.strip() for ln in block if ln.strip().startswith(":") and not ln.strip().startswith("::")}
    seen = set()
    for ln in block:
        s = ln.strip()
        if not s or is_comment(s):
            continue
        for m in re.finditer(r"(?:goto|call)\s+(:[A-Za-z0-9_]+)", s, re.I):
            if m.group(1) not in own and m.group(1) not in driver["labels"]:
                found.append("reaches %s, which neither the block nor the driver defines" % m.group(1))
        names = [m.group(1) for m in re.finditer(r"(?i)\bdefined\s+(\w+)", s)]
        names += re.findall(r"%([A-Za-z_][A-Za-z0-9_]*)(?::[^%\s]*)?%", s)
        for name in names:
            if name not in seen and name not in driver["vars"] and name not in setup:
                found.append("reads %s before the block sets it, and neither the driver nor the gate's setup defines it" % name)
        for m in re.finditer(r'(?i)\bset\s+"(\w+)=', s):
            seen.add(m.group(1))
        if "!" in s:
            found.append("holds an exclamation mark: %s" % s[:80])
        if any(ord(c) > 126 for c in s):
            found.append("holds a character that is not ASCII: %s" % s[:80])
    return found


def choice_problems(block):
    """Exactly one live console read, and it is the question the script replaces: Y and N, a wait of 30 seconds, default N."""
    reads = [ln for ln in live(block) if re.match(r"(?i)\s*choice\s", ln)]
    if len(reads) != 1:
        return ["%d live line(s) start with choice; the script's driver replaces exactly one console read" % len(reads)]
    ln = reads[0]
    found = []
    if not re.search(r"(?i)\bchoice\s+/C\s+YN\s+/N\b", ln):
        found.append("the choice line is not 'choice /C YN /N' (Y and N only, no list of keys in the prompt)")
    if not re.search(r"(?i)\s/D\s+N(\s|$)", ln):
        found.append("the choice line does not default to N after the wait (/D N)")
    t = re.search(r"(?i)\s/T\s+(\S+)", ln)
    if not t:
        found.append("the choice line has no /T, so it would wait for ever")
    elif t.group(1) != "30":
        var = re.fullmatch(r"%(\w+)%", t.group(1))
        if not var or not any(b.strip() == 'set "%s=30"' % var.group(1) for b in live(block)):
            found.append("the choice line does not wait for 30 seconds (/T %s, and no live line sets that variable to 30)" % t.group(1))
    return found


def heading_problems(block, pattern):
    """The heading the script looks for in the console is printed by exactly one live echo line of the block."""
    hits = [ln for ln in live(block) if is_echo(ln) and re.search(pattern, re.sub(r"%[A-Za-z_]+(?::[^%\s]*)?%", "x", ln))]
    if len(hits) != 1:
        return ["the heading pattern %r matches %d live echo line(s) of the block; expected exactly 1" % (pattern, len(hits))]
    return []


def log_problems(block, accepted, declined):
    """Each decision is logged by exactly one live call :log line, and the two patterns tell the decisions apart."""
    found = []
    logs = [ln for ln in live(block) if re.search(r"\bcall :log\b", ln)]
    for name, pattern, other in (("accepted", accepted, declined), ("declined", declined, accepted)):
        hits = [ln for ln in logs if re.search(pattern, ln)]
        if len(hits) != 1:
            found.append("the %s pattern %r matches %d live call :log line(s); expected exactly 1" % (name, pattern, len(hits)))
        if any(re.search(other, ln) for ln in hits):
            found.append("the %s pattern also matches a line of the other decision" % name)
    return found


def verdict_problems(key, block):
    """What the driver records after the call is what the block leaves: the lines it reads are still in the block."""
    body = live(block)
    found = ["no live line holds %r, which the verdict of the script reads" % needle
             for needle in VERDICT_LINES[key] if not any(needle in ln for ln in body)]
    if key == "cascade":
        for log_pattern, want in ((GATES[key]["Accepted"], "exit /b 0"), (GATES[key]["Declined"], "exit /b 1")):
            at = next((i for i, ln in enumerate(body) if re.search(r"\bcall :log\b", ln) and re.search(log_pattern, ln)), -1)
            if at < 0 or at + 1 >= len(body) or body[at + 1].strip() != want:
                found.append("the line after the %r log line is not %r, which the script reads as RC" % (log_pattern, want))
    return found


def guard_problems(batch):
    """The fix itself: the two live lines after each question's console read send errorlevel 2 (N, and an error, which choice.exe
    reports as 255) AND errorlevel 0 (Ctrl+C or Ctrl+Break) to the gate's decline label, before any line can accept. `if errorlevel 2`
    alone is true for 2 and above, so it never catches 0, and the lines that follow it took 0 for a yes."""
    found = []
    for key, g in GATES.items():
        block = cut_block(batch, g["Start"], g["End"])
        if block is None:
            found.append("%s: the block between %s and %s cannot be cut" % (key, g["Start"], g["End"]))
            continue
        # raw lines, not live ones: nothing may run between choice and the lines that read its errorlevel, and a comment is not
        # known to leave the errorlevel alone either, so the two guards are the two lines directly after the read
        reads = [i for i, ln in enumerate(block) if re.match(r"(?i)\s*choice\s", ln)]
        if len(reads) != 1:
            found.append("%s: %d line(s) start with choice; expected exactly one" % (key, len(reads)))
            continue
        after = [ln.strip() for ln in block[reads[0] + 1:reads[0] + 3]]
        first = re.fullmatch(r"(?i)if errorlevel 2 goto (:\w+)", after[0]) if after else None
        if not first:
            found.append("%s: the line right after the console read is not 'if errorlevel 2 goto <decline label>' (nothing, not even a "
                         "comment, may sit between choice and the lines that read its errorlevel): %r" % (key, after[:1]))
            continue
        label = first.group(1)
        if label.lower() != DECLINE_LABELS[key].lower():
            found.append("%s: errorlevel 2 goes to %s; expected the decline label %s" % (key, label, DECLINE_LABELS[key]))
        if len(after) < 2 or not re.fullmatch(r"(?i)if not errorlevel 1 goto %s" % re.escape(label), after[1]):
            found.append("%s: the second line after the console read is not 'if not errorlevel 1 goto %s', so errorlevel 0 (Ctrl+C or "
                         "Ctrl+Break) is taken for a yes: %r" % (key, label, after[1:2]))
    return found


def batch_problems(batch, script):
    """Everything the script assumes about run_setup.bat, one list; empty means the cut-out blocks run in the driver."""
    found = order_problems(batch)
    if found:
        return found
    driver = driver_facts(script)
    if not driver["found"]:
        return ["the script has no function New-ChoiceDriver"]
    gates = script_gates(script) or {}
    for key, g in GATES.items():
        block = cut_block(batch, g["Start"], g["End"])
        if block is None:
            found.append("%s: the block between %s and %s cannot be cut" % (key, g["Start"], g["End"]))
            continue
        problems = block_problems(block, driver, setup_names(gates.get(key)))
        problems += choice_problems(block)
        problems += heading_problems(block, g["Heading"])
        problems += log_problems(block, g["Accepted"], g["Declined"])
        problems += verdict_problems(key, block)
        found += ["%s: %s" % (key, p) for p in problems]
    return found


# --- the script: its own rules -----------------------------------------------------------------------------------------

def script_problems(text):
    text = norm(text)
    found = []
    live_ps = [ln.strip() for ln in text.split("\n") if ln.strip() and not ln.strip().startswith("#")]
    for row_id, req, key in ROWS:
        pair = r"id = '%s'; req = '%s'; pass = \$" % (re.escape(row_id), re.escape(req))
        if len(re.findall(pair, text)) != 2:
            found.append("%s is not a literal id with req '%s' at both of its Write-NdjsonRow calls (the skip path and the real row)" % (row_id, req))
        verdict = (r"\$pass = \[bool\]\(@\(\$%s\.Problems\)\.Count -eq 0\)\n"
                   r"if \(-not \$pass\) \{ \$allPass = \$false \}\n"
                   r"Write-NdjsonRow \(\[ordered\]@\{ %s") % (key, pair)
        if not re.search(verdict, text):
            found.append("the row %s does not take its verdict from the problems of the %s gate and clear $allPass when it is red" % (row_id, key))
    for key in GATES:
        if not re.search(r"\$%s\s+= Get-GateResult -Gate \$gates\[%d\]" % (key, list(GATES).index(key)), text):
            found.append("the %s row is not computed from entry %d of the gate table" % (key, list(GATES).index(key)))
    gates = script_gates(text)
    if gates is None:
        found.append("the script has no $gates table")
    else:
        if list(gates) != list(GATES):
            found.append("the gate table holds %s; expected %s" % (list(gates), list(GATES)))
        for key, want in GATES.items():
            got = gates.get(key)
            if got is None:
                continue
            for field in ("Start", "End", "Heading", "Accepted", "Declined", "Call"):
                if got[field] != want[field]:
                    found.append("gate %s: %s is %r; expected %r" % (key, field, got[field], want[field]))
            if 'set "HP_CI_LANE="' not in got["Setup"]:
                found.append("gate %s: the setup does not clear HP_CI_LANE, which every one of these questions tests" % key)
    answers = [(n, int(rc), flag == "true") for n, rc, flag in
               re.findall(r"\[pscustomobject\]@\{ Name = '(\w+)'; Rc = (\d+); Accept = \$(true|false) \}", text)]
    if answers != list(ANSWERS):
        found.append("the answers are %s; expected %s (only 1 accepts, and the Ctrl+C scenario answers 0)" % (answers, list(ANSWERS)))
    if text.count("foreach ($a in $answers) {") != 1:
        found.append("the gate result does not run every answer in one loop over $answers")
    if "-ExpectAccepted ([bool]$a.Accept)" not in text:
        found.append("the judge is not told from the answers table whether the gate may accept")
    driver = driver_facts(text)
    if not driver["found"]:
        found.append("the script has no function New-ChoiceDriver")
    else:
        if sorted(driver["labels"]) != sorted(STUB_LABELS):
            found.append("the driver defines the labels %s; expected %s, each once" % (driver["labels"], STUB_LABELS))
        if not DRIVER_VARIABLES <= driver["vars"]:
            found.append("the driver does not set %s" % sorted(DRIVER_VARIABLES - driver["vars"]))
    for needle, why in (
        ("call ~driver.bat > ~driver_console.txt 2>&1 < nul", "the driver launch does not close standard input (< nul)"),
        ("taskkill.exe /F /T /PID", "a run past the time limit is not stopped with taskkill /F /T"),
        ("-LimitMs 180000", "a driver run has no 3 minute limit"),
        ("-replace '^(\\s*)choice\\s+', '$1call :choice_stub '", "the console read (the line that starts with choice) is not replaced by the stub"),
        ("'exit /b %CHOICE_RC%'", "the stub does not answer with the errorlevel of the scenario"),
        ("'>>\"%CHOICE_ARGS%\" echo %*'", "the stub does not record its arguments"),
        ("'>\"%RESULT%\" echo START'", "the driver does not record that it started"),
        ("'>>\"%RESULT%\" echo END'", "the driver does not record that it reached its end"),
        ("'non-windows-host'", "the script has no skip path off Windows"),
        ("no python on the runner could run the helper", "the install gate does not fail when no python can run the helper"),
        ("'REACHED rti_rebuild'", "the rebuild stub does not record that it was reached"),
    ):
        if needle.replace("'", "") not in text.replace("'", "") and needle not in text:
            found.append(why)
    if "REACHED" not in text or "(?m)^REACHED\\s" not in text:
        found.append("the judge does not count a step the driver does not run as a problem")
    if not live_ps or live_ps[-1] != "exit 0":
        found.append("the script does not end with exit 0 (last line: %r)" % (live_ps[-1] if live_ps else ""))
    if "if (-not $allPass) { exit 1 }" not in live_ps:
        found.append("the script never exits 1 when a row is red")
    return found


# --- the workflow and the registry ------------------------------------------------------------------------------------

def step_block(text):
    lines = norm(text).split("\n")
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if "selfapps_choice_cancel.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_choice_cancel.ps1"]
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
            ids.add(ln.strip())
    return ids


def registry_problems(text):
    registered = registry_ids(text)
    return ["%s is not in docs/agent-ndjson.md" % row_id for row_id, _req, _key in ROWS if row_id not in registered]


# --- the script's judging functions, run through a real pwsh ------------------------------------------------------------

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


# What a clean run of each gate looks like, as the driver would leave it. The heading is the console line the block prints; the
# choice line is what the stub records (the arguments of the console read, after cmd.exe has expanded them).
HEADING_LINE = {
    "cascade": "*** Some dependencies could not be installed under the current Python provider. ***",
    "visa": "*** The NI-VISA driver looks needed only by a file in a subfolder: subfolder\\old_program.py ***",
    "install": "*** Your program asked for packages that are not installed: ***",
    "repair": "*** The check run of your program failed, exit code 1. ***",
}
ACCEPTED_LOG = {
    "cascade": "[INFO] REQ-009: cascade consent: accepted.",
    "visa": "[INFO] NI-VISA install for a subfolder-only import: accepted.",
    "install": "[INFO] Runtime install: accepted.",
    "repair": "[INFO] Repair loop: accepted. Your program will be started again to look for a missing package.",
}
DECLINED_LOG = {
    "cascade": "[INFO] REQ-009: cascade consent: declined.",
    "visa": "[VISA] skipped (subfolder_only)",
    "install": "[INFO] Runtime install: declined. Nothing was changed.",
    "repair": "[INFO] Repair loop: declined. Your program was not started again and nothing was rebuilt.",
}
RESULT_ACCEPTED = {
    "cascade": ["RC=0"], "visa": ["NEED_VISA=1"],
    "install": ["INSTALL_ONE pvw_cancel_probe_ pvw_cancel_probe_", "ROW=install_failed", "OFFERED=1"], "repair": ["ALLOWED=yes"],
}
RESULT_DECLINED = {
    "cascade": ["RC=1"], "visa": ["NEED_VISA=2"], "install": ["ROW=declined", "OFFERED=1"], "repair": ["ALLOWED=no"],
}
CHOICE_LINE = '/C YN /N /T 30 /D N /M "  Is this a question? [Y/N, defaults to N after 30s] "\r\n'


def result_text(*lines):
    return "\r\n".join(("START",) + tuple(lines) + ("END",)) + "\r\n"


def judge(name, key, scenario, **over):
    """The arguments of one Get-ChoiceProblems case; by default a clean run of the gate and answer."""
    accepts = scenario == "yes"
    args = {
        "GateKey": key, "Scenario": scenario, "Finished": True,
        "ResultText": result_text(*(RESULT_ACCEPTED if accepts else RESULT_DECLINED)[key]),
        "LogText": (ACCEPTED_LOG if accepts else DECLINED_LOG)[key] + "\r\n",
        "ConsoleText": "\r\n" + HEADING_LINE[key] + "\r\n",
        "ChoiceArgsText": CHOICE_LINE, "HeadingPattern": GATES[key]["Heading"],
        "AcceptedPattern": GATES[key]["Accepted"], "DeclinedPattern": GATES[key]["Declined"], "ExpectAccepted": accepts,
    }
    args.update(over)
    return {"name": name, "fn": "Get-ChoiceProblems", "args": args}


def decision(name, key, text):
    return {"name": name, "fn": "Get-Decision", "args": {"GateKey": key, "ResultText": text}}


def judge_cases():
    cases = []
    for key in GATES:
        for scenario, _rc, _accept in ANSWERS:
            cases.append(judge("good_%s_%s" % (key, scenario), key, scenario))
        # the defect: every answer but a yes must decline, and the message for Ctrl+C names it
        wrong = {"ResultText": result_text(*RESULT_ACCEPTED[key]), "LogText": ACCEPTED_LOG[key] + "\r\n"}
        for scenario in ("no", "cancel", "error"):
            cases.append(judge("taken_for_yes_%s_%s" % (key, scenario), key, scenario, **wrong))
        cases.append(judge("yes_declined_%s" % key, key, "yes", ResultText=result_text(*RESULT_DECLINED[key]), LogText=DECLINED_LOG[key] + "\r\n"))
        cases.append(decision("decision_accepted_%s" % key, key, result_text(*RESULT_ACCEPTED[key])))
        cases.append(decision("decision_declined_%s" % key, key, result_text(*RESULT_DECLINED[key])))
        cases.append(decision("decision_unknown_%s" % key, key, result_text()))
    cases += [
        judge("unfinished", "cascade", "cancel", Finished=False),
        judge("no_end", "cascade", "cancel", ResultText="START\r\nRC=1\r\n"),
        judge("reached", "install", "yes", ResultText=result_text(*(RESULT_ACCEPTED["install"] + ["REACHED rti_rebuild"]))),
        judge("heading_twice", "cascade", "no", ConsoleText="\r\n" + HEADING_LINE["cascade"] + "\r\n" + HEADING_LINE["cascade"] + "\r\n"),
        judge("heading_missing", "cascade", "no", ConsoleText="\r\nnothing\r\n"),
        judge("no_choice_read", "cascade", "no", ChoiceArgsText=""),
        judge("two_choice_reads", "cascade", "no", ChoiceArgsText=CHOICE_LINE + CHOICE_LINE),
        judge("wrong_keys", "cascade", "no", ChoiceArgsText=CHOICE_LINE.replace("/C YN", "/C YNC")),
        judge("wrong_wait", "cascade", "no", ChoiceArgsText=CHOICE_LINE.replace("/T 30", "/T 60")),
        judge("wrong_default", "cascade", "no", ChoiceArgsText=CHOICE_LINE.replace("/D N", "/D Y")),
        judge("unknown_verdict", "cascade", "no", ResultText=result_text()),
        judge("both_decisions_logged", "visa", "no", LogText=DECLINED_LOG["visa"] + "\r\n" + ACCEPTED_LOG["visa"] + "\r\n"),
        judge("declined_logged_twice", "repair", "cancel", LogText=DECLINED_LOG["repair"] + "\r\n" + DECLINED_LOG["repair"] + "\r\n"),
        judge("no_decision_logged", "install", "no", LogText=""),
    ]
    return cases


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgeOnSyntheticRuns(unittest.TestCase):
    """The script's two judging functions on runs built here: a clean run of every gate and answer passes, and each kind of wrong
    run is reported with its own sentence. The functions run alone and in strict mode, so they cannot read the script's variables."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(SCRIPT, ["Get-Decision", "Get-ChoiceProblems"], judge_cases(), d)

    def has(self, name, needle):
        found = self.r[name]
        self.assertTrue(any(needle in f for f in found), (name, needle, found))

    def test_a_clean_run_of_every_gate_and_answer_has_no_problem(self):
        for key in GATES:
            for scenario, _rc, _accept in ANSWERS:
                with self.subTest(gate=key, answer=scenario):
                    self.assertEqual(self.r["good_%s_%s" % (key, scenario)], [])

    def test_ctrl_c_taken_for_a_yes_is_named_in_the_report(self):
        for key in GATES:
            with self.subTest(gate=key):
                self.has("taken_for_yes_%s_cancel" % key, "errorlevel 0 (Ctrl+C or Ctrl+Break) was taken for a yes")
                self.has("taken_for_yes_%s_cancel" % key, "log holds 1 accepted line(s), expected 0")
                self.has("taken_for_yes_%s_cancel" % key, "log holds 0 declined line(s), expected 1")

    def test_an_error_or_a_no_taken_for_a_yes_is_a_problem_too(self):
        for key in GATES:
            for scenario in ("no", "error"):
                with self.subTest(gate=key, answer=scenario):
                    self.has("taken_for_yes_%s_%s" % (key, scenario), "the gate accepted, expected declined")

    def test_a_gate_that_ignores_a_yes_is_a_problem(self):
        for key in GATES:
            with self.subTest(gate=key):
                self.has("yes_declined_%s" % key, "the gate declined, expected accepted")
                self.has("yes_declined_%s" % key, "log holds 0 accepted line(s), expected 1")

    def test_the_decision_is_read_from_what_each_block_leaves(self):
        for key in GATES:
            with self.subTest(gate=key):
                self.assertEqual(self.r["decision_accepted_%s" % key], ["accepted"])
                self.assertEqual(self.r["decision_declined_%s" % key], ["declined"])
                self.assertEqual(self.r["decision_unknown_%s" % key], ["unknown"])

    def test_a_run_that_did_not_finish_or_end_is_one_problem_and_nothing_else(self):
        self.assertEqual(len(self.r["unfinished"]), 1)
        self.has("unfinished", "did not finish within the time limit")
        self.assertEqual(len(self.r["no_end"]), 1)
        self.has("no_end", "did not reach its end")

    def test_a_block_that_goes_on_to_a_step_the_driver_does_not_run_is_a_problem(self):
        self.has("reached", "went on to a step this driver does not run")

    def test_the_heading_must_be_printed_exactly_once(self):
        self.has("heading_twice", "printed 2 time(s), expected 1")
        self.has("heading_missing", "printed 0 time(s), expected 1")

    def test_the_console_read_must_happen_once_and_have_the_shape_of_the_question(self):
        self.has("no_choice_read", "never reached its choice line")
        self.has("two_choice_reads", "read the console 2 times, expected once")
        self.has("wrong_keys", "does not offer exactly Y and N")
        self.has("wrong_wait", "does not wait for 30 seconds")
        self.has("wrong_default", "does not default to N")

    def test_a_verdict_nobody_recorded_is_not_taken_for_a_decline(self):
        self.has("unknown_verdict", "the gate unknown, expected declined")

    def test_each_decision_is_logged_exactly_once(self):
        self.has("both_decisions_logged", "log holds 1 accepted line(s), expected 0")
        self.has("declined_logged_twice", "log holds 2 declined line(s), expected 1")
        self.has("no_decision_logged", "log holds 0 declined line(s), expected 1")


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


# --- the rules on the real files ----------------------------------------------------------------------------------------

class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_labels_exist_once_so_each_block_can_be_cut(self):
        self.assertEqual(order_problems(self.batch), [])

    def test_the_blocks_have_what_the_script_assumes(self):
        self.assertEqual(batch_problems(self.batch, self.script), [])

    def test_every_timed_question_declines_errorlevel_0_as_well_as_2(self):
        self.assertEqual(guard_problems(self.batch), [])

    def test_the_script_has_its_rows_tables_stubs_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_contract_uv_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_script_table_matches_every_block_it_cuts(self):
        gates = script_gates(self.script)
        self.assertEqual(list(gates), list(GATES))
        for key, g in GATES.items():
            block = cut_block(self.batch, g["Start"], g["End"])
            self.assertIsNotNone(block, key)
            text = "\n".join(live(block))
            self.assertRegex(re.sub(r"%[A-Za-z_]+(?::[^%\s]*)?%", "x", text), gates[key]["Accepted"], key)
            self.assertRegex(text, gates[key]["Declined"], key)

    def test_the_checks_are_not_vacuous_on_the_real_files(self):
        for key, g in GATES.items():
            block = cut_block(self.batch, g["Start"], g["End"])
            self.assertIsNotNone(block, key)
            self.assertGreater(len(live(block)), 15, key)
            self.assertEqual(len([ln for ln in live(block) if re.match(r"(?i)\s*choice\s", ln)]), 1, key)
        gates = script_gates(self.script)
        self.assertEqual(sorted(setup_names(gates["install"]) & {"HP_ENV_MODE", "HP_RTM_FOUND", "HP_CI_LANE"}),
                         ["HP_CI_LANE", "HP_ENV_MODE", "HP_RTM_FOUND"])
        self.assertEqual(driver_facts(self.script)["vars"] & DRIVER_VARIABLES, DRIVER_VARIABLES)


def mutate(text, old, new):
    # exactly once: with two matches the case would edit the first one, which may be another block of the file (the choice line
    # of :hidden_import_consent looks like the one of :runtime_install_offer), and the pin under test would never see the change
    assert text.count(old) == 1, "the synthetic case needs the text to hold %r exactly once, found %d" % (old[:60], text.count(old))
    return text.replace(old, new, 1)


class BatchRulesCanFail(unittest.TestCase):
    """Each rule about run_setup.bat is shown to fail on a mutated copy of the real file."""

    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")

    def problems(self, batch):
        return batch_problems(batch, self.script)

    def test_a_missing_or_duplicated_label_is_reported_not_skipped(self):
        gone = mutate(self.batch, ":runtime_install_offer\n", ":runtime_install_asks\n")
        self.assertTrue(any("appears 0 time(s)" in f for f in order_problems(gone)))
        twice = self.batch + "\n:hidden_import_consent\n"
        self.assertTrue(any("appears 2 time(s)" in f for f in order_problems(twice)))
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))
        self.assertIsNone(cut_block("a\n:two\nb\n", ":one", ":two"))

    def test_labels_in_the_wrong_order_are_reported(self):
        swapped = "\n".join([":cascade_consent_gate", ":visa_subfolder_gate", ":dll_bundle_recover", ":runtime_install_offer",
                             ":rti_install_one", ":run_exe_smokerun", ":hidden_import_consent"])
        self.assertTrue(any("does not come before" in f for f in order_problems(swapped)))

    def test_a_block_that_reaches_a_label_the_driver_does_not_define_is_caught(self):
        text = mutate(self.batch, ":visa_gate_decline\nset \"HP_VISA_DECISION=N\"\n", ":visa_gate_decline\ncall :somewhere_else\nset \"HP_VISA_DECISION=N\"\n")
        self.assertTrue(any("visa" in f and ":somewhere_else" in f for f in self.problems(text)))

    def test_a_block_that_reads_a_new_variable_is_caught(self):
        text = mutate(self.batch, 'set "HP_CASCADE_CHOICE="\nif defined HP_TEST_CASCADE_ANSWER', 'set "HP_CASCADE_CHOICE="\necho %HP_NEW_THING%\nif defined HP_TEST_CASCADE_ANSWER')
        self.assertTrue(any("cascade" in f and "HP_NEW_THING" in f for f in self.problems(text)))

    def test_a_new_test_of_a_variable_the_driver_does_not_clear_is_caught(self):
        text = mutate(self.batch, "if defined NOINPUT goto :visa_gate_decline\n", "if defined NOINPUT goto :visa_gate_decline\nif defined HP_NEW_SIGNAL goto :visa_gate_decline\n")
        self.assertTrue(any("visa" in f and "HP_NEW_SIGNAL" in f for f in self.problems(text)))

    def test_a_second_console_read_is_caught(self):
        extra = 'choice /C YN /N /T 30 /D N /M "again? "\n'
        text = mutate(self.batch, 'goto :rti_gate_interactive\n:rti_gate_override', 'goto :rti_gate_interactive\n' + extra + ':rti_gate_override')
        self.assertTrue(any("install" in f and "2 live line(s) start with choice" in f for f in self.problems(text)))

    def test_a_console_read_that_is_no_longer_a_yes_no_question_is_caught(self):
        for old, new, needle in (
            ('choice /C YN /N /T 30 /D N /M "  Start your program again', 'choice /C YNC /N /T 30 /D N /M "  Start your program again', "/C YN /N"),
            ('choice /C YN /N /T 30 /D N /M "  Start your program again', 'choice /C YN /N /T 60 /D N /M "  Start your program again', "30 seconds"),
            ('choice /C YN /N /T 30 /D N /M "  Start your program again', 'choice /C YN /N /T 30 /D Y /M "  Start your program again', "/D N"),
            ('choice /C YN /N /T 30 /D N /M "  Start your program again', 'choice /C YN /N /D N /M "  Start your program again', "no /T"),
        ):
            with self.subTest(new=new):
                found = self.problems(mutate(self.batch, old, new))
                self.assertTrue(any("repair" in f and needle in f for f in found), found)

    def test_a_wait_variable_that_is_not_30_is_caught(self):
        text = mutate(self.batch, 'set "HP_CASCADE_T=30"', 'set "HP_CASCADE_T=300"')
        self.assertTrue(any("cascade" in f and "30 seconds" in f for f in self.problems(text)))

    def test_a_reworded_heading_is_caught(self):
        for old, new, key in (
            ("Some dependencies could not be installed under the current Python provider.", "Some dependencies failed.", "cascade"),
            ("The NI-VISA driver looks needed only by a file in a subfolder:", "The NI-VISA driver may be needed:", "visa"),
            ("Your program asked for packages that are not installed:", "Your program needs packages:", "install"),
            ("The check run of your program failed, exit code", "The first run failed, exit code", "repair"),
        ):
            with self.subTest(gate=key):
                found = self.problems(mutate(self.batch, old, new))
                self.assertTrue(any(key in f and "heading pattern" in f for f in found), found)

    def test_a_reworded_decision_log_line_is_caught(self):
        for old, new, key in (
            ("[INFO] REQ-009: cascade consent: declined.", "[INFO] REQ-009: cascade consent: no.", "cascade"),
            ("[INFO] REQ-009: cascade consent: accepted.", "[INFO] REQ-009: cascade consent: yes.", "cascade"),
            ('[VISA] skipped (subfolder_only)', '[VISA] skipped (subfolder)', "visa"),
            ("[INFO] Runtime install: declined. Nothing was changed.", "[INFO] Runtime install: declined.", "install"),
            ("[INFO] Repair loop: accepted. Your program will be started again to look for a missing package.", "[INFO] Repair loop: yes.", "repair"),
        ):
            with self.subTest(new=new):
                found = self.problems(mutate(self.batch, old, new))
                self.assertTrue(any(key in f and "call :log line" in f for f in found), found)

    def test_a_verdict_the_script_reads_that_moved_is_caught(self):
        text = mutate(self.batch, 'set "NEED_VISA=1"', 'set "NEED_VISA_X=1"')
        self.assertTrue(any("visa" in f and "NEED_VISA=1" in f for f in self.problems(text)))
        text = mutate(self.batch, 'call :log "[INFO] REQ-009: cascade consent: declined."\nexit /b 1', 'call :log "[INFO] REQ-009: cascade consent: declined."\nexit /b 0')
        self.assertTrue(any("cascade" in f and "exit /b 1" in f for f in self.problems(text)))

    def test_a_gate_without_its_errorlevel_0_guard_is_caught(self):
        for key, label in DECLINE_LABELS.items():
            with self.subTest(gate=key):
                found = guard_problems(mutate(self.batch, "if not errorlevel 1 goto %s\n" % label, ""))
                self.assertEqual([f.split(":")[0] for f in found], [key], found)
                self.assertIn("Ctrl+C", found[0])

    def test_a_gate_without_its_errorlevel_2_line_is_caught(self):
        for key, label in DECLINE_LABELS.items():
            with self.subTest(gate=key):
                found = guard_problems(mutate(self.batch, "if errorlevel 2 goto %s\n" % label, ""))
                self.assertEqual([f.split(":")[0] for f in found], [key], found)
                self.assertIn("if errorlevel 2 goto", found[0])

    def test_guards_in_the_wrong_order_or_for_the_wrong_label_are_caught(self):
        text = mutate(self.batch, "if errorlevel 2 goto :visa_gate_decline\nif not errorlevel 1 goto :visa_gate_decline\n",
                      "if not errorlevel 1 goto :visa_gate_decline\nif errorlevel 2 goto :visa_gate_decline\n")
        self.assertTrue(any(f.startswith("visa:") and "if errorlevel 2 goto" in f for f in guard_problems(text)))
        text = mutate(self.batch, "if not errorlevel 1 goto :rti_gate_decline\n", "if not errorlevel 1 goto :rti_gate_resolve\n")
        self.assertTrue(any(f.startswith("install:") and "if not errorlevel 1 goto :rti_gate_decline" in f for f in guard_problems(text)))
        text = mutate(self.batch, "if errorlevel 2 goto :cascade_consent_ci_decline\nif not errorlevel 1 goto :cascade_consent_ci_decline\n",
                      "if errorlevel 2 goto :cascade_consent_resolve\nif not errorlevel 1 goto :cascade_consent_resolve\n")
        self.assertTrue(any(f.startswith("cascade:") and "expected the decline label" in f for f in guard_problems(text)))

    def test_a_guard_that_sends_errorlevel_0_to_the_accept_is_caught(self):
        text = mutate(self.batch, "if not errorlevel 1 goto :visa_gate_decline\n", "if not errorlevel 1 goto :visa_gate_accept\n")
        self.assertTrue(any(f.startswith("visa:") for f in guard_problems(text)))

    def test_anything_between_the_read_and_the_guards_is_caught_even_a_comment(self):
        text = mutate(self.batch, 'Install and check? [Y/N, defaults to N after 30s] "\n', 'Install and check? [Y/N, defaults to N after 30s] "\nrem a comment\n')
        found = guard_problems(text)
        self.assertEqual([f.split(":")[0] for f in found], ["install"], found)
        self.assertIn("not even a comment", found[0])

    def test_a_second_choice_line_or_a_missing_one_is_reported_by_the_guard_rule_too(self):
        text = mutate(self.batch, "if not errorlevel 1 goto :rti_gate_decline\nset \"HP_RTI_CHOICE=Y\"\n",
                      "if not errorlevel 1 goto :rti_gate_decline\nchoice /C YN /N /T 30 /D N\nset \"HP_RTI_CHOICE=Y\"\n")
        self.assertTrue(any(f.startswith("install:") and "2 line(s) start with choice" in f for f in guard_problems(text)))
        text = mutate(self.batch, 'choice /C YN /N /T 30 /D N /M "  Install and check?', 'rem choice /C YN /N /T 30 /D N /M "  Install and check?')
        self.assertTrue(any(f.startswith("install:") and "0 line(s) start with choice" in f for f in guard_problems(text)))

    def test_a_block_that_cannot_be_cut_is_reported_by_the_guard_rule_too(self):
        text = mutate(self.batch, ":rti_install_one\n", ":rti_install_two\n")
        self.assertTrue(any(f.startswith("install:") and "cannot be cut" in f for f in guard_problems(text)))

    def test_a_block_with_a_character_the_driver_cannot_carry_is_caught(self):
        self.assertTrue(block_problems([":start", "echo done!"], {"labels": [], "vars": set()}, set()))
        self.assertTrue(block_problems([":start", "echo caf\u00e9"], {"labels": [], "vars": set()}, set()))
        self.assertEqual(block_problems([":start", "goto :start", "call :log x", "rem %IGNORED% !"], {"labels": [":log"], "vars": set()}, set()), [])


class ScriptRulesCanFail(unittest.TestCase):
    """The same for the rules that read the script, the workflow step and the registry."""

    def setUp(self):
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_a_row_id_that_is_not_literal_is_caught(self):
        text = mutate(self.script, "id = 'self.consent.cancel.visa'; req = 'REQ-008.11'; pass = $pass", "id = $visaId; req = 'REQ-008.11'; pass = $pass")
        self.assertTrue(any("self.consent.cancel.visa" in f for f in script_problems(text)))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        text = mutate(self.script, "id = 'self.consent.cancel.install'; req = 'REQ-018.15'; pass = $pass", "id = 'self.consent.cancel.install'; req = 'N/A'; pass = $pass")
        self.assertTrue(any("self.consent.cancel.install" in f and "REQ-018.15" in f for f in script_problems(text)))

    def test_a_row_that_stops_taking_its_verdict_from_the_problems_is_caught(self):
        text = mutate(self.script, "$pass = [bool](@($repair.Problems).Count -eq 0)", "$pass = [bool](@($repair.Problems).Count -ge 0)")
        self.assertTrue(any("self.consent.cancel.repair" in f and "verdict" in f for f in script_problems(text)))
        text = mutate(self.script, "$pass = [bool](@($cascade.Problems).Count -eq 0)\nif (-not $pass) { $allPass = $false }", "$pass = [bool](@($cascade.Problems).Count -eq 0)")
        self.assertTrue(any("self.consent.cancel.cascade" in f and "$allPass" in f for f in script_problems(text.replace("\r\n", "\n"))))

    def test_a_row_computed_from_another_gate_is_caught(self):
        text = mutate(self.script, "$visa    = Get-GateResult -Gate $gates[1]", "$visa    = Get-GateResult -Gate $gates[0]")
        self.assertTrue(any("visa" in f and "entry 1" in f for f in script_problems(text)))

    def test_a_gate_table_that_drifts_is_caught(self):
        for old, new, needle in (
            ("End = ':visa_subfolder_gate'", "End = ':dll_bundle_recover'", "End is"),
            ("Heading = 'Your program asked for packages that are not installed:'", "Heading = 'Your program'", "Heading is"),
            ("Accepted = 'Runtime install: accepted\\.'", "Accepted = 'accepted'", "Accepted is"),
            ("'call :runtime_install_offer exe'", "'call :runtime_install_offer interpreter'", "Call is"),
        ):
            with self.subTest(new=new):
                self.assertTrue(any(needle in f for f in script_problems(mutate(self.script, old, new))))

    def test_a_setup_that_leaves_the_ci_signal_is_caught(self):
        text = mutate(self.script, """'set "HP_TEST_FORCE_INTERACTIVE_CASCADE="', 'set "HP_CI_LANE="')""", """'set "HP_TEST_FORCE_INTERACTIVE_CASCADE="')""")
        self.assertTrue(any("cascade" in f and "HP_CI_LANE" in f for f in script_problems(text)))

    def test_an_answers_table_that_weakens_a_scenario_is_caught(self):
        for old, new in (
            ("Name = 'cancel'; Rc = 0; Accept = $false", "Name = 'cancel'; Rc = 2; Accept = $false"),
            ("Name = 'cancel'; Rc = 0; Accept = $false", "Name = 'cancel'; Rc = 0; Accept = $true"),
            ("Name = 'error'; Rc = 255; Accept = $false", "Name = 'error'; Rc = 254; Accept = $false"),
            ("Name = 'yes'; Rc = 1; Accept = $true", "Name = 'yes'; Rc = 1; Accept = $false"),
        ):
            with self.subTest(new=new):
                self.assertTrue(any("the answers are" in f for f in script_problems(mutate(self.script, old, new))))

    def test_a_judge_that_is_not_told_what_the_answer_must_do_is_caught(self):
        text = mutate(self.script, "-ExpectAccepted ([bool]$a.Accept)", "-ExpectAccepted $true")
        self.assertTrue(any("answers table" in f for f in script_problems(text)))

    def test_a_driver_that_loses_a_stub_or_a_variable_is_caught(self):
        text = mutate(self.script, "':rti_rebuild', '>>\"%RESULT%\" echo REACHED rti_rebuild', 'exit /b 0',\n", "")
        self.assertTrue(any("the driver defines the labels" in f for f in script_problems(text)))
        text = mutate(self.script, "('set \"CHOICE_RC=' + [string]$Answer.Rc + '\"'),\n", "")
        self.assertTrue(any("CHOICE_RC" in f for f in script_problems(text)))

    def test_a_console_read_that_is_not_replaced_is_caught(self):
        text = mutate(self.script, "'$1call :choice_stub '", "'$1rem '")
        self.assertTrue(any("not replaced by the stub" in f for f in script_problems(text)))
        text = mutate(self.script, "'exit /b %CHOICE_RC%'", "'exit /b 2'")
        self.assertTrue(any("errorlevel of the scenario" in f for f in script_problems(text)))

    def test_open_standard_input_is_caught(self):
        text = mutate(self.script, "call ~driver.bat > ~driver_console.txt 2>&1 < nul", "call ~driver.bat > ~driver_console.txt 2>&1")
        self.assertTrue(any("standard input" in f for f in script_problems(text)))

    def test_a_missing_time_limit_or_kill_is_caught(self):
        text = mutate(self.script, "taskkill.exe /F /T /PID", "taskkill.exe /F /PID")
        self.assertTrue(any("taskkill" in f for f in script_problems(text)))
        text = mutate(self.script, "-LimitMs 180000", "-LimitMs 0")
        self.assertTrue(any("3 minute limit" in f for f in script_problems(text)))

    def test_a_judge_that_stops_counting_a_step_the_driver_does_not_run_is_caught(self):
        text = mutate(self.script, "(?m)^REACHED\\s", "(?m)^NOTHING\\s")
        self.assertTrue(any("does not count a step" in f for f in script_problems(text)))

    def test_a_script_without_its_exit_codes_is_caught(self):
        no_one = mutate(self.script, "if (-not $allPass) { exit 1 }", "")
        self.assertTrue(any("never exits 1" in f for f in script_problems(no_one)))
        no_zero = self.script.rstrip().rsplit("exit 0", 1)[0]
        self.assertTrue(any("does not end with exit 0" in f for f in script_problems(no_zero)))

    def test_a_step_that_is_not_contract_uv_only_is_caught(self):
        block = step_block(self.workflow)
        mutated = self.workflow.replace(block, block.replace("matrix.mode == 'contract-uv'", "matrix.mode == 'real'"))
        self.assertTrue(any("contract-uv lane" in f for f in workflow_problems(mutated)))

    def test_a_step_that_cannot_fail_is_caught(self):
        block = step_block(self.workflow)
        mutated = self.workflow.replace(block, block.replace("shell: pwsh", "shell: pwsh\n        continue-on-error: true"))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(mutated)))

    def test_a_missing_step_or_upload_is_caught(self):
        mutated = self.workflow.replace("selfapps_choice_cancel.ps1", "something_else.ps1")
        self.assertEqual(workflow_problems(mutated), ["no step runs tests\\selfapps_choice_cancel.ps1"])
        mutated = self.workflow.replace("tests/~choice_cancel_evidence.txt", "tests/~other.txt")
        self.assertTrue(any("~choice_cancel_evidence.txt" in f for f in workflow_problems(mutated)))

    def test_an_unregistered_row_or_one_only_named_in_prose_is_caught(self):
        registry = REGISTRY.read_text(encoding="utf-8")
        self.assertEqual(registry_problems(registry.replace("self.consent.cancel.repair\n", "self.consent.cancel.other\n")),
                         ["self.consent.cancel.repair is not in docs/agent-ndjson.md"])
        self.assertEqual(registry_problems("Prose: self.consent.cancel.cascade self.consent.cancel.visa self.consent.cancel.install self.consent.cancel.repair"),
                         ["%s is not in docs/agent-ndjson.md" % row_id for row_id, _r, _k in ROWS])


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgesCanFail(unittest.TestCase):
    """A judge that quietly stops judging would pass every scenario, so the clean cases are run against mutated copies of the script."""

    def run_mutated(self, old, new, names):
        text = norm(SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, new), encoding="utf-8")
            wanted = [c for c in judge_cases() if c["name"] in names]
            return run_cases(script, ["Get-Decision", "Get-ChoiceProblems"], wanted, d)

    def test_a_judge_that_reads_the_cascade_exit_code_the_wrong_way_round_is_caught(self):
        got = self.run_mutated("if ($ResultText -match '(?m)^RC=0\\s*$') { return 'accepted' }", "if ($ResultText -match '(?m)^RC=0\\s*$') { return 'declined' }", ["good_cascade_yes"])
        self.assertNotEqual(got["good_cascade_yes"], [])

    def test_a_judge_that_forgets_the_expectation_is_caught(self):
        got = self.run_mutated("    $want = 'declined'\n", "    $want = 'accepted'\n", ["good_cascade_no", "good_cascade_cancel"])
        self.assertNotEqual(got["good_cascade_no"], [])
        self.assertNotEqual(got["good_cascade_cancel"], [])

    def test_a_judge_that_stops_counting_the_declined_line_is_caught(self):
        got = self.run_mutated("    if ($declinedLines -ne $wantDeclined) {", "    if ($false) {", ["declined_logged_twice"])
        self.assertEqual(got["declined_logged_twice"], [])


if __name__ == "__main__":
    unittest.main()
