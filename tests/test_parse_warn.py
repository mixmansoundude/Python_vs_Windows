"""Tests for tools/parse_warn.py -- translation table coverage.

Each TRANSLATIONS entry has at least one assertion; removing any entry causes a
test failure.  Both PyInstaller 5.x (W: no module named 'foo') and 6.x
(missing module named foo - imported by bar (top-level|delayed|conditional)) formats are covered.
"""
import os
import tempfile
import unittest
from pathlib import Path

from tools.parse_warn import parse_warn_file, TRANSLATIONS, SKIP


def _warn5(mod):
    """Return a PyInstaller 5.x warn line for mod."""
    return "W: no module named '{}'".format(mod)


def _warn6(mod, importer="app"):
    """Return a PyInstaller 6.x warn line (top-level) for mod."""
    return "missing module named {} - imported by {} (top-level)".format(mod, importer)


def _parse_lines(lines):
    """Write lines to a temp warn file and return parse_warn_file() output."""
    with tempfile.TemporaryDirectory() as tmp:
        warn_path = Path(tmp) / "warn-env.txt"
        warn_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return parse_warn_file(str(warn_path))


def _resolve(import_name, fmt="5"):
    """Return conda packages produced for a single import name."""
    if fmt == "5":
        line = _warn5(import_name)
    else:
        line = _warn6(import_name)
    return _parse_lines([line])


class TranslationTableTest(unittest.TestCase):
    """One test method per TRANSLATIONS key; removing any key breaks a test."""

    def _assert_maps(self, import_name, expected_pkg):
        """Assert import_name -> expected_pkg in both PyInstaller 5.x and 6.x formats."""
        for fmt in ("5", "6"):
            result = _resolve(import_name, fmt=fmt)
            self.assertEqual(
                result,
                [expected_pkg],
                "fmt={} import={!r}: expected [{!r}], got {!r}".format(
                    fmt, import_name, expected_pkg, result
                ),
            )

    def test_cv2_maps_to_opencv(self):
        self._assert_maps("cv2", "opencv")

    def test_PIL_maps_to_pillow(self):
        self._assert_maps("PIL", "pillow")

    def test_Image_maps_to_pillow(self):
        self._assert_maps("Image", "pillow")

    def test_sklearn_maps_to_scikit_learn(self):
        self._assert_maps("sklearn", "scikit-learn")

    def test_bs4_maps_to_beautifulsoup4(self):
        self._assert_maps("bs4", "beautifulsoup4")

    def test_serial_maps_to_pyserial(self):
        self._assert_maps("serial", "pyserial")

    def test_yaml_maps_to_pyyaml(self):
        self._assert_maps("yaml", "pyyaml")

    def test_git_maps_to_gitpython(self):
        self._assert_maps("git", "gitpython")

    def test_wx_maps_to_wxpython(self):
        self._assert_maps("wx", "wxpython")

    def test_dateutil_maps_to_python_dateutil(self):
        self._assert_maps("dateutil", "python-dateutil")

    def test_dotenv_maps_to_python_dotenv(self):
        self._assert_maps("dotenv", "python-dotenv")

    def test_Crypto_maps_to_pycryptodome(self):
        self._assert_maps("Crypto", "pycryptodome")

    def test_OpenSSL_maps_to_pyopenssl(self):
        self._assert_maps("OpenSSL", "pyopenssl")

    def test_jwt_maps_to_pyjwt(self):
        self._assert_maps("jwt", "pyjwt")

    def test_usb_maps_to_pyusb(self):
        self._assert_maps("usb", "pyusb")

    def test_attr_maps_to_attrs(self):
        self._assert_maps("attr", "attrs")

    def test_win32api_maps_to_pywin32(self):
        self._assert_maps("win32api", "pywin32")

    def test_win32con_maps_to_pywin32(self):
        self._assert_maps("win32con", "pywin32")

    def test_fitz_maps_to_pymupdf(self):
        self._assert_maps("fitz", "pymupdf")

    def test_docx_maps_to_python_docx(self):
        self._assert_maps("docx", "python-docx")


# Explicit set of all TRANSLATIONS keys tested above.
# If a new key is added to TRANSLATIONS without adding a test here, the
# completeness test below fails, enforcing full table coverage.
_TESTED_KEYS = frozenset({
    "cv2", "PIL", "Image", "sklearn", "bs4", "serial", "yaml", "git",
    "wx", "dateutil", "dotenv", "Crypto", "OpenSSL", "jwt", "usb",
    "attr", "win32api", "win32con", "fitz", "docx",
})


