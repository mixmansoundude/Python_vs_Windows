"""preflight_check (HP_PREFLIGHT_CHECK) -- REQ-021 static syntax check of the entry file.

Usage: python preflight_check.py <entry.py>

Exit codes:
  0 - the entry file's syntax is valid
  1 - the entry file has a syntax error; the interpreter's own message goes to stderr
  3 - the check could not decide (unreadable file, wrong arguments, internal error); the
      caller logs a warning and carries on, so a broken check never blocks a valid program

Why not `python -m py_compile`: py_compile writes a .pyc into __pycache__ next to the entry.
It exits 1 for a perfectly valid file when it cannot write there (a read-only __pycache__,
or a FILE named __pycache__), which the bootstrapper then reported as a syntax error that
was not there (Item 83), and when it can write it leaves the .pyc behind in the user's
folder (REQ-021.5). compile() uses the same parser and writes nothing. The check executes
none of the user's code.

Runs on any interpreter the bootstrapper may hold, so no 3.10+ syntax.

Canonical source for the HP_PREFLIGHT_CHECK base64 payload embedded in run_setup.bat;
tests/test_preflight_check.py asserts the payload matches.
"""
import sys
import traceback
import warnings

try:
    if len(sys.argv) != 2:
        sys.exit(3)
    with open(sys.argv[1], 'rb') as f:
        data = f.read()
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            compile(data, sys.argv[1], 'exec', dont_inherit=True)
    except (SyntaxError, ValueError) as exc:
        # SyntaxError covers IndentationError, TabError and bad encodings; ValueError is the
        # null-byte case on interpreters before 3.12. Both make the file unrunnable.
        sys.stderr.write(''.join(traceback.format_exception_only(type(exc), exc)))
        sys.exit(1)
    sys.exit(0)
except SystemExit:
    raise
except Exception:
    # Exception, not BaseException: Ctrl+C (KeyboardInterrupt) must stop the check, not turn into exit 3.
    sys.exit(3)
