@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
if not exist "tests" mkdir "tests" >nul 2>&1
echo [%date% %time%] Running static harness...
powershell -NoProfile -ExecutionPolicy Bypass -File "tests\harness.ps1"
set ERR=%ERRORLEVEL%
echo.
if exist "tests\~test-summary.txt" type "tests\~test-summary.txt"
echo.
if %ERR%==0 (
  echo [%date% %time%] Running bootstrap self-tests...
  powershell -NoProfile -ExecutionPolicy Bypass -File "tests\selftest.ps1"
  if errorlevel 1 set ERR=1
  if exist "tests\~selftest-summary.txt" (
    echo.
    type "tests\~selftest-summary.txt"
  )
  echo.
  echo [%date% %time%] Verifying empty-repo console self-test...
  powershell -NoProfile -ExecutionPolicy Bypass -File "tests\selftests.ps1"
  if errorlevel 1 set ERR=1
  if exist "tests\~selftests-summary.txt" (
    echo.
    type "tests\~selftests-summary.txt"
  )
  echo.
)
echo Static test exit code: %ERR%
echo.
echo Optional dynamic tests (needs any Python): tests\dynamic_tests.bat
echo To bootstrap the app, double-click: run_setup.bat
exit /b %ERR%
