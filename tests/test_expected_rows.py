"""Items 98 and 104: the aggregate gate also fails on a row that was never written.

"Aggregate self-test verdicts" fails on a row with pass:false. A row that was never written cannot be red, so a
selfapps script that crashed before its first row, failed to parse, or whose step stopped running left no trace in a
lane whose step has continue-on-error (Item 84 found it for the self-tests, Item 95 for the cache health check).
tests/expected_rows/<lane>.txt lists the row ids each lane must have written before run_tests.bat, and
tools/check_expected_rows.py compares the list with the lane's ci_test_results artifact inside the selftest-gate job.

Item 104 repeats it for the file run_tests.bat leaves behind (tests/~test-results.ndjson: the harness `batch.*` rows and
what selftest.ps1 and selftests.ps1 append). harness.ps1 deletes and rewrites that file, so none of those rows are in the
pre-harness snapshot the first lists read. A small artifact post_harness_rows-selftest-<lane>-<run>-<attempt> carries it
(uploaded after the meta row is appended), tests/expected_rows_post/<lane>.txt lists the ids, and the same tool checks it
with --stage post from the same step.

What this file keeps true:
- the tool: a complete lane passes, a missing id / a lane with no results / an unusable baseline fail with a message that
  names the lane and the id, unlisted rows and the gate's own artifact are fine, the cache lane's own infrastructure-skip
  rows waive only the cache lane, generate writes the ids present in every run it is given; both of that for --stage post,
  which reads another artifact name and prints another console tag, and never takes one stage's artifact for the other's;
- the baseline in the repository (tests/expected_rows and, for the post-harness file, tests/expected_rows_post): one file
  per selftest matrix lane, sorted, no duplicates, ASCII with LF endings, every id registered in docs/agent-ndjson.md (so a
  PR that removes or renames a row is told to update the list here, locally, and not after a 2.5 hour run);
- the wiring in batch-check.yml: the lane NDJSON is downloaded without merge-multiple before the aggregate step, the
  check runs from that step, starts from a failing exit code and a cleared $LASTEXITCODE (python missing must not read as
  success), and its result joins has_failures, which the enforce step (tests/test_aggregate_gate.py) turns into a red check;
  the same for the post-harness file (its own download, its own exit code cleared and initialised, joined in the same
  expression), and in the matrix job the step that uploads that file runs after run_tests.bat and after the meta row, on
  a name the tool and the gate's download pattern both read, and nothing writes the file after it.

The workflow is read as plain text (the pytest step installs no YAML library). Synthetic cases prove each rule can fail.
"""
import fnmatch
import io
import json
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tools import check_expected_rows as cer
from tools import check_ndjson_registry

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
BASELINE = REPO / "tests" / "expected_rows"
POST_BASELINE = REPO / "tests" / "expected_rows_post"
REGISTRY_DOC = REPO / "docs" / "agent-ndjson.md"
SELFTESTS = REPO / "tests" / "selftests.ps1"
TOOL = REPO / "tools" / "check_expected_rows.py"

# derived requirement: a "probe." id is how the gate is proved on a real run (a throwaway id in one baseline file that no
# code writes, as tests/test_aggregate_gate.py's TEMP PROBE steps were for the enforce step). It is registered nowhere and
# must never be merged: with one in a list the gate would be red on every run, so the lists are checked for it below.
PROBE_PREFIX = "probe."


def probe_ids(per_lane):
    """The throwaway ids a baseline still lists, as readable problem lines."""
    return ["%s lists the throwaway id %s" % (lane, rid)
            for lane, ids in sorted(per_lane.items()) for rid in ids if rid.startswith(PROBE_PREFIX)]


def rows_written_twice(selftests_text):
    """Ids tests/selftests.ps1 writes as literals. It runs twice per lane (its own workflow step, then run_tests.bat), so
    these rows are in the pre-harness snapshot and in the post-harness file; every other row has one home."""
    return set(re.findall(r"\bid\s*=\s*'([A-Za-z0-9][A-Za-z0-9_.~-]*)'", selftests_text))


def folder_overlap(pre, post, twice):
    """Problems with where the ids of the two folders sit: a batch.* row in a pre list (harness.ps1 writes it after the snapshot,
    so it could never be there) and an id in both folders that selftests.ps1 does not write twice."""
    problems = []
    for lane in sorted(pre):
        for rid in pre[lane]:
            if rid.startswith("batch."):
                problems.append("%s lists %s before run_tests.bat, but harness.ps1 writes it after the snapshot" % (lane, rid))
    for lane in sorted(post):
        for rid in post[lane]:
            if rid in pre.get(lane, []) and rid not in twice:
                problems.append("%s lists %s in both folders, and selftests.ps1 does not write it twice" % (lane, rid))
    return problems


ARTIFACT_PREFIX = {"pre": "ci_test_results", "post": "post_harness_rows"}


def write_lane(results, lane, ids, run="100", attempt="1", extra_lines=(), stage="pre"):
    folder = Path(results) / ("%s-selftest-%s-%s-%s" % (ARTIFACT_PREFIX[stage], lane, run, attempt))
    folder.mkdir(parents=True, exist_ok=True)
    lines = ["not json at all", "{broken", json.dumps({"pass": True, "desc": "a row with no id"})]
    lines += [json.dumps({"id": rid, "pass": True}) for rid in ids]
    lines += list(extra_lines)
    (folder / "~test-results.ndjson").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return folder


def write_baseline(folder, per_lane):
    Path(folder).mkdir(parents=True, exist_ok=True)
    for lane, ids in per_lane.items():
        (Path(folder) / (lane + ".txt")).write_text("# header\n\n" + "\n".join(ids) + "\n", encoding="ascii")


def run_main(argv):
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = cer.main(argv)
    return rc, buf.getvalue()


