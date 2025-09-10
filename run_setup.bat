@echo off
REM ==============================================================================
REM run_setup.bat header
REM Purpose:
REM   From only one or more .py files on a clean Windows 10+ machine with internet,
REM   bootstrap everything needed to run the Python app with all imports installed,
REM   and produce a one-file exe by default. No other project files required.
REM
REM Platform and paths:
REM   OS: Windows 10 (1809+) only. Use built-in curl and PowerShell.
REM   Miniconda root: %PUBLIC%\Documents\Miniconda3
REM   Conda env prefix: %PUBLIC%\Documents\CondaEnvs\<envname>  (envname = current folder)
REM   Workspace: current directory (where this batch runs)
REM   Keep: runtime.txt, requirements.txt, conda_env.json, dist\<envname>.exe
REM   Tilde-prefixed internal files: ~setup.log, ~setup.prev.log, ~source.hash, ~exe_source.hash,
REM     ~conda_update.timestamp, ~rebuild.once.flag, ~requirements.auto.txt
REM   ASCII only characters throughout the file and outputs.
REM
REM Python and environment selection:
REM   Version detection order:
REM     1) runtime.txt   (python-3.x.y or 3.x[.y])
REM     2) pyproject.toml requires-python (use floor if range)
REM     3) else let conda choose latest, then write runtime.txt
REM   Create env by prefix (no activation):
REM     call "%PUBLIC%\Documents\Miniconda3\condabin\conda.bat" create --prefix "<ENV_PREFIX>" -y --override-channels -c conda-forge [python=X.Y or python]
REM   All conda operations must include:
REM     --prefix "<ENV_PREFIX>"  and  --override-channels -c conda-forge
REM
REM Dependencies:
REM   Always infer sidecar:
REM     "<ENV_PREFIX>\python.exe" -m pipreqs . --force --mode compat --savepath ~requirements.auto.txt
REM   Log diff (requirements.txt vs ~requirements.auto.txt) into ~setup.log.
REM   If requirements.txt missing or empty -> adopt ~requirements.auto.txt as requirements.txt.
REM   Install order:
REM     1) conda bulk:
REM        call "%PUBLIC%\Documents\Miniconda3\condabin\conda.bat" install --prefix "<ENV_PREFIX>" --yes --override-channels -c conda-forge --file requirements.txt
REM     2) if bulk fails -> per package with compatible release conversion:
REM        pkg~=A.B[.C]  =>  pkg>=A.B[.C],<A.(B+1)   (PEP 440)
REM     3) pip sweep always:
REM        "<ENV_PREFIX>\python.exe" -m pip install -r requirements.txt
REM   Heuristics:
REM     - if pandas present, ensure openpyxl is included
REM     - on first ModuleNotFoundError: append missing module, merge ~requirements.auto.txt, rebuild once
REM   Sidecar lifecycle:
REM     - on success without rebuild: delete ~requirements.auto.txt
REM     - on rebuild or failure: keep ~requirements.auto.txt
REM
REM Executable:
REM   Always build one-file exe:
REM     "<ENV_PREFIX>\python.exe" -m PyInstaller --onefile --name "<envname>" "<main.py>"
REM   Fast path: if dist\<envname>.exe exists and ~source.hash == ~exe_source.hash, run exe and exit.
REM
REM NI-VISA (optional system install):
REM   If code imports pyvisa or visa and NI-VISA not installed, attempt silent install unless VISAINSTALL=no.
REM
REM Maintenance and logging:
REM   Conda base update at most every 30 days (skip right after fresh install):
REM     call "%PUBLIC%\Documents\Miniconda3\condabin\conda.bat" update -n base --override-channels -c conda-forge conda -y
REM   Logging: ~setup.log (rotate to ~setup.prev.log at start/end).
REM   VERBOSE=1 mirrors DEBUG to console (DEBUG always written to log).
REM
REM Source change detection:
REM   Hash all .py files (stable order) to ~source.hash. After successful build, copy to ~exe_source.hash.
REM   If equal on next run and exe exists, skip build and run exe.
REM
REM Flags:
REM   FORCE=1 (force env rebuild)
REM   VERBOSE=1 (console DEBUG)
REM   VISAINSTALL=yes|no|auto
REM   NOINPUT=1 (non-interactive entrypoint pick)
REM   NOEXE=1 (do not launch exe)
REM   TEST=1 (built-in minimal scenarios)
REM
REM Exit codes:
REM   0 success
REM   1 generic failure
REM   2 no .py files or empty entrypoint
REM   3 Miniconda download invalid or too small
REM   4 Miniconda installer failure
REM   6 env creation failure
REM   7 env Python missing
REM   8 env recreate sanity failure
REM
REM Batch guardrails:
REM   setlocal EnableExtensions DisableDelayedExpansion
REM   Avoid delayed expansion globally; do not rely on %VAR% changing inside parentheses.
REM   Prefer prefix execution over activation.
REM   Safe curl:
REM     curl --fail --location --retry 5 --retry-delay 2 --connect-timeout 20 -o "<file>" "<url>"
REM   PowerShell:
REM     powershell -NoProfile -ExecutionPolicy Bypass -Command "<cmd>"
REM ==============================================================================
REM End header
REM ==============================================================================

