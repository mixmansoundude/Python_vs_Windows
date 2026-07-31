#!/usr/bin/env bash
# tools/run_sanity_sweep.sh -- CLAUDE.md's "Mandatory Sanity Checks" sweep as one command.
#
# Formalizes a block that was previously copy-pasted by hand from CLAUDE.md before every
# commit (many times per session, across many sessions) into a single, reusable,
# consistently-run script -- reducing the risk of a mistyped or partially-pasted copy and
# giving a clear pass/fail summary at the end instead of scrolling through raw tool output.
#
# Usage:
#   tools/run_sanity_sweep.sh                         # ASCII sweep uses the default file list
#   tools/run_sanity_sweep.sh path/to/new_file.ps1 ... # extra files ADDED to the ASCII sweep
#
# CLAUDE.md's own words: "The ASCII sweep's file list is illustrative, not exhaustive --
# extend it to cover whatever files the current change actually touches." Pass any
# additional touched files as arguments; they are appended to the default list below.
#
# Exit code: 0 only if every check passed. Non-zero otherwise, with a per-check summary
# printed at the end so a failure doesn't require scrolling back through the full log.
#
# This intentionally does NOT auto-install missing tools (pwsh, actionlint, yamllint,
# pyflakes) -- installing system packages is a real, side-effect-having action a sweep
# script should not take silently. A missing tool is reported as a FAILED check with a
# pointer to AGENTS.md's "Style and robustness" section, which documents install steps
# for this sandbox.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

DEFAULT_ASCII_FILES=(
  run_setup.bat
  tests/harness.ps1
  docs/agent-interconnect.md
  docs/agent-lessons-learned.md
  CLAUDE.md
)
ASCII_FILES=("${DEFAULT_ASCII_FILES[@]}" "$@")

declare -a RESULTS=()
OVERALL=0

step() {
  local name="$1"
  shift
  echo
  echo "=== $name ==="
  if "$@"; then
    RESULTS+=("OK   $name")
  else
    RESULTS+=("FAIL $name")
    OVERALL=1
  fi
}

check_compileall() {
  python -m compileall -q .
}

check_pyflakes() {
  if ! python -m pyflakes --version >/dev/null 2>&1; then
    echo "pyflakes not installed -- see AGENTS.md 'Style and robustness' for install steps."
    return 1
  fi
  # pyflakes findings are advisory (matches CLAUDE.md's own "| head -20", non-gating
  # historically) -- print them but do not fail the sweep on nonzero output alone.
  python -m pyflakes . 2>&1 | head -20
  return 0
}

check_delimiters() {
  python tools/check_delimiters.py run_setup.bat
}

check_yamllint() {
  if ! python -m yamllint --version >/dev/null 2>&1; then
    echo "yamllint not installed -- see AGENTS.md 'Style and robustness' for install steps."
    return 1
  fi
  python -m yamllint .github/workflows/
}

check_actionlint() {
  export PATH="$PATH:/root/go/bin"
  if ! command -v actionlint >/dev/null 2>&1; then
    echo "actionlint not on PATH -- see AGENTS.md 'Style and robustness' for install steps."
    return 1
  fi
  actionlint -oneline .github/workflows/*.yml
}

check_markdownlint() {
  if ! command -v markdownlint-cli2 >/dev/null 2>&1; then
    echo "markdownlint-cli2 not installed (npm install -g markdownlint-cli2) -- skipping (advisory only)."
    return 0
  fi
  # Advisory only, matches PYFLAKES's own non-gating precedent -- always return 0.
  # Scoped to MD029 only via .markdownlint-cli2.jsonc; that file's own header explains why
  # (this repo's docs don't follow a general markdown style gate). Formerly had one
  # PERMANENT, EXPECTED finding (item 7's own solo "7." entry in CLAUDE.md's Active
  # Backlog); item 7 was closed and moved to docs/agent-closed-backlog.md on 2026-07-31,
  # so this should now come back fully clean -- treat ANY finding on CLAUDE.md as worth
  # investigating.
  #
  # Deliberately scoped to CLAUDE.md only, not README.md/docs/*.md -- those files use their
  # own non-sequential numbering schemes (e.g. "Finding N") for reasons not reviewed here;
  # a blanket docs/*.md scan surfaced several pre-existing MD029 hits there unrelated to the
  # stable-ID convention this check exists to backstop. Widen the scope only after reviewing
  # whether those other schemes should follow the same bullet-with-number-in-prose pattern.
  markdownlint-cli2 CLAUDE.md 2>&1
  return 0
}

check_ascii_sweep() {
  local bad=0
  for f in "${ASCII_FILES[@]}"; do
    if [ ! -f "$f" ]; then
      continue
    fi
    local out
    out=$(grep -nP '[^\x00-\x7F]' "$f" || true)
    if [ -n "$out" ]; then
      echo "=== $f ==="
      echo "$out"
      bad=1
    fi
  done
  if [ "$bad" -eq 0 ]; then
    echo "ASCII SWEEP DONE -- clean"
  fi
  return "$bad"
}

check_git_diff_stat() {
  git diff --stat origin/main 2>/dev/null || echo "(no origin/main to diff against, or not a git repo -- skipped)"
  return 0
}

check_ps_parse_sweep() {
  if ! command -v pwsh >/dev/null 2>&1; then
    echo "pwsh not installed -- see AGENTS.md 'Style and robustness' for install steps."
    echo "'I am on Linux so I cannot check PowerShell' is not an acceptable reason to skip this."
    return 1
  fi
  local repo_root
  repo_root="$(pwd)"
  pwsh -NoProfile -Command "
\$ErrorActionPreference = 'Stop'
\$fail = 0
Get-ChildItem '$repo_root/tests/*.ps1', '$repo_root/tools/*.ps1' | ForEach-Object {
  try { [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName, [ref]\$null, [ref]\$null) | Out-Null }
  catch { Write-Host \"PARSE FAIL: \$(\$_.FullName): \$_\"; \$fail = 1 }
}
if (\$fail -eq 0) { Write-Host 'PS PARSE SWEEP DONE - ALL CLEAN' }
exit \$fail
"
}

check_pytest() {
  python -m pytest tests/test_*.py -q 2>&1 | tail -20
  # tail'd output above hides the real exit code; re-run the count check via the
  # PIPESTATUS of the pipeline that just ran.
  return "${PIPESTATUS[0]:-1}"
}

step "COMPILEALL" check_compileall
step "PYFLAKES" check_pyflakes
step "DELIMITER CHECK" check_delimiters
step "MARKDOWNLINT (advisory, MD029 only)" check_markdownlint
step "YAMLLINT" check_yamllint
step "ACTIONLINT" check_actionlint
step "ASCII SWEEP" check_ascii_sweep
step "GIT DIFF STAT (vs origin/main)" check_git_diff_stat
step "POWERSHELL AST PARSE SWEEP" check_ps_parse_sweep
step "PYTEST" check_pytest

echo
echo "=== Sanity sweep summary ==="
for line in "${RESULTS[@]}"; do
  echo "$line"
done

if [ "$OVERALL" -eq 0 ]; then
  echo
  echo "ALL CHECKS PASSED"
else
  echo
  echo "ONE OR MORE CHECKS FAILED -- see above"
fi

exit "$OVERALL"
