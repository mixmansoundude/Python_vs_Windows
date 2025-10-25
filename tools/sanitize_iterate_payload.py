#!/usr/bin/env python3
"""Redact and truncate iterate payload files per diagnostics contract."""
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path


def _redact(obj, pattern: re.Pattern, placeholder: str):
    if isinstance(obj, dict):
        return {
            key: (placeholder if pattern.search(key) else _redact(value, pattern, placeholder))
            for key, value in obj.items()
        }
    if isinstance(obj, list):
        return [_redact(item, pattern, placeholder) for item in obj]
    if isinstance(obj, str) and pattern.search(obj):
        return placeholder
    return obj


def sanitize_text(text: str, limit: int) -> str:
    if limit > 0 and len(text) > limit:
        note = f"\n... [truncated after {limit} characters]\n"
        return text[:limit] + note
    return text


SUMMARY_BLOCK = re.compile(r"```summary_text\s*\r?\n(?P<body>.*?)(?:\r?\n```|```)", re.DOTALL | re.IGNORECASE)


def _extract_response_text(raw_json: str, response_text_path: Path | None) -> str:
    if response_text_path and response_text_path.exists():
        return response_text_path.read_text(encoding="utf-8", errors="replace")

    try:
        data = json.loads(raw_json)
    except json.JSONDecodeError:
        return ""

    if not isinstance(data, dict):
        return ""

    text_value = data.get("output_text")
    if isinstance(text_value, str) and text_value.strip():
        return text_value

    outputs = data.get("output")
    if not isinstance(outputs, list):
        return ""

    pieces: list[str] = []
    for entry in outputs:
        if not isinstance(entry, dict):
            continue
        content = entry.get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            text = item.get("text")
            if isinstance(text, str) and text:
                pieces.append(text)

    combined = "\n".join(pieces)
    return combined


def _extract_summary_lines(response_text: str) -> list[str]:
    if not response_text:
        return []

    match = SUMMARY_BLOCK.search(response_text)
    if not match:
        return []

    body = match.group("body")
    lines = [line.rstrip() for line in body.splitlines()]
    # Trim trailing blanks that do not add signal.
    while lines and not lines[-1]:
        lines.pop()
    return lines[:10]


def _discover_fail_list(diag_root: Path | None) -> Path | None:
    candidates: list[Path] = []
    if diag_root:
        candidates.append(diag_root)

    workspace = os.environ.get("GITHUB_WORKSPACE")
    if workspace:
        workspace_path = Path(workspace)
        candidates.append(workspace_path / "diag")
        candidates.append(workspace_path)

    runner_temp = os.environ.get("RUNNER_TEMP")
    if runner_temp:
        candidates.append(Path(runner_temp))

    seen: set[str] = set()
    for base in candidates:
        try:
            resolved = base.resolve()
        except OSError:
            continue

        key = str(resolved)
        if key in seen or not resolved.exists():
            continue
        seen.add(key)

        direct = resolved / "batchcheck_failing.txt"
        if direct.exists():
            return direct

        try:
            found = next(resolved.rglob("batchcheck_failing.txt"))
        except StopIteration:
            continue
        else:
            return found

    return None


def _load_fail_ids(diag_root: Path | None) -> list[str]:
    path = _discover_fail_list(diag_root)
    if not path:
        return []

    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []

    entries: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped:
            entries.append(stripped)
        if len(entries) >= 10:
            break
    return entries


def _maybe_write_why(
    raw_json: str,
    why_path: Path,
    diff_path: Path | None,
    response_text_path: Path | None,
    diag_root: Path | None,
    pattern: re.Pattern | None,
    placeholder: str,
) -> None:
    if not diff_path or not diff_path.exists():
        return

    try:
        diff_content = diff_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return

    if diff_content.strip() != "# no changes":
        return

    if why_path.exists():
        try:
            first = why_path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            first = []
        if first:
            head = first[0].strip()
            if head and head != "model returned # no changes":
                # Preserve upstream status markers (HTTP failures, gating skips, etc.) so the
                # rationale writer only replaces the placeholder "model returned # no changes".
                return

    response_text = _extract_response_text(raw_json, response_text_path)
    summary_lines = _extract_summary_lines(response_text)

    if summary_lines:
        payload_lines = ["Model rationale (summary_text):", *summary_lines]
    else:
        payload_lines = [
            "Model returned # no changes and did not provide summary_text.",
        ]
        fail_ids = _load_fail_ids(diag_root)
        if fail_ids:
            payload_lines.append("")
            payload_lines.append("First failing IDs from batchcheck_failing.txt:")
            payload_lines.extend(f"- {item}" for item in fail_ids)
        else:
            payload_lines.append("")
            payload_lines.append("First failing IDs unavailable; batchcheck_failing.txt not found.")

    payload = "\n".join(payload_lines).rstrip() + "\n"
    if pattern is not None:
        # derived requirement: reviewer flagged raw rationale leaking secrets when
        # ``_maybe_write_why`` bypassed the sanitizer. Keep the payload aligned with
        # ``--redact-pattern`` so diagnostics never surface unmasked secrets.
        payload = pattern.sub(placeholder, payload)
    why_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        why_path.write_text(payload, encoding="utf-8", errors="replace")
    except OSError:
        pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--truncate", type=int, default=0)
    parser.add_argument("--redact-pattern", default="", help="case-insensitive regex for keys/values to redact")
    parser.add_argument("--placeholder", default="***")
    parser.add_argument("--why-output", default="")
    parser.add_argument("--diff-path", default="")
    parser.add_argument("--response-text", default="")
    parser.add_argument("--diag-root", default="")
    args = parser.parse_args()

    src = Path(args.input)
    dest = Path(args.output)
    dest.parent.mkdir(parents=True, exist_ok=True)

    if not src.exists():
        dest.write_text("missing\n", encoding="utf-8")
        return 0

    text = src.read_text(encoding="utf-8", errors="replace")
    pattern = re.compile(args.redact_pattern) if args.redact_pattern else None
    rendered = text

    if pattern is not None:
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            data = None
        if data is not None:
            redacted = _redact(data, pattern, args.placeholder)
            rendered = json.dumps(redacted, indent=2, ensure_ascii=False)
        else:
            rendered = pattern.sub(args.placeholder, text)

    rendered = sanitize_text(rendered, args.truncate)
    dest.write_text(rendered, encoding="utf-8")

    if args.why_output:
        why_path = Path(args.why_output)
        diff_path = Path(args.diff_path) if args.diff_path else None
        response_path = Path(args.response_text) if args.response_text else None
        diag_root = Path(args.diag_root) if args.diag_root else None
        _maybe_write_why(
            text,
            why_path,
            diff_path,
            response_path,
            diag_root,
            pattern,
            args.placeholder,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
