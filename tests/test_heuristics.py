# ASCII only. Cross-platform unit tests for HP_PREP_REQUIREMENTS heuristic rules.
# Extracts the embedded helper from run_setup.bat and exercises all 6 heuristic
# dependency-augmentation rules (REQ-005), the kill-switch, and idempotency.
import base64
import importlib.util
import os
import re
import pytest

REPO = os.path.dirname(os.path.dirname(__file__))
RUN_SETUP = os.path.join(REPO, "run_setup.bat")


def _extract_payload(varname):
    pattern = re.compile(r'^set "' + re.escape(varname) + r'=(.*)"$')
    with open(RUN_SETUP, "r", encoding="ascii", errors="ignore") as fh:
        for line in fh:
            m = pattern.match(line.rstrip("\r\n"))
            if m:
                return base64.b64decode(m.group(1))
    raise RuntimeError(f"{varname} not found in run_setup.bat")


@pytest.fixture(scope="session")
def pr(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("heuristics")
    script = tmp / "prep_requirements.py"
    script.write_bytes(_extract_payload("HP_PREP_REQUIREMENTS"))
    spec = importlib.util.spec_from_file_location("pr", script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _run(pr, tmp_path, reqs, extra_env=None):
    inp = tmp_path / "requirements.txt"
    out_conda = tmp_path / "reqs_conda.txt"
    out_pip = tmp_path / "reqs_pip.txt"
    inp.write_text(reqs, encoding="ascii")
    pr.INP = str(inp)
    pr.OUT_CONDA = str(out_conda)
    pr.OUT_PIP = str(out_pip)
    saved = {}
    try:
        for k, v in (extra_env or {}).items():
            saved[k] = os.environ.get(k)
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        pr.main()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    conda = out_conda.read_text(encoding="ascii").splitlines()
    pip = out_pip.read_text(encoding="ascii").splitlines()
    return conda, pip


def _has(lines, pkg):
    return any(pkg.lower() in ln.lower() for ln in lines)


class TestPandas:
    def test_adds_openpyxl(self, pr, tmp_path):
        conda, pip = _run(pr, tmp_path, "pandas\n")
        assert _has(conda, "openpyxl") and _has(pip, "openpyxl")

    def test_adds_xlsxwriter(self, pr, tmp_path):
        conda, pip = _run(pr, tmp_path, "pandas\n")
        assert _has(conda, "xlsxwriter") and _has(pip, "xlsxwriter")

    def test_no_dup_openpyxl(self, pr, tmp_path):
        _, pip = _run(pr, tmp_path, "pandas\nopenpyxl\n")
        assert sum(1 for ln in pip if "openpyxl" in ln.lower()) == 1


class TestRequests:
    def test_adds_certifi(self, pr, tmp_path):
        conda, pip = _run(pr, tmp_path, "requests\n")
        assert _has(conda, "certifi") and _has(pip, "certifi")


class TestSQLAlchemy:
    def test_adds_pymysql(self, pr, tmp_path):
        conda, pip = _run(pr, tmp_path, "sqlalchemy\n")
        assert _has(conda, "pymysql") and _has(pip, "pymysql")


class TestMatplotlib:
    def test_adds_tk(self, pr, tmp_path):
        # tk ships as a conda package; verify conda output only
        conda, _ = _run(pr, tmp_path, "matplotlib\n")
        assert _has(conda, "tk")


class TestCrypto:
    def test_cryptography_adds_cffi(self, pr, tmp_path):
        conda, pip = _run(pr, tmp_path, "cryptography\n")
        assert _has(conda, "cffi") and _has(pip, "cffi")

    def test_pycryptodome_adds_cffi(self, pr, tmp_path):
        conda, pip = _run(pr, tmp_path, "pycryptodome\n")
        assert _has(conda, "cffi") and _has(pip, "cffi")


class TestDisable:
    def test_kill_switch(self, pr, tmp_path):
        conda, pip = _run(pr, tmp_path, "pandas\nrequests\n",
                          extra_env={"HP_DISABLE_HEURISTICS": "1"})
        assert not _has(conda, "openpyxl")
        assert not _has(pip, "certifi")


class TestNoFalsePositives:
    def test_unrelated_package(self, pr, tmp_path):
        conda, pip = _run(pr, tmp_path, "flask\n")
        for pkg in ("openpyxl", "certifi", "pymysql", "cffi"):
            assert not _has(conda, pkg), f"unexpected {pkg} in conda"
            assert not _has(pip, pkg), f"unexpected {pkg} in pip"
