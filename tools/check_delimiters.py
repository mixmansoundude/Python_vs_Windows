#!/usr/bin/env python3
"""Simple delimiter and quote balance checker."""
from __future__ import annotations

import argparse
import pathlib
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
        for line_no, raw_line in enumerate(lines, start=1):
            line = raw_line.rstrip("\n\r")

            if self.here_string:
                terminator = self.here_string
                if line.strip().startswith(terminator) and line.strip() == terminator:
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
            lower_suffix = self.path.suffix.lower()
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
                        self.in_block_comment = True
                        cursor.advance(2)
                        continue

                if lower_suffix == ".ps1":
                    trimmed = line.strip()
                    if trimmed.startswith("@\"") and trimmed == "@\"":
                        self.here_string = '"@'
                        break
                    if trimmed.startswith("@'") and trimmed == "@'":
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
