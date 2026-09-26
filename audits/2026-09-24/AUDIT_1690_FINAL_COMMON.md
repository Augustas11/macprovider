# #1690 final audit (PR #1719): common brief

**Method constraint.** This is a first-party software-correctness and specification review. Do NOT author malformed payloads or exploit inputs. Evaluate by reading source and specs, and run EXISTING tests only if needed. Describe gaps abstractly, in prose.

**Scope.** The FULL diff `git diff origin/main...HEAD`: the entire #1690 epic, rebased onto current main. It covers:
- M0: the benchmark harness and runner
- M1: SPEC-042-R006 labels and the candidate-env gate
- M2: the OpenAI-compatible loopback runtime
- M3: the SPEC amendments, audited separately to 0 C/H/M
- M4: the coordinator (policy-core/v2 runtime allowlist, pool route-time selection of external-runtime members, `pool_operator_attested` usage source, SPEC-022 R012 settlement and finality, per-request `pool_runtime_authorization`, the GGUF feed tuple)
- M5: the CLI per-request receipt eligibility
- the freeze-audit round-1 fixes (`audits/2026-09-24/AUDIT_1690_FREEZE_R1_*` are NOT on the branch; the resolutions are summarized in the commit messages of M4-fix and M5-fix)

**Invariants:**
- The global (poolless) network is unchanged: byte-identical poolless route-snapshot digests, the admission bar and hello sandbox unlifted, a loopback session on a global route never paid.
- An external runtime earns only on a pool route whose signed v2 policy core allowlists the coordinator-derived runtime class, for a current non-delegated member whose account is the pool creator, with an undisputed label, from snapshot-digested values only.
- The CLI signs a loopback receipt only for a request carrying a matching `pool_runtime_authorization`.
- An older CLI or coordinator fails closed.
- There is no money-path arithmetic change outside R012.
- The runner never pauses a provider without explicit opt-in, and always resumes it.

**Rebase note.** Main has #1689 amendments: SPEC-010 v1.10, SPEC-022 v0.1.9 with AC-022-65 / R-2.7. The #1690 M3 text therefore stacks as SPEC-010 v1.11, and its pool settlement criterion is AC-022-66. Check that the rebase merged these correctly, with no lost main behavior (#1728 settlement recovery, #1713 node-operator UX, #1720 disclosure).

**Output format.** Numbered findings, each with a severity (CRITICAL/HIGH/MEDIUM/LOW), file:line, the failure scenario, and a fix. End with exactly one line: `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
