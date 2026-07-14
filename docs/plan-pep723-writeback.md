# Implementation Plan: PEP 723 Dependency Write-Back via `uv add --script`

**Status:** Implementation-ready. Three research/testing passes completed (2026-07-11 initial
design + local scratch-dir verification against uv 0.8.17; 2026-07-12 follow-up: web/docs/GitHub-
issues research pass, a second local scratch-dir pass comparing uv 0.8.17 against uv 0.11.28 to
directly test version-drift risk, and a code-grounded implementation pass tracing the actual
`run_setup.bat` hook points; 2026-07-14 a third, narrower pass confirming pin/custom-key
preservation on re-add, prompted by reviewing `docs/plan-pvw-quickstart.md`). No code written yet.
**Owner:** Python_vs_Windows maintainer
**Related:** `CLAUDE.md` Active Backlog (this item is linked from there); `docs/prd-av-safe-build-
path.md` (a structurally similar large design doc, for format precedent); `docs/plan-pvw-
quickstart.md` (a standalone, non-`run_setup.bat` sibling feature for a different audience --
see that document's own "Why this is a separate document" section for how the two relate).

---

## Goal

After this bootstrapper successfully resolves and installs a script's dependencies (via pipreqs
discovery, heuristic augmentation, and/or the warnfix repair loop), promote the final resolved
dependency list into a persistent, authoritative PEP 723 `# /// script` header directly in the
user's entry `.py` file, using uv's native `uv add --script` command -- instead of leaving
inferred deps only in the non-authoritative `requirements.auto.txt`. This makes the file
self-describing and durable (PEP 723 is already this repo's #1 authoritative dependency source
per REQ-005.1), and gives a second, independently-maintained path to declare dependencies that
doesn't depend on `pipreqs` (which this repo already treats with some wariness -- see
`CLAUDE.md`'s pipreqs pin rationale section).

**Scope for v1: uv lane only** (the provider that created `.uv_env`), best-effort/non-gating,
**entry file only** (not every `.py` file in the folder). Replicating to conda/venv/embed/system
lanes is explicitly a later step.

## Big picture: how this fits with pipreqs, `autopep723`, and the existing dependency-source chain

Added 2026-07-12 in response to a direct question about how all the pieces relate -- worth stating
plainly since it's easy to conflate this feature with a bigger discovery-mechanism change it is
NOT:

- **This is not "running `autopep723` up front."** `autopep723` (the community tool) is not used
  anywhere in this design, in any capacity -- it was researched purely as prior art/comparison
  (Part 1's Pass 2, finding 5). This feature calls uv's own native `uv add --script` directly.
- **REQ-005.1's dependency-source discovery order is completely unchanged**: PEP 723 (if present
  and valid) > `pyproject.toml` > `requirements.txt` > `requirements.auto.txt` (pipreqs, non-
  authoritative) > empty. `pipreqs` is not being replaced, backed up, or run differently. This
  feature does not touch discovery at all.
- **This feature is a purely post-hoc, one-way promotion step**: it runs *after* dependencies are
  already resolved and installed (via whichever source was actually authoritative for that run),
  and writes the *final resolved set* into the entry file's PEP 723 header -- regardless of which
  tier in REQ-005.1's chain actually supplied it. If PEP 723 was already the source, there's
  nothing new to add (the "already authoritative" case, Part 2.2 point 7) and the call is a no-op.
  If `requirements.txt` or pipreqs supplied it, this is the mechanism that promotes that inferred
  set into the higher-priority, persistent PEP 723 form for next time.
- **Yes, `requirements.txt`/`requirements.auto.txt` are still left behind too, unchanged, in
  addition to the new PEP 723 header.** Nothing in this feature deletes or stops writing either
  file -- they remain exactly as useful as they already are today (a plain-text fallback readable
  without parsing TOML, and pipreqs's own inference record). No conflict: since PEP 723 is already
  the *highest*-priority authoritative source per REQ-005.1, having a PEP 723 header present
  automatically makes it win on the *next* run, with zero new precedence logic needed -- this falls
  directly out of the existing rule, nothing new to build.
- **"Append-only, never delete" symmetry with the `requirements.txt` process is already satisfied,
  for free, by uv's own confirmed behavior** (Part 1, Pass 1: adding a new package never removes or
  alters an existing entry). No additional robustness needs to be ported over from the
  `requirements.txt`/pipreqs side -- the two processes already behave the same way on this specific
  point, coincidentally, without either having been designed to match the other.
- **Relationship to REQ-004's `runtime.txt` write-back**: this feature is conceptually a sibling
  of REQ-004's existing "write back `runtime.txt` once the Python version is resolved" behavior --
  both persist an inferred fact into an authoritative, git-committable file so a future run (by
  this bootstrapper, or by anyone else who receives the file) starts from a documented, faster
  starting point instead of re-inferring from scratch. The plan's REQ-005.11 write-up (Part 2.4)
  should cross-reference REQ-004 explicitly as this pattern's existing precedent, rather than
  presenting the write-back idea as something novel to this repo.

---

## Part 1: Empirical findings (both testing passes)

### Pass 1 (2026-07-11, against uv 0.8.17 only)

- **No version bound written by default** at the time: `uv add --script file.py requests` wrote
  a bare `"requests"` line, confirmed even with `--offline` against an uncached package.
- **Idempotent**: re-running with an already-present package produced a byte-identical file.
- **Merges cleanly into an existing valid header**: a new package is appended alphabetically;
  an existing `requires-python` line is left completely untouched.
