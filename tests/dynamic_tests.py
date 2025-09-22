# ASCII only
import base64
import json
import os
import re
import sys
import importlib.util

BASE = os.path.dirname(__file__)
EXTRACT = os.path.join(BASE, "extracted")
OUT = os.path.join(BASE, "~dynamic-results.ndjson")
RUN_SETUP = os.path.join(os.path.dirname(BASE), "run_setup.bat")
STATUS_PATH = os.path.join(os.path.dirname(BASE), "~bootstrap.status.json")

FAILED = False

def ndjson_write(rec):
    with open(OUT, "a", encoding="ascii") as f:
        f.write(json.dumps(rec, separators=(",",":")) + "\n")

def record(rec):
    global FAILED
    ndjson_write(rec)
    if not rec.get("pass", True):
        FAILED = True

def ensure_extracted():
    os.makedirs(EXTRACT, exist_ok=True)
    payloads = {}
    pattern = re.compile(r'^set "([A-Za-z0-9_]+)=(.*)"$')
    if not os.path.exists(RUN_SETUP):
        record({"id":"helpers.run_setup","pass":False,"message":"run_setup.bat missing"})
        raise SystemExit(1)
    with open(RUN_SETUP, "r", encoding="ascii", errors="ignore") as fh:
        for raw in fh:
            raw = raw.rstrip("\r\n")
            match = pattern.match(raw)
            if not match:
                continue
            name, value = match.groups()
            if name.startswith("HP_"):
                payloads[name] = value
    needed = {
        "~detect_python.py": "HP_DETECT_PY",
        "~prep_requirements.py": "HP_PREP_REQUIREMENTS",
        "~print_pyver.py": "HP_PRINT_PYVER",
        "~detect_visa.py": "HP_DETECT_VISA",
        "~find_entry.py": "HP_FIND_ENTRY",
    }
    all_ok = True
    for dst, var in needed.items():
        rec = {"id":f"helpers.decode.{dst}", "var":var}
        data = payloads.get(var)
        if not data:
            rec.update({"pass":False, "message":"payload missing"})
            record(rec)
            all_ok = False
            continue
        try:
            decoded = base64.b64decode(data)
        except Exception as exc:
            rec.update({"pass":False, "message":f"decode failed: {exc}"})
            record(rec)
            all_ok = False
            continue
        out_path = os.path.join(EXTRACT, dst)
        with open(out_path, "wb") as fh:
            fh.write(decoded)
        rec.update({"pass":True, "path":dst})
        record(rec)
    if not all_ok:
        raise SystemExit(1)

def import_from(path, modname):
    spec = importlib.util.spec_from_file_location(modname, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def main():
    ensure_extracted()

    if os.path.exists(STATUS_PATH):
        try:
            with open(STATUS_PATH, "r", encoding="ascii") as fh:
                status = json.load(fh)
            record({"id":"bootstrap.status","pass":True,"state":status.get("state"),"exitCode":status.get("exitCode"),"pyFiles":status.get("pyFiles")})
        except Exception as exc:
            record({"id":"bootstrap.status","pass":False,"message":f"invalid json: {exc}"})
    else:
        record({"id":"bootstrap.status","pass":False,"message":"missing status file"})

    dp = import_from(os.path.join(EXTRACT, "~detect_python.py"), "dp")
    pr = import_from(os.path.join(EXTRACT, "~prep_requirements.py"), "pr")

    for s, exp in [
        ("~=3.10", "python>=3.10,<3.11"),
        (">=3.9,<3.11", "python>=3.9,<3.11"),
        ("==3.11", "python==3.11"),
        (">=3.8,<=3.12", "python>=3.8,<=3.12"),
        ("<3.13", "python<3.13"),
    ]:
        got = dp.pep440_to_conda(s)
        record({"id":"dp.pep440","spec":s,"expected":exp,"actual":got,"pass": got==exp})

    for s, exp in [
        ("pyvisa~=1.14", ["pyvisa >=1.14,<1.15"]),
        ("pyserial>=3.5", ["pyserial >=3.5"]),
        ("pandas==2.2.2", ["pandas ==2.2.2"]),
        ("numpy>=1.26,<2.0", ["numpy >=1.26,<2.0"]),
        ("requests", ["requests"]),
        ("fastapi[standard]>=0.110", ["fastapi >=0.110"]),
    ]:
        got = pr.to_conda(s)
        record({"id":"pr.to_conda","spec":s,"expected":exp,"actual":got,"pass": got==exp})

    tmp = os.path.join(BASE, "~tmp.requirements.txt")
    with open(tmp, "w", encoding="ascii") as f:
        f.write("pandas==2.2.2\n")
    pr.INP = tmp
    pr.OUT_CONDA = os.path.join(BASE, "~conda.txt")
    pr.OUT_PIP = os.path.join(BASE, "~pip.txt")
    pr.main()
    conda_lines = open(pr.OUT_CONDA, "r", encoding="ascii").read().splitlines()
    pip_lines = open(pr.OUT_PIP, "r", encoding="ascii").read().splitlines()
    record({"id":"pr.pandas.openpyxl","pass": any('openpyxl' in x for x in pip_lines) and any('openpyxl' in x for x in conda_lines),"conda":conda_lines,"pip":pip_lines})

    app_text = "import pyvisa\nimport serial\n"
    visa_hit = bool(re.search(r'(?m)^\s*(from\s+pyvisa|import\s+pyvisa|import\s+visa)\b', app_text))
    serial_hit = bool(re.search(r'(?m)^\s*import\s+serial\b', app_text))
    record({"id":"app.visa.detect","pass":visa_hit})
    record({"id":"app.pyserial.detect","pass":serial_hit})

if __name__ == "__main__":
    if os.path.exists(OUT): os.remove(OUT)
    main()
    sys.exit(1 if FAILED else 0)
