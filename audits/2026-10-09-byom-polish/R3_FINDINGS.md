=================== codex-you-are-the-code-lane-auditor-for-pr-1923-augustas11-macprov-2026-10-09T14-11-26-844Z.md
## Raw output

```text
Gate: **NOT MET** — one new MEDIUM. Reviewed all 70 changed files at `8249c45b8`; no files edited.

Round-2 CODE findings:

- **FIXED — MLX wrong-server/live-port detection:** fingerprint validation and configured-port exclusion are present at `MLXLMLoopback.swift:59,73,145`, with discovery callers passing the serve port.
- **FIXED — missing pricing-bounds error mapping:** `CreatorCommand.swift:668` provides actionable guidance and preserves the pending manifest; regression coverage is at `CreatorCommandTests.swift:511`.

Findings:

1. **MEDIUM — Incomplete HF cache hides a ready native model.**  
   [BYOMDiscovery.swift:4040](/Users/augstar/macprovider-1880-cli/phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:4040)  
   **Scenario:** An HF directory contains config but no usable weights, while the durable store contains a complete copy of the same model. Deduplication skips the durable copy at line 4050, retaining `needs_weights`. `models offer` and `models propose --yes` then fail because submission requires `ready` at line 1637.  
   **Fix:** Summarize both sources and prefer the ready candidate. Add a regression covering an incomplete HF duplicate alongside a complete durable copy; current coverage tests ready duplicates and an entirely absent HF root.

2. **LOW — SPEC-047 embedded version remains stale.**  
   [SPEC-047-network-model-admission.md:9](/Users/augstar/macprovider-1880-cli/specs/SPEC-047-network-model-admission.md:9)  
   **Scenario:** The header and new amendment identify `0.2.8`, but embedded metadata identifies `0.2.6`. Metadata consumers receive the wrong revision. This mismatch is **pre-existing**, exposed again by this amendment.  
   **Fix:** Update the embedded version to `0.2.8`.

3. **LOW — Pre-existing, carried Arch L6: ambiguous durable-directory decoding.**  
   [BYOMDiscovery.swift:4086](/Users/augstar/macprovider-1880-cli/phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:4086)  
   **Scenario:** A model ID containing literal `--` is decoded as `/`, producing a different identity.  
   **Fix:** Use unambiguous encoding or validated sidecar metadata, with compatibility handling for existing directories.

Validation: `git diff --check origin/main...HEAD` passed; portal regression tests passed **7/7**. Swift/Go tests were inspected, not executed.

C/H/M/L = 0/0/1/2
=================== codex-you-are-the-security-lane-auditor-for-pr-1923-augustas11-mac-2026-10-09T14-10-22-290Z.md
## Raw output

```text
Security gate **PASS** at `8249c45b88`. Reviewed the complete **70-file diff**, relevant callers, and changed SPECs. No new CRITICAL, HIGH, or MEDIUM findings.

Round-2 security verification:

- **FIXED — HIGH, cookie scope/fixation:** `session/cookie.go:12–40` uses host-only `__Host-mp_session`; `ws/auth_github.go:347–401` rejects legacy authentication and checks provider ownership.
- **FIXED — HIGH, proposal-controlled creator fields:** `CreatorCommand.swift:843–849` rejects embedded license/attestation and requires creator-supplied flags.
- **FIXED — HIGH, MLX path trust:** `MLXLMLoopback.swift:115–162` resolves symlinks and confines inferred paths to approved roots. Lines `59–93` additionally enforce serve-port exclusion and the server fingerprint.
- **FIXED — HIGH, LM Studio path selection:** `BYOMArtifactDigest.swift:417` resolves local matching GGUF files; runtime paths cannot select an artifact.
- **FIXED — MEDIUM, earnings caching:** `billing/endpoints.go:1172–1173` sets private/no-store and credential-aware `Vary` before every response; nginx mirrors it.
- **FIXED — MEDIUM, credential-store fallback:** `ClaimCommand.swift:242–258` propagates store failures without stale-token fallback or secret-bearing diagnostics.
- **FIXED — LOW, empty pool selector:** `ws/model_admission.go:2727–2731` rejects present-empty/null selectors.
- **FIXED — MEDIUM, contradictory SPEC-014 contract:** `SPEC-014-provider-portal.md:570–597` defines cookie ownership authorization and labels obsolete text non-normative; acceptance criteria at `1643`, `1662`, and `1690` require cookie-mode earnings.

Remaining finding:

- **LOW — NOT FIXED; pre-existing, carried Arch L6.** `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:4086`; encoder at `DurableModelArtifactStore.swift:303`. Encoding `/` as `--`, then decoding every `--` as `/`, changes `org/model--variant` into `org/model/variant`. Native durable discovery can advertise the wrong model identity. **Fix:** use an unambiguous encoding or validated sidecar identity metadata.

