"""Tests for tools/autopep_merge.py (HP_AUTOPEP_MERGE) -- Tier 1 of
docs/plan-autopep723-two-tier.md. Merges the dependency names discovered by
`uvx autopep723 check <entry>` into requirements.txt, additively.

extract_autopep_deps/existing_names/ensure_trailing_newline are called directly with an
explicit path argument. main() reads its two paths from argv, so it is exercised via
subprocess with a crafted temp directory -- mirrors tests/test_dep_check.py's pattern for
main()-level run/skip decisions.

Covers: PEP-723-style dependency-array extraction (including the no-dependencies-key and
malformed/error-output cases), name-collision dedup against existing requirements.txt content
(case-insensitive), missing-file handling for both inputs, trailing-newline repair before
append, and the base64 HP_AUTOPEP_MERGE payload sync (byte-equality of the embedded payload
vs this source -- mirrors PyprojDeps/DetectVisa/DepCheck PayloadSync).
"""
import base64
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "autopep_merge.py"

sys.path.insert(0, str(REPO / "tools"))
import autopep_merge  # noqa: E402


def _run_main(cwd, args=None):
    cmd = [sys.executable, str(SOURCE)] + (args or [])
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


class ExtractAutopepDeps(unittest.TestCase):
    def test_real_autopep723_style_output(self, tmp_write=None):
        p = self._write(
            "# /// script\n"
            '# requires-python = ">=3.13"\n'
            "# dependencies = [\n"
            '#     "click",\n'
            '#     "requests",\n'
            "# ]\n"
            "# ///\n"
        )
        self.assertEqual(autopep_merge.extract_autopep_deps(str(p)), ["click", "requests"])

    def test_no_dependencies_key_present(self):
        p = self._write("# /// script\n# requires-python = \">=3.13\"\n# ///\n")
        self.assertEqual(autopep_merge.extract_autopep_deps(str(p)), [])

    def test_error_output_no_pep723_block(self):
        p = self._write("Error: Script 'missing.py' does not exist.\n")
        self.assertEqual(autopep_merge.extract_autopep_deps(str(p)), [])

    def test_missing_file_returns_empty(self):
        self.assertEqual(autopep_merge.extract_autopep_deps("/nonexistent/path.txt"), [])

    def test_empty_file_returns_empty(self):
        p = self._write("")
        self.assertEqual(autopep_merge.extract_autopep_deps(str(p)), [])

    def _write(self, text):
        import tempfile
        d = Path(tempfile.mkdtemp(prefix="autopep_merge_extract_"))
        p = d / "requirements.autopep.txt"
        p.write_text(text, encoding="utf-8")
        return p


class ExistingNames(unittest.TestCase):
    def test_parses_bare_and_specced_names_lowercased(self):
        import tempfile
        d = Path(tempfile.mkdtemp(prefix="autopep_merge_existing_"))
        p = d / "requirements.txt"
        p.write_text("Flask\nrequests>=2.0\n# comment\n\nNumPy==1.2\n", encoding="utf-8")
        self.assertEqual(autopep_merge.existing_names(str(p)), {"flask", "requests", "numpy"})

    def test_missing_file_returns_empty_set(self):
        self.assertEqual(autopep_merge.existing_names("/nonexistent/requirements.txt"), set())


class EnsureTrailingNewline(unittest.TestCase):
    def test_adds_newline_when_missing(self):
        import tempfile
        d = Path(tempfile.mkdtemp(prefix="autopep_merge_nl_"))
        p = d / "requirements.txt"
        p.write_bytes(b"flask")
        autopep_merge.ensure_trailing_newline(str(p))
        self.assertEqual(p.read_bytes(), b"flask\n")

    def test_no_op_when_already_present(self):
        import tempfile
        d = Path(tempfile.mkdtemp(prefix="autopep_merge_nl2_"))
        p = d / "requirements.txt"
        p.write_bytes(b"flask\n")
        autopep_merge.ensure_trailing_newline(str(p))
        self.assertEqual(p.read_bytes(), b"flask\n")

    def test_no_op_when_file_missing(self):
        # Must not raise.
        autopep_merge.ensure_trailing_newline("/nonexistent/requirements.txt")

    def test_no_op_when_file_empty(self):
        import tempfile
        d = Path(tempfile.mkdtemp(prefix="autopep_merge_nl3_"))
        p = d / "requirements.txt"
        p.write_bytes(b"")
        autopep_merge.ensure_trailing_newline(str(p))
        self.assertEqual(p.read_bytes(), b"")


