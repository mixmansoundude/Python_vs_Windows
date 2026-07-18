:: run_setup.bat -- Python vs Windows
:: Project Home: https://github.com/mixmansoundude/Python_vs_Windows
:: Description: Automated, zero-config Python environment management for Windows. Standalone and portable.
:: [VERSION_METADATA]
:: Last Verified Date: 2026-06-19
:: Verified Windows: Windows 10/11 (CI runner: Windows Server 2025)
:: Verified PowerShell: 5.1+
:: Verified Python: 3.14.6 (CI Latest)
:: NOTE: Update 'Last Verified Date' only when 'Verified Python' version changes
::   or this entry is more than 6 months stale. Do NOT update the date on every commit.
:: RECOVERY: If a future Python version breaks auto-detection, install a Python version matching the
::   'Last Verified' metadata above, then run 'set PVW_PYTHON_EXE=C:\path\to\python.exe' in your
::   terminal before running this script to bypass the broken detection.
:: ============================================================
:: FIRST-TIME WINDOWS USERS: SmartScreen / Security Warning
:: ============================================================
:: When you double-click this file, Windows may show:
::   "Windows protected your PC"
:: This is normal for any .bat file downloaded from the internet.
::
:: TO RUN:  Click "More info"  then  "Run anyway"
::
:: IF "Run anyway" is not shown:
::   1. Close this dialog
::   2. Right-click run_setup.bat in File Explorer
::   3. Click "Properties"
::   4. At the bottom, check the "Unblock" checkbox
::   5. Click "OK"
::   6. Double-click run_setup.bat again
:: ============================================================
@echo off
setlocal DisableDelayedExpansion
set "DEP_SOURCE=unknown"
rem Boot strap renamed to run_setup.bat
set "HP_SCRIPT_LAUNCH_DIR=%~dp0"
echo %~dp0 | findstr /C:"\\\\" >nul
if not errorlevel 1 echo [WARN] UNC paths not supported
if "%HP_SCRIPT_LAUNCH_DIR:~0,2%"=="\\" (
  rem derived requirement: parentheses must be escaped inside IF (...) blocks in CMD or parsing breaks.
  echo *** WARNING: UNC/network paths detected ^(\\server\share^).
  echo *** This script may fail in this environment.
  echo *** Recommended: Map the network path to a drive letter and re-run.
  echo ***
)
if not exist "%~dp0" (
  echo [ERROR] Workspace path invalid: %~dp0
  exit /b 1
)
cd /d "%~dp0"
if errorlevel 1 (
  echo [ERROR] Workspace path invalid: %~dp0
  exit /b 1
)
set "HP_SCRIPT_ROOT=%~dp0"
for %%R in ("%HP_SCRIPT_ROOT%") do set "HP_SCRIPT_ROOT=%%~fR"
if not "%HP_SCRIPT_ROOT:~-1%"=="\\" set "HP_SCRIPT_ROOT=%HP_SCRIPT_ROOT%\"
set "HP_CI_MARKER=.ci_bootstrap_marker"
type nul > "%HP_CI_MARKER%" 2>nul
set "LOG=~setup.log"
set "LOGPREV=~setup.prev.log"
set "STATUS_FILE=~bootstrap.status.json"
if not exist "%LOG%" (type nul > "%LOG%")
call :merge_git_config
if "%HP_TEST_FORCE_CONNECTIVITY_CHECK%"=="1" call :check_net_after_dl_fail
if "%HP_TEST_FORCE_CONSENT_CHECK%"=="1" (
  call :system_python_consent_gate
  if errorlevel 1 (
    call :log "[INFO] REQ-014: Consent gate test: user declined."
    exit /b 1
  )
  call :log "[INFO] REQ-014: Consent gate test: user accepted."
)
rem --- PVW_ super-user overrides (inherit from calling terminal; logged before detection runs) ---
rem derived requirement: PVW_ variables let a super-user pre-set values to bypass auto-detection.
rem Single-line if form avoids parse-time expansion issues in block-form if-statements when a
rem variable value contains parentheses, such as a path under "C:\Program Files (x86)\...".
if defined PVW_PYTHON_EXE call :log "[DEBUG] Using super-user override for PVW_PYTHON_EXE: %PVW_PYTHON_EXE%"
if defined PVW_UV_EXE call :log "[DEBUG] Using super-user override for PVW_UV_EXE: %PVW_UV_EXE%"
if defined PVW_CONDA_EXE call :log "[DEBUG] Using super-user override for PVW_CONDA_EXE: %PVW_CONDA_EXE%"
if defined PVW_TARGET_PY call :log "[DEBUG] Using super-user override for PVW_TARGET_PY: %PVW_TARGET_PY%"
if defined PVW_WORKSPACE call :log "[DEBUG] Using super-user override for PVW_WORKSPACE: %PVW_WORKSPACE%"
rem --- Path-length guard: warn if script root path approaches the 260-char cmd.exe limit ---
for /f "usebackq delims=" %%L in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:HP_SCRIPT_ROOT.Length" 2^>nul`) do set "HP_PATH_LEN=%%L"
if defined HP_PATH_LEN if %HP_PATH_LEN% GEQ 200 (
  echo *** WARNING: Script path is %HP_PATH_LEN% chars. Paths near 260 chars may cause cmd.exe failures.
  call :log "[WARN] Script path is %HP_PATH_LEN% chars; paths near 260 chars may cause failures."
)
set "HP_PATH_LEN="
rem --- Synced-folder guard: warn when running from a OneDrive or similar sync folder ---
if /I not "%HP_SCRIPT_ROOT:OneDrive=%"=="%HP_SCRIPT_ROOT%" (
  echo *** WARNING: Script appears to be in a OneDrive folder. File locking may cause failures.
  call :log "[WARN] OneDrive path detected; file locking may cause failures."
)
rem --- System-directory guard: check-and-abort (not warn-only) if the script root is under a
rem Windows system folder. Unlike the OneDrive/path-length/disk-space guards above (marginal
rem conditions that MIGHT cause a failure), a user occasionally drops this script into
rem %WINDIR%/%PROGRAMFILES% thinking it "installs" there -- without elevation this will
rem essentially always fail on write-permission errors several steps in (creating ~setup.log,
rem ~uv_bin, .uv_env, etc. right next to itself), so a clear early abort is kinder than a
rem cryptic failure deep in the bootstrap. findstr substring match mirrors the UNC-path check
rem at the top of this file; HP_SCRIPT_ROOT always has a trailing backslash (see above), so a
rem trailing backslash on the search pattern prevents a same-prefix false match (e.g.
rem "C:\WindowsFooBar\" does not contain the substring "C:\Windows\").
set "HP_SYSDIR_HIT="
set "HP_PF86=%ProgramFiles(x86)%"
rem derived requirement: the search pattern ends in "\\" (two backslashes), not "\" -- a
rem SINGLE backslash immediately before the closing quote is a classic Windows argv-parsing
rem trap: findstr.exe (like most native console apps) follows the standard C-runtime rule
rem that an ODD number of backslashes right before a closing quote escapes the quote instead
rem of closing the string, silently corrupting the whole /C: argument (and swallowing the
rem trailing ">nul" into the search pattern) so the match can never succeed. An EVEN count
rem (here, two) collapses to a single literal backslash and the quote closes normally.
if defined WINDIR (
  echo %HP_SCRIPT_ROOT%| findstr /I /C:"%WINDIR%\\" >nul
  if not errorlevel 1 set "HP_SYSDIR_HIT=1"
)
if defined ProgramFiles (
  echo %HP_SCRIPT_ROOT%| findstr /I /C:"%ProgramFiles%\\" >nul
  if not errorlevel 1 set "HP_SYSDIR_HIT=1"
)
if defined HP_PF86 (
  echo %HP_SCRIPT_ROOT%| findstr /I /C:"%HP_PF86%\\" >nul
  if not errorlevel 1 set "HP_SYSDIR_HIT=1"
)
set "HP_PF86="
if defined HP_SYSDIR_HIT (
  echo *** ERROR: This script is located inside a Windows system folder.
  echo *** Placing it here does not "install" it. Windows restricts writes to this location
  echo *** without administrator rights, and this bootstrapper needs to create files right
  echo *** next to itself to work.
  echo *** Please move this script ^(and your .py files^) to a normal folder -- your Desktop
  echo *** or Documents folder both work well -- then run it again from there.
  call :log "[ERROR] System-directory guard: script root is under a Windows system folder; aborting."
  exit /b 1
)
set "HP_SYSDIR_HIT="
rem --- Free-disk-space guard: warn (never abort) if the script's drive looks low on space ---
rem derived requirement: Miniconda download/install plus conda env creation can together need
rem several hundred MB to a few GB; a low-disk-space beginner machine would otherwise see whatever
rem low-level error curl/conda/pip happens to surface for "no space left on device" deep inside the
rem bootstrap, instead of a clear, early, plain-language message. Threshold is deliberately generous
rem (2 GB) and this only warns -- per REQ-001 (env-var flags are scaffolding, never a Prime-Directive
rem gate), a low reading must never hard-block the run: the user may still have just enough, or may
rem free space and retry after seeing the warning.
set "HP_FREE_GB="
if defined HP_TEST_FORCE_LOW_DISK (
  set "HP_FREE_GB=0"
) else (
  for /f "usebackq delims=" %%D in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $letter = ([System.IO.Path]::GetPathRoot($env:HP_SCRIPT_ROOT)).Substring(0,1); [math]::Floor((Get-PSDrive -Name $letter).Free / 1GB) } catch { '' }" 2^>nul`) do set "HP_FREE_GB=%%D"
)
if defined HP_FREE_GB if %HP_FREE_GB% LSS 2 (
  echo *** WARNING: Only ~%HP_FREE_GB% GB free disk space detected on this drive.
  echo *** Downloading Python/Miniconda and building your app can need several GB.
  echo *** If setup fails partway through, freeing up disk space is a likely fix.
  call :log "[WARN] REQ-025: low disk space detected (~%HP_FREE_GB% GB free); continuing (warn-only)."
)
set "HP_FREE_GB="
if exist "%STATUS_FILE%" del "%STATUS_FILE%"
rem REQ-024: concurrent-instance protection -- must run before any real bootstrap work
rem (env creation, downloads, EXE fast path) so two double-clicks in this folder cannot race.
call :acquire_lock
if errorlevel 1 exit /b 1
set "HP_BOOTSTRAP_STATE=ok"
rem REQ-010: nullify host-system Python path variables to prevent library interference
set "PYTHONPATH="
set "PYTHONHOME="
set "HP_ENV_MODE=conda"
set "HP_ENV_READY="
set "HP_SKIP_PIPREQS=%HP_SKIP_PIPREQS%"
set "HP_PY="
set "HP_UV_PROVIDING_PYTHON="
set "HP_FIND_ENTRY_SYNTAX_OK="
set "HP_HELPER_SYNTAX_EMITTED="
set "HP_HELPER_CMD_LOGGED="
set "HP_FIND_ENTRY_NAME=~find_entry.py"
set "HP_FIND_ENTRY_ABS="
set "HP_PIPREQS_VERSION=%HP_PIPREQS_VERSION%"
rem derived requirement: pin pipreqs to 0.4.13, NOT 0.5.0. pipreqs 0.5.0 added Jupyter
rem notebook scanning, which hard-pins ipython==8.12.3 (the last ipython supporting Python
rem 3.8). ipython 8.12.3 does not support Python 3.13+, so 0.5.0's metadata declares
rem Requires-Python >=3.8.1,<3.13. Because the bootstrapper always targets the latest
rem conda-forge Python (3.14+), 0.5.0 refuses to install there and pipreqs is lost entirely.
rem 0.4.13 has Requires-Python >=3.7 (no upper cap), deps only docopt+yarg, supports the same
rem --mode compat / --force / --savepath flags, uses only stable stdlib (ast-based scan), and
rem runs on Python 3.14. Do NOT "upgrade" back to 0.5.0 -- it reintroduces the <3.13 cap.
rem The only feature lost is .ipynb scanning, which was already non-functional on latest Python.
if not defined HP_PIPREQS_VERSION set "HP_PIPREQS_VERSION=0.4.13"
set "HP_MINICONDA_MIN_BYTES=%HP_MINICONDA_MIN_BYTES%"
if not defined HP_MINICONDA_MIN_BYTES set "HP_MINICONDA_MIN_BYTES=5000000"
set "HP_CONDA_DL_INJECTED="
if defined HP_MINICONDA_URL set "HP_CONDA_DL_INJECTED=1"
if not defined HP_MINICONDA_URL set "HP_MINICONDA_URL=https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe"
set "HP_MINICONDA_FALLBACK_URL=https://repo.continuum.io/miniconda/Miniconda3-latest-Windows-x86_64.exe"
set "HP_UV_DL_INJECTED="
if defined HP_UV_URL set "HP_UV_DL_INJECTED=1"
if not defined HP_UV_URL set "HP_UV_URL=https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip"
rem HP_UV_FALLBACK_URL: pinned release used when primary GitHub releases/latest CDN fails
set "HP_UV_FALLBACK_URL=https://github.com/astral-sh/uv/releases/download/0.7.3/uv-x86_64-pc-windows-msvc.zip"
set "HP_UV_MIN_BYTES=%HP_UV_MIN_BYTES%"
if not defined HP_UV_MIN_BYTES set "HP_UV_MIN_BYTES=1000000"
rem REQ-023b: get-pip.py -- used only by the venv fallback tier's --without-pip retry (see
rem :download_get_pip / :try_venv_fallback). HP_GETPIP_FALLBACK_URL is the get-pip project's own
rem GitHub source (the file bootstrap.pypa.io serves is generated from this repo), mirroring the
rem primary-CDN + GitHub-source fallback pattern already used for Miniconda/uv above.
if not defined HP_GETPIP_URL set "HP_GETPIP_URL=https://bootstrap.pypa.io/get-pip.py"
set "HP_GETPIP_FALLBACK_URL=https://raw.githubusercontent.com/pypa/get-pip/main/public/get-pip.py"
rem REQ-009 Tier 5 (by naming/history; executed 3rd as of the provider-chain reorder): the
rem embeddable-Python fallback, reached right after conda fails (before venv/system) so a
rem pinned runtime.txt/pyproject.toml version is still honored via a fresh checksummed download
rem instead of silently falling back to whatever ambient Python happens to be on the machine.
rem Only a single "latest" version is ever downloaded here -- HP_EMBED_LATEST_SHA256 MUST match
rem the "3.14" entry embedded in the Python-side
rem ~embed_pyver_check.py payload below (a unit test asserts this so a refresh that updates one
rem but not the other is caught at CI time, not discovered live). See docs/agent-interconnect.md
rem "Standalone Python-download tier" for the two-stage PowerShell/Python design and why a
rem per-request version table deliberately does NOT live here in batch.
if not defined HP_EMBED_LATEST_PATCH set "HP_EMBED_LATEST_PATCH=3.14.6"
set "HP_EMBED_LATEST_SHA256=df901e84a896ff1ee720ad03377e0c8d8c2244fda79808aeeaff6316df1cb75c"
rem HP_TEST_OFFLINE=1: simulates ping failure for REQ-013 branch coverage (CI test flag)
set "HP_TEST_OFFLINE=%HP_TEST_OFFLINE%"
rem HP_OFFLINE_MODE is set by :check_net_after_dl_fail when user declines or no internet
set "HP_OFFLINE_MODE=%HP_OFFLINE_MODE%"
rem HP_TEST_FORCE_CONNECTIVITY_CHECK=1: triggers connectivity gate at startup for CI coverage
set "HP_TEST_FORCE_CONNECTIVITY_CHECK=%HP_TEST_FORCE_CONNECTIVITY_CHECK%"
rem HP_TEST_FORCE_VENV_FAIL=1: simulates venv creation failure for REQ-009/REQ-014 branch coverage
set "HP_TEST_FORCE_VENV_FAIL=%HP_TEST_FORCE_VENV_FAIL%"
rem HP_TEST_FORCE_VENV_CANARY_FAIL=1: simulates the post-creation canary probe (REQ-023) failing
rem after a real, successful venv creation (distinct from HP_TEST_FORCE_VENV_FAIL, which skips
rem creation entirely)
set "HP_TEST_FORCE_VENV_CANARY_FAIL=%HP_TEST_FORCE_VENV_CANARY_FAIL%"
rem HP_TEST_FORCE_VENV_CREATE_FAIL=1: simulates the FIRST plain "python -m venv" attempt failing
rem outright (e.g. a stripped-down host Python missing ensurepip) so the REQ-023b --without-pip
rem retry path is exercised for real; distinct from HP_TEST_FORCE_VENV_FAIL, which skips venv
rem creation entirely and never reaches either attempt.
set "HP_TEST_FORCE_VENV_CREATE_FAIL=%HP_TEST_FORCE_VENV_CREATE_FAIL%"
rem HP_TEST_FORCE_EMBED_FAIL=1: simulates the REQ-009 Tier 5 embedded-Python fallback failing
rem outright, for CI coverage of the "every tier exhausted" clean-:die path.
set "HP_TEST_FORCE_EMBED_FAIL=%HP_TEST_FORCE_EMBED_FAIL%"
rem HP_TEST_FORCE_EMBED_REAL=1: narrow test-only hole through HP_OFFLINE_MODE=1 for the embed
rem tier's own download AND the get-pip.py download it triggers (mirrors
rem HP_TEST_FORCE_VENV_CREATE_FAIL's existing exception for :download_get_pip) so CI can exercise
rem the real embed download/extract/patch/pip-bootstrap path while HP_OFFLINE_MODE=1 still blocks
rem unrelated Miniconda/uv downloads earlier in the same test run.
set "HP_TEST_FORCE_EMBED_REAL=%HP_TEST_FORCE_EMBED_REAL%"
rem HP_TEST_FORCE_CONDA_FAIL=1: simulates conda env creation failure for REQ-009/REQ-014 branch coverage
set "HP_TEST_FORCE_CONDA_FAIL=%HP_TEST_FORCE_CONDA_FAIL%"
rem HP_TEST_FORCE_WARNFIX_UNRESOLVED=1: forces the warnfix cascade-candidate detection (REQ-009/REQ-005.10) for branch coverage
set "HP_TEST_FORCE_WARNFIX_UNRESOLVED=%HP_TEST_FORCE_WARNFIX_UNRESOLVED%"
rem HP_TEST_CASCADE_ANSWER=Y|N: bypasses the cascade consent prompt (REQ-009/REQ-005.10) for CI testing
set "HP_TEST_CASCADE_ANSWER=%HP_TEST_CASCADE_ANSWER%"
rem HP_ALLOW_VENV_FALLBACK (deprecated): venv fallback is now unconditional when conda fails; accepted but ignored.
set "HP_ALLOW_VENV_FALLBACK=%HP_ALLOW_VENV_FALLBACK%"
rem HP_ALLOW_SYSTEM_FALLBACK (deprecated as a gate): system Python fallback (REQ-009 Tier 4) is now
rem reached in any run and gated solely by the REQ-014 consent prompt; this flag is accepted but
rem ignored. Conda-only mode still suppresses all non-conda fallbacks via HP_FORCE_CONDA_ONLY.
set "HP_ALLOW_SYSTEM_FALLBACK=%HP_ALLOW_SYSTEM_FALLBACK%"
rem HP_TEST_FORCE_CONSENT_CHECK=1: directly triggers consent gate at startup for REQ-014 branch coverage
set "HP_TEST_FORCE_CONSENT_CHECK=%HP_TEST_FORCE_CONSENT_CHECK%"
rem HP_TEST_SYSCON_ANSWER=Y|N: bypasses the REQ-014 system Python consent prompt for CI testing
set "HP_TEST_SYSCON_ANSWER=%HP_TEST_SYSCON_ANSWER%"
rem HP_TEST_CORRUPT_CONDA=1: simulates a corrupt conda binary for REQ-020 branch coverage (corruption hardening)
set "HP_TEST_CORRUPT_CONDA=%HP_TEST_CORRUPT_CONDA%"
rem HP_TEST_HEAL_ANSWER=Y|N: bypasses the interactive Y/N prompt in :conda_binary_corrupt for CI testing
set "HP_TEST_HEAL_ANSWER=%HP_TEST_HEAL_ANSWER%"
rem HP_TEST_CORRUPT_UV=1: simulates a corrupt uv binary; clears cache and re-downloads for REQ-020 branch coverage
set "HP_TEST_CORRUPT_UV=%HP_TEST_CORRUPT_UV%"
rem HP_TEST_FORCE_UV_FAIL=1: CI-only; forces uv acquisition to fail entirely (before any download attempt).
rem Use in justme-test lane to exercise Miniconda/JustMe paths that are bypassed when uv succeeds.
rem Mirrors HP_TEST_FORCE_CONDA_FAIL=1 pattern. Does not affect HP_TEST_UV_DL_FALLBACK behavior.
set "HP_TEST_FORCE_UV_FAIL=%HP_TEST_FORCE_UV_FAIL%"
rem HP_TEST_SKIP_EVICT=1: CI-only; skips the rmdir and Miniconda re-download in :evict_and_rebuild.
rem Use with HP_TEST_CORRUPT_CONDA=1 + HP_TEST_HEAL_ANSWER=Y to test the accept branch without
rem deleting the real CI Miniconda installation. The eviction log line is still emitted.
set "HP_TEST_SKIP_EVICT=%HP_TEST_SKIP_EVICT%"
rem HP_SKIP_NIVISA=1: REQ-008 opt-out -- skip the NI-VISA driver install even when pyvisa/visa is detected (debugging)
set "HP_SKIP_NIVISA=%HP_SKIP_NIVISA%"
rem HP_NIVISA_WAIT_SECS=<n>: REQ-008 diagnostic -- post-install registry poll budget in seconds.
rem Default (unset) keeps the fast ~15s / 3-retry behavior for gating lanes. A dedicated non-gating
rem lane sets a large value (e.g. 2700 = 45 min) to wait out a genuinely slow NI-VISA install.
set "HP_NIVISA_WAIT_SECS=%HP_NIVISA_WAIT_SECS%"
rem HP_TEST_FORCE_CONDA_BULK_FAIL=1: simulate a non-transient conda bulk-install failure so the
rem REQ-005.3 per-package fallback fires (CI branch coverage). Consumed once in :conda_bulk_install.
set "HP_TEST_FORCE_CONDA_BULK_FAIL=%HP_TEST_FORCE_CONDA_BULK_FAIL%"
rem HP_TEST_FORCE_INTERACTIVE_PROBE=1: CI-only; forces the fail-fast probe's interactive branch
rem (:try_fast_exe / :verify_no_exe_interpreter) even under HP_CI_LANE, for deterministic branch
rem coverage of the ALIVE_AT_PROBE state machine. Mirrors HP_TEST_FORCE_PICKER.
set "HP_TEST_FORCE_INTERACTIVE_PROBE=%HP_TEST_FORCE_INTERACTIVE_PROBE%"
rem HP_FAILFAST_PROBE_MS: the fail-fast probe's classification window (default 10000ms). This is
rem NOT the same concept as the unrelated ~30s hard-kill cap used by :run_exe_smokerun /
rem :hidden_import_recover -- that is a force-kill ceiling for the fresh-build verification run
rem (the only run this bootstrapper ever kills). This probe window only decides how long to wait
rem before treating a launched process as "still alive / healthy" rather than "failed fast"; once
rem classified alive, the wait becomes unbounded and the process is never killed.
rem Widened from the original 5000ms after a real CI flake (self.failfast.probe.fastfail):
rem what races this window is not the failure itself (a raised exception unwinds and exits in
rem microseconds) but PyInstaller onefile COLD START -- extracting the bundled runtime to a temp
rem dir and booting an embedded interpreter before any user code (or its failure) can even run.
rem That step is commonly 1-3+ seconds on a healthy machine and can be pushed well past 5s under
rem CI-runner CPU/disk contention or a Defender on-access scan of the freshly-extracted EXE/DLLs.
rem A real user's own machine sees this same cold-start cost but rarely the added contention, so
rem widening this is a low-risk, low-cost change: it never introduces a kill (this window only
rem ever governs classification, never termination -- see above), and the only cost of widening
rem it is a few extra seconds before a genuinely broken cached EXE is recognized as such.
set "HP_FAILFAST_PROBE_MS=%HP_FAILFAST_PROBE_MS%"
if not defined HP_FAILFAST_PROBE_MS set "HP_FAILFAST_PROBE_MS=10000"
rem HP_TEST_CHECKPOINT_ANSWER=Y|N: bypasses the REQ-018 post-execution checkpoint prompt for CI
rem testing (mirrors HP_TEST_SYSBUILD_ANSWER/HP_TEST_SYSCON_ANSWER). Checked before HP_CI_LANE so
rem an explicit Y reaches the accept branch even in CI.
set "HP_TEST_CHECKPOINT_ANSWER=%HP_TEST_CHECKPOINT_ANSWER%"
rem HP_SKIP_PEP723_WRITEBACK=1: REQ-005.11/[REQ-019] opt-out -- skip the PEP 723 header
rem write-back (uv add --script) that otherwise runs after a fresh dependency install or a
rem successful warnfix repair in uv mode. Suppression-only, per [REQ-019]: absence never
rem blocks a Prime-Directive-needed behavior; setting this only disables an optional step.
set "HP_SKIP_PEP723_WRITEBACK=%HP_SKIP_PEP723_WRITEBACK%"

rem derived requirement: CI's conda-only lane must surface conda regressions instead of masking them with opt-in fallbacks.
if "%HP_FORCE_CONDA_ONLY%"=="1" (
  rem derived requirement: conda-full diagnostics must avoid venv/system fallbacks so iterate can flag real conda regressions.
  set "HP_ALLOW_SYSTEM_FALLBACK="
  call :log "[INFO] Conda-only flag active: fallbacks disabled."
)

if not defined HP_NDJSON if exist "%CD%\tests" set "HP_NDJSON=%CD%\tests\~test-results.ndjson"
if defined HP_NDJSON (
  for %%F in ("%HP_NDJSON%") do (
    if not "%%~dpF"=="" if not exist "%%~dpF" mkdir "%%~dpF" >nul 2>&1
  )
  if not exist "%HP_NDJSON%" ( type nul > "%HP_NDJSON%" )
)
rem --- CI fast path (entry tests only) ---
call :rotate_log
rem HP_* variables represent "Helper Payload" assets emitted on demand.
call :define_helper_payloads
for %%I in ("%CD%") do set "ENVNAME=%%~nI"
rem derived requirement: conda env names reject characters like '~'; self env smoke
rem scenarios run from tests\~envsmoke so normalize to ASCII word chars/_/-.
set "ENVNAME_ORIG=%ENVNAME%"
set "ENVNAME_SANITIZED="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$name = $env:ENVNAME; if (-not $name) { $name = 'env'; } $san = ($name -replace '[^A-Za-z0-9_-]', '_'); $san = ($san -replace '^-+', '_'); if ([string]::IsNullOrWhiteSpace($san) -or ($san.Trim('_').Length -eq 0)) { $san = 'env'; } [Console]::Write($san)"` ) do set "ENVNAME_SANITIZED=%%I"
if defined ENVNAME_SANITIZED set "ENVNAME=%ENVNAME_SANITIZED%"
set "ENVNAME_SANITIZED="
rem derived requirement: a leading hyphen is replaced above because `conda create -n -foo`
rem parses the name as a command-line flag (malformed); internal hyphens (my-app) are kept.
rem G1 guardrail: warn when folder name contained only non-word chars and defaulted to 'env'
if "%ENVNAME%"=="env" if not "%ENVNAME_ORIG%"=="env" (
  call :log "[WARN] Env name could not be derived from '%ENVNAME_ORIG%'; defaulting to 'env'."
)
set "ENVNAME_ORIG="
call :log "[INFO] Environment name: %ENVNAME%"
rem --- Host environment diagnostics (confirm runner OS/PS version for every CI run) ---
for /f "tokens=*" %%V in ('ver') do call :log "[INFO] Host OS: %%V"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$PSVersionTable.PSVersion.ToString()" 2^>nul`) do call :log "[INFO] Host PowerShell: %%P"

set "PYCOUNT=0"
for /f "delims=" %%F in ('dir /b /a-d *.py 2^>nul') do call :count_python "%%F"
if "%PYCOUNT%"=="" set "PYCOUNT=0"
call :log "[INFO] Python file count: %PYCOUNT%"
rem derived requirement: REQ-011 cross-dir check moved to pre-flight so users get instant
rem feedback rather than waiting through env creation to see the rejection error.
if not "%~1"=="" if /i not "%~dp1"=="%~dp0" (
  echo [ERROR] REQ-011: Dragged files must reside in the bootstrapper root folder for environment cleanliness.
  call :log "[ERROR] REQ-011: Dragged files must reside in the bootstrapper root folder."
  call :write_status "error" 1 %PYCOUNT%
  exit /b 1
)
set "HP_CONDA_PROBE_STATUS=skipped"
set "HP_CONDA_PROBE_REASON=not-requested"

rem Slice 2b-C: compute the shared interactivity determination once, before the very first
rem :try_fast_exe call below, so both untimed user-code launch points dispatch consistently.
call :compute_interactive_run

rem --- Very top EXE fast path: reuse dist\%ENVNAME%.exe when sources are unchanged ---
set "HP_FASTPATH_USED="
rem REQ-016: start clean so an inherited env var can never trigger a false "EXE
rem unverified" caveat; :run_exe_smokerun sets this only on a real non-zero EXE exit.
set "HP_EXE_VERIFY_FAILED="
rem REQ-012: HP_EXE_SKIPPED records that EXE verification was skipped by request
rem (HP_SKIP_EXE_SMOKERUN) -- distinct from "failed" -- for the post-flight note.
set "HP_EXE_SKIPPED="
rem Slice 2b-C: start clean so an inherited HP_SMOKE_RC (e.g. from a parent shell/CI wrapper)
rem can never be misread as "the just-attempted run failed" below -- :try_fast_exe's own
rem REQ-012 HP_SKIP_EXE_SMOKERUN early-return leaves HP_SMOKE_RC untouched by design (no run
rem happened), and the HP_FASTPATH_RUN_FAILED check right after this call relies on that
rem meaning "empty", not "whatever happened to be inherited."
set "HP_SMOKE_RC="
if not "%PYCOUNT%"=="0" (
  call :try_fast_exe
)
rem Slice 2b-C: HP_FASTPATH_USED alone is no longer proof of a clean run -- the interactive
rem fail-fast probe can leave it set even when the reused EXE later exited non-zero (it is
rem classified alive/healthy at the probe and is never discarded/rebuilt for a later failure;
rem see :try_fast_exe). Decouple "keep the cached EXE, skip the rebuild" from "declare full
rem success" so that outcome is never silently swallowed: HP_SMOKE_RC is empty when the run
rem never happened or was skipped by request (REQ-012, HP_EXE_SKIPPED) -- still the
rem zero-friction path -- and is a real non-zero value only for a genuine post-probe failure.
set "HP_FASTPATH_RUN_FAILED="
if defined HP_SMOKE_RC if not "%HP_SMOKE_RC%"=="0" set "HP_FASTPATH_RUN_FAILED=1"
if defined HP_FASTPATH_USED (
  if defined HP_FASTPATH_RUN_FAILED (
    rem :run_failfast_probe already logged "[STATUS] Run Status: FAILED (Exit Code: ...)"
    rem for this exact run (it always fires before returning here) -- add only the extra
    rem context, not a duplicate STATUS line.
    call :log "[WARN] dist\%ENVNAME%.exe (standalone EXE, PyInstaller build) ran to completion and exited non-zero after passing the fail-fast probe; treated as your program's own result, not a rebuild trigger."
  ) else (
    rem derived requirement: if the EXE fast path succeeds, treat bootstrap as complete without touching Conda/venv.
    call :log "[INFO] Fast path: skipping PyInstaller rebuild for existing dist\%ENVNAME%.exe"
  )
  if /I "%HP_BOOTSTRAP_STATE%"=="ok" (
    call :write_status ok 0 %PYCOUNT%
  ) else (
    call :write_status "%HP_BOOTSTRAP_STATE%" 0 %PYCOUNT%
  )
  goto :success
)
set "HP_FASTPATH_RUN_FAILED="

if "%PYCOUNT%"=="0" (
  rem derived requirement: CI observed the Miniconda probe firing before the
  rem empty-repo fast path, so keep this guard ahead of any network/bootstrap
  rem calls to avoid flaky failures when no Python sources exist.
  echo Python file count: %PYCOUNT%
  >> "%LOG%" echo Python file count: %PYCOUNT%
  echo No Python files detected; skipping environment bootstrap.
  >> "%LOG%" echo No Python files detected; skipping environment bootstrap.
  call :log "[INFO] No Python files detected; skipping environment bootstrap."
  call :write_status no_python_files 0 %PYCOUNT%
  goto :success
)

if defined HP_CI_SKIP_ENV goto :ci_skip_entry

rem === uv acquisition (preferred env+dep installer; falls back to conda) =======
rem derived requirement: uv is gated by HP_FORCE_CONDA_ONLY (same gate used for
rem venv/system fallbacks) so the conda-full CI lane exercises the pure conda path.
rem The binary is cached under ~uv_bin\ (tilde-prefix keeps it gitignored).
rem Orchestration layer: force uv to use only its own managed CPython toolchain and
rem ignore any ambient/legacy system or conda interpreter on PATH/registry (e.g. the
rem GitHub runner's hostedtoolcache Python). With no user version constraint uv then
rem selects the latest managed CPython; a user runtime.txt/pyproject.toml is still
rem honored via the --python forwarding applied downstream where the uv venv is created
rem (HP_UV_PY_REQ; loose constraints forward the range so uv picks the latest satisfying
rem version, exact pins stay fixed). Set before the PVW_UV_EXE branch and before the first uv
rem invocation so every uv command (run,
rem venv, pip) in this process inherits it. See docs/agent-lessons-learned.md.
set "UV_PYTHON_PREFERENCE=only-managed"
call :log "[INFO] uv: UV_PYTHON_PREFERENCE=only-managed (orchestration uses managed Python)."
if not defined PVW_UV_EXE goto :pvw_uv_exe_skip
set "HP_UV_EXE=%PVW_UV_EXE%"
call :log "[INFO] uv: using super-user override PVW_UV_EXE."
goto :uv_acquire_done
:pvw_uv_exe_skip
set "HP_UV_EXE="
set "HP_UV_BIN=%HP_SCRIPT_ROOT%~uv_bin"
set "HP_UV_ZIP=%TEMP%\~uv_setup.zip"
if "%HP_FORCE_CONDA_ONLY%"=="1" (
  call :log "[INFO] uv: skipped (HP_FORCE_CONDA_ONLY=1)."
  goto :uv_acquire_done
)
if "%HP_TEST_FORCE_UV_FAIL%"=="1" (
  call :log "[WARN] uv: HP_TEST_FORCE_UV_FAIL: simulating uv acquisition failure."
  set "UV_FALLBACK_REASON=test_forced_fail"
  call :log "[WARN] UV_FALLBACK reason=test_forced_fail"
  goto :uv_acquire_done
)
if exist "%HP_UV_BIN%\uv.exe" (
  if defined HP_TEST_CORRUPT_UV (
    call :log "[WARN] HP_TEST_CORRUPT_UV: simulating corrupt uv binary; clearing cache."
    del /f /q "%HP_UV_BIN%\uv.exe" >nul 2>&1
    goto :uv_acquire_download
  )
  "%HP_UV_BIN%\uv.exe" --version >nul 2>&1
  if errorlevel 1 (
    call :log "[WARN] Cached uv.exe failed health check; clearing and re-downloading."
    del /f /q "%HP_UV_BIN%\uv.exe" >nul 2>&1
    goto :uv_acquire_download
  )
  set "HP_UV_EXE=%HP_UV_BIN%\uv.exe"
  call :log "[INFO] uv: cached binary found at ~uv_bin\uv.exe"
  goto :uv_acquire_done
)
:uv_acquire_download
if "%HP_OFFLINE_MODE%"=="1" (
  call :log "[INFO] REQ-013: Offline mode: skipping uv download."
  set "UV_FALLBACK_REASON=offline"
  call :log "[WARN] UV_FALLBACK reason=offline"
  goto :uv_acquire_done
)
call :log "[INFO] uv: downloading to ~uv_bin..."
if not exist "%HP_UV_BIN%" mkdir "%HP_UV_BIN%" >nul 2>&1
set "HP_UV_ACTIVE_URL=%HP_UV_URL%"
if "%HP_TEST_UV_DL_FALLBACK%"=="1" if not defined HP_UV_DL_INJECTED set "HP_UV_ACTIVE_URL=https://uv-test-fail.invalid/uv-x86_64-pc-windows-msvc.zip"
call :log "[INFO] Downloading uv from %HP_UV_ACTIVE_URL%..."
curl --fail -L --retry 3 --retry-delay 5 --max-time 120 "%HP_UV_ACTIVE_URL%" -o "%HP_UV_ZIP%" >> "%LOG%" 2>&1
if errorlevel 1 if exist "%HP_UV_ZIP%" del "%HP_UV_ZIP%" >nul 2>&1
if not exist "%HP_UV_ZIP%" (
  if not "%HP_TEST_UV_DL_FALLBACK%"=="1" call :check_net_after_dl_fail
)
if not exist "%HP_UV_ZIP%" if not "%HP_OFFLINE_MODE%"=="1" (
  if defined HP_UV_DL_INJECTED (
    call :log "[ERROR] Injected HP_UV_URL failed; not trying fallback."
  ) else (
    call :log "[INFO] Trying fallback uv URL: %HP_UV_FALLBACK_URL%..."
    curl --fail -L --retry 3 --retry-delay 5 --max-time 120 "%HP_UV_FALLBACK_URL%" -o "%HP_UV_ZIP%" >> "%LOG%" 2>&1
    if errorlevel 1 if exist "%HP_UV_ZIP%" del "%HP_UV_ZIP%" >nul 2>&1
    if exist "%HP_UV_ZIP%" (
      call :log "[INFO] uv download succeeded from fallback URL."
    ) else (
      call :log "[WARN] uv: all download URLs failed."
    )
  )
)
if exist "%HP_UV_ZIP%" (
  for %%S in ("%HP_UV_ZIP%") do (
    if %%~zS GEQ %HP_UV_MIN_BYTES% (
      powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath '%HP_UV_ZIP%' -DestinationPath '%HP_UV_BIN%' -Force } catch { exit 1 }" >> "%LOG%" 2>&1
    ) else (
      call :log "[WARN] uv: zip too small (%%~zS bytes); skipping extract."
    )
  )
  del "%HP_UV_ZIP%" >nul 2>&1
)
if exist "%HP_UV_BIN%\uv.exe" (
  set "HP_UV_EXE=%HP_UV_BIN%\uv.exe"
  call :log "[INFO] uv: acquired at ~uv_bin\uv.exe"
) else (
  call :log "[WARN] uv: acquisition failed; will use conda for env creation."
  set "UV_FALLBACK_REASON=acquire_failed"
  call :log "[WARN] UV_FALLBACK reason=acquire_failed"
)
:uv_acquire_done

rem === uv-first: skip Miniconda when uv can provide Python ====================
rem derived requirement: when uv is available, use it to run ~detect_python.py
rem instead of CONDA_BASE_PY so the Miniconda download can be skipped entirely.
rem HP_FORCE_CONDA_ONLY already cleared HP_UV_EXE above, so no extra check needed.
if not defined HP_UV_EXE goto :uv_first_skip
set "HP_RUNTIME_TXT_PREEXIST="
if exist "runtime.txt" set "HP_RUNTIME_TXT_PREEXIST=1"
call :emit_from_base64 "~detect_python.py" HP_DETECT_PY
if errorlevel 1 goto :uv_first_skip
"%HP_UV_EXE%" run --no-project python "~detect_python.py" > "~py_spec.txt" 2>> "%LOG%"
if errorlevel 1 (
  call :log "[WARN] uv-first: detect_python via uv run failed; will download Miniconda."
  goto :uv_first_skip
)
set "PYSPEC="
for /f "usebackq delims=" %%A in ("~py_spec.txt") do set "PYSPEC=%%A"
set "HP_UV_PROVIDING_PYTHON=1"
call :log "[INFO] uv-first: Miniconda download skipped."
:uv_first_skip

rem === Miniconda URL probe (CI only, deferred after uv detection) ==============
rem derived requirement: probe deferred to after uv detection so that uv-first
rem runs skip the ~99 MB download when Miniconda will not be used. The probe
rem verifies the Miniconda URL is reachable only when conda is actually needed.
if "%HP_CI_TEST_CONDA_DL%"=="1" (
  if not defined HP_CI_SKIP_ENV (
    if not defined HP_UV_PROVIDING_PYTHON (
      set "HP_CONDA_PROBE_STATUS=ran"
      call :probe_conda_url
      if errorlevel 1 (
        rem derived requirement: CI observed the Miniconda probe erroring before real bootstrap.
        rem Emit a warning and continue so the actual install path can still run.
        set "HP_CONDA_PROBE_STATUS=failed"
        set "HP_CONDA_PROBE_REASON=probe-failed"
        call :log "[WARN] Miniconda download probe failed; continuing to bootstrap."
      )
    ) else (
      set "HP_CONDA_PROBE_REASON=uv-first"
    )
  ) else (
    set "HP_CONDA_PROBE_REASON=skip-env"
  )
)
if "%HP_CONDA_PROBE_STATUS%"=="skipped" (
  call :emit_conda_probe_skip
)

rem === Miniconda location (non-admin) =========================================
rem G2 guardrail: warn if PUBLIC is absent so path failures are observable
if not defined PUBLIC call :log "[WARN] PUBLIC env var not defined; Miniconda path may be invalid."
set "MC=%PUBLIC%\Documents\Miniconda3"
set "CONDA_MAIN=%MC%\condabin\conda.bat"
set "CONDA_ALT=%MC%\Scripts\conda.bat"
set "MINICONDA_ROOT=%MC%"
set "CONDA_BASE_PY=%MINICONDA_ROOT%\python.exe"

call :select_conda_bat
rem PVW_CONDA_EXE: super-user override for the conda batch file path. When set, Miniconda
rem installation is skipped. Requires conda to already be on PATH (the 'where conda' probe
rem below will fail gracefully if not). Typical usage: pointing at a system-wide conda install.
if defined PVW_CONDA_EXE set "CONDA_BAT=%PVW_CONDA_EXE%"

rem Install Miniconda if conda.bat is missing (skipped when uv is providing Python)
set "HP_CONDA_JUST_INSTALLED="
if not defined HP_UV_PROVIDING_PYTHON if not defined CONDA_BAT (
  set "HP_CONDA_JUST_INSTALLED=1"
  echo [INFO] Installing Miniconda into "%MINICONDA_ROOT%"...
  call :download_miniconda_exe
  if exist "%TEMP%\miniconda.exe" (
    REM Attempt AllUsers install with JustMe fallback; see :try_conda_install.
    call :try_conda_install
  )
  if exist "%TEMP%\miniconda.exe" del "%TEMP%\miniconda.exe" >nul 2>&1
  call :select_conda_bat
)

set "PATH=%MINICONDA_ROOT%\condabin;%MINICONDA_ROOT%\Scripts;%MINICONDA_ROOT%\Library\bin;%MINICONDA_ROOT%;%PATH%"
:after_conda_bat_validation

if not defined HP_UV_PROVIDING_PYTHON if not defined CONDA_BAT (
  set "HP_ENV_READY="
  call :handle_conda_failure "conda.bat not found after bootstrap."
  if defined HP_ENV_READY goto :after_env_mode_selection
  call :die "[ERROR] conda.bat not found after bootstrap."
)

rem === Fresh install: warm up conda to initialize base-env state (REQ-020) ===
rem derived requirement: Silent Miniconda install (/S /AddToPath=0) leaves the base
rem environment in a state where conda info may return non-zero until conda is run
rem once with its own directories in PATH. Calling conda info here (silently, after
rem the PATH update) ensures subsequent bootstrap runs that find the pre-installed
rem Miniconda pass the corruption health check instead of falsely flagging it corrupt.
if defined HP_CONDA_JUST_INSTALLED if defined CONDA_BAT (
  call "%CONDA_BAT%" info >nul 2>&1
)

rem === Validate existing conda binary health (REQ-020: corruption hardening) ===
rem Only fires for pre-existing installs (HP_CONDA_JUST_INSTALLED guards fresh downloads).
rem Skipped when HP_TEST_FORCE_CONDA_FAIL=1 (test flag already simulates conda failure).
rem Placed after PATH update so conda.bat internal calls can resolve their dependencies.
if defined CONDA_BAT if not defined HP_CONDA_JUST_INSTALLED if not defined HP_TEST_FORCE_CONDA_FAIL (
  if defined HP_TEST_CORRUPT_CONDA (
    call :log "[ERROR] HP_TEST_CORRUPT_CONDA: simulating corrupt conda binary."
    goto :conda_binary_corrupt
  )
  call "%CONDA_BAT%" info >nul 2>&1
  if errorlevel 1 goto :conda_binary_corrupt
)
if defined HP_UV_PROVIDING_PYTHON goto :after_conda_probes
where conda >> "%LOG%" 2>&1 || (
  set "HP_ENV_READY="
  call :handle_conda_failure "[ERROR] 'conda' not found on PATH after bootstrap."
  if defined HP_ENV_READY goto :after_env_mode_selection
  call :die "[ERROR] 'conda' not found on PATH after bootstrap."
)
where python >> "%LOG%" 2>&1 || (
  set "HP_ENV_READY="
  call :handle_conda_failure "[ERROR] 'python' not found on PATH after bootstrap."
  if defined HP_ENV_READY goto :after_env_mode_selection
  call :die "[ERROR] 'python' not found on PATH after bootstrap."
)
python -V >> "%LOG%" 2>&1 || (
  set "HP_ENV_READY="
  call :handle_conda_failure "[ERROR] 'python -V' failed after bootstrap."
  if defined HP_ENV_READY goto :after_env_mode_selection
  call :die "[ERROR] 'python -V' failed after bootstrap."
)
:after_conda_probes

rem === Channel policy (determinism & legal) ===================================
if not defined HP_UV_PROVIDING_PYTHON if not exist "%CONDA_BAT%" (
  call :die "[ERROR] Conda not found at: %CONDA_BAT%"
)
if not defined HP_UV_PROVIDING_PYTHON call "%CONDA_BAT%" config --name base --add channels conda-forge >> "%LOG%" 2>&1

rem NOTE: every 'conda create' or 'conda install' call below MUST include:
rem       --override-channels -c conda-forge

set "ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%"
call :log "[INFO] Workspace: %CD%"
call :log "[INFO] Env name: %ENVNAME%"
call :log "[INFO] Log: %LOG%"

if not defined HP_UV_PROVIDING_PYTHON (
  set "HP_RUNTIME_TXT_PREEXIST="
  if exist "runtime.txt" set "HP_RUNTIME_TXT_PREEXIST=1"
)
rem --- Detect required Python version (must run before env-state check) ---
rem derived requirement: PYSPEC must be known before the env-state skip decision
rem so a runtime.txt / pyproject.toml change triggers a full env rebuild.
rem uv-first path: already ran detect_python via uv run and set PYSPEC above.
if defined HP_UV_PROVIDING_PYTHON goto :detect_python_done
call :emit_from_base64 "~detect_python.py" HP_DETECT_PY
if errorlevel 1 call :die "[ERROR] Could not write ~detect_python.py"
if exist "%CONDA_BASE_PY%" (
  "%CONDA_BASE_PY%" "~detect_python.py" > "~py_spec.txt" 2>> "%LOG%"
) else (
  call "%CONDA_BAT%" run -n base python "~detect_python.py" > "~py_spec.txt" 2>> "%LOG%"
)
set "PYSPEC="
for /f "usebackq delims=" %%A in ("~py_spec.txt") do set "PYSPEC=%%A"
:detect_python_done
if defined PVW_TARGET_PY set "PYSPEC=%PVW_TARGET_PY%"
if defined PVW_TARGET_PY call :log "[INFO] Python version: using super-user override PVW_TARGET_PY."

rem --- Env-state fast path: skip conda create+install if env is still valid ---
rem derived requirement: ~env.state.json records envMode/envName/envPath/pySpec/lockSize
rem from the last successful run. Fast path fires only when PYSPEC, envName, lock size,
rem and python.exe all match the stored snapshot.
rem uv-first path: env reuse is handled by the .uv_env existence check below; skip here.
if defined HP_UV_PROVIDING_PYTHON goto :env_state_check_done
set "HP_ENV_STATE_RESULT="
call :emit_from_base64 "~env_state.py" HP_ENV_STATE
if errorlevel 1 goto :env_state_check_done
if exist "%CONDA_BASE_PY%" (
  "%CONDA_BASE_PY%" "~env_state.py" --check > "~env_state.txt" 2>> "%LOG%"
) else (
  call "%CONDA_BAT%" run -n base python "~env_state.py" --check > "~env_state.txt" 2>> "%LOG%"
)
for /f "usebackq delims=" %%E in ("~env_state.txt") do set "HP_ENV_STATE_RESULT=%%E"
if exist "~env_state.txt" del "~env_state.txt" >nul 2>&1
if exist "~env_state.py" del "~env_state.py" >nul 2>&1
if /I "%HP_ENV_STATE_RESULT%"=="skip" (
  call :log "[INFO] Env-state fast path: reusing conda env %ENVNAME%."
  goto :env_state_fast_path
)
:env_state_check_done
rem --- ENVNAME guard: default to 'env' if sanitization yielded an empty name ---
if "%ENVNAME%"=="" (
  call :log "[WARN] Conda env name resolved to empty; defaulting to 'env'."
  set "ENVNAME=env"
)
rem Recalculate ENV_PATH so it is always consistent with the guarded ENVNAME value
set "ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%"
rem === uv venv creation (primary path when uv was acquired) ====================
rem derived requirement: uv creates a pip-native venv at .uv_env in the project
rem folder, short-circuiting conda create. On failure, :try_conda_create runs the
rem existing conda path unchanged. REQ-004 Tier 1-2 Python version (PYSPEC) is
rem forwarded to uv via --python X.Y when a lower-bound version can be extracted.
if not defined HP_UV_EXE goto :try_conda_create
set "HP_UV_ENV_PATH=%HP_SCRIPT_ROOT%.uv_env"
if defined PVW_WORKSPACE set "HP_UV_ENV_PATH=%PVW_WORKSPACE%"
if exist "%HP_UV_ENV_PATH%\Scripts\python.exe" (
  "%HP_UV_ENV_PATH%\Scripts\python.exe" -c "import pip;exit(0)" >nul 2>&1
  if not errorlevel 1 (
    set "HP_ENV_MODE=uv"
    set "HP_PY=%HP_UV_ENV_PATH%\Scripts\python.exe"
    set "ENV_PATH=%HP_UV_ENV_PATH%"
    call :log "[INFO] uv: reusing existing .uv_env"
    goto :uv_venv_ready
  )
)
rem Translate PYSPEC into a uv --python request (REQ-004 Tiers 1-2, floor-vs-pin).
rem Two outputs, pipe-delimited: HP_UV_PY_REQ (forwarded to uv) and HP_UV_PY_DISP (log only).
rem  - Exact pins (python=X.Y runtime.txt, python==X.Y) -> bare "X.Y" (uv pins to X.Y).
rem  - Loose/range forms (python>=X.Y, python>X.Y, python>=X.Y,<X.Z) -> the RANGE itself, so
rem    uv resolves the LATEST satisfying managed CPython instead of the floor (matches the
rem    conda path, which hands the full range to its solver).
rem CRITICAL: the range may contain < and > . Forward it ONLY through the double-quoted
rem --python "%HP_UV_PY_REQ%" argument (quotes shield it from cmd's redirection parser).
rem The :log line uses HP_UV_PY_DISP, which is operator-free ("X.Y" or "X.Y or newer"),
rem because :log echoes its message UNQUOTED -- a raw < or > there would be a redirection.
rem Single quotes only inside -Command (a literal " would close the cmd-level quote).
rem [Console]::Write avoids the trailing CR that for /f does not strip.
set "HP_UV_PY_REQ="
set "HP_UV_PY_DISP="
if defined PYSPEC (
  for /f "usebackq tokens=1,2 delims=|" %%V in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = $env:PYSPEC; $req = ($s -replace '^python','').Trim(); if ($req -match '^==?([0-9].*)$') { $req = $Matches[1] }; $floor = ''; if ($s -match '([0-9]+\.[0-9]+)') { $floor = $Matches[1] }; $disp = $floor; if ($req -ne $floor) { $disp = $floor + ' or newer' }; [Console]::Write($req + '|' + $disp)"`) do (
    set "HP_UV_PY_REQ=%%V"
    set "HP_UV_PY_DISP=%%W"
  )
)
if defined HP_UV_PY_REQ (
  call :log "[INFO] uv: creating venv at .uv_env with Python %HP_UV_PY_DISP%..."
  "%HP_UV_EXE%" venv --seed --python "%HP_UV_PY_REQ%" "%HP_UV_ENV_PATH%" >> "%LOG%" 2>&1
) else (
  call :log "[INFO] uv: creating venv at .uv_env..."
  "%HP_UV_EXE%" venv --seed "%HP_UV_ENV_PATH%" >> "%LOG%" 2>&1
)
if errorlevel 1 goto :uv_venv_fail
if not exist "%HP_UV_ENV_PATH%\Scripts\python.exe" goto :uv_venv_fail
set "HP_ENV_MODE=uv"
set "HP_PY=%HP_UV_ENV_PATH%\Scripts\python.exe"
set "ENV_PATH=%HP_UV_ENV_PATH%"
call :log "[INFO] uv: venv created at .uv_env"
:uv_venv_ready
call :log "[INFO] HP_ENV_MODE=uv"
call :log "[BOOT] REQ-009: Selected Python provider: UV."
call :emit_from_base64 "~print_pyver.py" HP_PRINT_PYVER
if not errorlevel 1 (
  "%HP_PY%" "~print_pyver.py" > "~pyver.txt" 2>> "%LOG%"
  for /f "usebackq delims=" %%A in ("~pyver.txt") do set "PYVER=%%A"
  if not defined HP_RUNTIME_TXT_PREEXIST call :write_runtime_txt
)
if "%HP_TEST_UV_FAIL%"=="1" (
  call :log "[TEST] Injecting uv dep install failure"
  "%HP_UV_EXE%" pip install --python "%HP_PY%" __hp_test_nonexistent_pkg_0xdeadbeef__ >> "%LOG%" 2>&1
  call :log "[WARN] uv pip install -r requirements.txt failed; some packages may be missing."
  set "UV_FALLBACK_REASON=dep_install_failed"
  call :log "[WARN] UV_FALLBACK reason=dep_install_failed"
)
goto :after_env_mode_selection
:uv_venv_fail
rem derived requirement: uv venv reads pyproject.toml for requires-python even when
rem --python is not passed, so a malformed pyproject.toml causes venv creation to fail.
rem When HP_UV_PROVIDING_PYTHON=1 (conda not installed), retry via "uv run --no-project
rem python -m venv" which bypasses project discovery and ignores pyproject.toml.
rem The HP_PYPROJ_DEPS path (line ~712) later detects the malformed TOML and emits the
rem [WARN] pyproject.toml TOML parse error message as normal.
if defined HP_UV_PROVIDING_PYTHON (
  call :log "[WARN] uv: venv creation failed; retrying via uv run --no-project (malformed pyproject.toml guard)."
  if defined HP_UV_PY_REQ (
    "%HP_UV_EXE%" run --no-project --python "%HP_UV_PY_REQ%" python -m venv "%HP_UV_ENV_PATH%" >> "%LOG%" 2>&1
  ) else (
    "%HP_UV_EXE%" run --no-project python -m venv "%HP_UV_ENV_PATH%" >> "%LOG%" 2>&1
  )
  if not errorlevel 1 (
    if exist "%HP_UV_ENV_PATH%\Scripts\python.exe" (
      set "HP_ENV_MODE=uv"
      set "HP_PY=%HP_UV_ENV_PATH%\Scripts\python.exe"
      set "ENV_PATH=%HP_UV_ENV_PATH%"
      call :log "[INFO] uv: venv created at .uv_env via uv run --no-project fallback"
      goto :uv_venv_ready
    )
  )
  call :log "[WARN] uv: uv run --no-project venv also failed; falling back to conda create."
)
call :log "[WARN] uv: venv creation failed; falling back to conda create."
set "UV_FALLBACK_REASON=venv_create_failed"
call :log "[WARN] UV_FALLBACK reason=venv_create_failed"
set "HP_UV_EXE="
:try_conda_create
call :log "[INFO] HP_ENV_MODE=conda"
if "%HP_TEST_FORCE_CONDA_FAIL%"=="1" goto :hp_test_conda_fail
rem derived requirement: conda env create can take several minutes; emit a user-facing message
rem so the script never appears to hang silently during the longest single step.
call :log "[INFO] Creating Python environment '%ENVNAME%' -- this may take several minutes..."
rem REQ-022: transient-retry for conda create, mirroring the proven :conda_bulk_install pattern
rem (findstr-detect a transient network error, wait 15s, retry once). Goto-based dispatch on
rem purpose (see docs/agent-lessons-learned.md "Provider-cascade dispatch is goto-based on
rem purpose"): the create call + %ERRORLEVEL% capture is never nested inside a parenthesized
rem if/else block, so cmd's parse-time %VAR% expansion cannot freeze it to a stale value.
if exist "~conda_create.tmp" del "~conda_create.tmp" >nul 2>&1
if "%HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL%"=="1" goto :conda_create_test_network_fail
if "%PYSPEC%"=="" (
  call "%CONDA_BAT%" create -y -n "%ENVNAME%" python pip --override-channels -c conda-forge > "~conda_create.tmp" 2>&1
) else (
  call "%CONDA_BAT%" create -y -n "%ENVNAME%" %PYSPEC% pip --override-channels -c conda-forge > "~conda_create.tmp" 2>&1
)
set "HP_CCREATE_RC=%ERRORLEVEL%"
goto :conda_create_have_rc
:conda_create_test_network_fail
rem [TEST] HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL: simulate a transient CondaHTTPError on the
rem first conda-create attempt only (mirrors HP_TEST_FORCE_CONDA_NETWORK_FAIL for bulk-install).
echo CondaHTTPError: HTTP 000 CONNECTION FAILED (simulated) > "~conda_create.tmp"
set "HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL="
set "HP_CCREATE_RC=1"
:conda_create_have_rc
type "~conda_create.tmp" >> "%LOG%"
if not "%HP_CCREATE_RC%"=="0" goto :conda_create_check_transient
del "~conda_create.tmp" >nul 2>&1
goto :conda_create_done
:conda_create_check_transient
findstr /i /c:"CondaHTTPError" /c:"Failed to fetch" /c:"timed out" /c:"ConnectionError" "~conda_create.tmp" >nul 2>&1
set "HP_CCREATE_TRANSIENT_RC=%ERRORLEVEL%"
del "~conda_create.tmp" >nul 2>&1
if not "%HP_CCREATE_TRANSIENT_RC%"=="0" goto :conda_create_failed
echo Conda environment creation failed -- possible network or repository issue. Retrying once...
call :log "[INFO] conda create: transient failure detected; retrying after 15s."
timeout /t 15 /nobreak >nul 2>&1
echo Retrying environment creation...
if "%PYSPEC%"=="" (
  call "%CONDA_BAT%" create -y -n "%ENVNAME%" python pip --override-channels -c conda-forge >> "%LOG%" 2>&1
) else (
  call "%CONDA_BAT%" create -y -n "%ENVNAME%" %PYSPEC% pip --override-channels -c conda-forge >> "%LOG%" 2>&1
)
if not errorlevel 1 goto :conda_create_done
echo *** Conda environment creation could not complete. This may be a temporary network issue.
echo *** See log file for details: ~setup.log
call :log "[WARN] conda create: retry after transient failure also failed."
:conda_create_failed
set "HP_ENV_READY="
call :handle_conda_failure "[ERROR] conda env create failed."
if defined HP_ENV_READY goto :after_env_mode_selection
call :die "[ERROR] conda env create failed."
:conda_create_done

set "CONDA_PREFIX=%ENV_PATH%"
set "HP_PY=%CONDA_PREFIX%\python.exe"
if not exist "%HP_PY%" (
  set "HP_ENV_READY="
  call :handle_conda_failure "[ERROR] python.exe missing from conda environment."
  if defined HP_ENV_READY goto :after_env_mode_selection
  call :die "[ERROR] python.exe missing from conda environment."
)

call :emit_from_base64 "~print_pyver.py" HP_PRINT_PYVER
if errorlevel 1 call :die "[ERROR] Could not write ~print_pyver.py"
"%HP_PY%" "~print_pyver.py" > "~pyver.txt" 2>> "%LOG%"
for /f "usebackq delims=" %%A in ("~pyver.txt") do set "PYVER=%%A"
if not defined HP_RUNTIME_TXT_PREEXIST if not "%PYVER%"=="" (
  >"runtime.txt" echo %PYVER%
  if errorlevel 1 (
    call :log "[WARN] runtime.txt write failed (read-only filesystem?). Tier 3 remains active."
  ) else (
    call :log "[INFO] runtime.txt written: %PYVER%"
    set "PYSPEC=%PYVER:python-=python=%"
  )
)

rem README.md documents the conda-forge policy for this project and why .condarc is required.
rem Emit the .condarc payload from base64 so quoting stays robust on Windows CMD.
call :emit_from_base64 "~condarc" HP_CONDARC
if errorlevel 1 call :die "[ERROR] Could not stage ~condarc"
if not exist "%ENV_PATH%" mkdir "%ENV_PATH%"
copy /y "~condarc" "%ENV_PATH%\.condarc" >> "%LOG%" 2>&1
if errorlevel 1 call :die "[ERROR] Could not write %ENV_PATH%\.condarc"
call :log "[BOOT] REQ-009: Selected Python provider: Conda (Portable)."
goto :after_env_mode_selection

:env_state_fast_path
rem derived requirement: env exists from prior run; set interpreter, skip create+install.
set "CONDA_PREFIX=%ENV_PATH%"
set "HP_PY=%CONDA_PREFIX%\python.exe"
if not exist "%HP_PY%" (
  call :log "[WARN] Env-state fast path: %HP_PY% not found; falling back to full env rebuild."
  set "HP_ENV_STATE_RESULT=stale"
  goto :env_state_check_done
)
call :log "[BOOT] REQ-009: Selected Python provider: Conda (Portable) [fast path]."
call :emit_from_base64 "~print_pyver.py" HP_PRINT_PYVER
if not errorlevel 1 (
  "%HP_PY%" "~print_pyver.py" > "~pyver.txt" 2>> "%LOG%"
  for /f "usebackq delims=" %%A in ("~pyver.txt") do set "PYVER=%%A"
  if not defined HP_RUNTIME_TXT_PREEXIST if not "%PYVER%"=="" (
    >"runtime.txt" echo %PYVER%
    if errorlevel 1 (
      call :log "[WARN] runtime.txt write failed (read-only filesystem?). Tier 3 remains active."
    ) else (
      call :log "[INFO] runtime.txt written: %PYVER%"
      set "PYSPEC=%PYVER:python-=python=%"
    )
  )
)

:after_env_mode_selection
if defined PVW_PYTHON_EXE set "HP_PY=%PVW_PYTHON_EXE%"
if defined PVW_PYTHON_EXE call :log "[INFO] Python host: using super-user override PVW_PYTHON_EXE."
rem === Conda base periodic update (~30 days) ====================================
rem derived requirement: README.md requires periodic conda base update; skip on
rem first install (timestamp seeded) and when uv env is in use.
call :conda_base_update
rem === end conda base update ====================================================
call :emit_from_base64 "~prep_requirements.py" HP_PREP_REQUIREMENTS
if errorlevel 1 call :die "[ERROR] Could not write ~prep_requirements.py"
set "REQ=requirements.txt"
if exist "%REQ%" ( for %%S in ("%REQ%") do if %%~zS EQU 0 del "%REQ%" )
if exist "%REQ%" (
  echo *** [INFO] Using requirements.txt for dependencies
  echo *** [INFO] Dependency accuracy depends on file correctness
  set "DEP_SOURCE=requirements.txt"
  set "DEP_LAYER_REQUIREMENTS=1"
  call :log "[INFO] DEP_LAYER_REQUIREMENTS=1"
  call :log "[TRACE] dep source selected: requirements.txt"
)
set "HP_JOB_SUMMARY=~pipreqs.summary.txt"
if exist "%HP_JOB_SUMMARY%" del "%HP_JOB_SUMMARY%"
if not defined HP_PY (
  call :die "[ERROR] Active Python interpreter not resolved."
)

echo Interpreter: %HP_PY%
>> "%LOG%" echo Interpreter: %HP_PY%
call :append_env_mode_row
"%HP_PY%" -c "print('py_ok')" 1>nul 2>nul || call :log "[WARN] Interpreter smoke test failed (continuing)."
"%HP_PY%" -c "import sys;print(sys.version.split()[0])" > "~pyver_host.tmp" 2>nul
if exist "~pyver_host.tmp" for /f "usebackq delims=" %%Y in ("~pyver_host.tmp") do call :log "[INFO] Host Python: %%Y"
if exist "~pyver_host.tmp" del "~pyver_host.tmp" >nul 2>&1
set "PEP723_ACTIVE="
set "PEP723_BLOCK_FOUND="
set "PEP723_REQ=~requirements.pep723.txt"
if exist "%PEP723_REQ%" del "%PEP723_REQ%" >nul 2>&1
call :determine_entry "%~1"
if errorlevel 11 (
  call :write_status "error" 1 %PYCOUNT%
  exit /b 1
)
if errorlevel 1 call :die "[ERROR] Could not determine entry point"
set "HP_PYPROJ_REQ=~requirements.pyproject.txt"
if exist "%HP_PYPROJ_REQ%" del "%HP_PYPROJ_REQ%" >nul 2>&1
set "HP_PYPROJ_ACTIVE="
if exist "pyproject.toml" (
  call :emit_from_base64 "~pyproj_deps.py" HP_PYPROJ_DEPS
  if not errorlevel 1 (
    "%HP_PY%" "~pyproj_deps.py" "%HP_PYPROJ_REQ%" >nul 2>&1
    if errorlevel 1 (
      if errorlevel 2 (
        echo *** [WARN] pyproject.toml could not be parsed as valid TOML; falling back to requirements.txt or pipreqs.
        call :log "[WARN] pyproject.toml TOML parse error; falling back."
      )
    ) else (
      if exist "%HP_PYPROJ_REQ%" for %%S in ("%HP_PYPROJ_REQ%") do if %%~zS GTR 0 set "HP_PYPROJ_ACTIVE=1"
    )
    if exist "~pyproj_deps.py" del "~pyproj_deps.py" >nul 2>&1
  )
)
if defined HP_PYPROJ_ACTIVE (
  echo *** [INFO] pyproject.toml [project].dependencies found; overrides requirements.txt
  call :log "[INFO] pyproject.toml [project].dependencies detected"
  call :log "[INFO] DEP_SOURCE=pyproject"
  call :log "[INFO] DEP_LAYER_PYPROJECT=1"
  call :log "[TRACE] dep source selected: pyproject"
  set "DEP_SOURCE=pyproject"
  set "DEP_LAYER_PYPROJECT=1"
  copy /y "%HP_PYPROJ_REQ%" "requirements.txt" >nul 2>&1
)
if exist "%HP_PYPROJ_REQ%" del "%HP_PYPROJ_REQ%" >nul 2>&1
set "HP_PYPROJ_REQ="
set "HP_PYPROJ_ACTIVE="
if defined HP_ENTRY if exist "%HP_ENTRY%" (
  findstr /c:"# /// script" "%HP_ENTRY%" >nul 2>&1
  if not errorlevel 1 (
    set "PEP723_BLOCK_FOUND=1"
    echo *** PEP 723 metadata detected
    call :extract_pep723_requirements "%HP_ENTRY%" "%PEP723_REQ%"
    if exist "%PEP723_REQ%" for %%S in ("%PEP723_REQ%") do if %%~zS GTR 0 set "PEP723_ACTIVE=1"
  )
)
if defined PEP723_BLOCK_FOUND if not defined PEP723_ACTIVE (
  echo *** [WARN] PEP 723 block found but dependency list is empty or malformed; falling back
  call :log "[WARN] PEP 723 block found but no valid dependencies extracted; pipreqs fallback."
)
set "PEP723_BLOCK_FOUND="

set "HP_PIPREQS_INSTALL_PASS=0"
set "HP_PIPREQS_INSTALL_ATTEMPTED=0"
if not defined HP_SKIP_PIPREQS if not defined PEP723_ACTIVE (
  set "HP_PIPREQS_INSTALL_ATTEMPTED=1"
  if "%HP_ENV_MODE%"=="uv" (
    rem derived requirement: uv pip install bypasses python -m pip so pip need not
    rem be a module inside the uv venv; uv's own resolver handles the installation.
    "%HP_UV_EXE%" pip install --python "%HP_PY%" -q pipreqs==%HP_PIPREQS_VERSION% >> "%LOG%" 2>&1
  ) else (
    "%HP_PY%" -m pip install -q --disable-pip-version-check pipreqs==%HP_PIPREQS_VERSION% >> "%LOG%" 2>&1
  )
  if errorlevel 1 (
    call :log "[WARN] pipreqs install failed (Python version incompatible with pipreqs). Fallback: warnfix will detect and install missing imports at build time. Consider adding requirements.txt or pyproject.toml [project].dependencies for explicit dependency specification."
    set "HP_SKIP_PIPREQS=1"
    set "HP_PIPREQS_SUMMARY_NOTE=(pipreqs unavailable for this Python version)"
  ) else (
    set "HP_PIPREQS_INSTALL_PASS=1"
    call :log "[INFO] pipreqs %HP_PIPREQS_VERSION% installed successfully; using it for dependency discovery."
  )
)
if defined HP_NDJSON (
  rem Emit pass=true for intentional skips (PEP 723 or pre-existing HP_SKIP_PIPREQS),
  rem pass=true for successful installs, pass=false for install failures.
  rem Use HP_PIPREQS_INSTALL_ATTEMPTED to distinguish failed install (attempted=1, pass=0)
  rem from intentional skip (attempted=0).
  if defined PEP723_ACTIVE (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "$row = @{ id='pipreqs.install'; pass=$true; reason='pep723_active' } | ConvertTo-Json -Compress -Depth 8;" ^
      "Add-Content -Path '%HP_NDJSON%' -Value $row -Encoding ASCII" >> "%LOG%" 2>&1
  ) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "$attempted = [Environment]::GetEnvironmentVariable('HP_PIPREQS_INSTALL_ATTEMPTED') -eq '1';" ^
      "$pass = [Environment]::GetEnvironmentVariable('HP_PIPREQS_INSTALL_PASS') -eq '1';" ^
      "if ($attempted) { $reason = if ($pass) { 'success' } else { 'install_failed' } } else { $reason = 'skip_preexisting' };" ^
      "$pass = if ($attempted) { $pass } else { $true };" ^
      "$row = @{ id='pipreqs.install'; pass=$pass; reason=$reason } | ConvertTo-Json -Compress -Depth 8;" ^
      "Add-Content -Path '%HP_NDJSON%' -Value $row -Encoding ASCII" >> "%LOG%" 2>&1
  )
)

set "HP_PIPREQS_TARGET_WORK=%CD%\requirements.auto.txt"
set "HP_PIPREQS_TARGET=%HP_PIPREQS_TARGET_WORK%"
set "HP_PIPREQS_IGNORE=.git,.github,.venv,venv,env,.uv_env,build,dist,__pycache__,tests"
set "HP_PIPREQS_IGNORE_DISPLAY="
if defined HP_PIPREQS_IGNORE set "HP_PIPREQS_IGNORE_DISPLAY= --ignore \"%HP_PIPREQS_IGNORE%\""
set "HP_PIPREQS_SUMMARY_PHASE="
set "HP_PIPREQS_SUMMARY_NOTE="
set "HP_PIPREQS_SUMMARY_CMD_PATH=%HP_PIPREQS_TARGET_WORK%"
set "HP_PIPREQS_SUMMARY_IGNORE=%HP_PIPREQS_IGNORE_DISPLAY%"
set "HP_PIPREQS_PHASE_RESULT="
set "HP_PIPREQS_LAST_LOG="
set "HP_PIPREQS_DIRECT_LOG=~pipreqs_direct.log"
if exist "%HP_PIPREQS_DIRECT_LOG%" del "%HP_PIPREQS_DIRECT_LOG%"
set "HP_PIPREQS_STAGE_LOG=~pipreqs_stage.log"
if exist "%HP_PIPREQS_STAGE_LOG%" del "%HP_PIPREQS_STAGE_LOG%"
set "HP_PIPREQS_STAGE_COPY_LOG=~pipreqs_stage_copy.log"
if exist "%HP_PIPREQS_STAGE_COPY_LOG%" del "%HP_PIPREQS_STAGE_COPY_LOG%"

set "HP_PIPREQS_CANON=pipreqs . --force --mode compat --savepath requirements.auto.txt"
set "HP_PIPREQS_CMD_LOG=pipreqs . --force --mode compat --savepath \"%HP_PIPREQS_TARGET%\"%HP_PIPREQS_IGNORE_DISPLAY%"
call :log "[INFO] pipreqs (direct) command: %HP_PIPREQS_CMD_LOG%"
echo Pipreqs command (direct): %HP_PIPREQS_CMD_LOG%

if defined HP_SKIP_PIPREQS (
  set "HP_PIPREQS_PHASE_RESULT=skipped"
  set "HP_PIPREQS_SUMMARY_PHASE=skipped"
  set "HP_PIPREQS_SUMMARY_NOTE=(pipreqs skipped for %HP_ENV_MODE% mode)"
  set "HP_PIPREQS_LAST_LOG=%HP_PIPREQS_DIRECT_LOG%"
  goto :after_pipreqs_run
)
if defined PEP723_ACTIVE (
  echo *** Using dependencies from PEP 723 metadata
  echo *** [INFO] Using PEP 723 inline dependency metadata
  echo *** [INFO] Dependency accuracy depends on script metadata correctness
  call :log "[INFO] Using PEP 723 inline dependency metadata"
  call :log "[INFO] DEP_SOURCE=pep723"
  call :log "[INFO] PEP723_USED=1"
  call :log "[INFO] DEP_LAYER_PEP723=1"
  call :log "[TRACE] dep source selected: pep723"
  set "DEP_SOURCE=pep723"
  set "DEP_LAYER_PEP723=1"
  copy /y "%PEP723_REQ%" "requirements.txt" >nul 2>&1
  if errorlevel 1 call :die "[ERROR] Could not stage PEP 723 requirements."
  copy /y "%PEP723_REQ%" "requirements.auto.txt" >nul 2>&1
  set "HP_PIPREQS_PHASE_RESULT=skipped"
  set "HP_PIPREQS_SUMMARY_PHASE=skipped"
  set "HP_PIPREQS_SUMMARY_NOTE=(pipreqs skipped: PEP 723 metadata)"
  set "HP_PIPREQS_LAST_LOG=%HP_PIPREQS_DIRECT_LOG%"
  goto :after_pipreqs_run
)
rem REQ-005: Only warn when no user-provided dep source was detected (no requirements.txt /
rem pyproject / PEP 723). If DEP_SOURCE is already set, pipreqs runs as an augmentation
rem pass but the user has explicit deps -- the WARN is misleading and must be suppressed.
if not defined DEP_SOURCE (
  echo *** [WARN] Dependencies were auto-detected (pipreqs)
  echo *** [WARN] Auto-detection may be incomplete or incorrect
  echo *** [INFO] Consider adding requirements.txt or PEP 723 metadata for reliability
  set "DEP_SOURCE=pipreqs"
) else (
  call :log "[TRACE] pipreqs augmenting %DEP_SOURCE% dep source; auto-detect WARN suppressed."
)

rem pipreqs invocation: uses "python -m pipreqs.pipreqs" NOT the console script (pipreqs command).
rem derived requirement: bootstrap determinism. The console script (pipreqs) relies on PATH being set
rem correctly after conda env activation, which is not guaranteed in the same shell session immediately
rem after environment creation. Using explicit Python interpreter + module bypasses PATH resolution and
rem works reliably in bootstrap contexts where shell state / PATH propagation is not fully initialized.
rem This is NOT a pipreqs API issue (the console script is the official API); it is a Windows batch
rem bootstrap sequencing issue. pipreqs is pinned to 0.4.13 permanently, so internal coupling is a
rem low-risk controlled assumption due to the pinned dependency version.
rem pipreqs flags are locked by CI (pipreqs.flags gate).
rem Rationale: compat mode for deterministic output; force overwrite; write to requirements.auto.txt (separate from committed requirements).
"%HP_PY%" -m pipreqs.pipreqs . --force --mode compat --savepath "%HP_PIPREQS_TARGET%" --ignore "%HP_PIPREQS_IGNORE%" > "%HP_PIPREQS_DIRECT_LOG%" 2>&1
:pipreqs_direct_done
set "HP_PIPREQS_LAST_LOG=%HP_PIPREQS_DIRECT_LOG%"
set "HP_PIPREQS_RC=%errorlevel%"
if "%HP_PIPREQS_RC%"=="0" if exist "%HP_PIPREQS_TARGET_WORK%" (
  rem Zero imports are valid: pipreqs exits 0 and may intentionally leave requirements.auto.txt empty.
  set "HP_PIPREQS_PHASE_RESULT=ok"
  set "HP_PIPREQS_SUMMARY_PHASE=direct"
  goto :after_pipreqs_run
)
rem ---- pipreqs result handling -------------------------------------------
rem RC=0  + file exists             -> OK  (deps found, or zero deps via exit 0)
rem RC!=0 + no file                 -> OK  (no imports: zero requirements)
rem RC!=0 + file empty (size=0)     -> OK  (no imports: zero requirements)
rem RC!=0 + file populated          -> FAIL (unexpected; fall through to staging)
rem
rem Notes:
rem - pipreqs returns non-zero when no imports are found: that is NOT an error
rem - We inspect file state, not just exit code, to distinguish zero-deps from crash
rem - If pipreqs crashed on a file WITH imports, output is absent/empty and this
rem   guard treats it as zero-requirements; downstream pip/tokenFound will expose it
rem - Staging path below acts as fallback for direct path quoting/path issues
rem -------------------------------------------------------------------------
rem Debug: log rc + file size so future diagnosis is trivial
set "HP_PIPREQS_SIZE=missing"
if exist "%HP_PIPREQS_TARGET_WORK%" for %%A in ("%HP_PIPREQS_TARGET_WORK%") do set "HP_PIPREQS_SIZE=%%~zA"
call :log "[DEBUG] pipreqs (direct) rc=%HP_PIPREQS_RC% size=%HP_PIPREQS_SIZE%"
rem Zero-requirements guard: accept non-zero exit only when output is absent or empty
if not "%HP_PIPREQS_RC%"=="0" (
  if not exist "%HP_PIPREQS_TARGET_WORK%" (
    set "HP_PIPREQS_PHASE_RESULT=ok"
    set "HP_PIPREQS_SUMMARY_PHASE=direct"
    set "HP_PIPREQS_SUMMARY_NOTE=(zero requirements: no imports found)"
    goto :after_pipreqs_run
  ) else (
    for %%A in ("%HP_PIPREQS_TARGET_WORK%") do if %%~zA EQU 0 (
      set "HP_PIPREQS_PHASE_RESULT=ok"
      set "HP_PIPREQS_SUMMARY_PHASE=direct"
      set "HP_PIPREQS_SUMMARY_NOTE=(zero requirements: no imports found)"
      goto :after_pipreqs_run
    )
  )
)

set "HP_TEMP_ROOT=%RUNNER_TEMP%"
if not defined HP_TEMP_ROOT set "HP_TEMP_ROOT=%TEMP%"
set "HP_PIPREQS_STAGE_ROOT=%HP_TEMP_ROOT%\pipreqs_stage"
set "HP_PIPREQS_STAGE_TARGET=%HP_PIPREQS_STAGE_ROOT%\requirements.auto.txt"
if exist "%HP_PIPREQS_STAGE_ROOT%" rd /s /q "%HP_PIPREQS_STAGE_ROOT%"
mkdir "%HP_PIPREQS_STAGE_ROOT%" >nul 2>&1
robocopy . "%HP_PIPREQS_STAGE_ROOT%" /E /NFL /NDL /NJH /NJS /NP ^
  /XD .git .github .venv venv env build dist __pycache__ tests ^
  /XF ~*.py > "%HP_PIPREQS_STAGE_COPY_LOG%" 2>&1
set "HP_PIPREQS_STAGE_COPY_RC=%errorlevel%"
if %HP_PIPREQS_STAGE_COPY_RC% GEQ 8 (
  set "HP_PIPREQS_PHASE_RESULT=fail"
  set "HP_PIPREQS_LAST_LOG=%HP_PIPREQS_STAGE_COPY_LOG%"
  set "HP_PIPREQS_SUMMARY_NOTE=(robocopy staging failed)"
  goto :after_pipreqs_run
)
set "HP_PIPREQS_SUMMARY_CMD_PATH=%HP_PIPREQS_STAGE_TARGET%"
set "HP_PIPREQS_SUMMARY_IGNORE="
if not exist "%HP_PIPREQS_STAGE_ROOT%\" (
    echo [WARN] pushd skipped, stage root missing: %HP_PIPREQS_STAGE_ROOT%
    set "HP_PIPREQS_PHASE_RESULT=fail"
    set "HP_PIPREQS_SUMMARY_NOTE=(stage root missing)"
    goto :after_pipreqs_run
)
pushd "%HP_PIPREQS_STAGE_ROOT%" >nul 2>&1
if errorlevel 1 (
    set "HP_PIPREQS_PHASE_RESULT=fail"
    set "HP_PIPREQS_SUMMARY_NOTE=(pushd to staging root failed)"
    goto :after_pipreqs_run
)
call :log "[INFO] pipreqs (staging) command: pipreqs . --force --mode compat --savepath ""%HP_PIPREQS_STAGE_TARGET%"""
echo Pipreqs command (staging): pipreqs . --force --mode compat --savepath "%HP_PIPREQS_STAGE_TARGET%"
:: pipreqs flags are locked by CI (pipreqs.flags gate).
:: Rationale: compat mode for deterministic output; force overwrite; write to requirements.auto.txt (separate from committed requirements).
"%HP_PY%" -m pipreqs.pipreqs . --force --mode compat --savepath "%HP_PIPREQS_STAGE_TARGET%" > "%HP_PIPREQS_STAGE_LOG%" 2>&1
set "HP_PIPREQS_RC=%errorlevel%"
popd >nul 2>&1
if errorlevel 1 call :log "[WARN] pipreqs staging: popd failed; CWD may not be restored."
set "HP_PIPREQS_LAST_LOG=%HP_PIPREQS_STAGE_LOG%"
if "%HP_PIPREQS_RC%"=="0" if exist "%HP_PIPREQS_STAGE_TARGET%" (
  rem Zero imports are valid: copy the staging file even when pipreqs produced an empty requirements list.
  copy /y "%HP_PIPREQS_STAGE_TARGET%" "%HP_PIPREQS_TARGET_WORK%" >nul 2>&1
  if errorlevel 1 (
    set "HP_PIPREQS_PHASE_RESULT=fail"
    set "HP_PIPREQS_SUMMARY_NOTE=(failed to copy staging output)"
    goto :after_pipreqs_run
  )
  set "HP_PIPREQS_PHASE_RESULT=ok"
  set "HP_PIPREQS_SUMMARY_PHASE=staging"
  set "HP_PIPREQS_SUMMARY_NOTE=(fallback after direct failure)"
  goto :after_pipreqs_run
)
rem Debug: log rc + file size for staging path
set "HP_PIPREQS_SIZE=missing"
if exist "%HP_PIPREQS_STAGE_TARGET%" for %%A in ("%HP_PIPREQS_STAGE_TARGET%") do set "HP_PIPREQS_SIZE=%%~zA"
call :log "[DEBUG] pipreqs (staging) rc=%HP_PIPREQS_RC% size=%HP_PIPREQS_SIZE%"
rem Zero-requirements guard for staging path
if not "%HP_PIPREQS_RC%"=="0" (
  if not exist "%HP_PIPREQS_STAGE_TARGET%" (
    set "HP_PIPREQS_PHASE_RESULT=ok"
    set "HP_PIPREQS_SUMMARY_PHASE=staging"
    set "HP_PIPREQS_SUMMARY_NOTE=(zero requirements: no imports found)"
    goto :after_pipreqs_run
  ) else (
    for %%A in ("%HP_PIPREQS_STAGE_TARGET%") do if %%~zA EQU 0 (
      set "HP_PIPREQS_PHASE_RESULT=ok"
      set "HP_PIPREQS_SUMMARY_PHASE=staging"
      set "HP_PIPREQS_SUMMARY_NOTE=(zero requirements: no imports found)"
      goto :after_pipreqs_run
    )
  )
)
if not defined HP_PIPREQS_SUMMARY_NOTE set "HP_PIPREQS_SUMMARY_NOTE=(staging pipreqs failed)"
set "HP_PIPREQS_PHASE_RESULT=fail"

:after_pipreqs_run
set "DEP_FINAL_COUNT=0"
if exist "requirements.txt" for /f "usebackq eol=# tokens=*" %%L in ("requirements.txt") do if not "%%L"=="" set /a DEP_FINAL_COUNT+=1
call :log "[INFO] DEP_RESOLUTION_STRATEGY=layered"
call :log "[INFO] DEP_FINAL_COUNT=%DEP_FINAL_COUNT%"
set "DEP_FINAL_COUNT="
if exist "%HP_PIPREQS_STAGE_ROOT%" rd /s /q "%HP_PIPREQS_STAGE_ROOT%"
set "HP_PIPREQS_TARGET=%HP_PIPREQS_TARGET_WORK%"
if "%HP_PIPREQS_PHASE_RESULT%"=="ok" (
  call :write_pipreqs_summary
) else (
  if /I "%HP_PIPREQS_PHASE_RESULT%"=="skipped" (
    if not defined HP_PIPREQS_SUMMARY_PHASE set "HP_PIPREQS_SUMMARY_PHASE=skipped"
    if not defined HP_PIPREQS_SUMMARY_NOTE set "HP_PIPREQS_SUMMARY_NOTE=(pipreqs skipped)"
    call :write_pipreqs_summary
  ) else (
    set "HP_PIPREQS_SUMMARY_PHASE=failed"
    if not defined HP_PIPREQS_SUMMARY_NOTE set "HP_PIPREQS_SUMMARY_NOTE=(pipreqs run failed)"
    set "HP_PIPREQS_FAILURE_LOG=%HP_PIPREQS_LAST_LOG%"
    call :write_pipreqs_summary
    rem G3 guardrail: pipreqs is discovery only; a failed scan must not block bootstrap.
    call :log "[WARN] pipreqs generation failed; continuing without auto-detected requirements."
  )
)
if not exist "%REQ%" if exist "requirements.auto.txt" (
  copy /y "requirements.auto.txt" "requirements.txt" >> "%LOG%" 2>&1
  if errorlevel 1 (
    echo *** Could not generate requirements.txt. Continuing without dependencies...
    call :log "[WARN] Failed to copy requirements.auto.txt to requirements.txt; continuing without dependency installation."
  )
)
echo (no diff: requirements files not both present) > "~pipreqs.diff.txt"
if exist "requirements.txt" if exist "requirements.auto.txt" (
  fc "requirements.txt" "requirements.auto.txt" > "~pipreqs.diff.txt" 2>&1
)
call :log "[INFO] REQ-005.5: dependency source diff computed -- ~pipreqs.diff.txt"
rem --- Dep-check fast path: skip conda install when all pipreqs packages are in the lock ---
rem derived requirement: skip the slow conda solver on repeat runs when the
rem environment lock file already contains every package pipreqs detected.
rem goto is used to avoid %errorlevel% parse-time expansion inside parenthesized blocks.
set "HP_DEP_SKIP="
set "HP_DEP_RESULT="
rem REQ-005.11: reset on every entry to this label (including REQ-009 provider-cascade
rem re-entry) so a stale HP_UV_INSTALL_OK from a previous, now-abandoned uv attempt can
rem never satisfy :pep723_writeback's confirmed-installed gate for an unrelated trigger.
set "HP_UV_INSTALL_OK="
if not "%HP_ENV_MODE%"=="conda" if not "%HP_ENV_MODE%"=="uv" goto :dep_check_done
call :emit_from_base64 "~dep_check.py" HP_DEP_CHECK
if errorlevel 1 goto :dep_check_done
"%HP_PY%" "~dep_check.py" > "~dep_check.txt" 2>> "%LOG%"
set "HP_DEP_RC=%errorlevel%"
for /f "usebackq delims=" %%D in ("~dep_check.txt") do set "HP_DEP_RESULT=%%D"
if exist "~dep_check.txt" del "~dep_check.txt" >nul 2>&1
if exist "~dep_check.py" del "~dep_check.py" >nul 2>&1
if not "%HP_DEP_RC%"=="0" goto :dep_check_done
if /I "%HP_DEP_RESULT%"=="skip" set "HP_DEP_SKIP=1"
if defined HP_DEP_SKIP call :log "[INFO] Dep-check: all pipreqs packages satisfied in lock; skipping conda install."
:dep_check_done
rem IMPORTANT: requirements.txt must always reflect the final dependency set passed to installer.
rem All source layers (PEP 723, pyproject, pipreqs) overwrite requirements.txt in-place above.
rem Do not bypass requirements.txt without updating the snapshot and installed-state logic below.
rem --- Snapshot resolved dependency input before install ---
if exist "~dependency_resolved.txt" del "~dependency_resolved.txt" >nul 2>&1
if exist "requirements.txt" (
  copy /y "requirements.txt" "~dependency_resolved.txt" >nul 2>&1
  if not errorlevel 1 call :log "[INFO] DEP_RESOLVED_FILE written: ~dependency_resolved.txt"
)
call :log "[INFO] DEP_RESOLVED_FROM=requirements.txt"
call :log "[INFO] DEP_INSTALL_SOURCE=requirements.txt"
call :log "[TRACE] dep install phase: start"
if exist "requirements.txt" (
  if exist "~reqs_conda.txt" del "~reqs_conda.txt"
  call :log "[TRACE] heuristic augmentation: ~prep_requirements.py"
  if "%HP_ENV_MODE%"=="conda" (
    "%CONDA_BASE_PY%" "~prep_requirements.py" "requirements.txt" >nul 2>> "%LOG%"
  ) else (
    "%HP_PY%" "~prep_requirements.py" "requirements.txt" >nul 2>> "%LOG%"
  )
  call :log "[TRACE] heuristic augmentation: complete"
  if "%HP_ENV_MODE%"=="conda" (
    if not defined HP_DEP_SKIP (
      call :log "[INSTALL] conda bulk from ~reqs_conda.txt"
      call :conda_bulk_install
      if errorlevel 1 (
        call :log "[INSTALL] conda per-pkg fallback"
        for /f "usebackq delims=" %%P in ("~reqs_conda.txt") do (
          call "%CONDA_BAT%" install -y -n "%ENVNAME%" --override-channels -c conda-forge %%P >> "%LOG%" 2>&1
        )
      )
    )
    call :log "[INSTALL] pip gap fill from requirements.txt"
    "%HP_PY%" -m pip install -r requirements.txt >> "%LOG%" 2>&1
    if errorlevel 1 (
      echo *** Warning: Some requirements may have failed to install.
      call :log "[WARN] pip install -r requirements.txt failed; some packages may be missing."
    )
  ) else if "%HP_ENV_MODE%"=="venv" (
    "%HP_PY%" -m pip install -r requirements.txt >> "%LOG%" 2>&1
    if errorlevel 1 (
      echo *** Warning: Some requirements may have failed to install.
      call :log "[WARN] pip install -r requirements.txt failed; some packages may be missing."
    )
  ) else if "%HP_ENV_MODE%"=="uv" (
    rem derived requirement: uv pip install targets the uv venv explicitly via --python.
    rem HP_DEP_SKIP is set by dep_check before this block; 'if not defined' evaluates at
    rem runtime so there is no block-parse-time expansion issue.
    if not defined HP_DEP_SKIP (
      "%HP_UV_EXE%" pip install --python "%HP_PY%" -r requirements.txt >> "%LOG%" 2>&1
      if errorlevel 1 (
        echo *** Warning: Some requirements may have failed to install.
        call :log "[WARN] uv pip install -r requirements.txt failed; some packages may be missing."
        set "UV_FALLBACK_REASON=dep_install_failed"
        call :log "[WARN] UV_FALLBACK reason=dep_install_failed"
      ) else (
        rem REQ-005.11: install fully succeeded; PEP 723 write-back may run for this round.
        set "HP_UV_INSTALL_OK=1"
      )
    ) else (
      rem REQ-005.11: HP_DEP_SKIP means the lock already satisfied every package -- still a
      rem confirmed-installed state, not a failure to distinguish from a genuine install.
      set "HP_UV_INSTALL_OK=1"
    )
    call :log "[INFO] UV_USED=1"
  ) else if "%HP_ENV_MODE%"=="embed" (
    rem REQ-009 Tier 5: embed is a private, bootstrapper-owned interpreter like venv, not a
    rem shared/uncontrolled one like system -- installing into it is exactly the point, so it
    rem must NOT fall into the system catch-all below (that branch deliberately skips install).
    "%HP_PY%" -m pip install -r requirements.txt >> "%LOG%" 2>&1
    if errorlevel 1 (
      echo *** Warning: Some requirements may have failed to install.
      call :log "[WARN] pip install -r requirements.txt failed; some packages may be missing."
    )
  ) else (
    call :log "[WARN] System fallback: skipping requirement installation."
  )
)
rem --- Capture installed package state via pip freeze ---
if exist "~dependency_installed.txt" del "~dependency_installed.txt" >nul 2>&1
if "%HP_ENV_MODE%"=="uv" (
  "%HP_UV_EXE%" pip freeze --python "%HP_PY%" > "~dependency_installed.txt" 2>nul
) else (
  "%HP_PY%" -m pip freeze > "~dependency_installed.txt" 2>nul
)
set "HP_DEP_INST_RC=%errorlevel%"
if "%HP_DEP_INST_RC%"=="0" call :log "[INFO] DEP_INSTALLED_CAPTURED=1"
if not "%HP_DEP_INST_RC%"=="0" (
  if exist "~dependency_installed.txt" del "~dependency_installed.txt" >nul 2>&1
  call :log "[WARN] DEP_INSTALLED_CAPTURE_FAILED=1"
)
set "HP_DEP_INST_RC="
rem --- Capture resolved environment snapshot ---
rem derived requirement: goto avoids %errorlevel% parse-time expansion that
rem would occur inside a parenthesized if-block (cmd.exe expands %var% for
rem the whole block at parse time, so set HP_LOCK_RC=%errorlevel% inside
rem if (...) always captures the pre-block errorlevel, not conda list's exit code).
if "%HP_ENV_MODE%"=="uv" (
  rem derived requirement: dep_check.py and selfapps_depcheck.ps1 expect
  rem ~environment.lock.txt regardless of env mode; reuse the pip freeze output
  rem already captured in ~dependency_installed.txt to avoid a second freeze call.
  if exist "~dependency_installed.txt" copy /y "~dependency_installed.txt" "~environment.lock.txt" >nul 2>&1
  if exist "~environment.lock.txt" call :log "[INFO] Environment snapshot written: ~environment.lock.txt"
  if not exist "~environment.lock.txt" (
    set "UV_FALLBACK_REASON=lock_failed"
    call :log "[WARN] UV_FALLBACK reason=lock_failed"
  )
  goto :lock_done
)
if not "%HP_ENV_MODE%"=="conda" goto :lock_done
call :log "[INFO] Capturing environment snapshot..."
call "%CONDA_BAT%" list -n "%ENVNAME%" --export > "~environment.lock.txt" 2>> "%LOG%"
set "HP_LOCK_RC=%errorlevel%"
if "%HP_LOCK_RC%"=="0" (
  for %%Z in ("~environment.lock.txt") do if %%~zZ GTR 0 (
    call :log "[INFO] Environment snapshot written: ~environment.lock.txt"
    goto :lock_done
  )
  call :log "[WARN] Environment snapshot: conda list succeeded but output is empty."
  if exist "~environment.lock.txt" del "~environment.lock.txt" >nul 2>&1
) else (
  call :log "[WARN] Environment snapshot failed (conda list rc=%HP_LOCK_RC%)."
  if exist "~environment.lock.txt" del "~environment.lock.txt" >nul 2>&1
)
:lock_done
rem REQ-005.11: fresh-install PEP 723 write-back trigger. Must run after the lock
rem snapshot above (HP_UV_INSTALL_OK is set during dependency install, further up
rem this same :after_env_mode_selection scope) and before pyvisa detection below.
call :pep723_writeback fresh
rem Detect pyvisa/visa usage so harness sees NI-VISA requirements

call :emit_from_base64 "~detect_visa.py" HP_DETECT_VISA
if errorlevel 1 call :die "[ERROR] Could not write ~detect_visa.py"
set "NEED_VISA=0"
if exist "~visa.flag" del "~visa.flag"
"%HP_PY%" "~detect_visa.py" > "~visa.flag" 2>> "%LOG%"
for /f "usebackq delims=" %%V in ("~visa.flag") do set "NEED_VISA=%%V"
if "%NEED_VISA%"=="1" (
  call :log "[INFO] Detected pyvisa/visa import; NI-VISA install may be required."
) else (
  call :log "[INFO] No pyvisa/visa imports detected."
)
if exist "~visa.flag" del "~visa.flag"

rem --- NI-VISA presence check and install (REQ-008) ---
rem derived requirement: NEED_VISA must be exactly "1"; any other value (0, empty, error)
rem skips install to avoid hanging CI on non-visa projects.
if not "%NEED_VISA%"=="1" (
  call :log "[VISA] skipped (not_required)"
  goto visa_done
)
rem REQ-008: allow disabling the NI-VISA install for debugging, even when pyvisa/visa is detected.
if "%HP_SKIP_NIVISA%"=="1" (
  call :log "[VISA] skipped (disabled)"
  goto visa_done
)
reg query "HKLM\SOFTWARE\National Instruments\NI-VISA" /v "CurrentVersion" >nul 2>&1
if not errorlevel 1 (
  call :log "[VISA] present"
  goto visa_done
)
set "NIVISA_INSTALLER=~ni-visa-runtime.exe"
set "HP_VISA_DLVIA=curl"
curl -L --silent --fail -o "%NIVISA_INSTALLER%" "https://download.ni.com/support/nipkg/products/ni-v/ni-visa/21.5/online/ni-visa_21.5_online.exe" 2>> "%LOG%"
if errorlevel 1 (
  set "HP_VISA_DLVIA=powershell"
  rem derived requirement: curl can leave a partial file on failure; delete before fallback
  rem so PowerShell does not find a corrupt file and skip its own download attempt.
  if exist "%NIVISA_INSTALLER%" del "%NIVISA_INSTALLER%" >nul 2>&1
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://download.ni.com/support/nipkg/products/ni-v/ni-visa/24.0/runtime/ni-visa-runtime_24.0.0_windows.exe' -OutFile '%NIVISA_INSTALLER%' -UseBasicParsing -ErrorAction Stop } catch { exit 1 }" 2>> "%LOG%"
)
if not exist "%NIVISA_INSTALLER%" (
  call :log "[VISA] install_failed (download)"
  goto visa_done
)
rem REQ-008 diagnostic: record the downloaded installer's provenance, size, and PE validity so a
rem non-zero installer exit code can be classified (blocked/redirected payload vs a real installer
rem that refused unattended install). These are read-only probes -- they never touch the install.
call :log "[VISA] download method: %HP_VISA_DLVIA%"
set "HP_VISA_DLSIZE=0"
for %%S in ("%NIVISA_INSTALLER%") do set "HP_VISA_DLSIZE=%%~zS"
call :log "[VISA] installer file size: %HP_VISA_DLSIZE% bytes"
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $fs=[System.IO.File]::OpenRead('%NIVISA_INSTALLER%'); $a=$fs.ReadByte(); $b=$fs.ReadByte(); $fs.Close(); if ($a -eq 77 -and $b -eq 90) { 'PE_OK' } else { 'NOT_PE' } } catch { 'PROBE_ERR' }" > "~visa_pe.txt" 2>nul
set "HP_VISA_PE="
if exist "~visa_pe.txt" for /f "usebackq delims=" %%P in ("~visa_pe.txt") do set "HP_VISA_PE=%%P"
if exist "~visa_pe.txt" del "~visa_pe.txt" >nul 2>&1
call :log "[VISA] installer PE check: %HP_VISA_PE%"
start /wait "" "%NIVISA_INSTALLER%" --quiet --accept-eulas --prevent-reboot --prevent-activation
set "HP_VISA_INSTALLER_RC=%ERRORLEVEL%"
rem derived requirement: capture the installer exit code so diagnostics can tell a hard failure
rem (non-zero rc) apart from a slow-but-progressing install (rc=0, registry not yet populated).
call :log "[VISA] installer exit code: %HP_VISA_INSTALLER_RC%"
rem derived requirement: NI installers may spawn child processes; poll the registry before declaring
rem post-install failure. Budget is configurable via HP_NIVISA_WAIT_SECS so a dedicated diagnostic
rem lane can wait out a slow (~30-45 min) NI-VISA install without slowing gating lanes. Default keeps
rem the original ~15s behavior (3 retries x ~5s); single-line ifs avoid parenthesized parse-time issues.
set "HP_VISA_PINGN=6"
set "HP_VISA_MAXRETRY=3"
if defined HP_NIVISA_WAIT_SECS set "HP_VISA_PINGN=31"
if defined HP_NIVISA_WAIT_SECS set /a HP_VISA_MAXRETRY=%HP_NIVISA_WAIT_SECS%/30
if %HP_VISA_MAXRETRY% lss 3 set "HP_VISA_MAXRETRY=3"
set "HP_VISA_RETRY=0"
:visa_post_check
reg query "HKLM\SOFTWARE\National Instruments\NI-VISA" /v "CurrentVersion" >nul 2>&1
if not errorlevel 1 (
  call :log "[VISA] install_success"
  goto visa_cleanup
)
set /a HP_VISA_RETRY+=1
if %HP_VISA_RETRY% lss %HP_VISA_MAXRETRY% (
  call :log "[VISA] post-check waiting; retry %HP_VISA_RETRY%/%HP_VISA_MAXRETRY% (installer_rc=%HP_VISA_INSTALLER_RC%)"
  ping -n %HP_VISA_PINGN% 127.0.0.1 >nul 2>&1
  goto visa_post_check
)
call :log "[VISA] install_failed (post_check_timeout) installer_rc=%HP_VISA_INSTALLER_RC%"
:visa_cleanup
if exist "%NIVISA_INSTALLER%" del "%NIVISA_INSTALLER%" >nul 2>&1
:visa_done

rem --- Write env state for fast path on next run ---
rem derived requirement: goto avoids %errorlevel% parse-time expansion inside
rem parenthesized if-blocks; same pattern as dep-check and lock-capture blocks.
call :emit_from_base64 "~env_state.py" HP_ENV_STATE
if errorlevel 1 goto :env_state_write_done
"%HP_PY%" "~env_state.py" --write >> "%LOG%" 2>&1
set "HP_ENV_STATE_WRITE_RC=%errorlevel%"
if exist "~env_state.py" del "~env_state.py" >nul 2>&1
if "%HP_ENV_STATE_WRITE_RC%"=="0" call :log "[INFO] Env state written: ~env.state.json"
if not "%HP_ENV_STATE_WRITE_RC%"=="0" call :log "[WARN] Env state write failed (rc=%HP_ENV_STATE_WRITE_RC%)."
set "HP_ENV_STATE_WRITE_RC="
:env_state_write_done
goto :after_env_bootstrap

:ci_skip_entry
call :log "[INFO] CI self-test: skipping environment bootstrap"
set "HP_ENTRY="
set "HP_CRUMB="
if exist "~entry.abs" del "~entry.abs"
rem --- stage helper ---
call :emit_from_base64 "~find_entry.py" HP_FIND_ENTRY
if errorlevel 1 call :die "[ERROR] CI skip: entry helper staging failed"
call :update_find_entry_abs
call :verify_find_entry_helper
if errorlevel 1 call :die "[ERROR] find_entry helper syntax error"

rem --- locate a Python ---
set "HP_SYS_PY=" & set "HP_SYS_PY_ARGS="
set "HP_SYS_PY_LOGGED="
where python >nul 2>&1 && set "HP_SYS_PY=python"
if not defined HP_SYS_PY (
  where py >nul 2>&1 && (set "HP_SYS_PY=py" & set "HP_SYS_PY_ARGS=-3")
)

if defined HP_SYS_PY for %%C in ("%HP_SYS_PY%") do set "HP_SYS_PY=%%~C"
if defined HP_SYS_PY_ARGS for %%A in ("%HP_SYS_PY_ARGS%") do set "HP_SYS_PY_ARGS=%%~A"

rem --- run helper and capture RELATIVE crumb ---
set "HP_CRUMB="
if not defined HP_SYS_PY goto :ci_skip_helper_done
rem derived requirement: use goto instead of if-block; DisableDelayedExpansion coalesces
rem the entire block at parse time, so %HP_CRUMB_FILE% (set mid-block) was empty when
rem used as a redirect target, causing "syntax of the command is incorrect" / exit 255.
rem derived requirement: CI observed `'python" "~find_entry.py' is not recognized` when
rem helper args were empty. Keep the helper invocation split so CMD never appends a stray
rem quote to the interpreter token, and route stdout through a file to avoid shell quoting drift.
if not defined HP_SYS_PY_LOGGED (
  if defined HP_SYS_PY_ARGS (
    >> "%LOG%" echo Helper command: "%HP_SYS_PY%" %HP_SYS_PY_ARGS% "%HP_FIND_ENTRY_ABS%"
  ) else (
    >> "%LOG%" echo Helper command: "%HP_SYS_PY%" "%HP_FIND_ENTRY_ABS%"
  )
  set "HP_SYS_PY_LOGGED=1"
)
rem derived requirement: CI skip jobs sometimes run from a borrowed working directory.
rem Normalize the helper root so helper discovery always executes from the bootstrapper tree.
set "HP_HELPER_ROOT=%HP_SCRIPT_ROOT%"
for %%R in ("%HP_HELPER_ROOT%") do set "HP_HELPER_ROOT=%%~fR"
if not defined HP_HELPER_ROOT set "HP_HELPER_ROOT=%CD%"
if not exist "%HP_HELPER_ROOT%" mkdir "%HP_HELPER_ROOT%" >nul 2>&1
set "HP_CHOOSER_ROOT=%HP_HELPER_ROOT%"
for %%R in ("%HP_HELPER_ROOT%tests") do if exist "%%~fR" set "HP_CHOOSER_ROOT=%%~fR"
rem derived requirement: the helper enumerates cwd *.py files; pivot into tests/ when present
rem so crumbs reference the self-test entry scripts without emitting "The system cannot find the path specified.".
for %%R in ("%HP_CHOOSER_ROOT%") do set "HP_CHOOSER_ROOT=%%~fR"
if not exist "%HP_CHOOSER_ROOT%" set "HP_CHOOSER_ROOT=%HP_HELPER_ROOT%"
set "HP_CRUMB_FILE=%HP_CHOOSER_ROOT%"
if not "%HP_CRUMB_FILE:~-1%"=="\" set "HP_CRUMB_FILE=%HP_CRUMB_FILE%\"
set "HP_CRUMB_FILE=%HP_CRUMB_FILE%~crumb.txt"
if exist "%HP_CRUMB_FILE%" del "%HP_CRUMB_FILE%" >nul 2>&1
set "HP_CHOOSER_PUSHD="
if exist "%HP_CHOOSER_ROOT%" (
  pushd "%HP_CHOOSER_ROOT%" >nul 2>&1
  set "HP_CHOOSER_PUSHD=1"
) else (
  echo [WARN] pushd skipped, chooser root missing: %HP_CHOOSER_ROOT%
)
if defined HP_SYS_PY_ARGS (
  "%HP_SYS_PY%" %HP_SYS_PY_ARGS% -m py_compile "%HP_FIND_ENTRY_ABS%" 1>nul 2>nul
) else (
  "%HP_SYS_PY%" -m py_compile "%HP_FIND_ENTRY_ABS%" 1>nul 2>nul
)
if defined HP_SYS_PY_ARGS (
  "%HP_SYS_PY%" %HP_SYS_PY_ARGS% "%HP_FIND_ENTRY_ABS%" > "%HP_CRUMB_FILE%" 2>> "%LOG%"
) else (
  "%HP_SYS_PY%" "%HP_FIND_ENTRY_ABS%" > "%HP_CRUMB_FILE%" 2>> "%LOG%"
)
if defined HP_CHOOSER_PUSHD (
  popd >nul 2>&1
  set "HP_CHOOSER_PUSHD="
)
if exist "%HP_CRUMB_FILE%" (
  for /f "usebackq delims=" %%L in ("%HP_CRUMB_FILE%") do if not defined HP_CRUMB set "HP_CRUMB=%%L"
  del "%HP_CRUMB_FILE%" >nul 2>&1
)
if /i not "%HP_CHOOSER_ROOT%"=="%HP_HELPER_ROOT%" (
  if defined HP_CRUMB set "HP_CRUMB=tests\%HP_CRUMB%"
)
:ci_skip_helper_done

if not defined HP_CRUMB (
  echo [INFO] CI skip: no entry script detected.
  goto :after_env_bootstrap
)

rem --- write breadcrumb EXACTLY (no trailing punctuation) ---
echo Chosen entry: %HP_CRUMB%
>> "%LOG%" echo Chosen entry: %HP_CRUMB%

rem optional: set HP_ENTRY if helper emitted an abs path file
if exist "~entry.abs" set /p HP_ENTRY=<"~entry.abs"
rem Helper now only prints the crumb; reuse it for optional smoke runs.
if not defined HP_ENTRY if defined HP_CRUMB set "HP_ENTRY=%HP_CRUMB%"

rem optional best-effort run; never install in skip mode
if defined HP_ENTRY if defined HP_SYS_PY (
  if defined HP_SYS_PY_ARGS (
    "%HP_SYS_PY%" %HP_SYS_PY_ARGS% "%HP_ENTRY%" > "~run.out.txt" 2>&1 || echo [WARN] CI skip: system Python non-zero
  ) else (
    "%HP_SYS_PY%" "%HP_ENTRY%" > "~run.out.txt" 2>&1 || echo [WARN] CI skip: system Python non-zero
  )
)
call :append_env_mode_row
goto :after_env_bootstrap

:after_env_bootstrap
if defined HP_CI_SKIP_ENV goto :after_env_skip
call :determine_entry "%~1"
if errorlevel 11 (
  call :write_status "error" 1 %PYCOUNT%
  exit /b 1
)
if errorlevel 1 call :die "[ERROR] Could not determine entry point"
if "%HP_ENTRY%"=="" (
  call :log "[INFO] No entry script detected; skipping PyInstaller packaging."
) else (
  call :run_entry_smoke
)

rem REQ-009/REQ-005.10 slice 3: if warnfix left dependencies unresolved under the current
rem provider AND the user approved (HP_CASCADE_APPROVED, set in :warnfix_cascade_detect),
rem re-attempt the dependency phase under the next REQ-009 provider tier. The per-tier
rem HP_CASCADE_TRIED_* guards inside :provider_cascade ensure a tier is never used as a
rem cascade source twice, so an unresolvable dependency exhausts the tiers and stops --
rem it never loops. Each re-attempt re-enters at :try_conda_create / :after_env_mode_selection.
if defined HP_CASCADE_APPROVED goto :provider_cascade
:after_cascade_decision
if /i "%HP_BOOTSTRAP_STATE%"=="ok" (
  call :write_status ok 0 %PYCOUNT%
) else (
  call :write_status "%HP_BOOTSTRAP_STATE%" 0 %PYCOUNT%
)
goto :success

:after_env_skip
call :write_status ok 0 %PYCOUNT%
goto :success

:success
rem derived requirement: skip write when DEP_SOURCE=unknown (EXE fast path / no-python-files paths
rem fire before dep resolution; preserve any existing dependency_source.txt from previous run).
if not "%DEP_SOURCE%"=="unknown" (
  echo dependency_source=%DEP_SOURCE%> "dependency_source.txt"
  echo *** [INFO] Dependency source logged to dependency_source.txt
)
rem REQ-016: show post-flight briefing when a full EXE build completed.
if not defined HP_FASTPATH_USED if exist "dist\%ENVNAME%.exe" (
  call :print_postflight_briefing
)
call :release_lock
rem REQ-016: retain terminal window on success so user can read the output.
if not defined HP_CI_LANE (
  pause
)
exit /b 0

:provider_cascade
rem REQ-009/REQ-005.10 slice 3: re-attempt the dependency phase under the next provider tier.
rem Dispatch is goto-based (no parenthesized interdependent sets) to avoid CMD parse-time
rem expansion traps. Each tier is marked HP_CASCADE_TRIED_<tier> the first time it is used as a
rem cascade source; a tier is never used twice, so tiers exhaust and the run stops (no loop).
rem HP_ENV_MODE only advances (uv -> conda -> embed -> venv -> system), so re-entry cannot
rem revisit a tier. conda and embed both front-load acquisition of a FRESH/pinned interpreter
rem before falling back to venv/system, which merely wrap whatever Python is already ambient on
rem the machine -- see docs/agent-interconnect.md "Standalone Python-download tier" for the
rem ordering rationale. NOTE: the :log messages below say "uv to conda" (not "uv -> conda") on
rem purpose -- :log echoes UNQUOTED, so a ">" in the message would be parsed as redirection and
rem eat the line (see docs/agent-lessons-learned.md). Do not "fix" these to arrows.
set "HP_CASCADE_APPROVED="
if /i "%HP_ENV_MODE%"=="uv" goto :cascade_from_uv
if /i "%HP_ENV_MODE%"=="conda" goto :cascade_from_conda
if /i "%HP_ENV_MODE%"=="embed" goto :cascade_from_embed
if /i "%HP_ENV_MODE%"=="venv" goto :cascade_from_venv
rem NOTE: no "system" case here, by design -- system is the absolute last resort (Tier 4 by
rem naming/history, REQ-014-gated), no cascade target beyond it. A re-entry with
rem HP_ENV_MODE=system falls straight through to the catch-all below, exactly as a re-entry
rem with HP_ENV_MODE=embed used to before this reorder (when embed was terminal).
call :log "[INFO] REQ-009: provider tiers exhausted after %HP_ENV_MODE%; keeping current build."
goto :after_cascade_decision

:cascade_from_uv
if defined HP_CASCADE_TRIED_UV goto :after_cascade_decision
set "HP_CASCADE_TRIED_UV=1"
call :log "[INFO] REQ-009: cascading provider uv to conda; re-attempting dependencies."
echo *** [INFO] Trying the next Python provider (conda) to resolve dependencies...
call :cascade_acquire_conda
if not defined CONDA_BAT goto :cascade_conda_unavailable
set "HP_UV_PROVIDING_PYTHON="
set "HP_ENV_MODE=conda"
set "ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%"
goto :try_conda_create
:cascade_conda_unavailable
call :log "[WARN] REQ-009: cascade to conda unavailable (Miniconda not installed); keeping current build."
goto :after_cascade_decision

:cascade_from_conda
if defined HP_CASCADE_TRIED_CONDA goto :after_cascade_decision
set "HP_CASCADE_TRIED_CONDA=1"
if "%HP_FORCE_CONDA_ONLY%"=="1" goto :cascade_condaonly_stop
call :log "[INFO] REQ-009: cascading provider conda to embed; re-attempting dependencies."
echo *** [INFO] Trying the next Python provider (embed) to resolve dependencies...
call :try_embed_fallback
if errorlevel 1 goto :cascade_embed_unavailable
goto :after_env_mode_selection
:cascade_condaonly_stop
call :log "[INFO] REQ-009: conda-only mode; cascade beyond conda suppressed; keeping current build."
goto :after_cascade_decision
:cascade_embed_unavailable
call :log "[WARN] REQ-009: cascade target embedded Python unavailable; keeping current build."
goto :after_cascade_decision

:cascade_from_embed
if defined HP_CASCADE_TRIED_EMBED goto :after_cascade_decision
set "HP_CASCADE_TRIED_EMBED=1"
call :log "[INFO] REQ-009: cascading provider embed to venv; re-attempting dependencies."
echo *** [INFO] Trying the next Python provider (venv) to resolve dependencies...
call :try_venv_fallback
if errorlevel 1 goto :cascade_venv_unavailable
goto :after_env_mode_selection
:cascade_venv_unavailable
call :log "[WARN] REQ-009: cascade target venv unavailable; keeping current build."
goto :after_cascade_decision

:cascade_from_venv
if defined HP_CASCADE_TRIED_VENV goto :after_cascade_decision
set "HP_CASCADE_TRIED_VENV=1"
rem REQ-009/REQ-014: system Python is Tier 4 (by naming/history; executed last in chain order);
rem reached in any run and gated only by the REQ-014 consent prompt inside :try_system_fallback
rem (no env flag). A decline keeps the current build.
call :log "[INFO] REQ-009: cascading provider venv to system; re-attempting dependencies."
call :try_system_fallback
if errorlevel 1 goto :cascade_system_unavailable
goto :after_env_mode_selection
:cascade_system_unavailable
call :log "[WARN] REQ-009: cascade target system Python unavailable; keeping current build."
goto :after_cascade_decision

:cascade_acquire_conda
rem REQ-009 slice 3: a uv-first run skipped Miniconda; acquire it on demand for a uv->conda
rem cascade. MINICONDA_ROOT / CONDA_MAIN / CONDA_ALT are already set (near line 410) even in
rem uv-first runs, so :select_conda_bat and :try_conda_install work without further setup.
call :select_conda_bat
if defined CONDA_BAT goto :eof
echo [INFO] Installing Miniconda into "%MINICONDA_ROOT%"...
set "HP_CONDA_JUST_INSTALLED=1"
call :download_miniconda_exe
if exist "%TEMP%\miniconda.exe" call :try_conda_install
if exist "%TEMP%\miniconda.exe" del "%TEMP%\miniconda.exe" >nul 2>&1
call :select_conda_bat
goto :eof

:count_python
set "NAME=%~1"
if "%NAME%"=="" exit /b 0
if "%NAME:~0,1%"=="~" exit /b 0
set /a PYCOUNT+=1 >nul
exit /b 0

:select_conda_bat
set "CONDA_BAT="
if exist "%CONDA_MAIN%" set "CONDA_BAT=%CONDA_MAIN%"
if not defined CONDA_BAT if exist "%CONDA_ALT%" set "CONDA_BAT=%CONDA_ALT%"
if defined CONDA_BAT if not exist "%CONDA_BAT%" set "CONDA_BAT="
exit /b 0

:download_miniconda_exe
set "HP_MINICONDA_ACTIVE_URL=%HP_MINICONDA_URL%"
if "%HP_TEST_CONDA_DL_FALLBACK%"=="1" if not defined HP_CONDA_DL_INJECTED set "HP_MINICONDA_ACTIVE_URL=https://miniconda-test-fail.invalid/Miniconda3-latest-Windows-x86_64.exe"
if "%HP_OFFLINE_MODE%"=="1" (
  call :log "[INFO] REQ-013: Offline mode: skipping Miniconda download."
  goto :eof
)
call :log "[INFO] Downloading Miniconda from %HP_MINICONDA_ACTIVE_URL%..."
curl --fail -L --retry 3 --retry-delay 5 --max-time 120 "%HP_MINICONDA_ACTIVE_URL%" -o "%TEMP%\miniconda.exe" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%TEMP%\miniconda.exe" goto :eof
echo *** curl download failed, trying PowerShell...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%HP_MINICONDA_ACTIVE_URL%' -OutFile '%TEMP%\miniconda.exe' -UseBasicParsing } catch { exit 1 }" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%TEMP%\miniconda.exe" goto :eof
if exist "%TEMP%\miniconda.exe" del "%TEMP%\miniconda.exe" >nul 2>&1
rem REQ-013: primary download failed; check connectivity before trying fallback.
rem Skip connectivity check when HP_TEST_CONDA_DL_FALLBACK=1 (failure was intentional).
if not "%HP_TEST_CONDA_DL_FALLBACK%"=="1" call :check_net_after_dl_fail
if "%HP_OFFLINE_MODE%"=="1" goto :eof
if defined HP_CONDA_DL_INJECTED (
  call :log "[ERROR] Injected HP_MINICONDA_URL failed; not trying fallback."
  goto :eof
)
call :log "[INFO] Trying fallback Miniconda URL: %HP_MINICONDA_FALLBACK_URL%..."
curl --fail -L --retry 3 --retry-delay 5 --max-time 120 "%HP_MINICONDA_FALLBACK_URL%" -o "%TEMP%\miniconda.exe" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%TEMP%\miniconda.exe" (
  call :log "[INFO] Miniconda download succeeded from fallback URL."
  goto :eof
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%HP_MINICONDA_FALLBACK_URL%' -OutFile '%TEMP%\miniconda.exe' -UseBasicParsing } catch { exit 1 }" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%TEMP%\miniconda.exe" (
  call :log "[INFO] Miniconda download succeeded from fallback URL."
  goto :eof
)
call :log "[WARN] Miniconda: all download URLs failed."
goto :eof

:download_get_pip
rem REQ-023b: fetches get-pip.py so the venv fallback tier can bootstrap pip after a
rem --without-pip venv creation (see :try_venv_fallback). Sets HP_GETPIP_PY to the downloaded
rem file path on success; leaves it undefined/absent on failure so the caller can detect it via
rem "if not exist". No interactive connectivity gate here (unlike :download_miniconda_exe's use
rem of :check_net_after_dl_fail) -- this runs deep inside a fallback tier where the zero-friction
rem design intent reserves the one interactive prompt for the REQ-014 system-Python consent gate;
rem a plain download failure here should silently decline the tier, not stop to ask the user.
set "HP_GETPIP_PY="
rem The HP_TEST_FORCE_VENV_CREATE_FAIL / HP_TEST_FORCE_EMBED_REAL exceptions below let CI
rem exercise this real download path while still using HP_OFFLINE_MODE=1 to cheaply skip
rem unrelated downloads (Miniconda, the embed zip's own earlier PowerShell-stage download)
rem elsewhere in the same test run -- neither flag weakens real-user offline protection, since
rem they are never set outside CI coverage.
set "HP_GETPIP_SKIP_OFFLINE=1"
if "%HP_TEST_FORCE_VENV_CREATE_FAIL%"=="1" set "HP_GETPIP_SKIP_OFFLINE="
if "%HP_TEST_FORCE_EMBED_REAL%"=="1" set "HP_GETPIP_SKIP_OFFLINE="
if "%HP_OFFLINE_MODE%"=="1" if defined HP_GETPIP_SKIP_OFFLINE (
  call :log "[INFO] REQ-013: Offline mode: skipping get-pip.py download."
  goto :eof
)
call :log "[INFO] Downloading get-pip.py from %HP_GETPIP_URL%..."
curl --fail -L --retry 3 --retry-delay 5 --max-time 120 "%HP_GETPIP_URL%" -o "%TEMP%\get-pip.py" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%TEMP%\get-pip.py" (
  set "HP_GETPIP_PY=%TEMP%\get-pip.py"
  goto :eof
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%HP_GETPIP_URL%' -OutFile '%TEMP%\get-pip.py' -UseBasicParsing } catch { exit 1 }" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%TEMP%\get-pip.py" (
  set "HP_GETPIP_PY=%TEMP%\get-pip.py"
  goto :eof
)
if exist "%TEMP%\get-pip.py" del "%TEMP%\get-pip.py" >nul 2>&1
call :log "[INFO] Trying fallback get-pip.py URL: %HP_GETPIP_FALLBACK_URL%..."
curl --fail -L --retry 3 --retry-delay 5 --max-time 120 "%HP_GETPIP_FALLBACK_URL%" -o "%TEMP%\get-pip.py" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%TEMP%\get-pip.py" (
  call :log "[INFO] get-pip.py download succeeded from fallback URL."
  set "HP_GETPIP_PY=%TEMP%\get-pip.py"
  goto :eof
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%HP_GETPIP_FALLBACK_URL%' -OutFile '%TEMP%\get-pip.py' -UseBasicParsing } catch { exit 1 }" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%TEMP%\get-pip.py" (
  call :log "[INFO] get-pip.py download succeeded from fallback URL."
  set "HP_GETPIP_PY=%TEMP%\get-pip.py"
  goto :eof
)
call :log "[WARN] get-pip.py: all download URLs failed."
goto :eof

:handle_conda_failure
set "HP_FAIL_MSG=%~1"
if not "%HP_FAIL_MSG%"=="" call :log "%HP_FAIL_MSG%"

if "%HP_FORCE_CONDA_ONLY%"=="1" (
  rem derived requirement: the dedicated conda CI slice must surface conda failures instead of hiding behind venv/system fallbacks.
  call :log "[INFO] Conda-only mode: skipping fallback attempts."
  exit /b 0
)

rem REQ-009 (reordered): embedded Python (Tier 5 by naming/history, executed 3rd since this
rem reorder) is attempted immediately after conda fails, ahead of venv/system -- so a user who
rem pinned a newer-than-ambient Python version via runtime.txt/pyproject.toml still gets it via
rem a fresh checksummed python.org download, before falling back to a tier that just wraps
rem whatever's already on the machine. No consent gate (see :try_embed_fallback's header
rem comment for why). See docs/agent-interconnect.md "Standalone Python-download tier" for the
rem full ordering rationale.
call :try_embed_fallback
if not errorlevel 1 (
  set "HP_ENV_READY=1"
  exit /b 0
)
rem REQ-009: venv fallback is attempted when conda and embed both fail; HP_ALLOW_VENV_FALLBACK
rem is deprecated/ignored.
call :try_venv_fallback
if not errorlevel 1 (
  set "HP_ENV_READY=1"
  exit /b 0
)
rem REQ-009/REQ-014: system Python is Tier 4 (by naming/history) and the absolute last resort --
rem the only tier gated by the REQ-014 consent prompt (touches the user's real environment), so
rem it stays final regardless of embed's move. HP_ALLOW_SYSTEM_FALLBACK is deprecated/ignored.
call :try_system_fallback
if not errorlevel 1 (
  set "HP_ENV_READY=1"
  exit /b 0
)
exit /b 0

:try_venv_fallback
call :log "[WARN] Attempting venv fallback..."
if "%HP_TEST_FORCE_VENV_FAIL%"=="1" (
  call :log "[TEST] HP_TEST_FORCE_VENV_FAIL: simulating venv creation failure."
  exit /b 1
)
call :resolve_system_python
if errorlevel 1 (
  call :log "[WARN] venv fallback: system Python not found."
  exit /b 1
)
if exist ".\.venv" rd /s /q ".\.venv" >nul 2>&1
if "%HP_TEST_FORCE_VENV_CREATE_FAIL%"=="1" goto :venv_create_retry
if defined HP_SYS_ARGS (
  "%HP_SYS_CMD%" %HP_SYS_ARGS% -m venv .\.venv >> "%LOG%" 2>&1
) else (
  "%HP_SYS_CMD%" -m venv .\.venv >> "%LOG%" 2>&1
)
if not errorlevel 1 goto :venv_create_ok
rem REQ-023b: "python -m venv" (which requires ensurepip) can fail outright on a stripped-down
rem host Python that is missing ensurepip -- a commonly cited real-world failure mode. Retry
rem once with --without-pip (which does not need ensurepip) and manually bootstrap pip via
rem get-pip.py, mirroring the existing Miniconda/uv download-with-fallback pattern
rem (:download_get_pip). Goto-based per "Provider-cascade dispatch is goto-based on purpose" in
rem docs/agent-lessons-learned.md.
:venv_create_retry
call :log "[WARN] venv fallback: python -m venv failed; retrying once with --without-pip."
if exist ".\.venv" rd /s /q ".\.venv" >nul 2>&1
if defined HP_SYS_ARGS (
  "%HP_SYS_CMD%" %HP_SYS_ARGS% -m venv .\.venv --without-pip >> "%LOG%" 2>&1
) else (
  "%HP_SYS_CMD%" -m venv .\.venv --without-pip >> "%LOG%" 2>&1
)
if errorlevel 1 (
  call :log "[WARN] venv fallback: python -m venv --without-pip also failed."
  exit /b 1
)
set "HP_PY=%CD%\.venv\Scripts\python.exe"
if not exist "%HP_PY%" (
  call :log "[WARN] venv fallback: interpreter missing after --without-pip creation."
  exit /b 1
)
call :download_get_pip
if not exist "%HP_GETPIP_PY%" (
  call :log "[WARN] venv fallback: get-pip.py download failed; venv has no pip."
  exit /b 1
)
"%HP_PY%" "%HP_GETPIP_PY%" >> "%LOG%" 2>&1
if errorlevel 1 (
  del "%HP_GETPIP_PY%" >nul 2>&1
  call :log "[WARN] venv fallback: get-pip.py bootstrap failed."
  exit /b 1
)
del "%HP_GETPIP_PY%" >nul 2>&1
call :log "[INFO] venv fallback: pip bootstrapped successfully via get-pip.py."
goto :venv_create_pip_ready
:venv_create_ok
set "HP_PY=%CD%\.venv\Scripts\python.exe"
if not exist "%HP_PY%" (
  call :log "[WARN] venv fallback: interpreter missing after creation."
  exit /b 1
)
:venv_create_pip_ready
rem REQ-023: canary probe -- a venv can be "created" (directory + exe present) yet still be
rem non-functional (missing DLLs, broken symlinks, execution-policy blocks). Verify the fresh
rem interpreter actually runs before declaring success, so a silently broken venv doesn't reach
rem PyInstaller only to fail later with a more confusing error. Goto-based (not nested inside
rem an if/else block) per "Provider-cascade dispatch is goto-based on purpose" in
rem docs/agent-lessons-learned.md, so the probe call + %ERRORLEVEL% read is never frozen by
rem cmd's parse-time %VAR% expansion.
if "%HP_TEST_FORCE_VENV_CANARY_FAIL%"=="1" goto :venv_canary_fail
"%HP_PY%" -c "import sys" >nul 2>&1
if errorlevel 1 goto :venv_canary_fail
goto :venv_canary_ok
:venv_canary_fail
call :log "[WARN] venv fallback: interpreter created but failed canary probe (import sys)."
rem derived requirement: HP_PY was set above to the venv interpreter path in preparation for
rem success, but a failed canary probe must not leak it forward -- a later gate
rem (:after_env_mode_selection's "if not defined HP_PY") would otherwise treat this failed tier
rem as if a real provider had been selected, silently proceeding with a broken interpreter
rem instead of reaching :die. Exact mirror of the :try_system_fallback fix. See
rem docs/agent-lessons-learned.md "A declined/failed fallback tier must clear HP_PY".
set "HP_PY="
exit /b 1
:venv_canary_ok
set "HP_ENV_MODE=venv"
set "HP_BOOTSTRAP_STATE=venv_env"
set "HP_SKIP_PIPREQS="
call :log "[INFO] venv fallback ready: %HP_PY%"
call :log "[BOOT] REQ-009: Selected Python provider: Local venv (fallback)."
exit /b 0

:try_system_fallback
call :log "[WARN] Attempting system Python fallback (degraded)..."
call :resolve_system_python
if errorlevel 1 (
  call :log "[WARN] system fallback: interpreter not available."
  exit /b 1
)
set "HP_PY=%HP_SYS_EXE%"
if not exist "%HP_PY%" (
  call :log "[WARN] system fallback: resolved interpreter path missing."
  set "HP_PY="
  exit /b 1
)
rem REQ-014: consent gate before using global system Python.
call :system_python_consent_gate
if errorlevel 1 (
  call :log "[INFO] REQ-014: System Python fallback aborted: consent not granted."
  rem derived requirement: HP_PY was set above to prepare for a possible accept, but
  rem a decline must not leak it forward -- a later gate (:after_env_mode_selection's
  rem "if not defined HP_PY") would otherwise treat this exhausted tier as if a real
  rem provider had been selected, silently proceeding with a stale interpreter path
  rem instead of reaching :die. See docs/agent-lessons-learned.md.
  set "HP_PY="
  exit /b 1
)
set "HP_ENV_MODE=system"
set "HP_BOOTSTRAP_STATE=degraded_env"
set "HP_SKIP_PIPREQS=1"
call :log "[INFO] System fallback using %HP_PY%"
call :log "[BOOT] REQ-009: Selected Python provider: System Python (degraded)."
exit /b 0

:resolve_system_python
set "HP_SYS_CMD="
set "HP_SYS_ARGS="
set "HP_SYS_EXE="
where python >nul 2>&1 && set "HP_SYS_CMD=python"
if not defined HP_SYS_CMD (
  where py >nul 2>&1 && (set "HP_SYS_CMD=py" & set "HP_SYS_ARGS=-3")
)
if not defined HP_SYS_CMD exit /b 1
set "HP_SYS_TMP=~sys_exe.txt"
if exist "%HP_SYS_TMP%" del "%HP_SYS_TMP%" >nul 2>&1
if defined HP_SYS_ARGS (
  "%HP_SYS_CMD%" %HP_SYS_ARGS% -c "import sys;print(sys.executable)" > "%HP_SYS_TMP%" 2>nul
) else (
  "%HP_SYS_CMD%" -c "import sys;print(sys.executable)" > "%HP_SYS_TMP%" 2>nul
)
if exist "%HP_SYS_TMP%" (
  set /p HP_SYS_EXE=<"%HP_SYS_TMP%"
  del "%HP_SYS_TMP%" >nul 2>&1
)
if not defined HP_SYS_EXE exit /b 1
exit /b 0

:try_embed_fallback
rem REQ-009 Tier 5: last-resort fallback when uv, conda, venv, and system all failed (or no
rem ambient interpreter exists at all). Unlike system Python, embed is a private, checksummed,
rem bootstrapper-controlled extraction -- no REQ-014-style consent gate, matching venv's
rem zero-friction treatment, not system's. Two stages: PowerShell (~embed_extract.ps1) always
rem fetches ONE hardcoded "latest" version with no per-request branching; Python
rem (~embed_pyver_check.py), running under that fresh interpreter, checks PYSPEC (already
rem computed earlier by ~detect_python.py -- the same value uv/conda already honor) and re-fetches
rem a different version via its own urllib/hashlib/zipfile if requested. See
rem docs/agent-interconnect.md "Standalone Python-download tier" for the full design rationale,
rem including why this is deliberately NOT all-PowerShell.
call :log "[WARN] Attempting embedded Python download (REQ-009 Tier 5)..."
if "%HP_TEST_FORCE_EMBED_FAIL%"=="1" (
  call :log "[TEST] HP_TEST_FORCE_EMBED_FAIL: simulating embed tier failure."
  exit /b 1
)
rem derived requirement: HP_TEST_FORCE_EMBED_REAL punches a narrow hole through the offline
rem gate for this tier only, mirroring HP_TEST_FORCE_VENV_CREATE_FAIL's exception for
rem :download_get_pip -- lets CI exercise the real embed download while HP_OFFLINE_MODE=1 still
rem blocks the earlier uv/conda/venv tiers' unrelated downloads in the same test run.
if "%HP_OFFLINE_MODE%"=="1" if not "%HP_TEST_FORCE_EMBED_REAL%"=="1" (
  call :log "[WARN] embed fallback: offline mode; cannot download embedded Python."
  exit /b 1
)
set "HP_EMBED_URL=https://www.python.org/ftp/python/%HP_EMBED_LATEST_PATCH%/python-%HP_EMBED_LATEST_PATCH%-embed-amd64.zip"
set "HP_EMBED_ZIP=%TEMP%\python-%HP_EMBED_LATEST_PATCH%-embed-amd64.zip"
set "HP_EMBED_DIR=%HP_SCRIPT_ROOT%~embed_python"
rem derived requirement: a single retry of the WHOLE download+verify cycle on either a download
rem failure or a checksum mismatch -- mirrors the existing transient-network-retry pattern used
rem by :try_conda_create/:conda_bulk_install (REQ-022) elsewhere in this file. A checksum mismatch
rem here does not necessarily mean a bad pin; it can mean a truncated/corrupted download, so
rem redownloading (not just re-verifying) is the correct remedy. Goto-based, not nested inside a
rem parenthesized if/else, per "Provider-cascade dispatch is goto-based on purpose" in
rem docs/agent-lessons-learned.md.
set "HP_EMBED_DL_ATTEMPT=0"
:embed_dl_retry
set /a HP_EMBED_DL_ATTEMPT+=1
if exist "%HP_EMBED_ZIP%" del "%HP_EMBED_ZIP%" >nul 2>&1
call :log "[INFO] Downloading embedded Python %HP_EMBED_LATEST_PATCH% from %HP_EMBED_URL%..."
curl --fail -L --retry 3 --retry-delay 5 --max-time 120 "%HP_EMBED_URL%" -o "%HP_EMBED_ZIP%" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%HP_EMBED_ZIP%" goto :embed_dl_ok
echo *** curl download failed, trying PowerShell...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%HP_EMBED_URL%' -OutFile '%HP_EMBED_ZIP%' -UseBasicParsing } catch { exit 1 }" >> "%LOG%" 2>&1
if not errorlevel 1 if exist "%HP_EMBED_ZIP%" goto :embed_dl_ok
if %HP_EMBED_DL_ATTEMPT% LSS 2 (
  call :log "[WARN] embed fallback: download failed; retrying once."
  goto :embed_dl_retry
)
call :log "[WARN] embed fallback: download failed (both curl and PowerShell)."
exit /b 1
:embed_dl_ok
call :emit_from_base64 "~embed_extract.ps1" HP_EMBED_EXTRACT
if errorlevel 1 (
  call :log "[WARN] embed fallback: could not write ~embed_extract.ps1."
  if exist "%HP_EMBED_ZIP%" del "%HP_EMBED_ZIP%" >nul 2>&1
  exit /b 1
)
set "HP_EMBED_PY="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -File "~embed_extract.ps1" "%HP_EMBED_ZIP%" "%HP_EMBED_LATEST_SHA256%" "%HP_EMBED_DIR%" 2^>^> "%LOG%"`) do set "HP_EMBED_PY=%%P"
if exist "~embed_extract.ps1" del "~embed_extract.ps1" >nul 2>&1
if exist "%HP_EMBED_ZIP%" del "%HP_EMBED_ZIP%" >nul 2>&1
if not exist "%HP_EMBED_PY%" (
  if %HP_EMBED_DL_ATTEMPT% LSS 2 (
    call :log "[WARN] embed fallback: checksum verification or extraction failed; retrying download once."
    goto :embed_dl_retry
  )
  call :log "[WARN] embed fallback: checksum verification or extraction failed."
  exit /b 1
)
call :log "[INFO] embed fallback: %HP_EMBED_LATEST_PATCH% extracted and verified."

rem --- Python stage: only place per-request version logic lives (deliberately not PowerShell
rem a second time). A failure here is non-fatal -- the "latest" interpreter from the stage above
rem is kept and used as-is; only a genuine version *mismatch* is lost, not the whole tier.
rem derived requirement: this block used to be one big parenthesized "if not errorlevel 1 ( ... )"
rem block. A for /f loop inside it set HP_EMBED_SWAP_DIR/_TAG/_MINOR, and code later in the SAME
rem block read %HP_EMBED_SWAP_DIR% to decide whether to swap -- but CMD's parse-time %VAR%
rem expansion substitutes every %VAR% in a parenthesized block using the value from BEFORE the
rem block began, not a value a for /f loop set earlier in the same block's own execution. Since
rem HP_EMBED_SWAP_DIR was never set before this point, that read was always empty, so the swap
rem NEVER executed regardless of what the Python stage actually requested -- the entire
rem "pull latest, then swap to the user's requested version" feature was dead code. Fixed via
rem goto-based dispatch (see "Provider-cascade dispatch is goto-based on purpose" in
rem docs/agent-lessons-learned.md) so every %VAR% read below reflects its true runtime value.
call :emit_from_base64 "~embed_pyver_check.py" HP_EMBED_PYVER_CHECK
if errorlevel 1 goto :embed_pyver_check_skip
set "HP_EMBED_CHECK_OUT=~embed_pyver_check.txt"
if exist "%HP_EMBED_CHECK_OUT%" del "%HP_EMBED_CHECK_OUT%" >nul 2>&1
"%HP_EMBED_PY%" "~embed_pyver_check.py" "%HP_EMBED_DIR%" > "%HP_EMBED_CHECK_OUT%" 2>> "%LOG%"
if exist "~embed_pyver_check.py" del "~embed_pyver_check.py" >nul 2>&1
set "HP_EMBED_SWAP_TAG="
set "HP_EMBED_SWAP_MINOR="
set "HP_EMBED_SWAP_DIR="
for /f "usebackq tokens=1,2,3 delims=|" %%A in ("%HP_EMBED_CHECK_OUT%") do (
  set "HP_EMBED_SWAP_TAG=%%A"
  set "HP_EMBED_SWAP_MINOR=%%B"
  set "HP_EMBED_SWAP_DIR=%%C"
)
if exist "%HP_EMBED_CHECK_OUT%" del "%HP_EMBED_CHECK_OUT%" >nul 2>&1
rem derived requirement: the version-check process (the "%HP_EMBED_PY%" call above) has
rem already fully exited by this point, so its file locks on HP_EMBED_DIR are released and
rem it is now safe to replace that directory -- swapping while that process was still running
rem would fail (Windows will not let a process delete/replace the files it is executing from),
rem which is exactly why the Python stage extracted into a sibling _swap directory instead of
rem overwriting HP_EMBED_DIR itself. See docs/agent-interconnect.md.
if not defined HP_EMBED_SWAP_DIR goto :embed_pyver_check_tagcheck
if not exist "%HP_EMBED_SWAP_DIR%\python.exe" goto :embed_pyver_check_tagcheck
rem derived requirement: rd /s /q can return before an AV/indexer file handle on HP_EMBED_DIR
rem fully releases, causing the immediately-following move /y to fail (a real, if low-severity,
rem Windows deletion race). Already failed safely before this change (checked python.exe exists
rem after, logged WARN, tier failed cleanly) -- this just retries the pair up to 3 total attempts
rem with a short pause between, so a rare transient lock doesn't needlessly fail the last-resort
rem tier. Uses ping (not timeout /t) for the pause -- this file already has a proven-safe idiom
rem for exactly this at line 1461's VISA-detection delay; see docs/agent-lessons-learned.md.
set "HP_EMBED_SWAP_ATTEMPT=0"
:embed_swap_retry
set /a HP_EMBED_SWAP_ATTEMPT+=1
rd /s /q "%HP_EMBED_DIR%" >nul 2>&1
move /y "%HP_EMBED_SWAP_DIR%" "%HP_EMBED_DIR%" >nul 2>&1
if exist "%HP_EMBED_DIR%\python.exe" (
  call :log "[INFO] embed fallback: swapped to requested Python %HP_EMBED_SWAP_MINOR%."
  goto :embed_pyver_check_tagcheck
)
if %HP_EMBED_SWAP_ATTEMPT% LSS 3 (
  ping -n 2 127.0.0.1 >nul 2>&1
  goto :embed_swap_retry
)
call :log "[WARN] embed fallback: swap move failed; interpreter may be missing."
:embed_pyver_check_tagcheck
if /i "%HP_EMBED_SWAP_TAG%"=="fellback" call :log "[WARN] REQ-009: requested Python not in embed table; using %HP_EMBED_SWAP_MINOR% instead."
:embed_pyver_check_skip
set "HP_EMBED_PY=%HP_EMBED_DIR%\python.exe"
if not exist "%HP_EMBED_PY%" (
  call :log "[WARN] embed fallback: interpreter missing after version-check stage."
  exit /b 1
)

rem --- bootstrap pip via get-pip.py (reuses the existing REQ-023b download) ---
call :download_get_pip
if not exist "%HP_GETPIP_PY%" (
  call :log "[WARN] embed fallback: get-pip.py download failed."
  exit /b 1
)
"%HP_EMBED_PY%" "%HP_GETPIP_PY%" >> "%LOG%" 2>&1
if errorlevel 1 (
  del "%HP_GETPIP_PY%" >nul 2>&1
  call :log "[WARN] embed fallback: get-pip.py bootstrap failed."
  exit /b 1
)
del "%HP_GETPIP_PY%" >nul 2>&1

rem --- canary probe (matches REQ-023's venv canary probe) ---
"%HP_EMBED_PY%" -c "import sys, pip" >nul 2>&1
if errorlevel 1 (
  call :log "[WARN] embed fallback: interpreter created but failed canary probe (import sys, pip)."
  exit /b 1
)

set "HP_ENV_MODE=embed"
set "HP_PY=%HP_EMBED_PY%"
set "HP_BOOTSTRAP_STATE=embed_env"
set "HP_SKIP_PIPREQS="
call :log "[INFO] embed fallback ready: %HP_PY%"
call :log "[BOOT] REQ-009: Selected Python provider: Embedded Python (python.org)."
exit /b 0

:append_env_mode_row
if not defined HP_NDJSON exit /b 0
if not defined HP_PY exit /b 0
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$mode = [Environment]::GetEnvironmentVariable('HP_ENV_MODE');" ^
  "$py = [Environment]::GetEnvironmentVariable('HP_PY');" ^
  "if (-not $mode) { $mode = 'unknown' }" ^
  "$row = @{ id='env.mode'; pass=$true; details=@{ mode=$mode; py=$py } } | ConvertTo-Json -Compress -Depth 8;" ^
  "Add-Content -Path '%HP_NDJSON%' -Value $row -Encoding ASCII" >> "%LOG%" 2>&1
exit /b 0

:update_find_entry_abs
rem derived requirement: CI skip lane could change the working directory while probing
rem for helper crumbs. Recompute the absolute helper path each time so commands like
rem `py -3` never see a dangling relative path.
if exist "%HP_FIND_ENTRY_NAME%" (
  for %%F in ("%HP_FIND_ENTRY_NAME%") do set "HP_FIND_ENTRY_ABS=%%~fF"
) else if defined HP_SCRIPT_ROOT (
  rem derived requirement: helper lookups must stay rooted to the bootstrapper
  rem directory even if callers pushd elsewhere. Use HP_SCRIPT_ROOT so the CI
  rem skip lane never feeds CMD a dangling relative path.
  set "HP_FIND_ENTRY_ABS=%HP_SCRIPT_ROOT%%HP_FIND_ENTRY_NAME%"
) else (
  set "HP_FIND_ENTRY_ABS=%CD%\%HP_FIND_ENTRY_NAME%"
)
exit /b 0

:verify_find_entry_helper
if "%HP_FIND_ENTRY_SYNTAX_OK%"=="1" exit /b 0
if "%HP_FIND_ENTRY_SYNTAX_OK%"=="0" exit /b 1
set "HP_HELPER_CMD="
set "HP_HELPER_ARGS="
set "HP_HELPER_SYNTAX_PASS=0"
if defined HP_PY if exist "%HP_PY%" set "HP_HELPER_CMD=%HP_PY%"
if not defined HP_HELPER_CMD (
  where python >nul 2>&1 && set "HP_HELPER_CMD=python"
)
if not defined HP_HELPER_CMD (
  where py >nul 2>&1 && (set "HP_HELPER_CMD=py" & set "HP_HELPER_ARGS=-3")
)
if defined HP_HELPER_CMD for %%C in ("%HP_HELPER_CMD%") do set "HP_HELPER_CMD=%%~C"
if defined HP_HELPER_ARGS for %%A in ("%HP_HELPER_ARGS%") do set "HP_HELPER_ARGS=%%~A"
if defined HP_HELPER_CMD (
  if not defined HP_HELPER_CMD_LOGGED (
    rem derived requirement: capture the helper command verbatim so future regressions can
    rem trace quoting issues without reproducing CI. Logged once per bootstrap run.
    if defined HP_HELPER_ARGS (
      >> "%LOG%" echo Helper command: "%HP_HELPER_CMD%" %HP_HELPER_ARGS% "%HP_FIND_ENTRY_ABS%"
    ) else (
      >> "%LOG%" echo Helper command: "%HP_HELPER_CMD%" "%HP_FIND_ENTRY_ABS%"
    )
    set "HP_HELPER_CMD_LOGGED=1"
  )
  if defined HP_HELPER_ARGS (
    "%HP_HELPER_CMD%" %HP_HELPER_ARGS% -m py_compile "%HP_FIND_ENTRY_ABS%" 1>nul 2>nul
  ) else (
    "%HP_HELPER_CMD%" -m py_compile "%HP_FIND_ENTRY_ABS%" 1>nul 2>nul
  )
  if errorlevel 1 (
    set "HP_HELPER_SYNTAX_PASS=0"
  ) else (
    set "HP_HELPER_SYNTAX_PASS=1"
  )
) else (
  set "HP_HELPER_SYNTAX_PASS=0"
)
set "HP_FIND_ENTRY_SYNTAX_OK=%HP_HELPER_SYNTAX_PASS%"
call :append_helper_syntax_row
set "HP_HELPER_CMD="
set "HP_HELPER_ARGS="
if "%HP_HELPER_SYNTAX_PASS%"=="1" exit /b 0
exit /b 1

:append_helper_syntax_row
if "%HP_HELPER_SYNTAX_EMITTED%"=="1" exit /b 0
if not defined HP_NDJSON (
  set "HP_HELPER_SYNTAX_EMITTED=1"
  exit /b 0
)
if "%HP_FIND_ENTRY_SYNTAX_OK%"=="" (
  set "HP_HELPER_SYNTAX_EMITTED=1"
  exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$flag = [Environment]::GetEnvironmentVariable('HP_FIND_ENTRY_SYNTAX_OK');" ^
  "if (-not $flag) { $flag = '0' }" ^
  "$ok = $flag -eq '1';" ^
  "$row = @{ id='helper.find_entry.syntax'; pass=$ok; details=@{ } } | ConvertTo-Json -Compress -Depth 8;" ^
  "Add-Content -Path '%HP_NDJSON%' -Value $row -Encoding ASCII" >> "%LOG%" 2>&1
set "HP_HELPER_SYNTAX_EMITTED=1"
exit /b 0

:emit_conda_probe_skip
if not defined HP_NDJSON exit /b 0
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$reason = [Environment]::GetEnvironmentVariable('HP_CONDA_PROBE_REASON');" ^
  "if (-not $reason) { $reason = 'not-requested' }" ^
  "$row = @{ id='conda.url'; pass=$true; details=@{ skipped=$true; reason=$reason; bytes=0 } } | ConvertTo-Json -Compress -Depth 8;" ^
  "Add-Content -Path '%HP_NDJSON%' -Value $row -Encoding ASCII" >> "%LOG%" 2>&1
exit /b 0

:probe_conda_url
set "HP_DL_PATH=~miniconda.exe"
if exist "%HP_DL_PATH%" del "%HP_DL_PATH%" >nul 2>&1
curl -L --retry 3 --retry-delay 5 --max-time 120 "%HP_MINICONDA_URL%" -o "%HP_DL_PATH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :probe_conda_url_fail
set "HP_DL_BYTES=0"
if exist "%HP_DL_PATH%" for %%S in ("%HP_DL_PATH%") do set "HP_DL_BYTES=%%~zS"
set "HP_DL_PASS=1"
if not defined HP_DL_BYTES set "HP_DL_BYTES=0"
for /f "tokens=*" %%B in ("%HP_DL_BYTES%") do set "HP_DL_BYTES=%%B"
for /f "tokens=*" %%B in ("%HP_MINICONDA_MIN_BYTES%") do set "HP_MIN_BYTES_SAFE=%%B"
if not defined HP_MIN_BYTES_SAFE set "HP_MIN_BYTES_SAFE=0"
set /a HP_BYTES_CHECK=%HP_DL_BYTES%
set /a HP_MIN_CHECK=%HP_MIN_BYTES_SAFE%
if %HP_BYTES_CHECK% LSS %HP_MIN_CHECK% set "HP_DL_PASS=0"
if "%HP_DL_PASS%"=="0" goto :probe_conda_url_fail_with_bytes
call :log "[INFO] Miniconda probe downloaded %HP_DL_BYTES% bytes."
if defined HP_NDJSON (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$row = @{ id='conda.url'; pass=$true; details=@{ bytes=%HP_DL_BYTES% } } | ConvertTo-Json -Compress -Depth 8;" ^
    "Add-Content -Path '%HP_NDJSON%' -Value $row -Encoding ASCII" >> "%LOG%" 2>&1
)
if exist "%HP_DL_PATH%" del "%HP_DL_PATH%" >nul 2>&1
exit /b 0

:probe_conda_url_fail_with_bytes
if defined HP_NDJSON (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$row = @{ id='conda.url'; pass=$false; details=@{ bytes=%HP_DL_BYTES% } } | ConvertTo-Json -Compress -Depth 8;" ^
    "Add-Content -Path '%HP_NDJSON%' -Value $row -Encoding ASCII" >> "%LOG%" 2>&1
)
if exist "%HP_DL_PATH%" del "%HP_DL_PATH%" >nul 2>&1
exit /b 1

:probe_conda_url_fail
set "HP_DL_BYTES=0"
if defined HP_NDJSON (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$row = @{ id='conda.url'; pass=$false; details=@{ bytes=0 } } | ConvertTo-Json -Compress -Depth 8;" ^
    "Add-Content -Path '%HP_NDJSON%' -Value $row -Encoding ASCII" >> "%LOG%" 2>&1
)
if exist "%HP_DL_PATH%" del "%HP_DL_PATH%" >nul 2>&1
exit /b 1

:extract_pep723_requirements
set "HP_PEP723_IN=%~1"
set "HP_PEP723_OUT=%~2"
if exist "%HP_PEP723_OUT%" del "%HP_PEP723_OUT%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$inside = $false; $deps = $false;" ^
  "Get-Content -LiteralPath '%HP_PEP723_IN%' | ForEach-Object {" ^
  "  $line = $_;" ^
  "  if (-not $inside) { if ($line -eq '# /// script') { $inside = $true }; return }" ^
  "  if ($line -eq '# ///') { $inside = $false; $deps = $false; return }" ^
  "  $trim = $line.Trim();" ^
  "  $compact = ($trim -replace '\s','');" ^
  "  if ($compact.StartsWith('#dependencies=') -and $compact.EndsWith('[')) { $deps = $true; return }" ^
  "  if ($deps -and $compact -eq '#]') { $deps = $false; return }" ^
  "  if ($deps -and $trim.StartsWith('# ""')) { $item = $trim.Substring(3).Trim(); if ($item.EndsWith('""')) { $item = $item.Substring(0, $item.Length - 1) }; $item }" ^
  "} | Set-Content -LiteralPath '%HP_PEP723_OUT%' -Encoding ASCII" >> "%LOG%" 2>&1
exit /b %errorlevel%

:determine_entry
set "HP_ENTRY="
set "HP_ENTRY_CMD="
set "HP_ENTRY_ARGS="
if not "%~1"=="" (
  rem REQ-011: %~dp1 = caller's argument directory; %~dp0 = batch script directory (both include trailing \)
  if /i not "%~dp1"=="%~dp0" (
    echo [ERROR] REQ-011: Dragged files must reside in the bootstrapper root folder for environment cleanliness.
    call :log "[ERROR] REQ-011: Dragged files must reside in the bootstrapper root folder."
    exit /b 11
  )
  if exist "%~1" (
    rem derived requirement: use the %~1 parameter directly, not %MAIN_FILE%. Inside this
    rem parenthesized block %MAIN_FILE% expands at parse time (before "set MAIN_FILE" runs),
    rem which yielded an empty HP_ENTRY and an empty "Using drag-and-drop file:" message.
    rem %~1 is the call parameter and expands to the argument value, so both are correct.
    set "HP_ENTRY=%~1"
    if not defined HP_DRAG_MSG_EMITTED (
      echo *** Using drag-and-drop file: %~1
      set "HP_DRAG_MSG_EMITTED=1"
    )
    exit /b 0
  )
)
call :emit_from_base64 "~find_entry.py" HP_FIND_ENTRY
if errorlevel 1 exit /b 1
call :update_find_entry_abs
call :verify_find_entry_helper
if errorlevel 1 exit /b 1
if defined HP_PY if exist "%HP_PY%" set "HP_ENTRY_CMD=%HP_PY%"
if not defined HP_ENTRY_CMD if defined CONDA_BASE_PY if exist "%CONDA_BASE_PY%" set "HP_ENTRY_CMD=%CONDA_BASE_PY%"
if not defined HP_ENTRY_CMD (
  where python >nul 2>&1 && set "HP_ENTRY_CMD=python"
)
if not defined HP_ENTRY_CMD (
  where py >nul 2>&1 && (set "HP_ENTRY_CMD=py" & set "HP_ENTRY_ARGS=-3")
)
if defined HP_ENTRY_CMD for %%C in ("%HP_ENTRY_CMD%") do set "HP_ENTRY_CMD=%%~C"
if defined HP_ENTRY_ARGS for %%A in ("%HP_ENTRY_ARGS%") do set "HP_ENTRY_ARGS=%%~A"
if not defined HP_ENTRY_CMD exit /b 0
rem derived requirement: maintain split helper calls so `py -3` and bare `python` both expand
rem without producing `python"` tokens. This mirrors the CI skip logic above and uses a crumb file
rem so Windows never merges tokens when arguments are empty.
set "HP_ENTRY_CRUMB=~entry.crumb"
if exist "%HP_ENTRY_CRUMB%" del "%HP_ENTRY_CRUMB%" >nul 2>&1
if defined HP_ENTRY_ARGS (
  "%HP_ENTRY_CMD%" %HP_ENTRY_ARGS% "%HP_FIND_ENTRY_ABS%" > "%HP_ENTRY_CRUMB%" 2>> "%LOG%"
) else (
  "%HP_ENTRY_CMD%" "%HP_FIND_ENTRY_ABS%" > "%HP_ENTRY_CRUMB%" 2>> "%LOG%"
)
rem REQ-002: capture find_entry's exit code immediately -- AMBIGUOUS_RC (3) marks the
rem alphabetical fallback (multiple files, no clear winner), the only case that offers
rem the timed interactive picker. Must read %ERRORLEVEL% before any other command.
set "HP_FIND_RC=%ERRORLEVEL%"
if exist "%HP_ENTRY_CRUMB%" (
  for /f "usebackq delims=" %%M in ("%HP_ENTRY_CRUMB%") do if not defined HP_ENTRY set "HP_ENTRY=%%M"
  del "%HP_ENTRY_CRUMB%" >nul 2>&1
)
if not defined HP_ENTRY set "HP_ENTRY="
if defined HP_ENTRY if "%HP_FIND_RC%"=="3" call :pick_entry_interactive
set "HP_FIND_RC="
exit /b 0

:pick_entry_interactive
rem REQ-002: timed interactive entry picker for the ambiguous case. The default
rem (Enter / timeout) is find_entry's alphabetical pick (HP_ENTRY). Skipped when
rem non-interactive: NOINPUT, HP_NONINTERACTIVE, or CI (HP_CI_LANE) -- unless
rem HP_TEST_FORCE_PICKER forces the path (it degrades to the default with no console).
if defined NOINPUT exit /b 0
if defined HP_NONINTERACTIVE exit /b 0
if defined HP_CI_LANE if not defined HP_TEST_FORCE_PICKER exit /b 0
rem choice.exe drives the timed prompt; on a stripped image without it, keep the default.
where choice >nul 2>&1 || exit /b 0
if exist "~entry.menu" del "~entry.menu" >nul 2>&1
(for /f "delims=" %%F in ('dir /b /a-d *.py 2^>nul ^| findstr /v /b /c:"~" ^| sort') do echo %%F) > "~entry.menu"
set "HP_PICK_N=0"
for /f "usebackq delims=" %%F in ("~entry.menu") do set /a HP_PICK_N+=1
if %HP_PICK_N% LSS 2 ( del "~entry.menu" >nul 2>&1 & exit /b 0 )
if %HP_PICK_N% GTR 9 (
  call :log "[INFO] REQ-002: %HP_PICK_N% candidates exceed picker limit; keeping %HP_ENTRY% (alphabetical)."
  del "~entry.menu" >nul 2>&1
  exit /b 0
)
echo.
echo Multiple Python files detected -- no clear entry point, so please choose one to run:
set "HP_PICK_I=0"
set "HP_PICK_DEFAULT=1"
for /f "usebackq delims=" %%F in ("~entry.menu") do call :pick_menu_line "%%F"
echo.
echo   Tip: to skip this question next time, do any one of these:
echo     1. Drag a .py file onto run_setup.bat -- drop it on the batch file icon to run
echo        that file directly. It must be in this same folder.
echo     2. Rename your main script to one of: main.py, app.py, run.py, or cli.py.
echo     3. Give exactly one script an  if __name__ == "__main__":  block.
echo   If you do nothing, the alphabetically-first file is used: %HP_ENTRY%
echo.
set "HP_PICK_T=30"
if defined HP_TEST_FORCE_PICKER set "HP_PICK_T=2"
choice /C 123456789 /N /T %HP_PICK_T% /D %HP_PICK_DEFAULT% /M "Type a number 1-%HP_PICK_N%, or wait %HP_PICK_T%s for the default [%HP_PICK_DEFAULT%]: "
set "HP_PICK_SEL=%ERRORLEVEL%"
if %HP_PICK_SEL% GEQ 1 if %HP_PICK_SEL% LEQ %HP_PICK_N% (
  set "HP_PICK_I=0"
  for /f "usebackq delims=" %%F in ("~entry.menu") do call :pick_apply_line "%%F"
)
del "~entry.menu" >nul 2>&1
call :log "[INFO] REQ-002: Picker entry selected: %HP_ENTRY%"
set "HP_PICK_N="
set "HP_PICK_I="
set "HP_PICK_SEL="
set "HP_PICK_DEFAULT="
set "HP_PICK_T="
exit /b 0

:pick_menu_line
set /a HP_PICK_I+=1
echo   [%HP_PICK_I%] %~1
if /i "%~1"=="%HP_ENTRY%" set "HP_PICK_DEFAULT=%HP_PICK_I%"
exit /b 0

:pick_apply_line
set /a HP_PICK_I+=1
if "%HP_PICK_I%"=="%HP_PICK_SEL%" set "HP_ENTRY=%~1"
exit /b 0

:record_chosen_entry
rem %~1 is the RELATIVE crumb (what we want to show users and tests)
set "HP_CRUMB=%~1"
if "%HP_CRUMB%"=="" exit /b 0
set "HP_CRUMB_SHOW=%HP_CRUMB%"
set "HP_CRUMB_DRIVE="
for %%A in ("%HP_CRUMB_SHOW%") do (
  if not "%%~dA"=="" set "HP_CRUMB_DRIVE=%%~dA"
)
if not defined HP_CRUMB_DRIVE (
  set "HP_CRUMB_FIRST=%HP_CRUMB_SHOW:~0,1%"
  if not "%HP_CRUMB_FIRST%"=="\" (
    if not "%HP_CRUMB_FIRST%"=="/" (
      set "HP_CRUMB_PREFIX2=%HP_CRUMB_SHOW:~0,2%"
      if /I not "%HP_CRUMB_PREFIX2%"==".\" (
        if not "%HP_CRUMB_PREFIX2%"=="./" (
          if not "%HP_CRUMB_PREFIX2%"==".." (
            set "HP_CRUMB_SHOW=.\%HP_CRUMB_SHOW%"
          )
        )
      )
    )
  )
)
set "HP_CRUMB=%HP_CRUMB_SHOW%"
set "HP_CRUMB_DRIVE="
set "HP_CRUMB_FIRST="
set "HP_CRUMB_PREFIX2="
set "HP_CRUMB_SHOW="

rem Echo to console (no punctuation at end)
echo Chosen entry: %HP_CRUMB%
rem Append same line to setup log
>> "%LOG%" echo Chosen entry: %HP_CRUMB%
call :log "[BOOT] REQ-002: Entry selected: %HP_CRUMB%"

rem If we also need an absolute path for execution, set HP_ENTRY elsewhere
rem and keep the echo outside any ( ... ) block.
exit /b 0
:compute_interactive_run
rem Slice 2b-C: single interactivity determination shared by the fail-fast probe at both
rem untimed user-code launch points (:try_fast_exe, :verify_no_exe_interpreter). Mirrors
rem :pick_entry_interactive's three non-interactivity signals (NOINPUT, HP_NONINTERACTIVE,
rem HP_CI_LANE) so a real double-click user gets the new probe with zero flags required,
rem while every CI/automation signal keeps today's plain-redirect behavior byte-for-byte
rem unchanged (self.fastpath / self.exe.fastpath.graceful stay deterministic).
rem HP_TEST_FORCE_INTERACTIVE_PROBE=1 forces the probe branch under HP_CI_LANE for
rem dedicated, deterministic CI coverage of the new state machine (mirrors HP_TEST_FORCE_PICKER).
set "HP_INTERACTIVE_RUN=1"
if defined NOINPUT set "HP_INTERACTIVE_RUN="
if defined HP_NONINTERACTIVE set "HP_INTERACTIVE_RUN="
if defined HP_CI_LANE if not defined HP_TEST_FORCE_INTERACTIVE_PROBE set "HP_INTERACTIVE_RUN="
exit /b 0
:run_failfast_probe
rem Slice 2b-C: shared fail-fast probe for the two untimed user-code launch points. Reuses
rem :run_exe_smokerun's ProcessStartInfo + ReadToEndAsync pattern (preserves ~run.out.txt /
rem ~run.err.txt for existing consumers -- envsmoke's 'smoke-ok' token, spaced-path dist\
rem token capture) but replaces the single 30s-cap-then-Kill() wait with a two-stage wait
rem inside ~failfast_probe.ps1 (HP_FAILFAST_PROBE): WaitForExit(HP_FAILFAST_PROBE_MS)
rem classifies a fast exit vs. still-running; if still running, a SECOND, UNBOUNDED
rem WaitForExit() follows and the process is NEVER killed -- this is the only difference
rem from :run_exe_smokerun, which stays the sole place in this file allowed to force-kill
rem (the fresh-build verification run). Caller sets HP_PROBE_EXE / HP_PROBE_ARGS (raw,
rem unquoted -- the helper quotes it) / HP_PROBE_CWD before calling; %1 is a short site tag
rem ('fastpath'|'interpreter'|'checkpoint' -- the last added by :run_postexec_checkpoint,
rem Slice 2b-C's post-execution checkpoint) used only for the NDJSON row and log text. Always
rem leaves HP_SMOKE_RC set to the true final exit code and HP_PROBE_EXCEEDED set (1) iff the probe
rem window was exceeded -- the caller decides what that means (:try_fast_exe discards a
rem cached EXE only when NOT exceeded; :verify_no_exe_interpreter has no cached artifact and
rem just reports the final outcome either way). Caller may optionally set HP_PROBE_OUT /
rem HP_PROBE_ERR to redirect the captured stdout/stderr somewhere other than the default
rem ~run.out.txt / ~run.err.txt -- :run_postexec_checkpoint uses this so its elective SECOND
rem run never overwrites the FIRST (real) verification run's captured output.
set "HP_PROBE_SITE=%~1"
set "HP_PROBE_EXCEEDED="
set "HP_SMOKE_RC="
set "HP_PROBE_PS=~failfast_probe.ps1"
if not defined HP_PROBE_OUT set "HP_PROBE_OUT=~run.out.txt"
if not defined HP_PROBE_ERR set "HP_PROBE_ERR=~run.err.txt"
if exist "%HP_PROBE_PS%" del "%HP_PROBE_PS%" >nul 2>&1
rem pre-truncate: the helper only writes these once, at process exit, so without this an
rem unbounded ALIVE-AT-PROBE wait would leave stale prior-run content lingering for its
rem full duration with no indication it is stale.
if exist "%HP_PROBE_OUT%" del "%HP_PROBE_OUT%" >nul 2>&1
if exist "%HP_PROBE_ERR%" del "%HP_PROBE_ERR%" >nul 2>&1
call :emit_from_base64 "%HP_PROBE_PS%" HP_FAILFAST_PROBE
if errorlevel 1 (
  rem Extremely rare (disk/permission failure writing a work file); mirror :try_fast_exe's own
  rem emit-failure convention of skipping gracefully rather than hand-rolling an unsafe manual
  rem launch here (HP_PROBE_ARGS is intentionally unquoted raw text -- only the .ps1 helper
  rem quotes it safely; a direct cmd invocation would mis-tokenize an entry path with spaces).
  rem HP_SMOKE_RC stays unset; the safety net below turns that into -1 so callers still see a
  rem defined, non-zero, non-"exceeded" outcome (:try_fast_exe's discard-and-rebuild fires).
  call :log "[WARN] Fail-fast probe: could not emit ~failfast_probe.ps1; treating as a failed run."
) else (
  for /f "usebackq delims=" %%X in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HP_PROBE_PS%"`) do (
    for /f "tokens=1,2 delims=|" %%A in ("%%X") do (
      set "HP_PROBE_EXCEEDED=%%A"
      set "HP_SMOKE_RC=%%B"
    )
  )
  if exist "%HP_PROBE_PS%" del "%HP_PROBE_PS%" >nul 2>&1
)
if "%HP_PROBE_EXCEEDED%"=="0" set "HP_PROBE_EXCEEDED="
if not defined HP_SMOKE_RC set "HP_SMOKE_RC=-1"
call :log "[INFO] Entry smoke exit=%HP_SMOKE_RC%"
if defined HP_PROBE_EXCEEDED (
  call :log "[INFO] Fail-fast probe: still running after %HP_FAILFAST_PROBE_MS%ms; this is your program's real run, not a rebuild trigger. If it has a GUI it may have opened minimized or on another window; if it is a background/console app with no window, that is expected. The bootstrapper is waiting for it to finish so it can report the final result -- it will not force-stop it."
)
if "%HP_SMOKE_RC%"=="0" (
  call :log "[STATUS] Run Status: SUCCESS (Exit Code: 0)"
) else (
  call :log "[STATUS] Run Status: FAILED (Exit Code: %HP_SMOKE_RC%)"
)
if defined HP_NDJSON (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$c=[int]'%HP_SMOKE_RC%';$ex=[bool]'%HP_PROBE_EXCEEDED%';" ^
    "$r=[ordered]@{id='self.failfast.probe';pass=($c -eq 0);details=[ordered]@{site='%HP_PROBE_SITE%';exitCode=$c;probeExceeded=$ex;probeMs=[int]'%HP_FAILFAST_PROBE_MS%'}}|ConvertTo-Json -Compress -Depth 8;" ^
    "Add-Content -Path '%HP_NDJSON%' -Value $r -Encoding ASCII" >> "%LOG%" 2>&1
)
set "HP_PROBE_EXE="
set "HP_PROBE_ARGS="
set "HP_PROBE_CWD="
set "HP_PROBE_SITE="
set "HP_PROBE_PS="
set "HP_PROBE_OUT="
set "HP_PROBE_ERR="
exit /b 0
:run_postexec_checkpoint
rem REQ-018 (2b-C): post-execution checkpoint. The FIRST run (EXE smoke or no-EXE interpreter
rem run) has already happened and its [STATUS] telemetry has already been printed by the time
rem this is called -- this offers an ELECTIVE second run via the interpreter as a diagnostic
rem tool, never forced. Declining (the default, and the only outcome in CI/automation) leaves
rem the run footprint at exactly one execution. Called unconditionally after every verification
rem telemetry point (never after :try_fast_exe's fast-path reuse, which stays zero-friction by
rem design -- see docs/agent-interconnect.md). %1 is a short site tag ('exe'|'interpreter') used
rem only for the log lines below, so a reader can tell which verification path preceded this.
rem
rem Mirrors the existing 3-branch consent-gate pattern (:system_build_consent_gate,
rem :cascade_consent_gate, :system_python_consent_gate): echo the prompt UNCONDITIONALLY (so
rem prompt-text assertions see it even on auto-decline), then HP_TEST_CHECKPOINT_ANSWER
rem (override, checked FIRST so an explicit Y reaches the accept branch even under HP_CI_LANE)
rem -> HP_CI_LANE auto-decline -> interactive set /p. UNLIKE those 3 gates (each reached only on
rem a narrow edge-case path), this one fires on essentially every successful bootstrap run, so it
rem ALSO auto-declines on NOINPUT/HP_NONINTERACTIVE (the same signals :compute_interactive_run and
rem :pick_entry_interactive already treat as authoritative non-interactivity elsewhere in this
rem file) -- without this, any automation that sets those two flags but not HP_CI_LANE (a
rem documented, supported way to run this bootstrapper headlessly), or a contributor running a
rem full-bootstrap selfapps test locally (most do not pin HP_CI_LANE, see docs/agent-lessons-
rem learned.md "Accepted gap"), would hang on set /p with no console input available.
set "HP_CHECKPOINT_SITE=%~1"
echo.
echo *** Verification finished -- see the Run Status above. ***
echo *** You can run your program again now via the interpreter as an extra diagnostic check. ***
set "HP_CHECKPOINT_RAW="
if defined HP_TEST_CHECKPOINT_ANSWER (
  set "HP_CHECKPOINT_RAW=%HP_TEST_CHECKPOINT_ANSWER%"
) else if defined HP_CI_LANE (
  set "HP_CHECKPOINT_RAW=n"
) else if defined NOINPUT (
  set "HP_CHECKPOINT_RAW=n"
) else if defined HP_NONINTERACTIVE (
  set "HP_CHECKPOINT_RAW=n"
) else (
  set /p "HP_CHECKPOINT_RAW=  Run again via the interpreter now? [Y/N] "
)
set "HP_CHECKPOINT_CHOICE=%HP_CHECKPOINT_RAW:~0,1%"
if /I not "%HP_CHECKPOINT_CHOICE%"=="Y" (
  call :log "[INFO] REQ-018: post-execution checkpoint (%HP_CHECKPOINT_SITE%): declined (run footprint stays at one execution)."
  set "HP_CHECKPOINT_SITE="
  set "HP_CHECKPOINT_RAW="
  set "HP_CHECKPOINT_CHOICE="
  exit /b 0
)
call :log "[INFO] REQ-018: post-execution checkpoint (%HP_CHECKPOINT_SITE%): accepted; running a second time via the interpreter."
if /I "%HP_CHECKPOINT_SITE%"=="exe" call :log "[INFO] REQ-018: note -- this diagnostic run uses the interpreter, not the packaged EXE, so behavior can differ (e.g. working directory, bundled resources)."
rem Reuses :run_failfast_probe (same never-kill, two-stage wait) rather than a fourth ad hoc
rem launch mechanism -- this elective run is exactly the same class of "user consciously
rem launched something that might run for a while" as the fail-fast probe's own interactive
rem branch, so it gets the same guarantees (never hard-killed, final outcome always reported).
rem Save/restore HP_SMOKE_RC and HP_PROBE_EXCEEDED around this second call: they belong to the
rem FIRST (real) verification run in the caller's namespace, and :run_failfast_probe would
rem otherwise overwrite both with the SECOND (elective) run's outcome, corrupting them for any
rem future code a caller might add after this checkpoint call before its own exit /b 0.
set "HP_CHECKPOINT_SAVED_SMOKE_RC=%HP_SMOKE_RC%"
set "HP_CHECKPOINT_SAVED_PROBE_EXCEEDED=%HP_PROBE_EXCEEDED%"
set "HP_PROBE_EXE=%HP_PY%"
set "HP_PROBE_ARGS=%HP_ENTRY%"
set "HP_PROBE_CWD=%CD%"
rem Distinct output files from the primary run's ~run.out.txt/~run.err.txt: this is a genuinely
rem SECOND, separate execution, and reusing those paths would silently overwrite the FIRST run's
rem captured output out from under any downstream consumer (envsmoke's 'smoke-ok' token check,
rem the spaced-path dist\ token capture) that expects them to reflect the verified build.
set "HP_PROBE_OUT=~checkpoint_run.out.txt"
set "HP_PROBE_ERR=~checkpoint_run.err.txt"
call :run_failfast_probe checkpoint
set "HP_PROBE_OUT="
set "HP_PROBE_ERR="
set "HP_SMOKE_RC=%HP_CHECKPOINT_SAVED_SMOKE_RC%"
set "HP_PROBE_EXCEEDED=%HP_CHECKPOINT_SAVED_PROBE_EXCEEDED%"
set "HP_CHECKPOINT_SAVED_SMOKE_RC="
set "HP_CHECKPOINT_SAVED_PROBE_EXCEEDED="
set "HP_CHECKPOINT_SITE="
set "HP_CHECKPOINT_RAW="
set "HP_CHECKPOINT_CHOICE="
exit /b 0
:try_fast_exe
set "HP_FASTPATH_USED="
set "HP_FAST_EXE="
set "HP_FAST_EXE_PATH="
if "%PYCOUNT%"=="0" exit /b 0
set "HP_FAST_EXE=dist\%ENVNAME%.exe"
if not exist "%HP_FAST_EXE%" exit /b 0
set "HP_FAST_EXE_PATH=%HP_FAST_EXE%"
set "HP_FASTPATH_TOKEN="
set "HP_FAST_CHECK_PS=~fast_check.ps1"
set "HP_FAST_CHECK_OUT=~fast_check.txt"
if exist "%HP_FAST_CHECK_PS%" del "%HP_FAST_CHECK_PS%" >nul 2>&1
if exist "%HP_FAST_CHECK_OUT%" del "%HP_FAST_CHECK_OUT%" >nul 2>&1
call :emit_from_base64 "%HP_FAST_CHECK_PS%" HP_FAST_CHECK
if errorlevel 1 (
  call :log "[WARN] Fast path: could not emit ~fast_check.ps1; skipping fast path."
  exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HP_FAST_CHECK_PS%" "%HP_FAST_EXE_PATH%" > "%HP_FAST_CHECK_OUT%" 2>> "%LOG%"
if exist "%HP_FAST_CHECK_PS%" del "%HP_FAST_CHECK_PS%" >nul 2>&1
for /f "usebackq delims=" %%T in ("%HP_FAST_CHECK_OUT%") do set "HP_FASTPATH_TOKEN=%%T"
if exist "%HP_FAST_CHECK_OUT%" del "%HP_FAST_CHECK_OUT%" >nul 2>&1
if /I "%HP_FASTPATH_TOKEN%"=="fresh" (
  set "HP_FASTPATH_USED=1"
)
if not defined HP_FASTPATH_USED exit /b 0
rem REQ-012: super-user hook -- reuse the fresh cached EXE but do not run it.
if defined HP_SKIP_EXE_SMOKERUN (
  call :log "[INFO] REQ-012: HP_SKIP_EXE_SMOKERUN set; reusing cached EXE without running it (skipped by request)."
  set "HP_EXE_SKIPPED=1"
  exit /b 0
)
set "HP_PROBE_EXCEEDED="
rem Slice 2b-C: goto-based dispatch, NOT a parenthesized if/else block, is deliberate here --
rem see docs/agent-lessons-learned.md "Provider-cascade dispatch is goto-based on purpose".
rem cmd.exe expands every %VAR% in a parenthesized ( ... ) block ONCE, at parse time, using
rem values from BEFORE the block started -- an earlier revision of this code launched the EXE
rem and read "set HP_SMOKE_RC=%ERRORLEVEL%" inside the else-branch's own parens, which silently
rem froze %ERRORLEVEL% (and every in-block %HP_SMOKE_RC% read) to whatever it was right before
rem the if/else began (almost always "0"), so a genuinely broken cached EXE was NEVER discarded
rem in the legacy/CI branch. Each branch below is reached via goto so its statements are parsed
rem and executed as fresh top-level lines, exactly like the rest of this file's %ERRORLEVEL%
rem capture sites.
if defined HP_INTERACTIVE_RUN goto :try_fast_exe_probe
call :log "[INFO] Fast path: reusing %HP_FAST_EXE%"
>> "%LOG%" echo Fast path command: "%HP_FAST_EXE%" ^> "~run.out.txt" 2^> "~run.err.txt"
"%HP_FAST_EXE%" 1> "~run.out.txt" 2> "~run.err.txt"
set "HP_SMOKE_RC=%ERRORLEVEL%"
call :log "[INFO] Entry smoke exit=%HP_SMOKE_RC%"
if "%HP_SMOKE_RC%"=="0" (
  call :log "[STATUS] Run Status: SUCCESS (Exit Code: 0)"
) else (
  call :log "[STATUS] Run Status: FAILED (Exit Code: %HP_SMOKE_RC%)"
)
goto :try_fast_exe_discard_check
:try_fast_exe_probe
rem Interactive fail-fast probe -- a real double-click user is told explicitly what is about
rem to launch and never sees a hard kill here; a genuinely stale/broken cached EXE that fails
rem within the probe window is still discarded+rebuilt below exactly as before. CI/automation
rem (HP_INTERACTIVE_RUN unset) takes the branch above instead, byte-for-byte unchanged, so
rem self.fastpath / self.exe.fastpath.graceful stay deterministic.
call :log "[INFO] Launching your program now via the cached standalone EXE (PyInstaller build): %HP_FAST_EXE%"
rem Resolve to an absolute path -- HP_FAST_EXE is relative (dist\%ENVNAME%.exe). .NET
rem Process.Start's FileName resolution is a different mechanism from cmd.exe's own relative
rem launch, so keep this unambiguous rather than relying on the child process inheriting the
rem right CWD to resolve it, in case a future change alters how/where this is invoked from.
set "HP_PROBE_EXE=%CD%\%HP_FAST_EXE%"
set "HP_PROBE_ARGS="
set "HP_PROBE_CWD=%CD%"
call :run_failfast_probe fastpath
:try_fast_exe_discard_check
rem REQ-007: a reused EXE that exits non-zero must NOT abort the bootstrapper. The cached
rem EXE may be stale or carry an unbundled runtime dependency (DLL/data file) the fast-path
rem freshness check cannot see. Drop the fast path and fall through to a full rebuild, which
rem routes any persistent failure through :run_exe_smokerun's graceful handling + banner.
rem Slice 2b-C: this discard only fires when the probe was NOT exceeded (a fast, genuine
rem failure). Once a process is classified alive/healthy at the probe, a LATER non-zero exit
rem is presumed to be the user's own program outcome, not proof of a stale artifact -- a
rem rebuild would not fix a runtime bug in the user's own code, so the cached EXE is kept.
if not "%HP_SMOKE_RC%"=="0" if not defined HP_PROBE_EXCEEDED (
  call :log "[WARN] Fast path standalone EXE (PyInstaller build) exited %HP_SMOKE_RC%; discarding cached EXE and rebuilding."
  rem Delete the broken EXE so the next :try_fast_exe call does not re-detect it as
  rem "fresh" and run the known-bad binary again; the rebuild below recreates it.
  if exist "%HP_FAST_EXE%" del "%HP_FAST_EXE%" >nul 2>&1
  set "HP_FASTPATH_USED="
  set "HP_SMOKE_RC="
)
exit /b 0
:run_entry_smoke
call :record_chosen_entry "%HP_ENTRY%"
rem REQ-021: static pre-flight syntax check of the entry (no user code executed). A SyntaxError
rem makes the program unrunnable under the interpreter AND unbuildable by PyInstaller, so report it
rem clearly and stop here instead of failing later inside the doomed PyInstaller build.
call :preflight_compile
if defined HP_PREFLIGHT_FAILED (
  set "HP_BOOTSTRAP_STATE=error"
  exit /b 0
)
set "HP_FASTPATH_USED="
set "HP_SMOKE_RC="
rem REQ-012: super-user hook -- skip the entry-script smoke test (and fast-path EXE
rem reuse, which also executes the program) so no user code runs. Env creation,
rem dependency install, and the PyInstaller build still proceed; the result is left
rem unverified (HP_SMOKE_RC stays empty), not a fake pass or fail.
if defined HP_SKIP_ENTRY_SMOKE (
  call :log "[INFO] REQ-012: HP_SKIP_ENTRY_SMOKE set; skipping entry-script smoke test (no user code executed)."
  goto :run_entry_after_smoke
)
call :try_fast_exe
rem REQ-018 (2b-A.2): single verification -- the redundant pre-build interpreter smoke is removed.
rem In the EXE path the timed EXE smoke (:run_exe_smokerun) is now the sole verification run, so the
rem app is no longer executed twice (interpreter then EXE). When no EXE is produced (system-Python
rem decline / build skipped), the interpreter runs ONCE via :verify_no_exe_interpreter after the
rem build gate. The fast-path EXE run inside :try_fast_exe is the user's run and is left as-is here
rem (its run-timing/consent is unified with the no-EXE interpreter in slice 2b-C).
:run_entry_after_smoke
rem derived requirement: the CI harness inspects the breadcrumb log to flag missing entries.
set "HP_BREADCRUMB=~entry1_bootstrap.log"
if exist "tests\~entry1\" set "HP_BREADCRUMB=tests\~entry1\~entry1_bootstrap.log"
if not exist "%HP_BREADCRUMB%" (
  rem derived requirement: create the breadcrumb when the smoke run succeeds so diagnostics stay consistent.
  for %%B in ("%HP_BREADCRUMB%") do if not "%%~dpB"=="" if not exist "%%~dpB" mkdir "%%~dpB" >nul 2>&1
  type nul > "%HP_BREADCRUMB%"
)
if exist "%HP_BREADCRUMB%" (
  call :log "[INFO] Entry smoke breadcrumb exists: %HP_BREADCRUMB%"
) else (
  call :log "[WARN] Entry smoke missing breadcrumb: %HP_BREADCRUMB%"
)
rem derived requirement (REQ-007 / Windows Server 2025 + VS2026 image): on conda-forge
rem Python, pyexpat.pyd is dynamically linked against a separate libexpat-*.dll in the
rem env's Library\bin. PyInstaller bundles pyexpat.pyd but not that DLL, so the frozen EXE
rem hits "DLL load failed while importing pyexpat" whenever a stdlib XML path runs (e.g.
rem openpyxl -> xml.etree.ElementTree). Bundle the DLL explicitly via --add-binary.
rem Stock python.org builds statically link expat, and venv/uv layouts have no Library\bin,
rem so this detection finds nothing and HP_PYI_EXPAT stays empty (no behavior change).
set "HP_PYI_EXPAT="
set "HP_EXPAT_DLL="
for %%I in ("%HP_PY%") do set "HP_PY_DIR=%%~dpI"
if defined HP_PY_DIR for /f "delims=" %%D in ('dir /b /a-d "%HP_PY_DIR%Library\bin\libexpat*.dll" 2^>nul') do if not defined HP_EXPAT_DLL set "HP_EXPAT_DLL=%HP_PY_DIR%Library\bin\%%D"
if defined HP_EXPAT_DLL (
  call :log "[INFO] REQ-007: bundling conda libexpat DLL for pyexpat: %HP_EXPAT_DLL%"
  set "HP_PYI_EXPAT=--add-binary "%HP_EXPAT_DLL%;.""
)
rem REQ-005.x: pre-build --collect-submodules for curated packages that load
rem submodules dynamically (the warn file is silent about them, so warnfix never
rem repairs them). Double-gated inside the helper (used-by-source AND installed) so
rem a fat global env never bloats a lean app EXE. Computed in a subroutine so
rem %HP_PYI_COLLECT% resolves at parse time inside the build block below.
call :compute_collect_flags
rem REQ-007: provider-independent build. The EXE build is attempted under every provider. System
rem Python (Tier 4) is the one exception: building installs PyInstaller into the user's system
rem interpreter, so it is gated on explicit consent (CI auto-declines); all other providers build.
set "HP_BUILD_OK=1"
if /i "%HP_ENV_MODE%"=="system" call :system_build_consent_gate
if /i "%HP_ENV_MODE%"=="system" if errorlevel 1 set "HP_BUILD_OK="
rem Slice 2b-C: recompute the same HP_FASTPATH_RUN_FAILED check the top-of-file gate uses
rem (this is :try_fast_exe's SECOND call site, inside :run_entry_smoke; the first call's own
rem HP_FASTPATH_RUN_FAILED does not reach here -- any first-call success or post-probe-failure
rem outcome already took goto :success before this point, so this recomputation is normally a
rem no-op today, but keeps this call site from silently reopening the same "HP_FASTPATH_USED
rem alone is not proof of a clean run" gap the top-of-file gate closed, should a future change
rem (e.g. a provider-cascade re-entry) ever reach here with HP_FASTPATH_USED still set from a
rem probe-classified alive-then-failed run). Computed as a top-level statement, not inside the
rem block below, for the same parse-time-expansion reason documented in :try_fast_exe.
set "HP_FASTPATH_RUN_FAILED="
if defined HP_SMOKE_RC if not "%HP_SMOKE_RC%"=="0" set "HP_FASTPATH_RUN_FAILED=1"
if not defined HP_BUILD_OK (
  call :log "[INFO] REQ-007: system-Python EXE build not consented; skipping PyInstaller packaging. The environment and dependencies are installed; run the app directly via the prepared Python."
) else (
  if defined HP_FASTPATH_USED (
    if defined HP_FASTPATH_RUN_FAILED (
      call :log "[WARN] dist\%ENVNAME%.exe (standalone EXE, PyInstaller build) ran to completion and exited non-zero after passing the fail-fast probe; treated as your program's own result, not a rebuild trigger."
    ) else (
      call :log "[INFO] Fast path: skipping PyInstaller rebuild for existing dist\%ENVNAME%.exe"
    )
  ) else (
    rem derived requirement: PyInstaller install + build can take a minute or more; emit a
    rem user-facing message before the silent operation so the script never looks hung.
    call :log "[INFO] Building standalone executable -- this may take a minute or two..."
    :: derived requirement: ~parse_warn.py was written against PyInstaller 5.x and 6.x warn-file formats.
    :: Version is intentionally unpinned so future PyInstaller releases are adopted automatically.
    :: If CI starts failing parse_warn tests after a PyInstaller update, review ~parse_warn.py
    :: against the new warn-file format and update the translation table as needed.
    if "%HP_ENV_MODE%"=="uv" (
      "%HP_UV_EXE%" pip install --python "%HP_PY%" -q pyinstaller >> "%LOG%" 2>&1
    ) else (
      "%HP_PY%" -m pip install -q pyinstaller >> "%LOG%" 2>&1
    )
    if exist "%ENVNAME%.spec" set "HP_SPEC_PREEXIST=1"
    "%HP_PY%" -m PyInstaller -y --onefile --clean --log-level WARN %HP_PYI_EXPAT% %HP_PYI_COLLECT% --name "%ENVNAME%" "%HP_ENTRY%" >> "%LOG%" 2>&1
    if errorlevel 1 call :die "[ERROR] PyInstaller execution failed."
    if not exist "dist\%ENVNAME%.exe" call :die "[ERROR] PyInstaller did not produce dist\%ENVNAME%.exe"
    call :log "[INFO] PyInstaller produced dist\%ENVNAME%.exe"
    rem parse_warn: check PyInstaller warn file for missing modules before cleanup
    rem derived requirement: build\ must still exist when ~parse_warn.py runs.
    rem derived requirement: use %ENVNAME% (set before this block) as the inline
    rem path, not a variable set inside the same else-block; cmd.exe expands
    rem %VAR% at parse time for the whole block, so HP_WARNFILE would be empty.
    if exist "build\%ENVNAME%\warn-%ENVNAME%.txt" (
      call :log "[DEBUG] warnfix: warn file found"
      type "build\%ENVNAME%\warn-%ENVNAME%.txt" >> "%LOG%"
      copy "build\%ENVNAME%\warn-%ENVNAME%.txt" "~warnfile.txt" >nul 2>&1
      call :log "[INFO] warnfix: Platform-specific modules in the list above are expected on Windows: posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, _frozen_importlib_external. These will be filtered out automatically."
      if defined HP_NDJSON (
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
          "$row = @{ id='self.warnfix.platform_filter'; pass=$true; detail='posix_modules_expected_on_windows' } | ConvertTo-Json -Compress -Depth 8;" ^
          "Add-Content -Path '%HP_NDJSON%' -Value $row -Encoding ASCII" >> "%LOG%" 2>&1
      )
    ) else (
      call :log "[DEBUG] warnfix: warn file not found"
    )
    if exist "~missing_modules.txt" del "~missing_modules.txt" >nul 2>&1
    call :emit_from_base64 "~parse_warn.py" HP_PARSE_WARN
    "%HP_PY%" ~parse_warn.py "%ENVNAME%" > "~missing_modules.txt" 2>> "%LOG%"
    if exist "~parse_warn.py" del "~parse_warn.py" >nul 2>&1
    set "HP_WARNFIX_NEEDED="
    for /f "usebackq delims=" %%M in ("~missing_modules.txt") do set "HP_WARNFIX_NEEDED=1"
    if exist "~warnfix_repair_failed.flag" del "~warnfix_repair_failed.flag" >nul 2>&1
    if defined HP_WARNFIX_NEEDED (
      set "HP_WARNFIX_APPLIED=1"
      call :log "[REPAIR] missing modules detected; installing and rebuilding."
      if "%HP_ENV_MODE%"=="uv" (
        for /f "usebackq delims=" %%M in ("~missing_modules.txt") do (
          "%HP_UV_EXE%" pip install --python "%HP_PY%" %%M >> "%LOG%" 2>&1
          if errorlevel 1 (
            call :log "[WARN] Repair failed: %%M"
            copy nul "~warnfix_repair_failed.flag" >nul 2>&1
          )
        )
      ) else if defined CONDA_BAT (
        for /f "usebackq delims=" %%M in ("~missing_modules.txt") do (
          call "%CONDA_BAT%" install -y -n "%ENVNAME%" --override-channels -c conda-forge %%M >> "%LOG%" 2>&1
          if errorlevel 1 (
            call :log "[WARN] Repair failed: %%M"
            copy nul "~warnfix_repair_failed.flag" >nul 2>&1
          )
        )
      )
      if exist "~warnfix_repair_failed.flag" call :log "[WARN] One or more repair attempts failed"
      call :log "[INFO] Rebuilding standalone executable after warnfix -- this may take a minute or two..."
      "%HP_PY%" -m PyInstaller -y --onefile --clean --log-level WARN %HP_PYI_EXPAT% %HP_PYI_COLLECT% --name "%ENVNAME%" "%HP_ENTRY%" >> "%LOG%" 2>&1
      call :log "[REPAIR] rebuild complete after warnfix."
      rem REQ-005.11: warnfix-trigger PEP 723 write-back. Must run here, not later --
      rem ~missing_modules.txt and ~warnfix_repair_failed.flag are both still on disk at
      rem this point and are deleted shortly after (see below).
      call :pep723_writeback warnfix
      rem REQ-009/REQ-005.10 (slice 1: detect only): flag when this provider could not
      rem resolve all modules. Must run before the repair-failed flag is deleted (next line).
      call :warnfix_cascade_detect
    )
    if exist "~warnfix_repair_failed.flag" del "~warnfix_repair_failed.flag" >nul 2>&1
    if exist "~missing_modules.txt" del "~missing_modules.txt" >nul 2>&1
    set "HP_WARNFIX_NEEDED="
    if not defined HP_SPEC_PREEXIST if exist "%ENVNAME%.spec" del "%ENVNAME%.spec" >nul 2>&1
    set "HP_SPEC_PREEXIST="
    if exist "build\%ENVNAME%" rd /s /q "build\%ENVNAME%" >nul 2>&1
    call :log "[INFO] PyInstaller build artifacts cleaned up."
    call :run_exe_smokerun
  )
)
call :verify_no_exe_interpreter
set "HP_WARNFIX_APPLIED="
set "HP_FAST_EXE="
set "HP_FAST_EXE_PATH="
set "HP_FASTPATH_USED="
set "HP_FASTPATH_TOKEN="
set "HP_PYI_EXPAT="
set "HP_EXPAT_DLL="
set "HP_PY_DIR="
exit /b 0
:preflight_compile
rem REQ-021: static pre-flight -- byte-compile the entry to catch a SyntaxError in the user's own
rem code early and clearly, before the doomed PyInstaller build. py_compile uses the same parser as
rem the interpreter (zero false positives for the entry) and writes NO .pyc on failure. No setlocal:
rem HP_PREFLIGHT_FAILED must persist to the caller. Capture %ERRORLEVEL% immediately (the del/set
rem below would clobber it).
set "HP_PREFLIGHT_FAILED="
if not defined HP_ENTRY exit /b 0
if not exist "%HP_ENTRY%" exit /b 0
if exist "~preflight.err.txt" del "~preflight.err.txt" >nul 2>&1
"%HP_PY%" -m py_compile "%HP_ENTRY%" 2> "~preflight.err.txt"
set "HP_PREFLIGHT_RC=%ERRORLEVEL%"
if "%HP_PREFLIGHT_RC%"=="0" (
  if exist "~preflight.err.txt" del "~preflight.err.txt" >nul 2>&1
  set "HP_PREFLIGHT_RC="
  exit /b 0
)
echo.
echo *** [ERROR] REQ-021: Your Python program has a syntax error and cannot run. ***
echo *** File: "%HP_ENTRY%" ***
call :log "[ERROR] REQ-021: entry failed py_compile (syntax error): %HP_ENTRY%"
if exist "~preflight.err.txt" type "~preflight.err.txt"
if exist "~preflight.err.txt" type "~preflight.err.txt" >> "%LOG%"
echo.
echo *** Fix the syntax error shown above, then run this batch again. ***
if exist "~preflight.err.txt" del "~preflight.err.txt" >nul 2>&1
set "HP_PREFLIGHT_RC="
set "HP_PREFLIGHT_FAILED=1"
exit /b 0
:compute_collect_flags
rem Emit --collect-submodules flags for curated packages (sklearn, matplotlib,
rem scipy, plotly) that load submodules dynamically -- PyInstaller static analysis
rem misses them so the warn file is silent and warnfix never repairs them. The helper
rem ~collect_submodules.py double-gates: a flag is emitted only when the package is
rem BOTH imported by the user project source AND importable in the build interpreter,
rem so a hello-world in a fat env stays lean. No setlocal: HP_PYI_COLLECT must persist
rem to the caller and into the build command.
set "HP_PYI_COLLECT="
if "%HP_ENV_MODE%"=="system" exit /b 0
if defined HP_FASTPATH_USED exit /b 0
call :emit_from_base64 "~collect_submodules.py" HP_COLLECT_SUBMODULES
if exist "~collect_flags.txt" del "~collect_flags.txt" >nul 2>&1
"%HP_PY%" ~collect_submodules.py . > "~collect_flags.txt" 2>> "%LOG%"
if exist "~collect_submodules.py" del "~collect_submodules.py" >nul 2>&1
for /f "usebackq delims=" %%F in ("~collect_flags.txt") do set "HP_PYI_COLLECT=%%F"
if exist "~collect_flags.txt" del "~collect_flags.txt" >nul 2>&1
if defined HP_PYI_COLLECT call :log "[INFO] Pre-build collect-submodules:%HP_PYI_COLLECT%"
exit /b 0
:system_build_consent_gate
rem REQ-007: consent before installing PyInstaller into the user's system Python to build an EXE.
rem CI-safe (mirrors :cascade_consent_gate): HP_TEST_SYSBUILD_ANSWER (Y/N) overrides; else
rem HP_CI_LANE auto-declines with no set /p (no CI hang); else interactive prompt. The prompt
rem string is echoed unconditionally so prompt assertions see it even on auto-decline.
rem exit 0 = consent (build), exit 1 = decline (skip the build).
echo.
echo *** The standalone EXE build installs PyInstaller into your system Python. ***
echo *** This is the same PyInstaller build used for every provider -- not a special path -- and ***
echo *** its footprint is small and self-contained (it does not pin common libraries), so it is ***
echo *** unlikely to conflict with your existing packages. ***
echo.
set "HP_SYSBUILD_RAW="
if defined HP_TEST_SYSBUILD_ANSWER (
  set "HP_SYSBUILD_RAW=%HP_TEST_SYSBUILD_ANSWER%"
) else if defined HP_CI_LANE (
  set "HP_SYSBUILD_RAW=n"
) else (
  set /p "HP_SYSBUILD_RAW=  Build the standalone EXE now? [Y/N] "
)
set "HP_SYSBUILD_CHOICE=%HP_SYSBUILD_RAW:~0,1%"
if /I "%HP_SYSBUILD_CHOICE%"=="Y" (
  call :log "[INFO] REQ-007: system-Python EXE build consent: accepted."
  exit /b 0
)
call :log "[INFO] REQ-007: system-Python EXE build consent: declined."
exit /b 1
:verify_no_exe_interpreter
rem REQ-018 (2b-A.2): single-verification fallback for the NO-EXE path. When no EXE was built or
rem run (system-Python build declined, or build skipped), run the entry once via the interpreter --
rem in those providers there is no EXE deliverable, so this IS the user's run, not a throwaway.
rem Skipped when user code must not run (REQ-012) or already ran (fast path, or an EXE smoke
rem verified the build). Emits the same "Entry smoke" vocabulary + [STATUS] readout.
if defined HP_SKIP_ENTRY_SMOKE exit /b 0
if defined HP_FASTPATH_USED exit /b 0
rem skip only when an EXE smoke actually verified the build; if the EXE exists but its smoke was
rem skipped by request (HP_SKIP_EXE_SMOKERUN without HP_SKIP_ENTRY_SMOKE), still verify via the
rem interpreter so that REQ-012 "skip the EXE run" does not silently skip all verification.
if exist "dist\%ENVNAME%.exe" if not defined HP_EXE_SKIPPED exit /b 0
set "HP_PROBE_EXCEEDED="
rem Slice 2b-C: goto-based dispatch, not a parenthesized if/else block -- see the identical
rem rationale comment in :try_fast_exe (cmd.exe freezes every %VAR% in a ( ... ) block to its
rem pre-block value at parse time; launching the interpreter and reading %ERRORLEVEL% inside
rem the same parens would silently corrupt HP_SMOKE_RC for the legacy/CI branch).
if defined HP_INTERACTIVE_RUN goto :verify_no_exe_probe
call :log "[INFO] Running entry script smoke test via %HP_ENV_MODE% interpreter."
rem derived requirement: execute the smoke command inline so cmd, not our logging, owns redirection parsing.
>> "%LOG%" echo Smoke command: "%HP_PY%" "%HP_ENTRY%" ^> "~run.out.txt" 2^> "~run.err.txt"
"%HP_PY%" "%HP_ENTRY%" 1> "~run.out.txt" 2> "~run.err.txt"
set "HP_SMOKE_RC=%ERRORLEVEL%"
call :log "[INFO] Entry smoke exit=%HP_SMOKE_RC%"
if "%HP_SMOKE_RC%"=="0" (
  call :log "[STATUS] Run Status: SUCCESS (Exit Code: 0)"
) else (
  call :log "[STATUS] Run Status: FAILED (Exit Code: %HP_SMOKE_RC%)"
)
call :run_postexec_checkpoint interpreter
exit /b 0
:verify_no_exe_probe
rem Kept UNTIMED past the short probe window on purpose: a long-running app (GUI / server /
rem loop) for system-mode users has no recourse if killed, so once the probe window
rem (HP_FAILFAST_PROBE_MS) is crossed the wait becomes unbounded and the process is never
rem force-stopped. There is no cached artifact at this call site, so the probe only adds an
rem early, honest heads-up log line; the final outcome is reported either way once the
rem interpreter actually exits.
call :log "[INFO] Launching your program now via the %HP_ENV_MODE% interpreter: %HP_PY% %HP_ENTRY%"
set "HP_PROBE_EXE=%HP_PY%"
set "HP_PROBE_ARGS=%HP_ENTRY%"
set "HP_PROBE_CWD=%CD%"
call :run_failfast_probe interpreter
call :run_postexec_checkpoint interpreter
exit /b 0
:warnfix_cascade_detect
rem REQ-009/REQ-005.10 (slice 1: detect only). After the warnfix rebuild, re-parse the
rem fresh PyInstaller warn file. If modules are STILL missing AND at least one repair
rem install failed this round, the current provider genuinely cannot supply them -- mark a
rem cascade candidate (HP_CASCADE_CANDIDATE). This slice only detects and logs; the actual
rem provider cascade (re-attempt under the next REQ-009 tier) is added in a later change.
rem Confidence gate: require BOTH the unresolved signal AND a recorded install failure so a
rem parse_warn false-positive on an already-present module does not trigger a cascade.
rem HP_TEST_FORCE_WARNFIX_UNRESOLVED=1 forces the candidate for deterministic CI coverage.
rem No setlocal: HP_CASCADE_CANDIDATE must persist to the caller.
set "HP_CASCADE_CANDIDATE="
set "HP_UNRESOLVED_AFTER="
if exist "build\%ENVNAME%\warn-%ENVNAME%.txt" (
  call :emit_from_base64 "~parse_warn.py" HP_PARSE_WARN
  "%HP_PY%" ~parse_warn.py "%ENVNAME%" > "~missing_after.txt" 2>> "%LOG%"
  if exist "~parse_warn.py" del "~parse_warn.py" >nul 2>&1
  for /f "usebackq delims=" %%M in ("~missing_after.txt") do set "HP_UNRESOLVED_AFTER=1"
)
if exist "~warnfix_repair_failed.flag" if defined HP_UNRESOLVED_AFTER set "HP_CASCADE_CANDIDATE=1"
if "%HP_TEST_FORCE_WARNFIX_UNRESOLVED%"=="1" set "HP_CASCADE_CANDIDATE=1"
set "HP_CASCADE_APPROVED="
if defined HP_CASCADE_CANDIDATE (
  call :log "[WARN] REQ-009: warnfix left modules unresolved under provider %HP_ENV_MODE%."
  call :log "[INFO] REQ-009: cascade candidate detected."
)
rem Slice 2: ask for consent. Slice 3 will consume HP_CASCADE_APPROVED to re-attempt the
rem dependency phase under the next REQ-009 provider tier. Detection-only until then.
if defined HP_CASCADE_CANDIDATE call :cascade_consent_gate
if defined HP_CASCADE_CANDIDATE if not errorlevel 1 set "HP_CASCADE_APPROVED=1"
if defined HP_CASCADE_APPROVED call :log "[INFO] REQ-009: cascade approved; will re-attempt under the next provider tier."
if defined HP_CASCADE_CANDIDATE if not defined HP_CASCADE_APPROVED call :log "[INFO] REQ-009: cascade declined; keeping current build."
if exist "~missing_after.txt" del "~missing_after.txt" >nul 2>&1
exit /b 0
:pep723_writeback
rem REQ-005.11: promotes resolved dependencies into %HP_ENTRY%'s PEP 723 header via
rem uv add --script; see docs/plan-pep723-writeback.md Part 2. Called with one argument,
rem 'fresh' or 'warnfix', for log-message differentiation only. Goto-based dispatch, not
rem nested parens, per the established cascade-dispatch convention (docs/agent-lessons-
rem learned.md "Provider-cascade dispatch is goto-based on purpose").
set "HP_PEP723_TRIGGER=%~1"
rem v1 scope gate: uv lane only. Silent -- no log line, to avoid noise on every non-uv run.
if not "%HP_ENV_MODE%"=="uv" exit /b 0
if defined HP_SKIP_PEP723_WRITEBACK (
  call :log "[INFO] REQ-005.11: PEP 723 write-back skipped (HP_SKIP_PEP723_WRITEBACK set)."
  exit /b 0
)
rem Defensive; technically unreachable given call-site ordering, cheap insurance only.
if defined HP_CI_SKIP_ENV exit /b 0
if not defined HP_UV_EXE exit /b 0
if not defined HP_ENTRY exit /b 0
if not exist "%HP_ENTRY%" exit /b 0
rem Packages-source-exists check runs BEFORE the confirmed-installed gate below:
rem an app with nothing to install (e.g. a stdlib-only app -- no requirements.txt is
rem ever written for it) must exit silently here, not fall into the confirmed-
rem installed gate and log a misleading "install did not fully succeed" message
rem for a round where nothing was ever attempted in the first place.
set "HP_PEP723_PKGS_SRC="
if /I "%HP_PEP723_TRIGGER%"=="fresh" set "HP_PEP723_PKGS_SRC=requirements.txt"
if /I "%HP_PEP723_TRIGGER%"=="warnfix" set "HP_PEP723_PKGS_SRC=~missing_modules.txt"
if not defined HP_PEP723_PKGS_SRC exit /b 0
if not exist "%HP_PEP723_PKGS_SRC%" exit /b 0
rem All-or-nothing confirmed-installed gate per trigger (see Part 2.0 point 3): never
rem write back from a partially-failed round.
if /I "%HP_PEP723_TRIGGER%"=="fresh" if not defined HP_UV_INSTALL_OK (
  call :log "[INFO] REQ-005.11: PEP 723 write-back skipped (dependency install did not fully succeed)."
  exit /b 0
)
if /I "%HP_PEP723_TRIGGER%"=="warnfix" if exist "~warnfix_repair_failed.flag" (
  call :log "[INFO] REQ-005.11: PEP 723 write-back skipped (one or more warnfix repairs failed)."
  exit /b 0
)
if exist "~pep723_pkgs.txt" del "~pep723_pkgs.txt" >nul 2>&1
copy /y "%HP_PEP723_PKGS_SRC%" "~pep723_pkgs.txt" >nul 2>&1
if errorlevel 1 goto :pep723_writeback_cleanup
call :emit_from_base64 "~pep723_writeback.py" HP_PEP723_WRITEBACK
if errorlevel 1 goto :pep723_writeback_cleanup
if exist "~pep723_result.txt" del "~pep723_result.txt" >nul 2>&1
"%HP_PY%" "~pep723_writeback.py" "%HP_ENTRY%" "%HP_UV_EXE%" "%HP_PY%" "~pep723_pkgs.txt" > "~pep723_result.txt" 2>> "%LOG%"
set "HP_PEP723_RESULT="
for /f "usebackq delims=" %%R in ("~pep723_result.txt") do set "HP_PEP723_RESULT=%%R"
if exist "~pep723_result.txt" del "~pep723_result.txt" >nul 2>&1
if exist "~pep723_writeback.py" del "~pep723_writeback.py" >nul 2>&1
if not defined HP_PEP723_RESULT (
  call :log "[WARN] REQ-005.11: PEP 723 write-back helper produced no output; continuing."
  goto :pep723_writeback_cleanup
)
if "%HP_PEP723_RESULT:~0,3%"=="OK:" (
  call :log "[INFO] REQ-005.11: PEP 723 header write-back succeeded via uv add --script."
  goto :pep723_writeback_cleanup
)
if "%HP_PEP723_RESULT%"=="SKIP:no_packages" (
  call :log "[INFO] REQ-005.11: PEP 723 write-back skipped (no packages to write)."
  goto :pep723_writeback_cleanup
)
if "%HP_PEP723_RESULT%"=="SKIP:non_utf8" (
  call :log "[INFO] REQ-005.11: PEP 723 write-back skipped (entry file is not UTF-8)."
  goto :pep723_writeback_cleanup
)
if "%HP_PEP723_RESULT%"=="SKIP:file_locked" (
  call :log "[INFO] REQ-005.11: PEP 723 write-back skipped (entry file is locked)."
  goto :pep723_writeback_cleanup
)
if "%HP_PEP723_RESULT%"=="SKIP:lockfile" (
  call :log "[INFO] REQ-005.11: PEP 723 write-back skipped (a .py.lock sidecar already exists)."
  goto :pep723_writeback_cleanup
)
if "%HP_PEP723_RESULT:~0,6%"=="ERROR:" (
  call :log "[WARN] REQ-005.11: PEP 723 header write-back failed (%HP_PEP723_RESULT%); continuing."
  goto :pep723_writeback_cleanup
)
call :log "[WARN] REQ-005.11: PEP 723 header write-back returned an unrecognized result; continuing."
:pep723_writeback_cleanup
if exist "~pep723_pkgs.txt" del "~pep723_pkgs.txt" >nul 2>&1
set "HP_PEP723_TRIGGER="
set "HP_PEP723_PKGS_SRC="
set "HP_PEP723_RESULT="
exit /b 0

:cascade_consent_gate
rem REQ-009/REQ-005.10: require explicit consent before cascading to the next provider tier.
rem CI-safe (mirrors :conda_binary_corrupt heal prompt): HP_TEST_CASCADE_ANSWER (Y/N) overrides;
rem otherwise HP_CI_LANE auto-declines with no prompt (no set /p hang in CI); interactive users
rem get a Y/N prompt. exit 0 = approved (cascade), exit 1 = declined (keep the current build).
echo.
echo *** Some dependencies could not be installed under the current Python provider. ***
echo.
set "HP_CASCADE_RAW="
if defined HP_TEST_CASCADE_ANSWER (
  set "HP_CASCADE_RAW=%HP_TEST_CASCADE_ANSWER%"
) else if defined HP_CI_LANE (
  set "HP_CASCADE_RAW=n"
) else (
  set /p "HP_CASCADE_RAW=  Try the next Python provider to resolve them? [Y/N] "
)
set "HP_CASCADE_CHOICE=%HP_CASCADE_RAW:~0,1%"
if /I "%HP_CASCADE_CHOICE%"=="Y" (
  call :log "[INFO] REQ-009: cascade consent: accepted."
  exit /b 0
)
call :log "[INFO] REQ-009: cascade consent: declined."
exit /b 1
:hidden_import_recover
rem Slice 2 (REQ-016): strict, double-gated --hidden-import auto-recovery loop.
rem Acts ONLY on `ModuleNotFoundError: No module named X` where X is INSTALLED in the
rem build interpreter (~hidden_import_scan.py enforces both gates), so a user typo /
rem ImportError / circular-import never triggers a rebuild. Bounded to 3 rebuilds; the
rem helper's already-tried list plus the iter cap guarantee the loop cannot run forever.
rem Sets HP_EXE_EXIT to the final EXE exit so the caller re-checks success. goto-based
rem (not a parenthesized block) so each %VAR% reads its runtime value, not a parse-time one.
if not exist "dist\%ENVNAME%.exe" exit /b 0
set "HP_PYI_HIDDEN_IMPORTS="
set "HP_HIDDEN_ITER=0"
set "HP_HIDDEN_TRIED="
rem preserve a user pre-existing spec across recovery rebuilds (the main-build spec-preexist
rem flag was already consumed before run_exe_smokerun ran).
set "HP_HID_SPEC_PRE="
if exist "%ENVNAME%.spec" set "HP_HID_SPEC_PRE=1"
call :warn_user_code_launch
:hidden_import_loop
rem run the EXE with a 30s cap and capture combined output for the scan. A cap is
rem essential here: once recovery fixes a missing import the app may proceed into a
rem long-running phase (server/GUI), and an uncapped run would hang the bootstrapper.
set "HP_EXE_EXIT="
pushd dist
for /f "usebackq delims=" %%X in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$si=New-Object System.Diagnostics.ProcessStartInfo;$si.FileName='%ENVNAME%.exe';$si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$p=[System.Diagnostics.Process]::Start($si);$so=$p.StandardOutput.ReadToEndAsync();$se=$p.StandardError.ReadToEndAsync();$done=$p.WaitForExit(30000);if(-not $done){try{$p.Kill()}catch{}};($so.Result+$se.Result)|Set-Content -Path '~exe_out.txt' -Encoding ASCII;if($done){$p.ExitCode}else{-1}"`) do set "HP_EXE_EXIT=%%X"
if not defined HP_EXE_EXIT set "HP_EXE_EXIT=-1"
popd
if "%HP_EXE_EXIT%"=="0" goto :hidden_import_recover_done
if %HP_HIDDEN_ITER% GEQ 3 goto :hidden_import_recover_done
call :emit_from_base64 "~hidden_import_scan.py" HP_HIDDEN_IMPORT_SCAN
"%HP_PY%" ~hidden_import_scan.py "dist\~exe_out.txt" %HP_HIDDEN_TRIED% > "~next_hidden.txt" 2>> "%LOG%"
if exist "~hidden_import_scan.py" del "~hidden_import_scan.py" >nul 2>&1
set "HP_NEXT_HIDDEN="
for /f "usebackq delims=" %%M in ("~next_hidden.txt") do set "HP_NEXT_HIDDEN=%%M"
if exist "~next_hidden.txt" del "~next_hidden.txt" >nul 2>&1
if not defined HP_NEXT_HIDDEN goto :hidden_import_recover_done
set /a HP_HIDDEN_ITER+=1
set "HP_PYI_HIDDEN_IMPORTS=%HP_PYI_HIDDEN_IMPORTS% --hidden-import=%HP_NEXT_HIDDEN%"
set "HP_HIDDEN_TRIED=%HP_HIDDEN_TRIED% %HP_NEXT_HIDDEN%"
call :log "[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=%HP_NEXT_HIDDEN%; rebuilding EXE (iter %HP_HIDDEN_ITER%/3)."
"%HP_PY%" -m PyInstaller -y --onefile --clean --log-level WARN %HP_PYI_EXPAT% %HP_PYI_COLLECT% %HP_PYI_HIDDEN_IMPORTS% --name "%ENVNAME%" "%HP_ENTRY%" >> "%LOG%" 2>&1
if errorlevel 1 (
  call :log "[REPAIR][HIDDEN_IMPORT] PyInstaller rebuild failed; stopping recovery."
  set "HP_EXE_EXIT=1"
  goto :hidden_import_recover_done
)
goto :hidden_import_loop
:hidden_import_recover_done
if "%HP_EXE_EXIT%"=="0" if %HP_HIDDEN_ITER% GEQ 1 call :log "[REPAIR][HIDDEN_IMPORT] EXE verified after hidden-import recovery."
rem derived requirement: prior to this line, exhausting the 3-attempt cap with the EXE still
rem failing logged nothing beyond the per-iteration [REPAIR][HIDDEN_IMPORT] lines -- the user
rem only saw the generic post-build failure output, with no explicit signal that auto-recovery
rem was attempted and gave up.
if not "%HP_EXE_EXIT%"=="0" if %HP_HIDDEN_ITER% GEQ 3 call :log "[WARN][HIDDEN_IMPORT] Auto-recovery exhausted after 3 attempts; module(s) still missing."
if exist "dist\~exe_out.txt" del "dist\~exe_out.txt" >nul 2>&1
rem clean up artifacts created by recovery rebuilds (mirror the main-build cleanup);
rem preserve a user pre-existing spec.
if not defined HP_HID_SPEC_PRE if exist "%ENVNAME%.spec" del "%ENVNAME%.spec" >nul 2>&1
if exist "build\%ENVNAME%" rd /s /q "build\%ENVNAME%" >nul 2>&1
set "HP_HIDDEN_ITER="
set "HP_HIDDEN_TRIED="
set "HP_NEXT_HIDDEN="
set "HP_HID_SPEC_PRE="
set "HP_PYI_HIDDEN_IMPORTS="
exit /b 0
:warn_user_code_launch
rem REQ-016: tightly-scoped heads-up before a launch that is force-stopped at ~30s, so the
rem user does not mistake a verification run for finished setup and start real work in it
rem (which would be lost when the run is killed). Called only where a 30s kill actually
rem happens -- the EXE smoke and hidden-import recovery -- not at the untimed entry smoke.
call :log "[WARN] Verifying the built standalone EXE (PyInstaller) now: it is force-stopped after about 30 seconds even if running perfectly, so do not start real work in it yet or any unsaved work will be lost."
exit /b 0
:run_exe_smokerun
if not exist "dist\%ENVNAME%.exe" (
  call :log "[WARN] EXE smokerun: dist\%ENVNAME%.exe not found; skipping"
  exit /b 0
)
rem REQ-012: super-user hook -- skip EXE verification by request, BEFORE announcing a
rem test. Distinct from a verification failure, so HP_EXE_VERIFY_FAILED is NOT set; the
rem post-flight note records that the EXE was built but intentionally not run.
if defined HP_SKIP_EXE_SMOKERUN (
  call :log "[INFO] REQ-012: HP_SKIP_EXE_SMOKERUN set; skipping EXE verification (skipped by request)."
  set "HP_EXE_SKIPPED=1"
  exit /b 0
)
call :log "[INFO] EXE smokerun: testing dist\%ENVNAME%.exe"
call :log "[INFO] Running entry script smoke test via packaged EXE."
call :warn_user_code_launch
set "HP_EXE_EXIT=-1"
pushd dist
rem REQ-018 (2b-A.2): the EXE smoke runs from dist\ (CWD = dist) -- the working directory a frozen
rem EXE has always used here, and some tests depend on it (the selfapps_exedata_fail app opens a
rem CWD-relative config.json that MUST be absent at runtime, which only holds when CWD is dist\).
rem Capture the EXE stdout/stderr to the APP ROOT (..\~run.out.txt / ..\~run.err.txt) so the single
rem EXE verification produces the run artifacts the old interpreter smoke did -- the main 'smoke-ok'
rem token is on stdout. Note: an app that writes a file next to sys.argv[0] (e.g. the spaced-path
rem test's ~smoke_token.txt) writes it into dist\ for a frozen EXE, so selfapps_envsmoke.ps1 reads
rem that token from dist\. ReadToEndAsync drains both pipes before WaitForExit (no deadlock).
for /f "usebackq delims=" %%X in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$si=New-Object System.Diagnostics.ProcessStartInfo;$si.FileName='%ENVNAME%.exe';$si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$p=[System.Diagnostics.Process]::Start($si);$so=$p.StandardOutput.ReadToEndAsync();$se=$p.StandardError.ReadToEndAsync();$done=$p.WaitForExit(30000);if(-not $done){try{$p.Kill()}catch{}};$so.Result|Set-Content -Path '..\~run.out.txt' -Encoding ASCII;$se.Result|Set-Content -Path '..\~run.err.txt' -Encoding ASCII;if($done){$p.ExitCode}else{-1}"`) do set "HP_EXE_EXIT=%%X"
popd
if not defined HP_EXE_EXIT set "HP_EXE_EXIT=-1"
if "%HP_EXE_EXIT%"=="0" goto :smokerun_ok
call :log "[WARN] EXE smokerun: exited %HP_EXE_EXIT% (non-zero)"
rem Slice 2 (REQ-016): attempt strict --hidden-import auto-recovery before giving up.
rem Skip when HP_EXE_EXIT is -1 (a timeout/hang) -- re-running a hung EXE in the recovery
rem loop would hang too; only a real fast non-zero exit (e.g. ModuleNotFoundError) is fixable.
if not "%HP_EXE_EXIT%"=="-1" call :hidden_import_recover
if "%HP_EXE_EXIT%"=="0" goto :smokerun_ok
rem REQ-016: record that the packaged EXE could not be verified so the post-flight
rem briefing can guide the user to run the app directly instead of claiming success.
set "HP_EXE_VERIFY_FAILED=1"
rem a -1 is a timeout/hang: no parseable error to hint on, and re-running the EXE in
rem :exe_smokerun_hints would hang too -- skip straight to the post-flight caveat.
if not "%HP_EXE_EXIT%"=="-1" call :exe_smokerun_hints
goto :smokerun_ndjson
:smokerun_ok
call :log "[INFO] EXE smokerun: exited 0 (ok)"
set "HP_EXE_VERIFY_FAILED="
:smokerun_ndjson
rem REQ-018 (2b-A.2): unified verification vocabulary -- emit the same "Entry smoke exit=" line the
rem interpreter smoke used, so the single EXE verification satisfies the existing run assertions
rem (self.env.smoke.run / self.prime.run / self.prime.bootstrap) without re-pointing them.
call :log "[INFO] Entry smoke exit=%HP_EXE_EXIT%"
rem REQ-018 (2b-A): telemetry readout of the single verification run. HP_EXE_EXIT is the final
rem EXE exit after any hidden-import recovery: 0 = clean, -1 = the 30s cap was hit (force-stopped,
rem not necessarily broken), other = a real non-zero exit. This [STATUS] line is the readout the
rem 2b-C post-execution checkpoint (:run_postexec_checkpoint, called below) shows the user before
rem offering the elective second run. :log echoes unquoted, so keep the message free of
rem < > | & (parentheses are literal to echo outside if/for blocks).
if "%HP_EXE_EXIT%"=="0" (
  call :log "[STATUS] Run Status: SUCCESS (Exit Code: 0)"
) else if "%HP_EXE_EXIT%"=="-1" (
  call :log "[STATUS] Run Status: TIMED OUT (hit the ~30s verification cap; force-stopped, not necessarily broken)"
) else (
  call :log "[STATUS] Run Status: FAILED (Exit Code: %HP_EXE_EXIT%)"
)
if defined HP_NDJSON (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$c=[int]'%HP_EXE_EXIT%';" ^
    "$r=[ordered]@{id='self.exe.smokerun';pass=($c -eq 0);details=[ordered]@{exitCode=$c}}|ConvertTo-Json -Compress -Depth 8;" ^
    "Add-Content -Path '%HP_NDJSON%' -Value $r -Encoding ASCII" >> "%LOG%" 2>&1
)
call :run_postexec_checkpoint exe
set "HP_EXE_EXIT="
exit /b 0
:exe_smokerun_hints
rem derived requirement: re-run EXE briefly to capture stderr for pattern-based hints
rem only. EXE exits immediately on ModuleNotFoundError/FileNotFoundError so no timeout
rem is needed for hint capture. Existing success/failure logic is not changed.
if not exist "dist\%ENVNAME%.exe" exit /b 0
pushd dist
"%ENVNAME%.exe" > "~exe_out.txt" 2>&1
popd
set "HP_HINT_FILE=dist\~exe_out.txt"
set "HP_HINT_FILE_NAME=<file>"
set "HP_HINT_MOD=<module>"
findstr /i /c:"FileNotFoundError" /c:"No such file or directory" "%HP_HINT_FILE%" >nul 2>&1
if not errorlevel 1 goto :hint_data_file
goto :hint_check_mod
:hint_data_file
for /f "usebackq delims=" %%F in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText('%HP_HINT_FILE%');$m=[regex]::Match($t,'No such file or directory: ''([^'']+)''');if($m.Success){$m.Groups[1].Value}else{'<file>'}"`) do set "HP_HINT_FILE_NAME=%%F"
call :log "[HINT][DATA_FILE] Missing data file detected: %HP_HINT_FILE_NAME%"
call :log "[HINT][DATA_FILE] Consider adding: --add-data %HP_HINT_FILE_NAME%;."
if defined HINT_JSON powershell -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ([PSCustomObject]@{hint_type='DATA_FILE';file=$env:HP_HINT_FILE_NAME}|ConvertTo-Json -Compress)"
:hint_check_mod
findstr /i /c:"ModuleNotFoundError" /c:"No module named" "%HP_HINT_FILE%" >nul 2>&1
if not errorlevel 1 goto :hint_hidden_import
goto :hint_packaging
:hint_hidden_import
for /f "usebackq delims=" %%M in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText('%HP_HINT_FILE%');$m=[regex]::Match($t,'No module named ''([^'']+)''');if($m.Success){$m.Groups[1].Value}else{'<module>'}"`) do set "HP_HINT_MOD=%%M"
call :log "[HINT][HIDDEN_IMPORT] Hidden import likely missing: %HP_HINT_MOD%"
call :log "[HINT][HIDDEN_IMPORT] Consider adding: --hidden-import=%HP_HINT_MOD%"
if defined HINT_JSON powershell -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ([PSCustomObject]@{hint_type='HIDDEN_IMPORT';module=$env:HP_HINT_MOD}|ConvertTo-Json -Compress)"
:hint_packaging
call :log "[HINT][RUNTIME_MISMATCH] Standalone EXE behavior differs from the Python runtime (possible PyInstaller packaging issue in the EXE, not your environment or dependencies)"
if defined HINT_JSON powershell -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ([PSCustomObject]@{hint_type='RUNTIME_MISMATCH'}|ConvertTo-Json -Compress)"
if exist "%HP_HINT_FILE%" del "%HP_HINT_FILE%" >nul 2>&1
set "HP_HINT_FILE="
set "HP_HINT_FILE_NAME="
set "HP_HINT_MOD="
exit /b 0
:write_pipreqs_summary
if "%HP_JOB_SUMMARY%"=="" exit /b 0
set "HP_SUMMARY_PATH=%HP_JOB_SUMMARY%"
if not defined HP_PIPREQS_SUMMARY_PHASE set "HP_PIPREQS_SUMMARY_PHASE=<unknown>"
> "%HP_SUMMARY_PATH%" echo Interpreter: %HP_PY%
>> "%HP_SUMMARY_PATH%" echo Pipreqs command: pipreqs . --force --mode compat --savepath "%HP_PIPREQS_SUMMARY_CMD_PATH%"%HP_PIPREQS_SUMMARY_IGNORE%
if defined HP_PIPREQS_SUMMARY_NOTE (
  >> "%HP_SUMMARY_PATH%" echo Phase: %HP_PIPREQS_SUMMARY_PHASE% %HP_PIPREQS_SUMMARY_NOTE%
) else (
  >> "%HP_SUMMARY_PATH%" echo Phase: %HP_PIPREQS_SUMMARY_PHASE%
)
if defined HP_PIPREQS_FAILURE_LOG (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$summary = '%HP_SUMMARY_PATH%'; $logPath = '%HP_PIPREQS_FAILURE_LOG%';" ^
    "Add-Content -Path $summary -Value '---' -Encoding ASCII;" ^
    "Add-Content -Path $summary -Value 'Pipreqs log tail:' -Encoding ASCII;" ^
    "if (Test-Path $logPath) {" ^
    "  Get-Content -LiteralPath $logPath -Tail 20 | Out-File -FilePath $summary -Encoding ASCII -Append;" ^
    "} else {" ^
    "  Add-Content -Path $summary -Value '<log tail unavailable>' -Encoding ASCII;" ^
    "}" >> "%LOG%" 2>&1
)
exit /b 0

:write_status
set "HP_STATE=%~1"
set "HP_EXIT=%~2"
set "HP_PYFILES=%~3"
if "%HP_STATE%"=="" set "HP_STATE=error"
if "%HP_EXIT%"=="" set "HP_EXIT=0"
if "%HP_PYFILES%"=="" set "HP_PYFILES=%PYCOUNT%"
echo {"state":"%HP_STATE%","exitCode":%HP_EXIT%,"pyFiles":%HP_PYFILES%}> "%STATUS_FILE%"
if exist "%STATUS_FILE%" (
  if exist "~bootstrap.status.txt" del "~bootstrap.status.txt" >nul 2>&1
) else if /i "%HP_STATE%"=="no_python_files" (
  > "~bootstrap.status.txt" echo [INFO] Python file count: %HP_PYFILES%
  >> "~bootstrap.status.txt" echo [INFO] No Python files detected; skipping environment bootstrap.
)
set "HP_STATE="
set "HP_EXIT="
set "HP_PYFILES="
exit /b 0
:emit_from_base64
rem Decode helper payloads with PowerShell Convert.FromBase64String (see https://learn.microsoft.com/dotnet/api/system.convert.frombase64string).
rem Keep these helpers in sync with README.md regeneration notes.
set "DST=%~1"
set "VAR=%~2"
if not defined DST exit /b 1
if not defined VAR exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$varName = '%VAR%'; $envItem = Get-Item Env:$varName -ErrorAction SilentlyContinue; if (-not $envItem) { exit 1 }; $base64 = $envItem.Value; if (-not $base64) { exit 1 }; $outFile = Join-Path (Get-Location) '%DST%'; $bytes = [Convert]::FromBase64String($base64); [IO.File]::WriteAllBytes($outFile, $bytes)" >> "%LOG%" 2>&1
exit /b %errorlevel%
:define_helper_payloads
rem Helper payloads are base64-encoded so run_setup.bat stays self-contained.
rem Regenerate with python - <<'PY' snippets as noted in README.md (base64 docs: https://docs.python.org/3/library/base64.html).
set "HP_PYPROJ_DEPS=IiIicHlwcm9qX2RlcHMgKEhQX1BZUFJPSl9ERVBTKSAtLSBleHRyYWN0cyBbcHJvamVjdF0uZGVwZW5kZW5jaWVzIGZyb20KcHlwcm9qZWN0LnRvbWwsIHdyaXRpbmcgb25lIGRlcGVuZGVuY3kgcGVyIGxpbmUgdG8gYW4gb3V0cHV0IGZpbGUuCgpSdW4gZnJvbSB0aGUgYXBwbGljYXRpb24gZGlyZWN0b3J5IChyZWFkcyAicHlwcm9qZWN0LnRvbWwiIGZyb20gQ1dEKS4KVXNhZ2U6IHB5dGhvbiBweXByb2pfZGVwcy5weSBbb3V0cHV0X3BhdGhdICAoZGVmYXVsdCAifnJlcXVpcmVtZW50cy5weXByb2plY3QudHh0IikKCkV4aXQgY29kZXM6CiAgMCAtIHN1Y2Nlc3MsIGRlcGVuZGVuY2llcyB3cml0dGVuIHRvIHRoZSBvdXRwdXQgZmlsZQogIDEgLSBub3QtZm91bmQvZXJyb3IgKG5vIHB5cHJvamVjdC50b21sLCBubyBbcHJvamVjdF0uZGVwZW5kZW5jaWVzIGtleSwKICAgICAgb3IgYW4gZW1wdHkgZGVwZW5kZW5jaWVzIGxpc3QpCiAgMiAtIG1hbGZvcm1lZCBUT01MICh0b21sbGliIHJhaXNlZCwgb3IgLS0gd2hlbiB0b21sbGliIGlzIHVuYXZhaWxhYmxlIC0tCiAgICAgIHRoZSByZWdleCBmYWxsYmFjayBmb3VuZCBhbiB1bmNsb3NlZCAiW3Byb2plY3QiIGhlYWRlcikKClByZWZlcnMgc3RkbGliIHRvbWxsaWIgKDMuMTErKSB3aGVuIGF2YWlsYWJsZS4gRmFsbHMgYmFjayB0byBhIHJlZ2V4LWJhc2VkCmV4dHJhY3RvciB3aGVuIHRvbWxsaWIgaXMgbWlzc2luZyBPUiB0aGUgW3Byb2plY3RdIHRhYmxlIGhhcyBubwoiZGVwZW5kZW5jaWVzIiBrZXkgdmlhIHRvbWxsaWIgKHRoZSB0d28gY2FzZXMgYXJlIGluZGlzdGluZ3Vpc2hhYmxlIGZyb20KdG9tbGxpYidzIG93biByZXR1cm4gdmFsdWUsIHNvIHRoZSBmYWxsYmFjayBhbHdheXMgcmUtc2NhbnMgaW4gdGhhdCBjYXNlIC0tCmhhcm1sZXNzLCBzaW5jZSBhIGdlbnVpbmVseS1hYnNlbnQga2V5IGFsc28gZmluZHMgbm90aGluZyB2aWEgcmVnZXgpLiBUaGUKZmFsbGJhY2sncyBkZXBlbmRlbmN5LWFycmF5IHdhbGsgaXMgY2hhci1ieS1jaGFyIG92ZXIgcXVvdGVkIHN0cmluZ3MgKG5vdCBhCm5haXZlIGNvbW1hL25ld2xpbmUgc3BsaXQpIHNvIGl0IHByZXNlcnZlcyBleHRyYXMgKCJwa2dbYWxsXSIpIGFuZAptdWx0aS1jb25zdHJhaW50IHNwZWNpZmllcnMgKCJwa2c+PTQsPDUiKSBpbnRhY3QuCgpUaGlzIGlzIHRoZSBjYW5vbmljYWwgc291cmNlIGZvciB0aGUgSFBfUFlQUk9KX0RFUFMgYmFzZTY0IHBheWxvYWQgZW1iZWRkZWQKaW4gcnVuX3NldHVwLmJhdC4gQWZ0ZXIgZWRpdGluZywgcmUtZW5jb2RlIGFuZCBwYXN0ZSBpdCBpbnRvIHRoZQpgc2V0ICJIUF9QWVBST0pfREVQUz0uLi4iYCBsaW5lOyB0ZXN0cy90ZXN0X3B5cHJval9kZXBzLnB5IGFzc2VydHMgdGhlCmVtYmVkZGVkIHBheWxvYWQgbWF0Y2hlcyB0aGlzIGZpbGUuCiIiIgppbXBvcnQgc3lzLCBwYXRobGliCgp0cnk6CiAgICBpbXBvcnQgdG9tbGxpYgpleGNlcHQgSW1wb3J0RXJyb3I6CiAgICB0b21sbGliID0gTm9uZQoKb3V0ID0gc3lzLmFyZ3ZbMV0gaWYgbGVuKHN5cy5hcmd2KSA+IDEgZWxzZSAnfnJlcXVpcmVtZW50cy5weXByb2plY3QudHh0Jwp0cnk6CiAgICB0eHQgPSBwYXRobGliLlBhdGgoJ3B5cHJvamVjdC50b21sJykucmVhZF90ZXh0KGVuY29kaW5nPSd1dGYtOCcsIGVycm9ycz0ncmVwbGFjZScpCiAgICBkZXBzID0gTm9uZQogICAgaWYgdG9tbGxpYjoKICAgICAgICB0cnk6CiAgICAgICAgICAgIGRhdGEgPSB0b21sbGliLmxvYWRzKHR4dCkKICAgICAgICAgICAgZGVwcyA9IGRhdGEuZ2V0KCdwcm9qZWN0Jywge30pLmdldCgnZGVwZW5kZW5jaWVzJykKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAjIEV4aXQgMiBzaWduYWxzIGNhbGxlciB0byBlbWl0IFtXQVJOXTogcHlwcm9qZWN0LnRvbWwgaXMgbm90IHZhbGlkIFRPTUwuCiAgICAgICAgICAgIHN5cy5leGl0KDIpCiAgICBpZiBkZXBzIGlzIE5vbmU6CiAgICAgICAgaW1wb3J0IHJlCiAgICAgICAgbSA9IHJlLnNlYXJjaChyJ15cW3Byb2plY3RcXScsIHR4dCwgcmUuTVVMVElMSU5FKQogICAgICAgIGlmIG5vdCBtOgogICAgICAgICAgICAjIGRlcml2ZWQgcmVxdWlyZW1lbnQ6IHdpdGhvdXQgdG9tbGxpYiwgZGV0ZWN0IG9idmlvdXNseSBtYWxmb3JtZWQgW3Byb2plY3QgaGVhZGVyCiAgICAgICAgICAgICMgKG1pc3NpbmcgY2xvc2luZyBicmFja2V0IC0tIGUuZy4gIltwcm9qZWN0XG4iKS4gRXhpdCAyIHNvIGNhbGxlciBlbWl0cyBUT01MIHBhcnNlIHdhcm5pbmcuCiAgICAgICAgICAgIGlmIHJlLnNlYXJjaChyJ15cW3Byb2plY3RccyokJywgdHh0LCByZS5NVUxUSUxJTkUpOgogICAgICAgICAgICAgICAgc3lzLmV4aXQoMikKICAgICAgICAgICAgc3lzLmV4aXQoMSkKICAgICAgICBzZWMgPSB0eHRbbS5lbmQoKTpdCiAgICAgICAgc3RvcCA9IHJlLnNlYXJjaChyJ15cWycsIHNlYywgcmUuTVVMVElMSU5FKQogICAgICAgIGlmIHN0b3A6CiAgICAgICAgICAgIHNlYyA9IHNlY1s6c3RvcC5zdGFydCgpXQogICAgICAgIGRtID0gcmUuc2VhcmNoKHInXlxzKmRlcGVuZGVuY2llc1xzKj1ccypcWycsIHNlYywgcmUuTVVMVElMSU5FKQogICAgICAgIGlmIG5vdCBkbToKICAgICAgICAgICAgc3lzLmV4aXQoMSkKICAgICAgICByZXN0ID0gc2VjW2RtLmVuZCgpOl0KICAgICAgICAjIFdhbGsgY2hhci1ieS1jaGFyOiBjb2xsZWN0IG9ubHkgcXVvdGVkIHN0cmluZ3M7IHN0b3AgYXQgdW5xdW90ZWQgXQogICAgICAgICMgVGhpcyBwcmVzZXJ2ZXMgZnVsbCBkZXAgc3RyaW5ncyBpbmNsdWRpbmcgZXh0cmFzIChbYWxsXSkgYW5kCiAgICAgICAgIyBtdWx0aS1jb25zdHJhaW50IHNwZWNpZmllcnMgKD49NCw8NSkgd2l0aG91dCBuYWl2ZSBjb21tYS9uZXdsaW5lIHNwbGl0cy4KICAgICAgICBkZXBzID0gW10KICAgICAgICBpID0gMAogICAgICAgIHdoaWxlIGkgPCBsZW4ocmVzdCk6CiAgICAgICAgICAgIGMgPSByZXN0W2ldCiAgICAgICAgICAgIGlmIGMgaW4gKCciJywgIiciKToKICAgICAgICAgICAgICAgIHEgPSBjCiAgICAgICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgICAgIHN0YXJ0ID0gaQogICAgICAgICAgICAgICAgd2hpbGUgaSA8IGxlbihyZXN0KSBhbmQgcmVzdFtpXSAhPSBxOgogICAgICAgICAgICAgICAgICAgIGlmIHJlc3RbaV0gPT0gJ1xcJzoKICAgICAgICAgICAgICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgICAgICBkZXBzLmFwcGVuZChyZXN0W3N0YXJ0OmldKQogICAgICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGVsaWYgYyA9PSAnXSc6CiAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgaSArPSAxCiAgICBpZiBub3QgZGVwczoKICAgICAgICBzeXMuZXhpdCgxKQogICAgcGF0aGxpYi5QYXRoKG91dCkud3JpdGVfdGV4dCgnXG4nLmpvaW4oZGVwcykgKyAnXG4nLCBlbmNvZGluZz0nYXNjaWknLCBlcnJvcnM9J3JlcGxhY2UnKQogICAgc3lzLmV4aXQoMCkKZXhjZXB0IEV4Y2VwdGlvbjoKICAgIHN5cy5leGl0KDEpCg=="
set "HP_CONDARC=Y2hhbm5lbHM6CiAgLSBjb25kYS1mb3JnZQpjaGFubmVsX3ByaW9yaXR5OiBzdHJpY3QKc2hvd19jaGFubmVsX3VybHM6IHRydWUK"
set "HP_DETECT_PY=IiIiZGV0ZWN0X3B5dGhvbiAoSFBfREVURUNUX1BZKSAtLSBSRVEtMDA0IFRpZXIgMS8yIHJlcXVpcmVzLXB5dGhvbiBkZXRlY3Rvci4KClJ1biBmcm9tIHRoZSBhcHBsaWNhdGlvbiBkaXJlY3Rvcnk7IHByaW50cyBhIG5vcm1hbGl6ZWQgY29uZGEtc3ludGF4CiJweXRob248b3A+PHZlcj5bLC4uLl0iIGNvbnN0cmFpbnQgdG8gc3Rkb3V0LCBvciBhbiBlbXB0eSBsaW5lIGlmIG5laXRoZXIKdGllciBmb3VuZCBhbnl0aGluZyAodGhlIGNhbGxlciB0aGVuIGxldHMgdGhlIHNlbGVjdGVkIHByb3ZpZGVyIHBpY2sgdGhlCmxhdGVzdCBhdmFpbGFibGUgUHl0aG9uIC0tIFJFUS0wMDQgVGllciAzLCBoYW5kbGVkIG91dHNpZGUgdGhpcyBoZWxwZXIpLgpEZXRlY3Rpb24gb3JkZXI6CgogIDEuIHJ1bnRpbWUudHh0IC0tIGEgYmFyZSAicHl0aG9uLVguWVsuWl0iIG9yICJYLllbLlpdIiBsaW5lIHBpbnMgYW4gZXhhY3QKICAgICBtaW5vciB2ZXJzaW9uIChweXRob249WC5ZOyB0aGUgcGF0Y2ggY29tcG9uZW50LCBpZiBwcmVzZW50LCBpcyBub3QKICAgICBmb3J3YXJkZWQgLS0gcHJvdmlkZXJzIHBpbiBieSBtaW5vciBvbmx5KS4KICAyLiBweXByb2plY3QudG9tbCdzIFtwcm9qZWN0XSByZXF1aXJlcy1weXRob24gLS0gYSBQRVAgNDQwIHNwZWNpZmllcgogICAgIChlLmcuICI+PTMuMTAsPDQiLCAifj0zLjExIikgaXMgcGFyc2VkIGFuZCBleHBhbmRlZCBpbnRvIG9uZSBvciBtb3JlCiAgICAgY29uZGEtc3ludGF4IGNsYXVzZXMgdmlhIHBlcDQ0MF90b19jb25kYSgpLgoKcGVwNDQwX3RvX2NvbmRhKCkgYWxzbyBkb3VibGVzIGFzIGEgc3RhbmRhbG9uZSBDTEkgdXRpbGl0eSAoc2VlIG1haW4oKSkgZm9yCnRyYW5zbGF0aW5nIGFyYml0cmFyeSBQRVAgNDQwIHNwZWNpZmllcnMsIGluY2x1ZGluZyB0aGUgIn49IiBjb21wYXRpYmxlLXJlbGVhc2UKb3BlcmF0b3IsIHdoaWNoIGNvbmRhIGhhcyBubyBuYXRpdmUgZXF1aXZhbGVudCBmb3IgYW5kIG11c3QgYmUgZXhwYW5kZWQgaW50bwphbiBleHBsaWNpdCA+PS88IHJhbmdlLgoKVGhpcyBpcyB0aGUgY2Fub25pY2FsIHNvdXJjZSBmb3IgdGhlIEhQX0RFVEVDVF9QWSBiYXNlNjQgcGF5bG9hZCBlbWJlZGRlZCBpbgpydW5fc2V0dXAuYmF0LiBBZnRlciBlZGl0aW5nLCByZS1lbmNvZGUgYW5kIHBhc3RlIGl0IGludG8gdGhlCmBzZXQgIkhQX0RFVEVDVF9QWT0uLi4iYCBsaW5lOyB0ZXN0cy90ZXN0X2RldGVjdF9weXRob24ucHkgYXNzZXJ0cyB0aGUKZW1iZWRkZWQgcGF5bG9hZCBtYXRjaGVzIHRoaXMgZmlsZS4KIiIiCl9fdmVyc2lvbl9fID0gImRldGVjdF9weXRob24gdjIgKDIwMjUtMDktMjQpIgpfX2FsbF9fID0gWyJwZXA0NDBfdG9fY29uZGEiLCAiZGV0ZWN0X3JlcXVpcmVzX3B5dGhvbiIsICJtYWluIl0KT1JERVIgPSB7Ij09IjogMCwgIiE9IjogMSwgIj49IjogMiwgIj4iOiAzLCAiPD0iOiA0LCAiPCI6IDV9CgppbXBvcnQgb3MKaW1wb3J0IHJlCmltcG9ydCBzeXMKCiMgSGVscGVyIGltcGxlbWVudHMgdGhlIFJFQURNRSBib290c3RyYXAgY29udHJhY3QuIFBFUCA0NDAgZGV0YWlsczoKIyBodHRwczovL3BlcHMucHl0aG9uLm9yZy9wZXAtMDQ0MC8KCkNEID0gb3MuZ2V0Y3dkKCkKUlVOVElNRV9QQVRIID0gb3MucGF0aC5qb2luKENELCAicnVudGltZS50eHQiKQpQWVBST0pFQ1RfUEFUSCA9IG9zLnBhdGguam9pbihDRCwgInB5cHJvamVjdC50b21sIikKUFlQUk9KRUNUX1JFID0gcmUuY29tcGlsZSgicmVxdWlyZXMtcHl0aG9uXFxzKj1cXHMqWydcIl0oW14nXCJdKylbJ1wiXSIsIHJlLklHTk9SRUNBU0UpClNQRUNfUEFUVEVSTiA9IHJlLmNvbXBpbGUocicofj18PT18IT18Pj18PD18Pnw8KVxzKihbMC05XSsoPzpcLlswLTldKykqKScpCgoKZGVmIHZlcnNpb25fa2V5KHRleHQ6IHN0cik6CiAgICAiIiJSZXR1cm4gYSB0dXBsZSB1c2FibGUgZm9yIG51bWVyaWMgb3JkZXJpbmcgb2YgZG90dGVkIHZlcnNpb25zLiIiIgogICAgcGFydHMgPSBbXQogICAgZm9yIGNodW5rIGluIHRleHQuc3BsaXQoJy4nKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIHBhcnRzLmFwcGVuZChpbnQoY2h1bmspKQogICAgICAgIGV4Y2VwdCBWYWx1ZUVycm9yOgogICAgICAgICAgICBwYXJ0cy5hcHBlbmQoMCkKICAgIHJldHVybiB0dXBsZShwYXJ0cykKCgpkZWYgYnVtcF9mb3JfY29tcGF0aWJsZSh2ZXJzaW9uOiBzdHIpIC0+IHN0cjoKICAgICIiIlRyYW5zbGF0ZSB0aGUgUEVQIDQ0MCBjb21wYXRpYmxlIHJlbGVhc2UgdXBwZXIgYm91bmQuIiIiCiAgICBwaWVjZXMgPSBbaW50KGl0ZW0pIGZvciBpdGVtIGluIHZlcnNpb24uc3BsaXQoJy4nKSBpZiBpdGVtLmlzZGlnaXQoKV0KICAgIGlmIG5vdCBwaWVjZXM6CiAgICAgICAgcmV0dXJuIHZlcnNpb24KICAgIGlmIGxlbihwaWVjZXMpID49IDM6CiAgICAgICAgcmV0dXJuIGYie3BpZWNlc1swXX0ue3BpZWNlc1sxXSArIDF9IgogICAgaWYgbGVuKHBpZWNlcykgPT0gMjoKICAgICAgICByZXR1cm4gZiJ7cGllY2VzWzBdICsgMX0uMCIKICAgIHJldHVybiBzdHIocGllY2VzWzBdICsgMSkKCgpkZWYgZXhwYW5kX2NsYXVzZShvcDogc3RyLCB2ZXJzaW9uOiBzdHIpOgogICAgaWYgb3AgPT0gIn49IjoKICAgICAgICB1cHBlciA9IGJ1bXBfZm9yX2NvbXBhdGlibGUodmVyc2lvbikKICAgICAgICByZXR1cm4gWygiPj0iLCB2ZXJzaW9uKSwgKCI8IiwgdXBwZXIpXQogICAgcmV0dXJuIFsob3AsIHZlcnNpb24pXQoKCmRlZiBwZXA0NDBfdG9fY29uZGEoc3BlYzogc3RyKSAtPiBzdHI6CiAgICAiIiJSZXR1cm4gInB5dGhvbiIgY29uc3RyYWludHMgZXhwYW5kZWQgZnJvbSBhIHJlcXVpcmVzLXB5dGhvbiBzcGVjLiIiIgogICAgY2xhdXNlcyA9IFtdCiAgICBmb3IgcmF3IGluIHNwZWMuc3BsaXQoJywnKToKICAgICAgICByYXcgPSByYXcuc3RyaXAoKQogICAgICAgIGlmIG5vdCByYXc6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgbWF0Y2ggPSBTUEVDX1BBVFRFUk4ubWF0Y2gocmF3KQogICAgICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBvcCwgdmVyc2lvbiA9IG1hdGNoLmdyb3VwcygpCiAgICAgICAgY2xhdXNlcy5leHRlbmQoZXhwYW5kX2NsYXVzZShvcCwgdmVyc2lvbikpCiAgICBpZiBub3QgY2xhdXNlczoKICAgICAgICByZXR1cm4gIiIKICAgIGRlZHVwID0ge30KICAgIGZvciBvcCwgdmVyc2lvbiBpbiBjbGF1c2VzOgogICAgICAgIGRlZHVwWyhvcCwgdmVyc2lvbildID0gKG9wLCB2ZXJzaW9uKQogICAgb3JkZXJlZCA9IHNvcnRlZChkZWR1cC52YWx1ZXMoKSwga2V5PWxhbWJkYSBpdGVtOiAoT1JERVIuZ2V0KGl0ZW1bMF0sIDk5KSwgdmVyc2lvbl9rZXkoaXRlbVsxXSkpKQogICAgcmV0dXJuICJweXRob24iICsgIiwiLmpvaW4oZiJ7b3B9e3ZlcnNpb259IiBmb3Igb3AsIHZlcnNpb24gaW4gb3JkZXJlZCkKCgpkZWYgcmVhZF9ydW50aW1lX3NwZWMoKSAtPiBzdHI6CiAgICBpZiBub3Qgb3MucGF0aC5leGlzdHMoUlVOVElNRV9QQVRIKToKICAgICAgICByZXR1cm4gIiIKICAgIHdpdGggb3BlbihSVU5USU1FX1BBVEgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgdGV4dCA9IGhhbmRsZS5yZWFkKCkKICAgIG1hdGNoID0gcmUuc2VhcmNoKHInKD86cHl0aG9uWy09XSk/XHMqKFswLTldKyg/OlwuWzAtOV0rKXswLDJ9KScsIHRleHQpCiAgICBpZiBub3QgbWF0Y2g6CiAgICAgICAgcmV0dXJuICIiCiAgICBwYXJ0cyA9IG1hdGNoLmdyb3VwKDEpLnNwbGl0KCcuJykKICAgIG1ham9yX21pbm9yID0gJy4nLmpvaW4ocGFydHNbOjJdKQogICAgcmV0dXJuIGYncHl0aG9uPXttYWpvcl9taW5vcn0nCgoKZGVmIHJlYWRfcHlwcm9qZWN0X3NwZWMoKSAtPiBzdHI6CiAgICBpZiBub3Qgb3MucGF0aC5leGlzdHMoUFlQUk9KRUNUX1BBVEgpOgogICAgICAgIHJldHVybiAiIgogICAgd2l0aCBvcGVuKFBZUFJPSkVDVF9QQVRILCAncicsIGVuY29kaW5nPSd1dGYtOCcsIGVycm9ycz0naWdub3JlJykgYXMgaGFuZGxlOgogICAgICAgIHRleHQgPSBoYW5kbGUucmVhZCgpCiAgICBtYXRjaCA9IFBZUFJPSkVDVF9SRS5zZWFyY2godGV4dCkKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByZXR1cm4gIiIKICAgIHJldHVybiBwZXA0NDBfdG9fY29uZGEobWF0Y2guZ3JvdXAoMSkpCgoKZGVmIGRldGVjdF9yZXF1aXJlc19weXRob24oKSAtPiBzdHI6CiAgICAiIiJSZXR1cm4gYmVzdC1lZmZvcnQgcmVxdWlyZXMtcHl0aG9uIGNvbnN0cmFpbnQgZm9yIHRoZSBjdXJyZW50IHByb2plY3QuIiIiCiAgICBydW50aW1lX3NwZWMgPSByZWFkX3J1bnRpbWVfc3BlYygpCiAgICBpZiBydW50aW1lX3NwZWM6CiAgICAgICAgcmV0dXJuIHJ1bnRpbWVfc3BlYwogICAgcmV0dXJuIHJlYWRfcHlwcm9qZWN0X3NwZWMoKQoKCmRlZiBtYWluKGFyZ3Y9Tm9uZSkgLT4gTm9uZToKICAgICIiIkNMSSBlbnRyeSBwb2ludCB0aGF0IHByaW50cyBub3JtYWxpemVkIHJlcXVpcmVzLXB5dGhvbiBjb25zdHJhaW50cy4iIiIKICAgIGFyZ3MgPSBsaXN0KHN5cy5hcmd2WzE6XSBpZiBhcmd2IGlzIE5vbmUgZWxzZSBhcmd2KQogICAgaWYgYXJncyBhbmQgYXJnc1swXSA9PSAiLS1zZWxmLXRlc3QiOgogICAgICAgIGZvciBzYW1wbGUgaW4gKCJ+PTMuMTAiLCAifj0zLjguMSIpOgogICAgICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKHBlcDQ0MF90b19jb25kYShzYW1wbGUpICsgIlxuIikKCiAgICAgICAgcmV0dXJuCiAgICBpZiBhcmdzOgogICAgICAgIGZvciBpdGVtIGluIGFyZ3M6CiAgICAgICAgICAgIHN5cy5zdGRvdXQud3JpdGUocGVwNDQwX3RvX2NvbmRhKGl0ZW0pICsgIlxuIikKCiAgICAgICAgcmV0dXJuCiAgICBzeXMuc3Rkb3V0LndyaXRlKGRldGVjdF9yZXF1aXJlc19weXRob24oKSArICJcbiIpCgoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK"
set "HP_PRINT_PYVER=aW1wb3J0IHN5cwoKcHJpbnQoZiJweXRob24te3N5cy52ZXJzaW9uX2luZm9bMF19LntzeXMudmVyc2lvbl9pbmZvWzFdfS57c3lzLnZlcnNpb25faW5mb1syXX0iKQo="
rem HP_FAST_CHECK decoded content:
rem $exe = $args[0]
rem if (-not $exe) { $exe = $env:HP_FAST_EXE }
rem $infraPattern = '(?i)(^|[/\\])(\.git|\.github|dist|\.venv|\.uv_env|__pycache__|\.conda)([/\\]|$)'
rem $sources = Get-ChildItem -Recurse -File -Filter '*.py' | Where-Object { $_.FullName -notmatch $infraPattern -and $_.Name -notlike '~*.py' }
rem if (-not $sources) { exit 1 }
rem $latest = ($sources | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
rem $exeTime = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
rem if ($exeTime -ge $latest) { 'fresh' }
rem If HP_FAST_CHECK changes, update this decoded comment block to match the base64 payload.
set "HP_FAST_CHECK=JGV4ZSA9ICRhcmdzWzBdCmlmICgtbm90ICRleGUpIHsgJGV4ZSA9ICRlbnY6SFBfRkFTVF9FWEUgfQokaW5mcmFQYXR0ZXJuID0gJyg/aSkoXnxbL1xcXSkoXC5naXR8XC5naXRodWJ8ZGlzdHxcLnZlbnZ8XC51dl9lbnZ8X19weWNhY2hlX198XC5jb25kYSkoWy9cXF18JCknCiRzb3VyY2VzID0gR2V0LUNoaWxkSXRlbSAtUmVjdXJzZSAtRmlsZSAtRmlsdGVyICcqLnB5JyB8IFdoZXJlLU9iamVjdCB7ICRfLkZ1bGxOYW1lIC1ub3RtYXRjaCAkaW5mcmFQYXR0ZXJuIC1hbmQgJF8uTmFtZSAtbm90bGlrZSAnfioucHknIH0KaWYgKC1ub3QgJHNvdXJjZXMpIHsgZXhpdCAxIH0KJGxhdGVzdCA9ICgkc291cmNlcyB8IFNvcnQtT2JqZWN0IC1Qcm9wZXJ0eSBMYXN0V3JpdGVUaW1lVXRjIC1EZXNjZW5kaW5nIHwgU2VsZWN0LU9iamVjdCAtRmlyc3QgMSkuTGFzdFdyaXRlVGltZVV0YwokZXhlVGltZSA9IChHZXQtSXRlbSAtTGl0ZXJhbFBhdGggJGV4ZSkuTGFzdFdyaXRlVGltZVV0YwppZiAoJGV4ZVRpbWUgLWdlICRsYXRlc3QpIHsgJ2ZyZXNoJyB9Cg=="
set "HP_EMBED_EXTRACT=IyBSRVEtMDA5IFRpZXIgNTogdmVyaWZpZXMgY2hlY2tzdW0sIGV4dHJhY3RzLCBhbmQgcGF0Y2hlcyB0aGUgZGlzYWJsZWQtc2l0ZS1pbXBvcnRzIC5fcHRoIGZpbGUKIyBmb3IgYW4gYWxyZWFkeS1kb3dubG9hZGVkIGVtYmVkZGFibGUgUHl0aG9uIHppcC4gQmF0Y2ggaGFzIGFscmVhZHkgZG93bmxvYWRlZCB0aGUgemlwICh2aWEgdGhlCiMgc2FtZSBjdXJsLXRoZW4tSW52b2tlLVdlYlJlcXVlc3QgcGF0dGVybiBhcyA6ZG93bmxvYWRfbWluaWNvbmRhX2V4ZS86ZG93bmxvYWRfZ2V0X3BpcCkgYW5kCiMgcGFzc2VzIGl0cyBwYXRoIHBsdXMgdGhlIGV4cGVjdGVkIFNIQTI1NiBhbmQgZGVzdGluYXRpb24gZGlyZWN0b3J5IGFzIGFyZ3MuIFRoaXMgc2NyaXB0IGRvZXMKIyBOT1QgZG93bmxvYWQgYW55dGhpbmcgaXRzZWxmIGFuZCBkb2VzIE5PVCBicmFuY2ggb24gcmVxdWVzdGVkIHZlcnNpb24gLS0gc2VlIHRoZSBQeXRob24tc2lkZQojIHN0YWdlIGZvciBwZXItcmVxdWVzdCB2ZXJzaW9uIHNlbGVjdGlvbi4KIyBBcmdzOiAkMSA9IHppcCBwYXRoLCAkMiA9IGV4cGVjdGVkIHNoYTI1NiAobG93ZXJjYXNlIGhleCksICQzID0gZGVzdGluYXRpb24gZGlyZWN0b3J5LgojIE91dHB1dDogb24gc3VjY2VzcywgcHJpbnRzIHRoZSBleHRyYWN0ZWQgcHl0aG9uLmV4ZSBwYXRoIG9uIHN0ZG91dCwgZXhpdCAwLiBPbiBmYWlsdXJlCiMgKGNoZWNrc3VtIG1pc21hdGNoLCBleHRyYWN0aW9uIGZhaWx1cmUsIG1pc3NpbmcgLl9wdGgsIG1pc3NpbmcgcHl0aG9uLmV4ZSksIHByaW50cyBub3RoaW5nIGFuZAojIGV4aXRzIDEgLS0gY2FsbGVyIGNoZWNrcyBib3RoIHN0ZG91dCBhbmQgZXhpdCBjb2RlLgojCiMgZGVyaXZlZCByZXF1aXJlbWVudDogaGFzaGluZy9leHRyYWN0aW9uL3RleHQtSU8gZGVsaWJlcmF0ZWx5IHVzZSByYXcgLk5FVCBBUElzCiMgKFtTeXN0ZW0uU2VjdXJpdHkuQ3J5cHRvZ3JhcGh5LlNIQTI1Nl0sIFtTeXN0ZW0uSU8uQ29tcHJlc3Npb24uWmlwRmlsZV0sIFtTeXN0ZW0uSU8uRmlsZV0pCiMgaW5zdGVhZCBvZiB0aGUgR2V0LUZpbGVIYXNoIC8gRXhwYW5kLUFyY2hpdmUgLyBHZXQtQ29udGVudCAvIFNldC1Db250ZW50IGNtZGxldHMuIENvbmZpcm1lZCB2aWEKIyByZWFsIENJIGZhaWx1cmUgKFdpbmRvd3MgUG93ZXJTaGVsbCA1LjEsIGludm9rZWQgYXMgYSBmb3IgL2YgYmFja3RpY2sgc3Vic2hlbGwgZnJvbSBydW5fc2V0dXAuYmF0KQojIHRoYXQgR2V0LUZpbGVIYXNoIHRocm93cyAibm90IHJlY29nbml6ZWQgYXMgdGhlIG5hbWUgb2YgYSBjbWRsZXQiIGluIHRoYXQgZXhhY3QgaW52b2NhdGlvbgojIGNvbnRleHQgLS0gaXRzIG1vZHVsZSAoTWljcm9zb2Z0LlBvd2VyU2hlbGwuVXRpbGl0eSkgd2FzIG5vdCBhdXRvLWxvYWRpbmcsIGV2ZW4gdGhvdWdoIHRoaXMKIyBzY3JpcHQgdGVzdGVkIGZpbmUgbG9jYWxseSB1bmRlciBwd3NoIChQb3dlclNoZWxsIDcgb24gTGludXgpIGJlZm9yZWhhbmQsIHdoaWNoIGRvZXMgbm90IHNoYXJlCiMgdGhlIHNhbWUgbW9kdWxlLWxvYWRpbmcgYmVoYXZpb3IuIFRlc3QtUGF0aC9HZXQtSXRlbSAoTWljcm9zb2Z0LlBvd2VyU2hlbGwuTWFuYWdlbWVudCkgd29ya2VkCiMgZmluZSBpbiB0aGUgc2FtZSBydW4sIHNvIHRoaXMgaXMgc2NvcGVkIHRvIFV0aWxpdHktbW9kdWxlIGNtZGxldHMgc3BlY2lmaWNhbGx5OyAuTkVUIHR5cGVzIGhhdmUKIyBubyBtb2R1bGUtbG9hZGluZyBkZXBlbmRlbmN5IGF0IGFsbCBhbmQgc2lkZXN0ZXAgdGhlIHdob2xlIGNsYXNzIG9mIGZhaWx1cmUuIFNlZQojIGRvY3MvYWdlbnQtbGVzc29ucy1sZWFybmVkLm1kLgokWmlwUGF0aCA9ICRhcmdzWzBdCiRFeHBlY3RlZFNoYTI1NiA9ICRhcmdzWzFdCiREZXN0RGlyID0gJGFyZ3NbMl0KCnRyeSB7CiAgICBpZiAoLW5vdCAoVGVzdC1QYXRoIC1MaXRlcmFsUGF0aCAkWmlwUGF0aCkpIHsKICAgICAgICBbQ29uc29sZV06OkVycm9yLldyaXRlTGluZSgiW2VtYmVkX2V4dHJhY3RdIHppcCBub3QgZm91bmQ6ICRaaXBQYXRoIikKICAgICAgICBleGl0IDEKICAgIH0KICAgICRaaXBTaXplID0gKEdldC1JdGVtIC1MaXRlcmFsUGF0aCAkWmlwUGF0aCkuTGVuZ3RoCiAgICAkU2hhMjU2UHJvdmlkZXIgPSBbU3lzdGVtLlNlY3VyaXR5LkNyeXB0b2dyYXBoeS5TSEEyNTZdOjpDcmVhdGUoKQogICAgJEZpbGVTdHJlYW0gPSBbU3lzdGVtLklPLkZpbGVdOjpPcGVuUmVhZCgkWmlwUGF0aCkKICAgIHRyeSB7CiAgICAgICAgJEhhc2hCeXRlcyA9ICRTaGEyNTZQcm92aWRlci5Db21wdXRlSGFzaCgkRmlsZVN0cmVhbSkKICAgIH0gZmluYWxseSB7CiAgICAgICAgJEZpbGVTdHJlYW0uRGlzcG9zZSgpCiAgICAgICAgJFNoYTI1NlByb3ZpZGVyLkRpc3Bvc2UoKQogICAgfQogICAgJEFjdHVhbEhhc2ggPSAoW0JpdENvbnZlcnRlcl06OlRvU3RyaW5nKCRIYXNoQnl0ZXMpIC1yZXBsYWNlICctJywgJycpLlRvTG93ZXIoKQogICAgaWYgKCRBY3R1YWxIYXNoIC1uZSAkRXhwZWN0ZWRTaGEyNTYuVG9Mb3dlcigpKSB7CiAgICAgICAgW0NvbnNvbGVdOjpFcnJvci5Xcml0ZUxpbmUoIltlbWJlZF9leHRyYWN0XSBjaGVja3N1bSBtaXNtYXRjaDogc2l6ZT0kWmlwU2l6ZSBleHBlY3RlZD0kKCRFeHBlY3RlZFNoYTI1Ni5Ub0xvd2VyKCkpIGFjdHVhbD0kQWN0dWFsSGFzaCIpCiAgICAgICAgZXhpdCAxCiAgICB9CgogICAgaWYgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJERlc3REaXIpIHsgUmVtb3ZlLUl0ZW0gLVJlY3Vyc2UgLUZvcmNlIC1MaXRlcmFsUGF0aCAkRGVzdERpciB9CiAgICBBZGQtVHlwZSAtQXNzZW1ibHlOYW1lIFN5c3RlbS5JTy5Db21wcmVzc2lvbi5GaWxlU3lzdGVtCiAgICBbU3lzdGVtLklPLkNvbXByZXNzaW9uLlppcEZpbGVdOjpFeHRyYWN0VG9EaXJlY3RvcnkoJFppcFBhdGgsICREZXN0RGlyKQoKICAgICRQdGhGaWxlID0gR2V0LUNoaWxkSXRlbSAtTGl0ZXJhbFBhdGggJERlc3REaXIgLUZpbHRlciAicHl0aG9uKi5fcHRoIiAtRmlsZSB8IFNlbGVjdC1PYmplY3QgLUZpcnN0IDEKICAgIGlmICgtbm90ICRQdGhGaWxlKSB7CiAgICAgICAgW0NvbnNvbGVdOjpFcnJvci5Xcml0ZUxpbmUoIltlbWJlZF9leHRyYWN0XSBubyBweXRob24qLl9wdGggZmlsZSBmb3VuZCB1bmRlciAkRGVzdERpciIpCiAgICAgICAgZXhpdCAxCiAgICB9CiAgICAjIGRlcml2ZWQgcmVxdWlyZW1lbnQ6IHRoZSBlbWJlZGRhYmxlIHppcCdzIC5fcHRoIGZpbGUgc2hpcHMgd2l0aCBDUkxGIGxpbmUgZW5kaW5ncywgYW5kCiAgICAjIC5ORVQgcmVnZXggJCBpbiBtdWx0aWxpbmUgbW9kZSBtYXRjaGVzIGltbWVkaWF0ZWx5IGJlZm9yZSBcbiAtLSBpdCBkb2VzIG5vdCBza2lwIGEKICAgICMgcHJlY2VkaW5nIFxyLCBzbyBhbiBhbmNob3Igb2YgIl4jaW1wb3J0IHNpdGUkIiBhZ2FpbnN0IGEgQ1JMRiBsaW5lIHNpbGVudGx5IG5ldmVyIG1hdGNoZXMKICAgICMgKHRoZSBcciBzaXRzIGJldHdlZW4gInNpdGUiIGFuZCB0aGUgbWF0Y2ggcG9zaXRpb24pLiBccj8gaGFuZGxlcyBib3RoIGxpbmUtZW5kaW5nIHN0eWxlcy4KICAgICRQdGhDb250ZW50ID0gW1N5c3RlbS5JTy5GaWxlXTo6UmVhZEFsbFRleHQoJFB0aEZpbGUuRnVsbE5hbWUpCiAgICAkUHRoQ29udGVudCA9ICRQdGhDb250ZW50IC1yZXBsYWNlICcoP20pXiNpbXBvcnQgc2l0ZVxyPyQnLCAnaW1wb3J0IHNpdGUnCiAgICBbU3lzdGVtLklPLkZpbGVdOjpXcml0ZUFsbFRleHQoJFB0aEZpbGUuRnVsbE5hbWUsICRQdGhDb250ZW50LCBbU3lzdGVtLlRleHQuRW5jb2RpbmddOjpBU0NJSSkKCiAgICAkUHlFeGUgPSBKb2luLVBhdGggJERlc3REaXIgInB5dGhvbi5leGUiCiAgICBpZiAoLW5vdCAoVGVzdC1QYXRoIC1MaXRlcmFsUGF0aCAkUHlFeGUpKSB7CiAgICAgICAgW0NvbnNvbGVdOjpFcnJvci5Xcml0ZUxpbmUoIltlbWJlZF9leHRyYWN0XSBweXRob24uZXhlIG1pc3NpbmcgYWZ0ZXIgZXh0cmFjdGlvbjogJFB5RXhlIikKICAgICAgICBleGl0IDEKICAgIH0KICAgIFtDb25zb2xlXTo6V3JpdGUoJFB5RXhlKQp9IGNhdGNoIHsKICAgIFtDb25zb2xlXTo6RXJyb3IuV3JpdGVMaW5lKCJbZW1iZWRfZXh0cmFjdF0gZXhjZXB0aW9uOiAkKCRfLkV4Y2VwdGlvbi5NZXNzYWdlKSIpCiAgICBleGl0IDEKfQo="
set "HP_EMBED_PYVER_CHECK=IyBSRVEtMDA5IFRpZXIgNSwgUHl0aG9uIHN0YWdlOiBydW5zIHVuZGVyIHRoZSAiYWx3YXlzIGxhdGVzdCIgaW50ZXJwcmV0ZXIgfmVtYmVkX2V4dHJhY3QucHMxCiMgKFBvd2VyU2hlbGwgc3RhZ2UpIGFscmVhZHkgZG93bmxvYWRlZC92ZXJpZmllZC9leHRyYWN0ZWQuIFRoaXMgaXMgdGhlIE9OTFkgcGxhY2UgcGVyLXJlcXVlc3QKIyB2ZXJzaW9uIGxvZ2ljIGxpdmVzIC0tIGRlbGliZXJhdGVseSBQeXRob24sIG5vdCBQb3dlclNoZWxsLCByZXVzaW5nIHRoaXMgY29kZWJhc2UncyBwcm92ZW4KIyB2ZXJzaW9uLWRldGVjdGlvbiBwYXR0ZXJuIGluc3RlYWQgb2YgcmUtZGVyaXZpbmcgaXQgaW4gUG93ZXJTaGVsbC4gRnVsbCByYXRpb25hbGU6CiMgZG9jcy9hZ2VudC1pbnRlcmNvbm5lY3QubWQgIlN0YW5kYWxvbmUgUHl0aG9uLWRvd25sb2FkIHRpZXIiLiAiMy4xNCIgZW50cnkgYmVsb3cgTVVTVCBtYXRjaAojIEhQX0VNQkVEX0xBVEVTVF9QQVRDSC9IUF9FTUJFRF9MQVRFU1RfU0hBMjU2IGluIHJ1bl9zZXR1cC5iYXQgLS0gYSBQYXlsb2FkU3luYy1zdHlsZSB1bml0IHRlc3QKIyBhc3NlcnRzIHRoaXMuIExhc3QgcmVmcmVzaGVkOiAyMDI2LTA3LTA5LgppbXBvcnQgaGFzaGxpYgppbXBvcnQgb3MKaW1wb3J0IHJlCmltcG9ydCBzaHV0aWwKaW1wb3J0IHNvY2tldAppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIucmVxdWVzdAppbXBvcnQgemlwZmlsZQoKIyBkZXJpdmVkIHJlcXVpcmVtZW50OiB1cmxsaWIucmVxdWVzdC51cmxyZXRyaWV2ZSBoYXMgbm8gdGltZW91dD0gcGFyYW1ldGVyICh2ZXJpZmllZCB2aWEKIyBpbnNwZWN0LnNpZ25hdHVyZSAtLSBwYXNzaW5nIG9uZSByYWlzZXMgVHlwZUVycm9yKSwgc28gYSBzdGFsbGVkIChub3QgcmVmdXNlZCkgY29ubmVjdGlvbgojIGR1cmluZyBkb3dubG9hZF9hbmRfdmVyaWZ5KCkgd291bGQgb3RoZXJ3aXNlIGhhbmcgdGhpcyBvbmUtc2hvdCBzY3JpcHQgZm9yZXZlci4gQSBnbG9iYWwKIyBkZWZhdWx0IHRpbWVvdXQgaXMgc2FmZSBoZXJlIHNpbmNlIHRoZSB3aG9sZSBzY3JpcHQgZXhpdHMgaW1tZWRpYXRlbHkgYWZ0ZXIgdXNlIC0tIG5vdGhpbmcKIyBlbHNlIGluIHRoaXMgc2hvcnQtbGl2ZWQgcHJvY2VzcyBpcyBhZmZlY3RlZC4gTWlycm9ycyB0aGUgY3VybCAtLW1heC10aW1lIDEyMCBhbHJlYWR5IHVzZWQKIyBmb3IgdGhlIFBvd2VyU2hlbGwtc3RhZ2UgZG93bmxvYWQgb2YgdGhlIHNhbWUgemlwIGZhbWlseS4Kc29ja2V0LnNldGRlZmF1bHR0aW1lb3V0KDEyMCkKCiMgbWlub3IgLT4gKHBhdGNoLCBzaGEyNTYpCkVNQkVEX1BZVEhPTl9UQUJMRSA9IHsKICAgICIzLjEwIjogKCIzLjEwLjExIiwgIjYwODYxOWY4NjE5MDc1NjI5YzljNjlmMzYxMzUyYTBkYTZlZDdlNjJmODNhMGUxOWM2M2UwZWEzMmViNzYyOWQiKSwKICAgICIzLjExIjogKCIzLjExLjkiLCAiMDA5ZDZiZjdlM2IyZGRjYTNkNzg0ZmEwOWY5MGZlNTQzMzZkNWI2MGYwZTBmMzA1YzM3ZjQwMGJmODNjZmQzYiIpLAogICAgIjMuMTIiOiAoIjMuMTIuMTAiLCAiNGFjYmVkNmRkMWM3NDRiMDM3NmUzYjFjZjU3Y2U5MDZmOWRjOWU5NWU2ODgyNDU4NGM4MDk5YTYzMDI1YTNjMyIpLAogICAgIjMuMTMiOiAoIjMuMTMuMTQiLCAiOTBiNGU1Yjk4OThiNzJkNzQ0NjUwNTI0YmZmOTIzNzdjMzY3ZjQ0YmQ1ZmJkMDllMzE0ODY1NmMwODBhZDkwNyIpLAogICAgIjMuMTQiOiAoIjMuMTQuNiIsICJkZjkwMWU4NGE4OTZmZjFlZTcyMGFkMDMzNzdlMGM4ZDhjMjI0NGZkYTc5ODA4YWVlYWZmNjMxNmRmMWNiNzVjIiksCn0KTEFURVNUX01JTk9SID0gIjMuMTQiCkZMT09SX01JTk9SID0gIjMuMTAiCgpTUEVDX01JTk9SX1JFID0gcmUuY29tcGlsZShyIihbMC05XStcLlswLTldKykiKQoKCmRlZiBfbWlub3Jfa2V5KG1pbm9yKToKICAgIHRyeToKICAgICAgICBtYWpvciwgc3ViID0gbWlub3Iuc3BsaXQoIi4iKQogICAgICAgIHJldHVybiAoaW50KG1ham9yKSwgaW50KHN1YikpCiAgICBleGNlcHQgKFZhbHVlRXJyb3IsIEF0dHJpYnV0ZUVycm9yKToKICAgICAgICByZXR1cm4gKDAsIDApCgoKZGVmIHJlc29sdmVfcmVxdWVzdGVkX21pbm9yKHB5c3BlYyk6CiAgICAjIEV4dHJhY3RzICJYLlkiIGZyb20gYSBQWVNQRUMgc3RyaW5nIChlLmcuICJweXRob24+PTMuMTAsPDQuMCIpOyBOb25lIGlmIGVtcHR5L3VucGFyc2VhYmxlLgogICAgaWYgbm90IHB5c3BlYzoKICAgICAgICByZXR1cm4gTm9uZQogICAgbWF0Y2ggPSBTUEVDX01JTk9SX1JFLnNlYXJjaChweXNwZWMpCiAgICByZXR1cm4gbWF0Y2guZ3JvdXAoMSkgaWYgbWF0Y2ggZWxzZSBOb25lCgoKZGVmIHJlc29sdmVfdGFibGVfZW50cnkocmVxdWVzdGVkX21pbm9yKToKICAgICMgUmV0dXJucyAobWlub3IsIHBhdGNoLCBzaGEyNTYsIGZlbGxfYmFjayk7IG1pcnJvcnMgdGhlIFBvd2VyU2hlbGwgc3RhZ2UncyBvd24gcnVsZXMuCiAgICBpZiByZXF1ZXN0ZWRfbWlub3IgaW4gRU1CRURfUFlUSE9OX1RBQkxFOgogICAgICAgIHBhdGNoLCBzaGEyNTYgPSBFTUJFRF9QWVRIT05fVEFCTEVbcmVxdWVzdGVkX21pbm9yXQogICAgICAgIHJldHVybiByZXF1ZXN0ZWRfbWlub3IsIHBhdGNoLCBzaGEyNTYsIEZhbHNlCiAgICBtaW5vciA9IEZMT09SX01JTk9SIGlmIF9taW5vcl9rZXkocmVxdWVzdGVkX21pbm9yKSA8IF9taW5vcl9rZXkoRkxPT1JfTUlOT1IpIGVsc2UgTEFURVNUX01JTk9SCiAgICBwYXRjaCwgc2hhMjU2ID0gRU1CRURfUFlUSE9OX1RBQkxFW21pbm9yXQogICAgcmV0dXJuIG1pbm9yLCBwYXRjaCwgc2hhMjU2LCBUcnVlCgoKZGVmIGRvd25sb2FkX2FuZF92ZXJpZnkodXJsLCBleHBlY3RlZF9zaGEyNTYsIGRlc3RfemlwKToKICAgIHVybGxpYi5yZXF1ZXN0LnVybHJldHJpZXZlKHVybCwgZGVzdF96aXApCiAgICBkaWdlc3QgPSBoYXNobGliLnNoYTI1NigpCiAgICB3aXRoIG9wZW4oZGVzdF96aXAsICJyYiIpIGFzIGZoOgogICAgICAgIGZvciBjaHVuayBpbiBpdGVyKGxhbWJkYTogZmgucmVhZCgxIDw8IDIwKSwgYiIiKToKICAgICAgICAgICAgZGlnZXN0LnVwZGF0ZShjaHVuaykKICAgIGFjdHVhbCA9IGRpZ2VzdC5oZXhkaWdlc3QoKS5sb3dlcigpCiAgICBpZiBhY3R1YWwgIT0gZXhwZWN0ZWRfc2hhMjU2Lmxvd2VyKCk6CiAgICAgICAgb3MucmVtb3ZlKGRlc3RfemlwKQogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoImNoZWNrc3VtIG1pc21hdGNoOiBleHBlY3RlZCB7fSwgZ290IHt9Ii5mb3JtYXQoZXhwZWN0ZWRfc2hhMjU2LCBhY3R1YWwpKQoKCmRlZiBleHRyYWN0X2FuZF9wYXRjaCh6aXBfcGF0aCwgZGVzdF9kaXIpOgogICAgaWYgb3MucGF0aC5pc2RpcihkZXN0X2Rpcik6CiAgICAgICAgc2h1dGlsLnJtdHJlZShkZXN0X2RpcikKICAgIHdpdGggemlwZmlsZS5aaXBGaWxlKHppcF9wYXRoKSBhcyB6ZjoKICAgICAgICB6Zi5leHRyYWN0YWxsKGRlc3RfZGlyKQogICAgcHRoX2ZpbGVzID0gW2YgZm9yIGYgaW4gb3MubGlzdGRpcihkZXN0X2RpcikgaWYgcmUubWF0Y2gociJecHl0aG9uXGQrXC5fcHRoJCIsIGYpXQogICAgaWYgbm90IHB0aF9maWxlczoKICAgICAgICByYWlzZSBGaWxlTm90Rm91bmRFcnJvcigibm8gcHl0aG9uKi5fcHRoIGZpbGUgZm91bmQgYWZ0ZXIgZXh0cmFjdGlvbiIpCiAgICBwdGhfcGF0aCA9IG9zLnBhdGguam9pbihkZXN0X2RpciwgcHRoX2ZpbGVzWzBdKQogICAgd2l0aCBvcGVuKHB0aF9wYXRoLCAiciIsIGVuY29kaW5nPSJhc2NpaSIpIGFzIGZoOgogICAgICAgIGNvbnRlbnQgPSBmaC5yZWFkKCkKICAgIGNvbnRlbnQgPSByZS5zdWIociIoP20pXiNpbXBvcnQgc2l0ZSQiLCAiaW1wb3J0IHNpdGUiLCBjb250ZW50KQogICAgd2l0aCBvcGVuKHB0aF9wYXRoLCAidyIsIGVuY29kaW5nPSJhc2NpaSIsIG5ld2xpbmU9IiIpIGFzIGZoOgogICAgICAgIGZoLndyaXRlKGNvbnRlbnQpCiAgICBweV9leGUgPSBvcy5wYXRoLmpvaW4oZGVzdF9kaXIsICJweXRob24uZXhlIikKICAgIGlmIG5vdCBvcy5wYXRoLmlzZmlsZShweV9leGUpOgogICAgICAgIHJhaXNlIEZpbGVOb3RGb3VuZEVycm9yKCJweXRob24uZXhlIG1pc3NpbmcgYWZ0ZXIgZXh0cmFjdGlvbiIpCiAgICByZXR1cm4gcHlfZXhlCgoKZGVmIG1haW4oKToKICAgICMgZGVzdF9kaXIgaXMgd2hlcmUgVEhJUyBydW5uaW5nIGludGVycHJldGVyIGxpdmVzOyBXaW5kb3dzIHdvbid0IGxldCBhIHByb2Nlc3MgcmVwbGFjZSBpdHMKICAgICMgb3duIGZpbGVzLCBzbyBhIHN3YXAgZXh0cmFjdHMgaW50byBhIHNpYmxpbmcgX3N3YXAgZGlyIGFuZCBiYXRjaCBtb3ZlcyBpdCBpbnRvIHBsYWNlIG9ubHkKICAgICMgYWZ0ZXIgdGhpcyBwcm9jZXNzIGV4aXRzIChsb2NrcyByZWxlYXNlZCkuIFNlZSBkb2NzL2FnZW50LWludGVyY29ubmVjdC5tZC4KICAgIGRlc3RfZGlyID0gc3lzLmFyZ3ZbMV0gaWYgbGVuKHN5cy5hcmd2KSA+IDEgZWxzZSAiIgogICAgc3dhcF9kaXIgPSBkZXN0X2Rpci5yc3RyaXAoIlxcLyIpICsgIl9zd2FwIgogICAgcHlzcGVjID0gb3MuZW52aXJvbi5nZXQoIlBZU1BFQyIsICIiKQogICAgcmVxdWVzdGVkX21pbm9yID0gcmVzb2x2ZV9yZXF1ZXN0ZWRfbWlub3IocHlzcGVjKQoKICAgIGlmIHJlcXVlc3RlZF9taW5vciBpcyBOb25lIG9yIHJlcXVlc3RlZF9taW5vciA9PSBMQVRFU1RfTUlOT1I6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgidW5jaGFuZ2VkfHt9XG4iLmZvcm1hdChMQVRFU1RfTUlOT1IpKQogICAgICAgIHJldHVybiAwCgogICAgbWlub3IsIHBhdGNoLCBzaGEyNTYsIGZlbGxfYmFjayA9IHJlc29sdmVfdGFibGVfZW50cnkocmVxdWVzdGVkX21pbm9yKQogICAgaWYgbWlub3IgPT0gTEFURVNUX01JTk9SOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoInVuY2hhbmdlZHx7fVxuIi5mb3JtYXQobWlub3IpKQogICAgICAgIHJldHVybiAwCgogICAgdXJsID0gImh0dHBzOi8vd3d3LnB5dGhvbi5vcmcvZnRwL3B5dGhvbi97cH0vcHl0aG9uLXtwfS1lbWJlZC1hbWQ2NC56aXAiLmZvcm1hdChwPXBhdGNoKQogICAgemlwX3BhdGggPSBvcy5wYXRoLmpvaW4ob3MuZW52aXJvbi5nZXQoIlRFTVAiLCAiLiIpLCAicHl0aG9uLXt9LWVtYmVkLWFtZDY0LnppcCIuZm9ybWF0KHBhdGNoKSkKICAgIHRyeToKICAgICAgICBkb3dubG9hZF9hbmRfdmVyaWZ5KHVybCwgc2hhMjU2LCB6aXBfcGF0aCkKICAgICAgICBleHRyYWN0X2FuZF9wYXRjaCh6aXBfcGF0aCwgc3dhcF9kaXIpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzoKICAgICAgICBzeXMuc3RkZXJyLndyaXRlKCJlbWJlZCB2ZXJzaW9uIHN3YXAgZmFpbGVkOiB7fVxuIi5mb3JtYXQoZXhjKSkKICAgICAgICBpZiBvcy5wYXRoLmlzZGlyKHN3YXBfZGlyKToKICAgICAgICAgICAgc2h1dGlsLnJtdHJlZShzd2FwX2RpciwgaWdub3JlX2Vycm9ycz1UcnVlKQogICAgICAgIHJldHVybiAxCgogICAgdGFnID0gImZlbGxiYWNrIiBpZiBmZWxsX2JhY2sgZWxzZSAic3dhcHBlZCIKICAgIHN5cy5zdGRvdXQud3JpdGUoInt9fHt9fHt9XG4iLmZvcm1hdCh0YWcsIG1pbm9yLCBzd2FwX2RpcikpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg=="
rem HP_FAILFAST_PROBE decoded content (Slice 2b-C, output-path args added in the 2b-C checkpoint
rem slice so the elective secondary run never overwrites the primary run's captured files):
rem $exe = $env:HP_PROBE_EXE
rem $rawArgs = $env:HP_PROBE_ARGS
rem $workDir = $env:HP_PROBE_CWD
rem $probeMs = [int]$env:HP_FAILFAST_PROBE_MS
rem $outPath = $env:HP_PROBE_OUT
rem if (-not $outPath) { $outPath = '~run.out.txt' }
rem $errPath = $env:HP_PROBE_ERR
rem if (-not $errPath) { $errPath = '~run.err.txt' }
rem $si = New-Object System.Diagnostics.ProcessStartInfo
rem $si.FileName = $exe
rem if ($rawArgs) { $si.Arguments = '"' + $rawArgs + '"' }
rem $si.WorkingDirectory = $workDir
rem $si.UseShellExecute = $false
rem $si.RedirectStandardOutput = $true
rem $si.RedirectStandardError = $true
rem $p = [System.Diagnostics.Process]::Start($si)
rem $so = $p.StandardOutput.ReadToEndAsync()
rem $se = $p.StandardError.ReadToEndAsync()
rem $fast = $p.WaitForExit($probeMs)
rem $exceeded = 0
rem if (-not $fast) {
rem     $exceeded = 1
rem     $p.WaitForExit()
rem }
rem $so.Result | Set-Content -Path $outPath -Encoding ASCII
rem $se.Result | Set-Content -Path $errPath -Encoding ASCII
rem "$exceeded|$($p.ExitCode)"
rem Never calls $p.Kill() -- once the probe window (HP_FAILFAST_PROBE_MS) is exceeded, the second
rem WaitForExit() is unbounded so a healthy long-running app is never force-stopped. Reads all
rem inputs from env vars set by the caller (no positional args) to avoid any cmd.exe quoting
rem hazard; caller must pre-truncate the output files (default paths baked into this script)
rem before invoking (this script only writes them once, at process exit, so a stale prior run's
rem content would otherwise linger for the full unbounded-wait duration).
rem If HP_FAILFAST_PROBE changes, update this decoded comment block to match the base64 payload.
set "HP_FAILFAST_PROBE=JGV4ZSA9ICRlbnY6SFBfUFJPQkVfRVhFCiRyYXdBcmdzID0gJGVudjpIUF9QUk9CRV9BUkdTCiR3b3JrRGlyID0gJGVudjpIUF9QUk9CRV9DV0QKJHByb2JlTXMgPSBbaW50XSRlbnY6SFBfRkFJTEZBU1RfUFJPQkVfTVMKJG91dFBhdGggPSAkZW52OkhQX1BST0JFX09VVAppZiAoLW5vdCAkb3V0UGF0aCkgeyAkb3V0UGF0aCA9ICd+cnVuLm91dC50eHQnIH0KJGVyclBhdGggPSAkZW52OkhQX1BST0JFX0VSUgppZiAoLW5vdCAkZXJyUGF0aCkgeyAkZXJyUGF0aCA9ICd+cnVuLmVyci50eHQnIH0KJHNpID0gTmV3LU9iamVjdCBTeXN0ZW0uRGlhZ25vc3RpY3MuUHJvY2Vzc1N0YXJ0SW5mbwokc2kuRmlsZU5hbWUgPSAkZXhlCmlmICgkcmF3QXJncykgeyAkc2kuQXJndW1lbnRzID0gJyInICsgJHJhd0FyZ3MgKyAnIicgfQokc2kuV29ya2luZ0RpcmVjdG9yeSA9ICR3b3JrRGlyCiRzaS5Vc2VTaGVsbEV4ZWN1dGUgPSAkZmFsc2UKJHNpLlJlZGlyZWN0U3RhbmRhcmRPdXRwdXQgPSAkdHJ1ZQokc2kuUmVkaXJlY3RTdGFuZGFyZEVycm9yID0gJHRydWUKJHAgPSBbU3lzdGVtLkRpYWdub3N0aWNzLlByb2Nlc3NdOjpTdGFydCgkc2kpCiRzbyA9ICRwLlN0YW5kYXJkT3V0cHV0LlJlYWRUb0VuZEFzeW5jKCkKJHNlID0gJHAuU3RhbmRhcmRFcnJvci5SZWFkVG9FbmRBc3luYygpCiRmYXN0ID0gJHAuV2FpdEZvckV4aXQoJHByb2JlTXMpCiRleGNlZWRlZCA9IDAKaWYgKC1ub3QgJGZhc3QpIHsKICAgICRleGNlZWRlZCA9IDEKICAgICRwLldhaXRGb3JFeGl0KCkKfQokc28uUmVzdWx0IHwgU2V0LUNvbnRlbnQgLVBhdGggJG91dFBhdGggLUVuY29kaW5nIEFTQ0lJCiRzZS5SZXN1bHQgfCBTZXQtQ29udGVudCAtUGF0aCAkZXJyUGF0aCAtRW5jb2RpbmcgQVNDSUkKIiRleGNlZWRlZHwkKCRwLkV4aXRDb2RlKSIK"
:: --- Embedded helper: HP_PREP_REQUIREMENTS (~prep_requirements.py) ---
:: Purpose:
::   - Normalize pip/conda specifiers from requirements.txt
::   - Apply heuristic extras (REQ-005.8)
::
:: Current heuristics applied (set HP_DISABLE_HEURISTICS=1 to skip):
::   REQ-005.8.1 -- pandas  -> openpyxl (+ xlsxwriter)
::   REQ-005.8.2 -- requests -> certifi
::   REQ-005.8.3 -- sqlalchemy -> pymysql
::   REQ-005.8.4 -- matplotlib -> tk
::   REQ-005.8.5 -- cryptography/pycryptodome -> cffi
::
:: Log format: [HEURISTIC] <source->target>  (emitted to stderr -> ~setup.log)
:: Tests: selfapps_pandas_excel.ps1 validates REQ-005.8.1 translation
:: --------------------------------------------------------------------
set "HP_PREP_REQUIREMENTS=T1BfT1JERVIgPSAoIj09IiwgIiE9IiwgIj49IiwgIj4iLCAiPD0iLCAiPCIpCk9QX1JBTksgPSB7b3A6IGlkeCBmb3IgaWR4LCBvcCBpbiBlbnVtZXJhdGUoT1BfT1JERVIpfQoKaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc3lzCmZyb20gY29sbGVjdGlvbnMgaW1wb3J0IE9yZGVyZWREaWN0CgpJTlAgPSBzeXMuYXJndlsxXSBpZiBsZW4oc3lzLmFyZ3YpID4gMSBlbHNlICJyZXF1aXJlbWVudHMudHh0IgpPVVRfQ09OREEgPSAifnJlcXNfY29uZGEudHh0IgpPVVRfUElQID0gIn5yZXFzX3BpcC50eHQiClNQRUNfUEFUVEVSTiA9IHJlLmNvbXBpbGUociIofj18PT18IT18Pj18Pnw8PXw8KVxzKihbXlxzLDtdKylccyokIikKTkFNRV9QQVRURVJOID0gcmUuY29tcGlsZShyIl5ccyooW0EtWmEtejAtOV8uLV0rKVxzKiguKikkIikKCgpkZWYgc3BsaXRfbWFya2VyKHRleHQ6IHN0cikgLT4gc3RyOgogICAgcmV0dXJuIHRleHQuc3BsaXQoIjsiKVswXS5zdHJpcCgpCgoKZGVmIF92ZXJzaW9uX2tleSh0ZXh0OiBzdHIpOgogICAgcGFydHMgPSBbXQogICAgZm9yIGNodW5rIGluIHRleHQuc3BsaXQoJy4nKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIHBhcnRzLmFwcGVuZChpbnQoY2h1bmspKQogICAgICAgIGV4Y2VwdCBWYWx1ZUVycm9yOgogICAgICAgICAgICBwYXJ0cy5hcHBlbmQoMCkKICAgIHJldHVybiB0dXBsZShwYXJ0cykKCgpkZWYgX2J1bXBfY29tcGF0aWJsZSh2YWx1ZTogc3RyKSAtPiBzdHI6CiAgICBwaWVjZXMgPSB2YWx1ZS5zcGxpdCgnLicpCiAgICBpZiBub3QgcGllY2VzIG9yIG5vdCBwaWVjZXNbMF0uaXNkaWdpdCgpOgogICAgICAgIHJldHVybiB2YWx1ZQogICAgbWFqb3IgPSBpbnQocGllY2VzWzBdKQogICAgaWYgbGVuKHBpZWNlcykgPj0gMyBhbmQgcGllY2VzWzFdLmlzZGlnaXQoKToKICAgICAgICByZXR1cm4gZiJ7bWFqb3J9LntpbnQocGllY2VzWzFdKSArIDF9IgogICAgaWYgbGVuKHBpZWNlcykgPj0gMjoKICAgICAgICByZXR1cm4gZiJ7bWFqb3IgKyAxfS4wIgogICAgcmV0dXJuIHN0cihtYWpvciArIDEpCgoKZGVmIF9leHBhbmRfZnJhZ21lbnQoZnJhZ21lbnQ6IHN0cik6CiAgICBpZiBub3QgZnJhZ21lbnQ6CiAgICAgICAgcmV0dXJuIFtdCiAgICB2YWx1ZSA9IGZyYWdtZW50LnN0cmlwKCkKICAgIGlmIG5vdCB2YWx1ZToKICAgICAgICByZXR1cm4gW10KICAgIG1hdGNoID0gU1BFQ19QQVRURVJOLmZ1bGxtYXRjaCh2YWx1ZSkKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByZXR1cm4gW10KICAgIG9wLCB2ZXIgPSBtYXRjaC5ncm91cHMoKQogICAgdmVyID0gdmVyLnN0cmlwKCkKICAgIGlmIG5vdCB2ZXI6CiAgICAgICAgcmV0dXJuIFtdCiAgICBpZiBvcCA9PSAifj0iOgogICAgICAgIHVwcGVyID0gX2J1bXBfY29tcGF0aWJsZSh2ZXIpCiAgICAgICAgcmV0dXJuIFtmIj49e3Zlcn0iLCBmIjx7dXBwZXJ9Il0KICAgIHJldHVybiBbZiJ7b3B9e3Zlcn0iXQoKCmRlZiBjYW5vbmljYWxfb3BzKHNwZWNzKSAtPiBsaXN0OgogICAgYnVja2V0ID0gT3JkZXJlZERpY3QoKQogICAgZm9yIHJhdyBpbiBzcGVjczoKICAgICAgICBmb3Igbm9ybWFsaXplZCBpbiBfZXhwYW5kX2ZyYWdtZW50KHJhdyk6CiAgICAgICAgICAgIGJ1Y2tldFtub3JtYWxpemVkXSA9IE5vbmUKICAgIG9yZGVyZWQgPSBsaXN0KGJ1Y2tldC5rZXlzKCkpCiAgICBvcmRlcmVkLnNvcnQoa2V5PV9zcGVjX3NvcnRfa2V5KQogICAgcmV0dXJuIF9lbmZvcmNlX2JvdW5kc19vcmRlcihvcmRlcmVkKQoKCmRlZiBfc3BlY19zb3J0X2tleSh2YWx1ZTogc3RyKToKICAgIGZvciBvcCBpbiBPUF9PUkRFUjoKICAgICAgICBpZiB2YWx1ZS5zdGFydHN3aXRoKG9wKToKICAgICAgICAgICAgdmVyID0gdmFsdWVbbGVuKG9wKTpdCiAgICAgICAgICAgIHJldHVybiBPUF9SQU5LW29wXSwgX3ZlcnNpb25fa2V5KHZlciksIHZlcgogICAgcmV0dXJuIGxlbihPUF9PUkRFUiksIF92ZXJzaW9uX2tleSh2YWx1ZSksIHZhbHVlCgoKZGVmIF9lbmZvcmNlX2JvdW5kc19vcmRlcihpdGVtczogbGlzdCkgLT4gbGlzdDoKICAgIG9wcyA9IGxpc3QoaXRlbXMpCiAgICBsb3dlcl9pbmRleCA9IG5leHQoKGlkeCBmb3IgaWR4LCB0ZXh0IGluIGVudW1lcmF0ZShvcHMpIGlmIHRleHQuc3RhcnRzd2l0aCgiPj0iKSksIE5vbmUpCiAgICBpZiBsb3dlcl9pbmRleCBpcyBOb25lOgogICAgICAgIHJldHVybiBvcHMKICAgIGZvciB1cHBlcl9vcCBpbiAoIjw9IiwgIjwiKToKICAgICAgICB1cHBlcl9pbmRleCA9IG5leHQoKGlkeCBmb3IgaWR4LCB0ZXh0IGluIGVudW1lcmF0ZShvcHMpIGlmIHRleHQuc3RhcnRzd2l0aCh1cHBlcl9vcCkpLCBOb25lKQogICAgICAgIGlmIHVwcGVyX2luZGV4IGlzIG5vdCBOb25lIGFuZCB1cHBlcl9pbmRleCA8IGxvd2VyX2luZGV4OgogICAgICAgICAgICB2YWx1ZSA9IG9wcy5wb3AobG93ZXJfaW5kZXgpCiAgICAgICAgICAgIG9wcy5pbnNlcnQodXBwZXJfaW5kZXgsIHZhbHVlKQogICAgICAgICAgICBsb3dlcl9pbmRleCA9IHVwcGVyX2luZGV4CiAgICByZXR1cm4gb3BzCgoKZGVmIGZvcm1hdF9saW5lKG5hbWU6IHN0ciwgc3BlY3MpIC0+IGxpc3Q6CiAgICBvcHMgPSBjYW5vbmljYWxfb3BzKHNwZWNzKQogICAgcmV0dXJuIFtmIntuYW1lfSAiICsgIiwiLmpvaW4ob3BzKV0gaWYgb3BzIGVsc2UgW25hbWVdCgoKZGVmIG5vcm1hbGl6ZV9zcGVjaWZpZXJzKHJlc3Q6IHN0cik6CiAgICBpdGVtcyA9IFtdCiAgICBmb3IgY2h1bmsgaW4gcmVzdC5zcGxpdCgnLCcpOgogICAgICAgIGNodW5rID0gY2h1bmsuc3RyaXAoKQogICAgICAgIGlmIGNodW5rOgogICAgICAgICAgICBpdGVtcy5leHRlbmQoX2V4cGFuZF9mcmFnbWVudChjaHVuaykpCiAgICByZXR1cm4gY2Fub25pY2FsX29wcyhpdGVtcykKCgpkZWYgdG9fY29uZGEobGluZTogc3RyKToKICAgIHNlY3Rpb24gPSBzcGxpdF9tYXJrZXIobGluZSkKICAgIGlmIG5vdCBzZWN0aW9uIG9yIHNlY3Rpb24uc3RhcnRzd2l0aCgnIycpOgogICAgICAgIHJldHVybiBbXQogICAgbWF0Y2ggPSBOQU1FX1BBVFRFUk4ubWF0Y2goc2VjdGlvbikKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByZXR1cm4gW10KICAgIG5hbWUsIHJlc3QgPSBtYXRjaC5ncm91cHMoKQogICAgcmVzdCA9IHJlLnN1YihyIlxbLio/XF0iLCAiIiwgcmVzdCkKICAgIHNwZWNzID0gW2NodW5rLnN0cmlwKCkgZm9yIGNodW5rIGluIHJlc3Quc3BsaXQoJywnKSBpZiBjaHVuay5zdHJpcCgpXQogICAgcmV0dXJuIGZvcm1hdF9saW5lKG5hbWUsIHNwZWNzKQoKCmRlZiB0b19waXAobGluZTogc3RyKToKICAgIHNlY3Rpb24gPSBzcGxpdF9tYXJrZXIobGluZSkKICAgIGlmIG5vdCBzZWN0aW9uIG9yIHNlY3Rpb24uc3RhcnRzd2l0aCgnIycpOgogICAgICAgIHJldHVybiBOb25lCiAgICBtYXRjaCA9IE5BTUVfUEFUVEVSTi5tYXRjaChzZWN0aW9uKQogICAgaWYgbm90IG1hdGNoOgogICAgICAgIHJldHVybiBzZWN0aW9uLnN0cmlwKCkKICAgIG5hbWUsIHJlc3QgPSBtYXRjaC5ncm91cHMoKQogICAgcmV0dXJuIChuYW1lICsgcmVzdCkuc3RyaXAoKQoKCmRlZiBtYWluKCk6CiAgICBoYXZlX2ZpbGUgPSBvcy5wYXRoLmV4aXN0cyhJTlApIGFuZCBvcy5wYXRoLmdldHNpemUoSU5QKSA+IDAKICAgIGxpbmVzID0gW10KICAgIGlmIGhhdmVfZmlsZToKICAgICAgICB3aXRoIG9wZW4oSU5QLCAncicsIGVuY29kaW5nPSd1dGYtOCcsIGVycm9ycz0naWdub3JlJykgYXMgaGFuZGxlOgogICAgICAgICAgICBsaW5lcyA9IFtpdGVtLnN0cmlwKCkgZm9yIGl0ZW0gaW4gaGFuZGxlIGlmIGl0ZW0uc3RyaXAoKV0KICAgIGNvbmRhX3NwZWNzID0gW10KICAgIHBpcF9zcGVjcyA9IFtdCiAgICBmb3IgbGluZSBpbiBsaW5lczoKICAgICAgICBjb25kYV9zcGVjcy5leHRlbmQodG9fY29uZGEobGluZSkpCiAgICAgICAgcGlwX2VudHJ5ID0gdG9fcGlwKGxpbmUpCiAgICAgICAgaWYgcGlwX2VudHJ5OgogICAgICAgICAgICBwaXBfc3BlY3MuYXBwZW5kKHBpcF9lbnRyeSkKICAgIG5hbWVzX2xvd2VyID0gW3JlLnNwbGl0KHIiWzw+PSF+LFxzXFtdIiwgdmFsdWUsIG1heHNwbGl0PTEpWzBdLnN0cmlwKCkubG93ZXIoKSBmb3IgdmFsdWUgaW4gcGlwX3NwZWNzXQogICAgaWYgb3MuZW52aXJvbi5nZXQoJ0hQX0RJU0FCTEVfSEVVUklTVElDUycpICE9ICcxJzoKICAgICAgICBpZiAncGFuZGFzJyBpbiBuYW1lc19sb3dlciBhbmQgJ29wZW5weXhsJyBub3QgaW4gbmFtZXNfbG93ZXI6CiAgICAgICAgICAgIHBpcF9zcGVjcy5hcHBlbmQoJ29wZW5weXhsJykKICAgICAgICAgICAgY29uZGFfc3BlY3MuZXh0ZW5kKGZvcm1hdF9saW5lKCdvcGVucHl4bCcsIFtdKSkKICAgICAgICAgICAgc3lzLnN0ZGVyci53cml0ZSgnW0hFVVJJU1RJQ10gcGFuZGFzLT5vcGVucHl4bFxuJykKICAgICAgICBpZiAncGFuZGFzJyBpbiBuYW1lc19sb3dlciBhbmQgJ3hsc3h3cml0ZXInIG5vdCBpbiBuYW1lc19sb3dlcjoKICAgICAgICAgICAgcGlwX3NwZWNzLmFwcGVuZCgneGxzeHdyaXRlcicpCiAgICAgICAgICAgIGNvbmRhX3NwZWNzLmV4dGVuZChmb3JtYXRfbGluZSgneGxzeHdyaXRlcicsIFtdKSkKICAgICAgICAgICAgc3lzLnN0ZGVyci53cml0ZSgnW0hFVVJJU1RJQ10gcGFuZGFzLT54bHN4d3JpdGVyXG4nKQogICAgICAgIGlmICdyZXF1ZXN0cycgaW4gbmFtZXNfbG93ZXIgYW5kICdjZXJ0aWZpJyBub3QgaW4gbmFtZXNfbG93ZXI6CiAgICAgICAgICAgIHBpcF9zcGVjcy5hcHBlbmQoJ2NlcnRpZmknKQogICAgICAgICAgICBjb25kYV9zcGVjcy5leHRlbmQoZm9ybWF0X2xpbmUoJ2NlcnRpZmknLCBbXSkpCiAgICAgICAgICAgIHN5cy5zdGRlcnIud3JpdGUoJ1tIRVVSSVNUSUNdIHJlcXVlc3RzLT5jZXJ0aWZpXG4nKQogICAgICAgIGlmICdzcWxhbGNoZW15JyBpbiBuYW1lc19sb3dlciBhbmQgJ3B5bXlzcWwnIG5vdCBpbiBuYW1lc19sb3dlcjoKICAgICAgICAgICAgcGlwX3NwZWNzLmFwcGVuZCgncHlteXNxbCcpCiAgICAgICAgICAgIGNvbmRhX3NwZWNzLmV4dGVuZChmb3JtYXRfbGluZSgncHlteXNxbCcsIFtdKSkKICAgICAgICAgICAgc3lzLnN0ZGVyci53cml0ZSgnW0hFVVJJU1RJQ10gc3FsYWxjaGVteS0+cHlteXNxbFxuJykKICAgICAgICBpZiAnbWF0cGxvdGxpYicgaW4gbmFtZXNfbG93ZXIgYW5kICd0aycgbm90IGluIG5hbWVzX2xvd2VyOgogICAgICAgICAgICBwaXBfc3BlY3MuYXBwZW5kKCd0aycpCiAgICAgICAgICAgIGNvbmRhX3NwZWNzLmV4dGVuZChmb3JtYXRfbGluZSgndGsnLCBbXSkpCiAgICAgICAgICAgIHN5cy5zdGRlcnIud3JpdGUoJ1tIRVVSSVNUSUNdIG1hdHBsb3RsaWItPnRrXG4nKQogICAgICAgIGlmICgnY3J5cHRvZ3JhcGh5JyBpbiBuYW1lc19sb3dlciBvciAncHljcnlwdG9kb21lJyBpbiBuYW1lc19sb3dlcikgYW5kICdjZmZpJyBub3QgaW4gbmFtZXNfbG93ZXI6CiAgICAgICAgICAgIHBpcF9zcGVjcy5hcHBlbmQoJ2NmZmknKQogICAgICAgICAgICBjb25kYV9zcGVjcy5leHRlbmQoZm9ybWF0X2xpbmUoJ2NmZmknLCBbXSkpCiAgICAgICAgICAgIHN5cy5zdGRlcnIud3JpdGUoJ1tIRVVSSVNUSUNdIGNyeXB0by0+Y2ZmaVxuJykKICAgIHdpdGggb3BlbihPVVRfQ09OREEsICd3JywgZW5jb2Rpbmc9J2FzY2lpJykgYXMgaGFuZGxlOgogICAgICAgIGZvciBpdGVtIGluIGNvbmRhX3NwZWNzOgogICAgICAgICAgICBpZiBpdGVtOgogICAgICAgICAgICAgICAgaGFuZGxlLndyaXRlKGl0ZW0gKyAnXG4nKQogICAgd2l0aCBvcGVuKE9VVF9QSVAsICd3JywgZW5jb2Rpbmc9J2FzY2lpJykgYXMgaGFuZGxlOgogICAgICAgIGZvciBpdGVtIGluIHBpcF9zcGVjczoKICAgICAgICAgICAgaWYgaXRlbToKICAgICAgICAgICAgICAgIGhhbmRsZS53cml0ZShpdGVtICsgJ1xuJykKICAgIHN5cy5zdGRvdXQud3JpdGUoJ09LXG4nKQoKCmlmIF9fbmFtZV9fID09ICdfX21haW5fXyc6CiAgICBtYWluKCkK"
set "HP_DETECT_VISA=aW1wb3J0IG9zLCByZSwgc3lzCgpST09UID0gb3MuZ2V0Y3dkKCkKUEFUVEVSTlMgPSBbCiAgICByIig/bSleXHMqKD86ZnJvbVxzK3B5dmlzfGltcG9ydFxzK3B5dmlzKSIsCiAgICByIig/bSleXHMqaW1wb3J0XHMrdmlzIiwKXQoKZGVmIG5lZWRzX3Zpc2EoKToKICAgIGZvciBjdXJyZW50LCBkaXJzLCBmaWxlcyBpbiBvcy53YWxrKFJPT1QpOgogICAgICAgIGRpcnNbOl0gPSBbaXRlbSBmb3IgaXRlbSBpbiBkaXJzIGlmIG5vdCBpdGVtLnN0YXJ0c3dpdGgoKCd+JywgJy4nKSldCiAgICAgICAgZm9yIG5hbWUgaW4gZmlsZXM6CiAgICAgICAgICAgIGlmIG5vdCBuYW1lLmVuZHN3aXRoKCcucHknKSBvciBuYW1lLnN0YXJ0c3dpdGgoJ34nKToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIHBhdGggPSBvcy5wYXRoLmpvaW4oY3VycmVudCwgbmFtZSkKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgd2l0aCBvcGVuKHBhdGgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgICAgICAgICAgdGV4dCA9IGhhbmRsZS5yZWFkKCkKICAgICAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBmb3IgcGF0dGVybiBpbiBQQVRURVJOUzoKICAgICAgICAgICAgICAgIGlmIHJlLnNlYXJjaChwYXR0ZXJuLCB0ZXh0KToKICAgICAgICAgICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgcmV0dXJuIEZhbHNlCgpkZWYgbWFpbigpOgogICAgc3lzLnN0ZG91dC53cml0ZSgnMScgaWYgbmVlZHNfdmlzYSgpIGVsc2UgJzAnKQoKaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJzoKICAgIG1haW4oKQo="
rem ~find_entry.py emits a normalized crumb, logs it for tests, and skip mode reads its stdout
set "HP_FIND_ENTRY=IiIiZmluZF9lbnRyeSAoUkVRLTAwMikgLS0gZGV0ZXJtaW5pc3RpYyBlbnRyeS1wb2ludCBzZWxlY3Rvci4KClJ1biBmcm9tIHRoZSBhcHBsaWNhdGlvbiBkaXJlY3Rvcnk7IHByaW50cyB0aGUgY2hvc2VuIGVudHJ5IHNjcmlwdCAob25lIGxpbmUpIHRvCnN0ZG91dCBhbmQgZGlhZ25vc3RpYyBbQk9PVF0gbGluZXMgdG8gc3RkZXJyLiBTZWxlY3Rpb24gb3JkZXI6CgogIDEuIFBSRUZFUlJFRCBuYW1lIG1hdGNoIChtYWluLnB5ID4gYXBwLnB5ID4gcnVuLnB5ID4gY2xpLnB5KS4KICAyLiBUaGUgc29sZSAucHkgZmlsZSwgd2hlbiB0aGVyZSBpcyBleGFjdGx5IG9uZS4KICAzLiBUaGUgc29sZSBmaWxlIGNvbnRhaW5pbmcgYSBzdWJzdGFudGl2ZSBgaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjpgIGd1YXJkLgogIDQuIERldGVybWluaXN0aWMgYWxwaGFiZXRpY2FsIGZhbGxiYWNrIC0tIHByZWZlciBmaWxlcyB0aGF0IGRlY2xhcmVkIGEgX19tYWluX18KICAgICBndWFyZCwgZWxzZSBhbnkgLnB5IGZpbGUgLS0gc28gc29tZXRoaW5nIGFsd2F5cyBydW5zL2J1aWxkcyByYXRoZXIgdGhhbiB0aGUKICAgICBlbnRyeSByZXNvbHZpbmcgdG8gZW1wdHkgKHdoaWNoIHNpbGVudGx5IHNraXBzIHJ1biArIHBhY2thZ2luZykuCgpUaGlzIGlzIHRoZSBjYW5vbmljYWwgc291cmNlIGZvciB0aGUgSFBfRklORF9FTlRSWSBiYXNlNjQgcGF5bG9hZCBlbWJlZGRlZCBpbgpydW5fc2V0dXAuYmF0LiBBZnRlciBlZGl0aW5nLCByZS1lbmNvZGUgYW5kIHBhc3RlIGl0IGludG8gdGhlIGBzZXQgIkhQX0ZJTkRfRU5UUlk9Li4uImAKbGluZTsgdGVzdHMvdGVzdF9maW5kX2VudHJ5LnB5IGFzc2VydHMgdGhlIGVtYmVkZGVkIHBheWxvYWQgbWF0Y2hlcyB0aGlzIGZpbGUuCiIiIgppbXBvcnQgYXN0CmltcG9ydCBvcwppbXBvcnQgc3lzCgpQUkVGRVJSRUQgPSAoIm1haW4ucHkiLCAiYXBwLnB5IiwgInJ1bi5weSIsICJjbGkucHkiKQoKCmRlZiBpc19weShuYW1lKToKICAgIGxvd2VyID0gbmFtZS5sb3dlcigpCiAgICAjICIuXyItcHJlZml4OiBtYWNPUyBBcHBsZURvdWJsZSBtZXRhZGF0YSBmaWxlcyAoZS5nLiAiLl9tYWluLnB5IiksIGEgY29tbW9uCiAgICAjIGNyb3NzLXBsYXRmb3JtIHBhcGVyY3V0IHdoZW4gYSBXaW5kb3dzIHVzZXIgdW56aXBzIHNvbWV0aGluZyBhIE1hYyB1c2VyIHppcHBlZC4KICAgIHJldHVybiAoCiAgICAgICAgbG93ZXIuZW5kc3dpdGgoIi5weSIpCiAgICAgICAgYW5kIG5vdCBsb3dlci5zdGFydHN3aXRoKCJ+IikKICAgICAgICBhbmQgbm90IGxvd2VyLnN0YXJ0c3dpdGgoIi5fIikKICAgICAgICBhbmQgb3MucGF0aC5pc2ZpbGUobmFtZSkKICAgICkKCgpkZWYgX2lzX21haW5fZ3VhcmQodGVzdCk6CiAgICAiIiJUcnVlIGlmIGFuIElmIHRlc3QgaXMgYF9fbmFtZV9fID09ICJfX21haW5fXyJgIChlaXRoZXIgb3BlcmFuZCBvcmRlcikuIiIiCiAgICBpZiBub3QgaXNpbnN0YW5jZSh0ZXN0LCBhc3QuQ29tcGFyZSkgb3IgbGVuKHRlc3Qub3BzKSAhPSAxOgogICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgbm90IGlzaW5zdGFuY2UodGVzdC5vcHNbMF0sIGFzdC5FcSk6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBuYW1lcyA9IHNldCgpCiAgICBjb25zdHMgPSBzZXQoKQogICAgZm9yIHNpZGUgaW4gKHRlc3QubGVmdCwgdGVzdC5jb21wYXJhdG9yc1swXSk6CiAgICAgICAgaWYgaXNpbnN0YW5jZShzaWRlLCBhc3QuTmFtZSk6CiAgICAgICAgICAgIG5hbWVzLmFkZChzaWRlLmlkKQogICAgICAgIGVsaWYgaXNpbnN0YW5jZShzaWRlLCBhc3QuQ29uc3RhbnQpOgogICAgICAgICAgICBjb25zdHMuYWRkKHNpZGUudmFsdWUpCiAgICByZXR1cm4gIl9fbmFtZV9fIiBpbiBuYW1lcyBhbmQgIl9fbWFpbl9fIiBpbiBjb25zdHMKCgpkZWYgX2lzX3N1YnN0YW50aXZlKHN0bXQpOgogICAgIiIiQSBzdGF0ZW1lbnQgdGhhdCBkb2VzIHJlYWwgd29yayAobm90IHBhc3MgLyBkb2NzdHJpbmcgLyBiYXJlIC4uLikuIiIiCiAgICBpZiBpc2luc3RhbmNlKHN0bXQsIGFzdC5QYXNzKToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGlmIGlzaW5zdGFuY2Uoc3RtdCwgYXN0LkV4cHIpIGFuZCBpc2luc3RhbmNlKHN0bXQudmFsdWUsIGFzdC5Db25zdGFudCk6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICByZXR1cm4gVHJ1ZQoKCmRlZiBoYXNfbWFpbihwYXRoKToKICAgICIiIlRydWUgaWYgdGhlIGZpbGUgaGFzIGFuIGBpZiBfX25hbWVfXyA9PSAiX19tYWluX18iOmAgZ3VhcmQgdGhhdCBkb2VzIHJlYWwgd29yay4KCiAgICBBIGd1YXJkIHdob3NlIGJvZHkgaXMgZXhjbHVzaXZlbHkgcGFzcy9jb21tZW50cy9kb2NzdHJpbmcvYC4uLmAgZG9lcyBub3QgY291bnQKICAgIChpdCBzZWxmLWlkZW50aWZpZXMgdGhlIG1vZHVsZSBhcyBub24tcnVubmFibGUpLCBzbyBhIHNpYmxpbmcgcmVhbCBlbnRyeSB3aW5zLgogICAgIiIiCiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKHBhdGgsICJyIiwgZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJpZ25vcmUiKSBhcyBoYW5kbGU6CiAgICAgICAgICAgIHNyYyA9IGhhbmRsZS5yZWFkKCkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICB0cnk6CiAgICAgICAgdHJlZSA9IGFzdC5wYXJzZShzcmMpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICMgVW5wYXJzZWFibGUgc291cmNlIGlzIGEgcG9vciBlbnRyeSBjYW5kaWRhdGU7IGRvIG5vdCByZXN1cnJlY3QgdGhlIG9sZAogICAgICAgICMgc3Vic3RyaW5nIGhldXJpc3RpYyAod2hpY2ggbWlzLWZpcmVkIG9uICJfX21haW5fXyIgaW4gc3RyaW5ncy9jb21tZW50cykuCiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAjIE9ubHkgYSBtb2R1bGUtbGV2ZWwgZ3VhcmQgbWFya3MgYSBydW5uYWJsZSBzY3JpcHQ7IGEgZ3VhcmQgbmVzdGVkIGluc2lkZSBhCiAgICAjIGZ1bmN0aW9uIG9yIGNsYXNzIChlLmcuIGEgaGVscGVyJ3MgYGRlZiBydW4oKTogLi4uIGlmIF9fbmFtZV9fID09IC4uLmApIGlzIG5vdC4KICAgIGZvciBub2RlIGluIHRyZWUuYm9keToKICAgICAgICBpZiBpc2luc3RhbmNlKG5vZGUsIGFzdC5JZikgYW5kIF9pc19tYWluX2d1YXJkKG5vZGUudGVzdCk6CiAgICAgICAgICAgIGlmIGFueShfaXNfc3Vic3RhbnRpdmUoc3RtdCkgZm9yIHN0bXQgaW4gbm9kZS5ib2R5KToKICAgICAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICByZXR1cm4gRmFsc2UKCgpkZWYgZW1pdChwYXRoKToKICAgIHByaW50KG9zLnBhdGgubm9ybXBhdGgocGF0aCkpCgoKIyBFeGl0IGNvZGVzOiAwID0gYSBjbGVhciwgdW5hbWJpZ3VvdXMgcGljayB3YXMgZW1pdHRlZDsgQU1CSUdVT1VTX1JDICgzKSA9IHRoZQojIGFscGhhYmV0aWNhbCBmYWxsYmFjayB3YXMgdXNlZCAobXVsdGlwbGUgZmlsZXMsIG5vIGNsZWFyIHdpbm5lcikgLS0gcnVuX3NldHVwLmJhdAojIHJlYWRzIHRoaXMgdG8gZGVjaWRlIHdoZXRoZXIgdG8gb2ZmZXIgdGhlIGludGVyYWN0aXZlIHBpY2tlci4gc3Rkb3V0IGFsd2F5cyBob2xkcwojIHRoZSBjaG9zZW4gZW50cnkgcmVnYXJkbGVzcywgc28gbm9uLWludGVyYWN0aXZlIGNhbGxlcnMgYXJlIHVuYWZmZWN0ZWQgYnkgdGhlIGNvZGUuCkFNQklHVU9VU19SQyA9IDMKCgpkZWYgbWFpbigpOgogICAgZmlsZXMgPSBbbmFtZSBmb3IgbmFtZSBpbiBvcy5saXN0ZGlyKCIuIikgaWYgaXNfcHkobmFtZSldCgogICAgaWYgbGVuKGZpbGVzKSA+IDE6CiAgICAgICAgc3lzLnN0ZGVyci53cml0ZSgiW0JPT1RdIFJFUS0wMDI6IE11bHRpcGxlIHNjcmlwdHMgZm91bmQ6ICVyXG4iICUgc29ydGVkKGZpbGVzKSkKCiAgICBmb3IgY2FuZGlkYXRlIGluIFBSRUZFUlJFRDoKICAgICAgICBpZiBjYW5kaWRhdGUgaW4gZmlsZXM6CiAgICAgICAgICAgIGlmIGxlbihmaWxlcykgPiAxOgogICAgICAgICAgICAgICAgc3lzLnN0ZGVyci53cml0ZSgKICAgICAgICAgICAgICAgICAgICAiW0JPT1RdIFJFUS0wMDI6IFByaW9yaXR5IExvZ2ljIFRyaWdnZXJlZDogRm91bmQgJXIuICIKICAgICAgICAgICAgICAgICAgICAiU2VsZWN0aW5nICVyIChSRVEtMDAyOiBQcmlvcml0eSBuYW1lIG1hdGNoKS5cbiIKICAgICAgICAgICAgICAgICAgICAlIChzb3J0ZWQoZmlsZXMpLCBjYW5kaWRhdGUpCiAgICAgICAgICAgICAgICApCiAgICAgICAgICAgIGVtaXQoY2FuZGlkYXRlKQogICAgICAgICAgICByZXR1cm4gMAoKICAgIGlmIGxlbihmaWxlcykgPT0gMToKICAgICAgICBlbWl0KGZpbGVzWzBdKQogICAgICAgIHJldHVybiAwCgogICAgY2FuZGlkYXRlcyA9IFtuYW1lIGZvciBuYW1lIGluIGZpbGVzIGlmIGhhc19tYWluKG5hbWUpXQogICAgaWYgbGVuKGNhbmRpZGF0ZXMpID09IDE6CiAgICAgICAgZW1pdChjYW5kaWRhdGVzWzBdKQogICAgICAgIHJldHVybiAwCgogICAgIyBEZXRlcm1pbmlzdGljIGZhbGxiYWNrIChSRVEtMDAyKTogbm8gUFJFRkVSUkVEIG5hbWUgYW5kIG5vdCBleGFjdGx5IG9uZQogICAgIyBzdWJzdGFudGl2ZSBfX21haW5fXyBndWFyZC4gUHJlZmVyIGZpbGVzIHRoYXQgZGVjbGFyZWQgYSBndWFyZCwgZWxzZSBhbnkgZmlsZS4KICAgICMgVGhpcyBhbWJpZ3VvdXMgcGF0aCBleGl0cyBBTUJJR1VPVVNfUkMgc28gdGhlIGJhdGNoIG1heSBvZmZlciB0aGUgaW50ZXJhY3RpdmUKICAgICMgcGlja2VyIGJlZm9yZSBhY2NlcHRpbmcgdGhpcyBhbHBoYWJldGljYWwgZGVmYXVsdC4KICAgIHBvb2wgPSBjYW5kaWRhdGVzIGlmIGNhbmRpZGF0ZXMgZWxzZSBmaWxlcwogICAgaWYgcG9vbDoKICAgICAgICBjaG9pY2UgPSBzb3J0ZWQocG9vbClbMF0KICAgICAgICBzeXMuc3RkZXJyLndyaXRlKAogICAgICAgICAgICAiW0JPT1RdIFJFUS0wMDI6IE5vIGNsZWFyIGVudHJ5IGZvdW5kOyBzZWxlY3RpbmcgJXIgKGFscGhhYmV0aWNhbCBmYWxsYmFjaykuXG4iCiAgICAgICAgICAgICUgY2hvaWNlCiAgICAgICAgKQogICAgICAgIGVtaXQoY2hvaWNlKQogICAgICAgIHJldHVybiBBTUJJR1VPVVNfUkMKCiAgICAjIE5vIC5weSBmaWxlcyBhdCBhbGwgLS0gdGhlIGJvb3RzdHJhcHBlciBoYW5kbGVzIG5vLXB5dGhvbi1maWxlcyBzZXBhcmF0ZWx5LgogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo="
rem ~env_state.py records envMode/envName/envPath/lockSize after a successful
rem conda bootstrap; prints 'skip' on --check when the env is still valid,
rem 'run' otherwise. Writes ~env.state.json on --write.
set "HP_ENV_STATE=IiIiZW52X3N0YXRlIHYzICgyMDI2LTAzLTI3KQpXcml0ZXMgYW5kIHZhbGlkYXRlcyB+ZW52LnN0YXRlLmpzb24gZm9yIHRoZSBydW5fc2V0dXAuYmF0IGJvb3RzdHJhcCBmYXN0IHBhdGguClVzYWdlOgogIHB5dGhvbiB+ZW52X3N0YXRlLnB5IC0tY2hlY2sgIDogcHJpbnQgJ3NraXAnIGlmIHRoZSBzYXZlZCBlbnYgc3RhdGUgaXMgc3RpbGwgdmFsaWQKICBweXRob24gfmVudl9zdGF0ZS5weSAtLXdyaXRlICA6IHdyaXRlIGN1cnJlbnQgZW52IHN0YXRlIHRvIH5lbnYuc3RhdGUuanNvbgpOb3RlOiBweVNwZWMgaXMgaW50ZW50aW9uYWxseSBvbWl0dGVkIGZyb20gdGhlIHN0YXRlIGNoZWNrIGJlY2F1c2UgcnVuX3NldHVwLmJhdAp3cml0ZXMgcnVudGltZS50eHQgKmR1cmluZyogdGhlIGZpcnN0IGJvb3RzdHJhcCwgc28gdGhlIGRldGVjdGVkIHNwZWMgb24gcnVuIDIKZGlmZmVycyBmcm9tIHRoZSBlbXB0eSBzcGVjIG9uIHJ1biAxLCBjYXVzaW5nIGEgc3B1cmlvdXMgY2FjaGUgbWlzcy4KIiIiCl9fdmVyc2lvbl9fID0gImVudl9zdGF0ZSB2MyAoMjAyNi0wMy0yNykiCl9fYWxsX18gPSBbInJlYWRfc3RhdGUiLCAid3JpdGVfc3RhdGUiLCAiY2hlY2tfc3RhdGUiXQoKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzeXMKClNUQVRFX0ZJTEUgPSAifmVudi5zdGF0ZS5qc29uIgpMT0NLX0ZJTEUgPSAifmVudmlyb25tZW50LmxvY2sudHh0IgoKCmRlZiBfbG9ja19zaXplKCk6CiAgICB0cnk6CiAgICAgICAgcmV0dXJuIG9zLnBhdGguZ2V0c2l6ZShMT0NLX0ZJTEUpCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICByZXR1cm4gMAoKCmRlZiByZWFkX3N0YXRlKCk6CiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKFNUQVRFX0ZJTEUsICJyIiwgZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJpZ25vcmUiKSBhcyBmaDoKICAgICAgICAgICAgcmV0dXJuIGpzb24ubG9hZChmaCkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJuIHt9CgoKZGVmIHdyaXRlX3N0YXRlKCk6CiAgICBlbnZfbW9kZSA9IG9zLmVudmlyb24uZ2V0KCJIUF9FTlZfTU9ERSIsICIiKQogICAgZW52X25hbWUgPSBvcy5lbnZpcm9uLmdldCgiRU5WTkFNRSIsICIiKQogICAgZW52X3BhdGggPSBvcy5lbnZpcm9uLmdldCgiRU5WX1BBVEgiLCAiIikKICAgIGxvY2tfc2l6ZSA9IF9sb2NrX3NpemUoKQogICAgc3RhdGUgPSB7CiAgICAgICAgImVudk1vZGUiOiBlbnZfbW9kZSwKICAgICAgICAiZW52TmFtZSI6IGVudl9uYW1lLAogICAgICAgICJlbnZQYXRoIjogZW52X3BhdGgsCiAgICAgICAgImxvY2tTaXplIjogbG9ja19zaXplLAogICAgfQogICAgdHJ5OgogICAgICAgIHdpdGggb3BlbihTVEFURV9GSUxFLCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpIGFzIGZoOgogICAgICAgICAgICBqc29uLmR1bXAoc3RhdGUsIGZoKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgc3lzLmV4aXQoMSkKCgpkZWYgY2hlY2tfc3RhdGUoKToKICAgIHN0YXRlID0gcmVhZF9zdGF0ZSgpCiAgICBpZiBub3Qgc3RhdGU6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgICAgIHJldHVybgogICAgZW52X25hbWUgPSBvcy5lbnZpcm9uLmdldCgiRU5WTkFNRSIsICIiKQogICAgaWYgbm90IGVudl9uYW1lIG9yIHN0YXRlLmdldCgiZW52TmFtZSIpICE9IGVudl9uYW1lOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoInJ1blxuIikKICAgICAgICByZXR1cm4KICAgIGlmIHN0YXRlLmdldCgiZW52TW9kZSIpICE9ICJjb25kYSI6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgICAgIHJldHVybgogICAgZW52X3BhdGggPSBzdGF0ZS5nZXQoImVudlBhdGgiLCAiIikKICAgIGlmIG5vdCBlbnZfcGF0aDoKICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJydW5cbiIpCiAgICAgICAgcmV0dXJuCiAgICBweV9leGUgPSBvcy5wYXRoLmpvaW4oZW52X3BhdGgsICJweXRob24uZXhlIikKICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyhweV9leGUpOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoInJ1blxuIikKICAgICAgICByZXR1cm4KICAgIGxvY2tfc2l6ZSA9IF9sb2NrX3NpemUoKQogICAgaWYgbG9ja19zaXplID09IDAgb3IgbG9ja19zaXplICE9IHN0YXRlLmdldCgibG9ja1NpemUiLCAtMSk6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgICAgIHJldHVybgogICAgc3lzLnN0ZG91dC53cml0ZSgic2tpcFxuIikKCgpkZWYgbWFpbigpOgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgIi0td3JpdGUiIGluIGFyZ3M6CiAgICAgICAgd3JpdGVfc3RhdGUoKQogICAgZWxpZiAiLS1jaGVjayIgaW4gYXJnczoKICAgICAgICBjaGVja19zdGF0ZSgpCiAgICBlbHNlOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoInJ1blxuIikKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg=="
rem ~parse_warn.py reads PyInstaller warn file, extracts missing module names,
rem applies import-to-conda-package translations, and prints one package per line.
set "HP_PARSE_WARN=IiIicGFyc2Vfd2FybiB2MyAoMjAyNi0wNS0wMykKUmVhZHMgUHlJbnN0YWxsZXIgd2FybiBmaWxlLCBleHRyYWN0cyBtaXNzaW5nIG1vZHVsZSBuYW1lcywgYXBwbGllcyB0cmFuc2xhdGlvbnMuClVzYWdlOiBweXRob24gfnBhcnNlX3dhcm4ucHkgPGVudm5hbWU+ClByaW50cyBvbmUgY29uZGEgcGFja2FnZSBuYW1lIHBlciBsaW5lIHRvIHN0ZG91dC4KU2tpcHMgaW50ZXJuYWwgbW9kdWxlcyAoc3RhcnRpbmcgd2l0aCBfKSBhbmQga25vd24tc2FmZS91bml4LW9ubHkgbmFtZXMuClN1cHBvcnRzIFB5SW5zdGFsbGVyIDUueCBmb3JtYXQgKFc6IG5vIG1vZHVsZSBuYW1lZCAnZm9vJykgYW5kClB5SW5zdGFsbGVyIDYueCBmb3JtYXQgKG1pc3NpbmcgbW9kdWxlIG5hbWVkIGZvbyAtIGltcG9ydGVkIGJ5IC4uLiAoZGVsYXllZHx0b3AtbGV2ZWx8Y29uZGl0aW9uYWwpKS4KIiIiCl9fdmVyc2lvbl9fID0gInBhcnNlX3dhcm4gdjMgKDIwMjYtMDUtMDMpIgpfX2FsbF9fID0gWyJtYWluIiwgInBhcnNlX3dhcm5fZmlsZSIsICJUUkFOU0xBVElPTlMiLCAiU0tJUCJdCgppbXBvcnQgb3MKaW1wb3J0IHJlCmltcG9ydCBzeXMKClRSQU5TTEFUSU9OUyA9IHsKICAgICJjdjIiOiAib3BlbmN2IiwKICAgICJQSUwiOiAicGlsbG93IiwKICAgICJJbWFnZSI6ICJwaWxsb3ciLAogICAgInNrbGVhcm4iOiAic2Npa2l0LWxlYXJuIiwKICAgICJiczQiOiAiYmVhdXRpZnVsc291cDQiLAogICAgInNlcmlhbCI6ICJweXNlcmlhbCIsCiAgICAieWFtbCI6ICJweXlhbWwiLAogICAgImdpdCI6ICJnaXRweXRob24iLAogICAgInd4IjogInd4cHl0aG9uIiwKICAgICJkYXRldXRpbCI6ICJweXRob24tZGF0ZXV0aWwiLAogICAgImRvdGVudiI6ICJweXRob24tZG90ZW52IiwKICAgICJDcnlwdG8iOiAicHljcnlwdG9kb21lIiwKICAgICJPcGVuU1NMIjogInB5b3BlbnNzbCIsCiAgICAiand0IjogInB5and0IiwKICAgICJ1c2IiOiAicHl1c2IiLAogICAgImF0dHIiOiAiYXR0cnMiLAogICAgIndpbjMyYXBpIjogInB5d2luMzIiLAogICAgIndpbjMyY29uIjogInB5d2luMzIiLAogICAgImZpdHoiOiAicHltdXBkZiIsCiAgICAiZG9jeCI6ICJweXRob24tZG9jeCIsCiAgICAicHlkYW50aWNfY29yZSI6ICJweWRhbnRpYy1jb3JlIiwKfQoKU0tJUCA9IGZyb3plbnNldChbCiAgICAicGtnX3Jlc291cmNlcyIsCiAgICAiZGlzdHV0aWxzIiwKICAgICJzZXR1cHRvb2xzIiwKICAgICJpbXBvcnRsaWIiLAogICAgImltcG9ydGxpYi5tZXRhZGF0YSIsCiAgICAiaW1wb3J0bGliLnJlc291cmNlcyIsCiAgICAiaW1wb3J0bGliLmFiYyIsCiAgICAjIHN0ZGxpYiBwYWNrYWdlcyB3aG9zZSBzdWJtb2R1bGVzIHN1cmZhY2UgYXMgIm1pc3NpbmciIGluIHRoZSB3YXJuIGZpbGUKICAgICMgKGUuZy4gY29sbGVjdGlvbnMuYWJjIC0+IGNvbGxlY3Rpb25zKS4gVGhleSBhcmUgbmV2ZXIgY29uZGEgcGFja2FnZXMsIHNvCiAgICAjIGZvcndhcmRpbmcgdGhlbSB0byAiY29uZGEgaW5zdGFsbCIgb25seSBwcm9kdWNlcyBhIG5vaXN5IFBhY2thZ2VzTm90Rm91bmQuCiAgICAiY29sbGVjdGlvbnMiLAogICAgIyBVbml4LW9ubHkgcGxhdGZvcm0gbW9kdWxlcyBhYnNlbnQgb24gV2luZG93czsgdGhlc2UgYXBwZWFyIGFzIG9wdGlvbmFsL2RlbGF5ZWQKICAgICMgc3RkbGliIGltcG9ydHMgaW4gdGhlIHdhcm4gZmlsZSBhbmQgYXJlIHNhZmUgdG8gaWdub3JlLgogICAgImdycCIsCiAgICAicHdkIiwKICAgICJwb3NpeCIsCiAgICAicmVzb3VyY2UiLAogICAgImZjbnRsIiwKICAgICJyZWFkbGluZSIsCiAgICAidGVybWlvcyIsCiAgICAidHR5IiwKICAgICJwdHkiLAogICAgImNyeXB0IiwKICAgICJzcHdkIiwKICAgICJuaXMiLAogICAgInN5c2xvZyIsCiAgICAib3NzYXVkaW9kZXYiLApdKQoKCmRlZiBwYXJzZV93YXJuX2ZpbGUod2Fybl9wYXRoKToKICAgICIiIlBhcnNlIGEgUHlJbnN0YWxsZXIgd2FybiBmaWxlOyByZXR1cm4gbGlzdCBvZiBjb25kYSBwYWNrYWdlIG5hbWVzIChkZWR1cGxpY2F0ZWQsIG9yZGVyZWQpLgoKICAgIFJldHVybnMgYW4gZW1wdHkgbGlzdCBpZiB3YXJuX3BhdGggZG9lcyBub3QgZXhpc3QuCiAgICBFYWNoIGVudHJ5IGluIFRSQU5TTEFUSU9OUyBtYXBzIGFuIGltcG9ydC1uYW1lIHRvIGEgY29uZGEgcGFja2FnZSBuYW1lLgogICAgVW5rbm93biBpbXBvcnQgbmFtZXMgcGFzcyB0aHJvdWdoIHVuY2hhbmdlZC4KICAgICIiIgogICAgaWYgbm90IG9zLnBhdGguZXhpc3RzKHdhcm5fcGF0aCk6CiAgICAgICAgcmV0dXJuIFtdCiAgICBzZWVuID0gc2V0KCkKICAgIHJlc3VsdCA9IFtdCiAgICB3aXRoIG9wZW4od2Fybl9wYXRoLCAiciIsIGVuY29kaW5nPSJ1dGYtOCIsIGVycm9ycz0iaWdub3JlIikgYXMgZmg6CiAgICAgICAgZm9yIGxpbmUgaW4gZmg6CiAgICAgICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICAgICAgIyBQeUluc3RhbGxlciA1LnggZm9ybWF0OiBXOiBubyBtb2R1bGUgbmFtZWQgJ2ZvbycKICAgICAgICAgICAgbSA9IHJlLm1hdGNoKHIiVzogbm8gbW9kdWxlIG5hbWVkICcoW14nXSspJyIsIGxpbmUpCiAgICAgICAgICAgIGlmIG06CiAgICAgICAgICAgICAgICBtb2QgPSBtLmdyb3VwKDEpLnNwbGl0KCIuIilbMF0KICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgICMgUHlJbnN0YWxsZXIgNi54IGZvcm1hdDoKICAgICAgICAgICAgICAgICMgbWlzc2luZyBtb2R1bGUgbmFtZWQgZm9vIC0gaW1wb3J0ZWQgYnkgYmFyICh0b3AtbGV2ZWwpCiAgICAgICAgICAgICAgICAjIG1pc3NpbmcgbW9kdWxlIG5hbWVkIGZvbyAtIGltcG9ydGVkIGJ5IGJhciAoZGVsYXllZCkKICAgICAgICAgICAgICAgICMgbWlzc2luZyBtb2R1bGUgbmFtZWQgZm9vIC0gaW1wb3J0ZWQgYnkgYmFyIChjb25kaXRpb25hbCkKICAgICAgICAgICAgICAgICMgU2tpcCBlbnRyaWVzIHRoYXQgYXJlIE9OTFkgb3B0aW9uYWwgKHRyeS1leGNlcHQgZ3VhcmRzIHdpdGggbm8KICAgICAgICAgICAgICAgICMgb3RoZXIgcXVhbGlmaWVyKSAtLSB0aG9zZSBhcmUgaW50ZW50aW9uYWxseSByZXNpbGllbnQgdG8gbWlzc2luZwogICAgICAgICAgICAgICAgIyBtb2R1bGVzLiB0b3AtbGV2ZWwsIGRlbGF5ZWQsIGFuZCBjb25kaXRpb25hbCBpbXBvcnRzIGFyZSByZXF1aXJlZAogICAgICAgICAgICAgICAgIyBhdCBydW50aW1lLiBVbml4LW9ubHkgc3RkbGliIHNoaW1zIChncnAsIHB3ZCwgcG9zaXgsIGV0Yy4pIGxhbmQKICAgICAgICAgICAgICAgICMgaW4gdGhvc2UgY2F0ZWdvcmllcyB0b28gYnV0IGFyZSBhbHJlYWR5IGZpbHRlcmVkIGJ5IFNLSVAuCiAgICAgICAgICAgICAgICBtID0gcmUubWF0Y2gociJtaXNzaW5nIG1vZHVsZSBuYW1lZCAoXFMrKSIsIGxpbmUpCiAgICAgICAgICAgICAgICBpZiBub3QgbToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAgaWYgbm90IHJlLnNlYXJjaChyJ1woW14pXSooPzp0b3AtbGV2ZWx8ZGVsYXllZHxjb25kaXRpb25hbClbXildKlwpJywgbGluZSk6CiAgICAgICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgICAgIG1vZCA9IG0uZ3JvdXAoMSkuc3RyaXAoIidcIiIpLnNwbGl0KCIuIilbMF0KICAgICAgICAgICAgaWYgbW9kLnN0YXJ0c3dpdGgoIl8iKToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIGlmIG1vZCBpbiBTS0lQOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgcGtnID0gVFJBTlNMQVRJT05TLmdldChtb2QsIG1vZCkKICAgICAgICAgICAgaWYgcGtnIG5vdCBpbiBzZWVuOgogICAgICAgICAgICAgICAgc2Vlbi5hZGQocGtnKQogICAgICAgICAgICAgICAgcmVzdWx0LmFwcGVuZChwa2cpCiAgICByZXR1cm4gcmVzdWx0CgoKZGVmIG1haW4oKToKICAgIGlmIGxlbihzeXMuYXJndikgPCAyOgogICAgICAgIHN5cy5leGl0KDEpCiAgICBlbnZuYW1lID0gc3lzLmFyZ3ZbMV0KICAgIHdhcm5fcGF0aCA9IG9zLnBhdGguam9pbigiYnVpbGQiLCBlbnZuYW1lLCAid2Fybi0iICsgZW52bmFtZSArICIudHh0IikKICAgIGZvciBwa2cgaW4gcGFyc2Vfd2Fybl9maWxlKHdhcm5fcGF0aCk6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZShwa2cgKyAiXG4iKQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK"
rem ~dep_check.py compares requirements.auto.txt against ~environment.lock.txt;
rem prints 'skip' when all pipreqs packages are already installed, 'run' otherwise.
set "HP_DEP_CHECK=IiIiZGVwX2NoZWNrIHYxICgyMDI2LTAzLTI3KQpDb21wYXJlcyByZXF1aXJlbWVudHMuYXV0by50eHQgKHBpcHJlcXMgb3V0cHV0KSBhZ2FpbnN0IH5lbnZpcm9ubWVudC5sb2NrLnR4dAooY29uZGEgbGlzdCAtLWV4cG9ydCBzbmFwc2hvdCkuIFByaW50cyAnc2tpcCcgd2hlbiBldmVyeSBwYWNrYWdlIGRldGVjdGVkIGJ5CnBpcHJlcXMgaXMgYWxyZWFkeSBwcmVzZW50IGluIHRoZSBsb2NrOyBwcmludHMgJ3J1bicgb3RoZXJ3aXNlIHNvIHRoZSBjYWxsZXIKcHJvY2VlZHMgd2l0aCBjb25kYSBpbnN0YWxsLgoiIiIKX192ZXJzaW9uX18gPSAiZGVwX2NoZWNrIHYxICgyMDI2LTAzLTI3KSIKX19hbGxfXyA9IFsicGFyc2VfbG9jayIsICJwYXJzZV9yZXFzIiwgIm1haW4iXQoKaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc3lzCgpSRVFfRklMRSA9ICJyZXF1aXJlbWVudHMuYXV0by50eHQiCkxPQ0tfRklMRSA9ICJ+ZW52aXJvbm1lbnQubG9jay50eHQiCgoKZGVmIHBhcnNlX2xvY2socGF0aCk6CiAgICAiIiJSZXR1cm4gZnJvemVuc2V0IG9mIGxvd2VyY2FzZSBwYWNrYWdlIG5hbWVzIGZyb20gY29uZGEgbGlzdCAtLWV4cG9ydC4iIiIKICAgIG5hbWVzID0gc2V0KCkKICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4ocGF0aCwgInIiLCBlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9Imlnbm9yZSIpIGFzIGZoOgogICAgICAgICAgICBmb3IgbGluZSBpbiBmaDoKICAgICAgICAgICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICAgICAgICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgiIyIpOgogICAgICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgICAgICAjIGNvbmRhIGxpc3QgLS1leHBvcnQ6IG5hbWU9dmVyc2lvbj1idWlsZFs9Y2hhbm5lbF0KICAgICAgICAgICAgICAgIG5hbWUgPSBsaW5lLnNwbGl0KCI9IilbMF0uc3RyaXAoKS5sb3dlcigpCiAgICAgICAgICAgICAgICBpZiBuYW1lOgogICAgICAgICAgICAgICAgICAgIG5hbWVzLmFkZChuYW1lKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcGFzcwogICAgcmV0dXJuIGZyb3plbnNldChuYW1lcykKCgpkZWYgcGFyc2VfcmVxcyhwYXRoKToKICAgICIiIlJldHVybiBsaXN0IG9mIGxvd2VyY2FzZSBwYWNrYWdlIG5hbWVzIGZyb20gcGlwLXN0eWxlIHJlcXVpcmVtZW50cyBmaWxlLiIiIgogICAgbmFtZXMgPSBbXQogICAgdHJ5OgogICAgICAgIHdpdGggb3BlbihwYXRoLCAiciIsIGVuY29kaW5nPSJ1dGYtOCIsIGVycm9ycz0iaWdub3JlIikgYXMgZmg6CiAgICAgICAgICAgIGZvciBsaW5lIGluIGZoOgogICAgICAgICAgICAgICAgbGluZSA9IGxpbmUuc3RyaXAoKQogICAgICAgICAgICAgICAgaWYgbm90IGxpbmUgb3IgbGluZS5zdGFydHN3aXRoKCIjIik6CiAgICAgICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgICAgICMgU3RyaXAgdmVyc2lvbiBzcGVjaWZpZXI6IG51bXB5Pj0xLjIwIC0+IG51bXB5CiAgICAgICAgICAgICAgICBuYW1lID0gcmUuc3BsaXQociJbPj08IX4sO1xzXFtdIiwgbGluZSwgbWF4c3BsaXQ9MSlbMF0uc3RyaXAoKS5sb3dlcigpCiAgICAgICAgICAgICAgICBpZiBuYW1lOgogICAgICAgICAgICAgICAgICAgIG5hbWVzLmFwcGVuZChuYW1lKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcGFzcwogICAgcmV0dXJuIG5hbWVzCgoKZGVmIG1haW4oKToKICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyhMT0NLX0ZJTEUpOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoInJ1blxuIikKICAgICAgICByZXR1cm4KICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyhSRVFfRklMRSk6CiAgICAgICAgIyBObyBwaXByZXFzIG91dHB1dDsgbm90aGluZyByZXF1aXJlcyBpbnN0YWxsYXRpb24KICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJza2lwXG4iKQogICAgICAgIHJldHVybgogICAgbG9ja19uYW1lcyA9IHBhcnNlX2xvY2soTE9DS19GSUxFKQogICAgaWYgbm90IGxvY2tfbmFtZXM6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgICAgIHJldHVybgogICAgcmVxX25hbWVzID0gcGFyc2VfcmVxcyhSRVFfRklMRSkKICAgIGlmIG5vdCByZXFfbmFtZXM6CiAgICAgICAgIyBFbXB0eSByZXF1aXJlbWVudHMgZmlsZTsgY29uZGEgaW5zdGFsbCB3b3VsZCBiZSBhIG5vLW9wCiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgic2tpcFxuIikKICAgICAgICByZXR1cm4KICAgIG1pc3NpbmcgPSBbbmFtZSBmb3IgbmFtZSBpbiByZXFfbmFtZXMgaWYgbmFtZSBub3QgaW4gbG9ja19uYW1lc10KICAgIGlmIG1pc3Npbmc6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgZWxzZToKICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJza2lwXG4iKQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK"
rem ~collect_submodules.py emits pre-build --collect-submodules flags for packages
rem that load submodules dynamically; double-gated on used-by-source AND installed.
set "HP_COLLECT_SUBMODULES=IiIiY29sbGVjdF9zdWJtb2R1bGVzIHYxICgyMDI2LTA2LTI3KQpQcmUtYnVpbGQgUHlJbnN0YWxsZXIgZmxhZyBnZW5lcmF0b3IgZm9yIHBhY2thZ2VzIHRoYXQgbG9hZCBzdWJtb2R1bGVzCmR5bmFtaWNhbGx5IChwbHVnaW4vYmFja2VuZC9yZWdpc3RyeSBzeXN0ZW1zKSB3aGljaCBQeUluc3RhbGxlcidzIHN0YXRpYwphbmFseXNpcyBjYW5ub3QgdHJhY2UuIFN1Y2ggcGFja2FnZXMgcHJvZHVjZSBOTyB3YXJuLWZpbGUgZW50cnkgKHRoZSBpbXBvcnQKaXRzZWxmIHJlc29sdmVzKSwgc28gd2FybmZpeCBuZXZlciBzZWVzIHRoZW07IHRoZSBmcm96ZW4gRVhFIHRoZW4gZmFpbHMgYXQKcnVudGltZSB3aGVuIGl0IHJlYWNoZXMgdGhlIHVuLWJ1bmRsZWQgc3VibW9kdWxlLgoKRW1pdHMgb25lIHNwYWNlLXNlcGFyYXRlZCBsaW5lIG9mIGAtLWNvbGxlY3Qtc3VibW9kdWxlcz1QS0dgIGZsYWdzIHRvIHN0ZG91dC4KCkRPVUJMRS1HQVRFIChkZWxpYmVyYXRlIC0tIHNlZSBkZXJpdmVkIHJlcXVpcmVtZW50IGJlbG93KTogYSBmbGFnIGlzIGVtaXR0ZWQKb25seSB3aGVuIFBLRyBpcyBCT1RICiAgKDEpIGltcG9ydGVkIGJ5IHRoZSB1c2VyJ3MgcHJvamVjdCBzb3VyY2UgKCJ1c2VkIiksIEFORAogICgyKSBpbXBvcnRhYmxlIGluIHRoZSBidWlsZCBpbnRlcnByZXRlciAoImluc3RhbGxlZCIsIHZpYSBmaW5kX3NwZWMpLgpHYXRpbmcgb24gImluc3RhbGxlZCIgYWxvbmUgd291bGQgYnVuZGxlIGh1bmRyZWRzIG9mIE1CIG9mIGFuIHVudXNlZCBsaWJyYXJ5CmludG8gZXZlcnkgRVhFIG1lcmVseSBiZWNhdXNlIGl0IGhhcHBlbnMgdG8gc2l0IGluIGEgZmF0IGdsb2JhbC9jb25kYSBlbnYKKGEgNS1saW5lIGhlbGxvLXdvcmxkIHNob3VsZCBzdGF5IGxlYW4pLiBHYXRpbmcgb24gInVzZWQiIGFsb25lIGNvdWxkIHBhc3MgYQpmbGFnIGZvciBhIHBhY2thZ2UgdGhhdCBpcyBpbXBvcnRlZCBidXQgbm90IGFjdHVhbGx5IGluc3RhbGxlZCwgd2hpY2ggbWFrZXMKUHlJbnN0YWxsZXIgZXJyb3Igb3V0LiBSZXF1aXJpbmcgYm90aCBrZWVwcyBsZWFuIGFwcHMgbGVhbiBhbmQgYXZvaWRzIHNwdXJpb3VzCmZsYWdzLgoKVGhlIGN1cmF0ZWQgc2V0IHVzZXMgSU1QT1JUIG5hbWVzIChza2xlYXJuLCBub3Qgc2Npa2l0LWxlYXJuKSBiZWNhdXNlCi0tY29sbGVjdC1zdWJtb2R1bGVzIHRha2VzIHRoZSBpbXBvcnRhYmxlIG1vZHVsZSBuYW1lLCBhbmQgbWF0Y2hpbmcgdGhlIGltcG9ydApuYW1lIGFnYWluc3QgcHJvamVjdCBzb3VyY2UgYXZvaWRzIHRoZSBwYWNrYWdlLXZzLWltcG9ydCBuYW1pbmcgbWlzbWF0Y2guCgpVc2FnZTogcHl0aG9uIH5jb2xsZWN0X3N1Ym1vZHVsZXMucHkgW3Byb2plY3Rfcm9vdF0gICAoZGVmYXVsdDogY3dkKQoiIiIKX192ZXJzaW9uX18gPSAiY29sbGVjdF9zdWJtb2R1bGVzIHYxICgyMDI2LTA2LTI3KSIKX19hbGxfXyA9IFsiRFlOQU1JQ19QS0dTIiwgImltcG9ydGVkX3RvcF9sZXZlbHMiLCAiY29sbGVjdF9mbGFncyIsICJtYWluIl0KCmltcG9ydCBhc3QKaW1wb3J0IGltcG9ydGxpYi51dGlsCmltcG9ydCBvcwppbXBvcnQgcmUKaW1wb3J0IHN5cwoKIyBDdXJhdGVkIHNldCBvZiBwYWNrYWdlcyB3aG9zZSBzdWJtb2R1bGVzIGFyZSBsb2FkZWQgdmlhIGR5bmFtaWMgZGlzcGF0Y2gKIyAoZXN0aW1hdG9yIHJlZ2lzdHJpZXMsIGJhY2tlbmQgcGx1Z2lucywgY29tcGlsZWQtZXh0ZW5zaW9uIHN1Ym1vZHVsZXMpIHRoYXQKIyBQeUluc3RhbGxlcidzIHN0YXRpYyB0cmFjZXIgbWlzc2VzLiBJbXBvcnQtbmFtZSA9PSAtLWNvbGxlY3Qtc3VibW9kdWxlcyB0YXJnZXQuCiMgQ29uc2VydmF0aXZlIG9uIHB1cnBvc2U6IGhlYXZ5IE1MIHN0YWNrcyAodG9yY2gvdGVuc29yZmxvdy90cmFuc2Zvcm1lcnMpIGFyZQojIGV4Y2x1ZGVkIC0tIGNvbGxlY3RpbmcgdGhlaXIgc3VibW9kdWxlcyBibG9hdHMgdGhlIEVYRSBieSBnaWdhYnl0ZXMgYW5kIHRob3NlCiMgdXNlcnMgdHlwaWNhbGx5IHN1cHBseSBleHBsaWNpdCBkZXBzLgpEWU5BTUlDX1BLR1MgPSAoInNrbGVhcm4iLCAibWF0cGxvdGxpYiIsICJzY2lweSIsICJwbG90bHkiKQoKIyBEaXJlY3RvcmllcyBuZXZlciBwYXJ0IG9mIHRoZSB1c2VyJ3MgYXBwbGljYXRpb24gc291cmNlLgpfU0tJUF9ESVJTID0gZnJvemVuc2V0KFsKICAgICJkaXN0IiwgImJ1aWxkIiwgIl9fcHljYWNoZV9fIiwgIm5vZGVfbW9kdWxlcyIsCl0pCgoKZGVmIF9za2lwX2RpcihuYW1lKToKICAgICIiIlRydWUgaWYgYSBkaXJlY3Rvcnkgc2hvdWxkIG5vdCBiZSB3YWxrZWQgZm9yIHVzZXIgc291cmNlLiIiIgogICAgaWYgbmFtZS5zdGFydHN3aXRoKCIuIikgb3IgbmFtZS5zdGFydHN3aXRoKCJ+Iik6CiAgICAgICAgcmV0dXJuIFRydWUKICAgIHJldHVybiBuYW1lIGluIF9TS0lQX0RJUlMKCgpkZWYgX3JlZ2V4X3RvcF9sZXZlbHModGV4dCk6CiAgICAiIiJGYWxsYmFjayBpbXBvcnQgc2NhbiBmb3IgYSBzaW5nbGUgZmlsZSB0aGF0IGZhaWxlZCB0byBBU1QtcGFyc2UuCgogICAgTWF0Y2hlcyBvbmx5IGltcG9ydCBzdGF0ZW1lbnRzIGF0IGxpbmUgc3RhcnQgKGFmdGVyIG9wdGlvbmFsIHdoaXRlc3BhY2UpLAogICAgd2l0aCBhIHdvcmQgYm91bmRhcnkgc28gJ2ltcG9ydCBzY2lweXRob24nIGRvZXMgbm90IG1hdGNoICdzY2lweScuCiAgICAiIiIKICAgIGZvdW5kID0gc2V0KCkKICAgIGZvciBwa2cgaW4gRFlOQU1JQ19QS0dTOgogICAgICAgIHBhdHRlcm4gPSByIig/bSleXHMqKD86aW1wb3J0fGZyb20pXHMrIiArIHJlLmVzY2FwZShwa2cpICsgciJcYiIKICAgICAgICBpZiByZS5zZWFyY2gocGF0dGVybiwgdGV4dCk6CiAgICAgICAgICAgIGZvdW5kLmFkZChwa2cpCiAgICByZXR1cm4gZm91bmQKCgpkZWYgX2ZpbGVfdG9wX2xldmVscyh0ZXh0KToKICAgICIiIlJldHVybiB0aGUgc2V0IG9mIHRvcC1sZXZlbCBpbXBvcnRlZCBtb2R1bGUgbmFtZXMgaW4gb25lIHNvdXJjZSBmaWxlLgoKICAgIFVzZXMgQVNUIChzbyBjb21tZW50ZWQtb3V0IG9yIHN0cmluZy1saXRlcmFsICdpbXBvcnRzJyBkbyBub3QgY291bnQpLiBPbiBhCiAgICBTeW50YXhFcnJvciBpbiB0aGUgdXNlcidzIGNvZGUsIGZhbGxzIGJhY2sgdG8gYSBjb25zZXJ2YXRpdmUgcmVnZXggc2NhbiBvZgogICAgdGhlIHNhbWUgdGV4dCBzbyBhIHNpbmdsZSB1bi1wYXJzZWFibGUgZmlsZSBkb2VzIG5vdCBibGluZCB0aGUgd2hvbGUgc2Nhbi4KICAgICIiIgogICAgZm91bmQgPSBzZXQoKQogICAgdHJ5OgogICAgICAgIHRyZWUgPSBhc3QucGFyc2UodGV4dCkKICAgIGV4Y2VwdCAoU3ludGF4RXJyb3IsIFZhbHVlRXJyb3IpOgogICAgICAgIHJldHVybiBfcmVnZXhfdG9wX2xldmVscyh0ZXh0KQogICAgZm9yIG5vZGUgaW4gYXN0LndhbGsodHJlZSk6CiAgICAgICAgaWYgaXNpbnN0YW5jZShub2RlLCBhc3QuSW1wb3J0KToKICAgICAgICAgICAgZm9yIGFsaWFzIGluIG5vZGUubmFtZXM6CiAgICAgICAgICAgICAgICBpZiBhbGlhcy5uYW1lOgogICAgICAgICAgICAgICAgICAgIGZvdW5kLmFkZChhbGlhcy5uYW1lLnNwbGl0KCIuIilbMF0pCiAgICAgICAgZWxpZiBpc2luc3RhbmNlKG5vZGUsIGFzdC5JbXBvcnRGcm9tKToKICAgICAgICAgICAgIyBsZXZlbCA+IDAgaXMgYSByZWxhdGl2ZSBpbXBvcnQgKGZyb20gLiBpbXBvcnQgeCkgLS0gdGhlIG1vZHVsZSBpcwogICAgICAgICAgICAjIGxvY2FsIHRvIHRoZSBwcm9qZWN0LCBuZXZlciBvbmUgb2YgdGhlIGN1cmF0ZWQgdGhpcmQtcGFydHkgcGtncy4KICAgICAgICAgICAgaWYgbm9kZS5sZXZlbCA9PSAwIGFuZCBub2RlLm1vZHVsZToKICAgICAgICAgICAgICAgIGZvdW5kLmFkZChub2RlLm1vZHVsZS5zcGxpdCgiLiIpWzBdKQogICAgcmV0dXJuIGZvdW5kCgoKZGVmIGltcG9ydGVkX3RvcF9sZXZlbHMocm9vdCk6CiAgICAiIiJXYWxrIHRoZSBwcm9qZWN0IHRyZWUgYW5kIHJldHVybiB0aGUgc2V0IG9mIHRvcC1sZXZlbCBpbXBvcnRlZCBtb2R1bGVzLiIiIgogICAgZm91bmQgPSBzZXQoKQogICAgZm9yIGN1cnJlbnQsIGRpcnMsIGZpbGVzIGluIG9zLndhbGsocm9vdCk6CiAgICAgICAgZGlyc1s6XSA9IFtkIGZvciBkIGluIGRpcnMgaWYgbm90IF9za2lwX2RpcihkKV0KICAgICAgICBmb3IgbmFtZSBpbiBmaWxlczoKICAgICAgICAgICAgaWYgbm90IG5hbWUuZW5kc3dpdGgoIi5weSIpIG9yIG5hbWUuc3RhcnRzd2l0aCgifiIpOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgcGF0aCA9IG9zLnBhdGguam9pbihjdXJyZW50LCBuYW1lKQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICB3aXRoIG9wZW4ocGF0aCwgInIiLCBlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9Imlnbm9yZSIpIGFzIGhhbmRsZToKICAgICAgICAgICAgICAgICAgICB0ZXh0ID0gaGFuZGxlLnJlYWQoKQogICAgICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIGZvdW5kIHw9IF9maWxlX3RvcF9sZXZlbHModGV4dCkKICAgIHJldHVybiBmb3VuZAoKCmRlZiBfaXNfaW5zdGFsbGVkKG5hbWUpOgogICAgIiIiVHJ1ZSBpZiBuYW1lIGlzIGltcG9ydGFibGUgaW4gdGhlIGN1cnJlbnQgKGJ1aWxkKSBpbnRlcnByZXRlci4iIiIKICAgIHRyeToKICAgICAgICByZXR1cm4gaW1wb3J0bGliLnV0aWwuZmluZF9zcGVjKG5hbWUpIGlzIG5vdCBOb25lCiAgICBleGNlcHQgKEltcG9ydEVycm9yLCBWYWx1ZUVycm9yLCBBdHRyaWJ1dGVFcnJvcik6CiAgICAgICAgIyBmaW5kX3NwZWMgY2FuIHJhaXNlIGZvciBuYW1lc3BhY2UvcGFydGlhbCBwYWNrYWdlczsgdHJlYXQgYXMgYWJzZW50LgogICAgICAgIHJldHVybiBGYWxzZQoKCmRlZiBjb2xsZWN0X2ZsYWdzKHJvb3QsIGluc3RhbGxlZF9jaGVjaz1Ob25lKToKICAgICIiIlJldHVybiBvcmRlcmVkIC0tY29sbGVjdC1zdWJtb2R1bGVzIGZsYWdzIGZvciB1c2VkIEFORCBpbnN0YWxsZWQgcGFja2FnZXMuCgogICAgaW5zdGFsbGVkX2NoZWNrIGlzIGluamVjdGFibGUgZm9yIHRlc3Rpbmcgc28gdGhlIGdhdGluZyBsb2dpYyBjYW4gYmUKICAgIGV4ZXJjaXNlZCB3aXRob3V0IGFjdHVhbGx5IGluc3RhbGxpbmcgaGVhdnkgcGFja2FnZXMuCiAgICAiIiIKICAgIGlmIGluc3RhbGxlZF9jaGVjayBpcyBOb25lOgogICAgICAgIGluc3RhbGxlZF9jaGVjayA9IF9pc19pbnN0YWxsZWQKICAgIHVzZWQgPSBpbXBvcnRlZF90b3BfbGV2ZWxzKHJvb3QpCiAgICBmbGFncyA9IFtdCiAgICBmb3IgcGtnIGluIERZTkFNSUNfUEtHUzoKICAgICAgICBpZiBwa2cgaW4gdXNlZCBhbmQgaW5zdGFsbGVkX2NoZWNrKHBrZyk6CiAgICAgICAgICAgIGZsYWdzLmFwcGVuZCgiLS1jb2xsZWN0LXN1Ym1vZHVsZXM9IiArIHBrZykKICAgIHJldHVybiBmbGFncwoKCmRlZiBtYWluKGFyZ3Y9Tm9uZSk6CiAgICBhcmdzID0gbGlzdChzeXMuYXJndlsxOl0gaWYgYXJndiBpcyBOb25lIGVsc2UgYXJndikKICAgICMgTm9ybWFsaXplIHRvIGFuIGFic29sdXRlIHBhdGggc28gdGhlIHdhbGsgaXMgYW5jaG9yZWQgcmVnYXJkbGVzcyBvZiB0aGUKICAgICMgY2FsbGVyJ3MgY3dkIC8gcmVsYXRpdmUtcGF0aCBkcmlmdCAoZGVmZW5zaXZlIG9uIFdpbmRvd3MgbXVsdGktZHJpdmUgcGF0aHMpLgogICAgcm9vdCA9IG9zLnBhdGguYWJzcGF0aChhcmdzWzBdIGlmIGFyZ3MgZWxzZSAiLiIpCiAgICBzeXMuc3Rkb3V0LndyaXRlKCIgIi5qb2luKGNvbGxlY3RfZmxhZ3Mocm9vdCkpKQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK"
rem ~hidden_import_scan.py decides the next --hidden-import target from a frozen EXE
rem stderr: strict ModuleNotFoundError + the module must be installed in the build env.
set "HP_HIDDEN_IMPORT_SCAN=IiIiaGlkZGVuX2ltcG9ydF9zY2FuIHYxICgyMDI2LTA2LTI4KQpEZWNpZGUgdGhlIG5leHQgLS1oaWRkZW4taW1wb3J0IHRhcmdldCBmcm9tIGEgZnJvemVuIEVYRSdzIHN0ZGVyciwgZm9yIHRoZQpTbGljZSAyIGF1dG8tcmVjb3ZlcnkgbG9vcCBpbiBydW5fc2V0dXAuYmF0LgoKU1RSSUNUIGFuZCBET1VCTEUtR0FURUQgb24gcHVycG9zZToKICAoMSkgVGhlIEVYRSBzdGRlcnIgbXVzdCBjb250YWluIGBNb2R1bGVOb3RGb3VuZEVycm9yOiBObyBtb2R1bGUgbmFtZWQgJ1gnYC4KICAgICAgVGhhdCBpcyB0aGUgZGV0ZXJtaW5pc3RpYyAiWCdzIGNvZGUgaXMgbm90IGluIHRoZSBidW5kbGUiIHNpZ25hbCAtLQogICAgICBQeUluc3RhbGxlciBsZWZ0IFggb3V0LCBhbmQgYC0taGlkZGVuLWltcG9ydD1YYCBpcyB0aGUgZXhhY3Qgc3RydWN0dXJhbCBmaXguCiAgKDIpIFggKGl0cyB0b3AtbGV2ZWwgcGFja2FnZSkgbXVzdCBiZSBpbXBvcnRhYmxlIGluIHRoZSBCVUlMRCBpbnRlcnByZXRlcgogICAgICAoZmluZF9zcGVjKS4gSWYgWCBpcyBub3QgaW5zdGFsbGVkLCB0aGlzIGlzIGEgdXNlciB0eXBvIG9yIGEgZ2VudWluZWx5CiAgICAgIG1pc3NpbmcgZGVwZW5kZW5jeSAtLSBOT1QgYSBwYWNrYWdpbmcgbWlzcyAtLSBzbyB3ZSBlbWl0IG5vdGhpbmcgYW5kIGxldAogICAgICB0aGUgcG9zdC1mbGlnaHQgaGludHMgc3VyZmFjZSB0aGUgc3RhY2sgdHJhY2UuIFRoaXMgaXMgd2hhdCBtYWtlcyBhIHR5cG8KICAgICAgbGlrZSBgaW1wb3J0IG5vbmV4aXN0YW50YCBjb3N0IFpFUk8gcmVidWlsZHMuCiAgKDMpIFggbXVzdCBub3QgYWxyZWFkeSBiZSBpbiB0aGUgYWxyZWFkeS10cmllZCBsaXN0IChubyBsb29wcykuCiAgKDQpIFggbXVzdCBub3QgYmUgYSBwbGF0Zm9ybS9zdGRsaWIgc2hpbSBsZWdpdGltYXRlbHkgYWJzZW50IG9uIFdpbmRvd3MuCgpEZWxpYmVyYXRlbHkgTk9UIGhhbmRsZWQ6IGBJbXBvcnRFcnJvcjogY2Fubm90IGltcG9ydCBuYW1lICdZJyBmcm9tICdaJ2AuIFogaXMKYWxyZWFkeSBidW5kbGVkIGFuZCBZIGlzIGFuIGF0dHJpYnV0ZSwgbm90IGEgbW9kdWxlLCBzbyBubyAtLWhpZGRlbi1pbXBvcnQKdGFyZ2V0IGlzIGRlcml2YWJsZSBhbmQgYSByZWJ1aWxkIGNhbm5vdCBmaXggaXQuIFN1Y2ggZXJyb3JzIGFyZSB1c2VyIGNvZGUKKHR5cG9zLCBjaXJjdWxhciBpbXBvcnRzLCB2ZXJzaW9uIGRyaWZ0KSBvciBkeW5hbWljLXN1Ym1vZHVsZSBnYXBzIGJldHRlciBmaXhlZApieSAtLWNvbGxlY3Qtc3VibW9kdWxlcyAoaGFuZGxlZCBzZXBhcmF0ZWx5KS4gVGhleSByb3V0ZSB0byBoaW50cyB1bmNoYW5nZWQuCgpVc2FnZTogcHl0aG9uIH5oaWRkZW5faW1wb3J0X3NjYW4ucHkgPHN0ZGVycl9maWxlPiBbYWxyZWFkeV90cmllZCAuLi5dClByaW50cyB0aGUgbmV4dCBoaWRkZW4taW1wb3J0IG1vZHVsZSBuYW1lIChvciBub3RoaW5nKSB0byBzdGRvdXQuCiIiIgpfX3ZlcnNpb25fXyA9ICJoaWRkZW5faW1wb3J0X3NjYW4gdjEgKDIwMjYtMDYtMjgpIgpfX2FsbF9fID0gWyJTS0lQIiwgIm5leHRfaGlkZGVuX2ltcG9ydCIsICJtYWluIl0KCmltcG9ydCBpbXBvcnRsaWIudXRpbAppbXBvcnQgcmUKaW1wb3J0IHN5cwoKIyBQbGF0Zm9ybS9zdGRsaWIgbW9kdWxlcyBsZWdpdGltYXRlbHkgYWJzZW50IG9uIFdpbmRvd3MgLS0gbmV2ZXIgYSBwYWNrYWdpbmcKIyBtaXNzLCBzbyBuZXZlciBoaWRkZW4taW1wb3J0IHRoZW0gKG1pcnJvciBvZiB0aGUgcGFyc2Vfd2FybiB1bml4LW9ubHkgc2V0KS4KU0tJUCA9IGZyb3plbnNldChbCiAgICAiZ3JwIiwgInB3ZCIsICJwb3NpeCIsICJyZXNvdXJjZSIsICJmY250bCIsICJyZWFkbGluZSIsICJ0ZXJtaW9zIiwgInR0eSIsCiAgICAicHR5IiwgImNyeXB0IiwgInNwd2QiLCAibmlzIiwgInN5c2xvZyIsICJvc3NhdWRpb2RldiIsCiAgICAiX3Bvc2l4c3VicHJvY2VzcyIsICJfc2Nwcm94eSIsICJfZnJvemVuX2ltcG9ydGxpYl9leHRlcm5hbCIsCl0pCgojIE9ubHkgTW9kdWxlTm90Rm91bmRFcnJvciAtLSBOT1QgYSBiYXJlIEltcG9ydEVycm9yIChzZWUgbW9kdWxlIGRvY3N0cmluZykuCl9QQVRURVJOID0gcmUuY29tcGlsZSgKICAgIHIiTW9kdWxlTm90Rm91bmRFcnJvcjogTm8gbW9kdWxlIG5hbWVkIFsnXCJdKFteJ1wiXSspWydcIl0iCikKCgpkZWYgX2lzX2luc3RhbGxlZChuYW1lKToKICAgICIiIlRydWUgaWYgbmFtZSBpcyBpbXBvcnRhYmxlIGluIHRoZSBjdXJyZW50IChidWlsZCkgaW50ZXJwcmV0ZXIuIiIiCiAgICB0cnk6CiAgICAgICAgcmV0dXJuIGltcG9ydGxpYi51dGlsLmZpbmRfc3BlYyhuYW1lKSBpcyBub3QgTm9uZQogICAgZXhjZXB0IChJbXBvcnRFcnJvciwgVmFsdWVFcnJvciwgQXR0cmlidXRlRXJyb3IpOgogICAgICAgIHJldHVybiBGYWxzZQoKCmRlZiBuZXh0X2hpZGRlbl9pbXBvcnQoc3RkZXJyX3RleHQsIGFscmVhZHlfdHJpZWQ9KCksIGluc3RhbGxlZF9jaGVjaz1Ob25lKToKICAgICIiIlJldHVybiB0aGUgbmV4dCAtLWhpZGRlbi1pbXBvcnQgbW9kdWxlIG5hbWUsIG9yICIiIGlmIG5vbmUgaXMgZml4YWJsZS4KCiAgICBpbnN0YWxsZWRfY2hlY2sgaXMgaW5qZWN0YWJsZSBmb3IgdGVzdGluZyBzbyB0aGUgZmluZF9zcGVjIGdhdGUgY2FuIGJlCiAgICBleGVyY2lzZWQgd2l0aG91dCBpbnN0YWxsaW5nIHBhY2thZ2VzLiBJdCBpcyBjYWxsZWQgd2l0aCB0aGUgVE9QLUxFVkVMCiAgICBwYWNrYWdlIG5hbWUgKG5vdCB0aGUgZG90dGVkIHN1Ym1vZHVsZSkgdG8gYXZvaWQgaW1wb3J0aW5nIHRoZSBwYXJlbnQKICAgIHBhY2thZ2UncyBzaWRlIGVmZmVjdHMgZHVyaW5nIGRldGVjdGlvbi4KICAgICIiIgogICAgaWYgaW5zdGFsbGVkX2NoZWNrIGlzIE5vbmU6CiAgICAgICAgaW5zdGFsbGVkX2NoZWNrID0gX2lzX2luc3RhbGxlZAogICAgdHJpZWQgPSBzZXQoYWxyZWFkeV90cmllZCkKICAgIGZvciBtYXRjaCBpbiBfUEFUVEVSTi5maW5kaXRlcihzdGRlcnJfdGV4dCk6CiAgICAgICAgbW9kID0gbWF0Y2guZ3JvdXAoMSkuc3RyaXAoKQogICAgICAgIGlmIG5vdCBtb2Qgb3IgbW9kIGluIHRyaWVkOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIHRvcCA9IG1vZC5zcGxpdCgiLiIpWzBdCiAgICAgICAgaWYgdG9wIGluIFNLSVAgb3IgbW9kIGluIFNLSVAgb3IgdG9wLnN0YXJ0c3dpdGgoIl8iKToKICAgICAgICAgICAgY29udGludWUKICAgICAgICAjIEdhdGUgKDIpOiB0aGUgdG9wLWxldmVsIHBhY2thZ2UgbXVzdCBiZSBpbnN0YWxsZWQgaW4gdGhlIGJ1aWxkIGludGVycC4KICAgICAgICAjIFdlIGVtaXQgdGhlIEZVTEwgZG90dGVkIG5hbWUgYXMgdGhlIGhpZGRlbi1pbXBvcnQgdGFyZ2V0IGJ1dCBnYXRlIG9uCiAgICAgICAgIyB0aGUgdG9wLWxldmVsIHBhY2thZ2Ugc28gZGV0ZWN0aW9uIG5ldmVyIGltcG9ydHMgYSBoZWF2eSBzdWJtb2R1bGUuCiAgICAgICAgaWYgaW5zdGFsbGVkX2NoZWNrKHRvcCk6CiAgICAgICAgICAgIHJldHVybiBtb2QKICAgIHJldHVybiAiIgoKCmRlZiBtYWluKGFyZ3Y9Tm9uZSk6CiAgICBhcmdzID0gbGlzdChzeXMuYXJndlsxOl0gaWYgYXJndiBpcyBOb25lIGVsc2UgYXJndikKICAgIGlmIG5vdCBhcmdzOgogICAgICAgIHJldHVybgogICAgc3RkZXJyX2ZpbGUgPSBhcmdzWzBdCiAgICBhbHJlYWR5ID0gYXJnc1sxOl0KICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4oc3RkZXJyX2ZpbGUsICJyIiwgZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJpZ25vcmUiKSBhcyBmaDoKICAgICAgICAgICAgdGV4dCA9IGZoLnJlYWQoKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcmV0dXJuCiAgICBzeXMuc3Rkb3V0LndyaXRlKG5leHRfaGlkZGVuX2ltcG9ydCh0ZXh0LCBhbHJlYWR5KSkKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg=="
rem ~pep723_writeback.py promotes resolved dependencies into the entry file's
rem PEP 723 header via uv add --script; see docs/plan-pep723-writeback.md Part 2.1.
set "HP_PEP723_WRITEBACK=IiIicGVwNzIzX3dyaXRlYmFjayB2MSAoMjAyNi0wNy0xOCkKUHJvbW90ZXMgYSByZXNvbHZlZCBkZXBlbmRlbmN5IGxpc3QgaW50byB0aGUgZW50cnkgZmlsZSdzIFBFUCA3MjMgaGVhZGVyIHZpYQpgdXYgYWRkIC0tc2NyaXB0YC4gU2VlIGRvY3MvcGxhbi1wZXA3MjMtd3JpdGViYWNrLm1kIFBhcnQgMi4xIGZvciB0aGUgZnVsbCBkZXNpZ24uClVzYWdlOiBweXRob24gcGVwNzIzX3dyaXRlYmFjay5weSA8ZW50cnkucHk+IDx1dl9leGU+IDxweXRob25fZXhlPiA8cGFja2FnZXNfZmlsZT4KUHJpbnRzIG9uZSByZXN1bHQgbGluZSB0byBzdGRvdXQ6IE9LOjxuPiAvIFNLSVA6PHJlYXNvbj4gLyBFUlJPUjo8cmVhc29uPi4KIiIiCl9fdmVyc2lvbl9fID0gInBlcDcyM193cml0ZWJhY2sgdjEgKDIwMjYtMDctMTgpIgpfX2FsbF9fID0gWyJyZWFkX3BhY2thZ2VzIiwgInN0cmlwX3BlcDcyM19ibG9jayIsICJtYWluIl0KCmltcG9ydCBvcwppbXBvcnQgc3VicHJvY2VzcwppbXBvcnQgc3lzCgoKZGVmIHJlYWRfcGFja2FnZXMocGF0aCk6CiAgICAiIiJSZXR1cm4gYSBsaXN0IG9mIG5vbi1ibGFuaywgbm9uLWNvbW1lbnQgbGluZXMgZnJvbSBhIHBhY2thZ2VzIGZpbGUuIiIiCiAgICBwYWNrYWdlcyA9IFtdCiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKHBhdGgsICJyIiwgZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJpZ25vcmUiKSBhcyBmaDoKICAgICAgICAgICAgZm9yIGxpbmUgaW4gZmg6CiAgICAgICAgICAgICAgICBsaW5lID0gbGluZS5zdHJpcCgpCiAgICAgICAgICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dpdGgoIiMiKToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAgIyBwaXAgZGlyZWN0aXZlcyAoLWUsIC1yLCAtLWhhc2gsIC4uLikgZXhpdCAyIGZyb20gdXYncyBjbGFwCiAgICAgICAgICAgICAgICAjIHBhcnNlciBzYW1lIGFzIG1hbGZvcm1lZCBUT01MIC0tIGZpbHRlciBvciBtYWluKCkgd3JvbmdseQogICAgICAgICAgICAgICAgIyBzdHJpcHMgYSB2YWxpZCBoZWFkZXIuIFJlYWwgc3BlY3MgbmV2ZXIgc3RhcnQgd2l0aCAnLScuCiAgICAgICAgICAgICAgICBpZiBsaW5lLnN0YXJ0c3dpdGgoIi0iKToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAgcGFja2FnZXMuYXBwZW5kKGxpbmUpCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICBwYXNzCiAgICByZXR1cm4gcGFja2FnZXMKCgpkZWYgc3RyaXBfcGVwNzIzX2Jsb2NrKHRleHQpOgogICAgIiIiUmVtb3ZlIGFuIGV4aXN0aW5nICcjIC8vLyBzY3JpcHQnIC4uLiAnIyAvLy8nIGJsb2NrLCBsaW5lIGJ5IGxpbmUuCgogICAgQSBsaW5lLWJ5LWxpbmUgc3RhdGUgbWFjaGluZSwgbm90IGEgcmVnZXg6IGEgZ3JlZWR5IHJlZ2V4IHJpc2tzIHN0cmlwcGluZwogICAgY29kZSBhZnRlciB0aGUgYmxvY2ssIGFuZCBhIGxhenkgb25lIGNhbiBsZWF2ZSBhIHN0cmF5IGZlbmNlIGxpbmUgYmVoaW5kLAogICAgd2hpY2ggbmV3ZXIgdXYgdHJlYXRzIGFzIGEgaGFyZCBlcnJvciAoYXN0cmFsLXNoL3V2IzE5NTQ0KS4gVGhlIGNsb3NpbmcKICAgIGZlbmNlIG1hdGNoIHRvbGVyYXRlcyB0cmFpbGluZyB3aGl0ZXNwYWNlIChhc3RyYWwtc2gvdXYjMTA5MTgpLgogICAgIiIiCiAgICBsaW5lcyA9IHRleHQuc3BsaXRsaW5lcyhrZWVwZW5kcz1UcnVlKQogICAgb3V0ID0gW10KICAgIGluX2Jsb2NrID0gRmFsc2UKICAgIGZvciBsaW5lIGluIGxpbmVzOgogICAgICAgIHN0cmlwcGVkID0gbGluZS5yc3RyaXAoIlxyXG4iKQogICAgICAgIGlmIG5vdCBpbl9ibG9jayBhbmQgc3RyaXBwZWQgPT0gIiMgLy8vIHNjcmlwdCI6CiAgICAgICAgICAgIGluX2Jsb2NrID0gVHJ1ZQogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGlmIGluX2Jsb2NrOgogICAgICAgICAgICBpZiBzdHJpcHBlZC5yc3RyaXAoKSA9PSAiIyAvLy8iOgogICAgICAgICAgICAgICAgaW5fYmxvY2sgPSBGYWxzZQogICAgICAgICAgICBjb250aW51ZQogICAgICAgIG91dC5hcHBlbmQobGluZSkKICAgIHJldHVybiAiIi5qb2luKG91dCkKCgpkZWYgcnVuX3V2X2FkZChlbnRyeV9wYXRoLCB1dl9leGUsIHB5dGhvbl9leGUsIHBhY2thZ2VzKToKICAgICIiIkludm9rZSBgdXYgYWRkIC0tc2NyaXB0YCBvbmNlOyByZXR1cm4gKHJldHVybmNvZGUsIHN0ZGVycl90ZXh0KS4iIiIKICAgIGNtZCA9IFt1dl9leGUsICJhZGQiLCAiLS1zY3JpcHQiLCBlbnRyeV9wYXRoLCAiLXAiLCBweXRob25fZXhlXSArIHBhY2thZ2VzCiAgICB0cnk6CiAgICAgICAgIyBCb3VuZGVkIGxpa2Ugb3RoZXIgbmV0d29yay10b3VjaGluZyBoZWxwZXJzIGhlcmUgKGVtYmVkX3B5dmVyX2NoZWNrLnB5CiAgICAgICAgIyBzb2NrZXQgdGltZW91dCkgLS0gYSBzdGFsbGVkIHV2IGNhbGwgbXVzdCBub3QgaGFuZyB0aGUgYm9vdHN0cmFwLgogICAgICAgIHByb2MgPSBzdWJwcm9jZXNzLnJ1bihjbWQsIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSwgdGltZW91dD0xMjApCiAgICBleGNlcHQgc3VicHJvY2Vzcy5UaW1lb3V0RXhwaXJlZDoKICAgICAgICByZXR1cm4gMSwgInRpbWVvdXQiCiAgICAjIGFzdHJhbC1zaC91diMxNTk1NjogYSBiZW5pZ24gVklSVFVBTF9FTlYgbWlzbWF0Y2ggd2FybmluZyBjYW4gYXBwZWFyIG9uIHN0ZGVycgogICAgIyB3aXRoIGV4aXQgY29kZSAwIC0tIHN0ZGVyciB0ZXh0IGlzIG5ldmVyIGl0c2VsZiBhIGZhaWx1cmUgc2lnbmFsLCBvbmx5IHRoZQogICAgIyBwcm9jZXNzIHJldHVybiBjb2RlIGlzLgogICAgcmV0dXJuIHByb2MucmV0dXJuY29kZSwgcHJvYy5zdGRlcnIKCgpkZWYgbWFpbihhcmd2PU5vbmUpOgogICAgYXJncyA9IGxpc3Qoc3lzLmFyZ3ZbMTpdIGlmIGFyZ3YgaXMgTm9uZSBlbHNlIGFyZ3YpCiAgICBpZiBsZW4oYXJncykgPCA0OgogICAgICAgIHByaW50KCJFUlJPUjpiYWRfYXJncyIpCiAgICAgICAgcmV0dXJuIDEKICAgIGVudHJ5X3BhdGgsIHV2X2V4ZSwgcHl0aG9uX2V4ZSwgcGFja2FnZXNfZmlsZSA9IGFyZ3NbMF0sIGFyZ3NbMV0sIGFyZ3NbMl0sIGFyZ3NbM10KCiAgICBwYWNrYWdlcyA9IHJlYWRfcGFja2FnZXMocGFja2FnZXNfZmlsZSkKICAgIGlmIG5vdCBwYWNrYWdlczoKICAgICAgICBwcmludCgiU0tJUDpub19wYWNrYWdlcyIpCiAgICAgICAgcmV0dXJuIDAKCiAgICAjIEVuY29kaW5nIHByZS1jaGVjazogbmV2ZXIgaGFuZCB1diBhIGZpbGUgd2hvc2UgVVRGLTgtbmVzcyBpcyB1bmNvbmZpcm1lZC4KICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4oZW50cnlfcGF0aCwgZW5jb2Rpbmc9InV0Zi04IikgYXMgZmg6CiAgICAgICAgICAgIGZoLnJlYWQoKQogICAgZXhjZXB0IChVbmljb2RlRGVjb2RlRXJyb3IsIE9TRXJyb3IpOgogICAgICAgIHByaW50KCJTS0lQOm5vbl91dGY4IikKICAgICAgICByZXR1cm4gMAoKICAgICMgRmlsZS1sb2NrIGNhbmFyeTogZGlhZ25vc3RpYy1xdWFsaXR5IG9ubHksIGdpdmVzIGEgY2xlYXJlciByZWFzb24gdGhhbiB0aGUKICAgICMgZ2VuZXJpYyBFUlJPUjp1dl9yY188bj4gcGF0aCBiZWxvdy4gQWNjZXB0ZWQgVE9DVE9VIHJhY2UgKGxvY2sgY291bGQgYmUKICAgICMgYWNxdWlyZWQgYWZ0ZXIgdGhpcyBjaGVjaykgZmFsbHMgYmFjayB0byB0aGF0IHNhbWUgc2FmZSBnZW5lcmljIHBhdGguCiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKGVudHJ5X3BhdGgsICJyK2IiKToKICAgICAgICAgICAgcGFzcwogICAgZXhjZXB0IFBlcm1pc3Npb25FcnJvcjoKICAgICAgICBwcmludCgiU0tJUDpmaWxlX2xvY2tlZCIpCiAgICAgICAgcmV0dXJuIDAKICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgIHBhc3MKCiAgICBpZiBlbnRyeV9wYXRoLmVuZHN3aXRoKCIucHkiKSBhbmQgX2xvY2tfc2lkZWNhcl9leGlzdHMoZW50cnlfcGF0aCk6CiAgICAgICAgcHJpbnQoIlNLSVA6bG9ja2ZpbGUiKQogICAgICAgIHJldHVybiAwCgogICAgcmMsIF9zdGRlcnIgPSBydW5fdXZfYWRkKGVudHJ5X3BhdGgsIHV2X2V4ZSwgcHl0aG9uX2V4ZSwgcGFja2FnZXMpCiAgICBpZiByYyA9PSAwOgogICAgICAgIHByaW50KCJPSzolZCIgJSBsZW4ocGFja2FnZXMpKQogICAgICAgIHJldHVybiAwCiAgICBpZiByYyA9PSAyOgogICAgICAgICMgYXN0cmFsLXNoL3V2IzEwOTE4IC8gIzE5NTQ0OiBleGl0IDIgaXMgdXYncyBzaWduYWwgdGhlIGV4aXN0aW5nIGhlYWRlcgogICAgICAgICMgaXMgdW5wYXJzZWFibGUgVE9NTCAtLSB0aGUgb25lIGNhc2Ugd2hlcmUgc3RhcnRpbmcgb3ZlciBpcyBjb3JyZWN0LgogICAgICAgICMgQW55IG90aGVyIGV4aXQgY29kZSBtdXN0IG5vdCBzdHJpcCBhbnl0aGluZy4KICAgICAgICB0cnk6CiAgICAgICAgICAgICMgbmV3bGluZT0iIiBrZWVwcyBDUkxGIGludGFjdCBvbiByZWFkIC0tIHdpdGhvdXQgaXQsIGJvdGggdGhlCiAgICAgICAgICAgICMgc3RyaXBwZWQgd3JpdGUgYW5kIHRoZSByZXN0b3JlLW9uLWRvdWJsZS1mYWlsdXJlIHdyaXRlIGJlbG93CiAgICAgICAgICAgICMgd291bGQgc2lsZW50bHkgbm9ybWFsaXplIHRoZSB3aG9sZSBmaWxlJ3MgbGluZSBlbmRpbmdzIHRvIExGLgogICAgICAgICAgICB3aXRoIG9wZW4oZW50cnlfcGF0aCwgInIiLCBlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9Imlnbm9yZSIsIG5ld2xpbmU9IiIpIGFzIGZoOgogICAgICAgICAgICAgICAgb3JpZ2luYWwgPSBmaC5yZWFkKCkKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgcHJpbnQoIkVSUk9SOnN0cmlwX3JldHJ5X2ZhaWxlZDpyZWFkIikKICAgICAgICAgICAgcmV0dXJuIDEKICAgICAgICBzdHJpcHBlZCA9IHN0cmlwX3BlcDcyM19ibG9jayhvcmlnaW5hbCkKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggb3BlbihlbnRyeV9wYXRoLCAidyIsIGVuY29kaW5nPSJ1dGYtOCIsIG5ld2xpbmU9IiIpIGFzIGZoOgogICAgICAgICAgICAgICAgZmgud3JpdGUoc3RyaXBwZWQpCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHByaW50KCJFUlJPUjpzdHJpcF9yZXRyeV9mYWlsZWQ6d3JpdGUiKQogICAgICAgICAgICByZXR1cm4gMQogICAgICAgIHJjMiwgX3N0ZGVycjIgPSBydW5fdXZfYWRkKGVudHJ5X3BhdGgsIHV2X2V4ZSwgcHl0aG9uX2V4ZSwgcGFja2FnZXMpCiAgICAgICAgaWYgcmMyID09IDA6CiAgICAgICAgICAgIHByaW50KCJPSzolZCIgJSBsZW4ocGFja2FnZXMpKQogICAgICAgICAgICByZXR1cm4gMAogICAgICAgICMgUmV0cnkgYWxzbyBmYWlsZWQgLS0gcmVzdG9yZSBvcmlnaW5hbCAoc3RpbGwtbWFsZm9ybWVkKSBjb250ZW50IHJhdGhlcgogICAgICAgICMgdGhhbiBsZWF2ZSB0aGUgZmlsZSBwZXJtYW5lbnRseSBzdHJpcHBlZCAobWlycm9ycyBQVlcgUXVpY2tTdGFydCdzIG93bgogICAgICAgICMgcmVzdG9yZS1vbi1kb3VibGUtZmFpbHVyZSBndWFyYW50ZWUpLgogICAgICAgIHRyeToKICAgICAgICAgICAgd2l0aCBvcGVuKGVudHJ5X3BhdGgsICJ3IiwgZW5jb2Rpbmc9InV0Zi04IiwgbmV3bGluZT0iIikgYXMgZmg6CiAgICAgICAgICAgICAgICBmaC53cml0ZShvcmlnaW5hbCkKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgcGFzcwogICAgICAgIHByaW50KCJFUlJPUjpzdHJpcF9yZXRyeV9mYWlsZWQ6JWQiICUgcmMyKQogICAgICAgIHJldHVybiAxCiAgICBwcmludCgiRVJST1I6dXZfcmNfJWQiICUgcmMpCiAgICByZXR1cm4gMQoKCmRlZiBfbG9ja19zaWRlY2FyX2V4aXN0cyhlbnRyeV9wYXRoKToKICAgIHJldHVybiBvcy5wYXRoLmV4aXN0cyhlbnRyeV9wYXRoICsgIi5sb2NrIikKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo="
exit /b 0
:log
set "MSG=%~1"
echo %date% %time% %MSG%
>> "%LOG%" echo [%date% %time%] %MSG%
exit /b 0
:write_runtime_txt
rem derived requirement: called from inside a parenthesized if-block so %PYVER%
rem would expand at block-parse time (empty) if inlined. Subroutine body is
rem re-parsed at call time, so %PYVER% correctly reflects the for/f result.
rem derived requirement: guarded by HP_RUNTIME_TXT_PREEXIST so write-back only
rem fires when runtime.txt did not pre-exist (Tier 2/3 promotion to Tier 1).
if not defined HP_RUNTIME_TXT_PREEXIST if not "%PYVER%"=="" (
  >"runtime.txt" echo %PYVER%
  if errorlevel 1 (
    call :log "[WARN] runtime.txt write failed (read-only filesystem?). Tier 3 remains active."
  ) else (
    call :log "[INFO] runtime.txt written: %PYVER%"
    set "PYSPEC=%PYVER:python-=python=%"
  )
)
exit /b 0
rem :conda_binary_corrupt -- REQ-020: shows user-friendly message when conda binary fails health check.
rem Called when: (a) HP_TEST_CORRUPT_CONDA=1, (b) call "%CONDA_BAT%" info returns non-zero (DLL error, etc.).
rem Interactive users get a Y/N prompt to self-heal; CI exits immediately.
rem HP_TEST_HEAL_ANSWER bypasses HP_CI_LANE gate so CI can test the decline path without pausing.
rem PVW_CONDA_EXE overrides skip self-heal: we must not delete a user-managed conda root.
:conda_binary_corrupt
cls
echo.
echo ================================================================
echo   CORRUPTED PYTHON ENVIRONMENT DETECTED
echo ================================================================
echo.
echo   The local conda installation appears to be broken.
echo   This can happen after a Windows update or OS migration
echo   ^(example: DLL load error 0xc000007b^).
echo.
echo   Affected path: %MINICONDA_ROOT%
echo.
call :log "[ERROR] Corrupt conda binary detected at: %CONDA_BAT%"
if defined PVW_CONDA_EXE goto :corrupt_override_exit
if defined HP_TEST_HEAL_ANSWER goto :heal_prompt
if defined HP_CI_LANE goto :corrupt_ci_exit
:heal_prompt
set "HP_HEAL_RAW="
if defined HP_TEST_HEAL_ANSWER (
  set "HP_HEAL_RAW=%HP_TEST_HEAL_ANSWER%"
) else (
  set /p "HP_HEAL_RAW=  Would you like to delete it and rebuild? [Y/N] "
)
set "HP_HEAL_CHOICE=%HP_HEAL_RAW:~0,1%"
if /I "%HP_HEAL_CHOICE%"=="Y" goto :evict_and_rebuild
echo.
echo   Exiting without changes. Delete the folder above manually,
echo   then run this setup again.
echo.
call :die "[ERROR] Corrupt conda env; user declined rebuild." 2
exit /b 2
:corrupt_override_exit
echo.
echo   This binary was specified via PVW_CONDA_EXE:
echo     %PVW_CONDA_EXE%
echo.
echo   Automatic self-healing is not available for user-managed conda.
echo   Please fix or replace the binary at the path above, then re-run.
echo.
call :die "[ERROR] Corrupt user-managed conda (PVW_CONDA_EXE); fix manually." 2
exit /b 2
:corrupt_ci_exit
call :die "[ERROR] Corrupt conda binary in CI; cache must be cleared." 2
exit /b 2
:evict_and_rebuild
echo.
echo   [INFO] Removing corrupt Miniconda installation...
rem HP_TEST_SKIP_EVICT: CI branch-coverage flag -- skip actual deletion and re-download so
rem the test does not destroy the CI Miniconda installation. The eviction log line fires to
rem prove the accept branch was reached. Must not be set in production.
if not defined HP_TEST_SKIP_EVICT (
  rmdir /s /q "%MINICONDA_ROOT%" 2>nul
  if exist "%MINICONDA_ROOT%" (
    echo.
    echo   [WARN] Could not fully remove %MINICONDA_ROOT%.
    echo   Some files may be locked. Close any Python/conda windows and try again.
    echo.
    call :die "[ERROR] Could not delete corrupt conda dir; files may be locked." 3
    exit /b 3
  )
  echo   [INFO] Corrupt installation removed. Downloading fresh copy...
)
call :log "[INFO] Self-healing: corrupt conda evicted from %MINICONDA_ROOT%."
set "CONDA_BAT="
set "HP_CONDA_JUST_INSTALLED="
set "HP_ENV_STATE_RESULT="
if not defined HP_TEST_SKIP_EVICT (
  call :download_miniconda_exe
  if exist "%TEMP%\miniconda.exe" (
    call :try_conda_install
  )
  if exist "%TEMP%\miniconda.exe" del "%TEMP%\miniconda.exe" >nul 2>&1
)
call :select_conda_bat
if not defined CONDA_BAT (
  call :die "[ERROR] Fresh Miniconda install failed after self-healing eviction." 4
  exit /b 4
)
set "HP_CONDA_JUST_INSTALLED=1"
goto :after_conda_bat_validation
:conda_bulk_install
rem Run conda bulk install; retry once if output indicates a transient network failure.
rem derived requirement: ~conda_bulk.tmp is tilde-prefixed so it is gitignored and cleaned here.
if exist "~conda_bulk.tmp" del "~conda_bulk.tmp" >nul 2>&1
rem [TEST] HP_TEST_FORCE_CONDA_BULK_FAIL: force a non-transient bulk failure (no retry keyword)
rem so the caller takes the REQ-005.3 per-package fallback. No real conda call is made here.
if "%HP_TEST_FORCE_CONDA_BULK_FAIL%"=="1" (
  call :log "[TEST] HP_TEST_FORCE_CONDA_BULK_FAIL: forcing non-transient bulk failure for REQ-005.3 per-pkg fallback."
  exit /b 1
)
if not "%HP_TEST_FORCE_CONDA_NETWORK_FAIL%"=="1" goto :conda_bulk_real_call
rem [TEST] HP_TEST_FORCE_CONDA_NETWORK_FAIL: simulate a transient CondaHTTPError on first attempt.
echo CondaHTTPError: HTTP 000 CONNECTION FAILED (simulated) > "~conda_bulk.tmp"
set "HP_TEST_FORCE_CONDA_NETWORK_FAIL="
type "~conda_bulk.tmp" >> "%LOG%"
set "HP_CBULK_RC=1"
goto :conda_bulk_have_rc
:conda_bulk_real_call
call "%CONDA_BAT%" install -y -n "%ENVNAME%" --file "~reqs_conda.txt" --override-channels -c conda-forge > "~conda_bulk.tmp" 2>&1
set "HP_CBULK_RC=%ERRORLEVEL%"
type "~conda_bulk.tmp" >> "%LOG%"
:conda_bulk_have_rc
if "%HP_CBULK_RC%"=="0" (
  del "~conda_bulk.tmp" >nul 2>&1
  exit /b 0
)
findstr /i /c:"CondaHTTPError" /c:"Failed to fetch" /c:"timed out" /c:"ConnectionError" "~conda_bulk.tmp" >nul 2>&1
if errorlevel 1 (
  del "~conda_bulk.tmp" >nul 2>&1
  exit /b 1
)
del "~conda_bulk.tmp" >nul 2>&1
echo Conda install failed -- possible network or repository issue. Retrying once...
call :log "[INSTALL] conda bulk: transient failure detected; retrying after 15s."
timeout /t 15 /nobreak >nul 2>&1
echo Retrying package installation...
call "%CONDA_BAT%" install -y -n "%ENVNAME%" --file "~reqs_conda.txt" --override-channels -c conda-forge >> "%LOG%" 2>&1
if not errorlevel 1 exit /b 0
echo *** Package installation could not complete. This may be a temporary network issue.
echo *** See log file for details: ~setup.log
call :log "[WARN] conda bulk: retry after transient failure also failed."
exit /b 1

:die
set "MSG=%~1"
set "RC=%~2"
if "%RC%"=="" set "RC=1"
echo %date% %time% %MSG%
>> "%LOG%" echo [%date% %time%] %MSG%
call :write_status "error" %RC% %PYCOUNT%
call :release_lock
rem REQ-016: retain terminal window on error so user can read the message.
if not defined HP_CI_LANE (
  pause
)
exit /b %RC%
:rotate_log
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"if (Test-Path '%LOG%') { if ((Get-Item '%LOG%').Length -gt 10485760) { Move-Item -Force '%LOG%' '%LOGPREV%' } }"
exit /b 0
:acquire_lock
rem REQ-024: concurrent-instance (double-click race) protection. mkdir is atomic on NTFS,
rem giving a race-free acquire primitive; CMD has no native mutex. Staleness (age-based, not
rem PID-liveness -- PIDs get reused) is the correctness backstop for the crash/kill/power-loss
rem case, since CMD has no finally/trap to guarantee release on every exit path. See
rem docs/agent-lessons-learned.md "Concurrent-instance lock" for the full design rationale.
set "HP_LOCK_DIR=%HP_SCRIPT_ROOT%~bootstrap.lock"
set "HP_LOCK_OWNED="
if defined HP_TEST_DISABLE_LOCK exit /b 0
mkdir "%HP_LOCK_DIR%" 2>nul
if not errorlevel 1 goto :lock_acquired
call :lock_is_stale
if not errorlevel 1 goto :lock_stale_evict
echo ***
echo *** Another instance of this setup appears to be running in this folder already.
echo *** If you are sure that is NOT the case ^(for example, a previous run crashed^),
echo *** delete the "~bootstrap.lock" folder next to this script and run it again.
echo ***
if exist "%HP_LOCK_DIR%\owner.txt" type "%HP_LOCK_DIR%\owner.txt"
call :log "[WARN] REQ-024: setup already running (lock held, not stale); this instance is exiting."
if not defined HP_CI_LANE pause
exit /b 1
:lock_stale_evict
call :log "[INFO] REQ-024: stale lock evicted (older than the staleness threshold); proceeding."
rd /s /q "%HP_LOCK_DIR%" 2>nul
mkdir "%HP_LOCK_DIR%" 2>nul
if errorlevel 1 (
  call :log "[WARN] REQ-024: could not acquire lock after evicting stale lock; continuing without it."
  exit /b 0
)
:lock_acquired
set "HP_LOCK_OWNED=1"
set "HP_LOCK_PID="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$PID" 2^>nul`) do set "HP_LOCK_PID=%%P"
>"%HP_LOCK_DIR%\owner.txt" echo pid=%HP_LOCK_PID%
>>"%HP_LOCK_DIR%\owner.txt" echo started=%date% %time%
exit /b 0
:lock_is_stale
rem exit/b 0 = stale (caller should evict); exit/b 1 = fresh (still held by a live instance).
rem derived requirement: HP_TEST_FORCE_LOCK_STALE gives CI a deterministic way to exercise the
rem eviction path without waiting out the real ~2 hour threshold.
if defined HP_TEST_FORCE_LOCK_STALE exit /b 0
set "HP_LOCK_STALE_RESULT="
for /f "usebackq delims=" %%R in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path '%HP_LOCK_DIR%') { try { $d = (Get-Item '%HP_LOCK_DIR%').LastWriteTime; if (((Get-Date)-$d).TotalHours -ge 2) { 'stale' } else { 'fresh' } } catch { 'stale' } } else { 'stale' }" 2^>nul`) do set "HP_LOCK_STALE_RESULT=%%R"
if "%HP_LOCK_STALE_RESULT%"=="stale" exit /b 0
exit /b 1
:release_lock
if defined HP_LOCK_OWNED (
  rd /s /q "%HP_LOCK_DIR%" 2>nul
  set "HP_LOCK_OWNED="
)
exit /b 0
:try_conda_install
rem derived requirement: AllUsers install can fail when UAC rejects elevation even for admin accounts.
rem JustMe is the non-admin fallback that installs under the user profile instead.
rem Both attempts reuse the already-downloaded installer at %TEMP%\miniconda.exe (no re-download).
rem derived requirement: non-admin machines produce a UAC prompt when AllUsers install is attempted;
rem skip directly to JustMe when the process is not elevated.
rem HP_TEST_NOT_ELEVATED=1 simulates a non-admin environment for CI coverage of this branch.
if "%HP_TEST_NOT_ELEVATED%"=="1" (
  call :log "[INFO] Not elevated; skipping AllUsers Miniconda install."
  goto :tci_justme
)
fsutil dirty query %systemdrive% >nul 2>&1
if errorlevel 1 (
  call :log "[INFO] Not elevated; skipping AllUsers Miniconda install."
  goto :tci_justme
)
if "%HP_TEST_JUSTME_FALLBACK%"=="1" (
  call :log "[INFO] HP_TEST_JUSTME_FALLBACK: skipping AllUsers, forcing JustMe path."
  goto :tci_justme
)
start "" /wait "%TEMP%\miniconda.exe" /InstallationType=AllUsers /AddToPath=0 /RegisterPython=0 /S /D=%MINICONDA_ROOT%
if errorlevel 1 goto :tci_justme
set "HP_CONDA_INSTALL_MODE=AllUsers"
call :log "[INFO] Miniconda installed successfully."
goto :eof
:tci_justme
call :log "[WARN] Miniconda AllUsers install failed; retrying with JustMe."
if exist "%MINICONDA_ROOT%" rd /s /q "%MINICONDA_ROOT%" >nul 2>&1
start "" /wait "%TEMP%\miniconda.exe" /InstallationType=JustMe /AddToPath=0 /RegisterPython=0 /S /D=%MINICONDA_ROOT%
if errorlevel 1 goto :tci_both_failed
set "HP_CONDA_INSTALL_MODE=JustMe"
call :log "[INFO] Miniconda installed (JustMe fallback)."
goto :eof
:tci_both_failed
call :die "[ERROR] Miniconda install failed (both AllUsers and JustMe)."
goto :eof

:conda_base_update
if /i not "%HP_ENV_MODE%"=="conda" goto :eof
if "%HP_TEST_CONDA_UPDATE%"=="1" (
  if exist "%TEMP%\~conda.update.done" (
    call :log "[INFO] Conda base update: skipped (already ran this session)."
    goto :eof
  )
  goto :cbu_run
)
if defined HP_CONDA_JUST_INSTALLED goto :cbu_firstinstall
set "HP_CONDA_UPDATE_RESULT=update"
rem derived requirement: raw .NET File/DateTime APIs, not Get-Content/Get-Date/Test-Path --
rem see docs/agent-lessons-learned.md "Prefer raw .NET types over Utility-module cmdlets" for
rem the confirmed Windows PowerShell 5.1 module-autoload gap this avoids (Get-FileHash failed
rem to autoload in the identical for-/f-backtick-subshell topology; Get-Date/Get-Content share
rem its Microsoft.PowerShell.Utility module, so both are equally exposed, not just the one that
rem was actually caught failing).
for /f "delims=" %%R in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "if ([System.IO.File]::Exists('%MINICONDA_ROOT%\~conda.lastupdate')) { try { $d = [datetime]([System.IO.File]::ReadAllText('%MINICONDA_ROOT%\~conda.lastupdate', [System.Text.Encoding]::ASCII)); if (([datetime]::Now - $d).TotalDays -ge 30) { 'update' } else { 'skip' } } catch { 'update' } } else { 'update' }"') do set "HP_CONDA_UPDATE_RESULT=%%R"
if "%HP_CONDA_UPDATE_RESULT%"=="update" goto :cbu_run
call :log "[INFO] Conda base update: skipped (last update < 30 days ago)."
goto :eof

:cbu_firstinstall
call :log "[INFO] Conda base update: skipped (first install)."
powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.IO.File]::WriteAllText('%MINICONDA_ROOT%\~conda.lastupdate', [datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss'), [System.Text.Encoding]::ASCII)" >nul 2>&1
goto :eof

:cbu_run
call :log "[INFO] Conda base update: running (>=30 days since last update or no record)."
call "%CONDA_BAT%" update -n base --all --override-channels -c conda-forge -y >> "%LOG%" 2>&1
if not errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.IO.File]::WriteAllText('%MINICONDA_ROOT%\~conda.lastupdate', [datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss'), [System.Text.Encoding]::ASCII)" >nul 2>&1
  call :log "[INFO] Conda base update complete."
) else (
  call :log "[WARN] Conda base update failed; continuing."
)
type nul > "%TEMP%\~conda.update.done" 2>nul
goto :eof

:merge_git_config
rem REQ-015: idempotently append standard .gitignore and .gitattributes entries.
rem Uses findstr errorlevel: 0=found (skip), 1=not found, 2=file missing; both 1 and 2 trigger append.
set "HP_GI_SIG=# Automated Python Bootstrapper Standard Ignores"
set "HP_GA_SIG=# Automated Python Bootstrapper Attributes"
findstr /C:"%HP_GI_SIG%" ".gitignore" >nul 2>&1
if not errorlevel 1 goto :mgc_gi_done
call :log "[INFO] REQ-015: Appending standard ignores to .gitignore."
>> ".gitignore" echo.
>> ".gitignore" echo %HP_GI_SIG%
>> ".gitignore" echo .*_env/
>> ".gitignore" echo .venv/
>> ".gitignore" echo .uv/
>> ".gitignore" echo .cache/
>> ".gitignore" echo .conda/
>> ".gitignore" echo dist/
>> ".gitignore" echo build/
>> ".gitignore" echo *~
>> ".gitignore" echo ~*
:mgc_gi_done
findstr /C:"%HP_GA_SIG%" ".gitattributes" >nul 2>&1
if not errorlevel 1 goto :mgc_ga_done
call :log "[INFO] REQ-015: Appending standard attributes to .gitattributes."
>> ".gitattributes" echo.
>> ".gitattributes" echo %HP_GA_SIG%
>> ".gitattributes" echo *.bat eol=crlf
>> ".gitattributes" echo *.cmd eol=crlf
>> ".gitattributes" echo *.exe binary
:mgc_ga_done
set "HP_GI_SIG="
set "HP_GA_SIG="
exit /b 0

:print_postflight_briefing
rem REQ-016: print a scannable summary panel after a successful full EXE build.
echo.
echo ============================================================
if defined HP_EXE_VERIFY_FAILED goto :pfb_caveat
echo  SETUP COMPLETE
echo ============================================================
echo  Your standalone application is ready:
echo    dist\%ENVNAME%.exe
if defined HP_EXE_SKIPPED echo    Note: EXE verification was skipped by request (HP_SKIP_EXE_SMOKERUN).
goto :pfb_runapp
:pfb_caveat
echo  SETUP COMPLETE -- WITH A CAVEAT
echo ============================================================
echo  We packaged your app, but couldn't fully verify it runs as a
echo  standalone program. Your environment and dependencies ARE
echo  installed correctly -- you can always run your app directly:
echo    "%HP_PY%" "%HP_ENTRY%"
:pfb_runapp
echo.
echo  RUNNING YOUR APP
echo    Double-click dist\%ENVNAME%.exe to run it.
echo.
echo    STARTUP MAY BE SLOW: a one-file .exe unpacks itself each time it
echo    starts, so allow 10-15 seconds (longer for big libraries like
echo    numpy/scipy/matplotlib, or when extra packages were bundled to fix
echo    missing imports) before assuming it has hung.
echo.
echo    If the window flashes and closes instantly: that's normal if
echo    your program finished quickly or hit an error before printing
echo    anything. To see what happened, open Command Prompt, cd to
echo    this folder, and run:
echo      dist\%ENVNAME%.exe
echo    This keeps the window open so you can read any messages.
echo.
echo    A progress indicator that updates in place may appear all at
echo    once instead of live when run as the .exe -- that is a stdout
echo    buffering difference between the .exe and the script, not an error.
echo.
echo  KEEP these files with your project:
echo    requirements.txt  -- packages your app depends on
echo    runtime.txt       -- Python version pin
echo.
echo  SAFE TO DELETE to reclaim disk space:
echo    .*_env\ folders   -- environment directories
echo    ~* files          -- tilde-prefix work files (e.g. ~setup.log)
echo    build\            -- PyInstaller build cache
echo ============================================================
echo.
if defined HP_EXE_VERIFY_FAILED goto :pfb_log_caveat
call :log "[INFO] REQ-016: Post-flight briefing printed."
exit /b 0
:pfb_log_caveat
call :log "[WARN] REQ-016: Post-flight briefing printed; EXE unverified, advised direct run."
exit /b 0

:check_net_after_dl_fail
rem REQ-013: called after a primary download fails. Pings 8.8.8.8 to distinguish
rem no-internet (Scenario A) from specific-URL-failed (Scenario B).
rem HP_TEST_OFFLINE=1 simulates ping failure for CI branch coverage.
rem derived requirement: both the ping and curl reachability checks retry once (2 total
rem attempts each) before concluding "no internet" -- a single dropped ICMP echo or a
rem momentarily-contended curl connect on a busy shared CI runner is enough to misclassify a
rem genuinely-online host as offline (root-caused from a real self.ux.connectivity.online CI
rem flake). Mirrors the REQ-022 detect-transient-then-retry-once idiom used elsewhere in this
rem file (:try_conda_create/:conda_bulk_install). The counter-based loop below is safe because
rem these lines are top-level (not nested in a parenthesized block); the "Y" retry branch
rem further down uses literal duplication instead of a counter, since it IS nested in a block
rem and a counter set+read inside the same block would hit CMD's parse-time %VAR% expansion
rem trap (see docs/agent-lessons-learned.md).
if "%HP_TEST_OFFLINE%"=="1" (
  call :log "[TEST] HP_TEST_OFFLINE: simulating ping failure for REQ-013."
  goto :cndf_ping_failed
)
set "HP_CONN_PING_ATTEMPT=0"
:cndf_ping_retry
set /a HP_CONN_PING_ATTEMPT+=1
ping -n 1 8.8.8.8 >nul 2>&1
if not errorlevel 1 (
  call :log "[INFO] REQ-013: Connectivity check: internet reachable. Cascading to fallback."
  exit /b 0
)
if %HP_CONN_PING_ATTEMPT% LSS 2 goto :cndf_ping_retry
rem ICMP may be blocked on corporate networks; try HTTPS as secondary reachability check.
set "HP_CONN_CURL_ATTEMPT=0"
:cndf_curl_retry
set /a HP_CONN_CURL_ATTEMPT+=1
curl -s --connect-timeout 5 --max-time 8 -o nul "https://conda.anaconda.org" >nul 2>&1
if not errorlevel 1 (
  call :log "[INFO] REQ-013: Connectivity check: internet reachable via HTTPS (ICMP blocked). Cascading to fallback."
  exit /b 0
)
if %HP_CONN_CURL_ATTEMPT% LSS 2 goto :cndf_curl_retry
:cndf_ping_failed
call :log "[WARN] REQ-013: Connectivity check: no internet detected (ICMP and HTTPS check failed)."
:cndf_prompt_loop
set "HP_CONN_CHOICE="
set /p HP_CONN_CHOICE="WARNING: No internet connection detected. Remote providers may fail. Retry? (Fix connection then press Y) or proceed offline (N): "
if "%HP_CONN_CHOICE:~0,1%"=="" (
  call :log "[INFO] REQ-013: Connectivity prompt: empty input; defaulting offline."
  set "HP_OFFLINE_MODE=1"
  exit /b 1
)
if /I "%HP_CONN_CHOICE:~0,1%"=="y" (
  if "%HP_TEST_OFFLINE%"=="1" (
    call :log "[TEST] HP_TEST_OFFLINE: Y selected; still simulating offline."
    goto :cndf_ping_failed
  )
  rem derived requirement: 2 literal attempts each (not a counter var) -- this whole branch is
  rem nested inside the "y" parenthesized block, and a counter set+read inside the same block
  rem would be frozen at the block's pre-execution value by CMD's parse-time %VAR% expansion
  rem (see docs/agent-lessons-learned.md); literal duplication has no such variable to freeze.
  ping -n 1 8.8.8.8 >nul 2>&1
  if not errorlevel 1 (
    call :log "[INFO] REQ-013: Connectivity restored after retry."
    exit /b 0
  )
  ping -n 1 8.8.8.8 >nul 2>&1
  if not errorlevel 1 (
    call :log "[INFO] REQ-013: Connectivity restored after retry."
    exit /b 0
  )
  curl -s --connect-timeout 5 --max-time 8 -o nul "https://conda.anaconda.org" >nul 2>&1
  if not errorlevel 1 (
    call :log "[INFO] REQ-013: Connectivity restored after retry (HTTPS, ICMP blocked)."
    exit /b 0
  )
  curl -s --connect-timeout 5 --max-time 8 -o nul "https://conda.anaconda.org" >nul 2>&1
  if not errorlevel 1 (
    call :log "[INFO] REQ-013: Connectivity restored after retry (HTTPS, ICMP blocked)."
    exit /b 0
  )
  call :log "[INFO] REQ-013: Still offline after Y; re-prompting."
  goto :cndf_prompt_loop
)
call :log "[INFO] REQ-013: Connectivity prompt: user chose offline (N)."
set "HP_OFFLINE_MODE=1"
exit /b 1

:system_python_consent_gate
rem REQ-014: halt and require explicit consent before using global system Python.
rem CI-safe (mirrors :cascade_consent_gate): HP_TEST_SYSCON_ANSWER (Y/N) overrides; otherwise
rem HP_CI_LANE auto-declines with no prompt (no set /p hang in CI); interactive users get a
rem y/n prompt. The prompt string is echoed unconditionally so it appears even on the
rem auto-decline path. exit 0 = accepted, exit 1 = declined.
echo.
echo *** WARNING: System Python Execution ***
echo *** Using global system Python may pollute shared packages. ***
echo.
echo Proceed with System Python? (Global pollution risk) [y/n]: y to accept, n to decline.
set "HP_SYSCON_CHOICE="
if defined HP_TEST_SYSCON_ANSWER (
  set "HP_SYSCON_CHOICE=%HP_TEST_SYSCON_ANSWER%"
) else if defined HP_CI_LANE (
  set "HP_SYSCON_CHOICE=n"
) else (
  set /p "HP_SYSCON_CHOICE=Your choice [y/n]: "
)
if "%HP_SYSCON_CHOICE:~0,1%"=="" (
  call :log "[INFO] REQ-014: System Python consent: empty input; declining."
  exit /b 1
)
if /I "%HP_SYSCON_CHOICE:~0,1%"=="y" (
  call :log "[INFO] REQ-014: System Python consent: user accepted."
  exit /b 0
)
call :log "[INFO] REQ-014: System Python consent: user declined."
exit /b 1

:hp_test_conda_fail
call :log "[TEST] HP_TEST_FORCE_CONDA_FAIL: simulating conda env creation failure."
set "HP_ENV_READY="
call :handle_conda_failure "[TEST] conda env create forced to fail."
if defined HP_ENV_READY goto :after_env_mode_selection
call :die "[ERROR] conda env create failed."
goto :after_env_mode_selection
