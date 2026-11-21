"""Item 112: README REQ-013 (network resilience) shown with real downloads, and the harness that does it.

`tests/selfapps_net_resilience.ps1` cuts five blocks out of `run_setup.bat` (the get-pip.py download, the Miniconda
download, the embedded Python download and extraction, the replacement of the embedded Python folder, the reachability
check), wraps each in a small driver and runs it with cmd.exe against a local HTTP server and a stub ping.exe/curl.exe.
Item 116 added three more cuts (the uv acquisition, the Miniconda folder decision and `:select_conda_bat`) for the rows that
show an installed uv or Miniconda used as it is in offline mode (REQ-013.12), and one more run of the get-pip.py block with PATH
cut to the System32 folders (REQ-003.1).
Item 127 added the uv archive unpack (`:uv_acquire_done` cut) for the two rows `self.netres.uv.acquire` and `.unpackfail`: the unpack is
raw .NET with the reason of a failure written to the setup log, because `Expand-Archive` failed in the real chain on Windows image
20261116.315.1 and left no uv.exe.
Item 128 added `self.netres.uv.partial` (REQ-009.24): the unpack's exit code is read, a failed unpack deletes the three uv files it
left, and a bare `uv.exe` that exists is no longer the verdict, because `uv.exe` is the first archive entry and a held `uvx.exe`
stops the unpack after it.
What it can prove depends on those blocks staying what the script assumes. This file pins that, so a change that moves a
label, adds a variable the driver does not set, drops `--retry 3` or reorders the attempts fails here with a message
that names the script to update, and not after a two and a half hour run.

It reads text only (no Windows needed). The behavior itself is the script's `self.netres.*` rows. Synthetic cases prove
each rule can fail.
"""
import re
import unittest
from pathlib import Path

from tools import check_ndjson_registry

REPO = Path(__file__).resolve().parent.parent
BAT = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_net_resilience.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"
README = REPO / "README.md"

# id -> req tag, literal in the script at two places (Write-AllRows and the real row).
ROWS = {
    "self.netres.getpip.retry": "REQ-013.14",
    "self.netres.getpip.powershell": "REQ-013.15",
    "self.netres.getpip.fallback": "REQ-013.13, REQ-013.14",
    "self.netres.getpip.offline": "REQ-013.11",
    "self.netres.miniconda.retry": "REQ-013.14",
    "self.netres.miniconda.powershell": "REQ-013.15",
    "self.netres.miniconda.checkorder": "REQ-013.1, REQ-013.13",
    "self.netres.miniconda.offline": "REQ-013.10",
    "self.netres.embed.retry": "REQ-013.14",
    "self.netres.embed.powershell": "REQ-013.15",
    "self.netres.embed.checksum": "REQ-013.17",
    "self.netres.embed.extractfail": "REQ-013.17",
    "self.netres.check.repeat": "REQ-013.3",
    "self.netres.swap.retry": "REQ-013.18",
    "self.netres.offline.uv": "REQ-013.12",
    "self.netres.offline.conda": "REQ-013.12",
    "self.netres.shipped.tools": "REQ-003.1",
    # Item 127: the uv archive that downloaded in full is unpacked, and a failed unpack names its reason.
    "self.netres.uv.acquire": "REQ-009.22",
    "self.netres.uv.unpackfail": "REQ-009.23",
    # Item 128: an unpack that fails after uv.exe was written leaves no uv files behind and the run does not use them.
    "self.netres.uv.partial": "REQ-009.24",
    # Item 128 follow-up: a uv.exe that a failed unpack could not delete is not used, the next run unpacks again.
    "self.netres.uv.survivor": "REQ-009.25",
}
STEP_NAME = "Self-test: network resilience of the downloads (real only)"

# name -> (first line, line it stops before), both compared with the trimmed line, each present exactly once.
BLOCKS = {
    "getpip": (":download_get_pip", ":handle_conda_failure"),
    "miniconda": (":download_miniconda_exe", ":download_get_pip"),
    "embed": ('set "HP_EMBED_DL_ATTEMPT=0"', 'call :log "[INFO] embed fallback: %HP_EMBED_LATEST_PATCH% extracted and verified."'),
    "swap": ('set "HP_EMBED_SWAP_ATTEMPT=0"', ":embed_pyver_check_tagcheck"),
    "check": (":check_net_after_dl_fail", ":system_python_consent_gate"),
    # Item 116: the installed uv and Miniconda decisions that REQ-013.12 is about.
    "uv": (":pvw_uv_exe_skip", ":uv_acquire_done"),
    "mcdir": ('set "MC=%PUBLIC%\\Documents\\Miniconda3"', ":after_conda_bat_validation"),
    "select": (":select_conda_bat", ":download_miniconda_exe"),
}
# The uv download is inline in the main flow (not a subroutine) and uses curl only; its half of REQ-013.1 and REQ-013.9 is pinned
# here as text, because the script's Miniconda block shows the same order with real requests and uv's URL cannot be redirected.
UV_BLOCK = (":uv_acquire_download", 'for %%S in ("%HP_UV_ZIP%") do (')
# Item 127: from that same `for` line to the end of the acquisition, the unpack and the verdict on ~uv_bin\uv.exe.
UV_UNPACK = ('for %%S in ("%HP_UV_ZIP%") do (', ":uv_acquire_done")

