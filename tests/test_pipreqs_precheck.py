"""Tests for tools/pipreqs_precheck.py -- CLAUDE.md Item 63.

pipreqs 0.4.13 opens every .py with the locale encoding and aborts the whole scan on the first file
it cannot decode or parse. The pre-check reads each .py first: all clean UTF-8 means scan in place
(exit 0); anything else means write a UTF-8 copy of the tree (exit 10) in which re-encodable files
are re-encoded and unreadable files become empty stubs. These tests pin that on any OS, without
needing a cp1252 Windows locale (the CI scenario tests/selfapps_pipreqs_encoding.ps1 covers the
real thing).
"""
import ast
import base64
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools.pipreqs_precheck import check_file, main

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "pipreqs_precheck.py"

# Written with escapes so this file stays ASCII.
RIGHT_QUOTE = "\u201d"
LEFT_QUOTE = "\u201c"
# The shape of the maintainer's real file: valid UTF-8, no coding cookie, smart-quote cleanup regexes.
CURLY_SRC = (
    "import re\n"
    "import colorama\n"
    "def clean(data):\n"
    "    data = re.sub(r'" + LEFT_QUOTE + "', '\"', data)\n"
    "    data = re.sub(r'" + RIGHT_QUOTE + "', '\"', data)\n"
    "    return data\n"
)


class Tree:
    """A scratch project folder plus a sibling stage folder and report path."""

    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name)
        self.src = base / "app"
        self.src.mkdir()
        self.stage = base / "stage"
        self.report = base / "report.txt"

    def put(self, rel, data):
        path = self.src / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
        return path

    def run(self, ignore=""):
        return main(str(self.src), str(self.stage), ignore, str(self.report))

    def lines(self):
        return self.report.read_text().splitlines()

    def cleanup(self):
        self._tmp.cleanup()


class TreeCase(unittest.TestCase):
    def setUp(self):
        self.t = Tree()
        self.addCleanup(self.t.cleanup)


class WhyPipreqsCrashed(unittest.TestCase):
    def test_right_curly_quote_is_valid_utf8_but_undecodable_in_cp1252(self):
        # The exact traceback from the maintainer's real run: byte 0x9d, 'character maps to <undefined>'.
        raw = RIGHT_QUOTE.encode("utf-8")
        self.assertEqual(raw, b"\xe2\x80\x9d")
        with self.assertRaises(UnicodeDecodeError) as ctx:
            raw.decode("cp1252")
        self.assertIn("0x9d", str(ctx.exception))
        self.assertEqual(raw.decode("utf-8"), RIGHT_QUOTE)

    def test_left_curly_quote_decodes_silently_under_cp1252(self):
        # Why a fixture holding only left quotes would pass today and prove nothing.
        LEFT_QUOTE.encode("utf-8").decode("cp1252")


