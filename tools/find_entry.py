"""find_entry (REQ-002) -- deterministic entry-point selector.

Run from the application directory; prints the chosen entry script (one line) to
stdout and diagnostic [BOOT] lines to stderr. Selection order:

  1. PREFERRED name match (main.py > app.py > run.py > cli.py).
  2. The sole .py file, when there is exactly one.
  3. The sole file containing a substantive `if __name__ == "__main__":` guard.
  4. Deterministic alphabetical fallback -- prefer files that declared a __main__
     guard, else any .py file -- so something always runs/builds rather than the
     entry resolving to empty (which silently skips run + packaging).

This is the canonical source for the HP_FIND_ENTRY base64 payload embedded in
run_setup.bat. After editing, re-encode and paste it into the `set "HP_FIND_ENTRY=..."`
line; tests/test_find_entry.py asserts the embedded payload matches this file.
"""
import ast
import os
import sys

PREFERRED = ("main.py", "app.py", "run.py", "cli.py")


def is_py(name):
    lower = name.lower()
    return lower.endswith(".py") and not lower.startswith("~") and os.path.isfile(name)


def _is_main_guard(test):
    """True if an If test is `__name__ == "__main__"` (either operand order)."""
    if not isinstance(test, ast.Compare) or len(test.ops) != 1:
        return False
    if not isinstance(test.ops[0], ast.Eq):
        return False
    names = set()
    consts = set()
    for side in (test.left, test.comparators[0]):
        if isinstance(side, ast.Name):
            names.add(side.id)
        elif isinstance(side, ast.Constant):
            consts.add(side.value)
    return "__name__" in names and "__main__" in consts


def _is_substantive(stmt):
    """A statement that does real work (not pass / docstring / bare ...)."""
    if isinstance(stmt, ast.Pass):
        return False
    if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant):
        return False
    return True


def has_main(path):
    """True if the file has an `if __name__ == "__main__":` guard that does real work.

    A guard whose body is exclusively pass/comments/docstring/`...` does not count
    (it self-identifies the module as non-runnable), so a sibling real entry wins.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as handle:
            src = handle.read()
    except Exception:
        return False
    try:
        tree = ast.parse(src)
    except Exception:
        # Unparseable source is a poor entry candidate; do not resurrect the old
        # substring heuristic (which mis-fired on "__main__" in strings/comments).
        return False
    # Only a module-level guard marks a runnable script; a guard nested inside a
    # function or class (e.g. a helper's `def run(): ... if __name__ == ...`) is not.
    for node in tree.body:
        if isinstance(node, ast.If) and _is_main_guard(node.test):
            if any(_is_substantive(stmt) for stmt in node.body):
                return True
    return False


def emit(path):
    print(os.path.normpath(path))


# Exit codes: 0 = a clear, unambiguous pick was emitted; AMBIGUOUS_RC (3) = the
# alphabetical fallback was used (multiple files, no clear winner) -- run_setup.bat
# reads this to decide whether to offer the interactive picker. stdout always holds
# the chosen entry regardless, so non-interactive callers are unaffected by the code.
AMBIGUOUS_RC = 3


def main():
    files = [name for name in os.listdir(".") if is_py(name)]

    if len(files) > 1:
        sys.stderr.write("[BOOT] REQ-002: Multiple scripts found: %r\n" % sorted(files))

    for candidate in PREFERRED:
        if candidate in files:
            if len(files) > 1:
                sys.stderr.write(
                    "[BOOT] REQ-002: Priority Logic Triggered: Found %r. "
                    "Selecting %r (REQ-002: Priority name match).\n"
                    % (sorted(files), candidate)
                )
            emit(candidate)
            return 0

    if len(files) == 1:
        emit(files[0])
        return 0

    candidates = [name for name in files if has_main(name)]
    if len(candidates) == 1:
        emit(candidates[0])
        return 0

    # Deterministic fallback (REQ-002): no PREFERRED name and not exactly one
    # substantive __main__ guard. Prefer files that declared a guard, else any file.
    # This ambiguous path exits AMBIGUOUS_RC so the batch may offer the interactive
    # picker before accepting this alphabetical default.
    pool = candidates if candidates else files
    if pool:
        choice = sorted(pool)[0]
        sys.stderr.write(
            "[BOOT] REQ-002: No clear entry found; selecting %r (alphabetical fallback).\n"
            % choice
        )
        emit(choice)
        return AMBIGUOUS_RC

    # No .py files at all -- the bootstrapper handles no-python-files separately.
    return 0


if __name__ == "__main__":
    sys.exit(main())
