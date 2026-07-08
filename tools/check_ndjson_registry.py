#!/usr/bin/env python3
"""Cross-checks NDJSON row IDs across three sources: docs/agent-ndjson.md (doc),
code emission sites (PowerShell Write-NdjsonRow/Write-Result call sites plus
run_setup.bat inline emissions, .github/workflows/*.yml inline PowerShell
emissions, and tests/dynamic_tests.py's Python record({"id": ...}) calls), and
observed NDJSON artifacts from a CI run (log, optional).

Advisory tool: reports mismatches, does not attempt to be exhaustive.
Python scanning (tests/dynamic_tests.py only) uses `ast` to resolve id values
that are string literals, f-strings templated from an enclosing `for` loop's
literal iterable (e.g. f"pr.{_pkg}.{_target}"), or a bare loop variable used
directly as the id (e.g. `for rec_id, ... in [("entry.select.single", ...), ...]:
record({"id": rec_id, ...})`) -- including the one-hop `rec = {"id": ...}; ...;
record(rec)` indirection this file also uses. It does not attempt to resolve
ids built from anything more dynamic than that (nested loops, function calls,
non-literal iterables) -- see scan_dynamic_tests_ids's and _resolve_id_value's docstrings.
"""
import argparse
import ast
import json
import re
import sys
from pathlib import Path

DOC_FENCE_RE = re.compile(r'```(?:\w*)\n(.*?)\n```', re.DOTALL)
BRACE_RE = re.compile(r'([A-Za-z0-9_.\-]*)\{([^{}]+)\}')
DOC_TOKEN_RE = re.compile(r'([A-Za-z0-9][A-Za-z0-9_.~\-]*\.[A-Za-z0-9_.~\-]*)(?:\s*\(([^()]*)\))?')
CODE_HASHTABLE_ID_RE = re.compile(r"""\bid\s*=\s*['"]([A-Za-z0-9][A-Za-z0-9_.\-]*)['"]""")
CODE_WRITERESULT_ID_RE = re.compile(r"""Write-Result\s+['"]([A-Za-z0-9][A-Za-z0-9_.\-]*)['"]""")
CODE_NAMEDPARAM_ID_RE = re.compile(r"""-Id\s+['"]([A-Za-z0-9][A-Za-z0-9_.\-]*)['"]""")
CODE_JSONLITERAL_ID_RE = re.compile(r'"id"\s*:\s*"([A-Za-z0-9][A-Za-z0-9_.\-]*)"')


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
        for m in CODE_JSONLITERAL_ID_RE.finditer(text):
            ids.add(m.group(1))
    return ids


def _literal(node):
    """Return the literal value of a simple ast.Constant, else None."""
    return node.value if isinstance(node, ast.Constant) else None


def _for_loop_bindings(for_node, local_dicts):
    """For `for TARGET in ITER:`, return a list of {name: literal_value} dicts, one per
    iteration, if ITER is a literal List/Tuple, or a `.items()` call on a name already
    resolved (via local_dicts) to a literal dict assigned earlier in the same scope (e.g.
    `needed = {...}; for dst, var in needed.items():`). Returns None if ITER isn't
    resolvable this way at all (e.g. a function call, an unresolved name) -- callers must
    treat None as "can't resolve, skip". A tuple-unpacking target may mix literal and
    non-literal positions (e.g. `for rec_id, expected, files in [(str, str, {...}), ...]`)
    -- non-literal positions (like a dict literal) are simply omitted from each binding
    rather than failing the whole loop, since a caller only needs the specific name(s) it
    actually references as an id value.
    """
    iter_node = for_node.iter
    if isinstance(iter_node, (ast.List, ast.Tuple)):
        elts = iter_node.elts
    elif (isinstance(iter_node, ast.Call) and isinstance(iter_node.func, ast.Attribute)
            and iter_node.func.attr == 'items' and isinstance(iter_node.func.value, ast.Name)
            and iter_node.func.value.id in local_dicts
            and isinstance(local_dicts[iter_node.func.value.id], ast.Dict)):
        dict_node = local_dicts[iter_node.func.value.id]
        elts = [ast.Tuple(elts=[k, v]) for k, v in zip(dict_node.keys, dict_node.values)]
    else:
        return None
    target = for_node.target
    if isinstance(target, ast.Name):
        names = [target.id]
    elif isinstance(target, ast.Tuple):
        names = [t.id if isinstance(t, ast.Name) else None for t in target.elts]
    else:
        return None

    bindings = []
    for elt in elts:
        binding = {}
        if len(names) == 1:
            val = _literal(elt)
            if val is not None:
                binding[names[0]] = val
        else:
            if not isinstance(elt, ast.Tuple) or len(elt.elts) < len(names):
                return None
            for name, sub in zip(names, elt.elts):
                if name is None:
                    continue
                val = _literal(sub)
                if val is not None:
                    binding[name] = val
        bindings.append(binding)
    return bindings


