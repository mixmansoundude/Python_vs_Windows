from tools import audit_console_messages as acm


def test_normalize_env_var():
    assert acm.normalize('[INFO] Log: %LOG%') == '[INFO] Log: <V>'


def test_normalize_positional_param():
    assert acm.normalize('[ERROR] Workspace path invalid: %~dp0') == '[ERROR] Workspace path invalid: <V>'
    assert acm.normalize('*** Using drag-and-drop file: %~1') == '*** Using drag-and-drop file: <V>'


def test_normalize_for_loop_var():
    assert acm.normalize('[WARN] Repair failed: %%M') == '[WARN] Repair failed: <V>'
    assert acm.normalize('[WARN] zip too small (%%~zS bytes)') == '[WARN] zip too small (<V> bytes)'


def test_normalize_literal_percent_not_consumed_by_later_var():
    # A literal, isolated '%' earlier in the line must not be greedily paired with a
    # real %VAR% later in the same line.
    assert acm.normalize('10% free on %DRIVE%') == '10% free on <V>'


def test_normalize_adjacent_expansions():
    # Realistic adjacent expansions (a separator between them, as always occurs in actual
    # run_setup.bat message text) each normalize independently.
    assert acm.normalize('rc=%RC% size=%SIZE%') == 'rc=<V> size=<V>'


def test_normalize_all_args_param():
    assert acm.normalize('[INFO] Forwarding arguments: %*') == '[INFO] Forwarding arguments: <V>'


def test_extract_records_skips_echo_control_tokens(tmp_path):
    bat = tmp_path / 'run_setup.bat'
    bat.write_text('@echo off\necho.\necho on\necho [INFO] real message\n', encoding='ascii')
    records = acm.extract_records(bat)
    assert records == [(4, '[INFO] real message')]


def test_extract_records_case_insensitive_call_log(tmp_path):
    bat = tmp_path / 'run_setup.bat'
    bat.write_text('CALL :LOG "[INFO] upper case call"\n', encoding='ascii')
    records = acm.extract_records(bat)
    assert records == [(1, '[INFO] upper case call')]


def test_extract_records_skips_redirected_lines(tmp_path):
    bat = tmp_path / 'run_setup.bat'
    bat.write_text(
        'echo not visible >> log.txt\n'
        'call :log "not visible either" >> log.txt\n'
        'echo [INFO] visible line\n',
        encoding='ascii',
    )
    records = acm.extract_records(bat)
    assert records == [(3, '[INFO] visible line')]


def test_extract_records_skips_single_arrow_redirected_lines(tmp_path):
    bat = tmp_path / 'run_setup.bat'
    bat.write_text(
        'echo not visible > log.txt\n'
        'call :log "not visible either" > log.txt\n'
        'echo [INFO] visible line\n',
        encoding='ascii',
    )
    records = acm.extract_records(bat)
    assert records == [(3, '[INFO] visible line')]


def test_extract_records_keeps_ge_symbol_in_message_content(tmp_path):
    # A message containing a literal '>=' comparison (not a shell redirect) must not be
    # mistaken for a redirected line.
    bat = tmp_path / 'run_setup.bat'
    bat.write_text('call :log "[INFO] running (>=30 days since last update)."\n', encoding='ascii')
    records = acm.extract_records(bat)
    assert records == [(1, '[INFO] running (>=30 days since last update).')]


def test_extract_records_keeps_caret_escaped_redirect_of_nested_command(tmp_path):
    # A caret-escaped redirect belongs to a NESTED command (e.g. a powershell subprocess's own
    # stderr), not to this call :log line itself -- it must not cause a skip.
    bat = tmp_path / 'run_setup.bat'
    bat.write_text(
        'for /f "delims=" %%P in (`powershell -Command "1" 2^>nul`) do call :log "[INFO] Value: %%P"\n',
        encoding='ascii',
    )
    records = acm.extract_records(bat)
    assert records == [(1, '[INFO] Value: <V>')]


def test_extract_records_keeps_call_log_with_redirect_on_later_chained_command(tmp_path):
    # A redirect on a LATER command chained via '&' belongs to that command, not to the
    # call :log that already reached the console before the separator -- it must not cause
    # the call :log record to be dropped.
    bat = tmp_path / 'run_setup.bat'
    bat.write_text('call :log "[INFO] visible" & echo hidden > log.txt\n', encoding='ascii')
    records = acm.extract_records(bat)
    assert records == [(1, '[INFO] visible')]


def test_extract_records_skips_call_log_with_redirect_in_same_segment(tmp_path):
    # A redirect immediately after the closing quote, with no intervening command
    # separator, DOES belong to this call :log -- it must still be skipped.
    bat = tmp_path / 'run_setup.bat'
    bat.write_text('call :log "[INFO] hidden" > log.txt\n', encoding='ascii')
    records = acm.extract_records(bat)
    assert records == []


def test_is_covered_true_when_all_segments_present():
    assert acm.is_covered('[INFO] Log: <V>', '... [INFO] Log: C:\\work\\ ...') is True


def test_is_covered_false_when_missing():
    assert acm.is_covered('[WARN] never documented anywhere', 'totally unrelated corpus text') is False


def test_main_reports_error_on_missing_file(tmp_path, capsys):
    missing = tmp_path / 'nope.bat'
    doc = tmp_path / 'demo.md'
    doc.write_text('placeholder', encoding='utf-8')
    result = acm.main(['--file', str(missing), '--demo-doc', str(doc)])
    captured = capsys.readouterr()
    assert result == 2
    assert 'not found' in captured.err


def test_main_reports_error_on_directory_path(tmp_path, capsys):
    doc = tmp_path / 'demo.md'
    doc.write_text('placeholder', encoding='utf-8')
    result = acm.main(['--file', str(tmp_path), '--demo-doc', str(doc)])
    captured = capsys.readouterr()
    assert result == 2
    assert 'not found' in captured.err
