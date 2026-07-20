# Plan: Two-Tier `autopep723` Integration (Default Path discovery + `HP_PVW_KNOWN_IDEMPOTENT`)

**Status:** Both prerequisites shipped (`plan-pep723-writeback.md`'s write-back, REQ-005.11; and
`plan-pvw-quickstart.md`'s README commands, with a standalone CI dry-run proof too --
`tests/selfapps_pvw_quickstart.ps1`, 2026-07-19). **Tier 1 (REQ-005.12) is now SHIPPED**
(2026-07-20) -- `tools/autopep_merge.py` (canonical source + `HP_AUTOPEP_MERGE` PayloadSync),
the `run_setup.bat` insertion at `:after_pipreqs_run`, `tests/test_autopep_merge.py` (18 unit
tests), `tests/selfapps_autopep_discovery.ps1` (uv lane, non-gating CI proof), and doc updates
(README's REQ-005.12 section, `docs/agent-ndjson.md`, `docs/agent-interconnect.md`) all landed
together. See Tier 1's own section below for what was built exactly as designed vs. what changed
during implementation. **Tier 2's own code-grounded pass is now done (2026-07-20, prep only)** --
hook point, data-flow (requirements.txt population), and reuse points are settled; implementation
itself is intentionally on hold until Tier 1's PR actually merges, per this doc's own explicit
sequencing dependency -- still **sequenced after Tier 1** within this doc.
Supersedes `plan-pvw-quickstart.md`'s "Shape B" (a vaguely-specified, deliberately-deferred
`run_setup.bat` hook) with a concrete design -- see that doc's own Shape B section, now pointing
here.
**Owner:** Python_vs_Windows maintainer
**Source material:** a user-supplied third-party spec ("Two-Tier autopep723 Strategy for PVW").
Not reproduced verbatim here; this doc states what was verified, what was corrected, and why, per
this repo's established practice of testing third-party claims directly (source code, not just
behavior) rather than accepting them on authority.
**Related:** `docs/plan-pep723-writeback.md` and `docs/plan-pvw-quickstart.md` (both prerequisite,
must ship first); `docs/agent-lessons-learned.md`'s "`autopep723`'s own import-detection is
environment-leaky under direct invocation, safe under `uvx`" section (the empirical foundation
this doc's two corrections are built on -- read that first); `CLAUDE.md` Active Backlog (this item
is linked from there).

---

## Sequencing (explicit, per the request that raised this)

1. `plan-pep723-writeback.md` ships (automatic write-back inside `run_setup.bat`, uv lane). SHIPPED.
2. `plan-pvw-quickstart.md`'s commands, already shipped in README, get real-world use and comfort. SHIPPED.
3. **This doc's Tier 1**: add `autopep723 check` alongside `pipreqs` in the Default Path discovery
   phase, for all users, non-gating. **SHIPPED 2026-07-20.**
4. **This doc's Tier 2**: `HP_PVW_KNOWN_IDEMPOTENT`, an opt-in flag enabling runtime
   (execute-mode) discovery inside `run_setup.bat` itself. Not yet started.

Tier 2 is the next step whenever picked up.

---

## Two corrections to the source spec, both found via direct testing and source-code reading

The source spec's central empirical claim -- "autopep723 check never reports delta, it's
environment-independent" -- was the load-bearing justification for its entire discovery-merge
design. Both of the following were checked directly rather than trusted, per this repo's
established pattern for third-party claims (see `plan-pep723-writeback.md`'s own multi-pass
history). One of the two claims does not hold as stated; the other reveals a concrete
implementation bug in the spec's own proposed code.

### Correction 1: the proposed insertion snippet passes a directory, not a file -- confirmed broken

