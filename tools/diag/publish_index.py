#!/usr/bin/env python3
"""Generate diagnostics index and overview pages using Python.

This port maintains the behavior of the PowerShell helpers so the publish
job can run on Ubuntu without quoting issues.
"""
from __future__ import annotations

import base64
import json
import os
from datetime import datetime, timezone
from html import escape as html_escape
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional
from urllib.parse import quote

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python < 3.9 fallback
    ZoneInfo = None  # type: ignore


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None:
        raise SystemExit(f"{name} environment variable is required")
    return value


def _get_env(name: str) -> Optional[str]:
    value = os.environ.get(name)
    return value if value else None


def _normalize_link(value: Optional[str]) -> Optional[str]:
    if not value:
        return value
    return value.replace("\\", "/")


def _escape_href(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    try:
        return quote(value, safe="/:#?&=%+-_.")
    except Exception:
        return value


def _first_dir(root: Optional[Path]) -> Optional[Path]:
    if not root or not root.exists():
        return None
    for child in sorted(root.iterdir()):
        if child.is_dir():
            return child
    return None


def _find_iterate_dir(artifacts_root: Optional[Path]) -> Optional[Path]:
    iterate_root = artifacts_root / "iterate" if artifacts_root else None
    iterate_dir = _first_dir(iterate_root)
    if iterate_root and iterate_root.exists():
        for candidate in sorted(iterate_root.iterdir()):
            if not candidate.is_dir():
                continue
            if (candidate / "decision.txt").exists():
                # Professional note: prefer the iterate folder carrying decision.txt
                # so metadata stays anchored to the sanitized payload.
                iterate_dir = candidate
                break
    return iterate_dir


def _find_iterate_temp(iterate_root: Optional[Path], iterate_dir: Optional[Path]) -> Optional[Path]:
    candidates: List[Path] = []
    if iterate_root and iterate_root.exists():
        direct = iterate_root / "_temp"
        if direct.exists():
            return direct
        candidates.append(iterate_root)
    if iterate_dir and iterate_dir.exists():
        nested = iterate_dir / "_temp"
        if nested.exists():
            return nested
        candidates.append(iterate_dir)
    for base in candidates:
        for child in base.rglob("_temp"):
            if child.is_dir():
                return child
    return None


def _load_json(path: Optional[Path]) -> Optional[Any]:
    if not path or not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _format_tokens(response_data: Optional[dict], iterate_dir: Optional[Path]) -> Dict[str, str]:
    tokens = {"prompt": "n/a", "completion": "n/a", "total": "n/a"}
    if response_data and isinstance(response_data, dict):
        usage = response_data.get("usage")
        if isinstance(usage, dict):
            for key in ("prompt", "completion", "total"):
                field = f"{key}_tokens"
                value = usage.get(field)
                if value is not None:
                    tokens[key] = str(value)
    if iterate_dir and iterate_dir.exists():
        tokens_path = iterate_dir / "tokens.txt"
        if tokens_path.exists():
            for raw in tokens_path.read_text(encoding="utf-8").splitlines():
                if "=" not in raw:
                    continue
                key, value = raw.split("=", 1)
                key = key.strip()
                value = value.strip()
                if not key:
                    continue
                if key not in tokens or not tokens[key] or tokens[key] == "n/a":
                    tokens[key] = value
    return tokens


def _diff_produced(patch_path: Optional[Path]) -> bool:
    if not patch_path or not patch_path.exists():
        return False
    lines = patch_path.read_text(encoding="utf-8").splitlines()[:20]
    if not lines:
        return False
    return not (len(lines) == 1 and lines[0].strip() == "# no changes")


def _gather_files(root: Optional[Path]) -> List[Path]:
    if not root or not root.exists():
        return []
    return sorted([p for p in root.rglob("*") if p.is_file()])


def _relative_to_diag(diag: Optional[Path], path: Path) -> str:
    if diag and path.is_absolute():
        try:
            rel = path.relative_to(diag)
            return rel.as_posix()
        except ValueError:
            pass
    return path.as_posix()


def _read_inventory_b64(value: Optional[str]) -> List[str]:
    if not value:
        return []
    try:
        decoded = base64.b64decode(value).decode("utf-8")
    except Exception:
        return []
    return decoded.splitlines()


def _escape_html(value: Optional[str]) -> str:
    return html_escape(value or "")


def _site_has_file(site: Optional[Path], relative: Optional[str]) -> bool:
    if not site or not relative:
        return False
    return (site / relative).exists()


def _build_datetime_strings() -> tuple[str, str]:
    utc_now = datetime.now(timezone.utc)
    utc_iso = utc_now.isoformat()
    if ZoneInfo is not None:
        try:
            ct_iso = utc_now.astimezone(ZoneInfo("America/Chicago")).isoformat()
            return utc_iso, ct_iso
        except Exception:
            pass
    # Professional note: fall back to UTC when zoneinfo fails so publishing
    # never blocks on timezone availability.
    return utc_iso, utc_iso


def main() -> None:
    diag = _get_env("DIAG")
    artifacts = _get_env("ARTIFACTS")
    repo = _require_env("REPO")
    sha = _require_env("SHA")
    run_id = _require_env("RUN_ID")
    run_attempt = _require_env("RUN_ATTEMPT")
    run_url = _require_env("RUN_URL")
    short_sha = _get_env("SHORTSHA")
    inventory_b64 = _get_env("INVENTORY_B64")
    batch_run_id = _get_env("BATCH_RUN_ID")
    batch_run_attempt = _get_env("BATCH_RUN_ATTEMPT")
    site = _get_env("SITE")

    diag_path = Path(diag) if diag else None
    artifacts_path = Path(artifacts) if artifacts else None
    site_path = Path(site) if site else None

    if not short_sha:
        short_sha = sha[:7]

    utc_iso, ct_iso = _build_datetime_strings()

    iterate_root = artifacts_path / "iterate" if artifacts_path else None
    iterate_dir = _find_iterate_dir(artifacts_path)
    iterate_temp = _find_iterate_temp(iterate_root, iterate_dir)

    response_data = _load_json(iterate_temp / "response.json" if iterate_temp else None)
    status_data = _load_json(iterate_temp / "iterate_status.json" if iterate_temp else None)

    why_outcome = None
    if iterate_temp:
        why_path = iterate_temp / "why_no_diff.txt"
        if why_path.exists():
            why_outcome = why_path.read_text(encoding="utf-8").splitlines()[:1]
            why_outcome = why_outcome[0].strip() if why_outcome else None

    def read_value(directory: Optional[Path], name: str) -> str:
        if not directory:
            return "n/a"
        path = directory / name
        return path.read_text(encoding="utf-8").strip() if path.exists() else "n/a"

    decision = read_value(iterate_dir, "decision.txt")
    model = read_value(iterate_dir, "model.txt")
    endpoint = read_value(iterate_dir, "endpoint.txt")
    http_status = read_value(iterate_dir, "http_status.txt")

    if isinstance(response_data, dict):
        http_status = str(response_data.get("http_status", http_status)) if response_data.get("http_status") is not None else http_status
        if response_data.get("model"):
            model = str(response_data["model"])

    tokens = _format_tokens(response_data if isinstance(response_data, dict) else None, iterate_dir)

    patch_diff_path = iterate_dir / "patch.diff" if iterate_dir else None
    diff_produced = _diff_produced(patch_diff_path)

    outcome = "n/a"
    if why_outcome:
        outcome = why_outcome
    elif diff_produced:
        outcome = "diff produced"

    def format_status_value(value: Any) -> str:
        if isinstance(value, bool):
            return str(value).lower()
        if value is None:
            return "n/a"
        return str(value)

    attempt_summary = None
    if isinstance(status_data, dict):
        attempt_summary = "attempted={0} gate={1} auth_ok={2} attempts_left={3}".format(
            format_status_value(status_data.get("attempted")),
            format_status_value(status_data.get("gate")),
            format_status_value(status_data.get("auth_ok")),
            format_status_value(status_data.get("attempts_left")),
        )

    ndjson_summaries = []
    if artifacts_path and artifacts_path.exists():
        ndjson_summaries = sorted(artifacts_path.rglob("ndjson_summary.txt"))

    iterate_zip_name = f"iterate-{run_id}-{run_attempt}.zip"
    iterate_zip_path = diag_path / "logs" / iterate_zip_name if diag_path else None
    iterate_status = "found"
    if not iterate_zip_path or not iterate_zip_path.exists():
        iterate_status = "missing (see logs/iterate.MISSING.txt)"

    batch_status = "missing"
    batch_zip_name = None
    if batch_run_id:
        batch_attempt = batch_run_attempt or "n/a"
        batch_zip_name = f"batch-check-{batch_run_id}-{batch_attempt}.zip"
        batch_zip_path = diag_path / "logs" / batch_zip_name if diag_path else None
        if batch_zip_path and batch_zip_path.exists():
            batch_status = f"found (run {batch_run_id}, attempt {batch_attempt})"
        else:
            batch_status = f"missing archive (run {batch_run_id}, attempt {batch_attempt})"
    elif diag_path and (diag_path / "logs" / "batch-check.MISSING.txt").exists():
        batch_status = "missing (see logs/batch-check.MISSING.txt)"

    artifact_files = []
    if artifacts_path and artifacts_path.exists():
        artifact_files = [p for p in artifacts_path.rglob("*") if p.is_file()]
    artifact_count = len(artifact_files)

    artifact_missing = None
    artifact_missing_path = artifacts_path / "MISSING.txt" if artifacts_path else None
    if artifact_missing_path and artifact_missing_path.exists():
        artifact_missing = artifact_missing_path.read_text(encoding="utf-8").strip()

    all_files = _gather_files(diag_path)

    lines: List[str] = []
    lines.extend([
        "# CI Diagnostics",
        f"Repo: {repo}",
        f"Commit: {sha}",
        f"Run: {run_id} (attempt {run_attempt})",
        f"Built (UTC): {utc_iso}",
        f"Built (CT): {ct_iso}",
        f"Run page: {run_url}",
        "",
        "## Status",
        f"- Iterate logs: {iterate_status}",
        f"- Batch-check run id: {batch_status}",
        f"- Artifact files enumerated: {artifact_count}",
    ])

    if artifact_missing:
        lines.append(f"- Artifact sentinel: {artifact_missing}")

    lines.append("")
    lines.append("## Quick links")

    bundle_links: List[Dict[str, Any]] = [
        {"Label": "Inventory (HTML)", "Path": "inventory.html", "Exists": bool(diag_path and (diag_path / "inventory.html").exists())},
        {"Label": "Inventory (text)", "Path": "inventory.txt", "Exists": bool(diag_path and (diag_path / "inventory.txt").exists())},
        {"Label": "Inventory (markdown)", "Path": "inventory.md", "Exists": bool(diag_path and (diag_path / "inventory.md").exists())},
        {"Label": "Inventory (json)", "Path": "inventory.json", "Exists": bool(diag_path and (diag_path / "inventory.json").exists())},
        {"Label": "Iterate logs zip", "Path": f"logs/{iterate_zip_name}", "Exists": bool(iterate_zip_path and iterate_zip_path.exists())},
        {"Label": "Batch-check logs zip", "Path": f"logs/{batch_zip_name}" if batch_zip_name else None, "Exists": bool(diag_path and batch_zip_name and (diag_path / "logs" / batch_zip_name).exists())},
        {"Label": "Batch-check failing tests", "Path": "batchcheck_failing.txt", "Exists": bool(diag_path and (diag_path / "batchcheck_failing.txt").exists())},
        {"Label": "Batch-check fail debug", "Path": "batchcheck_fail-debug.txt", "Exists": bool(diag_path and (diag_path / "batchcheck_fail-debug.txt").exists())},
        {"Label": "Repository zip", "Path": f"repo/repo-{short_sha}.zip", "Exists": bool(diag_path and (diag_path / "repo" / f"repo-{short_sha}.zip").exists())},
        {"Label": "Repository files (unzipped)", "Path": "repo/files/", "Exists": bool(diag_path and (diag_path / "repo" / "files").exists())},
    ]

    if diag_path and (diag_path / "wf").exists():
        for wf in sorted((diag_path / "wf").glob("*.yml.txt")):
            bundle_links.append({"Label": f"Workflow: {wf.name}", "Path": f"wf/{wf.name}", "Exists": True})

    for entry in bundle_links:
        path = entry.get("Path")
        if not path:
            continue
        if entry.get("Exists"):
            link_path = _normalize_link(path)
            lines.append(f"- {entry['Label']}: [{link_path}]({link_path})")
        else:
            lines.append(f"- {entry['Label']}: missing")

    lines.append("")
    lines.append("## Iterate metadata")
    lines.extend([
        f"- Decision: {decision}",
        f"- Outcome: {outcome}",
        f"- HTTP status: {http_status}",
        f"- Model: {model}",
        f"- Endpoint: {endpoint}",
        f"- Tokens: prompt={tokens['prompt']} completion={tokens['completion']} total={tokens['total']}",
    ])

    if not isinstance(response_data, dict) and attempt_summary:
        lines.append(f"- Attempt summary: {attempt_summary}")

    if iterate_dir and iterate_dir.exists():
        iter_files = [p for p in iterate_dir.iterdir() if p.is_file()]
        if iter_files:
            lines.append("")
            lines.append("### Iterate files")
            for file_path in sorted(iter_files):
                rel = _relative_to_diag(diag_path, file_path)
                rel_norm = _normalize_link(rel)
                lines.append(f"- [`{rel_norm}`]({rel_norm})")

    batch_run_meta = artifacts_path / "batch-check" / "run.json" if artifacts_path else None
    batch_meta = _load_json(batch_run_meta)
    if isinstance(batch_meta, dict):
        lines.append("")
        lines.append("## Batch-check run")
        lines.append(f"- Run id: {batch_meta.get('run_id')} (attempt {batch_meta.get('run_attempt')})")
        lines.append(f"- Status: {batch_meta.get('status')} / {batch_meta.get('conclusion')}")
        if batch_meta.get("html_url"):
            lines.append(f"- Run page: {batch_meta['html_url']}")

    if ndjson_summaries:
        lines.append("")
        lines.append("## NDJSON summaries")
        for file_path in ndjson_summaries:
            rel = _relative_to_diag(diag_path, file_path)
            lines.append(f"### {rel}")
            lines.append("```text")
            lines.extend(file_path.read_text(encoding="utf-8").splitlines())
            lines.append("```")

    if all_files:
        lines.append("")
        lines.append("## File listing")
        for item in all_files:
            rel = _relative_to_diag(diag_path, item)
            rel_norm = _normalize_link(rel)
            size = f"{item.stat().st_size:,.0f}"
            lines.append(f"- [{size} bytes]({rel_norm})")

    inventory_lines = _read_inventory_b64(inventory_b64)
    if inventory_lines:
        lines.append("")
        lines.append("## Inventory (raw)")
        lines.extend(inventory_lines)

    if diag_path:
        md_path = diag_path / "index.md"
        md_path.write_text("\n".join(lines), encoding="utf-8")

    # HTML rendering for diag bundle
    status_pairs = [
        {"label": "Iterate logs", "value": iterate_status},
        {"label": "Batch-check run id", "value": batch_status},
        {"label": "Artifact files enumerated", "value": str(artifact_count)},
    ]
    if artifact_missing:
        status_pairs.append({"label": "Artifact sentinel", "value": artifact_missing})

    metadata_pairs = [
        {"label": "Repo", "value": repo},
        {"label": "Commit", "value": sha},
        {"label": "Run", "value": f"{run_id} (attempt {run_attempt})"},
        {"label": "Built (UTC)", "value": utc_iso},
        {"label": "Built (CT)", "value": ct_iso},
        {"label": "Run page", "value": run_url, "href": run_url},
    ]

    iterate_pairs = [
        {"label": "Decision", "value": decision},
        {"label": "Outcome", "value": outcome},
        {"label": "HTTP status", "value": http_status},
        {"label": "Model", "value": model},
        {"label": "Endpoint", "value": endpoint},
        {"label": "Tokens", "value": f"prompt={tokens['prompt']} completion={tokens['completion']} total={tokens['total']}"},
    ]
    if not isinstance(response_data, dict) and attempt_summary:
        iterate_pairs.append({"label": "Attempt summary", "value": attempt_summary})

    html_lines = [
        "<!doctype html>",
        "<html lang=\"en\">",
        "<head>",
        "<meta charset=\"utf-8\">",
        "<title>CI Diagnostics</title>",
        "</head>",
        "<body>",
        "<h1>CI Diagnostics</h1>",
    ]

    def render_pairs(title: str, pairs: Iterable[Dict[str, str]]) -> None:
        html_lines.append("<section>")
        html_lines.append(f"<h2>{html_escape(title)}</h2>")
        html_lines.append("<ul>")
        for pair in pairs:
            label = html_escape(pair.get("label", ""))
            value = pair.get("value")
            href = pair.get("href") if isinstance(pair, dict) else None
            if href:
                html_lines.append(
                    f"<li><strong>{label}:</strong> <a href=\"{_escape_href(_normalize_link(href))}\">{html_escape(value or '')}</a></li>"
                )
            else:
                html_lines.append(f"<li><strong>{label}:</strong> {html_escape(value or '')}</li>")
        html_lines.append("</ul>")
        html_lines.append("</section>")

    render_pairs("Metadata", metadata_pairs)
    render_pairs("Status", status_pairs)

    html_lines.append("<section>")
    html_lines.append("<h2>Quick links</h2>")
    html_lines.append("<ul>")
    for entry in bundle_links:
        path = entry.get("Path")
        label = html_escape(entry.get("Label", ""))
        if path and entry.get("Exists"):
            href = _escape_href(_normalize_link(path))
            html_lines.append(f"<li><a href=\"{href}\">{label}</a></li>")
        elif path:
            html_lines.append(f"<li>{label}: missing</li>")
    html_lines.append("</ul>")
    html_lines.append("</section>")

    render_pairs("Iterate metadata", iterate_pairs)

    if iterate_dir and iterate_dir.exists():
        iter_files = [p for p in iterate_dir.iterdir() if p.is_file()]
        if iter_files:
            html_lines.append("<section>")
            html_lines.append("<h3>Iterate files</h3>")
            html_lines.append("<ul>")
            for file_path in sorted(iter_files):
                rel = _normalize_link(_relative_to_diag(diag_path, file_path))
                href = _escape_href(rel)
                html_lines.append(f"<li><code><a href=\"{href}\">{html_escape(rel)}</a></code></li>")
            html_lines.append("</ul>")
            html_lines.append("</section>")

    if isinstance(batch_meta, dict):
        html_lines.append("<section>")
        html_lines.append("<h2>Batch-check run</h2>")
        html_lines.append("<ul>")
        run_id_html = html_escape(str(batch_meta.get("run_id")))
        run_attempt_html = html_escape(str(batch_meta.get("run_attempt")))
        status_html = html_escape(str(batch_meta.get("status")))
        conclusion_html = html_escape(str(batch_meta.get("conclusion")))
        html_lines.append(f"<li>Run id: {run_id_html} (attempt {run_attempt_html})</li>")
        html_lines.append(f"<li>Status: {status_html} / {conclusion_html}</li>")
        if batch_meta.get("html_url"):
            html_lines.append(f"<li><a href=\"{_escape_href(batch_meta['html_url'])}\">Run page</a></li>")
        html_lines.append("</ul>")
        html_lines.append("</section>")

    if ndjson_summaries:
        html_lines.append("<section>")
        html_lines.append("<h2>NDJSON summaries</h2>")
        for file_path in ndjson_summaries:
            rel = _relative_to_diag(diag_path, file_path)
            html_lines.append(f"<h3>{html_escape(rel)}</h3>")
            html_lines.append("<pre>")
            for segment in file_path.read_text(encoding="utf-8").splitlines():
                html_lines.append(html_escape(segment))
            html_lines.append("</pre>")
        html_lines.append("</section>")

    if all_files:
        html_lines.append("<section>")
        html_lines.append("<h2>File listing</h2>")
        html_lines.append("<ul>")
        for item in all_files:
            rel = _normalize_link(_relative_to_diag(diag_path, item))
            href = _escape_href(rel)
            size = f"{item.stat().st_size:,.0f} bytes"
            html_lines.append(f"<li><a href=\"{href}\">{html_escape(rel)}</a> — {html_escape(size)}</li>")
        html_lines.append("</ul>")
        html_lines.append("</section>")

    if inventory_lines:
        html_lines.append("<section>")
        html_lines.append("<h2>Inventory (raw)</h2>")
        html_lines.append("<pre>")
        for entry in inventory_lines:
            html_lines.append(html_escape(entry))
        html_lines.append("</pre>")
        html_lines.append("</section>")

    html_lines.append("</body>")
    html_lines.append("</html>")

    if diag_path:
        (diag_path / "index.html").write_text("\n".join(html_lines), encoding="utf-8")

    # Emit site latest.json metadata
    if site_path and diag_path:
        latest = {
            "repo": repo,
            "run_id": run_id,
            "run_attempt": run_attempt,
            "sha": sha,
            "bundle_url": f"diag/{run_id}-{run_attempt}/index.html",
            "inventory": f"diag/{run_id}-{run_attempt}/inventory.json",
            "workflow": f"diag/{run_id}-{run_attempt}/wf/codex-auto-iterate.yml.txt",
            "iterate": {
                "prompt": f"diag/{run_id}-{run_attempt}/_artifacts/iterate/iterate/prompt.txt",
                "response": f"diag/{run_id}-{run_attempt}/_artifacts/iterate/iterate/response.json",
                "diff": f"diag/{run_id}-{run_attempt}/_artifacts/iterate/iterate/patch.diff",
                "log": f"diag/{run_id}-{run_attempt}/_artifacts/iterate/iterate/exec.log",
            },
        }
        (site_path / "latest.json").write_text(json.dumps(latest, indent=2), encoding="utf-8")

    # Site overview content (root index)
    bundle_prefix = f"diag/{run_id}-{run_attempt}"
    bundle_index = f"{bundle_prefix}/index.html"
    cache_busted = f"{bundle_index}?v={run_id}"
    inventory_html = f"{bundle_prefix}/inventory.html"
    inventory_txt = f"{bundle_prefix}/inventory.txt"
    inventory_md = f"{bundle_prefix}/inventory.md"
    iterate_zip_rel = f"{bundle_prefix}/logs/{iterate_zip_name}"
    repo_zip_rel = f"{bundle_prefix}/repo/repo-{short_sha}.zip"
    repo_files_rel = f"{bundle_prefix}/repo/files/"
    batch_zip_rel = None
    if batch_zip_name:
        batch_zip_rel = f"{bundle_prefix}/logs/{batch_zip_name}"

    decision_value = decision
    http_status_value = http_status

    summary_preview: List[str] = []
    if artifacts_path and artifacts_path.exists():
        summary_candidate = next((p for p in artifacts_path.rglob("ndjson_summary.txt")), None)
        if summary_candidate:
            summary_preview.append("```text")
            summary_preview.extend(summary_candidate.read_text(encoding="utf-8").splitlines())
            summary_preview.append("```")

    overview_lines: List[str] = [
        "# Diagnostics overview",
        "",
        f"Latest run: [{run_id} (attempt {run_attempt})]({_normalize_link(cache_busted)})",
        "",
        "## Metadata",
        f"- Repo: {repo}",
        f"- Commit: {sha}",
        f"- Run page: {run_url}",
        f"- Iterate decision: {decision_value}",
        f"- Iterate HTTP status: {http_status_value}",
        "",
        "## Quick links",
    ]

    def add_overview_link(label: str, path: Optional[str]) -> None:
        if _site_has_file(site_path, path):
            overview_lines.append(f"- [{label}]({_normalize_link(path)})")
        else:
            overview_lines.append(f"- {label}: missing")

    add_overview_link("Bundle index", bundle_index)
    add_overview_link("Open latest (cache-busted)", cache_busted)
    add_overview_link("Artifact inventory (HTML)", inventory_html)
    add_overview_link("Artifact inventory (text)", inventory_txt)
    add_overview_link("Iterate logs zip", iterate_zip_rel)
    add_overview_link("Batch-check logs zip", batch_zip_rel)
    add_overview_link("Repository zip", repo_zip_rel)
    add_overview_link("Repository files (unzipped)", repo_files_rel)
    add_overview_link("Inventory (markdown)", inventory_md)

    if summary_preview:
        overview_lines.append("")
        overview_lines.append("## NDJSON summary (first bundle)")
        overview_lines.extend(summary_preview)

    overview_lines.append("")
    overview_lines.append("Artifacts from the self-test workflow and iterate job are merged under the bundle directory above.")

    if site_path:
        (site_path / "index.md").write_text("\n".join(overview_lines), encoding="utf-8")

    # HTML overview at site root
    metadata_items = [
        {"label": "Repo", "value": repo},
        {"label": "Commit", "value": sha},
        {"label": "Run page", "value": run_url, "href": run_url},
        {"label": "Iterate decision", "value": decision_value},
        {"label": "Iterate HTTP status", "value": http_status_value},
    ]

    quick_link_specs = [
        {"label": "Bundle index", "path": cache_busted, "exists": _site_has_file(site_path, bundle_index)},
        {"label": "Open latest (cache-busted)", "path": cache_busted, "exists": _site_has_file(site_path, bundle_index)},
        {"label": "Artifact inventory (HTML)", "path": inventory_html, "exists": _site_has_file(site_path, inventory_html)},
        {"label": "Artifact inventory (text)", "path": inventory_txt, "exists": _site_has_file(site_path, inventory_txt)},
        {"label": "Iterate logs zip", "path": iterate_zip_rel, "exists": _site_has_file(site_path, iterate_zip_rel)},
        {"label": "Batch-check logs zip", "path": batch_zip_rel, "exists": _site_has_file(site_path, batch_zip_rel)},
        {"label": "Repository zip", "path": repo_zip_rel, "exists": _site_has_file(site_path, repo_zip_rel)},
        {"label": "Repository files (unzipped)", "path": repo_files_rel, "exists": _site_has_file(site_path, repo_files_rel)},
        {"label": "Inventory (markdown)", "path": inventory_md, "exists": _site_has_file(site_path, inventory_md)},
    ]

    overview_html: List[str] = [
        "<!doctype html>",
        "<html lang=\"en\">",
        "<head>",
        "<meta charset=\"utf-8\">",
        "<title>Diagnostics overview</title>",
        "</head>",
        "<body>",
        "<h1>Diagnostics overview</h1>",
        f"<p>Latest run: <a href=\"{_escape_href(_normalize_link(cache_busted))}\">{html_escape(f'{run_id} (attempt {run_attempt})')}</a></p>",
    ]

    overview_html.append("<section>")
    overview_html.append("<h2>Metadata</h2>")
    overview_html.append("<ul>")
    for item in metadata_items:
        label = html_escape(item.get("label", ""))
        value = item.get("value", "")
        href = item.get("href")
        if href:
            overview_html.append(
                f"<li><strong>{label}:</strong> <a href=\"{_escape_href(href)}\">{html_escape(str(value))}</a></li>"
            )
        else:
            overview_html.append(f"<li><strong>{label}:</strong> {html_escape(str(value))}</li>")
    overview_html.append("</ul>")
    overview_html.append("</section>")

    overview_html.append("<section>")
    overview_html.append("<h2>Quick links</h2>")
    overview_html.append("<ul>")
    for spec in quick_link_specs:
        label = html_escape(spec["label"])
        path = spec.get("path")
        exists = spec.get("exists")
        if path and exists:
            overview_html.append(
                f"<li><a href=\"{_escape_href(_normalize_link(path))}\">{label}</a></li>"
            )
        else:
            overview_html.append(f"<li>{label}: missing</li>")
    overview_html.append("</ul>")
    overview_html.append("</section>")

    if summary_preview:
        overview_html.append("<section>")
        overview_html.append("<h2>NDJSON summary (first bundle)</h2>")
        overview_html.append("<pre>")
        for entry in summary_preview:
            if entry.startswith("```"):
                continue
            overview_html.append(html_escape(entry))
        overview_html.append("</pre>")
        overview_html.append("</section>")

    overview_html.append(
        "<p>Artifacts from the self-test workflow and iterate job are merged under the bundle directory above.</p>"
    )
    overview_html.append("</body>")
    overview_html.append("</html>")

    if site_path:
        (site_path / "index.html").write_text("\n".join(overview_html), encoding="utf-8")


if __name__ == "__main__":
    main()
