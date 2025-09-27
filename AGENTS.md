# AGENTS.md

Operating policy for automated agents (Codex, Copilot, others).

## Ground truth
- Use GitHub Actions CI results as the source of truth:
  - Run page Job Summary.
  - Grouped log tails printed by the workflow.
  - PR failure comment posted by the workflow.
- Local or sandbox runs are advisory only. Windows runner behavior is authoritative.
- Enforce the single-bootstrapper Prime Directive: `run_setup.bat` must work when dropped next to the app with no committed helper files.
- The CI harness may use additional scripts or assets under `tests/` to inspect the bootstrapper, but those files cannot be required for the real bootstrap flow.

## Do not
- Do not weaken tests or remove logging/artifacts.
- Do not delete or skip checks to obtain a green build.
- Do not change workflow triggers, permissions, or retention.

## Conda policy (mandatory)
- Enforce conda-forge only.
- Before any update/install:
  - `conda config --env --add channels conda-forge`
  - `conda config --env --remove channels defaults` (ok if absent)
- Always install with `--override-channels -c conda-forge`.

## How to work here
- Read and enforce the **README.md** and follow the “Software Requirements Directive”.
- Make minimal, surgical patches in failing areas:
  - `run_tests.bat`, `tests/harness.ps1`, files under `tests/**`.
- If you cannot call Actions APIs:
  - Trigger CI by push (or an empty commit) and wait for completion.
- Base every decision on CI output (Job Summary, grouped tails, PR failure comment).

## Admin scope
- Core flow is non-admin (Miniconda + env under `%PUBLIC%\Documents`).
- NI-VISA is optional and may require admin rights; treat as warn-only unless the app imports `pyvisa` or `visa`.

## Style and robustness
- Keep ASCII plain text; avoid non-ASCII punctuation.
- Prefer quoting/escaping and logic fixes over silencing errors.
- Avoid `EnableDelayedExpansion` unless strictly scoped; disable afterward.
- Batch file syntax has been a critical source of failures. Especially for escaping special characters.
  - Since batch file syntax is tricky, and there is not an easy checker, if you cannot run it on a windows environment then utilize the CI workflow actions that run on every push so wait for the results to appear and recheck after the push.
- Use LF endings in the repository.
- Only Windows scripts (.bat .cmd .ps1 .psm1 .psd1) should check out as CRLF.
- Do not change line endings manually; follow .gitattributes.
- If you change the bootstrapper’s console text or these entry rules in a future PR, update the self-test and any entry-selection tests accordingly.
- The bootstrapper’s exit code when no Python files are present is not a release contract; guard on the console text instead.
- Keep core.autocrlf=false and let .gitattributes control endings.