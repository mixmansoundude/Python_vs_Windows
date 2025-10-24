#!/usr/bin/env python3
"""Summarize failing tests for diagnostics publishing."""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Dict, Iterable, List, Optional


_PLACEHOLDER = "none"


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
            if value and value.lower() != _PLACEHOLDER:
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


def _ndjson_segments(raw: str) -> List[str]:
    """Split concatenated JSON objects without disturbing braces inside strings."""

    segments: List[str] = []
    if not raw:
        return segments

    builder: List[str] = []
    depth = 0
    in_string = False
    escape_next = False

    for ch in raw:
        if in_string:
            builder.append(ch)
            if escape_next:
                escape_next = False
            elif ch == "\\":
                escape_next = True
            elif ch == '"':
                in_string = False
            continue

        if ch == '"':
            builder.append(ch)
            in_string = True
        elif ch == "{":
            builder.append(ch)
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
            builder.append(ch)
            if depth == 0 and builder:
                segment = "".join(builder).strip()
                if segment:
                    segments.append(segment)
                builder.clear()
        else:
            if depth > 0:
                builder.append(ch)
            # Ignore whitespace between objects when depth == 0.

    if builder:
        tail = "".join(builder).strip()
        if tail:
            segments.append(tail)

    return segments


def _fallback_ndjson(batch_root: Path, collected: List[str], debug_lines: List[str]) -> None:
    if not batch_root.is_dir():
        return

    per_file: Dict[str, List[str]] = {}
    ndjson_files = sorted(batch_root.rglob("*.ndjson"))

    for file in ndjson_files:
        try:
            rel = file.relative_to(batch_root).as_posix()
        except ValueError:
            rel = file.as_posix()
        per_file.setdefault(rel, [])

        try:
            raw = file.read_text(encoding="utf-8")
        except OSError:
            continue

        segments = _ndjson_segments(raw)
        for segment in segments:
            line = segment.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            failed = False
            name: Optional[str] = None

            legacy_id = _extract_failure_id(obj)
            if legacy_id:
                failed = True
                name = legacy_id

            if not failed:
                if "pass" in obj:
                    value = obj["pass"]
                    if isinstance(value, bool) and not value:
                        failed = True
                    elif isinstance(value, str) and value.lower() == "false":
                        failed = True
                if not failed and "status" in obj:
                    status = obj["status"]
                    if isinstance(status, str) and status.lower() in {"fail", "failure"}:
                        failed = True
                if failed:
                    if isinstance(obj.get("id"), str) and obj["id"].strip():
                        name = obj["id"].strip()
                    elif isinstance(obj.get("desc"), str) and obj["desc"].strip():
                        name = obj["desc"].strip()

            if failed and name:
                collected.append(name)
                per_file[rel].append(name)

    if per_file:
        for rel, ids in sorted(per_file.items()):
            unique_count = len({value for value in ids if value})
            debug_lines.append(f"fallback:{rel}\t{unique_count}")
    elif not debug_lines:
        debug_lines.append("fallback: no ndjson located")


def generate_fail_list(diag_root: Path) -> None:
    """Write batch-check fail lists under *diag* using staged artifacts."""

    batch_root = diag_root / "_artifacts" / "batch-check"
    target = diag_root / "batchcheck_failing.txt"
    debug_target = diag_root / "batchcheck_fail-debug.txt"

    collected: List[str] = []
    debug_lines: List[str] = []

    _collect_from_artifacts(batch_root, collected, debug_lines)

    if not collected:
        # Professional note: legacy bundles only expose NDJSON. Re-running the
        # brace-aware scan here mirrors the PowerShell extractor so publisher
        # runs stay consistent regardless of platform availability.
        _fallback_ndjson(batch_root, collected, debug_lines)

    unique = sorted({item for item in collected if item})
    real_items = [item for item in unique if item.lower() != _PLACEHOLDER]
    final = real_items or (unique if unique else [_PLACEHOLDER])

    target.parent.mkdir(parents=True, exist_ok=True)
    text = "\n".join(final)
    try:
        existing = target.read_text(encoding="utf-8")
    except OSError:
        existing = None
    if existing != text:
        target.write_text(text, encoding="utf-8")

    # Professional note: CI can drop placeholder "none" files into artifacts before
    # this publisher reruns the extractor. Synchronizing the staged copies keeps the
    # mirrors, artifact browsing, and canonical file aligned so future refactors do
    # not reintroduce stale previews.
    artifacts_root = diag_root / "_artifacts"
    synced = 0
    if artifacts_root.exists():
        for candidate in artifacts_root.rglob("failing-tests.txt"):
            try:
                current = candidate.read_text(encoding="utf-8")
            except OSError:
                current = None
            if current == text:
                continue
            try:
                candidate.write_text(text, encoding="utf-8")
            except OSError:
                continue
            synced += 1
    if synced:
        print(f"[ndjson_fail_list] synced {synced} artifact fail-list file(s)")

    if not debug_lines:
        debug_lines.append(_PLACEHOLDER)
    debug_target.parent.mkdir(parents=True, exist_ok=True)
    debug_target.write_text("\n".join(debug_lines), encoding="utf-8")


def main() -> None:
    diag_root = Path(_require_env("DIAG"))
    generate_fail_list(diag_root)


if __name__ == "__main__":
    main()
