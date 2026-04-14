# Python_vs_Windows

![Armchair Vibe Coded](promo/avc-shield-charcoal-left-purple-right.svg)
[![Batch syntax/run check](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/batch-check.yml/badge.svg?branch=main)](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/batch-check.yml)
[![CodeQL](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/codeql.yml)

**Live diagnostics bundle:** https://mixmansoundude.github.io/Python_vs_Windows/

Prime Directive: With only one or more Python files on a clean Windows 10+ machine with internet, get at least one to run, with all imports installed.

This tool is for beginners or unfamiliar users who have been given Python code and want to get it running, not for maintaining production repositories. It brute-forces a working environment: it discovers dependencies, installs them via conda, and produces a standalone EXE. Getting the code to run takes priority over preserving outdated constraints.

---

### 🌟 Armchair Vibe Coding

> 🔧 This project was **entirely armchair vibe coded** — built from a mobile device using conversational AI prompts, without a traditional development setup.

**What is Armchair Vibe Coding?**  
Armchair Vibe Coding is a new workflow where developers build software by interacting with AI tools (like ChatGPT or GitHub Copilot) primarily from mobile devices. It combines the philosophy of **vibe coding** — coding through natural-language prompts and AI — with a relaxed, mobile-first posture.

You’re not at a desk. You’re not opening VS Code. You’re on your couch, your bed, a train — just vibing and coding through AI.

> It’s not just code — it’s coding on your terms, powered by AI and creativity, not IDEs and desk chairs.

This repository serves as a proof of concept of this new approach.

---

## TL;DR (Quickstart)

1. Windows 10 (1809+) or newer.
2. Put your `.py` app files in a folder.
3. Put `run_setup.bat` in the same folder.
4. Double-click `run_setup.bat`.
   - Core flow targets **non-admin** install under `%PUBLIC%\Documents` using Miniconda.
   - **NI-VISA** (optional) may require admin rights. If non-admin is blocked by policy, use an elevated shell.

---

# Software Requirements Directive

## [REQ-001] Prime Directive Expanded

- From only one or more `.py` files on a clean Windows 10+ machine with internet, a **single batch file** (double-clicked) must bootstrap everything to run the Python app **with all imports installed**.

### [REQ-002] Entry selection (current behavior)
- **0 Python files**: the bootstrapper reports no Python files and skips environment bootstrap. It prints:
  - `Python file count: 0`
  - `No Python files detected; skipping environment bootstrap.`
- **Exactly 1 Python file**: run that file directly.
- **2 or more Python files**: prefer a clear entry by:
  1) Common names in order: `main.py` > `app.py` > `run.py` > `cli.py`
  2) Otherwise, any file containing `if __name__ == "__main__":`
  - If no clear entry is found after those checks, the bootstrapper chooses deterministically and logs the choice.

---

## [REQ-003] Platform & Locations

- Platform: Windows 10 (1809+) or newer to leverage built-in `curl` and PowerShell.
- Conda environments: use **Miniconda** (non-admin).
- Writable, non-admin locations under Public Documents:
  - Miniconda root: `%PUBLIC%\Documents\Miniconda3`
  - App workspace: current folder (where the batch runs)

### Limitations

- UNC/network paths (`\\server\share`) are not supported for reliable bootstrap behavior. Map the share to a drive letter before running `run_setup.bat`.
- Unicode/high-bit characters in key paths are not guaranteed to work across all bootstrap steps.

---

## Python & Environment

- [REQ-004] Python version detection precedence:
  1. `runtime.txt` (`python-3.x.y` or `3.x[.y]`)
  2. `pyproject.toml` `requires-python`
  3. Otherwise let **conda pick latest** (no hard-coded fallback); then **write back `runtime.txt`**.

- Environment naming: env name equals the **current folder name**.

- Miniconda is the primary environment provider and the CI contract expects it. When Miniconda cannot be installed or
  downloaded, the bootstrapper falls back first to a Python venv and, as a last resort, runs the entry point under any
  available system Python. Either fallback preserves the Prime Directive -- at least one .py file runs with its imports
  satisfied.
- Why Miniconda instead of only venv?
  - Conda/Miniconda is the primary, tested path used in CI with pinned channels and reproducible solver behavior.
  - venv is a pragmatic fallback for networks or hosts where Conda cannot be installed or downloaded; it is not the main
    contract.
  - Many users already have a Conda installer cached, so exercising the Miniconda path keeps the real-world fast path
    healthy.
  - The fast path (reusing `dist/<envname>.exe` when non-helper sources are unchanged) sits on top of either provider,
    whether the env originated from Conda or venv.
- [REQ-006] Channels policy (determinism and legal-friction avoidance):
  - Before any updates or installs, force **community conda-forge only**:
    ```
    conda config --env --add channels conda-forge
    ```
  - Always install with `--override-channels -c conda-forge`.

---

## [REQ-005] Dependencies

