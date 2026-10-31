"""Item 95: the cache lane's "Validate restored conda binary" step must really pass -ExactHit to the self-heal script.

The step built the arguments for tools/ci_cache_selfheal.ps1 in an ARRAY (`$exactArgs = @('-ExactHit')`) and splatted it
(`@exactArgs`). PowerShell splats an array as positional values, so the string '-ExactHit' was offered to a script that has
no positional parameter left (-CondaDir is bound by name) and PowerShell stopped with "A positional parameter cannot be
found that accepts argument '-ExactHit'". GitHub's pwsh shell runs with $ErrorActionPreference = 'stop', so on every EXACT
cache hit the step died before the health check ran, and `continue-on-error: true` kept the lane green: a corrupted
exact-key restore was never detected. A restore-keys prefix match and a miss pass no switch, so those runs were fine. A
hashtable splat (`@{ ExactHit = $true }`) binds the switch by name.

The behavior test runs the step's own text through a real `pwsh` the way the runner does ($ErrorActionPreference = 'stop',
dot-sourced), against a stub whose parameter block is copied from the real script, and reads what the stub was given and
which flags the step wrote to GITHUB_ENV. The static rule holds every call of a .ps1 script in the workflows and in the
PowerShell sources to the same shape. Synthetic cases prove each rule can fail.
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
SELFHEAL = REPO / "tools" / "ci_cache_selfheal.ps1"
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 60  # seconds, for pwsh start-up on a busy runner
STEP_NAME = "Validate restored conda binary"
CALL = ".\\tools\\ci_cache_selfheal.ps1"

STUB_BODY = """
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'record.txt') -Encoding Ascii -Value @(
    "CondaDir=$CondaDir",
    "ExactHit=$($ExactHit.IsPresent)")
exit ([int]$env:HP_TEST_STUB_RC)
"""

# (cache-hit output of the restore step, exit code of the self-heal script, ExactHit it must receive, flags the step writes)
MATRIX = (
    ("true", 0, "True", []),
    ("true", 1, "True", ["HP_CACHE_CORRUPTED=1"]),
    ("false", 0, "False", []),
    ("false", 2, "False", ["HP_CACHE_SELFHEAL_ATTEMPTED=1"]),
    ("false", 3, "False", ["HP_CACHE_CORRUPTED=1", "HP_CACHE_SELFHEAL_FAILED=1", "HP_CACHE_SELFHEAL_ATTEMPTED=1"]),
    ("", 0, "False", []),
)


def step_block(text, name=STEP_NAME):
    """Return the text of the step called `name`, or None."""
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        if lines[start].strip() == "- name: " + name:
            return "\n".join(lines[start:end])
    return None


def run_text(block):
    """The body of the step's `run: |` scalar as the runner writes it to a script file (10 spaces of indent removed)."""
    lines = block.splitlines()
    head = next(i for i, ln in enumerate(lines) if re.match(r"^        run: \|\s*$", ln))
    body = []
    for ln in lines[head + 1:]:
        if not ln.strip():
            body.append("")
        elif ln.startswith(" " * 10):
            body.append(ln[10:])
        else:
            break
    return "\n".join(body).rstrip("\n") + "\n"


def param_block(text):
    """The `param( ... )` block at the top of the real script."""
    m = re.search(r"^param\(\n.*?^\)\n", text.replace("\r\n", "\n"), re.MULTILINE | re.DOTALL)
    return m.group(0) if m else None


def splat_problems(text, where):
    """A variable splatted into a call of a .ps1 script must hold a hashtable.

    An array splat passes positional values, so a switch name in it ('-ExactHit') is read as a string argument.
    Native commands (`& $python @args`) take arrays and are not looked at: only lines that call a .ps1 file are.
    """
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        if ".ps1" not in line or line.lstrip().startswith("#"):
            continue
        for name in re.findall(r"(?<![\w$@'\"])@([A-Za-z_]\w*)\s*(?:$|[|>;)]|\s)", line):
            assigns = re.findall(r"\$%s\s*=\s*(\S+)" % re.escape(name), text)
            if not assigns:
                found.append("%s:%d: @%s is splatted but never assigned" % (where, number, name))
                continue
            bad = [a for a in assigns if not a.startswith("@{")]
            if bad:
                found.append("%s:%d: @%s is splatted into a .ps1 call but is assigned %s, not a hashtable; an array "
                             "splat passes positional values, so a switch name in it fails to bind"
                             % (where, number, name, bad[0]))
    return found


