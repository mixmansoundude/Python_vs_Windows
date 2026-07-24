"""Tests for tools/failfast_probe.ps1 -- the REQ-018 Slice 2b-C fail-fast probe that launches
the caller's program, classifies it as "exited fast" (probe window crossed before the process
finished -> discard-and-rebuild candidate) vs. "still running" (the user's real, possibly
long-running program -- never touched again, no Kill() anywhere), and captures stdout/stderr to
caller-specified files.

No importable functions exist (the script reads its inputs from env vars) -- this is exercised
end-to-end via a real `pwsh` subprocess, mirroring tests/test_pyproj_deps.py's subprocess-based
pattern for a flat script.

Per docs/plan-cli-interactive-verification.md Finding 6, the script now live-echoes the child's
stdout/stderr to its own stdout/stderr AS IT ARRIVES (instead of only writing captured output to
disk after exit) and writes its "$exceeded|$exitcode" classification result to a dedicated result
file (HP_PROBE_RESULT, default ~probe_result.txt) instead of printing it as the final stdout line
-- the caller no longer wraps this script in a `for /f` stdout-capture, which would otherwise
swallow the live-teed lines and corrupt the result parsing. Tests read the result file, not
`proc.stdout`, for the classification outcome; `proc.stdout`/`proc.stderr` are asserted to contain
the live-teed child output instead.

Covers the fast-exit / probe-window-exceeded classification, exit-code passthrough in both
cases, default vs. caller-specified output-path behavior, stdout/stderr capture content (both the
live-teed process output and the ~run.out.txt/~run.err.txt file capture), and the base64
HP_FAILFAST_PROBE payload sync (byte-equality of the embedded payload vs this source,
CRLF/LF-normalized -- mirrors test_embed_tier.py's PayloadSync pattern for a .ps1 canonical
source, since *.ps1 carries `.gitattributes`' `eol=crlf`).
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
SOURCE = REPO / "tools" / "failfast_probe.ps1"
PWSH = shutil.which("pwsh")

FAST_SCRIPT = """
import sys
sys.exit(0)
"""

FAST_NONZERO_SCRIPT = """
import sys
sys.exit(5)
"""

SLOW_SCRIPT = """
import sys
import time
print("hello-stdout")
print("hello-stderr", file=sys.stderr)
time.sleep(1.5)
sys.exit(7)
"""

# The owner's actual target program shape for this repo: no launch arguments, asks setup
# questions via input(), loops on stdin until a quit command. HP_PROBE_ARGS points at this file
# on disk (not stdin -- see test_exe_smokerun.py's module docstring for why a script fed via
# stdin can't also read its own input() calls from that same, already-consumed stream), so
# stdin stays completely free for the script's own prompts.
INTERACTIVE_SCRIPT = """
name = input("Enter your name: ")
print("Hello, " + name + "!")
while True:
    cmd = input("Type 'ping' or 'exit': ")
    if cmd == "exit":
        print("Goodbye!")
        break
    elif cmd == "ping":
        print("pong")
    else:
        print("unknown command: " + cmd)
