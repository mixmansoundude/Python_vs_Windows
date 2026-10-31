"""Tests for tools/runtime_module_scan.py (HP_RUNTIME_MODULE_SCAN), CLAUDE.md Item 65 slice 1.

The helper reads the stderr a run of the user's program left behind and prints every module it
names as missing that the interpreter does not have, even when the program still exited 0.
Names that must NOT be reported: modules the interpreter has (installed, or a local file next to the
helper), standard library names (a different problem, pip cannot fix it), and anything that is not a
plain identifier (the batch echoes the output unquoted).
"""
import ast
import base64
import contextlib
import importlib
import importlib.util
import io
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "runtime_module_scan.py"

_spec = importlib.util.spec_from_file_location("runtime_module_scan", SOURCE)
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)

GONE = "zz_runtime_scan_gone_pkg"


def _line(name, kind="ModuleNotFoundError"):
    return "%s: No module named '%s'\n" % (kind, name)


class Extraction(unittest.TestCase):
    def test_names_a_missing_module_from_a_traceback(self):
        text = (
            "Traceback (most recent call last):\n"
            '  File "app.py", line 9, in on_click\n'
            + _line(GONE)
        )
        self.assertEqual(scan.missing(text), [GONE])

    def test_a_submodule_is_reported_by_its_top_level_package(self):
        self.assertEqual(scan.missing(_line(GONE + ".styles.fonts")), [GONE])

    def test_repeats_are_reported_once_in_first_seen_order(self):
        text = _line(GONE + "_b") + _line(GONE + "_a") + _line(GONE + "_b")
        self.assertEqual(scan.missing(text), [GONE + "_b", GONE + "_a"])

    def test_plain_importerror_with_the_same_wording_counts(self):
        self.assertEqual(scan.missing(_line(GONE, "ImportError")), [GONE])

    def test_double_quoted_name_counts(self):
        self.assertEqual(scan.missing('ModuleNotFoundError: No module named "%s"\n' % GONE), [GONE])

    def test_output_is_capped(self):
        text = "".join(_line("%s_%d" % (GONE, i)) for i in range(40))
        self.assertEqual(len(scan.missing(text)), 10)

    def test_nothing_to_report_for_unrelated_stderr(self):
        text = "Traceback (most recent call last):\nValueError: bad value\nWARNING: something\n"
        self.assertEqual(scan.missing(text), [])


class WhatIsNotReported(unittest.TestCase):
    def test_a_module_found_on_sys_path_is_not_reported(self):
        d = tempfile.mkdtemp()
        try:
            Path(d, "zz_on_path_mod.py").write_text("X = 1\n", encoding="ascii")
            sys.path.insert(0, d)
            importlib.invalidate_caches()
            self.assertEqual(scan.missing(_line("zz_on_path_mod") + _line(GONE)), [GONE])
        finally:
            sys.path.remove(d)
            importlib.invalidate_caches()
            shutil.rmtree(d, ignore_errors=True)

    def test_a_standard_library_name_is_not_reported(self):
        # tkinter is missing from some interpreters (the embeddable zip); that is a different
        # problem and "add tkinter to requirements.txt" would be wrong advice.
        if not hasattr(sys, "stdlib_module_names"):
            self.skipTest("sys.stdlib_module_names needs Python 3.10+")
        self.assertEqual(scan.missing(_line("tkinter")), [])

    def test_names_that_are_not_plain_identifiers_are_dropped(self):
        for bad in ("a b", ".rel", "x%PATH%", "x&y", "x|y", "x^y", "a-b", "1abc", "x<y>"):
            with self.subTest(bad=bad):
                self.assertEqual(scan.missing(_line(bad)), [])

    def test_a_local_module_next_to_the_helper_is_not_reported(self):
        d = Path(tempfile.mkdtemp())
        try:
            shutil.copy(SOURCE, d / "~runtime_module_scan.py")
            (d / "zz_local_helper_mod.py").write_text("X = 1\n", encoding="ascii")
            (d / "err.txt").write_text(_line("zz_local_helper_mod") + _line(GONE), encoding="ascii")
            r = subprocess.run(
                [sys.executable, "~runtime_module_scan.py", "err.txt"],
                cwd=str(d), capture_output=True, text=True,
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.split(), [GONE])
        finally:
            shutil.rmtree(d, ignore_errors=True)


