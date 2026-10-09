# Field Report Triage -- Aug-Sep 2026 real-user runs (planning only)

**Status**: planning doc, no executable change. Filed 2026-10-08 from the maintainer's own
stream-of-consciousness notes on real (non-CI) bootstrapper runs dated 2026-08-17 through
2026-09-28, plus two outside AI analyses the maintainer forwarded (called "3rd party" and "4th
party" below; neither could run the code). Every claim below was re-checked against `main` at
`0f088b4` (2026-08-30). `main` has not changed since, so every note dated after 2026-08-30 was
observed on exactly this code.

The ranked backlog items live in CLAUDE.md's Active Backlog (Items 62-78), each one short and
pointing back here. This file holds the evidence, root causes, and the "do not add" list so a
future implementing agent does not re-derive them. Open maintainer decisions are in
`docs/open-questions.md`.

**Confidence labels**: **Confirmed** = reproduced or read directly in current code (line numbers
below are as of `0f088b4`; re-grep before editing). **Inferred** = the code makes the symptom
possible and it fits the notes, but the maintainer's exact files/logs were not available, so it
is a strong hypothesis, not a proof.

**CI evidence (read 2026-10-09)**: the first planning pass could not reach the diagnostics site or
the Actions log store. A second pass read the last complete runs (workflow run `37733140007` for the
per-lane NDJSON and test logs, and run `37878641926` on the diagnostics site; both are docs-only
heads of the planning PR, so they exercise the same bootstrapper code as `main`). `real`,
`conda-full`, `justme-test`, `contract-uv`, `contract-uv-fail` and `uv-dl-fallback` are fully
green; the only failing rows are the three already recorded under CLAUDE.md Item 35 (`cache`
`self.exe.smokerun`; `uv` `self.cascade.exec` and `self.exe.warnfix.venv_repair`). Nothing in the
CI results changes the ranking. Two items are confirmed by real CI logs (see "CI confirmation"
under Items 62 and 64). Every claim below that is not marked "CI confirmation" still comes from
reading code, not from a CI log.

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

**CI confirmation (2026-10-09)**: in the `real` (uv-first) lane of run `37733140007`, the second
bootstrap in `selfapps_exefastpath` (`~exefastpath_run2.log`) and the rebuild in `selftest_depcheck`
(`~depcheck_rebuild.log`) both print `PEP 723 block found but dependency list is empty or
malformed; falling back` right after run 1 logged `REQ-005.11: PEP 723 header write-back succeeded
via uv add --script`. So the defect already fires on every second run in CI; a regression test only
needs to assert that line is absent after a write-back. It also means a header written by run 1 is
ignored on run 2, so if pipreqs finds nothing on run 2 (Item 63) the recorded dependencies are lost.

**Outside analyses**: the 4th party got this right. The 3rd party's causes (`Get-Content` array
trap, `>=` eaten by cmd.exe, UTF-16 output) do not match the code: it is line-oriented by
design, the content never passes through cmd.exe, and it already writes `-Encoding ASCII`.

### Item 63 -- pipreqs crashes are reported as "no imports found" (Confirmed mechanism and cause, small)

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

**Why Inferred (as of the August run)**: the maintainer's exact files were not available. A non-cp1252 character or a
non-parseable `.py` anywhere in the folder (the `pyimod02_importers` mention suggests files
extracted from a PyInstaller EXE may have been present) would produce exactly these symptoms.

**Maintainer answer (Q4, 2026-10-09, resolved)**: no non-English text was knowingly in the folder.
The folder probably held a `.pdf`, a `.xlsx`, and possibly one or two more `.py` files. Non-`.py`
files do not affect pipreqs, since it only scans `.py`. The `.py` files are the only ones at risk,
and the pre-check below covers them. The maintainer also asked that the bootstrapper report what
it found, so the next failed run shows the likely cause in its log. **Added to the fix shape:**
log one line per `.py` file scanned, giving its declared or detected encoding and whether it
parsed, plus a count of other file types left out of the scan. This is informational only and
does not change the scan result.