class Tmp(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.tmp = Path(self._td.name)
        self.results = self.tmp / "results"
        self.baseline = self.tmp / "baseline"
        self.results.mkdir()

    def check(self, report=None, stage=None):
        argv = ["check", "--results", str(self.results), "--baseline", str(self.baseline)]
        if stage:
            argv += ["--stage", stage]
        if report:
            argv += ["--report", str(report)]
        return run_main(argv)


class ToolChecksALane(Tmp):
    def test_complete_lanes_pass(self):
        write_baseline(self.baseline, {"real": ["a.one", "a.two"], "uv": ["b.one"]})
        write_lane(self.results, "real", ["a.one", "a.two"])
        write_lane(self.results, "uv", ["b.one"])
        rc, out = self.check()
        self.assertEqual(rc, 0, out)
        self.assertIn("every listed row was written", out)

    def test_missing_row_fails_and_names_lane_and_id(self):
        write_baseline(self.baseline, {"real": ["a.one", "a.two"], "uv": ["b.one"]})
        write_lane(self.results, "real", ["a.one"])
        write_lane(self.results, "uv", ["b.one"])
        rc, out = self.check()
        self.assertEqual(rc, 1, out)
        self.assertIn("expected-rows: MISSING lane=real id=a.two", out)
        self.assertNotIn("MISSING lane=uv", out)
        self.assertIn("expected-rows: FAILED", out)

    def test_lane_with_no_artifact_fails(self):
        write_baseline(self.baseline, {"real": ["a.one"], "uv": ["b.one"]})
        write_lane(self.results, "real", ["a.one"])
        rc, out = self.check()
        self.assertEqual(rc, 1, out)
        self.assertIn("lane uv: NO ci_test_results artifact", out)

    def test_missing_results_folder_fails_every_lane(self):
        write_baseline(self.baseline, {"real": ["a.one"], "uv": ["b.one"]})
        rc, out = run_main(["check", "--results", str(self.tmp / "nowhere"), "--baseline", str(self.baseline)])
        self.assertEqual(rc, 1, out)
        self.assertIn("lane real: NO ci_test_results artifact", out)
        self.assertIn("lane uv: NO ci_test_results artifact", out)

    def test_empty_artifact_fails(self):
        write_baseline(self.baseline, {"real": ["a.one"]})
        write_lane(self.results, "real", [])
        rc, out = self.check()
        self.assertEqual(rc, 1, out)
        self.assertIn("MISSING lane=real id=a.one", out)

    def test_unlisted_rows_and_the_gate_artifact_are_fine(self):
        write_baseline(self.baseline, {"real": ["a.one"]})
        write_lane(self.results, "real", ["a.one", "a.new", "a.newer"])
        write_lane(self.results, "gate", ["diag.selftest_gate.verdict"])
        rc, out = self.check()
        self.assertEqual(rc, 0, out)
        self.assertIn("2 not listed", out)
        self.assertNotIn("no baseline file", out)

    def test_lane_without_a_baseline_file_is_reported_not_failed(self):
        write_baseline(self.baseline, {"real": ["a.one"]})
        write_lane(self.results, "real", ["a.one"])
        write_lane(self.results, "newlane", ["x.one"])
        rc, out = self.check()
        self.assertEqual(rc, 0, out)
        self.assertIn("no baseline file: newlane", out)

    def test_lane_names_with_hyphens_are_read_whole(self):
        write_baseline(self.baseline, {"contract-uv-fail": ["c.one"], "contract-uv": ["d.one"]})
        write_lane(self.results, "contract-uv-fail", ["c.one"], run="41171609830", attempt="2")
        write_lane(self.results, "contract-uv", ["d.one"], run="41171609830", attempt="2")
        rc, out = self.check()
        self.assertEqual(rc, 0, out)

    def test_folders_that_are_not_lane_artifacts_are_ignored(self):
        write_baseline(self.baseline, {"real": ["a.one"]})
        write_lane(self.results, "real", ["a.one"])
        other = self.results / "selftest-verdict-real-100-1"
        other.mkdir()
        (other / "x.ndjson").write_text(json.dumps({"id": "z.other"}) + "\n", encoding="utf-8")
        self.assertEqual(sorted(cer.read_run(str(self.results))), ["real"])

    def test_two_artifacts_of_one_lane_are_united(self):
        write_baseline(self.baseline, {"real": ["a.one", "a.two"]})
        write_lane(self.results, "real", ["a.one"], attempt="1")
        write_lane(self.results, "real", ["a.two"], attempt="2")
        rc, out = self.check()
        self.assertEqual(rc, 0, out)

    def test_an_id_must_match_whole_not_as_a_prefix(self):
        write_baseline(self.baseline, {"real": ["a.one"]})
        write_lane(self.results, "real", ["a.one.sub", "a.one2"])
        rc, out = self.check()
        self.assertEqual(rc, 1, out)

    def test_a_row_id_of_the_wrong_type_is_not_an_id(self):
        write_baseline(self.baseline, {"real": ["a.one"]})
        write_lane(self.results, "real", [], extra_lines=[json.dumps({"id": ["a.one"]}), json.dumps({"id": 7}),
                                                           json.dumps(["a.one"]), json.dumps({"id": ""})])
        rc, out = self.check()
        self.assertEqual(rc, 1, out)

    def test_long_missing_list_is_cut(self):
        ids = ["m.%03d" % n for n in range(45)]
        write_baseline(self.baseline, {"real": ids})
        write_lane(self.results, "real", [])
        rc, out = self.check()
        self.assertEqual(rc, 1, out)
        self.assertEqual(out.count("MISSING lane=real"), cer.SHOW)
        self.assertIn("and 5 more missing in lane real", out)

    def test_report_file_is_written(self):
        write_baseline(self.baseline, {"real": ["a.one", "a.two"]})
        write_lane(self.results, "real", ["a.one"])
        report = self.tmp / "report.json"
        rc, _ = self.check(report=report)
        self.assertEqual(rc, 1)
        data = json.loads(report.read_text(encoding="ascii"))
        self.assertTrue(data["has_failures"])
        self.assertEqual(data["lanes"]["real"]["missing"], ["a.two"])

    def test_output_is_ascii(self):
        write_baseline(self.baseline, {"real": ["a.one"], "uv": ["b.one"]})
        write_lane(self.results, "real", [])
        _rc, out = self.check()
        out.encode("ascii")


class ToolWaivesOnlyTheCacheLane(Tmp):
    def test_cache_lane_that_reported_its_own_skip_is_waived(self):
        write_baseline(self.baseline, {"cache": ["a.one", "a.two"], "real": ["r.one"]})
        write_lane(self.results, "cache", ["self.cache.corrupted"])
        write_lane(self.results, "real", ["r.one"])
        rc, out = self.check()
        self.assertEqual(rc, 0, out)
        self.assertIn("lane cache: waived", out)

    def test_the_bootstrap_failed_row_waives_too(self):
        write_baseline(self.baseline, {"cache": ["a.one"]})
        write_lane(self.results, "cache", ["self.cache.bootstrap.failed"])
        rc, out = self.check()
        self.assertEqual(rc, 0, out)

    def test_a_waiver_row_in_another_lane_waives_nothing(self):
        write_baseline(self.baseline, {"real": ["a.one"]})
        write_lane(self.results, "real", ["self.cache.corrupted"])
        rc, out = self.check()
        self.assertEqual(rc, 1, out)
        self.assertIn("MISSING lane=real id=a.one", out)

    def test_a_cache_lane_without_the_waiver_row_is_checked(self):
        write_baseline(self.baseline, {"cache": ["a.one", "a.two"]})
        write_lane(self.results, "cache", ["a.one"])
        rc, out = self.check()
        self.assertEqual(rc, 1, out)
        self.assertIn("MISSING lane=cache id=a.two", out)

    def test_a_waived_lane_with_no_artifact_is_still_a_failure(self):
        write_baseline(self.baseline, {"cache": ["a.one"]})
        rc, out = self.check()
        self.assertEqual(rc, 1, out)


class ToolRefusesUnusableInput(Tmp):
    def test_baseline_line_that_is_not_an_id(self):
        write_baseline(self.baseline, {"real": ["a.one", "bad id with spaces"]})
        write_lane(self.results, "real", ["a.one"])
        rc, out = self.check()
        self.assertEqual(rc, 2, out)
        self.assertIn("is not a row id", out)

    def test_baseline_folder_missing(self):
        rc, out = run_main(["check", "--results", str(self.results), "--baseline", str(self.tmp / "nope")])
        self.assertEqual(rc, 2, out)

    def test_baseline_folder_without_lane_files(self):
        self.baseline.mkdir()
        (self.baseline / "README.md").write_text("x\n", encoding="ascii")
        rc, out = self.check()
        self.assertEqual(rc, 2, out)
        self.assertIn("no baseline files", out)

    def test_non_ascii_baseline_is_unusable(self):
        self.baseline.mkdir()
        (self.baseline / "real.txt").write_bytes(b"a.one\n\xe2\x80\x9d\n")
        rc, out = self.check()
        self.assertEqual(rc, 2, out)

    def test_command_line_runs_as_a_script(self):
        write_baseline(self.baseline, {"real": ["a.one"]})
        write_lane(self.results, "real", ["a.one"])
        cmd = [sys.executable, str(TOOL), "check", "--results", str(self.results), "--baseline", str(self.baseline)]
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        (self.results / "ci_test_results-selftest-real-100-1" / "~test-results.ndjson").write_text("", encoding="utf-8")
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("MISSING lane=real id=a.one", done.stdout)


class ToolGeneratesTheBaseline(Tmp):
    def test_ids_present_in_every_run_are_kept(self):
        run_a, run_b = self.tmp / "run_a", self.tmp / "run_b"
        run_a.mkdir()
        run_b.mkdir()
        write_lane(run_a, "real", ["a.one", "a.two", "only.in.a"])
        write_lane(run_b, "real", ["a.one", "a.two", "only.in.b"])
        write_lane(run_a, "uv", ["u.one"])
        write_lane(run_b, "uv", ["u.one"])
        rc, _ = run_main(["generate", "--results", str(run_a), str(run_b), "--baseline", str(self.baseline)])
        self.assertEqual(rc, 0)
        self.assertEqual(cer.read_baseline(str(self.baseline)), {"real": ["a.one", "a.two"], "uv": ["u.one"]})
        for run in (run_a, run_b):
            rc, out = run_main(["check", "--results", str(run), "--baseline", str(self.baseline)])
            self.assertEqual(rc, 0, out)

    def test_ids_are_sorted_and_the_header_names_the_runs(self):
        run_a = self.tmp / "run_a"
        run_a.mkdir()
        write_lane(run_a, "real", ["z.last", "a.first", "m.middle"])
        run_main(["generate", "--results", str(run_a), "--baseline", str(self.baseline)])
        text = (self.baseline / "real.txt").read_text(encoding="ascii")
        self.assertEqual([ln for ln in text.splitlines() if not ln.startswith("#")], ["a.first", "m.middle", "z.last"])
        self.assertIn("run_a", text)
        self.assertNotIn("\r", text)

    def test_waived_cache_run_and_gate_artifact_are_skipped(self):
        run_a, run_b = self.tmp / "run_a", self.tmp / "run_b"
        run_a.mkdir()
        run_b.mkdir()
        write_lane(run_a, "cache", ["c.one", "c.two"])
        write_lane(run_b, "cache", ["self.cache.corrupted"])
        write_lane(run_a, "gate", ["diag.selftest_gate.verdict"])
        run_main(["generate", "--results", str(run_a), str(run_b), "--baseline", str(self.baseline)])
        self.assertEqual(cer.read_baseline(str(self.baseline)), {"cache": ["c.one", "c.two"]})

    def test_no_artifacts_is_unusable(self):
        empty = self.tmp / "empty"
        empty.mkdir()
        rc, out = run_main(["generate", "--results", str(empty), "--baseline", str(self.baseline)])
        self.assertEqual(rc, 2, out)

    def test_a_run_without_a_lane_is_rejected_and_nothing_is_written(self):
        # derived requirement: "ids present in every run" must hold for every lane; a run that lacks a lane's
        # artifact would otherwise be left out of that lane's intersection while the header still named it.
        run_a, run_b = self.tmp / "run_a", self.tmp / "run_b"
        run_a.mkdir()
        run_b.mkdir()
        write_lane(run_a, "real", ["a.one"])
        write_lane(run_a, "uv", ["u.one"])
        write_lane(run_b, "real", ["a.one"])
        rc, out = run_main(["generate", "--results", str(run_a), str(run_b), "--baseline", str(self.baseline)])
        self.assertEqual(rc, 2, out)
        self.assertIn("uv", out)
        self.assertIn("run_b", out)
        self.assertEqual(list(self.baseline.glob("*.txt")) if self.baseline.exists() else [], [],
                         "a rejected input must not leave a half-written baseline")

    def test_a_lane_waived_in_every_run_is_rejected_and_nothing_is_written(self):
        # otherwise an existing cache.txt would stay in place unchanged and the command would report success
        run_a, run_b = self.tmp / "run_a", self.tmp / "run_b"
        run_a.mkdir()
        run_b.mkdir()
        for run in (run_a, run_b):
            write_lane(run, "cache", ["self.cache.bootstrap.failed"])
            write_lane(run, "real", ["a.one"])
        rc, out = run_main(["generate", "--results", str(run_a), str(run_b), "--baseline", str(self.baseline)])
        self.assertEqual(rc, 2, out)
        self.assertIn("cache", out)
        self.assertEqual(list(self.baseline.glob("*.txt")) if self.baseline.exists() else [], [])

    def test_the_header_names_only_the_runs_a_lane_was_built_from(self):
        run_a, run_b = self.tmp / "run_a", self.tmp / "run_b"
        run_a.mkdir()
        run_b.mkdir()
        write_lane(run_a, "cache", ["c.one"])
        write_lane(run_b, "cache", ["self.cache.corrupted"])
        write_lane(run_a, "real", ["a.one"])
        write_lane(run_b, "real", ["a.one"])
        rc, out = run_main(["generate", "--results", str(run_a), str(run_b), "--baseline", str(self.baseline)])
        self.assertEqual(rc, 0, out)
        cache = (self.baseline / "cache.txt").read_text(encoding="ascii")
        real = (self.baseline / "real.txt").read_text(encoding="ascii")
        header = lambda text: [ln for ln in text.splitlines() if ln.startswith("# Generated by")][0]
        self.assertIn("run_a", header(cache))
        self.assertNotIn("run_b", header(cache))
        self.assertIn("run_a", header(real))
        self.assertIn("run_b", header(real))


class ToolChecksThePostHarnessFile(Tmp):
    """Item 104: --stage post reads post_harness_rows-selftest-<lane>-<run>-<attempt>, the file run_tests.bat leaves."""

    def check_post(self, report=None):
        return self.check(report=report, stage="post")

    def test_complete_lanes_pass_under_their_own_console_tag(self):
        write_baseline(self.baseline, {"real": ["batch.a", "self.stub.b"], "uv": ["batch.a"]})
        write_lane(self.results, "real", ["batch.a", "self.stub.b"], stage="post")
        write_lane(self.results, "uv", ["batch.a"], stage="post")
        rc, out = self.check_post()
        self.assertEqual(rc, 0, out)
        self.assertIn("expected-post-rows: every listed row was written", out)
        self.assertNotIn("expected-rows:", out, "the two checks must be told apart in one step summary")

    def test_missing_row_fails_and_names_lane_and_id(self):
        write_baseline(self.baseline, {"real": ["batch.a", "batch.b"], "uv": ["batch.a"]})
        write_lane(self.results, "real", ["batch.a"], stage="post")
        write_lane(self.results, "uv", ["batch.a"], stage="post")
        rc, out = self.check_post()
        self.assertEqual(rc, 1, out)
        self.assertIn("expected-post-rows: MISSING lane=real id=batch.b", out)
        self.assertNotIn("MISSING lane=uv", out)
        self.assertIn("expected-post-rows: FAILED", out)

    def test_a_lane_with_no_post_artifact_fails_and_names_it(self):
        write_baseline(self.baseline, {"real": ["batch.a"], "uv": ["batch.a"]})
        write_lane(self.results, "real", ["batch.a"], stage="post")
        rc, out = self.check_post()
        self.assertEqual(rc, 1, out)
        self.assertIn("lane uv: NO post_harness_rows artifact", out)

    def test_the_pre_harness_artifact_is_not_taken_for_the_post_file(self):
        # derived requirement: a lane whose post-harness upload went missing must fail, not be vouched for by the
        # pre-harness snapshot that happens to hold the same ids.
        write_baseline(self.baseline, {"real": ["batch.a"]})
        write_lane(self.results, "real", ["batch.a"], stage="pre")
        rc, out = self.check_post()
        self.assertEqual(rc, 1, out)
        self.assertIn("lane real: NO post_harness_rows artifact", out)

    def test_the_post_artifact_is_not_taken_for_the_pre_harness_snapshot(self):
        write_baseline(self.baseline, {"real": ["a.one"]})
        write_lane(self.results, "real", ["a.one"], stage="post")
        rc, out = self.check()
        self.assertEqual(rc, 1, out)
        self.assertIn("lane real: NO ci_test_results artifact", out)
        self.assertEqual(self.check(stage="pre")[0], 1)

    def test_both_kinds_in_one_folder_are_read_apart(self):
        write_baseline(self.baseline, {"real": ["a.one", "batch.a"]})
        write_lane(self.results, "real", ["a.one"], stage="pre")
        write_lane(self.results, "real", ["batch.a"], stage="post")
        self.assertEqual(sorted(cer.read_run(str(self.results), "pre")["real"]), ["a.one"])
        self.assertEqual(sorted(cer.read_run(str(self.results), "post")["real"]), ["batch.a"])
        self.assertEqual(self.check()[0], 1)
        self.assertEqual(self.check_post()[0], 1)

    def test_hyphenated_lane_names_are_read_whole(self):
        write_baseline(self.baseline, {"contract-uv-fail": ["c.one"], "contract-uv": ["d.one"]})
        write_lane(self.results, "contract-uv-fail", ["c.one"], run="42231664711", attempt="2", stage="post")
        write_lane(self.results, "contract-uv", ["d.one"], run="42231664711", attempt="2", stage="post")
        rc, out = self.check_post()
        self.assertEqual(rc, 0, out)

    def test_emit_extract_style_repeats_are_one_id(self):
        # the real post-harness file holds the same id more than once (emit.extract is written 43 times)
        write_baseline(self.baseline, {"real": ["emit.extract"]})
        write_lane(self.results, "real", ["emit.extract"] * 5, stage="post")
        self.assertEqual(self.check_post()[0], 0)

    def test_the_cache_lane_waiver_reads_the_same_in_this_stage(self):
        write_baseline(self.baseline, {"cache": ["batch.a", "batch.b"], "real": ["batch.a"]})
        write_lane(self.results, "cache", ["self.cache.corrupted"], stage="post")
        write_lane(self.results, "real", ["batch.a"], stage="post")
        rc, out = self.check_post()
        self.assertEqual(rc, 0, out)
        self.assertIn("lane cache: waived", out)

    def test_a_waiver_row_in_another_lane_waives_nothing_here_either(self):
        write_baseline(self.baseline, {"real": ["batch.a"]})
        write_lane(self.results, "real", ["self.cache.bootstrap.failed"], stage="post")
        rc, out = self.check_post()
        self.assertEqual(rc, 1, out)
        self.assertIn("MISSING lane=real id=batch.a", out)

    def test_the_report_names_its_stage(self):
        write_baseline(self.baseline, {"real": ["batch.a", "batch.b"]})
        write_lane(self.results, "real", ["batch.a"], stage="post")
        report = self.tmp / "post.json"
        self.assertEqual(self.check_post(report=report)[0], 1)
        data = json.loads(report.read_text(encoding="ascii"))
        self.assertEqual(data["stage"], "post")
        self.assertEqual(data["lanes"]["real"]["missing"], ["batch.b"])
        write_lane(self.results, "real", ["a.one"], stage="pre")
        report_pre = self.tmp / "pre.json"
        self.check(report=report_pre)
        self.assertEqual(json.loads(report_pre.read_text(encoding="ascii"))["stage"], "pre")

    def test_output_is_ascii(self):
        write_baseline(self.baseline, {"real": ["batch.a"], "uv": ["batch.b"]})
        write_lane(self.results, "real", [], stage="post")
        _rc, out = self.check_post()
        out.encode("ascii")

    def test_an_unknown_stage_is_refused(self):
        write_baseline(self.baseline, {"real": ["batch.a"]})
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                run_main(["check", "--stage", "later", "--results", str(self.results), "--baseline", str(self.baseline)])
        self.assertEqual(raised.exception.code, 2)

    def test_unusable_baseline_is_still_exit_2_with_the_post_tag(self):
        rc, out = run_main(["check", "--stage", "post", "--results", str(self.results),
                            "--baseline", str(self.tmp / "nope")])
        self.assertEqual(rc, 2, out)
        self.assertIn("expected-post-rows: cannot run", out)

    def test_command_line_runs_as_a_script(self):
        write_baseline(self.baseline, {"real": ["batch.a"]})
        write_lane(self.results, "real", ["batch.a"], stage="post")
        cmd = [sys.executable, str(TOOL), "check", "--stage", "post", "--results", str(self.results),
               "--baseline", str(self.baseline)]
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        (self.results / "post_harness_rows-selftest-real-100-1" / "~test-results.ndjson").write_text("", encoding="utf-8")
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("expected-post-rows: MISSING lane=real id=batch.a", done.stdout)


class ToolGeneratesThePostHarnessBaseline(Tmp):
    def gen(self, *runs, stage="post"):
        return run_main(["generate", "--stage", stage, "--results"] + [str(r) for r in runs]
                        + ["--baseline", str(self.baseline)])

    def test_ids_present_in_every_run_are_kept_and_the_header_names_the_item(self):
        run_a, run_b = self.tmp / "run_a", self.tmp / "run_b"
        run_a.mkdir()
        run_b.mkdir()
        write_lane(run_a, "real", ["batch.a", "self.stub.b", "only.in.a"], stage="post")
        write_lane(run_b, "real", ["batch.a", "self.stub.b", "only.in.b"], stage="post")
        rc, out = self.gen(run_a, run_b)
        self.assertEqual(rc, 0, out)
        self.assertIn("expected-post-rows: wrote real.txt with 2 ids from 2 run(s)", out)
        self.assertEqual(cer.read_baseline(str(self.baseline)), {"real": ["batch.a", "self.stub.b"]})
        text = (self.baseline / "real.txt").read_text(encoding="ascii")
        self.assertIn("# Item 104:", text)
        self.assertIn("generate --stage post", text)
        self.assertIn("run_a, run_b", text)
        for run in (run_a, run_b):
            rc, out = run_main(["check", "--stage", "post", "--results", str(run), "--baseline", str(self.baseline)])
            self.assertEqual(rc, 0, out)

    def test_the_pre_harness_header_is_unchanged(self):
        run_a = self.tmp / "run_a"
        run_a.mkdir()
        write_lane(run_a, "real", ["a.one"])
        rc, out = run_main(["generate", "--results", str(run_a), "--baseline", str(self.baseline)])
        self.assertEqual(rc, 0, out)
        text = (self.baseline / "real.txt").read_text(encoding="ascii")
        self.assertIn("# Item 98: row ids lane 'real' must write before run_tests.bat", text)
        self.assertNotIn("--stage", text)
        self.assertNotIn("Item 104", text)

    def test_generate_reads_only_the_stage_it_is_given(self):
        run_a = self.tmp / "run_a"
        run_a.mkdir()
        write_lane(run_a, "real", ["a.one"], stage="pre")
        rc, out = self.gen(run_a)
        self.assertEqual(rc, 2, out)
        self.assertIn("post_harness_rows-selftest-<lane>-<run>-<attempt>", out)
        self.assertEqual(list(self.baseline.glob("*.txt")) if self.baseline.exists() else [], [])

    def test_a_run_without_a_lane_is_rejected_and_nothing_is_written(self):
        run_a, run_b = self.tmp / "run_a", self.tmp / "run_b"
        run_a.mkdir()
        run_b.mkdir()
        write_lane(run_a, "real", ["batch.a"], stage="post")
        write_lane(run_a, "uv", ["batch.a"], stage="post")
        write_lane(run_b, "real", ["batch.a"], stage="post")
        rc, out = self.gen(run_a, run_b)
        self.assertEqual(rc, 2, out)
        self.assertIn("uv", out)
        self.assertEqual(list(self.baseline.glob("*.txt")) if self.baseline.exists() else [], [])

    def test_a_waived_cache_run_is_skipped(self):
        run_a, run_b = self.tmp / "run_a", self.tmp / "run_b"
        run_a.mkdir()
        run_b.mkdir()
        write_lane(run_a, "cache", ["batch.a", "batch.b"], stage="post")
        write_lane(run_b, "cache", ["self.cache.corrupted"], stage="post")
        rc, out = self.gen(run_a, run_b)
        self.assertEqual(rc, 0, out)
        self.assertEqual(cer.read_baseline(str(self.baseline)), {"cache": ["batch.a", "batch.b"]})


def matrix_modes(text):
    """The `- mode:` entries of the selftest matrix (same reading as tests/test_aggregate_gate.py)."""
    lines = text.splitlines()
    start = next((i for i, ln in enumerate(lines) if re.match(r"^  selftest:\s*$", ln)), None)
    if start is None:
        return []
    end = next((j for j in range(start + 1, len(lines)) if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[j])), len(lines))
    body = "\n".join(ln for ln in lines[start:end] if not ln.strip().startswith("#"))
    return re.findall(r"^          - mode:\s*([A-Za-z0-9_-]+)\s*$", body, re.MULTILINE)


