from tools import check_ndjson_registry


def test_parse_doc_registry_expands_braces_and_strips_annotations(tmp_path):
    doc = tmp_path / "agent-ndjson.md"
    doc.write_text(
        "## Section\n\n"
        "```\n"
        "reqspec.translate.{gte,eq,compat}, self.cascade.exec (uv lane only -- notes; non-gating),\n"
        "pr.to_conda (x many)\n"
        "```\n",
        encoding="utf-8",
    )
    ids, many_ids = check_ndjson_registry.parse_doc_registry(doc)
    assert ids == {
        "reqspec.translate.gte",
        "reqspec.translate.eq",
        "reqspec.translate.compat",
        "self.cascade.exec",
        "pr.to_conda",
    }
    # "(x many)" is informational only (same id fires many times) -- still a full member of ids.
    assert many_ids == {"pr.to_conda"}


def test_scan_code_ids_covers_all_four_emission_patterns(tmp_path):
    ps1 = tmp_path / "selfapps_example.ps1"
    ps1.write_text(
        "Write-NdjsonRow ([ordered]@{ id = 'self.example.hashtable'; pass = $true })\n"
        "Write-Result 'batch.example.writeresult' 'desc' $true @{}\n"
        "Write-EntryRow -Id 'self.example.namedparam' -Expected $x\n"
        '$row = \'{"id":"self.example.jsonliteral","pass":true}\'\n',
        encoding="utf-8",
    )
    ids = check_ndjson_registry.scan_code_ids([ps1])
    assert ids == {
        "self.example.hashtable",
        "batch.example.writeresult",
        "self.example.namedparam",
        "self.example.jsonliteral",
    }


def test_scan_log_ids_reads_ndjson_lines(tmp_path):
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    (log_dir / "results.ndjson").write_text(
        '{"id": "self.example.hashtable", "pass": true}\n'
        '{"id": "batch.example.writeresult", "pass": false}\n'
        "not-json\n",
        encoding="utf-8",
    )
    ids = check_ndjson_registry.scan_log_ids(log_dir)
    assert ids == {"self.example.hashtable", "batch.example.writeresult"}


def test_main_reports_pass_when_doc_and_code_agree(tmp_path, capsys):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "agent-ndjson.md").write_text(
        "```\nself.example.row\n```\n", encoding="utf-8"
    )
    (tmp_path / "tests").mkdir()
    (tmp_path / "tests" / "selfapps_example.ps1").write_text(
        "Write-NdjsonRow ([ordered]@{ id = 'self.example.row'; pass = $true })\n",
        encoding="utf-8",
    )
    (tmp_path / "run_setup.bat").write_text("rem no rows here\n", encoding="utf-8")

    result = check_ndjson_registry.main(["--repo-root", str(tmp_path)])
    captured = capsys.readouterr()

    assert result == 0
    assert "PASS: no doc/code registry mismatches found." in captured.out


def test_main_scans_workflow_yaml_for_inline_emissions(tmp_path, capsys):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "agent-ndjson.md").write_text(
        "```\nself.example.workflow.row\n```\n", encoding="utf-8"
    )
    (tmp_path / "tests").mkdir()
    (tmp_path / "run_setup.bat").write_text("rem no rows here\n", encoding="utf-8")
    workflows_dir = tmp_path / ".github" / "workflows"
    workflows_dir.mkdir(parents=True)
    (workflows_dir / "batch-check.yml").write_text(
        "jobs:\n"
        "  example:\n"
        "    steps:\n"
        "      - run: |\n"
        "          $row = [ordered]@{ id = 'self.example.workflow.row'; pass = $true }\n",
        encoding="utf-8",
    )

    result = check_ndjson_registry.main(["--repo-root", str(tmp_path)])
    captured = capsys.readouterr()

    assert result == 0
    assert "PASS: no doc/code registry mismatches found." in captured.out


def test_main_reports_fail_on_undocumented_code_row(tmp_path, capsys):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "agent-ndjson.md").write_text("```\n```\n", encoding="utf-8")
    (tmp_path / "tests").mkdir()
    (tmp_path / "tests" / "selfapps_example.ps1").write_text(
        "Write-NdjsonRow ([ordered]@{ id = 'self.example.undocumented'; pass = $true })\n",
        encoding="utf-8",
    )
    (tmp_path / "run_setup.bat").write_text("rem no rows here\n", encoding="utf-8")

    result = check_ndjson_registry.main(["--repo-root", str(tmp_path)])
    captured = capsys.readouterr()

    assert result == 1
    assert "self.example.undocumented" in captured.out
    assert "Emitted in code but not registered" in captured.out
