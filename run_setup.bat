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
if exist "%STATUS_FILE%" del "%STATUS_FILE%"
set "HP_BOOTSTRAP_STATE=ok"
set "HP_ENV_MODE=conda"
set "HP_ENV_READY="
set "HP_SKIP_PIPREQS=%HP_SKIP_PIPREQS%"
set "HP_PY="
set "HP_FIND_ENTRY_SYNTAX_OK="
set "HP_HELPER_SYNTAX_EMITTED="
set "HP_HELPER_CMD_LOGGED="
set "HP_FIND_ENTRY_NAME=~find_entry.py"
set "HP_FIND_ENTRY_ABS="
set "HP_PIPREQS_VERSION=%HP_PIPREQS_VERSION%"
if not defined HP_PIPREQS_VERSION set "HP_PIPREQS_VERSION=0.5.0"
set "HP_MINICONDA_MIN_BYTES=%HP_MINICONDA_MIN_BYTES%"
if not defined HP_MINICONDA_MIN_BYTES set "HP_MINICONDA_MIN_BYTES=5000000"
set "HP_MINICONDA_URL=https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe"

rem derived requirement: CI's conda-only lane must surface conda regressions instead of masking them with opt-in fallbacks.
if "%HP_FORCE_CONDA_ONLY%"=="1" (
  rem derived requirement: conda-full diagnostics must avoid venv/system fallbacks so iterate can flag real conda regressions.
  set "HP_ALLOW_VENV_FALLBACK="
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
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$name = $env:ENVNAME; if (-not $name) { $name = 'env'; } $san = ($name -replace '[^A-Za-z0-9_-]', '_'); if ([string]::IsNullOrWhiteSpace($san) -or ($san.Trim('_').Length -eq 0)) { $san = 'env'; } [Console]::Write($san)"` ) do set "ENVNAME_SANITIZED=%%I"
if defined ENVNAME_SANITIZED set "ENVNAME=%ENVNAME_SANITIZED%"
set "ENVNAME_SANITIZED="
rem G1 guardrail: warn when folder name contained only non-word chars and defaulted to 'env'
if "%ENVNAME%"=="env" if not "%ENVNAME_ORIG%"=="env" (
  call :log "[WARN] Env name could not be derived from '%ENVNAME_ORIG%'; defaulting to 'env'."
)
set "ENVNAME_ORIG="


set "PYCOUNT=0"
for /f "delims=" %%F in ('dir /b /a-d *.py 2^>nul') do call :count_python "%%F"
if "%PYCOUNT%"=="" set "PYCOUNT=0"
call :log "[INFO] Python file count: %PYCOUNT%"
set "HP_CONDA_PROBE_STATUS=skipped"
set "HP_CONDA_PROBE_REASON=not-requested"

rem --- Very top EXE fast path: reuse dist\%ENVNAME%.exe when sources are unchanged ---
set "HP_FASTPATH_USED="
if not "%PYCOUNT%"=="0" (
  call :try_fast_exe
)
if defined HP_FASTPATH_USED (
  rem derived requirement: if the EXE fast path succeeds, treat bootstrap as complete without touching Conda/venv.
  call :log "[INFO] Fast path: skipping PyInstaller rebuild for existing dist\%ENVNAME%.exe"
  if /I "%HP_BOOTSTRAP_STATE%"=="ok" (
    call :write_status ok 0 %PYCOUNT%
  ) else (
    call :write_status "%HP_BOOTSTRAP_STATE%" 0 %PYCOUNT%
  )
  goto :success
)

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

if "%HP_CI_TEST_CONDA_DL%"=="1" (
  if not defined HP_CI_SKIP_ENV (
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
    set "HP_CONDA_PROBE_REASON=skip-env"
  )
) else if defined HP_CI_SKIP_ENV (
  set "HP_CONDA_PROBE_REASON=skip-env"
)
if "%HP_CONDA_PROBE_STATUS%"=="skipped" (
  call :emit_conda_probe_skip
)

if defined HP_CI_SKIP_ENV goto :ci_skip_entry

rem === Miniconda location (non-admin) =========================================
rem G2 guardrail: warn if PUBLIC is absent so path failures are observable
if not defined PUBLIC call :log "[WARN] PUBLIC env var not defined; Miniconda path may be invalid."
set "MC=%PUBLIC%\Documents\Miniconda3"
set "CONDA_MAIN=%MC%\condabin\conda.bat"
set "CONDA_ALT=%MC%\Scripts\conda.bat"
set "MINICONDA_ROOT=%MC%"
set "CONDA_BASE_PY=%MINICONDA_ROOT%\python.exe"

call :select_conda_bat

rem Install Miniconda if conda.bat is missing
if not defined CONDA_BAT (
  echo [INFO] Installing Miniconda into "%MINICONDA_ROOT%"...
  set "HP_CONDA_DL_RC=0"
  curl -L --retry 3 --retry-delay 5 --max-time 120 "%HP_MINICONDA_URL%" -o "%TEMP%\miniconda.exe" >> "%LOG%" 2>&1
  if errorlevel 1 set "HP_CONDA_DL_RC=%errorlevel%"
  if not exist "%TEMP%\miniconda.exe" (
    echo *** curl download failed, trying PowerShell...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri '%HP_MINICONDA_URL%' -OutFile '%TEMP%\miniconda.exe' -UseBasicParsing } catch { exit 1 }" >> "%LOG%" 2>&1
    if errorlevel 1 set "HP_CONDA_DL_RC=%errorlevel%"
  )
  if not exist "%TEMP%\miniconda.exe" set "HP_CONDA_DL_RC=1"
  if exist "%TEMP%\miniconda.exe" (
    REM Attempt AllUsers install with JustMe fallback; see :try_conda_install.
    call :try_conda_install
  )
  if exist "%TEMP%\miniconda.exe" del "%TEMP%\miniconda.exe" >nul 2>&1
  call :select_conda_bat
)

if not defined CONDA_BAT (
  set "HP_ENV_READY="
  call :handle_conda_failure "conda.bat not found after bootstrap."
  if defined HP_ENV_READY goto :after_env_mode_selection
  call :die "[ERROR] conda.bat not found after bootstrap."
)

set "PATH=%MINICONDA_ROOT%\condabin;%MINICONDA_ROOT%\Scripts;%MINICONDA_ROOT%\Library\bin;%MINICONDA_ROOT%;%PATH%"
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

rem === uv acquisition (preferred env+dep installer; falls back to conda) =======
rem derived requirement: uv is gated by HP_FORCE_CONDA_ONLY (same gate used for
rem venv/system fallbacks) so the conda-full CI lane exercises the pure conda path.
rem The binary is cached under ~uv_bin\ (tilde-prefix keeps it gitignored).
set "HP_UV_EXE="
set "HP_UV_BIN=%HP_SCRIPT_ROOT%~uv_bin"
set "HP_UV_ZIP=%TEMP%\~uv_setup.zip"
if "%HP_FORCE_CONDA_ONLY%"=="1" (
  call :log "[INFO] uv: skipped (HP_FORCE_CONDA_ONLY=1)."
  goto :uv_acquire_done
)
if exist "%HP_UV_BIN%\uv.exe" (
  set "HP_UV_EXE=%HP_UV_BIN%\uv.exe"
  call :log "[INFO] uv: cached binary found at ~uv_bin\uv.exe"
  goto :uv_acquire_done
)
call :log "[INFO] uv: downloading to ~uv_bin..."
if not exist "%HP_UV_BIN%" mkdir "%HP_UV_BIN%" >nul 2>&1
curl -L --retry 3 --retry-delay 5 --max-time 120 "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip" -o "%HP_UV_ZIP%" >> "%LOG%" 2>&1
if exist "%HP_UV_ZIP%" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath '%HP_UV_ZIP%' -DestinationPath '%HP_UV_BIN%' -Force } catch { exit 1 }" >> "%LOG%" 2>&1
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

rem === Channel policy (determinism & legal) ===================================
if not exist "%CONDA_BAT%" (
  call :die "[ERROR] Conda not found at: %CONDA_BAT%"
)
call "%CONDA_BAT%" config --name base --add channels conda-forge >> "%LOG%" 2>&1

rem NOTE: every 'conda create' or 'conda install' call below MUST include:
rem       --override-channels -c conda-forge

set "ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%"
call :log "[INFO] Workspace: %CD%"
call :log "[INFO] Env name: %ENVNAME%"
call :log "[INFO] Log: %LOG%"

rem --- Detect required Python version (must run before env-state check) ---
rem derived requirement: PYSPEC must be known before the env-state skip decision
rem so a runtime.txt / pyproject.toml change triggers a full env rebuild.
call :emit_from_base64 "~detect_python.py" HP_DETECT_PY
if errorlevel 1 call :die "[ERROR] Could not write ~detect_python.py"
if exist "%CONDA_BASE_PY%" (
  "%CONDA_BASE_PY%" "~detect_python.py" > "~py_spec.txt" 2>> "%LOG%"
) else (
  call "%CONDA_BAT%" run -n base python "~detect_python.py" > "~py_spec.txt" 2>> "%LOG%"
)
set "PYSPEC="
for /f "usebackq delims=" %%A in ("~py_spec.txt") do set "PYSPEC=%%A"