class BaselineRules:
    """What both baseline folders keep true; FOLDER, STAGE and WHAT name the one under test."""
    FOLDER = BASELINE
    STAGE = "pre"
    WHAT = "tests/expected_rows"

    def files(self):
        return sorted(self.FOLDER.glob("*.txt"))

    def lists(self):
        return cer.read_baseline(str(self.FOLDER))

    def test_one_file_per_selftest_lane(self):
        modes = matrix_modes(WORKFLOW.read_text(encoding="utf-8"))
        self.assertTrue(modes, "could not read the selftest matrix modes")
        self.assertEqual(sorted(p.stem for p in self.files()), sorted(modes),
                         "%s needs exactly one <lane>.txt per selftest matrix lane" % self.WHAT)

    def test_folder_holds_only_lane_lists(self):
        stray = sorted(p.name for p in self.FOLDER.iterdir() if p.suffix != ".txt")
        self.assertEqual(stray, [])

    def test_files_are_clean_sorted_lists(self):
        for path in self.files():
            raw = path.read_bytes()
            self.assertNotIn(b"\r", raw, "%s must use LF line endings" % path.name)
            raw.decode("ascii")
            ids = self.lists()[path.stem]
            self.assertTrue(ids, "%s lists no rows" % path.name)
            self.assertEqual(ids, sorted(set(ids)), "%s must be sorted with no duplicates" % path.name)

    def test_every_id_is_registered_in_the_ndjson_doc(self):
        registered, _many = check_ndjson_registry.parse_doc_registry(REGISTRY_DOC)
        problems = []
        for lane, ids in self.lists().items():
            for rid in ids:
                if rid not in registered:
                    problems.append("%s lists %s, which docs/agent-ndjson.md does not register" % (lane, rid))
        self.assertEqual(problems, [], "A row that was removed or renamed must leave %s/<lane>.txt in "
                                       "the same change, or the aggregate gate fails on the missing id" % self.WHAT)

    def test_no_list_carries_a_throwaway_probe_id(self):
        self.assertEqual(probe_ids(self.lists()), [],
                         "a probe. id proves the gate on one red run and is removed in the next commit")

    def test_the_probe_guard_can_fail(self):
        with tempfile.TemporaryDirectory() as td:
            write_baseline(td, {"real": ["a.row", "probe.expected_rows.missing"], "uv": ["b.row"]})
            self.assertEqual(probe_ids(cer.read_baseline(td)),
                             ["real lists the throwaway id probe.expected_rows.missing"])
            write_baseline(td, {"real": ["a.row"], "uv": ["b.row"]})
            self.assertEqual(probe_ids(cer.read_baseline(td)), [])

    def test_a_lane_that_wrote_exactly_its_list_passes_and_one_short_fails(self):
        baseline = self.lists()
        with tempfile.TemporaryDirectory() as td:
            for lane, ids in baseline.items():
                write_lane(td, lane, ids, stage=self.STAGE)
            argv = ["check", "--stage", self.STAGE, "--results", td, "--baseline", str(self.FOLDER)]
            rc, out = run_main(argv)
            self.assertEqual(rc, 0, out)
            lane = sorted(baseline)[0]
            write_lane(td, lane, baseline[lane][:-1], stage=self.STAGE)
            rc, out = run_main(argv)
            self.assertEqual(rc, 1, out)
            self.assertIn("MISSING lane=%s id=%s" % (lane, baseline[lane][-1]), out)