class TranslationTableCompletenessTest(unittest.TestCase):
    """Fail when TRANSLATIONS gains a key not covered by TranslationTableTest."""

    def test_no_untested_translation_keys(self):
        untested = set(TRANSLATIONS) - _TESTED_KEYS
        self.assertEqual(
            untested,
            set(),
            "New TRANSLATIONS entries need test coverage: {}".format(sorted(untested)),
        )


class ParseWarnFileEdgeCasesTest(unittest.TestCase):

    def test_missing_file_returns_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = parse_warn_file(os.path.join(tmp, "nonexistent.txt"))
        self.assertEqual(result, [])

    def test_internal_modules_skipped(self):
        result = _parse_lines(["W: no module named '_internal'"])
        self.assertEqual(result, [])

    def test_skip_set_entries_ignored(self):
        result = _parse_lines([
            "W: no module named 'pkg_resources'",
            "W: no module named 'grp'",
            "W: no module named 'distutils'",
        ])
        self.assertEqual(result, [])

    def test_pyi6_optional_only_skipped(self):
        # derived requirement: (optional)-only means a try-except guard; the module
        # is intentionally resilient to absence so we do not try to install it.
        result = _parse_lines([
            "missing module named openpyxl - imported by app (optional)"
        ])
        self.assertEqual(result, [])

    def test_pyi6_optional_with_qualifier_in_modname_skipped(self):
        # derived requirement: qualifier check must match the trailing parentheses, not
        # anywhere in the line. A module whose name contains "delayed" but is only
        # (optional) must still be skipped.
        result = _parse_lines([
            "missing module named delayed_tasks - imported by app (optional)"
        ])
        self.assertEqual(result, [])

    def test_pyi6_skip_set_filtered_even_when_delayed(self):
        # Unix-only stdlib shims land as (delayed) or (conditional) but are in SKIP.
        result = _parse_lines([
            "missing module named posix - imported by app (conditional)"
        ])
        self.assertEqual(result, [])

    def test_pyi6_delayed_processed(self):
        # derived requirement: function-scoped imports appear as (delayed) in the
        # PyInstaller 6.x warn file. warnfix must install them.
        result = _parse_lines([
            "missing module named xlrd - imported by app (delayed)"
        ])
        self.assertEqual(result, ["xlrd"])

    def test_pyi6_conditional_processed(self):
        # derived requirement: platform-conditional imports (e.g. if sys.platform == ...)
        # appear as (conditional); they are required at runtime so warnfix installs them.
        result = _parse_lines([
            "missing module named cv2 - imported by app (conditional)"
        ])
        self.assertEqual(result, ["opencv"])

    def test_pyi6_toplevel_processed(self):
        result = _parse_lines([
            "missing module named cv2 - imported by app (top-level)"
        ])
        self.assertEqual(result, ["opencv"])

    def test_pyi6_quoted_module_name_strips_quotes(self):
        # PyInstaller 6.x may quote the module name; quotes must not appear in output
        result = _parse_lines([
            "missing module named 'collections' - imported by app (top-level)"
        ])
        self.assertEqual(result, ["collections"])

    def test_submodule_resolves_to_root(self):
        # PIL.Image.open -> root PIL -> pillow
        result = _parse_lines(["W: no module named 'PIL.Image'"])
        self.assertEqual(result, ["pillow"])

    def test_unknown_module_passthrough(self):
        result = _parse_lines(["W: no module named 'someunknownpkg'"])
        self.assertEqual(result, ["someunknownpkg"])

    def test_deduplication_PIL_and_Image_both_yield_pillow_once(self):
        # Both PIL and Image map to pillow; only one entry expected
        result = _parse_lines([
            "W: no module named 'PIL'",
            "W: no module named 'Image'",
        ])
        self.assertEqual(result, ["pillow"])

    def test_deduplication_win32api_and_win32con_both_yield_pywin32_once(self):
        result = _parse_lines([
            "W: no module named 'win32api'",
            "W: no module named 'win32con'",
        ])
        self.assertEqual(result, ["pywin32"])

    def test_empty_file_returns_empty(self):
        result = _parse_lines([])
        self.assertEqual(result, [])

    def test_blank_lines_ignored(self):
        result = _parse_lines(["", "   ", "W: no module named 'cv2'", ""])
        self.assertEqual(result, ["opencv"])

    def test_importlib_abc_is_skipped(self):
        # derived requirement: importlib.abc is in SKIP (was a typo 'importlia.abc' in earlier versions)
        self.assertIn("importlib.abc", SKIP)
        result = _parse_lines(["W: no module named 'importlib.abc'"])
        self.assertEqual(result, [])


if __name__ == "__main__":
    unittest.main()