- **Malformed existing header -> hard error, file left untouched**: exit 2, TOML parse error,
  zero modification to the file. This makes a strip-then-retry repair sequence *mandatory*, not
  optional, since uv will never self-repair a broken block.
- **`requires-python` is auto-written only on first-ever header creation**, never touched on
  later `add` calls; fully controllable via `-p`/`--python "<path>"`.
- **`--no-sync` is a no-op in script mode** -- no redundant environment gets built as a side
  effect of adding a dependency; this is genuinely a metadata-only operation.
- **No package-existence validation at add time** -- `uv add --script` happily wrote a
  deliberately nonexistent package name with no error. This bootstrapper must only ever feed it
  package names it has *already confirmed installed*.

### Pass 2 (2026-07-12): web/docs/GitHub research

Full agent report is not reproduced verbatim here; the actionable findings are:

1. **Open uv bug, issue #15156 ("Cached Script Dependencies Not Properly Invalidated")**: a
   sequence of `uv add --script` (change deps) then `uv run --script` (execute) can see a STALE
   cached resolution even with `--refresh`/`--force-reinstall`; renaming the file "fixes" it,
   implying the cache key is filename-derived. **This bootstrapper does not call `uv run
   --script` on the entry file** (it runs the entry via its own separately-managed `.uv_env`
   interpreter, or the built PyInstaller EXE), so this bug does not affect this bootstrapper's
   own immediate execution correctness. It IS a real risk for the exact scenario this feature
   enables: someone *later* running the promoted, self-describing file directly via `uv run
   <entry>.py` outside this bootstrapper could hit stale cached results if a same-named file was
   previously run with different dependencies. Document as a known limitation, don't silently
   ignore.
2. **Lockfile side-effect** (confirmed independently in Pass 2's local testing, see below): if a
   `<entry>.py.lock` file already exists next to the target script, `uv add --script`
   automatically reads and rewrites/extends that lockfile as an undocumented side effect, with no
   flag to suppress it by default.
3. **Version drift is real and was directly demonstrated**, not just theoretical (see local
   testing below).
4. **Other confirmed GitHub issues**: #10918 (open) -- a `# ///` closing fence with trailing
   whitespace fails to parse as valid, meaning a header can become "malformed" from something as
   innocuous as an editor adding trailing whitespace, not just from bad TOML content (confirmed
   locally, see below). #15956 (open) -- `uv add --script` prints a benign stderr warning if
   `VIRTUAL_ENV` is set in the calling environment; not a failure (confirmed locally, see below).
   #13447 and #12499 were real past bugs (both fixed) about comment-deletion and TOML-block-
   adjacency corruption around the metadata block -- evidence the header-insertion logic has had
   genuine correctness bugs before.
5. **autopep723 does NOT validate `uv add --script`'s write path.** It has its own, independent
   TOML-writing code and only uses uv as an ephemeral runner (`uv run --with <deps>`), never `uv
   add`/`uv run --script`. There is no "battle-tested by a popular third-party tool" confidence to
   lean on here -- confidence rests solely on this repo's own direct testing plus uv's own
   documented/changelogged behavior.

### Pass 2 local scratch-dir testing (uv 0.8.17 vs uv 0.11.28, both installed side by side)

- **CONFIRMED VERSION DRIFT, directly observed, not inferred from changelog text alone**: uv
  0.11.28's default behavior differs from 0.8.17 -- it now writes a version *lower bound*
  (`"pandas[excel]>=3.0.3"`) where 0.8.17 wrote a bare name (`"pandas[excel]"`). This is the
  single most important finding of this pass: the "no version bound by default" claim from Pass 1
  was correct for 0.8.17 specifically and is **already false** for current uv. Since this repo
  never pins uv's version, production behavior will match whatever the *current* uv does, not the
  0.8.17 baseline. **Design implication: do not hard-code an assumption about whether a bound is
  present in the written output -- treat "whatever uv writes" as opaque and correct by
  construction**, which the original design already avoided asserting as a hard requirement, but
  this confirms that caution was warranted, not excessive.
- **Extras syntax (`pandas[excel]`) works correctly on both versions** and is correctly
  recognized as the same logical package on re-add: adding bare `pandas` after `pandas[excel]`
  was already present did not duplicate or downgrade the entry; the extras+bound form was kept.
- **CRLF line endings are NOT preserved in the inserted header** on either version: the new `#
  /// script ... # ///` block is written with LF line endings, while the original file's body
  (below the header) keeps its original CRLF endings untouched. This produces a *mixed*
  line-ending file if the original was CRLF throughout -- confirmed via byte-level hexdump
  inspection on both uv versions. This is cosmetic, not functional (Python's own parser and any
  reasonable editor handle mixed line endings fine), but should be mentioned in the feature's
  log/doc text so a Windows user who diffs their file isn't surprised.
- **Paths containing spaces work correctly** on both versions, given proper `"..."` quoting of
  the script path argument -- confirms the design's `"%HP_ENTRY%"` quoting approach is necessary
  and sufficient.
- **CONFIRMED: an existing `.lock` sidecar gets silently rewritten** as an automatic side effect
  of `uv add --script`, on both versions -- directly reproduced (mtime change, new package
  content appearing in the lock) with zero flags set. **Confirmed the exact filename convention**:
  `<script-name>.py` -> `<script-name>.py.lock` (verified directly, not assumed).
  - **Also tested**: `--frozen` *does* suppress the lockfile rewrite on 0.11.28 (mtime unchanged,
    new package not written into the lock), while still updating the `.py` header itself and
    without raising an error -- despite uv's own stderr text calling `--frozen` "a no-op for
    Python scripts with inline metadata." A quick follow-up check (`uv run --script ... --locked`
    against the now-out-of-sync lock) did not immediately surface an error either, which is
    surprising given `--locked`'s documented "assert lockfile unchanged" semantics. **This
    `--frozen` behavior is interesting but NOT adopted for v1** -- relying on an undocumented,
    seemingly-inconsistent interaction (a flag whose own warning text calls it a no-op, yet it
    measurably changes behavior) is riskier than the simpler original design decision: if a
    `.lock` file already exists, skip the write-back entirely. This respects a user who has
    opted into uv's stricter locked workflow and avoids scope creep into lockfile maintenance
    (hash verification, transitive pinning) which is a much bigger commitment than "write the
    dependency list."