class RepositoryBaseline(BaselineRules, unittest.TestCase):
    pass


class PostRepositoryBaseline(BaselineRules, unittest.TestCase):
    """Item 104: tests/expected_rows_post, the ids each lane must have in the file run_tests.bat leaves behind."""
    FOLDER = POST_BASELINE
    STAGE = "post"
    WHAT = "tests/expected_rows_post"

    def test_the_post_harness_rows_are_not_in_the_pre_harness_lists(self):
        # derived requirement: harness.ps1 deletes and rewrites the file, so a batch.* row in a pre list could never be
        # written by the time the gate reads it. The rows selftests.ps1 writes sit in both files on purpose: the second run
        # inside run_tests.bat is the one the post list proves (a skipped section leaves no row, Item 84).
        twice = rows_written_twice(SELFTESTS.read_text(encoding="utf-8"))
        self.assertTrue(twice, "could not read the ids tests/selftests.ps1 writes")
        self.assertEqual(folder_overlap(cer.read_baseline(str(BASELINE)), self.lists(), twice), [])

    def test_the_overlap_guard_can_fail(self):
        twice = {"self.twice.row"}
        pre = {"real": ["a.row", "self.twice.row", "self.once.row"], "uv": ["b.row"]}
        post = {"real": ["batch.x", "self.twice.row", "self.once.row"], "uv": ["batch.x"]}
        self.assertEqual(folder_overlap(pre, post, twice),
                         ["real lists self.once.row in both folders, and selftests.ps1 does not write it twice"])
        pre["real"].append("batch.y")
        self.assertEqual(folder_overlap(pre, post, twice)[0],
                         "real lists batch.y before run_tests.bat, but harness.ps1 writes it after the snapshot")
        self.assertEqual(rows_written_twice("Write-NdjsonRow ([ordered]@{ id = 'self.a.b'; pass = $true })"), {"self.a.b"})

    def test_the_harness_rows_are_listed(self):
        # the point of the folder: batch.* rows (harness.ps1) and self.stub.* rows (selftest.ps1) are checked
        for lane, ids in self.lists().items():
            self.assertTrue(any(i.startswith("batch.") for i in ids), "%s lists no batch.* row" % lane)
            self.assertTrue(any(i.startswith("self.stub.") for i in ids), "%s lists no self.stub.* row" % lane)


