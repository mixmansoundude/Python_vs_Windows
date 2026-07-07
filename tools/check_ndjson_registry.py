#!/usr/bin/env python3
"""Cross-checks NDJSON row IDs across three sources: docs/agent-ndjson.md (doc),
PowerShell Write-NdjsonRow/Write-Result call sites plus run_setup.bat inline
emissions (code), and observed NDJSON artifacts from a CI run (log, optional).

Advisory tool: reports mismatches, does not attempt to be exhaustive.
Scope: PowerShell-emitted rows only (tests/*.ps1, tests/harness.ps1,
run_setup.bat). dynamic_tests.py's Python-side rows are out of scope --
docs/agent-ndjson.md's own "Dynamic-tests NDJSON" section already
acknowledges several of those as "(x many)" per-test-case IDs.
"""
import argparse
import json
import re
import sys
from pathlib import Path

DOC_FENCE_RE = re.compile(r'```(?:\w*)\n(.*?)\n```', re.DOTALL)
BRACE_RE = re.compile(r'([A-Za-z0-9_.\-]*)\{([^{}]+)\}')
DOC_TOKEN_RE = re.compile(r'([A-Za-z0-9][A-Za-z0-9_.\-]*\.[A-Za-z0-9_.\-]*)(?:\s*\(([^()]*)\))?')
CODE_HASHTABLE_ID_RE = re.compile(r"""\bid\s*=\s*['"]([A-Za-z0-9][A-Za-z0-9_.\-]*)['"]""")
CODE_WRITERESULT_ID_RE = re.compile(r"""Write-Result\s+['"]([A-Za-z0-9][A-Za-z0-9_.\-]*)['"]""")
CODE_NAMEDPARAM_ID_RE = re.compile(r"""-Id\s+['"]([A-Za-z0-9][A-Za-z0-9_.\-]*)['"]""")


def expand_braces(text: str) -> str:
    def _expand(m):
        prefix, inner = m.group(1), m.group(2)
        return ', '.join(prefix + v.strip() for v in inner.split(','))
    prev = None
    while prev != text:
        prev = text
        text = BRACE_RE.sub(_expand, text)
    return text


def parse_doc_registry(doc_path: Path):
    """Returns (ids, many_ids). many_ids is informational only (rows tagged "(x many)"
    fire multiple times under one literal id, e.g. once per loop iteration -- confirmed
    by inspecting their emission sites; it is NOT a dynamic/templated-id wildcard, so it
    does not need special-case exclusion from the doc/code diff below)."""
    text = doc_path.read_text(encoding='utf-8')
    ids = set()
    many_ids = set()
    for block in DOC_FENCE_RE.findall(text):
        block = expand_braces(block)
        for m in DOC_TOKEN_RE.finditer(block):
            token, note = m.group(1), m.group(2)
            token = token.strip().rstrip('.')
            if not token:
                continue
            ids.add(token)
            if note and 'many' in note.lower():
                many_ids.add(token)
    return ids, many_ids


def scan_code_ids(paths):
    ids = set()
    for p in paths:
        text = p.read_text(encoding='utf-8', errors='replace')
        for m in CODE_HASHTABLE_ID_RE.finditer(text):
            ids.add(m.group(1))
        for m in CODE_WRITERESULT_ID_RE.finditer(text):
            ids.add(m.group(1))
        for m in CODE_NAMEDPARAM_ID_RE.finditer(text):
            ids.add(m.group(1))
    return ids


def scan_log_ids(log_dir: Path):
    ids = set()
    if not log_dir or not log_dir.is_dir():
        return ids
    for ndjson_file in log_dir.rglob('*.ndjson'):
        try:
            for line in ndjson_file.read_text(encoding='utf-8', errors='replace').splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(row, dict) and 'id' in row:
                    ids.add(str(row['id']))
        except OSError:
            continue
    return ids


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo-root', default='.', type=Path)
    ap.add_argument('--log-dir', default=None, type=Path,
                     help='Directory containing downloaded *.ndjson artifacts (optional)')
    args = ap.parse_args(argv)

    root = args.repo_root
    doc_path = root / 'docs' / 'agent-ndjson.md'
    doc_ids, doc_many_ids = parse_doc_registry(doc_path)

    code_paths = sorted((root / 'tests').glob('*.ps1')) + [root / 'run_setup.bat']
    code_paths = [p for p in code_paths if p.is_file()]
    code_ids = scan_code_ids(code_paths)

    doc_only = sorted(doc_ids - code_ids)
    code_only = sorted(code_ids - doc_ids)

    print(f"Doc-registered IDs: {len(doc_ids)} ({len(doc_many_ids)} tagged '(x many)')")
    print(f"Code-emitted IDs (PowerShell scan): {len(code_ids)}")
    print()

    ok = True
    if doc_only:
        ok = False
        print(f"## Registered in docs but no matching code emission site found ({len(doc_only)})")
        print("(stale/removed row -- doc likely needs cleanup -- OR a legitimate 'Dynamic-tests")
        print(" NDJSON' row from tests/dynamic_tests.py, which this scanner does not read (Python")
        print(" file, out of scope by design -- see this script's module docstring). Verify by")
        print(" hand against dynamic_tests.py before treating any of these as a real gap.)")
        for i in doc_only:
            print(f"  - {i}")
        print()

    if code_only:
        ok = False
        print(f"## Emitted in code but not registered in docs/agent-ndjson.md ({len(code_only)})")
        print("(the AGENT DIRECTIVE gap this tool exists to catch -- register these)")
        for i in code_only:
            print(f"  - {i}")
        print()

    if args.log_dir:
        observed = scan_log_ids(args.log_dir)
        print(f"Observed IDs in downloaded NDJSON artifacts: {len(observed)}")
        known = doc_ids | code_ids
        never_observed = sorted(i for i in known if i not in observed)
        if never_observed:
            print(f"## Known IDs never observed in this run's artifacts ({len(never_observed)})")
            print("(ADVISORY ONLY -- many of these are legitimately lane/flag-gated or")
            print(" inline-emitted rows that don't reach a real CI artifact by design; see")
            print(" docs/agent-ndjson.md 'Key facts for debugging missing rows'. Not a failure")
            print(" signal on its own -- for human review only, never affects exit code.)")
            for i in never_observed:
                print(f"  - {i}")
        print()

    if ok:
        print("PASS: no doc/code registry mismatches found.")
        return 0
    else:
        print("FAIL: doc/code registry mismatches found (see above). This check is advisory")
        print("(non-gating) -- it will not block PR merges, but should be addressed.")
        return 1


if __name__ == '__main__':
    sys.exit(main())
