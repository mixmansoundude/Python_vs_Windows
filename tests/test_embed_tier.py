"""Tests for the REQ-009 Tier 5 (standalone embeddable-Python fallback) helpers:
tools/embed_pyver_check.py's version-table resolution logic, and byte-equality of both
tools/embed_extract.ps1 and tools/embed_pyver_check.py against their embedded HP_EMBED_EXTRACT /
HP_EMBED_PYVER_CHECK base64 payloads in run_setup.bat (mirrors PayloadSync in
test_collect_submodules.py / test_hidden_import_scan.py). Also asserts the batch-side
HP_EMBED_LATEST_PATCH/HP_EMBED_LATEST_SHA256 constants agree with the Python table's LATEST_MINOR
entry -- a refresh that updates one but not the other must be caught here, not discovered live.
"""
import base64
import io
import os
import re
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from tools.embed_pyver_check import (
    EMBED_PYTHON_TABLE,
    FLOOR_MINOR,
    LATEST_MINOR,
    main,
    pick_minor,
    resolve_requested_minor,
    resolve_table_entry,
)

REPO = Path(__file__).resolve().parent.parent
BAT = REPO / "run_setup.bat"
PS_SOURCE = REPO / "tools" / "embed_extract.ps1"
PY_SOURCE = REPO / "tools" / "embed_pyver_check.py"


class ResolveRequestedMinor(unittest.TestCase):
    def test_empty_pyspec_returns_none(self):
        self.assertIsNone(resolve_requested_minor(""))
        self.assertIsNone(resolve_requested_minor(None))

    def test_extracts_minor_from_various_pyspec_shapes(self):
        self.assertEqual(resolve_requested_minor("python>=3.10,<4.0"), "3.10")
        self.assertEqual(resolve_requested_minor("python=3.11"), "3.11")
        self.assertEqual(resolve_requested_minor("python==3.12"), "3.12")
        self.assertEqual(resolve_requested_minor("python<3.13"), "3.13")

    def test_unparseable_pyspec_returns_none(self):
        self.assertIsNone(resolve_requested_minor("not-a-version-spec"))


class PickMinor(unittest.TestCase):
    # A range resolves to the newest table minor it allows (as uv and conda do), never to its lower bound;
    # None means no table minor is allowed and main() falls back to the floor or the newest minor with a WARN.
    def test_exact_requests_pick_that_minor(self):
        for spec in ("python=3.12", "python==3.12", "python=3.12.4"):
            self.assertEqual(pick_minor(spec), "3.12", spec)

    def test_open_range_picks_the_newest_minor(self):
        self.assertEqual(pick_minor("python>=3.10,<4.0"), LATEST_MINOR)
        self.assertEqual(pick_minor("python>=3"), LATEST_MINOR)

    def test_bounded_range_picks_the_newest_minor_inside_it(self):
        self.assertEqual(pick_minor("python>=3.11,<3.13"), "3.12")
        self.assertEqual(pick_minor("python<3.13"), "3.12")
        self.assertEqual(pick_minor("python<=3.12"), "3.12")
        self.assertEqual(pick_minor("python>3.10,<3.12"), "3.11")

    def test_exclusion_skips_only_that_minor(self):
        self.assertEqual(pick_minor("python!=" + LATEST_MINOR), sorted(
            (m for m in EMBED_PYTHON_TABLE if m != LATEST_MINOR), key=lambda m: tuple(map(int, m.split("."))))[-1])

    def test_unsatisfiable_or_empty_requests_pick_nothing(self):
        for spec in ("python=3.99", "python>=3.99", "python=3.9", "python<3.9", "python>3.10,<3.11", "", None):
            self.assertIsNone(pick_minor(spec), spec)


