"""runtime_module_scan (HP_RUNTIME_MODULE_SCAN) -- Item 65 slice 1.

Reads the stderr a run of the user's program left behind and prints, one per line, every module
it says is missing AND that this interpreter does not have. A program can exit 0 and still print
"ModuleNotFoundError: No module named 'x'" (a GUI callback's exception is caught and printed by the
toolkit), so the exit code alone never shows it.

Usage: runtime_module_scan.py <stderr-file>. Exit 0 always, even for an unreadable file (nothing is
reported then); 3 only for an unexpected internal error. Python 3.9 grammar only (see the embedded
helper baseline in docs/agent-lessons-learned.md); sys.stdlib_module_names is a feature guard.

Every name printed matches [A-Za-z_][A-Za-z0-9_]*, because the batch echoes it unquoted.
"""
import importlib.util
import re
import sys

_PAT = re.compile(r"(?:ModuleNotFoundError|ImportError): No module named ['\"]([^'\"\r\n]+)['\"]")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_CAP = 10


def _have(top):
    # Local modules count as present: this file sits in the app folder, so sys.path[0] finds them.
    try:
        return importlib.util.find_spec(top) is not None
    except (ImportError, ValueError, AttributeError):
        return True  # cannot tell, so say nothing


def missing(text):
    out = []
    stdlib = getattr(sys, "stdlib_module_names", ())
    for m in _PAT.finditer(text):
        top = m.group(1).split(".")[0]
        if top in out or top in stdlib or not _NAME.match(top) or _have(top):
            continue
        out.append(top)
        if len(out) == _CAP:
            break
    return out


def main(argv):
    try:
        with open(argv[1], "rb") as f:
            text = f.read().decode("utf-8", "replace")
    except (IndexError, OSError):
        return 0
    try:
        for name in missing(text):
            print(name)
    except Exception as exc:  # derived requirement: never break the bootstrap over a diagnostic
        print("runtime_module_scan: %s" % type(exc).__name__, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
