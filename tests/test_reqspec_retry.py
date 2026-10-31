"""Item 92: tests/selfapps_reqspec.ps1 retries a conda network call once when conda-forge answers with a 5xx.

Run 41074512594 (PR #513): a single `502 Server Error: Bad Gateway` on a repodata shard made the first conda dry run exit 1,
and nine `reqspec.*` rows plus the required "Aggregate self-test verdicts" check went red, although every other conda call in
the same run worked. The script's five network calls (the dry run and the install of each half, and the dry run that is expected to fail) now go
through `Invoke-CondaCommand`: one more attempt after a short wait, only when the output names a 5xx or a failed connection, never
for a solver answer or a 404, never more than twice.

What this file proves, without Windows or conda:
  - the helper's loop, run through real `pwsh` with a `cmd` function standing in for the native command (Invoke-CondaCommand
    is cut out of the script text, so the shipped code is what runs): a 502 then success exits 0 after two attempts, a 502
    that stays exits 1 after exactly two, a solver answer, a 404 and a success are run once, the first attempt's output and a
    one-line notice reach the log;
  - the transient pattern against text conda wrote (the 502 crash line of that run, conda's own CondaHTTPError wording);
  - the expected-failure row's verdict (`Test-FailcaseRejected`, cut out the same way): a solver answer with a non-zero exit
    passes, a 5xx or connection answer does not, because it proves nothing about the constraint (CodeRabbit, PR #515);
  - static pins: one helper, a bounded attempt count and wait, every network call of the script goes through it (a new raw
    `cmd /c $...Command` must be added to the short allow list on purpose), the four proof rows keep literal ids, the workflow
    step stays a gating step.
The Windows side of the same behavior is the rows `reqspec.retry.*` themselves (justme-test and conda-full lanes).
Synthetic text cases prove each static rule can fail.
"""
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools import check_ndjson_registry

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "tests" / "selfapps_reqspec.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
PWSH = shutil.which("pwsh")

ROW_IDS = ("reqspec.retry.once", "reqspec.retry.bounded", "reqspec.retry.nontransient", "reqspec.retry.classify")
STEP_NAME = "Self-test: requirements specifier coverage"
# Raw `cmd /c $X` calls that are allowed to stay outside the helper: local configuration and the two python import checks.
# The dry run that is EXPECTED to fail goes through the helper too, and its verdict refuses a 5xx answer.
RAW_ALLOWED = {"configCommand", "importCommand", "ingestImportCommand"}
MAX_ATTEMPTS = 2
MAX_WAIT_SECONDS = 30

# Real text. The first is the last line of the crash in run 41074512594; the next three follow conda's own error wording.
TRANSIENT = (
    "requests.exceptions.HTTPError: 502 Server Error: Bad Gateway for url: "
    "https://conda.anaconda.org/conda-forge/win-64/ce81bff8e89d422c0e4ef1ac471cc77422695c84a7d589c446d1e1a1d5ad2b7b.msgpack.zst",
    "CondaHTTPError: HTTP 503 SERVICE UNAVAILABLE for url <https://conda.anaconda.org/conda-forge/noarch/repodata.json>",
    "CondaHTTPError: HTTP 000 CONNECTION FAILED for url <https://conda.anaconda.org/conda-forge/win-64/current_repodata.json>",
    "requests.exceptions.ConnectionError: HTTPSConnectionPool(host='conda.anaconda.org', port=443): Max retries exceeded",
    "requests.exceptions.ReadTimeout: HTTPSConnectionPool(host='conda.anaconda.org', port=443): Read timed out. (read timeout=9.15)",
)
NOT_TRANSIENT = (
    "PackagesNotFoundError: The following packages are not available from current channels:",
    "UnsatisfiableError: The following specifications were found to be incompatible with each other:",
    "CondaHTTPError: HTTP 404 NOT FOUND for url <https://conda.anaconda.org/conda-forge/win-64/nosuchpackage>",
    "requests.exceptions.HTTPError: 404 Client Error: Not Found for url: https://conda.anaconda.org/conda-forge/win-64/x.msgpack.zst",
)


def _read():
    return SCRIPT.read_text(encoding="utf-8")


def helper_text(text):
    """The pattern assignment plus the whole Invoke-CondaCommand function, as they stand in the script."""
    start = text.index("$script:CondaTransientPattern")
    end = text.index("function Get-CondaBatPath")
    return text[start:end]


def pattern_from(text):
    m = re.search(r"\$script:CondaTransientPattern\s*=\s*'((?:[^']|'')*)'", text)
    return m.group(1).replace("''", "'") if m else None


