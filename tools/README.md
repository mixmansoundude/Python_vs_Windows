# tools/

This directory is mixed-purpose. Most of it is load-bearing -- do not assume anything here is
low-stakes without checking which category a given file falls into.

## Most files here need full review rigor

- **CI-wired scripts**, invoked directly by `.github/workflows/*.yml` (e.g. `apply_patch.py`,
  `check_ndjson_registry.py`, `check_workflows_yaml.py`, `inline_model_fix.py`, `parse_warn.py`,
  `prep_requirements.py`, `diag/ndjson_fail_list.py`, `diag/publish_index.py`) or that gate CI
  decisions even if not directly listed in a workflow step (`iterate_gate.ps1` -- "the active gate
  used by CI"; `sanitize_iterate_payload.py` -- defines the current NDJSON contract).
- **Canonical sources for `run_setup.bat`'s embedded `HP_*` payloads** (e.g. `pyproj_deps.py`,
  `prep_requirements.py`, `collect_submodules.py`, `hidden_import_scan.py`, `dep_check.py`,
  `env_state.py`, `detect_python.py`, `detect_visa.py`, `find_entry.py`, `embed_extract.ps1`,
  `embed_pyver_check.py`, `exe_smokerun.ps1`, `failfast_probe.ps1`, `run_installer_with_timeout.ps1`,
  `pvw_known_idempotent.py`, `autopep_merge.py`, `pep723_writeback.py`). These ship as part of the
  actual deliverable (base64-embedded in `run_setup.bat`) -- arguably higher stakes than a CI
  script, not lower. Update via `tools/sync_payload.py`, never by hand-editing the embedded
  base64 (see `docs/agent-lessons-learned.md`'s "Embedded Helper Update Workflow").
- **Required dev-workflow tooling**, run before every commit even though no `.yml` file calls it
  directly: `check_delimiters.py`, `run_sanity_sweep.sh`, `ps-compileall.ps1`, `sync_payload.py`.
  See CLAUDE.md's "Mandatory Sanity Checks" section.
- Everything else not explicitly named below.

## Exceptions: manual, hand-run, not required by any flow

These two are genuinely informal -- standalone diagnostic/audit scripts, run by hand on demand,
not invoked by CI, not a canonical payload source, and not part of any required pre-commit check.
Normal-rigor review asks (type annotations, `# derived requirement:` comment tags, etc.) don't
apply the same way here; use judgment rather than treating every linter nitpick as actionable.

- `audit_console_messages.py` -- own docstring: "Not wired into CI -- run by hand when
  re-reviewing docs/demo-bootstrapper-output.md... or after a batch of new lines."
- `audit_batch_exit_paths.py` -- a one-off audit tool for tracing `run_setup.bat`'s exit paths;
  own module docstring notes it is "not a final answer on its own."

If you add a new script that's genuinely in this category, say so explicitly in its own
docstring/header (matching the two examples above) and add it to this list in the same commit --
don't rely on this README alone to establish that later.