setlocal EnableExtensions DisableDelayedExpansion

REM -----------------------------
REM Config
REM -----------------------------
set "PUBLIC_DOCS=%PUBLIC%\Documents"
set "MINICONDA_DIR=%PUBLIC_DOCS%\Miniconda3"
set "CONDA_ENVS_PATH=%PUBLIC_DOCS%\CondaEnvs"
set "LOG_FILE=~setup.log"
set "MAX_LOG_SIZE_BYTES=10485760"
set "CONDABAT=%MINICONDA_DIR%\condabin\conda.bat"
set "FORCE=0"
set "VERBOSE=0"
set "VISAINSTALL=auto"
set "TEST=0"
set "NOEXE=0"
set "NOINPUT=0"
set "NI_VISA_URL=https://download.ni.com/support/softlib/visa/VISA/21.5/Windows/NI-VISA%2021.5%20Offline%20Installer.exe"
set "REBUILD_OCCURRED=0"

REM Parse key=value args quickly
:__parse_args
if "%~1"=="" goto :__parse_done
echo.%~1| findstr "=" >nul && set "%~1"
shift
goto :__parse_args
:__parse_done
echo %* | findstr /I "VERBOSE=1" >nul && set "VERBOSE=1"
REM Robust arg parsing for known keys (no delayed expansion)
:__parse_known
if "%~1"=="" goto :__parse_known_done
for /f "tokens=1,2 delims==" %%K in ("%~1") do (
  if /I "%%K"=="VERBOSE"     set "VERBOSE=%%L"
  if /I "%%K"=="FORCE"       set "FORCE=%%L"
  if /I "%%K"=="VISAINSTALL" set "VISAINSTALL=%%L"
  if /I "%%K"=="TEST"        set "TEST=%%L"
  if /I "%%K"=="NOINPUT"     set "NOINPUT=%%L"
  if /I "%%K"=="NOEXE"       set "NOEXE=%%L"
)
shift
goto :__parse_known
:__parse_known_done

REM Normalize unset flags
if "%VERBOSE%"=="" set "VERBOSE=0"
if "%FORCE%"=="" set "FORCE=0"
if "%VISAINSTALL%"=="" set "VISAINSTALL=auto"
if "%TEST%"=="" set "TEST=0"
if "%NOINPUT%"=="" set "NOINPUT=0"
if "%NOEXE%"=="" set "NOEXE=0"

set "PSH=powershell -NoProfile -ExecutionPolicy Bypass"

call :log INFO "run_setup.bat start"
call :log INFO "Flags FORCE=%FORCE% VERBOSE=%VERBOSE% VISAINSTALL=%VISAINSTALL% TEST=%TEST% NOINPUT=%NOINPUT% NOEXE=%NOEXE%"
call :rotate_log_if_needed  &  call :log DEBUG "Log rotation check at start complete"

REM Env/exe name == current folder
for %%I in ("%CD%") do set "ENV_NAME=%%~nxI"
call :log INFO "Environment and exe name %ENV_NAME%"

REM --------------------------------------------------
REM Entrypoint detection
REM --------------------------------------------------
call :log DEBUG "Begin entrypoint detection"
call :log DEBUG "Listing py files"
dir /b /a:-d *.py 2>nul

set "MAIN_PY="
for /f "tokens=1" %%c in ('dir /b /a:-d *.py ^| find /c /v ""') do set "PYCOUNT=%%c"
call :log DEBUG "PYCOUNT=%PYCOUNT%"
if "%PYCOUNT%"=="0" goto :no_python_files
if "%PYCOUNT%"=="1" goto :pick_only_file

