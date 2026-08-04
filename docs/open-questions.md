# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

## 1. Conda native-DLL bundling repair loop: narrow (pygrib/eccodes-only) fix vs. a general pattern-matcher?

Full context: `docs/prd-conda-native-dll-bundling.md` (CLAUDE.md Active Backlog Item 24, cold-
storaged -- see `docs/agent-cold-storage.md`'s own entry for the thaw trigger). When this repair
loop is eventually built, should it hardcode the `eccodes.dll` name/glob (mirroring REQ-007's
existing libexpat pattern exactly -- cheap, directly closes the one known failure), or should it
detect ANY `Library not found: could not resolve 'X.dll'` PyInstaller warning generically and
bundle whatever `X` turns out to be (costs more to build/test, but silently covers any future
conda-forge package hitting the same gap without needing its own dedicated PRD each time)?

The PRD leans toward "build it general is not much extra cost over building it narrow" -- the
loop's reactive/bounded/iterative shape (mirroring `:hidden_import_recover`) doesn't really care
whether the DLL name is hardcoded or parsed out of the warning text -- but this is exactly the
kind of proportionality judgment `docs/prd-av-safe-build-path.md`'s own "Notes from Claude"
section on pin-generalization warns against an agent deciding unilaterally. Needs the
maintainer's call, and only once the PRD's own Requirement 1 (verifying whether
`pyinstaller-hooks-contrib`'s existing `hook-gribapi.py` already solves this for free) has been
checked first -- that verification could make this whole question moot for the pygrib case.
