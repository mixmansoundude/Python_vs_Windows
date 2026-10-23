"""Item 72 follow-up: both Nuitka builds keep their unpacked files in a per-app cache folder.

A Nuitka --onefile EXE unpacks into a fresh temp folder on every launch by default. The Windows run in
docs/plan-field-report-2026-10.md showed a static --onefile-tempdir-spec makes later launches about 3.7 times
faster, so the two Nuitka command lines in run_setup.bat (:try_nuitka_tier_a and :offer_optimized_build) take
the flag from :nuitka_cache_arg. The rules below read run_setup.bat and the test script as plain text (no
PowerShell or YAML parser) so they run on every lane; the token recipe is also executed, because "two apps
never share a folder" is a property of that one line of Python. Synthetic cases prove each rule can fail.
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_nuitka_cachespec.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"

ROW_SPEC = "self.nuitka.cachespec"
ROW_SAFETY = "self.nuitka.cachesafety"

SPEC_PREFIX = "--onefile-tempdir-spec={CACHE_DIR}/PVW/%ENVNAME%-%HP_NK_TOKEN%"


def lines_of(text):
    return text.splitlines()


def nuitka_command_lines(batch_text):
    return [(i, ln) for i, ln in enumerate(lines_of(batch_text)) if re.match(r'^\s*"%HP_PY%" -m nuitka ', ln)]


def command_problems(batch_text):
    """Each Nuitka command line carries the cache argument between --output-dir=dist and -o, after a call."""
    found = []
    cmds = nuitka_command_lines(batch_text)
    if len(cmds) != 2:
        found.append("expected 2 Nuitka command lines, found %d" % len(cmds))
    lines = lines_of(batch_text)
    for i, ln in cmds:
        if "--output-dir=dist %HP_NUITKA_CACHE_ARG% -o " not in ln:
            found.append("a Nuitka command line lacks %%HP_NUITKA_CACHE_ARG%% after --output-dir=dist: %s" % ln.strip()[:100])
        # the call must come before the command and after the previous label (so it is in the same subroutine)
        j = i - 1
        called = False
        while j >= 0 and not lines[j].startswith(":"):
            if lines[j].strip() == "call :nuitka_cache_arg":
                called = True
            j -= 1
        if not called:
            found.append("no 'call :nuitka_cache_arg' before the Nuitka command line near line %d" % (i + 1))
    return found


def subroutine_body(batch_text):
    lines = lines_of(batch_text)
    starts = [i for i, ln in enumerate(lines) if ln.strip().lower() == ":nuitka_cache_arg"]
    if len(starts) != 1:
        return None
    body = []
    for ln in lines[starts[0] + 1:]:
        if ln.startswith(":") and not ln.lower().startswith(":nuitka_cache_arg_"):
            break
        body.append(ln)
    return "\n".join(body)


def python_snippet(body):
    m = re.search(r'"%HP_PY%" -c "([^"]+)"', body)
    return m.group(1) if m else None


def subroutine_problems(batch_text):
    body = subroutine_body(batch_text)
    if body is None:
        return ["expected exactly one :nuitka_cache_arg label"]
    found = []
    snippet = python_snippet(body)
    if snippet is None:
        found.append("the subroutine has no '%HP_PY%' -c \"...\" token command")
    else:
        if "%" in snippet or '"' in snippet:
            found.append("the Python snippet holds a percent sign or a double quote, which cmd would parse")
        for needle in ("os.getcwd()", ".lower()", "sha256", "[:12]"):
            if needle not in snippet:
                found.append("the Python snippet does not use %s" % needle)
    first_set = body.find('set "HP_NUITKA_CACHE_ARG="')
    first_spec = body.find("set \"HP_NUITKA_CACHE_ARG=" + SPEC_PREFIX.split("=", 1)[0])
    if first_set < 0:
        found.append("HP_NUITKA_CACHE_ARG is not emptied first (the helper must fail open)")
    elif first_spec >= 0 and first_set > first_spec:
        found.append("HP_NUITKA_CACHE_ARG is emptied after it is set")
    if SPEC_PREFIX not in body:
        found.append("the spec is not %s" % SPEC_PREFIX)
    if "findstr /r /x" not in body:
        found.append("the token is not validated with findstr /r /x before it is used")
    elif body.find("findstr /r /x") > body.find(SPEC_PREFIX):
        found.append("the token is validated after the spec is built")
    if "[0-9a-f]" * 12 not in body:
        found.append("the validation does not require exactly 12 hex characters")
    if re.search(r"exit /b [1-9]", body):
        found.append("the subroutine can fail the build (every exit must be exit /b 0)")
    if "%LOCALAPPDATA%" in body:
        found.append("a log line expands %LOCALAPPDATA% (the unquoted-echo hazard in docs/agent-lessons-learned.md)")
    if "~nuitka_cache_token.txt" not in body:
        found.append("the token file ~nuitka_cache_token.txt is not used")
    if not re.search(r'del /f /q "~nuitka_cache_token\.txt"', body):
        found.append("the token file is not deleted")
    return found


def token_for(snippet, cwd):
    out = subprocess.run([sys.executable, "-c", snippet], cwd=cwd, capture_output=True, text=True, timeout=30)
    return out.returncode, out.stdout.strip()


def row_problems(script_text):
    found = []
    for rid in (ROW_SPEC, ROW_SAFETY):
        if len(re.findall(r"\bid\s*=\s*['\"]%s['\"]" % re.escape(rid), script_text)) != 1:
            found.append("the script does not emit %s exactly once as a literal id" % rid)
    tail = script_text.rstrip().splitlines()[-4:]
    if not any(re.match(r"^\s*exit 0\s*$", ln) for ln in tail):
        found.append("the script does not end with exit 0")
    if not re.search(r"^\s*if \(.*\)\s*\{\s*exit 1\s*\}\s*$", script_text, re.MULTILINE):
        found.append("the script has no 'if (<any row red>) { exit 1 }'")
    if "GetLongPathName" not in script_text:
        found.append("the script never converts the reported folder to its long form")
    return found


def step_problems(workflow_text):
    lines = lines_of(workflow_text)
    idx = [i for i, ln in enumerate(lines) if "selfapps_nuitka_cachespec.ps1" in ln and "&" in ln]
    if len(idx) != 1:
        return ["expected exactly 1 step running selfapps_nuitka_cachespec.ps1, found %d" % len(idx)]
    start = idx[0]
    while start > 0 and not re.match(r"^      - name:", lines[start]):
        start -= 1
    block = "\n".join(lines[start:idx[0] + 1])
    found = []
    if "matrix.mode == 'uv'" not in block:
        found.append("the step is not restricted to the uv lane")
    if not re.search(r"^\s+continue-on-error:\s*true\s*$", block, re.MULTILINE):
        found.append("the step is not non-gating (continue-on-error: true)")
    return found


GOOD_BATCH = """\
:try_nuitka_tier_a
call :nuitka_cache_arg
"%HP_PY%" -m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist %HP_NUITKA_CACHE_ARG% -o "%ENVNAME%.exe" "%HP_ENTRY%" >> "%LOG%" 2>&1
exit /b 0

