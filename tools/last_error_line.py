"""last_error_line (HP_LAST_ERROR_LINE) -- Item 82 slice 1.

Reads the stderr a run of the user's program left behind and writes its LAST non-blank line to a file,
indented two spaces, so the last-chance offer can show the user what the program ended with. The batch
file shows the file with `type`, which never parses its content, so printable ASCII is kept literally,
including < > & | % and ^ (an error message is only useful if it reads as the program wrote it). Anything
else, controls and non-ASCII alike, becomes ?, and a line over 200 characters is cut with ... at the end.

Usage: last_error_line.py <stderr-file> <out-file>. Exit 0 = a line was written, 1 = nothing to show (file
missing, empty or only blank lines; no out file is left), 3 = unexpected internal error. Only the last
64 KB of the file is read. Python 3.9 grammar only (see the embedded helper baseline in
docs/agent-lessons-learned.md).
"""
import sys

_TAIL = 65536
_MAX = 200


def clean(raw):
    text = raw.decode("utf-8", "replace")
    out = []
    for ch in text:
        out.append(ch if " " <= ch <= "~" else "?")
    return "".join(out)


def last_line(path):
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - _TAIL))
        data = f.read()
    for line in reversed(data.splitlines()):
        if line.strip():
            text = clean(line).rstrip()
            if len(text) > _MAX:
                text = text[: _MAX - 3] + "..."
            return text
    return ""


def main(argv):
    try:
        text = last_line(argv[1])
        if not text:
            return 1
        with open(argv[2], "wb") as f:
            f.write(("  " + text + "\r\n").encode("ascii"))
        return 0
    except (OSError, IndexError):
        return 1
    except Exception as exc:  # derived requirement: never break the bootstrap over a diagnostic
        print("last_error_line: %s" % type(exc).__name__, file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
