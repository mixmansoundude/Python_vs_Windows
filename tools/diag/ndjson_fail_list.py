#!/usr/bin/env python3
"""Summarize failing tests for diagnostics bundles.

This mirrors the behavior of ``tools/diag/ndjson_fail_list.ps1`` so the
workflow can execute on Ubuntu where PowerShell quoting previously broke.
"""
from __future__ import annotations

import json
import os
from collections import defaultdict
from pathlib import Path
from typing import Any, List
from collections.abc import Iterable


def _extract_failure_identifier(root: Any) -> str | None:
    """Traverse a JSON fragment looking for a failed test identifier."""
    stack: List[Any] = [root]
    has_failure = False
    node_id: str | None = None
    name_val: str | None = None

    while stack:
        current = stack.pop()
        if current is None:
            continue

        if isinstance(current, dict):
            for key, value in current.items():
                if not key:
                    continue
                lower = key.lower()
                if lower == "outcome":
                    if isinstance(value, str) and value == "failed":
                        has_failure = True
                elif lower == "nodeid":
                    if node_id is None and value not in (None, ""):
                        node_id = str(value)
                elif lower == "name":
                    if name_val is None and value not in (None, ""):
                        name_val = str(value)
                if value is not None and not isinstance(value, (str, bytes)):
                    stack.append(value)
        elif isinstance(current, (list, tuple, set)):
            stack.extend(current)
        elif isinstance(current, Iterable) and not isinstance(current, (str, bytes)):
            stack.extend(list(current))

    if not has_failure:
        return None
    return node_id or name_val


def main() -> None:
    diag = os.environ.get("DIAG")
    if not diag:
        raise SystemExit("DIAG environment variable is required")

    diag_path = Path(diag)
    batch_root = diag_path / "_artifacts" / "batch-check"
    target = diag_path / "batchcheck_failing.txt"
    debug_target = diag_path / "batchcheck_fail-debug.txt"

    collected: List[str] = []
    debug_lines: List[str] = []

    if batch_root.exists():
        for artifact in batch_root.rglob("failing-tests.txt"):
            for raw in artifact.read_text(encoding="utf-8").splitlines():
                line = raw.strip()
                if line:
                    collected.append(line)

        for debug in batch_root.rglob("fail-debug.txt"):
            rel = debug.relative_to(batch_root)
            debug_lines.append(f"# {rel.as_posix()}")
            debug_lines.extend(debug.read_text(encoding="utf-8").splitlines())
            debug_lines.append("")

    if not collected:
        ndjson_files = list(batch_root.rglob("*.ndjson")) if batch_root.exists() else []
        per_file: dict[str, List[str]] = defaultdict(list)

        for file_path in ndjson_files:
            rel = file_path.relative_to(batch_root)
            for line in file_path.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                try:
                    parsed = json.loads(line)
                except json.JSONDecodeError:
                    continue
                identifier = _extract_failure_identifier(parsed)
                if identifier:
                    collected.append(identifier)
                    per_file[rel.as_posix()].append(identifier)

        if per_file:
            for rel, ids in sorted(per_file.items()):
                count = len(sorted(set(ids)))
                debug_lines.append(f"fallback:{rel}\t{count}")
        elif not debug_lines:
            debug_lines.append("fallback: no ndjson located")

    final = sorted(set(collected)) if collected else []
    if len(final) > 1 and "none" in final:
        final = [entry for entry in final if entry != "none"]

    if not final:
        final = ["none"]

    target.write_text("\n".join(final) + "\n", encoding="utf-8")

    if not debug_lines:
        debug_lines.append("none")
    debug_target.write_text("\n".join(debug_lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
