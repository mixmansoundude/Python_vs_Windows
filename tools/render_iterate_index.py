#!/usr/bin/env python3
"""Render iterate diagnostics index for GitHub Pages."""
from __future__ import annotations

import argparse
import datetime as dt
import html
import pathlib
from typing import List, Tuple


def list_artifact_dirs(root: pathlib.Path) -> List[pathlib.Path]:
    if not root.exists():
        return []
    return sorted([p for p in root.iterdir() if p.is_dir()])


def list_files(base: pathlib.Path) -> List[Tuple[str, str]]:
    files: List[Tuple[str, str]] = []
    for path in sorted(base.rglob("*")):
        if path.is_file():
            rel = path.relative_to(base)
            files.append((rel.as_posix(), path.read_text(encoding="utf-8", errors="ignore") if path.stat().st_size < 1024 else ""))
    return files


def build_markdown(artifacts: List[pathlib.Path], repo: str, sha: str, run_id: str, run_attempt: str) -> str:
    lines: List[str] = []
    lines.append(f"# Codex iterate diagnostics for {repo}")
    lines.append("")
    lines.append(f"- Commit: `{sha}`")
    lines.append(f"- Run: [{run_id}](https://github.com/{repo}/actions/runs/{run_id}) (attempt {run_attempt})")
    lines.append(f"- Generated: {dt.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')} UTC")
    lines.append("")

    if not artifacts:
        lines.append("No iterate-diag-* artifacts were found for this run.")
        return "\n".join(lines)

    for art in artifacts:
        lines.append(f"## {art.name}")
        files = list_files(art)
        if not files:
            lines.append("(No files extracted from artifact.)")
            continue
        for rel, _preview in files:
            safe_rel = rel.replace('\\', '/')
            lines.append(f"- [{safe_rel}]({art.name}/{safe_rel})")
        lines.append("")
    return "\n".join(lines)


def markdown_to_html(md_text: str) -> str:
    escaped = html.escape(md_text)
    template = """<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <title>Codex iterate diagnostics</title>
  <style>
    body {{ font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas,
           \"Liberation Mono\", \"Courier New\", monospace; margin: 2rem; }}
    pre {{ white-space: pre-wrap; }}
    a {{ color: #0366d6; }}
  </style>
</head>
<body>
<pre>{content}</pre>
</body>
</html>
"""
    return template.format(content=escaped)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-root", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    args = parser.parse_args()

    artifacts = list_artifact_dirs(pathlib.Path(args.artifacts_root))
    markdown = build_markdown(artifacts, args.repo, args.sha, args.run_id, args.run_attempt)

    out_dir = pathlib.Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "index.md").write_text(markdown, encoding="utf-8")
    (out_dir / "index.html").write_text(markdown_to_html(markdown), encoding="utf-8")
    (out_dir / ".nojekyll").write_text("", encoding="utf-8")


if __name__ == "__main__":
    main()
