import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

# The live diagnostics site is now published by tools/diag/publish_index.py.

from tools.diag.publish_index import (
    Context,
    _build_markdown,
    _build_site_overview,
    _batch_status,
    _ensure_diag_log_placeholders,
    _ensure_iterate_log_archive,
    _ensure_repo_index,
    _validate_iterate_status_line,
    _write_global_txt_mirrors,
    _write_html,
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


class ReloadLinkTest(unittest.TestCase):
    def test_markdown_includes_reload_cache_buster(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            diag_root = Path(tmp) / "diag"
            diag_root.mkdir(parents=True, exist_ok=True)

            context = Context(
                diag=diag_root,
                artifacts=None,
                artifacts_override=None,
                downloaded_iter_root=None,
                repo="owner/repo",
                branch="main",
                sha="deadbeef",
                run_id="1234",
                run_attempt="2",
                run_url="https://example.invalid/run",
                short_sha="deadbee",
                inventory_b64=None,
                batch_run_id=None,
                batch_run_attempt=None,
                site=None,
            )

            markdown = _build_markdown(
                context,
                None,
                None,
                "2025-01-02T03:04:05Z",
                "2025-01-01T21:04:05-06:00",
                None,
                None,
                None,
            )

            lines = markdown.splitlines()
            self.assertGreaterEqual(len(lines), 2)
            self.assertRegex(
                lines[1], r"^Reload: \[Reload with cache-buster\]\(\?v=1234-2\)$"
            )

    def test_markdown_includes_navigation_notes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            diag_root = Path(tmp) / "diag"
            diag_root.mkdir(parents=True, exist_ok=True)

            context = Context(
                diag=diag_root,
                artifacts=None,
                artifacts_override=None,
                downloaded_iter_root=None,
                repo="owner/repo",
                branch="main",
                sha="deadbeef",
                run_id="1234",
                run_attempt="2",
                run_url="https://example.invalid/run",
                short_sha="deadbee",
                inventory_b64=None,
                batch_run_id=None,
                batch_run_attempt=None,
                site=None,
            )

            markdown = _build_markdown(
                context,
                None,
                None,
                "2025-01-02T03:04:05Z",
                "2025-01-01T21:04:05-06:00",
                None,
                None,
                None,
            )

            self.assertIn("## Diagnostics navigation notes (for Supervisor/model)", markdown)
            self.assertIn("Repository (zip)", markdown)
            self.assertIn("_mirrors/repo/files/...*.txt", markdown)


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

    def test_repo_index_links_target_mirrored_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            diag_root = Path(tmp) / "diag"
            repo_root = (
                diag_root / "repo" / "files" / "owner-repo-deadbee" / "src"
            )
            repo_root.mkdir(parents=True, exist_ok=True)
            script_path = repo_root / "example.py"
            script_path.write_text("print('hello')\n", encoding="utf-8")

            context = Context(
                diag=diag_root,
                artifacts=None,
                artifacts_override=None,
                downloaded_iter_root=None,
                repo="owner/repo",
                branch="main",
                sha="deadbeefdeadbeef",
                run_id="99",
                run_attempt="1",
                run_url="https://example.invalid/run",
                short_sha="deadbee",
                inventory_b64=None,
                batch_run_id=None,
                batch_run_attempt=None,
                site=None,
            )

            _ensure_repo_index(context)
            mirrors_root = diag_root / "_mirrors"
            _write_global_txt_mirrors(diag_root, mirrors_root)

            index_mirror = mirrors_root / "repo" / "index.html.txt"
            self.assertTrue(index_mirror.exists())

            # Professional note: the offline repo index must link to the extracted
            # payload, not the mirrored previews, so the downloaded bundle stays
            # navigable. The mirrors still exist under ``_mirrors`` but are exposed
            # elsewhere in the diagnostics UI.
            expected_href = "./files/owner-repo-deadbee/src/example.py"
            index_preview = index_mirror.read_text(encoding="utf-8")
            self.assertIn(expected_href, index_preview)
            self.assertIn("example.py</a>", index_preview)

            mirrored_file = (
                mirrors_root
                / "repo"
                / "files"
                / "owner-repo-deadbee"
                / "src"
                / "example.py.txt"
            )
            self.assertTrue(mirrored_file.exists())


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
            artifacts_override=None,
            downloaded_iter_root=None,
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

    def test_batch_status_prefers_run_json_when_env_missing(self) -> None:
        batch_root = self.diag / "_artifacts" / "batch-check"
        batch_root.mkdir(parents=True, exist_ok=True)
        run_json = batch_root / "run.json"
        run_json.write_text(
            '{"run_id": "42", "run_attempt": 2, "status": "completed", "conclusion": "success"}',
            encoding="utf-8",
        )

        logs_dir = self.diag / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        (logs_dir / "batch-check-42-2.zip").write_bytes(b"PK")

        context = self._make_context()
        meta = json.loads(run_json.read_text(encoding="utf-8"))
        context.batch_run_id = meta["run_id"]
        context.batch_run_attempt = str(meta["run_attempt"])

        status = _batch_status(self.diag, context)

        self.assertEqual(status, "42 (attempt 2)")
        ok_marker = logs_dir / "batch-check.OK.txt"
        self.assertTrue(ok_marker.exists(), "OK marker should be created when the zip is present")
        self.assertIn("42-2", ok_marker.read_text(encoding="utf-8"))

    def test_batch_status_infers_run_json_when_env_na_and_zip_present(self) -> None:
        batch_root = self.diag / "_artifacts" / "batch-check"
        batch_root.mkdir(parents=True, exist_ok=True)
        run_json = batch_root / "run.json"
        run_json.write_text(
            '{"run_id": "77", "run_attempt": 3, "status": "completed", "conclusion": "success"}',
            encoding="utf-8",
        )

        logs_dir = self.diag / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        zip_path = logs_dir / "batch-check-77-3.zip"
        zip_path.write_bytes(b"PK")

        context = self._make_context()
        context.batch_run_id = None
        context.batch_run_attempt = None
        context.run_attempt = None
        context.artifacts_override = self.diag / "_artifacts"

        status = _batch_status(self.diag, context)

        self.assertEqual(status, "77 (attempt 3)")
        ok_marker = logs_dir / "batch-check.OK.txt"
        self.assertTrue(ok_marker.exists(), "OK marker should be created when the zip is present")
        self.assertNotIn("MISSING", "".join(p.name for p in logs_dir.iterdir()))
        missing_path = logs_dir / "batch-check.MISSING.txt"
        self.assertFalse(missing_path.exists())

    def test_batch_status_reuses_iterate_zip_for_current_run(self) -> None:
        batch_root = self.diag / "_artifacts" / "batch-check"
        batch_root.mkdir(parents=True, exist_ok=True)
        run_json = batch_root / "run.json"
        run_json.write_text(
            '{"run_id": "1234", "run_attempt": 1, "status": "completed", "conclusion": "success"}',
            encoding="utf-8",
        )

        logs_dir = self.diag / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        iterate_zip = logs_dir / "iterate-1234-1.zip"
        iterate_zip.write_bytes(b"PK")

        context = self._make_context()
        context.batch_run_id = None
        context.batch_run_attempt = None
        context.artifacts_override = self.diag / "_artifacts"

        status = _batch_status(self.diag, context)

        self.assertEqual(status, "1234 (attempt 1)")
        missing_path = logs_dir / "batch-check.MISSING.txt"
        self.assertFalse(missing_path.exists())

    def test_batch_status_reports_missing_with_sentinel_reason(self) -> None:
        batch_root = self.diag / "_artifacts" / "batch-check"
        batch_root.mkdir(parents=True, exist_ok=True)
        run_json = batch_root / "run.json"
        run_json.write_text(
            '{"run_id": "88", "run_attempt": 4, "status": "completed", "conclusion": "success"}',
            encoding="utf-8",
        )

        logs_dir = self.diag / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        missing_path = logs_dir / "batch-check.MISSING.txt"
        missing_path.write_text("download failed", encoding="utf-8")

        context = self._make_context()
        context.batch_run_id = None
        context.batch_run_attempt = None
        context.run_attempt = None
        context.artifacts_override = self.diag / "_artifacts"

        status = _batch_status(self.diag, context)

        self.assertEqual(
            status,
            "missing archive (run 88, attempt 4; reason: download failed)",
        )
        ok_marker = logs_dir / "batch-check.OK.txt"
        self.assertFalse(ok_marker.exists(), "OK marker should not be present when logs are missing")

    def test_placeholders_clear_when_batch_artifacts_exist(self) -> None:
        context = self._make_context()

        batch_root = self.diag / "_artifacts" / "batch-check"
        batch_root.mkdir(parents=True, exist_ok=True)
        (batch_root / "STATUS.txt").write_text("completed\n", encoding="utf-8")
        (batch_root / "ci_test_results.ndjson").write_text("{}\n", encoding="utf-8")

        missing_artifact = self.diag / "_artifacts" / "MISSING.txt"
        missing_artifact.write_text(
            "batch-check artifact lookup failed: no completed run for this commit\n",
            encoding="utf-8",
        )

        logs_dir = self.diag / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        missing_log = logs_dir / "batch-check.MISSING.txt"
        missing_log.write_text("stale\n", encoding="utf-8")

        _ensure_diag_log_placeholders(context)

        self.assertFalse(missing_log.exists(), "Cleanup should remove stale batch-check placeholder")
        self.assertFalse(
            missing_artifact.exists(),
            "_artifacts/MISSING.txt should be cleared once batch-check artifacts are present",
        )
        iterate_placeholder = logs_dir / "iterate.MISSING.txt"
        self.assertTrue(iterate_placeholder.exists(), "Iterate placeholder should still be created")

    def test_iterate_placeholder_not_recreated_once_logs_exist(self) -> None:
        context = self._make_context()

        logs_dir = self.diag / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)

        iterate_zip = logs_dir / f"iterate-{context.run_id}-{context.run_attempt}.zip"
        with zipfile.ZipFile(iterate_zip, "w") as archive:
            archive.writestr("payload.txt", "ok")

        missing_placeholder = logs_dir / "iterate.MISSING.txt"
        missing_placeholder.write_text("stale\n", encoding="utf-8")

        _ensure_iterate_log_archive(context)
        self.assertFalse(
            missing_placeholder.exists(),
            "Iterate log mirroring should clear stale placeholders once the archive is present",
        )

        _ensure_diag_log_placeholders(context)

        self.assertFalse(
            missing_placeholder.exists(),
            "Placeholder cleanup should remain idempotent when iterate logs are available",
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


    def test_real_ndjson_summary_and_failures(self) -> None:
        real_root = self.diag / "_artifacts" / "batch-check" / "diag-selftest-real-1"
        logs_dir = real_root / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        (logs_dir / "ci_test_results.ndjson").write_text(
            '{"id":"a","pass":true}\n{"id":"b","pass":false}\n{"id":"c"}\n',
            encoding="utf-8",
        )
        (logs_dir / "~test-results.ndjson").write_text(
            '{"id":"filtered","pass":true}\n',
            encoding="utf-8",
        )

        failure_dir = real_root / "batchcheck-failures-real"
        failure_dir.mkdir(parents=True, exist_ok=True)
        (failure_dir / "failing-tests.txt").write_text(
            "failure.one\nfailure.two\n",
            encoding="utf-8",
        )

        context = self._make_context()
        markdown = _build_markdown(
            context,
            iterate_dir=None,
            iterate_temp=None,
            built_utc="2024-01-01T00:00:00Z",
            built_ct="2023-12-31T18:00:00-06:00",
            response_data=None,
            status_data=None,
            why_outcome=None,
        )

        self.assertIn("## NDJSON (real lane)", markdown)
        self.assertIn("- real ci_test_results.ndjson: rows=3 pass=1 fail=2", markdown)
        self.assertIn("- real ~test-results.ndjson: rows=1 pass=1 fail=0", markdown)
        self.assertIn("**Real lane failures detected:**", markdown)
        self.assertIn("- failure.one", markdown)
        self.assertIn("- failure.two", markdown)
        self.assertIn(
            "- Source: _artifacts/batch-check/diag-selftest-real-1/batchcheck-failures-real/failing-tests.txt",
            markdown,
        )

        html = _write_html(
            context,
            iterate_dir=None,
            iterate_temp=None,
            built_utc="2024-01-01T00:00:00Z",
            built_ct="2023-12-31T18:00:00-06:00",
            response_data=None,
            status_data=None,
            why_outcome=None,
        )

        self.assertIn("<h2>NDJSON (real lane)</h2>", html)
        self.assertIn("rows=3 pass=1 fail=2", html)
        self.assertIn("rows=1 pass=1 fail=0", html)
        self.assertIn("<h2>Real lane failures detected</h2>", html)
        self.assertIn("failure.one", html)
        self.assertIn("failure.two", html)
        self.assertIn("failing-tests.txt", html)

    def test_two_lane_ndjson_prefers_real_table_and_reports_both(self) -> None:
        real_root = self.diag / "_artifacts" / "batch-check" / "diag-selftest-real-1"
        real_logs = real_root / "logs"
        real_logs.mkdir(parents=True, exist_ok=True)
        (real_logs / "ci_test_results.ndjson").write_text(
            '{"id":"real.a","pass":true}\n{"id":"real.b","pass":false}\n',
            encoding="utf-8",
        )

        cache_root = self.diag / "_artifacts" / "batch-check" / "diag-selftest-cache-1"
        cache_logs = cache_root / "logs"
        cache_logs.mkdir(parents=True, exist_ok=True)
        (cache_logs / "ci_test_results.ndjson").write_text(
            '{"id":"cache.a","pass":true}\n{"id":"cache.b","pass":true}\n',
            encoding="utf-8",
        )

        artifacts_root = self.diag / "_artifacts"
        real_summary = real_root / "ndjson_summary.txt"
        cache_summary = cache_root / "ndjson_summary.txt"
        real_summary.write_text("REAL_SUMMARY_LINE\n", encoding="utf-8")
        cache_summary.write_text("CACHE_SUMMARY_LINE\n", encoding="utf-8")

        context = self._make_context()
        context.artifacts = artifacts_root

        markdown = _build_markdown(
            context,
            iterate_dir=None,
            iterate_temp=None,
            built_utc="2024-01-01T00:00:00Z",
            built_ct="2023-12-31T18:00:00-06:00",
            response_data=None,
            status_data=None,
            why_outcome=None,
        )

        self.assertIn("## NDJSON (selected lane: cache+real)", markdown)
        self.assertIn("- real ci_test_results.ndjson: rows=2 pass=1 fail=1", markdown)
        self.assertIn("- cache ci_test_results.ndjson: rows=2 pass=2 fail=0", markdown)
        self.assertIn("REAL_SUMMARY_LINE", markdown)
        self.assertNotIn("CACHE_SUMMARY_LINE", markdown)

        html = _write_html(
            context,
            iterate_dir=None,
            iterate_temp=None,
            built_utc="2024-01-01T00:00:00Z",
            built_ct="2023-12-31T18:00:00-06:00",
            response_data=None,
            status_data=None,
            why_outcome=None,
        )

        self.assertIn("<h2>NDJSON (selected lane: cache+real)</h2>", html)
        self.assertIn("cache ci_test_results.ndjson", html)
        self.assertIn("REAL_SUMMARY_LINE", html)
        self.assertNotIn("CACHE_SUMMARY_LINE", html)

    def test_publisher_marker_renders_in_markdown_and_html(self) -> None:
        context = self._make_context()

        markdown = _build_markdown(
            context,
            iterate_dir=None,
            iterate_temp=None,
            built_utc="2024-01-01T00:00:00Z",
            built_ct="2023-12-31T18:00:00-06:00",
            response_data=None,
            status_data=None,
            why_outcome=None,
        )

        html = _write_html(
            context,
            iterate_dir=None,
            iterate_temp=None,
            built_utc="2024-01-01T00:00:00Z",
            built_ct="2023-12-31T18:00:00-06:00",
            response_data=None,
            status_data=None,
            why_outcome=None,
        )

        marker = "Publisher: tools/diag/publish_index.py (Python)"
        self.assertIn(marker, markdown)
        self.assertIn(marker, html)

    def test_latest_manifest_pointer_files(self) -> None:
        context = self._make_context()
        _write_latest_json(context, None, None, None, None)

        latest_json = self.site / "diag" / "latest.json"
        payload = json.loads(latest_json.read_text(encoding="utf-8"))
        self.assertEqual(
            payload,
            {"run_id": "1234-1", "url": "/repo/diag/1234-1/index.html"},
        )

        latest_txt = (self.site / "diag" / "latest.txt").read_text(encoding="utf-8")
        self.assertEqual(latest_txt, "/repo/diag/1234-1/index.html\n")

    def test_latest_manifest_and_txt_stay_in_sync(self) -> None:
        context = self._make_context()
        context.run_id = "5678"
        context.run_attempt = "3"

        _write_latest_json(context, None, None, None, None)

        latest_json = self.site / "diag" / "latest.json"
        payload = json.loads(latest_json.read_text(encoding="utf-8"))

        self.assertEqual(payload["run_id"], "5678-3")
        self.assertEqual(payload["url"], "/repo/diag/5678-3/index.html")

        latest_txt = (self.site / "diag" / "latest.txt").read_text(encoding="utf-8")
        self.assertEqual(latest_txt, payload["url"] + "\n")
        self.assertIn(payload["run_id"], latest_txt)

    def test_run_index_txt_mirrors_prompt_and_rationale(self) -> None:
        context = self._make_context()
        iterate_temp = self.diag / "_artifacts" / "iterate" / "_temp"
        iterate_temp.mkdir(parents=True, exist_ok=True)

        (iterate_temp / "prompt.txt").write_text("line1\nline2\n", encoding="utf-8")
        (iterate_temp / "why_no_diff.txt").write_text("reason1\nreason2\n", encoding="utf-8")
        (iterate_temp / "request.redacted.json").write_text("{}", encoding="utf-8")
        (iterate_temp / "response.json").write_text("{}", encoding="utf-8")
        (iterate_temp / "repo_context.zip").write_bytes(b"PK")

        inputs_dir = self.diag / "_artifacts" / "iterate" / "inputs"
        inputs_dir.mkdir(parents=True, exist_ok=True)
        (inputs_dir / "ci_test_results.ndjson").write_text('{"id":"a","pass":false}\n', encoding="utf-8")
        (inputs_dir / "tests~test-results.ndjson").write_text('{"id":"b","pass":true}\n', encoding="utf-8")

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
        self.assertIn("Iterate inputs source: public diagnostics page for run 1234-1", index_txt)
        self.assertIn("root: _artifacts/iterate/inputs", index_txt)
        self.assertIn("  - _artifacts/iterate/inputs/ci_test_results.ndjson", index_txt)
        self.assertIn("  - _artifacts/iterate/inputs/tests~test-results.ndjson", index_txt)
        self.assertIn("Rationale:", index_txt)
        self.assertIn("  reason1", index_txt)
        self.assertIn("Prompt (head):", index_txt)
        self.assertIn("  line1", index_txt)


if __name__ == "__main__":
    unittest.main()