%PSH% -Command " $m=Get-ChildItem -File -Filter *.py ^| Where-Object { (Get-Content $_ -Raw) -match 'if\s+__name__\s*==\s*[\'\"]__main__[\'\"]' } ^| Select-Object -First 1; if($m){[Console]::Out.Write($m.Name)} " > "~main_candidate.txt"
for /f "usebackq delims=" %%f in ("~main_candidate.txt") do set "MAIN_PY=%%f"
del /q "~main_candidate.txt" 2>nul
if not "%MAIN_PY%"=="" goto :have_main
if exist "main.py" (
  set "MAIN_PY=main.py"
  goto :have_main
)
if exist "app.py" (
  set "MAIN_PY=app.py"
  goto :have_main
)

if /I "%NOINPUT%"=="1" goto :default_first
call :log INFO "Multiple Python files detected choose one"
dir /b /a:-d *.py | sort | findstr /n "^"
set "SEL="
set /p SEL=Enter number default 1:
if "%SEL%"=="" set "SEL=1"
for /f "tokens=1* delims=:" %%N in ('dir /b /a:-d *.py ^| sort ^| findstr /n "^"') do if "%%N"=="%SEL%" set "MAIN_PY=%%O"
if "%MAIN_PY%"=="" goto :default_first

:have_main
if not defined MAIN_PY (
  call :log ERROR "Entrypoint not determined"
  exit /b 2
)
call :log INFO "Selected entrypoint %MAIN_PY%"
call :log DEBUG "Computing source hash"
goto :after_entrypoint

:pick_only_file
for /f "delims=" %%f in ('dir /b /a:-d *.py') do set "MAIN_PY=%%f"
goto :have_main

:default_first
for /f "delims=" %%f in ('dir /b /a:-d *.py ^| sort') do set "MAIN_PY=%%f" & goto :have_main

:no_python_files
call :log ERROR "No Python files found in current directory"
exit /b 2

:after_entrypoint
%PSH% ^
 "$files=Get-ChildItem -File -Filter *.py|Sort-Object Name;" ^
 "if(-not $files){exit 3};" ^
 "$concat=($files|%{(Get-FileHash $_.FullName -Algorithm SHA256).Hash+' '+$_.Name}) -join \"`n\";" ^
 "$hash=[BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($concat))).Replace('-','');" ^
 "Set-Content -Path '~source.hash' -Value $hash -NoNewline" >nul 2>&1

set "SRC_CHANGED=1"
if exist "~source.hash" if exist "~source.hash.prev" (
  %PSH% "if((Get-Content '~source.hash') -eq (Get-Content '~source.hash.prev')){ exit 0 } else { exit 1 }" >nul
  if errorlevel 1 (set "SRC_CHANGED=1") else (set "SRC_CHANGED=0")
)
call :log INFO "SRC_CHANGED=%SRC_CHANGED%"
call :log DEBUG "Checking early fast path exe"

if exist "dist\%ENV_NAME%.exe" if exist "~exe_source.hash" if exist "~source.hash" (
  %PSH% "if((Get-Content '~source.hash') -eq (Get-Content '~exe_source.hash')){ exit 0 } else { exit 1 }" >nul
  if not errorlevel 1 (
    call :log INFO "Source unchanged running dist\%ENV_NAME%.exe"
    if /I "%NOEXE%"=="1" (call :log INFO "NOEXE=1 skipping launch") else (start "" "dist\%ENV_NAME%.exe")
    set "RUN_OK=1"
    goto :success
  )
)

REM Python version selection
set "PY_VER="
if exist "runtime.txt" (
  for /f "usebackq tokens=1" %%v in (`type runtime.txt`) do set "RT_VER=%%v"
  set "PY_VER=%RT_VER:python-=%"
  call :log INFO "runtime.txt specifies Python %PY_VER%"
) else (
  if exist "pyproject.toml" (
    %PSH% "$raw=Get-Content 'pyproject.toml' -Raw; $m=[regex]::Match($raw,'(?im)^\s*requires-python\s*=\s*\"?([^\"''\r\n]+)'); if($m.Success){$m.Groups[1].Value}" > "~pyreq_spec.txt"
    for /f "usebackq delims=" %%s in ("~pyreq_spec.txt") do set "PY_SPEC=%%s"
    del /q "~pyreq_spec.txt" 2>nul
    if not "%PY_SPEC%"=="" (
      for /f "tokens=1 delims=>" %%f in ("%PY_SPEC%") do set "PY_FLOOR=%%~f"
      set "PY_FLOOR=%PY_FLOOR:~0,-1%"
      if not "%PY_FLOOR%"=="" set "PY_VER=%PY_FLOOR%"
      call :log INFO "pyproject.toml requires python %PY_SPEC% selecting %PY_VER%"
    )
  )
)
if "%PY_VER%"=="" (call :log INFO "No explicit Python version letting conda choose latest") else (call :log INFO "Targeting Python %PY_VER%")

