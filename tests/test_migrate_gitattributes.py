"""Tests for tools/migrate_gitattributes.ps1 -- CLAUDE.md Item 60's fix for a pre-existing
.gitattributes still carrying the disproven "*.bat eol=crlf"/"*.cmd eol=crlf" rule (written by
an older copy of this bootstrapper, before the eol=crlf -> -text fix landed for item 59). The
existing :merge_git_config idempotency guard gates on a shared signature comment line, so a
user who already ran an older run_setup.bat has that signature present and a newer copy skips
the whole append block -- the stale rule was never migrated. This script replaces ONLY lines
that exactly match one of the two known-stale strings, in place; every other line (including
any user hand-edits elsewhere in the file) passes through byte-identical. See
docs/agent-lessons-learned.md's ".bat files: -text, not eol=crlf" entry for why -text is
correct and eol=crlf is not.

No importable functions exist -- exercised end-to-end via a real `pwsh` subprocess, mirroring
tests/test_dll_pct_sanitize.py's own harness.
"""
import base64
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "migrate_gitattributes.ps1"
PWSH = shutil.which("pwsh")


def _run_migrate(path):
    return subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SOURCE), "-Path", str(path)],
        capture_output=True,
        text=True,
        timeout=15,
    )


@unittest.skipUnless(PWSH, "pwsh not available")
class BasicMigration(unittest.TestCase):
    def test_both_stale_lines_replaced_other_content_untouched(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_text(
                "# some user content\n"
                "*.md text\n"
                "# Automated Python Bootstrapper Attributes\n"
                "*.bat eol=crlf\n"
                "*.cmd eol=crlf\n"
                "*.exe binary\n",
                encoding="ascii",
            )
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            lines = path.read_text(encoding="ascii").splitlines()
            self.assertEqual(
                lines,
                [
                    "# some user content",
                    "*.md text",
                    "# Automated Python Bootstrapper Attributes",
                    "*.bat -text",
                    "*.cmd -text",
                    "*.exe binary",
                ],
            )

    def test_asymmetric_only_bat_stale(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_text("*.bat eol=crlf\n*.exe binary\n", encoding="ascii")
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            self.assertEqual(
                path.read_text(encoding="ascii").splitlines(),
                ["*.bat -text", "*.exe binary"],
            )

    def test_no_stale_lines_is_noop_and_file_untouched(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            original = "*.bat -text\n*.cmd -text\n*.exe binary\n"
            path.write_text(original, encoding="ascii")
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "NOOP:no-stale-lines")
            self.assertEqual(path.read_text(encoding="ascii"), original)

    def test_idempotent_second_run_after_migration(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_text("*.bat eol=crlf\n*.cmd eol=crlf\n", encoding="ascii")
            first = _run_migrate(path)
            self.assertEqual(first.stdout.strip(), "MIGRATED")
            second = _run_migrate(path)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(second.stdout.strip(), "NOOP:no-stale-lines")

    def test_missing_file_is_noop(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "does_not_exist"
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "NOOP:missing")

    def test_partial_line_match_not_touched(self):
        # A line that CONTAINS the stale text but isn't an EXACT match (extra trailing text,
        # different whitespace) must not be rewritten -- exact-match-only is the safety
        # property that protects a user's own hand-edited content.
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            original = "*.bat eol=crlf text\n"
            path.write_text(original, encoding="ascii")
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "NOOP:no-stale-lines")
            self.assertEqual(path.read_text(encoding="ascii"), original)


@unittest.skipUnless(PWSH, "pwsh not available")
class LineEndingAndEncodingPreservation(unittest.TestCase):
    # derived requirement (CodeRabbit review, PR #455): an earlier version used
    # ReadAllLines/WriteAllLines, which strips every line's own terminator and reimposes a
    # single uniform one (Environment.NewLine -- CRLF on real Windows) on write. That would
    # have silently converted an LF-only .gitattributes' ENTIRE content to CRLF even though
    # only two lines were ever meant to change -- invisible when tested only under Linux
    # pwsh, where Environment.NewLine is LF, so these cases specifically exercise the
    # property a same-platform test alone could never have caught.

    def test_lf_only_file_stays_lf(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_bytes(b"# user\n*.md text\n*.bat eol=crlf\n*.cmd eol=crlf\n*.exe binary\n")
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            self.assertEqual(
                path.read_bytes(),
                b"# user\n*.md text\n*.bat -text\n*.cmd -text\n*.exe binary\n",
            )

    def test_crlf_only_file_stays_crlf(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_bytes(
                b"# user\r\n*.md text\r\n*.bat eol=crlf\r\n*.cmd eol=crlf\r\n*.exe binary\r\n"
            )
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            self.assertEqual(
                path.read_bytes(),
                b"# user\r\n*.md text\r\n*.bat -text\r\n*.cmd -text\r\n*.exe binary\r\n",
            )

    def test_mixed_line_endings_each_terminator_preserved_independently(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_bytes(
                b"# user\r\n*.md text\n*.bat eol=crlf\r\n*.cmd eol=crlf\n*.exe binary\r\n"
            )
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            self.assertEqual(
                path.read_bytes(),
                b"# user\r\n*.md text\n*.bat -text\r\n*.cmd -text\n*.exe binary\r\n",
            )

    def test_no_trailing_newline_last_line_stale(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_bytes(b"# user\n*.bat eol=crlf")
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            self.assertEqual(path.read_bytes(), b"# user\n*.bat -text")

    def test_stale_line_is_first_line_no_preceding_terminator(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_bytes(b"*.bat eol=crlf\n*.exe binary\n")
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            self.assertEqual(path.read_bytes(), b"*.bat -text\n*.exe binary\n")

    def test_utf8_bom_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_bytes(b"\xef\xbb\xbf# user\n*.bat eol=crlf\n*.cmd eol=crlf\n")
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            result = path.read_bytes()
            self.assertTrue(result.startswith(b"\xef\xbb\xbf"), "BOM was stripped")
            self.assertEqual(result, b"\xef\xbb\xbf# user\n*.bat -text\n*.cmd -text\n")

    def test_bom_immediately_precedes_stale_rule_as_first_line(self):
        # derived requirement (CodeRabbit review, PR #455): a stale rule as the file's
        # genuine FIRST line, with a BOM immediately preceding it (no comment/other line in
        # between) -- the exact shape a plain \A-only left boundary could in principle miss if
        # StreamReader's own well-established BOM-stripping-on-read behavior ever didn't hold.
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_bytes(b"\xef\xbb\xbf*.bat eol=crlf\n*.cmd eol=crlf\n")
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            self.assertEqual(path.read_bytes(), b"\xef\xbb\xbf*.bat -text\n*.cmd -text\n")

    def test_no_bom_originally_no_bom_added(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / ".gitattributes"
            path.write_bytes(b"*.bat eol=crlf\n")
            proc = _run_migrate(path)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "MIGRATED")
            result = path.read_bytes()
            self.assertFalse(result.startswith(b"\xef\xbb\xbf"), "a BOM was added where none existed")
            self.assertEqual(result, b"*.bat -text\n")


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        # See tests/test_exe_hint_rerun.py's own PayloadSync test for why CRLF/LF normalization
        # is required here (`*.ps1 text eol=crlf` in .gitattributes).
        bat = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_MIGRATE_GITATTRIBUTES=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_MIGRATE_GITATTRIBUTES payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).replace(b"\r\n", b"\n")
        source = SOURCE.read_bytes().replace(b"\r\n", b"\n")
        self.assertEqual(
            decoded, source,
            "HP_MIGRATE_GITATTRIBUTES base64 is out of sync with tools/migrate_gitattributes.ps1; "
            "re-sync it.",
        )


if __name__ == "__main__":
    unittest.main()