**Second real run (maintainer, 2026-10-09, field evidence, supersedes "Inferred" above)**: on the
maintainer's real folder `~pipreqs_direct.log` ends with `UnicodeDecodeError: 'charmap' codec can't
decode byte 0x9d in position 6291: character maps to <undefined>`, raised from a bare `f.read()`
inside pipreqs, with no file named. That is the mechanism above, and it is a decode error, so no
`Failed on file:` line exists (checked in the 0.4.13 wheel: that line is logged only inside the
`except` around `ast.parse`). The message text reproduces exactly with `b"\xe2\x80\x9d".decode(
"cp1252")` (checked 2026-10-09). 0x9D is one of the five bytes cp1252 leaves undefined (0x81,
0x8D, 0x8F, 0x90, 0x9D). The most common character that ends in 0x9D is U+201D, the right curly
double quote (`E2 80 9D`) that word processors and chat assistants put in comments and strings.
The other curly quotes decode silently as mojibake (`E2 80 98`, `99`, `9C` all map), so a file
full of curly quotes can pass while one containing U+201D aborts the scan. Other UTF-8 characters
that end in 0x9D (U+221D, U+1F49D) and the emoji case already above (0x8D) fail the same way.
Because cp1252 cannot even represent 0x9D, the offending file has to be valid UTF-8, not a cp1252
file.

**Cause confirmed on the maintainer's own folder (2026-10-09, later the same day)**: the maintainer
scanned the folder with a decode check and found the file. It is valid UTF-8 (Notepad++ shows
UTF-8), has no encoding cookie, and holds both a left and a right curly double quote, on two
different lines, inside regex lines of the shape `data = re.sub(r'<U+201D>', '"', data)` that
normalize smart quotes in text extracted from a PDF. Only the right quote (`E2 80 9D`) is
undecodable under cp1252, which is why the left one on the other line did no harm. The code is
fine; pipreqs' cp1252 read is the whole fault, and nothing but `--encoding utf-8` (or the staged
UTF-8 copy) is needed to clear it. The scan found exactly one failing file, `adjacent.py`, with
the undecodable byte at offset 6291 (line 190). That matches the traceback's `position 6291`
exactly (`f.read()` decodes the whole file in one call, so the position is the file offset), so
traceback and file are the same event. `adjacent.py` is also the sibling the August symptom names
as the one holding the real imports (pandas, PyPDF2, pdfminer), which is why the crash hid exactly
the dependencies that mattered. The shape matters for the fixture: a smart-quote cleanup like
this is ordinary for any script that handles PDF or word-processor text, so expect it from other
users too. The scan was done with a one-off script, not the bootstrapper, because the bootstrapper
still cannot name the file; the per-file informational line above is what removes that need.

**Visibility gap seen in the same run**: `no imports found` appears in `~pipreqs.summary.txt` but
not in `~setup.log`. `~setup.log` only gets `[DEBUG] pipreqs (direct) rc=<n> size=missing` from
`:pipreqs_direct_done`; the summary note text is written only by `:write_pipreqs_summary`. A user
reading the setup log therefore never sees that pipreqs crashed. The fix shape below covers it.

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
`[WARN]` that also says the detected requirements may be incomplete. The scan is whole-tree, so
archived subfolders are pre-checked and staged too (scan scope decided under Item 78). (c) Change the summary
note so a crash is never labeled "no imports found", and put the same words in `~setup.log` and
on the console as a `[WARN]` that points at `~pipreqs_direct.log`, followed by the traceback's
last line. That last line (for example `... character maps to <undefined>`) contains `<` and `>`,
so it must reach the log through a file append (`findstr`/`type` into `%LOG%`), never through
`:log "..."`, which echoes unquoted (see `docs/agent-lessons-learned.md`). The
`pipreqs.flags` CI gate locks invocation flags, so (a) must update that gate in the same change.
This is the narrow fix; the shelved "pipreqs internalization" idea in
`docs/agent-cold-storage.md` has a thaw trigger ("a real user run hits a pipreqs failure the
warnfix safety net doesn't cleanly cover") that this arguably meets, but the narrow fix should
come first.

**CI proof**: a fixture app with a UTF-8 emoji in one file; a second UTF-8 file shaped like the
maintainer's real one (confirmed 2026-10-09): valid UTF-8, no coding cookie, `import re` plus an
import of a real package, and a raw-string regex line holding the right curly double quote U+201D
(for example `re.sub(r'<U+201D>', '"', data)`, written with the real character) and another
holding the left one U+201C. Under cp1252 only the right quote fails (on 0x9D), so this must be its
own fixture, not folded into the emoji one, and a version with only left quotes would pass today
and prove nothing; a cp1252 `.py` that
declares `# -*- coding: cp1252 -*-`, contains a non-ASCII byte and imports a real package; a cp1252
`.py` with no coding cookie (not valid UTF-8); and a deliberately unparseable `.py`. Assert that
the imports from the first three files land in `requirements.auto.txt` and that no WARN names
them, and that the WARNs name the last two files. Have the entry file also `import` the
unparseable file's module name, and assert that name is not in `requirements.auto.txt`. Also
assert that a crashed scan is never summarized as `no imports found` in either
`~pipreqs.summary.txt` or `~setup.log`. Alongside the CI scenario, a cross-platform unit test of
the pre-check helper (new `tests/test_pipreqs_precheck.py`) pins the same cases without needing a
cp1252 Windows locale, including `b"\xe2\x80\x9d"` decoded under cp1252 raising and under UTF-8
passing. The test lands first and must be red before the fix (rule in `AGENTS.md`).

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

