"""Cross-platform unit tests for tools/find_entry.py (REQ-002 entry selection).

Covers the deterministic selection order, the tightened __main__ detection
(pass/docstring-only guards do not count), the alphabetical fallback that fixes
the previously-silent empty-entry gap, and that the base64 HP_FIND_ENTRY payload
embedded in run_setup.bat matches this source.
"""
import base64
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIND_ENTRY = REPO / "tools" / "find_entry.py"


def _run(files):
    """Write files into a temp dir, run find_entry there, return (stdout, stderr)."""
    with tempfile.TemporaryDirectory() as d:
        for name, content in files.items():
            (Path(d) / name).write_text(content, encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(FIND_ENTRY)],
            cwd=d,
            capture_output=True,
            text=True,
        )
        return proc.stdout.strip(), proc.stderr


def _rc(files):
    """Run find_entry in a temp dir; return (stdout pick, exit code)."""
    with tempfile.TemporaryDirectory() as d:
        for name, content in files.items():
            (Path(d) / name).write_text(content, encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(FIND_ENTRY)],
            cwd=d,
            capture_output=True,
            text=True,
        )
        return proc.stdout.strip(), proc.returncode


class FindEntryExitCode(unittest.TestCase):
    """Exit code signals selection certainty to run_setup.bat: 0 = clear pick,
    3 (AMBIGUOUS_RC) = alphabetical fallback -> the only case that offers the picker."""

    def test_rc_preferred_is_clear(self):
        self.assertEqual(_rc({"zzz.py": "x=1\n", "main.py": "x=1\n"}), ("main.py", 0))

    def test_rc_single_is_clear(self):
        self.assertEqual(_rc({"solo.py": "print('hi')\n"}), ("solo.py", 0))

    def test_rc_sole_mainguard_is_clear(self):
        out, rc = _rc({"lib.py": "x=1\n", "tool.py": "if __name__ == '__main__':\n    print('go')\n"})
        self.assertEqual((out, rc), ("tool.py", 0))

    def test_rc_fallback_no_main_is_ambiguous(self):
        self.assertEqual(_rc({"plotting.py": "x=1\n", "analysis.py": "y=2\n"}), ("analysis.py", 3))

    def test_rc_fallback_multiple_guards_is_ambiguous(self):
        out, rc = _rc({
            "aaa.py": "x=1\n",
            "ggg.py": "if __name__ == '__main__':\n    print('g')\n",
            "hhh.py": "if __name__ == '__main__':\n    print('h')\n",
        })
        self.assertEqual((out, rc), ("ggg.py", 3))


