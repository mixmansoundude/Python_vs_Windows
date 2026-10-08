# Field Report Triage -- Aug-Sep 2026 real-user runs (planning only)

**Status**: planning doc, no executable change. Filed 2026-10-08 from the maintainer's own
stream-of-consciousness notes on real (non-CI) bootstrapper runs dated 2026-08-17 through
2026-09-28, plus two outside AI analyses the maintainer forwarded (called "3rd party" and "4th
party" below; neither could run the code). Every claim below was re-checked against `main` at
`0f088b4` (2026-08-30). `main` has not changed since, so every note dated after 2026-08-30 was
observed on exactly this code.

The ranked backlog items live in CLAUDE.md's Active Backlog (Items 62-75), each one short and
pointing back here. This file holds the evidence, root causes, and the "do not add" list so a
future implementing agent does not re-derive them. Open maintainer decisions are in
`docs/open-questions.md`.

**Confidence labels**: **Confirmed** = reproduced or read directly in current code (line numbers
below are as of `0f088b4`; re-grep before editing). **Inferred** = the code makes the symptom
possible and it fits the notes, but the maintainer's exact files/logs were not available, so it
is a strong hypothesis, not a proof.

**Evidence gap**: this pass could not read CI job logs or the diagnostics site (the planning
session's network policy blocked `mixmansoundude.github.io` and the Actions log blob store), so
CI evidence comes from what CLAUDE.md/`docs/agent-ndjson.md` already record. No claim below
depends on a log this pass did not see.

---

## The big picture (why the Aug 17-Sep 1 runs went sideways)

Most of the painful notes trace back to ONE chain, not to many unrelated bugs:

1. **pipreqs silently found nothing** for the multi-file app (Item 63). Likely cause: pipreqs
   0.4.13 aborts the whole scan on the first file it cannot decode or parse, and the bootstrapper
   then treats "crashed" the same as "no imports".
2. With no `requirements.txt`, the **pandas -> xlsxwriter heuristic never fired** (it only looks
   at `requirements.txt`), so `xlsxwriter` was never installed up front.
3. **warnfix then installed nearly every optional dependency pandas mentions** (Item 64),
   because PyInstaller's warn file lists every lazy/optional import inside library code as
   "delayed", and `tools/parse_warn.py` treats all of those as required. That is the
   30-minute "rabbit hole" (pyarrow, numba, tables, sqlalchemy, PyQt...).
4. The same warn file also lists **stdlib and never-installable names** (`multiprocessing`,
   `tkinter`, `sqlite3`, `pyimod02_importers`, `java`, `AppKit`...) that `SKIP` does not cover.
   Each one is a guaranteed install failure, and "a repair install failed + something is still
   unresolved" is exactly the cascade trigger. So **the "try the next provider" prompt fired on
   noise** (Item 64), not on a genuine uv limitation. That is why it felt premature.
5. Installing every optional binding eventually put **both PyQt5 and PyQt6** in the env, which
   PyInstaller refuses to bundle ("multiple Qt bindings"). Nothing ever uninstalls, so each
   re-run made it worse (the "devolved" note).
6. When the program finally ran, its `ModuleNotFoundError: xlsxwriter` happened **inside a GUI
   callback**: the process kept running and exited 0, and the bootstrapper never reads the
   captured stderr of a run that exits 0 (Item 65). So the one signal that named the real
   missing package was ignored.

Fixing 63/64/65 attacks the chain at both ends: better discovery up front, far less noise in the
middle, and runtime evidence at the end.

---

## Ranked backlog

Rank is by user impact on the default double-click path, then confidence, then size. Every item
names the CI proof it needs, because the maintainer cannot hand-test (see "CI-first testing
policy" at the end).

### Item 62 -- PEP 723 extractor cannot read the header the bootstrapper itself writes (Confirmed, small)

**Symptom (2026-09-01)**: after the bootstrapper wrote a PEP 723 header into the user's file,
the next run printed `*** [WARN] PEP 723 block found but dependency list is empty or malformed;
falling back`, and no `~requirements.pep723.txt` existed.

**Root cause**: `:extract_pep723_requirements` in `run_setup.bat` only accepts a
dependency line that starts with exactly `# "` (one space) and only strips a trailing `"`:

```
if ($deps -and $trim.StartsWith('# ""')) { $item = $trim.Substring(3).Trim(); if ($item.EndsWith('""')) { ... } }
```

`uv add --script` (what REQ-005.11 write-back calls) writes the canonical form with four spaces
and a trailing comma. Verified with a real `uv add --script a.py requests xlsxwriter` on
2026-10-08:

```
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "requests>=2.34.2",
#     "xlsxwriter>=3.2.9",
# ]
# ///
```

A line-for-line Python simulation of the extractor gives: uv-written block -> `[]`; the CI
fixture in `tests/selftest.ps1` (`# "packaging"`) -> `['packaging']`; one-space-with-comma ->
`['packaging",']` (corrupted); single-line `dependencies = ["requests"]` -> `[]`. The CI fixture
even documents the limitation (`tests/selftest.ps1:1251`, "Extract subroutine expects exactly
"# " + quote (one space)"), which is why CI stayed green. `docs/demo-bootstrapper-output.md`
already shows the four-space form, so the repo's own demo is unreadable by its own extractor.

**Fix shape**: keep the line-oriented state machine. Strip the leading `#` and whitespace, then
accept any quoted item (single or double quotes), drop a trailing comma, and handle the
single-line `dependencies = [...]` form. Log how many entries were extracted; when zero, log
why (no `dependencies` key, empty array, unparsed line N). Prefer moving the logic into an
emitted helper (`.ps1` via `-File`, or Python) rather than growing the inline `-Command`,
per the lessons-learned rule about literal `"` in `-Command` text.

**CI proof**: a fixture whose header is byte-for-byte what `uv add --script` writes (CRLF
endings, since Windows users' files are CRLF), asserting `DEP_SOURCE=pep723` and the extracted
names; plus a genuine two-run test (run 1 writes the header via REQ-005.11, run 2 must read it
back). Keep the existing one-space fixture as a regression case.

**Outside analyses**: the 4th party got this right. The 3rd party's causes (`Get-Content` array
trap, `>=` eaten by cmd.exe, UTF-16 output) do not match the code: it is line-oriented by
design, the content never passes through cmd.exe, and it already writes `-Encoding ASCII`.

### Item 63 -- pipreqs crashes are reported as "no imports found" (Inferred cause, Confirmed mechanism, small)

**Symptom (Aug)**: a `main.py` that imports a sibling `adjacent.py` (which imports pandas,
PyPDF2, pdfminer, etc.) produced no `requirements.txt`; `~pipreqs.diff.txt` said
`(no diff: requirements files not both present)`, and pipreqs "said it detected nothing."

**Mechanism (Confirmed)**: pipreqs 0.4.13's `get_all_imports()` (read from the 0.4.13 wheel)
hard-codes `ignore_errors = False`, opens every `.py` under the folder with
`open(file_name, "r", encoding=None)` OUTSIDE its try block, and re-raises any parse error. So
ONE file in the folder that is not valid in the locale encoding or does not parse aborts the
whole scan with no output. `encoding=None` uses the locale encoding; on Western-locale Windows
without UTF-8 mode that is cp1252, and ordinary UTF-8 text
such as an emoji in a `print()` (very common in AI-written scripts) contains bytes cp1252 cannot
decode (checked: `"\U0001F50D"` fails on byte 0x8D). The bootstrapper does not pass
`--encoding`, and its result handling (the pipreqs result-handling block at
`:pipreqs_direct_done`) deliberately treats "nonzero exit + no output file" as "zero requirements: no imports found", with a comment
admitting a crash looks the same. The scan is already whole-folder (the 4th party is right that
it is not "only main.py").

**Why Inferred**: the maintainer's exact files were not available. A non-cp1252 character or a
non-parseable `.py` anywhere in the folder (the `pyimod02_importers` mention suggests files
extracted from a PyInstaller EXE may have been present) would produce exactly these symptoms.
See open question Q4.

**Fix shape**: (a) pass `--encoding utf-8` (or run the pipreqs call with `PYTHONUTF8=1`);
(b) when pipreqs exits nonzero, look for its `Failed on file:` line in `~pipreqs_direct.log`,
name that file in a `[WARN]`, and retry once with that file excluded rather than reporting zero
imports. `Failed on file:` is logged only for parse errors: the file is read before pipreqs'
try block, so a decode error (for example a cp1252-encoded `.py` once (a) forces UTF-8) aborts
with a bare traceback that names no file. So (b) also needs a pre-check that runs before
pipreqs: a few lines of Python that open each `.py` pipreqs would scan with its declared
encoding (`tokenize.open`, which honors a PEP 263 coding cookie and defaults to UTF-8) and
`ast.parse` it. pipreqs then scans a staged copy of the tree, not the original: every file that
passed is written there as UTF-8, and every file that failed is replaced by an empty `.py` of
the same name. pipreqs 0.4.13 treats any import that matches a `.py` filename in the scanned
tree as local, so the empty stub keeps `import adjacent` from becoming a false requirement
while contributing no imports of its own. pipreqs' `--ignore`
takes directories, not files, so it cannot do this exclusion. Each left-out file is named in a
`[WARN]` that also says the detected requirements may be incomplete. (c) Change the summary
note so a crash is never labeled "no imports found". The
`pipreqs.flags` CI gate locks invocation flags, so (a) must update that gate in the same change.
This is the narrow fix; the shelved "pipreqs internalization" idea in
`docs/agent-cold-storage.md` has a thaw trigger ("a real user run hits a pipreqs failure the
warnfix safety net doesn't cleanly cover") that this arguably meets, but the narrow fix should
come first.

**CI proof**: a fixture app with a UTF-8 emoji in one file; a cp1252 `.py` that declares
`# -*- coding: cp1252 -*-`, contains a non-ASCII byte and imports a real package; a cp1252 `.py`
with no coding cookie (not valid UTF-8); and a deliberately unparseable `.py`. Assert that the
imports from the first two files land in `requirements.auto.txt`, and that the WARNs name the
last two files. Have the entry file also `import` the unparseable file's module name, and
assert that name is not in `requirements.auto.txt`.

### Item 64 -- warnfix treats noise as required: stdlib names, non-PyPI names, and library-internal optional imports (Confirmed, medium)

**Symptoms (Aug)**: warnfix tried to install `multiprocessing`, `pyimod02_importers`, `java`,
`tkFileDialog`, `FileDialog`, `uu`, `gdbm`, `dumbdbm`, `test`, `imp`, `tkinter`, `sqlite3`,
`Foundation`, `AppKit`, `win32pdh`, `pygame`, `cppyy`, `mupdf_cppyy`, ... and succeeded at a
long list of pandas extras (pyarrow, numba, numexpr, tables, sqlalchemy, matplotlib, qtpy...).
It took more than 30 minutes, prompted for a provider cascade, and on later runs failed the
build on "multiple Qt bindings" (PyQt5 and PyQt6).

**Root cause (Confirmed in `tools/parse_warn.py`)**:
1. `SKIP` covers Unix-only modules and two Python-2 shims, but not the general stdlib. PyInstaller
   reports `from multiprocessing import X` as `missing module named multiprocessing.X`;
   `parse_warn` keeps only the top-level name, so stdlib `multiprocessing` becomes an install
   target. Same for `tkinter`, `sqlite3`, `test`, removed-stdlib names (`imp`, `uu`), Python-2
   names (`tkFileDialog`, `FileDialog`, `gdbm`, `dumbdbm`), other-platform names (`java` for
   Jython, `Foundation`/`AppKit` for macOS), and PyInstaller's own internals
   (`pyimod02_importers`). README REQ-005.9 already requires that "names known in advance to be
   un-installable ... are filtered out before any install is attempted", so this is a spec
   violation, not a new idea.
2. Every `(delayed)` / `(conditional)` entry is treated as required no matter WHO imports it.
   pandas, matplotlib and friends lazy-import dozens of optional backends; those lines say
   `imported by pandas.io...`, not `imported by <user module>`.
3. `:warnfix_cascade_detect` marks a cascade candidate when something is still unresolved AND a
   repair install failed. Point 1 guarantees both on almost any real app, so the cascade prompt
   fires on noise. This is the actual reason the prompt "felt premature" (the 4th party said
   the cascade design was already settled; true, but the trigger is being fed garbage).
4. `win32pdh` belongs to `pywin32` but is missing from `TRANSLATIONS`.

**Fix shape** (one item, can ship in slices): filter with `sys.stdlib_module_names` evaluated
under the build interpreter (3.10+, guarded per the embedded-helper baseline rule) plus a small
curated never-installable list (`pyimod*`, `java`, `Foundation`, `AppKit`, Python-2 names);
skip `X.attr` entries whose top-level `X` already resolves via `find_spec`; only treat
`delayed`/`conditional` entries as required when the importer is one of the user's own modules
(library-internal optional imports stay optional unless runtime evidence from Item 65 names
them); add `win32pdh` (and other `win32*` modules) to `TRANSLATIONS`. Keep the REQ-005.8
heuristics as the curated way to pull in the optional extras that matter (openpyxl, xlsxwriter).
Watch the interaction with `selfapps_warnfix*.ps1` and `self.layered_e2e.chain`, which rely on
real warnfix installs; and with the still-open Item 35 sub-item about `self.cascade.exec`
falling through to embed, which this noise may also explain.

**CI proof**: a pandas app with no `requirements.txt` asserting no stdlib/never-installable name
is attempted, total install attempts stay small, no cascade candidate is raised, and the EXE
still builds; a `test_parse_warn.py` table covering each new filter rule.

### Item 65 -- Runtime `ModuleNotFoundError` is ignored when it does not change the exit code (Confirmed, medium)

**Symptom (Aug)**: the GUI launched from the interpreter, but clicking through it raised
`ModuleNotFoundError: No module named 'xlsxwriter'`. The console showed the traceback and the
fail-fast probe line, and nothing acted on it. "How are we supposed to capture the module not
found error and fix the env?"

**Root cause**: `:verify_no_exe_interpreter` and the fast path record only the exit
code; nothing parses `~run.err.txt`. Tkinter catches exceptions raised in callbacks, prints the
traceback to stderr, and keeps running, so the process can exit 0 with the real answer sitting
in stderr. `:exe_smokerun_hints` does parse `No module named` on the EXE side, but only as a
`--hidden-import` hint, and `:hidden_import_recover` deliberately acts only on modules that are
already installed. A missing, not-installed package named at runtime has no repair path.

**Fix shape**: slice 1 (diagnostic only): after every real run (EXE smoke, interpreter run, fast
path), scan the captured stderr for `ModuleNotFoundError: No module named 'X'` regardless of exit
code; when X is not installed in the env, say so plainly in the console and the post-flight
panel ("Your program needed X, which is not installed; add X to requirements.txt and re-run"),
and emit an NDJSON row. Slice 2 (needs Q2): automatically install X into the env, add it to
`requirements.txt` (or the PEP 723 header), and rebuild, without re-running the user's program
unasked. The 4th party's caution about auto-rerunning user code is right; REQ-018 governs it.

**CI proof**: a tkinter-free fixture that catches the `ImportError` itself, prints the traceback
to stderr, and exits 0, asserting the new message and row appear and name the module.

### Item 66 -- Remember the provider that actually worked (Confirmed gap, medium)

**Symptom**: after a run that only worked once cascaded to conda, every later run (for example
after editing `requirements.txt`) starts over in uv and redoes all the uv work before offering
conda again, and the 30-second cascade prompt is easy to miss.

**Root cause**: provider order always starts at uv. `tools/env_state.py` stores `envMode` but its
validity check rejects anything not `conda`, and the env-state fast path only reuses a conda
env; nothing records "uv failed here, conda succeeded".

**Fix shape**: write a small state file (keep it separate from `~env.state.json`) only when a
cascade-reached provider produced a verified successful run; on the next run, start at that
provider if it is still available, and log that it did so. Fall back to normal order if the
state is stale or the provider is missing. `HP_FORCE_CONDA_ONLY` stays CI/test-only per REQ-019
(see Q3). Items 63-64 should shrink how often this matters, so it ranks after them.

**CI proof**: a two-run test where run 1 is forced through the uv-to-conda cascade and run 2
(after touching `requirements.txt`) must log the remembered provider and skip uv.

### Item 67 -- `%1` that is not an existing `.py` is silently mishandled (Confirmed, small)

**Symptom (2026-08-31)**: `run_setup.bat arg1 arg2` (entry file forgotten) gave "compile errors"
for a file that runs fine, and the existing EXE was deleted.

**Root cause**: `:determine_entry` accepts `%1` as the entry if the path merely
EXISTS (any extension, so an input `.csv`/`.pdf` passed first becomes the "entry"), and silently
falls back to auto-detection if it does not exist. Separately, `HP_APP_ARGS` always starts at
`%2`, so the user's real first argument is dropped; the fast-path EXE then receives the wrong
arguments, can fail fast, and the discard-and-rebuild logic deletes a perfectly good EXE.

**Fix shape** (see Q1 for the one policy choice): if `%1` is given, it must resolve to an
existing `.py` in the bootstrapper folder, either as typed or by appending `.py`. Otherwise stop
before the fast path with a short usage message (`run_setup.bat <your_script.py> [args...]`)
and change nothing on disk. Never fall back silently.

**CI proof**: rows for `%1` = `main` (resolves to `main.py`), `%1` = an existing `.csv` (stops,
EXE untouched), `%1` = a missing name (stops, EXE untouched).

### Item 68 -- Small honest-wording fixes (Confirmed, tiny, one PR)

Each was checked against current text:
- **Fail-fast probe line prints milliseconds**: `:run_failfast_probe` prints `still running
  after %HP_FAILFAST_PROBE_MS%ms` (shows `10000ms`). Print seconds. The 4th party's "already
  fixed" is wrong: the default was fixed, the wording was not.
- **Nuitka fallback says "this may take a minute or two"** (`:try_nuitka_tier_a`) while a real build took
  about an hour with output only in `~setup.log`. Say it can take a long time for large apps
  (tens of minutes or more) and that progress is in `~setup.log`. Same for the
  optimized-build message in `:offer_optimized_build`.
- **`~pipreqs.diff.txt` placeholder** (in `:after_pipreqs_run`) `(no diff: requirements files not both
  present)`: name which file was missing.
- **Cascade prompt wording** (`:cascade_consent_gate`): say which provider is next ("Try conda
  instead of uv?") and that the current build will still be checked first. After an approved
  cascade the current uv build is still verified before the switch, which is why a later line
  said `current provider: uv` (the 4th party is right that `HP_ENV_MODE` is updated; it just
  happens after that verification). Log one line at approval time: "Cascade approved; finishing
  checks on the uv build, then switching to conda." Re-check after Item 64, since most noisy
  prompts should disappear.
- **Silent rebuild when sources changed**: `:try_fast_exe` exits silently when the hash is not
  fresh. Print one line saying the EXE is being rebuilt because inputs changed (naming the
  changed file if `tools/fast_check.ps1` can report it cheaply).
- **Dead pipreqs auto-detect WARN**: `DEP_SOURCE` is initialized to `unknown` near the top of the file
  (right after the preflight self-check), so `if not defined DEP_SOURCE` in
  `:after_env_mode_selection` can never fire; the "Dependencies were auto-detected
  via pipreqs / Consider adding requirements.txt" lines are unreachable and
  `dependency_source.txt` says `unknown` instead of `pipreqs`. (So the hint the maintainer
  remembers seeing with a `requirements.txt` present did not come from this line on current
  code.) Gate on `"%DEP_SOURCE%"=="unknown"` instead. `tests/harness.ps1`
  `batch.req005.warn_gate` checks only the text, so update it to check behavior.

### Item 69 -- Post-flight "run it yourself" command fails when pasted into PowerShell (Inferred, tiny)

**Symptom**: the briefing's `"C:\...\python.exe" "main.py"` failed when typed manually; dropping
the quotes worked.

**Cause (Inferred)**: that line is valid in Command Prompt. In PowerShell (the default shell in
Windows Terminal on Windows 11) a quoted string at the start of a line is an expression, not a
command, and fails with "Unexpected token"; PowerShell needs `& "C:\...\python.exe" "main.py"`.
Removing the quotes only worked because the path had no spaces. So do NOT remove the quotes
(both outside analyses' instincts there were half right). Show both forms, labelled
"Command Prompt:" and "PowerShell:". Confirm the shell with Q5 before changing.

### Item 70 -- PyInstaller hints the user cannot act on (Confirmed, small)

The `[HINT][DATA_FILE] Consider adding: --add-data X;.` and `[HINT][HIDDEN_IMPORT] Consider
adding: --hidden-import=X` lines name PyInstaller flags, but every PyInstaller build command (the
fresh build, the warnfix rebuild, and the two repair-loop rebuilds) builds from the `.py` with a fixed flag set, so there is nowhere for a user to
"add" them (an edited `.spec` is regenerated by `-y`). Either reword the hints into actions a
user can take (the CWD-relative branch added in PR #470 already does this for data files), or
add one supported way to pass extra PyInstaller flags (a `PVW_` super-user override, per
REQ-019). The CWD half of the Aug 27 report is already fixed (see "Already fixed" below).

### Item 71 -- Builder choice for power users (Confirmed gap, medium)

The maintainer needed test-only flags (`HP_TEST_FORCE_PYINSTALLER_FAIL`) plus deleting the EXE
by hand to get a Nuitka build. Add a `PVW_BUILDER=auto|pyinstaller|nuitka|both` super-user
override (absence = today's behavior, REQ-019). For `both`, never replace a verified EXE with
an unverified one, reusing `:offer_optimized_build`'s build-to-temp-then-swap pattern. A
user-facing prompt to pick a builder is a separate decision (Q6); leave the default order
alone until Tier B matures, as the notes say.

### Item 72 -- Nuitka long-build visibility and slow first launch (Investigation, medium)

Beyond Item 68's wording: (a) consider a heartbeat line every few minutes while Nuitka runs
(for example, the size of `~setup.log` or the last Nuitka progress line), but only if it can be
done without locking the log and without new moving parts; drop it if it gets fragile.
(b) The ~60 s first-launch delay with Defender at 100% CPU is real but its cause is not
established. Note that Nuitka `--onefile` also self-extracts to a temp folder on every launch
(the 3rd party's "single native binary" explanation is wrong for this build mode), so a large
scipy/pandas app extracts and gets scanned each launch. A cheap experiment is Nuitka's
`--onefile-tempdir-spec` pointing at a stable cache folder so only the first launch pays. Do
not adopt the 3rd party's "signing is the only fix" claim. (c) Long C compiles on
`scipy.stats` and similar are expected Nuitka behavior; record the observed hour as a data point
in `docs/prd-av-safe-build-path.md` rather than "fixing" it.

### Item 73 -- PEP 723 write-back failure hides uv's own error (Confirmed, tiny)

`[WARN] REQ-005.11: PEP 723 header write-back failed (ERROR:uv_rc_1)` gives no reason because
`tools/pep723_writeback.py` captures uv's stderr and discards it (`rc, _stderr = run_uv_add(...)`).
Log the last few lines of uv's stderr to `~setup.log`. Likely cause in the maintainer's run
(Inferred): `requirements.txt` held names that do not exist on PyPI (noise from Item 64), and
`uv add` fails resolution with exit 1. Items 64 and 62 should make this rare; the logging makes
the next one diagnosable.

### Item 74 -- Get the test example apps without running the whole suite (Confirmed gap, small, low priority)

Most CI fixture apps are generated inline inside `tests/selfapps_*.ps1`, so there is no folder
of ready-made example `.py` files to drop next to `run_setup.bat`. Add a small, curated
`tests/fixtures/` (or a `tools/` script that writes them out) holding a handful of the real
scenario apps (stdlib only, pandas+Excel, a GUI that exits, multi-file with a sibling import),
and have the CI scenarios read from it so the files stay honest. Keep it out of `run_setup.bat`
(the bootstrapper's own payload sync is for its helpers, not test data). Ranked last because it
is a convenience, but it also makes Item 75's real-app scenarios cheaper.

---

## Already fixed or working as designed (do not add)

- **CRLF on raw download**: fixed (`-text` attributes, `tools/check_crlf.py`, startup
  self-check). The Aug 17 run confirms it.
- **EXE runs from a different folder than the `.py` (Aug 27)**: fixed in PR #470 on 2026-08-29,
  two days after that note (`:run_exe_smokerun` now uses the app root;
  `tests/selfapps_exe_cwd_consistency.ps1` proves fast path and fresh build agree). The two
  remaining `pushd dist` sites are deliberate and documented.
- **Fast path ignores `%1`**: confirmed and accepted by the maintainer (fast path runs before
  entry selection). Now documented in README REQ-026. Item 67 changes what happens when `%1`
  is not a real `.py`; see Q1 for how that interacts.
- **Self-modifying programs and the fast path**: accepted limitation, now in README Known
  Limitations. The freshness hash is written at the end of a build run, after the verification
  run has already rewritten the sibling `.py`, so the next run can reuse an EXE built from the
  pre-rewrite source, and later runs can alternate between reuse and rebuild. That explains at
  least one "rebuilt even though I edited nothing" run.
- **Exe kept for `HP_SKIP_ENTRY_SMOKE` / `HP_TEST_FORCE_PYINSTALLER_FAIL` when `dist\<env>.exe`
  exists**: correct; those flags affect builds, and a fresh, cached EXE skips the build. The
  post-flight briefing already says to delete the EXE for a fresh build.
- **requirements.txt edits not "obeyed"**: they were obeyed (the run that finally worked came
  from that edit). User-written lines are deliberately not rewritten with version pins; only
  pipreqs output gets `~=` pins. The bare `xlsxwriter` after a blank line is the REQ-005.8
  heuristic appending its additions (`tools/prep_requirements.py` writes
  `'\n' + '\n'.join(added)`); cosmetic, and a version pin there buys nothing.
- **"force conda never writes requirements.txt"**: expected. With pipreqs producing nothing
  (Item 63), the only other writer is the autopep723 merge (REQ-005.12), which is uv-only by
  design; PEP 723 write-back is uv-only too. Item 63 fixes the real gap for both providers. Do
  not add a `pip freeze > requirements.txt` step (the 3rd party's idea): it would replace the
  user's intent with a full transitive snapshot.
- **`--hidden-import=xlsxwriter` whenever pandas is present** (3rd party): no. The pandas
  heuristic already installs xlsxwriter when pandas is known, and PyInstaller's pandas hook
  handles the import once the package is installed; the real gap was discovery (Items 63-65).
- **`SyntaxWarning: invalid escape sequence` from site-packages**: upstream packages' own
  warnings under newer Python; not a bootstrapper problem and not a sign of a bad env.
- **`pip` "not defined" in the REPL**: `pip` is a command, not a Python name. From a Command
  Prompt run `"<env python>" -m pip freeze` (for a uv env, `uv pip freeze --python "<env
  python>"`). Not a bug; maybe worth one line in the post-flight panel later.
- **"Visual C++ redistributable not installed" warnings**: informational from PyInstaller; the
  run worked. Revisit only if a real DLL load failure is seen.
- **"Move the cascade prompt until after the interpreter run"** (3rd party): no. The prompt
  firing on noise is the real defect (Item 64); the gate design itself was already reviewed
  (`docs/agent-closed-backlog.md` Known Findings).
- **pipreqs "only scanned main.py"** (3rd party): wrong; it scans the whole folder. The real
  issue is that one bad file aborts the scan (Item 63).
- **Defender/Nuitka "looks like malware, signing is the only fix"** (3rd party): unsupported;
  see Item 72.

---

## CI-first testing policy for these items

The maintainer has almost no hands-on Windows time, so "it works on the first real run" has to
be proven in CI. For every item above:

1. Each fix lands with a Windows CI scenario that reproduces the ORIGINAL symptom first (red on
   the old code, where practical) and then passes.
2. Prefer fixtures that copy real-world shape over sanitized ones: the exact bytes `uv` writes,
   CRLF line endings, a multi-file app, a GUI-style "swallow the exception and exit 0" app, a
   UTF-8 emoji in source.
3. Add second-run scenarios wherever a feature writes state the next run reads (PEP 723
   write-back, provider memory, fast-path hash). Several of these bugs only exist on run two.
4. Item 75 (below) is the umbrella for the reusable pieces.

### Item 75 -- Real-app regression scenarios in CI (umbrella, medium)

Add a small set of end-to-end scenarios modelled on the maintainer's real runs, each asserting
on intermediate files and log lines, not just exit code: (a) multi-file pandas+Excel app with no
`requirements.txt` (Items 63-65); (b) the same app run twice with a `requirements.txt` edit in
between (Items 62, 66); (c) `%1` misuse cases (Item 67). Respect Item 35's process discipline:
new rows start non-gating and soak before being promoted.
