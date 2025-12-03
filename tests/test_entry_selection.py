import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path


@unittest.skipUnless(os.name == "nt", "Windows-only entry-selection bootstrap check")
class EntrySelectionSelfTest(unittest.TestCase):
    def _locate_powershell(self) -> str:
        for candidate in ("pwsh", "powershell"):
            resolved = shutil.which(candidate)
            if resolved:
                return resolved
        raise unittest.SkipTest("PowerShell is not available in this environment")

    def _run_selfapps_entry(self) -> None:
        ps_path = self._locate_powershell()
        script = Path(__file__).with_name("selfapps_entry.ps1")

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

    def test_main_precedence_is_logged(self) -> None:
        results_path = Path(__file__).with_name("~test-results.ndjson")
        ci_results_path = Path(__file__).resolve().parents[1] / "ci_test_results.ndjson"

        results_backup = self._backup_text(results_path)
        ci_results_backup = self._backup_text(ci_results_path)
        try:
            self._run_selfapps_entry()
            rows = self._read_ndjson(results_path)
            row = next((r for r in rows if r.get("id") == "self.entry.entryA"), None)
            self.assertIsNotNone(row, "Expected self.entry.entryA row in NDJSON output")
            self.assertTrue(row.get("pass"), f"Entry selection row reported failure: {row}")

            details = row.get("details", {}) if isinstance(row, dict) else {}
            chosen_entry = str(details.get("chosen", ""))
            self.assertIn("main.py", chosen_entry or "", "Chosen entry should include main.py")

            log_path = Path(__file__).with_name("~entryA") / "~entryA_bootstrap.log"
            self.assertTrue(log_path.exists(), "Bootstrap log for entry selection should exist")
            log_text = log_path.read_text(encoding="ascii")
            self.assertIn("Python file count: 2", log_text)
            self.assertRegex(log_text, r"Chosen entry:\s+.*main\.py")
        finally:
            self._restore_text(results_path, results_backup)
            self._restore_text(ci_results_path, ci_results_backup)

