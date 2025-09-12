# ASCII only
import json, os, re, sys, importlib.util

BASE = os.path.dirname(__file__)
EXTRACT = os.path.join(BASE, "extracted")
OUT = os.path.join(BASE, "~dynamic-results.ndjson")

def ndjson_write(rec):
    with open(OUT, "a", encoding="ascii") as f:
        f.write(json.dumps(rec, separators=(",",":")) + "\n")

def import_from(path, modname):
    spec = importlib.util.spec_from_file_location(modname, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def main():
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
        ndjson_write({"id":"dp.pep440","spec":s,"expected":exp,"actual":got,"pass": got==exp})

    for s, exp in [
        ("pyvisa~=1.14", ["pyvisa >=1.14,<1.15"]),
        ("pyserial>=3.5", ["pyserial >=3.5"]),
        ("pandas==2.2.2", ["pandas ==2.2.2"]),
        ("numpy>=1.26,<2.0", ["numpy >=1.26,<2.0"]),
        ("requests", ["requests"]),
        ("fastapi[standard]>=0.110", ["fastapi >=0.110"]),
    ]:
        got = pr.to_conda(s)
        ndjson_write({"id":"pr.to_conda","spec":s,"expected":exp,"actual":got,"pass": got==exp})

    tmp = os.path.join(BASE, "~tmp.requirements.txt")
    with open(tmp, "w", encoding="ascii") as f:
        f.write("pandas==2.2.2\n")
    pr.INP = tmp
    pr.OUT_CONDA = os.path.join(BASE, "~conda.txt")
    pr.OUT_PIP = os.path.join(BASE, "~pip.txt")
    pr.main()
    conda_lines = open(pr.OUT_CONDA, "r", encoding="ascii").read().splitlines()
    pip_lines = open(pr.OUT_PIP, "r", encoding="ascii").read().splitlines()
    ndjson_write({"id":"pr.pandas.openpyxl","pass": any('openpyxl' in x for x in pip_lines) and any('openpyxl' in x for x in conda_lines),"conda":conda_lines,"pip":pip_lines})

    app_text = "import pyvisa\nimport serial\n"
    visa_hit = bool(re.search(r'(?m)^\s*(from\s+pyvisa|import\s+pyvisa|import\s+visa)\b', app_text))
    serial_hit = bool(re.search(r'(?m)^\s*import\s+serial\b', app_text))
    ndjson_write({"id":"app.visa.detect","pass":visa_hit})
    ndjson_write({"id":"app.pyserial.detect","pass":serial_hit})

if __name__ == "__main__":
    if os.path.exists(OUT): os.remove(OUT)
    main()
