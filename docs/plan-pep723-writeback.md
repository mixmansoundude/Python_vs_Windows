# Implementation Plan: PEP 723 Dependency Write-Back via `uv add --script`

**Status:** Implementation-ready. Two research/testing passes completed (2026-07-11 initial
design + local scratch-dir verification against uv 0.8.17; 2026-07-12 follow-up: web/docs/GitHub-
issues research pass, a second local scratch-dir pass comparing uv 0.8.17 against uv 0.11.28 to
directly test version-drift risk, and a code-grounded implementation pass tracing the actual
`run_setup.bat` hook points). No code written yet.
**Owner:** Python_vs_Windows maintainer
**Related:** `CLAUDE.md` Active Backlog (this item is linked from there); `docs/prd-av-safe-build-
path.md` (a structurally similar large design doc, for format precedent).

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

**Helper logic:**
1. Read the packages file; strip blank/`#`-comment lines. If empty, print `SKIP:no_packages`,
   exit 0.
2. Compute the lockfile sidecar path (`<entry>.py` -> `<entry>.py.lock`, confirmed convention)
   and check existence; if present, print `SKIP:lockfile`, exit 0, **without ever invoking uv**.
3. Run `uv add --script <entry> -p <python> <packages...>` via `subprocess.run`.
   - Exit 0: print `OK:<n>` (n = package count passed), exit 0.
   - Exit 2 (confirmed malformed-TOML signal, on both idle-syntax-error and trailing-whitespace
     cases): **strip the entire existing `# /// script` ... `# ///` block** from the entry file
     (tolerant regex matching both fence lines with optional trailing whitespace), then retry the
     *same* `uv add --script` call exactly once. If the retry also fails, print
     `ERROR:strip_retry_failed:<rc>`, exit 1 (operate on an in-memory copy; only write the file
     if the retry is about to actually run).
   - Any other non-zero exit: print `ERROR:uv_rc_<n>`, exit 1. Do not attempt further repair --
     best-effort failure, consistent with "never gating."
4. **Never treat stderr text as a failure signal by itself** (confirmed benign stderr can occur,
   e.g. the `VIRTUAL_ENV` warning) -- success/failure is determined solely by the process return
   code.
5. Never call `uv add --script` with a package name that wasn't already present in the input
   file -- this helper performs zero independent package-name inference; it is purely a
   plumbing/CLI-safety layer over data the caller has already validated as "confirmed installed."

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
   (HP_SKIP_PEP723_WRITEBACK set)." & exit /b 0 )` -- new suppression-only flag (REQ-001 "flags
   only suppress" rule).
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
     "confirmed installed" state). Reset to empty at the top of `:after_env_mode_selection` for
     cascade re-entrancy correctness (2.0 point 4).
   - Warnfix trigger: `if exist "~warnfix_repair_failed.flag"` -> skip (all-or-nothing per
     round).
6. **Existing `.lock` sidecar check** -- implemented inside the Python helper (2.1 step 2), not
   in batch. Batch-side callers interpret the helper's `SKIP:lockfile` result and log accordingly
   (no filename in the message, per the `:log` unquoted-metacharacter rule).
7. **Optional, not load-bearing for v1**: an "already-authoritative, nothing changed" no-op check
   -- when the run's dep source was already PEP 723 and the resolved set is unchanged from what's
   already declared, skip the uv call entirely to avoid an unnecessary file touch on every run.
   Since `uv add --script` is independently confirmed idempotent, correctness does not depend on
   this optimization -- cutting it for v1 still produces a correct feature, just with one extra
   no-op uv invocation per run on already-fully-annotated scripts. **Flagged as a nice-to-have,
   safe to defer to a later pass.**

**`HP_SKIP_PEP723_WRITEBACK` wiring**: declared alongside other `HP_SKIP_*` flags near the top of
the file; documented in README's "Advanced Environment Variables" table as suppression-only, per
REQ-001.

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

All scenarios need `HP_ENV_MODE` to actually resolve to `uv`; each test should assert that
precondition explicitly and emit `skip=true` with reason `provider_not_uv` if a given CI lane
doesn't reach uv (mirroring this suite's existing non-Windows-skip pattern, applied to a
different precondition).

**CI wiring**: add step(s) invoking the new test file in `.github/workflows/batch-check.yml`,
gated to lanes where uv is the default provider (`real`/`cache`), explicitly NOT `conda-full`
(which forces conda-only, out of v1 scope). Confirm the exact lane-to-provider mapping
empirically (Part 3) rather than assuming.

### 2.4 Docs to update in the same commit

- `docs/agent-ndjson.md`: the 7 new row IDs, in a new subsection for whichever lane(s) the CI
  wiring lands on.
- `docs/agent-interconnect.md`: a new section near the existing `### warnfix install + uv mode`
  and `### dep-check + uv mode lock file interconnection` sections, since this feature is a
  direct sibling dependency of both. Cross-reference: REQ-002 entry selection, REQ-005's
  `requirements.txt` snapshot timing (post-augmentation, not pre), uv-only `HP_UV_EXE`
  availability, and the `HP_UV_INSTALL_OK` re-entrancy requirement.
- `docs/agent-lessons-learned.md`: consider a small addendum to the existing "`:log` echoes
  UNQUOTED" section noting this feature's near-miss (2.0 point 2), only if the implementation
  actually needed the correction (per that doc's "record hazards actually hit" convention).
- `README.md`: new REQ-005 sub-bullet (or a standalone `[REQ-005.11]`-style section, following the
  `## [REQ-023] Venv Fallback Canary Probe` format: title, bullets, explicit Log contract, CI test
  flag, Test NDJSON rows); new row in the "Advanced Environment Variables" table for
  `HP_SKIP_PEP723_WRITEBACK=1`.
- `CLAUDE.md`: move the Active Backlog pointer to this document into Closed Backlog once shipped,
  following the existing Closed Backlog entry style -- what shipped, what was corrected from this
  plan during implementation, "CLOSED by this PR."

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
   auto-rewrite side effect.
3. Record findings as a dated addendum to this document (in the style of Part 1's two existing
   dated passes) before writing batch/Python code, so the design's assumptions are re-validated
   against current reality rather than trusted from this document alone.

---

## Part 4: Sizing and iteration-slicing recommendation

The core feature (fresh trigger + warnfix trigger + skip flag + happy-path tests) fits comfortably
in this repo's "one feature slice per loop" norm. The additions from the code-grounded pass (the
`HP_UV_INSTALL_OK` state, the lockfile-skip path, the two new adversarial-input test scenarios)
push it closer to the edge of a single slice. **Recommended split if the single-loop budget feels
tight:**

- **Loop 1**: the two hook points, skip-condition logic, `tools/pep723_writeback.py`, and the
  three simplest/most load-bearing tests (`fresh`, `idempotent`, `skipflag`) -- proves the
  mechanism works end to end. All doc updates except the Closed Backlog move.
- **Loop 2**: the four "resilience under adversarial input" tests (`malformed`, `warnfix`,
  `trailing_ws_malformed`, `existing_lockfile`), CI workflow wiring, and the Closed Backlog move.

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
