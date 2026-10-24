"""Item 35 (C6): the aggregate self-test verdict is a real gate, and nothing around it can hide a red row.

The "Enforce aggregate self-test verdict" step of the selftest-gate job turns any red row in any lane into a red
required check ("Aggregate self-test verdicts"). It was advisory (continue-on-error) from 2026-08-30 until the
baseline reds were fixed (CLAUDE.md Item 35, PR #491). These rules keep it that way and keep the pieces it
depends on in place:
- the step exists once, has no continue-on-error, runs unless cancelled, and exits 1;
- the lanes the aggregator expects are exactly the lanes in the selftest matrix (the list is written twice);
- selftest-gate, model-quick-fix and publish_diag still run after a failure, so the diagnostics site is
  published even when the gate is red (Item 35's non-negotiable constraint);
- a throwaway probe step ("TEMP PROBE ...", used to prove the gate on a real run) never reaches main.

The rules read batch-check.yml as plain text (no YAML dependency: the pytest step installs only pytest, pydantic
and requests, same style as test_run_tests_step.py). Synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"

GATE_STEP = "Enforce aggregate self-test verdict"


def live(text):
    """Drop comment-only lines so a rule cannot be satisfied (or tripped) by prose."""
    return "\n".join(ln for ln in text.splitlines() if not ln.strip().startswith("#"))


def job(text, name):
    """Text of one top-level job (from its two-space header to the next header), or None."""
    lines = text.splitlines()
    start = None
    for i, ln in enumerate(lines):
        if re.match(r"^  %s:\s*$" % re.escape(name), ln):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[j]) or re.match(r"^\S", lines[j]):
            end = j
            break
    return "\n".join(lines[start:end])


def steps(job_text):
    """(name, block) for every step of a job."""
    lines = job_text.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    out = []
    for n, s in enumerate(starts):
        e = starts[n + 1] if n + 1 < len(starts) else len(lines)
        name = re.sub(r"^      - name:\s*", "", lines[s]).strip().strip('"').strip("'")
        out.append((name, "\n".join(lines[s:e])))
    return out


def job_key(job_text, key):
    """The value of a job-level key written as `    key: value` (four-space indent), or None."""
    m = re.search(r"^    %s:\s*(.+?)\s*$" % re.escape(key), live(job_text), re.MULTILINE)
    return m.group(1) if m else None


def matrix_modes(text):
    sel = job(text, "selftest")
    if sel is None:
        return None
    return re.findall(r"^          - mode:\s*([A-Za-z0-9_-]+)\s*$", live(sel), re.MULTILINE)


def expected_lanes(gate_job):
    for name, block in steps(gate_job):
        if name == "Aggregate verdicts":
            m = re.search(r"-ExpectedLanes\s+@\(([^)]*)\)", live(block))
            if not m:
                return None
            return re.findall(r"'([^']+)'", m.group(1))
    return None


def problems(text):
    found = []
    gate = job(text, "selftest-gate")
    if gate is None:
        return ["there is no selftest-gate job"]
    if job_key(gate, "if") != "${{ always() }}":
        found.append("selftest-gate must run with if: ${{ always() }} (a lane that died has to turn the gate red)")
    if job_key(gate, "needs") != "[selftest]":
        found.append("selftest-gate must need exactly [selftest]")

    gate_steps = [blk for name, blk in steps(gate) if name == GATE_STEP]
    if len(gate_steps) != 1:
        found.append("selftest-gate must have exactly one step named %r (found %d)" % (GATE_STEP, len(gate_steps)))
    else:
        block = live(gate_steps[0])
        if re.search(r"^\s*continue-on-error:", block, re.MULTILINE):
            found.append("the aggregate gate step has continue-on-error: it would stay green with a red row")
        cond = re.search(r"^\s*if:\s*(.+)$", block, re.MULTILINE)
        if not cond or "!cancelled()" not in cond.group(1) or "steps.aggregate.outputs.has_failures == 'true'" not in cond.group(1):
            found.append("the aggregate gate step must run on !cancelled() and has_failures == 'true'")
        if not re.search(r"^\s*exit 1\s*$", block, re.MULTILINE):
            found.append("the aggregate gate step never exits 1")

    modes = matrix_modes(text)
    lanes = expected_lanes(gate)
    if not modes:
        found.append("could not read the selftest matrix modes")
    elif lanes is None:
        found.append("could not read -ExpectedLanes from the Aggregate verdicts step")
    elif sorted(modes) != sorted(lanes):
        found.append("-ExpectedLanes %s differs from the selftest matrix %s" % (sorted(lanes), sorted(modes)))

    mqf = job(text, "model-quick-fix")
    if mqf is None or job_key(mqf, "if") != "${{ always() }}":
        found.append("model-quick-fix must run with if: ${{ always() }}")
    pub = job(text, "publish_diag")
    if pub is None:
        found.append("there is no publish_diag job")
    else:
        if job_key(pub, "if") != "${{ always() }}":
            found.append("publish_diag must run with if: ${{ always() }} so the diagnostics site is published after a red gate")
        needs = job_key(pub, "needs") or ""
        for must in ("selftest", "selftest-gate", "model-quick-fix"):
            if not re.search(r"(?<![A-Za-z0-9_-])%s(?![A-Za-z0-9_-])" % re.escape(must), needs):
                found.append("publish_diag must need %s (needs: %s)" % (must, needs))

    for job_name in re.findall(r"^  ([A-Za-z0-9_-]+):\s*$", text, re.MULTILINE):
        for name, _ in steps(job(text, job_name) or ""):
            if name.upper().startswith("TEMP PROBE"):
                found.append("a throwaway probe step is still in the workflow: %r" % name)
    return found


GOOD = """jobs_header_is_ignored: x
  selftest:
    strategy:
      matrix:
        include:
          - mode: real
          - mode: uv
    steps:
      - name: Something
        run: echo hi

  selftest-gate:
    name: Aggregate self-test verdicts
    needs: [selftest]
    if: ${{ always() }}
    steps:
      - name: Aggregate verdicts
        run: |
          & .\\tools\\aggregate_selftest_verdicts.ps1 `
            -ExpectedLanes @('real', 'uv') `
            -ReportPath $reportPath

      - name: Enforce aggregate self-test verdict
        if: ${{ !cancelled() && steps.aggregate.outputs.has_failures == 'true' }}
        shell: bash
        run: |
          echo "failing this check."
          exit 1

  model-quick-fix:
    if: ${{ always() }}
    steps:
      - name: x
        run: y

  publish_diag:
    needs: [selftest, selftest-gate, model-quick-fix]
    if: ${{ always() }}
    steps:
      - name: x
        run: y