REM Ensure Miniconda present (no activation)
call :log DEBUG "Ensuring Miniconda present"
set "JUST_INSTALLED=0"
if exist "%CONDABAT%" goto :_conda_present
call :log INFO "Conda not found installing to %MINICONDA_DIR%"
if not exist "%PUBLIC_DOCS%" mkdir "%PUBLIC_DOCS%" >nul 2>&1
set "MINICONDA_DL=%PUBLIC_DOCS%\~Miniconda3-latest-Windows-x86_64.exe"
if exist "%MINICONDA_DL%" del /f /q "%MINICONDA_DL%" >nul 2>&1
call :log DEBUG "Downloading Miniconda with curl"
curl --fail --location --retry 5 --retry-delay 2 --connect-timeout 20 -o "%MINICONDA_DL%" "https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe"
if errorlevel 1 (
  call :log ERROR "curl failed trying PowerShell Invoke WebRequest fallback"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri 'https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe' -OutFile '%MINICONDA_DL%'; exit 0 } catch { exit 1 }"
  if errorlevel 1 (
    call :log ERROR "Failed to download Miniconda with both curl and PowerShell"
    exit /b 3
  )
)
for %%S in ("%MINICONDA_DL%") do set "MINISIZE=%%~zS"
if "%MINISIZE%"=="" set "MINISIZE=0"
if %MINISIZE% LSS 1000000 (
  call :log ERROR "Downloaded Miniconda installer is too small bytes=%MINISIZE%"
  exit /b 3
)
call :log INFO "Launching Miniconda silent installer"
start /wait "" "%MINICONDA_DL%" /S /D=%MINICONDA_DIR%
if errorlevel 1 (
  call :log ERROR "Miniconda silent install failed"
  exit /b 4
)
set "JUST_INSTALLED=1"
call :log INFO "Miniconda installed to %MINICONDA_DIR%"

:_conda_present
REM Using env by prefix (no activation); all conda/python calls will reference %ENV_PREFIX% and %CONDABAT%

REM IMPORTANT: set user-level channels to conda-forge only to avoid ToS defaults
call :log DEBUG "Setting user level conda channels conda forge only remove defaults to avoid ToS prompts"
call "%CONDABAT%" config --add channels conda-forge >>"%LOG_FILE%" 2>&1
call "%CONDABAT%" config --remove channels defaults >>"%LOG_FILE%" 2>&1

REM Periodic base update (every 30 days) unless just installed
if "%JUST_INSTALLED%"=="1" (
  call :log INFO "Skipping base update fresh install"
) else (
  for /f %%U in ('%PSH% "$p='~conda_update.timestamp'; if(!(Test-Path $p)){'1'} else {$d=Get-Content $p; $last=[datetime]::ParseExact($d,'yyyyMMdd',$null); $age=(New-TimeSpan -Start $last -End (Get-Date)).TotalDays; if($age -ge 30){'1'} else {'0'}}"') do set "NEED_BASE_UPDATE=%%U"
  if "%NEED_BASE_UPDATE%"=="1" (
    call :log INFO "Updating conda base conda forge channel"
    call "%CONDABAT%" update -n base -c conda-forge --override-channels conda -y >>"%LOG_FILE%" 2>&1
    for /f "usebackq delims=" %%d in (`%PSH% "(Get-Date).ToString('yyyyMMdd')"`) do set "TODAY=%%d"
    > "~conda_update.timestamp" echo %TODAY%
  ) else (
    call :log INFO "Conda base update not needed age less than 30 days"
  )
)

REM Create env by prefix
set "ENV_PREFIX=%CONDA_ENVS_PATH%\%ENV_NAME%"
if not exist "%CONDA_ENVS_PATH%" mkdir "%CONDA_ENVS_PATH%" >nul 2>&1
if "%FORCE%"=="1" set "SRC_CHANGED=1"
if "%SRC_CHANGED%"=="1" if exist "%ENV_PREFIX%" (
  call :log INFO "Removing existing env %ENV_PREFIX%"
  call "%CONDABAT%" env remove --prefix "%ENV_PREFIX%" -y >>"%LOG_FILE%" 2>&1
)
if not exist "%ENV_PREFIX%" (
  call :log INFO "Creating conda env at %ENV_PREFIX%"
  if "%PY_VER%"=="" (
    call "%CONDABAT%" create --prefix "%ENV_PREFIX%" -y --override-channels -c conda-forge python >>"%LOG_FILE%" 2>&1
  ) else (
    call "%CONDABAT%" create --prefix "%ENV_PREFIX%" -y --override-channels -c conda-forge python="%PY_VER%" >>"%LOG_FILE%" 2>&1
  )
  if errorlevel 1 (
    call :log ERROR "Failed to create env"
    exit /b 6
  )
) else (
  call :log INFO "Reusing env %ENV_PREFIX%"
)
call :log INFO "Using Conda environment at %ENV_PREFIX%"
REM Using env by prefix (no activation) for installs and Python execution

