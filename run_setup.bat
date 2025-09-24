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
set "HP_PREP_REQUIREMENTS=IyBoZWxwZXI6IHByZXBfcmVxdWlyZW1lbnRzIHYyICgyMDI1LTA5LTI0KQpfX3ZlcnNpb25fXyA9ICJwcmVwX3JlcXVpcmVtZW50cyB2MiAoMjAyNS0wOS0yNCkiCk9QX09SREVSID0gKCI9PSIsICIhPSIsICI+PSIsICI+IiwgIjw9IiwgIjwiKQpPUF9SQU5LID0ge29wOiBpZHggZm9yIGlkeCwgb3AgaW4gZW51bWVyYXRlKE9QX09SREVSKX0KCmltcG9ydCBvcwppbXBvcnQgcmUKaW1wb3J0IHN5cwpmcm9tIGNvbGxlY3Rpb25zIGltcG9ydCBPcmRlcmVkRGljdAoKSU5QID0gc3lzLmFyZ3ZbMV0gaWYgbGVuKHN5cy5hcmd2KSA+IDEgZWxzZSAicmVxdWlyZW1lbnRzLnR4dCIKT1VUX0NPTkRBID0gIn5yZXFzX2NvbmRhLnR4dCIKT1VUX1BJUCA9ICJ+cmVxc19waXAudHh0IgpTUEVDX1BBVFRFUk4gPSByZS5jb21waWxlKHIiKH49fD09fCE9fD49fD58PD18PClccyooW15ccyw7XSspXHMqJCIpCk5BTUVfUEFUVEVSTiA9IHJlLmNvbXBpbGUociJeXHMqKFtBLVphLXowLTlfLi1dKylccyooLiopJCIpCgoKZGVmIG5vcm0odGV4dDogc3RyKSAtPiBzdHI6CiAgICByZXR1cm4gdGV4dC5zdHJpcCgpCgoKZGVmIHNwbGl0X21hcmtlcih0ZXh0OiBzdHIpIC0+IHN0cjoKICAgIHJldHVybiB0ZXh0LnNwbGl0KCI7IilbMF0uc3RyaXAoKQoKCmRlZiBzdHJpcF9leHRyYXMobmFtZTogc3RyKSAtPiBzdHI6CiAgICByZXR1cm4gcmUuc3ViKHIiXFsuKj9cXSIsICIiLCBuYW1lKQoKCmRlZiBfdmVyc2lvbl9rZXkodGV4dDogc3RyKToKICAgIHBhcnRzID0gW10KICAgIGZvciBjaHVuayBpbiB0ZXh0LnNwbGl0KCcuJyk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBwYXJ0cy5hcHBlbmQoaW50KGNodW5rKSkKICAgICAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgcGFydHMuYXBwZW5kKDApCiAgICByZXR1cm4gdHVwbGUocGFydHMpCgoKZGVmIF9idW1wX2NvbXBhdGlibGUodmFsdWU6IHN0cikgLT4gc3RyOgogICAgcGllY2VzID0gdmFsdWUuc3BsaXQoJy4nKQogICAgaWYgbm90IHBpZWNlcyBvciBub3QgcGllY2VzWzBdLmlzZGlnaXQoKToKICAgICAgICByZXR1cm4gdmFsdWUKICAgIG1ham9yID0gaW50KHBpZWNlc1swXSkKICAgIGlmIGxlbihwaWVjZXMpID49IDMgYW5kIHBpZWNlc1sxXS5pc2RpZ2l0KCk6CiAgICAgICAgcmV0dXJuIGYie21ham9yfS57aW50KHBpZWNlc1sxXSkgKyAxfSIKICAgIGlmIGxlbihwaWVjZXMpID49IDI6CiAgICAgICAgcmV0dXJuIGYie21ham9yICsgMX0uMCIKICAgIHJldHVybiBzdHIobWFqb3IgKyAxKQoKCmRlZiBfZXhwYW5kX2ZyYWdtZW50KGZyYWdtZW50OiBzdHIpOgogICAgaWYgbm90IGZyYWdtZW50OgogICAgICAgIHJldHVybiBbXQogICAgdmFsdWUgPSBmcmFnbWVudC5zdHJpcCgpCiAgICBpZiBub3QgdmFsdWU6CiAgICAgICAgcmV0dXJuIFtdCiAgICBtYXRjaCA9IFNQRUNfUEFUVEVSTi5mdWxsbWF0Y2godmFsdWUpCiAgICBpZiBub3QgbWF0Y2g6CiAgICAgICAgcmV0dXJuIFtdCiAgICBvcCwgdmVyID0gbWF0Y2guZ3JvdXBzKCkKICAgIHZlciA9IHZlci5zdHJpcCgpCiAgICBpZiBub3QgdmVyOgogICAgICAgIHJldHVybiBbXQogICAgaWYgb3AgPT0gIn49IjoKICAgICAgICB1cHBlciA9IF9idW1wX2NvbXBhdGlibGUodmVyKQogICAgICAgIHJldHVybiBbZiI+PXt2ZXJ9IiwgZiI8e3VwcGVyfSJdCiAgICByZXR1cm4gW2Yie29wfXt2ZXJ9Il0KCgpkZWYgY2Fub25pY2FsX29wcyhzcGVjcykgLT4gbGlzdDoKICAgIGJ1Y2tldCA9IE9yZGVyZWREaWN0KCkKICAgIGZvciByYXcgaW4gc3BlY3M6CiAgICAgICAgZm9yIG5vcm1hbGl6ZWQgaW4gX2V4cGFuZF9mcmFnbWVudChyYXcpOgogICAgICAgICAgICBidWNrZXRbbm9ybWFsaXplZF0gPSBOb25lCiAgICBvcmRlcmVkID0gbGlzdChidWNrZXQua2V5cygpKQogICAgb3JkZXJlZC5zb3J0KGtleT1fc3BlY19zb3J0X2tleSkKICAgIHJldHVybiBfZW5mb3JjZV9ib3VuZHNfb3JkZXIob3JkZXJlZCkKCgpkZWYgX3NwZWNfc29ydF9rZXkodmFsdWU6IHN0cik6CiAgICBmb3Igb3AgaW4gT1BfT1JERVI6CiAgICAgICAgaWYgdmFsdWUuc3RhcnRzd2l0aChvcCk6CiAgICAgICAgICAgIHZlciA9IHZhbHVlW2xlbihvcCk6XQogICAgICAgICAgICByZXR1cm4gT1BfUkFOS1tvcF0sIF92ZXJzaW9uX2tleSh2ZXIpLCB2ZXIKICAgIHJldHVybiBsZW4oT1BfT1JERVIpLCBfdmVyc2lvbl9rZXkodmFsdWUpLCB2YWx1ZQoKCmRlZiBfZW5mb3JjZV9ib3VuZHNfb3JkZXIoaXRlbXM6IGxpc3QpIC0+IGxpc3Q6CiAgICBvcHMgPSBsaXN0KGl0ZW1zKQogICAgbG93ZXJfaW5kZXggPSBuZXh0KChpZHggZm9yIGlkeCwgdGV4dCBpbiBlbnVtZXJhdGUob3BzKSBpZiB0ZXh0LnN0YXJ0c3dpdGgoIj49IikpLCBOb25lKQogICAgaWYgbG93ZXJfaW5kZXggaXMgTm9uZToKICAgICAgICByZXR1cm4gb3BzCiAgICBmb3IgdXBwZXJfb3AgaW4gKCI8PSIsICI8Iik6CiAgICAgICAgdXBwZXJfaW5kZXggPSBuZXh0KChpZHggZm9yIGlkeCwgdGV4dCBpbiBlbnVtZXJhdGUob3BzKSBpZiB0ZXh0LnN0YXJ0c3dpdGgodXBwZXJfb3ApKSwgTm9uZSkKICAgICAgICBpZiB1cHBlcl9pbmRleCBpcyBub3QgTm9uZSBhbmQgdXBwZXJfaW5kZXggPCBsb3dlcl9pbmRleDoKICAgICAgICAgICAgdmFsdWUgPSBvcHMucG9wKGxvd2VyX2luZGV4KQogICAgICAgICAgICBvcHMuaW5zZXJ0KHVwcGVyX2luZGV4LCB2YWx1ZSkKICAgICAgICAgICAgbG93ZXJfaW5kZXggPSB1cHBlcl9pbmRleAogICAgcmV0dXJuIG9wcwoKCmRlZiBmb3JtYXRfbGluZShuYW1lOiBzdHIsIHNwZWNzKSAtPiBsaXN0OgogICAgb3BzID0gY2Fub25pY2FsX29wcyhzcGVjcykKICAgIHJldHVybiBbZiJ7bmFtZX0gIiArICIsIi5qb2luKG9wcyldIGlmIG9wcyBlbHNlIFtuYW1lXQoKCmRlZiBub3JtYWxpemVfc3BlY2lmaWVycyhyZXN0OiBzdHIpOgogICAgaXRlbXMgPSBbXQogICAgZm9yIGNodW5rIGluIHJlc3Quc3BsaXQoJywnKToKICAgICAgICBjaHVuayA9IGNodW5rLnN0cmlwKCkKICAgICAgICBpZiBjaHVuazoKICAgICAgICAgICAgaXRlbXMuZXh0ZW5kKF9leHBhbmRfZnJhZ21lbnQoY2h1bmspKQogICAgcmV0dXJuIGNhbm9uaWNhbF9vcHMoaXRlbXMpCgoKZGVmIHRvX2NvbmRhKGxpbmU6IHN0cik6CiAgICBzZWN0aW9uID0gc3BsaXRfbWFya2VyKGxpbmUpCiAgICBpZiBub3Qgc2VjdGlvbiBvciBzZWN0aW9uLnN0YXJ0c3dpdGgoJyMnKToKICAgICAgICByZXR1cm4gW10KICAgIG1hdGNoID0gTkFNRV9QQVRURVJOLm1hdGNoKHNlY3Rpb24pCiAgICBpZiBub3QgbWF0Y2g6CiAgICAgICAgcmV0dXJuIFtdCiAgICBuYW1lLCByZXN0ID0gbWF0Y2guZ3JvdXBzKCkKICAgIG5hbWUgPSBzdHJpcF9leHRyYXMobmFtZSkKICAgIHJlc3QgPSByZS5zdWIociJcWy4qP1xdIiwgIiIsIHJlc3QpCiAgICBzcGVjcyA9IFtjaHVuay5zdHJpcCgpIGZvciBjaHVuayBpbiByZXN0LnNwbGl0KCcsJykgaWYgY2h1bmsuc3RyaXAoKV0KICAgIHJldHVybiBmb3JtYXRfbGluZShuYW1lLCBzcGVjcykKCgpkZWYgdG9fcGlwKGxpbmU6IHN0cik6CiAgICBzZWN0aW9uID0gc3BsaXRfbWFya2VyKGxpbmUpCiAgICBpZiBub3Qgc2VjdGlvbiBvciBzZWN0aW9uLnN0YXJ0c3dpdGgoJyMnKToKICAgICAgICByZXR1cm4gTm9uZQogICAgbWF0Y2ggPSBOQU1FX1BBVFRFUk4ubWF0Y2goc2VjdGlvbikKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByZXR1cm4gc2VjdGlvbi5zdHJpcCgpCiAgICBuYW1lLCByZXN0ID0gbWF0Y2guZ3JvdXBzKCkKICAgIG5hbWUgPSBzdHJpcF9leHRyYXMobmFtZSkKICAgIHJldHVybiAobmFtZSArIHJlc3QpLnN0cmlwKCkKCgpkZWYgbWFpbigpOgogICAgaGF2ZV9maWxlID0gb3MucGF0aC5leGlzdHMoSU5QKSBhbmQgb3MucGF0aC5nZXRzaXplKElOUCkgPiAwCiAgICBsaW5lcyA9IFtdCiAgICBpZiBoYXZlX2ZpbGU6CiAgICAgICAgd2l0aCBvcGVuKElOUCwgJ3InLCBlbmNvZGluZz0ndXRmLTgnLCBlcnJvcnM9J2lnbm9yZScpIGFzIGhhbmRsZToKICAgICAgICAgICAgbGluZXMgPSBbbm9ybShpdGVtKSBmb3IgaXRlbSBpbiBoYW5kbGUgaWYgbm9ybShpdGVtKV0KICAgIGNvbmRhX3NwZWNzID0gW10KICAgIHBpcF9zcGVjcyA9IFtdCiAgICBmb3IgbGluZSBpbiBsaW5lczoKICAgICAgICBjb25kYV9zcGVjcy5leHRlbmQodG9fY29uZGEobGluZSkpCiAgICAgICAgcGlwX2VudHJ5ID0gdG9fcGlwKGxpbmUpCiAgICAgICAgaWYgcGlwX2VudHJ5OgogICAgICAgICAgICBwaXBfc3BlY3MuYXBwZW5kKHBpcF9lbnRyeSkKICAgIG5hbWVzX2xvd2VyID0gW3JlLnNwbGl0KHIiWzw+PSF+LFxzXSIsIHZhbHVlLCAxKVswXS5zdHJpcCgpLmxvd2VyKCkgZm9yIHZhbHVlIGluIHBpcF9zcGVjc10KICAgIGlmICdwYW5kYXMnIGluIG5hbWVzX2xvd2VyIGFuZCAnb3BlbnB5eGwnIG5vdCBpbiBuYW1lc19sb3dlcjoKICAgICAgICBwaXBfc3BlY3MuYXBwZW5kKCdvcGVucHl4bCcpCiAgICAgICAgY29uZGFfc3BlY3MuZXh0ZW5kKGZvcm1hdF9saW5lKCdvcGVucHl4bCcsIFtdKSkKICAgIHdpdGggb3BlbihPVVRfQ09OREEsICd3JywgZW5jb2Rpbmc9J2FzY2lpJykgYXMgaGFuZGxlOgogICAgICAgIGZvciBpdGVtIGluIGNvbmRhX3NwZWNzOgogICAgICAgICAgICBpZiBpdGVtOgogICAgICAgICAgICAgICAgaGFuZGxlLndyaXRlKGl0ZW0gKyAnXG4nKQogICAgd2l0aCBvcGVuKE9VVF9QSVAsICd3JywgZW5jb2Rpbmc9J2FzY2lpJykgYXMgaGFuZGxlOgogICAgICAgIGZvciBpdGVtIGluIHBpcF9zcGVjczoKICAgICAgICAgICAgaWYgaXRlbToKICAgICAgICAgICAgICAgIGhhbmRsZS53cml0ZShpdGVtICsgJ1xuJykKICAgIHN5cy5zdGRvdXQud3JpdGUoJ09LXG4nKQoKCmlmIF9fbmFtZV9fID09ICdfX21haW5fXyc6CiAgICBtYWluKCkKICAgIGlmIGxlbihzeXMuYXJndikgPT0gMToKICAgICAgICBkZW1vID0gewogICAgICAgICAgICAncHl0aG9uJzogWyc+PTMuOCcsICc8NC4wJ10sCiAgICAgICAgICAgICdyZXF1ZXN0cyc6IFsnPj0yLjMxLjAnLCAnPDMnXSwKICAgICAgICAgICAgJ3B5ZGFudGljJzogWycgPj0yICcsICcgPDMnXSwKICAgICAgICB9CiAgICAgICAgZm9yIG5hbWUsIHNwZWNzIGluIGRlbW8uaXRlbXMoKToKICAgICAgICAgICAgZm9yIGxpbmUgaW4gZm9ybWF0X2xpbmUobmFtZSwgc3BlY3MpOgogICAgICAgICAgICAgICAgcHJpbnQobGluZSkK"
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
