"""The worst case of the Pages deploy retries must fit inside the `publish_diag` job's own time limit.

`publish_diag` publishes the diagnostics site and promises to survive any red lane (CLAUDE.md Item 35). Its last steps deploy
the Pages artifact up to three times: attempt 1, a short wait, attempt 2, a long wait, attempt 3. `actions/deploy-pages`
gives up on one attempt after its `timeout` input, which is 600000 ms (ten minutes) when nothing sets it. In run
42384855330 the Pages backend left both of the first two attempts running until that limit (606 s and 604 s), the long wait
began at about 22 minutes and the job's 40 minute limit cancelled it in the middle: the job ended as cancelled and no third
attempt ever ran. Worst case with the old values: about 3 minutes of setup, 3 x 10 minutes of attempts, 30 seconds and
20 minutes of waiting, about 54 minutes against 40.

The rule pinned here is arithmetic over the workflow text: setup budget + every deploy step's timeout + every
`run: sleep N` between them must be at most `timeout-minutes`, and every deploy step sets its `timeout` itself so the
default is never silently part of the sum. Synthetic cases prove each rule can fail; the one named after the real run
shows the old shape is refused.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
JOB = "publish_diag"
# Seconds from the job's start to the first deploy step: run 42384855330 had about 100 s of steps over 20 seconds and a
# 64 s artifact download; five minutes leaves room for a slow runner.
SETUP_BUDGET_SECONDS = 300
DEPLOY_DEFAULT_TIMEOUT_MS = 600000  # actions/deploy-pages input `timeout` when it is not set


def job_block(text, name=JOB):
    """The lines of the job called `name`, from its `  name:` line to the next job or the end of the file."""
    lines = text.splitlines()
    start = [i for i, ln in enumerate(lines) if ln == "  %s:" % name]
    if len(start) != 1:
        return None
    end = len(lines)
    for i in range(start[0] + 1, len(lines)):
        if re.match(r"^  [A-Za-z_][A-Za-z0-9_-]*:\s*$", lines[i]):
            end = i
            break
    return "\n".join(lines[start[0]:end])


def step_blocks(job):
    lines = job.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - (name|uses|id):", ln)]
    out = []
    for n, s in enumerate(starts):
        e = starts[n + 1] if n + 1 < len(starts) else len(lines)
        out.append("\n".join(lines[s:e]))
    return out


def budget_problems(text):
    job = job_block(text)
    if job is None:
        return ["the job %s must exist exactly once" % JOB]
    found = []
    limit = re.search(r"^    timeout-minutes:\s*(\d+)\s*$", job, re.MULTILINE)
    if not limit:
        return ["the job %s has no timeout-minutes" % JOB]
    limit_s = int(limit.group(1)) * 60
    deploys = [b for b in step_blocks(job) if re.search(r"uses:\s*actions/deploy-pages@", b)]
    if not deploys:
        return ["the job %s has no actions/deploy-pages step" % JOB]
    total = SETUP_BUDGET_SECONDS
    for b in deploys:
        m = re.search(r"^\s+timeout:\s*(\d+)\s*$", b, re.MULTILINE)
        if not m:
            found.append("a deploy-pages step sets no timeout, so the %d ms default is part of the sum: %s"
                         % (DEPLOY_DEFAULT_TIMEOUT_MS, b.splitlines()[0].strip()))
            total += DEPLOY_DEFAULT_TIMEOUT_MS // 1000
        else:
            total += int(m.group(1)) // 1000
    for b in step_blocks(job):
        m = re.search(r"^\s+run:\s*sleep\s+(\d+)\s*$", b, re.MULTILINE)
        if m:
            total += int(m.group(1))
    if total > limit_s:
        found.append("worst case of the deploy retries is %d s (setup %d s included) but the job's limit is %d s"
                     % (total, SETUP_BUDGET_SECONDS, limit_s))
    return found


def mutate(text, old, new):
    assert text.count(old) == 1, "anchor must occur exactly once: %r (found %d)" % (old[:60], text.count(old))
    return text.replace(old, new)


GOOD = """jobs:
  other:
    timeout-minutes: 5
    steps:
      - name: x
        run: sleep 9999
  publish_diag:
    timeout-minutes: 40
    steps:
      - name: Deploy (attempt 1)
        uses: actions/deploy-pages@v5
        with:
          timeout: 300000
      - name: Wait (short)
        shell: bash
        run: sleep 30
      - name: Deploy (attempt 2)
        uses: actions/deploy-pages@v5
        with:
          timeout: 300000
      - name: Wait (long)
        shell: bash
        run: sleep 600
      - name: Deploy (attempt 3, final)
        uses: actions/deploy-pages@v5
        with:
          timeout: 600000
"""


class RealWorkflow(unittest.TestCase):
    def test_the_workflow_fits_its_time_limit(self):
        text = WORKFLOW.read_text(encoding="utf-8", errors="replace")
        self.assertEqual(budget_problems(text), [])

    def test_the_job_has_three_deploy_attempts(self):
        job = job_block(WORKFLOW.read_text(encoding="utf-8", errors="replace"))
        self.assertIsNotNone(job)
        self.assertEqual(len([b for b in step_blocks(job) if "actions/deploy-pages@" in b]), 3)


class EachRuleCanFail(unittest.TestCase):
    def test_the_good_shape_is_clean(self):
        self.assertEqual(budget_problems(GOOD), [])

    def test_the_other_job_does_not_count(self):
        self.assertIn("sleep 9999", GOOD)
        self.assertEqual(budget_problems(GOOD), [])

    def test_the_old_shape_of_run_42384855330_is_refused(self):
        old = GOOD.replace("          timeout: 300000\n", "").replace("          timeout: 600000\n", "").replace("sleep 600", "sleep 1200")
        found = budget_problems(old)
        self.assertTrue(any("sets no timeout" in f for f in found), found)
        self.assertTrue(any("worst case" in f for f in found), found)

    def test_a_long_wait_alone_is_refused(self):
        found = budget_problems(mutate(GOOD, "sleep 600", "sleep 1500"))
        self.assertTrue(any("worst case" in f for f in found), found)
        self.assertFalse(any("sets no timeout" in f for f in found), found)

    def test_a_longer_attempt_alone_is_refused(self):
        found = budget_problems(mutate(GOOD, "timeout: 600000", "timeout: 1500000"))
        self.assertTrue(any("worst case" in f for f in found), found)

    def test_a_missing_timeout_alone_is_named(self):
        found = budget_problems(mutate(GOOD, "        with:\n          timeout: 600000\n", ""))
        self.assertTrue(any("sets no timeout" in f for f in found), found)

    def test_a_shorter_job_limit_is_refused(self):
        found = budget_problems(mutate(GOOD, "  publish_diag:\n    timeout-minutes: 40", "  publish_diag:\n    timeout-minutes: 20"))
        self.assertTrue(any("worst case" in f for f in found), found)

    def test_a_missing_job_limit_is_named(self):
        found = budget_problems(mutate(GOOD, "  publish_diag:\n    timeout-minutes: 40\n", "  publish_diag:\n"))
        self.assertEqual(found, ["the job publish_diag has no timeout-minutes"])

    def test_a_missing_job_is_named(self):
        found = budget_problems(GOOD.replace("  publish_diag:", "  other_diag:"))
        self.assertEqual(found, ["the job publish_diag must exist exactly once"])

    def test_no_deploy_step_is_named(self):
        found = budget_problems(GOOD.replace("actions/deploy-pages@v5", "actions/other@v5"))
        self.assertEqual(found, ["the job publish_diag has no actions/deploy-pages step"])


if __name__ == "__main__":
    unittest.main()
