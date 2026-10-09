"""pep723_extract (HP_PEP723_EXTRACT) -- extracts the dependencies of a PEP 723
inline script-metadata block, one dependency per line, to an output file.

Usage: python pep723_extract.py <entry.py> <output_path>

Exit codes:
  0 - dependencies written to the output file
  1 - nothing usable (no block, unterminated block, no dependencies key, or an
      empty list); a one-line reason is printed on stdout for the setup log
  3 - unexpected internal error (never confused with the benign exit 1)

Accepts the shapes real tools write, not just one hand-typed layout: CRLF or
LF, `#` followed by any amount of whitespace, single or double quoted items,
a trailing comma, a comment after an item, trailing whitespace on the fence
lines (astral-sh/uv#10918), and dependencies on one line or many. Only the
top-level `dependencies` key counts; a [tool.*] table ends the search.

Runs on any interpreter the bootstrapper may hold, so no tomllib and no
3.10+ syntax: the array walk is char-by-char, as in pyproj_deps.py.

Canonical source for the HP_PEP723_EXTRACT base64 payload embedded in
run_setup.bat; tests/test_pep723_extract.py asserts the payload matches.
"""
import re
import sys


def block_text(lines):
    """Return the TOML text of the first `script` block, or a reason string."""
    start = None
    for i, ln in enumerate(lines):
        if ln.rstrip() == '# /// script':
            start = i + 1
            break
    if start is None:
        return None, 'no "# /// script" line'
    end = None
    i = start
    while i < len(lines) and lines[i].startswith('#'):
        if lines[i].rstrip() == '# ///':
            end = i
        i += 1
    if end is None:
        return None, 'block has no closing "# ///" line'
    return '\n'.join(re.sub(r'^#[ \t]?', '', ln) for ln in lines[start:end]), None


def walk_array(rest):
    """Collect the quoted strings of a TOML array body, stopping at the closing ]."""
    deps = []
    i = 0
    while i < len(rest):
        c = rest[i]
        if c in ('"', "'"):
            q = c
            i += 1
            s = i
            while i < len(rest) and rest[i] != q:
                if q == '"' and rest[i] == '\\':
                    i += 1
                i += 1
            deps.append(rest[s:i].strip())
            i += 1
        elif c == '#':
            nl = rest.find('\n', i)
            if nl == -1:
                break
            i = nl + 1
        elif c == ']':
            break
        else:
            i += 1
    return [d for d in deps if d]


def extract(path):
    with open(path, encoding='utf-8-sig', errors='replace') as f:
        lines = f.read().splitlines()
    text, why = block_text(lines)
    if text is None:
        return [], why
    top = re.split(r'^[ \t]*\[', text, maxsplit=1, flags=re.MULTILINE)[0]
    m = re.search(r'^[ \t]*dependencies[ \t]*=[ \t]*\[', top, re.MULTILINE)
    if not m:
        return [], 'block has no top-level dependencies list'
    deps = walk_array(top[m.end():])
    if not deps:
        return [], 'dependencies list is empty'
    return deps, None


try:
    found, reason = extract(sys.argv[1])
    if not found:
        print('pep723_extract: no dependencies (%s)' % reason)
        sys.exit(1)
    with open(sys.argv[2], 'w', encoding='ascii', errors='replace') as out:
        out.write('\n'.join(found) + '\n')
    print('pep723_extract: %d dependencies' % len(found))
    sys.exit(0)
except Exception:
    sys.exit(3)
