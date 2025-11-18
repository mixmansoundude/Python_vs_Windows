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
import hashlib
import importlib.util
import json
import mimetypes
import os
import re
import shutil
import sys
import textwrap
import time
from http.client import RemoteDisconnected
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Dict, Iterable, List, Optional, Set, Tuple
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

CONTEXT_TOTAL_CAP_BYTES = 512 * 1024

# derived requirement: iterate run 19283281951-1 showed the model needs full
# visibility into the harness stack. Keep these files untrimmed and in this
# deterministic order so the contract stays stable when future failures arise.
CONTEXT_PRIMARY_KEEP = [
    Path("README.md"),
    Path("AGENTS.md"),
    Path("run_setup.bat"),
    Path("run_tests.bat"),
    Path("tests/harness.ps1"),
    Path("tests/selfapps_entry.ps1"),
    Path("tests/selfapps_single.ps1"),
    Path("tests/selfapps_envsmoke.ps1"),
]

# derived requirement: narrow the iterate bundle to failure-relevant sources.
CONTEXT_EXCLUDED_PATHS = {
    Path(".github/workflows"),
    Path(".github/workflows/batch-check.yml"),
    Path("tools/diag"),
    Path("tools/diag/publish_index.ps1"),
    Path("tools/diag/publish_index.py"),
    Path("tools/diag/build_prompt.ps1"),
    Path("tools/apply_patch.py"),
    Path("tools/check_delimiters.py"),
    Path("scripts/poll_public_diag.ps1"),
}

REFERENCE_EXTENSIONS = {".bat", ".cmd", ".ps1", ".psm1", ".psd1", ".py", ".json", ".txt"}


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



def _load_fail_list_from_candidates(candidates: Iterable[Path]) -> Tuple[Optional[Path], List[str]]:
    seen: Set[Path] = set()
    for base in candidates:
        try:
            resolved = base.resolve()
        except OSError:
            continue
        if resolved in seen or not resolved.exists():
            continue
        seen.add(resolved)

        direct = resolved / "batchcheck_failing.txt"
        target: Optional[Path] = None
        if direct.exists():
            target = direct
        else:
            try:
                target = next(resolved.rglob("batchcheck_failing.txt"))
            except StopIteration:
                target = None
        if not target:
            continue

        try:
            lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return target, []
        entries = [
            line.strip()
            for line in lines
            if line.strip() and line.strip().lower() != "none"
        ]
        return target, entries
    return None, []


def discover_fail_list(repo_root: Path) -> Tuple[Optional[Path], List[str]]:
    candidates: List[Path] = []
    diag_env = os.environ.get("DIAG")
    if diag_env:
        candidates.append(Path(diag_env))
    for rel in ("diag", "_mirrors", "_ctx", "_ctx/attached", "_ctx/attached/_mirrors"):
        candidates.append(repo_root / rel)
    for rel in ("_artifacts", "_artifacts/batch-check"):
        # derived requirement: runs like 19451761905-1 mirrored an empty fail list
        # into the batch-check artifact root; include it so the call phase can honor
        # the authoritative "none" sentinel before any model traffic occurs.
        candidates.append(repo_root / rel)
    candidates.append(repo_root)
    workspace_env = os.environ.get("GITHUB_WORKSPACE")
    if workspace_env:
        workspace_path = Path(workspace_env)
        candidates.append(workspace_path)
        candidates.append(workspace_path / "diag")
    runner_temp = os.environ.get("RUNNER_TEMP")
    if runner_temp:
        candidates.append(Path(runner_temp))
    return _load_fail_list_from_candidates(candidates)


_APPLY_PATCH_MODULE: Optional[ModuleType] = None


def _load_apply_patch_module() -> ModuleType:
    """Dynamically load tools/apply_patch.py for dry-run validation."""

    global _APPLY_PATCH_MODULE
    if _APPLY_PATCH_MODULE is None:
        module_path = Path(__file__).with_name("apply_patch.py")
        spec = importlib.util.spec_from_file_location("inline_apply_patch", module_path)
        if spec is None or spec.loader is None:  # pragma: no cover - defensive guard
            raise RuntimeError("Unable to load apply_patch module for inline validation")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)  # type: ignore[union-attr]
        _APPLY_PATCH_MODULE = module
    return _APPLY_PATCH_MODULE


def dry_run_patch_apply(patch_text: str, repo_root: Path) -> Tuple[bool, Optional[str]]:
    """Validate *patch_text* using the shared patch engine without mutating the repo."""

    module = _load_apply_patch_module()
    overlay: Dict[str, Optional[str]] = {}

    def _open(path: str) -> str:
        target = repo_root / path
        return target.read_text(encoding="utf-8")

    def _write(path: str, content: str) -> None:
        overlay[path] = content

    def _remove(path: str) -> None:
        overlay[path] = None

    try:
        module.process_patch(patch_text, _open, _write, _remove)
    except module.DiffError as exc:
        return False, f"diff_error:{exc}"
    except FileNotFoundError as exc:
        # derived requirement: staged artifacts can lag repo updates; surface missing context
        # as a deterministic diff_error so the escalator retries instead of mutating the tree.
        return False, f"diff_missing:{exc}"
    except Exception as exc:  # pragma: no cover - mirrors apply_patch CLI behavior
        return False, f"unexpected:{exc}"
    return True, None


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


