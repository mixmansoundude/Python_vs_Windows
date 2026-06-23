# Agent Lessons Learned -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-lessons-learned.md`
import in CLAUDE.md. It collects standalone hazards, hard-won rules, budgets, gotchas, and
procedures discovered while working on this repo -- the things that are easy to get wrong
again and cost a CI cycle (or worse) to rediscover.

**Categorization principle (shared with `docs/agent-interconnect.md`):**
- **interconnect** = a dependency between two or more components such that changing one
  requires understanding the other ("touch A, must understand B"). Lives in
  `docs/agent-interconnect.md`.
- **lessons learned** = a discovered fact, hazard, budget, or procedure that stands on its
  own. Lives here.

**AGENT DIRECTIVE: keep this file AND `docs/agent-interconnect.md` current -- update existing
entries, not just append new ones -- in the SAME commit as the change that taught (or
invalidated) the lesson. Most lessons in this repo are batch/CMD syntax quirks and Windows
shell gotchas; record those here. Record cross-component effects in the interconnect map. If
a lesson is later disproven or fixed at the source, edit the entry to say so rather than
leaving stale guidance.**

---

## Ambient Python path leakage in uv sub-bootstrap venvs (fixed via `UV_PYTHON_PREFERENCE=only-managed`)

**This was an isolation-boundary leak in our bootstrapper, NOT a uv defect.** uv was doing
exactly what it is designed to do: with no version constraint and no managed-only
preference, it discovers and uses an interpreter already on the host (PATH / registry /
toolchain cache). The bug was that `run_setup.bat` never told uv to stay inside its own
managed toolchain, so sub-bootstrap venvs silently inherited whatever ambient Python the
runner happened to ship.

**Observed symptom:** in uv-first lanes (`real`, `uv`, `contract-uv`, `contract-uv-fail`),
`uv venv` created `.uv_env` from the GitHub runner's `C:\hostedtoolcache\windows\Python\...`
interpreter (3.12.10 as of 2026-06; historically 3.9.25) instead of the latest managed
CPython. The orchestration layer and its embedded helpers then ran on an older,
ambient Python than intended. Earlier this also surfaced as `self.pyproject.malformed`
failing because a helper assumed `tomllib` (3.11+ stdlib) on an ambient 3.9.x.

**Fix (orchestration layer):** at the very start of the uv acquisition block in
`run_setup.bat` (before the `PVW_UV_EXE` branch and before the first uv invocation):
```bat
set "UV_PYTHON_PREFERENCE=only-managed"
```
This blinds uv to ambient/system/conda interpreters. With no user constraint, uv selects
(downloading if necessary) the latest managed CPython. A user-provided version is still
honored: `runtime.txt`/`pyproject.toml` flows through PYSPEC and is forwarded as
`uv venv --python X.Y` downstream (see `docs/agent-interconnect.md` "uv Coverage Status"
and the REQ-004 forwarding). The `set` lives inside the self-contained bootstrapper -- a
real double-click user has no CI `env:` block, so this is the only thing that protects them;
do NOT move it into `batch-check.yml`.

**Two layers, deliberately decoupled:**
- *Orchestration layer* (the bootstrapper, diagnostics, helper scripts): ALWAYS the latest
  managed CPython. It must not be held hostage by the target app's version constraints.
