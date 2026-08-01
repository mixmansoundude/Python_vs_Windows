"""Tests for tools/exe_hint_rerun.ps1 -- the bounded diagnostic re-run helper for
:exe_smokerun_hints (closes former CLAUDE.md Active Backlog item 15: the ONE user-code launch
point in run_setup.bat with no timeout at all).

No importable functions exist -- exercised end-to-end via a real `pwsh` subprocess, mirroring
tests/test_exe_smokerun.py's own harness (sys.executable as the fake "exe", fed via inherited
stdin -- see that file's module docstring for why a shebang/chmod script does not work under
UseShellExecute=$false on Windows).

Unlike exe_smokerun.ps1 (activity-aware: any output before the deadline skips the kill and the
wait becomes unbounded), this helper is diagnostic-only and kills UNCONDITIONALLY at the
deadline -- a process that prints something and then hangs must still be cut off, since nothing
downstream needs more than a stderr/stdout snapshot for pattern-matching.
"""
import base64
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "exe_hint_rerun.ps1"
PWSH = shutil.which("pwsh")

FAST_SCRIPT = """
import sys
print("hint-fast-out")
print("ModuleNotFoundError: No module named 'nope'", file=sys.stderr)
sys.exit(1)
"""

HANG_SILENT_SCRIPT = """
import time
time.sleep(120)
"""

HANG_AFTER_OUTPUT_SCRIPT = """
import sys, time
print("some output before hanging", flush=True)
time.sleep(120)
"""


def _make_script(d, name, body):
    path = Path(d) / (name + ".py")
    path.write_text(body, encoding="utf-8")
    return path


def _run_hint_rerun(d, script, env_extra, timeout=15):
    # Mirrors :exe_smokerun_hints' own `pushd dist` convention: default HP_HINT_RERUN_OUT is
    # the CWD-relative "~exe_out.txt", so run with cwd=d/dist to land the default at
    # d/dist/~exe_out.txt, matching :exe_smokerun_hints' own `dist\~exe_out.txt` reference.
    dist = Path(d) / "dist"
    dist.mkdir(exist_ok=True)
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin", "HP_HINT_RERUN_EXE": sys.executable}
    env.update(env_extra)
    with open(script, "r", encoding="utf-8") as stdin_src:
        return subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE)],
            cwd=str(dist),
            env=env,
            stdin=stdin_src,
            capture_output=True,
            text=True,
            timeout=timeout,
        )


def _out_path(d, env_extra):
    override = env_extra.get("HP_HINT_RERUN_OUT")
    return Path(override) if override else (Path(d) / "dist" / "~exe_out.txt")


@unittest.skipUnless(PWSH, "pwsh not available")
class FastExit(unittest.TestCase):
    def test_fast_exit_output_captured_combined(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            env = {}
            proc = _run_hint_rerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            combined = _out_path(d, env).read_text(encoding="ascii")
            # derived requirement: stdout+stderr must land in ONE file (matching the original
            # `"%ENVNAME%.exe" > "~exe_out.txt" 2>&1` merge behavior) since the existing
            # :exe_smokerun_hints findstr checks only look for substring presence in one file,
            # never which stream a line came from.
            self.assertIn("hint-fast-out", combined)
            self.assertIn("ModuleNotFoundError: No module named 'nope'", combined)


@unittest.skipUnless(PWSH, "pwsh not available")
class UnconditionalKill(unittest.TestCase):
    def test_silent_hang_is_killed(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "hang", HANG_SILENT_SCRIPT)
            env = {"HP_HINT_RERUN_KILL_MS": "500"}
            proc = _run_hint_rerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            # No result/exit-code file is written by this helper (only the combined output
            # file) -- the caller only ever pattern-matches text, never checks an exit code.
            self.assertTrue(_out_path(d, env).exists())

    def test_hang_after_output_is_ALSO_killed_unlike_exe_smokerun(self):
        # The defining behavioral difference from exe_smokerun.ps1/failfast_probe.ps1: THOSE
        # skip the kill once any output has been observed (activity-aware, for a real
        # verification run worth waiting on). This helper must NOT do that -- it is a
        # diagnostic-only snapshot, so a process that prints once and then hangs must still be
        # bounded, or the whole point of adding a timeout here is defeated.
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "hang_after", HANG_AFTER_OUTPUT_SCRIPT)
            env = {"HP_HINT_RERUN_KILL_MS": "500"}
            proc = _run_hint_rerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("some output before hanging", _out_path(d, env).read_text(encoding="ascii"))
            # If this test itself completes within the subprocess.run timeout (15s) rather than
            # hanging for the full 120s sleep, the unconditional kill worked.

    def test_default_kill_ms_unset_means_10000(self):
        text = SOURCE.read_text(encoding="utf-8")
        self.assertIn("$killMs = 10000", text)


@unittest.skipUnless(PWSH, "pwsh not available")
class OutputPaths(unittest.TestCase):
    def test_custom_out_path_honored(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            custom = str(Path(d) / "dist" / "~custom_hint.txt")
            env = {"HP_HINT_RERUN_OUT": custom}
            proc = _run_hint_rerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(Path(custom).exists())


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        # See tests/test_exe_smokerun.py's own PayloadSync test for why CRLF/LF normalization
        # is required here (`*.ps1 text eol=crlf` in .gitattributes).
        bat = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_EXE_HINT_RERUN=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_EXE_HINT_RERUN payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).replace(b"\r\n", b"\n")
        source = SOURCE.read_bytes().replace(b"\r\n", b"\n")
        self.assertEqual(
            decoded, source,
            "HP_EXE_HINT_RERUN base64 is out of sync with tools/exe_hint_rerun.ps1; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
