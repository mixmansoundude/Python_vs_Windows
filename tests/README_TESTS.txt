Test Harness (fast cycle)

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

Bootstrap self-tests:
  * `tests\selftest.ps1` creates throwaway folders (`~selftest_empty`, `~selftest_stub`), runs `run_setup.bat`,
    and verifies both the no-Python and stub bootstrap paths while capturing logs for CI summaries.

Artifacts written:
  tests\extracted\~*.py   (helpers extracted from run_setup.bat)
  tests\~dynamic-run.log  (if dynamic tests run)
  tests\~selftest-summary.txt (results from bootstrap self-tests)
  tests\~selftest_empty\~empty_bootstrap.log (empty-folder bootstrap log)
  tests\~selftest_stub\~stub_bootstrap.log (stub bootstrap log)
  tests\~selftest_stub\~stub_run.log (hello_stub.py execution log)
