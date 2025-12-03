from tools import check_delimiters


def test_check_delimiters_import_and_empty_run(tmp_path, capsys):
    # Ensure the manual helper remains importable and reports no issues for empty directories.
    result = check_delimiters.main([str(tmp_path)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out
