"""Deterministic pipreqs entry point for run_setup.bat.

This script delegates to pipreqs.pipreqs.main with the locked flags
(--force --mode compat --savepath <path> target) so we avoid relying on the
__main__ module wrapper, which changed behaviour in pipreqs 0.5.0.
"""
from __future__ import annotations

import argparse
import sys
from typing import List

from pipreqs import pipreqs as pr


def build_argv(args: argparse.Namespace) -> List[str]:
    argv: List[str] = [
        "--force",
        "--mode",
        "compat",
        "--savepath",
        args.savepath,
    ]
    if args.ignore:
        argv.extend(["--ignore", args.ignore])
    argv.append(args.target)
    return argv


def main() -> int:
    parser = argparse.ArgumentParser(description="Run pipreqs with locked flags")
    parser.add_argument("target", nargs="?", default=".", help="Project root path")
    parser.add_argument("--savepath", required=True, help="Output requirements file")
    parser.add_argument("--ignore", help="Comma-separated ignore entries")
    ns = parser.parse_args()

    argv = build_argv(ns)
    try:
        pr.main(argv=argv)
    except SystemExit as exc:  # pragma: no cover - pipreqs terminates via SystemExit
        code = int(exc.code) if isinstance(exc.code, int) else 1
        return code
    return 0


if __name__ == "__main__":
    sys.exit(main())