# Labels a block may reach outside itself. The script's driver defines each one.
EXTERNAL_LABELS = {
    "getpip": {":log"},
    "miniconda": {":log", ":check_net_after_dl_fail"},
    "embed": {":log", ":emit_from_base64"},
    "swap": {":log", ":embed_pyver_check_tagcheck"},
    "check": {":log"},
    # :uv_acquire_done is the label the driver puts right after the block (the block's own end line is not part of it).
    "uv": {":log", ":check_net_after_dl_fail", ":uv_acquire_done"},
    "mcdir": {":log", ":select_conda_bat", ":download_miniconda_exe", ":try_conda_install"},
    "select": set(),
}
# Variables a block reads that the driver sets (or the system always has).
DRIVER_VARIABLES = {
    "getpip": {"LOG", "TEMP", "HP_GETPIP_URL", "HP_GETPIP_FALLBACK_URL"},
    "miniconda": {"LOG", "TEMP", "HP_MINICONDA_URL", "HP_MINICONDA_FALLBACK_URL"},
    "embed": {"LOG", "HP_EMBED_URL", "HP_EMBED_ZIP", "HP_EMBED_DIR", "HP_EMBED_LATEST_PATCH", "HP_EMBED_LATEST_SHA256"},
    "swap": {"HP_EMBED_DIR", "HP_EMBED_SWAP_DIR", "HP_EMBED_SWAP_MINOR"},
    "check": set(),
    "uv": {"LOG", "TEMP", "HP_OFFLINE_MODE", "HP_SCRIPT_ROOT", "HP_UV_URL", "HP_UV_FALLBACK_URL", "HP_UV_MIN_BYTES"},
    "mcdir": {"LOG", "TEMP", "PUBLIC", "HP_OFFLINE_MODE", "HP_MINICONDA_URL", "HP_MINICONDA_FALLBACK_URL", "PATH"},
    # CONDA_MAIN and CONDA_ALT are set by the Miniconda folder block, which runs first in the same driver.
    "select": {"CONDA_MAIN", "CONDA_ALT"},
}
# Variables a block reads that the script leaves undefined on purpose: a test hook or the product's own offline flag.
ABSENT_BY_DESIGN = {
    "getpip": {"HP_TEST_FORCE_VENV_CREATE_FAIL", "HP_TEST_FORCE_EMBED_REAL", "HP_OFFLINE_MODE"},
    "miniconda": {"HP_TEST_CONDA_DL_FALLBACK", "HP_CONDA_DL_INJECTED", "HP_OFFLINE_MODE"},
    "embed": {"HP_TEST_FORCE_EMBED_DL_FAIL_ONCE"},
    "swap": set(),
    "check": {"HP_TEST_OFFLINE", "HP_TEST_CNDF_ANSWER", "HP_OFFLINE_MODE", "NOINPUT", "HP_NONINTERACTIVE"},
    "uv": {"HP_FORCE_CONDA_ONLY", "HP_TEST_FORCE_UV_FAIL", "HP_TEST_CORRUPT_UV", "HP_TEST_UV_DL_FALLBACK", "HP_UV_DL_INJECTED"},
    "mcdir": {"PVW_CONDA_EXE", "HP_UV_PROVIDING_PYTHON"},
    "select": set(),
}

# (what the script looks for in a driver log, the live `call :log` text in run_setup.bat that writes it)
LOG_TEXTS = (
    ("Offline mode: skipping get-pip.py download", "Offline mode: skipping get-pip.py download"),
    ("Offline mode: skipping Miniconda download", "Offline mode: skipping Miniconda download"),
    ("Offline mode: skipping uv download", "Offline mode: skipping uv download"),
    ("uv: cached binary found at ~uv_bin\\\\uv\\.exe", "uv: cached binary found at ~uv_bin"),
    # Item 127: the two outcomes of the unpack, as the setup log words them.
    ("uv: acquired at ~uv_bin\\\\uv\\.exe", "uv: acquired at ~uv_bin"),
    ("uv: acquisition failed; will use conda", "uv: acquisition failed; will use conda"),
    ("UV_FALLBACK reason=acquire_failed", "UV_FALLBACK reason=acquire_failed"),
    ("uv: ~uv_bin holds the files listed next", "uv: ~uv_bin holds the files listed next"),
    ("Trying fallback get-pip.py URL", "Trying fallback get-pip.py URL"),
    ("get-pip.py download succeeded from fallback URL", "get-pip.py download succeeded from fallback URL"),
    ("Trying fallback Miniconda URL", "Trying fallback Miniconda URL"),
    ("Miniconda download succeeded from fallback URL", "Miniconda download succeeded from fallback URL"),
    ("checksum verification or extraction failed; retrying download once", "checksum verification or extraction failed; retrying download once"),
    ("checksum verification or extraction failed\\.$", "checksum verification or extraction failed."),
    ("swap move failed; interpreter may be missing", "swap move failed; interpreter may be missing"),
    ("swapped to requested Python 3\\.12", "swapped to requested Python %HP_EMBED_SWAP_MINOR%"),
    ("internet reachable\\. Cascading to fallback", "internet reachable. Cascading to fallback"),
    ("reachable via HTTPS", "reachable via HTTPS"),
    ("no internet detected", "no internet detected"),
)

CURL_DL = re.compile(r'^curl --fail -L --retry 3 --retry-delay 5 --max-time 120 "%(\w+)%" -o "([^"]+)"')
PS_DL = re.compile(r"^powershell -NoProfile -ExecutionPolicy Bypass -Command .*Invoke-WebRequest -Uri '%(\w+)%' -OutFile '([^']+)'")


def _bat_lines():
    return [l.rstrip("\r") for l in BAT.read_text(encoding="utf-8", errors="replace").split("\n")]


def cut_block(lines, start, end):
    s = next((i for i, l in enumerate(lines) if l.strip() == start), None)
    if s is None:
        return None
    e = next((j for j in range(s + 1, len(lines)) if lines[j].strip() == end), None)
    if e is None:
        return None
    return lines[s:e]


def label_problems(lines):
    """Each cut line has to exist exactly once, or the script's Get-BatBlock takes the wrong one."""
    found = []
    trimmed = [l.strip() for l in lines]
    for name, (start, end) in BLOCKS.items():
        for edge in (start, end):
            n = trimmed.count(edge)
            if n != 1:
                found.append("%s: the line %r occurs %d times, the script needs exactly one" % (name, edge, n))
    return found


def block_problems(name, block):
    """What a cut-out block reaches outside itself that the driver does not provide."""
    found = []
    labels = {l.strip() for l in block if l.strip().startswith(":") and not l.strip().startswith("::")}
    assigned = set()
    for l in block:
        for m in re.finditer(r'set(?:\s+/a)?\s+"?([A-Za-z_][A-Za-z0-9_]*)[=+]', l, re.I):
            assigned.add(m.group(1))
    allowed = DRIVER_VARIABLES[name] | ABSENT_BY_DESIGN[name] | assigned | {"ERRORLEVEL"}
    for l in block:
        s = l.strip()
        if s.lower().startswith("rem "):
            continue
        for m in re.finditer(r"(?:goto|call)\s+(:[A-Za-z0-9_]+)", s, re.I):
            target = m.group(1)
            if target.lower() != ":eof" and target not in labels and target not in EXTERNAL_LABELS[name]:
                found.append("%s: reaches %s, which the driver does not define" % (name, target))
        for v in re.findall(r"%([A-Za-z_][A-Za-z0-9_]*)(?::[^%]*)?%", s):
            if v not in allowed:
                found.append("%s: uses %%%s%%, which the driver does not set and the script does not leave out on purpose" % (name, v))
    return found


