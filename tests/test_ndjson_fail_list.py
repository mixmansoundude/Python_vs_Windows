import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class NdjsonFailListScriptTest(unittest.TestCase):
    def _locate_powershell(self) -> str:
        for candidate in ("pwsh", "powershell"):
            resolved = shutil.which(candidate)
            if resolved:
                return resolved
        raise unittest.SkipTest("PowerShell is not available in this environment")

    def _run_script(self, diag_root: Path) -> Path:
        ps_path = self._locate_powershell()
        repo_root = Path(__file__).resolve().parents[1]
        script = repo_root / "tools" / "diag" / "ndjson_fail_list.ps1"

        env = os.environ.copy()
        env["DIAG"] = str(diag_root)

        cmd = [ps_path, "-NoLogo", "-NoProfile"]
        if Path(ps_path).name.lower().startswith("powershell"):
            cmd.extend(["-NonInteractive", "-ExecutionPolicy", "Bypass"])
        cmd.extend(["-File", str(script)])

        subprocess.run(cmd, check=True, env=env)

        output_path = diag_root / "batchcheck_failing.txt"
        self.assertTrue(output_path.exists(), "Expected fail list to be generated")
        return output_path

    def test_placeholder_none_triggers_ndjson_scan(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            diag_root = Path(tmp)
            batch_root = diag_root / "_artifacts" / "batch-check"
            batch_root.mkdir(parents=True, exist_ok=True)
            (batch_root / "failing-tests.txt").write_text("none\n", encoding="utf-8")
            ndjson_path = batch_root / "sample~test-results.ndjson"
            ndjson_path.write_text('{"id":"conda.url","pass":false}\n', encoding="utf-8")

            output_path = self._run_script(diag_root)
            lines = [line.strip() for line in output_path.read_text(encoding="utf-8").splitlines() if line.strip()]
            self.assertIn("conda.url", lines)
            self.assertNotIn("none", lines)

    def test_concatenated_json_objects_are_normalized(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            diag_root = Path(tmp)
            batch_root = diag_root / "_artifacts" / "batch-check"
            batch_root.mkdir(parents=True, exist_ok=True)
            (batch_root / "failing-tests.txt").write_text("none\n", encoding="utf-8")

            ndjson_path = batch_root / "mega~test-results.ndjson"
            ndjson_path.write_text(
                '{"id":"conda.url","pass":false} {"id":"self.bootstrap.state","pass":false}'
                '{"id":"self.empty_repo.msg","pass":false}',
                encoding="utf-8",
            )

            output_path = self._run_script(diag_root)
            lines = [line.strip() for line in output_path.read_text(encoding="utf-8").splitlines() if line.strip()]
            self.assertEqual(
                sorted({"conda.url", "self.bootstrap.state", "self.empty_repo.msg"}),
                sorted(lines),
            )
            self.assertNotIn("none", lines)

    def test_precomputed_list_filters_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            diag_root = Path(tmp)
            batch_root = diag_root / "_artifacts" / "batch-check"
            batch_root.mkdir(parents=True, exist_ok=True)
            (batch_root / "failing-tests.txt").write_text("self.bootstrap.state\n NONE \n", encoding="utf-8")

            output_path = self._run_script(diag_root)
            lines = [line.strip() for line in output_path.read_text(encoding="utf-8").splitlines() if line.strip()]
            self.assertEqual(["self.bootstrap.state"], lines)


if __name__ == "__main__":
    unittest.main()
