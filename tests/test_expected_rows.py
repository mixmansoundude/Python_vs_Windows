"""Item 98: the aggregate gate also fails on a row that was never written.

"Aggregate self-test verdicts" fails on a row with pass:false. A row that was never written cannot be red, so a
selfapps script that crashed before its first row, failed to parse, or whose step stopped running left no trace in a
lane whose step has continue-on-error (Item 84 found it for the self-tests, Item 95 for the cache health check).
tests/expected_rows/<lane>.txt lists the row ids each lane must have written before run_tests.bat, and
tools/check_expected_rows.py compares the list with the lane's ci_test_results artifact inside the selftest-gate job.

What this file keeps true:
- the tool: a complete lane passes, a missing id / a lane with no results / an unusable baseline fail with a message that
  names the lane and the id, unlisted rows and the gate's own artifact are fine, the cache lane's own infrastructure-skip
  rows waive only the cache lane, generate writes the ids present in every run it is given;
- the baseline in the repository: one file per selftest matrix lane, sorted, no duplicates, ASCII with LF endings, every
  id registered in docs/agent-ndjson.md (so a PR that removes or renames a row is told to update the list here, locally,
  and not after a 2.5 hour run);
- the wiring in batch-check.yml: the lane NDJSON is downloaded without merge-multiple before the aggregate step, the
  check runs from that step, starts from a failing exit code and a cleared $LASTEXITCODE (python missing must not read as
  success), and its result joins has_failures, which the enforce step (tests/test_aggregate_gate.py) turns into a red check.

The workflow is read as plain text (the pytest step installs no YAML library). Synthetic cases prove each rule can fail.
"""
import io
import json
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from tools import check_expected_rows as cer
from tools import check_ndjson_registry

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
BASELINE = REPO / "tests" / "expected_rows"
REGISTRY_DOC = REPO / "docs" / "agent-ndjson.md"
TOOL = REPO / "tools" / "check_expected_rows.py"

# derived requirement: "probe." ids are for proving the gate on a real run (a throwaway id in one baseline file that no
# code writes, as tests/test_aggregate_gate.py's TEMP PROBE steps were for the enforce step); they are not registered.
PROBE_PREFIX = "probe."


def write_lane(results, lane, ids, run="100", attempt="1", extra_lines=()):
    folder = Path(results) / ("ci_test_results-selftest-%s-%s-%s" % (lane, run, attempt))
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

    def check(self, report=None):
        argv = ["check", "--results", str(self.results), "--baseline", str(self.baseline)]
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


def matrix_modes(text):
    """The `- mode:` entries of the selftest matrix (same reading as tests/test_aggregate_gate.py)."""
    lines = text.splitlines()
    start = next((i for i, ln in enumerate(lines) if re.match(r"^  selftest:\s*$", ln)), None)
    if start is None:
        return []
    end = next((j for j in range(start + 1, len(lines)) if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[j])), len(lines))
    body = "\n".join(ln for ln in lines[start:end] if not ln.strip().startswith("#"))
    return re.findall(r"^          - mode:\s*([A-Za-z0-9_-]+)\s*$", body, re.MULTILINE)