BAT_REFERENCE_RE = re.compile(
    r'"([^"\s]+\.[A-Za-z0-9]+)"|\'([^\'\s]+\.[A-Za-z0-9]+)\'|([A-Za-z0-9_./\\-]+\.[A-Za-z0-9]+)'
)


def _normalize_rel(rel: Path) -> Path:
    text = rel.as_posix().lstrip("./")
    return Path(text)


def _should_exclude_from_context(rel: Path) -> bool:
    rel_posix = rel.as_posix()
    for excluded in CONTEXT_EXCLUDED_PATHS:
        prefix = excluded.as_posix()
        if rel_posix == prefix or rel_posix.startswith(prefix + "/"):
            return True
    return False


def _gather_context_file_list(repo_root: Path, ctx_dir: Path) -> List[Path]:
    ordered: List[Path] = []
    seen: Set[str] = set()

    def add_candidate(rel: Path) -> None:
        normalized = _normalize_rel(rel)
        key = normalized.as_posix()
        if key in seen:
            return
        # derived requirement: run 19285065673-1 surfaced duplicate _ctx/attached
        # copies in the iterate bundle. Ignore workspace mirrors so the model
        # only sees canonical repo paths.
        if normalized.parts and normalized.parts[0] == "_ctx":
            append_note(ctx_dir, f"context_skip={key} reason=ctx_workspace")
            return
        if _should_exclude_from_context(normalized):
            append_note(ctx_dir, f"context_excluded={key}")
            return
        candidate = repo_root / normalized
        if not candidate.exists():
            append_note(ctx_dir, f"context_missing={key}")
            return
        seen.add(key)
        ordered.append(normalized)

    for rel in CONTEXT_PRIMARY_KEEP:
        add_candidate(rel)

    for bat_path in sorted(repo_root.rglob("*.bat")):
        if "_ctx" in bat_path.parts:
            continue
        try:
            rel = bat_path.relative_to(repo_root)
        except ValueError:
            continue
        # derived requirement: keep batch harness focus narrow — only root-level
        # launchers and tests/**/*.bat matter for iterate triage.
        if len(rel.parts) > 1 and rel.parts[0] not in {"tests"}:
            continue
        add_candidate(rel)

    referenced: Set[Path] = set()
    processed_bats: Set[str] = set()

    def process_bat(rel: Path) -> None:
        key = rel.as_posix()
        if key in processed_bats:
            return
        processed_bats.add(key)
        abs_path = repo_root / rel
        try:
            text = abs_path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            append_note(ctx_dir, f"bat_reference_read_error={key} error={exc}")
            return
        for match in BAT_REFERENCE_RE.findall(text):
            candidate = next((item for item in match if item), None)
            if not candidate:
                continue
            candidate = candidate.replace("%~dp0", "")
            candidate = candidate.strip()
            if not candidate:
                continue
            # derived requirement: environment placeholders such as %MC% or
            # $(PATH) surfaced during run 19285065673-1; skip them so we don't
            # spam context_missing with non-repo tokens.
            if any(symbol in candidate for symbol in ("%", "!", "$(")):
                append_note(
                    ctx_dir,
                    f"bat_reference_skip={candidate} reason=env_placeholder",
                )
                continue
            rel_candidate = path_in_repo(candidate, repo_root)
            if rel_candidate is None:
                continue
            abs_candidate = (repo_root / rel_candidate).resolve()
            try:
                relative = abs_candidate.relative_to(repo_root.resolve())
            except ValueError:
                continue
            normalized = _normalize_rel(relative)
            ext = normalized.suffix.lower()
            if ext and ext not in REFERENCE_EXTENSIONS:
                continue
            if _should_exclude_from_context(normalized):
                append_note(ctx_dir, f"context_excluded={normalized.as_posix()}")
                continue
            if normalized.suffix.lower() in {".bat", ".cmd"}:
                add_candidate(normalized)
                process_bat(normalized)
            else:
                referenced.add(normalized)

    idx = 0
    while idx < len(ordered):
        rel = ordered[idx]
        if rel.suffix.lower() in {".bat", ".cmd"}:
            process_bat(rel)
        idx += 1

    for rel in sorted(referenced, key=lambda item: item.as_posix()):
        add_candidate(rel)

    return ordered


def _read_tail_lines(path: Path, count: int) -> List[str]:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    if not lines:
        return []
    return lines[-count:]


def _collect_envsmoke_summaries(ctx_dir: Path) -> List[Tuple[str, str]]:
    """Return trimmed envsmoke log tails when available."""

    summaries: List[Tuple[str, str]] = []
    targets = [
        ("~envsmoke_bootstrap.log", 120),
        ("~setup.log", 80),
    ]
    for suffix, limit in targets:
        for path in sorted(ctx_dir.glob(f"attached/**/*{suffix}")):
            if not path.is_file():
                continue
            tail = _read_tail_lines(path, limit)
            if not tail:
                continue
            label = path.relative_to(ctx_dir).as_posix() + " tail"
            body = "\n".join(tail)
            summaries.append((label, body))
    return summaries


