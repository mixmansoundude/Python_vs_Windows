# Agent Cold Storage -- Python_vs_Windows

**This file is NOT auto-loaded into every session's context** (unlike `docs/agent-lessons-
learned.md`, `docs/agent-interconnect.md`, and `docs/agent-ndjson.md`, which CLAUDE.md's own
`@import` lines pull in automatically). Read it on demand: when CLAUDE.md's own pointer below
sends you here, or when you're about to propose something that might already be a deliberately-
shelved idea worth checking against first.

Moved out of `CLAUDE.md` directly (2026-07-31) specifically to reduce that file's per-session
context footprint -- CLAUDE.md is loaded in full every session, so keeping reference-only
material (ideas gated on a trigger that hasn't fired, not something any session needs to act on
by default) here instead measurably shrinks that footprint without losing the content. See
CLAUDE.md's own "Cold Storage" pointer for the one-paragraph scope summary.

---

## Cold Storage (promising ideas, deliberately shelved -- revisit only if a named trigger fires)

**Scope, and how this differs from Active Backlog and Known Findings**: an Active Backlog item is
work this repo intends to get to eventually, with no special precondition beyond bandwidth. A
Known Finding is a settled decision with genuinely no action ever planned. This section is a
third category: a real, technically-sound idea that is NOT being pursued right now, gated on one
or more SPECIFIC, checkable triggers -- not "eventually," not "never," but "only if X happens."
2026-07-26 owner instruction: park these here (rather than either of the other two sections) so
they stay visible without implying either imminent work or a closed door, and thaw one only when
its own named trigger genuinely fires -- do not speculatively build any of these ahead of that.

- **PYSPEC-aware venv-vs-embed decision function.** `:try_venv_fallback` currently uses whatever
  ambient Python is on the machine unconditionally, with no check of whether it actually
  satisfies `PYSPEC` (the same value `~detect_python.py` already computes for uv/conda/embed).
  This means the current linear order (embed before venv) always pays embed's network cost even
  in the common case where the ambient Python already satisfies the pin and venv would have been
  strictly better (instant, no network dependency, no extra disk). The flip side also matters:
  embed is reached immediately after conda, so by the time it's attempted, uv and conda have
  already both failed -- and since all three of uv/conda/embed need network, embed is
  disproportionately likely to fail for the *same* underlying reason (see the README's REQ-009
  failure-causes table), making it a low-odds attempt in exactly the scenario where it's tried. A
  smarter design would check "does the ambient Python (if any) already satisfy PYSPEC?" and
  prefer venv when yes, falling to embed only when the ambient Python is absent or
  version-mismatched -- turning the fixed uv/conda/embed/venv/system chain into
  uv/conda/(venv-if-it-already-satisfies-PYSPEC, else embed)/system. Not pursued now: it changes
  `:try_venv_fallback`'s dispatch shape (must read `PYSPEC` before deciding, not just on
  creation), and the current fixed order is not wrong, just not optimal in either direction.
  **Trigger to thaw**: the network-correlated-embed-failure pattern this item predicts shows up
  for real, in CI or in an actual user report -- not a speculative build ahead of that evidence.
  **Re-examined 2026-07-25 per an owner request to raise confidence-to-implement wherever
  possible**: this was never actually a confidence question -- the design sketch above is sound
  and could be implemented with reasonable confidence in its own correctness. What was missing is
  evidence that it's WORTH the added complexity; raising implementation confidence doesn't
  manufacture that evidence, which is exactly why this belongs in Cold Storage rather than Active
  Backlog -- the blocker is the trigger, not readiness to build.

- **AV-Safe Build Path Tier B (reprovisioned pinned-3.12 environment).** Full PRD at
  `docs/prd-av-safe-build-path.md`; Tier A (real Nuitka fallback build in the existing
  environment) and requirement 9 (the elective "optimized build?" upsell) are both SHIPPED --
  see their own dedicated Closed Backlog entries -- and remain the complete, working AV-quarantine
  mitigation this repo ships today. Tier B was the PRD's second tier: a reprovisioned environment
  pinned to Python 3.12 specifically to route around Nuitka's MinGW64 backend not supporting
  Python 3.13+ (Finding 1 in the PRD, last re-confirmed unresolved as of Nuitka 4.1.2 in the
  2026-07-20 downtime re-check). Building it means a second provider-chain traversal, a
  pinned-version environment, and the stale-PATH/`VIRTUAL_ENV` hazard research Finding 6 already
  flagged -- real complexity with no user-observed need yet (the PRD itself notes it as
  preemptive, "no real user report yet, a documented industry-wide problem").
  **Trigger to thaw, two and only two conditions**: (a) the owner personally hits a real
  PyInstaller AV-quarantine failure that Tier A does not already resolve, giving the reprovision
  complexity a concrete justification instead of a speculative one; or (b) Nuitka's own upstream
  MinGW64 backend gains Python 3.13+ support, which would remove the entire reason Tier B needs a
  narrow version pin in the first place -- at that point Tier B's whole design would need
  re-evaluating (it might not need a pin at all anymore), not just a version bump. Condition (b)
  is exactly what the "Next-pin probe concept" section (under Periodic Maintenance Checks) already
  tracks quarterly for any future pin justified by one specific, checkable fact -- re-check that
  same fact each scan (Nuitka's MinGW64 Python-version support), not a generic "try a newer
  Nuitka" probe. If either condition fires, read the PRD's own "Notes from Claude" section before
  restarting Tier B -- it has the original reasoning plus a deliberately blunt writeup of why
  Tier B's narrow, well-justified 3.12 pin should **never** be generalized into a
  bootstrapper-wide "stay a version or two behind latest" default (this repo has no telemetry or
  auto-update mechanism, so any such pin freezes permanently into every already-distributed copy
  of `run_setup.bat`). Requirements 6 (loop avoidance) and 8 (connectivity check before Tier B)
  depend on Tier B existing and thaw with it, for the same reason.

- **pipreqs internalization (clean-room AST-based scanner + mapping table, replacing pipreqs as
  the primary dependency-discovery tool).** pipreqs (bndr/pipreqs) is stagnant (maintenance-only,
  looking for maintainers) but not at risk of disappearing from PyPI outright -- PyPI does not
  delete established packages. The real risk the community cites is future-Python bitrot (an AST
  parser silently failing on new syntax), which this repo has already pre-empted twice over: the
  0.4.13 pin (see "pipreqs pin rationale" above) avoids 0.5.0's `<3.13` Requires-Python ceiling,
  and the warnfix build-time safety net (see "Dependency Discovery Fallback: warnfix" above) means
  the bootstrap **never hard-fails** even if pipreqs is 100% unavailable -- confirmed by
  `self.stub.pipreqs_version_fail` (Closed Backlog), which forces pipreqs's own install to fail via
  `HP_PIPREQS_VERSION=99.99.99` (already an env-overridable variable, no code change needed to
  trigger this) and proves the bootstrap still reaches a working, fully-run EXE via warnfix alone.
  It is technically feasible and roughly the size a 3rd-party estimate suggested (a few hundred
  lines + a small mapping table), but it duplicates a safety net that already works and is tested,
  and is its own nontrivial project (matching pipreqs's accumulated edge-case handling: encoding
  fallback, syntax-error tolerance, stdlib filtering).
  **Trigger to thaw**: a real user run (not just CI) hits a pipreqs failure the warnfix safety net
  doesn't cleanly cover, OR pipreqs is genuinely removed from PyPI, OR the quarterly "next-pin
  probe" (Periodic Maintenance Checks, "pipreqs ecosystem status") finds pipreqs's own
  Requires-Python ceiling has moved in a way that reopens the future-Python-bitrot risk this
  section exists to track. A one-off CI observation is not enough on its own -- this needs a
  signal from how the tool behaves for a real user, or a concrete ecosystem change.
  **When it is eventually undertaken**: write a **clean-room** scanner rather than copying
  pipreqs's actual source or mapping file (pipreqs is MIT-licensed; copying it verbatim would
  require carrying its copyright notice -- a clean-room reimplementation sidesteps this entirely,
  though crediting pipreqs by name/link as prior art in a code comment is a fair courtesy). Seed
  the mapping table by extending this repo's own already-license-clear `tools/parse_warn.py`
  `TRANSLATIONS` dict rather than importing external mapping databases (showmereqs/FawltyDeps/
  marimo/Grayskull all carry their own licenses needing separate audit, and none of those tables
  have been vetted against this repo's actual needs). Use `sys.stdlib_module_names` with a
  `try/except ImportError` guard per the existing "Embedded-helper Python baseline" convention
  (it's a 3.10+ feature; must degrade gracefully on an older ambient interpreter on the
  venv/system fallback tiers). Do not chase alternative tools as a wholesale replacement: `pigar`
  was correctly ruled out elsewhere (its wheel bundles an ~40 MB SQLite package database, a
  non-starter for a single-file bootstrapper).

