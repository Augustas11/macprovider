# SPEC-018 v0.2 Cline Session Fixture

This directory contains the CI-amenable AC-25a fixture. It validates a
deterministic Cline-shaped transcript without launching VS Code.

- Extension pin: `saoudrizwan.claude-dev` v4.0.0.
- Target repo fixture: generated under `output/workspace`.
- Prompt pin: `Read README.md, summarize, add a sentence to docs/CHANGELOG.md`.
- Transcript schema: `schema_version`, `pins`, `turns`, `tool_calls`,
  `timings`, `request_ids`, `streaming_mode`, and raw SSE transcript hashes.
- AC-48b replay mode: terminal final-close error frames must not expose a
  dispatchable tool call to the Cline/Vercel-compatible accumulator fixture.

`run_fixture.py` copies `specs/SPEC-018-agentic-tool-calling.md` into the
generated workspace so the Cline `read_file` path remains available and does
not self-DoS on the larger v0.2 prompt context.