def _collect_ndjson_summaries(ctx_dir: Path) -> List[Tuple[str, str]]:
    summaries: List[Tuple[str, str]] = []
    failing_ids = {"self.env.smoke.conda", "self.env.smoke.run"}
    for path in sorted(ctx_dir.glob("attached/**/*test-results*.ndjson*")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            append_note(ctx_dir, f"ndjson_summary_error={path.relative_to(ctx_dir)} error={exc}")
            continue
        lines = text.splitlines()
        head = lines[:20]
        tail = lines[-20:] if len(lines) > 20 else []
        failing_rows = [
            line
            for line in lines
            if any(identifier in line for identifier in failing_ids)
        ]
        body_parts: List[str] = []
        if head:
            body_parts.append("-- head --")
            body_parts.extend(head)
        if tail:
            body_parts.append("-- tail --")
            body_parts.extend(tail)
        body_parts.append("-- failing rows --")
        body_parts.extend(failing_rows or ["[rows not present]"])
        body = "\n".join(body_parts)
        label = path.relative_to(ctx_dir).as_posix()
        summaries.append((label, body))
    return summaries


def _first_failing_check(search_root: Path, notes: List[str]) -> Optional[dict]:
    """Locate the first failing NDJSON entry and surface enough detail for triage.

    Professional note: runs like 19411179602-1 produced NDJSON summaries that
    captured the real envsmoke failures while the generic failpack log only
    mentioned the missing Python heuristic. Keep this parser minimal to avoid
    disturbing the existing attachment contract while still extracting a single
    failing check for the guide and log hint.
    """

    def _is_ndjson_candidate(path: Path) -> bool:
        name = path.name.lower()
        return "ndjson" in name or path.suffix.lower() == ".ndjson"

    for path in sorted(search_root.rglob("*")):
        if not path.is_file() or not _is_ndjson_candidate(path):
            continue
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as exc:
            notes.append(f"ndjson_scan_error={path.relative_to(search_root)} error={exc}")
            continue
        for line in lines:
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(payload, dict):
                continue
            if payload.get("pass") is not False:
                continue
            failing_id = payload.get("id")
            if failing_id:
                notes.append(
                    "first_failing_check="
                    + str(failing_id)
                    + f" source={path.relative_to(search_root)}"
                )
            return {
                "id": payload.get("id"),
                "desc": payload.get("desc"),
                "command": payload.get("command") or payload.get("cmd"),
                "exit_code": payload.get("exitCode") or payload.get("exit_code"),
                "source": path,
            }
    notes.append("first_failing_check=not_found")
    return None


def _map_failing_check_to_hints(failing_id: Optional[str]) -> tuple[Optional[Path], Optional[str]]:
    if failing_id in {"self.env.smoke.conda", "self.env.smoke.run"}:
        return Path("tests/selfapps_envsmoke.ps1"), "tests/~envsmoke/~envsmoke_bootstrap.log"
    return None, None


def _build_inlined_context(repo_root: Path, ctx_dir: Path) -> Tuple[str, int, int]:
    """Assemble a bounded text bundle for the Responses input field."""

    sections: List[str] = []
    total_bytes = 0
    inlined_files = 0

    keep_paths = _gather_context_file_list(repo_root, ctx_dir)
    keep_set = {item.as_posix() for item in keep_paths}

    def add_section(label: str, body: str, *, log_prefix: str, file_bytes: Optional[int] = None) -> None:
        nonlocal total_bytes
        section = f"=== CONTEXT FILE: {label} ===\n{body}"
        encoded = section.encode("utf-8")
        if total_bytes + len(encoded) > CONTEXT_TOTAL_CAP_BYTES:
            append_note(ctx_dir, f"context_skip={label} reason=total_cap")
            return
        sections.append(section)
        total_bytes += len(encoded)
        payload_bytes = len(body.encode("utf-8"))
        if file_bytes is not None and file_bytes > 0:
            kept_percent = min(100, int(round(payload_bytes * 100 / file_bytes)))
        else:
            kept_percent = 100 if file_bytes == payload_bytes else 0
        append_note(
            ctx_dir,
            f"{log_prefix}={label} inlined_bytes={payload_bytes} file_bytes={file_bytes or payload_bytes} kept_percent={kept_percent}",
        )

    for rel in keep_paths:
        abs_path = repo_root / rel
        try:
            data = abs_path.read_bytes()
        except OSError as exc:
            append_note(ctx_dir, f"context_read_error={rel.as_posix()} error={exc}")
            continue

        if not _is_probably_text(data):
            digest = hashlib.sha256(data).hexdigest()
            body = f"<binary {len(data)} bytes sha256={digest[:16]}>"
            append_note(ctx_dir, f"context_binary_summary={rel.as_posix()} size={len(data)} sha256={digest[:16]}")
            add_section(rel.as_posix(), body, log_prefix="context_file", file_bytes=len(data))
            inlined_files += 1
            continue

        text = data.decode("utf-8", errors="replace")
        keep_full = rel.as_posix() in keep_set and (
            rel in CONTEXT_PRIMARY_KEEP or rel.suffix.lower() in {".bat", ".cmd"}
        )
        if keep_full:
            snippet = text
            truncated = False
        else:
            snippet = trim_content(text, 64 * 1024)
            truncated = len(snippet.encode("utf-8")) < len(data)
            if truncated:
                append_note(
                    ctx_dir,
                    f"context_truncated={rel.as_posix()} original_bytes={len(data)} kept_bytes={len(snippet.encode('utf-8'))}",
                )
        add_section(rel.as_posix(), snippet, log_prefix="context_file", file_bytes=len(data))
        inlined_files += 1

    notes_tail = _read_tail_lines(ctx_dir / "notes.txt", 60)
    if notes_tail:
        add_section(
            "_ctx/notes.txt tail",
            "\n".join(notes_tail),
            log_prefix="context_summary",
            file_bytes=len("\n".join(notes_tail).encode("utf-8")),
        )

    failpack_tail = _read_tail_lines(ctx_dir / "attached" / "failpack.log", 120)
    if failpack_tail:
        add_section(
            "failpack.log tail",
            "\n".join(failpack_tail),
            log_prefix="context_summary",
            file_bytes=len("\n".join(failpack_tail).encode("utf-8")),
        )

    decision_path = ctx_dir / "decision.json"
    if decision_path.exists():
        try:
            decision_data = json.loads(decision_path.read_text(encoding="utf-8"))
            decision_line = json.dumps(decision_data, sort_keys=True)
        except (OSError, json.JSONDecodeError):
            decision_line = decision_path.read_text(encoding="utf-8", errors="replace").splitlines()[0:1]
            decision_line = "".join(decision_line)
        add_section(
            "decision.json one-line",
            decision_line,
            log_prefix="context_summary",
            file_bytes=len(decision_line.encode("utf-8")),
        )

    lane_verdict = ctx_dir / "attached" / "lane_verdict.json"
    if lane_verdict.exists():
        try:
            verdict_data = json.loads(lane_verdict.read_text(encoding="utf-8"))
            verdict_line = json.dumps(verdict_data, sort_keys=True)
        except (OSError, json.JSONDecodeError):
            verdict_line = lane_verdict.read_text(encoding="utf-8", errors="replace").strip()
        add_section(
            "lane_verdict.json one-line",
            verdict_line,
            log_prefix="context_summary",
            file_bytes=len(verdict_line.encode("utf-8")),
        )

    for label, body in _collect_ndjson_summaries(ctx_dir):
        add_section(label, body, log_prefix="context_summary", file_bytes=len(body.encode("utf-8")))
    for label, body in _collect_envsmoke_summaries(ctx_dir):
        # derived requirement: envsmoke triage depends on bootstrap tails for exit code 255 failures
        add_section(label, body, log_prefix="context_summary", file_bytes=len(body.encode("utf-8")))

    context_text = "\n\n".join(sections)
    return context_text, inlined_files, total_bytes


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


def _load_patch_state(ctx_dir: Path) -> Tuple[int, int]:
    """Return (current_patch_count, patch_limit) for this workflow run."""

    limit_raw = os.environ.get("PATCHES_PER_RUN_LIMIT", "1")
    try:
        patch_limit = int(limit_raw)
    except ValueError:
        patch_limit = 1
    patch_limit = max(patch_limit, 1)

    count = 0
    decision_path = ctx_dir / "decision.json"
    if decision_path.exists():
        try:
            prior = json.loads(decision_path.read_text(encoding="utf-8"))
            count = int(prior.get("patches_applied_count", 0))
        except Exception as exc:  # pragma: no cover - defensive against corrupt artifacts
            append_note(ctx_dir, f"patch_count_read_error={exc}")
            count = 0
    return max(count, 0), patch_limit


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

    failing_check = _first_failing_check(search_root, notes)

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
    failpack_body = read_text(failure_path)
    if failing_check:
        summary_lines = ["First failing check (from ci_test_results NDJSON):"]
        if failing_check.get("id"):
            summary_lines.append(f"id: {failing_check['id']}")
        if failing_check.get("desc"):
            summary_lines.append(f"desc: {failing_check['desc']}")
        if failing_check.get("command"):
            summary_lines.append(f"command: {failing_check['command']}")
        if failing_check.get("exit_code") is not None:
            summary_lines.append(f"exitCode: {failing_check['exit_code']}")
        summary_lines.append("")
        summary_lines.append("-- failpack.log follows --")
        failpack_body = "\n".join(summary_lines) + "\n\n" + failpack_body
    failpack_path.write_text(failpack_body, encoding="utf-8")
    relative_source = failure_path
    try:
        relative_source = failure_path.relative_to(search_root)
    except ValueError:
        pass
    notes.append(f"failpack_source={relative_source}")

    guide = ctx_dir / "guide.json"
    primary_override, log_hint_override = _map_failing_check_to_hints(
        failing_check.get("id") if failing_check else None
    )
    if primary_override:
        # Professional note: envsmoke failures need to point at the harness that actually
        # runs the check, otherwise the model can loop on why_no_diff replies. Keep the
        # existing guide schema intact while steering the primary file to the failing lane.
        primary, line = primary_override, None
    else:
        primary, line = derive_primary(failpack_body, repo_root, notes)
    guide.write_text(
        json.dumps(
            {
                "primary_file": str(primary).replace("\\", "/"),
                "line": line,
                "run_id": args.run_id,
                "log_hint": log_hint_override or "failpack.log",
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


def extract_patch(response_json: dict) -> Tuple[str, Optional[str], Optional[dict], Optional[str]]:
    segments: List[str] = []

    outputs = response_json.get("output") or []
    for item in outputs:
        content = item.get("content") or []
        for segment in content:
            text = segment.get("text")
            if isinstance(text, str):
                segments.append(text)

    choices = response_json.get("choices") or []
    for choice in choices:
        message = choice.get("message") or {}
        content = message.get("content")
        if isinstance(content, list):
            for segment in content:
                text = segment.get("text") or segment.get("value")
                if isinstance(text, str):
                    segments.append(text)
        elif isinstance(content, str):
            segments.append(content)

    combined = "\n\n".join(segments)
    code_block_re = re.compile(r"```(\w+)?\s*\n([\s\S]*?)\n```", re.IGNORECASE)
    rationale_raw: Optional[str] = None
    rationale_json: Optional[dict] = None
    rationale_error: Optional[str] = None
    diff_body: Optional[str] = None
    invalid_sequence = False

    for match in code_block_re.finditer(combined):
        lang = (match.group(1) or "").strip().lower()
        body = match.group(2).rstrip()
        if lang == "json" and rationale_raw is None and diff_body is None:
            rationale_raw = body
            try:
                rationale_json = json.loads(body)
            except json.JSONDecodeError:
                rationale_error = "invalid_rationale_json"
            continue
        if lang == "diff" and diff_body is None:
            diff_body = body
            continue
        invalid_sequence = True
        break

    if invalid_sequence:
        return "", rationale_raw, rationale_json, "invalid_sequence"

    if diff_body is not None:
        return diff_body, rationale_raw, rationale_json, rationale_error

    if rationale_raw is not None:
        return "", rationale_raw, rationale_json, rationale_error or "json_only"

    # derived requirement: retain compatibility with historical ---BEGIN PATCH---
    # payloads so older retries do not regress if the upstream contract shifts
    # again. This path should become dormant once all prompts enforce the fenced
    # diff contract.
    legacy_start = "---BEGIN PATCH---"
    legacy_end = "---END PATCH---"
    for text in segments:
        start = text.find(legacy_start)
        end = text.find(legacy_end)
        if start != -1 and end != -1 and end > start:
            return text[start : end + len(legacy_end)], None, None, None

    return "", rationale_raw, rationale_json, rationale_error


def _emit_job_summary(
    ctx_dir: Path,
    *,
    model: Optional[str],
    status: str,
    reason: Optional[str],
    response_payload: Optional[dict],
    patch_text: Optional[str],
    rationale: Optional[str] = None,
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

    if rationale:
        lines.append("\n<details>\n<summary>Model rationale</summary>\n\n")
        lines.append("```json\n")
        lines.extend(f"{line}\n" for line in rationale.splitlines())
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
    rationale: Optional[str] = None,
    patch_count: int = 0,
) -> None:
    # derived requirement: run 19208683015-1 produced discovery-only iterate zips;
    # keep human-readable breadcrumbs in every outcome to avoid empty artifacts.
    """Persist iterate breadcrumbs even when the model cannot return a diff."""

    # derived requirement: runs like 19218551964-1 demanded JSON breadcrumbs so
    # downstream tooling can parse iterate outcomes deterministically.
    decision_payload = {
        "patches_applied_count": max(patch_count, 0),
        "reason": reason or "none",
        "status": status,
    }
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
    if material and not material.endswith("\n"):
        # derived requirement: the CI workflow applies _ctx/fix.patch using
        # tools/apply_patch.py, which expects raw unified diff content with
        # a trailing newline and no markdown fences.
        material += "\n"
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
        rationale=rationale,
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

    current_patch_count, patch_limit = _load_patch_state(ctx_dir)
    append_note(
        ctx_dir,
        (
            "patch_limit_state="
            f"applied={current_patch_count};limit={patch_limit}"
        ),
    )
    existing_response: Optional[dict] = None
    existing_patch_text: Optional[str] = None
    response_path = ctx_dir / "response.json"
    if response_path.exists():
        try:
            existing_response = json.loads(response_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            existing_response = None
    patch_path = ctx_dir / "fix.patch"
    if patch_path.exists():
        try:
            existing_patch_text = patch_path.read_text(encoding="utf-8")
        except OSError:
            existing_patch_text = None

    fail_list_path, fail_entries = discover_fail_list(repo_root)
    if fail_list_path:
        append_note(ctx_dir, f"fail_list_path={fail_list_path}")
        append_note(ctx_dir, f"fail_list_entries={len(fail_entries)}")
    if fail_list_path and not fail_entries:
        append_note(ctx_dir, "iterate_skip=no_failing_tests")
        _record_decision(
            ctx_dir,
            status="skipped",
            reason="no_failing_tests",
            response_payload=None,
            patch_text="",
            model=args.model,
            patch_count=current_patch_count,
        )
        return

    if current_patch_count >= patch_limit:
        # derived requirement: CI currently permits exactly one applied patch per run;
        # short-circuit additional model calls so follow-up failures remain manual until
        # the limit increases.
        append_note(ctx_dir, "iterate_skip=patch_limit_reached")
        _record_decision(
            ctx_dir,
            status="skipped",
            reason="patch_limit_reached",
            response_payload=existing_response,
            patch_text=existing_patch_text or "",
            model=args.model,
            patch_count=current_patch_count,
        )
        return

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
            patch_count=current_patch_count,
        )
        return

    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    files = plan.get("files", [])
    append_note(ctx_dir, f"attachments_staged={len(files)}")
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
            patch_count=current_patch_count,
        )
        return

    file_ids: List[str] = []
    upload_enabled = False  # derived requirement: Responses input now inlines context; skip unused uploads to avoid API fatigue.

    if upload_enabled:
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
                patch_count=current_patch_count,
            )
            return
    else:
        append_note(ctx_dir, "openai_upload_skipped=responses_input_inlined_context")

    prompt_text = textwrap.dedent(
        """
        Apply the smallest change that resolves the FIRST failing step described in failpack.log. Change as few lines as possible and keep the diff tightly focused on the failing tests described above. Start at guide.json {primary_file}:{line}; if insufficient, search the attached repo files. Preserve current messaging/labels/structure and do not rewrite unrelated sections or stylistic details. If you cannot safely produce a patch, emit exactly one fenced json block with keys why_no_diff, insights, files_missing, hotspots. If you can produce a patch, you may optionally emit that json block first, then emit exactly one fenced diff block containing the complete patch. Do not write any other prose. If no changes are required, return an empty fenced diff block.
        """
    ).strip()

    def _post_payload(payload: dict, timeout: int) -> requests.Response:
        return requests.post(
            "https://api.openai.com/v1/responses",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            data=json.dumps(payload),
            timeout=timeout,
        )

    context_text, inlined_count, context_bytes = _build_inlined_context(repo_root, ctx_dir)
    if context_text:
        full_prompt = (
            "### TASK\n"
            f"{prompt_text}\n\n"
            "### CONTEXT\n"
            f"{context_text}"
        )
    else:
        append_note(ctx_dir, "inlined_skip=none reason=no_candidates")
        full_prompt = prompt_text

    payload = {"model": args.model, "input": full_prompt}
    # NOTE: Do not send ``temperature`` to the Responses API for GPT-5-Codex;
    # runs like 19285065673-1 prove the endpoint rejects it with HTTP 400
    # "Unsupported parameter: 'temperature'". Log the omission so future
    # maintainers understand why the knob is absent here.
    append_note(
        ctx_dir,
        f"omitted_params=temperature;model={args.model}",
    )
    # NOTE: Do not send ``text.verbosity`` either; run 19285065673-1 showed the
    # API rejects "low" with HTTP 400 "unsupported_value" and only advertises
    # "medium". We omit the parameter entirely to avoid future breakage.
    append_note(
        ctx_dir,
        f"omitted_params=text.verbosity;model={args.model}",
    )
    token_plan = [
        {"cap": 4000, "effort": "low"},
        {"cap": 16000, "effort": "low"},
        {"cap": 48000, "effort": "medium"},
        {"cap": None, "effort": None},  # final attempt: unbounded tokens with default reasoning
    ]
    initial_cap = token_plan[0]["cap"]
    initial_effort = token_plan[0]["effort"]

    timeout_sec = int(os.environ.get("INLINE_MODEL_TIMEOUT", "300"))
    retry_delays = [0, 5]
    attachments_uploaded = len(file_ids)

    append_note(
        ctx_dir,
        (
            "openai_call_payload=responses.input_no_attachments "
            f"files_inlined={inlined_count} bytes={context_bytes} "
            f"attachments_uploaded={attachments_uploaded} "
            f"timeout={timeout_sec} retries={len(token_plan) - 1} "
            f"initial_max_output_tokens={initial_cap} "
            f"initial_reasoning_effort={initial_effort} "
            f"final_max_output_tokens={token_plan[-1]['cap'] or 'unbounded'}"
        ),
    )

    def _execute_payload(current_payload: dict) -> Tuple[Optional[dict], Optional[str]]:
        removed_params: Set[str] = set()
        while True:
            response: Optional[requests.Response] = None
            last_error_label: Optional[str] = None
            last_reason: Optional[str] = "request_exception"
            for attempt, delay in enumerate(retry_delays):
                if delay:
                    time.sleep(delay)
                try:
                    resp = _post_payload(current_payload, timeout_sec)
                except (
                    requests.exceptions.ReadTimeout,
                    requests.exceptions.ConnectTimeout,
                    requests.exceptions.Timeout,
                ) as exc:
                    last_error_label = f"timeout:{type(exc).__name__}"
                    last_reason = "request_exception"
                    append_note(
                        ctx_dir,
                        f"openai_call_timeout_attempt={attempt} error={exc}",
                    )
                    continue
                except requests.RequestException as exc:
                    # Professional note: transient disconnects (RemoteDisconnected) are common when
                    # the Responses API trims connections under load. Treat them as a soft error so
                    # diagnostics encourage a retry instead of marking the run as a hard failure.
                    if isinstance(exc, requests.exceptions.ConnectionError) and isinstance(
                        getattr(exc, "__cause__", None), RemoteDisconnected
                    ):
                        append_note(ctx_dir, "openai_call_exception=remote_disconnected")
                        return None, "remote_disconnected"
                    append_note(ctx_dir, f"openai_call_exception={exc}")
                    return None, "request_exception"
                if resp.status_code >= 500:
                    last_error_label = f"http_{resp.status_code}"
                    last_reason = f"http_{resp.status_code}"
                    append_note(
                        ctx_dir,
                        f"openai_call_retry_http={resp.status_code} attempt={attempt}",
                    )
                    continue
                response = resp
                break
            if response is None:
                append_note(
                    ctx_dir,
                    f"openai_call_exception={last_error_label or 'unknown_failure'}",
                )
                return None, last_reason or "request_exception"

            if response.status_code == 400:
                body_snippet = response.text[:400]
                append_note(
                    ctx_dir,
                    f"openai_call_error=HTTP 400 body={body_snippet}",
                )
                lowered = body_snippet.lower()
                dropped = False
                for param in ("text", "reasoning"):
                    if (
                        param not in removed_params
                        and param in current_payload
                        and "unknown parameter" in lowered
                        and f"'{param}'" in lowered
                    ):
                        append_note(ctx_dir, f"openai_call_drop_param={param}")
                        current_payload.pop(param, None)
                        removed_params.add(param)
                        dropped = True
                        break
                if dropped:
                    continue
                return None, "http_400"

            if response.status_code != 200:
                append_note(
                    ctx_dir,
                    f"openai_call_error=HTTP {response.status_code} body={response.text[:400]}",
                )
                return None, f"http_{response.status_code}"
            try:
                return response.json(), None
            except ValueError as exc:
                append_note(ctx_dir, f"openai_response_json_error={exc}")
                return None, "invalid_json"

    def log_attempt(idx: int, level: str, reason: str, status: str) -> None:
        append_note(
            ctx_dir,
            f"attempt={idx} escalator_level={level} escalate_reason={reason} attempt_status={status}",
        )

    response_json: Optional[dict] = None
    error_reason: Optional[str] = None
    escalator_exhausted = False
    accepted_patch_details: Optional[Tuple[str, Optional[str], Optional[dict], Optional[str]]] = None
    final_status_note: Optional[str] = None
    final_reason_note: Optional[str] = None

    def record_final_status() -> None:
        if final_status_note and final_reason_note:
            append_note(
                ctx_dir,
                f"final_status={final_status_note} final_reason={final_reason_note}",
            )

    for idx, plan in enumerate(token_plan):
        attempt_no = idx + 1
        cap = plan["cap"]
        effort = plan["effort"]
        cap_desc = str(cap) if cap is not None else "unbounded"
        effort_desc = effort if effort is not None else "default"
        escalate_reason = "none"
        attempt_status = "pending"
        if cap is None:
            payload.pop("max_output_tokens", None)
        else:
            payload["max_output_tokens"] = cap
        if effort is None:
            if "reasoning" in payload:
                payload.pop("reasoning", None)
                append_note(ctx_dir, "openai_call_reasoning_reset=default")
        else:
            payload["reasoning"] = {"effort": effort}
        append_note(
            ctx_dir,
            f"openai_call_attempt={idx} max_output_tokens={cap_desc} reasoning_effort={effort_desc}",
        )
        if idx > 0:
            append_note(
                ctx_dir,
                (
                    "openai_call_retry_max_output_tokens="
                    f"{cap_desc} retry_ix={idx} reasoning_effort={effort_desc}"
                ),
            )
        response_json, error_reason = _execute_payload(payload)
        if response_json is None:
            escalate_reason = error_reason or "request_exception"
            attempt_status = "aborted"
            log_attempt(attempt_no, cap_desc, escalate_reason, attempt_status)
            final_status_note = "no_commit"
            final_reason_note = escalate_reason
            break

        candidate = extract_patch(response_json)
        candidate_patch_raw = candidate[0]
        candidate_patch = candidate_patch_raw.strip()

        incomplete_details = response_json.get("incomplete_details") or {}
        status_tag = response_json.get("status")
        reason_tag = incomplete_details.get("reason")
        if reason_tag:
            append_note(
                ctx_dir,
                f"openai_call_incomplete_reason={reason_tag} "
                f"retry_ix={idx} max_output_tokens={cap_desc}",
            )
        if status_tag == "incomplete" and reason_tag == "max_output_tokens":
            if candidate_patch:
                # derived requirement: iterate run 19331718491 proved that useful diffs can
                # surface even when the Responses API reports an incomplete status because
                # the token cap was reached. Accept the salvaged diff instead of forcing a
                # retry so we avoid unnecessary context escalation loops.
                append_note(
                    ctx_dir,
                    "openai_call_incomplete_salvaged=diff_present",
                )
                accepted_patch_details = candidate
                attempt_status = "accepted"
                final_status_note = "diff_ready"
                final_reason_note = "patch_ready"
                log_attempt(attempt_no, cap_desc, escalate_reason, attempt_status)
                break
            if idx + 1 < len(token_plan):
                escalate_reason = "truncation"
                attempt_status = "retrying"
                log_attempt(attempt_no, cap_desc, escalate_reason, attempt_status)
                continue
            escalator_exhausted = True
            escalate_reason = "truncation"
            attempt_status = "failed"
            log_attempt(attempt_no, cap_desc, escalate_reason, attempt_status)
            final_status_note = "no_commit"
            final_reason_note = "token_cap_exhausted"
            break

        if candidate_patch:
            ok, failure_label = dry_run_patch_apply(candidate_patch_raw, repo_root)
            if ok:
                accepted_patch_details = candidate
                attempt_status = "accepted"
                final_status_note = "diff_ready"
                final_reason_note = "patch_ready"
                log_attempt(attempt_no, cap_desc, escalate_reason, attempt_status)
                break
            escalate_reason = "patch_apply_failed"
            attempt_status = "retrying" if idx + 1 < len(token_plan) else "failed"
            detail = failure_label or "unknown"
            append_note(ctx_dir, f"patch_apply_dry_run_error={detail}")
            log_attempt(attempt_no, cap_desc, escalate_reason, attempt_status)
            if idx + 1 < len(token_plan):
                continue
            final_status_note = "no_commit"
            final_reason_note = "patch_apply_failed_after_escalation"
            break

        escalate_reason = "no_diff"
        attempt_status = "no_diff"
        log_attempt(attempt_no, cap_desc, escalate_reason, attempt_status)
        if idx + 1 < len(token_plan):
            continue
        accepted_patch_details = candidate
        break

    if response_json is None:
        status_value = "error"
        reason_value = error_reason or "request_exception"
        if error_reason == "remote_disconnected":
            # derived requirement: intermittent RemoteDisconnected responses should not poison
            # the diagnostics summary with a hard error; mark them as a soft miss so CI
            # operators know a rerun is sufficient.
            append_note(ctx_dir, "decision_soft_failure=remote_disconnected")
            status_value = "error_soft"
            reason_value = "remote_disconnected"
        _record_decision(
            ctx_dir,
            status=status_value,
            reason=reason_value,
            response_payload=None,
            patch_text="",
            model=args.model,
            patch_count=current_patch_count,
        )
        record_final_status()
        return

    if escalator_exhausted:
        append_note(ctx_dir, "token_escalator_exhausted=true")

    if accepted_patch_details is not None:
        patch, rationale_raw, rationale_json, format_issue = accepted_patch_details
    else:
        patch, rationale_raw, rationale_json, format_issue = extract_patch(response_json)

    rationale_note: Optional[str] = None
    rationale_summary: Optional[str] = None
    if rationale_json is not None:
        rationale_note = json.dumps(rationale_json, sort_keys=True)
        rationale_summary = json.dumps(rationale_json, indent=2, sort_keys=True)
    elif rationale_raw:
        rationale_note = rationale_raw
        rationale_summary = rationale_raw
    if rationale_note:
        append_note(ctx_dir, f"model_rationale_json={rationale_note}")
    if format_issue == "invalid_rationale_json":
        append_note(ctx_dir, "model_rationale_invalid_json=true")
    if format_issue == "invalid_sequence":
        append_note(ctx_dir, "openai_patch=invalid_sequence")
    if format_issue == "json_only":
        append_note(ctx_dir, "openai_patch=json_only")

    patch_count = 1 if patch.strip() else 0
    total_patch_count = current_patch_count + patch_count

    if patch.strip():
        append_note(ctx_dir, "openai_patch=received")
        _record_decision(
            ctx_dir,
            status="success",
            reason="diff_generated",
            response_payload=response_json,
            patch_text=patch,
            model=args.model,
            rationale=rationale_summary,
            patch_count=total_patch_count,
        )
    else:
        if format_issue == "json_only":
            # derived requirement: explanation-only responses should not surface as hard errors
            append_note(ctx_dir, "openai_patch=explanation_only")
            _record_decision(
                ctx_dir,
                status="skipped",
                reason="explanation_only",
                response_payload=response_json,
                patch_text="",
                model=args.model,
                rationale=rationale_summary,
                patch_count=total_patch_count,
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
                rationale=rationale_summary,
                patch_count=total_patch_count,
            )

    record_final_status()


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
