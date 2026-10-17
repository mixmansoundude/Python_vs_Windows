"""Reference reader for a PEP 723 script block, used as a test oracle (CLAUDE.md Item 79).

Reads the block with the regular expression the PEP itself publishes
(https://peps.python.org/pep-0723/, "Reference Implementation") and decodes it with
tomllib, so it shares no code with tools/pep723_extract.py, the helper under test.

Importable: reference_deps(text) returns the list of dependency strings, or None when
there is no block; it raises tomllib.TOMLDecodeError when the block is not valid TOML.

CLI (used by tests/selfapps_toml_uvcorpus.ps1, needs Python 3.11+ for tomllib):
  python toml_oracle_check.py <script.py> <extractor_output.txt>
prints one JSON line and exits 0 when the extractor's output lists exactly the
reference dependencies and the list is not empty, 1 otherwise.
"""
import json
import re
import sys
import tomllib

BLOCK_RE = r'(?m)^# /// (?P<type>[a-zA-Z0-9-]+)$\s(?P<content>(^#(| .*)$\s)+)^# ///$'


def reference_deps(text):
    """Dependencies of the first `script` block in text (LF newlines), or None."""
    found = [m for m in re.finditer(BLOCK_RE, text) if m.group('type') == 'script']
    if not found:
        return None
    content = ''.join(
        line[2:] if line.startswith('# ') else line[1:]
        for line in found[0].group('content').splitlines(keepends=True)
    )
    return list(tomllib.loads(content).get('dependencies', []))


def main(argv):
    with open(argv[1], encoding='utf-8', newline=None) as handle:
        text = handle.read()
    with open(argv[2], encoding='ascii', errors='replace') as handle:
        got = [ln for ln in handle.read().splitlines() if ln]
    want = reference_deps(text) or []
    result = {
        'referenceCount': len(want),
        'extractorCount': len(got),
        'match': got == want,
        'reference': want,
        'extractor': got,
    }
    print(json.dumps(result))
    return 0 if (got == want and want) else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
