#!/usr/bin/env python3
"""REQ-007.20 wording ratchet for run_setup.bat's console messages (Item 123).

README REQ-007.20 [minor]: every message about the build, the verification or the failure of the executable names the
artifact and the tool in plain words ("EXE", "PyInstaller", "standalone .exe"), so that the user can tell the message is about
the optional one-file executable and not about the environment or the dependencies, which are already installed and usable.

Two checks share one set of rules (the constants below and tests/exe_wording_exempt.txt):

  check    Reads run_setup.bat. Every console message (`call :log "..."`, a tagged `call :sub "[TAG] ..."`, a block of
           consecutive `echo` lines, an inline `if ... echo`, a `set /p` or `choice /M` prompt) that talks about building,
           bundling, packaging or verifying (TRIGGER) must name the artifact or the tool (PLAIN) or be listed in
           tests/exe_wording_exempt.txt with a category that says why it is about something else. A new message that fails
           this turns the unit test red (tests/test_exe_wording.py, inside self.pytest.unit) and names the line to add or
           the wording to change. Entries that no longer match a message, or that the message does not need, are also
           reported, so the list can only shrink or be re-decided on purpose.
  console  Reads the text of a real run (the console log of a bootstrap) and judges every timestamped log line the same
           way, so a message that is built at run time, or printed by a helper, is held to the rule too. Used by
           tests/selfapps_sysbuild_accept.ps1.

What it does not see (a stated limit, not a promise): text printed by a PowerShell or Python helper, `type` of a file, and a
message assembled from variables alone. The console check covers those only for the run it is given. It reads one line at a time,
so the echo lines of a group that spans several lines and is redirected on its closing line (`( ... ) > file`) count as console
messages here (a one-line group that a redirect or a pipe follows is understood).
"""
import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_BAT = REPO / "run_setup.bat"
DEFAULT_RULES = REPO / "tests" / "exe_wording_exempt.txt"

# A message is about the build, the verification or the failure of the executable when it says so. "package" alone is the noun
# of the dependency messages ("package installation", "the package list"), so only the verb counts: it is followed by what it
# packages (`package your app`, `package up`) and no determiner stands in front of it ("the package your program needs").
TRIGGER = re.compile(
    r"\bbuild(?:s|ing)?\b|\bbuilt\b|\brebuil\w*|\bpackag(?:ing|ed)\b|\bbundl(?:e|es|ed|ing)\b"
    r"|\bsmoke\b|\bverif(?:y|ies|ied|ication|ying)\b"
    r"|(?<!\bthe )(?<!\ba )(?<!\ban )(?<!\bthat )(?<!\bwhich )(?<!\beach )(?<!\bevery )(?<!\bany )(?<!\bno )(?<!\bone )"
    r"\bpackage\s+(?:up\b|(?:your|my|our|this|these)\b)",
    re.IGNORECASE,
)
# ... and it names the artifact or the tool in plain words when it holds one of these.
PLAIN = re.compile(r"\bEXE\b|\.exe\b|executable|PyInstaller|Nuitka|standalone", re.IGNORECASE)
# A variable whose value is the path of the EXE names it as well (the user sees dist\<name>.exe).
PLAIN_VARS = ("HP_FAST_EXE_PATH",)
# Phrases that hold a trigger word without being about the build.
STRIP = re.compile(r"Visual Studio Build Tools", re.IGNORECASE)
# Not shown to a user on the default path: tagged diagnostics and the text of test and super-user hooks.
HIDDEN_TAG = re.compile(r"^\[(?:DEBUG|TRACE|INSTALL|TEST)\]")
HOOK = re.compile(r"HP_TEST_|HP_SKIP_")