**CI confirmation (2026-10-09)**: `tests/selfapps_collect.ps1` (a plotly-only app, `real` and
`conda-full` lanes, `~selftest_collect/~setup.log` in run `37733140007`) shows the storm without
any pandas or GUI code: warnfix installs pyarrow, polars, pandas, numpy, sqlframe, duckdb,
pyspark, ibis, dask, modin, scikit-image, statsmodels, sphinx, kaleido, ipywidgets, anywidget and
traitlets, and tries to build cupy and cudf (both fail), over about five minutes. They are plotly's
lazy optional backends, surfaced because `--collect-submodules=plotly` makes PyInstaller import
every plotly submodule. Every one is imported by `plotly.*`, not by the user's module, so the
importer rule in the fix shape removes them. That scenario is also a ready place for the "small
install count" assertion below.

**Second real run (maintainer, 2026-10-09)**: the same folder as Item 63's second run produced the
same pattern. The PyInstaller warn-file copy (`~warnfile.txt`) held about 25 `missing module`
lines and one `excluded module named _frozen_importlib`; warnfix tried to install
`pyimod02_importers` and `multiprocessing` (both failed) and succeeded for `future`, pandas,
pdfminer, pymupdf and PyPDF2; the cascade prompt then timed out to "no" (its 30-second default).
Reproduced without CI on 2026-10-09: `parse_warn_file` over sample lines in the 6.x format returns
`multiprocessing`, `pyimod02_importers`, `tkinter` and `AppKit` as install targets, so point 1 is
live on current code. The `excluded module named _frozen_importlib` line needs no fix: both
matchers in `parse_warn.py` look only for `W: no module named` or `missing module named`, so an
`excluded module` line is never an install candidate (pin that with a table case so a future
regex change cannot start installing it). The packages that did install (pandas, pdfminer,
pymupdf, PyPDF2, `future`) are exactly the real dependencies that Item 63's crashed pipreqs scan
should have written to `requirements.txt` up front, which is the chain in "The big picture".

**The two failures, in the maintainer's words from the console and `~setup.log` (2026-10-09, uv
env on Python 3.14.8; the console showed only pass or fail, the reasons are in the log)**:
- `pyimod02_importers` (a `(delayed)` entry): uv reported "No solution found when resolving
  dependencies ... `pyimod02-importers` was not found in the package registry and you require
  `pyimod02-importers`, we can conclude your requirements are unsatisfiable", then "repair failed".
  The name is PyInstaller-internal and exists nowhere on PyPI.
- `multiprocessing` (stdlib): uv did find a package of that name on PyPI, the Python-2-era backport
  `multiprocessing==2.6.2.1`, and failed to build it ("The build backend returned an error ...
  `setuptools.build_meta:__legacy__.get_requires_for_build_wheel` failed", from its `setup.py`:
  `print 'Macros:'`, "SyntaxError: Missing parentheses in call to 'print'"). So asking PyPI whether
  a name exists cannot replace the stdlib list: a stdlib name can resolve to an unrelated, broken
  old package. That is one more reason the filter must use `sys.stdlib_module_names` (guarded per
  the embedded-helper baseline) and not an install attempt.
These two are the Item 64 fixture: a `test_parse_warn.py` case with `missing module named
pyimod02_importers - imported by pkg_resources._vendor... (delayed)` and `missing module named
multiprocessing.X - imported by ... (top-level)` that must produce no install target. Nothing else
in the long list needs retyping; the real dependencies that installed (`future`, pandas, pdfminer,
pymupdf, PyPDF2) are the expected positives of Item 63's staged scan.

