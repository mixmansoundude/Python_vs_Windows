"""Tests for tools/exe_smokerun.ps1 -- the dedicated helper for :run_exe_smokerun (the sole,
timed, kill-after-30s verification pass for a freshly-built EXE that has never been confirmed
working). Split out of an inline `-Command "..."` one-liner into an emitted .ps1 file as part of
docs/plan-cli-interactive-verification.md's requirement 1: Register-ObjectEvent's -Action
scriptblock needs literal-quote-containing PowerShell an inline -Command string cannot safely
hold, and the caller no longer wraps this script's invocation in a for /f stdout capture (see
tools/failfast_probe.ps1's sibling test module docstring for the full for /f-capture-vs-tee
conflict this also applies to).

No importable functions exist -- exercised end-to-end via a real `pwsh` subprocess.

derived requirement: HP_SMOKERUN_EXE is invoked directly with no separate Arguments field
(matching the frozen EXE's own invocation shape), so the fake "exe" must be a genuinely,
directly-executable file under `UseShellExecute = $false` -- a POSIX shebang script (chmod +x)
works on Linux but is NOT executable on Windows this way, and a .bat/.cmd launcher does not work
either (confirmed against Microsoft's own ProcessStartInfo.UseShellExecute guidance: with
UseShellExecute=false, Process.Start becomes a direct CreateProcess call, which can only launch
genuine executables, not scripts needing a command interpreter). First draft of this test file
used the shebang/chmod approach and failed on every real Windows CI lane
(FileNotFoundError-equivalent: the "exe" simply never started, so nothing was captured) --
confirmed and root-caused via real CI logs, not just reasoned about.

Fix: use `sys.executable` itself (a real, directly-executable binary on every platform) as
HP_SMOKERUN_EXE, and feed it the actual Python logic via its INHERITED stdin instead of a CLI
argument -- `exe_smokerun.ps1` never sets RedirectStandardInput on the grandchild, so it inherits
whatever stdin the pwsh process itself has, and subprocess.run's own `stdin=` parameter can point
that at an open script file. `python` invoked with zero arguments and a non-tty stdin reads and
executes exactly that stdin stream as its program (documented CPython CLI behavior, confirmed
directly: `python3 < script.py` runs `script.py`) -- this reproduces through the full pwsh ->
grandchild chain identically on Windows and Linux, with no shebang/chmod/.bat trickery, and no
change to exe_smokerun.ps1 itself.

Covers: normal fast exit (result file + captured output), the Kill()-after-timeout path for a
genuinely SILENT hang (via the HP_SMOKERUN_KILL_MS test-only override -- production always uses
the unset default, 30000ms), the activity-aware "stop" path added 2026-07-24 (Open Question 1,
owner decision) where a process that has produced ANY output before the deadline is never killed
even if it keeps running well past HP_SMOKERUN_KILL_MS -- see the script's own header comment and
docs/agent-interconnect.md "Activity-aware EXE-smoke kill" for the full rationale -- caller
output-path overrides, and the base64 HP_EXE_SMOKERUN payload sync (byte-equality vs this source,
CRLF/LF-normalized, mirroring the .ps1 PayloadSync convention used across this repo -- see
docs/agent-lessons-learned.md "Embedded Helper Update Workflow").
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
SOURCE = REPO / "tools" / "exe_smokerun.ps1"
PWSH = shutil.which("pwsh")

FAST_SCRIPT = """
import sys
print("fast-hello")
print("fast-hello-err", file=sys.stderr)
sys.exit(3)
"""

ARGV_ECHO_SCRIPT = """
import sys
print("ARGV:" + "|".join(sys.argv[1:]))
"""

HANG_SILENT_SCRIPT = """
import time
time.sleep(120)
"""

OUTPUT_THEN_LONG_SCRIPT = """
import sys, time
print("prompt-shown", flush=True)
time.sleep(0.8)
print("after-hang", flush=True)
sys.exit(7)
"""

# Regression script for Finding 9 (docs/plan-cli-interactive-verification.md): writes WITHOUT a
# trailing newline (mirroring input("prompt")'s own no-newline-by-design behavior) and flushes,
# then sleeps well past a short kill window before ever completing a line. Under the old
# ReadLineAsync()-based reader, $sawOutput would stay false until the LATER bare print() finally
# terminates the line -- by which point a short kill window would already have fired. Under the
# chunk-based reader, the initial unterminated write is itself enough to set $sawOutput.
NO_NEWLINE_THEN_LONG_SCRIPT = """
import sys, time
sys.stdout.write("partial-no-newline-prompt")
sys.stdout.flush()
time.sleep(0.8)
print()
print("after-hang", flush=True)
sys.exit(9)
"""


def _make_script(d, name, body):
    path = Path(d) / (name + ".py")
    path.write_text(body, encoding="utf-8")
    return path


def _run_smokerun(d, script, env_extra, timeout=15):
    # Mirrors :run_exe_smokerun's own `pushd dist` convention (REQ-018 2b-A.2): default output
    # paths are `..\~run.out.txt` / `..\~run.err.txt`, relative to a dist\ subdirectory -- so the
    # default-path tests run with cwd=d/dist to land the defaults at d/~run.out.txt etc.
    dist = Path(d) / "dist"
    dist.mkdir(exist_ok=True)
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin", "HP_SMOKERUN_EXE": sys.executable}
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
            script = _make_script(d, "fast", FAST_SCRIPT)
            env = {}
            proc = _run_smokerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "3")
            self.assertIn("fast-hello", (Path(d) / "~run.out.txt").read_text(encoding="ascii"))
            self.assertIn("fast-hello-err", (Path(d) / "~run.err.txt").read_text(encoding="ascii"))

    def test_live_tee_reaches_own_stdout_stderr(self):
        # docs/plan-cli-interactive-verification.md Finding 5b/6: the whole point of converting
        # this to an emitted helper with event-driven reads is that a real user watching the
        # console sees the child's own output live, not only captured to disk after exit.
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            proc = _run_smokerun(d, script, {})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("fast-hello", proc.stdout)
            self.assertIn("fast-hello-err", proc.stderr)


@unittest.skipUnless(PWSH, "pwsh not available")
class KillTimeout(unittest.TestCase):
    def test_silent_hang_is_killed_and_result_is_negative_one(self):
        # HP_SMOKERUN_KILL_MS is a test-only override (production never sets it, so the real
        # 30000ms default -- unchanged -- always applies). A process that has produced ZERO
        # output by the deadline is the case this cap still exists to catch (Open Question 1's
        # activity-aware "stop" behavior below only applies once output has been observed).
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "hang", HANG_SILENT_SCRIPT)
            env = {"HP_SMOKERUN_KILL_MS": "500"}
            proc = _run_smokerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "-1")

    def test_default_kill_ms_unset_means_30000(self):
        # Confirms the env var is genuinely optional and the script's own default matches the
        # prior hardcoded 30s -- not a change in behavior when run_setup.bat doesn't set it.
        text = SOURCE.read_text(encoding="utf-8")
        self.assertIn("$killMs = 30000", text)


@unittest.skipUnless(PWSH, "pwsh not available")
class ActivityAwareStop(unittest.TestCase):
    def test_output_before_deadline_prevents_kill_even_past_deadline(self):
        # docs/plan-cli-interactive-verification.md Open Question 1 (owner decision 2026-07-24):
        # once ANY output has been observed before HP_SMOKERUN_KILL_MS elapses, the kill is
        # skipped entirely and the wait becomes unbounded -- proxy for "likely at an interactive
        # prompt" per Python's own input() flush-before-block behavior. This script deliberately
        # prints, then runs well PAST a short kill window, then exits on its own with a real,
        # distinguishable exit code (7) -- proving it was never force-stopped.
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "outlonghang", OUTPUT_THEN_LONG_SCRIPT)
            env = {"HP_SMOKERUN_KILL_MS": "300"}
            proc = _run_smokerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "7")
            out_text = (Path(d) / "~run.out.txt").read_text(encoding="ascii")
            self.assertIn("prompt-shown", out_text)
            self.assertIn("after-hang", out_text)
            self.assertIn("prompt-shown", proc.stdout)
            self.assertIn("after-hang", proc.stdout)

    def test_output_with_no_trailing_newline_still_prevents_kill(self):
        # Regression test for Finding 9: a chunk with NO trailing newline (the exact shape of
        # input("prompt")'s own output) must still set $sawOutput immediately -- not only once a
        # LATER newline happens to terminate the line. Confirmed this test fails against the
        # pre-Finding-9 ReadLineAsync()-based implementation (the process gets killed, result
        # "-1") and passes against the chunk-based fix (result "9", the script's real exit code).
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "nonewlinehang", NO_NEWLINE_THEN_LONG_SCRIPT)
            env = {"HP_SMOKERUN_KILL_MS": "300"}
            proc = _run_smokerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "9")
            out_text = (Path(d) / "~run.out.txt").read_text(encoding="ascii")
            self.assertIn("partial-no-newline-prompt", out_text)
            self.assertIn("after-hang", out_text)


@unittest.skipUnless(PWSH, "pwsh not available")
class ArgvPassthrough(unittest.TestCase):
    # [REQ-026] argv passthrough (docs/plan-cli-interactive-verification.md P1): HP_SMOKERUN_ARGS,
    # if set, is used verbatim as $si.Arguments -- the EXE is self-contained, so no separate
    # entry-file argv is needed here (unlike tools/failfast_probe.ps1's interpreter call sites).
    # This harness's own stand-in "EXE" is `sys.executable` fed the actual program via inherited
    # stdin (see the module docstring for why -- a real frozen EXE needs no such trick, but a bare
    # `python` with zero positional args and non-tty stdin can't ALSO accept extra CLI args, since
    # it has no script-path slot to attach them after). Fixed by using CPython's own `python -
    # arg1 arg2` form (a literal `-` as the script name means "read the program from stdin," with
    # every argument AFTER it becoming sys.argv[1:] for that program) -- confirmed directly
    # (`python3 - --foo "bar baz" < script.py` prints ARGV:--foo|bar baz) before relying on it.
    def test_extra_args_forwarded_as_separate_argv(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "argv", ARGV_ECHO_SCRIPT)
            env = {"HP_SMOKERUN_ARGS": '"-" "--foo" "bar baz"'}
            proc = _run_smokerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "0")
            out = (Path(d) / "~run.out.txt").read_text(encoding="utf-8")
            self.assertIn("ARGV:--foo|bar baz", out)

    def test_unset_means_no_arguments(self):
        # HP_SMOKERUN_ARGS unset (production's default when the user passed no extra args) must
        # not set $si.Arguments at all -- exercised via the plain FAST_SCRIPT invocation every
        # other test in this file already uses, confirming this new code path is a true no-op
        # when there is nothing to forward.
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            env = {}
            proc = _run_smokerun(d, script, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "3")


@unittest.skipUnless(PWSH, "pwsh not available")
class OutputPaths(unittest.TestCase):
    def test_caller_specified_output_and_result_paths(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            out_path = Path(d) / "custom.out.txt"
            err_path = Path(d) / "custom.err.txt"
            result_path = Path(d) / "custom.result.txt"
            env = {
                "HP_SMOKERUN_OUT": str(out_path),
                "HP_SMOKERUN_ERR": str(err_path),
                "HP_SMOKERUN_RESULT": str(result_path),
            }
            _run_smokerun(d, script, env)
            self.assertIn("fast-hello", out_path.read_text(encoding="ascii"))
            self.assertIn("fast-hello-err", err_path.read_text(encoding="ascii"))
            self.assertEqual(_result(d, env), "3")
            self.assertFalse((Path(d) / "~run.out.txt").exists())
            self.assertFalse((Path(d) / "~smokerun_result.txt").exists())


@unittest.skipUnless(PWSH, "pwsh not available")
class ProcessIdMessage(unittest.TestCase):
    # A user with no cached EXE watching a genuinely stuck verification run has no clean way to
    # get back to the bootstrapper -- Ctrl+C broadcasts to the whole console process group
    # (killing the bootstrapper too), and past the probe window this file only Kill()s on a
    # fully-silent timeout, never once real output has appeared. Printing the real Windows PID
    # lets a stuck user End Task it via Task Manager's Details tab -- a precise, single-process
    # kill, unlike Ctrl+C.
    def test_pid_message_printed_with_real_numeric_pid(self):
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            proc = _run_smokerun(d, script, {})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            m = re.search(r"\[INFO\] Process ID (\d+)\.", proc.stdout)
            self.assertIsNotNone(m, "PID message not found in stdout: " + proc.stdout)
            self.assertGreater(int(m.group(1)), 0)
            self.assertIn("Task Manager", proc.stdout)
            self.assertIn("End Task", proc.stdout)

    def test_pid_message_never_lands_in_captured_output_file(self):
        # The PID line is bootstrapper-generated console guidance, not part of the user's own
        # program output -- it must never contaminate ~run.out.txt (the file downstream checks
        # read as "what did the user's program print").
        with tempfile.TemporaryDirectory() as d:
            script = _make_script(d, "fast", FAST_SCRIPT)
            proc = _run_smokerun(d, script, {})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            captured = (Path(d) / "~run.out.txt").read_text(encoding="ascii")
            self.assertNotIn("Process ID", captured)


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