- *Target layer* (the user's app venv): honors an explicit user `runtime.txt`/`pyproject.toml`
  downstream via `--python`.

**Verification:**
- Runtime proof: `self.uv.managed.interpreter` (`tests/selfapps_envsmoke.ps1`) asserts the
  `.uv_env` base interpreter resides under uv's managed root (`uv python dir`) and matches
  the managed `cpython-<ver>-<os>` naming. It is version-agnostic on purpose (no hardcoded
  version) and skips on the graceful paths (conda-only lane, uv not acquired, uv fell back).
- Config-presence: `uv.python.preference.configured` (`tests/harness.ps1`) statically
  confirms the `set` line exists. This is a configuration check, NOT a runtime assertion --
  the runtime guarantee is the envsmoke row above.

### Embedded-helper Python baseline: target modern, degrade gracefully (syntax vs. feature)

With managed-only orchestration, embedded `HP_*` helpers normally run on the latest managed
CPython. But fallback paths still exist where `HP_PY` can be an older ambient interpreter
(venv-fallback, system-Python consent path, `HP_CI_SKIP_ENV`). So the rule is no longer
"must run on 3.9," but it is NOT "modern only" either:

- **Feature guards are fine.** Modern *stdlib features* (e.g. `tomllib`, 3.11+ modules) MAY
  be used when wrapped in `try/except ImportError` with a working fallback. `HP_PYPROJ_DEPS`
  is the gold standard: it tries `import tomllib`, sets `tomllib = None` on failure, and
  falls back to a regex TOML parser.
  ```python
  try:
      import tomllib
  except ImportError:
      tomllib = None
  ```
- **Core token SYNTAX must stay parse-compatible with older interpreters.** A
  `SyntaxError` is raised at parse/compile time -- BEFORE any `try/except` runs -- so it
  cannot be caught at runtime and produces a hard, ugly crash. Therefore do NOT use
  parse-time-only modern syntax in embedded helpers: no bare `match`/`case` (3.10+), no
  `X | Y` runtime type unions in evaluated positions (use string-literal annotations or
  `typing.Optional`), no other grammar that an older CPython would reject while tokenizing.
- **Net:** target modern CPython; gracefully degrade on older interpreters when feasible;
  never assume a newest-stdlib feature without a fallback; keep the file's syntax loadable
  by the oldest interpreter any fallback path might hand it.

---

## Batch / CMD.EXE syntax quirks (the most common source of regressions)

The bootstrapper is a single self-contained `.bat` file, so CMD.EXE parsing rules dominate
the bug surface. `CLAUDE.md` "Common Pitfalls" and "Key Conventions" are the authoritative
list; the recurring traps that have actually bitten us:

- **Parse-time vs. runtime variable expansion.** CMD expands `%VAR%` when it *parses* a
  block, not when it executes each line. Inside a parenthesized `if (...)`/`for (...)` block,
  a `%VAR%` set earlier in the same block still reads its OLD value. (This caused the
  drag-and-drop empty-filename bug: `%MAIN_FILE%` expanded before `set "MAIN_FILE=%~1"` ran.
  Fix: reference the `%~1` parameter directly, or restructure out of the block.)
- **`%%` inside `for` loops.** Loop variables and any literal `%` must be doubled (`%%I`,
  `%%`) inside `for` bodies in a `.bat` file.
- **Special characters need escaping/quoting:** `&`, `|`, `<`, `>`, `^`, `!`, `~`, and `%`
  in values require quoting or `^`-escaping; `%` must be doubled (`%%`).
- **Avoid `EnableDelayedExpansion`; if unavoidable, wrap it tightly.** `!` becomes special
  under delayed expansion, and a parent shell launched with `/V:ON` causes `!`-collisions.
  `tests/harness.ps1` `batch.bang.scan` enforces "no `!` in live batch code lines."
- **`call "%CONDA_BAT%" ...` for all conda invocations** so the parent batch keeps running
  after conda's own batch returns (a bare invocation can terminate the parent).
- **CMD `set` 8191-character hard limit** -- see the dedicated section below.
- **Line endings:** `.bat`/`.ps1` are CRLF, everything else LF, controlled by
  `.gitattributes` (do not hand-edit). LF-only edits to `.bat`/`.ps1` can fail locally
  before git normalizes them on commit.
- **`:die` uses `exit /b`** (subroutine return), so the batch process can still exit 0 even
  after a logical failure -- check `~bootstrap.status.json` / log markers, not just the
  process exit code, when reasoning about success.

**PowerShell adjacent traps:** `-or`/`-and` outside a conditional are parsed as parameter
names ("parameter name 'or'"); `tools/check_delimiters.py` flags these. Multi-line `run:`
PowerShell in YAML interacts badly with quote nesting -- run `actionlint` on changed
workflows.

---

## `:log` echoes UNQUOTED -- never route shell metacharacters through it

`:log` in `run_setup.bat` does `set "MSG=%~1"` then `echo %date% %time% %MSG%` -- the message
is echoed **unquoted**. If `%MSG%` contains a redirection/pipe metacharacter (`<`, `>`, `|`,
`&`), cmd's parser treats it as a redirection/pipe at execution time, corrupting the log line
and/or creating a stray file (e.g. `call :log "...with Python >=3.11..."` would try to write
to a file named `=3.11`). This is the cmd.exe escape trap.

**Rule:** never pass a value containing `<`/`>`/`|`/`&` into `:log`. If you must surface such
a value, forward it **only** through a tightly double-quoted argument to the actual command
(e.g. `uv venv --python "%HP_UV_PY_REQ%"`) -- double quotes shield those characters from the
redirection parser -- and log a separate **operator-free** display string instead. The
floor-vs-pin change (REQ-004) is the canonical example: `HP_UV_PY_REQ` (may contain `>=`/`<`,
quoted at the uv call site only) vs `HP_UV_PY_DISP` (`X.Y` / `X.Y or newer`, safe for `:log`).

**Deferred tech debt -- do NOT "fix" `:log` with delayed expansion.** A global hardening of
`:log` to swallow metacharacters via `setlocal enabledelayedexpansion` + `echo !MSG!` is
**blocked** by three CI static checks in `tests/harness.ps1`: `batch.delayed.off` (requires
`DisableDelayedExpansion` present), `batch.delayed.enable_absent` (forbids
`EnableDelayedExpansion`), and `batch.bang.scan` (no `!` in live batch lines). Those guards
exist because process-wide delayed expansion previously caused `!`-collision debugging pain.
If a global `:log` fix is ever pursued, it is its own isolated task that must also revisit
those checks -- not a drive-by change.

---

## INVENTORY_B64 E2BIG pattern (publish_index.py)

Passing large data through step env vars (`INVENTORY_B64` was ~168 KB base64) overflows
Linux's `execve` ARG_MAX. Fix: read the same data from a file written to disk by the
inventory step instead of routing it through the process environment. Applied to
`tools/diag/publish_index.py` and `.github/workflows/batch-check.yml`.

General rule: NEVER pass data >32 KB through GitHub Actions step `env:` -- write to a
temp file in `$GITHUB_WORKSPACE` and read from disk instead.

---

## Heuristic dep-augmentation (HP_PREP_REQUIREMENTS): pandas[excel] extras syntax

The `names_lower` list is built from `pip_specs` by splitting at version specifier chars
and lowercasing. The original code did NOT strip pip extras (`[excel]`) before the lookup,
so `pandas[excel]` was stored as `"pandas[excel]"` in `names_lower` and the check
`'pandas' in names_lower` returned `False`.

**Fix applied (2026-06-21):** Strip `[...]` from each name before lowercasing:
```python
names_lower = [re.sub(r"\[.*?\]", "", re.split(r"[<>=!~,\s]", value, maxsplit=1)[0]).strip().lower() for value in pip_specs]
```

Covered by `tests/test_heuristics.py::TestPandas::test_pandas_extras_triggers`.

The fix is load-bearing for the primary use case: users who copy `pandas[excel]` from
modern documentation into requirements.txt now get openpyxl and xlsxwriter injected.

---

## CMD.EXE 8191-Character Line Limit for HP_* Payloads

**Critical: every `set "HP_VARNAME=..."` line in run_setup.bat must stay under 8191 total characters.**

CMD.EXE enforces a hard 8191-character line limit for `set` commands. Exceeding this causes
CMD.EXE to crash with exit code `-1073740791` (`0xC0000409` = `STATUS_STACK_BUFFER_OVERRUN`).
The crash is silent and hard to diagnose: `bootstrap.log` will contain only 1-3 early lines
(the UNC-path warning and any REQ-015 lines), and the CI job completes in ~1 second.

**Budget calculation per payload:**
- `set "HP_VARNAME=` prefix = varies (22-26 chars depending on var name)
- `"` suffix = 1 char
- Max b64 content = 8191 - prefix_len - 1

| Payload var | Prefix chars | Max b64 chars | Current b64 | Safety margin |
|-------------|-------------|---------------|-------------|---------------|
| HP_PREP_REQUIREMENTS | 26 | 8165 | 7972 | 192 |
| HP_DEP_CHECK | 18 | 8173 | 3244 | 4928 |
| HP_ENV_STATE | 18 | 8173 | 3280 | 4892 |
| HP_PYPROJ_DEPS | 20 | 8171 | 2868 | 5302 |

**HP_PREP_REQUIREMENTS is the tightest** because it encodes the largest helper.
The 192-char safety margin is narrow. Before expanding the payload, verify b64 length:
```python
import base64
b64 = base64.b64encode(open('helper.py', 'rb').read()).decode('ascii')
line_len = len('set "HP_PREP_REQUIREMENTS=') + len(b64) + 1  # +1 for closing " (prefix=26)
print(f"b64={len(b64)}, line={line_len}, margin={8191-line_len}")
assert line_len <= 8191, f"CMD line limit exceeded by {line_len-8191} chars!"
```

**Crash diagnosis checklist:**
1. bootstrap.log has only 1-3 lines (not the usual 50+ lines)
2. CI job runtime is ~1s (not the usual 5-15 min)
3. `exit code -1073740791` or `0xC0000409` in CI step output
4. Failure happens at `call :define_helper_payloads` (line ~188 of run_setup.bat)
5. Run `python -c "line = open('run_setup.bat').read().split('\n'); [print(i, len(l), l[:60]) for i, l in enumerate(line) if len(l) > 8190]"` to find offending lines

**Occurred in commit `23c1ed9`:** Adding `strip_extras()` function to HP_PREP_REQUIREMENTS
pushed the line to 8215 chars. Fixed in `d8f313c` by removing the redundant function
(NAME_PATTERN already stops at `[`, so `strip_extras()` was a no-op).

---

## Embedded Helper Update Workflow

All helpers embedded in `run_setup.bat` as `HP_*` base64 vars have NO standalone source file.
The canonical source is the decoded base64. To update a helper:

1. Extract + decode:
   ```python
   import base64, re
   with open('run_setup.bat', 'r', encoding='ascii', errors='ignore') as f:
       for line in f:
           m = re.match(r'^set "HP_VARNAME=(.*)"$', line.rstrip('\r\n'))
           if m:
               print(base64.b64decode(m.group(1)).decode('ascii'))
               break
   ```
2. Edit the decoded Python source.
3. Re-encode:
   ```python
   import base64
   new_b64 = base64.b64encode(open('helper.py', 'rb').read()).decode('ascii')
   ```
4. Replace the `set "HP_VARNAME=..."` line in run_setup.bat.
5. Run `python tools/check_delimiters.py run_setup.bat` and the relevant unit test.

**Python baseline reminder:** With `UV_PYTHON_PREFERENCE=only-managed`, helpers normally run
on the latest managed CPython, but fallback paths can still hand them an older ambient
interpreter. Target modern CPython, guard modern *stdlib features* with `try/except`, and
keep the file's *syntax* parse-compatible with older interpreters (no `match`/`case`, no
evaluated `X | Y` unions). See "Embedded-helper Python baseline" above.
