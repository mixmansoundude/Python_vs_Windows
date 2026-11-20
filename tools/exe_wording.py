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
messages here (a one-line group that a redirect of standard output or a pipe follows is understood: its commands write there. A
redirect of standard error or input hides nothing, and the redirects of one command apply from left to right as in cmd.exe).
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
_SET_P = re.compile(r'\bset\s+/p\s+("?)[A-Za-z0-9_]+=', re.IGNORECASE)
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
# One redirect of a command: a pipe (not `||`), or `<`, `>` or `>>` with what it reads or writes, a file name (`target`) or `&n` for a
# handle (`dup`). The optional digit in front is the handle the redirect is about (`2>` is standard error; none means 0 for `<` and 1
# for `>`). Whether a digit in the middle of a command is a handle is not for this pattern to say, see _split_redirects.
_CLAUSE = re.compile(
    r'(?:(?P<pipe>\|)(?!\|)'
    r'|(?:(?P<handle>[0-9])(?=[<>]))?(?P<op><|>>?)(?:&(?P<dup>[0-9])|[ \t]*(?P<target>"[^"]*"|[^\s&|<>()]+)))'
)


def _caret_escaped(text, pos):
    """True when text[pos] is escaped by an odd run of carets in front of it (cmd.exe's parity rule)."""
    carets = 0
    i = pos - 1
    while i >= 0 and text[i] == "^":
        carets += 1
        i -= 1
    return carets % 2 == 1


def _group_end(text):
    """Index of the first `)` of the text that closes a group the text did not open, or -1. Quotes and carets protect parentheses."""
    depth = 0
    quoted = False
    for i, ch in enumerate(text):
        if ch == '"':
            quoted = not quoted
        elif quoted or ch not in "()" or _caret_escaped(text, i):
            continue
        elif ch == "(":
            depth += 1
        elif depth == 0:
            return i
        else:
            depth -= 1
    return -1


def _clause(match, handle=None):
    """(kind, stream, source) of a redirect that _CLAUSE matched; `handle` is the digit the caller found in front of it."""
    if match.group("pipe"):
        return ("pipe", None, None)
    if match.group("op") == "<":
        return ("in", None, None)
    stream = int(match.group("handle") or handle or 1)
    if match.group("dup"):
        return ("dup", stream, int(match.group("dup")))
    return ("file", stream, None)


def _hides_output(clauses):
    """True when the redirects, applied from left to right as cmd.exe does, leave what a command writes away from the console.

    Standard output is gone after `>file` or a pipe; `2>file` takes only standard error, and `<` is about standard input. `>&2` copies
    standard error as it is at that moment (the console, unless an earlier `2>` took it) and `2>&1` copies standard output, so
    `2>nul >&2` hides the text and `>&2 2>nul` does not."""
    gone = {1: False, 2: False}  # the stream no longer reaches the console
    for kind, stream, source in clauses:
        if kind == "pipe":
            gone[1] = True
        elif stream in gone and kind == "file":
            gone[stream] = True
        elif stream in gone and kind == "dup" and source in gone:
            gone[stream] = gone[source]
    return gone[1]


def _split_redirects(text):
    """(hidden, rest) of the text of one command: `rest` is the text without its redirects, `hidden` says whether they take standard
    output away from the console (see _hides_output).

    A redirect can stand anywhere in a command, in front of it too (`2>nul echo x`). Its handle is the digit in front of it when that
    digit starts a word: `echo Step 2> f.txt` redirects standard error and prints `Step`, while `echo Step2> f.txt` and the usual
    `echo %TIME%>>log` write their text to the file. Quotes and carets protect the characters that would start a redirect. A pipe ends
    the command: what follows it belongs to the next one."""
    clauses = []
    kept = []
    quoted = False
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == '"':
            quoted = not quoted
        elif not quoted and ch in "<>|" and not _caret_escaped(text, i):
            if text[i : i + 2] == "||":
                kept.extend("||")
                i += 2
                continue
            digit = None
            if ch != "|" and kept and kept[-1] in "0123456789" and (len(kept) == 1 or kept[-2] in " \t("):
                digit = kept[-1]
            match = _CLAUSE.match(text, i)
            if match:
                if digit is not None:
                    kept.pop()
                clauses.append(_clause(match, digit))
                if match.group("pipe"):
                    break
                i = match.end()
                continue
        kept.append(ch)
        i += 1
    return _hides_output(clauses), "".join(kept)