set "PY_EXE=%ENV_PREFIX%\python.exe"
if not exist "%PY_EXE%" (
  call :log ERROR "Python executable not found in env prefix %ENV_PREFIX%"
  exit /b 7
)

REM Tooling
call :log DEBUG "Upgrading pip setuptools wheel"
"%PY_EXE%" -m pip install --upgrade pip setuptools wheel --disable-pip-version-check >>"%LOG_FILE%" 2>&1

REM Requirements
set "REQ_EXISTED=0"
if exist "requirements.txt" (
  for /f "usebackq delims=" %%s in (`%PSH% "(Get-Item \".\\requirements.txt\").Length"`) do set "REQSIZE=%%s"
  if not "%REQSIZE%"=="0" set "REQ_EXISTED=1"
)
"%PY_EXE%" -m pip install pipreqs pip-tools pip-chill pyinstaller >>"%LOG_FILE%" 2>&1
call :log DEBUG "Generating ~requirements.auto.txt via pipreqs compat"
"%PY_EXE%" -c "import importlib,sys;sys.exit(0 if importlib.util.find_spec('pipreqs') else 1)" >>"%LOG_FILE%" 2>&1
if errorlevel 1 "%PY_EXE%" -m pip install pipreqs >>"%LOG_FILE%" 2>&1
"%PY_EXE%" -m pipreqs . --force --mode compat --savepath ~requirements.auto.txt >>"%LOG_FILE%" 2>&1
if errorlevel 1 (
  if exist "%ENV_PREFIX%\Scripts\pipreqs.exe" (
    call :log DEBUG "Retrying pipreqs via Scripts\pipreqs.exe"
    "%ENV_PREFIX%\Scripts\pipreqs.exe" . --force --mode compat --savepath ~requirements.auto.txt >>"%LOG_FILE%" 2>&1
  )
)
if errorlevel 1 (
  call :log ERROR "pipreqs failed"
) else (
  call :log INFO "~requirements.auto.txt written compat"
)

if "%REQ_EXISTED%"=="0" (
  if exist "~requirements.auto.txt" (
    copy /Y "~requirements.auto.txt" "requirements.txt" >nul
    > "~reqs.generated.flag" echo 1
    call :log INFO "Adopted ~requirements.auto.txt as requirements.txt"
  )
)

if exist "requirements.txt" if exist "~requirements.auto.txt" (
  %PSH% " $a=Get-Content 'requirements.txt'; $b=Get-Content '~requirements.auto.txt'; $d=Compare-Object -ReferenceObject $a -DifferenceObject $b -IncludeEqual:$false -PassThru; if($d){'--- DIFF requirements txt vs auto ---'; $d; '--- END DIFF ---'}" >>"%LOG_FILE%" 2>&1
)

%PSH% "$r=Get-Content 'requirements.txt' -Raw; if($r -match '(?im)^\s*pandas(\b|==|>=|~=)'){ if($r -notmatch '(?im)^\s*openpyxl(\b|==|>=|~=)'){ Add-Content 'requirements.txt' 'openpyxl'; 'Added openpyxl for pandas'|Out-File -Append '%LOG_FILE%' } }" >nul 2>&1

if exist "requirements.txt" (
  call :log INFO "Conda bulk install from requirements.txt via conda forge"
  call :log DEBUG "Attempting conda bulk install"
  call "%CONDABAT%" install --yes --override-channels -c conda-forge --prefix "%ENV_PREFIX%" --file requirements.txt >>"%LOG_FILE%" 2>&1
  if errorlevel 1 (
    call :log ERROR "Conda bulk failed attempting per package with tilde conversion"
    call :log DEBUG "Converting tilde ranges and installing per package"
    call :reqs_to_conda_specs "requirements.txt" "~reqs.conda.txt"
    for /f "usebackq delims=" %%L in ("~reqs.conda.txt") do (
      call :log DEBUG "conda install %%L"
      call "%CONDABAT%" install --yes --override-channels -c conda-forge --prefix "%ENV_PREFIX%" %%L >>"%LOG_FILE%" 2>&1
    )
  )
  call :log INFO "Finalizing deps with pip install -r requirements.txt"
  call :log DEBUG "Running pip install -r requirements.txt"
  "%PY_EXE%" -m pip install -r requirements.txt >>"%LOG_FILE%" 2>&1
)

