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
                # pip directives (-e, -r, --hash) make uv exit 2, like bad TOML;
                # filter them or main() wrongly strips a valid header.
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
    fake = os.environ.get("HP_TEST_PEP723_UV_ERR")  # test hook: pretend uv failed, no uv call
    if fake:
        return 1, fake
    cmd = [uv_exe, "add", "--script", entry_path, "-p", python_exe] + packages
    try:
        # Bounded: a stalled uv call must not hang the bootstrap.
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return 1, "timeout"
    # astral-sh/uv#15956: a benign warning can sit on stderr at exit 0; only the
    # return code signals failure.
    return proc.returncode, proc.stderr


def _log_tail(text):
    # Item 73: uv's own reason; the batch appends our stderr to the setup log (2>> "%LOG%").
    for line in [x.strip() for x in (text or "").splitlines() if x.strip()][-5:]:
        sys.stderr.write("uv: %s\n" % line[:200].encode("ascii", "replace").decode())


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

    # Never hand uv a file that is not confirmed UTF-8.
    try:
        with open(entry_path, encoding="utf-8") as fh:
            fh.read()
    except (UnicodeDecodeError, OSError):
        print("SKIP:non_utf8")
        return 0

    # File-lock canary: a clearer reason than the generic ERROR:uv_rc_<n> below.
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

    rc, err = run_uv_add(entry_path, uv_exe, python_exe, packages)
    if rc:
        _log_tail(err)
    if rc == 0:
        print("OK:%d" % len(packages))
        return 0
    if rc == 2:
        # uv#10918/#19544: exit 2 = unparseable header, the one case to start over.
        try:
            # newline="" keeps CRLF intact through the strip and the restore below.
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
        rc2, err2 = run_uv_add(entry_path, uv_exe, python_exe, packages)
        if rc2:
            _log_tail(err2)
        if rc2 == 0:
            print("OK:%d" % len(packages))
            return 0
        # Retry failed too: restore the original rather than leave it stripped.
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
