@echo off
setlocal DisableDelayedExpansion
rem Boot strap renamed to run_setup.bat
cd /d "%~dp0"
set "LOG=~setup.log"
set "LOGPREV=~setup.prev.log"
set "PUBLICDOCS=%PUBLIC%\Documents"
set "CONDA_ROOT=%PUBLICDOCS%\Miniconda3"
set "CONDA_BAT=%CONDA_ROOT%\condabin\conda.bat"
set "CONDA_BASE_PY=%CONDA_ROOT%\python.exe"
if not exist "%LOG%" (type nul > "%LOG%")
call :rotate_log
for %%I in ("%CD%") do set "ENVNAME=%%~nI"
set "ENV_PATH=%CONDA_ROOT%\envs\%ENVNAME%"
call :log "[INFO] Workspace: %CD%"
call :log "[INFO] Env name: %ENVNAME%"
call :log "[INFO] Log: %LOG%"
if exist "%CONDA_BAT%" goto have_conda
set "MINI=~Miniconda3-latest-Windows-x86_64.exe"
set "MINIURL=https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe"
curl --version >nul 2>&1
if errorlevel 1 call :die "[ERROR] curl not available (needs Windows 10 1809+)."
if not exist "%MINI%" ( curl -L -# -o "%MINI%" "%MINIURL%" >> "%LOG%" 2>&1 & if errorlevel 1 call :die "[ERROR] Download failed." )
if not exist "%PUBLICDOCS%" mkdir "%PUBLICDOCS%" >> "%LOG%" 2>&1
if not exist "%CONDA_ROOT%" mkdir "%CONDA_ROOT%" >> "%LOG%" 2>&1
"%MINI%" /InstallationType=JustMe /AddToPath=0 /RegisterPython=0 /S /D=%CONDA_ROOT% >> "%LOG%" 2>&1
if errorlevel 1 call :die "[ERROR] Miniconda installer failed."
:have_conda
if not exist "%CONDA_BAT%" call :die "[ERROR] conda.bat not found after install."
call :write_ps_file "~emit_detect_python.ps1" "@'
$OutFile='~detect_python.py'
$Content=@'
import os, re, sys
CD = os.getcwd()
rt_path = os.path.join(CD, "runtime.txt")
pp_path = os.path.join(CD, "pyproject.toml")
def rt_spec(text):
    m = re.search(r'(?:python[-=])?\s*([0-9]+(?:\.[0-9]+){0,2})', text)
    if not m: 
        return ""
    v = m.group(1)
    parts = v.split(".")
    mm = ".".join(parts[:2])
    return f"python={mm}"
def pep440_to_conda(specs):
    out = []
    for raw in re.split(r"\s*,\s*", specs.strip()):
        if not raw: 
            continue
        m = re.match(r"(>=|>|<=|<|==|~=)\s*([0-9]+(?:\.[0-9]+){0,2})\s*$", raw)
        if not m:
            continue
        op, ver = m.group(1), m.group(2)
        if op == "~=":
            parts = [int(x) for x in ver.split(".")]
            if len(parts) == 1:
                upper = f"{parts[0]+1}"
            elif len(parts) >= 2:
                upper = f"{parts[0]}.{parts[1]+1}"
            out.append(f"python>={ver},<%s" % upper)
        else:
            out.append(f"python{op}{ver}")
    return ",".join([x for x in out if x])
def main():
    if os.path.exists(rt_path):
        with open(rt_path, "r", encoding="utf-8", errors="ignore") as f:
            s = rt_spec(f.read())
            if s:
                print(s); return
    if os.path.exists(pp_path):
        with open(pp_path, "r", encoding="utf-8", errors="ignore") as f:
            t = f.read()
        m = re.search(r'requires-python\s*=\s*["\']([^"\']+)["\']', t)
        if m:
            c = pep440_to_conda(m.group(1))
            print(c); return
    print("")
if __name__ == "__main__":
    main()
'@
[IO.File]::WriteAllText($OutFile, $Content, [Text.Encoding]::ASCII)
'@"
powershell -NoProfile -ExecutionPolicy Bypass -File "~emit_detect_python.ps1" >> "%LOG%" 2>&1
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
call :write_ps_file "~emit_pyver.ps1" "@'
$OutFile='~print_pyver.py'
$Content=@'
import sys
print(f"python-{sys.version_info[0]}.{sys.version_info[1]}")
'@
[IO.File]::WriteAllText($OutFile, $Content, [Text.Encoding]::ASCII)
'@"
powershell -NoProfile -ExecutionPolicy Bypass -File "~emit_pyver.ps1" >> "%LOG%" 2>&1
call "%CONDA_BAT%" run -n "%ENVNAME%" python "~print_pyver.py" > "~pyver.txt" 2>> "%LOG%"
for /f "usebackq delims=" %%A in ("~pyver.txt") do set "PYVER=%%A"
if not "%PYVER%"=="" ( > "runtime.txt" echo %PYVER% )
call :write_ps_file "~emit_env_condarc.ps1" "@'
$OutFile = '%ENV_PATH%\.condarc'
$Content = @'
channels:
  - conda-forge
channel_priority: strict
show_channel_urls: true
'@
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
[IO.File]::WriteAllText($OutFile, $Content, [Text.Encoding]::ASCII)
'@"
powershell -NoProfile -ExecutionPolicy Bypass -File "~emit_env_condarc.ps1" >> "%LOG%" 2>&1
call :write_ps_file "~emit_prep_requirements.ps1" "@'
$OutFile='~prep_requirements.py'
$Content=@'
import os, re, sys
INP = sys.argv[1] if len(sys.argv)>1 else "requirements.txt"
OUT_CONDA = "~reqs_conda.txt"
OUT_PIP   = "~reqs_pip.txt"
def norm(line): return line.strip()
def split_marker(s): return s.split(";")[0].strip()
def strip_extras(name): return re.sub(r"\[.*?\]", "", name)
def bump_for_compatible(v):
    parts = [int(x) for x in v.split(".")]
    if len(parts)==1: return f"{parts[0]+1}"
    if len(parts)==2: return f"{parts[0]}.{parts[1]+1}"
    return f"{parts[0]}.{parts[1]+1}"
def to_conda(line):
    s = split_marker(line)
    if not s or s.startswith("#"): return []
    if s.startswith("-e ") or s.startswith("--editable") or s.startswith("git+") or "://" in s: return []
    m = re.match(r"^\s*([A-Za-z0-9_.-]+)\s*(.*)$", s)
    if not m: return []
    name, rest = m.group(1), m.group(2).strip()
    name = strip_extras(name)
    if not rest: return [name]
    rest = rest.replace(" ", "")
    m2 = re.match(r"^~=\s*([0-9]+(?:\.[0-9]+){0,2})$", rest)
    if m2:
        base = m2.group(1)
        upper = bump_for_compatible(base)
        return [f"{name} >={base},<{upper}"]
    parts = [p for p in rest.split(",") if p]
    ops=[]
    for p in parts:
        m3 = re.match(r"^(>=|<=|==|!=|>|<)\s*([0-9]+(?:\.[0-9]+){0,5})$", p)
        if m3: ops.append(f"{m3.group(1)}{m3.group(2)}")
    return [f"{name} " + ",".join(ops)] if ops else [name]
def to_pip(line):
    s = split_marker(line)
    if not s or s.startswith("#"): return None
    m = re.match(r"^\s*([A-Za-z0-9_.-]+)(.*)$", s)
    if not m: return s.strip()
    name, rest = m.group(1), m.group(2)
    name = strip_extras(name)
    return (name + rest).strip()
def main():
    have = os.path.exists(INP) and os.path.getsize(INP) > 0
    lines=[]
    if have:
        with open(INP,"r",encoding="utf-8",errors="ignore") as f:
            lines=[norm(x) for x in f if norm(x)]
    conda_specs=[]
    pip_specs=[]
    for line in lines:
        c=to_conda(line)
        if c: conda_specs.extend(c)
        p=to_pip(line)
        if p: pip_specs.append(p)
    names_lower=[re.split(r"[<>=!~,\s]", x, 1)[0].strip().lower() for x in pip_specs]
    if "pandas" in names_lower and "openpyxl" not in names_lower:
        pip_specs.append("openpyxl"); conda_specs.append("openpyxl")
    with open(OUT_CONDA,"w",encoding="ascii") as f:
        for s in conda_specs:
            if s: f.write(s+"\n")
    with open(OUT_PIP,"w",encoding="ascii") as f:
        for s in pip_specs:
            if s: f.write(s+"\n")
    sys.stdout.write("OK\n")
if __name__=="__main__":
    main()
'@
[IO.File]::WriteAllText($OutFile, $Content, [Text.Encoding]::ASCII)
'@"
powershell -NoProfile -ExecutionPolicy Bypass -File "~emit_prep_requirements.ps1" >> "%LOG%" 2>&1
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
call :write_ps_file "~emit_entry_finder.ps1" "@'
$OutTxt='~entry.txt'
$code = @'
import os
def find_entry():
    files = [f for f in os.listdir('.') if f.endswith('.py') and not f.startswith('~')]
    for f in files:
        try:
            with open(f,'r',encoding='utf-8',errors='ignore') as h:
                t = h.read()
            if \"if __name__ == '__main__'\" in t:
                return f
        except Exception:
            pass
    return files[0] if files else \"\"
print(find_entry())
'@
$TmpPy='~find_entry.py'
[IO.File]::WriteAllText($TmpPy, $code, [Text.Encoding]::ASCII)
& '%CONDA_ROOT%\python.exe' $TmpPy | Out-File -Encoding ASCII -NoNewline $OutTxt
'@"
powershell -NoProfile -ExecutionPolicy Bypass -File "~emit_entry_finder.ps1" >> "%LOG%" 2>&1
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
"if(Test-Path '%LOG%'){if((Get-Item '%LOG%').Length -gt 10485760){Move-Item -Force '%LOG%' '%LOGPREV%'}}" >nul 2>&1
exit /b 0
:write_ps_file
set "PSFILE=%~1"
set "PAYLOAD=%~2"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"$c=%PAYLOAD%; [IO.File]::WriteAllText('%PSFILE%',$c,[Text.Encoding]::ASCII)" >nul 2>&1
if errorlevel 1 ( call :die "[ERROR] Could not write %PSFILE%" )
exit /b 0