def order_problems(name, block, wanted):
    """`wanted` is a list of (description, regex); each has to match some line, in this order."""
    found = []
    pos = -1
    for desc, rx in wanted:
        idx = next((i for i, l in enumerate(block) if i > pos and re.search(rx, l.strip())), None)
        if idx is None:
            found.append("%s: no line for '%s' after line %d of the block (%s)" % (name, desc, pos + 1, rx))
            break
        pos = idx
    return found


def contract_problems(lines):
    """The shapes of the five blocks the script's expected request counts and orders depend on."""
    found = []
    blocks = {}
    for name, (start, end) in BLOCKS.items():
        blocks[name] = cut_block(lines, start, end)
        if blocks[name] is None:
            found.append("%s: the block cannot be cut" % name)
    if found:
        return found
    for name, block in blocks.items():
        found += block_problems(name, block)

    # every download line: curl with --fail and three retries, then the Windows PowerShell second method on the same URL
    for name, urls in (("getpip", ("HP_GETPIP_URL", "HP_GETPIP_FALLBACK_URL")), ("miniconda", ("HP_MINICONDA_ACTIVE_URL", "HP_MINICONDA_FALLBACK_URL")), ("embed", ("HP_EMBED_URL",))):
        curls = [(i, CURL_DL.match(l.strip())) for i, l in enumerate(blocks[name])]
        curls = [(i, m) for i, m in curls if m]
        pss = [(i, PS_DL.match(l.strip())) for i, l in enumerate(blocks[name])]
        pss = [(i, m) for i, m in pss if m]
        if [m.group(1) for _i, m in curls] != list(urls):
            found.append("%s: the curl download lines name %r, the script plans for %r" % (name, [m.group(1) for _i, m in curls], list(urls)))
        if [m.group(1) for _i, m in pss] != list(urls):
            found.append("%s: the PowerShell download lines name %r, the script plans for %r" % (name, [m.group(1) for _i, m in pss], list(urls)))
        for k in range(min(len(curls), len(pss))):
            if not curls[k][0] < pss[k][0]:
                found.append("%s: the PowerShell method of URL %d runs before the curl one" % (name, k + 1))
            if curls[k][1].group(2) != pss[k][1].group(2).replace("'", '"'):
                found.append("%s: curl and PowerShell write URL %d to different files" % (name, k + 1))

    found += order_problems("miniconda", blocks["miniconda"], [
        ("curl of the active URL", r"^curl --fail -L --retry 3 .*%HP_MINICONDA_ACTIVE_URL%"),
        ("PowerShell of the active URL", r"Invoke-WebRequest -Uri '%HP_MINICONDA_ACTIVE_URL%'"),
        ("the connectivity check", r"^if not \"%HP_TEST_CONDA_DL_FALLBACK%\"==\"1\" call :check_net_after_dl_fail$"),
        ("the offline test after the check", r"^if \"%HP_OFFLINE_MODE%\"==\"1\" goto :eof$"),
        ("the fallback log line", r"Trying fallback Miniconda URL"),
        ("curl of the fallback URL", r"^curl --fail -L --retry 3 .*%HP_MINICONDA_FALLBACK_URL%"),
        ("PowerShell of the fallback URL", r"Invoke-WebRequest -Uri '%HP_MINICONDA_FALLBACK_URL%'"),
    ])
    found += order_problems("getpip", blocks["getpip"], [
        ("the offline skip", r"Offline mode: skipping get-pip\.py download"),
        ("curl of the primary URL", r"^curl --fail -L --retry 3 .*%HP_GETPIP_URL%"),
        ("PowerShell of the primary URL", r"Invoke-WebRequest -Uri '%HP_GETPIP_URL%'"),
        ("the fallback log line", r"Trying fallback get-pip\.py URL"),
        ("curl of the fallback URL", r"^curl --fail -L --retry 3 .*%HP_GETPIP_FALLBACK_URL%"),
        ("PowerShell of the fallback URL", r"Invoke-WebRequest -Uri '%HP_GETPIP_FALLBACK_URL%'"),
    ])
    getpip_live = "\n".join(l for l in blocks["getpip"] if not l.strip().lower().startswith("rem "))
    if "check_net_after_dl_fail" in getpip_live:
        found.append("getpip: the block now calls the connectivity check; the script's getpip rows assume it does not (REQ-023b comment in the batch)")
    found += order_problems("embed", blocks["embed"], [
        ("the attempt counter", r"^set /a HP_EMBED_DL_ATTEMPT\+=1$"),
        ("curl of the zip", r"^curl --fail -L --retry 3 .*%HP_EMBED_URL%"),
        ("PowerShell of the zip", r"Invoke-WebRequest -Uri '%HP_EMBED_URL%'"),
        ("the cap after a failed download", r"^if %HP_EMBED_DL_ATTEMPT% LSS 2 \($"),
        ("the extraction", r"-File \"~embed_extract\.ps1\""),
        ("the cap after a failed extraction", r"^if %HP_EMBED_DL_ATTEMPT% LSS 2 \($"),
        ("the retry line", r"checksum verification or extraction failed; retrying download once"),
        ("the final line", r"checksum verification or extraction failed\.\""),
    ])
    found += order_problems("swap", blocks["swap"], [
        ("the attempt counter", r"^set /a HP_EMBED_SWAP_ATTEMPT\+=1$"),
        ("the folder removal", r"^rd /s /q \"%HP_EMBED_DIR%\""),
        ("the removal gate", r"^if exist \"%HP_EMBED_DIR%\" goto :embed_swap_rd_failed$"),
        ("the move", r"^move /y \"%HP_EMBED_SWAP_DIR%\" \"%HP_EMBED_DIR%\""),
        ("the success line", r"swapped to requested Python %HP_EMBED_SWAP_MINOR%"),
        ("the cap of three attempts", r"^if %HP_EMBED_SWAP_ATTEMPT% LSS 3 \($"),
        ("the pause", r"^ping -n 2 127\.0\.0\.1"),
        ("the failure line", r"swap move failed; interpreter may be missing"),
    ])
    # REQ-013.12: the installed binary is taken before the offline test, and Miniconda is installed only when conda.bat is missing.
    found += order_problems("uv", blocks["uv"], [
        ("the health check of the installed uv", r"^\"%HP_UV_BIN%\\uv\.exe\" --version"),
        ("the installed uv is the one used", r"^set \"HP_UV_EXE=%HP_UV_BIN%\\uv\.exe\"$"),
        ("the cached binary line", r"uv: cached binary found at ~uv_bin"),
        ("the download label", r"^:uv_acquire_download$"),
        ("the offline skip", r"Offline mode: skipping uv download"),
        ("curl of the active URL", r"^curl --fail -L --retry 3 --retry-delay 5 --max-time 120 \"%HP_UV_ACTIVE_URL%\""),
    ])
    found += order_problems("mcdir", blocks["mcdir"], [
        ("the Miniconda folder", r"^set \"MC=%PUBLIC%\\Documents\\Miniconda3\"$"),
        ("the search for an installed conda.bat", r"^call :select_conda_bat$"),
        ("the install only when conda.bat is missing", r"^if not defined HP_UV_PROVIDING_PYTHON if not defined CONDA_BAT \($"),
        ("the download", r"^call :download_miniconda_exe$"),
        ("the installer", r"^call :try_conda_install$"),
    ])
    found += order_problems("select", blocks["select"], [
        ("the reset", r"^set \"CONDA_BAT=\"$"),
        ("the main conda.bat", r"^if exist \"%CONDA_MAIN%\" set \"CONDA_BAT=%CONDA_MAIN%\"$"),
        ("the alternative conda.bat", r"^if not defined CONDA_BAT if exist \"%CONDA_ALT%\" set \"CONDA_BAT=%CONDA_ALT%\"$"),
    ])
    check = blocks["check"]
    found += order_problems("check", check, [
        ("the attempt counter of the echo", r"^set /a HP_CONN_PING_ATTEMPT\+=1$"),
        ("the echo", r"^ping -n 1 8\.8\.8\.8"),
        ("the cap of the echo", r"^if %HP_CONN_PING_ATTEMPT% LSS 2 goto :cndf_ping_retry$"),
        ("the attempt counter of the request", r"^set /a HP_CONN_CURL_ATTEMPT\+=1$"),
        ("the request", r"^curl -s --connect-timeout 5 --max-time 8 -o nul \"https://conda\.anaconda\.org\""),
        ("the cap of the request", r"^if %HP_CONN_CURL_ATTEMPT% LSS 2 goto :cndf_curl_retry$"),
        ("the no internet line", r"no internet detected"),
    ])
    return found


