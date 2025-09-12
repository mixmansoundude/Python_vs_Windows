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

Artifacts written:
  tests\extracted\~*.py   (helpers extracted from run_setup.bat)
  tests\~dynamic-run.log  (if dynamic tests run)
