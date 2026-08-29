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
import time
import unittest
from pathlib import Path

def _rmtree_best_effort(path: str) -> None:
    """Delete a temp directory tree, tolerating a still-running descendant on Windows."""
    # derived requirement (real Windows CI, PR #410): the grandchild-holds-pipe regression
    # test below deliberately leaves a sleeping grandchild process alive with its CWD inside
    # this directory (see GRANDCHILD_HOLDS_PIPE_SCRIPT) -- on Windows, a process's CWD is an
    # open directory handle, so shutil.rmtree() (and tempfile.TemporaryDirectory's own
    # __exit__ cleanup) fails with PermissionError/WinError 5/32 while that process is still
    # alive. This is a real, CI-observed failure (not reproducible on this Linux sandbox,
    # where deleting a directory a process has as its CWD is allowed) -- confirmed via two
    # separate real Windows CI lanes. The grandchild exits on its own after its sleep(30), so
    # ignore_errors=True here is a correct best-effort cleanup, not a masked bug: the test's
    # own assertions (elapsed time, output file presence) already prove the actual behavior
    # under test; a leftover temp directory is a harmless CI-runner artifact, cleaned up when
    # the runner's own ephemeral workspace is torn down.
    shutil.rmtree(path, ignore_errors=True)

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

# Regression script for the process-tree-kill gap (CodeRabbit review, PR #410): spawns a
# grandchild that inherits OUR stdout (the redirected pipe from the .NET parent) and then
# exits immediately itself. Process.Kill() (or the process's own fast exit) only affects the
# immediate child tracked by $p -- the grandchild keeps the pipe's write end open, so
# ReadToEndAsync() alone would never reach EOF. Proves the bounded drain-wait fallback
# (Task.Wait($drainMs)) prevents this from hanging the helper forever.
GRANDCHILD_HOLDS_PIPE_SCRIPT = """
import subprocess, sys
subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], stdout=sys.stdout, stderr=sys.stdout)
sys.exit(0)
"""


def _make_script(d, name, body):
    path = Path(d) / (name + ".py")
    path.write_text(body, encoding="utf-8")
    return path


def _run_hint_rerun(d, script, env_extra, timeout=15):
    # CLAUDE.md Active Backlog Item 38: :exe_smokerun_hints' caller CWD is now the app root, not
    # dist\ (matching :run_exe_smokerun's own primary-run CWD, since this rerun exists purely to
    # explain that primary run's own failure). Default HP_HINT_RERUN_OUT is the CWD-relative
    # "~exe_out.txt", so run with cwd=d to land the default at d/~exe_out.txt.
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin", "HP_HINT_RERUN_EXE": sys.executable}
    env.update(env_extra)
    with open(script, "r", encoding="utf-8") as stdin_src:
        return subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE)],
            cwd=str(d),
            env=env,
            stdin=stdin_src,
            capture_output=True,
            text=True,
            timeout=timeout,
        )


def _out_path(d, env_extra):
    override = env_extra.get("HP_HINT_RERUN_OUT")
    return Path(override) if override else (Path(d) / "~exe_out.txt")


