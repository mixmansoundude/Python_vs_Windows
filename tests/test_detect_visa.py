"""Tests for tools/detect_visa.py -- REQ-008 NI-VISA import scanner. Decides
whether the frozen EXE needs the NI-VISA driver install branch by scanning
the project directory for pyvisa-style imports.

The script is a flat, top-level script that reads sys.argv/os.getcwd() and
prints "0"/"1"/"2" to stdout ("2" = matches only below a subfolder, Item 78
slice 2), so it is exercised via subprocess with cwd set to a crafted temp
project (mirrors tests/test_find_entry.py's pattern).

Covers positive/negative detection, the "~"/"."-prefixed dir and file
skip rules, recursive nesting, and the base64 HP_DETECT_VISA payload sync
(byte-equality of the embedded payload vs this source -- mirrors
CollectSubmodules/HiddenImportScan/DetectPython/PyprojDeps PayloadSync).
"""
import base64
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "detect_visa.py"


def _run_full(files):
    """Write files into a temp project dir, run detect_visa.py there,
    return (stdout, stderr, ~visa.where text or None)."""
    with tempfile.TemporaryDirectory() as d:
        for rel, content in files.items():
            p = Path(d) / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content, encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(SOURCE)],
            cwd=d,
            capture_output=True,
            text=True,
        )
        where = Path(d) / "~visa.where"
        where_text = where.read_text(encoding="ascii") if where.exists() else None
        return proc.stdout, proc.stderr, where_text


def _run(files):
    """Return stdout only ("0", "1" or "2")."""
    return _run_full(files)[0]


class VisaDetection(unittest.TestCase):
    def test_no_visa_import_returns_0(self):
        self.assertEqual(_run({"app.py": "import requests\nprint('hi')\n"}), "0")

    def test_plain_import_pyvisa_returns_1(self):
        self.assertEqual(_run({"app.py": "import pyvisa\n"}), "1")

    def test_from_pyvisa_import_returns_1(self):
        self.assertEqual(_run({"app.py": "from pyvisa import ResourceManager\n"}), "1")

    def test_import_visa_returns_1(self):
        self.assertEqual(_run({"app.py": "import visa\n"}), "1")

    def test_nested_directory_is_scanned(self):
        # Still scanned (the README documents it); a match only below a subfolder is
        # reported as "2", not "1", so the batch can ask before installing the driver.
        self.assertEqual(_run({"pkg/sub/mod.py": "import pyvisa\n"}), "2")

    def test_tilde_prefixed_directory_skipped(self):
        self.assertEqual(_run({"~scratch/mod.py": "import pyvisa\n"}), "0")

    def test_dot_prefixed_directory_skipped(self):
        self.assertEqual(_run({".venv/mod.py": "import pyvisa\n"}), "0")

    def test_tilde_prefixed_file_skipped(self):
        self.assertEqual(_run({"~backup.py": "import pyvisa\n"}), "0")

    def test_non_py_file_skipped(self):
        self.assertEqual(_run({"notes.txt": "import pyvisa\n"}), "0")

    def test_indented_import_inside_function_still_matches(self):
        # PATTERNS anchor on ^\s* per-line (re.MULTILINE), so an indented
        # import inside a function body is still detected.
        self.assertEqual(_run({"app.py": "def load():\n    import pyvisa\n"}), "1")

    def test_import_pyvista_false_positive_fixed(self):
        # PATTERNS now anchors on the full module name ("pyvisa") with a
        # trailing \b instead of a truncated "pyvis" prefix, so an unrelated
        # import merely starting with those letters -- e.g. "import
        # pyvista", a real, popular, unrelated 3D-visualization package --
        # no longer matches. This assertion previously documented the
        # opposite (over-broad) behavior; see CLAUDE.md's Closed Backlog for
        # the fix.
        self.assertEqual(_run({"app.py": "import pyvista\n"}), "0")

    def test_import_vision_false_positive_fixed(self):
        self.assertEqual(_run({"app.py": "import vision\n"}), "0")

    def test_import_pyviscoelastic_false_positive_fixed(self):
        self.assertEqual(_run({"app.py": "import pyviscoelastic\n"}), "0")

    def test_dotted_submodule_import_still_matches(self):
        # \b after the full word ("pyvisa") still allows a dotted submodule
        # import to match, since "." is a non-word character.
        self.assertEqual(_run({"app.py": "import pyvisa.constants\n"}), "1")
        self.assertEqual(
            _run({"app.py": "from pyvisa.constants import StatusCode\n"}), "1")


