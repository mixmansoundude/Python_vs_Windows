#!/usr/bin/env python3
"""Publish diagnostics markdown/html and site overview pages."""
from __future__ import annotations

import base64
import json
import os
import re
import shutil
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python < 3.9 is not expected on Actions
    ZoneInfo = None  # type: ignore


@dataclass
class Context:
    diag: Optional[Path]
    artifacts: Optional[Path]
    repo: str
    sha: str
    run_id: str
    run_attempt: str
    run_url: str
    short_sha: str
    inventory_b64: Optional[str]
    batch_run_id: Optional[str]
    batch_run_attempt: Optional[str]
    site: Optional[Path]


def _get_env_path(name: str) -> Optional[Path]:
    value = os.getenv(name)
    return Path(value) if value else None


def _isoformat_ct(now: Optional[datetime] = None) -> str:
    if now is None:
        now = datetime.now(timezone.utc)
    if ZoneInfo is None:
        # Professional note: fall back to UTC when zoneinfo is unavailable so we still emit a timestamp.
        return now.isoformat()
    central = now.astimezone(ZoneInfo("America/Chicago"))
    return central.isoformat()


def _get_context() -> Context:
    diag = _get_env_path("DIAG")
    artifacts = _get_env_path("ARTIFACTS")
    repo = os.getenv("REPO", "n/a")
    sha = os.getenv("SHA", "n/a")
    run_id = os.getenv("RUN_ID", "n/a")
    run_attempt = os.getenv("RUN_ATTEMPT", "n/a")
    run_url = os.getenv("RUN_URL", "n/a")
    short_sha = os.getenv("SHORTSHA") or sha[:7]
    inventory_b64 = os.getenv("INVENTORY_B64")
    batch_run_id = os.getenv("BATCH_RUN_ID")
    batch_run_attempt = os.getenv("BATCH_RUN_ATTEMPT")
    site = _get_env_path("SITE")
    return Context(
        diag=diag,
        artifacts=artifacts,
        repo=repo,
        sha=sha,
        run_id=run_id,
        run_attempt=run_attempt,
        run_url=run_url,
        short_sha=short_sha,
        inventory_b64=inventory_b64,
        batch_run_id=batch_run_id,
        batch_run_attempt=batch_run_attempt,
        site=site,
    )


def _first_child_directory(root: Path) -> Optional[Path]:
    try:
        return next(item for item in sorted(root.iterdir()) if item.is_dir())
    except (FileNotFoundError, StopIteration):
        return None


ITERATE_METADATA_FILENAMES = (
    "decision.txt",
    "model.txt",
    "http_status.txt",
    "response.json",
    "iterate_status.json",
    "why_no_diff.txt",
)


def _iterate_logs_found(context: Context) -> bool:
    """Return True when the iterate-logs artifact actually exists."""

    artifacts = context.artifacts
    if not artifacts:
        return False

    iterate_root = artifacts / "iterate"
    if not iterate_root.exists():
        return False

    expected = iterate_root / f"iterate-logs-{context.run_id}-{context.run_attempt}"
    if expected.exists():
        return True

    # Professional note: actions/download-artifact@v4 can unpack the payload
    # directly under the iterate root instead of a named iterate-logs-*
    # directory. Treat the root as present when metadata files land there so we
    # continue reporting success for flattened artifacts.
    if any((iterate_root / name).exists() for name in ITERATE_METADATA_FILENAMES):
        return True

    temp_dir = iterate_root / "_temp"
    try:
        for candidate in temp_dir.rglob("*"):
            if candidate.is_file():
                return True
    except FileNotFoundError:
        pass

    return False


def _repo_directory(context: Context) -> Optional[Path]:
    diag = context.diag
    if not diag:
        return None
    repo_dir = diag / "repo"
    if repo_dir.is_dir():
        return repo_dir
    return None


def _sanitize_repo_name(context: Context) -> Optional[str]:
    repo = context.repo
    if not repo or repo == "n/a":
        return None
    return repo.replace("/", "-")


def _candidate_repo_roots(repo_dir: Path) -> List[Path]:
    try:
        return [
            child
            for child in sorted(repo_dir.iterdir())
            if child.is_dir() and child.name != "files"
        ]
    except FileNotFoundError:
        return []


def _resolve_repo_root(context: Context) -> Optional[Path]:
    """Locate the extracted working tree for this run's commit."""

    repo_dir = _repo_directory(context)
    if not repo_dir:
        return None

    sanitized = _sanitize_repo_name(context)
    candidates = _candidate_repo_roots(repo_dir)

    def prefer(name: str) -> Optional[Path]:
        candidate = repo_dir / name
        if candidate.is_dir():
            return candidate
        return None

    if sanitized:
        for suffix in (
            context.short_sha,
            context.sha[:12] if context.sha and context.sha != "n/a" else None,
            context.sha if context.sha and context.sha != "n/a" else None,
        ):
            if not suffix:
                continue
            resolved = prefer(f"{sanitized}-{suffix}")
            if resolved:
                return resolved

    for candidate in candidates:
        if sanitized and context.short_sha and context.short_sha in candidate.name:
            return candidate
        if sanitized and context.sha and context.sha != "n/a" and context.sha in candidate.name:
            return candidate

    try:
        direct_children = [child for child in repo_dir.iterdir() if child.name != "index.html"]
    except FileNotFoundError:
        direct_children = []

    if any(child.is_file() for child in direct_children):
        return repo_dir
    if (repo_dir / ".github").is_dir():
        return repo_dir
    if candidates:
        return candidates[0]
    return repo_dir


def _relative_repo_path(path: Path, context: Context) -> Optional[str]:
    diag = context.diag
    if not diag:
        return None
    try:
        return path.relative_to(diag).as_posix()
    except ValueError:
        return _relative_to_diag(path, diag)


