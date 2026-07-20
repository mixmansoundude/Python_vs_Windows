"""pvw_known_idempotent v1 -- Tier 2, docs/plan-autopep723-two-tier.md (HP_PVW_KNOWN_IDEMPOTENT).
Runs the entry via `uvx autopep723 <entry>` as execute-mode discovery for opted-in users
(HP_PVW_KNOWN_IDEMPOTENT=1); relocates README's "Just run it" QuickStart logic into
run_setup.bat (same 0/2/other-nonzero branching, same strip-and-retry-once).
strip_pep723_block mirrors tools/pep723_writeback.py's function (not imported -- embedded
payloads can't share imports at runtime).

Run inherits stdout live; only `autopep723 check` calls capture output. Result markers
(RAN:<detail>/ERROR:<reason>) go to STDERR since stdout is reserved for the passthrough script.

Post-persist retries pass UV_NO_CACHE=1 (force_fresh) to dodge astral-sh/uv#15156: persist()
rewrites the header then run_script() reruns the same file -- the bug's exact trigger. Only
retries pay the no-cache cost; the first attempt keeps normal caching.

Usage: python pvw_known_idempotent.py <entry.py> <uvx_exe> <uv_exe> <python_exe>
Exit 0 = ran (regardless of persist outcome); nonzero = failed after one retry.
Canonical source for HP_PVW_IDEMPOTENT; tests/test_pvw_known_idempotent.py checks payload sync.
"""
import os
import re
import subprocess
import sys

DEP_LINE_RE = re.compile(r'^#\s*"([^"]+)",?\s*$')


def strip_pep723_block(text):
    """Remove an existing '# /// script' ... '# ///' block, line by line. Mirrors
    tools/pep723_writeback.py's function (state machine, tolerant of trailing whitespace
    on the closing fence per astral-sh/uv#10918)."""
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


def run_script(uvx_exe, entry_path, force_fresh=False):
    """Execute via `uvx autopep723 <entry>`, inheriting stdio. force_fresh=True sets
    UV_NO_CACHE=1 (see module docstring); only used on post-persist retries."""
    env = None
    if force_fresh:
        env = dict(os.environ)
        env["UV_NO_CACHE"] = "1"
    try:
        proc = subprocess.run([uvx_exe, "autopep723", entry_path], env=env)
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
        rc2 = run_script(uvx_exe, entry_path, force_fresh=True)
        if rc2 == 0:
            if persist(uvx_exe, uv_exe, python_exe, entry_path):
                print("RAN:persisted_after_repair", file=sys.stderr)
            else:
                print("RAN:persist_failed_after_repair", file=sys.stderr)
            return 0
        # Retry also failed -- restore original content rather than leave it stripped.
        try:
            with open(entry_path, "w", encoding="utf-8", newline="") as fh:
                fh.write(original)
        except OSError:
            pass
        print("ERROR:strip_retry_failed:%d" % rc2, file=sys.stderr)
        return rc2

    # Other nonzero: header (if any) is presumably valid; run failed for another reason --
    # most commonly a missing dependency. Best-effort fill-in without stripping, retry once.
    persist(uvx_exe, uv_exe, python_exe, entry_path)
    rc3 = run_script(uvx_exe, entry_path, force_fresh=True)
    if rc3 == 0:
        print("RAN:persisted_after_fillin", file=sys.stderr)
        return 0
    print("ERROR:run_failed_not_dependency_gap:%d" % rc3, file=sys.stderr)
    return rc3


if __name__ == "__main__":
    sys.exit(main())
