#!/usr/bin/env python3
"""Summarize batch-check failures without relying on PowerShell."""

from __future__ import annotations

import json
import os
from collections import defaultdict, deque
from collections.abc import Iterable as IterableABC
from pathlib import Path
from typing import Any, Iterable


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} environment variable is required.")
    return value


def _trimmed_lines(path: Path) -> Iterable[str]:
    try:
        for raw in path.read_text(encoding='utf-8').splitlines():
            line = raw.strip()
            if line:
                yield line
    except FileNotFoundError:
        return


def _collect_failures_from_ndjson(batch_root: Path, ndjson_files: Iterable[Path]) -> tuple[list[str], list[str]]:
    collected: list[str] = []
    per_file: dict[str, set[str]] = defaultdict(set)

    for file_path in ndjson_files:
        try:
            text = file_path.read_text(encoding='utf-8')
        except FileNotFoundError:
            continue

        for raw_line in text.splitlines():
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                payload = json.loads(raw_line)
            except json.JSONDecodeError:
                continue

            failure_id = _extract_failure_id(payload)
            if failure_id:
                collected.append(failure_id)
                key = str(file_path.relative_to(batch_root)) if file_path.is_relative_to(batch_root) else file_path.as_posix()
                per_file[key].add(failure_id)

    debug_lines: list[str] = []
    if per_file:
        for rel_path in sorted(per_file):
            unique_count = len(per_file[rel_path])
            debug_lines.append(f"fallback:{rel_path.replace('\\', '/') }\t{unique_count}")
    return collected, debug_lines


def _extract_failure_id(payload: Any) -> str | None:
    stack: deque[Any] = deque([payload])
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
                if lowered == 'outcome':
                    if isinstance(value, str) and value == 'failed':
                        has_failure = True
                elif lowered == 'nodeid':
                    if node_id is None and value:
                        node_id = str(value)
                elif lowered == 'name':
                    if name_val is None and value:
                        name_val = str(value)

                if value is None or isinstance(value, str):
                    continue
                if isinstance(value, dict):
                    stack.append(value)
                elif isinstance(value, IterableABC):
                    stack.extend(item for item in value)
        elif isinstance(current, IterableABC) and not isinstance(current, str):
            stack.extend(item for item in current)

    if not has_failure:
        return None
    return node_id or name_val


def main() -> None:
    diag_root = Path(_require_env('DIAG'))
    batch_root = diag_root / '_artifacts' / 'batch-check'
    target = diag_root / 'batchcheck_failing.txt'
    debug_target = diag_root / 'batchcheck_fail-debug.txt'

    collected: list[str] = []
    debug_lines: list[str] = []

    if batch_root.exists():
        for artifact in sorted(batch_root.rglob('failing-tests.txt')):
            for line in _trimmed_lines(artifact):
                collected.append(line)

        for debug_path in sorted(batch_root.rglob('fail-debug.txt')):
            rel = debug_path.relative_to(batch_root).as_posix()
            debug_lines.append(f"# {rel}")
            try:
                debug_text = debug_path.read_text(encoding='utf-8')
            except FileNotFoundError:
                debug_lines.append('(missing)')
            else:
                debug_lines.extend(debug_text.splitlines())
            debug_lines.append('')

    if not collected:
        ndjson_files = sorted(batch_root.rglob('*.ndjson')) if batch_root.exists() else []
        fallback_values, fallback_debug = _collect_failures_from_ndjson(batch_root, ndjson_files)
        collected.extend(fallback_values)
        if fallback_debug:
            debug_lines.extend(fallback_debug)
        elif not debug_lines:
            debug_lines.append('fallback: no ndjson located')

    final: list[str]
    if collected:
        unique = sorted(set(collected))
        if len(unique) > 1 and 'none' in unique:
            unique = [value for value in unique if value != 'none']
        final = unique or ['none']
    else:
        final = ['none']

    target.write_text('\n'.join(final) + '\n', encoding='utf-8')

    if not debug_lines:
        debug_lines.append('none')
    debug_target.write_text('\n'.join(debug_lines).rstrip() + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
