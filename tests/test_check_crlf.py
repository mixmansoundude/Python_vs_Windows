from tools import check_crlf


def test_find_bad_lines_pure_crlf_is_clean():
    data = b"line one\r\nline two\r\nline three\r\n"
    assert check_crlf.find_bad_lines(data) == []


def test_find_bad_lines_detects_bare_lf():
    data = b"line one\r\nline two\nline three\r\n"
    assert check_crlf.find_bad_lines(data) == [2]


def test_find_bad_lines_detects_bare_cr():
    data = b"line one\r\nline two\rline three\r\n"
    assert check_crlf.find_bad_lines(data) == [2]


def test_find_bad_lines_multiple_offenders():
    data = b"ok\r\nbad\nalso bad\nok\r\n"
    assert check_crlf.find_bad_lines(data) == [2, 3]


def test_normalize_to_crlf_from_pure_lf():
    data = b"a\nb\nc\n"
    assert check_crlf.normalize_to_crlf(data) == b"a\r\nb\r\nc\r\n"


def test_normalize_to_crlf_from_mixed():
    data = b"a\r\nb\nc\rd\r\n"
    assert check_crlf.normalize_to_crlf(data) == b"a\r\nb\r\nc\r\nd\r\n"


def test_normalize_to_crlf_is_idempotent():
    data = b"a\r\nb\nc\rd\r\n"
    once = check_crlf.normalize_to_crlf(data)
    twice = check_crlf.normalize_to_crlf(once)
    assert once == twice
    assert check_crlf.find_bad_lines(twice) == []


def test_fix_file_rewrites_and_verifies(tmp_path):
    bat = tmp_path / "sample.bat"
    bat.write_bytes(b"@echo off\nrem hello\n")

    changed = check_crlf.fix_file(bat)

    assert changed is True
    fixed_bytes = bat.read_bytes()
    assert fixed_bytes == b"@echo off\r\nrem hello\r\n"
    assert check_crlf.find_bad_lines(fixed_bytes) == []
    # No leftover temp file from the safe-write pattern.
    assert not (tmp_path / "sample.bat.crlf_tmp").exists()


def test_fix_file_is_a_noop_when_already_clean(tmp_path):
    bat = tmp_path / "sample.bat"
    bat.write_bytes(b"@echo off\r\nrem hello\r\n")

    changed = check_crlf.fix_file(bat)

    assert changed is False
    assert bat.read_bytes() == b"@echo off\r\nrem hello\r\n"


def test_main_check_mode_reports_and_exits_nonzero(tmp_path, capsys):
    bat = tmp_path / "sample.bat"
    bat.write_bytes(b"@echo off\nrem hello\r\n")

    result = check_crlf.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 1
    assert "non-CRLF line ending" in captured.out
    assert "--fix" in captured.out
    # Check mode must never modify the file.
    assert bat.read_bytes() == b"@echo off\nrem hello\r\n"


def test_main_fix_mode_rewrites_and_exits_zero(tmp_path, capsys):
    bat = tmp_path / "sample.bat"
    bat.write_bytes(b"@echo off\nrem hello\r\n")

    result = check_crlf.main(["--fix", str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "fixed" in captured.out
    assert bat.read_bytes() == b"@echo off\r\nrem hello\r\n"


def test_main_clean_file_reports_ok(tmp_path, capsys):
    bat = tmp_path / "sample.bat"
    bat.write_bytes(b"@echo off\r\nrem hello\r\n")

    result = check_crlf.main([str(bat)])
    captured = capsys.readouterr()

    assert result == 0
    assert "OK" in captured.out


def test_main_ignores_non_bat_files(tmp_path, capsys):
    py = tmp_path / "sample.py"
    py.write_bytes(b"print('hi')\n")

    result = check_crlf.main([str(py)])
    captured = capsys.readouterr()

    assert result == 0
    assert "No .bat/.cmd files found" in captured.out