class CheckFile(TreeCase):
    def test_plain_utf8_is_ok(self):
        p = self.t.put("a.py", "import os\n")
        self.assertEqual(check_file(str(p))[0], "ok")

    def test_right_curly_quote_file_is_ok_utf8(self):
        p = self.t.put("adjacent.py", CURLY_SRC)
        state, text, enc, why = check_file(str(p))
        self.assertEqual((state, enc, why), ("ok", "utf-8", ""))
        self.assertIn(RIGHT_QUOTE, text)

    def test_emoji_file_is_ok(self):
        p = self.t.put("e.py", "import tabulate\nprint('\U0001F50D')\n")
        self.assertEqual(check_file(str(p))[0], "ok")

    def test_declared_cp1252_is_reencoded(self):
        p = self.t.put("c.py", b"# -*- coding: cp1252 -*-\nimport termcolor\nx = '\xe9'\n")
        state, text, enc, why = check_file(str(p))
        self.assertEqual((state, enc), ("reenc", "cp1252"))
        self.assertIn("\u00e9", text)

    def test_cp1252_without_cookie_is_left_out(self):
        p = self.t.put("n.py", b"# caf\xe9\nimport os\n")
        state, text, enc, why = check_file(str(p))
        self.assertEqual(state, "bad")
        self.assertIn("not valid UTF-8", why)

    def test_unknown_coding_cookie_is_left_out(self):
        p = self.t.put("u.py", b"# -*- coding: no-such-codec -*-\nimport os\n\xe9\n")
        self.assertEqual(check_file(str(p))[0], "bad")

    def test_utf8_bom_is_reencoded_without_the_bom(self):
        p = self.t.put("b.py", b"\xef\xbb\xbfimport os\n")
        state, text, enc, why = check_file(str(p))
        self.assertEqual((state, enc), ("reenc", "utf-8-bom"))
        self.assertFalse(text.startswith("\ufeff"))

    def test_unparseable_is_left_out(self):
        p = self.t.put("x.py", "import jinja2\ndef broken(:\n")
        state, text, enc, why = check_file(str(p))
        self.assertEqual(state, "bad")
        self.assertIn("does not parse", why)

    def test_python2_print_statement_is_left_out(self):
        p = self.t.put("old.py", "import os\nprint 'hello'\n")
        self.assertEqual(check_file(str(p))[0], "bad")

    def test_nul_byte_is_left_out_not_a_crash(self):
        p = self.t.put("z.py", b"import os\n\x00\n")
        self.assertEqual(check_file(str(p))[0], "bad")

    def test_missing_file_is_left_out_not_a_crash(self):
        state, text, enc, why = check_file(str(self.t.src / "gone.py"))
        self.assertEqual((state, why), ("bad", "cannot be read"))


class ScanInPlace(TreeCase):
    def test_all_clean_exits_zero_and_writes_no_stage(self):
        self.t.put("main.py", "import os\n")
        self.t.put("pkg/mod.py", "import json\n")
        self.t.put("notes.pdf", b"%PDF")
        self.assertEqual(self.t.run(), 0)
        self.assertFalse(self.t.stage.exists())
        self.assertEqual(
            self.t.lines()[-1],
            "[INFO] pipreqs pre-check: 2 .py file(s), 0 re-encoded as UTF-8, 0 left out, 1 other file(s) not scanned.",
        )

    def test_curly_quote_utf8_file_alone_still_scans_in_place(self):
        # With --encoding utf-8 passed, a valid UTF-8 file needs no copy.
        self.t.put("adjacent.py", CURLY_SRC)
        self.assertEqual(self.t.run(), 0)
        self.assertFalse(self.t.stage.exists())

    def test_empty_folder_is_exit_zero(self):
        self.assertEqual(self.t.run(), 0)
        self.assertIn("0 .py file(s)", self.t.lines()[-1])


class StagedCopy(TreeCase):
    def setUp(self):
        super().setUp()
        self.t.put("main.py", "import adjacent, cp1252_declared, cp1252_nocookie, unparseable\n")
        self.t.put("adjacent.py", CURLY_SRC)
        self.t.put("cp1252_declared.py", b"# -*- coding: cp1252 -*-\nimport termcolor\nx = '\xe9'\n")
        self.t.put("cp1252_nocookie.py", b"# caf\xe9\nimport os\n")
        self.t.put("unparseable.py", "import jinja2\ndef broken(:\n")
        self.code = self.t.run()

    def test_exit_ten(self):
        self.assertEqual(self.code, 10)

    def test_clean_file_copied_byte_for_byte(self):
        self.assertEqual((self.t.stage / "adjacent.py").read_bytes(), (self.t.src / "adjacent.py").read_bytes())

    def test_declared_cp1252_file_is_written_as_utf8(self):
        data = (self.t.stage / "cp1252_declared.py").read_bytes()
        self.assertIn("\u00e9".encode("utf-8"), data)
        data.decode("utf-8")

    def test_left_out_files_become_empty_stubs_so_their_names_stay_local(self):
        for name in ("cp1252_nocookie.py", "unparseable.py"):
            self.assertTrue((self.t.stage / name).is_file(), name)
            self.assertEqual((self.t.stage / name).read_bytes(), b"")

    def test_every_staged_file_decodes_as_utf8_and_parses(self):
        for p in self.t.stage.rglob("*.py"):
            ast.parse(p.read_bytes().decode("utf-8"))

    def test_warn_names_exactly_the_left_out_files(self):
        warns = [ln for ln in self.t.lines() if ln.startswith("[WARN]")]
        self.assertEqual(len(warns), 2)
        self.assertTrue(any("cp1252_nocookie.py" in w for w in warns))
        self.assertTrue(any("unparseable.py" in w for w in warns))
        for w in warns:
            self.assertNotIn("adjacent.py", w)
            self.assertNotIn("cp1252_declared.py", w)
            self.assertIn("may be incomplete", w)

    def test_info_line_per_scanned_file_with_its_encoding(self):
        infos = [ln for ln in self.t.lines() if ln.startswith("[INFO]") and "encoding=" in ln]
        self.assertTrue(any("adjacent.py encoding=utf-8 parsed=yes" in i for i in infos))
        self.assertTrue(any("cp1252_declared.py encoding=cp1252 parsed=yes" in i for i in infos))
        self.assertEqual(len(infos), 3)  # adjacent, cp1252_declared, main

    def test_summary_counts(self):
        self.assertEqual(
            self.t.lines()[-1],
            "[INFO] pipreqs pre-check: 5 .py file(s), 1 re-encoded as UTF-8, 2 left out, 0 other file(s) not scanned.",
        )

    def test_original_files_are_untouched(self):
        self.assertEqual((self.t.src / "cp1252_nocookie.py").read_bytes(), b"# caf\xe9\nimport os\n")


