#!/usr/bin/env python3
"""Build Codex iterate prompt from collected diagnostics."""
from __future__ import annotations

import argparse
import json
import pathlib
from typing import Iterable

MAX_PER_FILE_CHARS = 6000
MAX_FILES = 40


def iter_files(root: pathlib.Path) -> Iterable[pathlib.Path]:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            yield path


def read_text(path: pathlib.Path) -> str:
    try:
        data = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return "<unreadable>"
    if len(data) > MAX_PER_FILE_CHARS:
        head = data[: MAX_PER_FILE_CHARS // 2]
        tail = data[-MAX_PER_FILE_CHARS // 2 :]
        data = head + "\n...\n" + tail
    return data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", required=True, help="Directory of collected inputs")
    parser.add_argument("--output", required=True, help="Prompt file path")
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--total", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()

    inputs_dir = pathlib.Path(args.inputs)
    prompt_path = pathlib.Path(args.output)

    manifest_path = inputs_dir / "collection_manifest.json"
    manifest = {}
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except Exception:
            manifest = {}

    lines = []
    lines.append("You are Codex. Fix only what failed and avoid speculative edits.")
    lines.append("Read README.md and AGENTS.md before applying changes.")
    lines.append("")
    lines.append(f"Repository: {args.repo}")
    lines.append(f"Branch: {args.branch}")
    lines.append(f"Commit: {args.sha}")
    lines.append(f"Attempt: {args.attempt}/{args.total}")
    lines.append("")
    lines.append("Apply the smallest patch that addresses the concrete CI failures below.")
    lines.append("Return a unified diff wrapped in a single ```diff code block.")
    lines.append("If no changes are required, respond with ```diff\n# no changes\n```.")

    if manifest:
        lines.append("")
        lines.append("----- Upstream diagnostics summary -----")
        summary = {
            key: manifest.get(key)
            for key in [
                "ndjson_found",
                "ndjson_empty",
                "ndjson_any_fail",
                "ndjson_passes",
                "ndjson_fails",
                "summary_first_failure",
                "gate_output_verdict",
            ]
        }
        lines.append(json.dumps(summary, indent=2))

    count = 0
    for path in iter_files(inputs_dir):
        rel = path.relative_to(inputs_dir)
        if rel.name == prompt_path.name:
            continue
        if rel.name.endswith(".zip"):
            continue
        count += 1
        lines.append("")
        lines.append(f"----- {rel} -----")
        lines.append(read_text(path))
        if count >= MAX_FILES:
            lines.append("")
            lines.append("(Truncated additional files to keep prompt compact.)")
            break

    prompt_path.parent.mkdir(parents=True, exist_ok=True)
    prompt_path.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
