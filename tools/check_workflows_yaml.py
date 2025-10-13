"""Check GitHub workflow YAML files with PyYAML."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Iterable, Sequence

import yaml


def discover_workflows(root: Path) -> Sequence[Path]:
    patterns = ("*.yml", "*.yaml")
    files = {
        path
        for pattern in patterns
        for path in root.rglob(pattern)
    }
    return tuple(sorted(files, key=lambda candidate: candidate.as_posix()))


def load_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Parse GitHub workflow YAML files with PyYAML")
    parser.add_argument("--root", default=".github/workflows", help="Directory to scan for workflow files")
    parser.add_argument("--list", required=True, help="Path to write the discovered workflow file list")
    parser.add_argument("--log", required=True, help="Path to write PyYAML diagnostics")
    return parser.parse_args(list(argv))


def parse_workflows(files: Sequence[Path]) -> list[tuple[Path, Exception]]:
    failures: list[tuple[Path, Exception]] = []
    for path in files:
        try:
            with path.open("r", encoding="utf-8") as handle:
                list(yaml.safe_load_all(handle))
        except yaml.YAMLError as exc:
            failures.append((path, exc))
        except Exception as exc:  # derived requirement: surface unexpected parser failures
            failures.append((path, exc))
    return failures


def main(argv: Iterable[str] | None = None) -> int:
    args = load_args(sys.argv[1:] if argv is None else argv)

    root = Path(args.root)
    list_path = Path(args.list)
    log_path = Path(args.log)

    list_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    files = discover_workflows(root)

    with list_path.open("w", encoding="utf-8") as handle:
        for path in files:
            handle.write(f"{path.as_posix()}\n")

    log_path.write_text("", encoding="utf-8")

    if not files:
        print("No workflow files discovered under .github/workflows", file=sys.stderr)
        return 0

    failures = parse_workflows(files)

    if failures:
        with log_path.open("w", encoding="utf-8") as handle:
            for file_path, exc in failures:
                handle.write(f"{file_path.as_posix()}: {exc}\n")
        first_path, first_exc = failures[0]
        print(f"{first_path.as_posix()}: {first_exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
