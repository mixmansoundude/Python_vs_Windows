#!/usr/bin/env python3
"""Item 98: the expected-row baseline of the aggregate gate. ASCII only.

The aggregate gate ("Aggregate self-test verdicts") fails on a row with pass:false. A row that was never written
cannot be red: a selfapps script that crashes before its first row, fails to parse, or whose step stops running
leaves no trace in a lane whose step has continue-on-error (Item 84 found it for the self-tests, Item 95 for the
cache health check). This tool closes that hole from the other side. tests/expected_rows/<lane>.txt lists the row
ids a lane must write before run_tests.bat, and `check` fails when one of them is missing from the lane's
ci_test_results artifact.

  check    --results DIR --baseline DIR [--report FILE]
           DIR holds one sub-folder per downloaded artifact, named ci_test_results-selftest-<lane>-<run>-<attempt>
           (actions/download-artifact without merge-multiple). Exit 0 = every lane complete, 1 = a lane or a row is
           missing, 2 = unusable input. Rows in a lane that are not listed are fine (see `unlisted` in the report).
  generate --results DIR [DIR ...] --baseline DIR
           Writes one file per lane with the ids present in every given run (each DIR is one run's artifacts).

A cache lane that wrote self.cache.corrupted or self.cache.bootstrap.failed skipped its battery on purpose (an
infrastructure problem the lane reports as such), so its list is waived for that run and the report says so.
"""
import argparse
import json
import os
import re
import sys

ARTIFACT = re.compile(r"^ci_test_results-selftest-(?P<lane>.+)-\d+-\d+$")
VALID_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.~-]*$")
# derived requirement: the lane-level skip rows written by batch-check.yml when the restored Miniconda was unusable.
WAIVER_ROWS = {"cache": ("self.cache.corrupted", "self.cache.bootstrap.failed")}
SHOW = 40


def lane_of(dirname):
    m = ARTIFACT.match(dirname)
    return m.group("lane") if m else None


