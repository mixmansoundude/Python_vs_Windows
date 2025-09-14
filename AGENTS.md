# AGENTS.md

## Operating policy for automated agents (Codex, Copilot, etc.)

- **Read the README.md first.** Follow “Agent Guardrails.”
- Treat **CI output** (run page Job Summary + grouped log tails + PR failure comment) as the only ground truth.
- **Don’t weaken tests or remove logging/artifacts.**
- **Conda policy is mandatory**: force `conda-forge` only and use `--override-channels -c conda-forge`.
- Work on **`fix/ci-batch-tests`** with a single PR to `main`.
- Commit messages: `fix(ci): address <short-cause> (#<iteration>)`.
- If unable to call Actions APIs, **trigger CI by push** (or an empty commit) and **wait** for completion before deciding the next change.
- **Iteration cap:** 20. Stop early if the same top error appears twice consecutively.