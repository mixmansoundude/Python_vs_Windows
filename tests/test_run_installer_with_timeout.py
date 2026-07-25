"""Tests for tools/run_installer_with_timeout.ps1 -- the helper behind run_setup.bat's new
:run_installer_timeout subroutine ([Active Backlog item 14]: bound the three "start "" /wait"
external-installer launches -- NI-VISA, Miniconda AllUsers, Miniconda JustMe -- with a generous,
configurable timeout ceiling instead of an unbounded wait).

No importable functions exist -- exercised end-to-end via a real `pwsh` subprocess, mirroring
tests/test_exe_smokerun.py's own established pattern for this repo's other emitted-.ps1 process
helpers.

derived requirement: this script sets UseShellExecute = $true (deliberately, to preserve the
same UAC-elevation-via-manifest behavior "start "" /wait" already had -- see the script's own
header comment), which means it does NOT redirect the child's stdout/stderr. Tests therefore
cannot assert on captured output the way test_exe_smokerun.py's FastExit/ActivityAwareStop
classes do -- instead, the stand-in "installer" scripts below write their own side-effect files
(so a test can confirm what actually ran / what arguments it received) and the test asserts on
the RESULT FILE (`HP_INSTALLER_RESULT`, "<exitcode>|<timedout:0/1>") plus those side-effect files.

The timeout/Kill() path is real but its taskkill.exe cleanup step is Windows-only -- confirmed
directly (via a local pwsh repro before writing this file) that on a non-Windows pwsh host,
`taskkill.exe` is simply not found, the script's own `try { ... } catch {}` swallows that error
cleanly (no crash, no hang), and the timeout branch still correctly writes "1|1" to the result
file -- so the timeout-detection behavior is fully testable here even though the actual
process-tree kill itself can only be confirmed on real Windows CI. Test cleans up any leaked
child process itself afterward so a local/CI run of this suite never leaves orphans behind.
"""
import base64
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "run_installer_with_timeout.ps1"
PWSH = shutil.which("pwsh")

FAST_SCRIPT = """
import sys
sys.exit(3)
"""

ARGV_ECHO_SCRIPT = """
import sys, pathlib
pathlib.Path("argv_seen.txt").write_text("|".join(sys.argv[1:]), encoding="ascii")
sys.exit(0)
"""

# Writes a marker file, then sleeps -- long enough to reliably outlast a short test timeout, but
# the test process itself is force-killed (SIGKILL) after asserting on the result file, so this
# never actually needs to sleep its full duration in practice.
HANG_SCRIPT = """
import pathlib, time
pathlib.Path("hang_started.txt").write_text("started", encoding="ascii")
time.sleep(60)
"""


def _make_script(d, name, body):
    path = Path(d) / (name + ".py")
    path.write_text(body, encoding="utf-8")
    return path


def _run_installer(d, exe, args, timeout_ms, env_extra=None, wait=10, capture=True):
    env = dict(os.environ)
    env["HP_INSTALLER_EXE"] = exe
    if args is not None:
        env["HP_INSTALLER_ARGS"] = args
    env["HP_INSTALLER_TIMEOUT_MS"] = str(timeout_ms)
    if env_extra:
        env.update(env_extra)
    # derived requirement: on a run whose grandchild ("installer") is left running past the
    # timeout (taskkill.exe is Windows-only -- see the module docstring), that grandchild
    # inherits this pwsh process's own stdout/stderr pipes. subprocess.run's capture_output=True
    # uses real pipes, so Popen.communicate() blocks waiting for EOF on those pipes until the
    # grandchild itself exits/closes them -- even though pwsh (the direct child) has already
    # returned. Redirect to DEVNULL instead of a pipe for the timeout-path test so this doesn't
    # hang; fast-exit tests still use real pipes (capture=True) to assert on stdout/stderr.
    if capture:
        return subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE)],
            cwd=d,
            env=env,
            capture_output=True,
            text=True,
            timeout=wait,
        )
    return subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE)],
        cwd=d,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=wait,
    )


def _result(d, env_extra=None):
    override = (env_extra or {}).get("HP_INSTALLER_RESULT")
    result_path = Path(override) if override else (Path(d) / "~installer_result.txt")
    return result_path.read_text(encoding="ascii").strip()


