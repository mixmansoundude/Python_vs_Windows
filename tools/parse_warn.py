"""parse_warn v4 (2026-10-10)
Reads the PyInstaller warn file; prints one package name per line for warnfix to install.
Usage: python ~parse_warn.py <envname>
Reads 5.x "W: no module named 'foo'" and 6.x "missing module named foo - imported by bar
(top-level|delayed|conditional)" lines, never "excluded module named" ones. Never printed
(README REQ-005.9): names starting with _, SKIP, the standard library, PyInstaller's own
pyimod*/pyi_* modules, and X.attr when X is already installed. SKIP group rationale:
docs/agent-closed-backlog.md, Dependency Strategy Rationale.
"""
__version__ = "parse_warn v4 (2026-10-10)"
__all__ = ["main", "parse_warn_file", "TRANSLATIONS", "SKIP"]

import importlib.util
import os
import re
import sys

TRANSLATIONS = {
    "cv2": "opencv",
    "PIL": "pillow",
    "Image": "pillow",
    "sklearn": "scikit-learn",
    "bs4": "beautifulsoup4",
    "serial": "pyserial",
    "yaml": "pyyaml",
    "git": "gitpython",
    "wx": "wxpython",
    "dateutil": "python-dateutil",
    "dotenv": "python-dotenv",
    "Crypto": "pycryptodome",
    "OpenSSL": "pyopenssl",
    "jwt": "pyjwt",
    "usb": "pyusb",
    "attr": "attrs",
    "fitz": "pymupdf",
    "docx": "python-docx",
    "pptx": "python-pptx",
    "pydantic_core": "pydantic-core",
    "skimage": "scikit-image",
    "Cryptodome": "pycryptodome",
    "zmq": "pyzmq",
}
# pywin32 ships dozens of top-level modules; every one of them is the one package pywin32.
TRANSLATIONS.update(dict.fromkeys((
    "win32api win32con win32com win32gui win32file win32process win32event pywintypes pythoncom "
    "winerror win32pdh win32pdhutil win32pipe win32service win32serviceutil servicemanager win32clipboard "
    "win32print win32security win32net win32netcon win32ui win32uiole win32timezone win32crypt "
    "win32evtlog win32evtlogutil win32job win32profile win32ts win32wnet win32console win32cred "
    "win32inet win32gui_struct winxpgui ntsecuritycon").split(), "pywin32"))

SKIP = frozenset((
    # stdlib/setuptools machinery and packages whose submodules surface as "missing"
    "pkg_resources distutils setuptools importlib importlib.metadata importlib.resources "
    "importlib.abc collections "
    # Unix-only platform modules, absent on Windows
    "grp pwd posix resource fcntl readline termios tty pty crypt spwd nis syslog ossaudiodev "
    # Python 2 shims real packages still reference (xlrd does conditional cStringIO imports)
    "cStringIO StringIO "
    # Item 64: stdlib removed in Python 3, other interpreters and operating systems (Jython,
    # OpenVMS, macOS, classic Mac), and the Python 2 standard library: on no index for Windows
    "imp uu test java vms_lib org ce os2 riscos riscospath Foundation AppKit objc Cocoa Quartz "
    "CoreFoundation PyObjCTools MacOS EasyDialogs Carbon tkFileDialog tkMessageBox tkSimpleDialog "
    "tkColorChooser tkCommonDialog tkFont Tkinter Tkconstants Tix ScrolledText FileDialog gdbm "
    "dumbdbm dbhash anydbm whichdb cPickle ConfigParser Queue SocketServer urllib2 urlparse "
    "httplib HTMLParser htmlentitydefs Cookie cookielib xmlrpclib SimpleXMLRPCServer UserDict "
    "UserList UserString copy_reg commands thread md5 sha sets exceptions repr").split())


def _spec(name):
    # find_spec on a top-level name never imports it; any failure means "not found".
    try:
        return importlib.util.find_spec(name)
    except Exception:
        return None


def _is_stdlib(name):
    names = getattr(sys, "stdlib_module_names", None)  # Python 3.10+
    if names is not None:
        return name in names
    spec = _spec(name)  # older Python: found outside site/dist-packages means stdlib
    where = (getattr(spec, "origin", None) or "").replace("\\", "/").lower()
    return spec is not None and "-packages" not in where


def parse_warn_file(warn_path):
    """Parse a PyInstaller warn file; return list of conda package names (deduplicated, ordered).

    Returns an empty list if warn_path does not exist.
    Each entry in TRANSLATIONS maps an import-name to a conda package name.
    Unknown import names pass through unchanged.
    """
    if not os.path.exists(warn_path):
        return []
    seen = set()
    result = []
    with open(warn_path, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            # PyInstaller 5.x format: W: no module named 'foo'
            m = re.match(r"W: no module named '([^']+)'", line)
            if m:
                raw = m.group(1)
            else:
                # 6.x: top-level, delayed and conditional imports are required; an entry that is
                # only (optional) is a try-except guard, resilient by design, so it is skipped.
                m = re.match(r"missing module named (\S+)", line)
                if not m:
                    continue
                if not re.search(r'\([^)]*(?:top-level|delayed|conditional)[^)]*\)', line):
                    continue
                raw = m.group(1).strip("'\"")
            mod = raw.split(".")[0]
            if not mod or mod.startswith(("_", "pyimod", "pyi_")):
                continue
            if mod in SKIP or _is_stdlib(mod):
                continue
            if "." in raw and _spec(mod) is not None:
                continue
            pkg = TRANSLATIONS.get(mod, mod)
            if pkg not in seen:
                seen.add(pkg)
                result.append(pkg)
    return result


def main():
    if len(sys.argv) < 2:
        sys.exit(1)
    envname = sys.argv[1]
    warn_path = os.path.join("build", envname, "warn-" + envname + ".txt")
    for pkg in parse_warn_file(warn_path):
        sys.stdout.write(pkg + "\n")


if __name__ == "__main__":
    main()