# --- the wiring in batch-check.yml ------------------------------------------------------------------------------------

DOWNLOAD_STEP = "Download lane NDJSON"
POST_DOWNLOAD_STEP = "Download post-harness rows"
AGGREGATE_STEP = "Aggregate verdicts"
UPLOAD_STEP = "Upload gate report"
SUMMARY_STEP = "Append gate summary"
POST_UPLOAD_STEP = "Upload post-harness rows"
PRE_UPLOAD_STEP = "Upload CI NDJSON"
RUN_TESTS_STEP = "Run tests (run_tests.bat)"
META_STEP = "Append matrix mode meta row"

# One entry per stage of the check; the two are held to the same rules with their own names.
SPECS = {
    "pre": {"download": DOWNLOAD_STEP, "artifact": "ci_test_results-selftest-", "baseline": "tests/expected_rows",
            "rc": "rowsRc", "exit_key": "expected_rows_exit", "reports": ("expected-rows.txt", "expected-rows.json"),
            "label": "expected-row check", "stage": "pre"},
    "post": {"download": POST_DOWNLOAD_STEP, "artifact": "post_harness_rows-selftest-",
             "baseline": "tests/expected_rows_post", "rc": "postRc", "exit_key": "post_rows_exit",
             "reports": ("expected-post-rows.txt", "expected-post-rows.json"),
             "label": "post-harness expected-row check", "stage": "post"},
}
CHECK_CALL = re.compile(r"python\s+tools/check_expected_rows\.py\s+check\b")
RUN_ID_TAIL = "-${{ github.run_id }}-${{ github.run_attempt }}"
# a line that changes tests/~test-results.ndjson (a write, an append, a delete, a move)
WRITES_THE_FILE = re.compile(r"(Add-Content|Set-Content|Out-File|Remove-Item|Move-Item|Copy-Item|>>|WriteAll|append|write)",
                             re.IGNORECASE)


def live(text):
    return "\n".join(ln for ln in text.splitlines() if not ln.strip().startswith("#"))


def job(text, name):
    lines = text.splitlines()
    start = next((i for i, ln in enumerate(lines) if re.match(r"^  %s:\s*$" % re.escape(name), ln)), None)
    if start is None:
        return None
    end = next((j for j in range(start + 1, len(lines))
                if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[j]) or re.match(r"^\S", lines[j])), len(lines))
    return "\n".join(lines[start:end])


def steps(job_text):
    lines = job_text.splitlines()
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    out = []
    for n, s in enumerate(starts):
        e = starts[n + 1] if n + 1 < len(starts) else len(lines)
        name = re.sub(r"^      - name:\s*", "", lines[s]).strip().strip('"').strip("'")
        out.append((name, "\n".join(lines[s:e])))
    return out


def render(template):
    """What an artifact name template becomes for lane `real` of run 100, attempt 1."""
    return (template.replace("${{ github.job }}", "selftest").replace("${{ matrix.mode }}", "real")
            .replace("${{ github.run_id }}", "100").replace("${{ github.run_attempt }}", "1"))


def call_tails(a):
    """[(match, the statement)] for every check call in the step; a statement runs on while a line ends in a backtick."""
    out = []
    for m in CHECK_CALL.finditer(a):
        lines = a[m.start():].splitlines()
        taken = []
        for ln in lines:
            taken.append(ln)
            if not ln.rstrip().endswith("`"):
                break
        out.append((m, "\n".join(taken)))
    return out


def stage_of(tail):
    return "post" if re.search(r"--stage\s+post\b", tail) else "pre"


def download_problems(spec, named, names):
    found = []
    dl = [blk for n, blk in named if n == spec["download"]]
    if len(dl) != 1:
        return ["selftest-gate must have exactly one step named %r (found %d)" % (spec["download"], len(dl))], None
    if names.index(spec["download"]) > names.index(AGGREGATE_STEP):
        found.append("%r must come before %r (the check reads what it downloads)" % (spec["download"], AGGREGATE_STEP))
    d = live(dl[0])
    if "actions/download-artifact@" not in d:
        found.append("%r must use actions/download-artifact" % spec["download"])
    if re.search(r"^\s*merge-multiple:", d, re.MULTILINE):
        found.append("%r must not use merge-multiple: every lane writes the same file name and the folder name is the lane"
                     % spec["download"])
    pat = re.search(r"^\s*pattern:\s*(.+?)\s*$", d, re.MULTILINE)
    if not pat or not pat.group(1).startswith(spec["artifact"]) or not pat.group(1).endswith(RUN_ID_TAIL):
        found.append("%r must download %s*-<run id>-<attempt> (this attempt's artifacts only)"
                     % (spec["download"], spec["artifact"]))
    elif not fnmatch.fnmatchcase(render(spec["artifact"] + "${{ matrix.mode }}" + RUN_ID_TAIL), render(pat.group(1))):
        found.append("%r pattern %r does not match the artifact name the matrix lanes upload" % (spec["download"], pat.group(1)))
    dpath = re.search(r"^\s*path:\s*\$\{\{ runner\.temp \}\}/([A-Za-z0-9_-]+)\s*$", d, re.MULTILINE)
    if not dpath:
        found.append("%r must download into ${{ runner.temp }}/<folder>" % spec["download"])
    return found, (dpath.group(1) if dpath else None)


def stage_problems(spec, named, names, a, folder):
    """The rules for one stage's call inside the (comment-free) text `a` of the Aggregate verdicts step."""
    found = []
    label = spec["label"]
    calls = [(m, tail) for m, tail in call_tails(a) if stage_of(tail) == spec["stage"]]
    if not calls:
        return ["%r does not run python tools/check_expected_rows.py check%s" % (
            AGGREGATE_STEP, " --stage post" if spec["stage"] == "post" else "")]
    if len(calls) > 1:
        found.append("%r runs the %s %d times" % (AGGREGATE_STEP, label, len(calls)))
    call, tail = calls[0]
    base = re.search(r"--baseline\s+(\S+)", tail)
    if not base or base.group(1) != spec["baseline"]:
        found.append("the %s must read --baseline %s" % (label, spec["baseline"]))
    res = re.search(r"--results\s+\(Join-Path \$env:RUNNER_TEMP '([A-Za-z0-9_-]+)'\)", tail)
    if not res:
        found.append("the %s must read --results (Join-Path $env:RUNNER_TEMP '<folder>')" % label)
    elif folder and res.group(1) != folder:
        found.append("the %s reads folder %r but the download writes %r" % (label, res.group(1), folder))
    rc = spec["rc"]
    # everything between the end of the previous check (or the start of the step) and this call
    earlier = [m for m, _t in call_tails(a) if m.start() < call.start()]
    start = earlier[-1].start() if earlier else 0
    before = a[:call.start()]
    between = a[start:call.start()]
    init = re.findall(r"^\s*\$%s\s*=\s*(\S+)\s*$" % rc, before, re.MULTILINE)
    if not init or init[-1] in ("0", "$null"):
        found.append("$%s must start at a failing code before the %s runs (python missing must fail the gate)" % (rc, label))
    if not re.search(r"^\s*\$global:LASTEXITCODE\s*=\s*\$null\s*$", between, re.MULTILINE):
        found.append("$global:LASTEXITCODE must be cleared before the %s (a stale 0 would read as success)" % label)
    later = [m for m, _t in call_tails(a) if m.start() > call.start()]
    segment = a[call.start():later[0].start() if later else len(a)]
    if not re.search(r"if\s*\(\s*\$null\s+-ne\s+\$LASTEXITCODE\s*\)\s*\{\s*\$%s\s*=\s*\$LASTEXITCODE\s*\}" % rc, segment):
        found.append("$%s must take $LASTEXITCODE only when the check ran" % rc)
    if re.search(r"\|\|\s*(?:true\b|:(?![A-Za-z0-9_])|exit\s+0\b)", tail):
        found.append("the %s's exit code is hidden" % label)
    if spec["exit_key"] not in a:
        found.append("the diag.selftest_gate.verdict row lost details.%s" % spec["exit_key"])
    return found


