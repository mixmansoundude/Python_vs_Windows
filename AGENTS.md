# AGENTS.md

Operating policy for automated agents (Codex, Copilot, others).

## Ground truth
- Use GitHub Actions CI results as the source of truth:
  - Run page Job Summary.
  - Grouped log tails printed by the workflow.
  - PR failure comment posted by the workflow.
- Local or sandbox runs are advisory only. Windows runner behavior is authoritative.

## CI cost and capacity (do not optimize against these)
- This is a **public repository**, so GitHub Actions minutes are **free and unmetered**. Do not avoid
  adding jobs/lanes, re-runs, or long-running diagnostics out of a concern for billing -- there is none.
- Matrix jobs run on **separate runner VMs in true parallel**. Total CI wall-clock is the duration of the
  *slowest* lane, not the sum. A new lane is "free" in wall-clock terms as long as it finishes within the
  current critical lane's time and a runner is available (standard public-repo `windows-latest` = 4 vCPU /
  16 GB RAM; concurrency limits are generous and not a practical constraint here).
- Therefore: when a step is slow, flaky, or environment-dependent (e.g. a real NI-VISA install that can take
  30-45 min), prefer isolating it in its **own non-gating (`continue-on-error`) lane** rather than embedding
  it in an existing lane -- isolation costs no extra wall-clock and keeps gating lanes fast and deterministic.
- External/environmental failures (blocked downloads, third-party installer quirks) are **not** repo/test/CI
  bugs. Make them legible in logs/NDJSON (e.g. capture installer exit codes and emit a `reason=` token) so a
  non-gating lane surfaces them without failing the run or being mistaken for a regression.
- Enforce the single-bootstrapper Prime Directive: `run_setup.bat` must work when dropped next to the app with no committed helper files.
- The CI harness may use additional scripts or assets under `tests/` to inspect the bootstrapper, but those files cannot be required for the real bootstrap flow.

### Current agents
- One CI auto-patcher exists: `.github/workflows/batch-check.yml` job **Model quick-fix (inline)** calling `tools/inline_model_fix.py` with the `gpt-codex-5` model via the inline Models.OpenAI request.
- Iterate and the diagnostics publisher consume NDJSON/git results only; they do not invoke models directly.
- Older “online model” or extra inline experiments were removed; extend this single path for any future model work.

## Do not
- Do not weaken tests or remove logging/artifacts.
- Do not delete or skip checks to obtain a green build.
- Do not change workflow triggers, permissions, or retention.

## No silent features
If something new is observable in logs or produces an artifact, it needs an NDJSON row AND the
artifact path must be added to the test-logs upload in batch-check.yml (both slash-style variants
per existing convention). Observable = any new log line, new file written to disk, or new behavior
detectable by an assertion. Silent features are forbidden.

## Branch coverage policy

Every code branch added to run_setup.bat or related helpers must have a
corresponding test that exercises that branch in CI. This includes:

- Feature flags and fallback paths (e.g. HP_TEST_JUSTME_FALLBACK)
- Error recovery paths (e.g. retry logic, warn-file driven installs)
- Fast path vs full path branches (e.g. env-state fast path, dep-check skip)

When adding a new branch or fallback:

1. Add an NDJSON row that asserts the branch fired (pass=true when the
   specific log line or artifact is present)
2. If the branch cannot be triggered by the normal CI flow, add a dedicated
   test lane or HP_* flag to force it
3. Do not ship a branch without a test that would catch it being silently
   deleted or bypassed

## Interface contract with CI
- CI asserts on the exact bootstrapper messages emitted by `run_setup.bat` and related helpers.
- When adjusting bootstrap log text or status summaries, update the workflow checks that parse them at the same time.
- Likewise, when tightening CI parsing or summaries, ensure `run_setup.bat` keeps emitting the expected phrases.
- Always validate both sides together so the message contract stays synchronized and avoids false regressions.
- The only parser-facing signal for iterate presence is the single line '* Iterate logs: {found|missing}'. Any additional iterate-related details are advisory and must not change consumer logic.
- The diagnostics publisher expects the iterate job to upload a single artifact named `iterate-logs-${run_id}-${run_attempt}` that contains the `iterate/_temp/` payload plus the job summary. Missing that artifact yields '* Iterate logs: missing'.
- The pre-flight iterate gate intentionally fails when NDJSON inputs are missing; do not "fix" that failure. The later NDJSON summary (cache+real) is the real verdict once results land.

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

## CI Polling and Verification

### 1. After every push, poll CI before proceeding

After each `git push`, wait for CI to complete before making any further commits or opening a PR.
Poll using the diagnostics site latest.txt:

```bash
for i in $(seq 1 9); do
  LATEST=$(curl -s "https://mixmansoundude.github.io/Python_vs_Windows/diag/latest.txt" \
    | tr -d '[:space:]')
  RUN=$(echo "$LATEST" | grep -oE '[0-9]+-[0-9]+' | head -1)
  [ -n "$RUN" ] && echo "Run: $RUN" && break
  sleep 60
done
```

Poll interval: 1-9 minutes. Max wait: under 10 minutes in practice.
If CI is red, self-heal before proceeding to the next commit.

### 2. After CI is green, verify outputs via the diag site

Green NDJSON rows are necessary but not sufficient. Also:

- Fetch the relevant ~setup.log.txt from the diag site and confirm expected log lines are
  present for the change made.
- Check that new artifact files appear in the inventory if the change was supposed to produce them.
- Confirm the NDJSON row count in each lane is non-decreasing from the last known-good run (check the diag site).

URL pattern for setup logs:

```
https://mixmansoundude.github.io/Python_vs_Windows/diag/<RUN>/_mirrors/_artifacts/batch-check/test-logs/test-logs-selftest-conda-full-<RUN>/tests/~envsmoke/~setup.log.txt
```

### 3. Opening a PR

After all commits are pushed and CI is confirmed green with diag verification, open a PR with:

```
gh pr create --title "<descriptive title>" --body "<summary of changes>"
```

No label is required. Auto-merge fires automatically for all non-draft PRs unless the
'no-automerge' label is present.

Do NOT open a PR before CI is green on the final commit.

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

## Windows Scripting Conventions

### Batch path quoting
- Assign with `set "VAR=value"` (quotes wrap the whole assignment, not the value).
  Never use `set VAR="value"` -- the quotes become part of the string and cause double-quoting on expansion.
- Execute with `"%VAR%"` at every file-system call site (`del`, `if exist`, `mkdir`, `move`, `copy`, `pushd`).
- Exception: NSIS installer `/D=` parameter cannot be quoted -- leave as `/D=%VAR%` (NSIS restriction).

### PowerShell 5.1 web requests (TLS)
- Prepend `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;`
  to every `Invoke-WebRequest` call. PS 5.1 on older Windows defaults to TLS 1.0/1.1 which modern CDNs reject.
- Keep `-UseBasicParsing` on all `Invoke-WebRequest` calls.

### Admin awareness before system-wide installs
- Before any system-wide install, check elevation silently:
  `fsutil dirty query %systemdrive% >nul 2>&1`
  If `errorlevel 1`, skip the system-wide path and fall back to per-user installation.
  This avoids unexpected UAC prompts on non-elevated machines.

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
    - **Do NOT skip PowerShell validation just because the host is Linux.** `pwsh` installs and runs
      reliably on these Linux runners — this is a proven, repeatable path, not a long shot. If a script
      under `.ps1` is touched, install `pwsh` and validate it. "I'm on Linux so I can't check PowerShell"
      is not an acceptable reason to push unvalidated `.ps1` changes.
    - **Fastest check (no PSGallery, no script execution): AST parse via the .NET parser.** This catches
      every syntax error (unbalanced braces, bad here-strings, parameter-name `-or`/`-and` traps) in
      milliseconds and runs identically on Linux and Windows. Use it as the default `.ps1` pre-commit gate:
      ```
      pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseFile('tests/selftest.ps1', [ref]\$null, [ref]\$null)"
      ```
      Exit code 0 with no output means the file parses cleanly. To sweep every PowerShell file:
      ```
      pwsh -NoProfile -c "Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.psd1 | ForEach-Object { \$errs=\$null; [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName,[ref]\$null,[ref]\$errs) > \$null; if (\$errs) { Write-Host \"FAIL \$(\$_.FullName)\"; \$errs } }"
      ```
      (`tools/ps-compileall.ps1` wraps this sweep if you prefer a named helper.)
    - If `pwsh` is not yet present, install it first (works on these runners as of 2025-11-09):
      ```
      sudo apt-get update
      sudo apt-get install -y wget apt-transport-https software-properties-common lsb-release
      wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb" -O packages-microsoft-prod.deb
      sudo dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb
      sudo apt-get update
      sudo apt-get install -y powershell
      ```
      Verify with `pwsh --version` (7.5.4 installs cleanly). If the apt path is blocked, the Microsoft
      install docs cover tarball and snap alternatives — try those before declaring pwsh unavailable.
    - **No-sudo / restricted-env fallback (verified 2026-06-22): direct tarball install.** When apt/sudo
      is unavailable in the cloud session, download the release tarball straight from GitHub and run it
      from a local prefix — no root needed:
      ```
      curl -fsSL --max-time 90 \
        https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz \
        -o /tmp/pwsh.tar.gz
      mkdir -p /opt/pwsh && tar -xzf /tmp/pwsh.tar.gz -C /opt/pwsh && chmod +x /opt/pwsh/pwsh
      /opt/pwsh/pwsh --version   # -> PowerShell 7.4.6
      ```
      Then use `/opt/pwsh/pwsh -NoLogo -NoProfile -File tools/ps-compileall.ps1` for the syntax sweep.
    - PowerShell Gallery downloads (PSResourceGet / PSScriptAnalyzer) are still blocked by proxy 403 responses. When linting is required, prefer executing the scripts directly under `pwsh` with realistic environment variables instead of relying on ScriptAnalyzer.
    - After installing `pwsh`, sanity-check modified scripts by invoking them directly. For example, populate temporary directories for `DIAG`/`ARTIFACTS` and run `pwsh -NoLogo -File tools/diag/publish_index.ps1` to catch syntax errors.
    - Use `pwsh -NoLogo -NoProfile -File tools/ps-compileall.ps1` for syntax-only sweeps across `.ps1`/`.psm1`/`.psd1` files when you need a lightweight pre-commit check without PSGallery access.
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