REM Snapshot env and persist runtime.txt if absent
call "%CONDABAT%" list --prefix "%ENV_PREFIX%" --json > conda_env.json 2>>"%LOG_FILE%"
if not exist "runtime.txt" (
  for /f "delims=" %%v in ('"%PY_EXE%" -c "import sys;print(f\"python-{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}\")"') do set "RES_PY=%%v"
  if not "%RES_PY%"=="" (
    > "runtime.txt" echo %RES_PY%
    call :log INFO "Recorded %RES_PY% to runtime.txt"
  )
)
"%PY_EXE%" -c "import sys,subprocess; subprocess.run([sys.executable,'-m','pip','freeze'], check=True)" 1>requirements.txt 2>>"%LOG_FILE%"

REM NI-VISA optional install
set "NEED_VISA=0"
%PSH% "$usesVisa = (Select-String -Path *.py -Pattern '(^|\W)(pyvisa|import\s+visa)(\W|$)' -SimpleMatch -ErrorAction SilentlyContinue); if($usesVisa){ exit 0 } else { exit 1 }" >nul
if errorlevel 1 (rem none) else (set "NEED_VISA=1")
if /I "%VISAINSTALL%"=="no" set "NEED_VISA=0"
if /I "%VISAINSTALL%"=="yes" set "NEED_VISA=1"
if "%NEED_VISA%"=="1" (
  call :log INFO "Ensuring NI VISA is installed silent"
  call :log DEBUG "Checking registry for NI VISA"
  %PSH% "if(Get-ItemProperty -Path 'HKLM:\SOFTWARE\National Instruments\NI-VISA' -ErrorAction SilentlyContinue){ exit 0 } else { exit 1 }" >nul
  if errorlevel 1 (
    set "NI_TMP=%TEMP%\ni-visa-offline.exe"
    curl --fail --location --retry 5 --retry-delay 2 --connect-timeout 20 -o "%NI_TMP%" "%NI_VISA_URL%"
    if not errorlevel 1 (
      start /wait "" "%NI_TMP%" /q
      if errorlevel 1 (call :log ERROR "NI-VISA silent installer returned error") else (call :log INFO "NI-VISA installed")
    ) else (
      call :log ERROR "Failed to download NI-VISA"
    )
  ) else (
    call :log INFO "NI-VISA already present"
  )
) else (
  call :log INFO "NI-VISA install not required or disabled"
)

REM First run to catch missing modules
set "RUN_OK=0"
"%PY_EXE%" "%MAIN_PY%" > "~run.output.tmp" 2> "~run.error.tmp"
set "RC=%ERRORLEVEL%"
if not defined RC set "RC=1"
if "%RC%"=="0" (
  set "RUN_OK=1"
  call :log INFO "Initial run succeeded"
) else (
  call :log ERROR "Initial run failed code %RC% checking for missing module"
  findstr /I /C:"ModuleNotFoundError: No module named '" "~run.error.tmp" > "~missing.mod" 2>nul
  if exist "~missing.mod" (
    if exist "~reqs.generated.flag" (
      call :log INFO "requirements.txt generated this run not looping"
    ) else if exist "~rebuild.once.flag" (
      call :log INFO "Rebuild already attempted once avoid loop"
    ) else (
      > "~rebuild.once.flag" echo 1
      set "REBUILD_OCCURRED=1"
      for /f "usebackq tokens=5 delims=' " %%m in ("~missing.mod") do set "MISS=%%m"
      if not "%MISS%"=="" (
        call :log INFO "Adding missing package %MISS% to requirements.txt and merging auto list"
        echo %MISS%>>requirements.txt
        if exist ~requirements.auto.txt type ~requirements.auto.txt>>requirements.txt
      )
      call :log INFO "Recreating env and reinstalling due to missing package"
      call "%CONDABAT%" env remove --prefix "%ENV_PREFIX%" -y >>"%LOG_FILE%" 2>&1
      if "%PY_VER%"=="" (
        call "%CONDABAT%" create --prefix "%ENV_PREFIX%" -y --override-channels -c conda-forge python >>"%LOG_FILE%" 2>&1
      ) else (
        call "%CONDABAT%" create --prefix "%ENV_PREFIX%" -y --override-channels -c conda-forge python="%PY_VER%" >>"%LOG_FILE%" 2>&1
      )
      set "PY_EXE=%ENV_PREFIX%\python.exe"
      if not exist "%PY_EXE%" (call :log ERROR "Python exe missing after recreate" & exit /b 8)
      call "%CONDABAT%" install --yes --override-channels -c conda-forge --prefix "%ENV_PREFIX%" --file requirements.txt >>"%LOG_FILE%" 2>&1
      if errorlevel 1 (
        call :reqs_to_conda_specs "requirements.txt" "~reqs.conda.txt"
        for /f "usebackq delims=" %%L in ("~reqs.conda.txt") do call "%CONDABAT%" install --yes --override-channels -c conda-forge --prefix "%ENV_PREFIX%" %%L >>"%LOG_FILE%" 2>&1
      )
      "%PY_EXE%" -m pip install -r requirements.txt >>"%LOG_FILE%" 2>&1
      "%PY_EXE%" "%MAIN_PY%" > "~run.output.tmp" 2> "~run.error.tmp"
      set "RC=%ERRORLEVEL%"
      if not defined RC set "RC=1"
      if "%RC%"=="0" (set "RUN_OK=1" & call :log INFO "Run succeeded after rebuild") else (call :log ERROR "Run still failing code %RC%")
    )
  ) else (
    call :log ERROR "Run failed for non missing module reason see ~run.error.tmp"
  )
)

