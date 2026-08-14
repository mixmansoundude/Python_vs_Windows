# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

## 1. Should the post-flight caveat panel surface a DLL-specific hint now that the repair loop exists and its real-CI confirmation has landed?

**Status: UNBLOCKED, ready for a decision as of 2026-08-08.** This question was deliberately left
sitting until `self.layered_e2e.chain`'s own real-CI confirmation landed (see
`docs/agent-closed-backlog.md`'s Item 24/28/29 entries) -- that has now happened (`chainPass:true`,
PR #421 merge). Nothing further is blocking a decision; this is purely a product/UX call for the
maintainer, not something to settle unilaterally.

**Background**: README.md's REQ-016 spec (current, correctly implemented) already guarantees the
post-flight briefing always shows the direct interpreter-run command regardless of EXE
verification outcome, and separately shows a generic "couldn't fully verify it runs as a
standalone program" caveat when the EXE smoke run failed -- deliberately never asserting a root
cause (an already-settled design decision from REQ-027 P2; see `docs/agent-interconnect.md`'s
"Honest ambiguous-exit messaging" section).

**The question**: `:dll_bundle_recover` (CLAUDE.md's closed Item 24) now computes a concrete,
specific fact the bootstrapper didn't have before -- whether a missing native-DLL dependency was
detected, and whether a repair was attempted and succeeded/failed. Should the post-flight caveat
panel surface this fact when relevant, instead of staying purely generic? This would still be
in scope of the "no general root-cause guessing" principle (it's a real signal the mechanism
already computes, not a guess), but is new user-facing wording that has never shipped.

**If yes, any wording must model three distinct states, not one** (a review pass on PR #414
caught this): detection and repair are NOT the same event, and repair is a no-op under a
non-conda provider or a Nuitka-built EXE (Item 24 Requirements 3/6), so detection can fire with
no repair ever attempted. Real, already-emitted log lines back all three states:
- **Detected, repair skipped** (`[INFO][DLL_BUNDLE] Detected native-DLL warning...skipping.`) --
  wording must NOT claim "attempted to fix it automatically."
- **Detected, repair attempted and failed** (no `Native-DLL bundling complete` line despite a
  `Bundling native DLL dependency` attempt) -- "we detected and attempted to fix" is accurate.
- **Detected, repair attempted and succeeded** (`Native-DLL bundling complete`) -- this caveat
  panel only fires on an EXE verification FAILURE, so this state likely never co-occurs with the
  panel firing in practice; worth confirming against real evidence before assuming it's dead code.

**Decision needed**: implement this new caveat wording (and if so, in this loop or backlogged),
or leave the caveat panel purely generic indefinitely and close this question as "declined"?

---

## 2. Should the distribution channel itself be fixed so a raw download of `run_setup.bat` gets correct (CRLF) line endings, and if so, how?

**Status: OPEN, raised 2026-08-14.** Background and full mechanism in CLAUDE.md's former Active
Backlog Item 44 (now closed/mitigated -- see `docs/agent-closed-backlog.md` once archived): a raw
download (GitHub's "Raw" button, or a `raw.githubusercontent.com` link) serves `run_setup.bat`
with Unix (LF-only) line endings instead of the Windows (CRLF) endings a real `git clone` checkout
produces, because `.gitattributes`'s `* text=auto eol=lf` normalizes the STORED blob to LF and the
`*.bat text eol=crlf` override only affects checkout-time conversion, never what GitHub serves raw.
cmd.exe's goto/call label-seeking silently misbehaves on the LF-only copy, producing a confusing,
partial, undiagnosable run. A same-session mitigation now makes `run_setup.bat` self-detect this
and fail with a clear message (see the top of the file) -- but the distribution channel itself is
unchanged: a user can still land on a raw link and get the broken file, they just now get told
clearly instead of being left confused.

**The maintainer explicitly wants**: diffs to stay clean (no line-ending noise from
cross-platform edits), and ideally for a raw download to just work. These two preferences are in
tension, since git's own line-ending normalization is exactly what both protects diffs AND causes
the raw-download breakage -- see the option table below.

| Option | Raw download works? | Diff cleanliness | Effort | Notes |
|---|---|---|---|---|
| **A. Status quo** -- keep `.gitattributes` exactly as-is (`text=auto eol=lf` + `*.bat`/`*.ps1` `eol=crlf`) | No (confirmed broken) | Best -- this is exactly what `text=auto` exists to guarantee | None | The self-check (Item 44's mitigation) turns the failure loud and actionable instead of silent, but does not prevent it. `git clone` already works correctly today with zero further changes. |
| **B. Make `.bat`/`.ps1` files `-text`/`binary`** (disable git's line-ending conversion for them entirely) | Yes, IF the stored blob is CRLF at the time each commit is made | Worse, and inconsistently so -- diffs are computed against raw bytes, so any commit made from an LF working copy (e.g. an editing tool on Linux/Mac that doesn't explicitly preserve CRLF) re-introduces a whole-file line-ending diff, and risks silently mixing CRLF/LF within one file across edits | Low to set up, but shifts ongoing burden onto every future commit | This is the option that most directly reopens the "noisy diffs" problem the maintainer said they want to avoid -- git's own checkin normalization (which currently fixes this automatically regardless of what edited the file) would be gone. Would need either strict contributor/tooling discipline or a CI check enforcing CRLF on every PR touching these files to be safe, adding friction to what CLAUDE.md's own docs describe as a very frequently edited file. **Not recommended given the stated diff-cleanliness priority.** |
| **C. Publish a GitHub Release with a verified-CRLF asset**, and point users at that instead of the raw blob URL | Yes, and cleanly -- Release assets are not git blobs and are not subject to `.gitattributes` conversion at all | Unaffected -- the repository's own line-ending policy (Option A) stays exactly as-is | Moderate -- needs a CI step (this repo already has the infrastructure for this kind of thing, e.g. the diagnostics-site publish job) that builds/verifies/uploads a CRLF-correct asset on some cadence (every push to main, or every tag) | The only option that achieves "raw download works" without reopening the diff-noise problem. Real but bounded effort; a legitimate future Active Backlog item if this direction is chosen. Self-check (Item 44) stays valuable regardless, as defense-in-depth for anyone who still finds an old raw link. |
| **D. No infrastructure change; just document the correct way to get the file** | No structural fix, but the natural failure mode is closed off by steering users away from it | Unaffected | Essentially free | Already done this session: README's new TL;DR bullet recommends `git clone`. Cheap, available today, but relies on users reading and following it rather than the download "just working" from the most obvious link. |

**Recommendation (not a decision -- the maintainer's call)**: keep Option A's `.gitattributes`
policy unchanged (protects the diff-cleanliness priority, and is what the existing CLAUDE.md
convention already documents as intentional), do Option D now (already done), and treat Option C
as a real but separate future Active Backlog item if "raw download should just work" is a strong
enough priority to justify the CI effort. Option B is not recommended given the explicit
diff-cleanliness preference.

**Decision needed**: pursue Option C (and if so, prioritize it as an Active Backlog item), or
accept Option A+D as the steady state and close this question?
