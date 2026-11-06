"""Item 97: the --hidden-import repair loop asks before it starts the program again (README REQ-018.1, REQ-018.2).

After a failed EXE verification run, :hidden_import_recover starts dist\\<env>.exe again to read the error text and then
once more after each repair rebuild (at most three). README REQ-018.1 allows one automatic start per invocation and
REQ-018.2 asks for the user's explicit consent, in a prompt that names the risk, before any other. The loop announced
each start with a one-line warning and asked nothing, so a program that is not safe to run twice ran up to four more
times unasked. The maintainer decided (2026-10-31, open question 7) on a first pass: ONE question before the loop's
first extra start, default No after 30 seconds, no waiting and no repair in a non-interactive run (NOINPUT,
HP_NONINTERACTIVE or HP_CI_LANE), and HP_PVW_KNOWN_IDEMPOTENT (the user's own word that the program is safe to run more
than once, REQ-005.13) counts as consent. HP_TEST_REPAIR_ANSWER is the test answer, checked first like the other four
elective offers, so CI scenarios that exercise the repair itself can say yes.

What really happens is checked by tests/selfapps_repair_consent.ps1 (seven gate rows that run the real
:hidden_import_consent block under cmd.exe, and two real bootstraps). These rules read run_setup.bat, that script and
batch-check.yml as text, so a gate that drops a signal, a reworded question, a call site that moved before the Nuitka
skip, a row that stops naming its shall or a step that stops gating fails here with a sentence, before a Windows run is
needed. The block is also cut out and held to what the script's driver defines (the technique of
tests/test_conda_transient_terms.py). Synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BAT = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_repair_consent.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
REGISTRY = REPO / "docs" / "agent-ndjson.md"

CONSENT_START, CONSENT_END = ":hidden_import_consent", ":run_exe_smokerun"
RECOVER_START, RECOVER_END = ":hidden_import_recover", ":warn_user_code_launch"

# The wording the user sees and the log lines the rows read. tests/selfapps_repair_consent.ps1 holds the same texts.
HEADING = "The check run of your program failed, exit code"
MARKER = "running it twice could cause harm"
PROMPT = "Start your program again to try the repair?"
SIGNALS = ("HP_CI_LANE", "NOINPUT", "HP_NONINTERACTIVE")
# (key in the script's $logPatterns, the text the script matches, the text the batch has to log)
LOG_LINES = (
    ("auto", "Repair loop: not asked in a non-interactive run", "Repair loop: not asked in a non-interactive run"),
    ("declined", "Repair loop: declined\\.", "Repair loop: declined."),
    ("accepted", "Repair loop: accepted\\.", "Repair loop: accepted."),
    ("idempotent", "Repair loop: HP_PVW_KNOWN_IDEMPOTENT is set", "Repair loop: HP_PVW_KNOWN_IDEMPOTENT is set"),
    ("remembered", "Repair loop: using the answer given earlier in this run", "Repair loop: using the answer given earlier in this run"),
)

# Names the cut-out block may reach outside itself; the script's driver defines every one of them.
EXTERNAL_LABELS = {":log"}
KNOWN_VARIABLES = {"HP_EXE_EXIT", "HP_TEST_REPAIR_ANSWER", "HP_HIC_RAW", "HP_HIC_CHOICE", "HP_HIC_ANSWER"}

ROWS = (
    ("self.repair.gate.noinput", "REQ-018.2"),
    ("self.repair.gate.nonint", "REQ-018.2"),
    ("self.repair.gate.cilane", "REQ-018.2"),
    ("self.repair.gate.control", "REQ-018.2"),
    ("self.repair.gate.answers", "REQ-018.2"),
    ("self.repair.gate.idempotent", "REQ-005.13"),
    ("self.repair.gate.once", "REQ-018.2"),
    ("self.repair.consent.declined", "REQ-018.1, REQ-018.2"),
    ("self.repair.consent.accepted", "REQ-018.2"),
)
SCENARIOS = ("noinput", "nonint", "cilane", "control", "answer_yes", "answer_no", "answer_beats_signal",
             "idempotent", "once_yes", "once_no")

# Scripts whose scenario is about the repair itself: they answer yes (the question has its own rows above).
ANSWERING_YES = (
    ("selfapps_hidden_import.ps1", "SetEnvironmentVariable('HP_TEST_REPAIR_ANSWER', 'Y')"),
    ("selfapps_hidden_import_exhaust.ps1", "SetEnvironmentVariable('HP_TEST_REPAIR_ANSWER', 'Y')"),
    ("selfapps_exedyn_fail.ps1", "SetEnvironmentVariable('HP_TEST_REPAIR_ANSWER', 'Y')"),
    ("selfapps_layered_e2e.ps1", "SetEnvironmentVariable('HP_TEST_REPAIR_ANSWER', 'Y')"),
    ("selfapps_hint_norerun.ps1", "$vars['HP_TEST_REPAIR_ANSWER'] = 'Y'"),
)

UPLOADS = (
    "tests/~repair_consent_evidence.txt",
    "tests/~selftest_repair_*/~setup.log",
    "tests/~selftest_repair_*/~repair_*.log",
    "tests/~selftest_repair_*/~repair_ledger.jsonl",
)


# A small batch file shaped like the real one: the per-bootstrap clear, the repair loop with its call site, the two callers, the
# question and the next label. The rule checks below are run on it (it must be clean) and on one mutation each (each must be
# caught), so the cases prove the rules can fail without needing the real file to have the question yet.
GOOD_BATCH = r"""@echo off
rem the answer lives for one bootstrap
set "HP_HIC_ANSWER="
:hidden_import_recover
set "HP_HIDDEN_REPAIRED="
if not exist "dist\%ENVNAME%.exe" exit /b 0
if defined HP_NUITKA_FALLBACK_USED (
  call :log "[INFO][HIDDEN_IMPORT] Skipping --hidden-import auto-recovery."
  exit /b 0
)
call :hidden_import_consent
if not defined HP_HIC_ALLOWED exit /b 0
set "HP_HIDDEN_ITER=0"
call :warn_user_code_launch hidden_import
:hidden_import_loop
pushd dist
popd
exit /b 0
:warn_user_code_launch
exit /b 0
:hidden_import_consent
rem Ask once per bootstrap before the repair loop starts the program again.
set "HP_HIC_ALLOWED="
if defined HP_PVW_KNOWN_IDEMPOTENT goto :hic_idempotent
if defined HP_HIC_ANSWER goto :hic_remembered
echo.
echo *** The check run of your program failed, exit code %HP_EXE_EXIT%. ***
echo *** To find out, the repair starts your program again to read its error, and again after each rebuild. ***
echo *** Each start repeats whatever your program does, so say no if running it twice could cause harm. ***
set "HP_HIC_CHOICE="
if defined HP_TEST_REPAIR_ANSWER goto :hic_gate_override
if defined HP_CI_LANE goto :hic_gate_auto
if defined NOINPUT goto :hic_gate_auto
if defined HP_NONINTERACTIVE goto :hic_gate_auto
goto :hic_gate_interactive
:hic_gate_override
set "HP_HIC_RAW=%HP_TEST_REPAIR_ANSWER%"
set "HP_HIC_CHOICE=%HP_HIC_RAW:~0,1%"
goto :hic_gate_resolve
:hic_gate_auto
call :log "[INFO] Repair loop: not asked in a non-interactive run, so your program is not started again."
set "HP_HIC_ANSWER=N"
exit /b 0
:hic_gate_interactive
where choice >nul 2>&1
if errorlevel 1 goto :hic_gate_declined
choice /C YN /N /T 30 /D N /M "  Start your program again to try the repair? [Y/N, defaults to N after 30s] "
if errorlevel 2 goto :hic_gate_declined
if not errorlevel 1 goto :hic_gate_declined
set "HP_HIC_CHOICE=Y"
:hic_gate_resolve
if /I "%HP_HIC_CHOICE%"=="Y" goto :hic_accepted
:hic_gate_declined
call :log "[INFO] Repair loop: declined. Your program was not started again."
set "HP_HIC_ANSWER=N"
exit /b 0
:hic_accepted
call :log "[INFO] Repair loop: accepted. Your program will be started again."
set "HP_HIC_ANSWER=Y"
set "HP_HIC_ALLOWED=1"
exit /b 0
:hic_idempotent
call :log "[INFO] Repair loop: HP_PVW_KNOWN_IDEMPOTENT is set, so no question is asked."
set "HP_HIC_ALLOWED=1"
exit /b 0
:hic_remembered
call :log "[INFO] Repair loop: using the answer given earlier in this run."
if /I not "%HP_HIC_ANSWER%"=="Y" exit /b 0
set "HP_HIC_ALLOWED=1"
exit /b 0
:run_exe_smokerun
if not "%HP_EXE_EXIT%"=="-1" call :hidden_import_recover
if defined HP_DLL_REPAIRED (
  call :hidden_import_recover
)
exit /b 0
"""


def lines_of(text):
    return text.replace("\r\n", "\n").split("\n")


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


def block_problems(block):
    """What a cut-out block reaches outside itself; empty means the script's driver defines everything it needs."""
    found = []
    labels = {ln.strip() for ln in block if ln.strip().startswith(":") and not ln.strip().startswith("::")}
    for ln in block:
        s = ln.strip()
        if is_comment(s):
            continue
        for m in re.finditer(r"(?:goto|call)\s+(:[A-Za-z0-9_]+)", s, re.I):
            if m.group(1) not in labels and m.group(1) not in EXTERNAL_LABELS:
                found.append("reaches %s, which the driver does not define" % m.group(1))
        for v in re.findall(r"%([A-Za-z_][A-Za-z0-9_]*)(?::[^%\s]*)?%", s):
            if v not in KNOWN_VARIABLES:
                found.append("uses %%%s%%, which the driver does not set" % v)
        if "!" in s:
            found.append("holds an exclamation mark: %s" % s[:80])
        if any(ord(c) > 126 for c in s):
            found.append("holds a character that is not ASCII: %s" % s[:80])
    return found


