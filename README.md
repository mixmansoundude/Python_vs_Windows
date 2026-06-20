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

- **Windows 10 (1809+)** or newer.
- **One Folder per Program:** Create a unique folder for your project (e.g., `universal_paperclip_optimizer` or `solve_world_hunger_v2`).
- **Avoid Conflicts:** To ensure environment integrity, do not mix independent programs in the same folder. Each program should have its own dedicated folder and its own copy of `run_setup.bat`.
- **First run on Windows:** Windows may show "Windows protected your PC" -- click **More info** -> **Run anyway**. If "Run anyway" is absent: right-click the batch -> **Properties** -> check **Unblock** -> **OK** -> run again.
- **Setup:** Put your `.py` files and `run_setup.bat` in that folder, then double-click the `.bat`.
- **Environment Locking:** On the first run, `run_setup.bat` creates or respects a `runtime.txt` to "pin" the Python version. It applies similar logic for dependencies found in `requirements.txt`, `pyproject.toml`, or PEP 723 headers.

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
  0) Manual override (`%1` argument, e.g. drag-and-drop) -- if the file is co-located with the bootstrapper (REQ-011), it is used directly and skips all auto-detection.
  1) Common names in order: `main.py` > `app.py` > `run.py` > `cli.py`
  2) Otherwise, the sole file containing a **substantive** `if __name__ == "__main__":` guard (a guard whose body is only `pass`, comments, a docstring, or `...` does not count, so a real sibling entry wins).
  - If no single clear entry remains after those checks (multiple files, no clear winner), the bootstrapper reverts to the spirit of its original behavior:
    - **Interactive picker (timed)** -- when a human is present (interactive console; not CI/`NOINPUT`/`HP_NONINTERACTIVE`), it prints an alphabetical numbered menu (up to 9 files) and waits ~30s. Typing a valid number selects that file; **timeout (or no console) -> the alphabetical default**. The menu also explains how to avoid the prompt next time (drag-and-drop a file onto the batch, rename to `main.py`/`app.py`/`run.py`/`cli.py`, or add a single `__main__` guard).
    - **Alphabetical fallback (deterministic)** -- the non-interactive / default path: the alphabetically-first candidate (preferring files that declared a `__main__` guard, otherwise any `.py` file). This is the guaranteed terminal pick, so something always runs and packages instead of the entry resolving to empty. `find_entry` logs `[BOOT] REQ-002: No clear entry found; selecting <file> (alphabetical fallback).` and exits with a distinct ambiguous code that triggers the picker.

**Entry selection criteria (priority order):**

| Criterion | Priority | REQ |
|-----------|----------|-----|
| Manual override `%1` (co-located) | 0 (highest) | REQ-002, REQ-011 |
| `main.py` | 1 | REQ-002 |
| `app.py` | 2 | REQ-002 |
| `run.py` / `cli.py` | 3 | REQ-002 |
| Sole file with a substantive `__main__` guard | 4 | REQ-002 |
| Interactive picker (timed; human present) | 5 | REQ-002 |
| Alphabetical fallback (deterministic) | 6 (lowest) | REQ-002 |

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

- Environment naming: env name equals the **current folder name**, sanitized for conda: characters outside `[A-Za-z0-9_-]` (e.g. spaces) become `_`, a **leading hyphen** is replaced with `_` (so `conda create -n` does not parse the name as a flag), and a name that reduces to only separators falls back to `env`. Internal hyphens (e.g. `my-app`) are preserved. The derived name is logged: `[INFO] Environment name: <name>`.

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
- [REQ-009] Environment discovery hierarchy (priority order):
  1. **UV** -- if `uv.exe` is available (cached or downloadable), create a `.uv_env` virtual environment using UV for fast dependency installs.
  2. **Conda (Portable / Miniconda)** -- install or reuse Miniconda at `%PUBLIC%\Documents\Miniconda3` (non-admin) and create a named conda env.
  3. **Local venv** (environment-creation fallback) -- if Conda is unavailable or fails, create a `.venv` virtual environment using whatever `python` / `py` is found on PATH (`python -m venv`). Still isolated, but depends on a pre-existing Python installation to create the env.
  4. **System Python** (final degraded execution mode) -- if no isolated environment can be created, run the entry point directly under the first `python` / `py` on PATH with no env isolation. Dependencies may conflict with system packages.

  **Provider selection criteria (priority order):**

  | Provider | Priority | Notes |
  |----------|----------|-------|
  | UV (`.uv_env`) | 1st | REQ-009 |
  | Conda / Miniconda | 2nd | REQ-009 |
  | Local venv (`.venv`) | 3rd | REQ-009; env creation fallback |
  | System Python | 4th | REQ-009; degraded execution mode, no isolation |

  **Provider fallback trigger (current behavior):** The cascade to the next provider fires on *environment creation failure* only (e.g., uv venv create fails, Miniconda download fails). A provider that successfully creates its environment is not currently abandoned if dependency installation or warnfix repair later fails -- the bootstrap continues in a degraded state within the same provider. The intended direction is that a warnfix hard failure should also cascade to the next provider (e.g., uv warnfix exhausted -> retry full dep-install under conda).