"""


def _run_probe(d, env_extra, timeout=15, stdin=None):
    env = {
        "PATH": "/usr/bin:/bin:/usr/local/bin",
        "HP_FAILFAST_PROBE_MS": "300",
    }
    env.update(env_extra)
    proc = subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE)],
        cwd=d,
        env=env,
        stdin=stdin,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc


def _result(d, env_extra):
    # HP_PROBE_RESULT defaults to ~probe_result.txt in the cwd; honor a caller override the same
    # way the script does, so callers testing a custom path can still retrieve it.
    override = env_extra.get("HP_PROBE_RESULT")
    result_path = Path(override) if override else (Path(d) / "~probe_result.txt")
    return result_path.read_text(encoding="ascii").strip()


@unittest.skipUnless(PWSH, "pwsh not available")
class FastExitClassification(unittest.TestCase):
    def test_fast_exit_zero_not_exceeded(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "fast.py"
            script.write_text(FAST_SCRIPT, encoding="utf-8")
            env = {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            }
            proc = _run_probe(d, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "0|0")

    def test_fast_exit_nonzero_passthrough(self):
        # derived requirement: HP_PROBE_ARGS is a SINGLE path argument only (the script's own
        # header comment: $si.Arguments = '"' + $rawArgs + '"' wraps the whole string as one
        # quoted token) -- the nonzero exit code is baked into the script itself rather than
        # passed as a second CLI token, since a second token would be swallowed into the same
        # quoted argument as the path and misparsed as part of the filename.
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "fast_nonzero.py"
            script.write_text(FAST_NONZERO_SCRIPT, encoding="utf-8")
            env = {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            }
            proc = _run_probe(d, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "0|5")


@unittest.skipUnless(PWSH, "pwsh not available")
class ArgsIsSingleArgumentOnly(unittest.TestCase):
    def test_multi_token_args_misparsed_as_one_argument(self):
        # Documents, rather than silently works around, the constraint in the script's own
        # header comment: HP_PROBE_ARGS must be a single path, never a multi-token command
        # line. Passing "<path> 5" here is NOT two arguments -- it is wrapped whole in quotes
        # and handed to python3 as one literal (nonexistent) filename, which python3 reports
        # as exit code 2 ("can't open file"), not as sys.argv[1]=="5".
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "fast.py"
            script.write_text(FAST_SCRIPT, encoding="utf-8")
            env = {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": "{} 5".format(script),
                "HP_PROBE_CWD": d,
            }
            proc = _run_probe(d, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "0|2")


@unittest.skipUnless(PWSH, "pwsh not available")
class SlowExitClassification(unittest.TestCase):
    def test_probe_window_exceeded_but_final_rc_captured(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "slow.py"
            script.write_text(SLOW_SCRIPT, encoding="utf-8")
            env = {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            }
            proc = _run_probe(d, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "1|7")


@unittest.skipUnless(PWSH, "pwsh not available")
class LiveTee(unittest.TestCase):
    def test_child_output_reaches_scripts_own_stdout_stderr_live(self):
        # docs/plan-cli-interactive-verification.md Finding 5b/6: the whole point of this
        # requirement is that a real user watching the console sees the child's prompts as they
        # happen, not only after it exits. This can't assert *timing* through a captured
        # subprocess.run() call the way the sandbox pwsh repro did, but it can assert the
        # mechanism used (Register-ObjectEvent + Write-Host/[Console]::Error.WriteLine) actually
        # lands the child's own stdout/stderr on this script's own stdout/stderr at all -- the
        # previous ReadToEndAsync()-only design never wrote anything to its own stdout/stderr.
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "slow.py"
            script.write_text(SLOW_SCRIPT, encoding="utf-8")
            proc = _run_probe(d, {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            })
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("hello-stdout", proc.stdout)
            self.assertIn("hello-stderr", proc.stderr)


@unittest.skipUnless(PWSH, "pwsh not available")
class InteractiveRoundTrip(unittest.TestCase):
    # Answers the actual question this repo's live-echo work exists to answer: not just "is
    # output visible," but "can a real multi-round input()-driven program be watched AND
    # answered through this exact mechanism." RedirectStandardInput is never set on the
    # grandchild in failfast_probe.ps1, so it inherits whatever stdin this pwsh process itself
    # has -- subprocess.run's own stdin= parameter points that at a file containing only the
    # ANSWERS (never the script source; see INTERACTIVE_SCRIPT's own comment for why those two
    # must stay on separate channels). This does not prove a live human's typing timing (that
    # needs a real Windows double-click, still open -- see
    # docs/plan-cli-interactive-verification.md requirement 2), but it does prove the mechanism
    # (Register-ObjectEvent tee + inherited/piped stdin together, not one or the other in
    # isolation) carries a genuine multi-round conversation correctly end to end.
    def test_multi_round_input_conversation_completes_correctly(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "interactive.py"
            script.write_text(INTERACTIVE_SCRIPT, encoding="utf-8")
            answers = Path(d) / "answers.txt"
            answers.write_text("Alice\nping\nexit\n", encoding="utf-8")
            with open(answers, "r", encoding="utf-8") as stdin_src:
                proc = _run_probe(d, {
                    "HP_PROBE_EXE": sys.executable,
                    "HP_PROBE_ARGS": str(script),
                    "HP_PROBE_CWD": d,
                }, stdin=stdin_src)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            # Ordering, not just presence: proves each answer was consumed by the RIGHT prompt,
            # not just that all expected substrings happen to appear somewhere in the output.
            out = proc.stdout
            i1 = out.index("Enter your name:")
            i2 = out.index("Hello, Alice!")
            i3 = out.index("Type 'ping' or 'exit':")
            i4 = out.index("pong")
            i5 = out.index("Goodbye!")
            self.assertLess(i1, i2)
            self.assertLess(i2, i3)
            self.assertLess(i3, i4)
            self.assertLess(i4, i5)
            # Same round trip landed in the captured file, not just the live-teed console stream.
            captured = (Path(d) / "~run.out.txt").read_text(encoding="ascii")
            self.assertIn("Hello, Alice!", captured)
            self.assertIn("pong", captured)
            self.assertIn("Goodbye!", captured)


@unittest.skipUnless(PWSH, "pwsh not available")
class OutputCapture(unittest.TestCase):
    def test_default_output_paths_used_when_unset(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "fast.py"
            script.write_text(FAST_SCRIPT, encoding="utf-8")
            _run_probe(d, {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            })
            self.assertTrue((Path(d) / "~run.out.txt").exists())
            self.assertTrue((Path(d) / "~run.err.txt").exists())

    def test_caller_specified_output_paths_and_content(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "slow.py"
            script.write_text(SLOW_SCRIPT, encoding="utf-8")
            out_path = Path(d) / "custom.out.txt"
            err_path = Path(d) / "custom.err.txt"
            result_path = Path(d) / "custom.result.txt"
            _run_probe(d, {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
                "HP_PROBE_OUT": str(out_path),
                "HP_PROBE_ERR": str(err_path),
                "HP_PROBE_RESULT": str(result_path),
            })
            self.assertIn("hello-stdout", out_path.read_text(encoding="ascii"))
            self.assertIn("hello-stderr", err_path.read_text(encoding="ascii"))
            self.assertEqual(result_path.read_text(encoding="ascii").strip(), "1|7")
            self.assertFalse((Path(d) / "~run.out.txt").exists())
            self.assertFalse((Path(d) / "~probe_result.txt").exists())

    def test_single_argument_path_with_spaces_quoted_correctly(self):
        with tempfile.TemporaryDirectory() as d:
            subdir = Path(d) / "dir with spaces"
            subdir.mkdir()
            script = subdir / "fast.py"
            script.write_text(FAST_SCRIPT, encoding="utf-8")
            env = {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            }
            proc = _run_probe(d, env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(_result(d, env), "0|0")


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        # derived requirement: tools/failfast_probe.ps1 carries .gitattributes' `*.ps1 text
        # eol=crlf`, so a checkout on Windows CI materializes CRLF line endings regardless of
        # what the payload was encoded from -- normalize both sides before comparing so this
        # verifies content, not incidental checkout-time line-ending translation.
        bat = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_FAILFAST_PROBE=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_FAILFAST_PROBE payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).replace(b"\r\n", b"\n")
        source = SOURCE.read_bytes().replace(b"\r\n", b"\n")
        self.assertEqual(
            decoded, source,
            "HP_FAILFAST_PROBE base64 is out of sync with tools/failfast_probe.ps1; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