def consent_problems(text):
    """The question's own shape: what it asks, what it tests before it asks, how it reads the answer and what it logs."""
    block = cut_block(text, CONSENT_START, CONSENT_END)
    if block is None:
        return ["labels %s ... %s not found, so the repair loop asks no question" % (CONSENT_START, CONSENT_END)]
    found = ["the block %s" % p for p in block_problems(block)]
    body = live(block)
    # the first statement clears the verdict, so a stale 'allowed' of an earlier call cannot leak into this one
    if len(body) < 2 or body[1].strip() != 'set "HP_HIC_ALLOWED="':
        found.append('the first statement after the label is not set "HP_HIC_ALLOWED="')
    head = next((i for i, ln in enumerate(body) if HEADING in ln and is_echo(ln)), -1)
    if head < 0:
        found.append("heading %r is not an echo line of the block" % HEADING)
        return found
    read = next((i for i in range(head, len(body)) if PROMPT in body[i] and re.search(r"(?i)\bchoice\b", body[i])), -1)
    if read < 0:
        found.append("no choice line holding %r after the heading" % PROMPT)
        return found
    if not re.search(r"(?i)\bchoice\s+/C\s+YN\s+/N\s+/T\s+30\s+/D\s+N\b", body[read]):
        found.append("the choice line is not 'choice /C YN /N /T 30 /D N' (30 seconds, default No)")
    between = body[head:read]
    if not any(MARKER in ln and is_echo(ln) for ln in between):
        found.append("the question never says %r between its heading and its prompt" % MARKER)
    for signal in ("HP_TEST_REPAIR_ANSWER",) + SIGNALS:
        if not any(re.search(r"\bdefined\s+%s\b" % signal, ln) for ln in between):
            found.append("no live line between the heading and the read tests 'defined %s'" % signal)
    before = body[:head]
    if not any(re.search(r"\bdefined\s+HP_PVW_KNOWN_IDEMPOTENT\b", ln) for ln in before):
        found.append("HP_PVW_KNOWN_IDEMPOTENT is not tested before the question is made")
    if not any(re.search(r"\bdefined\s+HP_HIC_ANSWER\b", ln) for ln in before):
        found.append("an answer given earlier in the run is not tested before the question is made")
    # only an exact answer of 1 (Y) goes on: Ctrl+C is 0 and a read that failed is 255, both are a no
    after = body[read + 1:]
    yes_at = next((i for i, ln in enumerate(after) if ln.strip() == 'set "HP_HIC_CHOICE=Y"'), -1)
    if yes_at < 0:
        found.append('no line sets "HP_HIC_CHOICE=Y" after the choice line')
    else:
        guards = [ln.strip() for ln in after[:yes_at]]
        if not any(re.match(r"if errorlevel 2 goto \S+$", g) for g in guards):
            found.append("'if errorlevel 2 goto' (a no) does not guard the yes")
        if not any(re.match(r"if not errorlevel 1 goto \S+$", g) for g in guards):
            found.append("'if not errorlevel 1 goto' (Ctrl+C, an unreadable answer) does not guard the yes")
    allow = [ln for ln in body if ln.strip() == 'set "HP_HIC_ALLOWED=1"']
    if len(allow) != 3:
        found.append("HP_HIC_ALLOWED=1 is set on %d live line(s); expected 3 (accepted, idempotent, remembered yes)" % len(allow))
    for _key, _regex, shown in LOG_LINES:
        if not any(shown in ln and re.search(r"\bcall :log\b", ln) for ln in body):
            found.append("no live 'call :log' line says %r" % shown)
    for ln in body:
        if re.search(r"\bcall :log\b", ln) and re.search(r"[<>|&^]", ln.split(":log", 1)[1]):
            found.append(":log is called with a shell character in its text: %s" % ln.strip()[:100])
    return found