- [REQ-006] Channels policy (determinism and legal-friction avoidance):
  - Before any updates or installs, force **community conda-forge only**:
    ```
    conda config --env --add channels conda-forge
    ```
  - Always install with `--override-channels -c conda-forge`.
- [REQ-010] Session isolation (leak-proof environment):
  - At script start, `PYTHONPATH` and `PYTHONHOME` are explicitly cleared so the host shell cannot inject external site-packages into the bootstrapped environment.
  - Portable provider directories (UV `.uv_env\Scripts`, Conda env `\Scripts`) are **prepended** to `PATH` to shadow any global Python installation.
- [REQ-011] Directory integrity for explicit file arguments:
  - When a `.py` file is passed as `%1` (drag-and-drop or CLI argument), its parent directory (`%~dp1`) must equal the batch file directory (`%~dp0`). Both expand to a fully-qualified drive+path with trailing backslash; comparison is case-insensitive.
  - On mismatch: `[ERROR] REQ-011: Dragged files must reside in the bootstrapper root folder for environment cleanliness.` -- script aborts (exit 1).
  - This prevents accidental cross-project contamination when users drag a file from a different project folder onto `run_setup.bat`.

---

## REQ-005 -- Dependency Handling

Defines how dependencies are discovered, selected, installed, augmented, and repaired to ensure the application runs successfully.

---

### Core Dependency Flow

#### Source Resolution (authoritative order)

- REQ-005.1 -- Detect requirements source (priority order): Resolve dependencies using the following order:
  1. PEP 723 inline script metadata (`# /// script`)
     - If present, valid, and non-empty -> authoritative
     - Parsed before any file-based source
     - If malformed or empty: `[WARN] PEP 723 metadata invalid or empty` -> fall through
  2. `pyproject.toml` `[project].dependencies`
     - If present and non-empty -> authoritative; overrides `requirements.txt`
  3. `requirements.txt`
     - If present and non-empty -> authoritative
  4. `requirements.auto.txt` (pipreqs output)
     - Used only if no authoritative source exists
     - Not authoritative (best-effort inference)
  5. No dependencies
     - Continue with empty set if all sources unavailable

---

### Installation Strategy (Conda + pip compatibility path)

- REQ-005.2 -- Conda bulk install: Attempt install from the selected dependency source:
  ```
  conda install --file <resolved_requirements> --override-channels -c conda-forge
  ```

---

- REQ-005.3 -- Conda per-package fallback: If bulk install fails:
  - Install packages individually via conda
  - Convert `~=` (PEP 440 compatible release) to `>=X.Y,<X.(Y+1)`

---

- REQ-005.4 -- Generate inferred requirements (non-authoritative): Always run:
  ```
  pipreqs . --force --mode compat --savepath requirements.auto.txt
  ```
  - `compat` ensures cross-runner determinism
  - `--force` overwrites stale output
  - `--savepath` preserves original requirements
  - Behavior: Used for visibility and fallback only
  - Failure does not stop bootstrap: `[WARN] pipreqs failed, continuing with available sources`

---

- REQ-005.5 -- Diff tracking: Log differences between:
  - Authoritative source (PEP 723, `pyproject.toml`, or `requirements.txt`)
  - `requirements.auto.txt`

---

- REQ-005.6 -- Fallback requirements source: If no authoritative source exists:
  - Promote `requirements.auto.txt` to active dependency set

---

- REQ-005.7 -- pip gap fill: After conda attempts:
  ```
  pip install -r <resolved_requirements>
  ```
  Purpose:
  - Resolve packages unavailable or incomplete in conda
  - Uses the same resolved dependency set (no divergence)

---

### Heuristic Dependency Augmentation (Bootstrap-Time)