- If `requirements.txt` exists and is non-empty:
  - First try bulk install:  
    `conda install --file requirements.txt --override-channels -c conda-forge`
  - If bulk fails, fall back per-package via conda. For `~=` (compatible release), convert to `>=X.Y,<X.(Y+1)` (PEP 440) before feeding conda. Handle this carefully.

- Always run:

  `pipreqs . --force --mode compat --savepath requirements.auto.txt`

  compat mode ensures cross-runner determinism; --force overwrites stale output; --savepath keeps the generated file separate from the source-of-truth requirements.

  and log a **diff vs `requirements.txt`**.

- If there is no usable `requirements.txt`, adopt `requirements.auto.txt` as canonical.

- After conda attempts, run:
pip install -r requirements.txt

to fill remaining gaps quickly.

- Heuristic extras:
- If `pandas` is present, ensure `openpyxl` is included.
- When imports are missing at any point -- such as detected during dependency installation or during EXE build -- the bootstrapper must attempt to identify the missing packages by any available means and install them before retrying. Getting the code to run takes priority.

---

### Dependency strategy

- `pipreqs` is used for discovery only -- it is not authoritative for versions or completeness. If pipreqs fails, bootstrap continues on available requirements rather than stopping; getting the code to run takes priority.
- An existing `requirements.txt` is treated as input (hints), not as the authoritative specification.
- conda performs final resolution from conda-forge; what it installs is the truth.
- Implicit and plugin dependencies (for example, `pandas` needing `openpyxl` for `read_excel`) cannot be detected statically -- `pipreqs` only sees `import pandas`, not the runtime method call. These surface as `ImportError` at runtime.
- When missing imports are detected (for example from build-time warn files or installation output), the bootstrapper
  attempts to identify and install the missing packages using whatever signal is available. It cannot map all module
  names to conda package names (for example, `PIL` maps to `pillow`, `cv2` maps to `opencv`). This is a known
  limitation, not a bug.

---

## [REQ-008] NI-VISA (optional external)

- If the app imports `pyvisa` or `visa`, attempt **NI-VISA** Windows driver install if not present (system install, not just a Python package).
- Leave option to disable for debugging purposes.
- May require admin rights.

---

## [REQ-007] Executable

- Attempt to produce a **PyInstaller one-file EXE** after setup.
- Name the EXE exactly the env name (equals the folder name).
- Fast path: if sources are unchanged since the last EXE build, detect early and run the existing EXE. Fast path freshness is determined by comparing the EXE timestamp against non-helper *.py files under the working directory (recursively), ignoring infrastructure directories like .git, .github, dist, .venv, __pycache__, etc.

---

## Maintenance, Logging, and Lessons Learned

- Update conda base periodically (~30 days), but **skip on first Miniconda install**. Ensure base is configured to conda-forge before updating to avoid prompts.
- Single rolling log `~setup.log` capped near **10 MB** total, don't spin out extra log files. Trim at start. Use debug-level detail when `VERBOSE=1`.
- Tilde-prefix any files not meant to persist (or may remain after a crash) so they are easy to ignore in VCS.
- Batch robustness for some approaches:
- Avoid `EnableDelayedExpansion`. If unavoidable, enable only around the exact lines, then disable. Force disable at script start.
- Be robust against parent shells started with `CMD /V:ON` and 3rd-party wrappers.
- Treat special characters (`&`, `~`, etc.) carefully in batch.
- ASCII only: no emojis, curly quotes, em-dashes, or ellipses.
- Always call the batch (call "%CONDA_BAT%" ...) so the parent script continues.
- Quote batch variables carefully to survive if there are spaces in their contents.
- After the silent install, recompute the %CONDA_BAT% path (condabin first; Scripts as fallback).

---

## Agent Guardrails (Codex / Copilot / other agents)

- Enforce and obey this readme document and see See **[AGENTS.md](./AGENTS.md)**.
  
---

## Repository Map

- `run_setup.bat` — bootstrap installer (Miniconda + env + deps + optional EXE)
- `run_tests.bat` — CI/static checks and harness
- `tests/` — PowerShell/batch harness, log helpers, and ndjson summaries
- `.github/workflows/` — CI workflows (batch check + CodeQL)
- Helper scripts are emitted on demand by `run_setup.bat`; no committed helper directory is required.

### Bootstrap status contract

`run_setup.bat` writes `~bootstrap.status.json` alongside its logs with ASCII JSON describing the bootstrap result:

```json
{"state":"ok|no_python_files|error","exitCode":0,"pyFiles":0}
```

- `state` is `ok` when at least one Python file bootstrapped successfully, `no_python_files` when none were discovered, and `error` if the bootstrapper halted.
- `exitCode` mirrors the batch exit code so harnesses can fail fast on real bootstrap errors.
- `pyFiles` records how many `.py` files were counted before the environment build began.

The CI harness and `tests/selftest.ps1` read this file to validate both the empty-folder (`no_python_files`) flow and the stub bootstrap path with a simple `hello_stub.py` runner.