REM Build exe
set "NEED_BUILD=0"
if not exist "dist\%ENV_NAME%.exe" set "NEED_BUILD=1"
if "%NEED_BUILD%"=="0" if exist "~source.hash" if exist "~exe_source.hash" (
  %PSH% "if((Get-Content '~source.hash') -ne (Get-Content '~exe_source.hash')){ exit 0 } else { exit 1 }" >nul
  if not errorlevel 1 (set "NEED_BUILD=1")
)
if "%NEED_BUILD%"=="1" (
  call :log INFO "Building one file executable with PyInstaller name %ENV_NAME%"
  call :log DEBUG "Invoking pyinstaller"
  "%PY_EXE%" -m PyInstaller --onefile --name "%ENV_NAME%" "%MAIN_PY%" >>"%LOG_FILE%" 2>&1
  if errorlevel 1 (
    call :log ERROR "PyInstaller build failed"
  ) else (
    call :log INFO "PyInstaller build succeeded dist\%ENV_NAME%.exe"
    if exist "~source.hash" copy /Y "~source.hash" "~exe_source.hash" >nul
  )
) else (
  call :log INFO "Executable up to date no rebuild needed"
)

REM Final snapshots and rotate
call "%CONDABAT%" list --prefix "%ENV_PREFIX%" --json > conda_env.json 2>>"%LOG_FILE%"
"%PY_EXE%" -c "import sys,subprocess; subprocess.run([sys.executable,'-m','pip','freeze'], check=True)" 1>requirements.txt 2>>"%LOG_FILE%"
if exist "~source.hash" copy /Y "~source.hash" "~source.hash.prev" >nul
call :rotate_log_if_needed  &  call :log DEBUG "Log rotation check at end complete"

if /I "%TEST%"=="1" goto :run_tests

call :self_tests

call :cleanup_requirements_auto
if "%RUN_OK%"=="1" goto :success
goto :fail

:success
call :log INFO "All done Env prefix %ENV_PREFIX% Entrypoint %MAIN_PY%"
del /q "~run.output.tmp" "~run.error.tmp" "~missing.mod" "~reqs.conda.txt" "~reqs.generated.flag" "~rebuild.once.flag" 2>nul
exit /b 0

:fail
call :log ERROR "Completed with errors check ~setup.log and ~run.error.tmp"
exit /b 1

REM ==============================================================================
REM Routines
REM ==============================================================================

:log
REM Fast ASCII logger. Writes all lines to file. Prints DEBUG to console only when VERBOSE=1.
set "LVL=%~1"
set "MSG=%~2"
set "TS=%date% %time%"
>>"%LOG_FILE%" echo [%TS%] [%LVL%] %MSG%
if /I "%LVL%"=="DEBUG" (
  if "%VERBOSE%"=="1" echo [%TS%] [%LVL%] %MSG%
) else (
  echo [%TS%] [%LVL%] %MSG%
)
exit /b 0

:rotate_log_if_needed
if not exist "%LOG_FILE%" exit /b 0
for %%F in ("%LOG_FILE%") do set "SIZE=%%~zF"
if "%SIZE%"=="" exit /b 0
set "MAX=%MAX_LOG_SIZE_BYTES%"
for /f "tokens=1" %%N in ("%SIZE%") do set "SNUM=%%N"
if %SNUM% GTR %MAX% (
  if exist "~setup.prev.log" del /f /q "~setup.prev.log" >nul 2>&1
  move /y "%LOG_FILE%" "~setup.prev.log" >nul
)
exit /b 0

