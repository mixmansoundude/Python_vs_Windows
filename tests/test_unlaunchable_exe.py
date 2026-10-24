"""Item 87: a file that cannot be started must end the check, not hang it.

The three bounded-launch helpers (tools/exe_smokerun.ps1, tools/failfast_probe.ps1, tools/exe_hint_rerun.ps1) called
$p.Start() without handling a failure. When Start() throws (a text file, a zero-byte file or a truncated copy of a
program named dist\\<env>.exe; an antivirus stub; an interrupted build), the process object has no process, the read
loop's `-not $p.HasExited` test errors and reads as true, and the loop spins forever. The first red-test commit of
PR #499 seeded a text file as the EXE and the step ran for over ten minutes until the next push cancelled it.

Contract after the fix (each helper, exercised end to end through a real `pwsh` subprocess with a hard timeout):
  - it returns, exit code 0, no PowerShell error text on stderr;
  - it writes ~launch_failed.txt: one line, printable ASCII only, at most 200 characters (the caller shows it with
    `type`, so < > & | % ^ may stay, nothing else unprintable may);
  - it prints a console line that says the program could not be started;
  - exe_smokerun writes result -1, failfast_probe writes 0|-1 (not exceeded, exit -1: the cached-EXE caller already
    discards and rebuilds on that), exe_hint_rerun writes an empty output file (the hint falls through to the
    generic one); smokerun and probe leave empty output/error files and never leave ~smokerun_killed.txt.
The batch side is pinned by the static tests at the bottom (ordering of the marker read, the delete of the unusable
EXE, the interpreter run that follows, the test hook). A real Windows run of the batch is the row set in
tests/selfapps_unlaunchable_exe.ps1.
"""
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
BAT = REPO / "run_setup.bat"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 25  # seconds; the old code never returned

KINDS = ("text", "empty", "truncated")


def _make_bad(d, kind, name="bad.exe"):
    path = Path(d) / name
    if kind == "text":
        path.write_text("this is not a program\n", encoding="ascii")
    elif kind == "empty":
        path.write_bytes(b"")
    elif kind == "truncated":
        path.write_bytes(Path(sys.executable).read_bytes()[:64])
    else:
        raise ValueError(kind)
    path.chmod(0o755)  # so Linux fails with a format error, not a permission error; Windows ignores the bit
    return path


def _run(helper, d, env_extra):
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin"}
    env.update(env_extra)
    try:
        return subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-File", str(TOOLS / helper)],
            cwd=str(d), env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=HARD_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        raise AssertionError(
            "%s was still running after %d seconds: a program that cannot be started must end the check" % (helper, HARD_TIMEOUT)
        )


class _Contract:
    """Checks shared by the three helpers."""

    def _marker_line(self, d):
        marker = Path(d) / "~launch_failed.txt"
        self.assertTrue(marker.exists(), "~launch_failed.txt was not written")
        raw = marker.read_bytes()
        text = raw.decode("ascii")  # raises on a non-ASCII byte
        lines = [ln for ln in text.splitlines() if ln.strip()]
        self.assertEqual(len(lines), 1, text)
        self.assertLessEqual(len(lines[0]), 200)
        self.assertTrue(all(0x20 <= ord(c) <= 0x7E for c in lines[0]), repr(lines[0]))
        return lines[0]

    def _common(self, proc, d):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotRegex(proc.stderr, r"Exception|cannot call a method|null-valued")
        self.assertIn("could not be started", proc.stdout)
        self._marker_line(d)
        self.assertFalse((Path(d) / "~smokerun_killed.txt").exists())


