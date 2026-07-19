"""dep_check v1 (2026-03-27)
Compares requirements.auto.txt (pipreqs output) against ~environment.lock.txt
(conda list --export snapshot). Prints 'skip' when every package detected by
pipreqs is already present in the lock; prints 'run' otherwise so the caller
proceeds with conda install.

This is the canonical source for the HP_DEP_CHECK base64 payload embedded in
run_setup.bat. After editing, re-encode and paste it into the
`set "HP_DEP_CHECK=..."` line; tests/test_dep_check.py asserts the embedded
payload matches this file.
"""
__version__ = "dep_check v1 (2026-03-27)"
__all__ = ["parse_lock", "parse_reqs", "main"]

import os
import re
import sys

REQ_FILE = "requirements.auto.txt"
LOCK_FILE = "~environment.lock.txt"


def parse_lock(path):
    """Return frozenset of lowercase package names from conda list --export."""
    names = set()
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # conda list --export: name=version=build[=channel]
                name = line.split("=")[0].strip().lower()
                if name:
                    names.add(name)
    except OSError:
        pass
    return frozenset(names)


def parse_reqs(path):
    """Return list of lowercase package names from pip-style requirements file."""
    names = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # Strip version specifier: numpy>=1.20 -> numpy
                name = re.split(r"[>=<!~,;\s\[]", line, maxsplit=1)[0].strip().lower()
                if name:
                    names.append(name)
    except OSError:
        pass
    return names


def main():
    if not os.path.exists(LOCK_FILE):
        sys.stdout.write("run\n")
        return
    if not os.path.exists(REQ_FILE):
        # No pipreqs output; nothing requires installation
        sys.stdout.write("skip\n")
        return
    lock_names = parse_lock(LOCK_FILE)
    if not lock_names:
        sys.stdout.write("run\n")
        return
    req_names = parse_reqs(REQ_FILE)
    if not req_names:
        # Empty requirements file; conda install would be a no-op
        sys.stdout.write("skip\n")
        return
    missing = [name for name in req_names if name not in lock_names]
    if missing:
        sys.stdout.write("run\n")
    else:
        sys.stdout.write("skip\n")


if __name__ == "__main__":
    main()
