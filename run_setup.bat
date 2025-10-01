@echo off
setlocal DisableDelayedExpansion
rem Boot strap renamed to run_setup.bat
cd /d "%~dp0"
set "LOG=~setup.log"
set "LOGPREV=~setup.prev.log"
set "STATUS_FILE=~bootstrap.status.json"
if not exist "%LOG%" (type nul > "%LOG%")
if exist "%STATUS_FILE%" del "%STATUS_FILE%"
rem --- CI fast path (entry tests only) ---
call :rotate_log
rem HP_* variables represent "Helper Payload" assets emitted on demand.
call :define_helper_payloads
for %%I in ("%CD%") do set "ENVNAME=%%~nI"

set "PYCOUNT=0"
for /f "delims=" %%F in ('dir /b /a-d *.py 2^>nul') do call :count_python "%%F"
if "%PYCOUNT%"=="" set "PYCOUNT=0"
call :log "[INFO] Python file count: %PYCOUNT%"

if "%PYCOUNT%"=="0" (
  call :log "[INFO] No Python files detected; skipping environment bootstrap."
  call :write_status "no_python_files" 0 0
  goto :success
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
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "iwr https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe -OutFile $env:TEMP\miniconda.exe"
  start /wait "" "%TEMP%\miniconda.exe" /InstallationType=JustMe /AddToPath=0 /RegisterPython=0 /S /D=%MINICONDA_ROOT%
  call :select_conda_bat
)

if not defined CONDA_BAT (
  call :die "[ERROR] conda.bat not found after bootstrap."
)

set "PATH=%MINICONDA_ROOT%\condabin;%MINICONDA_ROOT%\Scripts;%MINICONDA_ROOT%\Library\bin;%MINICONDA_ROOT%;%PATH%"
where conda >> "%LOG%" 2>&1 || call :die "[ERROR] 'conda' not found on PATH after bootstrap."
where python >> "%LOG%" 2>&1 || call :die "[ERROR] 'python' not found on PATH after bootstrap."
python -V >> "%LOG%" 2>&1 || call :die "[ERROR] 'python -V' failed after bootstrap."

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
if errorlevel 1 call :die "[ERROR] conda env create failed."

call :emit_from_base64 "~print_pyver.py" HP_PRINT_PYVER
if errorlevel 1 call :die "[ERROR] Could not write ~print_pyver.py"
call "%CONDA_BAT%" run -n "%ENVNAME%" python "~print_pyver.py" > "~pyver.txt" 2>> "%LOG%"
for /f "usebackq delims=" %%A in ("~pyver.txt") do set "PYVER=%%A"
if not "%PYVER%"=="" ( > "runtime.txt" echo %PYVER% )

rem README.md documents the conda-forge policy for this project and why .condarc is required.
rem Emit the .condarc payload from base64 so quoting stays robust on Windows CMD.
call :emit_from_base64 "~condarc" HP_CONDARC
if errorlevel 1 call :die "[ERROR] Could not stage ~condarc"
if not exist "%ENV_PATH%" mkdir "%ENV_PATH%"
copy /y "~condarc" "%ENV_PATH%\.condarc" >> "%LOG%" 2>&1
if errorlevel 1 call :die "[ERROR] Could not write %ENV_PATH%\.condarc"