def sources():
    """Every file whose .ps1 calls the rule reads: the workflows, tools/ and tests/ PowerShell."""
    yield from sorted((REPO / ".github" / "workflows").glob("*.yml"))
    yield from sorted((REPO / "tools").glob("*.ps1"))
    yield from sorted((REPO / "tests").glob("*.ps1"))


def plain(text):
    """PowerShell's error text without colour codes or line breaks, for matching."""
    return " ".join(re.sub(r"\x1b\[[0-9;]*m", "", text).split())


def stub_script(real=None):
    """A script with the real script's parameter block that records what it was given."""
    block = param_block(real if real is not None else SELFHEAL.read_text(encoding="utf-8"))
    assert block, "tools/ci_cache_selfheal.ps1 has no param( ... ) block at its top level"
    return block + STUB_BODY


def run_step(run, exact_hit, rc, stub=None):
    """Run the step text like the runner does; return (process, what the stub recorded or None, GITHUB_ENV lines)."""
    if os.name != "nt":
        run = run.replace(CALL, "./tools/ci_cache_selfheal.ps1")  # a backslash is not a separator off Windows
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        (d / "tools").mkdir()
        (d / "tools" / "ci_cache_selfheal.ps1").write_text(stub or stub_script(), encoding="ascii")
        script = d / "step.ps1"
        script.write_text("$ErrorActionPreference = 'stop'\n" + run
                          + "\nif ((Test-Path -LiteralPath variable:\\LASTEXITCODE)) { exit $LASTEXITCODE }\n",
                          encoding="ascii")
        env = os.environ.copy()
        env.update({"GITHUB_ENV": str(d / "github_env.txt"), "HP_CACHE_EXACT_HIT": exact_hit,
                    "HP_TEST_STUB_RC": str(rc)})
        proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-Command", ". '%s'" % script],
                              cwd=str(d), env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=HARD_TIMEOUT)
        record = d / "tools" / "record.txt"
        seen = None
        if record.exists():
            seen = dict(ln.split("=", 1) for ln in record.read_text(encoding="ascii").splitlines() if "=" in ln)
        flags = d / "github_env.txt"
        written = [ln.strip() for ln in flags.read_text(encoding="ascii").splitlines() if ln.strip()] if flags.exists() else []
        return proc, seen, written


OLD_RUN = """\
$exactArgs = @()
if ($env:HP_CACHE_EXACT_HIT -eq 'true') { $exactArgs = @('-ExactHit') }
& .\\tools\\ci_cache_selfheal.ps1 -CondaDir 'C:\\Users\\Public\\Documents\\Miniconda3' @exactArgs
$rc = $LASTEXITCODE
if ($rc -eq 1 -or $rc -eq 3) {
  'HP_CACHE_CORRUPTED=1' | Out-File -FilePath $env:GITHUB_ENV -Encoding ascii -Append
}
if ($rc -eq 3) {
  'HP_CACHE_SELFHEAL_FAILED=1' | Out-File -FilePath $env:GITHUB_ENV -Encoding ascii -Append
}
if ($rc -eq 2 -or $rc -eq 3) {
  'HP_CACHE_SELFHEAL_ATTEMPTED=1' | Out-File -FilePath $env:GITHUB_ENV -Encoding ascii -Append
}
exit 0
"""

NEW_RUN = OLD_RUN.replace("$exactArgs = @()", "$exactArgs = @{}").replace("@('-ExactHit')", "@{ ExactHit = $true }")


