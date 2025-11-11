"""Inline model quick-fix helper for batch-check workflow.

This utility orchestrates two phases:

1. ``stage`` — download the current run's logs, locate the first failing step,
   build ``_ctx`` with ``failpack.log``, ``guide.json``, trimmed attachments,
   and a manifest describing the staged files.
2. ``call`` — upload staged attachments to OpenAI's Files API, invoke the
   Responses API request, persist the raw response, and extract any fenced diff
   into ``_ctx/fix.patch``.

The script intentionally writes human-readable breadcrumbs to
``_ctx/notes.txt`` for diagnostics packaging.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import shutil
import sys
import textwrap
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Tuple
from zipfile import ZipFile


# ``requests`` keeps the HTTP plumbing readable. The workflow installs it
# explicitly before invoking this helper; fail fast with a friendly message
# if the dependency is missing so the runner log explains the requirement.
try:  # pragma: no cover - dependency guard for the workflow runner
    import requests
except ImportError as exc:  # pragma: no cover - surfaced in CI logs
    raise SystemExit(
        "The requests module is required. Install it with 'python -m pip install requests'."
    ) from exc


FATAL_PATTERNS = [
    re.compile(r"::error"),
    re.compile(r"^Error:", re.MULTILINE),
    re.compile(r"Traceback"),
    re.compile(r"^Failed tests?", re.MULTILINE),
    re.compile(r"Process completed with exit code [1-9]", re.MULTILINE),
]

PRIMARY_HINT_PATTERNS = [
    re.compile(r"File \"([^\"]+)\", line (\d+)", re.IGNORECASE),
    re.compile(r"([A-Za-z0-9_/\\.\-]+):(\d+)", re.IGNORECASE),
    re.compile(r"([A-Za-z0-9_/\\.\-]+) \(line (\d+)\)", re.IGNORECASE),
]

INCLUDE_GLOBS = [
    "*.py",
    "*.ps1",
    "*.psm1",
    "*.yml",
    "*.yaml",
    "*.sh",
    "*.bat",
    "*.cmd",
    "*.md",
    "*.txt",
    "*.json",
]

EXCLUDED_PARTS = {
    ".git",
    ".github/pages",
    ".venv",
    "venv",
    "env",
    "node_modules",
    "dist",
    "build",
    "_artifacts",
    "_site",
    ".pytest_cache",
    "logs",
    "_ctx",
}

# derived requirement: run 19252219085-1 failed when uploading .log attachments;
# OpenAI's Files API now enforces this extension allowlist. Keep it in sync with
# the error payload so iterate never regresses into upload_failed again.
ALLOWED_FILE_EXTENSIONS = {
    "c",
    "cpp",
    "cs",
    "css",
    "csv",
    "doc",
    "docx",
    "gif",
    "go",
    "html",
    "java",
    "jpeg",
    "jpg",
    "js",
    "json",
    "md",
    "pdf",
    "php",
    "pkl",
    "png",
    "pptx",
    "py",
    "rb",
    "tar",
    "tex",
    "ts",
    "txt",
    "webp",
    "xlsx",
    "xml",
    "zip",
}

TEXT_SANITIZE_LIMIT = 1 * 1024 * 1024


def debug(msg: str) -> None:
    print(msg)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def ensure_ctx(repo_root: Path) -> Path:
    """Guarantee that the shared _ctx workspace exists."""

    ctx_dir = repo_root / "_ctx"
    ctx_dir.mkdir(parents=True, exist_ok=True)
    return ctx_dir


def _is_extension_allowed(path: Path) -> bool:
    suffix = path.suffix.lower().lstrip(".")
    if not suffix:
        return True
    return suffix in ALLOWED_FILE_EXTENSIONS


def _is_probably_text(data: bytes) -> bool:
    if b"\x00" in data:
        return False
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def _sanitize_attachment(path: Path, ctx_dir: Path) -> Tuple[Path, str]:
    """Create an allowed-format copy of *path* for OpenAI uploads."""

    sanitized_root = ctx_dir / "_sanitized"
    sanitized_root.mkdir(parents=True, exist_ok=True)

    size = path.stat().st_size
    note_reason = "ext not allowed"
    if size <= TEXT_SANITIZE_LIMIT:
        data = path.read_bytes()
        if _is_probably_text(data):
            target_name = f"{path.name}.txt"
            sanitized_path = sanitized_root / target_name
            sanitized_path.write_bytes(data)
            note = f"upload_sanitized: {path.name} -> {target_name} (reason: {note_reason})"
            return sanitized_path, note

    # Fallback to zipping the original payload when it's large or binary.
    # derived requirement: runs with binary failpacks hit the extension wall;
    # wrapping them in a small zip keeps the evidence intact while satisfying
    # OpenAI's allowlist.
    base_name = f"{path.stem or path.name}_sanitized.zip"
    sanitized_path = sanitized_root / base_name
    counter = 1
    while sanitized_path.exists():
        sanitized_path = sanitized_root / f"{path.stem or path.name}_sanitized_{counter}.zip"
        counter += 1
    with ZipFile(sanitized_path, "w") as archive:
        archive.write(path, arcname=path.name)
    note = (
        f"upload_sanitized: {path.name} -> {sanitized_path.name} "
        f"(reason: {note_reason} zipped)"
    )
    return sanitized_path, note


def path_in_repo(candidate: str, repo_root: Path) -> Optional[Path]:
    try:
        normalized = candidate.replace("\\", "/")
        absolute = Path(normalized)
        if absolute.is_absolute():
            try:
                rel = absolute.relative_to(repo_root)
            except ValueError:
                text = str(absolute)
                root_text = str(repo_root)
                if root_text in text:
                    rel_text = text[text.index(root_text) + len(root_text) :]
                    rel = Path(rel_text.lstrip("/\\"))
                else:
                    return None
            return rel
        return Path(normalized)
    except Exception:
        return None


def is_excluded(rel_path: Path) -> bool:
    parts = rel_path.parts
    for idx in range(1, len(parts) + 1):
        segment = "/".join(parts[:idx])
        segment_no_slash = segment.rstrip("/")
        if segment in EXCLUDED_PARTS or segment_no_slash in EXCLUDED_PARTS:
            return True
    return False


def matches_globs(rel_path: Path) -> bool:
    from fnmatch import fnmatch

    return any(fnmatch(rel_path.name, pattern) for pattern in INCLUDE_GLOBS)


def iter_repo_files(repo_root: Path) -> Iterable[Path]:
    for path in sorted(repo_root.rglob("*")):
        if not path.is_file():
            continue
        try:
            rel = path.relative_to(repo_root)
        except ValueError:
            continue
        if is_excluded(rel):
            continue
        if matches_globs(rel):
            yield rel


def trim_content(text: str, limit: int) -> str:
    if len(text.encode("utf-8")) <= limit:
        return text

    lines = text.splitlines()
    if not lines:
        return text[: limit // 2]

    header_count = min(10, len(lines))
    head_count = min(300, len(lines))
    tail_count = min(300, len(lines))

    header = lines[:header_count]
    head = lines[header_count:head_count]
    tail = lines[-tail_count:]

    segments: List[str] = []
    segments.extend(header)
    if head:
        segments.append("\n# --- head (trimmed) ---\n")
        segments.extend(head)
    segments.append("\n# --- trimmed ---\n")
    segments.extend(tail)

    trimmed = "\n".join(segments)
    encoded = trimmed.encode("utf-8")
    if len(encoded) <= limit:
        return trimmed

    return encoded[:limit].decode("utf-8", errors="ignore")


@dataclass
class StageResult:
    failpack_path: Path
    guide_path: Path
    primary_file: Path
    primary_line: Optional[int]
    attachments: List[dict]
    notes: List[str]


def download_logs(repo: str, run_id: str, token: str, dest: Path) -> None:
    url = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/logs"
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": "inline-model-fix",
        "Accept": "application/vnd.github+json",
    }
    debug(f"Downloading logs from {url}")
    response = requests.get(url, headers=headers, timeout=60)
    if response.status_code != 200:
        raise RuntimeError(f"Failed to download logs: HTTP {response.status_code}")
    dest.write_bytes(response.content)


def list_run_artifacts(repo: str, run_id: str, token: str) -> List[dict]:
    url = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100"
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": "inline-model-fix",
        "Accept": "application/vnd.github+json",
    }
    debug(f"Listing artifacts from {url}")
    response = requests.get(url, headers=headers, timeout=60)
    if response.status_code != 200:
        debug(f"artifact_list_error=HTTP {response.status_code}")
        return []
    payload = response.json()
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list):
        return []
    return artifacts


def download_artifact_zip(repo: str, artifact_id: str, token: str, dest: Path) -> bool:
    url = f"https://api.github.com/repos/{repo}/actions/artifacts/{artifact_id}/zip"
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": "inline-model-fix",
        "Accept": "application/vnd.github+json",
    }
    debug(f"Downloading artifact {artifact_id} from {url}")
    response = requests.get(url, headers=headers, timeout=60)
    if response.status_code != 200:
        debug(f"artifact_download_error={artifact_id} status={response.status_code}")
        return False
    dest.write_bytes(response.content)
    return True


ARTIFACT_FALLBACK_PREFIXES = [
    "bootstrapper-tests",
    "selftest-verdict-",
    "ci_test_results-",
    "test-logs-",
]


def extract_fallback_artifacts(
    repo: str,
    run_id: str,
    token: str,
    attached_dir: Path,
    notes: List[str],
) -> tuple[List[str], List[dict]]:
    ensure_dir(attached_dir)
    artifacts_root = attached_dir / "artifacts"
    ensure_dir(artifacts_root)
    artifacts = list_run_artifacts(repo, run_id, token)
    selected: List[str] = []
    attached_entries: List[dict] = []
    for prefix in ARTIFACT_FALLBACK_PREFIXES:
        lower_prefix = prefix.lower()
        for item in artifacts:
            name = str(item.get("name", ""))
            if not name:
                continue
            if not str(name).lower().startswith(lower_prefix):
                continue
            if item.get("expired"):
                notes.append(f"fallback_artifact_expired={name}")
                continue
            artifact_id = str(item.get("id"))
            if not artifact_id or not artifact_id.isdigit():
                notes.append(f"fallback_artifact_invalid_id={name}")
                continue
            safe_name = re.sub(r"[^0-9A-Za-z_.-]", "-", name)
            zip_path = artifacts_root / f"{safe_name}.zip"
            if download_artifact_zip(repo, artifact_id, token, zip_path):
                target_dir = artifacts_root / f"artifact-{safe_name}"
                try:
                    extract_zip(zip_path, target_dir)
                    selected.append(name)
                    notes.append(f"fallback_artifact_downloaded={name}")
                    for file_path in sorted(target_dir.rglob("*")):
                        if not file_path.is_file():
                            continue
                        try:
                            size = file_path.stat().st_size
                        except OSError:
                            size = 0
                        rel = file_path.relative_to(attached_dir)
                        attached_entries.append(
                            {
                                "name": str(rel).replace("\\", "/"),
                                "size": size,
                            }
                        )
                except Exception as exc:
                    notes.append(f"fallback_artifact_extract_error={name} error={exc}")
                finally:
                    try:
                        zip_path.unlink()
                    except OSError:
                        pass
            else:
                notes.append(f"fallback_artifact_download_failed={name}")
    return selected, attached_entries


def extract_zip(zip_path: Path, dest: Path) -> None:
    with ZipFile(zip_path) as zf:
        zf.extractall(dest)


def find_first_failure(log_root: Path, notes: List[str]) -> Optional[Path]:
    candidates = sorted(
        [p for p in log_root.rglob("*") if p.is_file() and p.suffix.lower() in {".txt", ".log"}]
    )
    notes.append(f"log_files_scanned={len(candidates)}")
    for path in candidates:
        text = read_text(path)
        for pattern in FATAL_PATTERNS:
            if pattern.search(text):
                notes.append(f"fail_marker={pattern.pattern} source={path.relative_to(log_root)}")
                return path
    if candidates:
        notes.append("fail_marker=not_found; using first log file")
        return candidates[0]
    notes.append("fail_marker=not_found; no log files located")
    return None


def derive_primary(text: str, repo_root: Path, notes: List[str]) -> tuple[Path, Optional[int]]:
    for pattern in PRIMARY_HINT_PATTERNS:
        for match in pattern.finditer(text):
            raw_path, raw_line = match.group(1), match.group(2)
            candidate = path_in_repo(raw_path, repo_root)
            if not candidate:
                continue
            rel = candidate
            if rel.is_absolute():
                try:
                    rel = rel.relative_to(repo_root)
                except ValueError:
                    continue
            normalized = Path("/".join(rel.parts))
            file_path = repo_root / normalized
            if file_path.exists():
                try:
                    line = int(raw_line)
                except Exception:
                    line = None
                notes.append(f"primary_hint={normalized} line={line}")
                return normalized, line
    notes.append("primary_hint=not_found; defaulting to README.md")
    return Path("README.md"), None


def stage_attachments(
    repo_root: Path,
    ctx_dir: Path,
    failpack: Path,
    guide: Path,
    primary: Path,
    per_file_cap: int,
    total_cap: int,
    notes: List[str],
) -> List[dict]:
    attached_dir = ctx_dir / "attached"
    ensure_dir(attached_dir)

    staged: List[dict] = []
    total_bytes = 0

    def add_attachment(rel: Path, source: Path, essential: bool = False) -> None:
        nonlocal total_bytes
        dest = attached_dir / rel
        ensure_dir(dest.parent)
        text = read_text(source)
        trimmed = text
        trimmed_flag = False
        if len(text.encode("utf-8")) > per_file_cap:
            trimmed = trim_content(text, per_file_cap)
            trimmed_flag = True
        size = len(trimmed.encode("utf-8"))
        if not essential and total_bytes + size > total_cap:
            notes.append(f"skipped_due_to_cap={rel}")
            return
        dest.write_text(trimmed, encoding="utf-8")
        staged.append({"name": str(rel).replace("\\", "/"), "size": size})
        total_bytes += size
        if trimmed_flag:
            notes.append(f"trimmed_attachment={rel} original_size={len(text.encode('utf-8'))}")

    essentials = [
        (Path("guide.json"), guide),
        (Path("failpack.log"), failpack),
    ]

    for rel, src in essentials:
        add_attachment(rel, src, essential=True)

    candidate_primary = repo_root / primary
    if candidate_primary.exists():
        add_attachment(primary, candidate_primary, essential=True)

    special_paths = [
        Path(".github/workflows/batch-check.yml"),
        Path("README.md"),
        Path("AGENTS.md"),
    ]
    for rel in special_paths:
        src = repo_root / rel
        if src.exists():
            add_attachment(rel, src, essential=True)

    for rel in iter_repo_files(repo_root):
        if rel in {primary, *special_paths}:
            continue
        src = repo_root / rel
        add_attachment(rel, src, essential=False)

    notes.append(f"attachment_total_bytes={total_bytes}")
    notes.append(f"attachment_count={len(staged)}")
    return staged


def write_manifest(ctx_dir: Path, attachments: List[dict]) -> None:
    manifest = ctx_dir / "iterate_context_manifest.tsv"
    with manifest.open("w", encoding="utf-8") as handle:
        for item in attachments:
            handle.write(f"{item['name']}\t{item['size']}\n")

    plan = ctx_dir / "upload_plan.json"
    plan.write_text(json.dumps({"files": attachments}, indent=2) + "\n", encoding="utf-8")


def write_notes(ctx_dir: Path, notes: List[str]) -> None:
    note_path = ctx_dir / "notes.txt"
    note_path.write_text("\n".join(notes) + "\n", encoding="utf-8")


def append_note(ctx_dir: Path, message: str) -> None:
    note_path = ctx_dir / "notes.txt"
    if not note_path.exists():
        # derived requirement: workflows like run 19214772212-1 call append_note during
        # failure handling before stage writes the initial notes header. Touch the file
        # so diagnostics always capture at least one breadcrumb per iterate attempt.
        note_path.parent.mkdir(parents=True, exist_ok=True)
        note_path.write_text("", encoding="utf-8")
    with note_path.open("a", encoding="utf-8") as handle:
        handle.write(message + "\n")


def stage_phase(args: argparse.Namespace) -> None:
    repo_root = Path.cwd()
    ctx_dir = repo_root / "_ctx"
    if ctx_dir.exists():
        shutil.rmtree(ctx_dir)
    ensure_dir(ctx_dir)
    attached_dir = ctx_dir / "attached"
    # Professional note: artifact fallbacks must live under _ctx/attached so the iterate zip
    # always carries the bootstrapper evidence even when GitHub withholds logs.zip.
    ensure_dir(attached_dir)

    notes: List[str] = []
    notes.append(f"run_id={args.run_id}")
    notes.append(f"run_attempt={args.run_attempt}")

    logs_zip = ctx_dir / "logs.zip"
    logs_dir = ctx_dir / "logs"
    ensure_dir(logs_dir)

    logs_available = False
    fallback_names: List[str] = []
    fallback_entries: List[dict] = []
    current_run = os.environ.get("GITHUB_RUN_ID")
    is_current_run = bool(current_run and current_run == args.run_id)

    if is_current_run:
        # Professional note: GitHub withholds the current run's logs until the workflow completes;
        # skip the logs.zip fetch entirely so same-run staging always falls back to artifacts.
        notes.append("log_download_skipped=current_run")
    else:
        try:
            download_logs(args.repo, args.run_id, args.token, logs_zip)
            extract_zip(logs_zip, logs_dir)
            logs_available = True
        except RuntimeError as exc:
            # Professional note: prior runs can 404/403 until GitHub finalizes the archive;
            # record the failure but continue so artifact packaging still succeeds.
            notes.append(f"log_download_error={exc}")
        except Exception as exc:
            notes.append(f"log_download_error={exc}")

    fallback_root = attached_dir / "artifacts"
    fallback_names, fallback_entries = extract_fallback_artifacts(
        args.repo,
        args.run_id,
        args.token,
        attached_dir,
        notes,
    )
    if fallback_names:
        notes.append("fallback_sources=" + ",".join(sorted(fallback_names)))
    else:
        notes.append("fallback_sources=none")

    search_root = logs_dir if logs_available else fallback_root

    failure_path: Optional[Path] = None
    if logs_available or fallback_names:
        failure_path = find_first_failure(search_root, notes)
    if not failure_path:
        placeholder = search_root / "fallback.log"
        ensure_dir(placeholder.parent)
        message_lines = [
            "Logs for the current run are not yet available from GitHub.",
            f"run_id={args.run_id} run_attempt={args.run_attempt}",
        ]
        if fallback_names:
            message_lines.append("Fallback artifacts:")
            message_lines.extend(f"- {name}" for name in sorted(fallback_names))
        else:
            message_lines.append("Fallback artifacts: none located")
        message_lines.append(
            "Inspect the staged attachments for additional context once artifacts finish uploading."
        )
        placeholder.write_text("\n".join(message_lines) + "\n", encoding="utf-8")
        notes.append("failpack_placeholder=created")
        failure_path = placeholder

    if not failure_path:
        write_notes(ctx_dir, notes)
        raise SystemExit("No logs found to build failpack.")

    failpack_path = ctx_dir / "failpack.log"
    failpack_path.write_text(read_text(failure_path), encoding="utf-8")
    relative_source = failure_path
    try:
        relative_source = failure_path.relative_to(search_root)
    except ValueError:
        pass
    notes.append(f"failpack_source={relative_source}")

    guide = ctx_dir / "guide.json"
    primary, line = derive_primary(read_text(failpack_path), repo_root, notes)
    guide.write_text(
        json.dumps(
            {
                "primary_file": str(primary).replace("\\", "/"),
                "line": line,
                "run_id": args.run_id,
                "log_hint": "failpack.log",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    attachments = stage_attachments(
        repo_root=repo_root,
        ctx_dir=ctx_dir,
        failpack=failpack_path,
        guide=guide,
        primary=primary,
        per_file_cap=args.per_file_cap,
        total_cap=args.total_cap,
        notes=notes,
    )
    if fallback_entries:
        attachments.extend(fallback_entries)
        notes.append(f"fallback_attachment_entries={len(fallback_entries)}")
    write_manifest(ctx_dir, attachments)
    write_notes(ctx_dir, notes)


def upload_file(path: Path, api_key: str, ctx_dir: Path) -> str:
    mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"

    def _post(purpose: str) -> requests.Response:
        with path.open("rb") as handle:
            return requests.post(
                "https://api.openai.com/v1/files",
                headers={"Authorization": f"Bearer {api_key}"},
                files={"file": (path.name, handle, mime_type)},
                data={"purpose": purpose},
                timeout=60,
            )

    # Professional note: Runs like 19197599278-1 confirmed the Files API now
    # expects the ``assistants`` purpose. Retain a guarded ``user_data``
    # fallback so sandboxes that lag behind do not regress with HTTP 400
    # responses mid-incident.
    purpose = "assistants"
    response = _post(purpose)
    if response.status_code == 400 and "purpose" in response.text.lower():
        debug(
            "OpenAI file upload rejected purpose 'assistants'; retrying with 'user_data'"
        )
        append_note(ctx_dir, "file_upload_purpose_retry=user_data")
        purpose = "user_data"
        response = _post(purpose)
    append_note(ctx_dir, f"file_upload_purpose={purpose}")
    if response.status_code != 200:
        raise RuntimeError(f"File upload failed ({path}): HTTP {response.status_code} {response.text}")
    payload = response.json()
    file_id = payload.get("id")
    if not file_id:
        raise RuntimeError(f"File upload missing id for {path}")
    return file_id


def extract_patch(response_json: dict) -> str:
    outputs = response_json.get("output") or []
    for item in outputs:
        content = item.get("content") or []
        for segment in content:
            text = segment.get("text")
            if not text:
                continue
            start = text.find("---BEGIN PATCH---")
            end = text.find("---END PATCH---")
            if start != -1 and end != -1 and end > start:
                return text[start : end + len("---END PATCH---")]
    # derived requirement: Assistants messages responses land under "choices";
    # parse both shapes so diagnostics stay compatible with either endpoint.
    choices = response_json.get("choices") or []
    for choice in choices:
        message = choice.get("message") or {}
        content = message.get("content")
        if isinstance(content, list):
            for segment in content:
                text = segment.get("text") or segment.get("value")
                if not isinstance(text, str):
                    continue
                start = text.find("---BEGIN PATCH---")
                end = text.find("---END PATCH---")
                if start != -1 and end != -1 and end > start:
                    return text[start : end + len("---END PATCH---")]
        elif isinstance(content, str):
            start = content.find("---BEGIN PATCH---")
            end = content.find("---END PATCH---")
            if start != -1 and end != -1 and end > start:
                return content[start : end + len("---END PATCH---")]
    return ""


def _emit_job_summary(
    ctx_dir: Path,
    *,
    model: Optional[str],
    status: str,
    reason: Optional[str],
    response_payload: Optional[dict],
    patch_text: Optional[str],
) -> None:
    """Append a compact iterate summary to the GitHub job log when available."""

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    if os.environ.get("HP_ITERATE_SUMMARY_WRITTEN") == "1":
        return

    tokens: List[str] = []
    usage = response_payload.get("usage") if isinstance(response_payload, dict) else None
    if isinstance(usage, dict):
        for label, key in (
            ("input", "input_tokens"),
            ("output", "output_tokens"),
            ("total", "total_tokens"),
            ("prompt", "prompt_tokens"),
            ("completion", "completion_tokens"),
        ):
            value = usage.get(key)
            if value is None:
                continue
            text = f"{label}={value}"
            if text not in tokens:
                tokens.append(text)

    patch_text = patch_text or ""
    diff_present = bool(patch_text.strip())
    patch_lines: List[str] = []
    if diff_present:
        patch_lines = patch_text.strip().splitlines()[:15]

    lines: List[str] = ["\n### Iterate summary\n"]
    lines.append(f"* Status: `{status}`\n")
    lines.append(f"* Reason: `{(reason or 'n/a')}`\n")
    if model:
        lines.append(f"* Model: `{model}`\n")
    if tokens:
        lines.append(f"* Tokens: {', '.join(tokens)}\n")
    else:
        lines.append("* Tokens: n/a\n")
    lines.append(f"* Diff produced: {'yes' if diff_present else 'no'}\n")

    if patch_lines:
        lines.append("\n<details>\n<summary>Patch preview (first 15 lines)</summary>\n\n```diff\n")
        for snippet in patch_lines:
            lines.append(f"{snippet}\n")
        lines.append("```\n</details>\n")

    try:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.writelines(lines)
        os.environ["HP_ITERATE_SUMMARY_WRITTEN"] = "1"
    except OSError as exc:
        append_note(ctx_dir, f"summary_write_error={exc}")


def _record_decision(
    ctx_dir: Path,
    *,
    status: str,
    reason: Optional[str],
    response_payload: Optional[dict],
    patch_text: Optional[str],
    model: Optional[str] = None,
) -> None:
    # derived requirement: run 19208683015-1 produced discovery-only iterate zips;
    # keep human-readable breadcrumbs in every outcome to avoid empty artifacts.
    """Persist iterate breadcrumbs even when the model cannot return a diff."""

    # derived requirement: runs like 19218551964-1 demanded JSON breadcrumbs so
    # downstream tooling can parse iterate outcomes deterministically.
    decision_payload = {"status": status, "reason": reason or "none"}
    decision_path = ctx_dir / "decision.json"
    decision_path.write_text(
        json.dumps(decision_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    decision_txt = ctx_dir / "decision.txt"
    decision_lines = [f"status={status}"]
    if reason:
        decision_lines.append(f"reason={reason}")
    decision_txt.write_text("\n".join(decision_lines) + "\n", encoding="utf-8")

    response_path = ctx_dir / "response.json"
    if response_payload is None:
        # derived requirement: keep response.json deterministic even when the
        # API call never happens so diagnostics stop surfacing stale payloads.
        response_path.write_text("{}\n", encoding="utf-8")
    else:
        response_path.write_text(
            json.dumps(response_payload, indent=2) + "\n", encoding="utf-8"
        )

    patch_path = ctx_dir / "fix.patch"
    material = patch_text if patch_text is not None else ""
    patch_path.write_text(material, encoding="utf-8")

    append_note(
        ctx_dir,
        f"decision_status={status} reason={reason or 'none'}",
    )
    # derived requirement: the workflow needs a human-readable fallback even when iterate
    # artifacts are delayed or missing; surface the same breadcrumbs in the job summary.
    _emit_job_summary(
        ctx_dir,
        model=model,
        status=status,
        reason=reason,
        response_payload=response_payload,
        patch_text=patch_text,
    )


def call_phase(args: argparse.Namespace) -> None:
    repo_root = Path.cwd()
    # derived requirement: field reports showed the call phase executing from a
    # fresh checkout without stage creating _ctx first. Guarantee the workspace
    # exists so later breadcrumbs survive even when stage bailed out early.
    ctx_dir = ensure_ctx(repo_root)

    # derived requirement: field reports such as run 19218918397-1 invoked the call phase
    # with a partially-initialized _ctx directory. Touch notes.txt up front so subsequent
    # breadcrumbs never fail to persist simply because the stage phase exited early.
    notes_path = ctx_dir / "notes.txt"
    if not notes_path.exists():
        notes_path.parent.mkdir(parents=True, exist_ok=True)
        notes_path.write_text("", encoding="utf-8")

    plan_path = ctx_dir / "upload_plan.json"
    if not plan_path.exists():
        append_note(ctx_dir, "openai_call=skipped_missing_plan")
        _record_decision(
            ctx_dir,
            status="error",
            reason="stage_incomplete",
            response_payload=None,
            patch_text="",
            model=args.model,
        )
        return

    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    files = plan.get("files", [])
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        append_note(ctx_dir, "openai_call=skipped_missing_key")
        _record_decision(
            ctx_dir,
            status="error",
            reason="missing_api_key",
            response_payload=None,
            patch_text="",
            model=args.model,
        )
        return

    file_ids: List[str] = []
    failed_rel_paths: List[str] = []

    def _queue_sanitized(original_path: Path) -> Tuple[Path, Optional[str]]:
        sanitized_path, sanitize_note = _sanitize_attachment(original_path, ctx_dir)
        return sanitized_path, sanitize_note

    def _is_invalid_extension_error(message: str) -> bool:
        lowered = message.lower()
        return "invalid extension" in lowered or "supported formats" in lowered

    for entry in files:
        rel = entry["name"]
        path = ctx_dir / "attached" / rel
        if not path.exists():
            append_note(ctx_dir, f"openai_upload_missing={rel}")
            continue

        candidate_queue: List[Tuple[Path, Optional[str]]] = []
        sanitized_generated = False
        if _is_extension_allowed(path):
            candidate_queue.append((path, None))
        else:
            sanitized_path, sanitize_note = _queue_sanitized(path)
            candidate_queue.append((sanitized_path, sanitize_note))
            sanitized_generated = True

        success = False
        idx = 0
        while idx < len(candidate_queue):
            candidate_path, sanitize_note = candidate_queue[idx]
            if sanitize_note:
                append_note(ctx_dir, sanitize_note)
            try:
                file_id = upload_file(candidate_path, api_key, ctx_dir)
                file_ids.append(file_id)
                source_name = candidate_path.name
                append_note(
                    ctx_dir,
                    f"uploaded={rel} file_id={file_id} source={source_name}",
                )
                success = True
                break
            except RuntimeError as exc:
                message = str(exc)
                append_note(ctx_dir, f"openai_upload_error={message}")
                if not sanitized_generated and _is_invalid_extension_error(message):
                    sanitized_path, sanitize_note = _queue_sanitized(path)
                    candidate_queue.append((sanitized_path, sanitize_note))
                    sanitized_generated = True
                idx += 1

        if not success:
            failed_rel_paths.append(rel)
            append_note(ctx_dir, f"openai_upload_failed={rel}")

    if not file_ids:
        append_note(ctx_dir, "openai_call=skipped_no_files")
        if failed_rel_paths:
            append_note(
                ctx_dir,
                "openai_upload_failed_all=" + ",".join(sorted(failed_rel_paths)),
            )
        _record_decision(
            ctx_dir,
            status="error",
            reason="no_files",  # derived requirement: keep diagnostics truthful when nothing was staged
            response_payload=None,
            patch_text="",
            model=args.model,
        )
        return

    prompt_text = textwrap.dedent(
        """
        Apply the smallest change that resolves the FIRST failing step described in failpack.log. Start at guide.json {primary_file}:{line}; if insufficient, search the attached repo files. Preserve current messaging/labels/structure. Return ONLY a unified diff fenced by ---BEGIN PATCH--- and ---END PATCH---.
        """
    ).strip()

    def _build_responses_payload() -> dict:
        """Build a Responses API payload that uses the attachments field."""

        # derived requirement: run 19252510407-1 showed the PDF-only guard when
        # we relied on ``messages``; the official attachments list keeps our
        # staged context intact without triggering that constraint.
        payload = {"model": args.model, "input": prompt_text}
        if file_ids:
            payload["attachments"] = [{"file_id": fid} for fid in file_ids]
        return payload

    def _post_payload(payload: dict) -> requests.Response:
        return requests.post(
            "https://api.openai.com/v1/responses",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            data=json.dumps(payload),
            timeout=120,
        )

    try:
        payload = _build_responses_payload()
        append_note(
            ctx_dir,
            f"openai_call_payload=responses.input attachments={len(file_ids)}",
        )
        response = _post_payload(payload)
    except requests.RequestException as exc:
        append_note(ctx_dir, f"openai_call_exception={exc}")
        _record_decision(
            ctx_dir,
            status="error",
            reason="request_exception",
            response_payload=None,
            patch_text="",
            model=args.model,
        )
        return

    if response.status_code != 200:
        append_note(
            ctx_dir,
            f"openai_call_error=HTTP {response.status_code} body={response.text[:400]}",
        )
        _record_decision(
            ctx_dir,
            status="error",
            reason=f"http_{response.status_code}",
            response_payload=None,
            patch_text="",
            model=args.model,
        )
        return

    try:
        response_json = response.json()
    except ValueError as exc:
        append_note(ctx_dir, f"openai_response_json_error={exc}")
        _record_decision(
            ctx_dir,
            status="error",
            reason="invalid_json",
            response_payload=None,
            patch_text="",
            model=args.model,
        )
        return
    patch = extract_patch(response_json)
    if patch.strip():
        append_note(ctx_dir, "openai_patch=received")
        _record_decision(
            ctx_dir,
            status="success",
            reason="diff_generated",
            response_payload=response_json,
            patch_text=patch,
            model=args.model,
        )
    else:
        # derived requirement: run 19211170783-1 surfaced a zero-byte iterate bundle;
        # treat missing fenced diffs as an error so diagnostics capture breadcrumbs.
        append_note(ctx_dir, "openai_patch=no_fenced_diff")
        _record_decision(
            ctx_dir,
            status="error",
            reason="no_fenced_diff",
            response_payload=response_json,
            patch_text="",
            model=args.model,
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inline model quick-fix helper")
    sub = parser.add_subparsers(dest="command", required=True)

    stage = sub.add_parser("stage", help="Build _ctx attachments")
    stage.add_argument("--repo", required=True)
    stage.add_argument("--run-id", required=True)
    stage.add_argument("--run-attempt", required=True)
    stage.add_argument("--token", required=True)
    stage.add_argument("--per-file-cap", type=int, default=200 * 1024)
    stage.add_argument(
        "--total-cap",
        type=int,
        default=int(os.environ.get("ATTACH_MAX_TOTAL", 6 * 1024 * 1024)),
    )

    call = sub.add_parser("call", help="Upload attachments and invoke model")
    call.add_argument("--model", default="gpt-5-codex")

    return parser


def main(argv: Optional[List[str]] = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "stage":
        stage_phase(args)
    elif args.command == "call":
        call_phase(args)
    else:  # pragma: no cover - defensive
        parser.error(f"Unknown command: {args.command}")


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    main(sys.argv[1:])
