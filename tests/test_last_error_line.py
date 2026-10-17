"""Tests for tools/last_error_line.py (HP_LAST_ERROR_LINE) and the batch wiring of the last-chance offer,
CLAUDE.md Item 82 slice 1.

The helper writes the last non-blank line of a failed run's stderr to a file, two spaces in front,
keeping every printable ASCII character literally (the batch shows the file with type, which never
parses its content) and turning anything else into a question mark. The batch tests pin the order of the
gates and the places the offer's inputs are captured, since a wrong order is silent: it only means the
question appears when it should not, or never.
"""
import ast
import base64
import contextlib
import importlib.util
import io
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "last_error_line.py"

_spec = importlib.util.spec_from_file_location("last_error_line", SOURCE)
lel = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lel)


def _run(data, name="err.txt"):
    """Runs the helper as the batch does and returns (exit code, out file text or None, stderr)."""
    d = Path(tempfile.mkdtemp())
    try:
        if data is not None:
            (d / name).write_bytes(data)
        r = subprocess.run(
            [sys.executable, str(SOURCE), name, "out.txt"], cwd=str(d), capture_output=True, text=True,
        )
        out = (d / "out.txt").read_bytes().decode("ascii") if (d / "out.txt").exists() else None
        return r.returncode, out, r.stderr
    finally:
        shutil.rmtree(d, ignore_errors=True)


class WhatIsShown(unittest.TestCase):
    def test_the_last_line_of_a_traceback_is_written_indented_with_crlf(self):
        tb = b'Traceback (most recent call last):\n  File "a.py", line 1, in <module>\nRuntimeError: boom\n'
        rc, out, _ = _run(tb)
        self.assertEqual(rc, 0)
        self.assertEqual(out, "  RuntimeError: boom\r\n")

    def test_trailing_blank_lines_and_whitespace_are_skipped(self):
        rc, out, _ = _run(b"first\nsecond   \n\n   \r\n\n")
        self.assertEqual((rc, out), (0, "  second\r\n"))

    def test_crlf_input_is_read_per_line(self):
        rc, out, _ = _run(b"first\r\nsecond\r\n")
        self.assertEqual((rc, out), (0, "  second\r\n"))

    def test_every_shell_operator_and_quote_is_kept_literally(self):
        line = 'Error: a<b>c&d|e%PATH%^f "q" \'r\' !x'
        rc, out, _ = _run(line.encode("ascii") + b"\n")
        self.assertEqual((rc, out), (0, "  " + line + "\r\n"))

    def test_controls_and_non_ascii_become_question_marks(self):
        rc, out, _ = _run(b"na\xc3\xafve \xe2\x80\x9cquote\xe2\x80\x9d \x1b[31mred\tend\n")
        self.assertEqual(rc, 0)
        # U+00EF and each curly quote are one character each; the escape and the tab are controls.
        self.assertEqual(out, "  na?ve ?quote? ?[31mred?end\r\n")

    def test_bytes_that_are_not_utf8_do_not_break_it(self):
        rc, out, _ = _run(b"ok\n\xff\xfe\x80 junk\n")
        self.assertEqual(rc, 0)
        self.assertTrue(out.startswith("  "))
        self.assertTrue(out.endswith(" junk\r\n"))
        out.encode("ascii")

    def test_a_long_line_is_cut_and_marked(self):
        rc, out, _ = _run(b"x" * 500 + b"\n")
        self.assertEqual(rc, 0)
        shown = out[2:-2]
        self.assertEqual(len(shown), 200)
        self.assertTrue(shown.endswith("..."))

    def test_only_the_tail_of_a_large_file_is_read(self):
        big = (b"noise line\n" * 20000) + b"the end\n"
        rc, out, _ = _run(big)
        self.assertEqual((rc, out), (0, "  the end\r\n"))


