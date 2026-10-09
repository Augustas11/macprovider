=================== codex-you-are-the-code-lane-auditor-for-pr-1923-augustas11-macprov-2026-10-09T13-47-36-185Z.md
## Raw output

```text
Code-lane gate: **NOT MET** — one MEDIUM remains.

Round 1 verification:

- **FIXED:** LM Studio runtime-path trust. `LMStudioLoopback.swift:122-169` no longer decodes or trusts a runtime path; artifact resolution now requires local matching files.
- **FIXED:** Claim credential-store fallback. `ClaimCommand.swift:185-193,237-251` fails closed on store-read errors and only falls back when no stored claim exists.
- **NOT FIXED:** MLX loopback auto-detection still trusts unrelated servers and can probe the live 8080 port.
- **FIXED:** SPEC-014 contradiction. Legacy bearer text is explicitly superseded; current cookie semantics are normative at `specs/SPEC-014-provider-portal.md:569-589,704-713`.
- **FIXED:** SPEC-043 metadata mismatch. Both version declarations are `0.3.1`.

Findings:

1. **MEDIUM — Round 1 finding remains: MLX discovery accepts the wrong loopback server.**

   `phase3-binary/Sources/macprovider-cli/MLXLMLoopback.swift:58-63,115-132` accepts any loopback service returning exactly one absolute model ID that resolves under an approved directory. Configured origins bypass the `servePort` exclusion. Additionally, `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:2601-2610` calls discovery without excluding the provider’s live port, so port 8080 may be probed during model discovery.

   Failure scenario: an unrelated OpenAI-compatible service on `127.0.0.1:8080` or `:8081` returns one plausible absolute model path. The CLI identifies it as `mlx_lm.server`, binds the wrong model, and may advertise or serve against that process.

   Fix: require an MLX-specific identity/fingerprint or explicit opt-in; thread `servePort` through all discovery paths; apply exclusion to configured origins as well.

2. **LOW — Pricing-bounds “unset” rejection is not mapped to an actionable CLI error.**

   `phase3-binary/Sources/macprovider-cli/CreatorCommand.swift:660-668` maps only `pool_model_pricing_out_of_bounds`. The coordinator separately emits `pool_model_pricing_bounds_unset` (`phase4-coordinator/internal/poolmanifest/model_entries.go:99-108`, `trustpool/admin_handler.go:1767-1782`).

   Failure scenario: bounds are unavailable when signing or are removed before submission. The coordinator rejects the manifest, but the CLI displays a generic HTTP error instead of explaining that pricing bounds are missing and what action is required. The pending manifest remains safely, so this is an error-mapping/operability issue.

   Fix: map `pool_model_pricing_bounds_unset` explicitly to a clear actionable `CreatorCLIError`, and add a regression test.

Checked without findings: Swift/Go offer canonicalization including unset requested IDs, pool binding and migration, manifest supersede expiry cuts, LM Studio ambiguity handling, claim ordering, restart behavior, portal cookie handling, and proposal pricing hints.

C/H/M/L = 0/0/1/1
=================== codex-you-are-the-security-lane-auditor-for-pr-1923-augustas11-mac-2026-10-09T13-43-07-527Z.md
## Raw output

```text
Result: no CRITICAL or HIGH security defects remain in the reviewed code paths. One MEDIUM normative-spec inconsistency remains, plus the explicitly carried LOW durable-directory ambiguity.

Round 1 security findings:

- HIGH — FIXED — Cookie scope/fixation. `phase4-coordinator/internal/session/cookie.go:12-40` now issues `__Host-mp_session` without `Domain`; legacy `mp_session` never authenticates and is cleared. Ownership authorization is enforced in `phase4-coordinator/internal/ws/auth_github.go:347-384`.
- HIGH — FIXED — Provider-controlled `--from-proposal` fields. `phase3-binary/Sources/macprovider-cli/CreatorCommand.swift:816-860` rejects embedded creator fields and requires creator flags. Proposal pricing/context values remain unsigned hints only when flags are missing.
- HIGH — FIXED — MLX loopback path trust. `phase3-binary/Sources/macprovider-cli/MLXLMLoopback.swift:66-200` requires approved roots, resolves symlinks, and fails closed on malformed paths.
- HIGH — FIXED — LM Studio path selection. `phase3-binary/Sources/macprovider-cli/BYOMArtifactDigest.swift:399-449` ignores the runtime-reported path and resolves a unique local GGUF under the approved root.
- MEDIUM — FIXED — Earnings caching. `phase4-coordinator/internal/billing/endpoints.go:1169-1173` and the nginx location set `Cache-Control: private, no-store` and `Vary: Cookie, Authorization`.
- MEDIUM — FIXED — Credential-store fallback. `phase3-binary/Sources/macprovider-cli/ClaimCommand.swift:185-192,237-252` fails closed on store errors and does not fall back to stale tokens.
- LOW — FIXED — Empty `requested_pool_model_id`. `phase4-coordinator/internal/ws/model_admission.go:2726-2732` rejects present-empty/null values.

Remaining findings:

1. MEDIUM — stale contradictory security contract

   File: `specs/SPEC-014-provider-portal.md:590-605,1617-1621,1660-1664`

   Failure scenario: v0.11 says cookie-authorized earnings are live, but active text and acceptance criteria still say earnings are bearer-only, return 401, and relaunch OAuth. A future implementation, test, or deployment review could revert the ownership check or incorrectly mark the fixed portal flow as unsupported.

   This is pre-existing text exposed by the v0.11 change; the runtime authorization is correct.

   Fix: remove the obsolete claims from active normative sections, or move them into an explicitly non-normative historical appendix. Update A.2/C.1/A.5 acceptance criteria to require cookie-mode earnings.

2. LOW — ambiguous durable model-directory decoding

   Files: `phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift:300-313`; `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:4074-4078`

   Failure scenario: `/` is encoded as `--`, then every `--` is decoded as `/`. A model identifier containing `--` can therefore decode to a different model identity, causing native durable discovery to summarize or offer the wrong directory.

   Pre-existing; carried as requested. Fix with an unambiguous encoding or authenticated sidecar metadata.

No additional issues found in:

- earnings ownership, CSRF/cross-site reads, cookie scope, rate limiting, or 401/403/404 enumeration;
- signed `requested_pool_model_id` binding, replay, downgrade, or non-member pool selection;
- manifest supersession, rollback, double activation, expiry, or revocation;
- pricing-bound enforcement;
- creator self-serve ownership, revoke, lifecycle, and proxy-header authorization;
- loopback symlink/traversal/hash handling;
- restart token handling.

The pre-existing claim URL/pair token appearing in `/usr/bin/open` arguments was not introduced by this diff and is not counted.

Targeted cookie, self-serve, router, and portal tests reported passing; `git diff --check` also passed. No files were edited.

C/H/M/L = 0/0/1/1
=================== codex-you-are-the-architecture-lane-auditor-for-pr-1923-augustas11-2026-10-09T13-43-14-706Z.md
## Raw output

