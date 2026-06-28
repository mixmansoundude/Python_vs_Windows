"""collect_submodules v1 (2026-06-27)
Pre-build PyInstaller flag generator for packages that load submodules
dynamically (plugin/backend/registry systems) which PyInstaller's static
analysis cannot trace. Such packages produce NO warn-file entry (the import
itself resolves), so warnfix never sees them; the frozen EXE then fails at
runtime when it reaches the un-bundled submodule.

Emits one space-separated line of `--collect-submodules=PKG` flags to stdout.

DOUBLE-GATE (deliberate -- see derived requirement below): a flag is emitted
only when PKG is BOTH
  (1) imported by the user's project source ("used"), AND
  (2) importable in the build interpreter ("installed", via find_spec).
Gating on "installed" alone would bundle hundreds of MB of an unused library
into every EXE merely because it happens to sit in a fat global/conda env
(a 5-line hello-world should stay lean). Gating on "used" alone could pass a
flag for a package that is imported but not actually installed, which makes
PyInstaller error out. Requiring both keeps lean apps lean and avoids spurious
flags.

The curated set uses IMPORT names (sklearn, not scikit-learn) because
--collect-submodules takes the importable module name, and matching the import
name against project source avoids the package-vs-import naming mismatch.

Usage: python ~collect_submodules.py [project_root]   (default: cwd)
"""
__version__ = "collect_submodules v1 (2026-06-27)"
__all__ = ["DYNAMIC_PKGS", "imported_top_levels", "collect_flags", "main"]

import ast
import importlib.util
import os
import re
import sys

# Curated set of packages whose submodules are loaded via dynamic dispatch
# (estimator registries, backend plugins, compiled-extension submodules) that
# PyInstaller's static tracer misses. Import-name == --collect-submodules target.
# Conservative on purpose: heavy ML stacks (torch/tensorflow/transformers) are
# excluded -- collecting their submodules bloats the EXE by gigabytes and those
# users typically supply explicit deps.
DYNAMIC_PKGS = ("sklearn", "matplotlib", "scipy", "plotly")

# Directories never part of the user's application source.
_SKIP_DIRS = frozenset([
    "dist", "build", "__pycache__", "node_modules",
])


def _skip_dir(name):
    """True if a directory should not be walked for user source."""
    if name.startswith(".") or name.startswith("~"):
        return True
    return name in _SKIP_DIRS


def _regex_top_levels(text):
    """Fallback import scan for a single file that failed to AST-parse.

    Matches only import statements at line start (after optional whitespace),
    with a word boundary so 'import scipython' does not match 'scipy'.
    """
    found = set()
    for pkg in DYNAMIC_PKGS:
        pattern = r"(?m)^\s*(?:import|from)\s+" + re.escape(pkg) + r"\b"
        if re.search(pattern, text):
            found.add(pkg)
    return found


def _file_top_levels(text):
    """Return the set of top-level imported module names in one source file.

    Uses AST (so commented-out or string-literal 'imports' do not count). On a
    SyntaxError in the user's code, falls back to a conservative regex scan of
    the same text so a single un-parseable file does not blind the whole scan.
    """
    found = set()
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError):
        return _regex_top_levels(text)
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name:
                    found.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            # level > 0 is a relative import (from . import x) -- the module is
            # local to the project, never one of the curated third-party pkgs.
            if node.level == 0 and node.module:
                found.add(node.module.split(".")[0])
    return found


def imported_top_levels(root):
    """Walk the project tree and return the set of top-level imported modules."""
    found = set()
    for current, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not _skip_dir(d)]
        for name in files:
            if not name.endswith(".py") or name.startswith("~"):
                continue
            path = os.path.join(current, name)
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as handle:
                    text = handle.read()
            except OSError:
                continue
            found |= _file_top_levels(text)
    return found


def _is_installed(name):
    """True if name is importable in the current (build) interpreter."""
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError, AttributeError):
        # find_spec can raise for namespace/partial packages; treat as absent.
        return False


def collect_flags(root, installed_check=None):
    """Return ordered --collect-submodules flags for used AND installed packages.

    installed_check is injectable for testing so the gating logic can be
    exercised without actually installing heavy packages.
    """
    if installed_check is None:
        installed_check = _is_installed
    used = imported_top_levels(root)
    flags = []
    for pkg in DYNAMIC_PKGS:
        if pkg in used and installed_check(pkg):
            flags.append("--collect-submodules=" + pkg)
    return flags


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    # Normalize to an absolute path so the walk is anchored regardless of the
    # caller's cwd / relative-path drift (defensive on Windows multi-drive paths).
    root = os.path.abspath(args[0] if args else ".")
    sys.stdout.write(" ".join(collect_flags(root)))


if __name__ == "__main__":
    main()
