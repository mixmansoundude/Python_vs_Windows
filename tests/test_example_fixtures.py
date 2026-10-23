"""Item 74: the curated example apps under tests/fixtures/examples stay honest.

Four small programs a person can drop next to run_setup.bat: stdlib only, pandas + Excel, a window that closes
itself, and a program with a sibling module. CI scenarios read them (tests/selfapps_example_apps.ps1 runs three of
them through the bootstrapper, tests/selfapps_pandas_excel.ps1 reads the fourth), so a fixture that drifts from what
its scenario expects fails there, and a fixture that stops being a plain example fails here:
  - the folder holds exactly the files listed in APPS (a stray file changes the Python file count the scenarios
    assert, and a leftover __pycache__ is the only thing ignored);
  - every file is ASCII (batch, PowerShell and Python all read these, README ASCII rule);
  - every .py compiles in memory (no .pyc is written, same reason as tools/preflight_check.py);
  - every import is the standard library, a sibling file in the same folder, or a package the app declares, so a
    fixture cannot quietly depend on something its folder does not provide;
  - README.txt names every folder.
The wiring tests pin the places that read the folder, so moving a fixture back inline fails here instead of leaving
an unused file behind. Synthetic trees prove each rule can fail.
"""
import ast
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "examples"

# name -> files the folder holds, the third-party import names the app may use (the folder declares them)
APPS = {
    "stdlib_single": {"files": {"solo.py"}, "third_party": set()},
    "pandas_excel": {"files": {"app.py", "requirements.txt"}, "third_party": {"pandas"}},
    "gui_exits": {"files": {"app.py"}, "third_party": set()},
    "multifile_sibling": {"files": {"main.py", "helper.py"}, "third_party": set()},
}

# Used only when this interpreter has no sys.stdlib_module_names (before 3.10): the names the fixtures import.
_STDLIB_FALLBACK = {"sys", "os", "time", "tkinter"}


def _is_stdlib(name):
    names = getattr(sys, "stdlib_module_names", None)
    if names is None:
        return name in _STDLIB_FALLBACK
    return name in names


def _top_level_imports(tree):
    found = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                found.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            found.add(node.module.split(".")[0])
    return found


def check_app(root, name, spec):
    """Return a list of problems with one example folder; empty means honest."""
    problems = []
    folder = root / name
    if not folder.is_dir():
        return ["%s: folder is missing (expected %s)" % (name, folder)]
    present = {p.name for p in folder.iterdir() if p.name != "__pycache__"}
    if present != spec["files"]:
        problems.append(
            "%s: files are %s, expected exactly %s" % (name, sorted(present), sorted(spec["files"]))
        )
    siblings = {p.stem for p in folder.glob("*.py")}
    for path in sorted(folder.iterdir()):
        if not path.is_file():
            continue
        data = path.read_bytes()
        try:
            data.decode("ascii")
        except UnicodeDecodeError as exc:
            problems.append("%s/%s: not ASCII (%s)" % (name, path.name, exc))
            continue
        if path.suffix != ".py":
            continue
        try:
            tree = ast.parse(data, filename=str(path))
            compile(data, str(path), "exec", dont_inherit=True)
        except (SyntaxError, ValueError) as exc:
            problems.append("%s/%s: does not compile (%s)" % (name, path.name, exc))
            continue
        for mod in sorted(_top_level_imports(tree)):
            if _is_stdlib(mod) or mod in siblings or mod in spec["third_party"]:
                continue
            problems.append(
                "%s/%s: imports %r, which is neither the standard library, a sibling file nor a declared package"
                % (name, path.name, mod)
            )
    if spec["third_party"]:
        req = folder / "requirements.txt"
        listed = set()
        if req.is_file():
            for line in req.read_text(encoding="ascii", errors="replace").splitlines():
                token = line.strip().split("==")[0].split(">=")[0].split("~=")[0].strip().lower()
                if token and not token.startswith("#"):
                    listed.add(token)
        for pkg in sorted(spec["third_party"]):
            if pkg not in listed:
                problems.append("%s: requirements.txt does not list %s" % (name, pkg))
    return problems


def check_tree(root):
    """Problems for the whole examples folder, including the README that names every app."""
    problems = []
    for name, spec in APPS.items():
        problems.extend(check_app(root, name, spec))
    readme = root / "README.txt"
    if not readme.is_file():
        problems.append("README.txt is missing in %s" % root)
    else:
        text = readme.read_text(encoding="ascii", errors="replace")
        for name in APPS:
            if name not in text:
                problems.append("README.txt does not mention %s" % name)
    return problems


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text.replace("\r\n", "\n").encode("utf-8"))


