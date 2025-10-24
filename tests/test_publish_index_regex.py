import tempfile
import unittest
import zipfile
from pathlib import Path

from tools.diag.publish_index import (
    _validate_iterate_status_line,
    _write_global_txt_mirrors,
)


class IterateStatusLineTest(unittest.TestCase):
    def test_accepts_single_iterate_logs_line(self) -> None:
        sample = "\n".join(
            [
                "# CI Diagnostics",
                "",
                "## Status",
                "* Iterate logs: found",
                "- Batch-check run id: missing",
            ]
        )
        # Should not raise
        _validate_iterate_status_line(sample)

    def test_rejects_missing_iterate_logs_line(self) -> None:
        sample = "\n".join(["# CI Diagnostics", "", "## Status"])
        with self.assertRaises(ValueError):
            _validate_iterate_status_line(sample)

    def test_rejects_multiple_iterate_logs_lines(self) -> None:
        sample = "\n".join(
            [
                "# CI Diagnostics",
                "",
                "## Status",
                "* Iterate logs: found",
                "* Iterate logs: missing",
            ]
        )
        with self.assertRaises(ValueError):
            _validate_iterate_status_line(sample)


class MirrorGenerationTest(unittest.TestCase):
    def test_global_mirror_tree_captures_previews(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "diag"
            iterate_temp = root / "_artifacts" / "iterate" / "_temp"
            iterate_temp.mkdir(parents=True, exist_ok=True)
            response_path = iterate_temp / "response.json"
            response_path.write_text("{\"foo\": \"bar\"}", encoding="utf-8")

            logs_dir = root / "logs"
            logs_dir.mkdir(parents=True, exist_ok=True)
            zip_path = logs_dir / "example.zip"
            with zipfile.ZipFile(zip_path, "w") as archive:
                archive.writestr("sample.txt", "hello world")

            mirrors_root = root / "_mirrors"
            pairs = _write_global_txt_mirrors(root, mirrors_root)

            json_mirror = mirrors_root / "_artifacts" / "iterate" / "_temp" / "response.json.txt"
            self.assertTrue(json_mirror.exists(), "JSON preview should be generated")
            json_preview = json_mirror.read_text(encoding="utf-8")
            self.assertIn('"foo"', json_preview)
            self.assertIn("  \"foo\"", json_preview)
            self.assertTrue(json_preview.endswith("\n"))

            zip_mirror = mirrors_root / "logs" / "example.zip.txt"
            self.assertTrue(zip_mirror.exists(), "ZIP preview should be generated")
            zip_preview = zip_mirror.read_text(encoding="utf-8")
            self.assertIn("Zip archive preview", zip_preview)
            self.assertIn("sample.txt", zip_preview)

            self.assertFalse(
                any(p.suffix == ".txt" for p in iterate_temp.rglob("*.txt")),
                "Iterate directory should not receive inline mirrors",
            )

            for _, mirror_path in pairs:
                self.assertTrue(mirror_path.is_file())
                self.assertTrue(str(mirror_path).startswith(str(mirrors_root)))


if __name__ == "__main__":
    unittest.main()