**CI proof**: a pandas app with no `requirements.txt` asserting no stdlib/never-installable name
is attempted, total install attempts stay small, no cascade candidate is raised, and the EXE
still builds; a `test_parse_warn.py` table covering each new filter rule, including the
`excluded module named` negative case above and the two fixtures just described.

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
and emit an NDJSON row. Slice 2 (decided 2026-10-09, option B: one consent prompt before any install, requirements edit, or rebuild; a yes also covers one verification run): install X into the env, add it to
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
state is stale or the provider is missing. `HP_FORCE_CONDA_ONLY` stays CI/test-only per REQ-019.
Items 63-64 should shrink how often this matters, so it ranks after them.

**Decided 2026-10-09 (Q3, option B): add a super-user switch `PVW_PROVIDER=conda`.** Unset means
no change at all, so a double-click user never sees it. It is the only `PVW_` variable that picks
a mode rather than a path; it follows the `PVW_CONDA_EXE` pattern (explicit variable, a `[DEBUG]`
override log line). The value `conda` is the existing internal `HP_ENV_MODE` name, and conda is
the most capable provider: the default order (uv, then conda, then embed, venv, system) is about
speed and fallbacks, and a conda solve failure is rarely fixed by a later tier.

**Edge cases the implementation must cover (each needs a CI row):**
1. Unset: byte-for-byte the current behavior (REQ-019).
2. Any value other than `conda` (typo, `Conda`, `miniconda`): stop with an `[ERROR]` that lists
   the accepted value. Never silently fall back to the normal order.
3. Forced conda with Miniconda not yet installed (a uv-first run skipped it): acquire Miniconda
   through the normal conda path. Do not try uv first, even if uv is available.
4. Forced conda while Item 66's memory says uv: the flag wins for that run. Memory changes only
   after a verified run, so a failed forced run leaves memory alone.
5. Forced conda with an existing `.uv_env` or a valid uv venv: do not reuse the uv venv. The run
   must build or reuse a conda env.
6. Forced conda with an exact patch pin from an earlier uv run (the runtime.txt write-back case
   in `docs/agent-interconnect.md`): `HP_CONDA_PYSPEC_USE` must still drop the write-back pin, or
   the solve fails for a reason the user cannot see.
7. Cached EXE fast path: it runs before provider selection, so a valid cached EXE is reused and the
   switch has no effect. The README must say so, the same way REQ-026 does for `%1`.
8. `HP_FORCE_CONDA_ONLY` (CI) and `PVW_PROVIDER` set together: behave as `HP_FORCE_CONDA_ONLY`
   does (no fallbacks). The two must not conflict or double-log.
9. Conda alive but the solve fails under the switch: stop with the conda error and a hint to run
   without `PVW_PROVIDER` (decided 2026-10-09, Q8: stop, no silent cascade).
10. Logging: the value is checked against a fixed list before any `:log` call, so nothing
   unsafe reaches the echo (see the `:log` lesson).
11. Memory use is always visible: when a run starts at the remembered provider, the console says
   so, names the provider, and says how to reset it (delete the state file, or set
   `PVW_PROVIDER`). Nothing is picked from memory silently.

**Memory invalidation (decided 2026-10-09):** the state file is replaced after a verified run,
and it is cleared automatically when the same inputs that rebuild the EXE change
(`requirements.txt`, `pyproject.toml`, `runtime.txt`, source `.py`), when the remembered provider
is no longer available, and never by a failed or declined run. `PVW_PROVIDER` overrides it for one
run and writes nothing. Deleting the file is always a valid manual reset. Users do not need to
delete it in normal use.

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

**Fix shape** (policy decided 2026-10-09: validate and stop; program arguments are optional): if `%1` is given, it must resolve to an
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
- **Running the env interpreter with no script opens a Python prompt (second report,
  2026-10-09)**: the maintainer ran the printed interpreter path without `main.py`, got a `>>>`
  prompt, and read "`pipreqs` and even `pip` is not defined" as "not installed in that env". They
  are commands, not Python names; there is nothing wrong with the env. The post-flight panel
  that prints the run command should add one line: "Running the interpreter with no script
  opens an interactive prompt; to run pip use `"<python>" -m pip ...`." (This is the "one line in
  the post-flight panel later" from the do-not-add list; it is cheap enough to do here.)

