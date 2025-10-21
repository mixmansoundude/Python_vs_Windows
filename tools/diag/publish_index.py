#!/usr/bin/env python3
"""Generate diagnostics indexes and site overview without PowerShell."""

from __future__ import annotations

import base64
import html
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import quote

try:
    from zoneinfo import ZoneInfo
except Exception:  # pragma: no cover - zoneinfo may be unavailable in minimal images
    ZoneInfo = None  # type: ignore[assignment]


def _env(name: str) -> Optional[str]:
    value = os.environ.get(name)
    if value:
        return value
    return None


def _first_directory(root: Optional[Path]) -> Optional[Path]:
    if not root or not root.exists():
        return None
    directories = sorted([child for child in root.iterdir() if child.is_dir()])
    selected = directories[0] if directories else None
    for candidate in directories:
        if (candidate / "decision.txt").exists():
            return candidate
    return selected


def _locate_iterate_temp(iterate_root: Optional[Path], iterate_dir: Optional[Path]) -> Optional[Path]:
    if iterate_root and (iterate_root / "_temp").exists():
        return iterate_root / "_temp"
    if iterate_dir and (iterate_dir / "_temp").exists():
        return iterate_dir / "_temp"
    if iterate_root and iterate_root.exists():
        for candidate in iterate_root.rglob("_temp"):
            if candidate.is_dir():
                return candidate
    return None


def _read_json(path: Optional[Path]) -> Optional[dict]:
    if not path or not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def _read_text(path: Optional[Path]) -> Optional[str]:
    if not path or not path.exists():
        return None
    return path.read_text(encoding="utf-8").strip()


def _format_status_value(value: object) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


def _normalize_link(value: str) -> str:
    return value.replace("\\", "/")


def _relative(path: Path, root: Optional[Path]) -> str:
    if root:
        try:
            return path.relative_to(root).as_posix()
        except ValueError:
            pass
    return path.as_posix()


def _escape_href(value: str) -> str:
    return quote(value, safe="/:?&=#%+@-._~")


def _decode_inventory(inventory_b64: Optional[str]) -> list[str]:
    if not inventory_b64:
        return []
    try:
        raw = base64.b64decode(inventory_b64.encode("utf-8"), validate=True)
    except Exception:
        return []
    text = raw.decode("utf-8", errors="replace")
    return text.splitlines()


def _gather_iterate_files(iterate_dir: Optional[Path]) -> list[Path]:
    if not iterate_dir or not iterate_dir.exists():
        return []
    return sorted([child for child in iterate_dir.iterdir() if child.is_file()])


def _gather_ndjson_summaries(artifacts: Optional[Path]) -> list[Path]:
    if not artifacts or not artifacts.exists():
        return []
    return sorted(artifacts.rglob("ndjson_summary.txt"))


def _gather_all_files(diag: Optional[Path]) -> list[Path]:
    if not diag or not diag.exists():
        return []
    return sorted([item for item in diag.rglob("*") if item.is_file()])


def _format_datetime_strings() -> tuple[str, str]:
    utc_now = datetime.now(timezone.utc)
    utc_str = utc_now.isoformat()
    ct_str = "n/a"
    if ZoneInfo is not None:
        try:
            ct = utc_now.astimezone(ZoneInfo("America/Chicago"))
            ct_str = ct.isoformat()
        except Exception:
            ct_str = "n/a"
    return utc_str, ct_str


def _read_tokens(iterate_dir: Optional[Path]) -> dict[str, str]:
    tokens = {"prompt": "n/a", "completion": "n/a", "total": "n/a"}
    if not iterate_dir:
        return tokens
    tokens_path = iterate_dir / "tokens.txt"
    if tokens_path.exists():
        for line in tokens_path.read_text(encoding="utf-8").splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if key and key not in tokens:
                tokens[key] = value.strip()
            elif key in tokens:
                current = tokens[key]
                if current.lower() in {"", "n/a"}:
                    tokens[key] = value.strip()
    return tokens


