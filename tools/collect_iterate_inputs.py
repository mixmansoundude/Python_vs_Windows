#!/usr/bin/env python3
"""Collect iterate inputs and gate signals from an upstream workflow run."""
from __future__ import annotations

import argparse
import io
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from typing import Dict, Iterable, List, Optional, Tuple

DEFAULT_HEADERS = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "collect-iterate-inputs/1.0",
}


def gh_request(url: str, token: str, accept: Optional[str] = None) -> Tuple[bytes, Dict[str, str]]:
    headers = dict(DEFAULT_HEADERS)
    if accept:
        headers["Accept"] = accept
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as resp:  # nosec B310 (GitHub API HTTPS)
        data = resp.read()
        header_map = {k.lower(): v for k, v in resp.headers.items()}
    return data, header_map


def gh_request_json(url: str, token: str) -> Dict[str, object]:
    raw, _ = gh_request(url, token)
    try:
        return json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:  # pragma: no cover - diagnostic
        raise RuntimeError(f"Failed to decode JSON from {url}: {exc}") from exc


def iter_paginated(url: str, token: str) -> Iterable[Dict[str, object]]:
    next_url = url
    while next_url:
        data, headers = gh_request(next_url, token)
        payload = json.loads(data.decode("utf-8"))
        items = payload.get("artifacts") or payload.get("jobs") or payload.get("workflow_runs")
        if not isinstance(items, list):
            items = []
        for item in items:
            yield item
        link_header = headers.get("link", "")
        next_url = None
        if link_header:
            for part in link_header.split(","):
                section = part.strip()
                if section.endswith('rel="next"'):
                    start = section.find("<")
                    end = section.find(">", start + 1)
                    if start != -1 and end != -1:
                        next_url = section[start + 1 : end]
                        break


