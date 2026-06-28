"""hidden_import_scan v1 (2026-06-28)
Decide the next --hidden-import target from a frozen EXE's stderr, for the
Slice 2 auto-recovery loop in run_setup.bat.

STRICT and DOUBLE-GATED on purpose:
  (1) The EXE stderr must contain `ModuleNotFoundError: No module named 'X'`.
      That is the deterministic "X's code is not in the bundle" signal --
      PyInstaller left X out, and `--hidden-import=X` is the exact structural fix.
  (2) X (its top-level package) must be importable in the BUILD interpreter
      (find_spec). If X is not installed, this is a user typo or a genuinely
      missing dependency -- NOT a packaging miss -- so we emit nothing and let
      the post-flight hints surface the stack trace. This is what makes a typo
      like `import nonexistant` cost ZERO rebuilds.
  (3) X must not already be in the already-tried list (no loops).
  (4) X must not be a platform/stdlib shim legitimately absent on Windows.

Deliberately NOT handled: `ImportError: cannot import name 'Y' from 'Z'`. Z is
already bundled and Y is an attribute, not a module, so no --hidden-import
target is derivable and a rebuild cannot fix it. Such errors are user code
(typos, circular imports, version drift) or dynamic-submodule gaps better fixed
by --collect-submodules (handled separately). They route to hints unchanged.

Usage: python ~hidden_import_scan.py <stderr_file> [already_tried ...]
Prints the next hidden-import module name (or nothing) to stdout.
"""
__version__ = "hidden_import_scan v1 (2026-06-28)"
__all__ = ["SKIP", "next_hidden_import", "main"]

import importlib.util
import re
import sys

# Platform/stdlib modules legitimately absent on Windows -- never a packaging
# miss, so never hidden-import them (mirror of the parse_warn unix-only set).
SKIP = frozenset([
    "grp", "pwd", "posix", "resource", "fcntl", "readline", "termios", "tty",
    "pty", "crypt", "spwd", "nis", "syslog", "ossaudiodev",
    "_posixsubprocess", "_scproxy", "_frozen_importlib_external",
])

# Only ModuleNotFoundError -- NOT a bare ImportError (see module docstring).
_PATTERN = re.compile(
    r"ModuleNotFoundError: No module named ['\"]([^'\"]+)['\"]"
)


def _is_installed(name):
    """True if name is importable in the current (build) interpreter."""
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError, AttributeError):
        return False


def next_hidden_import(stderr_text, already_tried=(), installed_check=None):
    """Return the next --hidden-import module name, or "" if none is fixable.

    installed_check is injectable for testing so the find_spec gate can be
    exercised without installing packages. It is called with the TOP-LEVEL
    package name (not the dotted submodule) to avoid importing the parent
    package's side effects during detection.
    """
    if installed_check is None:
        installed_check = _is_installed
    tried = set(already_tried)
    for match in _PATTERN.finditer(stderr_text):
        mod = match.group(1).strip()
        if not mod or mod in tried:
            continue
        top = mod.split(".")[0]
        if top in SKIP or mod in SKIP or top.startswith("_"):
            continue
        # Gate (2): the top-level package must be installed in the build interp.
        # We emit the FULL dotted name as the hidden-import target but gate on
        # the top-level package so detection never imports a heavy submodule.
        if installed_check(top):
            return mod
    return ""


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        return
    stderr_file = args[0]
    already = args[1:]
    try:
        with open(stderr_file, "r", encoding="utf-8", errors="ignore") as fh:
            text = fh.read()
    except OSError:
        return
    sys.stdout.write(next_hidden_import(text, already))


if __name__ == "__main__":
    main()
