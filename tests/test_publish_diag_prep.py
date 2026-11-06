"""Item 100: the publish_diag step "Prep site directories" must write its step outputs before anything that can fail.

The Pages publish is the one thing this repository promises never to lose when a test lane is red (CLAUDE.md Item 35).
`publish_diag` starts under `if: always()`, but its first real work is the step "Prep site directories", which made the
`_site` folders and only then wrote `SITE`, `DIAG`, `ARTIFACTS` and `SHORTSHA` to `$GITHUB_OUTPUT`. GitHub's pwsh shell runs
with `$ErrorActionPreference = 'stop'`, so one failing `New-Item` (a full disk, which is what run 19236437263 died of, a
name the file system refuses) ended the step with no outputs at all. About twenty later steps read
`${{ steps.prep.outputs.* }}`: an empty `ARTIFACTS` turned `"${ARTIFACTS}/iterate"` into `/iterate`, an empty `SITE` made
"Upload Pages artifact" look at the repository root. The values are fixed by the job's working folder and the run id, so
nothing about them needs the folders to exist: write them first.

The behavior test runs the step's own text through a real `pwsh` the way the runner does, once normally and once with a run
id long enough that the file system refuses the per-run folder name, and reads what reached `GITHUB_OUTPUT`. The static
rules pin the order and that every `steps.prep.outputs.NAME` the job reads is a name the step writes. Synthetic cases prove
each rule can fail.
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
PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 60  # seconds, for pwsh start-up on a busy runner
STEP_NAME = "Prep site directories"
OUTPUTS = ("SITE", "DIAG", "ARTIFACTS", "SHORTSHA")
SHA = "0123456789abcdef0123456789abcdef01234567"
# One path component of this length is refused on Linux (NAME_MAX 255) and on Windows (a component is at most 255 characters
# even with long paths enabled), so the per-run folder cannot be created on either.
TOO_LONG = "9" * 300


def step_block(text, name=STEP_NAME):
    """Return the text of the step called `name` (a step is a `      - name:` line up to the next one), or None."""
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


def code_lines(run):
    """(number, text) of every non-comment line of the script."""
    return [(i, ln) for i, ln in enumerate(run.splitlines(), 1) if ln.strip() and not ln.lstrip().startswith("#")]


def order_problems(run):
    """The outputs must all be written before the first line that touches the file system.

    Returns a list of problems; empty means every `NAME=...` line appended to GITHUB_OUTPUT comes before the first
    New-Item / Remove-Item / Copy-Item line.
    """
    code = code_lines(run)
    writes = {}
    for number, line in code:
        m = re.search(r'echo\s+"(\w+)=[^"]*"\s*>>\s*\$env:GITHUB_OUTPUT', line)
        if m:
            writes[m.group(1)] = number
    problems = ["%s is never written to GITHUB_OUTPUT" % name for name in OUTPUTS if name not in writes]
    touches = [n for n, line in code if re.search(r"\b(New-Item|Remove-Item|Copy-Item|Set-Content|Out-File)\b", line)]
    if touches and writes:
        first = min(touches)
        late = sorted(name for name, number in writes.items() if number > first)
        if late:
            problems.append("%s written after line %d, which already touches the file system; a failure there would leave "
                            "them unset" % (", ".join(late), first))
    return problems


def consumed_names(workflow_text):
    """Every NAME in `steps.prep.outputs.NAME` that the workflow reads."""
    return sorted(set(re.findall(r"steps\.prep\.outputs\.(\w+)", workflow_text)))


def plain(text):
    """PowerShell's error text without colour codes or line breaks, for matching."""
    return " ".join(re.sub(r"\x1b\[[0-9;]*m", "", text).split())


def substitute(run, run_id, attempt="1", sha=SHA):
    """Replace the three github-context expressions the step uses; any other expression is left and fails the caller."""
    run = run.replace("${{ github.run_id }}", run_id).replace("${{ github.run_attempt }}", attempt)
    return run.replace("${{ github.sha }}", sha)


