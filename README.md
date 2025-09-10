# Python_vs_Windows
# Software Requirements Directive

## Prime Directive
From only one or more `.py` files on a clean Windows 10+ machine with internet,  
the batch must bootstrap everything to run the Python app with all imports installed—without requiring any other project files.

---

## Platform & Locations
- **Platform**: Windows 10 (1809+) only; rely on built-in `curl` and PowerShell.
- **Locations (non-admin, writable installs in Public Documents):**
  - Miniconda root: `%PUBLIC%\Documents\Miniconda3`
  - Conda envs: `%PUBLIC%\Documents\CondaEnvs`
  - App workspace: current working folder (where the batch runs)

---

## Python & Environment
- **Python version detection precedence:**
  1. `runtime.txt` (`python-3.x.y` or `3.x[.y]`)
  2. `pyproject.toml` → `requires-python`
  3. Otherwise: let conda pick latest (no hard-coded fallback), then write back `runtime.txt`.

- **Conda env name**: equals the current folder name.  
  Env is created under `%PUBLIC%\Documents\CondaEnvs\<envname>`.

- **Channels policy** (determinism & legal friction avoidance):
  - Before any updates/installs, force `conda-forge` only:
    ```bash
    conda config --env --add channels conda-forge
    conda config --env --remove channels defaults  # ok if absent
    ```
  - Always install with `--override-channels -c conda-forge`.

---

## Dependencies
- **requirements.txt handling:**
  - If present and non-empty:
    - First: `conda install --file requirements.txt --override-channels`
    - If that fails: retry per-package with conda.  
      For `~=` version specifier, convert to `>=X.Y,<X.(Y+1)` (PEP 440 compatible).
  - Always run:
    ```bash
    pipreqs . --force --mode compat --savepath requirements.auto.txt
    ```
    and log a diff vs `requirements.txt`.
  - If no usable `requirements.txt`, adopt `requirements.auto.txt` as canonical.
  - After conda attempts, always run `pip install -r requirements.txt`.

- **Heuristic extras:**
  - If `pandas` is present, ensure `openpyxl` is included.
  - On `ModuleNotFoundError`, extract missing module, append to `requirements.txt`, merge with `requirements.auto.txt`, then one-time rebuild env (guard loop).

---

## NI-VISA (Optional External)
- If app code imports `pyvisa` or `visa`, attempt Windows driver install (NI-VISA) if not present.  
- Can be disabled via `VISAINSTALL=no`.  
- Note: This is a system install, not just a Python package.

---

## Executable
- Always ensure a PyInstaller one-file exe is present after setup.
- Name the exe exactly the env name (equals folder name).
- If sources unchanged since last exe build, detect early and just run the exe (fast path).

---

## Maintenance & Logging
- Update conda base periodically (~30 days), but skip on first Miniconda install.  
  Always ensure base uses `conda-forge` before updating to avoid prompts.
- Maintain a single rolling log `~setup.log` capped at ~10MB with rotation.  
  `VERBOSE=1` enables debug-level detail.
- Tilde-prefixed helper files are VCS-ignorable.
- Avoid `EnableDelayedExpansion`. If unavoidable, enable only around exact lines then disable.  
  - Force disable at the start to be safe.  
  - Be robust against parent shells launched with `CMD /V:ON` or 3rd-party wrappers.
- Handle batch-file quirks with `&`, `~`, and other special characters carefully.
- Use **ASCII basic text only**: no emojis, curly quotes, em-dash, or ellipsis.

---
