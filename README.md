# Python_vs_Windows

![Armchair Vibe Coded](promo/avc-shield-charcoal-left-purple-right.svg)
[![Batch syntax/run check](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/batch-check.yml/badge.svg?branch=main)](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/batch-check.yml)
[![CodeQL](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/codeql.yml)

**Live diagnostics bundle:** https://mixmansoundude.github.io/Python_vs_Windows/

Prime Directive: With only one or more Python files on a clean Windows 10+ machine with internet, get at least one to run, with all imports installed.

This tool is for beginners or unfamiliar users who have been given Python code and want to get it running, not for maintaining production repositories. It brute-forces a working environment: it discovers dependencies, installs them via the selected provider (uv, conda, or pip), and produces a standalone EXE. Getting the code to run takes priority over preserving outdated constraints.

---

### Armchair Vibe Coding

> This project was **entirely armchair vibe coded** -- built from a mobile device using conversational AI prompts, without a traditional development setup.

**What is Armchair Vibe Coding?**  
Armchair Vibe Coding is a new workflow where developers build software by interacting with AI tools (like ChatGPT or GitHub Copilot) primarily from mobile devices. It combines the philosophy of **vibe coding** -- coding through natural-language prompts and AI -- with a relaxed, mobile-first posture.

You're not at a desk. You're not opening VS Code. You're on your couch, your bed, a train -- just vibing and coding through AI.

> It's not just code -- it's coding on your terms, powered by AI and creativity, not IDEs and desk chairs.

This repository serves as a proof of concept of this new approach.

---

## TL;DR (Quickstart)

- **Windows 10 (1809+)** or newer.
- **One Folder per Program:** Create a unique folder for your project (e.g., `universal_paperclip_optimizer` or `solve_world_hunger_v2`).
- **Avoid Conflicts:** To ensure environment integrity, do not mix independent programs in the same folder. Each program should have its own dedicated folder and its own copy of `run_setup.bat`.
- **First run on Windows:** Windows may show "Windows protected your PC" -- click **More info** -> **Run anyway**. If "Run anyway" is absent: right-click the batch -> **Properties** -> check **Unblock** -> **OK** -> run again.
- **Setup:** Put your `.py` files and `run_setup.bat` in that folder, then double-click the `.bat`.
- **Running your app:** The first double-click sets up the environment, builds the app, verifies it, and offers to run it. Double-clicking `run_setup.bat` again later runs the ready app directly and quickly -- no console interaction needed -- rebuilding only if your code changed.
- **Environment Locking:** On the first run, `run_setup.bat` creates or respects a `runtime.txt` to "pin" the Python version. It applies similar logic for dependencies found in `requirements.txt`, `pyproject.toml`, or PEP 723 headers.

---

# Software Requirements Directive

**Intent of this directive.** This document specifies **what must happen** -- the observable,
user-facing outcomes the bootstrapper must guarantee -- stated as high-level and unambiguously as
possible, **independent of the current implementation or CI mechanics**. Test wiring, NDJSON rows,
CI lane behavior, and exact log strings are **implementation detail, not requirements**: they may
illustrate a requirement but never define it. Going forward, when a section is updated it should
trend toward this altitude -- keep the requirement crisp and let mechanism detail live in
**[AGENTS.md](./AGENTS.md)**, the `docs/` notes, or the diagnostics site.

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
  - If no single clear entry remains after those checks (multiple files, no clear winner), the bootstrapper falls through to a deterministic resolution:
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
- Conda environments (when conda is the selected provider): use **Miniconda** (non-admin).
- Writable, non-admin locations under Public Documents (conda provider):
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
  3. Otherwise let the **selected provider pick latest** (no hard-coded fallback); then **write back `runtime.txt`**. (When the conda provider is active, conda resolves the latest available Python from conda-forge.)

- Environment naming: env name equals the **current folder name**, sanitized (characters outside `[A-Za-z0-9_-]` (e.g. spaces) become `_`, a **leading hyphen** is replaced with `_`, and a name that reduces to only separators falls back to `env`; internal hyphens like `my-app` are preserved). When the conda provider is active, this sanitized name is passed to `conda create -n`. The derived name is logged: `[INFO] Environment name: <name>`.

- **Provider independence:** The bootstrapper cannot depend exclusively on a single provider. It must be able to function with only any one of the REQ-009 providers available (uv alone, conda alone, venv alone, or system Python alone). No bootstrap path may hard-require a specific provider to be present.
- UV is the preferred environment provider when available (cached or downloadable), as it is fast and avoids Miniconda download latency. When UV is unavailable or disabled, the bootstrapper falls back to Miniconda (conda provider), then to a local venv, and as a last resort runs the entry point under any available system Python. Every provider path preserves the Prime Directive -- at least one .py file runs with its imports satisfied.
- Why multiple providers instead of only one?
  - UV is fast and increasingly well-supported; prioritizing it reduces cold-start latency for new users.
  - Conda/Miniconda has deep ecosystem support and reproducible solver behavior; it remains the authoritative provider in CI (cache and conda-full lanes) and the fallback when UV is unavailable.
  - venv is a pragmatic fallback for networks or hosts where neither UV nor Conda can be installed or downloaded.
  - The fast path (reusing `dist/<envname>.exe` when non-helper sources are unchanged) sits on top of any provider, regardless of which one created the environment.
- [REQ-009] Environment discovery hierarchy (priority order):
  1. **UV** -- if `uv.exe` is available (cached or downloadable), create a `.uv_env` virtual environment using UV for fast dependency installs.
  2. **Conda (Portable / Miniconda)** -- install or reuse Miniconda at `%PUBLIC%\Documents\Miniconda3` (non-admin) and create a named conda env.
  3. **Local venv** (environment-creation fallback) -- if Conda is unavailable or fails, create a `.venv` virtual environment using whatever `python` / `py` is found on PATH (`python -m venv`). Still isolated, but depends on a pre-existing Python installation to create the env.
  4. **System Python** (final degraded execution mode) -- if no isolated environment can be created, run the entry point directly under the first `python` / `py` on PATH with no env isolation. Dependencies may conflict with system packages. **This tier is reachable in the default (no-flag) run** and is gated **only** by the REQ-014 consent prompt -- never by an opt-in environment variable. The legacy `HP_ALLOW_SYSTEM_FALLBACK` flag is **deprecated as a gate** (accepted but ignored, mirroring `HP_ALLOW_VENV_FALLBACK`). The CI-only `HP_FORCE_CONDA_ONLY` lane still suppresses all non-conda tiers for conda diagnostics.

  **Provider selection criteria (priority order):**

  | Provider | Priority | Notes |
  |----------|----------|-------|
  | UV (`.uv_env`) | 1st | REQ-009 |
  | Conda / Miniconda | 2nd | REQ-009 |
  | Local venv (`.venv`) | 3rd | REQ-009; env creation fallback |
  | System Python | 4th | REQ-009; degraded execution mode, no isolation |

  **Provider fallback trigger (current behavior):** The cascade to the next provider fires on *environment creation failure* only (e.g., uv venv create fails, Miniconda download fails). A provider that successfully creates its environment is not currently abandoned if dependency installation or warnfix repair later fails -- the bootstrap continues in a degraded state within the same provider. The intended direction is that a warnfix hard failure should also cascade to the next provider (e.g., uv warnfix exhausted -> retry full dep-install under conda).

- [REQ-006] Channels policy (applies when **conda is the selected provider**; determinism and legal-friction avoidance):
  - Before any conda updates or installs, force **community conda-forge only**:
    ```
    conda config --env --add channels conda-forge
    ```
  - Always install with `--override-channels -c conda-forge`.
  - These constraints do not apply to uv or venv providers, which use PyPI (pip) with no channel concept.
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

### Installation Strategy (provider-dependent)

The install strategy varies by the active REQ-009 provider. The steps below apply when **conda is the selected provider**. When uv or venv is the provider, pip is used directly (no conda install step, no channel policy).

- REQ-005.2 -- Conda bulk install (conda provider only): Attempt install from the selected dependency source:
  ```
  conda install --file <resolved_requirements> --override-channels -c conda-forge
  ```
  If this fails with a transient network signature (`CondaHTTPError`, `Failed to fetch`, `timed out`,
  `ConnectionError`), wait 15 seconds and retry once before falling through to REQ-005.3. This is the
  same retry mechanism REQ-022 applies to conda environment creation.
  - Log contract: `[INSTALL] conda bulk: transient failure detected; retrying after 15s.`
  - CI test flag: `HP_TEST_FORCE_CONDA_NETWORK_FAIL=1`.
  - Test NDJSON row: `self.stub.conda_retry` (in `tests/selftest.ps1`).

---

- REQ-005.3 -- Conda per-package fallback (conda provider only): If bulk install fails:
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

- REQ-005.7 -- pip gap fill: After the provider's primary install attempt (conda bulk/per-package when conda is active; uv or pip directly when uv/venv is active):
  ```
  pip install -r <resolved_requirements>
  ```
  Purpose:
  - Resolve packages unavailable or incomplete in the primary provider
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
  - On hard failure: cascade to the next REQ-009 provider (uv exhausted -> conda, conda exhausted -> venv, venv exhausted -> system Python) and re-attempt from the dependency installation phase, after explicit user consent (REQ-014 for the system tier).

---

### Design Principles

- Authoritative hierarchy is deterministic: PEP 723 > requirements.txt > pipreqs > none
- pipreqs is discovery only: Never trusted for completeness or versions
- No silent fallbacks: All degradations emit explicit warnings
- Single resolved dependency set: Conda + pip operate on the same inputs
- Execution success > dependency purity: System prioritizes working application over strict resolution correctness
- Provider cascade on hard failure (REQ-009/REQ-005.10): exhausting dep-install/warnfix repair within a provider triggers a consent-gated REQ-009 fallback to the next tier rather than a hard exit. The venv -> system tier is gated by the REQ-014 consent prompt and reachable in the default run.
- When missing imports are detected (for example from build-time warn files or installation output), the bootstrapper
  attempts to identify and install the missing packages using whatever signal is available. It cannot map all module
  names to conda package names (for example, `PIL` maps to `pillow`, `cv2` maps to `opencv`). This is a known
  limitation, not a bug.

### Dependency strategy

Summary of the design above, for readers linking directly to this anchor: **pipreqs is discovery
only** (static import scanning, never trusted for completeness or exact versions), **`requirements.txt`
is a hint, not authority** (getting the code to run takes priority over preserving the original
author's exact pin set), and **conda-forge is truth** (the resolved conda environment is the
source of record once installed, per REQ-006's channel policy). The known module-name-to-package-name
mapping limitation (`PIL` -> `pillow`, `cv2` -> `opencv`) above is the main practical consequence:
static analysis and the warnfix repair loop cannot always guess the correct package name from an
`import` statement, so an unusual mapping can occasionally require a `requirements.txt` hint from
the user to resolve cleanly on the first try.

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
- **Application-complete packaging**: the produced EXE must include the dependencies the application actually uses -- including ones loaded in ways a static packager cannot see (plugin/backend systems, runtime-resolved submodules, dynamic imports). Conversely it must not bundle libraries the application does not use: a trivial app must not inherit the bulk of whatever happens to be installed in the environment.
- **Self-healing of packaging misses**: when a freshly built EXE fails at runtime *solely* because an already-installed dependency was left out of the bundle, the bootstrapper attempts to repair the packaging and rebuild automatically, bounded so the attempt always terminates. It must not attempt repair for a failure it cannot mechanically fix -- a dependency the user never installed, or a fault in the user's own code -- which instead completes gracefully per the graceful-EXE-failure rule above. When self-healing does not apply it costs nothing (no extra rebuild).
- **Provider-independent build.** The EXE build is attempted regardless of which REQ-009 provider created the environment (uv, conda, or venv) -- it is the same normal build step in every case, not a special path. The single exception is the system-Python degraded mode (REQ-009 Tier 4): because building would install PyInstaller into the user's existing system Python, the build there is offered behind a separate explicit consent and, if declined or non-interactive, skipped with a logged reason -- never silently.
- **Explicit packaging vocabulary.** Every user-facing message about the build, verification, or failure of the standalone executable names the concrete artifact and tool in plain words -- "EXE", "PyInstaller", "standalone .exe" -- never vague phrasing like "packaging error" alone, so the user can always tell the message concerns the optional one-file executable, not their environment or dependencies (which are already installed and usable).

---

## [REQ-018] Controlled execution of user code

Running the user's program IS the goal -- a beginner who cannot launch it themselves is exactly who this tool serves -- but each run must be treated as potentially destructive: a program is not guaranteed to be idempotent, and one run can overwrite files, send network requests or email, mutate a database, or actuate connected hardware (e.g. a VISA/serial instrument). The bootstrapper therefore runs the user's code purposefully and at most once per invocation, never repeatedly and never via two launch methods in the same run.

- **Fast path is the user's run (frictionless).** When a current, already-verified EXE exists (sources unchanged since it was built), double-clicking the batch runs it directly and untimed, with no prompt and no console interaction -- the double-click is the user's intent to run, and this is the session's single run. A fast non-zero exit is still treated as a stale/broken EXE and triggers a rebuild (REQ-007); a program that keeps running is the user's app, left to run.
- **Verifying a fresh build is time-boxed and announced.** When the bootstrapper builds or rebuilds the EXE, it runs it once to verify, force-stopped after a short interval even if running fine, and preceded by a clear warning that this is a throwaway check so the user does not start real work in it. This is the only run that is killed on a timer.
- **After a build, the real run is offered, not forced.** Following a successful build and verification, the bootstrapper offers to launch the app untimed for real, so a beginner need not launch it manually. The offer is consent-gated and names the side-effect/idempotency risk; declining leaves the verified EXE plus the post-flight guidance.
- **Consent before any extra run.** Beyond the single automatic run, any further execution -- re-running, or running via the other launch method -- requires explicit consent that names the risk that the program may not be safe to run twice.
- **Non-interactive and CI** resolve every gate without hanging: no untimed run, and offers auto-decline.

---

## [REQ-021] Static pre-flight validation

Before executing or packaging the selected entry, the bootstrapper statically validates that it is syntactically loadable (byte-compilation of the entry file). A pure code-level error in the user's own program (a SyntaxError) is reported early, in plain language, and attributed to the user's code -- distinct from a dependency-install failure or a PyInstaller packaging failure -- so a user typo does not surface as a confusing downstream error. It reports an existing, unavoidable failure (a syntax error makes the program unrunnable under both the interpreter and PyInstaller) clearly and first; it never aborts a run that would otherwise have succeeded, and it costs nothing when the code is valid.

---

## [REQ-013] Network Resilience

The bootstrapper shall detect connectivity problems and be robust against transient network
failures during environment and dependency acquisition -- retrying before giving up on a step,
and falling through to the next REQ-009 provider tier rather than failing outright on a single
blip or a temporary outage.

- **Connectivity detection**: when a primary download fails (Miniconda or uv), the bootstrapper
  checks internet reachability before cascading to a fallback URL -- first an ICMP ping, then a
  lightweight HTTPS probe if ICMP is blocked. If both fail, it prompts the user to confirm
  offline mode or retry. In offline mode, internet-dependent steps (uv download, Miniconda
  download) are skipped; an already-cached Miniconda or uv install is used as-is.
- **Transient-failure retry**: conda environment creation, conda's bulk dependency install, and
  the venv fallback tier's pip bootstrap (via a downloaded `get-pip.py`, used when a plain venv
  creation attempt fails outright) each retry once on a detected transient failure before
  falling through to the next provider tier. Download steps (Miniconda, uv, get-pip.py)
  additionally retry across a primary URL, a PowerShell fallback method, and a secondary URL
  before giving up.
- Mechanism detail for each retry point (exact log lines, CI test flags, subroutine names) is
  intentionally not enumerated here -- see `docs/agent-lessons-learned.md` and CLAUDE.md's
  Closed Backlog, which are the authoritative source for implementation-level specifics.
- Log contract (illustrative, not exhaustive):
  - `[INFO] REQ-013: Connectivity check: internet reachable. Cascading to fallback.`
  - `[WARN] REQ-013: Connectivity check: no internet detected (ICMP and HTTPS check failed).`
- CI test flag: `HP_TEST_OFFLINE=1` simulates ping failure for connectivity-check branch
  coverage; per-mechanism retry test flags are documented alongside their subroutines in
  `docs/agent-lessons-learned.md`.

---

## [REQ-014] System Python Consent Gate

- Before using system Python as the last-resort execution provider (REQ-009 Tier 4), the bootstrapper must obtain explicit user consent.
- Without consent, the bootstrapper aborts rather than silently running under an unmanaged system Python.
- **This consent prompt is the sole gate on the system tier.** It is reached in the default (no-flag) run whenever uv, conda, and venv all fail -- it is not behind an opt-in environment variable. The bootstrapper echoes the prompt string unconditionally (so it is visible even on non-interactive auto-decline), then resolves the answer; an empty/declined answer aborts the tier and keeps the current build.
- Log contract:
  - `[INFO] REQ-014: System Python fallback aborted: consent not granted.`
  - `[INFO] REQ-014: System Python consent: user accepted.`
  - `[INFO] REQ-014: System Python consent: user declined.`
- CI test flags: `HP_TEST_FORCE_CONSENT_CHECK=1` directly triggers the consent gate at startup for branch coverage; `HP_TEST_SYSCON_ANSWER=Y|N` deterministically answers the prompt (and, like other interactive gates, `HP_CI_LANE` auto-declines with no `set /p` to avoid a CI hang).

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
- The panel sets realistic startup expectations: a one-file EXE can take noticeably longer to start than running the script (it self-extracts on each launch, more so when large or extra-bundled libraries are present), so a slow first appearance is not mistaken for a hang.
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

**Intended run paths are double-click and drag-and-drop, with no environment variables set.** All
`HP_*` and `PVW_*` environment variables are **test/CI/super-user scaffolding only**. No intended
user path may *require* the user to set such a flag, and the **absence** of any such flag must
never block a Prime-Directive outcome: a flag may add diagnostic/CI behavior or a super-user
override, or suppress an optional step (so absence == full behavior), but it is never the gate for
a behavior the Prime Directive needs. The default no-flag run must still reach every fallback tier
that gets the code running. Requirements and tests therefore exercise the no-flag path.

Operational knobs, not needed for normal double-click use:

| Variable | Effect | REQ |
|----------|--------|-----|
| `HP_SKIP_ENTRY_SMOKE=1` | Skip the entry-script smoke test (no user code run) | REQ-012 |
| `HP_SKIP_EXE_SMOKERUN=1` | Skip running the built/cached EXE for verification | REQ-012 |
| `HP_SKIP_NIVISA=1` | Skip NI-VISA install even when pyvisa/visa is detected | REQ-008 |
| `NOINPUT=1` / `HP_NONINTERACTIVE=1` | Skip the interactive entry picker; take the alphabetical default | REQ-002 |

**This table is not exhaustive -- for awareness only.** More `HP_*` / `PVW_*` / `HP_TEST_*`
variables exist (CI-only test-injection flags such as `HP_TEST_*`, `HP_CI_*`, and
`HP_FORCE_CONDA_ONLY` are documented inline in their respective REQ sections). The authoritative
set lives in `run_setup.bat`.

---

## [REQ-020] Cache Corruption Hardening

- On startup, if a previously downloaded conda or uv binary is found, the bootstrapper validates it with a health check before use.
- Corrupt conda binary: runs `conda.bat info`; on failure, halts with a user-friendly error message and offers to self-heal (re-download Miniconda). If the user declines, exits with code 2.
- Corrupt uv binary: detected at startup by a version probe; the cached binary is evicted so the next run downloads a fresh copy. Bootstrap continues via the next available provider (conda if available, otherwise venv or system Python).
- Log contract:
  - `[ERROR] Corrupt conda binary detected at: <path>` (real corruption)
  - `[WARN] Cached uv.exe failed health check; clearing and re-downloading.` (real uv corruption)
  - `[INFO] Self-healing: corrupt conda evicted from <path>.` (user accepts self-heal)
  - `[ERROR] Corrupt conda env; user declined rebuild.` (user declines)
- CI test flags: `HP_TEST_CORRUPT_CONDA=1`, `HP_TEST_CORRUPT_UV=1`, `HP_TEST_HEAL_ANSWER=N`.
- Test NDJSON rows: `self.corrupt.conda.detect`, `self.corrupt.conda.heal.decline`, `self.corrupt.conda.heal.accept`, `self.corrupt.uv.detect` (in `tests/selftest.ps1`).

---

## [REQ-023] Venv Fallback Canary Probe

- After the REQ-009 Tier 3 venv fallback (`:try_venv_fallback`) creates `.venv` and confirms the interpreter file exists, the bootstrapper verifies the interpreter actually runs (`python -c "import sys"`) before declaring the tier ready.
- A venv can be "created" (directory and `python.exe` present) yet still be non-functional (missing DLLs, broken symlinks, execution-policy blocks). Without this check, a silently broken venv would reach PyInstaller and fail later with a more confusing error, or be reported as bootstrap success when the environment cannot actually run code.
- If the probe fails, the venv tier is declined (as if creation itself had failed) and the bootstrap falls through to the next REQ-009 provider (system Python).
- Log contract:
  - `[WARN] venv fallback: interpreter created but failed canary probe (import sys).`
- CI test flag: `HP_TEST_FORCE_VENV_CANARY_FAIL=1` simulates a failing probe after a real, successful venv creation.
- Test NDJSON row: `self.venv.canary_fail` (in `tests/selfapps_ux_hardening.ps1`).
- The venv fallback tier's retry-on-transient-failure behavior (when plain venv creation fails
  outright, distinct from this canary probe) is part of the REQ-013 Network Resilience
  requirement above, not this one -- this section covers only the post-creation health check.