def call_site_problems(text):
    """Where the question is asked: once, inside :hidden_import_recover, after the Nuitka skip and before the first start."""
    recover = cut_block(text, RECOVER_START, RECOVER_END)
    if recover is None:
        return ["labels %s ... %s not found" % (RECOVER_START, RECOVER_END)]
    found = []
    body = live(recover)
    calls = [i for i, ln in enumerate(body) if ln.strip() == "call :hidden_import_consent"]
    if len(calls) != 1:
        return ["%s holds %d live 'call :hidden_import_consent' line(s); expected exactly 1" % (RECOVER_START, len(calls))]
    at = calls[0]
    if at + 1 >= len(body) or body[at + 1].strip() != "if not defined HP_HIC_ALLOWED exit /b 0":
        found.append("the line after the call is not 'if not defined HP_HIC_ALLOWED exit /b 0'")
    nuitka = next((i for i, ln in enumerate(body) if "defined HP_NUITKA_FALLBACK_USED" in ln), -1)
    if nuitka < 0 or at < nuitka:
        found.append("the question is not asked after the Nuitka skip (a Nuitka EXE is never repaired, so it must not be asked about)")
    loop = next((i for i, ln in enumerate(body) if ln.strip() == ":hidden_import_loop"), -1)
    start = next((i for i, ln in enumerate(body) if re.match(r"(?i)pushd\s+dist\b", ln.strip())), -1)
    if loop < 0 or at > loop:
        found.append("the question is not asked before :hidden_import_loop")
    if start < 0 or at > start:
        found.append("the question is not asked before the first start of the program (pushd dist)")
    first = next((i for i, ln in enumerate(body) if ln.strip() == 'set "HP_HIDDEN_REPAIRED="'), -1)
    if first < 0 or first > at:
        found.append('set "HP_HIDDEN_REPAIRED=" is not cleared before the question, so a no could be read as a repair')
    everywhere = [i for i, ln in enumerate(lines_of(text)) if not is_comment(ln) and ln.strip() == "call :hidden_import_consent"]
    if len(everywhere) != 1:
        found.append("run_setup.bat holds %d live 'call :hidden_import_consent' line(s); expected exactly 1" % len(everywhere))
    callers = [ln for ln in live(lines_of(text)) if ln.strip().endswith("call :hidden_import_recover")]
    if len(callers) != 2:
        found.append("%d live line(s) call :hidden_import_recover; expected the 2 known sites, and the answer must survive both" % len(callers))
    return found


