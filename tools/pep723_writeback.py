"""pep723_writeback v1 (2026-07-18)
Promotes a resolved dependency list into the entry file's PEP 723 header via
`uv add --script`. See docs/plan-pep723-writeback.md Part 2.1 for the full design.
Usage: python pep723_writeback.py <entry.py> <uv_exe> <python_exe> <packages_file>
Prints one result line to stdout: OK:<n> / SKIP:<reason> / ERROR:<reason>.
"""
__version__ = "pep723_writeback v1 (2026-07-18)"
__all__ = ["read_packages", "strip_pep723_block", "main"]

import os
import subprocess
import sys


def read_packages(path):
    """Return a list of non-blank, non-comment lines from a packages file."""
    packages = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # pip directives (-e, -r, --hash, ...) exit 2 from uv's clap
                # parser same as malformed TOML -- filter or main() wrongly
                # strips a valid header. Real specs never start with '-'.
                if line.startswith("-"):
                    continue
                packages.append(line)
    except OSError:
        pass
    return packages


def strip_pep723_block(text):
    """Remove an existing '# /// script' ... '# ///' block, line by line.

    A line-by-line state machine, not a regex: a greedy regex risks stripping
    code after the block, and a lazy one can leave a stray fence line behind,
    which newer uv treats as a hard error (astral-sh/uv#19544). The closing
    fence match tolerates trailing whitespace (astral-sh/uv#10918).
    """
    lines = text.splitlines(keepends=True)
    out = []
    in_block = False
    for line in lines:
        stripped = line.rstrip("\r\n")
        if not in_block and stripped == "# /// script":
            in_block = True
            continue
        if in_block:
            if stripped.rstrip() == "# ///":
                in_block = False
            continue
        out.append(line)
    return "".join(out)


def run_uv_add(entry_path, uv_exe, python_exe, packages):
    """Invoke `uv add --script` once; return (returncode, stderr_text)."""
    cmd = [uv_exe, "add", "--script", entry_path, "-p", python_exe] + packages
    try:
        # Bounded like other network-touching helpers here (embed_pyver_check.py
        # socket timeout) -- a stalled uv call must not hang the bootstrap.
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return 1, "timeout"
    # astral-sh/uv#15956: a benign VIRTUAL_ENV mismatch warning can appear on stderr
    # with exit code 0 -- stderr text is never itself a failure signal, only the
    # process return code is.
    return proc.returncode, proc.stderr


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 4:
        print("ERROR:bad_args")
        return 1
    entry_path, uv_exe, python_exe, packages_file = args[0], args[1], args[2], args[3]

    packages = read_packages(packages_file)
    if not packages:
        print("SKIP:no_packages")
        return 0

    # Encoding pre-check: never hand uv a file whose UTF-8-ness is unconfirmed.
    try:
        with open(entry_path, encoding="utf-8") as fh:
            fh.read()
    except (UnicodeDecodeError, OSError):
        print("SKIP:non_utf8")
        return 0

    # File-lock canary: diagnostic-quality only, gives a clearer reason than the
    # generic ERROR:uv_rc_<n> path below. Accepted TOCTOU race (lock could be
    # acquired after this check) falls back to that same safe generic path.
    try:
        with open(entry_path, "r+b"):
            pass
    except PermissionError:
        print("SKIP:file_locked")
        return 0
    except OSError:
        pass

    if entry_path.endswith(".py") and _lock_sidecar_exists(entry_path):
        print("SKIP:lockfile")
        return 0

    rc, _stderr = run_uv_add(entry_path, uv_exe, python_exe, packages)
    if rc == 0:
        print("OK:%d" % len(packages))
        return 0
    if rc == 2:
        # astral-sh/uv#10918 / #19544: exit 2 is uv's signal the existing header
        # is unparseable TOML -- the one case where starting over is correct.
        # Any other exit code must not strip anything.
        try:
            # newline="" keeps CRLF intact on read -- without it, both the
            # stripped write and the restore-on-double-failure write below
            # would silently normalize the whole file's line endings to LF.
            with open(entry_path, "r", encoding="utf-8", errors="ignore", newline="") as fh:
                original = fh.read()
        except OSError:
            print("ERROR:strip_retry_failed:read")
            return 1
        stripped = strip_pep723_block(original)
        try:
            with open(entry_path, "w", encoding="utf-8", newline="") as fh:
                fh.write(stripped)
        except OSError:
            print("ERROR:strip_retry_failed:write")
            return 1
        rc2, _stderr2 = run_uv_add(entry_path, uv_exe, python_exe, packages)
        if rc2 == 0:
            print("OK:%d" % len(packages))
            return 0
        # Retry also failed -- restore original (still-malformed) content rather
        # than leave the file permanently stripped (mirrors PVW QuickStart's own
        # restore-on-double-failure guarantee).
        try:
            with open(entry_path, "w", encoding="utf-8", newline="") as fh:
                fh.write(original)
        except OSError:
            pass
        print("ERROR:strip_retry_failed:%d" % rc2)
        return 1
    print("ERROR:uv_rc_%d" % rc)
    return 1


def _lock_sidecar_exists(entry_path):
    return os.path.exists(entry_path + ".lock")


if __name__ == "__main__":
    sys.exit(main())
