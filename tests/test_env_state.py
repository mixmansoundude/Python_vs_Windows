"""Tests for tools/env_state.py -- writes/validates ~env.state.json for the
run_setup.bat env-state fast path (REQ-009 conda-lane fast path: skip a
redundant conda env re-create when the saved state still matches).

read_state/write_state/check_state reference module-level STATE_FILE/
LOCK_FILE constants (CWD-relative filenames, not parameterized) and read
ENVNAME/ENV_PATH/HP_ENV_MODE from os.environ, so tests patch those module
attributes (mirrors tests/test_detect_python.py's RUNTIME_PATH/
PYPROJECT_PATH patching) and os.environ (patch.dict with clear=True for
full isolation from the real process environment) rather than invoking a
subprocess.

Covers read/write round-tripping, missing/malformed state, and
check_state's full run-vs-skip decision matrix, plus the base64
HP_ENV_STATE payload sync (byte-equality of the embedded payload vs this
source -- mirrors CollectSubmodules/DetectPython/PyprojDeps/DetectVisa/
DepCheck PayloadSync).
"""
import base64
import json
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import env_state
from tools.env_state import check_state, read_state, write_state

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "env_state.py"


class ReadState(unittest.TestCase):
    def test_missing_file_returns_empty_dict(self):
        with tempfile.TemporaryDirectory() as d:
            with patch.object(env_state, "STATE_FILE", str(Path(d) / "~env.state.json")):
                self.assertEqual(read_state(), {})

    def test_valid_json_parsed(self):
        with tempfile.TemporaryDirectory() as d:
            state_path = Path(d) / "~env.state.json"
            state_path.write_text(json.dumps({"envMode": "conda"}), encoding="utf-8")
            with patch.object(env_state, "STATE_FILE", str(state_path)):
                self.assertEqual(read_state(), {"envMode": "conda"})

    def test_malformed_json_returns_empty_dict(self):
        with tempfile.TemporaryDirectory() as d:
            state_path = Path(d) / "~env.state.json"
            state_path.write_text("not valid json {{{", encoding="utf-8")
            with patch.object(env_state, "STATE_FILE", str(state_path)):
                self.assertEqual(read_state(), {})


class WriteState(unittest.TestCase):
    def test_writes_expected_fields_from_env(self):
        with tempfile.TemporaryDirectory() as d:
            state_path = Path(d) / "~env.state.json"
            lock_path = Path(d) / "~environment.lock.txt"
            lock_path.write_text("numpy=1.26.0=py311h0\n", encoding="ascii")
            with patch.object(env_state, "STATE_FILE", str(state_path)), \
                 patch.object(env_state, "LOCK_FILE", str(lock_path)), \
                 patch.dict(os.environ, {
                     "HP_ENV_MODE": "conda",
                     "ENVNAME": "myapp",
                     "ENV_PATH": r"C:\envs\myapp",
                 }, clear=True):
                write_state()
            written = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(written, {
                "envMode": "conda",
                "envName": "myapp",
                "envPath": r"C:\envs\myapp",
                "lockSize": lock_path.stat().st_size,
            })

    def test_missing_env_vars_default_to_empty_string(self):
        with tempfile.TemporaryDirectory() as d:
            state_path = Path(d) / "~env.state.json"
            lock_path = Path(d) / "~environment.lock.txt"
            with patch.object(env_state, "STATE_FILE", str(state_path)), \
                 patch.object(env_state, "LOCK_FILE", str(lock_path)), \
                 patch.dict(os.environ, {}, clear=True):
                write_state()
            written = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(written["envMode"], "")
            self.assertEqual(written["envName"], "")
            self.assertEqual(written["envPath"], "")
            self.assertEqual(written["lockSize"], 0)


class CheckState(unittest.TestCase):
    def _check(self, d, state=None, env=None, python_exists=False):
        state_path = Path(d) / "~env.state.json"
        lock_path = Path(d) / "~environment.lock.txt"
        env_dir = Path(d) / "envdir"
        env_dir.mkdir(exist_ok=True)
        if state is not None:
            state_path.write_text(json.dumps(state), encoding="utf-8")
        if python_exists:
            (env_dir / "python.exe").write_text("stub", encoding="ascii")
        lock_path.write_text("numpy=1.26.0=py311h0\n", encoding="ascii")
        import io
        import contextlib
        buf = io.StringIO()
        with patch.object(env_state, "STATE_FILE", str(state_path)), \
             patch.object(env_state, "LOCK_FILE", str(lock_path)), \
             patch.dict(os.environ, env or {}, clear=True), \
             contextlib.redirect_stdout(buf):
            check_state()
        return buf.getvalue().strip(), str(env_dir), lock_path.stat().st_size

    def test_no_state_file_runs(self):
        with tempfile.TemporaryDirectory() as d:
            out, _, _ = self._check(d, state=None, env={"ENVNAME": "app"})
            self.assertEqual(out, "run")

    def test_envname_not_set_runs(self):
        with tempfile.TemporaryDirectory() as d:
            out, _, _ = self._check(
                d, state={"envName": "app", "envMode": "conda", "envPath": "x", "lockSize": 0},
                env={})
            self.assertEqual(out, "run")

    def test_envname_mismatch_runs(self):
        with tempfile.TemporaryDirectory() as d:
            out, envdir, _ = self._check(
                d, state={"envName": "other", "envMode": "conda", "envPath": "x", "lockSize": 0},
                env={"ENVNAME": "app"})
            self.assertEqual(out, "run")

    def test_env_mode_not_conda_runs(self):
        with tempfile.TemporaryDirectory() as d:
            out, envdir, _ = self._check(
                d, state={"envName": "app", "envMode": "uv", "envPath": "x", "lockSize": 0},
                env={"ENVNAME": "app"})
            self.assertEqual(out, "run")

    def test_empty_env_path_runs(self):
        with tempfile.TemporaryDirectory() as d:
            out, _, _ = self._check(
                d, state={"envName": "app", "envMode": "conda", "envPath": "", "lockSize": 0},
                env={"ENVNAME": "app"})
            self.assertEqual(out, "run")

    def test_python_exe_missing_runs(self):
        with tempfile.TemporaryDirectory() as d:
            envdir = str(Path(d) / "envdir")
            out, _, _ = self._check(
                d, state={"envName": "app", "envMode": "conda", "envPath": envdir, "lockSize": 999},
                env={"ENVNAME": "app"}, python_exists=False)
            self.assertEqual(out, "run")

    def test_lock_size_mismatch_runs(self):
        with tempfile.TemporaryDirectory() as d:
            envdir = str(Path(d) / "envdir")
            out, _, size = self._check(
                d, state={"envName": "app", "envMode": "conda", "envPath": envdir, "lockSize": 999999},
                env={"ENVNAME": "app"}, python_exists=True)
            self.assertEqual(out, "run")

    def test_all_valid_skips(self):
        with tempfile.TemporaryDirectory() as d:
            envdir = str(Path(d) / "envdir")
            lock_path = Path(d) / "~environment.lock.txt"
            lock_path.write_text("numpy=1.26.0=py311h0\n", encoding="ascii")
            actual_size = lock_path.stat().st_size
            out, _, _ = self._check(
                d, state={"envName": "app", "envMode": "conda", "envPath": envdir, "lockSize": actual_size},
                env={"ENVNAME": "app"}, python_exists=True)
            self.assertEqual(out, "skip")


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_ENV_STATE=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_ENV_STATE payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_ENV_STATE base64 is out of sync with tools/env_state.py; re-encode it.",
        )


if __name__ == "__main__":
    unittest.main()
