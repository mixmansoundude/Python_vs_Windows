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

## REQ-013 connectivity check needed the REQ-022 retry idiom too -- and a second technique for the in-block case

`:check_net_after_dl_fail` (the REQ-013 "is the host actually offline" probe) did exactly ONE
`ping -n 1 8.8.8.8` and, if that failed, exactly ONE `curl --connect-timeout 5 --max-time 8` to
`conda.anaconda.org` -- zero retries on either check. Root-caused a real CI failure to this: a
single dropped ICMP echo plus a curl connect that happened to exceed 5s (plausible under network
contention on a shared runner, especially in the `conda-full` lane which is mid-flight doing
several other real network operations for its ~80-minute duration) is enough to misclassify a
genuinely-online host as offline. This is the same transient-single-shot-check problem REQ-022
already solved for `:try_conda_create`/`:conda_bulk_install` (detect, wait, retry once) -- just
never applied to this subroutine.

Fixed by adding a 2-total-attempts retry to both the ping and curl checks, but using **two
different techniques depending on nesting**, because this subroutine has both a top-level check
and an in-block check:

- **Top-level check** (the initial ping/curl, not nested in any parenthesized block): a normal
  `set "HP_CONN_PING_ATTEMPT=0"` + `:label` + `set /a HP_CONN_PING_ATTEMPT+=1` + single-line
  `if %HP_CONN_PING_ATTEMPT% LSS 2 goto :label` counter loop is safe here, because every line is
  freshly parsed at the top level -- no parenthesized block is freezing any `%VAR%` read.
- **In-block check** (the "Y" interactive retry, nested inside `if /I "...=="y" ( ... )`): a
  counter variable would NOT work here -- `set /a`-ing it and then reading it via `if %VAR% LSS 2
  goto` INSIDE the same parenthesized block hits the exact parse-time `%VAR%`-expansion trap
  documented above ("Provider-cascade dispatch is goto-based on purpose"): the whole block is
  read once before any of its `set` statements execute, so the counter read would always see the
  pre-block (0/undefined) value, making the loop condition always true or always false depending
  on how it's written, never the real in-block-incremented count. Fixed instead by literally
  duplicating the ping/curl-and-check pair a second time (2 total attempts spelled out, no
  variable) -- there is nothing to freeze when there is no counter variable at all. **Rule of
  thumb:** inside a parenthesized block, prefer literal duplication over a counter-variable retry
  loop for a small, fixed attempt count (2-3); reserve the counter-loop idiom for top-level code.

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

## A single trailing backslash before a closing quote silently corrupts a subprocess argument

**Discovered 2026-07-18 via a real CI failure** on the REQ-025-family system-directory guard
(`self.warn.sysdir`, `run_setup.bat`): `findstr /I /C:"%WINDIR%\" >nul` never matched, even
against a script root genuinely under `%WINDIR%\Temp\...` in real Windows CI -- the guard
silently never fired (`errFound: false, exitCode: 0` on every lane) despite `HP_SCRIPT_ROOT`
being provably correct (the OneDrive guard's own substring check, running moments earlier in
the same file, passed normally).

**Root cause: this is NOT a cmd.exe `%VAR%`-expansion bug (the class already documented above)
-- it's the separate, standard Windows C-runtime argv-parsing rule that `findstr.exe` (like
nearly every native Windows console app) applies to ITS OWN command line after cmd.exe hands it
off.** That rule: N backslashes immediately followed by a `"` collapse to `N/2` literal
backslashes, and if N is ODD, the trailing backslash "escapes" the quote -- the quote becomes a
literal character instead of closing the string. `%WINDIR%\"` expands to `C:\Windows\"`: a
single (odd) backslash before the quote, so the quote does NOT close -- the rest of the line,
including the trailing `>nul`, gets silently absorbed into the (now-corrupted, never-matching)
search pattern. No error, no crash -- the check just quietly never works. Confirmed by directly
implementing the parsing rule in Python and running both the old and new pattern through it (see
PR that added this entry for the exact repro) -- verified the OLD pattern indeed fails to close
the quote, and the FIX (see below) closes it correctly with a single literal trailing backslash
as intended.

