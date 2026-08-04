# PRD: Conda Native-DLL Bundling Repair Loop (pygrib/eccodes and the General Case)

**Status:** Draft v1 -- planning only, no implementation started. Written in response to CLAUDE.md
Active Backlog Item 24 (found via `self.layered_e2e.chain`'s real CI evidence once the cStringIO
warnfix fix let that test reach this far for the first time -- see `docs/agent-closed-backlog.md`'s
Item 22 entry for the discovery trail). Deliberately stored in cold storage after this draft, not scheduled
-- see `docs/agent-cold-storage.md`'s own entry for the thaw trigger.
**Owner:** Supervisor (Python_vs_Windows)
**Related:** `docs/agent-closed-backlog.md` Item 22 (the layered E2E test that found this),
CLAUDE.md Active Backlog Item 24, `docs/prd-av-safe-build-path.md` (the repo's other PRD stored
in cold storage -- same "cheapest option first, reactive not proactive" design philosophy applies here)

---

## Research Findings

### Finding 1 -- PyInstaller already has SOME upstream machinery for this exact package family; untested whether it actually covers `pygrib`

`pyinstaller-hooks-contrib` (already an installed dependency of this repo's build -- confirmed in
real CI logs as version `2026.6`) ships `hook-gribapi.py`, a standard hook for the `gribapi`
package -- eccodes's own official Python bindings. Per that project's own changelog, this hook was
specifically updated "to account for the possibility of bundled eccodes shared library," and a
companion `findlibs` runtime hook exists and was reworked for eccodes compatibility. PyInstaller's
own binary-collection machinery is also documented as aware of conda's `Library\bin` convention on
Windows.

**This does not mean the problem is already solved.** `pygrib` is a *different* PyPI/conda package
name from `gribapi`, with its own compiled extension (`_pygrib.cp314-win_amd64.pyd`, per the real
build log this PRD is responding to). PyInstaller hooks trigger on the exact top-level Python
import PyInstaller's static analysis detects -- if `pygrib`'s own C extension links against
`eccodes.dll` directly at the OS/linker level, without ever doing `import gribapi` from Python
code, `hook-gribapi.py` would never fire for a pygrib-only project, regardless of how
conda-Library\bin-aware that hook actually is. This was NOT independently verified against the
hook's actual source in this research pass (the sandbox this PRD was written in could not fetch
`pyinstaller-hooks-contrib`'s repository directly) -- **the single highest-leverage next step,
cheaper than everything else in this document, is confirming this one way or the other** before
building any new bootstrapper-side mechanism. Two ways to check, in order of cost:
1. Add `--hidden-import=gribapi` to the PyInstaller build command for the failing case and see
   whether that alone makes `hook-gribapi.py` fire and correctly bundle `eccodes.dll` (and its own
   transitive deps) -- if yes, this problem may not need ANY new bootstrapper mechanism at all,
   just a hidden-import addition scoped the same way REQ-016's existing loop already works.
2. Failing that, read `hook-gribapi.py`'s actual source (`pyinstaller-hooks-contrib`'s GitHub repo,
   `src/_pyinstaller_hooks_contrib/stdhooks/hook-gribapi.py`) to see exactly what it collects and
   whether it can be reused/imitated for `pygrib` specifically.

### Finding 2 -- `--collect-binaries=PKG` is the wrong shape for this failure; it does not cross package boundaries

