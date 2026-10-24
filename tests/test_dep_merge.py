"""Tests for tools/dep_merge.py -- merges requirements.txt, the pyproject.toml dependencies and the PEP 723
header dependencies into one list (CLAUDE.md Item 89, README REQ-005.1).

The helper runs in the app folder and reads fixed file names, so every case builds a scratch folder, runs the
script there with subprocess and reads the files it wrote. Two phases are covered:
- a cold run (no snapshot): the union of the lists, a conflict resolved by rank (header, pyproject.toml,
  requirements.txt) and reported;
- a later run (snapshots left by the previous good run): what the user changed since is theirs. An add is added,
  a removal from a file we write stays removed, a pin the user edited beats the unchanged copy of the old pin,
  and pyproject.toml, which we never write, keeps its packages alive.
Also: exit codes, ASCII-only report, Python 3.9 grammar guard, batch wiring, HP_DEP_MERGE payload sync.
"""
import ast
import base64
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "dep_merge.py"
BAT = REPO / "run_setup.bat"

FILES = {"req": "requirements.txt", "pyproject": "~requirements.pyproject.txt", "pep723": "~requirements.pep723.txt"}
BASES = {"req": "~dep_base.requirements.txt", "pyproject": "~dep_base.pyproject.txt", "pep723": "~dep_base.pep723.txt"}


def lines(*items):
    return "\n".join(items) + "\n"


class Case:
    """A scratch app folder; run() executes the helper there."""

    def __init__(self, req=None, pyproject=None, pep723=None, base_req=None, base_pyproject=None, base_pep723=None):
        self.td = tempfile.TemporaryDirectory()
        self.dir = Path(self.td.name)
        for key, value in (("req", req), ("pyproject", pyproject), ("pep723", pep723)):
            if value is not None:
                (self.dir / FILES[key]).write_text(value, encoding="utf-8")
        for key, value in (("req", base_req), ("pyproject", base_pyproject), ("pep723", base_pep723)):
            if value is not None:
                (self.dir / BASES[key]).write_text(value, encoding="utf-8")
        self.proc = None

    def run(self):
        self.proc = subprocess.run([sys.executable, str(SOURCE)], cwd=self.dir, capture_output=True, text=True)
        return self.proc.returncode

    def read(self, name):
        path = self.dir / name
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else None

    @property
    def merged(self):
        return self.read("requirements.txt")

    @property
    def removed(self):
        return self.read("~dep_merge.removed.txt")

    @property
    def report(self):
        return self.read("~dep_merge.report.txt")

    @property
    def changed(self):
        return (self.dir / "~dep_merge.changed.txt").exists()

    def report_has(self, *needles):
        return any(all(n in ln for n in needles) for ln in (self.report or []))

    def snapshot(self):
        """What the batch does at the end of a good run: copy the three lists as they now stand."""
        for key in FILES:
            src = self.dir / (FILES[key] if key == "req" else FILES[key])
            dst = self.dir / BASES[key]
            if src.exists():
                dst.write_bytes(src.read_bytes())
            elif dst.exists():
                dst.unlink()

    def close(self):
        self.td.cleanup()


