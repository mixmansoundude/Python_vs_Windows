# Agent Interconnectedness Map -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-interconnect.md`
import in CLAUDE.md. It documents the non-obvious cross-component dependencies that
future agents must understand to avoid re-introducing known failures.

Standalone hazards, rules, budgets, and procedures (batch/CMD quirks, the CMD `set` line
limit, the embedded-helper workflow, the ambient-Python lesson, etc.) now live in
`docs/agent-lessons-learned.md`.

**Categorization principle:** interconnect = a dependency between two or more components
such that changing one requires understanding the other ("touch A, must understand B"). A
standalone discovered fact, hazard, budget, or procedure belongs in
`docs/agent-lessons-learned.md` instead.

**AGENT DIRECTIVE: When you discover a new interconnect or correct an existing one, update
this file immediately in the SAME commit (edit existing entries, do not only append). Keep
`docs/agent-lessons-learned.md` current too. The map must stay accurate.**

---

## Concurrent-instance lock (REQ-024) touches every exit path -- call-graph tracing method

The lock (`:acquire_lock`/`:lock_is_stale`/`:release_lock`, called near the top of the file right
after `%STATUS_FILE%` cleanup, released at `:die` and `:success`) is cross-cutting: **any new
top-level process-terminating `exit /b` site, or any conversion of a `call`-based subroutine into
a `goto`-only continuation of the main line, must consider whether that site also needs
`call :release_lock` before it.**

**Why release is hooked at `:die`/`:success` only, not all ~100 `exit /b` sites** (`run_setup.bat`
has 129 `:label`s, 55 top-level `exit /b` sites, 100 total including indented/parenthesized ones):
whether a given `exit /b` terminates the whole process or just returns from a subroutine depends
on the RUNTIME call stack, not on whether its label was ever `call`ed -- `exit /b` returns to the
nearest active `call` frame, and a label reached purely via `goto` from inside an active call frame
(e.g. `:venv_canary_fail`, reached from within `:try_venv_fallback`'s frame) still returns to that
caller, not the whole process. A static line-based CFG walk (BFS over goto/call/fall-through edges)
proves depth for pure goto/call/fall-through code but breaks on parenthesized
`if (...) ( ... ) else ( ... )` blocks -- it has no notion of "skip to after the matching
close-paren" for the false branch without a full paren-balance parser, so it wrongly treats any
`exit /b` lexically inside such a block as always-reached. A true paren-aware CFG parser was
assessed as disproportionate effort.

**`tools/audit_batch_exit_paths.py`** (not wired into CI, run by hand) captures the label/call/exit
inventory instead: every label, every `call :label` site, every `exit /b` site with its containing
label and whether that label is ever `call`ed anywhere. It deliberately does NOT attempt the
paren-aware CFG proof -- its own docstring documents "called=False is a hint, not proof." Starting
point for a future exit-path audit, not a final answer.

**The actual correctness mechanism is age-based staleness, not proven release-path coverage** --
CMD has no `finally`/`trap`, so a design depending on proving every exit path releases the lock is
the wrong shape (Ctrl+C, a killed process, power loss, or a missed exit site all bypass any release
hook). The `:die`/`:success` hooks are an optimization (avoid a stale lock for up to ~2h after an
ordinary run), not the guarantee. Both are confirmed universal funnels for the normal flow: every
`call`-based consent-gate decline (REQ-014, REQ-009 cascade, REQ-013 connectivity, venv canary,
etc.) returns up its call chain and continues the bootstrap rather than terminating directly, and
the EXE fast path's early-success shortcut (`:try_fast_exe`, ~line 294) also funnels through
`:success` (see "EXE fast path vs env-state fast path" below). The few truly-early, pre-label
`exit /b 1` sites (workspace-path-invalid guards, ~lines 47/52) execute before the lock is ever
acquired, so need no release call.

**Rule for a new top-level (non-`call`ed) `exit /b` site**: if it's reachable with an empty call
stack (directly off a `goto` from the main line, not from inside any `call`ed subroutine's
continuation chain) AND is a *routine* exit a real user could hit often (not a crash), add
`call :release_lock` before it -- same as `:die`/`:success` -- so a repeated-decline pattern
doesn't leave stale locks for other users of the same folder.

---

## AV-Safe Build Path Tier A (`:try_nuitka_tier_a`) and hidden-import auto-recovery

**Touch either subroutine, must understand the other.** `:try_nuitka_tier_a` (AV-Safe Build Path
requirements 2-4, `docs/prd-av-safe-build-path.md`) attempts a Nuitka fallback build when
PyInstaller's own build fails; on success it sets `HP_NUITKA_FALLBACK_USED=1` and
`dist\<env>.exe` becomes a Nuitka-produced binary, not a PyInstaller one. `:hidden_import_recover`
(REQ-016 Slice 2, see `docs/agent-lessons-learned.md`'s "--hidden-import auto-recovery must stay
STRICT" entry) is the ONLY post-build repair mechanism for a frozen EXE that fails at runtime with
a `ModuleNotFoundError` for an installed module -- its repair action is a PyInstaller-specific
rebuild (`--hidden-import=X`), which does not apply to a Nuitka-built EXE (Nuitka has its own,
structurally different `--include-module`/`--follow-import-to` mechanism, not wired up here).

**Bug found and fixed (2026-07-21, same day Tier A shipped):** `:hidden_import_recover` had no
check for `HP_NUITKA_FALLBACK_USED` before its first real work -- it would unconditionally re-run
the EXE, scan for a fixable `ModuleNotFoundError`, and rebuild via `PyInstaller -y --onefile ...
--hidden-import=X`, silently discarding the Nuitka-built EXE for a fresh PyInstaller attempt. Since
Tier A only runs when the ORIGINAL PyInstaller build already failed, this rebuild had a real chance
of reproducing the exact failure Tier A exists to route around (e.g. AV quarantine), or at minimum
burning the loop's 3-attempt budget on the wrong tool. `HP_NUITKA_FALLBACK_USED` is process-global
and safely readable at `:hidden_import_recover`'s entry (only one `setlocal` exists in the whole
file, at the top, disabling delayed expansion -- no scoping boundary between the build block that
sets it and this subroutine).

**Fix**: `:hidden_import_recover` now checks `if defined HP_NUITKA_FALLBACK_USED` right after its
existing `if not exist "dist\%ENVNAME%.exe" exit /b 0` early-return, and exits `/b 0` immediately
(skip, not attempt-and-fail) with an `[INFO][HIDDEN_IMPORT]` log line -- deliberately a SKIP, not a
Nuitka-aware repair (wiring up Nuitka's own missing-import mechanism is a future feature if ever
needed). Regression test: `tests/selfapps_nuitka_tiera_hidden_skip.ps1` (uv lane, non-gating,
`self.exe.tiera.hidden_skip`) -- forces Tier A via `HP_TEST_FORCE_PYINSTALLER_FAIL=1`, lets a real
Nuitka build succeed, and has the stub app print a FABRICATED
`ModuleNotFoundError: No module named 'nuitka'` to stderr before exiting 1 (`nuitka` is guaranteed
installed in Tier A's own build interpreter, so the scanner's `find_spec` gate would treat it as
fixable if the skip guard were missing) -- asserts the skip log fires and the OLD
`[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=` rebuild line does NOT.

**Mirror-image gap found via a later bug-hunt pass, in the warnfix-triggered rebuild (a SECOND
PyInstaller rebuild call site, inside `HP_WARNFIX_NEEDED`): no failure handling at all, and no
`HP_NUITKA_FALLBACK_USED` clearing on success.** Unlike the original build (which routes every
failure through `:try_nuitka_tier_a`/`:die`/`HP_BOOTSTRAP_STATE=error`), this rebuild's
`"%HP_PY%" -m PyInstaller ...` call had no `if errorlevel 1` check -- the next line unconditionally
logged `[REPAIR] rebuild complete after warnfix.` regardless of outcome, and nothing re-checked
`dist\%ENVNAME%.exe`. A genuine failure here (the exact AV-lock class the PRD exists to route
around) fell through to `:run_exe_smokerun`'s silent no-op-when-missing skip, then a clean
interpreter-fallback run, ending in a false `state=ok`. Fixed with the same
`if errorlevel 1 (...) else if not exist "dist\%ENVNAME%.exe" (...) else (...)` nested if/else
shape (no goto, matching the "safe inside a parenthesized block" pattern) -- **deliberately NOT
retried via `:try_nuitka_tier_a`**: this rebuild only bundles an already-installed warnfix module
into an EXE already confirmed working, so the conservative response to failure is
`HP_BOOTSTRAP_STATE=error`, not a speculative second build tool inside an already-nested failure
path. On SUCCESS the fix also clears `HP_NUITKA_FALLBACK_USED` -- this rebuild always uses
PyInstaller, so if the EXE it just replaced was previously Nuitka-built (a stale
`build\%ENVNAME%\warn-%ENVNAME%.txt` can survive a Tier-A-rescued build and still trigger this
block), the flag must reflect the file is now genuinely PyInstaller-built, or
`:hidden_import_recover`'s guard above would wrongly keep skipping repair. No dedicated CI test
(a review-pass correctness fix reusing an already-tested failure-handling shape) -- flagged in
CLAUDE.md as a candidate for a future dedicated test pass if this path's trigger rate justifies it.

**Any future Tier B or alternate-build-tool path needs this same guard**, on
`HP_NUITKA_FALLBACK_USED` specifically (or an equivalent "the EXE at `dist\<env>.exe` was NOT built
by PyInstaller" signal) -- any subroutine that can produce `dist\<env>.exe` via something other
than PyInstaller should set an analogous marker and extend this guard to check it.

**`:hidden_import_recover` now pairs `--collect-submodules=X` with every `--hidden-import=X` it
adds (`docs/agent-closed-backlog.md`'s Item 28, closed 2026-08-08 -- confirmed via real CI evidence
the same day, see that entry for the trace).** A `--hidden-import=X` target alone only
guarantees PyInstaller follows whatever `X`'s own `__init__.py` statically imports -- it does not
guarantee every real submodule under `X/` is bundled. A compiled C extension ELSEWHERE in the app
(invisible to PyInstaller's static scan the same way the original missing import was) can still
need a submodule of `X` that `X`'s own `__init__.py` never references -- confirmed via a real
pygrib 2.1.8 failure (`from packaging import version` inside a Cython extension, needing
`packaging.version` even after `--hidden-import=packaging` alone genuinely worked). New
accumulator `HP_PYI_HID_COLLECT` (distinct from the pre-build `HP_PYI_COLLECT` computed by
`:compute_collect_flags` for packages imported by the USER'S OWN source -- do not confuse the
two, they are gated completely differently) mirrors `HP_PYI_HIDDEN_IMPORTS`'s own
accumulate-then-inject shape: each loop iteration appends
`--collect-submodules=%HP_NEXT_HIDDEN%` for the SAME `%HP_NEXT_HIDDEN%` just added as a hidden
import, and both flag lists are passed to the SAME rebuild call. Broader than strictly necessary
(collects every submodule of `X`, not just the one actually needed) but structurally safe: `X` is
already `find_spec`-confirmed installed by `~hidden_import_scan.py`'s own gate (see
`docs/agent-lessons-learned.md`'s "--hidden-import auto-recovery must stay STRICT" entry, which
this change leaves untouched -- it only changes what happens for a target the strict gate ALREADY
decided to act on, never what triggers the gate itself).

**The `[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=X` log line now reads
`Adding --hidden-import=X --collect-submodules=X`** -- every existing consumer of that line
matches it as a PREFIX substring (`-match [regex]::Escape('...Adding --hidden-import=colorama')`
or the bare `'...Adding --hidden-import='` prefix), never a full-line or trailing-anchor match, so
each one continues to match unchanged: `self.exe.hidden_import`'s own `addingFired` check,
`self.exe.hidden_import.exhaust`'s `$addingCount -eq 3` occurrence count (the appended text sits
BEFORE the semicolon each line already had, so the per-line occurrence count of the matched
substring is unaffected), `self.layered_e2e.chain`'s `mech3Pass` colorama check, and
`tests/selfapps_nuitka_tiera_hidden_skip.ps1`'s negative "this line must NOT appear" check (still
correctly absent, since that code path returns before ever reaching this line). Re-verify this
holds for any FUTURE change to this log line's own text.

---

## Conda native-DLL bundling repair loop (`:dll_bundle_recover`, CLAUDE.md Item 24) and its two siblings

**Touch any of the three PyInstaller repair loops (`:dll_bundle_recover`, `:hidden_import_recover`,
the warnfix per-module rebuild), must understand how they chain.** `:dll_bundle_recover` (new,
`docs/prd-conda-native-dll-bundling.md`) repairs a DIFFERENT failure class than
`:hidden_import_recover`: a conda-installed native extension's own compiled `.pyd` depends on a
shared DLL under the env's `Library\bin` (conda's convention, e.g. `eccodes.dll` for `pygrib`) that
PyInstaller's static analysis bundles the `.pyd` for but never discovers the DLL dependency of --
this is a MISSING-NATIVE-LIBRARY failure, not a missing-Python-module one, so
`:hidden_import_recover`'s own strict `ModuleNotFoundError`-only gate correctly never fires for it
(see "--hidden-import auto-recovery must stay STRICT" in `docs/agent-lessons-learned.md`).

**Detects at BUILD time, not runtime -- the one structural difference from `:hidden_import_recover`
(Requirement 2's own design choice, `docs/prd-conda-native-dll-bundling.md` Finding 5).**
`:hidden_import_recover` has no earlier signal than the runtime `ModuleNotFoundError` (PyInstaller's
static analysis cannot tell whether an installed module will actually be imported at runtime), so
it must re-run the EXE to detect anything. This failure class announces itself immediately after
the build, in the build log itself (`WARNING: Library not found: could not resolve 'X.dll',
dependency of '...'.`) -- reacting to that build-time line (`:dll_bundle_recover` is called from
`:run_entry_smoke` right before `:run_exe_smokerun`, i.e. BEFORE the smoke run rather than after)
skips one guaranteed-failing verification cycle a runtime-detection design would otherwise waste.
The `HP_LOG_SIZE_BEFORE` byte-offset snapshot (taken right before the fresh-build attempt begins)
is what makes this safe against `%LOG%`'s own persistence across runs in the same app directory --
without it, a stale DLL warning from an EARLIER run could be re-detected and re-"fixed" for no
reason. `tools/dll_bundle_scan.py` (`HP_DLL_BUNDLE_SCAN` payload) is the scanning helper, mirroring
`~hidden_import_scan.py`'s shape (`read_tail`/`next_dll_target`/`locate_dll`/`main`, unit-tested in
`tests/test_dll_bundle_scan.py`) but reading a byte-offset log slice instead of a captured EXE
stderr file, and with two extra pieces the sibling doesn't need: a `--detect` CLI mode (see below)
and `read_tried_file()` (see the tried-list paragraph below).

**Bug found and fixed via review (real, not hypothetical): the original implementation gated
DETECTION itself on `HP_ENV_MODE=conda`, silently defeating the "provider-agnostic detection"
design the PRD itself specifies.** The first-shipped version checked `if not "%HP_ENV_MODE%"=="conda"
exit /b 0` as effectively the FIRST real check, before ever scanning the log -- meaning a non-conda
provider (or a Nuitka-built EXE, same class of bug) got ZERO detection and ZERO log line, not the
documented "detected, repair skipped" state (see `docs/open-questions.md`). Fixed by restructuring
so detection runs first and unconditionally (a cheap `--detect`-mode call into
`tools/dll_bundle_scan.py` that only parses the log, no `Library\bin` lookup), with the
Nuitka-guard and the conda-gate each becoming a "detected but here's why we can't act" log branch
instead of a silent early exit before detection ever happened.

**Built GENERAL, not hardcoded to `eccodes.dll`** (resolved `docs/open-questions.md`'s former
narrow-vs-general question, 2026-08-04): `next_dll_target()` parses whatever DLL name PyInstaller's
own warning names via regex, not a fixed string -- the loop's reactive/bounded/iterative shape
(mirroring `:hidden_import_recover`, 3-iteration cap, tried-list guard) does not actually care
whether the DLL name is hardcoded or parsed out of the warning text, so building it general cost no
more than building it narrow would have. Double-gated like its sibling: `locate_dll()` requires the
named DLL to ACTUALLY exist under the conda env's own `Library\bin` (searched recursively, since
`hook-gribapi.py` itself nests `eccodes.dll` under a package-named subfolder there on Windows, per
the PRD's Finding 1) before emitting anything -- a name mentioned in a stale/irrelevant warning that
isn't really on disk is not something `--add-binary` could fix.

**Gated to `HP_ENV_MODE=conda` for the actual bundling action (Requirement 3) ONLY -- detection now
genuinely runs first and unconditionally.** `Library\bin` is conda's own shared-DLL convention,
meaningless under uv/embed/venv/system (those install from PyPI wheels, expected to vendor their
own native deps) -- with no conda env to search there is nothing this loop could BUNDLE even under
a real warning, but it still logs `[INFO][DLL_BUNDLE] Detected native-DLL warning for '...';
native-DLL bundling repair requires the conda provider...; skipping.` rather than staying silent,
satisfying the caveat panel's "detected, repair skipped" state.

**Carries the identical `HP_NUITKA_FALLBACK_USED` early-exit guard `:hidden_import_recover` has, for
the identical reason (Requirement 6) -- also now checked AFTER detection, for the same reason as
the conda gate above.** `--add-binary` is a PyInstaller-specific flag with no Nuitka equivalent
wired up here; skip (not attempt-and-fail) rather than risk rebuilding a working Tier-A EXE via the
wrong tool, but still log the detected DLL name before skipping.

**Tried-list is a FILE (`~dll_bundle_tried.txt`), not inline argv -- a second real bug found via
review.** The first-shipped version accumulated tried DLL names in a batch variable
(`HP_DLL_TRIED`) and expanded it unquoted on the scan command line -- a DLL basename can legally
contain a space or a cmd.exe metacharacter (`&`, `|`, `^`), which would split the command line's
argv or, worse, have `&` interpreted as a command separator, injecting arbitrary text into the
line. Fixed by appending each `name|path` result to a tilde-prefixed file via `type ...
>>"~dll_bundle_tried.txt"` (pure byte-copy between files, never routing the DLL name through any
`%VAR%`-expanded command text) and having `tools/dll_bundle_scan.py`'s new `read_tried_file()`
parse it back -- the same "prefer a file over inline argv for anything risky" convention this
repo already uses for `~missing_modules.txt`/`~next_hidden.txt`.

