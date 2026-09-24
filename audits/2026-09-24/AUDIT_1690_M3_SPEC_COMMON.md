# #1690 M3 SPEC audit: common brief

**Method constraint.** This is a first-party software-correctness and specification review. Do NOT author or construct malformed payloads or exploit inputs. Evaluate by reading the specs and the source, and by running EXISTING tests only if needed. Describe any gap abstractly, in prose (field + condition).

**Scope.** The full diff of commit `b4c06e21` ("M3: SPEC amendments for runtime-agnostic serving on Trusted Pools (#1690)"), against its parent `f244f9c1`: `git show b4c06e21`. It amends SPEC-042, SPEC-047, SPEC-022, SPEC-015, SPEC-010, SPEC-023, SPEC-032, SPEC-046 and SPEC-043, plus `specs/AUTHORITY.json`, `specs/CONFORMANCE.json`, three runbooks, and `beta/DECISION_CRITERIA.md` (entry 247).

**Intent.** Issue #1690 (the plan is in `gh issue view 1690 --repo Augustas11/macprovider`). External loopback runtimes (llama.cpp `llama-server` first) may serve and EARN only inside SPEC-042 Trusted Pools, under a signed runtime allowlist. The global network stays native-only.

**Invariants the text must guarantee:**
- The admission bar (`settlement_capable`) and the hello sandbox stay unlifted. The lift is route-time and pool-only.
- A pool member on a global route gets zero billable.
- `pool_operator_attested` requires ALL of: a pool route, current membership, runtime on the digested allowlist, and provider account == pool creator.
- A disputed label means `byte_estimated`.
- The usage source is derived only from route-snapshot digested values.
- The hello `runtime_source` only narrows.
- Older CLIs fail closed.
- The v0.4 receipt tuple is unchanged.
- SPEC-008 `attestation_tier` is untouched.
- Poolless route-snapshot digests are byte-identical.

**Context commits on the same branch:**
- `0515dc70` (M1): R006 labels and the candidate-env gate, in code.
- `f244f9c1` (M2): the loopback runtime, still non-earning.

Code anchors: `phase4-coordinator/internal/{routing,buyer,billing,ws,trustpool,poolmanifest}`, `phase3-binary/Sources/macprovider-cli/`.

**Output format.** Numbered findings. Each has a severity (CRITICAL/HIGH/MEDIUM/LOW), file:line evidence, the failure scenario, and a concrete fix. End with exactly one line: `VERDICT: <n_critical> CRITICAL / <n_high> HIGH / <n_medium> MEDIUM / <n_low> LOW`. Do not pad. If an area is sound, say so in one line.