## Embedded payload inventory (run_setup.bat)

All helpers are base64-encoded inside `run_setup.bat` under `:define_helper_payloads`.
Adding or changing a payload requires re-encoding and updating the matching `set "HP_*"=...` line.
Run the delimiter check after every payload change.

| Variable | Decoded filename | Purpose |
|----------|-----------------|---------|
| `HP_FAST_CHECK` | `~fast_check.py` | Pre-bootstrap sanity checks (Python files present, etc.) |
| `HP_DEP_CHECK` | `~dep_check.py` | Compares pipreqs output against `~environment.lock.txt`; exits 0 (skip install) or 1 (install needed). SHIPPED Loop 2. |
| `HP_ENV_STATE` | `~env_state.py` | Reads/writes `~env.state.json`; validates env cache across runs. SHIPPED Loop 3. |
| `HP_PARSE_WARN` | `~parse_warn.py` | Reads PyInstaller warn file, extracts missing module names, applies import-to-conda translation table. Supports PyInstaller 5.x (W: no module named 'foo') and 6.x (missing module named foo - imported by ... (delayed|top-level|conditional)) formats. Skips (optional)-only entries (try-except guards). Prints one package per line. Version is intentionally unpinned -- update this table and the translation logic if a new format is introduced. |
| `HP_COLLECT_SUBMODULES` | `~collect_submodules.py` | Emits pre-build `--collect-submodules=PKG` flags (one space-separated line) for curated packages (sklearn, matplotlib, scipy, plotly) that load submodules dynamically and are invisible to the warn file. Double-gated: a flag is emitted only when the package is BOTH imported by the user's project source AND importable in the build interpreter. Canonical source `tools/collect_submodules.py`; PayloadSync in `tests/test_collect_submodules.py`. |
| `HP_HIDDEN_IMPORT_SCAN` | `~hidden_import_scan.py` | Decides the next `--hidden-import` target from a frozen EXE's stderr for the Slice 2 auto-recovery loop. Strict + double-gated: emits a module ONLY on `ModuleNotFoundError: No module named 'X'` AND when X is installed in the build interpreter (so a user typo / `ImportError: cannot import name` never triggers a rebuild). Canonical source `tools/hidden_import_scan.py`; PayloadSync in `tests/test_hidden_import_scan.py`. |

## Runtime artifact paths

Files written by `run_setup.bat` during a bootstrap run. All use the tilde prefix so they
are gitignored and survive crashes. Do not remove tilde prefixes.

| File | When written | Used by |
|------|-------------|---------|
| `~bootstrap.status.json` | Every run | CI harness, selftest.ps1 |
| `~setup.log` | Every run | CI test-logs artifact, diagnostics previews |
| `~environment.lock.txt` | After successful conda install (errorlevel=0, non-empty) | HP_DEP_CHECK (dep-skip fast path) |
| `~env.state.json` | After successful full bootstrap | HP_ENV_STATE (env-state fast path) |

Schema for `~env.state.json` (schema=1):
```json
{"schema": 1, "env_name": "...", "env_path": "...", "python_version": "...",
 "req_hash": "...", "runtime_hash": "...", "lock_hash": "..."}
```
Unknown schema is treated as stale (triggers full rebuild, not error).

## Version Metadata Maintenance

The `[VERSION_METADATA]` block at the top of `run_setup.bat` records the last verified execution environment.

**Maintenance Rule:** If a CI run passes on a version of Windows, PowerShell, or Python newer than
what is listed in the `[VERSION_METADATA]` block, update that block to reflect the latest verified
environment. Fields to keep current:

- `Last Verified Date` -- date of the confirming CI run (YYYY-MM-DD)
- `Verified Windows` -- Windows version(s) confirmed passing
- `Verified PowerShell` -- PowerShell version confirmed present on the runner
- `Verified Python` -- Python version(s) used in CI (CI Default / Latest)
