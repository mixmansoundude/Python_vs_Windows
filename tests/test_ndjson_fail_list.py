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

    def test_batch_ndjson_pass_false_produces_id(self) -> None:
        ps_path = self._locate_powershell()
        repo_root = Path(__file__).resolve().parents[1]
        script = repo_root / "tools" / "diag" / "ndjson_fail_list.ps1"

        with tempfile.TemporaryDirectory() as tmp:
            diag_root = Path(tmp)
            batch_root = diag_root / "_artifacts" / "batch-check"
            batch_root.mkdir(parents=True, exist_ok=True)
            ndjson_path = batch_root / "sample~test-results.ndjson"
            ndjson_path.write_text('{"id":"conda.url","pass":false}\n', encoding="utf-8")

            env = os.environ.copy()
            env["DIAG"] = str(diag_root)

            cmd = [ps_path, "-NoLogo", "-NoProfile"]
            if Path(ps_path).name.lower().startswith("powershell"):
                cmd.extend(["-NonInteractive", "-ExecutionPolicy", "Bypass"])
            cmd.extend(["-File", str(script)])

            subprocess.run(cmd, check=True, env=env)

            output_path = diag_root / "batchcheck_failing.txt"
            self.assertTrue(output_path.exists(), "Expected fail list to be generated")
            lines = [line.strip() for line in output_path.read_text(encoding="utf-8").splitlines() if line.strip()]
            self.assertIn("conda.url", lines)
            self.assertNotIn("none", lines)


if __name__ == "__main__":
    unittest.main()