:offer_optimized_build
call :nuitka_cache_arg
"%HP_PY%" -m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist %HP_NUITKA_CACHE_ARG% -o "%HP_OPTBUILD_TMP%" "%HP_ENTRY%" >> "%LOG%" 2>&1
exit /b 0

:nuitka_cache_arg
set "HP_NUITKA_CACHE_ARG="
set "HP_NK_TOKEN="
del /f /q "~nuitka_cache_token.txt" >nul 2>&1
"%HP_PY%" -c "import hashlib,os;print(hashlib.sha256(os.getcwd().lower().encode('utf-8','replace')).hexdigest()[:12])" > "~nuitka_cache_token.txt" 2>nul
findstr /r /x /c:"[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]" "~nuitka_cache_token.txt" >nul 2>&1
if errorlevel 1 goto :nuitka_cache_arg_done
set /p HP_NK_TOKEN=<"~nuitka_cache_token.txt"
set "HP_NUITKA_CACHE_ARG=--onefile-tempdir-spec={CACHE_DIR}/PVW/%ENVNAME%-%HP_NK_TOKEN%"
:nuitka_cache_arg_done
del /f /q "~nuitka_cache_token.txt" >nul 2>&1
exit /b 0

:die
exit /b 1
"""

GOOD_STEP = """      - name: "Self-test: Nuitka unpack cache (uv lane, non-gating)"
        if: ${{ matrix.mode == 'uv' }}
        continue-on-error: true
        shell: pwsh
        run: |
          & tests\\selfapps_nuitka_cachespec.ps1
