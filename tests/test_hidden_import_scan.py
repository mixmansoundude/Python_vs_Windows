"""Tests for tools/hidden_import_scan.py -- the Slice 2 strict, double-gated
--hidden-import auto-recovery decision (ModuleNotFoundError + installed-in-env).

Covers the deterministic packaging-miss case, the user-typo / ImportError /
circular-import cases that must NOT trigger a rebuild, the already-tried loop
guard, platform-shim skips, dotted submodules, and the base64 payload sync.
"""
import base64
import re
import tempfile
import unittest
from pathlib import Path

from tools.hidden_import_scan import next_hidden_import, SKIP, main

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "hidden_import_scan.py"

INSTALLED = lambda name: True
NOT_INSTALLED = lambda name: False


def _mnfe(mod):
    """A realistic frozen-EXE traceback ending in ModuleNotFoundError."""
    return (
        "Traceback (most recent call last):\n"
        '  File "app.py", line 1, in <module>\n'
        "    import {0}\n"
        "ModuleNotFoundError: No module named '{0}'\n"
    ).format(mod)


class PackagingMiss(unittest.TestCase):
    def test_mnfe_installed_returns_module(self):
        # The deterministic win: missing from bundle but installed in env.
        self.assertEqual(next_hidden_import(_mnfe("colorama"), installed_check=INSTALLED), "colorama")

    def test_mnfe_not_installed_returns_nothing(self):
        # User typo / genuinely-absent dep -> ZERO rebuilds.
        self.assertEqual(next_hidden_import(_mnfe("nonexistant"), installed_check=NOT_INSTALLED), "")

    def test_dotted_submodule_returned_whole_gated_on_top(self):
        # find_spec gate is called with top-level 'plotly'; full dotted name emitted.
        seen = []
        def check(name):
            seen.append(name)
            return name == "plotly"
        self.assertEqual(
            next_hidden_import(_mnfe("plotly.graph_objects"), installed_check=check),
            "plotly.graph_objects",
        )
        self.assertEqual(seen, ["plotly"])  # gated on top-level only, no submodule import

    def test_first_installed_untried_wins(self):
        text = _mnfe("aaa") + _mnfe("bbb")
        # aaa not installed, bbb installed -> bbb
        self.assertEqual(next_hidden_import(text, installed_check=lambda n: n == "bbb"), "bbb")


class MustNotTrigger(unittest.TestCase):
    def test_cannot_import_name_ignored(self):
        # ImportError: cannot import name -> no --hidden-import target derivable.
        text = "ImportError: cannot import name 'slow_compute' from 'library'\n"
        self.assertEqual(next_hidden_import(text, installed_check=INSTALLED), "")

    def test_bare_importerror_ignored(self):
        text = "ImportError: DLL load failed while importing _ssl\n"
        self.assertEqual(next_hidden_import(text, installed_check=INSTALLED), "")

    def test_tkinter_attribute_typo_ignored(self):
        # from tkinter import text  (should be Text) -> cannot import name, user bug.
        text = "ImportError: cannot import name 'text' from 'tkinter'\n"
        self.assertEqual(next_hidden_import(text, installed_check=INSTALLED), "")

    def test_already_tried_skipped(self):
        # Prevents the loop from re-suggesting the same module forever.
        self.assertEqual(
            next_hidden_import(_mnfe("colorama"), already_tried=["colorama"], installed_check=INSTALLED),
            "",
        )

    def test_platform_shim_skipped(self):
        for shim in ("posix", "fcntl", "_posixsubprocess"):
            self.assertIn(shim, SKIP)
            self.assertEqual(next_hidden_import(_mnfe(shim), installed_check=INSTALLED), "")

    def test_underscore_module_skipped(self):
        self.assertEqual(next_hidden_import(_mnfe("_internal_thing"), installed_check=INSTALLED), "")

    def test_no_error_returns_nothing(self):
        self.assertEqual(next_hidden_import("plotly imported ok\n", installed_check=INSTALLED), "")

    def test_empty_returns_nothing(self):
        self.assertEqual(next_hidden_import("", installed_check=INSTALLED), "")


class TriedListProgression(unittest.TestCase):
    def test_second_module_after_first_tried(self):
        # Iteration 2: first module already added, the next MNFE is surfaced.
        text = _mnfe("aaa") + _mnfe("bbb")
        self.assertEqual(
            next_hidden_import(text, already_tried=["aaa"], installed_check=INSTALLED),
            "bbb",
        )


class MainCli(unittest.TestCase):
    def test_main_reads_file_and_writes_stdout(self):
        # End-to-end via the real find_spec gate using a stdlib module name that
        # is always importable ('json'); proves file read + emit path.
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "err.txt"
            p.write_text(_mnfe("json"), encoding="utf-8")
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                main([str(p)])
            self.assertEqual(buf.getvalue(), "json")

    def test_main_missing_file_silent(self):
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            main(["/no/such/file/xyz.txt"])
        self.assertEqual(buf.getvalue(), "")


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_HIDDEN_IMPORT_SCAN=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_HIDDEN_IMPORT_SCAN payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_HIDDEN_IMPORT_SCAN base64 is out of sync with tools/hidden_import_scan.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
