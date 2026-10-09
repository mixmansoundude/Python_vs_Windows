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
Double-quoted items have their TOML escapes decoded (a marker like
python_version < \"3.10\" must reach pip unescaped); single-quoted items are
literal. An array with no closing bracket is rejected (exit 1), never partly used.

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


_ESC = {'b': '\b', 't': '\t', 'n': '\n', 'f': '\f', 'r': '\r', '"': '"', '\\': '\\'}


def unescape(s):
    """Decode TOML basic-string escapes; an unknown escape is left as written."""
    def one(m):
        g = m.group(1)
        if g[0] in 'uU' and len(g) > 1:
            try:
                return chr(int(g[1:], 16))
            except (ValueError, OverflowError):
                return m.group(0)
        return _ESC.get(g, m.group(0))
    return re.sub(r'\\(u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)', one, s)


def walk_array(rest):
    """Collect the quoted strings of a TOML array body; return (deps, closed).

    closed is False when the text ends before the closing ], so the caller can reject
    a truncated array instead of installing the items read so far.
    """
    deps = []
    closed = False
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
            item = rest[s:i]
            if q == '"':
                item = unescape(item)
            deps.append(item.strip())
            i += 1
        elif c == '#':
            nl = rest.find('\n', i)
            if nl == -1:
                break
            i = nl + 1
        elif c == ']':
            closed = True
            break
        else:
            i += 1
    return [d for d in deps if d], closed


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
    deps, closed = walk_array(top[m.end():])
    if not closed:
        return [], 'dependencies list has no closing "]"'
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