class SubfolderOnly(unittest.TestCase):
    """Item 78 slice 2: 0 nothing, 1 a match next to run_setup.bat, 2 matches only below a subfolder.
    The scanner logs up to three matching paths on stderr (the batch appends it to the setup log) and
    writes the first path to ~visa.where in a character set that is safe to echo from cmd.exe."""

    def test_subfolder_only_returns_2(self):
        self.assertEqual(_run({"main.py": "print(1)\n", "archive/old_tool.py": "import visa\n"}), "2")

    def test_top_folder_match_returns_1_even_when_a_subfolder_also_matches(self):
        files = {"main.py": "import pyvisa\n", "archive/old_tool.py": "import visa\n"}
        self.assertEqual(_run(files), "1")

    def test_no_match_returns_0_and_writes_nothing(self):
        out, err, where = _run_full({"main.py": "print(1)\n", "archive/old.py": "import os\n"})
        self.assertEqual((out, err, where), ("0", "", None))

    def test_top_folder_match_is_logged_as_top_folder(self):
        out, err, where = _run_full({"main.py": "import pyvisa\n"})
        self.assertEqual(out, "1")
        self.assertEqual(err.strip(), "[VISA] pyvisa/visa import found in: main.py (top folder)")
        self.assertEqual(where.strip(), "main.py")

    def test_subfolder_match_is_logged_with_a_backslash_path(self):
        out, err, where = _run_full({"main.py": "print(1)\n", "archive/old_tool.py": "import visa\n"})
        self.assertEqual(out, "2")
        self.assertEqual(err.strip(), "[VISA] pyvisa/visa import found in: archive\\old_tool.py (subfolder)")
        self.assertEqual(where.strip(), "archive\\old_tool.py")

    def test_at_most_three_paths_are_logged(self):
        files = {"main.py": "print(1)\n"}
        for i in range(5):
            files["old%d/tool.py" % i] = "import visa\n"
        out, err, where = _run_full(files)
        self.assertEqual(out, "2")
        self.assertEqual(len([l for l in err.splitlines() if l.startswith("[VISA] pyvisa/visa import found in:")]), 3)

    def test_unsafe_characters_never_reach_the_log_or_the_where_file(self):
        out, err, where = _run_full({"main.py": "print(1)\n", "a&b%c^d/x(1).py": "import visa\n"})
        self.assertEqual(out, "2")
        logged_path = err.split("found in: ", 1)[1].rsplit(" (", 1)[0]
        for text in (logged_path, where):
            for bad in "&%^()<>|!\"":
                self.assertNotIn(bad, text)
        self.assertIn("a_b_c_d", where)

    def test_non_ascii_names_are_replaced_not_crashed_on(self):
        out, err, where = _run_full({"main.py": "print(1)\n", "caf\u00e9/tool.py": "import visa\n"})
        self.assertEqual(out, "2")
        self.assertTrue(where.strip().isascii())

    def test_tilde_where_file_is_not_scanned_as_source(self):
        # ~visa.where is written into the project folder; a second run must not trip over it.
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "main.py").write_text("print(1)\n", encoding="utf-8")
            (Path(d) / "~visa.where").write_text("import visa\n", encoding="ascii")
            proc = subprocess.run([sys.executable, str(SOURCE)], cwd=d, capture_output=True, text=True)
            self.assertEqual(proc.stdout, "0")


class GateStateIsPerRun(unittest.TestCase):
    """Item 78 slice 2: the remembered answer lives only as long as one bootstrapper run."""

    def setUp(self):
        self.bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")

    def test_decision_is_cleared_once_before_the_first_scan(self):
        # An HP_VISA_DECISION inherited from the calling terminal (or an earlier run in the same window) would be
        # read by :visa_subfolder_gate as a remembered answer and the question would never be asked. The clear must
        # be a top-of-run statement, not part of the VISA block, which a cascade re-entry runs again on purpose.
        clear = 'set "HP_VISA_DECISION="'
        self.assertEqual(self.bat.count(clear), 1, "exactly one clear of HP_VISA_DECISION")
        scan = self.bat.index('set "NEED_VISA=0"')
        gate = self.bat.index(":visa_subfolder_gate\n")
        self.assertLess(self.bat.index(clear), scan, "the clear must come before the scanner runs")
        self.assertLess(self.bat.index(clear), gate)


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_DETECT_VISA=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_DETECT_VISA payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_DETECT_VISA base64 is out of sync with tools/detect_visa.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