class FindEntrySelection(unittest.TestCase):
    def test_single_file(self):
        out, _ = _run({"solo.py": "print('hi')\n"})
        self.assertEqual(out, "solo.py")

    def test_apple_double_metadata_file_excluded(self):
        # "._solo.py" is a macOS AppleDouble metadata sibling left behind when a
        # Windows user unzips something a Mac user zipped -- must not count as a
        # second candidate or affect selection.
        out, _ = _run({"solo.py": "print('hi')\n", "._solo.py": "junk\x00bytes"})
        self.assertEqual(out, "solo.py")

    def test_preferred_wins_over_generic(self):
        out, _ = _run({"zzz.py": "x=1\n", "main.py": "x=1\n"})
        self.assertEqual(out, "main.py")

    def test_preferred_order_run_beats_cli(self):
        out, _ = _run({"cli.py": "x=1\n", "run.py": "x=1\n"})
        self.assertEqual(out, "run.py")

    def test_single_substantive_main_guard(self):
        out, _ = _run({
            "lib.py": "x = 1\n",
            "tool.py": "if __name__ == '__main__':\n    print('go')\n",
        })
        self.assertEqual(out, "tool.py")

    def test_pass_only_guard_does_not_count(self):
        # utils.py has a pass-only guard; solution.py has none. Neither is PREFERRED,
        # so the tightened has_main yields zero candidates -> alphabetical fallback.
        out, err = _run({
            "utils.py": "def helper():\n    return 1\nif __name__ == '__main__':\n    pass\n",
            "solution.py": "value = 42\n",
        })
        self.assertEqual(out, "solution.py")
        self.assertIn("alphabetical fallback", err)

    def test_substantive_guard_beats_pass_only_guard(self):
        # Only the real guard counts -> exactly one candidate, selected directly.
        out, _ = _run({
            "aaa_helper.py": "if __name__ == '__main__':\n    pass\n",
            "bbb_run.py": "if __name__ == '__main__':\n    print('run')\n",
        })
        self.assertEqual(out, "bbb_run.py")

    def test_broad_gap_no_main_anywhere_alphabetical(self):
        out, err = _run({"plotting.py": "x=1\n", "analysis.py": "y=2\n"})
        self.assertEqual(out, "analysis.py")
        self.assertIn("alphabetical fallback", err)

    def test_multiple_real_guards_alphabetical_among_candidates(self):
        # Two substantive guards; fallback picks alphabetically among the candidates,
        # not among all files (so the no-guard 'aaa.py' is not chosen).
        out, _ = _run({
            "aaa.py": "x=1\n",
            "ggg.py": "if __name__ == '__main__':\n    print('g')\n",
            "hhh.py": "if __name__ == '__main__':\n    print('h')\n",
        })
        self.assertEqual(out, "ggg.py")

    def test_main_in_string_is_not_a_guard(self):
        # "__main__" appearing only in a string/comment must not be treated as a guard
        # (the old substring check would have mis-detected lib.py).
        out, _ = _run({
            "lib.py": "marker = '__main__'  # not a guard\n",
            "real.py": "if __name__ == '__main__':\n    print('real')\n",
        })
        self.assertEqual(out, "real.py")

    def test_docstring_only_guard_does_not_count(self):
        out, err = _run({
            "alpha.py": "if __name__ == '__main__':\n    'just a docstring'\n",
            "beta.py": "z = 0\n",
        })
        self.assertEqual(out, "alpha.py")  # alphabetical fallback (no real guard)
        self.assertIn("alphabetical fallback", err)

    def test_nested_guard_inside_function_does_not_count(self):
        # A guard nested in a def/class is not a module entry point; only the
        # top-level program (aaa_program.py) should be considered -> fallback.
        out, err = _run({
            "aaa_program.py": "def go():\n    return 1\n",
            "zlib_helper.py": "def run():\n    if __name__ == '__main__':\n        print('x')\n",
        })
        self.assertEqual(out, "aaa_program.py")
        self.assertIn("alphabetical fallback", err)

    def test_unparseable_file_is_not_a_guard(self):
        # A syntactically broken file containing "__main__" only in a string must
        # not be selected via has_main; the real entry wins.
        out, _ = _run({
            "broken.py": "def (:  # syntax error\nmsg = 'see __main__'\n",
            "real.py": "if __name__ == '__main__':\n    print('real')\n",
        })
        self.assertEqual(out, "real.py")


UNITTEST_RUNNER = (
    "import unittest\n"
    "class T(unittest.TestCase):\n"
    "    def test_x(self):\n"
    "        self.assertTrue(True)\n"
    "if __name__ == '__main__':\n"
    "    unittest.main()\n"
)
UNITTEST_NO_GUARD = "import unittest\nclass T(unittest.TestCase):\n    pass\n"
PROGRAM_GUARD = "if __name__ == '__main__':\n    print('go')\n"


