# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

## 1. Conda native-DLL bundling repair loop: narrow (pygrib/eccodes-only) fix vs. a general pattern-matcher?

Full context: `docs/prd-conda-native-dll-bundling.md` (CLAUDE.md Active Backlog Item 24 -- active
work as of 2026-08-04, thawed from cold storage; see `docs/agent-cold-storage.md`'s own entry for
the original shelve-and-thaw reasoning). When this repair loop is eventually built, should it
hardcode the `eccodes.dll` name/glob (mirroring REQ-007's existing libexpat pattern exactly --
cheap, directly closes the one known failure), or should it detect ANY `Library not found: could
not resolve 'X.dll'` PyInstaller warning generically and bundle whatever `X` turns out to be
(costs more to build/test, but silently covers any future conda-forge package hitting the same gap
without needing its own dedicated PRD each time)?

The PRD leans toward "build it general is not much extra cost over building it narrow" -- the
loop's reactive/bounded/iterative shape (mirroring `:hidden_import_recover`) doesn't really care
whether the DLL name is hardcoded or parsed out of the warning text -- but this is exactly the
kind of proportionality judgment `docs/prd-av-safe-build-path.md`'s own "Notes from Claude"
section on pin-generalization warns against an agent deciding unilaterally. Needs the
maintainer's call, and only once the PRD's own Requirement 1 (verifying whether
`pyinstaller-hooks-contrib`'s existing `hook-gribapi.py` already solves this for free) has been
checked first -- that verification could make this whole question moot for the pygrib case.

## 2. Should the post-flight caveat panel surface a DLL-specific hint once the new repair loop's own detection signal exists?

README.md's REQ-016 spec (confirmed current, correctly implemented today) already guarantees the
post-flight briefing always shows the direct interpreter-run command regardless of EXE
verification outcome, and separately shows a generic "couldn't fully verify it runs as a
standalone program" caveat when the EXE smoke run failed -- this generic caveat deliberately never
asserts a root cause (an explicit, already-settled design decision from REQ-027 P2, see
`docs/agent-interconnect.md`'s "Honest ambiguous-exit messaging" section: "Neither panel asserts a
root cause... Open Question 3 explicitly leaves root-cause distinction unsolved").

This is a narrower question than reopening that settled one: once the Item 24 repair loop's own
detection mechanism exists (a build-time `Library not found: could not resolve` warning, or a
runtime DLL-load-failure signature -- see the PRD's Finding 5), that SAME signal is a concrete,
specific, already-computed fact the bootstrapper doesn't have today -- not a general root-cause
guess. Should the caveat panel, ONLY when this specific signal fired (whether or not the repair
loop's own bundling attempt succeeded), add one extra line distinguishing "we detected a missing
native library and attempted to fix it automatically" from the generic message? This stays fully
in scope of the already-decided "no general root-cause claims" principle -- it surfaces a fact the
new mechanism computes anyway, not a guess about causes the bootstrapper can't actually determine.

Not urgent -- naturally sequenced after the repair loop itself exists (Item 24's Requirement 3),
not before. Flagged now so it isn't lost, and so Item 24's eventual implementation considers it
alongside Requirement 5's documentation pass rather than as an afterthought.