_LABEL = re.compile(r"^:([A-Za-z0-9_]+)\s*$")
_REM = re.compile(r"^(?:rem\b|::)", re.IGNORECASE)
_LOG = re.compile(r'\bcall\s+:log\s+"([^"]*)"', re.IGNORECASE)
_TAGGED_CALL = re.compile(r'\bcall\s+:(?!log\b)[A-Za-z0-9_]+\s+"(\[[A-Z][A-Z_]*\][^"]*)"', re.IGNORECASE)
_SET_P = re.compile(r'\bset\s+/p\s+"?[A-Za-z0-9_]+=([^"]*)"?', re.IGNORECASE)
_CHOICE_M = re.compile(r'\bchoice\b[^"\n]*?/M\s+"([^"]*)"', re.IGNORECASE)
_ECHO = re.compile(r"^@?echo(?:\.|\s+)(.*)$", re.IGNORECASE)
_HEAD = re.compile(r"^(?:[()\s@]|else\b)+", re.IGNORECASE)
_IF = re.compile(
    r"""^if\s+(?:/i\s+)?(?:not\s+)?(?:
        defined\s+\S+
        |exist\s+(?:"[^"]*"|\S+)
        |errorlevel\s+\d+
        |(?:"[^"]*"|[^\s=]+)\s*(?:==|\s(?:equ|neq|lss|leq|gtr|geq)\s)\s*(?:"[^"]*"|\S+)
    )\s*""",
    re.IGNORECASE | re.VERBOSE,
)
_FOR = re.compile(r"^for\s+.*?\bdo\s+", re.IGNORECASE)
_ELSE = re.compile(r"^[\s)]*else\b", re.IGNORECASE)
_TIME = re.compile(r"\b\d{1,2}:\d{2}:\d{2}[.,]\d{2}\]?\s+(.*)$")
_PLACEHOLDER = re.compile(r"%%~?[A-Za-z][A-Za-z0-9]*|%~[A-Za-z$:]*[0-9]|%[0-9]\b|%\*|%[^%\s]+%")
# What can follow the closing parenthesis of a group to send its output away: `>`, `>>`, `<`, `2>`, `2>&1` or a pipe (not `||`).
_REDIRECT_AFTER = re.compile(r"\s*(?:\d?[<>]|\|(?!\|))")


def _caret_escaped(text, pos):
    """True when text[pos] is escaped by an odd run of carets in front of it (cmd.exe's parity rule)."""
    carets = 0
    i = pos - 1
    while i >= 0 and text[i] == "^":
        carets += 1
        i -= 1
    return carets % 2 == 1


def _has_redirect(text):
    """True when the text holds an unquoted, unescaped `>`, `<` or `|` (the statement writes a file or feeds a pipe)."""
    quoted = False
    for i, ch in enumerate(text):
        if ch == '"':
            quoted = not quoted
        elif not quoted and ch in "<>|" and not _caret_escaped(text, i):
            return True
    return False


def _mask_redirected_groups(line):
    """The line with the inside of every parenthesised group blanked that a redirect or a pipe follows (`( ... ) > f.txt`).

    cmd.exe sends the output of EVERY command of such a group to the file or the pipe, so none of its echoes or log calls
    reaches the console, whichever command the redirect seems to stand next to. Quotes and caret-escaped parentheses are not
    group brackets. The group's own parentheses and the redirect stay, so the statements around it are read as before."""
    masked = list(line)
    opened = []
    quoted = False
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif quoted or _caret_escaped(line, i):
            continue
        elif ch == "(":
            opened.append(i)
        elif ch == ")" and opened:
            start = opened.pop()
            if _REDIRECT_AFTER.match(line, i + 1):
                masked[start + 1 : i] = " " * (i - start - 1)
    return "".join(masked)


def _statements(line):
    """Split a line at the unquoted, unescaped `&`, `&&` and `||` that chain commands."""
    out = []
    quoted = False
    start = 0
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == '"':
            quoted = not quoted
        elif not quoted and not _caret_escaped(line, i):
            if ch == "&":
                out.append(line[start:i])
                i += 2 if line[i + 1 : i + 2] == "&" else 1
                start = i
                continue
            if ch == "|" and line[i + 1 : i + 2] == "|":
                out.append(line[start:i])
                i += 2
                start = i
                continue
        i += 1
    out.append(line[start:])
    return out


def _unwrap(stmt):
    """Strip the leading parentheses, `else`, `if` conditions and `for ... do` of a statement; what is left is the command."""
    rest = stmt.strip()
    while True:
        before = rest
        rest = _HEAD.sub("", rest)
        m = _IF.match(rest)
        if m:
            rest = rest[m.end():]
        else:
            m = _FOR.match(rest)
            if m:
                rest = rest[m.end():]
        if rest == before:
            return rest


def _echo_body(command):
    """(body, tail) of an `echo` command, or None when the command is not a console echo (control words, a redirect).

    A closing parenthesis that has no opening one ends the echo's group; a parenthesis escaped by a caret (`^)`) is text and
    ends nothing. `tail` is what follows it when that is another branch of a one-line `if (...) else (...)`, so the caller reads
    that branch as a statement of its own; a redirect after the parenthesis belongs to the group, so the echo writes a file and
    is not a console message."""
    m = _ECHO.match(command)
    if not m:
        return None
    body = m.group(1)
    if body.strip().lower() in ("off", "on"):
        return None
    tail = ""
    depth = 0
    for i, ch in enumerate(body):
        if ch not in "()" or _caret_escaped(body, i):
            continue
        if ch == "(":
            depth += 1
        elif depth == 0:
            tail = body[i + 1 :]
            body = body[:i]
            break
        else:
            depth -= 1
    if _has_redirect(body):
        return None
    if _ELSE.match(tail):
        return body, tail
    if _has_redirect(tail):
        return None
    return body, ""