class FindEntryTestModules(unittest.TestCase):
    """README REQ-002.27 and REQ-002.28 (backlog Item 125): a test module is not taken as the
    program while another file could be, and is still taken when nothing else exists."""

    def test_unittest_runner_loses_to_the_program_it_tests(self):
        # Both files have a guard, so the alphabetical rule applied: test_weather.py sorts before weather.py.
        self.assertEqual(
            _rc({"weather.py": PROGRAM_GUARD, "test_weather.py": UNITTEST_RUNNER}),
            ("weather.py", 0),
        )

    def test_test_module_with_the_only_guard_loses_to_a_library(self):
        out, err = _run({"calc.py": "x = 1\n", "calc_test.py": UNITTEST_RUNNER})
        self.assertEqual(out, "calc.py")
        self.assertIn("selecting 'calc.py' (alphabetical fallback)", err)

    def test_library_and_tests_stay_ambiguous(self):
        # No program is named, so the picker of an interactive run is still offered (exit 3).
        self.assertEqual(_rc({"calc.py": "x = 1\n", "test_calc.py": UNITTEST_RUNNER}), ("calc.py", 3))

    def test_pytest_import_makes_a_test_module(self):
        for source in ("import pytest\n", "from pytest import fixture\n", "import unittest.mock\n",
                       "from unittest import TestCase\n"):
            with self.subTest(source=source):
                files = {"tool.py": PROGRAM_GUARD, "test_tool.py": source + PROGRAM_GUARD}
                self.assertEqual(_rc(files), ("tool.py", 0))

    def test_an_import_inside_a_function_counts(self):
        source = "def run():\n    import unittest\n    return unittest\nif __name__ == '__main__':\n    run()\n"
        self.assertEqual(_rc({"app_logic.py": PROGRAM_GUARD, "test_logic.py": source}), ("app_logic.py", 0))

    def test_a_script_named_like_a_test_that_imports_no_framework_is_kept(self):
        # A lab script that drives an instrument and is called test_scope.py is a program.
        files = {"scope.py": "x = 1\n", "test_scope.py": PROGRAM_GUARD}
        self.assertEqual(_rc(files), ("test_scope.py", 0))

    def test_names_that_only_look_like_tests_are_kept(self):
        for name in ("test.py", "tests.py", "latest_test_data.py", "contest.py", "testing_tools.py"):
            with self.subTest(name=name):
                self.assertEqual(_rc({"lib.py": "x = 1\n", name: UNITTEST_RUNNER}), (name, 0))

    def test_the_name_alone_is_not_enough_for_a_framework_word_in_text(self):
        # The word is in a string and a comment, not an import statement.
        source = "note = 'import unittest'  # import pytest\n" + PROGRAM_GUARD
        self.assertEqual(_rc({"lib.py": "x = 1\n", "test_lib.py": source}), ("test_lib.py", 0))

    def test_a_test_module_that_does_not_parse_is_not_one(self):
        files = {"zeta.py": PROGRAM_GUARD, "test_broken.py": "import unittest\ndef (:\n"}
        self.assertEqual(_rc(files), ("zeta.py", 0))

    def test_only_test_modules_still_give_an_entry(self):
        self.assertEqual(_rc({"test_a.py": UNITTEST_RUNNER, "test_b.py": UNITTEST_NO_GUARD}), ("test_a.py", 0))
        out, rc = _rc({"test_a.py": UNITTEST_NO_GUARD, "test_b.py": UNITTEST_NO_GUARD})
        self.assertEqual((out, rc), ("test_a.py", 3))
        out, rc = _rc({"test_a.py": UNITTEST_RUNNER, "b_test.py": UNITTEST_RUNNER})
        self.assertEqual((out, rc), ("b_test.py", 3))

    def test_the_four_names_a_sole_file_and_a_pick_do_not_change(self):
        self.assertEqual(_rc({"main.py": "x = 1\n", "test_main.py": UNITTEST_RUNNER}), ("main.py", 0))
        self.assertEqual(_rc({"test_only.py": UNITTEST_RUNNER}), ("test_only.py", 0))
        self.assertEqual(_rc({"test_only.py": UNITTEST_NO_GUARD}), ("test_only.py", 0))

    def test_name_match_ignores_case(self):
        files = {"weather.py": PROGRAM_GUARD, "Test_Weather.py": UNITTEST_RUNNER}
        self.assertEqual(_rc(files), ("weather.py", 0))


class FindEntryTestModuleRows(unittest.TestCase):
    """The Windows rows that show REQ-002.27 and REQ-002.28 keep literal ids and tags, because the
    trace scans read them as text (tests/test_req_trace.py, tests/test_req_shall_trace.py)."""

    ROWS = (
        ("self.entry.testmodule.guard", "REQ-002.27"),
        ("self.entry.testmodule.library", "REQ-002.27"),
        ("self.entry.testmodule.script", "REQ-002.27"),
        ("self.entry.testmodule.only", "REQ-002.28"),
    )

    def setUp(self):
        self.text = (REPO / "tests" / "selfapps_entry.ps1").read_text(encoding="utf-8")

    def test_each_row_is_written_once_with_its_tag(self):
        for row_id, tag in self.ROWS:
            with self.subTest(row=row_id):
                pattern = re.compile(r"Write-EntryRow -Id '%s'[^\r\n]*-Tag @\{ req = '%s' \}" % (re.escape(row_id), re.escape(tag)))
                self.assertEqual(len(pattern.findall(self.text)), 1, row_id)

    def test_each_row_is_in_the_results_summary(self):
        for row_id, _ in self.ROWS:
            with self.subTest(row=row_id):
                self.assertIn("@{ Id = '%s'; Expected = " % row_id, self.text)

    def test_the_registry_names_every_row(self):
        doc = (REPO / "docs" / "agent-ndjson.md").read_text(encoding="utf-8")
        for row_id, _ in self.ROWS:
            with self.subTest(row=row_id):
                self.assertIn(row_id, doc)


class FindEntryPayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_FIND_ENTRY=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_FIND_ENTRY payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = FIND_ENTRY.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_FIND_ENTRY base64 is out of sync with tools/find_entry.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
