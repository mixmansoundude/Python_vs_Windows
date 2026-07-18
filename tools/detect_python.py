"""detect_python (HP_DETECT_PY) -- REQ-004 Tier 1/2 requires-python detector.

Run from the application directory; prints a normalized conda-syntax
"python<op><ver>[,...]" constraint to stdout, or an empty line if neither
tier found anything (the caller then lets the selected provider pick the
latest available Python -- REQ-004 Tier 3, handled outside this helper).
Detection order:

  1. runtime.txt -- a bare "python-X.Y[.Z]" or "X.Y[.Z]" line pins an exact
     minor version (python=X.Y; the patch component, if present, is not
     forwarded -- providers pin by minor only).
  2. pyproject.toml's [project] requires-python -- a PEP 440 specifier
     (e.g. ">=3.10,<4", "~=3.11") is parsed and expanded into one or more
     conda-syntax clauses via pep440_to_conda().

pep440_to_conda() also doubles as a standalone CLI utility (see main()) for
translating arbitrary PEP 440 specifiers, including the "~=" compatible-release
operator, which conda has no native equivalent for and must be expanded into
an explicit >=/< range.

This is the canonical source for the HP_DETECT_PY base64 payload embedded in
run_setup.bat. After editing, re-encode and paste it into the
`set "HP_DETECT_PY=..."` line; tests/test_detect_python.py asserts the
embedded payload matches this file.
"""
__version__ = "detect_python v2 (2025-09-24)"
__all__ = ["pep440_to_conda", "detect_requires_python", "main"]
ORDER = {"==": 0, "!=": 1, ">=": 2, ">": 3, "<=": 4, "<": 5}

import os
import re
import sys

# Helper implements the README bootstrap contract. PEP 440 details:
# https://peps.python.org/pep-0440/

CD = os.getcwd()
RUNTIME_PATH = os.path.join(CD, "runtime.txt")
PYPROJECT_PATH = os.path.join(CD, "pyproject.toml")
PYPROJECT_RE = re.compile("requires-python\\s*=\\s*['\"]([^'\"]+)['\"]", re.IGNORECASE)
SPEC_PATTERN = re.compile(r'(~=|==|!=|>=|<=|>|<)\s*([0-9]+(?:\.[0-9]+)*)')


def version_key(text: str):
    """Return a tuple usable for numeric ordering of dotted versions."""
    parts = []
    for chunk in text.split('.'):
        try:
            parts.append(int(chunk))
        except ValueError:
            parts.append(0)
    return tuple(parts)


def bump_for_compatible(version: str) -> str:
    """Translate the PEP 440 compatible release upper bound."""
    pieces = [int(item) for item in version.split('.') if item.isdigit()]
    if not pieces:
        return version
    if len(pieces) >= 3:
        return f"{pieces[0]}.{pieces[1] + 1}"
    if len(pieces) == 2:
        return f"{pieces[0] + 1}.0"
    return str(pieces[0] + 1)


def expand_clause(op: str, version: str):
    if op == "~=":
        upper = bump_for_compatible(version)
        return [(">=", version), ("<", upper)]
    return [(op, version)]


def pep440_to_conda(spec: str) -> str:
    """Return "python" constraints expanded from a requires-python spec."""
    clauses = []
    for raw in spec.split(','):
        raw = raw.strip()
        if not raw:
            continue
        match = SPEC_PATTERN.match(raw)
        if not match:
            continue
        op, version = match.groups()
        clauses.extend(expand_clause(op, version))
    if not clauses:
        return ""
    dedup = {}
    for op, version in clauses:
        dedup[(op, version)] = (op, version)
    ordered = sorted(dedup.values(), key=lambda item: (ORDER.get(item[0], 99), version_key(item[1])))
    return "python" + ",".join(f"{op}{version}" for op, version in ordered)


def read_runtime_spec() -> str:
    if not os.path.exists(RUNTIME_PATH):
        return ""
    with open(RUNTIME_PATH, 'r', encoding='utf-8', errors='ignore') as handle:
        text = handle.read()
    match = re.search(r'(?:python[-=])?\s*([0-9]+(?:\.[0-9]+){0,2})', text)
    if not match:
        return ""
    parts = match.group(1).split('.')
    major_minor = '.'.join(parts[:2])
    return f'python={major_minor}'


def read_pyproject_spec() -> str:
    if not os.path.exists(PYPROJECT_PATH):
        return ""
    with open(PYPROJECT_PATH, 'r', encoding='utf-8', errors='ignore') as handle:
        text = handle.read()
    match = PYPROJECT_RE.search(text)
    if not match:
        return ""
    return pep440_to_conda(match.group(1))


def detect_requires_python() -> str:
    """Return best-effort requires-python constraint for the current project."""
    runtime_spec = read_runtime_spec()
    if runtime_spec:
        return runtime_spec
    return read_pyproject_spec()


def main(argv=None) -> None:
    """CLI entry point that prints normalized requires-python constraints."""
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] == "--self-test":
        for sample in ("~=3.10", "~=3.8.1"):
            sys.stdout.write(pep440_to_conda(sample) + "\n")

        return
    if args:
        for item in args:
            sys.stdout.write(pep440_to_conda(item) + "\n")

        return
    sys.stdout.write(detect_requires_python() + "\n")



if __name__ == "__main__":
    main()