class CommandLine(unittest.TestCase):
    def _run(self, *args, data=None):
        d = Path(tempfile.mkdtemp())
        try:
            if data is not None:
                (d / "err.txt").write_bytes(data)
            return subprocess.run(
                [sys.executable, str(SOURCE)] + list(args), cwd=str(d), capture_output=True, text=True,
            )
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_prints_one_name_per_line_and_exits_zero(self):
        r = self._run("err.txt", data=(_line(GONE + "_a") + _line(GONE + "_b")).encode("ascii"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split(), [GONE + "_a", GONE + "_b"])

    def test_missing_file_or_no_argument_reports_nothing_and_exits_zero(self):
        for args in (("nope.txt",), ()):
            with self.subTest(args=args):
                r = self._run(*args)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout, "")

    def test_bytes_that_are_not_utf8_do_not_break_it(self):
        r = self._run("err.txt", data=b"\xff\xfe\x80 junk\n" + _line(GONE).encode("ascii"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split(), [GONE])

    def test_internal_error_exits_three_with_a_one_line_reason(self):
        d = Path(tempfile.mkdtemp())
        try:
            (d / "err.txt").write_text(_line(GONE), encoding="ascii")
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(scan, "missing", side_effect=ZeroDivisionError), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = scan.main(["x", str(d / "err.txt")])
            self.assertEqual(rc, 3)
            self.assertEqual(out.getvalue(), "")
            self.assertEqual(err.getvalue().strip(), "runtime_module_scan: ZeroDivisionError")
        finally:
            shutil.rmtree(d, ignore_errors=True)


class PackagesAndAppend(unittest.TestCase):
    """Slice 2 modes: module -> package for the consented install, and the requirements.txt edit."""

    def _run(self, files, *args):
        d = Path(tempfile.mkdtemp())
        try:
            for name, data in files.items():
                (d / name).write_bytes(data)
            r = subprocess.run([sys.executable, str(SOURCE)] + list(args), cwd=str(d),
                               capture_output=True, text=True)
            return r, {n.name: n.read_bytes() for n in d.iterdir()}
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_packages_maps_known_names_and_passes_the_rest_through(self):
        r, _ = self._run({"m.txt": b"xlsxwriter\ncv2\nsklearn\n"}, "--packages", "m.txt", "uv")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines(),
                         ["xlsxwriter xlsxwriter", "cv2 opencv-python", "sklearn scikit-learn"])

    def test_conda_uses_the_conda_forge_name_for_cv2_only(self):
        r, _ = self._run({"m.txt": b"cv2\nsklearn\n"}, "--packages", "m.txt", "conda")
        self.assertEqual(r.stdout.splitlines(), ["cv2 opencv", "sklearn scikit-learn"])

    def test_packages_drops_anything_that_is_not_a_plain_identifier(self):
        r, _ = self._run({"m.txt": b"ok_mod\nbad name\nx&y\n..\n"}, "--packages", "m.txt", "uv")
        self.assertEqual(r.stdout.splitlines(), ["ok_mod ok_mod"])

    def test_append_adds_only_what_is_not_declared_and_keeps_line_endings(self):
        req = b"numpy==1.26\r\nPillow>=10 ; python_version > '3.8'"  # no trailing newline, CRLF file
        ok = b"PIL pillow\nxlsxwriter xlsxwriter\nfoo_bar foo_bar\n"
        r, files = self._run({"requirements.txt": req, "ok.txt": ok}, "--append", "requirements.txt", "ok.txt")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split(), ["xlsxwriter", "foo_bar"])
        self.assertEqual(files["requirements.txt"],
                         b"numpy==1.26\r\nPillow>=10 ; python_version > '3.8'\r\nxlsxwriter\r\nfoo_bar\r\n")

    def test_append_treats_dash_underscore_and_case_as_the_same_name(self):
        r, files = self._run({"requirements.txt": b"Foo_Bar==1\n", "ok.txt": b"foo-bar foo-bar\n"},
                             "--append", "requirements.txt", "ok.txt")
        self.assertEqual(r.stdout, "")
        self.assertEqual(files["requirements.txt"], b"Foo_Bar==1\n")

    def test_append_creates_the_file_when_there_is_none(self):
        r, files = self._run({"ok.txt": b"xlsxwriter xlsxwriter\n"}, "--append", "requirements.txt", "ok.txt")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(files["requirements.txt"], b"xlsxwriter\n")

    def test_append_that_cannot_write_exits_three_and_prints_no_package(self):
        # The batch warns on any nonzero result (CodeRabbit, PR #511), and the added-package list must stay empty then,
        # or the log would say a line was added that never was. A folder in the file's place stands for a locked file.
        d = Path(tempfile.mkdtemp())
        try:
            (d / "requirements.txt").mkdir()
            (d / "ok.txt").write_bytes(b"xlsxwriter xlsxwriter\n")
            r = subprocess.run([sys.executable, str(SOURCE), "--append", "requirements.txt", "ok.txt"], cwd=str(d),
                               capture_output=True, text=True)
        finally:
            shutil.rmtree(d, ignore_errors=True)
        self.assertEqual(r.returncode, 3)
        self.assertEqual(r.stdout, "")
        # Opening a folder for writing is IsADirectoryError on Linux and PermissionError on Windows; the exit code and the
        # one-line reason are the contract, not which OSError subclass the platform picks (run 41034621526, justme-test).
        self.assertRegex(r.stderr.strip(), r"^runtime_module_scan: (IsADirectoryError|PermissionError)$")