**Fix: double the trailing backslash** (`%WINDIR%\\"` instead of `%WINDIR%\"`) -- an EVEN count
(2) collapses to exactly one literal backslash and the quote closes normally, giving the intended
search text (`C:\Windows\`) with the trailing-slash anchor still doing its job of preventing a
same-prefix false match (e.g. `C:\WindowsFooBar\` does not contain the substring `C:\Windows\`).

**Rule of thumb for ANY future `findstr /C:"...%VAR%..."` (or any other native-exe subprocess
argument) whose value can end in a backslash**: never let a `%VAR%`-expanded value that might end
in `\` sit immediately before the closing `"` with nothing in between. Either double the trailing
backslash defensively, or restructure so the closing quote is never adjacent to a variable-derived
trailing backslash. This is a DIFFERENT hazard from cmd.exe's own parse-time `%VAR%` expansion
(the "Parse-time vs. runtime variable expansion" entry above) -- that one is about WHEN a `%VAR%`
gets substituted; this one is about HOW the resulting text is re-parsed by the child process cmd
hands it to. Existing `findstr /C:"..."` call sites in this file (the UNC-path check at the very
top, `\\\\`, and the `.gitignore`/`.gitattributes` signature checks) happen to be safe already --
none of their literal search strings end in an odd number of backslashes -- but this was luck, not
design, until this entry documented the rule explicitly.

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

**Concrete unresolved instance, accepted risk, no action planned: `%HP_ENTRY%`.** `%HP_ENTRY%`
is echoed unquoted at 4 call sites: the raw `echo` alphabetical-fallback hint and the
`[INFO] REQ-002: Picker entry selected:` `:log` call, both inside `:pick_entry_interactive`;
the `[ERROR] REQ-021: entry failed py_compile` `:log` call inside `:preflight_compile`; and the
`[INFO] Launching your program now via the ... interpreter:` `:log` call inside
`:verify_no_exe_probe`. A filename containing `<`/`>`/`&`/`|` would in principle mis-parse as a
redirection/pipe operator here, exactly per the rule above. This requires a
maliciously-or-accidentally-crafted filename delivered via a Windows double-click/drag-and-drop
flow (not a common vector), and the only real fix is the global `:log` rework already documented
as blocked by the three CI static guards above. Noted here so it isn't rediscovered as a "new"
finding later.

---

## Provider-cascade dispatch is goto-based on purpose (parse-time expansion)

`:provider_cascade` (REQ-009/REQ-005.10 slice 3) routes by `HP_ENV_MODE` to one of
`:cascade_from_uv` / `:cascade_from_conda` / `:cascade_from_venv` using **one-line `if /i ...
goto`** statements, not a big parenthesized `if (...)` block. This is deliberate: inside the
`uv -> conda` path we `set "HP_ENV_MODE=conda"` and then `set "ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%"`
and immediately `goto :try_conda_create`. If those were inside a single parenthesized block,
CMD's parse-time `%VAR%` expansion would read the OLD values of any variable set earlier in
the same block (the classic drag-and-drop empty-filename bug). Splitting into goto-reached
labels means each `set`/read happens on a freshly parsed line. **If you refactor the cascade
into nested `( ... )` blocks, re-verify every `%VAR%` you read was not `set` earlier in the
same block** -- prefer keeping the goto-dispatch shape.

**Second confirmed instance (Slice 2b-C, `:try_fast_exe` / `:verify_no_exe_interpreter`):** an
earlier revision of the fail-fast probe dispatch launched a process and read
`set "HP_SMOKE_RC=%ERRORLEVEL%"` (plus the immediate SUCCESS/FAILED `[STATUS]` branch) INSIDE the
non-interactive `else ( ... )` clause of an `if defined HP_INTERACTIVE_RUN (...) else (...)`
block -- this is the exact same bug class as the drag-and-drop empty-filename bug and the cascade
gotcha above, just with `%ERRORLEVEL%` as the frozen variable instead of `%MAIN_FILE%`. It froze
silently (no error, no crash) to whatever the errorlevel was right before the dispatch began
(almost always `"0"`, since the preceding line is usually a successful `set`), so a genuinely
broken cached EXE was NEVER discarded via the non-interactive branch in CI. Fixed the same way as
the cascade: `if defined HP_INTERACTIVE_RUN goto :<label>_probe` instead of a parenthesized
if/else, so the launch + `%ERRORLEVEL%` capture + STATUS branch are all top-level lines, each
parsed fresh. **Any time a diff wraps a previously-top-level "launch a process, read
`%ERRORLEVEL%`" sequence inside a NEW `if (...) ( ... ) else ( ... )` block for ANY reason
(feature-flagging, dispatch, refactor), stop and check whether the read is safe** -- this is easy
to introduce by accident precisely because the surrounding lines look unchanged and the bug
produces no error, only a silently wrong captured exit code.

Two more cascade gotchas worth remembering:
- `if defined HP_CASCADE_TRIED_UV` / `if not defined CONDA_BAT` are **runtime** checks (safe
  inside blocks); `%HP_CASCADE_TRIED_UV%` / `%CONDA_BAT%` are parse-time (not safe). The
  per-tier no-retry guards use the `if defined` form for exactly this reason.
- `:cascade_acquire_conda` is `call`ed (not `goto`'d) so it returns; it relies on
  `MINICONDA_ROOT`/`CONDA_MAIN`/`CONDA_ALT` already being set near line 410 (they are, even in
  uv-first runs -- only the *install* at line ~423 is gated on `HP_UV_PROVIDING_PYTHON`).
- The cascade `:log` messages say **"uv to conda"**, not "uv -> conda". `:log` echoes UNQUOTED
  (see the ":log echoes UNQUOTED" section above), so a `>` in the message is parsed as a
  redirection and silently EATS the log line (and litters a stray file). This actually bit
  slice 3: the cascade ran correctly on Windows (uv->conda->venv->stop, no loop, exit 0) but
  `self.cascade.exec` failed because its phrase-count assertions never matched -- the
  `cascading provider uv -> conda` lines had been swallowed by the `>`. Keep these arrow-free.

---

## A declined/failed fallback tier must clear HP_PY, not just return failure

**Discovered 2026-07 via the REQ-009 Tier 5 embed-tier tests (the first tests in this repo's
history to assert the OUTCOME of a fully-exhausted fallback chain, not just that each individual
decline point was logged).** `:try_system_fallback` sets `HP_PY=%HP_SYS_EXE%` *before* the REQ-014
consent gate (so it's ready to use immediately on accept), but on EITHER of the two failure exits
after that point (missing interpreter path, or consent declined) it returned `exit /b 1` without
clearing `HP_PY` back to empty. Combined with `:die` being `call`ed (not `goto`'d) everywhere --
see the "Known Findings" `:die` note elsewhere in this file: `exit /b` inside `:die` only returns
from that one `call`, so execution routinely continues past a `call :die` line to whatever comes
next in the enclosing block -- the leaked, non-empty `HP_PY` silently satisfied
`:after_env_mode_selection`'s `if not defined HP_PY (call :die ...)` guard, the LAST checkpoint
before dependency install/build. The bootstrap then proceeded to actually build and run using
the STALE interpreter path from the declined/failed system attempt, with `HP_ENV_MODE` left at
whatever it was last set to (often still `conda`, its optimistic default) -- silently reporting
full `state=ok` SUCCESS out of a scenario where every real provider tier had failed or been
declined. This directly blocked the new embed tier from ever being reached in any scenario that
declines system consent (both `self.embed.fallback.decline` and `self.embed.fallback.real` decline
system consent to reach embed) -- `self.embed.fallback.real`'s failure signature confirmed it:
`appRan: true` but `extractedLog`/`readyLog`/`providerLogFound` all `false`, meaning the app ran
successfully via the leaked system Python without the embed tier ever being attempted at all.

**Fix**: `:try_system_fallback` now sets `HP_PY=` (clears it) on both failure exits, immediately
before their `exit /b 1`. **Rule for any current or future fallback-tier subroutine that sets
`HP_PY` (or any other "selected provider" variable) speculatively before a gate that can still
decline**: every failure/decline exit AFTER that point must clear the variable back to its
pre-tier state, not just return a non-zero/failure signal -- a failed subroutine's job is to leave
no trace of its attempt in shared state, since callers may (and in this codebase's case, routinely
do, via the `:die`-continues quirk) proceed past a declared failure using whatever is left behind.

**Sibling leak fixed in a follow-up pass:** `:try_venv_fallback`'s `:venv_canary_fail` label had
the identical pattern -- `HP_PY` is set to `.venv\Scripts\python.exe` during venv creation, and if
the post-creation canary probe (REQ-023) then fails, it returned `exit /b 1` without clearing
`HP_PY`. Not hit by either Tier 5 embed test (both force `HP_TEST_FORCE_VENV_FAIL=1`, which exits
before `HP_PY` is ever set in venv's case, so this leak point wasn't on their path), but the same
failure mode was plausible: a real-world venv that creates successfully but fails its canary check
would leak a technically-existing-but-broken interpreter path forward exactly like system's did.
Fixed with `set "HP_PY="` before that `exit /b 1`, exact mirror of the `:try_system_fallback` fix
above.

---

## Env-var flags are scaffolding, not intended run paths (REQ-019)

**Note (2026-07-12): this section's own title previously cited "(REQ-001)" ambiguously.**
`[REQ-001]` in README.md is the Prime Directive itself, not this rule -- this rule *protects*
REQ-001, it isn't numbered as it. The rule described here now has its own proper number,
`[REQ-019]`, promoted from README's previously-unnumbered "Advanced Environment Variables"
section specifically so it stops needing an ambiguous cross-reference like this one.

The intended run paths are **double-click and drag-and-drop with no environment variables**.
Every `HP_*` / `PVW_*` variable is test/CI/super-user scaffolding. **No Prime-Directive outcome
may depend on a user setting one**, and the *absence* of a flag must never block a fallback tier
that gets the code running. A flag may ADD diagnostic/CI behavior or a super-user override, or
DISABLE/skip an optional step (so absence == full behavior) -- but an **opt-in flag must never be
the gate for a behavior the Prime Directive needs**.

This bit us with system Python (REQ-009 Tier 4): it was hard-gated behind
`HP_ALLOW_SYSTEM_FALLBACK==1`, a flag the bootstrapper never sets and a double-click user never
sets, so the last-resort tier was unreachable by default and the REQ-014 consent prompt was dead
code for real users -- a silent violation of REQ-009/REQ-014/Prime Directive. Fix: system Python
is now reached in any run, gated solely by the REQ-014 consent prompt;
`HP_ALLOW_SYSTEM_FALLBACK` is deprecated/ignored (mirroring the earlier `HP_ALLOW_VENV_FALLBACK`
deprecation). `HP_FORCE_CONDA_ONLY` (CI conda-diagnostic lane) is a legitimate *suppression* flag
and stays. **When auditing, treat any `if "%HP_...%"=="1"` that ENABLES a Prime-Directive
behavior as a bug; flags should only suppress, divert for tests, or add super-user overrides.**

**Standing directive: re-run this audit whenever a new `HP_*`/`PVW_*` flag is added.** The
system-Python sweep above was the first pass; it also confirmed two other flag families are
correctly scoped as suppression-only (no further action needed unless a future flag changes
their behavior): `HP_OFFLINE_MODE` is auto-set by the REQ-013 connectivity check and never
something a user is required to set, and `HP_SKIP_*` flags only ever *disable* an optional step
(absence == full behavior, never the reverse). Treat this as a checklist item for every new flag,
not a one-time task -- see the "Periodic Maintenance Checks" section of `CLAUDE.md` for the
scheduled cadence this and other recurring reviews are tracked under.

## CI-safe interactive gates: echo the prompt, then resolve the answer

Any `set /p` consent prompt that can be reached on a non-interactive CI path must be made
CI-safe or it hangs (or relies on a fragile stdin EOF). The established pattern (see
`:cascade_consent_gate` and `:system_python_consent_gate`):

1. **Echo the exact prompt string unconditionally** (a plain `echo`, not via `:log`) so prompt
   assertions still see it even when input is skipped. Put real text after the colon-space so the
   asserted substring (`... [y/n]: `) does not rely on a trailing space surviving an editor.
2. Then branch: `if defined HP_TEST_<X>_ANSWER` (deterministic Y/N override, checked FIRST so an
   explicit `Y` can still ACCEPT in CI) `else if defined HP_CI_LANE` (auto-decline, no `set /p`)
   `else` interactive `set /p`.
3. Keep the accept/decline log lines verbatim -- harness static checks and behavioral tests match
   them. For the system gate: `HP_TEST_SYSCON_ANSWER`, with `batch.req014.consent` asserting the
   flag name is present in `run_setup.bat`.

## INVENTORY_B64 E2BIG pattern (publish_index.py)

Passing large data through step env vars (`INVENTORY_B64` was ~168 KB base64) overflows
Linux's `execve` ARG_MAX. Fix: read the same data from a file written to disk by the
inventory step instead of routing it through the process environment. Applied to
`tools/diag/publish_index.py` and `.github/workflows/batch-check.yml`.

General rule: NEVER pass data >32 KB through GitHub Actions step `env:` -- write to a
temp file in `$GITHUB_WORKSPACE` and read from disk instead.

## `download-artifact@v6` `merge-multiple: true` silently overwrites same-named files

**This has now bitten this repo twice with the identical root cause.** When a workflow step
downloads MULTIPLE artifacts matching a `pattern:`, and each of those artifacts zips a file with
the SAME local filename (only the artifact's own top-level *name* differs, e.g.
`ci_test_results-selftest-<mode>-<run>-<attempt>` all containing `ci_test_results.ndjson`, or
`selftest-verdict-<mode>` all containing `lane_verdict.json`), setting `merge-multiple: true`
extracts every matched artifact into ONE flat directory. Because the local filenames collide,
each subsequent download silently overwrites the previous one -- **only the last-downloaded
artifact's content survives**, with no error, warning, or non-zero exit code anywhere in the
step. Any step downstream that reads "the file" in that directory silently sees just one lane's
data instead of all of them.

**Confirmed instances (both fixed):**
1. `ndjson-registry-check`'s "Download lane NDJSON artifacts" step (added 2026-07): caught during
   CI verification of the job's first real run -- the `--log-dir` cross-check reported only 1
   observed ID across all 8 lanes instead of the expected 100+. This was advisory-only (never
   affected the job's exit code or the primary doc-vs-code diff), but degraded the tool's third
   data source to near-uselessness.
2. `selftest-gate`'s "Download lane verdicts" step (pre-existing, found while auditing the first
   instance for other occurrences of the same pattern): silently limited the `has_failures`
   aggregation to whichever single lane's `lane_verdict.json` happened to survive the collision,
   instead of the OR of all 8 matrix lanes. Lower severity than it sounds -- `has_failures` only
   feeds `model-quick-fix`'s auto-fix trigger (`HAS_FAILURES` env var), NOT PR merge gating
   itself (the `real`/`conda-full` matrix jobs gate merges via their own individual GitHub check
   conclusions, entirely independent of this aggregation) -- but it could have caused the
   auto-fix bot to skip attempting a fix when a non-surviving lane genuinely had failures.

**The fix is the same in both cases and is the correct default: drop `merge-multiple` entirely.**
Without it, `download-artifact@v6` places each matched artifact into its own
`<path>/<artifact-name>/` subdirectory, so no collision is possible. Every consumer in this repo
that reads the downloaded files already does so via `Get-ChildItem -Recurse` / `Path.rglob` /
equivalent, so removing `merge-multiple` requires no other code change -- the recursive read
already looks inside per-artifact subdirectories.

**When `merge-multiple: true` IS actually safe (confirmed present, unfixed, correctly so):**
`batch-check.yml`'s "Download iterate logs artifact" step (`publish_diag` job) downloads a
single artifact by exact `name:`, not a `pattern:` matching several -- there is only ever one
artifact in play, so no collision is possible regardless of the flag.

**Audit method for future additions:** before setting `merge-multiple: true` on any
`download-artifact@v6` step that uses `pattern:` (matches more than one artifact), trace the
matching `upload-artifact@v6` step(s) and check whether the uploaded `path:` is the same local
filename across all matched artifacts. If yes, either drop `merge-multiple` (preferred -- almost
always safe, since consuming code should already handle nested subdirectories) or give each
upload a distinct filename. Do not add `merge-multiple: true` to a new multi-artifact download
step without doing this check first.

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

## Pre-build `--collect-submodules` must be DOUBLE-gated (used AND installed), never installed-only

`HP_COLLECT_SUBMODULES` (`~collect_submodules.py`) emits `--collect-submodules=PKG` flags for a
curated set (sklearn, matplotlib, scipy, plotly) whose submodules load via dynamic dispatch that
PyInstaller's static analysis cannot trace -- the warn file stays silent, so warnfix never repairs
them and the frozen EXE fails at runtime on the un-bundled submodule.

**The gate is deliberately on USED-by-source AND INSTALLED, not on installed alone.** Gating on
"installed" (a bare `find_spec`) would make every EXE bundle hundreds of MB of an unused library
merely because it sits in a fat global/conda env -- a `print("hello")` script would ship all of
scikit-learn. Gating on "used" alone could emit a flag for a package that is imported but absent,
which makes PyInstaller error out. **Do NOT "simplify" this to a single gate.** The double-gate is
the whole point; `tests/test_collect_submodules.py::GatingMatrix` locks both halves.

Two more details a future agent must preserve:
- The curated set uses IMPORT names (`sklearn`, not `scikit-learn`) because `--collect-submodules`
  takes the importable module name AND because matching the import name against project source
  avoids the package-vs-import naming mismatch. Keep the set conservative -- heavy stacks
  (torch/tensorflow/transformers) are excluded on purpose (gigabyte EXEs).
- `HP_PYI_COLLECT` is computed in the `:compute_collect_flags` SUBROUTINE and set BEFORE the
  `if "%HP_ENV_MODE%"=="system" (...) else (...)` build block, exactly like `HP_PYI_EXPAT`. If you
  move the computation inside that parenthesized block, `%HP_PYI_COLLECT%` in the build command will
  parse-time-expand to its OLD (empty) value (the classic drag-and-drop trap). The walk reuses the
  `~detect_visa.py` pattern (skip `~`/`.`-prefixed dirs) and AST-parses with a per-file regex
  fallback so a single un-parseable user file does not blind the scan.

---

## --hidden-import auto-recovery must stay STRICT (ModuleNotFoundError + installed), never broaden to ImportError

`:hidden_import_recover` (REQ-016 Slice 2) re-runs a failed frozen EXE, and via
`~hidden_import_scan.py` (`HP_HIDDEN_IMPORT_SCAN`) decides the next `--hidden-import` target.
It is deliberately gated on TWO conditions and it is a mistake to relax either:

1. **`ModuleNotFoundError: No module named 'X'` only -- NOT a bare `ImportError`.**
   For `ModuleNotFoundError`, X *is* the exact `--hidden-import` target (its code is simply not
   in the bundle). For `ImportError: cannot import name 'Y' from 'Z'`, Z is **already bundled**
   and Y is an *attribute*, not a module -- so **no `--hidden-import` target is derivable** and a
   rebuild cannot fix it. Broadening to ImportError would burn the 3 rebuild cycles and hand back
   the same error. The genuine packaging case behind some ImportErrors (a dynamic
   `except ImportError: from ._fallback import ...` where the fallback was not collected) is
   `--collect-submodules`/`--collect-all` territory (Slice 1 / a future Slice 3), **not** the
   hidden-import token extractor.
2. **X must be installed in the build interpreter (`find_spec`).** This is what makes a user typo
   `import nonexistant` cost **ZERO rebuilds** -- the typo'd module is not installed, so the helper
   emits nothing and the failure routes straight to the post-flight hints. It also excludes a
   genuinely-missing dependency (warnfix's job, not this loop's).

No-loop guarantee: the helper takes an already-tried list and the batch caps at 3 iterations, so
a pathological "different missing module every rebuild" app stops at 3 and a "same module repeats"
app stops after 1. The loop only re-runs the EXE when the *initial* smoke returned a real fast
non-zero exit (not `-1`); a `-1` is a timeout/hang, and re-running a hung EXE in the loop would
hang too, so recovery is skipped for it.

Two batch hazards a future agent must preserve:
- `:hidden_import_recover` is **goto-based, not a parenthesized block**, so each `%HP_HIDDEN_ITER%`
  / `%HP_PYI_HIDDEN_IMPORTS%` reads its runtime value. `set /a HP_HIDDEN_ITER+=1` then
  `if %HP_HIDDEN_ITER% GEQ 3 ...` only works because they are separate lines re-parsed per goto.
- Recovery rebuilds recreate `<ENVNAME>.spec` and `build\<ENVNAME>\` **after** the main-build
  cleanup already ran, so the subroutine cleans them up itself and re-snapshots spec pre-existence
  (`HP_HID_SPEC_PRE`) at entry to avoid clobbering a user's committed `.spec`.

**Test interaction (caught in CI run 28307675855):** any XFAIL test that builds an EXE which fails
on a `ModuleNotFoundError` for an **installed** module is now **auto-recovered** by this loop and
will XPASS. `selfapps_exedyn_fail.ps1` originally dynamically imported colorama (installed) expecting
permanent failure; it was repurposed to import a **non-installed** module so recovery's find_spec
gate correctly declines and the graceful-failure path is still covered (the recover-success case is
covered positively by `selfapps_hidden_import.ps1`). `selfapps_exefail.ps1` (static `import
nonexistent_module`, not installed) and `selfapps_exedata_fail.ps1` (FileNotFoundError, not a MNFE)
are unaffected -- recovery declines for both. When adding a new EXE-failure xfail test, use a
not-installed module or a non-MNFE failure so recovery cannot heal it.

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
| HP_COLLECT_SUBMODULES | 27 | 8163 | 7704 | 459 |
| HP_HIDDEN_IMPORT_SCAN | 27 | 8163 | 5216 | 2947 |
| HP_DEP_CHECK | 18 | 8173 | 3244 | 4928 |
| HP_ENV_STATE | 18 | 8173 | 3280 | 4892 |
| HP_PYPROJ_DEPS | 20 | 8171 | 2868 | 5302 |

**HP_PREP_REQUIREMENTS is the tightest** because it encodes the largest helper
(HP_COLLECT_SUBMODULES is the second-tightest at 459).
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

**PayloadSync tests for a `.ps1` canonical source must normalize CRLF/LF before comparing bytes.**
All prior PayloadSync precedents (`test_collect_submodules.py`, `test_hidden_import_scan.py`)
wrap `.py` canonical sources, which are `eol=lf` per `.gitattributes` -- no checkout-time line
ending translation, so a raw `read_bytes()` byte-comparison against the base64-decoded payload is
safe. The first `.ps1` canonical source with a PayloadSync test (`tools/embed_extract.ps1`, added
for REQ-009 Tier 5) hit a real, CI-only failure this precedent didn't anticipate: `.ps1` files
carry `*.ps1 text eol=crlf`, so `actions/checkout@v5` on the Windows CI runner materializes CRLF
line endings in the working tree regardless of what the payload was encoded from. If the payload
was encoded on a Linux/dev sandbox (LF-only working copy, since files created via a local editor
don't go through git's checkout smudge filter), the base64-decoded bytes stay LF while
`PS_SOURCE.read_bytes()` on the Windows runner returns CRLF -- a byte-for-byte mismatch that
passes locally and fails only in real CI. This is a test-assertion bug only, not a functional one:
the base64 string itself is immune to `.bat` eol conversion (it's plain characters on one line,
no `\r`/`\n` inside it), and the runtime-extracted `.ps1` script works identically whether it
lands on disk as LF or CRLF (PowerShell parses both). Fix: normalize both sides with
`.replace(b"\r\n", b"\n")` before `assertEqual` -- verifies logical content, not incidental
checkout-time line-ending translation. Any FUTURE PayloadSync test added for a `.bat`/`.ps1`/
`.cmd`/`.psm1`/`.psd1` canonical source (anything covered by an `eol=crlf` `.gitattributes` rule)
must include this same normalization from the start; `.py`/`.sh`/other `eol=lf`-attributed sources
do not need it.

**Python baseline reminder:** With `UV_PYTHON_PREFERENCE=only-managed`, helpers normally run
on the latest managed CPython, but fallback paths can still hand them an older ambient
interpreter. Target modern CPython, guard modern *stdlib features* with `try/except`, and
keep the file's *syntax* parse-compatible with older interpreters (no `match`/`case`, no
evaluated `X | Y` unions). See "Embedded-helper Python baseline" above.

**PowerShell helpers apply too, and the choice of inline `-Command` vs. embedded `.ps1` file
matters more than it looks (Slice 2b-C, `HP_FAILFAST_PROBE`):** `:run_exe_smokerun`'s inline
`powershell -Command "..."` one-liners work because they carefully avoid ANY literal `"` character
inside the command body (all internal PowerShell string literals use single quotes, and the final
captured value is a bare expression like `$p.ExitCode`, never a double-quoted interpolated string).
The fail-fast probe needed to build a properly-quoted single argument for
`ProcessStartInfo.Arguments` (`$si.Arguments = '"' + $rawArgs + '"'`, so a script path containing
spaces still parses as one argument) -- and the `'"'` literal (a single-quoted PowerShell string
whose CONTENT is one double-quote character) is itself a literal `"` character sitting in the
command text cmd.exe has to tokenize. **The root cause is any literal `"` appearing anywhere in
the `-Command` body, not specifically interpolation** -- a literal `"` embedded inside an
already-double-quoted `-Command "..."` argument breaks cmd.exe's naive quote-toggle tokenization
of that argument (cmd does not understand PowerShell's quoting rules; it just flips an
in-quotes/out-of-quotes flag on every literal `"` it sees, with no concept of nesting or of
"this quote is inside a single-quoted PowerShell string"). String interpolation
(`"$exceeded|$($p.ExitCode)"`) would trip the SAME hazard if used inline, since it also requires a
double-quoted PowerShell string, but avoiding interpolation alone (e.g. via `+` concatenation)
would NOT have been sufficient here -- the `Arguments` quoting step needed a literal `"` character
regardless of interpolation vs. concatenation. **Fix: emit a standalone `.ps1` file via the
existing `:emit_from_base64` mechanism (exactly like `HP_FAST_CHECK`/`~fast_check.ps1`) and invoke
it with `-File` instead of `-Command`.** A real file has no cmd.exe quote-parsing exposure at all
-- write normal, readable PowerShell inside it, quotes and interpolation both included freely.
Rule of thumb: if an inline `-Command` one-liner would need ANY literal `"` character anywhere in
its body (interpolation, nested quoting, here-strings, or quoting an argument for
`ProcessStartInfo`), stop and make it a `.ps1` helper instead of trying to escape around it.

**Prefer raw .NET types over Utility-module cmdlets (Get-FileHash, Expand-Archive, Get-Content,
Set-Content) in embedded `.ps1` helpers invoked from a `for /f` backtick subshell -- module
auto-loading is not guaranteed there on Windows PowerShell 5.1.** Discovered via a real CI
failure building the REQ-009 Tier 5 embed tier: `tools/embed_extract.ps1` used `Get-FileHash` to
verify the downloaded zip's checksum, tested successfully with `pwsh` (PowerShell 7 on this
repo's Linux dev sandbox), and then failed on every real Windows CI run with `'Get-FileHash' is
not recognized as the name of a cmdlet, function, script file, or operable program` -- the exact
`CommandNotFoundException` wording, meaning `Get-FileHash`'s module (`Microsoft.PowerShell.Utility`)
was genuinely not auto-loading in that specific invocation context (`run_setup.bat`'s
`for /f "usebackq delims=" %%P in (\`powershell ... -File "helper.ps1" ...\`) do ...` pattern --
i.e. `powershell.exe` spawned as a backtick subshell child of a `for /f` inside `cmd.exe`).
`Test-Path`/`Get-Item` (`Microsoft.PowerShell.Management`) worked fine in the same run, so this is
scoped to `Microsoft.PowerShell.Utility` cmdlets specifically, not module auto-loading in general
-- and it never reproduced under `pwsh`, which does not share Windows PowerShell 5.1's module
discovery behavior, so **local testing with `pwsh` on Linux cannot catch this class of bug**; it
only shows up on a real Windows PowerShell 5.1 CI run. Fixed by replacing `Get-FileHash` with
`[System.Security.Cryptography.SHA256]::Create()` + `[System.IO.File]::OpenRead()`, `Expand-Archive`
with `[System.IO.Compression.ZipFile]::ExtractToDirectory()` (needs
`Add-Type -AssemblyName System.IO.Compression.FileSystem` first), and `Get-Content`/`Set-Content`
with `[System.IO.File]::ReadAllText()`/`WriteAllText()` -- all raw .NET API calls with zero
PowerShell module dependency, since `System.Security.Cryptography`/`System.IO`/
`System.IO.Compression` are loaded as part of the CLR itself, not lazily discovered via
`$env:PSModulePath`. Any future embedded `.ps1` helper reached via this same
`for /f`-backtick-subshell pattern should default to .NET types for hashing/archive/file-IO
rather than assuming the equivalent PowerShell cmdlet's module will be available.

**Applied defensively to a second, pre-existing `for /f`-backtick-subshell site with the same
topology: `:conda_base_update`'s timestamp check (run_setup.bat, was CLAUDE.md Active Backlog
item, now closed).** This site was NEVER confirmed to have failed in CI -- it is wrapped in a
`try/catch` that silently defaults to `'update'` on any exception, so a module-autoload failure
here would be masked (an unnecessary conda update), not a crash, unlike the embed tier's
unguarded `Get-FileHash` call. Rewritten anyway on the same principle: `Get-Content -Raw` ->
`[System.IO.File]::ReadAllText(path, [System.Text.Encoding]::ASCII)`, `Test-Path` ->
`[System.IO.File]::Exists(path)`, and -- worth calling out specifically -- `Get-Date` -> `[datetime]::Now`.
`Get-Date` is easy to overlook here: it lives in the exact same `Microsoft.PowerShell.Utility`
module as `Get-FileHash`/`Get-Content`/`Set-Content`, so if the module-autoload gap were ever
triggered at this call site, `Get-Date` would fail identically -- fixing only the
Get-Content/Set-Content calls while leaving `Get-Date` in place would have been an incomplete
fix. All three PowerShell snippets here are inline `-Command "..."` one-liners (not an emitted
`.ps1` file via `:emit_from_base64`), so per the quoting hazard documented elsewhere in this
file, the .NET replacement calls stick to single-quoted PowerShell string literals throughout
(`'...'`) to avoid introducing any literal `"` into the `-Command` body -- confirmed no such
character was added.

**A second, independent bug hid behind the first and only surfaced once diagnostics were added:**
once `Get-FileHash` was replaced, a follow-up local `pwsh` test against the real downloaded zip
showed extraction succeeding but the `._pth` site-imports patch silently NOT applying --
`(Get-Content ...) -replace '^#import site$', 'import site'` (and its .NET-API equivalent using
the same regex) never matched, because the embeddable zip's `._pth` file uses CRLF line endings
and .NET regex `$` in multiline mode matches immediately before `\n`, not before a `\r\n` pair --
the literal `\r` sits between `site` and the match position, so the anchor never lines up. Fixed
by widening the pattern to `'(?m)^#import site\r?$'`. This is the same general CRLF-vs-`$`-anchor
hazard as `.ps1` PayloadSync tests needing CRLF normalization (see "Embedded Helper Update
Workflow" below) but hits at *runtime* instead of test-time -- worth checking for on ANY regex
anchor (`^`/`$`) applied to file content that might carry Windows line endings, not just test
assertions.

**Fail-fast probe window vs. the ~30s hard-kill cap are unrelated numbers, do not conflate them:**
`HP_FAILFAST_PROBE_MS` (default 10000ms, `:run_failfast_probe`) is a CLASSIFICATION checkpoint --
how long to wait before deciding "this exited fast, treat a non-zero rc as a stale artifact" vs.
"this is still running, treat it as the user's real program and never touch it again." The ~30s cap
used by `:run_exe_smokerun`/`:hidden_import_recover` is a FORCE-KILL CEILING for the one run this
bootstrapper is ever allowed to `Kill()` (the fresh-build verification run). The probe's second wait
stage (`$p.WaitForExit()`, no argument) is genuinely unbounded and never kills anything -- raising or
lowering the probe window only changes how quickly a broken cached EXE gets discarded+rebuilt, it
never introduces a new kill point.

**Why the default is 10000ms, not 5000ms (widened 2026-07):** the original 5000ms default was
tuned assuming the probe window only needs to outlast a failing process's own error handling
(instant -- an unhandled exception unwinds in microseconds). It does not: a PyInstaller *onefile*
EXE must first extract its bundled runtime to a temp directory and boot an embedded interpreter
before ANY user code (or its failure) can run at all, and that cold-start step alone is commonly
1-3+ seconds even on an idle machine. Confirmed as the real cause via a CI flake in
`self.failfast.probe.fastfail` (a test whose whole design is a reliably-fast-failing frozen EXE):
identical code produced `discardedAndRebuilt: true` on one CI run and `discardedAndRebuilt: false`
on the very next run of the same commit, with no code change between them -- a pure timing race
between cold-start-plus-failure and the classification window, worsened by a shared CI runner's
CPU/disk contention or a Defender on-access scan of the freshly-extracted EXE/DLLs. Widening the
window is unconditionally safe to do liberally: it is a classification-only value (see above --
never a kill point), so the only cost of widening it is a few extra seconds before a genuinely
broken cached EXE is recognized and rebuilt.

**Accepted gap: most `selfapps_*.ps1` files do not locally pin `HP_CI_LANE`/`HP_NONINTERACTIVE`
around their `run_setup.bat` invocations, so a LOCAL (non-CI) run of one that reaches the fast-path
reuse or no-EXE interpreter dispatch point would take the new interactive fail-fast-probe branch
instead of the plain/legacy branch.** This is a deliberate, low-priority trade-off, not an oversight:
real CI always sets `HP_CI_LANE` at the GitHub Actions job level (`batch-check.yml`,
`HP_CI_LANE: ${{ matrix.mode }}`), and every subprocess (including a PS test script's own
`cmd /c run_setup.bat` child) inherits it automatically -- so CI determinism for `self.fastpath` /
`self.exe.fastpath.graceful` / envsmoke's fast-path assertions is unaffected regardless of what any
individual test file does. Only `tests/selfapps_sysbuild.ps1`, `tests/selfapps_ux_hardening.ps1`,
and the new `tests/selfapps_failfast_probe.ps1` explicitly set `$env:HP_CI_LANE` locally (needed
because those specifically drive consent gates / force the new branch on purpose). If a future
agent wants full local-dev parity with CI for the remaining files, add the same
save/set/restore-`HP_CI_LANE` pattern to whichever ones are found to actually reach the dispatch
point (most single-build-run tests never reach it at all, since `:try_fast_exe` returns immediately
when no cached EXE exists yet) -- but this is optional polish, not a correctness requirement.

---

## `cache` lane Miniconda-corruption handling lives only in `batch-check.yml` YAML comments

The `cache` CI lane restores a Miniconda install from a GitHub Actions cache to skip the ~99 MB
download/install on every run. This mechanism has its own self-healing logic that is easy to miss
because, until this note, it was documented nowhere except inline YAML comments in
`.github/workflows/batch-check.yml` -- a future agent debugging "why did the cache lane skip
everything" should read this instead of re-deriving it from the workflow file.

**Cache key includes the pipreqs version, not just a source hash** (`batch-check.yml:85-87`):
```yaml
key: win-${{ runner.os }}-py311b-conda-${{ hashFiles('run_setup.bat') }}-${{ steps.extract_version.outputs.pipreqs_version }}
restore-keys: |
  win-${{ runner.os }}-py311b-conda-
```
`hashFiles('run_setup.bat')` busts the cache automatically on any bootstrapper edit (no manual
cache-bust needed for source changes); the `pipreqs_version` suffix (extracted via regex from the
`HP_PIPREQS_VERSION` default-assignment line, `batch-check.yml:62-77`) additionally busts it if the
pin ever changes. The `restore-keys` prefix fallback means a stale/partial-match cache can still be
restored even when the primary key misses.

**Three-layer anti-corruption chain, all keyed on a single `HP_CACHE_CORRUPTED` env flag:**
1. *Health check on restore* (`batch-check.yml:89-108`, "Validate restored conda binary"): runs
   `conda.bat info`; on failure, sets `HP_CACHE_CORRUPTED=1` via `GITHUB_ENV` and logs
   `::warning::Conda binary health check failed...; cache corrupted.` The step deliberately
   `exit 0`s regardless ("health check is informational; never fail this step") so a corrupt cache
   doesn't crash the job outright.
2. *Bootstrap-failure fallback* (`batch-check.yml:248-258`, "Catch cache lane bootstrap failure"):
   if `run_setup.bat` itself fails in the cache lane (even with a healthy-looking cache), this ALSO
   sets `HP_CACHE_CORRUPTED=1`.
3. *Skip path*: when `HP_CACHE_CORRUPTED=1` (from either trigger above), later steps write
   placeholder NDJSON rows (`self.cache.corrupted` / `self.cache.bootstrap.failed`, both marked
   `"pass":true`) and skip the rest of the self-test battery for that run -- treating the condition
   as an infrastructure issue, not a product regression. Most subsequent steps are guarded by
   `if: ${{ env.HP_CACHE_CORRUPTED != '1' }}`.

**Save-side guard prevents a "rolling corruption factory"** (`batch-check.yml:1485-1509`): "Validate
Miniconda before cache save" and "Save Miniconda cache" both additionally require
`HP_CACHE_CORRUPTED != '1'` (plus a fresh `conda.bat` presence/health check of their own). This
means a corrupted cache is **never re-saved** -- corruption cannot compound run over run, and the
next run's `restore-keys` fallback will eventually pick up a healthy cache from before the
corruption was introduced (or fall through to a fresh install if none exists).

If you touch any of `batch-check.yml`'s cache-lane steps, preserve this chain: the health check
must stay non-fatal (`exit 0`), `HP_CACHE_CORRUPTED` must gate both the skip-path steps and the
save step, and the cache key must keep including a value that changes whenever the *content* the
cache is keyed on (Miniconda install driven by `run_setup.bat` + the pinned pipreqs version) could
have changed.

---

## Pre-flight py_compile cost on the fast path (accepted, by design)

`:preflight_compile` (REQ-021, run_setup.bat) runs unconditionally on every `:run_entry_smoke`
invocation, including runs that will subsequently take the cached-EXE fast path -- it is not
skipped or gated on `HP_FASTPATH_USED`. This is intentional, not an oversight: it catches an
entry `SyntaxError` before a doomed PyInstaller build even when the cached EXE is about to be
reused. Cost is negligible (single-file byte-compile, ~50ms) relative to the fast path's overall
savings. No action needed; recorded here so it isn't re-flagged as a "missing optimization" later.

---

## `uv add --script` / PEP 723 empirical behavior (shared foundation for two features)

Two features in this repo persist resolved dependencies into a script's PEP 723 header via `uv
add --script`: the automatic, `run_setup.bat`-integrated one (`docs/plan-pep723-writeback.md`) and
the standalone, manual "PVW QuickStart" one (`docs/plan-pvw-quickstart.md`, partially shipped in
README's "PVW QuickStart" section). Both depend on the same empirical facts about `uv`'s real
behavior, established via direct testing across three separate passes (never trusted from
documentation alone) and originally restated in each plan doc's own words. Consolidated here once
instead, per this file's own "standalone fact" categorization principle -- each plan doc now
points back here rather than re-deriving these.

- **`uv add --script` performs a genuine targeted merge, not a rewrite.** Re-adding an
  already-pinned package by its bare name does not downgrade the pin (confirmed: `flask>=2.0`
  survived a bare `flask` re-add byte-for-byte). Adding a mix of already-pinned and genuinely new
  packages in one call preserves every existing pin and adds only the new ones (as bare names, or
  on newer `uv`, an auto-resolved lower bound -- see the version-drift note below). A hand-added
  custom TOML key outside `dependencies`/`requires-python` survives untouched. This is what lets
  both features skip building a hand-rolled TOML differ/merger: feed the full current dependency
  list to `uv add --script` every time and let `uv`'s own merge logic do the rest.
- **Exit code `2` reliably and exclusively means "the header itself is unparseable TOML."**
  Confirmed across every malformed-header test in both features' testing, and confirmed a missing/
  misnamed file does NOT also produce exit 2 (it's exit 1, "script does not exist"), so the signal
  isn't accidentally shared with an unrelated failure class. Both features' malformed-header-repair
  logic is built on this: branch on exit code 2 specifically, not "any nonzero exit," before
  deciding whether stripping the header is safe.
- **A closing `# ///` fence with trailing whitespace fails to parse, exit 2 -- astral-sh/uv#10918.**
  Looks fine to a human, invalid to `uv`'s strict parser. Any header-repair logic must be tolerant
  of this on the STRIP side (match `# ///` followed by optional trailing whitespace, not requiring
  an exact end-of-line) even though `uv` itself won't tolerate it on write.
- **A stray/duplicate leftover fence line can itself become a NEW hard error on newer `uv` --
  astral-sh/uv#19544** ("reject duplicate script metadata blocks," landed ~0.11.17; previously
  silently treated as postlude). This is why header-strip logic should be a line-by-line state
  machine (track an `in_block` boolean, remove the whole block cleanly) rather than a regex that
  could under- or over-match, especially a lazy regex that could leave a stray fence line behind.
- **`VIRTUAL_ENV` set in the calling environment produces only a benign stderr warning, never a
  failure -- astral-sh/uv#15956.** Confirms success/failure must be judged solely by exit code,
  never by the presence of stderr text.
- **An existing `<script>.py.lock` sidecar is silently rewritten as a side effect of `uv add
  --script`, with no flag to suppress it.** Confirmed the exact filename convention
  (`<script-name>.py` -> `<script-name>.py.lock`) via a real lockfile (mtime + content change).
  Any feature that calls `uv add --script` on a file that might have a hand-maintained lock should
  either skip when one exists, or at minimum document that it will be touched.
- **Open caching issue -- astral-sh/uv#15156 ("Cached Script Dependencies Not Properly
  Invalidated").** A sequence of `uv add --script` (change deps) then a later `uv run --script`
  (or ephemeral run) on the SAME filename can serve a stale cached resolution even after the
  header changed; renaming the file "fixes" it, implying the cache key is filename-derived. Hit
  this repo's own testing directly: an early attempt to reproduce a design bug returned a
  misleadingly clean result because of exactly this stale-cache effect, only resolved by using a
  fresh filename and clearing `~/.cache/uv`. Relevant to any feature whose entire point is
  persisting a header for a LATER, independent `uv run` to pick up.
- **`Get-Content -Raw`'s default text handling silently replaces any invalid-UTF-8 byte with the
  Unicode replacement character (`U+FFFD` / `EF BF BD`) the instant it reads a file** -- confirmed
  at the raw byte level, not just visually. For a script saved in a legacy encoding, this corrupts
  an in-memory "original" backup before any risky operation even begins, so a later "restore" can
  silently hand back an altered file. Reading and writing via `[System.IO.File]::ReadAllText`/
  `WriteAllText` with `[System.Text.Encoding]::GetEncoding("ISO-8859-1")` round-trips any file's
  bytes exactly (`ISO-8859-1` maps every byte value to a distinct character 1:1), regardless of
  the file's real encoding -- the fix PVW QuickStart uses for its own retry/restore mutation.
  `plan-pep723-writeback.md`'s automatic feature takes a different, simpler path for the same
  underlying hazard (skip non-UTF-8 files entirely rather than round-tripping), since it never
  needs to mutate-then-possibly-restore the same way QuickStart's live retry does.
- **A genuinely new dependency's written form depends on the `uv` version, not just on whether
  it's new.** `uv` 0.8.17 wrote bare names (`"requests"`); `uv` 0.11.28 wrote an auto-resolved
  lower bound (`"requests>=2.34.2"`) for the identical operation. Neither feature should assume or
  document one specific form -- treat whatever `uv` writes as correct by construction.

None of this is specific to either feature's own design (hook points, dispatch shape, audience) --
that detail stays in each plan doc, with a pointer back here for the underlying `uv` facts.

---

## `autopep723`'s own import-detection is environment-leaky under direct invocation, safe under `uvx`

Discovered while reviewing a user-supplied third-party design proposing to run `autopep723 check`
next to `pipreqs` in `run_setup.bat`'s discovery phase (`docs/plan-autopep723-two-tier.md`). The
third-party document made a blanket claim, backed by an 11-scenario test matrix, that `autopep723
check` "never reports delta" and is "environment-independent" -- i.e. it always reports the
complete set of third-party imports regardless of what's already installed. **This claim is false
as a blanket statement, confirmed by reading `autopep723`'s actual source (pulled from the local
`uv` cache, not guessed at) and by direct reproduction -- but the truth is narrower and still
usable.**

`autopep723`'s `get_builtin_modules()` (the function every one of its commands -- `check`, `add`,
and the default run mode -- calls before filtering "third-party" from "already accounted for")
does `set(sys.builtin_module_names) | {m.name for m in pkgutil.iter_modules()}`.
`pkgutil.iter_modules()` walks `sys.path` of **whichever Python process is currently running
`autopep723` itself** -- so any package already installed in that process's own environment gets
silently treated as "not third-party" and dropped from the output, even though it's a real
dependency the target script needs.

**Reproduced directly**: a venv with only `requests` pre-installed, running `autopep723 check` on
a script that imports both `requests` and `click`, reported only `click` -- `requests` vanished
from the output with no error, no warning, nothing distinguishing it from "not needed." This is a
real, silent under-report, not a hypothetical.

**But it depends entirely on invocation method, not on the tool being unreliable in general**:
- `uvx autopep723 check <file>` (an isolated `uv`-managed tool venv, recreated/reused per-tool
  rather than sharing the target script's own environment) is **not** fooled by an active
  `VIRTUAL_ENV` env var pointing at a dirty environment -- confirmed directly: with `VIRTUAL_ENV`
  set to a venv that already had `requests` installed, `uvx autopep723 check` still correctly
  reported both `click` and `requests`.
- It **is** still fooled by a leaked `PYTHONPATH` -- confirmed directly: setting `PYTHONPATH` to a
  site-packages directory containing `requests` caused `uvx autopep723 check` to drop `requests`
  from its output, the same silent failure as the direct-invocation case.
- A **direct** interpreter invocation (`python -m ...`, `%HP_PY% -m autopep723`, `conda run python
  -m autopep723`, or any invocation sharing the target script's own populated environment) is
  **not** protected at all -- it reliably reproduces the delta bug for any package already
  installed in that interpreter's site-packages.

**Practical rule**: only ever invoke `autopep723` (any subcommand) via `uvx`, never via a direct/
shared interpreter, and only in a context where `PYTHONPATH` is already known-clear. This repo's
existing `set "PYTHONPATH="` / `set "PYTHONHOME="` near the top of `run_setup.bat` (REQ-010
isolation, runs long before any discovery-phase code) already satisfies the second condition for
any `run_setup.bat`-integrated use of `autopep723`. A design that instead proposes invoking it
directly through a lane's own interpreter (e.g. `conda run python -m autopep723 check` for a
future conda-lane integration) is **not** safe as written and must be revised to keep using `uvx`
even there -- see `docs/plan-autopep723-two-tier.md` for where this correction was applied.

**This also resolves an apparent contradiction, not just a caveat**: a user reported working with
a third party who suspected this exact delta bug, lost the specific reproduction, and could not
tell whether it was a miscommunication. It wasn't -- the bug is real and reproduces reliably, it
just depends on invocation method in a way that made it easy to "fix" by accident (switching from
a direct interpreter to `uvx` between test sessions) without anyone identifying why the behavior
had changed.

**One more confirmed, load-bearing fact from the same source-reading pass**: `autopep723` has zero
runtime dependencies of its own (`Requires-Dist` is empty in its distribution metadata), and is
strictly single-file -- its argument parser (`cli.py`) has no directory, glob, or multi-file mode
at all. Passing a directory (e.g. `.`) to any subcommand hits `Path.read_text()`'s
`IsADirectoryError`, which `get_third_party_imports()` catches and turns into an empty result with
**exit code 0** (not a nonzero failure) -- confirmed directly: `uvx autopep723 check .` prints an
error to stderr but still emits a valid, empty `# /// script ... # ///` block and exits clean. Any
design invoking `autopep723` against `run_setup.bat`'s app directory as a whole (rather than the
specific resolved entry file, e.g. `%HP_ENTRY%`) will silently produce zero discovered
dependencies on every run, with no error signal a caller could branch on.