class StaticShape(unittest.TestCase):
    def test_the_step_exists_and_calls_the_script_the_behavior_test_replaces(self):
        block = step_block(WORKFLOW.read_text(encoding="utf-8"))
        self.assertIsNotNone(block, "no step is named %r" % STEP_NAME)
        run = run_text(block)
        self.assertEqual(run.count(CALL), 1, run)
        self.assertRegex(run, r"-CondaDir '[^']+'")

    def test_the_stub_takes_the_real_scripts_parameters(self):
        block = param_block(SELFHEAL.read_text(encoding="utf-8"))
        self.assertIsNotNone(block)
        self.assertIn("[string]$CondaDir", block)
        self.assertIn("[switch]$ExactHit", block)

    def test_no_script_call_in_the_repository_splats_an_array(self):
        found = []
        for path in sources():
            found += splat_problems(path.read_text(encoding="utf-8", errors="replace"), path.relative_to(REPO).as_posix())
        self.assertEqual(found, [])

    def test_the_old_shape_is_caught(self):
        found = splat_problems(OLD_RUN, "old")
        self.assertEqual(len(found), 1, found)
        self.assertIn("not a hashtable", found[0])

    def test_the_hashtable_shape_is_clean(self):
        self.assertEqual(splat_problems(NEW_RUN, "new"), [])

    def test_a_splat_into_a_native_command_is_not_looked_at(self):
        native = "$pyArgs = @('-m', 'pip', 'list')\n& $python @pyArgs *>&1 | Tee-Object -FilePath $log\n"
        self.assertEqual(splat_problems(native, "native"), [])

    def test_an_unassigned_splat_is_named(self):
        found = splat_problems("& .\\tools\\x.ps1 -A 1 @missing\n", "x")
        self.assertEqual(len(found), 1, found)
        self.assertIn("never assigned", found[0])

    def test_a_comment_line_is_not_a_call(self):
        self.assertEqual(splat_problems("# & .\\tools\\x.ps1 @oldArgs\n$oldArgs = @('-A')\n", "c"), [])


@unittest.skipUnless(PWSH, "pwsh not available")
class StepBehavior(unittest.TestCase):
    CONDA_DIR = "C:\\Users\\Public\\Documents\\Miniconda3"

    def real_run(self):
        return run_text(step_block(WORKFLOW.read_text(encoding="utf-8")))

    def check(self, run, exact_hit, rc, switch, flags):
        proc, seen, written = run_step(run, exact_hit, rc)
        self.assertIsNotNone(
            seen, "tools/ci_cache_selfheal.ps1 was never reached (cache-hit=%r), so the health check did not run: %s"
            % (exact_hit, plain(proc.stderr or proc.stdout)[:300]))
        self.assertEqual(seen.get("CondaDir"), self.CONDA_DIR)
        self.assertEqual(seen.get("ExactHit"), switch,
                         "cache-hit=%r must reach the script as ExactHit=%s" % (exact_hit, switch))
        self.assertEqual(written, flags)
        self.assertEqual(proc.returncode, 0, "the step must never fail: %s" % proc.stderr)

    def test_the_real_step_passes_the_switch_only_on_an_exact_hit(self):
        run = self.real_run()
        for exact_hit, rc, switch, flags in MATRIX:
            with self.subTest(cache_hit=exact_hit, rc=rc):
                self.check(run, exact_hit, rc, switch, flags)

    def test_the_harness_sees_the_old_shape_fail_on_an_exact_hit(self):
        proc, seen, written = run_step(OLD_RUN, "true", 1)
        self.assertIsNone(seen, "the array splat reached the script; the harness no longer reproduces Item 95")
        self.assertEqual(written, [])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("A positional parameter cannot be found that accepts argument '-ExactHit'", plain(proc.stderr))

    def test_the_harness_passes_the_old_shape_where_no_switch_is_sent(self):
        for exact_hit in ("false", ""):
            with self.subTest(cache_hit=exact_hit):
                self.check(OLD_RUN, exact_hit, 2 if exact_hit else 0, "False",
                           ["HP_CACHE_SELFHEAL_ATTEMPTED=1"] if exact_hit else [])

    def test_the_harness_passes_the_hashtable_shape_on_every_row(self):
        for exact_hit, rc, switch, flags in MATRIX:
            with self.subTest(cache_hit=exact_hit, rc=rc):
                self.check(NEW_RUN, exact_hit, rc, switch, flags)

    def test_a_script_that_has_lost_the_switch_is_reported_not_skipped(self):
        # the stub copies the real parameter block, so renaming or dropping -ExactHit there must turn the exact-hit row red
        original = SELFHEAL.read_text(encoding="utf-8")
        trimmed = original.replace("    [switch]$ExactHit\n", "").replace("[string]$CondaDir,\n", "[string]$CondaDir\n")
        self.assertNotEqual(trimmed, original)
        self.assertNotIn("[switch]$ExactHit", param_block(trimmed))
        proc, seen, written = run_step(NEW_RUN, "true", 1, stub=stub_script(trimmed))
        self.assertIsNone(seen)
        self.assertEqual(written, [])
        self.assertNotEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
