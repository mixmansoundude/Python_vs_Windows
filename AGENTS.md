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

## Interface contract with CI
- CI asserts on the exact bootstrapper messages emitted by `run_setup.bat` and related helpers.
- When adjusting bootstrap log text or status summaries, update the workflow checks that parse them at the same time.
- Likewise, when tightening CI parsing or summaries, ensure `run_setup.bat` keeps emitting the expected phrases.
- Always validate both sides together so the message contract stays synchronized and avoids false regressions.
- The only parser-facing signal for iterate presence is the single line '* Iterate logs: {found|missing}'. Any additional iterate-related details are advisory and must not change consumer logic.
- The diagnostics publisher expects the iterate job to upload a single artifact named `iterate-logs-${run_id}-${run_attempt}` that contains the `iterate/_temp/` payload plus the job summary. Missing that artifact yields '* Iterate logs: missing'.

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

# Iteration Contract (Agent)

You MUST follow this order every loop:
Always run yml lint on workflow.

IF scope change requested → create backlog item; DO NOT edit current requirements unless explicitly told to do so.

IF CI red → fix CI.

IF tests error (crash/invalid) → fix tests/harness. Run yml lint, python compile, install and run pyflakes, do other self checks/tests.

IF tests fail (assert red) → fix product code at root cause.

IF all green → verify no false passes (hunt flakiness/missing checks).

ELSE IF unmet requirement exists → implement ONE slice.

ELSE IF implemented behavior lacks a test → add ONE test.

IF any code is untraceable to a requirement → add comment:
`derived requirement: <why needed>` and propose a requirement.

THEN stop and open/append a PR. One loop = one change set.

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
- Do not change line endings manually; follow .gitattributes.
- If you change the bootstrapper’s console text or these entry rules in a future PR, update the self-test and any entry-selection tests accordingly.
- The bootstrapper’s exit code when no Python files are present is not a release contract; guard on the console text instead.
- Be sure to sanity check anything touched before submitting code. Recommended options include:
  - Python: `python -m compileall -q .` and `python -m pyflakes .` (install `pyflakes` if needed).
  - PowerShell:
    - Install `pwsh` first:
      ```
      sudo apt-get update
      sudo apt-get install -y wget apt-transport-https software-properties-common lsb-release
      wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb" -O packages-microsoft-prod.deb
      sudo dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb
      sudo apt-get update
      sudo apt-get install -y powershell
      ```
    - (Optional) Install PSScriptAnalyzer after PowerShell is present. Prefer PSResourceGet and fall back to other methods when corporate proxies allow traffic:
      ```
      pwsh -NoLogo -Command "Import-Module Microsoft.PowerShell.PSResourceGet; Register-PSResourceRepository -PSGallery -ErrorAction SilentlyContinue; Install-PSResource -Name PSScriptAnalyzer -Scope CurrentUser -TrustRepository; Get-Module PSScriptAnalyzer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1 Name,Version,Path"
      pwsh -NoLogo -Command "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force; Register-PSRepository -Default -ErrorAction SilentlyContinue; Install-Module -Name PowerShellGet -Force -Scope CurrentUser; Import-Module PowerShellGet; Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force; Get-Module PSScriptAnalyzer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1 Name,Version,Path"
      ```
      - On these runners both commands currently hit HTTP 403 responses from the proxy; if the gallery stays blocked, download the `.nupkg` manually from an approved mirror (or transfer a cached copy) into `~/.local/share/powershell/Modules/PSScriptAnalyzer/<version>` and import it from disk.
    - Once PowerShell (and optionally PSScriptAnalyzer) is in place, mirror the workflow environment variables, run the script with `pwsh`, enable traces via `Set-PSDebug -Trace 2`, and inspect `$Error` afterwards for hidden stack info. Finish with `Invoke-ScriptAnalyzer -Path . -Recurse -EnableExit` when the module is available.
- YAML (and GitHub Actions): run `python -m yamllint <file>` (or `actionshub/yamllint@v1`) and `actionlint -oneline` for workflow validation.
  - Preferred actionlint install: `curl -sSLO https://github.com/rhysd/actionlint/releases/latest/download/actionlint_linux_amd64.tar.gz && tar -xzf actionlint_linux_amd64.tar.gz actionlint && ./actionlint -oneline .`
  - If the release tarball resolves to "Not Found" due to proxy filtering, install with Go instead: `go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.1` and add `/root/.local/share/mise/installs/go/1.24.3/bin` to `PATH` before running `actionlint`. On this runner `go env GOPATH` resolves to `/root/go`, so the compiled binary also lives under `/root/go/bin`—add that directory to `PATH` if the mise shim is absent.
  - JSON: `jq -e .` over `*.json`.
  - Generic paired-delimiter scan for `.bat`, `.cmd`, `.ps1`, `.py`, `.yml`, `.yaml`, `.json`:
    - Provide a helper such as `tools/check_delimiters.py` that validates (), {}, [], and quotes " ' (handle escapes and ignore comments when practical).
    - For `.bat/.cmd`, treat `^` as escape and `REM`/`::` as comment starts; avoid over-parsing redirection symbols.
    - For `.ps1`, respect `#` comments and here-strings (@'…'@, @"…"@) when counting delimiters.

- Work in an explicit loop: **Plan → Check the plan → Execute → Self-check/tests**. Document the plan before coding, verify it against requirements, act, then rerun the listed sanity checks.
- When fixing bugs, leave professional comments that explain why the change is structured the way it is so future readers understand the constraint.
- You may add helper utilities under `tools/` (preferred over embedding long scripts inside YAML/PowerShell/batch files). Run helpers from there freely, but update existing tools carefully to avoid regressions.
