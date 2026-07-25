"""Tests for tools/sync_payload.py -- the safe embedded-HP_*-payload swap tool.

Formalizes the manual "read as bytes, build candidate in memory, diff to
confirm exactly one line changed, only then write" procedure documented in
docs/agent-lessons-learned.md (see the "Never open a real source file in
Python 'w' mode as part of a 'dry run'" entry for the near-miss that
motivated it). These tests exercise the tool against synthetic .bat files
only -- never the real run_setup.bat -- so a bug here can't touch the repo's
actual deliverable.
"""
import base64
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOL = REPO / "tools" / "sync_payload.py"


def _run(args):
    proc = subprocess.run(
        [sys.executable, str(TOOL)] + args,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


class SyncPayload(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.dir = Path(self.tmpdir.name)

        self.source = self.dir / "helper.py"
        self.source.write_text("print('hello')\n", encoding="ascii")

        self.batch = self.dir / "sample.bat"
        correct_b64 = base64.b64encode(self.source.read_bytes()).decode("ascii")
        self.batch.write_bytes(
            b"@echo off\r\n"
            b'set "HP_OTHER=abc123"\r\n'
            + f'set "HP_HELPER={correct_b64}"\r\n'.encode("ascii")
            + b"echo done\r\n"
        )
        self.correct_b64 = correct_b64

    def test_check_reports_in_sync(self):
        rc, out, _ = _run(["HP_HELPER", str(self.source), "--batch", str(self.batch), "--check"])
        self.assertEqual(rc, 0)
        self.assertIn("already in sync", out)
        # --check must never write.
        self.assertIn(self.correct_b64, self.batch.read_text())

    def test_check_reports_out_of_sync_without_writing(self):
        self.batch.write_bytes(
            self.batch.read_bytes().replace(
                self.correct_b64.encode("ascii"), b"stale_b64_value"
            ),
        )
        rc, out, _ = _run(["HP_HELPER", str(self.source), "--batch", str(self.batch), "--check"])
        self.assertEqual(rc, 1)
        self.assertIn("OUT OF SYNC", out)
        # --check must never write -- the stale value must still be there.
        self.assertIn("stale_b64_value", self.batch.read_text())

    def test_write_fixes_drift_and_touches_only_target_line(self):
        self.batch.write_bytes(
            self.batch.read_bytes().replace(
                self.correct_b64.encode("ascii"), b"stale_b64_value"
            ),
        )
        corrupted_lines = self.batch.read_bytes().split(b"\n")

        rc, out, _ = _run(["HP_HELPER", str(self.source), "--batch", str(self.batch)])
        self.assertEqual(rc, 0)
        self.assertIn("synced", out)

        new_lines = self.batch.read_bytes().split(b"\n")
        self.assertEqual(len(new_lines), len(corrupted_lines))
        changed = [i for i in range(len(corrupted_lines)) if corrupted_lines[i] != new_lines[i]]
        self.assertEqual(changed, [2], "only the HP_HELPER line (index 2) should differ")
        self.assertIn(self.correct_b64.encode("ascii"), new_lines[2])

    def test_write_preserves_crlf_line_ending(self):
        self.batch.write_bytes(
            self.batch.read_bytes().replace(
                self.correct_b64.encode("ascii"), b"stale_b64_value"
            ),
        )
        _run(["HP_HELPER", str(self.source), "--batch", str(self.batch)])
        target_line = [
            line for line in self.batch.read_bytes().split(b"\n")
            if line.startswith(b'set "HP_HELPER=')
        ][0]
        self.assertTrue(target_line.endswith(b"\r"), "CRLF ending must be preserved")

    def test_missing_variable_exits_2(self):
        rc, _, err = _run(["HP_NOT_PRESENT", str(self.source), "--batch", str(self.batch)])
        self.assertEqual(rc, 2)
        self.assertIn("no line starting with", err)

    def test_duplicate_variable_exits_2(self):
        self.batch.write_bytes(self.batch.read_bytes() + b'set "HP_HELPER=dup"\r\n')
        rc, _, err = _run(["HP_HELPER", str(self.source), "--batch", str(self.batch)])
        self.assertEqual(rc, 2)
        self.assertIn("expected exactly 1", err)

    def test_missing_batch_file_exits_2(self):
        rc, _, err = _run(["HP_HELPER", str(self.source), "--batch", str(self.dir / "nope.bat")])
        self.assertEqual(rc, 2)
        self.assertIn("not found", err)

    def test_missing_source_file_exits_2(self):
        rc, _, err = _run(["HP_HELPER", str(self.dir / "nope.py"), "--batch", str(self.batch)])
        self.assertEqual(rc, 2)
        self.assertIn("not found", err)

    def test_over_budget_refused_without_force(self):
        big_source = self.dir / "big.py"
        # base64 expands ~4/3; comfortably exceed the 8191-char line budget.
        big_source.write_text("x = 1  # " + ("a" * 7000) + "\n", encoding="ascii")
        rc, _, err = _run(["HP_HELPER", str(big_source), "--batch", str(self.batch)])
        self.assertEqual(rc, 1)
        self.assertIn("8191-char limit", err)
        # Refused write must leave the original payload untouched.
        self.assertIn(self.correct_b64, self.batch.read_text())

    def test_over_budget_written_with_force(self):
        big_source = self.dir / "big.py"
        big_source.write_text("x = 1  # " + ("a" * 7000) + "\n", encoding="ascii")
        rc, out, _ = _run(["HP_HELPER", str(big_source), "--batch", str(self.batch), "--force"])
        self.assertEqual(rc, 0)
        self.assertIn("synced", out)


if __name__ == "__main__":
    unittest.main()