---

## Maintenance, Logging, and Lessons Learned

- Update conda base periodically (~30 days), but **skip on first Miniconda install**. Ensure base is configured to conda-forge before updating to avoid prompts.
- Single rolling log `~setup.log` capped near **10 MB** total, don't spin out extra log files. Trim at start. Use debug-level detail when `VERBOSE=1`.
- Tilde-prefix any files not meant to persist (or may remain after a crash) so they are easy to ignore in VCS.
- Avoid `EnableDelayedExpansion`. If unavoidable, enable only around the exact lines, then disable. Force disable at script start.
- Be robust against parent shells started with `CMD /V:ON` and 3rd-party wrappers.
- Treat special characters (`&`, `~`, etc.) carefully in batch.
- ASCII only: no emojis, curly quotes, em-dashes, or ellipses.
- Always call the batch (call "%CONDA_BAT%" ...) so the parent script continues.
- Quote batch variables carefully to survive if there are spaces in their contents.
- After the silent install, recompute the %CONDA_BAT% path (condabin first; Scripts as fallback).

---

## Agent Guardrails (Codex / Copilot / other agents)

- Enforce and obey this README; see **[AGENTS.md](./AGENTS.md)** for the full agent policy.
  
---

## Repository Map

- `run_setup.bat` -- bootstrap installer (Miniconda + env + deps + optional EXE)
- `run_tests.bat` -- CI/static checks and harness
- `tests/` -- PowerShell/batch harness, log helpers, and ndjson summaries
- `.github/workflows/` -- CI workflows (batch check + CodeQL)
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
- `bootstrap.log` -- full bootstrap transcript.
- `~setup.log` -- rolling setup log from the batch.
- `tests/~dynamic-run.log` -- canonical dynamic test status line.
- `tests/~test-summary.txt` -- condensed static harness output.
- `tests/~test-results.ndjson` -- machine-readable check results.
- `tests/extracted/**` -- helper scripts decoded from the bootstrapper for inspection.

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

MIT -- see `LICENSE`.