class RepositoryBaseline(unittest.TestCase):
    def files(self):
        return sorted(BASELINE.glob("*.txt"))

    def test_one_file_per_selftest_lane(self):
        modes = matrix_modes(WORKFLOW.read_text(encoding="utf-8"))
        self.assertTrue(modes, "could not read the selftest matrix modes")
        self.assertEqual(sorted(p.stem for p in self.files()), sorted(modes),
                         "tests/expected_rows needs exactly one <lane>.txt per selftest matrix lane")

    def test_folder_holds_only_lane_lists(self):
        stray = sorted(p.name for p in BASELINE.iterdir() if p.suffix != ".txt")
        self.assertEqual(stray, [])

    def test_files_are_clean_sorted_lists(self):
        for path in self.files():
            raw = path.read_bytes()
            self.assertNotIn(b"\r", raw, "%s must use LF line endings" % path.name)
            raw.decode("ascii")
            ids = cer.read_baseline(str(BASELINE))[path.stem]
            self.assertTrue(ids, "%s lists no rows" % path.name)
            self.assertEqual(ids, sorted(set(ids)), "%s must be sorted with no duplicates" % path.name)

    def test_every_id_is_registered_in_the_ndjson_doc(self):
        registered, _many = check_ndjson_registry.parse_doc_registry(REGISTRY_DOC)
        problems = []
        for lane, ids in cer.read_baseline(str(BASELINE)).items():
            for rid in ids:
                if rid.startswith(PROBE_PREFIX):
                    continue
                if rid not in registered:
                    problems.append("%s lists %s, which docs/agent-ndjson.md does not register" % (lane, rid))
        self.assertEqual(problems, [], "A row that was removed or renamed must leave tests/expected_rows/<lane>.txt in "
                                       "the same change, or the aggregate gate fails on the missing id")

    def test_a_lane_that_wrote_exactly_its_list_passes_and_one_short_fails(self):
        baseline = cer.read_baseline(str(BASELINE))
        with tempfile.TemporaryDirectory() as td:
            for lane, ids in baseline.items():
                write_lane(td, lane, ids)
            rc, out = run_main(["check", "--results", td, "--baseline", str(BASELINE)])
            self.assertEqual(rc, 0, out)
            lane = sorted(baseline)[0]
            write_lane(td, lane, baseline[lane][:-1])
            rc, out = run_main(["check", "--results", td, "--baseline", str(BASELINE)])
            self.assertEqual(rc, 1, out)
            self.assertIn("MISSING lane=%s id=%s" % (lane, baseline[lane][-1]), out)


# --- the wiring in batch-check.yml ------------------------------------------------------------------------------------

DOWNLOAD_STEP = "Download lane NDJSON"
AGGREGATE_STEP = "Aggregate verdicts"
UPLOAD_STEP = "Upload gate report"


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


