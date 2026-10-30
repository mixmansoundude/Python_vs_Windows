"""Item 35 (C6): the aggregate self-test verdict is a real gate, and nothing around it can hide a red row.

The "Enforce aggregate self-test verdict" step of the selftest-gate job turns any red row in any lane into a red
required check ("Aggregate self-test verdicts"). It was advisory (continue-on-error) from 2026-08-30 until the
baseline reds were fixed (CLAUDE.md Item 35, PR #491). These rules keep it that way and keep the pieces it
depends on in place:
- the step exists once, has no continue-on-error, runs on exactly `!cancelled() && has_failures == 'true'`
  (an extra `&& false` would leave it skipped for ever), and exits 1;
- the "Aggregate verdicts" step it reads has `id: aggregate` and writes `has_failures=` to $GITHUB_OUTPUT (without
  either, the condition is always false and the gate never runs);
- the lanes the aggregator expects are exactly the lanes in the selftest matrix (the list is written twice);
- selftest-gate, model-quick-fix and publish_diag still run after a failure, so the diagnostics site is
  published even when the gate is red (Item 35's non-negotiable constraint);
- a throwaway probe step ("TEMP PROBE ...", used to prove the gate on a real run) never reaches main;
- the NDJSON registry cross-check job gates too (no continue-on-error, the checker's exit code is not hidden), and the
  same check stays a unit test over the real repository, which is what lets the aggregate gate hold a PR on it.

The rules read batch-check.yml as plain text (no YAML dependency: the pytest step installs only pytest, pydantic
and requests, same style as test_run_tests_step.py). Synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"

GATE_STEP = "Enforce aggregate self-test verdict"
GATE_CONDITION = "${{ !cancelled() && steps.aggregate.outputs.has_failures == 'true' }}"


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
        if not cond or re.sub(r"\s+", " ", cond.group(1)).strip() != GATE_CONDITION:
            found.append("the aggregate gate step must run on exactly %s" % GATE_CONDITION)
        if not re.search(r"^\s*exit 1\s*$", block, re.MULTILINE):
            found.append("the aggregate gate step never exits 1")

    agg = [blk for name, blk in steps(gate) if name == "Aggregate verdicts"]
    if len(agg) != 1:
        found.append("selftest-gate must have exactly one Aggregate verdicts step (found %d)" % len(agg))
    else:
        agg_block = live(agg[0])
        if not re.search(r"^\s*id:\s*aggregate\s*$", agg_block, re.MULTILINE):
            found.append("the Aggregate verdicts step must have id: aggregate (the gate reads steps.aggregate.outputs)")
        if not re.search(r"has_failures=.*\$env:GITHUB_OUTPUT", agg_block):
            found.append("the Aggregate verdicts step must write has_failures= to $env:GITHUB_OUTPUT")

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


REGISTRY_JOB = "ndjson-registry-check"
REGISTRY_STEP = "Run NDJSON registry cross-check"
REGISTRY_TEST = REPO / "tests" / "test_check_ndjson_registry.py"


def registry_problems(text, registry_test_text):
    """The registry cross-check is a gate (Item 35): the job must be able to fail and the same check must also be a
    unit test of the real repository, because the job's own check is not a required status check."""
    found = []
    reg = job(text, REGISTRY_JOB)
    if reg is None:
        return ["there is no %s job" % REGISTRY_JOB]
    if re.search(r"^    continue-on-error:", live(reg), re.MULTILINE):
        found.append("%s has continue-on-error: a mismatch would stay green" % REGISTRY_JOB)
    if re.fullmatch(r"(?:\$\{\{\s*false\s*\}\}|false)", job_key(reg, "if") or ""):
        found.append("%s is disabled by an always-false condition: no check would ever run" % REGISTRY_JOB)
    blocks = [blk for name, blk in steps(reg) if name == REGISTRY_STEP]
    if len(blocks) != 1:
        found.append("%s must have exactly one step named %r (found %d)" % (REGISTRY_JOB, REGISTRY_STEP, len(blocks)))
    else:
        block = live(blocks[0])
        if "tools/check_ndjson_registry.py" not in block:
            found.append("the registry step does not run tools/check_ndjson_registry.py")
        if "set -o pipefail" not in block:
            found.append("the registry step needs set -o pipefail (the report is piped through tee, which would hide the exit code)")
        if re.search(r"\|\|\s*(?:true\b|:(?![A-Za-z0-9_])|exit\s+0\b)|continue-on-error:", block):
            found.append("the registry step hides the checker's exit code")
        if re.search(r"^\s*(?:-\s+)?if:\s*(?:\$\{\{\s*false\s*\}\}|false)\s*$", block, re.MULTILINE):
            found.append("the registry step is disabled by an always-false condition: the checker would never run")
    m = re.search(r"^def test_repo_rows_and_registry_agree\b.*?(?=^def |\Z)", registry_test_text, re.MULTILINE | re.DOTALL)
    if not m:
        found.append("tests/test_check_ndjson_registry.py lost test_repo_rows_and_registry_agree (the aggregate gate carries the check through it)")
    elif "check_ndjson_registry.main(" not in m.group(0) or not re.search(r"assert\s+result\s*==\s*0", m.group(0)):
        found.append("test_repo_rows_and_registry_agree no longer runs the checker and asserts its result is 0 (a test that only passes would carry nothing)")
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
        id: aggregate
        run: |
          & .\\tools\\aggregate_selftest_verdicts.ps1 `
            -ExpectedLanes @('real', 'uv') `
            -ReportPath $reportPath
          "has_failures=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding ascii -Append

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


