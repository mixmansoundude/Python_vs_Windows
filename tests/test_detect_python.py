"""Tests for tools/detect_python.py -- REQ-004 Tier 1/2 requires-python
detection (runtime.txt / pyproject.toml precedence) and the PEP 440 ->
conda-syntax translator (pep440_to_conda), including the "~=" compatible-
release expansion conda has no native equivalent for.

Covers the same pep440_to_conda cases already exercised by
tests/dynamic_tests.py's dp.pep440 rows (kept in sync for consistency, not
duplicated logic), plus the multi-tier detect_requires_python() precedence,
missing-file and malformed-content edge cases, and the base64 HP_DETECT_PY
payload sync (byte-equality of the embedded payload vs this source -- mirrors
CollectSubmodules/HiddenImportScan PayloadSync).
"""
import base64
import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import detect_python
from tools.detect_python import pep440_to_conda, detect_requires_python

try:
    import tomllib
except ImportError:  # Python below 3.11: the TOML-scoped tests below have nothing to compare with
    tomllib = None

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "detect_python.py"


class Pep440ToConda(unittest.TestCase):
    # Same cases as tests/dynamic_tests.py's dp.pep440 rows -- keep in sync.
    def test_compatible_release_three_part(self):
        self.assertEqual(pep440_to_conda("~=3.10"), "python>=3.10,<4.0")

    def test_compatible_release_with_patch(self):
        self.assertEqual(pep440_to_conda("~=3.8.1"), "python>=3.8.1,<3.9")

    def test_range(self):
        self.assertEqual(pep440_to_conda(">=3.9,<3.11"), "python>=3.9,<3.11")

    def test_exact_pin(self):
        self.assertEqual(pep440_to_conda("==3.11"), "python==3.11")

    def test_inclusive_range(self):
        self.assertEqual(pep440_to_conda(">=3.8,<=3.12"), "python>=3.8,<=3.12")

    def test_upper_bound_only(self):
        self.assertEqual(pep440_to_conda("<3.13"), "python<3.13")

    def test_single_digit_compatible_release(self):
        # bump_for_compatible with only one dotted component: "~=3" -> "4".
        self.assertEqual(pep440_to_conda("~=3"), "python>=3,<4")

    def test_empty_spec_returns_empty_string(self):
        self.assertEqual(pep440_to_conda(""), "")

    def test_unmatched_clause_ignored(self):
        # A clause the regex cannot parse is silently dropped, not an error.
        self.assertEqual(pep440_to_conda("garbage-not-a-spec"), "")

    def test_duplicate_clauses_deduplicated(self):
        self.assertEqual(pep440_to_conda(">=3.9,>=3.9"), "python>=3.9")

    def test_whitespace_around_commas_tolerated(self):
        self.assertEqual(pep440_to_conda(">=3.9, <3.11"), "python>=3.9,<3.11")


class DetectRequiresPython(unittest.TestCase):
    """detect_requires_python()'s multi-tier precedence: runtime.txt wins
    over pyproject.toml when both exist (REQ-004 Tier 1 before Tier 2)."""

    def _write(self, path: Path, text: str):
        path.write_text(text, encoding="ascii")

    def test_no_files_returns_empty_string(self):
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d) / "runtime.txt"
            pyproject = Path(d) / "pyproject.toml"
            with patch.object(detect_python, "RUNTIME_PATH", str(runtime)), \
                 patch.object(detect_python, "PYPROJECT_PATH", str(pyproject)):
                self.assertEqual(detect_requires_python(), "")

    def test_runtime_txt_wins_over_pyproject(self):
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d) / "runtime.txt"
            pyproject = Path(d) / "pyproject.toml"
            self._write(runtime, "python-3.10.5\n")
            self._write(pyproject, '[project]\nrequires-python = "~=3.11"\n')
            with patch.object(detect_python, "RUNTIME_PATH", str(runtime)), \
                 patch.object(detect_python, "PYPROJECT_PATH", str(pyproject)):
                self.assertEqual(detect_requires_python(), "python=3.10")

    def test_pyproject_alone_is_used(self):
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d) / "runtime.txt"
            pyproject = Path(d) / "pyproject.toml"
            self._write(pyproject, '[project]\nrequires-python = ">=3.11"\n')
            with patch.object(detect_python, "RUNTIME_PATH", str(runtime)), \
                 patch.object(detect_python, "PYPROJECT_PATH", str(pyproject)):
                self.assertEqual(detect_requires_python(), "python>=3.11")

    def test_runtime_txt_bare_version_no_prefix(self):
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d) / "runtime.txt"
            pyproject = Path(d) / "pyproject.toml"
            self._write(runtime, "3.12\n")
            with patch.object(detect_python, "RUNTIME_PATH", str(runtime)), \
                 patch.object(detect_python, "PYPROJECT_PATH", str(pyproject)):
                self.assertEqual(detect_requires_python(), "python=3.12")

    def test_runtime_txt_patch_component_truncated(self):
        # Providers pin by minor only -- a patch version in runtime.txt is
        # accepted but not forwarded.
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d) / "runtime.txt"
            pyproject = Path(d) / "pyproject.toml"
            self._write(runtime, "python-3.11.9\n")
            with patch.object(detect_python, "RUNTIME_PATH", str(runtime)), \
                 patch.object(detect_python, "PYPROJECT_PATH", str(pyproject)):
                self.assertEqual(detect_requires_python(), "python=3.11")

    def test_runtime_txt_unparseable_falls_through_to_pyproject(self):
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d) / "runtime.txt"
            pyproject = Path(d) / "pyproject.toml"
            self._write(runtime, "not a version at all\n")
            self._write(pyproject, '[project]\nrequires-python = ">=3.9"\n')
            with patch.object(detect_python, "RUNTIME_PATH", str(runtime)), \
                 patch.object(detect_python, "PYPROJECT_PATH", str(pyproject)):
                self.assertEqual(detect_requires_python(), "python>=3.9")

    def test_pyproject_missing_requires_python_key(self):
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d) / "runtime.txt"
            pyproject = Path(d) / "pyproject.toml"
            self._write(pyproject, "[project]\nname = \"app\"\n")
            with patch.object(detect_python, "RUNTIME_PATH", str(runtime)), \
                 patch.object(detect_python, "PYPROJECT_PATH", str(pyproject)):
                self.assertEqual(detect_requires_python(), "")

    def test_pyproject_requires_python_double_vs_single_quotes(self):
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d) / "runtime.txt"
            pyproject = Path(d) / "pyproject.toml"
            self._write(pyproject, "[project]\nrequires-python = '>=3.10'\n")
            with patch.object(detect_python, "RUNTIME_PATH", str(runtime)), \
                 patch.object(detect_python, "PYPROJECT_PATH", str(pyproject)):
                self.assertEqual(detect_requires_python(), "python>=3.10")


