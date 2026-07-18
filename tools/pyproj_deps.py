"""pyproj_deps (HP_PYPROJ_DEPS) -- extracts [project].dependencies from
pyproject.toml, writing one dependency per line to an output file.

Run from the application directory (reads "pyproject.toml" from CWD).
Usage: python pyproj_deps.py [output_path]  (default "~requirements.pyproject.txt")

Exit codes:
  0 - success, dependencies written to the output file
  1 - not-found/error (no pyproject.toml, no [project].dependencies key,
      or an empty dependencies list)
  2 - malformed TOML (tomllib raised, or -- when tomllib is unavailable --
      the regex fallback found an unclosed "[project" header)

Prefers stdlib tomllib (3.11+) when available. Falls back to a regex-based
extractor when tomllib is missing OR the [project] table has no
"dependencies" key via tomllib (the two cases are indistinguishable from
tomllib's own return value, so the fallback always re-scans in that case --
harmless, since a genuinely-absent key also finds nothing via regex). The
fallback's dependency-array walk is char-by-char over quoted strings (not a
naive comma/newline split) so it preserves extras ("pkg[all]") and
multi-constraint specifiers ("pkg>=4,<5") intact.

This is the canonical source for the HP_PYPROJ_DEPS base64 payload embedded
in run_setup.bat. After editing, re-encode and paste it into the
`set "HP_PYPROJ_DEPS=..."` line; tests/test_pyproj_deps.py asserts the
embedded payload matches this file.
"""
import sys, pathlib

try:
    import tomllib
except ImportError:
    tomllib = None

out = sys.argv[1] if len(sys.argv) > 1 else '~requirements.pyproject.txt'
try:
    txt = pathlib.Path('pyproject.toml').read_text(encoding='utf-8', errors='replace')
    deps = None
    if tomllib:
        try:
            data = tomllib.loads(txt)
            deps = data.get('project', {}).get('dependencies')
        except Exception:
            # Exit 2 signals caller to emit [WARN]: pyproject.toml is not valid TOML.
            sys.exit(2)
    if deps is None:
        import re
        m = re.search(r'^\[project\]', txt, re.MULTILINE)
        if not m:
            # derived requirement: without tomllib, detect obviously malformed [project header
            # (missing closing bracket -- e.g. "[project\n"). Exit 2 so caller emits TOML parse warning.
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
        # Walk char-by-char: collect only quoted strings; stop at unquoted ]
        # This preserves full dep strings including extras ([all]) and
        # multi-constraint specifiers (>=4,<5) without naive comma/newline splits.
        deps = []
        i = 0
        while i < len(rest):
            c = rest[i]
            if c in ('"', "'"):
                q = c
                i += 1
                start = i
                while i < len(rest) and rest[i] != q:
                    if rest[i] == '\\':
                        i += 1
                    i += 1
                deps.append(rest[start:i])
                i += 1
            elif c == ']':
                break
            else:
                i += 1
    if not deps:
        sys.exit(1)
    pathlib.Path(out).write_text('\n'.join(deps) + '\n', encoding='ascii', errors='replace')
    sys.exit(0)
except Exception:
    sys.exit(1)