class NothingToShow(unittest.TestCase):
    def test_missing_empty_or_blank_files_exit_one_and_leave_no_file(self):
        for data in (None, b"", b"\n\n   \n", b"\r\n"):
            with self.subTest(data=data):
                rc, out, _ = _run(data)
                self.assertEqual((rc, out), (1, None))

    def test_no_argument_exits_one(self):
        r = subprocess.run([sys.executable, str(SOURCE)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)

    def test_internal_error_exits_three_with_a_one_line_reason(self):
        err = io.StringIO()
        with mock.patch.object(lel, "last_line", side_effect=ZeroDivisionError), contextlib.redirect_stderr(err):
            rc = lel.main(["x", "in.txt", "out.txt"])
        self.assertEqual(rc, 3)
        self.assertEqual(err.getvalue().strip(), "last_error_line: ZeroDivisionError")


class EmbeddedHelperBaseline(unittest.TestCase):
    def test_source_parses_under_python_39_grammar(self):
        ast.parse(SOURCE.read_text(encoding="utf-8"), feature_version=(3, 9))

    def test_source_is_ascii(self):
        SOURCE.read_text(encoding="ascii")


class BatchWiring(unittest.TestCase):
    def setUp(self):
        self.bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        i = re.search(r"(?m)^:last_chance_offer", self.bat).start()
        self.block = self.bat[i:self.bat.index("\n:lc_row", i)]

    def _between(self, start, end):
        a = self.block.index("\n" + start + "\n") + 1
        return self.block[a:self.block.index("\n" + end + "\n", a)]

    def _sub(self, label):
        i = re.search(r"(?m)^%s\b" % re.escape(label), self.bat).start()
        return self.bat[i:self.bat.index("\nexit /b 0", i)]

    def test_the_offer_runs_once_right_after_the_verification_and_before_the_fast_path_flag_is_cleared(self):
        self.assertEqual(self.bat.count("call :last_chance_offer"), 1)
        i = self.bat.index("call :last_chance_offer")
        j = self.bat.rindex("call :verify_no_exe_interpreter\n", 0, i) + len("call :verify_no_exe_interpreter\n")
        # only comment lines may sit between the verification call and the offer call
        for line in self.bat[j:i].splitlines():
            self.assertTrue(not line.strip() or line.startswith("rem "), line)
        self.assertGreater(self.bat.index('set "HP_FASTPATH_USED="', i), i)

    def test_every_not_offered_reason_is_checked_before_the_prompt(self):
        reasons = ["provider", "cascade_approved", "runtime_install", "checkpoint_ok"]
        for r in reasons:
            with self.subTest(reason=r):
                self.assertIn('set "HP_LC_REASON=%s"' % r, self.block)
        self.assertLess(self.block.index("if defined HP_LC_REASON goto :lc_not_offered"),
                        self.block.index("Your program stopped with an error"))

    def test_exit_zero_and_minus_one_and_the_fast_path_are_never_offered(self):
        head = self.block[:self.block.index('set "HP_LC_REASON="')]
        self.assertIn("if not defined HP_LC_EXIT exit /b 0", head)
        self.assertIn("if defined HP_FASTPATH_USED goto :lc_cleanup", head)
        self.assertIn('if "%HP_LC_EXIT%"=="0" goto :lc_cleanup', head)
        # -1 never reaches the three-answer prompt; it goes to the window question (slice 2), which has its own gates
        self.assertIn('if "%HP_LC_EXIT%"=="-1" goto :lc_window', head)

    def test_uv_to_conda_only(self):
        self.assertIn('if /i not "%HP_ENV_MODE%"=="uv" set "HP_LC_REASON=provider"', self.block)
        self.assertIn('if defined HP_CASCADE_TRIED_UV set "HP_LC_REASON=provider"', self.block)

    def test_the_gate_checks_the_override_first_then_the_forced_read_then_the_automated_guards(self):
        order = [
            "if defined HP_TEST_LASTCHANCE_ANSWER goto :lc_gate_override",
            "if defined HP_TEST_FORCE_INTERACTIVE_LASTCHANCE goto :lc_gate_interactive",
            "if defined HP_CI_LANE goto :lc_gate_auto",
            "if defined NOINPUT goto :lc_gate_auto",
            "if defined HP_NONINTERACTIVE goto :lc_gate_auto",
            "goto :lc_gate_interactive",
        ]
        lines = self.block.splitlines()
        at = [lines.index(x) for x in order]
        self.assertEqual(at, list(range(at[0], at[0] + len(order))))

    def test_the_prompt_text_is_echoed_before_the_gate(self):
        gate = self.block.index("if defined HP_TEST_LASTCHANCE_ANSWER")
        for text in ("*** Your program stopped with an error, exit code %HP_LC_EXIT%.",
                     "[W] It actually worked", "[C] Try again with Miniconda", "[N] Neither"):
            with self.subTest(text=text):
                self.assertLess(self.block.index(text), gate)
        self.assertIn("runs your program once more", self.block)

    def test_the_prompt_is_not_timed_and_defaults_to_neither(self):
        self.assertIn('set /p "HP_LC_RAW=', self.block)
        self.assertNotIn("choice /", self.block)
        self.assertNotIn("/T ", self.block)
        resolve = self._between(":lc_gate_resolve", ":lc_worked")
        self.assertIn('if /I "%HP_LC_CHOICE%"=="W" goto :lc_worked', resolve)
        self.assertIn('if /I "%HP_LC_CHOICE%"=="C" goto :lc_cascade', resolve)
        self.assertIn("Last chance: neither", resolve)

    def test_a_c_answer_only_sets_the_existing_cascade_flag(self):
        body = self._between(":lc_cascade", ":lc_not_offered")
        self.assertIn('set "HP_CASCADE_APPROVED=1"', body)
        self.assertNotIn("provider_cascade", body)

    def test_a_worked_answer_records_the_pass_type_and_starts_no_cascade(self):
        body = self._between(":lc_worked", ":lc_cascade")
        self.assertIn('set "HP_LC_PASS=user_confirmed"', body)
        self.assertNotIn("HP_CASCADE_APPROVED", body)

    def test_the_error_line_is_shown_with_type_and_never_through_log(self):
        for line in self.bat.splitlines():
            if "~last_error_line.txt" not in line or "last_error_line.py" in line:
                continue
            if line.startswith("rem ") or "type " in line:
                continue
            self.assertTrue(line.startswith(("if exist ", "if not errorlevel ", "set ")), line)
            self.assertNotIn("call :log", line)
        self.assertIn('if defined HP_LC_HAVE_LINE type "~last_error_line.txt"\n', self.bat)
        self.assertIn('type "~last_error_line.txt" >> "%LOG%"', self.block)

    def test_the_helper_is_emitted_from_its_payload_and_the_hook_covers_it(self):
        self.assertIn('call :emit_from_base64 "~last_error_line.py" HP_LAST_ERROR_LINE', self.bat)
        self.assertIn('"%HP_PY%" "~last_error_line.py" "~run.err.txt" "~last_error_line.txt"', self.bat)

    def test_the_inputs_are_captured_where_they_would_otherwise_be_lost(self):
        # EXE site: the exit code is snapshotted before :smokerun_ndjson clears it.
        i = self.bat.index('set "HP_LC_EXIT=%HP_EXE_EXIT%"')
        self.assertLess(i, self.bat.index('set "HP_EXE_EXIT="', i))
        self.assertIn('set "HP_LC_SITE=exe"', self.bat[i:i + 200])
        # Interpreter site: both branches of :verify_no_exe_interpreter.
        self.assertEqual(self.bat.count('set "HP_LC_EXIT=%HP_SMOKE_RC%"'), 2)
        # Checkpoint: captured before the caller's own HP_SMOKE_RC is restored.
        j = self.bat.index('set "HP_LC_CKPT_RC=%HP_SMOKE_RC%"')
        self.assertLess(self.bat.rindex("call :run_failfast_probe checkpoint", 0, j), j)
        self.assertLess(j, self.bat.index('set "HP_SMOKE_RC=%HP_CHECKPOINT_SAVED_SMOKE_RC%"', j))

    def test_each_fresh_attempt_resets_the_inputs(self):
        reset = 'set "HP_LC_EXIT="\nset "HP_LC_SITE="\nset "HP_LC_CKPT_RC="\n'
        i = self.bat.index(reset)
        # inside :run_entry_smoke, after the per-attempt HP_SMOKE_RC reset
        self.assertGreater(i, self.bat.index("\n:run_entry_smoke\n"))
        self.assertLess(self.bat.rindex('set "HP_SMOKE_RC="\n', 0, i), i)

    def test_the_runtime_mismatch_hint_no_longer_rules_out_the_environment(self):
        line = next(x for x in self.bat.splitlines() if "[HINT][RUNTIME_MISMATCH]" in x)
        self.assertNotIn("not your environment", line)
        self.assertIn("dependency problem in the environment", line)

    def test_the_row_carries_the_fields_the_test_reads(self):
        row = self._sub(":lc_row")
        for f in ("state=", "reason=", "site=", "provider=", "exitCode=", "passType=", "hasLine="):
            with self.subTest(field=f):
                self.assertIn(f, row)
        self.assertIn("id='self.lastchance.offer'", row)


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_LAST_ERROR_LINE=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_LAST_ERROR_LINE payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_LAST_ERROR_LINE base64 is out of sync with tools/last_error_line.py; "
            "run: python tools/sync_payload.py HP_LAST_ERROR_LINE tools/last_error_line.py",
        )


if __name__ == "__main__":
    unittest.main()
