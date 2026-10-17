# Python_vs_Windows

![Armchair Vibe Coded](promo/avc-shield-charcoal-left-purple-right.svg)
[![Batch syntax/run check](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/batch-check.yml/badge.svg?branch=main)](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/batch-check.yml)
[![CodeQL](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/codeql.yml)

**Just want the file?** This repo's root has a lot in it -- the one file you actually need is
`run_setup.bat`. Right-click the link below and "Save link as..." (or open it and press Ctrl+S):

**-> [https://raw.githubusercontent.com/mixmansoundude/Python_vs_Windows/main/run_setup.bat](https://raw.githubusercontent.com/mixmansoundude/Python_vs_Windows/main/run_setup.bat) <-**

No git, no terminal, no zip file -- just that one `.bat` file. If that link ever behaves oddly
(some browsers try to "helpfully" convert or preview it), this mirror is republished from `main`
on every push and works the same way: https://mixmansoundude.github.io/Python_vs_Windows/run_setup.bat

**Live diagnostics bundle:** https://mixmansoundude.github.io/Python_vs_Windows/

Prime Directive: With only one or more Python files on a clean Windows 10+ machine with internet, get at least one to run, with all imports installed.

This tool is for beginners or unfamiliar users who have been given Python code and want to get it running, not for maintaining production repositories. It brute-forces a working environment: it discovers dependencies, installs them via the selected provider (uv, conda, or pip), and produces a standalone EXE. Getting the code to run takes priority over preserving outdated constraints.

---

### Why does this exist? (a true-to-life example)

> **You:** Head of Cybersecurity Jim sent me a Python file he AI-vibe-coded to solve all my problems, but I don't know what Python is.
>
> **Me:** Put the Python file in its own folder, open PowerShell in that folder (Shift+right-click -> "Open PowerShell window here"), paste `irm https://astral.sh/uv/install.ps1 | iex` to install uv, restart the terminal, then type `uvx autopep723 solve_my_probs.py`. First run might take a minute or two.
>
> **You:** Wow, that was fast! Worked great once I figured out how to open a terminal for the first time (never doing that again).
>
> *Two hours later...*
>
> **You:** Jim sent me multiple Python files and then won the lottery. It runs for a bit, then says something about `ModuleNotFoundError`. I'm not even sure which file to put in the `uv run` command, and Jim won't get off his yacht to help me. What do I do?
>
> **Me:** Try this `run_setup.bat`. Brute force is the name of the game. Stand back and give it a minute -- it should figure out something to run for you, once, and only once, by default.

The first exchange is the honest, fast path for anyone who can find a terminal and doesn't mind a one-time restart -- and it's a real, good recommendation for a single self-contained script. The second is what this tool exists for: multiple files, ambiguous entry points, missing dependencies discovered mid-run, and a Jim who is unavailable. See "Why 'Build-First, Run-Once'?" near the end of this README for the deeper reasoning behind that "once, and only once" promise.

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
- **Getting `run_setup.bat`:** Right-click GitHub's "Raw" button (or [this direct link](https://raw.githubusercontent.com/mixmansoundude/Python_vs_Windows/main/run_setup.bat)) and "Save link as...", or use `git clone https://github.com/mixmansoundude/Python_vs_Windows` and copy the file from there -- both now give you the Windows (CRLF) line endings the script needs (this repo enforces that in CI on every change). If you ever land on a copy with the wrong line endings anyway (an old cached download, an editor that "helpfully" re-saved it), the script detects it on startup and tells you exactly how to fix it, rather than failing silently.
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

**How requirements are written here.** A section that has been converted opens with its goal, written
with "should", and keeps its `[REQ-nnn]` id. Beneath it, each verifiable requirement is one numbered
"shall" (`REQ-nnn.m`) with a criticality tag (`[critical]`, `[major]` or `[minor]`); the notes after the
shalls explain why and how, and are not requirements. Sections not yet converted keep their older prose
until a change that works on their tests rewrites them; where a numbered shall and older prose differ, the
shall governs. The writing rules are in AGENTS.md, "Writing README requirements".

### Terms

- **program**: the user's Python code in the folder, starting from the entry file.
- **entry file**: the `.py` file the bootstrapper selects to start the program (REQ-002).
- **folder**: the directory that holds `run_setup.bat` and the program.
- **working file**: a file the bootstrapper creates in the folder whose name begins with `~` (REQ-015).
- **selected interpreter**: the Python interpreter of the provider the bootstrapper chose for the run
  (REQ-009).
- **non-interactive run**: a run in which `NOINPUT`, `HP_NONINTERACTIVE` or `HP_CI_LANE` is set in the
  environment. **Interactive run**: any other run, in which the bootstrapper may wait for the user to answer.
  `NOINPUT` and `HP_NONINTERACTIVE` are the documented user controls (see Advanced Environment Variables);
  `HP_CI_LANE` is the marker the CI lanes set. Test hooks named `HP_TEST_*` are never part of this
  definition. Some individual prompts read fewer of the three signals than this term lists; those
  differences are tracked in `docs/open-questions.md`.

## [REQ-001] Prime Directive Expanded

**Goal.** A person who has only one or more `.py` files on a clean Windows 10+ machine with internet access
should be able to double-click a **single batch file** and have the Python program run **with all of its
imports installed**.

- **REQ-001.1** [critical] The bootstrapper **shall**, when the user starts `run_setup.bat` in a folder that
  holds `.py` files on a Windows 10 or newer machine with internet access, set up everything the program needs
  and run the program with all of its imports installed, without anything having been installed or configured
  beforehand.
- **REQ-001.2** [major] The bootstrapper **shall**, when the path of the folder contains an accented Latin
  letter (for example e with an acute accent, U+00E9), set up and run the program the same way it does for a
  path of ASCII letters only.

> **Notes (non-normative).**
> - REQ-001.2 is exercised with the folder `Caf<U+00E9> Test\Jos<U+00E9>` (an accented letter in two
>   components, one with a space). The environment name, and so the EXE name, loses the accented letter
>   (`Jos_.exe`). Characters outside the system code page, and the Miniconda location (REQ-003.2), are not
>   covered by it.

### [REQ-002] Entry selection (current behavior)
- **0 Python files**: the bootstrapper reports no Python files and skips environment bootstrap. It prints:
  - `Python file count: 0`
  - `No Python files detected; skipping environment bootstrap.`
- **Exactly 1 Python file**: run that file directly.
- **2 or more Python files**: prefer a clear entry by:
  0) Manual override (`%1` argument, e.g. drag-and-drop) -- if the file is co-located with the bootstrapper (REQ-011), it is used directly and skips all auto-detection. The argument must name an existing `.py` file, as typed or with `.py` appended (`run_setup.bat main` uses `main.py`). Anything else (a `.csv`, a name that is not a file, a wildcard) stops the run before anything is built or run, with `Usage: run_setup.bat your_script.py [arguments for your program]`; it is never ignored and never taken as the entry. See REQ-026 for the arguments that follow it.
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

**Goal.** The bootstrapper should run on Windows 10 (1809) or newer using the `curl` and PowerShell that
Windows ships, and should keep everything it installs in writable, non-admin locations.

- **REQ-003.1** [major] The bootstrapper **shall** run on Windows 10 (version 1809) or newer, using the
  `curl` and PowerShell that Windows ships.
- **REQ-003.2** [major] When conda is the selected provider, the bootstrapper **shall** use Miniconda, installed
  under `%PUBLIC%\Documents\Miniconda3`.
- **REQ-003.3** [major] The bootstrapper **shall** create its working files and its build output in the
  folder where it was started.
- **REQ-003.4** [minor] When the bootstrapper is started from a UNC path (`\\server\share\...`), it **shall**
  print a warning that names the UNC path, report `Workspace path invalid`, exit with code 1 and leave the
  folder without a `dist` folder or a setup log.

> **Notes (non-normative).**
> - Limitation: UNC/network paths (`\\server\share`) are not supported for reliable bootstrap behavior. The
>   warning of REQ-003.4 recommends mapping the share to a drive letter and running `run_setup.bat` again,
>   which is what the user should do. CMD cannot make a UNC path its current directory, which is why the
>   run stops. The test starts a copy through the runner's own administrative share
>   (`\\localhost\<drive>$\...`).
> - Limitation: Unicode/high-bit characters in key paths are not guaranteed to work across all bootstrap
>   steps. REQ-001.2 covers accented letters in the folder path; other characters are not covered.

---

## Python & Environment

- [REQ-004] Python version detection precedence:
  1. `runtime.txt` (`python-3.x.y` or `3.x[.y]`)
  2. `pyproject.toml` `requires-python`
  3. Otherwise let the **selected provider pick latest** (no hard-coded fallback); then **write back `runtime.txt`**. (When the conda provider is active, conda resolves the latest available Python from conda-forge; when the embedded-Python provider is active, it resolves to the newest entry in its pinned version table.)

- Environment naming: env name equals the **current folder name**, sanitized (`&` is first special-cased to the bare word `and` for readability, e.g. `Sales & Marketing` -> `Sales_and_Marketing`; then characters outside `[A-Za-z0-9_-]` (e.g. spaces) become `_`; a **leading hyphen** is replaced with `_`; the result is **truncated to 64 characters** whenever it exceeds that length (most commonly caused by the `&`->`and` expansion, which can make the sanitized name longer than the original); and a name that reduces to only separators falls back to `env`; internal hyphens like `my-app` are preserved). When the conda provider is active, this sanitized name is passed to `conda create -n`. The derived name is logged: `[INFO] Environment name: <name>`.

- **Provider independence:** The bootstrapper cannot depend exclusively on a single provider. It must be able to function with only any one of the REQ-009 providers available (uv alone, conda alone, embedded Python alone, venv alone, or system Python alone). No bootstrap path may hard-require a specific provider to be present.
- UV is the preferred environment provider when available (cached or downloadable), as it is fast and avoids Miniconda download latency. When UV is unavailable or disabled, the bootstrapper falls back to Miniconda (conda provider); if conda also fails, it downloads a checksum-verified embeddable Python build directly from python.org (no admin rights, no pre-existing Python required); if that fails too, it falls back to a local venv built from whatever Python is already on the machine; and as a last resort runs the entry point under any available system Python. Every provider path preserves the Prime Directive -- at least one .py file runs with its imports satisfied.
- Why multiple providers instead of only one?
  - UV is fast and increasingly well-supported; prioritizing it reduces cold-start latency for new users.
  - Conda/Miniconda has deep ecosystem support and reproducible solver behavior; it remains the authoritative provider in CI (cache and conda-full lanes) and the fallback when UV is unavailable.
  - The embedded-Python download covers a gap neither UV, Conda, nor venv can cover alone: when a specific Python version is pinned (`runtime.txt` / `pyproject.toml`) but UV and Conda are both unreachable, fetching a fresh, checksum-verified interpreter is the only way to still honor that pin, rather than silently falling back to whatever (if anything) already happens to be on the machine.
  - venv is a pragmatic fallback for hosts that already have a working ambient Python but where UV, Conda, and the embedded-Python download are all unavailable (e.g., no network at all).
  - The fast path (reusing `dist/<envname>.exe` when non-helper sources are unchanged) sits on top of any provider, regardless of which one created the environment.

  Why do these tiers tend to fail, and what does it mean when a run falls through several in a row?

  | Tier | Depends on | Typical failure causes |
  |------|-----------|------------------------|
  | UV | network reachability, disk write | transient network blip, proxy/TLS interception, antivirus quarantining the fresh binary |
  | Conda (Miniconda) | network (larger download), disk space, installer permissions | interrupted download, an `AllUsers` install permission failure (a `JustMe` retry mitigates this), transient index/repo errors, low disk space |
  | Embedded Python | network (small download), checksum match | corrupted or interrupted download, a stalled connection |
  | Local venv | an ambient Python that already works | no ambient Python at all, a broken/stripped install missing `ensurepip`, execution-policy blocks |
  | System Python | same as venv, plus explicit consent | same as venv, or the user declining the consent prompt |

  Falling through three or more tiers in one run is almost always one shared root cause rather than independent bad luck at each tier: no usable internet (or a proxy/firewall blocking the relevant domains) explains UV, Conda, and Embedded Python failing together, since all three need network; a full disk explains the same three failing together for a different reason; no admin rights mainly affects Conda's `AllUsers` install path and doesn't block any other tier, since none of the rest require elevation; and a locked-down managed image (antivirus blocking new executables, a domain allow-list) produces the same symptom as "no internet" but is a policy failure, not a resource one -- no amount of retrying fixes it. A machine where even a bare `python.exe` can't run at all is rare and correctly out of scope for this bootstrapper.

- [REQ-009] Environment discovery hierarchy (priority order):
  1. **UV** -- if `uv.exe` is available (cached or downloadable), create a `.uv_env` virtual environment using UV for fast dependency installs.
  2. **Conda (Portable / Miniconda)** -- install or reuse Miniconda at `%PUBLIC%\Documents\Miniconda3` (non-admin) and create a named conda env.
  3. **Embedded Python** (fresh-acquisition fallback) -- if Conda is unavailable or fails, download the official python.org embeddable zip (checksum-verified against an embedded SHA256), extract it to a private `~embed_python\` directory, and bootstrap pip into it. Honors a pinned `runtime.txt` / `pyproject.toml` version if one is set; no admin rights and no pre-existing Python required.
  4. **Local venv** (environment-creation fallback) -- if Conda and the embedded-Python download are both unavailable or fail, create a `.venv` virtual environment using whatever `python` / `py` is found on PATH (`python -m venv`). Still isolated, but depends on a pre-existing Python installation to create the env.
  5. **System Python** (final degraded execution mode) -- if no isolated environment can be created, run the entry point directly under the first `python` / `py` on PATH with no env isolation. Dependencies may conflict with system packages. **This tier is reachable in the default (no-flag) run** and is gated **only** by the REQ-014 consent prompt -- never by an opt-in environment variable. The legacy `HP_ALLOW_SYSTEM_FALLBACK` flag is **deprecated as a gate** (accepted but ignored, mirroring `HP_ALLOW_VENV_FALLBACK`). The CI-only `HP_FORCE_CONDA_ONLY` lane still suppresses all non-conda tiers for conda diagnostics.

  **Provider selection criteria (priority order):**

  | Provider | Priority | Notes |
  |----------|----------|-------|
  | UV (`.uv_env`) | 1st | REQ-009 |
  | Conda / Miniconda | 2nd | REQ-009 |
  | Embedded Python | 3rd | REQ-009; fresh-acquisition fallback |
  | Local venv (`.venv`) | 4th | REQ-009; env creation fallback |
  | System Python | 5th | REQ-009; degraded execution mode, no isolation |

  **Provider fallback trigger:** environment-creation failure (e.g., uv venv create fails, Miniconda download fails, the embedded-Python download fails) cascades immediately to the next provider tier. A warnfix hard failure (dependencies still unresolved after the repair loop exhausts) also cascades to the next tier and re-attempts dependency installation there, gated by explicit user consent before the run continues under a different provider (see REQ-005.10, and REQ-014 for the system tier's own consent gate).

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
  - On mismatch: `[ERROR] REQ-011: Dragged files must reside in the bootstrapper root folder for environment cleanliness.` -- script aborts (exit 1) and releases the concurrent-instance lock, so the next run in that folder starts normally.
  - The same pre-flight step then requires the argument to be an existing `.py` file in that folder, as typed or with `.py` appended (REQ-002, CLAUDE.md Item 67). Otherwise it prints `[ERROR] The first argument must be one of your Python files in this folder.` and the usage line, writes status `error` (exit 1), releases the lock, and stops before the cached-EXE fast path. The existing EXE, the environment and the dependency files are not touched.
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

The install strategy varies by the active REQ-009 provider. The steps below apply when **conda is the selected provider**. When uv, embedded Python, or venv is the provider, pip is used directly (no conda install step, no channel policy). When system Python is the provider, automatic dependency installation is skipped entirely (a deliberately minimal-footprint design for a shared, uncontrolled environment).

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
  pipreqs . --force --mode compat --savepath requirements.auto.txt --encoding utf-8
  ```
  - `compat` ensures cross-runner determinism
  - `--force` overwrites stale output
  - `--savepath` preserves original requirements
  - `--encoding utf-8` because pipreqs otherwise reads every `.py` with the Windows locale encoding
    (cp1252 on Western systems before Python 3.15), which cannot decode ordinary UTF-8 text such as
    a curly double quote or an emoji
  - Behavior: Used for visibility and fallback only
  - Failure does not stop bootstrap: `[WARN] pipreqs failed, continuing with available sources`
  - Pre-check: pipreqs stops its whole scan at the first `.py` it cannot decode or parse, so before it
    runs every `.py` under the folder (subfolders included, minus the ignored folders) is checked using
    its declared or detected encoding and parsed, and one line per file giving its encoding (the first
    100 files) is written to `~setup.log`. If all are clean UTF-8, pipreqs scans the folder in place. Otherwise pipreqs scans
    a UTF-8 copy of the folder under the temp folder and the original files are never changed: a file
    in another declared encoding is re-encoded, and a file that cannot be read or does not parse is
    left out of the scan. The first 25 files left out are each named in a `[WARN]` line on the console and in
    `~setup.log` that says the detected requirements may be incomplete, followed by a count of any
    further files left out; the full report is `~pipreqs_precheck.txt`. A left-out file keeps its module name as a local module, so an
    `import` of it is never treated as a requirement.
  - A pipreqs crash is never reported as "no imports found": the console and `~setup.log` say pipreqs
    crashed and point at `~pipreqs_direct.log`, whose contents are copied into `~setup.log`.
  - The scan's own output file is never stale: before pipreqs runs, any old `requirements.auto.txt` in
    the folder is deleted (a read-only one too), so an old file cannot be taken for this run's result.
    If the new result cannot be written because another program has the old file open, the console
    names `requirements.auto.txt`, the scan is reported as failed (`~pipreqs.summary.txt` says
    `Phase: failed`), and setup carries on without auto-detected requirements.
  - The UTF-8 copy lives in a temp folder named for this run, so two projects set up at the same time
    never delete each other's copy, and the copy is removed when the scan ends.
  - Test NDJSON rows: `self.pipreqs.encoding.curly_quote`, `.mixed_files`, `.never_no_imports`
    (`tests/selfapps_pipreqs_encoding.ps1`, `real` lane, gating); `self.pipreqs.output.readonly_replaced`,
    `.temp_isolated`, `.locked_named`, `.locked_crash` (`tests/selfapps_pipreqs_output.ps1`, `real` lane, gating).

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

- REQ-005.9 -- Missing import detection and repair: If missing modules are detected during dependency install or EXE build, the bootstrapper must attempt to identify and install them automatically. Names known in advance to be un-installable are filtered out before any install is attempted, so repair never wastes a cycle on something guaranteed to fail: the standard library of the interpreter that built the program (a stdlib name can match an unrelated, broken old package on PyPI), platform-only and removed standard-library modules, obsolete Python 2 compatibility shims a dependency's own code still references, other interpreters' and operating systems' modules (`java`, `AppKit`), PyInstaller's own runtime modules (`pyimod02_importers`), and any `X.attr` whose package `X` is already installed (installing `X` cannot add an attribute). A missing module is also installed only when the program's own code imports it: an entry whose importers are all the standard library or installed packages (`pandas.io.sql` asking for `sqlalchemy`, `plotly.basewidget` asking for `traitlets`) is that library's optional backend, left to the library's own dependency metadata, and an importer that cannot be placed counts as the program's own so a real dependency is never dropped.

---

- REQ-005.10 -- Retry loop: After repair attempts, rebuild/re-run until:
  - Success (application runs), or
  - Hard failure (unresolvable within the current provider)
  - On hard failure: cascade to the next REQ-009 provider (uv exhausted -> conda, conda exhausted -> embedded Python, embedded Python exhausted -> venv, venv exhausted -> system Python) and re-attempt from the dependency installation phase, after explicit user consent (REQ-014 for the system tier).
  - A run that fails under uv can also reach the uv -> conda cascade after the run, through the last-chance offer described under REQ-018 (planned, not yet built), with the same consent rule.

---

### PEP 723 Header Write-Back (uv lane)

- REQ-005.11 -- After a fresh, fully-successful dependency install (uv mode only, v1) or a
  fully-successful warnfix repair round, promote the resolved dependency set into the entry
  file's own PEP 723 header via `uv add --script`, so the pin becomes part of the user's own
  source rather than only a transient `requirements.txt`/lock file this bootstrapper manages.
  Complements REQ-004's PEP 723 as a Tier-1 dependency *source*: REQ-005.11 is the write-back
  direction, promoting a *resolved* set back into that same header.
  - Scope gate: only runs when `HP_ENV_MODE=uv`. A partially-failed install or repair round
    never triggers a write-back (all-or-nothing per round).
  - Delegates malformed-header detection entirely to `uv`'s own exit code (a strip-and-retry-
    once sequence on exit 2) rather than a second, bespoke TOML validator.
  - Best-effort and never gates the Prime Directive: any failure is logged as a `[WARN]` and
    the run continues exactly as if the feature were absent.
  - Opt-out: `HP_SKIP_PEP723_WRITEBACK=1` (suppression-only flag, see `[REQ-019]`).
  - TESTED: `tests/test_pep723_writeback.py`, `tests/selfapps_pep723_writeback.ps1`.

