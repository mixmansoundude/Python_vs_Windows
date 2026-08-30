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

**House rule: distill to the load-bearing rule; move the narrative to
`docs/agent-closed-backlog.md`'s "Interconnect Narrative Archive".** This file is auto-loaded
every session -- keep each entry to the CURRENT-STATE rule plus, where an obvious alternative
fix exists, one line on why it doesn't work. The "which review round caught it / which fix
attempt was wrong first / confirming commit or CI run" detail lives in the archive, referenced
by section title where it matters.

---

## `$IsWindows` is undefined under Windows PowerShell 5.1 -- use `OSVersion.Platform` instead

**Mechanically enforced**: `tools/check_delimiters.py` flags any live (non-comment) use of the
bare `$IsWindows` token; `tools/run_sanity_sweep.sh`'s "DELIMITER CHECK" step scans the whole
repo with it. `$IsWindows` is a PowerShell 6+ automatic variable -- under Windows PowerShell 5.1
(what a real Windows machine's `powershell.exe` launches, as opposed to `pwsh.exe`) it does not
exist at all, so `if (-not $IsWindows) { skip }` silently evaluates true on GENUINE Windows and a
real test quietly no-ops with a false `skip=true`. Every `batch-check.yml` step uses `shell: pwsh`
(which always defines it correctly), so this stays dormant until someone runs a script locally via
`powershell.exe`, a CI step ever switches to `shell: powershell`, or `pwsh` is used on a
non-Windows sandbox (safe there too, since `pwsh` defines `$IsWindows` as `$false` correctly).

**Fix, proven correct everywhere in this repo:**
```powershell
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    # genuinely not Windows -- skip
}
```
A .NET API since .NET 1.0, not a PowerShell-edition automatic variable -- works identically under
`pwsh` (any OS) and Windows PowerShell 5.1.

**Rule for any PowerShell-line sanitizer in this repo's own tooling**: double-quoted string
content is not uniformly inert -- a `$variable` inside a double-quoted string is a live
interpolation reference and must survive a comment/string-stripping pass; single-quoted content
never interpolates and can be stripped wholesale. (History of the two rounds this checker needed
to get right: `docs/agent-closed-backlog.md`.)

---

## CodeRabbit review requires a manual trigger on every PR (repo has fewer than 10 stars)

This repo's CodeRabbit integration does NOT auto-review a newly opened or updated PR -- it posts a
"Review available on request" gate comment instead, and a push to an already-open PR resets to
that same gated state. **Standing procedure: reply `@coderabbitai review` (or `@coderabbitai full
review`) immediately after opening a PR, and again after every fix-commit push.**

**Rate limit**: roughly 1 included review/hour/developer. A rate-limited request replies "Next
review available in: N minutes" instead of running -- re-post after that window. Individual
finding threads CodeRabbit confirms as "Addressed in commit X" resolve independently of the full
formal review completing -- both signals are legitimate, check separately.

If CodeRabbit is stuck at CHANGES_REQUESTED after every actionable finding is confirmed resolved,
posting `@coderabbitai approve` has reliably cleared it.

---

## `.bat`/`.cmd` files: `-text`, not `eol=crlf` -- git's own normalization cannot make a raw download correct

A raw download of `run_setup.bat` (GitHub's "Raw" button, or `raw.githubusercontent.com` -- the
only realistic path for the Prime Directive's target user, a clean Windows machine with no git)
served pure LF, not CRLF, even with `.gitattributes`' `*.bat text eol=crlf`. Root cause: git's
`text=auto`/`text` attribute normalizes the STORED BLOB to LF on every commit unconditionally --
`eol=` only controls what a real `git checkout` writes to a working tree, a step raw/blob serving
never performs. Any repo relying on `eol=crlf` alone for a file that must also be byte-correct
when served raw has this gap.

**Fix: `-text` in `.gitattributes` for `.bat`/`.cmd`** -- disables git's line-ending handling
entirely, so the committed blob, working-tree bytes, and a raw URL's bytes are always identical.
Trades away git's "diffs stay clean regardless of editor" guarantee for "raw download is always
correct" -- the two are not simultaneously achievable through git normalization alone, so
byte-uniformity must be enforced by tooling instead:
- **`tools/check_crlf.py`** (check + `--fix`) enforces this on every git-tracked `*.bat`/`*.cmd`
  file. Wired into `tools/run_sanity_sweep.sh` AND a dedicated, independent, no-`continue-on-error`
  CI job (`crlf-check` in `batch-check.yml`). Its fix mode follows the safe-write pattern (build
  fixed bytes in memory, verify via fresh read-back, atomic replace) -- see "Never open a real
  source file in Python 'w' mode" below.
- CI enforcement is a real job conclusion, not automatically a merge gate -- per "gating is a
  GitHub branch-protection setting, not a YAML edit" (CLAUDE.md Item 35), someone with repo-admin
  access still has to add the check name to required-status-checks.
- No CI auto-fix-and-commit (only `tools/inline_model_fix.py`'s job may commit auto-fixes) --
  `--fix` is local/on-demand only.
- A contributor-facing warning banner (top of `run_setup.bat`/`run_tests.bat`/
  `tests/dynamic_tests.bat`) warns against editing via the GitHub web editor or a Mac/Linux tool --
  parallel to the runtime self-check (`run_setup.bat` detects a corrupted LF-only copy of ITSELF
  at startup and fails clearly).
- A second, independent distribution point (GitHub Pages, `publish_diag` job) republishes
  `run_setup.bat` decoupled from git blob/raw semantics entirely, and independently re-verifies
  CRLF via `tools/check_crlf.py` before publishing.

`.ps1`/`.psm1`/`.psd1` keep normal `text eol=crlf` unchanged -- never raw-fetched by end users
(embedded as base64 payloads, or contributor/CI-only scripts).

---

## Quote a variable before piping it into `findstr`, or `&` in its value splits the command line

`echo %VAR%| findstr ...` with `%VAR%` UNQUOTED: cmd.exe decides whether `&` is a command
separator purely from the current quote state as it scans left to right, in the SAME pass that
substitutes `%VAR%` -- it has no notion of "this `&` came from a variable." A path like `C:\Users\
Sales & Marketing\...` would silently split the line at the `&`, truncating what `findstr`
actually receives.

**Fix: `echo "%VAR%"| findstr ...`** -- the literal `"` characters toggle quote state before
`%VAR%` is substituted, so any `&` inside the expanded value is scanned "inside quotes." `echo`
does not strip the quote characters from what it prints, but a plain substring `findstr /C:"..."`
still matches fine against the quoted output. Applied to all system-directory checks
(`WINDIR`/`ProgramFiles`/`HP_PF86`).

---

## A multi-scenario PowerShell test's NDJSON `id` must stay a literal string at each `Write-NdjsonRow` call site, never a shared variable

`tools/check_ndjson_registry.py`'s static scan matches `id\s*=\s*['"]([...])['"]` -- a plain regex
over file TEXT, not a PowerShell parser, so it only matches an `id` key followed IMMEDIATELY by a
quoted literal. Consolidating a multi-scenario test's per-scenario id into one shared variable
(`$rowId = 'self.foo.bar'` in a `switch`, one `Write-NdjsonRow` call reading `$rowId`) is correct,
idiomatic PowerShell with identical runtime output, but silently breaks the regex -- the checker
reports the id as "no matching code emission site found," indistinguishable from a genuinely
stale/removed row, and this can hide even a PRE-EXISTING scenario's id if the refactor touches its
call site too.

**Fix: keep `id='literal.id.here'` as a literal at EVERY `Write-NdjsonRow` call site**, branching
on the scenario variable a second time right at the call site if needed, rather than one call fed
by a shared id variable. This check is advisory (non-gating) but the finding is real -- fix on
sight. Verify a new multi-scenario file:
`python3 -c "import re; print(re.findall(r'\bid\s*=\s*[\'\"]([A-Za-z0-9][A-Za-z0-9_.-]*)[\'\"]', open('tests/the_file.ps1').read()))"`

---

## Never open a real source file in Python `'w'` mode as part of a "dry run" -- write to a NEW path and diff before overwriting

Python's `'w'` mode truncates a file to zero bytes THE MOMENT `open()` succeeds, regardless of
whether anything is ever written. A verification script meant only to preview a payload-line swap
opened `run_setup.bat` this way and left it at 0 bytes -- caught immediately via `git status` and
restored via `git checkout --` since nothing was uncommitted at the time (would have been lost
otherwise).

**Rule: a script that INSPECTS or PREVIEWS a change to an existing tracked file must never open it
in a write/truncate mode (`'w'`, `'wb'`), even speculatively.** Safe pattern: read as bytes, build
the modified content entirely in memory, diff the candidate against the original to confirm only
intended lines changed, THEN copy the verified candidate over the real file as the last step.

`tools/sync_payload.py` implements this exact procedure as a reusable tool -- see "Embedded Helper
Update Workflow" below; use it instead of a one-off inline snippet for every payload swap.

---

## `rem` needs a space after it -- `rem-word` is parsed as a command, not a comment

cmd.exe only treats a line as a comment when `rem` is followed by whitespace (or EOL) --
`rem-nested` (no space) is parsed as an attempt to run a nonexistent command literally named
`rem-nested`, leaving a nonzero errorlevel sitting before whatever real `if errorlevel 1` check
comes next, silently misattributing that stray comment's own failure to unrelated code. **Rule:
never split a hyphenated word across two `rem` lines by putting the second half at the start of
the next line** -- any time a `rem` line's very next character after "rem" is NOT whitespace,
cmd.exe executes that leading token as a command name.

Mechanically enforced: `tools/check_delimiters.py`'s `_check_bat_rem_comment_spacing`.

---

## Live-tee async output: chunk-based reads, single-in-flight polling, never `Register-ObjectEvent`, never `select.select()` on Windows

Multiple rounds of bugs (superseded implementations, kept here only as the load-bearing current
rule -- full bug-by-bug history in `docs/agent-closed-backlog.md`):

1. **Never trust ".NET async output handling has completed" from a documented `WaitForExit()`
   contract without empirical verification** -- calling the no-arg `WaitForExit()` after a timed
   one does NOT guarantee `Register-ObjectEvent`'s buffers are drained; a final line flushed only
   at process exit can arrive after both calls return, silently truncating the capture.
2. **`Register-ObjectEvent` has no ordering guarantee between queued events on the SAME stream**
   (confirmed upstream: PowerShell/PowerShell#11937) -- two lines arriving close together can have
   their callbacks run on different pool threads in either order, silently transposing output.
3. **Fix for both: poll a single in-flight async read per stream, never `Register-ObjectEvent`.**
   Only issue the next read after consuming the current one's `.Result` -- ordering is enforced by
   construction. A completed read task with a `$null`/0-length result IS the EOF signal (no
   separate flag-polling needed).
4. **`StreamReader.ReadLineAsync()` is LINE-buffered -- invisible for a prompt with no trailing
   newline.** Python's `input(prompt)` flushes its prompt WITHOUT a trailing newline; a line-based
   reader returns nothing until a later write happens to add a newline (or the process exits),
   leaving a live user staring at a blank screen. **Fix: `StreamReader.ReadAsync(char[], int,
   int)`** (chunk-based) on a fixed buffer -- any available bytes surface the moment they arrive.
   `[Console]::Out.Write($chunk)`/`[Console]::Error.Write($chunk)` (no auto-newline, chunks land at
   arbitrary boundaries); EOF is a 0-length read.
5. **Testing this class of bug requires driving stdin live via a test-controlled pipe and
   asserting readability BEFORE writing anything** -- `subprocess.run(capture_output=True)`/
   `proc.communicate()` both block until the whole exchange finishes and cannot distinguish
   "surfaced instantly" from "surfaced only once something else flushed a line."
6. **Never use `select.select()` on a `subprocess.Popen` pipe in code that must run on Windows** --
   passed 8 local Linux runs, then failed on 4 separate Windows CI lanes on its first real run
   (`OSError: [WinError 10038]`; CPython's `select.select()` on Windows only supports sockets).
   Fix: a background `threading.Thread` doing blocking `os.read()` into a `queue.Queue`, main
   thread calling `q.get(timeout=N)`.

**Companion fact**: Python's `input(prompt)` DOES flush stdout before blocking on stdin, even when
redirected/non-tty -- a program that asks setup questions via `input()` then loops is not at risk
of a drain-race, only `print()` calls made well before the next `input()`/exit are.

**Rule of thumb for any future async-output consumer**: prefer chunk/byte-based reads whenever the
producer might write meaningful, already-flushed content without a trailing newline.

---

## Ambient Python path leakage in uv sub-bootstrap venvs (fixed via `UV_PYTHON_PREFERENCE=only-managed`)

**Isolation-boundary leak in this bootstrapper, not a uv defect** -- in uv-first lanes, `uv venv`
was using the GitHub runner's own ambient/hosted-toolcache Python instead of a fresh managed
CPython, because nothing told uv to stay inside its own managed toolchain (this also surfaced as
malformed-pyproject-toml failures when a helper assumed 3.11+ `tomllib` on an ambient 3.9.x).

**Fix**: `set "UV_PYTHON_PREFERENCE=only-managed"` at the very start of the uv acquisition block in
`run_setup.bat`, before the `PVW_UV_EXE` branch and before the first uv invocation. Blinds uv to
ambient/system/conda interpreters; with no user constraint uv selects (downloading if needed) the
latest managed CPython. A user-provided version is still honored downstream via `uv venv --python
X.Y`. Lives inside the self-contained bootstrapper itself (a real double-click user has no CI
`env:` block) -- never move this into `batch-check.yml`.

**Two layers, deliberately decoupled**: the orchestration layer (bootstrapper, diagnostics, helper
scripts) is ALWAYS the latest managed CPython, never held hostage by the target app's version
constraints; the target layer (the user's app venv) honors an explicit user constraint via
`--python`.

**Verification**: `self.uv.managed.interpreter` (runtime proof, version-agnostic on purpose) and
`uv.python.preference.configured` (static config-presence check only).

### Embedded-helper Python baseline: target modern, degrade gracefully (syntax vs. feature)

Fallback paths (venv-fallback, system-Python consent, `HP_CI_SKIP_ENV`) can still hand `HP_PY` an
older ambient interpreter, so embedded `HP_*` helpers are neither "must run on 3.9" nor "modern
only":
- **Feature guards are fine.** Modern stdlib features (`tomllib`, etc.) may be used wrapped in
  `try/except ImportError` with a working fallback -- `HP_PYPROJ_DEPS` is the gold standard (tries
  `tomllib`, falls back to a regex TOML parser on failure).
- **Core token SYNTAX must stay parse-compatible with older interpreters.** A `SyntaxError` fires
  at parse/compile time, BEFORE any `try/except` runs, producing a hard crash. No bare
  `match`/`case` (3.10+), no `X | Y` runtime type unions in evaluated positions, no other grammar
  an older CPython would reject while tokenizing.

---

## REQ-013 connectivity check needed a bounded retry, split into two techniques by nesting depth

A single dropped ICMP echo plus a curl connect exceeding 5s (plausible under shared-runner network
contention) was enough to misclassify a genuinely-online host as offline -- REQ-022 already solved
this class of problem for `:try_conda_create` (detect, wait, retry once), just never applied here.

**Top-level checks** (not nested in a parenthesized block): a normal counter-variable retry loop
(`set /a HP_CONN_PING_ATTEMPT+=1` + `if %HP_CONN_PING_ATTEMPT% LSS 2 goto :label`) is safe -- every
line is freshly parsed at the top level.

**In-block checks** (nested inside `if /I "...=="y" ( ... )`): a counter variable does NOT work --
`set /a`-ing it and reading it via `if %VAR% LSS 2 goto` INSIDE the same parenthesized block hits
the parse-time `%VAR%`-expansion trap (see "Provider-cascade dispatch is goto-based on purpose"
below): the whole block is read once before any `set` inside it executes, so the read always sees
the pre-block value. Fixed instead by literally duplicating the check-and-retry pair a second time
(no variable at all -- nothing to freeze). **Rule of thumb**: inside a parenthesized block, prefer
literal duplication over a counter-variable retry loop for a small, fixed attempt count (2-3);
reserve the counter-loop idiom for top-level code.

---

## Batch / CMD.EXE syntax quirks (the most common source of regressions)

The bootstrapper is a single self-contained `.bat` file, so CMD.EXE parsing rules dominate the bug
surface. `CLAUDE.md`'s "Common Pitfalls"/"Key Conventions" are the authoritative list; the
recurring traps that have actually bitten us:

- **Parse-time vs. runtime variable expansion.** CMD expands `%VAR%` when it *parses* a
  parenthesized block, not when it executes each line -- a `%VAR%` set earlier in the SAME block
  still reads its OLD value. Fix: reference `%~1` directly, or restructure via `goto` instead of a
  parenthesized block (see "Provider-cascade dispatch is goto-based on purpose" below).
- **`%%` inside `for` loops.** Loop variables and any literal `%` must be doubled inside `for`
  bodies.
- **Special characters need escaping/quoting:** `&`, `|`, `<`, `>`, `^`, `!`, `~`, `%` in values
  require quoting/`^`-escaping; `%` must be doubled (`%%`).
- **A `(`/`)` pair inside echo/rem prose text, if nested inside ANY real open bracket at all --
  even one level deep, even same-line, even with no redirection -- corrupts a parenthesized
  block's parse.** cmd.exe determines where a parenthesized block's raw text ENDS by counting
  `(`/`)` characters in the raw text, with zero concept of "this paren is just prose," and it must
  do so BEFORE deciding whether to execute or skip the block -- so corruption happens regardless of
  whether the block's own runtime condition ever evaluates true. This shipped as a real regression
  THREE separate times (PR #408 cross-line in `echo` text; PR #445/Item 52 cross-line in `rem`
  text, breaking all 8 CI lanes; a same-line `(exit 3)` pair nested 4 levels deep in the same PR
  #445 code, breaking CI again after the first fix). A dedicated live-`cmd.exe` probe (CLAUDE.md
  Item 61) confirmed even the simplest possible case -- one level of nesting, same-line, no
  redirection -- corrupts identically to the cross-line case. **Rule, no exceptions: never let a
  literal `(`/`)` land in echo/rem prose text that is nested inside any open bracket, regardless of
  same-line vs. cross-line or redirection.** Reword around it (` -- ` or `,` instead of
  parentheses), or escape both as `^(`/`^)`. A top-level (non-nested) echo/rem statement's own
  same-line, self-contained pair remains safe (confirmed precedent:
  `:print_fastpath_ambiguous_note`) -- the hazard is specifically about NESTING, not parens in
  prose generally.
  `tools/check_delimiters.py` enforces this for both `echo` AND `rem` lines (generalized under
  CLAUDE.md Item 61 after the checker was found to skip `rem` lines from paren-scanning entirely) --
  same-line and cross-line nested pairs are flagged identically, with `^`-escaped brackets and
  quote characters on prose lines correctly treated as inert. Running the fixed checker against
  `run_setup.bat` found and fixed 89 previously-invisible violations across two passes (26 + 63).
  Tests: `tests/test_check_delimiters_import.py`'s `test_paren_*` cases.
- **Avoid `EnableDelayedExpansion`; if unavoidable, wrap it tightly.** `!` becomes special under
  delayed expansion, and a parent shell launched with `/V:ON` causes `!`-collisions.
  `tests/harness.ps1`'s `batch.bang.scan` enforces "no `!` in live batch code lines."
- **`call "%CONDA_BAT%" ...` for all conda invocations** so the parent batch keeps running after
  conda's own batch returns (a bare invocation can terminate the parent).
- **CMD `set` 8191-character hard limit** -- see the dedicated section below.
- **Line endings:** `.bat`/`.ps1` are CRLF, everything else LF, controlled by `.gitattributes` (do
  not hand-edit). LF-only edits to `.bat`/`.ps1` can fail locally before git normalizes on commit.
- **`:die` uses `exit /b`** (a subroutine return, NOT a process halt) -- execution routinely
  continues past a `call :die` line into whatever the enclosing block does next. Check
  `~bootstrap.status.json`/log markers, not just the process exit code, when reasoning about
  success. `:die` itself sets `HP_BOOTSTRAP_STATE=error` unconditionally as its first action
  (before `:write_status`), so this is centralized at the source rather than needing a companion
  `set` at every one of its ~26 call sites.
  - **`:warn_build_incomplete`** is a non-pausing sibling of `:die` for the 3 PyInstaller-build-
    failure sites reached only AFTER the Nuitka fallback has ALSO failed, where genuinely useful
    verification work still follows (interpreter-fallback verification decides real
    success/failure). Sets `HP_BOOTSTRAP_STATE=error` but skips `:die`'s pause/`:release_lock`/
    `:write_status` (all premature there). Not every `:die` site qualifies -- classify
    doomed-vs-not-doomed before converting a new one (see CLAUDE.md's Item 46 / the plan doc it
    references).
  - **`:die` already `pause`s BEFORE its own `exit /b %RC%`** on the real-interactive-user path
    (`if not defined HP_CI_LANE`) -- so the commonly-cited risk of converting `:die` to a genuine
    halting `exit` ("closes the console before the user reads the message") does NOT actually
    apply; the pause already ran first.
  - **Two independently-tracked "exit code" concepts, do not confuse them**: the real OS-level
    process exit code (currently always 0 for nearly every `:die` site, since most fall through to
    `:success`'s unconditional `exit /b 0`) vs. the self-reported `exitCode` JSON field in
    `~bootstrap.status.json` (from `:write_status`'s `%RC%` argument, entirely independent,
    written to disk BEFORE `:die`'s pause/exit lines run). This is a deliberate signal-separation
    design ("did the bootstrapper run to completion" vs. "did the product succeed"). A full sweep
    (2026-08-18) found exactly ONE currently-gating test that hard-asserts the OLD always-0
    behavior as its own pass condition: `tests/selfapps_entrysmoke_no_interpreter.ps1:171`. **A
    future `:die`-halts-the-process change must update this test's contract deliberately** (or
    justify exempting it) and re-sweep for any new such assertion added since -- do not discover
    the breakage via a red CI run.
- **PowerShell adjacent traps:** `-or`/`-and` outside a conditional are parsed as parameter names
  ("parameter name 'or'"); `tools/check_delimiters.py` flags these, correctly tracking multi-line
  continuation (backtick, trailing `-and`/`-or`, an already-open bracket) so it doesn't
  false-positive on valid multi-line PowerShell. Multi-line `run:` PowerShell in YAML interacts
  badly with quote nesting -- run `actionlint` on changed workflows.

---

## `"$var:text"` inside a double-quoted PowerShell string is a scope-qualified-variable parse error, not string interpolation followed by a literal colon

`"...$scenario: run_setup.bat not found"` looks like interpolation-then-colon, but PowerShell's
tokenizer reads `$scenario:` as a SCOPE-QUALIFIED variable attempt (`$scope:name`, same syntax as
`$env:VAR`) -- any bare `$name` immediately followed by `:` and non-identifier text is a
`ParserError`. This is a PARSE-time error, so the ENTIRE `.ps1` file fails to load -- not a
runtime exception in one function; every row the file emits is simply ABSENT from a CI artifact,
easy to misdiagnose as "never wired up" instead of "the file never parsed."

**Fix: `${scenario}:` (curly-brace delimiting)**, not string concatenation. Applies to ANY
interpolated variable immediately followed by `:` in a double-quoted string.

**This shipped and broke all 8 CI lanes of a PR because the sanity sweep's own PS parse check
silently discarded parse errors** -- `[...]::ParseFile($path, [ref]$tokens, [ref]$errors)` reports
errors via the `$errors` out-parameter, not a catchable exception; passing `[ref]$null` for it (as
both CLAUDE.md's inline sweep block and `tools/run_sanity_sweep.sh` did) silently discards every
parse error, and `try/catch` around the call does not catch them either. **Rule: any future
`[...]::ParseFile(...)` call in this repo's tooling must capture and check the errors
out-parameter -- never pass `[ref]$null` for it.**

---

## Windows `move` onto an existing destination: atomic replace for FILES, silent NESTING for DIRECTORIES

For a same-volume FILE `move /y` onto an existing destination, the operation is atomic (fully
replaces, source consumed) or fully fails (both untouched) -- so checking whether the SOURCE is
now gone reliably tells you the move succeeded (`:offer_optimized_build`'s pattern).

**That reasoning does NOT carry over to a DIRECTORY move.** A directory `move` onto an existing
destination silently NESTS the source inside it (`move srcdir destdir` where `destdir` exists
produces `destdir\srcdir\...`) -- neither "check destination" nor "check source gone" detects
this: if a preceding `rd /s /q` fails to fully clear the destination (a lock), the subsequent
`move` nests rather than erroring, so both checks read false-success.

**The only reliable fix for a directory swap: verify the PRECONDITION (destination actually
cleared) before attempting the move**, not the move's outcome afterward -- gate `move` itself on
`if exist "%DEST%" goto :skip_move_this_attempt` right after the `rd`, so `move` only ever runs
onto a confirmed-nonexistent target (`:embed_swap_retry`'s pattern). **Rule of thumb: before
reusing a Windows move/swap verification pattern proven for a FILE on a DIRECTORY (or vice versa),
re-derive the semantics explicitly** -- do not assume the same post-condition check transfers.

---

## A single trailing backslash before a closing quote silently corrupts a subprocess argument

Any native Windows console app's C-runtime argv parser (`CommandLineToArgvW`-equivalent) collapses
N backslashes immediately followed by `"` to `N/2` literal backslashes -- if N is ODD, the trailing
backslash escapes the quote instead of closing it, silently merging that argument with whatever
text follows into corrupted garbage. No error, no crash -- it just quietly never works. Confirmed
in two independent real instances: `findstr /C:"%WINDIR%\"` (odd count, never matched a real
target) and `~dll_bundle_scan.py` called with `"%HP_PY_DIR%"` (from `%~dpI`, always one trailing
backslash) immediately followed by another quoted argument (silently merged two args into one,
making a real, present DLL always report "could not locate").

**Rule: never let a `%VAR%`-expanded value that might end in `\` sit immediately before the
closing `"`** in any subprocess argument. Double the trailing backslash defensively
(`%WINDIR%\\"`, or a dedicated `_ARG` copy with one appended backslash), or restructure so the
closing quote is never adjacent to a variable-derived trailing backslash. This is a genuinely
general rule about Windows argv re-parsing, not specific to any one native executable.

---

## `:log` echoes UNQUOTED -- never route shell metacharacters through it

`:log` does `set "MSG=%~1"` then `echo %date% %time% %MSG%` -- echoed **unquoted**. A `<`/`>`/`|`/
`&` in `%MSG%` is parsed as a redirection/pipe operator at execution time, corrupting the log line
and/or creating a stray file. **Rule: never pass a value containing `<`/`>`/`|`/`&` into `:log`.**
If you must surface such a value, forward it only through a tightly double-quoted argument to the
actual command, and log a separate operator-free display string instead (e.g. `HP_UV_PY_REQ`,
quoted at the uv call site, vs. `HP_UV_PY_DISP`, safe for `:log`).

**Deferred tech debt -- do NOT "fix" `:log` globally with delayed expansion.** Blocked by three CI
static checks (`batch.delayed.off`, `batch.delayed.enable_absent`, `batch.bang.scan` -- no `!` in
live batch lines), which exist because process-wide delayed expansion previously caused
`!`-collision pain. A global fix is its own isolated task that must also revisit those checks.

**Concrete unresolved instance, accepted risk**: `%HP_ENTRY%` is echoed unquoted at 4 call sites
(a filename with `<`/`>`/`&`/`|` would mis-parse -- requires a crafted drag-and-drop filename, not
a common vector); 3 of those 4 are also `call :log "..."` invocations, exposed to the second hazard
below too. Blocked on the same global `:log` rework.

**A second, independent hazard: `call :log "..."` triggers cmd.exe's OWN second expansion pass, so
`%`/`^` are just as dangerous as `<`/`>`/`|`/`&`.** `call` re-scans its own already-substituted
command line a second time before invoking the target. If a value's CONTENT happens to contain
text shaped like `%OTHER_VAR%` (captured external text -- a build-tool warning, not a literal
source reference), the caller's normal substitution inserts it first, then the SECOND `call`-scan
finds and expands `%OTHER_VAR%` too, potentially leaking an unrelated env var (a CI secret) into
`:log`'s output. **Rule: any display-only sanitization protecting a `call`-based subroutine's
unquoted internals must ALSO strip `%` and `^`, not just `<`/`>`/`|`/`&`.**

**To strip a literal `%`/`^` from a batch variable, do NOT use cmd.exe `:search=replace`
substitution** (`set "VAR=%VAR:%%=_%"` looks like a natural extension of the FOR-loop `%%i`
escaping rule but silently produces an EMPTY value instead) **and do NOT build the replacement
inside a `-Command` string that shares a cmd.exe logical line with any real `%VAR%` reference**
(cmd.exe pairs `%` characters via a left-to-right whole-line scan with zero quote-awareness -- a
lone unpaired `%` inside PowerShell text can pair with a real `%LOG%`/`%TEMP%` reference instead,
silently deleting everything between them; an EVEN total `%` count is NOT proof of safety, since
two lone `%`s can pair with EACH OTHER instead of each correctly pairing with a real reference).
This exact code path got "fixed" wrong THREE times in a row before landing on the actual fix,
each miss only caught by a live-`cmd.exe`-executed CI fixture, never by reasoning alone (full
trace: `docs/agent-closed-backlog.md`). **Final, correct fix: stop generating cmd.exe-unsafe
`-Command` text at all.** The moment a PowerShell one-liner needs to build or contain a literal
`%` or `^` (not just read an existing `%VAR%` the caller already substituted), use a real emitted
`.ps1` file invoked via `-File` (env-var names and output paths as plain argv) instead of
`-Command` -- removes cmd.exe's tokenizer from the equation entirely. See "PowerShell helpers:
prefer an emitted `.ps1` file" below.

---

## Provider-cascade dispatch is goto-based on purpose (parse-time expansion)

`:provider_cascade` routes via one-line `if /i ... goto` statements, never a big parenthesized
`if (...)` block -- inside such a path, `set "HP_ENV_MODE=conda"` then reading `%ENV_PATH%`
built from it in the SAME parenthesized block would read the OLD (pre-`set`) value (parse-time
`%VAR%` expansion, the classic drag-and-drop-empty-filename bug class). Splitting into
goto-reached labels means each `set`/read happens on a freshly parsed line. The identical bug
class also hit `%ERRORLEVEL%` (not just ordinary variables): reading `set "HP_SMOKE_RC=
%ERRORLEVEL%"` INSIDE a parenthesized `else ( ... )` clause froze it to whatever preceded the
dispatch (almost always `"0"`), so a genuinely broken cached EXE was never discarded via the
non-interactive CI branch. **Rule: any time a diff wraps a previously-top-level "launch a process,
read `%ERRORLEVEL%`" sequence inside a NEW `if (...) else (...)` block, stop and check whether the
read is safe** -- it produces no error, only a silently wrong captured value. If you refactor a
goto-dispatch cascade into nested blocks, re-verify every `%VAR%` you read was not `set` earlier
in the same block.

Two more cascade gotchas: `if defined VAR`/`if not defined VAR` are runtime checks (safe inside
blocks); `%VAR%` substitution is parse-time (not safe) -- per-tier no-retry guards use `if defined`
for exactly this reason. `:log` cascade messages say "uv to conda," never "uv -> conda" -- a `>`
is parsed as a redirection and silently eats the log line.

---

## A declined/failed fallback tier must clear its own "selected provider" variable, not just return failure

`:try_system_fallback` set `HP_PY=%HP_SYS_EXE%` BEFORE the REQ-014 consent gate (ready to use
immediately on accept), but on either failure exit after that point it returned without clearing
`HP_PY`. Combined with `:die`'s call-frame-only-return quirk, the leaked, non-empty `HP_PY`
silently satisfied `:after_env_mode_selection`'s `if not defined HP_PY` guard -- the bootstrap
built and ran using the STALE interpreter path from the declined/failed attempt, reporting
`state=ok` out of a scenario where every real provider had failed or been declined. **Rule for any
fallback-tier subroutine that sets a "selected provider" variable speculatively before a gate that
can still decline**: every failure/decline exit after that point must clear the variable back to
its pre-tier state -- a failed subroutine must leave no trace of its attempt in shared state, since
callers may (and routinely do, via the `:die`-continues quirk) proceed past a declared failure
using whatever is left behind. (`:try_venv_fallback`'s `:venv_canary_fail` had the identical latent
bug, fixed the same way.)

---

## Env-var flags are scaffolding, not intended run paths (REQ-019)

The intended run paths are double-click and drag-and-drop with NO environment variables. Every
`HP_*`/`PVW_*` variable is test/CI/super-user scaffolding. **No Prime-Directive outcome may depend
on a user setting one, and the ABSENCE of a flag must never block a fallback tier that gets the
code running.** A flag may ADD diagnostic/CI behavior or a super-user override, or DISABLE/skip an
optional step (absence == full behavior) -- but an opt-in flag must never be the GATE for a
behavior the Prime Directive needs. (Bit us once for real: system Python was hard-gated behind
`HP_ALLOW_SYSTEM_FALLBACK==1`, a flag a double-click user never sets, making the last-resort tier
unreachable by default -- fixed by gating solely on the REQ-014 consent prompt, deprecating the
flag.) **When auditing, treat any `if "%HP_...%"=="1"` that ENABLES a Prime-Directive behavior as
a bug**; flags should only suppress, divert for tests, or add super-user overrides.
`HP_FORCE_CONDA_ONLY` (CI diagnostic) and `HP_OFFLINE_MODE` (auto-set by the connectivity check)
and `HP_SKIP_*` (disable-only) are all correctly scoped as suppression-only. **Standing directive:
re-run this specific check whenever a new `HP_*`/`PVW_*` flag is added** (see CLAUDE.md's
"Periodic Maintenance Checks" for the cadence).

## CI-safe interactive gates: echo the prompt, then resolve the answer

Any `set /p` consent prompt reachable on a non-interactive CI path must be CI-safe or it hangs.
Established pattern (`:cascade_consent_gate`, `:system_python_consent_gate`):
1. **Echo the exact prompt string unconditionally** (a plain `echo`, not via `:log`) so prompt
   assertions see it even when input is skipped.
2. Branch: `if defined HP_TEST_<X>_ANSWER` (deterministic override, checked FIRST so an explicit
   `Y` can accept even in CI) `else if defined HP_CI_LANE` (auto-decline, no `set /p`) `else`
   interactive `set /p`.
3. Keep accept/decline log lines verbatim -- static and behavioral tests match them.

**`:cndf_prompt_loop` (REQ-013 connectivity-retry) is a DELIBERATE EXCEPTION to step 2's
`HP_CI_LANE` auto-decline -- verify before "fixing" it like every other gate.** It uses
`HP_TEST_CNDF_ANSWER` plus `NOINPUT`/`HP_NONINTERACTIVE` auto-decline, but NOT bare `HP_CI_LANE`,
because three existing regression tests deliberately run this exact gate under `HP_CI_LANE=test`
while piping real Y/N answers via stdin to exercise the interactive Y-then-N retry loop -- a
mechanism a static override CANNOT replicate (the same env var would answer identically on both
passes, infinite-looping on `Y`). Adding a bare `HP_CI_LANE` auto-decline here would silently break
all three by bypassing `set /p` before it reads the piped stdin.

---

## GitHub Actions data-passing hazards

**Never pass data >32 KB through a step's `env:`** -- overflows Linux's `execve` ARG_MAX (bit this
repo at ~168 KB base64 passed via `INVENTORY_B64`). Write to a file in `$GITHUB_WORKSPACE` and read
from disk instead.

**`download-artifact@v6`'s `merge-multiple: true` silently overwrites same-named files** when a
step downloads MULTIPLE artifacts matching a `pattern:` and each zips a file with the SAME local
filename -- only the LAST-downloaded artifact's content survives, no error anywhere. Bit this repo
twice (an NDJSON cross-check silently degraded to 1 observed lane instead of 8+; `selftest-gate`'s
verdict aggregation silently limited to whichever single lane survived). **Fix: drop
`merge-multiple` entirely** -- without it, each matched artifact lands in its own
`<path>/<artifact-name>/` subdirectory, so no collision is possible; every consumer already reads
via a recursive glob, so no other code change is needed. Safe to keep `merge-multiple: true` only
when the step downloads a SINGLE artifact by exact `name:` (no `pattern:` matching several). Before
setting it on any new multi-artifact download, trace the matching uploads and check whether their
`path:` is the same local filename across all of them.

**A `pwsh` `run:` block's own final `$LASTEXITCODE` becomes the step's exit code, even after later
PowerShell-only lines that never touch it.** GitHub Actions appends its own `exit $LASTEXITCODE` to
the end of every `pwsh`-shell block -- if the block invokes an external script via `&` that exits
non-zero, `$LASTEXITCODE` stays set through any number of later pure-PowerShell lines, so the step
(and job conclusion) can silently fail on that exit code even when the author only meant to capture
and act on it programmatically. **Rule: the moment a `run:` block invokes an external script/
command via `&` and captures `$LASTEXITCODE` to branch on programmatically (rather than letting
that failure genuinely fail the step), explicitly control the step's own final exit status at the
end of the block** (an explicit `exit 0`, or reset `$LASTEXITCODE`) -- do not assume "the script's
result is just a variable I read" is enough.

---

## Heuristic dep-augmentation must strip pip extras before name lookup

`HP_PREP_REQUIREMENTS`'s `names_lower` list must strip `[...]` (pip extras, e.g. `pandas[excel]`)
before lowercasing/comparing -- otherwise `'pandas' in names_lower` returns `False` for a spec
written as `pandas[excel]`, and the openpyxl/xlsxwriter augmentation never fires for the exact
syntax modern documentation tells users to write. Fix:
```python
names_lower = [re.sub(r"\[.*?\]", "", re.split(r"[<>=!~,\s]", value, maxsplit=1)[0]).strip().lower() for value in pip_specs]
```

---

## Pre-build `--collect-submodules` must be DOUBLE-gated (used AND installed), never installed-only

`HP_COLLECT_SUBMODULES` emits `--collect-submodules=PKG` for a curated set (sklearn, matplotlib,
scipy, plotly) whose submodules load via dynamic dispatch PyInstaller's static analysis can't
trace. **The gate is deliberately on USED-by-source AND INSTALLED, not installed alone** --
"installed" alone would bundle hundreds of MB of an unused library merely because it sits in a fat
global/conda env; "used" alone could target a package that's imported but absent, making
PyInstaller error out. Do NOT simplify to a single gate; `tests/test_collect_submodules.py::
GatingMatrix` locks both halves. The curated set uses IMPORT names (`sklearn`, not `scikit-learn`)
and stays conservative on purpose (heavy stacks like torch/tensorflow excluded -- gigabyte EXEs).
`HP_PYI_COLLECT` must be computed in `:compute_collect_flags` and set BEFORE the build's
parenthesized `if/else` block, exactly like `HP_PYI_EXPAT` -- moving it inside would parse-time-
expand to its old (empty) value.

---

## --hidden-import auto-recovery must stay STRICT (ModuleNotFoundError + installed), never broaden to ImportError

`:hidden_import_recover` (via `~hidden_import_scan.py`) is deliberately gated on THREE conditions;
relaxing any is a mistake:
1. **`ModuleNotFoundError: No module named 'X'` only -- NOT a bare `ImportError`.** For MNFE, X
   *is* the exact `--hidden-import` target. For `ImportError: cannot import name 'Y' from 'Z'`, Z
   is ALREADY bundled and Y is an attribute, not a module -- no `--hidden-import` target is
   derivable, and broadening to ImportError would burn all 3 rebuild cycles for nothing. The
   genuine packaging case behind some ImportErrors (a dynamic fallback import whose target wasn't
   collected) is `--collect-submodules`/`--collect-all` territory, not this token extractor.
   Confirmed correct against a real production case (pygrib's own Cython-generated `ImportError:
   cannot import name version` -- no quotes, no `from 'packaging'` clause, since Cython's
   hand-rolled error format carries neither, so nothing in the runtime signal identifies the source
   package at all). Do not "improve" this with a heuristic guessing the source package from the
   last hidden-imported target -- a coincidental `find_spec` hit would silently burn an iteration
   with no way to distinguish it from a correct fix.
2. **X must be installed in the build interpreter (`find_spec`)** -- makes a user typo cost ZERO
   rebuilds (not installed, so the helper emits nothing) and correctly excludes a genuinely-missing
   dependency (warnfix's job, not this loop's).
3. **`dist\<env>.exe` must have been built by PyInstaller, not Nuitka**
   (`HP_NUITKA_FALLBACK_USED`) -- see `docs/agent-interconnect.md`'s Tier A section.

No-loop guarantee: an already-tried list plus a 3-iteration cap; a `-1` (timeout/hang) initial exit
skips recovery entirely (re-running a hung EXE would just hang again). `:hidden_import_recover` is
goto-based, not a parenthesized block, so `%HP_HIDDEN_ITER%` reads its runtime value on each pass.
Recovery rebuilds re-snapshot spec pre-existence (`HP_HID_SPEC_PRE`) at entry to avoid clobbering a
user's committed `.spec`.

**Test-authoring rule**: any XFAIL test building an EXE that fails on a MNFE for an INSTALLED
module will be auto-recovered and XPASS -- use a not-installed module or a non-MNFE failure for a
genuinely permanent xfail scenario.

---

## CMD.EXE 8191-Character Line Limit for HP_* Payloads

**Every `set "HP_VARNAME=..."` line in run_setup.bat must stay under 8191 total characters.**
Exceeding it crashes cmd.exe with exit code `-1073740791` (`STATUS_STACK_BUFFER_OVERRUN`) --
silently: `bootstrap.log` has only 1-3 early lines, the CI job completes in ~1s.

**Budget**: max b64 content = 8191 - `len('set "HP_VARNAME=')` - 1 (closing quote). Current
tightest margins (re-verify before expanding any payload): `HP_PREP_REQUIREMENTS` (192-char
margin), `HP_COLLECT_SUBMODULES` (459-char margin) -- everything else has 2900+ margin.
```python
import base64
b64 = base64.b64encode(open('helper.py', 'rb').read()).decode('ascii')
line_len = len('set "HP_VARNAME=') + len(b64) + 1
assert line_len <= 8191, f"CMD line limit exceeded by {line_len-8191} chars!"
```

**Crash diagnosis checklist**: bootstrap.log has only 1-3 lines; CI job runtime ~1s; exit code
`-1073740791`/`0xC0000409`; failure at `call :define_helper_payloads`; run
`python -c "..." ` (see `check_delimiters.py`-style scan) to find any line over 8190 chars.

---

## Embedded Helper Update Workflow

**Preferred method (has a canonical `tools/` source, the common case): edit the source file, then
run `tools/sync_payload.py`.** Reads `run_setup.bat` as bytes, verifies the diff touches EXACTLY
the target `set "HP_VARNAME=..."` line, checks the 8191-char budget, and only then writes.
```bash
python tools/sync_payload.py HP_PYPROJ_DEPS tools/pyproj_deps.py         # write
python tools/sync_payload.py HP_PYPROJ_DEPS tools/pyproj_deps.py --check  # verify only
```
Then `python tools/check_delimiters.py run_setup.bat` and the payload's `PayloadSync` unit test.

**No canonical source yet**: decode to a scratch file, edit that, still hand it to
`tools/sync_payload.py` for the actual write -- never open `run_setup.bat` in write mode by hand.

**PayloadSync tests for a `.ps1`/`.bat`/`eol=crlf`-attributed canonical source must normalize
CRLF/LF before comparing bytes** (`.replace(b"\r\n", b"\n")` on both sides) -- `actions/checkout`
on Windows CI materializes CRLF regardless of what the payload was encoded from (e.g. LF on a
Linux dev sandbox), so a raw byte comparison mismatches even though content is logically identical
(the base64 string itself is immune -- test-assertion bug only). `.py`/`.sh` sources are `eol=lf`,
safe to compare raw.

**PowerShell helpers: prefer an emitted `.ps1` file over inline `-Command "..."` the moment the
body needs ANY literal `"` character anywhere** -- cmd.exe's naive quote-toggle tokenizer has no
concept of "this quote is inside a single-quoted PowerShell string," so a literal `"` anywhere
breaks its parsing of the `-Command` argument regardless of how it got there. A real `.ps1` file
(via `:emit_from_base64`) has no such exposure.

**Second, independent trigger for the same rule: a literal `%` anywhere in `-Command` text, even
with zero `"` characters involved** -- cmd.exe pairs `%` via a whole-line left-to-right scan with
zero PowerShell-quoting awareness (see "`:log` echoes UNQUOTED" above for the full trace of three
wrong fixes before landing on this rule). **The moment a PowerShell one-liner needs to build or
contain a literal `%`, stop and use `-File` instead of reasoning through cmd.exe's pairing
behavior again.**

**Prefer raw .NET types over Utility-module cmdlets (`Get-FileHash`, `Expand-Archive`,
`Get-Content`, `Set-Content`, `Get-Date`) in embedded `.ps1` helpers invoked from a `for /f`
backtick subshell -- module auto-loading is not guaranteed there on Windows PowerShell 5.1, and
this cannot be caught by local `pwsh` testing.** `Microsoft.PowerShell.Utility` genuinely failed to
auto-load in that specific invocation shape on real Windows CI (`Microsoft.PowerShell.Management`
cmdlets worked fine in the same run) -- `pwsh` never reproduces it. Use
`[System.Security.Cryptography.SHA256]`, `[System.IO.Compression.ZipFile]`,
`[System.IO.File]::ReadAllText/WriteAllText`, `[datetime]::Now` instead. Also check any `^`/`$`
regex anchor applied to file content that might carry Windows line endings -- .NET regex `$` in
multiline mode matches before `\n`, not `\r\n`, so an anchor like `^#import site$` silently fails
to match CRLF-terminated content; widen to `(?m)^#import site\r?$`.

**Three distinct bounded-launch helpers, three different kill philosophies -- do not conflate
them:**
- `~failfast_probe.ps1` (`HP_FAILFAST_PROBE_MS`, default 10000ms) -- a CLASSIFICATION checkpoint
  only, never kills; after the window, a second unbounded wait covers the user's real program.
- `~exe_smokerun.ps1` (`HP_SMOKERUN_KILL_MS`, default 30000ms) -- kills, but only if the process
  produced ZERO output by the deadline ("activity-aware": any output, even one chunk with no
  trailing newline, skips the kill for the rest of the run, unbounded).
- `~exe_hint_rerun.ps1` (`HP_HINT_RERUN_KILL_MS`, default 10000ms) -- kills UNCONDITIONALLY at its
  deadline regardless of output, since it exists purely to capture a bounded diagnostic snapshot,
  never shown live. **`Process.Kill()` alone only terminates the tracked process, not descendants**
  -- a spawned child inheriting the redirected pipe can keep it open forever after the parent
  dies. Fixed via `taskkill /F /T /PID` (process-tree kill; .NET Framework has no
  `Process.Kill(entireProcessTree)` overload) PLUS an independent bounded final read
  (`Task.Wait($drainMs)`, 5000ms) as a second safety net -- confirmed as load-bearing via a real
  triple-lane CI failure (kill eventually succeeded, just 40-60s late against a 500ms test
  deadline) traced to TWO unbounded waits in the kill path itself (the blocking `taskkill.exe`
  invocation, and the trailing `$p.WaitForExit()`) -- both are now bounded to 5000ms each.

**Why the fail-fast probe default is 10000ms, not 5000ms**: a PyInstaller *onefile* EXE must first
extract its bundled runtime and boot an embedded interpreter before ANY user code (or its failure)
can run -- commonly 1-3+ seconds even on an idle machine. A 5000ms window produced a genuine CI
flake (`discardedAndRebuilt: true` on one run, `false` on the very next run of the SAME commit) --
a pure timing race, worsened by shared-runner contention or a Defender on-access scan. Widening is
unconditionally safe (a classification-only value, never a kill point) -- the only cost is a few
extra seconds before a genuinely broken cached EXE is recognized and rebuilt.

---

## `cache` lane Miniconda-corruption handling lives only in `batch-check.yml` YAML comments

The `cache` CI lane restores Miniconda from a GitHub Actions cache to skip the ~99 MB
download/install. Self-healing logic is documented nowhere except inline YAML comments -- read
this instead of re-deriving it from the workflow file.

**Cache key includes the pipreqs version, not just a source hash** (`hashFiles('run_setup.bat')`
busts on any bootstrapper edit; a `pipreqs_version` suffix busts on a pin change).
`restore-keys`' prefix fallback means a stale/partial-match cache can still restore.

**Three-layer anti-corruption chain, keyed on `HP_CACHE_CORRUPTED`:**
1. Health check on restore (`conda.bat info`) -- sets the flag on failure but `exit 0`s regardless
   (informational, never fails the step outright).
2. Bootstrap-failure fallback -- if `run_setup.bat` itself fails in this lane even with a
   healthy-looking cache, this ALSO sets the flag.
3. Skip path -- when the flag is set, later steps write placeholder NDJSON rows
   (`self.cache.corrupted`/`self.cache.bootstrap.failed`, both `pass:true`) and skip the rest of
   the battery, treating it as infra, not a product regression.

**Save-side guard prevents a "rolling corruption factory"**: the cache-save step ALSO requires the
flag be unset (plus its own fresh health check) -- a corrupted cache is NEVER re-saved, so
corruption cannot compound run over run; `restore-keys`' prefix fallback will eventually pick up a
healthy cache from before the corruption, or fall through to a fresh install.

If touching any of `batch-check.yml`'s cache-lane steps, preserve this chain exactly: the health
check stays non-fatal, `HP_CACHE_CORRUPTED` gates both the skip-path steps and the save step, and
the cache key keeps including a value that changes whenever the cached content's own recipe could
have changed.

---

## `uv add --script` / PEP 723 empirical `uv` behavior (shared foundation for two features)

Two features (the automatic `run_setup.bat`-integrated PEP 723 write-back, and the manual "PVW
QuickStart" workflow) both rely on the same empirically-confirmed (never assumed from docs) `uv`
facts, consolidated here once:

- **`uv add --script` performs a genuine targeted merge, not a rewrite** -- re-adding an
  already-pinned package by bare name does not downgrade the pin; a mix of already-pinned and new
  packages in one call preserves every existing pin; a hand-added custom TOML key survives
  untouched. This lets both features feed the full current dependency list to `uv add --script`
  every time and let `uv`'s own merge logic do the rest.
- **Exit code 2 means "malformed TOML" ONLY after a caller has ruled out uv's other two exit-2
  triggers** -- non-UTF-8 input, and a pip-style package directive (`-e`/`-r`/`--hash`) passed as a
  plain spec. Both this repo's callers pre-filter these (UTF-8 pre-check, `-`-prefixed line
  filtering) before treating exit 2 as a malformed-header signal -- a future caller without the
  same guards must not assume exit 2 means malformed TOML. A missing/misnamed file is exit 1, not
  exit 2.
- **A closing `# ///` fence with trailing whitespace fails to parse (exit 2)** -- astral-sh/uv#10918.
  Header-repair logic must tolerate this on the STRIP side even though `uv` won't tolerate it on
  write.
- **A stray/duplicate leftover fence line is itself a hard error on newer `uv`** -- astral-sh/
  uv#19544. Header-strip logic should be a line-by-line state machine (track `in_block`), not a
  regex that could under/over-match.
- **`VIRTUAL_ENV` set in the environment produces only a benign stderr warning, never a failure**
  -- astral-sh/uv#15956. Judge success/failure solely by exit code.
- **An existing `<script>.py.lock` sidecar is silently rewritten as a side effect, no suppress
  flag.**
- **Open caching issue -- astral-sh/uv#15156**: `uv add --script` then `uv run --script` on the
  SAME filename can serve a stale cached resolution even after the header changed (cache key is
  filename-derived; renaming fixes it). Confirmed to bite a real shipped call site
  (`tools/pvw_known_idempotent.py`'s retry paths) -- fixed via `UV_NO_CACHE=1` on retry-only calls
  (never the first attempt, to keep normal caching speed for the common case).
- **`Get-Content -Raw` silently replaces any invalid-UTF-8 byte with U+FFFD on read** -- corrupts an
  in-memory "original" backup before a risky operation, so a later "restore" can silently hand back
  an altered file. Fix: `[System.IO.File]::ReadAllText/WriteAllText` with
  `[System.Text.Encoding]::GetEncoding("ISO-8859-1")` (round-trips any file's bytes exactly, 1:1
  byte-to-char, regardless of real encoding).
- **A genuinely new dependency's written form depends on the `uv` version** (bare name on one
  version, an auto-resolved lower bound on a later one) -- neither feature should assume or
  document one specific form.

---

## `autopep723`'s own import-detection is environment-leaky under direct invocation, safe under `uvx`

`autopep723`'s own `get_builtin_modules()` walks `sys.path` of WHICHEVER process is currently
running it (`pkgutil.iter_modules()`) -- any package already installed in that process's own
environment is silently treated as "not third-party" and dropped from the discovered-imports
output, even though the target script genuinely needs it. Confirmed directly (a venv with only
`requests` pre-installed reported only `click` for a script importing both).

**Depends entirely on invocation method**:
- `uvx autopep723 check <file>` (an isolated `uv`-managed tool venv) is NOT fooled by an active
  `VIRTUAL_ENV` pointing at a dirty environment, but IS still fooled by a leaked `PYTHONPATH`.
- A DIRECT interpreter invocation (`python -m autopep723`, `conda run python -m autopep723`, or any
  invocation sharing the target script's own populated environment) is NOT protected at all.

**Practical rule: only ever invoke `autopep723` via `uvx`, never a direct/shared interpreter, and
only where `PYTHONPATH` is already known-clear.** This repo's pre-existing `set "PYTHONPATH="`
near the top of `run_setup.bat` (REQ-010 isolation) already satisfies the second condition for any
integrated use -- a design proposing direct invocation through a lane's own interpreter is NOT
safe as written.

**Also load-bearing**: `autopep723` has zero runtime dependencies and is strictly single-file, no
directory/glob mode -- passing a directory hits `IsADirectoryError`, caught and turned into an
EMPTY result with EXIT CODE 0 (not a failure). Any design invoking it against a directory rather
than the specific resolved entry file will silently produce zero discovered dependencies with no
error signal to branch on.