GOOD = {
    "stdlib_single/solo.py": 'if __name__ == "__main__":\n    print("from-single")\n',
    "pandas_excel/app.py": 'import pandas as pd\n\ndf = pd.DataFrame({"a": [1, 2]})\ndf.to_excel("out.xlsx")\n',
    "pandas_excel/requirements.txt": "pandas\nopenpyxl\n",
    "gui_exits/app.py": "import tkinter as tk\n\nroot = tk.Tk()\nroot.after(500, root.destroy)\nroot.mainloop()\n",
    "multifile_sibling/main.py": "import helper\n\nprint(helper.greeting(\"x\"))\n",
    "multifile_sibling/helper.py": 'def greeting(name):\n    return "hello " + name\n',
    "README.txt": "stdlib_single pandas_excel gui_exits multifile_sibling\n",
}


def build_tree(root, overrides=None, drop=()):
    files = dict(GOOD)
    files.update(overrides or {})
    for rel in drop:
        files.pop(rel, None)
    for rel, text in files.items():
        _write(root / rel, text)
    return root


class RealTreeIsHonest(unittest.TestCase):
    def test_examples_folder_exists_and_is_clean(self):
        self.assertEqual(check_tree(FIXTURES), [], "tests/fixtures/examples is not a clean set of examples")


class CheckerCanFail(unittest.TestCase):
    """Each rule above is proven on a synthetic tree, so a green real tree cannot be a checker that never fails."""

    def _problems(self, **kw):
        with tempfile.TemporaryDirectory() as tmp:
            return check_tree(build_tree(Path(tmp), **kw))

    def test_good_synthetic_tree_has_no_problems(self):
        self.assertEqual(self._problems(), [])

    def test_missing_folder_is_reported(self):
        out = self._problems(drop=["gui_exits/app.py"])
        self.assertTrue(any("gui_exits" in p for p in out), out)

    def test_extra_file_is_reported(self):
        out = self._problems(overrides={"stdlib_single/extra.py": "x = 1\n"})
        self.assertTrue(any("expected exactly" in p for p in out), out)

    def test_non_ascii_is_reported(self):
        out = self._problems(overrides={"stdlib_single/solo.py": 'print("caf' + chr(0xE9) + '")\n'})
        self.assertTrue(any("not ASCII" in p for p in out), out)

    def test_syntax_error_is_reported(self):
        out = self._problems(overrides={"stdlib_single/solo.py": "def broken(:\n"})
        self.assertTrue(any("does not compile" in p for p in out), out)

    def test_undeclared_third_party_import_is_reported(self):
        out = self._problems(overrides={"stdlib_single/solo.py": "import requests\n"})
        self.assertTrue(any("requests" in p for p in out), out)

    def test_unresolved_sibling_import_is_reported(self):
        out = self._problems(overrides={"multifile_sibling/main.py": "import missing_sibling\n"})
        self.assertTrue(any("missing_sibling" in p for p in out), out)

    def test_requirements_must_list_the_declared_package(self):
        out = self._problems(overrides={"pandas_excel/requirements.txt": "openpyxl\n"})
        self.assertTrue(any("does not list pandas" in p for p in out), out)

    def test_readme_must_name_every_app(self):
        out = self._problems(overrides={"README.txt": "stdlib_single pandas_excel gui_exits\n"})
        self.assertTrue(any("multifile_sibling" in p for p in out), out)

    def test_pycache_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_tree(Path(tmp))
            (root / "stdlib_single" / "__pycache__").mkdir()
            self.assertEqual(check_tree(root), [])


class ScenariosReadTheFolder(unittest.TestCase):
    """The places that read the fixtures, so an app cannot be moved back inline without this failing."""

    def _text(self, rel):
        return (ROOT / rel).read_text(encoding="utf-8")

    def test_example_script_runs_three_apps_from_the_folder(self):
        text = self._text("tests/selfapps_example_apps.ps1")
        self.assertIn("fixtures", text)
        for name in ("stdlib_single", "multifile_sibling", "gui_exits"):
            self.assertIn(name, text)
        for rid in ("self.examples.stdlib_single", "self.examples.multifile_sibling", "self.examples.gui_exits"):
            self.assertRegex(text, r"id\s*=\s*'%s'" % re.escape(rid))

    def test_example_script_sets_its_own_exit_code(self):
        # The pwsh step appends exit $LASTEXITCODE, so a script that runs native commands must end with its own exit.
        text = self._text("tests/selfapps_example_apps.ps1").rstrip()
        self.assertTrue(text.endswith("exit 0"), text[-80:])
        self.assertIn("exit 1", text)

    def test_pandas_excel_script_reads_the_fixture(self):
        text = self._text("tests/selfapps_pandas_excel.ps1")
        self.assertIn("fixtures", text)
        self.assertIn("pandas_excel", text)
        self.assertNotIn('df.to_excel("out.xlsx")', text, "the pandas app must come from the fixture folder")

    def test_workflow_runs_the_script_on_the_real_lane_and_uploads_its_logs(self):
        text = self._text(".github/workflows/batch-check.yml")
        idx = text.index("tests\\selfapps_example_apps.ps1")
        step = text[text.rfind("- name:", 0, idx):idx]
        self.assertIn("matrix.mode == 'real'", step)
        self.assertNotIn("continue-on-error", step, "a new test gates from its first run")
        self.assertIn("tests/~selftest_example_", text)


if __name__ == "__main__":
    unittest.main()
