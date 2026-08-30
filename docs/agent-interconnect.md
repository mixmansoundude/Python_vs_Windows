# Agent Interconnectedness Map -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-interconnect.md`
import in CLAUDE.md. It documents the non-obvious cross-component dependencies that
future agents must understand to avoid re-introducing known failures.

Standalone hazards, rules, budgets, and procedures (batch/CMD quirks, the CMD `set` line
limit, the embedded-helper workflow, the ambient-Python lesson, etc.) live in
`docs/agent-lessons-learned.md`.

**Categorization principle:** interconnect = a dependency between two or more components
such that changing one requires understanding the other ("touch A, must understand B"). A
standalone discovered fact, hazard, budget, or procedure belongs in
`docs/agent-lessons-learned.md` instead.

**AGENT DIRECTIVE: When you discover a new interconnect or correct an existing one, update
this file immediately in the SAME commit (edit existing entries, do not only append). Keep
`docs/agent-lessons-learned.md` current too. The map must stay accurate.**

**This file is not human-facing prose -- it is loaded into every agent session via CLAUDE.md's
`@` import.** Every entry below is distilled to CURRENT-STATE facts: the rule, the mechanism, the
variable/subroutine relationship a future edit must respect. The "how we found this out" -- which
review round caught it, which fix attempt was wrong first, exact commit/run IDs -- lives in
`docs/agent-closed-backlog.md`'s "Interconnect Narrative Archive" section (read on demand). Do not
re-inflate an entry with discovery narrative when editing it; add the rule here and, if the
provenance is worth keeping, a compressed note there instead.

---

## `:define_helper_payloads` must be `call`ed before ANY subroutine using an `HP_*` payload

Every `HP_*` payload variable (~30 as of this writing) is `set` inside `:define_helper_payloads`'s
own body. `:emit_from_base64`, the shared decoder every payload consumer calls, reads the payload
via `Get-Item Env:$varName` -- if the caller's `set` line hasn't executed yet, this returns nothing
and `:emit_from_base64` silently `exit 1`s WITHOUT writing the target file, so the caller's own
`powershell -File "<target>.ps1"` fails with `The argument '<target>.ps1' ... does not exist.`

