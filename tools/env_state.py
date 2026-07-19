"""env_state v3 (2026-03-27)
Writes and validates ~env.state.json for the run_setup.bat bootstrap fast path.
Usage:
  python ~env_state.py --check  : print 'skip' if the saved env state is still valid
  python ~env_state.py --write  : write current env state to ~env.state.json
Note: pySpec is intentionally omitted from the state check because run_setup.bat
writes runtime.txt *during* the first bootstrap, so the detected spec on run 2
differs from the empty spec on run 1, causing a spurious cache miss.

This is the canonical source for the HP_ENV_STATE base64 payload embedded in
run_setup.bat. After editing, re-encode and paste it into the
`set "HP_ENV_STATE=..."` line; tests/test_env_state.py asserts the embedded
payload matches this file.
"""
__version__ = "env_state v3 (2026-03-27)"
__all__ = ["read_state", "write_state", "check_state"]

import json
import os
import sys

STATE_FILE = "~env.state.json"
LOCK_FILE = "~environment.lock.txt"


def _lock_size():
    try:
        return os.path.getsize(LOCK_FILE)
    except OSError:
        return 0


def read_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8", errors="ignore") as fh:
            return json.load(fh)
    except Exception:
        return {}


def write_state():
    env_mode = os.environ.get("HP_ENV_MODE", "")
    env_name = os.environ.get("ENVNAME", "")
    env_path = os.environ.get("ENV_PATH", "")
    lock_size = _lock_size()
    state = {
        "envMode": env_mode,
        "envName": env_name,
        "envPath": env_path,
        "lockSize": lock_size,
    }
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
    except OSError:
        sys.exit(1)


def check_state():
    state = read_state()
    if not state:
        sys.stdout.write("run\n")
        return
    env_name = os.environ.get("ENVNAME", "")
    if not env_name or state.get("envName") != env_name:
        sys.stdout.write("run\n")
        return
    if state.get("envMode") != "conda":
        sys.stdout.write("run\n")
        return
    env_path = state.get("envPath", "")
    if not env_path:
        sys.stdout.write("run\n")
        return
    py_exe = os.path.join(env_path, "python.exe")
    if not os.path.exists(py_exe):
        sys.stdout.write("run\n")
        return
    lock_size = _lock_size()
    if lock_size == 0 or lock_size != state.get("lockSize", -1):
        sys.stdout.write("run\n")
        return
    sys.stdout.write("skip\n")


def main():
    args = sys.argv[1:]
    if "--write" in args:
        write_state()
    elif "--check" in args:
        check_state()
    else:
        sys.stdout.write("run\n")


if __name__ == "__main__":
    main()