class TreeWalk(TreeCase):
    def test_subfolders_are_checked_and_staged(self):
        self.t.put("main.py", "import os\n")
        self.t.put("archive/old/helper.py", b"import json\n# \xe9\n")
        self.assertEqual(self.t.run(), 10)
        self.assertTrue((self.t.stage / "archive" / "old" / "helper.py").is_file())
        self.assertTrue(any("archive" in w and "helper.py" in w for w in self.t.lines() if w.startswith("[WARN]")))

    def test_folder_names_survive_even_without_py_files(self):
        # pipreqs counts folder basenames as local modules too
        self.t.put("main.py", b"# \xe9\n")
        (self.t.src / "assets").mkdir()
        self.assertEqual(self.t.run(), 10)
        self.assertTrue((self.t.stage / "assets").is_dir())

    def test_ignored_and_default_skipped_folders_are_neither_checked_nor_staged(self):
        self.t.put("main.py", "import os\n")
        self.t.put("venv/lib/bad.py", b"\xe9\n")
        self.t.put("tests/bad.py", b"\xe9\n")
        self.t.put(".git/hooks/bad.py", b"\xe9\n")
        self.t.put("keep/bad.py", b"\xe9\n")
        self.assertEqual(self.t.run("tests,build"), 10)
        warns = [ln for ln in self.t.lines() if ln.startswith("[WARN]")]
        self.assertEqual(len(warns), 1)
        self.assertIn("keep", warns[0])
        self.assertFalse((self.t.stage / "venv").exists())
        self.assertFalse((self.t.stage / "tests").exists())
        self.assertFalse((self.t.stage / ".git").exists())

    def test_non_py_files_are_counted_and_never_copied(self):
        self.t.put("main.py", b"# \xe9\n")
        self.t.put("data.xlsx", b"PK")
        self.t.put("doc.pdf", b"%PDF")
        self.assertEqual(self.t.run(), 10)
        self.assertFalse((self.t.stage / "data.xlsx").exists())
        self.assertIn("2 other file(s) not scanned", self.t.lines()[-1])


