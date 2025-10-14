#!/usr/bin/env python3
"""Render Markdown and HTML listings for Codex iterate diagnostics."""

from __future__ import annotations

import argparse
import datetime as _dt
import html
from pathlib import Path
from typing import Iterable


def _collect_files(base: Path) -> list[Path]:
    files: list[Path] = []
    for path in sorted(base.rglob("*")):
        if not path.is_file():
            continue
        if path.name in {"index.html", "index.md", ".nojekyll"}:
            continue
        try:
            rel = path.relative_to(base)
        except ValueError:
            continue
        files.append(rel)
    return files


def _build_markdown(
    repo: str,
    sha: str,
    run_id: str,
    attempt: str,
    generated: str,
    entries: Iterable[Path],
    note: str | None,
) -> str:
    run_url = f"https://github.com/{repo}/actions/runs/{run_id}"
    lines = [
        "# Codex iterate diagnostics",
        "",
        f"- Repo: `{repo}`",
        f"- Commit: `{sha}`",
        f"- Workflow run: [{run_id}]({run_url})",
        f"- Run attempt: {attempt}",
        f"- Generated: {generated}",
        "",
    ]
    if note:
        lines.extend(("## Notes", "", note.strip(), ""))
    lines.append("## Files")
    entries = list(entries)
    if not entries:
        lines.append("- (no diagnostic files captured)")
    else:
        for rel in entries:
            lines.append(f"- [{rel.as_posix()}]({rel.as_posix()})")
    lines.append("")
    return "\n".join(lines)


def _build_html(
    repo: str,
    sha: str,
    run_id: str,
    attempt: str,
    generated: str,
    entries: Iterable[Path],
    note: str | None,
) -> str:
    run_url = f"https://github.com/{repo}/actions/runs/{run_id}"
    esc_repo = html.escape(repo)
    esc_sha = html.escape(sha)
    esc_run_url = html.escape(run_url)
    esc_run_id = html.escape(run_id)
    esc_attempt = html.escape(attempt)
    esc_generated = html.escape(generated)
    parts = [
        "<!doctype html>",
        "<html lang=\"en\">",
        "<head>",
        "  <meta charset=\"utf-8\">",
        "  <title>Codex iterate diagnostics</title>",
        "  <style>body{font-family:ui-sans-serif,system-ui,Segoe UI,Helvetica,Arial,sans-serif;line-height:1.5;margin:24px;}"
        "code{font-family:ui-monospace,Consolas,monospace;background:#f6f8fa;padding:2px 4px;border-radius:4px;}"
        "a{color:#0366d6;text-decoration:none;}a:hover{text-decoration:underline;}ul{padding-left:1.25em;}" 
        "table{border-collapse:collapse;}th,td{padding:4px 8px;border:1px solid #d0d7de;}" 
        "</style>",
        "</head>",
        "<body>",
        "  <h1>Codex iterate diagnostics</h1>",
        "  <p>",
        f"    <strong>Repo:</strong> <code>{esc_repo}</code><br>",
        f"    <strong>Commit:</strong> <code>{esc_sha}</code><br>",
        f"    <strong>Workflow run:</strong> <a href=\"{esc_run_url}\">{esc_run_id}</a><br>",
        f"    <strong>Run attempt:</strong> {esc_attempt}<br>",
        f"    <strong>Generated:</strong> {esc_generated}",
        "  </p>",
    ]
    if note:
        parts.append("  <section>")
        parts.append("    <h2>Notes</h2>")
        parts.append(f"    <p>{html.escape(note.strip())}</p>")
        parts.append("  </section>")
    entries = list(entries)
    parts.append("  <section>")
    parts.append("    <h2>Files</h2>")
    if not entries:
        parts.append("    <p>(no diagnostic files captured)</p>")
    else:
        parts.append("    <ul>")
        for rel in entries:
            rel_posix = html.escape(rel.as_posix())
            parts.append(f"      <li><a href=\"{rel_posix}\">{rel_posix}</a></li>")
        parts.append("    </ul>")
    parts.append("  </section>")
    parts.append("</body>")
    parts.append("</html>")
    parts.append("")
    return "\n".join(parts)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Directory containing staged diagnostics (public root)")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--timestamp", default=None)
    parser.add_argument("--note", default=None)
    args = parser.parse_args()

    output_dir: Path = args.output
    output_dir.mkdir(parents=True, exist_ok=True)

    timestamp = args.timestamp
    if not timestamp:
        timestamp = _dt.datetime.utcnow().isoformat(timespec="seconds") + "Z"

    entries = _collect_files(output_dir)
    markdown = _build_markdown(
        repo=args.repo,
        sha=args.sha,
        run_id=args.run_id,
        attempt=args.attempt,
        generated=timestamp,
        entries=entries,
        note=args.note,
    )
    html_doc = _build_html(
        repo=args.repo,
        sha=args.sha,
        run_id=args.run_id,
        attempt=args.attempt,
        generated=timestamp,
        entries=entries,
        note=args.note,
    )

    (output_dir / "index.md").write_text(markdown, encoding="utf-8")
    (output_dir / "index.html").write_text(html_doc, encoding="utf-8")


if __name__ == "__main__":
    main()
