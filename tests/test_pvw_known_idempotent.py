"""Tests for tools/pvw_known_idempotent.py -- Tier 2 of
docs/plan-autopep723-two-tier.md (HP_PVW_KNOWN_IDEMPOTENT).

Covers strip_pep723_block (mirrors tools/pep723_writeback.py's version -- same test shapes),
discover_dep_names's PEP-723-style output parsing, persist's discovery+uv-add-script sequence,
main()'s three exit-code branches (0 / 2 / other-nonzero) via a mocked subprocess.run that
dispatches on argv shape (run vs. check vs. add), run_script's force_fresh=True UV_NO_CACHE
workaround for astral-sh/uv#15156 (only used on post-persist retries, never the first attempt),
and the base64 HP_PVW_IDEMPOTENT payload sync.
"""
import base64
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from tools.pvw_known_idempotent import (
    discover_dep_names,
    main,
    persist,
    run_script,
    strip_pep723_block,
)

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "pvw_known_idempotent.py"


class StripPep723Block(unittest.TestCase):
    def test_removes_block_preserves_code(self):
        text = '# /// script\n# dependencies = ["requests"]\n# ///\nimport requests\nprint("hi")\n'
        self.assertEqual(strip_pep723_block(text), 'import requests\nprint("hi")\n')

    def test_tolerates_trailing_whitespace_on_closing_fence(self):
        text = '# /// script\n# dependencies = ["click"]\n# ///   \nimport click\n'
        self.assertEqual(strip_pep723_block(text), "import click\n")

    def test_no_block_present_unchanged(self):
        text = "import os\nprint('hi')\n"
        self.assertEqual(strip_pep723_block(text), text)


class RunScript(unittest.TestCase):
    """astral-sh/uv#15156 workaround: force_fresh must be opt-in and env-scoped only to that
    one call, never leaking UV_NO_CACHE into the default (first-attempt) invocation."""

    def test_default_call_passes_no_env_override(self):
        with patch("tools.pvw_known_idempotent.subprocess.run") as mock_run:
            mock_run.return_value = Mock(returncode=0)
            run_script("uvx", "app.py")
        _, kwargs = mock_run.call_args
        self.assertIsNone(kwargs.get("env"))

    def test_force_fresh_sets_uv_no_cache(self):
        with patch("tools.pvw_known_idempotent.subprocess.run") as mock_run:
            mock_run.return_value = Mock(returncode=0)
            run_script("uvx", "app.py", force_fresh=True)
        _, kwargs = mock_run.call_args
        self.assertEqual(kwargs.get("env", {}).get("UV_NO_CACHE"), "1")

    def test_call_is_bounded_by_a_timeout(self):
        # A GUI-mainloop or input()-waiting entry script must not hang the bootstrap
        # forever -- run_script is the live-execution call and had no timeout at all.
        with patch("tools.pvw_known_idempotent.subprocess.run") as mock_run:
            mock_run.return_value = Mock(returncode=0)
            run_script("uvx", "app.py")
        _, kwargs = mock_run.call_args
        self.assertIsNotNone(kwargs.get("timeout"))
        self.assertGreater(kwargs["timeout"], 0)

    def test_timeout_expired_returns_1_not_raise(self):
        with patch("tools.pvw_known_idempotent.subprocess.run") as mock_run:
            mock_run.side_effect = subprocess.TimeoutExpired(cmd=["uvx"], timeout=120)
            rc = run_script("uvx", "app.py")
        self.assertEqual(rc, 1)


class DiscoverDepNames(unittest.TestCase):
    def _run(self, stdout, returncode=0):
        with patch("tools.pvw_known_idempotent.subprocess.run") as mock_run:
            mock_run.return_value = Mock(returncode=returncode, stdout=stdout, stderr="")
            return discover_dep_names("uvx", "app.py")

    def test_extracts_names_from_dependency_array(self):
        stdout = '# /// script\n# dependencies = [\n#     "click",\n#     "requests",\n# ]\n# ///\n'
        self.assertEqual(self._run(stdout), ["click", "requests"])

    def test_no_dependencies_key_returns_empty(self):
        stdout = '# /// script\n# requires-python = ">=3.13"\n# ///\n'
        self.assertEqual(self._run(stdout), [])

    def test_nonzero_exit_returns_empty(self):
        self.assertEqual(self._run("", returncode=1), [])