- REQ-005.8 -- Heuristic extras: Augment dependencies based on known ecosystem gaps that are not already included.
  - REQ-005.8.1 -- pandas -> openpyxl (+ xlsxwriter): Ensures Excel backends are available. TESTED: `tests/selfapps_pandas_excel.ps1`, `tests/test_heuristics.py`, `tests/dynamic_tests.py`
  - REQ-005.8.2 -- requests -> certifi: Ensures SSL certificate bundle is present. TESTED: `tests/test_heuristics.py`, `tests/dynamic_tests.py`
  - REQ-005.8.3 -- sqlalchemy -> pymysql: Provides common MySQL driver. TESTED: `tests/test_heuristics.py`, `tests/dynamic_tests.py`
  - REQ-005.8.4 -- matplotlib -> tk: Enables common GUI backend support. TESTED: `tests/test_heuristics.py`, `tests/dynamic_tests.py`
  - REQ-005.8.5 -- cryptography / pycryptodome -> cffi: Supports compiled crypto backends. TESTED: `tests/test_heuristics.py`, `tests/dynamic_tests.py`
  - Logging Contract: Heuristics must emit `[HEURISTIC] <source->target>` -- required for test validation.

---

### Reactive Repair (Warnfix)

- REQ-005.9 -- Missing import detection and repair: If missing modules are detected during dependency install or EXE build, the bootstrapper must attempt to identify and install them automatically.

---

- REQ-005.10 -- Retry loop: After repair attempts, rebuild/re-run until:
  - Success (application runs), or
  - Hard failure (unresolvable within the current provider)
  - On hard failure: currently logs and exits. Intended direction: cascade to the next REQ-009 provider (uv exhausted -> conda, conda exhausted -> venv, venv exhausted -> system Python) and re-attempt from the dependency installation phase.

---

### Design Principles

- Authoritative hierarchy is deterministic: PEP 723 > requirements.txt > pipreqs > none
- pipreqs is discovery only: Never trusted for completeness or versions
- No silent fallbacks: All degradations emit explicit warnings
- Single resolved dependency set: Conda + pip operate on the same inputs
- Execution success > dependency purity: System prioritizes working application over strict resolution correctness
- Provider cascade on hard failure (intended): dep-install and warnfix failures are currently contained within the active provider. The design intent is that exhausting repair within a provider triggers REQ-009 fallback rather than a hard exit.
- When missing imports are detected (for example from build-time warn files or installation output), the bootstrapper
  attempts to identify and install the missing packages using whatever signal is available. It cannot map all module
  names to conda package names (for example, `PIL` maps to `pillow`, `cv2` maps to `opencv`). This is a known
  limitation, not a bug.

---

### REQ-005 -- End-to-End Dependency Resolution Trace

This section describes the full runtime flow of dependency resolution, installation, augmentation, and repair as executed during a bootstrap run.

#### Execution Flow Summary

1. Dependency Source Selection
   - Check PEP 723 metadata first
   - Else check `pyproject.toml` `[project].dependencies`
   - Else fall back to `requirements.txt`
   - Else use `requirements.auto.txt` (pipreqs inference)
   - Else empty dependency set

2. Dependency Installation Phase
   - Attempt conda bulk install
   - If failure -> per-package conda fallback
   - If still incomplete -> pip gap fill

3. Heuristic Augmentation Phase
   - Apply known ecosystem dependency mappings via `~prep_requirements.py`
   - Log all applied heuristics explicitly

4. Runtime Validation Phase
   - Detect missing imports or runtime failures
   - Trigger reactive repair system

5. Repair + Retry Loop
   - Install missing dependencies
   - Re-run execution
   - Repeat until success or hard failure

#### Logging Contract

All stages emit structured logs:

- `[WARN]` -- dependency source fallback
- `[HEURISTIC]` -- applied mapping (emitted by `~prep_requirements.py` to stderr -> `~setup.log`)
- `[INSTALL]` -- conda/pip actions
- `[REPAIR]` -- missing module resolution
- `[TRACE]` -- dependency resolution step transitions

#### Failure Behavior

- No silent fallback allowed
- Every transition must be logged
- System prioritizes recovery over strict dependency correctness

#### End State Guarantees

At completion:
- Environment is either functional OR explicitly failed
- Dependency source lineage is traceable
- Repair attempts are fully recorded in logs

---

## [REQ-008] NI-VISA (optional external)

- If the app imports `pyvisa` or `visa`, attempt **NI-VISA** Windows driver install if not present (system install, not just a Python package).
- Leave option to disable for debugging purposes: set `HP_SKIP_NIVISA=1` to skip the NI-VISA install even when `pyvisa`/`visa` is detected. Log contract: `[VISA] skipped (disabled)`.
- May require admin rights.