The spec's own "Scope: v1" code sample runs:
```powershell
uvx autopep723 check . > "requirements.autopep.txt"
```
`autopep723` is strictly single-file (confirmed via `cli.py`'s argument parser -- no directory,
glob, or multi-file mode exists anywhere in the tool). Passing `.` hits `Path.read_text()`'s
`IsADirectoryError` inside `get_third_party_imports()`, which is caught and converted into an
**empty result with exit code 0** -- not a nonzero failure the spec's own "autopep723 fail != lane
fail" fallback logic could catch. Confirmed directly:
```
$ uvx autopep723 check .
Warning: '.' does not have a .py extension.
Error: Error reading .: [Errno 21] Is a directory: '.'
# /// script
# requires-python = ">=3.13"
# ///
EXIT: 0
```
As written, this design would produce an empty `requirements.autopep.txt` on **every single run**,
silently, with no error signal -- the entire merge-with-pipreqs mechanism would be a permanent
no-op. **Fix, mandatory before any implementation**: target the actual resolved entry file (this
repo's `%HP_ENTRY%`), never a directory or `.`.

### Correction 2: "never reports delta" is false as a blanket claim -- but the real behavior is still usable

See `docs/agent-lessons-learned.md`'s full writeup (the empirical trail, both confirmations and
counter-examples, lives there -- not duplicated here). Summary of the conclusion: `autopep723`'s
import detection depends on `pkgutil.iter_modules()`'s view of whatever Python process is running
it, so it silently drops already-installed packages from its "third-party" output when invoked
through a *direct* interpreter that already has some of the target script's dependencies
installed. It does **not** do this when invoked via `uvx` (an isolated tool venv), and `uvx` is
additionally confirmed immune to an active `VIRTUAL_ENV` pointing at a dirty environment -- but
still vulnerable to a leaked `PYTHONPATH`.

**Net effect on this design specifically**: the source spec's v1 snippet already uses `uvx`, and
`run_setup.bat` already clears `PYTHONPATH`/`PYTHONHOME` (REQ-010 isolation) well before the
discovery phase this design would insert into -- so **Tier 1 as corrected (fixing Correction 1)
is safe from this hazard as scoped.** The spec's own "Scope: Future Lanes" section, however,
proposes `conda run python -m autopep723 check` for a hypothetical future conda-lane
integration -- a *direct* interpreter invocation into a potentially non-empty conda environment.
**That proposal is not safe and must not be implemented as written** -- any future lane extension
must keep using `uvx`, never a lane's own interpreter, regardless of which lane it targets.

This also resolves, rather than merely caveats, the "lost reproduction" the requester described:
a collaborator suspected this exact delta bug, lost the specific repro, and couldn't tell if it
was a miscommunication. It wasn't a miscommunication -- the bug is real and reliably reproducible,
it is just conditional on invocation method in a way that made it easy to "fix" by accident
(switching from a direct interpreter to `uvx` between sessions) without anyone identifying why the
behavior changed.

---

## What holds up, re-confirmed or already established elsewhere

- **`autopep723 add` loses indirect dependencies; `uv add --script` does not** -- already
  established across this repo's prior testing (`plan-pep723-writeback.md`,
  `plan-pvw-quickstart.md`, `agent-lessons-learned.md`'s consolidated `uv` section). The source
  spec's "Why Not Use autopep723 add for Writeback" reasoning matches this repo's own
  already-adopted decision; no new verification needed, cited here for completeness.
- **UV-only writeback** (no `conda add --script`/`pip add --script` equivalent exists) -- same,
  already established.
- **`HP_PVW_KNOWN_IDEMPOTENT`'s exit-code branching (0 / 2 / other-nonzero) is not a new design --
  it is the exact mechanism already built, tested across a dozen-plus scenarios, and shipped in
  README's "PVW QuickStart" section** (the "Just run it (and remember what it needed)" command).
  Tier 2 below is that same, already-proven logic relocated into `run_setup.bat` as opt-in code,
  not a new mechanism invented from scratch. This substantially de-risks Tier 2 relative to how it
  would look if proposed cold.
- **`autopep723` has zero runtime dependencies of its own** and is strictly single-file --
  confirmed via its distribution metadata and `cli.py`'s argument parser. Relevant because it
  means `pkgutil.iter_modules()` (Correction 2) has nothing of `autopep723`'s own to leak, only
  whatever the invoking environment happens to already have installed.
- **uvx tool-venv caching is real** (confirmed faster on a second identical invocation), consistent
  with `uv`'s documented tool-cache behavior. Not independently re-verified in depth here; low risk
  if the exact magnitude is off, since it doesn't affect correctness.

---

## Tier 1: Default Path discovery augmentation (corrected design)

**Goal**: run `autopep723 check` alongside `pipreqs` during discovery, merge the results (union),
for all users, on all lanes eventually (v1: uv lane, matching `plan-pep723-writeback.md`'s own v1
scope decision) -- non-gating, never a cause of lane failure on its own.