call :emit_from_base64 "~prep_requirements.py" HP_PREP_REQUIREMENTS
if errorlevel 1 call :die "[ERROR] Could not write ~prep_requirements.py"
set "REQ=requirements.txt"
if exist "%REQ%" ( for %%S in ("%REQ%") do if %%~zS EQU 0 del "%REQ%" )
call "%CONDA_BAT%" run -n "%ENVNAME%" python -m pip install --upgrade pipreqs >> "%LOG%" 2>&1
set "HP_PIPREQS_STAGE=.~pipreqs_src"
set "HP_PIPREQS_TARGET=%CD%\requirements.auto.txt"
if exist "%HP_PIPREQS_STAGE%" rd /s /q "%HP_PIPREQS_STAGE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$stage = '.~pipreqs_src';" ^
  "$root = Get-Location;" ^
  "Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue;" ^
  "$stageItem = New-Item -ItemType Directory -Force -Path $stage;" ^
  "$stageFull = $stageItem.FullName;" ^
  "$testsRoot = [IO.Path]::Combine($root.Path, 'tests');" ^
  "Get-ChildItem -Path $root -Recurse -Filter *.py | Where-Object { $_.Name -notlike '~*' -and -not $_.FullName.StartsWith($testsRoot, [System.StringComparison]::OrdinalIgnoreCase) -and -not $_.FullName.StartsWith($stageFull, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $rel = $_.FullName.Substring($root.Path.Length).TrimStart('\\'); $dest = Join-Path $stage $rel; $destDir = Split-Path -Parent $dest; if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }; Copy-Item -LiteralPath $_.FullName -Destination $dest -Force }" >> "%LOG%" 2>&1
if exist "%HP_PIPREQS_STAGE%" (
  pushd "%HP_PIPREQS_STAGE%"
  call "%CONDA_BAT%" run -n "%ENVNAME%" pipreqs . --force --mode compat --savepath "%HP_PIPREQS_TARGET%" >> "%LOG%" 2>&1
  popd
)
if exist "%HP_PIPREQS_STAGE%" rd /s /q "%HP_PIPREQS_STAGE%"
if not exist "%REQ%" if exist "requirements.auto.txt" ( copy /y "requirements.auto.txt" "requirements.txt" >> "%LOG%" 2>&1 )
if exist "requirements.txt" if exist "requirements.auto.txt" ( fc "requirements.txt" "requirements.auto.txt" > "~pipreqs.diff.txt" 2>&1 )
if exist "requirements.txt" (
  if exist "~reqs_conda.txt" del "~reqs_conda.txt"
  "%CONDA_BASE_PY%" "~prep_requirements.py" "requirements.txt" >nul 2>> "%LOG%"
  call "%CONDA_BAT%" install -y -n "%ENVNAME%" --file "~reqs_conda.txt" --override-channels -c conda-forge >> "%LOG%" 2>&1
  if errorlevel 1 (
    for /f "usebackq delims=" %%P in ("~reqs_conda.txt") do (
      call "%CONDA_BAT%" install -y -n "%ENVNAME%" --override-channels -c conda-forge %%P >> "%LOG%" 2>&1
    )
  )
  call "%CONDA_BAT%" run -n "%ENVNAME%" python -m pip install -r requirements.txt >> "%LOG%" 2>&1
)
rem Detect pyvisa/visa usage so harness sees NI-VISA requirements

call :emit_from_base64 "~detect_visa.py" HP_DETECT_VISA
if errorlevel 1 call :die "[ERROR] Could not write ~detect_visa.py"
set "NEED_VISA=0"
if exist "~visa.flag" del "~visa.flag"
call "%CONDA_BAT%" run -n "%ENVNAME%" python "~detect_visa.py" > "~visa.flag" 2>> "%LOG%"
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

rem --- locate a Python ---
set "HP_SYS_PY=" & set "HP_SYS_PY_ARGS="
where python >nul 2>&1 && set "HP_SYS_PY=python"
if not defined HP_SYS_PY (
  where py >nul 2>&1 && (set "HP_SYS_PY=py" & set "HP_SYS_PY_ARGS=-3")
)
if not defined HP_SYS_PY (
  if exist "%PUBLIC%\Documents\Miniconda3\python.exe" set "HP_SYS_PY=%PUBLIC%\Documents\Miniconda3\python.exe"
)