def _resolve_id_value(value_node, loop_stack):
    """Resolve an "id" dict-value AST node to a list of concrete id strings, using the
    innermost enclosing for-loop's per-iteration bindings (loop_stack[-1]) when the value
    is a bare loop variable or an f-string templated from loop variables. Returns [] if
    unresolvable (e.g. templated from something other than the innermost loop, or from a
    non-literal source) -- unresolvable ids are silently skipped, matching this tool's
    "advisory, not exhaustive" posture rather than raising.
    """
    lit = _literal(value_node)
    if lit is not None:
        return [str(lit)]

    if isinstance(value_node, ast.Name):
        if not loop_stack:
            return []
        return [str(b[value_node.id]) for b in loop_stack[-1] if value_node.id in b]

    if isinstance(value_node, ast.JoinedStr):
        if not loop_stack:
            return []
        bindings = loop_stack[-1]
        out = []
        for binding in bindings:
            parts = []
            ok = True
            for piece in value_node.values:
                if isinstance(piece, ast.Constant):
                    parts.append(str(piece.value))
                elif isinstance(piece, ast.FormattedValue) and isinstance(piece.value, ast.Name):
                    name = piece.value.id
                    if name not in binding:
                        ok = False
                        break
                    parts.append(str(binding[name]))
                else:
                    ok = False
                    break
            if ok:
                out.append(''.join(parts))
        return out

    return []


def _dict_id_values(dict_node, loop_stack):
    if not isinstance(dict_node, ast.Dict):
        return []
    for key, value in zip(dict_node.keys, dict_node.values):
        if isinstance(key, ast.Constant) and key.value == 'id':
            return _resolve_id_value(value, loop_stack)
    return []


def scan_dynamic_tests_ids(path: Path):
    """AST-walk tests/dynamic_tests.py for record({"id": ...}) calls (direct dict literal,
    or a `rec = {...}` assignment later passed as `record(rec)`), resolving ids per
    _resolve_id_value's rules. See this module's docstring for the resolution scope/limits.
    """
    ids = set()
    try:
        tree = ast.parse(path.read_text(encoding='utf-8', errors='replace'))
    except (OSError, SyntaxError):
        return ids

    def walk_body(stmts, loop_stack, local_dicts):
        for stmt in stmts:
            if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Dict):
                for t in stmt.targets:
                    if isinstance(t, ast.Name):
                        local_dicts[t.id] = stmt.value
            elif isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call):
                call = stmt.value
                if isinstance(call.func, ast.Name) and call.func.id == 'record' and call.args:
                    arg = call.args[0]
                    if isinstance(arg, ast.Dict):
                        ids.update(_dict_id_values(arg, loop_stack))
                    elif isinstance(arg, ast.Name) and arg.id in local_dicts:
                        ids.update(_dict_id_values(local_dicts[arg.id], loop_stack))
            elif isinstance(stmt, ast.For):
                bindings = _for_loop_bindings(stmt, local_dicts)
                next_stack = loop_stack + [bindings] if bindings else loop_stack
                walk_body(stmt.body, next_stack, dict(local_dicts))
                walk_body(stmt.orelse, loop_stack, dict(local_dicts))
            elif isinstance(stmt, (ast.If, ast.While)):
                walk_body(stmt.body, loop_stack, local_dicts)
                walk_body(stmt.orelse, loop_stack, local_dicts)
            elif isinstance(stmt, ast.Try):
                walk_body(stmt.body, loop_stack, local_dicts)
                for handler in stmt.handlers:
                    walk_body(handler.body, loop_stack, local_dicts)
                walk_body(stmt.orelse, loop_stack, local_dicts)
                walk_body(stmt.finalbody, loop_stack, local_dicts)
            elif isinstance(stmt, ast.With):
                walk_body(stmt.body, loop_stack, local_dicts)
            elif isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
                walk_body(stmt.body, [], {})

    walk_body(tree.body, [], {})
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

    code_paths = (
        sorted((root / 'tests').glob('*.ps1'))
        + [root / 'run_setup.bat']
        + sorted((root / '.github' / 'workflows').glob('*.yml'))
        + sorted((root / '.github' / 'workflows').glob('*.yaml'))
    )
    code_paths = [p for p in code_paths if p.is_file()]
    code_ids = scan_code_ids(code_paths)

    dynamic_tests_path = root / 'tests' / 'dynamic_tests.py'
    if dynamic_tests_path.is_file():
        code_ids |= scan_dynamic_tests_ids(dynamic_tests_path)

    doc_only = sorted(doc_ids - code_ids)
    code_only = sorted(code_ids - doc_ids)

    print(f"Doc-registered IDs: {len(doc_ids)} ({len(doc_many_ids)} tagged '(x many)')")
    print(f"Code-emitted IDs (PowerShell + dynamic_tests.py AST scan): {len(code_ids)}")
    print()

    ok = True
    if doc_only:
        ok = False
        print(f"## Registered in docs but no matching code emission site found ({len(doc_only)})")
        print("(stale/removed row -- doc likely needs cleanup. Could also mean")
        print(" tests/dynamic_tests.py builds this id from something the AST resolver doesn't")
        print(" handle -- nested loops, a non-literal iterable, a function call -- see this")
        print(" module's docstring before assuming a real gap.)")
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