def matrix_problems(text):
    """The matrix job's side: which steps upload which file, in which order."""
    found = []
    sjob = job(text, "selftest")
    if sjob is None:
        return ["there is no selftest job"]
    named = steps(sjob)
    names = [n for n, _ in named]
    for step in (RUN_TESTS_STEP, META_STEP, PRE_UPLOAD_STEP):
        if names.count(step) != 1:
            found.append("the selftest job must have exactly one step named %r (found %d)" % (step, names.count(step)))
    ups = [blk for n, blk in named if n == POST_UPLOAD_STEP]
    if len(ups) != 1:
        found.append("the selftest job must have exactly one step named %r (found %d)" % (POST_UPLOAD_STEP, len(ups)))
        return found
    if found:
        return found
    at = names.index(POST_UPLOAD_STEP)
    if at < names.index(RUN_TESTS_STEP):
        found.append("%r must come after %r (harness.ps1 rewrites the file there)" % (POST_UPLOAD_STEP, RUN_TESTS_STEP))
    if at < names.index(META_STEP):
        found.append("%r must come after %r (it appends the last row)" % (POST_UPLOAD_STEP, META_STEP))
    u = live(ups[0])
    if "actions/upload-artifact@" not in u:
        found.append("%r must use actions/upload-artifact" % POST_UPLOAD_STEP)
    cond = re.search(r"^\s*if:\s*(.+?)\s*$", u, re.MULTILINE)
    if not cond or not re.search(r"!cancelled\(\)|always\(\)", cond.group(1)) or "success()" in cond.group(1):
        found.append("%r must run when an earlier step failed (if: ${{ !cancelled() }}): a red lane still has to be checked"
                     % POST_UPLOAD_STEP)
    path = re.search(r"^\s*path:\s*(\S+)\s*$", u, re.MULTILINE)
    if not path or path.group(1) != "tests/~test-results.ndjson":
        found.append("%r must upload tests/~test-results.ndjson, the file run_tests.bat leaves" % POST_UPLOAD_STEP)
    for upload, kind in ((ups[0], "post"), ([blk for n, blk in named if n == PRE_UPLOAD_STEP][0], "pre")):
        name = re.search(r"^\s*name:\s*(ci_test_results-|post_harness_rows-)(.+?)\s*$", live(upload), re.MULTILINE)
        which = POST_UPLOAD_STEP if kind == "post" else PRE_UPLOAD_STEP
        want = "post_harness_rows-" if kind == "post" else "ci_test_results-"
        if not name or name.group(1) != want or not (name.group(1) + name.group(2)).endswith(RUN_ID_TAIL):
            found.append("%r must upload an artifact named %s${{ github.job }}-${{ matrix.mode }}%s" % (which, want, RUN_ID_TAIL))
        elif cer.lane_of(render(name.group(1) + name.group(2)), kind) != "real":
            found.append("the artifact name of %r does not read as lane `real` for tools/check_expected_rows.py --stage %s "
                         "(it needs %s${{ github.job }}-${{ matrix.mode }}-<run>-<attempt>)" % (which, kind, want))
    for later_name, blk in named[at + 1:]:
        for line in live(blk).splitlines():
            if "~test-results.ndjson" in line and WRITES_THE_FILE.search(line):
                found.append("step %r changes tests/~test-results.ndjson after it was uploaded: %s" % (later_name, line.strip()[:80]))
    return found


def wiring_problems(text):
    found = []
    gate = job(text, "selftest-gate")
    if gate is None:
        return ["there is no selftest-gate job"]
    named = steps(gate)
    names = [n for n, _ in named]
    agg = [blk for n, blk in named if n == AGGREGATE_STEP]
    up = [blk for n, blk in named if n == UPLOAD_STEP]
    summ = [blk for n, blk in named if n == SUMMARY_STEP]
    folders = {}
    for key, spec in SPECS.items():
        problems, folder = download_problems(spec, named, names)
        found += problems
        folders[key] = folder
    if len(agg) != 1:
        found.append("selftest-gate must have exactly one step named %r (found %d)" % (AGGREGATE_STEP, len(agg)))
    if found:
        return found

    a = live(agg[0])
    for key, spec in SPECS.items():
        found += stage_problems(spec, named, names, a, folders[key])
    tails = call_tails(a)
    if not tails:
        return found
    value = re.search(r"^\s*\$value\s*=\s*if\s*\((.*?)\)\s*\{\s*'false'\s*\}\s*else\s*\{\s*'true'\s*\}\s*$", a, re.MULTILINE)
    if not value:
        found.append("the Aggregate verdicts step lost its `$value = if (...) { 'false' } else { 'true' }` line")
    else:
        terms = [x.strip() for x in value.group(1).split("-and")]
        wanted = {"rc"} | {spec["rc"] for spec in SPECS.values()}
        seen = [re.fullmatch(r"\$([A-Za-z]+)\s+-eq\s+0", x) for x in terms]
        if "-or" in value.group(1) or not all(seen) or {m.group(1) for m in seen} != wanted or len(terms) != len(wanted):
            found.append("has_failures must be false only when $rc -eq 0 -and $rowsRc -eq 0 -and $postRc -eq 0 (got %r)"
                         % value.group(1).strip())
        elif a.find(value.group(0)) < tails[-1][0].start():
            found.append("$value is decided before the expected-row check ran")
    if re.search(r"^\s*continue-on-error:", a, re.MULTILINE):
        found.append("%r has continue-on-error: a failing check would stay green" % AGGREGATE_STEP)
    if len(up) != 1:
        found.append("%r must exist once" % UPLOAD_STEP)
    else:
        for spec in SPECS.values():
            if not all(r in live(up[0]) for r in spec["reports"]):
                found.append("%r must also upload %s and %s" % ((UPLOAD_STEP,) + spec["reports"]))
    if len(summ) != 1 or "expected-post-rows.txt" not in live(summ[0]):
        found.append("%r must print expected-post-rows.txt (the post-harness check's output)" % SUMMARY_STEP)
    if not any(n == "Checkout repository" for n in names):
        found.append("selftest-gate needs the repository checkout (tests/expected_rows and the tool come from it)")
    found += matrix_problems(text)
    return found