class ColdRun(unittest.TestCase):
    def tearDown(self):
        for c in getattr(self, "cases", []):
            c.close()

    def case(self, **kw):
        c = Case(**kw)
        self.cases = getattr(self, "cases", []) + [c]
        return c

    def test_union_of_three_lists(self):
        c = self.case(req=lines("termcolor"), pyproject=lines("iniconfig"), pep723=lines("toolz>=1.0"))
        self.assertEqual(c.run(), 0, c.proc.stderr)
        self.assertEqual(sorted(c.merged), ["iniconfig", "termcolor", "toolz>=1.0"])
        self.assertEqual(c.removed, [])
        self.assertTrue(c.report_has("merged", "3 packages"), c.report)

    def test_requirements_order_comes_first(self):
        c = self.case(req=lines("b", "a"), pep723=lines("c"))
        c.run()
        self.assertEqual(c.merged, ["b", "a", "c"])

    def test_header_outranks_pyproject_outranks_requirements(self):
        c = self.case(req=lines("six==1.15.0"), pyproject=lines("six==1.16.0"), pep723=lines("six==1.17.0"))
        c.run()
        self.assertEqual(c.merged, ["six==1.17.0"])
        self.assertTrue(c.report_has("Conflict for six", "requirements.txt", "pyproject.toml", "PEP 723 header"), c.report)
        c2 = self.case(req=lines("six==1.15.0"), pyproject=lines("six==1.16.0"))
        c2.run()
        self.assertEqual(c2.merged, ["six==1.16.0"])
        self.assertTrue(c2.report_has("Conflict for six", "using six==1.16.0", "pyproject.toml"), c2.report)

    def test_bare_name_next_to_a_pin_is_not_a_conflict(self):
        c = self.case(req=lines("six"), pep723=lines("six>=1.16"))
        c.run()
        self.assertEqual(c.merged, ["six>=1.16"])
        self.assertFalse(c.report_has("Conflict"), c.report)
        c2 = self.case(req=lines("six>=1.16"), pep723=lines("six"))
        c2.run()
        self.assertEqual(c2.merged, ["six>=1.16"], "a bare name from a higher list does not drop the pin")
        self.assertFalse(c2.report_has("Conflict"), c2.report)

    def test_same_package_spelled_differently_is_one_package(self):
        c = self.case(req=lines("Typing_Extensions>=4"), pep723=lines("typing-extensions >= 4 "))
        c.run()
        self.assertEqual(len(c.merged), 1, c.merged)
        self.assertFalse(c.report_has("Conflict"), c.report)

    def test_clause_order_and_spaces_are_not_a_conflict(self):
        c = self.case(req=lines("pandas>=1.0,<3"), pyproject=lines("pandas < 3, >= 1.0"))
        c.run()
        self.assertFalse(c.report_has("Conflict"), c.report)

    def test_markers_and_extras_survive(self):
        c = self.case(req=lines('colorama>=0.4; sys_platform == "win32"'), pep723=lines("pandas[excel]>=2"))
        c.run()
        self.assertIn('colorama>=0.4; sys_platform == "win32"', c.merged)
        self.assertIn("pandas[excel]>=2", c.merged)

    def test_lines_that_name_no_package_stay_in_requirements(self):
        c = self.case(req=lines("-r other.txt", "git+https://example.invalid/x.git", "six"), pep723=lines("toolz"))
        c.run()
        self.assertEqual(c.merged[:2], ["six", "toolz"])
        self.assertIn("-r other.txt", c.merged)
        self.assertIn("git+https://example.invalid/x.git", c.merged)

    def test_comments_blank_lines_and_bom_are_ignored(self):
        c = self.case(req="\ufeff# a comment\n\nsix  # trailing\n", pep723=lines("toolz"))
        c.run()
        self.assertEqual(c.merged, ["six", "toolz"])

    def test_one_list_is_nothing_to_merge(self):
        c = self.case(req=lines("six"))
        self.assertEqual(c.run(), 1)
        self.assertEqual(c.merged, ["six"], "requirements.txt is left exactly as it was")
        self.assertIsNone(c.report)
        c2 = self.case(pep723=lines("six"))
        self.assertEqual(c2.run(), 1)
        self.assertIsNone(c2.merged)

    def test_report_is_ascii_and_capped(self):
        many = lines(*["pkg%d==1" % i for i in range(60)])
        other = lines(*["pkg%d==2" % i for i in range(60)])
        c = self.case(req=many, pep723=other)
        c.run()
        self.assertLessEqual(len(c.report), 30)
        (c.dir / "~dep_merge.report.txt").read_bytes().decode("ascii")

    def test_non_ascii_text_is_replaced_in_the_report(self):
        c = self.case(req=lines("six==1.15.0 ; python_version >= '3.6' # caf\u00e9"), pep723=lines("six==1.16.0"))
        c.run()
        (c.dir / "~dep_merge.report.txt").read_bytes().decode("ascii")


