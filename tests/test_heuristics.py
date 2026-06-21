# ASCII only. Cross-platform unit tests for HP_PREP_REQUIREMENTS heuristic rules.
# Covers all 6 REQ-005.8 rules, the HP_DISABLE_HEURISTICS kill-switch, idempotency,
# and no-false-positives. Runnable with: python -m unittest tests.test_heuristics -v
import base64
import importlib.util
import os
import re
import shutil
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(__file__))
RUN_SETUP = os.path.join(REPO, "run_setup.bat")

# Module-level singleton: HP_PREP_REQUIREMENTS extracted and imported once.
_PR_MODULE = None


def _extract_payload(varname):
    pattern = re.compile(r'^set "' + re.escape(varname) + r'=(.*)"$')
    with open(RUN_SETUP, "r", encoding="ascii", errors="ignore") as fh:
        for line in fh:
            m = pattern.match(line.rstrip("\r\n"))
            if m:
                return base64.b64decode(m.group(1))
    raise RuntimeError(f"{varname} not found in run_setup.bat")


def _get_pr():
    global _PR_MODULE
    if _PR_MODULE is None:
        tmp = tempfile.mkdtemp(prefix="heuristics.")
        script = os.path.join(tmp, "prep_requirements.py")
        with open(script, "wb") as fh:
            fh.write(_extract_payload("HP_PREP_REQUIREMENTS"))
        spec = importlib.util.spec_from_file_location("pr", script)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _PR_MODULE = mod
    return _PR_MODULE


def _run(tmp_dir, reqs, extra_env=None):
    pr = _get_pr()
    inp = os.path.join(tmp_dir, "requirements.txt")
    out_conda = os.path.join(tmp_dir, "reqs_conda.txt")
    out_pip = os.path.join(tmp_dir, "reqs_pip.txt")
    with open(inp, "w", encoding="ascii") as fh:
        fh.write(reqs)
    pr.INP = inp
    pr.OUT_CONDA = out_conda
    pr.OUT_PIP = out_pip
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
    with open(out_conda, encoding="ascii") as fh:
        conda = fh.read().splitlines()
    with open(out_pip, encoding="ascii") as fh:
        pip = fh.read().splitlines()
    return conda, pip


def _has(lines, pkg):
    return any(pkg.lower() in ln.lower() for ln in lines)


class _Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="heuristics.")

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)


class TestPandas(_Base):
    def test_adds_openpyxl(self):
        conda, pip = _run(self._tmp, "pandas\n")
        self.assertTrue(_has(conda, "openpyxl") and _has(pip, "openpyxl"))

    def test_adds_xlsxwriter(self):
        conda, pip = _run(self._tmp, "pandas\n")
        self.assertTrue(_has(conda, "xlsxwriter") and _has(pip, "xlsxwriter"))

    def test_no_dup_openpyxl(self):
        _, pip = _run(self._tmp, "pandas\nopenpyxl\n")
        self.assertEqual(sum(1 for ln in pip if "openpyxl" in ln.lower()), 1)

    def test_no_dup_xlsxwriter(self):
        _, pip = _run(self._tmp, "pandas\nxlsxwriter\n")
        self.assertEqual(sum(1 for ln in pip if "xlsxwriter" in ln.lower()), 1)

    def test_pandas_with_openpyxl_explicit_still_adds_xlsxwriter(self):
        conda, pip = _run(self._tmp, "pandas\nopenpyxl\n")
        self.assertTrue(_has(conda, "xlsxwriter") and _has(pip, "xlsxwriter"))

    def test_pandas_with_xlsxwriter_explicit_still_adds_openpyxl(self):
        conda, pip = _run(self._tmp, "pandas\nxlsxwriter\n")
        self.assertTrue(_has(conda, "openpyxl") and _has(pip, "openpyxl"))

    def test_pandas_capitalized_triggers(self):
        # Package names are case-insensitive per PEP 508; Pandas == pandas
        conda, pip = _run(self._tmp, "Pandas\n")
        self.assertTrue(_has(conda, "openpyxl") and _has(pip, "openpyxl"))
        self.assertTrue(_has(conda, "xlsxwriter") and _has(pip, "xlsxwriter"))

    def test_pandas_extras_triggers(self):
        # pandas[excel] is valid pip extras syntax; extras must be stripped before name lookup
        conda, pip = _run(self._tmp, "pandas[excel]\n")
        self.assertTrue(_has(conda, "openpyxl") and _has(pip, "openpyxl"))
        self.assertTrue(_has(conda, "xlsxwriter") and _has(pip, "xlsxwriter"))


class TestRequests(_Base):
    def test_adds_certifi(self):
        conda, pip = _run(self._tmp, "requests\n")
        self.assertTrue(_has(conda, "certifi") and _has(pip, "certifi"))


class TestSQLAlchemy(_Base):
    def test_adds_pymysql(self):
        conda, pip = _run(self._tmp, "sqlalchemy\n")
        self.assertTrue(_has(conda, "pymysql") and _has(pip, "pymysql"))


class TestMatplotlib(_Base):
    def test_adds_tk(self):
        # tk ships as a conda system package; verify conda output only
        conda, _ = _run(self._tmp, "matplotlib\n")
        self.assertTrue(_has(conda, "tk"))


class TestCrypto(_Base):
    def test_cryptography_adds_cffi(self):
        conda, pip = _run(self._tmp, "cryptography\n")
        self.assertTrue(_has(conda, "cffi") and _has(pip, "cffi"))

    def test_pycryptodome_adds_cffi(self):
        conda, pip = _run(self._tmp, "pycryptodome\n")
        self.assertTrue(_has(conda, "cffi") and _has(pip, "cffi"))


class TestDisable(_Base):
    def test_kill_switch(self):
        conda, pip = _run(self._tmp, "pandas\nrequests\n",
                          extra_env={"HP_DISABLE_HEURISTICS": "1"})
        self.assertFalse(_has(conda, "openpyxl"))
        self.assertFalse(_has(pip, "certifi"))


class TestNoFalsePositives(_Base):
    def test_unrelated_package(self):
        conda, pip = _run(self._tmp, "flask\n")
        for pkg in ("openpyxl", "certifi", "pymysql", "cffi"):
            self.assertFalse(_has(conda, pkg), f"unexpected {pkg} in conda")
            self.assertFalse(_has(pip, pkg), f"unexpected {pkg} in pip")


if __name__ == "__main__":
    unittest.main()