@unittest.skipUnless(PWSH, "pwsh not available")
class SmokerunLaunchFailure(_Contract, unittest.TestCase):
    def _go(self, d, exe):
        return _run("exe_smokerun.ps1", d, {"HP_SMOKERUN_EXE": str(exe)})

    def test_unlaunchable_file_ends_the_check_with_result_minus_one(self):
        for kind in KINDS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as d:
                proc = self._go(d, _make_bad(d, kind))
                self._common(proc, d)
                self.assertEqual((Path(d) / "~smokerun_result.txt").read_text(encoding="ascii").strip(), "-1")
                self.assertEqual((Path(d) / "~run.out.txt").read_text(encoding="ascii").strip(), "")
                self.assertEqual((Path(d) / "~run.err.txt").read_text(encoding="ascii").strip(), "")

    def test_missing_file_is_the_same_failure(self):
        with tempfile.TemporaryDirectory() as d:
            proc = self._go(d, Path(d) / "does_not_exist.exe")
            self._common(proc, d)
            self.assertEqual((Path(d) / "~smokerun_result.txt").read_text(encoding="ascii").strip(), "-1")

    def test_reason_keeps_batch_metacharacters_as_text_and_drops_the_unprintable(self):
        with tempfile.TemporaryDirectory() as d:
            exe = _make_bad(d, "text", name="a&b%c^d.exe")
            proc = self._go(d, exe)
            self._common(proc, d)  # printable ASCII only, one line, checked there

    def test_a_good_program_leaves_no_launch_marker(self):
        with tempfile.TemporaryDirectory() as d:
            proc = _run("exe_smokerun.ps1", d, {"HP_SMOKERUN_EXE": sys.executable, "HP_SMOKERUN_ARGS": "-c \"pass\""})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertFalse((Path(d) / "~launch_failed.txt").exists())
            self.assertEqual((Path(d) / "~smokerun_result.txt").read_text(encoding="ascii").strip(), "0")


@unittest.skipUnless(PWSH, "pwsh not available")
class ProbeLaunchFailure(_Contract, unittest.TestCase):
    def _go(self, d, exe):
        return _run("failfast_probe.ps1", d, {"HP_PROBE_EXE": str(exe), "HP_PROBE_CWD": str(d), "HP_FAILFAST_PROBE_MS": "300"})

    def test_unlaunchable_file_reports_a_fast_failed_run(self):
        for kind in KINDS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as d:
                proc = self._go(d, _make_bad(d, kind))
                self._common(proc, d)
                self.assertEqual((Path(d) / "~probe_result.txt").read_text(encoding="ascii").strip(), "0|-1")
                self.assertEqual((Path(d) / "~run.out.txt").read_text(encoding="ascii").strip(), "")
                self.assertEqual((Path(d) / "~run.err.txt").read_text(encoding="ascii").strip(), "")

    def test_a_good_program_leaves_no_launch_marker(self):
        with tempfile.TemporaryDirectory() as d:
            proc = _run("failfast_probe.ps1", d, {"HP_PROBE_EXE": sys.executable, "HP_PROBE_ARGS": "-c \"pass\"", "HP_PROBE_CWD": str(d), "HP_FAILFAST_PROBE_MS": "300"})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertFalse((Path(d) / "~launch_failed.txt").exists())
            self.assertEqual((Path(d) / "~probe_result.txt").read_text(encoding="ascii").strip(), "0|0")


@unittest.skipUnless(PWSH, "pwsh not available")
class HintRerunLaunchFailure(_Contract, unittest.TestCase):
    def test_unlaunchable_file_leaves_an_empty_hint_output(self):
        for kind in KINDS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as d:
                proc = _run("exe_hint_rerun.ps1", d, {"HP_HINT_RERUN_EXE": str(_make_bad(d, kind)), "HP_HINT_RERUN_KILL_MS": "500"})
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertNotRegex(proc.stderr, r"Exception|cannot call a method|null-valued")
                self.assertEqual((Path(d) / "~exe_out.txt").read_text(encoding="ascii").strip(), "")


