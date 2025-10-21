#!/usr/bin/env python3
"""Port of tools/diag/ndjson_fail_list.ps1 for cross-platform diagnostics.

This script intentionally mirrors the PowerShell helper that publishes the
batch-check failure summary. Moving the diagnostics publishing stage to the
Ubuntu runner requires a Python implementation so quoting issues stop blocking
GitHub Actions deployments. The behavior is kept byte-for-byte compatible with
what publish_index.ps1 expected so downstream tooling keeps working.
"""
from __future__ import annotations

import json
import os
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable, List, Sequence


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} environment variable is required.")
    return value


def _read_lines(path: Path) -> List[str]:
    text = path.read_text(encoding="utf-8")
    return [line.strip() for line in text.splitlines()]


def _iter_ndjson_lines(path: Path) -> Iterable[Any]:
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line:
            continue
        try:
            yield json.loads(raw_line)
        except json.JSONDecodeError:
            continue


def _push_iterable(stack: List[Any], value: Any) -> None:
    if value is None:
        return
    if isinstance(value, str):
        return
    if isinstance(value, dict):
        stack.append(value)
        return
    if isinstance(value, (list, tuple, set)):
        stack.extend(value)
        return
    if isinstance(value, Iterable):  # pragma: no cover - defensive parity with PS script
        stack.extend(value)


def _extract_failure_identifier(payload: Any) -> str | None:
    stack: List[Any] = [payload]
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
                lowered = key.lower()
                if lowered == "outcome" and isinstance(value, str):
                    if value == "failed":
                        has_failure = True
                elif lowered == "nodeid" and value and node_id is None:
                    node_id = str(value)
                elif lowered == "name" and value and name_val is None:
                    name_val = str(value)
                _push_iterable(stack, value)
        elif isinstance(current, (list, tuple, set)):
            stack.extend(current)
        elif isinstance(current, Iterable) and not isinstance(current, str):
            stack.extend(list(current))

    if not has_failure:
        return None
    return node_id or name_val


def _ensure_parent(path: Path) -> None:
    if not path.parent.exists():
        path.parent.mkdir(parents=True, exist_ok=True)


def _write_lines(path: Path, lines: Sequence[str]) -> None:
    _ensure_parent(path)
    text = "\n".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text, encoding="utf-8")


def main() -> int:
    diag_root = Path(_require_env("DIAG"))
    batch_root = diag_root / "_artifacts" / "batch-check"
    target = diag_root / "batchcheck_failing.txt"
    debug_target = diag_root / "batchcheck_fail-debug.txt"

    collected: List[str] = []
    debug_lines: List[str] = []

    if batch_root.exists():
        failing_files = sorted(batch_root.rglob("failing-tests.txt"))
        for artifact in failing_files:
            for entry in _read_lines(artifact):
                if entry:
                    collected.append(entry)

        debug_artifacts = sorted(batch_root.rglob("fail-debug.txt"))
        for debug_file in debug_artifacts:
            rel = debug_file.relative_to(batch_root)
            debug_lines.append(f"# {rel.as_posix()}")
            debug_lines.extend(debug_file.read_text(encoding="utf-8").splitlines())
            debug_lines.append("")

    if not collected:
        ndjson_files: List[Path] = []
        if batch_root.exists():
            ndjson_files = sorted(batch_root.rglob("*.ndjson"))

        per_file_values: dict[str, List[str]] = defaultdict(list)

        for ndjson_path in ndjson_files:
            rel = ndjson_path.relative_to(batch_root).as_posix()
            for payload in _iter_ndjson_lines(ndjson_path):
                identifier = _extract_failure_identifier(payload)
                if identifier:
                    collected.append(identifier)
                    per_file_values[rel].append(identifier)

        if per_file_values:
            for rel, ids in sorted(per_file_values.items()):
                count = len(sorted(set(ids)))
                debug_lines.append(f"fallback:{rel}\t{count}")
        elif not debug_lines:
            debug_lines.append("fallback: no ndjson located")

    final: List[str]
    if collected:
        final = sorted(set(collected))
        if len(final) > 1 and "none" in final:
            final = [entry for entry in final if entry != "none"]
        if not final:
            final = ["none"]
    else:
        final = ["none"]

    if not debug_lines:
        debug_lines = ["none"]

    _write_lines(target, final)
    _write_lines(debug_target, debug_lines)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # Professional note: preserve the existing hard-fail semantics.
        print(str(exc), file=sys.stderr)
        sys.exit(1)