rem --- run helper and capture RELATIVE crumb ---
set "HP_CRUMB="
if defined HP_SYS_PY (
  if defined HP_SYS_PY_ARGS (
    for /f "usebackq delims=" %%L in (`"%HP_SYS_PY%" %HP_SYS_PY_ARGS% "~find_entry.py"`) do set "HP_CRUMB=%%L"
  ) else (
    for /f "usebackq delims=" %%L in (`"%HP_SYS_PY%" "~find_entry.py"`) do set "HP_CRUMB=%%L"
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
  call :log "[INFO] Running entry script smoke test via conda run."
  call "%CONDA_BAT%" run -n "%ENVNAME%" python "%HP_ENTRY%" > "~run.out.txt" 2> "~run.err.txt"
  if errorlevel 1 call :die "[ERROR] Entry script execution failed."
  call "%CONDA_BAT%" run -n "%ENVNAME%" python -m pip install -q pyinstaller >> "%LOG%" 2>&1
  call "%CONDA_BAT%" run -n "%ENVNAME%" pyinstaller -y --onefile --name "%ENVNAME%" "%HP_ENTRY%" >> "%LOG%" 2>&1
  if errorlevel 1 call :die "[ERROR] PyInstaller execution failed."
  if not exist "dist\%ENVNAME%.exe" call :die "[ERROR] PyInstaller did not produce dist\%ENVNAME%.exe"
  call :log "[INFO] PyInstaller produced dist\%ENVNAME%.exe"
)

call :write_status "ok" 0 %PYCOUNT%
goto :success

:after_env_skip
call :write_status "ok" 0 %PYCOUNT%
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

:determine_entry
set "HP_ENTRY="
call :emit_from_base64 "~find_entry.py" HP_FIND_ENTRY
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$skip = [bool][Environment]::GetEnvironmentVariable('HP_CI_SKIP_ENV');" ^
  "if ($skip) {" ^
  "  if (Get-Command python -ErrorAction SilentlyContinue) {" ^
  "    $out = & python '~find_entry.py'" ^
  "  } elseif (Get-Command py -ErrorAction SilentlyContinue) {" ^
  "    $out = & py '~find_entry.py'" ^
  "  } else {" ^
  "    Write-Host '[WARN] find_entry: no system Python found'" ^
  "    $out = ''" ^
  "  }" ^
  "} else {" ^
  "  $pyExe = '%CONDA_BASE_PY%';" ^
  "  if ($pyExe -and (Test-Path $pyExe)) {" ^
  "    $out = & $pyExe '~find_entry.py'" ^
  "  } else {" ^
  "    $out = & '%CONDA_BAT%' run -n '%ENVNAME%' python '~find_entry.py'" ^
  "  }" ^
  "}" ^
  "; if ($out) { Set-Content -Path '~entry.txt' -Value $out -Encoding ASCII -NoNewline } else { Set-Content -Path '~entry.txt' -Value '' -Encoding ASCII }" >> "%LOG%" 2>&1
if errorlevel 1 exit /b 1
if exist "~entry.txt" (
  for /f "usebackq delims=" %%M in ("~entry.txt") do set "HP_ENTRY=%%M"
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
:write_status
set "STATE=%~1"
set "RC=%~2"
set "COUNT=%~3"
if "%STATE%"=="" set "STATE=error"
if "%RC%"=="" set "RC=0"
if "%COUNT%"=="" set "COUNT=%PYCOUNT%"
> "%STATUS_FILE%" echo {"state":"%STATE%","exitCode":%RC%,"pyFiles":%COUNT%}
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
rem ~find_entry.py emits a normalized crumb, logs it for tests, and writes ~entry.abs for skip mode
set "HP_FIND_ENTRY=aW1wb3J0IG9zCmltcG9ydCBzeXMKCkxPR19UQVJHRVQgPSBvcy5wYXRoLmpvaW4oJ3Rlc3RzJywgJ35zZXR1cC5sb2cnKQpBQlNfVEFSR0VUID0gb3MucGF0aC5qb2luKCcuJywgJ35lbnRyeS5hYnMnKQoKCmRlZiBub3JtYWxpemVkX2VudHJ5KGVudHJ5OiBzdHIpIC0+IHN0cjoKICAgIGlmIG5vdCBlbnRyeToKICAgICAgICByZXR1cm4gJycKICAgIHJldHVybiBvcy5wYXRoLmpvaW4oJy4nLCBlbnRyeSkucmVwbGFjZSgnLycsICdcJykKCgpkZWYgbG9nX2JyZWFkY3J1bWIoZW50cnk6IHN0cikgLT4gTm9uZToKICAgIGNydW1iID0gbm9ybWFsaXplZF9lbnRyeShlbnRyeSkKICAgIGlmIG5vdCBjcnVtYjoKICAgICAgICByZXR1cm4KICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4oTE9HX1RBUkdFVCwgJ2EnLCBlbmNvZGluZz0nYXNjaWknLCBlcnJvcnM9J2lnbm9yZScpIGFzIGhhbmRsZToKICAgICAgICAgICAgaGFuZGxlLndyaXRlKGYiQ2hvc2VuIGVudHJ5OiB7Y3J1bWJ9CiIpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKCgpkZWYgd3JpdGVfYWJzb2x1dGUoZW50cnk6IHN0cikgLT4gTm9uZToKICAgIGlmIG5vdCBlbnRyeToKICAgICAgICByZXR1cm4KICAgIHRyeToKICAgICAgICBhYnNfcGF0aCA9IG9zLnBhdGguYWJzcGF0aChlbnRyeSkKICAgICAgICB3aXRoIG9wZW4oQUJTX1RBUkdFVCwgJ3cnLCBlbmNvZGluZz0nYXNjaWknLCBlcnJvcnM9J2lnbm9yZScpIGFzIGhhbmRsZToKICAgICAgICAgICAgaGFuZGxlLndyaXRlKGFic19wYXRoKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCgoKZGVmIHByZWZlcl9jYW5kaWRhdGVzKGZpbGVzKToKICAgIGZvciBjYW5kaWRhdGUgaW4gKCdtYWluLnB5JywgJ2FwcC5weScsICdpbmRleC5weScpOgogICAgICAgIGlmIGNhbmRpZGF0ZSBpbiBmaWxlczoKICAgICAgICAgICAgcmV0dXJuIGNhbmRpZGF0ZQogICAgcmV0dXJuICcnCgoKZGVmIHByZWZlcl9ndWFyZGVkKGZpbGVzKToKICAgIGZvciBuYW1lIGluIGZpbGVzOgogICAgICAgIHRyeToKICAgICAgICAgICAgd2l0aCBvcGVuKG5hbWUsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgICAgICBpZiAiaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJyIgaW4gaGFuZGxlLnJlYWQoKToKICAgICAgICAgICAgICAgICAgICByZXR1cm4gbmFtZQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICByZXR1cm4gJycKCgpkZWYgZmluZF9lbnRyeSgpOgogICAgZmlsZXMgPSBbbmFtZSBmb3IgbmFtZSBpbiBvcy5saXN0ZGlyKCcuJyksaWYgbmFtZS5lbmRzd2l0aCgnLnB5JykgYW5kIG5vdCBuYW1lLnN0YXJ0c3dpdGgoJ34nKV0KICAgIGZpbGVzLnNvcnQoKQoKICAgIGNob3NlbiA9IHByZWZlcl9jYW5kaWRhdGVzKGZpbGVzKQogICAgaWYgbm90IGNob3NlbjoKICAgICAgICBjaG9zZW4gPSBwcmVmZXJfZ3VhcmRlZChmaWxlcykKICAgIGlmIG5vdCBjaG9zZW4gYW5kIGZpbGVzOgogICAgICAgIGNob3NlbiA9IGZpbGVzWzBdCgogICAgaWYgY2hvc2VuOgogICAgICAgIGxvZ19icmVhZGNydW1iKGNob3NlbikKICAgICAgICB3cml0ZV9hYnNvbHV0ZShjaG9zZW4pCiAgICByZXR1cm4gY2hvc2VuCgoKaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJzoKICAgIGVudHJ5ID0gZmluZF9lbnRyeSgpCiAgICBjcnVtYiA9IG5vcm1hbGl6ZWRfZW50cnkoZW50cnkpCiAgICBzeXMuc3Rkb3V0LndyaXRlKGNydW1iKQogICAgc3lzLmV4aXQoMCBpZiBjcnVtYiBlbHNlIDEp"
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
