#!/usr/bin/env python3
"""Fallback helper to focus failing job logs when tools/focus_logs.py is missing."""
from __future__ import annotations

import os
from pathlib import Path

def main() -> None:
    extract_dir = Path(os.environ.get("EXTRACT_DIR", ""))
    output_path = Path(os.environ.get("FOCUS_OUTPUT", ""))
    if not extract_dir or not extract_dir.exists() or not output_path:
        return
    largest: tuple[int, Path] | None = None
    for path in extract_dir.rglob("*.txt"):
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if largest is None or size > largest[0]:
            largest = (size, path)
    if not largest:
        return
    data = largest[1].read_text(encoding="utf-8", errors="replace").splitlines()[-200:]
    output_path.write_text("\n".join(data) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()
