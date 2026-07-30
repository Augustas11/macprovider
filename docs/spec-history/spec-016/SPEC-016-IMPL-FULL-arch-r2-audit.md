# SPEC-016 FULL IMPL architecture audit r2

**Verdict:** CONVERGENT. Counts:

| CRITICAL | HIGH | MAJOR | MEDIUM | LOW |
|----------|------|-------|--------|-----|
| 0 | 0 | 0 | 0 | 0 |

Scope note: the lane prompt names implementation HEAD `3b41c0d`, while the checked-out audit target is `09163b6` (`spec(016): FULL-implementation r2 audit prompts...`) on `impl/spec-016`. The code under audit is the current worktree at `09163b6`; the implementation commit named by the prompt is its parent.

## Summary

The r1 architecture closure holds: `setupPayout` now enables the SPEC §6.3 Linux gate, documents why, and the topology regression test covers both Linux and non-Linux behavior. The r2 cross-step probes did not find a new architecture blocker: halt, tuning, run-now, migration, topology, and admin halt-bypass authorities compose correctly at HEAD.

The main residual risk is test granularity rather than implementation behavior: I found no dedicated unit test that asserts `payout_admin_invoked_while_halted` is emitted only after successful operator-key auth. The chi wrapping order is still correct in code, so this is not a finding for this lane.

## Analysis

### r1 closure verification: LinuxRequired=true

`setupPayout` fails fast through `AssertPayoutRuntimeTopology` before signer, RPC, runner, or mux construction, and passes `LinuxRequired: true` when `payout.enabled=true` at `phase4-coordinator/cmd/coordinator/main.go:677`. The adjacent comment explicitly ties the flip to SPEC §6.3 and the Step 1 r2 carry at `phase4-coordinator/cmd/coordinator/main.go:671`.

The topology primitive rejects non-Linux only when `LinuxRequired` is set at `phase4-coordinator/internal/payout/topology.go:83`, and the new regression test exercises that exact gate with runtime-specific expected behavior at `phase4-coordinator/internal/payout/topology_test.go:70`.

### Authority enumeration

| Authority | Verdict | Evidence |
|-----------|---------|----------|
| `TuningProvider` | PASS | `RunOnce` captures one per-cycle snapshot at `phase4-coordinator/internal/payout/runner.go:433`; downstream reads use `r.snap()` for confirmation depth at `phase4-coordinator/internal/payout/runner.go:1234`. Run-now reads live tuning per invocation at `phase4-coordinator/internal/payout/runnow.go:92`, and RPC SPKI closures read `tuningProvider.Snapshot()` per handshake at `phase4-coordinator/cmd/coordinator/main.go:733`. |
| Halt primitive | PASS | `RequestHalt` is idempotent via `CompareAndSwap` at `phase4-coordinator/internal/payout/runner.go:191`; `RunOnce` refuses before cycle work at `phase4-coordinator/internal/payout/runner.go:406`; row-loop and irreversible-window gates are at `phase4-coordinator/internal/payout/runner.go:539`, `runner.go:797`, `runner.go:1150`, and `runner.go:1304`. |
| `RunNowController` | PASS | All mux levels delegate run-now to the controller: Step2 at `phase4-coordinator/internal/payout/mux.go:175`, Step3 at `mux.go:243`, Step4 at `mux.go:340`. The controller maps halted admission and post-RunOnce halt races to `409 runner_halted` at `phase4-coordinator/internal/payout/runnow.go:157` and `runnow.go:179`. |
| Lease / self-fence | PASS | Runner construction follows `Acquire` at `phase4-coordinator/cmd/coordinator/main.go:788`; persisted-byte rebroadcast self-fences before chain write at `phase4-coordinator/internal/payout/runner.go:789`; fresh allocation self-fences post-COMMIT at `runner.go:1131`. |
| Pause flag | PASS | Pause/resume owns writes through `RuntimeFlagWriter` in setup at `phase4-coordinator/cmd/coordinator/main.go:853`; the registration handler uses the persistent pause reader wired at `main.go:777`. |
| Bootstrap sentinel | PASS | Startup calls `BootstrapRuntimeFlags` before listener mount at `phase4-coordinator/cmd/coordinator/main.go:651`; the sentinel/flag halt paths remain in `phase4-coordinator/internal/payout/bootstrap.go:77`. |
| §4.1 import boundary | PASS | The runner exposes a narrow `PayoutClaimer` interface at `phase4-coordinator/internal/payout/runner.go:38`; import boundary tests remain in `phase4-coordinator/internal/payout/importgraph_test.go:28`. |
| §6.3 co-residency + Linux gate | PASS | `HandlerEnabled:true`, `RunnerCoResident:true`, and `LinuxRequired:true` are co-located in the startup topology call at `phase4-coordinator/cmd/coordinator/main.go:677`; the topology helper rejects handler-without-runner at `phase4-coordinator/internal/payout/topology.go:92`. |
| Admin halt-bypass policy | PASS | Step2 wraps abandon and leaves run-now halt-blocked at `phase4-coordinator/internal/payout/mux.go:165`; Step3 wraps abandon, pause, resume, record-funding, and record-orphan at `mux.go:235`, `mux.go:248`, `mux.go:253`, `mux.go:259`, and `mux.go:262`; Step4 wraps the same five at `mux.go:335`, `mux.go:343`, `mux.go:348`, `mux.go:353`, and `mux.go:355`. `r.With(auth).Post(..., withHaltObservability(...))` means operator-key middleware runs before the wrapper; unauthorized requests return at `mux.go:398` and never call the wrapped handler. |