---

## [REQ-007] Executable

- Attempt to produce a **PyInstaller one-file EXE** after setup.
- Name the EXE exactly the env name (equals the folder name).
- Fast path: if sources are unchanged since the last EXE build, detect early and run the existing EXE. Fast path freshness is determined by comparing the EXE timestamp against non-helper *.py files under the working directory (recursively), ignoring infrastructure directories like .git, .github, dist, .venv, __pycache__, etc.
- **Graceful EXE-failure handling**: a packaged EXE that exits non-zero must never abort the bootstrapper. The environment and dependencies are already installed, so the bootstrap completes and the user is guided to run the app directly.
  - First-build path: the EXE smoke test logs the non-zero exit, emits hints, and continues (`self.exe.smokerun` records the result).
  - Fast path: a reused EXE that exits non-zero is **discarded** (the cached EXE may be stale or carry an unbundled runtime dependency, e.g. a DLL or data file the freshness check cannot see) and a full rebuild runs instead of aborting.
  - Log contract: `[WARN] Fast path EXE exited <N>; discarding cached EXE and rebuilding.`
  - Covered by `self.exe.fastpath.graceful` (real/conda-full lanes): builds an EXE that fails at runtime (a `importlib.resources` package data file not bundled by PyInstaller), then re-runs the bootstrapper so the fast path reuses the broken EXE, asserting the second run discards it, rebuilds, and still exits 0.

---

## [REQ-013] Internet Connectivity Guard

- When a primary download fails (Miniconda or uv), the bootstrapper checks internet reachability before cascading to a fallback URL.
  - First, ICMP ping to 8.8.8.8 (fast path).
  - If ICMP is blocked, fall back to a lightweight HTTPS probe.
  - If both fail: prompt the user to confirm offline mode or retry.
- In offline mode, internet-dependent steps (uv download, Miniconda download) are skipped.
  - If the user already has a cached Miniconda or uv install, those are used as-is.
- Log contract:
  - `[INFO] REQ-013: Connectivity check: internet reachable. Cascading to fallback.`
  - `[INFO] REQ-013: Connectivity check: internet reachable via HTTPS (ICMP blocked). Cascading to fallback.`
  - `[WARN] REQ-013: Connectivity check: no internet detected (ICMP and HTTPS check failed).`
  - `[INFO] REQ-013: Offline mode: skipping uv download.`
  - `[INFO] REQ-013: Offline mode: skipping Miniconda download.`
- CI test flag: `HP_TEST_OFFLINE=1` simulates ping failure for branch coverage.

---

## [REQ-014] System Python Consent Gate

- Before using system Python as the last-resort execution provider (REQ-009 Tier 4), the bootstrapper must obtain explicit user consent.
- Without consent, the bootstrapper aborts rather than silently running under an unmanaged system Python.
- Log contract:
  - `[INFO] REQ-014: System Python fallback aborted: consent not granted.`
  - `[INFO] REQ-014: System Python consent: user accepted.`
  - `[INFO] REQ-014: System Python consent: user declined.`
- CI test flag: `HP_TEST_FORCE_CONSENT_CHECK=1` directly triggers the consent gate for branch coverage.

---

## [REQ-015] Idempotent Git Config Merge

- At bootstrap time, the bootstrapper appends standard `.gitignore` and `.gitattributes` entries to the working directory.
- Uses a sentinel comment line to detect existing entries; never duplicates content already present.
- `.gitignore` additions: tilde-prefix work files (`~*`), env directories (`.venv/`, `.uv/`, `.*_env/`, `.cache/`, `.conda/`), build artifacts (`dist/`, `build/`).
- `.gitattributes` additions: `*.bat eol=crlf`, `*.cmd eol=crlf`, `*.exe binary`.
- Silent if no changes needed; logs when appending.
- Log contract:
  - `[INFO] REQ-015: Appending standard ignores to .gitignore.`
  - `[INFO] REQ-015: Appending standard attributes to .gitattributes.`

---

## [REQ-016] Post-flight Briefing