def uv_problems(lines):
    """uv: offline skip, curl with retries, then the connectivity check, then the secondary URL; no PowerShell second method."""
    block = cut_block(lines, *UV_BLOCK)
    if block is None:
        return ["the uv download block cannot be cut (%s ... %s)" % UV_BLOCK]
    found = []
    trimmed = [l.strip() for l in lines]
    for edge in UV_BLOCK:
        if trimmed.count(edge) != 1:
            found.append("uv: the line %r occurs %d times, this test needs exactly one" % (edge, trimmed.count(edge)))
    found += order_problems("uv", block, [
        ("the offline skip", r"Offline mode: skipping uv download"),
        ("curl of the active URL", r"^curl --fail -L --retry 3 --retry-delay 5 --max-time 120 \"%HP_UV_ACTIVE_URL%\""),
        ("the connectivity check", r"^if not \"%HP_TEST_UV_DL_FALLBACK%\"==\"1\" call :check_net_after_dl_fail$"),
        ("the fallback log line", r"Trying fallback uv URL"),
        ("curl of the fallback URL", r"^curl --fail -L --retry 3 --retry-delay 5 --max-time 120 \"%HP_UV_FALLBACK_URL%\""),
    ])
    if any("Invoke-WebRequest" in l for l in block):
        found.append("uv: the block now has a PowerShell download; README REQ-013.15 and its note say uv uses curl only, update both and this test")
    return found


