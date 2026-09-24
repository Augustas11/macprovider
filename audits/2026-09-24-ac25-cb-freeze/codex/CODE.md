## Lane: CODE (correctness, concurrency, tests)

Look for:
- Scheduler, drain, and delivery races and continuations that never resume.
- Stop-token and usage accounting errors, including Harmony.
- Ragged-row and Mamba state corruption across join, leave, and cancel.
- Probe-verdict bypass.
- Config parsing and precedence of the new knobs.
- Tests that would not fail on a real regression.
