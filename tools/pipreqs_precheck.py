# ASCII only. Item 63: pipreqs 0.4.13 opens every .py with the locale encoding (cp1252 on Western
# Windows before Python 3.15) and aborts the whole scan on the first file it cannot decode or
# parse, so one stray U+201D in a regex line costs the project every import it has. Check each
# .py first. If all are clean UTF-8 the caller scans in place; otherwise write a UTF-8 copy of the
# tree for pipreqs to scan: re-encodable files are re-encoded, unreadable files become empty stubs
# (pipreqs treats any .py basename in the scanned tree as a local module, so the stub keeps the
# file's own module name out of the requirements while adding no imports).
# usage: pipreqs_precheck.py SRC STAGE IGNORE_CSV REPORT   exit 0 in place, 10 staged, 3 error
import ast, io, os, sys, tokenize, warnings

# Same directory names pipreqs 0.4.13 prunes on its own; IGNORE_CSV is the caller's --ignore list.
SKIP = {".hg", ".svn", ".git", ".tox", "__pycache__", "env", "venv"}
BOM = chr(0xFEFF)
MAX_WARN = 25
MAX_INFO = 100


def safe(text):
    return "".join(c if (c.isascii() and c.isalnum()) or c in " ._-~/\\" else "?" for c in text)


def check_file(path):
    """Return (state, text, encoding, why); state is ok, reenc (needs a UTF-8 rewrite) or bad."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return "bad", None, "", "cannot be read"
    try:
        text, enc = raw.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        try:
            enc = tokenize.detect_encoding(io.BytesIO(raw).readline)[0]
            text = raw.decode(enc)
        except (SyntaxError, UnicodeDecodeError, LookupError):
            return "bad", None, "", "not valid UTF-8 and no readable coding declaration"
    state = "ok"
    if enc != "utf-8":
        state = "reenc"
    elif text.startswith(BOM):
        # ast.parse rejects a leading BOM character, so pipreqs would too
        text, state, enc = text[1:], "reenc", "utf-8-bom"
    try:
        with warnings.catch_warnings():
            # Python 3.12+ warns on every invalid escape sequence while parsing; thousands of those
            # lines would drown the setup log, and pipreqs does not care.
            warnings.simplefilter("ignore")
            ast.parse(text)
    except (SyntaxError, ValueError, MemoryError, RecursionError) as exc:
        return "bad", None, "", "does not parse, " + type(exc).__name__
    return state, text, enc, ""


def main(src, stage, ignore_csv, report):
    skip = SKIP | set(x for x in ignore_csv.split(",") if x)
    found, dirs_seen, other = [], [], 0
    for root, dirs, files in os.walk(src, followlinks=True):
        dirs[:] = sorted(d for d in dirs if d not in skip)
        dirs_seen.append(os.path.relpath(root, src))
        for name in sorted(files):
            if os.path.splitext(name)[1] != ".py":
                other += 1
                continue
            rel = os.path.normpath(os.path.join(os.path.relpath(root, src), name))
            found.append((rel,) + check_file(os.path.join(root, name)))
    lines, left, listed, infos = [], 0, 0, 0
    for rel, state, text, enc, why in found:
        if state == "bad":
            left += 1
            if listed < MAX_WARN:
                listed += 1
                lines.append("[WARN] pipreqs pre-check: left out %s (%s); its imports are not scanned and the detected requirements may be incomplete." % (safe(rel), why))
        elif infos < MAX_INFO:
            infos += 1
            lines.append("[INFO] pipreqs pre-check: %s encoding=%s parsed=yes" % (safe(rel), enc))
    if left > listed:
        lines.append("[WARN] pipreqs pre-check: %d more file(s) left out, not listed here." % (left - listed))
    staged = sum(1 for f in found if f[1] == "reenc")
    lines.append("[INFO] pipreqs pre-check: %d .py file(s), %d re-encoded as UTF-8, %d left out, %d other file(s) not scanned." % (len(found), staged, left, other))
    code = 10 if staged or left else 0
    if code:
        for rel_dir in dirs_seen:
            os.makedirs(os.path.join(stage, rel_dir), exist_ok=True)
        for rel, state, text, enc, why in found:
            with open(os.path.join(stage, rel), "wb") as out:
                if state == "reenc":
                    out.write(text.encode("utf-8"))
                elif state == "ok":
                    with open(os.path.join(src, rel), "rb") as fh:
                        out.write(fh.read())
    with open(report, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return code


if __name__ == "__main__":
    try:
        sys.exit(main(*sys.argv[1:5]))
    except Exception as exc:
        sys.stderr.write("pipreqs_precheck failed: %s\n" % type(exc).__name__)
        sys.exit(3)
