"""
Tests for the HP_FAST_CHECK embedded payload (fast-path EXE freshness check).

The PowerShell script is base64-encoded inside run_setup.bat.  These tests
extract the $infraPattern regex and verify it correctly classifies paths so
the EXE fast path only fires when the user's own .py files are unchanged.

Coverage goal: every directory name in the exclusion list has a test; every
directory that must NOT be excluded has a test; and adversarial names that
share a prefix with an excluded name (e.g. "distribute" ~ "dist") are verified
to be included.  Both forward-slash and backslash path separators are tested
because Windows paths use backslashes and the .NET regex engine (PowerShell)
treats backslash-slash as forward-slash only -- the pattern must use [/\\\\] for correctness.
"""
import base64
import pathlib
import re
import unittest

_BAT = pathlib.Path(__file__).parent.parent / "run_setup.bat"


def _extract_infra_pattern() -> str:
    for line in _BAT.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if stripped.startswith('set "HP_FAST_CHECK='):
            # split at first = only; the base64 payload may contain = padding
            b64 = stripped.split("=", 1)[1].rstrip('"')
            ps = base64.b64decode(b64).decode("utf-8")
            m = re.search(r"\$infraPattern\s*=\s*'([^']+)'", ps)
            if m:
                return m.group(1)
    raise ValueError("HP_FAST_CHECK or $infraPattern not found in run_setup.bat")


_PATTERN = _extract_infra_pattern()
_RX = re.compile(_PATTERN)

# Paths whose .py files must be EXCLUDED (matched by the regex).
# Includes both forward-slash (/)) and backslash (\\) variants because
# Windows uses backslashes and the regex must handle both.
_EXCLUDED = [
    # .git
    "C:/app/.git/hooks/pre-commit.py",
    r"C:\app\.git\hooks\pre-commit.py",
    ".git/config.py",
    # .github
    "C:/app/.github/scripts/check.py",
    r"C:\app\.github\scripts\check.py",
    # dist (PyInstaller output)
    "C:/app/dist/myapp/myapp.py",
    r"C:\app\dist\myapp\myapp.py",
    # .venv (standard virtual environment)
    "C:/app/.venv/site-packages/requests/__init__.py",
    r"C:\app\.venv\Lib\site-packages\requests\__init__.py",
    # .uv_env (UV virtual environment -- REQ-009 UV provider)
    "C:/app/.uv_env/Lib/site-packages/requests/__init__.py",
    r"C:\app\.uv_env\Lib\site-packages\requests\__init__.py",
    ".uv_env/site-packages/numpy/core/_multiarray_umath.py",
    # __pycache__
    "C:/app/__pycache__/main.cpython-311.pyc.py",
    r"C:\app\__pycache__\util.cpython-311.py",
    "src/__pycache__/helper.py",
    # .conda (conda package cache)
    "C:/app/.conda/pkgs/numpy/__init__.py",
    r"C:\app\.conda\pkgs\numpy\__init__.py",
]

# Paths whose .py files must be INCLUDED (NOT matched by the regex).
_INCLUDED = [
    "C:/app/main.py",
    r"C:\app\main.py",
    "C:/app/src/app.py",
    "C:/app/utils/helper.py",
    "./run.py",
    # Names that share a prefix with an excluded component but differ
    "C:/app/distribute/lib.py",       # 'dist' prefix but not a path component
    "C:/app/distribution/utils.py",
    "C:/app/vendor/condautils/pkg.py",  # 'conda' inside word, not a .conda dir
    "C:/app/githubtools/api.py",       # 'github' prefix, no leading dot
    "C:/app/venv_wrapper/proxy.py",    # 'venv' prefix, not '.venv'
    "C:/app/src/uv_helpers.py",        # 'uv_' in filename, not a dir
]