---

### autopep723 Discovery Augmentation (uv lane)

- REQ-005.12 -- Alongside pipreqs's own scan, run `uvx autopep723 check <entry>` against the
  resolved entry file and merge any additionally-discovered dependency names into
  `requirements.txt` (union, deduplicated, additive-only -- never removes or reorders anything
  already there). Non-gating and never a cause of lane failure on its own: a missing, empty, or
  failed `autopep723 check` result is a silent no-op and pipreqs's own results stand unchanged.
  - `uvx` runs `autopep723` in an isolated tool venv rather than a direct interpreter
    invocation, avoiding a real environment-leak hazard where a direct invocation silently
    under-reports already-installed packages as "not third-party" (see
    `docs/agent-lessons-learned.md`'s autopep723 section for the full empirical trail).
  - Scope gate: only runs when `HP_ENV_MODE=uv` (v1, matching REQ-005.11's own scope decision).
  - Opt-out: `HP_SKIP_AUTOPEP_DISCOVERY=1` (suppression-only flag, see `[REQ-019]`).
  - TESTED: `tests/test_autopep_merge.py`, `tests/selfapps_autopep_discovery.ps1`.

---

### Execute-Mode Dependency Discovery (opt-in, uv lane)

- REQ-005.13 -- `HP_PVW_KNOWN_IDEMPOTENT=1` (opt-in only, never a default): actually run the
  entry script via `uvx autopep723 <entry>` as a dependency-discovery mechanism, for users who
  have explicitly declared their own script safe to run more than once. Relocates the "Just run
  it (and remember what it needed)" logic from README's PVW QuickStart section into
  `run_setup.bat` itself -- same exit-code branching (0 = ran clean, best-effort persist; 2 =
  malformed header, strip-and-retry-once; other nonzero = fill in what's missing without
  stripping, retry once), not a new mechanism.
  - The script's own output prints live to the console -- stdout is never captured or
    suppressed, exactly like running it directly with `python entry.py`.
  - Additive, not a replacement: pipreqs and the REQ-005.12 discovery merge still run normally
    afterward, catching anything a single execution path didn't happen to exercise.
  - Runs before pyproject.toml/PEP 723 header/pipreqs discovery, not after -- see
    `docs/agent-interconnect.md`'s "HP_PVW_KNOWN_IDEMPOTENT execute-mode discovery" section for
    the full hook-point rationale.
  - Scope gate: only runs when `HP_ENV_MODE=uv` (v1, matching REQ-005.11/REQ-005.12's own scope
    decision).
  - Never gates the Prime Directive: the flag's very absence leaves this whole step a no-op, and
    any failure here falls back gracefully to the Default Path.
  - TESTED: `tests/test_pvw_known_idempotent.py`, `tests/selfapps_pvw_idempotent.ps1`.

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
- Scan scope (documented behavior): the import scan covers every `.py` below the bootstrapper's folder, subfolders included (directories starting with `~` or `.`, and `.py` files whose names start with `~`, are skipped), not only the entry file or the files it imports. An `import pyvisa` or `import visa` in an archived or unrelated subfolder therefore counts and can start the driver install, which can take 30-45 minutes. The bootstrapper does not trace the entry file's import chain.
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
- **Provider-independent build.** The EXE build is attempted regardless of which REQ-009 provider created the environment (uv, conda, embedded Python, or venv) -- it is the same normal build step in every case, not a special path. The single exception is the system-Python degraded mode (REQ-009 Tier 4): because building would install PyInstaller into the user's existing system Python, the build there is offered behind a separate explicit consent and, if declined or non-interactive, skipped with a logged reason -- never silently.
- **Explicit packaging vocabulary.** Every user-facing message about the build, verification, or failure of the standalone executable names the concrete artifact and tool in plain words -- "EXE", "PyInstaller", "standalone .exe" -- never vague phrasing like "packaging error" alone, so the user can always tell the message concerns the optional one-file executable, not their environment or dependencies (which are already installed and usable).

---

## [REQ-018] Controlled execution of user code

Running the user's program IS the goal -- a beginner who cannot launch it themselves is exactly who this tool serves -- but each run must be treated as potentially destructive: a program is not guaranteed to be idempotent, and one run can overwrite files, send network requests or email, mutate a database, or actuate connected hardware (e.g. a VISA/serial instrument). The bootstrapper therefore runs the user's code purposefully and at most once per invocation, never repeatedly and never via two launch methods in the same run.

- **Fast path is the user's run (frictionless).** When a current, already-verified EXE exists (sources unchanged since it was built), double-clicking the batch runs it directly and untimed, with no prompt and no console interaction -- the double-click is the user's intent to run, and this is the session's single run. A fast non-zero exit is still treated as a stale/broken EXE and triggers a rebuild (REQ-007); a program that keeps running is the user's app, left to run.
- **Verifying a fresh build is activity-aware and announced.** When the bootstrapper builds or rebuilds the EXE, it runs it once to verify, preceded by a clear warning that this is a throwaway check so the user does not start real work in it. This run is only force-stopped if it stays completely silent for about 30 seconds; any output at all -- including a prompt waiting on input -- keeps it running for as long as needed, so an interactive program gets a real chance to be exercised. (A separate, narrower re-verification inside the `--hidden-import` auto-recovery loop remains unconditionally time-boxed at ~30 seconds, since it exists only to confirm one specific repair worked.) This is the only primary verification run that can be force-stopped at all.
- **After a build, the real run is offered, not forced.** Following a successful build and verification, the bootstrapper offers to launch the app untimed for real, so a beginner need not launch it manually. The offer is consent-gated and names the side-effect/idempotency risk; declining leaves the verified EXE plus the post-flight guidance.
- **Consent before any extra run.** Beyond the single automatic run, any further execution -- re-running, or running via the other launch method -- requires explicit consent that names the risk that the program may not be safe to run twice.
- **Missing packages named at runtime.** After each run of your program that the bootstrapper
  makes (the EXE verification run, the interpreter run, and the optional second run), it reads that
  run's error output, whatever the exit code was. A program can print
  `ModuleNotFoundError: No module named X` and still exit 0, because a window toolkit catches an error
  raised in a button handler, prints it and keeps running. When X is not installed in the environment,
  the console says so right after the run and again at the end, and tells you to add X, or the package
  that provides it, to the file your dependencies come from and run again: `requirements.txt`, the
  `[project]` dependencies in `pyproject.toml`, or the PEP 723 header of your script, whichever the run
  reported as its dependency source (the last two are copied over `requirements.txt` on every run, so
  editing `requirements.txt` would not last). This reading step itself installs and edits nothing and does
  not run your program again; the offer below is a separate step that asks first. Standard library names (such as `tkinter`) and modules
  that sit next to your script are not reported. The cached-EXE fast path skips this check, because it
  runs before any interpreter is chosen.
- **Installing a missing package.** When the check above finds a module that is not installed, the
  bootstrapper asks once per run, before it installs anything, edits `requirements.txt` or rebuilds: it
  lists the packages and waits 30 seconds for Y or N (a quiet run, a CI run and a bare Enter all mean no). A
  yes installs each package into the program's own environment (never into a system Python, and never under
  the fallback build system's EXE), adds it to `requirements.txt` unless it is already listed (when your
  dependency source is `pyproject.toml` or a PEP 723 header, which are copied over `requirements.txt` on
  every run, nothing is edited: the prompt and the log tell you to add the package to that file yourself),
  rebuilds the EXE with `--hidden-import` and `--collect-submodules` for each new module when there is one,
  and runs your program one more time to check; that one extra run is covered by the yes. The log ends with
  `verified` when the check run no longer names the module, or says it still does. A failed install or
  rebuild stops there, with no provider cascade. A no changes nothing and the module is only named, as
  above. The import name is turned into the package name from a small table (`cv2` becomes `opencv-python`,
  `PIL` becomes `pillow`); any other name is used as it is.
- **Last-chance offer to try conda (planned, not yet built; shape agreed 2026-10-11).** If a fresh
  build that ran under uv ends with your program stopping on a real error, the bootstrapper asks once,
  after the verification run and the optional interpreter re-run, with no timer: it shows the last
  line of your program's error output and offers "it actually worked", "try again with Miniconda" or
  "neither" (the default). The Miniconda choice says that your program will run one more time. The
  offer is not made on the cached-EXE fast path, after a silent timeout (normal for a window app),
  when conda is already the provider, or when the earlier dependency prompt already approved a
  cascade, and every non-interactive or CI run resolves it to "neither" without waiting. On a conda
  run reached this way, a window app that was still running when the check stopped it is asked once
  whether it opened and worked; the question says the check stops the program after about 30 seconds,
  so a window that stays open is expected. Only an explicit yes is remembered for the next run; pressing
  Enter alone, or any other answer, remembers nothing.
- **Non-interactive and CI** resolve every gate without hanging: no untimed run, and offers auto-decline.

---

## [REQ-021] Static pre-flight validation

**Goal.** The bootstrapper should report a syntax error in the user's own program early and in plain
language, so that a typo does not surface as a confusing downstream error, and should never stop a
program that is valid.

- **REQ-021.1** [major] Before it builds or runs the entry file, the bootstrapper **shall** determine
  whether the entry file's syntax is valid.
- **REQ-021.2** [major] When the entry file contains a syntax error, the bootstrapper **shall** report the
  error, in plain language, before it builds or runs anything.
- **REQ-021.3** [major] The report under REQ-021.2 **shall** state that the error is in the user's program
  and not in dependency installation or in the EXE build.
- **REQ-021.4** [critical] When the entry file's syntax is valid, the bootstrapper **shall** continue the
  run, whatever the state of the folder.
- **REQ-021.5** [minor] When the entry file's syntax is valid, the bootstrapper **shall** leave the folder
  unchanged, except for working files.
- **REQ-021.6** [major] The bootstrapper **shall** treat as a syntax error every error that the Python
  compiler of the selected interpreter reports when it compiles the entry file.

> **Notes (non-normative).**
> - Rationale: a syntax error makes the program unrunnable under the interpreter and under PyInstaller, so
>   reporting it first, in plain words, keeps a typo from surfacing as a confusing downstream error.
> - Mechanism: `:preflight_compile` runs the emitted `~preflight_check.py` on the entry file with the
>   selected interpreter. The helper compiles the source in memory, so it executes none of the user's code
>   and writes nothing. A helper that cannot decide (it could not be written, or it exited with any code but
>   0 or 1) logs a `[WARN]` and the run continues, so a broken check never stops a valid program.
> - REQ-021.4 covers a read-only `__pycache__` and a plain file named `__pycache__`. The check used to run
>   `py_compile`, which writes a `.pyc` into `__pycache__`, failed a valid program when it could not, and
>   left the `.pyc` behind when it could (CLAUDE.md Item 83); that is why REQ-021.4 and REQ-021.5 exist.
>   The same `py_compile` call also verified the bootstrapper's own `~find_entry.py` helper, so an
>   unwritable `__pycache__` stopped the run with "Could not determine entry point" before the entry
>   check was reached; that verification now uses the same in-memory helper and follows the same rule: only
>   exit 1 is a syntax error, and a check that could not run is logged and skipped.
> - REQ-021.6: the parser alone accepts some programs the compiler rejects, for example a `return`
>   statement outside a function, so a check that only parsed would let a real syntax error through to the
>   build.

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
- **Transient-failure retry**: conda environment creation, conda's bulk dependency install, the
  embedded-Python fallback tier's download and directory-swap steps, and the venv fallback
  tier's pip bootstrap (via a downloaded `get-pip.py`, used when a plain venv creation attempt
  fails outright) each retry on a detected transient failure before falling through to the next
  provider tier. Download steps retry across a primary URL and a PowerShell fallback method;
  Miniconda, uv, and get-pip.py additionally retry across a secondary URL before giving up (the
  embedded-Python download has no second host to retry against -- see CLAUDE.md's Known
  Findings for why).
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
- **This consent prompt is the sole gate on the system tier.** It is reached in the default (no-flag) run whenever uv, conda, the embedded-Python download, and venv all fail -- it is not behind an opt-in environment variable. The bootstrapper echoes the prompt string unconditionally (so it is visible even on non-interactive auto-decline), then resolves the answer; an empty/declined answer aborts the tier and keeps the current build.
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
- Tilde-prefixed files: a file the bootstrapper writes for its own bookkeeping shall start with `~`, and a file the user is meant to keep or share shall not. Tilde files are git-ignored, and deleting one shall not lose the user's work.
- `.gitattributes` additions: `*.bat -text`, `*.cmd -text`, `*.exe binary`. (`-text`, not `eol=crlf`: `eol=crlf` only affects `git checkout`, never what a raw/GitHub-served download returns -- see this repo's own CRLF distribution fix.)
- Silent if no changes needed; logs when appending.
- Log contract:
  - `[INFO] REQ-015: Appending standard ignores to .gitignore.`
  - `[INFO] REQ-015: Appending standard attributes to .gitattributes.`

---

## [REQ-016] Post-flight Briefing

- After a successful full EXE build, the bootstrapper prints a scannable summary panel identifying the output EXE, files to keep, and files safe to delete.
- The panel always includes a **RUNNING YOUR APP** section covering the two most common beginner confusions with frozen Windows executables: (1) the console window flashing closed before output is visible (run from an already-open Command Prompt to keep it open), and (2) in-place progress output appearing all at once due to stdout buffering differences between the EXE and the script.
- The panel sets realistic startup expectations: a one-file EXE can take noticeably longer to start than running the script (it self-extracts on each launch, more so when large or extra-bundled libraries are present), so a slow first appearance is not mistaken for a hang.
- The **RUNNING YOUR APP** section always shows the exact command to run the app directly via the prepared interpreter (`"<env python>" "<entry>"`) alongside the double-click instructions, regardless of whether EXE verification succeeded -- building the EXE at all already proves the interpreter works, which is what makes that command valid.
- When the packaged EXE could not be verified (its smoke run exited non-zero), the panel instead shows a **caveat** explaining that the Python environment was set up and packaging completed without a fatal error, without claiming dependency installation was itself verified (a partial/failed dependency install can still reach this point). The bootstrap still completes (the environment is usable).
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

## [REQ-019] Environment-Variable Flags Are Scaffolding, Never a Gate

**Goal.** A user should be able to get every Prime Directive outcome by double-clicking or dragging a file onto
`run_setup.bat`, with no environment variable set. The `HP_*` and `PVW_*` variables should stay
test, CI and super-user scaffolding: a flag may add diagnostic or CI behavior, give a super-user an
override, or suppress an optional step (so that absence is full behavior), but it should never be the gate for
a behavior the Prime Directive needs.

- **REQ-019.1** [critical] The bootstrapper **shall**, when the user starts `run_setup.bat` with none of the
  `HP_*`, `PVW_*` and `NOINPUT` environment variables set and nobody answers a prompt, finish the run by
  itself, with the bootstrap state `ok` for a program that runs.
- **REQ-019.2** [critical] The absence of an `HP_*` or `PVW_*` environment variable **shall not** prevent the
  bootstrapper from using a fallback provider that gets the program running.
- **REQ-019.3** [major] The bootstrapper **shall**, when none of the `HP_*`, `PVW_*` and `NOINPUT`
  environment variables is set and the folder holds a current, verified EXE, start that EXE once, without
  rebuilding it.

> **Notes (non-normative).**
> - Intended run paths are double-click and drag-and-drop with no environment variables set, so requirements
>   and tests exercise the no-flag path. This is a standing design constraint: it was previously stated only
>   in this section's prose without a requirement number, although `docs/agent-lessons-learned.md` and other
>   internal docs already cited it as a load-bearing rule (the "Env-var flags are scaffolding" principle). It
>   is distinct from `[REQ-001]`, the Prime Directive itself, which this rule protects but does not replace.
> - REQ-019.1 and REQ-019.3 are exercised by starting the bootstrapper with every such variable removed from
>   its environment and standard input closed, so the prompts that wait for an answer reach end of input; the
>   launched shell's own list of such variables is what proves none was set. A repeat run takes the
>   interactive probe of the cached EXE ("Launching your program now via the cached standalone EXE") rather
>   than the plain fast path. Every other test scenario sets `HP_CI_LANE`, which resolves these prompts and
>   the end-of-run pause differently.
> - REQ-019.2 is checked by inspection: `tests/test_flag_inventory.py` lists every test hook the batch reads,
>   and the AGENTS.md and `docs/agent-lessons-learned.md` rule is to re-read any new flag for this property.
>   The one historical breach was system Python hidden behind `HP_ALLOW_SYSTEM_FALLBACK`; it is gated by the
>   consent prompt of REQ-014 alone now.

## Advanced Environment Variables (reference)

Operational knobs, not needed for normal double-click use:

| Variable | Effect | REQ |
|----------|--------|-----|
| `HP_PVW_KNOWN_IDEMPOTENT=1` | Opt-in: run the entry live via `uvx autopep723` for execute-mode dependency discovery (uv lane only) | REQ-005.13 |
| `HP_SKIP_AUTOPEP_DISCOVERY=1` | Skip the `autopep723 check` discovery-merge augmentation of pipreqs (uv lane only) | REQ-005.12 |
| `HP_SKIP_ENTRY_SMOKE=1` | Skip the entry-script smoke test (no user code run) | REQ-012 |
| `HP_SKIP_EXE_SMOKERUN=1` | Skip running the built/cached EXE for verification | REQ-012 |
| `HP_SKIP_NIVISA=1` | Skip NI-VISA install even when pyvisa/visa is detected | REQ-008 |
| `HP_SKIP_PEP723_WRITEBACK=1` | Skip the PEP 723 header write-back (`uv add --script`) after a fresh install or warnfix repair | REQ-005.11 |
| `HP_VERBOSE_CONSOLE=1` | Opt-in: also echo `[DEBUG]`/`[TRACE]`/`[INSTALL]`-tagged lines to the live console (suppressed by default; always written to `~setup.log` either way) | -- |
| `NOINPUT=1` / `HP_NONINTERACTIVE=1` | Skip the interactive entry picker; take the alphabetical default | REQ-002 |

**This table is not exhaustive -- for awareness only.** More `HP_*` / `PVW_*` / `HP_TEST_*`
variables exist (CI-only test-injection flags such as `HP_TEST_*`, `HP_CI_*`, and
`HP_FORCE_CONDA_ONLY` are documented inline in their respective REQ sections). The authoritative
set lives in `run_setup.bat`.

---

## [REQ-020] Cache Corruption Hardening

- On startup, if a previously downloaded conda or uv binary is found, the bootstrapper validates it with a health check before use.
- Corrupt conda binary: runs `conda.bat info`; on failure, halts with a user-friendly error message and offers to self-heal (re-download Miniconda). If the user declines, exits with code 2.
- Corrupt uv binary: detected at startup by a version probe; the cached binary is evicted so the next run downloads a fresh copy. Bootstrap continues via the next available provider (conda if available, otherwise the embedded-Python download, venv, or system Python).
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

## [REQ-026] Argv Passthrough Escape Hatch

**Goal.** A user whose program needs launch arguments should be able to give them on `run_setup.bat`'s own
command line, so that the program runs as the user intends during the bootstrap without a separate launcher.
Program arguments are optional: `run_setup.bat` with no arguments, and `run_setup.bat myapp.py` with no
further arguments, work as before.

- **REQ-026.1** [major] When the user gives arguments after the entry file, the bootstrapper **shall** pass
  them to the user's program, in order and with an argument that contains spaces kept as one argument, when
  it runs the program through the EXE it just built.
- **REQ-026.2** [major] When the user gives arguments after the entry file, the bootstrapper **shall** pass
  them to the user's program, in the same way, when it reuses a cached EXE.
- **REQ-026.3** [major] When the user gives arguments after the entry file, the bootstrapper **shall** pass
  them to the user's program, in the same way, when it runs the program through the interpreter because no
  EXE was built.
- **REQ-026.4** [major] When the user has given arguments after the entry file, the bootstrapper **shall**
  pass the same arguments to the post-execution checkpoint's second run, if the user accepts that run.
- **REQ-026.5** [minor] The bootstrapper **shall** pass at most eight arguments after the entry file, drop an
  argument that is empty, and ignore every argument after the ninth position on its command line.
- **REQ-026.6** [minor] When the user gives no arguments after the entry file, the bootstrapper **shall**
  start the program without arguments.

> **Notes (non-normative).**
> - Usage: `run_setup.bat myapp.py --input file.csv`. It works whether the entry file was typed, dragged
>   onto a shortcut with arguments added to its Target field, or given in any other manual invocation. A
>   plain drag-and-drop of one file passes only that file (Windows Explorer's behavior, not something this
>   bootstrapper controls).
> - Positions 2 through 9 are forwarded. CMD batch files address `%2` to `%9` directly, and going further
>   would need `shift`, which is deliberately not used because it would also shift `%~1`, the entry-file
>   argument that other parts of the file read directly. A program that needs more than eight launch
>   arguments is not covered by this escape hatch yet.
> - No detection or heuristics are involved; this is a documented, opt-in escape hatch, not automatic
>   argument discovery (see `docs/plan-cli-interactive-verification.md` Findings 4 and 5).
> - The forwarding does not persist: it applies only during the bootstrap run that received the arguments
>   and does not change how a later double-click of `dist\<env>.exe` launches the program (double-clicking
>   never passes arguments). To launch the built EXE with the same arguments afterward, make a Windows
>   shortcut and add them to its Target field, or launch it from a Command Prompt.
> - A token that contains a literal `"` is not supported: each argument is individually re-quoted so that
>   spaces survive as one argument, but an embedded double quote is a documented limitation.
> - The elective optimized-build's own verification launch also receives the arguments, because it starts a
>   binary that has never run and a program that needs arguments would otherwise fail the check. The
>   `--hidden-import` auto-recovery re-run does not: it is a diagnostic re-run of a build already confirmed
>   working (see `docs/agent-interconnect.md`).
> - The first argument is checked before the cached-EXE fast path runs. It must be an existing `.py` file in
>   the bootstrapper folder, as typed or with `.py` appended; otherwise the run stops with a usage message and
>   the existing EXE is left alone (REQ-002, REQ-011, CLAUDE.md Item 67). Before this check,
>   `run_setup.bat arg1 arg2` with the entry file forgotten launched the existing EXE with `arg2`, and when
>   the program rejected it, the fast path deleted a working EXE. A typed entry file now behaves the same
>   whether or not an EXE exists yet: `run_setup.bat myapp.py arg1 arg2`.

---

## [REQ-027] Honest Ambiguous-Exit Messaging

- When a verification run ends ambiguously (your program exited with an error, and neither
  automatic repair -- `--hidden-import` auto-recovery, the dependency-resolution cascade -- fixed
  it), the bootstrapper no longer claims success it can't actually confirm:
  - **No-EXE path**: if packaging failed outright (both PyInstaller and the Nuitka fallback) AND
    the interpreter fallback that then ran your program also exited non-zero, the post-flight
    panel says so plainly instead of claiming "your code ran successfully."
  - **Cached-EXE fast path**: if a reused `dist\<env>.exe` was classified alive/healthy by the
    fail-fast probe (so it was kept, not rebuilt) and it later exited non-zero, a short
    informational panel now appears -- previously this case had no signal beyond one log line.
- Neither message claims to know *why* the run was ambiguous (a bug in your own code vs.
  something this bootstrapper missed) -- both point you at running the program yourself to see
  the full output, and the fast-path note additionally suggests deleting `dist\<env>.exe` and
  re-running the bootstrapper if you want a fully fresh dependency check.
- This is messaging only -- it does not change `~bootstrap.status.json` semantics, the process
  exit code, or add any new consent prompt (the cached-EXE note is a plain print, preserving the
  fast path's zero-friction design).

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

**Payload inventory and PayloadSync coverage** (added so this is visible at a glance, instead of
needing to grep the batch file or a research pass to find out; re-audited 2026-07-25 against the
file's actual current contents rather than trusting the previous count, which had drifted --
`HP_EXE_SMOKERUN` and `HP_PEP723_WRITEBACK` had gained canonical sources without this paragraph
ever being updated). Of the 21 embedded `HP_*` payloads, 18 have a canonical `tools/` source file
*and* a dedicated `PayloadSync` unit test that asserts the embedded base64 is byte-for-byte in
sync with that source (`HP_AUTOPEP_MERGE` -> `tools/autopep_merge.py`, `HP_COLLECT_SUBMODULES` ->
`tools/collect_submodules.py`, `HP_DEP_CHECK` -> `tools/dep_check.py`, `HP_DETECT_PY` ->
`tools/detect_python.py`, `HP_DETECT_VISA` -> `tools/detect_visa.py`, `HP_EMBED_EXTRACT` ->
`tools/embed_extract.ps1`, `HP_EMBED_PYVER_CHECK` -> `tools/embed_pyver_check.py`, `HP_ENV_STATE`
-> `tools/env_state.py`, `HP_EXE_SMOKERUN` -> `tools/exe_smokerun.ps1`, `HP_FAILFAST_PROBE` ->
`tools/failfast_probe.ps1`, `HP_FIND_ENTRY` -> `tools/find_entry.py`, `HP_HIDDEN_IMPORT_SCAN` ->
`tools/hidden_import_scan.py`, `HP_INSTALLER_TIMEOUT` -> `tools/run_installer_with_timeout.ps1`,
`HP_PARSE_WARN` -> `tools/parse_warn.py`, `HP_PEP723_WRITEBACK` -> `tools/pep723_writeback.py`,
`HP_PREP_REQUIREMENTS` -> `tools/prep_requirements.py`, `HP_PVW_IDEMPOTENT` ->
`tools/pvw_known_idempotent.py`, `HP_PYPROJ_DEPS` -> `tools/pyproj_deps.py`; each is exercised by
the matching `tests/test_*.py` file). `HP_PREP_REQUIREMENTS` is a deliberate partial case: its
canonical source is a byte-for-byte decode of the currently embedded payload with NO header
comment added (unlike the other 17), since this payload's CMD 8191-char line budget is the
tightest in the whole file (304-char margin) -- even a minimal "canonical source" pointer would
cost more margin than is safely available; see the `PayloadSync` test in
`tests/test_heuristics.py` for the full reasoning. The remaining 3 (`HP_CONDARC`, `HP_FAST_CHECK`,
`HP_PRINT_PYVER`) are embedded-only, with no separate canonical source to sync against --
`HP_CONDARC` is static config text, not code, so this doesn't apply to it; `HP_FAST_CHECK` at
least has its *logic* covered by `tests/test_fast_check_pattern.py` (extracted and tested in
place, just not against a separate source file). `HP_PRINT_PYVER` is a trivial one-liner
(`print(f"python-{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}")`) with no
branching logic to test. Any *new* embedded payload should default to the
canonical-source-plus-`PayloadSync` pattern from the start rather than adding a 4th embedded-only
exception.

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

## Why "Build-First, Run-Once"? (Design Rationale)

REQ-018 above states the rule -- the bootstrapper runs the user's code purposefully and at most once per invocation. This section explains why, since the alternative (a faster, iterative "just run it and fix errors as they come up" loop) is a real, commonly-used pattern elsewhere and deserves an honest comparison rather than an assumed answer.

There are two broad ways a tool like this could resolve missing dependencies:

- **Build-first, run-once (this tool's approach):** discover dependencies statically (pipreqs, PEP 723, `requirements.txt`), install them, build and verify once, then offer to run for real. Slower to the first successful run, but the user's code never executes more than once per invocation.
- **Fail-fast, run-early (the alternative):** run the script immediately; when it crashes on a missing import, install that package and rerun from the top; repeat until it succeeds. Near-instant feedback, but every rerun re-executes everything the script already did before the point of failure.

The second approach is genuinely how most professional developers iterate locally, and for a stateless, read-only script it's strictly better -- faster, and just as correct. The problem is this tool's actual target audience: a beginner who was handed a `.py` file has no way to know, and no way to verify, whether their script is stateless. A script that renames files, appends a row to a shared spreadsheet, sends an email, hits a paid API, or talks to lab hardware is not a hypothetical for this audience -- it's a common case. If that script writes a row on line 10 and crashes on a missing import on line 50, "run it early and often" means line 10 executes once for every missing package discovered, silently, with no undo. This is the same hazard idempotency-key designs in production APIs exist to prevent (see, for example, [Stripe's idempotent-request documentation](https://docs.stripe.com/api/idempotent_requests) for a well-known treatment of why retrying a non-idempotent operation is dangerous by default) -- it's a general software-engineering hazard, not one specific to this tool.

|  | Build-first, run-once | Fail-fast, run-early |
|---|---|---|
| First-run latency | Slower (static discovery + build) | Fast (immediate feedback) |
| Side-effect safety | Safe -- broken code never runs | Dangerous -- reruns side effects up to the crash point every retry |
| Handling dynamic/runtime-only imports | Needs a repair loop (warnfix) since static analysis can miss them | Catches them naturally, since the code actually ran |
| Right choice for | Unknown, possibly-non-idempotent code (this tool's actual audience) | Known-stateless scripts, or a developer who already knows their own code |

Given that this tool cannot know in advance whether a given script is safe to rerun, and its whole purpose is serving people who can't answer that question themselves, defaulting to the safe option is the correct call, not merely a cautious one -- a beginner who loses data or double-sends an email because a dependency-discovery loop re-ran their script is a much worse outcome than a slower first run. This is also why the warnfix repair loop (REQ-005.9/REQ-005.10) targets *build-time* signals (the PyInstaller warn file, which is produced by static analysis, not by executing the script) rather than a live run-and-catch loop -- it gets most of the benefit of "catch what static discovery missed" without ever executing unverified code more than the one, deliberately time-boxed and announced time REQ-018 allows.

None of this rules out a faster path for a user who genuinely knows their own script is side-effect-free -- see `docs/prd-av-safe-build-path.md`'s "Notes from Claude" section and the corresponding `CLAUDE.md` Active Backlog entry for a specific, opt-in (never default) design being considered for exactly that case, gated behind an explicit flag rather than silently changing this tool's default behavior for everyone.

---

## Python_vs_Windows and the "Deno for Python" Question

People occasionally ask whether anything plays the role for Python that [Deno](https://deno.com/) -- a zero-config, single-binary JavaScript/TypeScript runtime built by one of Node's original creators -- plays for JavaScript: no install rituals, no dependency-hell, just run the file. That question isn't hypothetical -- it's been asked directly, by name, on [Hacker News](https://news.ycombinator.com/item?id=35379227): *"Are there any efforts akin to deno for python?"* Python_vs_Windows doesn't reimplement the Python runtime the way Deno reimplemented JavaScript's, but on Windows, for the specific problem of "I was handed a `.py` file and nothing else," it answers the same question in spirit.

The repository's Prime Directive: on a clean Windows 10+ machine with only a `.py` file, double-click a batch file, and it bootstraps an isolated runtime environment, installs every required dependency, and runs the script -- no manual configuration.

Here's how that maps to Deno's actual design, point by point:

**1. Zero-config, single-command execution**
Deno: `deno run script.ts` downloads missing modules and executes, no setup step.
This repo: double-click `run_setup.bat`. It scans the script, builds an isolated environment, installs what's missing, and runs it.

**2. Rust-powered speed, with real fallbacks underneath**
Deno is built in Rust end to end. This repo uses [uv](https://github.com/astral-sh/uv) -- Astral's Rust-based Python toolchain -- as its preferred, fastest environment provider. Underneath that, it doesn't depend on any single mechanism working: if uv isn't available, it cascades through several independent fallback tiers -- Conda/Miniconda, a checksum-verified embedded Python download straight from python.org, a local `venv`, and, as a last resort with explicit user consent, an unmanaged system Python. No single one of these being blocked or missing takes the whole tool down with it.

**3. Automatic dependency discovery**
Deno parses import URLs directly from the source file. This repo resolves dependencies in priority order: PEP 723 inline script metadata, then `pyproject.toml`, then `requirements.txt`, and only if none of those exist, a best-effort static-analysis scan (`pipreqs`) to infer what the script imports.

**4. Compiling to a standalone executable**
`deno compile` packages a script into a single distributable binary. This repo does the same in spirit: after setup succeeds, it bundles the app and its environment into a single-file Windows EXE via PyInstaller, so it can be handed to someone else without asking them to set anything up.

**5. Controlled execution, not sandboxing**
Deno enforces permissions by default (`--allow-net`, `--allow-read`, etc.). Python has no native equivalent, so this repo takes a different, deliberate precaution instead: it treats every run of the user's code as potentially non-idempotent -- a script can overwrite files, send an email, mutate a database, or actuate connected hardware -- so it runs that code purposefully and at most once per invocation automatically. A fresh build gets a single, time-boxed verification run; a real run is then offered, not forced; and anything beyond that single automatic run requires explicit consent that names the risk. Session isolation backs this up structurally too -- `PYTHONPATH` and `PYTHONHOME` are cleared on every run so the host system can't leak unrelated packages into the bootstrapped environment.

The gap between the two projects is real -- Deno is a from-scratch runtime; this is a batch file orchestrating existing Python tooling. But for the narrow, common case this repo targets -- a non-technical user on Windows with someone else's script and nothing else -- it's the same promise: point it at the file, get a working run, no ceremony.

---

## PVW QuickStart (Super-User Fast Path)

The rest of this README is about `run_setup.bat`: build-first, run-once, an EXE at the end, safe
by default for code you don't know is idempotent. If that's not you -- your script is
self-contained, you already trust it, and you just want it running in a terminal right now with
no EXE and no conda -- this is the "known-stateless scripts, or a developer who already knows
their own code" column from the comparison above, and there's a faster path for it: `uv` plus
[`autopep723`](https://github.com/mgaitan/autopep723), a tool that statically scans a script's
imports and either runs it in a throwaway environment or writes what it found into the file's own
PEP 723 header.

Every command below was tested directly against real `uv`/`autopep723` runs (not just read in
docs) before being written here, including every failure-handling path (a genuinely broken
header, a header that's merely incomplete, and a non-ASCII byte in the file) -- see
`docs/plan-pvw-quickstart.md` for the full verification trail if you want it. The one part that
could not be tested in that pass is real Windows PowerShell 5.1 specifically (verified via `pwsh`
7 instead, which shares the same `.NET` APIs these commands rely on) -- if you hit something odd
on an older PowerShell, that's the first place to look.

### Just run it (and remember what it needed)

Open PowerShell in the folder with your script (Shift+right-click -> "Open PowerShell window
here"), then paste:

```powershell
irm https://astral.sh/uv/install.ps1 | iex; $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"; $enc = [System.Text.Encoding]::GetEncoding("ISO-8859-1"); $f = "solve_my_probs.py"; $original = [System.IO.File]::ReadAllText((Get-Item $f).FullName, $enc); function Persist($f) { $chk = (uvx autopep723 check $f) -join "`n"; if ($LASTEXITCODE -ne 0) { return $false }; $names = [regex]::Matches($chk, '^#\s*"([^"]+)",?\s*$', 'Multiline') | ForEach-Object { $_.Groups[1].Value }; if ($names.Count -eq 0) { return $true }; uv add --script $f $names; return ($LASTEXITCODE -eq 0) }; uvx autopep723 $f; $rc = $LASTEXITCODE; if ($rc -eq 0) { if (Persist $f) { Write-Host "Ran successfully and remembered what it needed." } else { Write-Host "Ran successfully, but could not update the dependency header - nothing was changed there." } } elseif ($rc -eq 2) { Write-Host "Header is malformed - retrying with a clean version..."; [System.IO.File]::WriteAllText("$((Get-Item $f).FullName).bak", $original, $enc); $c = $original -replace "(?ms)^# /// script\r?\n.*?^# ///[ \t]*\r?\n?", ""; [System.IO.File]::WriteAllText((Get-Item $f).FullName, $c, $enc); uvx autopep723 $f; if ($LASTEXITCODE -eq 0) { if (Persist $f) { Write-Host "Ran successfully after repair and remembered a fresh header." } else { Write-Host "Ran successfully after repair, but could not update the header." } } else { Write-Host "Retry also failed - restoring your original file untouched."; [System.IO.File]::WriteAllText((Get-Item $f).FullName, $original, $enc) }; Remove-Item -ErrorAction SilentlyContinue "$f.bak" } else { Write-Host "Run failed with an existing header in place - trying to fill in any missing dependencies..."; Persist $f | Out-Null; uvx autopep723 $f; if ($LASTEXITCODE -eq 0) { Write-Host "Ran successfully after filling in missing dependencies." } else { Write-Host "Run still failed - this looks like a script-level issue, not a dependency gap, so nothing further was attempted." } }
```

Change `solve_my_probs.py` to your file's name and run again if you're pasting this more than
once. What it does: installs `uv`, runs your script via a throwaway environment, and -- once the
run actually succeeds -- remembers what it needed by writing (or updating) the file's own PEP 723
header, the same **additive-merge, never-delete** approach `run_setup.bat` itself uses for
`runtime.txt`/`requirements.txt`: an existing exact pin (`flask>=2.0`) or hand-added TOML key is
never touched, only genuinely new dependencies get added.

It only ever resets the header from scratch in one specific situation, and it's not "the run
failed" in general: it's when the header itself is unparseable TOML (a real syntax error, not
just an incomplete list) -- that's the one case where "keep what's there" genuinely isn't
possible, so it backs up, replaces, and retries clean. Any *other* kind of failure -- most
commonly a valid header that's just missing a recently-added import -- is treated as "add what's
missing," never "start over." Concretely, it branches on *why* the first attempt failed, not just
whether it failed:

- **Ran clean:** best-effort remembers what it needed, now that the run has actually confirmed it
  works.
- **Header is genuinely malformed:** the one case where starting over is correct -- backs up,
  strips the broken header, retries clean, and remembers a fresh header if the retry succeeds.
- **Ran but failed for some other reason** (most often a valid header just missing an import):
  fills in what's missing *without* touching anything else already in the header, then retries
  once.

If you ever see a `<yourfile>.bak` file sitting next to your script afterward, that's the
safety-net copy made right before the one destructive step above (a genuinely malformed header) --
it means something interrupted the run before cleanup could finish (a closed terminal, a lost
connection); rename it back over the current file to get back to exactly where you started. It's
never created for the other two outcomes, since neither one ever removes anything from the file to
begin with.

**One thing to know if you rename the file later:** `uv` has an open caching issue
([astral-sh/uv#15156](https://github.com/astral-sh/uv/issues/15156)) where running the same
filename with a different dependency set can occasionally serve a stale cached resolution --
relevant here because this command's whole point is to leave behind a header a later, independent
`uv run` will pick up. If a promoted file behaves oddly after you've changed its imports, renaming
the file or clearing `~/.cache/uv` resolves it; it's a known upstream quirk, not something wrong
with your file.

It reads and writes the file byte-for-byte (not through a UTF-8-only text conversion), so a file
saved in an older encoding is never silently corrupted along the way -- an unreadable file safely
falls into the "some other reason" branch above and is left untouched, exactly like any other
non-dependency failure.

**Fine print:** in the "ran but failed for some other reason" branch, if the retry (after filling
in what looked missing) *also* fails -- for instance the script has a real bug unrelated to any
dependency -- that fill-in is not rolled back. This is deliberate, not an oversight: `uv add
--script`'s writes are already confirmed atomic (never partial), so the header at worst ends up
*more* correct (whatever was genuinely missing really was needed) even though the script itself
still needs a real fix -- never silently wrong data, just not undone.

The same thing, spaced out if you'd rather read it before pasting:

```powershell
irm https://astral.sh/uv/install.ps1 | iex
$env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
$enc = [System.Text.Encoding]::GetEncoding("ISO-8859-1")
$f = "solve_my_probs.py"
$original = [System.IO.File]::ReadAllText((Get-Item $f).FullName, $enc)

function Persist($f) {
    $chk = (uvx autopep723 check $f) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $false }
    $names = [regex]::Matches($chk, '^#\s*"([^"]+)",?\s*$', 'Multiline') | ForEach-Object { $_.Groups[1].Value }
    if ($names.Count -eq 0) { return $true }
    uv add --script $f $names
    return ($LASTEXITCODE -eq 0)
}

uvx autopep723 $f
$rc = $LASTEXITCODE

if ($rc -eq 0) {
    if (Persist $f) {
        Write-Host "Ran successfully and remembered what it needed."
    } else {
        Write-Host "Ran successfully, but could not update the dependency header - nothing was changed there."
    }
} elseif ($rc -eq 2) {
    Write-Host "Header is malformed - retrying with a clean version..."
    [System.IO.File]::WriteAllText("$((Get-Item $f).FullName).bak", $original, $enc)
    $c = $original -replace "(?ms)^# /// script\r?\n.*?^# ///[ \t]*\r?\n?", ""
    [System.IO.File]::WriteAllText((Get-Item $f).FullName, $c, $enc)
    uvx autopep723 $f
    if ($LASTEXITCODE -eq 0) {
        if (Persist $f) {
            Write-Host "Ran successfully after repair and remembered a fresh header."
        } else {
            Write-Host "Ran successfully after repair, but could not update the header."
        }
    } else {
        Write-Host "Retry also failed - restoring your original file untouched."
        [System.IO.File]::WriteAllText((Get-Item $f).FullName, $original, $enc)
    }
    Remove-Item -ErrorAction SilentlyContinue "$f.bak"
} else {
    Write-Host "Run failed with an existing header in place - trying to fill in any missing dependencies..."
    Persist $f | Out-Null
    uvx autopep723 $f
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Ran successfully after filling in missing dependencies."
    } else {
        Write-Host "Run still failed - this looks like a script-level issue, not a dependency gap, so nothing further was attempted."
    }
}
```

### Check what it would install, without running or changing anything

Purely read-only -- prints a freshly-scanned dependency block to the screen for you to eyeball,
changes nothing:

```powershell
uvx autopep723 check solve_my_probs.py
```

### Make it remember, without actually running it

The command above already remembers what it needed once it confirms the run works. Use this one
instead if you want to update the header *without* executing the script at all -- for example,
to check dependencies into the file for someone else before you're ready to run it yourself, or
to prep a file for `run_setup.bat` ahead of time. Same additive-merge guarantee: it keeps any
exact version pin (`flask>=2.0`) or hand-added TOML key you already have, adding only genuinely
new dependencies -- paste this instead:

```powershell
$f = "solve_my_probs.py"; $chk = (uvx autopep723 check $f) -join "`n"; if ($LASTEXITCODE -eq 0) { $names = [regex]::Matches($chk, '^#\s*"([^"]+)",?\s*$', 'Multiline') | ForEach-Object { $_.Groups[1].Value }; if ($names.Count -gt 0) { uv add --script $f $names } else { Write-Host "No dependencies detected (or the file could not be fully analyzed)." } } else { Write-Host "Could not analyze script - nothing changed." }
```

The same thing, spaced out:

```powershell
$f = "solve_my_probs.py"
$chk = (uvx autopep723 check $f) -join "`n"
if ($LASTEXITCODE -eq 0) {
    $names = [regex]::Matches($chk, '^#\s*"([^"]+)",?\s*$', 'Multiline') | ForEach-Object { $_.Groups[1].Value }
    if ($names.Count -gt 0) {
        uv add --script $f $names
    } else {
        Write-Host "No dependencies detected (or the file could not be fully analyzed)."
    }
} else {
    Write-Host "Could not analyze script - nothing changed."
}
```

This uses `autopep723 check`'s read-only scan for discovery, then hands the result to `uv add
--script` for the actual write -- `uv` already refuses to downgrade an existing pin when you
re-add a package by its bare name (verified directly: re-adding `flask` when `flask>=2.0` was
already pinned left the file byte-for-byte unchanged), so no separate merge logic is needed here.
A genuinely new dependency gets added too, though exactly how depends on your `uv` version --
current `uv` tends to write an auto-resolved lower bound (`requests>=2.34.2`) rather than a bare
name; treat whatever `uv` writes as correct by construction rather than expecting one specific
form. Safe to run more than once -- confirmed idempotent on repeat runs, across `uv` versions. If
it fails because your file's *existing* header is malformed rather than missing, run the command
above first (it repairs a broken header), then try this one again.

**Worth knowing if you use this regularly:** if a `<yourfile>.py.lock` file already exists next to
your script (from separate `uv` usage), `uv add --script` will silently rewrite it as a side
effect of adding a dependency -- expected `uv` behavior, not a bug in this command, but worth
knowing if you maintain that lockfile by hand. The same caching quirk noted above (renaming a file
after changing its imports can serve a stale cached resolution -- astral-sh/uv#15156) applies here
too, for the same reason: this command exists specifically to leave behind a header a later `uv
run` will pick up.

**Fine print:** this whole section is for a script you already trust, or one you're consciously
iterating on and accept re-running. If you were handed a `.py` file and don't know whether it's
safe to run more than once, use `run_setup.bat` instead -- see "Why 'Build-First, Run-Once'?"
above for why that distinction matters here specifically, not just as a generic caveat.

---

## Known Limitations

- **Implicit/plugin dependencies**: Dependencies that are not detected via static import analysis (for example, `pandas` needing `openpyxl` for `read_excel`) will surface as `ImportError` at runtime. See [Dependency strategy](#dependency-strategy) for detail.
- **`requirements.txt` is input only**: The resolved conda environment may differ from the original author's intent. This is intentional -- getting the code to run takes priority over preserving outdated constraints.
- **Windows only**: There is no macOS or Linux support.
- **Self-modifying programs can get a stale cached EXE**: the cached `dist\<env>.exe` is reused only while your `.py` files (and `requirements.txt`/`pyproject.toml`/`runtime.txt`) match the hash recorded after the last build. That hash is recorded at the end of the build run, after the verification run of your program. A program that rewrites one of its own `.py` files when it runs (for example, bumping a version string in a sibling module) therefore gets the rewritten source recorded, so the next run can reuse an EXE built from the source as it was before the rewrite. Later runs may alternate between reusing and rebuilding. This is accepted; deleting `dist\<env>.exe` forces a fresh build.
- **NI-VISA may require admin rights**: The NI-VISA optional install may require an elevated shell on machines where non-admin installs are blocked by policy.

---

## Contributing

See `CONTRIBUTING.md`. PRs are welcome. Keep CI green.

## Security

See `SECURITY.md`. Do not include secrets in issues or PRs.

## License

MIT -- see `LICENSE`.
