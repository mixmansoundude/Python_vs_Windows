# Plan: PVW QuickStart -- a standalone, no-EXE super-user path

**Status:** Design-only, not scheduled. Sequenced to land *after* `docs/plan-pep723-writeback.md`
(see "Sequencing decision" below). One local verification pass completed (2026-07-14, uv 0.8.17 /
autopep723 0.2.0, this repo's Linux sandbox) against both the source document and this plan's own
proposed simplification.
**Owner:** Python_vs_Windows maintainer
**Source material:** a user-supplied third-party document ("The PEP 723 Megacommand") proposing a
single-paste PowerShell command family for running/persisting a `.py` file's dependencies without
`run_setup.bat` at all. That document is not reproduced here; this plan states what was verified,
what was kept, what was simplified, and why.
**Related:** `docs/plan-pep723-writeback.md` (the automatic, `run_setup.bat`-integrated sibling of
this feature); README's `## Why "Build-First, Run-Once"? (Design Rationale)` section (the existing
audience-split argument this plan leans on directly); `CLAUDE.md` Active Backlog (this item is
linked from there).

---

## Why this is a separate document, not a merge into `plan-pep723-writeback.md`

The two features solve the same underlying problem (persist resolved dependencies into a PEP 723
header) for two audiences this repo has already explicitly distinguished, in README's own words:

> Right choice for | Unknown, possibly-non-idempotent code (this tool's actual audience) |
> Known-stateless scripts, or a developer who already knows their own code

`plan-pep723-writeback.md` is the first column: automatic, silent, gated behind `run_setup.bat`'s
full build-first-run-once machinery (REQ-018), because the beginner audience it serves cannot be
trusted to know whether their own script is safe to re-run. PVW QuickStart is the second column: a
super user who already knows their script is safe (or is consciously iterating and accepts the
risk) and wants the fastest possible turnaround -- no conda, no PyInstaller EXE, no verification
gate, just "run the file now." Folding QuickStart's logic into `run_setup.bat`'s dispatch would
mean either building a whole new REQ-009-style tier that bypasses REQ-018's single-verified-run
guarantee (undermining the exact protection that guarantee exists for), or gating it so heavily
behind consent prompts that it stops being a "quickstart." Keeping it a fully separate, standalone
artifact avoids that conflict entirely and costs nothing in `run_setup.bat`'s own risk surface --
see "Architecture decision" below for the two shapes considered and why the standalone shape won.

---

## What was independently re-verified (not just trusted from the source document)

Per this repo's established practice of testing third-party claims rather than accepting them on
authority (see `docs/plan-pep723-writeback.md`'s own two-pass empirical history), the source
document's core claims were re-run directly in this session, plus one significant simplification
was found and verified that the source document did not have available to it.

1. **`uvx autopep723 <file>` (no subcommand) genuinely executes the script**, confirmed directly:
   a test file's `print()` output appeared in the terminal and the file was confirmed unchanged
   afterward. This matches the source document's own finding and independently disproves the same
   "doesn't execute, needs a trailing `uv run`" claim `docs/plan-pep723-writeback.md`'s Part 1
   already flagged as false for a related reason.
2. **The encoding-corruption bug is real and reproduces exactly as described.** Built a file with
   one intentionally-invalid-UTF-8 byte, read it via PowerShell's default `Get-Content -Raw`, and
   confirmed the byte is silently replaced with the Unicode replacement character (`EF BF BD`)
   before the command ever acts on it -- verified at the raw byte level, not just visually. Reading
   and writing the same file via `[System.IO.File]::ReadAllText`/`WriteAllText` with
   `[System.Text.Encoding]::GetEncoding("ISO-8859-1")` round-trips it byte-for-byte identical
   (`cmp` confirms zero difference). This is the same category of hazard
   `plan-pep723-writeback.md`'s Non-Goals section already reasons about for the *automatic*
   feature (which sidesteps it by skipping non-UTF-8 files entirely, never attempting a round
   trip) -- QuickStart's problem is different in kind: it actively mutates the file in place with
   a retry, so it needs a real round-trip guarantee, not just a skip. The ISO-8859-1 technique is
   the right tool for that job and is adopted as-is.
3. **`uv add --script` already does everything the source document's hand-rolled "Option C" TOML
   merge script was built to achieve -- confirmed with three fresh, targeted tests this session,
   going further than either document's existing testing:**
   - Re-running `uv add --script file.py flask` when `flask>=2.0` was already pinned in the header
     left the file **byte-for-byte unchanged** -- the existing pin was not downgraded to a bare
     name.
   - Running `uv add --script file.py flask click requests` (two already-pinned packages plus one
     genuinely new one) preserved both existing pins exactly (`flask>=2.0`, `click==8.1.0`) and
     added only `requests`, as a bare name, in its correct alphabetical position.
   - A hand-added custom TOML key (`[tool.custom]` with its own field) outside the
     `dependencies`/`requires-python` keys survived an `add` call untouched.
   - This confirms `docs/plan-pep723-writeback.md`'s existing Pass 2 finding ("adding bare pandas
     after `pandas[excel]` was already present did not duplicate or downgrade the entry") was not
     a narrow extras-specific behavior -- it is uv's general merge policy, and it covers explicit
     version pins (`>=`, `==`) and arbitrary custom keys too, not just extras syntax.
   - **Design implication:** the source document's Option C script (an inline Python one-liner
     requiring `--with tomli-w`, TOML-parsing both the old header and a fresh `autopep723 check`
     scan, name-normalizing both sides, and manually computing a set difference before writing a
     merged block back by hand) is solving a problem uv's own `add --script` command already
     solves natively. QuickStart's persistence step does not need to reimplement it -- see
     "Simplified persistence design" below.

**Not independently re-verified in this pass** (carried over honestly from the source document,
not silently dropped): behavior on real Windows PowerShell 5.1 (this session, like the source
document's, ran on Linux via `pwsh` 7.6.3); the exact failure text/class when `uv`'s own installer
fails outright (network blocked, domain unreachable); the missing/misnamed-file error UX. All three
remain open items -- see "Open gaps, carried over honestly" below.

---

## Simplified persistence design (this plan's contribution beyond the source document)

Because `uv add --script` already preserves existing pins and custom keys on its own (see finding
3 above), QuickStart's optional persistence step does not need a TOML parser, `tomli-w`, or any
diffing logic at all. The full recipe:

1. Discovery: `uvx autopep723 check <file>` -- **read-only**, prints a freshly-scanned dependency
   block based on the file's actual `import` statements (confirmed directly: it reports only names
   the code body actually imports, ignoring whatever the existing header already claims -- tested
   against a file whose header listed a package the code never imports, and `check` correctly
   omitted it). Always emits bare names, regardless of what pins already exist in the file.
2. Extract the bare package names from `check`'s printed `dependencies = [...]` block (simple
   line-oriented parsing of quoted strings inside that block -- no TOML library needed for this
   step either, since `check`'s own output format is this repo's own tool's fixed, predictable
   shape, not arbitrary user input).