def uv_unpack_problems(lines):
    """Item 127 (REQ-009.22, .23) and Item 128 (REQ-009.24): the unpack of the downloaded archive writes its reason to the setup log, a missing uv.exe is explained, and a failed unpack never leaves a uv the run uses.

    The unpack is raw .NET (`ZipFile.OpenRead` and `ExtractToFile`), never `Expand-Archive`: on Windows runner image 20261116.315.1 the
    cmdlet failed in the chain pwsh -> cmd.exe -> powershell.exe with `Cannot find an overload for "ExtractToDirectory" and the
    argument count: "3"`, a 3-argument overload that only .NET Core has, so no uv.exe resulted (29 of 29 acquisitions, Item 127).
    """
    block = cut_block(lines, UV_UNPACK[0], UV_UNPACK[1])
    if block is None:
        return ["the uv unpack block cannot be cut (%s ... %s)" % UV_UNPACK]
    found = []
    trimmed = [l.strip() for l in lines]
    for edge in UV_UNPACK:
        if trimmed.count(edge) != 1:
            found.append("uv unpack: the line %r occurs %d times, this test needs exactly one" % (edge, trimmed.count(edge)))
    unpack = [l.strip() for l in block if l.strip().startswith("powershell ")]
    if len(unpack) != 1:
        return found + ["uv unpack: expected exactly one PowerShell line in the unpack block, found %d" % len(unpack)]
    line = unpack[0]
    # The archive module's cmdlet is what failed on the new image; the unpack stays raw .NET, which the embedded Python tier already runs in the same chain.
    if "Expand-Archive" in line or "Microsoft.PowerShell.Archive" in line:
        found.append("uv unpack: the unpack line uses Expand-Archive again (it failed on Windows image 20261116.315.1, Item 127); keep the .NET ZipFile route")
    for needle in ("Add-Type -AssemblyName System.IO.Compression.FileSystem", "[System.IO.Compression.ZipFile]::OpenRead(", "[System.IO.Compression.ZipFileExtensions]::ExtractToFile("):
        if needle not in line:
            found.append("uv unpack: the unpack line no longer holds %r" % needle)
    # Entries are written under their bare file name, so a crafted entry name cannot leave ~uv_bin.
    if "$e.FullName" in line or "ExtractToDirectory" in line:
        found.append("uv unpack: the unpack line writes entries under their full name or extracts a whole folder; entries must go under their bare Name")
    if "$e.Name" not in line:
        found.append("uv unpack: the unpack line no longer places entries by their bare Name")
    # The paths reach PowerShell as environment variables, never pasted in: a folder name with an apostrophe would end a single-quoted literal.
    if "$env:HP_UV_ZIP" not in line or "$env:HP_UV_BIN" not in line:
        found.append("uv unpack: the unpack line no longer reads the archive and ~uv_bin from $env:HP_UV_ZIP and $env:HP_UV_BIN")
    # The reason of a failure reaches the setup log: the command's own output is appended to it, and the command prints the reason.
    if "uv: unpack failed: " not in line or "Exception.Message" not in line:
        found.append("uv unpack: the unpack line no longer prints why it failed (the line that README REQ-009.23 and self.netres.uv.unpackfail read)")
    if not line.endswith('>> "%LOG%" 2>&1'):
        found.append('uv unpack: the unpack line no longer appends its output to the setup log')
    # No double quote inside the -Command text (cmd's quote toggle) and no percent sign at all but the log path's: two quotes around the command, two around the log path.
    if line.count('"') != 4:
        found.append("uv unpack: the unpack line holds %d double quotes, 4 are expected (a quote inside -Command breaks cmd's parsing)" % line.count('"'))
    if line.replace("%LOG%", "").count("%"):
        found.append("uv unpack: a percent sign other than the log path's sits in the unpack line (use $env:NAME, cmd pairs percent signs across the whole line)")
    # An unreadable failure was the defect: the catch must not be a bare exit.
    if re.search(r"catch \{ exit 1 \}", line):
        found.append("uv unpack: the unpack line swallows the reason again (catch { exit 1 })")
    # Item 128: nothing may sit between the unpack line and the two exit code tests (any command, a rem line included, would be a
    # place to lose the code), the flag is cleared once before the unpack (an inherited value would decline every run), and the
    # old verdict, a bare `if exist uv.exe (`, must not come back: uv.exe is the first file the archive writes.
    tb = [l.strip() for l in block]
    k = next(i for i, l in enumerate(tb) if l.startswith("powershell "))
    if tb[k + 1:k + 3] != ['if errorlevel 1 set "HP_UV_UNPACK_BAD=1"', 'if not errorlevel 0 set "HP_UV_UNPACK_BAD=1"']:
        found.append("uv unpack: the two exit code tests are not the two lines directly after the unpack line (REQ-009.24)")
    if 'if exist "%HP_UV_BIN%\\uv.exe" (' in tb:
        found.append("uv unpack: a bare `if exist uv.exe (` decides the acquisition again; a partly unpacked uv would be used (REQ-009.24, Item 128)")
    whole = cut_block(lines, *BLOCKS["uv"])
    tw = [l.strip() for l in whole] if whole else []
    if tw.count('set "HP_UV_UNPACK_BAD="') != 1:
        found.append("uv unpack: set \"HP_UV_UNPACK_BAD=\" occurs %d times in the uv block, expected one clear before the unpack" % tw.count('set "HP_UV_UNPACK_BAD="'))
    elif tw.index('set "HP_UV_UNPACK_BAD="') > next((i for i, l in enumerate(tw) if l.startswith("powershell ")), -1):
        found.append("uv unpack: the failure flag is cleared after the unpack line instead of before it")
    if sum(1 for l in tw if l.endswith('set "HP_UV_UNPACK_BAD=1"')) != 2:
        found.append("uv unpack: the failure flag must be set by exactly the two exit code tests")
    found += order_problems("uv unpack", block, [
        ("the unpack", r"^powershell .*ZipFile\]::OpenRead"),
        # Item 128 (REQ-009.24): the exit code of the unpack decides, and a failed unpack deletes the uv files it left before uv.exe is looked for.
        ("the exit code test", r"^if errorlevel 1 set \"HP_UV_UNPACK_BAD=1\"$"),
        ("the test of a negative exit code", r"^if not errorlevel 0 set \"HP_UV_UNPACK_BAD=1\"$"),
        ("the archive is removed", r"^del \"%HP_UV_ZIP%\""),
        ("the failure branch", r"^if defined HP_UV_UNPACK_BAD \($"),
        ("the deletion of uv.exe", r"^del /f /q \"%HP_UV_BIN%\\uv\.exe\""),
        ("the deletion of uvx.exe", r"^del /f /q \"%HP_UV_BIN%\\uvx\.exe\""),
        ("the deletion of uvw.exe", r"^del /f /q \"%HP_UV_BIN%\\uvw\.exe\""),
        ("the reset of the verdict", r"^set \"HP_UV_OK=\"$"),
        ("the uv.exe test", r"^if exist \"%HP_UV_BIN%\\uv\.exe\" set \"HP_UV_OK=1\"$"),
        ("the veto of a failed unpack", r"^if defined HP_UV_UNPACK_BAD set \"HP_UV_OK=\"$"),
        ("the verdict", r"^if defined HP_UV_OK \($"),
        ("the success line", r"uv: acquired at ~uv_bin"),
        ("the failure line", r"uv: acquisition failed; will use conda"),
        ("the listing heading", r"uv: ~uv_bin holds the files listed next"),
        ("the listing", r"^dir /b \"%HP_UV_BIN%\" >> \"%LOG%\" 2>&1$"),
        ("the fallback reason", r"^set \"UV_FALLBACK_REASON=acquire_failed\"$"),
        ("the fallback line", r"UV_FALLBACK reason=acquire_failed"),
    ])
    return found


def log_problems(bat_text):
    """Each text the script looks for in a driver log is written by a live call :log line of the batch."""
    found = []
    live = [l for l in bat_text.split("\n") if re.match(r"^\s*call :log ", l)]
    for _rx, wanted in LOG_TEXTS:
        if not any(wanted in l for l in live):
            found.append("no live `call :log` line of run_setup.bat holds %r" % wanted)
    return found


def script_problems(text):
    """Literal ids and tags (the registry check and the trace tests read them as text), the stub, the server and the exits."""
    found = []
    for row, tag in ROWS.items():
        pair = re.compile(r"id\s*=\s*'%s'\s*[;\n]\s*req\s*=\s*'%s'" % (re.escape(row), re.escape(tag)))
        n = len(pair.findall(text))
        if n != 2:
            found.append("%s: the id with the tag %r occurs %d times, expected 2 (Write-AllRows and the real row)" % (row, tag, n))
    for needle in (
        "System.Net.HttpListener",
        "'curl*'",
        "'*WindowsPowerShell*'",
        "Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe",
        "[System.IO.FileShare]::Read",
        "taskkill /F /T /PID",
        "NoDefaultCurrentDirectoryInExePath",
        "'set \"NO_PROXY=127.0.0.1\"'",
        "'^(HP_|PVW_|NOINPUT$|NoDefaultCurrentDirectoryInExePath$)'",
        "'non-windows-host'",
        "-ShippedOnly $true",
        "$state.Agents[$key] = $ua",
        "[Environment]::OSVersion.Version.Build",
        "-ge 17763",
        "WindowsPowerShell/5\\.1",
    ):
        if needle not in text:
            found.append("the script no longer holds %r" % needle)
    for name, (start, end) in BLOCKS.items():
        call = "Get-BatBlock -StartLine '%s' -EndLine '%s'" % (start, end)
        if call not in text:
            found.append("%s: the script cuts a different block than this test pins (%s)" % (name, call))
    if not text.rstrip().endswith("if ($script:AnyRowFailed) { exit 1 }\nexit 0"):
        found.append("the script does not end with its own exit 1 / exit 0")
    return found


