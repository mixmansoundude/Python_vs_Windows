"""detect_visa (HP_DETECT_VISA) -- scans the project directory for
NI-VISA-instrument-control imports (pyvisa) to decide whether the REQ-008
NI-VISA driver install branch should run.

Run from the application directory; recursively walks the current directory
(skipping "~"/"."-prefixed subdirectories and files, matching this repo's
usual scratch-file convention) and prints one digit to stdout (no trailing
newline): "0" no scanned .py file matches a pyvisa-style import, "1" at
least one match sits in the folder next to run_setup.bat, "2" every match
sits below a subfolder (an archived older program, say). The batch asks
before installing the driver for "2" and installs without asking for "1"
(Item 78 slice 2, README REQ-008).

It also logs up to three matching files on stderr, which the batch appends
to the setup log, and writes the first one to ~visa.where for the prompt.
A path can hold characters cmd.exe treats as operators, so every path is
reduced to ASCII letters, digits and ". _ - space \\" before it is printed.

PATTERNS anchor on the full module name ("pyvisa"/"visa") with a trailing
\b, not a truncated "pyvis"/"vis" prefix -- this deliberately excludes an
unrelated import that merely STARTS with those letters (e.g. "import
pyvista", a real, popular, unrelated 3D-visualization package; "import
vision"; "import pyviscoelastic"). \b after the full word also allows a
dotted submodule import ("import pyvisa.constants") to still match, since
"." is a non-word character. Note: anchoring \b right after the truncated
"vis"/"pyvis" prefix (rather than the full word) would NOT work here -- \b
only matches at a word/non-word transition, and there is no such boundary
between "vis" and the "a" in "visa" (both are word characters), so a
"vis\b" pattern would fail to match the genuine "import visa" case.

This is the canonical source for the HP_DETECT_VISA base64 payload embedded
in run_setup.bat. After editing, re-encode and paste it into the
`set "HP_DETECT_VISA=..."` line; tests/test_detect_visa.py asserts the
embedded payload matches this file.
"""
import os, re, sys

ROOT = os.getcwd()
PATTERNS = [
    r"(?m)^\s*(?:from\s+pyvisa\b|import\s+pyvisa\b)",
    r"(?m)^\s*import\s+visa\b",
]

def safe(rel):
    rel = rel.replace(os.sep, '\\')
    return ''.join(c if (c.isascii() and (c.isalnum() or c in '._- \\')) else '_' for c in rel)[:100]

def matches():
    found = []
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
            if any(re.search(pattern, text) for pattern in PATTERNS):
                found.append((os.path.relpath(path, ROOT), current == ROOT))
                if len(found) == 3:
                    return found
    return found

def main():
    where = os.path.join(ROOT, '~visa.where')
    try:
        if os.path.exists(where):
            os.remove(where)
    except OSError:
        pass
    found = matches()
    for rel, top in found:
        sys.stderr.write('[VISA] pyvisa/visa import found in: %s (%s)\n' % (safe(rel), 'top folder' if top else 'subfolder'))
    if found:
        try:
            with open(where, 'w', encoding='ascii') as handle:
                handle.write(safe(found[0][0]) + '\n')
        except OSError:
            pass
    sys.stdout.write('0' if not found else ('1' if any(top for _, top in found) else '2'))

if __name__ == '__main__':
    main()