class Persist(unittest.TestCase):
    def test_no_names_discovered_is_true_noop(self):
        with patch("tools.pvw_known_idempotent.subprocess.run") as mock_run:
            mock_run.return_value = Mock(returncode=0, stdout="# /// script\n# ///\n", stderr="")
            self.assertTrue(persist("uvx", "uv", "python", "app.py"))
            # Only the "check" call happens; no "add --script" call since nothing to add.
            self.assertEqual(mock_run.call_count, 1)

    def test_names_discovered_and_uv_add_succeeds(self):
        check_result = Mock(returncode=0, stdout='#     "requests",\n', stderr="")
        add_result = Mock(returncode=0)
        with patch("tools.pvw_known_idempotent.subprocess.run", side_effect=[check_result, add_result]):
            self.assertTrue(persist("uvx", "uv", "python", "app.py"))

    def test_uv_add_fails_returns_false(self):
        check_result = Mock(returncode=0, stdout='#     "requests",\n', stderr="")
        add_result = Mock(returncode=2)
        with patch("tools.pvw_known_idempotent.subprocess.run", side_effect=[check_result, add_result]):
            self.assertFalse(persist("uvx", "uv", "python", "app.py"))


def _run_result(argv, returncode, stdout=""):
    """Build a fake subprocess.run dispatcher keyed on whether argv contains 'check' or 'add'."""
    if "check" in argv:
        return Mock(returncode=0, stdout=stdout, stderr="")
    if "add" in argv:
        return Mock(returncode=0)
    return Mock(returncode=returncode)


