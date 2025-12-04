"""Windows-only CI guardrail for the single-entry bootstrap path.

Runs tests/selfapps_single.ps1 under a simulated pyFiles=1 environment and
asserts that the NDJSON stream captures a passing entry.single.direct row plus
the expected bootstrap breadcrumb for the lone Python entry.
"""
import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path


@unittest.skipUnless(os.name == "nt", "Windows-only single-entry bootstrap check")
class SingleEntrySelfTest(unittest.TestCase):
    def _locate_powershell(self) -> str:
        for candidate in ("pwsh", "powershell"):
            resolved = shutil.which(candidate)
            if resolved:
                return resolved
        raise unittest.SkipTest("PowerShell is not available in this environment")

    def _run_selfapps_single(self) -> None:
        ps_path = self._locate_powershell()
        script = Path(__file__).with_name("selfapps_single.ps1")

        cmd = [ps_path, "-NoLogo", "-NoProfile"]
        if Path(ps_path).name.lower().startswith("powershell"):
            cmd.extend(["-NonInteractive", "-ExecutionPolicy", "Bypass"])
        cmd.extend(["-File", str(script)])

        env = os.environ.copy()
        env.setdefault("PY_FILES", "1")

        subprocess.run(cmd, check=True, cwd=script.parent, env=env)

    def _read_ndjson(self, path: Path) -> list[dict]:
        rows: list[dict] = []
        if not path.exists():
            return rows
        for line in path.read_text(encoding="ascii").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return rows

    def _backup_text(self, path: Path) -> str | None:
        if not path.exists():
            return None
        return path.read_text(encoding="ascii")

    def _restore_text(self, path: Path, content: str | None) -> None:
        if content is None:
            if path.exists():
                path.unlink()
            return
        path.write_text(content, encoding="ascii")

    def test_single_entry_row_is_logged(self) -> None:
        results_path = Path(__file__).with_name("~test-results.ndjson")
        ci_results_path = Path(__file__).resolve().parents[1] / "ci_test_results.ndjson"

        results_backup = self._backup_text(results_path)
        ci_results_backup = self._backup_text(ci_results_path)
        try:
            self._run_selfapps_single()
            rows = self._read_ndjson(results_path)
            row = next((r for r in rows if r.get("id") == "entry.single.direct"), None)
            self.assertIsNotNone(row, "Expected entry.single.direct row in NDJSON output")
            self.assertTrue(row.get("pass"), f"Single-entry row reported failure: {row}")

            log_path = Path(__file__).with_name("~entry1") / "~entry1_bootstrap.log"
            self.assertTrue(log_path.exists(), "Bootstrap log for single-entry path should exist")
            log_text = log_path.read_text(encoding="ascii")
            if "Python file count:" in log_text:
                self.assertIn("Python file count: 1", log_text)
            self.assertRegex(log_text, r"Chosen entry:\s+.*solo\.py")
        finally:
            self._restore_text(results_path, results_backup)
            self._restore_text(ci_results_path, ci_results_backup)
