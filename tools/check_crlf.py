#!/usr/bin/env python3
"""CRLF byte-uniformity checker/fixer for Windows batch files.

Batch files (.bat/.cmd) are tracked with "-text" in .gitattributes (see
docs/agent-lessons-learned.md's ".bat files: -text, not eol=crlf" entry) -- git performs NO
line-ending conversion for them, so the committed bytes are exactly what a clean-Windows
Prime Directive user gets from a raw download URL. This tool is the enforcement mechanism
that replaces git's own normalization for these files: every line ending must be CRLF, with
no bare LF and no bare CR anywhere in the file. Wired into tools/run_sanity_sweep.sh and a
gating CI step; run standalone with --fix to correct a file before committing.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
from typing import List, Optional, Sequence

TARGET_SUFFIXES = {".bat", ".cmd"}


def default_targets() -> List[pathlib.Path]:
    """Git-tracked .bat/.cmd files -- matches exactly what .gitattributes' "-text" governs."""
    try:
        out = subprocess.run(
            ["git", "ls-files", "*.bat", "*.cmd"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return []
    return [pathlib.Path(line) for line in out.stdout.splitlines() if line.strip()]


def find_bad_lines(data: bytes) -> List[int]:
    """Return 1-based line numbers containing a bare LF or a bare CR (not part of a CRLF pair)."""
    bad: List[int] = []
    line_no = 1
    i = 0
    n = len(data)
    while i < n:
        byte = data[i]
        if byte == 0x0A:  # \n
            prev = data[i - 1] if i > 0 else None
            if prev != 0x0D:
                bad.append(line_no)
            line_no += 1
            i += 1
            continue
        if byte == 0x0D:  # \r
            nxt = data[i + 1] if i + 1 < n else None
            if nxt != 0x0A:
                bad.append(line_no)
            i += 1
            continue
        i += 1
    return bad


def normalize_to_crlf(data: bytes) -> bytes:
    """CRLF -> LF -> CRLF: collapses any mix of line endings to pure CRLF, idempotently."""
    return data.replace(b"\r\n", b"\n").replace(b"\r", b"\n").replace(b"\n", b"\r\n")


def check_file(path: pathlib.Path) -> List[int]:
    return find_bad_lines(path.read_bytes())


def fix_file(path: pathlib.Path) -> bool:
    """Rewrite path with pure CRLF line endings in place. Returns True if changed.

    Safe-write pattern (see docs/agent-lessons-learned.md's "never open a real source file
    in Python 'w' mode as part of a dry run" entry): build the fixed content fully in
    memory, compare against the original, and only write via a temp file plus an atomic
    replace, verified by a fresh read-back -- a partial or failed write can never truncate
    or corrupt the original file.
    """
    original = path.read_bytes()
    fixed = normalize_to_crlf(original)
    if fixed == original:
        return False
    tmp = path.parent / (path.name + ".crlf_tmp")
    tmp.write_bytes(fixed)
    verify = tmp.read_bytes()
    if verify != fixed:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise RuntimeError(f"Verification failed writing {path}; original left untouched.")
    tmp.replace(path)
    return True


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check (or fix) that .bat/.cmd files use CRLF line endings only."
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Files to check. Defaults to every git-tracked *.bat/*.cmd file.",
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Rewrite any file with bad line endings to pure CRLF instead of just reporting.",
    )
    args = parser.parse_args(argv)

    targets = [pathlib.Path(p) for p in args.paths] if args.paths else default_targets()
    targets = [p for p in targets if p.suffix.lower() in TARGET_SUFFIXES and p.is_file()]

    if not targets:
        print("No .bat/.cmd files found to check.")
        return 0

    had_issues = False
    for path in targets:
        bad_lines = check_file(path)
        if not bad_lines:
            continue
        had_issues = True
        if args.fix:
            changed = fix_file(path)
            state = "fixed" if changed else "unchanged"
            print(f"{path}: {len(bad_lines)} non-CRLF line ending(s) -- {state}")
        else:
            preview = ", ".join(str(n) for n in bad_lines[:10])
            more = f" (+{len(bad_lines) - 10} more)" if len(bad_lines) > 10 else ""
            print(f"{path}: {len(bad_lines)} non-CRLF line ending(s) at line(s) {preview}{more}")

    if had_issues and not args.fix:
        print(
            "\nFound non-CRLF line endings. Run with --fix to correct, or see "
            "docs/agent-lessons-learned.md's \".bat files: -text, not eol=crlf\" entry."
        )
        return 1

    if had_issues and args.fix:
        print("\nAll flagged files were rewritten to pure CRLF.")
        return 0

    print(f"OK: {len(targets)} file(s) checked, all pure CRLF.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
