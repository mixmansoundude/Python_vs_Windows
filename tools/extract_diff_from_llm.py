#!/usr/bin/env python3
"""Extract the first unified diff fenced block from LLM output."""
from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract_diff_from_llm.py <input> <output>")
    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    text = input_path.read_text(encoding="utf-8", errors="replace")
    patterns = [
        r"```diff\s*\n(.*?)\n```",
        r"```\s*diff\s*\n(.*?)\n```",
        r"```[\w-]*\s*\n(.*?)\n```",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, re.DOTALL)
        if match:
            output_path.write_text(match.group(1).strip() + "\n", encoding="utf-8")
            return 0
    output_path.write_text("# no changes\n", encoding="utf-8")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
