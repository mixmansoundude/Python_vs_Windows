"""Tests for tools/parse_warn.py -- translation table coverage.

Each TRANSLATIONS entry has at least one assertion; removing any entry causes a
test failure.  Both PyInstaller 5.x (W: no module named 'foo') and 6.x
(missing module named foo - imported by bar (top-level|delayed|conditional)) formats are covered.

Also guards that the base64 HP_PARSE_WARN payload embedded in run_setup.bat
matches this source (mirrors FindEntryPayloadSync in test_find_entry.py).
"""
import base64
import importlib.util
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.parse_warn import parse_warn_file, TRANSLATIONS, SKIP

REPO = Path(__file__).resolve().parent.parent
PARSE_WARN = REPO / "tools" / "parse_warn.py"


def _warn5(mod):
    """Return a PyInstaller 5.x warn line for mod."""
    return "W: no module named '{}'".format(mod)


def _warn6(mod, importer="app"):
    """Return a PyInstaller 6.x warn line (top-level) for mod."""
    return "missing module named {} - imported by {} (top-level)".format(mod, importer)


class _FakeSpec(object):
    """Stand-in for an importlib ModuleSpec (only truthiness and origin are read)."""
    origin = "site-packages"


def _parse_lines(lines, installed=()):
    """Write lines to a temp warn file and return parse_warn_file() output.

    The result must not depend on what happens to be installed where the tests run, so by
    default importlib.util.find_spec reports every name as not installed; pass `installed`
    (an iterable of top-level names) to make some resolve, or None to use the real find_spec.
    """
    with tempfile.TemporaryDirectory() as tmp:
        warn_path = Path(tmp) / "warn-env.txt"
        warn_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        if installed is None:
            return parse_warn_file(str(warn_path))
        have = set(installed)
        with mock.patch.object(
            importlib.util, "find_spec",
            side_effect=lambda name, *a, **k: _FakeSpec() if name in have else None,
        ):
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

    def test_win32com_maps_to_pywin32(self):
        self._assert_maps("win32com", "pywin32")

    def test_win32gui_maps_to_pywin32(self):
        self._assert_maps("win32gui", "pywin32")

    def test_win32file_maps_to_pywin32(self):
        self._assert_maps("win32file", "pywin32")

    def test_win32process_maps_to_pywin32(self):
        self._assert_maps("win32process", "pywin32")

    def test_win32event_maps_to_pywin32(self):
        self._assert_maps("win32event", "pywin32")

    def test_pywintypes_maps_to_pywin32(self):
        self._assert_maps("pywintypes", "pywin32")

    def test_pythoncom_maps_to_pywin32(self):
        self._assert_maps("pythoncom", "pywin32")

    def test_winerror_maps_to_pywin32(self):
        self._assert_maps("winerror", "pywin32")

    def test_fitz_maps_to_pymupdf(self):
        self._assert_maps("fitz", "pymupdf")

    def test_docx_maps_to_python_docx(self):
        self._assert_maps("docx", "python-docx")

    def test_pptx_maps_to_python_pptx(self):
        self._assert_maps("pptx", "python-pptx")

    def test_pydantic_core_maps_to_pydantic_core_conda_name(self):
        self._assert_maps("pydantic_core", "pydantic-core")

    def test_skimage_maps_to_scikit_image(self):
        self._assert_maps("skimage", "scikit-image")

    def test_Cryptodome_maps_to_pycryptodome(self):
        self._assert_maps("Cryptodome", "pycryptodome")

    def test_zmq_maps_to_pyzmq(self):
        self._assert_maps("zmq", "pyzmq")


# Item 64: pywin32 ships dozens of top-level modules; the field report's win32pdh was missing from
# TRANSLATIONS, so warnfix tried to install a package literally named "win32pdh". All of these are
# modules of the one conda/PyPI package pywin32.
_PYWIN32_MODULES = (
    "win32pdh", "win32pdhutil", "win32pipe", "win32service", "win32serviceutil", "servicemanager",
    "win32clipboard", "win32print", "win32security", "win32net", "win32netcon", "win32ui",
    "win32uiole", "win32timezone", "win32crypt", "win32evtlog", "win32evtlogutil", "win32job",
    "win32profile", "win32ts", "win32wnet", "win32console", "win32cred", "win32inet",
    "win32gui_struct", "winxpgui", "ntsecuritycon",
)


