"""Tests for tools/dll_pct_sanitize.ps1 -- the emitted-.ps1 replacement for the DLL-bundling
loop's HP_DLL_DETECTED_SAFE / HP_NEXT_DLL_SAFE / HP_NEXT_DLL_PATH_SAFE display sanitization
(CLAUDE.md Item 24). The old inline `-Command` version of this logic went through THREE separate
real-CI-confirmed bugs, all rooted in the same cause: literal `%` text sitting on a cmd.exe-parsed
line. See docs/agent-lessons-learned.md's ":log echoes UNQUOTED" entry for the full trace. This
file is a real emitted .ps1 (invoked via `-File`, never `-Command`), so cmd.exe's own tokenizer
never sees its body at all -- only the outer `-File "path" arg...` invocation is cmd.exe-parsed,
and that's plain argv (env var names, output paths) with no %-pairing hazard.

No importable functions exist -- exercised end-to-end via a real `pwsh` subprocess, mirroring
tests/test_exe_hint_rerun.py's own harness.
"""
import base64
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "dll_pct_sanitize.ps1"
PWSH = shutil.which("pwsh")


def _run_sanitize(env_extra, args, cwd):
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin"}
    env.update(env_extra)
    return subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE)] + args,
        cwd=str(cwd),
        env=env,
        capture_output=True,
        text=True,
        timeout=15,
    )


@unittest.skipUnless(PWSH, "pwsh not available")
class BasicSanitize(unittest.TestCase):
    def test_percent_and_caret_replaced(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "out.txt"
            proc = _run_sanitize(
                {"HP_TEST_VAL": "prefix%SECRET%suffix^caretend"},
                ["HP_TEST_VAL", str(out)],
                d,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(out.read_text(encoding="ascii"), "prefix_SECRET_suffix_caretend")

    def test_ampersand_pipe_lt_gt_left_untouched(self):
        # These are the caller's job (plain cmd.exe :search=replace substitution before this
        # helper runs) -- this script only ever handles %/^, per its own docstring contract.
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "out.txt"
            proc = _run_sanitize(
                {"HP_TEST_VAL": "a&b|c<d>e"},
                ["HP_TEST_VAL", str(out)],
                d,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(out.read_text(encoding="ascii"), "a&b|c<d>e")

    def test_no_trailing_newline(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "out.txt"
            proc = _run_sanitize({"HP_TEST_VAL": "plain"}, ["HP_TEST_VAL", str(out)], d)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            raw = out.read_bytes()
            self.assertEqual(raw, b"plain", "output must have no trailing newline (read back via a plain for /f)")

    def test_undefined_var_writes_empty_file_not_error(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "out.txt"
            proc = _run_sanitize({}, ["HP_TEST_VAL_NEVER_SET", str(out)], d)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(out.read_text(encoding="ascii"), "")


@unittest.skipUnless(PWSH, "pwsh not available")
class MultiVar(unittest.TestCase):
    def test_two_pairs_in_one_invocation(self):
        # Mirrors run_setup.bat's HP_NEXT_DLL_SAFE/HP_NEXT_DLL_PATH_SAFE call site: two
        # (envVarName, outFile) pairs handled by one process, one shared $pct across both.
        with tempfile.TemporaryDirectory() as d:
            out_a = Path(d) / "a.txt"
            out_b = Path(d) / "b.txt"
            proc = _run_sanitize(
                {"HP_A": "100%done", "HP_B": r"C:\envs\foo^bar\Library\bin"},
                ["HP_A", str(out_a), "HP_B", str(out_b)],
                d,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(out_a.read_text(encoding="ascii"), "100_done")
            self.assertEqual(out_b.read_text(encoding="ascii"), r"C:\envs\foo_bar\Library\bin")


@unittest.skipUnless(PWSH, "pwsh not available")
class SecondExpansionSafety(unittest.TestCase):
    def test_sanitized_value_survives_call_based_second_expansion(self):
        # The actual security property this sanitizer exists for (see
        # docs/agent-lessons-learned.md's "call triggers a second expansion pass" entry): a raw
        # value shaped like "%SECRET%" must not leak the real SECRET variable's value once it
        # has been through this sanitizer and is later substituted into a `call :label "..."`
        # line, which cmd.exe re-scans a second time. Exercised end-to-end via a real cmd.exe
        # child process, not static reasoning -- this exact code path got that reasoning wrong
        # twice before landing on this file (docs/agent-interconnect.md's DLL-bundling section).
        with tempfile.TemporaryDirectory() as d:
            fixture = Path(d) / "verify.cmd"
            out = Path(d) / "out.txt"
            fixture.write_text(
                "\r\n".join(
                    [
                        "@echo off",
                        "setlocal DisableDelayedExpansion",
                        "set \"SECRET=must-not-appear\"",
                        "set \"HP_DLL_DETECTED_SAFE=prefix%%SECRET%%suffix^caretend\"",
                        'powershell -NoProfile -ExecutionPolicy Bypass -File "{script}" HP_DLL_DETECTED_SAFE "{out}" > nul 2>&1'.format(
                            script=SOURCE, out=out
                        ),
                        'set "SAFE="',
                        'for /f "usebackq delims=" %%X in ("{out}") do set "SAFE=%%X"'.format(out=out),
                        'call :log "%SAFE%"',
                        "exit /b",
                        ":log",
                        "echo %~1",
                        "",
                    ]
                ),
                encoding="ascii",
            )
            cmd_exe = shutil.which("cmd.exe") or shutil.which("cmd")
            if not cmd_exe:
                self.skipTest("cmd.exe not available (non-Windows sandbox)")
            proc = subprocess.run([cmd_exe, "/d", "/v:off", "/c", str(fixture)], capture_output=True, text=True, timeout=15)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "prefix_SECRET_suffix_caretend")
            self.assertNotIn("must-not-appear", proc.stdout)


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        # See tests/test_exe_hint_rerun.py's own PayloadSync test for why CRLF/LF normalization
        # is required here (`*.ps1 text eol=crlf` in .gitattributes).
        bat = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_DLL_PCT_SANITIZE=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_DLL_PCT_SANITIZE payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).replace(b"\r\n", b"\n")
        source = SOURCE.read_bytes().replace(b"\r\n", b"\n")
        self.assertEqual(
            decoded, source,
            "HP_DLL_PCT_SANITIZE base64 is out of sync with tools/dll_pct_sanitize.ps1; re-sync it.",
        )


if __name__ == "__main__":
    unittest.main()
