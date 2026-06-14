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


class FindEntrySelection(unittest.TestCase):
    def test_single_file(self):
        out, _ = _run({"solo.py": "print('hi')\n"})
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
