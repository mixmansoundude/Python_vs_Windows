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

- Canonical pipreqs invocation (locked by CI gates):

  `pipreqs . --force --mode compat --savepath requirements.auto.txt`

  compat mode ensures cross-runner determinism; --force overwrites stale output; --savepath keeps the generated file separate from the source-of-truth requirements.

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
- Be sure to sanity check anything touched before submitting code. Here are some methods:
  - Python syntax errors and name errors: use `python -m compileall -q .` and `python -m pyflakes .` (or `pip install pyflakes`).
  - PowerShell lint: run PSScriptAnalyzer (`Install-Module PSScriptAnalyzer -Force -Scope CurrentUser` then `Invoke-ScriptAnalyzer -Path . -Recurse -EnableExit`).
  - YAML lint: use `pip install yamllint` (or `actionshub/yamllint@v1`) and run over `*.yml`/`*.yaml`.
  - JSON lint: use `jq -e .` over `*.json`.
  - Generic **paired-delimiter** scanner for `.bat`, `.cmd`, `.ps1`, `.py`, `.yml`, `.yaml`, `.json`:
     - Implement a kind of `tools/check_delimiters.py` that reads text files and validates balanced/ordered pairs: (), {}, [], and quotes " ' (handle escapes and ignore inside comments where feasible).
     - For `.bat/.cmd`, be conservative: treat `^` (escape) and `REM`/`::` as comment starts; don’t over-parse redirection `<` `>`; just count (), quotes, and braces/brackets. For `.ps1`, respect `#` comments and here-strings (@'…'@, @"…"@).


## Headless Codex Iteration (CI)
- Trigger: Workflow_run completion of **Batch syntax/run check**.
- Requires repository secret **OPENAI_API_KEY** (used by the Codex CLI).
- Model pin: `gpt-4o-mini` via `codex exec` headless mode.
- Attempt cap: 20 commits per source branch (tracked by commit prefix).
- Branch naming: `codex/ci-fix-<failing head branch>` for automated fixes.
- Disable by commenting out the workflow job or forcing an always-false condition in `.github/workflows/codex-auto-iterate.yml`.
