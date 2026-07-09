# REQ-009 Tier 5, Python stage: runs under the "always latest" interpreter ~embed_extract.ps1
# (PowerShell stage) already downloaded/verified/extracted. This is the ONLY place per-request
# version logic lives -- deliberately Python, not PowerShell, reusing this codebase's proven
# version-detection pattern instead of re-deriving it in PowerShell. Full rationale:
# docs/agent-interconnect.md "Standalone Python-download tier". "3.14" entry below MUST match
# HP_EMBED_LATEST_PATCH/HP_EMBED_LATEST_SHA256 in run_setup.bat -- a PayloadSync-style unit test
# asserts this. Last refreshed: 2026-07-09.
import hashlib
import os
import re
import shutil
import sys
import urllib.request
import zipfile

# minor -> (patch, sha256)
EMBED_PYTHON_TABLE = {
    "3.10": ("3.10.11", "608619f8619075629c9c69f361352a0da6ed7e62f83a0e19c63e0ea32eb7629d"),
    "3.11": ("3.11.9", "009d6bf7e3b2ddca3d784fa09f90fe54336d5b60f0e0f305c37f400bf83cfd3b"),
    "3.12": ("3.12.10", "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3"),
    "3.13": ("3.13.14", "90b4e5b9898b72d744650524bff92377c367f44bd5fbd09e3148656c080ad907"),
    "3.14": ("3.14.6", "df901e84a896ff1ee720ad03377e0c8d8c2244fda79808aeeaff6316df1cb75c"),
}
LATEST_MINOR = "3.14"
FLOOR_MINOR = "3.10"

SPEC_MINOR_RE = re.compile(r"([0-9]+\.[0-9]+)")


def _minor_key(minor):
    try:
        major, sub = minor.split(".")
        return (int(major), int(sub))
    except (ValueError, AttributeError):
        return (0, 0)


def resolve_requested_minor(pyspec):
    # Extracts "X.Y" from a PYSPEC string (e.g. "python>=3.10,<4.0"); None if empty/unparseable.
    if not pyspec:
        return None
    match = SPEC_MINOR_RE.search(pyspec)
    return match.group(1) if match else None


def resolve_table_entry(requested_minor):
    # Returns (minor, patch, sha256, fell_back); mirrors the PowerShell stage's own rules.
    if requested_minor in EMBED_PYTHON_TABLE:
        patch, sha256 = EMBED_PYTHON_TABLE[requested_minor]
        return requested_minor, patch, sha256, False
    minor = FLOOR_MINOR if _minor_key(requested_minor) < _minor_key(FLOOR_MINOR) else LATEST_MINOR
    patch, sha256 = EMBED_PYTHON_TABLE[minor]
    return minor, patch, sha256, True


def download_and_verify(url, expected_sha256, dest_zip):
    urllib.request.urlretrieve(url, dest_zip)
    digest = hashlib.sha256()
    with open(dest_zip, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    actual = digest.hexdigest().lower()
    if actual != expected_sha256.lower():
        os.remove(dest_zip)
        raise ValueError("checksum mismatch: expected {}, got {}".format(expected_sha256, actual))


def extract_and_patch(zip_path, dest_dir):
    if os.path.isdir(dest_dir):
        shutil.rmtree(dest_dir)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(dest_dir)
    pth_files = [f for f in os.listdir(dest_dir) if re.match(r"^python\d+\._pth$", f)]
    if not pth_files:
        raise FileNotFoundError("no python*._pth file found after extraction")
    pth_path = os.path.join(dest_dir, pth_files[0])
    with open(pth_path, "r", encoding="ascii") as fh:
        content = fh.read()
    content = re.sub(r"(?m)^#import site$", "import site", content)
    with open(pth_path, "w", encoding="ascii", newline="") as fh:
        fh.write(content)
    py_exe = os.path.join(dest_dir, "python.exe")
    if not os.path.isfile(py_exe):
        raise FileNotFoundError("python.exe missing after extraction")
    return py_exe


def main():
    # dest_dir is where THIS running interpreter lives; Windows won't let a process replace its
    # own files, so a swap extracts into a sibling _swap dir and batch moves it into place only
    # after this process exits (locks released). See docs/agent-interconnect.md.
    dest_dir = sys.argv[1] if len(sys.argv) > 1 else ""
    swap_dir = dest_dir.rstrip("\\/") + "_swap"
    pyspec = os.environ.get("PYSPEC", "")
    requested_minor = resolve_requested_minor(pyspec)

    if requested_minor is None or requested_minor == LATEST_MINOR:
        sys.stdout.write("unchanged|{}\n".format(LATEST_MINOR))
        return 0

    minor, patch, sha256, fell_back = resolve_table_entry(requested_minor)
    if minor == LATEST_MINOR:
        sys.stdout.write("unchanged|{}\n".format(minor))
        return 0

    url = "https://www.python.org/ftp/python/{p}/python-{p}-embed-amd64.zip".format(p=patch)
    zip_path = os.path.join(os.environ.get("TEMP", "."), "python-{}-embed-amd64.zip".format(patch))
    try:
        download_and_verify(url, sha256, zip_path)
        extract_and_patch(zip_path, swap_dir)
    except Exception as exc:
        sys.stderr.write("embed version swap failed: {}\n".format(exc))
        if os.path.isdir(swap_dir):
            shutil.rmtree(swap_dir, ignore_errors=True)
        return 1

    tag = "fellback" if fell_back else "swapped"
    sys.stdout.write("{}|{}|{}\n".format(tag, minor, swap_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