class Pywin32ModulesTest(unittest.TestCase):
    """Every pywin32 module name maps to pywin32 (loop, so the list above is the one registry)."""

    def test_every_pywin32_module_maps_to_pywin32(self):
        for name in _PYWIN32_MODULES:
            for fmt in ("5", "6"):
                self.assertEqual(
                    _resolve(name, fmt=fmt), ["pywin32"],
                    "fmt={} import={!r} must map to pywin32".format(fmt, name))


# Explicit set of all TRANSLATIONS keys tested above.
# If a new key is added to TRANSLATIONS without adding a test here, the
# completeness test below fails, enforcing full table coverage.
_TESTED_KEYS = frozenset({
    "cv2", "PIL", "Image", "sklearn", "bs4", "serial", "yaml", "git",
    "wx", "dateutil", "dotenv", "Crypto", "OpenSSL", "jwt", "usb",
    "attr", "win32api", "win32con", "win32com", "win32gui", "win32file",
    "win32process", "win32event", "pywintypes", "pythoncom", "winerror",
    "fitz", "docx", "pptx", "pydantic_core", "skimage", "Cryptodome", "zmq",
}) | frozenset(_PYWIN32_MODULES)


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

    def test_cstringio_skipped_real_xlrd_warn_line(self):
        # derived requirement: real, unflagged warn-file line captured verbatim from
        # self.layered_e2e.chain's own CI run -- xlrd's own Python 2/3 compatibility shim
        # (xlrd/timemachine.py) does a conditional "from cStringIO import StringIO", a dead
        # code path under Python 3 but still flagged by PyInstaller's own static analysis.
        # cStringIO can never be a real installable package (removed entirely in Python 3),
        # so warnfix must never attempt to install it -- confirmed this was previously
        # causing a genuine, unnecessary extra provider cascade in real CI.
        result = _parse_lines([
            "missing module named cStringIO - imported by xlrd.timemachine (conditional)"
        ])
        self.assertEqual(result, [])

    def test_stringio_skipped(self):
        # Bare StringIO (as opposed to cStringIO) is the same Python-2-only stdlib module
        # class -- also never a real installable package.
        result = _parse_lines([
            "missing module named StringIO - imported by app (conditional)"
        ])
        self.assertEqual(result, [])

    def test_every_skip_entry_filtered_in_realistic_warn_line(self):
        # derived requirement: prior to this test, only 2 of SKIP's ~14 non-collections/
        # importlib entries (grp, posix) had any dedicated test exercising them through
        # parse_warn_file -- the rest (pwd, fcntl, resource, readline, termios, tty, pty,
        # crypt, spwd, nis, syslog, ossaudiodev) were only asserted present in the SKIP
        # frozenset itself, never proven to actually filter when they appear in a real
        # PyInstaller 6.x warn line. This test iterates the CURRENT SKIP set (any future
        # addition is covered automatically, no separate registry to keep in sync) and
        # proves each one is filtered in both the (conditional) and (delayed) forms real
        # warn files actually use for these stdlib shims.
        for mod in sorted(SKIP):
            for qualifier in ("conditional", "delayed", "top-level"):
                line = f"missing module named {mod} - imported by app ({qualifier})"
                result = _parse_lines([line])
                self.assertEqual(
                    result, [],
                    f"SKIP entry {mod!r} was not filtered for qualifier {qualifier!r}: line={line!r}",
                )

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

    def test_pyi6_combined_qualifiers_processed(self):
        # derived requirement: PyInstaller 6.x can emit combined qualifiers like
        # (delayed, conditional) for function-scoped conditional imports.
        # Any entry containing top-level, delayed, or conditional must be processed.
        result = _parse_lines([
            "missing module named xlrd - imported by app (delayed, conditional)"
        ])
        self.assertEqual(result, ["xlrd"])

    def test_pyi6_combined_qualifiers_with_optional_processed(self):
        # derived requirement: (delayed, optional) contains a required qualifier (delayed);
        # the entry must be processed, not skipped.
        result = _parse_lines([
            "missing module named xlrd - imported by app (delayed, optional)"
        ])
        self.assertEqual(result, ["xlrd"])

    def test_pyi6_quoted_module_name_strips_quotes(self):
        # PyInstaller 6.x may quote the module name; quotes must not appear in output
        result = _parse_lines([
            "missing module named 'requests' - imported by app (top-level)"
        ])
        self.assertEqual(result, ["requests"])

    def test_stdlib_collections_skipped(self):
        # collections.abc surfaces as "missing module named collections.abc"; the root
        # collections is stdlib, never a conda package, so it must be skipped (REQ-007).
        result = _parse_lines([
            "missing module named 'collections.abc' - imported by app (top-level)",
            "missing module named collections - imported by app (top-level)",
        ])
        self.assertEqual(result, [])

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