class TableMatchesWarnfix(unittest.TestCase):
    def test_every_name_but_cv2_agrees_with_parse_warn(self):
        spec = importlib.util.spec_from_file_location("parse_warn_for_table", REPO / "tools" / "parse_warn.py")
        pw = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(pw)
        for mod, pkg in scan._PIP.items():
            if mod == "cv2":
                continue  # warnfix says opencv (the conda-forge name); PyPI's name is opencv-python
            with self.subTest(module=mod):
                self.assertEqual(pw.TRANSLATIONS.get(mod), pkg)


class BatchCallSites(unittest.TestCase):
    def setUp(self):
        self.bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")

    def test_the_scan_runs_after_the_exe_smoke_and_both_interpreter_runs(self):
        # EXE verification run, the no-EXE interpreter run (legacy branch), and the shared probe
        # (covers the interactive interpreter run and the post-execution checkpoint).
        self.assertIn('call :scan_runtime_missing_module exe "~run.err.txt"', self.bat)
        self.assertIn('call :scan_runtime_missing_module interpreter "~run.err.txt"', self.bat)
        self.assertIn('call :scan_runtime_missing_module "%HP_PROBE_SITE%" "%HP_PROBE_ERR%"', self.bat)

    def test_the_helper_is_emitted_from_its_payload(self):
        self.assertIn('call :emit_from_base64 "~runtime_module_scan.py" HP_RUNTIME_MODULE_SCAN', self.bat)

    def test_the_advice_names_the_active_dependency_source(self):
        # pyproject.toml and a PEP 723 header overwrite requirements.txt every run (CodeRabbit, PR #487).
        for marker in ("call :log \"[WARN] The program may have kept running anyway.",
                       "echo *** Add them, or the packages that provide them"):
            line = next(x for x in self.bat.splitlines() if marker in x)
            self.assertIn("%HP_RTM_WHERE%", line)
            self.assertNotIn("requirements.txt", line)
        i = re.search(r"(?m)^:rtm_where", self.bat).start()
        body = self.bat[i:self.bat.index("exit /b 0", i)]
        self.assertIn('"%DEP_SOURCE%"=="pyproject"', body)
        self.assertIn('"%DEP_SOURCE%"=="pep723"', body)

    def test_the_install_edits_requirements_whatever_the_dependency_source(self):
        # Item 91: before Item 89 a pyproject.toml or PEP 723 list was copied over requirements.txt on every run, so an
        # appended line was lost and the offer edited nothing for those sources. The merge now keeps a list's change,
        # so the append and the prompt that promises it no longer depend on DEP_SOURCE.
        i = re.search(r"(?m)^:runtime_install_offer", self.bat).start()
        block = self.bat[i:self.bat.index("\n:rti_install_one", i)]
        for gone in ("HP_RTI_EDITS", "rti_not_edited", "did not edit", "but does not edit"):
            self.assertNotIn(gone, block)
        self.assertIn("adds them to this program's own environment and to requirements.txt", block)
        accepted = block.index(":rti_accepted")
        append = block.index('--append "requirements.txt"')
        self.assertLess(accepted, append)
        self.assertNotIn("DEP_SOURCE", block[accepted:append])
        self.assertIn("Runtime install: added %%P to requirements.txt.", block)
        # A failed append is said out loud, on the line right after the helper call and before the added list is read.
        lines = block.splitlines()
        call = next(n for n, ln in enumerate(lines) if '--append "requirements.txt"' in ln)
        self.assertTrue(lines[call + 1].startswith('if errorlevel 1 call :log "[WARN] Runtime install: could not add the package to requirements.txt'), lines[call + 1])
        self.assertIn("Runtime install: added", lines[call + 2])
        self.assertIn("depSource=[Environment]::GetEnvironmentVariable('DEP_SOURCE')", self.bat)

    def test_the_rebuild_passes_both_flags_for_each_installed_module(self):
        # README REQ-018.19: --hidden-import and --collect-submodules for each installed module. The program loads the
        # package by a computed name, so self.runtime.install.accept shows the first flag by behavior (the check run is
        # clean only if the EXE holds the package); nothing runs the second flag, so its way onto the PyInstaller command
        # line is pinned here as text (CodeRabbit, PR 517).
        i = re.search(r"(?m)^:rti_rebuild", self.bat).start()
        body = self.bat[i:self.bat.index("\n:rti_row", i)]
        add = body[body.index(":rti_add_hidden"):]
        self.assertIn('--hidden-import=%~1"', add)
        self.assertIn('--collect-submodules=%~1"', add)
        loop = 'for /f "usebackq tokens=1,2" %%A in ("~runtime_install_ok.txt") do call :rti_add_hidden "%%A"'
        self.assertIn(loop, body)
        pyi = next(ln for ln in body.splitlines() if "-m PyInstaller" in ln)
        self.assertIn("%HP_PYI_HIDDEN_IMPORTS%", pyi)
        self.assertIn("%HP_PYI_HID_COLLECT%", pyi)
        self.assertLess(body.index(loop), body.index("-m PyInstaller"))

    def test_the_reminder_is_printed_before_the_lock_is_released(self):
        i = self.bat.index("if defined HP_RTM_FOUND call :print_runtime_missing_reminder")
        j = self.bat.index("call :release_lock", i)
        self.assertLess(i, j)


class EmbeddedHelperBaseline(unittest.TestCase):
    def test_source_parses_under_python_39_grammar(self):
        ast.parse(SOURCE.read_text(encoding="utf-8"), feature_version=(3, 9))

    def test_source_is_ascii(self):
        SOURCE.read_text(encoding="ascii")


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_RUNTIME_MODULE_SCAN=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_RUNTIME_MODULE_SCAN payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_RUNTIME_MODULE_SCAN base64 is out of sync with tools/runtime_module_scan.py; "
            "run: python tools/sync_payload.py HP_RUNTIME_MODULE_SCAN tools/runtime_module_scan.py",
        )


if __name__ == "__main__":
    unittest.main()
