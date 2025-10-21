#!/usr/bin/env python3
"""Diagnostics publisher used by the Ubuntu-based publish_diag job.

The previous workflow invoked PowerShell helpers on Windows. Quoting rules made
those steps brittle, so we reimplemented both publish_index.ps1 and the "Write
site overview" logic in Python per the request to "Move only the diagnostics
page generation to ubuntu+python to avoid heredocs/quoting issues." All outputs
and filenames remain aligned with the original scripts so downstream consumers
continue to function unchanged.
"""
from __future__ import annotations

import base64
import html
import json
import os
import sys
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, List, Optional

try:  # Professional note: zoneinfo is required to match the Central time stamp.
    from zoneinfo import ZoneInfo
except Exception:  # pragma: no cover - Python <3.9 fallback when unavailable.
    ZoneInfo = None  # type: ignore


@dataclass
class BundleLink:
    label: str
    path: Optional[str]
    exists: bool


def _env(name: str, default: Optional[str] = None) -> Optional[str]:
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return value


def _require_env(name: str) -> str:
    value = _env(name)
    if not value:
        raise RuntimeError(f"{name} environment variable is required.")
    return value


def _iso_utc_now() -> tuple[str, str]:
    now_utc = datetime.now(timezone.utc)
    utc_stamp = now_utc.isoformat()
    if ZoneInfo is not None:
        try:
            ct_zone = ZoneInfo("America/Chicago")
            ct_stamp = now_utc.astimezone(ct_zone).isoformat()
        except Exception:  # pragma: no cover - gracefully fall back to UTC.
            ct_stamp = utc_stamp
    else:
        ct_stamp = utc_stamp
    return utc_stamp, ct_stamp


def _first_directory(root: Optional[Path]) -> Optional[Path]:
    if not root or not root.exists():
        return None
    for entry in root.iterdir():
        if entry.is_dir():
            return entry
    return None


def _choose_iterate_dir(iterate_root: Optional[Path]) -> Optional[Path]:
    chosen = _first_directory(iterate_root)
    if not iterate_root or not iterate_root.exists():
        return chosen
    for candidate in iterate_root.iterdir():
        if not candidate.is_dir():
            continue
        if (candidate / "decision.txt").exists():
            return candidate
    return chosen


def _find_iterate_temp(iterate_root: Optional[Path], iterate_dir: Optional[Path]) -> Optional[Path]:
    for candidate in (
        iterate_root / "_temp" if iterate_root else None,
        iterate_dir / "_temp" if iterate_dir else None,
    ):
        if candidate and candidate.exists():
            return candidate
    if iterate_root and iterate_root.exists():
        for path in iterate_root.rglob("_temp"):
            if path.is_dir():
                return path
    return None


