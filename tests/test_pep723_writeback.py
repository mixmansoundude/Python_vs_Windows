"""Tests for tools/pep723_writeback.py -- REQ-005.11 PEP 723 header write-back.

Covers read_packages/strip_pep723_block logic, main()'s skip-condition branches
that do not require a real uv binary, the strip-and-retry / restore-on-double-
failure sequence (via a mocked subprocess.run), and the base64
HP_PEP723_WRITEBACK payload sync (byte-equality of the embedded payload vs this
source -- mirrors PayloadSync in test_collect_submodules.py /
test_hidden_import_scan.py).
"""
import base64
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.pep723_writeback import (
    main,
    read_packages,
    run_uv_add,
    strip_pep723_block,
)

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "pep723_writeback.py"


class ReadPackages(unittest.TestCase):
    def _write(self, tmp, text):
        p = Path(tmp) / "pkgs.txt"
        p.write_text(text, encoding="utf-8")
        return str(p)

    def test_blank_and_comment_lines_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp, "requests\n\n# a comment\ncertifi\n   \n#another\n")
            self.assertEqual(read_packages(path), ["requests", "certifi"])

    def test_missing_file_returns_empty(self):
        self.assertEqual(read_packages("/nonexistent/path/pkgs.txt"), [])

    def test_whitespace_stripped(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(tmp, "  requests  \n\tclick\t\n")
            self.assertEqual(read_packages(path), ["requests", "click"])

    def test_pip_directives_filtered(self):
        # -e, -r, --hash, --index-url etc. are not PEP 508 specs and make uv's
        # clap parser exit 2 (the same code used to detect a malformed existing
        # header) -- confirmed directly against a real uv binary. Must be
        # filtered so a user's own requirements.txt containing one of these
        # doesn't cause main() to wrongly strip a valid header.
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(
                tmp,
                "requests\n-e .\n--hash=sha256:deadbeef\n-r other.txt\ncertifi\n",
            )
            self.assertEqual(read_packages(path), ["requests", "certifi"])


class StripPep723Block(unittest.TestCase):
    def test_removes_simple_block(self):
        text = (
            "# /// script\n"
            "# requires-python = \">=3.11\"\n"
            "# dependencies = [\"requests\"]\n"
            "# ///\n"
            "\n"
            "print('hello')\n"
        )
        self.assertEqual(strip_pep723_block(text), "\nprint('hello')\n")

    def test_no_block_returns_unchanged(self):
        text = "print('hello')\n"
        self.assertEqual(strip_pep723_block(text), text)

    def test_tolerates_trailing_whitespace_on_closing_fence(self):
        # astral-sh/uv#10918: a closing fence with trailing whitespace is
        # invalid to uv's strict parser but must still be recognized here.
        text = (
            "# /// script\n"
            "# dependencies = [\"requests\"]\n"
            "# ///   \n"
            "print('hello')\n"
        )
        self.assertEqual(strip_pep723_block(text), "print('hello')\n")

    def test_preserves_code_after_block(self):
        text = (
            "# /// script\n"
            "# dependencies = []\n"
            "# ///\n"
            "import requests\n"
            "requests.get('https://example.com')\n"
        )
        result = strip_pep723_block(text)
        self.assertNotIn("# /// script", result)
        self.assertIn("import requests", result)
        self.assertIn("requests.get", result)

    def test_stray_leftover_fence_not_left_behind(self):
        # A lazy strip could leave a stray closing fence, which newer uv
        # treats as a hard error (astral-sh/uv#19544 duplicate-block rejection).
        text = "# /// script\n# dependencies = []\n# ///\nprint(1)\n"
        result = strip_pep723_block(text)
        self.assertEqual(result.count("# ///"), 0)


class MainSkipConditions(unittest.TestCase):
    def test_bad_args(self):
        self.assertEqual(main([]), 1)
        self.assertEqual(main(["only_one_arg"]), 1)

    def test_empty_packages_file_skips_without_touching_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry = Path(tmp) / "app.py"
            entry.write_text("print('hi')\n", encoding="utf-8")
            pkgs = Path(tmp) / "pkgs.txt"
            pkgs.write_text("# nothing here\n\n", encoding="utf-8")
            before = entry.read_bytes()
            with patch("tools.pep723_writeback.subprocess.run") as mock_run:
                rc = main([str(entry), "uv", "python3", str(pkgs)])
            mock_run.assert_not_called()
            self.assertEqual(rc, 0)
            self.assertEqual(entry.read_bytes(), before)

    def test_non_utf8_entry_skips_without_invoking_uv(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry = Path(tmp) / "app.py"
            # A byte sequence that is not valid UTF-8 (lone continuation byte).
            entry.write_bytes(b"print('hi')\n\x93\x94\n")
            pkgs = Path(tmp) / "pkgs.txt"
            pkgs.write_text("requests\n", encoding="utf-8")
            before = entry.read_bytes()
            with patch("tools.pep723_writeback.subprocess.run") as mock_run:
                rc = main([str(entry), "uv", "python3", str(pkgs)])
            mock_run.assert_not_called()
            self.assertEqual(rc, 0)
            self.assertEqual(entry.read_bytes(), before)

    def test_lockfile_sidecar_skips_without_invoking_uv(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry = Path(tmp) / "app.py"
            entry.write_text("print('hi')\n", encoding="utf-8")
            (Path(tmp) / "app.py.lock").write_text("", encoding="utf-8")
            pkgs = Path(tmp) / "pkgs.txt"
            pkgs.write_text("requests\n", encoding="utf-8")
            before = entry.read_bytes()
            with patch("tools.pep723_writeback.subprocess.run") as mock_run:
                rc = main([str(entry), "uv", "python3", str(pkgs)])
            mock_run.assert_not_called()
            self.assertEqual(rc, 0)
            self.assertEqual(entry.read_bytes(), before)


class MainUvDispatch(unittest.TestCase):
    """Exercise main()'s uv-invocation branches via a mocked subprocess.run,
    so these do not depend on a real uv binary being present."""

    def _entry_and_pkgs(self, tmp, entry_text="print('hi')\n"):
        entry = Path(tmp) / "app.py"
        entry.write_text(entry_text, encoding="utf-8")
        pkgs = Path(tmp) / "pkgs.txt"
        pkgs.write_text("requests\n", encoding="utf-8")
        return entry, pkgs

    def test_success_prints_ok_with_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry, pkgs = self._entry_and_pkgs(tmp)
            with patch("tools.pep723_writeback.subprocess.run") as mock_run:
                mock_run.return_value.returncode = 0
                mock_run.return_value.stderr = ""
                with patch("builtins.print") as mock_print:
                    rc = main([str(entry), "uv", "python3", str(pkgs)])
            self.assertEqual(rc, 0)
            mock_print.assert_called_once_with("OK:1")

    def test_malformed_header_strip_and_retry_succeeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry, pkgs = self._entry_and_pkgs(
                tmp,
                entry_text="# /// script\nbroken toml (((\n# ///\nprint('hi')\n",
            )
            calls = {"n": 0}

            def fake_run(cmd, capture_output, text, timeout=None):
                calls["n"] += 1
                result = unittest.mock.Mock()
                result.returncode = 2 if calls["n"] == 1 else 0
                result.stderr = ""
                return result

            with patch("tools.pep723_writeback.subprocess.run", side_effect=fake_run):
                with patch("builtins.print") as mock_print:
                    rc = main([str(entry), "uv", "python3", str(pkgs)])
            self.assertEqual(rc, 0)
            self.assertEqual(calls["n"], 2)
            mock_print.assert_called_once_with("OK:1")
            # The block was stripped before the retry.
            self.assertNotIn("# /// script", entry.read_text(encoding="utf-8"))

    def test_double_failure_restores_original_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            original = "# /// script\nbroken toml (((\n# ///\nprint('hi')\n"
            entry, pkgs = self._entry_and_pkgs(tmp, entry_text=original)

            def fake_run(cmd, capture_output, text, timeout=None):
                result = unittest.mock.Mock()
                result.returncode = 2
                result.stderr = ""
                return result

            with patch("tools.pep723_writeback.subprocess.run", side_effect=fake_run):
                with patch("builtins.print") as mock_print:
                    rc = main([str(entry), "uv", "python3", str(pkgs)])
            self.assertEqual(rc, 1)
            mock_print.assert_called_once_with("ERROR:strip_retry_failed:2")
            # Original (still-malformed) content must be restored byte-for-byte.
            self.assertEqual(entry.read_text(encoding="utf-8"), original)

    def test_malformed_header_strip_and_retry_preserves_crlf(self):
        # Regression test: a text-mode read without newline="" would collapse
        # all CRLF in the file to LF before the stripped write, silently
        # violating the "no line-ending normalization, anywhere, ever" rule.
        with tempfile.TemporaryDirectory() as tmp:
            entry, pkgs = self._entry_and_pkgs(tmp)
            entry.write_bytes(
                b"# /// script\r\nbroken toml (((\r\n# ///\r\nprint('hi')\r\n"
            )
            calls = {"n": 0}

            def fake_run(cmd, capture_output, text, timeout=None):
                calls["n"] += 1
                result = unittest.mock.Mock()
                result.returncode = 2 if calls["n"] == 1 else 0
                result.stderr = ""
                return result

            with patch("tools.pep723_writeback.subprocess.run", side_effect=fake_run):
                with patch("builtins.print"):
                    rc = main([str(entry), "uv", "python3", str(pkgs)])
            self.assertEqual(rc, 0)
            after = entry.read_bytes()
            self.assertIn(b"\r\n", after)
            self.assertNotIn(b"# /// script", after)

    def test_double_failure_restore_preserves_crlf(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry, pkgs = self._entry_and_pkgs(tmp)
            original = b"# /// script\r\nbroken toml (((\r\n# ///\r\nprint('hi')\r\n"
            entry.write_bytes(original)

            def fake_run(cmd, capture_output, text, timeout=None):
                result = unittest.mock.Mock()
                result.returncode = 2
                result.stderr = ""
                return result

            with patch("tools.pep723_writeback.subprocess.run", side_effect=fake_run):
                with patch("builtins.print"):
                    rc = main([str(entry), "uv", "python3", str(pkgs)])
            self.assertEqual(rc, 1)
            self.assertEqual(entry.read_bytes(), original)

    def test_timeout_treated_as_generic_error_no_hang(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry, pkgs = self._entry_and_pkgs(tmp)
            before = entry.read_bytes()
            with patch(
                "tools.pep723_writeback.subprocess.run",
                side_effect=subprocess.TimeoutExpired(cmd="uv", timeout=120),
            ):
                with patch("builtins.print") as mock_print:
                    rc = main([str(entry), "uv", "python3", str(pkgs)])
            self.assertEqual(rc, 1)
            mock_print.assert_called_once_with("ERROR:uv_rc_1")
            self.assertEqual(entry.read_bytes(), before)

    def test_other_nonzero_exit_is_generic_error_no_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry, pkgs = self._entry_and_pkgs(tmp)
            before = entry.read_bytes()
            with patch("tools.pep723_writeback.subprocess.run") as mock_run:
                mock_run.return_value.returncode = 1
                mock_run.return_value.stderr = "some error"
                with patch("builtins.print") as mock_print:
                    rc = main([str(entry), "uv", "python3", str(pkgs)])
            self.assertEqual(rc, 1)
            mock_print.assert_called_once_with("ERROR:uv_rc_1")
            self.assertEqual(entry.read_bytes(), before)

    def test_run_uv_add_command_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry, _ = self._entry_and_pkgs(tmp)
            with patch("tools.pep723_writeback.subprocess.run") as mock_run:
                mock_run.return_value.returncode = 0
                mock_run.return_value.stderr = ""
                run_uv_add(str(entry), "uv", "python3", ["requests", "click"])
            args, kwargs = mock_run.call_args
            cmd = args[0]
            self.assertEqual(
                cmd,
                ["uv", "add", "--script", str(entry), "-p", "python3", "requests", "click"],
            )
            self.assertTrue(kwargs.get("capture_output"))
            self.assertTrue(kwargs.get("text"))


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_PEP723_WRITEBACK=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_PEP723_WRITEBACK payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_PEP723_WRITEBACK base64 is out of sync with tools/pep723_writeback.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
