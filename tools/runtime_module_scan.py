"""runtime_module_scan (HP_RUNTIME_MODULE_SCAN) -- Item 65 slice 1.

Reads the stderr a run of the user's program left behind and prints, one per line, every module
it says is missing AND that this interpreter does not have. A program can exit 0 and still print
"ModuleNotFoundError: No module named 'x'" (a GUI callback's exception is caught and printed by the
toolkit), so the exit code alone never shows it.

Usage: runtime_module_scan.py <stderr-file>. Exit 0 always, even for an unreadable file (nothing is
reported then); 3 only for an unexpected internal error. Python 3.9 grammar only (see the embedded
helper baseline in docs/agent-lessons-learned.md); sys.stdlib_module_names is a feature guard.

Every name printed matches [A-Za-z_][A-Za-z0-9_]*, because the batch echoes it unquoted.

Slice 2 (the consented install, README REQ-018) adds two more modes, used only after a yes:
  --packages <modules-file> <provider>   prints "module package" per line (package from the table
                                         below, else the module name itself; conda gets cv2 as opencv)
  --append <requirements-file> <ok-file> adds the second column of <ok-file> to the requirements file
                                         unless that package is already declared there
Package names match [A-Za-z0-9][A-Za-z0-9._-]*, so they are as safe to echo as module names.
"""
import importlib.util
import re
import sys

_PAT = re.compile(r"(?:ModuleNotFoundError|ImportError): No module named ['\"]([^'\"\r\n]+)['\"]")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_CAP = 10
_PKG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
# derived requirement: import name -> PyPI name, for the names that differ. Every entry but cv2 must
# equal tools/parse_warn.py's TRANSLATIONS (tests/test_runtime_module_scan.py::TableMatchesWarnfix),
# so warnfix and this offer cannot disagree about what a name means.
_PIP = {
    "cv2": "opencv-python", "PIL": "pillow", "sklearn": "scikit-learn", "bs4": "beautifulsoup4",
    "serial": "pyserial", "yaml": "pyyaml", "git": "gitpython", "wx": "wxpython",
    "dateutil": "python-dateutil", "dotenv": "python-dotenv", "Crypto": "pycryptodome",
    "OpenSSL": "pyopenssl", "jwt": "pyjwt", "usb": "pyusb", "attr": "attrs", "fitz": "pymupdf",
    "docx": "python-docx", "pptx": "python-pptx", "skimage": "scikit-image", "zmq": "pyzmq",
    "win32api": "pywin32", "win32con": "pywin32", "win32com": "pywin32", "win32gui": "pywin32",
    "pythoncom": "pywin32", "pywintypes": "pywin32",
}
_CONDA = {"cv2": "opencv"}  # conda-forge calls it opencv; opencv-python is a PyPI-only name


def _have(top):
    # Local modules count as present: this file sits in the app folder, so sys.path[0] finds them.
    try:
        return importlib.util.find_spec(top) is not None
    except (ImportError, ValueError, AttributeError):
        return True  # cannot tell, so say nothing


def missing(text):
    out = []
    stdlib = getattr(sys, "stdlib_module_names", ())
    for m in _PAT.finditer(text):
        top = m.group(1).split(".")[0]
        if top in out or top in stdlib or not _NAME.match(top) or _have(top):
            continue
        out.append(top)
        if len(out) == _CAP:
            break
    return out


def package_for(module, provider):
    if provider == "conda" and module in _CONDA:
        return _CONDA[module]
    return _PIP.get(module, module)


def _read_lines(path):
    with open(path, "rb") as f:
        return [x.strip() for x in f.read().decode("utf-8", "replace").splitlines() if x.strip()]


def packages(path, provider):
    out = []
    for mod in _read_lines(path):
        if _NAME.match(mod) and _PKG.match(package_for(mod, provider)):
            out.append("%s %s" % (mod, package_for(mod, provider)))
    return out


def _dist_name(line):
    # "Foo_Bar[extra]>=1 ; marker" -> "foo-bar": enough to tell whether a package is already declared
    m = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", line)
    return re.sub(r"[-_.]+", "-", m.group(1)).lower() if m else ""


def append_requirements(req_path, ok_path):
    have = set()
    raw = b""
    try:
        with open(req_path, "rb") as f:
            raw = f.read()
    except OSError:
        pass
    for line in raw.decode("utf-8", "replace").splitlines():
        have.add(_dist_name(line))
    add = []
    for line in _read_lines(ok_path):
        parts = line.split()
        pkg = parts[1] if len(parts) > 1 else ""
        if _PKG.match(pkg) and _dist_name(pkg) not in have:
            have.add(_dist_name(pkg))
            add.append(pkg)
    if add:
        nl = b"\r\n" if b"\r\n" in raw else b"\n"
        data = raw if (not raw or raw.endswith(b"\n")) else raw + nl
        with open(req_path, "wb") as f:
            f.write(data + b"".join(a.encode("ascii") + nl for a in add))
    return add


def main(argv):
    try:
        if len(argv) > 3 and argv[1] == "--packages":
            for line in packages(argv[2], argv[3]):
                print(line)
            return 0
        if len(argv) > 3 and argv[1] == "--append":
            for pkg in append_requirements(argv[2], argv[3]):
                print(pkg)
            return 0
    except Exception as exc:  # derived requirement: never break the bootstrap over a diagnostic
        print("runtime_module_scan: %s" % type(exc).__name__, file=sys.stderr)
        return 3
    try:
        with open(argv[1], "rb") as f:
            text = f.read().decode("utf-8", "replace")
    except (IndexError, OSError):
        return 0
    try:
        for name in missing(text):
            print(name)
    except Exception as exc:  # derived requirement: never break the bootstrap over a diagnostic
        print("runtime_module_scan: %s" % type(exc).__name__, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
