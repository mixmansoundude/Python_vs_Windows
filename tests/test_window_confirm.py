"""Tests for the window-app question of the last-chance offer, CLAUDE.md Item 82 slice 2 (README REQ-018).

A window app stays silent on the console, so the EXE verification run is force-stopped after about 30 seconds
and reads as exit -1. On the conda tier that the provider cascade reached, the bootstrapper asks once whether the
window opened and worked, because the run can never end in a clean exit 0 and would never count as a pass. Exit -1
alone does not prove a stop: the runner also leaves HP_EXE_EXIT at -1 when it could not be written or never wrote
its result, and a program may exit with -1 by itself. So the question is gated on a marker file that only
tools/exe_smokerun.ps1 writes, in the branch that kills the process. These tests pin where the marker is
cleared, read and reset and the order of the gates, since a wrong order is silent: the question appears when it
should not, or never.

Item 124 (README REQ-018.30, the question says the check stops the program 30 seconds after it started): until then the shall
was a wording pin of this file, and the row that raises the question (self.lastchance.window_yes) only looked for the words
"Did it open and work". The row now judges the question's own console text, line by line and exactly, with the function
Get-WindowQuestionProblems of tests/selfapps_lastchance.ps1. The classes at the end of this file hold what that needs to stay
honest: the three lines the judge expects are the echo lines of :lc_window (a reworded statement fails here, with the line, before a
Windows run), the judge is run through a real pwsh on synthetic consoles (a good one, and one for each way to be wrong), and the
row, its tag and its verdict are pinned as text. Each rule has a case that proves it can fail. That the stop really comes after 30
seconds is a different row (self.launch.cap.silent, REQ-018.6), which runs with the default wait.
"""
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import PWSH, case, mutate, norm, run_cases  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
LASTCHANCE = REPO / "tests" / "selfapps_lastchance.ps1"
SHALL_TRACE = REPO / "tests" / "test_req_shall_trace.py"


class RunnerMarkerWiring(unittest.TestCase):
    def setUp(self):
        self.bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        a = self.bat.index("\n:run_exe_smokerun\n")
        self.run = self.bat[a:self.bat.index("\n:smokerun_ndjson\n", a)]

    def test_the_marker_is_cleared_before_the_launch(self):
        launch = self.run.index('powershell -NoProfile -ExecutionPolicy Bypass -File "~exe_smokerun.ps1"')
        clear = self.run.index('del "~smokerun_killed.txt"')
        self.assertLess(clear, launch)
        self.assertLess(self.run.index('set "HP_EXE_KILLED_SILENT="'), launch)

    def test_the_flag_comes_only_from_the_marker_file_after_the_launch(self):
        launch = self.run.index('powershell -NoProfile -ExecutionPolicy Bypass -File "~exe_smokerun.ps1"')
        read = self.run.index('if exist "~smokerun_killed.txt"', launch)
        self.assertIn('set "HP_EXE_KILLED_SILENT=1"', self.run[read:read + 200])
        # the exit code alone must never set it
        for line in self.run.splitlines():
            if "HP_EXE_KILLED_SILENT=1" in line:
                self.assertNotIn("HP_EXE_EXIT", line)
        self.assertEqual(self.run.count('set "HP_EXE_KILLED_SILENT=1"'), 1)

    def test_the_marker_is_removed_once_read(self):
        read = self.run.index('if exist "~smokerun_killed.txt"', self.run.index("~exe_smokerun.ps1\"\n"))
        self.assertIn('del "~smokerun_killed.txt"', self.run[read:read + 300])

    def test_a_failed_emit_leaves_the_flag_unset(self):
        # when ~exe_smokerun.ps1 cannot be written nothing ran, so no marker can exist: the read is inside the
        # branch that launched the runner, not after the if/else
        emit_fail = self.run.index("could not emit ~exe_smokerun.ps1")
        read = self.run.index('set "HP_EXE_KILLED_SILENT=1"')
        self.assertGreater(read, emit_fail)

    def test_each_fresh_build_resets_the_flag_with_the_timed_out_flag(self):
        i = self.bat.index('    set "HP_EXE_TIMEDOUT_SILENT="\n')
        self.assertIn('set "HP_EXE_KILLED_SILENT="', self.bat[i:i + 120])