def _killms_path(d, env_extra) -> Path:
    override = env_extra.get("HP_HINT_RERUN_KILLMS_OUT")
    return Path(override) if override else (Path(d) / "~exe_hint_killms.txt")


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
    # derived requirement (CodeRabbit review, PR #410; redesigned after four real-CI runs proved
    # a wall-clock upper bound is not a reliable signal here): elapsed-time assertions on this
    # test kept flaking upward on shared real-Windows CI runners -- 9.235s, 13.468s, 14.578s,
    # 16.328s of overhead were all observed for the SAME 500ms override across different runs,
    # with no bound converging. The actual thing worth proving -- that HP_HINT_RERUN_KILL_MS was
    # read and used, rather than silently falling back to the 10000ms default -- does not need
    # wall-clock inference at all: the script now writes its resolved $killMs directly to
    # HP_HINT_RERUN_KILLMS_OUT (see tools/exe_hint_rerun.ps1), so the test reads that value
    # straight instead of guessing it from timing. A generous, loose wall-clock ceiling is kept
    # only as a coarse sanity net against the kill mechanism being completely broken (e.g. never
    # firing at all, letting the script run out its full HANG_*_SCRIPT sleep) -- it is not tuned
    # to the override value and should not need adjusting for ordinary CI noise.
    SANITY_CEILING_SECONDS = 45
    RUN_TIMEOUT_SECONDS = 60

    def test_silent_hang_is_killed(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "hang", HANG_SILENT_SCRIPT)
            env = {"HP_HINT_RERUN_KILL_MS": "500"}
            start = time.monotonic()
            proc = _run_hint_rerun(d, script, env, timeout=self.RUN_TIMEOUT_SECONDS)
            elapsed = time.monotonic() - start
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_killms_path(d, env).read_text(encoding="ascii").strip(), "500",
                              "script did not read/use the HP_HINT_RERUN_KILL_MS override")
            self.assertLess(elapsed, self.SANITY_CEILING_SECONDS, "kill mechanism appears completely broken")
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
            start = time.monotonic()
            proc = _run_hint_rerun(d, script, env, timeout=self.RUN_TIMEOUT_SECONDS)
            elapsed = time.monotonic() - start
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_killms_path(d, env).read_text(encoding="ascii").strip(), "500",
                              "script did not read/use the HP_HINT_RERUN_KILL_MS override")
            self.assertLess(elapsed, self.SANITY_CEILING_SECONDS, "kill mechanism appears completely broken")
            self.assertIn("some output before hanging", _out_path(d, env).read_text(encoding="ascii"))

    def test_default_kill_ms_unset_means_10000(self):
        text = SOURCE.read_text(encoding="utf-8")
        self.assertIn("$killMs = 10000", text)
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast_default", FAST_SCRIPT)
            env = {}
            proc = _run_hint_rerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_killms_path(d, env).read_text(encoding="ascii").strip(), "10000")


@unittest.skipUnless(PWSH, "pwsh not available")
class ProcessTreeAndDrainTimeout(unittest.TestCase):
    def test_grandchild_holding_pipe_open_does_not_hang_forever(self):
        # Regression test for the process-tree-kill gap (CodeRabbit review, PR #410): a
        # grandchild that inherits the redirected pipe and outlives its own parent would make
        # an unbounded ReadToEndAsync().Result hang forever. The bounded drain-wait fallback
        # (Task.Wait($drainMs), hardcoded 5000ms in the script) must let the helper complete
        # anyway, with partial/empty output rather than hanging -- proven here by the test
        # itself completing well within its own timeout despite the grandchild sleeping 30s.
        # On this Linux sandbox (no taskkill.exe) this specifically exercises the drain-wait
        # fallback; on real Windows CI (confirmed via two lanes on PR #410) the same
        # assertions pass too, so the taskkill /T process-tree kill path is now exercised
        # there as well -- only cleanup of the tempdir itself needed a Windows-specific fix
        # (see _rmtree_best_effort above: the sleeping grandchild's CWD is an open directory
        # handle on Windows, which blocks a plain rmtree while it's still alive).
        d = tempfile.mkdtemp()
        try:
            script = _make_script(d, "grandchild_holds_pipe", GRANDCHILD_HOLDS_PIPE_SCRIPT)
            env = {}
            start = time.monotonic()
            proc = _run_hint_rerun(d, script, env, timeout=15)
            elapsed = time.monotonic() - start
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertLess(elapsed, 10, "drain-wait fallback did not bound the hang")
            # The output file must still be written (empty or partial is acceptable -- the
            # point is the helper terminates, not that it captures the grandchild's output).
            self.assertTrue(_out_path(d, env).exists())
        finally:
            _rmtree_best_effort(d)


@unittest.skipUnless(PWSH, "pwsh not available")
class OutputPaths(unittest.TestCase):
    def test_custom_out_path_honored(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            custom = str(Path(d) / "~custom_hint.txt")
            env = {"HP_HINT_RERUN_OUT": custom}
            proc = _run_hint_rerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(Path(custom).exists())

    def test_custom_killms_out_path_honored(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            custom = str(Path(d) / "~custom_killms.txt")
            env = {"HP_HINT_RERUN_KILLMS_OUT": custom, "HP_HINT_RERUN_KILL_MS": "7000"}
            proc = _run_hint_rerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(Path(custom).read_text(encoding="ascii").strip(), "7000")


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