def order_problems(text):
    lines = [ln.strip() for ln in lines_of(text)]
    where = {}
    for label in (RECOVER_START, RECOVER_END, CONSENT_START, CONSENT_END):
        hits = [i for i, ln in enumerate(lines) if ln == label]
        if len(hits) != 1:
            return ["label %s appears %d time(s); expected exactly once" % (label, len(hits))]
        where[label] = hits[0]
    if not (where[RECOVER_START] < where[RECOVER_END] < where[CONSENT_START] < where[CONSENT_END]):
        return ["the labels are not in the order :hidden_import_recover, :warn_user_code_launch, :hidden_import_consent, "
                ":run_exe_smokerun (the static checks of tests/harness.ps1 read the text between the first two)"]
    return []


def memory_problems(text):
    """The answer lives for one bootstrap: cleared once at the top of the file, never inside the block."""
    lines = lines_of(text)
    clears = [i for i, ln in enumerate(lines) if not is_comment(ln) and ln.strip() == 'set "HP_HIC_ANSWER="']
    if len(clears) != 1:
        return ['run_setup.bat holds %d live set "HP_HIC_ANSWER=" line(s); expected exactly 1, at the top' % len(clears)]
    first_call = next((i for i, ln in enumerate(lines) if not is_comment(ln) and ln.strip().endswith("call :hidden_import_recover")), None)
    block_start = next((i for i, ln in enumerate(lines) if ln.strip() == CONSENT_START), None)
    if first_call is None or block_start is None or clears[0] > first_call or clears[0] > block_start:
        return ['set "HP_HIC_ANSWER=" is not before the first call of the repair loop and the question']
    return []


