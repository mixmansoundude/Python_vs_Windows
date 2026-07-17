# Plan: Two-Tier `autopep723` Integration (Default Path discovery + `HP_PVW_KNOWN_IDEMPOTENT`)

**Status:** Design-only, not scheduled, **sequenced last** in the PEP 723 work: after
`docs/plan-pep723-writeback.md` is implemented AND `docs/plan-pvw-quickstart.md`'s shipped README
commands have had time to prove out, per the user's own explicit sequencing. Supersedes
`plan-pvw-quickstart.md`'s "Shape B" (a vaguely-specified, deliberately-deferred `run_setup.bat`
hook) with a concrete design -- see that doc's own Shape B section, now pointing here.
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

1. `plan-pep723-writeback.md` ships (automatic write-back inside `run_setup.bat`, uv lane).
2. `plan-pvw-quickstart.md`'s commands, already shipped in README, get real-world use and comfort.
3. **This doc's Tier 1**: add `autopep723 check` alongside `pipreqs` in the Default Path discovery
   phase, for all users, non-gating.
4. **This doc's Tier 2**: `HP_PVW_KNOWN_IDEMPOTENT`, an opt-in flag enabling runtime
   (execute-mode) discovery inside `run_setup.bat` itself.

Not scheduled for a specific loop. This document exists so the corrected design is available
whenever the team is ready to pick up step 3.

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

**Insertion point**: after pipreqs completes and `requirements.txt` is finalized, before the
existing dependency-optimization/heuristics steps -- re-verify the exact label names against the
live `run_setup.bat` at implementation time (this repo's docs consistently warn that line/label
anchors drift; treat any specific label name here as illustrative, not guaranteed-current).

**Corrected invocation** (fixing Correction 1):
```
uvx autopep723 check "%HP_ENTRY%" > "requirements.autopep.txt" 2>>"%LOG%"
```
Never `.`, never a bare directory. `%HP_ENTRY%` is this repo's existing resolved-entry-file
variable (REQ-002) -- reuse it, do not re-derive an entry path independently.

**Failure semantics** (from the source spec, still sound): `autopep723 check` failing (nonzero
exit -- a genuine failure this time, not the directory-argument false-zero from Correction 1) must
never propagate to lane failure. Fall back to pipreqs-only results and continue. `pipreqs` failure
already has its own established fallback path in this repo; `autopep723` is strictly additive on
top of that, never a replacement for it.

**Merge**: union of pipreqs's and `autopep723 check`'s package lists, deduplicated. A dedicated
small Python helper (mirroring `tools/prep_requirements.py`'s existing role, not a from-scratch
design) is the right shape for this -- simple set-union logic, no TOML parsing needed since this
touches `requirements.txt`, not a PEP 723 header.

**Not yet implementation-ready**: unlike `plan-pep723-writeback.md`, this section has not had a
code-grounded pass against the live `run_setup.bat` (exact insertion label, exact variable names,
exact merge-helper shape). That pass is the first step whenever this is picked up, matching the
pattern `plan-pep723-writeback.md`'s own Part 2 already establishes.

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

**Not yet implementation-ready.** This is a design sketch, deliberately less detailed than Tier 1,
since it depends on Tier 1 (and both prerequisite plans) shipping first per the sequencing above.

---

## Open questions for whenever this is picked up

- Exact `run_setup.bat` insertion label for Tier 1 (re-verify against the live file, not this doc).
- Exact shape of the merge helper (new `tools/` file vs. extending `prep_requirements.py`).
- Whether Tier 2's embedded helper should be Python (matching most of this repo's other embedded
  helpers) or a translated PowerShell approach closer to README's shipped commands -- Python is
  likely the better fit given `run_setup.bat`'s existing conventions, but the README commands are
  the proven reference implementation either way.
- CI test plan for both tiers (not drafted here -- follow the pattern established in
  `plan-pep723-writeback.md`'s Part 2.3 and `plan-pvw-quickstart.md`'s CI test plan section).

---

## Critical files for implementation (when scheduled)

- `run_setup.bat` -- Tier 1's discovery-phase insertion; Tier 2's new `HP_PVW_KNOWN_IDEMPOTENT`
  dispatch and embedded-helper payload declaration.
- A new or extended `tools/` helper for Tier 1's merge logic.
- A new embedded helper (Tier 2) following the `tools/collect_submodules.py` /
  `tools/hidden_import_scan.py` canonical-source-plus-`PayloadSync` pattern.
- `tests/` -- new CI test file(s) for both tiers.
- `README.md` -- Tier 2's `HP_PVW_KNOWN_IDEMPOTENT` flag documented alongside the existing
  "Advanced Environment Variables" table; cross-reference the already-shipped PVW QuickStart
  section rather than re-explaining the branch logic.
- `CLAUDE.md` -- Active Backlog pointer, mirroring the existing sibling-plan entries' style.
