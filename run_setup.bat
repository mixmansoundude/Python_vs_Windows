@echo off
setlocal DisableDelayedExpansion
rem Boot strap renamed to run_setup.bat
cd /d "%~dp0"
set "LOG=~setup.log"
set "LOGPREV=~setup.prev.log"
if not exist "%LOG%" (type nul > "%LOG%")
call :rotate_log
call :define_helper_payloads
for %%I in ("%CD%") do set "ENVNAME=%%~nI"

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

  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$content = @'
channels:
  - conda-forge
channel_priority: strict
show_channel_urls: true
'@
$target = "%ENV_PATH%\.condarc"
$dir = Split-Path $target
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
Set-Content -Path $target -Encoding ASCII -Value $content" >> "%LOG%" 2>&1
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
for /f "usebackq delims=" %%M in ("~entry.txt") do set "ENTRY=%%M"
if "%ENTRY%"=="" ( call :die "[ERROR] Could not find an entry script." )
call "%CONDA_BAT%" run -n "%ENVNAME%" python "%ENTRY%" > "~run.out.txt" 2> "~run.err.txt"
call "%CONDA_BAT%" run -n "%ENVNAME%" python -m pip install -q pyinstaller >> "%LOG%" 2>&1
call "%CONDA_BAT%" run -n "%ENVNAME%" pyinstaller -y --onefile --name "%ENVNAME%" "%ENTRY%" >> "%LOG%" 2>&1
if not exist "dist\%ENVNAME%.exe" call :die "[ERROR] PyInstaller did not produce dist\%ENVNAME%.exe"
  start "" "dist\%ENVNAME%.exe"
  goto :eof