def script_problems(text):
    found = []
    live_lines = [ln.strip() for ln in lines_of(text) if ln.strip() and not ln.strip().startswith("#")]
    for row_id, req in ROWS:
        pattern = r"Write-NdjsonRow \(\[ordered\]@\{\s*id = '%s'; req = '%s'" % (re.escape(row_id), re.escape(req))
        if not re.search(pattern, text):
            found.append("%s is not a literal id with req '%s' at a Write-NdjsonRow call" % (row_id, req))
    for scenario in SCENARIOS:
        if "Name = '%s'" % scenario not in text:
            found.append("scenario %s is missing" % scenario)
    for name, literal in (("heading", HEADING), ("marker", MARKER), ("prompt", PROMPT)):
        if "'%s'" % literal not in text:
            found.append("the script does not hold the %s %r" % (name, literal))
    for key, regex, _shown in LOG_LINES:
        if not re.search(r"(?m)^\s*%s\s*=\s*'%s'" % (re.escape(key), re.escape(regex)), text):
            found.append("the script does not hold the log pattern for %s: %r" % (key, regex))
    if "Get-BatBlock -StartLabel ':hidden_import_consent' -EndLabel ':run_exe_smokerun'" not in text:
        found.append("the script does not cut the block between the two labels this test pins")
    for name in ("HP_CI_LANE", "NOINPUT", "HP_NONINTERACTIVE", "HP_TEST_REPAIR_ANSWER", "HP_PVW_KNOWN_IDEMPOTENT"):
        if "'set \"%s=\"'" % name not in text:
            found.append("the driver does not clear %s before a scenario" % name)
    if "call ~driver.bat > ~driver_console.txt 2>&1 < nul" not in text:
        found.append("the driver launch does not close standard input (< nul)")
    if 'call run_setup.bat > $consoleName 2>&1 < nul' not in text:
        found.append("the bootstrap launch does not close standard input (< nul)")
    if "taskkill.exe /F /T" not in text:
        found.append("a run past the time limit is not stopped with taskkill /F /T")
    if "$runTimeoutMs = 15 * 60 * 1000" not in text:
        found.append("a bootstrap has no 15 minute limit")
    if "Invoke-RepairScenario -Scenario 'declined' -Answer ''" not in text:
        found.append("the declined scenario is missing or gives an answer")
    if "Invoke-RepairScenario -Scenario 'accepted' -Answer 'Y'" not in text:
        found.append("the accepted scenario is missing or does not answer yes")
    for var in ("HP_PVW_KNOWN_IDEMPOTENT", "HP_TEST_REPAIR_ANSWER"):
        if "'set \"%s=\"'" % var not in text.split("function Invoke-RepairScenario", 1)[-1]:
            found.append("the bootstrap launch file does not clear %s" % var)
    ledger = text.find('with open(os.environ["REPAIR_LEDGER"], "a")')
    imported = text.find("importlib.import_module('colorama')")
    if ledger < 0 or imported < 0 or ledger > imported:
        found.append("the program does not write its ledger line before it imports colorama by name")
    if '"frozen": bool(getattr(sys, "frozen", False))' not in text:
        found.append("the ledger lines do not say whether the EXE or the interpreter started the program")
    if "importlib.import_module('colorama')" not in text or "colorama" not in text:
        found.append("the program no longer imports an installed package by a runtime name")
    if "$starts -ne 1" not in text:
        found.append("the declined scenario does not require exactly one start")
    if not live_lines or live_lines[-1] != "exit 0":
        found.append("the script does not end with exit 0 (last line: %r)" % (live_lines[-1] if live_lines else ""))
    if "if (-not $allPass) { exit 1 }" not in live_lines:
        found.append("the script never exits 1 when a row is red")
    return found


def step_block(text):
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if "selfapps_repair_consent.ps1" in block:
            return block
    return None


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_repair_consent.ps1"]
    found = []
    if "if: ${{ !cancelled() && matrix.mode == 'real' }}" not in block:
        found.append("the step is not limited to the real lane with !cancelled()")
    if "shell: pwsh" not in block:
        found.append("the step does not use shell: pwsh")
    if "continue-on-error" in block:
        found.append("the step has continue-on-error, so it cannot hold a pull request")
    for pattern in UPLOADS:
        if pattern not in text:
            found.append("the artifact upload does not list %s" % pattern)
    return found


def answering_problems(files):
    """files maps a script name to its text: each must answer yes (and the four environment scripts restore the old value)."""
    found = []
    for name, needle in ANSWERING_YES:
        text = files.get(name)
        if text is None:
            found.append("%s was not found" % name)
        elif needle not in text:
            found.append("%s does not hold %s, so its repair scenario would be declined" % (name, needle))
        elif needle.startswith("SetEnvironmentVariable") and "SetEnvironmentVariable('HP_TEST_REPAIR_ANSWER', $prevRepairAnswer)" not in text:
            found.append("%s does not put the previous value of HP_TEST_REPAIR_ANSWER back" % name)
    return found


def registry_problems(text):
    return ["%s is not in docs/agent-ndjson.md" % row_id for row_id, _req in ROWS if row_id not in text]


def read_scripts():
    return {name: (REPO / "tests" / name).read_text(encoding="utf-8") for name, _n in ANSWERING_YES}