class ResolveTableEntry(unittest.TestCase):
    def test_exact_match_no_fallback(self):
        minor, patch, sha256, fell_back = resolve_table_entry("3.11")
        self.assertEqual(minor, "3.11")
        self.assertEqual(patch, EMBED_PYTHON_TABLE["3.11"][0])
        self.assertEqual(sha256, EMBED_PYTHON_TABLE["3.11"][1])
        self.assertFalse(fell_back)

    def test_below_floor_falls_back_to_floor(self):
        minor, patch, sha256, fell_back = resolve_table_entry("3.6")
        self.assertEqual(minor, FLOOR_MINOR)
        self.assertTrue(fell_back)

    def test_above_ceiling_falls_back_to_latest(self):
        minor, patch, sha256, fell_back = resolve_table_entry("3.99")
        self.assertEqual(minor, LATEST_MINOR)
        self.assertTrue(fell_back)

    def test_table_scope_is_non_eol_minors_only(self):
        # Not a moving-target assertion against python.org -- just guards against the table
        # silently growing back toward ancient/EOL versions, or losing its floor/ceiling entries.
        self.assertIn(FLOOR_MINOR, EMBED_PYTHON_TABLE)
        self.assertIn(LATEST_MINOR, EMBED_PYTHON_TABLE)
        self.assertGreaterEqual(len(EMBED_PYTHON_TABLE), 5)


class BatchPythonConsistency(unittest.TestCase):
    def test_batch_latest_constants_match_python_table(self):
        bat = BAT.read_text(encoding="ascii", errors="replace")
        patch_m = re.search(r'set "HP_EMBED_LATEST_PATCH=([0-9.]+)"', bat)
        sha_m = re.search(r'set "HP_EMBED_LATEST_SHA256=([0-9a-f]+)"', bat)
        self.assertIsNotNone(patch_m, "HP_EMBED_LATEST_PATCH not found in run_setup.bat")
        self.assertIsNotNone(sha_m, "HP_EMBED_LATEST_SHA256 not found in run_setup.bat")
        table_patch, table_sha256 = EMBED_PYTHON_TABLE[LATEST_MINOR]
        self.assertEqual(
            patch_m.group(1), table_patch,
            "HP_EMBED_LATEST_PATCH is out of sync with embed_pyver_check.py's LATEST_MINOR entry.",
        )
        self.assertEqual(
            sha_m.group(1), table_sha256,
            "HP_EMBED_LATEST_SHA256 is out of sync with embed_pyver_check.py's LATEST_MINOR entry.",
        )


class MainDispatch(unittest.TestCase):
    # Exercises main()'s early-return branches directly with no network I/O (both return before
    # download_and_verify/extract_and_patch are ever called), and its swap branch with those two
    # functions mocked. The real swap, its directory move and the floor/ceiling fallbacks run end to
    # end in tests/selfapps_embed_version.ps1 (rows self.embed.version.*).
    def _run_main(self, argv, env):
        buf = io.StringIO()
        with patch.object(sys, "argv", argv), \
             patch.dict(os.environ, env, clear=True), \
             redirect_stdout(buf):
            rc = main()
        return rc, buf.getvalue().strip()

    def test_no_pyspec_is_unchanged(self):
        rc, out = self._run_main(["embed_pyver_check.py", "/dest"], {})
        self.assertEqual(rc, 0)
        self.assertEqual(out, "unchanged|{}".format(LATEST_MINOR))

    def test_exact_latest_request_is_unchanged(self):
        rc, out = self._run_main(
            ["embed_pyver_check.py", "/dest"], {"PYSPEC": "python={}".format(LATEST_MINOR)})
        self.assertEqual(rc, 0)
        self.assertEqual(out, "unchanged|{}".format(LATEST_MINOR))

    def test_above_ceiling_request_is_fellback_not_unchanged(self):
        # derived requirement (the fix): previously this branch emitted "unchanged", making the
        # "fellback" WARN tag unreachable for above-ceiling requests even though a below-floor
        # request already correctly reached it (see ResolveTableEntry.test_above_ceiling_falls_
        # back_to_latest / test_below_floor_falls_back_to_floor for the table-resolution half of
        # this, which was already correct -- only main()'s dispatch was wrong).
        rc, out = self._run_main(
            ["embed_pyver_check.py", "/dest"], {"PYSPEC": "python>=3.99"})
        self.assertEqual(rc, 0)
        self.assertEqual(out, "fellback|{}".format(LATEST_MINOR))


    def test_open_range_is_unchanged_not_a_swap_to_its_lower_bound(self):
        # "python>=3.10,<4.0" used to resolve to its first number (3.10) and swap down to the floor.
        rc, out = self._run_main(
            ["embed_pyver_check.py", "/dest"], {"PYSPEC": "python>=3.10,<4.0"})
        self.assertEqual(rc, 0)
        self.assertEqual(out, "unchanged|{}".format(LATEST_MINOR))

    def _run_swap(self, pyspec):
        calls = []
        with patch("tools.embed_pyver_check.download_and_verify", lambda url, sha, dest: calls.append((url, sha))), \
             patch("tools.embed_pyver_check.extract_and_patch", lambda zip_path, dest: calls.append(("extract", dest))):
            rc, out = self._run_main(["embed_pyver_check.py", "/dest"], {"PYSPEC": pyspec})
        return rc, out, calls

    def test_bounded_range_downloads_the_newest_minor_inside_it(self):
        rc, out, calls = self._run_swap("python>=3.11,<3.13")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "swapped|3.12|/dest_swap")
        self.assertEqual(calls[0], (
            "https://www.python.org/ftp/python/{p}/python-{p}-embed-amd64.zip".format(p=EMBED_PYTHON_TABLE["3.12"][0]),
            EMBED_PYTHON_TABLE["3.12"][1]))

    def test_below_floor_request_downloads_the_floor_and_is_tagged_fellback(self):
        rc, out, calls = self._run_swap("python=3.9")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "fellback|{}|/dest_swap".format(FLOOR_MINOR))
        self.assertIn(EMBED_PYTHON_TABLE[FLOOR_MINOR][1], [c[1] for c in calls if len(c) == 2 and c[0] != "extract"])