### Rebuilding embedded helper payloads

`run_setup.bat` stores its helper scripts and `.condarc` template as base64 strings so the bootstrapper stays self-contained. To refresh one of the payloads, run a short Python snippet and paste the output back into the batch file (see also https://docs.python.org/3/library/base64.html).

```batch
python - <<'PY'
import base64, pathlib
payload = pathlib.Path('path/to/helper.py').read_bytes()
print(base64.b64encode(payload).decode('ascii'))
PY
```

Update the corresponding `set "HP_*"=...` line under `:define_helper_payloads` with the new base64 text. The batch file comments point back to this section when further guidance is needed.

## How CI decides pass/fail

### Bootstrap status JSON
- CI enforces the `run_setup.bat` status contract described above: every run writes `~bootstrap.status.json` (ASCII) with `state`, `exitCode`, and `pyFiles` fields.
- `state` is one of `ok`, `no_python_files`, or `error`; `exitCode` mirrors the batch exit code; `pyFiles` records how many `.py` files were detected before bootstrapping.
- When tightening CI parsing or changing the bootstrap log text, update both sides together so the JSON and logs stay in sync.

### Dynamic test rules
- The dynamic test step reads `~bootstrap.status.json` before running optional tests.
- `state == "no_python_files"` skips the dynamic tests and logs `SKIPPED: no_python_files` while exiting 0.
- `state == "ok"` searches for `tests/dynamic_tests.bat` or `tests/dynamic_tests.py` and runs whichever exists; missing runners count as skips, not failures.
- `state == "error"` or a missing/invalid status file surfaces the bootstrap logs and fails immediately.

### Summary layout
The GitHub Actions job summary always lists information in this order:
1. Bootstrap status one-liner.
2. `Bootstrap (tail)` code block (last ~120 lines of `bootstrap.log`).
3. Dynamic test note (skip or run) followed by `Dynamic tests (tail)`.
4. Static test PASS/FAIL counts and a short code block from `tests/~test-summary.txt`.
5. First three non-comment lines from `tests/extracted/~prep_requirements.py` and `tests/extracted/~detect_python.py`.
6. Machine-readable first failure JSON and a matching snippet when any static check fails.

### Artifacts
The workflow uploads a single artifact bundle named `test-logs` containing:
- `bootstrap.log` – full bootstrap transcript.
- `~setup.log` – rolling setup log from the batch.
- `tests/~dynamic-run.log` – canonical dynamic test status line.
- `tests/~test-summary.txt` – condensed static harness output.
- `tests/~test-results.ndjson` – machine-readable check results.
- `tests/extracted/**` – helper scripts decoded from the bootstrapper for inspection.

### Green on empty repositories
A branch with zero Python files still counts as healthy when:
- `~bootstrap.status.json` reports `state=no_python_files`, `exitCode=0`, and `pyFiles=0`.
- Dynamic tests log `SKIPPED: no_python_files` and exit 0.
- Static checks succeed (PASS count equals total checks, FAIL 0).
- `tests/selftests.ps1` confirms the bootstrap log still prints `Python file count: 0` and `No Python files detected; skipping environment bootstrap.` so CI never relies on exit-code remapping to spot regressions.

### Diagnostics and Iterate gate snapshots
- The diagnostics run-summary page shows a **pre-flight Iterate gate** entry that snapshots the NDJSON inputs before iterate runs. That snapshot is expected to report `has_failures: true` while `tests~test-results.ndjson` and `ci_test_results.ndjson` are still empty so blank inputs cannot pass silently.
- The later Iterate gate summary (after iterate has produced NDJSON rows) is the real gate verdict; use it to judge pass/fail once results exist.

The only CI auto-patching agent is the **Model quick-fix (inline)** job in `.github/workflows/batch-check.yml`, which invokes `tools/inline_model_fix.py` against the `gpt-codex-5` model. It only runs when the NDJSON harness reports failures and must respect the git hygiene rules that forbid committing artifacts (tilde-prefixed logs, NDJSON outputs, etc.). See **AGENTS.md** for the full agent policy.

---

## Known Limitations

- **Implicit/plugin dependencies**: Dependencies that are not detected via static import analysis (for example, `pandas` needing `openpyxl` for `read_excel`) will surface as `ImportError` at runtime. See [Dependency strategy](#dependency-strategy) for detail.
- **`requirements.txt` is input only**: The resolved conda environment may differ from the original author's intent. This is intentional -- getting the code to run takes priority over preserving outdated constraints.
- **Windows only**: There is no macOS or Linux support.
- **NI-VISA may require admin rights**: The NI-VISA optional install may require an elevated shell on machines where non-admin installs are blocked by policy.

---

## Contributing

See `CONTRIBUTING.md`. PRs are welcome. Keep CI green.

## Security

See `SECURITY.md`. Do not include secrets in issues or PRs.

## License

MIT — see `LICENSE`.
