"""Tests for tools/collect_submodules.py -- the pre-build --collect-submodules
double-gate (package must be BOTH imported by user source AND installed).

Covers the gating matrix, adversarial import-scan cases (relative imports,
word-boundary near-misses, comments/docstrings), AST-failure regex fallback,
flag ordering, and the base64 HP_COLLECT_SUBMODULES payload sync (byte-equality
of the embedded payload vs this source -- mirrors ParseWarnPayloadSync).
"""
import base64
import re
import tempfile
import unittest
from pathlib import Path

from tools.collect_submodules import (
    DYNAMIC_PKGS,
    collect_flags,
    imported_top_levels,
)

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "collect_submodules.py"

# installed_check stubs for the gating tests (no real installs needed).
ALL_INSTALLED = lambda name: True
NONE_INSTALLED = lambda name: False


def _project(files):
    """Create a temp project dir from {relpath: text} and return its path object.

    Caller is responsible for keeping the TemporaryDirectory alive; use the
    context-manager helper _flags() / _used() instead for one-shot checks.
    """
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name)
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    return tmp, root


def _flags(files, installed_check):
    tmp, root = _project(files)
    try:
        return collect_flags(str(root), installed_check=installed_check)
    finally:
        tmp.cleanup()


def _used(files):
    tmp, root = _project(files)
    try:
        return imported_top_levels(str(root))
    finally:
        tmp.cleanup()


class GatingMatrix(unittest.TestCase):
    def test_curated_set_is_exactly_the_agreed_four(self):
        # Guards against silently widening the set (bloat) or dropping a package.
        self.assertEqual(DYNAMIC_PKGS, ("sklearn", "matplotlib", "scipy", "plotly"))

    def test_used_and_installed_emits_flag(self):
        flags = _flags({"app.py": "import sklearn\n"}, ALL_INSTALLED)
        self.assertEqual(flags, ["--collect-submodules=sklearn"])

    def test_used_but_not_installed_emits_nothing(self):
        # Imported but absent -> a flag would make PyInstaller error out.
        flags = _flags({"app.py": "import sklearn\n"}, NONE_INSTALLED)
        self.assertEqual(flags, [])

    def test_installed_but_not_used_emits_nothing(self):
        # The anti-bloat case: package sits in a fat env but the app never uses it.
        flags = _flags({"app.py": "print('hello')\n"}, ALL_INSTALLED)
        self.assertEqual(flags, [])

    def test_neither_emits_nothing(self):
        flags = _flags({"app.py": "print('hello')\n"}, NONE_INSTALLED)
        self.assertEqual(flags, [])

    def test_multiple_used_preserve_dynamic_pkgs_order(self):
        # File lists scipy before sklearn; output must follow DYNAMIC_PKGS order.
        files = {"app.py": "import scipy\nimport sklearn\nimport plotly\n"}
        flags = _flags(files, ALL_INSTALLED)
        self.assertEqual(
            flags,
            [
                "--collect-submodules=sklearn",
                "--collect-submodules=scipy",
                "--collect-submodules=plotly",
            ],
        )

    def test_only_curated_set_considered(self):
        # numpy/pandas are not in the curated set even if used+installed.
        flags = _flags({"app.py": "import numpy\nimport pandas\n"}, ALL_INSTALLED)
        self.assertEqual(flags, [])


class ImportScan(unittest.TestCase):
    def test_submodule_import_counts_top_level(self):
        self.assertIn("matplotlib", _used({"a.py": "import matplotlib.pyplot as plt\n"}))

    def test_from_submodule_counts_top_level(self):
        self.assertIn("sklearn", _used({"a.py": "from sklearn.ensemble import RandomForestClassifier\n"}))

    def test_relative_import_not_counted(self):
        # 'from . import scipy' is a LOCAL module, not the third-party scipy.
        self.assertNotIn("scipy", _used({"pkg/__init__.py": "", "pkg/a.py": "from . import scipy\n"}))

    def test_word_boundary_near_miss_not_matched(self):
        # 'scipython' must not be read as 'scipy'.
        used = _used({"a.py": "import scipython\n"})
        self.assertNotIn("scipy", used)

    def test_commented_import_not_counted(self):
        self.assertNotIn("sklearn", _used({"a.py": "# import sklearn\nprint('x')\n"}))

    def test_string_literal_import_not_counted(self):
        self.assertNotIn("sklearn", _used({"a.py": "x = 'import sklearn'\n"}))

    def test_multi_file_project_scanned(self):
        used = _used({"main.py": "print(1)\n", "lib/helper.py": "import plotly\n"})
        self.assertIn("plotly", used)

    def test_infra_dirs_skipped(self):
        # An import inside dist/ / .venv / build must not count.
        files = {
            "app.py": "print('x')\n",
            "dist/bundled.py": "import sklearn\n",
            ".venv/site.py": "import scipy\n",
            "build/gen.py": "import matplotlib\n",
        }
        used = _used(files)
        self.assertNotIn("sklearn", used)
        self.assertNotIn("scipy", used)
        self.assertNotIn("matplotlib", used)

    def test_tilde_files_skipped(self):
        self.assertNotIn("sklearn", _used({"~scratch.py": "import sklearn\n"}))

    def test_syntax_error_file_uses_regex_fallback(self):
        # Unparseable Python still gets a conservative regex scan.
        used = _used({"a.py": "import matplotlib\ndef (:\n  pass\n"})
        self.assertIn("matplotlib", used)

    def test_syntax_error_regex_word_boundary(self):
        # Regex fallback must also respect the word boundary.
        used = _used({"a.py": "import scipython\ndef (:\n"})
        self.assertNotIn("scipy", used)


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_COLLECT_SUBMODULES=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_COLLECT_SUBMODULES payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_COLLECT_SUBMODULES base64 is out of sync with tools/collect_submodules.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