:emit_from_base64
set "DST=%~1"
set "VAR=%~2"
if not defined DST exit /b 1
if not defined VAR exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$varName = '%VAR%'; $envItem = Get-Item Env:$varName -ErrorAction SilentlyContinue; if (-not $envItem) { exit 1 }; $base64 = $envItem.Value; if (-not $base64) { exit 1 }; $outFile = Join-Path (Get-Location) '%DST%'; $bytes = [Convert]::FromBase64String($base64); [IO.File]::WriteAllBytes($outFile, $bytes)" >> "%LOG%" 2>&1
exit /b %errorlevel%
:define_helper_payloads
set "HP_DETECT_PY=aW1wb3J0IG9zLCByZSwgc3lzCgpDRCA9IG9zLmdldGN3ZCgpCnJ0X3BhdGggPSBvcy5wYXRoLmpvaW4oQ0QsICdydW50aW1lLnR4dCcpCnBwX3BhdGggPSBvcy5wYXRoLmpvaW4oQ0QsICdweXByb2plY3QudG9tbCcpCgpkZWYgcnRfc3BlYyh0ZXh0KToKICAgIG1hdGNoID0gcmUuc2VhcmNoKHInKD86cHl0aG9uWy09XSk/XHMqKFswLTldKyg/OlwuWzAtOV0rKXswLDJ9KScsIHRleHQpCiAgICBpZiBub3QgbWF0Y2g6CiAgICAgICAgcmV0dXJuICcnCiAgICB2YWx1ZSA9IG1hdGNoLmdyb3VwKDEpCiAgICBwYXJ0cyA9IHZhbHVlLnNwbGl0KCcuJykKICAgIG1ham9yX21pbm9yID0gJy4nLmpvaW4ocGFydHNbOjJdKQogICAgcmV0dXJuIGYncHl0aG9uPXttYWpvcl9taW5vcn0nCgpkZWYgcGVwNDQwX3RvX2NvbmRhKHNwZWNzKToKICAgIG91dCA9IFtdCiAgICBmb3IgcmF3IGluIHJlLnNwbGl0KHInXHMqLFxzKicsIHNwZWNzLnN0cmlwKCkpOgogICAgICAgIGlmIG5vdCByYXc6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgbWF0Y2ggPSByZS5tYXRjaChyJyg+PXw+fDw9fDx8PT18fj0pXHMqKFswLTldKyg/OlwuWzAtOV0rKXswLDJ9KVxzKiQnLCByYXcpCiAgICAgICAgaWYgbm90IG1hdGNoOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIG9wLCB2ZXIgPSBtYXRjaC5ncm91cCgxKSwgbWF0Y2guZ3JvdXAoMikKICAgICAgICBpZiBvcCA9PSAnfj0nOgogICAgICAgICAgICBwYXJ0cyA9IFtpbnQoeCkgZm9yIHggaW4gdmVyLnNwbGl0KCcuJyldCiAgICAgICAgICAgIGlmIGxlbihwYXJ0cykgPT0gMToKICAgICAgICAgICAgICAgIHVwcGVyID0gc3RyKHBhcnRzWzBdICsgMSkKICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgIHVwcGVyID0gZiJ7cGFydHNbMF19LntwYXJ0c1sxXSArIDF9IgogICAgICAgICAgICBvdXQuYXBwZW5kKGYncHl0aG9uPj17dmVyfSw8e3VwcGVyfScpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgb3V0LmFwcGVuZChmJ3B5dGhvbntvcH17dmVyfScpCiAgICByZXR1cm4gJywnLmpvaW4oW2l0ZW0gZm9yIGl0ZW0gaW4gb3V0IGlmIGl0ZW1dKQoKZGVmIG1haW4oKToKICAgIGlmIG9zLnBhdGguZXhpc3RzKHJ0X3BhdGgpOgogICAgICAgIHdpdGggb3BlbihydF9wYXRoLCAncicsIGVuY29kaW5nPSd1dGYtOCcsIGVycm9ycz0naWdub3JlJykgYXMgaGFuZGxlOgogICAgICAgICAgICBzcGVjID0gcnRfc3BlYyhoYW5kbGUucmVhZCgpKQogICAgICAgICAgICBpZiBzcGVjOgogICAgICAgICAgICAgICAgcHJpbnQoc3BlYykKICAgICAgICAgICAgICAgIHJldHVybgogICAgaWYgb3MucGF0aC5leGlzdHMocHBfcGF0aCk6CiAgICAgICAgd2l0aCBvcGVuKHBwX3BhdGgsICdyJywgZW5jb2Rpbmc9J3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKSBhcyBoYW5kbGU6CiAgICAgICAgICAgIHRleHQgPSBoYW5kbGUucmVhZCgpCiAgICAgICAgbWF0Y2ggPSByZS5zZWFyY2gocidyZXF1aXJlcy1weXRob25ccyo9XHMqWyJcJ10oW14iXCddKylbIlwnXScsIHRleHQpCiAgICAgICAgaWYgbWF0Y2g6CiAgICAgICAgICAgIGNvbnZlcnRlZCA9IHBlcDQ0MF90b19jb25kYShtYXRjaC5ncm91cCgxKSkKICAgICAgICAgICAgcHJpbnQoY29udmVydGVkKQogICAgICAgICAgICByZXR1cm4KICAgIHByaW50KCcnKQoKaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJzoKICAgIG1haW4oKQo="
set "HP_PRINT_PYVER=aW1wb3J0IHN5cwoKcHJpbnQoZiJweXRob24te3N5cy52ZXJzaW9uX2luZm9bMF19LntzeXMudmVyc2lvbl9pbmZvWzFdfSIpCg=="
set "HP_PREP_REQUIREMENTS=aW1wb3J0IG9zLCByZSwgc3lzCgpJTlAgPSBzeXMuYXJndlsxXSBpZiBsZW4oc3lzLmFyZ3YpID4gMSBlbHNlICdyZXF1aXJlbWVudHMudHh0JwpPVVRfQ09OREEgPSAnfnJlcXNfY29uZGEudHh0JwpPVVRfUElQID0gJ35yZXFzX3BpcC50eHQnCgpkZWYgbm9ybShsaW5lKToKICAgIHJldHVybiBsaW5lLnN0cmlwKCkKCmRlZiBzcGxpdF9tYXJrZXIodGV4dCk6CiAgICByZXR1cm4gdGV4dC5zcGxpdCgnOycpWzBdLnN0cmlwKCkKCmRlZiBzdHJpcF9leHRyYXMobmFtZSk6CiAgICByZXR1cm4gcmUuc3ViKHIiXFsuKj9cXSIsICcnLCBuYW1lKQoKZGVmIGJ1bXBfZm9yX2NvbXBhdGlibGUodmFsdWUpOgogICAgcGFydHMgPSBbaW50KHgpIGZvciB4IGluIHZhbHVlLnNwbGl0KCcuJyldCiAgICBpZiBsZW4ocGFydHMpID09IDE6CiAgICAgICAgcmV0dXJuIHN0cihwYXJ0c1swXSArIDEpCiAgICBpZiBsZW4ocGFydHMpID49IDI6CiAgICAgICAgcmV0dXJuIGYie3BhcnRzWzBdfS57cGFydHNbMV0gKyAxfSIKICAgIHJldHVybiB2YWx1ZQoKZGVmIHRvX2NvbmRhKGxpbmUpOgogICAgc2VjdGlvbiA9IHNwbGl0X21hcmtlcihsaW5lKQogICAgaWYgbm90IHNlY3Rpb24gb3Igc2VjdGlvbi5zdGFydHN3aXRoKCcjJyk6CiAgICAgICAgcmV0dXJuIFtdCiAgICBpZiBzZWN0aW9uLnN0YXJ0c3dpdGgoJy1lICcpIG9yIHNlY3Rpb24uc3RhcnRzd2l0aCgnLS1lZGl0YWJsZScpIG9yIHNlY3Rpb24uc3RhcnRzd2l0aCgnZ2l0KycpIG9yICc6Ly8nIGluIHNlY3Rpb246CiAgICAgICAgcmV0dXJuIFtdCiAgICBtYXRjaCA9IHJlLm1hdGNoKHIiXlxzKihbQS1aYS16MC05Xy4tXSspXHMqKC4qKSQiLCBzZWN0aW9uKQogICAgaWYgbm90IG1hdGNoOgogICAgICAgIHJldHVybiBbXQogICAgbmFtZSwgcmVzdCA9IG1hdGNoLmdyb3VwKDEpLCBtYXRjaC5ncm91cCgyKS5zdHJpcCgpCiAgICBuYW1lID0gc3RyaXBfZXh0cmFzKG5hbWUpCiAgICBpZiBub3QgcmVzdDoKICAgICAgICByZXR1cm4gW25hbWVdCiAgICByZXN0ID0gcmVzdC5yZXBsYWNlKCcgJywgJycpCiAgICBtYXRjaF9jb21wYXQgPSByZS5tYXRjaChyIl5+PVxzKihbMC05XSsoPzpcLlswLTldKyl7MCwyfSkkIiwgcmVzdCkKICAgIGlmIG1hdGNoX2NvbXBhdDoKICAgICAgICBiYXNlID0gbWF0Y2hfY29tcGF0Lmdyb3VwKDEpCiAgICAgICAgdXBwZXIgPSBidW1wX2Zvcl9jb21wYXRpYmxlKGJhc2UpCiAgICAgICAgcmV0dXJuIFtmIntuYW1lfSA+PXtiYXNlfSw8e3VwcGVyfSJdCiAgICBzZWdtZW50cyA9IFtwYXJ0IGZvciBwYXJ0IGluIHJlc3Quc3BsaXQoJywnKSBpZiBwYXJ0XQogICAgb3BzID0gW10KICAgIGZvciBwYXJ0IGluIHNlZ21lbnRzOgogICAgICAgIG0gPSByZS5tYXRjaChyIl4oPj18PD18PT18IT18Pnw8KVxzKihbMC05XSsoPzpcLlswLTldKyl7MCw1fSkkIiwgcGFydCkKICAgICAgICBpZiBtOgogICAgICAgICAgICBvcHMuYXBwZW5kKGYie20uZ3JvdXAoMSl9e20uZ3JvdXAoMil9IikKICAgIHJldHVybiBbZiJ7bmFtZX0gIiArICcsJy5qb2luKG9wcyldIGlmIG9wcyBlbHNlIFtuYW1lXQoKZGVmIHRvX3BpcChsaW5lKToKICAgIHNlY3Rpb24gPSBzcGxpdF9tYXJrZXIobGluZSkKICAgIGlmIG5vdCBzZWN0aW9uIG9yIHNlY3Rpb24uc3RhcnRzd2l0aCgnIycpOgogICAgICAgIHJldHVybiBOb25lCiAgICBtYXRjaCA9IHJlLm1hdGNoKHIiXlxzKihbQS1aYS16MC05Xy4tXSspKC4qKSQiLCBzZWN0aW9uKQogICAgaWYgbm90IG1hdGNoOgogICAgICAgIHJldHVybiBzZWN0aW9uLnN0cmlwKCkKICAgIG5hbWUsIHJlc3QgPSBtYXRjaC5ncm91cCgxKSwgbWF0Y2guZ3JvdXAoMikKICAgIG5hbWUgPSBzdHJpcF9leHRyYXMobmFtZSkKICAgIHJldHVybiAobmFtZSArIHJlc3QpLnN0cmlwKCkKCmRlZiBtYWluKCk6CiAgICBoYXZlX2ZpbGUgPSBvcy5wYXRoLmV4aXN0cyhJTlApIGFuZCBvcy5wYXRoLmdldHNpemUoSU5QKSA+IDAKICAgIGxpbmVzID0gW10KICAgIGlmIGhhdmVfZmlsZToKICAgICAgICB3aXRoIG9wZW4oSU5QLCAncicsIGVuY29kaW5nPSd1dGYtOCcsIGVycm9ycz0naWdub3JlJykgYXMgaGFuZGxlOgogICAgICAgICAgICBsaW5lcyA9IFtub3JtKGl0ZW0pIGZvciBpdGVtIGluIGhhbmRsZSBpZiBub3JtKGl0ZW0pXQogICAgY29uZGFfc3BlY3MgPSBbXQogICAgcGlwX3NwZWNzID0gW10KICAgIGZvciBsaW5lIGluIGxpbmVzOgogICAgICAgIGNvbmRhX3NwZWNzLmV4dGVuZCh0b19jb25kYShsaW5lKSkKICAgICAgICBwaXBfZW50cnkgPSB0b19waXAobGluZSkKICAgICAgICBpZiBwaXBfZW50cnk6CiAgICAgICAgICAgIHBpcF9zcGVjcy5hcHBlbmQocGlwX2VudHJ5KQogICAgbmFtZXNfbG93ZXIgPSBbcmUuc3BsaXQociJbPD49IX4sXHNdIiwgdmFsdWUsIDEpWzBdLnN0cmlwKCkubG93ZXIoKSBmb3IgdmFsdWUgaW4gcGlwX3NwZWNzXQogICAgaWYgJ3BhbmRhcycgaW4gbmFtZXNfbG93ZXIgYW5kICdvcGVucHl4bCcgbm90IGluIG5hbWVzX2xvd2VyOgogICAgICAgIHBpcF9zcGVjcy5hcHBlbmQoJ29wZW5weXhsJykKICAgICAgICBjb25kYV9zcGVjcy5hcHBlbmQoJ29wZW5weXhsJykKICAgIHdpdGggb3BlbihPVVRfQ09OREEsICd3JywgZW5jb2Rpbmc9J2FzY2lpJykgYXMgaGFuZGxlOgogICAgICAgIGZvciBpdGVtIGluIGNvbmRhX3NwZWNzOgogICAgICAgICAgICBpZiBpdGVtOgogICAgICAgICAgICAgICAgaGFuZGxlLndyaXRlKGl0ZW0gKyAnXG4nKQogICAgd2l0aCBvcGVuKE9VVF9QSVA6ICd3JywgZW5jb2Rpbmc9J2FzY2lpJykgYXMgaGFuZGxlOgogICAgICAgIGZvciBpdGVtIGluIHBpcF9zcGVjczoKICAgICAgICAgICAgaWYgaXRlbToKICAgICAgICAgICAgICAgIGhhbmRsZS53cml0ZShpdGVtICsgJ1xuJykKICAgIHN5cy5zdGRvdXQud3JpdGUoJ09LXG4nKQoKaWYgX19uYW1lX18gPT0gJ19fbWFpbl9fJzoKICAgIG1haW4oKQo="
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
echo %date% %time% %MSG%
>> "%LOG%" echo [%date% %time%] %MSG%
exit /b 1
:rotate_log
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"if (Test-Path '%LOG%') { if ((Get-Item '%LOG%').Length -gt 10485760) { Move-Item -Force '%LOG%' '%LOGPREV%' } }"
exit /b 0