def _spec(text, tomllib_missing=False, raw=None):
    """Run detect_requires_python() on a pyproject.toml holding text (or the raw bytes)."""
    with tempfile.TemporaryDirectory() as d:
        runtime = Path(d) / "runtime.txt"
        pyproject = Path(d) / "pyproject.toml"
        pyproject.write_bytes(raw if raw is not None else text.encode("utf-8"))
        patches = [patch.object(detect_python, "RUNTIME_PATH", str(runtime)),
                   patch.object(detect_python, "PYPROJECT_PATH", str(pyproject))]
        if tomllib_missing:
            patches.append(patch.object(detect_python, "tomllib", None, create=True))
        for p in patches:
            p.start()
        try:
            return detect_requires_python()
        finally:
            for p in reversed(patches):
                p.stop()


@unittest.skipIf(tomllib is None, "no tomllib in the test interpreter")
class RequiresPythonTomlScope(unittest.TestCase):
    """CLAUDE.md Item 79 slice 3: requires-python is read as TOML (the [project] table only, comments
    ignored), not found by a regular expression over the whole file."""

    def test_commented_out_line_is_ignored(self):
        self.assertEqual(_spec('[project]\nname = "app"\n# requires-python = ">=3.8,<3.9"\n'), "")

    def test_real_key_wins_over_an_earlier_commented_out_line(self):
        self.assertEqual(
            _spec('[project]\n# requires-python = ">=3.8,<3.9"\nrequires-python = ">=3.10"\n'),
            "python>=3.10")

    def test_key_under_another_table_is_ignored(self):
        self.assertEqual(_spec('[project]\nname = "app"\n\n[tool.other]\nrequires-python = ">=3.8"\n'), "")

    def test_key_under_another_table_before_project_is_ignored(self):
        self.assertEqual(
            _spec('[tool.other]\nrequires-python = ">=3.8"\n\n[project]\nrequires-python = ">=3.10"\n'),
            "python>=3.10")

    def test_triple_quoted_value(self):
        self.assertEqual(_spec('[project]\nrequires-python = """>=3.10"""\n'), "python>=3.10")

    def test_literal_string_with_trailing_comment(self):
        self.assertEqual(_spec("[project]\nrequires-python = '>=3.10'  # needs match\n"), "python>=3.10")

    def test_dotted_key_form(self):
        self.assertEqual(_spec('project.requires-python = ">=3.10"\n'), "python>=3.10")

    def test_not_a_string_is_ignored(self):
        self.assertEqual(_spec("[project]\nrequires-python = 3.10\n"), "")

    def test_byte_order_mark_does_not_hide_the_real_key(self):
        raw = b'\xef\xbb\xbf[project]\n# requires-python = ">=3.8,<3.9"\nrequires-python = ">=3.10"\n'
        self.assertEqual(_spec("", raw=raw), "python>=3.10")


class RequiresPythonPatternFallback(unittest.TestCase):
    """The pattern read stays for a file tomllib cannot parse and for an interpreter without tomllib, so
    a hand-edited pyproject.toml with one stray character, or an older Python, still gets its version."""

    def test_unparseable_toml_still_uses_the_pattern(self):
        # Today's behaviour, kept: one broken line elsewhere must not cost the Python version.
        self.assertEqual(_spec('[project]\nrequires-python = ">=3.10"\nname = "unterminated\n'),
                         "python>=3.10")

    def test_missing_tomllib_still_uses_the_pattern(self):
        self.assertEqual(_spec('[project]\nrequires-python = ">=3.10"\n', tomllib_missing=True),
                         "python>=3.10")


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_DETECT_PY=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_DETECT_PY payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_DETECT_PY base64 is out of sync with tools/detect_python.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
