"""Tests for tools/preflight_check.py -- the REQ-021 static syntax check (CLAUDE.md Item 83).

The old pre-flight ran `python -m py_compile`, which writes a .pyc into __pycache__. It exited 1 for
a valid program when it could not write there (a read-only or file-shaped __pycache__), and the
bootstrapper reported a syntax error that was not there (REQ-021.4); when it could write it left the
.pyc behind (REQ-021.5). The helper compiles in memory instead, so these tests pin: the exit codes,
that nothing is written next to the entry, that an unwritable __pycache__ changes nothing, that the
message still carries the interpreter's own wording, the embedded-helper Python 3.9 grammar rule,
and the HP_PREFLIGHT_CHECK payload sync.

The script is a flat top-level sys.exit() script (matching its payload form), so it is exercised
via subprocess, like tests/test_pep723_extract.py.
"""
import ast
import base64
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "preflight_check.py"


def run_check(*args):
    return subprocess.run([sys.executable, str(SOURCE), *args], capture_output=True, text=True)


class Fixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)

    def write(self, name, content, binary=False):
        path = self.dir / name
        if binary:
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        return path

    def listing(self):
        return sorted(p.name for p in self.dir.rglob("*"))


class ValidSyntax(Fixture):
    def test_valid_file_exits_0_with_no_output(self):
        entry = self.write("entry.py", "print('hello')\n")
        r = run_check(str(entry))
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def test_valid_file_leaves_the_folder_unchanged(self):
        # REQ-021.5: py_compile left __pycache__/entry.cpython-*.pyc behind.
        entry = self.write("entry.py", "print('hello')\n")
        before = self.listing()
        run_check(str(entry))
        self.assertEqual(self.listing(), before)
        self.assertFalse((self.dir / "__pycache__").exists())

    def test_file_named_pycache_does_not_matter(self):
        # REQ-021.4: a FILE where py_compile wants a directory made it exit 1 for valid code.
        entry = self.write("entry.py", "print('hello')\n")
        (self.dir / "__pycache__").write_text("not a directory", encoding="ascii")
        r = run_check(str(entry))
        self.assertEqual(r.returncode, 0, r.stderr)

    @unittest.skipIf(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0),
                     "a read-only directory only blocks writes for a non-root POSIX user")
    def test_read_only_pycache_directory_does_not_matter(self):
        entry = self.write("entry.py", "print('hello')\n")
        cache = self.dir / "__pycache__"
        cache.mkdir()
        cache.chmod(0o500)
        self.addCleanup(cache.chmod, 0o700)
        self.assertEqual(run_check(str(entry)).returncode, 0)

    def test_utf8_bom_is_accepted(self):
        entry = self.write("entry.py", b"\xef\xbb\xbfprint('hi')\n", binary=True)
        self.assertEqual(run_check(str(entry)).returncode, 0)

    def test_declared_latin1_encoding_is_accepted(self):
        entry = self.write("entry.py", b"# -*- coding: latin-1 -*-\nprint('caf\xe9')\n", binary=True)
        self.assertEqual(run_check(str(entry)).returncode, 0)

    def test_crlf_line_endings_are_accepted(self):
        entry = self.write("entry.py", b"x = 1\r\nprint(x)\r\n", binary=True)
        self.assertEqual(run_check(str(entry)).returncode, 0)

    def test_invalid_escape_warning_is_not_an_error_and_prints_nothing(self):
        entry = self.write("entry.py", 'print("\\d")\n')
        r = run_check(str(entry))
        self.assertEqual((r.returncode, r.stderr), (0, ""))

    def test_empty_file_is_valid(self):
        entry = self.write("entry.py", "")
        self.assertEqual(run_check(str(entry)).returncode, 0)

    def test_valid_file_with_an_unimportable_name_is_still_valid(self):
        entry = self.write("my app (1).py", "print(1)\n")
        self.assertEqual(run_check(str(entry)).returncode, 0)


