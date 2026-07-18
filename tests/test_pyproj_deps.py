"""Tests for tools/pyproj_deps.py -- extracts [project].dependencies from
pyproject.toml (tomllib preferred, regex fallback when unavailable or when
the key is absent from tomllib's own parse).

The script is a flat, top-level sys.exit()-based script (matching its
embedded-payload form exactly, no importable functions), so it is exercised
via subprocess -- mirrors tests/test_find_entry.py's subprocess pattern.
The regex-fallback path is exercised by shadowing "tomllib" with a stub
module (via PYTHONPATH) that raises ImportError on import, reproducing the
script's own `try: import tomllib / except ImportError: tomllib = None`
without needing an actual pre-3.11 interpreter.

Covers exit codes (0 success / 1 not-found-or-empty / 2 malformed TOML),
the char-by-char dependency-array walk (extras, multi-constraint specifiers),
a custom output path, and the base64 HP_PYPROJ_DEPS payload sync (byte-
equality of the embedded payload vs this source -- mirrors
CollectSubmodules/HiddenImportScan/DetectPython PayloadSync).
"""
import base64
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "pyproj_deps.py"

# A stub "tomllib" module that raises ImportError on import, placed on
# PYTHONPATH ahead of the real stdlib path so it shadows the genuine
# tomllib -- reproduces the script's own tomllib-unavailable branch.
_SHADOW_DIR = None


def setUpModule():
    global _SHADOW_DIR
    _SHADOW_DIR = tempfile.mkdtemp(prefix="pyproj_deps_shadow_")
    (Path(_SHADOW_DIR) / "tomllib.py").write_text(
        "raise ImportError('stub: tomllib intentionally unavailable for test')\n",
        encoding="ascii",
    )


def _run(cwd, args=None, no_tomllib=False):
    """Run pyproj_deps.py with cwd as the working directory; return (returncode, stdout, stderr)."""
    cmd = [sys.executable, str(SOURCE)] + (args or [])
    env = dict(os.environ)
    if no_tomllib:
        env["PYTHONPATH"] = _SHADOW_DIR + os.pathsep + env.get("PYTHONPATH", "")
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout, proc.stderr


def _write(path: Path, text: str):
    path.write_text(text, encoding="utf-8")