A subroutine's `:label` position in the file is IRRELEVANT -- only the RUNTIME ORDER of `call`
statements in the main flow matters. `call :define_helper_payloads` runs as one of the first two
things the main flow does (immediately before `call :merge_git_config`), specifically because
`:merge_git_config` is called earlier than almost everything else and now uses a payload
(`HP_MIGRATE_GITATTRIBUTES`, Item 60). **Before adding a new early `call` to the main flow, or
wiring a new payload into an already-early-called subroutine, verify `:define_helper_payloads` is
still called before it.** No automated test guards this ordering (`*.PayloadSync` tests only prove
byte-equality of the embedded base64, not reachability-in-time) -- a dedicated ordering guard is a
plausible future addition. (History: `docs/agent-closed-backlog.md`, CLAUDE.md Item 60 / PR #455.)

---

## Concurrent-instance lock (REQ-024) touches every exit path

The lock (`:acquire_lock`/`:lock_is_stale`/`:release_lock`) is released only at `:die` and
`:success`, not at every one of the file's ~100 `exit /b` sites. **Correctness is age-based
staleness, not proven release-path coverage** -- CMD has no `finally`/`trap`, so depending on
proving every exit path releases the lock is the wrong shape (Ctrl+C, a kill, power loss all
bypass any release hook regardless). The `:die`/`:success` hooks are an optimization (avoid a
stale lock for up to ~2h after an ordinary run), not the guarantee. Both are confirmed universal
funnels for the normal flow: every `call`-based consent-gate decline returns up its call chain and
continues rather than terminating directly, and the EXE fast path's early-success shortcut also
funnels through `:success`. The few pre-label `exit /b 1` sites (workspace-path-invalid guards, near
top of file) execute before the lock is acquired, so need no release call.

**`tools/audit_batch_exit_paths.py`** (not wired into CI, run by hand) inventories every label/
call/exit site and whether each label is ever `call`ed -- deliberately not a full paren-aware CFG
proof (a `called=False` result is "a hint, not proof" per its own docstring; a true parenthesized-
`if`-block-aware CFG parser was assessed as disproportionate effort). Starting point for a future
exit-path audit, not a final answer.

**Rule for a new top-level (non-`call`ed) `exit /b` site**: if reachable with an empty call stack
AND is a routine exit a real user could hit often (not a crash), add `call :release_lock` before
it -- same as `:die`/`:success` -- so a repeated-decline pattern doesn't leave stale locks.

---

## `:emit_from_base64`'s test-injection hook covers every future payload automatically

`HP_TEST_FORCE_EMIT_FAIL=<VARNAME>` (checked first, before the real PowerShell write): if defined
and equal to the CALL's own `%VAR%` argument, logs `[TEST]` and `exit /b 1` immediately, simulating
a genuine disk-write/AV-lock failure for that ONE payload without touching any other payload
emitted in the same run. REQ-019-compliant (absence changes nothing). Any future new embedded
helper automatically inherits this same test-injection capability with zero extra wiring.

---

## AV-Safe Build Path Tier A (`:try_nuitka_tier_a`) and hidden-import auto-recovery

**Touch either subroutine, must understand the other.** `:try_nuitka_tier_a` (Nuitka fallback when
PyInstaller's build fails) sets `HP_NUITKA_FALLBACK_USED=1` on success, and `dist\<env>.exe`
becomes a Nuitka-produced binary. `:hidden_import_recover`'s repair action is PyInstaller-specific
(`--hidden-import=X`), which does not apply to a Nuitka-built EXE. **Rule: any subroutine that can
build `dist\<env>.exe` via something other than PyInstaller must set an analogous marker, and
`:hidden_import_recover` (plus any sibling repair loop) must check it and skip (not attempt-and-
fail) when set.** Both `:hidden_import_recover` and `:dll_bundle_recover` (below) carry this guard
today, right after their own early-return checks. The warnfix-triggered rebuild (a second
PyInstaller rebuild call site) clears `HP_NUITKA_FALLBACK_USED` on its own success, since it always
uses PyInstaller -- if the EXE it just replaced was Nuitka-built, the flag must reflect the new
reality or the guard above would wrongly keep skipping repair.

**`:hidden_import_recover` pairs `--collect-submodules=X` with every `--hidden-import=X` it adds**
(accumulator `HP_PYI_HID_COLLECT`, mirrors `HP_PYI_HIDDEN_IMPORTS`'s accumulate-then-inject shape).
A `--hidden-import=X` target alone only guarantees PyInstaller follows what `X`'s own `__init__.py`
statically imports -- not every real submodule under `X/`, which a compiled C extension elsewhere
in the app can still need. Broader than strictly necessary but structurally safe: `X` is already
`find_spec`-confirmed installed by `~hidden_import_scan.py`'s own strict gate (see
`docs/agent-lessons-learned.md`'s "--hidden-import auto-recovery must stay STRICT" entry -- this
change doesn't touch what triggers that gate, only what happens once it fires). The
`[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=X` log line now also appends
`--collect-submodules=X` -- every existing consumer matches it as a PREFIX/substring, so this is
non-breaking; re-verify that holds for any future change to this log line.

(History of the two "no guard existed at all" bugs that motivated this section, and the exact CI
runs that confirmed each fix: `docs/agent-closed-backlog.md`.)

---

## Conda native-DLL bundling repair loop (`:dll_bundle_recover`, CLAUDE.md Item 24) and its two siblings

**Touch any of the three PyInstaller repair loops (`:dll_bundle_recover`, `:hidden_import_recover`,
the warnfix per-module rebuild), must understand how they chain.** `:dll_bundle_recover` repairs a
DIFFERENT failure class than `:hidden_import_recover`: a conda-installed native extension's `.pyd`
depends on a shared DLL under the env's `Library\bin` (e.g. `eccodes.dll` for `pygrib`) that
PyInstaller bundles the `.pyd` for but never discovers the DLL dependency of -- a
missing-native-library failure, not a missing-Python-module one, so `:hidden_import_recover`'s
strict `ModuleNotFoundError`-only gate correctly never fires for it.

**Detects at BUILD time** (reacts to PyInstaller's own build-log warning, `WARNING: Library not
found: could not resolve 'X.dll'...`), called from `:run_entry_smoke` right before
`:run_exe_smokerun` -- one guaranteed-failing verification cycle earlier than a runtime-only design
could. `HP_LOG_SIZE_BEFORE` (a byte-offset snapshot taken right before the fresh-build attempt)
scopes the scan to THIS build's own log output, since `%LOG%` persists across runs in the same app
directory.

**Detection runs first and UNCONDITIONALLY, independent of provider/Nuitka.** `next_dll_target()`
(`tools/dll_bundle_scan.py`, `HP_DLL_BUNDLE_SCAN`) parses whatever DLL name PyInstaller's own
warning names via regex (general, not hardcoded to `eccodes.dll`) -- `locate_dll()` requires the
named DLL to actually exist under the conda env's `Library\bin` (searched recursively) before
emitting anything. The actual BUNDLING action (Requirement 3) is gated on `HP_ENV_MODE=conda` (no
`Library\bin` convention elsewhere) and on `HP_NUITKA_FALLBACK_USED` being unset (same reasoning as
the hidden-import guard above) -- but detection itself always runs and always logs, so the
caveat-panel "detected, repair skipped" state (see below) is honest in both non-actionable cases.

**Tried-list is a FILE** (`~dll_bundle_tried.txt`, appended via `type ... >>`), never inline argv --
a DLL basename can legally contain a space or a cmd.exe metacharacter, which would corrupt an
unquoted inline accumulator. `tools/dll_bundle_scan.py`'s `read_tried_file()` parses it back. `main()`
continues past a named-but-not-on-disk candidate to the next one in the same log, rather than
stalling the whole loop on one stale/irrelevant warning.

**Outcome bookkeeping, the load-bearing state variables:**
- `HP_DLL_FAILED` -- set only on a genuine rebuild failure (PyInstaller errorlevel, or a missing
  post-rebuild EXE); gates whether the "bundling complete" line/state can ever fire on a failure.
  Also sets `HP_BOOTSTRAP_STATE=error` (mirrors the warnfix-rebuild's own "conservative response to
  failure" precedent). The smoke run afterward still runs regardless (see "Single-verification
  smoke model" below).
- `HP_DLL_EXHAUSTED` -- set when a real, locatable candidate DLL is found AFTER the 3-iteration cap
  is already hit, so it is correctly reported as `exhausted` (a distinct, `pass:true` NDJSON state)
  rather than being silently discarded and misreported as a clean `repaired`.
- `HP_DLL_REPAIRED` -- reset at the very top of `:dll_bundle_recover` (before ANY early-return),
  set ONLY in the genuine "repaired" branch. This is the caller's own per-call signal for "did THIS
  call actually bundle something" -- deliberately NOT `HP_DLL_ITER` (which is reset partway through
  the subroutine and would read stale/nonzero on a second call that found nothing new).
- `HP_DLL_HINT_STATE` -- set by `:emit_dll_bundle_row` BEFORE its own `HP_NDJSON`-gated early
  return (so the postflight caveat hint works even with NDJSON disabled), survives past the
  subroutine returning (NOT cleared at `:dll_bundle_recover_exit`, unlike `HP_DLL_FAILED`/
  `HP_DLL_EXHAUSTED`), and drives `:pfb_dll_hint`'s 3-bucket wording dispatch (never-attempted /
  attempted-but-incomplete / repaired-but-something-else-still-wrong). Reset once per fresh build
  attempt, same as `HP_DEP_MAYBE_INCOMPLETE`/`HP_PYI_DLLBIND`, so a tier that never calls
  `:dll_bundle_recover` this run doesn't inherit a stale hint from an earlier cascaded-away tier.

**Cross-tier/cross-pass state-leak resets are consolidated in `:run_entry_smoke`'s init block, NOT
inside `:dll_bundle_recover`/`:hidden_import_recover` themselves.** `HP_PYI_DLLBIND` (the
accumulated `--add-binary` flags) and `HP_PYI_HIDDEN_IMPORTS`/`HP_PYI_HID_COLLECT` must each be
reset EXACTLY ONCE per fresh build attempt, not once per subroutine call -- since
`:dll_bundle_recover` now runs a SECOND time per build (see below), resetting inside the subroutine
itself would wipe an earlier pass's already-accumulated flags before a later rebuild could use
them. Every rebuild command in this build lifecycle (`:dll_bundle_recover`'s own, and
`:hidden_import_recover`'s own) must thread ALL of `%HP_PYI_EXPAT% %HP_PYI_COLLECT%
%HP_PYI_DLLBIND% %HP_PYI_HIDDEN_IMPORTS% %HP_PYI_HID_COLLECT%` -- any future repair loop added to
this lifecycle must thread its own accumulated flags through every later rebuild the same way, or
an earlier loop's fix is silently discarded by a later one's rebuild.

**`:dll_bundle_recover` runs a SECOND time per fresh build, after `:hidden_import_recover`'s own
loop finishes** (`:run_exe_smokerun`'s flow calls it again there) -- a `--collect-submodules=X`
hidden-import fix can pull a package's compiled extensions into the bundle for the FIRST time,
surfacing a native-DLL warning that never existed in any earlier build (confirmed via a real
`pyproj`/`proj_9.dll` case). If that second call actually bundles something (`HP_DLL_REPAIRED=1`),
`:hidden_import_recover` gets one more bounded pass too (gated on a matching `HP_HIDDEN_REPAIRED`
flag, same reset-at-entry-before-any-early-return shape as `HP_DLL_REPAIRED`).
`:hidden_import_recover`'s own rebuild also re-snapshots `HP_LOG_SIZE_BEFORE` immediately before
its call, narrowing each pass's own scan window to just the freshest rebuild's output. **Bounded to
exactly one extra round of each subroutine, never a further interleave** -- a case needing more
than this is its own future backlog item, not solved speculatively here. The caller's own early
`if "%HP_EXE_EXIT%"=="0" goto :smokerun_ok` (previously placed right after the FIRST
`:hidden_import_recover` call) was removed -- it could skip the entire second-pass block whenever
the first call's rebuild happened to already exit 0, defeating build-time DLL detection for exactly
the case this feature exists to catch (a smoke run passing today doesn't mean the build log has
nothing left to flag for a different code path later).

**`HP_PY_DIR` (`%~dpI`, always ends in exactly one trailing backslash) must be passed as
`HP_PY_DIR_ARG` (one extra backslash appended) when immediately followed by another quoted
argument** on `~dll_bundle_scan.py`'s own command line -- an odd trailing-backslash count before a
closing quote escapes the quote instead of closing it (see `docs/agent-lessons-learned.md`'s
"single trailing backslash" entry for the general Windows-argv rule this is one instance of).
Getting this wrong makes `locate_dll()` always report "could not locate" even when the DLL is
genuinely present, since the corrupted path fails `os.path.isdir()`.

**`HP_DLL_DETECTED`/`HP_NEXT_DLL`/`HP_NEXT_DLL_PATH` need SANITIZED copies for `:log`'s own
unquoted echo and the `call`-triggered second-expansion-pass hazard** (`_SAFE` variants, computed
by the real emitted file `tools/dll_pct_sanitize.ps1`, `HP_DLL_PCT_SANITIZE` -- NOT cmd.exe
`:search=replace` substitution, which cannot reliably strip a literal `%`/`^`; see
`docs/agent-lessons-learned.md`'s "`:log` echoes UNQUOTED" entry for the full mechanism and why
this needed three attempts to get right). Every FUNCTIONAL use of the raw value (the tried-file
byte-copy, the quoted `--add-binary` argument) is untouched -- only `:log` calls use the sanitized
copies, so tried-list dedup matching is unaffected.

Every outcome of this loop (`skipped_nuitka`/`skipped_non_conda`/`repaired`/`unlocatable`/
`exhausted`/`failed_rebuild`/`failed_missing_exe`) is emitted as NDJSON id `self.dll_bundle.recover`
via `:emit_dll_bundle_row` -- see `docs/agent-ndjson.md` for the full field schema. Any future
repair loop's outcome points need the same treatment: a `call`ed emitter subroutine plus a
registered NDJSON row.

**`self.layered_e2e.chain` (`tests/selfapps_layered_e2e.ps1`) is this loop's regression test**,
proving all 4 mechanisms (REQ-009 cascade, warnfix repair, hidden-import recovery, DLL bundling)
fire together for real via a genuine `pygrib`/`eccodes.dll`/`pyproj`/`proj_9.dll` chain --
`chainPass` confirmed `true` via real CI (PR #421, `cache`-lane run `31264219121`).

(Full bug-by-bug history -- 9+ distinct real bugs found via CodeRabbit review rounds and live CI,
each with its own wrong-first-attempt trace -- lives in `docs/agent-closed-backlog.md`'s
Interconnect Narrative Archive, filed under Items 24/25/28/29.)

---

## AV-Safe Build Path requirement 9 (`:offer_optimized_build`) -- a strictly safer sibling of Tier A

**Shares `:try_nuitka_tier_a`'s Nuitka invocation but NOT its "delete first, build second" safety
posture.** Tier A runs only after PyInstaller already failed, so deleting the old EXE first is
free. `:offer_optimized_build` (called from `:smokerun_ndjson` right after
`call :run_postexec_checkpoint exe`) runs in the OPPOSITE situation: the existing EXE already
passed verification. It builds to a distinct temp name (`%ENVNAME%.optimized_build.exe`), runs its
own internal 30s-capped verification launch against that temp file, and only on CONFIRMED
build-and-run success does `move /y` swap it over the original. Every failure branch
(`goto :optbuild_cleanup`) deletes only the temp file, leaving the original untouched.

**Post-swap verification checks whether the SOURCE (temp file) is gone, not whether the
destination exists** -- the destination (the already-working original) exists before the move
regardless of outcome, so checking it can never detect a failed swap. A same-volume FILE `move /y`
onto an existing destination is atomic (fully replaces or fully fails, source consumed only on
success) -- see `docs/agent-lessons-learned.md`'s "Windows `move` onto an existing destination"
entry for why this file-move reasoning does NOT transfer to a directory swap (the embed tier's own
`:embed_swap_retry` needed a different fix for exactly that reason).

**Gated on the SAME `HP_NUITKA_FALLBACK_USED` flag Tier A sets, for the opposite reason**: Tier A's
guard checks it to SKIP a PyInstaller-only repair against a Nuitka EXE; this subroutine checks it
to skip OFFERING THE PROMPT AT ALL when Tier A already ran (the user already has an optimized-ish
build). On its own success it also sets `HP_NUITKA_FALLBACK_USED=1`.

**Cascade re-entry can offer this prompt more than once per bootstrap** -- called from the same
site as `:run_postexec_checkpoint exe`, so each cascade tier's own verification pass re-offers both
prompts fresh (each tier is a genuinely different build).

**Nuitka auto-detects an installed Visual Studio via the registry** (confirmed against
Nuitka/Nuitka#3317) -- no Developer Command Prompt/`vcvarsall.bat` needed. The hint text
referencing Visual Studio Build Tools is REACTIVE ONLY (shown after a real Nuitka build failure),
never proactive fingerprinting.

Four test scenarios (`tests/selfapps_optimized_build.ps1`, uv lane, non-gating): `accept` (real
build+swap), `forcefail` (original untouched), `swapfail` (forced swap failure, original untouched,
temp cleaned up), `decline` (prompt shown, no build attempted).

---

## Standalone Python-download tier (REQ-009 Tier 5 by naming; executed 3rd in provider order)

**Provider chain: `uv -> conda -> embed -> venv -> system`** (embed sits right after conda, not
last-resort) -- conda and embed both front-load acquisition of a fresh/pinned interpreter; venv/
system wrap whatever's ambient and stay the true last resort (system is absolute final, gated
solely by the REQ-014 consent prompt). Both dispatch mechanisms encode this order:
`:handle_conda_failure` (linear initial fallback) and `:provider_cascade` (goto-based re-entrant
post-warnfix cascade -- see below).

**Mental model: embed behaves like `venv`, not `system`.** Both venv and embed are fully isolated
and bootstrapper-installable (safe to `pip install` into freely); system is shared/minimally-
invasive (installs consent-gated). Wherever code branches system out to a restricted/no-op path,
embed should NOT be excluded the same way.

**Two-stage PowerShell/Python split, not a single script** -- this tier runs before the
bootstrapper has secured any interpreter of its own, so per-request version-table logic cannot live
in Python until SOME interpreter exists on disk (the one this tier itself is extracting).
1. **PowerShell stage** (`tools/embed_extract.ps1`, `HP_EMBED_EXTRACT`) -- checksum verification
   (`[System.Security.Cryptography.SHA256]`, not `Get-FileHash` -- see
   `docs/agent-lessons-learned.md`'s "prefer raw .NET types" entry for why Utility-module cmdlets
   are unsafe in this invocation shape), extraction, and the `._pth` patch (uncomment
   `#import site`, regex `(?m)^#import site\r?$` to survive CRLF). Zero per-request branching.
2. **Python stage** (`tools/embed_pyver_check.py`, `HP_EMBED_PYVER_CHECK`) -- runs under the
   freshly extracted interpreter, reuses the SAME `PYSPEC` value `~detect_python.py` already
   computed. `EMBED_PYTHON_TABLE` maps minor -> `(patch, sha256)` for 3.10-3.14 (5 entries,
   matching python.org's currently-supported non-EOL minors, refreshed quarterly -- see CLAUDE.md's
   "Embed version table" periodic check). The `"3.14"` entry's patch/sha256 MUST match the
   batch-side `HP_EMBED_LATEST_PATCH`/`HP_EMBED_LATEST_SHA256` exactly --
   `tests/test_embed_tier.py`'s `BatchPythonConsistency` test enforces this.
3. **Windows self-file-lock**: the Python stage runs FROM `HP_EMBED_DIR` itself, so a version-swap
   extraction happens into a SIBLING staging directory (`HP_EMBED_DIR` + `_swap`); the actual swap
   (`rd /s /q` old + `move /y` new-into-place) happens in the BATCH caller, only after the Python
   process has fully exited and released its locks.
4. **`:embed_swap_retry` gates `move` on `rd` having genuinely cleared the destination first**
   (`if exist "%HP_EMBED_DIR%" goto :embed_swap_rd_failed`, skip `move` entirely) -- a directory
   `move` onto a still-existing destination silently NESTS the source inside it rather than failing
   cleanly, so a post-hoc "does it exist now" check cannot detect a failed `rd`. **NOT CI-confirmed**
   (`self.embed.fallback.real` never requests a non-default version through this path) -- static
   reasoning about documented Windows semantics only.

**Version selection is a small pinned table, never a live python.org scrape** (same "deterministic
execution > dynamic resolution" principle as the pipreqs 0.4.13 pin). Integrity via embedded SHA256
computed once at pin-time, never fetched over the same network path as the download.

**Offline-mode test-flag exception touches two call sites**: `HP_TEST_FORCE_EMBED_REAL=1` punches a
hole through `HP_OFFLINE_MODE=1` at both `:try_embed_fallback`'s own check AND
`:download_get_pip` (reused from REQ-023b) via an intermediate `HP_GETPIP_SKIP_OFFLINE` OR
variable. A future third test flag needing `:download_get_pip`'s real download must extend both.

**Call sites** (all four wired to `embed`): `:handle_conda_failure` (initial chain, right after
conda), `:provider_cascade`'s dispatch (`:cascade_from_conda` targets `:try_embed_fallback`,
`HP_CASCADE_TRIED_EMBED` guard; `:cascade_from_embed` targets `:try_venv_fallback`), the new
`:try_embed_fallback` subroutine itself (on success: `HP_ENV_MODE=embed`, `HP_PY=<extracted
pythonXY.exe>`, `HP_BOOTSTRAP_STATE=embed_env`, leaves `HP_SKIP_PIPREQS` UNSET like venv), and the
dependency-install dispatch in `:after_env_mode_selection` (an explicit `embed` branch was added
before the system-only catch-all, or embed would silently get zero installed deps).

**Warnfix's repair-install dispatch has explicit `venv`/`embed` branches** (each a plain
`"%HP_PY%" -m pip install %%M`) plus a `system`-mode catch-all that stays a no-op but now logs
`[WARN] System fallback: skipping warnfix repair installation.` -- previously venv/embed/system all
silently no-opped while still logging as if the repair succeeded (CLAUDE.md's former Item 36).
Regression: `tests/selfapps_warnfix_venv_repair.ps1` (uv lane, non-gating) proves the venv branch
genuinely installs, not just that the EXE eventually builds.

---

## uv-First Provider Architecture

### Provider selection flow

```
HP_FORCE_CONDA_ONLY=1 -> always go through Miniconda; uv never tried as primary
HP_TEST_FORCE_UV_FAIL=1 -> fires before the cached-uv check; uv never used
HP_UV_PROVIDING_PYTHON=1 -> set when uv successfully detects Python; gates Miniconda skip
```

When `HP_UV_PROVIDING_PYTHON=1`: Miniconda is not downloaded/installed; `CONDA_BAT` is never set;
all conda-dependent paths (including the corruption check) are bypassed.

### Provider cascade execution re-enters env-create (REQ-009/REQ-005.10 slice 3)

`:provider_cascade` (reached via `if defined HP_CASCADE_APPROVED goto :provider_cascade`) reuses
the existing env-create paths rather than reimplementing them:
- `uv -> conda`: `HP_ENV_MODE=conda`, `ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%`,
  `goto :try_conda_create`. `:cascade_acquire_conda` downloads+installs Miniconda on demand if the
  uv-first run skipped it.
- `conda -> embed`, `embed -> venv`, `venv -> system`: each `call`s the matching `:try_*_fallback`
  then `goto :after_env_mode_selection`. System is reached in any run (only gate: the REQ-014
  consent prompt; CI auto-declines via `HP_CI_LANE` unless `HP_TEST_SYSCON_ANSWER=Y`). System has
  no cascade target of its own -- terminal.

**No-loop guarantee**: each tier is marked `HP_CASCADE_TRIED_<tier>` on first use as a cascade
source; `HP_ENV_MODE` only ever advances (uv->conda->embed->venv->system). A new provider or
reordering must add a matching guard and keep the order monotonic.

**`:after_env_mode_selection` must stay safe to re-enter** (recomputes REQ/DEP_SOURCE/entry/
pyproject state from scratch every time) -- the EXE fast path is NOT re-run on cascade, and
`:run_entry_smoke`'s rebuild-skip is gated on `HP_FASTPATH_USED` (unset on a fresh build), so the
next tier genuinely rebuilds. Any new first-run-only state added here must be made idempotent.

**`runtime.txt` write-back (REQ-004) can poison a cascade re-entry with an unsatisfiable exact
pin.** Write-back fires the moment ANY provider's env setup succeeds, writing the EXACT patch
version that provider reports and reassigning `PYSPEC` to match. Since `:after_env_mode_selection`
recomputes `PYSPEC` fresh on every cascade tier, a LATER provider's own env-create call can receive
an EARLIER provider's exact patch pin verbatim (e.g. uv's `python-3.14.7` forwarded to
`conda create ... python=3.14.7` when conda-forge's own release cadence never shipped that exact
patch) -- confirmed as the real cause of a cascade dead-end via real CI (CLAUDE.md Item 24).
**Fix**: `HP_PYSPEC_WRITEBACK` (set at all 3 write-back sites) signals "the in-memory `PYSPEC` is
now write-back-derived, do not forward it across a cascade." `HP_PYSPEC_ORIGINAL` (snapshotted
immediately before each write-back reassignment) preserves a genuine user-authored pyproject/PEP
723 range so it still reaches a cascade target's solver, rather than unconditionally dropping to
"no constraint." `:try_conda_create` computes `HP_CONDA_PYSPEC_USE` (`%PYSPEC%` normally,
`%HP_PYSPEC_ORIGINAL%` when `HP_PYSPEC_WRITEBACK` is defined) and MUST use it quoted
(`"%HP_CONDA_PYSPEC_USE%"`) at both `conda create` call sites -- a PEP 440 range containing live
`<`/`>` corrupts an unquoted cmd.exe command line. Base drop-to-unconstrained behavior confirmed
via real CI (`self.layered_e2e.chain`'s `pinDropped:true`); the `HP_PYSPEC_ORIGINAL`
range-preservation path itself remains unconfirmed by a real range-constrained cascade run.

**Embed's own PYSPEC-driven version lookup is NOT (yet) given the same treatment** -- its table
lookup already degrades gracefully (falls back to oldest/newest with a WARN) rather than hard-
failing on an unresolvable exact pin the way conda's solver does. Revisit only if a real run shows
this actually misbehaving for embed specifically.

### Genuine (non-cascade) conda-create exhaustion also falls through `:conda_create_done`

Distinct from the cascade re-entry above (`HP_CASCADE_SAVED_PY` undefined here): a GENUINE FIRST
ATTEMPT where `:handle_conda_failure`'s entire embed/venv/system chain has already been tried and
failed. `:conda_create_failed`'s `call :die` now `goto`s straight to `:after_env_mode_selection`
instead of falling through into `:conda_create_done`'s body (which used to unconditionally set
`HP_PY` to a never-created path, re-detect that, and call `:handle_conda_failure` A SECOND TIME --
replaying the embed/venv attempts and the REQ-014 consent prompt twice for one real user).

**Does NOT reduce total pause count to one.** `:after_env_mode_selection` has its OWN
`if not defined HP_PY (...)` check a few dozen lines below its label, which now fires instead
(`HP_PY` is genuinely undefined post-fix) -- the fix relocates pause #2 to an already-precedented
site, it does not eliminate it. A further slice targeting that check is the natural next step if
reducing to one pause is ever pursued.

### Batch 1 (Item 46 Bucket A): the conda-acquisition-probe chain collapses the same way

Sibling fix, one step earlier in the acquisition flow: 5 chained sites (`conda.bat not found after
bootstrap`, `where conda`/`where python`/`python -V` not-found, `Conda not found at:`) all shared
one root cause and could previously stack 4-5 back-to-back `[ERROR]`/pause pairs before finally
reaching `:try_conda_create` and dying there too. Each of the 5 `call :die` lines now also
`goto :after_env_mode_selection`. **Same limitation as above** -- collapses worst-case 5-6 stacked
pauses down to 2 (the first specific site, plus the same `:after_env_mode_selection` sink), not 1.
`:try_conda_install`'s own two failure sites (`:tci_both_failed`, Batch 6, not yet fixed) fall
through INTO this chain's own top as their caller resumes -- Batch 1 already shrinks Batch 6's
remaining blast radius as a side effect (confirmed via `tests/selfapps_conda_bothfail.ps1`). A
second, independent `:try_conda_install` call site (`:cascade_acquire_conda`, the REQ-009 cascade's
own on-demand Miniconda acquisition) does NOT re-enter this chain at all -- its own fall-through
proceeds fairly directly to a conda-create attempt that already `goto`s correctly.

### A future `:die`-halts-the-process change must respect one specific existing test contract

Two INDEPENDENT "exit code" signals exist: the real OS-level process exit code (currently always 0
for nearly every `:die` site, since most fall through to `:success`'s unconditional `exit /b 0`)
and the self-reported `exitCode` JSON field in `~bootstrap.status.json` (from `:write_status`'s
`%RC%` argument, entirely independent of the first). A hypothetical future change making `:die`
itself halt the process (drop `/b`) would start reflecting `%RC%` in the real exit code for the
first time. A full sweep (2026-08-18) found exactly ONE currently-gating test that hard-asserts the
OLD always-0 behavior as its own pass condition:
`tests/selfapps_entrysmoke_no_interpreter.ps1:171`, `($statusState -eq 'error') -and ($runExit -eq
0)`. Every other similarly-shaped assertion pairs with a success/recovery scenario where `:die` is
never reached, so is unaffected. **Anyone implementing this change must update this one test's
contract deliberately** (or justify exempting it) rather than discover the breakage via a red CI
run -- and re-sweep for any NEW such assertion added since 2026-08-18. Note: `:die` already
`pause`s before its `exit /b`, so the commonly-cited risk ("closes the console before a real user
reads the message") does not actually apply to converting it to a bare `exit` -- the pause already
runs first on the real-interactive-user path.

### uv uses managed-only CPython (`UV_PYTHON_PREFERENCE=only-managed`)

Set at the top of the uv acquisition block; every uv command in the process inherits it, so uv
never selects an ambient/system/conda interpreter. A user `runtime.txt`/`pyproject.toml` constraint
is still forwarded via `uv venv --python X.Y`. See `docs/agent-lessons-learned.md`'s "Ambient
Python path leakage" entry for why this exists and the companion "target modern, degrade
gracefully" rule for embedded helpers.

### Lanes and their conda state

| Lane | HP_FORCE_CONDA_ONLY | uv used | Miniconda installed | CONDA_BAT set |
|------|---------------------|---------|---------------------|---------------|
| conda-full | 1 | no | yes | yes |
| real | not set | yes (uv-first) | no | no |
| cache | not set | yes (uv-first) | maybe (cached) | maybe |
| justme-test | not set | no (HP_TEST_FORCE_UV_FAIL=1) | via JustMe | yes |
| contract-uv | not set | yes (forced) | no | no |
| uv-dl-fallback | not set | yes (forces primary URL fail, fallback used) | no | no |

### Test files that assume conda is present -- `skip=true` pattern required

Only 3 files call `Get-CondaBatPath` directly and need the guard: `selfapps_reqspec.ps1`,
`selfapps_pyproject_precedence.ps1`, `selftest.ps1` (its `self.corrupt.conda.*` rows),
`selfapps_pandas_excel.ps1` (all 6 rows). All emit `skip=true` when `HP_FORCE_CONDA_ONLY != '1'`
and conda is absent, and real failures when `HP_FORCE_CONDA_ONLY == '1'`. Every other selfapps file
either runs the full bootstrapper (uv/conda split handled internally) or is restricted to
`conda-full` by CI wiring alone (`selfapps_skiphooks.ps1`, `selfapps_pandas_excel.ps1`) rather than
needing its own guard. Template:

```powershell
if ($env:HP_FORCE_CONDA_ONLY -ne '1') {
    $myPass = $true
    $myDetails.skip = $true
    $myDetails.reason = 'conda-not-installed-uv-first'
} else {
    $myDetails.reason = "conda python missing: $condaPython"
}
```

### EXE fast path vs env-state fast path vs uv venv reuse

| Fast path | Trigger | Log line | Lane |
|-----------|---------|----------|------|
| EXE fast path (`:try_fast_exe`) | `dist\<ENVNAME>.exe` exists AND hash check = "fresh" | `Fast path: reusing ...` (non-interactive) or the interactive launch line | All lanes |
| Env-state fast path (`:env_state_fast_path`) | `~env.state.json` valid, conda env python.exe present | `Env-state fast path: reusing conda env ...` | conda mode only |
| uv venv reuse | `.uv_env\Scripts\python.exe` exists AND `import pip` succeeds | `uv: reusing existing .uv_env` | uv mode only |

**Critical order**: EXE fast path runs at the top of the file, BEFORE provider selection -- if it
fires, uv/conda logic is never reached. The env-state check and uv venv reuse only matter on a
first run or when sources changed.

**`HP_FAST_CHECK`'s freshness signal is content-hash, not mtime** (CLAUDE.md's former Item 39):
`:try_fast_exe` compares a stored `~fast_check.hash.txt` against a composite SHA256 over the
non-infra `*.py` files plus `requirements.txt`/`pyproject.toml`/`runtime.txt`. The write side is
`:write_fast_hash` (a separate subroutine, called from `:success`), gated on `HP_FRESH_BUILD_OK`
-- NOT `HP_FASTPATH_USED` (a corrected bug: `HP_FASTPATH_USED` being unset only proves the fast
path wasn't taken, not that a build succeeded; a skipped/failed rebuild leaving a STALE EXE in
place would otherwise get paired with the CURRENT (changed) source hash, making the next run
wrongly trust the stale EXE). `HP_FRESH_BUILD_OK` is reset once per fresh build attempt and set
ONLY in the genuine build-success branches (PyInstaller clean, or Tier A after PyInstaller failed).
A later repair-loop rebuild (`:hidden_import_recover`/`:dll_bundle_recover`) failing does NOT need
to unset it -- those repair bundling issues, not source content, so the initial successful build in
the same run still genuinely reflects the current source. Both the read (`:try_fast_exe`) and write
(`:write_fast_hash`) call sites share one script (`tools/fast_check.ps1`, mode-dispatched), so a
change to file enumeration/hashing logic stays in sync automatically; only a change to the CALL
SITES themselves risks drift.

### `~dependency_installed.txt`: pip freeze output and its consumers

Written after install via `pip freeze` (uv: `uv pip freeze --python "%HP_PY%"`; conda/venv:
`"%HP_PY%" -m pip freeze`). Consumed by `selfapps_pipgap.ps1` (opencv-python check) and copied to
`~environment.lock.txt` in uv mode (the dep-check cache key `~dep_check.py` reads).

### Warnfix install + uv mode

Warnfix's per-module repair loop uses `uv pip install --python "%HP_PY%" %%M` under
`HP_ENV_MODE=uv`, `conda install -y -n "%ENVNAME%"` under conda -- `selfapps_warnfix.ps1` needs no
guard, the bootstrapper handles the split internally.

### autopep723 discovery merge (REQ-005.12, Tier 1)

`:after_pipreqs_run` is inserted immediately after the REQ-005.5 diff-computation log line and
immediately before the dep-check fast-path reset -- re-verify this block still sits between those
two neighbors on any future edit (depends on `requirements.txt` already being finalized by pipreqs,
and must run before `HP_DEP_SKIP`/`HP_DEP_RESULT`/`HP_UV_INSTALL_OK` reset for the fast path).
v1-scoped to `HP_ENV_MODE=uv` only, silently a no-op elsewhere (`HP_UVX_EXE`, derived from
`HP_UV_EXE` not `HP_UV_BIN` -- matters under the `PVW_UV_EXE` override, which never populates
`HP_UV_BIN`). Writes to `requirements.txt` (not `requirements.auto.txt`), so the unconditional pip
gap-fill step picks up anything Tier 1 adds regardless of dep-check fast-path state. Purely
additive merge (`tools/autopep_merge.py`, never removes/reorders existing content) -- a failure
here is non-fatal, the pipreqs-derived `requirements.txt` from earlier in the flow is already
usable.

### `HP_PVW_KNOWN_IDEMPOTENT` execute-mode discovery (REQ-005.13, Tier 2) hooks in earlier than Tier 1

`:pvw_known_idempotent_run` is called right after `:determine_entry` returns, BEFORE the
pyproject.toml/PEP 723/pipreqs block even begins -- Tier 2's premise is "skip static discovery, use
execution instead." `HP_UVX_EXE` is recomputed independently here (Tier 2's gate is earlier in the
file than Tier 1's, so it can't reuse Tier 1's copy). `uv add --script` only updates the PEP 723
header, not `requirements.txt` -- `:extract_pep723_requirements` is reused to re-extract the
just-updated header afterward. Deliberately does NOT set `HP_SKIP_PIPREQS` in production (additive
layering: Tier 2 anchors `requirements.txt`, pipreqs/Tier 1 still get their normal chance
afterward). `tools/pvw_known_idempotent.py`'s `run_script()` leaves the child's stdio fully
inherited (no `capture_output`) and prints its own `RAN:`/`ERROR:` marker to **stderr**, never
stdout, so the user's live script output is never swallowed -- and is bounded by a 120s timeout
(this is a genuine execution of the user's entry script, not a smoke test). Double-execution under
this flag (once here, once later during the real EXE build's verification) is intentional, not a
REQ-018 gap -- the flag's own name is the user's consent. Never gates the lane: any nonzero outcome
just logs `[WARN]` and returns 0.

### PEP 723 write-back (REQ-005.11)

`:pep723_writeback` is v1-scoped to `HP_ENV_MODE=uv` only, called from two sites: `:lock_done`
(fresh-install trigger, `call :pep723_writeback fresh`) and inside the warnfix repair block
(`call :pep723_writeback warnfix`, between the rebuild-complete log line and
`:warnfix_cascade_detect` -- safe from the parse-time-expansion trap because it passes a literal
argument and reads files via runtime `if exist` inside its own call frame). `HP_UV_INSTALL_OK` is
reset in `:after_env_mode_selection`'s existing reset block (same re-entrancy reasoning as
`HP_DEP_SKIP`) and set to 1 in exactly two places: genuine install success, and the
lock-already-satisfied short-circuit. Packages-file staging is a plain `copy` (not a re-derivation)
to `~pep723_pkgs.txt` -- "all-or-nothing per round," since neither trigger point can know which
subset of a failed bulk install actually succeeded. Does not touch venv/conda/embed/system modes at
all -- a future extension needs an `HP_UV_INSTALL_OK`-equivalent per provider plus a matching scope
relaxation in this subroutine's own first line.

### Dep-check + uv mode lock file interconnection

`dep_check.py` runs for both `HP_ENV_MODE=conda` and `HP_ENV_MODE=uv` (skipped for venv/system --
no lock written, no skip check). `~environment.lock.txt` is the cache key either way (conda: `conda
list --export`; uv: copy of `~dependency_installed.txt`). `HP_DEP_SKIP` is honored in uv mode too.

### `HP_TEST_FORCE_UV_FAIL` / `HP_TEST_CORRUPT_UV` interaction

`HP_TEST_FORCE_UV_FAIL=1` fires BEFORE the cached-uv check where `HP_TEST_CORRUPT_UV` fires -- if
both are set, FORCE_UV_FAIL wins. `tests/selftest.ps1`'s corrupt-uv sub-bootstrap
saves/clears/restores `HP_TEST_FORCE_UV_FAIL` so its own branch is reachable in all lanes.

### Malformed `pyproject.toml` + uv venv failure (uv-first lanes)

`uv venv` reads `pyproject.toml` for `requires-python` even without `--python`, so malformed TOML
makes it exit non-zero BEFORE `HP_PYPROJ_DEPS` (which reads the same file via regex, not a TOML
parser, and exits 0/empty on malformed TOML) ever gets a chance to detect and warn. Fix:
`:uv_venv_fail`, when `HP_UV_PROVIDING_PYTHON=1`, retries via `uv run --no-project python -m venv
.uv_env` (bypasses project discovery entirely -- `UV_NO_CONFIG=1` does NOT help, since
`[project]` metadata is still read regardless; only `--no-project` truly bypasses it). On success,
`HP_PYPROJ_DEPS` then naturally detects the malformed TOML on its own normal pass. Regex fallback:
`re.search(r'^\[project\s*$', txt, re.MULTILINE)` (must not assume `tomllib` -- see the embedded-
helper baseline in `docs/agent-lessons-learned.md`).

### `HP_FORCE_CONDA_ONLY` as a test-override pattern

Tests that specifically test CONDA BEHAVIOR set `HP_FORCE_CONDA_ONLY=1` themselves (self-contained,
works in all lanes): `selfapps_pipgap.ps1` (conda bulk fail + pip gap-fill), `selftest.ps1`'s
conda_retry/conda_perpkg blocks. Contrast with tests that merely USE conda as a side effect while
testing something else (reqspec, pyproject_precedence, pandas_excel) -- those emit `skip=true`
instead of forcing a download.

### `HP_UV_BIN` locality

`HP_UV_BIN=%HP_SCRIPT_ROOT%~uv_bin` -- rooted at the bootstrapper's OWN directory, never a
user-global/TEMP path. A test copying `run_setup.bat` into a fresh scratch dir therefore always
gets an empty `~uv_bin`, so combined with `HP_OFFLINE_MODE=1` (blocks re-download), uv is ALWAYS
unavailable in that sub-bootstrap -- this is what makes `selfapps_ux_hardening.ps1`'s fallback-chain
tests (`self.venv.fallback`, `self.ux.system.gate.real`/`.accept`, `self.entry.override`) work
correctly even in uv-first lanes. **Never** change `HP_UV_BIN` to a user-global/TEMP-based path --
it would break this isolation and make sub-bootstrap tests depend on whether the parent job already
downloaded uv. `PVW_UV_EXE` (a super-user override) would also break it, but CI never sets it.

### Lane-specific selfapps notes

- `selfapps_isolation.ps1` (`HP_CI_SKIP_ENV=1`): jumps to `:ci_skip_entry`, uses system Python,
  bypasses provider selection entirely -- lane-agnostic, safe everywhere.
- `selfapps_skiphooks.ps1`: provider-independent by design (no `Get-CondaBatPath` call); restricted
  to `conda-full` only by CI wiring, not by the test's own content.
- `selfapps_pandas_excel.ps1`: wired to `conda-full` only in CI; its own `skip=true` guard is
  defensive dead code under current wiring.

### uv Coverage Status

Covered: `self.contract.uv`/`.pyver`/`.pyver.range`/`.pyver.exactpin` (contract-uv lane -- pyver
tests both an exact pin staying pinned and a loose range resolving to latest-satisfying, not the
floor, via `HP_UV_PY_REQ`/operator-free `HP_UV_PY_DISP`), `self.uv.first.miniconda.skip`,
`self.contract.uv.fail` (contract-uv-fail), `self.uv.managed.interpreter` (all uv-first lanes),
`uv.python.preference.configured` (static), `self.dl.uv.fallback` (justme-test, passes via skip).

**Gap**: the real uv DL-fallback URL path (`HP_TEST_UV_DL_FALLBACK=1`) has no lane exercising it
without also short-circuiting before download is reached.

---

## Single-verification smoke model (REQ-018 2b-A.2)

The bootstrapper runs the user's code for MANDATORY verification exactly ONCE per invocation (the
pre-build interpreter smoke and a second EXE smoke were merged into one; an accepted post-execution
checkpoint can still launch an OPTIONAL second run). Touching this flow requires understanding
`tests/selfapps_envsmoke.ps1`/`selfapps_skiphooks.ps1`, coupled by exact log strings:

- **EXE path = primary verification** (`:run_exe_smokerun`). Emits `[INFO] Running entry script
  smoke test via packaged EXE.` and `[INFO] Entry smoke exit=%HP_EXE_EXIT%`, matching the log
  vocabulary the (now-removed) pre-build interpreter smoke used to emit, and captures EXE
  stdout/stderr to `~run.out.txt`/`~run.err.txt` at the app root. **Runs from the app root now, not
  `dist\`** (CLAUDE.md Item 38, resolved) -- the same CWD `:try_fast_exe`/
  `:verify_no_exe_interpreter` and the interpreter's own run already use, so a CWD-relative-path
  app (e.g. `open("config.json")` next to the script) can no longer disagree between a fresh build
  and a fast-path reuse. Two narrower `pushd dist` sites remain deliberately deferred
  (`:offer_optimized_build`'s internal verify, `:hidden_import_recover`'s diagnostic re-run) --
  each carries its own comment naming the deferral; no test depends on either site's CWD.
  `sys.argv[0]`-relative files (not CWD-relative) still land in `dist\` for a frozen EXE regardless
  of this fix -- an inherent EXE-vs-script difference, not something to normalize.
  If any of this vocabulary/paths changes, `harness.ps1`'s `batch.smoke.single_verify` and
  `self.env.smoke.run`/`self.prime.run`/`self.prime.bootstrap` break.
- **No-EXE path** runs the interpreter ONCE via `:verify_no_exe_interpreter`, UNTIMED on purpose
  (the interpreter run IS the user's real run there, not a throwaway) -- skipped when an EXE
  exists, the fast path ran it, or `HP_SKIP_ENTRY_SMOKE`.
- **skiphooks** (`HP_SKIP_ENTRY_SMOKE` + `HP_SKIP_EXE_SMOKERUN`): both exit before the vocab line,
  so no user code runs.
- The `~run.out.txt` capture reflects the PRE-recovery run (before hidden-import recovery); the
  fail-fast probe's own capture (below) is a separate, pre-truncated write of the same two files.

## Fail-fast probe (Slice 2b-C): shared state machine for the two untimed launch points

`:try_fast_exe` and `:verify_no_exe_interpreter` launch with no timeout in CI (unchanged). For a
real interactive user (`HP_INTERACTIVE_RUN`, or `HP_TEST_FORCE_INTERACTIVE_PROBE=1` for CI
coverage), both call `:run_failfast_probe` instead, via the emitted `~failfast_probe.ps1`
(`HP_FAILFAST_PROBE` -- an emitted file, not inline `-Command`, because the two-stage wait needs
interpolated strings). `WaitForExit(HP_FAILFAST_PROBE_MS)` (default 10000ms -- a classification
checkpoint, unrelated to the separate ~30s hard-kill cap used by `:run_exe_smokerun`/
`:hidden_import_recover`), then, if still running, a SECOND unbounded wait with no `Kill()`.

**Touch either call site, must understand the other, plus the top-of-file success gate:**
- `HP_PROBE_ARGS` is a complete, ready-to-use Arguments string (caller quotes each token;
  `~failfast_probe.ps1` assigns it VERBATIM to `ProcessStartInfo.Arguments`, no extra wrapping).
  CWD matches across all three call sites (`:try_fast_exe`, `:verify_no_exe_interpreter`,
  `:run_exe_smokerun` -- all app root, no `pushd dist`).
- `HP_SMOKE_RC` always ends up the true final exit code; `HP_PROBE_EXCEEDED=1` iff the probe window
  was crossed. `:try_fast_exe`'s discard-and-rebuild is gated on `not "0" AND not
  HP_PROBE_EXCEEDED` -- once classified alive/healthy, a LATER non-zero exit is presumed the user's
  own program outcome, never discarded.
- `HP_FASTPATH_RUN_FAILED` (true only when `HP_SMOKE_RC` is defined and non-"0") gates whether the
  top-of-file fast-path shortcut's `[STATUS]` line shows the true outcome before `goto :success` --
  `HP_BOOTSTRAP_STATE` stays `ok` regardless (a runtime bug in the user's own code isn't fixable by
  a rebuild), but the console must never silently claim success. Both `:try_fast_exe` call sites
  (top-of-file and inside `:run_entry_smoke`'s build gate) carry this guard.
- **cmd.exe parse-time-expansion hazard**: both dispatch sites use `if defined HP_INTERACTIVE_RUN
  goto :<label>_probe`, never a parenthesized if/else around a launch+`%ERRORLEVEL%`-capture
  sequence (see `docs/agent-lessons-learned.md`'s "Provider-cascade dispatch is goto-based on
  purpose" for why the parenthesized form silently freezes `%ERRORLEVEL%` to its pre-block value).
- NDJSON row `self.failfast.probe` carries `details.site` (`fastpath`/`interpreter`/`checkpoint`)
  -- not guaranteed at most once per stream, since the post-execution checkpoint can trigger it a
  second time.

### Live-echo mechanism (both `~failfast_probe.ps1` and `~exe_smokerun.ps1`)

Both helpers live-tee the child's stdout/stderr via chunk-based `StreamReader.ReadAsync(char[],
int, int)` polling (one read in flight per stream, enforcing ordering by construction),
`[Console]::Out.Write($chunk)`/`[Console]::Error.Write($chunk)` (no auto-newline -- chunks land at
arbitrary boundaries), EOF is a 0-length read. Chunk-based (not line-based `ReadLineAsync`)
specifically because Python's `input("prompt")` flushes its prompt WITHOUT a trailing newline; a
line-based reader would leave a live user staring at a blank screen until something else flushed a
line. (Full supersession history -- `Register-ObjectEvent`'s cross-thread reordering bug,
`ReadLineAsync`'s no-trailing-newline blind spot -- lives in `docs/agent-lessons-learned.md`.)

Each helper's own `"$exceeded|$exitcode"` result is written to a DEDICATED file
(`HP_PROBE_RESULT`/`HP_SMOKERUN_RESULT`), never printed as the script's own final stdout line --
capturing that via `for /f` backtick-substitution would swallow every live-teed line into the
result parse. The batch caller invokes each helper DIRECTLY (a plain top-level `powershell -File`
statement, not `for /f`-wrapped) so live output flows straight to the console, then reads the
result file via a separate `for /f` afterward.

`~exe_smokerun.ps1` (`HP_EXE_SMOKERUN`, `tools/exe_smokerun.ps1`) is NOT a reuse of
`~failfast_probe.ps1` -- it is the sole verification pass for a build never confirmed working, so
after `HP_SMOKERUN_KILL_MS` (default 30000, test-only override) it calls `$p.Kill()`, conditionally:

### Activity-aware EXE-smoke kill

`Kill()` fires ONLY if the process has produced ZERO output by the deadline -- any output (even
one chunk, even with no trailing newline) skips the kill for the rest of the run, unbounded,
mirroring the fail-fast probe's "classify once, then never kill" philosophy. "Any output" is the
proxy for "interactive input was likely received," since the parent cannot observe stdin directly
and `input(prompt)` is confirmed to flush before blocking. **Accepted trade-off**: a process that
prints once (a startup banner) and then genuinely deadlocks for an unrelated reason now hangs
indefinitely instead of being caught at 30s -- an explicit owner decision ("if interactive input
was received then extend or stop the timeout... don't change the timeout" otherwise).
`:warn_user_code_launch` takes a `main`/`hidden_import` parameter with different wording per
caller, since `:hidden_import_recover`'s own separate, still-unconditional 30s check is
deliberately NOT migrated to this activity-aware behavior.

### Process-ID display for stuck-program recovery

Both `~exe_smokerun.ps1` and `~failfast_probe.ps1` print `[INFO] Process ID $($p.Id). ... Task
Manager > Details tab > find this PID > End Task ...` right after `Start()` -- `TerminateProcess`
(what End Task calls) targets a single PID directly, unlike `Ctrl+C`/`CTRL_C_EVENT` (rejected:
broadcasts to the WHOLE console process group, would also hit `cmd.exe`/`powershell.exe`). Uses
`Write-Host` deliberately (auto-newline, never captured into the output buffers, so it can't be
mistaken for the user's own program output).

### Argv passthrough (REQ-026, P1)

`HP_APP_ARGS` is captured ONCE at the very top of `run_setup.bat` from `%2`-`%9` (never via
`shift`, since `%~1` is read directly at several later call sites) -- caps the feature at 8 extra
arguments. **`HP_PROBE_ARGS`'s contract is "caller provides a fully-quoted, ready-to-use string,
used VERBATIM"** -- NOT wrapped in an extra pair of quotes by the receiving script (a pre-existing
single-quote-wrap was correct only for one token; wrapping multiple pre-quoted tokens collapses
them into one argv element). Every assignment site must quote/re-quote per this contract:
`:try_fast_exe_probe` (`%HP_APP_ARGS%` alone, EXE is self-contained), `:verify_no_exe_probe`/
`:run_postexec_checkpoint` (`"%HP_ENTRY%"%HP_APP_ARGS%`, entry path re-quoted first). The two
direct (non-probe) legacy branches append `%HP_APP_ARGS%` as ordinary additional quoted tokens.
`tools/exe_smokerun.ps1` needed a NEW variable (`HP_SMOKERUN_ARGS`, no prior `Arguments` handling
at all), same contract.

`:log` must never interpolate `%HP_APP_ARGS%`'s content -- a user argument can legally contain
`<`/`>`/`|`/`&`. The one new log line this feature adds is content-free ("extra launch argument(s)
detected").

`:hidden_import_recover`'s own EXE re-run and the CI-only `HP_CI_SKIP_ENV=1` path deliberately do
NOT receive `HP_APP_ARGS` (a diagnostic re-run of an already-verified build; test infra with no
interactive terminal to benefit). `:offer_optimized_build`'s internal build-verify launch DOES need
it (it launches a brand-new, never-before-executed Nuitka binary) -- but reads `$env:HP_APP_ARGS`
directly in PowerShell rather than cmd.exe-substituting `%HP_APP_ARGS%` into `-Command` text, since
the value contains literal embedded double-quotes per token that would corrupt naive substitution.

### Honest ambiguous-exit messaging (REQ-027, P2)

`:print_no_exe_briefing`'s header now dispatches on `HP_NOEXE_VERIFY_FAILED` (set in both branches
of `:verify_no_exe_interpreter` whenever `HP_SMOKE_RC` is nonzero) rather than unconditionally
claiming "your code ran successfully" -- mirrors the pre-existing `HP_EXE_VERIFY_FAILED` pattern
for the EXE path. A new `:print_fastpath_ambiguous_note` (called from
`else if defined HP_FASTPATH_RUN_FAILED`) closes the OTHER previously-silent gap: the "cached EXE
kept despite a later non-zero exit" case had NO postflight panel at all (the fast path's own
briefing dispatch is entirely skipped by design). Plain informational print, no consent gate --
points at the direct-run command and at deleting `dist\<env>.exe` for a fresh dependency check.
Neither panel asserts a root cause (real bug vs. unresolved dependency vs. something else stays
undistinguished, by design).

## Post-execution checkpoint (Slice 2b-C, second half)

`:run_postexec_checkpoint` is a **consent gate** (echo prompt unconditionally, then
`HP_TEST_CHECKPOINT_ANSWER` override, then `HP_CI_LANE` auto-decline, then interactive `set /p`) --
NOT the `HP_INTERACTIVE_RUN` silent-skip convention the fail-fast probe uses; do not conflate the
two. Called at the end of every FRESH verification run (`:smokerun_ndjson` and both branches of
`:verify_no_exe_interpreter`) -- never from `:try_fast_exe`'s reuse (would violate the fast path's
zero-friction rule even on auto-decline, since the prompt still echoes in CI). On accept, reuses
`:run_failfast_probe` (site `checkpoint`) with its OWN output files
(`~checkpoint_run.out.txt`/`.err.txt`) and explicitly saves/restores `HP_SMOKE_RC`/
`HP_PROBE_EXCEEDED` around the call so the caller's own downstream code still sees the FIRST run's
result. Cascade re-entry can offer this (and `:offer_optimized_build`'s prompt) more than once per
bootstrap -- each cascade tier is a genuinely different build.

**Cascade approval skips BOTH elective offers, but ONLY at the `exe` call site, ONLY when the
CURRENT tier's cascade was just approved** -- asking about a build the user just opted away from
wastes real time (the optimized-build offer alone can take a minute+). **The smoke run ITSELF is
never skipped**, even then: `HP_CASCADE_APPROVED` only means the next tier will be TRIED, not that
the cascade actually reaches one (every remaining tier could still be unavailable/declined,
falling back to keeping the CURRENT build) -- so `:run_exe_smokerun` always runs; only the two
elective follow-up calls inside `:smokerun_ndjson` are conditionally wrapped.

**`:cascade_consent_gate`'s real-interactive branch uses a TIMED `choice /T` prompt** (default 30s,
mirrors `:pick_entry_interactive`'s pattern; `/D N` on timeout) instead of an unbounded `set /p` --
several sibling gates still use unbounded `set /p` and share the same "hangs unattended" property,
fixing all of them was out of scope for this pass. A companion "dependencies may be incomplete"
note (`HP_DEP_MAYBE_INCOMPLETE`, set when a cascade candidate was detected but not approved) warns
at decision time and again right before the EXE launches -- a note, never a second gate.

### Cascade signal reliability

`HP_CASCADE_CANDIDATE` requires BOTH: (A) PyInstaller's warn file still lists an unresolved import
after a repair-install-and-rebuild, and (B) at least one specific repair install command in that
same round returned nonzero. Requiring both together (not "any repair failure") is what makes a
genuine candidate uncommon. Neither signal is based on actually running the `.exe`. Investigated
whether the uv->conda hop specifically deserves a different default (conda-forge is a genuinely
different index with pre-built native-extension binaries pip on Windows often can't produce;
later hops -- embed/venv/system -- all still resolve via plain PyPI pip, so they mainly help only
for environment-specific root causes, not genuine package unavailability). **Outcome: kept
`:cascade_consent_gate` exactly as shipped** -- no code change (see
`docs/agent-closed-backlog.md`'s Known Findings for the full reasoning trace).