# Real warn-file lines (PyInstaller 6.22.3, a ten-line app that does `import pkgutil`,
# `import platform` and `from multiprocessing import Pool, freeze_support`), importer lists
# shortened, build-machine paths replaced. Every name below is noise: stdlib, PyInstaller's own
# runtime hook, or another interpreter's module. Nothing here is a package to install.
HELLO_WORLD_WARN_6X = [
    r"missing module named pyimod02_importers - imported by C:\Python\Lib\site-packages\PyInstaller\hooks\rthooks\pyi_rth_pkgutil.py (delayed)",
    "missing module named 'collections.abc' - imported by traceback (top-level), typing (top-level), inspect (top-level)",
    "missing module named _winapi - imported by encodings (delayed, conditional, optional), shutil (conditional), subprocess (conditional)",
    "missing module named msvcrt - imported by subprocess (optional), multiprocessing.spawn (delayed, conditional), getpass (optional)",
    "missing module named _frozen_importlib_external - imported by importlib._bootstrap (delayed), importlib (optional), zipimport (top-level)",
    "excluded module named _frozen_importlib - imported by importlib (optional), importlib.abc (optional), zipimport (top-level)",
    "missing module named winreg - imported by importlib._bootstrap_external (conditional), platform (delayed, optional), mimetypes (optional)",
    "missing module named nt - imported by shutil (conditional), importlib._bootstrap_external (conditional), ntpath (optional)",
    "missing module named _scproxy - imported by urllib.request (conditional)",
    "missing module named multiprocessing.BufferTooShort - imported by multiprocessing (top-level), multiprocessing.connection (top-level)",
    "missing module named multiprocessing.AuthenticationError - imported by multiprocessing (top-level), multiprocessing.connection (top-level)",
    "missing module named multiprocessing.get_context - imported by multiprocessing (top-level), multiprocessing.pool (top-level)",
    "missing module named multiprocessing.TimeoutError - imported by multiprocessing (top-level), multiprocessing.pool (top-level)",
    "missing module named multiprocessing.set_start_method - imported by multiprocessing (top-level), multiprocessing.spawn (top-level)",
    "missing module named multiprocessing.get_start_method - imported by multiprocessing (top-level), multiprocessing.spawn (top-level)",
    r"missing module named multiprocessing.freeze_support - imported by multiprocessing (top-level), C:\app\app.py (top-level)",
    r"missing module named multiprocessing.Pool - imported by multiprocessing (top-level), C:\app\app.py (top-level)",
    "missing module named vms_lib - imported by platform (delayed, optional)",
    "missing module named 'java.lang' - imported by platform (delayed, optional)",
    "missing module named java - imported by platform (delayed)",
    "missing module named _wmi - imported by platform (optional)",
]


