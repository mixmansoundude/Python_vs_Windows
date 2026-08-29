from tools import check_delimiters


def test_check_delimiters_import_and_empty_run(tmp_path, capsys):
    # Ensure the manual helper remains importable and reports no issues for empty directories.
    result = check_delimiters.main([str(tmp_path)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


# derived requirement: this exact bug ($IsWindows undefined under Windows PowerShell 5.1,
# where it reads as $null/falsy so "-not $IsWindows" silently skips real Windows execution)
# was independently rediscovered and fixed one file at a time across at least 4 separate PRs
# before this check existed -- see docs/agent-lessons-learned.md's own entry. Regression guard
# for the automated check that now catches it mechanically instead.
def test_live_iswindows_reference_is_flagged(tmp_path, capsys):
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text("if (-not $IsWindows) {\n    Write-Host 'skip'\n}\n", encoding="ascii")
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 1
    assert "$IsWindows" in captured.out
    assert "OSVersion.Platform" in captured.out


def test_commented_iswindows_mention_is_not_flagged(tmp_path, capsys):
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text(
        "# $IsWindows is undefined under Windows PowerShell 5.1 -- do not use it here.\n"
        "if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {\n"
        "    Write-Host 'skip'\n"
        "}\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


# derived requirement (CodeRabbit review, PR #470): the $IsWindows scan used to search raw
# whole-file text with re.finditer, so a QUOTED occurrence (data, not a live reference) was
# indistinguishable from a real one. Fixed by routing the scan through
# find_live_ps1_matches/sanitize_ps1_line, the same quote/comment-stripping machinery the
# boolean-operator checker already relies on.
def test_quoted_iswindows_string_literal_is_not_flagged(tmp_path, capsys):
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text("Write-Host '$IsWindows'\n", encoding="ascii")
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


# derived requirement (CodeRabbit review, PR #470): the old comment-skip logic was a bare
# `line_text.find("#")` against the RAW line -- a '#' inside an earlier quoted string on the
# same line was misread as the start of a real comment, silently suppressing a genuine LIVE
# $IsWindows reference appearing later on that same line. sanitize_ps1_line strips quoted
# content (and the '#' inside it) before comment detection, so this no longer happens.
def test_iswindows_after_quoted_hash_on_same_line_is_still_flagged(tmp_path, capsys):
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text("Write-Host '#not a comment'; if (-not $IsWindows) { 1 }\n", encoding="ascii")
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 1
    assert "$IsWindows" in captured.out
    assert "OSVersion.Platform" in captured.out


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


def test_paren_pair_on_same_echo_line_nested_is_flagged(tmp_path, capsys):
    # A balanced pair on a single plain "echo" line (a parenthetical aside), one
    # level of block nesting deep, IS flagged -- confirmed unsafe via CLAUDE.md
    # Item 61's dedicated cmd.exe probe (tools/probe_paren_hazard.ps1, dispatched
    # 2026-08-23 on a real Windows runner): every same-line matrix fixture
    # corrupted, including the shallowest case (plain, non-redirected, one level
    # of nesting) -- the exact shape this fixture reproduces. See
    # test_paren_pair_on_same_echo_line_at_top_level_is_not_flagged below for the
    # one shape that remains genuinely safe (no enclosing block at all).
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

    assert result == 1
    assert "on this same line" in captured.out
    assert "counts parens in echo text too" in captured.out


def test_paren_pair_on_at_echo_line_nested_is_flagged(tmp_path, capsys):
    # CodeRabbit review finding on PR #464: ECHO_LINE_RE originally missed "@echo" --
    # command-echo suppressed, cmd.exe's own well-documented convention and this file's
    # own top-of-file line -- so a same-line paren pair on an "@echo" line, nested
    # inside a real block, went untracked the same way the redirected-echo gap did
    # before it was fixed. Same fixture shape as the plain-echo test above, "@echo"
    # in place of "echo".
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "if defined FOO (\r\n"
        "  @echo *** see the docs (specifically the README) for details ***\r\n"
        "  exit /b 0\r\n"
        ")\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 1
    assert "on this same line" in captured.out
    assert "counts parens in echo text too" in captured.out


def test_paren_pair_on_same_echo_line_at_top_level_is_not_flagged(tmp_path, capsys):
    # Same textual pattern as the test above, but with no enclosing if/for block --
    # a plain top-level echo statement never needs cmd.exe to search for a block
    # terminator at all, so a same-line pair here is genuinely safe. A real
    # instance of this shape exists in run_setup.bat
    # (:print_fastpath_ambiguous_note) and must not false-positive.
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "echo *** see the docs (specifically the README) for details ***\r\n"
        "exit /b 0\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_paren_pair_nested_inside_another_prose_paren_at_top_level_is_not_flagged(tmp_path, capsys):
    # Regression fixture for a real bug found via CodeRabbit's review of PR #464:
    # the original "already nested" check was `bool(self.stack)`, true the moment
    # ANY bracket is open -- including a PRIOR prose paren from this exact same
    # echo/rem line's own text, not just a genuine enclosing if/for block. For
    # "echo outer (inner (detail))" at true top level (no enclosing block at all),
    # this wrongly classified the line's own SECOND paren as hazardous once the
    # FIRST paren was already on the stack. Fixed by basing the hazard check on
    # whether a genuine STRUCTURAL (non-prose) bracket is already open, not merely
    # on stack non-emptiness -- see StackItem.is_prose.
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "echo outer (inner (detail))\r\n"
        "exit /b 0\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_paren_pair_on_redirected_echo_line_deeply_nested_is_flagged(tmp_path, capsys):
    # Regression fixture for CLAUDE.md Item 61 / PR #445's second real CI incident:
    # a same-line, self-contained "(exit 3)" pair inside a ">> file echo ..."
    # redirected statement, nested FOUR levels deep inside real if(...) blocks,
    # corrupted cmd.exe's block-closing parser on real Windows CI ("falling was
    # unexpected at this time."). Previously a KNOWN FALSE NEGATIVE (the checker
    # did not catch same-line pairs at all); now flagged since the probe confirmed
    # nesting depth and the ">>" redirection prefix are both irrelevant -- any
    # nested same-line pair corrupts, so the fix removed the same-line exemption
    # entirely rather than special-casing depth or redirection.
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "if exist \"x\" (\r\n"
        "  if not errorlevel 1 (\r\n"
        "    if errorlevel 1 (\r\n"
        "      if errorlevel 3 (\r\n"
        "        >> \"%LOG%\" echo unexpected internal error (exit 3); falling back.\r\n"
        "      )\r\n"
        "    )\r\n"
        "  )\r\n"
        ")\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 1
    assert "on this same line" in captured.out
    assert "counts parens in echo text too" in captured.out


# derived requirement: these tests close the cross-line half of CLAUDE.md Item 61 --
# a "rem" comment was previously fully opaque to check_delimiters.py (skipped from
# paren-scanning entirely, unlike "echo" lines), so it never caught the identical
# PR #408 hazard class when it hit a "rem" block instead of an "echo" one, as it
# genuinely did in PR #445 (see docs/agent-lessons-learned.md's "rem needs a space
# after it" entry's sibling incident). The fix routes rem lines through the same
# character scan + is_echo_open-style stack tracking echo lines already get.
def test_paren_split_across_rem_lines_inside_block_is_flagged(tmp_path, capsys):
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "if defined HP_NO_INTERPRETER (\r\n"
        "  rem method (uv, conda, a fresh download, a\r\n"
        "  rem local virtual environment) failed -- usually\r\n"
        "  exit /b 0\r\n"
        ")\r\n"
        "echo done\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 1
    assert "does not close until line" in captured.out
    assert "counts parens in rem text too" in captured.out


def test_paren_split_across_rem_lines_at_top_level_is_not_flagged(tmp_path, capsys):
    # Same textual pattern as above, but with no enclosing if/for block -- a real
    # instance of this shape exists in run_setup.bat's own file header (a top-level
    # "rem" block, no enclosing bracket) and must not false-positive, mirroring the
    # existing top-level-echo negative case above.
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "rem  and it exited with an error just now (see the status line\r\n"
        "rem  above) -- so we cannot tell what happened.\r\n"
        "exit /b 0\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


# derived requirement: two real, necessary correctness bugs found while implementing
# the fix above, both discovered only by running the extended checker against the
# real run_setup.bat (not by reasoning about the fixtures alone) -- each one alone
# was enough to make the rem-line extension actively counterproductive (flagging or
# corrupting far more than it fixed), since real "rem" prose in this heavily-
# documented codebase routinely contains both patterns.
def test_caret_escaped_paren_on_rem_line_is_not_flagged(tmp_path, capsys):
    # cmd.exe's own escape character ('^') in front of a bracket makes it a literal
    # character there, not a real block delimiter -- and '^(' / '^)' is this repo's
    # own established convention for defusing exactly this hazard (see the error
    # message's own suggested fix, and run_setup.bat's real file-header rem block,
    # which uses this pattern extensively). Without this check, the very construct
    # that FIXES the hazard was itself flagged as if it were the hazard.
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "if defined HP_NO_INTERPRETER (\r\n"
        "  rem this file's line endings are Windows ^(CRLF^) by construction\r\n"
        "  rem and enforced elsewhere ^(see the docs^), but a stale copy can differ\r\n"
        "  exit /b 0\r\n"
        ")\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_apostrophe_and_standalone_quote_in_rem_text_do_not_corrupt_paren_tracking(tmp_path, capsys):
    # cmd.exe has no concept of a single-quote string delimiter at all, and rem/echo
    # PROSE text (unlike real code) has no "quoted argument" concept either -- so an
    # ordinary contraction/possessive ("doesn't", "user's") or a standalone '"'
    # describing the quote character itself must never open a persistent "string"
    # that swallows later, unrelated characters (including real parens) until some
    # later, unrelated quote happens to "close" it. Confirmed directly against real
    # run_setup.bat prose ("cmd.exe's", "GitHub's", '...a literal " would close...').
    #
    # derived requirement (CodeRabbit review, PR #449): the original version of this
    # fixture had no '(' or ')' anywhere AFTER the apostrophe/standalone-quote lines,
    # so a REGRESSED implementation that still corrupts string-state tracking (and
    # therefore never resumes normal scanning at all) could pass this test purely by
    # having nothing left to scan. Nested inside a real enclosing block, with a real
    # cross-line rem paren pair immediately afterward that MUST still be flagged --
    # proving the fix genuinely resumes correct paren tracking, not just that it
    # avoids an immediate crash/false-positive on the quote characters themselves.
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "if defined HP_NO_INTERPRETER (\r\n"
        "  rem cmd.exe's own quoting rules mean a literal \" would close the quote.\r\n"
        "  rem This is just an ordinary sentence that doesn't need any escaping here.\r\n"
        "  rem method (uv, conda, a fresh download, a\r\n"
        "  rem local virtual environment) failed -- usually\r\n"
        "  exit /b 0\r\n"
        ")\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 1
    assert "does not close until line" in captured.out
    assert "counts parens in rem text too" in captured.out


def test_tab_delimited_rem_line_inside_block_is_flagged(tmp_path, capsys):
    # derived requirement (CodeRabbit review, PR #449, Major): cmd.exe treats a TAB
    # exactly like a space as the word separator after "rem" -- "rem\tsomething" is
    # just as much a real comment as "rem something". The original REM_LINE_RE-less
    # classifier (a literal "REM " startswith check) missed this: a tab-delimited rem
    # line matched neither the rem branch nor the echo branch, so its parens were
    # scanned WITHOUT prose_kind tagging and a cross-line pair on such a line was
    # silently never flagged. Same fixture shape as
    # test_paren_split_across_rem_lines_inside_block_is_flagged above, but with a tab
    # after "rem" instead of a space, proving both rem-detection call sites recognize
    # it identically.
    bat = tmp_path / "sample.bat"
    bat.write_text(
        "@echo off\r\n"
        "if defined HP_NO_INTERPRETER (\r\n"
        "  rem\tmethod (uv, conda, a fresh download, a\r\n"
        "  rem\tlocal virtual environment) failed -- usually\r\n"
        "  exit /b 0\r\n"
        ")\r\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 1
    assert "does not close until line" in captured.out
    assert "counts parens in rem text too" in captured.out


# derived requirement: a full-repo scan (python tools/check_delimiters.py .) found 24 false
# positives from _check_ps1_boolean_operators across 8 real, already-shipped test files --
# the space_pattern/leading-operator checks only ever looked at the CURRENT physical line for
# an '=' or control keyword, missing that a PowerShell statement can legitimately span multiple
# lines (backtick continuation, natural continuation via a trailing -and/-or, or simply being
# nested inside a bracket opened on an earlier line). These tests are the regression guard for
# the fix (carried "was this statement's context already established" state) and for the
# ORIGINAL hazard the check still must catch: a bare command followed by -and/-or, genuinely
# parsed by PowerShell as an attempt to bind a parameter named -and/-or.
def test_bare_command_followed_by_and_is_still_flagged(tmp_path, capsys):
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text("someCommand -and $x\n", encoding="ascii")
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 1
    assert "PowerShell boolean operator '-and'" in captured.out


def test_leading_or_with_no_preceding_backtick_is_still_flagged(tmp_path, capsys):
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text("-or $x\n", encoding="ascii")
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 1
    assert "cannot begin a statement" in captured.out


def test_and_across_natural_trailing_operator_continuation_is_not_flagged(tmp_path, capsys):
    # Real shape from tests/selfapps_runtime_writeback.ps1: no backtick, no brackets -- the
    # statement continues naturally because each line ends in a trailing -and.
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text(
        "$pass = ($exitCode -eq 0) -and $runtimeExists -and $runtimeValid -and\n"
        "        $noTrailingSpace -and $logContainsWriteback -and\n"
        "        ($secondRunExitCode -eq 0) -and $secondRunMatches -and $secondRunNoWriteback\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_and_inside_bracket_opened_on_earlier_line_is_not_flagged(tmp_path, capsys):
    # Real shape from tests/selfapps_envsmoke.ps1: an if-expression's own {} branch, opened
    # and assigned via '=' two lines above the flagged -and.
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text(
        "$hasExpectedEnv = if ($isUvMode) {\n"
        "    ($hasInterpreter -and ($interpreterPath -match 'x'))\n"
        "} else {\n"
        "    ($hasInterpreter -and ($interpreterPath -match 'y'))\n"
        "}\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_and_inside_scriptblock_from_earlier_line_is_not_flagged(tmp_path, capsys):
    # Real shape from tools/ps-compileall.ps1: a Where-Object scriptblock's own boolean
    # return expression, with no '=' or control keyword anywhere in the scriptblock body.
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text(
        "$files = $allFiles | Where-Object {\n"
        "  $p = $_.FullName\n"
        "  -not ($p -match 'skip') -and ($_.Extension -in $Extensions)\n"
        "}\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_backtick_continued_leading_or_is_not_flagged(tmp_path, capsys):
    # Real shape from tests/selfapps_pyvisa.ps1: explicit backtick continuation, each
    # continuation line starting with -or for readability.
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text(
        "$nisaReasonPass = ($installerRcMatch.Success) `\n"
        "    -or ($log -match 'a') `\n"
        "    -or ($log -match 'b') `\n"
        "    -or ($log -match 'c')\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out


def test_backtick_continued_and_across_multiple_lines_is_not_flagged(tmp_path, capsys):
    # Real shape from tests/selfapps_contract_uv.ps1: assignment on the first line, each
    # backtick-continued line below it carries -and with no '=' of its own.
    ps1 = tmp_path / "sample.ps1"
    ps1.write_text(
        "$pass = $fallbackInjected -and $fallbackLogged -and `\n"
        "        ($fallbackReason -eq 'x') -and `\n"
        "        $uvVenvReady -and `\n"
        "        $lockNonEmpty -and $runtimeValid\n",
        encoding="ascii",
    )
    result = check_delimiters.main([str(ps1)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No delimiter issues found." in captured.out