3. Feed the **entire** extracted name list to `uv add --script <file> <names...>` in one call --
   not just the "new" subset. uv's own merge logic (finding 3) already leaves every
   already-present, already-pinned entry untouched and only adds genuinely new ones. No set
   difference, no old-header parsing, needs to happen in QuickStart's own code at all.

This removes an entire class of surface area the source document's Option C carried (a second TOML
parser's worth of edge cases, an extra `--with tomli-w` dependency fetch, a hand-written name
normalizer that the document itself flagged as "best-effort, not a full PyPI-aware identity
check"). It is also easier to test: the only two things QuickStart's own code does are "parse a
predictable, self-generated TOML-comment block for quoted strings" and "shell out to uv" -- both
narrow, mechanical operations.

---

## Architecture decision: standalone script, not a `run_setup.bat` hook

Two shapes were considered, matching the two options raised when this plan was requested.

### Shape A (recommended): standalone `pvw_quickstart.ps1`, documented and optionally downloadable

A single PowerShell script, independent of `run_setup.bat`, that a super user pastes or downloads
and runs directly in a terminal they've already opened in the script's folder. Two modes:

- **Default (run only, no persistence):** hardened version of the source document's Tier 1 --
  install uv via the official installer (`irm https://astral.sh/uv/install.ps1 | iex`, already
  this repo's own documented recommendation for an *interactive terminal* context -- see
  `CLAUDE.md`'s "Known Findings" entry explaining why that same installer is deliberately **not**
  used inside `run_setup.bat` itself; a live terminal session has none of the PATH-propagation/
  restart problems a background batch process does, so there is no conflict between the two
  decisions, just two different execution contexts), read the target file with the ISO-8859-1
  round-trip technique (finding 2) so a crash or a bad-header retry can always restore the
  original bytes exactly, run `uvx autopep723 <file>` (ephemeral, no persistence), and on a
  non-zero exit, strip any existing `# /// script ... # ///` block using the **same line-by-line
  state-machine approach** `plan-pep723-writeback.md`'s Part 2.1 step 5 already specifies for the
  automatic feature (not the source document's own DOTALL-ish regex, which that same section
  already reasons is riskier -- see astral-sh/uv#10918 and astral-sh/uv#19544, both already cited
  there) and retry once. On a second failure, restore the original bytes and stop -- never leave
  the file in a partially-stripped state.