rem --- Env-state fast path: skip conda create+install if env is still valid ---
rem derived requirement: ~env.state.json records envMode/envName/envPath/pySpec/lockSize
rem from the last successful run. Fast path fires only when PYSPEC, envName, lock size,
rem and python.exe all match the stored snapshot.
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
rem existing conda path unchanged. Python version from PYSPEC is not yet forwarded
rem to uv (version-pinning deferred; uv picks the system default Python).
if not defined HP_UV_EXE goto :try_conda_create
set "HP_UV_ENV_PATH=%HP_SCRIPT_ROOT%.uv_env"
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
call :log "[INFO] uv: creating venv at .uv_env..."
"%HP_UV_EXE%" venv --seed "%HP_UV_ENV_PATH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :uv_venv_fail
if not exist "%HP_UV_ENV_PATH%\Scripts\python.exe" goto :uv_venv_fail
set "HP_ENV_MODE=uv"
set "HP_PY=%HP_UV_ENV_PATH%\Scripts\python.exe"
set "ENV_PATH=%HP_UV_ENV_PATH%"
call :log "[INFO] uv: venv created at .uv_env"
:uv_venv_ready
call :log "[INFO] HP_ENV_MODE=uv"
call :emit_from_base64 "~print_pyver.py" HP_PRINT_PYVER
if not errorlevel 1 (
  "%HP_PY%" "~print_pyver.py" > "~pyver.txt" 2>> "%LOG%"
  for /f "usebackq delims=" %%A in ("~pyver.txt") do set "PYVER=%%A"
  call :write_runtime_txt
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
call :log "[WARN] uv: venv creation failed; falling back to conda create."
set "UV_FALLBACK_REASON=venv_create_failed"
call :log "[WARN] UV_FALLBACK reason=venv_create_failed"
set "HP_UV_EXE="
:try_conda_create
call :log "[INFO] HP_ENV_MODE=conda"
if "%PYSPEC%"=="" (
  call "%CONDA_BAT%" create -y -n "%ENVNAME%" "python<3.13" pip --override-channels -c conda-forge >> "%LOG%" 2>&1
) else (
  call "%CONDA_BAT%" create -y -n "%ENVNAME%" %PYSPEC% pip --override-channels -c conda-forge >> "%LOG%" 2>&1
)
if errorlevel 1 (
  set "HP_ENV_READY="
  call :handle_conda_failure "[ERROR] conda env create failed."
  if defined HP_ENV_READY goto :after_env_mode_selection
  call :die "[ERROR] conda env create failed."
)

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
if not "%PYVER%"=="" ( > "runtime.txt" echo %PYVER% )
if not "%PYVER%"=="" call :log "[INFO] runtime.txt written: %PYVER%"

rem README.md documents the conda-forge policy for this project and why .condarc is required.
rem Emit the .condarc payload from base64 so quoting stays robust on Windows CMD.
call :emit_from_base64 "~condarc" HP_CONDARC
if errorlevel 1 call :die "[ERROR] Could not stage ~condarc"
if not exist "%ENV_PATH%" mkdir "%ENV_PATH%"
copy /y "~condarc" "%ENV_PATH%\.condarc" >> "%LOG%" 2>&1
if errorlevel 1 call :die "[ERROR] Could not write %ENV_PATH%\.condarc"
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
call :emit_from_base64 "~print_pyver.py" HP_PRINT_PYVER
if not errorlevel 1 (
  "%HP_PY%" "~print_pyver.py" > "~pyver.txt" 2>> "%LOG%"
  for /f "usebackq delims=" %%A in ("~pyver.txt") do set "PYVER=%%A"
  if not "%PYVER%"=="" ( > "runtime.txt" echo %PYVER% )
)
if not "%PYVER%"=="" call :log "[INFO] runtime.txt written: %PYVER%"

:after_env_mode_selection
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
set "PEP723_ACTIVE="
set "PEP723_BLOCK_FOUND="
set "PEP723_REQ=~requirements.pep723.txt"
if exist "%PEP723_REQ%" del "%PEP723_REQ%" >nul 2>&1
call :determine_entry "%~1"
if errorlevel 1 call :die "[ERROR] Could not determine entry point"
set "HP_PYPROJ_REQ=~requirements.pyproject.txt"
if exist "%HP_PYPROJ_REQ%" del "%HP_PYPROJ_REQ%" >nul 2>&1
set "HP_PYPROJ_ACTIVE="
if exist "pyproject.toml" (
  call :emit_from_base64 "~pyproj_deps.py" HP_PYPROJ_DEPS
  if not errorlevel 1 (
    "%HP_PY%" "~pyproj_deps.py" "%HP_PYPROJ_REQ%" >nul 2>&1
    if not errorlevel 1 (
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

if not defined HP_SKIP_PIPREQS if not defined PEP723_ACTIVE (
  if "%HP_ENV_MODE%"=="uv" (
    rem derived requirement: uv pip install bypasses python -m pip so pip need not
    rem be a module inside the uv venv; uv's own resolver handles the installation.
    "%HP_UV_EXE%" pip install --python "%HP_PY%" -q pipreqs==%HP_PIPREQS_VERSION% >> "%LOG%" 2>&1
  ) else (
    "%HP_PY%" -m pip install -q --disable-pip-version-check pipreqs==%HP_PIPREQS_VERSION% >> "%LOG%" 2>&1
  )
  if errorlevel 1 call :die "[ERROR] pipreqs install failed."
)

set "HP_PIPREQS_TARGET_WORK=%CD%\requirements.auto.txt"
set "HP_PIPREQS_TARGET=%HP_PIPREQS_TARGET_WORK%"
set "HP_PIPREQS_IGNORE=.git,.github,.venv,venv,env,build,dist,__pycache__,tests"
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
echo *** [WARN] Dependencies were auto-detected (pipreqs)
echo *** [WARN] Auto-detection may be incomplete or incorrect
echo *** [INFO] Consider adding requirements.txt or PEP 723 metadata for reliability
if not "%DEP_SOURCE%"=="requirements.txt" set "DEP_SOURCE=pipreqs"

rem pipreqs flags are locked by CI (pipreqs.flags gate).
rem Rationale: compat mode for deterministic output; force overwrite; write to requirements.auto.txt (separate from committed requirements).
if defined HP_PIPREQS_IGNORE goto :pipreqs_direct_with_ignore
rem pipreqs flags are locked by CI (pipreqs.flags gate).
rem Rationale: compat mode for deterministic output; force overwrite; write to requirements.auto.txt (separate from committed requirements).
  "%HP_PY%" -m pipreqs . --force --mode compat --savepath "%HP_PIPREQS_TARGET%" > "%HP_PIPREQS_DIRECT_LOG%" 2>&1
goto :pipreqs_direct_done
:pipreqs_direct_with_ignore
rem pipreqs flags are locked by CI (pipreqs.flags gate).
rem Rationale: compat mode for deterministic output; force overwrite; write to requirements.auto.txt (separate from committed requirements).
"%HP_PY%" -m pipreqs . --force --mode compat --savepath "%HP_PIPREQS_TARGET%" --ignore "%HP_PIPREQS_IGNORE%" > "%HP_PIPREQS_DIRECT_LOG%" 2>&1
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
"%HP_PY%" -m pipreqs . --force --mode compat --savepath "%HP_PIPREQS_STAGE_TARGET%" > "%HP_PIPREQS_STAGE_LOG%" 2>&1
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
if exist "requirements.txt" if exist "requirements.auto.txt" ( fc "requirements.txt" "requirements.auto.txt" > "~pipreqs.diff.txt" 2>&1 )
rem --- Dep-check fast path: skip conda install when all pipreqs packages are in the lock ---
rem derived requirement: skip the slow conda solver on repeat runs when the
rem environment lock file already contains every package pipreqs detected.
rem goto is used to avoid %errorlevel% parse-time expansion inside parenthesized blocks.
set "HP_DEP_SKIP="
set "HP_DEP_RESULT="
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
if exist "requirements.txt" (
  if exist "~reqs_conda.txt" del "~reqs_conda.txt"
  if "%HP_ENV_MODE%"=="conda" (
    "%CONDA_BASE_PY%" "~prep_requirements.py" "requirements.txt" >nul 2>> "%LOG%"
  ) else (
    "%HP_PY%" "~prep_requirements.py" "requirements.txt" >nul 2>> "%LOG%"
  )
  if "%HP_ENV_MODE%"=="conda" (
    if not defined HP_DEP_SKIP (
      call "%CONDA_BAT%" install -y -n "%ENVNAME%" --file "~reqs_conda.txt" --override-channels -c conda-forge >> "%LOG%" 2>&1
      if errorlevel 1 (
        for /f "usebackq delims=" %%P in ("~reqs_conda.txt") do (
          call "%CONDA_BAT%" install -y -n "%ENVNAME%" --override-channels -c conda-forge %%P >> "%LOG%" 2>&1
        )
      )
    )
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
      )
    )
    call :log "[INFO] UV_USED=1"
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
if defined HP_SYS_PY (
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
)

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
if errorlevel 1 call :die "[ERROR] Could not determine entry point"
if "%HP_ENTRY%"=="" (
  call :log "[INFO] No entry script detected; skipping PyInstaller packaging."
) else (
  call :run_entry_smoke
)

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
exit /b 0
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

:handle_conda_failure
set "HP_FAIL_MSG=%~1"
if not "%HP_FAIL_MSG%"=="" call :log "%HP_FAIL_MSG%"

if "%HP_FORCE_CONDA_ONLY%"=="1" (
  rem derived requirement: the dedicated conda CI slice must surface conda failures instead of hiding behind venv/system fallbacks.
  call :log "[INFO] Conda-only mode: skipping fallback attempts."
  exit /b 0
)

if "%HP_ALLOW_VENV_FALLBACK%"=="1" (
  call :try_venv_fallback
  if not errorlevel 1 (
    set "HP_ENV_READY=1"
    exit /b 0
  )
)
if "%HP_ALLOW_SYSTEM_FALLBACK%"=="1" (
  call :try_system_fallback
  if not errorlevel 1 (
    set "HP_ENV_READY=1"
    exit /b 0
  )
)
exit /b 0

:try_venv_fallback
call :log "[WARN] Attempting venv fallback..."
call :resolve_system_python
if errorlevel 1 (
  call :log "[WARN] venv fallback: system Python not found."
  exit /b 1
)
if exist ".\.venv" rd /s /q ".\.venv" >nul 2>&1
if defined HP_SYS_ARGS (
  "%HP_SYS_CMD%" %HP_SYS_ARGS% -m venv .\.venv >> "%LOG%" 2>&1
) else (
  "%HP_SYS_CMD%" -m venv .\.venv >> "%LOG%" 2>&1
)
if errorlevel 1 (
  call :log "[WARN] venv fallback: python -m venv failed."
  exit /b 1
)
set "HP_PY=%CD%\.venv\Scripts\python.exe"
if not exist "%HP_PY%" (
  call :log "[WARN] venv fallback: interpreter missing after creation."
  exit /b 1
)
set "HP_ENV_MODE=venv"
set "HP_BOOTSTRAP_STATE=venv_env"
set "HP_SKIP_PIPREQS="
call :log "[INFO] venv fallback ready: %HP_PY%"
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
  exit /b 1
)
set "HP_ENV_MODE=system"
set "HP_BOOTSTRAP_STATE=degraded_env"
set "HP_SKIP_PIPREQS=1"
call :log "[INFO] System fallback using %HP_PY%"
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
if not "%~1"=="" if exist "%~1" (
  set "MAIN_FILE=%~1"
  set "HP_ENTRY=%MAIN_FILE%"
  if not defined HP_DRAG_MSG_EMITTED (
    echo *** Using drag-and-drop file: %MAIN_FILE%
    set "HP_DRAG_MSG_EMITTED=1"
  )
  exit /b 0
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
if exist "%HP_ENTRY_CRUMB%" (
  for /f "usebackq delims=" %%M in ("%HP_ENTRY_CRUMB%") do if not defined HP_ENTRY set "HP_ENTRY=%%M"
  del "%HP_ENTRY_CRUMB%" >nul 2>&1
)
if not defined HP_ENTRY set "HP_ENTRY="
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

rem If we also need an absolute path for execution, set HP_ENTRY elsewhere
rem and keep the echo outside any ( ... ) block.
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
call :log "[INFO] Fast path: reusing %HP_FAST_EXE%"
>> "%LOG%" echo Fast path command: "%HP_FAST_EXE%" ^> "~run.out.txt" 2^> "~run.err.txt"
"%HP_FAST_EXE%" 1> "~run.out.txt" 2> "~run.err.txt"
set "HP_SMOKE_RC=%ERRORLEVEL%"
call :log "[INFO] Entry smoke exit=%HP_SMOKE_RC%"
if not "%HP_SMOKE_RC%"=="0" call :die "[ERROR] Fast path EXE execution failed."
exit /b 0
:run_entry_smoke
call :record_chosen_entry "%HP_ENTRY%"
set "HP_FASTPATH_USED="
set "HP_SMOKE_RC="
call :try_fast_exe
if defined HP_FASTPATH_USED goto :run_entry_after_smoke
call :log "[INFO] Running entry script smoke test via %HP_ENV_MODE% interpreter."
rem derived requirement: execute the smoke command inline so cmd, not our logging, owns redirection parsing.
>> "%LOG%" echo Smoke command: "%HP_PY%" "%HP_ENTRY%" ^> "~run.out.txt" 2^> "~run.err.txt"
"%HP_PY%" "%HP_ENTRY%" 1> "~run.out.txt" 2> "~run.err.txt"
set "HP_SMOKE_RC=%ERRORLEVEL%"
call :log "[INFO] Entry smoke exit=%HP_SMOKE_RC%"
if not "%HP_SMOKE_RC%"=="0" call :die "[ERROR] Entry script execution failed."
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
if "%HP_ENV_MODE%"=="system" (
  call :log "[INFO] System fallback: skipping PyInstaller packaging."
) else (
  if defined HP_FASTPATH_USED (
    call :log "[INFO] Fast path: skipping PyInstaller rebuild for existing dist\%ENVNAME%.exe"
  ) else (
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
    "%HP_PY%" -m PyInstaller -y --onefile --clean --log-level WARN --name "%ENVNAME%" "%HP_ENTRY%" >> "%LOG%" 2>&1
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
      call :log "[INFO] PyInstaller flagged missing modules; installing and rebuilding."
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
      "%HP_PY%" -m PyInstaller -y --onefile --clean --log-level WARN --name "%ENVNAME%" "%HP_ENTRY%" >> "%LOG%" 2>&1
      call :log "[INFO] PyInstaller rebuild after missing module install complete."
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
set "HP_FAST_EXE="
set "HP_FAST_EXE_PATH="
set "HP_FASTPATH_USED="
set "HP_FASTPATH_TOKEN="
exit /b 0
:run_exe_smokerun
if not exist "dist\%ENVNAME%.exe" (
  call :log "[WARN] EXE smokerun: dist\%ENVNAME%.exe not found; skipping"
  exit /b 0
)
call :log "[INFO] EXE smokerun: testing dist\%ENVNAME%.exe"
set "HP_EXE_EXIT=-1"
pushd dist
for /f "usebackq delims=" %%X in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$si=New-Object System.Diagnostics.ProcessStartInfo;$si.FileName='%ENVNAME%.exe';$si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$p=[System.Diagnostics.Process]::Start($si);$done=$p.WaitForExit(30000);if(-not $done){try{$p.Kill()}catch{}};if($done){$p.ExitCode}else{-1}"`) do set "HP_EXE_EXIT=%%X"
popd
if not defined HP_EXE_EXIT set "HP_EXE_EXIT=-1"
if "%HP_EXE_EXIT%"=="0" (
  call :log "[INFO] EXE smokerun: exited 0 (ok)"
) else (
  call :log "[WARN] EXE smokerun: exited %HP_EXE_EXIT% (non-zero)"
  call :exe_smokerun_hints
)
if defined HP_NDJSON (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$c=[int]'%HP_EXE_EXIT%';" ^
    "$r=[ordered]@{id='self.exe.smokerun';pass=($c -eq 0);details=[ordered]@{exitCode=$c}}|ConvertTo-Json -Compress -Depth 8;" ^
    "Add-Content -Path '%HP_NDJSON%' -Value $r -Encoding ASCII" >> "%LOG%" 2>&1
)
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
call :log "[HINT][RUNTIME_MISMATCH] EXE behavior differs from Python runtime (possible packaging issue)"
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
set "HP_PYPROJ_DEPS=aW1wb3J0IHN5cywgcGF0aGxpYgoKdHJ5OgogICAgaW1wb3J0IHRvbWxsaWIKZXhjZXB0IEltcG9ydEVycm9yOgogICAgdG9tbGxpYiA9IE5vbmUKCm91dCA9IHN5cy5hcmd2WzFdIGlmIGxlbihzeXMuYXJndikgPiAxIGVsc2UgJ35yZXF1aXJlbWVudHMucHlwcm9qZWN0LnR4dCcKdHJ5OgogICAgdHh0ID0gcGF0aGxpYi5QYXRoKCdweXByb2plY3QudG9tbCcpLnJlYWRfdGV4dChlbmNvZGluZz0ndXRmLTgnLCBlcnJvcnM9J3JlcGxhY2UnKQogICAgZGVwcyA9IE5vbmUKICAgIGlmIHRvbWxsaWI6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBkYXRhID0gdG9tbGxpYi5sb2Fkcyh0eHQpCiAgICAgICAgICAgIGRlcHMgPSBkYXRhLmdldCgncHJvamVjdCcsIHt9KS5nZXQoJ2RlcGVuZGVuY2llcycpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgZGVwcyA9IE5vbmUKICAgIGlmIGRlcHMgaXMgTm9uZToKICAgICAgICBpbXBvcnQgcmUKICAgICAgICBtID0gcmUuc2VhcmNoKHInXlxbcHJvamVjdFxdJywgdHh0LCByZS5NVUxUSUxJTkUpCiAgICAgICAgaWYgbm90IG06CiAgICAgICAgICAgIHN5cy5leGl0KDEpCiAgICAgICAgc2VjID0gdHh0W20uZW5kKCk6XQogICAgICAgIHN0b3AgPSByZS5zZWFyY2gocideXFsnLCBzZWMsIHJlLk1VTFRJTElORSkKICAgICAgICBpZiBzdG9wOgogICAgICAgICAgICBzZWMgPSBzZWNbOnN0b3Auc3RhcnQoKV0KICAgICAgICBkbSA9IHJlLnNlYXJjaChyJ15ccypkZXBlbmRlbmNpZXNccyo9XHMqXFsnLCBzZWMsIHJlLk1VTFRJTElORSkKICAgICAgICBpZiBub3QgZG06CiAgICAgICAgICAgIHN5cy5leGl0KDEpCiAgICAgICAgcmVzdCA9IHNlY1tkbS5lbmQoKTpdCiAgICAgICAgIyBXYWxrIGNoYXItYnktY2hhcjogY29sbGVjdCBvbmx5IHF1b3RlZCBzdHJpbmdzOyBzdG9wIGF0IHVucXVvdGVkIF0KICAgICAgICAjIFRoaXMgcHJlc2VydmVzIGZ1bGwgZGVwIHN0cmluZ3MgaW5jbHVkaW5nIGV4dHJhcyAoW2FsbF0pIGFuZAogICAgICAgICMgbXVsdGktY29uc3RyYWludCBzcGVjaWZpZXJzICg+PTQsPDUpIHdpdGhvdXQgbmFpdmUgY29tbWEvbmV3bGluZSBzcGxpdHMuCiAgICAgICAgZGVwcyA9IFtdCiAgICAgICAgaSA9IDAKICAgICAgICB3aGlsZSBpIDwgbGVuKHJlc3QpOgogICAgICAgICAgICBjID0gcmVzdFtpXQogICAgICAgICAgICBpZiBjIGluICgnIicsICInIik6CiAgICAgICAgICAgICAgICBxID0gYwogICAgICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgICAgICBzdGFydCA9IGkKICAgICAgICAgICAgICAgIHdoaWxlIGkgPCBsZW4ocmVzdCkgYW5kIHJlc3RbaV0gIT0gcToKICAgICAgICAgICAgICAgICAgICBpZiByZXN0W2ldID09ICdcXCc6CiAgICAgICAgICAgICAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICAgICAgZGVwcy5hcHBlbmQocmVzdFtzdGFydDppXSkKICAgICAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICBlbGlmIGMgPT0gJ10nOgogICAgICAgICAgICAgICAgYnJlYWsKICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgIGkgKz0gMQogICAgaWYgbm90IGRlcHM6CiAgICAgICAgc3lzLmV4aXQoMSkKICAgIHBhdGhsaWIuUGF0aChvdXQpLndyaXRlX3RleHQoJ1xuJy5qb2luKGRlcHMpICsgJ1xuJywgZW5jb2Rpbmc9J2FzY2lpJywgZXJyb3JzPSdyZXBsYWNlJykKICAgIHN5cy5leGl0KDApCmV4Y2VwdCBFeGNlcHRpb246CiAgICBzeXMuZXhpdCgxKQo="
set "HP_CONDARC=Y2hhbm5lbHM6CiAgLSBjb25kYS1mb3JnZQpjaGFubmVsX3ByaW9yaXR5OiBzdHJpY3QKc2hvd19jaGFubmVsX3VybHM6IHRydWUK"
set "HP_DETECT_PY=X192ZXJzaW9uX18gPSAiZGV0ZWN0X3B5dGhvbiB2MiAoMjAyNS0wOS0yNCkiCl9fYWxsX18gPSBbInBlcDQ0MF90b19jb25kYSIsICJkZXRlY3RfcmVxdWlyZXNfcHl0aG9uIiwgIm1haW4iXQpPUkRFUiA9IHsiPT0iOiAwLCAiIT0iOiAxLCAiPj0iOiAyLCAiPiI6IDMsICI8PSI6IDQsICI8IjogNX0KCmltcG9ydCBvcwppbXBvcnQgcmUKaW1wb3J0IHN5cwoKIyBIZWxwZXIgaW1wbGVtZW50cyB0aGUgUkVBRE1FIGJvb3RzdHJhcCBjb250cmFjdC4gUEVQIDQ0MCBkZXRhaWxzOgojIGh0dHBzOi8vcGVwcy5weXRob24ub3JnL3BlcC0wNDQwLwoKQ0QgPSBvcy5nZXRjd2QoKQpSVU5USU1FX1BBVEggPSBvcy5wYXRoLmpvaW4oQ0QsICJydW50aW1lLnR4dCIpClBZUFJPSkVDVF9QQVRIID0gb3MucGF0aC5qb2luKENELCAicHlwcm9qZWN0LnRvbWwiKQpQWVBST0pFQ1RfUkUgPSByZS5jb21waWxlKCJyZXF1aXJlcy1weXRob25cXHMqPVxccypbJ1wiXShbXidcIl0rKVsnXCJdIiwgcmUuSUdOT1JFQ0FTRSkKU1BFQ19QQVRURVJOID0gcmUuY29tcGlsZShyJyh+PXw9PXwhPXw+PXw8PXw+fDwpXHMqKFswLTldKyg/OlwuWzAtOV0rKSopJykKCgpkZWYgdmVyc2lvbl9rZXkodGV4dDogc3RyKToKICAgICIiIlJldHVybiBhIHR1cGxlIHVzYWJsZSBmb3IgbnVtZXJpYyBvcmRlcmluZyBvZiBkb3R0ZWQgdmVyc2lvbnMuIiIiCiAgICBwYXJ0cyA9IFtdCiAgICBmb3IgY2h1bmsgaW4gdGV4dC5zcGxpdCgnLicpOgogICAgICAgIHRyeToKICAgICAgICAgICAgcGFydHMuYXBwZW5kKGludChjaHVuaykpCiAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgIHBhcnRzLmFwcGVuZCgwKQogICAgcmV0dXJuIHR1cGxlKHBhcnRzKQoKCmRlZiBidW1wX2Zvcl9jb21wYXRpYmxlKHZlcnNpb246IHN0cikgLT4gc3RyOgogICAgIiIiVHJhbnNsYXRlIHRoZSBQRVAgNDQwIGNvbXBhdGlibGUgcmVsZWFzZSB1cHBlciBib3VuZC4iIiIKICAgIHBpZWNlcyA9IFtpbnQoaXRlbSkgZm9yIGl0ZW0gaW4gdmVyc2lvbi5zcGxpdCgnLicpIGlmIGl0ZW0uaXNkaWdpdCgpXQogICAgaWYgbm90IHBpZWNlczoKICAgICAgICByZXR1cm4gdmVyc2lvbgogICAgaWYgbGVuKHBpZWNlcykgPj0gMzoKICAgICAgICByZXR1cm4gZiJ7cGllY2VzWzBdfS57cGllY2VzWzFdICsgMX0iCiAgICBpZiBsZW4ocGllY2VzKSA9PSAyOgogICAgICAgIHJldHVybiBmIntwaWVjZXNbMF0gKyAxfS4wIgogICAgcmV0dXJuIHN0cihwaWVjZXNbMF0gKyAxKQoKCmRlZiBleHBhbmRfY2xhdXNlKG9wOiBzdHIsIHZlcnNpb246IHN0cik6CiAgICBpZiBvcCA9PSAifj0iOgogICAgICAgIHVwcGVyID0gYnVtcF9mb3JfY29tcGF0aWJsZSh2ZXJzaW9uKQogICAgICAgIHJldHVybiBbKCI+PSIsIHZlcnNpb24pLCAoIjwiLCB1cHBlcildCiAgICByZXR1cm4gWyhvcCwgdmVyc2lvbildCgoKZGVmIHBlcDQ0MF90b19jb25kYShzcGVjOiBzdHIpIC0+IHN0cjoKICAgICIiIlJldHVybiAicHl0aG9uIiBjb25zdHJhaW50cyBleHBhbmRlZCBmcm9tIGEgcmVxdWlyZXMtcHl0aG9uIHNwZWMuIiIiCiAgICBjbGF1c2VzID0gW10KICAgIGZvciByYXcgaW4gc3BlYy5zcGxpdCgnLCcpOgogICAgICAgIHJhdyA9IHJhdy5zdHJpcCgpCiAgICAgICAgaWYgbm90IHJhdzoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBtYXRjaCA9IFNQRUNfUEFUVEVSTi5tYXRjaChyYXcpCiAgICAgICAgaWYgbm90IG1hdGNoOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIG9wLCB2ZXJzaW9uID0gbWF0Y2guZ3JvdXBzKCkKICAgICAgICBjbGF1c2VzLmV4dGVuZChleHBhbmRfY2xhdXNlKG9wLCB2ZXJzaW9uKSkKICAgIGlmIG5vdCBjbGF1c2VzOgogICAgICAgIHJldHVybiAiIgogICAgZGVkdXAgPSB7fQogICAgZm9yIG9wLCB2ZXJzaW9uIGluIGNsYXVzZXM6CiAgICAgICAgZGVkdXBbKG9wLCB2ZXJzaW9uKV0gPSAob3AsIHZlcnNpb24pCiAgICBvcmRlcmVkID0gc29ydGVkKGRlZHVwLnZhbHVlcygpLCBrZXk9bGFtYmRhIGl0ZW06IChPUkRFUi5nZXQoaXRlbVswXSwgOTkpLCB2ZXJzaW9uX2tleShpdGVtWzFdKSkpCiAgICByZXR1cm4gInB5dGhvbiIgKyAiLCIuam9pbihmIntvcH17dmVyc2lvbn0iIGZvciBvcCwgdmVyc2lvbiBpbiBvcmRlcmVkKQoKCmRlZiByZWFkX3J1bnRpbWVfc3BlYygpIC0+IHN0cjoKICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyhSVU5USU1FX1BBVEgpOgogICAgICAgIHJldHVybiAiIgogICAgd2l0aCBvcGVuKFJVTlRJTUVfUEFUSCwgJ3InLCBlbmNvZGluZz0ndXRmLTgnLCBlcnJvcnM9J2lnbm9yZScpIGFzIGhhbmRsZToKICAgICAgICB0ZXh0ID0gaGFuZGxlLnJlYWQoKQogICAgbWF0Y2ggPSByZS5zZWFyY2gocicoPzpweXRob25bLT1dKT9ccyooWzAtOV0rKD86XC5bMC05XSspezAsMn0pJywgdGV4dCkKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByZXR1cm4gIiIKICAgIHBhcnRzID0gbWF0Y2guZ3JvdXAoMSkuc3BsaXQoJy4nKQogICAgbWFqb3JfbWlub3IgPSAnLicuam9pbihwYXJ0c1s6Ml0pCiAgICByZXR1cm4gZidweXRob249e21ham9yX21pbm9yfScKCgpkZWYgcmVhZF9weXByb2plY3Rfc3BlYygpIC0+IHN0cjoKICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyhQWVBST0pFQ1RfUEFUSCk6CiAgICAgICAgcmV0dXJuICIiCiAgICB3aXRoIG9wZW4oUFlQUk9KRUNUX1BBVEgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgdGV4dCA9IGhhbmRsZS5yZWFkKCkKICAgIG1hdGNoID0gUFlQUk9KRUNUX1JFLnNlYXJjaCh0ZXh0KQogICAgaWYgbm90IG1hdGNoOgogICAgICAgIHJldHVybiAiIgogICAgcmV0dXJuIHBlcDQ0MF90b19jb25kYShtYXRjaC5ncm91cCgxKSkKCgpkZWYgZGV0ZWN0X3JlcXVpcmVzX3B5dGhvbigpIC0+IHN0cjoKICAgICIiIlJldHVybiBiZXN0LWVmZm9ydCByZXF1aXJlcy1weXRob24gY29uc3RyYWludCBmb3IgdGhlIGN1cnJlbnQgcHJvamVjdC4iIiIKICAgIHJ1bnRpbWVfc3BlYyA9IHJlYWRfcnVudGltZV9zcGVjKCkKICAgIGlmIHJ1bnRpbWVfc3BlYzoKICAgICAgICByZXR1cm4gcnVudGltZV9zcGVjCiAgICByZXR1cm4gcmVhZF9weXByb2plY3Rfc3BlYygpCgoKZGVmIG1haW4oYXJndj1Ob25lKSAtPiBOb25lOgogICAgIiIiQ0xJIGVudHJ5IHBvaW50IHRoYXQgcHJpbnRzIG5vcm1hbGl6ZWQgcmVxdWlyZXMtcHl0aG9uIGNvbnN0cmFpbnRzLiIiIgogICAgYXJncyA9IGxpc3Qoc3lzLmFyZ3ZbMTpdIGlmIGFyZ3YgaXMgTm9uZSBlbHNlIGFyZ3YpCiAgICBpZiBhcmdzIGFuZCBhcmdzWzBdID09ICItLXNlbGYtdGVzdCI6CiAgICAgICAgZm9yIHNhbXBsZSBpbiAoIn49My4xMCIsICJ+PTMuOC4xIik6CiAgICAgICAgICAgIHN5cy5zdGRvdXQud3JpdGUocGVwNDQwX3RvX2NvbmRhKHNhbXBsZSkgKyAiXG4iKQoKICAgICAgICByZXR1cm4KICAgIGlmIGFyZ3M6CiAgICAgICAgZm9yIGl0ZW0gaW4gYXJnczoKICAgICAgICAgICAgc3lzLnN0ZG91dC53cml0ZShwZXA0NDBfdG9fY29uZGEoaXRlbSkgKyAiXG4iKQoKICAgICAgICByZXR1cm4KICAgIHN5cy5zdGRvdXQud3JpdGUoZGV0ZWN0X3JlcXVpcmVzX3B5dGhvbigpICsgIlxuIikKCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIG1haW4oKQo="
set "HP_PRINT_PYVER=aW1wb3J0IHN5cwoKcHJpbnQoZiJweXRob24te3N5cy52ZXJzaW9uX2luZm9bMF19LntzeXMudmVyc2lvbl9pbmZvWzFdfSIpCg=="
rem HP_FAST_CHECK decoded content:
rem $exe = $args[0]
rem if (-not $exe) { $exe = $env:HP_FAST_EXE }
rem $infraPattern = '(?i)(^|[\/])(\.git|\.github|dist|\.venv|__pycache__|\.conda)([\/]|$)'
rem $sources = Get-ChildItem -Recurse -File -Filter '*.py' | Where-Object { $_.FullName -notmatch $infraPattern -and $_.Name -notlike '~*.py' }
rem if (-not $sources) { exit 1 }
rem $latest = ($sources | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
rem $exeTime = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
rem if ($exeTime -ge $latest) { 'fresh' }
rem If HP_FAST_CHECK changes, update this decoded comment block to match the base64 payload.
set "HP_FAST_CHECK=JGV4ZSA9ICRhcmdzWzBdCmlmICgtbm90ICRleGUpIHsgJGV4ZSA9ICRlbnY6SFBfRkFTVF9FWEUgfQokaW5mcmFQYXR0ZXJuID0gJyg/aSkoXnxbXC9dKShcLmdpdHxcLmdpdGh1YnxkaXN0fFwudmVudnxfX3B5Y2FjaGVfX3xcLmNvbmRhKShbXC9dfCQpJwokc291cmNlcyA9IEdldC1DaGlsZEl0ZW0gLVJlY3Vyc2UgLUZpbGUgLUZpbHRlciAnKi5weScgfCBXaGVyZS1PYmplY3QgeyAkXy5GdWxsTmFtZSAtbm90bWF0Y2ggJGluZnJhUGF0dGVybiAtYW5kICRfLk5hbWUgLW5vdGxpa2UgJ34qLnB5JyB9CmlmICgtbm90ICRzb3VyY2VzKSB7IGV4aXQgMSB9CiRsYXRlc3QgPSAoJHNvdXJjZXMgfCBTb3J0LU9iamVjdCAtUHJvcGVydHkgTGFzdFdyaXRlVGltZVV0YyAtRGVzY2VuZGluZyB8IFNlbGVjdC1PYmplY3QgLUZpcnN0IDEpLkxhc3RXcml0ZVRpbWVVdGMKJGV4ZVRpbWUgPSAoR2V0LUl0ZW0gLUxpdGVyYWxQYXRoICRleGUpLkxhc3RXcml0ZVRpbWVVdGMKaWYgKCRleGVUaW1lIC1nZSAkbGF0ZXN0KSB7ICdmcmVzaCcgfQo="
set "HP_PREP_REQUIREMENTS=IyBoZWxwZXI6IHByZXBfcmVxdWlyZW1lbnRzIHYzICgyMDI2LTA1LTAyKQpfX3ZlcnNpb25fXyA9ICJwcmVwX3JlcXVpcmVtZW50cyB2MyAoMjAyNi0wNS0wMikiCk9QX09SREVSID0gKCI9PSIsICIhPSIsICI+PSIsICI+IiwgIjw9IiwgIjwiKQpPUF9SQU5LID0ge29wOiBpZHggZm9yIGlkeCwgb3AgaW4gZW51bWVyYXRlKE9QX09SREVSKX0KX19hbGxfXyA9IFsiZm9ybWF0X2xpbmUiLCAiY2Fub25pY2FsX29wcyIsICJ0b19jb25kYSIsICJ0b19waXAiLCAibWFpbiJdCgppbXBvcnQgb3MKaW1wb3J0IHJlCmltcG9ydCBzeXMKZnJvbSBjb2xsZWN0aW9ucyBpbXBvcnQgT3JkZXJlZERpY3QKCklOUCA9IHN5cy5hcmd2WzFdIGlmIGxlbihzeXMuYXJndikgPiAxIGVsc2UgInJlcXVpcmVtZW50cy50eHQiCk9VVF9DT05EQSA9ICJ+cmVxc19jb25kYS50eHQiCk9VVF9QSVAgPSAifnJlcXNfcGlwLnR4dCIKU1BFQ19QQVRURVJOID0gcmUuY29tcGlsZShyIih+PXw9PXwhPXw+PXw+fDw9fDwpXHMqKFteXHMsO10rKVxzKiQiKQpOQU1FX1BBVFRFUk4gPSByZS5jb21waWxlKHIiXlxzKihbQS1aYS16MC05Xy4tXSspXHMqKC4qKSQiKQoKCmRlZiBub3JtKHRleHQ6IHN0cikgLT4gc3RyOgogICAgcmV0dXJuIHRleHQuc3RyaXAoKQoKCmRlZiBzcGxpdF9tYXJrZXIodGV4dDogc3RyKSAtPiBzdHI6CiAgICByZXR1cm4gdGV4dC5zcGxpdCgiOyIpWzBdLnN0cmlwKCkKCgpkZWYgc3RyaXBfZXh0cmFzKG5hbWU6IHN0cikgLT4gc3RyOgogICAgcmV0dXJuIHJlLnN1YihyIlxbLio/XF0iLCAiIiwgbmFtZSkKCgpkZWYgX3ZlcnNpb25fa2V5KHRleHQ6IHN0cik6CiAgICBwYXJ0cyA9IFtdCiAgICBmb3IgY2h1bmsgaW4gdGV4dC5zcGxpdCgnLicpOgogICAgICAgIHRyeToKICAgICAgICAgICAgcGFydHMuYXBwZW5kKGludChjaHVuaykpCiAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgIHBhcnRzLmFwcGVuZCgwKQogICAgcmV0dXJuIHR1cGxlKHBhcnRzKQoKCmRlZiBfYnVtcF9jb21wYXRpYmxlKHZhbHVlOiBzdHIpIC0+IHN0cjoKICAgIHBpZWNlcyA9IHZhbHVlLnNwbGl0KCcuJykKICAgIGlmIG5vdCBwaWVjZXMgb3Igbm90IHBpZWNlc1swXS5pc2RpZ2l0KCk6CiAgICAgICAgcmV0dXJuIHZhbHVlCiAgICBtYWpvciA9IGludChwaWVjZXNbMF0pCiAgICBpZiBsZW4ocGllY2VzKSA+PSAzIGFuZCBwaWVjZXNbMV0uaXNkaWdpdCgpOgogICAgICAgIHJldHVybiBmInttYWpvcn0ue2ludChwaWVjZXNbMV0pICsgMX0iCiAgICBpZiBsZW4ocGllY2VzKSA+PSAyOgogICAgICAgIHJldHVybiBmInttYWpvciArIDF9LjAiCiAgICByZXR1cm4gc3RyKG1ham9yICsgMSkKCgpkZWYgX2V4cGFuZF9mcmFnbWVudChmcmFnbWVudDogc3RyKToKICAgIGlmIG5vdCBmcmFnbWVudDoKICAgICAgICByZXR1cm4gW10KICAgIHZhbHVlID0gZnJhZ21lbnQuc3RyaXAoKQogICAgaWYgbm90IHZhbHVlOgogICAgICAgIHJldHVybiBbXQogICAgbWF0Y2ggPSBTUEVDX1BBVFRFUk4uZnVsbG1hdGNoKHZhbHVlKQogICAgaWYgbm90IG1hdGNoOgogICAgICAgIHJldHVybiBbXQogICAgb3AsIHZlciA9IG1hdGNoLmdyb3VwcygpCiAgICB2ZXIgPSB2ZXIuc3RyaXAoKQogICAgaWYgbm90IHZlcjoKICAgICAgICByZXR1cm4gW10KICAgIGlmIG9wID09ICJ+PSI6CiAgICAgICAgdXBwZXIgPSBfYnVtcF9jb21wYXRpYmxlKHZlcikKICAgICAgICByZXR1cm4gW2YiPj17dmVyfSIsIGYiPHt1cHBlcn0iXQogICAgcmV0dXJuIFtmIntvcH17dmVyfSJdCgoKZGVmIGNhbm9uaWNhbF9vcHMoc3BlY3MpIC0+IGxpc3Q6CiAgICAiIiJSZXR1cm4gbm9ybWFsaXplZCBjb25zdHJhaW50IGZyYWdtZW50cyBzb3J0ZWQgZm9yIG91dHB1dC4iIiIKICAgIGJ1Y2tldCA9IE9yZGVyZWREaWN0KCkKICAgIGZvciByYXcgaW4gc3BlY3M6CiAgICAgICAgZm9yIG5vcm1hbGl6ZWQgaW4gX2V4cGFuZF9mcmFnbWVudChyYXcpOgogICAgICAgICAgICBidWNrZXRbbm9ybWFsaXplZF0gPSBOb25lCiAgICBvcmRlcmVkID0gbGlzdChidWNrZXQua2V5cygpKQogICAgb3JkZXJlZC5zb3J0KGtleT1fc3BlY19zb3J0X2tleSkKICAgIHJldHVybiBfZW5mb3JjZV9ib3VuZHNfb3JkZXIob3JkZXJlZCkKCgpkZWYgX3NwZWNfc29ydF9rZXkodmFsdWU6IHN0cik6CiAgICBmb3Igb3AgaW4gT1BfT1JERVI6CiAgICAgICAgaWYgdmFsdWUuc3RhcnRzd2l0aChvcCk6CiAgICAgICAgICAgIHZlciA9IHZhbHVlW2xlbihvcCk6XQogICAgICAgICAgICByZXR1cm4gT1BfUkFOS1tvcF0sIF92ZXJzaW9uX2tleSh2ZXIpLCB2ZXIKICAgIHJldHVybiBsZW4oT1BfT1JERVIpLCBfdmVyc2lvbl9rZXkodmFsdWUpLCB2YWx1ZQoKCmRlZiBfZW5mb3JjZV9ib3VuZHNfb3JkZXIoaXRlbXM6IGxpc3QpIC0+IGxpc3Q6CiAgICBvcHMgPSBsaXN0KGl0ZW1zKQogICAgbG93ZXJfaW5kZXggPSBuZXh0KChpZHggZm9yIGlkeCwgdGV4dCBpbiBlbnVtZXJhdGUob3BzKSBpZiB0ZXh0LnN0YXJ0c3dpdGgoIj49IikpLCBOb25lKQogICAgaWYgbG93ZXJfaW5kZXggaXMgTm9uZToKICAgICAgICByZXR1cm4gb3BzCiAgICBmb3IgdXBwZXJfb3AgaW4gKCI8PSIsICI8Iik6CiAgICAgICAgdXBwZXJfaW5kZXggPSBuZXh0KChpZHggZm9yIGlkeCwgdGV4dCBpbiBlbnVtZXJhdGUob3BzKSBpZiB0ZXh0LnN0YXJ0c3dpdGgodXBwZXJfb3ApKSwgTm9uZSkKICAgICAgICBpZiB1cHBlcl9pbmRleCBpcyBub3QgTm9uZSBhbmQgdXBwZXJfaW5kZXggPCBsb3dlcl9pbmRleDoKICAgICAgICAgICAgdmFsdWUgPSBvcHMucG9wKGxvd2VyX2luZGV4KQogICAgICAgICAgICBvcHMuaW5zZXJ0KHVwcGVyX2luZGV4LCB2YWx1ZSkKICAgICAgICAgICAgbG93ZXJfaW5kZXggPSB1cHBlcl9pbmRleAogICAgcmV0dXJuIG9wcwoKCmRlZiBmb3JtYXRfbGluZShuYW1lOiBzdHIsIHNwZWNzKSAtPiBsaXN0OgogICAgIiIiUmV0dXJuIFsnbmFtZSA+PS4uLiddIHdpdGggY2Fub25pY2FsaXplZCBzcGVjaWZpZXJzLiIiIgogICAgb3BzID0gY2Fub25pY2FsX29wcyhzcGVjcykKICAgIHJldHVybiBbZiJ7bmFtZX0gIiArICIsIi5qb2luKG9wcyldIGlmIG9wcyBlbHNlIFtuYW1lXQoKCmRlZiBub3JtYWxpemVfc3BlY2lmaWVycyhyZXN0OiBzdHIpOgogICAgaXRlbXMgPSBbXQogICAgZm9yIGNodW5rIGluIHJlc3Quc3BsaXQoJywnKToKICAgICAgICBjaHVuayA9IGNodW5rLnN0cmlwKCkKICAgICAgICBpZiBjaHVuazoKICAgICAgICAgICAgaXRlbXMuZXh0ZW5kKF9leHBhbmRfZnJhZ21lbnQoY2h1bmspKQogICAgcmV0dXJuIGNhbm9uaWNhbF9vcHMoaXRlbXMpCgoKZGVmIHRvX2NvbmRhKGxpbmU6IHN0cik6CiAgICAiIiJSZXR1cm4gY29uZGEtc3R5bGUgcmVxdWlyZW1lbnQgbGluZXMgZGVyaXZlZCBmcm9tIGlucHV0LiIiIgogICAgc2VjdGlvbiA9IHNwbGl0X21hcmtlcihsaW5lKQogICAgaWYgbm90IHNlY3Rpb24gb3Igc2VjdGlvbi5zdGFydHN3aXRoKCcjJyk6CiAgICAgICAgcmV0dXJuIFtdCiAgICBtYXRjaCA9IE5BTUVfUEFUVEVSTi5tYXRjaChzZWN0aW9uKQogICAgaWYgbm90IG1hdGNoOgogICAgICAgIHJldHVybiBbXQogICAgbmFtZSwgcmVzdCA9IG1hdGNoLmdyb3VwcygpCiAgICBuYW1lID0gc3RyaXBfZXh0cmFzKG5hbWUpCiAgICByZXN0ID0gcmUuc3ViKHIiXFsuKj9cXSIsICIiLCByZXN0KQogICAgc3BlY3MgPSBbY2h1bmsuc3RyaXAoKSBmb3IgY2h1bmsgaW4gcmVzdC5zcGxpdCgnLCcpIGlmIGNodW5rLnN0cmlwKCldCiAgICByZXR1cm4gZm9ybWF0X2xpbmUobmFtZSwgc3BlY3MpCgoKZGVmIHRvX3BpcChsaW5lOiBzdHIpOgogICAgIiIiUmV0dXJuIHJhdyBwaXAgcmVxdWlyZW1lbnQgc3RyaW5nIG9yIE5vbmUgd2hlbiBza2lwcGVkLiIiIgogICAgc2VjdGlvbiA9IHNwbGl0X21hcmtlcihsaW5lKQogICAgaWYgbm90IHNlY3Rpb24gb3Igc2VjdGlvbi5zdGFydHN3aXRoKCcjJyk6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIG1hdGNoID0gTkFNRV9QQVRURVJOLm1hdGNoKHNlY3Rpb24pCiAgICBpZiBub3QgbWF0Y2g6CiAgICAgICAgcmV0dXJuIHNlY3Rpb24uc3RyaXAoKQogICAgbmFtZSwgcmVzdCA9IG1hdGNoLmdyb3VwcygpCiAgICBuYW1lID0gc3RyaXBfZXh0cmFzKG5hbWUpCiAgICByZXR1cm4gKG5hbWUgKyByZXN0KS5zdHJpcCgpCgoKZGVmIG1haW4oKToKICAgICIiIkNMSSBlbnRyeSBwb2ludCB3cml0aW5nIGNvbmRhL3BpcCByZXF1aXJlbWVudCBmaWxlcy4iIiIKICAgIGhhdmVfZmlsZSA9IG9zLnBhdGguZXhpc3RzKElOUCkgYW5kIG9zLnBhdGguZ2V0c2l6ZShJTlApID4gMAogICAgbGluZXMgPSBbXQogICAgaWYgaGF2ZV9maWxlOgogICAgICAgIHdpdGggb3BlbihJTlAsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgIGxpbmVzID0gW25vcm0oaXRlbSkgZm9yIGl0ZW0gaW4gaGFuZGxlIGlmIG5vcm0oaXRlbSldCiAgICBjb25kYV9zcGVjcyA9IFtdCiAgICBwaXBfc3BlY3MgPSBbXQogICAgZm9yIGxpbmUgaW4gbGluZXM6CiAgICAgICAgY29uZGFfc3BlY3MuZXh0ZW5kKHRvX2NvbmRhKGxpbmUpKQogICAgICAgIHBpcF9lbnRyeSA9IHRvX3BpcChsaW5lKQogICAgICAgIGlmIHBpcF9lbnRyeToKICAgICAgICAgICAgcGlwX3NwZWNzLmFwcGVuZChwaXBfZW50cnkpCiAgICBuYW1lc19sb3dlciA9IFtyZS5zcGxpdChyIls8Pj0hfixcc10iLCB2YWx1ZSwgbWF4c3BsaXQ9MSlbMF0uc3RyaXAoKS5sb3dlcigpIGZvciB2YWx1ZSBpbiBwaXBfc3BlY3NdCiAgICBpZiBvcy5lbnZpcm9uLmdldCgnSFBfRElTQUJMRV9IRVVSSVNUSUNTJykgIT0gJzEnOgogICAgICAgICMgUmVxIDUuMSAtIHBhbmRhcyBuZWVkcyBFeGNlbCBiYWNrZW5kcwogICAgICAgIGlmICdwYW5kYXMnIGluIG5hbWVzX2xvd2VyIGFuZCAnb3BlbnB5eGwnIG5vdCBpbiBuYW1lc19sb3dlcjoKICAgICAgICAgICAgcGlwX3NwZWNzLmFwcGVuZCgnb3BlbnB5eGwnKQogICAgICAgICAgICBjb25kYV9zcGVjcy5leHRlbmQoZm9ybWF0X2xpbmUoJ29wZW5weXhsJywgW10pKQogICAgICAgIGlmICdwYW5kYXMnIGluIG5hbWVzX2xvd2VyIGFuZCAneGxzeHdyaXRlcicgbm90IGluIG5hbWVzX2xvd2VyOgogICAgICAgICAgICBwaXBfc3BlY3MuYXBwZW5kKCd4bHN4d3JpdGVyJykKICAgICAgICAgICAgY29uZGFfc3BlY3MuZXh0ZW5kKGZvcm1hdF9saW5lKCd4bHN4d3JpdGVyJywgW10pKQogICAgICAgICMgUmVxIDUuMiAtIHJlcXVlc3RzIG5lZWRzIGNlcnRpZmkgZm9yIFRMUwogICAgICAgIGlmICdyZXF1ZXN0cycgaW4gbmFtZXNfbG93ZXIgYW5kICdjZXJ0aWZpJyBub3QgaW4gbmFtZXNfbG93ZXI6CiAgICAgICAgICAgIHBpcF9zcGVjcy5hcHBlbmQoJ2NlcnRpZmknKQogICAgICAgICAgICBjb25kYV9zcGVjcy5leHRlbmQoZm9ybWF0X2xpbmUoJ2NlcnRpZmknLCBbXSkpCiAgICAgICAgIyBSZXEgNS4zIC0gc3FsYWxjaGVteSBuZWVkcyBweW15c3FsIGZvciBNeVNRTCBkcml2ZXIKICAgICAgICBpZiAnc3FsYWxjaGVteScgaW4gbmFtZXNfbG93ZXIgYW5kICdweW15c3FsJyBub3QgaW4gbmFtZXNfbG93ZXI6CiAgICAgICAgICAgIHBpcF9zcGVjcy5hcHBlbmQoJ3B5bXlzcWwnKQogICAgICAgICAgICBjb25kYV9zcGVjcy5leHRlbmQoZm9ybWF0X2xpbmUoJ3B5bXlzcWwnLCBbXSkpCiAgICAgICAgIyBSZXEgNS40IC0gbWF0cGxvdGxpYiBuZWVkcyB0ayBmb3IgR1VJIGJhY2tlbmQKICAgICAgICBpZiAnbWF0cGxvdGxpYicgaW4gbmFtZXNfbG93ZXIgYW5kICd0aycgbm90IGluIG5hbWVzX2xvd2VyOgogICAgICAgICAgICBwaXBfc3BlY3MuYXBwZW5kKCd0aycpCiAgICAgICAgICAgIGNvbmRhX3NwZWNzLmV4dGVuZChmb3JtYXRfbGluZSgndGsnLCBbXSkpCiAgICAgICAgIyBSZXEgNS41IC0gY3J5cHRvIGxpYnMgbmVlZCBjZmZpIGZvciBDIGJpbmRpbmdzCiAgICAgICAgaWYgKCdjcnlwdG9ncmFwaHknIGluIG5hbWVzX2xvd2VyIG9yICdweWNyeXB0b2RvbWUnIGluIG5hbWVzX2xvd2VyKSBhbmQgJ2NmZmknIG5vdCBpbiBuYW1lc19sb3dlcjoKICAgICAgICAgICAgcGlwX3NwZWNzLmFwcGVuZCgnY2ZmaScpCiAgICAgICAgICAgIGNvbmRhX3NwZWNzLmV4dGVuZChmb3JtYXRfbGluZSgnY2ZmaScsIFtdKSkKICAgIHdpdGggb3BlbihPVVRfQ09OREEsICd3JywgZW5jb2Rpbmc9J2FzY2lpJykgYXMgaGFuZGxlOgogICAgICAgIGZvciBpdGVtIGluIGNvbmRhX3NwZWNzOgogICAgICAgICAgICBpZiBpdGVtOgogICAgICAgICAgICAgICAgaGFuZGxlLndyaXRlKGl0ZW0gKyAnXG4nKQogICAgd2l0aCBvcGVuKE9VVF9QSVAsICd3JywgZW5jb2Rpbmc9J2FzY2lpJykgYXMgaGFuZGxlOgogICAgICAgIGZvciBpdGVtIGluIHBpcF9zcGVjczoKICAgICAgICAgICAgaWYgaXRlbToKICAgICAgICAgICAgICAgIGhhbmRsZS53cml0ZShpdGVtICsgJ1xuJykKICAgIHN5cy5zdGRvdXQud3JpdGUoJ09LXG4nKQoKCmlmIF9fbmFtZV9fID09ICdfX21haW5fXyc6CiAgICBtYWluKCkKICAgIGlmIGxlbihzeXMuYXJndikgPT0gMToKICAgICAgICBkZW1vID0gewogICAgICAgICAgICAncHl0aG9uJzogWyc+PTMuOCcsICc8NC4wJ10sCiAgICAgICAgICAgICdyZXF1ZXN0cyc6IFsnPj0yLjMxLjAnLCAnPDMnXSwKICAgICAgICAgICAgJ3B5ZGFudGljJzogWycgPj0yICcsICcgPDMnXSwKICAgICAgICB9CiAgICAgICAgZm9yIG5hbWUsIHNwZWNzIGluIGRlbW8uaXRlbXMoKToKICAgICAgICAgICAgZm9yIGxpbmUgaW4gZm9ybWF0X2xpbmUobmFtZSwgc3BlY3MpOgogICAgICAgICAgICAgICAgcHJpbnQobGluZSkK"
set "HP_DETECT_VISA=aW1wb3J0IG9zLCByZSwgc3lzCgpST09UID0gb3MuZ2V0Y3dkKCkKUEFUVEVSTlMgPSBbCiAgICByIig/bSleXHMqKD86ZnJvbVxzK3B5dmlzfGltcG9ydFxzK3B5dmlzKSIsCiAgICByIig/bSleXHMqaW1wb3J0XHMrdmlzIiwKXQoKZGVmIG5lZWRzX3Zpc2EoKToKICAgIGZvciBjdXJyZW50LCBkaXJzLCBmaWxlcyBpbiBvcy53YWxrKFJPT1QpOgogICAgICAgIGRpcnNbOl0gPSBbaXRlbSBmb3IgaXRlbSBpbiBkaXJzIGlmIG5vdCBpdGVtLnN0YXJ0c3dpdGgoKCd+JywgJy4nKSldCiAgICAgICAgZm9yIG5hbWUgaW4gZmlsZXM6CiAgICAgICAgICAgIGlmIG5vdCBuYW1lLmVuZHN3aXRoKCcucHknKSBvciBuYW1lLnN0YXJ0c3dpdGgoJ34nKToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIHBhdGggPSBvcy5wYXRoLmpvaW4oY3VycmVudCwgbmFtZSkKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgd2l0aCBvcGVuKHBhdGgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgICAgICAgICAgdGV4dCA9IGhhbmRsZS5yZWFkKCkKICAgICAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBmb3IgcGF0dGVybiBpbiBQQVRURVJOUzoKICAgICAgICAgICAgICAgIGlmIHJlLnNlYXJjaChwYXR0ZXJuLCB0ZXh0KToKICAgICAgICAgICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgcmV0dXJuIEZhbHNlCgpkZWYgbWFpbigpOgogICAgc3lzLnN0ZG91dC53cml0ZSgnMScgaWYgbmVlZHNfdmlzYSgpIGVsc2UgJzAnKQoKaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJzoKICAgIG1haW4oKQo="
rem ~find_entry.py emits a normalized crumb, logs it for tests, and skip mode reads its stdout
set "HP_FIND_ENTRY=aW1wb3J0IG9zCmltcG9ydCBzeXMKClBSRUZFUlJFRCA9ICgibWFpbi5weSIsICJhcHAucHkiLCAicnVuLnB5IikKCmRlZiBpc19weShuYW1lOiBzdHIpIC0+IGJvb2w6CiAgICBsb3dlciA9IG5hbWUubG93ZXIoKQogICAgcmV0dXJuIGxvd2VyLmVuZHN3aXRoKCIucHkiKSBhbmQgbm90IGxvd2VyLnN0YXJ0c3dpdGgoIn4iKSBhbmQgb3MucGF0aC5pc2ZpbGUobmFtZSkKCmRlZiBoYXNfbWFpbihwYXRoOiBzdHIpIC0+IGJvb2w6CiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKHBhdGgsICJyIiwgZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJpZ25vcmUiKSBhcyBoYW5kbGU6CiAgICAgICAgICAgIHRleHQgPSBoYW5kbGUucmVhZCgpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0dXJuICJfX21haW5fXyIgaW4gdGV4dAoKZGVmIGVtaXQocGF0aDogc3RyKSAtPiBOb25lOgogICAgY3J1bWIgPSBvcy5wYXRoLm5vcm1wYXRoKHBhdGgpCiAgICBwcmludChjcnVtYikKCmZpbGVzID0gW25hbWUgZm9yIG5hbWUgaW4gb3MubGlzdGRpcigiLiIpIGlmIGlzX3B5KG5hbWUpXQoKZm9yIGNhbmRpZGF0ZSBpbiBQUkVGRVJSRUQ6CiAgICBpZiBjYW5kaWRhdGUgaW4gZmlsZXM6CiAgICAgICAgZW1pdChjYW5kaWRhdGUpCiAgICAgICAgc3lzLmV4aXQoMCkKCmlmIGxlbihmaWxlcykgPT0gMToKICAgIGVtaXQoZmlsZXNbMF0pCiAgICBzeXMuZXhpdCgwKQoKY2FuZGlkYXRlcyA9IFtuYW1lIGZvciBuYW1lIGluIGZpbGVzIGlmIGhhc19tYWluKG5hbWUpXQppZiBsZW4oY2FuZGlkYXRlcykgPT0gMToKICAgIGVtaXQoY2FuZGlkYXRlc1swXSkKICAgIHN5cy5leGl0KDApCg=="
rem ~env_state.py records envMode/envName/envPath/lockSize after a successful
rem conda bootstrap; prints 'skip' on --check when the env is still valid,
rem 'run' otherwise. Writes ~env.state.json on --write.
set "HP_ENV_STATE=IiIiZW52X3N0YXRlIHYzICgyMDI2LTAzLTI3KQpXcml0ZXMgYW5kIHZhbGlkYXRlcyB+ZW52LnN0YXRlLmpzb24gZm9yIHRoZSBydW5fc2V0dXAuYmF0IGJvb3RzdHJhcCBmYXN0IHBhdGguClVzYWdlOgogIHB5dGhvbiB+ZW52X3N0YXRlLnB5IC0tY2hlY2sgIDogcHJpbnQgJ3NraXAnIGlmIHRoZSBzYXZlZCBlbnYgc3RhdGUgaXMgc3RpbGwgdmFsaWQKICBweXRob24gfmVudl9zdGF0ZS5weSAtLXdyaXRlICA6IHdyaXRlIGN1cnJlbnQgZW52IHN0YXRlIHRvIH5lbnYuc3RhdGUuanNvbgpOb3RlOiBweVNwZWMgaXMgaW50ZW50aW9uYWxseSBvbWl0dGVkIGZyb20gdGhlIHN0YXRlIGNoZWNrIGJlY2F1c2UgcnVuX3NldHVwLmJhdAp3cml0ZXMgcnVudGltZS50eHQgKmR1cmluZyogdGhlIGZpcnN0IGJvb3RzdHJhcCwgc28gdGhlIGRldGVjdGVkIHNwZWMgb24gcnVuIDIKZGlmZmVycyBmcm9tIHRoZSBlbXB0eSBzcGVjIG9uIHJ1biAxLCBjYXVzaW5nIGEgc3B1cmlvdXMgY2FjaGUgbWlzcy4KIiIiCl9fdmVyc2lvbl9fID0gImVudl9zdGF0ZSB2MyAoMjAyNi0wMy0yNykiCl9fYWxsX18gPSBbInJlYWRfc3RhdGUiLCAid3JpdGVfc3RhdGUiLCAiY2hlY2tfc3RhdGUiXQoKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzeXMKClNUQVRFX0ZJTEUgPSAifmVudi5zdGF0ZS5qc29uIgpMT0NLX0ZJTEUgPSAifmVudmlyb25tZW50LmxvY2sudHh0IgoKCmRlZiBfbG9ja19zaXplKCk6CiAgICB0cnk6CiAgICAgICAgcmV0dXJuIG9zLnBhdGguZ2V0c2l6ZShMT0NLX0ZJTEUpCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICByZXR1cm4gMAoKCmRlZiByZWFkX3N0YXRlKCk6CiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKFNUQVRFX0ZJTEUsICJyIiwgZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJpZ25vcmUiKSBhcyBmaDoKICAgICAgICAgICAgcmV0dXJuIGpzb24ubG9hZChmaCkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJuIHt9CgoKZGVmIHdyaXRlX3N0YXRlKCk6CiAgICBlbnZfbW9kZSA9IG9zLmVudmlyb24uZ2V0KCJIUF9FTlZfTU9ERSIsICIiKQogICAgZW52X25hbWUgPSBvcy5lbnZpcm9uLmdldCgiRU5WTkFNRSIsICIiKQogICAgZW52X3BhdGggPSBvcy5lbnZpcm9uLmdldCgiRU5WX1BBVEgiLCAiIikKICAgIGxvY2tfc2l6ZSA9IF9sb2NrX3NpemUoKQogICAgc3RhdGUgPSB7CiAgICAgICAgImVudk1vZGUiOiBlbnZfbW9kZSwKICAgICAgICAiZW52TmFtZSI6IGVudl9uYW1lLAogICAgICAgICJlbnZQYXRoIjogZW52X3BhdGgsCiAgICAgICAgImxvY2tTaXplIjogbG9ja19zaXplLAogICAgfQogICAgdHJ5OgogICAgICAgIHdpdGggb3BlbihTVEFURV9GSUxFLCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpIGFzIGZoOgogICAgICAgICAgICBqc29uLmR1bXAoc3RhdGUsIGZoKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgc3lzLmV4aXQoMSkKCgpkZWYgY2hlY2tfc3RhdGUoKToKICAgIHN0YXRlID0gcmVhZF9zdGF0ZSgpCiAgICBpZiBub3Qgc3RhdGU6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgICAgIHJldHVybgogICAgZW52X25hbWUgPSBvcy5lbnZpcm9uLmdldCgiRU5WTkFNRSIsICIiKQogICAgaWYgbm90IGVudl9uYW1lIG9yIHN0YXRlLmdldCgiZW52TmFtZSIpICE9IGVudl9uYW1lOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoInJ1blxuIikKICAgICAgICByZXR1cm4KICAgIGlmIHN0YXRlLmdldCgiZW52TW9kZSIpICE9ICJjb25kYSI6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgICAgIHJldHVybgogICAgZW52X3BhdGggPSBzdGF0ZS5nZXQoImVudlBhdGgiLCAiIikKICAgIGlmIG5vdCBlbnZfcGF0aDoKICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJydW5cbiIpCiAgICAgICAgcmV0dXJuCiAgICBweV9leGUgPSBvcy5wYXRoLmpvaW4oZW52X3BhdGgsICJweXRob24uZXhlIikKICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyhweV9leGUpOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoInJ1blxuIikKICAgICAgICByZXR1cm4KICAgIGxvY2tfc2l6ZSA9IF9sb2NrX3NpemUoKQogICAgaWYgbG9ja19zaXplID09IDAgb3IgbG9ja19zaXplICE9IHN0YXRlLmdldCgibG9ja1NpemUiLCAtMSk6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgICAgIHJldHVybgogICAgc3lzLnN0ZG91dC53cml0ZSgic2tpcFxuIikKCgpkZWYgbWFpbigpOgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgIi0td3JpdGUiIGluIGFyZ3M6CiAgICAgICAgd3JpdGVfc3RhdGUoKQogICAgZWxpZiAiLS1jaGVjayIgaW4gYXJnczoKICAgICAgICBjaGVja19zdGF0ZSgpCiAgICBlbHNlOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoInJ1blxuIikKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg=="
rem ~parse_warn.py reads PyInstaller warn file, extracts missing module names,
rem applies import-to-conda-package translations, and prints one package per line.
set "HP_PARSE_WARN=IiIicGFyc2Vfd2FybiB2MiAoMjAyNi0wMy0yOSkKUmVhZHMgUHlJbnN0YWxsZXIgd2FybiBmaWxlLCBleHRyYWN0cyBtaXNzaW5nIG1vZHVsZSBuYW1lcywgYXBwbGllcyB0cmFuc2xhdGlvbnMuClVzYWdlOiBweXRob24gfnBhcnNlX3dhcm4ucHkgPGVudm5hbWU+ClByaW50cyBvbmUgY29uZGEgcGFja2FnZSBuYW1lIHBlciBsaW5lIHRvIHN0ZG91dC4KU2tpcHMgaW50ZXJuYWwgbW9kdWxlcyAoc3RhcnRpbmcgd2l0aCBfKSBhbmQga25vd24tc2FmZS91bml4LW9ubHkgbmFtZXMuClN1cHBvcnRzIFB5SW5zdGFsbGVyIDUueCBmb3JtYXQgKFc6IG5vIG1vZHVsZSBuYW1lZCAnZm9vJykgYW5kClB5SW5zdGFsbGVyIDYueCBmb3JtYXQgKG1pc3NpbmcgbW9kdWxlIG5hbWVkIGZvbyAtIGltcG9ydGVkIGJ5IC4uLiAodG9wLWxldmVsKSkuCiIiIgpfX3ZlcnNpb25fXyA9ICJwYXJzZV93YXJuIHYyICgyMDI2LTAzLTI5KSIKX19hbGxfXyA9IFsibWFpbiIsICJwYXJzZV93YXJuX2ZpbGUiLCAiVFJBTlNMQVRJT05TIiwgIlNLSVAiXQoKaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc3lzCgpUUkFOU0xBVElPTlMgPSB7CiAgICAiY3YyIjogIm9wZW5jdiIsCiAgICAiUElMIjogInBpbGxvdyIsCiAgICAiSW1hZ2UiOiAicGlsbG93IiwKICAgICJza2xlYXJuIjogInNjaWtpdC1sZWFybiIsCiAgICAiYnM0IjogImJlYXV0aWZ1bHNvdXA0IiwKICAgICJzZXJpYWwiOiAicHlzZXJpYWwiLAogICAgInlhbWwiOiAicHl5YW1sIiwKICAgICJnaXQiOiAiZ2l0cHl0aG9uIiwKICAgICJ3eCI6ICJ3eHB5dGhvbiIsCiAgICAiZGF0ZXV0aWwiOiAicHl0aG9uLWRhdGV1dGlsIiwKICAgICJkb3RlbnYiOiAicHl0aG9uLWRvdGVudiIsCiAgICAiQ3J5cHRvIjogInB5Y3J5cHRvZG9tZSIsCiAgICAiT3BlblNTTCI6ICJweW9wZW5zc2wiLAogICAgImp3dCI6ICJweWp3dCIsCiAgICAidXNiIjogInB5dXNiIiwKICAgICJhdHRyIjogImF0dHJzIiwKICAgICJ3aW4zMmFwaSI6ICJweXdpbjMyIiwKICAgICJ3aW4zMmNvbiI6ICJweXdpbjMyIiwKICAgICJmaXR6IjogInB5bXVwZGYiLAogICAgImRvY3giOiAicHl0aG9uLWRvY3giLAp9CgpTS0lQID0gZnJvemVuc2V0KFsKICAgICJwa2dfcmVzb3VyY2VzIiwKICAgICJkaXN0dXRpbHMiLAogICAgInNldHVwdG9vbHMiLAogICAgImltcG9ydGxpYiIsCiAgICAiaW1wb3J0bGliLm1ldGFkYXRhIiwKICAgICJpbXBvcnRsaWIucmVzb3VyY2VzIiwKICAgICJpbXBvcnRsaWIuYWJjIiwKICAgICMgVW5peC1vbmx5IHBsYXRmb3JtIG1vZHVsZXMgYWJzZW50IG9uIFdpbmRvd3M7IHRoZXNlIGFwcGVhciBhcyBvcHRpb25hbC9kZWxheWVkCiAgICAjIHN0ZGxpYiBpbXBvcnRzIGluIHRoZSB3YXJuIGZpbGUgYW5kIGFyZSBzYWZlIHRvIGlnbm9yZS4KICAgICJncnAiLAogICAgInB3ZCIsCiAgICAicG9zaXgiLAogICAgInJlc291cmNlIiwKICAgICJmY250bCIsCiAgICAicmVhZGxpbmUiLAogICAgInRlcm1pb3MiLAogICAgInR0eSIsCiAgICAicHR5IiwKICAgICJjcnlwdCIsCiAgICAic3B3ZCIsCiAgICAibmlzIiwKICAgICJzeXNsb2ciLAogICAgIm9zc2F1ZGlvZGV2IiwKXSkKCgpkZWYgcGFyc2Vfd2Fybl9maWxlKHdhcm5fcGF0aCk6CiAgICAiIiJQYXJzZSBhIFB5SW5zdGFsbGVyIHdhcm4gZmlsZTsgcmV0dXJuIGxpc3Qgb2YgY29uZGEgcGFja2FnZSBuYW1lcyAoZGVkdXBsaWNhdGVkLCBvcmRlcmVkKS4KCiAgICBSZXR1cm5zIGFuIGVtcHR5IGxpc3QgaWYgd2Fybl9wYXRoIGRvZXMgbm90IGV4aXN0LgogICAgRWFjaCBlbnRyeSBpbiBUUkFOU0xBVElPTlMgbWFwcyBhbiBpbXBvcnQtbmFtZSB0byBhIGNvbmRhIHBhY2thZ2UgbmFtZS4KICAgIFVua25vd24gaW1wb3J0IG5hbWVzIHBhc3MgdGhyb3VnaCB1bmNoYW5nZWQuCiAgICAiIiIKICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyh3YXJuX3BhdGgpOgogICAgICAgIHJldHVybiBbXQogICAgc2VlbiA9IHNldCgpCiAgICByZXN1bHQgPSBbXQogICAgd2l0aCBvcGVuKHdhcm5fcGF0aCwgInIiLCBlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9Imlnbm9yZSIpIGFzIGZoOgogICAgICAgIGZvciBsaW5lIGluIGZoOgogICAgICAgICAgICBsaW5lID0gbGluZS5zdHJpcCgpCiAgICAgICAgICAgICMgUHlJbnN0YWxsZXIgNS54IGZvcm1hdDogVzogbm8gbW9kdWxlIG5hbWVkICdmb28nCiAgICAgICAgICAgIG0gPSByZS5tYXRjaChyIlc6IG5vIG1vZHVsZSBuYW1lZCAnKFteJ10rKSciLCBsaW5lKQogICAgICAgICAgICBpZiBtOgogICAgICAgICAgICAgICAgbW9kID0gbS5ncm91cCgxKS5zcGxpdCgiLiIpWzBdCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICAjIFB5SW5zdGFsbGVyIDYueCBmb3JtYXQ6CiAgICAgICAgICAgICAgICAjIG1pc3NpbmcgbW9kdWxlIG5hbWVkIGZvbyAtIGltcG9ydGVkIGJ5IGJhciAodG9wLWxldmVsKQogICAgICAgICAgICAgICAgIyBPbmx5IHByb2Nlc3MgdG9wLWxldmVsIGltcG9ydHM7IGNvbmRpdGlvbmFsL29wdGlvbmFsL2RlbGF5ZWQKICAgICAgICAgICAgICAgICMgYXJlIHVzdWFsbHkgdW5peC1vbmx5IHN0ZGxpYiBzaGltcyBzYWZlIHRvIGV4Y2x1ZGUgb24gV2luZG93cy4KICAgICAgICAgICAgICAgIG0gPSByZS5tYXRjaChyIm1pc3NpbmcgbW9kdWxlIG5hbWVkIChcUyspIiwgbGluZSkKICAgICAgICAgICAgICAgIGlmIG5vdCBtOgogICAgICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgICAgICBpZiAidG9wLWxldmVsIiBub3QgaW4gbGluZToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAgbW9kID0gbS5ncm91cCgxKS5zcGxpdCgiLiIpWzBdCiAgICAgICAgICAgIGlmIG1vZC5zdGFydHN3aXRoKCJfIik6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBpZiBtb2QgaW4gU0tJUDoKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIHBrZyA9IFRSQU5TTEFUSU9OUy5nZXQobW9kLCBtb2QpCiAgICAgICAgICAgIGlmIHBrZyBub3QgaW4gc2VlbjoKICAgICAgICAgICAgICAgIHNlZW4uYWRkKHBrZykKICAgICAgICAgICAgICAgIHJlc3VsdC5hcHBlbmQocGtnKQogICAgcmV0dXJuIHJlc3VsdAoKCmRlZiBtYWluKCk6CiAgICBpZiBsZW4oc3lzLmFyZ3YpIDwgMjoKICAgICAgICBzeXMuZXhpdCgxKQogICAgZW52bmFtZSA9IHN5cy5hcmd2WzFdCiAgICB3YXJuX3BhdGggPSBvcy5wYXRoLmpvaW4oImJ1aWxkIiwgZW52bmFtZSwgIndhcm4tIiArIGVudm5hbWUgKyAiLnR4dCIpCiAgICBmb3IgcGtnIGluIHBhcnNlX3dhcm5fZmlsZSh3YXJuX3BhdGgpOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUocGtnICsgIlxuIikKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg=="
rem ~dep_check.py compares requirements.auto.txt against ~environment.lock.txt;
rem prints 'skip' when all pipreqs packages are already installed, 'run' otherwise.
set "HP_DEP_CHECK=IiIiZGVwX2NoZWNrIHYxICgyMDI2LTAzLTI3KQpDb21wYXJlcyByZXF1aXJlbWVudHMuYXV0by50eHQgKHBpcHJlcXMgb3V0cHV0KSBhZ2FpbnN0IH5lbnZpcm9ubWVudC5sb2NrLnR4dAooY29uZGEgbGlzdCAtLWV4cG9ydCBzbmFwc2hvdCkuIFByaW50cyAnc2tpcCcgd2hlbiBldmVyeSBwYWNrYWdlIGRldGVjdGVkIGJ5CnBpcHJlcXMgaXMgYWxyZWFkeSBwcmVzZW50IGluIHRoZSBsb2NrOyBwcmludHMgJ3J1bicgb3RoZXJ3aXNlIHNvIHRoZSBjYWxsZXIKcHJvY2VlZHMgd2l0aCBjb25kYSBpbnN0YWxsLgoiIiIKX192ZXJzaW9uX18gPSAiZGVwX2NoZWNrIHYxICgyMDI2LTAzLTI3KSIKX19hbGxfXyA9IFsicGFyc2VfbG9jayIsICJwYXJzZV9yZXFzIiwgIm1haW4iXQoKaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc3lzCgpSRVFfRklMRSA9ICJyZXF1aXJlbWVudHMuYXV0by50eHQiCkxPQ0tfRklMRSA9ICJ+ZW52aXJvbm1lbnQubG9jay50eHQiCgoKZGVmIHBhcnNlX2xvY2socGF0aCk6CiAgICAiIiJSZXR1cm4gZnJvemVuc2V0IG9mIGxvd2VyY2FzZSBwYWNrYWdlIG5hbWVzIGZyb20gY29uZGEgbGlzdCAtLWV4cG9ydC4iIiIKICAgIG5hbWVzID0gc2V0KCkKICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4ocGF0aCwgInIiLCBlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9Imlnbm9yZSIpIGFzIGZoOgogICAgICAgICAgICBmb3IgbGluZSBpbiBmaDoKICAgICAgICAgICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICAgICAgICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgiIyIpOgogICAgICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgICAgICAjIGNvbmRhIGxpc3QgLS1leHBvcnQ6IG5hbWU9dmVyc2lvbj1idWlsZFs9Y2hhbm5lbF0KICAgICAgICAgICAgICAgIG5hbWUgPSBsaW5lLnNwbGl0KCI9IilbMF0uc3RyaXAoKS5sb3dlcigpCiAgICAgICAgICAgICAgICBpZiBuYW1lOgogICAgICAgICAgICAgICAgICAgIG5hbWVzLmFkZChuYW1lKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcGFzcwogICAgcmV0dXJuIGZyb3plbnNldChuYW1lcykKCgpkZWYgcGFyc2VfcmVxcyhwYXRoKToKICAgICIiIlJldHVybiBsaXN0IG9mIGxvd2VyY2FzZSBwYWNrYWdlIG5hbWVzIGZyb20gcGlwLXN0eWxlIHJlcXVpcmVtZW50cyBmaWxlLiIiIgogICAgbmFtZXMgPSBbXQogICAgdHJ5OgogICAgICAgIHdpdGggb3BlbihwYXRoLCAiciIsIGVuY29kaW5nPSJ1dGYtOCIsIGVycm9ycz0iaWdub3JlIikgYXMgZmg6CiAgICAgICAgICAgIGZvciBsaW5lIGluIGZoOgogICAgICAgICAgICAgICAgbGluZSA9IGxpbmUuc3RyaXAoKQogICAgICAgICAgICAgICAgaWYgbm90IGxpbmUgb3IgbGluZS5zdGFydHN3aXRoKCIjIik6CiAgICAgICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgICAgICMgU3RyaXAgdmVyc2lvbiBzcGVjaWZpZXI6IG51bXB5Pj0xLjIwIC0+IG51bXB5CiAgICAgICAgICAgICAgICBuYW1lID0gcmUuc3BsaXQociJbPj08IX4sO1xzXFtdIiwgbGluZSwgbWF4c3BsaXQ9MSlbMF0uc3RyaXAoKS5sb3dlcigpCiAgICAgICAgICAgICAgICBpZiBuYW1lOgogICAgICAgICAgICAgICAgICAgIG5hbWVzLmFwcGVuZChuYW1lKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcGFzcwogICAgcmV0dXJuIG5hbWVzCgoKZGVmIG1haW4oKToKICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyhMT0NLX0ZJTEUpOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoInJ1blxuIikKICAgICAgICByZXR1cm4KICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyhSRVFfRklMRSk6CiAgICAgICAgIyBObyBwaXByZXFzIG91dHB1dDsgbm90aGluZyByZXF1aXJlcyBpbnN0YWxsYXRpb24KICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJza2lwXG4iKQogICAgICAgIHJldHVybgogICAgbG9ja19uYW1lcyA9IHBhcnNlX2xvY2soTE9DS19GSUxFKQogICAgaWYgbm90IGxvY2tfbmFtZXM6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgICAgIHJldHVybgogICAgcmVxX25hbWVzID0gcGFyc2VfcmVxcyhSRVFfRklMRSkKICAgIGlmIG5vdCByZXFfbmFtZXM6CiAgICAgICAgIyBFbXB0eSByZXF1aXJlbWVudHMgZmlsZTsgY29uZGEgaW5zdGFsbCB3b3VsZCBiZSBhIG5vLW9wCiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgic2tpcFxuIikKICAgICAgICByZXR1cm4KICAgIG1pc3NpbmcgPSBbbmFtZSBmb3IgbmFtZSBpbiByZXFfbmFtZXMgaWYgbmFtZSBub3QgaW4gbG9ja19uYW1lc10KICAgIGlmIG1pc3Npbmc6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgicnVuXG4iKQogICAgZWxzZToKICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJza2lwXG4iKQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK"
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
if not "%PYVER%"=="" ( > "runtime.txt" echo %PYVER% )
if not "%PYVER%"=="" call :log "[INFO] runtime.txt written: %PYVER%"
exit /b 0
rem :die signals a fatal error but uses exit /b so the caller (CI orchestration,
rem harness, or run_tests.bat) can continue collecting artifacts and gate results.
rem Do NOT change to a bare `exit` here - that would terminate the entire job.
:die
set "MSG=%~1"
set "RC=%~2"
if "%RC%"=="" set "RC=1"
echo %date% %time% %MSG%
>> "%LOG%" echo [%date% %time%] %MSG%
call :write_status "error" %RC% %PYCOUNT%
exit /b %RC%
:rotate_log
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"if (Test-Path '%LOG%') { if ((Get-Item '%LOG%').Length -gt 10485760) { Move-Item -Force '%LOG%' '%LOGPREV%' } }"
exit /b 0
:try_conda_install
rem derived requirement: AllUsers install can fail when UAC rejects elevation even for admin accounts.
rem JustMe is the non-admin fallback that installs under the user profile instead.
rem Both attempts reuse the already-downloaded installer at %TEMP%\miniconda.exe (no re-download).
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
