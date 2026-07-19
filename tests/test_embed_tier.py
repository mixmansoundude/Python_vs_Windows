"""Tests for the REQ-009 Tier 5 (standalone embeddable-Python fallback) helpers:
tools/embed_pyver_check.py's version-table resolution logic, and byte-equality of both
tools/embed_extract.ps1 and tools/embed_pyver_check.py against their embedded HP_EMBED_EXTRACT /
HP_EMBED_PYVER_CHECK base64 payloads in run_setup.bat (mirrors PayloadSync in
test_collect_submodules.py / test_hidden_import_scan.py). Also asserts the batch-side
HP_EMBED_LATEST_PATCH/HP_EMBED_LATEST_SHA256 constants agree with the Python table's "3.14"
entry -- a refresh that updates one but not the other must be caught here, not discovered live.
"""
import base64
import io
import os
import re
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from tools.embed_pyver_check import (
    EMBED_PYTHON_TABLE,
    FLOOR_MINOR,
    LATEST_MINOR,
    main,
    resolve_requested_minor,
    resolve_table_entry,
)

REPO = Path(__file__).resolve().parent.parent
BAT = REPO / "run_setup.bat"
PS_SOURCE = REPO / "tools" / "embed_extract.ps1"
PY_SOURCE = REPO / "tools" / "embed_pyver_check.py"


class ResolveRequestedMinor(unittest.TestCase):
    def test_empty_pyspec_returns_none(self):
        self.assertIsNone(resolve_requested_minor(""))
        self.assertIsNone(resolve_requested_minor(None))

    def test_extracts_minor_from_various_pyspec_shapes(self):
        self.assertEqual(resolve_requested_minor("python>=3.10,<4.0"), "3.10")
        self.assertEqual(resolve_requested_minor("python=3.11"), "3.11")
        self.assertEqual(resolve_requested_minor("python==3.12"), "3.12")
        self.assertEqual(resolve_requested_minor("python<3.13"), "3.13")

    def test_unparseable_pyspec_returns_none(self):
        self.assertIsNone(resolve_requested_minor("not-a-version-spec"))


class ResolveTableEntry(unittest.TestCase):
    def test_exact_match_no_fallback(self):
        minor, patch, sha256, fell_back = resolve_table_entry("3.11")
        self.assertEqual(minor, "3.11")
        self.assertEqual(patch, EMBED_PYTHON_TABLE["3.11"][0])
        self.assertEqual(sha256, EMBED_PYTHON_TABLE["3.11"][1])
        self.assertFalse(fell_back)

    def test_below_floor_falls_back_to_floor(self):
        minor, patch, sha256, fell_back = resolve_table_entry("3.6")
        self.assertEqual(minor, FLOOR_MINOR)
        self.assertTrue(fell_back)

    def test_above_ceiling_falls_back_to_latest(self):
        minor, patch, sha256, fell_back = resolve_table_entry("3.99")
        self.assertEqual(minor, LATEST_MINOR)
        self.assertTrue(fell_back)

    def test_table_scope_is_non_eol_minors_only(self):
        # Not a moving-target assertion against python.org -- just guards against the table
        # silently growing back toward ancient/EOL versions, or losing its floor/ceiling entries.
        self.assertIn(FLOOR_MINOR, EMBED_PYTHON_TABLE)
        self.assertIn(LATEST_MINOR, EMBED_PYTHON_TABLE)
        self.assertGreaterEqual(len(EMBED_PYTHON_TABLE), 5)