class ReportHygiene(TreeCase):
    def test_report_is_ascii_and_free_of_cmd_metacharacters(self):
        # File names reach cmd.exe's echo via the report, so nothing but a safe alphabet may get through.
        self.t.put("na\u00efve.py", b"\xe9\n")
        self.t.put("a&b.py", b"\xe9\n")
        self.t.put("c%d^e.py", b"\xe9\n")
        self.t.put("p(q)!r.py", b"\xe9\n")
        self.assertEqual(self.t.run(), 10)
        text = self.t.report.read_text()
        text.encode("ascii")
        # The helper's own wording is the only place these characters may appear.
        for line in self.t.lines():
            name_part = line.split("left out ", 1)[-1].split(" (", 1)[0] if "left out " in line else ""
            for ch in '&%^!"<>|':
                self.assertNotIn(ch, name_part)

    def test_tilde_prefixed_names_survive(self):
        # The bootstrapper's own temp helpers are named ~something.py and appear in every report.
        self.t.put("~helper.py", "x = 1\n")
        self.assertEqual(self.t.run(), 0)
        self.assertIn("[INFO] pipreqs pre-check: ~helper.py encoding=utf-8 parsed=yes", self.t.lines())

    def test_warn_lines_are_capped_with_a_remainder_line(self):
        for i in range(30):
            self.t.put("bad%02d.py" % i, b"\xe9\n")
        self.assertEqual(self.t.run(), 10)
        warns = [ln for ln in self.t.lines() if ln.startswith("[WARN]")]
        self.assertEqual(len(warns), 26)
        self.assertIn("5 more file(s) left out", warns[-1])
        self.assertIn("30 left out", self.t.lines()[-1])

    def test_info_lines_are_capped(self):
        for i in range(120):
            self.t.put("ok%03d.py" % i, "x = 1\n")
        self.assertEqual(self.t.run(), 0)
        infos = [ln for ln in self.t.lines() if "encoding=" in ln]
        self.assertEqual(len(infos), 100)
        self.assertIn("120 .py file(s)", self.t.lines()[-1])


class CommandLine(TreeCase):
    def _cli(self, *args):
        return subprocess.run([sys.executable, str(SOURCE)] + list(args), capture_output=True, text=True)

    def test_exit_codes_through_the_cli(self):
        self.t.put("main.py", "import os\n")
        r = self._cli(str(self.t.src), str(self.t.stage), "", str(self.t.report))
        self.assertEqual(r.returncode, 0)
        self.t.put("bad.py", b"\xe9\n")
        r = self._cli(str(self.t.src), str(self.t.stage), "", str(self.t.report))
        self.assertEqual(r.returncode, 10)

    def test_internal_error_is_exit_three_with_a_one_line_reason(self):
        r = self._cli(str(self.t.src))  # missing arguments
        self.assertEqual(r.returncode, 3)
        self.assertIn("pipreqs_precheck failed", r.stderr)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)

    def test_unwritable_report_is_exit_three(self):
        self.t.put("main.py", "import os\n")
        r = self._cli(str(self.t.src), str(self.t.stage), "", str(self.t.src / "no-such-dir" / "r.txt"))
        self.assertEqual(r.returncode, 3)


class BatchCallSite(unittest.TestCase):
    def setUp(self):
        self.bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")

    def test_every_pipreqs_invocation_forces_utf8(self):
        lines = [ln for ln in self.bat.splitlines() if re.search(r"-m pipreqs\.pipreqs\b", ln) and "--savepath" in ln]
        self.assertGreaterEqual(len(lines), 3)  # direct, UTF-8 copy, robocopy fallback
        for ln in lines:
            self.assertIn("--encoding utf-8", ln, ln)

    def test_precheck_runs_before_the_direct_invocation(self):
        call = self.bat.index("call :pipreqs_precheck")
        direct = self.bat.index('"%HP_PY%" -m pipreqs.pipreqs . --force --mode compat --savepath "%HP_PIPREQS_TARGET%"')
        self.assertLess(call, direct)


class EmbeddedHelperBaseline(unittest.TestCase):
    def test_source_is_ascii(self):
        SOURCE.read_bytes().decode("ascii")

    def test_source_parses_under_python_39_grammar(self):
        # Fallback providers can hand HP_PY an older interpreter; syntax errors are not catchable.
        ast.parse(SOURCE.read_text(encoding="utf-8"), feature_version=(3, 9))


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_PIPREQS_PRECHECK=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_PIPREQS_PRECHECK payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_PIPREQS_PRECHECK base64 is out of sync with tools/pipreqs_precheck.py; "
            "run: python tools/sync_payload.py HP_PIPREQS_PRECHECK tools/pipreqs_precheck.py",
        )


if __name__ == "__main__":
    unittest.main()