class LaterRun(unittest.TestCase):
    """Snapshots exist: the last good run left requirements.txt and the header equal to the merged list."""

    def tearDown(self):
        for c in getattr(self, "cases", []):
            c.close()

    def case(self, **kw):
        c = Case(**kw)
        self.cases = getattr(self, "cases", []) + [c]
        return c

    BASE = lines("termcolor", "iniconfig", "toolz")
    HEADER = lines("termcolor>=2.0", "iniconfig>=2.0", "toolz>=1.0")

    def settled(self, **kw):
        kw.setdefault("base_req", self.BASE)
        kw.setdefault("base_pep723", self.HEADER)
        return self.case(**kw)

    def test_nothing_changed_keeps_everything_and_asks_nothing(self):
        c = self.settled(req=self.BASE, pep723=self.HEADER)
        self.assertEqual(c.run(), 0)
        self.assertEqual(c.merged, ["termcolor>=2.0", "iniconfig>=2.0", "toolz>=1.0"])
        self.assertEqual(c.removed, [])
        self.assertFalse(c.report_has("Conflict"), c.report)
        self.assertFalse(c.report_has("Removed"), c.report)

    def test_a_package_deleted_from_requirements_stays_removed(self):
        c = self.settled(req=lines("termcolor", "iniconfig"), pep723=self.HEADER)
        c.run()
        self.assertEqual(c.merged, ["termcolor>=2.0", "iniconfig>=2.0"])
        self.assertEqual(c.removed, ["toolz"], "the header still lists it, so the batch must run uv remove --script")
        self.assertTrue(c.report_has("Removed toolz", "requirements.txt"), c.report)

    def test_a_package_deleted_from_the_header_stays_removed(self):
        c = self.settled(req=self.BASE, pep723=lines("termcolor>=2.0", "toolz>=1.0"))
        c.run()
        self.assertNotIn("iniconfig", " ".join(c.merged))
        self.assertEqual(c.removed, [], "it is already gone from the header")
        self.assertTrue(c.report_has("Removed iniconfig", "the PEP 723 header"), c.report)

    def test_a_package_deleted_from_both_is_gone(self):
        c = self.settled(req=lines("termcolor", "iniconfig"), pep723=lines("termcolor>=2.0", "iniconfig>=2.0"))
        c.run()
        self.assertNotIn("toolz", " ".join(c.merged))
        self.assertEqual(c.removed, [])

    def test_a_package_added_to_requirements_is_added(self):
        c = self.settled(req=lines("termcolor", "iniconfig", "toolz", "six"), pep723=self.HEADER)
        c.run()
        self.assertIn("six", c.merged)
        self.assertEqual(len(c.merged), 4)

    def test_a_package_added_to_the_header_is_added(self):
        c = self.settled(req=self.BASE, pep723=self.HEADER + "six>=1.16\n")
        c.run()
        self.assertIn("six>=1.16", c.merged)

    def test_a_package_added_to_pyproject_is_added(self):
        c = self.settled(req=self.BASE, pep723=self.HEADER, pyproject=lines("six"), base_pyproject="")
        c.run()
        self.assertIn("six", c.merged)

    def test_removed_from_requirements_but_pyproject_still_lists_it_stays(self):
        c = self.settled(req=lines("termcolor", "iniconfig"), pep723=self.HEADER, pyproject=lines("toolz"),
                         base_pyproject=lines("toolz"))
        c.run()
        self.assertIn("toolz>=1.0", c.merged)
        self.assertEqual(c.removed, [])
        self.assertTrue(c.report_has("toolz was removed from requirements.txt", "pyproject.toml still lists it"), c.report)

    def test_removed_from_pyproject_with_the_other_lists_unchanged_is_removed(self):
        c = self.settled(req=self.BASE, pep723=self.HEADER, pyproject=lines("termcolor"),
                         base_pyproject=lines("termcolor", "toolz"))
        c.run()
        self.assertNotIn("toolz", " ".join(c.merged))
        self.assertEqual(c.removed, ["toolz"])

    def test_a_header_we_did_not_write_keeps_a_package_alive(self):
        # No header snapshot: the header is the user's own file, so it still declares toolz.
        c = self.case(req=lines("termcolor", "iniconfig"), base_req=self.BASE, pep723=self.HEADER)
        c.run()
        self.assertIn("toolz>=1.0", c.merged)

    def test_a_pin_edited_in_requirements_beats_the_unchanged_header_pin(self):
        c = self.settled(req=lines("termcolor==2.1.0", "iniconfig", "toolz"), pep723=self.HEADER)
        c.run()
        self.assertIn("termcolor==2.1.0", c.merged)
        self.assertFalse(c.report_has("Conflict"), c.report)

    def test_a_pin_edited_in_the_header_beats_the_unchanged_requirements_pin(self):
        c = self.case(req=lines("termcolor==2.1.0", "iniconfig"), base_req=lines("termcolor==2.1.0", "iniconfig"),
                      pep723=lines("termcolor>=2.3", "iniconfig>=2.0"), base_pep723=lines("termcolor>=2.0", "iniconfig>=2.0"))
        c.run()
        self.assertIn("termcolor>=2.3", c.merged)

    def test_both_edited_differently_follows_the_rank_and_says_so(self):
        c = self.settled(req=lines("termcolor==2.1.0", "iniconfig", "toolz"),
                         pep723=lines("termcolor>=2.3", "iniconfig>=2.0", "toolz>=1.0"))
        c.run()
        self.assertIn("termcolor>=2.3", c.merged)
        self.assertTrue(c.report_has("Conflict for termcolor"), c.report)

    def test_dropping_a_pin_by_editing_to_a_bare_name_is_respected(self):
        c = self.settled(req=lines("termcolor", "iniconfig", "toolz"), pep723=self.HEADER,
                         base_req=lines("termcolor>=2.0", "iniconfig", "toolz"))
        c.run()
        self.assertIn("termcolor", c.merged, c.merged)
        self.assertNotIn("termcolor>=2.0", c.merged)

    def test_a_missing_list_casts_no_vote(self):
        # requirements.txt was deleted: nothing was removed from it, so the header's packages all stay.
        c = self.settled(pep723=self.HEADER, pyproject=lines("six"), base_pyproject="")
        self.assertEqual(c.run(), 0)
        self.assertEqual(len(c.merged), 4)

    def test_an_unreadable_snapshot_is_a_cold_run(self):
        c = self.case(req=lines("termcolor"), pep723=lines("toolz"), base_req="\x00\x01garbage\n")
        self.assertEqual(c.run(), 0)
        self.assertEqual(sorted(c.merged), ["termcolor", "toolz"])

    def test_the_second_run_with_fresh_snapshots_changes_nothing(self):
        c = self.case(req=lines("a", "b==1"), pyproject=lines("c"), pep723=lines("b>=1", "d"))
        c.run()
        first = c.merged
        c.snapshot()
        (c.dir / "~dep_merge.report.txt").unlink()
        c.run()
        self.assertEqual(c.merged, first)
        self.assertFalse(c.report_has("Conflict"), c.report)
        self.assertFalse(c.report_has("Removed"), c.report)


