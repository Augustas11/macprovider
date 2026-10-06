# #1690 M1 fix audit ROUND 3 (final) — lane: architect (single lane only)

Anchored re-audit. Branch fix/1690-loopback-startup-throughput. The branch's own change set is ONLY the three-dot diff vs main: audits/2026-10-06-1690-loopback-tps/diff-r3.patch (= git diff origin/main...HEAD). Round-2 fix commit is beeb86b51 (after merge 26106d9b9 of origin/main). Read touched files in full. Do NOT audit code that is not in diff-r3.patch.

Note: the round-2 security lane's two Pearl-updater findings came from a stale two-dot diff that showed main's own #1861 in reverse; ops/pearl-updater is not changed by this branch and is out of scope.

1. For EACH round-2 open finding below, state FIXED / NOT FIXED / PARTIAL with file:line evidence.
2. Then report any NEW issue in diff-r3.patch for this lane only.

## Round-2 output for this lane

```text
Architect lane re-audit of the full supplied diff:

1. **MEDIUM — PARTIAL — incompatible throughput semantics**

   The loopback probe now measures total request time and uses the native prompt/budget: `OpenAICompatibleLoopbackRuntime.swift:1289-1301`, `:1348-1385`; SPEC-001 documents the shared intent at `SPEC-001-phase3-binary.md:1169-1174`, `:1621-1628`.

   Still open: coordinator semantics remain implicit. `SPEC-002-coordinator.md:1986`, `:2416` and `server.go:641-645` apply the same field to routing floors and ordering without defining or testing the cross-runtime measurement contract.

   Failure: future runtime implementations can produce incomparable values while the coordinator treats them identically. Fix: amend SPEC-002 and add cross-runtime contract tests.

2. **MEDIUM — FIXED — chunk-count fallback**

   The startup probe now uses only upstream `usage.completion_tokens` or `timings.predicted_n`: `OpenAICompatibleLoopbackRuntime.swift:1377-1384`. The remaining `deltaEvents` fallback is explicitly display-only at `:599-601`. Regression coverage confirms chunk-only SSE fails closed at `OpenAICompatibleLoopbackRuntimeTests.swift:1892-1908`.

3. **MEDIUM — FIXED — stale deploy artifact verification**

   The route test accepts a config path at `check_nginx_model_admission_routes_test.sh:7-14`, deploy passes the exact `$NGINX_SITE` at `deploy-pearl-vps.sh:1798-1802`, and that same file is uploaded at `:3518`. The focused route test passed.

4. **LOW — NOT FIXED — metadata affects measured elapsed time**

   Timing begins before the HTTP request at `OpenAICompatibleLoopbackRuntime.swift:1348-1352` and ends only after all SSE lines and accumulator finalization at `:1364-1385`. Role, finish, usage, and `[DONE]` events remain in the measured interval; the fixture includes them at `OpenAICompatibleLoopbackRuntimeTests.swift:1784-1795`.

   Failure: delayed metadata can still change the reported rate. Fix: measure content-bearing/token timing or use authoritative upstream timing metadata.

5. **LOW — NOT FIXED — concrete runtime coupling and duplicated probe contract**

   `ModelRuntimeServing` has no probe requirement at `ModelRuntime.swift:13-57`; native and loopback implementations remain separate at `ModelRuntime.swift:8213-8244` and `OpenAICompatibleLoopbackRuntime.swift:1302-1308`. Serve dispatch still downcasts at `MacProviderCLI.swift:2733-2746`.

   Failure: a new conforming runtime can serve successfully but silently advertise zero throughput. Fix: add a shared probe specification/measurer protocol and dispatch through the existential.

New architect-lane issues: none verified.

Validation: route test, shell syntax checks, reverse patch application check, and `git diff --check` passed. Full Swift/Go suites were not run due the MacProvider local CI resource boundary.

C=0 H=0 M=1 L=2



## Lane focus
Architecture: is a CLI-side probe the right layer vs coordinator floor semantics; single source of truth for the probe constant/semantics shared with native ModelRuntime; coupling between MacProviderCLI serve wiring and the runtime actor; SPEC-001 FR-20/FR-17 amendment consistency with SPEC-002 routing and SPEC-046/SPEC-010 loopback SPECs; whether the nginx template + test are the right durable home (vs deploy tooling) and consistent with existing route tests.

## Output
Severity CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line, failure scenario and fix; only verified issues. End with one line: "C=<n> H=<n> M=<n> L=<n>" counting OPEN in-scope issues only.