- **Opt-in `-Persist` switch:** after a successful run (or independently, without running), does
  the discovery-then-`uv add --script` recipe above.

This is what the user's own framing leaned toward ("just run this and bail out") and is the
default recommendation here: it costs `run_setup.bat` nothing (zero lines changed, zero new
dispatch risk in the file this repo's own maintainer has repeatedly described as frail), and it
matches the audience split README already draws rather than inventing a new one.

### Shape B (considered, deliberately deferred, not implemented): `run_setup.bat` hook

An opt-in `HP_QUICKSTART_MODE=1`-style flag that, if set, makes `run_setup.bat` skip straight to a
"resolve via uv, run once via the interpreter, exit -- no PyInstaller EXE, no conda" fast path
before any of the normal REQ-009 provider cascade or REQ-018 build gating runs. This would be
`[REQ-019]`-compliant on its face (an opt-in flag that adds an alternate behavior without blocking
the default flow for anyone who doesn't set it), so it is not rejected outright -- but it is not
recommended as the first move, for reasons specific to this file rather than to the flag rule:

- It would need its own answer to REQ-018's core question ("is this run allowed to happen more
  than once, unverified?") for a mode that exists specifically to skip verification -- either it
  quietly inherits none of REQ-018's safety reasoning (a real regression in spirit, even if
  opt-in), or it re-derives a parallel, smaller version of that reasoning just for itself, which is
  duplicated complexity for a feature whose whole point is to be simple: skip the ceremony.
- `run_setup.bat` is a single ~157 KB file already carrying five REQ-009 provider tiers, a
  hidden-import recovery loop, a provider cascade, and a lock/consent/checkpoint apparatus. Adding
  a sixth, structurally different execution mode to the same dispatch surface increases the file's
  already-acknowledged fragility for a use case (a super user who is comfortable running one
  PowerShell command directly) that does not actually need `run_setup.bat` to be involved at all.

**Recorded here as the fallback if real usage later shows a standalone script is insufficient**
(e.g. if super users specifically want it triggered *from* an existing `run_setup.bat` folder
without a second file to manage) -- not implemented now, not scheduled.

---

## Sequencing decision: `plan-pep723-writeback.md` ships first

Three independent reasons, not just one:

1. **`plan-pep723-writeback.md` is already implementation-ready** -- two full research/testing
   passes completed, code-grounded hook points traced against the live file, test plan written.
   This plan is a single design pass with no code-grounded tracing needed (it touches no existing
   file), but it has not had a second look the way the write-back plan has.
2. **The write-back feature serves this repo's stated primary audience** (the beginner using
   `run_setup.bat` itself); QuickStart serves an explicitly secondary, opt-in audience. Per
   `CLAUDE.md`'s iteration priorities, primary-audience work goes first when both are ready.
3. **Shared research reduces duplicated effort if sequenced this way, not the other way around.**
   Implementing write-back first will re-run Part 3's "current uv version" empirical check
   (`plan-pep723-writeback.md` Part 3/3.5) against whatever uv is current at that time -- that
   same check (idempotency, malformed-header exit codes, the trailing-whitespace fence case)
   covers most of what QuickStart's own persistence step depends on too. Building QuickStart
   first would mean re-deriving the same uv-version confidence twice, once per feature, instead of
   QuickStart's later implementation simply inheriting whatever was just re-confirmed for
   write-back.

---

## Open gaps, carried over honestly (not silently dropped from the source document)

- **Real Windows PowerShell 5.1 is untested** by either document. Both this session and the source
  document's own testing ran on Linux via `pwsh` 7.x. The ISO-8859-1 encoding technique and the
  `[System.IO.File]` static-method calls are standard .NET and expected to behave identically on
  PS 5.1 (this repo already relies on the same "raw .NET types over Utility-module cmdlets"
  precedent elsewhere -- see `docs/agent-lessons-learned.md`), but this is an expectation, not a
  confirmed fact, until a real dry run happens.