class NoiseIsNeverAnInstallTargetTest(unittest.TestCase):
    """Item 64 / README REQ-005.9: names that cannot be installed are filtered before any install."""

    def test_real_hello_world_warn_file_yields_no_install_target(self):
        # The whole file of a program with no third-party imports at all must produce nothing.
        self.assertEqual(_parse_lines(HELLO_WORLD_WARN_6X), [])

    def test_field_report_fixture_pyimod02_importers(self):
        # Field report 2026-10-09: uv said "pyimod02-importers was not found in the package
        # registry". The name is PyInstaller's own runtime module and exists nowhere on PyPI.
        for qualifier in ("delayed", "delayed, optional", "top-level"):
            line = ("missing module named pyimod02_importers - imported by "
                    "pkg_resources._vendor.jaraco (%s)" % qualifier)
            self.assertEqual(_parse_lines([line]), [], line)

    def test_field_report_fixture_multiprocessing(self):
        # Field report 2026-10-09: uv found a PyPI package called multiprocessing (a Python 2
        # backport that cannot build) and failed to build it. A stdlib name must never be tried.
        lines = [
            "missing module named multiprocessing.Pool - imported by app (top-level)",
            "missing module named multiprocessing - imported by app (top-level)",
        ]
        self.assertEqual(_parse_lines(lines), [])

    def test_pyinstaller_internal_modules_are_never_targets(self):
        for name in ("pyimod01_archive", "pyimod02_importers", "pyimod03_ctypes",
                     "pyimod04_pywin32", "pyi_splash"):
            for qualifier in ("top-level", "delayed", "conditional"):
                line = "missing module named %s - imported by app (%s)" % (name, qualifier)
                self.assertEqual(_parse_lines([line]), [], line)

    def test_stdlib_names_are_never_targets(self):
        # Undotted and dotted, quoted and not, every qualifier that counts as required.
        names = ("multiprocessing", "tkinter", "sqlite3", "ctypes", "asyncio", "concurrent",
                 "json", "logging", "unittest", "xml", "email", "http", "urllib", "winreg",
                 "msvcrt", "nt", "turtle", "idlelib", "dbm")
        for name in names:
            for form in (name, name + ".something", "'%s.something'" % name):
                for qualifier in ("top-level", "delayed", "conditional", "delayed, optional"):
                    line = "missing module named %s - imported by somepkg (%s)" % (form, qualifier)
                    self.assertEqual(_parse_lines([line]), [], line)

    def test_stdlib_names_in_the_5x_format_are_never_targets(self):
        lines = ["W: no module named 'multiprocessing.Pool'", "W: no module named 'tkinter'",
                 "W: no module named 'sqlite3'", "W: no module named 'pyimod02_importers'"]
        self.assertEqual(_parse_lines(lines), [])

    def test_removed_and_python2_stdlib_names_are_never_targets(self):
        # Not in sys.stdlib_module_names on a current Python, so they need their own list.
        names = ("imp", "uu", "test", "tkFileDialog", "FileDialog", "tkMessageBox", "Tkinter",
                 "gdbm", "dumbdbm", "anydbm", "cPickle", "ConfigParser", "urllib2", "urlparse",
                 "httplib", "Queue", "SocketServer", "xmlrpclib", "HTMLParser", "cookielib")
        for name in names:
            line = "missing module named %s - imported by somepkg (delayed, conditional)" % name
            self.assertEqual(_parse_lines([line]), [], line)

    def test_other_interpreter_and_other_platform_names_are_never_targets(self):
        # Jython (java, org), OpenVMS (vms_lib), macOS (Foundation, AppKit, objc): optional
        # branches of stdlib and library code that a Windows CPython never takes.
        for name in ("java", "java.lang", "org.python.core", "vms_lib", "Foundation", "AppKit",
                     "objc", "Cocoa", "Quartz", "CoreFoundation"):
            line = "missing module named '%s' - imported by platform (delayed)" % name
            self.assertEqual(_parse_lines([line]), [], line)

    def test_excluded_module_lines_are_never_targets(self):
        # PyInstaller prints "excluded module named X" for modules that were removed on purpose.
        # Both matchers only look for "no module named" / "missing module named", so a future
        # regex change must not start installing these.
        for name in ("_frozen_importlib", "xlrd", "pandas", "tkinter"):
            line = "excluded module named %s - imported by importlib (top-level)" % name
            self.assertEqual(_parse_lines([line]), [], line)

    def test_a_real_dependency_next_to_the_noise_is_still_a_target(self):
        # The filter must not swallow the real thing: xlrd is not stdlib, not internal, not installed.
        lines = HELLO_WORLD_WARN_6X + [
            r"missing module named xlrd - imported by C:\app\app.py (delayed)",
            "missing module named 'PIL.Image' - imported by app (top-level)",
        ]
        self.assertEqual(_parse_lines(lines), ["xlrd", "pillow"])

    def test_future_stays_a_target(self):
        # `future` is a real PyPI package that the field-report run needed; it must not be
        # mistaken for a Python 2 stdlib name.
        self.assertEqual(
            _parse_lines(["missing module named future - imported by app (top-level)"]),
            ["future"])


