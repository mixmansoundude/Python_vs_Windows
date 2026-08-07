# Agent Lessons Learned -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-lessons-learned.md`
import in CLAUDE.md. It collects standalone hazards, hard-won rules, budgets, gotchas, and
procedures discovered while working on this repo -- the things that are easy to get wrong
again and cost a CI cycle (or worse) to rediscover.

**Categorization principle (shared with `docs/agent-interconnect.md`):**
- **interconnect** = a dependency between two or more components such that changing one
  requires understanding the other ("touch A, must understand B"). Lives in
  `docs/agent-interconnect.md`.
- **lessons learned** = a discovered fact, hazard, budget, or procedure that stands on its
  own. Lives here.

**AGENT DIRECTIVE: keep this file AND `docs/agent-interconnect.md` current -- update existing
entries, not just append new ones -- in the SAME commit as the change that taught (or
invalidated) the lesson. Most lessons in this repo are batch/CMD syntax quirks and Windows
shell gotchas; record those here. Record cross-component effects in the interconnect map. If
a lesson is later disproven or fixed at the source, edit the entry to say so rather than
leaving stale guidance.**

---

## Never open a real source file in Python `'w'` mode as part of a "dry run" -- write to a NEW path and diff before overwriting

**Genuine near-miss (2026-07-25) while fixing the `HP_PREP_REQUIREMENTS` payload.** A verification
script meant to preview a payload-line swap opened `run_setup.bat` with `open(..., 'w', ...)`,
intending to fill in the write logic later (`... pass`). Python's `'w'` mode truncates a file to
zero bytes THE MOMENT `open()` succeeds, regardless of whether anything is ever written -- this
left `run_setup.bat` (~4715 lines, the repo's entire deliverable) at 0 bytes. Caught immediately
via `wc -l`/`git status` (cheap, worth running reflexively after any script touching a tracked
file) and restored losslessly via `git checkout --` since there were no uncommitted changes at the
time -- if there had been, those would have been lost too.

**Rule: a script that INSPECTS or PREVIEWS a change to an existing tracked file must never open it
in a write/truncate mode (`'w'`, `'wb'`), even speculatively.** Safe pattern: read as bytes, build
the modified content entirely in memory, diff the candidate against the original to confirm only
intended lines changed, THEN copy the verified candidate over the real file as the last step. For
`run_setup.bat` specifically, also re-run `tools/check_delimiters.py` and confirm the line count
is unchanged immediately after any swap.

**Automated same day: `tools/sync_payload.py`** implements this exact procedure as a reusable
tool -- reads `run_setup.bat` as bytes, verifies the diff touches EXACTLY the target
`set "HP_VARNAME=..."` line, checks the CMD 8191-char budget, and only then writes (refuses with
no write if any check fails). See "Embedded Helper Update Workflow" below; use it instead of a
one-off inline snippet for every future payload swap.

---

## `rem` needs a space after it -- `rem-word` is parsed as a command, not a comment

**Found via a real CI failure on PR #380.** A multi-line `rem` comment wrapped the phrase "an
already-nested failure path" across two lines, splitting at the hyphen:
```bat
rem is to report it, not to speculatively rebuild via a second tool inside an already
rem-nested failure path.
```
cmd.exe only treats a line as a comment when `rem` is followed by whitespace (or EOL) --
`rem-nested` has no space, so cmd.exe parsed it as an attempt to run a nonexistent command
literally named `rem-nested`: `'rem-nested' is not recognized as an internal or external
command...`. This left a **nonzero errorlevel** sitting immediately before the very next line, a
freshly-added `if errorlevel 1 (...)` check for the PyInstaller rebuild's own exit code -- so the
stray comment's own failure was silently misattributed to PyInstaller, even though PyInstaller had
already produced the EXE successfully. Confirmed by reading the real CI artifact's
`~warnfix_bootstrap.log` directly.

**Rule: never split a hyphenated word across two `rem` lines by putting the second half at the
start of the next line.** More generally: any time a `rem` line's very next character after "rem"
is NOT whitespace, cmd.exe does not treat it as a comment at all -- it executes that leading token
as a command name.

**Automated same day: `tools/check_delimiters.py`'s `_check_bat_rem_comment_spacing` now catches
this** -- any `.bat`/`.cmd` line whose first token starts with `rem` immediately followed by a
non-whitespace character is flagged, part of the standard sweep.

---

## .NET Process async-redirected-output: "call WaitForExit() twice" is NOT sufficient to guarantee buffers are drained [SUPERSEDED]

**Superseded 2026-07-24 by the `ReadLineAsync()`/chunk-read entries below -- kept only for the
methodology lesson.** Microsoft's own docs for `Process.WaitForExit(Int32)` say calling the
no-arg `WaitForExit()` overload after a timed one returns `true` ensures async output handling
has completed. Empirically FALSE for `Register-ObjectEvent` on `OutputDataReceived`: a direct
`pwsh` repro (5/5 deterministic) showed the final event -- carrying a line flushed only at
process exit -- firing AFTER both `WaitForExit()` calls returned, silently truncating the
captured buffer with no error. Reproduced only when the `pwsh`-launching chain was itself
launched via Python's `subprocess.run(..., capture_output=True)`, not from an interactive shell
(same "differs by invocation shape" class as this repo's `Get-FileHash` module-autoload gap).
**Rule: never trust a documented "async handling has completed" guarantee without empirical
verification** -- this specific mechanism (`Register-ObjectEvent` + explicit EOF-flag polling) is
gone from the codebase, replaced entirely by `StreamReader` async reads (see entries below), which
have no equivalent drain race (a completed read task with a `$null`/`0` result IS the stream's own
EOF signal).

**Companion fact, still load-bearing (referenced by later entries):** Python's `input(prompt)`
DOES flush stdout before blocking on stdin, even when stdout is redirected/non-tty (confirmed via
direct reproduction). So a program that asks setup questions via `input()` then loops is NOT at
risk of the buffering hazard above -- that hazard mainly bites `print()` calls made well before
the next `input()`/exit, not the interactive prompts themselves.

---

## `Register-ObjectEvent` reorders lines WITHIN a single stream -- confirmed upstream bug [SUPERSEDED to chunk reads, pattern still valid]

**Superseded same day (2026-07-24) by chunk-based `ReadAsync()` -- see the next entry -- but the
single-read-in-flight POLLING PATTERN this entry introduced still holds; only the read primitive
changed (line-based to chunk-based).**

Found via `tests/test_failfast_probe.py`'s `InteractiveRoundTrip` test (a scripted `input()`/
`print()` conversation): 2/5 local runs showed a LATER round's output appearing BEFORE an EARLIER
round's in the captured/teed text -- a silent in-place transposition, worse than a dropped/late
line. **Root cause: `Register-ObjectEvent` dispatches each event via
`ThreadPool.QueueUserWorkItem`, which gives no ordering guarantee between queued work items** --
two lines from the same stream arriving close together can have their `-Action` callbacks run on
different pool threads in either order. Confirmed upstream, not sandbox-specific:
[PowerShell/PowerShell#11937](https://github.com/PowerShell/PowerShell/issues/11937).

**Fix: stop using `Register-ObjectEvent`. Poll a single in-flight async read per stream instead**
(`$task = $p.StandardOutput.ReadLineAsync()`; only issue the next read after consuming the
current one's `.Result`) -- ordering is enforced by construction, never more than one outstanding
read racing against itself per stream. Cross-stream (stdout vs. stderr) interleaving was never
guaranteed either way -- that's the child's own two independent OS pipes, not a defect. This also
subsumes the drain-race workaround from the entry above (a completed task with `$null` .Result IS
the EOF signal, no separate flag-polling needed). Applied to `tools/failfast_probe.ps1` and
`tools/exe_smokerun.ps1`; a future third consumer should use this polling pattern from the start.
Verified 20/20 clean post-fix (vs. 2/5 before). See `docs/plan-cli-interactive-verification.md`
Finding 8 for full context.

---

## `StreamReader.ReadLineAsync()` is line-buffered: a prompt with no trailing newline is invisible until something else flushes a line -- fixed by switching to `ReadAsync()` chunk reads

Found during a refinement pass on already-shipped work; motivated by the owner independently
hitting the same class of bug (progress dots delayed in a frozen EXE, fixed via explicit
`.flush()`).

**The problem**: Python's `input(prompt)` writes the prompt to stdout and flushes immediately
(see the companion fact two entries up) but WITHOUT a trailing newline, by design -- the cursor
stays on the same line. `ReadLineAsync()` does not return anything for a stream until a full
newline-terminated line arrives, or EOF -- so the flushed prompt bytes sit in the OS pipe,
invisible to the reader. Confirmed directly: a child writing `"Enter your name: "` then blocking
on stdin produced ZERO completed `ReadLineAsync()` reads for 2+ seconds even though the bytes
were provably there (`CanRead` confirmed). The text only surfaces once a later write adds a
newline (concatenating the prompt with whatever comes after into one misleadingly-timed chunk) or
the process exits.

**Why this stayed hidden through two prior rounds of round-trip testing**: both the local test
and `selfapps_interactive_stdin.ps1` feed the ENTIRE scripted answer sequence through stdin
essentially instantly -- a pre-loaded answers file can't distinguish "surfaced instantly" from
"surfaced only once something else happened to flush a line," since both produce the same final
captured text. This is a structural blind spot in any timing-insensitive test, not a flaw in
those tests' own (correctly scoped) design.

**Fix: replace `ReadLineAsync()` with `StreamReader.ReadAsync(char[], int, int)`** on a fixed
buffer (same single-read-in-flight polling shape as the entry above, only the primitive changed),
so any available bytes surface the moment they arrive. `Write-Host`/`WriteLine` become
`[Console]::Out.Write($chunk)`/`[Console]::Error.Write($chunk)` (chunks arrive at arbitrary
boundaries now, not lines); EOF becomes a 0-length read, not a `$null` result.

**How to actually TEST for this class of bug -- a pre-loaded answers file cannot catch it.** The
regression test must drive stdin itself, live, via a pipe the TEST controls, and assert something
is readable on the far end BEFORE writing anything to stdin -- raw `os.read(fd, n)` with a timed
wait, NOT `subprocess.run(..., capture_output=True)`/`proc.communicate()` (both block until the
whole exchange finishes). Verified both new regression tests
(`tests/test_failfast_probe.py::NoNewlinePromptVisibility`,
`tests/test_exe_smokerun.py::ActivityAwareStop::test_output_with_no_trailing_newline_still_prevents_kill`)
genuinely FAIL pre-fix and PASS post-fix.

**The timed wait itself must NOT be `select.select()` on the pipe object -- confirmed broken on
real Windows CI.** `select.select([fileobj], [], [], timeout)` against a `subprocess.Popen` pipe
passed every local Linux run but failed on 4 separate Windows CI lanes on its first real run:
`OSError: [WinError 10038] An operation was attempted on something that is not a socket`. CPython
`select.select()` on Windows only supports socket objects -- it cannot poll an arbitrary file/pipe
handle the way POSIX can. **Fixed with a background `threading.Thread` doing blocking `os.read()`
into a `queue.Queue`, with the main thread calling `q.get(timeout=N)` instead of `select()`** --
portable, and preserves the same live-timing sensitivity. **Rule: never use `select.select()` on
a `subprocess.Popen` pipe in code that must run on Windows** -- use a reader-thread-plus-queue
instead. A local-sandbox-only pass of a test using `select()` on a pipe is NOT sufficient proof it
will pass on Windows CI (this exact bug passed 8 local runs before shipping and only surfaced on
the first real Windows CI run).

**Rule of thumb for any future async-output consumer in this repo**: prefer chunk/byte-based
reads over line-based reads whenever the producer might write meaningful, already-flushed content
without a trailing newline (an interactive prompt, a progress indicator) -- line-based reads are
only safe when every producer write is guaranteed to end in a newline.

---

## Ambient Python path leakage in uv sub-bootstrap venvs (fixed via `UV_PYTHON_PREFERENCE=only-managed`)

**Isolation-boundary leak in our bootstrapper, NOT a uv defect** -- uv correctly used whatever
ambient interpreter was on the host (PATH/registry/toolchain cache), because nothing told it to
stay inside its own managed toolchain.

**Observed symptom:** in uv-first lanes (`real`, `uv`, `contract-uv`, `contract-uv-fail`),
`uv venv` created `.uv_env` from the GitHub runner's `C:\hostedtoolcache\windows\Python\...`
interpreter (3.12.10 as of 2026-06; historically 3.9.25) instead of the latest managed
CPython. The orchestration layer and its embedded helpers then ran on an older,
ambient Python than intended. Earlier this also surfaced as `self.pyproject.malformed`
failing because a helper assumed `tomllib` (3.11+ stdlib) on an ambient 3.9.x.

**Fix (orchestration layer):** at the very start of the uv acquisition block in
`run_setup.bat` (before the `PVW_UV_EXE` branch and before the first uv invocation):
```bat
set "UV_PYTHON_PREFERENCE=only-managed"
```
This blinds uv to ambient/system/conda interpreters. With no user constraint, uv selects
(downloading if necessary) the latest managed CPython. A user-provided version is still
honored: `runtime.txt`/`pyproject.toml` flows through PYSPEC and is forwarded as
`uv venv --python X.Y` downstream (see `docs/agent-interconnect.md` "uv Coverage Status"
and the REQ-004 forwarding). The `set` lives inside the self-contained bootstrapper -- a
real double-click user has no CI `env:` block, so this is the only thing that protects them;
do NOT move it into `batch-check.yml`.

**Two layers, deliberately decoupled:**
- *Orchestration layer* (the bootstrapper, diagnostics, helper scripts): ALWAYS the latest
  managed CPython. It must not be held hostage by the target app's version constraints.
- *Target layer* (the user's app venv): honors an explicit user `runtime.txt`/`pyproject.toml`
  downstream via `--python`.

**Verification:**
- Runtime proof: `self.uv.managed.interpreter` (`tests/selfapps_envsmoke.ps1`) asserts the
  `.uv_env` base interpreter resides under uv's managed root (`uv python dir`) and matches
  the managed `cpython-<ver>-<os>` naming. It is version-agnostic on purpose (no hardcoded
  version) and skips on the graceful paths (conda-only lane, uv not acquired, uv fell back).
- Config-presence: `uv.python.preference.configured` (`tests/harness.ps1`) statically
  confirms the `set` line exists. This is a configuration check, NOT a runtime assertion --
  the runtime guarantee is the envsmoke row above.

### Embedded-helper Python baseline: target modern, degrade gracefully (syntax vs. feature)

With managed-only orchestration, embedded `HP_*` helpers normally run on the latest managed
CPython. But fallback paths still exist where `HP_PY` can be an older ambient interpreter
(venv-fallback, system-Python consent path, `HP_CI_SKIP_ENV`). So the rule is no longer
"must run on 3.9," but it is NOT "modern only" either:

- **Feature guards are fine.** Modern *stdlib features* (e.g. `tomllib`, 3.11+ modules) MAY
  be used when wrapped in `try/except ImportError` with a working fallback. `HP_PYPROJ_DEPS`
  is the gold standard: it tries `import tomllib`, sets `tomllib = None` on failure, and
  falls back to a regex TOML parser.
  ```python
  try:
      import tomllib
  except ImportError:
      tomllib = None
  ```
- **Core token SYNTAX must stay parse-compatible with older interpreters.** A
  `SyntaxError` is raised at parse/compile time -- BEFORE any `try/except` runs -- so it
  cannot be caught at runtime and produces a hard, ugly crash. Therefore do NOT use
  parse-time-only modern syntax in embedded helpers: no bare `match`/`case` (3.10+), no
  `X | Y` runtime type unions in evaluated positions (use string-literal annotations or
  `typing.Optional`), no other grammar that an older CPython would reject while tokenizing.
- **Net:** target modern CPython; gracefully degrade on older interpreters when feasible;
  never assume a newest-stdlib feature without a fallback; keep the file's syntax loadable
  by the oldest interpreter any fallback path might hand it.

---

## REQ-013 connectivity check needed the REQ-022 retry idiom too -- and a second technique for the in-block case

`:check_net_after_dl_fail` (the REQ-013 "is the host actually offline" probe) did exactly ONE
`ping -n 1 8.8.8.8` and, if that failed, exactly ONE `curl --connect-timeout 5 --max-time 8` to
`conda.anaconda.org` -- zero retries. A single dropped ICMP echo plus a curl connect exceeding 5s
(plausible under shared-runner network contention) is enough to misclassify a genuinely-online
host as offline -- the same transient-single-shot problem REQ-022 already solved for
`:try_conda_create`/`:conda_bulk_install` (detect, wait, retry once), just never applied here.

Fixed by adding a 2-total-attempts retry to both the ping and curl checks, but using **two
different techniques depending on nesting**, because this subroutine has both a top-level check
and an in-block check:

- **Top-level check** (the initial ping/curl, not nested in any parenthesized block): a normal
  `set "HP_CONN_PING_ATTEMPT=0"` + `:label` + `set /a HP_CONN_PING_ATTEMPT+=1` + single-line
  `if %HP_CONN_PING_ATTEMPT% LSS 2 goto :label` counter loop is safe here, because every line is
  freshly parsed at the top level -- no parenthesized block is freezing any `%VAR%` read.
- **In-block check** (the "Y" interactive retry, nested inside `if /I "...=="y" ( ... )`): a
  counter variable would NOT work here -- `set /a`-ing it and then reading it via `if %VAR% LSS 2
  goto` INSIDE the same parenthesized block hits the exact parse-time `%VAR%`-expansion trap
  documented above ("Provider-cascade dispatch is goto-based on purpose"): the whole block is
  read once before any of its `set` statements execute, so the counter read would always see the
  pre-block (0/undefined) value, making the loop condition always true or always false depending
  on how it's written, never the real in-block-incremented count. Fixed instead by literally
  duplicating the ping/curl-and-check pair a second time (2 total attempts spelled out, no
  variable) -- there is nothing to freeze when there is no counter variable at all. **Rule of
  thumb:** inside a parenthesized block, prefer literal duplication over a counter-variable retry
  loop for a small, fixed attempt count (2-3); reserve the counter-loop idiom for top-level code.

---

## Batch / CMD.EXE syntax quirks (the most common source of regressions)

The bootstrapper is a single self-contained `.bat` file, so CMD.EXE parsing rules dominate
the bug surface. `CLAUDE.md` "Common Pitfalls" and "Key Conventions" are the authoritative
list; the recurring traps that have actually bitten us:

- **Parse-time vs. runtime variable expansion.** CMD expands `%VAR%` when it *parses* a
  block, not when it executes each line. Inside a parenthesized `if (...)`/`for (...)` block,
  a `%VAR%` set earlier in the same block still reads its OLD value. (This caused the
  drag-and-drop empty-filename bug: `%MAIN_FILE%` expanded before `set "MAIN_FILE=%~1"` ran.
  Fix: reference the `%~1` parameter directly, or restructure out of the block.)
- **`%%` inside `for` loops.** Loop variables and any literal `%` must be doubled (`%%I`,
  `%%`) inside `for` bodies in a `.bat` file.
- **Special characters need escaping/quoting:** `&`, `|`, `<`, `>`, `^`, `!`, `~`, and `%`
  in values require quoting or `^`-escaping; `%` must be doubled (`%%`).
- **A literal `(`/`)` inside `echo` text is NOT invisible to a parenthesized block's own parser,
  even split across lines -- confirmed as a real shipped regression (PR #408, commit `fd52a3f`).**
  cmd.exe buffers an entire `if (...)`/`for (...)` block by counting `(`/`)` chars in the raw text
  -- no concept of "this paren is just prose." A stray `(` on one `echo` line and its matching `)`
  on the NEXT `echo` line reads as a real block-closing paren the instant the parser reaches it --
  the block ends there, and whatever token follows the `)` gets parsed as a new top-level command
  (`failed was unexpected at this time.` when the next word was "failed"). Broke multiple CI lanes
  simultaneously. `check_delimiters.py` did NOT catch it at the time: a stray `(...)` pair inside
  echo text is individually balanced, so a whole-file LIFO paren-count scan sees nothing wrong --
  the hazard is a cross-line split inside an ALREADY-open block, not a raw count mismatch. **Rule:
  never let a `(`/`)` pair land on different lines inside a parenthesized `.bat` block, even in
  `echo`/prose text.** Keep the pair on one line, avoid literal parens in wrapped prose (prefer
  ` -- ` or `,`), or escape both as `^(`/`^)`. **Gap closed same day**: `check_delimiters.py` now
  flags a `(` opened on an `echo` line, ALREADY nested inside another open bracket, whose matching
  `)` closes on a different line -- scoped to "already nested" so a harmless top-level echo (no
  enclosing block, confirmed against `:print_fastpath_ambiguous_note`) doesn't false-positive.
  Tests: `tests/test_check_delimiters_import.py`'s three `test_paren_*` cases.
- **Avoid `EnableDelayedExpansion`; if unavoidable, wrap it tightly.** `!` becomes special
  under delayed expansion, and a parent shell launched with `/V:ON` causes `!`-collisions.
  `tests/harness.ps1` `batch.bang.scan` enforces "no `!` in live batch code lines."
- **`call "%CONDA_BAT%" ...` for all conda invocations** so the parent batch keeps running
  after conda's own batch returns (a bare invocation can terminate the parent).
- **CMD `set` 8191-character hard limit** -- see the dedicated section below.
- **Line endings:** `.bat`/`.ps1` are CRLF, everything else LF, controlled by
  `.gitattributes` (do not hand-edit). LF-only edits to `.bat`/`.ps1` can fail locally
  before git normalizes them on commit.
- **`:die` uses `exit /b`** (subroutine return, NOT a process halt), so the batch process can
  still exit 0 even after a logical failure, and execution routinely continues past a `call :die`
  line into whatever the enclosing block does next -- check `~bootstrap.status.json` / log
  markers, not just the process exit code, when reasoning about success. **Fixed at the source
  2026-07-22**: `:die` itself now sets `HP_BOOTSTRAP_STATE=error` unconditionally as its first
  action, before its `call :write_status "error" ...` line. Before this fix, only 3 of ~26
  `call :die` sites had a companion `set "HP_BOOTSTRAP_STATE=error"`; the rest could fall through
  (e.g. using a now-broken `HP_PY`) all the way to `:after_cascade_decision`/`:after_env_skip`
  (which unconditionally rewrite the status file from whatever `HP_BOOTSTRAP_STATE` currently
  holds), silently reporting `state=ok` for a genuine failure. Centralizing the set in `:die`
  itself covers every existing AND future call site with one line, rather than requiring each one
  to remember an easy-to-forget companion `set`. Regression coverage:
  `tests/selfapps_pyinstaller_fail.ps1`, `self.embed.fallback.decline`/
  `self.ux.system.gate.real`-style tests asserting `state=='error'`.

**PowerShell adjacent traps:** `-or`/`-and` outside a conditional are parsed as parameter
names ("parameter name 'or'"); `tools/check_delimiters.py` flags these. Multi-line `run:`
PowerShell in YAML interacts badly with quote nesting -- run `actionlint` on changed
workflows.

---

## Windows `move` onto an existing destination: atomic replace for FILES, silent NESTING for DIRECTORIES -- do not assume the same post-check works for both

Requirement 9's swap-verification fix (`:offer_optimized_build`, own section below) established a
correct pattern: for a same-volume FILE `move /y` onto an existing destination, the operation is
atomic (fully replaces, source consumed) or fully fails (both untouched) -- so checking whether
the SOURCE is now gone reliably tells you whether the move succeeded, when the destination itself
existed before the move regardless of outcome.

**That reasoning does NOT carry over to a DIRECTORY move** -- caught when an initial fix mirrored
the file-move pattern onto `:embed_swap_retry`'s directory swap without re-verifying OS semantics
first. A `move` of a directory onto an existing destination silently NESTS the source inside it
(`move srcdir destdir` where `destdir` exists produces `destdir\srcdir\...`, not `destdir`
becoming `srcdir`'s contents) -- neither "check destination" nor "check source gone" detects this
correctly: if a preceding `rd /s /q` fails to fully clear the destination (a lock), the subsequent
`move` nests rather than erroring, so BOTH checks read false-success for different reasons.

**The only reliable fix for a directory swap: verify the PRECONDITION (destination actually
cleared) before attempting the move, not the move's own outcome afterward.** Gate `move` itself on
`if exist "%DEST%" goto :skip_move_this_attempt` right after the `rd`, so `move` only ever runs
onto a confirmed-nonexistent target -- at that point it degenerates to a pure rename (nesting is
structurally impossible), and a post-hoc "does the destination exist now" check becomes trustworthy
again. **Rule of thumb: before reusing a Windows move/swap verification pattern proven for a FILE
on a DIRECTORY (or vice versa), re-derive the semantics for the new case explicitly -- do not
assume the same post-condition check transfers.** `:offer_optimized_build`'s file-swap pattern and
`:embed_swap_retry`'s directory-swap pattern are the two examples of each shape in this repo; if a
third swap site is ever added, classify it as file-vs-directory first before picking a check.

---

## A single trailing backslash before a closing quote silently corrupts a subprocess argument

**Found via a real CI failure** on the REQ-025-family system-directory guard (`self.warn.sysdir`):
`findstr /I /C:"%WINDIR%\" >nul` never matched, even under a script root genuinely under
`%WINDIR%\Temp\...`, despite `HP_SCRIPT_ROOT` being provably correct.

**Root cause: NOT the cmd.exe `%VAR%`-expansion trap -- it's the separate, standard Windows
C-runtime argv-parsing rule** `findstr.exe` (like nearly every native Windows console app)
applies to its own command line after cmd.exe hands it off: N backslashes immediately followed by
`"` collapse to `N/2` literal backslashes, and if N is ODD, the trailing backslash escapes the
quote instead of closing it. `%WINDIR%\"` expands to `C:\Windows\"` -- one (odd) backslash before
the quote, so it doesn't close, and the rest of the line (including `>nul`) gets silently absorbed
into a corrupted, never-matching search pattern. No error, no crash -- the check just quietly
never works.

**Fix: double the trailing backslash** (`%WINDIR%\\"`) -- an EVEN count collapses to one literal
backslash and the quote closes normally, giving the intended search text with the trailing-slash
anchor still preventing a same-prefix false match.

**Rule for ANY future `findstr /C:"...%VAR%..."` (or other native-exe subprocess argument) whose
value can end in a backslash**: never let a `%VAR%`-expanded value that might end in `\` sit
immediately before the closing `"`. Double the trailing backslash defensively, or restructure so
the closing quote is never adjacent to a variable-derived trailing backslash. Different hazard
from cmd.exe's own parse-time `%VAR%` expansion (that's about WHEN substitution happens; this is
about HOW the resulting text is re-parsed by the child process).

**Second real, CI-confirmed instance -- `python.exe`'s own argv, not just `findstr.exe`'s (CLAUDE.md
Item 24, `self.layered_e2e.chain`, cache lane, 2026-08-07).** Confirms this is a genuinely GENERAL
rule about how any native Windows console app's C-runtime startup re-parses its own command line
(`CommandLineToArgvW`-equivalent), not something specific to `findstr`. `run_setup.bat`'s
`:dll_bundle_recover` called `~dll_bundle_scan.py` with `"%HP_PY_DIR%"` (from `%~dpI`, which
ALWAYS ends in exactly one trailing backslash) as the third argument, immediately followed by
another quoted argument (the tried-file path) -- the same odd-backslash-before-quote pattern,
just hitting `python.exe`'s own argv parser instead of `findstr.exe`'s. The single trailing
backslash escaped the closing quote instead of closing it, silently merging `conda_env_dir` with
the next argument into one corrupted string containing a literal embedded `"`. `locate_dll()`
then failed `os.path.isdir()` on that garbage and reported "could not locate a matching file"
**even though the real DLL was genuinely present** -- confirmed directly by downloading the real
`eccodes-2.48.0-h3bec8ca_0` conda-forge win-64 package and inspecting its contents: `eccodes.dll`
sits at exactly `Library\bin\eccodes.dll`, precisely where the (uncorrupted) search would have
found it. Deterministic, not flaky -- `HP_PY_DIR` always ends in one backslash by construction, so
this fired on every single conda-provider run, and is the likely reason `self.layered_e2e.chain`'s
`chainPass` had never been observed `true` in any real CI run despite the mechanism itself being
otherwise correct. **Also plausibly explains `mech3Pass:false`** in the same test run: the
frozen EXE never got past the corrupted-DLL pygrib import to reach colorama's own (deliberately
un-bundled, `importlib`-based) hidden-import gap, so `:hidden_import_recover`'s own strict
`ModuleNotFoundError`-only gate never had a chance to fire on this run -- an `ImportError: DLL
load failed` is a structurally different failure signature it correctly declines to act on (see
"--hidden-import auto-recovery must stay STRICT" above). Fixed the same way: `HP_PY_DIR_ARG`
(`%HP_PY_DIR%` plus one appended backslash, giving an even count) replaces `HP_PY_DIR` at this one
call site. Verified via a faithful Python simulation of the documented `CommandLineToArgvW`
algorithm (`tests/test_dll_bundle_scan.py`'s `HpPyDirArgvQuoting` class) rather than a real
Windows subprocess repro -- Linux's `execve` passes argv as a real array with no command-line
re-tokenizing step, so this specific hazard class cannot be reproduced via a real subprocess on
this sandbox at all; the algorithmic simulation is the closest available live-verification
substitute for a hazard that is Windows-only by construction. **Needs a fresh `cache`-lane
`self.layered_e2e.chain` run to confirm `chainPass:true` for the first time** -- do not assume
this is fully fixed until that real evidence lands.

---

## `:log` echoes UNQUOTED -- never route shell metacharacters through it

`:log` in `run_setup.bat` does `set "MSG=%~1"` then `echo %date% %time% %MSG%` -- the message
is echoed **unquoted**. If `%MSG%` contains a redirection/pipe metacharacter (`<`, `>`, `|`,
`&`), cmd's parser treats it as a redirection/pipe at execution time, corrupting the log line
and/or creating a stray file (e.g. `call :log "...with Python >=3.11..."` would try to write
to a file named `=3.11`).

**Rule:** never pass a value containing `<`/`>`/`|`/`&` into `:log`. If you must surface such
a value, forward it **only** through a tightly double-quoted argument to the actual command
(e.g. `uv venv --python "%HP_UV_PY_REQ%"`) -- double quotes shield those characters from the
redirection parser -- and log a separate **operator-free** display string instead. The
floor-vs-pin change (REQ-004) is the canonical example: `HP_UV_PY_REQ` (may contain `>=`/`<`,
quoted at the uv call site only) vs `HP_UV_PY_DISP` (`X.Y` / `X.Y or newer`, safe for `:log`).

**Deferred tech debt -- do NOT "fix" `:log` with delayed expansion.** A global hardening of
`:log` to swallow metacharacters via `setlocal enabledelayedexpansion` + `echo !MSG!` is
**blocked** by three CI static checks in `tests/harness.ps1`: `batch.delayed.off` (requires
`DisableDelayedExpansion` present), `batch.delayed.enable_absent` (forbids
`EnableDelayedExpansion`), and `batch.bang.scan` (no `!` in live batch lines). Those guards
exist because process-wide delayed expansion previously caused `!`-collision debugging pain.
If a global `:log` fix is ever pursued, it is its own isolated task that must also revisit
those checks -- not a drive-by change.

**Concrete unresolved instance, accepted risk, no action planned: `%HP_ENTRY%`.** `%HP_ENTRY%`
is echoed unquoted at 4 call sites: the raw `echo` alphabetical-fallback hint and the
`[INFO] REQ-002: Picker entry selected:` `:log` call, both inside `:pick_entry_interactive`;
the `[ERROR] REQ-021: entry failed py_compile` `:log` call inside `:preflight_compile`; and the
`[INFO] Launching your program now via the ... interpreter:` `:log` call inside
`:verify_no_exe_probe`. A filename containing `<`/`>`/`&`/`|` would in principle mis-parse as a
redirection/pipe operator here, exactly per the rule above. This requires a
maliciously-or-accidentally-crafted filename delivered via a Windows double-click/drag-and-drop
flow (not a common vector), and the only real fix is the global `:log` rework already documented
as blocked by the three CI static guards above. Noted here so it isn't rediscovered as a "new"
finding later.

**A second, distinct hazard on top of the above: `call :log "..."` triggers cmd.exe's OWN second
expansion pass, so `%`/`^` are just as dangerous as `<`/`>`/`|`/`&` -- found and fixed for the
conda native-DLL bundling loop (CLAUDE.md Item 24), via a CodeRabbit review round.** This is
independent of the UNQUOTED-echo hazard above (which is about `:log`'s OWN `echo %MSG%` line) --
this one is about the CALLER's line, `call :log "... %SOME_VAR% ..."`, itself. `call` is
documented (informally, but extremely well-established in practice) to re-scan its own,
already-substituted command line a SECOND time before invoking the target. Concretely: if
`%SOME_VAR%`'s value happens to CONTAIN text shaped like `%OTHER_VAR%` (not a literal `%OTHER_VAR%`
reference in the source code -- a VALUE that merely looks like one, e.g. captured from external
text such as a build-tool warning message), the caller's own NORMAL single-pass substitution
inserts that literal text into the line first; then, because the command is `call`, a SECOND scan
finds `%OTHER_VAR%` sitting in the now-substituted text and expands IT too -- potentially leaking
an unrelated environment variable (a CI secret, a token) into whatever the call ultimately does
with it (in this case, `:log`'s own console/file output). **Rule: any DISPLAY-ONLY sanitization
built to protect a `call`-based subroutine's own unquoted internals (mirroring the `_SAFE` pattern
above) must ALSO strip `%` and `^`, not just `<`/`>`/`|`/`&`** -- omitting them defeats the whole
point of building the sanitization in the first place, since a value from an untrusted/external
source can just as easily be shaped like `%GITHUB_TOKEN%` as it can contain a raw `&`.

**`set "VAR=%VAR:%%=_%"` (doubling `%` to `%%` in the search text) does NOT reliably strip a
literal percent sign -- a real bug this repo shipped once and caught only via a live-cmd.exe CI
test, not via reasoning.** The doubled-percent form looks like a natural extension of the
well-known FOR-loop `%%i` escaping rule, and was documented here as "the standard, long-established
cmd.exe idiom" on that basis -- but confirmed FALSE via `tests/harness.ps1`'s
`batch.dll_bundle.pct_sanitizer` fixture executed for real on Windows CI: the substitution silently
produced an EMPTY value (`echo` with no argument) instead of the sanitized text. This broke the DLL
native-bundling loop's own sanitization across essentially every CI lane. **Rule: to strip a
literal `%` (or `^`) from a batch variable, do NOT use cmd.exe `:search=replace` substitution --
shell out to PowerShell instead** (`[Environment]::GetEnvironmentVariable('VAR') -replace
'%','_' -replace '\^','_'`, written to a temp file and read back via a plain, non-`call`
`for /f "usebackq delims=" %%X in (...) do set`), which has unambiguous .NET string semantics
instead of cmd.exe's own undocumented parsing quirks. See `docs/agent-interconnect.md`'s "Conda
native-DLL bundling repair loop" section for the concrete fix (`HP_DLL_DETECTED_SAFE`/
`HP_NEXT_DLL_SAFE`/`HP_NEXT_DLL_PATH_SAFE`) and the CI-confirmed failure signature.

**That PowerShell fix ALSO shipped broken, on the exact same fixture's next real Windows run --
a third round of the same underlying lesson.** The replacement text itself, `-replace '%','_'`,
put a lone, unpaired `%` literal into the `-Command` argument -- and that `-Command` argument sat
on the same cmd.exe logical line as a legitimate `%LOG%`/`%TEMP%` reference. **cmd.exe pairs `%`
characters with a left-to-right scan of the ENTIRE line, ignoring quote boundaries** -- it does
not know or care that the lone `%` is "inside a PowerShell string" three quote-levels deep; it
just counts percent signs. The lone `%` paired with `%LOG%`'s own opening `%`, and everything
between them -- the whole real replace logic -- was parsed as one bogus, undefined variable name.
Inside a batch file specifically (not an interactive prompt), an undefined `%VAR%` reference is
silently deleted and replaced with empty text, not left as literal fallback text -- so the entire
PowerShell command was gutted before it ever executed, reproducing the identical `"ECHO is off."`
failure signature as the very bug this fix was meant to close. A sibling block with an EVEN total
`%` count (two lone `%`'s, one per `-replace` call, plus `%LOG%`'s own pair) shows even parity is
NOT sufficient proof of safety: the two lone `%`'s paired with EACH OTHER instead of each correctly
pairing with `%LOG%`, silently deleting an entire intervening `Set-Content` call. **Rule: a
literal, lone `%` must never appear anywhere in PowerShell text embedded in a `-Command` argument
if that same cmd.exe logical line ALSO contains any legitimate `%VAR%` reference** (a redirection
target, `%LOG%`, `%TEMP%`, anything) -- cmd.exe's pairing scan has no concept of "this one is fake,
skip it." Build the percent character entirely inside PowerShell instead: `$pct = [char]37` (or
`[char]0x25`), then `-replace $pct,'_'` -- this removes every literal `%` from the cmd.exe-visible
text, leaving only the genuine, correctly-paired reference. **Verification method that actually
caught this**: after any such fix, count `%` occurrences on the fully-joined (continuation-`^`-
resolved) logical line and confirm the total matches exactly the number of INTENDED pairs -- do not
stop at "the count looks even," trace which characters are meant to pair with which.

**General rule this incident reinforces, for the THIRD time in this exact code path**: when this
repo's own static reasoning about an undocumented cmd.exe parsing rule cannot be settled by citing
an authoritative source, build a live-cmd.exe-executed test fixture (mirroring `tests/harness.ps1`'s
existing pattern) and trust ITS result over another round of reasoning. Static reasoning about
cmd.exe's own `%`-pairing and substitution semantics has now been WRONG three separate times in
this one code path, even after the fixture had already caught the first mistake -- the fixture
itself is what caught the second and third, exactly by design. Do not treat "I fixed the thing the
test caught" as proof the new code is correct; re-run the actual test.

**Closed out via a fourth change: stop trying to write cmd.exe-safe `%`-handling `-Command` text
at all.** After three rounds of getting the exact same class of bug wrong, the actual fix was to
stop fighting cmd.exe's `%`-pairing rules and remove them from the equation entirely -- the
sanitizer moved into a real emitted file, `tools/dll_pct_sanitize.ps1` (`HP_DLL_PCT_SANITIZE`),
invoked via `-File "path" arg1 arg2...` instead of `-Command "..."`. A `-File` invocation's own
script body is never handed to cmd.exe's tokenizer at all -- only the outer invocation line is,
and that's plain argv (env-var names and output file paths), with no `%`-pairing hazard to get
wrong a fourth time. See the "PowerShell helpers: prefer an emitted `.ps1` file..." entry further
below in this file (now covers this as a second, independent trigger condition alongside embedded
`"` characters) and `docs/agent-interconnect.md`'s DLL-bundling section for the full before/after.

---

## Provider-cascade dispatch is goto-based on purpose (parse-time expansion)

`:provider_cascade` (REQ-009/REQ-005.10 slice 3) routes by `HP_ENV_MODE` to one of
`:cascade_from_uv` / `:cascade_from_conda` / `:cascade_from_venv` using **one-line `if /i ...
goto`** statements, not a big parenthesized `if (...)` block. This is deliberate: inside the
`uv -> conda` path we `set "HP_ENV_MODE=conda"` and then `set "ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%"`
and immediately `goto :try_conda_create`. If those were inside a single parenthesized block,
CMD's parse-time `%VAR%` expansion would read the OLD values of any variable set earlier in
the same block (the classic drag-and-drop empty-filename bug). Splitting into goto-reached
labels means each `set`/read happens on a freshly parsed line. **If you refactor the cascade
into nested `( ... )` blocks, re-verify every `%VAR%` you read was not `set` earlier in the
same block** -- prefer keeping the goto-dispatch shape.

**Second confirmed instance (Slice 2b-C, `:try_fast_exe` / `:verify_no_exe_interpreter`):** the
same bug class, `%ERRORLEVEL%` as the frozen variable instead of `%MAIN_FILE%` -- an earlier
revision read `set "HP_SMOKE_RC=%ERRORLEVEL%"` INSIDE the non-interactive `else ( ... )` clause of
an `if defined HP_INTERACTIVE_RUN (...) else (...)` block, freezing silently to whatever
errorlevel preceded the dispatch (almost always `"0"`), so a genuinely broken cached EXE was NEVER
discarded via the non-interactive branch in CI. Fixed the same way: `goto :<label>_probe` instead
of a parenthesized if/else. **Any time a diff wraps a previously-top-level "launch a process, read
`%ERRORLEVEL%`" sequence inside a NEW `if (...) else (...)` block, stop and check whether the read
is safe** -- easy to introduce by accident since it produces no error, only a silently wrong
captured exit code.

Two more cascade gotchas worth remembering:
- `if defined HP_CASCADE_TRIED_UV` / `if not defined CONDA_BAT` are **runtime** checks (safe
  inside blocks); `%HP_CASCADE_TRIED_UV%` / `%CONDA_BAT%` are parse-time (not safe). The
  per-tier no-retry guards use the `if defined` form for exactly this reason.
- `:cascade_acquire_conda` is `call`ed (not `goto`'d) so it returns; it relies on
  `MINICONDA_ROOT`/`CONDA_MAIN`/`CONDA_ALT` already being set near line 410 (they are, even in
  uv-first runs -- only the *install* at line ~423 is gated on `HP_UV_PROVIDING_PYTHON`).
- The cascade `:log` messages say **"uv to conda"**, not "uv -> conda" -- `:log` echoes UNQUOTED,
  so a `>` is parsed as a redirection and silently EATS the log line (and litters a stray file).
  Bit slice 3 for real: the cascade ran correctly on Windows but `self.cascade.exec` failed
  because its phrase-count assertions never matched the swallowed lines. Keep these arrow-free.

---

## A declined/failed fallback tier must clear HP_PY, not just return failure

**Found via the REQ-009 Tier 5 embed-tier tests.** `:try_system_fallback` sets
`HP_PY=%HP_SYS_EXE%` *before* the REQ-014 consent gate (ready to use immediately on accept), but
on EITHER failure exit after that point (missing interpreter, or consent declined) it returned
`exit /b 1` without clearing `HP_PY`. Combined with `:die`'s call-frame-only-return quirk
(execution continues past a `call :die` line), the leaked, non-empty `HP_PY` silently satisfied
`:after_env_mode_selection`'s `if not defined HP_PY (call :die ...)` guard -- the bootstrap then
built and ran using the STALE interpreter path from the declined/failed attempt, silently
reporting `state=ok` SUCCESS out of a scenario where every real provider tier had failed or been
declined. This directly blocked the embed tier from ever being reached when system consent was
declined -- confirmed via `self.embed.fallback.real`'s failure signature: `appRan: true` but every
embed-specific log flag `false`, meaning the app ran via the leaked system Python without embed
ever being attempted.

**Fix**: `:try_system_fallback` now sets `HP_PY=` on both failure exits, immediately before
`exit /b 1`. **Rule for any fallback-tier subroutine that sets `HP_PY` (or any "selected provider"
variable) speculatively before a gate that can still decline**: every failure/decline exit after
that point must clear the variable back to its pre-tier state -- a failed subroutine must leave no
trace of its attempt in shared state, since callers may (and routinely do, via the `:die`-continues
quirk) proceed past a declared failure using whatever is left behind.

**Sibling leak fixed in the same pass:** `:try_venv_fallback`'s `:venv_canary_fail` label had the
identical pattern (`HP_PY` set during venv creation, not cleared if the post-creation canary probe
then fails) -- not hit by either Tier 5 test, but the same failure mode was plausible for a
real-world venv. Fixed with `set "HP_PY="`, mirroring the `:try_system_fallback` fix.

---

## Env-var flags are scaffolding, not intended run paths (REQ-019)

The intended run paths are **double-click and drag-and-drop with no environment variables**.
Every `HP_*` / `PVW_*` variable is test/CI/super-user scaffolding. **No Prime-Directive outcome
may depend on a user setting one**, and the *absence* of a flag must never block a fallback tier
that gets the code running. A flag may ADD diagnostic/CI behavior or a super-user override, or
DISABLE/skip an optional step (so absence == full behavior) -- but an **opt-in flag must never be
the gate for a behavior the Prime Directive needs**.

This bit us with system Python (REQ-009 Tier 4): it was hard-gated behind
`HP_ALLOW_SYSTEM_FALLBACK==1`, a flag the bootstrapper never sets and a double-click user never
sets, so the last-resort tier was unreachable by default and the REQ-014 consent prompt was dead
code for real users -- a silent violation of REQ-009/REQ-014/Prime Directive. Fix: system Python
is now reached in any run, gated solely by the REQ-014 consent prompt;
`HP_ALLOW_SYSTEM_FALLBACK` is deprecated/ignored (mirroring the earlier `HP_ALLOW_VENV_FALLBACK`
deprecation). `HP_FORCE_CONDA_ONLY` (CI conda-diagnostic lane) is a legitimate *suppression* flag
and stays. **When auditing, treat any `if "%HP_...%"=="1"` that ENABLES a Prime-Directive
behavior as a bug; flags should only suppress, divert for tests, or add super-user overrides.**

**Standing directive: re-run this audit whenever a new `HP_*`/`PVW_*` flag is added.** The
system-Python sweep above was the first pass; it also confirmed two other flag families are
correctly scoped as suppression-only (no further action needed unless a future flag changes
their behavior): `HP_OFFLINE_MODE` is auto-set by the REQ-013 connectivity check and never
something a user is required to set, and `HP_SKIP_*` flags only ever *disable* an optional step
(absence == full behavior, never the reverse). Treat this as a checklist item for every new flag,
not a one-time task -- see the "Periodic Maintenance Checks" section of `CLAUDE.md` for the
scheduled cadence this and other recurring reviews are tracked under.

## CI-safe interactive gates: echo the prompt, then resolve the answer

Any `set /p` consent prompt that can be reached on a non-interactive CI path must be made
CI-safe or it hangs (or relies on a fragile stdin EOF). The established pattern (see
`:cascade_consent_gate` and `:system_python_consent_gate`):

1. **Echo the exact prompt string unconditionally** (a plain `echo`, not via `:log`) so prompt
   assertions still see it even when input is skipped. Put real text after the colon-space so the
   asserted substring (`... [y/n]: `) does not rely on a trailing space surviving an editor.
2. Then branch: `if defined HP_TEST_<X>_ANSWER` (deterministic Y/N override, checked FIRST so an
   explicit `Y` can still ACCEPT in CI) `else if defined HP_CI_LANE` (auto-decline, no `set /p`)
   `else` interactive `set /p`.
3. Keep the accept/decline log lines verbatim -- harness static checks and behavioral tests match
   them. For the system gate: `HP_TEST_SYSCON_ANSWER`, with `batch.req014.consent` asserting the
   flag name is present in `run_setup.bat`.

## INVENTORY_B64 E2BIG pattern (publish_index.py)

Passing large data through step env vars (`INVENTORY_B64` was ~168 KB base64) overflows
Linux's `execve` ARG_MAX. Fix: read the same data from a file written to disk by the
inventory step instead of routing it through the process environment. Applied to
`tools/diag/publish_index.py` and `.github/workflows/batch-check.yml`.

General rule: NEVER pass data >32 KB through GitHub Actions step `env:` -- write to a
temp file in `$GITHUB_WORKSPACE` and read from disk instead.

## `download-artifact@v6` `merge-multiple: true` silently overwrites same-named files

**Has bitten this repo twice with the identical root cause.** When a workflow step downloads
MULTIPLE artifacts matching a `pattern:`, and each artifact zips a file with the SAME local
filename (only the artifact's own top-level *name* differs), `merge-multiple: true` extracts
every matched artifact into ONE flat directory -- the local filenames collide, so each subsequent
download silently overwrites the previous one. **Only the last-downloaded artifact's content
survives**, no error/warning/nonzero exit anywhere.

**Confirmed instances (both fixed):**
1. `ndjson-registry-check`'s "Download lane NDJSON artifacts" step: the `--log-dir` cross-check
   reported only 1 observed ID across all 8 lanes instead of 100+. Advisory-only (never affected
   the job's exit code), but degraded the tool's third data source to near-uselessness.
2. `selftest-gate`'s "Download lane verdicts" step: silently limited `has_failures` aggregation to
   whichever single lane survived the collision instead of the OR of all 8 lanes. Lower severity
   than it sounds -- `has_failures` only feeds `model-quick-fix`'s auto-fix trigger, not PR merge
   gating (that's independent, via each matrix job's own GitHub check conclusion) -- but could
   cause the auto-fix bot to skip a fix when a non-surviving lane genuinely had failures.

**The fix is the same in both cases and is the correct default: drop `merge-multiple` entirely.**
Without it, `download-artifact@v6` places each matched artifact into its own
`<path>/<artifact-name>/` subdirectory, so no collision is possible. Every consumer in this repo
that reads the downloaded files already does so via `Get-ChildItem -Recurse` / `Path.rglob` /
equivalent, so removing `merge-multiple` requires no other code change -- the recursive read
already looks inside per-artifact subdirectories.

**When `merge-multiple: true` IS actually safe (confirmed present, unfixed, correctly so):**
`batch-check.yml`'s "Download iterate logs artifact" step (`publish_diag` job) downloads a
single artifact by exact `name:`, not a `pattern:` matching several -- there is only ever one
artifact in play, so no collision is possible regardless of the flag.

**Audit method for future additions:** before setting `merge-multiple: true` on any
`download-artifact@v6` step that uses `pattern:` (matches more than one artifact), trace the
matching `upload-artifact@v6` step(s) and check whether the uploaded `path:` is the same local
filename across all matched artifacts. If yes, either drop `merge-multiple` (preferred -- almost
always safe, since consuming code should already handle nested subdirectories) or give each
upload a distinct filename. Do not add `merge-multiple: true` to a new multi-artifact download
step without doing this check first.

---

## Heuristic dep-augmentation (HP_PREP_REQUIREMENTS): pandas[excel] extras syntax

The `names_lower` list is built from `pip_specs` by splitting at version specifier chars
and lowercasing. The original code did NOT strip pip extras (`[excel]`) before the lookup,
so `pandas[excel]` was stored as `"pandas[excel]"` in `names_lower` and the check
`'pandas' in names_lower` returned `False`.

**Fix applied (2026-06-21):** Strip `[...]` from each name before lowercasing:
```python
names_lower = [re.sub(r"\[.*?\]", "", re.split(r"[<>=!~,\s]", value, maxsplit=1)[0]).strip().lower() for value in pip_specs]
```

Covered by `tests/test_heuristics.py::TestPandas::test_pandas_extras_triggers`.

The fix is load-bearing for the primary use case: users who copy `pandas[excel]` from
modern documentation into requirements.txt now get openpyxl and xlsxwriter injected.

---

## Pre-build `--collect-submodules` must be DOUBLE-gated (used AND installed), never installed-only

`HP_COLLECT_SUBMODULES` (`~collect_submodules.py`) emits `--collect-submodules=PKG` flags for a
curated set (sklearn, matplotlib, scipy, plotly) whose submodules load via dynamic dispatch that
PyInstaller's static analysis cannot trace -- the warn file stays silent, so warnfix never repairs
them and the frozen EXE fails at runtime on the un-bundled submodule.

**The gate is deliberately on USED-by-source AND INSTALLED, not on installed alone.** Gating on
"installed" (a bare `find_spec`) would make every EXE bundle hundreds of MB of an unused library
merely because it sits in a fat global/conda env -- a `print("hello")` script would ship all of
scikit-learn. Gating on "used" alone could emit a flag for a package that is imported but absent,
which makes PyInstaller error out. **Do NOT "simplify" this to a single gate.** The double-gate is
the whole point; `tests/test_collect_submodules.py::GatingMatrix` locks both halves.

Two more details a future agent must preserve:
- The curated set uses IMPORT names (`sklearn`, not `scikit-learn`) because `--collect-submodules`
  takes the importable module name AND because matching the import name against project source
  avoids the package-vs-import naming mismatch. Keep the set conservative -- heavy stacks
  (torch/tensorflow/transformers) are excluded on purpose (gigabyte EXEs).
- `HP_PYI_COLLECT` is computed in the `:compute_collect_flags` SUBROUTINE and set BEFORE the
  `if "%HP_ENV_MODE%"=="system" (...) else (...)` build block, exactly like `HP_PYI_EXPAT`. If you
  move the computation inside that parenthesized block, `%HP_PYI_COLLECT%` in the build command will
  parse-time-expand to its OLD (empty) value (the classic drag-and-drop trap). The walk reuses the
  `~detect_visa.py` pattern (skip `~`/`.`-prefixed dirs) and AST-parses with a per-file regex
  fallback so a single un-parseable user file does not blind the scan.

---

## --hidden-import auto-recovery must stay STRICT (ModuleNotFoundError + installed), never broaden to ImportError

`:hidden_import_recover` (REQ-016 Slice 2) re-runs a failed frozen EXE, and via
`~hidden_import_scan.py` (`HP_HIDDEN_IMPORT_SCAN`) decides the next `--hidden-import` target.
It is deliberately gated on TWO conditions and it is a mistake to relax either:

1. **`ModuleNotFoundError: No module named 'X'` only -- NOT a bare `ImportError`.**
   For `ModuleNotFoundError`, X *is* the exact `--hidden-import` target (its code is simply not
   in the bundle). For `ImportError: cannot import name 'Y' from 'Z'`, Z is **already bundled**
   and Y is an *attribute*, not a module -- so **no `--hidden-import` target is derivable** and a
   rebuild cannot fix it. Broadening to ImportError would burn the 3 rebuild cycles and hand back
   the same error. The genuine packaging case behind some ImportErrors (a dynamic
   `except ImportError: from ._fallback import ...` where the fallback was not collected) is
   `--collect-submodules`/`--collect-all` territory (Slice 1 / a future Slice 3), **not** the
   hidden-import token extractor.
2. **X must be installed in the build interpreter (`find_spec`).** This is what makes a user typo
   `import nonexistant` cost **ZERO rebuilds** -- the typo'd module is not installed, so the helper
   emits nothing and the failure routes straight to the post-flight hints. It also excludes a
   genuinely-missing dependency (warnfix's job, not this loop's).
3. **`dist\<env>.exe` must have been built by PyInstaller, not Nuitka (AV-Safe Build Path Tier A,
   `HP_NUITKA_FALLBACK_USED`).** Added when Tier A shipped -- see
   `docs/agent-interconnect.md`'s "Tier A and hidden-import auto-recovery" section for the full
   interaction and the fix. The loop's only repair mechanism is `--hidden-import`, a
   PyInstaller-specific flag; it does nothing useful against a Nuitka-built EXE and risks
   rebuilding via the wrong tool.

No-loop guarantee: the helper takes an already-tried list and the batch caps at 3 iterations, so
a pathological "different missing module every rebuild" app stops at 3 and a "same module repeats"
app stops after 1. The loop only re-runs the EXE when the *initial* smoke returned a real fast
non-zero exit (not `-1`); a `-1` is a timeout/hang, and re-running a hung EXE in the loop would
hang too, so recovery is skipped for it.

Two batch hazards a future agent must preserve:
- `:hidden_import_recover` is **goto-based, not a parenthesized block**, so each `%HP_HIDDEN_ITER%`
  / `%HP_PYI_HIDDEN_IMPORTS%` reads its runtime value. `set /a HP_HIDDEN_ITER+=1` then
  `if %HP_HIDDEN_ITER% GEQ 3 ...` only works because they are separate lines re-parsed per goto.
- Recovery rebuilds recreate `<ENVNAME>.spec` and `build\<ENVNAME>\` **after** the main-build
  cleanup already ran, so the subroutine cleans them up itself and re-snapshots spec pre-existence
  (`HP_HID_SPEC_PRE`) at entry to avoid clobbering a user's committed `.spec`.

**Test interaction (caught in CI run 28307675855):** any XFAIL test that builds an EXE which fails
on a `ModuleNotFoundError` for an **installed** module is now **auto-recovered** by this loop and
will XPASS. `selfapps_exedyn_fail.ps1` originally dynamically imported colorama (installed) expecting
permanent failure; it was repurposed to import a **non-installed** module so recovery's find_spec
gate correctly declines and the graceful-failure path is still covered (the recover-success case is
covered positively by `selfapps_hidden_import.ps1`). `selfapps_exefail.ps1` (static `import
nonexistent_module`, not installed) and `selfapps_exedata_fail.ps1` (FileNotFoundError, not a MNFE)
are unaffected -- recovery declines for both. When adding a new EXE-failure xfail test, use a
not-installed module or a non-MNFE failure so recovery cannot heal it.

---

## CMD.EXE 8191-Character Line Limit for HP_* Payloads

**Critical: every `set "HP_VARNAME=..."` line in run_setup.bat must stay under 8191 total characters.**

CMD.EXE enforces a hard 8191-character line limit for `set` commands. Exceeding this causes
CMD.EXE to crash with exit code `-1073740791` (`0xC0000409` = `STATUS_STACK_BUFFER_OVERRUN`).
The crash is silent and hard to diagnose: `bootstrap.log` will contain only 1-3 early lines
(the UNC-path warning and any REQ-015 lines), and the CI job completes in ~1 second.

**Budget calculation per payload:**
- `set "HP_VARNAME=` prefix = varies (22-26 chars depending on var name)
- `"` suffix = 1 char
- Max b64 content = 8191 - prefix_len - 1

| Payload var | Prefix chars | Max b64 chars | Current b64 | Safety margin |
|-------------|-------------|---------------|-------------|---------------|
| HP_PREP_REQUIREMENTS | 26 | 8165 | 7972 | 192 |
| HP_COLLECT_SUBMODULES | 27 | 8163 | 7704 | 459 |
| HP_HIDDEN_IMPORT_SCAN | 27 | 8163 | 5216 | 2947 |
| HP_DEP_CHECK | 18 | 8173 | 3244 | 4928 |
| HP_ENV_STATE | 18 | 8173 | 3280 | 4892 |
| HP_PYPROJ_DEPS | 20 | 8171 | 2868 | 5302 |

**HP_PREP_REQUIREMENTS is the tightest** because it encodes the largest helper
(HP_COLLECT_SUBMODULES is the second-tightest at 459).
The 192-char safety margin is narrow. Before expanding the payload, verify b64 length:
```python
import base64
b64 = base64.b64encode(open('helper.py', 'rb').read()).decode('ascii')
line_len = len('set "HP_PREP_REQUIREMENTS=') + len(b64) + 1  # +1 for closing " (prefix=26)
print(f"b64={len(b64)}, line={line_len}, margin={8191-line_len}")
assert line_len <= 8191, f"CMD line limit exceeded by {line_len-8191} chars!"
```

**Crash diagnosis checklist:**
1. bootstrap.log has only 1-3 lines (not the usual 50+ lines)
2. CI job runtime is ~1s (not the usual 5-15 min)
3. `exit code -1073740791` or `0xC0000409` in CI step output
4. Failure happens at `call :define_helper_payloads` (line ~188 of run_setup.bat)
5. Run `python -c "line = open('run_setup.bat').read().split('\n'); [print(i, len(l), l[:60]) for i, l in enumerate(line) if len(l) > 8190]"` to find offending lines

**Occurred in commit `23c1ed9`:** Adding `strip_extras()` function to HP_PREP_REQUIREMENTS
pushed the line to 8215 chars. Fixed in `d8f313c` by removing the redundant function
(NAME_PATTERN already stops at `[`, so `strip_extras()` was a no-op).

---

## Embedded Helper Update Workflow

**Preferred method (has a canonical `tools/` source, the common case -- 12 of 16 payloads
as of 2026-07): edit the source file, then run `tools/sync_payload.py`.** This is now the
required method for any payload with a canonical source -- do not hand-roll the
read/re-encode/splice/write sequence below for these; `tools/sync_payload.py` was written
specifically to eliminate the risk class described in "Never open a real source file in
Python 'w' mode as part of a 'dry run'" above (a careless one-off script truncated
`run_setup.bat` to zero bytes doing this by hand).
```bash
# 1. Edit the canonical source (e.g. tools/pyproj_deps.py) directly.
# 2. Re-sync the embedded payload -- reads run_setup.bat as bytes, verifies EXACTLY the
#    target line changes, checks the CMD 8191-char budget, and only then writes:
python tools/sync_payload.py HP_PYPROJ_DEPS tools/pyproj_deps.py
# 3. Verify without writing (e.g. to check a claim before touching anything):
python tools/sync_payload.py HP_PYPROJ_DEPS tools/pyproj_deps.py --check
```
Then run `python tools/check_delimiters.py run_setup.bat` and the payload's own
`PayloadSync` unit test (e.g. `python -m pytest tests/test_pyproj_deps.py -k PayloadSync`).

**No canonical source yet (a shrinking minority -- see AGENTS.md's embedded payload
inventory table):** decode to a scratch file, edit that, then still hand it to
`tools/sync_payload.py` for the actual write -- never open `run_setup.bat` in write mode by hand.
```python
import base64, re
with open('run_setup.bat', 'r', encoding='ascii', errors='ignore') as f:
    for line in f:
        m = re.match(r'^set "HP_VARNAME=(.*)"$', line.rstrip('\r\n'))
        if m:
            open('/tmp/decoded_helper.py', 'w').write(base64.b64decode(m.group(1)).decode('ascii'))
            break
```
Edit `/tmp/decoded_helper.py`, then:
```bash
python tools/sync_payload.py HP_VARNAME /tmp/decoded_helper.py
python tools/check_delimiters.py run_setup.bat
```

**PayloadSync tests for a `.ps1` (or any `eol=crlf`-attributed) canonical source must normalize
CRLF/LF before comparing bytes, or the test passes locally and fails only on real Windows CI.**
`.py`/`.sh` sources are `eol=lf` (no checkout-time translation, safe to `read_bytes()` and compare
raw). `.ps1`/`.bat`/`.cmd`/`.psm1`/`.psd1` are `eol=crlf` -- `actions/checkout@v5` on Windows CI
materializes CRLF regardless of what the payload was encoded from (e.g. LF on a Linux dev
sandbox), so a raw byte comparison mismatches even though the content is logically identical (the
base64 string itself is immune -- no `\r`/`\n` inside it -- and the runtime-extracted script
parses fine either way; this is a test-assertion bug only). Fix: `.replace(b"\r\n", b"\n")` on
both sides before `assertEqual`.

**Python baseline reminder:** see "Embedded-helper Python baseline" above (target modern CPython,
guard modern stdlib features with `try/except`, keep syntax parse-compatible with older
interpreters) -- same rule applies to every embedded helper, not just the uv-managed-only case.

**PowerShell helpers: prefer an emitted `.ps1` file over inline `-Command "..."` the moment the
body needs ANY literal `"` character anywhere** (interpolation, nested quoting, here-strings, or
quoting a `ProcessStartInfo.Arguments` value like `'"' + $rawArgs + '"'`) -- cmd.exe's naive
quote-toggle tokenizer has no concept of "this quote is inside a single-quoted PowerShell string,"
so a literal `"` anywhere in the command text breaks its parsing of the `-Command` argument,
regardless of whether it came from interpolation or plain concatenation. A real `.ps1` file (via
the existing `:emit_from_base64` mechanism) has no such exposure. This is why `HP_FAILFAST_PROBE`
became an emitted file instead of an inline one-liner.

**Second, independent trigger condition for the same rule: a literal `%` anywhere in `-Command`
text, even with zero `"` characters involved.** The DLL-bundling `%`/`^` sanitizer (CLAUDE.md
Item 24) went through THREE separate real-CI-confirmed bugs while it stayed inline `-Command`
text (see `docs/agent-interconnect.md`'s "Conda native-DLL bundling repair loop" section for the
full trace) -- cmd.exe pairs `%` characters via a left-to-right scan of the ENTIRE logical line,
with zero awareness of PowerShell's own quoting, so a literal `%` inside `-Command` text sharing a
cmd.exe line with any real `%VAR%` reference (`%LOG%`, `%TEMP%`, etc.) can silently corrupt that
reference's pairing -- an entirely separate failure mode from the `"`-breaks-tokenizing rule above,
with its own history of getting "fixed" wrong twice before landing on the actual fix. Eventually
converted to `tools/dll_pct_sanitize.ps1`, a real emitted file (env-var names and output paths
passed as plain argv, never interpolated into `-Command` text) -- this closes the bug class
structurally, the same way `HP_FAILFAST_PROBE` closed the `"`-tokenizing class above. **Rule of
thumb going forward: the moment a PowerShell one-liner needs to build or contain a literal `%`
(not just read an existing `%VAR%` the CALLER already substituted), stop and use `-File` instead
of reasoning through cmd.exe's pairing behavior again** -- that reasoning has now been wrong three
times in a row in this exact code path, each only caught by a live-cmd.exe CI test built for the
purpose, never by review or local `pwsh` testing.

**Prefer raw .NET types over Utility-module cmdlets (`Get-FileHash`, `Expand-Archive`,
`Get-Content`, `Set-Content`, `Get-Date`) in embedded `.ps1` helpers invoked from a `for /f`
backtick subshell -- module auto-loading is not guaranteed there on Windows PowerShell 5.1, and
this cannot be caught by local `pwsh` testing.** `tools/embed_extract.ps1` used `Get-FileHash`,
tested fine under `pwsh` (PowerShell 7, Linux), then failed on every real Windows CI run:
`'Get-FileHash' is not recognized as the name of a cmdlet...` -- `Microsoft.PowerShell.Utility`
genuinely did not auto-load in that specific `for /f "..." in (\`powershell ... -File ...\`)`
invocation shape. `Microsoft.PowerShell.Management` cmdlets (`Test-Path`/`Get-Item`) worked fine
in the same run, so this is scoped to `Utility` specifically. `pwsh` never reproduces it (different
module discovery behavior) -- **only real Windows PowerShell 5.1 CI catches this class of bug**.
Fix: `[System.Security.Cryptography.SHA256]::Create()`/`OpenRead()` instead of `Get-FileHash`,
`[System.IO.Compression.ZipFile]::ExtractToDirectory()` instead of `Expand-Archive`,
`[System.IO.File]::ReadAllText()`/`WriteAllText()` instead of `Get-Content`/`Set-Content`,
`[datetime]::Now` instead of `Get-Date` (easy to overlook -- same module as the others, so a
partial fix that missed it would still fail identically). Applied defensively to a second,
pre-existing `for /f`-backtick-subshell site with the same topology (`:conda_base_update`'s
timestamp check) even though it was never confirmed broken in CI (masked by a `try/catch`) --
any future embedded `.ps1` helper reached via this pattern should default to .NET types from the
start.

**A second, independent bug hid behind the first, found only after diagnostics were added:** once
`Get-FileHash` was replaced, extraction succeeded but the embeddable zip's `._pth` site-imports
patch silently didn't apply -- `-replace '^#import site$', 'import site'` never matched, because
`._pth` uses CRLF and .NET regex `$` in multiline mode matches before `\n`, not before `\r\n` (the
literal `\r` sits between `site` and the match position). Fixed by widening to
`'(?m)^#import site\r?$'`. Same general CRLF-vs-`$`-anchor hazard as the PayloadSync note above,
but at *runtime* instead of test-time -- check any `^`/`$` regex anchor applied to file content
that might carry Windows line endings.

**Fail-fast probe window vs. the ~30s hard-kill cap are unrelated numbers, do not conflate them:**
`HP_FAILFAST_PROBE_MS` (default 10000ms, `:run_failfast_probe`) is a CLASSIFICATION checkpoint --
how long to wait before deciding "this exited fast, treat a non-zero rc as a stale artifact" vs.
"this is still running, treat it as the user's real program and never touch it again." The ~30s cap
used by `:run_exe_smokerun`/`:hidden_import_recover` is a FORCE-KILL CEILING for the fresh-build
verification run (`~exe_smokerun.ps1`, `HP_SMOKERUN_KILL_MS`, activity-aware -- see "Activity-aware
EXE-smoke kill" in `docs/agent-interconnect.md`). The probe's second wait stage (`$p.WaitForExit()`,
no argument) is genuinely unbounded and never kills anything -- raising or lowering the probe window
only changes how quickly a broken cached EXE gets discarded+rebuilt, it never introduces a new kill
point.

**A third bounded-launch helper exists, with a DIFFERENT kill philosophy from the two above --
`~exe_hint_rerun.ps1` (`HP_EXE_HINT_RERUN`, `:exe_smokerun_hints`, closes former Active Backlog
item 15).** Unlike `~exe_smokerun.ps1`/`~failfast_probe.ps1` (activity-aware: any output before the
deadline skips the kill, since those cover a REAL run worth waiting on), this helper kills
UNCONDITIONALLY at its deadline (default `HP_HINT_RERUN_KILL_MS=10000`, test-only override) --
it exists purely to capture a bounded stdout+stderr snapshot for stderr pattern-matching
(`ModuleNotFoundError`/`FileNotFoundError` signatures), never shown live to the user, so partial
output on a hang is fine and strictly preferred over letting a diagnostic-only re-run hang the
whole bootstrap a second time. Before this fix, `:exe_smokerun_hints` did a plain, untimed
`"%ENVNAME%.exe" > "~exe_out.txt" 2>&1` -- the one user-code launch point in this file with no
timeout at all, on the theory that a genuine ModuleNotFoundError/FileNotFoundError always exits
immediately. That theory holds for the ORIGINAL failure (already classified as fast/real/non-hang
by the primary verification), but this is a FRESH re-run of the same binary; any non-determinism
could hang it. Regression tests: `tests/test_exe_hint_rerun.py` (`UnconditionalKill` class
specifically proves a process that prints once and then hangs is STILL killed -- the defining
behavioral difference from the other two helpers). **`Process.Kill()` alone only terminates the
tracked process, not its descendants** -- a spawned child inheriting the redirected pipe can keep
it open after the parent is killed, hanging an unbounded `ReadToEndAsync().Result` forever. Fixed
via `taskkill /F /T /PID` (process-tree kill; Windows PowerShell 5.1's .NET Framework has no
`Process.Kill(entireProcessTree)` overload, that's .NET 5+ only) PLUS an independent bounded final
read (`Task.Wait($drainMs)`, 5000ms) as a second safety net. The `taskkill /T` half is NOT
CI-confirmed (no Windows environment available to construct a genuine repro); the drain-wait
fallback IS verified (`ProcessTreeAndDrainTimeout` test, a grandchild-inherits-the-pipe scenario).

**First real CI evidence, 2026-08-07 -- THREE occurrences of the same mechanism across three
separate runner VMs in one real Windows CI run, escalating from "watch for recurrence" to a
confirmed, fixed bug.** `UnconditionalKill::test_hang_after_output_is_ALSO_killed_unlike_exe_
smokerun` failed on 3 of 8 lanes on a commit that touched neither this test file nor
`tools/exe_hint_rerun.ps1` (confirmed via `git log`/`git diff origin/main` showing zero changes to
either since PR #410) -- the other 5 lanes passed the identical suite on the identical commit:
- `contract-uv` (non-gating): a hard `subprocess.TimeoutExpired` after the test's own 60s outer
  budget, waiting on a real `pwsh.EXE ... tools/exe_hint_rerun.ps1` child -- the kill never
  completed in time.
- `uv` (non-gating): `AssertionError: 50.641... not less than 45` -- the kill DID eventually
  complete, just past the test's own 45s inner assertion.
- `real` (**GATING**): `AssertionError: 48.437... not less than 45` -- the identical failure
  signature as `uv`, now on a lane that blocks PR merges. This is what escalated the issue from a
  documentation note to an actual fix: three occurrences across independent runner VMs, all
  showing the SAME direction of slowness (kill eventually succeeds, just 40-60s late against a
  500ms test deadline), is a real pattern, not noise -- and once it hit a gating lane it could no
  longer be deferred.
- The other gating lane (`conda-full`) and 4 more non-gating lanes passed clean on the same commit.

**Root cause identified and fixed the same day, without a Windows repro environment, by bounding
every previously-unbounded wait in the kill path.** `~exe_hint_rerun.ps1`'s post-kill sequence had
TWO calls with no timeout at all: the blocking `& taskkill.exe /F /T /PID $p.Id` invocation itself
(a synchronous native-command call with no way to bound it via the `&` operator), and the trailing
`$p.WaitForExit()` (no argument) right after it. Either one stalling under shared-runner
contention -- CPU/disk contention, or Windows Defender scanning a freshly-terminated process tree,
neither confirmed since no Windows host was available to instrument directly -- would fully explain
all three observed signatures (a slow-but-eventually-successful kill, or a kill so slow it blew
past even a 60s outer budget). Rather than guess which single call was the culprit, BOTH are now
bounded: `taskkill.exe` is launched via its own `System.Diagnostics.Process` object with a 5000ms
`WaitForExit`, and the trailing `$p.WaitForExit()` after the kill attempt is now
`$p.WaitForExit($drainMs)` (also 5000ms) instead of unbounded. `$p` has already been sent `/F /T`
plus a direct `Kill()` by the time either bound is reached, so a slow confirmation now just means
"stop waiting," never "the process might still be alive and unaddressed." All 8
`tests/test_exe_hint_rerun.py` tests (including `PayloadSync`) pass locally post-fix.
**Confirmed against the real slowness on BOTH gating lanes** (commit `f106f78`, run
`31196980168`): `real` (job `92928320716`) and `conda-full` (job `92928320698`) both came back
`conclusion: success`, full pytest suite included -- the same runner-contention class did not
recur on either lane's re-run. Closed as CLAUDE.md Active Backlog Item 27, moved to
`docs/agent-closed-backlog.md`.

**Why the default is 10000ms, not 5000ms (widened 2026-07):** the original 5000ms default was
tuned assuming the probe window only needs to outlast a failing process's own error handling
(instant -- an unhandled exception unwinds in microseconds). It does not: a PyInstaller *onefile*
EXE must first extract its bundled runtime to a temp directory and boot an embedded interpreter
before ANY user code (or its failure) can run at all, and that cold-start step alone is commonly
1-3+ seconds even on an idle machine. Confirmed as the real cause via a CI flake in
`self.failfast.probe.fastfail` (a test whose whole design is a reliably-fast-failing frozen EXE):
identical code produced `discardedAndRebuilt: true` on one CI run and `discardedAndRebuilt: false`
on the very next run of the same commit, with no code change between them -- a pure timing race
between cold-start-plus-failure and the classification window, worsened by a shared CI runner's
CPU/disk contention or a Defender on-access scan of the freshly-extracted EXE/DLLs. Widening the
window is unconditionally safe to do liberally: it is a classification-only value (see above --
never a kill point), so the only cost of widening it is a few extra seconds before a genuinely
broken cached EXE is recognized and rebuilt.

**Accepted gap: most `selfapps_*.ps1` files do not locally pin `HP_CI_LANE`/`HP_NONINTERACTIVE`
around their `run_setup.bat` invocations, so a LOCAL (non-CI) run of one that reaches the fast-path
reuse or no-EXE interpreter dispatch point would take the new interactive fail-fast-probe branch
instead of the plain/legacy branch.** This is a deliberate, low-priority trade-off, not an oversight:
real CI always sets `HP_CI_LANE` at the GitHub Actions job level (`batch-check.yml`,
`HP_CI_LANE: ${{ matrix.mode }}`), and every subprocess (including a PS test script's own
`cmd /c run_setup.bat` child) inherits it automatically -- so CI determinism for `self.fastpath` /
`self.exe.fastpath.graceful` / envsmoke's fast-path assertions is unaffected regardless of what any
individual test file does. Only `tests/selfapps_sysbuild.ps1`, `tests/selfapps_ux_hardening.ps1`,
and the new `tests/selfapps_failfast_probe.ps1` explicitly set `$env:HP_CI_LANE` locally (needed
because those specifically drive consent gates / force the new branch on purpose). If a future
agent wants full local-dev parity with CI for the remaining files, add the same
save/set/restore-`HP_CI_LANE` pattern to whichever ones are found to actually reach the dispatch
point (most single-build-run tests never reach it at all, since `:try_fast_exe` returns immediately
when no cached EXE exists yet) -- but this is optional polish, not a correctness requirement.

---

## `cache` lane Miniconda-corruption handling lives only in `batch-check.yml` YAML comments

The `cache` CI lane restores a Miniconda install from a GitHub Actions cache to skip the ~99 MB
download/install on every run. This mechanism has its own self-healing logic that is easy to miss
because it's documented nowhere except inline YAML comments in `.github/workflows/batch-check.yml`
-- a future agent debugging "why did the cache lane skip everything" should read this instead of
re-deriving it from the workflow file. **Item 19 (`docs/agent-closed-backlog.md`) closed the
former self-perpetuating-corruption trap here**: a `restore-keys` PREFIX match that's corrupted
now gets the stale `Miniconda3` directory deleted (falling through to a genuine fresh install)
instead of the old unconditional skip-this-run behavior; an EXACT primary-key hit that's corrupted
still skips (that narrower case needs an explicit cache-deletion API call, not yet implemented).

**Cache key includes the pipreqs version, not just a source hash** (`batch-check.yml:85-87`):
```yaml
key: win-${{ runner.os }}-py311b-conda-${{ hashFiles('run_setup.bat') }}-${{ steps.extract_version.outputs.pipreqs_version }}
restore-keys: |
  win-${{ runner.os }}-py311b-conda-
```
`hashFiles('run_setup.bat')` busts the cache automatically on any bootstrapper edit (no manual
cache-bust needed for source changes); the `pipreqs_version` suffix (extracted via regex from the
`HP_PIPREQS_VERSION` default-assignment line, `batch-check.yml:62-77`) additionally busts it if the
pin ever changes. The `restore-keys` prefix fallback means a stale/partial-match cache can still be
restored even when the primary key misses.

**Three-layer anti-corruption chain, all keyed on a single `HP_CACHE_CORRUPTED` env flag:**
1. *Health check on restore* (`batch-check.yml:89-108`, "Validate restored conda binary"): runs
   `conda.bat info`; on failure, sets `HP_CACHE_CORRUPTED=1` via `GITHUB_ENV` and logs
   `::warning::Conda binary health check failed...; cache corrupted.` The step deliberately
   `exit 0`s regardless ("health check is informational; never fail this step") so a corrupt cache
   doesn't crash the job outright.
2. *Bootstrap-failure fallback* (`batch-check.yml:248-258`, "Catch cache lane bootstrap failure"):
   if `run_setup.bat` itself fails in the cache lane (even with a healthy-looking cache), this ALSO
   sets `HP_CACHE_CORRUPTED=1`.
3. *Skip path*: when `HP_CACHE_CORRUPTED=1` (from either trigger above), later steps write
   placeholder NDJSON rows (`self.cache.corrupted` / `self.cache.bootstrap.failed`, both marked
   `"pass":true`) and skip the rest of the self-test battery for that run -- treating the condition
   as an infrastructure issue, not a product regression. Most subsequent steps are guarded by
   `if: ${{ env.HP_CACHE_CORRUPTED != '1' }}`.

**Save-side guard prevents a "rolling corruption factory"** (`batch-check.yml:1485-1509`): "Validate
Miniconda before cache save" and "Save Miniconda cache" both additionally require
`HP_CACHE_CORRUPTED != '1'` (plus a fresh `conda.bat` presence/health check of their own). This
means a corrupted cache is **never re-saved** -- corruption cannot compound run over run, and the
next run's `restore-keys` fallback will eventually pick up a healthy cache from before the
corruption was introduced (or fall through to a fresh install if none exists).

If you touch any of `batch-check.yml`'s cache-lane steps, preserve this chain: the health check
must stay non-fatal (`exit 0`), `HP_CACHE_CORRUPTED` must gate both the skip-path steps and the
save step, and the cache key must keep including a value that changes whenever the *content* the
cache is keyed on (Miniconda install driven by `run_setup.bat` + the pinned pipreqs version) could
have changed.

---

## Pre-flight py_compile cost on the fast path (accepted, by design)

`:preflight_compile` (REQ-021, run_setup.bat) runs unconditionally on every `:run_entry_smoke`
invocation, including runs that will subsequently take the cached-EXE fast path -- it is not
skipped or gated on `HP_FASTPATH_USED`. This is intentional, not an oversight: it catches an
entry `SyntaxError` before a doomed PyInstaller build even when the cached EXE is about to be
reused. Cost is negligible (single-file byte-compile, ~50ms) relative to the fast path's overall
savings. No action needed; recorded here so it isn't re-flagged as a "missing optimization" later.

---

## `uv add --script` / PEP 723 empirical behavior (shared foundation for two features)

Two features persist resolved dependencies into a script's PEP 723 header via `uv add --script`:
the automatic `run_setup.bat`-integrated one (`docs/plan-pep723-writeback.md`) and the manual "PVW
QuickStart" one (`docs/plan-pvw-quickstart.md`, README's "PVW QuickStart" section). Both rely on
the same empirically-confirmed (never assumed from docs) `uv` behavior, consolidated here once --
each plan doc points back here instead of re-deriving these facts.

- **`uv add --script` performs a genuine targeted merge, not a rewrite.** Re-adding an
  already-pinned package by its bare name does not downgrade the pin (confirmed: `flask>=2.0`
  survived a bare `flask` re-add byte-for-byte). Adding a mix of already-pinned and genuinely new
  packages in one call preserves every existing pin and adds only the new ones (as bare names, or
  on newer `uv`, an auto-resolved lower bound -- see the version-drift note below). A hand-added
  custom TOML key outside `dependencies`/`requires-python` survives untouched. This is what lets
  both features skip building a hand-rolled TOML differ/merger: feed the full current dependency
  list to `uv add --script` every time and let `uv`'s own merge logic do the rest.
- **Exit code `2` reliably and exclusively means "the header itself is unparseable TOML."**
  Confirmed across every malformed-header test in both features' testing, and confirmed a missing/
  misnamed file does NOT also produce exit 2 (it's exit 1, "script does not exist"), so the signal
  isn't accidentally shared with an unrelated failure class. Both features' malformed-header-repair
  logic is built on this: branch on exit code 2 specifically, not "any nonzero exit," before
  deciding whether stripping the header is safe.
- **A closing `# ///` fence with trailing whitespace fails to parse, exit 2 -- astral-sh/uv#10918.**
  Looks fine to a human, invalid to `uv`'s strict parser. Any header-repair logic must be tolerant
  of this on the STRIP side (match `# ///` followed by optional trailing whitespace, not requiring
  an exact end-of-line) even though `uv` itself won't tolerate it on write.
- **A stray/duplicate leftover fence line can itself become a NEW hard error on newer `uv` --
  astral-sh/uv#19544** ("reject duplicate script metadata blocks," landed ~0.11.17; previously
  silently treated as postlude). This is why header-strip logic should be a line-by-line state
  machine (track an `in_block` boolean, remove the whole block cleanly) rather than a regex that
  could under- or over-match, especially a lazy regex that could leave a stray fence line behind.
- **`VIRTUAL_ENV` set in the calling environment produces only a benign stderr warning, never a
  failure -- astral-sh/uv#15956.** Confirms success/failure must be judged solely by exit code,
  never by the presence of stderr text.
- **An existing `<script>.py.lock` sidecar is silently rewritten as a side effect of `uv add
  --script`, with no flag to suppress it.** Confirmed the exact filename convention
  (`<script-name>.py` -> `<script-name>.py.lock`) via a real lockfile (mtime + content change).
  Any feature that calls `uv add --script` on a file that might have a hand-maintained lock should
  either skip when one exists, or at minimum document that it will be touched.
- **Open caching issue -- astral-sh/uv#15156 ("Cached Script Dependencies Not Properly
  Invalidated").** `uv add --script` (change deps) then a later `uv run --script` on the SAME
  filename can serve a stale cached resolution even after the header changed; renaming the file
  fixes it, implying the cache key is filename-derived. Confirmed directly in this repo's own
  testing (an early reproduction attempt gave a misleadingly clean result from exactly this
  effect, resolved only via a fresh filename + clearing `~/.cache/uv`). **Confirmed to bite a
  real, shipped call site**: `tools/pvw_known_idempotent.py`'s (`HP_PVW_KNOWN_IDEMPOTENT`,
  REQ-005.13) retry paths -- `uvx autopep723 <entry>` shells out to `uv run` itself, and
  `main()`'s "other nonzero"/post-strip-repair branches both call `persist()` (writes a NEW
  header) then immediately re-run the SAME entry file, exactly this bug's trigger. Fixed via a
  `force_fresh` parameter on `run_script()` setting `UV_NO_CACHE=1`, used ONLY on the two
  post-persist retry calls (never the first attempt, so the common single-pass case keeps normal
  caching speed). `tests/test_pvw_known_idempotent.py`'s `RunScript`/`MainDispatch` tests assert
  the env split directly, so dropping `force_fresh` from either retry site is caught in CI.
- **`Get-Content -Raw`'s default text handling silently replaces any invalid-UTF-8 byte with the
  Unicode replacement character (`U+FFFD` / `EF BF BD`) on read** -- confirmed at the raw byte
  level. For a legacy-encoded script this corrupts an in-memory "original" backup before any risky
  operation begins, so a later "restore" can silently hand back an altered file. Fix: read/write
  via `[System.IO.File]::ReadAllText`/`WriteAllText` with
  `[System.Text.Encoding]::GetEncoding("ISO-8859-1")`, which round-trips any file's bytes exactly
  (1:1 byte-to-char mapping) regardless of real encoding -- used by PVW QuickStart's own
  retry/restore mutation. `plan-pep723-writeback.md`'s automatic feature sidesteps the hazard
  differently (skips non-UTF-8 files entirely, since it never mutate-then-possibly-restores the
  way QuickStart's live retry does).
- **A genuinely new dependency's written form depends on the `uv` version, not just on whether
  it's new.** `uv` 0.8.17 wrote bare names (`"requests"`); `uv` 0.11.28 wrote an auto-resolved
  lower bound (`"requests>=2.34.2"`) for the identical operation. Neither feature should assume or
  document one specific form -- treat whatever `uv` writes as correct by construction.

None of this is specific to either feature's own design (hook points, dispatch shape, audience) --
that detail stays in each plan doc, with a pointer back here for the underlying `uv` facts.

---

## `autopep723`'s own import-detection is environment-leaky under direct invocation, safe under `uvx`

A third-party design (`docs/plan-autopep723-two-tier.md`) claimed `autopep723 check` "never
reports delta" / is "environment-independent" -- always reports the complete set of third-party
imports regardless of what's already installed. **False as a blanket statement, confirmed by
reading `autopep723`'s actual source (pulled from the local `uv` cache) and direct reproduction --
the truth is narrower and still usable.**

`autopep723`'s `get_builtin_modules()` (the function every one of its commands -- `check`, `add`,
and the default run mode -- calls before filtering "third-party" from "already accounted for")
does `set(sys.builtin_module_names) | {m.name for m in pkgutil.iter_modules()}`.
`pkgutil.iter_modules()` walks `sys.path` of **whichever Python process is currently running
`autopep723` itself** -- so any package already installed in that process's own environment gets
silently treated as "not third-party" and dropped from the output, even though it's a real
dependency the target script needs.

**Reproduced directly**: a venv with only `requests` pre-installed, running `autopep723 check` on
a script that imports both `requests` and `click`, reported only `click` -- `requests` vanished
from the output with no error, no warning, nothing distinguishing it from "not needed." This is a
real, silent under-report, not a hypothetical.

**But it depends entirely on invocation method, not on the tool being unreliable in general**:
- `uvx autopep723 check <file>` (an isolated `uv`-managed tool venv, recreated/reused per-tool
  rather than sharing the target script's own environment) is **not** fooled by an active
  `VIRTUAL_ENV` env var pointing at a dirty environment -- confirmed directly: with `VIRTUAL_ENV`
  set to a venv that already had `requests` installed, `uvx autopep723 check` still correctly
  reported both `click` and `requests`.
- It **is** still fooled by a leaked `PYTHONPATH` -- confirmed directly: setting `PYTHONPATH` to a
  site-packages directory containing `requests` caused `uvx autopep723 check` to drop `requests`
  from its output, the same silent failure as the direct-invocation case.
- A **direct** interpreter invocation (`python -m ...`, `%HP_PY% -m autopep723`, `conda run python
  -m autopep723`, or any invocation sharing the target script's own populated environment) is
  **not** protected at all -- it reliably reproduces the delta bug for any package already
  installed in that interpreter's site-packages.

**Practical rule**: only ever invoke `autopep723` (any subcommand) via `uvx`, never via a direct/
shared interpreter, and only in a context where `PYTHONPATH` is already known-clear. This repo's
existing `set "PYTHONPATH="` / `set "PYTHONHOME="` near the top of `run_setup.bat` (REQ-010
isolation, runs long before any discovery-phase code) already satisfies the second condition for
any `run_setup.bat`-integrated use of `autopep723`. A design that instead proposes invoking it
directly through a lane's own interpreter (e.g. `conda run python -m autopep723 check` for a
future conda-lane integration) is **not** safe as written and must be revised to keep using `uvx`
even there -- see `docs/plan-autopep723-two-tier.md` for where this correction was applied.

**Also confirmed, load-bearing**: `autopep723` has zero
runtime dependencies of its own (`Requires-Dist` is empty in its distribution metadata), and is
strictly single-file -- its argument parser (`cli.py`) has no directory, glob, or multi-file mode
at all. Passing a directory (e.g. `.`) to any subcommand hits `Path.read_text()`'s
`IsADirectoryError`, which `get_third_party_imports()` catches and turns into an empty result with
**exit code 0** (not a nonzero failure) -- confirmed directly: `uvx autopep723 check .` prints an
error to stderr but still emits a valid, empty `# /// script ... # ///` block and exits clean. Any
design invoking `autopep723` against `run_setup.bat`'s app directory as a whole (rather than the
specific resolved entry file, e.g. `%HP_ENTRY%`) will silently produce zero discovered
dependencies on every run, with no error signal a caller could branch on.