### Item 69 -- Post-flight "run it yourself" command fails when pasted into PowerShell (Inferred, tiny)

**Symptom**: the briefing's `"C:\...\python.exe" "main.py"` failed when typed manually; dropping
the quotes worked.

**Cause (Inferred)**: that line is valid in Command Prompt. In PowerShell (the default shell in
Windows Terminal on Windows 11) a quoted string at the start of a line is an expression, not a
command, and fails with "Unexpected token"; PowerShell needs `& "C:\...\python.exe" "main.py"`.
Removing the quotes only worked because the path had no spaces. So do NOT remove the quotes
(both outside analyses' instincts there were half right).

**Field-note wording (verbatim, late Aug)**: "The post-flight debriefing stated
"C:\...\miniconda3\...\python.exe" "main.py" but it seems like the quotes are offending when I
try to run it with both wrapped in quotes like that manually. ... If I drop all the quotes, then it
works." The same note says the quotes around `python.exe` look like the problem and suggests the
hint should say so.

**Maintainer answer (Q5, 2026-10-09, resolved)**: the command was pasted into Command Prompt, not
PowerShell. PowerShell was used only for the PEP 723 work. So the PowerShell theory above does not
fit the report.

**What the printed line is**: `run_setup.bat` is ASCII-only (checked: zero non-ASCII lines), and the
line printed at `:noexe_runapp` is `"%HP_PY%" "%HP_ENTRY%"` with straight quotes, which Command
Prompt accepts as written. The field note itself uses curly quotes, which suggests the paste
turned straight quotes into curly ones on the way in. Curly quotes make cmd fail exactly as
reported ("drop the quotes and it works"). This is a hypothesis, not a confirmed cause. Before
changing any code, reproduce with the printed line pasted as-is into Command Prompt, and a copy
of it with curly quotes, on a path that contains spaces. Keep the straight-quote form.

**Re-check (maintainer, 2026-10-09)**: the printed line, quotes included, works when pasted into
Command Prompt ("not sure why it didn't before"). That is the reproduction this item asked for,
and it came out clean, so there is no code change to make. The curly-quote paste above is the
remaining unproven explanation for the August failure; a fresh report with the exact pasted text
would reopen this. Close the CLAUDE.md entry as "no action needed" (a Known Finding) when the next
docs-only change touches the backlog.

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
user-facing prompt to pick a builder was decided against (Q6 = A, override only, 2026-10-09); leave the default order
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
  is not a real `.py`; the decided policy is in Item 67.
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

1. Each fix lands with a Windows CI scenario that reproduces the ORIGINAL symptom first. The
   test lands alone and must be proven red in CI, and blocking the PR, before the fix commit
   follows; the rule is in AGENTS.md's "Test-first for bug fixes and new behavior" section.
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

### Item 77 -- `import pymupdf` fails on a clean machine: "DLL load failed while importing _extra" (Likely cause, runtime DLLs confirmed missing, small)

**Symptom (second real run, 2026-10-09, same folder as Items 63 and 64)**: after PyInstaller built
the EXE and warnfix installed pymupdf, the run ended with `ImportError: DLL load failed while
importing _extra: The specified module could not be found.` and an unhandled exception.

**Field result that narrows it (maintainer, same day)**: `_extra.pyd` and `mupdfcpp64.dll` are both
present in the env's `pymupdf` folder, and a bare `import pymupdf` in the env's own interpreter
fails with the same error. So this is NOT a PyInstaller bundling gap: the package fails before
PyInstaller is involved. The test machine is a Windows sandbox, that is, a clean Windows image,
which is the bootstrapper's stated target machine, so this is not a red herring.

**What the message means**: "The specified module could not be found" is Windows' generic text for
"this `.pyd`, or a DLL it needs, did not load"; it never names the missing DLL. Reading the import
tables of the `pymupdf-1.28.2-cp310-abi3-win_amd64` wheel (checked 2026-10-09 by scanning the
binaries for DLL names): `_extra.pyd` imports `mupdfcpp64.dll`, and `mupdfcpp64.dll` imports
`msvcp140.dll`, `vcruntime140.dll` and `vcruntime140_1.dll` plus Windows' own `api-ms-win-*`
forwarders. `msvcp140.dll` (the C++ standard library) and `vcruntime140_1.dll` are Microsoft's
Visual C++ runtime, not part of a fresh Windows install and, to my knowledge, not shipped with
CPython. A clean machine without that runtime fails exactly like this. The August notes already
carry the matching warning: "Microsoft Visual C++ redistributable is not installed which may lead
to DLL load failure" (PyInstaller printed it). The do-not-add list said to revisit that warning
"only if a real DLL load failure is seen"; this is that failure.

**Why a conda env would not show it**: conda-forge packages normally depend on their own copy of the
runtime, so the DLLs land inside the env. A uv or venv env relies on the machine having Microsoft's
runtime installed. `:dll_bundle_recover` only handles conda envs (`HP_ENV_MODE=conda`), and
`:hidden_import_recover` is correctly silent because this is not a `ModuleNotFoundError`. Nothing in
the bootstrapper looks for the runtime today (no mention of it in `run_setup.bat`).

**Confirmation status (maintainer, 2026-10-09)**: `dir /b %SystemRoot%\System32\msvcp140.dll
%SystemRoot%\System32\vcruntime140_1.dll` answered "File Not Found" (retyped; the command named
both files, so at least one is missing). That supports the cause. The last step, installing the
official x64 runtime and repeating `import pymupdf`, was skipped because the sandbox is being thrown
away, so the cause is LIKELY, not confirmed. Supporting context: the maintainer has run this same
program from the interpreter on their normal machine before (once the xlsxwriter workaround was
done), which fits a machine that has the runtime. A 32-bit interpreter is ruled out: `mupdfcpp64.dll`
is in the env's `pymupdf` folder, so pip installed the `win_amd64` wheel, which it only does for a
64-bit interpreter.

**Fix shape (small, if confirmed)**: (a) detect and say so. When the build or a run prints
`DLL load failed`, or before building when `System32` lacks `msvcp140.dll` or `vcruntime140_1.dll`,
print a `[WARN]` that names the Microsoft Visual C++ runtime, says some packages (PyMuPDF is one)
will not load without it, and gives the download link; do not install it automatically (it needs
administrator rights and the core flow does not). (b) Evaluate, as a separate decision, whether the
uv and venv paths should carry the runtime inside the env the way conda does; do not decide that
here. CI runners already have the runtime, so CI cannot reproduce the real failure. CI can prove
the wiring: a test-only flag (absent means normal behavior) that makes the check report the runtime
as missing, plus a fixture run whose output contains the `DLL load failed` text, asserting the new
`[WARN]` appears. No CI scenario that builds a pymupdf EXE is needed for this cause, and none is
planned unless the confirmation above fails.

### Item 78 -- An archived subfolder triggered an NI-VISA driver install that then failed (Confirmed trigger, failure cause partly narrowed, small)

**Symptom (second real run, 2026-10-09)**: `[VISA] installer exit code: -125202` then
`[VISA] install_failed (post_check_timeout) installer_rc=-125202` (the maintainer's words: "failed
visa install (rc=-125202)"). That is the NI-VISA installer's own exit code, not uv's.

**Why it was attempted (Confirmed by the maintainer)**: the program being run is the PDF extractor,
which does not use VISA. A `.py` in an archived subfolder (kept so the maintainer can switch
between programs under test) has `import visa`. `tools/detect_visa.py` walks every subfolder, skipping
only `~`- and `.`-prefixed directories, and any line `import visa` / `import pyvisa` / `from pyvisa`
sets `NEED_VISA=1` (`run_setup.bat` around line 1913), which starts a real driver install. The
detector's regex is anchored (`pyvista` cannot trigger it), so this is the design working as coded,
on files the user did not think were part of the app.

**Decision on scan scope (maintainer, 2026-10-09, resolved; was Q9)**: keep scanning subfolders for
now and document it. Do not build call-chain tracing from the entry file: it is not already done
(`tools/find_entry.py` lists only the top folder; pipreqs, `tools/collect_submodules.py`,
`tools/detect_visa.py` and the fast-path hash all recurse), so tracing would be new work, and it is
not worth it. The maintainer left the rest to this thread, with this preference order: a log at
minimum, and at worst a prompt that defaults to "no install" after the same timeout the cascade
prompt uses. The README (REQ-008) now states the subfolder behavior as documented behavior. That
README sentence describes what the code does today; the log and prompt below are planned and are
deliberately NOT in the README until they ship.

**Chosen shape (this thread's call)**: both pieces, because the log alone cannot stop a 30-45
minute install that the user has already waited through.
1. **Log, always, when the scan finds an import**: name the file(s) that triggered it and whether
   they sit next to the bootstrapper or below a subfolder, for example `[VISA] pyvisa/visa import
   found in: <relative path> (subfolder)`. At most three paths, written by the Python scanner
   straight to the log (its stderr is already appended to `%LOG%`), never through `:log`, because a
   relative path can hold `&`, `%` or `^` (see "`:log` echoes UNQUOTED" in
   `docs/agent-lessons-learned.md`). "Outside the bootstrapper's folder" cannot happen: the scan
   root is the working directory, so a subfolder is the only other place a match can come from.
2. **Prompt, only when every match is below a subfolder** (none in the folder next to
   `run_setup.bat`): a timed consent gate, same pattern as `:cascade_consent_gate` (`choice /T` with
   the cascade's default timeout, default NO). Wording: NI-VISA looks needed only by a file in a
   subfolder, name the file, say the install can take 30-45 minutes and that the Python `pyvisa`
   package is installed either way. CI-safe by the repo's rule: echo the prompt unconditionally, a
   `HP_TEST_*_ANSWER` override first, then `HP_CI_LANE` auto-decline, then the timed prompt. A match
   in the top folder keeps today's behavior exactly: no prompt, install attempted. The scanner's
   stdout contract grows from `0|1` to `0|1|2` (`2` = matches only in subfolders), with `NEED_VISA`
   still required to be exactly `1` to install, which keeps `2` safe by default. Declined or timed
   out: log `[VISA] skipped (subfolder_only)`.
3. **Cost and sequencing**: small. Changing the output contract means updating `HP_DETECT_VISA`
   through `tools/sync_payload.py` and `tests/test_detect_visa.py` (which already pins the recursive
   behavior, so the new `2` case is an addition, not a reversal). The existing `selfapps_pyvisa.ps1`
   puts its import in a top-level `main.py`, so it keeps meaning "install attempted"; it needs a
   sibling scenario with the import in a subfolder, asserting the prompt text, the default-no
   result and the log line. Ship this as its own PR, separate from the Item 64 and Item 77 fixes
   and from slice 1 of this item (the elevation line and the failure `[WARN]` below).

**Elevation (maintainer, 2026-10-09)**: `whoami /groups` returned `S-1-16-12288`, so this run WAS
elevated, and the installer still exited `-125202`. That rules out "the installer needs
administrator rights" for this run. What remains: the sandbox is a clean Windows image whose
network or install policy NI's online installer does not like (the CI runner behaves the same way
with `-125083`), or the pinned 21.5 online URL is stale. The maintainer says the install has
worked on their regular machine before, slowly (from memory, not from a log).

**What this changes in the docs**: `docs/agent-closed-backlog.md`'s Known Finding "NI-VISA real
install fails fast in CI" said it still needed a real user run to confirm the installer succeeds off
CI. This run does not do that: it is another clean image, elevated, failing with the same family of
code (`-125202` also appears in CI per `docs/demo-bootstrapper-output.md`'s Scenario 24). The
maintainer's recollection of past successes is the only off-CI evidence. The finding's
"environmental" classification stands; it gets a note, not a rewrite, in the same change as this plan.

**Fix shape (small)**: (a) log elevation once near the start of every run, as the maintainer
proposed: `[INFO] Elevated: yes` or `no`. The bootstrapper already has a test that works (`fsutil
dirty query %systemdrive%` succeeds only when elevated, used in the Miniconda AllUsers branch);
reuse it from one place instead of repeating it. (b) On `install_failed`, print a console `[WARN]`
(not only a `~setup.log` line) saying the NI-VISA driver did not install, that the Python `pyvisa`
package is installed anyway, and that talking to real instruments needs the driver; the bootstrap
itself still continues (never fatal, as today). (c) Do not add a retry loop or an automatic
elevation prompt. (d) Scan scope: see the decision above; it ships as its own slice. **CI proof**: the
existing `pyvisa.nivisa` scenario already reaches `install_failed` in CI; assert the new `[WARN]`
text there, and assert the `Elevated:` line appears in the log on every lane.