def _norm_echo(text):
    text = re.sub(r"\^(.)", r"\1", text)
    text = re.sub(r"\*{3,}", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _norm_quoted(text):
    return re.sub(r"\s+", " ", text).strip()


def messages(bat_text):
    """The console messages of a batch file: a list of (line number, label, kind, text), kind log, echo or prompt."""
    out = []
    label = None
    block = None  # the open block of consecutive echo lines: [line, label, "echo", text]
    block_end = 0
    for n, raw in enumerate(bat_text.replace("\r\n", "\n").split("\n"), 1):
        line = raw.strip()
        m = _LABEL.match(line)
        if m:
            label = m.group(1)
            block = None
            continue
        if not line or _REM.match(line):
            block = None
            continue
        line = _mask_redirected_groups(line)
        rest = list(line)  # the line without the messages found below, so a command after a log call is read as well
        found = False
        for pattern, kind in ((_LOG, "log"), (_TAGGED_CALL, "log")):
            for m in pattern.finditer(line):
                found = True
                rest[m.start() : m.end()] = " " * (m.end() - m.start())
                if _has_redirect(_statements(line[m.end():])[0]):
                    continue
                out.append((n, label, kind, _norm_quoted(m.group(1))))
        for pattern in (_SET_P, _CHOICE_M):
            for m in pattern.finditer(line):
                found = True
                rest[m.start() : m.end()] = " " * (m.end() - m.start())
                text = _norm_quoted(m.group(1))
                if text:
                    out.append((n, label, "prompt", text))
        if found:
            block = None  # a log call or a prompt ends a block of echo lines
            line = "".join(rest).strip()
            if not line:
                continue
        statements = _statements(line)
        pure = len(statements) == 1 and _ECHO.match(line.lstrip("@ ")) is not None
        added = False
        queue = list(statements)
        while queue:
            command = _unwrap(queue.pop(0))
            found_echo = _echo_body(command)
            if found_echo is None:
                continue
            body, tail = found_echo
            if tail:
                queue.insert(0, tail)
                pure = False
            text = _norm_echo(body)
            if not text:
                continue
            added = True
            if pure and block is not None and block_end == n - 1 and block[1] == label:
                block[3] += " " + text
                block_end = n
            elif pure:
                block = [n, label, "echo", text]
                block_end = n
                out.append(block)
            else:
                out.append([n, label, "echo", text])
                block = None
        if pure and not added:
            block = None  # `echo.` ends a block
        elif not pure:
            block = None
    return [tuple(item) for item in out]


def console_visible(text):
    """False for messages a user does not see on the default path."""
    return not (HIDDEN_TAG.match(text) or HOOK.search(text))


def is_about_build(text):
    """The message talks about building, bundling, packaging or verifying."""
    return TRIGGER.search(STRIP.sub(" ", text)) is not None


def names_exe(text):
    """The message names the artifact or the tool in plain words."""
    if PLAIN.search(text):
        return True
    return any("%" + var + "%" in text for var in PLAIN_VARS)


class Rules(object):
    """The parsed tests/exe_wording_exempt.txt: category -> meaning, and (category, text, line) entries."""

    def __init__(self):
        self.categories = {}
        self.entries = []
        self.problems = []

    def exempt_texts(self):
        return {text: cat for cat, text, _ in self.entries}


def parse_rules(text):
    rules = Rules()
    seen = {}
    for n, raw in enumerate(text.replace("\r\n", "\n").split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("category:"):
            name, sep, meaning = line[len("category:"):].strip().partition(" | ")
            name = name.strip()
            if not sep or not name or not meaning.strip():
                rules.problems.append("line %d: a category line reads 'category: <name> | <why a message in it is not about the EXE>'" % n)
            elif name in rules.categories:
                rules.problems.append("line %d: category %r is defined twice" % (n, name))
            else:
                rules.categories[name] = meaning.strip()
            continue
        cat, sep, msg = line.partition(" | ")
        cat = cat.strip()
        msg = _norm_quoted(msg)
        if not sep or not cat or not msg:
            rules.problems.append("line %d: an entry reads '<category> | <message text as run_setup.bat writes it>'" % n)
            continue
        if msg in seen:
            rules.problems.append("line %d: the message is listed twice (first on line %d): %s" % (n, seen[msg], msg))
            continue
        seen[msg] = n
        rules.entries.append((cat, msg, n))
    for cat, msg, n in rules.entries:
        if cat not in rules.categories:
            rules.problems.append("line %d: category %r is not defined by a 'category:' line" % (n, cat))
    return rules


def classify(bat_text, rules):
    """(rows, problems). A row is (line, label, kind, text, status); status is quiet, named, exempt:<category> or violation."""
    exempt = rules.exempt_texts()
    rows = []
    for n, label, kind, text in messages(bat_text):
        if not console_visible(text):
            continue
        if not is_about_build(text):
            status = "quiet"
        elif names_exe(text):
            status = "named"
        elif text in exempt:
            status = "exempt:" + exempt[text]
        else:
            status = "violation"
        rows.append((n, label, kind, text, status))
    return rows


def check(bat_text, rules):
    """The problems of a batch file against the rules; an empty list means the ratchet holds."""
    problems = list(rules.problems)
    rows = classify(bat_text, rules)
    by_text = {}
    for n, label, kind, text, status in rows:
        by_text.setdefault(text, []).append(status)
    for n, label, kind, text, status in rows:
        if status == "violation":
            problems.append(
                "run_setup.bat line %d (%s): this message talks about building or verifying and does not name the EXE or the tool: %s\n"
                "    Reword it so that it holds EXE, executable, standalone, PyInstaller or Nuitka (README REQ-007.20) or, when it is "
                "about something else, add the line '<category> | %s' to tests/exe_wording_exempt.txt"
                % (n, label, text, text)
            )
    used = set(cat for cat, _, _ in rules.entries)
    for cat in sorted(rules.categories):
        if cat not in used:
            problems.append("tests/exe_wording_exempt.txt: the category %r has no entry, remove its 'category:' line" % cat)
    for cat, msg, n in rules.entries:
        statuses = by_text.get(msg)
        if not statuses:
            problems.append("tests/exe_wording_exempt.txt line %d: no console message of run_setup.bat reads this any more, remove or update it: %s" % (n, msg))
        elif not any(s.startswith("exempt:") for s in statuses):
            problems.append("tests/exe_wording_exempt.txt line %d: the message does not need an exemption (it %s), remove it: %s"
                            % (n, "names the EXE" if "named" in statuses else "is not about the build", msg))
    return problems


def _template_regex(text):
    """A regex for a message whose variables are filled in at run time."""
    parts = []
    pos = 0
    for m in _PLACEHOLDER.finditer(text):
        parts.append(re.escape(text[pos:m.start()]))
        parts.append(".*?")
        pos = m.end()
    parts.append(re.escape(text[pos:]))
    return re.compile("^" + "".join(parts) + "$")


def console_check(console_text, rules):
    """Judge the timestamped log lines of a real run. Returns (problems, stats)."""
    templates = [(cat, _template_regex(msg)) for cat, msg, _ in rules.entries]
    stats = {"lines": 0, "timestamped": 0, "triggered": 0, "named": 0, "exempt": 0, "violations": 0}
    problems = []
    for raw in console_text.replace("\r\n", "\n").split("\n"):
        stats["lines"] += 1
        m = _TIME.search(raw)
        if not m:
            continue
        stats["timestamped"] += 1
        text = _norm_quoted(m.group(1))
        if not text or not console_visible(text) or not is_about_build(text):
            continue
        stats["triggered"] += 1
        if names_exe(text):
            stats["named"] += 1
        elif any(rx.match(text) for _, rx in templates):
            stats["exempt"] += 1
        else:
            stats["violations"] += 1
            problems.append("console line talks about building or verifying and does not name the EXE or the tool: %s" % text)
    return problems, stats


def _read(path):
    return Path(path).read_bytes().decode("ascii", errors="replace")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("check", "list"):
        p = sub.add_parser(name)
        p.add_argument("--bat", default=str(DEFAULT_BAT))
        p.add_argument("--rules", default=str(DEFAULT_RULES))
    p = sub.add_parser("console")
    p.add_argument("--file", required=True)
    p.add_argument("--rules", default=str(DEFAULT_RULES))
    args = parser.parse_args(argv)
    try:
        rules = parse_rules(_read(args.rules))
        if args.command == "console":
            problems, stats = console_check(_read(args.file), rules)
            problems = list(rules.problems) + problems
            print(json.dumps({"ok": not problems, "stats": stats, "problems": problems}, sort_keys=True))
            return 0 if not problems else 1
        bat_text = _read(args.bat)
    except OSError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2
    if args.command == "list":
        for n, label, kind, text, status in classify(bat_text, rules):
            if status != "quiet":
                print("%5d  %-12s %-10s %s" % (n, status, label, text))
        return 0
    problems = check(bat_text, rules)
    for problem in problems:
        print(problem)
    print("exe_wording: %d problem(s)" % len(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