class MainDispatch(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.cwd = Path(tempfile.mkdtemp(prefix="autopep_merge_main_"))

    def test_union_adds_new_names_preserves_existing(self):
        (self.cwd / "requirements.autopep.txt").write_text(
            '# dependencies = [\n#     "click",\n#     "requests",\n# ]\n', encoding="utf-8"
        )
        (self.cwd / "requirements.txt").write_text("requests>=2.0\n", encoding="utf-8")
        rc, out, err = _run_main(self.cwd)
        self.assertEqual(rc, 0)
        self.assertIn("added", out)
        content = (self.cwd / "requirements.txt").read_text(encoding="utf-8")
        self.assertEqual(content, "requests>=2.0\nclick\n")

    def test_creates_requirements_txt_when_absent(self):
        (self.cwd / "requirements.autopep.txt").write_text(
            '# dependencies = [\n#     "numpy",\n# ]\n', encoding="utf-8"
        )
        rc, out, err = _run_main(self.cwd)
        self.assertEqual(rc, 0)
        self.assertEqual((self.cwd / "requirements.txt").read_text(encoding="utf-8"), "numpy\n")

    def test_noop_when_no_deps_discovered(self):
        (self.cwd / "requirements.autopep.txt").write_text(
            '# requires-python = ">=3.13"\n', encoding="utf-8"
        )
        (self.cwd / "requirements.txt").write_text("flask\n", encoding="utf-8")
        rc, out, err = _run_main(self.cwd)
        self.assertEqual(rc, 0)
        self.assertIn("no-op", out)
        self.assertEqual((self.cwd / "requirements.txt").read_text(encoding="utf-8"), "flask\n")

    def test_noop_when_autopep_file_missing(self):
        (self.cwd / "requirements.txt").write_text("flask\n", encoding="utf-8")
        rc, out, err = _run_main(self.cwd)
        self.assertEqual(rc, 0)
        self.assertIn("no-op", out)
        self.assertEqual((self.cwd / "requirements.txt").read_text(encoding="utf-8"), "flask\n")

    def test_all_deps_already_present_is_noop(self):
        (self.cwd / "requirements.autopep.txt").write_text(
            '# dependencies = [\n#     "flask",\n# ]\n', encoding="utf-8"
        )
        (self.cwd / "requirements.txt").write_text("Flask\n", encoding="utf-8")
        rc, out, err = _run_main(self.cwd)
        self.assertEqual(rc, 0)
        self.assertIn("no-op", out)
        self.assertEqual((self.cwd / "requirements.txt").read_text(encoding="utf-8"), "Flask\n")

    def test_custom_paths_via_argv(self):
        (self.cwd / "custom_autopep.txt").write_text(
            '# dependencies = [\n#     "click",\n# ]\n', encoding="utf-8"
        )
        (self.cwd / "custom_reqs.txt").write_text("", encoding="utf-8")
        rc, out, err = _run_main(self.cwd, ["custom_autopep.txt", "custom_reqs.txt"])
        self.assertEqual(rc, 0)
        self.assertEqual((self.cwd / "custom_reqs.txt").read_text(encoding="utf-8"), "click\n")


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_AUTOPEP_MERGE=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_AUTOPEP_MERGE payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_AUTOPEP_MERGE base64 is out of sync with tools/autopep_merge.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