def wiring_problems(text):
    found = []
    gate = job(text, "selftest-gate")
    if gate is None:
        return ["there is no selftest-gate job"]
    named = steps(gate)
    names = [n for n, _ in named]
    dl = [blk for n, blk in named if n == DOWNLOAD_STEP]
    agg = [blk for n, blk in named if n == AGGREGATE_STEP]
    up = [blk for n, blk in named if n == UPLOAD_STEP]
    if len(dl) != 1:
        found.append("selftest-gate must have exactly one step named %r (found %d)" % (DOWNLOAD_STEP, len(dl)))
    if len(agg) != 1:
        found.append("selftest-gate must have exactly one step named %r (found %d)" % (AGGREGATE_STEP, len(agg)))
    if found:
        return found
    if names.index(DOWNLOAD_STEP) > names.index(AGGREGATE_STEP):
        found.append("%r must come before %r (the check reads what it downloads)" % (DOWNLOAD_STEP, AGGREGATE_STEP))

    d = live(dl[0])
    if "actions/download-artifact@" not in d:
        found.append("%r must use actions/download-artifact" % DOWNLOAD_STEP)
    if re.search(r"^\s*merge-multiple:", d, re.MULTILINE):
        found.append("%r must not use merge-multiple: every lane writes the same file name and the folder name is the lane" % DOWNLOAD_STEP)
    pat = re.search(r"^\s*pattern:\s*(.+?)\s*$", d, re.MULTILINE)
    if not pat or not pat.group(1).startswith("ci_test_results-selftest-") or \
            not pat.group(1).endswith("-${{ github.run_id }}-${{ github.run_attempt }}"):
        found.append("%r must download ci_test_results-selftest-*-<run id>-<attempt> (this attempt's lane NDJSON only)" % DOWNLOAD_STEP)
    dpath = re.search(r"^\s*path:\s*\$\{\{ runner\.temp \}\}/([A-Za-z0-9_-]+)\s*$", d, re.MULTILINE)
    if not dpath:
        found.append("%r must download into ${{ runner.temp }}/<folder>" % DOWNLOAD_STEP)

    a = live(agg[0])
    call = re.search(r"python\s+tools/check_expected_rows\.py\s+check\b", a)
    if not call:
        found.append("%r does not run python tools/check_expected_rows.py check" % AGGREGATE_STEP)
        return found
    tail = a[call.start():]
    tail = tail[:tail.find("\n\n")] if "\n\n" in tail else tail
    if "--baseline tests/expected_rows" not in tail:
        found.append("the expected-row check must read --baseline tests/expected_rows")
    res = re.search(r"--results\s+\(Join-Path \$env:RUNNER_TEMP '([A-Za-z0-9_-]+)'\)", tail)
    if not res:
        found.append("the expected-row check must read --results (Join-Path $env:RUNNER_TEMP '<folder>')")
    elif dpath and res.group(1) != dpath.group(1):
        found.append("the check reads folder %r but the download writes %r" % (res.group(1), dpath.group(1)))
    before = a[:call.start()]
    init = re.findall(r"^\s*\$rowsRc\s*=\s*(\S+)\s*$", before, re.MULTILINE)
    if not init or init[-1] in ("0", "$null"):
        found.append("$rowsRc must start at a failing code before the check runs (python missing must fail the gate)")
    if not re.search(r"^\s*\$global:LASTEXITCODE\s*=\s*\$null\s*$", before, re.MULTILINE):
        found.append("$global:LASTEXITCODE must be cleared before the check (a stale 0 would read as success)")
    after = a[call.start():]
    if not re.search(r"if\s*\(\s*\$null\s+-ne\s+\$LASTEXITCODE\s*\)\s*\{\s*\$rowsRc\s*=\s*\$LASTEXITCODE\s*\}", after):
        found.append("$rowsRc must take $LASTEXITCODE only when the check ran")
    value = re.search(r"^\s*\$value\s*=\s*if\s*\((.*?)\)\s*\{\s*'false'\s*\}\s*else\s*\{\s*'true'\s*\}\s*$", a, re.MULTILINE)
    if not value:
        found.append("the Aggregate verdicts step lost its `$value = if (...) { 'false' } else { 'true' }` line")
    elif not re.fullmatch(r"\s*\$rc\s+-eq\s+0\s+-and\s+\$rowsRc\s+-eq\s+0\s*", value.group(1)):
        found.append("has_failures must be false only when $rc -eq 0 -and $rowsRc -eq 0 (got %r)" % value.group(1).strip())
    elif a.find(value.group(0)) < call.start():
        found.append("$value is decided before the expected-row check ran")
    if re.search(r"^\s*continue-on-error:", a, re.MULTILINE):
        found.append("%r has continue-on-error: a failing check would stay green" % AGGREGATE_STEP)
    if re.search(r"\|\|\s*(?:true\b|:(?![A-Za-z0-9_])|exit\s+0\b)", tail):
        found.append("the expected-row check's exit code is hidden")
    if "expected_rows_exit" not in a:
        found.append("the diag.selftest_gate.verdict row lost details.expected_rows_exit")

    if len(up) != 1 or "expected-rows.txt" not in live(up[0]) or "expected-rows.json" not in live(up[0]):
        found.append("%r must also upload expected-rows.txt and expected-rows.json" % UPLOAD_STEP)
    if not any(n == "Checkout repository" for n in names):
        found.append("selftest-gate needs the repository checkout (tests/expected_rows and the tool come from it)")
    return found


