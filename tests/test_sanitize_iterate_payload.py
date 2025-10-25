import json
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent


def _write_common_files(tmp_path: Path) -> tuple[Path, Path, Path]:
    diff_path = tmp_path / "diff.txt"
    diff_path.write_text("# no changes\n", encoding="utf-8")

    raw_json_path = tmp_path / "response.json"
    raw_json_path.write_text(json.dumps({"output": []}), encoding="utf-8")

    diag_root = tmp_path / "diag"
    diag_root.mkdir()
    (diag_root / "batchcheck_failing.txt").write_text(
        "case-1\ncase-2\n", encoding="utf-8"
    )

    return raw_json_path, diff_path, diag_root


def _run_sanitizer(
    tmp_path: Path,
    raw_json_path: Path,
    diff_path: Path,
    response_text: str,
    diag_root: Path,
    pattern: str,
    placeholder: str,
) -> Path:
    response_text_path = tmp_path / "response.txt"
    response_text_path.write_text(response_text, encoding="utf-8")

    why_path = tmp_path / "why_no_diff.txt"
    output_path = tmp_path / "out.json"

    cmd = [
        sys.executable,
        "tools/sanitize_iterate_payload.py",
        "--input",
        str(raw_json_path),
        "--output",
        str(output_path),
        "--why-output",
        str(why_path),
        "--diff-path",
        str(diff_path),
        "--response-text",
        str(response_text_path),
        "--diag-root",
        str(diag_root),
        "--redact-pattern",
        pattern,
        "--placeholder",
        placeholder,
    ]
    subprocess.run(cmd, check=True, cwd=REPO_ROOT)
    return why_path


def test_summary_text_rationale_is_redacted(tmp_path):
    raw_json_path, diff_path, diag_root = _write_common_files(tmp_path)
    response_text = """```summary_text
Line 1
Contains token: sk-THISISFAKEBUTLONGENOUGH
password=abc123
secret hint
```
"""
    why_path = _run_sanitizer(
        tmp_path,
        raw_json_path,
        diff_path,
        response_text,
        diag_root,
        "(?i)(secret|token|password|apikey|key|sk-[A-Za-z0-9]{20,})",
        "***",
    )
    payload = why_path.read_text(encoding="utf-8")

    assert payload.splitlines()[0] == "Model rationale (summary_text):"
    assert "***" in payload
    assert "sk-THISISFAKEBUTLONGENOUGH" not in payload
    assert "password=abc123" not in payload


def test_fallback_rationale_uses_fail_ids_and_redacts(tmp_path):
    raw_json_path, diff_path, diag_root = _write_common_files(tmp_path)
    (diag_root / "batchcheck_failing.txt").write_text(
        "run-1\ncontains token sk-THISISFAKEBUTLONGENOUGH\n",
        encoding="utf-8",
    )
    response_text = "No summary block here."
    why_path = _run_sanitizer(
        tmp_path,
        raw_json_path,
        diff_path,
        response_text,
        diag_root,
        "(?i)(secret|token|password|apikey|key|sk-[A-Za-z0-9]{20,})",
        "***",
    )
    payload = why_path.read_text(encoding="utf-8")

    assert "Model returned # no changes" in payload.splitlines()[0]
    assert "***" in payload
    assert "sk-THISISFAKEBUTLONGENOUGH" not in payload
    assert "contains token" not in payload
