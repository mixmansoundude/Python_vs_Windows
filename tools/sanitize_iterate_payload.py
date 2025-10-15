#!/usr/bin/env python3
"""Redact and truncate iterate payload files per diagnostics contract."""
from __future__ import annotations

import argparse
import json
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--truncate", type=int, default=0)
    parser.add_argument("--redact-pattern", default="", help="case-insensitive regex for keys/values to redact")
    parser.add_argument("--placeholder", default="***")
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
