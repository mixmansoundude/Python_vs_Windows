"""Batch wiring of the provider memory file and the PVW_PROVIDER switch, CLAUDE.md Item 66 (README REQ-009).

Decided 2026-10-17 (Q11, option A): after a run that only worked once the cascade reached conda, the
bootstrapper writes ~provider.state.json; the next run starts at conda; the file survives edits to the
program's inputs and is cleared only when Miniconda is gone or the user deletes it; every run that uses it
says so and how to reset. PVW_PROVIDER=conda forces conda for one run and writes nothing.

These tests pin the order of the pieces, because a wrong order is silent: a switch value validated after the
first log line could echo a hostile string, a memory read placed before the cached-EXE fast path would change
what the fast path does, and a write placed anywhere but after a verified conda pass would remember a provider
that never worked. The behavior itself is proven by tests/selfapps_provider_memory.ps1 on Windows.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BAT = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
PS1 = (REPO / "tests" / "selfapps_provider_memory.ps1").read_text(encoding="utf-8", errors="replace")


def _sub(label):
    """Text of a subroutine from its label to the first top-of-line exit /b."""
    m = re.search(r"(?m)^%s\b" % re.escape(label), BAT)
    assert m, label + " is missing from run_setup.bat"
    end = BAT.index("\nexit /b", m.start())
    return BAT[m.start():end]


# Every phrase a CI row matches in the bootstrapper's output must exist in run_setup.bat.
PHRASES = [
    "PVW_PROVIDER has a value this bootstrapper does not accept",
    "only accepted value is conda",
    "Using super-user override for PVW_PROVIDER: conda",
    "uv: skipped (PVW_PROVIDER=conda)",
    "uv: skipped (provider memory: conda)",
    "Provider memory: starting with conda",
    "Provider memory: conda was remembered, but Miniconda is no longer installed",
    "Provider memory: ~provider.state.json is not in a form this bootstrapper reads",
    "Provider memory: conda worked for this program after uv did not",
    "delete ~provider.state.json",
    "runtime.txt holds the exact Python version an earlier run of this bootstrapper wrote",
    "PVW_PROVIDER=conda is set, so no other provider was tried",
    "Run again without PVW_PROVIDER",
]


class Phrases(unittest.TestCase):
    def test_every_phrase_a_row_matches_exists_in_the_batch_file(self):
        for p in PHRASES:
            with self.subTest(phrase=p):
                self.assertIn(p, BAT)


class SwitchValidation(unittest.TestCase):
    def test_the_value_is_compared_without_cmd_ever_parsing_it(self):
        # set <name> prints NAME=value to a pipe; findstr /x /l compares the whole line literally, so a value with
        # quotes, ampersands or percent signs is never parsed as batch syntax. The comparison is case sensitive.
        self.assertIn('set PVW_PROVIDER 2>nul | findstr /x /l /c:"PVW_PROVIDER=conda" >nul', BAT)
        self.assertNotIn('"%PVW_PROVIDER%"==', BAT)
        self.assertNotIn("/i \"%PVW_PROVIDER%\"", BAT)

    def test_no_line_ever_prints_the_value(self):
        for n, line in enumerate(BAT.splitlines(), 1):
            if "%PVW_PROVIDER%" in line:
                self.fail("line %d expands the raw PVW_PROVIDER value: %s" % (n, line.strip()))

    def test_validation_runs_after_the_lock_and_before_the_cached_exe_fast_path_and_any_provider_work(self):
        v = BAT.index('findstr /x /l /c:"PVW_PROVIDER=conda"')
        self.assertGreater(v, BAT.index("call :acquire_lock"))
        self.assertLess(v, BAT.index("call :try_fast_exe"))
        self.assertLess(v, BAT.index("rem === uv acquisition"))

    def test_a_bad_value_stops_with_die_and_a_real_exit(self):
        i = BAT.index("PVW_PROVIDER has a value this bootstrapper does not accept")
        tail = BAT[i:i + 400]
        self.assertIn("call :die", BAT[i - 120:i])
        self.assertRegex(tail, r"exit /b 1")

    def test_the_valid_value_acts_like_conda_only_mode_without_the_ci_log_line(self):
        # behaves as HP_FORCE_CONDA_ONLY does (no fallbacks), set after that flag's own log line so a user who set
        # only PVW_PROVIDER is not told about a "flag"
        a = BAT.index('if "%HP_FORCE_CONDA_ONLY%"=="1" (\n  rem derived requirement: conda-full diagnostics')
        b = BAT.index('findstr /x /l /c:"PVW_PROVIDER=conda"')
        self.assertLess(a, b)
        self.assertIn('set "HP_PVW_PROVIDER_CONDA=1"', BAT)
        self.assertRegex(BAT, r'set "HP_FORCE_CONDA_ONLY=1"')


class UvSkip(unittest.TestCase):
    def test_both_skips_come_before_the_uv_executable_override_so_pvw_uv_exe_cannot_bring_uv_back(self):
        a = BAT.index("if defined HP_PVW_PROVIDER_CONDA goto :uv_skip_pvw_provider")
        b = BAT.index("if defined HP_PM_START_CONDA goto :uv_skip_provider_memory")
        c = BAT.index("if not defined PVW_UV_EXE goto :pvw_uv_exe_skip")
        self.assertLess(a, b)
        self.assertLess(b, c)

    def test_each_skip_clears_uv_and_rejoins_the_normal_conda_path(self):
        for label, text in (
            (":uv_skip_pvw_provider", "uv: skipped (PVW_PROVIDER=conda)"),
            (":uv_skip_provider_memory", "uv: skipped (provider memory: conda)"),
        ):
            with self.subTest(label=label):
                m = re.search(r"(?m)^%s\n" % re.escape(label), BAT)
                self.assertIsNotNone(m)
                body = BAT[m.start():BAT.index("goto :uv_acquire_done", m.start())]
                self.assertIn('set "HP_UV_EXE="', body)
                self.assertIn(text, body)


class MemoryRead(unittest.TestCase):
    def test_the_read_sits_after_the_cached_exe_fast_path_and_before_the_uv_block(self):
        self.assertEqual(BAT.count("call :provider_memory_read"), 1)
        i = BAT.index("call :provider_memory_read")
        self.assertGreater(i, BAT.index("call :try_fast_exe"))
        self.assertLess(i, BAT.index("rem === uv acquisition"))

    def test_the_read_keeps_to_its_contract(self):
        body = _sub(":provider_memory_read")
        # the switch and the CI mode win over memory, a missing file means nothing to do
        self.assertLess(body.index("HP_PVW_PROVIDER_CONDA"), body.index("~provider.state.json"))
        self.assertIn('if "%HP_FORCE_CONDA_ONLY%"=="1" exit /b 0', body)
        self.assertIn('if not exist "~provider.state.json" exit /b 0', body)
        # quote-free pattern: a dot stands for each quote character of the JSON text
        self.assertIn('findstr /r /c:"provider.:.conda"', body)
        # Miniconda is checked the way the main flow finds it (both conda.bat spots) and PVW_CONDA_EXE counts
        self.assertIn("Documents\\Miniconda3\\condabin\\conda.bat", body)
        self.assertIn("Documents\\Miniconda3\\Scripts\\conda.bat", body)
        self.assertIn("PVW_CONDA_EXE", body)

    def test_the_clear_condition_lives_in_exactly_one_place(self):
        self.assertEqual(BAT.count('del /f /q "~provider.state.json"'), 1)
        self.assertEqual(len(re.findall(r'(?m)^:pm_conda_gone$', BAT)), 1)

    def test_use_is_always_visible_with_the_reset_instruction(self):
        body = _sub(":provider_memory_read")
        self.assertRegex(body, r'call :log "\[INFO\] Provider memory: starting with conda[^"]*delete ~provider\.state\.json')

    def test_an_edit_to_the_inputs_never_clears_the_file(self):
        # Q11 option A: the read must not look at requirements.txt, pyproject.toml, runtime.txt or any .py
        body = _sub(":provider_memory_read")
        for name in ("requirements.txt", "pyproject.toml", "runtime.txt", ".py", "fast_check", "hash"):
            with self.subTest(name=name):
                self.assertNotIn(name, body)


class MemoryWrite(unittest.TestCase):
    def test_the_pass_is_noted_only_for_a_fresh_exit_zero_and_reset_for_every_attempt(self):
        lc = _sub(":last_chance_offer")
        head = lc[:lc.index('set "HP_LC_REASON="')]
        self.assertLess(head.index("if defined HP_FASTPATH_USED goto :lc_cleanup"),
                        head.index('if "%HP_LC_EXIT%"=="0" call :provider_memory_note_pass'))
        self.assertLess(head.index('if "%HP_LC_EXIT%"=="0" call :provider_memory_note_pass'),
                        head.index('if "%HP_LC_EXIT%"=="0" goto :lc_cleanup'))
        note = _sub(":provider_memory_note_pass")
        self.assertIn('set "HP_PM_PASS=exe_ok"', note)
        self.assertIn('if "%HP_LC_SITE%"=="interpreter" set "HP_PM_PASS=interpreter_ok"', note)
        # reset next to the other last-chance inputs, so a cascade tier never inherits an earlier tier's pass
        i = BAT.index('set "HP_LC_EXIT="\nset "HP_LC_SITE="\nset "HP_LC_CKPT_RC="')
        self.assertIn('set "HP_PM_PASS="', BAT[i:i + 200])

    def test_a_confirmed_window_on_the_conda_tier_is_a_pass_too(self):
        m = re.search(r"(?m)^:lc_window_yes\n", BAT)
        self.assertIsNotNone(m)
        body = BAT[m.start():BAT.index("goto :lc_cleanup", m.start())]
        self.assertIn('set "HP_PM_PASS=user_confirmed"', body)
        # and only an explicit yes: the no and automated branches never set it
        for label in (":lc_window_no", ":lc_window_gate_auto"):
            n = re.search(r"(?m)^%s\n" % re.escape(label), BAT)
            self.assertNotIn("HP_PM_PASS", BAT[n.start():BAT.index("goto :lc_cleanup", n.start())])

    def test_success_writes_before_it_releases_the_lock(self):
        s = BAT[BAT.index("\n:success\n"):]
        s = s[:s.index("\nexit /b 0")]
        self.assertLess(s.index("call :provider_memory_write"), s.index("call :release_lock"))

    def test_the_write_requires_a_verified_cascade_reached_conda_pass(self):
        body = _sub(":provider_memory_write")
        for guard in (
            "if not defined HP_PM_PASS exit /b 0",
            'if /i not "%HP_ENV_MODE%"=="conda" exit /b 0',
            "if not defined HP_CASCADE_TRIED_UV exit /b 0",
            'if /i not "%HP_BOOTSTRAP_STATE%"=="ok" exit /b 0',
        ):
            with self.subTest(guard=guard):
                self.assertIn(guard, body)
        # the switch and CI conda-only mode never write
        self.assertIn('if defined HP_PVW_PROVIDER_CONDA exit /b 0', body)
        self.assertIn('if "%HP_FORCE_CONDA_ONLY%"=="1" exit /b 0', body)

    def test_the_file_content_comes_only_from_fixed_values(self):
        body = _sub(":provider_memory_write")
        self.assertIn('"provider":"conda"', body)
        self.assertIn('"passType":"%HP_PM_PASS%"', body)
        self.assertIn("Provider memory: conda worked for this program after uv did not", body)
        self.assertIn("delete ~provider.state.json", body)


class StaleExactPin(unittest.TestCase):
    def test_every_runtime_txt_write_back_leaves_a_record_of_what_it_wrote(self):
        sites = [m.start() for m in re.finditer(r'call :log "\[INFO\] runtime\.txt written: %PYVER%"', BAT)]
        self.assertEqual(len(sites), 3)
        for s in sites:
            with self.subTest(site=s):
                self.assertIn('>"~runtime_writeback.txt" echo %PYVER%', BAT[s:s + 200])

    def test_the_record_is_used_only_when_conda_goes_first_and_only_if_unchanged(self):
        body = _sub(":runtime_txt_writeback_release")
        self.assertIn('fc "runtime.txt" "~runtime_writeback.txt"', body)
        self.assertIn('del /f /q "runtime.txt"', body)
        calls = [m.start() for m in re.finditer(r"call :runtime_txt_writeback_release", BAT)]
        self.assertEqual(len(calls), 2)
        pre = BAT.index('set "HP_RUNTIME_TXT_PREEXIST="\n  if exist "runtime.txt" set "HP_RUNTIME_TXT_PREEXIST=1"\n)\nrem --- Detect required Python version')
        for c in calls:
            self.assertLess(c, pre)
        self.assertIn("if defined HP_PVW_PROVIDER_CONDA call :runtime_txt_writeback_release", BAT)
        self.assertIn("if defined HP_PM_START_CONDA call :runtime_txt_writeback_release", BAT)


class FailureHint(unittest.TestCase):
    def test_a_failed_forced_solve_stops_with_a_hint_and_never_cascades(self):
        i = BAT.index(":handle_conda_failure\n")
        body = BAT[i:BAT.index("rem REQ-009 (reordered)", i)]
        self.assertIn('if "%HP_FORCE_CONDA_ONLY%"=="1" (', body)
        self.assertIn("PVW_PROVIDER=conda is set, so no other provider was tried", body)
        self.assertIn("Run again without PVW_PROVIDER", body)
        # still returns without HP_ENV_READY, so the caller stops
        self.assertIn("exit /b 0", body)


if __name__ == "__main__":
    unittest.main()