class BatchPythonConsistency(unittest.TestCase):
    def test_batch_latest_constants_match_python_table(self):
        bat = BAT.read_text(encoding="ascii", errors="replace")
        patch_m = re.search(r'set "HP_EMBED_LATEST_PATCH=([0-9.]+)"', bat)
        sha_m = re.search(r'set "HP_EMBED_LATEST_SHA256=([0-9a-f]+)"', bat)
        self.assertIsNotNone(patch_m, "HP_EMBED_LATEST_PATCH not found in run_setup.bat")
        self.assertIsNotNone(sha_m, "HP_EMBED_LATEST_SHA256 not found in run_setup.bat")
        table_patch, table_sha256 = EMBED_PYTHON_TABLE[LATEST_MINOR]
        self.assertEqual(
            patch_m.group(1), table_patch,
            "HP_EMBED_LATEST_PATCH is out of sync with embed_pyver_check.py's LATEST_MINOR entry.",
        )
        self.assertEqual(
            sha_m.group(1), table_sha256,
            "HP_EMBED_LATEST_SHA256 is out of sync with embed_pyver_check.py's LATEST_MINOR entry.",
        )


class MainDispatch(unittest.TestCase):
    # Exercises main()'s two early-return branches directly (no network I/O -- both return
    # before download_and_verify/extract_and_patch are ever called). The actual swap path
    # (exact in-table match or below-floor fallback) is untouched by this fix and already has
    # real end-to-end CI coverage via self.embed.fallback.real (selfapps_ux_hardening.ps1), so
    # it is not re-tested here with mocked network calls.
    def _run_main(self, argv, env):
        buf = io.StringIO()
        with patch.object(sys, "argv", argv), \
             patch.dict(os.environ, env, clear=True), \
             redirect_stdout(buf):
            rc = main()
        return rc, buf.getvalue().strip()

    def test_no_pyspec_is_unchanged(self):
        rc, out = self._run_main(["embed_pyver_check.py", "/dest"], {})
        self.assertEqual(rc, 0)
        self.assertEqual(out, "unchanged|{}".format(LATEST_MINOR))

    def test_exact_latest_request_is_unchanged(self):
        rc, out = self._run_main(
            ["embed_pyver_check.py", "/dest"], {"PYSPEC": "python={}".format(LATEST_MINOR)})
        self.assertEqual(rc, 0)
        self.assertEqual(out, "unchanged|{}".format(LATEST_MINOR))

    def test_above_ceiling_request_is_fellback_not_unchanged(self):
        # derived requirement (the fix): previously this branch emitted "unchanged", making the
        # "fellback" WARN tag unreachable for above-ceiling requests even though a below-floor
        # request already correctly reached it (see ResolveTableEntry.test_above_ceiling_falls_
        # back_to_latest / test_below_floor_falls_back_to_floor for the table-resolution half of
        # this, which was already correct -- only main()'s dispatch was wrong).
        rc, out = self._run_main(
            ["embed_pyver_check.py", "/dest"], {"PYSPEC": "python>=3.99"})
        self.assertEqual(rc, 0)
        self.assertEqual(out, "fellback|{}".format(LATEST_MINOR))


class PayloadSync(unittest.TestCase):
    def test_embed_extract_ps1_matches_source(self):
        # derived requirement: tools/embed_extract.ps1 carries .gitattributes' `*.ps1 text
        # eol=crlf`, so a checkout on Windows CI materializes CRLF line endings regardless of
        # what the payload was encoded from -- normalize both sides before comparing so this
        # test verifies content, not incidental checkout-time line-ending translation (which
        # PowerShell itself does not care about either).
        bat = BAT.read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_EMBED_EXTRACT=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_EMBED_EXTRACT payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).replace(b"\r\n", b"\n")
        source = PS_SOURCE.read_bytes().replace(b"\r\n", b"\n")
        self.assertEqual(
            decoded, source,
            "HP_EMBED_EXTRACT base64 is out of sync with tools/embed_extract.ps1; re-encode it.",
        )

    def test_embed_pyver_check_py_matches_source(self):
        bat = BAT.read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_EMBED_PYVER_CHECK=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_EMBED_PYVER_CHECK payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1))
        source = PY_SOURCE.read_bytes()
        self.assertEqual(
            decoded, source,
            "HP_EMBED_PYVER_CHECK base64 is out of sync with tools/embed_pyver_check.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
