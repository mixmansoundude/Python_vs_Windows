#!/usr/bin/env python3
"""Simple delimiter and quote balance checker."""
from __future__ import annotations

import argparse
import pathlib
import re
from dataclasses import dataclass
from typing import Iterable, List, Optional, Sequence, Tuple


TARGET_SUFFIXES = {
    ".bat",
    ".cmd",
    ".ps1",
    ".py",
    ".yml",
    ".yaml",
    ".json",
}


@dataclass
class Issue:
    path: pathlib.Path
    line: int
    column: int
    message: str

    def format(self) -> str:
        return f"{self.path}:{self.line}:{self.column}: {self.message}"


@dataclass
class StackItem:
    char: str
    line: int
    column: int


class LineCursor:
    def __init__(self, line: str, number: int) -> None:
        self.line = line
        self.number = number
        self.index = 0

    def remaining(self) -> str:
        return self.line[self.index :]

    def advance(self, count: int = 1) -> None:
        self.index += count

    def current(self) -> Optional[str]:
        if self.index >= len(self.line):
            return None
        return self.line[self.index]

    def column(self) -> int:
        return self.index + 1


def sanitize_ps1_line(line: str) -> Tuple[str, List[int]]:
    """Strip comments/strings for heuristic scanning while tracking raw indexes."""

    sanitized: List[str] = []
    mapping: List[int] = []
    quote: Optional[str] = None
    i = 0
    length = len(line)
    while i < length:
        ch = line[i]
        if quote:
            if quote == '"' and ch == '`' and i + 1 < length:
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in {'"', "'"}:
            quote = ch
            i += 1
            continue
        if ch == '#':
            break
        sanitized.append(ch)
        mapping.append(i)
        i += 1
    return ("".join(sanitized), mapping)


def iter_files(paths: Sequence[pathlib.Path]) -> Iterable[pathlib.Path]:
    for path in paths:
        if path.is_file():
            if path.suffix.lower() in TARGET_SUFFIXES:
                yield path
        elif path.is_dir():
            for sub in path.rglob("*"):
                if sub.is_file() and sub.suffix.lower() in TARGET_SUFFIXES:
                    # Skip files inside .git folders.
                    if any(part.startswith(".git") for part in sub.parts):
                        continue
                    yield sub


def is_python_triple_quote(line: str, idx: int, quote: str) -> bool:
    segment = line[idx : idx + 3]
    return segment == quote * 3


def count_preceding(line: str, idx: int, char: str) -> int:
    count = 0
    j = idx - 1
    while j >= 0 and line[j] == char:
        count += 1
        j -= 1
    return count


def yaml_is_doubled_quote(line: str, idx: int, quote: str) -> bool:
    # For YAML single/double quoted scalars, repeated quotes escape themselves.
    return idx + 1 < len(line) and line[idx + 1] == quote