class BatchWiring(unittest.TestCase):
    """Static pins for run_setup.bat; behaviour is the real-lane rows of tests/selfapps_unlaunchable_exe.ps1."""

    @classmethod
    def setUpClass(cls):
        cls.text = BAT.read_text(encoding="ascii", errors="replace").replace("\r\n", "\n")

    def _sub(self, label, nxt):
        a = self.text.index("\n:" + label + "\n")
        b = self.text.index("\n:" + nxt + "\n", a)
        return self.text[a:b]

    def test_smokerun_clears_reads_and_acts_on_the_marker_before_judging_the_exit_code(self):
        body = self._sub("run_exe_smokerun", "exe_smokerun_hints")
        clear = body.index('del "~launch_failed.txt"')
        launch = body.index('powershell -NoProfile -ExecutionPolicy Bypass -File "~exe_smokerun.ps1"')
        read = body.index("HP_EXE_LAUNCH_FAILED=1")
        judge = body.index('if "%HP_EXE_EXIT%"=="0" goto :smokerun_ok')
        self.assertLess(clear, launch)
        self.assertLess(launch, read)
        self.assertLess(read, judge)
        self.assertIn("goto :smokerun_launch_failed", body)

    def test_launch_failure_branch_removes_the_unusable_exe_and_is_not_a_timeout(self):
        body = self._sub("run_exe_smokerun", "exe_smokerun_hints")
        branch = body[body.index("\n:smokerun_launch_failed\n"):]
        branch = branch[: branch.index("\nexit /b 0")]
        self.assertIn('del /f /q "dist\\%ENVNAME%.exe"', branch)
        self.assertIn('set "HP_EXE_UNUSABLE=1"', branch)
        self.assertIn('set "HP_EXE_VERIFY_FAILED=1"', branch)
        self.assertIn('set "HP_FRESH_BUILD_OK="', branch)  # no hash may vouch for an EXE that never ran
        self.assertIn("call :report_launch_failure", branch)
        self.assertNotIn("HP_EXE_TIMEDOUT_SILENT", branch)
        self.assertNotIn("Run Status: TIMED OUT", branch)

    def test_reporter_shows_the_reason_with_type_never_through_log(self):
        # the reason is arbitrary text from .NET: shown with type and appended to the log with type, never through :log
        body = self._sub("report_launch_failure", "run_postexec_checkpoint")
        self.assertIn('type "~launch_failed.txt"', body)
        self.assertIn('>> "%LOG%"', body)
        self.assertIn('del "~launch_failed.txt"', body)
        self.assertNotRegex(body, r':log[^\n]*launch_failed')

    def test_interpreter_verification_runs_when_the_exe_is_unusable(self):
        body = self._sub("verify_no_exe_interpreter", "verify_no_exe_probe")
        line = [ln for ln in body.splitlines() if ln.startswith('if exist "dist\\%ENVNAME%.exe"')][0]
        self.assertIn("HP_EXE_UNUSABLE", line)

    def test_probe_clears_and_reports_the_marker(self):
        body = self._sub("run_failfast_probe", "report_launch_failure")
        clear = body.index('del "~launch_failed.txt"')
        launch = body.index('powershell -NoProfile -ExecutionPolicy Bypass -File "%HP_PROBE_PS%"')
        report = body.index("call :report_launch_failure")
        self.assertLess(clear, launch)
        self.assertLess(launch, report)

    def test_hook_that_simulates_a_stub_sits_before_the_launch_in_the_smoke_subroutine(self):
        body = self._sub("run_exe_smokerun", "exe_smokerun_hints")
        hook = body.index("HP_TEST_CORRUPT_BUILT_EXE")
        launch = body.index('powershell -NoProfile -ExecutionPolicy Bypass -File "~exe_smokerun.ps1"')
        self.assertLess(hook, launch)

    def test_state_is_reset_per_fresh_build(self):
        # HP_EXE_UNUSABLE must not leak into a cascade tier's build: it is cleared where HP_EXE_TIMEDOUT_SILENT is.
        idx = self.text.index('set "HP_EXE_TIMEDOUT_SILENT="')
        self.assertIn('set "HP_EXE_UNUSABLE="', self.text[idx - 400: idx + 400])


if __name__ == "__main__":
    unittest.main()