No additional findings in cross-site earnings reads, enumeration, signed selector binding/replay, supersession, pricing enforcement, creator authorization, or restart token handling.

Validation: portal auth tests **7/7 passed**; `git diff --check origin/main...HEAD` passed. No Go/Swift suites ran. Checkout remains clean; no files edited.

C/H/M/L = 0/0/0/1
=================== codex-you-are-the-architecture-lane-auditor-for-pr-1923-augustas11-2026-10-09T14-07-31-149Z.md
## Raw output

```text
Architecture gate: **NOT MET** — one MEDIUM remains. Reviewed `origin/main...HEAD` at `8249c45b8`: **70 changed files**. No files edited.

Round 2 verification:

- **FIXED — superseded-window detection:** [rollback_replay_check.go:141](/Users/augstar/macprovider-1880-cli/phase4-coordinator/internal/trustpool/rollback_replay_check.go:141) detects overlapping history and blocks pre-`p1880` targets. Regression coverage includes superseding and adjacent windows.
- **NOT FIXED end-to-end — selector downgrade safety:** live selector detection is implemented, but writes remain possible after preflight passes; finding 1 below.
- **FIXED — SPEC-014 contradictions:** [SPEC-014:567](/Users/augstar/macprovider-1880-cli/specs/SPEC-014-provider-portal.md:567) establishes the current normative earnings contract; A.2/A.5/C.1 acceptance criteria now require cookie-mode earnings.
- **FIXED — SPEC-042 metadata:** [SPEC-042:14](/Users/augstar/macprovider-1880-cli/specs/SPEC-042-pool-control-plane.md:14) advertises `0.0.42`.
- **NOT FIXED — carried Arch L6:** ambiguous durable-directory decoding remains; finding 3 below.
- **FIXED — rollback reauthentication disclosure:** [deployment guide:212](/Users/augstar/macprovider-1880-cli/docs/operations/spec-014-v0.2-deploy.md:212) explicitly documents sign-out across the cookie-name change.

Findings:

1. **MEDIUM — Rollback preflight does not fence subsequent writes.**  
   [pool_rollback_preflight.go:71](/Users/augstar/macprovider-1880-cli/phase4-coordinator/cmd/coordinator/pool_rollback_preflight.go:71), [rollback runbook:618](/Users/augstar/macprovider-1880-cli/docs/runbooks/trusted-pool-production-launch.md:618).

   **Failure scenario:** preflight returns 0 against the running coordinator after existing selector offers are withdrawn. Before the binary swap, a provider submits another signed selector-bearing offer. Buyer-ingress shutdown and paused pools do not prevent this: [model_admission.go:2172](/Users/augstar/macprovider-1880-cli/phase4-coordinator/internal/ws/model_admission.go:2172) persists offers independently of pool routeability. The downgraded coordinator then ignores the selector and can bind to another matching pool once routing resumes. A concurrent superseding manifest can similarly invalidate the history check.

   **Fix:** enforce a quiescent rollback sequence through `scripts/ops/`: stop coordinator writers, run the current binary’s preflight against the final database, and keep writers stopped through the swap. Explicitly prohibit concurrent old/new coordinators sharing that database. Add coverage for a write arriving between initial preflight and swap. The general preflight race is **pre-existing**, but this diff exposes it to the new selector and supersession semantics.

2. **LOW — LM Studio runbook still claims runtime paths disambiguate files.**  
   [trusted-pool-external-engines.md:113](/Users/augstar/macprovider-1880-cli/docs/runbooks/trusted-pool-external-engines.md:113).

   **Failure scenario:** an operator keeps two matching, same-size GGUF files because the runbook says publisher, size **and path** select the loaded artifact. The implementation deliberately ignores runtime paths and refuses that ambiguity.

   **Fix:** remove “and path”; state that publisher and size only narrow locally name-matched files, and multiple remaining files fail closed.

3. **LOW — Pre-existing, carried Arch L6: ambiguous durable-directory decoding.**  
   [BYOMDiscovery.swift:4086](/Users/augstar/macprovider-1880-cli/phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:4086).

   **Failure scenario:** a model ID containing literal `--` decodes those characters as `/`, producing a different discovery identity.

   **Fix:** use an unambiguous reversible encoding or verified sidecar metadata.

No additional findings in mixed-version offer canonicalization, additive SQLite migration, billing’s injected session-authorizer boundary, or lowest-pool-id admission followed by exact candidate binding.

Validation: portal regression tests **7/7 passed**; `git diff --check origin/main...HEAD` passed; checkout remained clean. Broad Go/Swift and hardware verification were not run.

C/H/M/L = 0/0/1/2