class WindowQuestionWiring(unittest.TestCase):
    def setUp(self):
        self.bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        i = re.search(r"(?m)^:last_chance_offer", self.bat).start()
        self.block = self.bat[i:self.bat.index("\n:lc_row", i)]

    def _between(self, start, end):
        a = self.block.index("\n" + start + "\n") + 1
        return self.block[a:self.block.index("\n" + end + "\n", a)]

    def test_minus_one_is_routed_to_the_window_question_not_dropped(self):
        head = self.block[:self.block.index('set "HP_LC_REASON="')]
        self.assertIn('if "%HP_LC_EXIT%"=="-1" goto :lc_window', head)
        self.assertNotIn('if "%HP_LC_EXIT%"=="-1" goto :lc_cleanup', self.block)

    def test_every_condition_is_checked_before_the_question(self):
        body = self._between(":lc_window", ":lc_window_gate_override")
        self.assertIn('if /i not "%HP_ENV_MODE%"=="conda" goto :lc_cleanup', body)
        self.assertIn("if not defined HP_CASCADE_TRIED_UV goto :lc_cleanup", body)
        self.assertIn("if not defined HP_EXE_KILLED_SILENT goto :lc_cleanup", body)
        self.assertIn("if defined HP_CASCADE_APPROVED goto :lc_cleanup", body)
        for needle in ("if /i not", "if not defined HP_CASCADE_TRIED_UV", "if not defined HP_EXE_KILLED_SILENT",
                       "if defined HP_CASCADE_APPROVED"):
            self.assertLess(body.index(needle), body.index("Did it open and work"))

    def test_the_question_says_why_it_is_asked_and_what_a_blank_answer_means(self):
        body = self._between(":lc_window", ":lc_window_gate_override")
        self.assertIn("about 30 seconds", body)
        self.assertIn("A program with a window prints nothing", body)
        self.assertIn("Did it open and work? [y/N]", self.block)
        self.assertNotIn("choice /", self.block)

    def test_the_gate_checks_the_override_first_then_the_forced_read_then_the_automated_guards(self):
        order = [
            "if defined HP_TEST_WINDOWOK_ANSWER goto :lc_window_gate_override",
            "if defined HP_TEST_FORCE_INTERACTIVE_WINDOWOK goto :lc_window_gate_interactive",
            "if defined HP_CI_LANE goto :lc_window_gate_auto",
            "if defined NOINPUT goto :lc_window_gate_auto",
            "if defined HP_NONINTERACTIVE goto :lc_window_gate_auto",
            "goto :lc_window_gate_interactive",
        ]
        lines = self.block.splitlines()
        at = [lines.index(x) for x in order]
        self.assertEqual(at, list(range(at[0], at[0] + len(order))))

    def test_the_prompt_text_is_echoed_before_the_gate(self):
        gate = self.block.index("if defined HP_TEST_WINDOWOK_ANSWER")
        self.assertLess(self.block.index("Did it open and work"), gate)

    def test_only_an_explicit_yes_records_anything(self):
        resolve = self._between(":lc_window_gate_resolve", ":lc_window_yes")
        self.assertIn('if /I "%HP_LC_CHOICE%"=="Y" goto :lc_window_yes', resolve)
        # everything else, a bare Enter included, is a no
        self.assertIn("goto :lc_window_no", resolve)
        no = self._between(":lc_window_no", ":lc_not_offered") if False else self.block[self.block.index("\n:lc_window_no\n"):]
        no = no[:no.index("goto :lc_cleanup")]
        self.assertNotIn("HP_LC_PASS", no)
        self.assertIn("Last chance: window not confirmed", no)

    def test_a_yes_records_the_pass_type_and_never_starts_a_cascade(self):
        a = self.block.index("\n:lc_window_yes\n")
        yes = self.block[a:self.block.index("goto :lc_cleanup", a)]
        self.assertIn('set "HP_LC_PASS=user_confirmed"', yes)
        self.assertIn('set "HP_LC_STATE=window_confirmed"', yes)
        self.assertIn("Last chance: you said the window opened and worked", yes)
        self.assertNotIn("HP_CASCADE_APPROVED", yes)

    def test_the_automated_branch_asks_nothing_and_records_nothing(self):
        a = self.block.index("\n:lc_window_gate_auto\n")
        auto = self.block[a:self.block.index("goto :lc_cleanup", a)]
        self.assertIn('set "HP_LC_STATE=window_automated"', auto)
        self.assertIn("Last chance: automated run, no window question asked", auto)
        self.assertNotIn("HP_LC_PASS", auto)
        self.assertNotIn("set /p", auto)

    def test_the_state_is_cleaned_up_with_the_rest(self):
        # the shared cleanup already clears HP_LC_STATE, HP_LC_CHOICE, HP_LC_RAW and HP_LC_PASS
        a = self.block.index("\n:lc_cleanup\n")
        tail = self.block[a:self.block.index("exit /b 0", a)]
        for v in ("HP_LC_STATE", "HP_LC_CHOICE", "HP_LC_RAW", "HP_LC_PASS"):
            self.assertIn('set "%s="' % v, tail)