Confirmed via PyInstaller's own documentation: `--collect-binaries=PKG` collects binaries found
*inside PKG's own installed package directory*. It is not a dependency-walker across unrelated
packages. Since `eccodes.dll` lives in conda's shared `Library\bin`, not inside `pygrib`'s own
site-packages folder, `--collect-binaries=pygrib` would very likely find nothing -- the DLL isn't
where that flag looks. `--collect-binaries=eccodes` is a closer guess (if eccodes's own Python
package tree contains anything binary) but still uncertain, since the DLL's actual location is the
shared `Library\bin` convention, not a package-local one. `--collect-all=PKG` has the identical
directory-scoping problem, plus it is much heavier (bundles all of a package's data+binaries+
submodules, not just the one missing DLL) -- rejected for the same reason this repo's own
`--collect-submodules` mechanism deliberately excludes heavy stacks like torch/tensorflow (see
`docs/agent-lessons-learned.md`'s "Pre-build --collect-submodules must be DOUBLE-gated" entry).

### Finding 3 -- this repo already has a working, shipped example of exactly this failure class: `libexpat` under REQ-007 -- but it is single-purpose, not generalized

`run_setup.bat`'s `:compute_collect_flags`-adjacent REQ-007 block globs for
`%HP_PY_DIR%Library\bin\libexpat*.dll` and, if found, emits `--add-binary "<path>;."` on the
PyInstaller build command line, logged as `[INFO] REQ-007: bundling conda libexpat DLL for
pyexpat: ...`. This is real, proven, shipped evidence that the "explicit `--add-binary` glob
against conda's `Library\bin`" approach genuinely works for at least one native DLL in this exact
codebase. It is entirely hardcoded to `libexpat` specifically -- the glob pattern, variable names
(`HP_PYI_EXPAT`), and log text are all expat-literal, with no generality and no "is this DLL
actually needed" gate beyond "does the file exist in `Library\bin`." Copy-pasting this pattern for
`eccodes` would work for the ONE named DLL, but inherits the same single-DLL blind spot Finding 4
below addresses.

### Finding 4 -- the existing `--hidden-import` auto-recovery loop is the right architectural template, not the collect/add-binary flags in isolation

This repo already ships a REACTIVE, bounded, iterative repair loop for a structurally similar
problem: `:hidden_import_recover` (REQ-016 Slice 2) re-runs a failed frozen EXE, scans its captured
output for a *specific* error signature (`ModuleNotFoundError` for an installed module), and only
then attempts a targeted rebuild -- bounded to 3 attempts, with a tried-list so the same fix is
never attempted twice (see `docs/agent-lessons-learned.md`'s "--hidden-import auto-recovery must
stay STRICT" entry for the full design). This is deliberately **reactive, never proactive** --
matching the same design principle `docs/prd-av-safe-build-path.md`'s Tier A already established
("let Nuitka do its own internal compiler discovery... do not build an independent detection
check").

A DLL-bundling repair loop should reuse this exact shape, not just the `--add-binary`/glob
mechanics from Finding 3: re-run the EXE, scan output for `ImportError: DLL load failed... The
specified module could not be found` (or the equivalent PyInstaller build-time `WARNING: Library
not found: could not resolve '<name>.dll'` signal, which is available even earlier -- at build
time, before any smoke-test run is needed at all, see the Requirements section below for why this
matters), locate and bundle the NAMED missing DLL from `%CONDA_PREFIX%\Library\bin`, rebuild, and
re-run. If a DIFFERENT DLL is now missing (a transitive dependency of the first), the SAME loop
catches it on the next iteration -- this is what elegantly solves Finding 3's single-DLL blind
spot without needing to solve "walk the full transitive dependency graph up front," which would be
a much larger and more fragile undertaking (Windows has no single, universally-available tool for
this the way `ldd` serves on Linux -- `dumpbin` requires a Visual Studio install, which this
bootstrapper cannot assume is present).

### Finding 5 -- the build-time warning is a stronger, earlier signal than the runtime crash, and may not even need a "post-smoke" trigger

Unlike `--hidden-import` auto-recovery (which has no earlier signal than the runtime
`ModuleNotFoundError` -- PyInstaller's static analysis cannot tell whether a genuinely-installed
module will actually be imported by the running program), THIS failure class already announces
itself at BUILD time: `WARNING: Library not found: could not resolve 'eccodes.dll', dependency of
'...\pygrib\_pygrib.cp314-win_amd64.pyd'`. This is available in the PyInstaller build log
immediately after the build step, before the EXE is ever smoke-run. A design that reacts to this
build-time warning (parallel to how `parse_warn.py` already parses PyInstaller's warn file for a
DIFFERENT purpose -- missing Python modules, not missing binaries) could trigger the repair BEFORE
the first smoke-test run ever happens, instead of waiting for a guaranteed-to-fail runtime crash
first. This is a real design choice to make explicitly (see Requirements, P0 item 2) -- build-time
detection is strictly cheaper (skips one guaranteed-failing smoke run) but needs a new parser for a
different PyInstaller output stream than the existing `parse_warn.py` handles; runtime detection
reuses `:hidden_import_recover`'s existing scan-and-react shape almost exactly, at the cost of one
wasted smoke-test cycle per missing DLL.

## Problem Statement

`pygrib`'s conda-forge build genuinely installs and PyInstaller's build genuinely succeeds when the
uv-to-conda provider cascade lands a user on the conda provider for a package needing native
C-library dependencies conda ships separately (via its own `Library\bin` shared-library
convention). But the frozen EXE then fails at runtime (`ImportError: DLL load failed`) because
PyInstaller does not discover or bundle that native DLL dependency -- silently defeating the whole
point of having successfully cascaded to conda in the first place. This is currently the ONLY
remaining gap keeping `self.layered_e2e.chain` (the real end-to-end test proving "why you'd need
conda over uv") at `pass:false`; the two mechanisms that test actually exists to prove (REQ-009
cascade, warnfix repair) both now genuinely pass.

## Goals

1. When a frozen EXE fails at runtime with a native-DLL-load-failure signature (or, per Finding 5,
   when PyInstaller's own build log already warns about an unresolved `.dll` dependency), locate
   the missing DLL in the conda environment's `Library\bin` and bundle it, then rebuild and
   re-verify -- reactively, never proactively, matching this repo's established design philosophy.
2. Handle the "one DLL might not be the whole fix" case (transitive native dependencies) via
   bounded iteration, reusing the shape of the existing `--hidden-import` auto-recovery loop, not
   by trying to solve full dependency-graph resolution up front.
3. Scope the actual repair ACTION to the conda provider specifically (`%CONDA_PREFIX%\Library\bin`
   has no meaning under uv/embed/venv/system) -- detection can stay provider-agnostic and cheap.
4. Before building any new mechanism, verify Finding 1's cheaper alternative
   (`--hidden-import=gribapi` triggering an existing upstream hook) does not already solve this
   for free.

## Non-Goals

- **Solving this for every possible native-DLL-dependent package speculatively.** Scope to what
  the real, observed failure needs (`eccodes.dll`, and whatever its own transitive chain turns out
  to be) first; generalize only if a second, unrelated conda-native-DLL gap is actually observed
  (see the Open Question below on narrow-vs-general scope).
- **A full Windows DLL dependency-graph walker** (the `dumpbin`/`ldd`-equivalent problem). Too
  heavy, needs tooling this bootstrapper cannot assume is present. The iterative reactive-loop
  design (Finding 4) is the deliberate alternative to building this.
- **Fixing this under uv/embed/venv/system.** These providers install from PyPI wheels, which are
  expected to vendor their own native dependencies inside the wheel (the whole point of the
  manylinux/Windows-wheel packaging standard) -- this specific failure shape is conda-specific by
  construction. A package that ships a broken/incomplete wheel is a different, unrelated problem
  this PRD does not address.
- **Upstreaming a fix to `pyinstaller-hooks-contrib` itself.** Worth considering later if Finding 1
  confirms a real gap there, but out of scope for this bootstrapper's own PRD -- track separately if
  it becomes relevant.

## Requirements (sketch only -- not sequenced into P0/P1 until this is actually picked up)

1. **Verify Finding 1 first, with zero new bootstrapper code.** Manually (or via a scratch CI
   experiment) add `--hidden-import=gribapi` to a `pygrib` build and observe whether
   `hook-gribapi.py` already resolves `eccodes.dll` correctly under conda on Windows. If yes, the
   fix may be as small as extending the EXISTING `--hidden-import` mechanism's own scope (or a
   small, targeted addition informed by exactly what the hook needs), not a new repair loop at all.
2. **Decide build-time vs. runtime detection (Finding 5).** Prototype whichever is cheaper to wire
   given requirement 1's outcome; a build-time detector reuses `parse_warn.py`'s general shape
   (new pattern, same file family) but targets a different PyInstaller output stream (`Library not
   found: could not resolve` warnings, not the missing-module warn file); a runtime detector reuses
   `:hidden_import_recover`'s existing scan-and-react loop shape almost directly.
3. **New repair loop, gated to `HP_ENV_MODE=conda` for the actual bundling action.** Mirror
   `:hidden_import_recover`'s bounded-iteration, tried-list shape (see Finding 4) -- not a
   single-shot fix. Detection stays provider-agnostic (cheap, always checked); the DLL-glob-and-
   `--add-binary` action itself no-ops (with a clear log line) under any non-conda provider.
4. **Regression test forcing the real `pygrib`/`eccodes` failure**, modeled on how
   `tests/selfapps_layered_e2e.ps1` already reaches this exact failure for real today (no new
   simulated-failure hook needed -- the failure is already reliably reproducible via the existing
   test's own uv-to-conda cascade). Assert the loop bundles the DLL, rebuilds, and the final EXE
   genuinely runs and prints its token -- this is the acceptance criterion that would finally flip
   `self.layered_e2e.chain`'s `chainPass` to `True`.
5. **Documentation**: CLAUDE.md's Item 24 gets its resolution written up (mirroring how Item 22 and
   Item 23 were each closed with a full mechanism trace); `docs/agent-interconnect.md` gets a new
   section analogous to "Tier A and hidden-import auto-recovery" describing how this new loop
   relates to the existing one (touch one, must understand the other, if they end up sharing any
   scan infrastructure).

## Level Check (explicitly requested by the owner)

**Still on-target, not scope creep.** This repo's own established narrative -- proven out in
`selfapps_cascade.ps1`'s header comment ("the main gain: conda is the strongest solver") and the
whole design of the layered E2E test -- is showcasing concrete, real reasons a user would need
conda's deeper bootstrapping over plain uv/pip. `pygrib` (zero Windows PyPI wheels, real
conda-forge binaries) is already exactly that story for the *install* step. Item 24 is that same
story's natural continuation into the *packaging* step: not just "conda can install what pip
can't," but "the bootstrapper can also freeze a conda-installed native-dependent package into a
working standalone EXE" -- arguably an even sharper, more specific value proposition, since
PyInstaller-plus-conda-native-packages is a genuinely gnarly combination many people struggle with
even by hand. Finishing this closes the loop on the exact demonstration this repo has been building
toward, rather than diverging from it.

## Open Questions

- **Narrow (pygrib/eccodes-only) fix vs. a general "conda native-DLL repair loop" that could catch
  a FUTURE, different package's missing-DLL gap too -- genuinely undecided, needs the maintainer's
  call.** A narrow fix (hardcode the eccodes DLL name/glob, mirroring REQ-007's libexpat pattern
  exactly) is cheap and directly closes the one known failure. A general version (detect ANY
  `Library not found: could not resolve 'X.dll'` pattern, not just eccodes by name, and bundle
  whatever `X` turns out to be) costs more to build and test but would silently cover any future
  conda-forge package hitting the same PyInstaller gap, without needing its own dedicated PRD each
  time. Given Finding 4's iterative-loop design is barely more general than a single-DLL fix once
  built (the loop shape does not care whether the DLL name is hardcoded or parsed from the
  warning), this leans toward "build it general from the start is not much extra cost over
  building it narrow" -- but this is exactly the kind of proportionality judgment
  `docs/prd-av-safe-build-path.md`'s own "Notes from Claude" section on pin-generalization warns
  against deciding unilaterally. Flagged here rather than resolved.

## Confidence Assessment

**Yellow -- real, well-evidenced problem with a plausible design direction, but the single most
important fact (does `--hidden-import=gribapi` already solve this via the existing upstream hook)
is unverified.** The reactive-loop architecture (Finding 4) is sound and directly reuses a proven,
shipped pattern from this same codebase -- low design risk there. The genuine uncertainty is
scope: this PRD could describe either "add one hidden-import flag" or "build a new repair
subsystem," and which one is true depends entirely on Finding 1's still-open verification. Do not
start implementation without resolving that first -- it changes the size of this work by an order
of magnitude in either direction.