- **Failed `uv` install** (no network, blocked domain): `uvx`/`uv` becomes an unrecognized command,
  which PowerShell surfaces as a terminating error rather than a `$LASTEXITCODE` the rest of a
  script's retry logic can branch on. Neither document confirmed the exact error text/class. Low
  severity (fails safely, just not with a single clean message) but worth a real test before this
  ships.
- **Missing/misnamed target file**: produces a pile of raw PowerShell errors instead of one clear
  message. Confirmed by the source document's own direct test; the single most likely real-world
  mistake (an un-edited placeholder filename), not an obscure edge case. Worth a guard clause
  (`if (-not (Test-Path $f)) { ... one clear message ... exit }`) at implementation time -- cheap,
  not yet written here since this is a design pass, not an implementation pass.
- **`try`/`finally` does not protect against `SIGKILL`-class termination** (confirmed directly by
  the source document, not re-tested here) -- this is exactly why the on-disk `.bak`-before-mutate
  approach is required rather than an in-memory-only backup or a `finally` block alone; the design
  above already reflects this.

---

## CI test plan (for whenever this is implemented, not built now)

A pasted third-party suggestion for validating a shipped `pvw_quickstart.ps1` proposed three
angles; each is worth keeping, and none require new infrastructure beyond what this repo's CI
already knows how to do (Windows runners, matrix jobs, NDJSON rows):

1. **Installer resiliency, on a genuinely clean runner.** GitHub Actions Windows runners start
   clean per job, so a real job (not a scratch dir inside an already-provisioned runner) is the
   right place to confirm `irm ... | iex` actually installs uv and that `$env:Path` picks it up
   within the same session, with no restart -- this is exactly the guarantee QuickStart's whole
   premise depends on and it should be asserted, not assumed, in CI.
2. **Matrix over `powershell.exe` (5.1) and `pwsh` (7)**, both against the same test scenarios,
   specifically to close the "real Windows PowerShell 5.1 is untested" gap above with an ongoing,
   automatic check rather than a one-time manual dry run -- mirrors this repo's existing "CI itself
   is the ongoing drift detector" reasoning already documented in `plan-pep723-writeback.md`'s Part
   3.5 for the sibling feature.
3. **Byte-level verification of the round-trip guarantee**, not just a visual/string diff: read
   the file back after a run (success, forced-failure, and forced-header-corruption scenarios) via
   raw byte comparison (`[System.IO.File]::ReadAllBytes` + `-eq` array comparison, or the same
   `cmp`-equivalent .NET approach used in this session's own verification above) to prove no
   encoding translation or BOM was introduced -- directly provable, not just plausible from reading
   the code.

Scenario list to adapt once implementation starts (mirrors `plan-pep723-writeback.md`'s own test
table shape for consistency): happy path no header; existing valid pinned header (persist mode);
malformed header (retry path); non-UTF-8 source file (round-trip path); missing/misnamed file;
`-Persist` custom-key preservation; `-Persist` idempotency (run twice, byte-identical result).

---

## Critical files for implementation (when scheduled)

- `pvw_quickstart.ps1` (new, repo root or a `tools/`-adjacent location TBD at implementation time)
  -- the standalone script itself, self-contained like `run_setup.bat` is, but far smaller.
- `README.md` -- new user-facing section; see "README placement" below for where.
- `tests/` -- new CI test file(s) once a shape is chosen; no existing test file is a close enough
  structural match to extend rather than create fresh.
- `CLAUDE.md` -- Active Backlog pointer, mirroring the existing `plan-pep723-writeback.md` entry's
  style.

## README placement (backlog, not written yet)

Positioned **not near the top** of the README, per explicit request -- this is opt-in super-user
material, not the beginner-facing quickstart the top of the README already owns. Two candidate
locations, either acceptable, final call deferred to implementation time once the surrounding
prose can be read in context:

- Directly after `## [REQ-015] Idempotent Git Config Merge`, since QuickStart is itself an
  explicitly-idempotent-by-design tool (repeated `-Persist` runs converge, per finding 3) and
  a reader already primed on "idempotent" by that section's own title is a natural next stop.
- Inside or directly after `## Python_vs_Windows and the "Deno for Python" Question`, since that
  section already draws the exact audience distinction ("known-stateless scripts, or a developer
  who already knows their own code") this whole plan is built on -- QuickStart could be introduced
  as a concrete instance of that column, rather than a hypothetical one.

Recorded in `CLAUDE.md`'s Active Backlog (see that file) so this placement decision isn't lost
before the section is actually written.
