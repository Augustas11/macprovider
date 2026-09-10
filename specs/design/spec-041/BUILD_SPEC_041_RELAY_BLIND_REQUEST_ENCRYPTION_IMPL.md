# BUILD_SPEC_041_RELAY_BLIND_REQUEST_ENCRYPTION_IMPL

Implement the complete SPEC-041 v0.2.0 default-off, global-pool pilot. SPEC-041 remains draft, pending-reconciliation, and not-deployed. Do not enable production, contact providers, move funds, promote CONFORMANCE, fabricate hardware evidence, or change the SPEC-015 v0.4 receipt tuple.

## Historical note

The previous version of this build spec described only gateway admission and disclosure. That slice remains valid historical partial work, but it cannot produce a successful relay-blind request and is superseded by this five-stage plan. Existing admission-only tests and CONFORMANCE references remain evidence of partial implementation only.

## Stage 1 - Provider identities and authenticated key lifecycle

- Add a dedicated durable Ed25519 relay-blind identity, independently operator-pinned to authenticated provider ID/session, plus a separate rotatable X25519 key.
- Implement SPEC-041 exact framing, limits, fingerprints, `kid`, signed-record digest, signature verification, monotonic renewal, rotation, revocation, freshness, and same-session checks in Go and Swift.
- Keep private material outside repository/worktrees with 0700 directories and 0600 files. Add shared deterministic public vectors only.
- Keep buyer success disabled.

Verify signature/identity substitution, duplicate/substituted kids, array framing, canonical base64url, low-order X25519, expiry/skew/lifetime, scope bounds, revocation races/restart, reconnect, and default off.

## Stage 2 - Reservations, consume, durable replay, and buyer CLI

- Implement the exact public/coordinator reservation and internal consume schemas from SPEC-041-R004.
- Preserve API-key and SPEC-040 wallet authentication, revocation, allowlists, caps, and metadata budgets. Strip/overwrite trusted internal headers and avoid wallet replay double-consumption.
- Reject every nonempty pool selection before reservation/quota/dispatch.
- Persist bounded coordinator reservation state and gateway replay state; consume atomically before quota/dispatch and burn all applicable terminal failures.
- Implement the reference CLI with `--identity-pin /absolute/local/file.json`, no-follow descriptor-based pin validation, signature/scope/time checks, exact encryption, and safe stdout/stderr separation.

Verify API/wallet success and mismatch cases, malicious pin paths/permissions/owners/replacement/oversize, replay concurrency/restart/config cycling, expiry/revocation, byte/cap bounds, and deterministic Go/Swift ciphertext vectors.

## Stage 3 - Opaque dispatch and provider execution journal

- Add SPEC-001-compatible `body_encoding: relay-blind-request-v1`; authenticate it within SPEC-008 when active.
- Branch before plaintext chat parsing. Dispatch opaque WebSocket-only to the exact session with no body rewrite, HTTP fallback, failover, or provider substitution.
- Claim the framed execution identity using exclusive create and file+directory fsync before decrypt/runtime; use atomic rename+fsync for terminal state.
- Decrypt, validate the exact inner chat request and actual tokenized input bounds, persist authenticated validation evidence, then run inference at most once.

Verify every AAD field/tag, encoding namespace, low-order input, inner schema/caps/tools/structured output, delayed prior-session evidence, context tampering, and crash cuts before claim, after claim, after decrypt, before first token, partial output, and terminal persistence/send loss.

## Stage 4 - Existing accounting and truthful disclosure

- Thread the bounded relay facts through coordinator `request_log`, gateway `usage_events`/journal, recovery, quota, ordinary SPEC-005 settlement, provider earnings, payment, and payout readiness.
- Reject SPEC-022 enforce mode before quota. Under off/observe, exclude relay-blind work permanently from positive receipt claims, mirrored/verified state, SPEC-022 verified-work rewards, and positive verified-work aggregates.
- Clamp input/output under SPEC-041 without estimating tokens from ciphertext or fabricating plaintext hashes/snapshots.
- Emit exact requested/effective outcome, scope, settlement labels, and retry action in headers, JSON success/error, SSE usage/terminal/error, `/v1/models`, status, and CLI output. Never expose stable provider identity such as `X-Provider-Id`.

Verify known/unknown/overreported input, underdeclared actual input rejection, partial output, settlement failures/recovery, duplicate terminal delivery, reward exclusion, and unchanged plaintext/SPEC-008 behavior.

## Stage 5 - Integrated success, recovery, and review

Run real local buyer -> gateway -> coordinator -> Swift provider nonstream and streaming requests using a deterministic backend. Cover quota, request_log, usage journal, delivery accounting, cancellation, partial output, provider loss, timeout, reconnect, and every coordinator/provider/gateway restart state. Mixed/disabled binaries fail before quota; `responses`, `messages`, and all pool-scoped requests remain unsupported.

Scan captured logs/errors for fixture plaintext, ciphertext, private material, bearer values, and stable public provider identifiers. Use signed journey tooling only when an authorized test signer exists and label evidence honestly.

Run targeted tests first, then relevant Go tests/build/vet, Swift tests, integration, dist, and governance checks. Review the complete diff through independent code, security, architecture, adversarial-verifier, and product-design lanes. The implementation gate is zero Critical, High, and Medium findings. Use a Lore commit, validate the governance declaration, push the task branch, and open a PR. Do not merge.
