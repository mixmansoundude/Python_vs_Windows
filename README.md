# Python_vs_Windows

[![Batch syntax/run check](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/batch-check.yml/badge.svg?branch=main)](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/batch-check.yml)
[![CodeQL](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/mixmansoundude/Python_vs_Windows/actions/workflows/codeql.yml)

Prime Directive: With only one or more Python files on a clean Windows 10+ machine with internet, get at least one to run, with all imports installed.

---

## TL;DR (Quickstart)

1. Windows 10 (1809+) or newer.
2. Put your `.py` app files in a folder.
3. Put `run_setup.bat` in the same folder.
4. Double-click `run_setup.bat`.
   - Core flow targets **non-admin** install under `%PUBLIC%\Documents` using Miniconda.
   - **NI-VISA** (optional) may require admin rights. If non-admin is blocked by policy, use an elevated shell.

---

# Software Requirements Directive

## Prime Directive Expanded

- From only one or more `.py` files on a clean Windows 10+ machine with internet, a **single batch file** (double-clicked) must bootstrap everything to run the Python app **with all imports installed**.

### Entry selection (current behavior)
- **0 Python files**: the bootstrapper reports no Python files and skips environment bootstrap. It prints:
  - `Python file count: 0`
  - `No Python files detected; skipping environment bootstrap.`
- **Exactly 1 Python file**: run that file directly.
- **2 or more Python files**: prefer a clear entry by:
  1) Common names in order: `main.py` > `app.py` > `run.py` > `cli.py`
  2) Otherwise, any file containing `if __name__ == "__main__":`
  - If no clear entry is found after those checks, the bootstrapper chooses deterministically and logs the choice.

---

## Platform & Locations

- Platform: Windows 10 (1809+) or newer to leverage built-in `curl` and PowerShell.
- Conda environments: use **Miniconda** (non-admin).
- Writable, non-admin locations under Public Documents:
  - Miniconda root: `%PUBLIC%\Documents\Miniconda3`
  - App workspace: current folder (where the batch runs)

---

## Python & Environment

- Python version detection precedence:
  1. `runtime.txt` (`python-3.x.y` or `3.x[.y]`)
  2. `pyproject.toml` `requires-python`
  3. Otherwise let **conda pick latest** (no hard-coded fallback); then **write back `runtime.txt`**.

- Environment naming: env name equals the **current folder name**.

- Channels policy (determinism and legal-friction avoidance):
  - Before any updates or installs, force **community conda-forge only**:
    ```
    conda config --env --add channels conda-forge
    ```
  - Always install with `--override-channels -c conda-forge`.

---

## Dependencies

- If `requirements.txt` exists and is non-empty:
  - First try bulk install:  
    `conda install --file requirements.txt --override-channels -c conda-forge`
  - If bulk fails, fall back per-package via conda. For `~=` (compatible release), convert to `>=X.Y,<X.(Y+1)` (PEP 440) before feeding conda. Handle this carefully.

- Always run:
pipreqs . --force --mode compat --savepath requirements.auto.txt
and log a **diff vs `requirements.txt`**.

- If there is no usable `requirements.txt`, adopt `requirements.auto.txt` as canonical.

- After conda attempts, run:
pip install -r requirements.txt

to fill remaining gaps quickly.

- Heuristic extras:
- If `pandas` is present, ensure `openpyxl` is included.
- On `ModuleNotFoundError`, extract the missing module, append to `requirements.txt`, merge with `requirements.auto.txt`, then perform a **one-time env rebuild** (guard loop).

---

## NI-VISA (optional external)

- If the app imports `pyvisa` or `visa`, attempt **NI-VISA** Windows driver install if not present (system install, not just a Python package).
- Leave option to disable for debugging purposes.
- May require admin rights.

---

## Executable

- Attempt to produce a **PyInstaller one-file EXE** after setup.
- Name the EXE exactly the env name (equals the folder name).
- Fast path: if sources are unchanged since the last EXE build, detect early and run the existing EXE.

---

## Maintenance, Logging, and Lessons Learned

- Update conda base periodically (~30 days), but **skip on first Miniconda install**. Ensure base is configured to conda-forge before updating to avoid prompts.
- Single rolling log `~setup.log` capped near **10 MB** total, don't spin out extra log files. Trim at start. Use debug-level detail when `VERBOSE=1`.
- Tilde-prefix any files not meant to persist (or may remain after a crash) so they are easy to ignore in VCS.
- Batch robustness for some approaches:
- Avoid `EnableDelayedExpansion`. If unavoidable, enable only around the exact lines, then disable. Force disable at script start.
- Be robust against parent shells started with `CMD /V:ON` and 3rd-party wrappers.
- Treat special characters (`&`, `~`, etc.) carefully in batch.
- ASCII only: no emojis, curly quotes, em-dashes, or ellipses.
- Always call the batch (call "%CONDA_BAT%" ...) so the parent script continues.
- Quote batch variables carefully to survive if there are spaces in their contents.
- After the silent install, recompute the %CONDA_BAT% path (condabin first; Scripts as fallback).

---

## Agent Guardrails (Codex / Copilot / other agents)

- Enforce and obey this readme document and see See **[AGENTS.md](./AGENTS.md)**.
  
---

## Repository Map

- `run_setup.bat` — bootstrap installer (Miniconda + env + deps + optional EXE)
- `run_tests.bat` — CI/static checks and harness
- `tests/` — PowerShell/batch harness, log helpers, and ndjson summaries
- `.github/workflows/` — CI workflows (batch check + CodeQL)
- Helper scripts are emitted on demand by `run_setup.bat`; no committed helper directory is required.

### Bootstrap status contract

`run_setup.bat` writes `~bootstrap.status.json` alongside its logs with ASCII JSON describing the bootstrap result:

```json
{"state":"ok|no_python_files|error","exitCode":0,"pyFiles":0}
```

- `state` is `ok` when at least one Python file bootstrapped successfully, `no_python_files` when none were discovered, and `error` if the bootstrapper halted.
- `exitCode` mirrors the batch exit code so harnesses can fail fast on real bootstrap errors.
- `pyFiles` records how many `.py` files were counted before the environment build began.

The CI harness and `tests/selftest.ps1` read this file to validate both the empty-folder (`no_python_files`) flow and the stub bootstrap path with a simple `hello_stub.py` runner.

### Rebuilding embedded helper payloads

`run_setup.bat` stores its helper scripts and `.condarc` template as base64 strings so the bootstrapper stays self-contained. To refresh one of the payloads, run a short Python snippet and paste the output back into the batch file (see also https://docs.python.org/3/library/base64.html).

```batch
python - <<'PY'
import base64, pathlib
payload = pathlib.Path('path/to/helper.py').read_bytes()
print(base64.b64encode(payload).decode('ascii'))
PY
```

Update the corresponding `set "HP_*"=...` line under `:define_helper_payloads` with the new base64 text. The batch file comments point back to this section when further guidance is needed.

## How CI decides pass/fail

See [docs/ci_contract.md](docs/ci_contract.md) for the GitHub Actions contract covering the bootstrap status JSON, dynamic test skip rules, summary layout, and archived artifacts.

---

## Contributing

See `CONTRIBUTING.md`. PRs are welcome. Keep CI green.

## Security

See `SECURITY.md`. Do not include secrets in issues or PRs.

## License

MIT — see `LICENSE`.