"""


class CommandLines(unittest.TestCase):
    def test_real_batch_lines_carry_the_argument(self):
        self.assertEqual(command_problems(BATCH.read_text(encoding="ascii", errors="replace")), [])

    def test_good_fixture_is_clean(self):
        self.assertEqual(command_problems(GOOD_BATCH), [])

    def test_a_line_without_the_argument_is_caught(self):
        bad = GOOD_BATCH.replace("--output-dir=dist %HP_NUITKA_CACHE_ARG% -o \"%ENVNAME%.exe\"", "--output-dir=dist -o \"%ENVNAME%.exe\"")
        self.assertEqual(len(command_problems(bad)), 1)

    def test_a_line_without_the_call_is_caught(self):
        bad = GOOD_BATCH.replace(":offer_optimized_build\ncall :nuitka_cache_arg\n", ":offer_optimized_build\n")
        self.assertIn("no 'call :nuitka_cache_arg'", command_problems(bad)[0])

    def test_a_call_in_another_subroutine_does_not_count(self):
        bad = GOOD_BATCH.replace(":offer_optimized_build\ncall :nuitka_cache_arg\n", "call :nuitka_cache_arg\n:offer_optimized_build\n")
        self.assertIn("no 'call :nuitka_cache_arg'", command_problems(bad)[0])


class Subroutine(unittest.TestCase):
    def test_real_subroutine_is_well_formed(self):
        self.assertEqual(subroutine_problems(BATCH.read_text(encoding="ascii", errors="replace")), [])

    def test_good_fixture_is_clean(self):
        self.assertEqual(subroutine_problems(GOOD_BATCH), [])

    def test_a_missing_subroutine_is_caught(self):
        self.assertEqual(subroutine_problems("echo hi\n"), ["expected exactly one :nuitka_cache_arg label"])

    def test_a_percent_in_the_snippet_is_caught(self):
        bad = GOOD_BATCH.replace("print(", "print(\"%CD%\", ")
        self.assertTrue(any("snippet" in p for p in subroutine_problems(bad)))

    def test_an_unvalidated_token_is_caught(self):
        bad = GOOD_BATCH.replace("findstr /r /x", "findstr /r")
        self.assertTrue(any("validated with findstr" in p for p in subroutine_problems(bad)))

    def test_a_short_validation_is_caught(self):
        bad = GOOD_BATCH.replace("[0-9a-f]" * 12, "[0-9a-f]" * 11)
        self.assertTrue(any("exactly 12 hex" in p for p in subroutine_problems(bad)))

    def test_a_build_failing_exit_is_caught(self):
        bad = GOOD_BATCH.replace("if errorlevel 1 goto :nuitka_cache_arg_done", "if errorlevel 1 exit /b 1")
        self.assertTrue(any("can fail the build" in p for p in subroutine_problems(bad)))

    def test_a_spec_not_under_the_pvw_folder_is_caught(self):
        bad = GOOD_BATCH.replace("{CACHE_DIR}/PVW/", "{CACHE_DIR}/")
        self.assertTrue(any("the spec is not" in p for p in subroutine_problems(bad)))

    def test_an_arg_not_emptied_first_is_caught(self):
        bad = GOOD_BATCH.replace('set "HP_NUITKA_CACHE_ARG="\n', "")
        self.assertTrue(any("not emptied first" in p for p in subroutine_problems(bad)))


class TokenRecipe(unittest.TestCase):
    """The Python line really names the app folder, the same way for any capitalization of the path."""

    @classmethod
    def setUpClass(cls):
        cls.snippet = python_snippet(subroutine_body(BATCH.read_text(encoding="ascii", errors="replace")) or "")

    def test_snippet_found(self):
        self.assertIsNotNone(self.snippet)

    def test_token_is_twelve_hex_characters(self):
        with tempfile.TemporaryDirectory() as d:
            rc, out = token_for(self.snippet, d)
        self.assertEqual(rc, 0)
        self.assertRegex(out, r"^[0-9a-f]{12}$")

    def test_two_folders_with_the_same_name_get_different_tokens(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            one = Path(a) / "myapp"
            two = Path(b) / "myapp"
            one.mkdir()
            two.mkdir()
            self.assertNotEqual(token_for(self.snippet, one)[1], token_for(self.snippet, two)[1])

    def test_the_same_folder_gets_the_same_token_every_time(self):
        with tempfile.TemporaryDirectory() as a:
            self.assertEqual(token_for(self.snippet, a)[1], token_for(self.snippet, a)[1])

    def test_non_ascii_folder_name_still_gives_an_ascii_token(self):
        with tempfile.TemporaryDirectory() as a:
            sub = Path(a) / ("caf" + chr(0xE9) + " " + chr(0x4E2D) + chr(0x6587))
            try:
                sub.mkdir()
            except (OSError, UnicodeError):
                self.skipTest("this file system rejects the name")
            rc, out = token_for(self.snippet, sub)
        self.assertEqual(rc, 0)
        self.assertRegex(out, r"^[0-9a-f]{12}$")

    @unittest.skipIf(os.name != "nt", "case-insensitive paths are a Windows property")
    def test_path_capitalization_does_not_change_the_token(self):
        with tempfile.TemporaryDirectory() as a:
            sub = Path(a) / "MixedCase"
            sub.mkdir()
            self.assertEqual(token_for(self.snippet, sub)[1], token_for(self.snippet, Path(str(sub).upper()))[1])


class ScriptAndStep(unittest.TestCase):
    def test_script_exists_and_is_wired(self):
        self.assertTrue(SCRIPT.exists(), "tests/selfapps_nuitka_cachespec.ps1 is missing")
        self.assertEqual(row_problems(SCRIPT.read_text(encoding="ascii")), [])

    def test_real_workflow_step_is_uv_only_and_non_gating(self):
        self.assertEqual(step_problems(WORKFLOW.read_text(encoding="utf-8")), [])

    def test_good_step_is_clean(self):
        self.assertEqual(step_problems(GOOD_STEP), [])

    def test_a_gating_step_is_caught(self):
        self.assertEqual(step_problems(GOOD_STEP.replace("        continue-on-error: true\n", "")), ["the step is not non-gating (continue-on-error: true)"])

    def test_a_step_on_every_lane_is_caught(self):
        self.assertEqual(step_problems(GOOD_STEP.replace("        if: ${{ matrix.mode == 'uv' }}\n", "")), ["the step is not restricted to the uv lane"])

    def test_a_missing_step_is_caught(self):
        self.assertIn("found 0", step_problems("      - name: other\n        run: echo hi\n")[0])

    def test_a_script_missing_a_row_is_caught(self):
        text = "Write-Row -Id 'x'\nid = '%s'\nif ($bad) { exit 1 }\nexit 0\n" % ROW_SPEC
        self.assertTrue(any(ROW_SAFETY in p for p in row_problems(text)))


if __name__ == "__main__":
    unittest.main()