**Insertion point (code-grounded, 2026-07-19 -- re-verify line numbers before implementing,
they drift):** right after `:after_pipreqs_run`'s `requirements.txt`/`requirements.auto.txt`
finalization and diff computation (the `fc` comparison, `run_setup.bat` ~line 1290-1293), before
the dep-check fast-path setup (`set "HP_DEP_SKIP="`, ~line 1294/1298). This is genuinely "after
pipreqs completes and requirements.txt is finalized, before the existing
dependency-optimization/heuristics steps" as originally described -- the heuristic augmentation
(`~prep_requirements.py`) and dependency install don't start until ~line 1330.

**`%HP_ENTRY%` availability confirmed** via a dedicated control-flow trace (not just grep): the
`:determine_entry` call at ~line 975 runs strictly before the pipreqs block, on the SAME straight-
line path with no intervening `goto`, and reliably leaves `HP_ENTRY` set to a real, existing file
path by the time execution reaches `:after_pipreqs_run`. Two things that could have broken this
assumption were checked and ruled out: (1) a SECOND `:determine_entry` call exists at ~line 1662,
but it only runs ~400 lines later, after the entire dependency-install/PEP-723-writeback block has
already finished -- it cannot affect the value read at this insertion point. (2) `HP_CI_SKIP_ENV=1`
bypasses the ENTIRE block this insertion point lives in (a `goto` at ~line 431 jumps straight to
`:ci_skip_entry`) -- that lane never reaches this code at all, so it's a non-issue, not something
needing special-case handling.

**One narrow, pre-existing edge case to guard against defensively**: if a repo's only top-level
`.py` file(s) are `._`-prefixed macOS AppleDouble shadow files (no real `.py` present), `PYCOUNT`
(which gates the whole block) can be >=1 while `tools/find_entry.py`'s own filtering excludes them,
leaving `HP_ENTRY` empty at this point. This is an existing gap unrelated to this feature -- the
new code should simply `if defined HP_ENTRY` before invoking `autopep723 check`, both to handle
this case and as ordinary defensive coding.

**Corrected invocation** (fixing Correction 1):
```
if defined HP_ENTRY uvx autopep723 check "%HP_ENTRY%" > "requirements.autopep.txt" 2>>"%LOG%"
```
Never `.`, never a bare directory. `%HP_ENTRY%` is this repo's existing resolved-entry-file
variable (REQ-002) -- reuse it, do not re-derive an entry path independently.

**Failure semantics** (from the source spec, still sound): `autopep723 check` failing (nonzero
exit -- a genuine failure this time, not the directory-argument false-zero from Correction 1) must
never propagate to lane failure. Fall back to pipreqs-only results and continue. `pipreqs` failure
already has its own established fallback path in this repo; `autopep723` is strictly additive on
top of that, never a replacement for it.

