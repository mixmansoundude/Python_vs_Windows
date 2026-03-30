"""parse_warn v2 (2026-03-29)
Reads PyInstaller warn file, extracts missing module names, applies translations.
Usage: python ~parse_warn.py <envname>
Prints one conda package name per line to stdout.
Skips internal modules (starting with _) and known-safe/unix-only names.
Supports PyInstaller 5.x format (W: no module named 'foo') and
PyInstaller 6.x format (missing module named foo - imported by ... (top-level)).
"""
__version__ = "parse_warn v2 (2026-03-29)"
__all__ = ["main", "parse_warn_file", "TRANSLATIONS", "SKIP"]

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
    "win32api": "pywin32",
    "win32con": "pywin32",
    "fitz": "pymupdf",
    "docx": "python-docx",
}

SKIP = frozenset([
    "pkg_resources",
    "distutils",
    "setuptools",
    "importlib",
    "importlib.metadata",
    "importlib.resources",
    "importlib.abc",
    # Unix-only platform modules absent on Windows; these appear as optional/delayed
    # stdlib imports in the warn file and are safe to ignore.
    "grp",
    "pwd",
    "posix",
    "resource",
    "fcntl",
    "readline",
    "termios",
    "tty",
    "pty",
    "crypt",
    "spwd",
    "nis",
    "syslog",
    "ossaudiodev",
])


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
                mod = m.group(1).split(".")[0]
            else:
                # PyInstaller 6.x format:
                # missing module named foo - imported by bar (top-level)
                # Only process top-level imports; conditional/optional/delayed
                # are usually unix-only stdlib shims safe to exclude on Windows.
                m = re.match(r"missing module named (\S+)", line)
                if not m:
                    continue
                if "top-level" not in line:
                    continue
                mod = m.group(1).split(".")[0]
            if mod.startswith("_"):
                continue
            if mod in SKIP:
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
