@echo off
setlocal DisableDelayedExpansion
rem Boot strap renamed to run_setup.bat
cd /d "%~dp0"
set "LOG=~setup.log"
set "LOGPREV=~setup.prev.log"
set "STATUS_FILE=~bootstrap.status.json"
if not exist "%LOG%" (type nul > "%LOG%")
if exist "%STATUS_FILE%" del "%STATUS_FILE%"
call :rotate_log
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

rem === Miniconda location (non-admin) =========================================
set "MINICONDA_ROOT=%PUBLIC%\Documents\Miniconda3"
set "CONDA_BAT=%MINICONDA_ROOT%\condabin\conda.bat"
if not exist "%CONDA_BAT%" set "CONDA_BAT=%MINICONDA_ROOT%\Scripts\conda.bat"
set "CONDA_BASE_PY=%MINICONDA_ROOT%\python.exe"

rem Install Miniconda if conda.bat is missing
if not exist "%CONDA_BAT%" (
  echo [INFO] Installing Miniconda into "%MINICONDA_ROOT%"...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "iwr https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe -OutFile $env:TEMP\miniconda.exe"
  start /wait "" "%TEMP%\miniconda.exe" /InstallationType=JustMe /AddToPath=0 /RegisterPython=0 /S /D=%MINICONDA_ROOT%
  set "CONDA_BAT=%MINICONDA_ROOT%\condabin\conda.bat"
  if not exist "%CONDA_BAT%" set "CONDA_BAT=%MINICONDA_ROOT%\Scripts\conda.bat"
)

if not exist "%CONDA_BAT%" (
  call :die "[ERROR] conda.bat not found after bootstrap."
)

set "PATH=%MINICONDA_ROOT%\condabin;%MINICONDA_ROOT%\Scripts;%MINICONDA_ROOT%\Library\bin;%MINICONDA_ROOT%;%PATH%"
where conda >> "%LOG%" 2>&1 || call :die "[ERROR] 'conda' not found on PATH after bootstrap."
where python >> "%LOG%" 2>&1 || call :die "[ERROR] 'python' not found on PATH after bootstrap."
python -V >> "%LOG%" 2>&1 || call :die "[ERROR] 'python -V' failed after bootstrap."

rem === Channel policy (determinism & legal) ===================================
call "%CONDA_BAT%" config --name base --add channels conda-forge
call "%CONDA_BAT%" config --name base --remove channels defaults

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
call "%CONDA_BAT%" run -n "%ENVNAME%" python -m pip install -q -U pip pipreqs >> "%LOG%" 2>&1
call "%CONDA_BAT%" run -n "%ENVNAME%" python -m pipreqs . --force --mode compat --savepath requirements.auto.txt >> "%LOG%" 2>&1
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

call :emit_from_base64 "~find_entry.py" HP_FIND_ENTRY
if errorlevel 1 call :die "[ERROR] Could not write ~find_entry.py"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$pyExe = '%CONDA_BASE_PY%'; if (Test-Path $pyExe) { $out = & $pyExe '~find_entry.py' } else { $out = & '%CONDA_BAT%' run -n '%ENVNAME%' python '~find_entry.py' } if ($out) { Set-Content -Path '~entry.txt' -Value $out -Encoding ASCII -NoNewline } else { Set-Content -Path '~entry.txt' -Value '' -Encoding ASCII }" >> "%LOG%" 2>&1
if errorlevel 1 call :die "[ERROR] Could not determine entry point"
set "ENTRY="
for /f "usebackq delims=" %%M in ("~entry.txt") do set "ENTRY=%%M"
if "%ENTRY%"=="" (
  call :log "[INFO] No entry script detected; skipping PyInstaller packaging."
) else (
  call :log "[INFO] Running entry script smoke test via conda run."
  call "%CONDA_BAT%" run -n "%ENVNAME%" python "%ENTRY%" > "~run.out.txt" 2> "~run.err.txt"
  if errorlevel 1 call :die "[ERROR] Entry script execution failed."
  call "%CONDA_BAT%" run -n "%ENVNAME%" python -m pip install -q pyinstaller >> "%LOG%" 2>&1
  call "%CONDA_BAT%" run -n "%ENVNAME%" pyinstaller -y --onefile --name "%ENVNAME%" "%ENTRY%" >> "%LOG%" 2>&1
  if errorlevel 1 call :die "[ERROR] PyInstaller execution failed."
  if not exist "dist\%ENVNAME%.exe" call :die "[ERROR] PyInstaller did not produce dist\%ENVNAME%.exe"
  call :log "[INFO] PyInstaller produced dist\%ENVNAME%.exe"
)

