#!/usr/bin/env python3
"""Extract focused failing job logs from a workflow artifact.

This helper mirrors the inline logic previously embedded in
`.github/workflows/codex-auto-iterate.yml` but avoids indentation
hazards when executed through a here-doc.
"""

from __future__ import annotations

import argparse
import os
from collections import deque
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple


TAIL_LENGTH = 200
MAX_MATCHES = 3


def _gather_identifiers(primary: str | None, secondary: str | None) -> List[str]:
    identifiers: List[str] = []
    for raw in (primary, secondary):
        value = (raw or "").strip()
        if value and value not in identifiers:
            identifiers.append(value)
    return identifiers


def _scan_file(path: str, identifiers: Sequence[str]) -> Tuple[bool, List[str]]:
    tail: deque[str] = deque(maxlen=TAIL_LENGTH)
    found = False
    try:
        with open(path, "r", errors="ignore") as handle:
            for line in handle:
                tail.append(line)
                if not found and any(identifier in line for identifier in identifiers):
                    found = True
    except (OSError, UnicodeDecodeError):
        return False, []
    return found, list(tail)


def _iter_matches(extract_dir: str, identifiers: Sequence[str]) -> Iterable[Tuple[str, List[str]]]:
    matches_found = 0
    for root, _dirs, files in os.walk(extract_dir):
        for name in files:
            path = os.path.join(root, name)
            found, tail = _scan_file(path, identifiers)
            if found:
                yield path, tail
                matches_found += 1
                if matches_found >= MAX_MATCHES:
                    return


def _write_output(extract_dir: str, focus_path: Path, matches: Sequence[Tuple[str, List[str]]]) -> None:
    focus_path.parent.mkdir(parents=True, exist_ok=True)
    with focus_path.open("w", encoding="utf-8") as out:
        for idx, (path, tail) in enumerate(matches, start=1):
            rel = os.path.relpath(path, extract_dir)
            out.write(f"===== match {idx}: {rel} =====\n")
            out.writelines(tail)
            if not tail or not tail[-1].endswith("\n"):
                out.write("\n")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Locate log files matching job identifiers")
    parser.add_argument("extract_dir", help="Directory containing extracted log files")
    parser.add_argument("focus_path", help="Output file for focused log snippets")
    parser.add_argument("primary", nargs="?", help="Primary identifier (job id)")
    parser.add_argument("secondary", nargs="?", help="Secondary identifier (job name)")
    args = parser.parse_args(argv)

    extract_dir = args.extract_dir
    focus_path = Path(args.focus_path)

    if not extract_dir or not os.path.isdir(extract_dir):
        return 0

    identifiers = _gather_identifiers(args.primary, args.secondary)
    if not identifiers:
        return 0

    matches = list(_iter_matches(extract_dir, identifiers))
    if not matches:
        if focus_path.exists():
            focus_path.unlink()
        return 0

    _write_output(extract_dir, focus_path, matches)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
