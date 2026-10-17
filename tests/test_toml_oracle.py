"""Oracle tests for the two hand-written TOML array readers (CLAUDE.md Item 79, slice 1).

tools/pyproj_deps.py (the fallback walker, used when the target interpreter has no tomllib) and
tools/pep723_extract.py (always a walker) each re-implement a small part of TOML. These tests treat
tomllib as the oracle: for a corpus of dependency arrays in the shapes real tools and people write,
the helpers must list exactly what tomllib reads, and for an array tomllib rejects they must refuse
it (exit 2 from pyproj_deps.py, exit 1 from pep723_extract.py) instead of installing a prefix of it.

The PEP 723 side is compared against tests/toml_oracle_check.py, which uses the regular expression
published in the PEP plus tomllib and shares no code with the helper under test.

Both helpers are flat sys.exit() scripts, so they run as subprocesses, like their own test files. The
pyproject fallback is reached by shadowing tomllib with a stub that raises ImportError.

Skipped when the interpreter running the tests has no tomllib (Python below 3.11): there is no oracle.
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

try:
    import tomllib
except ImportError:  # pragma: no cover - only on Python below 3.11
    tomllib = None

REPO = Path(__file__).resolve().parent.parent
PYPROJ = REPO / "tools" / "pyproj_deps.py"
PEP723 = REPO / "tools" / "pep723_extract.py"

# (name, TOML text of the array value). Raw strings keep the backslashes TOML sees.
VALID = [
    ("plain", r'["click", "requests>=2,<3"]'),
    ("multiline_trailing_comma", '[\n    "click",\n    "requests>=2,<3",\n]'),
    ("extras_and_specifiers", r'["pkg[all]>=1,<2", "rich[jupyter]~=13.0"]'),
    ("marker_escaped_double_quotes", r'["pywin32; sys_platform == \"win32\""]'),
    ("marker_in_literal_string", """['pywin32; sys_platform == "win32"']"""),
    ("marker_single_quotes_inside", """["colorama; python_version < '3.10'"]"""),
    ("escaped_backslash", r'["a\\b"]'),
    ("url_with_hash", r'["pkg @ https://example.com/pkg.zip#sha256=abc"]'),
    ("comment_after_item", '[\n    "click",  # a comment\n    "requests",\n]'),
    ("comment_with_bracket", '[\n    "requests",  # supports [1,2] syntax\n    "click",\n]'),
    ("comment_line_inside", '[\n    # the web stack first\n    "requests",\n]'),
    ("hash_inside_quotes", """["pkg; marker == 'a#b'"]"""),
    ("comment_after_array", '["click"]  # done'),
]

# Arrays tomllib rejects. Each must be refused, never read as a shorter list.
MALFORMED = [
    ("unclosed_at_end_of_file", '["requests",\n'),
    ("unclosed_before_next_table", '["requests",\n\n[tool.other]\nname = "x"\n'),
]

_SHADOW_DIR = None
_oracle = None


def setUpModule():
    global _SHADOW_DIR, _oracle
    _SHADOW_DIR = tempfile.mkdtemp(prefix="toml_oracle_shadow_")
    (Path(_SHADOW_DIR) / "tomllib.py").write_text(
        "raise ImportError('stub: tomllib intentionally unavailable for test')\n",
        encoding="ascii",
    )
    if tomllib is not None:
        spec = importlib.util.spec_from_file_location(
            "toml_oracle_check", REPO / "tests" / "toml_oracle_check.py")
        _oracle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_oracle)


def _pyproject_text(array_text, trailer=True):
    """A pyproject.toml whose [project].dependencies value is array_text."""
    text = '[project]\nname = "app"\ndependencies = ' + array_text
    if not text.endswith("\n"):
        text += "\n"
    if trailer:
        text += '\n[project.optional-dependencies]\ndev = ["pytest"]\n\n[tool.other]\ndependencies = ["not-this"]\n'
    return text


def _run_pyproj(text, no_tomllib, newline="\n"):
    """Run pyproj_deps.py on a pyproject.toml holding text; return (returncode, lines or None)."""
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "pyproject.toml").write_bytes(text.replace("\n", newline).encode("utf-8"))
        env = dict(os.environ)
        if no_tomllib:
            env["PYTHONPATH"] = _SHADOW_DIR + os.pathsep + env.get("PYTHONPATH", "")
        proc = subprocess.run([sys.executable, str(PYPROJ), "out.txt"], cwd=d,
                              capture_output=True, text=True, env=env)
        out = Path(d) / "out.txt"
        lines = out.read_text(encoding="ascii").splitlines() if out.exists() else None
        return proc.returncode, lines


def _script_text(array_text):
    """A script whose PEP 723 block holds `dependencies = <array_text>`."""
    toml = "dependencies = " + array_text
    if not toml.endswith("\n"):
        toml += "\n"
    body = "".join(("# " + ln if ln else "#") + "\n" for ln in toml.splitlines())
    return "# /// script\n" + body + "# ///\nprint('x')\n"


def _run_pep723(script, newline="\n"):
    """Run pep723_extract.py on script; return (returncode, lines or None)."""
    with tempfile.TemporaryDirectory() as d:
        entry = Path(d) / "entry.py"
        entry.write_bytes(script.replace("\n", newline).encode("utf-8"))
        out = Path(d) / "out.txt"
        proc = subprocess.run([sys.executable, str(PEP723), str(entry), str(out)],
                              capture_output=True, text=True)
        lines = out.read_text(encoding="ascii").splitlines() if out.exists() else None
        return proc.returncode, lines


@unittest.skipIf(tomllib is None, "no tomllib: nothing to use as the oracle")
class CorpusSanity(unittest.TestCase):
    """The corpus itself: valid entries parse, malformed entries are rejected by tomllib."""

    def test_valid_entries_parse_and_are_not_empty(self):
        for name, array_text in VALID:
            with self.subTest(name):
                deps = tomllib.loads(_pyproject_text(array_text))["project"]["dependencies"]
                self.assertTrue(deps)
                self.assertEqual(_oracle.reference_deps(_script_text(array_text)), deps)

    def test_malformed_entries_are_rejected_by_tomllib(self):
        for name, array_text in MALFORMED:
            with self.subTest(name):
                with self.assertRaises(tomllib.TOMLDecodeError):
                    tomllib.loads(_pyproject_text(array_text, trailer=False))


@unittest.skipIf(tomllib is None, "no tomllib: nothing to use as the oracle")
class PyprojectDepsMatchesTomllib(unittest.TestCase):
    def _expect(self, array_text):
        return tomllib.loads(_pyproject_text(array_text))["project"]["dependencies"]

    def test_tomllib_path_matches_oracle(self):
        for name, array_text in VALID:
            with self.subTest(name):
                rc, lines = _run_pyproj(_pyproject_text(array_text), no_tomllib=False)
                self.assertEqual(rc, 0)
                self.assertEqual(lines, self._expect(array_text))

    def test_fallback_walker_matches_oracle(self):
        for name, array_text in VALID:
            with self.subTest(name):
                rc, lines = _run_pyproj(_pyproject_text(array_text), no_tomllib=True)
                self.assertEqual(rc, 0)
                self.assertEqual(lines, self._expect(array_text))

    def test_fallback_walker_matches_oracle_with_crlf(self):
        for name, array_text in VALID:
            with self.subTest(name):
                rc, lines = _run_pyproj(_pyproject_text(array_text), no_tomllib=True, newline="\r\n")
                self.assertEqual(rc, 0)
                self.assertEqual(lines, self._expect(array_text))

    def test_tomllib_path_refuses_malformed_array(self):
        for name, array_text in MALFORMED:
            with self.subTest(name):
                rc, lines = _run_pyproj(_pyproject_text(array_text, trailer=False), no_tomllib=False)
                self.assertEqual(rc, 2)
                self.assertIsNone(lines)

    def test_fallback_walker_refuses_malformed_array(self):
        # Exit 2 is the caller's "pyproject.toml is not valid TOML" warning; reading a prefix of the
        # array (exit 0) would install a partial dependency list without a word.
        for name, array_text in MALFORMED:
            with self.subTest(name):
                rc, lines = _run_pyproj(_pyproject_text(array_text, trailer=False), no_tomllib=True)
                self.assertEqual(rc, 2)
                self.assertIsNone(lines)


@unittest.skipIf(tomllib is None, "no tomllib: nothing to use as the oracle")
class Pep723ExtractMatchesReference(unittest.TestCase):
    def test_matches_reference_reader(self):
        for name, array_text in VALID:
            with self.subTest(name):
                script = _script_text(array_text)
                rc, lines = _run_pep723(script)
                self.assertEqual(rc, 0)
                self.assertEqual(lines, _oracle.reference_deps(script))

    def test_matches_reference_reader_with_crlf(self):
        for name, array_text in VALID:
            with self.subTest(name):
                script = _script_text(array_text)
                rc, lines = _run_pep723(script, newline="\r\n")
                self.assertEqual(rc, 0)
                self.assertEqual(lines, _oracle.reference_deps(script))

    def test_refuses_malformed_array(self):
        for name, array_text in MALFORMED:
            with self.subTest(name):
                script = _script_text(array_text)
                with self.assertRaises(tomllib.TOMLDecodeError):
                    _oracle.reference_deps(script)
                rc, lines = _run_pep723(script)
                self.assertEqual(rc, 1)
                self.assertIsNone(lines)


if __name__ == "__main__":
    unittest.main()
