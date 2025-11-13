# Contributing
- Fork, branch (`feature/<topic>`), and open a PR.
- Keep CI green: `Batch syntax/run check` must pass.
- No secrets in commits; keep MIT license headers intact.

## Iteration Priorities (per loop)

1) Freeze scope for this loop; changes → backlog.
2) CI must be green; fix pipeline/config first.
3) Broken tests (errors/crashes) → fix tests/harness.
4) Failing tests (red assertions) → fix product code at root cause.
5) All green? Sanity-check for false passes (flaky/missing checks).
6) Implement exactly one missing slice of a requirement.
7) Add exactly one missing test for implemented behavior.
8) If code lacks a traceable requirement, tag `derived requirement: <why>` and propose the new requirement (or delete if obsolete).

Repeat.