def _chain_hides(text, pos):
    """Whether the redirects that directly follow a group, from `pos` (right after its closing parenthesis), take its standard output
    away. The chain ends at the first thing that is not a redirect (`&`, `else`, the end of the line) and at a pipe."""
    clauses = []
    i = pos
    while True:
        while i < len(text) and text[i] in " \t":
            i += 1
        match = _CLAUSE.match(text, i)
        if not match:
            break
        clauses.append(_clause(match))
        i = match.end()
        if match.group("pipe"):
            break
    return _hides_output(clauses)


def _hidden_after(line, pos):
    """Whether the redirects after a log call or a tagged call (from `pos`, the end of its quoted text) hide it: those of its own
    command, up to `&`, `&&`, `||` or the parenthesis that closes its group, not those of the next branch or command."""
    tail = _statements(line[pos:])[0]
    end = _group_end(tail)
    return _split_redirects(tail if end < 0 else tail[:end])[0]


def _mask_redirected_groups(line):
    """The line with the inside of every parenthesised group blanked that a redirect of standard output or a pipe follows
    (`( ... ) > f.txt`).

    cmd.exe sends the output of EVERY command of such a group to the file or the pipe, so none of its echoes or log calls
    reaches the console, whichever command the redirect seems to stand next to. A group that only redirects standard error or input
    (`( ... ) 2>nul`) still prints. Quotes and caret-escaped parentheses are not group brackets. The group's own parentheses and the
    redirect stay, so the statements around it are read as before."""
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
            if _chain_hides(line, i + 1):
                masked[start + 1 : i] = " " * (i - start - 1)
    return "".join(masked)


def _prompt_span(line, start, quoted_form):
    """(text, end) of the prompt of the `set /p` whose `NAME=` ends at `start`; `end` is where the rest of the line goes on.

    `set /p "NAME=text"` ends at the closing quote. Unquoted, cmd hands the command the text up to the first `&`, `|`, `<` or
    `>` that no quote or caret protects, or up to a `)` that closes a group the text did not open, so `set /p A=Ready? & echo x`
    is a prompt and an echo. A caret in front of a character is dropped like in an echo."""
    if quoted_form:
        close = line.find('"', start)
        if close < 0:
            return line[start:], len(line)
        return line[start:close], close + 1
    quoted = False
    depth = 0
    end = len(line)
    for i in range(start, len(line)):
        ch = line[i]
        if ch == '"':
            quoted = not quoted
        elif quoted or _caret_escaped(line, i):
            continue
        elif ch in "&|<>":
            end = i
            break
        elif ch == "(":
            depth += 1
        elif ch == ")":
            if depth == 0:
                end = i
                break
            depth -= 1
    return re.sub(r"\^(.)", r"\1", line[start:end]), end


def _statements(line):
    """Split a line at the unquoted, unescaped `&`, `&&` and `||` that chain commands. The `&` of `>&2` or `<&3` is part of the
    redirect, which copies a handle, and chains nothing."""
    out = []
    quoted = False
    start = 0
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == '"':
            quoted = not quoted
        elif not quoted and not _caret_escaped(line, i):
            if ch == "&" and not (line[i - 1 : i] in ("<", ">") and not _caret_escaped(line, i - 1)):
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


def _echo_text(command):
    """The text of the console echo that `command` is (the part of a statement before the parenthesis that ends its group, see
    _group_end), or None when it is not one: another command, `echo off`, or an echo whose standard output goes to a file or a pipe.
    The redirects of standard error and input are not part of the text and do not stop the echo from printing."""
    hidden, command = _split_redirects(command)
    if hidden:
        return None
    m = _ECHO.match(command.strip())
    if not m:
        return None
    body = m.group(1)
    if body.strip().lower() in ("off", "on"):
        return None
    return body


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
                if _hidden_after(line, m.end()):
                    continue
                out.append((n, label, kind, _norm_quoted(m.group(1))))
        for m in _SET_P.finditer(line):
            found = True
            text, end = _prompt_span(line, m.end(), m.group(1) == '"')
            rest[m.start() : end] = " " * (end - m.start())
            text = _norm_quoted(text)
            if text:
                out.append((n, label, "prompt", text))
        for m in _CHOICE_M.finditer(line):
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
            # The parenthesis that closes the group ends the command. What follows it is the next branch of a one-line
            # `if (...) else (...)`, read as a statement of its own, or the redirects of the group, which hide the command
            # when they take standard output away (a group opened on this line was dealt with by _mask_redirected_groups).
            end = _group_end(command)
            tail = ""
            if end >= 0:
                command, tail = command[:end], command[end + 1 :]
            if _ELSE.match(tail):
                queue.insert(0, tail)
                pure = False
            elif _chain_hides(tail, 0):
                continue
            body = _echo_text(command)
            if body is None:
                continue
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