def _load_response_usage(response_data: Optional[dict], tokens: dict[str, str]) -> None:
    if not response_data:
        return
    usage = response_data.get("usage")
    if not isinstance(usage, dict):
        return
    for key in ("prompt", "completion", "total"):
        field = f"{key}_tokens"
        if field in usage and usage[field] is not None:
            tokens[key] = str(usage[field])


def _diff_produced(iterate_dir: Optional[Path]) -> bool:
    if not iterate_dir:
        return False
    patch_path = iterate_dir / "patch.diff"
    if not patch_path.exists():
        return False
    head = patch_path.read_text(encoding="utf-8", errors="replace").splitlines()[:20]
    if not head:
        return False
    return not (len(head) == 1 and head[0].strip() == "# no changes")


def _inventory_lines_for_markdown(inventory_b64: Optional[str]) -> list[str]:
    lines = _decode_inventory(inventory_b64)
    if not lines:
        return []
    return [*lines]


def _artifact_count(artifacts: Optional[Path]) -> int:
    if not artifacts or not artifacts.exists():
        return 0
    return sum(1 for _ in artifacts.rglob("*") if _.is_file())


def _read_artifact_missing(artifacts: Optional[Path]) -> Optional[str]:
    if not artifacts:
        return None
    missing_path = artifacts / "MISSING.txt"
    if not missing_path.exists():
        return None
    return missing_path.read_text(encoding="utf-8").strip()


def _add_line(collection: list[str], value: str) -> None:
    collection.append(value)


def _write_text(path: Optional[Path], content: str) -> None:
    if not path:
        return
    path.write_text(content, encoding="utf-8")


def _site_has(site: Optional[Path], relative: Optional[str]) -> bool:
    if not site or not relative:
        return False
    return (site / Path(relative)).exists()