def read_ids(folder):
    """Row ids written in every .ndjson file below folder (lines that are not a JSON object are skipped)."""
    ids = set()
    for root, _dirs, files in os.walk(folder):
        for name in files:
            if not name.endswith(".ndjson"):
                continue
            with open(os.path.join(root, name), "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line.startswith("{"):
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    rid = row.get("id") if isinstance(row, dict) else None
                    if isinstance(rid, str) and rid:
                        ids.add(rid)
    return ids


def read_run(results):
    """{lane: set(ids)} for one results folder; two artifacts of one lane are united."""
    lanes = {}
    if not os.path.isdir(results):
        return lanes
    for entry in sorted(os.listdir(results)):
        path = os.path.join(results, entry)
        lane = lane_of(entry)
        if lane is None or not os.path.isdir(path):
            continue
        lanes.setdefault(lane, set()).update(read_ids(path))
    return lanes


def waived(lane, ids):
    return any(w in ids for w in WAIVER_ROWS.get(lane, ()))


def read_baseline(folder):
    """{lane: sorted ids}; raises ValueError for a line that is not a row id."""
    out = {}
    if not os.path.isdir(folder):
        raise ValueError("baseline folder %s does not exist" % folder)
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".txt"):
            continue
        lane = name[:-4]
        ids = []
        with open(os.path.join(folder, name), "r", encoding="ascii") as fh:
            for n, line in enumerate(fh, 1):
                text = line.strip()
                if not text or text.startswith("#"):
                    continue
                if not VALID_ID.match(text):
                    raise ValueError("%s line %d is not a row id: %r" % (name, n, text[:60]))
                ids.append(text)
        out[lane] = ids
    return out


def check(results, baseline_dir):
    baseline = read_baseline(baseline_dir)
    if not baseline:
        raise ValueError("no baseline files in %s" % baseline_dir)
    observed = read_run(results)
    report = {"has_failures": False, "lanes": {}, "unexpected_lanes": sorted(set(observed) - set(baseline) - {"gate"})}
    for lane in sorted(baseline):
        want = baseline[lane]
        entry = {"expected": len(want), "observed": None, "missing": [], "unlisted": 0, "waived": False,
                 "no_results": False}
        report["lanes"][lane] = entry
        if lane not in observed:
            entry["no_results"] = True
            report["has_failures"] = True
            continue
        have = observed[lane]
        entry["observed"] = len(have)
        entry["unlisted"] = len(have - set(want))
        if waived(lane, have):
            entry["waived"] = True
            continue
        entry["missing"] = [rid for rid in want if rid not in have]
        if entry["missing"]:
            report["has_failures"] = True
    return report


def print_report(report):
    for lane, e in report["lanes"].items():
        if e["no_results"]:
            print("expected-rows: lane %s: NO ci_test_results artifact (%d rows expected)" % (lane, e["expected"]))
        elif e["waived"]:
            print("expected-rows: lane %s: waived, the lane reported its own infrastructure skip (%d rows seen)"
                  % (lane, e["observed"]))
        else:
            print("expected-rows: lane %s: %d expected, %d written, %d missing, %d not listed"
                  % (lane, e["expected"], e["observed"], len(e["missing"]), e["unlisted"]))
            for rid in e["missing"][:SHOW]:
                print("expected-rows: MISSING lane=%s id=%s" % (lane, rid))
            if len(e["missing"]) > SHOW:
                print("expected-rows: ... and %d more missing in lane %s" % (len(e["missing"]) - SHOW, lane))
    if report["unexpected_lanes"]:
        print("expected-rows: artifacts for lanes with no baseline file: %s" % ", ".join(report["unexpected_lanes"]))
    print("expected-rows: %s" % ("FAILED" if report["has_failures"] else "every listed row was written"))


def generate(result_dirs, baseline_dir):
    # derived requirement: a list is the ids present in EVERY run it is built from, so every run must hold every lane
    # (a run without a lane's artifact would be left out of that intersection while the header still named it), and a
    # lane that reported its own infrastructure skip in every run has nothing to build from (writing nothing would leave an
    # old list in place and report success). All lanes are checked before any file is written.
    runs = [(os.path.basename(os.path.normpath(folder)), read_run(folder)) for folder in result_dirs]
    lanes = sorted({lane for _name, found in runs for lane in found if lane != "gate"})
    if not lanes:
        raise ValueError("no ci_test_results-selftest-<lane>-<run>-<attempt> folders found")
    plans = []
    for lane in lanes:
        used = []
        for name, found in runs:
            if lane not in found:
                raise ValueError("lane %s has no artifact in run %s; give runs that each hold every lane" % (lane, name))
            if waived(lane, found[lane]):
                print("expected-rows: lane %s: run %s reported an infrastructure skip and is not used" % (lane, name))
                continue
            used.append((name, found[lane]))
        if not used:
            raise ValueError("lane %s reported an infrastructure skip in every run given, so its list was not written; "
                             "add a run in which it ran" % lane)
        plans.append((lane, used))
    os.makedirs(baseline_dir, exist_ok=True)
    for lane, used in plans:
        keep = sorted(set.intersection(*[ids for _name, ids in used]))
        header = [
            "# Item 98: row ids lane '%s' must write before run_tests.bat; the aggregate gate fails when one is" % lane,
            "# missing. One id per line, sorted. Remove an id only when the code stops writing it; add one after it",
            "# has appeared in a green run of this lane (rows not listed here are not checked).",
            "# Generated by: python tools/check_expected_rows.py generate (ids present in every one of: %s)"
            % ", ".join(name for name, _ids in used),
        ]
        with open(os.path.join(baseline_dir, lane + ".txt"), "w", encoding="ascii", newline="\n") as fh:
            fh.write("\n".join(header + keep) + "\n")
        print("expected-rows: wrote %s.txt with %d ids from %d run(s)" % (lane, len(keep), len(used)))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--results", required=True)
    c.add_argument("--baseline", required=True)
    c.add_argument("--report")
    g = sub.add_parser("generate")
    g.add_argument("--results", required=True, nargs="+")
    g.add_argument("--baseline", required=True)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "generate":
            generate(args.results, args.baseline)
            return 0
        report = check(args.results, args.baseline)
    except (ValueError, OSError) as exc:
        print("expected-rows: cannot run: %s" % exc)
        return 2
    print_report(report)
    if args.report:
        with open(args.report, "w", encoding="ascii", newline="\n") as fh:
            json.dump(report, fh, indent=1, sort_keys=True)
            fh.write("\n")
    return 1 if report["has_failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
