"""Tests for tools/fast_check.ps1 -- CLAUDE.md Active Backlog Item 39's fix for the EXE fast
path's freshness check. Previously mtime-only over *.py files: (a) a timestamp-preserving
delivery method (a ZIP, xcopy, robocopy) could carry a genuinely changed file whose mtime
still predates the built EXE, silently reusing stale logic with no signal to the user, and
(b) a requirements.txt/pyproject.toml/runtime.txt change was invisible to the scan entirely.
Fixed by switching to a content-hash comparison (never fooled by a preserved/backdated
mtime) over the same *.py file set, extended to include those three dependency files.

No importable functions exist -- exercised end-to-end via a real `pwsh` subprocess, mirroring
tests/test_migrate_gitattributes.py's own harness.
"""
import base64
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "fast_check.ps1"
PWSH = shutil.which("pwsh")


def _run_check(cwd, exe="dist/myapp.exe", mode="check"):
    result = subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE), exe, mode],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result.returncode, result.stdout.strip(), result.stderr


@unittest.skipUnless(PWSH, "pwsh not available")
class FreshnessBehavior(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = Path(self.tmp)
        (self.root / "dist").mkdir()
        (self.root / "dist" / "myapp.exe").write_text("fake-exe")
        (self.root / "entry.py").write_text("print('hello')\n")
        (self.root / "requirements.txt").write_text("requests==2.0\n")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_check_with_no_stored_hash_is_not_fresh(self):
        rc, out, err = _run_check(self.root)
        self.assertNotEqual(out, "fresh", err)

    def test_write_then_check_is_fresh(self):
        _run_check(self.root, mode="write")
        self.assertTrue((self.root / "~fast_check.hash.txt").exists())
        rc, out, err = _run_check(self.root)
        self.assertEqual(out, "fresh", err)

    def test_content_change_with_backdated_mtime_is_not_fresh(self):
        # The core Item 39 regression case: a ZIP/xcopy/robocopy delivery can carry a
        # genuinely changed file whose mtime is preserved from BEFORE the build -- the old
        # mtime-only check would have wrongly reported "fresh" here.
        _run_check(self.root, mode="write")
        entry = self.root / "entry.py"
        entry.write_text("print('changed')\n")
        old = 1000000000  # 2001-09-09, far before dist/myapp.exe's own mtime
        import os
        os.utime(entry, (old, old))
        rc, out, err = _run_check(self.root)
        self.assertNotEqual(out, "fresh", err)

    def test_dependency_file_only_change_is_not_fresh(self):
        # requirements.txt is not a *.py file -- the old mtime scan never looked at it at
        # all, so this change (Item 39's exposure (b)) was previously invisible regardless
        # of mtime.
        _run_check(self.root, mode="write")
        (self.root / "requirements.txt").write_text("requests==3.0\n")
        rc, out, err = _run_check(self.root)
        self.assertNotEqual(out, "fresh", err)

    def test_rewrite_after_change_is_fresh_again(self):
        _run_check(self.root, mode="write")
        (self.root / "entry.py").write_text("print('changed')\n")
        _run_check(self.root, mode="write")
        rc, out, err = _run_check(self.root)
        self.assertEqual(out, "fresh", err)

    def test_missing_exe_is_not_fresh(self):
        _run_check(self.root, mode="write")
        (self.root / "dist" / "myapp.exe").unlink()
        rc, out, err = _run_check(self.root)
        self.assertNotEqual(out, "fresh", err)


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        # See tests/test_migrate_gitattributes.py's own PayloadSync test for why CRLF/LF
        # normalization is required here (`*.ps1 text eol=crlf` in .gitattributes).
        bat = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_FAST_CHECK=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_FAST_CHECK payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).replace(b"\r\n", b"\n")
        source = SOURCE.read_bytes().replace(b"\r\n", b"\n")
        self.assertEqual(
            decoded, source,
            "HP_FAST_CHECK base64 is out of sync with tools/fast_check.ps1; re-sync it.",
        )


if __name__ == "__main__":
    unittest.main()