class PayloadSync(unittest.TestCase):
    def test_embed_extract_ps1_matches_source(self):
        # derived requirement: tools/embed_extract.ps1 carries .gitattributes' `*.ps1 text
        # eol=crlf`, so a checkout on Windows CI materializes CRLF line endings regardless of
        # what the payload was encoded from -- normalize both sides before comparing so this
        # test verifies content, not incidental checkout-time line-ending translation (which
        # PowerShell itself does not care about either).
        bat = BAT.read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_EMBED_EXTRACT=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_EMBED_EXTRACT payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).replace(b"\r\n", b"\n")
        source = PS_SOURCE.read_bytes().replace(b"\r\n", b"\n")
        self.assertEqual(
            decoded, source,
            "HP_EMBED_EXTRACT base64 is out of sync with tools/embed_extract.ps1; re-encode it.",
        )

    def test_embed_pyver_check_py_matches_source(self):
        bat = BAT.read_text(encoding="ascii", errors="replace")
        m = re.search(r'set "HP_EMBED_PYVER_CHECK=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_EMBED_PYVER_CHECK payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1))
        source = PY_SOURCE.read_bytes()
        self.assertEqual(
            decoded, source,
            "HP_EMBED_PYVER_CHECK base64 is out of sync with tools/embed_pyver_check.py; re-encode it.",
        )


class EmbedVersionScenarioPins(unittest.TestCase):
    """Static pins for tests/selfapps_embed_version.ps1 (rows self.embed.version.*): the scenario that
    proves the swap path (a second download, rd, move) really runs. The script reads the table at run
    time, so a refresh needs no edit there, but the swap scenario needs 3.12 strictly inside the table."""

    SCRIPT = REPO / "tests" / "selfapps_embed_version.ps1"
    WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
    IDS = ("self.embed.version.swap", "self.embed.version.floor", "self.embed.version.ceiling", "self.embed.version.range")

    @classmethod
    def script_issues(cls, text):
        issues = []
        for row_id in cls.IDS:
            # skip rows (2), inputs-missing rows (1) and the real row (1): the id stays literal at each call
            if len(re.findall(r"id\s*=\s*'" + re.escape(row_id) + r"'", text)) < 4:
                issues.append("literal id missing: " + row_id)
        tail = [ln.strip() for ln in text.splitlines() if ln.strip()][-2:]
        if tail != ["if (-not ($passSwap -and $passFloor -and $passCeiling -and $passRange)) { exit 1 }", "exit 0"]:
            issues.append("script must end with its own exit 1 / exit 0")
        if text.count("$d.requestLog") < 4:
            issues.append("every scenario must require the request log line")
        if "taskkill" not in text:
            issues.append("no watchdog")
        if any(ord(c) > 127 for c in text):
            issues.append("not ascii")
        return issues

    @classmethod
    def step_issues(cls, workflow_text):
        m = re.search(r"\n( +)- name: \"Self-test: embed tier honors[^\n]*\n(.*?)(?=\n\1- name:)", workflow_text, re.S)
        if not m:
            return ["workflow step missing"]
        block = m.group(2)
        issues = []
        if "matrix.mode == 'real'" not in block:
            issues.append("step is not real-lane only")
        if "selfapps_embed_version.ps1" not in block:
            issues.append("step does not run the script")
        if "continue-on-error" in block:
            issues.append("step must gate")
        for ext in ("~embver_boot.log", "~setup.log", "~run.out.txt", "runtime.txt"):
            if "tests/~selftest_embed_ver_*/" + ext not in workflow_text:
                issues.append("artifact path missing: " + ext)
        return issues

    def test_the_tier_finds_the_request_before_the_version_check(self):
        # A chain with neither uv nor Miniconda reaches the embed tier before ~detect_python.py ran, so PYSPEC was
        # empty and runtime.txt / pyproject.toml were ignored (run 40074772192). The tier now runs the helper under
        # its own fresh interpreter, after the extraction line and before it emits and runs ~embed_pyver_check.py.
        bat = BAT.read_bytes().decode("ascii", "replace")
        extracted = bat.index('call :log "[INFO] embed fallback: %HP_EMBED_LATEST_PATCH% extracted and verified."')
        ready = bat.index("\r\n:embed_pyspec_ready\r\n", extracted)
        emit = bat.index('call :emit_from_base64 "~embed_pyver_check.py"', extracted)
        self.assertLess(extracted, ready)
        self.assertLess(ready, emit)
        block = bat[extracted:ready]
        self.assertIn('"%HP_EMBED_PY%" "~detect_python.py" > "~py_spec.txt"', block)
        self.assertIn("if defined PYSPEC goto :embed_pyspec_ready", block)
        self.assertIn('set "PYSPEC=%PVW_TARGET_PY%"', block)
        self.assertIn("a Python version request was found in this folder.", block)
        # the value can hold angle brackets, so it is never echoed or logged
        live = [ln for ln in block.splitlines() if not ln.lstrip().lower().startswith("rem ")]
        self.assertFalse([ln for ln in live if "%PYSPEC%" in ln], live)

    def test_script_is_wired_correctly(self):
        self.assertEqual(self.script_issues(self.SCRIPT.read_text(encoding="utf-8")), [])

    def test_workflow_step_gates_on_the_real_lane(self):
        self.assertEqual(self.step_issues(self.WORKFLOW.read_text(encoding="utf-8")), [])

    def test_swap_minor_sits_inside_the_table(self):
        # the swap scenario asks for 3.12: it must be in the table and neither the newest (no swap
        # happens) nor the oldest (it would be the floor scenario); the script fails its rows otherwise
        self.assertIn("'3.12'", self.SCRIPT.read_text(encoding="utf-8"))
        self.assertIn("3.12", EMBED_PYTHON_TABLE)
        self.assertNotEqual("3.12", LATEST_MINOR)
        self.assertNotEqual("3.12", FLOOR_MINOR)

    def test_each_rule_can_fail(self):
        good = self.SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(self.script_issues(good.replace("self.embed.version.floor", "self.embed.version.flor")))
        self.assertTrue(self.script_issues(good.rstrip() + "\nexit 3\n"))
        self.assertTrue(self.script_issues(good.replace("taskkill", "kill")))
        self.assertTrue(self.script_issues(good.replace("$d.requestLog", "$d.swappedLog")))
        wf = self.WORKFLOW.read_text(encoding="utf-8")
        self.assertTrue(self.step_issues(wf.replace("selfapps_embed_version.ps1", "selfapps_other.ps1", 1)))
        self.assertTrue(self.step_issues(wf.replace(
            "if: ${{ !cancelled() && matrix.mode == 'real' }}\n        shell: pwsh\n        run: |\n          & tests\\selfapps_embed_version.ps1",
            "continue-on-error: true\n        shell: pwsh\n        run: |\n          & tests\\selfapps_embed_version.ps1")))


if __name__ == "__main__":
    unittest.main()
