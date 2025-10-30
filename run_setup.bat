@echo off
setlocal DisableDelayedExpansion
rem Boot strap renamed to run_setup.bat
cd /d "%~dp0"
set "HP_SCRIPT_ROOT=%~dp0"
set "LOG=~setup.log"
set "LOGPREV=~setup.prev.log"
set "STATUS_FILE=~bootstrap.status.json"
if not exist "%LOG%" (type nul > "%LOG%")
if exist "%STATUS_FILE%" del "%STATUS_FILE%"
set "HP_BOOTSTRAP_STATE=ok"
set "HP_ENV_MODE=conda"
set "HP_ENV_READY="
set "HP_SKIP_PIPREQS="
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
set "HP_NDJSON="
if exist "%CD%\tests" set "HP_NDJSON=%CD%\tests\~test-results.ndjson"
if defined HP_NDJSON if not exist "%HP_NDJSON%" ( type nul > "%HP_NDJSON%" )
rem --- CI fast path (entry tests only) ---
call :rotate_log
rem HP_* variables represent "Helper Payload" assets emitted on demand.
call :define_helper_payloads
for %%I in ("%CD%") do set "ENVNAME=%%~nI"

set "PYCOUNT=0"
for /f "delims=" %%F in ('dir /b /a-d *.py 2^>nul') do call :count_python "%%F"
if "%PYCOUNT%"=="" set "PYCOUNT=0"
call :log "[INFO] Python file count: %PYCOUNT%"
set "HP_CONDA_PROBE_STATUS=skipped"
set "HP_CONDA_PROBE_REASON=not-requested"

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
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "try {"
  "  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12"
  "  $ProgressPreference = 'SilentlyContinue'"
  "  $uri = [Environment]::GetEnvironmentVariable('HP_MINICONDA_URL');"
  "  if (-not $uri) { throw 'HP_MINICONDA_URL not set' }"
  "  $target = Join-Path $env:TEMP 'miniconda.exe'"
  "  $max = 3"
  "  for ($i = 1; $i -le $max; $i++) {"
  "    try {"
  "      Invoke-WebRequest -Uri $uri -OutFile $target -UseBasicParsing -MaximumRedirection 5"
  "      if ((Test-Path $target) -and ((Get-Item $target).Length -gt 0)) { break }"
  "      throw 'Zero-length download'"
  "    } catch {"
  "      if ($i -eq $max) { throw }"
  "      Write-Host ('[WARN] Miniconda download retry {0}: {1}' -f $i, $_.Exception.Message)"
  "      Start-Sleep -Seconds ([int][Math]::Min(3 * $i, 15))"
  "    }"
  "  }"
  "} catch {"
  "  Write-Host ('[WARN] Miniconda download failed: {0}' -f $_.Exception.Message)"
  "  exit 1"
  "}"
    >> "%LOG%" 2>&1
  if errorlevel 1 set "HP_CONDA_DL_RC=%errorlevel%"
  if not exist "%TEMP%\miniconda.exe" set "HP_CONDA_DL_RC=1"
  if "%HP_CONDA_DL_RC%"=="0" (
    start /wait "" "%TEMP%\miniconda.exe" /InstallationType=JustMe /AddToPath=0 /RegisterPython=0 /S /D=%MINICONDA_ROOT%
    if errorlevel 1 set "HP_CONDA_DL_RC=%errorlevel%"
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

rem === Channel policy (determinism & legal) ===================================
call "%CONDA_BAT%" config --name base --add channels conda-forge

rem NOTE: every 'conda create' or 'conda install' call below MUST include:
rem       --override-channels -c conda-forge

set "ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%"
call :log "[INFO] Workspace: %CD%"
call :log "[INFO] Env name: %ENVNAME%"
call :log "[INFO] Log: %LOG%"

call :emit_from_base64 "~detect_python.py" HP_DETECT_PY
if errorlevel 1 call :die "[ERROR] Could not write ~detect_python.py"
if exist "%CONDA_BASE_PY%" (
  "%CONDA_BASE_PY%" "~detect_python.py" > "~py_spec.txt" 2>> "%LOG%"
) else (
  call "%CONDA_BAT%" run -n base python "~detect_python.py" > "~py_spec.txt" 2>> "%LOG%"
)
set "PYSPEC="
for /f "usebackq delims=" %%A in ("~py_spec.txt") do set "PYSPEC=%%A"
if "%PYSPEC%"=="" (
  call "%CONDA_BAT%" create -y -n "%ENVNAME%" --override-channels -c conda-forge >> "%LOG%" 2>&1
) else (
  call "%CONDA_BAT%" create -y -n "%ENVNAME%" %PYSPEC% --override-channels -c conda-forge >> "%LOG%" 2>&1
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

rem README.md documents the conda-forge policy for this project and why .condarc is required.
rem Emit the .condarc payload from base64 so quoting stays robust on Windows CMD.
call :emit_from_base64 "~condarc" HP_CONDARC
if errorlevel 1 call :die "[ERROR] Could not stage ~condarc"
if not exist "%ENV_PATH%" mkdir "%ENV_PATH%"
copy /y "~condarc" "%ENV_PATH%\.condarc" >> "%LOG%" 2>&1
if errorlevel 1 call :die "[ERROR] Could not write %ENV_PATH%\.condarc"



:after_env_mode_selection
call :emit_from_base64 "~prep_requirements.py" HP_PREP_REQUIREMENTS
if errorlevel 1 call :die "[ERROR] Could not write ~prep_requirements.py"
set "REQ=requirements.txt"
if exist "%REQ%" ( for %%S in ("%REQ%") do if %%~zS EQU 0 del "%REQ%" )
set "HP_JOB_SUMMARY=~pipreqs.summary.txt"
if exist "%HP_JOB_SUMMARY%" del "%HP_JOB_SUMMARY%"
if not defined HP_PY (
  call :die "[ERROR] Active Python interpreter not resolved."
)

echo Interpreter: %HP_PY%
>> "%LOG%" echo Interpreter: %HP_PY%
call :append_env_mode_row
"%HP_PY%" -c "print('py_ok')" 1>nul 2>nul || call :log "[WARN] Interpreter smoke test failed (continuing)."

if not defined HP_SKIP_PIPREQS (
  "%HP_PY%" -m pip install -q --disable-pip-version-check pipreqs==%HP_PIPREQS_VERSION% >> "%LOG%" 2>&1
  if errorlevel 1 call :die "[ERROR] pipreqs install failed."
)

set "HP_PIPREQS_TARGET_WORK=%CD%\requirements.auto.txt"
set "HP_PIPREQS_TARGET=%HP_PIPREQS_TARGET_WORK%"
set "HP_PIPREQS_IGNORE=.git,.github,.venv,venv,env,build,dist,__pycache__,tests"
set "HP_PIPREQS_IGNORE_DISPLAY="
if defined HP_PIPREQS_IGNORE set "HP_PIPREQS_IGNORE_DISPLAY= --ignore %HP_PIPREQS_IGNORE%"
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

if defined HP_PIPREQS_IGNORE (
  :: pipreqs flags are locked by CI (pipreqs.flags gate).
  :: Rationale: compat mode for deterministic output; force overwrite; write to requirements.auto.txt (separate from committed requirements).
  "%HP_PY%" -m pipreqs . --force --mode compat --savepath "%HP_PIPREQS_TARGET%" --ignore %HP_PIPREQS_IGNORE% > "%HP_PIPREQS_DIRECT_LOG%" 2>&1
) else (
  :: pipreqs flags are locked by CI (pipreqs.flags gate).
  :: Rationale: compat mode for deterministic output; force overwrite; write to requirements.auto.txt (separate from committed requirements).
  "%HP_PY%" -m pipreqs . --force --mode compat --savepath "%HP_PIPREQS_TARGET%" > "%HP_PIPREQS_DIRECT_LOG%" 2>&1
)
set "HP_PIPREQS_LAST_LOG=%HP_PIPREQS_DIRECT_LOG%"
set "HP_PIPREQS_RC=%errorlevel%"
if "%HP_PIPREQS_RC%"=="0" if exist "%HP_PIPREQS_TARGET_WORK%" (
  for %%S in ("%HP_PIPREQS_TARGET_WORK%") do if %%~zS GTR 0 (
    set "HP_PIPREQS_PHASE_RESULT=ok"
    set "HP_PIPREQS_SUMMARY_PHASE=direct"
    goto :after_pipreqs_run
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
pushd "%HP_PIPREQS_STAGE_ROOT%"
call :log "[INFO] pipreqs (staging) command: pipreqs . --force --mode compat --savepath ""%HP_PIPREQS_STAGE_TARGET%"""
echo Pipreqs command (staging): pipreqs . --force --mode compat --savepath "%HP_PIPREQS_STAGE_TARGET%"
:: pipreqs flags are locked by CI (pipreqs.flags gate).
:: Rationale: compat mode for deterministic output; force overwrite; write to requirements.auto.txt (separate from committed requirements).
"%HP_PY%" -m pipreqs . --force --mode compat --savepath "%HP_PIPREQS_STAGE_TARGET%" > "%HP_PIPREQS_STAGE_LOG%" 2>&1
set "HP_PIPREQS_RC=%errorlevel%"
popd
set "HP_PIPREQS_LAST_LOG=%HP_PIPREQS_STAGE_LOG%"
if "%HP_PIPREQS_RC%"=="0" if exist "%HP_PIPREQS_STAGE_TARGET%" (
  for %%S in ("%HP_PIPREQS_STAGE_TARGET%") do if %%~zS GTR 0 (
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
)
if not defined HP_PIPREQS_SUMMARY_NOTE set "HP_PIPREQS_SUMMARY_NOTE=(staging pipreqs failed)"
set "HP_PIPREQS_PHASE_RESULT=fail"

:after_pipreqs_run
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
    call :die "[ERROR] pipreqs generation failed."
  )
)
if not exist "%REQ%" if exist "requirements.auto.txt" ( copy /y "requirements.auto.txt" "requirements.txt" >> "%LOG%" 2>&1 )
if exist "requirements.txt" if exist "requirements.auto.txt" ( fc "requirements.txt" "requirements.auto.txt" > "~pipreqs.diff.txt" 2>&1 )
if exist "requirements.txt" (
  if exist "~reqs_conda.txt" del "~reqs_conda.txt"
  if "%HP_ENV_MODE%"=="conda" (
    "%CONDA_BASE_PY%" "~prep_requirements.py" "requirements.txt" >nul 2>> "%LOG%"
  ) else (
    "%HP_PY%" "~prep_requirements.py" "requirements.txt" >nul 2>> "%LOG%"
  )
  if "%HP_ENV_MODE%"=="conda" (
    call "%CONDA_BAT%" install -y -n "%ENVNAME%" --file "~reqs_conda.txt" --override-channels -c conda-forge >> "%LOG%" 2>&1
    if errorlevel 1 (
      for /f "usebackq delims=" %%P in ("~reqs_conda.txt") do (
        call "%CONDA_BAT%" install -y -n "%ENVNAME%" --override-channels -c conda-forge %%P >> "%LOG%" 2>&1
      )
    )
    "%HP_PY%" -m pip install -r requirements.txt >> "%LOG%" 2>&1
  ) else if "%HP_ENV_MODE%"=="venv" (
    "%HP_PY%" -m pip install -r requirements.txt >> "%LOG%" 2>&1
  ) else (
    call :log "[WARN] System fallback: skipping requirement installation."
  )
)
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
  if defined HP_SYS_PY_ARGS (
    "%HP_SYS_PY%" %HP_SYS_PY_ARGS% -m py_compile "%HP_FIND_ENTRY_ABS%" 1>nul 2>nul
  ) else (
    "%HP_SYS_PY%" -m py_compile "%HP_FIND_ENTRY_ABS%" 1>nul 2>nul
  )
  set "HP_CRUMB_FILE=%HP_SCRIPT_ROOT%~crumb.txt"
  if exist "%HP_CRUMB_FILE%" del "%HP_CRUMB_FILE%" >nul 2>&1
  if defined HP_SYS_PY_ARGS (
    "%HP_SYS_PY%" %HP_SYS_PY_ARGS% "%HP_FIND_ENTRY_ABS%" > "%HP_CRUMB_FILE%" 2>> "%LOG%"
  ) else (
    "%HP_SYS_PY%" "%HP_FIND_ENTRY_ABS%" > "%HP_CRUMB_FILE%" 2>> "%LOG%"
  )
  if exist "%HP_CRUMB_FILE%" (
    for /f "usebackq delims=" %%L in ("%HP_CRUMB_FILE%") do if not defined HP_CRUMB set "HP_CRUMB=%%L"
    del "%HP_CRUMB_FILE%" >nul 2>&1
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
goto :after_env_bootstrap

:after_env_bootstrap
if defined HP_CI_SKIP_ENV goto :after_env_skip
call :determine_entry
if errorlevel 1 call :die "[ERROR] Could not determine entry point"
if "%HP_ENTRY%"=="" (
  call :log "[INFO] No entry script detected; skipping PyInstaller packaging."
) else (
  call :record_chosen_entry "%HP_ENTRY%"
  call :log "[INFO] Running entry script smoke test via %HP_ENV_MODE% interpreter."
  rem derived requirement: CI env smoke saw `The syntax of the command is incorrect.`
  rem when this block silently built the command. Log the exact invocation (with
  rem explicit redirection) so future regressions remain diagnosable.
  >> "%LOG%" echo Smoke command: "%HP_PY%" "%HP_ENTRY%" ^> "~run.out.txt" 2^> "~run.err.txt"
  "%HP_PY%" "%HP_ENTRY%" > "~run.out.txt" 2> "~run.err.txt"
  if errorlevel 1 call :die "[ERROR] Entry script execution failed."
  if "%HP_ENV_MODE%"=="system" (
    call :log "[INFO] System fallback: skipping PyInstaller packaging."
  ) else (
    "%HP_PY%" -m pip install -q pyinstaller >> "%LOG%" 2>&1
    "%HP_PY%" -m PyInstaller -y --onefile --name "%ENVNAME%" "%HP_ENTRY%" >> "%LOG%" 2>&1
    if errorlevel 1 call :die "[ERROR] PyInstaller execution failed."
    if not exist "dist\%ENVNAME%.exe" call :die "[ERROR] PyInstaller did not produce dist\%ENVNAME%.exe"
    call :log "[INFO] PyInstaller produced dist\%ENVNAME%.exe"
  )
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
if defined HP_SYS_ARGS (
  for /f "usebackq delims=" %%I in (`"%HP_SYS_CMD%" %HP_SYS_ARGS% -c "import sys;print(sys.executable)"`) do set "HP_SYS_EXE=%%I"
) else (
  for /f "usebackq delims=" %%I in (`"%HP_SYS_CMD%" -c "import sys;print(sys.executable)"`) do set "HP_SYS_EXE=%%I"
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
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12" ^
  "$ProgressPreference = 'SilentlyContinue'" ^
  "$uri = [Environment]::GetEnvironmentVariable('HP_MINICONDA_URL');" ^
  "if (-not $uri) { Write-Host '[ERROR] HP_MINICONDA_URL not set'; exit 1 }" ^
  "$out = Join-Path (Get-Location) '%HP_DL_PATH%';" ^
  "$max = 3; $ok = $false;" ^
  "for ($i = 1; $i -le $max; $i++) {" ^
  "  try {" ^
  "    Invoke-WebRequest -Uri $uri -OutFile $out -UseBasicParsing -MaximumRedirection 5" ^
  "    if ((Test-Path $out) -and ((Get-Item $out).Length -gt 0)) {" ^
  "      $ok = $true; break" ^
  "    }" ^
  "    throw 'Zero-length download'" ^
  "  } catch {" ^
  "    Write-Host ('[WARN] Download attempt {0} failed: {1}' -f $i, $_.Exception.Message)" ^
  "    Start-Sleep -Seconds ([int][Math]::Min(3 * $i, 15))" ^
  "  }" ^
  "}" ^
  "if (-not $ok) { exit 1 }" >> "%LOG%" 2>&1
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

:determine_entry
set "HP_ENTRY="
set "HP_ENTRY_CMD="
set "HP_ENTRY_ARGS="
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

rem Echo to console (no punctuation at end)
echo Chosen entry: %HP_CRUMB%
rem Append same line to setup log
>> "%LOG%" echo Chosen entry: %HP_CRUMB%

rem If we also need an absolute path for execution, set HP_ENTRY elsewhere
rem and keep the echo outside any ( ... ) block.
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
set "HP_CONDARC=Y2hhbm5lbHM6CiAgLSBjb25kYS1mb3JnZQpjaGFubmVsX3ByaW9yaXR5OiBzdHJpY3QKc2hvd19jaGFubmVsX3VybHM6IHRydWUK"
set "HP_DETECT_PY=X192ZXJzaW9uX18gPSAiZGV0ZWN0X3B5dGhvbiB2MiAoMjAyNS0wOS0yNCkiCl9fYWxsX18gPSBbInBlcDQ0MF90b19jb25kYSIsICJkZXRlY3RfcmVxdWlyZXNfcHl0aG9uIiwgIm1haW4iXQpPUkRFUiA9IHsiPT0iOiAwLCAiIT0iOiAxLCAiPj0iOiAyLCAiPiI6IDMsICI8PSI6IDQsICI8IjogNX0KCmltcG9ydCBvcwppbXBvcnQgcmUKaW1wb3J0IHN5cwoKIyBIZWxwZXIgaW1wbGVtZW50cyB0aGUgUkVBRE1FIGJvb3RzdHJhcCBjb250cmFjdC4gUEVQIDQ0MCBkZXRhaWxzOgojIGh0dHBzOi8vcGVwcy5weXRob24ub3JnL3BlcC0wNDQwLwoKQ0QgPSBvcy5nZXRjd2QoKQpSVU5USU1FX1BBVEggPSBvcy5wYXRoLmpvaW4oQ0QsICJydW50aW1lLnR4dCIpClBZUFJPSkVDVF9QQVRIID0gb3MucGF0aC5qb2luKENELCAicHlwcm9qZWN0LnRvbWwiKQpQWVBST0pFQ1RfUkUgPSByZS5jb21waWxlKHIicmVxdWlyZXMtcHl0aG9uXHMqPVxzKlsnIl0oW14nIl0rKVsnIl0iLCByZS5JR05PUkVDQVNFKQpTUEVDX1BBVFRFUk4gPSByZS5jb21waWxlKHInKH49fD09fCE9fD49fDw9fD58PClccyooWzAtOV0rKD86XC5bMC05XSspKiknKQoKCmRlZiB2ZXJzaW9uX2tleSh0ZXh0OiBzdHIpOgogICAgIiIiUmV0dXJuIGEgdHVwbGUgdXNhYmxlIGZvciBudW1lcmljIG9yZGVyaW5nIG9mIGRvdHRlZCB2ZXJzaW9ucy4iIiIKICAgIHBhcnRzID0gW10KICAgIGZvciBjaHVuayBpbiB0ZXh0LnNwbGl0KCcuJyk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBwYXJ0cy5hcHBlbmQoaW50KGNodW5rKSkKICAgICAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgcGFydHMuYXBwZW5kKDApCiAgICByZXR1cm4gdHVwbGUocGFydHMpCgoKZGVmIGJ1bXBfZm9yX2NvbXBhdGlibGUodmVyc2lvbjogc3RyKSAtPiBzdHI6CiAgICAiIiJUcmFuc2xhdGUgdGhlIFBFUCA0NDAgY29tcGF0aWJsZSByZWxlYXNlIHVwcGVyIGJvdW5kLiIiIgogICAgcGllY2VzID0gW2ludChpdGVtKSBmb3IgaXRlbSBpbiB2ZXJzaW9uLnNwbGl0KCcuJykgaWYgaXRlbS5pc2RpZ2l0KCldCiAgICBpZiBub3QgcGllY2VzOgogICAgICAgIHJldHVybiB2ZXJzaW9uCiAgICBpZiBsZW4ocGllY2VzKSA+PSAzOgogICAgICAgIHJldHVybiBmIntwaWVjZXNbMF19LntwaWVjZXNbMV0gKyAxfSIKICAgIGlmIGxlbihwaWVjZXMpID09IDI6CiAgICAgICAgcmV0dXJuIGYie3BpZWNlc1swXSArIDF9LjAiCiAgICByZXR1cm4gc3RyKHBpZWNlc1swXSArIDEpCgoKZGVmIGV4cGFuZF9jbGF1c2Uob3A6IHN0ciwgdmVyc2lvbjogc3RyKToKICAgIGlmIG9wID09ICJ+PSI6CiAgICAgICAgdXBwZXIgPSBidW1wX2Zvcl9jb21wYXRpYmxlKHZlcnNpb24pCiAgICAgICAgcmV0dXJuIFsoIj49IiwgdmVyc2lvbiksICgiPCIsIHVwcGVyKV0KICAgIHJldHVybiBbKG9wLCB2ZXJzaW9uKV0KCgpkZWYgcGVwNDQwX3RvX2NvbmRhKHNwZWM6IHN0cikgLT4gc3RyOgogICAgIiIiUmV0dXJuICJweXRob24iIGNvbnN0cmFpbnRzIGV4cGFuZGVkIGZyb20gYSByZXF1aXJlcy1weXRob24gc3BlYy4iIiIKICAgIGNsYXVzZXMgPSBbXQogICAgZm9yIHJhdyBpbiBzcGVjLnNwbGl0KCcsJyk6CiAgICAgICAgcmF3ID0gcmF3LnN0cmlwKCkKICAgICAgICBpZiBub3QgcmF3OgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIG1hdGNoID0gU1BFQ19QQVRURVJOLm1hdGNoKHJhdykKICAgICAgICBpZiBub3QgbWF0Y2g6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgb3AsIHZlcnNpb24gPSBtYXRjaC5ncm91cHMoKQogICAgICAgIGNsYXVzZXMuZXh0ZW5kKGV4cGFuZF9jbGF1c2Uob3AsIHZlcnNpb24pKQogICAgaWYgbm90IGNsYXVzZXM6CiAgICAgICAgcmV0dXJuICIiCiAgICBkZWR1cCA9IHt9CiAgICBmb3Igb3AsIHZlcnNpb24gaW4gY2xhdXNlczoKICAgICAgICBkZWR1cFsob3AsIHZlcnNpb24pXSA9IChvcCwgdmVyc2lvbikKICAgIG9yZGVyZWQgPSBzb3J0ZWQoZGVkdXAudmFsdWVzKCksIGtleT1sYW1iZGEgaXRlbTogKE9SREVSLmdldChpdGVtWzBdLCA5OSksIHZlcnNpb25fa2V5KGl0ZW1bMV0pKSkKICAgIHJldHVybiAicHl0aG9uIiArICIsIi5qb2luKGYie29wfXt2ZXJzaW9ufSIgZm9yIG9wLCB2ZXJzaW9uIGluIG9yZGVyZWQpCgoKZGVmIHJlYWRfcnVudGltZV9zcGVjKCkgLT4gc3RyOgogICAgaWYgbm90IG9zLnBhdGguZXhpc3RzKFJVTlRJTUVfUEFUSCk6CiAgICAgICAgcmV0dXJuICIiCiAgICB3aXRoIG9wZW4oUlVOVElNRV9QQVRILCAncicsIGVuY29kaW5nPSd1dGYtOCcsIGVycm9ycz0naWdub3JlJykgYXMgaGFuZGxlOgogICAgICAgIHRleHQgPSBoYW5kbGUucmVhZCgpCiAgICBtYXRjaCA9IHJlLnNlYXJjaChyJyg/OnB5dGhvblstPV0pP1xzKihbMC05XSsoPzpcLlswLTldKyl7MCwyfSknLCB0ZXh0KQogICAgaWYgbm90IG1hdGNoOgogICAgICAgIHJldHVybiAiIgogICAgcGFydHMgPSBtYXRjaC5ncm91cCgxKS5zcGxpdCgnLicpCiAgICBtYWpvcl9taW5vciA9ICcuJy5qb2luKHBhcnRzWzoyXSkKICAgIHJldHVybiBmJ3B5dGhvbj17bWFqb3JfbWlub3J9JwoKCmRlZiByZWFkX3B5cHJvamVjdF9zcGVjKCkgLT4gc3RyOgogICAgaWYgbm90IG9zLnBhdGguZXhpc3RzKFBZUFJPSkVDVF9QQVRIKToKICAgICAgICByZXR1cm4gIiIKICAgIHdpdGggb3BlbihQWVBST0pFQ1RfUEFUSCwgJ3InLCBlbmNvZGluZz0ndXRmLTgnLCBlcnJvcnM9J2lnbm9yZScpIGFzIGhhbmRsZToKICAgICAgICB0ZXh0ID0gaGFuZGxlLnJlYWQoKQogICAgbWF0Y2ggPSBQWVBST0pFQ1RfUkUuc2VhcmNoKHRleHQpCiAgICBpZiBub3QgbWF0Y2g6CiAgICAgICAgcmV0dXJuICIiCiAgICByZXR1cm4gcGVwNDQwX3RvX2NvbmRhKG1hdGNoLmdyb3VwKDEpKQoKCmRlZiBkZXRlY3RfcmVxdWlyZXNfcHl0aG9uKCkgLT4gc3RyOgogICAgIiIiUmV0dXJuIGJlc3QtZWZmb3J0IHJlcXVpcmVzLXB5dGhvbiBjb25zdHJhaW50IGZvciB0aGUgY3VycmVudCBwcm9qZWN0LiIiIgogICAgcnVudGltZV9zcGVjID0gcmVhZF9ydW50aW1lX3NwZWMoKQogICAgaWYgcnVudGltZV9zcGVjOgogICAgICAgIHJldHVybiBydW50aW1lX3NwZWMKICAgIHJldHVybiByZWFkX3B5cHJvamVjdF9zcGVjKCkKCgpkZWYgbWFpbihhcmd2PU5vbmUpIC0+IE5vbmU6CiAgICAiIiJDTEkgZW50cnkgcG9pbnQgdGhhdCBwcmludHMgbm9ybWFsaXplZCByZXF1aXJlcy1weXRob24gY29uc3RyYWludHMuIiIiCiAgICBhcmdzID0gbGlzdChzeXMuYXJndlsxOl0gaWYgYXJndiBpcyBOb25lIGVsc2UgYXJndikKICAgIGlmIGFyZ3MgYW5kIGFyZ3NbMF0gPT0gIi0tc2VsZi10ZXN0IjoKICAgICAgICBmb3Igc2FtcGxlIGluICgifj0zLjEwIiwgIn49My44LjEiKToKICAgICAgICAgICAgc3lzLnN0ZG91dC53cml0ZShwZXA0NDBfdG9fY29uZGEoc2FtcGxlKSArICIKIikKICAgICAgICByZXR1cm4KICAgIGlmIGFyZ3M6CiAgICAgICAgZm9yIGl0ZW0gaW4gYXJnczoKICAgICAgICAgICAgc3lzLnN0ZG91dC53cml0ZShwZXA0NDBfdG9fY29uZGEoaXRlbSkgKyAiCiIpCiAgICAgICAgcmV0dXJuCiAgICBzeXMuc3Rkb3V0LndyaXRlKGRldGVjdF9yZXF1aXJlc19weXRob24oKSArICIKIikKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg=="
set "HP_PRINT_PYVER=aW1wb3J0IHN5cwoKcHJpbnQoZiJweXRob24te3N5cy52ZXJzaW9uX2luZm9bMF19LntzeXMudmVyc2lvbl9pbmZvWzFdfSIpCg=="
set "HP_PREP_REQUIREMENTS=IyBoZWxwZXI6IHByZXBfcmVxdWlyZW1lbnRzIHYyICgyMDI1LTA5LTI0KQpfX3ZlcnNpb25fXyA9ICJwcmVwX3JlcXVpcmVtZW50cyB2MiAoMjAyNS0wOS0yNCkiCk9QX09SREVSID0gKCI9PSIsICIhPSIsICI+PSIsICI+IiwgIjw9IiwgIjwiKQpPUF9SQU5LID0ge29wOiBpZHggZm9yIGlkeCwgb3AgaW4gZW51bWVyYXRlKE9QX09SREVSKX0KX19hbGxfXyA9IFsiZm9ybWF0X2xpbmUiLCAiY2Fub25pY2FsX29wcyIsICJ0b19jb25kYSIsICJ0b19waXAiLCAibWFpbiJdCgppbXBvcnQgb3MKaW1wb3J0IHJlCmltcG9ydCBzeXMKZnJvbSBjb2xsZWN0aW9ucyBpbXBvcnQgT3JkZXJlZERpY3QKCklOUCA9IHN5cy5hcmd2WzFdIGlmIGxlbihzeXMuYXJndikgPiAxIGVsc2UgInJlcXVpcmVtZW50cy50eHQiCk9VVF9DT05EQSA9ICJ+cmVxc19jb25kYS50eHQiCk9VVF9QSVAgPSAifnJlcXNfcGlwLnR4dCIKU1BFQ19QQVRURVJOID0gcmUuY29tcGlsZShyIih+PXw9PXwhPXw+PXw+fDw9fDwpXHMqKFteXHMsO10rKVxzKiQiKQpOQU1FX1BBVFRFUk4gPSByZS5jb21waWxlKHIiXlxzKihbQS1aYS16MC05Xy4tXSspXHMqKC4qKSQiKQoKCmRlZiBub3JtKHRleHQ6IHN0cikgLT4gc3RyOgogICAgcmV0dXJuIHRleHQuc3RyaXAoKQoKCmRlZiBzcGxpdF9tYXJrZXIodGV4dDogc3RyKSAtPiBzdHI6CiAgICByZXR1cm4gdGV4dC5zcGxpdCgiOyIpWzBdLnN0cmlwKCkKCgpkZWYgc3RyaXBfZXh0cmFzKG5hbWU6IHN0cikgLT4gc3RyOgogICAgcmV0dXJuIHJlLnN1YihyIlxbLio/XF0iLCAiIiwgbmFtZSkKCgpkZWYgX3ZlcnNpb25fa2V5KHRleHQ6IHN0cik6CiAgICBwYXJ0cyA9IFtdCiAgICBmb3IgY2h1bmsgaW4gdGV4dC5zcGxpdCgnLicpOgogICAgICAgIHRyeToKICAgICAgICAgICAgcGFydHMuYXBwZW5kKGludChjaHVuaykpCiAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgIHBhcnRzLmFwcGVuZCgwKQogICAgcmV0dXJuIHR1cGxlKHBhcnRzKQoKCmRlZiBfYnVtcF9jb21wYXRpYmxlKHZhbHVlOiBzdHIpIC0+IHN0cjoKICAgIHBpZWNlcyA9IHZhbHVlLnNwbGl0KCcuJykKICAgIGlmIG5vdCBwaWVjZXMgb3Igbm90IHBpZWNlc1swXS5pc2RpZ2l0KCk6CiAgICAgICAgcmV0dXJuIHZhbHVlCiAgICBtYWpvciA9IGludChwaWVjZXNbMF0pCiAgICBpZiBsZW4ocGllY2VzKSA+PSAzIGFuZCBwaWVjZXNbMV0uaXNkaWdpdCgpOgogICAgICAgIHJldHVybiBmInttYWpvcn0ue2ludChwaWVjZXNbMV0pICsgMX0iCiAgICBpZiBsZW4ocGllY2VzKSA+PSAyOgogICAgICAgIHJldHVybiBmInttYWpvciArIDF9LjAiCiAgICByZXR1cm4gc3RyKG1ham9yICsgMSkKCgpkZWYgX2V4cGFuZF9mcmFnbWVudChmcmFnbWVudDogc3RyKToKICAgIGlmIG5vdCBmcmFnbWVudDoKICAgICAgICByZXR1cm4gW10KICAgIHZhbHVlID0gZnJhZ21lbnQuc3RyaXAoKQogICAgaWYgbm90IHZhbHVlOgogICAgICAgIHJldHVybiBbXQogICAgbWF0Y2ggPSBTUEVDX1BBVFRFUk4uZnVsbG1hdGNoKHZhbHVlKQogICAgaWYgbm90IG1hdGNoOgogICAgICAgIHJldHVybiBbXQogICAgb3AsIHZlciA9IG1hdGNoLmdyb3VwcygpCiAgICB2ZXIgPSB2ZXIuc3RyaXAoKQogICAgaWYgbm90IHZlcjoKICAgICAgICByZXR1cm4gW10KICAgIGlmIG9wID09ICJ+PSI6CiAgICAgICAgdXBwZXIgPSBfYnVtcF9jb21wYXRpYmxlKHZlcikKICAgICAgICByZXR1cm4gW2YiPj17dmVyfSIsIGYiPHt1cHBlcn0iXQogICAgcmV0dXJuIFtmIntvcH17dmVyfSJdCgoKZGVmIGNhbm9uaWNhbF9vcHMoc3BlY3MpIC0+IGxpc3Q6CiAgICAiIiJSZXR1cm4gbm9ybWFsaXplZCBjb25zdHJhaW50IGZyYWdtZW50cyBzb3J0ZWQgZm9yIG91dHB1dC4iIiIKICAgIGJ1Y2tldCA9IE9yZGVyZWREaWN0KCkKICAgIGZvciByYXcgaW4gc3BlY3M6CiAgICAgICAgZm9yIG5vcm1hbGl6ZWQgaW4gX2V4cGFuZF9mcmFnbWVudChyYXcpOgogICAgICAgICAgICBidWNrZXRbbm9ybWFsaXplZF0gPSBOb25lCiAgICBvcmRlcmVkID0gbGlzdChidWNrZXQua2V5cygpKQogICAgb3JkZXJlZC5zb3J0KGtleT1fc3BlY19zb3J0X2tleSkKICAgIHJldHVybiBfZW5mb3JjZV9ib3VuZHNfb3JkZXIob3JkZXJlZCkKCgpkZWYgX3NwZWNfc29ydF9rZXkodmFsdWU6IHN0cik6CiAgICBmb3Igb3AgaW4gT1BfT1JERVI6CiAgICAgICAgaWYgdmFsdWUuc3RhcnRzd2l0aChvcCk6CiAgICAgICAgICAgIHZlciA9IHZhbHVlW2xlbihvcCk6XQogICAgICAgICAgICByZXR1cm4gT1BfUkFOS1tvcF0sIF92ZXJzaW9uX2tleSh2ZXIpLCB2ZXIKICAgIHJldHVybiBsZW4oT1BfT1JERVIpLCBfdmVyc2lvbl9rZXkodmFsdWUpLCB2YWx1ZQoKCmRlZiBfZW5mb3JjZV9ib3VuZHNfb3JkZXIoaXRlbXM6IGxpc3QpIC0+IGxpc3Q6CiAgICBvcHMgPSBsaXN0KGl0ZW1zKQogICAgbG93ZXJfaW5kZXggPSBuZXh0KChpZHggZm9yIGlkeCwgdGV4dCBpbiBlbnVtZXJhdGUob3BzKSBpZiB0ZXh0LnN0YXJ0c3dpdGgoIj49IikpLCBOb25lKQogICAgaWYgbG93ZXJfaW5kZXggaXMgTm9uZToKICAgICAgICByZXR1cm4gb3BzCiAgICBmb3IgdXBwZXJfb3AgaW4gKCI8PSIsICI8Iik6CiAgICAgICAgdXBwZXJfaW5kZXggPSBuZXh0KChpZHggZm9yIGlkeCwgdGV4dCBpbiBlbnVtZXJhdGUob3BzKSBpZiB0ZXh0LnN0YXJ0c3dpdGgodXBwZXJfb3ApKSwgTm9uZSkKICAgICAgICBpZiB1cHBlcl9pbmRleCBpcyBub3QgTm9uZSBhbmQgdXBwZXJfaW5kZXggPCBsb3dlcl9pbmRleDoKICAgICAgICAgICAgdmFsdWUgPSBvcHMucG9wKGxvd2VyX2luZGV4KQogICAgICAgICAgICBvcHMuaW5zZXJ0KHVwcGVyX2luZGV4LCB2YWx1ZSkKICAgICAgICAgICAgbG93ZXJfaW5kZXggPSB1cHBlcl9pbmRleAogICAgcmV0dXJuIG9wcwoKCmRlZiBmb3JtYXRfbGluZShuYW1lOiBzdHIsIHNwZWNzKSAtPiBsaXN0OgogICAgIiIiUmV0dXJuIFsnbmFtZSA+PS4uLiddIHdpdGggY2Fub25pY2FsaXplZCBzcGVjaWZpZXJzLiIiIgogICAgb3BzID0gY2Fub25pY2FsX29wcyhzcGVjcykKICAgIHJldHVybiBbZiJ7bmFtZX0gIiArICIsIi5qb2luKG9wcyldIGlmIG9wcyBlbHNlIFtuYW1lXQoKCmRlZiBub3JtYWxpemVfc3BlY2lmaWVycyhyZXN0OiBzdHIpOgogICAgaXRlbXMgPSBbXQogICAgZm9yIGNodW5rIGluIHJlc3Quc3BsaXQoJywnKToKICAgICAgICBjaHVuayA9IGNodW5rLnN0cmlwKCkKICAgICAgICBpZiBjaHVuazoKICAgICAgICAgICAgaXRlbXMuZXh0ZW5kKF9leHBhbmRfZnJhZ21lbnQoY2h1bmspKQogICAgcmV0dXJuIGNhbm9uaWNhbF9vcHMoaXRlbXMpCgoKZGVmIHRvX2NvbmRhKGxpbmU6IHN0cik6CiAgICAiIiJSZXR1cm4gY29uZGEtc3R5bGUgcmVxdWlyZW1lbnQgbGluZXMgZGVyaXZlZCBmcm9tIGlucHV0LiIiIgogICAgc2VjdGlvbiA9IHNwbGl0X21hcmtlcihsaW5lKQogICAgaWYgbm90IHNlY3Rpb24gb3Igc2VjdGlvbi5zdGFydHN3aXRoKCcjJyk6CiAgICAgICAgcmV0dXJuIFtdCiAgICBtYXRjaCA9IE5BTUVfUEFUVEVSTi5tYXRjaChzZWN0aW9uKQogICAgaWYgbm90IG1hdGNoOgogICAgICAgIHJldHVybiBbXQogICAgbmFtZSwgcmVzdCA9IG1hdGNoLmdyb3VwcygpCiAgICBuYW1lID0gc3RyaXBfZXh0cmFzKG5hbWUpCiAgICByZXN0ID0gcmUuc3ViKHIiXFsuKj9cXSIsICIiLCByZXN0KQogICAgc3BlY3MgPSBbY2h1bmsuc3RyaXAoKSBmb3IgY2h1bmsgaW4gcmVzdC5zcGxpdCgnLCcpIGlmIGNodW5rLnN0cmlwKCldCiAgICByZXR1cm4gZm9ybWF0X2xpbmUobmFtZSwgc3BlY3MpCgoKZGVmIHRvX3BpcChsaW5lOiBzdHIpOgogICAgIiIiUmV0dXJuIHJhdyBwaXAgcmVxdWlyZW1lbnQgc3RyaW5nIG9yIE5vbmUgd2hlbiBza2lwcGVkLiIiIgogICAgc2VjdGlvbiA9IHNwbGl0X21hcmtlcihsaW5lKQogICAgaWYgbm90IHNlY3Rpb24gb3Igc2VjdGlvbi5zdGFydHN3aXRoKCcjJyk6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIG1hdGNoID0gTkFNRV9QQVRURVJOLm1hdGNoKHNlY3Rpb24pCiAgICBpZiBub3QgbWF0Y2g6CiAgICAgICAgcmV0dXJuIHNlY3Rpb24uc3RyaXAoKQogICAgbmFtZSwgcmVzdCA9IG1hdGNoLmdyb3VwcygpCiAgICBuYW1lID0gc3RyaXBfZXh0cmFzKG5hbWUpCiAgICByZXR1cm4gKG5hbWUgKyByZXN0KS5zdHJpcCgpCgoKZGVmIG1haW4oKToKICAgICIiIkNMSSBlbnRyeSBwb2ludCB3cml0aW5nIGNvbmRhL3BpcCByZXF1aXJlbWVudCBmaWxlcy4iIiIKICAgIGhhdmVfZmlsZSA9IG9zLnBhdGguZXhpc3RzKElOUCkgYW5kIG9zLnBhdGguZ2V0c2l6ZShJTlApID4gMAogICAgbGluZXMgPSBbXQogICAgaWYgaGF2ZV9maWxlOgogICAgICAgIHdpdGggb3BlbihJTlAsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgIGxpbmVzID0gW25vcm0oaXRlbSkgZm9yIGl0ZW0gaW4gaGFuZGxlIGlmIG5vcm0oaXRlbSldCiAgICBjb25kYV9zcGVjcyA9IFtdCiAgICBwaXBfc3BlY3MgPSBbXQogICAgZm9yIGxpbmUgaW4gbGluZXM6CiAgICAgICAgY29uZGFfc3BlY3MuZXh0ZW5kKHRvX2NvbmRhKGxpbmUpKQogICAgICAgIHBpcF9lbnRyeSA9IHRvX3BpcChsaW5lKQogICAgICAgIGlmIHBpcF9lbnRyeToKICAgICAgICAgICAgcGlwX3NwZWNzLmFwcGVuZChwaXBfZW50cnkpCiAgICBuYW1lc19sb3dlciA9IFtyZS5zcGxpdChyIls8Pj0hfixcc10iLCB2YWx1ZSwgMSlbMF0uc3RyaXAoKS5sb3dlcigpIGZvciB2YWx1ZSBpbiBwaXBfc3BlY3NdCiAgICBpZiAncGFuZGFzJyBpbiBuYW1lc19sb3dlciBhbmQgJ29wZW5weXhsJyBub3QgaW4gbmFtZXNfbG93ZXI6CiAgICAgICAgcGlwX3NwZWNzLmFwcGVuZCgnb3BlbnB5eGwnKQogICAgICAgIGNvbmRhX3NwZWNzLmV4dGVuZChmb3JtYXRfbGluZSgnb3BlbnB5eGwnLCBbXSkpCiAgICB3aXRoIG9wZW4oT1VUX0NPTkRBLCAndycsIGVuY29kaW5nPSdhc2NpaScpIGFzIGhhbmRsZToKICAgICAgICBmb3IgaXRlbSBpbiBjb25kYV9zcGVjczoKICAgICAgICAgICAgaWYgaXRlbToKICAgICAgICAgICAgICAgIGhhbmRsZS53cml0ZShpdGVtICsgJ1xuJykKICAgIHdpdGggb3BlbihPVVRfUElQLCAndycsIGVuY29kaW5nPSdhc2NpaScpIGFzIGhhbmRsZToKICAgICAgICBmb3IgaXRlbSBpbiBwaXBfc3BlY3M6CiAgICAgICAgICAgIGlmIGl0ZW06CiAgICAgICAgICAgICAgICBoYW5kbGUud3JpdGUoaXRlbSArICdcbicpCiAgICBzeXMuc3Rkb3V0LndyaXRlKCdPS1xuJykKCgppZiBfX25hbWVfXyA9PSAnX19tYWluX18nOgogICAgbWFpbigpCiAgICBpZiBsZW4oc3lzLmFyZ3YpID09IDE6CiAgICAgICAgZGVtbyA9IHsKICAgICAgICAgICAgJ3B5dGhvbic6IFsnPj0zLjgnLCAnPDQuMCddLAogICAgICAgICAgICAncmVxdWVzdHMnOiBbJz49Mi4zMS4wJywgJzwzJ10sCiAgICAgICAgICAgICdweWRhbnRpYyc6IFsnID49MiAnLCAnIDwzJ10sCiAgICAgICAgfQogICAgICAgIGZvciBuYW1lLCBzcGVjcyBpbiBkZW1vLml0ZW1zKCk6CiAgICAgICAgICAgIGZvciBsaW5lIGluIGZvcm1hdF9saW5lKG5hbWUsIHNwZWNzKToKICAgICAgICAgICAgICAgIHByaW50KGxpbmUpCg=="
set "HP_DETECT_VISA=aW1wb3J0IG9zLCByZSwgc3lzCgpST09UID0gb3MuZ2V0Y3dkKCkKUEFUVEVSTlMgPSBbCiAgICByIig/bSleXHMqKD86ZnJvbVxzK3B5dmlzfGltcG9ydFxzK3B5dmlzKSIsCiAgICByIig/bSleXHMqaW1wb3J0XHMrdmlzIiwKXQoKZGVmIG5lZWRzX3Zpc2EoKToKICAgIGZvciBjdXJyZW50LCBkaXJzLCBmaWxlcyBpbiBvcy53YWxrKFJPT1QpOgogICAgICAgIGRpcnNbOl0gPSBbaXRlbSBmb3IgaXRlbSBpbiBkaXJzIGlmIG5vdCBpdGVtLnN0YXJ0c3dpdGgoKCd+JywgJy4nKSldCiAgICAgICAgZm9yIG5hbWUgaW4gZmlsZXM6CiAgICAgICAgICAgIGlmIG5vdCBuYW1lLmVuZHN3aXRoKCcucHknKSBvciBuYW1lLnN0YXJ0c3dpdGgoJ34nKToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIHBhdGggPSBvcy5wYXRoLmpvaW4oY3VycmVudCwgbmFtZSkKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgd2l0aCBvcGVuKHBhdGgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgICAgICAgICAgdGV4dCA9IGhhbmRsZS5yZWFkKCkKICAgICAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBmb3IgcGF0dGVybiBpbiBQQVRURVJOUzoKICAgICAgICAgICAgICAgIGlmIHJlLnNlYXJjaChwYXR0ZXJuLCB0ZXh0KToKICAgICAgICAgICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgcmV0dXJuIEZhbHNlCgpkZWYgbWFpbigpOgogICAgc3lzLnN0ZG91dC53cml0ZSgnMScgaWYgbmVlZHNfdmlzYSgpIGVsc2UgJzAnKQoKaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJzoKICAgIG1haW4oKQo="
rem ~find_entry.py emits a normalized crumb, logs it for tests, and skip mode reads its stdout
set "HP_FIND_ENTRY=aW1wb3J0IG9zCmltcG9ydCBzeXMKClBSRUZFUlJFRCA9ICgibWFpbi5weSIsICJhcHAucHkiLCAicnVuLnB5IikKCmRlZiBpc19weShuYW1lOiBzdHIpIC0+IGJvb2w6CiAgICBsb3dlciA9IG5hbWUubG93ZXIoKQogICAgcmV0dXJuIGxvd2VyLmVuZHN3aXRoKCIucHkiKSBhbmQgbm90IGxvd2VyLnN0YXJ0c3dpdGgoIn4iKSBhbmQgb3MucGF0aC5pc2ZpbGUobmFtZSkKCmRlZiBoYXNfbWFpbihwYXRoOiBzdHIpIC0+IGJvb2w6CiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKHBhdGgsICJyIiwgZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJpZ25vcmUiKSBhcyBoYW5kbGU6CiAgICAgICAgICAgIHRleHQgPSBoYW5kbGUucmVhZCgpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0dXJuICJfX21haW5fXyIgaW4gdGV4dAoKZGVmIGVtaXQocGF0aDogc3RyKSAtPiBOb25lOgogICAgY3J1bWIgPSBvcy5wYXRoLm5vcm1wYXRoKHBhdGgpCiAgICBwcmludChjcnVtYikKCmZpbGVzID0gW25hbWUgZm9yIG5hbWUgaW4gb3MubGlzdGRpcigiLiIpIGlmIGlzX3B5KG5hbWUpXQoKZm9yIGNhbmRpZGF0ZSBpbiBQUkVGRVJSRUQ6CiAgICBpZiBjYW5kaWRhdGUgaW4gZmlsZXM6CiAgICAgICAgZW1pdChjYW5kaWRhdGUpCiAgICAgICAgc3lzLmV4aXQoMCkKCmlmIGxlbihmaWxlcykgPT0gMToKICAgIGVtaXQoZmlsZXNbMF0pCiAgICBzeXMuZXhpdCgwKQoKY2FuZGlkYXRlcyA9IFtuYW1lIGZvciBuYW1lIGluIGZpbGVzIGlmIGhhc19tYWluKG5hbWUpXQppZiBsZW4oY2FuZGlkYXRlcykgPT0gMToKICAgIGVtaXQoY2FuZGlkYXRlc1swXSkKICAgIHN5cy5leGl0KDApCg=="
exit /b 0
:log
set "MSG=%~1"
echo %date% %time% %MSG%
>> "%LOG%" echo [%date% %time%] %MSG%
exit /b 0
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