def step_problems(text):
    found = []
    marker = '- name: "%s"' % STEP_NAME
    if marker not in text:
        return ["the workflow has no step named %r" % STEP_NAME]
    i = text.index(marker)
    nxt = text.find("\n      - name:", i + 1)
    block = text[i:nxt]
    if "continue-on-error" in block:
        found.append("the step has continue-on-error, so a red row would not fail the lane")
    if "selfapps_net_resilience.ps1" not in block:
        found.append("the step does not run the script")
    if "matrix.mode == 'real'" not in block:
        found.append("the step is not on the real lane")
    for other in ("justme-test", "conda-full", "contract-uv", "uv-dl-fallback", "'uv'", "'cache'"):
        if other in block.split("run:")[0]:
            found.append("the step's condition also names %s; the script is written for one lane" % other)
    if "tests/~selftest_netres/**" not in text:
        found.append("the artifact upload does not collect tests/~selftest_netres/**")
    return found


def _lines():
    return _bat_lines()


class BatchSide(unittest.TestCase):
    def test_cut_lines_exist_exactly_once(self):
        self.assertEqual(label_problems(_lines()), [])

    def test_blocks_keep_the_shape_the_script_assumes(self):
        self.assertEqual(contract_problems(_lines()), [])

    def test_uv_download_keeps_its_order(self):
        self.assertEqual(uv_problems(_lines()), [])

    def test_uv_unpack_says_why_it_failed_and_explains_a_missing_uv(self):
        self.assertEqual(uv_unpack_problems(_lines()), [])

    def test_the_script_looks_for_text_the_batch_writes(self):
        self.assertEqual(log_problems("\n".join(_lines())), [])
        script = SCRIPT.read_text(encoding="utf-8")
        for rx, _wanted in LOG_TEXTS:
            self.assertIn("'" + rx + "'", script, "the script no longer looks for " + rx)


class ScriptSide(unittest.TestCase):
    def test_script_holds_its_rows_and_parts(self):
        self.assertEqual(script_problems(SCRIPT.read_text(encoding="utf-8")), [])

    def test_script_is_crlf_ascii(self):
        raw = SCRIPT.read_bytes()
        self.assertTrue(all(b < 128 for b in raw), "non-ASCII byte in the script")
        self.assertNotIn(b"\n", raw.replace(b"\r\n", b""), "a bare LF in a .ps1 file")

    def test_the_counts_the_rows_wait_for_follow_from_the_batch(self):
        # curl --retry 3 means one first request and three more; the script waits for four, and plans three 503 answers.
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertEqual(text.count("-Items @('503', '503', '503', '200:good')"), 3)
        self.assertEqual(len(re.findall(r"p1Curl -eq 4\)", text)), 4)
        # the check repeats each probe once: two echoes, two requests.
        self.assertIn("pingCalls -eq 2) -and ($ckPing.curlCalls -eq 0)", text)
        self.assertIn("($ckNone.pingCalls -eq 2) -and ($ckNone.curlCalls -eq 2)", text)
        # three attempts at the swap, so two pauses.
        self.assertIn("$swStuck.pauses -eq 2", text)

    def test_the_registry_lists_the_rows(self):
        ids, _many = check_ndjson_registry.parse_doc_registry(REPO / "docs" / "agent-ndjson.md")
        for row in ROWS:
            self.assertIn(row, ids)

    def test_the_readme_names_the_rows(self):
        text = README.read_text(encoding="utf-8")
        for row in ROWS:
            self.assertIn(row, text, row)

    def test_step_is_a_gating_real_lane_step(self):
        self.assertEqual(step_problems(WORKFLOW.read_text(encoding="utf-8")), [])


