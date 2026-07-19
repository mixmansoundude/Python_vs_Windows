"""Tests for tools/detect_visa.py -- REQ-008 NI-VISA import scanner. Decides
whether the frozen EXE needs the NI-VISA driver install branch by scanning
the project directory for pyvisa-style imports.

The script is a flat, top-level script that reads sys.argv/os.getcwd() and
prints "1"/"0" to stdout, so it is exercised via subprocess with cwd set to
a crafted temp project (mirrors tests/test_find_entry.py's pattern).

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


def _run(files):
    """Write files into a temp project dir, run detect_visa.py there,
    return stdout ("1" or "0")."""
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
        return proc.stdout


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
        self.assertEqual(_run({"pkg/sub/mod.py": "import pyvisa\n"}), "1")

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
