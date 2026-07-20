"""pvw_known_idempotent v1 -- Tier 2, docs/plan-autopep723-two-tier.md (HP_PVW_KNOWN_IDEMPOTENT).
Runs the entry script via `uvx autopep723 <entry>` as execute-mode dependency discovery, for
users who opted in (HP_PVW_KNOWN_IDEMPOTENT=1). Relocates README's shipped "Just run it"
QuickStart logic into run_setup.bat: same exit-code branching (0 / 2 / other-nonzero), same
strip-and-retry-once-on-malformed-header handling. strip_pep723_block mirrors
tools/pep723_writeback.py's function of the same name (not imported -- embedded single-file
payloads can't share imports at runtime).

The run step inherits stdout so the user sees their own program's output live -- never
captured. Only internal `autopep723 check` calls (discovering names to persist) capture
output. Result markers (RAN:<detail> / ERROR:<reason>) print to STDERR, not stdout, since
stdout is reserved for the passed-through script -- caller redirects stderr to read them.

Usage: python pvw_known_idempotent.py <entry.py> <uvx_exe> <uv_exe> <python_exe>
Exit 0 = script ran (regardless of persist outcome); nonzero = run failed after one retry.
Canonical source for HP_PVW_IDEMPOTENT in run_setup.bat; tests/test_pvw_known_idempotent.py
asserts the embedded payload matches this file.
"""
import re
import subprocess
import sys

DEP_LINE_RE = re.compile(r'^#\s*"([^"]+)",?\s*$')


def strip_pep723_block(text):
    """Remove an existing '# /// script' ... '# ///' block, line by line.

    Mirrors tools/pep723_writeback.py's function of the same name (see that file's docstring
    for the full rationale: a line-by-line state machine, not a regex, tolerant of trailing
    whitespace on the closing fence per astral-sh/uv#10918).
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


def run_script(uvx_exe, entry_path):
    """Actually execute the user's script via `uvx autopep723 <entry>`, inheriting stdio."""
    try:
        proc = subprocess.run([uvx_exe, "autopep723", entry_path])
    except OSError:
        return 1
    return proc.returncode


def discover_dep_names(uvx_exe, entry_path):
    """Run `uvx autopep723 check <entry>` and extract dependency names from its output."""
    try:
        proc = subprocess.run(
            [uvx_exe, "autopep723", "check", entry_path],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    names = []
    for line in proc.stdout.splitlines():
        match = DEP_LINE_RE.match(line.rstrip("\n"))
        if match:
            names.append(match.group(1).strip())
    return names


def persist(uvx_exe, uv_exe, python_exe, entry_path):
    """Best-effort: discover dependency names and write them into the header via `uv add
    --script`. Returns True on a successful (or no-op, nothing-to-add) persist, False if
    discovery or the uv call itself failed. Never raises."""
    names = discover_dep_names(uvx_exe, entry_path)
    if not names:
        return True
    cmd = [uv_exe, "add", "--script", entry_path, "-p", python_exe] + names
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 4:
        print("ERROR:bad_args", file=sys.stderr)
        return 1
    entry_path, uvx_exe, uv_exe, python_exe = args[0], args[1], args[2], args[3]

    rc = run_script(uvx_exe, entry_path)

    if rc == 0:
        if persist(uvx_exe, uv_exe, python_exe, entry_path):
            print("RAN:persisted", file=sys.stderr)
        else:
            print("RAN:persist_failed", file=sys.stderr)
        return 0

    if rc == 2:
        try:
            with open(entry_path, "r", encoding="utf-8", errors="ignore", newline="") as fh:
                original = fh.read()
        except OSError:
            print("ERROR:strip_retry_failed:read", file=sys.stderr)
            return rc
        stripped = strip_pep723_block(original)
        try:
            with open(entry_path, "w", encoding="utf-8", newline="") as fh:
                fh.write(stripped)
        except OSError:
            print("ERROR:strip_retry_failed:write", file=sys.stderr)
            return rc
        rc2 = run_script(uvx_exe, entry_path)
        if rc2 == 0:
            if persist(uvx_exe, uv_exe, python_exe, entry_path):
                print("RAN:persisted_after_repair", file=sys.stderr)
            else:
                print("RAN:persist_failed_after_repair", file=sys.stderr)
            return 0
        # Retry also failed -- restore the original (still-malformed) content rather than
        # leave the file permanently stripped.
        try:
            with open(entry_path, "w", encoding="utf-8", newline="") as fh:
                fh.write(original)
        except OSError:
            pass
        print("ERROR:strip_retry_failed:%d" % rc2, file=sys.stderr)
        return rc2

    # Other nonzero: an existing header (if any) is presumably still valid TOML, but the run
    # failed for some other reason -- most commonly a missing dependency. Best-effort fill-in
    # without stripping anything, then retry once.
    persist(uvx_exe, uv_exe, python_exe, entry_path)
    rc3 = run_script(uvx_exe, entry_path)
    if rc3 == 0:
        print("RAN:persisted_after_fillin", file=sys.stderr)
        return 0
    print("ERROR:run_failed_not_dependency_gap:%d" % rc3, file=sys.stderr)
    return rc3


if __name__ == "__main__":
    sys.exit(main())
