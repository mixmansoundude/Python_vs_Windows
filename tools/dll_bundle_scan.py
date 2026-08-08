"""dll_bundle_scan v1 (2026-08-04)
Conda native-DLL bundling repair loop's scan helper (CLAUDE.md Item 24 /
docs/prd-conda-native-dll-bundling.md). PyInstaller bundles a conda
extension's .pyd but not its native DLL dependency under conda's
Library\\bin convention (e.g. eccodes.dll for pygrib) -- announced at
build time:
  WARNING: Library not found: could not resolve 'eccodes.dll', dependency
  of '...\\pygrib\\_pygrib.cp314-win_amd64.pyd'.
Mirrors ~hidden_import_scan.py: reactive, bounded, double-gated (the named
DLL must also exist under Library\\bin, or nothing is emitted). General,
not hardcoded to eccodes.dll -- parses whatever name the warning gives.

Usage:
  --detect <log_file> <byte_offset>
    Provider-agnostic: prints the next unresolved DLL name, or nothing.
    No disk lookup -- lets a non-conda run log "detected, can't repair"
    instead of nothing.
  <log_file> <byte_offset> <conda_env_dir> [tried_file]
    Prints "<name>|<path>" (or nothing). tried_file (one "name|path" line
    per prior attempt) replaces argv tried-names to avoid cmd.exe
    metacharacter corruption from a DLL basename containing a space or &.
    Skips past a named-but-not-on-disk candidate to the next one.
byte_offset excludes an earlier build/run's own warnings already in the
same persistent log file.
"""
import os
import re
import sys

__version__ = "dll_bundle_scan v1 (2026-08-04)"
__all__ = ["locate_dll", "main", "next_dll_target", "read_tail", "read_tried_file"]

_PATTERN = re.compile(
    r"Library not found: could not resolve ['\"]([^'\"]+)['\"]"
)


def read_tail(log_file, offset):
    """Read log_file from byte offset onward; tolerant binary decode."""
    try:
        with open(log_file, "rb") as fh:
            fh.seek(max(0, offset))
            return fh.read().decode("utf-8", errors="ignore")
    except OSError:
        return ""


def next_dll_target(log_text, already_tried=()):
    """Return the next unresolved DLL basename from a build log slice, or ""."""
    tried = {t.lower() for t in already_tried}
    for match in _PATTERN.finditer(log_text):
        name = match.group(1).strip()
        if name and name.lower() not in tried:
            return name
    return ""


def locate_dll(name, conda_env_dir):
    """Search <conda_env_dir>\\Library\\bin (recursively) for name; return
    the first match's full path, or "" if not found. Recursive because a
    hook can place a DLL under a package-named subfolder rather than
    directly in Library\\bin (confirmed for hook-gribapi.py's own
    eccodes.dll placement, docs/prd-conda-native-dll-bundling.md Finding 1).
    """
    if not conda_env_dir:
        return ""
    lib_bin = os.path.join(conda_env_dir, "Library", "bin")
    if not os.path.isdir(lib_bin):
        return ""
    target = name.lower()
    for root, _dirs, files in os.walk(lib_bin):
        for fname in files:
            if fname.lower() == target:
                return os.path.join(root, fname)
    return ""


def read_tried_file(path):
    """Read already-tried DLL names (one "name|path" line each) from path.
    Missing/unreadable file -> no tried names (not an error)."""
    names = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    names.append(line.split("|", 1)[0])
    except OSError:
        pass
    return names


def _detect(args):
    """--detect mode: provider-agnostic, log-only. See module docstring."""
    if len(args) < 2:
        return
    log_file, offset_raw = args[0], args[1]
    try:
        offset = int(offset_raw)
    except ValueError:
        offset = 0
    text = read_tail(log_file, offset)
    if not text:
        return
    name = next_dll_target(text)
    if name:
        sys.stdout.write(name)


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        return
    if args[0] == "--detect":
        _detect(args[1:])
        return
    if len(args) < 3:
        return
    log_file, offset_raw, conda_env_dir = args[0], args[1], args[2]
    tried_file = args[3] if len(args) > 3 else None
    already = read_tried_file(tried_file) if tried_file else []
    try:
        offset = int(offset_raw)
    except ValueError:
        offset = 0
    text = read_tail(log_file, offset)
    if not text:
        return
    # Skip a stale/unrelated not-on-disk candidate; keep trying the rest.
    candidates = list(already)
    while True:
        name = next_dll_target(text, candidates)
        if not name:
            return
        path = locate_dll(name, conda_env_dir)
        if path:
            sys.stdout.write(name + "|" + path)
            return
        candidates.append(name)


if __name__ == "__main__":
    main()