class TomllibPath(unittest.TestCase):
    """Real tomllib is present in the test environment (3.11+), so these
    exercise the primary (non-fallback) branch."""

    def test_happy_path_writes_deps(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml",
                   '[project]\nname = "app"\ndependencies = ["click", "requests>=2,<3"]\n')
            rc, _, _ = _run(d, ["out.txt"])
            self.assertEqual(rc, 0)
            self.assertEqual((Path(d) / "out.txt").read_text(encoding="ascii"),
                              "click\nrequests>=2,<3\n")

    def test_extras_and_escaped_quote_preserved_and_unescaped(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml",
                   '[project]\ndependencies = ["pkg[all]", "weird\\"quote"]\n')
            rc, _, _ = _run(d, ["out.txt"])
            self.assertEqual(rc, 0)
            lines = (Path(d) / "out.txt").read_text(encoding="ascii").splitlines()
            self.assertEqual(lines, ["pkg[all]", 'weird"quote'])

    def test_no_pyproject_toml_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            rc, _, _ = _run(d, ["out.txt"])
            self.assertEqual(rc, 1)
            self.assertFalse((Path(d) / "out.txt").exists())

    def test_missing_dependencies_key_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml", '[project]\nname = "app"\n')
            rc, _, _ = _run(d, ["out.txt"])
            self.assertEqual(rc, 1)

    def test_empty_dependencies_list_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml", '[project]\ndependencies = []\n')
            rc, _, _ = _run(d, ["out.txt"])
            self.assertEqual(rc, 1)

    def test_malformed_toml_exits_2(self):
        with tempfile.TemporaryDirectory() as d:
            # Unterminated string -- invalid TOML overall, tomllib.loads raises.
            _write(Path(d) / "pyproject.toml", '[project]\nname = "unterminated\n')
            rc, _, _ = _run(d, ["out.txt"])
            self.assertEqual(rc, 2)

    def test_default_output_path_used_when_arg_omitted(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml", '[project]\ndependencies = ["click"]\n')
            rc, _, _ = _run(d)
            self.assertEqual(rc, 0)
            self.assertTrue((Path(d) / "~requirements.pyproject.txt").exists())


class RegexFallbackPath(unittest.TestCase):
    """tomllib shadowed to be unavailable -- exercises the char-by-char
    dependency-array walk and the fallback's own malformed-header detection."""

    def test_happy_path_writes_deps(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml",
                   '[project]\nname = "app"\ndependencies = [\n    "click",\n    "requests>=2,<3",\n]\n')
            rc, _, _ = _run(d, ["out.txt"], no_tomllib=True)
            self.assertEqual(rc, 0)
            self.assertEqual((Path(d) / "out.txt").read_text(encoding="ascii"),
                              "click\nrequests>=2,<3\n")

    def test_extras_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml", '[project]\ndependencies = ["pkg[all]"]\n')
            rc, _, _ = _run(d, ["out.txt"], no_tomllib=True)
            self.assertEqual(rc, 0)
            self.assertEqual((Path(d) / "out.txt").read_text(encoding="ascii"), "pkg[all]\n")

    def test_escaped_quote_backslash_not_stripped(self):
        # derived requirement (observed, not changed): unlike tomllib's own parser,
        # the regex fallback's char-by-char walk skips an escaped quote to avoid
        # stopping early, but does not strip the backslash from the collected
        # text -- a real, minor, pre-existing behavioral difference between the
        # two paths. Documented here rather than "fixed" since real-world
        # pyproject.toml dependency strings essentially never contain escaped
        # quotes, and changing it is out of scope for a payload-promotion pass.
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml", '[project]\ndependencies = ["weird\\"quote"]\n')
            rc, _, _ = _run(d, ["out.txt"], no_tomllib=True)
            self.assertEqual(rc, 0)
            self.assertEqual((Path(d) / "out.txt").read_text(encoding="ascii"), 'weird\\"quote\n')

    def test_stops_at_first_unquoted_bracket_ignoring_trailing_comment(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml",
                   '[project]\ndependencies = ["click"]  # trailing comment\nname = "app"\n')
            rc, _, _ = _run(d, ["out.txt"], no_tomllib=True)
            self.assertEqual(rc, 0)
            self.assertEqual((Path(d) / "out.txt").read_text(encoding="ascii"), "click\n")

    def test_no_project_section_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml", '[tool.other]\nname = "app"\n')
            rc, _, _ = _run(d, ["out.txt"], no_tomllib=True)
            self.assertEqual(rc, 1)

    def test_project_section_no_dependencies_key_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml", '[project]\nname = "app"\n')
            rc, _, _ = _run(d, ["out.txt"], no_tomllib=True)
            self.assertEqual(rc, 1)

    def test_unclosed_project_header_exits_2(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml", '[project\ndependencies = ["click"]\n')
            rc, _, _ = _run(d, ["out.txt"], no_tomllib=True)
            self.assertEqual(rc, 2)

    def test_dependencies_scan_stops_at_next_table_header(self):
        with tempfile.TemporaryDirectory() as d:
            _write(Path(d) / "pyproject.toml",
                   '[project]\nname = "app"\n\n[tool.other]\ndependencies = ["should-not-see-this"]\n')
            rc, _, _ = _run(d, ["out.txt"], no_tomllib=True)
            # [project] itself has no dependencies key; the scan must not
            # bleed into the later [tool.other] table's own key of the same name.
            self.assertEqual(rc, 1)


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_PYPROJ_DEPS=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_PYPROJ_DEPS payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_PYPROJ_DEPS base64 is out of sync with tools/pyproj_deps.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
