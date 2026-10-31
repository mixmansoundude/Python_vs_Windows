"""Item 94b: in a non-interactive run the four elective offers decline without waiting (README REQ-018.9).

REQ-018.9 [critical]: the bootstrapper shall, in a non-interactive run, decline each elective offer (the
post-execution checkpoint, the optimized build, the missing-package install and the last-chance offer) without
waiting for input. The README Terms define a non-interactive run as one where NOINPUT, HP_NONINTERACTIVE or
HP_CI_LANE is set. Every CI lane sets HP_CI_LANE, so a gate that read only that variable passed every older row.

What really happens in a bootstrap is checked by tests/selfapps_offers_noninteractive.ps1 (rows self.offers.noinput,
.nonint, .cilane and .control, real lane). These rules read run_setup.bat, that script and batch-check.yml as text,
so a gate that drops a signal, a reworded prompt or a step that stops gating fails here with a sentence, before a
Windows run is needed. Synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_offers_noninteractive.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
README = REPO / "README.md"

SIGNALS = ("HP_CI_LANE", "NOINPUT", "HP_NONINTERACTIVE")

# (name, heading echoed before the gate, the prompt text only the interactive read prints,
#  the regex the PowerShell script uses for the decline line, the log texts the batch has to hold,
#  the sample text a log line must match the regex on)
OFFERS = (
    ("checkpoint", "Verification finished -- see the Run Status above.", "Run again via the interpreter now? [Y/N]",
     r"post-execution checkpoint \((exe|interpreter)\): declined", ("post-execution checkpoint (", "): declined"),
     "REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution)."),
    ("optimized build", "Want to build an optimized version too?", "Build the optimized version now? [Y/N]",
     r"Optimized build: declined", ("Optimized build: declined",),
     "Optimized build: declined."),
    ("runtime install", "Your program asked for packages that are not installed:", "Install and check?",
     r"Runtime install: declined\. Nothing was changed", ("Runtime install: declined. Nothing was changed",),
     "Runtime install: declined. Nothing was changed."),
    ("last chance", "Your program stopped with an error, exit code", "Your choice, W or C or N",
     r"Last chance: automated run, no question asked; keeping this build",
     ("Last chance: automated run, no question asked; keeping this build", "Last chance: neither; keeping this build"),
     "Last chance: automated run, no question asked; keeping this build."),
)

IDS = ("self.offers.noinput", "self.offers.nonint", "self.offers.cilane", "self.offers.control")
READ = re.compile(r"(?i)\b(set /p|choice)\b")


def lines_of(text):
    return text.replace("\r\n", "\n").split("\n")


def is_comment(line):
    return re.match(r"(?i)\s*(rem\b|::)", line) is not None


def is_echo(line):
    return not is_comment(line) and re.search(r"(?i)(^|\s)echo\b", line) is not None


def gate_problems(text):
    """For each offer: the heading is an echo line, the interactive read follows it, the three signals are tested
    on live lines between the two, and the decline log lines exist."""
    lines = lines_of(text)
    found = []
    for name, heading, prompt, _regex, declines, _sample in OFFERS:
        head = next((i for i, ln in enumerate(lines) if heading in ln and is_echo(ln)), -1)
        if head < 0:
            found.append("%s: heading %r not found as an echo line" % (name, heading))
            continue
        read = next((i for i in range(head, len(lines))
                     if prompt in lines[i] and READ.search(lines[i]) and not is_comment(lines[i])), -1)
        if read < 0:
            found.append("%s: no set /p or choice line holding %r after the heading" % (name, prompt))
            continue
        between = [ln for ln in lines[head:read] if not is_comment(ln)]
        for signal in SIGNALS:
            if not any(re.search(r"\bdefined\s+%s\b" % signal, ln) for ln in between):
                found.append("%s: no live line between the heading and the read tests 'defined %s'" % (name, signal))
        for decline in declines:
            if not any(decline in ln and "call :log" in ln and not is_comment(ln) for ln in lines):
                found.append("%s: no 'call :log' line says %r" % (name, decline))
    return found


def regex_problems(text):
    """The decline regexes of the PowerShell script match the log lines the batch really writes (a %VAR% in the
    line stands for a short word)."""
    found = []
    logs = [re.sub(r"%[A-Za-z_]+%", "exe", ln) for ln in lines_of(text) if "call :log" in ln and not is_comment(ln)]
    for name, _heading, _prompt, regex, _declines, _sample in OFFERS:
        if not any(re.search(regex, ln) for ln in logs):
            found.append("%s: the script regex %r matches no log line of the batch" % (name, regex))
    return found


def script_problems(text):
    found = []
    lines = lines_of(text)
    live = [ln.strip() for ln in lines if ln.strip() and not ln.strip().startswith("#")]
    for row_id in IDS:
        if not re.search(r"Write-NdjsonRow \(\[ordered\]@\{\s*id = '%s'; req = 'REQ-018\.9'" % re.escape(row_id), text):
            found.append("%s is not a literal id with req 'REQ-018.9' at a Write-NdjsonRow call" % row_id)
    for name, heading, prompt, regex, declines, _sample in OFFERS:
        for what, literal in (("heading", heading), ("prompt", prompt)):
            if "'%s'" % literal not in text:
                found.append("%s: the script does not hold the %s %r" % (name, what, literal))
        if "'%s'" % regex not in text:
            found.append("%s: the script does not hold the decline regex %r" % (name, regex))
    if "'Last chance: neither; keeping this build'" not in text:
        found.append("the script does not hold the answered-question line of the last-chance offer")
    # one signal per scenario, exactly as the README defines the term
    for scenario, set_line, flag in (("noinput", 'set "NOINPUT=1"', "NOINPUT"),
                                     ("nonint", 'set "HP_NONINTERACTIVE=1"', "HP_NONINTERACTIVE"),
                                     ("cilane", 'set "HP_CI_LANE=offers"', "HP_CI_LANE")):
        pattern = r"-ExpectFlags @\('%s'\) -Scenario '%s' -SetLines @\('%s'\)" % (flag, scenario, re.escape(set_line))
        if not re.search(pattern, text):
            found.append("scenario %s does not set exactly %s" % (scenario, flag))
    if not re.search(r"-Mode 'control' -ExpectFlags @\(\) -Scenario 'control' -SetLines @\(\)", text):
        found.append("the control scenario is missing or sets a signal")
    if "call run_setup.bat > ~offers_console.log 2>&1 < nul" not in text:
        found.append("the wrapper line that starts the bootstrapper does not close standard input (< nul)")
    if "taskkill.exe /F /T" not in text:
        found.append("a run past the time limit is not stopped with taskkill /F /T")
    if "Remove-Item -LiteralPath ('Env:' + $name)" not in text:
        found.append("the flags are not removed with the Env: drive")
    if "'set \"' + $_ + '=\"'" not in text:
        found.append("the wrapper does not clear each flag again with set NAME=")
    if not re.search(r"set HP_> ~offers_env\.txt 2>nul", text) or not re.search(r"set NOINPUT>> ~offers_env\.txt 2>nul", text):
        found.append("the verdict listing of the flags after the scenario's own set line is missing")
    if "sys.exit(3)" not in text:
        found.append("the lc program no longer exits 3")
    if '"".join(("xlsx", "writer"))' not in text:
        found.append("the rti program no longer builds the module name at run time")
    if text.count('~offers_ledger.jsonl') < 3:
        found.append("a program or the reader of the ledger is missing")
    if '"frozen": bool(getattr(sys, "frozen", False))' not in text:
        found.append("the ledger lines do not say whether the EXE or the interpreter started the program")
    if not live or live[-1] != "exit 0":
        found.append("the script does not end with exit 0 (last line: %r)" % (live[-1] if live else ""))
    if "if (-not $allPass) { exit 1 }" not in live:
        found.append("the script never exits 1 when a row is red")
    return found


def step_block(text):
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if "selfapps_offers_noninteractive.ps1" in block:
            return block
    return None


UPLOADS = (
    "tests/~selftest_offers_*/~offers_console.log",
    "tests/~selftest_offers_*/~offers_env.txt",
    "tests/~selftest_offers_*/~offers_env0.txt",
    "tests/~selftest_offers_*/~offers_ledger.jsonl",
    "tests/~selftest_offers_*/~setup.log",
    "tests/~selftest_offers_*/~bootstrap.status.json",
)


def workflow_problems(text):
    block = step_block(text)
    if block is None:
        return ["no step runs tests\\selfapps_offers_noninteractive.ps1"]
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


class RealFiles(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_every_offer_reads_all_three_signals_before_it_asks(self):
        self.assertEqual(gate_problems(self.batch), [])

    def test_the_script_regexes_match_the_lines_the_batch_logs(self):
        self.assertEqual(regex_problems(self.batch), [])

    def test_the_sample_lines_match_their_regexes(self):
        for name, _heading, _prompt, regex, _declines, sample in OFFERS:
            self.assertRegex(sample, regex, name)

    def test_the_script_has_its_rows_scenarios_and_exit_codes(self):
        self.assertEqual(script_problems(self.script), [])

    def test_the_step_gates_the_real_lane_and_uploads_the_evidence(self):
        self.assertEqual(workflow_problems(self.workflow), [])

    def test_the_signals_are_the_ones_the_readme_defines(self):
        readme = README.read_text(encoding="utf-8")
        self.assertIn("`NOINPUT`, `HP_NONINTERACTIVE` or `HP_CI_LANE` is set", readme)
        self.assertEqual(sorted(SIGNALS), sorted(["NOINPUT", "HP_NONINTERACTIVE", "HP_CI_LANE"]))

    def test_the_rows_are_registered(self):
        registry = (REPO / "docs" / "agent-ndjson.md").read_text(encoding="utf-8")
        for row_id in IDS:
            self.assertIn(row_id, registry)

    def test_the_offers_named_by_the_readme_are_the_ones_checked(self):
        readme = README.read_text(encoding="utf-8")
        flat = re.sub(r"\s+", " ", readme)
        self.assertIn("(the post-execution checkpoint, the optimized build, the missing-package install and the last-chance offer)", flat)
        self.assertEqual(len(OFFERS), 4)

    def test_the_checks_are_not_vacuous_on_the_real_batch(self):
        # every heading and read line is found, so an empty problem list means the signals were really tested
        lines = lines_of(self.batch)
        for name, heading, prompt, _regex, _declines, _sample in OFFERS:
            self.assertTrue(any(heading in ln and is_echo(ln) for ln in lines), name)
            self.assertTrue(any(prompt in ln and READ.search(ln) for ln in lines), name)


class EachRuleCanFail(unittest.TestCase):
    def setUp(self):
        self.batch = BATCH.read_text(encoding="utf-8", errors="replace")
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def _drop_signal_from_gate(self, signal, heading, read_hint):
        """Rename the tests of one signal inside one gate to a variable nobody sets."""
        lines = lines_of(self.batch)
        head = next(i for i, ln in enumerate(lines) if heading in ln and is_echo(ln))
        read = next(i for i in range(head, len(lines)) if read_hint in lines[i] and READ.search(lines[i]))
        changed = 0
        for i in range(head, read):
            if re.search(r"\bdefined\s+%s\b" % signal, lines[i]) and not is_comment(lines[i]):
                lines[i] = re.sub(r"\bdefined\s+%s\b" % signal, "defined HP_NEVER_SET", lines[i])
                changed += 1
        self.assertGreater(changed, 0, "the synthetic case needs a line to change")
        return "\n".join(lines)

    def test_a_gate_that_ignores_noinput_is_caught(self):
        text = self._drop_signal_from_gate("NOINPUT", "Verification finished", "Run again via the interpreter now")
        self.assertTrue(any("checkpoint" in f and "NOINPUT" in f for f in gate_problems(text)))

    def test_a_gate_that_ignores_hp_noninteractive_is_caught(self):
        text = self._drop_signal_from_gate("HP_NONINTERACTIVE", "Want to build an optimized version too", "Build the optimized version now")
        self.assertTrue(any("optimized build" in f and "HP_NONINTERACTIVE" in f for f in gate_problems(text)))

    def test_a_gate_that_ignores_hp_ci_lane_is_caught(self):
        text = self._drop_signal_from_gate("HP_CI_LANE", "Your program asked for packages", "Install and check")
        self.assertTrue(any("runtime install" in f and "HP_CI_LANE" in f for f in gate_problems(text)))

    def test_the_last_chance_gate_is_held_to_the_same_rule(self):
        text = self._drop_signal_from_gate("NOINPUT", "Your program stopped with an error", "Your choice, W or C or N")
        self.assertTrue(any("last chance" in f and "NOINPUT" in f for f in gate_problems(text)))

    def test_a_signal_that_is_only_in_a_comment_does_not_count(self):
        text = self._drop_signal_from_gate("NOINPUT", "Verification finished", "Run again via the interpreter now")
        lines = lines_of(text)
        head = next(i for i, ln in enumerate(lines) if "Verification finished" in ln and is_echo(ln))
        at = next(i for i in range(head, len(lines)) if "defined HP_NEVER_SET" in lines[i])
        lines[at] = "rem " + lines[at].strip().replace("HP_NEVER_SET", "NOINPUT")
        self.assertIn("defined NOINPUT", lines[at])
        self.assertTrue(any("checkpoint" in f and "NOINPUT" in f for f in gate_problems("\n".join(lines))))

    def test_a_reworded_heading_is_caught(self):
        text = self.batch.replace("Want to build an optimized version too?", "Want an optimized build as well?")
        self.assertTrue(any("optimized build: heading" in f for f in gate_problems(text)))

    def test_a_reworded_prompt_is_caught(self):
        text = self.batch.replace("Run again via the interpreter now? [Y/N]", "Run it again? [Y/N]")
        self.assertTrue(any("checkpoint: no set /p or choice line" in f for f in gate_problems(text)))

    def test_a_missing_decline_log_line_is_caught(self):
        text = self.batch.replace("Optimized build: declined.", "Optimized build: skipped.")
        self.assertTrue(any("optimized build: no 'call :log' line" in f for f in gate_problems(text)))

    def test_a_decline_regex_that_matches_nothing_is_caught(self):
        text = self.batch.replace("Last chance: automated run, no question asked", "Last chance: no question was asked")
        found = regex_problems(text)
        self.assertTrue(any("last chance" in f for f in found), found)

    def test_a_row_id_that_is_not_literal_is_caught(self):
        text = self.script.replace("id = 'self.offers.cilane'; req = 'REQ-018.9'", "id = $cilaneId; req = 'REQ-018.9'")
        self.assertTrue(any("self.offers.cilane" in f for f in script_problems(text)))

    def test_a_row_that_stops_naming_the_shall_is_caught(self):
        text = self.script.replace("id = 'self.offers.nonint'; req = 'REQ-018.9'", "id = 'self.offers.nonint'; req = 'REQ-018'")
        self.assertTrue(any("self.offers.nonint" in f for f in script_problems(text)))

    def test_a_scenario_that_sets_two_signals_is_caught(self):
        text = self.script.replace("-SetLines @('set \"NOINPUT=1\"')", "-SetLines @('set \"NOINPUT=1\"', 'set \"HP_CI_LANE=x\"')")
        self.assertTrue(any("scenario noinput" in f for f in script_problems(text)))

    def test_a_control_that_sets_a_signal_is_caught(self):
        text = self.script.replace("-Scenario 'control' -SetLines @()", "-Scenario 'control' -SetLines @('set \"NOINPUT=1\"')")
        self.assertTrue(any("control scenario" in f for f in script_problems(text)))

    def test_open_standard_input_is_caught(self):
        text = self.script.replace(" < nul'", "'")
        self.assertTrue(any("standard input" in f for f in script_problems(text)))

    def test_a_missing_time_limit_kill_is_caught(self):
        text = self.script.replace("taskkill.exe /F /T", "taskkill.exe /F")
        self.assertTrue(any("taskkill" in f for f in script_problems(text)))

    def test_a_program_that_no_longer_fails_is_caught(self):
        text = self.script.replace("sys.exit(3)", "sys.exit(0)")
        self.assertTrue(any("exits 3" in f for f in script_problems(text)))

    def test_a_script_without_its_exit_codes_is_caught(self):
        no_one = self.script.replace("if (-not $allPass) { exit 1 }", "")
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

    def test_a_missing_step_is_caught(self):
        mutated = self.workflow.replace("selfapps_offers_noninteractive.ps1", "something_else.ps1")
        self.assertEqual(workflow_problems(mutated), ["no step runs tests\\selfapps_offers_noninteractive.ps1"])

    def test_a_missing_upload_pattern_is_caught(self):
        mutated = self.workflow.replace("tests/~selftest_offers_*/~offers_ledger.jsonl", "tests/~selftest_offers_*/~other.jsonl")
        self.assertTrue(any("~offers_ledger.jsonl" in f for f in workflow_problems(mutated)))


if __name__ == "__main__":
    unittest.main()
