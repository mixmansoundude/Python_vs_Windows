# Plan: PVW QuickStart -- a standalone, no-EXE super-user path

**Status:** The user-facing commands are shipped directly in README's "PVW QuickStart" section
(copy-paste PowerShell, no download required); a standalone downloadable `pvw_quickstart.ps1`
file is still not built -- see "Architecture decision" below, unchanged by this update. Two local
verification passes completed (2026-07-14, uv 0.8.17 / autopep723 0.2.0, this repo's Linux
sandbox): an initial pass against the source document and this plan's own proposed simplification,
and a same-day follow-up pass (see "Pass 2: default command redesigned around exit-code branching"
below) that replaced the default run command's retry logic after a real, reproduced destructive
bug was found in the original design.
**Owner:** Python_vs_Windows maintainer
**Source material:** a user-supplied third-party document ("The PEP 723 Megacommand") proposing a
single-paste PowerShell command family for running/persisting a `.py` file's dependencies without
`run_setup.bat` at all. That document is not reproduced here; this plan states what was verified,
what was kept, what was simplified, and why.
**Related:** `docs/plan-pep723-writeback.md` (the automatic, `run_setup.bat`-integrated sibling of
this feature -- shares its core `uv` empirical foundation with this doc, consolidated in
`docs/agent-lessons-learned.md`); `docs/agent-lessons-learned.md`'s "`uv add --script` / PEP 723
empirical behavior" section (the shared empirical foundation both this doc and the sibling depend
on -- read that first); `docs/plan-autopep723-two-tier.md` (the concrete successor to this doc's
own "Shape B," sequenced to be picked up only after this doc's commands have had real-world use);
README's `## Why "Build-First, Run-Once"? (Design Rationale)` section (the existing audience-split
argument this plan leans on directly); `CLAUDE.md` Active Backlog (this item is linked from
there).

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
document's core claims were re-run directly in this session. **The empirical findings themselves
(the encoding-corruption bug and its `ISO-8859-1` fix, and `uv add --script`'s native
targeted-merge behavior that makes the source document's hand-rolled TOML merge unnecessary) now
live in `docs/agent-lessons-learned.md`'s "`uv add --script` / PEP 723 empirical behavior"
section, consolidated with the equivalent findings from `plan-pep723-writeback.md`'s own testing
-- read that section first.** One finding specific to this document, not shared with the sibling
feature:

- **`uvx autopep723 <file>` (no subcommand) genuinely executes the script**, confirmed directly:
  a test file's `print()` output appeared in the terminal and the file was confirmed unchanged
  afterward. This matches the source document's own finding and independently disproves the same
  "doesn't execute, needs a trailing `uv run`" claim `docs/plan-pep723-writeback.md`'s Part 1
  already flagged as false for a related reason. Not relevant to `plan-pep723-writeback.md`
  itself, since that feature never runs the entry file this way.

**Design implication carried from the lessons-learned consolidation:** since `uv add --script`'s
own merge logic already preserves existing pins/custom keys, the source document's Option C
script (an inline Python one-liner requiring `--with tomli-w`, TOML-parsing both the old header
and a fresh `autopep723 check` scan, name-normalizing both sides, and manually computing a set
difference before writing a merged block back by hand) is solving a problem `uv` already solves
natively. QuickStart's persistence step does not need to reimplement it -- see "Simplified
persistence design" below.

**Not independently re-verified in this pass** (carried over honestly from the source document,
not silently dropped): behavior on real Windows PowerShell 5.1 (this session, like the source
document's, ran on Linux via `pwsh` 7.6.3); the exact failure text/class when `uv`'s own installer
fails outright (network blocked, domain unreachable); the missing/misnamed-file error UX. All three
remain open items -- see "Open gaps, carried over honestly" below.

---

## Pass 2: default command redesigned around exit-code branching (same day, found via a real
## reproduced bug, not a hypothetical)

The originally-shipped default run command (this plan's own Shape A, and the source document's
own Tier 1) treated *any* nonzero exit from the first run attempt identically: strip the entire
existing `# /// script ... # ///` block and retry clean. This is correct for a genuinely malformed
header, but wrong for the much more common failure it doesn't distinguish from: a **valid** header
that is simply missing a recently-added import, which fails with `ModuleNotFoundError` -- a
different problem with the same symptom (nonzero exit). The blind-strip design could not tell them
apart and destroyed the second case as if it were the first.

**Reproduced directly, not assumed.** Built a file with a real pin (`flask>=2.0`), a hand-added
custom TOML key (`[tool.custom]`), and a script body that imports both `flask` and `requests` --
but a header that only declares `flask`. Running the original blind-strip command against it:

- First attempt: `ModuleNotFoundError: No module named 'requests'`, exit 1.
- The blind-strip logic could not distinguish this from a malformed header, so it stripped the
  entire header (pin, `requires-python`, and the custom key all gone) and retried on a bare file.
- Result: the script ran, but the file was left with **no header at all** where a moment before it
  had a real, correct, hand-maintained one. First reproduction attempt actually returned a
  misleadingly clean result (the run succeeded with no visible strip) -- traced this to the
  `astral-sh/uv#15156` stale-cache effect already noted in `agent-lessons-learned.md` (hit live,
  not just cited); re-running with a genuinely fresh filename and a cleared `~/.cache/uv`
  reproduced the destructive strip cleanly and repeatably.

**The fix**: branch on the *exit code* of the first attempt, not just success/failure -- using the
exit-code-2-means-malformed-TOML fact from `agent-lessons-learned.md` (confirmed there, across
both this plan's and `plan-pep723-writeback.md`'s testing, that a missing file does NOT also
produce exit 2, so the signal isn't accidentally shared with an unrelated failure class):

- **Exit 0** (ran clean): best-effort additive persist now that the run is confirmed working --
  the same discovery-then-`uv add --script` recipe from "Simplified persistence design" below,
  just triggered automatically on success instead of only via a separate opt-in command.
- **Exit 2** (header itself is malformed): the one case where starting over is actually correct --
  back up, strip, retry, persist a fresh header on success, restore the original byte-for-byte if
  the retry also fails.
- **Any other nonzero exit** (header parsed fine, something else failed -- most commonly a valid
  header missing a recently-added import): fill in what's missing via the same additive persist
  helper *without stripping anything*, then retry once. If that still fails, it's treated as a
  genuine script-level problem, not a dependency gap, and nothing further is attempted
  automatically.

**Re-verified after the fix, same reproduction file plus five more scenarios (all against the
final command as it now appears in README, not just the design):** the pin, `requires-python`, and
custom key all survive; only `requests` gets added; the script runs. A genuinely malformed header
(TOML syntax error) still correctly triggers strip-and-retry. A double failure (malformed header +
a genuinely nonexistent package) still restores the original file byte-for-byte with the `.bak`
cleaned up. A missing/misnamed file falls through to the safe "some other reason" branch rather
than the destructive one (confirmed exit code is 1, not 2). A non-UTF-8 file falls through the
same safe branch and is left untouched. Idempotency holds: running the finished command a second
time on an already-complete header produces a byte-identical file. One accepted, deliberate gap
carried forward from the source document's own equivalent design decision: the "some other reason"
branch's fill-in is not rolled back if the retry still fails for an unrelated reason (e.g. a real
bug in the script) -- safe because `uv add --script`'s writes are already independently confirmed
atomic (see `agent-lessons-learned.md`), so the header at worst ends up *more* correct, never
corrupted.

**Design consequence carried into README, not left implicit:** this changes the previous "never
touches your file in the common case where nothing goes wrong" framing -- the new default command
*does* touch the file on a successful run now, by design, additively. README's text was updated to
say so plainly rather than quietly changing the claim underneath an unchanged sentence.

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
   not just the "new" subset. uv's own merge logic (`agent-lessons-learned.md`) already leaves
   every already-present, already-pinned entry untouched and only adds genuinely new ones. No set
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
and runs directly in a terminal they've already opened in the script's folder. Three modes,
matching what's now shipped as README commands:

- **Default (run, and additively remember what it needed):** install uv via the official installer
  (`irm https://astral.sh/uv/install.ps1 | iex`, already this repo's own documented recommendation
  for an *interactive terminal* context -- see `CLAUDE.md`'s "Known Findings" entry explaining why
  that same installer is deliberately **not** used inside `run_setup.bat` itself; a live terminal
  session has none of the PATH-propagation/restart problems a background batch process does, so
  there is no conflict between the two decisions, just two different execution contexts), read the
  target file with the ISO-8859-1 round-trip technique (`agent-lessons-learned.md`) so a crash or
  a header repair can always restore the original bytes exactly, run `uvx autopep723 <file>`
  (ephemeral), then
  branch on the exit code per "Pass 2" above: exit 0 does a best-effort additive persist; exit 2
  (genuinely malformed TOML) is the one case where stripping and retrying from scratch is correct;
  any other nonzero exit tries an additive fill-in without ever stripping anything, then retries
  once. The malformed-header repair path uses the **same line-by-line state-machine approach**
  `plan-pep723-writeback.md`'s Part 2.1 step 5 already specifies for the automatic feature (not a
  DOTALL-ish regex, which that same section already reasons is riskier -- see astral-sh/uv#10918
  and astral-sh/uv#19544, both already cited there), and only that one path ever writes a `.bak`
  backup or removes anything from the file.
- **Read-only check:** `uvx autopep723 check <file>` -- prints what would be detected, changes
  nothing. No repair/persist logic involved at all.
- **Persist-only, without running:** the discovery-then-`uv add --script` recipe below, for when a
  super user wants the header updated without executing the script's side effects yet (the default
  mode already does this automatically after a successful run, so this mode exists specifically
  for the "don't run it" case).

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

**Superseded by a concrete design: see `docs/plan-autopep723-two-tier.md`'s `HP_PVW_KNOWN_IDEMPOTENT`
section.** That doc takes exactly this Shape B idea and gives it a name, a precondition (uv lane
only), and an explicit answer to the REQ-018 concern above (an opt-in, self-declaring-consent flag
is REQ-019-compliant by construction, and the retry/branch logic it would embed is not new design
-- it's this doc's own already-shipped, already-tested exit-code branching, just relocated into
`run_setup.bat`). Deliberately sequenced to be picked up only after this doc's own commands have
had real-world use -- see that doc's own "Sequencing" section.

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
table shape for consistency, extended per Pass 2's exit-code branching): happy path no header;
existing valid pinned header, no missing imports (default mode does nothing beyond confirming);
**valid-but-incomplete header with a pin and a custom key** (Pass 2's own reproduction case -- the
one that must NOT strip); genuinely malformed header (retry path, the one case that DOES strip);
double failure (malformed header + a genuinely nonexistent package -- must restore byte-for-byte);
non-UTF-8 source file (must fall into the safe non-stripping branch, not the retry branch);
missing/misnamed file (must also fall into the safe branch -- confirm its exit code is never 2);
persist-only mode's custom-key preservation; persist-only mode's idempotency (run twice,
byte-identical result); default mode's idempotency on an already-complete header.

---

## Critical files for implementation (when scheduled)

- `pvw_quickstart.ps1` (new, repo root or a `tools/`-adjacent location TBD at implementation time)
  -- the standalone script itself, self-contained like `run_setup.bat` is, but far smaller. Would
  wrap the same logic already shipped as README copy-paste commands, not a new design.
- `README.md` -- the "PVW QuickStart" section already exists and ships the full command set; a
  standalone script would be an additional, optional download of the same logic, not a rewrite.
- `tests/` -- new CI test file(s) once a shape is chosen; no existing test file is a close enough
  structural match to extend rather than create fresh.
- `CLAUDE.md` -- Active Backlog pointer, mirroring the existing `plan-pep723-writeback.md` entry's
  style.

## README placement (shipped)

Landed directly after `## Python_vs_Windows and the "Deno for Python" Question`, before `## Known
Limitations` -- the second of the two candidate locations this plan originally listed, chosen
because that section already draws the exact audience distinction ("known-stateless scripts, or a
developer who already knows their own code") this whole plan is built on, so QuickStart reads as a
concrete instance of that column rather than a hypothetical one. Still **not near the top** of the
README, per the original request -- the beginner-facing quickstart at the top is untouched.

Recorded in `CLAUDE.md`'s Active Backlog (see that file) so this placement decision isn't lost
before the section is actually written.
