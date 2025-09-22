@echo off
setlocal DisableDelayedExpansion
rem Boot strap renamed to run_setup.bat
cd /d "%~dp0"
set "LOG=~setup.log"
set "LOGPREV=~setup.prev.log"
if not exist "%LOG%" (type nul > "%LOG%")
call :rotate_log
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

  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$code = @'
import os, re, sys

CD = os.getcwd()
rt_path = os.path.join(CD, 'runtime.txt')
pp_path = os.path.join(CD, 'pyproject.toml')

def rt_spec(text):
    match = re.search(r'(?:python[-=])?\s*([0-9]+(?:\.[0-9]+){0,2})', text)
    if not match:
        return ''
    value = match.group(1)
    parts = value.split('.')
    major_minor = '.'.join(parts[:2])
    return f'python={major_minor}'

def pep440_to_conda(specs):
    out = []
    for raw in re.split(r'\s*,\s*', specs.strip()):
        if not raw:
            continue
        match = re.match(r'(>=|>|<=|<|==|~=)\s*([0-9]+(?:\.[0-9]+){0,2})\s*$', raw)
        if not match:
            continue
        op, ver = match.group(1), match.group(2)
        if op == '~=':
            parts = [int(x) for x in ver.split('.')]
            if len(parts) == 1:
                upper = str(parts[0] + 1)
            else:
                upper = f"{parts[0]}.{parts[1] + 1}"
            out.append(f'python>={ver},<{upper}')
        else:
            out.append(f'python{op}{ver}')
    return ','.join([item for item in out if item])

def main():
    if os.path.exists(rt_path):
        with open(rt_path, 'r', encoding='utf-8', errors='ignore') as handle:
            spec = rt_spec(handle.read())
            if spec:
                print(spec)
                return
    if os.path.exists(pp_path):
        with open(pp_path, 'r', encoding='utf-8', errors='ignore') as handle:
            text = handle.read()
        match = re.search(r'requires-python\s*=\s*["\']([^"\']+)["\']', text)
        if match:
            converted = pep440_to_conda(match.group(1))
            print(converted)
            return
    print('')

if __name__ == '__main__':
    main()
'@
Set-Content -Path '~detect_python.py' -Encoding ASCII -Value $code" >> "%LOG%" 2>&1
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

  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$code = @'
import sys

print(f"python-{sys.version_info[0]}.{sys.version_info[1]}")
'@
Set-Content -Path '~print_pyver.py' -Encoding ASCII -Value $code" >> "%LOG%" 2>&1
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



  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$code = @'
import os, re, sys

INP = sys.argv[1] if len(sys.argv) > 1 else 'requirements.txt'
OUT_CONDA = '~reqs_conda.txt'
OUT_PIP = '~reqs_pip.txt'

def norm(line):
    return line.strip()

def split_marker(text):
    return text.split(';')[0].strip()

def strip_extras(name):
    return re.sub(r"\[.*?\]", '', name)

def bump_for_compatible(value):
    parts = [int(x) for x in value.split('.')]
    if len(parts) == 1:
        return str(parts[0] + 1)
    if len(parts) >= 2:
        return f"{parts[0]}.{parts[1] + 1}"
    return value

def to_conda(line):
    section = split_marker(line)
    if not section or section.startswith('#'):
        return []
    if section.startswith('-e ') or section.startswith('--editable') or section.startswith('git+') or '://' in section:
        return []
    match = re.match(r"^\s*([A-Za-z0-9_.-]+)\s*(.*)$", section)
    if not match:
        return []
    name, rest = match.group(1), match.group(2).strip()
    name = strip_extras(name)
    if not rest:
        return [name]
    rest = rest.replace(' ', '')
    match_compat = re.match(r"^~=\s*([0-9]+(?:\.[0-9]+){0,2})$", rest)
    if match_compat:
        base = match_compat.group(1)
        upper = bump_for_compatible(base)
        return [f"{name} >={base},<{upper}"]
    segments = [part for part in rest.split(',') if part]
    ops = []
    for part in segments:
        m = re.match(r"^(>=|<=|==|!=|>|<)\s*([0-9]+(?:\.[0-9]+){0,5})$", part)
        if m:
            ops.append(f"{m.group(1)}{m.group(2)}")
    return [f"{name} " + ','.join(ops)] if ops else [name]

def to_pip(line):
    section = split_marker(line)
    if not section or section.startswith('#'):
        return None
    match = re.match(r"^\s*([A-Za-z0-9_.-]+)(.*)$", section)
    if not match:
        return section.strip()
    name, rest = match.group(1), match.group(2)
    name = strip_extras(name)
    return (name + rest).strip()

def main():
    have_file = os.path.exists(INP) and os.path.getsize(INP) > 0
    lines = []
    if have_file:
        with open(INP, 'r', encoding='utf-8', errors='ignore') as handle:
            lines = [norm(item) for item in handle if norm(item)]
    conda_specs = []
    pip_specs = []
    for line in lines:
        conda_specs.extend(to_conda(line))
        pip_entry = to_pip(line)
        if pip_entry:
            pip_specs.append(pip_entry)
    names_lower = [re.split(r"[<>=!~,\s]", value, 1)[0].strip().lower() for value in pip_specs]
    if 'pandas' in names_lower and 'openpyxl' not in names_lower:
        pip_specs.append('openpyxl')
        conda_specs.append('openpyxl')
    with open(OUT_CONDA, 'w', encoding='ascii') as handle:
        for item in conda_specs:
            if item:
                handle.write(item + '\n')
    with open(OUT_PIP, 'w', encoding='ascii') as handle:
        for item in pip_specs:
            if item:
                handle.write(item + '\n')
    sys.stdout.write('OK\n')

if __name__ == '__main__':
    main()
'@
Set-Content -Path '~prep_requirements.py' -Encoding ASCII -Value $code" >> "%LOG%" 2>&1
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

  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$code = @'
import os, re, sys

ROOT = os.getcwd()
PATTERNS = [
    r"(?m)^\s*(?:from\s+pyvisa|import\s+pyvisa)",
    r"(?m)^\s*import\s+visa",
]

def needs_visa():
    for current, dirs, files in os.walk(ROOT):
        dirs[:] = [item for item in dirs if not item.startswith(('~', '.'))]
        for name in files:
            if not name.endswith('.py') or name.startswith('~'):
                continue
            path = os.path.join(current, name)
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as handle:
                    text = handle.read()
            except OSError:
                continue
            for pattern in PATTERNS:
                if re.search(pattern, text):
                    return True
    return False

def main():
    sys.stdout.write('1' if needs_visa() else '0')

if __name__ == '__main__':
    main()
'@
Set-Content -Path '~detect_visa.py' -Encoding ASCII -Value $code" >> "%LOG%" 2>&1
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

  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$code = @'
import os

def find_entry():
    files = [name for name in os.listdir('.') if name.endswith('.py') and not name.startswith('~')]
    for name in files:
        try:
            with open(name, 'r', encoding='utf-8', errors='ignore') as handle:
                text = handle.read()
            if "if __name__ == '__main__'" in text:
                return name
        except Exception:
            continue
    return files[0] if files else ''

print(find_entry())
'@
Set-Content -Path '~find_entry.py' -Encoding ASCII -Value $code" >> "%LOG%" 2>&1
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
"if (Test-Path '%LOG%') { if ((Get-Item '%LOG%').Length -gt 10485760) { Move-Item -Force '%LOG%' '%LOGPREV%' } }" >nul 2>&1
exit /b 0
