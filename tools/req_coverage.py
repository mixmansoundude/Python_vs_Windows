#!/usr/bin/env python3
"""Aggregate requirement coverage from NDJSON test result files.

Usage:
    python tools/req_coverage.py <ndjson_dir>

Outputs JSON mapping REQ-XXX -> "pass" | "fail" | "missing".
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Dict, List


def compute_coverage(ndjson_dir: Path) -> Dict[str, str]:
    """Return dict mapping REQ-XXX -> 'pass' | 'fail'.

    Rules:
    - Parse all *.ndjson files under ndjson_dir recursively.
    - For each row that has a "req" field, record the pass/fail outcome.
    - If any row for a REQ is fail -> "fail"; else "pass".
    - REQs with no rows are not included (caller may treat absence as "missing").
    """
    req_results: Dict[str, List[bool]] = {}

    for path in sorted(ndjson_dir.rglob("*.ndjson")):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            req = row.get("req")
            if not req:
                continue
            pass_val = bool(row.get("pass"))
            if req not in req_results:
                req_results[req] = []
            req_results[req].append(pass_val)

    coverage: Dict[str, str] = {}
    for req in sorted(req_results):
        results = req_results[req]
        coverage[req] = "pass" if all(results) else "fail"
    return coverage


if __name__ == "__main__":
    d = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    print(json.dumps(compute_coverage(d), indent=2))
