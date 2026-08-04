"""Tests for tools/dll_bundle_scan.py -- the CLAUDE.md Active Backlog Item 24
conda native-DLL bundling repair loop's build-time detection (see
docs/prd-conda-native-dll-bundling.md).

Covers the warning-text parse, the tried-list guard, the Library\\bin
double-gate (a named DLL must actually exist on disk to be emitted), the
byte-offset log-tail read, and the base64 payload sync.
"""
import base64
import re
import tempfile
import unittest
from pathlib import Path

from tools.dll_bundle_scan import next_dll_target, locate_dll, read_tail, main

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "dll_bundle_scan.py"


def _warn(dll, dep_of="...\\pygrib\\_pygrib.cp314-win_amd64.pyd"):
    """A realistic PyInstaller build-log unresolved-native-DLL warning."""
    return "WARNING: Library not found: could not resolve '{0}', dependency of '{1}'.\n".format(dll, dep_of)


class WarningParse(unittest.TestCase):
    def test_single_warning_returns_dll_name(self):
        self.assertEqual(next_dll_target(_warn("eccodes.dll")), "eccodes.dll")

    def test_no_warning_returns_nothing(self):
        self.assertEqual(next_dll_target("PyInstaller build completed successfully.\n"), "")

    def test_empty_returns_nothing(self):
        self.assertEqual(next_dll_target(""), "")

    def test_first_untried_wins(self):
        text = _warn("aaa.dll") + _warn("bbb.dll")
        self.assertEqual(next_dll_target(text), "aaa.dll")

    def test_already_tried_skipped(self):
        # Prevents the loop from re-suggesting the same DLL forever.
        self.assertEqual(next_dll_target(_warn("eccodes.dll"), already_tried=["eccodes.dll"]), "")

    def test_already_tried_case_insensitive(self):
        self.assertEqual(next_dll_target(_warn("Eccodes.DLL"), already_tried=["eccodes.dll"]), "")

    def test_second_after_first_tried(self):
        text = _warn("aaa.dll") + _warn("bbb.dll")
        self.assertEqual(next_dll_target(text, already_tried=["aaa.dll"]), "bbb.dll")

    def test_lib_not_found_generic_text_not_matched(self):
        # A different, unrelated warning phrase must not false-positive.
        text = "WARNING: lib not found: somelib.so dependency of foo.so\n"
        self.assertEqual(next_dll_target(text), "")


class LocateDll(unittest.TestCase):
    def test_finds_dll_directly_in_library_bin(self):
        with tempfile.TemporaryDirectory() as tmp:
            lib_bin = Path(tmp) / "Library" / "bin"
            lib_bin.mkdir(parents=True)
            target = lib_bin / "eccodes.dll"
            target.write_bytes(b"stub")
            self.assertEqual(locate_dll("eccodes.dll", tmp), str(target))

    def test_finds_dll_nested_in_package_subfolder(self):
        # hook-gribapi.py's own Windows-aware placement nests under a
        # package-named subfolder of Library\bin rather than directly in it.
        with tempfile.TemporaryDirectory() as tmp:
            nested = Path(tmp) / "Library" / "bin" / "eccodes"
            nested.mkdir(parents=True)
            target = nested / "eccodes.dll"
            target.write_bytes(b"stub")
            self.assertEqual(locate_dll("eccodes.dll", tmp), str(target))

    def test_case_insensitive_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            lib_bin = Path(tmp) / "Library" / "bin"
            lib_bin.mkdir(parents=True)
            target = lib_bin / "ECCODES.DLL"
            target.write_bytes(b"stub")
            self.assertEqual(locate_dll("eccodes.dll", tmp), str(target))

    def test_missing_library_bin_returns_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(locate_dll("eccodes.dll", tmp), "")

    def test_dll_not_present_returns_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            lib_bin = Path(tmp) / "Library" / "bin"
            lib_bin.mkdir(parents=True)
            (lib_bin / "other.dll").write_bytes(b"stub")
            self.assertEqual(locate_dll("eccodes.dll", tmp), "")

    def test_empty_conda_dir_returns_empty(self):
        self.assertEqual(locate_dll("eccodes.dll", ""), "")


class ReadTail(unittest.TestCase):
    def test_reads_from_offset(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "log.txt"
            prefix = "stale content from an earlier run\n"
            suffix = _warn("eccodes.dll")
            p.write_text(prefix + suffix, encoding="utf-8")
            offset = len(prefix.encode("utf-8"))
            self.assertEqual(read_tail(str(p), offset), suffix)

    def test_offset_excludes_stale_warning(self):
        # A DLL warning entirely before the offset must not be detected --
        # this is what prevents re-flagging a stale warning from an earlier
        # run in the same persistent log file.
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "log.txt"
            prefix = _warn("stale.dll")
            suffix = "build succeeded, no new warnings\n"
            p.write_text(prefix + suffix, encoding="utf-8")
            offset = len(prefix.encode("utf-8"))
            self.assertEqual(next_dll_target(read_tail(str(p), offset)), "")

    def test_missing_file_returns_empty(self):
        self.assertEqual(read_tail("/no/such/file/xyz.txt", 0), "")

    def test_negative_offset_clamped_to_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "log.txt"
            text = _warn("eccodes.dll")
            p.write_text(text, encoding="utf-8")
            self.assertEqual(read_tail(str(p), -5), text)


class MainCli(unittest.TestCase):
    def test_main_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "log.txt"
            log.write_text(_warn("eccodes.dll"), encoding="utf-8")
            lib_bin = Path(tmp) / "Library" / "bin"
            lib_bin.mkdir(parents=True)
            target = lib_bin / "eccodes.dll"
            target.write_bytes(b"stub")
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                main([str(log), "0", tmp])
            self.assertEqual(buf.getvalue(), "eccodes.dll|" + str(target))

    def test_main_dll_not_on_disk_emits_nothing(self):
        # Double-gate: named in the warning but not found under Library\bin.
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "log.txt"
            log.write_text(_warn("eccodes.dll"), encoding="utf-8")
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                main([str(log), "0", tmp])
            self.assertEqual(buf.getvalue(), "")

    def test_main_too_few_args_silent(self):
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            main(["only_one_arg"])
        self.assertEqual(buf.getvalue(), "")

    def test_main_missing_log_file_silent(self):
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            main(["/no/such/file/xyz.txt", "0", "/no/such/conda/env"])
        self.assertEqual(buf.getvalue(), "")

    def test_main_bad_offset_defaults_to_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "log.txt"
            log.write_text(_warn("eccodes.dll"), encoding="utf-8")
            lib_bin = Path(tmp) / "Library" / "bin"
            lib_bin.mkdir(parents=True)
            (lib_bin / "eccodes.dll").write_bytes(b"stub")
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                main([str(log), "not_a_number", tmp])
            self.assertTrue(buf.getvalue().startswith("eccodes.dll|"))


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_DLL_BUNDLE_SCAN=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_DLL_BUNDLE_SCAN payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_DLL_BUNDLE_SCAN base64 is out of sync with tools/dll_bundle_scan.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
