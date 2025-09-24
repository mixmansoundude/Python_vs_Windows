# CI contract

This repository keeps a single Windows bootstrapper (`run_setup.bat`) as the source of truth. The GitHub Actions workflow enforces the following behaviors so local runs and CI stay aligned.

## Bootstrap status JSON
- `run_setup.bat` always writes `~bootstrap.status.json` (ASCII) in the repository root.
- The JSON payload has three fields: `state`, `exitCode`, and `pyFiles`.
- `state` is one of `ok`, `no_python_files`, or `error`.
  - `ok` means at least one Python source was found and the bootstrap completed.
  - `no_python_files` means zero `.py` files were detected; the batch exits 0 and CI treats this as informational.
  - `error` is reserved for real failures; the batch exits non-zero and CI fails immediately.
- `exitCode` mirrors the batch exit code so downstream jobs can stop on real errors.
- `pyFiles` records how many Python files were counted before bootstrapping began.

## Dynamic test rules
- The dynamic test step reads `~bootstrap.status.json` before running any optional tests.
- When `state == "no_python_files"`, dynamic tests are skipped, the log writes `SKIPPED: no_python_files`, and the step exits 0.
- When `state == "ok"`, the workflow looks for `tests/dynamic_tests.bat` (preferred) or `tests/dynamic_tests.py` (fallback) and runs whichever exists. Missing runners are treated as skips, not failures.
- When `state == "error"` or the status file is missing/invalid, the workflow surfaces the bootstrap logs and fails immediately.

## Summary layout
The job summary always lists information in this order:
1. Bootstrap status one-liner.
2. `Bootstrap (tail)` code block (last ~120 lines of `bootstrap.log`).
3. Dynamic test note (skip or run) followed by `Dynamic tests (tail)`.
4. Static test PASS/FAIL counts and a short code block from `tests/~test-summary.txt`.
5. First three non-comment lines from `tests/extracted/~prep_requirements.py` and `tests/extracted/~detect_python.py`.
6. Machine-readable first failure JSON and a matching snippet when any static check fails.

## Artifacts
The workflow uploads a single artifact bundle named `test-logs` containing only:
- `bootstrap.log` – full bootstrap transcript.
- `~setup.log` – rolling setup log from the batch.
- `tests/~dynamic-run.log` – canonical dynamic test status line.
- `tests/~test-summary.txt` – condensed static harness output.
- `tests/~test-results.ndjson` – machine-readable check results.
- `tests/extracted/**` – helper scripts decoded from the bootstrapper for inspection.
This keeps artifacts small while preserving everything reviewers need to debug failures.

## Green on empty repositories
A branch with zero Python files is considered healthy when:
- `~bootstrap.status.json` reports `state=no_python_files`, `exitCode=0`, and `pyFiles=0`.
- Dynamic tests log `SKIPPED: no_python_files` and exit 0.
- Static checks succeed (PASS count equals total checks, FAIL 0).
The workflow summary calls this out explicitly so maintainers know the bootstrapper handled the empty-folder scenario correctly.
