# Agent Scratchlog

Internal, working-notes log for the agent doing refinement/investigation passes on this repo --
NOT a user-facing document. Distinct from `docs/demo-bootstrapper-output.md` (what a human sees
on screen, latest state only, no history) and `docs/open-questions.md` (unresolved questions
needing a maintainer decision). This file is a scratchpad: verification checks, dead ends,
things ruled out, small findings not yet worth a full CLAUDE.md Closed Backlog entry. Prune or
overwrite stale entries freely -- this file has no obligation to stay complete or permanent.

---

## 2026-07-22

**PyInstaller command's own stdout/stderr ARE fully redirected -- ruled out as the literal
source of the "cannot find the drive specified" console message.** All three
`"%HP_PY%" -m PyInstaller ...` invocations in `run_setup.bat` end in `>> "%LOG%" 2>&1`, and the
`:compute_collect_flags` subroutine's own Python subprocess call
(`"%HP_PY%" ~collect_submodules.py . > "~collect_flags.txt" 2>> "%LOG%"`) is also fully
redirected (stdout to a temp file, stderr to the log). Neither can be the direct source of a
message appearing on the live console. Also ruled out ordering: `:compute_collect_flags` runs
*before* the "[INFO] Building standalone executable..." log line, but the drive message is
observed *after* it in real transcripts, so it isn't that subroutine's subprocess leaking through
some other path either. Best remaining hypothesis (unconfirmed, no Windows sandbox available
here): an unrelated background process (uv self-update check, Defender scan, or similar) whose
output happens to flush to the merged console/log stream around the same wall-clock window as the
build step, not causally triggered by the build itself -- would explain why it's "far too common
to be Tier-A-specific" and appears near nearly every build attempt regardless of outcome. Not
chased further per explicit instruction not to go deep (past attempts already stalled here).
Mitigation shipped instead: a one-line reassurance right after the "Building standalone
executable" log line, worded to avoid literally reproducing the trigger phrase (see the next
entry -- this mattered for real).

**Near-miss: my own reassurance-message wording would have caused a false test failure.**
First draft of the reassurance line quoted the exact phrase `'The system cannot find the drive
specified.'` inside the message text. `tests/selfapps_envsmoke.ps1`'s `Get-LineSnippet` does an
unanchored substring search (`$line -match $Pattern`) over the WHOLE bootstrap log and returns
the FIRST matching line verbatim; the caller then checks whether that returned line exactly
equals `^The system cannot find the drive specified\.?$` before treating it as an allowlisted,
harmless occurrence. Since my reassurance line would appear before the real system-generated line
in the transcript and ALSO matches the substring search, it would have been captured first,
failed the exact-match allowlist check (extra wrapper text around the quoted phrase), and flagged
as an unexpected system error -- a self-inflicted false failure. Fixed by rewording to avoid the
literal trigger substrings ("cannot find" / "is not recognized as an internal or external
command") entirely. Grepped `tests/*.ps1` for both trigger substrings afterward to confirm no
other detector would collide (`selfapps_entry.ps1`/`selfapps_single.ps1` both check for a
different, unrelated exact phrase about `~find_entry.py` not being recognized -- unaffected).
General rule for any future console message added near existing pass/fail detection: grep the
test suite for the phrase before wording it, not after.

**CI `continue-on-error` scoping, confirmed via the actual workflow YAML, not assumption.**
`batch-check.yml`'s single `selftest` job already sets `continue-on-error` at the JOB level for
six of eight matrix lanes (`cache`, `justme-test`, `uv`, `contract-uv`, `contract-uv-fail`,
`uv-dl-fallback`) -- only `real`/`conda-full` are true gating lanes. This means CLAUDE.md Active
Backlog item 7's "continue-on-error would defeat gating" reasoning applies ONLY to steps that can
run under `real`/`conda-full`; it does NOT apply to steps whose `if:` condition restricts them to
the six already-non-gating lanes, since those never gated merges regardless. Surveyed all step
`if:` conditions in the file (33 steps restricted to non-gating-lanes-only); found the PEP 723
write-back / PVW QuickStart / autopep723 discovery steps already use per-step
`continue-on-error: true` (established precedent, not something I invented) while 9 others
(uv-contract assertions, JustMe/download-fallback self-tests, provider-cascade exec, Tier A build
+ hidden-skip, all 4 optbuild scenarios) were missing it -- added it to those 9. This is a
narrower, safe subset of the originally-declined "retrofit `if: always()` across ~50 steps"
fix -- it changes nothing about merge gating (already didn't gate) and only stops one failing
self-test from hiding its siblings' results within the same non-gating lane run.
