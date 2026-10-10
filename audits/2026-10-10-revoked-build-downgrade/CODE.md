Lane: CODE REVIEW. Correctness of the diff: logic errors in the downgrade
decision and its wiring, session-state lifecycle of the revocation notice
(set/cleared on every session change, stale notice reuse across reconnects or
recommendation generations), event attribution on every exit path, Swift
concurrency/actor correctness, Go wire encoding (`omitempty`, both ack paths),
shell/Python correctness of the `rollback` step and `pearl-cli-config.py`
change, and whether the tests actually exercise the allow/deny combinations
they claim. Flag missing tests only when a rule above is untested.