class ChangedFlag(unittest.TestCase):
    """~dep_merge.changed.txt tells the batch not to skip the install as already satisfied."""

    def tearDown(self):
        for c in getattr(self, "cases", []):
            c.close()

    def case(self, **kw):
        c = Case(**kw)
        self.cases = getattr(self, "cases", []) + [c]
        return c

    def test_a_cold_merge_is_a_change(self):
        c = self.case(req=lines("a"), pep723=lines("b"))
        c.run()
        self.assertTrue(c.changed)

    def test_lists_equal_to_their_snapshots_are_not_a_change(self):
        c = self.case(req=lines("a"), pep723=lines("a>=1"), base_req=lines("a"), base_pep723=lines("a>=1"))
        self.assertEqual(c.run(), 0)
        self.assertFalse(c.changed)

    def test_an_edited_list_is_a_change(self):
        c = self.case(req=lines("a==2"), pep723=lines("a>=1"), base_req=lines("a"), base_pep723=lines("a>=1"))
        c.run()
        self.assertTrue(c.changed)

    def test_a_list_with_no_snapshot_is_a_change(self):
        c = self.case(req=lines("a"), pep723=lines("a>=1"), base_req=lines("a"))
        c.run()
        self.assertTrue(c.changed)

    def test_requirements_alone_with_a_snapshot_still_reports_a_change_and_is_not_rewritten(self):
        c = self.case(req="# mine\nsix\ntoolz\n", base_req=lines("six"))
        self.assertEqual(c.run(), 0)
        self.assertTrue(c.changed)
        self.assertEqual(c.merged, ["# mine", "six", "toolz"], "a single list is left byte for byte as written")

    def test_requirements_alone_equal_to_its_snapshot_is_nothing_to_do_but_exits_0(self):
        c = self.case(req=lines("six"), base_req=lines("six"))
        self.assertEqual(c.run(), 0)
        self.assertFalse(c.changed)

    def test_an_empty_list_counts_as_absent(self):
        c = self.case(req="", pep723=lines("toolz"))
        self.assertEqual(c.run(), 1)
        self.assertFalse(c.changed)


