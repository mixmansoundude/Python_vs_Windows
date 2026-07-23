"""Tests for tools/exe_smokerun.ps1 -- the dedicated helper for :run_exe_smokerun (the sole,
timed, kill-after-30s verification pass for a freshly-built EXE that has never been confirmed
working). Split out of an inline `-Command "..."` one-liner into an emitted .ps1 file as part of
docs/plan-cli-interactive-verification.md's requirement 1: Register-ObjectEvent's -Action
scriptblock needs literal-quote-containing PowerShell an inline -Command string cannot safely
hold, and the caller no longer wraps this script's invocation in a for /f stdout capture (see
tools/failfast_probe.ps1's sibling test module docstring for the full for /f-capture-vs-tee
conflict this also applies to).

No importable functions exist -- exercised end-to-end via a real `pwsh` subprocess against a
small "exe" (a real executable script with a shebang, since HP_SMOKERUN_EXE is invoked directly
with no separate arguments field, matching the frozen EXE's own invocation shape).

Covers: normal fast exit (result file + captured output), the Kill()-after-timeout path (via the
HP_SMOKERUN_KILL_MS test-only override -- production always uses the unset default, 30000ms,
matching the prior inline implementation exactly; see the script's own header comment), caller
output-path overrides, and the base64 HP_EXE_SMOKERUN payload sync (byte-equality vs this source,
CRLF/LF-normalized, mirroring the .ps1 PayloadSync convention used across this repo -- see
docs/agent-lessons-learned.md "Embedded Helper Update Workflow").
"""
import base64
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "exe_smokerun.ps1"
PWSH = shutil.which("pwsh")

FAST_EXE = """#!{python}
import sys
print("fast-hello")
print("fast-hello-err", file=sys.stderr)
sys.exit(3)
"""

HANG_EXE = """#!{python}
import sys, time
print("about-to-hang", flush=True)
time.sleep(120)
sys.exit(0)
"""


def _make_exe(d, name, template):
    path = Path(d) / name
    path.write_text(template.format(python=sys.executable), encoding="utf-8")
    st = os.stat(path)
    os.chmod(path, st.st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return path


def _run_smokerun(d, env_extra, timeout=15):
    # Mirrors :run_exe_smokerun's own `pushd dist` convention (REQ-018 2b-A.2): default output
    # paths are `..\~run.out.txt` / `..\~run.err.txt`, relative to a dist\ subdirectory -- so the
    # default-path tests run with cwd=d/dist to land the defaults at d/~run.out.txt etc.
    dist = Path(d) / "dist"
    dist.mkdir(exist_ok=True)
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin"}
    env.update(env_extra)
    return subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE)],
        cwd=str(dist),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _result(d, env_extra):
    # HP_SMOKERUN_RESULT defaults to plain ~smokerun_result.txt (CWD-relative, i.e. inside
    # dist\, unlike HP_SMOKERUN_OUT/ERR's ..\-prefixed defaults) -- see _run_smokerun's own
    # comment for why cwd is d/dist.
    override = env_extra.get("HP_SMOKERUN_RESULT")
    result_path = Path(override) if override else (Path(d) / "dist" / "~smokerun_result.txt")
    return result_path.read_text(encoding="ascii").strip()


@unittest.skipUnless(PWSH, "pwsh not available")
class FastExit(unittest.TestCase):
    def test_fast_exit_result_and_output_captured(self):
        with tempfile.TemporaryDirectory() as d:
            exe = _make_exe(d, "fast_exe", FAST_EXE)
            env = {"HP_SMOKERUN_EXE": str(exe)}
            proc = _run_smokerun(d, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "3")
            self.assertIn("fast-hello", (Path(d) / "~run.out.txt").read_text(encoding="ascii"))
            self.assertIn("fast-hello-err", (Path(d) / "~run.err.txt").read_text(encoding="ascii"))

    def test_live_tee_reaches_own_stdout_stderr(self):
        # docs/plan-cli-interactive-verification.md Finding 5b/6: the whole point of converting
        # this to an emitted helper with event-driven reads is that a real user watching the
        # console sees the child's own output live, not only captured to disk after exit.
        with tempfile.TemporaryDirectory() as d:
            exe = _make_exe(d, "fast_exe", FAST_EXE)
            proc = _run_smokerun(d, {"HP_SMOKERUN_EXE": str(exe)})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("fast-hello", proc.stdout)
            self.assertIn("fast-hello-err", proc.stderr)


@unittest.skipUnless(PWSH, "pwsh not available")
class KillTimeout(unittest.TestCase):
    def test_hung_process_is_killed_and_result_is_negative_one(self):
        # HP_SMOKERUN_KILL_MS is a test-only override (production never sets it, so the real
        # 30000ms default -- unchanged from the prior inline implementation -- always applies);
        # this exercises the Kill() branch without a real 30s wait.
        with tempfile.TemporaryDirectory() as d:
            exe = _make_exe(d, "hang_exe", HANG_EXE)
            env = {"HP_SMOKERUN_EXE": str(exe), "HP_SMOKERUN_KILL_MS": "500"}
            proc = _run_smokerun(d, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "-1")
            # The pre-sleep output must still have been captured/teed before the kill.
            self.assertIn("about-to-hang", (Path(d) / "~run.out.txt").read_text(encoding="ascii"))
            self.assertIn("about-to-hang", proc.stdout)

    def test_default_kill_ms_unset_means_30000(self):
        # Confirms the env var is genuinely optional and the script's own default matches the
        # prior hardcoded 30s -- not a change in behavior when run_setup.bat doesn't set it.
        text = SOURCE.read_text(encoding="utf-8")
        self.assertIn("$killMs = 30000", text)


@unittest.skipUnless(PWSH, "pwsh not available")
class OutputPaths(unittest.TestCase):
    def test_caller_specified_output_and_result_paths(self):
        with tempfile.TemporaryDirectory() as d:
            exe = _make_exe(d, "fast_exe", FAST_EXE)
            out_path = Path(d) / "custom.out.txt"
            err_path = Path(d) / "custom.err.txt"
            result_path = Path(d) / "custom.result.txt"
            env = {
                "HP_SMOKERUN_EXE": str(exe),
                "HP_SMOKERUN_OUT": str(out_path),
                "HP_SMOKERUN_ERR": str(err_path),
                "HP_SMOKERUN_RESULT": str(result_path),
            }
            _run_smokerun(d, env)
            self.assertIn("fast-hello", out_path.read_text(encoding="ascii"))
            self.assertIn("fast-hello-err", err_path.read_text(encoding="ascii"))
            self.assertEqual(_result(d, env), "3")
            self.assertFalse((Path(d) / "~run.out.txt").exists())
            self.assertFalse((Path(d) / "~smokerun_result.txt").exists())


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        # derived requirement: tools/exe_smokerun.ps1 carries .gitattributes' `*.ps1 text
        # eol=crlf`, so a checkout on Windows CI materializes CRLF line endings regardless of
        # what the payload was encoded from -- normalize both sides before comparing so this
        # verifies content, not incidental checkout-time line-ending translation.
        bat = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_EXE_SMOKERUN=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_EXE_SMOKERUN payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).replace(b"\r\n", b"\n")
        source = SOURCE.read_bytes().replace(b"\r\n", b"\n")
        self.assertEqual(
            decoded, source,
            "HP_EXE_SMOKERUN base64 is out of sync with tools/exe_smokerun.ps1; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
