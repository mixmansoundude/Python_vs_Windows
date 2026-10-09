# Plan: TOML reading hygiene (CLAUDE.md Item 79)

Filed 2026-10-09 from a planning-only brainstorm; every code claim below was re-checked against
the repo on 2026-10-09 (main at 7a91f77 plus the Item 62 extractor from PR #475, head 19e7fc2,
and uv 0.11.32). Low priority. **Nothing here changes dependency source priority** (PEP 723 >
pyproject > requirements.txt > pipreqs stays exactly as README REQ-005.1 states) or the flow or
the lock/state fast paths. Rules for every slice: red test first, proven red, then the fix, one
slice per PR (see AGENTS.md and the CI-first policy in `docs/plan-field-report-2026-10.md`).

## What the code does today

| Piece | Reads | Parser | Runs under | Payload margin |
|---|---|---|---|---|
| `pyproj_deps.py` (`HP_PYPROJ_DEPS`) | `[project].dependencies` | tomllib, else char-walker | target env python (`%HP_PY%`) | 198 chars |
| `pep723_extract.py` (`HP_PEP723_EXTRACT`) | top-level `dependencies` of the header | char-walker only | target env python (`%HP_PY%`) | about 2060 chars |
| `detect_python.py` (`HP_DETECT_PY`) | `requires-python` (pyproject only) | one regex over the whole file | orchestration python (`uv run --no-project python`, or Miniconda base) | 1552 chars |
| `pep723_writeback.py` (`HP_PEP723_WRITEBACK`) | writes the header via `uv add --script`; `strip_pep723_block` for the malformed retry | line state machine | `%HP_PY%` | 333 chars |

The target interpreter can lack tomllib (a `runtime.txt` or `requires-python` pin below 3.11
selects an older target Python under REQ-004), so the pyproject walker fallback is live code.
`detect_python.py` always runs under a modern interpreter, so it can use tomllib freely.
`pep723_extract.py` is script-style (it exits at import), so tests must run it as a subprocess
the way `tests/test_pep723_extract.py` does; they cannot import it.

## Two live bugs (both reproduced 2026-10-09)