GOOD = """  selftest-gate:
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

      - name: Aggregate verdicts
        id: aggregate
        shell: pwsh
        run: |
          & .\\tools\\aggregate_selftest_verdicts.ps1 `
            -ExpectedLanes @('real', 'uv')
          $rc = $LASTEXITCODE
          # a comment that mentions $rowsRc = 0 is ignored
          $rowsRc = 2
          $rowsTxt = Join-Path $env:RUNNER_TEMP 'expected-rows.txt'
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
          $value = if ($rc -eq 0 -and $rowsRc -eq 0) { 'false' } else { 'true' }
          "has_failures=$value" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding ascii -Append
          details = [ordered]@{ exit_code = $rc; expected_rows_exit = $rowsRc }
          exit 0

      - name: Upload gate report
        if: ${{ always() }}
        uses: actions/upload-artifact@v7
        with:
          path: |
            ${{ runner.temp }}/selftest-gate.json
            ${{ runner.temp }}/expected-rows.txt
            ${{ runner.temp }}/expected-rows.json

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

    def test_missing_download_step(self):
        self.assertCaught(GOOD.replace("Download lane NDJSON", "Download something"), "exactly one step named 'Download lane NDJSON'")

    def test_download_after_the_check(self):
        i = GOOD.index("      - name: Download lane NDJSON")
        j = GOOD.index("      - name: Aggregate verdicts")
        k = GOOD.index("      - name: Upload gate report")
        bad = GOOD[:i] + GOOD[j:k] + GOOD[i:j] + GOOD[k:]
        self.assertCaught(bad, "must come before")

    def test_merge_multiple(self):
        self.assertCaught(GOOD.replace("          path: ${{ runner.temp }}/lane-ndjson", "          merge-multiple: true\n          path: ${{ runner.temp }}/lane-ndjson"), "merge-multiple")

    def test_pattern_that_takes_other_attempts(self):
        self.assertCaught(GOOD.replace("-${{ github.run_id }}-${{ github.run_attempt }}\n", "\n"), "this attempt")

    def test_pattern_for_other_artifacts(self):
        self.assertCaught(GOOD.replace("pattern: ci_test_results-selftest-*", "pattern: selftest-verdict-*"), "this attempt")

    def test_check_not_run(self):
        self.assertCaught(GOOD.replace("tools/check_expected_rows.py", "tools/other.py"), "does not run")

    def test_wrong_baseline_folder(self):
        self.assertCaught(GOOD.replace("--baseline tests/expected_rows", "--baseline tests/other"), "--baseline")

    def test_results_folder_differs_from_download(self):
        self.assertCaught(GOOD.replace("'lane-ndjson'", "'elsewhere'"), "download writes")

    def test_exit_code_starts_at_success(self):
        self.assertCaught(GOOD.replace("          $rowsRc = 2\n", "          $rowsRc = 0\n"), "must start at a failing code")

    def test_exit_code_never_initialised(self):
        self.assertCaught(GOOD.replace("          $rowsRc = 2\n", ""), "must start at a failing code")

    def test_last_exit_code_not_cleared(self):
        self.assertCaught(GOOD.replace("          $global:LASTEXITCODE = $null\n", ""), "must be cleared")

    def test_unconditional_exit_code_copy(self):
        self.assertCaught(GOOD.replace("if ($null -ne $LASTEXITCODE) { $rowsRc = $LASTEXITCODE }", "$rowsRc = $LASTEXITCODE"), "only when the check ran")

    def test_result_not_in_has_failures(self):
        self.assertCaught(GOOD.replace("$rc -eq 0 -and $rowsRc -eq 0", "$rc -eq 0"), "has_failures must be false only")

    def test_result_ored_in_wrongly(self):
        self.assertCaught(GOOD.replace("$rc -eq 0 -and $rowsRc -eq 0", "$rc -eq 0 -or $rowsRc -eq 0"), "has_failures must be false only")

    def test_value_decided_before_the_check(self):
        line = "          $value = if ($rc -eq 0 -and $rowsRc -eq 0) { 'false' } else { 'true' }\n"
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
        self.assertCaught(bad, "must start at a failing code")

    def test_missing_gate_job(self):
        self.assertEqual(wiring_problems("x: y\n"), ["there is no selftest-gate job"])


if __name__ == "__main__":
    unittest.main()