- After a successful full EXE build, the bootstrapper prints a scannable summary panel identifying the output EXE, files to keep, and files safe to delete.
- The panel always includes a **RUNNING YOUR APP** section covering the two most common beginner confusions with frozen Windows executables: (1) the console window flashing closed before output is visible (run from an already-open Command Prompt to keep it open), and (2) in-place progress output appearing all at once due to stdout buffering differences between the EXE and the script.
- When the packaged EXE could not be verified (its smoke run exited non-zero), the panel instead shows a **caveat**: the environment and dependencies are installed correctly, and the exact command to run the app directly via the prepared interpreter (`"<env python>" "<entry>"`). The bootstrap still completes (the environment is usable).
- The terminal window is **retained** on both success and error so the user can read the output before it closes.
- Log contract:
  - `[INFO] REQ-016: Post-flight briefing printed.`
  - `[WARN] REQ-016: Post-flight briefing printed; EXE unverified, advised direct run.`

---

## [REQ-012] Super-user Execution-skip Hooks

- For advanced/CI use, two environment variables let a caller build the environment and EXE **without executing any user code**:
  - `HP_SKIP_ENTRY_SMOKE=1` -- skip the entry-script interpreter smoke test (and the fast-path EXE reuse, which also runs the program). The build still runs; the result is left **unverified** (not a fake pass or fail).
  - `HP_SKIP_EXE_SMOKERUN=1` -- skip running the built/cached EXE for verification (both first-build and fast-path). "Skipped by request" is distinct from "failed verification": the post-flight panel shows a neutral note rather than the unverified caveat.
- With both set, env creation, dependency install, and the PyInstaller build all still run, but no user code executes.
- Log contract:
  - `[INFO] REQ-012: HP_SKIP_ENTRY_SMOKE set; skipping entry-script smoke test (no user code executed).`
  - `[INFO] REQ-012: HP_SKIP_EXE_SMOKERUN set; skipping EXE verification (skipped by request).`
- Test NDJSON row: `self.skiphooks.combined` (in `tests/selfapps_skiphooks.ps1`).

---

## [REQ-017] Bootstrapper Size Limit

- `run_setup.bat` is fully self-contained (all helper payloads are base64-embedded), so the single file is the entire deliverable.
- It must stay **under 20 MB** so it can be distributed by email. CI enforces this as a tripwire to catch unbounded future growth (the current size is a tiny fraction of the limit).
- Test NDJSON row: `self.size.tripwire` (in `tests/selfapps_size.ps1`).

---

## Advanced Environment Variables (reference)

Operational knobs, not needed for normal double-click use:

| Variable | Effect | REQ |
|----------|--------|-----|
| `HP_SKIP_ENTRY_SMOKE=1` | Skip the entry-script smoke test (no user code run) | REQ-012 |
| `HP_SKIP_EXE_SMOKERUN=1` | Skip running the built/cached EXE for verification | REQ-012 |
| `HP_SKIP_NIVISA=1` | Skip NI-VISA install even when pyvisa/visa is detected | REQ-008 |
| `NOINPUT=1` / `HP_NONINTERACTIVE=1` | Skip the interactive entry picker; take the alphabetical default | REQ-002 |

CI-only test-injection flags (`HP_TEST_*`, `HP_CI_*`, `HP_FORCE_CONDA_ONLY`, etc.) are documented inline in their respective REQ sections.

---

## [REQ-020] Cache Corruption Hardening

- On startup, if a previously downloaded conda or uv binary is found, the bootstrapper validates it with a health check before use.
- Corrupt conda binary: runs `conda.bat info`; on failure, halts with a user-friendly error message and offers to self-heal (re-download Miniconda). If the user declines, exits with code 2.
- Corrupt uv binary: detected at startup by a version probe; the cached binary is evicted so the next run downloads a fresh copy. Bootstrap continues via conda.
- Log contract:
  - `[ERROR] Corrupt conda binary detected at: <path>` (real corruption)
  - `[WARN] Cached uv.exe failed health check; clearing and re-downloading.` (real uv corruption)
  - `[INFO] Self-healing: corrupt conda evicted from <path>.` (user accepts self-heal)
  - `[ERROR] Corrupt conda env; user declined rebuild.` (user declines)
- CI test flags: `HP_TEST_CORRUPT_CONDA=1`, `HP_TEST_CORRUPT_UV=1`, `HP_TEST_HEAL_ANSWER=N`.
- Test NDJSON rows: `self.corrupt.conda.detect`, `self.corrupt.conda.heal.decline`, `self.corrupt.conda.heal.accept`, `self.corrupt.uv.detect` (in `tests/selftest.ps1`).

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
- Diagnostics keeps a parser-facing machine line `* Iterate logs: found|missing` in the markdown source, but the human-facing status now reports either `available`, `not needed (all checks passing)`, or `not produced yet (check batch-check run)` to avoid false alarms from the raw word `missing` alone.

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