GOOD = """  selftest:
    name: Batch syntax/run check (${{ matrix.mode }})
    strategy:
      matrix:
        include:
          - mode: real
    steps:
      - name: Upload CI NDJSON
        if: ${{ !cancelled() }}
        uses: actions/upload-artifact@v7
        with:
          name: ci_test_results-${{ github.job }}-${{ matrix.mode }}-${{ github.run_id }}-${{ github.run_attempt }}
          path: tests/~test-results.ndjson

      - name: Run tests (run_tests.bat)
        shell: pwsh
        run: |
          & .\\run_tests.bat

      - name: Append matrix mode meta row
        if: ${{ !cancelled() }}
        shell: pwsh
        run: |
          Add-Content -LiteralPath tests/~test-results.ndjson -Value $json -Encoding Ascii

      - name: Upload post-harness rows
        if: ${{ !cancelled() }}
        uses: actions/upload-artifact@v7
        with:
          name: post_harness_rows-${{ github.job }}-${{ matrix.mode }}-${{ github.run_id }}-${{ github.run_attempt }}
          path: tests/~test-results.ndjson
          if-no-files-found: warn

      - name: Gate on NDJSON results
        if: ${{ !cancelled() }}
        uses: actions/github-script@v9
        with:
          script: |
            const raw = fs.readFileSync('tests/~test-results.ndjson', 'utf8');

  selftest-gate:
    name: Aggregate self-test verdicts
    steps:
      - name: Checkout repository
        uses: actions/checkout@v7

      - name: Download lane NDJSON
        uses: actions/download-artifact@v8
        continue-on-error: true
        with:
          pattern: ci_test_results-selftest-*-${{ github.run_id }}-${{ github.run_attempt }}
          path: ${{ runner.temp }}/lane-ndjson

      - name: Download post-harness rows
        uses: actions/download-artifact@v8
        continue-on-error: true
        with:
          pattern: post_harness_rows-selftest-*-${{ github.run_id }}-${{ github.run_attempt }}
          path: ${{ runner.temp }}/post-rows

      - name: Aggregate verdicts
        id: aggregate
        shell: pwsh
        run: |
          & .\\tools\\aggregate_selftest_verdicts.ps1 `
            -ExpectedLanes @('real', 'uv')
          $rc = $LASTEXITCODE
          # a comment that mentions $rowsRc = 0 is ignored
          $rowsRc = 2
          $postRc = 2
          $rowsTxt = Join-Path $env:RUNNER_TEMP 'expected-rows.txt'
          $postTxt = Join-Path $env:RUNNER_TEMP 'expected-post-rows.txt'
          $global:LASTEXITCODE = $null
          try {
            & python tools/check_expected_rows.py check `
              --results (Join-Path $env:RUNNER_TEMP 'lane-ndjson') `
              --baseline tests/expected_rows `
              --report $rowsJson | Tee-Object -FilePath $rowsTxt
            if ($null -ne $LASTEXITCODE) { $rowsRc = $LASTEXITCODE }
          } catch {
            Write-Host "could not run"
          }
          $global:LASTEXITCODE = $null
          try {
            & python tools/check_expected_rows.py check --stage post `
              --results (Join-Path $env:RUNNER_TEMP 'post-rows') `
              --baseline tests/expected_rows_post `
              --report $postJson | Tee-Object -FilePath $postTxt
            if ($null -ne $LASTEXITCODE) { $postRc = $LASTEXITCODE }
          } catch {
            Write-Host "could not run"
          }
          $value = if ($rc -eq 0 -and $rowsRc -eq 0 -and $postRc -eq 0) { 'false' } else { 'true' }
          "has_failures=$value" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding ascii -Append
          details = [ordered]@{ exit_code = $rc; expected_rows_exit = $rowsRc; post_rows_exit = $postRc }
          exit 0

      - name: Append gate summary
        if: ${{ always() }}
        shell: pwsh
        run: |
          $rowsPath = Join-Path $env:RUNNER_TEMP 'expected-rows.txt'
          $postPath = Join-Path $env:RUNNER_TEMP 'expected-post-rows.txt'

      - name: Upload gate report
        if: ${{ always() }}
        uses: actions/upload-artifact@v7
        with:
          path: |
            ${{ runner.temp }}/selftest-gate.json
            ${{ runner.temp }}/expected-rows.txt
            ${{ runner.temp }}/expected-rows.json
            ${{ runner.temp }}/expected-post-rows.txt
            ${{ runner.temp }}/expected-post-rows.json

  crlf-check:
    name: x
"""