**Merge target decision (code-grounded, 2026-07-19): `requirements.txt` only, not
`requirements.auto.txt`.** Traced what actually consumes each file: `tools/dep_check.py`'s fast
path (`HP_DEP_SKIP`) reads `requirements.auto.txt` (pipreqs's raw output) to decide whether the
slow conda bulk-install solver can be skipped on a repeat run -- but even when it fires and skips
conda, the existing UNCONDITIONAL "pip gap-fill" step right after it (`%HP_PY% -m pip install -r
requirements.txt`, `run_setup.bat` ~line 1348) still runs regardless, and it reads the MERGED
`requirements.txt`, not `requirements.auto.txt`. So merging autopep's discoveries into
`requirements.txt` alone is sufficient for correctness -- anything autopep-only-discovered still
gets installed either way, no `requirements.auto.txt` change needed for v1.
**Known, accepted trade-off, not a bug**: on a repeat run where the dep-check fast path fires
(pipreqs's OWN detected set is already satisfied by the lock), an autopep-only-discovered package
will always go through the pip gap-fill path rather than conda, since `dep_check.py`'s own
comparison never sees it. This mirrors this repo's existing, already-documented "pip gap-fill
safety net" pattern (`selfapps_pipgap.ps1`: "conda misses opencv-python, pip fills it") rather than
introducing a new failure mode -- acceptable for v1, worth revisiting only if it proves disruptive
in practice.

**Merge**: union of pipreqs's and `autopep723 check`'s package lists, deduplicated. A dedicated
small Python helper (mirroring `tools/prep_requirements.py`'s existing role, not a from-scratch
design) is the right shape for this -- simple set-union logic, no TOML parsing needed since this
touches `requirements.txt`, not a PEP 723 header.

**Status: SHIPPED** (2026-07-20). Built exactly as designed above, with one refinement worth
recording: the invocation resolves `uvx` as `%HP_UV_EXE:uv.exe=uvx.exe%` (a substring
substitution on the already-resolved `HP_UV_EXE`, guarded by `if exist` before use) rather than a
bare `uvx` on PATH or a path derived from `HP_UV_BIN` directly -- the latter would silently break
under the `PVW_UV_EXE` super-user override, where `HP_UV_BIN` never gets anything extracted into
it at all. See `docs/agent-interconnect.md`'s "autopep723 discovery merge (REQ-005.12, Tier 1)"
section for the full reasoning. `tools/autopep_merge.py` (the merge helper, embedded as
`HP_AUTOPEP_MERGE`) is a small, dedicated `tools/` file as anticipated, not an extension of
`prep_requirements.py` -- simple case-insensitive set-union against `requirements.txt`'s existing
top-level names, with a defensive trailing-newline repair before appending. CI proof:
`tests/selfapps_autopep_discovery.ps1` (uv lane, non-gating) isolates Tier 1's own contribution by
setting `HP_SKIP_PIPREQS=1` so the merged `requirements.txt` is populated by autopep723 discovery
alone, then asserts the app actually builds and runs from it -- not just that a log line appears.

---

## Tier 2: `HP_PVW_KNOWN_IDEMPOTENT` (corrected, cross-referenced to already-shipped logic)

**Goal**: an opt-in flag causing `run_setup.bat` to use runtime (execute-mode) discovery --
actually running the user's script via `uvx autopep723 <file>` as part of dependency discovery --
for advanced users who have explicitly declared their script safe to run more than once.

**This reuses README's already-shipped, already-tested exit-code-branching design verbatim, not a
new mechanism**: exit 0 (ran clean) -> best-effort persist; exit 2 (malformed header) -> the one
case where backing up, stripping, and retrying is correct; any other nonzero exit -> fill in what's
missing without stripping, retry once. Every one of these branches, and the reasoning behind each,
is already documented in README's "PVW QuickStart" section and `docs/plan-pvw-quickstart.md`'s
"Pass 2" -- this design does not re-derive it, it relocates it.

**What genuinely changes by moving this into `run_setup.bat`, and must be respected:**

- **REQ-018 interaction, addressed by construction, not by exception.** `plan-pvw-quickstart.md`'s
  original "Shape B" rejection worried about needing to "re-derive a parallel, smaller version" of
  REQ-018's safety reasoning for a mode that skips verification. The resolution this sequencing
  provides: `HP_PVW_KNOWN_IDEMPOTENT` is not asking `run_setup.bat` to skip REQ-018's protections
  for everyone -- it is an opt-in flag whose very name is the user's own explicit, self-declared
  consent ("I know this script is idempotent"), which is exactly the category REQ-019 ("flags only
  suppress, or add an alternate opt-in behavior, never gate the default") already permits. The flag
  does not change behavior for anyone who doesn't set it.
- **Must become real `run_setup.bat` code, not just a description.** Unlike Tier 1 (which mostly
  reuses existing batch/Python plumbing), Tier 2 needs its own embedded helper (base64 payload +
  canonical `tools/` source + `PayloadSync` test, per this repo's established convention -- see
  `CLAUDE.md`'s "Rebuilding embedded helper payloads" section) implementing the same branch logic
  README's PowerShell commands already prove out, translated into whatever language/shape fits
  `run_setup.bat`'s existing dispatch conventions (goto-based, not parenthesized blocks -- see
  `agent-lessons-learned.md`'s "Provider-cascade dispatch is goto-based on purpose").
- **Precondition: uv lane only**, matching Tier 1 and `plan-pep723-writeback.md`'s own v1 scope.
  Non-uv lanes fall back to the Default Path (Tier 1, or plain `pipreqs` if Tier 1 hasn't shipped
  yet) with no special handling needed.
- **`check` mode's role here is unchanged from Correction 2's finding**: if execute mode fails for
  a reason other than a malformed header, `autopep723 check` is used to discover what's missing --
  same `uvx`-only, `%HP_ENTRY%`-targeted invocation rule from Tier 1 applies here too, for the same
  reasons.

**Code-grounded pass (2026-07-20, prep only -- no `run_setup.bat` code written).** Tier 1
(REQ-005.12) has shipped its code but not yet merged (open PR as of this writing) -- per the
sequencing above, Tier 2 implementation itself should not begin until that lands. This section
records the hook-point research done in the meantime, so Tier 2 is ready to implement as soon as
Tier 1 merges, mirroring how Tier 1's own prep phase preceded its implementation by one day.

**Hook point: right after `:determine_entry` returns (`run_setup.bat` ~line 977), before the
`HP_PYPROJ_REQ`/pyproject.toml block begins.** This is EARLIER than Tier 1's own insertion point
(`:after_pipreqs_run`, ~line 1294) -- Tier 2 needs to run before requirements.txt/pyproject.toml/
PEP 723/pipreqs are even considered, not after, because its entire premise is "skip static
discovery, use execution instead." `%HP_ENTRY%` is confirmed available here (this is literally the
line immediately following the `call :determine_entry "%~1"` / errorlevel-checks that set it) and
`%HP_PY%`/`%HP_ENV_MODE%` are both already confirmed set well before this point (the `if not
defined HP_PY (call :die ...)` guard sits a few lines above `:determine_entry`'s call site, and
`HP_ENV_MODE=uv` is set during provider selection around lines 738-811, long before either).

**Does NOT need to bypass PEP 723 handling as a separate concern.** `uvx autopep723 <file>` (bare
run mode, no `check`) already respects an existing PEP 723 header on its own -- it uses the
header's declared dependencies to set up the run, and only surfaces something new via a
`ModuleNotFoundError` during actual execution. So Tier 2 doesn't need its own PEP-723-awareness;
it inherits `autopep723`'s already-correct behavior for that case for free.

**The real design wrinkle, found by tracing what happens AFTER this hook point returns.**
Skipping straight to `:after_pipreqs_run` (as an initial sketch of "just run it, then rejoin the
normal flow" might assume) would be wrong: `:after_pipreqs_run` onward -- the dep-check fast path,
`~prep_requirements.py`'s heuristic augmentation, and the actual `pip`/`conda install` step -- all
operate on `requirements.txt`, not on the entry file's PEP 723 header directly. Tier 2's
`uv add --script` persist step (the exact same mechanism `tools/pep723_writeback.py` already uses)
only updates the HEADER, not `requirements.txt` -- so a naive "run, persist, jump to
`:after_pipreqs_run`" would leave `requirements.txt` empty and the normal install phase would have
nothing to install. **Fix, confirmed reusable rather than needing new code**: after persisting,
call the ALREADY-EXISTING `:extract_pep723_requirements` subroutine (`run_setup.bat` ~line 2423,
already used at line 1017 for the pre-existing "entry file already has a PEP 723 header" case) to
re-extract the just-updated header straight into `requirements.txt` -- identical shape to what the
existing PEP 723 detection branch already does when a header exists on entry, just triggered from
the Tier 2 branch instead. This means Tier 2 does not need a second requirements.txt-writing
mechanism of its own; it reuses the one already there.

**`HP_SKIP_PIPREQS=1` should be set internally (not just user-settable) once Tier 2's run
completes**, so the normal pipreqs block further down the file doesn't redundantly re-scan a
script whose dependencies are now already fully known via the just-updated header -- mirrors how
the `non_utf8`/`warnfix` test scenarios in `selfapps_pep723_writeback.ps1` already use
`HP_SKIP_PIPREQS=1` to isolate a single discovery mechanism, just set by the bootstrapper itself
here rather than by a test.

**Strip-and-retry logic should be reused, not reimplemented.** The exit-code branching (0 / 2 /
other-nonzero) and the malformed-header strip-and-retry-once sequence are BOTH already implemented
twice in this codebase -- once in `tools/pep723_writeback.py` (the `run_setup.bat`-integrated
version, REQ-005.11) and once in README's shipped QuickStart PowerShell commands (proven end-to-end
by `tests/selfapps_pvw_quickstart.ps1`'s `run` scenario). Tier 2's own embedded helper should be
structured as closely as possible to `tools/pep723_writeback.py`'s existing shape (same strip
state-machine, same encoding pre-check, same `.py.lock` sidecar check) rather than a fresh
implementation of the same logic a third time -- the difference is WHEN it fires (proactively, as
the discovery mechanism itself, vs. reactively, after a normal install already succeeded) and WHAT
it wraps (`uvx autopep723 <file>` execution, vs. a plain `uv add --script` call against an
already-resolved dependency set), not the branching logic itself.

**Double-execution is intentional, not a REQ-018 gap.** Under `HP_PVW_KNOWN_IDEMPOTENT=1`, the
user's script runs twice: once here (via `uvx`, in an ephemeral uv-managed tool venv, for
discovery) and once later during the normal PyInstaller EXE build's smoke-test verification (in
the real, persistent environment, producing the actual deliverable). This is exactly what the
flag's name asks the user to consent to, and does not need a special REQ-018 carve-out beyond the
one already described above ("the flag's very name is the user's own explicit, self-declared
consent").

**Remaining before this is fully implementation-ready** (unlike Tier 1, which reached that bar):
the exact embedded-helper shape (Python is still the likely choice, per the still-open language
question below) has not been written, and the CI test plan has not been drafted. Both are smaller
remaining steps than the hook-point/data-flow questions this pass resolved.

---

## Open questions for whenever this is picked up

- ~~Exact `run_setup.bat` insertion label for Tier 1~~ -- **resolved 2026-07-19**, see Tier 1's own
  section above (`:after_pipreqs_run`'s diff computation, before the dep-check fast-path setup).
- ~~Exact shape of the merge helper~~ -- **resolved and shipped 2026-07-20**: `tools/autopep_merge.py`,
  a new small `tools/` file (not an extension of `prep_requirements.py`), matching the anticipated
  shape exactly.
- ~~CI test plan for Tier 1~~ -- **resolved and shipped 2026-07-20**: `tests/selfapps_autopep_discovery.ps1`
  (uv lane, non-gating), following the `HP_SKIP_PIPREQS=1`-isolation pattern already established by
  `plan-pep723-writeback.md`'s `non_utf8`/`warnfix` scenarios.
- Whether Tier 2's embedded helper should be Python (matching most of this repo's other embedded
  helpers) or a translated PowerShell approach closer to README's shipped commands -- Python is
  likely the better fit given `run_setup.bat`'s existing conventions, but the README commands are
  the proven reference implementation either way. Still open -- Tier 2 has not been picked up.
- CI test plan for Tier 2 (not drafted here -- follow the pattern established in
  `plan-pep723-writeback.md`'s Part 2.3 and Tier 1's own now-shipped test above). Note:
  `tests/selfapps_pvw_quickstart.ps1` (2026-07-19) already covers the underlying `uv`/`autopep723`
  mechanics Tier 2 depends on -- it is NOT a substitute for Tier 2's own eventual CI test plan
  (which needs to test the bootstrapper-integrated behavior, not just the standalone tool calls),
  but it means Tier 2's CI test plan can assume those mechanics already work rather than needing
  to re-prove them from scratch.

---

## Critical files

**Tier 1 (shipped 2026-07-20):**
- `run_setup.bat` -- the `:after_pipreqs_run` insertion (REQ-005.12) and `HP_AUTOPEP_MERGE`
  payload declaration.
- `tools/autopep_merge.py` -- the merge helper's canonical source.
- `tests/test_autopep_merge.py` -- unit tests + `PayloadSync`.
- `tests/selfapps_autopep_discovery.ps1` -- uv-lane, non-gating CI proof.
- `README.md`, `docs/agent-ndjson.md`, `docs/agent-interconnect.md`, `CLAUDE.md` -- doc updates.

**Tier 2 (not yet started):**
- `run_setup.bat` -- new `HP_PVW_KNOWN_IDEMPOTENT` dispatch and embedded-helper payload
  declaration.
- A new embedded helper following the `tools/collect_submodules.py` /
  `tools/hidden_import_scan.py` canonical-source-plus-`PayloadSync` pattern.
- `tests/` -- new CI test file(s).
- `README.md` -- `HP_PVW_KNOWN_IDEMPOTENT` flag documented alongside the existing "Advanced
  Environment Variables" table; cross-reference the already-shipped PVW QuickStart section rather
  than re-explaining the branch logic.
- `CLAUDE.md` -- Active Backlog pointer, mirroring the existing sibling-plan entries' style.