def run_step(run, run_id, attempt="1"):
    """Run the step text like the runner does; return (process, GITHUB_OUTPUT lines as a dict, what exists afterwards).

    The temporary working folder is gone when this returns, so what the test needs to know about it is read before.
    """
    run = substitute(run, run_id, attempt)
    assert "${{" not in run, "the step uses an expression this test does not provide: " + run
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        work = d / "work"
        work.mkdir()
        script = d / "step.ps1"
        script.write_text("$ErrorActionPreference = 'stop'\n" + run
                          + "\nif ((Test-Path -LiteralPath variable:\\LASTEXITCODE)) { exit $LASTEXITCODE }\n",
                          encoding="ascii")
        out = d / "github_output.txt"
        env = os.environ.copy()
        env["GITHUB_OUTPUT"] = str(out)
        # A single-quoted PowerShell string doubles its apostrophes, so a temp folder with one still reaches the shell.
        proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-Command",
                               ". '%s'" % str(script).replace("'", "''")],
                              cwd=str(work), env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=HARD_TIMEOUT)
        written = {}
        if out.exists():
            for ln in out.read_text(encoding="utf-8-sig").splitlines():
                if "=" in ln:
                    key, value = ln.split("=", 1)
                    written[key.strip()] = value.strip()
        found = {key: Path(written[key]).is_dir() for key in ("SITE", "DIAG", "ARTIFACTS") if key in written}
        if "SITE" in written:
            site = Path(written["SITE"])
            found["site_in_work"] = site.parent.resolve() == work.resolve()
            found["nojekyll_site"] = (site / ".nojekyll").is_file()
        if "DIAG" in written:
            found["nojekyll_diag"] = (Path(written["DIAG"]) / ".nojekyll").is_file()
        return proc, written, found


# The shape this step had until Item 100: folders first, outputs last.
OLD_RUN = """\
$RunId = "${{ github.run_id }}"
$Attempt = "${{ github.run_attempt }}"
$SiteRoot = Join-Path $PWD '_site'
if (Test-Path $SiteRoot) { Remove-Item -Recurse -Force $SiteRoot }
New-Item -ItemType Directory -Path $SiteRoot | Out-Null
$DiagRoot = Join-Path $SiteRoot 'diag'
New-Item -ItemType Directory -Path $DiagRoot | Out-Null
$Diag = Join-Path $DiagRoot "$RunId-$Attempt"
New-Item -ItemType Directory -Path $Diag | Out-Null
$Artifacts = Join-Path $Diag '_artifacts'
New-Item -ItemType Directory -Path $Artifacts | Out-Null
$short = "${{ github.sha }}"
if ($short.Length -gt 7) { $short = $short.Substring(0,7) }
echo "SITE=$SiteRoot" >> $env:GITHUB_OUTPUT
echo "DIAG=$Diag" >> $env:GITHUB_OUTPUT
echo "ARTIFACTS=$Artifacts" >> $env:GITHUB_OUTPUT
echo "SHORTSHA=$short" >> $env:GITHUB_OUTPUT
"""