def _normalize_repo_zip(context: Context) -> None:
    """Ensure repo.zip lives at the bundle root to avoid legacy aliases."""

    diag = context.diag
    if not diag:
        return
    desired = diag / "repo.zip"
    if desired.exists():
        return
    repo_dir = _repo_directory(context)
    if not repo_dir:
        return

    sanitized = _sanitize_repo_name(context)
    legacy_names: List[str] = []
    if sanitized:
        legacy_names.append(f"{sanitized}-{context.short_sha}.zip")
        if context.sha and context.sha != "n/a":
            legacy_names.append(f"{sanitized}-{context.sha}.zip")
    legacy_names.append(f"repo-{context.short_sha}.zip")

    for name in legacy_names:
        candidate = repo_dir / name
        if not candidate.exists():
            continue
        try:
            candidate.rename(desired)
        except OSError:
            # Professional note: fall back to copying when rename fails, e.g.,
            # when the artifact lives on a different filesystem. We remove the
            # legacy file afterward so GitHub Pages only serves the canonical
            # repo.zip expected by consumers.
            try:
                shutil.copyfile(candidate, desired)
            except OSError:
                return
            try:
                candidate.unlink()
            except OSError:
                pass
        return


def _discover_iterate_dir(context: Context) -> Optional[Path]:
    artifacts = context.artifacts
    if not artifacts:
        return None
    iterate_root = artifacts / "iterate"
    if not iterate_root.exists():
        return None

    if any((iterate_root / name).exists() for name in ITERATE_METADATA_FILENAMES):
        # Professional note: actions/download-artifact@v4 can unpack iterate metadata directly
        # into the root without an intermediate iterate-logs-* directory. Honor that layout so
        # diagnostics capture the files instead of defaulting to the child _temp directory.
        return iterate_root

    expected = iterate_root / f"iterate-logs-{context.run_id}-{context.run_attempt}"
    if expected.exists():
        return expected

    try:
        candidates = sorted(p for p in iterate_root.iterdir() if p.is_dir())
    except FileNotFoundError:
        candidates = []

    for candidate in candidates:
        if candidate.name == "_temp":
            continue
        if (candidate / "decision.txt").exists() or (candidate / "response.json").exists():
            return candidate

    if candidates and all(candidate.name == "_temp" for candidate in candidates):
        return iterate_root

    preferred = next((c for c in candidates if c.name != "_temp"), None)
    if preferred:
        return preferred

    return _first_child_directory(iterate_root)


def _discover_temp_dir(iterate_dir: Optional[Path], context: Context) -> Optional[Path]:
    artifacts = context.artifacts
    if not artifacts:
        return None
    iterate_root = artifacts / "iterate"
    candidates: List[Path] = []
    if (iterate_root / "_temp").exists():
        candidates.append(iterate_root / "_temp")
    if iterate_dir and (iterate_dir / "_temp").exists():
        candidates.append(iterate_dir / "_temp")
    if not candidates and iterate_root.exists():
        candidates.extend(p for p in iterate_root.rglob("_temp") if p.is_dir())
    return candidates[0] if candidates else None


def _iterate_lookup_dirs(
    iterate_dir: Optional[Path], iterate_temp: Optional[Path] = None
) -> List[Path]:
    """Return iterate directories to search, prioritizing metadata roots."""

    candidates: List[Path] = []
    seen: set[Path] = set()

    def add(path: Optional[Path]) -> None:
        if not path:
            return
        try:
            if not path.exists() or not path.is_dir():
                return
        except FileNotFoundError:
            return
        if path not in seen:
            candidates.append(path)
            seen.add(path)

    add(iterate_dir)
    if iterate_dir:
        add(iterate_dir / "_temp")
    add(iterate_temp)
    if iterate_temp:
        add(iterate_temp / "_temp")

    return candidates


def _find_iterate_file(
    iterate_dir: Optional[Path], iterate_temp: Optional[Path], name: str
) -> Optional[Path]:
    for directory in _iterate_lookup_dirs(iterate_dir, iterate_temp):
        candidate = directory / name
        if candidate.exists() and candidate.is_file():
            return candidate
    return None


def _read_iterate_text(
    iterate_dir: Optional[Path], iterate_temp: Optional[Path], name: str
) -> str:
    path = _find_iterate_file(iterate_dir, iterate_temp, name)
    if not path:
        return "n/a"
    value = _read_text(path)
    return value if value else "n/a"


def _read_iterate_first_line(
    iterate_dir: Optional[Path], iterate_temp: Optional[Path], name: str
) -> Optional[str]:
    path = _find_iterate_file(iterate_dir, iterate_temp, name)
    return _read_first_line(path) if path else None


def _load_iterate_json(
    iterate_dir: Optional[Path], iterate_temp: Optional[Path], name: str
) -> Optional[dict]:
    path = _find_iterate_file(iterate_dir, iterate_temp, name)
    return _load_json(path) if path else None


def _read_first_line(path: Path) -> Optional[str]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                return line.strip()
    except FileNotFoundError:
        return None
    return None