### Cross-step composition

Halt plus shutdown is correctly synchronized. Main starts runner, reorg poller, reaper, and chain-balance worker at `phase4-coordinator/cmd/coordinator/main.go:340`; shutdown first cancels other background work, then calls the payout stop closure at `main.go:407`. The closure stops chainWorker first, then runner, then reorgPoller, then reaper at `main.go:1022`; lease release is gated on `runnerClean && pollerClean` at `main.go:1030`. A mid-cycle halt only flips atomics and emits through `RequestHalt`, so it does not wait on `Stop()` or introduce a lock cycle.

Tuning and halt are intentionally separate authorities. The runner captures a per-cycle tuning snapshot at `phase4-coordinator/internal/payout/runner.go:438`; the new halt gates read `r.halted.Load()` directly at `runner.go:539`, `runner.go:797`, `runner.go:1150`, and `runner.go:1304`. That separation is correct: halt is an immediate process-local breaker, not a SIGHUP-tuned cycle parameter.

Migration ordering remains monotonic and rerun-safe. `Migrate` gathers embedded `.sql` filenames, sorts them lexicographically, and iterates in sorted order at `phase4-coordinator/internal/payout/migrations.go:58`. The r1 rewrite happens before execution at `migrations.go:92`; the `payout_schema_applied` marker insert still happens after the rewritten statement succeeds at `migrations.go:99`. The rewrite only strips already-present `ALTER TABLE ADD COLUMN` statements and preserves the rest of the body at `migrations.go:127`.

The post-COMMIT halt gate before fresh broadcast does not create a money-path observability gap. `RequestHalt` already emits the PAGE at `phase4-coordinator/internal/payout/runner.go:198`; if the current row returns `rowOutcomeSkipped`, the row-loop boundary emits `payout_runner_halted_skipping_rows` before any next row at `runner.go:539`. The persisted unsigned-broadcast state is documented inline at `runner.go:1142`; the next non-halted process reaches the persisted-byte path at `runner.go:716` and the rebroadcast gate documents the same replay behavior at `runner.go:793`. I found no runbook-level description of this internal replay path, but the operator-facing halt event and recovery posture are present, so I do not classify this as an architecture defect.

The Step1 nil-runner question is not an applicable runtime path. `NewMux` has only the provider-token registration route and fallback at `phase4-coordinator/internal/payout/mux.go:88`; admin halt-bypass wrapping starts in Step2. The wrapper itself is nil-safe at `mux.go:380`, but Step1 does not need to pass nil into it because Step1 has no admin endpoint.

Runtime and deploy-gate RPC URL constraints are split in an audit-stable way. Runtime validation is the trust root: `Validate` calls `validatePayoutRPCURL` for both URLs and enforces distinct hostnames at `phase4-coordinator/internal/config/config.go:1069`. The helper rejects non-HTTPS, userinfo, and literal internal/loopback/link-local/unspecified IPs at `config.go:1280`. The deploy gate mirrors those obvious checks as defense-in-depth and explicitly documents that hostname trust is deferred to TLS/SPKI at `phase4-coordinator/dist/check-deploy-config.sh:358`. Env-indirected values are resolved by runtime config loading at `config.go:737`, and the deploy gate defers unresolved env references back to runtime at `check-deploy-config.sh:333`.

Step 3 advisories remain tracked. The Step 4 convergence summary calls for one PR-open tracking issue covering the deferred [arch:4.5] advisories at `specs/SPEC-016-IMPL-STEP_4-r8-convergence.md:105`.

## Root Cause