def problems(text):
    """Static rules; returns a list of readable findings (empty = clean)."""
    found = []
    defs = re.findall(r"^function Invoke-CondaCommand\b", text, re.M)
    if len(defs) != 1:
        found.append("Invoke-CondaCommand must be defined exactly once, found %d" % len(defs))
    attempts = re.findall(r"\$maxAttempts\s*=\s*(\d+)", text)
    if len(attempts) != 1 or int(attempts[0]) > MAX_ATTEMPTS:
        found.append("the attempt count must be set once and be at most %d: %r" % (MAX_ATTEMPTS, attempts))
    wait = re.search(r"\[int\]\$WaitSeconds\s*=\s*(\d+)", text)
    if not wait or not (1 <= int(wait.group(1)) <= MAX_WAIT_SECONDS):
        found.append("the default wait must be between 1 and %d seconds" % MAX_WAIT_SECONDS)
    raw = set(re.findall(r"cmd /c \$(\w+)", text))
    # The helper's own call reads $Command; every other raw call must be on the allow list.
    stray = sorted(raw - RAW_ALLOWED - {"Command"})
    if stray:
        found.append("raw cmd /c calls outside the helper: %s" % ", ".join(stray))
    for label in ("conda dry-run", "conda install", "ingest conda dry-run", "ingest conda install", "conda failure-case dry-run"):
        if not re.search(r"Invoke-CondaCommand\b[^\n]*-Label '%s'" % re.escape(label), text):
            found.append("no Invoke-CondaCommand call labelled %r" % label)
    if not re.search(r"\$failcasePass\s*=\s*Test-FailcaseRejected\b", text):
        found.append("the failcase row must take its verdict from Test-FailcaseRejected")
    if not re.search(r"\$failcaseDetails\.transientAnswer\s*=", text):
        found.append("the failcase details must record transientAnswer")
    for row in ROW_IDS:
        n = len(re.findall(r"\bid\s*=\s*'%s'" % re.escape(row), text))
        if n != 1:
            found.append("row %s must be written once with a literal id, found %d" % (row, n))
    if "$script:CondaTransientPattern" not in text or pattern_from(text) is None:
        found.append("the transient pattern must stay one single-quoted assignment")
    return found


