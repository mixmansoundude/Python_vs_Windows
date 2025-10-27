import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from tools.diag.publish_index import (
    Context,
    _build_site_overview,
    _validate_iterate_status_line,
    _write_global_txt_mirrors,
    _write_latest_json,
    _write_run_index_txt,
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

            gate_path = root / "_artifacts" / "iterate" / "iterate_gate.json"
            gate_path.parent.mkdir(parents=True, exist_ok=True)
            gate_path.write_text(
                '{"stage":"iterate-gate","proceed":true,"missing_inputs":["tests~test-results.ndjson"]}',
                encoding="utf-8",
            )

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

            gate_mirror = mirrors_root / "_artifacts" / "iterate" / "iterate_gate.json.txt"
            self.assertTrue(gate_mirror.exists(), "Iterate gate preview should be generated")
            gate_preview = gate_mirror.read_text(encoding="utf-8")
            self.assertIn('"stage": "iterate-gate"', gate_preview)
            self.assertIn('"missing_inputs"', gate_preview)

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


class QuickLinksRenderingTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.diag = root / "diag"
        self.diag.mkdir(parents=True, exist_ok=True)
        self.site = root / "site"
        self.site.mkdir(parents=True, exist_ok=True)

    def _make_context(self) -> Context:
        return Context(
            diag=self.diag,
            artifacts=None,
            repo="owner/repo",
            branch="main",
            sha="deadbeef",
            run_id="1234",
            run_attempt="1",
            run_url="https://example.invalid/run",
            short_sha="deadbee",
            inventory_b64=None,
            batch_run_id=None,
            batch_run_attempt=None,
            site=self.site,
        )

    @patch("tools.diag.publish_index._has_file", return_value=False)
    @patch("tools.diag.publish_index._bundle_links", return_value=[])
    def test_site_overview_handles_zero_bundle_entries(
        self, mock_links, _mock_has
    ) -> None:
        context = self._make_context()
        markdown, html = _build_site_overview(context, None, None, None)
        self.assertIn("## Quick links", markdown)
        self.assertNotIn("[Download]", markdown)
        self.assertIn("<h2>Quick links</h2>", html)
        self.assertNotIn("Download</a>", html)
        mock_links.assert_called_once()

    @patch("tools.diag.publish_index._bundle_links")
    @patch("tools.diag.publish_index._has_file")
    def test_site_overview_emits_one_line_per_entry(self, mock_has_file, mock_bundle_links) -> None:
        preview_path = self.diag / "logs" / "previewed.txt"
        preview_path.parent.mkdir(parents=True, exist_ok=True)
        preview_path.write_text("preview", encoding="utf-8")
        preview_mirror = self.diag / "_mirrors" / "logs" / "previewed.txt"
        preview_mirror.parent.mkdir(parents=True, exist_ok=True)
        preview_mirror.write_text("preview mirror", encoding="utf-8")
        download_only_path = self.diag / "logs" / "download-only.txt"
        download_only_path.parent.mkdir(parents=True, exist_ok=True)
        download_only_path.write_text("download", encoding="utf-8")

        entries = [
            {"label": "Previewed", "path": preview_path, "mirror": preview_mirror},
            {"label": "Download only", "path": download_only_path},
        ]
        mock_bundle_links.return_value = entries

        def has_file(site, relative: str) -> bool:  # type: ignore[override]
            expected = {
                "diag/1234-1/logs/previewed.txt",
                "diag/1234-1/_mirrors/logs/previewed.txt",
                "diag/1234-1/logs/download-only.txt",
            }
            return relative in expected

        mock_has_file.side_effect = has_file
        context = self._make_context()
        markdown, html = _build_site_overview(context, None, None, None)

        self.assertIn(
            "- Previewed: [Preview (.txt)](diag/1234-1/_mirrors/logs/previewed.txt) ("
            "[Download](diag/1234-1/logs/previewed.txt))",
            markdown,
        )
        self.assertIn(
            "- Download only: [Download](diag/1234-1/logs/download-only.txt)",
            markdown,
        )
        self.assertIn(
            "<li><strong>Previewed:</strong> <a href=\"diag/1234-1/_mirrors/logs/previewed.txt\">"
            "Preview (.txt)</a> (<a href=\"diag/1234-1/logs/previewed.txt\">Download</a>)</li>",
            html,
        )
        self.assertIn(
            "<li><strong>Download only:</strong> <a href=\"diag/1234-1/logs/download-only.txt\">"
            "Download</a></li>",
            html,
        )
        self.assertEqual(mock_bundle_links.call_count, 1)

    def test_latest_manifest_pointer_files(self) -> None:
        context = self._make_context()
        _write_latest_json(context, None, None, None, None)

        latest_json = self.site / "latest.json"
        payload = json.loads(latest_json.read_text(encoding="utf-8"))
        self.assertEqual(
            payload,
            {"run_id": "1234-1", "url": "/repo/diag/1234-1/index.html"},
        )

        latest_txt = (self.site / "latest.txt").read_text(encoding="utf-8")
        self.assertEqual(latest_txt, "/repo/diag/1234-1/index.html\n")

    def test_run_index_txt_mirrors_prompt_and_rationale(self) -> None:
        context = self._make_context()
        iterate_temp = self.diag / "_artifacts" / "iterate" / "_temp"
        iterate_temp.mkdir(parents=True, exist_ok=True)

        (iterate_temp / "prompt.txt").write_text("line1\nline2\n", encoding="utf-8")
        (iterate_temp / "why_no_diff.txt").write_text("reason1\nreason2\n", encoding="utf-8")
        (iterate_temp / "request.redacted.json").write_text("{}", encoding="utf-8")
        (iterate_temp / "response.json").write_text("{}", encoding="utf-8")
        (iterate_temp / "repo_context.zip").write_bytes(b"PK")

        response_data = {"model": "gpt-4o", "http_status": 200}
        status_data = {"gate_summary": "pass: everything ok"}

        _write_run_index_txt(context, None, None, response_data, status_data)

        index_txt = (self.diag / "index.txt").read_text(encoding="utf-8")

        self.assertIn("Run: 1234-1", index_txt)
        self.assertIn("Branch: main", index_txt)
        self.assertIn("Gate: pass: everything ok", index_txt)
        self.assertIn("Iterate: model=gpt-4o; http=200", index_txt)
        self.assertIn("_artifacts/iterate/_temp/prompt.txt", index_txt)
        self.assertIn("_artifacts/iterate/_temp/repo_context.zip", index_txt)
        self.assertIn("Rationale:", index_txt)
        self.assertIn("  reason1", index_txt)
        self.assertIn("Prompt (head):", index_txt)
        self.assertIn("  line1", index_txt)


if __name__ == "__main__":
    unittest.main()