class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BAT.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_the_labels_exist_once_in_the_order_the_other_checks_read(self):
        self.assertEqual(order_problems(self.batch), [])

    def test_the_question_has_the_shape_of_the_other_elective_offers(self):
        self.assertEqual(consent_problems(self.batch), [])

    def test_the_question_is_asked_once_before_the_first_start(self):
        self.assertEqual(call_site_problems(self.batch), [])

    def test_the_answer_is_kept_for_one_bootstrap(self):
        self.assertEqual(memory_problems(self.batch), [])

    def test_the_script_regexes_match_the_lines_the_batch_logs(self):
        block = "\n".join(live(cut_block(self.batch, CONSENT_START, CONSENT_END) or []))
        block = re.sub(r"%[A-Za-z_]+%", "x", block)
        for key, regex, _shown in LOG_LINES:
            self.assertRegex(block, regex, key)

    def test_the_script_has_its_rows_scenarios_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_real_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_scenarios_about_the_repair_itself_answer_yes(self):
        self.assertEqual(answering_problems(read_scripts()), [])

    def test_the_rows_are_registered(self):
        self.assertEqual(registry_problems(REGISTRY.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous_on_the_real_batch(self):
        block = cut_block(self.batch, CONSENT_START, CONSENT_END)
        self.assertIsNotNone(block)
        self.assertGreater(len(live(block)), 20)
        self.assertTrue(any(HEADING in ln and is_echo(ln) for ln in block))
        recover = cut_block(self.batch, RECOVER_START, RECOVER_END)
        self.assertTrue(any("pushd dist" in ln for ln in recover))
        self.assertTrue(any("defined HP_NUITKA_FALLBACK_USED" in ln for ln in recover))


def mutate(text, old, new, count=1):
    assert old in text, "the synthetic case needs %r to be in the text" % old
    return text.replace(old, new, count)


class BatchRulesCanFail(unittest.TestCase):
    """Each batch rule is shown to fail on a synthetic batch (GOOD_BATCH), so these run before run_setup.bat has the question."""

    def setUp(self):
        self.batch = GOOD_BATCH

    def _drop_signal(self, signal):
        block = cut_block(self.batch, CONSENT_START, CONSENT_END)
        text = "\n".join(block)
        pattern = re.compile(r"\bdefined\s+%s\b" % signal)
        changed = "\n".join(pattern.sub("defined HP_NEVER_SET", ln) if not is_comment(ln) else ln for ln in block)
        self.assertNotEqual(text, changed, "the synthetic case needs a line to change")
        return self.batch.replace(text, changed)

    def test_the_good_batch_passes_every_rule(self):
        self.assertEqual(order_problems(self.batch), [])
        self.assertEqual(consent_problems(self.batch), [])
        self.assertEqual(call_site_problems(self.batch), [])
        self.assertEqual(memory_problems(self.batch), [])

    def test_a_gate_that_ignores_one_signal_is_caught(self):
        for signal in SIGNALS + ("HP_TEST_REPAIR_ANSWER",):
            found = consent_problems(self._drop_signal(signal))
            self.assertTrue(any(signal in f for f in found), (signal, found))

    def test_a_signal_that_is_only_in_a_comment_does_not_count(self):
        text = mutate(self.batch, "if defined NOINPUT goto :hic_gate_auto", "rem if defined NOINPUT goto :hic_gate_auto")
        self.assertTrue(any("NOINPUT" in f for f in consent_problems(text)))

    def test_a_question_that_forgets_known_idempotent_is_caught(self):
        text = mutate(self.batch, "if defined HP_PVW_KNOWN_IDEMPOTENT goto :hic_idempotent", "rem removed")
        self.assertTrue(any("HP_PVW_KNOWN_IDEMPOTENT" in f for f in consent_problems(text)))

    def test_a_question_that_asks_again_is_caught(self):
        text = mutate(self.batch, "if defined HP_HIC_ANSWER goto :hic_remembered", "rem removed")
        self.assertTrue(any("earlier in the run" in f for f in consent_problems(text)))

    def test_a_reworded_heading_is_caught(self):
        text = mutate(self.batch, HEADING, "The first run failed, exit code")
        self.assertTrue(any("heading" in f for f in consent_problems(text)))

    def test_a_question_without_the_risk_is_caught(self):
        text = mutate(self.batch, MARKER, "that is all")
        self.assertTrue(any(MARKER in f for f in consent_problems(text)))

    def test_a_reworded_prompt_is_caught(self):
        text = mutate(self.batch, PROMPT, "Run it again?")
        self.assertTrue(any("choice line" in f for f in consent_problems(text)))

    def test_a_timeout_that_is_not_30_seconds_or_not_no_is_caught(self):
        for old, new in (("/T 30 /D N", "/T 60 /D N"), ("/T 30 /D N", "/T 30 /D Y")):
            text = mutate(self.batch, "choice /C YN /N " + old + " /M \"  " + PROMPT, "choice /C YN /N " + new + " /M \"  " + PROMPT)
            self.assertTrue(any("30 seconds" in f for f in consent_problems(text)), new)

    def test_ctrl_c_and_an_unreadable_answer_must_both_be_a_no(self):
        for needle, label in (("if not errorlevel 1 goto :hic_gate_declined", "Ctrl+C"), ("if errorlevel 2 goto :hic_gate_declined", "a no")):
            text = mutate(self.batch, needle, "rem removed")
            self.assertTrue(any("does not guard the yes" in f for f in consent_problems(text)), label)

    def test_a_missing_decline_log_line_is_caught(self):
        text = mutate(self.batch, "Repair loop: declined.", "Repair loop: no.")
        self.assertTrue(any("Repair loop: declined." in f for f in consent_problems(text)))

    def test_a_second_way_to_allow_is_caught(self):
        text = mutate(self.batch, "\n:hic_gate_auto\n", '\n:hic_gate_auto\nset "HP_HIC_ALLOWED=1"\n')
        self.assertTrue(any("expected 3" in f for f in consent_problems(text)))

    def test_a_block_that_stops_clearing_its_verdict_first_is_caught(self):
        text = mutate(self.batch, "set \"HP_HIC_ALLOWED=\"", "set \"HP_HIC_ALLOWED_OLD=\"")
        self.assertTrue(any("HP_HIC_ALLOWED" in f for f in consent_problems(text)))

    def test_a_missing_label_is_reported_not_skipped(self):
        text = self.batch.replace(CONSENT_START, ":hidden_import_asks")
        self.assertTrue(any("not found" in f for f in consent_problems(text)))
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))
        self.assertIsNone(cut_block("a\n:two\nb\n", ":one", ":two"))

    def test_the_block_may_reach_only_what_the_driver_defines(self):
        self.assertTrue(block_problems([":start", "goto :elsewhere"]))
        self.assertEqual(block_problems([":start", "goto :start", "call :log x"]), [])
        self.assertTrue(block_problems([":start", "echo %HP_NEW_THING%"]))
        self.assertTrue(block_problems([":start", "echo %HP_NEW_THING:~0,1%"]))
        self.assertEqual(block_problems([":start", "echo %HP_HIC_RAW:~0,1%", "rem %HP_IGNORED%"]), [])
        self.assertTrue(block_problems([":start", "echo done!"]))

    def test_a_call_site_that_moved_before_the_nuitka_skip_is_caught(self):
        recover = cut_block(self.batch, RECOVER_START, RECOVER_END)
        call = next(ln for ln in recover if ln.strip() == "call :hidden_import_consent")
        guard = next(ln for ln in recover if ln.strip() == "if not defined HP_HIC_ALLOWED exit /b 0")
        text = mutate(self.batch, call + "\n" + guard + "\n", "")
        text = mutate(text, ":hidden_import_recover\n", ":hidden_import_recover\n" + call + "\n" + guard + "\n")
        self.assertTrue(any("Nuitka" in f for f in call_site_problems(text)))

    def test_a_call_site_without_the_stop_is_caught(self):
        text = mutate(self.batch, "if not defined HP_HIC_ALLOWED exit /b 0", "rem removed")
        self.assertTrue(any("HP_HIC_ALLOWED exit /b 0" in f for f in call_site_problems(text)))

    def test_no_call_site_or_two_are_caught(self):
        none = mutate(self.batch, "call :hidden_import_consent", "rem call :hidden_import_consent")
        self.assertTrue(any("expected exactly 1" in f for f in call_site_problems(none)))
        two = self.batch.replace("call :hidden_import_consent", "call :hidden_import_consent\ncall :hidden_import_consent", 1)
        self.assertTrue(any("expected exactly 1" in f for f in call_site_problems(two)))

    def test_a_third_caller_of_the_loop_is_caught(self):
        text = self.batch + "\nif defined X call :hidden_import_recover\n"
        self.assertTrue(any("expected the 2 known sites" in f for f in call_site_problems(text)))

    def test_an_answer_that_is_never_cleared_or_cleared_inside_is_caught(self):
        no_clear = mutate(self.batch, 'set "HP_HIC_ANSWER="', "rem removed")
        self.assertTrue(memory_problems(no_clear))
        inside = mutate(self.batch, 'set "HP_HIC_ALLOWED="\n', 'set "HP_HIC_ALLOWED="\nset "HP_HIC_ANSWER="\n')
        self.assertTrue(memory_problems(inside))

    def test_labels_that_are_missing_or_in_the_wrong_order_are_caught(self):
        renamed = self.batch.replace(":warn_user_code_launch\n", ":warn_user_code_launch_x\n").replace(":warn_user_code_launch\r\n", ":warn_user_code_launch_x\r\n")
        self.assertNotEqual(renamed, self.batch, "the synthetic case needs a label to rename")
        self.assertTrue(any("appears 0 time(s)" in f for f in order_problems(renamed)))
        swapped = "\n".join([":hidden_import_consent", "x", ":run_exe_smokerun", ":hidden_import_recover", "y", ":warn_user_code_launch"])
        self.assertTrue(any("not in the order" in f for f in order_problems(swapped)))