- **CONFIRMED: trailing whitespace on the closing `# ///` fence causes the same hard error
  (exit 2, file untouched)** as gross TOML syntax errors, on both versions -- directly reproduces
  GitHub issue #10918's report. The malformed-header repair path must treat this as just another
  case of "uv said exit 2" (see Part 2's decision not to build a bespoke pre-validator), not a
  special case needing its own detection logic.
- **Duplicate-metadata-block test was inconclusive.** Attempted to reproduce the specific
  behavior change from PR #19544 ("reject duplicate script metadata blocks," landed ~0.11.17,
  previously silently treated as postlude). The synthetic test used (two complete, well-formed
  `# /// script ... # ///` block pairs back to back) produced an identical hard TOML-parse error
  on *both* 0.8.17 and 0.11.28 -- meaning this specific construction doesn't cleanly isolate the
  changelog's described behavior difference (the "silently treated as postlude" case likely
  requires a more specific malformed shape than what was tested here). **Do not treat this as
  "the risk doesn't exist"** -- it's a genuine gap in this testing pass, not a disproof of the
  changelog entry. The practical design implication stands regardless: the repair step's block-
  stripping regex must remove the *entire* old block cleanly, with no stray remnant that could
  read as a second block under any uv version's rules.
- **CONFIRMED: `VIRTUAL_ENV` set in the calling environment produces only a benign stderr
  warning** (`does not match the script environment path ... and will be ignored`), exit code
  still 0. Confirms the design point that stderr text must never be treated as a failure signal
  by itself -- only the process exit code should determine success/failure.

### Pass 3 (2026-07-14, against uv 0.8.17): pin-preservation on re-add, prompted by reviewing a
### third-party "PVW QuickStart" design (see `docs/plan-pvw-quickstart.md`)

Reviewing a user-supplied third-party document proposing a hand-rolled TOML-merge script to
"safely" re-add dependencies without downgrading existing pins raised the question of whether
`uv add --script` already does this natively -- Pass 2 had only confirmed this for extras syntax
(`pandas[excel]`), not explicit version pins or custom keys. Tested directly, three scenarios:

- **Re-adding an already-pinned package by its bare name does not downgrade the pin.** A header
  with `flask>=2.0` and `click==8.1.0`, followed by `uv add --script file.py flask`, produced a
  **byte-for-byte unchanged file**. This generalizes the Pass 2 extras finding to explicit
  `>=`/`==` pins, not just extras syntax.
  - **Practically-neutral (already the plan's own explicit no-op design decision) for THIS
    feature's own trigger paths, but confirms that decision more strongly than Pass 2 alone did.**
    Part 2.2 point 7 already commits to never comparing "what's already in the header" against
    "what to write back" and always calling `uv add --script` with whatever the resolved set is --
    this finding confirms that decision was safe even in its full generality (bare re-adds of
    already-pinned packages), not just the narrower extras case Pass 2 had actually tested.
- **Mixed re-add + genuinely-new-package call preserves old pins and adds only the new one.**
  `uv add --script file.py flask click requests` (two already-pinned, one new) left `flask>=2.0`
  and `click==8.1.0` untouched and added `requests` as a bare name in correct alphabetical
  position.
- **A hand-added custom TOML key outside `dependencies`/`requires-python` survives an `add`
  call untouched.** Confirms `uv add --script` performs a genuine targeted merge, not a
  rewrite-the-whole-block operation, in every dimension tested so far across all three passes.

No design change follows from this pass -- it is confirmation of an already-adopted decision, not
a new requirement. See `docs/plan-pvw-quickstart.md` for the sibling standalone feature this
finding was originally investigated for, which -- unlike this feature -- was able to drop a whole
hand-rolled TOML-merge step entirely as a direct result.

---

## Part 2: Code-grounded implementation plan

This section was produced by tracing the actual `run_setup.bat` (verify current line numbers
before implementing -- the file changes between now and whenever this is picked up; treat these
as strong pointers, not guaranteed-stable line anchors).

### 2.0 Corrections to the original (2026-07-11) design, found by reading the live code

1. **"Malformed header detection already exists" is only half true.** `:extract_pep723_requirements`
   is a naive PowerShell line-scanner, not a TOML validator -- it treats "block found but yielded
   zero deps" as the malformed signal, a weak proxy that will not necessarily agree with uv's real
   TOML parser on edge cases (e.g. the trailing-whitespace case above would likely not be caught by
   this exact-string check either). **Decision: do not build a second bespoke pre-validator.**
   Delegate malformed-detection entirely to uv itself via an attempt-first/strip-on-failure
   sequence (Part 2.2). This is more robust against version drift than hand-rolling TOML
   validation, since it automatically inherits whatever uv's authors decide "malformed" means,
   release to release.
2. **The literal log-contract string in the original design is unsafe as written.**
   `docs/agent-lessons-learned.md`'s "`:log` echoes UNQUOTED" section is explicit: `:log` does
   `echo %date% %time% %MSG%` with no quoting, so a literal `<`/`>` in the message text is parsed
   by cmd as redirection and silently eats the log line (this bit the REQ-009 cascade once
   already). The originally-proposed message `"[INFO] REQ-005: Wrote inferred dependencies into
   <entry>.py's PEP 723 header..."` **must not** be implemented with literal angle brackets. Drop
   the filename from the message entirely (recommended, matches several other REQ-005 log lines
   that don't name the file), or accept the same already-documented risk the four existing
   `%HP_ENTRY%`-in-`:log` call sites carry.
3. **Exact hook points and a new state variable needed:**
   - Fresh-install trigger: the `:lock_done` label (shared fallthrough for both conda and uv
     after dependency install + lock-snapshot capture, right before the pyvisa/visa detection
     comment). A single `if "%HP_ENV_MODE%"=="uv"` gate here covers both paths that can reach it.
   - Warnfix trigger: between the `[REPAIR] rebuild complete after warnfix.` log line and the
     `:warnfix_cascade_detect` call -- `~missing_modules.txt` and `~warnfix_repair_failed.flag`
     are both still on disk at that point (deleted shortly after), so this is the only safe
     window to read them.
   - **Neither trigger point currently knows *which* packages actually installed successfully**
     when the install command reports partial failure (a single `uv pip install -r
     requirements.txt` covering N packages failing doesn't say which of the N failed). Given the
     confirmed "uv never validates a package name" finding, adopt an **all-or-nothing
     confirmation rule per trigger**: only attempt write-back when the *entire* install/repair
     round is known to have fully succeeded, never a partial/best-guess subset. This is a
     deliberate, conservative scope decision, not an oversight.
4. **Re-entrancy.** The REQ-009 provider cascade re-enters `:after_env_mode_selection` from
   scratch on every tier retry (documented in `docs/agent-interconnect.md`: *"Do not introduce
   first-run-only state into `:after_env_mode_selection` without making it idempotent"*). The new
   `HP_UV_INSTALL_OK` tracking variable (2.3 below) must be reset at the top of that label's
   scope, alongside the existing `HP_DEP_SKIP`/`HP_DEP_RESULT` resets.

### 2.1 New embedded-helper shape

**One new Python helper, `tools/pep723_writeback.py`, embedded as `HP_PEP723_WRITEBACK`
(`~pep723_writeback.py`)**, with a canonical `tools/` source and a PayloadSync test -- matching
the more recent, more-scrutinized precedent (`collect_submodules.py`, `hidden_import_scan.py`)
rather than the older embedded-only style.

**Why a Python helper instead of inline batch `uv add --script pkg1 pkg2 ...`?** Assembling a
space-joined, individually-quoted package-arg list in batch from a loop over `requirements.txt`
requires delayed expansion (this repo's `agent-lessons-learned.md` explicitly warns against this,
and `tests/harness.ps1` has static checks forbidding it), and any package spec containing `<`/`>`
(a bare version constraint like `numpy<2`) would need extremely careful quoting to survive both
CMD's own parsing and any eventual `:log` call describing the result. Python already owns this
exact job pattern elsewhere in the repo (`~prep_requirements.py`).

Invoked as:
```
"%HP_PY%" "~pep723_writeback.py" "%HP_ENTRY%" "%HP_UV_EXE%" "%HP_PY%" "<packages_file>"
```
where `<packages_file>` is a plain-text file (one requirement-spec-or-bare-name per line) that
the batch caller has already produced by copying either `requirements.txt` (fresh trigger) or
`~missing_modules.txt` (warnfix trigger). No parsing of loose CLI args happens on the batch side.

**Helper logic** (steps 2-3 below added/revised 2026-07-12 per a 3rd-party technical review;
see the Non-Goals section right after this one for what was deliberately *not* adopted from the
same review):
1. Read the packages file; strip blank/`#`-comment lines. If empty, print `SKIP:no_packages`,
   exit 0.
2. **Encoding pre-check (new).** Attempt `open(entry_path, encoding="utf-8").read()` in a
   `try/except UnicodeDecodeError`. If it fails, print `SKIP:non_utf8`, exit 0, **without ever
   invoking uv**. Rationale: uv is Rust-based and its own file I/O behavior on a non-UTF-8 source
   (a legacy Windows-1252/"ANSI" file, or UTF-16LE from an old PowerShell `>` redirect) was not
   empirically tested in either research pass -- it's genuinely unknown whether uv errors safely
   or performs a lossy read/write that could silently replace non-ASCII bytes with the Unicode
   replacement character, corrupting the user's actual source code. Given that ambiguity, a cheap
   pre-check that sidesteps the question entirely (never hand uv a file we haven't confirmed is
   UTF-8) is safer than relying on uv's undetermined behavior. This also means the empirical
   re-verification step in Part 3 should add "does uv corrupt or safely reject a non-UTF-8 file"
   as an explicit thing to test once -- if it turns out uv already handles this safely, this
   pre-check becomes a harmless no-op, not a wrong design; if it doesn't, this pre-check is load
   -bearing. Either way, ship the pre-check regardless of that outcome, since it costs one cheap
   file read.
3. **File-lock canary (new, diagnostic-quality, not a correctness fix).** Attempt
   `open(entry_path, "r+b")` in a `try/except PermissionError`, then immediately close it without
   writing. If it fails, print `SKIP:file_locked`, exit 0, without invoking uv. **Important
   framing correction from the original review**: this is not closing a real safety gap -- the
   existing "any non-zero uv exit is caught by the generic `ERROR:uv_rc_<n>` path and never
   gates the Prime Directive" design already handles a locked file safely today, just with a less
   specific log message (uv would presumably fail with some non-zero exit on a locked file, which
   the catch-all in step 5 below already treats as a safe, non-fatal failure). This canary's only
   real value is a clearer, more specific skip reason in logs/tests rather than a generic error
   code -- worth adding since it's cheap, but not worth treating as a show-stopper fix the way the
   original review framed it. There is an inherent, accepted TOCTOU race (the lock could be
   acquired between this check and the actual `uv add --script` call) -- this is fine precisely
   because the fallback for that race is the same already-safe generic error path, not a crash.
4. Compute the lockfile sidecar path (`<entry>.py` -> `<entry>.py.lock`, confirmed convention)
   and check existence; if present, print `SKIP:lockfile`, exit 0, **without ever invoking uv**.
5. Run `uv add --script <entry> -p <python> <packages...>` via `subprocess.run`.
   - Exit 0: print `OK:<n>` (n = package count passed), exit 0.
   - Exit 2 (confirmed malformed-TOML signal, on both plain-syntax-error and trailing-whitespace
     cases -- the latter is specifically **GitHub issue #10918**; cite that issue number in the
     code comment next to this branch, per this repo's convention of tagging non-obvious
     constraints with their reason): **strip the entire existing `# /// script` ... `# ///`
     block** from the entry file, then retry the *same* `uv add --script` call exactly once.
     **Implementation note, corrected from the original design's "tolerant regex" language**: do
     NOT implement this as a single `re.DOTALL`-style regex spanning the whole file -- a greedy
     match risks stripping the user's actual code that follows the block, and a lazy match risks
     leaving a stray fence line behind (which, per **PR astral-sh/uv#19544**'s "reject duplicate
     script metadata blocks" change, could itself become a NEW hard-error on a sufficiently recent
     uv even though it wasn't previously -- cite that PR number in the code comment here too).
     Instead, iterate the file **line by line**, tracking a simple `in_block` boolean: start
     dropping lines when a line matches `^# /// script\s*$`-ish, keep dropping through and
     including the line that matches `^# ///\s*$` (tolerant of trailing whitespace, addressing
     #10918 directly), then stop. This is a small state machine, not a regex, and is much safer
     against both under- and over-matching on arbitrary user code. If the retry also fails, print
     `ERROR:strip_retry_failed:<rc>`, exit 1 (operate on an in-memory copy; only write the file if
     the retry is about to actually run).
   - Any other non-zero exit: print `ERROR:uv_rc_<n>`, exit 1. Do not attempt further repair --
     best-effort failure, consistent with "never gating." This is also the path a locked file or
     a read-only file (Windows Read-Only attribute, common on files pulled from a network share or
     extracted from a strict archive) falls into if the new canary checks above don't catch it
     first -- already safe by construction, nothing further needed for that case.
6. **Never treat stderr text as a failure signal by itself** (confirmed benign stderr can occur,
   e.g. **GitHub issue #15956**'s `VIRTUAL_ENV` warning -- cite that issue number in the code
   comment near wherever stderr is captured-but-ignored) -- success/failure is determined solely
   by the process return code.
7. Never call `uv add --script` with a package name that wasn't already present in the input
   file -- this helper performs zero independent package-name inference; it is purely a
   plumbing/CLI-safety layer over data the caller has already validated as "confirmed installed."

### Non-Goals & Safety (added 2026-07-12, to prevent scope creep once implementation starts)

- **No line-ending normalization, anywhere, ever.** The helper must never rewrite the whole
  entry file to a consistent line-ending style, even though the inserted header uses LF while
  the original file's body keeps whatever it already had (Part 1's confirmed mixed-line-ending
  finding). Normalizing is explicitly out of scope: it risks disrupting the user's own git
  history (`core.autocrlf` interactions) and breaking Docker/WSL workflows that may depend on the
  file's existing line endings -- a much bigger, riskier scope expansion than this feature's
  actual job. Surgical edits only: touch the metadata block, never anything else in the file.
- **No encoding "fixes."** If the encoding pre-check (helper step 2) fails, the helper skips and
  moves on -- it does not attempt to detect the actual encoding, transcode the file, or otherwise
  "help." File-parsing/encoding responsibility for the user's own source stays strictly with
  whatever the user's own tooling already does; this bootstrapper observes and skips, it does not
  silently rewrite.

The single stdout result line is read back into a batch variable via the same `for /f
"usebackq delims=" %%R in ("~pep723_result.txt") do set "HP_PEP723_RESULT=%%R"` pattern already
used for `~dep_check.py`'s result line, keeping the new code idiomatic with the rest of the file.

Because the helper does the strip-and-retry internally, `run_setup.bat` never needs its own
bespoke "detect malformed PEP 723 header" step for this feature -- it delegates entirely to uv's
exit code (per 2.0's point 1), which is simpler and more future-proof than hardcoding today's
understanding of "malformed" into a second parser that could silently diverge from uv's own
evolving rules.

### 2.2 Skip-condition checks (in order, short-circuit) and flag wiring

New subroutine `:pep723_writeback`, called with one argument (`fresh` or `warnfix`) for log-
message differentiation. Goto-based internal dispatch, not nested parens, per this repo's
established cascade-dispatch convention.

1. `if not "%HP_ENV_MODE%"=="uv" exit /b 0` -- v1 scope gate, silent (no log line at all, to
   avoid log noise on every single non-uv run).
2. `if defined HP_SKIP_PEP723_WRITEBACK ( call :log "[INFO] REQ-005: PEP 723 write-back skipped
   (HP_SKIP_PEP723_WRITEBACK set)." & exit /b 0 )` -- new suppression-only flag (per README's now-
   numbered `[REQ-019]` "flags only suppress" rule -- promoted from an unnumbered reference section
   to its own requirement, 2026-07-12, specifically so it has a stable number to cite instead of
   the ambiguous "see the Advanced Environment Variables section" phrasing earlier drafts used).
3. `if defined HP_CI_SKIP_ENV exit /b 0` -- defensive; technically unreachable given call-site
   ordering, but cheap insurance against a future refactor.
4. `if not defined HP_UV_EXE exit /b 0` / `if not defined HP_ENTRY exit /b 0` / `if not exist
   "%HP_ENTRY%" exit /b 0` -- defensive precondition re-checks, matching this repo's general
   subroutine-boundary style.
5. **Trigger-specific "confirmed installed" gate** (new, from 2.0 point 3):
   - Fresh trigger: `if not defined HP_UV_INSTALL_OK` -> skip with an `[INFO]` line explaining
     the install did not fully succeed. `HP_UV_INSTALL_OK` is a **new** variable, set to `1`
     inside the existing uv-install branch on genuine install success, and also set to `1` when
     `HP_DEP_SKIP` short-circuited the install (already-satisfied-by-lock case -- still a
     "confirmed installed" state). **Must be reset with the literal, explicit form
     `set "HP_UV_INSTALL_OK="` (nothing after the `=`)** at the top of `:after_env_mode_selection`,
     alongside the existing `HP_DEP_SKIP`/`HP_DEP_RESULT` resets, for cascade re-entrancy
     correctness (2.0 point 4) -- called out explicitly here because a provider-cascade downgrade
     (e.g. uv exhausted, cascading to conda) that fails to clear this variable would let a stale
     `HP_UV_INSTALL_OK=1` from the *previous*, now-abandoned uv attempt silently satisfy this gate
     on a later, unrelated trigger.
   - Warnfix trigger: `if exist "~warnfix_repair_failed.flag"` -> skip (all-or-nothing per
     round).
6. **Existing `.lock` sidecar check** -- implemented inside the Python helper (2.1 step 4), not
   in batch. Batch-side callers interpret the helper's `SKIP:lockfile` result and log accordingly
   (no filename in the message, per the `:log` unquoted-metacharacter rule).
7. **REJECTED, not merely deferred: no "already-authoritative, nothing changed" no-op
   optimization.** The original draft flagged this as an optional nice-to-have (skip the uv call
   entirely when the resolved set already matches an existing PEP 723 header, to avoid an
   unnecessary file touch). Per a 2026-07-12 review: **do not build this at all, in v1 or later.**
   `uv add --script` is independently confirmed idempotent and fast on a no-op case -- the
   Python-side cost of parsing the existing header, comparing it against the resolved set, and
   branching on the result is real, ongoing code-maintenance surface for a benefit (skipping one
   harmless, fast, idempotent uv call) that doesn't justify it. This is a permanent scope
   decision, not a "not yet."

**`HP_SKIP_PEP723_WRITEBACK` wiring**: declared alongside other `HP_SKIP_*` flags near the top of
the file; documented in README's "Advanced Environment Variables" table and cross-referenced to
`[REQ-019]`.

**Log contract (revised for `:log` safety, per 2.0 point 2):**
- Success: `[INFO] REQ-005: PEP 723 header write-back succeeded via uv add --script.` (no entry
  filename, no raw package-spec text; a package count via a plain-decimal variable is fine if
  wanted).
- Each skip condition: its own `[INFO]`-level, operator-free, filename-free message, so log-
  scraping tests can distinguish reasons.
- Failure: `[WARN] REQ-005: PEP 723 header write-back failed (uv exit <n>); continuing.` where
  `<n>` is a plain decimal exit code -- never gates the Prime Directive.

### 2.3 CI test plan

New file **`tests/selfapps_pep723_writeback.ps1`**, structured like `tests/selfapps_warnfix.ps1`
(scenario-selected via an env var) and reusing the `Write-NdjsonRow` boilerplate pattern already
duplicated across every `selfapps_*.ps1` file (no shared module exists in this repo -- follow
that convention rather than introducing a new shared import). Each scenario spins up its own
scratch directory, copies `run_setup.bat` in, writes a stub `.py`, runs the bootstrap, and asserts
against both the log AND the entry file's own post-run content (this feature's whole point is a
file mutation, so assertions must read the actual `.py` file, not just log text).

| Test ID | Setup | Assertions |
|---|---|---|
| `self.pep723.writeback.fresh` | No existing header; stub imports `requests` (pipreqs/heuristic resolves `requests`+`certifi`); no `requirements.txt`/`pyproject.toml`. | Success log line present; entry file now contains a `# /// script` block with `requests`/`certifi` and a `requires-python` line. |
| `self.pep723.writeback.idempotent` | Run the bootstrapper twice in the same scratch dir without deleting the entry file. | Entry file byte-identical after run 2 vs. run 1. |
| `self.pep723.writeback.malformed` | Entry file pre-seeded with a deliberately broken `# /// script` block. | Success log line still appears (strip-then-retry worked); post-run entry file has a valid, freshly-written header, not the original broken block. |
| `self.pep723.writeback.skipflag` | `HP_SKIP_PEP723_WRITEBACK=1`; no pre-existing header. | Entry file byte-identical before/after; skip-flag log line present. |
| `self.pep723.writeback.warnfix` | Entry imports a module warnfix (not pipreqs) will discover, forcing the repair loop to fire during the build. | Both the warnfix repair AND a second write-back succeed; post-run header includes the warnfix-only-discovered module, proving the second trigger point fires. |
| `self.pep723.writeback.trailing_ws_malformed` (new, from issue #10918) | Entry pre-seeded with an otherwise-valid header whose closing `# ///` fence has trailing whitespace. | Same success assertions as `.malformed` -- proves the strip-and-retry path handles this "looks fine to a human, invalid to a strict parser" case, and that the entire old block (not a stray remnant) got removed. |
| `self.pep723.writeback.existing_lockfile` (new, from finding #2) | No pre-existing header, but a `<entry>.py.lock` sidecar is pre-created before the run. | Lockfile-skip log line present; entry `.py` file byte-identical before/after (no header written); the `.lock` file itself untouched -- proves the helper truly never invokes `uv add --script` in this case. |
| `self.pep723.writeback.non_utf8` (new, added 2026-07-12 per technical review) | Entry file's body written with a deliberately non-UTF-8 encoding (e.g. Windows-1252 with a byte sequence like `\x93...\x94` "smart quotes" that isn't valid UTF-8), no pre-existing header. | Skip log line present (`SKIP:non_utf8` surfaced as an `[INFO]` line); entry file byte-identical before/after -- proves the encoding pre-check prevents ever handing a non-UTF-8 file to uv, regardless of what uv itself would have done with it. |

All scenarios need `HP_ENV_MODE` to actually resolve to `uv`; each test should assert that
precondition explicitly and emit `skip=true` with reason `provider_not_uv` if a given CI lane
doesn't reach uv (mirroring this suite's existing non-Windows-skip pattern, applied to a
different precondition).

**Test-fixture encoding, called out explicitly (a real risk specific to the CI harness, not the
feature itself):** the `.idempotent` and `.skipflag` scenarios assert the entry file is **byte-
identical** before/after. PowerShell's `Set-Content`/`Out-File` cmdlets do not default to plain
UTF-8-without-BOM -- depending on PowerShell version they can default to UTF-16LE-with-BOM or
add a BOM to UTF-8, and always write CRLF. If the test harness stubs the `.py` file using a bare
`Set-Content`/`Out-File` call, a later `git checkout`/`core.autocrlf` normalization or an
incidental BOM could make a byte-comparison fail even when the content is logically identical,
producing a flaky or wrong test independent of the feature actually working. **Every stub-writing
step in `tests/selfapps_pep723_writeback.ps1` must use an explicit, BOM-free UTF-8 encoding**
(`Set-Content -Encoding utf8NoBOM` on PowerShell 6+, or the raw `[System.IO.File]::WriteAllText`
.NET-API pattern this repo already prefers per `docs/agent-lessons-learned.md`'s "Prefer raw .NET
types" entry) -- do not rely on a cmdlet default.

**CI wiring**: add step(s) invoking the new test file in `.github/workflows/batch-check.yml`,
gated to lanes where uv is the default provider (`real`/`cache`), explicitly NOT `conda-full`
(which forces conda-only, out of v1 scope). Confirm the exact lane-to-provider mapping
empirically (Part 3) rather than assuming.

### 2.4 Docs to update in the same commit

- `docs/agent-ndjson.md`: the 8 new row IDs (7 original + `.non_utf8`), in a new subsection for
  whichever lane(s) the CI wiring lands on.
- `docs/agent-interconnect.md`: a new section near the existing `### warnfix install + uv mode`
  and `### dep-check + uv mode lock file interconnection` sections, since this feature is a
  direct sibling dependency of both. Cross-reference: REQ-002 entry selection, REQ-005's
  `requirements.txt` snapshot timing (post-augmentation, not pre), uv-only `HP_UV_EXE`
  availability, and the `HP_UV_INSTALL_OK` re-entrancy requirement.
- `docs/agent-lessons-learned.md`: consider a small addendum to the existing "`:log` echoes
  UNQUOTED" section noting this feature's near-miss (2.0 point 2), only if the implementation
  actually needed the correction (per that doc's "record hazards actually hit" convention).
- `README.md`: new **`[REQ-005.11]`** sub-section (following the `## [REQ-023] Venv Fallback
  Canary Probe` format: title, bullets, explicit Log contract, CI test flag, Test NDJSON rows) --
  explicitly cross-reference **REQ-004** (`runtime.txt` write-back) as this feature's existing
  sibling precedent, per the Big Picture section above, so a reader doesn't have to independently
  notice the two features share a design pattern; new row in the "Advanced Environment Variables"
  table for `HP_SKIP_PEP723_WRITEBACK=1`, cross-referenced to `[REQ-019]`.
- `CLAUDE.md`: move the Active Backlog pointer to this document into Closed Backlog once shipped,
  following the existing Closed Backlog entry style -- what shipped, what was corrected from this
  plan during implementation, "CLOSED by this PR."
- **Code comments citing specific GitHub issues/PRs**, per this repo's existing "tag non-obvious
  constraints with their reason" convention (`CLAUDE.md`'s Key Conventions table) -- not optional
  polish, an explicit implementation requirement: the trailing-whitespace-fence handling in the
  strip step (helper step 5) must cite **astral-sh/uv#10918**; the "why a line-by-line state
  machine instead of a DOTALL regex" comment must cite **astral-sh/uv#19544** (the duplicate-
  block-rejection change that motivates fully removing the old block, not just approximately);
  the "why stderr is never treated as a failure signal" comment must cite **astral-sh/uv#15956**;
  and, if the promoted file's future-portability limitation is mentioned anywhere user-facing or
  in this plan's own README write-up, cite **astral-sh/uv#15156** (the open cache-staleness bug)
  as the reason it's called out as a known limitation rather than silently ignored.

---

## Part 3: Required first step before writing any code

Before writing any `run_setup.bat` or helper code, the implementer must re-run an abbreviated
version of the Part 1 empirical testing against whatever `uv` version is actually current at
implementation time (this repo never pins uv, and Part 1 already directly demonstrated real
behavior drift between 0.8.17 and 0.11.28, not just theoretical risk):

1. Check `uv --version`.
2. In a scratch directory, re-confirm: idempotency of repeated adds; malformed-header exit code
   and untouched-file behavior; `requires-python` one-time-write behavior and `-p` control;
   `--no-sync` no-op status; no package-existence validation; the trailing-whitespace-closing-
   fence malformed case (issue #10918); the `<script>.py.lock` filename convention and its
   auto-rewrite side effect; **and, new for this pass, `uv add --script`'s actual behavior against
   a deliberately non-UTF-8-encoded target file** (Part 2.1 step 2's rationale) -- confirm whether
   it errors safely, corrupts silently, or does something else, since this directly determines
   whether the encoding pre-check is purely defensive insurance or an actually-load-bearing fix.
3. Record findings as a dated addendum to this document (in the style of Part 1's two existing
   dated passes) before writing batch/Python code, so the design's assumptions are re-validated
   against current reality rather than trusted from this document alone.

## Part 3.5: ongoing drift detection, not just a one-time dev check

Part 3's re-verification is a **one-time** pass done once, right before implementation starts --
but this repo's CI always fetches whatever uv is currently latest (the uv-first REQ-009
philosophy, no pin), which means **every real CI run of `tests/selfapps_pep723_writeback.ps1`
after this feature ships is itself an ongoing, automatic re-verification of these same
assumptions against whatever uv actually is at that moment** -- not a one-time gate that goes
stale the day after implementation. This is worth stating explicitly as the feature's real
long-term safety net, and mirrors the "next-pin probe" maintenance pattern already documented in
`CLAUDE.md`'s Periodic Maintenance Checks section for other never-pinned dependencies (`pipreqs`,
the embed-tier Python table): an unexpected CI failure in one of these tests down the road is
itself the signal that uv's behavior has drifted again, not a mysterious flake to explain away.
**If/when that happens**, the fix loop is: re-run Part 3's scratch-dir re-verification against
the new uv version, update this document with a new dated addendum (matching Part 1's existing
two-pass pattern), and patch `tools/pep723_writeback.py` to match -- the same loop this document
itself has already been through twice. This is also why every design decision in Part 2 that
traces back to a specific uv issue/PR number is tagged as such (2.4's "code comments citing
specific issues" requirement): a future maintainer debugging a CI failure in this area should be
able to find the relevant upstream issue by name instead of re-deriving the reasoning from
scratch.

---

## Part 4: Sizing and iteration-slicing recommendation

The core feature (fresh trigger + warnfix trigger + skip flag + happy-path tests) fits comfortably
in this repo's "one feature slice per loop" norm. The additions from the code-grounded pass (the
`HP_UV_INSTALL_OK` state, the lockfile-skip path, the two new adversarial-input test scenarios)
push it closer to the edge of a single slice. **Recommended split if the single-loop budget feels
tight:**

- **Loop 1**: the two hook points, skip-condition logic, `tools/pep723_writeback.py` (including
  the encoding pre-check and file-lock canary from the 2026-07-12 review -- both are cheap enough
  to belong in Loop 1, not deferred), and the three simplest/most load-bearing tests (`fresh`,
  `idempotent`, `skipflag`) -- proves the mechanism works end to end. All doc updates except the
  Closed Backlog move.
- **Loop 2**: the five "resilience under adversarial input" tests (`malformed`, `warnfix`,
  `trailing_ws_malformed`, `existing_lockfile`, `non_utf8`), CI workflow wiring, and the Closed
  Backlog move.

Loop 1 alone already ships a working, tested feature; Loop 2 hardens it against the specific edge
cases these two research passes surfaced, rather than being pure test-count padding.

**Part 3's empirical re-verification step happens at the very start of Loop 1**, not as a
separately schedulable task -- it directly determines whether the malformed-detection design in
Part 2.1 still matches current uv behavior before any code is written against it.

---

## Critical files for implementation

- `run_setup.bat` -- hook points at `:lock_done` and the warnfix repair block; new
  `:pep723_writeback` subroutine and `HP_PEP723_WRITEBACK` base64 payload declaration.
- `tools/pep723_writeback.py` (new) -- canonical helper source, following the
  `tools/collect_submodules.py` / `tools/hidden_import_scan.py` PayloadSync-tested pattern.
- `tests/selfapps_pep723_writeback.ps1` (new) -- following `tests/selfapps_warnfix.ps1`'s
  scenario-selection structure and `tests/selfapps_ux_hardening.ps1`'s NDJSON boilerplate.
- `tests/test_pep723_writeback.py` (new) -- following `tests/test_collect_submodules.py`'s
  `PayloadSync` class pattern.
- `.github/workflows/batch-check.yml` -- new CI step(s), gated to uv-default lanes.
- `CLAUDE.md` -- Active Backlog pointer -> Closed Backlog move once shipped.