def ensure_placeholder(path: pathlib.Path, message: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text(message + "\n", encoding="utf-8")


def copy_file_bytes(dest: pathlib.Path, content: bytes) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(content)


TARGET_PATTERNS = {
    "tests/~test-results.ndjson": "ndjson",
    "tests/~test-summary.txt": "summary",
    "dynamic_tests.log": "dynamic",
    "~dynamic-run.log": "dynamic",
}

SELFTEST_PREFIX = "tests/~selftest_"


def normalize_zip_path(name: str) -> str:
    return name.replace("\\", "/")


class CollectionState:
    def __init__(self) -> None:
        self.collected: Dict[str, List[pathlib.Path]] = {}
        self.ndjson_primary: Optional[pathlib.Path] = None
        self.summary_texts: List[str] = []
        self.summary_first_failure = False
        self.gate_output_verdict: Optional[str] = None

    def add_path(self, key: str, path: pathlib.Path) -> None:
        self.collected.setdefault(key, []).append(path)
        if key == "ndjson" and self.ndjson_primary is None:
            self.ndjson_primary = path


def parse_ndjson(path: pathlib.Path) -> Tuple[int, int, bool]:
    passes = 0
    fails = 0
    any_fail = False
    try:
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and "pass" in obj:
                val = obj.get("pass")
                if val is False:
                    fails += 1
                    any_fail = True
                elif val is True:
                    passes += 1
            elif isinstance(obj, dict) and obj.get("id") == "bootstrap.state":
                state = obj.get("details", {}).get("state") if isinstance(obj.get("details"), dict) else None
                if state and state not in {"ok", "no_python_files", "venv_env", "degraded_env"}:
                    any_fail = True
            elif isinstance(obj, dict) and obj.get("id") == "self.bootstrap.state":
                state = obj.get("details", {}).get("state") if isinstance(obj.get("details"), dict) else None
                if state and state not in {"ok", "no_python_files", "venv_env", "degraded_env"}:
                    any_fail = True
    except FileNotFoundError:
        pass
    return passes, fails, any_fail


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="owner/repo slug")
    parser.add_argument("--run-id", required=True, help="Workflow run ID to inspect")
    parser.add_argument("--output", required=True, help="Directory to write collected inputs")
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""), help="GitHub token")
    args = parser.parse_args()

    token = args.token or ""
    output_dir = pathlib.Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest: Dict[str, object] = {
        "repo": args.repo,
        "run_id": args.run_id,
        "collected": {},
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    run_url = f"https://api.github.com/repos/{args.repo}/actions/runs/{args.run_id}"
    try:
        run_data = gh_request_json(run_url, token)
    except Exception as exc:  # pragma: no cover - network
        sys.stderr.write(f"Failed to fetch run metadata: {exc}\n")
        run_data = {}
    copy_file_bytes(output_dir / "run_metadata.json", json.dumps(run_data, indent=2).encode("utf-8"))

    run_attempt = run_data.get("run_attempt") if isinstance(run_data, dict) else None
    if not isinstance(run_attempt, int):
        run_attempt = None

    state = CollectionState()

    # Collect artifacts
    artifacts_url = f"https://api.github.com/repos/{args.repo}/actions/runs/{args.run_id}/artifacts?per_page=100"
    artifacts: List[Dict[str, object]] = list(iter_paginated(artifacts_url, token))
    manifest["artifacts"] = [a.get("name") for a in artifacts]

    for artifact in artifacts:
        name = str(artifact.get("name"))
        expired = bool(artifact.get("expired"))
        if expired:
            continue
        artifact_id = artifact.get("id")
        if not artifact_id:
            continue
        download_url = f"https://api.github.com/repos/{args.repo}/actions/artifacts/{artifact_id}/zip"
        try:
            raw_zip, _ = gh_request(download_url, token, accept="application/zip")
        except urllib.error.HTTPError as exc:  # pragma: no cover - network
            sys.stderr.write(f"Failed to download artifact {name}: {exc}\n")
            continue
        with zipfile.ZipFile(io.BytesIO(raw_zip)) as zf:
            for entry in zf.infolist():
                if entry.is_dir():
                    continue
                rel = normalize_zip_path(entry.filename)
                content = zf.read(entry)
                dest = output_dir / name / rel
                copy_file_bytes(dest, content)
                lowered = rel.lower()
                for pattern, key in TARGET_PATTERNS.items():
                    if lowered.endswith(pattern.lower()):
                        state.add_path(key, dest)
                if lowered.startswith(SELFTEST_PREFIX):
                    state.add_path("selftest", dest)
                if lowered.endswith("iterate_gate.json") or lowered.endswith("ci_gate_outputs.json"):
                    try:
                        parsed = json.loads(content.decode("utf-8"))
                    except Exception:
                        parsed = None
                    if isinstance(parsed, dict):
                        verdict = parsed.get("verdict")
                        if isinstance(verdict, str):
                            state.gate_output_verdict = verdict
                if lowered.endswith("workflow_run_outputs.json"):
                    try:
                        parsed = json.loads(content.decode("utf-8"))
                    except Exception:
                        parsed = None
                    if isinstance(parsed, dict):
                        verdict = parsed.get("verdict")
                        if isinstance(verdict, str):
                            state.gate_output_verdict = verdict

    # Ensure placeholders exist
    ensure_placeholder(output_dir / "PLACEHOLDER.txt", "Collected inputs directory created")

    for pattern, key in TARGET_PATTERNS.items():
        matching = state.collected.get(key, [])
        if not matching:
            ensure_placeholder(
                output_dir / pattern,
                f"Missing source for {pattern}; placeholder created to keep artifact non-empty.",
            )
            manifest["collected"].setdefault(key, []).append(str((output_dir / pattern).relative_to(output_dir)))
        else:
            manifest["collected"].setdefault(key, []).extend(
                [str(path.relative_to(output_dir)) for path in matching]
            )

    if "selftest" not in state.collected:
        ensure_placeholder(
            output_dir / "tests/~selftest_placeholder.log",
            "No self-test logs were published in upstream artifacts.",
        )
        manifest["collected"].setdefault("selftest", []).append("tests/~selftest_placeholder.log")
    else:
        manifest["collected"]["selftest"] = [
            str(path.relative_to(output_dir)) for path in state.collected["selftest"]
        ]

    # Collect job summaries / logs for First failure detection
    summary_lines: List[str] = []
    jobs_endpoint = f"https://api.github.com/repos/{args.repo}/actions/runs/{args.run_id}/jobs?per_page=100"
    jobs = list(iter_paginated(jobs_endpoint, token))
    copy_file_bytes(output_dir / "run_jobs.json", json.dumps(jobs, indent=2).encode("utf-8"))
    manifest["job_count"] = len(jobs)

    for job in jobs:
        job_id = job.get("id")
        if not job_id:
            continue
        log_url = f"https://api.github.com/repos/{args.repo}/actions/jobs/{job_id}/logs"
        try:
            raw_log, _ = gh_request(log_url, token, accept="application/zip")
        except urllib.error.HTTPError:
            continue
        try:
            with zipfile.ZipFile(io.BytesIO(raw_log)) as zf:
                for entry in zf.infolist():
                    if entry.is_dir():
                        continue
                    rel = normalize_zip_path(entry.filename)
                    try:
                        text = zf.read(entry).decode("utf-8", errors="ignore")
                    except Exception:
                        continue
                    summary_lines.append(f"# Job {job_id} - {rel}")
                    summary_lines.append(text)
                    if "first failure" in text.lower():
                        state.summary_first_failure = True
        except zipfile.BadZipFile:
            continue

    if not summary_lines:
        summary_lines.append("Job summaries/logs unavailable for upstream run.")
    summary_text = "\n\n".join(summary_lines)
    (output_dir / "step_summary_raw.txt").write_text(summary_text, encoding="utf-8")

    if not state.summary_first_failure:
        # As fallback, inspect test summary file(s)
        for path in state.collected.get("summary", []):
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            if "first failure" in text.lower():
                state.summary_first_failure = True
                break

    manifest["summary_first_failure"] = state.summary_first_failure

    ndjson_path = state.ndjson_primary
    ndjson_found = ndjson_path is not None and ndjson_path.exists()
    ndjson_empty = True
    ndjson_passes = 0
    ndjson_fails = 0
    ndjson_any_fail = False
    if ndjson_found:
        content = ndjson_path.read_text(encoding="utf-8", errors="ignore")
        ndjson_empty = len(content.strip()) == 0
        ndjson_passes, ndjson_fails, ndjson_any_fail = parse_ndjson(ndjson_path)
    manifest.update(
        {
            "ndjson_found": ndjson_found,
            "ndjson_empty": ndjson_empty,
            "ndjson_passes": ndjson_passes,
            "ndjson_fails": ndjson_fails,
            "ndjson_any_fail": ndjson_any_fail,
            "gate_output_verdict": state.gate_output_verdict,
        }
    )

    copy_file_bytes(output_dir / "collection_manifest.json", json.dumps(manifest, indent=2).encode("utf-8"))

    outputs_path = os.environ.get("GITHUB_OUTPUT")
    if outputs_path:
        with open(outputs_path, "a", encoding="utf-8") as fh:
            fh.write(f"ndjson_found={str(ndjson_found).lower()}\n")
            fh.write(f"ndjson_empty={str(ndjson_empty).lower()}\n")
            fh.write(f"ndjson_any_fail={str(ndjson_any_fail).lower()}\n")
            fh.write(f"ndjson_passes={ndjson_passes}\n")
            fh.write(f"ndjson_fails={ndjson_fails}\n")
            fh.write(f"summary_first_failure={str(state.summary_first_failure).lower()}\n")
            if state.gate_output_verdict:
                fh.write(f"gate_output_verdict={state.gate_output_verdict}\n")
            if run_data.get("conclusion"):
                fh.write(f"upstream_conclusion={run_data['conclusion']}\n")


if __name__ == "__main__":
    main()
