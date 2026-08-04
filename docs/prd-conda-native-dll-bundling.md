# PRD: Conda Native-DLL Bundling Repair Loop (pygrib/eccodes and the General Case)

**Status:** Requirements 1-3 and 6 implemented (2026-08-04); Requirement 4's regression test
extended but not yet confirmed passing in real CI; Requirement 5 (documentation) in progress in
the same pass. See CLAUDE.md's Item 24 entry for current confirmation status. Originally written
in response to CLAUDE.md Active Backlog Item 24 (found via `self.layered_e2e.chain`'s real CI
evidence once the cStringIO warnfix fix let that test reach this far for the first time -- see
`docs/agent-closed-backlog.md`'s Item 22 entry for the discovery trail); thawed from cold storage
the same day the owner brought it forward -- see `docs/agent-cold-storage.md`'s own entry for the
original shelve-and-thaw reasoning.
**Owner:** Supervisor (Python_vs_Windows)
**Related:** `docs/agent-closed-backlog.md` Item 22 (the layered E2E test that found this),
CLAUDE.md Active Backlog Item 24, `docs/prd-av-safe-build-path.md` (the repo's other PRD stored
in cold storage -- same "cheapest option first, reactive not proactive" design philosophy applies here)

---

## Research Findings

### Finding 1 -- `hook-gribapi.py`'s actual source now confirmed; `pygrib` and `gribapi` are architecturally independent bindings, so the "free lunch" is now assessed as UNLIKELY (not just unverified) -- still worth the cheap empirical test

**Updated 2026-08-04 with the actual hook source and the pygrib/gribapi relationship, both
confirmed via direct research (not extrapolated).** `pyinstaller-hooks-contrib` (already an
installed dependency of this repo's build -- confirmed in real CI logs as version `2026.6`) ships
`hook-gribapi.py` at `_pyinstaller_hooks_contrib/stdhooks/hook-gribapi.py` (no `src/` prefix,
correcting the original guess below). Its actual mechanism, read directly from source:
1. Collects `gribapi`'s data files (`collect_data_files('gribapi')` -- header files like
   `eccodes.h`/`gribapi.h`).
2. At BUILD TIME, imports `gribapi` in the build environment and queries
   `gribapi.bindings.library_path` to locate the real eccodes shared library on disk.
3. Resolves a relative path via `_resolveCtypesImports`; on failure, logs a warning (does not
   hard-fail the build).
4. **Has explicit Windows-aware directory-preservation logic** -- calculates a destination
   relative to the package parent, producing `eccodes.libs` on Linux or `eccodes` on Windows. This
   directly contradicts an earlier, narrower assumption that the hook's shared-library awareness
   was "non-Windows only" -- it is not; Windows is a named, handled case in this exact code path.
5. If the library comes from the separate `eccodeslib` PyPI package (binary wheels for eccodes
   itself, `>= 2.37.0`), that package is added to hidden imports too, for `findlibs.find()`.

**Two separate claims here -- one proven, one still an expectation pending Requirement 1's own CI
experiment, not to be conflated (a distinction a review pass on this PR correctly flagged as
blurred in an earlier draft).**

*Proven, via the package-relationship research itself*: `pygrib` (jswhit/pygrib) and
`gribapi`/`eccodes-python` (ECMWF's official bindings, conda-forge package `python-eccodes`) are
two INDEPENDENT, unrelated Python bindings to the same underlying `eccodes` C library, from
different upstream projects -- `pygrib` does not import or depend on `gribapi` at all; it talks to
`libeccodes`/`eccodes.dll` directly through its own compiled extension. This means `hook-gribapi.py`
has no reason to fire UNFORCED for a pygrib-only project: PyInstaller's static analysis genuinely
never sees a `gribapi` import to trigger the hook on, since none exists in pygrib's own source.

*Still an expectation, not a proven negative*: whether FORCING `--hidden-import=gribapi` would
still help is a separate question this reasoning does not settle on its own. The hook's own
DLL-bundling logic (step 2 above) operates on `gribapi.bindings.library_path`, which is a fact
about `gribapi`'s own package location, not `pygrib`'s -- so it is EXPECTED to bundle a DLL that
doesn't help `pygrib`'s own separately-linked `_pygrib.cp314-win_amd64.pyd` extension, but this is
an inference from how the hook's logic reads, not something independently confirmed by running it.
It remains conceivable that PyInstaller's hook machinery, once `gribapi` is forced into the
dependency graph at all, ends up placing a copy of `eccodes.dll` somewhere `pygrib`'s own extension
can also find it (e.g. a shared `Library\bin`-adjacent location), which would make the forced
import help for a reason unrelated to the hook's own intended purpose. **Requirement 1's CI
experiment (not this section's reasoning) is the actual decision point** -- treat the paragraph
above as the expectation the experiment tests, not its conclusion.

**Still worth the empirical test, per explicit owner instruction to verify via real CI rather than
rely on analysis alone.** The conda-forge package providing `gribapi` (`python-eccodes`) does build
for win-64 (confirmed via the feedstock's own CI badge matrix, Python 3.10-3.14), so the experiment
is genuinely runnable: install `python-eccodes` alongside `pygrib`+`eccodes` in the test conda env,
force `--hidden-import=gribapi` on the build, and observe whether the resulting EXE's DLL situation
changes at all. **Updated expectation: likely a clean, informative negative result** (ruling out
the free lunch with real evidence, closing this specific question for good) rather than the
originally-hoped-for shortcut -- but a cheap, low-cost, one-CI-run experiment either way, and
worth running exactly because "likely won't work" is a probability estimate, not a certainty.

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

### Finding 6 -- interaction with the AV-Safe Build Path (Nuitka Tier A / requirement 9 optimized build), confirmed from existing shipped mechanisms

Traced directly against `docs/agent-interconnect.md`'s existing "AV-Safe Build Path Tier A and
hidden-import auto-recovery" and "requirement 9" sections -- not extrapolated, this repo already
shipped both mechanisms and their guards:

- **The existing `--hidden-import` auto-recovery loop (`:hidden_import_recover`) explicitly skips
  itself when `dist\<env>.exe` was built by Nuitka, not PyInstaller** (`HP_NUITKA_FALLBACK_USED`
  guard, added same-day Tier A shipped -- see `docs/agent-lessons-learned.md`'s "--hidden-import
  auto-recovery must stay STRICT" entry). Reason: its repair action is a PyInstaller-specific
  rebuild flag (`--hidden-import=X`); Nuitka has a structurally different, unwired mechanism
  (`--include-module`/`--follow-import-to`). **The new DLL-bundling repair loop this PRD proposes
  needs the identical guard, for the identical reason** -- `--add-binary`/`--collect-binaries` are
  PyInstaller-specific flags with no Nuitka equivalent wired up here. Any implementation MUST check
  `HP_NUITKA_FALLBACK_USED` (or an equivalent "this dist\<env>.exe was not built by PyInstaller"
  signal) before attempting a rebuild, mirroring `:hidden_import_recover`'s own early-exit shape --
  see Requirement 6 below.
- **Requirement 9's elective "optimized build?" Nuitka upsell (`:offer_optimized_build`) does not
  "fall back" to PyInstaller on failure -- there is nothing to fall back to, because the original
  PyInstaller EXE is never touched until success is fully confirmed.** It builds to a distinct temp
  filename, runs its own internal verify-launch against that temp file, and only on CONFIRMED
  success does it `move /y` the temp file over `dist\<env>.exe`. Every failure branch (build fails,
  verify-run fails, or the swap itself fails) routes through the shared `:optbuild_cleanup` label,
  which deletes only the temp file and leaves the original, already-working PyInstaller EXE
  completely untouched -- confirmed by `tests/selfapps_optimized_build.ps1`'s `forcefail`/
  `swapfail` scenarios, which explicitly re-execute the original EXE afterward to prove this. So:
  if a user's Nuitka-optimized build attempt fails for any reason, the answer is "it just doesn't
  swap," not "it falls back" -- the distinction matters because there is no active recovery step,
  just an absence of replacement.
- **Interesting side observation, not a requirement to chase**: Nuitka's `--standalone` mode uses
  its own Windows DLL dependency walker, generally understood to be more thorough at discovering
  native library dependencies than PyInstaller's warn-file-based static analysis. It is plausible
  (not verified in this research pass) that a user who hits this exact pygrib/eccodes failure under
  PyInstaller and then accepts the requirement-9 "optimized build?" upsell would find the Nuitka
  build bundles `eccodes.dll` correctly without this PRD's repair loop ever being needed for that
  specific run. This does NOT reduce the value of building the loop (Requirement 9 is elective, declined
  by default in CI and not something every user will accept, and the PyInstaller build is still the
  PRIMARY path this repo's Prime Directive depends on) -- noted here only because it is the same
  "does an existing mechanism already solve this for free" question Finding 1 asks about
  `hook-gribapi.py`, just for a different existing mechanism. Not verified; not planned as a
  dedicated investigation unless this PRD is picked up and the cheap check is worth adding then.

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

## Requirements -- IMPLEMENTED 2026-08-04

Requirements 1-3 and 6 done; Requirement 4's regression test extended but not yet CI-confirmed;
Requirement 5 done in the same pass. See CLAUDE.md's Item 24 entry for current confirmation
status. Kept below as the original design record, not rewritten to past tense throughout.

1. **Verify Finding 1 first, with zero new bootstrapper code, via its own small CI-only PR.** Add
   `python-eccodes` (the conda-forge package providing `gribapi`, confirmed to build for win-64)
   alongside `pygrib` in a minimal test build, force `--hidden-import=gribapi`, and observe whether
   `eccodes.dll` ends up bundled / the EXE runs. Per Finding 1's updated assessment this is now
   EXPECTED to come back negative (pygrib and gribapi are independent bindings), but run it anyway
   for real evidence before committing to the larger repair loop -- keep this experiment isolated
   in its own PR, not bundled with requirement 3's implementation, so a negative result doesn't
   block on or get entangled with unrelated work. **conda-forge only, matching this repo's
   established channel policy** (README.md/CLAUDE.md: `--override-channels -c conda-forge` on
   every conda install, no `defaults` channel contamination) -- a mixed-channel solve could pull a
   different `pygrib`/`eccodes` build with a different native-DLL graph, undermining the
   experiment's own reproducibility. The experiment PR's own conda env creation already does this
   (`--override-channels -c conda-forge` in its `conda create` call); record the resolved package
   versions from that run's env-create log when reporting the finding.
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
6. **`HP_NUITKA_FALLBACK_USED` early-exit guard, mandatory (see Finding 6).** The new repair loop
   must check this flag and skip (not attempt-and-fail) before any rebuild action, identical in
   shape to `:hidden_import_recover`'s own guard. No CI test currently exercises a Nuitka-built EXE
   hitting a native-DLL failure -- if one is added, it should assert the skip fires (mirroring
   `tests/selfapps_nuitka_tiera_hidden_skip.ps1`'s own regression-test shape for the sibling case).

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

**Green-leaning-Yellow (upgraded 2026-08-04 after reading `hook-gribapi.py`'s actual source and
confirming the pygrib/gribapi package relationship) -- real, well-evidenced problem, sound design
direction, and the scope question is now a probability estimate rather than a total unknown.** The
reactive-loop architecture (Finding 4) is sound and directly reuses a proven, shipped pattern from
this same codebase -- low design risk there. Finding 1's "free lunch" question is no longer
unverified-in-principle -- it is now assessed as LIKELY negative based on real research (pygrib and
gribapi are independent bindings to the same C library, confirmed via their respective upstream
docs), but Requirement 1's cheap CI experiment should still confirm this empirically before ruling
it out for good, since a probability estimate is not proof. Remaining genuine uncertainty is
narrower than before: exactly how many transitive native DLLs eccodes pulls in beyond itself
(hdf5/netcdf/proj were all observed in the same conda env in the original failure), which
Finding 4's iterative design handles without needing to know the answer up front.