class ScriptRulesCanFail(unittest.TestCase):
    """The same for the rules that read the row script, the workflow step, the other scripts and the registry."""

    def setUp(self):
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_a_row_id_that_is_not_literal_is_caught(self):
        text = mutate(self.script, "id = 'self.repair.gate.cilane'; req = 'REQ-018.2'", "id = $cilaneId; req = 'REQ-018.2'")
        self.assertTrue(any("self.repair.gate.cilane" in f for f in script_problems(text)))

    def test_a_row_that_stops_naming_its_shall_is_caught(self):
        text = mutate(self.script, "id = 'self.repair.gate.idempotent'; req = 'REQ-005.13'", "id = 'self.repair.gate.idempotent'; req = 'REQ-018'")
        self.assertTrue(any("self.repair.gate.idempotent" in f for f in script_problems(text)))
        text = mutate(self.script, "id = 'self.repair.consent.declined'; req = 'REQ-018.1, REQ-018.2'", "id = 'self.repair.consent.declined'; req = 'REQ-018.2'")
        self.assertTrue(any("self.repair.consent.declined" in f for f in script_problems(text)))

    def test_a_missing_scenario_or_wording_is_caught(self):
        text = mutate(self.script, "Name = 'once_no'", "Name = 'later'")
        self.assertTrue(any("once_no" in f for f in script_problems(text)))
        text = mutate(self.script, "$markerText  = 'running it twice could cause harm'", "$markerText  = 'something else'")
        self.assertTrue(any("marker" in f for f in script_problems(text)))
        text = mutate(self.script, "declined   = 'Repair loop: declined\\.'", "declined   = 'declined'")
        self.assertTrue(any("log pattern for declined" in f for f in script_problems(text)))

    def test_open_standard_input_is_caught(self):
        text = mutate(self.script, "call ~driver.bat > ~driver_console.txt 2>&1 < nul", "call ~driver.bat > ~driver_console.txt 2>&1")
        self.assertTrue(any("driver launch" in f for f in script_problems(text)))
        text = mutate(self.script, "call run_setup.bat > $consoleName 2>&1 < nul", "call run_setup.bat > $consoleName 2>&1")
        self.assertTrue(any("bootstrap launch" in f for f in script_problems(text)))

    def test_a_missing_time_limit_kill_is_caught(self):
        text = mutate(self.script, "taskkill.exe /F /T", "taskkill.exe /F")
        self.assertTrue(any("taskkill" in f for f in script_problems(text)))

    def test_a_bootstrap_that_may_inherit_an_answer_is_caught(self):
        text = mutate(self.script, "$launch = @('@echo off', 'set \"HP_PVW_KNOWN_IDEMPOTENT=\"', 'set \"HP_TEST_REPAIR_ANSWER=\"')", "$launch = @('@echo off')")
        found = script_problems(text)
        self.assertTrue(any("HP_PVW_KNOWN_IDEMPOTENT" in f for f in found), found)

    def test_a_program_that_writes_its_ledger_line_after_it_can_fail_is_caught(self):
        # the ledger line must come first, or a start that fails at once would not be counted
        ledger_open = 'with open(os.environ["REPAIR_LEDGER"], "a")'
        text = mutate(self.script, ledger_open, "X_LEDGER", 1) + "\n" + ledger_open
        self.assertTrue(any("ledger line before" in f for f in script_problems(text)))

    def test_a_script_without_its_exit_codes_is_caught(self):
        no_one = mutate(self.script, "if (-not $allPass) { exit 1 }", "")
        self.assertTrue(any("never exits 1" in f for f in script_problems(no_one)))
        no_zero = self.script.rstrip().rsplit("exit 0", 1)[0]
        self.assertTrue(any("does not end with exit 0" in f for f in script_problems(no_zero)))

    def test_a_step_that_is_not_real_only_is_caught(self):
        block = step_block(self.workflow)
        mutated = self.workflow.replace(block, block.replace("matrix.mode == 'real'", "matrix.mode == 'uv'"))
        self.assertTrue(any("real lane" in f for f in workflow_problems(mutated)))

    def test_a_step_that_cannot_fail_is_caught(self):
        block = step_block(self.workflow)
        mutated = self.workflow.replace(block, block.replace("shell: pwsh", "shell: pwsh\n        continue-on-error: true"))
        self.assertTrue(any("continue-on-error" in f for f in workflow_problems(mutated)))

    def test_a_missing_step_or_upload_is_caught(self):
        mutated = self.workflow.replace("selfapps_repair_consent.ps1", "something_else.ps1")
        self.assertEqual(workflow_problems(mutated), ["no step runs tests\\selfapps_repair_consent.ps1"])
        mutated = self.workflow.replace("tests/~selftest_repair_*/~repair_ledger.jsonl", "tests/~selftest_repair_*/~other.jsonl")
        self.assertTrue(any("~repair_ledger.jsonl" in f for f in workflow_problems(mutated)))

    def test_a_scenario_that_would_be_declined_is_caught(self):
        files = read_scripts()
        files["selfapps_hidden_import.ps1"] = files["selfapps_hidden_import.ps1"].replace("'HP_TEST_REPAIR_ANSWER', 'Y'", "'HP_TEST_REPAIR_ANSWER', 'N'")
        self.assertTrue(any("selfapps_hidden_import.ps1" in f for f in answering_problems(files)))
        files = read_scripts()
        files["selfapps_layered_e2e.ps1"] = files["selfapps_layered_e2e.ps1"].replace("SetEnvironmentVariable('HP_TEST_REPAIR_ANSWER', $prevRepairAnswer)", "")
        self.assertTrue(any("put the previous value" in f for f in answering_problems(files)))
        files = read_scripts()
        files["selfapps_hint_norerun.ps1"] = files["selfapps_hint_norerun.ps1"].replace("$vars['HP_TEST_REPAIR_ANSWER'] = 'Y'", "")
        self.assertTrue(any("selfapps_hint_norerun.ps1" in f for f in answering_problems(files)))

    def test_an_unregistered_row_is_caught(self):
        registry = REGISTRY.read_text(encoding="utf-8").replace("self.repair.gate.once", "self.repair.gate.other")
        self.assertEqual(registry_problems(registry), ["self.repair.gate.once is not in docs/agent-ndjson.md"])


if __name__ == "__main__":
    unittest.main()
