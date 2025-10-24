#!/usr/bin/env python3
"""Summarize failing tests for diagnostics publishing."""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Iterable, List, Optional


def _require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise SystemExit(f"{name} environment variable is required.")
    return value


def _iter_lines(path: Path) -> Iterable[str]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                yield line.rstrip("\n\r")
    except FileNotFoundError:
        return


def _collect_from_artifacts(batch_root: Path, collected: List[str], debug_lines: List[str]) -> None:
    if not batch_root.is_dir():
        return

    for artifact in batch_root.rglob("failing-tests.txt"):
        for line in _iter_lines(artifact):
            value = line.strip()
            if value:
                collected.append(value)

    for debug in batch_root.rglob("fail-debug.txt"):
        try:
            rel = debug.relative_to(batch_root).as_posix()
        except ValueError:
            rel = debug.as_posix()
        debug_lines.append(f"# {rel}")
        debug_lines.extend(_iter_lines(debug))
        debug_lines.append("")


def _extract_failure_id(root: object) -> Optional[str]:
    if root is None:
        return None

    stack = [root]
    has_failure = False
    node_id: Optional[str] = None
    name_val: Optional[str] = None

    while stack:
        current = stack.pop()
        if current is None:
            continue

        if isinstance(current, dict):
            for key, value in current.items():
                if not key:
                    continue
                if isinstance(key, str) and key.lower() == "outcome":
                    if isinstance(value, str) and value == "failed":
                        has_failure = True
                elif isinstance(key, str) and key.lower() == "nodeid":
                    if node_id is None and value:
                        node_id = str(value)
                elif isinstance(key, str) and key.lower() == "name":
                    if name_val is None and value:
                        name_val = str(value)

                if isinstance(value, (dict, list, tuple, set)):
                    stack.append(value)
                elif value is not None and not isinstance(value, (str, bytes)):
                    try:
                        iterator = iter(value)  # type: ignore[arg-type]
                    except TypeError:
                        continue
                    else:
                        stack.extend(list(iterator))
        elif isinstance(current, (list, tuple, set)):
            stack.extend(reversed(list(current)))

    if not has_failure:
        return None
    if node_id:
        return node_id
    return name_val


def _fallback_ndjson(batch_root: Path, collected: List[str], debug_lines: List[str]) -> None:
    if not batch_root.is_dir():
        return

    per_file: dict[str, List[str]] = {}
    ndjson_files = sorted(batch_root.rglob("*.ndjson"))
    for file in ndjson_files:
        try:
            rel = file.relative_to(batch_root).as_posix()
        except ValueError:
            rel = file.as_posix()
        per_file.setdefault(rel, [])
        for line in _iter_lines(file):
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            failure_id = _extract_failure_id(obj)
            if failure_id:
                collected.append(failure_id)
                per_file.setdefault(rel, []).append(failure_id)

    if per_file:
        for rel, ids in sorted(per_file.items()):
            unique_count = len(sorted(set(ids))) if ids else 0
            debug_lines.append(f"fallback:{rel}\t{unique_count}")
    elif not debug_lines:
        debug_lines.append("fallback: no ndjson located")


def main() -> None:
    diag_root = Path(_require_env("DIAG"))
    batch_root = diag_root / "_artifacts" / "batch-check"
    target = diag_root / "batchcheck_failing.txt"
    debug_target = diag_root / "batchcheck_fail-debug.txt"

    collected: List[str] = []
    debug_lines: List[str] = []

    _collect_from_artifacts(batch_root, collected, debug_lines)

    if not collected:
        _fallback_ndjson(batch_root, collected, debug_lines)

    final = sorted(set(collected))
    if len(final) > 1 and "none" in final:
        final = [item for item in final if item != "none"]
    if not final:
        final = ["none"]

    target.write_text("\n".join(final), encoding="utf-8")

    if not debug_lines:
        debug_lines.append("none")
    debug_target.write_text("\n".join(debug_lines), encoding="utf-8")


if __name__ == "__main__":
    main()