def main() -> None:
    diag = _env("DIAG")
    artifacts_env = _env("ARTIFACTS")
    site_env = _env("SITE")
    repo = _env("REPO") or "n/a"
    sha = _env("SHA") or "n/a"
    run_id = _env("RUN_ID") or "n/a"
    run_attempt = _env("RUN_ATTEMPT") or "n/a"
    run_url = _env("RUN_URL") or "n/a"
    short_sha = _env("SHORTSHA") or sha[:7]
    inventory_b64 = _env("INVENTORY_B64")
    batch_run_id = _env("BATCH_RUN_ID")
    batch_run_attempt = _env("BATCH_RUN_ATTEMPT") or "n/a"

    diag_path = Path(diag) if diag else None
    artifacts_path = Path(artifacts_env) if artifacts_env else None
    site_path = Path(site_env) if site_env else None

    utc_str, ct_str = _format_datetime_strings()

    iterate_root = artifacts_path / "iterate" if artifacts_path else None
    iterate_dir = _first_directory(iterate_root)
    if iterate_root and iterate_root.exists():
        for candidate in sorted(iterate_root.iterdir()):
            if candidate.is_dir() and (candidate / "decision.txt").exists():
                iterate_dir = candidate
                break
    iterate_temp = _locate_iterate_temp(iterate_root, iterate_dir)
    response_data = _read_json(iterate_temp / "response.json" if iterate_temp else None)
    status_data = _read_json(iterate_temp / "iterate_status.json" if iterate_temp else None)
    why_no_diff = _read_text(iterate_temp / "why_no_diff.txt" if iterate_temp else None)

    decision = _read_text(iterate_dir / "decision.txt" if iterate_dir else None) or "n/a"
    model = _read_text(iterate_dir / "model.txt" if iterate_dir else None) or "n/a"
    endpoint = _read_text(iterate_dir / "endpoint.txt" if iterate_dir else None) or "n/a"
    http_status = _read_text(iterate_dir / "http_status.txt" if iterate_dir else None) or "n/a"

    if response_data:
        if response_data.get("http_status") is not None:
            http_status = str(response_data["http_status"])
        if response_data.get("model"):
            model = str(response_data["model"])

    tokens = _read_tokens(iterate_dir)
    _load_response_usage(response_data, tokens)

    attempt_summary = None
    if status_data:
        attempt_summary = "attempted={0} gate={1} auth_ok={2} attempts_left={3}".format(
            _format_status_value(status_data.get("attempted")),
            _format_status_value(status_data.get("gate")),
            _format_status_value(status_data.get("auth_ok")),
            _format_status_value(status_data.get("attempts_left")),
        )

    diff_produced = _diff_produced(iterate_dir)
    outcome = "n/a"
    if why_no_diff:
        outcome = why_no_diff
    elif diff_produced:
        outcome = "diff produced"

    ndjson_summaries = _gather_ndjson_summaries(artifacts_path)
    iterate_files = _gather_iterate_files(iterate_dir)
    all_files = _gather_all_files(diag_path)

    iterate_zip_name = f"iterate-{run_id}-{run_attempt}.zip"
    iterate_zip_path = (diag_path / "logs" / iterate_zip_name) if diag_path else None
    iterate_status = "found" if iterate_zip_path and iterate_zip_path.exists() else "missing (see logs/iterate.MISSING.txt)"

    batch_zip_name = None
    batch_status = "missing"
    if batch_run_id:
        batch_zip_name = f"batch-check-{batch_run_id}-{batch_run_attempt}.zip"
        batch_zip_path = (diag_path / "logs" / batch_zip_name) if diag_path else None
        if batch_zip_path and batch_zip_path.exists():
            batch_status = f"found (run {batch_run_id}, attempt {batch_run_attempt})"
        else:
            batch_status = f"missing archive (run {batch_run_id}, attempt {batch_run_attempt})"
    elif diag_path and (diag_path / "logs" / "batch-check.MISSING.txt").exists():
        batch_status = "missing (see logs/batch-check.MISSING.txt)"

    artifact_count = _artifact_count(artifacts_path)
    artifact_missing = _read_artifact_missing(artifacts_path)

    markdown_lines: list[str] = []
    for line in [
        "# CI Diagnostics",
        f"Repo: {repo}",
        f"Commit: {sha}",
        f"Run: {run_id} (attempt {run_attempt})",
        f"Built (UTC): {utc_str}",
        f"Built (CT): {ct_str}",
        f"Run page: {run_url}",
        "",
        "## Status",
        f"- Iterate logs: {iterate_status}",
        f"- Batch-check run id: {batch_status}",
        f"- Artifact files enumerated: {artifact_count}",
    ]:
        _add_line(markdown_lines, line)

    if artifact_missing:
        _add_line(markdown_lines, f"- Artifact sentinel: {artifact_missing}")

    _add_line(markdown_lines, "")
    _add_line(markdown_lines, "## Quick links")

    diag_bundle_links = [
        {"label": "Inventory (HTML)", "path": "inventory.html", "exists": diag_path and (diag_path / "inventory.html").exists()},
        {"label": "Inventory (text)", "path": "inventory.txt", "exists": diag_path and (diag_path / "inventory.txt").exists()},
        {"label": "Inventory (markdown)", "path": "inventory.md", "exists": diag_path and (diag_path / "inventory.md").exists()},
        {"label": "Inventory (json)", "path": "inventory.json", "exists": diag_path and (diag_path / "inventory.json").exists()},
        {"label": "Iterate logs zip", "path": f"logs/{iterate_zip_name}", "exists": iterate_zip_path.exists() if iterate_zip_path else False},
        {"label": "Batch-check logs zip", "path": f"logs/{batch_zip_name}" if batch_zip_name else None, "exists": bool(batch_zip_name and diag_path and (diag_path / "logs" / batch_zip_name).exists())},
        {"label": "Batch-check failing tests", "path": "batchcheck_failing.txt", "exists": diag_path and (diag_path / "batchcheck_failing.txt").exists()},
        {"label": "Batch-check fail debug", "path": "batchcheck_fail-debug.txt", "exists": diag_path and (diag_path / "batchcheck_fail-debug.txt").exists()},
        {"label": "Repository zip", "path": f"repo/repo-{short_sha}.zip", "exists": diag_path and (diag_path / "repo" / f"repo-{short_sha}.zip").exists()},
        {"label": "Repository files (unzipped)", "path": "repo/files/", "exists": diag_path and (diag_path / "repo" / "files").exists()},
    ]

    if diag_path and (diag_path / "wf").exists():
        for wf in sorted((diag_path / "wf").iterdir()):
            if wf.is_file() and wf.name.endswith(".yml.txt"):
                diag_bundle_links.append({"label": f"Workflow: {wf.name}", "path": f"wf/{wf.name}", "exists": True})

    for entry in diag_bundle_links:
        path_value = entry.get("path")
        if not path_value:
            continue
        if entry.get("exists"):
            norm = _normalize_link(path_value)
            _add_line(markdown_lines, f"- {entry['label']}: [{norm}]({norm})")
        else:
            _add_line(markdown_lines, f"- {entry['label']}: missing")

    _add_line(markdown_lines, "")
    _add_line(markdown_lines, "## Iterate metadata")
    for seed in [
        f"- Decision: {decision}",
        f"- Outcome: {outcome}",
        f"- HTTP status: {http_status}",
        f"- Model: {model}",
        f"- Endpoint: {endpoint}",
        f"- Tokens: prompt={tokens['prompt']} completion={tokens['completion']} total={tokens['total']}",
    ]:
        _add_line(markdown_lines, seed)

    if not response_data and attempt_summary:
        _add_line(markdown_lines, f"- Attempt summary: {attempt_summary}")

    if iterate_files:
        _add_line(markdown_lines, "")
        _add_line(markdown_lines, "### Iterate files")
        for file_path in iterate_files:
            rel = _relative(file_path, diag_path)
            norm = _normalize_link(rel)
            _add_line(markdown_lines, f"- [`{norm}`]({norm})")

    if artifacts_path:
        batch_meta = artifacts_path / "batch-check" / "run.json"
        meta = _read_json(batch_meta)
        if meta:
            _add_line(markdown_lines, "")
            _add_line(markdown_lines, "## Batch-check run")
            _add_line(markdown_lines, f"- Run id: {meta.get('run_id', 'n/a')} (attempt {meta.get('run_attempt', 'n/a')})")
            _add_line(markdown_lines, f"- Status: {meta.get('status', 'n/a')} / {meta.get('conclusion', 'n/a')}")
            if meta.get("html_url"):
                _add_line(markdown_lines, f"- Run page: {meta['html_url']}")

    if ndjson_summaries:
        _add_line(markdown_lines, "")
        _add_line(markdown_lines, "## NDJSON summaries")
        for file_path in ndjson_summaries:
            rel = _relative(file_path, diag_path)
            _add_line(markdown_lines, f"### {rel}")
            _add_line(markdown_lines, "```text")
            for segment in file_path.read_text(encoding="utf-8", errors="replace").splitlines():
                _add_line(markdown_lines, segment)
            _add_line(markdown_lines, "```")

    if all_files:
        _add_line(markdown_lines, "")
        _add_line(markdown_lines, "## File listing")
        for item in all_files:
            rel = _relative(item, diag_path)
            size = f"{item.stat().st_size:,}"
            norm = _normalize_link(rel)
            _add_line(markdown_lines, f"- [{size} bytes]({norm})")

    inventory_lines = _inventory_lines_for_markdown(inventory_b64)
    if inventory_lines:
        _add_line(markdown_lines, "")
        _add_line(markdown_lines, "## Inventory (raw)")
        for entry in inventory_lines:
            _add_line(markdown_lines, entry)

    md_path = diag_path / "index.md" if diag_path else None
    _write_text(md_path, "\n".join(markdown_lines) + "\n")

    html_lines: list[str] = [
        "<!doctype html>",
        "<html lang=\"en\">",
        "<head>",
        "<meta charset=\"utf-8\">",
        "<title>CI Diagnostics</title>",
        "</head>",
        "<body>",
        "<h1>CI Diagnostics</h1>",
    ]

    metadata_pairs = [
        ("Repo", repo, None),
        ("Commit", sha, None),
        ("Run", f"{run_id} (attempt {run_attempt})", None),
        ("Built (UTC)", utc_str, None),
        ("Built (CT)", ct_str, None),
        ("Run page", run_url, run_url),
    ]

    html_lines.append("<section>")
    html_lines.append("<h2>Metadata</h2>")
    html_lines.append("<ul>")
    for label, value, href in metadata_pairs:
        escaped_label = html.escape(label)
        if href:
            html_lines.append(
                f"<li><strong>{escaped_label}:</strong> <a href=\"{_escape_href(href)}\">{html.escape(value)}</a></li>"
            )
        else:
            html_lines.append(f"<li><strong>{escaped_label}:</strong> {html.escape(value)}</li>")
    html_lines.append("</ul>")
    html_lines.append("</section>")

    status_pairs = [
        ("Iterate logs", iterate_status),
        ("Batch-check run id", batch_status),
        ("Artifact files enumerated", str(artifact_count)),
    ]
    if artifact_missing:
        status_pairs.append(("Artifact sentinel", artifact_missing))

    html_lines.append("<section>")
    html_lines.append("<h2>Status</h2>")
    html_lines.append("<ul>")
    for label, value in status_pairs:
        html_lines.append(f"<li><strong>{html.escape(label)}:</strong> {html.escape(value)}</li>")
    html_lines.append("</ul>")
    html_lines.append("</section>")

    html_lines.append("<section>")
    html_lines.append("<h2>Quick links</h2>")
    html_lines.append("<ul>")
    for entry in diag_bundle_links:
        label = html.escape(entry["label"])
        path_value = entry.get("path")
        if path_value and entry.get("exists"):
            href = _escape_href(_normalize_link(path_value))
            html_lines.append(f"<li><a href=\"{href}\">{label}</a></li>")
        else:
            html_lines.append(f"<li>{label}: missing</li>")
    html_lines.append("</ul>")
    html_lines.append("</section>")

    iterate_pairs = [
        ("Decision", decision),
        ("Outcome", outcome),
        ("HTTP status", http_status),
        ("Model", model),
        ("Endpoint", endpoint),
        ("Tokens", f"prompt={tokens['prompt']} completion={tokens['completion']} total={tokens['total']}")
    ]
    if not response_data and attempt_summary:
        iterate_pairs.append(("Attempt summary", attempt_summary))

    html_lines.append("<section>")
    html_lines.append("<h2>Iterate metadata</h2>")
    html_lines.append("<ul>")
    for label, value in iterate_pairs:
        html_lines.append(f"<li><strong>{html.escape(label)}:</strong> {html.escape(value)}</li>")
    html_lines.append("</ul>")
    html_lines.append("</section>")

    if iterate_files:
        html_lines.append("<section>")
        html_lines.append("<h3>Iterate files</h3>")
        html_lines.append("<ul>")
        for file_path in iterate_files:
            rel = _normalize_link(_relative(file_path, diag_path))
            href = _escape_href(rel)
            html_lines.append(f"<li><code><a href=\"{href}\">{html.escape(rel)}</a></code></li>")
        html_lines.append("</ul>")
        html_lines.append("</section>")

    if artifacts_path:
        meta = _read_json(artifacts_path / "batch-check" / "run.json")
        if meta:
            html_lines.append("<section>")
            html_lines.append("<h2>Batch-check run</h2>")
            html_lines.append("<ul>")
            html_lines.append(
                f"<li>Run id: {html.escape(str(meta.get('run_id', 'n/a')))} (attempt {html.escape(str(meta.get('run_attempt', 'n/a')) )})</li>"
            )
            html_lines.append(
                f"<li>Status: {html.escape(str(meta.get('status', 'n/a')))} / {html.escape(str(meta.get('conclusion', 'n/a')))}</li>"
            )
            if meta.get("html_url"):
                html_lines.append(f"<li><a href=\"{_escape_href(str(meta['html_url']))}\">Run page</a></li>")
            html_lines.append("</ul>")
            html_lines.append("</section>")

    if ndjson_summaries:
        html_lines.append("<section>")
        html_lines.append("<h2>NDJSON summaries</h2>")
        for file_path in ndjson_summaries:
            rel = _relative(file_path, diag_path)
            html_lines.append(f"<h3>{html.escape(rel)}</h3>")
            html_lines.append("<pre>")
            for segment in file_path.read_text(encoding="utf-8", errors="replace").splitlines():
                html_lines.append(html.escape(segment))
            html_lines.append("</pre>")
        html_lines.append("</section>")

    if all_files:
        html_lines.append("<section>")
        html_lines.append("<h2>File listing</h2>")
        html_lines.append("<ul>")
        for item in all_files:
            rel = _normalize_link(_relative(item, diag_path))
            href = _escape_href(rel)
            size = f"{item.stat().st_size:,} bytes"
            html_lines.append(f"<li><a href=\"{href}\">{html.escape(rel)}</a> — {html.escape(size)}</li>")
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

    html_path = diag_path / "index.html" if diag_path else None
    _write_text(html_path, "\n".join(html_lines) + "\n")

    # Site overview
    bundle_prefix = f"diag/{run_id}-{run_attempt}"
    cache_buster = run_id
    bundle_index = f"{bundle_prefix}/index.html"
    bundle_index_href = f"{bundle_index}?v={cache_buster}" if cache_buster else bundle_index
    inventory_html_rel = f"{bundle_prefix}/inventory.html"
    inventory_txt_rel = f"{bundle_prefix}/inventory.txt"
    inventory_md_rel = f"{bundle_prefix}/inventory.md"
    iterate_zip_rel = f"{bundle_prefix}/logs/{iterate_zip_name}"
    batch_zip_rel = f"{bundle_prefix}/logs/{batch_zip_name}" if batch_zip_name else None
    repo_zip_rel = f"{bundle_prefix}/repo/repo-{short_sha}.zip"
    repo_files_rel = f"{bundle_prefix}/repo/files/"

    iterate_dir_for_site = _first_directory(iterate_root)
    decision_site = _read_text(iterate_dir_for_site / "decision.txt" if iterate_dir_for_site else None) or "n/a"
    http_status_site = _read_text(iterate_dir_for_site / "http_status.txt" if iterate_dir_for_site else None) or "n/a"

    summary_preview: list[str] = []
    if ndjson_summaries:
        summary_preview.append("```text")
        summary_preview.extend(ndjson_summaries[0].read_text(encoding="utf-8", errors="replace").splitlines())
        summary_preview.append("```")

    site_lines: list[str] = [
        "# Diagnostics overview",
        "",
        f"Latest run: [{run_id} (attempt {run_attempt})]({bundle_index_href})",
        "",
        "## Metadata",
        f"- Repo: {repo}",
        f"- Commit: {sha}",
        f"- Run page: {run_url}",
        f"- Iterate decision: {decision_site}",
        f"- Iterate HTTP status: {http_status_site}",
        "",
        "## Quick links",
    ]

    if _site_has(site_path, bundle_index):
        site_lines.append(f"- [Bundle index]({_normalize_link(bundle_index_href)})")
        site_lines.append(f"- [Open latest (cache-busted)]({_normalize_link(bundle_index_href)})")
    else:
        site_lines.append("- Bundle index: missing")

    if _site_has(site_path, inventory_html_rel):
        site_lines.append(f"- [Artifact inventory (HTML)]({_normalize_link(inventory_html_rel)})")
    else:
        site_lines.append("- Artifact inventory (HTML): missing")

    if _site_has(site_path, inventory_txt_rel):
        site_lines.append(f"- [Artifact inventory (text)]({_normalize_link(inventory_txt_rel)})")
    else:
        site_lines.append("- Artifact inventory (text): missing")

    if _site_has(site_path, iterate_zip_rel):
        site_lines.append(f"- [Iterate logs zip]({iterate_zip_rel})")
    else:
        site_lines.append("- Iterate logs zip: missing")

    if batch_zip_rel:
        if _site_has(site_path, batch_zip_rel):
            site_lines.append(f"- [Batch-check logs zip]({batch_zip_rel})")
        else:
            site_lines.append("- Batch-check logs zip: missing")
    else:
        site_lines.append("- Batch-check logs zip: missing")

    if _site_has(site_path, repo_zip_rel):
        site_lines.append(f"- [Repository zip]({_normalize_link(repo_zip_rel)})")
    else:
        site_lines.append("- Repository zip: missing")

    if _site_has(site_path, repo_files_rel.rstrip("/")):
        site_lines.append(f"- [Repository files (unzipped)]({_normalize_link(repo_files_rel)})")
    else:
        site_lines.append("- Repository files (unzipped): missing")

    if _site_has(site_path, inventory_md_rel):
        site_lines.append(f"- [Inventory (markdown)]({_normalize_link(inventory_md_rel)})")
    else:
        site_lines.append("- Inventory (markdown): missing")

    if summary_preview:
        site_lines.append("")
        site_lines.append("## NDJSON summary (first bundle)")
        site_lines.extend(summary_preview)

    site_lines.append("")
    site_lines.append("Artifacts from the self-test workflow and iterate job are merged under the bundle directory above.")

    _write_text(site_path / "index.md" if site_path else None, "\n".join(site_lines) + "\n")

    site_html_lines: list[str] = [
        "<!doctype html>",
        "<html lang=\"en\">",
        "<head>",
        "<meta charset=\"utf-8\">",
        "<title>Diagnostics overview</title>",
        "</head>",
        "<body>",
        "<h1>Diagnostics overview</h1>",
        f"<p>Latest run: <a href=\"{_escape_href(_normalize_link(bundle_index_href))}\">{html.escape(f'{run_id} (attempt {run_attempt})')}</a></p>",
        "<section>",
        "<h2>Metadata</h2>",
        "<ul>",
    ]

    metadata_items = [
        ("Repo", repo, None),
        ("Commit", sha, None),
        ("Run page", run_url, run_url),
        ("Iterate decision", decision_site, None),
        ("Iterate HTTP status", http_status_site, None),
    ]
    for label, value, href in metadata_items:
        if href:
            site_html_lines.append(
                f"<li><strong>{html.escape(label)}:</strong> <a href=\"{_escape_href(href)}\">{html.escape(value)}</a></li>"
            )
        else:
            site_html_lines.append(f"<li><strong>{html.escape(label)}:</strong> {html.escape(value)}</li>")
    site_html_lines.append("</ul>")
    site_html_lines.append("</section>")

    quick_links = [
        ("Bundle index", bundle_index_href, _site_has(site_path, bundle_index)),
        ("Open latest (cache-busted)", bundle_index_href, _site_has(site_path, bundle_index)),
        ("Artifact inventory (HTML)", inventory_html_rel, _site_has(site_path, inventory_html_rel)),
        ("Artifact inventory (text)", inventory_txt_rel, _site_has(site_path, inventory_txt_rel)),
        ("Iterate logs zip", iterate_zip_rel, _site_has(site_path, iterate_zip_rel)),
        ("Batch-check logs zip", batch_zip_rel, _site_has(site_path, batch_zip_rel) if batch_zip_rel else False),
        ("Repository zip", repo_zip_rel, _site_has(site_path, repo_zip_rel)),
        ("Repository files (unzipped)", repo_files_rel, _site_has(site_path, repo_files_rel.rstrip("/"))),
        ("Inventory (markdown)", inventory_md_rel, _site_has(site_path, inventory_md_rel)),
    ]

    site_html_lines.append("<section>")
    site_html_lines.append("<h2>Quick links</h2>")
    site_html_lines.append("<ul>")
    for label, path_value, exists in quick_links:
        if path_value and exists:
            site_html_lines.append(f"<li><a href=\"{_escape_href(_normalize_link(path_value))}\">{html.escape(label)}</a></li>")
        else:
            site_html_lines.append(f"<li>{html.escape(label)}: missing</li>")
    site_html_lines.append("</ul>")
    site_html_lines.append("</section>")

    if summary_preview:
        site_html_lines.append("<section>")
        site_html_lines.append("<h2>NDJSON summary (first bundle)</h2>")
        site_html_lines.append("<pre>")
        for line in summary_preview:
            if line.startswith("```"):
                continue
            site_html_lines.append(html.escape(line))
        site_html_lines.append("</pre>")
        site_html_lines.append("</section>")

    site_html_lines.append("<p>Artifacts from the self-test workflow and iterate job are merged under the bundle directory above.</p>")
    site_html_lines.append("</body>")
    site_html_lines.append("</html>")

    _write_text(site_path / "index.html" if site_path else None, "\n".join(site_html_lines) + "\n")

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
        _write_text(site_path / "latest.json", json.dumps(latest, indent=2) + "\n")


if __name__ == "__main__":
    main()
