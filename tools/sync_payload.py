#!/usr/bin/env python3
"""Safely re-sync an embedded HP_* base64 payload line in run_setup.bat.

Formalizes a procedure that was previously done ad hoc via one-off inline
Python snippets every time a canonical `tools/*.py`/`tools/*.ps1` source was
edited -- see docs/agent-lessons-learned.md's "Never open a real source file
in Python 'w' mode as part of a 'dry run'" entry for the near-miss (a
careless verification script truncated run_setup.bat to zero bytes) that
motivated writing this as a reusable, defensively-verified tool instead of
repeating the same manual read-encode-splice-write dance by hand each time.

Guarantees this script enforces, unlike a one-off snippet:
  - run_setup.bat is never opened in a write mode -- the new content is built
    entirely in memory first.
  - the target `set "HP_VARNAME=..."` line must exist exactly once, or this
    refuses to proceed.
  - after building the candidate content, a line-by-line diff against the
    original confirms EXACTLY ONE line changed (the target payload line) --
    any other delta aborts with no write.
  - the resulting line is checked against the documented CMD.EXE 8191-
    character hard limit (see docs/agent-lessons-learned.md's "CMD.EXE
    8191-Character Line Limit" entry) before writing; over-budget refuses
    unless --force is passed.
  - the original line's line ending (CRLF, per .gitattributes) is preserved
    exactly; the replacement is written with the same terminator.

Usage:
  python tools/sync_payload.py HP_PYPROJ_DEPS tools/pyproj_deps.py
  python tools/sync_payload.py HP_PYPROJ_DEPS tools/pyproj_deps.py --check
  python tools/sync_payload.py HP_FOO tools/foo.py --batch other_setup.bat

Exit codes:
  0 - in sync (--check) or write succeeded
  1 - out of sync (--check) or a safety guard rejected the write
  2 - usage error (missing file, variable not found, etc.)
"""
from __future__ import annotations

import argparse
import base64
import pathlib
import sys

CMD_LINE_LIMIT = 8191


def find_payload_line(lines: list[bytes], varname: str) -> int:
    prefix = f'set "{varname}='.encode("ascii")
    matches = [i for i, line in enumerate(lines) if line.startswith(prefix)]
    if not matches:
        print(f'error: no line starting with set "{varname}=" found', file=sys.stderr)
        raise SystemExit(2)
    if len(matches) > 1:
        print(f'error: {len(matches)} lines start with set "{varname}=" -- expected exactly 1', file=sys.stderr)
        raise SystemExit(2)
    return matches[0]


def build_new_line(varname: str, b64: bytes, ending: bytes) -> bytes:
    return f'set "{varname}='.encode("ascii") + b64 + b'"' + ending


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("varname", help='HP_* variable name, e.g. HP_PYPROJ_DEPS')
    parser.add_argument("source", help="canonical source file to re-encode (e.g. tools/pyproj_deps.py)")
    parser.add_argument("--batch", default="run_setup.bat", help="path to the batch file (default: run_setup.bat)")
    parser.add_argument("--check", action="store_true", help="report sync status only; never write")
    parser.add_argument("--force", action="store_true", help="write even if the CMD 8191-char budget is exceeded")
    args = parser.parse_args(argv)

    batch_path = pathlib.Path(args.batch)
    source_path = pathlib.Path(args.source)
    if not batch_path.is_file():
        print(f"error: {batch_path} not found", file=sys.stderr)
        return 2
    if not source_path.is_file():
        print(f"error: {source_path} not found", file=sys.stderr)
        return 2

    original = batch_path.read_bytes()
    lines = original.split(b"\n")
    idx = find_payload_line(lines, args.varname)

    old_line = lines[idx]
    ending = b"\r" if old_line.endswith(b"\r") else b""

    new_b64 = base64.b64encode(source_path.read_bytes())
    new_line = build_new_line(args.varname, new_b64, ending)

    prefix = f'set "{args.varname}='.encode("ascii")
    old_b64 = old_line[len(prefix):]
    if old_b64.endswith(b'"' + ending):
        old_b64 = old_b64[: -(1 + len(ending))]

    line_len = len(new_line.rstrip(b"\r\n"))
    margin = CMD_LINE_LIMIT - line_len

    if old_b64 == new_b64:
        print(f"{args.varname}: already in sync with {source_path} (line_len={line_len}, margin={margin})")
        return 0

    if args.check:
        print(f"{args.varname}: OUT OF SYNC with {source_path} (embedded b64 differs)")
        return 1

    if margin < 0 and not args.force:
        print(
            f"error: {args.varname} line would be {line_len} chars, "
            f"{-margin} over the CMD.EXE 8191-char limit. Re-pass --force to override "
            "(not recommended -- shrink the source instead).",
            file=sys.stderr,
        )
        return 1

    new_lines = list(lines)
    new_lines[idx] = new_line
    new_content = b"\n".join(new_lines)

    # Defensive re-verification: confirm the candidate differs from the
    # original in EXACTLY the one line we intended to change, before ever
    # touching disk. This is the core safety property this tool exists for.
    new_split = new_content.split(b"\n")
    old_split = original.split(b"\n")
    if len(new_split) != len(old_split):
        print("error: line count changed unexpectedly; refusing to write", file=sys.stderr)
        return 1
    changed = [i for i in range(len(old_split)) if old_split[i] != new_split[i]]
    if changed != [idx]:
        print(f"error: expected exactly line {idx} to change, but {changed} changed; refusing to write", file=sys.stderr)
        return 1

    batch_path.write_bytes(new_content)
    print(f"{args.varname}: synced with {source_path} (line_len={line_len}, margin={margin})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