- **Pyproject fallback keeps backslashes in markers, and accepts an unclosed array.** With
  tomllib shadowed out (Python below 3.11), `dependencies = ["pywin32; sys_platform ==
  \"win32\""]` yields `pywin32; sys_platform == \"win32\"` (packaging rejects it: "Expected a
  marker variable or quoted string"), and `dependencies = ["requests",` (no `]`) yields
  `requests` with exit 0. tomllib and `pep723_extract.py` both get the escape case right, and
  the extractor rejects the unclosed array. `tests/test_pyproj_deps.py::
  test_escaped_quote_backslash_not_stripped` records the old behaviour as acceptable; slice 2
  flips it.
- **`detect_python.py` reads `requires-python` with an unscoped regex.** A commented-out
  `# requires-python = ">=3.8,<3.9"` yields `python>=3.8,<3.9`; the same key under
  `[tool.somethingelse]` does too; a triple-quoted value yields nothing. (The PEP 723 header's
  `requires-python` is ignored entirely, which matches README REQ-004: runtime.txt, then
  pyproject. That is a gap, not a bug; see the parked idea.)

## Facts about uv worth keeping (uv 0.11.32)

- `uv add --script s.py 'requests>=2.31' 'rich[jupyter]~=13.0' 'pywin32; sys_platform ==
  "win32"' 'colorama; python_version < "3.10"'` wrote a sorted list, added a lower bound
  (`pywin32>=312`), rewrote markers to single quotes and `python_version` to
  `python_full_version`, and added `requires-python = ">=3.13"` (the running interpreter) to a
  file with no header. The layout is outside our control, which is the argument for a canary.
- uv has no "print the declared deps" command: `uv pip compile s.py --no-deps` and `uv export
  --script s.py` resolve and pin (`requests==2.34.2`) and evaluate markers for the host, so
  uv can only be a test-side oracle for the WRITE format, never a replacement reader.
- Three fence rules exist: `block_text` in the extractor tolerates a trailing space on the
  opening `# /// script`; `strip_pep723_block` and uv do not (uv then prepends a second header
  and the strip leaves the old one). Very unlikely in practice; it only matters if reader and
  writer are ever merged.

## Item 79: three slices, in this order

1. **Oracle tests** (new file, e.g. `tests/test_toml_oracle.py`; do not touch
   `tests/test_pep723_extract.py`). Compare `pep723_extract.py` (subprocess) and
   `pyproj_deps.py` (run both with tomllib and with it shadowed out) against `tomllib.loads`
   over a PEP 508 corpus: markers in both quote styles and with escaped quotes, extras, URLs,
   `#` comments, CRLF, an unclosed array. It goes red on the pyproject fallback bugs above, which
   doubles as slice 2's regression test. Add one uv-lane row that extends the existing real-uv
   round trip (`self.pep723.writeback.roundtrip`) to a corpus written by real `uv add --script`,
   so a uv layout change turns CI red before a user hits it. Unit tests are not run by CI today
   (only parse_warn and heuristics have steps), so wire the new file into a step or state the
   AGENTS.md exception in the PR.
2. **Fix the pyproject fallback.** Port the extractor's TOML escape decoding and closed-array
   check into `pyproj_deps.py`'s fallback walker (about 25 lines), flip
   `test_escaped_quote_backslash_not_stripped`, and trim prose to stay inside the 198-char
   payload margin. If it cannot fit, that is the trigger for the parked headroom idea; stop and
   say so rather than dropping the escape handling.
3. **`detect_python.py` reads `requires-python` through tomllib.** Table-scoped
   (`[project].requires-python`) and comment-safe. Keep the regex only for when tomllib is
   missing or the TOML is malformed (today's behaviour); when the TOML is valid and the key is
   absent, return nothing rather than falling through to the regex, or the commented-out-line bug
   survives. Red tests first: the commented-out line, the other-table key, and a triple-quoted
   value. Same input, same precedence, so REQ-004 is unchanged.

## Parked (CLAUDE.md "Cold Storage" pointer; entries in `docs/agent-cold-storage.md`)

- Payload headroom (deflate mode in `:emit_from_base64`, or strip comments at `sync_payload.py`
  time), then one shared `toml_deps.py` for pyproject and PEP 723 and a shared fence finder.
  Headroom must come before any parser merge: the two helpers are 10.5 KB of source against a
  ceiling of about 6.1 KB per payload (deflate + base64 of the pair is about 5350 chars, under
  the limit, so the merge is feasible once headroom exists). Trigger: a payload edit lands
  under 100 chars of margin, or a third TOML consumer appears.
- PEP 723 `requires-python` as a Python-version input. It needs the entry known before env
  creation, which is decided after it today, and `uv add --script` itself writes `>=<running
  python>`, so honouring it recreates the write-back pin problem documented for runtime.txt.
  It is a REQ-004 precedence decision, not an implementation detail. Trigger: a field report of
  a header with an upper bound running on a too-new Python; a maintainer decision comes first.

## Considered and dropped

- tomllib-first inside `pep723_extract.py`: the walker already matches tomllib on real tool
  output, and a second path adds strict-versus-lenient differences (README: a malformed header
  falls through).
- Running parse helpers under the orchestration interpreter so tomllib always exists: embed,
  venv and system modes have no such interpreter.
- Any uv-native extraction (impossible, see above).
- A fallback chain through the `toml` or `tomli` packages: both need pip and an env, which do
  not exist yet when these helpers run (Bootstrap Architecture Principles 1 to 3). `toml` is at
  0.10.2 (TOML 0.5 only); `tomli` is at 2.5.0.
- Unioning `[project.optional-dependencies]` into discovery: extras are mostly dev, test and
  docs, and would be installed and bundled into the EXE.
- A `requirements-lock.txt` above PEP 723, or an `HP_REQUIREMENTS_FILE` override: a priority
  reorder (ruled out) and REQ-019 scaffolding respectively.
