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


# derived requirement: these three tests are a regression guard for a second real bug
# that shipped in run_setup.bat and broke 6 CI lanes simultaneously (see
# docs/agent-lessons-learned.md's "A literal (/) inside echo text is NOT invisible..."
# entry, PR #408 commit fd52a3f). A "(" opened on one "echo" line and closed by its
# matching ")" on a LATER "echo" line, both inside an enclosing if(...) block, is
# balanced from a pure count-matching perspective (which is why the pre-existing
# unclosed/mismatched checks missed it) but corrupts cmd.exe's own block-closing
# search at runtime -- "failed was unexpected at this time." check_delimiters.py did
# not catch this at the time; this dedicated check closes that gap.
def test_paren_split_across_echo_lines_inside_block_is_flagged(tmp_path, capsys):
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "if defined HP_NO_INTERPRETER (\r\n"
        "  echo *** method (uv, conda, a fresh download, a ***\r\n"
        "  echo *** local virtual environment) failed -- usually ***\r\n"
        "  exit /b 0\r\n"
        ")\r\n"
        "echo done\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 1
    assert "does not close until line" in captured.out
    assert "counts parens in echo text too" in captured.out


def test_paren_split_across_echo_lines_at_top_level_is_not_flagged(tmp_path, capsys):
    # Same textual pattern as above, but with no enclosing if/for block -- each echo
    # line is an independent top-level command, so there is no block-closing search
    # for cmd.exe to corrupt. A real instance of this shape exists in run_setup.bat
    # (:print_fastpath_ambiguous_note) and must not false-positive.
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "echo  and it exited with an error just now (see the status line\r\n"
        "echo  above) -- so we cannot tell what happened.\r\n"
        "exit /b 0\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_paren_pair_on_same_echo_line_is_not_flagged(tmp_path, capsys):
    # A balanced pair on a single echo line (common, e.g. a parenthetical aside) is
    # always safe regardless of block nesting -- only a CROSS-line split is risky.
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "if defined FOO (\r\n"
        "  echo *** see the docs (specifically the README) for details ***\r\n"
        "  exit /b 0\r\n"
        ")\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out
