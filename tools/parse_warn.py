"""parse_warn v5 (2026-10-11)
Prints one package name per line for warnfix, from the PyInstaller warn file (5.x "W: no module
named 'foo'", 6.x "missing module named foo - imported by bar (top-level|delayed|conditional)").
Never printed (README REQ-005.9, rationale in docs/agent-closed-backlog.md): names starting
with _, SKIP, stdlib, pyimod*/pyi_*, X.attr when X is installed, and a name only the stdlib or
installed packages import (6.x lines with no importer of the user's own).
"""
__version__ = "parse_warn v5 (2026-10-11)"
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
    # rationale per group: docs/agent-closed-backlog.md, Dependency Strategy Rationale
    "pkg_resources distutils setuptools importlib importlib.metadata importlib.resources "
    "importlib.abc collections "
    "grp pwd posix resource fcntl readline termios tty pty crypt spwd nis syslog ossaudiodev "
    "cStringIO StringIO "
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


def _lib(imp):
    # True when the importer is the stdlib or an installed package, never the user's own code.
    where = imp
    if "/" not in imp and "\\" not in imp:
        top = imp.split(".")[0]
        if top in (getattr(sys, "stdlib_module_names", None) or ()):
            return True
        s = _spec(top)
        where = "%s %s" % (getattr(s, "origin", ""), getattr(s, "submodule_search_locations", ""))
    return "-packages" in where.lower()


def _wanted(line):
    kinds = r"top-level|delayed|conditional"
    ents = re.findall(r"(.+?) \(([^)]*)\)(?:, |$)", line.partition(" - imported by ")[2])
    if not ents:
        return bool(re.search(kinds, line))
    return any(re.search(kinds, k) and not _lib(i) for i, k in ents)


def parse_warn_file(warn_path):
    """Return the install names (deduplicated, in order) a PyInstaller warn file asks for."""
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
                # 6.x: required only when the user's own code imports it at top level, in a
                # function or under an if; (optional) alone is a try-except guard, skipped.
                m = re.match(r"missing module named (\S+)", line)
                if not m or not _wanted(line):
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