@unittest.skipUnless(PWSH, "pwsh not available")
class FastExit(unittest.TestCase):
    def test_fast_exit_result_captured_and_not_timed_out(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            proc = _run_installer(d, sys.executable, str(script), 5000)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d), "3|0")

    def test_arguments_forwarded_as_single_arguments_string(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "argv", ARGV_ECHO_SCRIPT)
            args = "%s --foo bar" % script
            proc = _run_installer(d, sys.executable, args, 5000)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d), "0|0")
            # sys.argv[0] (the script's own path) is excluded by ARGV_ECHO_SCRIPT's own
            # sys.argv[1:] slice -- only the two forwarded flags should appear.
            seen = (Path(d) / "argv_seen.txt").read_text(encoding="ascii")
            self.assertEqual(seen, "--foo|bar")

    def test_no_arguments_means_arguments_not_set(self):
        # No HP_INSTALLER_ARGS at all -- exercises the "if ($argStr)" false branch. A script
        # with no required argv still runs to completion.
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            proc = _run_installer(d, sys.executable, script.as_posix(), 5000, env_extra=None)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d), "3|0")


@unittest.skipUnless(PWSH, "pwsh not available")
class TimeoutDetection(unittest.TestCase):
    def test_hung_process_reports_timeout_in_result_file(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "hang", HANG_SCRIPT)
            proc = _run_installer(d, sys.executable, str(script), 300, wait=15, capture=False)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(_result(d), "1|1")
            # Confirm the process genuinely started (proves this is a real timeout being
            # detected, not e.g. the child failing to launch at all).
            self.assertTrue((Path(d) / "hang_started.txt").exists())
            # Best-effort cleanup: taskkill.exe is Windows-only, so on this (non-Windows) test
            # host the child is left running past the script's own return -- reap it here so
            # the test suite never leaks a sleep(60) process into later tests / the shell.
            self._reap_leftover(script)

    @staticmethod
    def _reap_leftover(script_path):
        try:
            out = subprocess.run(
                ["pgrep", "-f", str(script_path)], capture_output=True, text=True, timeout=5
            )
        except Exception:
            return
        for pid_text in out.stdout.split():
            try:
                os.kill(int(pid_text), signal.SIGKILL)
            except (ValueError, ProcessLookupError, PermissionError):
                pass
        # Give the OS a moment to reap before the temp dir is removed out from under it.
        time.sleep(0.2)


@unittest.skipUnless(PWSH, "pwsh not available")
class ResultPathOverride(unittest.TestCase):
    def test_caller_specified_result_path(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            result_path = Path(d) / "custom_result.txt"
            env = {"HP_INSTALLER_RESULT": str(result_path)}
            proc = _run_installer(d, sys.executable, str(script), 5000, env_extra=env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "3|0")
            self.assertFalse((Path(d) / "~installer_result.txt").exists())

    def test_default_result_path_is_tilde_installer_result_txt(self):
        text = SOURCE.read_text(encoding="utf-8")
        self.assertIn("~installer_result.txt", text)


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        # derived requirement: tools/run_installer_with_timeout.ps1 carries .gitattributes'
        # `*.ps1 text eol=crlf`, so a checkout on Windows CI materializes CRLF line endings
        # regardless of what the payload was encoded from -- normalize both sides before
        # comparing so this verifies content, not incidental checkout-time line-ending
        # translation (see docs/agent-lessons-learned.md "Embedded Helper Update Workflow").
        bat = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_INSTALLER_TIMEOUT=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_INSTALLER_TIMEOUT payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).replace(b"\r\n", b"\n")
        source = SOURCE.read_bytes().replace(b"\r\n", b"\n")
        self.assertEqual(
            decoded, source,
            "HP_INSTALLER_TIMEOUT base64 is out of sync with "
            "tools/run_installer_with_timeout.ps1; re-sync with tools/sync_payload.py.",
        )


class CallSitesUseSubroutine(unittest.TestCase):
    def test_all_three_start_wait_installer_launches_now_route_through_the_subroutine(self):
        # Regression guard: the whole point of this feature is that NONE of the three external
        # installer launches (NI-VISA, Miniconda AllUsers, Miniconda JustMe) still use a bare,
        # unbounded "start "" /wait" -- a future edit that reverts one back to the old pattern
        # (e.g. while touching nearby code) should be caught here, not rediscovered live.
        text = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        bare_start_wait = re.findall(r'start\s+(?:/wait\s+""|""\s+/wait)\s+"[^"]*(?:miniconda|ni-visa)', text, re.IGNORECASE)
        self.assertEqual(
            bare_start_wait, [],
            "found a bare (untimed) start \"\" /wait installer launch that should route "
            "through :run_installer_timeout instead: %r" % (bare_start_wait,),
        )
        self.assertEqual(text.count("call :run_installer_timeout "), 3)


if __name__ == "__main__":
    unittest.main()