class StdlibListFallbackTest(unittest.TestCase):
    """Python before 3.10 has no sys.stdlib_module_names; the filter must still work there."""

    def _without_stdlib_list(self, lines, installed=None):
        with mock.patch.object(sys, "stdlib_module_names", None, create=True):
            return _parse_lines(lines, installed=installed)

    def test_stdlib_package_found_by_the_interpreter_is_filtered(self):
        lines = ["missing module named multiprocessing.Pool - imported by app (top-level)",
                 "missing module named sqlite3 - imported by app (top-level)",
                 "missing module named json - imported by app (top-level)"]
        self.assertEqual(self._without_stdlib_list(lines), [])

    def test_unknown_name_is_still_a_target(self):
        lines = ["missing module named definitely_not_installed_xyz - imported by app (delayed)"]
        self.assertEqual(self._without_stdlib_list(lines),
                         ["definitely_not_installed_xyz"])

    def test_package_in_site_packages_is_not_taken_for_stdlib(self):
        with tempfile.TemporaryDirectory() as tmp:
            pkg = Path(tmp) / "site-packages" / "fakethirdparty_xyz"
            pkg.mkdir(parents=True)
            (pkg / "__init__.py").write_text("", encoding="utf-8")
            with mock.patch.object(sys, "path", [str(pkg.parent)] + sys.path):
                result = self._without_stdlib_list(
                    ["missing module named fakethirdparty_xyz - imported by app (delayed)"])
        self.assertEqual(result, ["fakethirdparty_xyz"])


class InstalledTopLevelTest(unittest.TestCase):
    """`X.attr` is a missing attribute or submodule of X; installing X cannot supply it."""

    def test_dotted_name_of_an_installed_package_is_skipped(self):
        # Real line from a plotly build: plotly is installed, plotly.colors.sequential is the
        # missing "module" (really an attribute set up at import time).
        line = ("missing module named plotly.colors.sequential - imported by plotly.colors "
                "(top-level), plotly.express._core (top-level)")
        self.assertEqual(_parse_lines([line], installed=("plotly",)), [])

    def test_quoted_dotted_name_of_an_installed_package_is_skipped(self):
        line = "missing module named 'pandas.core' - imported by app (conditional)"
        self.assertEqual(_parse_lines([line], installed=("pandas",)), [])

    def test_dotted_name_of_a_missing_package_is_still_a_target(self):
        line = "missing module named 'pyarrow.compute' - imported by app (top-level)"
        self.assertEqual(_parse_lines([line], installed=()), ["pyarrow"])

    def test_dotted_name_uses_the_translated_package_only_when_not_installed(self):
        line = "missing module named PIL.Image - imported by app (top-level)"
        self.assertEqual(_parse_lines([line], installed=()), ["pillow"])
        self.assertEqual(_parse_lines([line], installed=("PIL",)), [])

    def test_undotted_name_is_a_target_even_if_it_resolves(self):
        # Unchanged on purpose: a bare name PyInstaller calls missing is still handed to warnfix,
        # so the cascade signal for a module the provider cannot supply is not weakened.
        line = "missing module named xlrd - imported by app (delayed)"
        self.assertEqual(_parse_lines([line], installed=("xlrd",)), ["xlrd"])

    def test_a_failing_lookup_counts_as_not_installed(self):
        line = "missing module named 'weird.sub' - imported by app (top-level)"
        for exc in (ValueError("x"), ImportError("x"), ModuleNotFoundError("x"), AttributeError("x")):
            with tempfile.TemporaryDirectory() as tmp:
                warn_path = Path(tmp) / "warn-env.txt"
                warn_path.write_text(line + "\n", encoding="utf-8")
                with mock.patch.object(importlib.util, "find_spec", side_effect=exc):
                    self.assertEqual(parse_warn_file(str(warn_path)), ["weird"], repr(exc))

    def test_the_lookup_never_imports_anything(self):
        # find_spec on a top-level name must not run the package's code.
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "imported.txt"
            pkg = Path(tmp) / "boom_pkg_xyz"
            pkg.mkdir()
            (pkg / "__init__.py").write_text(
                "open(%r, 'w').write('x')\n" % str(marker), encoding="utf-8")
            with mock.patch.object(sys, "path", [tmp] + sys.path):
                _parse_lines(["missing module named boom_pkg_xyz.sub - imported by app (delayed)"],
                             installed=None)
            self.assertFalse(marker.exists())
            sys.modules.pop("boom_pkg_xyz", None)


class ParseWarnPayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_PARSE_WARN=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_PARSE_WARN payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = PARSE_WARN.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_PARSE_WARN base64 is out of sync with tools/parse_warn.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