No active architecture defect was found in r2. The r1 fix-pass moved the Linux gate to the correct topology authority and added the admin halt-bypass observability wrapper at the mux authority layer; the remaining reviewed behavior is intentionally split between startup invariants, immediate halt atomics, per-cycle tuning snapshots, and deploy-gate defense-in-depth.

## Recommendations

1. Add a focused mux regression test for admin halt-bypass observability - small effort - medium confidence gain. Exercise bad operator key returning 401 with no emit, then good operator key while halted emitting `payout_admin_invoked_while_halted` before the handler runs.
2. Consider adding a short runbook note for post-COMMIT halted signed bytes - small effort - low operational impact. The code path is correct, but a note would help operators understand why an unbroadcast signed attempt may exist during a halted incident.

## Trade-offs

| Option | Pros | Cons |
|--------|------|------|
| Keep current implementation | No code churn; authority placement is correct; targeted tests pass | Admin halt-observability ordering is code-evidenced rather than directly test-locked |
| Add mux observability test | Prevents future middleware-order drift; documents intended auth-before-observe behavior | More test harness work around logger capture |
| Add runbook replay note | Improves incident operator understanding | Documents an internal recovery detail that most operators should not manually manipulate |

## Final PR Readiness Matrix

| Row | Verdict |
|-----|---------|
| §3.2 EIP-712 register | PASS |
| §3.3 cooling-off + pre-auth pause | PASS |
| §3.4 audit-log emits | PASS |
| §4.1 import boundary | PASS |
| §4.2 admin run-now contract | PASS |
| §4.3 9-step runner cycle | PASS |
| §4.4 two-RPC discipline | PASS |
| §4.6 abandon endpoint | PASS |
| §4.7 reorg detection + carve-out | PASS |
| §4.8a reaper | PASS |
| §4.8b lease | PASS |
| §4.8c stale-transition CAS + outbox | PASS |
| §4.9 record-funding | PASS |
| §6.2 balance monitoring emits | PASS |
| §6.3 co-residency + Linux gate | PASS |
| §6.4.1 pause/resume | PASS |
| §6.5 dual-namespace loader split + SIGHUP | PASS |
| §7.1 event field-name compliance + new payout_runner_halted_skipping_rows + payout_admin_invoked_while_halted | PASS |
| §7.3 provider-scoped read endpoint | PASS |
| §7.4 reconciliation queries + chain-balance worker | PASS |
| Ops bundle | PASS |
| 5-background shutdown composition | PASS |
| TuningProvider authoritative across consumers | PASS |
| Halt primitive authoritative across entry points | PASS |
| Migration ordering monotonic + idempotent | PASS |
| Step 3 advisories tracked or deferred | PASS |
| Admin halt-bypass policy explicit | PASS |
| Payout RPC URL trust constraints | PASS |

## Validation

- `go test -count=1 ./internal/payout ./internal/config ./cmd/coordinator` from `phase4-coordinator/`: PASS.
- `bash dist/test/check_deploy_config_test.sh` from `phase4-coordinator/`: PASS, 44 assertions.
- `git diff --check`: PASS.

## References

- `phase4-coordinator/cmd/coordinator/main.go:677` - enabled payout topology call sets `LinuxRequired:true`.
- `phase4-coordinator/internal/payout/topology.go:83` - topology Linux gate.
- `phase4-coordinator/internal/payout/topology_test.go:70` - LinuxRequired gate regression test.
- `phase4-coordinator/internal/payout/mux.go:165` - Step2 abandon wrapped with halt observability after auth.
- `phase4-coordinator/internal/payout/mux.go:335` - Step4 five-endpoint halt-bypass policy.
- `phase4-coordinator/internal/payout/mux.go:380` - wrapper nil-safe halt check.
- `phase4-coordinator/internal/payout/runner.go:191` - idempotent halt primitive.
- `phase4-coordinator/internal/payout/runner.go:539` - mid-cycle row-loop halt gate and observability emit.
- `phase4-coordinator/internal/payout/runner.go:1150` - post-COMMIT pre-broadcast halt gate.
- `phase4-coordinator/internal/payout/migrations.go:58` - lexicographic migration ordering.
- `phase4-coordinator/internal/payout/migrations.go:99` - marker insert after rewritten migration execution.
- `phase4-coordinator/internal/config/config.go:1069` - runtime RPC URL trust-root validation.
- `phase4-coordinator/dist/check-deploy-config.sh:358` - deploy-gate mirror of RPC URL constraints.
- `specs/SPEC-016-IMPL-STEP_4-r8-convergence.md:105` - Step 3 advisory tracking remains assigned to PR-open issue.
