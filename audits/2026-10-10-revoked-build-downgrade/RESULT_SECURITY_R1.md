# Round 1 — SECURITY lane (omc ask codex)


MEDIUM — phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:4787 — **PRE-EXISTING, exposed by this rollback workflow:** When unhealthy P rolls back to V, cleanup requires V to prove coordinator buyer-serving capability. Exactly-revoked V cannot do so. The pending marker remains and blocks subsequent updater transactions, including after cooldown or a healthy forward-fix recommendation. The new runbook’s automatic-retry claim is incorrect. — Add recovery that validates the restored set’s identity and local health, retires the failed transaction while retaining the buyer-serving fence, and permits another verified update. Correct the runbook and test this sequence.

LOW — specs/SPEC-020-provider-autoupdate.md:1559 — **NEW:** T-4 correctly acknowledges forged revocation under coordinator compromise, but “no larger than T-3” understates the distinct risk of restoring previously patched vulnerabilities. Its signed-policy guarantees also apply only to policy already observed locally. T-3 still contradictorily excludes all downgrade artifacts. — Explicitly document bounded rollback to vulnerable signed history, qualify enforcement by locally observed policy, and reconcile T-3.

No confirmed unauthorized downgrade or weakened artifact-verification path was found. Exact set binding, strict boolean handling, canonical downgrade-version parsing, the floor, signature/hash/manifest/index checks, staged identity/version checks, and Malibu verification remain enforced. Discovery and production manual-update paths remain forward-only; ops arguments cannot inject shell syntax, and the edit rejects revoking its resulting target.

Residual coordinator-compromise risk: the attacker can forge the revocation assertion and select an older legitimately signed release within the floor and effective policy bounds. Signing proves release authenticity, not present-day safety.

Read-only static audit; no network commands, edits, or test execution.

VERDICT: C=0 H=0 M=1 L=1