GOOD_REGISTRY = """jobs_header_is_ignored: x
  ndjson-registry-check:
    name: NDJSON registry cross-check (doc vs code vs log)
    # continue-on-error was removed on purpose
    needs: [selftest]
    if: ${{ always() }}
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Run NDJSON registry cross-check
        shell: bash
        run: |
          set -o pipefail
          python3 tools/check_ndjson_registry.py --repo-root . | tee report.txt

      - name: Upload NDJSON registry report
        if: ${{ always() }}
        run: y
"""
GOOD_REGISTRY_TEST = (
    "def test_repo_rows_and_registry_agree(capsys):\n"
    "    result = check_ndjson_registry.main([\"--repo-root\", \".\"])\n"
    "    assert result == 0\n"
)


class RegistryCheckGates(unittest.TestCase):
    def test_workflow(self):
        self.assertEqual(
            registry_problems(WORKFLOW.read_text(encoding="utf-8"), REGISTRY_TEST.read_text(encoding="utf-8")), []
        )

    def test_good_shape_is_clean(self):
        self.assertEqual(registry_problems(GOOD_REGISTRY, GOOD_REGISTRY_TEST), [])

    def test_job_level_continue_on_error_is_caught(self):
        bad = GOOD_REGISTRY.replace("    runs-on: ubuntu-latest\n", "    runs-on: ubuntu-latest\n    continue-on-error: true\n")
        self.assertTrue(any("continue-on-error" in f for f in registry_problems(bad, GOOD_REGISTRY_TEST)))

    def test_job_level_false_condition_is_caught(self):
        bad = GOOD_REGISTRY.replace("    if: ${{ always() }}\n    runs-on", "    if: ${{ false }}\n    runs-on")
        self.assertNotEqual(bad, GOOD_REGISTRY)
        self.assertTrue(any("always-false" in f for f in registry_problems(bad, GOOD_REGISTRY_TEST)))

    def test_checker_step_false_condition_is_caught(self):
        bad = GOOD_REGISTRY.replace("        shell: bash\n", "        shell: bash\n        if: ${{ false }}\n")
        self.assertNotEqual(bad, GOOD_REGISTRY)
        self.assertTrue(any("always-false" in f for f in registry_problems(bad, GOOD_REGISTRY_TEST)))

    def test_step_level_continue_on_error_is_caught(self):
        bad = GOOD_REGISTRY.replace("        shell: bash\n", "        shell: bash\n        continue-on-error: true\n")
        self.assertTrue(any("hides" in f for f in registry_problems(bad, GOOD_REGISTRY_TEST)))

    def test_swallowed_exit_code_is_caught(self):
        bad = GOOD_REGISTRY.replace("| tee report.txt", "| tee report.txt || true")
        self.assertTrue(any("hides" in f for f in registry_problems(bad, GOOD_REGISTRY_TEST)))

    def test_colon_suppression_is_caught(self):
        for tail in ("|| :", "|| : # keep going", "||:", "|| true", "|| exit 0"):
            bad = GOOD_REGISTRY.replace("| tee report.txt", "| tee report.txt " + tail)
            self.assertTrue(any("hides" in f for f in registry_problems(bad, GOOD_REGISTRY_TEST)), tail)

    def test_missing_pipefail_is_caught(self):
        bad = GOOD_REGISTRY.replace("          set -o pipefail\n", "")
        self.assertTrue(any("pipefail" in f for f in registry_problems(bad, GOOD_REGISTRY_TEST)))

    def test_step_that_stops_running_the_checker_is_caught(self):
        bad = GOOD_REGISTRY.replace("tools/check_ndjson_registry.py", "tools/other.py")
        self.assertTrue(any("does not run" in f for f in registry_problems(bad, GOOD_REGISTRY_TEST)))

    def test_missing_job_is_caught(self):
        self.assertTrue(any("no ndjson-registry-check job" in f for f in registry_problems("x: y\n", GOOD_REGISTRY_TEST)))

    def test_repo_test_that_only_passes_is_caught(self):
        bad = registry_problems(GOOD_REGISTRY, "def test_repo_rows_and_registry_agree(capsys):\n    pass\n")
        self.assertTrue(any("no longer runs the checker" in f for f in bad), bad)

    def test_repo_test_that_does_not_assert_the_result_is_caught(self):
        body = "def test_repo_rows_and_registry_agree(capsys):\n    result = check_ndjson_registry.main([])\n"
        bad = registry_problems(GOOD_REGISTRY, body)
        self.assertTrue(any("no longer runs the checker" in f for f in bad), bad)

    def test_lost_repo_test_is_caught(self):
        bad = registry_problems(GOOD_REGISTRY, "def test_something_else():\n    pass\n")
        self.assertTrue(any("test_repo_rows_and_registry_agree" in f for f in bad), bad)


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

    def test_extra_false_conjunction_is_caught(self):
        bad = GOOD.replace("== 'true' }}", "== 'true' && false }}")
        self.assertTrue(any("must run on exactly" in f for f in problems(bad)), problems(bad))

    def test_condition_widened_with_or_is_caught(self):
        bad = GOOD.replace("== 'true' }}", "== 'true' || always() }}")
        self.assertTrue(any("must run on exactly" in f for f in problems(bad)), problems(bad))

    def test_aggregate_step_without_id_is_caught(self):
        bad = GOOD.replace("        id: aggregate\n", "")
        self.assertTrue(any("id: aggregate" in f for f in problems(bad)), problems(bad))

    def test_aggregate_step_without_output_write_is_caught(self):
        bad = GOOD.replace('          "has_failures=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding ascii -Append\n', "")
        self.assertTrue(any("GITHUB_OUTPUT" in f for f in problems(bad)), problems(bad))

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