class SyntaxErrors(Fixture):
    def test_syntax_error_exits_1_and_names_the_line(self):
        entry = self.write("entry.py", "x = 1\ndef f(:\n    pass\n")
        r = run_check(str(entry))
        self.assertEqual(r.returncode, 1)
        self.assertIn("SyntaxError", r.stderr)
        self.assertIn("line 2", r.stderr)
        self.assertIn("entry.py", r.stderr)

    def test_indentation_error_exits_1(self):
        entry = self.write("entry.py", "if True:\nprint(1)\n")
        r = run_check(str(entry))
        self.assertEqual(r.returncode, 1)
        self.assertIn("IndentationError", r.stderr)

    def test_inconsistent_tabs_exit_1(self):
        entry = self.write("entry.py", "if True:\n        x = 1\n\ty = 2\n")
        r = run_check(str(entry))
        self.assertEqual(r.returncode, 1)
        self.assertIn("Error", r.stderr)

    def test_undecodable_bytes_exit_1(self):
        entry = self.write("entry.py", b"print('\xff\xfe')\n", binary=True)
        r = run_check(str(entry))
        self.assertEqual(r.returncode, 1)
        self.assertNotEqual(r.stderr, "")

    def test_null_byte_exits_1(self):
        entry = self.write("entry.py", b"x = 1\x00\n", binary=True)
        self.assertEqual(run_check(str(entry)).returncode, 1)

    def test_errors_only_the_compiler_reports_exit_1(self):
        # REQ-021.6: the parser accepts these, the compiler rejects them, so a check that only parsed
        # (ast.parse) would let each one through to the build. The cases name the exact wording the
        # interpreter prints so the user sees its own message.
        cases = {
            "return_outside_function": ("x = 1\nreturn x\n", "outside function"),
            "break_outside_loop": ("break\n", "outside loop"),
            "continue_outside_loop": ("continue\n", "not properly in loop"),
            "await_outside_function": ("await x\n", "outside function"),
            "nonlocal_at_module_level": ("nonlocal x\n", "nonlocal"),
        }
        for name, (source, wording) in cases.items():
            with self.subTest(name):
                entry = self.write("entry_%s.py" % name, source)
                r = run_check(str(entry))
                self.assertEqual(r.returncode, 1, r.stderr)
                self.assertIn("SyntaxError", r.stderr)
                self.assertIn(wording, r.stderr)

    def test_syntax_error_writes_nothing_either(self):
        entry = self.write("entry.py", "def f(:\n")
        before = self.listing()
        run_check(str(entry))
        self.assertEqual(self.listing(), before)

    def test_syntax_error_still_exits_1_next_to_a_file_named_pycache(self):
        entry = self.write("entry.py", "def f(:\n")
        (self.dir / "__pycache__").write_text("x", encoding="ascii")
        self.assertEqual(run_check(str(entry)).returncode, 1)

    def test_user_code_is_never_executed(self):
        marker = self.dir / "ran.txt"
        entry = self.write(
            "entry.py",
            "open(%r, 'w').write('x')\n" % str(marker),
        )
        self.assertEqual(run_check(str(entry)).returncode, 0)
        self.assertFalse(marker.exists())


class CouldNotDecide(Fixture):
    def test_missing_file_is_exit_3(self):
        self.assertEqual(run_check(str(self.dir / "nope.py")).returncode, 3)

    def test_no_argument_is_exit_3(self):
        self.assertEqual(run_check().returncode, 3)

    def test_two_arguments_are_exit_3(self):
        entry = self.write("entry.py", "x = 1\n")
        self.assertEqual(run_check(str(entry), str(entry)).returncode, 3)

    def test_directory_instead_of_a_file_is_exit_3(self):
        self.assertEqual(run_check(str(self.dir)).returncode, 3)


class BatchCallSite(unittest.TestCase):
    """Pins how :preflight_compile uses the helper: no py_compile, and a helper that cannot
    decide never blocks a program (REQ-021.4)."""

    @classmethod
    def setUpClass(cls):
        bat = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        start = bat.index("\n:preflight_compile\n")
        end = bat.index("\n:compute_collect_flags", start)
        cls.body = bat[start:end]

    def live_lines(self):
        return [ln for ln in self.body.splitlines() if not ln.lstrip().lower().startswith("rem ")]

    def test_py_compile_is_not_invoked(self):
        self.assertFalse([ln for ln in self.live_lines() if "py_compile" in ln and "-m py_compile" in ln])

    def test_helper_is_emitted_and_run_on_the_entry(self):
        self.assertIn('call :emit_from_base64 "~preflight_check.py" HP_PREFLIGHT_CHECK', self.body)
        self.assertIn('"%HP_PY%" "~preflight_check.py" "%HP_ENTRY%"', self.body)

    def test_only_exit_1_reports_a_syntax_error(self):
        # The error panel must sit behind an exit-code-1 test; any other nonzero code only warns.
        self.assertRegex(self.body, r'if not "%HP_PREFLIGHT_RC%"=="1"')
        self.assertIn("[WARN] REQ-021: syntax pre-check could not decide", self.body)


class EmbeddedHelperBaseline(unittest.TestCase):
    def test_parses_as_python_39_grammar(self):
        # Fallback tiers can hand the bootstrapper an older interpreter; a SyntaxError there is a
        # hard crash no try/except can catch (docs/agent-lessons-learned.md, embedded-helper baseline).
        ast.parse(SOURCE.read_text(encoding="utf-8"), feature_version=(3, 9))

    def test_payload_line_fits_cmd_limit(self):
        b64 = base64.b64encode(SOURCE.read_bytes())
        self.assertLessEqual(len('set "HP_PREFLIGHT_CHECK=') + len(b64) + 1, 8191)

    def test_source_is_ascii(self):
        SOURCE.read_bytes().decode("ascii")


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_PREFLIGHT_CHECK=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_PREFLIGHT_CHECK payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_PREFLIGHT_CHECK base64 is out of sync with tools/preflight_check.py; "
            "run: python tools/sync_payload.py HP_PREFLIGHT_CHECK tools/preflight_check.py",
        )


if __name__ == "__main__":
    unittest.main()
