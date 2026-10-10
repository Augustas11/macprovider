Fix correct and complete for the scoped finding. Launch precedes stdin writing; concurrent input/output handling removes the pipe deadlock. `F_SETNOSIGPIPE` and throwing writes handle early exit/EPIPE, and the writer closes afterward.

No regressions identified in changed lines involving crashes, descriptors/tasks, continuation completion, timeout behavior, or data races. Verification was source-only; tests were not run.

C/H/M/L = 0/0/0/0
VERDICT: PASS
