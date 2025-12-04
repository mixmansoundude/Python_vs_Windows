Test Harness (fast cycle)

Two worlds, one folder:
  * Bootstrapper repo CI: the selftest harness always runs and can wake the
    model through tests\~test-results.ndjson even when there are no Python
    files. It validates the bootstrapper messages and empty-repo behavior.
  * Real app repo: the same files act as templates. selfapps_*.ps1 and
    dynamic_tests.* only run when ~bootstrap.status.json reports state=="ok"
    with at least one Python entry; when pyFiles==0 they skip by design.

Place these files in your app folder:
  run_setup.bat            (bootstrapper)
  run_tests.bat            (static checks)
  tests\*                  (harness + optional dynamic tests)

Quick static pass (no Python needed):
  1) Double-click run_tests.bat
  2) Send me:
     - tests\~test-summary.txt
     - tests\~test-results.ndjson
  3) If you've run run_setup.bat, also include ~setup.log

Optional dynamic pass (needs any Python: Miniconda base, py.exe, or system python):
  1) Double-click tests\dynamic_tests.bat
  2) Send me: tests\~dynamic-results.ndjson
     - Also exercises Python version detection precedence (`runtime.txt` overrides `pyproject.toml`)
     - Also exercises entry selection precedence via the decoded `~find_entry.py` helper (e.g., `main.py` beats `app.py`)

Bootstrap self-tests:
  * `tests\selftest.ps1` creates throwaway folders (`~selftest_empty`, `~selftest_stub`), runs `run_setup.bat`,
    and verifies both the no-Python and stub bootstrap paths while capturing logs for CI summaries.
  * `tests\selftests.ps1` replays the empty-repo bootstrap log to confirm the console prints `Python file count: 0`
    and `No Python files detected; skipping environment bootstrap.`; CI fails if these lines disappear.

Artifacts written:
  tests\extracted\~*.py   (helpers extracted from run_setup.bat)
  tests\~dynamic-run.log  (if dynamic tests run)
  tests\~selftest-summary.txt (results from bootstrap self-tests)
  tests\~selftests-summary.txt (results from console self-tests)
  tests\~selftest_empty\~empty_bootstrap.log (empty-folder bootstrap log)
  tests\~selftest_stub\~stub_bootstrap.log (stub bootstrap log)
  tests\~selftest_stub\~stub_run.log (hello_stub.py execution log)
  tests\~test-results.ndjson (core harness NDJSON; model-facing CI summaries)
  tests\~dynamic-results.ndjson (only written when consumer repos enable dynamic tests)