class SyntheticRulesCanFail(unittest.TestCase):
    def test_a_moved_label_is_reported(self):
        lines = [l for l in _lines() if l.strip() != ":handle_conda_failure"]
        self.assertTrue(label_problems(lines))
        self.assertTrue(contract_problems(lines))

    def test_a_duplicated_cut_line_is_reported(self):
        lines = _lines() + [":check_net_after_dl_fail"]
        self.assertTrue(label_problems(lines))

    def test_a_new_variable_in_a_block_is_reported(self):
        block = ["set \"HP_EMBED_SWAP_ATTEMPT=0\"", ":embed_swap_retry", "echo %HP_BRAND_NEW%"]
        self.assertTrue(block_problems("swap", block))
        self.assertEqual(block_problems("swap", ["echo %HP_EMBED_DIR%", "set /a HP_EMBED_SWAP_ATTEMPT+=1", "echo %HP_EMBED_SWAP_ATTEMPT%"]), [])

    def test_a_new_goto_target_is_reported(self):
        self.assertTrue(block_problems("swap", [":a", "goto :elsewhere"]))
        self.assertEqual(block_problems("swap", [":a", "goto :a", "call :log x"]), [])

    def test_dropping_the_retry_flag_is_reported(self):
        lines = _lines()
        mutated = [l.replace("--retry 3 --retry-delay 5", "--retry-delay 5") if "HP_EMBED_URL%" in l and l.startswith("curl ") else l for l in lines]
        self.assertNotEqual(lines, mutated)
        problems = contract_problems(mutated)
        self.assertTrue(any("embed" in p for p in problems), problems)

    def test_swapping_the_two_download_methods_is_reported(self):
        lines = _lines()
        out = []
        i = 0
        # exchange the primary curl line and the primary PowerShell line of the get-pip.py block
        c = next(k for k, l in enumerate(lines) if l.startswith("curl --fail") and "%HP_GETPIP_URL%" in l)
        p = next(k for k, l in enumerate(lines) if l.startswith("powershell") and "'%HP_GETPIP_URL%'" in l)
        out = list(lines)
        out[c], out[p] = lines[p], lines[c]
        problems = contract_problems(out)
        self.assertTrue(problems)

    def test_calling_the_check_before_the_fallback_is_required(self):
        lines = [l for l in _lines() if l.strip() != 'if not "%HP_TEST_CONDA_DL_FALLBACK%"=="1" call :check_net_after_dl_fail']
        problems = contract_problems(lines)
        self.assertTrue(any("connectivity check" in p for p in problems), problems)

    def test_a_third_swap_attempt_cap_change_is_reported(self):
        lines = [l.replace("if %HP_EMBED_SWAP_ATTEMPT% LSS 3 (", "if %HP_EMBED_SWAP_ATTEMPT% LSS 5 (") for l in _lines()]
        self.assertTrue(any("cap of three" in p for p in contract_problems(lines)))

    def test_a_dropped_probe_repeat_is_reported(self):
        lines = [l.replace("if %HP_CONN_CURL_ATTEMPT% LSS 2 goto :cndf_curl_retry", "rem removed") for l in _lines()]
        self.assertTrue(any("cap of the request" in p for p in contract_problems(lines)))

    def test_uv_without_its_check_or_with_a_powershell_method_is_reported(self):
        lines = _lines()
        no_check = [l for l in lines if l.strip() != 'if not "%HP_TEST_UV_DL_FALLBACK%"=="1" call :check_net_after_dl_fail']
        self.assertTrue(any("connectivity check" in p for p in uv_problems(no_check)))
        i = next(k for k, l in enumerate(lines) if l.strip() == 'call :log "[INFO] uv: downloading to ~uv_bin..."')
        with_ps = lines[:i] + ["powershell -NoProfile -Command \"Invoke-WebRequest -Uri 'x'\""] + lines[i:]
        self.assertTrue(any("PowerShell download" in p for p in uv_problems(with_ps)))
        self.assertTrue(uv_problems([l for l in lines if l.strip() != ":uv_acquire_download"]))

    @staticmethod
    def _unpack_index(lines):
        """The one PowerShell line of the uv unpack block, found by its anchor (the ZipFile route), so a mutation cannot edit another line."""
        hits = [k for k, l in enumerate(lines) if "ZipFile]::OpenRead($env:HP_UV_ZIP)" in l]
        assert len(hits) == 1, hits
        return hits[0]

    def test_an_unpack_that_swallows_its_reason_is_reported(self):
        # Item 127: the first version of the line ended in catch { exit 1 }, which is why the log could not say why uv.exe was missing.
        lines = _lines()
        i = self._unpack_index(lines)
        mutated = list(lines)
        mutated[i] = lines[i].replace("Write-Output ('uv: unpack failed: ' + $_.Exception.Message); exit 1", "exit 1")
        self.assertNotEqual(lines, mutated)
        problems = uv_unpack_problems(mutated)
        self.assertTrue(any("no longer prints why it failed" in p for p in problems), problems)
        self.assertTrue(any("swallows the reason" in p for p in problems), problems)

    def test_an_unpack_with_its_output_dropped_or_a_stray_quote_is_reported(self):
        lines = _lines()
        i = self._unpack_index(lines)
        dropped = list(lines)
        dropped[i] = lines[i].replace(' >> "%LOG%" 2>&1', "")
        self.assertTrue(any("appends its output" in p for p in uv_unpack_problems(dropped)), uv_unpack_problems(dropped))
        quoted = list(lines)
        quoted[i] = lines[i].replace("'uv: unpack failed: '", '"uv: unpack failed: "')
        self.assertTrue(any("double quotes" in p for p in uv_unpack_problems(quoted)), uv_unpack_problems(quoted))

    def test_the_archive_cmdlet_is_reported(self):
        # Item 127: Expand-Archive failed on image 20261116.315.1 with an ExtractToDirectory overload error; its first version of the line is the control.
        lines = _lines()
        i = self._unpack_index(lines)
        old = list(lines)
        old[i] = ("powershell -NoProfile -ExecutionPolicy Bypass -Command \"try { Expand-Archive -LiteralPath $env:HP_UV_ZIP -DestinationPath $env:HP_UV_BIN -Force -ErrorAction Stop } "
                  "catch { Write-Output ('uv: unpack failed: ' + $_.Exception.Message); exit 1 }\" >> \"%LOG%\" 2>&1")
        problems = uv_unpack_problems(old)
        self.assertTrue(any("uses Expand-Archive again" in p for p in problems), problems)
        self.assertTrue(any("no longer holds" in p for p in problems), problems)

    def test_an_unpack_that_pastes_a_path_or_places_entries_by_full_name_is_reported(self):
        lines = _lines()
        i = self._unpack_index(lines)
        pasted = list(lines)
        pasted[i] = lines[i].replace("$env:HP_UV_ZIP", "'%HP_UV_ZIP%'")
        problems = uv_unpack_problems(pasted)
        self.assertTrue(any("percent sign" in p for p in problems), problems)
        self.assertTrue(any("$env:HP_UV_ZIP" in p for p in problems), problems)
        full = list(lines)
        full[i] = lines[i].replace("$e.Name)", "$e.FullName)")
        problems = uv_unpack_problems(full)
        self.assertTrue(any("full name" in p for p in problems), problems)
        self.assertTrue(any("bare Name" in p for p in problems), problems)

    def test_an_unpack_without_the_assembly_load_is_reported(self):
        # On Windows PowerShell 5.1 [System.IO.Compression.ZipFile] needs the assembly loaded first; the type does not resolve without Add-Type.
        lines = _lines()
        i = self._unpack_index(lines)
        bare = list(lines)
        bare[i] = lines[i].replace("Add-Type -AssemblyName System.IO.Compression.FileSystem; ", "")
        self.assertNotEqual(lines, bare)
        problems = uv_unpack_problems(bare)
        self.assertTrue(any("Add-Type -AssemblyName" in p for p in problems), problems)

    @staticmethod
    def _only(lines, trimmed):
        """The index of the one line equal to `trimmed`, so a mutation cannot edit another line."""
        hits = [k for k, l in enumerate(lines) if l.strip() == trimmed]
        assert len(hits) == 1, (trimmed, hits)
        return hits[0]

    def test_a_partly_unpacked_uv_that_is_used_again_is_reported(self):
        # Item 128 (REQ-009.24): the first version decided by `if exist uv.exe (`. uv.exe is the first file the archive writes, so a
        # uvx.exe that cannot be written stops the unpack with uv.exe in place, and the run used it. Each mutation puts one piece back.
        lines = _lines()
        old_verdict = list(lines)
        old_verdict[self._only(lines, "if defined HP_UV_OK (")] = 'if exist "%HP_UV_BIN%\\uv.exe" ('
        problems = uv_unpack_problems(old_verdict)
        self.assertTrue(any("bare `if exist uv.exe (`" in p for p in problems), problems)
        self.assertTrue(any("the verdict" in p for p in problems), problems)
        no_veto = [l for l in lines if l.strip() != 'if defined HP_UV_UNPACK_BAD set "HP_UV_OK="']
        self.assertNotEqual(lines, no_veto)
        self.assertTrue(any("the veto of a failed unpack" in p for p in uv_unpack_problems(no_veto)), uv_unpack_problems(no_veto))

    def test_an_unpack_whose_exit_code_is_not_read_is_reported(self):
        lines = _lines()
        for trimmed, piece in (('if errorlevel 1 set "HP_UV_UNPACK_BAD=1"', "the exit code test"),
                               ('if not errorlevel 0 set "HP_UV_UNPACK_BAD=1"', "the test of a negative exit code")):
            mutated = list(lines)
            del mutated[self._only(lines, trimmed)]
            problems = uv_unpack_problems(mutated)
            self.assertTrue(any(piece in p for p in problems), (piece, problems))
            self.assertTrue(any("exactly the two exit code tests" in p for p in problems), (piece, problems))

    def test_a_line_between_the_unpack_and_its_exit_code_tests_is_reported(self):
        # Any command there resets the exit code the tests read; a comment is not known to be safe, and the rule is nothing at all.
        lines = _lines()
        i = self._only(lines, 'if errorlevel 1 set "HP_UV_UNPACK_BAD=1"')
        mutated = lines[:i] + ["rem a comment"] + lines[i:]
        problems = uv_unpack_problems(mutated)
        self.assertTrue(any("directly after the unpack line" in p for p in problems), problems)

    def test_a_failure_flag_that_is_not_cleared_or_files_that_are_not_deleted_are_reported(self):
        lines = _lines()
        no_clear = [l for l in lines if l.strip() != 'set "HP_UV_UNPACK_BAD="']
        self.assertNotEqual(lines, no_clear)
        self.assertTrue(any("expected one clear" in p for p in uv_unpack_problems(no_clear)), uv_unpack_problems(no_clear))
        for name in ("uv", "uvx", "uvw"):
            # the cached-binary part above the unpack also deletes uv.exe, so only the last such line (the unpack tail) is taken out
            hits = [i for i, l in enumerate(lines) if l.strip() == 'del /f /q "%HP_UV_BIN%\\' + name + '.exe" >nul 2>&1']
            self.assertTrue(hits, name)
            mutated = [l for i, l in enumerate(lines) if i != hits[-1]]
            problems = uv_unpack_problems(mutated)
            self.assertTrue(any(("the deletion of %s.exe" % name) in p for p in problems), (name, problems))

    def test_a_missing_uv_without_its_listing_is_reported(self):
        lines = [l for l in _lines() if l.strip() != 'dir /b "%HP_UV_BIN%" >> "%LOG%" 2>&1']
        self.assertTrue(any("the listing" in p for p in uv_unpack_problems(lines)), uv_unpack_problems(lines))
        no_reason = [l.replace('call :log "[WARN] UV_FALLBACK reason=acquire_failed"', 'rem gone') for l in _lines()]
        self.assertTrue(any("fallback line" in p for p in uv_unpack_problems(no_reason)), uv_unpack_problems(no_reason))

    def test_a_reworded_log_line_is_reported(self):
        text = "\n".join(_lines()).replace("swap move failed; interpreter may be missing", "swap did not work")
        self.assertTrue(log_problems(text))

    def test_an_offline_gate_before_the_installed_uv_is_reported(self):
        # REQ-013.12: moving the offline test in front of the installed binary would make an installed uv unusable offline.
        lines = _lines()
        gate = 'call :log "[INFO] REQ-013: Offline mode: skipping uv download."'
        mutated = [l.replace('call :log "[INFO] uv: cached binary found at ~uv_bin\\uv.exe"', gate) for l in lines]
        self.assertNotEqual(lines, mutated)
        self.assertTrue(any("cached binary line" in p for p in contract_problems(mutated)), contract_problems(mutated))

    def test_installing_miniconda_without_the_conda_bat_test_is_reported(self):
        lines = [l.replace("if not defined HP_UV_PROVIDING_PYTHON if not defined CONDA_BAT (", "if not defined HP_UV_PROVIDING_PYTHON (") for l in _lines()]
        self.assertTrue(any("install only when conda.bat is missing" in p for p in contract_problems(lines)), contract_problems(lines))

    def test_script_without_a_row_or_the_exit_is_reported(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(script_problems(text.replace("self.netres.swap.retry", "self.netres.swap.other")))
        self.assertTrue(script_problems(text.replace("exit 0", "")))
        self.assertTrue(script_problems(text.replace("req = 'REQ-013.18'", "req = 'REQ-013.99'")))
        self.assertTrue(script_problems(text.replace("self.netres.shipped.tools", "self.netres.shipped.other")))
        self.assertTrue(script_problems(text.replace("-ge 17763", "-ge 10240")))
        self.assertTrue(script_problems(text.replace("-ShippedOnly $true", "-ShippedOnly $false")))
        self.assertTrue(script_problems(text.replace("NO_PROXY=127.0.0.1", "NO_PROXY_UNSET=1")))

    def test_script_cutting_another_block_is_reported(self):
        text = SCRIPT.read_text(encoding="utf-8").replace("-EndLine ':system_python_consent_gate'", "-EndLine ':elsewhere'")
        self.assertTrue(script_problems(text))

    def test_step_with_continue_on_error_or_another_lane_is_reported(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        marker = '- name: "%s"\n' % STEP_NAME
        self.assertIn(marker, text)
        self.assertTrue(step_problems(text.replace(marker, marker + "        continue-on-error: true\n", 1)))
        self.assertTrue(step_problems(text.replace("!cancelled() && matrix.mode == 'real' }}\n        shell: pwsh\n        run: |\n          & tests\\selfapps_net_resilience.ps1", "!cancelled() && (matrix.mode == 'real' || matrix.mode == 'justme-test') }}\n        shell: pwsh\n        run: |\n          & tests\\selfapps_net_resilience.ps1", 1)))
        self.assertTrue(step_problems(text.replace("tests/~selftest_netres/**", "tests/~selftest_other/**")))
        self.assertTrue(step_problems(text.replace(STEP_NAME, "Renamed step")))


if __name__ == "__main__":
    unittest.main()
