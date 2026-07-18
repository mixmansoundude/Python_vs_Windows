"""detect_visa (HP_DETECT_VISA) -- scans the project directory for
NI-VISA-instrument-control imports (pyvisa) to decide whether the REQ-008
NI-VISA driver install branch should run.

Run from the application directory; recursively walks the current directory
(skipping "~"/"."-prefixed subdirectories and files, matching this repo's
usual scratch-file convention) and prints "1" to stdout (no trailing
newline) if any scanned .py file's source matches a pyvisa-style import,
else "0".

Note: PATTERNS has no word-boundary anchor after "vis"/"pyvis", so an
unrelated import merely starting with those letters (e.g. "import pyvista",
a real, popular, unrelated 3D-visualization package) also matches -- a
known, pre-existing false-positive risk, not something this promotion pass
changes. See CLAUDE.md's Active Backlog for the tracked follow-up.

This is the canonical source for the HP_DETECT_VISA base64 payload embedded
in run_setup.bat. After editing, re-encode and paste it into the
`set "HP_DETECT_VISA=..."` line; tests/test_detect_visa.py asserts the
embedded payload matches this file.
"""
import os, re, sys

ROOT = os.getcwd()
PATTERNS = [
    r"(?m)^\s*(?:from\s+pyvis|import\s+pyvis)",
    r"(?m)^\s*import\s+vis",
]

def needs_visa():
    for current, dirs, files in os.walk(ROOT):
        dirs[:] = [item for item in dirs if not item.startswith(('~', '.'))]
        for name in files:
            if not name.endswith('.py') or name.startswith('~'):
                continue
            path = os.path.join(current, name)
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as handle:
                    text = handle.read()
            except OSError:
                continue
            for pattern in PATTERNS:
                if re.search(pattern, text):
                    return True
    return False

def main():
    sys.stdout.write('1' if needs_visa() else '0')

if __name__ == '__main__':
    main()