class MainDispatch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.entry = Path(self.tmp.name) / "app.py"
        self.entry.write_text("import requests\nprint('hi')\n", encoding="utf-8")

    def test_rc0_persists_and_returns_0(self):
        def fake_run(cmd, **kwargs):
            return _run_result(cmd, returncode=0)
        with patch("tools.pvw_known_idempotent.subprocess.run", side_effect=fake_run):
            with patch("builtins.print") as mock_print:
                rc = main([str(self.entry), "uvx", "uv", "python"])
        self.assertEqual(rc, 0)
        mock_print.assert_called_once_with("RAN:persisted", file=sys.stderr)

    def test_rc2_malformed_header_strip_and_retry_succeeds(self):
        original = '# /// script\n# broken (((\n# ///\nimport requests\nprint("hi")\n'
        self.entry.write_text(original, encoding="utf-8")
        calls = {"run_count": 0}
        run_call_kwargs = []

        def fake_run(cmd, **kwargs):
            if "check" in cmd or "add" in cmd:
                return _run_result(cmd, returncode=0)
            calls["run_count"] += 1
            run_call_kwargs.append(kwargs)
            # First run (before strip) -> 2 (malformed); second run (after strip) -> 0 (clean).
            return Mock(returncode=2 if calls["run_count"] == 1 else 0)

        with patch("tools.pvw_known_idempotent.subprocess.run", side_effect=fake_run):
            with patch("builtins.print") as mock_print:
                rc = main([str(self.entry), "uvx", "uv", "python"])
        self.assertEqual(rc, 0)
        mock_print.assert_called_once_with("RAN:persisted_after_repair", file=sys.stderr)
        # Header block was actually stripped from the file.
        self.assertNotIn("broken (((", self.entry.read_text(encoding="utf-8"))
        # First attempt uses normal caching; the post-persist retry forces UV_NO_CACHE=1
        # (astral-sh/uv#15156 workaround).
        self.assertIsNone(run_call_kwargs[0].get("env"))
        self.assertEqual(run_call_kwargs[1].get("env", {}).get("UV_NO_CACHE"), "1")

    def test_rc2_malformed_header_retry_also_fails_restores_original(self):
        original = '# /// script\n# broken (((\n# ///\nimport requests\nprint("hi")\n'
        self.entry.write_text(original, encoding="utf-8")

        def fake_run(cmd, **kwargs):
            if "check" in cmd or "add" in cmd:
                return _run_result(cmd, returncode=0)
            return Mock(returncode=2)

        with patch("tools.pvw_known_idempotent.subprocess.run", side_effect=fake_run):
            with patch("builtins.print") as mock_print:
                rc = main([str(self.entry), "uvx", "uv", "python"])
        self.assertEqual(rc, 2)
        mock_print.assert_called_once_with("ERROR:strip_retry_failed:2", file=sys.stderr)
        # Original (still-malformed) content restored, not left stripped.
        self.assertEqual(self.entry.read_text(encoding="utf-8"), original)

    def test_other_nonzero_fillin_succeeds(self):
        calls = {"run_count": 0}
        run_call_kwargs = []

        def fake_run(cmd, **kwargs):
            if "check" in cmd or "add" in cmd:
                return _run_result(cmd, returncode=0)
            calls["run_count"] += 1
            run_call_kwargs.append(kwargs)
            return Mock(returncode=1 if calls["run_count"] == 1 else 0)

        with patch("tools.pvw_known_idempotent.subprocess.run", side_effect=fake_run):
            with patch("builtins.print") as mock_print:
                rc = main([str(self.entry), "uvx", "uv", "python"])
        self.assertEqual(rc, 0)
        mock_print.assert_called_once_with("RAN:persisted_after_fillin", file=sys.stderr)
        self.assertIsNone(run_call_kwargs[0].get("env"))
        self.assertEqual(run_call_kwargs[1].get("env", {}).get("UV_NO_CACHE"), "1")

    def test_rc2_non_utf8_entry_skips_strip_and_leaves_file_untouched(self):
        # Encoding pre-check mirrors tools/pep723_writeback.py: a non-UTF-8 entry file
        # must never be read with errors="ignore" and rewritten -- that would silently
        # drop undecodable bytes, corrupting the file even on the "restore" path.
        raw = b"# /// script\n# broken (((\n# ///\nimport requests\n# non-utf8: \xff\xfe\n"
        self.entry.write_bytes(raw)

        def fake_run(cmd, **kwargs):
            if "check" in cmd or "add" in cmd:
                return _run_result(cmd, returncode=0)
            return Mock(returncode=2)

        with patch("tools.pvw_known_idempotent.subprocess.run", side_effect=fake_run):
            with patch("builtins.print") as mock_print:
                rc = main([str(self.entry), "uvx", "uv", "python"])
        self.assertEqual(rc, 2)
        mock_print.assert_called_once_with("ERROR:strip_retry_skipped:non_utf8", file=sys.stderr)
        # File must be byte-for-byte untouched -- no read-with-ignore, no rewrite at all.
        self.assertEqual(self.entry.read_bytes(), raw)

    def test_other_nonzero_fillin_also_fails(self):
        def fake_run(cmd, **kwargs):
            if "check" in cmd or "add" in cmd:
                return _run_result(cmd, returncode=0)
            return Mock(returncode=1)

        with patch("tools.pvw_known_idempotent.subprocess.run", side_effect=fake_run):
            with patch("builtins.print") as mock_print:
                rc = main([str(self.entry), "uvx", "uv", "python"])
        self.assertEqual(rc, 1)
        mock_print.assert_called_once_with("ERROR:run_failed_not_dependency_gap:1", file=sys.stderr)

    def test_bad_args_returns_1(self):
        with patch("builtins.print") as mock_print:
            rc = main(["only_one_arg"])
        self.assertEqual(rc, 1)
        mock_print.assert_called_once_with("ERROR:bad_args", file=sys.stderr)


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_PVW_IDEMPOTENT=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_PVW_IDEMPOTENT payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_PVW_IDEMPOTENT base64 is out of sync with "
            "tools/pvw_known_idempotent.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