class StaticRules(unittest.TestCase):
    def test_script_is_clean(self):
        self.assertEqual(problems(_read()), [])

    def test_step_is_a_gating_step(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        i = text.index('- name: "%s"' % STEP_NAME)
        nxt = text.find("\n      - name:", i + 1)
        block = text[i:nxt]
        self.assertNotIn("continue-on-error", block)
        self.assertIn("selfapps_reqspec.ps1", block)

    def test_registry_lists_the_rows(self):
        ids, _many = check_ndjson_registry.parse_doc_registry(REPO / "docs" / "agent-ndjson.md")
        for row in ROW_IDS:
            self.assertIn(row, ids)

    def test_rows_carry_a_free_requirement_tag(self):
        text = _read()
        for row in ROW_IDS:
            m = re.search(r"id\s*=\s*'%s'\s*\n\s*req\s*=\s*'([^']+)'" % re.escape(row), text)
            self.assertIsNotNone(m, row)
            self.assertEqual(m.group(1), "N/A", row)


class SyntheticRulesCanFail(unittest.TestCase):
    def test_second_definition(self):
        self.assertTrue(problems(_read() + "\nfunction Invoke-CondaCommand {}\n"))

    def test_unbounded_attempts(self):
        self.assertTrue(problems(re.sub(r"\$maxAttempts\s*=\s*\d+", "$maxAttempts = 5", _read())))

    def test_long_wait(self):
        self.assertTrue(problems(re.sub(r"\[int\]\$WaitSeconds\s*=\s*\d+", "[int]$WaitSeconds = 300", _read())))

    def test_raw_network_call(self):
        self.assertTrue(problems(_read() + "\n$o = cmd /c $newDryRunCommand 2>&1\n"))

    def test_call_site_moved_back_to_raw(self):
        text = _read().replace("Invoke-CondaCommand -Command $dryRunCommand -Label 'conda dry-run'", "Invoke-Other -Command $dryRunCommand")
        self.assertTrue(problems(text))

    def test_failcase_verdict_back_to_exit_code_only(self):
        text = _read().replace("$failcasePass = Test-FailcaseRejected", "$failcasePass = ($failcase.exitCode -ne 0) #")
        self.assertTrue(problems(text))

    def test_failcase_call_moved_back_to_raw(self):
        text = _read().replace("Invoke-CondaCommand -Command $badDryRunCommand -Label 'conda failure-case dry-run'", "cmd /c $badDryRunCommand")
        self.assertTrue(problems(text))

    def test_row_id_through_a_variable(self):
        self.assertTrue(problems(_read().replace("id = 'reqspec.retry.once'", "id = $rowId")))

    def test_pattern_removed(self):
        self.assertTrue(problems(_read().replace("$script:CondaTransientPattern =", "$script:Other =")))


class PatternMatchesRealText(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rx = re.compile(pattern_from(_read()))

    def test_transient_text_matches(self):
        for line in TRANSIENT:
            self.assertTrue(self.rx.search(line), line)

    def test_solver_and_client_errors_do_not(self):
        for line in NOT_TRANSIENT:
            self.assertFalse(self.rx.search(line), line)


# The shim: a function named `cmd` shadows the native command, so `cmd /c $Command 2>&1` inside the helper runs this instead.
# It consumes one scripted step per call (exit code and the text the command would print) and counts the calls.
RUNNER = r"""
$ErrorActionPreference = 'Stop'
{HELPER}
$global:Plan = @(Get-Content -LiteralPath '{PLAN}' -Raw | ConvertFrom-Json)
$global:Calls = 0
function cmd {
    $step = $global:Plan[[Math]::Min($global:Calls, $global:Plan.Count - 1)]
    $global:Calls++
    $global:LASTEXITCODE = [int]$step.code
    return [string]$step.text
}
$r = Invoke-CondaCommand -Command 'stub' -Label 'unit stub' -LogPath '{LOG}' -WaitSeconds 0
[pscustomobject]@{ exitCode = $r.ExitCode; attempts = $r.Attempts; retried = $r.Retried; calls = $global:Calls; output = $r.Output } | ConvertTo-Json -Compress
"""


@unittest.skipUnless(PWSH, "pwsh is not installed")
class HelperBehavior(unittest.TestCase):
    def _run(self, plan):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            plan_path = d / "plan.json"
            plan_path.write_text(json.dumps(plan), encoding="ascii")
            log = d / "run.log"
            script = d / "run.ps1"
            script.write_text(
                RUNNER.replace("{HELPER}", helper_text(_read())).replace("{PLAN}", str(plan_path)).replace("{LOG}", str(log)),
                encoding="ascii",
            )
            p = subprocess.run(
                [PWSH, "-NoProfile", "-NonInteractive", "-File", str(script)],
                capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
            )
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
            result = json.loads(p.stdout.strip().splitlines()[-1])
            result["log"] = log.read_text(encoding="utf-8") if log.exists() else ""
            return result

    def test_502_then_success_is_retried_once(self):
        r = self._run([{"code": 1, "text": TRANSIENT[0]}, {"code": 0, "text": "ok"}])
        self.assertEqual((r["exitCode"], r["attempts"], r["retried"], r["calls"]), (0, 2, True, 2))
        self.assertEqual(r["output"].strip(), "ok")

    def test_502_that_stays_runs_exactly_twice(self):
        r = self._run([{"code": 1, "text": TRANSIENT[0]}] * 5)
        self.assertEqual((r["exitCode"], r["attempts"], r["retried"], r["calls"]), (1, 2, True, 2))
        self.assertIn("502 Server Error", r["output"])

    def test_connection_failure_is_retried(self):
        r = self._run([{"code": 1, "text": TRANSIENT[2]}, {"code": 0, "text": "ok"}])
        self.assertEqual((r["exitCode"], r["attempts"]), (0, 2))

    def test_solver_answer_is_not_retried(self):
        r = self._run([{"code": 1, "text": NOT_TRANSIENT[0]}, {"code": 0, "text": "ok"}])
        self.assertEqual((r["exitCode"], r["attempts"], r["retried"], r["calls"]), (1, 1, False, 1))

    def test_404_is_not_retried(self):
        r = self._run([{"code": 1, "text": NOT_TRANSIENT[2]}, {"code": 0, "text": "ok"}])
        self.assertEqual((r["attempts"], r["calls"]), (1, 1))

    def test_success_is_run_once(self):
        r = self._run([{"code": 0, "text": "ok"}, {"code": 1, "text": TRANSIENT[0]}])
        self.assertEqual((r["exitCode"], r["attempts"], r["retried"], r["calls"]), (0, 1, False, 1))

    def test_a_retry_leaves_the_first_answer_in_the_log(self):
        r = self._run([{"code": 1, "text": TRANSIENT[0]}, {"code": 0, "text": "ok"}])
        self.assertIn("unit stub", r["log"])
        self.assertIn("retrying", r["log"])
        self.assertIn("502 Server Error", r["log"])

    def test_no_retry_writes_nothing_to_the_log(self):
        r = self._run([{"code": 0, "text": "ok"}])
        self.assertEqual(r["log"], "")


FAILCASE_RUNNER = r"""
$ErrorActionPreference = 'Stop'
{HELPER}
$cases = @(
    [pscustomobject]@{ exitCode = 1; transientAnswer = $false },
    [pscustomobject]@{ exitCode = 1; transientAnswer = $true },
    [pscustomobject]@{ exitCode = 0; transientAnswer = $false },
    [pscustomobject]@{ exitCode = 1 }
)
($cases | ForEach-Object { [bool](Test-FailcaseRejected -Details $_) }) | ConvertTo-Json -Compress
"""


@unittest.skipUnless(PWSH, "pwsh is not installed")
class FailcaseVerdict(unittest.TestCase):
    """reqspec.conda.dryrun.failcase must not pass on a provider answer: a 502 exits non-zero too."""

    def test_verdicts(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "run.ps1"
            script.write_text(FAILCASE_RUNNER.replace("{HELPER}", helper_text(_read())), encoding="ascii")
            p = subprocess.run(
                [PWSH, "-NoProfile", "-NonInteractive", "-File", str(script)],
                capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
            )
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
            # solver answer passes; transient answer does not; a zero exit is not a rejection; a missing flag counts as no transient
            self.assertEqual(json.loads(p.stdout.strip().splitlines()[-1]), [True, False, False, True])


if __name__ == "__main__":
    unittest.main()