def _read_json(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _relative(path: Path, diag_root: Optional[Path]) -> str:
    text = str(path)
    if not diag_root:
        return text.replace("\\", "/")
    try:
        rel = path.relative_to(diag_root)
        return rel.as_posix()
    except ValueError:
        return text.replace("\\", "/")


def _normalize_link(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    return value.replace("\\", "/")


def _escape_href(value: str) -> str:
    try:
        return urllib.parse.quote(value, safe="/:?&=#%-")
    except Exception:  # pragma: no cover - fallback matches PS fail-open behavior.
        return value


def _iter_files(path: Optional[Path]) -> Iterable[Path]:
    if not path or not path.exists():
        return []
    return sorted(p for p in path.rglob("*") if p.is_file())


def _decode_inventory(inv_b64: Optional[str]) -> List[str]:
    if not inv_b64:
        return []
    try:
        decoded = base64.b64decode(inv_b64)
        text = decoded.decode("utf-8")
    except Exception:
        return []
    return text.splitlines()


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _build_quick_links(diag_root: Optional[Path], short_sha: str, iterate_zip: str, batch_zip: Optional[str]) -> List[BundleLink]:
    diag_exists = bool(diag_root and diag_root.exists())

    def _has(rel: Path | str) -> bool:
        if not diag_root:
            return False
        rel_path = Path(rel)
        return (diag_root / rel_path).exists()

    links: List[BundleLink] = [
        BundleLink("Inventory (HTML)", "inventory.html", diag_exists and _has("inventory.html")),
        BundleLink("Inventory (text)", "inventory.txt", diag_exists and _has("inventory.txt")),
        BundleLink("Inventory (markdown)", "inventory.md", diag_exists and _has("inventory.md")),
        BundleLink("Inventory (json)", "inventory.json", diag_exists and _has("inventory.json")),
        BundleLink("Iterate logs zip", f"logs/{iterate_zip}", diag_exists and _has(Path("logs") / iterate_zip)),
        BundleLink(
            "Batch-check logs zip",
            f"logs/{batch_zip}" if batch_zip else None,
            diag_exists and bool(batch_zip and _has(Path("logs") / batch_zip)),
        ),
        BundleLink("Batch-check failing tests", "batchcheck_failing.txt", diag_exists and _has("batchcheck_failing.txt")),
        BundleLink("Batch-check fail debug", "batchcheck_fail-debug.txt", diag_exists and _has("batchcheck_fail-debug.txt")),
        BundleLink("Repository zip", f"repo/repo-{short_sha}.zip", diag_exists and _has(Path("repo") / f"repo-{short_sha}.zip")),
        BundleLink("Repository files (unzipped)", "repo/files/", diag_exists and _has(Path("repo") / "files")),
    ]

    if diag_root:
        wf_dir = diag_root / "wf"
        for wf in sorted(wf_dir.glob("*.yml.txt")):
            rel = Path("wf") / wf.name
            links.append(BundleLink(f"Workflow: {wf.name}", rel.as_posix(), True))
    return links


def _bundle_markdown(
    repo: str,
    sha: str,
    run_id: str,
    attempt: str,
    utc_stamp: str,
    ct_stamp: str,
    run_url: str,
    iterate_status: str,
    batch_status: str,
    artifact_count: int,
    artifact_missing: Optional[str],
    quick_links: List[BundleLink],
    decision: str,
    outcome: str,
    http_status: str,
    model: str,
    endpoint: str,
    tokens: dict,
    attempt_summary: Optional[str],
    include_attempt_summary: bool,
    iterate_dir: Optional[Path],
    diag_root: Optional[Path],
    artifacts_root: Optional[Path],
    ndjson_summaries: List[Path],
    inventory_lines: List[str],
) -> str:
    lines: List[str] = [
        "# CI Diagnostics",
        f"Repo: {repo}",
        f"Commit: {sha}",
        f"Run: {run_id} (attempt {attempt})",
        f"Built (UTC): {utc_stamp}",
        f"Built (CT): {ct_stamp}",
        f"Run page: {run_url}",
        "",
        "## Status",
        f"- Iterate logs: {iterate_status}",
        f"- Batch-check run id: {batch_status}",
        f"- Artifact files enumerated: {artifact_count}",
    ]

    if artifact_missing:
        lines.append(f"- Artifact sentinel: {artifact_missing}")

    lines.append("")
    lines.append("## Quick links")

    for entry in quick_links:
        if not entry.path:
            continue
        if entry.exists:
            norm = _normalize_link(entry.path)
            lines.append(f"- {entry.label}: [{norm}]({norm})")
        else:
            lines.append(f"- {entry.label}: missing")

    lines.extend(
        [
            "",
            "## Iterate metadata",
            f"- Decision: {decision}",
            f"- Outcome: {outcome}",
            f"- HTTP status: {http_status}",
            f"- Model: {model}",
            f"- Endpoint: {endpoint}",
            f"- Tokens: prompt={tokens['prompt']} completion={tokens['completion']} total={tokens['total']}",
        ]
    )

    if include_attempt_summary and attempt_summary:
        lines.append(f"- Attempt summary: {attempt_summary}")

    iter_files = []
    if iterate_dir and iterate_dir.exists():
        iter_files = sorted(p for p in iterate_dir.iterdir() if p.is_file())
    if iter_files:
        lines.append("")
        lines.append("### Iterate files")
        for file_path in iter_files:
            rel = _relative(file_path, diag_root)
            rel_norm = _normalize_link(rel)
            lines.append(f"- [`{rel_norm}`]({rel_norm})")

    batch_meta = None
    if artifacts_root:
        batch_meta_path = artifacts_root / "batch-check" / "run.json"
        if batch_meta_path.exists():
            try:
                batch_meta = json.loads(batch_meta_path.read_text(encoding="utf-8"))
            except Exception:
                batch_meta = None
    if batch_meta:
        lines.extend(
            [
                "",
                "## Batch-check run",
                f"- Run id: {batch_meta.get('run_id')} (attempt {batch_meta.get('run_attempt')})",
                f"- Status: {batch_meta.get('status')} / {batch_meta.get('conclusion')}",
            ]
        )
        if batch_meta.get("html_url"):
            lines.append(f"- Run page: {batch_meta['html_url']}")

    if ndjson_summaries:
        lines.append("")
        lines.append("## NDJSON summaries")
        for file_path in ndjson_summaries:
            rel = _relative(file_path, diag_root)
            lines.append(f"### {rel}")
            lines.append("```text")
            lines.extend(file_path.read_text(encoding="utf-8").splitlines())
            lines.append("```")

    diag_files = list(_iter_files(diag_root))
    if diag_files:
        lines.append("")
        lines.append("## File listing")
        for item in diag_files:
            rel = _relative(item, diag_root)
            lines.append(f"- [{item.stat().st_size:,} bytes]({_normalize_link(rel)})")

    if inventory_lines:
        lines.append("")
        lines.append("## Inventory (raw)")
        lines.extend(inventory_lines)

    return "\n".join(lines)


def _html_section_pairs(title: str, pairs: List[dict]) -> List[str]:
    lines = ["<section>", f"<h2>{html.escape(title)}</h2>", "<ul>"]
    for pair in pairs:
        label = html.escape(pair["label"])
        value = html.escape(pair["value"]) if pair.get("value") is not None else ""
        href = pair.get("href")
        if href:
            safe_href = _escape_href(_normalize_link(href) or href)
            lines.append(f"<li><strong>{label}:</strong> <a href=\"{safe_href}\">{value}</a></li>")
        else:
            lines.append(f"<li><strong>{label}:</strong> {value}</li>")
    lines.append("</ul>")
    lines.append("</section>")
    return lines


def _bundle_html(
    repo: str,
    sha: str,
    run_id: str,
    attempt: str,
    utc_stamp: str,
    ct_stamp: str,
    run_url: str,
    iterate_status: str,
    batch_status: str,
    artifact_count: int,
    artifact_missing: Optional[str],
    quick_links: List[BundleLink],
    decision: str,
    outcome: str,
    http_status: str,
    model: str,
    endpoint: str,
    tokens: dict,
    attempt_summary: Optional[str],
    include_attempt_summary: bool,
    iterate_dir: Optional[Path],
    diag_root: Optional[Path],
    artifacts_root: Optional[Path],
    ndjson_summaries: List[Path],
    inventory_lines: List[str],
) -> str:
    html_lines: List[str] = [
        "<!doctype html>",
        "<html lang=\"en\">",
        "<head>",
        "<meta charset=\"utf-8\">",
        "<title>CI Diagnostics</title>",
        "</head>",
        "<body>",
        "<h1>CI Diagnostics</h1>",
    ]

    html_lines.extend(
        _html_section_pairs(
            "Metadata",
            [
                {"label": "Repo", "value": repo},
                {"label": "Commit", "value": sha},
                {"label": "Run", "value": f"{run_id} (attempt {attempt})"},
                {"label": "Built (UTC)", "value": utc_stamp},
                {"label": "Built (CT)", "value": ct_stamp},
                {"label": "Run page", "value": run_url, "href": run_url},
            ],
        )
    )

    status_pairs = [
        {"label": "Iterate logs", "value": iterate_status},
        {"label": "Batch-check run id", "value": batch_status},
        {"label": "Artifact files enumerated", "value": str(artifact_count)},
    ]
    if artifact_missing:
        status_pairs.append({"label": "Artifact sentinel", "value": artifact_missing})
    html_lines.extend(_html_section_pairs("Status", status_pairs))

    html_lines.append("<section>")
    html_lines.append("<h2>Quick links</h2>")
    html_lines.append("<ul>")
    for entry in quick_links:
        label = html.escape(entry.label)
        if entry.exists and entry.path:
            href = _escape_href(_normalize_link(entry.path) or entry.path)
            html_lines.append(f"<li><a href=\"{href}\">{label}</a></li>")
        else:
            html_lines.append(f"<li>{label}: missing</li>")
    html_lines.append("</ul>")
    html_lines.append("</section>")

    iterate_pairs = [
        {"label": "Decision", "value": decision},
        {"label": "Outcome", "value": outcome},
        {"label": "HTTP status", "value": http_status},
        {"label": "Model", "value": model},
        {"label": "Endpoint", "value": endpoint},
        {
            "label": "Tokens",
            "value": f"prompt={tokens['prompt']} completion={tokens['completion']} total={tokens['total']}",
        },
    ]
    if include_attempt_summary and attempt_summary:
        iterate_pairs.append({"label": "Attempt summary", "value": attempt_summary})
    html_lines.extend(_html_section_pairs("Iterate metadata", iterate_pairs))

    iter_files = []
    if iterate_dir and iterate_dir.exists():
        iter_files = sorted(p for p in iterate_dir.iterdir() if p.is_file())
    if iter_files:
        html_lines.append("<section>")
        html_lines.append("<h3>Iterate files</h3>")
        html_lines.append("<ul>")
        for file_path in iter_files:
            rel = _relative(file_path, diag_root)
            rel_norm = _normalize_link(rel) or rel
            href = _escape_href(rel_norm)
            html_lines.append(f"<li><code><a href=\"{href}\">{html.escape(rel_norm)}</a></code></li>")
        html_lines.append("</ul>")
        html_lines.append("</section>")

    batch_meta = None
    if artifacts_root:
        batch_meta_path = artifacts_root / "batch-check" / "run.json"
        if batch_meta_path.exists():
            batch_meta = _read_json(batch_meta_path)
    if batch_meta:
        html_lines.append("<section>")
        html_lines.append("<h2>Batch-check run</h2>")
        html_lines.append("<ul>")
        html_lines.append(
            f"<li>Run id: {html.escape(str(batch_meta.get('run_id')))} (attempt {html.escape(str(batch_meta.get('run_attempt')))} )</li>"
        )
        html_lines.append(
            f"<li>Status: {html.escape(str(batch_meta.get('status')))} / {html.escape(str(batch_meta.get('conclusion')))}</li>"
        )
        if batch_meta.get("html_url"):
            href = _escape_href(str(batch_meta["html_url"]))
            html_lines.append(f"<li><a href=\"{href}\">Run page</a></li>")
        html_lines.append("</ul>")
        html_lines.append("</section>")

    if ndjson_summaries:
        html_lines.append("<section>")
        html_lines.append("<h2>NDJSON summaries</h2>")
        for file_path in ndjson_summaries:
            rel = _relative(file_path, diag_root)
            html_lines.append(f"<h3>{html.escape(rel)}</h3>")
            html_lines.append("<pre>")
            for segment in file_path.read_text(encoding="utf-8").splitlines():
                html_lines.append(html.escape(segment))
            html_lines.append("</pre>")
        html_lines.append("</section>")

    diag_files = list(_iter_files(diag_root))
    if diag_files:
        html_lines.append("<section>")
        html_lines.append("<h2>File listing</h2>")
        html_lines.append("<ul>")
        for item in diag_files:
            rel = _relative(item, diag_root)
            rel_norm = _normalize_link(rel) or rel
            href = _escape_href(rel_norm)
            size = f"{item.stat().st_size:,} bytes"
            html_lines.append(f"<li><a href=\"{href}\">{html.escape(rel_norm)}</a> — {html.escape(size)}</li>")
        html_lines.append("</ul>")
        html_lines.append("</section>")

    if inventory_lines:
        html_lines.append("<section>")
        html_lines.append("<h2>Inventory (raw)</h2>")
        html_lines.append("<pre>")
        for entry in inventory_lines:
            html_lines.append(html.escape(entry))
        html_lines.append("</pre>")
        html_lines.append("</section>")

    html_lines.append("</body>")
    html_lines.append("</html>")
    return "\n".join(html_lines)


def _site_overview(
    site_root: Path,
    diag_root: Path,
    artifacts_root: Path,
    run_id: str,
    attempt: str,
    repo: str,
    sha: str,
    run_url: str,
    short_sha: str,
    batch_run_id: Optional[str],
    batch_run_attempt: Optional[str],
) -> tuple[str, str]:
    bundle_prefix = Path("diag") / f"{run_id}-{attempt}"
    cache_buster = run_id
    bundle_index_href = f"{bundle_prefix.as_posix()}/index.html?v={cache_buster}"
    decision = "n/a"
    http_status = "n/a"

    iterate_dir = _choose_iterate_dir(artifacts_root / "iterate" if artifacts_root.exists() else None)
    if iterate_dir:
        decision_path = iterate_dir / "decision.txt"
        if decision_path.exists():
            decision = decision_path.read_text(encoding="utf-8").strip()
        status_path = iterate_dir / "http_status.txt"
        if status_path.exists():
            http_status = status_path.read_text(encoding="utf-8").strip()

    inventory_html = f"{bundle_prefix.as_posix()}/inventory.html"
    inventory_txt = f"{bundle_prefix.as_posix()}/inventory.txt"
    inventory_md = f"{bundle_prefix.as_posix()}/inventory.md"
    iterate_zip = f"{bundle_prefix.as_posix()}/logs/iterate-{run_id}-{attempt}.zip"
    batch_zip = None
    if batch_run_id:
        safe_attempt = batch_run_attempt or "n/a"
        batch_zip = f"{bundle_prefix.as_posix()}/logs/batch-check-{batch_run_id}-{safe_attempt}.zip"
    repo_zip = f"{bundle_prefix.as_posix()}/repo/repo-{short_sha}.zip"
    repo_files_rel = f"{bundle_prefix.as_posix()}/repo/files/"

    def has_file(relative: Optional[str]) -> bool:
        if not relative:
            return False
        return (site_root / Path(relative)).exists()

    ndjson_summary = next(
        (p for p in artifacts_root.rglob("ndjson_summary.txt") if p.is_file()),
        None,
    ) if artifacts_root.exists() else None

    summary_preview: List[str] = []
    if ndjson_summary:
        summary_preview.append("```text")
        summary_preview.extend(ndjson_summary.read_text(encoding="utf-8").splitlines())
        summary_preview.append("```")

    lines = [
        "# Diagnostics overview",
        "",
        f"Latest run: [{run_id} (attempt {attempt})]({_normalize_link(bundle_index_href)})",
        "",
        "## Metadata",
        f"- Repo: {repo}",
        f"- Commit: {sha}",
        f"- Run page: {run_url}",
        f"- Iterate decision: {decision}",
        f"- Iterate HTTP status: {http_status}",
        "",
        "## Quick links",
    ]

    def append_link(label: str, rel: Optional[str]) -> None:
        if rel and has_file(rel.split("?", 1)[0]):
            lines.append(f"- [{label}]({_normalize_link(rel)})")
        else:
            lines.append(f"- {label}: missing")

    append_link("Bundle index", bundle_index_href)
    append_link("Open latest (cache-busted)", bundle_index_href)
    append_link("Artifact inventory (HTML)", inventory_html)
    append_link("Artifact inventory (text)", inventory_txt)
    append_link("Iterate logs zip", iterate_zip)
    if batch_zip:
        append_link("Batch-check logs zip", batch_zip)
    else:
        lines.append("- Batch-check logs zip: missing")
    append_link("Repository zip", repo_zip)
    append_link("Repository files (unzipped)", repo_files_rel)
    append_link("Inventory (markdown)", inventory_md)

    if summary_preview:
        lines.append("")
        lines.append("## NDJSON summary (first bundle)")
        lines.extend(summary_preview)

    lines.append("")
    lines.append("Artifacts from the self-test workflow and iterate job are merged under the bundle directory above.")

    markdown = "\n".join(lines)

    html_lines = [
        "<!doctype html>",
        "<html lang=\"en\">",
        "<head>",
        "<meta charset=\"utf-8\">",
        "<title>Diagnostics overview</title>",
        "</head>",
        "<body>",
        "<h1>Diagnostics overview</h1>",
        f"<p>Latest run: <a href=\"{_escape_href(_normalize_link(bundle_index_href) or bundle_index_href)}\">{html.escape(run_id)} (attempt {html.escape(attempt)})</a></p>",
        "<section>",
        "<h2>Metadata</h2>",
        "<ul>",
        f"<li><strong>Repo:</strong> {html.escape(repo)}</li>",
        f"<li><strong>Commit:</strong> {html.escape(sha)}</li>",
        f"<li><strong>Run page:</strong> <a href=\"{_escape_href(run_url)}\">{html.escape(run_url)}</a></li>",
        f"<li><strong>Iterate decision:</strong> {html.escape(decision)}</li>",
        f"<li><strong>Iterate HTTP status:</strong> {html.escape(http_status)}</li>",
        "</ul>",
        "</section>",
        "<section>",
        "<h2>Quick links</h2>",
        "<ul>",
    ]

    def html_link(label: str, rel: Optional[str]) -> None:
        if rel and has_file(rel.split("?", 1)[0]):
            href = _escape_href(_normalize_link(rel) or rel)
            html_lines.append(f"<li><a href=\"{href}\">{html.escape(label)}</a></li>")
        else:
            html_lines.append(f"<li>{html.escape(label)}: missing</li>")

    html_link("Bundle index", bundle_index_href)
    html_link("Open latest (cache-busted)", bundle_index_href)
    html_link("Artifact inventory (HTML)", inventory_html)
    html_link("Artifact inventory (text)", inventory_txt)
    html_link("Iterate logs zip", iterate_zip)
    if batch_zip:
        html_link("Batch-check logs zip", batch_zip)
    else:
        html_lines.append("<li>Batch-check logs zip: missing</li>")
    html_link("Repository zip", repo_zip)
    html_link("Repository files (unzipped)", repo_files_rel)
    html_link("Inventory (markdown)", inventory_md)

    html_lines.extend(["</ul>", "</section>"])

    if summary_preview:
        html_lines.extend(["<section>", "<h2>NDJSON summary (first bundle)</h2>", "<pre>"])
        for line in summary_preview:
            if line.startswith("```"):
                continue
            html_lines.append(html.escape(line))
        html_lines.extend(["</pre>", "</section>"])

    html_lines.append(
        "<p>Artifacts from the self-test workflow and iterate job are merged under the bundle directory above.</p>"
    )
    html_lines.extend(["</body>", "</html>"])

    return markdown, "\n".join(html_lines)


def main() -> int:
    diag_path = Path(_require_env("DIAG"))
    artifacts_path = Path(_require_env("ARTIFACTS"))
    repo = _require_env("REPO")
    sha = _require_env("SHA")
    run_id = _require_env("RUN_ID")
    attempt = _require_env("RUN_ATTEMPT")
    run_url = _require_env("RUN_URL")
    short_sha = _env("SHORTSHA") or (sha[:7] if len(sha) >= 7 else sha)
    inventory_b64 = _env("INVENTORY_B64")
    batch_run_id = _env("BATCH_RUN_ID")
    batch_run_attempt = _env("BATCH_RUN_ATTEMPT") or "n/a"
    site_root = Path(_require_env("SITE"))

    utc_stamp, ct_stamp = _iso_utc_now()

    iterate_root = artifacts_path / "iterate"
    iterate_dir = _choose_iterate_dir(iterate_root)
    iterate_temp = _find_iterate_temp(iterate_root, iterate_dir)

    response_data = None
    status_data = None
    why_outcome = None

    if iterate_temp:
        resp_path = iterate_temp / "response.json"
        if resp_path.exists():
            response_data = _read_json(resp_path)
        status_path = iterate_temp / "iterate_status.json"
        if status_path.exists():
            status_data = _read_json(status_path)
        why_path = iterate_temp / "why_no_diff.txt"
        if why_path.exists():
            try:
                why_outcome = why_path.read_text(encoding="utf-8").splitlines()[0].strip()
            except Exception:
                pass

    def read_value(directory: Optional[Path], name: str) -> str:
        if not directory:
            return "n/a"
        target = directory / name
        if target.exists():
            return target.read_text(encoding="utf-8").strip()
        return "n/a"

    decision = read_value(iterate_dir, "decision.txt")
    model = read_value(iterate_dir, "model.txt")
    endpoint = read_value(iterate_dir, "endpoint.txt")
    http_status = read_value(iterate_dir, "http_status.txt")

    if response_data:
        http_status = str(response_data.get("http_status", http_status or "n/a"))
        if response_data.get("model"):
            model = str(response_data["model"])

    tokens = {"prompt": "n/a", "completion": "n/a", "total": "n/a"}
    if response_data and isinstance(response_data.get("usage"), dict):
        usage = response_data["usage"]
        for key in ("prompt", "completion", "total"):
            value_key = f"{key}_tokens"
            if usage.get(value_key) is not None:
                tokens[key] = str(usage[value_key])

    if iterate_dir:
        tokens_path = iterate_dir / "tokens.txt"
        if tokens_path.exists():
            for line in tokens_path.read_text(encoding="utf-8").splitlines():
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()
                if key and (key not in tokens or tokens[key] in {"", "n/a"}):
                    tokens[key] = value

    patch_diff = iterate_dir / "patch.diff" if iterate_dir else None
    diff_produced = False
    if patch_diff and patch_diff.exists():
        head = patch_diff.read_text(encoding="utf-8").splitlines()[:20]
        if head and not (len(head) == 1 and head[0].strip() == "# no changes"):
            diff_produced = True

    outcome = why_outcome or ("diff produced" if diff_produced else "n/a")

    def fmt_status(value: Optional[object]) -> str:
        if value is None:
            return "n/a"
        if isinstance(value, bool):
            return str(value).lower()
        return str(value)

    attempt_summary = None
    if status_data:
        attempt_summary = "attempted={0} gate={1} auth_ok={2} attempts_left={3}".format(
            fmt_status(status_data.get("attempted")),
            fmt_status(status_data.get("gate")),
            fmt_status(status_data.get("auth_ok")),
            fmt_status(status_data.get("attempts_left")),
        )

    ndjson_summaries = []
    if artifacts_path.exists():
        ndjson_summaries = [p for p in artifacts_path.rglob("ndjson_summary.txt") if p.is_file()]

    iterate_zip_name = f"iterate-{run_id}-{attempt}.zip"
    iterate_zip_path = diag_path / "logs" / iterate_zip_name
    iterate_status = "found" if iterate_zip_path.exists() else "missing (see logs/iterate.MISSING.txt)"

    batch_zip_name = None
    batch_status = "missing"
    if batch_run_id:
        batch_zip_name = f"batch-check-{batch_run_id}-{batch_run_attempt}.zip"
        batch_zip_path = diag_path / "logs" / batch_zip_name
        if batch_zip_path.exists():
            batch_status = f"found (run {batch_run_id}, attempt {batch_run_attempt})"
        else:
            batch_status = f"missing archive (run {batch_run_id}, attempt {batch_run_attempt})"
    elif (diag_path / "logs" / "batch-check.MISSING.txt").exists():
        batch_status = "missing (see logs/batch-check.MISSING.txt)"

    artifact_files = list(_iter_files(artifacts_path))
    artifact_count = len(artifact_files)
    artifact_missing = None
    missing_path = artifacts_path / "MISSING.txt"
    if missing_path.exists():
        artifact_missing = missing_path.read_text(encoding="utf-8").strip()

    inventory_lines = _decode_inventory(inventory_b64)

    bundle_links = _build_quick_links(diag_path, short_sha, iterate_zip_name, batch_zip_name)
    include_attempt_summary = bool(attempt_summary and not response_data)

    markdown = _bundle_markdown(
        repo,
        sha,
        run_id,
        attempt,
        utc_stamp,
        ct_stamp,
        run_url,
        iterate_status,
        batch_status,
        artifact_count,
        artifact_missing,
        bundle_links,
        decision,
        outcome,
        http_status,
        model,
        endpoint,
        tokens,
        attempt_summary,
        iterate_dir,
        diag_path,
        artifacts_path,
        ndjson_summaries,
        inventory_lines,
        include_attempt_summary,
    )
    html_body = _bundle_html(
        repo,
        sha,
        run_id,
        attempt,
        utc_stamp,
        ct_stamp,
        run_url,
        iterate_status,
        batch_status,
        artifact_count,
        artifact_missing,
        bundle_links,
        decision,
        outcome,
        http_status,
        model,
        endpoint,
        tokens,
        attempt_summary,
        iterate_dir,
        diag_path,
        artifacts_path,
        ndjson_summaries,
        inventory_lines,
        include_attempt_summary,
    )

    _write_text(diag_path / "index.md", markdown)
    _write_text(diag_path / "index.html", html_body)

    site_markdown, site_html = _site_overview(
        site_root,
        diag_path,
        artifacts_path,
        run_id,
        attempt,
        repo,
        sha,
        run_url,
        short_sha,
        batch_run_id,
        batch_run_attempt,
    )
    _write_text(site_root / "index.md", site_markdown)
    _write_text(site_root / "index.html", site_html)

    latest_payload = {
        "repo": repo,
        "run_id": run_id,
        "run_attempt": attempt,
        "sha": sha,
        "bundle_url": f"diag/{run_id}-{attempt}/index.html",
        "inventory": f"diag/{run_id}-{attempt}/inventory.json",
        "workflow": f"diag/{run_id}-{attempt}/wf/codex-auto-iterate.yml.txt",
        "iterate": {
            "prompt": f"diag/{run_id}-{attempt}/_artifacts/iterate/iterate/prompt.txt",
            "response": f"diag/{run_id}-{attempt}/_artifacts/iterate/iterate/response.json",
            "diff": f"diag/{run_id}-{attempt}/_artifacts/iterate/iterate/patch.diff",
            "log": f"diag/{run_id}-{attempt}/_artifacts/iterate/iterate/exec.log",
        },
    }
    _write_text(site_root / "latest.json", json.dumps(latest_payload, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
