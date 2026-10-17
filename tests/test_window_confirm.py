"""Tests for the window-app question of the last-chance offer, CLAUDE.md Item 82 slice 2 (README REQ-018).

A window app stays silent on the console, so the EXE verification run is force-stopped after about 30 seconds
and reads as exit -1. On the conda tier that the provider cascade reached, the bootstrapper asks once whether the
window opened and worked, because the run can never end in a clean exit 0 and would never count as a pass. Exit -1
alone does not prove a stop: the runner also leaves HP_EXE_EXIT at -1 when it could not be written or never wrote
its result, and a program may exit with -1 by itself. So the question is gated on a marker file that only
tools/exe_smokerun.ps1 writes, in the branch that kills the process. These tests pin where the marker is
cleared, read and reset and the order of the gates, since a wrong order is silent: the question appears when it
should not, or never.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


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


if __name__ == "__main__":
    unittest.main()