class ExpectedRowsWiring(unittest.TestCase):
    def test_workflow(self):
        self.assertEqual(wiring_problems(WORKFLOW.read_text(encoding="utf-8")), [])

    def test_good_shape_is_clean(self):
        self.assertEqual(wiring_problems(GOOD), [])

    def assertCaught(self, bad, needle):
        self.assertNotEqual(bad, GOOD, "the mutation changed nothing")
        found = wiring_problems(bad)
        self.assertTrue(any(needle in f for f in found), found)

    # --- the pre-harness check (Item 98)

    def test_missing_download_step(self):
        self.assertCaught(GOOD.replace("Download lane NDJSON", "Download something"), "exactly one step named 'Download lane NDJSON'")

    def test_download_after_the_check(self):
        i = GOOD.index("      - name: Download lane NDJSON")
        j = GOOD.index("      - name: Download post-harness rows")
        k = GOOD.index("      - name: Aggregate verdicts")
        m = GOOD.index("      - name: Append gate summary")
        bad = GOOD[:i] + GOOD[j:k] + GOOD[k:m] + GOOD[i:j] + GOOD[m:]
        self.assertCaught(bad, "must come before")

    def test_merge_multiple(self):
        self.assertCaught(GOOD.replace("          path: ${{ runner.temp }}/lane-ndjson", "          merge-multiple: true\n          path: ${{ runner.temp }}/lane-ndjson"), "merge-multiple")

    def test_pattern_that_takes_other_attempts(self):
        self.assertCaught(GOOD.replace("ci_test_results-selftest-*-${{ github.run_id }}-${{ github.run_attempt }}\n", "ci_test_results-selftest-*\n"), "this attempt")

    def test_pattern_for_other_artifacts(self):
        self.assertCaught(GOOD.replace("pattern: ci_test_results-selftest-*", "pattern: selftest-verdict-*"), "this attempt")

    def test_check_not_run(self):
        self.assertCaught(GOOD.replace("tools/check_expected_rows.py check `", "tools/other.py check `", 1), "does not run")

    def test_wrong_baseline_folder(self):
        self.assertCaught(GOOD.replace("--baseline tests/expected_rows `", "--baseline tests/other `"), "--baseline tests/expected_rows")

    def test_results_folder_differs_from_download(self):
        self.assertCaught(GOOD.replace("'lane-ndjson'", "'elsewhere'"), "download writes")

    def test_exit_code_starts_at_success(self):
        self.assertCaught(GOOD.replace("          $rowsRc = 2\n", "          $rowsRc = 0\n"), "$rowsRc must start at a failing code")

    def test_exit_code_never_initialised(self):
        self.assertCaught(GOOD.replace("          $rowsRc = 2\n", ""), "$rowsRc must start at a failing code")

    def test_last_exit_code_not_cleared_before_the_first_check(self):
        i = GOOD.index("          $global:LASTEXITCODE = $null\n")
        bad = GOOD[:i] + GOOD[i:].replace("          $global:LASTEXITCODE = $null\n", "", 1)
        self.assertCaught(bad, "must be cleared before the expected-row check")

    def test_unconditional_exit_code_copy(self):
        self.assertCaught(GOOD.replace("if ($null -ne $LASTEXITCODE) { $rowsRc = $LASTEXITCODE }", "$rowsRc = $LASTEXITCODE"), "$rowsRc must take $LASTEXITCODE only")

    def test_result_not_in_has_failures(self):
        self.assertCaught(GOOD.replace("$rc -eq 0 -and $rowsRc -eq 0 -and $postRc -eq 0", "$rc -eq 0 -and $postRc -eq 0"), "has_failures must be false only")

    def test_result_ored_in_wrongly(self):
        self.assertCaught(GOOD.replace("$rc -eq 0 -and $rowsRc -eq 0 -and $postRc -eq 0", "$rc -eq 0 -and $rowsRc -eq 0 -or $postRc -eq 0"), "has_failures must be false only")

    def test_value_decided_before_the_checks(self):
        line = "          $value = if ($rc -eq 0 -and $rowsRc -eq 0 -and $postRc -eq 0) { 'false' } else { 'true' }\n"
        bad = GOOD.replace(line, "").replace("          $rowsRc = 2\n", line + "          $rowsRc = 2\n")
        self.assertCaught(bad, "decided before")

    def test_continue_on_error_on_the_aggregate_step(self):
        self.assertCaught(GOOD.replace("        id: aggregate\n", "        id: aggregate\n        continue-on-error: true\n"), "continue-on-error")

    def test_swallowed_exit_code(self):
        self.assertCaught(GOOD.replace("Tee-Object -FilePath $rowsTxt", "Tee-Object -FilePath $rowsTxt || true"), "hidden")

    def test_gate_row_without_the_exit_code(self):
        self.assertCaught(GOOD.replace("expected_rows_exit", "other"), "expected_rows_exit")

    def test_report_upload_without_the_check_output(self):
        self.assertCaught(GOOD.replace("            ${{ runner.temp }}/expected-rows.txt\n", ""), "must also upload")

    def test_no_checkout(self):
        self.assertCaught(GOOD.replace("Checkout repository", "Something"), "checkout")

    def test_comment_only_mentions_do_not_count(self):
        bad = GOOD.replace("          $rowsRc = 2\n", "          # $rowsRc = 2\n")
        self.assertCaught(bad, "$rowsRc must start at a failing code")

    def test_missing_gate_job(self):
        self.assertEqual(wiring_problems("x: y\n"), ["there is no selftest-gate job"])

    # --- the post-harness check (Item 104)

    def test_missing_post_download_step(self):
        self.assertCaught(GOOD.replace("Download post-harness rows", "Download other rows"), "exactly one step named 'Download post-harness rows'")

    def test_post_download_after_the_check(self):
        i = GOOD.index("      - name: Download post-harness rows")
        k = GOOD.index("      - name: Aggregate verdicts")
        m = GOOD.index("      - name: Append gate summary")
        bad = GOOD[:i] + GOOD[k:m] + GOOD[i:k] + GOOD[m:]
        self.assertCaught(bad, "'Download post-harness rows' must come before")

    def test_post_download_with_merge_multiple(self):
        self.assertCaught(GOOD.replace("          path: ${{ runner.temp }}/post-rows", "          merge-multiple: true\n          path: ${{ runner.temp }}/post-rows"), "merge-multiple")

    def test_post_pattern_that_takes_other_attempts(self):
        self.assertCaught(GOOD.replace("post_harness_rows-selftest-*-${{ github.run_id }}-${{ github.run_attempt }}\n", "post_harness_rows-selftest-*\n"), "post_harness_rows-selftest-*-<run id>")

    def test_post_pattern_for_the_pre_harness_artifacts(self):
        self.assertCaught(GOOD.replace("pattern: post_harness_rows-selftest-*", "pattern: ci_test_results-selftest-*"), "post_harness_rows-selftest-*-<run id>")

    def test_post_pattern_that_cannot_match_the_upload(self):
        self.assertCaught(GOOD.replace("pattern: post_harness_rows-selftest-*", "pattern: post_harness_rows-selftest-x*"), "does not match the artifact name")

    def test_post_check_not_run(self):
        self.assertCaught(GOOD.replace("tools/check_expected_rows.py check --stage post `", "tools/other.py check --stage post `"), "does not run python tools/check_expected_rows.py check --stage post")

    def test_post_check_without_the_stage_flag_is_the_pre_check_twice(self):
        bad = GOOD.replace("check --stage post `", "check `")
        self.assertCaught(bad, "does not run python tools/check_expected_rows.py check --stage post")
        self.assertTrue(any("2 times" in f for f in wiring_problems(bad)), wiring_problems(bad))

    def test_post_check_reads_the_pre_harness_lists(self):
        self.assertCaught(GOOD.replace("--baseline tests/expected_rows_post `", "--baseline tests/expected_rows `"), "must read --baseline tests/expected_rows_post")

    def test_post_check_reads_the_wrong_download_folder(self):
        self.assertCaught(GOOD.replace("'post-rows'", "'lane-ndjson'"), "the post-harness expected-row check reads folder")

    def test_post_exit_code_starts_at_success(self):
        self.assertCaught(GOOD.replace("          $postRc = 2\n", "          $postRc = 0\n"), "$postRc must start at a failing code")

    def test_post_exit_code_never_initialised(self):
        self.assertCaught(GOOD.replace("          $postRc = 2\n", ""), "$postRc must start at a failing code")

    def test_last_exit_code_not_cleared_before_the_post_check(self):
        # derived requirement: the first check leaves 0 in $LASTEXITCODE, so a post check that never started would
        # read that stale 0 as its own answer
        i = GOOD.index("          $global:LASTEXITCODE = $null\n")
        j = GOOD.index("          $global:LASTEXITCODE = $null\n", i + 10)
        bad = GOOD[:j] + GOOD[j:].replace("          $global:LASTEXITCODE = $null\n", "", 1)
        self.assertCaught(bad, "must be cleared before the post-harness expected-row check")

    def test_post_unconditional_exit_code_copy(self):
        self.assertCaught(GOOD.replace("if ($null -ne $LASTEXITCODE) { $postRc = $LASTEXITCODE }", "$postRc = $LASTEXITCODE"), "$postRc must take $LASTEXITCODE only")

    def test_post_result_not_in_has_failures(self):
        self.assertCaught(GOOD.replace(" -and $postRc -eq 0", ""), "has_failures must be false only")

    def test_post_swallowed_exit_code(self):
        self.assertCaught(GOOD.replace("Tee-Object -FilePath $postTxt", "Tee-Object -FilePath $postTxt || exit 0"), "post-harness expected-row check's exit code is hidden")

    def test_gate_row_without_the_post_exit_code(self):
        self.assertCaught(GOOD.replace("post_rows_exit", "other"), "post_rows_exit")

    def test_report_upload_without_the_post_output(self):
        self.assertCaught(GOOD.replace("            ${{ runner.temp }}/expected-post-rows.json\n", ""), "must also upload expected-post-rows.txt and expected-post-rows.json")

    def test_summary_without_the_post_output(self):
        self.assertCaught(GOOD.replace("          $postPath = Join-Path $env:RUNNER_TEMP 'expected-post-rows.txt'\n", ""), "must print expected-post-rows.txt")

    # --- the matrix job's upload of the post-harness file (Item 104)

    def test_missing_post_upload_step(self):
        self.assertCaught(GOOD.replace("Upload post-harness rows", "Upload something"), "exactly one step named 'Upload post-harness rows'")

    def test_post_upload_before_the_harness_runs(self):
        i = GOOD.index("      - name: Upload CI NDJSON")
        j = GOOD.index("      - name: Run tests (run_tests.bat)")
        k = GOOD.index("      - name: Upload post-harness rows")
        m = GOOD.index("      - name: Gate on NDJSON results")
        bad = GOOD[:j] + GOOD[k:m] + GOOD[j:k] + GOOD[m:]
        self.assertCaught(bad, "must come after 'Run tests (run_tests.bat)'")

    def test_post_upload_before_the_meta_row(self):
        j = GOOD.index("      - name: Append matrix mode meta row")
        k = GOOD.index("      - name: Upload post-harness rows")
        m = GOOD.index("      - name: Gate on NDJSON results")
        bad = GOOD[:j] + GOOD[k:m] + GOOD[j:k] + GOOD[m:]
        self.assertCaught(bad, "must come after 'Append matrix mode meta row'")

    def test_post_upload_that_skips_a_red_lane(self):
        bad = GOOD.replace("      - name: Upload post-harness rows\n        if: ${{ !cancelled() }}", "      - name: Upload post-harness rows\n        if: ${{ success() }}")
        self.assertCaught(bad, "must run when an earlier step failed")

    def test_post_upload_with_no_condition_skips_a_red_lane(self):
        bad = GOOD.replace("      - name: Upload post-harness rows\n        if: ${{ !cancelled() }}\n", "      - name: Upload post-harness rows\n")
        self.assertCaught(bad, "must run when an earlier step failed")

    def test_post_upload_of_the_wrong_file(self):
        bad = GOOD.replace("          name: post_harness_rows-${{ github.job }}-${{ matrix.mode }}-${{ github.run_id }}-${{ github.run_attempt }}\n          path: tests/~test-results.ndjson", "          name: post_harness_rows-${{ github.job }}-${{ matrix.mode }}-${{ github.run_id }}-${{ github.run_attempt }}\n          path: tests/~test-summary.txt")
        self.assertCaught(bad, "must upload tests/~test-results.ndjson")

    def test_post_upload_under_the_pre_harness_name(self):
        bad = GOOD.replace("name: post_harness_rows-${{ github.job }}", "name: ci_test_results-${{ github.job }}")
        self.assertCaught(bad, "must upload an artifact named post_harness_rows-")

    def test_post_upload_name_without_the_attempt(self):
        bad = GOOD.replace("post_harness_rows-${{ github.job }}-${{ matrix.mode }}-${{ github.run_id }}-${{ github.run_attempt }}", "post_harness_rows-${{ github.job }}-${{ matrix.mode }}-${{ github.run_id }}")
        self.assertCaught(bad, "must upload an artifact named post_harness_rows-")

    def test_post_upload_name_the_tool_cannot_read(self):
        bad = GOOD.replace("post_harness_rows-${{ github.job }}-${{ matrix.mode }}-", "post_harness_rows-${{ matrix.mode }}-${{ github.job }}-")
        self.assertCaught(bad, "does not read as lane `real`")

    def test_pre_upload_name_the_tool_cannot_read(self):
        bad = GOOD.replace("name: ci_test_results-${{ github.job }}-${{ matrix.mode }}-", "name: ci_test_results-${{ matrix.mode }}-")
        self.assertCaught(bad, "does not read as lane `real`")

    def test_a_later_step_that_appends_to_the_file(self):
        bad = GOOD.replace("      - name: Gate on NDJSON results", "      - name: Late row\n        shell: pwsh\n        run: |\n          Add-Content -LiteralPath tests/~test-results.ndjson -Value $row\n\n      - name: Gate on NDJSON results")
        self.assertCaught(bad, "changes tests/~test-results.ndjson after it was uploaded")

    def test_a_later_step_that_only_reads_the_file_is_fine(self):
        good = GOOD.replace("      - name: Gate on NDJSON results", "      - name: Late read\n        shell: pwsh\n        run: |\n          Get-Content -LiteralPath tests/~test-results.ndjson\n\n      - name: Gate on NDJSON results")
        self.assertEqual(wiring_problems(good), [])

    def test_missing_matrix_job(self):
        bad = GOOD[GOOD.index("  selftest-gate:"):]
        self.assertIn("there is no selftest job", wiring_problems(bad))


if __name__ == "__main__":
    unittest.main()
