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


def test_scan_dynamic_tests_ids_resolves_literal_fstring_and_bare_name(tmp_path):
    # Mirrors the three id-construction shapes actually used in tests/dynamic_tests.py:
    # a plain literal, an f-string templated from a for-loop's literal tuple list, and a
    # bare loop variable used directly as the id (no quotes at all).
    py = tmp_path / "dynamic_tests.py"
    py.write_text(
        "def record(rec):\n"
        "    pass\n\n"
        "def main():\n"
        "    record({\"id\": \"plain.literal\", \"pass\": True})\n\n"
        "    for _pkg, _target in [(\"requests\", \"certifi\"), (\"sqlalchemy\", \"pymysql\")]:\n"
        "        record({\"id\": f\"pr.{_pkg}.{_target}\", \"pass\": True})\n\n"
        "    for rec_id, expected, files in [\n"
        "        (\"entry.select.single\", \"entry1.py\", {\"entry1.py\": \"x\"}),\n"
        "        (\"entry.select.main_vs_app\", \"main.py\", {\"main.py\": \"x\"}),\n"
        "    ]:\n"
        "        record({\"id\": rec_id, \"expected\": expected, \"pass\": True})\n",
        encoding="utf-8",
    )
    ids = check_ndjson_registry.scan_dynamic_tests_ids(py)
    assert ids == {
        "plain.literal",
        "pr.requests.certifi",
        "pr.sqlalchemy.pymysql",
        "entry.select.single",
        "entry.select.main_vs_app",
    }


def test_scan_dynamic_tests_ids_resolves_rec_indirection_via_dict_items(tmp_path):
    # Mirrors ensure_extracted()'s `needed = {...}; for dst, var in needed.items(): rec = {...};
    # ...; record(rec)` pattern -- the two-hop indirection (dict-literal assignment, then
    # record(name) rather than record({...}) directly) plus a .items() iterable resolved via
    # a locally-tracked dict literal, not a List/Tuple literal.
    py = tmp_path / "dynamic_tests.py"
    py.write_text(
        "def record(rec):\n"
        "    pass\n\n"
        "def ensure_extracted():\n"
        "    needed = {\"~a.py\": \"VAR_A\", \"~b.py\": \"VAR_B\"}\n"
        "    for dst, var in needed.items():\n"
        "        rec = {\"id\": f\"helpers.decode.{dst}\", \"var\": var}\n"
        "        rec.update({\"pass\": True})\n"
        "        record(rec)\n",
        encoding="utf-8",
    )
    ids = check_ndjson_registry.scan_dynamic_tests_ids(py)
    assert ids == {"helpers.decode.~a.py", "helpers.decode.~b.py"}


def test_main_wires_in_dynamic_tests_py_scan(tmp_path, capsys):
    # End-to-end: a doc-registered id that only exists as a dynamic_tests.py record({"id": ...})
    # call (not any PowerShell/batch/YAML pattern) must be found via the AST scan, and a tilde
    # in the id (as in the real helpers.decode.~detect_python.py row) must round-trip through
    # both the doc-side token regex and the code-side AST scan without mismatch.
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "agent-ndjson.md").write_text(
        "```\nhelpers.decode.~a.py\n```\n", encoding="utf-8"
    )
    (tmp_path / "tests").mkdir()
    (tmp_path / "run_setup.bat").write_text("rem no rows here\n", encoding="utf-8")
    (tmp_path / "tests" / "dynamic_tests.py").write_text(
        "def record(rec):\n"
        "    pass\n\n"
        "def main():\n"
        "    needed = {\"~a.py\": \"VAR_A\"}\n"
        "    for dst, var in needed.items():\n"
        "        record({\"id\": f\"helpers.decode.{dst}\", \"var\": var})\n",
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
