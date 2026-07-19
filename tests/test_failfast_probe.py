"""Tests for tools/failfast_probe.ps1 -- the REQ-018 Slice 2b-C fail-fast probe that launches
the caller's program, classifies it as "exited fast" (probe window crossed before the process
finished -> discard-and-rebuild candidate) vs. "still running" (the user's real, possibly
long-running program -- never touched again, no Kill() anywhere), and captures stdout/stderr to
caller-specified files.

No importable functions exist (the script reads its inputs from env vars and prints a single
"$exceeded|$exitcode" line to stdout) -- this is exercised end-to-end via a real `pwsh`
subprocess, mirroring tests/test_pyproj_deps.py's subprocess-based pattern for a flat script.

Covers the fast-exit / probe-window-exceeded classification, exit-code passthrough in both
cases, default vs. caller-specified output-path behavior, stdout/stderr capture content, and the
base64 HP_FAILFAST_PROBE payload sync (byte-equality of the embedded payload vs this source,
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


def _run_probe(d, env_extra, timeout=15):
    env = {
        "PATH": "/usr/bin:/bin:/usr/local/bin",
        "HP_FAILFAST_PROBE_MS": "300",
    }
    env.update(env_extra)
    proc = subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE)],
        cwd=d,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc


@unittest.skipUnless(PWSH, "pwsh not available")
class FastExitClassification(unittest.TestCase):
    def test_fast_exit_zero_not_exceeded(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "fast.py"
            script.write_text(FAST_SCRIPT, encoding="utf-8")
            proc = _run_probe(d, {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            })
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "0|0")

    def test_fast_exit_nonzero_passthrough(self):
        # derived requirement: HP_PROBE_ARGS is a SINGLE path argument only (the script's own
        # header comment: $si.Arguments = '"' + $rawArgs + '"' wraps the whole string as one
        # quoted token) -- the nonzero exit code is baked into the script itself rather than
        # passed as a second CLI token, since a second token would be swallowed into the same
        # quoted argument as the path and misparsed as part of the filename.
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "fast_nonzero.py"
            script.write_text(FAST_NONZERO_SCRIPT, encoding="utf-8")
            proc = _run_probe(d, {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            })
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "0|5")


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
            proc = _run_probe(d, {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": "{} 5".format(script),
                "HP_PROBE_CWD": d,
            })
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "0|2")


@unittest.skipUnless(PWSH, "pwsh not available")
class SlowExitClassification(unittest.TestCase):
    def test_probe_window_exceeded_but_final_rc_captured(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "slow.py"
            script.write_text(SLOW_SCRIPT, encoding="utf-8")
            proc = _run_probe(d, {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            })
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "1|7")


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
            _run_probe(d, {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
                "HP_PROBE_OUT": str(out_path),
                "HP_PROBE_ERR": str(err_path),
            })
            self.assertIn("hello-stdout", out_path.read_text(encoding="ascii"))
            self.assertIn("hello-stderr", err_path.read_text(encoding="ascii"))
            self.assertFalse((Path(d) / "~run.out.txt").exists())

    def test_single_argument_path_with_spaces_quoted_correctly(self):
        with tempfile.TemporaryDirectory() as d:
            subdir = Path(d) / "dir with spaces"
            subdir.mkdir()
            script = subdir / "fast.py"
            script.write_text(FAST_SCRIPT, encoding="utf-8")
            proc = _run_probe(d, {
                "HP_PROBE_EXE": sys.executable,
                "HP_PROBE_ARGS": str(script),
                "HP_PROBE_CWD": d,
            })
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "0|0")


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