# --- Item 124: the question's text as the user sees it (README REQ-018.30) ---------------------------------------------------------

STATEMENT = "*** Your program printed nothing, so the check stopped it after about 30 seconds. ***"
REMINDER = "*** A program with a window prints nothing in this console, so that alone does not mean it failed. ***"
QUESTION = "*** Did it open and work? [y/N] ***"
JUDGES = ["Get-WindowQuestionProblems"]
ROW_TAG = "REQ-018.28, REQ-018.29, REQ-018.30"


def real_question_lines(bat_text):
    """The echo lines of :lc_window that make the question, as the console shows them (the word echo and its space removed)."""
    start = re.search(r"(?m)^:lc_window\r?$", bat_text).start()
    block = norm(bat_text[start:bat_text.index('set "HP_LC_CHOICE="', start)])
    return [ln[len("echo "):] for ln in block.split("\n") if ln.startswith("echo ***")]


def judge_expected_lines(script_text):
    """The three lines the judge function of the script compares the console with."""
    m = re.search(r"function Get-WindowQuestionProblems \{.*?\$expected = @\((.*?)\)\n", norm(script_text), re.S)
    return re.findall(r"'([^']*)'", m.group(1)) if m else []


def wording_problems(bat_text, script_text):
    """The judge's three lines are the three echo lines of the question, in the same order."""
    real = real_question_lines(bat_text)
    want = judge_expected_lines(script_text)
    found = []
    if real != want:
        found.append("the lines of the question in :lc_window are %r, the judge of selfapps_lastchance.ps1 expects %r" % (real, want))
    if want != [STATEMENT, REMINDER, QUESTION]:
        found.append("the judge expects %r, this test pins %r" % (want, [STATEMENT, REMINDER, QUESTION]))
    return found


def script_problems(script_text):
    """The row that raises the question names REQ-018.30 and fails when the question's text is wrong."""
    t = norm(script_text)
    found = []
    m = re.search(r"id\s*=\s*'self\.lastchance\.window_yes'\s*\n\s*req\s*=\s*'([^']*)'", t)
    if not m:
        found.append("the row self.lastchance.window_yes with a literal req tag is missing")
    elif m.group(1) != ROW_TAG:
        found.append("self.lastchance.window_yes must carry the literal req tag %r, found %r" % (ROW_TAG, m.group(1)))
    if t.count("$wyQuestion = @(Get-WindowQuestionProblems -ConsoleText $wy.Console)") != 1:
        found.append("the verdict of window_yes must judge the console of its own run: $wyQuestion = @(Get-WindowQuestionProblems -ConsoleText $wy.Console)")
    pass_line = next((ln for ln in t.split("\n") if ln.strip().startswith("$wyPass = ")), "")
    if "($wyQuestion.Count -eq 0)" not in pass_line:
        found.append("$wyPass of window_yes must require ($wyQuestion.Count -eq 0)")
    for other in ("window_enter", "window_auto", "window_selfexit"):
        if re.search(r"id\s*=\s*'self\.lastchance\.%s'\s*\n\s*req\s*=\s*'[^']*REQ-018\.30" % other, t):
            found.append("%s names REQ-018.30, which only window_yes judges" % other)
    return found