call :write_status "ok" 0 %PYCOUNT%

:success
exit /b 0
:count_python
set "NAME=%~1"
if "%NAME%"=="" exit /b 0
if "%NAME:~0,1%"=="~" exit /b 0
set /a PYCOUNT+=1 >nul
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
set "HP_DETECT_PY=aW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc3lzCgojIEhlbHBlciBpbXBsZW1lbnRzIHRoZSBSRUFETUUgYm9vdHN0cmFwIGNvbnRyYWN0LiBQRVAgNDQwIGRldGFpbHM6CiMgaHR0cHM6Ly9wZXBzLnB5dGhvbi5vcmcvcGVwLTA0NDAvCgpDRCA9IG9zLmdldGN3ZCgpClJVTlRJTUVfUEFUSCA9IG9zLnBhdGguam9pbihDRCwgInJ1bnRpbWUudHh0IikKUFlQUk9KRUNUX1BBVEggPSBvcy5wYXRoLmpvaW4oQ0QsICJweXByb2plY3QudG9tbCIpClBZUFJPSkVDVF9SRSA9IHJlLmNvbXBpbGUociJyZXF1aXJlcy1weXRob25ccyo9XHMqWydcIl0oW14nXCJdKylbJ1wiXSIsIHJlLklHTk9SRUNBU0UpClNQRUNfUEFUVEVSTiA9IHJlLmNvbXBpbGUocicofj18PT18IT18Pj18PD18Pnw8KVxzKihbMC05XSsoPzpcLlswLTldKykqKScpCk9SREVSID0geyI9PSI6IDAsICIhPSI6IDEsICI+PSI6IDIsICI+IjogMywgIjw9IjogNCwgIjwiOiA1fQoKCmRlZiB2ZXJzaW9uX2tleSh0ZXh0OiBzdHIpOgogICAgIiIiUmV0dXJuIGEgdHVwbGUgdXNhYmxlIGZvciBudW1lcmljIG9yZGVyaW5nIG9mIGRvdHRlZCB2ZXJzaW9ucy4iIiIKICAgIHBhcnRzID0gW10KICAgIGZvciBjaHVuayBpbiB0ZXh0LnNwbGl0KCcuJyk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBwYXJ0cy5hcHBlbmQoaW50KGNodW5rKSkKICAgICAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgcGFydHMuYXBwZW5kKDApCiAgICByZXR1cm4gdHVwbGUocGFydHMpCgoKZGVmIGJ1bXBfZm9yX2NvbXBhdGlibGUodmVyc2lvbjogc3RyKSAtPiBzdHI6CiAgICAiIiJUcmFuc2xhdGUgdGhlIFBFUCA0NDAgY29tcGF0aWJsZSByZWxlYXNlIHVwcGVyIGJvdW5kLiIiIgogICAgcGllY2VzID0gW2ludChpdGVtKSBmb3IgaXRlbSBpbiB2ZXJzaW9uLnNwbGl0KCcuJykgaWYgaXRlbS5pc2RpZ2l0KCldCiAgICBpZiBub3QgcGllY2VzOgogICAgICAgIHJldHVybiB2ZXJzaW9uCiAgICBpZiBsZW4ocGllY2VzKSA+PSAzOgogICAgICAgIHJldHVybiBmIntwaWVjZXNbMF19LntwaWVjZXNbMV0gKyAxfSIKICAgIGlmIGxlbihwaWVjZXMpID09IDI6CiAgICAgICAgcmV0dXJuIGYie3BpZWNlc1swXSArIDF9LjAiCiAgICByZXR1cm4gc3RyKHBpZWNlc1swXSArIDEpCgoKZGVmIGV4cGFuZF9jbGF1c2Uob3A6IHN0ciwgdmVyc2lvbjogc3RyKToKICAgIGlmIG9wID09ICJ+PSI6CiAgICAgICAgdXBwZXIgPSBidW1wX2Zvcl9jb21wYXRpYmxlKHZlcnNpb24pCiAgICAgICAgcmV0dXJuIFsoIj49IiwgdmVyc2lvbiksICgiPCIsIHVwcGVyKV0KICAgIHJldHVybiBbKG9wLCB2ZXJzaW9uKV0KCgpkZWYgcGVwNDQwX3RvX2NvbmRhKHNwZWM6IHN0cikgLT4gc3RyOgogICAgIiIiQ29udmVydCBhIFBFUCA0NDAgcmVxdWlyZXMtcHl0aG9uIHN0cmluZyBpbnRvIGNvbmRhIGNvbnN0cmFpbnRzLiIiIgogICAgY2xhdXNlcyA9IFtdCiAgICBmb3IgcmF3IGluIHNwZWMuc3BsaXQoJywnKToKICAgICAgICByYXcgPSByYXcuc3RyaXAoKQogICAgICAgIGlmIG5vdCByYXc6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgbWF0Y2ggPSBTUEVDX1BBVFRFUk4ubWF0Y2gocmF3KQogICAgICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBvcCwgdmVyc2lvbiA9IG1hdGNoLmdyb3VwcygpCiAgICAgICAgY2xhdXNlcy5leHRlbmQoZXhwYW5kX2NsYXVzZShvcCwgdmVyc2lvbikpCiAgICBpZiBub3QgY2xhdXNlczoKICAgICAgICByZXR1cm4gIiIKICAgIGRlZHVwID0ge30KICAgIGZvciBvcCwgdmVyc2lvbiBpbiBjbGF1c2VzOgogICAgICAgIGRlZHVwWyhvcCwgdmVyc2lvbildID0gKG9wLCB2ZXJzaW9uKQogICAgb3JkZXJlZCA9IHNvcnRlZChkZWR1cC52YWx1ZXMoKSwga2V5PWxhbWJkYSBpdGVtOiAoT1JERVIuZ2V0KGl0ZW1bMF0sIDk5KSwgdmVyc2lvbl9rZXkoaXRlbVsxXSkpKQogICAgcmV0dXJuICJweXRob24iICsgIiwiLmpvaW4oZiJ7b3B9e3ZlcnNpb259IiBmb3Igb3AsIHZlcnNpb24gaW4gb3JkZXJlZCkKCgpkZWYgcmVhZF9ydW50aW1lX3NwZWMoKSAtPiBzdHI6CiAgICBpZiBub3Qgb3MucGF0aC5leGlzdHMoUlVOVElNRV9QQVRIKToKICAgICAgICByZXR1cm4gIiIKICAgIHdpdGggb3BlbihSVU5USU1FX1BBVEgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgdGV4dCA9IGhhbmRsZS5yZWFkKCkKICAgIG1hdGNoID0gcmUuc2VhcmNoKHInKD86cHl0aG9uWy09XSk/XHMqKFswLTldKyg/OlwuWzAtOV0rKXswLDJ9KScsIHRleHQpCiAgICBpZiBub3QgbWF0Y2g6CiAgICAgICAgcmV0dXJuICIiCiAgICBwYXJ0cyA9IG1hdGNoLmdyb3VwKDEpLnNwbGl0KCcuJykKICAgIG1ham9yX21pbm9yID0gJy4nLmpvaW4ocGFydHNbOjJdKQogICAgcmV0dXJuIGYncHl0aG9uPXttYWpvcl9taW5vcn0nCgoKZGVmIHJlYWRfcHlwcm9qZWN0X3NwZWMoKSAtPiBzdHI6CiAgICBpZiBub3Qgb3MucGF0aC5leGlzdHMoUFlQUk9KRUNUX1BBVEgpOgogICAgICAgIHJldHVybiAiIgogICAgd2l0aCBvcGVuKFBZUFJPSkVDVF9QQVRILCAncicsIGVuY29kaW5nPSd1dGYtOCcsIGVycm9ycz0naWdub3JlJykgYXMgaGFuZGxlOgogICAgICAgIHRleHQgPSBoYW5kbGUucmVhZCgpCiAgICBtYXRjaCA9IFBZUFJPSkVDVF9SRS5zZWFyY2godGV4dCkKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByZXR1cm4gIiIKICAgIHJldHVybiBwZXA0NDBfdG9fY29uZGEobWF0Y2guZ3JvdXAoMSkpCgoKZGVmIGRldGVjdF9yZXF1aXJlc19weXRob24oKSAtPiBzdHI6CiAgICBydW50aW1lX3NwZWMgPSByZWFkX3J1bnRpbWVfc3BlYygpCiAgICBpZiBydW50aW1lX3NwZWM6CiAgICAgICAgcmV0dXJuIHJ1bnRpbWVfc3BlYwogICAgcmV0dXJuIHJlYWRfcHlwcm9qZWN0X3NwZWMoKQoKCmRlZiBtYWluKGFyZ3Y9Tm9uZSkgLT4gTm9uZToKICAgIGFyZ3MgPSBsaXN0KHN5cy5hcmd2WzE6XSBpZiBhcmd2IGlzIE5vbmUgZWxzZSBhcmd2KQogICAgaWYgYXJncyBhbmQgYXJnc1swXSA9PSAiLS1zZWxmLXRlc3QiOgogICAgICAgIGZvciBzYW1wbGUgaW4gKCJ+PTMuMTAiLCAifj0zLjguMSIpOgogICAgICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKHBlcDQ0MF90b19jb25kYShzYW1wbGUpICsgIlxuIikKICAgICAgICByZXR1cm4KICAgIGlmIGFyZ3M6CiAgICAgICAgZm9yIGl0ZW0gaW4gYXJnczoKICAgICAgICAgICAgc3lzLnN0ZG91dC53cml0ZShwZXA0NDBfdG9fY29uZGEoaXRlbSkgKyAiXG4iKQogICAgICAgIHJldHVybgogICAgc3lzLnN0ZG91dC53cml0ZShkZXRlY3RfcmVxdWlyZXNfcHl0aG9uKCkgKyAiXG4iKQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK"
set "HP_PRINT_PYVER=aW1wb3J0IHN5cwoKcHJpbnQoZiJweXRob24te3N5cy52ZXJzaW9uX2luZm9bMF19LntzeXMudmVyc2lvbl9pbmZvWzFdfSIpCg=="
set "HP_PREP_REQUIREMENTS=aW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc3lzCgojIE1pcnJvcnMgUkVBRE1FIGd1aWRhbmNlIGZvciByZWdlbmVyYXRpbmcgaGVscGVyIHBheWxvYWRzLgojIFBhY2thZ2luZyBhbmQgc3BlYyBmb3JtYXR0aW5nIHJlZmVyZW5jZXM6CiMgaHR0cHM6Ly9wYWNrYWdpbmcucHl0aG9uLm9yZy9lbi9sYXRlc3Qvc3BlY2lmaWNhdGlvbnMvZGVjbGFyaW5nLXByb2plY3QtbWV0YWRhdGEvCgpJTlAgPSBzeXMuYXJndlsxXSBpZiBsZW4oc3lzLmFyZ3YpID4gMSBlbHNlICdyZXF1aXJlbWVudHMudHh0JwpPVVRfQ09OREEgPSAnfnJlcXNfY29uZGEudHh0JwpPVVRfUElQID0gJ35yZXFzX3BpcC50eHQnClNQRUNfUEFUVEVSTiA9IHJlLmNvbXBpbGUocicofj18PT18IT18Pj18PD18Pnw8KVxzKihbMC05XSsoPzpcLlswLTldKykqKScpClNQRUNfRlJBR01FTlQgPSByZS5jb21waWxlKHInXig9PXwhPXw+PXw8PXw+fDwpXHMqKFswLTldKyg/OlwuWzAtOV0rKSopJCcpCk9SREVSID0geyc9PSc6IDAsICchPSc6IDEsICc+PSc6IDIsICc+JzogMywgJzw9JzogNCwgJzwnOiA1fQoKCmRlZiBub3JtKHRleHQ6IHN0cikgLT4gc3RyOgogICAgcmV0dXJuIHRleHQuc3RyaXAoKQoKCmRlZiBzcGxpdF9tYXJrZXIodGV4dDogc3RyKSAtPiBzdHI6CiAgICByZXR1cm4gdGV4dC5zcGxpdCgnOycpWzBdLnN0cmlwKCkKCgpkZWYgc3RyaXBfZXh0cmFzKG5hbWU6IHN0cikgLT4gc3RyOgogICAgcmV0dXJuIHJlLnN1YihyIlxbLio/XF0iLCAnJywgbmFtZSkKCgpkZWYgdmVyc2lvbl9rZXkodGV4dDogc3RyKToKICAgIHBhcnRzID0gW10KICAgIGZvciBjaHVuayBpbiB0ZXh0LnNwbGl0KCcuJyk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBwYXJ0cy5hcHBlbmQoaW50KGNodW5rKSkKICAgICAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgcGFydHMuYXBwZW5kKDApCiAgICByZXR1cm4gdHVwbGUocGFydHMpCgoKZGVmIGJ1bXBfZm9yX2NvbXBhdGlibGUodmFsdWU6IHN0cikgLT4gc3RyOgogICAgaXRlbXMgPSBbaW50KHBpZWNlKSBmb3IgcGllY2UgaW4gdmFsdWUuc3BsaXQoJy4nKSBpZiBwaWVjZS5pc2RpZ2l0KCldCiAgICBpZiBub3QgaXRlbXM6CiAgICAgICAgcmV0dXJuIHZhbHVlCiAgICBpZiBsZW4oaXRlbXMpID49IDM6CiAgICAgICAgcmV0dXJuIGYie2l0ZW1zWzBdfS57aXRlbXNbMV0gKyAxfSIKICAgIGlmIGxlbihpdGVtcykgPT0gMjoKICAgICAgICByZXR1cm4gZiJ7aXRlbXNbMF0gKyAxfS4wIgogICAgcmV0dXJuIHN0cihpdGVtc1swXSArIDEpCgoKZGVmIG5vcm1hbGl6ZV9zcGVjaWZpZXJzKHJlc3Q6IHN0cik6CiAgICBjbGF1c2VzID0gW10KICAgIGZvciBjaHVuayBpbiByZXN0LnNwbGl0KCcsJyk6CiAgICAgICAgY2h1bmsgPSBjaHVuay5zdHJpcCgpCiAgICAgICAgaWYgbm90IGNodW5rOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIG1hdGNoID0gU1BFQ19QQVRURVJOLm1hdGNoKGNodW5rKQogICAgICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBvcCwgdmVyID0gbWF0Y2guZ3JvdXBzKCkKICAgICAgICBpZiBvcCA9PSAnfj0nOgogICAgICAgICAgICB1cHBlciA9IGJ1bXBfZm9yX2NvbXBhdGlibGUodmVyKQogICAgICAgICAgICBjbGF1c2VzLmFwcGVuZCgoJz49JywgdmVyKSkKICAgICAgICAgICAgY2xhdXNlcy5hcHBlbmQoKCc8JywgdXBwZXIpKQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGNsYXVzZXMuYXBwZW5kKChvcCwgdmVyKSkKICAgIHJldHVybiBbZiJ7b3B9e3Zlcn0iIGZvciBvcCwgdmVyIGluIGNsYXVzZXNdCgoKZGVmIGNhbm9uaWNhbF9zcGVjcyhzcGVjcyk6CiAgICBkZWR1cCA9IHt9CiAgICBmb3IgcmF3IGluIHNwZWNzOgogICAgICAgIG1hdGNoID0gU1BFQ19GUkFHTUVOVC5tYXRjaChyYXcpCiAgICAgICAgaWYgbm90IG1hdGNoOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIG9wLCB2ZXIgPSBtYXRjaC5ncm91cHMoKQogICAgICAgIGRlZHVwWyhvcCwgdmVyKV0gPSAob3AsIHZlcikKICAgIG9yZGVyZWQgPSBzb3J0ZWQoZGVkdXAudmFsdWVzKCksIGtleT1sYW1iZGEgaXRlbTogKE9SREVSLmdldChpdGVtWzBdLCA5OSksIHZlcnNpb25fa2V5KGl0ZW1bMV0pKSkKICAgIHJldHVybiBbZiJ7b3B9e3Zlcn0iIGZvciBvcCwgdmVyIGluIG9yZGVyZWRdCgoKZGVmIGZvcm1hdF9saW5lKG5hbWU6IHN0ciwgc3BlY3MpOgogICAgb3BzID0gY2Fub25pY2FsX3NwZWNzKHNwZWNzKQogICAgcmV0dXJuIGYie25hbWV9ICIgKyAiLCIuam9pbihvcHMpIGlmIG9wcyBlbHNlIG5hbWUKCgpkZWYgdG9fY29uZGEobGluZTogc3RyKToKICAgIHNlY3Rpb24gPSBzcGxpdF9tYXJrZXIobGluZSkKICAgIGlmIG5vdCBzZWN0aW9uIG9yIHNlY3Rpb24uc3RhcnRzd2l0aCgnIycpOgogICAgICAgIHJldHVybiBbXQogICAgbG93ZXJlZCA9IHNlY3Rpb24ubG93ZXIoKQogICAgaWYgbG93ZXJlZC5zdGFydHN3aXRoKCctZSAnKSBvciBsb3dlcmVkLnN0YXJ0c3dpdGgoJy0tZWRpdGFibGUnKSBvciBsb3dlcmVkLnN0YXJ0c3dpdGgoJ2dpdCsnKSBvciAnOi8vJyBpbiBzZWN0aW9uOgogICAgICAgIHJldHVybiBbXQogICAgbWF0Y2ggPSByZS5tYXRjaChyIl5ccyooW0EtWmEtejAtOV8uLV0rKVxzKiguKikkIiwgc2VjdGlvbikKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByZXR1cm4gW10KICAgIG5hbWUsIHJlc3QgPSBtYXRjaC5ncm91cCgxKSwgbWF0Y2guZ3JvdXAoMikKICAgIG5hbWUgPSBzdHJpcF9leHRyYXMobmFtZSkKICAgIHJlc3QgPSByZS5zdWIociJcWy4qP1xdIiwgJycsIHJlc3QpCiAgICBzcGVjcyA9IG5vcm1hbGl6ZV9zcGVjaWZpZXJzKHJlc3QpCiAgICBpZiBzcGVjczoKICAgICAgICByZXR1cm4gW2Zvcm1hdF9saW5lKG5hbWUsIHNwZWNzKV0KICAgIHJldHVybiBbbmFtZV0KCgpkZWYgdG9fcGlwKGxpbmU6IHN0cik6CiAgICBzZWN0aW9uID0gc3BsaXRfbWFya2VyKGxpbmUpCiAgICBpZiBub3Qgc2VjdGlvbiBvciBzZWN0aW9uLnN0YXJ0c3dpdGgoJyMnKToKICAgICAgICByZXR1cm4gTm9uZQogICAgbWF0Y2ggPSByZS5tYXRjaChyIl5ccyooW0EtWmEtejAtOV8uLV0rKSguKikkIiwgc2VjdGlvbikKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByZXR1cm4gc2VjdGlvbi5zdHJpcCgpCiAgICBuYW1lLCByZXN0ID0gbWF0Y2guZ3JvdXAoMSksIG1hdGNoLmdyb3VwKDIpCiAgICBuYW1lID0gc3RyaXBfZXh0cmFzKG5hbWUpCiAgICByZXR1cm4gKG5hbWUgKyByZXN0KS5zdHJpcCgpCgoKZGVmIG1haW4oKToKICAgIGhhdmVfZmlsZSA9IG9zLnBhdGguZXhpc3RzKElOUCkgYW5kIG9zLnBhdGguZ2V0c2l6ZShJTlApID4gMAogICAgbGluZXMgPSBbXQogICAgaWYgaGF2ZV9maWxlOgogICAgICAgIHdpdGggb3BlbihJTlAsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgIGxpbmVzID0gW25vcm0oaXRlbSkgZm9yIGl0ZW0gaW4gaGFuZGxlIGlmIG5vcm0oaXRlbSldCiAgICBjb25kYV9zcGVjcyA9IFtdCiAgICBwaXBfc3BlY3MgPSBbXQogICAgZm9yIGxpbmUgaW4gbGluZXM6CiAgICAgICAgY29uZGFfc3BlY3MuZXh0ZW5kKHRvX2NvbmRhKGxpbmUpKQogICAgICAgIHBpcF9lbnRyeSA9IHRvX3BpcChsaW5lKQogICAgICAgIGlmIHBpcF9lbnRyeToKICAgICAgICAgICAgcGlwX3NwZWNzLmFwcGVuZChwaXBfZW50cnkpCiAgICBuYW1lc19sb3dlciA9IFtyZS5zcGxpdChyIls8Pj0hfixcc10iLCB2YWx1ZSwgMSlbMF0uc3RyaXAoKS5sb3dlcigpIGZvciB2YWx1ZSBpbiBwaXBfc3BlY3NdCiAgICBpZiAncGFuZGFzJyBpbiBuYW1lc19sb3dlciBhbmQgJ29wZW5weXhsJyBub3QgaW4gbmFtZXNfbG93ZXI6CiAgICAgICAgcGlwX3NwZWNzLmFwcGVuZCgnb3BlbnB5eGwnKQogICAgICAgIGNvbmRhX3NwZWNzLmFwcGVuZCgnb3BlbnB5eGwnKQogICAgd2l0aCBvcGVuKE9VVF9DT05EQSwgJ3cnLCBlbmNvZGluZz0nYXNjaWknKSBhcyBoYW5kbGU6CiAgICAgICAgZm9yIGl0ZW0gaW4gY29uZGFfc3BlY3M6CiAgICAgICAgICAgIGlmIGl0ZW06CiAgICAgICAgICAgICAgICBoYW5kbGUud3JpdGUoaXRlbSArICdcbicpCiAgICB3aXRoIG9wZW4oT1VUX1BJUCwgJ3cnLCBlbmNvZGluZz0nYXNjaWknKSBhcyBoYW5kbGU6CiAgICAgICAgZm9yIGl0ZW0gaW4gcGlwX3NwZWNzOgogICAgICAgICAgICBpZiBpdGVtOgogICAgICAgICAgICAgICAgaGFuZGxlLndyaXRlKGl0ZW0gKyAnXG4nKQogICAgc3lzLnN0ZG91dC53cml0ZSgnT0tcbicpCgoKaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJzoKICAgIG1haW4oKQogICAgaWYgbGVuKHN5cy5hcmd2KSA9PSAxOgogICAgICAgIGRlbW8gPSB7J3B5dGhvbic6IFsnPj0zLjgnLCAnPDQuMCddLCAncmVxdWVzdHMnOiBbJz49Mi4zMS4wJywgJzwzJ119CiAgICAgICAgZm9yIG5hbWUsIHNwZWNzIGluIGRlbW8uaXRlbXMoKToKICAgICAgICAgICAgcHJpbnQoZm9ybWF0X2xpbmUobmFtZSwgc3BlY3MpKQo="
set "HP_DETECT_VISA=aW1wb3J0IG9zLCByZSwgc3lzCgpST09UID0gb3MuZ2V0Y3dkKCkKUEFUVEVSTlMgPSBbCiAgICByIig/bSleXHMqKD86ZnJvbVxzK3B5dmlzfGltcG9ydFxzK3B5dmlzKSIsCiAgICByIig/bSleXHMqaW1wb3J0XHMrdmlzIiwKXQoKZGVmIG5lZWRzX3Zpc2EoKToKICAgIGZvciBjdXJyZW50LCBkaXJzLCBmaWxlcyBpbiBvcy53YWxrKFJPT1QpOgogICAgICAgIGRpcnNbOl0gPSBbaXRlbSBmb3IgaXRlbSBpbiBkaXJzIGlmIG5vdCBpdGVtLnN0YXJ0c3dpdGgoKCd+JywgJy4nKSldCiAgICAgICAgZm9yIG5hbWUgaW4gZmlsZXM6CiAgICAgICAgICAgIGlmIG5vdCBuYW1lLmVuZHN3aXRoKCcucHknKSBvciBuYW1lLnN0YXJ0c3dpdGgoJ34nKToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIHBhdGggPSBvcy5wYXRoLmpvaW4oY3VycmVudCwgbmFtZSkKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgd2l0aCBvcGVuKHBhdGgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgICAgICAgICAgdGV4dCA9IGhhbmRsZS5yZWFkKCkKICAgICAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBmb3IgcGF0dGVybiBpbiBQQVRURVJOUzoKICAgICAgICAgICAgICAgIGlmIHJlLnNlYXJjaChwYXR0ZXJuLCB0ZXh0KToKICAgICAgICAgICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgcmV0dXJuIEZhbHNlCgpkZWYgbWFpbigpOgogICAgc3lzLnN0ZG91dC53cml0ZSgnMScgaWYgbmVlZHNfdmlzYSgpIGVsc2UgJzAnKQoKaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJzoKICAgIG1haW4oKQo="
set "HP_FIND_ENTRY=aW1wb3J0IG9zCgpkZWYgZmluZF9lbnRyeSgpOgogICAgZmlsZXMgPSBbbmFtZSBmb3IgbmFtZSBpbiBvcy5saXN0ZGlyKCcuJykgaWYgbmFtZS5lbmRzd2l0aCgnLnB5JykgYW5kIG5vdCBuYW1lLnN0YXJ0c3dpdGgoJ34nKV0KICAgIGZvciBuYW1lIGluIGZpbGVzOgogICAgICAgIHRyeToKICAgICAgICAgICAgd2l0aCBvcGVuKG5hbWUsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgICAgICB0ZXh0ID0gaGFuZGxlLnJlYWQoKQogICAgICAgICAgICBpZiAiaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJyIgaW4gdGV4dDoKICAgICAgICAgICAgICAgIHJldHVybiBuYW1lCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgY29udGludWUKICAgIHJldHVybiBmaWxlc1swXSBpZiBmaWxlcyBlbHNlICcnCgpwcmludChmaW5kX2VudHJ5KCkpCg=="
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
