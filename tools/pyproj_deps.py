"""pyproj_deps (HP_PYPROJ_DEPS) -- writes [project].dependencies of ./pyproject.toml, one per line.

Usage: python pyproj_deps.py [output_path]   (default ~requirements.pyproject.txt)
Exit codes: 0 written; 1 nothing usable (no file, no key, empty list); 2 malformed TOML (tomllib
raised, or without tomllib an unclosed [project header or dependencies array); 3 unexpected error,
kept apart from 1 so a real failure never looks like "nothing to do".

Uses tomllib when the interpreter has it (3.11+). Otherwise, or when tomllib finds no key, a
char-by-char walk reads the array: extras and multi-constraint specifiers stay intact, "#" comments
are skipped, TOML escapes in double-quoted items are decoded (same code as pep723_extract.py).
Why and what it must match: docs/plan-toml-reading-hygiene.md (tests/test_toml_oracle.py).

Canonical source of the HP_PYPROJ_DEPS payload in run_setup.bat; tests/test_pyproj_deps.py checks
that the payload matches this file. Keep it small: the payload line must stay under 8191 characters.
"""
import re, sys, pathlib

try:
    import tomllib
except ImportError:
    tomllib = None

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


out = sys.argv[1] if len(sys.argv) > 1 else '~requirements.pyproject.txt'
try:
    try:
        # derived requirement: no Path.exists() check -- Python 3.14 made it swallow a PermissionError,
        # which would turn a real failure (exit 3) into "not found" (exit 1).
        txt = pathlib.Path('pyproject.toml').read_text(encoding='utf-8', errors='replace')
    except FileNotFoundError:
        sys.exit(1)
    deps = None
    if tomllib:
        try:
            deps = tomllib.loads(txt).get('project', {}).get('dependencies')
        except Exception:
            sys.exit(2)
    if deps is None:
        m = re.search(r'^\[project\]', txt, re.MULTILINE)
        if not m:
            # derived requirement: without tomllib, "[project" with no closing bracket is still malformed.
            if re.search(r'^\[project\s*$', txt, re.MULTILINE):
                sys.exit(2)
            sys.exit(1)
        sec = txt[m.end():]
        stop = re.search(r'^\[', sec, re.MULTILINE)
        if stop:
            sec = sec[:stop.start()]
        dm = re.search(r'^\s*dependencies\s*=\s*\[', sec, re.MULTILINE)
        if not dm:
            sys.exit(1)
        rest = sec[dm.end():]
        deps = []
        closed = False
        i = 0
        while i < len(rest):
            c = rest[i]
            if c in ('"', "'"):
                q = c
                i += 1
                start = i
                while i < len(rest) and rest[i] != q:
                    if q == '"' and rest[i] == '\\':
                        i += 1
                    i += 1
                item = rest[start:i]
                deps.append(unescape(item) if q == '"' else item)
                i += 1
            elif c == '#':
                # A comment may hold a "]" (the array's end is the first unquoted one outside comments).
                nl = rest.find('\n', i)
                if nl == -1:
                    break
                i = nl + 1
            elif c == ']':
                closed = True
                break
            else:
                i += 1
        if not closed:
            sys.exit(2)
    if not deps:
        sys.exit(1)
    pathlib.Path(out).write_text('\n'.join(deps) + '\n', encoding='ascii', errors='replace')
    sys.exit(0)
except Exception:
    # SystemExit is not an Exception, so the deliberate exits above pass through.
    sys.exit(3)
