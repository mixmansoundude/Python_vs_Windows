#!/usr/bin/env python3
"""Simple batch file linter.

Performs basic static analysis specific to Windows CMD batch syntax.  In addition
to unsafe ``echo`` patterns, the linter checks for the following problems:

* unmatched parentheses and percent expansions
* unclosed quotation marks
* improper ``for`` loop structure
* suspicious ``if`` syntax
* missing ``=`` on ``set`` commands
* references to nonexistent ``goto``/``call`` labels
"""
import re
import sys
from pathlib import Path


def lint(path: Path) -> int:
    lines = path.read_text(errors="ignore").splitlines()
    errors: list[tuple[int, str]] = []
    stack: list[int] = []
    labels: dict[str, int] = {}
    refs: list[tuple[int, str]] = []

    for lineno, raw in enumerate(lines, 1):
        line = raw
        stripped = line.lstrip()
        if stripped.startswith("REM") or stripped.startswith("::"):
            continue

        # label definition
        m = re.match(r":([A-Za-z0-9_.$?-]+)\b(.*)", stripped)
        if m:
            name = m.group(1).lower()
            if name in labels:
                errors.append((lineno, f"duplicate label :{name} (first at {labels[name]})"))
            else:
                labels[name] = lineno
            rest = m.group(2).lstrip()
            if not rest:
                continue
            line = rest
            stripped = line.lstrip()

        # check unsafe echo usage anywhere in the line
        low = line.lower()
        if "echo(" not in low:
            m = re.search(r"(?i)(?:^|[\s>&|])echo[ .]", line)
            if m:
                after = line[m.end():]
                if "%" in after:
                    errors.append((lineno, "use echo( for safe output"))

        # unescape caret escapes
        res = ""
        esc = False
        for ch in line:
            if esc:
                esc = False
            elif ch == "^":
                esc = True
                continue
            res += ch
        line_u = res

        # remove quoted segments and track unmatched quotes
        in_q = False
        prev = ""
        tmp = ""
        for ch in line_u:
            if ch == '"' and prev != "\\":
                in_q = not in_q
            elif not in_q:
                tmp += ch
            prev = ch
        if in_q:
            errors.append((lineno, 'unmatched "'))

        # check for/goto/if/set patterns within unquoted text
        tmp_low = tmp.lower()

        if tmp_low.startswith('for'):
            if '%%' not in tmp:
                errors.append((lineno, 'for loop variable must use %%'))
            if ' in ' not in tmp_low or ' do' not in tmp_low:
                errors.append((lineno, 'for loop missing IN or DO'))

        if tmp_low.startswith('if'):
            if not any(op in tmp_low for op in ['==', ' equ ', ' neq ', ' lss ',
                                               ' gtr ', ' leq ', ' geq ',
                                               ' exist ', ' defined ',
                                               ' errorlevel ']):
                errors.append((lineno, 'suspicious if syntax'))

        if line_u.lstrip().lower().startswith('set ') and not line_u.lstrip().lower().startswith('setlocal'):
            low_u = line_u.lower()
            if '=' not in line_u and '/p' not in low_u and '/a' not in low_u:
                errors.append((lineno, 'set without ='))

        mg = re.search(r"(?i)\bgoto\s+(:?\w+)", tmp)
        if mg:
            lbl = mg.group(1)
            if lbl.startswith(':'):
                lbl = lbl[1:]
            refs.append((lineno, lbl.lower()))

        mc = re.search(r"(?i)\bcall\s+(:[A-Za-z0-9_.$?-]+)", tmp)
        if mc:
            refs.append((lineno, mc.group(1)[1:].lower()))

        # core syntax checks: parentheses and percent expansions
        j = 0
        while j < len(tmp):
            ch = tmp[j]
            if ch == '(':
                seg = tmp[max(0, j - 5):j].lower()
                if not seg.endswith('echo'):
                    stack.append(lineno)
            elif ch == ')':
                if stack:
                    stack.pop()
                else:
                    errors.append((lineno, 'unmatched )'))
            elif ch == '%':
                if j + 1 < len(tmp) and tmp[j + 1] == '%':
                    j += 2
                    continue
                if j + 1 < len(tmp) and tmp[j + 1] in '*0123456789':
                    j += 2
                    continue
                if j + 1 < len(tmp) and tmp[j + 1] == '~':
                    k = j + 2
                    while k < len(tmp) and tmp[k].isalpha():
                        k += 1
                    if k < len(tmp) and tmp[k].isdigit():
                        j = k + 1
                        continue
                k = tmp.find('%', j + 1)
                if k == -1:
                    errors.append((lineno, 'unmatched %'))
                    break
                j = k + 1
                continue
            j += 1

    for ln in stack:
        errors.append((ln, 'unmatched ('))

    for ln, label in refs:
        if label not in labels and label.lower() != 'eof':
            errors.append((ln, f'unknown label :{label}'))

    for ln, msg in errors:
        print(f"{path}:{ln}: {msg}")
    return 1 if errors else 0


def main(argv):
    if len(argv) != 2:
        print("Usage: lint_batch.py <file.bat>")
        return 1
    return lint(Path(argv[1]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
