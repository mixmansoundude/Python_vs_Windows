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
echo Static test exit code: %ERR%
echo.
echo Optional dynamic tests (needs any Python): tests\dynamic_tests.bat
echo To bootstrap the app, double-click: run_setup.bat
exit /b %ERR%
