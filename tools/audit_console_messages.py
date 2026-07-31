#!/usr/bin/env python3
"""On-demand audit of run_setup.bat's console-visible messages vs. the demo doc.

Not wired into CI -- run by hand when re-reviewing docs/demo-bootstrapper-output.md
for completeness (see that file's own "living demo report" header) or after a batch
of new `echo`/`call :log` lines have landed in run_setup.bat.

What it does:
  1. Extracts every `echo <text>` and `call :log "<text>"` line from run_setup.bat
     (case-insensitively, tolerating a leading `@`; skipping blank/`echo off`/
     `echo on` control lines and lines redirected to a file with `>`/`>>` (caret-
     escaped redirects and `>=` inside message text are not treated as redirects),
     which never reach the live console) and normalizes `%VAR%`, `%~dp0`/`%~1`/`%*`-
     style positional parameters, and `%%M`-style for-loop variables to a single
     placeholder so lines differing only by runtime substitution match.
  2. Splits each normalized message on its placeholder tokens and checks whether
     every resulting literal segment (length >= 6, to skip noise) appears anywhere
     in the demo doc's text -- a heuristic substring match, not a semantic one.
  3. Separately buckets messages that are test-only scaffolding (matched by
     `HP_TEST`, `[TEST]`, `simulating`, `injected`/`injecting`, or `corrupt_conda`/
     `corrupt_uv` in the text) -- these never reach a real user (see CLAUDE.md's
     "Env-var flags are scaffolding" rule, REQ-019) and are out of the demo doc's
     stated scope by design, not a documentation gap.

What it deliberately does NOT do (and why): it does not attempt semantic or
paraphrase matching, and it does not distinguish a genuinely undocumented feature
from a scenario that narrates the same event with different exact wording (the
demo doc's own stated scope is "representative captures," not an exhaustive
line-by-line transcript). Treat "not found" as "worth a 30-second manual look,"
not as proof of a real gap -- when this tool was built, roughly half its
"not found" hits turned out to already be covered by nearby prose in an existing
scenario. Only act on a hit after confirming the surrounding scenario doesn't
already narrate it.
"""
import argparse
import re
import sys
from pathlib import Path

TEST_ONLY_RE = re.compile(
    r'HP_TEST|\[TEST\]|simulating|inject(ed|ing)|corrupt_conda|corrupt_uv',
    re.IGNORECASE,
)

# A real redirect operator: one or two literal '>' not preceded by a caret escape (a caret
# protects an INNER command's own redirect, e.g. the `2^>nul` on a nested `powershell -Command`
# call, from being read as this line's own redirect) and not immediately followed by '=' (so a
# genuine console message containing '>=' -- e.g. "running (>=30 days since last update)" --
# is never mistaken for a redirect).
REDIRECT_RE = re.compile(r'(?<!\^)>{1,2}(?!=)')


def normalize(text: str) -> str:
    # %%VAR / %%~zS -style for-loop variable references -- must run before the single-percent
    # patterns below, since %% would otherwise look like an empty %...% pair to them.
    text = re.sub(r'%%~?[A-Za-z][A-Za-z0-9]*', '<V>', text)
    # %~dp0 / %~1 / %~nx1 -style positional/modified batch parameters, bare %1-%9, and %*
    # (all positional arguments).
    text = re.sub(r'%~[A-Za-z$:]*[0-9]', '<V>', text)
    text = re.sub(r'%[0-9]\b', '<V>', text)
    text = re.sub(r'%\*', '<V>', text)
    # %VAR% environment variable references. Requires no whitespace inside the delimiters (real
    # batch variable names never contain spaces) so a literal, isolated '%' earlier in the same
    # line (e.g. "10% free on %DRIVE%") can't be greedily treated as this pattern's opening
    # delimiter and swallow the literal text up to the next real '%'.
    text = re.sub(r'%[^%\s]+%', '<V>', text)
    return re.sub(r'\s+', ' ', text).strip()


def extract_records(bat_path: Path):
    """Return a list of (line_no, normalized_text) for console-visible lines."""
    records = []
    for i, raw in enumerate(bat_path.read_text(encoding='ascii', errors='replace').splitlines(), 1):
        line = raw.strip().lstrip('@')
        m = re.match(r'^echo\s+(.*)$', line, re.IGNORECASE)
        if m:
            body = m.group(1)
            if body.strip().lower() in ('.', 'off', 'on'):
                continue
            # `echo`'s body is unquoted plain text, so a trailing redirect (`> file`, `>> file`)
            # is indistinguishable from message content by position alone -- scan the whole raw
            # line. No current echo message contains a real (non-'>=', non-caret-escaped) '>',
            # confirmed by a full-file sweep at the time this check was added.
            if REDIRECT_RE.search(raw):
                continue
            records.append((i, normalize(body)))
            continue
        m = re.search(r'call :log\s+["\']([^"\']*)["\']', line, re.IGNORECASE)
        if m:
            # call :log's message is quote-delimited, so only the text AFTER the closing quote
            # can be a real redirect -- this correctly leaves a message that itself contains
            # '>=' (e.g. "running (>=30 days since last update)") untouched, since that '>=' is
            # inside the matched group, never scanned here.
            if REDIRECT_RE.search(line[m.end():]):
                continue
            records.append((i, normalize(m.group(1))))
    return records


def is_covered(normalized: str, corpus: str) -> bool:
    segments = [seg.strip() for seg in normalized.split('<V>') if len(seg.strip()) >= 6]
    if not segments:
        stripped = normalized.replace('<V>', '').strip()
        return len(stripped) < 6 or stripped in corpus
    return all(seg in corpus for seg in segments)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--file', default='run_setup.bat', help='Batch file to scan (default: run_setup.bat)')
    parser.add_argument('--demo-doc', default='docs/demo-bootstrapper-output.md',
                         help='Demo doc to check coverage against (default: docs/demo-bootstrapper-output.md)')
    parser.add_argument('--include-test-only', action='store_true',
                         help='Also report gaps in HP_TEST-gated / simulated lines (excluded by default, see module docstring)')
    args = parser.parse_args(argv)

    bat_path = Path(args.file)
    doc_path = Path(args.demo_doc)
    if not bat_path.is_file():
        print(f"error: {bat_path} not found", file=sys.stderr)
        return 2
    if not doc_path.is_file():
        print(f"error: {doc_path} not found", file=sys.stderr)
        return 2

    try:
        records = extract_records(bat_path)
        corpus = doc_path.read_text(encoding='utf-8', errors='replace')
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    missing = []
    test_only_missing = []
    for lineno, normalized in records:
        if is_covered(normalized, corpus):
            continue
        if TEST_ONLY_RE.search(normalized):
            test_only_missing.append((lineno, normalized))
        else:
            missing.append((lineno, normalized))

    print(f"Total console-visible records scanned: {len(records)}")
    print(f"Test-only scaffolding, not found (excluded by default, real users never see these): {len(test_only_missing)}")
    print(f"Real-user-facing, not found (worth a manual look): {len(missing)}")
    print()
    for lineno, normalized in missing:
        print(f"line {lineno}: {normalized}")
    if args.include_test_only:
        print()
        print("--- test-only scaffolding, not found ---")
        for lineno, normalized in test_only_missing:
            print(f"line {lineno}: {normalized}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