def _read_text(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None


def _load_json(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def _format_status_value(value: object) -> str:
    if isinstance(value, bool):
        return str(value).lower()
    if value is None:
        return "n/a"
    return str(value)


def _normalize_link(value: Optional[str]) -> Optional[str]:
    if not value:
        return value
    return value.replace("\\", "/")


def _escape_html(value: Optional[str]) -> str:
    if value is None:
        return ""
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def _escape_href(value: Optional[str]) -> Optional[str]:
    if not value:
        return value
    try:
        from urllib.parse import quote

        return quote(value, safe="/:?=&%#")
    except Exception:
        return value


def _relative_to_diag(path: Path, diag: Optional[Path]) -> str:
    if not diag:
        return path.as_posix()
    try:
        return path.relative_to(diag).as_posix()
    except ValueError:
        return path.as_posix()


def _gather_iterate_tokens(
    iterate_dir: Optional[Path], iterate_temp: Optional[Path], response_data: Optional[dict]
) -> dict:
    tokens = {"prompt": "n/a", "completion": "n/a", "total": "n/a"}
    if response_data and isinstance(response_data.get("usage"), dict):
        usage = response_data["usage"]
        for key in ("prompt", "completion", "total"):
            field = f"{key}_tokens" if key != "total" else "total_tokens"
            value = usage.get(field)
            if value is not None:
                tokens[key] = str(value)
    token_path = _find_iterate_file(iterate_dir, iterate_temp, "tokens.txt")
    if token_path and token_path.exists():
        for line in token_path.read_text(encoding="utf-8").splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if key and key not in tokens:
                tokens[key] = value
            elif key in tokens and (tokens[key] in {"n/a", "", None}):
                tokens[key] = value
    return tokens


def _diff_produced(iterate_dir: Optional[Path], iterate_temp: Optional[Path]) -> bool:
    patch_path = _find_iterate_file(iterate_dir, iterate_temp, "patch.diff")
    if not patch_path:
        return False
    head = patch_path.read_text(encoding="utf-8", errors="ignore").splitlines()[:20]
    if not head:
        return False
    return not (len(head) == 1 and head[0].strip() == "# no changes")


def _gather_ndjson_summaries(artifacts: Optional[Path]) -> List[Path]:
    if not artifacts or not artifacts.exists():
        return []
    return sorted(artifacts.rglob("ndjson_summary.txt"))

def _diag_files(diag: Optional[Path]) -> List[Path]:
    if not diag or not diag.exists():
        return []
    return sorted(p for p in diag.rglob("*") if p.is_file())


def _inventory_lines(encoded: Optional[str]) -> List[str]:
    if not encoded:
        return []
    try:
        decoded = base64.b64decode(encoded).decode("utf-8")
    except Exception:
        return []
    return decoded.splitlines()


def _nonempty_file(path: Path) -> bool:
    try:
        return path.is_file() and path.stat().st_size > 0
    except FileNotFoundError:
        return False


def _artifact_stats(artifacts: Optional[Path]) -> tuple[int, Optional[str]]:
    if not artifacts or not artifacts.exists():
        return 0, None
    files = [p for p in artifacts.rglob("*") if p.is_file()]
    missing = artifacts / "MISSING.txt"
    missing_note = _read_text(missing) if missing.exists() else None
    return len(files), missing_note


def _batch_status(diag: Optional[Path], context: Context) -> str:
    run_id = context.batch_run_id
    attempt = context.batch_run_attempt or "n/a"
    if run_id:
        if not diag:
            return f"missing archive (run {run_id}, attempt {attempt})"
        candidate = diag / "logs" / f"batch-check-{run_id}-{attempt}.zip"
        if candidate.exists():
            return f"found (run {run_id}, attempt {attempt})"
        return f"missing archive (run {run_id}, attempt {attempt})"
    if diag and (diag / "logs" / "batch-check.MISSING.txt").exists():
        return "missing (see logs/batch-check.MISSING.txt)"
    return "missing"


def _ensure_repo_index(context: Context) -> None:
    """Create repo/index.html that reflects the run's working tree."""

    repo_dir = _repo_directory(context)
    if not repo_dir:
        return
    repo_root = _resolve_repo_root(context)
    if not repo_root or not repo_root.exists():
        return

    index_path = repo_dir / "index.html"

    # Professional note: regenerate the landing page from the extracted
    # working copy so the diagnostics site only exposes the tree Codex
    # evaluated for this run. GitHub Pages reference:
    # https://docs.github.com/en/pages/getting-started-with-github-pages/about-github-pages
    files = [
        path
        for path in sorted(repo_root.rglob("*"))
        if path.is_file()
    ]

    rows: List[str] = []
    for file in files:
        try:
            relative = file.relative_to(repo_dir).as_posix()
        except ValueError:
            continue
        if relative == "index.html":
            continue
        href_target = _escape_href(relative) or relative
        rows.append(
            f'<li><a href="./{href_target}">{_escape_html(relative)}</a></li>'
        )

    if not rows:
        rows.append("<li>(no files extracted)</li>")

    lines = [
        "<!doctype html>",
        '<html lang="en">',
        "<head>",
        '<meta charset="utf-8">',
        "<title>Repository files</title>",
        "</head>",
        "<body>",
        "<main>",
        "<h1>Repository files</h1>",
        "<p>Browse the extracted commit snapshot below.</p>",
        "<ul>",
    ]
    lines.extend(rows)
    lines.extend(["</ul>", "</main>", "</body>", "</html>"])
    index_path.write_text("\n".join(lines), encoding="utf-8")


def _describe_batch_ndjson_label(filename: str) -> str:
    lower = filename.lower()
    if "cache" in lower:
        return "Batch-check NDJSON (cache)"
    if lower.endswith(".ndjson.zip") or lower.endswith(".zip"):
        return "Batch-check NDJSON"
    return f"Batch-check log: {filename}"


def _collect_batch_ndjson_links(diag: Optional[Path]) -> List[dict]:
    if not diag:
        return []

    results: List[dict] = []
    seen_zip: set[str] = set()
    seen_plain: set[str] = set()
    candidates = [diag / "logs", diag / "_artifacts" / "batch-check"]
    for root in candidates:
        if not root or not root.exists():
            continue
        for path in sorted(root.rglob("*.zip")):
            if "ndjson" not in path.name.lower():
                continue
            # Professional note: only surface bundles that actually shipped in
            # this run so the published links stay accurate when cache or run
            # payloads are absent.
            rel = _relative_to_diag(path, diag)
            if rel in seen_zip:
                continue
            seen_zip.add(rel)
            label = _describe_batch_ndjson_label(path.name)
            results.append({
                "label": label,
                "path": rel,
            })
            plain = path.with_suffix("")
            if plain.exists() and plain.is_file():
                plain_rel = _relative_to_diag(plain, diag)
                if plain_rel not in seen_plain:
                    seen_plain.add(plain_rel)
                    results.append({
                        "label": f"{label} (unzipped)",
                        "path": plain_rel,
                    })
    return results


def _locate_iterate_root(context: Context) -> Optional[Path]:
    if context.artifacts and (context.artifacts / "iterate").exists():
        return context.artifacts / "iterate"
    if context.diag:
        candidate = context.diag / "_artifacts" / "iterate"
        if candidate.exists():
            return candidate
    return None


def _discover_iterate_temp_dirs(iterate_root: Path) -> List[Path]:
    """Return candidate _temp directories that should contain iterate payloads."""

    candidates: List[Path] = []
    seen: set[Path] = set()

    def add(path: Path) -> None:
        if path.is_dir() and path not in seen:
            candidates.append(path)
            seen.add(path)

    add(iterate_root / "_temp")
    try:
        for child in sorted(iterate_root.iterdir()):
            if not child.is_dir():
                continue
            if child.name == "_temp":
                add(child)
            else:
                add(child / "_temp")
    except FileNotFoundError:
        pass

    for path in sorted(iterate_root.rglob("_temp")):
        add(path)

    if not candidates:
        add(iterate_root)

    return candidates


def _ensure_iterate_text_mirrors(
    context: Context, iterate_dir: Optional[Path], iterate_temp: Optional[Path]
) -> None:
    """Materialize iterate JSON mirrors (.txt) for the diagnostics bundle."""

    diag = context.diag
    if not diag:
        return

    diag_iterate_root = diag / "_artifacts" / "iterate"
    diag_temp = diag_iterate_root / "_temp"
    try:
        diag_temp.mkdir(parents=True, exist_ok=True)
    except OSError:
        return

    def copy_into_diag(source_name: str, dest_name: Optional[str] = None) -> bool:
        source = _find_iterate_file(iterate_dir, iterate_temp, source_name)
        if not source:
            return False

        destination = diag_temp / (dest_name or source_name)
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
        except OSError:
            return False

        try:
            if source.resolve() == destination.resolve():
                return True
        except OSError:
            pass

        try:
            shutil.copyfile(source, destination)
        except OSError:
            return destination.exists()
        return True

    def write_text(destination: Path, payload: str) -> None:
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(payload, encoding="utf-8")
        except OSError:
            pass

    def mirror_json(json_name: str, txt_name: str) -> None:
        present = copy_into_diag(json_name)
        if present:
            json_source = diag_temp / json_name
            if not json_source.exists():
                original = _find_iterate_file(iterate_dir, iterate_temp, json_name)
                json_source = original if original else json_source
        else:
            json_source = None

        if json_source and json_source.exists():
            try:
                parsed = json.loads(json_source.read_text(encoding="utf-8"))
                pretty = json.dumps(parsed, indent=2, sort_keys=True)
            except (json.JSONDecodeError, OSError):
                try:
                    pretty = json_source.read_text(encoding="utf-8")
                except OSError:
                    pretty = "missing"
        else:
            pretty = "missing"

        write_text(diag_temp / txt_name, pretty if pretty else "missing")

    copy_into_diag("prompt.txt")
    copy_into_diag("why_no_diff.txt")
    copy_into_diag("patch.apply.log")
    mirror_json("response.json", "response.txt")
    mirror_json("iterate_status.json", "iterate_status.txt")
    mirror_json("first_failure.json", "first_failure.txt")


def _summarize_iterate_files(context: Context) -> Tuple[str, List[Path]]:
    iterate_root = _locate_iterate_root(context)
    roots: List[Path] = []
    if context.diag:
        diag_root = context.diag / "_artifacts" / "iterate"
        if diag_root.exists():
            roots.append(diag_root)
    if iterate_root and iterate_root.exists() and iterate_root not in roots:
        roots.append(iterate_root)

    if not roots:
        return "missing", []

    temp_dirs: List[Path] = []
    for root in roots:
        for candidate in _discover_iterate_temp_dirs(root):
            if candidate not in temp_dirs:
                temp_dirs.append(candidate)

    has_files = False
    for temp_dir in temp_dirs:
        for path in temp_dir.rglob("*"):
            if path.is_file():
                has_files = True
                break
        if has_files:
            break
    if not has_files:
        return "missing", []

    key_names = [
        "prompt.txt",
        "response.json",
        "response.txt",
        "iterate_status.json",
        "iterate_status.txt",
        "why_no_diff.txt",
        "first_failure.json",
        "first_failure.txt",
        "patch.apply.log",
    ]
    found: List[Path] = []
    for pattern in key_names:
        match: Optional[Path] = None
        for directory in temp_dirs:
            candidate = directory / pattern
            if candidate.exists():
                match = candidate
                break
        if not match:
            for directory in temp_dirs:
                try:
                    match = next(p for p in directory.rglob(pattern) if p.is_file())
                except StopIteration:
                    continue
                else:
                    break
        if match:
            found.append(match)

    if not found:
        # Professional note: surface that content exists even if the usual
        # prompt/response/why files are missing so analysts know to explore.
        return "present", []

    return "present", found


def _write_summary_files(
    context: Context,
    iterate_dir: Optional[Path],
    iterate_temp: Optional[Path],
    response_data: Optional[dict],
    why_outcome: Optional[str],
) -> None:
    """Emit diag/_summary.txt and status.json for downstream consumers."""

    diag = context.diag
    if not diag:
        return

    model = _read_iterate_text(iterate_dir, iterate_temp, "model.txt")
    if response_data and response_data.get("model"):
        model = str(response_data["model"])

    tokens = _gather_iterate_tokens(iterate_dir, iterate_temp, response_data)
    total_tokens = tokens.get("total", "n/a")
    if not total_tokens or str(total_tokens).lower() in {"n/a", "none"}:
        total_tokens = "unknown"
    total_tokens_str = str(total_tokens)

    diff_produced = _diff_produced(iterate_dir, iterate_temp)
    outcome = why_outcome or ("diff produced" if diff_produced else "n/a")

    if not _iterate_logs_found(context):
        outcome = "n/a"

    summary_line = f"model={model} tokens={total_tokens_str} outcome={outcome}"
    try:
        (diag / "_summary.txt").write_text(summary_line + "\n", encoding="utf-8")
    except OSError:
        pass

    status_payload = {
        "model": model,
        "tokens": total_tokens_str,
        "outcome": outcome,
    }
    try:
        (diag / "status.json").write_text(
            json.dumps(status_payload, indent=2, sort_keys=True),
            encoding="utf-8",
        )
    except OSError:
        pass


def _bundle_links(context: Context) -> List[dict]:
    diag = context.diag
    entries: List[dict] = []

    if diag:
        inventory_entries = [
            ("Inventory (HTML)", "inventory.html"),
            ("Inventory (text)", "inventory.txt"),
            ("Inventory (markdown)", "inventory.md"),
            ("Inventory (json)", "inventory.json"),
        ]
        for label, relative in inventory_entries:
            candidate = diag / relative
            if _nonempty_file(candidate):
                entries.append({"label": label, "path": relative})

        iterate_zip = (
            diag / "logs" / f"iterate-{context.run_id}-{context.run_attempt}.zip"
        )
        if _nonempty_file(iterate_zip):
            entries.append(
                {
                    "label": "Iterate logs zip",
                    "path": _relative_to_diag(iterate_zip, diag),
                }
            )

        entries.extend(_collect_batch_ndjson_links(diag))

        for label, relative in [
            ("Batch-check failing tests", "batchcheck_failing.txt"),
            ("Batch-check fail debug", "batchcheck_fail-debug.txt"),
        ]:
            candidate = diag / relative
            if candidate.exists():
                entries.append({"label": label, "path": relative})

        repo_zip = diag / "repo.zip"
        if _nonempty_file(repo_zip):
            entries.append({"label": "Repository (zip)", "path": "repo.zip"})
        repo_index = diag / "repo" / "index.html"
        if repo_index.exists():
            entries.append(
                {"label": "Repository (unzipped)", "path": "repo/index.html"}
            )

        wf_dir = diag / "wf"
        if wf_dir.exists():
            workflow_files = [
                ("Workflow: codex-auto-iterate.yml", "codex-auto-iterate.yml"),
                (
                    "Workflow: codex-auto-iterate.yml (text)",
                    "codex-auto-iterate.yml.txt",
                ),
                ("Workflow: batch-check.yml", "batch-check.yml"),
                ("Workflow: batch-check.yml (text)", "batch-check.yml.txt"),
            ]
            for label, name in workflow_files:
                candidate = wf_dir / name
                if _nonempty_file(candidate):
                    entries.append({"label": label, "path": f"wf/{name}"})

    return entries


def _build_markdown(
    context: Context,
    iterate_dir: Optional[Path],
    iterate_temp: Optional[Path],
    built_utc: str,
    built_ct: str,
    response_data: Optional[dict],
    status_data: Optional[dict],
    why_outcome: Optional[str],
) -> str:
    diag = context.diag
    artifacts = context.artifacts

    # Professional note: honor the "Simplify diagnostics" directive by basing the
    # parser-facing signal solely on the iterate-logs artifact directory for this
    # run. Avoid consulting legacy run-log zips so downstream dashboards receive a
    # consistent contract.
    iterate_found = _iterate_logs_found(context)
    iterate_log_status = "found" if iterate_found else "missing"
    iterate_hint = None if iterate_found else "see logs/iterate.MISSING.txt"

    def read_value(name: str) -> str:
        return _read_iterate_text(iterate_dir, iterate_temp, name)

    decision = read_value("decision.txt")
    model = read_value("model.txt")
    endpoint = read_value("endpoint.txt")
    http_status = read_value("http_status.txt")

    if response_data:
        if response_data.get("http_status") is not None:
            http_status = str(response_data["http_status"])
        if response_data.get("model"):
            model = str(response_data["model"])

    tokens = _gather_iterate_tokens(iterate_dir, iterate_temp, response_data)

    diff_produced = _diff_produced(iterate_dir, iterate_temp)
    outcome = why_outcome or ("diff produced" if diff_produced else "n/a")

    attempt_summary = None
    if not response_data and status_data:
        attempt_summary = "attempted={0} gate={1} auth_ok={2} attempts_left={3}".format(
            _format_status_value(status_data.get("attempted")),
            _format_status_value(status_data.get("gate")),
            _format_status_value(status_data.get("auth_ok")),
            _format_status_value(status_data.get("attempts_left")),
        )

    ndjson_summaries = _gather_ndjson_summaries(artifacts)
    iterate_file_status, iterate_key_files = _summarize_iterate_files(context)
    diag_files = _diag_files(diag)
    artifact_count, artifact_missing = _artifact_stats(artifacts)
    batch_status = _batch_status(diag, context)
    lines: List[str] = []

    if iterate_log_status != "found":
        outcome = "n/a"
        iterate_file_status = "missing"
        iterate_key_files = []

    lines.extend(
        [
            "# CI Diagnostics",
            f"Repo: {context.repo}",
            f"Commit: {context.sha}",
            f"Run: {context.run_id} (attempt {context.run_attempt})",
            f"Built (UTC): {built_utc}",
            f"Built (CT): {built_ct}",
            f"Run page: {context.run_url}",
            "",
            "## Status",
            f"* Iterate logs: {iterate_log_status}",
            f"- Batch-check run id: {batch_status}",
            f"- Artifact files enumerated: {artifact_count}",
        ]
    )

    if iterate_hint:
        lines.append(f"  {iterate_hint}")

    if artifact_missing:
        lines.append(f"- Artifact sentinel: {artifact_missing}")
    lines.append("")
    lines.append("## Quick links")

    for entry in _bundle_links(context):
        label = entry["label"]
        path = entry.get("path")
        if not path:
            continue
        normalized = _normalize_link(path)
        lines.append(f"- {label}: [{normalized}]({normalized})")

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
            f"- Iterate files: {iterate_file_status}",
        ]
    )
    if attempt_summary:
        lines.append(f"- Attempt summary: {attempt_summary}")

    if iterate_file_status == "present":
        if iterate_key_files:
            for file in iterate_key_files:
                rel = _relative_to_diag(file, diag)
                normalized = _normalize_link(rel)
                label = file.name
                lines.append(f"  - [{label}]({normalized})")
        else:
            lines.append("  - (prompt/response/why_no_diff not located)")
    else:
        lines.append("  - (no iterate files captured)")

    batch_meta = artifacts / "batch-check" / "run.json" if artifacts else None
    if batch_meta and batch_meta.exists():
        try:
            meta = json.loads(batch_meta.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            meta = None
        if meta:
            lines.extend(
                [
                    "",
                    "## Batch-check run",
                    f"- Run id: {meta.get('run_id')} (attempt {meta.get('run_attempt')})",
                    f"- Status: {meta.get('status')} / {meta.get('conclusion')}",
                ]
            )
            if meta.get("html_url"):
                lines.append(f"- Run page: {meta['html_url']}")

    if ndjson_summaries:
        lines.append("")
        lines.append("## NDJSON summaries")
        for file in ndjson_summaries:
            rel = _relative_to_diag(file, diag)
            lines.append(f"### {rel}")
            lines.append("```text")
            lines.extend(file.read_text(encoding="utf-8").splitlines())
            lines.append("```")

    if diag_files:
        lines.append("")
        lines.append("## File listing")
        for file in diag_files:
            rel = _relative_to_diag(file, diag)
            size = f"{file.stat().st_size:,}"
            normalized = _normalize_link(rel)
            lines.append(f"- [{size} bytes]({normalized})")

    inventory_lines = _inventory_lines(context.inventory_b64)
    if inventory_lines:
        lines.append("")
        lines.append("## Inventory (raw)")
        lines.extend(inventory_lines)

    return "\n".join(lines)


def _write_markdown(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def _write_html(
    context: Context,
    iterate_dir: Optional[Path],
    iterate_temp: Optional[Path],
    built_utc: str,
    built_ct: str,
    response_data: Optional[dict],
    status_data: Optional[dict],
    why_outcome: Optional[str],
) -> str:
    diag = context.diag
    artifacts = context.artifacts

    # Professional note: mirror the Markdown status logic here so HTML renders the
    # same parser-facing state derived from the iterate-logs artifact directory.
    iterate_found = _iterate_logs_found(context)
    iterate_log_status = "found" if iterate_found else "missing"
    iterate_hint = None if iterate_found else "see logs/iterate.MISSING.txt"

    def read_value(name: str) -> str:
        return _read_iterate_text(iterate_dir, iterate_temp, name)

    decision = read_value("decision.txt")
    model = read_value("model.txt")
    endpoint = read_value("endpoint.txt")
    http_status = read_value("http_status.txt")

    if response_data:
        if response_data.get("http_status") is not None:
            http_status = str(response_data["http_status"])
        if response_data.get("model"):
            model = str(response_data["model"])

    tokens = _gather_iterate_tokens(iterate_dir, iterate_temp, response_data)
    diff_produced = _diff_produced(iterate_dir, iterate_temp)
    outcome = why_outcome or ("diff produced" if diff_produced else "n/a")
    attempt_summary = None
    if not response_data and status_data:
        attempt_summary = "attempted={0} gate={1} auth_ok={2} attempts_left={3}".format(
            _format_status_value(status_data.get("attempted")),
            _format_status_value(status_data.get("gate")),
            _format_status_value(status_data.get("auth_ok")),
            _format_status_value(status_data.get("attempts_left")),
        )

    artifact_count, artifact_missing = _artifact_stats(artifacts)
    ndjson_summaries = _gather_ndjson_summaries(artifacts)
    iterate_file_status, iterate_key_files = _summarize_iterate_files(context)
    batch_status = _batch_status(diag, context)
    diag_files = _diag_files(diag)

    if iterate_log_status != "found":
        outcome = "n/a"
        iterate_file_status = "missing"
        iterate_key_files = []

    metadata_pairs = [
        {"label": "Repo", "value": context.repo},
        {"label": "Commit", "value": context.sha},
        {"label": "Run", "value": f"{context.run_id} (attempt {context.run_attempt})"},
        {"label": "Built (UTC)", "value": built_utc},
        {"label": "Built (CT)", "value": built_ct},
        {"label": "Run page", "value": context.run_url, "href": context.run_url},
    ]

    status_pairs = [
        {"label": "Iterate logs", "value": iterate_log_status},
        {"label": "Batch-check run id", "value": batch_status},
        {"label": "Artifact files enumerated", "value": str(artifact_count)},
    ]
    if artifact_missing:
        status_pairs.append({"label": "Artifact sentinel", "value": artifact_missing})

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
        {"label": "Iterate files", "value": iterate_file_status, "files": iterate_key_files},
    ]
    if attempt_summary:
        iterate_pairs.append({"label": "Attempt summary", "value": attempt_summary})

    html: List[str] = []
    html.append("<!doctype html>")
    html.append('<html lang="en">')
    html.append("<head>")
    html.append('<meta charset="utf-8">')
    html.append("<title>CI Diagnostics</title>")
    html.append("</head>")
    html.append("<body>")
    html.append("<h1>CI Diagnostics</h1>")

    def render_pairs(title: str, pairs: Iterable[dict]) -> None:
        html.append("<section>")
        html.append(f"<h2>{_escape_html(title)}</h2>")
        html.append("<ul>")
        for pair in pairs:
            label = _escape_html(pair.get("label"))
            value = pair.get("value")
            href = pair.get("href")
            files = pair.get("files")
            if href:
                html.append(
                    f"<li><strong>{label}:</strong> <a href=\"{_escape_href(href)}\">{_escape_html(str(value))}</a></li>"
                )
                continue

            if files is not None:
                html.append(f"<li><strong>{label}:</strong> {_escape_html(str(value))}")
                html.append("<ul>")
                if str(value) == "present":
                    if files:
                        for file in files:
                            rel = _relative_to_diag(file, diag)
                            normalized = _normalize_link(rel)
                            href_file = _escape_href(normalized)
                            html.append(
                                f"<li><code><a href=\"{href_file}\">{_escape_html(file.name)}</a></code></li>"
                            )
                    else:
                        html.append("<li>(prompt/response/why_no_diff not located)</li>")
                else:
                    html.append("<li>(no iterate files captured)</li>")
                html.append("</ul>")
                html.append("</li>")
                continue

            html.append(f"<li><strong>{label}:</strong> {_escape_html(str(value))}</li>")
        html.append("</ul>")
        html.append("</section>")

    render_pairs("Metadata", metadata_pairs)
    render_pairs("Status", status_pairs)

    html.append("<section>")
    html.append("<h2>Quick links</h2>")
    html.append("<ul>")
    for entry in _bundle_links(context):
        label = _escape_html(entry["label"])
        path = entry.get("path")
        if path:
            href = _escape_href(_normalize_link(path))
            html.append(f"<li><a href=\"{href}\">{label}</a></li>")
    html.append("</ul>")
    html.append("</section>")

    render_pairs("Iterate metadata", iterate_pairs)

    if iterate_hint:
        html.append(
            f"<!-- Iterate logs hint: {_escape_html(iterate_hint)} -->"
        )

    batch_meta = artifacts / "batch-check" / "run.json" if artifacts else None
    if batch_meta and batch_meta.exists():
        try:
            meta = json.loads(batch_meta.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            meta = None
        if meta:
            html.append("<section>")
            html.append("<h2>Batch-check run</h2>")
            html.append("<ul>")
            run_id_html = _escape_html(str(meta.get("run_id")))
            attempt_html = _escape_html(str(meta.get("run_attempt")))
            html.append(f"<li>Run id: {run_id_html} (attempt {attempt_html})</li>")
            html.append(
                f"<li>Status: {_escape_html(str(meta.get('status')))} / {_escape_html(str(meta.get('conclusion')))}</li>"
            )
            if meta.get("html_url"):
                html.append(f"<li><a href=\"{_escape_href(meta['html_url'])}\">Run page</a></li>")
            html.append("</ul>")
            html.append("</section>")

    if ndjson_summaries:
        html.append("<section>")
        html.append("<h2>NDJSON summaries</h2>")
        for file in ndjson_summaries:
            rel = _escape_html(_relative_to_diag(file, diag))
            html.append(f"<h3>{rel}</h3>")
            html.append("<pre>")
            for line in file.read_text(encoding="utf-8").splitlines():
                html.append(_escape_html(line))
            html.append("</pre>")
        html.append("</section>")

    if diag_files:
        html.append("<section>")
        html.append("<h2>File listing</h2>")
        html.append("<ul>")
        for file in diag_files:
            rel = _normalize_link(_relative_to_diag(file, diag))
            href = _escape_href(rel)
            text = _escape_html(rel)
            size = _escape_html(f"{file.stat().st_size:,} bytes")
            html.append(f"<li><a href=\"{href}\">{text}</a> — {size}</li>")
        html.append("</ul>")
        html.append("</section>")

    inventory_lines = _inventory_lines(context.inventory_b64)
    if inventory_lines:
        html.append("<section>")
        html.append("<h2>Inventory (raw)</h2>")
        html.append("<pre>")
        for line in inventory_lines:
            html.append(_escape_html(line))
        html.append("</pre>")
        html.append("</section>")

    html.append("</body>")
    html.append("</html>")
    return "\n".join(html)


def _validate_iterate_status_line(markdown: str) -> None:
    """Ensure the parser-facing iterate bullet stays in the legacy format."""

    pattern = re.compile(r"(?m)^\* Iterate logs: (found|missing)$")
    matches = pattern.findall(markdown)
    if len(matches) != 1:
        raise ValueError(
            "Iterate logs bullet missing or invalid; expected '* Iterate logs: found|missing'."
        )


def _write_latest_json(context: Context) -> None:
    if not (context.site and context.diag):
        return
    data = {
        "repo": context.repo,
        "run_id": context.run_id,
        "run_attempt": context.run_attempt,
        "sha": context.sha,
        "bundle_url": f"diag/{context.run_id}-{context.run_attempt}/index.html",
        "inventory": f"diag/{context.run_id}-{context.run_attempt}/inventory.json",
        "workflow": f"diag/{context.run_id}-{context.run_attempt}/wf/codex-auto-iterate.yml.txt",
        "iterate": {
            "prompt": f"diag/{context.run_id}-{context.run_attempt}/_artifacts/iterate/iterate/prompt.txt",
            "response": f"diag/{context.run_id}-{context.run_attempt}/_artifacts/iterate/iterate/response.json",
            "diff": f"diag/{context.run_id}-{context.run_attempt}/_artifacts/iterate/iterate/patch.diff",
            "log": f"diag/{context.run_id}-{context.run_attempt}/_artifacts/iterate/iterate/exec.log",
        },
    }
    (context.site / "latest.json").write_text(json.dumps(data, indent=2), encoding="utf-8")


def _has_file(site: Optional[Path], relative: str) -> bool:
    if not site:
        return False
    candidate = site / Path(relative)
    if not candidate.exists():
        return False
    if candidate.is_file() and candidate.name.startswith("inventory."):
        return candidate.stat().st_size > 0
    return True


def _build_site_overview(
    context: Context,
    iterate_dir: Optional[Path],
    iterate_temp: Optional[Path],
    response_data: Optional[dict],
) -> tuple[str, str]:
    site = context.site
    artifacts = context.artifacts
    run_id = context.run_id
    run_attempt = context.run_attempt
    bundle_prefix = f"diag/{run_id}-{run_attempt}"
    cache_bust = context.run_id
    bundle_index_href = f"{bundle_prefix}/index.html?v={cache_bust}"

    def read_value(name: str) -> str:
        return _read_iterate_text(iterate_dir, iterate_temp, name)

    decision = read_value("decision.txt")
    http_status = read_value("http_status.txt")
    if response_data and response_data.get("http_status") is not None:
        http_status = str(response_data["http_status"])

    inventory_html = f"{bundle_prefix}/inventory.html"
    inventory_txt = f"{bundle_prefix}/inventory.txt"
    inventory_md = f"{bundle_prefix}/inventory.md"
    inventory_json = f"{bundle_prefix}/inventory.json"
    iterate_zip_rel = f"{bundle_prefix}/logs/iterate-{run_id}-{run_attempt}.zip"
    repo_zip_rel = f"{bundle_prefix}/repo.zip"
    repo_index_rel = f"{bundle_prefix}/repo/index.html"
    batch_ndjson_links = _collect_batch_ndjson_links(context.diag)

    ndjson_summary = None
    if artifacts and artifacts.exists():
        ndjson_summary = next(artifacts.rglob("ndjson_summary.txt"), None)

    summary_preview: List[str] = []
    if ndjson_summary:
        summary_preview.append("```text")
        summary_preview.extend(ndjson_summary.read_text(encoding="utf-8").splitlines())
        summary_preview.append("```")

    lines = [
        "# Diagnostics overview",
        "",
        f"Latest run: [{run_id} (attempt {run_attempt})]({_normalize_link(bundle_index_href)})",
        "",
        "## Metadata",
        f"- Repo: {context.repo}",
        f"- Commit: {context.sha}",
        f"- Run page: {context.run_url}",
        f"- Iterate decision: {decision}",
        f"- Iterate HTTP status: {http_status}",
        "",
        "## Quick links",
    ]

    def quick_link(label: str, path: Optional[str]) -> None:
        if not path:
            return
        if _has_file(site, path.split("?", 1)[0]):
            lines.append(f"- [{label}]({_normalize_link(path)})")

    quick_link("Bundle index", bundle_index_href)
    quick_link("Open latest (cache-busted)", bundle_index_href)
    quick_link("Artifact inventory (HTML)", inventory_html)
    quick_link("Artifact inventory (text)", inventory_txt)
    quick_link("Artifact inventory (JSON)", inventory_json)
    quick_link("Iterate logs zip", iterate_zip_rel)
    for entry in batch_ndjson_links:
        quick_link(entry["label"], f"{bundle_prefix}/{entry['path']}")
    quick_link("Repository (zip)", repo_zip_rel)
    quick_link("Repository (unzipped)", repo_index_rel)
    for label, relative in [
        ("Workflow: codex-auto-iterate.yml", f"{bundle_prefix}/wf/codex-auto-iterate.yml"),
        (
            "Workflow: codex-auto-iterate.yml (text)",
            f"{bundle_prefix}/wf/codex-auto-iterate.yml.txt",
        ),
        ("Workflow: batch-check.yml", f"{bundle_prefix}/wf/batch-check.yml"),
        ("Workflow: batch-check.yml (text)", f"{bundle_prefix}/wf/batch-check.yml.txt"),
    ]:
        quick_link(label, relative)
    quick_link("Inventory (markdown)", inventory_md)

    if summary_preview:
        lines.append("")
        lines.append("## NDJSON summary (first bundle)")
        lines.extend(summary_preview)

    lines.append("")
    lines.append(
        "Artifacts from the self-test workflow and iterate job are merged under the bundle directory above."
    )

    markdown = "\n".join(lines)

    html_lines: List[str] = []
    html_lines.append("<!doctype html>")
    html_lines.append('<html lang="en">')
    html_lines.append("<head>")
    html_lines.append('<meta charset="utf-8">')
    html_lines.append("<title>Diagnostics overview</title>")
    html_lines.append("</head>")
    html_lines.append("<body>")
    html_lines.append("<h1>Diagnostics overview</h1>")
    html_lines.append(
        f"<p>Latest run: <a href=\"{_escape_href(_normalize_link(bundle_index_href))}\">{_escape_html(f'{run_id} (attempt {run_attempt})')}</a></p>"
    )

    metadata_items = [
        {"label": "Repo", "value": context.repo},
        {"label": "Commit", "value": context.sha},
        {"label": "Run page", "value": context.run_url, "href": context.run_url},
        {"label": "Iterate decision", "value": decision},
        {"label": "Iterate HTTP status", "value": http_status},
    ]

    html_lines.append("<section>")
    html_lines.append("<h2>Metadata</h2>")
    html_lines.append("<ul>")
    for item in metadata_items:
        label = _escape_html(item["label"])
        value = _escape_html(str(item["value"]))
        href = item.get("href")
        if href:
            html_lines.append(
                f"<li><strong>{label}:</strong> <a href=\"{_escape_href(href)}\">{value}</a></li>"
            )
        else:
            html_lines.append(f"<li><strong>{label}:</strong> {value}</li>")
    html_lines.append("</ul>")
    html_lines.append("</section>")

    quick_link_specs = [
        {"label": "Bundle index", "path": bundle_index_href},
        {"label": "Open latest (cache-busted)", "path": bundle_index_href},
        {"label": "Artifact inventory (HTML)", "path": inventory_html},
        {"label": "Artifact inventory (text)", "path": inventory_txt},
        {"label": "Artifact inventory (JSON)", "path": inventory_json},
        {"label": "Iterate logs zip", "path": iterate_zip_rel},
        {"label": "Repository (zip)", "path": repo_zip_rel},
        {"label": "Repository (unzipped)", "path": repo_index_rel},
        {"label": "Inventory (markdown)", "path": inventory_md},
    ]
    quick_link_specs.extend(
        [
            {
                "label": "Workflow: codex-auto-iterate.yml",
                "path": f"{bundle_prefix}/wf/codex-auto-iterate.yml",
            },
            {
                "label": "Workflow: codex-auto-iterate.yml (text)",
                "path": f"{bundle_prefix}/wf/codex-auto-iterate.yml.txt",
            },
            {
                "label": "Workflow: batch-check.yml",
                "path": f"{bundle_prefix}/wf/batch-check.yml",
            },
            {
                "label": "Workflow: batch-check.yml (text)",
                "path": f"{bundle_prefix}/wf/batch-check.yml.txt",
            },
        ]
    )
    ndjson_specs = [
        {"label": entry["label"], "path": f"{bundle_prefix}/{entry['path']}"}
        for entry in batch_ndjson_links
    ]
    if ndjson_specs:
        insert_at = 5
        quick_link_specs[insert_at:insert_at] = ndjson_specs

    html_lines.append("<section>")
    html_lines.append("<h2>Quick links</h2>")
    html_lines.append("<ul>")
    filtered_specs = [
        spec
        for spec in quick_link_specs
        if spec.get("path") and _has_file(site, spec["path"].split("?", 1)[0])
    ]
    for spec in filtered_specs:
        label = _escape_html(spec["label"])
        path = spec.get("path")
        html_lines.append(
            f"<li><a href=\"{_escape_href(_normalize_link(path))}\">{label}</a></li>"
        )
    html_lines.append("</ul>")
    html_lines.append("</section>")

    if summary_preview:
        html_lines.append("<section>")
        html_lines.append("<h2>NDJSON summary (first bundle)</h2>")
        html_lines.append("<pre>")
        for line in summary_preview:
            if line.startswith("```"):
                continue
            html_lines.append(_escape_html(line))
        html_lines.append("</pre>")
        html_lines.append("</section>")

    html_lines.append(
        "<p>Artifacts from the self-test workflow and iterate job are merged under the bundle directory above.</p>"
    )
    html_lines.append("</body>")
    html_lines.append("</html>")

    return markdown, "\n".join(html_lines)


def main() -> None:
    context = _get_context()
    _normalize_repo_zip(context)
    _ensure_repo_index(context)
    iterate_dir = _discover_iterate_dir(context)
    iterate_temp = _discover_temp_dir(iterate_dir, context)
    now = datetime.now(timezone.utc)
    # Professional note: capture the timestamps once so markdown and HTML stay synchronized.
    built_utc = now.isoformat()
    built_ct = _isoformat_ct(now)
    response_data = _load_iterate_json(iterate_dir, iterate_temp, "response.json")
    status_data = _load_iterate_json(iterate_dir, iterate_temp, "iterate_status.json")
    why_outcome = _read_iterate_first_line(iterate_dir, iterate_temp, "why_no_diff.txt")
    _ensure_iterate_text_mirrors(context, iterate_dir, iterate_temp)

    diag_markdown = _build_markdown(
        context,
        iterate_dir,
        iterate_temp,
        built_utc,
        built_ct,
        response_data,
        status_data,
        why_outcome,
    )
    _validate_iterate_status_line(diag_markdown)
    if context.diag:
        _write_markdown(context.diag / "index.md", diag_markdown)
        diag_html = _write_html(
            context,
            iterate_dir,
            iterate_temp,
            built_utc,
            built_ct,
            response_data,
            status_data,
            why_outcome,
        )
        (context.diag / "index.html").write_text(diag_html, encoding="utf-8")
        _write_summary_files(context, iterate_dir, iterate_temp, response_data, why_outcome)

    if context.site:
        site_markdown, site_html = _build_site_overview(
            context, iterate_dir, iterate_temp, response_data
        )
        _write_markdown(context.site / "index.md", site_markdown)
        (context.site / "index.html").write_text(site_html, encoding="utf-8")
        _write_latest_json(context)


if __name__ == "__main__":
    main()