def shall_list_problems(text):
    if re.search(r'^\s*"REQ-018\.30":', text, re.M):
        return ["REQ-018.30 is still listed in UNTRACED_SHALLS although self.lastchance.window_yes is tagged with it"]
    return []


def good_console(**over):
    parts = dict(before="[INFO] Running entry script smoke test via packaged EXE.\r\n[STATUS] Run Status: TIMED OUT (hit the ~30s verification cap)",
                 statement=STATEMENT, reminder=REMINDER, question=QUESTION, after="  Your answer, Y or N [N]: ", eol="\r\n")
    parts.update(over)
    eol = parts["eol"]
    return eol.join([parts["before"], "", parts["statement"], parts["reminder"], parts["question"], parts["after"]]) + eol


def question_cases():
    c = []
    c.append(case("good", "Get-WindowQuestionProblems", ConsoleText=good_console()))
    c.append(case("good_lf_only", "Get-WindowQuestionProblems", ConsoleText=good_console(eol="\n", before="x")))
    c.append(case("good_trailing_blanks", "Get-WindowQuestionProblems",
                  ConsoleText=good_console(statement=STATEMENT + "  ", reminder=REMINDER + " ", question=QUESTION + "   ")))
    c.append(case("empty", "Get-WindowQuestionProblems", ConsoleText=""))
    c.append(case("statement_missing", "Get-WindowQuestionProblems",
                  ConsoleText=good_console().replace(STATEMENT + "\r\n", "")))
    c.append(case("number_changed", "Get-WindowQuestionProblems",
                  ConsoleText=good_console(statement=STATEMENT.replace("about 30 seconds", "about 3 seconds"))))
    c.append(case("number_changed_up", "Get-WindowQuestionProblems",
                  ConsoleText=good_console(statement=STATEMENT.replace("about 30 seconds", "about 300 seconds"))))
    c.append(case("statement_lowercase", "Get-WindowQuestionProblems",
                  ConsoleText=good_console(statement=STATEMENT.replace("Your program", "your program"))))
    c.append(case("statement_twice", "Get-WindowQuestionProblems",
                  ConsoleText=good_console(before="x\r\n" + STATEMENT)))
    c.append(case("statement_inside_a_longer_line", "Get-WindowQuestionProblems",
                  ConsoleText=good_console(statement="[INFO] " + STATEMENT)))
    c.append(case("reminder_missing", "Get-WindowQuestionProblems",
                  ConsoleText=good_console().replace(REMINDER + "\r\n", "")))
    c.append(case("question_missing", "Get-WindowQuestionProblems",
                  ConsoleText=good_console().replace(QUESTION + "\r\n", "")))
    c.append(case("question_default_changed", "Get-WindowQuestionProblems",
                  ConsoleText=good_console(question=QUESTION.replace("[y/N]", "[Y/n]"))))
    c.append(case("order_swapped", "Get-WindowQuestionProblems",
                  ConsoleText=good_console(statement=QUESTION, question=STATEMENT)))
    c.append(case("reminder_first", "Get-WindowQuestionProblems",
                  ConsoleText=good_console(statement=REMINDER, reminder=STATEMENT)))
    return c


