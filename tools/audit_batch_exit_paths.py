#!/usr/bin/env python3
"""On-demand audit of run_setup.bat's label/call/goto/exit structure.

Not wired into CI -- run by hand when auditing a change that touches process
termination (new top-level `exit /b` site, a new consent gate, reworking the
:acquire_lock/:release_lock lock feature, etc). See docs/agent-interconnect.md
"Concurrent-instance lock (REQ-024) touches every exit path" for how this was
used and why its output must be read with the limitation below in mind.

What it does:
  1. Lists every `:label` definition and every `call :label` site, so you can
     see at a glance which labels are ever entered as a subroutine (`called`)
     versus only ever reached via `goto` (a continuation of the calling
     subroutine's own frame, NOT a separate re-entrant routine).
  2. Lists every `exit /b` site (including ones indented inside parenthesized
     if/else blocks) and reports which label block it lexically sits under
     plus whether that label is ever `call`ed anywhere in the file.

What it deliberately does NOT do (and why): it does not attempt a true
call-depth-0 control-flow proof. CMD.EXE's `exit /b` returns to the nearest
*active* call frame at runtime, which depends on the actual execution path
taken, not lexical label containment -- a label reached purely via `goto`
from inside an active `call`ed block still returns to that block's caller,
not the whole process. Proving this precisely requires a paren-balance-aware
CFG parser (to know where an `if (...) ( ... ) else ( ... )` block's false
branch resumes), which was assessed as disproportionate effort when this
tool was built. Treat "called=False" as "probably a goto-continuation of an
enclosing subroutine, verify by reading the surrounding code" -- not as
proof that the exit site terminates the whole process.
"""
import argparse
import re
import sys
from pathlib import Path

LABEL_RE = re.compile(r'^:([A-Za-z_][A-Za-z0-9_]*)\s*$')
CALL_RE = re.compile(r'call\s+:([A-Za-z_][A-Za-z0-9_]*)', re.IGNORECASE)
EXIT_RE = re.compile(r'^\s*exit /b')


def audit(path: Path):
    lines = path.read_text(encoding='utf-8', errors='ignore').splitlines()

    labels = {}
    for i, line in enumerate(lines, 1):
        m = LABEL_RE.match(line)
        if m:
            labels[m.group(1)] = i

    called_labels = set()
    for line in lines:
        for m in CALL_RE.finditer(line):
            called_labels.add(m.group(1))

    exit_lines = [i for i, line in enumerate(lines, 1) if EXIT_RE.match(line)]

    sorted_labels = sorted(labels.items(), key=lambda kv: kv[1])

    def containing_label(exit_lineno):
        containing = None
        for name, lineno in sorted_labels:
            if lineno <= exit_lineno:
                containing = (name, lineno)
            else:
                break
        return containing

    return labels, called_labels, exit_lines, containing_label


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--file', default='run_setup.bat', help='Path to the batch file to audit (default: run_setup.bat)')
    parser.add_argument('--uncalled-only', action='store_true', help='Only print exit /b sites whose containing label is never call\'d anywhere')
    args = parser.parse_args()

    path = Path(args.file)
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 2

    labels, called_labels, exit_lines, containing_label = audit(path)

    print(f"Total labels: {len(labels)}")
    print(f"Labels ever reached via 'call :label': {len(called_labels)}")
    print(f"Total 'exit /b' sites (including indented/parenthesized): {len(exit_lines)}")
    print()
    print("NOTE: called=False does not prove process-termination -- see module docstring.")
    print()

    lines = path.read_text(encoding='utf-8', errors='ignore').splitlines()
    for ln in exit_lines:
        lbl = containing_label(ln)
        if lbl:
            name, lblline = lbl
            is_called = name in called_labels
            if args.uncalled_only and is_called:
                continue
            print(f"line {ln}: in :{name} (label@{lblline}) called={is_called}  -- {lines[ln - 1].strip()}")
        else:
            if args.uncalled_only:
                print(f"line {ln}: NO CONTAINING LABEL (before first label)  -- {lines[ln - 1].strip()}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
