"""dll_bundle_scan v1 (2026-08-04)
Decide the next --add-binary target for the conda native-DLL bundling repair
loop in run_setup.bat (CLAUDE.md Active Backlog Item 24 /
docs/prd-conda-native-dll-bundling.md).

PyInstaller's static analysis can trace an extension module's own compiled
.pyd but not that .pyd's own native DLL dependency when the DLL lives outside
the package's own directory tree -- conda's shared Library\\bin convention
(e.g. eccodes.dll for pygrib). PyInstaller already announces this at BUILD
time, no need to wait for the guaranteed runtime crash:

    WARNING: Library not found: could not resolve 'eccodes.dll', dependency
    of '...\\pygrib\\_pygrib.cp314-win_amd64.pyd'.

Mirrors ~hidden_import_scan.py's shape and gating philosophy (see
docs/agent-lessons-learned.md's "--hidden-import auto-recovery must stay
STRICT"): reactive (acts only on a real build-time warning, never proactive),
bounded (the caller enforces the iteration cap and tried-list, same as the
hidden-import loop), and double-gated -- the named DLL must ALSO actually
exist somewhere under the conda env's own Library\\bin tree, or nothing is
emitted. A name mentioned in a stale/unrelated warning that isn't really on
disk is not something --add-binary could fix; emitting it anyway would just
fail the rebuild for no reason.

General by design (CLAUDE.md Item 24 / docs/open-questions.md item 1): this
does not hardcode "eccodes.dll" -- it parses whatever DLL name PyInstaller's
own warning names, so the same loop covers any future conda-forge package
hitting the identical PyInstaller gap without its own dedicated fix.

Usage: python ~dll_bundle_scan.py <log_file> <byte_offset> <conda_env_dir> [already_tried ...]
Prints "<dll_name>|<resolved_path>" (or nothing) to stdout. byte_offset is
where to start scanning from (the log file's size before the build under
examination ran), so a DLL warning from an earlier build/run already present
in the same persistent log is never re-detected.
"""
import os
import re
import sys

__version__ = "dll_bundle_scan v1 (2026-08-04)"
__all__ = ["next_dll_target", "locate_dll", "read_tail", "main"]

_PATTERN = re.compile(
    r"Library not found: could not resolve ['\"]([^'\"]+)['\"]"
)


def read_tail(log_file, offset):
    """Read log_file from byte offset onward. Binary read + tolerant decode
    so an offset landing mid-multibyte-char (should not happen for this
    repo's ASCII-only log convention, but not assumed) never raises."""
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
    """Search <conda_env_dir>\\Library\\bin (recursively) for name; return the
    first match's full path, or "" if not found. Recursive because a hook can
    place a DLL under a package-named subfolder of Library\\bin rather than
    directly in it (confirmed for hook-gribapi.py's own Windows-aware
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


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 3:
        return
    log_file, offset_raw, conda_env_dir = args[0], args[1], args[2]
    already = args[3:]
    try:
        offset = int(offset_raw)
    except ValueError:
        offset = 0
    text = read_tail(log_file, offset)
    if not text:
        return
    name = next_dll_target(text, already)
    if not name:
        return
    path = locate_dll(name, conda_env_dir)
    if not path:
        return
    sys.stdout.write(name + "|" + path)


if __name__ == "__main__":
    main()
