@echo off
setlocal DisableDelayedExpansion
rem Boot strap renamed to run_setup.bat
cd /d "%~dp0"
set "LOG=~setup.log"
set "LOGPREV=~setup.prev.log"
if not exist "%LOG%" (type nul > "%LOG%")
call :rotate_log
set "HELPERS_DIR=%CD%\reference_helpers"
if not exist "%HELPERS_DIR%" (
  call :die "[ERROR] Helper directory missing: %HELPERS_DIR%"
)
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

call :copy_helper "%HELPERS_DIR%\detect_python.py" "~detect_python.py"
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

call :copy_helper "%HELPERS_DIR%\print_pyver.py" "~print_pyver.py"
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



call :copy_helper "%HELPERS_DIR%\prep_requirements.py" "~prep_requirements.py"
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

call :copy_helper "%HELPERS_DIR%\detect_visa.py" "~detect_visa.py"
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

call :copy_helper "%HELPERS_DIR%\find_entry.py" "~find_entry.py"
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
:copy_helper
set "SRC=%~1"
set "DST=%~2"
if not defined SRC exit /b 1
if not defined DST exit /b 1
if not exist "%SRC%" exit /b 1
copy /y "%SRC%" "%DST%" >nul
if errorlevel 1 exit /b %errorlevel%
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
