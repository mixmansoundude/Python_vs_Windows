"""autopep_merge (HP_AUTOPEP_MERGE) -- Tier 1 of docs/plan-autopep723-two-tier.md.

Merges the dependency names discovered by `uvx autopep723 check <entry>` (redirected to a
PEP-723-header-shaped output file) into requirements.txt, additively. Best-effort only: never
raises, never removes or reorders anything already in requirements.txt, and always exits 0 so
a caller can treat it as a diagnostic-only step (see run_setup.bat's REQ-005.12 call site --
autopep723 augments pipreqs's results, it never replaces or gates them).

Usage: python autopep_merge.py <autopep_output_file> <requirements_file>
  (both default to "requirements.autopep.txt" / "requirements.txt" for direct testing)

This is the canonical source for the HP_AUTOPEP_MERGE base64 payload embedded in run_setup.bat.
After editing, re-encode and paste it into the `set "HP_AUTOPEP_MERGE=..."` line;
tests/test_autopep_merge.py asserts the embedded payload matches this file.
"""
import os
import re
import sys

DEP_LINE_RE = re.compile(r'^#\s*"([^"]+)",?\s*$')
NAME_RE = re.compile(r'^\s*([A-Za-z0-9_.-]+)')


def extract_autopep_deps(path):
    """Pull quoted dependency names out of autopep723 check's PEP-723-style stdout capture."""
    if not os.path.exists(path):
        return []
    deps = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                match = DEP_LINE_RE.match(line.rstrip("\n"))
                if match:
                    deps.append(match.group(1).strip())
    except OSError:
        return []
    return deps


def existing_names(path):
    """Lowercased top-level package names already present in requirements.txt."""
    names = set()
    if not os.path.exists(path):
        return names
    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            match = NAME_RE.match(stripped)
            if match:
                names.add(match.group(1).lower())
    return names


def ensure_trailing_newline(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return
    with open(path, "rb") as handle:
        handle.seek(-1, os.SEEK_END)
        last = handle.read(1)
    if last not in (b"\n", b"\r"):
        with open(path, "a", encoding="ascii", newline="\n") as handle:
            handle.write("\n")


def main():
    autopep_path = sys.argv[1] if len(sys.argv) > 1 else "requirements.autopep.txt"
    reqs_path = sys.argv[2] if len(sys.argv) > 2 else "requirements.txt"

    autopep_deps = extract_autopep_deps(autopep_path)
    if not autopep_deps:
        sys.stdout.write("no-op: no autopep723 dependencies discovered\n")
        return 0

    current = existing_names(reqs_path)
    seen = set()
    additions = []
    for dep in autopep_deps:
        key = dep.lower()
        if key in current or key in seen:
            continue
        seen.add(key)
        additions.append(dep)

    if not additions:
        sys.stdout.write("no-op: all autopep723 dependencies already present\n")
        return 0

    ensure_trailing_newline(reqs_path)
    with open(reqs_path, "a", encoding="ascii", newline="\n") as handle:
        for dep in additions:
            handle.write(dep + "\n")
    sys.stdout.write("added: " + ",".join(additions) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
