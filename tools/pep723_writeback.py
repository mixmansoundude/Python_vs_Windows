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
    proc = subprocess.run(cmd, capture_output=True, text=True)
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
    except UnicodeDecodeError:
        print("SKIP:non_utf8")
        return 0
    except OSError:
        print("SKIP:non_utf8")
        return 0

    # File-lock canary: diagnostic-quality only. A locked file already falls safely
    # into the generic ERROR:uv_rc_<n> path below; this just gives a clearer reason.
    # Accepted TOCTOU race: the lock could be acquired after this check and before
    # the uv call -- the fallback is the same already-safe generic error path.
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
        # astral-sh/uv#10918 / astral-sh/uv#19544: exit 2 is uv's own signal that the
        # existing header is unparseable TOML -- the one case where starting over is
        # correct. Any other exit code is a different failure class and must not
        # strip anything (see docs/plan-pep723-writeback.md Part 3 addendum: exit 2
        # is also produced by a non-UTF-8 file, already intercepted above).
        try:
            with open(entry_path, "r", encoding="utf-8", errors="ignore") as fh:
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
        # Retry also failed -- restore the original (still-malformed) header rather
        # than leave the file permanently stripped. Matches the same restore-on-
        # double-failure guarantee already established for the standalone PVW
        # QuickStart commands (docs/plan-pvw-quickstart.md); never delete more of
        # the user's file than the feature actually needed to.
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
