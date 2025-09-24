# Agents guidance

## Interface contract with CI
- CI asserts on exact bootstrapper messages emitted by run_setup.bat and related helpers.
- When adjusting bootstrap log text or status summaries, update the workflow checks that parse them at the same time.
- Likewise, when tightening CI parsing or summaries, ensure run_setup.bat keeps emitting the expected phrases.
- Always validate both sides together so the message contract stays synchronized and avoids false regressions.