class StaticShape(unittest.TestCase):
    def real(self):
        block = step_block(WORKFLOW.read_text(encoding="utf-8"))
        self.assertIsNotNone(block, "no step is named %r" % STEP_NAME)
        return block

    def test_the_step_is_the_prep_step_of_the_publish_job_and_still_runs_unless_cancelled(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(text.count("- name: " + STEP_NAME), 1)
        block = self.real()
        self.assertIn("id: prep", block)
        self.assertRegex(block, r"(?m)^        if: \$\{\{ !cancelled\(\) \}\}$")
        self.assertIn("shell: pwsh", block)
        self.assertLess(text.index("  publish_diag:"), text.index("- name: " + STEP_NAME))

    def test_every_output_is_written_before_the_file_system_is_touched(self):
        self.assertEqual(order_problems(run_text(self.real())), [])

    def test_every_output_the_job_reads_is_one_the_step_writes(self):
        names = consumed_names(WORKFLOW.read_text(encoding="utf-8"))
        self.assertTrue(names, "no step reads steps.prep.outputs.*")
        self.assertEqual([n for n in names if n not in OUTPUTS], [])

    def test_the_old_order_is_caught(self):
        found = order_problems(OLD_RUN)
        self.assertEqual(len(found), 1, found)
        for name in OUTPUTS:
            self.assertIn(name, found[0])
        self.assertIn("touches the file system", found[0])

    def test_a_missing_output_is_named(self):
        found = order_problems(OLD_RUN.replace('echo "SHORTSHA=$short" >> $env:GITHUB_OUTPUT\n', ""))
        self.assertTrue(any(f == "SHORTSHA is never written to GITHUB_OUTPUT" for f in found), found)

    def test_one_late_output_is_named_alone(self):
        lines = OLD_RUN.splitlines()
        early = [ln for ln in lines if "GITHUB_OUTPUT" in ln and "SHORTSHA" not in ln]
        rest = [ln for ln in lines if "GITHUB_OUTPUT" not in ln or "SHORTSHA" in ln]
        found = order_problems("\n".join(early + rest) + "\n")
        self.assertEqual(len(found), 1, found)
        self.assertTrue(found[0].startswith("SHORTSHA written after line"), found)

    def test_a_comment_that_mentions_the_cmdlets_is_not_a_file_system_touch(self):
        run = "# New-Item and Remove-Item come later\n" + "\n".join(
            ln for ln in OLD_RUN.splitlines() if "GITHUB_OUTPUT" in ln) + "\nNew-Item -ItemType Directory -Path x\n"
        self.assertEqual(order_problems(run), [])

    def test_a_consumer_of_an_unwritten_name_is_named(self):
        self.assertEqual(consumed_names("a ${{ steps.prep.outputs.SITE }} b ${{ steps.prep.outputs.SITEE }}"),
                         ["SITE", "SITEE"])


@unittest.skipUnless(PWSH, "pwsh not available")
class StepBehavior(unittest.TestCase):
    def real_run(self):
        return run_text(step_block(WORKFLOW.read_text(encoding="utf-8")))

    def expect_outputs(self, written, run_id, attempt="1"):
        self.assertEqual(sorted(written), sorted(OUTPUTS), written)
        site = Path(written["SITE"])
        self.assertEqual(site.name, "_site")
        self.assertEqual(Path(written["DIAG"]), site / "diag" / ("%s-%s" % (run_id, attempt)))
        self.assertEqual(Path(written["ARTIFACTS"]), Path(written["DIAG"]) / "_artifacts")
        self.assertEqual(written["SHORTSHA"], SHA[:7])

    def test_the_real_step_lays_down_the_site_skeleton_and_the_outputs(self):
        proc, written, found = run_step(self.real_run(), "4242", "2")
        self.assertEqual(proc.returncode, 0, plain(proc.stderr or proc.stdout))
        self.expect_outputs(written, "4242", "2")
        self.assertEqual(found, {"SITE": True, "DIAG": True, "ARTIFACTS": True, "site_in_work": True,
                                 "nojekyll_site": True, "nojekyll_diag": True})

    def test_a_folder_that_cannot_be_made_still_leaves_every_output_set(self):
        proc, written, _ = run_step(self.real_run(), TOO_LONG)
        self.assertNotEqual(proc.returncode, 0, "the harness no longer makes the per-run folder fail; nothing is proved")
        self.expect_outputs(written, TOO_LONG)

    def test_the_harness_sees_the_old_order_lose_every_output(self):
        proc, written, _ = run_step(OLD_RUN, TOO_LONG)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(written, {}, "the old step wrote outputs before failing; the harness no longer reproduces Item 100")

    def test_the_harness_sees_the_old_order_work_when_nothing_fails(self):
        proc, written, _ = run_step(OLD_RUN, "7", "1")
        self.assertEqual(proc.returncode, 0, plain(proc.stderr or proc.stdout))
        self.expect_outputs(written, "7")


if __name__ == "__main__":
    unittest.main()