**`main()` continues past a named-but-not-on-disk candidate to the next one -- a third real bug
found via review.** The first-shipped version returned nothing the moment the FIRST untried
candidate failed `locate_dll()`'s double-gate, even if a LATER warning in the same log named a
real, locatable DLL -- silently stalling the whole loop on a single stale/irrelevant warning.
Fixed with a small loop in `main()` that keeps trying successive candidates (via
`next_dll_target(text, candidates)` with the just-rejected name appended to `candidates` each pass)
until one is both untried and actually found on disk, or none remain.

**The "bundling complete" log line must never fire on a genuine rebuild failure -- a fourth real
bug found via review, mirroring a bug class this repo has already hit and fixed once before for the
warnfix-triggered rebuild (see `docs/agent-lessons-learned.md`'s general "no failure handling at
all... unconditionally logged... complete... regardless of outcome" pattern).** `HP_DLL_ITER`
increments BEFORE the rebuild attempt, so a naive `if %HP_DLL_ITER% GEQ 1` check at the loop's exit
label is true on both the success path AND either failure path (`errorlevel 1` from PyInstaller, or
a missing `dist\<env>.exe` afterward) -- the original code used exactly that check, so a genuine
rebuild failure could still log "Native-DLL bundling complete" and continue as if nothing were
wrong. Fixed with an explicit `HP_DLL_FAILED` flag, set only on a real failure branch (which also
sets `HP_BOOTSTRAP_STATE=error` and logs an `[ERROR][DLL_BUNDLE]` line, mirroring the
warnfix-rebuild's own "conservative response to failure" precedent) and checked before the
"complete" line is ever logged. The smoke run afterward is deliberately NOT skipped on this
failure (same reasoning as the warnfix rebuild) -- `HP_BOOTSTRAP_STATE=error` alone is the
authoritative signal; see "Single-verification smoke model" above for why the smoke run always
runs regardless.

**`HP_PYI_DLLBIND` must be threaded into `:hidden_import_recover`'s OWN rebuild command, or a later
hidden-import repair silently drops an earlier DLL-bundle repair.** Both loops can fire in the same
build lifecycle (a native-DLL warning AND a separate missing-Python-module runtime failure), and
`:dll_bundle_recover` always runs first (build-time, before the smoke run that `:hidden_import_
recover` reacts to). Since `HP_PYI_DLLBIND` is reset only in the same end-of-`:run_entry_smoke`
trailer as `HP_PYI_EXPAT`/`HP_PYI_COLLECT` (not between the two loops), it survives into
`:hidden_import_recover`'s own rebuild -- but only because that rebuild's own PyInstaller command
line explicitly includes `%HP_PYI_DLLBIND%` alongside `%HP_PYI_EXPAT% %HP_PYI_COLLECT%
%HP_PYI_HIDDEN_IMPORTS%`. Any future repair loop added to this same build lifecycle must thread its
own accumulated flags through EVERY later rebuild command the same way, or an earlier loop's fix
gets silently discarded by a later one's rebuild.

**A fifth real bug found via review: `HP_DLL_DETECTED`/`HP_NEXT_DLL`/`HP_NEXT_DLL_PATH` reached
`:log`'s UNQUOTED echo, an already-documented hazard class in this repo (see
`docs/agent-lessons-learned.md`'s ":log echoes UNQUOTED" entry) this loop had not yet been
checked against.** All three values are ultimately derived from PyInstaller's own build-log
warning text (`_PATTERN`'s regex extracts whatever sits between quotes in `Library not found:
could not resolve 'X.dll'`), which can legally contain `&`/`|`/`<`/`>` on Windows -- cmd.exe would
reinterpret any of those as a live redirection/pipe operator once substituted into `:log`'s
unquoted `echo %date% %time% %MSG%` line, corrupting the log line and/or creating a stray file.
Fixed with the same DISPLAY-ONLY sanitization pattern the `%HP_ENTRY%` case documents as the
correct fix wherever the source is tractable (unlike `%HP_ENTRY%` itself, which remains an
accepted risk because its only real fix -- a global `:log` rework -- is blocked by three CI static
guards): `HP_DLL_DETECTED_SAFE`/`HP_NEXT_DLL_SAFE`/`HP_NEXT_DLL_PATH_SAFE` are computed via
chained `set "VAR_SAFE=%VAR_SAFE:&=_%"` substitution (repeated for `|`, `<`, `>`) immediately after
each raw value is captured, and used ONLY in `:log` calls -- every functional use of the raw value
(the tried-file byte-copy via `type`, the quoted `--add-binary` PyInstaller argument) is
untouched, so this cannot desync the tried-list dedup matching (`next_dll_target()` re-extracts
the RAW name from the log text on every loop iteration; sanitizing only the tried-file's stored
copy would break equality comparison for any DLL name containing a hazardous character).

**A sixth real bug found via a SECOND review pass on the fifth bug's own fix: the `_SAFE`
sanitization above stripped `&`/`|`/`<`/`>` but left `%` and `^` untouched, missing that `call`
performs its OWN, SECOND cmd.exe expansion pass on the command line it is calling** -- a
well-established (if not officially documented by Microsoft) cmd.exe behavior: `call :log "...
%HP_NEXT_DLL_SAFE% ..."` is itself an ordinary command line, so `%HP_NEXT_DLL_SAFE%` is substituted
once during the NORMAL parse of that line (as with any `%VAR%` reference) -- but because the
command being executed is `call`, cmd.exe then re-scans the ALREADY-SUBSTITUTED text a second time
before actually invoking `:log`. If the substituted text happened to contain something shaped like
`%SOME_VAR%` (a crafted "library not found" name from an adversarial native extension, since
`_PATTERN`'s regex only excludes quote characters, not `%`/`^`), that second pass would expand
`SOME_VAR`'s real value into what `:log` receives as `%~1` -- potentially leaking an unrelated
environment variable (e.g. a CI secret) into the log.

**First fix attempt was itself wrong, and only caught because a live-cmd.exe CI test was built to
verify it.** The initial fix extended all three `_SAFE` chains with `set "VAR_SAFE=%VAR_SAFE:%%=_%"`
on the theory that doubling `%` to `%%` is "the standard, long-established cmd.exe idiom" for
matching a literal percent sign as the search token in a `:search=replace` substitution. This is
**not actually how cmd.exe behaves** -- confirmed via `tests/harness.ps1`'s
`batch.dll_bundle.pct_sanitizer` fixture (built specifically to settle a Blinter E021 "malformed
string operation" flag on this construct empirically rather than trust static reasoning a fourth
time) executed for real on Windows CI: the substitution silently produced an **empty** value
(`echo` with no argument, `"ECHO is off."`) instead of the expected sanitized text -- an
undocumented cmd.exe parsing quirk, not a Blinter false positive as first assumed. This broke
`HP_DLL_DETECTED_SAFE`/`HP_NEXT_DLL_SAFE`/`HP_NEXT_DLL_PATH_SAFE` across essentially every CI lane
(the gating `batch.dll_bundle.pct_sanitizer` NDJSON row failed the run).

**Actual fix: strip `%` and `^` in PowerShell instead of cmd.exe substitution.** Each `_SAFE`
variable's `%`/`^` stripping now happens via a `powershell -NoProfile -ExecutionPolicy Bypass
-Command` call, read back via a plain, non-`call` `for /f "usebackq delims=" %%X in
("~dll_pct_safe*.txt") do set "VAR_SAFE=%%X"`. Reading the value via
`[Environment]::GetEnvironmentVariable` (never substituting it into the `-Command` text itself)
means this cannot reintroduce the same `call`-triggered second-pass hazard one layer up. `HP_NEXT_
DLL_SAFE`/`HP_NEXT_DLL_PATH_SAFE` are sanitized in ONE PowerShell invocation writing TWO separate
output files (`~dll_pct_safe_a.txt`/`~dll_pct_safe_b.txt`), not one combined multi-line file --
this repo bans delayed expansion (`!VAR!`) repo-wide, which parsing multiple lines out of one file
back into two batch variables would otherwise need. `&`/`|`/`<`/`>` stripping is unchanged (still
plain cmd.exe `:search=replace` substitution -- that part was never wrong, only the `%%` escape
attempt was).

**A THIRD real bug, caught by this fixture's own first real Windows CI run (the fixture proved
itself trustworthy again, not the fix): a lone, unpaired `%` inside the literal PowerShell text
`-replace '%','_'` sits on the SAME cmd.exe logical line as `%LOG%` (or, in the fixture itself,
`%TEMP%`).** cmd.exe pairs `%` characters via a left-to-right scan of the WHOLE line, completely
ignoring quote boundaries -- the lone `%` paired with `%LOG%`'s own opening `%`, and cmd.exe
treated everything between them (the entire real replace logic, dozens of characters) as one
bogus, undefined variable name. Inside a batch file, an undefined `%VAR%` reference is silently
removed and replaced with empty text (not left literal, the classic batch-only gotcha) -- so the
whole PowerShell command was gutted before it ever ran, producing an empty output file and the
identical `"ECHO is off."` failure signature as the first bug, on every single lane again. The
`HP_NEXT_DLL_SAFE`/`HP_NEXT_DLL_PATH_SAFE` block had a variant of the same bug with an EVEN total
`%` count (two lone `%`'s from two `-replace` calls, plus `%LOG%`'s own pair) -- even parity is
not enough to prove correct pairing: the two lone `%`'s paired with EACH OTHER instead of each
pairing with `%LOG%`, silently deleting the entire first `Set-Content` call as one bogus variable
name. **Fixed by removing every literal `%` from the `-Command` text entirely**: `$pct = [char]37`
builds the percent character inside PowerShell itself, so the only `%` remaining on any of these
cmd.exe lines is the single, legitimate, correctly-paired `%LOG%`/`%TEMP%` reference -- verified by
literally counting `%` occurrences per logical (continuation-joined) line after the fix (exactly 2
in every case, the one intended pair). `tests/harness.ps1`'s `batch.dll_bundle.pct_sanitizer`
fixture was updated with the same `[char]37` technique -- it validates the REPLACEMENT mechanism
(still a real cmd.exe + PowerShell child-process execution, not static pattern matching) and
additionally proves the actual security property end-to-end: a raw value shaped like `%SECRET%`,
once sanitized, survives a real `call`-based second expansion pass without leaking the shadowed
`SECRET` variable's true value. Order among all six substitutions
(`&`/`|`/`<`/`>`/`%`/`^`) is commutative -- none of them can match the replacement character (`_`),
so chaining them in any order produces the same result. `HP_NEXT_DLL_PATH_SAFE` needs the same `%`/
`^` stripping even though its raw value is a real, `os.walk()`-confirmed path (unlike
`HP_DLL_DETECTED`/`HP_NEXT_DLL`, which are regex-extracted from arbitrary warning text) -- Windows
filenames may legally contain `%`, `^`, and `&` (NTFS's own forbidden set is only
`< > : " / \ | ? *` plus control characters), so a real conda-forge package path could carry any of
these. `&` is a valid filename character but still a genuine CMD *transport* hazard once that path
reaches an unquoted `:log` echo -- legality on disk and safety on a cmd.exe command line are
unrelated axes, which is why it still needs the same sanitization as `|`/`<`/`>` (those three ARE
also filesystem-illegal, so a real path containing them would be a defect elsewhere; `&` is the one
character in this set that's both filesystem-legal and CMD-hazardous).

**Eventually converted to a real emitted `.ps1` file (`tools/dll_pct_sanitize.ps1`,
`HP_DLL_PCT_SANITIZE`), which eliminates this entire bug class structurally rather than patching
around it a fourth time.** All three bugs above share one root cause: literal `%` text sitting
somewhere on a line cmd.exe itself parses. A `-File "path" arg1 arg2...` invocation has no such
line -- cmd.exe only tokenizes the outer invocation (plain argv, no `%`-pairing hazard); the
script's own body is read and executed entirely by PowerShell, which never sees cmd.exe's parser
at all. Both call sites (`HP_DLL_DETECTED_SAFE`; `HP_NEXT_DLL_SAFE`/`HP_NEXT_DLL_PATH_SAFE`) now
call this one shared helper (`(envVarName, outFile)` pairs as plain argv) instead of building
inline `-Command` text per call site. See `docs/agent-lessons-learned.md`'s "PowerShell helpers:
prefer an emitted `.ps1` file..." entry, extended with this as a second, independent trigger
condition (alongside embedded `"` characters) for preferring `-File` over `-Command`.

**A companion CodeRabbit finding on the same review round: the loop's detected/skipped/repaired/
unlocatable/failed outcomes previously reached only `:log`'s console text, with no
machine-readable record.** Fixed with a new shared subroutine, `:emit_dll_bundle_row`, called from
all 7 outcome points (`skipped_nuitka`/`skipped_non_conda`/`repaired`/`unlocatable`/`exhausted`/
`failed_rebuild`/`failed_missing_exe`) and emitting NDJSON id `self.dll_bundle.recover` -- see
`docs/agent-ndjson.md` for the full field list and the `HP_NDJSON`-scoping caveat (this row is
not currently observed in `self.layered_e2e.chain`'s own artifact, since that test's isolated
sub-bootstrap leaves `HP_NDJSON` unset by the same established convention `selfapps_postexec_
checkpoint.ps1` already uses; `tests/harness.ps1`'s new `batch.dll_bundle.ndjson` static check is
the actual coverage for this row's wiring). The state name is passed as a `call` argument (safe --
always one of the 7 literal tokens above, written directly in `run_setup.bat`, never derived from
external content), but the DLL name/provider/iteration are pulled INSIDE the emitting PowerShell
command via `[Environment]::GetEnvironmentVariable(...)` rather than `%VAR%` cmd.exe substitution
into the `-Command` text -- protecting cmd.exe's OWN command-line parsing (`&`/`|` are
metacharacters even inside a quoted `call` argument) the same way the `_SAFE` display variables
protect `:log`'s unquoted echo, just at a different vulnerable site.

**A NINTH real bug found via a CodeRabbit review round on PR #414 itself (CLAUDE.md Item 25,
fixed in a dedicated follow-up loop): `:dll_bundle_loop` found the next candidate (`HP_NEXT_DLL`)
BEFORE checking `if %HP_DLL_ITER% GEQ 3`, silently discarding it instead of reporting an
`exhausted` outcome.** When a 4th (or later) locatable DLL exists after the 3-iteration cap is
already hit, the loop just `goto :dll_bundle_recover_done` with the candidate's own name and path
already sitting in `HP_NEXT_DLL`/`HP_NEXT_DLL_PATH` from that iteration's scan, but with nothing
recording that a real candidate was left unbundled. At `:dll_bundle_recover_done`, the
`if %HP_DLL_ITER% GEQ 1` check reads TRUE (3 DLLs were already genuinely bundled in earlier
iterations), so it logged `[REPAIR][DLL_BUNDLE] Native-DLL bundling complete` and emitted the
`repaired` NDJSON state -- indistinguishable from a clean, fully-resolved run, even though a real,
on-disk DLL was never bundled and the EXE could still fail to load it. Fixed with a new
`HP_DLL_EXHAUSTED` flag, set at the cap-check branch in `:dll_bundle_loop` (the early
`if not defined HP_NEXT_DLL` return above it already rules out the empty-candidate case, so
reaching the cap check at all means a real candidate was found and about to be discarded) and
checked at `:dll_bundle_recover_done` BEFORE the `HP_DLL_ITER GEQ 1` "repaired" branch -- emits a
new `[WARN][DLL_BUNDLE]` line and the `exhausted` NDJSON state instead, reusing the already-
sanitized `HP_DLL_DETECTED_SAFE` (the first warning seen this run, computed once at
`:dll_bundle_recover`'s own entry) to safely name at least one detected dependency without a new
sanitize pass. `exhausted` is `pass:true` under `:emit_dll_bundle_row`'s existing
`$pass = -not ($state -like 'failed_*')` formula -- same treatment as `unlocatable`, since neither
state means the bootstrap itself failed, only that the repair was incomplete; the EXE smoke run
afterward is the actual arbiter of whether the missing DLL matters at runtime. Mirrors
`:hidden_import_recover`'s own `[WARN][HIDDEN_IMPORT] Auto-recovery exhausted after 3 attempts`
precedent in spirit (a distinct "gave up, did not fully resolve" signal), though that sibling
loop's exhaustion is detected via a runtime EXE re-run rather than a build-time scan, so the two
mechanisms are not literally shared code. `HP_DLL_EXHAUSTED` is reset at `:dll_bundle_recover`'s
own top-of-loop reset block (alongside `HP_DLL_FAILED`) and cleared again at
`:dll_bundle_recover_exit`, mirroring `HP_DLL_FAILED`'s own cascade-re-entry-safe reset pattern
(see the CodeRabbit finding above about `HP_NEXT_DLL`/`HP_DLL_ITER` leaking across a REQ-009
cascade re-entry) -- a stale `exhausted` outcome from an EARLIER `:dll_bundle_recover` call could
otherwise leak into a LATER call's own outcome the same way that earlier bug did. Low real-world
trigger rate (needs 4+ conda-forge packages under ONE PyInstaller build to each separately need
`--add-binary`, not yet observed for any real package in this repo's testing) -- covered only by
`tests/harness.ps1`'s `batch.dll_bundle.ndjson` static wiring check (the new 7th call site and
state token), the same "static wiring guard, not runtime execution" precedent already accepted
for 4 of this subroutine's other 5 pre-existing states (see `docs/agent-ndjson.md`'s own note on
this), not a live CI trigger -- building a live fixture would need either 4 genuine native-DLL
dependencies in one build (not yet observed for any real package) or a new test-only injection
hook into the detection step, judged disproportionate effort for a low-trigger-rate correctness
fix relative to the rest of this feature.

**`self.layered_e2e.chain` (`tests/selfapps_layered_e2e.ps1`) is this loop's regression test
(Requirement 4)**, extended with a 4th mechanism (`mech4Pass`) alongside the three it already
proved for real (REQ-009 cascade, warnfix repair, hidden-import recovery) -- see that file's own
header comment for the full mechanism trace. `pygrib`'s conda-forge build genuinely triggers this
exact native-DLL gap, making `chainPass` flipping to `True` for the first time this loop's own
acceptance criterion.

**An EIGHTH real bug, found via the first real `cache`-lane run of this whole feature
(2026-08-07): `HP_PY_DIR`'s own trailing backslash corrupted the `~dll_bundle_scan.py` call's
argv, so `locate_dll()` always reported "could not locate" even when the DLL was genuinely
present.** `HP_PY_DIR` (from `%~dpI`) always ends in exactly one trailing backslash; quoted as
`"%HP_PY_DIR%"` immediately before another quoted argument (the tried-file path), Python's own
Windows argv parser (the same `CommandLineToArgvW`-equivalent hazard already documented for
`findstr.exe` in `docs/agent-lessons-learned.md`'s "A single trailing backslash before a closing
quote" entry -- this is the SAME general rule hitting a second native executable) treats the
single trailing backslash as escaping the closing quote rather than closing it, silently merging
`conda_env_dir` with the tried-file argument into one garbage string. `os.path.isdir()` then
fails on that garbage regardless of whether the real DLL exists. Confirmed directly: the real
`eccodes-2.48.0-h3bec8ca_0` conda-forge win-64 package genuinely ships `Library\bin\eccodes.dll`
(downloaded and inspected the package contents directly), and the real CI run's own
`~environment.lock.txt` confirmed `eccodes=2.48.0=h3bec8ca_0` was genuinely installed -- yet the
loop still reported `[INFO][DLL_BUNDLE] Detected native-DLL warning for 'eccodes.dll' but could
not locate a matching file under the conda env's Library\bin; skipping.` Deterministic, not
flaky -- `HP_PY_DIR` always ends in one backslash by construction, so every conda-provider run
hit this. **Fixed** with `HP_PY_DIR_ARG` (one extra backslash appended before quoting, giving an
even count) at the one call site that needed it; the sibling `HP_EXPAT_DLL` lookup a few lines
earlier was never affected, since there the trailing backslash is followed by more literal path
text (`Library\bin\libexpat*.dll`) before the closing quote, not directly by it.

**Also plausibly explains why `mech3Pass` (hidden-import recovery, colorama) had never been
observed passing in the same run either**: the frozen EXE never got past the corrupted-DLL
`pygrib` import to reach colorama's own separate, deliberately un-bundled hidden-import gap, so
`:hidden_import_recover`'s strict `ModuleNotFoundError`-only gate never had a chance to fire --
an `ImportError: DLL load failed` is a structurally different signature it correctly declines
(see "--hidden-import auto-recovery must stay STRICT" in `docs/agent-lessons-learned.md`).

**Confirmed fixed via real CI evidence (commit `45ec269`, `cache`-lane run `31208498606`)** --
`~layered_e2e_bootstrap.log` shows the loop genuinely locating and bundling `eccodes.dll` for the
first time: `[REPAIR][DLL_BUNDLE] Bundling native DLL dependency: eccodes.dll (found at
...\Library\bin\eccodes.dll); rebuilding EXE (iter 1/3).` followed by `Native-DLL bundling
complete`. `mech4Pass` is confirmed `true`, closing CLAUDE.md's Item 24. The fix itself was
verified pre-CI via a faithful Python simulation of the documented Windows argv-parsing algorithm
(`tests/test_dll_bundle_scan.py`'s `HpPyDirArgvQuoting` class) -- this hazard class cannot be
reproduced via a real subprocess on a Linux sandbox at all, since Linux's `execve` passes argv as
an array with no command-line re-tokenizing step for the simulation to catch a regression in; the
real CI run is what actually confirmed it. **Also confirmed the mech3 prediction was directionally
right but not the whole story**: the EXE does get further now, but hits a NEW, deeper gap first
(`pygrib`'s own extension needs `numpy`/`packaging` as hidden imports before colorama's own gap is
ever reached) -- see `docs/agent-closed-backlog.md`'s Item 28 entry for the full trace of this
separately-scoped finding (closed 2026-08-08; its own fix uncovered a further, deeper gap now
tracked as CLAUDE.md's Item 29).

---

## AV-Safe Build Path requirement 9 (`:offer_optimized_build`) -- a strictly safer sibling of Tier A

**Shares `:try_nuitka_tier_a`'s Nuitka invocation but NOT its "delete first, build second" safety
posture -- that difference is the entire point.** Tier A runs only after PyInstaller already
failed, so it's free to `del "dist\%ENVNAME%.exe"` first -- nothing working to lose.
`:offer_optimized_build` (requirement 9, called from `:smokerun_ndjson` right after
`call :run_postexec_checkpoint exe`, before `HP_EXE_EXIT` is cleared) runs in the OPPOSITE
situation: PyInstaller already succeeded AND the EXE already passed smoke-test verification.
Deleting/overwriting `dist\%ENVNAME%.exe` up front would risk losing a confirmed-working build to
an elective, declinable upsell. Instead it builds to a distinct temp name
(`%ENVNAME%.optimized_build.exe`), runs its own internal 30s-capped verification launch against
that temp file (same `ProcessStartInfo`/`WaitForExit(30000)`/`Kill()`-on-timeout pattern as
`:run_exe_smokerun`), and only on CONFIRMED build-and-run success does `move /y` swap it over the
original. Every failure branch (`goto :optbuild_cleanup`) deletes only the temp file, leaving
`dist\%ENVNAME%.exe` untouched -- see the subroutine's own header comment for the full trace.

**Bug found and fixed (same day PR #370 merged): the post-swap "did it work" check tested the
wrong file.** The original code checked `if not exist "dist\%ENVNAME%.exe"` after `move /y` --
but that's the DESTINATION, the already-working original EXE, which exists BEFORE the move
regardless of outcome. A same-volume `move /y` onto an existing destination is an atomic
rename-replace: on success the SOURCE is consumed; on failure (e.g. an AV/indexer lock on the
destination -- same hazard class as `:try_embed_fallback`'s own `rd`/`move` swap below) the whole
operation is rejected, source untouched, destination unaffected. The destination-existence check
could therefore never detect a failed swap -- a real failure was silently misreported as
`[INFO] Optimized build succeeded and verified...`, `HP_NUITKA_FALLBACK_USED` wrongly set
(incorrectly disabling `:hidden_import_recover`'s auto-recovery for what's still a
PyInstaller-built EXE), and the leftover temp file never cleaned up. Fixed by checking whether the
SOURCE is gone instead, routed through the shared `:optbuild_cleanup` label like every other
failure branch (fixing the temp-file leak too). New test hook
`HP_TEST_FORCE_OPTBUILD_SWAP_FAIL` (skips the real `move`, leaves the temp file in place,
reproducing the "source still exists after move" failure signature without an OS-level lock) and
a new `swapfail` scenario in `tests/selfapps_optimized_build.ps1` (uv lane, non-gating, real
Nuitka build) prove the fix.

**Gated on the SAME `HP_NUITKA_FALLBACK_USED` flag Tier A sets, for the opposite reason.** Tier
A's hidden-import-recovery guard checks the flag to SKIP a PyInstaller-only repair against a
Nuitka EXE; this subroutine checks it to SKIP OFFERING THE PROMPT AT ALL when Tier A already ran
(the "want an optimized version too?" question doesn't apply -- the user already has one). On its
own success path it sets `HP_NUITKA_FALLBACK_USED=1` too, for the same semantic reason -- this
happens late enough (after `:run_exe_smokerun`/`:hidden_import_recover` already completed for this
pass) to have no retroactive effect within the same run, but keeps the flag accurate later.

**Cascade re-entry can offer this prompt more than once per bootstrap, same as the checkpoint** --
called from the same site as `:run_postexec_checkpoint exe`, so a REQ-009 cascade reaching a new
verification pass under a different provider tier re-offers BOTH prompts fresh each time
(intentional -- each cascade tier is a genuinely different build; see "Post-execution checkpoint"
below).

**Consent-gate pattern mirrors `:run_postexec_checkpoint`'s BROADER 4-way auto-decline set** (not
the narrower 3-branch gates elsewhere, e.g. `:system_build_consent_gate`) -- like the checkpoint,
this fires on essentially every successful run, so it also auto-declines on
`NOINPUT`/`HP_NONINTERACTIVE` in addition to `HP_CI_LANE`, matching `:compute_interactive_run`'s
authoritative non-interactivity signals.

**Nuitka/MSVC auto-detection research** (informs the reactive-only hint text on failure, in both
this subroutine and `:try_nuitka_tier_a`): confirmed via Nuitka/Nuitka#3317 that Nuitka
auto-detects an installed Visual Studio via the registry with NO need for a Developer Command
Prompt or `vcvarsall.bat` -- a plain VS2022 + "Desktop development with C++" install should "just
work" via MSVC. Deliberately NOT proactive fingerprinting of the installed compiler (research
Finding 2 in `docs/prd-av-safe-build-path.md` already argued against that class of probing, and
Tier A already commits to trusting Nuitka's own discovery). The hint text is REACTIVE ONLY (a
static `[WARN]` after Nuitka's OWN build already failed), never a proactive nag.

---

## Standalone Python-download tier (REQ-009 Tier 5 by naming/history; executed 3rd as of the
## provider-chain reorder below, SHIPPED)

**Status: implemented 2026-07.** `:try_embed_fallback` is wired into both fallback ladders, a new
`HP_ENV_MODE=embed` value flows through every call site identified during the original design
audit (34 `HP_ENV_MODE` reference sites; re-verify line numbers before relying on them), and CI
coverage lives in `tests/selfapps_ux_hardening.ps1` (`self.embed.fallback.decline`,
`self.embed.fallback.real` -- see `docs/agent-ndjson.md`). This section maps the `HP_ENV_MODE`
blast radius this tier touches.

**Provider-chain reorder: `uv -> conda -> embed -> venv -> system`, embed moved from last-resort
to right after conda.** Originally embed was the final rung. Reordered so a user who pinned a
specific Python version via `runtime.txt`/`pyproject.toml` still gets it via a fresh checksummed
python.org download when uv/conda are unreachable, instead of silently falling back to whatever's
ambient (venv/system just wrap the ambient interpreter, they cannot acquire a different one) --
conda and embed both front-load acquisition of a FRESH/pinned interpreter; venv/system stay the
true last resort. System stays absolute final regardless (only tier gated by the REQ-014 consent
prompt). Both dispatch mechanisms encoding provider order moved together: `:handle_conda_failure`
(linear initial fallback chain, reordered venv/system/embed -> embed/venv/system) and
`:provider_cascade` (goto-based re-entrant post-warnfix cascade -- `:cascade_from_conda` now
targets `:try_embed_fallback`; new `:cascade_from_embed` + `HP_CASCADE_TRIED_EMBED` guard targets
`:try_venv_fallback`; `:cascade_from_venv` unchanged; `:cascade_from_system`/
`HP_CASCADE_TRIED_SYSTEM` deleted, since system has no cascade target now). No downstream
`HP_ENV_MODE`/`HP_ENV_READY` consumer needed to change (pure exact-string-equality / tier-agnostic
boolean) -- only the two dispatch chains moved. Tier numbering ("Tier 4"=system, "Tier 5"=embed)
was deliberately kept as a historical label, not renumbered to match execution order (the
load-bearing NDJSON ids are not tier-numbered).

**Bug found+fixed in the reorder pass: the version-swap mechanism (stage 2 below) was dead code.**
The version-check-and-swap sequence was wrapped in one parenthesized `if not errorlevel 1 ( ... )`
block; a `for /f` loop inside set `HP_EMBED_SWAP_DIR`/`_TAG`/`_MINOR`, and code later in the SAME
block read `%HP_EMBED_SWAP_DIR%` -- but CMD's parse-time `%VAR%` expansion substitutes every
`%VAR%` using the value from BEFORE the block began (the bug class in
`docs/agent-lessons-learned.md`'s "Provider-cascade dispatch is goto-based on purpose"), so the
read was always empty and the swap body never ran. No test caught it (`self.embed.fallback.real`
never requests a non-default version). Fixed via goto-based dispatch.

**Second bug (later deep-dive): a DIRECTORY move, not a FILE move -- requirement 9's swap-fix
shape does NOT transfer.** `:embed_swap_retry` checked `if exist "%HP_EMBED_DIR%\python.exe"`
after `rd /s /q "%HP_EMBED_DIR%"` + `move /y "%HP_EMBED_SWAP_DIR%" "%HP_EMBED_DIR%"`. A first pass
mirrored requirement 9's "check whether the source is gone" fix -- but that only holds for a FILE
move (atomic: fully replaces or fully fails, no third outcome). A DIRECTORY `move` onto a still-
existing destination silently NESTS the source inside it instead. If `rd /s /q` fails to fully
clear `HP_EMBED_DIR` (an AV/indexer-lock race this code already anticipates), the destination
still exists when `move` runs, so nesting occurs -- and BOTH candidate checks then read as false
success (stale `python.exe` still at the top level; `HP_EMBED_SWAP_DIR` no longer exists either,
since it got renamed into the nested subfolder, not genuinely swapped). Neither post-hoc check can
distinguish "swap succeeded" from "rd failed and the source got silently nested."

**Actual fix: gate `move` on `rd` having genuinely cleared the destination first**, so `move` only
ever runs onto a nonexistent target (pure rename, nesting structurally impossible) -- which makes a
post-hoc destination check reliable again. `:embed_swap_retry` now does `rd /s /q "%HP_EMBED_DIR%"`
then `if exist "%HP_EMBED_DIR%" goto :embed_swap_rd_failed` (skip `move`, go straight to the
retry-count check) before ever attempting `move`. **NOT CI-confirmed** -- `self.embed.fallback.real`
still never requests a non-default version through this tier, so this branch is untested by any
real CI run; the fix is static reasoning about documented Windows `move`/`rd` semantics, not a live
Windows repro. A dedicated test (pin a non-latest version through a real embed download) would be
the natural next step if this tier's trigger rate ever justifies it.

**Two-stage PowerShell/Python split (not a single script), a refinement found during
implementation.** This tier runs precisely when NO Python interpreter exists anywhere, so
per-request version-table logic cannot live in Python until *some* interpreter is on disk:
1. **PowerShell stage** (`tools/embed_extract.ps1`, `HP_EMBED_EXTRACT`) -- batch has already
   downloaded ONE hardcoded "latest" version's zip (`HP_EMBED_LATEST_PATCH`/
   `HP_EMBED_LATEST_SHA256` near the top of `run_setup.bat`). Does ONLY checksum verification
   (`Get-FileHash`), extraction (`Expand-Archive`), and the `._pth` patch (uncommenting
   `#import site`) -- zero per-request branching. Prints the extracted `python.exe` path on
   success, exits 1 silently on failure.
2. **Python stage** (`tools/embed_pyver_check.py`, `HP_EMBED_PYVER_CHECK`) -- runs under the fresh
   interpreter stage 1 just extracted. The ONLY place per-request version logic lives, reusing the
   same `PYSPEC` value `~detect_python.py` already computed (the value uv/conda already honor). If
   `PYSPEC` requests a minor other than the table's "latest," re-fetches/verifies/extracts the
   correct version itself via stdlib (`urllib.request`, `hashlib`, `zipfile`).
   `EMBED_PYTHON_TABLE` maps minor -> `(patch, sha256)` for 3.10-3.14 (5 entries, matching
   python.org's currently-supported non-EOL minors). The `"3.14"` entry's patch/sha256 MUST match
   the batch-side `HP_EMBED_LATEST_PATCH`/`HP_EMBED_LATEST_SHA256` exactly --
   `tests/test_embed_tier.py`'s `BatchPythonConsistency` test catches drift.

**Windows self-file-lock hazard (a running process cannot delete/replace its own EXE/DLLs).** The
Python stage runs FROM `HP_EMBED_DIR` (the directory stage 1 extracted into), so extracting a
version swap directly into `HP_EMBED_DIR` while that process is still running fails on file locks.
Fix: the Python stage extracts any swap into a SIBLING staging directory (`HP_EMBED_DIR` + `_swap`)
-- the actual swap (`rd /s /q` old + `move /y` new-into-place) happens in the BATCH caller, only
AFTER the `for /f ... in ('powershell ... -File "~embed_pyver_check.py" ...')` call returns (i.e.
after the Python process has fully exited and released its locks). Re-verify this ordering if the
Python stage is ever invoked differently.

**Offline-mode test-flag exception chain touches two call sites, not one.** `HP_TEST_FORCE_EMBED_
REAL=1` needs a hole punched through `HP_OFFLINE_MODE=1` at BOTH `:try_embed_fallback`'s own
offline check AND `:download_get_pip` (reused from REQ-023b, whose existing offline exception only
recognized `HP_TEST_FORCE_VENV_CREATE_FAIL`) -- extended via an intermediate
`HP_GETPIP_SKIP_OFFLINE` OR variable (batch has no clean single-line boolean OR without delayed
expansion). A future third test flag needing `:download_get_pip`'s real download must extend both
sites together.

**CMD line-length budget was hit for real.** `embed_pyver_check.py`'s first draft (docstrings,
nested-dict table) produced a 9439-char base64 line, 1248 over the 8191 hard limit. Trimmed to
6739 chars (condensed comments, inline comments instead of docstrings, tuples instead of nested
dicts) -- 1452-char margin. Re-check the budget before extending `EMBED_PYTHON_TABLE`.

**Sigstore was evaluated and rejected for integrity, in favor of embedded SHA256.** Sigstore needs
`cosign`/`sigstore-python`, which themselves need an existing Python/tool install -- circular for a
tier whose whole purpose is "no Python exists yet." Embedded SHA256 (computed once at pin-time,
verified independently against real downloads before shipping) matches this repo's "bootstrap
reliability > API correctness" principle.

**Design decisions agreed with the user:**
- No REQ-014-style consent gate -- the embeddable zip is a private, checksummed,
  bootstrapper-controlled extraction under `~embed_python\`, more REQ-010-isolated than system,
  not less. Progress logging (REQ-016-style), not a prompt.
- Version selection: a small pinned per-minor table, NOT a single hardcoded fallback and NOT a
  live python.org "latest" scrape (violates "deterministic execution > dynamic resolution," same
  reasoning as the pipreqs 0.4.13 pin). Table scope: python.org's currently-supported (non-EOL)
  minors (~5-6 entries), refreshed on the same quarterly cadence as the pipreqs pin. A request
  older than the table's floor falls back to the oldest entry with a WARN. No-request default uses
  the table's *newest* entry, mirroring uv's `UV_PYTHON_PREFERENCE=only-managed`.
- Integrity: embed the expected SHA256 per pinned version directly (computed at pin-time), never
  fetched from a checksum file over the same network path as the download.
- Two implementation gotchas: (1) the embeddable zip ships with `site` imports disabled via
  `pythonXY._pth` -- must uncomment before pip/any installed package is importable, or the tier
  looks like it succeeded while silently broken. (2) the embeddable zip has no pip -- reuse
  `:download_get_pip` (built for REQ-023b), don't write a second copy.

**Mental model: embed behaves like `venv`, not `system`.** venv and embed are both "fully
isolated, bootstrapper-installable" (safe to `pip install` into freely); system is "shared,
minimally-invasive" (installs avoided/consent-gated). Wherever code branches system out to a
restricted/no-op path, embed should NOT be excluded the same way.

**Call sites wired to a new `embed` case (current, post-reorder state -- matches "Provider cascade
execution re-enters env-create" below, which documents the same two dispatch chains in full):**
1. `:handle_conda_failure` (~line 1787) -- the initial fallback chain. `call :try_embed_fallback`
   runs right after conda itself fails, BEFORE venv/system are attempted (embed/venv/system order).
   `HP_FORCE_CONDA_ONLY=1` already short-circuits this function, so embed is auto-suppressed.
2. `:provider_cascade`'s dispatch (~line 1618-1632) -- the separate post-build warnfix cascade.
   `:cascade_from_conda` targets `:try_embed_fallback` (guard `HP_CASCADE_TRIED_EMBED`); a new
   `:cascade_from_embed` targets `:try_venv_fallback`. System has NO cascade target of its own
   (`:cascade_from_system` was deleted in the same reorder -- system is terminal). Per the
   no-loop-guarantee rule: each guard var is mandatory and the order stays monotonic.
3. **New subroutine `:try_embed_fallback`** -- mirrors `:try_venv_fallback`/`:try_system_fallback`'s
   shape, called from both sites above. On success: `HP_ENV_MODE=embed`, `HP_PY=<extracted
   pythonXY.exe>`, `HP_BOOTSTRAP_STATE=embed_env`, leaves `HP_SKIP_PIPREQS` UNSET (matching venv,
   not system -- system's `HP_SKIP_PIPREQS=1` exists specifically to avoid `pip install pipreqs`
   into a shared environment, which doesn't apply to embed's private extraction), logs `[BOOT]
   REQ-009: Selected Python provider: Embedded Python (python.org).`, `exit /b 0`.
4. Dependency-install branch in `:after_env_mode_selection` (~line 1258-1303) -- **the single most
   important site**: the final catch-all `else` is reached by `system` mode ON PURPOSE (no-install
   for a shared environment) but would ALSO silently catch `embed` if no new branch is added,
   leaving embed with zero installed deps, relying 100% on the warnfix safety net. Added
   `else if "%HP_ENV_MODE%"=="embed" (...)` before the catch-all, same body as `venv` (plain
   `"%HP_PY%" -m pip install -r requirements.txt`).

**Call sites that already worked automatically, zero change needed** (individually verified): the
pipreqs-install/heuristic-augmentation/pip-freeze-capture/PyInstaller-install uv-vs-else branches
(each plain-else already works once embed's pip is bootstrapped); `:compute_collect_flags`'s
system-only exclusion (embed never matches `"%HP_ENV_MODE%"=="system"`, confirmed by omission);
the REQ-007 "build under every provider except system" gate; `:append_env_mode_row`'s NDJSON
emitter (reads `HP_ENV_MODE` dynamically); both `%HP_ENV_MODE%`-interpolating smoke-test log
lines; `:conda_base_update`'s conda-only guard. Dep-check's fast-path gate (`if not
"%HP_ENV_MODE%"=="conda" if not "%HP_ENV_MODE%"=="uv" goto :dep_check_done`) **deliberately**
still excludes embed too, matching venv's scope -- a design choice for MVP parity, not an
oversight; could extend to embed later if desired.

**Pre-existing gap found during this audit, unrelated to embed, flagged not fixed:** the warnfix
REPAIR-install branch (~line 2661) only has two cases -- `if "%HP_ENV_MODE%"=="uv"` and
`else if defined CONDA_BAT` -- with NO plain-pip fallback for any other mode. venv and system
ALREADY had this blind spot (warnfix-detected missing modules under either mode match neither
branch, so the repair loop is a no-op). Confirmed unchanged after shipping embed (this branch
wasn't touched) -- embed inherits the identical gap. Worth a dedicated future fix (a plain
`%HP_PY% -m pip install` catch-all covering venv/system/embed) -- its own backlog item.

---

## uv-First Provider Architecture

The "uv-first" feature (skip Miniconda download when uv can provide Python) has a larger blast
radius than it appears -- this section documents how it touches test infrastructure.

### Provider selection flow (run_setup.bat)

```
HP_FORCE_CONDA_ONLY=1 -> always go through Miniconda; uv is never tried as primary
HP_TEST_FORCE_UV_FAIL=1 -> fires at line 296 (BEFORE cached-uv check at 302); uv never used
HP_UV_PROVIDING_PYTHON=1 -> set when uv successfully detects Python; gates Miniconda skip
```

When `HP_UV_PROVIDING_PYTHON=1`:
- Miniconda is NOT downloaded or installed
- `:select_conda_bat` (line 398) runs, but `%PUBLIC%\Documents\Miniconda3\condabin\conda.bat`
  does not exist on disk, so `CONDA_BAT` is never set
- The corruption check at line 442 (`if defined CONDA_BAT ...`) never fires
- All conda-dependent bootstrap paths are bypassed

### Provider cascade execution re-enters env-create (REQ-009/REQ-005.10 slice 3)

`:provider_cascade` (reached from the main line via `if defined HP_CASCADE_APPROVED goto
:provider_cascade`, just after `:run_entry_smoke` returns) re-attempts the dependency phase under
the next provider tier. **It does not re-implement env-create -- it reuses the existing paths**,
so anyone touching those paths must understand the cascade re-entry:

- `uv -> conda`: sets `HP_ENV_MODE=conda`, clears `HP_UV_PROVIDING_PYTHON`, sets
  `ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%`, `goto :try_conda_create`. Because uv-first runs
  skipped Miniconda, `:cascade_acquire_conda` downloads+installs it on demand
  (`MINICONDA_ROOT`/`CONDA_MAIN`/`CONDA_ALT` are already set near line 410 even in uv-first runs).
  `:try_conda_create` ends with `goto :after_env_mode_selection`, re-running dep install + build.
- `conda -> embed` (reordered from `conda -> venv`): `call :try_embed_fallback`, then
  `goto :after_env_mode_selection`. Suppressed when `HP_FORCE_CONDA_ONLY=1`. No
  `HP_OFFLINE_MODE`/consent gate of its own (mirrors venv's zero-friction treatment, not system's).
- `embed -> venv` (new edge): `call :try_venv_fallback`, then `goto :after_env_mode_selection`.
- `venv -> system`: `call :try_system_fallback`, then `goto :after_env_mode_selection`. **Reached
  in any run** -- the only gate is the REQ-014 consent prompt inside `:try_system_fallback` (no env
  flag; `HP_ALLOW_SYSTEM_FALLBACK` is deprecated/ignored). In CI the gate auto-declines
  (`HP_CI_LANE`, or explicit `HP_TEST_SYSCON_ANSWER=N`), so the cascade stops at system without
  entering it. `HP_FORCE_CONDA_ONLY=1` suppresses embed/venv/system upstream. System has no
  cascade target of its own (`:cascade_from_system` was deleted when this reorder made system
  terminal instead of embed; a re-entry with `HP_ENV_MODE=system` falls straight through to the
  "tiers exhausted" catch-all).

**No-loop guarantee (touch one, understand all):** each tier is marked `HP_CASCADE_TRIED_<tier>`
the first time it is used as a cascade source, and `HP_ENV_MODE` only ever advances
(uv->conda->embed->venv->system). Re-entry therefore cannot revisit a tier, and tiers exhaust to a
"keeping current build" terminal. If you add a new provider or reorder tiers, you MUST add a
matching `HP_CASCADE_TRIED_*` guard and keep the order monotonic, or the cascade can loop.

**`:after_env_mode_selection` re-entrancy:** the cascade relies on this label being safe to
re-enter (it recomputes REQ/DEP_SOURCE/entry/pyproject state from scratch). The EXE fast path
(`:try_fast_exe`, top of file) is NOT re-run on cascade, and `:run_entry_smoke`'s rebuild-skip
is gated on `HP_FASTPATH_USED` (unset on a fresh first build), so the next tier genuinely
rebuilds. Do not introduce first-run-only state into `:after_env_mode_selection` without
making it idempotent.

**`runtime.txt` write-back (REQ-004) can poison a `uv -> conda` cascade re-entry with an
unsatisfiable exact version pin -- found via real CI evidence, CLAUDE.md Item 24.** Write-back
(`:write_runtime_txt` and its two inline duplicates at `:conda_create_done`/
`:env_state_fast_path`) fires the moment ANY provider's own env setup succeeds, writing the
EXACT patch version that provider's interpreter reports (`~print_pyver.py`) to `runtime.txt` and
reassigning `PYSPEC` to match -- intended so a plain re-run reuses the same, proven-working
version. This interacts badly with cascade re-entry specifically because `:after_env_mode_
selection` (see re-entrancy note above) recomputes `PYSPEC` from scratch on EVERY tier, which
means a SUBSEQUENT provider's own env-create call receives the PREVIOUS provider's exact patch
pin, not its own. Confirmed via a real `self.layered_e2e.chain` cache-lane run
(2026-08-07): uv resolved `python-3.14.7`, write-back wrote that to `runtime.txt` the moment
uv's venv succeeded, then the uv->conda cascade (pygrib still failing to build under uv) re-
derived `PYSPEC=python=3.14.7` from that same freshly-written file and forwarded it verbatim to
`conda create ... python=3.14.7 ...` -- but conda-forge's own `python` package release cadence is
a wholly separate index from CPython's/uv's, and did not carry that exact patch:
`PackagesNotFoundInChannelsError: python=3.14.7`, a hard `conda env create failed.`, and the
cascade fell through embed -> venv without ever reaching a real conda environment (so pygrib was
never built, and Item 24's own `:dll_bundle_recover` loop was never exercised at all in that run,
regardless of its own correctness).

**Fixed with a new `HP_PYSPEC_WRITEBACK` flag**, set at all 3 sites where write-back reassigns
`PYSPEC` (immediately after each `set "PYSPEC=%PYVER:python-=python=%"` line) -- distinct from
`HP_RUNTIME_TXT_PREEXIST`, which only tracks whether the FILE existed before this run started,
not whether write-back has since overwritten its contents with a provider-specific artifact.

**Refined same day, before real CI ever confirmed the first version, in response to a maintainer
question and an independent CodeRabbit finding that converged on the same gap**: the maintainer
asked whether "how did this ever work" pointed at a genuinely SEPARATE gap for a plain subsequent
run (not just the same-run cascade), and whether backing off write-back's own precision would also
help; separately, CodeRabbit flagged that unconditionally dropping to "no constraint" on cascade
also discards a genuine, user-authored `pyproject.toml`/PEP 723 `requires-python` range whenever it
happens to coexist with a write-back-derived `PYSPEC` in the same run. Both were investigated
together:
- **The "subsequent run" concern turned out to already be handled, by pre-existing code unrelated
  to this fix.** `tools/detect_python.py`'s `read_runtime_spec()` (the canonical source for
  `HP_DETECT_PY`, invoked at the START of every fresh bootstrap process to derive `PYSPEC` from
  `runtime.txt`) already truncates ANY version string it finds down to major.minor
  (`major_minor = '.'.join(parts[:2])`) before ever returning a `python=X.Y` constraint -- it does
  not matter whether `runtime.txt`'s content came from write-back (`python-3.14.7`) or a genuine
  hand-authored file; a fresh, separate invocation of `run_setup.bat` never sees the exact patch,
  only `python=3.14`. This means the on-disk file can legitimately keep recording the exact,
  proven-working patch (useful documentation for the user) without that precision ever reaching a
  provider's create/venv command on a later, separate run -- no write-side change was needed for
  this half of the question. The ONLY place the untruncated patch leaks through as a hard
  constraint is the SAME-process in-memory `PYSPEC` variable reused during a cascade re-entry
  WITHIN one bootstrap run, which bypasses this file-read/truncation path entirely (the value is
  already sitting in a shell variable, never re-derived from disk) -- exactly the gap
  `HP_PYSPEC_WRITEBACK` already targets.
- **CodeRabbit's finding was real and is now fixed via a new `HP_PYSPEC_ORIGINAL` snapshot.**
  Immediately before each of the 3 write-back sites reassigns `PYSPEC`, it now also does
  `set "HP_PYSPEC_ORIGINAL=%PYSPEC%"` -- capturing whatever constraint existed at that exact moment
  (a genuine pyproject.toml/PEP 723 range if Tier 2 applied, or empty if Tier 3/no constraint;
  never anything write-back-derived itself, since this snapshot always runs before the very first
  write-back of the run). `:try_conda_create` now computes `HP_CONDA_PYSPEC_USE` (`%PYSPEC%`
  normally, `%HP_PYSPEC_ORIGINAL%` when `HP_PYSPEC_WRITEBACK` is defined) instead of unconditionally
  dropping to "no constraint" -- a genuine user-authored range still reaches conda's solver on
  cascade; only the bad exact pin is discarded, and the "no constraint" fallback now applies solely
  when there was never a real constraint to begin with (`HP_PYSPEC_ORIGINAL` empty too).
- **A genuine, independent pre-existing bug found while making this change, and fixed in the same
  pass: `%PYSPEC%` was used UNQUOTED on both `conda create` command lines.** A PEP 440 range (e.g.
  `python>=3.10,<4`, exactly what `HP_PYSPEC_ORIGINAL` now forwards more often than before) contains
  live `<`/`>` characters -- unquoted on a cmd.exe command line, these are parsed as real
  redirection operators, corrupting the `conda create` invocation (this predates the current
  session's changes entirely; a plain, non-cascade first run with a `requires-python = ">=3.10,<4"`
  pyproject.toml would already have hit this against the ORIGINAL, unmodified code). Fixed by
  quoting both call sites (`"%HP_CONDA_PYSPEC_USE%"`), mirroring the already-established
  `HP_UV_PY_REQ` pattern (quoted at its own `uv venv --python` call site -- see the "`:log` echoes
  UNQUOTED" entry in `docs/agent-lessons-learned.md` for the general rule this follows).

The two-variable split (`HP_PYSPEC_WRITEBACK` set once at write-back time; `HP_CONDA_PYSPEC_USE`/
`HP_CONDA_PYSPEC_SKIP` computed once at `:try_conda_create` entry, reused by both the initial
attempt and the REQ-022 transient retry) avoids re-deriving the same decision twice. **NOT YET
CONFIRMED in real CI** -- same status as the base `HP_PYSPEC_WRITEBACK` fix; needs a fresh
`cache`-lane `self.layered_e2e.chain` run to confirm `chainPass:true` before this can be considered
settled (that test's own fixture uses a Tier 3/no-constraint pyproject, so it does not by itself
exercise the `HP_PYSPEC_ORIGINAL` range-preservation path -- only the base drop-to-unconstrained
behavior; the range-preservation and quoting fix are verified by reasoning and local tooling only
so far, not a real-CI-observed range-constrained cascade).

**Why this doesn't (yet) need the same fix for the embed tier's own PYSPEC-driven version
lookup**: `tools/embed_pyver_check.py` also reads `PYSPEC` to pick which pinned table entry to
download (see "Standalone Python-download tier" above), so a write-back-derived exact patch
COULD in principle also reach an embed-tier cascade target with the same class of mismatch. Left
unfixed for now because embed's own table lookup already degrades gracefully for an unknown/
below-floor request (falls back to the table's oldest/newest entry with a WARN, never a hard
failure) -- unlike conda's solver, which fails outright on an unresolvable exact pin. Revisit if
a real CI run ever shows this actually misbehaving for the embed tier specifically; not assumed
from the conda case alone.

### uv uses managed-only CPython (UV_PYTHON_PREFERENCE)

`run_setup.bat` sets `UV_PYTHON_PREFERENCE=only-managed` at the top of the uv acquisition
block (before the `PVW_UV_EXE` branch and before the first uv invocation). Consequences that
ripple across components:
- Every uv command in the bootstrapper process (`uv run` detect, `uv venv`, `uv pip`)
  inherits it; uv never selects an ambient/system/conda interpreter.
- With no user constraint, `.uv_env` is the latest managed CPython; a user
  `runtime.txt`/`pyproject.toml` is still forwarded via `uv venv --python X.Y`.
- Tests that read the resulting `.uv_env` (e.g. `self.uv.managed.interpreter` in
  `selfapps_envsmoke.ps1`) depend on this; `harness.ps1` also statically asserts the `set`
  line via `uv.python.preference.configured`. The rationale and the embedded-helper Python
  baseline live in `docs/agent-lessons-learned.md`.

### Lanes and their conda state

| Lane | HP_FORCE_CONDA_ONLY | uv used | Miniconda installed | CONDA_BAT set |
|------|---------------------|---------|---------------------|---------------|
| conda-full | 1 | no | yes | yes |
| real | not set | yes (uv-first) | no | no |
| cache | not set | yes (uv-first) | maybe (cached) | maybe |
| justme-test | not set | no (HP_TEST_FORCE_UV_FAIL=1) | via JustMe | yes |
| contract-uv | not set | yes (forced) | no | no |
| uv-dl-fallback | not set | yes (HP_TEST_UV_DL_FALLBACK=1 forces primary URL fail, fallback URL used) | no | no |

### Test files that assume conda is present -- skip=true pattern required

These test files call `Get-CondaBatPath` and use the result to run conda-specific operations.
When conda is absent AND `HP_FORCE_CONDA_ONLY != '1'`, they MUST emit `skip=true` rows
instead of failures. When `HP_FORCE_CONDA_ONLY == '1'`, they MUST emit `pass=$false`
(conda is supposed to be there in that lane).

**Sweep completed (2026-06-20): only 3 files use `Get-CondaBatPath`; all other selfapps files
run the full bootstrapper or are lane-guarded (see notes below).**

| Test file | Affected rows | Skip guard added? |
|-----------|--------------|-------------------|
| `tests/selfapps_reqspec.ps1` | reqspec.translate.*, reqspec.conda.*, reqspec.install.import, reqspec.gte.explicit, reqspec.ingest.* | YES (current) |
| `tests/selfapps_pyproject_precedence.ps1` | pyproject.precedence.detect, pyproject.dep.detect, pyproject.dep.noproj | YES (current) |
| `tests/selftest.ps1` | self.corrupt.conda.detect, self.corrupt.conda.heal.decline, self.corrupt.conda.heal.accept | YES -- guards on `$condaBatOnDisk` |
| `tests/selfapps_pandas_excel.ps1` | pandas_excel.translate, pandas_excel.conda.install, pandas_excel.conda.install.req006, pandas_excel.runtime, self.pandas.openpyxl.install, self.pandas.openpyxl.import | YES (current) -- all 6 rows |
| `tests/selfapps_envsmoke.ps1` | self.env.smoke.conda, self.env.smoke.uv | NOT NEEDED -- already uv-aware via `$isUvMode = Test-Path .uv_env\Scripts\python.exe`; self.env.smoke.conda tests full bootstrapper; self.env.smoke.uv has explicit skip logic when uv not acquired or fell back to conda |
| `tests/selfapps_pipgap.ps1` | pipgap.conda.miss, pipgap.pip.fill | NOT NEEDED -- test sets `$env:HP_FORCE_CONDA_ONLY = '1'` (line 66) before running run_setup.bat; always in conda mode |
| `tests/selfapps_depcheck.ps1` | self.depcheck.install, self.depcheck.skip | NOT NEEDED -- dep-check runs in both conda AND uv mode (`HP_ENV_MODE` guard at run_setup.bat line 1048); in uv mode, `~environment.lock.txt` is written by copying `~dependency_installed.txt` (run_setup.bat lines 1141-1145) |
| `tests/selfapps_warnfix.ps1` | self.exe.warnfix.* | NOT NEEDED -- runs full bootstrapper; warnfix is a PyInstaller post-build phase in run_setup.bat that uses pip/conda within the bootstrapper's own install logic; no direct conda bat calls in test |
| `tests/selfapps_justme.ps1` | conda.install.justme | NOT NEEDED -- only runs in justme-test lane where HP_TEST_FORCE_UV_FAIL=1; conda always present via JustMe install |
| `tests/selfapps_ux_hardening.ps1` | self.ux.* | NOT NEEDED -- runs full bootstrapper; references conda only in a comment |

The `pyproject.precedence.writeback` test runs the FULL bootstrapper (which uses uv in
uv-first lanes) and does NOT require conda to be present. It is NOT in the "needs guard" list.

### EXE fast path vs env-state fast path vs uv venv reuse

Three distinct "fast" paths exist in run_setup.bat. They serve different purposes and
produce different log lines. Future agents must not confuse them:

| Fast path | Trigger | Log line | Lane |
|-----------|---------|----------|------|
| EXE fast path (`:try_fast_exe`) | `dist\<ENVNAME>.exe` exists AND `HP_FAST_CHECK` token = "fresh" | `[INFO] Fast path: reusing dist\<ENVNAME>.exe` (non-interactive/CI -- `HP_INTERACTIVE_RUN` unset) or `[INFO] Launching your program now via the cached standalone EXE (PyInstaller build): dist\<ENVNAME>.exe` (interactive -- see "Fail-fast probe (Slice 2b-C)" below) | All lanes |
| Env-state fast path (`:env_state_fast_path`) | `~env.state.json` valid, conda env python.exe present | `[INFO] Env-state fast path: reusing conda env <ENVNAME>.` | conda mode only; skipped when HP_UV_PROVIDING_PYTHON=1 |
| uv venv reuse | `.uv_env\Scripts\python.exe` exists AND `import pip` succeeds | `[INFO] uv: reusing existing .uv_env` | uv mode only |

**Critical order**: EXE fast path runs at line 222 (top of file, BEFORE provider selection).
If it fires, run_setup.bat goes directly to `:success`. uv/conda provider logic is never reached.
The env-state check (line 507) and uv venv reuse (line 544) are therefore only reached when
the EXE fast path does NOT fire (first run, or sources changed).

**`self.fastpath` test** (`selfapps_envsmoke.ps1` second run): matches `'Fast path: reusing'`
which appears in the EXE fast path log line ONLY on the non-interactive branch (real CI always
sets `HP_CI_LANE` at the job level, so this holds in every CI lane regardless of whether the
individual test file pins it locally -- see the "Accepted gap" entry in
`docs/agent-lessons-learned.md`). This works in ALL lanes (uv and conda) because the EXE fast
path is completely provider-independent. The test correctly validates the EXE fast path, not
the env-state or uv venv fast path.

### ~dependency_installed.txt: pip freeze output and its consumers

`~dependency_installed.txt` is written after install via `pip freeze` (run_setup.bat lines 1122-1134):
- uv mode: `uv pip freeze --python "%HP_PY%"`
- conda/venv mode: `"%HP_PY%" -m pip freeze`

**Consumers:**
- `selfapps_pipgap.ps1`: reads `~dependency_installed.txt` to check `opencv-python` was installed
- `~environment.lock.txt` (uv mode): `copy /y "~dependency_installed.txt" "~environment.lock.txt"` (line 1145)
- The dep-check (`~dep_check.py`) reads `~environment.lock.txt` (either conda list --export or pip freeze copy)

### warnfix install + uv mode

When `HP_ENV_MODE=uv`, the warnfix repair loop (run_setup.bat lines 2055-2062) uses
`uv pip install --python "%HP_PY%" %%M` for each missing module. When `HP_ENV_MODE=conda`,
it uses `conda install -y -n "%ENVNAME%"`. PyInstaller is also installed via
`uv pip install --python "%HP_PY%" -q pyinstaller` in uv mode (line 2018).

This means `selfapps_warnfix.ps1` works correctly in uv-first lanes without any guard:
the full bootstrapper handles the uv/conda split internally. The test only checks for log
phrases (`[REPAIR] missing modules detected`) and EXE success, both of which work in uv mode.

### autopep723 discovery merge (REQ-005.12, Tier 1) sits inside the pipreqs diff-computation block

`:after_pipreqs_run` (`run_setup.bat` ~line 1258) is the shared fallthrough every pipreqs code
path funnels to (success/skip/failure all `goto` here). The Tier 1 block
(docs/plan-autopep723-two-tier.md) is inserted immediately after the REQ-005.5 `fc`-based diff
computation's `[INFO] REQ-005.5: dependency source diff computed` log line, and immediately before
the dep-check fast-path reset (`set "HP_DEP_SKIP="`) -- **re-verify this block still sits between
those two neighbors on any future edit**: it depends on `requirements.txt` already being
finalized by pipreqs (or copied from `requirements.auto.txt`), and on running strictly before
`HP_DEP_SKIP`/`HP_DEP_RESULT`/`HP_UV_INSTALL_OK` are reset for the dep-check fast path below it.

**v1-scoped to `HP_ENV_MODE=uv` only.** Computes `HP_UVX_EXE` unconditionally (cheap string
substitution, `%HP_UV_EXE:uv.exe=uvx.exe%`) but only invokes it when `HP_ENV_MODE` is `uv` AND
`HP_ENTRY` is defined AND the derived `uvx.exe` path exists on disk -- the last check makes the
block a silent no-op under conda/venv/system/embed (where `HP_UV_EXE` is empty). **`HP_UVX_EXE` is
derived from `HP_UV_EXE`, not `HP_UV_BIN` directly** -- matters for the `PVW_UV_EXE` override
(~line 449): when set, `HP_UV_BIN` never gets a `uvx.exe` extracted at all, so deriving from
`HP_UV_BIN` would silently break Tier 1 under that override.

**Writes to `requirements.txt`, not `requirements.auto.txt`**: the unconditional pip gap-fill step
later (`%HP_PY% -m pip install -r requirements.txt`) reads the merged file regardless of whether
the dep-check fast path fires, so anything Tier 1 adds is installed either way. Accepted
trade-off: on a repeat run where the fast path fires, an autopep-only-discovered package always
goes through pip rather than conda (mirrors the existing "pip gap-fill safety net" pattern).

**Never gates the lane, in practice.** The merge helper (`tools/autopep_merge.py`/
`HP_AUTOPEP_MERGE`) is purely additive -- never removes/reorders existing `requirements.txt`
content, and a missing/empty `requirements.autopep.txt` is a silent no-op. Every normal/expected
path (no-op, successful merge) returns 0. **Correction: the module's own "never raises, always
exits 0" docstring claim is not literally true** -- `existing_names()`'s `open()` and `main()`'s
own trailing-newline/append `open()` calls are NOT wrapped in `try/except OSError` (unlike
`extract_autopep_deps()`, which is), so a genuine OSError there (permission denied, disk full, a
TOCTOU race between `os.path.exists()` and `open()`) propagates uncaught and exits nonzero via
Python's default uncaught-exception handling. `run_setup.bat` never treats this as fatal either
way -- the pipreqs-derived `requirements.txt` from earlier in the same flow is already on disk
and usable regardless of whether this merge step completes, so the bootstrap simply continues
with pipreqs-only results on that rare failure.

### HP_PVW_KNOWN_IDEMPOTENT execute-mode discovery (REQ-005.13, Tier 2) hooks in earlier than Tier 1

`:pvw_known_idempotent_run` (~line 3289) is called from a gate right after `:determine_entry`
returns (~line 980), BEFORE the pyproject.toml/PEP 723 header/pipreqs block even begins --
earlier than Tier 1's own `:after_pipreqs_run` insertion, deliberately: Tier 2's premise is "skip
static discovery, use execution instead," so it must run before any static source populates
`requirements.txt`. Needs no PEP-723-awareness of its own -- `uvx autopep723 <entry>` already
respects an existing header (uses declared deps to set up the run, only surfaces something new via
a real `ModuleNotFoundError` at runtime).

**`HP_UVX_EXE` is computed a second time here, independently of Tier 1's copy** -- Tier 2's gate
is earlier in the file, so it cannot reuse Tier 1's variable (intentional duplication of a cheap
string substitution, not a bug to consolidate).

**Design wrinkle: `uv add --script` only updates the PEP 723 header, not `requirements.txt`.** A
naive "run, persist, continue" would leave `requirements.txt` empty, since everything downstream
operates on that file, never the header directly. Fixed by reusing the already-existing
`:extract_pep723_requirements` subroutine (same one the pre-existing-header case uses) to
re-extract the just-updated header into `requirements.txt` after a successful Tier 2 run.

**Deliberately does NOT set `HP_SKIP_PIPREQS`** (unlike `selfapps_pvw_idempotent.ps1`'s own
test-only isolation) -- production Tier 2 leaves pipreqs free to run normally afterward: additive
layering, not replacement. Tier 2 anchors `requirements.txt` with what execution-based discovery
found; pipreqs/Tier 1's own later merge still gets its normal chance to catch anything a single
execution path didn't exercise (e.g. a conditionally imported module on an unhit branch).

**Only stderr is redirected when the batch caller captures the helper's result marker, never
stdout.** `tools/pvw_known_idempotent.py`'s `run_script()` leaves the child `uvx autopep723
<entry>` process's stdio fully inherited (no `capture_output`) so the user's script output prints
live -- the entire point of "execute-mode." Its own `RAN:<detail>`/`ERROR:<reason>` marker is
therefore printed to **stderr**, not stdout -- redirecting the batch call's stdout instead would
silently swallow the user's live output into a throwaway file. `tests/selfapps_pvw_idempotent.ps1`
guards this directly: asserts the stub app's `print()` output appears in the bootstrap log, not
just that the run "succeeded."

**`run_script()`'s live execution is bounded by a 120s timeout, found missing via a bug-hunt and
fixed.** This genuinely runs the user's entry script (not a smoke test) -- unlike
`discover_dep_names()`/`persist()` in the same file (60s/120s timeouts), it originally had none. A
GUI-mainloop app or a script blocking on `input()` would hang this call, and therefore the whole
bootstrap, forever, since this runs before any build/verification phase. Distinct from the "never
kill the user's real run" principle covering `:run_failfast_probe`'s later verification runs (see
"Fail-fast probe" below) -- that protects the run producing the actual deliverable; this is a
throwaway discovery pass that happens twice more anyway. On timeout, `run_script()` returns `1`
(routes through `main()`'s existing "other nonzero" retry branch) rather than raising --
`tests/test_pvw_known_idempotent.py`'s `RunScript` class asserts the timeout and the clean
`subprocess.TimeoutExpired` catch.

**Double-execution under this flag is intentional, not a REQ-018 gap.** The script runs once here
(ephemeral `uvx` venv, discovery) and again later during the normal PyInstaller EXE build's
smoke-test verification (real, persistent environment, producing the deliverable).
`HP_PVW_KNOWN_IDEMPOTENT`'s own name is the user's explicit consent to this -- REQ-019's "flags
only suppress or add an opt-in behavior, never gate the default" already covers it.

**Never gates the lane.** Any nonzero outcome is logged `[WARN]` and the subroutine returns 0
unconditionally -- the Default Path picks up exactly as if the flag had never been set.

### PEP 723 write-back (REQ-005.11) touches two hook points and the warnfix/lock flow

`:pep723_writeback` (called from two sites) is deliberately narrow -- v1-scoped to
`HP_ENV_MODE=uv` only -- but both call sites sit inside code this section and the one above
already document, so a future change to either must re-check this feature too:

- **Fresh-install trigger, at `:lock_done`** -- the shared fallthrough for both conda/uv
  dependency-install paths (see "Provider cascade execution re-enters env-create" above for the
  `:after_env_mode_selection` re-entrancy this label already handles). `call :pep723_writeback
  fresh` sits immediately after `:lock_done`, before the pyvisa/visa detection block -- the v1
  scope gate (`if not "%HP_ENV_MODE%"=="uv" exit /b 0`, first line) makes this a no-op on conda
  without an extra call-site guard.
- **Warnfix trigger, inside the warnfix repair block.** `call :pep723_writeback warnfix` sits
  between the `[REPAIR] rebuild complete after warnfix.` log line and the `:warnfix_cascade_detect`
  call -- `~missing_modules.txt`/`~warnfix_repair_failed.flag` are both still on disk at that
  exact point (deleted a few lines later). This call sits inside the same
  `if defined HP_WARNFIX_NEEDED ( ... )` block as the `for /f` loops that populate those files, but
  is safe from the parse-time-`%VAR%`-expansion trap (see `docs/agent-lessons-learned.md`
  "Provider-cascade dispatch is goto-based on purpose") only because it passes a literal argument
  (`warnfix`) and reads the two files via runtime `if exist` checks inside its OWN call frame, not
  via `%VAR%` substitution in the outer block.
- **`HP_UV_INSTALL_OK` reset lives in `:after_env_mode_selection`'s existing reset block**,
  alongside `HP_DEP_SKIP`/`HP_DEP_RESULT` (same re-entrancy reasoning: a stale
  `HP_UV_INSTALL_OK=1` from an abandoned uv attempt must never silently satisfy a later cascade
  tier's fresh-trigger gate). Set to `1` in exactly two places in the uv install branch: the
  genuine-install-succeeded `else` branch, and the `HP_DEP_SKIP`-short-circuited branch
  (already-satisfied-by-lock is a confirmed-installed state, not a failure).
- **Packages-file staging is a plain `copy`, not a re-derivation.** Copies whichever source file
  the trigger implies (`requirements.txt` for fresh, `~missing_modules.txt` for warnfix) to
  `~pep723_pkgs.txt` and hands it to the embedded helper. "All-or-nothing per round" design
  (`docs/plan-pep723-writeback.md` Part 2.0 point 3): neither trigger point can know which subset
  of a failed bulk install actually succeeded, so a failed round skips write-back entirely rather
  than guessing a partial set.
- **v1 does not touch venv/conda/embed/system modes at all.** A future extension would need a
  mechanism analogous to `HP_UV_INSTALL_OK` per provider, plus a matching v1 scope-gate
  relaxation in `:pep723_writeback`'s first line -- currently the single point controlling the
  feature's entire footprint.

### dep-check + uv mode lock file interconnection

`~environment.lock.txt` is the dep-check cache key: conda mode writes it via `conda list
--export`; uv mode writes it by copying `~dependency_installed.txt` (lines 1141-1145). This is
why `selfapps_depcheck.ps1` works in uv-first lanes -- the lock exists after run 1, so dep-check
on run 2 finds all packages already in it and emits the skip log line.

`dep_check.py` runs for BOTH `HP_ENV_MODE=conda` and `HP_ENV_MODE=uv` (line 1048: `if not
"%HP_ENV_MODE%"=="conda" if not "%HP_ENV_MODE%"=="uv" goto :dep_check_done`) -- skipped entirely
for venv/system (no lock written, no skip check). `HP_DEP_SKIP` is honored in uv mode too (line
1108 guards the `uv pip install` call), so second-run dep-check skips pip install as well.

### HP_TEST_FORCE_UV_FAIL and HP_TEST_CORRUPT_UV interaction

`HP_TEST_FORCE_UV_FAIL=1` fires at line 296, BEFORE the cached-uv check at line 302 where
`HP_TEST_CORRUPT_UV` fires -- if both are set, FORCE_UV_FAIL wins and CORRUPT_UV never triggers.
Fix (`tests/selftest.ps1`): the corrupt-uv sub-bootstrap saves/clears/restores
`HP_TEST_FORCE_UV_FAIL` so the corrupt-uv branch is exercised in all lanes.

### Malformed pyproject.toml + uv venv failure (uv-first lanes)

`uv venv` reads `pyproject.toml` for `[project].requires-python` even without `--python`; a
malformed TOML makes it exit non-zero. In the uv-first real lane (no conda installed), this
cascades: `:uv_venv_fail` falls to `:try_conda_create`, `CONDA_BAT` is empty, conda create also
fails, bootstrap exits non-zero.

**Symptom**: `self.pyproject.malformed` fails in real/cache lanes. **Root cause**: `uv venv` runs
in the project directory and hits the malformed TOML before `HP_PYPROJ_DEPS` gets a chance to
detect and warn. **Fix** (`:uv_venv_fail`): when `HP_UV_PROVIDING_PYTHON=1`, retry via `uv run
--no-project python -m venv .uv_env`, which bypasses project discovery entirely; on success go to
`:uv_venv_ready`, and `HP_PYPROJ_DEPS` then naturally detects the malformed TOML and emits
`[WARN] pyproject.toml TOML parse error; falling back.`

**`UV_NO_CONFIG=1` does NOT help** -- uv's own docs: pyproject.toml `[project]` metadata (e.g.
`requires-python`) is still used to guide resolution regardless. Only `--no-project` truly
bypasses pyproject.toml discovery. **`~detect_python.py` reads pyproject.toml via REGEX** (not a
TOML parser), so it exits 0 even on malformed TOML (returns empty string) -- `HP_UV_PROVIDING_
PYTHON=1` is set correctly, and venv creation is the actual first point of failure.

**Malformed TOML regex fallback** (must not assume `tomllib`; see the embedded-helper Python
baseline in `docs/agent-lessons-learned.md`): `re.search(r'^\[project\s*$', txt, re.MULTILINE)`
matches `[project` missing its closing `]` at end of line (optional whitespace/CRLF), exits 2 so
the caller emits WARN. No false positives for sub-tables like `[project.urls]` (`\s*$` requires
end of line right after `project`).

**Test assertion** (`tests/selftest.ps1` lines 599-643, all lanes, no HP_FORCE_CONDA_ONLY): row
`self.pyproject.malformed` asserts `[WARN] pyproject.toml TOML parse error` in log AND `exitCode
== 0`. In conda-full, malformed TOML is detected by HP_PYPROJ_DEPS (conda create doesn't read
TOML); in uv-first, the `:uv_venv_fail` retry lets the bootstrap continue so HP_PYPROJ_DEPS runs.

### HP_FORCE_CONDA_ONLY as a test-override pattern

Some tests that specifically test conda behavior SET `HP_FORCE_CONDA_ONLY=1` themselves rather
than relying on the CI lane -- self-contained, work in all lanes (triggering Miniconda download
in uv-first lanes if not already installed):

| Test | Why it sets HP_FORCE_CONDA_ONLY=1 |
|------|-----------------------------------|
| `selfapps_pipgap.ps1` (line 66) | Must test conda bulk fail + pip gap-fill path; conda is required for the bulk fail path |
| `tests/selftest.ps1` conda_retry block (line 939) | Must test conda bulk transient network retry; conda path required |
| `tests/selftest.ps1` conda_perpkg block (line 978) | Must test conda per-package fallback; conda path required |

Contrast these with tests that SKIP when conda is absent (reqspec, pyproject_precedence, pandas_excel):
those tests test non-conda-specific behaviors (translation, pyproject parsing) but happen to call
conda. They emit `skip=true` when conda is absent rather than triggering a download.

The distinction: if the test IS testing conda behavior -> force it; if the test happens to USE conda
as a side effect but is testing something else -> skip=true in uv-first lanes.

### HP_UV_BIN locality: why offline sub-bootstrap tests work in all lanes

`HP_UV_BIN` is set to `%HP_SCRIPT_ROOT%~uv_bin` (line 290), where `HP_SCRIPT_ROOT` is the
bootstrapper's own directory, not a system temp or user-global path. Consequence: when a test
creates a fresh temp directory and copies `run_setup.bat` into it, the sub-bootstrap's
`HP_SCRIPT_ROOT` is that new temp dir, so `HP_UV_BIN` = `~selftest_foo\~uv_bin\` (empty, no
uv.exe); combined with the test's own `HP_OFFLINE_MODE=1` (blocks re-download), uv is ALWAYS
unavailable in the sub-bootstrap.

This makes the fallback chain tests in `selfapps_ux_hardening.ps1` work correctly in uv-first
(real/cache) lanes even though those lanes normally use uv as the primary provider:

| Test | Env vars set | Why uv is bypassed |
|------|--------------|-------------------|
| `self.venv.fallback` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1 | HP_OFFLINE_MODE blocks uv download; fresh dir has no ~uv_bin |
| `self.ux.system.gate.real` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1, HP_TEST_FORCE_VENV_FAIL=1, HP_TEST_SYSCON_ANSWER=N | Same; forced chain: no-uv -> conda-fail -> venv-fail -> REQ-014 consent gate (declines). **No HP_ALLOW_SYSTEM_FALLBACK** -- proves the tier is reachable in a default no-flag run. |
| `self.ux.system.gate.accept` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1, HP_TEST_FORCE_VENV_FAIL=1, HP_TEST_SYSCON_ANSWER=Y | Same forced chain, but ACCEPT routes into Tier 4: asserts `System Python (degraded)` provider selected + `consent: user accepted` (REQ-009 "system Python alone"). |
| `self.entry.override` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1 | Same; forced chain: no-uv -> conda-fail -> venv-succeed |

These tests skip in conda-full lane (HP_FORCE_CONDA_ONLY=1 blocks system/venv fallbacks there).
Note: `HP_TEST_SYSCON_ANSWER` (Y/N) deterministically answers the REQ-014 consent prompt; it is
checked BEFORE the `HP_CI_LANE` auto-decline, so `=Y` reaches the system tier even in CI.

**What NOT to do**: never set HP_UV_BIN to a user-global or TEMP-based path -- it would break this
isolation property and make sub-bootstrap tests depend on whether the parent job happened to
download uv already.

`PVW_UV_EXE` is a super-user override (line 284) that would also break this property, but CI does
not set it (confirmed by grepping batch-check.yml).

### selfapps_isolation.ps1: HP_CI_SKIP_ENV=1 bypasses all provider logic

The three tests in `selfapps_isolation.ps1` (crossdir, sameDir, req010.pythonpath) run the
bootstrapper with `HP_CI_SKIP_ENV=1` inherited from CI, jumping to `:ci_skip_entry` (~1090-1196)
which uses system Python and bypasses provider selection entirely -- lane-agnostic, safe in all
lanes including uv-first.

### selfapps_skiphooks.ps1: provider-independent, conda-full lane only

Declared "Lane: conda-full only (behavior is provider-independent)" in the file header. The test
runs a full bootstrap and checks that HP_SKIP_ENTRY_SMOKE=1 + HP_SKIP_EXE_SMOKERUN=1 prevents
user code execution while still building the PyInstaller EXE. No Get-CondaBatPath call. The test
does not assert anything about the Python provider -- it only checks that the EXE was built and
that no user code ran. It is restricted to conda-full by CI wiring, not by the test itself.

### selfapps_pandas_excel.ps1: conda-full lane only (CI wiring)

This test script calls `Get-CondaBatPath` and runs pandas/openpyxl translation via conda.
It IS wired to the conda-full lane only in `.github/workflows/batch-check.yml`.
The `skip=true` guard for `HP_FORCE_CONDA_ONLY -ne '1'` is currently dead code in CI,
but correct defensively if CI wiring ever changes.

All 6 NDJSON rows (`pandas_excel.translate`, `pandas_excel.conda.install`,
`pandas_excel.conda.install.req006`, `pandas_excel.runtime`,
`self.pandas.openpyxl.install`, `self.pandas.openpyxl.import`) emit `skip=true` in
the uv-first guard branch.

### uv Coverage Status

**Currently covered by CI:**
- `self.contract.uv` (contract-uv lane): verifies uv venv creation and pip install work
- `self.contract.uv.pyver` (contract-uv lane): verifies an exact runtime.txt version is
  forwarded to `uv venv --python X.Y`
- `self.contract.uv.pyver.range` (contract-uv lane): verifies a loose pyproject
  `requires-python = ">=X.Y"` forwards the RANGE to uv so it resolves the latest satisfying
  managed CPython (interpreter minor in `.uv_env\pyvenv.cfg` is greater than the floor), not
  the floor. This is the floor-vs-pin fix: `run_setup.bat` emits `HP_UV_PY_REQ` (range for
  loose forms, bare `X.Y` for exact) and an operator-free `HP_UV_PY_DISP` for `:log`.
- `self.contract.uv.pyver.exactpin` (contract-uv lane): verifies an exact `==X.Y` pin stays
  pinned to `X.Y` and does not drift to latest after the range change.
- `self.uv.first.miniconda.skip` (contract-uv lane): verifies Miniconda is NOT downloaded when uv provides Python
- `self.contract.uv.fail` (contract-uv-fail lane): verifies graceful degradation when uv fails
- `self.uv.managed.interpreter` (selfapps_envsmoke.ps1, all uv-first lanes): verifies the
  `.uv_env` base interpreter is a uv-managed CPython, not an ambient/system Python
- `uv.python.preference.configured` (harness.ps1, static): verifies the
  `UV_PYTHON_PREFERENCE=only-managed` line is present in run_setup.bat
- `self.dl.uv.fallback` (justme-test lane): PASSES with `skip=true` because HP_TEST_UV_DL_FALLBACK is not set

**Gap (Active Backlog):**
- The actual uv DL fallback URL code path (`HP_TEST_UV_DL_FALLBACK=1`) has no active CI lane.
  justme-test uses `HP_TEST_FORCE_UV_FAIL=1` which skips uv before any download attempt.
  Needs a dedicated non-gating lane that sets `HP_TEST_UV_DL_FALLBACK=1` without
  `HP_FORCE_CONDA_ONLY=1` and without `HP_TEST_NOT_ELEVATED=1` so uv download is reached.

### Skip pattern template (copy-paste for new conda-specific test blocks)

```powershell
# derived requirement: in uv-first lanes, Miniconda is not installed so these
# conda-specific tests are not applicable -- emit skip=true.
# In conda-only lanes (HP_FORCE_CONDA_ONLY=1), conda MUST be present; emit failures.
if ($env:HP_FORCE_CONDA_ONLY -ne '1') {
    $myPass = $true
    $myDetails.skip   = $true
    $myDetails.reason = 'conda-not-installed-uv-first'
} else {
    $myDetails.reason = "conda python missing: $condaPython"
    $myDetails.condaBatCandidates = $condaInfo.candidates
}
```

---

## Single-verification smoke model (REQ-018 2b-A.2) couples run_setup.bat to envsmoke/skiphooks

The bootstrapper runs the user's code for MANDATORY verification exactly ONCE per invocation
(the pre-build interpreter smoke and a second EXE smoke were merged into one). An accepted
post-execution checkpoint (see that section below) can still launch an OPTIONAL second run --
"once per invocation" describes the automatic/default flow, not an absolute ceiling. Touching the
smoke flow in `run_setup.bat` requires understanding the assertions in
`tests/selfapps_envsmoke.ps1` and `tests/selfapps_skiphooks.ps1`, which are coupled by exact log
strings and run artifacts:

- **Removed:** the pre-build interpreter smoke (in `:run_entry_smoke`) and
  `:try_entry_smoke_after_warnfix` -- the EXE path no longer runs the app twice.
- **EXE path = primary (mandatory) verification via the timed EXE smoke** (`:run_exe_smokerun`).
  To keep existing
  tests passing without re-pointing them, it emits the **same vocabulary** the interpreter smoke
  used and **captures the EXE stdout/stderr** to the app root:
  - `[INFO] Running entry script smoke test via packaged EXE.` -> matches envsmoke `$hasEntryRun`
    (`'Running entry script smoke test'`).
  - `[INFO] Entry smoke exit=%HP_EXE_EXIT%` at `:smokerun_ndjson` -> matches `$hasEntryExit`
    (`'Entry smoke exit=0'`) when the EXE verifies clean.
  - The EXE smoke runs from `pushd dist` (CWD = dist\) -- the working directory a frozen EXE has
    always used here, and **load-bearing**: `selfapps_exedata_fail`'s app opens a CWD-relative
    `config.json` that MUST be absent at runtime (xfail), which only holds when CWD is `dist\`, not
    the app root (the app root contains `config.json`). Do NOT switch the EXE smoke to run from the
    app root -- it makes that file findable and turns the xfail into an xpass.
  - `$so.Result | Set-Content -Path '..\~run.out.txt'` (and `~run.err.txt`) from inside `pushd dist`
    captures the EXE's stdout/stderr to the app root so envsmoke `$tokenFound` (`'smoke-ok'`, on
    stdout) is satisfied by the EXE run instead of the deleted interpreter run.
  - **sys.argv[0]-relative files land in dist\ for a frozen EXE.** An app that writes next to
    `sys.argv[0]` (e.g. the spaced-path app's `~smoke_token.txt`, written to
    `dirname(abspath(sys.argv[0]))`) lands it in `dist\` under the EXE, not the app root where the
    interpreter would. `selfapps_envsmoke.ps1` therefore reads the spaced-path token from BOTH the
    app root and `dist\` (`$spaceTokenDist`). This is an inherent EXE-vs-script behavior difference,
    not something the bootstrapper can normalize.
  **If you change any of these strings/paths, envsmoke `$bootstrapPass` /
  `self.env.smoke.run` / `self.prime.run` / `self.prime.bootstrap` break.** `harness.ps1`
  `batch.smoke.single_verify` statically guards them.
- **No-EXE path** (system-Python build declined, or build skipped) runs the interpreter ONCE via
  `:verify_no_exe_interpreter` (after the build gate), emitting the same vocabulary. It is
  **UNTIMED on purpose** (in those providers the interpreter run IS the user's run, not a throwaway
  -- hard-killing a long-running app would have no recourse). It is skipped when `dist\<env>.exe`
  exists (EXE smoke handled it), `HP_FASTPATH_USED` (fast path ran it), or `HP_SKIP_ENTRY_SMOKE`.
- **skiphooks** (`HP_SKIP_ENTRY_SMOKE` + `HP_SKIP_EXE_SMOKERUN`) still asserts no user code ran:
  `:run_exe_smokerun` exits at the skip check BEFORE the vocab line, and
  `:verify_no_exe_interpreter` exits on `HP_SKIP_ENTRY_SMOKE`, so `'Running entry script smoke test'`
  is never emitted -> `$noUserCode` holds.
- **Shipped in 2b-C: fail-fast probe for the two previously-untimed runs** (`:try_fast_exe`'s cached
  EXE reuse and `:verify_no_exe_interpreter`). See the dedicated "Fail-fast probe (Slice 2b-C)"
  section below for the full mechanism, state variables, and the interconnects that touching either
  call site must respect (CWD-per-call-site, the `HP_FASTPATH_USED`/`HP_SMOKE_RC` decoupling fix,
  and the shared `:run_failfast_probe` subroutine both now route through).
- The `~run.out.txt` capture happens on the INITIAL EXE smoke run, before any hidden-import recovery, so
  after a recovery rebuild it reflects the pre-recovery run (diagnostic-only; token tests do not hit
  recovery). The fail-fast probe's own capture (interactive branch of `:try_fast_exe` /
  `:verify_no_exe_interpreter`) is a SEPARATE write of the same two files, pre-truncated at the start
  of `:run_failfast_probe` -- see the dedicated section below for why that pre-truncation matters.

## Fail-fast probe (Slice 2b-C): shared state machine for the two untimed launch points

`:try_fast_exe` (cached EXE reuse) and `:verify_no_exe_interpreter` (no-EXE interpreter run) both
launch user code with NO timeout in CI/automation (unchanged, plain `cmd` redirect). For a real
interactive double-click user (`HP_INTERACTIVE_RUN` set -- see `:compute_interactive_run`, mirrors
`:pick_entry_interactive`'s non-interactivity signals, plus `HP_TEST_FORCE_INTERACTIVE_PROBE=1` to
force the branch under `HP_CI_LANE` for CI coverage), both call the shared `:run_failfast_probe`
instead, which launches via `~failfast_probe.ps1` (`HP_FAILFAST_PROBE`, an emitted `.ps1` file, not
inline `-Command` -- the two-stage wait needs interpolated strings, which sidesteps every cmd.exe
quote-nesting hazard an inline command would hit). The helper does
`WaitForExit(HP_FAILFAST_PROBE_MS)` (default 10000ms -- distinct from the unrelated ~30s hard-kill
cap used by `:run_exe_smokerun`/`:hidden_import_recover`, which force-kills the fresh-build
verification run, the ONLY run this bootstrapper ever kills; this probe window is purely a
classification checkpoint, never a ceiling), then, if still running, a SECOND, UNBOUNDED
`WaitForExit()` with no `Kill()` anywhere.

**Touch either call site, must understand the other, plus the top-of-file success gate:**
- Both callers set `HP_PROBE_EXE`/`HP_PROBE_ARGS`/`HP_PROBE_CWD` before calling `:run_failfast_probe
  <site>`. **`HP_PROBE_ARGS` is a complete, ready-to-use Windows Arguments string, per the
  caller-owned quoting contract the Argv passthrough feature established (see below): the caller
  quotes each token, and `~failfast_probe.ps1` assigns the string to `ProcessStartInfo.Arguments`
  VERBATIM, adding no quotes of its own.** Do not wrap the complete string in another pair of
  quotes -- that collapses multiple arguments into one token. **CWD is preserved per call site**: both `:try_fast_exe` and
  `:verify_no_exe_interpreter` run from the app root (no `pushd dist`), unlike
  `:run_exe_smokerun`'s `pushd dist` (load-bearing for `selfapps_exedata_fail`'s CWD-relative
  `config.json` xfail check -- re-verify that test if these CWDs are ever unified).
- `:run_failfast_probe` always leaves `HP_SMOKE_RC` set to the true final exit code and
  `HP_PROBE_EXCEEDED` set (`1`) iff the probe window was crossed. `:try_fast_exe`'s
  discard-and-rebuild block is gated on `if not "%HP_SMOKE_RC%"=="0" if not defined
  HP_PROBE_EXCEEDED` -- once a process is classified alive/healthy at the probe, a LATER non-zero
  exit is presumed the user's own program outcome (not a stale artifact) and the cached EXE is
  kept, never discarded.
- **Silent-success bug this closed:** the top-of-file fast-path caller used to gate its `goto
  :success` shortcut on `HP_FASTPATH_USED` alone, with no outcome check -- harmless before this
  slice (any non-zero `HP_SMOKE_RC` always cleared `HP_FASTPATH_USED` too). Once the probe's
  "don't discard past the window" rule could leave `HP_FASTPATH_USED` set through a real later
  failure, that shortcut would silently report full success while hiding it. Fixed by computing
  `HP_FASTPATH_RUN_FAILED` (true only when `HP_SMOKE_RC` is DEFINED and non-"0" -- empty/undefined
  still means "no real failure observed," e.g. the REQ-012 skip-without-running case, which must
  still take the zero-friction path) and branching the log message on it before
  `write_status`/`goto :success`; `HP_BOOTSTRAP_STATE` stays `ok` either way (a runtime bug in the
  user's own code isn't something a rebuild could fix -- matches CLAUDE.md's "User-code exit-code
  semantics" Known Finding), but the console now always shows the true `[STATUS]` outcome first.
- **Both `:try_fast_exe` call sites carry this guard, not just the top-of-file one.** The second
  site (inside `:run_entry_smoke`'s build gate) recomputes `HP_FASTPATH_RUN_FAILED` fresh and
  branches the same way -- normally unreachable today (any first-call success or post-probe
  failure already took `goto :success` before this point), but a future provider-cascade
  re-entry could reach it with `HP_FASTPATH_USED` still set, so this closes that gap defensively.
- **cmd.exe parse-time-expansion hazard, avoided via goto not if/else, at both sites.** An earlier
  revision read `set "HP_SMOKE_RC=%ERRORLEVEL%"` (plus the SUCCESS/FAILED branch) INSIDE the
  non-interactive `else ( ... )` clause -- cmd.exe expands every `%VAR%` in a parenthesized block
  ONCE at parse time using pre-block values, so `%ERRORLEVEL%` silently froze to whatever it was
  before the dispatch (almost always `"0"`), meaning a genuinely broken cached EXE was NEVER
  discarded in the legacy/CI branch. Both sites now use `if defined HP_INTERACTIVE_RUN goto
  :<label>_probe` instead (see `docs/agent-lessons-learned.md` "Provider-cascade dispatch is
  goto-based on purpose") -- do not reintroduce a parenthesized if/else around a
  launch+`%ERRORLEVEL%`-capture sequence here.
- `:try_fast_exe`'s legacy branch also gained a `[STATUS] Run Status: SUCCESS/FAILED` line for
  parity (previously emitted no `[STATUS]` telemetry at all) -- purely additive, no branch/goto
  change, doesn't affect `self.fastpath`/`self.exe.fastpath.graceful` determinism.
- NDJSON row `self.failfast.probe` carries `details.site`
  (`'fastpath'|'interpreter'|'checkpoint'` -- the third value added when the post-execution
  checkpoint shipped, see below) so one schema covers all three call sites. Since the checkpoint
  can trigger this subroutine a SECOND time per bootstrap, this row is no longer guaranteed at
  most once per stream -- key off `details.site`, don't assume one row per run.
- Test coverage: `tests/selfapps_failfast_probe.ps1` (`self.failfast.probe.fastfail`,
  `self.failfast.probe.alive`), forced via `HP_TEST_FORCE_INTERACTIVE_PROBE=1` under
  `HP_CI_LANE=test`. `tests/harness.ps1`'s `batch.failfast.probe` statically guards the
  interactivity subroutine, the shared probe subroutine, the test override, the default window,
  the `HP_PROBE_EXCEEDED` var, and the decoupling fix.

### Live-echo redesign (docs/plan-cli-interactive-verification.md P0, requirement 1) -- touches BOTH `~failfast_probe.ps1` and the new `~exe_smokerun.ps1`, plus their callers

**Status: shipped.** Requirement 2 (real-Windows stdin confirmation) has a dedicated CI test now
(`tests/selfapps_interactive_stdin.ps1`, below) but isn't closed until its first real run is
observed passing. Requirement 3 (the 30s-kill revisit, Open Question 1) remains open.

**Current mechanism (final state, after two superseding rewrites -- see
`docs/agent-lessons-learned.md`'s ".NET Process async-redirected-output [SUPERSEDED]",
"`Register-ObjectEvent` reorders lines... [SUPERSEDED...]", and "`StreamReader.ReadLineAsync()` is
line-buffered" entries for the full bug-by-bug history of how this was arrived at):** both helper
scripts live-tee the child's stdout/stderr as bytes arrive, via chunk-based
`StreamReader.ReadAsync(char[], int, int)` polling (one read in flight per stream at a time,
enforcing ordering by construction) -- `[Console]::Out.Write($chunk)`/`[Console]::Error.Write($chunk)`
(no auto-newline, since chunks land at arbitrary boundaries), EOF is a 0-length read. Chosen over
line-based `ReadLineAsync()` specifically because Python's `input("prompt")` writes its prompt
WITHOUT a trailing newline, so a line-based read would leave a live user watching a blank screen
until something else flushed a newline (Finding 9).

**Result-passing is a dedicated file, not stdout capture.** Both helpers used to print their
`"$exceeded|$exitcode"` result as their own final stdout line, captured by the caller via `for /f
... in (\`powershell ...\`) do (...)` -- but `for /f` captures the ENTIRE stdout of the wrapped
command, which would swallow every live-teed line and corrupt the result parse. Fixed by invoking
the helper DIRECTLY (a plain top-level `powershell -File "..."` statement, no backtick/`for /f`
wrapping) so live output flows straight to the console, with each helper writing its result to a
dedicated file instead (`HP_PROBE_RESULT`/`HP_SMOKERUN_RESULT`, default `~probe_result.txt`/
`~smokerun_result.txt`) read afterward via a SEPARATE, safe `for /f` targeting a static file.

**`:run_exe_smokerun`'s inline `-Command "..."` became a proper emitted helper**,
`tools/exe_smokerun.ps1` (`HP_EXE_SMOKERUN`) -- required independently, per the "prefer an emitted
`.ps1` file over inline `-Command` with literal quotes" rule (`docs/agent-lessons-learned.md`).
NOT a reuse of `~failfast_probe.ps1` -- the one behavioral difference is preserved exactly: after
`HP_SMOKERUN_KILL_MS` (default 30000, `run_setup.bat` never overrides it -- production behavior is
byte-for-byte unchanged from the prior hardcoded 30s; the override exists only for
`tests/test_exe_smokerun.py` to exercise `Kill()` without a real 30s wait), this script calls
`$p.Kill()` -- `:run_exe_smokerun` is the sole verification pass for a build never confirmed
working, unlike the untimed sites `~failfast_probe.ps1` covers, so an unresponsive process here
cannot be trusted to eventually finish. Revisiting the 30s value itself is Open Question 1,
explicitly NOT decided by this redesign -- this was purely how output is captured/shown and how
the result is signaled back, not when/whether the process gets killed.

Both helper scripts hit the CMD 8191-char line-length budget for real while writing this (see
`docs/agent-lessons-learned.md`'s "CMD.EXE 8191-Character Line Limit" entry) -- both header
comments were trimmed to the terse, point-to-docs style already used by
`HP_EMBED_PYVER_CHECK`/`HP_EMBED_EXTRACT`. Current margins: `HP_FAILFAST_PROBE` line_len 7668,
margin 523; `HP_EXE_SMOKERUN` line_len 7394, margin 797.

Test coverage: `tests/test_failfast_probe.py` (`InteractiveRoundTrip` -- a multi-round `input()`
conversation asserting output ORDER via `.index()`, the test that found the ordering bug;
`NoNewlinePromptVisibility` -- drives stdin via a live, test-controlled pipe so it can assert the
prompt is readable BEFORE any answer is sent) and `tests/test_exe_smokerun.py`
(`ActivityAwareStop::test_output_with_no_trailing_newline_still_prevents_kill`) exercise both
scripts end-to-end via real `pwsh` subprocesses: fast-exit/probe-exceeded classification,
`Kill()`-after-timeout, output-path overrides, live output reaching the SCRIPT'S OWN stdout/stderr
(not just captured files), `PayloadSync` byte-equality, ordering correctness, no-newline-chunk
visibility. All regression tests confirmed to genuinely fail against the pre-fix implementation
and pass against the fix. What's provable by static analysis + local `pwsh` repro stops short of
the FULL production chain (cmd.exe's own console/stdin semantics for a double-clicked `.bat`,
unreproducible in this sandbox) -- `tests/selfapps_interactive_stdin.ps1` (uv lane, non-gating)
closes that gap: builds a real PyInstaller EXE from a multi-round `input()`-driven stub app, pipes
a scripted answer sequence into `cmd.exe`'s own stdin, exercises the full `cmd.exe ->
:run_exe_smokerun -> ~exe_smokerun.ps1 -> the built EXE` chain, asserts ordering via `IndexOf` on
the bootstrap log. Provider-agnostic by construction, so one passing run in the uv lane represents
every lane (`self.interactive.stdin.roundtrip`, see `docs/agent-ndjson.md`). Requirement 2 remains
open until this test's first real CI run is observed passing.

### Activity-aware EXE-smoke kill (docs/plan-cli-interactive-verification.md P0, requirement 3) -- resolves Open Question 1, touches `~exe_smokerun.ps1` and `:warn_user_code_launch`

**Status: SHIPPED 2026-07-24, owner decision.** The exact prompt: "don't change the timeout if
they were told at the beginning that it was timed. At best, if interactive input was received
then extend or stop the timeout."

1. **`tools/exe_smokerun.ps1`'s `Kill()` is now conditional on a new `$sawOutput` flag.** The
   `HP_SMOKERUN_KILL_MS` window is UNCHANGED (still 30000ms default, per "don't change the
   timeout") -- what changed is what happens AT the checkpoint: `Kill()` now only fires if the
   process has produced ZERO output by then. Any output skips the kill for the rest of the run --
   unbounded, mirroring `~failfast_probe.ps1`'s "classify once, then never kill" philosophy. The
   ONLY subroutine in this file family that still has a real `Kill()`. **Gap found+fixed same day
   (Finding 9)**: as shipped, `$sawOutput` was driven by `ReadLineAsync()`-completion, so it stayed
   false for a no-trailing-newline chunk (the exact shape of `input("prompt")`'s output) until a
   LATER newline -- meaning the kill could still fire for the canonical scenario this requirement
   protects. Fixed by switching to chunk-based reads (see "Live-echo redesign" above); `$sawOutput`
   now sets on any non-empty chunk regardless of trailing newline.
2. **"Any output" is the chosen proxy for "interactive input was received"** because the parent
   cannot observe stdin directly (`RedirectStandardInput` deliberately left unset/inherited, so
   real keystrokes reach the child without being routed through this script -- not reopened here).
   Python's `input(prompt)` flushes stdout before blocking on stdin (confirmed directly), so a
   process at its first prompt has ALREADY printed something -- a process STILL silent past the
   deadline is the genuine hung/deadlocked case this cap exists to catch (unaffected, still
   killed).
3. **"Stop" was chosen over "extend by a fixed increment"** -- a bounded extension just relocates
   the same ambiguity to a later deadline. "Stop" (fully unbounded once alive) reuses an
   already-proven pattern and serves the owner's target use case (an `input()`-driven
   setup-then-loop program). **Accepted trade-off**: a process that prints once (a startup banner)
   and then genuinely deadlocks for a reason unrelated to stdin now hangs the bootstrap
   indefinitely instead of being caught at 30s.
4. **`:warn_user_code_launch` now takes a parameter (`main`/`hidden_import`) with DIFFERENT
   messages per caller**, since the two now behave differently: `:run_exe_smokerun` (`main`) gets
   the new conditional wording; the hidden-import recovery loop's own separate, still-unconditional
   30s check (`:hidden_import_loop`, an older inline block that always kills at 30s regardless of
   output -- a bounded repair-verification check, not a full run) passes `hidden_import` and keeps
   the ORIGINAL unconditional wording, since its actual behavior is genuinely unchanged.
   **Deliberately NOT migrated to activity-aware/chunk-based reads in this pass** -- revisit only
   if interactive-friendly behavior is needed there too.

Test coverage: `tests/test_exe_smokerun.py`'s `KillTimeout` class was split -- the pre-existing
hung-process test now uses a genuinely SILENT script to keep testing "still killed" correctly; a
new `ActivityAwareStop` class proves a process that prints, runs well PAST a short kill window,
then exits with a distinguishable real code, is never force-stopped, plus a Finding-9-specific
test (`test_output_with_no_trailing_newline_still_prevents_kill`) confirmed to genuinely fail
against the pre-fix implementation and pass against the fix.

### Process-ID display for stuck-program recovery (owner-requested, 2026-07-25) -- touches both `~exe_smokerun.ps1` and `~failfast_probe.ps1`

**Direct follow-up to the "accepted trade-off" above**: once a process has printed anything,
`:run_exe_smokerun` AND `~failfast_probe.ps1`'s three call sites become genuinely unbounded by
design, so a real deadlock unrelated to stdin has no automatic recovery. The owner asked what
else could help a stuck user without reverting that decision.

**Ctrl+C was researched and rejected, in favor of something simpler.** `CTRL_C_EVENT` broadcasts
to the WHOLE console process group (per Microsoft's Windows Console docs) -- `cmd.exe`,
`powershell.exe`, AND the grandchild would all receive it simultaneously. Making it "safe" (kill
only the grandchild) needs real process-group-isolation engineering (`CREATE_NEW_PROCESS_GROUP`
via raw P/Invoke, plus `SetConsoleCtrlHandler(NULL, TRUE)` in this file's own layers) --
disproportionate for this ask, left unbuilt.

**What shipped instead: printing the real Windows PID, pointing the user at Task Manager's "End
Task."** `TerminateProcess` (what End Task calls) targets a single PID directly -- NOT a
console-signal broadcast, so inherently more surgical: it can never touch
`cmd.exe`/`powershell.exe`/the bootstrapper. The PID is already sitting in the existing `$p =
[System.Diagnostics.Process]::Start(...)` object at both never-kill call sites; nothing new to
track. Added `Write-Host "[INFO] Process ID $($p.Id). If it seems stuck: Task Manager > Details
tab > find this PID > End Task (this window stays open)."` right after `Start()` in both scripts.
**Deliberately `Write-Host`, not `[Console]::Out.Write`**: auto-appends a newline (correct for one
complete bootstrapper-generated line, not an arbitrary-boundary child chunk), and is never
captured into `$outBuf`/`$errBuf` (confirmed empirically), so it can't be mistaken for the user's
own program output downstream.

**Budget was the binding constraint.** Both payloads already had the tightest CMD-line-length
margins in the file; the message was written for maximum compactness, landing at 145/151-char
margins -- tight but workable.

**Pre-existing test bug found+fixed while verifying this, not introduced by it**:
`NoNewlinePromptVisibility` assumed the FIRST chunk read from the child's stdout pipe would BE the
child's prompt text -- true before this change, not after the PID line prints first (never
actually guaranteed by pipe semantics anyway). Fixed by accumulating reads until the expected
substring appears.

Both files' full test suites re-verified passing (22 combined, including `PayloadSync`), plus 4
new tests (2 per file): the PID line appears with a real positive numeric PID and mentions "Task
Manager"/"End Task," and never contaminates the captured output file.

## Argv passthrough escape hatch (REQ-026, P1) -- touches HP_PROBE_ARGS's own contract, not just new callers

**Status: SHIPPED 2026-07-24**, plan P1 requirement 4. `HP_APP_ARGS` is captured ONCE, at the very
top of `run_setup.bat` (right after `set "DEP_SOURCE=unknown"`), from `%2`-`%9` directly --
deliberately NOT via `shift`, since `%~1` (entry file) is read directly by several later call
sites (top-of-file UNC check, both `:determine_entry` sites), and shifting would silently change
what those later `"%~1"` reads see. Caps the feature at 8 extra arguments (matches the plan's
non-goal of not chasing generic detection).

**Touch either shared `.ps1` helper's `Arguments` handling, must understand the OTHER's -- this
shipped as a CONTRACT CHANGE to `HP_PROBE_ARGS`, not just a new optional variable.** Before this,
`tools/failfast_probe.ps1` did `if ($rawArgs) { $si.Arguments = '"' + $rawArgs + '"' }` --
wrapping whatever was in `HP_PROBE_ARGS` in one pair of quotes, correct only for a SINGLE token.
Forwarding multiple tokens through that wrapping would collapse them into one literal argv
element (per Windows' `CommandLineToArgvW` quoting rules). Fixed by changing the contract:
`$si.Arguments = $rawArgs`, used VERBATIM -- the CALLER is responsible for a fully-quoted,
ready-to-use Arguments string. Every `HP_PROBE_ARGS` assignment site had to be re-audited:
- `:try_fast_exe_probe`: was `set "HP_PROBE_ARGS="`; now `set "HP_PROBE_ARGS=%HP_APP_ARGS%"` (no
  entry-file prefix -- the EXE is self-contained).
- `:verify_no_exe_probe`/`:run_postexec_checkpoint` (launch the INTERPRETER, need the entry path
  as first argv): was `set "HP_PROBE_ARGS=%HP_ENTRY%"` (bare, unquoted -- safe under the OLD
  contract since the script's own wrapping quoted it); now `set "HP_PROBE_ARGS="%HP_ENTRY%"%HP_APP_ARGS%"`
  -- entry path explicitly re-quoted at the call site, extra args (pre-quoted at capture time)
  appended after.
- The two DIRECT (non-probe) sites (`:try_fast_exe`'s legacy branch, `:verify_no_exe_interpreter`'s
  legacy branch) needed `%HP_APP_ARGS%` appended directly to the command line, since cmd.exe
  forwards this as ordinary additional quoted tokens with no `.ps1`/re-quoting layer involved.

**`tools/exe_smokerun.ps1` needed a NEW variable, `HP_SMOKERUN_ARGS`, not a contract change** -- it
never had `Arguments` handling before (zero argv previously). Added `if ($argsRaw) { $si.Arguments
= $argsRaw }` under the same "caller provides a ready string" contract, fed from `run_setup.bat`'s
`:run_exe_smokerun` setting/clearing `HP_SMOKERUN_ARGS=%HP_APP_ARGS%` (no entry-file prefix, same
as the fastpath probe site).

**`:log` echoes UNQUOTED -- do NOT interpolate `%HP_APP_ARGS%`'s content into any log/echo line.**
A user-supplied argument can legitimately contain `<`/`>`/`|`/`&`, which would corrupt a raw
`:log`/`echo` line the same way `%HP_ENTRY%`'s own documented "accepted risk" does. The one new log
line this feature adds is deliberately CONTENT-FREE -- confirms "extra launch argument(s)
detected," never expands `%HP_APP_ARGS%` itself.

**Test-suite consequence: REPLACED an existing test documenting the OLD contract as correct, not
just added new ones.** `tests/test_failfast_probe.py`'s `ArgsIsSingleArgumentOnly` (docstring:
"HP_PROBE_ARGS must be a single path... misparsed as one argument") was true pre-fix, actively
WRONG post-fix. Replaced with `ArgvPassthrough` (proves multiple pre-quoted tokens forward as
separate argv elements, and documents the caller-responsibility boundary: an UNQUOTED token
containing a space is split by the CHILD's own argv parser). A second, pre-existing test
(`test_single_argument_path_with_spaces_quoted_correctly`) also had to change: an unquoted
path-with-spaces relying on the OLD wrapping now fails ("can't open file") -- fixed by quoting the
path in the test, matching production.

**`tests/test_exe_smokerun.py`'s harness has no natural "argv slot" -- solved with a lesser-known
CPython CLI form.** That file feeds the test program via INHERITED stdin (`python` with no script
argument, non-tty stdin executes stdin as the program), which has no positional slot for extra
CLI args (appending them would make Python parse them as its own interpreter flags). Fixed with
CPython's `python - arg1 arg2` form: a literal `-` as script name means "read from stdin," and
everything after becomes `sys.argv[1:]` -- confirmed directly (`python3 - --foo "bar baz" <
script.py` prints `ARGV:--foo|bar baz`).

**`:hidden_import_recover`'s own EXE re-run deliberately does NOT receive `HP_APP_ARGS`** -- a
diagnostic/repair check against a build ALREADY CONFIRMED WORKING, not the user's primary run
(same reasoning the Tier A section applies to that loop for Nuitka-vs-PyInstaller awareness). The
CI-only `HP_CI_SKIP_ENV=1` path was also left out -- test infrastructure, not a named real launch
site, and CI has no interactive terminal to benefit.

**`:offer_optimized_build`'s internal build-verify launch was ALSO missing `HP_APP_ARGS`, found
and fixed 2026-07-25 -- the two loops are NOT the same shape.** `:hidden_import_recover` re-runs
the ALREADY-VERIFIED original EXE; `:offer_optimized_build`'s internal verify launches a BRAND-NEW
Nuitka binary never executed before -- for a program needing launch arguments to start cleanly,
omitting `HP_APP_ARGS` meant this verification would ALWAYS report nonzero and decline the
optimized build regardless of whether the Nuitka build was actually fine. Fixed by having the
inline PowerShell `-Command` read `$env:HP_APP_ARGS` directly (PowerShell's own inherited-env
access) rather than cmd.exe substituting `%HP_APP_ARGS%` into the command text -- since
`HP_APP_ARGS` contains literal embedded double-quotes per token, and cmd.exe's quote-toggle parser
has no concept of "this quote belongs to a PowerShell string," direct substitution would corrupt
the `-Command` argument (the same hazard class as `HP_FAILFAST_PROBE`'s inline-vs-emitted-`.ps1`
decision) -- reading it at PowerShell runtime sidesteps the whole hazard, since cmd.exe's own
command-line text never needs to contain the quote-laden content.

## Honest ambiguous-exit messaging (REQ-027, P2) -- two panels, two independent gaps found by tracing what P1/P0 already changed

**Status: SHIPPED 2026-07-24**, plan P2 requirement 5. Deliberately scoped narrower than the plan
originally sketched -- "offer a deeper dependency-resolution pass" was dropped (that offer already
exists and fires earlier, at `:warnfix_cascade_detect`; re-offering it post-hoc would need much
more plumbing for uncertain benefit). What shipped is messaging-only, touching two genuinely
gapped panels found by tracing the ACTUAL control flow after P0/P1 shipped.

**Gap 1, a real pre-existing bug: `:print_no_exe_briefing`'s header unconditionally claimed "your
code ran successfully."** This panel fires whenever `HP_BUILD_OK` is defined and no EXE exists
(`:success`'s dispatch, ~line 1797-1802) -- always AFTER `:verify_no_exe_interpreter` already ran
the entry via the interpreter fallback, but the panel's text had zero awareness of whether that
run's `HP_SMOKE_RC` was actually 0. Fixed with a new flag, `HP_NOEXE_VERIFY_FAILED`, set in BOTH
of `:verify_no_exe_interpreter`'s branches whenever `HP_SMOKE_RC` is nonzero -- mirroring the
existing `HP_EXE_VERIFY_FAILED` pattern for the EXE path (declare-clean-at-top, set-only-on-failure).
No `-1`/timeout ambiguity: `:run_failfast_probe` never kills, so `HP_SMOKE_RC` is always the
interpreter's true final exit code. `:print_no_exe_briefing` now goto-dispatches its header on
this flag (mirroring `:print_postflight_briefing`'s `:pfb_caveat` shape) -- the caveat variant
never claims success and never asserts WHY the run failed (out of scope, per Open Question 3).

**Gap 2, a genuinely unsignaled path: the fast-path-kept-despite-failure case had NO postflight
panel at all.** `:success`'s dispatch is gated on `if not defined HP_FASTPATH_USED (...)` -- when
the fast path IS used, NEITHER briefing panel ever fires, by design (zero-friction, the user
already saw a full briefing on a prior run). But for the "kept despite a later non-zero exit"
sub-case (`HP_FASTPATH_RUN_FAILED` set -- see "Fail-fast probe" above for how this survives to
`:success`), that meant NO postflight signal beyond one `[WARN]` log line. New subroutine
`:print_fastpath_ambiguous_note`, called from a new `else if defined HP_FASTPATH_RUN_FAILED`
branch -- deliberately a PLAIN INFORMATIONAL PRINT, no `set /p`/consent gate (the fast path's
"zero friction, no prompts" rule is about not adding QUESTIONS; a print-only panel asks nothing).
Points the user at the direct-run command and at deleting `dist\<env>.exe` + re-running for a
genuinely fresh dependency check -- the closest honest equivalent to "try a deeper pass" here.

**Neither panel asserts a root cause** -- both stay agnostic about whether the ambiguous exit is a
real bug in the user's code, an unresolved dependency, or something else (Open Question 3
explicitly leaves root-cause distinction unsolved).

**Test coverage, reusing/extending existing scenarios rather than net-new test files.**
`tests/selfapps_pyinstaller_fail.ps1` gained a third `PYI_FAIL_SCENARIO`, `execfail_runtimefail`
-- identical to `execfail` except the stub app ALSO exits non-zero, so the interpreter fallback is
a genuine failure too, asserting the caveat header appears instead of the plain success text (the
two other scenarios still correctly assert that text unchanged). Wired as a third step in
`batch-check.yml`, same gating lanes. `tests/selfapps_failfast_probe.ps1`'s existing `self.failfast.
probe.alive` scenario already produces the EXACT "cached EXE kept, later exits non-zero" condition
`:print_fastpath_ambiguous_note` targets -- extended with one new assertion rather than a fourth,
largely-duplicate scenario.

## Post-execution checkpoint (Slice 2b-C, second half): the elective second run

`:run_postexec_checkpoint` is the other half of 2b-C (the fail-fast probe above shipped first, in
a separate PR). It is a **consent gate**, not a probe mechanism -- follows the SAME 3-branch
template as `:system_build_consent_gate`/`:cascade_consent_gate`/`:system_python_consent_gate`
(echo the prompt UNCONDITIONALLY, then `HP_TEST_CHECKPOINT_ANSWER` override, then `HP_CI_LANE`
auto-decline, then interactive `set /p`) -- **not** the `HP_INTERACTIVE_RUN` convention the
fail-fast probe uses. Do not conflate: `HP_INTERACTIVE_RUN` silently SKIPS a branch under CI (no
prompt text at all); the consent-gate pattern always ECHOES the prompt even when auto-declining,
so a `self.checkpoint.*` test can assert the prompt text regardless of lane.

**What it does and why it's safe to call unconditionally:** `:run_postexec_checkpoint <site>` is
called at the end of every place that already printed `[STATUS] Run Status: ...` for a FRESH
verification run -- `:smokerun_ndjson` and both branches of `:verify_no_exe_interpreter`.
Deliberately **never** called from `:try_fast_exe`'s fast-path reuse -- "Fast path = ZERO
friction... do NOT add a prompt or flag" -- adding it there would violate zero-friction even on
the auto-decline path (still echoes a prompt in CI). On accept, it reuses `:run_failfast_probe`
(site `'checkpoint'`) for the second launch -- same never-kill, two-stage-wait guarantee.

**State it touches:** the accepted run reuses `HP_PROBE_EXE`/`HP_PROBE_ARGS`/`HP_PROBE_CWD`, and
writes to distinct `~checkpoint_run.out.txt`/`~checkpoint_run.err.txt` files (via
`HP_PROBE_OUT`/`HP_PROBE_ERR`) rather than the FIRST run's `~run.out.txt`/`~run.err.txt`, so this
elective second run cannot clobber the real verification's captured output.
`HP_SMOKE_RC`/`HP_PROBE_EXCEEDED` are explicitly **saved before and restored after** the checkpoint
call (`HP_CHECKPOINT_SAVED_SMOKE_RC`/`HP_CHECKPOINT_SAVED_PROBE_EXCEEDED`) -- NOT overwritten by
the second run's outcome, since a caller's code after the checkpoint call must still see the FIRST
run's result. The elective run's outcome is only ever surfaced via its own `[STATUS]`/NDJSON
emission inside the checkpoint call, never propagated back into the caller's `HP_SMOKE_RC`.

**Cascade re-entry can offer the checkpoint more than once per bootstrap** -- `:after_env_mode_
selection` is re-entrant, so a REQ-009 cascade reaching a NEW verification run at any of the three
call sites offers a FRESH checkpoint prompt each time (intentional, each cascade tier is a
genuinely different build) -- `self.checkpoint.*`-style assertions must not assume exactly one
prompt occurrence.

Test coverage: `tests/selfapps_postexec_checkpoint.ps1` (`self.checkpoint.accept`/`.decline`),
asserting the prompt is shown in both cases and the run footprint is exactly two vs. one `Entry
smoke exit=0` occurrences. `tests/harness.ps1`'s `batch.postexec.checkpoint` statically guards the
subroutine, the test override, the unconditional prompt echo, both log lines, and that all three
call sites are still wired.

**Cascade-vs-postexec fix (CLAUDE.md item 9 / docs/open-questions.md item 1, closed) -- the
checkpoint and requirement 9's optimized-build offer are now both skipped, but ONLY at the `exe`
call site, and ONLY when the CURRENT provider's own cascade was just approved.** Closed open
question: cascade consent is asked BEFORE the EXE smoke run, so a user who already said "yes, try
the next provider" would still be shown two more elective prompts about the build they just opted
away from, wasting real time (the optimized-build offer alone can take a minute+ compiling
something about to be discarded).

**The smoke run ITSELF is deliberately NOT skipped, even when cascade is approved -- the first,
wrong design attempted, caught before shipping.** `HP_CASCADE_APPROVED` (set well before
`:run_exe_smokerun` runs) only means the NEXT tier will be TRIED, not that the cascade actually
reaches one -- `:provider_cascade` can still find every remaining tier unavailable/declined and
fall back to one of its six "keeping current build" exhaustion messages, at which point the
CURRENT build (whose smoke run would have been skipped) is what ships. Skipping the smoke run
entirely would leave that kept-on-exhaustion build completely unverified. Fix: `:run_exe_smokerun`
always runs; only the two ELECTIVE follow-up calls inside `:smokerun_ndjson`
(`:run_postexec_checkpoint exe`, `:offer_optimized_build`) are wrapped in `if defined
HP_CASCADE_APPROVED (...) else (...)`.

**The "declined/timed-out" side got two companion pieces:**
1. **`:cascade_consent_gate`'s real-interactive-user branch now uses a TIMED `choice /T` prompt**
   (default 30s) instead of an unbounded `set /p`, mirroring `:pick_entry_interactive`'s
   established `choice /T %HP_PICK_T% /D %HP_PICK_DEFAULT%` pattern -- the only other already-timed
   consent-style prompt (every sibling gate: `:run_postexec_checkpoint`, `:offer_optimized_build`,
   `:system_build_consent_gate`, `:conda_binary_corrupt`'s heal prompt, `:check_net_after_dl_fail`,
   `:system_python_consent_gate` still uses a bare, unbounded `set /p` and shares the same
   "hangs forever unattended" characteristic -- fixing all of them was out of scope for this pass).
   On timeout, `/D N` resolves to decline. `HP_TEST_FORCE_INTERACTIVE_CASCADE=1` forces this branch
   under `HP_CI_LANE` and shrinks the timeout to 2s for CI. Rewritten with goto-based dispatch (not
   nested parens) per "Provider-cascade dispatch is goto-based on purpose" -- `if errorlevel N`
   (not `%ERRORLEVEL%` substitution) sidesteps the parse-time-expansion trap.
2. **A new "dependencies may be incomplete" note** (`HP_DEP_MAYBE_INCOMPLETE`), set in
   `:warnfix_cascade_detect` whenever a cascade candidate was detected but NOT approved -- reset at
   the top of every FRESH build attempt (alongside `HP_NUITKA_FALLBACK_USED`'s reset). Consumed at
   two points: an immediate `[WARN]` at the decision, and a reminder in `:warn_user_code_launch`
   right before the EXE launches, so a confusing runtime failure isn't mistaken for a bug in the
   user's own code. Deliberately a NOTE, never a second gate. The "tell the user their odds of a
   DIFFERENT next tier helping" idea was investigated but not implemented -- see "Cascade signal
   reliability" below for why.

Test coverage: `tests/selfapps_cascade.ps1`'s `self.cascade.exec` (uv lane, non-gating) gained an
assertion that all 4 approved-cascade builds (uv, conda, embed, venv) correctly skip their
postexec offers (`offersSkipped` count, expected exactly 4). New `tests/selfapps_cascade_
timed.ps1` (conda-full lane) proves the timed-choice mechanism and the dirty-flag note positively
-- see `docs/agent-ndjson.md` for the full assertion list.

### Cascade signal reliability -- why `HP_CASCADE_CANDIDATE` is a strong-but-imperfect signal

Investigated in response to a maintainer question about how confident this signal actually is, and
whether the cascade consent gate's design (timed prompt, defaults to decline) should change as a
result. **Outcome: kept exactly as shipped -- see CLAUDE.md's Known Findings entry.** This
subsection preserves the supporting mechanism-level analysis for anyone touching the signal again.

`HP_CASCADE_CANDIDATE` requires BOTH of two build-time, static signals (`:warnfix_cascade_detect`):
- **Signal A**: PyInstaller's own warn file still lists an unresolved import even AFTER a
  repair-install attempt and a rebuild.
- **Signal B**: at least one specific `pip install <package>` / `conda install <package>` repair
  command, during that same repair round, itself returned a real, nonzero exit code.

This is never based on running the `.exe` -- the cascade decision happens entirely before the app
is ever launched. It is also narrower than "any warnfix repair failure": most apps needing any
repair at all get fixed cleanly by a single install (both signals false) -- requiring BOTH signals
together is what makes a genuine candidate uncommon, not the base rate of repairs needed.

| Signal A (still unresolved) | Signal B (an install genuinely failed) | Cascade offered? | What it usually means | Est. odds the `.exe` still runs fine |
|---|---|---|---|---|
| No | No | No | Repair fully worked, or nothing was needed. The common case. | Very high (~95%+) |
| No | Yes | No | An install command failed, but the rebuild's own scan came back clean anyway -- either that import was a false positive PyInstaller flags but doesn't actually need, or something else in the same round resolved it. | High (~80-90%) |
| Yes | No | No | A real gap the design doesn't catch: the repair round's OWN installs can pull in a brand-new import PyInstaller now also flags, which the repair loop never targeted (so nothing "failed" for it) -- the confidence gate doesn't distinguish this from noise. | Medium (~60-70%) |
| Yes | Yes | **Yes** | The actual trigger: a real install failure AND a persistent static-analysis gap. The strongest available signal, but still not proof the app will crash. | Lower, and audience-dependent (~25-40%) |

**Row 4 in more depth (the one that actually reaches the user).** Could the `.exe` still succeed
with a genuine (A=yes, B=yes) signal? Plausibly -- PyInstaller's warn file is a whole-codebase
static scan, not proof a specific code path executes; an optional feature behind `try/except
ImportError`, a rarely-used branch, or a type-checking-only import would all trigger this signal
without the main flow ever needing it. Against that: this bootstrapper's stated audience is
beginners with straightforward scripts, where a top-level, unconditionally-used import is common,
so an outright crash is plausibly more likely than not, just not overwhelming. These percentages
are informed estimates from reasoning through the mechanism, not measured production telemetry.

Could the NEXT provider actually help, given this signal? Depends entirely on WHICH hop, and the
bootstrapper has no way to tell which:
- **uv -> conda**: the one hop with real, mechanism-level justification. conda-forge is a
  genuinely different package index from PyPI, with different maintainers and (crucially)
  pre-built binaries for some native-extension packages notoriously hard to get right via pip on
  Windows. A meaningfully better chance here, though 0% if the package is genuinely absent from
  every index (a translation-table bug, or a nonexistent/private package name).
- **conda -> embed -> venv -> system**: all of these still install via plain pip against PyPI once
  bootstrapped -- functionally the SAME resolution mechanism uv already tried, just in a fresh
  environment. They only help if the root cause was environment-specific (a stale cache, a
  `PYTHONPATH`/`VIRTUAL_ENV` conflict, a uv-specific bug), not genuine package unavailability --
  and if uv AND conda have BOTH already reached this exact state, that's some evidence against a
  simple environment glitch. Meaningfully lower odds of success on these later hops.

This supports, with a real mechanism behind it rather than just intuition, the idea that cascading
specifically to conda has real, justified value while later hops add comparatively little. The
maintainer considered flipping the timed prompt's default from decline (N) to accept (Y)
specifically for the uv->conda hop on this basis, but decided to keep `:cascade_consent_gate`
exactly as shipped (see CLAUDE.md's Known Findings entry for the full reasoning) -- no code
change resulted from this investigation.