class InfraPatternExcludedTest(unittest.TestCase):
    def test_git_dir_excluded(self) -> None:
        for path in _EXCLUDED:
            if ".git" in path and ".github" not in path:
                self.assertIsNotNone(_RX.search(path), f"Expected excluded: {path!r}")

    def test_github_dir_excluded(self) -> None:
        for path in _EXCLUDED:
            if ".github" in path:
                self.assertIsNotNone(_RX.search(path), f"Expected excluded: {path!r}")

    def test_dist_dir_excluded(self) -> None:
        for path in _EXCLUDED:
            if "/dist/" in path or "\\dist\\" in path:
                self.assertIsNotNone(_RX.search(path), f"Expected excluded: {path!r}")

    def test_venv_dir_excluded(self) -> None:
        for path in _EXCLUDED:
            if ".venv" in path:
                self.assertIsNotNone(_RX.search(path), f"Expected excluded: {path!r}")

    def test_uv_env_dir_excluded(self) -> None:
        for path in _EXCLUDED:
            if ".uv_env" in path:
                self.assertIsNotNone(_RX.search(path), f"Expected excluded: {path!r}")

    def test_pycache_dir_excluded(self) -> None:
        for path in _EXCLUDED:
            if "__pycache__" in path:
                self.assertIsNotNone(_RX.search(path), f"Expected excluded: {path!r}")

    def test_conda_dir_excluded(self) -> None:
        for path in _EXCLUDED:
            if ".conda" in path:
                self.assertIsNotNone(_RX.search(path), f"Expected excluded: {path!r}")

    def test_backslash_paths_excluded(self) -> None:
        backslash_paths = [p for p in _EXCLUDED if "\\" in p]
        self.assertTrue(backslash_paths, "No backslash test paths in _EXCLUDED list")
        for path in backslash_paths:
            self.assertIsNotNone(
                _RX.search(path),
                f"Backslash path expected to be excluded: {path!r}",
            )


class InfraPatternIncludedTest(unittest.TestCase):
    def test_source_paths_included(self) -> None:
        for path in _INCLUDED:
            self.assertIsNone(_RX.search(path), f"Expected included (not excluded): {path!r}")

    def test_distribute_not_falsely_excluded(self) -> None:
        self.assertIsNone(_RX.search("C:/app/distribute/lib.py"))
        self.assertIsNone(_RX.search("C:/app/distribution/utils.py"))

    def test_githubtools_not_falsely_excluded(self) -> None:
        self.assertIsNone(_RX.search("C:/app/githubtools/api.py"))

    def test_venv_prefix_not_falsely_excluded(self) -> None:
        self.assertIsNone(_RX.search("C:/app/venv_wrapper/proxy.py"))

    def test_uv_env_in_filename_not_excluded(self) -> None:
        self.assertIsNone(_RX.search("C:/app/src/uv_helpers.py"))


class InfraPatternPayloadSyncTest(unittest.TestCase):
    def test_uv_env_present_in_pattern(self) -> None:
        self.assertIn(
            r"\.uv_env",
            _PATTERN,
            "REQ-009 UV provider creates .uv_env/; it must be in the exclusion list",
        )

    def test_venv_present_in_pattern(self) -> None:
        self.assertIn(r"\.venv", _PATTERN)

    def test_conda_present_in_pattern(self) -> None:
        self.assertIn(r"\.conda", _PATTERN)

    def test_git_present_in_pattern(self) -> None:
        self.assertIn(r"\.git", _PATTERN)

    def test_dist_present_in_pattern(self) -> None:
        self.assertIn("dist", _PATTERN)

    def test_pycache_present_in_pattern(self) -> None:
        self.assertIn("__pycache__", _PATTERN)

    def test_pattern_uses_dual_separator(self) -> None:
        # backslash-slash [\/] only matches forward slash in both Python and .NET regex.
        # The pattern must use [/\\] to also match Windows backslash paths.
        self.assertNotIn(
            r"[\/]",
            _PATTERN,
            r"Pattern must use [/\\] not [\/]; the latter only matches '/' in .NET regex",
        )


if __name__ == "__main__":
    unittest.main()