"""


class AggregateGateStaysReal(unittest.TestCase):
    def test_workflow(self):
        self.assertEqual(problems(WORKFLOW.read_text(encoding="utf-8")), [])

    def test_good_shape_is_clean(self):
        self.assertEqual(problems(GOOD), [])

    def test_continue_on_error_is_caught(self):
        bad = GOOD.replace("        shell: bash\n        run: |\n          echo \"failing", "        continue-on-error: true\n        shell: bash\n        run: |\n          echo \"failing")
        self.assertTrue(any("continue-on-error" in f for f in problems(bad)), problems(bad))

    def test_continue_on_error_in_a_comment_is_fine(self):
        ok = GOOD.replace("      - name: Enforce aggregate", "      # continue-on-error: true was removed on purpose\n      - name: Enforce aggregate")
        self.assertEqual(problems(ok), [])

    def test_missing_step_is_caught(self):
        bad = GOOD.replace("Enforce aggregate self-test verdict", "Something else")
        self.assertTrue(any("exactly one step" in f for f in problems(bad)), problems(bad))

    def test_step_that_cannot_fail_is_caught(self):
        bad = GOOD.replace("          exit 1\n", "          exit 0\n")
        self.assertTrue(any("never exits 1" in f for f in problems(bad)), problems(bad))

    def test_condition_without_has_failures_is_caught(self):
        bad = GOOD.replace("steps.aggregate.outputs.has_failures == 'true'", "true")
        self.assertTrue(any("must run on" in f for f in problems(bad)), problems(bad))

    def test_condition_without_not_cancelled_is_caught(self):
        bad = GOOD.replace("!cancelled() && ", "")
        self.assertTrue(any("must run on" in f for f in problems(bad)), problems(bad))

    def test_lane_list_drift_is_caught(self):
        bad = GOOD.replace("-ExpectedLanes @('real', 'uv')", "-ExpectedLanes @('real')")
        self.assertTrue(any("differs from the selftest matrix" in f for f in problems(bad)), problems(bad))

    def test_new_matrix_lane_is_caught(self):
        bad = GOOD.replace("          - mode: uv\n", "          - mode: uv\n          - mode: extra\n")
        self.assertTrue(any("differs from the selftest matrix" in f for f in problems(bad)), problems(bad))

    def test_gate_job_that_skips_after_failure_is_caught(self):
        bad = GOOD.replace("    needs: [selftest]\n    if: ${{ always() }}", "    needs: [selftest]\n    if: ${{ success() }}")
        self.assertTrue(any("selftest-gate must run" in f for f in problems(bad)), problems(bad))

    def test_publish_that_would_be_skipped_is_caught(self):
        bad = GOOD.replace("    needs: [selftest, selftest-gate, model-quick-fix]\n    if: ${{ always() }}", "    needs: [selftest, selftest-gate, model-quick-fix]\n    if: ${{ success() }}")
        self.assertTrue(any("publish_diag must run" in f for f in problems(bad)), problems(bad))

    def test_publish_that_stops_waiting_for_the_gate_is_caught(self):
        bad = GOOD.replace("needs: [selftest, selftest-gate, model-quick-fix]", "needs: [selftest, model-quick-fix]")
        self.assertTrue(any("publish_diag must need selftest-gate" in f for f in problems(bad)), problems(bad))

    def test_model_quick_fix_that_skips_is_caught(self):
        bad = GOOD.replace("  model-quick-fix:\n    if: ${{ always() }}", "  model-quick-fix:\n    if: ${{ success() }}")
        self.assertTrue(any("model-quick-fix must run" in f for f in problems(bad)), problems(bad))

    def test_leftover_probe_is_caught(self):
        bad = GOOD.replace("      - name: Something\n", "      - name: TEMP PROBE gate\n")
        self.assertTrue(any("throwaway probe" in f for f in problems(bad)), problems(bad))


if __name__ == "__main__":
    unittest.main()