class InternalError(unittest.TestCase):
    def test_a_blocked_requirements_file_exits_3_and_leaves_no_temp_file(self):
        c = Case(req=lines("six"), pep723=lines("toolz"))
        try:
            # a directory where the temp file goes makes the write fail without touching the inputs
            (c.dir / "~requirements.merge.tmp").mkdir()
            self.assertEqual(c.run(), 3)
            self.assertEqual(c.read("requirements.txt"), ["six"])
            self.assertIn("dep_merge:", c.proc.stderr)
        finally:
            c.close()


class BatchWiring(unittest.TestCase):
    """The batch side. Static, because the batch only runs on Windows."""

    bat = BAT.read_text(encoding="utf-8", errors="replace")

    def test_the_merge_replaces_the_winner_takes_all_copies(self):
        self.assertNotIn('copy /y "%HP_PYPROJ_REQ%" "requirements.txt"', self.bat)
        self.assertNotIn('copy /y "%PEP723_REQ%" "requirements.txt"', self.bat)
        self.assertIn("call :dep_merge_inputs", self.bat)

    def test_the_pyproject_message_no_longer_claims_an_override(self):
        self.assertNotIn("found; overrides requirements.txt", self.bat)


class EmbeddedHelperBaseline(unittest.TestCase):
    def test_source_parses_as_python_39_grammar(self):
        ast.parse(SOURCE.read_text(encoding="utf-8"), feature_version=(3, 9))

    def test_source_is_ascii(self):
        SOURCE.read_bytes().decode("ascii")

    def test_payload_line_fits_the_cmd_limit(self):
        b64 = base64.b64encode(SOURCE.read_bytes()).decode("ascii")
        self.assertLessEqual(len('set "HP_DEP_MERGE=') + len(b64) + 1, 8191)


class PayloadSync(unittest.TestCase):
    def test_embedded_payload_matches_source(self):
        bat = BAT.read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_DEP_MERGE=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_DEP_MERGE payload not found in run_setup.bat")
        self.assertEqual(
            base64.b64decode(m.group(1)), SOURCE.read_bytes(),
            "HP_DEP_MERGE base64 is out of sync with tools/dep_merge.py; "
            "run: python tools/sync_payload.py HP_DEP_MERGE tools/dep_merge.py",
        )


if __name__ == "__main__":
    unittest.main()
