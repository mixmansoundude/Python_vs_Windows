#!/usr/bin/env python3
"""Utilities for staging and executing the inline model quick-fix."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple
from urllib import request
import zipfile


@dataclass
class RepoFile:
    relative: str
    absolute: Path
    size: int


FATAL_PATTERNS = (
    re.compile(r"::error"),
    re.compile(r"^Error:", re.MULTILINE),
    re.compile(r"Traceback"),
    re.compile(r"^Failed tests?", re.MULTILINE),
    re.compile(r"Process completed with exit code [1-9]"),
)

ALLOWED_GLOBS = [
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
}

DEFAULT_TOTAL_CAP = 6 * 1024 * 1024
PER_FILE_CAP = 200 * 1024
MAX_HEAD_TAIL_LINES = 300


def debug(msg: str) -> None:
    print(msg, file=sys.stderr)


def request_logs_zip(token: str, run_id: str, repo: str, dest: Path) -> None:
    url = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/logs"
    debug(f"Downloading logs from {url}")
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "User-Agent": "inline-quickfix",
    }
    req = request.Request(url, headers=headers)
    with request.urlopen(req) as resp:
        data = resp.read()
    dest.write_bytes(data)


def extract_zip(src: Path, dest_dir: Path) -> None:
    with zipfile.ZipFile(src, "r") as zf:
        zf.extractall(dest_dir)


def iter_step_logs(log_root: Path) -> Iterable[Tuple[Tuple[int, ...], Path]]:
    entries: List[Tuple[Tuple[int, ...], Path]] = []
    for path in log_root.rglob("*.txt"):
        rel = path.relative_to(log_root)
        order: List[int] = []
        for part in rel.parts:
            m = re.match(r"(\d+)_", part)
            if m:
                order.append(int(m.group(1)))
        order_tuple = tuple(order + [len(entries)])
        entries.append((order_tuple, path))
    for item in sorted(entries, key=lambda x: x[0]):
        yield item


@dataclass
class FailingStep:
    log_path: Path
    marker: str
    rel_path: str


def detect_first_failure(log_root: Path) -> Optional[FailingStep]:
    for _, path in iter_step_logs(log_root):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for pattern in FATAL_PATTERNS:
            if pattern.search(text):
                rel = str(path.relative_to(log_root)).replace("\\", "/")
                return FailingStep(log_path=path, marker=pattern.pattern, rel_path=rel)
    return None


def load_repo_files(repo_root: Path) -> Dict[str, RepoFile]:
    files: Dict[str, RepoFile] = {}
    allowed_suffixes = {pat.lstrip("*") for pat in ALLOWED_GLOBS}

    def is_allowed(path: Path) -> bool:
        if not path.is_file():
            return False
        rel = path.relative_to(repo_root)
        rel_parts = rel.parts
        for idx in range(len(rel_parts)):
            prefix = "/".join(rel_parts[: idx + 1])
            if prefix in EXCLUDED_PARTS:
                return False
        suffix = path.suffix.lower()
        if not suffix:
            return False
        if suffix in allowed_suffixes:
            return True
        if any(path.match(pattern) for pattern in ALLOWED_GLOBS):
            return True
        return False

    for pattern in ALLOWED_GLOBS:
        for path in repo_root.rglob(pattern):
            if is_allowed(path):
                rel = str(path.relative_to(repo_root)).replace("\\", "/")
                if rel not in files:
                    files[rel] = RepoFile(relative=rel, absolute=path, size=path.stat().st_size)
    return files


def find_primary_pointer(text: str, repo_files: Dict[str, RepoFile]) -> Tuple[str, Optional[int], List[str]]:
    matches: List[Tuple[str, Optional[int]]] = []
    regex = re.compile(
        r"(?P<path>[A-Za-z0-9_./\\-]+?\.(?:py|ps1|psm1|yml|yaml|sh|bat|cmd|md|txt|json))(?:[:](?P<line>\d+))?"
    )
    for match in regex.finditer(text):
        raw = match.group("path") or ""
        line_str = match.group("line")
        line = int(line_str) if line_str else None
        normalized = normalise_candidate(raw)
        if normalized:
            repo_match = resolve_repo_path(normalized, repo_files)
            if repo_match:
                matches.append((repo_match, line))
    notes: List[str] = []
    if matches:
        chosen = matches[0]
        notes.append(f"primary_file derived from failpack match: {chosen[0]}")
        if chosen[1]:
            notes.append(f"primary line hint: {chosen[1]}")
        return chosen[0], chosen[1], notes
    fallback = ".github/workflows/batch-check.yml"
    if fallback in repo_files:
        notes.append("primary_file fallback: .github/workflows/batch-check.yml")
        return fallback, None, notes
    any_path = next(iter(repo_files.keys()), "README.md")
    notes.append(f"primary_file fallback: {any_path}")
    return any_path, None, notes


def normalise_candidate(raw: str) -> Optional[str]:
    cleaned = raw.strip().strip('"\'<>')
    if not cleaned:
        return None
    cleaned = cleaned.replace("\\", "/")
    cleaned = re.sub(r"^[A-Za-z]:", "", cleaned)
    cleaned = cleaned.lstrip("./")
    while "//" in cleaned:
        cleaned = cleaned.replace("//", "/")
    return cleaned


def resolve_repo_path(candidate: str, repo_files: Dict[str, RepoFile]) -> Optional[str]:
    parts = candidate.split("/")
    for idx in range(len(parts)):
        suffix = "/".join(parts[idx:])
        if suffix in repo_files:
            return suffix
    return None


def truncate_text(data: str, original_size: int, cap: int) -> str:
    lines = data.splitlines()
    if len(lines) <= MAX_HEAD_TAIL_LINES * 2:
        head = lines[:MAX_HEAD_TAIL_LINES]
        tail = lines[MAX_HEAD_TAIL_LINES:]
    else:
        head = lines[:MAX_HEAD_TAIL_LINES]
        tail = lines[-MAX_HEAD_TAIL_LINES:]
    body: List[str] = []
    body.append(f"# truncated to {cap} bytes from {original_size} bytes")
    body.append("# head")
    body.extend(head)
    if len(lines) > MAX_HEAD_TAIL_LINES * 2:
        body.append("# ...")
    if tail:
        body.append("# tail")
        body.extend(tail)
    result = "\n".join(body) + "\n"
    encoded = result.encode("utf-8")
    if len(encoded) > cap:
        # fallback: hard cut
        trimmed = encoded[: cap - 1]
        return trimmed.decode("utf-8", errors="ignore") + "\n"
    return result


def stage(args: argparse.Namespace) -> None:
    ctx = Path(args.ctx).resolve()
    repo = Path(args.repo).resolve()
    if ctx.exists():
        shutil.rmtree(ctx)
    ctx.mkdir(parents=True, exist_ok=True)
    attached_dir = ctx / "attached"
    attached_dir.mkdir(parents=True, exist_ok=True)
    notes: List[str] = []
    manifest_lines: List[str] = []
    attachments: List[str] = []
    total_cap = int(os.environ.get("ATTACH_MAX_TOTAL", DEFAULT_TOTAL_CAP))
    total_bytes = 0

    token = os.environ.get("GH_TOKEN")
    if not token:
        raise SystemExit("GH_TOKEN is required for staging")
    repo_slug = os.environ.get("GITHUB_REPOSITORY")
    if not repo_slug:
        raise SystemExit("GITHUB_REPOSITORY is required")

    logs_zip = ctx / "logs.zip"
    logs_dir = ctx / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    request_logs_zip(token, args.run_id, repo_slug, logs_zip)
    extract_zip(logs_zip, logs_dir)

    failing = detect_first_failure(logs_dir)
    if not failing:
        notes.append("no failing step detected; failpack.log contains placeholder")
        fail_text = "<no failing step detected>\n"
    else:
        fail_text = failing.log_path.read_text(encoding="utf-8", errors="replace")
        notes.append(f"first failing step: {failing.rel_path} via marker {failing.marker}")
    (ctx / "failpack.log").write_text(fail_text, encoding="utf-8")
    shutil.rmtree(logs_dir, ignore_errors=True)
    logs_zip.unlink(missing_ok=True)
    fail_bytes = len(fail_text.encode("utf-8"))
    attachments.append("failpack.log")
    manifest_lines.append(f"failpack.log\t{fail_bytes}")
    total_bytes += fail_bytes

    repo_files = load_repo_files(repo)
    primary_file, line_hint, focus_notes = find_primary_pointer(fail_text, repo_files)
    notes.extend(focus_notes)
    guide = {
        "primary_file": primary_file,
        "line": line_hint,
        "run_id": args.run_id,
        "log_hint": "failpack.log",
    }
    guide_path = ctx / "guide.json"
    guide_path.write_text(json.dumps(guide, indent=2), encoding="utf-8")
    guide_bytes = len(guide_path.read_bytes())
    attachments.insert(0, "guide.json")
    manifest_lines.insert(0, f"guide.json\t{guide_bytes}")
    total_bytes += guide_bytes

    essentials: List[str] = []
    if primary_file in repo_files:
        essentials.append(primary_file)
    if ".github/workflows/batch-check.yml" in repo_files and ".github/workflows/batch-check.yml" not in essentials:
        essentials.append(".github/workflows/batch-check.yml")
    for candidate in ("README.md", "AGENTS.md"):
        if candidate in repo_files and candidate not in essentials:
            essentials.append(candidate)

    extras = [path for path in sorted(repo_files.keys()) if path not in essentials]
    ordered_repo = essentials + extras

    staged_repo: List[str] = []
    for rel in ordered_repo:
        record = repo_files[rel]
        dest = attached_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        raw_data = record.absolute.read_text(encoding="utf-8", errors="replace")
        encoded = raw_data.encode("utf-8")
        staged_data: str
        if len(encoded) > PER_FILE_CAP:
            staged_data = truncate_text(raw_data, len(encoded), PER_FILE_CAP)
            notes.append(f"truncated {rel} to {PER_FILE_CAP} bytes")
        else:
            staged_data = raw_data
        staged_bytes = len(staged_data.encode("utf-8"))
        if total_bytes + staged_bytes > total_cap:
            notes.append(f"skipped {rel}: cap {total_cap} reached at {total_bytes} bytes")
            continue
        dest.write_text(staged_data, encoding="utf-8")
        attach_rel = f"attached/{rel}".replace("\\", "/")
        attachments.append(attach_rel)
        manifest_lines.append(f"{attach_rel}\t{staged_bytes}")
        total_bytes += staged_bytes
        staged_repo.append(rel)

    notes.append(f"attachments total bytes: {total_bytes} (cap {total_cap})")
    (ctx / "iterate_context_manifest.tsv").write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")
    (ctx / "notes.txt").write_text("\n".join(notes) + "\n", encoding="utf-8")
    order_path = ctx / "upload_order.txt"
    order_path.write_text("\n".join(attachments) + "\n", encoding="utf-8")
    meta = {
        "attachments": attachments,
        "primary_file": primary_file,
        "line": line_hint,
        "staged_repo_files": staged_repo,
        "failing_step": failing.rel_path if failing else None,
    }
    (ctx / "stage_meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")


def upload_file(api_key: str, path: Path) -> str:
    with tempfile.NamedTemporaryFile(delete=False) as temp_out:
        temp_out_path = Path(temp_out.name)
    try:
        cmd = [
            "curl",
            "-sS",
            "-w",
            "%{http_code}",
            "-o",
            str(temp_out_path),
            "-X",
            "POST",
            "https://api.openai.com/v1/files",
            "-H",
            f"Authorization: Bearer {api_key}",
            "-F",
            "purpose=responses",
            "-F",
            f"file=@{path}",
        ]
        result = subprocess.run(cmd, check=False, capture_output=True, text=True)
        status = result.stdout.strip()
        body = temp_out_path.read_text(encoding="utf-8", errors="replace")
        if status != "200":
            raise RuntimeError(f"file upload failed for {path}: status {status}, body {body[:200]}")
        payload = json.loads(body)
        file_id = payload.get("id")
        if not file_id:
            raise RuntimeError(f"file upload missing id for {path}")
        return file_id
    finally:
        temp_out_path.unlink(missing_ok=True)


def call_model(args: argparse.Namespace) -> None:
    ctx = Path(args.ctx).resolve()
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        notes_path = ctx / "notes.txt"
        try:
            with notes_path.open('a', encoding='utf-8') as handle:
                handle.write('model call skipped: OPENAI_API_KEY missing\n')
        except Exception:
            pass
        print('OPENAI_API_KEY missing; skipping model request.', file=sys.stderr)
        return
    order_path = ctx / "upload_order.txt"
    if not order_path.exists():
        raise SystemExit("upload_order.txt missing")
    meta_path = ctx / "stage_meta.json"
    meta = {}
    if meta_path.exists():
        try:
            meta = json.loads(meta_path.read_text())
        except Exception:
            meta = {}
    primary = meta.get("primary_file", "")
    line_hint = meta.get("line")
    line_display = str(line_hint) if line_hint is not None else 'null'
    attachments = [line.strip() for line in order_path.read_text().splitlines() if line.strip()]
    file_ids: List[Dict[str, str]] = []
    for rel in attachments:
        absolute = ctx / rel
        if not absolute.exists():
            raise SystemExit(f"attachment missing: {rel}")
        file_id = upload_file(api_key, absolute)
        file_ids.append({"path": rel, "file_id": file_id})
    message_text = (
        "Apply the smallest change that resolves the FIRST failing step described in failpack.log. "
        "Start at guide.json {primary}:{line}; if insufficient, search the attached repo files. "
        "Preserve current messaging/labels/structure. Return ONLY a unified diff fenced by ---BEGIN PATCH--- and ---END PATCH---."
    ).format(primary=primary, line=line_display)
    content = [
        {
            "type": "input_text",
            "text": message_text,
        }
    ]
    for item in file_ids:
        content.append({"type": "input_file", "file_id": item["file_id"]})
    payload = {
        "model": "gpt-5-codex",
        "input": [
            {
                "role": "user",
                "content": content,
            }
        ],
    }
    req_bytes = json.dumps(payload).encode("utf-8")
    req_file = ctx / "request.json"
    req_file.write_bytes(req_bytes)
    with tempfile.NamedTemporaryFile(delete=False) as temp_out:
        temp_out_path = Path(temp_out.name)
    try:
        cmd = [
            "curl",
            "-sS",
            "-w",
            "%{http_code}",
            "-o",
            str(temp_out_path),
            "-X",
            "POST",
            "https://api.openai.com/v1/responses",
            "-H",
            f"Authorization: Bearer {api_key}",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            f"@{req_file}",
        ]
        result = subprocess.run(cmd, check=False, capture_output=True, text=True)
        status = result.stdout.strip()
        body = temp_out_path.read_text(encoding="utf-8", errors="replace")
        if status != "200":
            raise RuntimeError(f"responses call failed: status {status}, body {body[:400]}")
        (ctx / "response.json").write_text(body, encoding="utf-8")
        manifest = {
            "files": file_ids,
            "status": status,
        }
        (ctx / "upload_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    finally:
        temp_out_path.unlink(missing_ok=True)


def extract_patch(args: argparse.Namespace) -> None:
    ctx = Path(args.ctx).resolve()
    response_path = ctx / "response.json"
    if not response_path.exists():
        debug("response.json missing; skipping patch extraction")
        return
    text = response_path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"---BEGIN PATCH---\s*(.*?)\s*---END PATCH---", text, re.DOTALL)
    if not match:
        debug("no fenced patch found")
        return
    patch = match.group(1)
    if not patch.strip():
        debug("patch empty after stripping")
        return
    (ctx / "fix.patch").write_text(patch.strip() + "\n", encoding="utf-8")


def package(args: argparse.Namespace) -> None:
    ctx = Path(args.ctx).resolve()
    output_dir = Path(args.repo).resolve() / "logs"
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"iterate-{args.run_id}-{args.run_attempt}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(ctx.rglob("*")):
            if path.is_file():
                rel = path.relative_to(ctx)
                zf.write(path, rel.as_posix())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inline model quick-fix helper")
    sub = parser.add_subparsers(dest="command", required=True)

    stage_p = sub.add_parser("stage", help="Stage logs and attachments")
    stage_p.add_argument("--run-id", required=True)
    stage_p.add_argument("--run-attempt", required=True)
    stage_p.add_argument("--repo", required=True)
    stage_p.add_argument("--ctx", required=True)
    stage_p.set_defaults(func=stage)

    call_p = sub.add_parser("call", help="Upload attachments and call model")
    call_p.add_argument("--ctx", required=True)
    call_p.set_defaults(func=call_model)

    patch_p = sub.add_parser("extract-patch", help="Extract fenced diff from response")
    patch_p.add_argument("--ctx", required=True)
    patch_p.set_defaults(func=extract_patch)

    pack_p = sub.add_parser("package", help="Zip staged context")
    pack_p.add_argument("--ctx", required=True)
    pack_p.add_argument("--repo", required=True)
    pack_p.add_argument("--run-id", required=True)
    pack_p.add_argument("--run-attempt", required=True)
    pack_p.set_defaults(func=package)

    return parser


def main(argv: Sequence[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