class QuestionWordingIsTheEcho(unittest.TestCase):
    """What the judge expects is what :lc_window prints."""

    def setUp(self):
        self.bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        self.script = LASTCHANCE.read_text(encoding="utf-8")

    def test_the_three_lines_are_the_real_echo_lines_in_the_real_order(self):
        self.assertEqual(real_question_lines(self.bat), [STATEMENT, REMINDER, QUESTION])
        self.assertEqual(wording_problems(self.bat, self.script), [])

    def test_a_reworded_statement_is_reported_with_both_sides(self):
        bad = mutate(self.bat, "echo *** Your program printed nothing, so the check stopped it after about 30 seconds. ***",
                     "echo *** Your program printed nothing, so the check stopped it after about 3 seconds. ***")
        found = wording_problems(bad, self.script)
        self.assertTrue(found and "about 3 seconds" in found[0] and "about 30 seconds" in found[0], found)

    def test_a_question_that_moved_before_the_statement_is_reported(self):
        # read_text() has turned the file's CRLF into LF, so the lines are swapped with LF
        statement = "echo " + STATEMENT + "\n"
        question = "echo " + QUESTION + "\n"
        self.assertEqual(self.bat.count(statement), 1)
        self.assertEqual(self.bat.count(question), 1)
        bad = self.bat.replace(statement, "@@S@@").replace(question, statement).replace("@@S@@", question)
        self.assertNotEqual(bad, self.bat)
        self.assertTrue(wording_problems(bad, self.script))

    def test_a_judge_that_expects_other_lines_is_reported(self):
        bad = mutate(norm(self.script), "'*** Your program printed nothing, so the check stopped it after about 30 seconds. ***',",
                     "'*** Your program printed nothing, so the check stopped it after about 3 seconds. ***',")
        self.assertTrue(wording_problems(self.bat, bad))

    def test_the_statement_names_the_number_of_seconds_the_shall_names(self):
        # README REQ-018.30: 30 seconds; the runner's default wait is HP_SMOKERUN_KILL_MS 30000 (tools/exe_smokerun.ps1)
        readme = (REPO / "README.md").read_text(encoding="utf-8")
        self.assertRegex(readme, r"\*\*REQ-018\.30\*\* \[major\] The bootstrapper \*\*shall\*\* state in the question of REQ-018\.28 that the check stops the\s+program 30 seconds after it started\.")
        self.assertIn("about 30 seconds", STATEMENT)
        runner = (REPO / "tools" / "exe_smokerun.ps1").read_text(encoding="utf-8")
        self.assertIn("30000", runner)


