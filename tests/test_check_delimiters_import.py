from tools import check_delimiters


def test_check_delimiters_import_and_empty_run(tmp_path, capsys):
    # Ensure the manual helper remains importable and reports no issues for empty directories.
    result = check_delimiters.main([str(tmp_path)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


# derived requirement: these four tests are a regression guard for a real bug that
# shipped in run_setup.bat and was only caught on real Windows CI (see
# docs/agent-lessons-learned.md's "rem needs a space after it" entry) -- a "rem"
# comment split across two lines left the second line reading "rem-nested ..." with
# no space after "rem", which cmd.exe parsed as an attempt to run a literal
# (nonexistent) command instead of a comment, leaving a stray nonzero errorlevel
# in front of the very next "if errorlevel 1" check. check_delimiters.py did not
# catch this at the time; _check_bat_rem_comment_spacing closes that gap.
def test_rem_missing_space_after_hyphen_is_flagged(tmp_path, capsys):
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "rem is to report it, not to speculatively rebuild inside an already\r\n"
        "rem-nested failure path.\r\n"
        "if errorlevel 1 (\r\n"
        "  echo bad\r\n"
        ")\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 1
    assert "rem-" in captured.out
    assert "must be followed by whitespace" in captured.out


def test_rem_with_space_is_not_flagged(tmp_path, capsys):
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "rem this is a perfectly normal comment\r\n"
        "echo ok\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_bare_rem_line_is_not_flagged(tmp_path, capsys):
    bat = tmp_path / "sample.bat"
    bat.write_text("@echo off\r\nrem\r\necho ok\r\n", encoding="ascii")
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_rem_prefixed_word_outside_bat_file_is_not_flagged(tmp_path, capsys):
    # The check is scoped to .bat/.cmd only; a Python comment starting with the
    # letters "rem" (e.g. "# remove this") must never be flagged.
    py = tmp_path / "sample.py"
    py.write_text("# remove this line later\nprint('ok')\n", encoding="ascii")
    result = check_delimiters.main([str(py)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out
