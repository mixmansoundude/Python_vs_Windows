@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
set "LOG=~dynamic-run.log"
echo [%date% %time%] Dynamic tests starting... > "%LOG%"
set "CAND=%PUBLIC%\Documents\Miniconda3\python.exe"
if exist "%CAND%" ( set "PY=%CAND%" )
if not defined PY (
  where py >nul 2>&1 && ( for /f "usebackq delims=" %%A in (`py -3 -c "import sys; print(sys.executable)"`) do set "PY=%%A" )
)
if not defined PY (
  for %%P in (python.exe) do ( where %%P >nul 2>&1 && set "PY=%%P" )
)
if not defined PY (
  echo No Python interpreter found. Skipping dynamic tests. >> "%LOG%"
  echo No Python found. Skipping dynamic tests.
  exit /b 2
)
echo Using Python: %PY% >> "%LOG%"
"%PY%" dynamic_tests.py > "~dynamic-results.ndjson" 2>> "%LOG%"
set ERR=%ERRORLEVEL%
type "~dynamic-results.ndjson"
echo Exit code: %ERR%
echo To bootstrap the app, double-click: ..\run_setup.bat
exit /b %ERR%