class WindowRowIsPinned(unittest.TestCase):
    def setUp(self):
        self.script = LASTCHANCE.read_text(encoding="utf-8")

    def test_the_real_script_and_the_shall_list_are_in_order(self):
        self.assertEqual(script_problems(self.script), [])
        self.assertEqual(shall_list_problems(SHALL_TRACE.read_text(encoding="utf-8")), [])

    def test_a_row_that_stops_naming_the_shall_is_reported(self):
        bad = mutate(norm(self.script), "req     = 'REQ-018.28, REQ-018.29, REQ-018.30'", "req     = 'REQ-018.28, REQ-018.29'")
        self.assertTrue(any("must carry the literal req tag" in f for f in script_problems(bad)))

    def test_a_verdict_that_ignores_the_question_text_is_reported(self):
        bad = mutate(norm(self.script), " -and ($wyQuestion.Count -eq 0)\n", "\n")
        self.assertTrue(any("must require" in f for f in script_problems(bad)))

    def test_a_verdict_that_judges_another_runs_console_is_reported(self):
        bad = mutate(norm(self.script), "Get-WindowQuestionProblems -ConsoleText $wy.Console)", "Get-WindowQuestionProblems -ConsoleText $we.Console)")
        self.assertTrue(any("console of its own run" in f for f in script_problems(bad)))

    def test_another_window_row_that_takes_the_tag_is_reported(self):
        bad = mutate(norm(self.script), "id      = 'self.lastchance.window_auto'\n        req     = 'REQ-018.28, REQ-018.29'",
                     "id      = 'self.lastchance.window_auto'\n        req     = 'REQ-018.28, REQ-018.30'")
        self.assertTrue(any("window_auto names REQ-018.30" in f for f in script_problems(bad)))

    def test_a_shall_that_is_still_listed_as_a_gap_is_reported(self):
        self.assertTrue(shall_list_problems('    "REQ-018.30": "unit: tests/test_window_confirm.py::WindowQuestionWiring x",\n'))
        self.assertEqual(shall_list_problems('    "REQ-018.300": "unit: x",\n'), [])


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgeOnSyntheticConsoles(unittest.TestCase):
    """The script's judge, alone and in strict mode, on consoles built here: a good one passes and each wrong one is named."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.r = run_cases(LASTCHANCE, JUDGES, question_cases(), d)

    def only(self, name, *needles):
        found = self.r[name]
        self.assertEqual(len(found), 1, (name, found))
        for needle in needles:
            self.assertIn(needle, found[0], (name, found))

    def test_a_console_with_the_question_in_order_is_clean_in_both_line_endings_and_with_trailing_blanks(self):
        for name in ("good", "good_lf_only", "good_trailing_blanks"):
            self.assertEqual(self.r[name], [], name)

    def test_an_empty_console_names_all_three_lines(self):
        self.assertEqual(len(self.r["empty"]), 3, self.r["empty"])
        for line in (STATEMENT, REMINDER, QUESTION):
            self.assertTrue(any(line in f and "0 time(s)" in f for f in self.r["empty"]), self.r["empty"])

    def test_a_missing_line_is_named_with_its_text(self):
        self.only("statement_missing", "printed nothing", "0 time(s)")
        self.only("reminder_missing", "A program with a window prints nothing", "0 time(s)")
        self.only("question_missing", "Did it open and work", "0 time(s)")

    def test_a_changed_number_a_changed_case_a_changed_default_and_a_longer_line_are_each_a_missing_line(self):
        for name in ("number_changed", "number_changed_up", "statement_lowercase", "statement_inside_a_longer_line"):
            self.only(name, "printed nothing", "0 time(s)")
        self.only("question_default_changed", "Did it open and work", "0 time(s)")

    def test_a_line_printed_twice_is_named(self):
        self.only("statement_twice", "printed nothing", "2 time(s)")

    def test_the_wrong_order_is_one_problem_and_nothing_else(self):
        self.only("order_swapped", "order")
        self.only("reminder_first", "order")


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgeCanFail(unittest.TestCase):
    """A judge that quietly stops judging would pass every run, so the cases run against mutated copies of the script."""

    def run_mutated(self, old, new, names):
        text = norm(LASTCHANCE.read_text(encoding="utf-8"))
        self.assertEqual(text.count(old), 1, "the synthetic case needs %r exactly once" % old)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "mutated.ps1"
            script.write_text(text.replace(old, new), encoding="utf-8")
            wanted = [c for c in question_cases() if c["name"] in names]
            return run_cases(script, JUDGES, wanted, d)

    def test_a_judge_that_ignores_case_is_caught(self):
        got = self.run_mutated("$consoleLines[$i] -ceq $want", "$consoleLines[$i] -eq $want", ["statement_lowercase"])
        self.assertEqual(got["statement_lowercase"], [])

    def test_a_judge_that_matches_a_part_of_a_line_is_caught(self):
        got = self.run_mutated("$consoleLines[$i] -ceq $want", "$consoleLines[$i].Contains($want)", ["statement_inside_a_longer_line"])
        self.assertEqual(got["statement_inside_a_longer_line"], [])

    def test_a_judge_that_accepts_a_repeated_line_is_caught(self):
        got = self.run_mutated("if ($found.Count -ne 1) {", "if ($found.Count -lt 1) {", ["statement_twice"])
        self.assertEqual(got["statement_twice"], [])

    def test_a_judge_that_forgets_the_order_is_caught(self):
        got = self.run_mutated("if (-not (($positions[0] -lt $positions[1]) -and ($positions[1] -lt $positions[2]))) {", "if ($false) {", ["order_swapped"])
        self.assertEqual(got["order_swapped"], [])

    def test_a_judge_that_forgets_a_line_is_caught(self):
        got = self.run_mutated("        '*** A program with a window prints nothing in this console, so that alone does not mean it failed. ***',\n", "", ["reminder_missing"])
        # the judge still says something (the order of the two lines it has left is wrong), but no longer names the missing line
        self.assertFalse(any("A program with a window prints nothing" in f for f in got["reminder_missing"]), got)


if __name__ == "__main__":
    unittest.main()