class DelimiterChecker:
    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        self.issues: List[Issue] = []
        self.stack: List[StackItem] = []
        self.string_state: Optional[Tuple[str, bool, int, int]] = None
        self.here_string: Optional[str] = None
        self.in_block_comment = False
        self.prev_ps1_backtick = False
        self.yaml_shell_by_indent: dict[int, str] = {}
        self.in_yaml_pwsh_block = False
        self.yaml_pwsh_block_indent = 0
        self.yaml_prev_pwsh_command = False

    def add_issue(self, line: int, column: int, message: str) -> None:
        self.issues.append(Issue(self.path, line, column, message))

    def push(self, char: str, line: int, column: int) -> None:
        self.stack.append(StackItem(char, line, column))

    def pop(self, expected: str, line: int, column: int, actual: str) -> None:
        if not self.stack:
            self.add_issue(line, column, f"Unexpected '{actual}' without matching opening")
            return
        last = self.stack.pop()
        if last.char != expected:
            self.add_issue(
                line,
                column,
                f"Mismatched '{actual}' (expected to close '{last.char}' from line {last.line}, column {last.column})",
            )

    def check(self) -> List[Issue]:
        try:
            text = self.path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = self.path.read_text(encoding="utf-8", errors="replace")

        lines = text.splitlines()
        lower_suffix = self.path.suffix.lower()
        if lower_suffix == ".ps1":
            bad = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*:")
            allow = re.compile(r"\$(?:script|global|local|private|env|using):", re.IGNORECASE)
            for match in bad.finditer(text):
                token = match.group(0)
                if allow.fullmatch(token):
                    continue
                prefix = text[: match.start()]
                line_no = prefix.count("\n") + 1
                last_newline = prefix.rfind("\n")
                column = match.start() + 1 if last_newline == -1 else match.start() - last_newline
                line_text = lines[line_no - 1] if line_no - 1 < len(lines) else ""
                stripped_line = line_text.lstrip()
                if stripped_line.startswith("#"):
                    continue
                comment_index = line_text.find("#")
                if comment_index != -1 and comment_index <= column - 1:
                    continue
                # derived requirement: catching `$var:` early prevents the Windows PowerShell parser
                # from treating it as a scoped lookup and crashing the gate pipeline again.
                self.add_issue(
                    line_no,
                    column,
                    f'PowerShell scoped variable token "{token}" (wrap with ${{...}} or use -f formatting)',
                )

        for line_no, raw_line in enumerate(lines, start=1):
            line = raw_line.rstrip("\n\r")

            if lower_suffix in {".yml", ".yaml"}:
                self._check_yaml_pwsh_block(line_no, line)

            if lower_suffix == ".ps1":
                self._check_ps1_boolean_operators(line_no, line)

            if self.here_string:
                terminator = self.here_string
                stripped_terminator = line.strip()
                if stripped_terminator.startswith(terminator):
                    remainder = stripped_terminator[len(terminator) :]
                    if not remainder or remainder[0].isspace() or remainder.startswith('-'):
                        self.here_string = None
                continue

            cursor = LineCursor(line, line_no)

            if self.in_block_comment:
                idx = line.find("#>")
                if idx == -1:
                    continue
                self.in_block_comment = False
                cursor.advance(idx + 2)

            stripped = line.lstrip()
            if lower_suffix in {".bat", ".cmd"}:
                upper = stripped.upper()
                if upper.startswith("REM ") or upper == "REM" or stripped.startswith("::"):
                    continue

            while True:
                ch = cursor.current()
                if ch is None:
                    break

                if self.string_state:
                    quote, triple, _, _ = self.string_state
                    if triple:
                        segment = cursor.remaining()
                        if segment.startswith(quote * 3):
                            self.string_state = None
                            cursor.advance(3)
                            continue
                        else:
                            cursor.advance()
                            continue
                    else:
                        escape = None
                        if lower_suffix in {".py", ".json"}:
                            escape = "\\"
                        elif lower_suffix in {".bat", ".cmd"}:
                            escape = "^"
                        elif lower_suffix == ".ps1" and quote == '"':
                            escape = "`"
                        if (
                            ch == quote
                            and lower_suffix in {".yml", ".yaml"}
                            and quote == "'"
                            and yaml_is_doubled_quote(line, cursor.index, "'")
                        ):
                            cursor.advance(2)
                            continue
                        if (
                            ch == quote
                            and lower_suffix == ".ps1"
                            and quote == "'"
                            and yaml_is_doubled_quote(line, cursor.index, "'")
                        ):
                            cursor.advance(2)
                            continue
                        if escape and count_preceding(line, cursor.index, escape) % 2 == 1:
                            cursor.advance()
                            continue
                        if ch == quote:
                            self.string_state = None
                            cursor.advance()
                            continue
                        cursor.advance()
                        continue

                # Not currently inside a string
                if lower_suffix in {".py", ".ps1", ".yml", ".yaml"} and ch == "#":
                    break

                if lower_suffix == ".ps1" and not self.in_block_comment:
                    segment = cursor.remaining()
                    if segment.startswith("<#"):
                        end = line.find("#>", cursor.index + 2)
                        if end == -1:
                            # Multiline comment: skip the remainder of this line
                            # and mark the parser as inside a block comment so
                            # subsequent lines get ignored until the terminator.
                            self.in_block_comment = True
                            break
                        # Comment closes on the same line; advance past the
                        # terminator so the rest of the line can be parsed.
                        cursor.advance(end - cursor.index + 2)
                        continue

                if lower_suffix == ".ps1":
                    trimmed = line.strip()
                    if trimmed.endswith("@\""):
                        self.here_string = '"@'
                        break
                    if trimmed.endswith("@'"):
                        self.here_string = "'@"
                        break

                if ch in "({[":
                    self.push(ch, line_no, cursor.column())
                    cursor.advance()
                    continue

                if ch in ")}]":
                    matching = {')': '(', ']': '[', '}': '{'}[ch]
                    self.pop(matching, line_no, cursor.column(), ch)
                    cursor.advance()
                    continue

                if ch in "'\"":
                    triple = False
                    if lower_suffix == ".py" and is_python_triple_quote(line, cursor.index, ch):
                        triple = True
                        self.string_state = (ch, True, line_no, cursor.column())
                        cursor.advance(3)
                        continue
                    self.string_state = (ch, False, line_no, cursor.column())
                    cursor.advance()
                    continue

                cursor.advance()

        if self.string_state:
            quote, triple, line_no, col = self.string_state
            kind = "triple" if triple else "string"
            self.add_issue(line_no, col, f"Unterminated {kind} starting with {quote!r}")

        if self.here_string:
            self.add_issue(len(lines), max(1, len(lines[-1]) if lines else 1), f"Unterminated here-string expecting {self.here_string}")

        if self.stack:
            for item in self.stack:
                self.add_issue(item.line, item.column, f"Unclosed '{item.char}'")

        return self.issues

    def _check_ps1_boolean_operators(self, line_no: int, line: str) -> None:
        # derived requirement: Windows runners surfaced "parameter name 'or'" faults whenever -or/-and sat
        # outside a boolean expression. These heuristics stay intentionally simple per the latest CI spec.
        if self.here_string or self.in_block_comment:
            self.prev_ps1_backtick = False
            return

        sanitized, index_map = sanitize_ps1_line(line)
        trimmed = sanitized.strip()
        if not trimmed:
            self.prev_ps1_backtick = False
            return

        sanitized_lower = sanitized.lower()
        trimmed_lower = trimmed.lower()
        keyword_re = re.compile(r"\b(if|elseif|while|for|switch|return|until)\b", re.IGNORECASE)
        assignment_re = re.compile(r"(?<![-!<>])=")
        flagged: set[int] = set()

        def note_issue(op: str, sanitized_index: int, detail: str) -> None:
            if sanitized_index < 0 or sanitized_index >= len(index_map):
                return
            raw_index = index_map[sanitized_index]
            if raw_index in flagged:
                return
            flagged.add(raw_index)
            self.add_issue(
                line_no,
                raw_index + 1,
                f"PowerShell boolean operator '{op}' {detail}; wrap it inside an explicit conditional expression.",
            )

        if trimmed_lower.startswith("-or") or trimmed_lower.startswith("-and"):
            op = "-or" if trimmed_lower.startswith("-or") else "-and"
            idx = sanitized_lower.find(op)
            if idx != -1:
                detail = "cannot begin a statement"
                if self.prev_ps1_backtick:
                    detail = "cannot follow a line ending with '`'; add parentheses around the condition"
                note_issue(op, idx, detail)

        has_assignment = bool(assignment_re.search(sanitized))
        has_control_keyword = bool(keyword_re.search(sanitized_lower))
        space_pattern = re.compile(r"\s-(or|and)\s", re.IGNORECASE)
        if not has_control_keyword and not has_assignment:
            for match in space_pattern.finditer(sanitized_lower):
                start_index = match.start()
                segment_before = sanitized[:start_index]
                if "{" in segment_before:
                    continue
                op = f"-{match.group(1).lower()}"
                note_issue(op, match.start() + 1, "appears without an enclosing if/elseif/while/for context")

        command_pattern = re.compile(r"-(or|and)\b", re.IGNORECASE)
        for match in command_pattern.finditer(sanitized_lower):
            op = f"-{match.group(1).lower()}"
            idx = match.start()
            if idx < 0 or idx >= len(index_map):
                continue
            before_segment = sanitized[:idx]
            stripped_before = before_segment.rstrip()
            if not stripped_before:
                continue

            if assignment_re.search(before_segment) or keyword_re.search(before_segment):
                continue

            command_before = False
            if "|" in stripped_before:
                command_before = True
            elif stripped_before.lstrip().startswith("&"):
                command_before = True
            else:
                tokens = stripped_before.split()
                if tokens:
                    last_token = tokens[-1]
                    if not last_token.endswith(")") and not last_token.startswith(("$", "!", "-", "{", "(", "[")):
                        if not keyword_re.search(last_token):
                            command_before = True

            if command_before:
                note_issue(op, idx, "appears after a command invocation; PowerShell treats it as a parameter")

        raw_trimmed = line.rstrip()
        self.prev_ps1_backtick = bool(trimmed) and raw_trimmed.endswith("`")

    def _check_yaml_pwsh_block(self, line_no: int, line: str) -> None:
        if self.here_string:
            return

        raw = line
        content_no_comment = raw.split("#", 1)[0]
        indent = len(raw) - len(raw.lstrip(" "))

        if self.in_yaml_pwsh_block:
            block_indent = self.yaml_pwsh_block_indent
            if indent <= block_indent and content_no_comment.strip():
                self.in_yaml_pwsh_block = False
                self.yaml_prev_pwsh_command = False
            else:
                self._inspect_yaml_pwsh_content(line_no, raw, content_no_comment)
                return

        for depth in list(self.yaml_shell_by_indent.keys()):
            if depth > indent:
                del self.yaml_shell_by_indent[depth]

        stripped = content_no_comment.strip()
        if not stripped:
            return

        shell_match = re.match(r"^(\s*)shell\s*:\s*([^\s]+)", content_no_comment, re.IGNORECASE)
        if shell_match:
            shell_indent = len(shell_match.group(1))
            shell_value = shell_match.group(2).strip().lower()
            self.yaml_shell_by_indent[shell_indent] = shell_value
            return

        run_match = re.match(r"^(\s*)run\s*:\s*\|[-+]?\s*$", content_no_comment, re.IGNORECASE)
        if run_match:
            run_indent = len(run_match.group(1))
            shell_value = self.yaml_shell_by_indent.get(run_indent, "")
            shell_value = shell_value.lower()
            if shell_value in {"pwsh", "powershell"}:
                self.in_yaml_pwsh_block = True
                self.yaml_pwsh_block_indent = run_indent
                self.yaml_prev_pwsh_command = False
            else:
                self.in_yaml_pwsh_block = False
                self.yaml_prev_pwsh_command = False
            return

    def _inspect_yaml_pwsh_content(self, line_no: int, raw: str, content_no_comment: str) -> None:
        block_indent = self.yaml_pwsh_block_indent
        segment = content_no_comment[block_indent + 1 :] if len(content_no_comment) > block_indent else ""
        trimmed = segment.lstrip()
        if not trimmed:
            self.yaml_prev_pwsh_command = False
            return

        lower = trimmed.lower()
        if lower.startswith("-or") or lower.startswith("-and"):
            op = "-or" if lower.startswith("-or") else "-and"
            op_start = raw.lower().find(op, block_indent)
            if op_start != -1:
                detail = "cannot begin a continued pwsh run line"
                if self.yaml_prev_pwsh_command:
                    detail = "cannot follow a command invocation on the previous line"
                self.add_issue(
                    line_no,
                    op_start + 1,
                    f"PowerShell boolean operator '{op}' {detail}; wrap it inside an explicit expression.",
                )
            self.yaml_prev_pwsh_command = False
            return

        if lower.endswith("-or") or lower.endswith("-and"):
            op = "-or" if lower.endswith("-or") else "-and"
            op_start = raw.lower().rfind(op)
            if op_start != -1:
                self.add_issue(
                    line_no,
                    op_start + 1,
                    f"PowerShell boolean operator '{op}' cannot terminate a pwsh run line; complete the expression before wrapping.",
                )

        begins_command = trimmed.startswith("&") or trimmed.startswith("./") or trimmed.startswith(".\\")
        self.yaml_prev_pwsh_command = begins_command


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Validate paired delimiters and quotes in text files.")
    parser.add_argument("paths", nargs="*", default=["."], help="Files or directories to scan")
    args = parser.parse_args(argv)

    base_paths = [pathlib.Path(p) for p in args.paths]
    issues: List[Issue] = []
    for file_path in iter_files(base_paths):
        checker = DelimiterChecker(file_path)
        issues.extend(checker.check())

    if issues:
        for issue in issues:
            print(issue.format())
        print(f"Found {len(issues)} delimiter issue(s).")
        return 1

    print("No delimiter issues found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