:reqs_to_conda_specs
%PSH% "$in='%~1'; $out='%~2'; " ^
  "$lines=Get-Content $in | Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*-' }; " ^
  "$conv = foreach($l in $lines){ " ^
  "  $m=$l" ^
  "    -replace '\s*;.*$',''" ^
  "    -replace '\[.*?\]',''; " ^
  "  if($m -match '^\s*([A-Za-z0-9_.\-]+)\s*~=\s*([0-9]+)\.([0-9]+)(?:\.([0-9]+))?'){ " ^
  "    $pkg=$matches[1]; $maj=[int]$matches[2]; $min=[int]$matches[3]; $patch=$matches[4]; " ^
  "    $low= if($patch){\"$maj.$min.$patch\"} else {\"$maj.$min\"}; $up=\"$maj.\"+($min+1); " ^
  "    \"$pkg>=$low,<${up}\" " ^
  "  } else { $m } " ^
  "} ; Set-Content $out $conv" >nul 2>&1
exit /b 0

:run_tests
call :log INFO "[TEST] starting test suite"
set "ROOT=%TEMP%\rsb_tests"
if not exist "%ROOT%" mkdir "%ROOT%" >nul 2>&1

set "C1=%ROOT%\t1_no_reqs"
if not exist "%C1%" mkdir "%C1%" >nul 2>&1
>%C1%\main.py echo import requests^&^&print("ok-requests")
pushd "%C1%"
call "%~dp0%~nx0" VERBOSE=1 NOEXE=1 NOINPUT=1 VISAINSTALL=no
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
  call :log ERROR "[TEST] t1_no_reqs failed with %RC%"
  exit /b %RC%
)

set "C2=%ROOT%\t2_compat"
if not exist "%C2%" mkdir "%C2%" >nul 2>&1
>%C2%\main.py echo import colorama^&^&print("ok-colorama")
>%C2%\requirements.txt echo colorama~=0.4
pushd "%C2%"
call "%~dp0%~nx0" VERBOSE=1 NOEXE=1 NOINPUT=1 VISAINSTALL=no
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
  call :log ERROR "[TEST] t2_compat failed with %RC%"
  exit /b %RC%
)

set "C3=%ROOT%\t3_pandas_openpyxl"
if not exist "%C3%" mkdir "%C3%" >nul 2>&1
>%C3%\main.py echo import pandas as pd^&^&print("ok-pandas")
>%C3%\requirements.txt echo pandas~=2.2
pushd "%C3%"
call "%~dp0%~nx0" VERBOSE=1 NOEXE=1 NOINPUT=1 VISAINSTALL=no
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
  call :log ERROR "[TEST] t3_pandas_openpyxl failed with %RC%"
  exit /b %RC%
)

set "C4=%ROOT%\t4_select_default"
if not exist "%C4%" mkdir "%C4%" >nul 2>&1
>%C4%\a_alpha.py echo print("alpha")
>%C4%\z_omega.py echo print("omega")
pushd "%C4%"
call "%~dp0%~nx0" VERBOSE=1 NOEXE=1 NOINPUT=1 VISAINSTALL=no
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
  call :log ERROR "[TEST] t4_select_default failed with %RC%"
  exit /b %RC%
)

call :log INFO "[TEST] suite finished see %ROOT%"
exit /b 0

:self_tests
if not exist "%MINICONDA_DIR%" (call :log ERROR "[TEST] Miniconda dir missing %MINICONDA_DIR%") else (call :log INFO "[TEST] Miniconda dir present")
for /f "delims=" %%v in ('"%ENV_PREFIX%\python.exe" -V 2^>^&1') do set "PYV_LINE=%%v"
call :log INFO "[TEST] Python version %PYV_LINE%"
if exist "conda_env.json" (call :log INFO "[TEST] conda_env.json present") else (call :log ERROR "[TEST] conda_env.json missing")
if exist "requirements.txt" (call :log INFO "[TEST] requirements.txt present") else (call :log ERROR "[TEST] requirements.txt missing")
exit /b 0

:cleanup_requirements_auto
if exist "~requirements.auto.txt" (
  if "%RUN_OK%"=="1" (
    if "%REBUILD_OCCURRED%"=="0" (
      del /q "~requirements.auto.txt"
      call :log INFO "Deleted ~requirements.auto.txt (success without rebuild)"
    ) else (
      call :log INFO "Retained ~requirements.auto.txt (rebuild occurred)"
    )
  ) else (
    call :log INFO "Retained ~requirements.auto.txt (run failed)"
  )
)
exit /b 0