```text
Architecture audit result: **FAIL** — 3 Medium findings remain. No files were edited. The checkout reports 65 changed files.

Round 1 verification:

1. **FIXED** — Proposal creator fields now come only from flags; proposal pricing/context are hints only (`CreatorCommand.swift:816-860`).
2. **FIXED** — Ambiguous binding guidance now withdraws before resubmission (`ModelsSubcommand.swift:3114-3125`).
3. **FIXED** — New CLI fails closed against an old coordinator without silently dropping pool selection (`BYOMDiscovery.swift:1945-1952`; guide `:336-339`).
4. **FIXED** — Portal clears stale earnings on cookie authorization failures (`index.html:716-723`).
5. **FIXED** — SQLite migration retries busy/locked errors with bounded backoff and duplicate-column handling (`model_admission.go:796-842`; migration tests).
6. **NOT FIXED — pre-existing LOW, carried Arch L6** — `--`-based durable model-directory decoding remains ambiguous (`BYOMDiscovery.swift:4029-4033`; encoder `DurableModelArtifactStore.swift:300-313`).
7. **FIXED** — Auto-detected MLX paths are confined to approved roots (`MLXLMLoopback.swift:66-132`).
8. **FIXED** — Creator guide now cites SPEC-043 0.3.1.
9. **FIXED** — Creator status labels manifest timing as local state (`CreatorCommand.swift:1144-1151`).

Findings:

1. **MEDIUM — SPEC-042 supersession is not downgrade-safe**

   File: `phase4-coordinator/internal/poolmanifest/policyhistory.go:160-167,195-219`; rollback check `phase4-coordinator/internal/trustpool/rollback_replay_check.go:65-145`

   Scenario: the new coordinator accepts overlapping v1/v2 policy windows under SPEC-042-R001. The old coordinator still rejects any overlap during manifest reconstruction. Existing rollback preflight checks encoding/runtime classes but not the old overlap rule, so it can pass and the downgraded coordinator then disables the pool or marks it stale.

   Fix: make rollback preflight validate target-version policy semantics, including rejection of overlapping windows, and block downgrade while such history exists.

2. **MEDIUM — Downgrade can silently discard `requested_pool_model_id`**

   Files: `phase4-coordinator/internal/ws/model_admission.go:180-184,783-784,1164`; `phase4-coordinator/internal/ws/model_admission_pool_manifest.go:531-577`; old logic `origin/main:phase4-coordinator/internal/ws/model_admission_pool_manifest.go:531-551`

   Scenario: a new coordinator stores an offer explicitly naming pool A while A is temporarily unmatched; pool B matches the same artifact. After rollback, the old coordinator ignores the new column, sees the offer as unnamed, and binds it to B. That persisted binding can later route and settle under the wrong pool.

   Fix: extend rollback preflight to block downgrade while any nonterminal offer has a nonempty selector, and prohibit concurrent old/new coordinator operation against the same database.

3. **MEDIUM — SPEC-014 still contains unqualified, contradictory v0.9 claims**

   File: `specs/SPEC-014-provider-portal.md:569-609,927-931,1170-1171,1617-1621`

   Scenario: the current implementation supports cookie-authorized, ownership-checked earnings, but these sections still say earnings cannot load, return 401, and lack ownership checks. Operators or acceptance tests following the normative-looking text may disable or reject the implemented path.

   Fix: rewrite these passages as explicitly historical/non-normative `[Superseded v0.11]` text, or replace them with the current contract.

4. **LOW — SPEC-042 embedded metadata remains at version 0.0.38**

   File: `specs/SPEC-042-pool-control-plane.md:14,415`

   Scenario: the document header/changelog and `CONFORMANCE.json` identify 0.0.42, while the embedded JSON advertises 0.0.38. Metadata consumers can associate the document with the wrong revision.

   Fix: update the embedded JSON version and reconciliation metadata to 0.0.42.

5. **LOW — Pre-existing Arch L6 remains**

   File: `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:4029-4033`

   Durable model IDs containing `--` can decode to a different model identity. This is pre-existing and carried from Round 1.

6. **INFO — Binary rollback across SPEC-014 v0.11 forces reauthentication**

   Files: `phase4-coordinator/internal/session/cookie.go:12-25`; `docs/operations/spec-014-v0.2-deploy.md:184-223`

   A pre-v0.11 coordinator only reads `mp_session`, while current sessions use `__Host-mp_session`; binary rollback with GitHub mode enabled therefore invalidates active sessions. The documented flag-first rollback is safe, but should explicitly state the reauthentication consequence.

Assessed with no finding: billing’s injected session-authorizer interface, lowest-pool-id admission followed by exact route binding, proposal pricing/context hint handling, normal mixed-version fail-closed behavior, cookie-domain hardening, and the bounded additive SQLite migration.

Validation: working tree clean; `git diff --check origin/main...HEAD` passed. No repository-wide tests or builds were run due the audit-only request and MacProvider host resource boundary.

**C/H/M/L = 0/0/3/3**
