# SPEC-008 — Tier-2 Trust Layer

**Version:** 0.4 (2026-07-11, attestation-reconciliation pass)
**Depends on:** SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-004 v0.3.1,
               SPEC-006 v0.8.1

**Change log v0.4 (runbook item 7 — spec-only reconciliation of shipped attestation):**
The shipped, default-enabled self-signed Secure-Enclave attestation path
(`macprovider-se-p256-v1`) was entirely absent from v0.3, which documented only the
Apple-MDA path. SPEC-032 (proof-of-weights) now names SPEC-008 authoritative on
attestation, so v0.4 documents the shipped reality (no code change — the code is the live
cross-repo interop contract the Swift provider CLI byte-matches):
- **§3 / §7-intro / §9.2 (foundational reconciliation):** broadened the load-bearing
  definitions of "Attested provider" and Pillar C from MDA/trust-root-only to the shipped
  two-format reality — self-signed SE (`self_signed`, key-custody, default) **and** the
  aspirational MDA `hardware` path — so "attested" no longer normatively means "hardware".
- **§7.3:** added the `attestation_tier` taxonomy (`""` / `self_signed` / `hardware`) and
  is explicit that `self_signed` proves **key custody + session binding only** (not
  Secure-Enclave custody, Apple-Silicon provenance, or device identity: `hardware_family`
  is an unauthenticated self-assertion), that a successful **MDA/mock** attestation is
  still `attested` but carries an **empty** tier (the shipped WS handler labels only the SE
  path — so `hardware` is never emitted), and that any future tier consumer MUST treat an
  empty tier on an `attested` provider as "attested, strength unlabelled" (SPEC-032 does
  not yet consume the tier — forward).
- **§7.4a (new):** documents `macprovider-se-p256-v1` byte-for-byte — the unpadded-base64url
  JSON token envelope, DER/ES256 body signature, raw 64-byte `x‖y` key parsed by splitting
  (no `0x04` prepend) with an exact-length + `IsOnCurve` check, the per-field base64
  variants (RawURL token/binding vs flexible inner body vs byte-matched
  `encryptionPublicKey`), the interop-critical **Go `encoding/json` (sorted-keys,
  HTML-escape ON: `<`/`>`/`&` -> `\u003c`/`\u003e`/`\u0026` — NOT RFC-8785 JCS)**
  canonicalization, and the **fixed 10-field** `macprovider/spec008/attestation-binding/v1`
  session-binding payload.
- **§7.4b (new):** documents the shipped SE **liveness re-challenge** protocol
  (`se_liveness_challenge`/`_response`): padded-URL-base64 nonce, RFC3339 timestamp, and a
  standard-base64 DER-ES256 signature over `SHA-256(nonce‖timestamp)` verified against the
  stored SE key; 3 consecutive failures → stale + close.
- **§4.3:** carved out the always-on attestation verify + `T2.C` diagnostic log for a
  v2.0 provider that volunteers a token at defaults (previously read as "no Tier-2 logs at
  defaults"), and corrected the buyer-visibility claim (see the §4.3 entry below — the
  gateway surfaces attestation for **any** ready provider even at defaults, so the
  "no buyer-visible change" invariant does not hold).
- **§7.4:** scoped "accepted encodings" per format (v0.3's "no other encodings" clause
  wrongly forbade the shipped SE JSON envelope) and added the 20-KiB outer-envelope cap
  alongside the 16-KiB token cap.
- **§7.5/§7.2:** scoped the trust-root requirement to the MDA/mock formats (the shipped SE
  path is accepted with an empty `attestation_roots`).
- **§7.7 / AC-T2-18:** reconciled to the shipped **network-level**
  `tier2.attestation{state,…}` disclosure — `state` enum `none|all|partial|unsupported`
  with a separate `mixed` boolean, counting only `StateReady` providers (matches §13.3);
  the v0.3 per-model block is retained as a **deferred** forward enhancement.
- **§13.3/§7.6 (trust honesty):** the buyer-visible **`hardware_attestation`** field is
  derived from the tier-blind `attested` aggregate (coordinator `attestationStateForProviders`
  → gateway `disclosure.HardwareAttestation`) with no `attestation_tier` check, so an
  all-`self_signed` (software-key) pool discloses `hardware_attestation: "all"` — documented
  as a **known overstatement** (the field is a misnomer for the SE path; buyers/consumers
  MUST NOT read it as hardware proof) with the gating/rename fix carried as a forward
  coordinator+gateway change. §7.6 makes explicit that `require_attestation` admits
  `self_signed` and does not require hardware. §13.3's activation and counting basis were
  reconciled to the shipped **pool-evidence-driven gateway** surface + `StateReady` counting;
  §7.7 (the coordinator `/v1/models` surface) was distinguished from it (`ConfigActive`-gated).
- **§4.3 / §13.3 (activation):** corrected — the gateway surfaces attestation for **any**
  `StateReady` provider (a legacy/tokenless pool discloses `hardware_attestation:
  "unsupported"`; state is `none` only for an empty ready pool), even at coordinator-default
  config (the gateway keys off `/internal/routing`, not the `/v1/models` `ConfigActive`
  gate). The earlier "not buyer-visible at defaults" and "activates on an attested provider"
  claims were both wrong. `unsupported` denotes every all-non-attested ready pool
  (failed/stale/`not_required`/empty/unsupported-format), not just unsupported-format.
- **§7.4/§10.4/§4.6:** reconciled attestation-token rejection transport — oversize/malformed
  tokens collapse to WS status `attestation_failed` + close `4012`, not an HTTP-400 code (the
  §4.6 `tier2_attestation_token_*` rows are a forward HTTP catalog).
- **§7.5/§11.2:** documented the verifier-vs-startup asymmetry (SE needs no root, but
  `require_attestation: true` still requires ≥1 `attestation_roots` at startup).
- **§7.3/§7.5 (check order):** `attestation_stale` (challenge/freshness) is classified
  **before** signature verification, so it does not imply the token was cryptographically
  valid; §7.5 reordered to the shipped identity→challenge→binding→hardware-family→freshness
  →signature sequence.
- **§13.2 (phase):** phase is config-driven and folds in only Pillar A model-hash pool
  evidence — encrypted-leg/attestation pool evidence does not affect phase, so a default
  pool can compute phase `0` while the gateway discloses non-`none` attestation.
- **§7.6/AC-C-1/AC-T2-16/AC-T2-5:** gated the `/v1/models` attestation-report requirement
  on `ConfigActive` (a volunteered token / configured root alone does not activate it), and
  scoped AC-T2-5 baseline-preservation to the coordinator surface (the gateway discloses for
  any ready provider).
- **§10.4/§10.5:** `binary_version` is signed-if-present but not required non-empty; the
  accepted `auth_response` omits the `attestation.format` field (`omitempty`).
- **§1.1/§3/§4.4/§7.1 (definitional sweep, completing the R3 fix):** the remaining
  load-bearing "Pillar C = hardware attestation" definitions and threat-model claims were
  scoped to the two-format reality — the shipped default `self_signed` SE path reduces only
  key-substitution/stale-token risk (key custody + freshness + session binding), while
  false-hardware/device claims are addressed only by the aspirational MDA path.
- **§1.1/§11/§13.2 (default-preservation scope):** the "every default preserves Tier-1
  behavior" invariant was scoped to the **coordinator's own** surfaces; the buyer-visible
  **gateway** disclosure activates on `/internal/routing` pool evidence (any `StateReady`
  provider → `hardware_attestation: "unsupported"`) and is a documented cross-service
  exception, not byte-identical at defaults.
- **§7.6/§13.3 (`ConfigActive`):** the definition now includes `behavioral_safety_enabled`
  (enabling Pillar D alone attaches the whole `/v1/models` `tier2` block, incl. attestation).
- **§7.3:** `attestation_stale` is excluded from routing **only** when
  `require_attestation: true` (was wrongly stated unconditional); added the legacy empty
  (`""`) status. **§9.2:** the trust-root prerequisite is MDA/enforcement-only (SE needs
  none). **§13.2 phase-0:** only Pillar A model-hash pool evidence affects phase. **§14:**
  restored the AC-T2-6 heading (accidentally dropped in R3).
- **§5.7:** clarified the hash-disclosure counting basis is slot-holders
  (`hasAvailableSlot`); `RoutingEligible` has no hash check — the hash routing-exclusion is
  the separate §5.5-5.6 predicate (mismatch/invalid always; uncatalogued only when
  `require_hash_verified`).
- **§6.4/§6.5:** corrected the transcript labels (`provider_public` /
  `coordinator_public` / `selected_aead`, which are hashed) and pinned the uint32-BE
  length framing / one-byte stream flag / JSON decode-fallback for the binary AAD.
- **§11.1/§11.5:** added `allow_mock_attestation` to the config shape and corrected the
  SE-liveness reload semantics — `se_liveness_interval_s` is stored on reload but not
  effective until restart (fixed ticker), while `_timeout_s`/`_max_failures` are live.
- **§15.3:** reconciled the T2.C event to the shipped `logAttestationEvent` field set
  (`event`/`category`/`severity`/`provider_id`/`pillar`/`decision`/`reason`/`config_flag`,
  INFO/WARN only); the richer field set + MAJOR severity is marked a forward enhancement.
- Confirmed **no drift** on the §5.5–5.6 hash routing-exclusion predicate that SPEC-032
  FR-TD1 cites as authoritative.

**Change log v0.3:**
- Resolves Round 2 findings C1, M1, M2, M3, M4, m1, m2, m3, m4.
- Restates AC-T2-5 around the SPEC-006 v0.8.1 disclosure allowlist, splits
  §13.2 default-config and active-state disclosure examples, and keeps
  `tier1_disclosure.version: "v0.8"` until §4.3 permits Tier-2 response
  changes.
- Clarifies `"enforced"` Pillar D disclosure semantics, Pillar D validation
  helper-key behavior, hardware-attestation disclosure derivation, p2c AAD
  symmetry, helper-only cap comments, and optional shadow-mode scope.

**Change log v0.2:**
- Resolves audit findings C1, C2, M1-M17, m1, q1.
- Adds §4.6 error table, §4.7 redaction rule, §6.5.2 response AAD,
  §6.7.1 decrypt-failure handling, §6.10 restart behavior, §8.6 flag
  precedence matrix, §10.1.1 first-message dispatch, and §11.5 config
  lifecycle table.
- Adds `tier2.observe_enabled` to §11. Expands AC-T2-5 and AC-T2-21.
  Removes `tier2.phase` from config; makes phase a computed disclosure field.
  No architectural changes.

**Change log v0.1:**
- Initial draft. Tier-2 survivability audit (§2) clears the four F-1.5
  invariants defined in SPEC-006 §F-1.5.
- Defines four pillars (model catalog, provider-leg encryption, hardware
  attestation, untrusted-provider safety) across three implementation phases.
- Annotates SPEC-001 v2.0 wire extensions required for Pillars B and C.
- All Tier-2 features opt-in; Tier-1 behavior unchanged at defaults.

---

## 0. Operator-paste invocation block

```
Implement SPEC-008. As you work, maintain a running
phase4-coordinator/implementation-notes.html that captures anything
I should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Scope and mission

SPEC-008 defines Mac Provider's Tier-2 trust layer. Tier 2 is the planned
hardening layer above the current Tier-1 cooperative provider network. It
turns the Tier-1 disclosure posture from SPEC-006 into enforceable coordinator
behavior where the required pillar is enabled.

Tier 1 remains valid. Tier 2 is additive. With every new `tier2.*` key at its
default value, the coordinator's own responses (`/v1/models` `tier1_disclosure`,
`/v1/chat/completions`), provider WebSocket protocol, routing selection,
sticky-affinity behavior, and audit logs MUST preserve current Tier-1 behavior.
**One shipped exception (v0.4):** the coordinator's `/internal/routing` metadata always
computes the attestation aggregate (not `ConfigActive`-gated), and the **gateway**
surfaces it whenever any `StateReady` provider exists — so the buyer-visible
`hardware_attestation` disclosure is **not** byte-identical to Tier-1 once a SPEC-008
gateway fronts the pool (a tokenless pool discloses `hardware_attestation: "unsupported"`;
§4.3, §13.2, §13.3). This is a known cross-service gap, documented rather than a
guarantee.

Tier 2 exists to close the expectation-drift gap recorded in the 2026-05-29
independent security audit:

> MacProvider does not appear to contain a critical architectural flaw if its
> current Tier 1 system is positioned as a cooperative, provisional provider
> network with no claim of provider-private prompts, hardware attestation, or
> malicious-provider resistance. The high-severity risk is expectation drift.

SPEC-006 v0.8.1 closed the disclosure surface by making Tier-1 limitations
normative. SPEC-008 closes the enforcement surface by specifying the
capabilities that Tier 1 deliberately deferred.

### 1.1 In scope

SPEC-008 covers:

- Pillar A: model catalog plus cryptographic model-hash verification.
- Pillar B: provider-leg application-layer encryption.
- Pillar C: provider attestation data model and coordinator verification flow —
  a self-signed Secure-Enclave key-custody format (shipped default, tier
  `self_signed`) and an aspirational hardware-rooted Apple-MDA path (§7).
- Pillar D: untrusted-provider behavioral safety controls in the coordinator
  relay loop.
- Three implementation phases:
  - Phase 1: Pillar A only, coordinator-only, no SPEC-001 wire change.
  - Phase 2: Pillars B and C together, requiring SPEC-001 v2.0.
  - Phase 3: Pillar D, coordinator-internal, enabled incrementally.
- The Tier-2 survivability audit required by SPEC-006 §F-1.5.
- `/v1/models` disclosure updates that reflect actual enforcement state.
- New `tier2.*` coordinator configuration keys and audit categories.
- SPEC-001 v1.3 candidate annotation for Pillar A's optional `model_hash`
  provider-registration field.
- SPEC-001 v2.0 candidate annotations for Pillar B and Pillar C.

### 1.2 Out of scope

SPEC-008 does not cover:

- Rewards, payouts, settlement, or provider compensation. Those remain in the
  SPEC-005 domain.
- AntFeed or other marketplace integration. That remains in the SPEC-007
  domain.
- Billing, invoices, or usage-price policy.
- Multi-region coordination, global replication, or cross-region trust roots.
- Buyer-to-provider end-to-end encryption.
- Any design in which the coordinator cannot see buyer plaintext.
- Prompt privacy from the selected provider runtime.
- Provider-side result caching beyond SPEC-004 sticky-affinity routing state.
- Editing SPEC-001, SPEC-002, SPEC-004, or SPEC-006 in this session.
- d-inference source inspection or any dependency on NOASSERTION-licensed
  private source.

### 1.3 Relationship to locked specs

SPEC-001 v1.2.4 remains the authoritative provider binary and provider
WebSocket protocol for Tier 1. SPEC-008 MAY annotate future SPEC-001 wire
extensions, but it MUST NOT change SPEC-001 v1.2.4 text.

SPEC-002 v1.3.3 remains the authoritative coordinator router spec. SPEC-008
adds routing predicates and audit categories. It does not replace SPEC-002's
state machine, preflight, warm-up gate, breaker, or routing-mode resolution.

SPEC-004 v0.3.1 remains the authoritative smart-router and sticky-affinity
spec. SPEC-008 MUST preserve SPEC-004's hard-pin precedence, `conv:` namespace,
soft sticky preference semantics, TTL expiry, and coordinator-only sticky map.

SPEC-006 v0.8.1 remains the authoritative buyer API gateway spec and Tier-1
disclosure baseline. SPEC-008 updates enforcement state in `/v1/models`
without changing the locked buyer chat/completions contract.

### 1.4 North-star requirement

Tier-2 engineering MUST never let future marketing, docs, API fields, or
operator copy claim more privacy, model integrity, hardware integrity, or
malicious-provider resistance than the enabled Tier-2 pillars actually enforce.

Any partial rollout MUST be represented as partial. A model served by a mixed
pool of verified and unverified providers MUST NOT be described as uniformly
verified.

---

## 2. Tier-2 survivability audit

This section is the mandatory survivability certificate required by
SPEC-006 §F-1.5. No Tier-2 capability in §§4-8 is acceptable unless all four
sticky-affinity invariants survive.

The current Tier-1 sticky design is:

- The gateway derives `routing_internal.conversation_key`.
- The key uses the reserved `conv:` namespace.
- The key is derived with HMAC-SHA256 over:
  - a fixed scope string,
  - the authenticated canonical `account_id`,
  - the buyer-supplied conversation tag.
- The HMAC secret is gateway-held.
- The raw buyer tag and raw account ID are never forwarded to providers.
- The coordinator stores sticky entries internally and enforces TTL expiry.
- Buyers purge account-scoped sticky state through authenticated
  `DELETE /v1/sticky`.

SPEC-008's Tier-2 design clears the four invariants below.

### 2.1 Invariant (a): account-scoped HMAC collision resistance

**Invariant.** `account_id` remains inside the HMAC message and cross-account
`conv:` collision remains structurally impossible, even after provider-leg
encryption or channel-level re-keying.

**Threat model.** A malicious buyer or provider attempts to cause two accounts
to share a sticky-affinity key by choosing the same conversation tag, replaying
traffic, observing provider-leg ciphertext, or influencing Tier-2 key
agreement.

**Tier-1 mechanism.** SPEC-006 §1.3 (the F-1.5 survivability clause) derives:

```
message = scope || "\n" || account_id || "\n" || buyer_tag
digest = HMAC-SHA256(MACPROVIDER_KEY_HASH_SECRET, message)
routing_internal.conversation_key = "conv:" || base64url_unpadded(digest)
```

Because `account_id` is inside the MAC input and the HMAC secret is held by
the gateway, two accounts using the same buyer tag cannot produce the same
`conv:` value unless HMAC-SHA256 is broken or the gateway secret leaks.

**Tier-2 finding.** Cleared.

**Normative preservation rule.** Tier-2 engineering MUST NOT move
conversation-key derivation from the gateway to the provider, MUST NOT remove
`account_id` from the HMAC message, MUST NOT allow provider-supplied
conversation keys, and MUST NOT derive sticky identity from Pillar B session
keys, AEAD nonces, attestation tokens, model hashes, provider IDs, or
provider-observable ciphertext.

Provider-leg encryption MAY re-key the coordinator-to-provider channel, but
that re-keying MUST be independent from sticky-key derivation. A provider-leg
session key MUST never be an input to the `conv:` HMAC.

If a proposed Tier-2 design requires deriving sticky keys after the request is
encrypted for the provider, that design is rejected.

### 2.2 Invariant (b): provider cannot derive `conv:` from traffic

**Invariant.** The `conv:` value is NOT derivable by the provider from any
observable traffic, even under Tier 2 where the coordinator-to-provider
channel may change.

**Threat model.** A provider observes:

- plaintext prompts and completions at the local MLX runtime,
- Tier-1 WebSocket frames when Pillar B is disabled,
- Pillar B ciphertext, nonce, AAD, and frame metadata when Pillar B is enabled,
- request timing,
- model IDs,
- provider assignment history,
- sticky-hit routing behavior.

The provider attempts to reconstruct the buyer's internal `conv:` value or raw
conversation tag.

**Tier-1 mechanism.** The `conv:` value is gateway-to-coordinator internal
state. SPEC-004 §4 says `routing_internal.conversation_key` is not a provider
protocol field. SPEC-006 §1.3 says raw buyer tag and raw account ID are not
logged as the opaque suffix and are not sent to providers.

**Tier-2 finding.** Cleared.

**Normative preservation rule.** Pillar B AEAD AAD MUST NOT include
`routing_internal.conversation_key`, raw buyer conversation tags, raw
`account_id`, or sticky-entry IDs. Pillar B ciphertext MUST carry only the
provider request body and response payload needed for inference. Pillar C
attestation challenges and tokens MUST NOT encode sticky state. Pillar D
output-safety logs MUST NOT expose `conv:` values to provider-originated
messages.

The coordinator MAY log sticky outcomes internally, but provider-visible error
messages, close reasons, preflight messages, inference messages, and
attestation challenges MUST NOT reveal the `conv:` key.

If a provider can compute or read the `conv:` value from any Tier-2 field,
frame, token, nonce, or error path, the design is rejected.

### 2.3 Invariant (c): deletion remains account-scoped and authenticated

**Invariant.** `DELETE /v1/sticky` remains account-scoped and authenticated.
Tier 2 MUST NOT introduce a provider-visible sticky lifecycle API.

**Threat model.** A provider attempts to purge, enumerate, extend, refresh, or
query sticky entries to influence future routing or learn account relationships.
An unauthenticated buyer attempts to delete another account's sticky state.

**Tier-1 mechanism.** SPEC-006 §1.3 (DELETE /v1/sticky definition) defines
`DELETE /v1/sticky` as
authenticated with the same bearer-token account identity as normal API
traffic. It purges only sticky entries attributable to the caller's
`account_id`. SPEC-004 §4 stores sticky entries in coordinator memory and
exposes no provider lifecycle API.

**Tier-2 finding.** Cleared.

**Normative preservation rule.** Tier-2 engineering MUST keep
`DELETE /v1/sticky` on the buyer/gateway side. Providers MUST NOT receive any
message type that creates, updates, deletes, lists, hints, refreshes, or
confirms sticky state. SPEC-001 v2.0 candidate extensions MUST NOT add a
provider-visible sticky lifecycle field. Pillar B encrypted frames MUST NOT
carry sticky lifecycle commands. Pillar C attestation status MUST NOT grant
sticky-management privilege.

If future operator tooling needs sticky inspection, it MUST be an
operator-authenticated coordinator endpoint, not a provider endpoint.

### 2.4 Invariant (d): TTL remains coordinator-enforced

**Invariant.** TTL expiry remains coordinator-enforced and not
provider-self-reported. Tier-2 encryption does not shift TTL authority to the
provider.

**Threat model.** A provider attempts to keep receiving related requests after
the sticky TTL expires by reporting a cache hit, claiming a fresh attestation,
or influencing encrypted-channel session lifetime.

**Tier-1 mechanism.** SPEC-004 §4's sticky map stores `created_at`,
`last_used_at`, TTL, LRU state, and model scope in coordinator memory. TTL
expiry and LRU eviction happen inside the coordinator. SPEC-002 §5 governs
preflight/disconnect behavior without letting providers report sticky
freshness.

**Tier-2 finding.** Cleared.

**Normative preservation rule.** Tier-2 engineering MUST keep sticky TTL
calculation inside the coordinator. Pillar B session duration, AEAD re-key
intervals, provider uptime, hardware-attestation lifetime, and model-hash
verification status MUST NOT extend sticky TTL. A provider MAY benefit from
warm local caches as a consequence of being selected, but it MUST NOT declare
that a sticky entry remains valid.

If the coordinator restarts and loses in-memory sticky state, Tier 2 MUST
preserve SPEC-004 behavior: future requests cold-route normally. Providers
MUST NOT be asked to reconstruct lost sticky entries.

### 2.5 Survivability conclusion

The Tier-2 design in this spec is non-regressive with respect to SPEC-006
§F-1.5 because:

- (a) sticky keys remain gateway-derived and account-scoped,
- (b) sticky keys remain coordinator-internal,
- (c) sticky deletion remains authenticated and account-scoped,
- (d) sticky TTL remains coordinator-enforced,
- provider-leg encryption and attestation are deliberately orthogonal to
  sticky identity.

Any future SPEC-008 revision that changes these properties MUST reopen §2 and
MUST NOT advance until the four invariants clear again.

---

## 3. Terms and definitions

**Tier 1.** The cooperative Mac Provider network defined by SPEC-001,
SPEC-002, SPEC-004, and SPEC-006 before Tier-2 enforcement is enabled. Tier 1
does not claim provider-private prompts, hardware attestation, cryptographic
model identity, or malicious-provider resistance.

**Tier 2.** Additive trust-layer enforcement specified by SPEC-008. Tier 2
does not replace Tier 1; it adds opt-in enforcement predicates and disclosure
updates per pillar.

**Pillar.** One of the four Tier-2 enforcement families:

- Pillar A: model catalog plus hash verification.
- Pillar B: provider-leg encryption.
- Pillar C: provider attestation (shipped default: self-signed Secure-Enclave
  key-custody, tier `self_signed`; aspirational: hardware-rooted Apple-MDA, §7).
- Pillar D: untrusted-provider behavioral safety.

**Phase.** A rollout group. Phase 1 ships Pillar A. Phase 2 ships Pillars B
and C together. Phase 3 ships Pillar D.

**Catalog.** A coordinator-readable, operator-signed data file mapping model
identifiers to expected SHA-256 artifact hashes and metadata.

**Catalogued model.** A model ID present in the active Tier-2 catalog.

**Uncatalogued provider.** A provider serving a model ID that is absent from
the active catalog, or a provider that omits `model_hash` for that model.

**Hash verification.** The coordinator compares a provider-reported SHA-256
model artifact hash against the active catalog's expected hash for the same
model ID.

**Hash verified.** A provider/model pair whose reported hash exactly matches
the active catalog entry.

**Hash mismatch.** A provider/model pair whose reported hash is syntactically
valid but does not match the active catalog entry.

**Encrypted leg.** The coordinator-to-provider WebSocket inference path after
Pillar B AEAD wrapping is enabled for a provider session.

**Provider-leg encryption.** Application-layer encryption between coordinator
and provider. It protects against passive observers on that leg. It is not
buyer-to-provider end-to-end encryption.

**Attested provider.** A provider session for which the coordinator has
cryptographically verified an attestation token and bound it to the session.
**Two formats yield this status, at different trust strengths (§7.3):**
(a) an Apple **Managed-Device-Attestation** token validated against an
operator-configured trust root, with attested device properties matched to the
provider's claims (the `hardware`-rooted path, §7.4 — aspirational/configured,
not the shipped default); and (b) the shipped **default self-signed
Secure-Enclave** format (`macprovider-se-p256-v1`, §7.4a), which the coordinator
verifies against the provider's *own* submitted key — proving P-256 key custody
+ session binding only (tier `self_signed`), **not** hardware provenance,
Secure-Enclave custody, Apple-Silicon, or device identity (the `hardware_family`
claim is a self-asserted string). **"Attested" therefore means "presented a
verified, session-bound attestation token" — it does NOT by itself mean
"proved trusted hardware"**; only the `hardware` tier does, and that tier is not
emitted by the shipped code (§7.3, §13.3).

**Unsupported attestation.** A provider state where a positive attestation was
not established — either because the platform/packaging/OS/entitlement/operator
trust root does not support a verifiable attestation token, **or** because the
provider presented no token, or presented one that failed/expired. On the
network-level disclosure this negative bucket is reported as `unsupported`
regardless of which of these applies (§7.7, §13.3).

**Behavioral safety.** Coordinator-enforced output constraints that limit
oversized completions, malformed encoding, and latency anomalies without
trusting provider self-report.

**Observe mode.** An explicit Tier-2 opt-in enabled by
`tier2.observe_enabled: true`. Observe mode permits Tier-2 evidence
computation, disclosure fields, and Tier-2 audit events without requiring a
routing predicate.

**Challenge ID.** A short coordinator-assigned identifier for an attestation
challenge attempt, or the first 8 raw challenge bytes base64url-encoded. It is
not the raw 32-byte challenge value.

**Pre-commit failure.** A relay failure detected before any bytes for the
buyer response body or stream have been written.

**Post-commit failure.** A relay failure detected after one or more buyer
response bytes or SSE events have already been written.

**Survivability invariant.** A SPEC-006 §F-1.5 sticky-affinity property that
future Tier-2 work must preserve.

**SPEC-001 v1.3 candidate annotation.** An additive candidate field that old
providers may omit and that a future SPEC-001 v1.x revision may adopt without
breaking Tier-1 behavior.

**SPEC-001 v2.0 candidate annotation.** A future provider-wire extension that
requires a coordinated provider/coordinator protocol migration.

**Plaintext coordinator.** The normative limitation that the coordinator sees
buyer prompts and provider responses in plaintext. SPEC-008 does not change
this.

---

## 4. Architecture overview

Tier 2 layers onto the existing Tier-1 coordinator. The coordinator remains
the enforcement point for routing eligibility, model aggregation, audit logs,
provider relay, and buyer-visible disclosure. Providers supply evidence;
coordinators decide whether that evidence is acceptable.

### 4.1 Pipeline

```
Provider connects
  |
  v
Provider registration / auth
  |
  +--> [Pillar C] attestation supported?
  |        |
  |        +--> SE self-signed (macprovider-se-p256-v1, default): verify
  |        |    provider's own key + session binding (no trust root) -> self_signed
  |        +--> MDA (apple-...-acme-v1): validate token against configured trust root
  |        +--> store attested true/false/unsupported (+ attestation_tier)
  |
  +--> [Pillar A] model hash supplied?
  |        |
  |        +--> compare SHA-256 to signed model catalog
  |        +--> store hash_verified true/false/uncatalogued
  |
  v
Pool entry becomes routing-eligible only if SPEC-002 filters pass
and enabled Tier-2 predicates pass
  |
  v
Buyer request enters coordinator
  |
  +--> SPEC-004 sticky / model class / retry selection remains coordinator-only
  |
  +--> [Pillar B] encrypted leg supported and selected?
  |        |
  |        +--> wrap inference request body in AEAD envelope
  |        +--> provider decrypts before local MLX runtime
  |
  v
Provider executes local inference
  |
  v
Provider response stream returns
  |
  +--> [Pillar B] encrypted response chunks are AEAD-unwrapped by coordinator
  |
  +--> [Pillar D] coordinator validates size, encoding, and timing
  |
  v
Coordinator responds to buyer
```

### 4.2 Enforcement ownership

| Capability | Enforced by coordinator | Requires provider change | Requires SPEC-001 wire change |
|---|---:|---:|---:|
| Pillar A catalog load | Yes | No | No |
| Pillar A `model_hash` self-report | Yes | Optional provider field | No; SPEC-001 v1.3 candidate |
| Pillar A routing predicate | Yes | No | No |
| Pillar B ECDH key exchange | Yes | Yes | Yes; SPEC-001 v2.0 candidate |
| Pillar B AEAD request envelope | Yes | Yes | Yes; SPEC-001 v2.0 candidate |
| Pillar B AEAD response envelope | Yes | Yes | Yes; SPEC-001 v2.0 candidate |
| Pillar C attestation token | Yes | Yes | Yes; SPEC-001 v2.0 candidate |
| Pillar C routing predicate | Yes | No | No after token exists |
| Pillar D response size cap | Yes | No | No |
| Pillar D encoding validation | Yes | No | No |
| Pillar D response-time anomaly logging | Yes | No | No |

### 4.3 Default behavior preservation

All Tier-2 predicates are dormant at defaults:

- `tier2.observe_enabled: false`
- `tier2.require_hash_verified: false`
- `tier2.require_encrypted_leg: false`
- `tier2.require_attestation: false`
- `tier2.behavioral_safety_enabled: false`

The coordinator MUST NOT compute Tier-2 evidence, emit Tier-2 audit events,
change routing decisions, or add Tier-2 fields to any response unless at least
one of the following is true:

- `tier2.catalog_path` is non-empty,
- any `tier2.require_*` enforcement key is true,
- `tier2.behavioral_safety_enabled: true`,
- `tier2.observe_enabled: true`.

With every `tier2.*` key at its default value, the coordinator MUST NOT reject,
reroute, truncate, disclose stronger posture, or change buyer-visible behavior solely
because a SPEC-008 binary was deployed.

**Attestation carve-out (v0.4, shipped reality — two exceptions).** `attestation_formats`
is advertised by default (§11.1), so when a **SPEC-001 v2.0-candidate provider chooses to
present an `attestation_token`**, the coordinator verifies it and emits a diagnostic
`T2.C` attestation event (`logAttestationEvent`, INFO on success / WARN on failure) even
at otherwise-default config. This is a provider-triggered, provider-scoped diagnostic — it
does **not** run for legacy/Tier-1 providers (which present no token) and does **not**
change routing (the routing predicate stays gated on `require_attestation`). Two clauses
of the default-preservation invariant are therefore **not** literally true at defaults and
are scoped accordingly:

1. *"Emit no new Tier-2 logs."* Scoped to Pillars A/B/D and the routing/disclosure
   surfaces; a volunteered attestation token still produces the `T2.C` diagnostic above.
2. *"No buyer-visible change."* The coordinator's own `/v1/models` **does** suppress the
   `tier2.attestation` block at defaults (`tier2.ConfigActive` is false, §7.7). **But** the
   coordinator's `/internal/routing` metadata always computes the attestation aggregate
   (it is **not** `ConfigActive`-gated), and the **gateway** treats any non-`none`
   attestation state — **including `unsupported`** — as active and emits the buyer-visible
   Tier-2 disclosure (`phase5-gateway/internal/router/disclosure.go`). Because the
   aggregate is `none` **only** for an empty ready pool (§13.3), the presence of **any
   single `StateReady` provider — including a legacy, tokenless one** — makes attestation
   buyer-visible via the gateway at otherwise-default coordinator config: a tokenless pool
   discloses `hardware_attestation: "unsupported"`, an SE-attested pool discloses `"all"`
   (a known misnomer for the self-signed path, §13.3). So a Tier-1-only pool that simply
   upgrades to a SPEC-008 gateway **does** change buyer-visible disclosure. Operators MUST
   NOT assume default coordinator config keeps attestation off the buyer surface; the
   gateway path bypasses the `/v1/models` `ConfigActive` gate entirely.

### 4.4 Threat boundary

Tier 2 reduces specific risks:

- Pillar A reduces honest-misconfiguration risk for model identity.
- Pillar B reduces passive network-observer risk on the provider leg.
- Pillar C reduces false-hardware and unsupported-platform claims **only via its
  hardware-rooted MDA path** (§7.4, aspirational/configured); the shipped default
  `self_signed` Secure-Enclave path reduces only key-substitution and stale/replayed-token
  risk (key custody + freshness + session binding), **not** false-hardware claims — the
  `hardware_family` value is an unauthenticated self-assertion (§7.3, §7.4a).
- Pillar D reduces common malicious-output and exfiltration patterns visible
  in the coordinator relay.

Tier 2 does not eliminate:

- provider access to plaintext at inference time,
- coordinator access to plaintext,
- compromised-provider behavior after correct model and hardware checks,
- prompt privacy from the selected provider,
- buyer-to-provider end-to-end encryption gaps.

### 4.5 Additive routing integration

SPEC-002's routing algorithm remains the base. Tier-2 filters are inserted
after SPEC-002 model/state/capacity filters and before final provider
selection/preflight:

1. SPEC-002 model match, state, capacity, provisional quota.
2. SPEC-004 hard pins, sticky soft preference, class resolution, retry policy.
3. SPEC-008 enabled predicates:
   - hash verified when `tier2.require_hash_verified: true`,
   - encrypted leg when `tier2.require_encrypted_leg: true`,
   - attested provider when `tier2.require_attestation: true`.
4. SPEC-002 preflight and relay.

Enabled Tier-2 predicates (hash verified, encrypted leg, attested) are
eligibility filters, not one-time initial-selection gates. They MUST be
re-applied on every provider selection attempt:

- SPEC-002 preflight advancement when the initially selected provider fails
  preflight,
- SPEC-002 F-4 failover when the selected provider disconnects mid-request,
- SPEC-004 retry when a sticky-preferred provider fails and class resolution
  selects an alternative,
- hard-pin validation when a buyer-supplied pin is evaluated.

A provider that is ineligible under enabled Tier-2 predicates MUST be treated
as ineligible at each of these steps, not re-admitted because it was previously
considered.

Hard pins retain SPEC-002 behavior. If a buyer hard-pins a provider that fails
an enabled Tier-2 predicate, the coordinator MUST return
`tier2_hard_pin_predicate_failed` per §4.6; it MUST NOT silently route to a
different provider.

### 4.6 Tier-2 error table

Tier-2 buyer errors MUST use SPEC-006's OpenAI-compatible error envelope. The
`error.code`, HTTP status, `error.type`, message template, and streaming
behavior are:

| Code | HTTP | error.type | Message (template) | Streaming: committed? |
|---|---:|---|---|---|
| `tier2_hash_verified_required` | 503 | `server_error` | No hash-verified provider available for model `{model_id}`. | N/A - pre-selection |
| `tier2_encrypted_leg_required` | 503 | `server_error` | No Pillar-B encrypted provider available for model `{model_id}`. | N/A |
| `tier2_attestation_required` | 503 | `server_error` | No attested provider available for model `{model_id}`. | N/A |
| `tier2_hard_pin_predicate_failed` | 400 | `invalid_request` | Hard-pinned provider `{provider_id}` does not satisfy enabled Tier-2 predicates. | N/A |
| `tier2_hash_mismatch` | 503 | `server_error` | Provider `{provider_id}` hash verification failed; excluded from pool. | N/A |
| `tier2_aead_decrypt_failed` | 502 | `server_error` | Provider response authentication failed. | If post-commit: emit error SSE event, close stream. |
| `tier2_output_encoding_invalid` | 502 | `server_error` | Provider response encoding validation failed. | If post-commit: emit error SSE event, close stream. |
| `tier2_attestation_token_too_large` | 400 | `invalid_request` | Attestation token exceeds maximum encoded length of 16384 bytes. | N/A - auth |
| `tier2_attestation_token_invalid` | 400 | `invalid_request` | Attestation token encoding or format is invalid. | N/A - auth |

**Note (shipped, v0.4).** The two `tier2_attestation_token_*` rows are a **forward
HTTP catalog**: attestation tokens are presented on the provider WebSocket auth handshake,
where the shipped verifier collapses over-limit/malformed/invalid to attestation status
`attestation_failed` and (when `require_attestation: true`) closes the session with WS code
`4012`, rather than returning an HTTP 400 with these codes (§7.4, §10.4). They are retained
for a future HTTP attestation-submission path.

Messages MUST NOT reveal raw hashes, keys, attestation tokens, or trust-root
details. Placeholders like `{model_id}` are literal substitution variables;
implementations MUST substitute the actual value.

### 4.7 Tier-2 redaction rule

All Tier-2 error messages, `auth_response.error.message` values, and WebSocket
close reasons MUST use generic human-readable text that identifies the failure
class, such as "attestation failed" or "key exchange failed", and MUST NOT
include:

- raw ECDH or AEAD keys, nonces, or secrets,
- raw attestation token bytes or JWS bodies,
- expected or reported cryptographic hashes beyond a truncated prefix of
  maximum 8 hex characters,
- raw API keys, provider bearer tokens, account IDs, or `conv:` values,
- unredacted trust-root certificate details.

---

## 5. Pillar A — Model catalog + hash verification

Pillar A adds a coordinator-managed model catalog and per-provider model-hash
verification. It ships first because it requires no SPEC-001 wire change.

### 5.1 Threat model

Pillar A closes honest-but-misconfigured model identity risk:

- a provider advertises a model ID but loaded a different artifact,
- a provider upgraded or downgraded local weights without updating metadata,
- an operator's pool contains multiple artifacts under the same display ID.

Pillar A does not close adversarial-provider lying risk. The provider computes
and reports its own hash. A malicious provider can lie about the hash unless a
future attested-measurement design binds the hash to a trusted runtime. That
future binding is not in v0.2 scope.

### 5.2 Catalog file

The coordinator MUST load a signed model catalog when
`tier2.catalog_path` is non-empty.

The catalog MUST be JSON encoded UTF-8.

The catalog MUST include:

```json
{
  "version": 1,
  "catalog_id": "macprovider-tier2-model-catalog-2026-05-31",
  "issued_at": "2026-05-31T00:00:00Z",
  "expires_at": "2026-08-31T00:00:00Z",
  "models": [
    {
      "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "artifact_kind": "mlx_weight_file",
      "sha256": "64 lowercase hex chars",
      "hash_scope": "primary_weight_file",
      "min_ram_gb": 16,
      "source": "operator-curated",
      "notes": "optional operator note"
    }
  ],
  "signature": {
    "alg": "Ed25519",
    "key_id": "catalog-key-2026q2",
    "sig": "base64url-unpadded signature over canonical catalog body"
  }
}
```

The canonical catalog body is the catalog object without the `signature`
member, serialized with deterministic JSON:

- UTF-8,
- lexicographic object keys,
- no insignificant whitespace,
- arrays in declared order,
- lowercase hex SHA-256 strings.

The coordinator MUST verify the signature using `tier2.catalog_public_key`
before accepting any entry. If verification fails, the coordinator MUST reject
the catalog at startup or reload time and MUST leave the previous accepted
catalog active, if one exists.

Catalog model entries MAY include `min_ram_gb`, a positive integer RAM floor
for provider-install UX and model-fit guidance. Because it is inside
`models[]`, `min_ram_gb` is covered by the catalog signature when present. It
MUST NOT affect hash equality; `sha256` remains the only model artifact hash
field used for Pillar A verification.

If no previous accepted catalog exists and `tier2.require_hash_verified: true`,
the coordinator MUST fail startup. If `tier2.require_hash_verified: false`, the
coordinator MAY start without an active catalog and treat all providers as
`"uncatalogued"`.

#### 5.2.1 Catalog key trust model

The `tier2.catalog_public_key` is an operator-supplied Ed25519 public key. The
trust model is:

- The key is pinned by the operator at deployment time (trust-on-first-config,
  not trust-on-first-use).
- No external certificate authority or revocation endpoint is required.
- Key rotation requires an operator-controlled restart with a new
  `catalog_public_key`. The old key is no longer valid after restart.
- A compromised catalog key is in scope for operator rotation by updating
  config and restarting, but out of scope for automatic cryptographic
  mitigation in v0.2.
- Key format: Ed25519 public key, 32 bytes, encoded as base64url-unpadded.

### 5.3 Hash algorithm

The hash algorithm is SHA-256 over the model artifact bytes declared by
`hash_scope`.

Allowed `hash_scope` values in v0.2:

- `primary_weight_file`: SHA-256 of the primary weight file.
- `artifact_manifest`: SHA-256 of a deterministic manifest listing all weight
  shard names, sizes, and SHA-256 values.
- `coordinator_endorsed_incremental`: coordinator-endorsed hash for large
  artifacts where the operator precomputes an incremental digest.

Providers MUST report lowercase hex SHA-256. The coordinator MUST reject
malformed hash strings as `hash_invalid`.

### 5.4 Provider registration extension

SPEC-001 v1.2.4 provider `hello` remains valid. Pillar A adds one optional
field as a SPEC-001 v1.3 candidate annotation:

```json
{
  "type": "hello",
  "version": 1,
  "tier": 1,
  "provider_id": "m4-anon",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_hash": "64 lowercase hex chars"
}
```

`model_hash`:

- Type: string.
- Required: no.
- Applies to the single `model_id` advertised in the same hello.
- Encoding: lowercase hex SHA-256.
- Missing value: provider/model status is `"uncatalogued"` unless a future
  SPEC-001 revision defines a multi-model shape.

Old providers omit `model_hash`. The coordinator MUST admit old providers
under default Tier-1 behavior.

### 5.5 Verification state

For every provider/model pair, the coordinator MUST compute one of:

- `hash_verified`: reported hash matches active catalog entry.
- `hash_mismatch`: reported hash does not match active catalog entry.
- `hash_invalid`: reported hash is syntactically invalid.
- `uncatalogued`: no active catalog entry exists for the model ID, or provider
  omitted `model_hash`.
- `catalog_unavailable`: catalog could not be loaded or verified.

Only `hash_verified` is a positive integrity signal.

`uncatalogued` is not a failure at default config. It means "not verified."

`hash_mismatch` and `hash_invalid` MUST exclude that provider from serving the
affected model when a catalog entry exists. The provider MAY still serve other
models that verify, if future multi-model support exists.

In current SPEC-001 single-model mode, a `hash_mismatch` or `hash_invalid`
MUST make the provider routing-ineligible and SHOULD close or mark the session
`degraded` with reason `hash_mismatch`.

### 5.6 Routing predicate

When `tier2.require_hash_verified: false`, `hash_mismatch` and `hash_invalid`
for a catalogued model MUST be excluded from routing. Only `uncatalogued` and
`catalog_unavailable` are permissive at default. The coordinator has positive
evidence of a false advertised identity; routing to that provider serves the
wrong model.

If known-bad catalogued providers are excluded and no otherwise-eligible
provider remains for the model, the coordinator MUST return
`tier2_hash_mismatch` per §4.6 unless `tier2.require_hash_verified: true`
requires the stricter `tier2_hash_verified_required` error.

When `tier2.require_hash_verified: true`, the coordinator MUST route only to
providers whose provider/model pair is `hash_verified`.

If all otherwise-eligible providers are excluded by the hash predicate, the
coordinator MUST return an OpenAI-compatible error envelope with:

- HTTP status: 503.
- Error code: `tier2_hash_verified_required`.
- Message: per §4.6.

Hard-pinned providers that fail the predicate MUST fail the request with
`tier2_hard_pin_predicate_failed` per §4.6; the coordinator MUST NOT fall back
to a different provider.

### 5.7 `/v1/models` fields

When Pillar A observation or enforcement is active, the aggregated
`/v1/models` entry for each model MUST include:

```json
{
  "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "object": "model",
  "hash_verified": true,
  "hash_verification": {
    "status": "all_verified",
    "verified_provider_count": 3,
    "uncatalogued_provider_count": 0,
    "mismatch_provider_count": 0,
    "invalid_provider_count": 0,
    "catalogued": true
  }
}
```

**Counting basis (v0.4 clarification).** The `hash_verification` counts and the
`hash_verified` summary aggregate over providers that hold an **available slot** for the
model (shipped predicate `hasAvailableSlot`, `internal/buyer/server.go`), **not** over the
strictly routable set. Slot-holding is independent of hash status:
`pool.Provider.RoutingEligible` does **not** inspect hash status — the routing exclusion
for bad hashes is a **separate** Tier-2 predicate (`IsHashPredicateFailure`, §5.5–5.6,
`internal/tier2/catalog.go`) which excludes `hash_mismatch`/`hash_invalid`
**unconditionally** and `uncatalogued` **only when `require_hash_verified: true`**. So a
`mismatch`/`invalid` provider (always) and an `uncatalogued` provider (when
`require_hash_verified` is true) hold a slot and are **counted here** for disclosure even
though the hash predicate keeps them out of routing; an `uncatalogued` provider under the
default `require_hash_verified: false` both counts here **and** routes (§5.6). "Routable"
elsewhere in this section is shorthand for "holding an available slot for the model", which
is the disclosure basis — not the strictly-routing-eligible set.

`hash_verified` MUST be:

- `true` when every slot-holding provider for that model is `hash_verified`.
- `"uncatalogued"` when every slot-holding provider for that model is
  `uncatalogued`.
- `false` when the slot-holding set is mixed, invalid, mismatched, or catalog
  unavailable.

The additive `hash_verification` object MUST be present only when at least one
of the following is true:

- `tier2.catalog_path` is non-empty,
- `tier2.require_hash_verified: true`,
- `tier2.observe_enabled: true`.

With all `tier2.*` keys at defaults and no `catalog_path`, `/v1/models` MUST
be byte-identical to the Tier-1 response.

Buyers and SDKs MUST be able to filter client-side to
`hash_verified: true` using this field. SPEC-008 v0.2 does not add a
server-side query parameter because SPEC-006 §5 endpoint shapes are locked.

### 5.8 Disclosure update

When any provider/model pair becomes `hash_verified`, the top-level
`tier1_disclosure` block MUST stop representing model identity as uniformly
provider-reported. It MUST instead represent the actual mixed state using the
protocol in §13.

Operators MUST NOT override this disclosure.

### 5.9 Pillar A acceptance criteria

**AC-A-1. Catalog signature verification.**
Given a catalog signed by the configured Ed25519 public key, coordinator
startup accepts it. Given one byte changed in the catalog body, startup or
reload rejects it and logs `T2.A catalog_signature_invalid`.

**AC-A-2. Hash match routes.**
Given a catalog entry for model M with hash H and a provider hello for M with
`model_hash: H`, `/v1/models` reports `hash_verified: true` for M when all
routable providers for M match.

**AC-A-3. Hash mismatch rejects per model.**
Given catalog hash H and provider-reported hash X for the same model M, the
provider/model pair is marked `hash_mismatch`, audit category `T2.A` is logged,
and the provider does not serve M.

**AC-A-4. Missing hash is uncatalogued.**
Given an old provider that omits `model_hash`, the coordinator admits it under
default config and preserves Tier-1 routing when
`tier2.require_hash_verified: false`. When Pillar A observation is active, it
reports `"uncatalogued"` when all providers are uncatalogued.

**AC-A-5. Required verified filter.**
With `tier2.require_hash_verified: true`, an otherwise-routable uncatalogued
provider is excluded and the buyer receives `503 tier2_hash_verified_required`
when no verified provider remains.

**AC-A-6. Mixed pool disclosure.**
Given one verified and one uncatalogued routable provider for the same model,
`hash_verified` is `false`, `hash_verification.verified_provider_count` is 1,
and `tier1_disclosure` indicates partial model-hash enforcement.

---

## 6. Pillar B — Provider-leg encryption

Pillar B adds application-layer encryption to the coordinator-to-provider
WebSocket inference leg.

### 6.1 Threat model

Pillar B protects buyer prompts and provider completions from passive network
observers on the provider WebSocket path.

It does not protect prompts from:

- the coordinator,
- the selected provider process,
- the selected provider operator,
- local malware on the provider machine,
- malicious provider runtime behavior.

### 6.2 Normative limitation: coordinator sees plaintext

Pillar B is channel-only confidentiality for the provider leg. The coordinator
sees plaintext buyer prompts before encryption and plaintext provider
completions after decryption.

The coordinator MUST see plaintext because it routes, accounts, enforces
quotas, applies SPEC-004 sticky and retry logic, validates Pillar D output
safety, and emits buyer-compatible responses.

This limitation is non-overrideable in SPEC-008 v0.2. A deployment MUST NOT
describe Pillar B as buyer-to-provider end-to-end encryption.

### 6.3 Cipher suites

The coordinator MUST support:

- `A256GCM`: AES-256-GCM.

The coordinator SHOULD support:

- `CHACHA20-POLY1305`: ChaCha20-Poly1305.

The default suite is `A256GCM`.

The operator MAY configure preferred suite order with
`tier2.encrypted_leg_aead`.

Providers and coordinators MUST reject unknown suite names.

### 6.4 Key exchange

Pillar B uses X25519 ECDH with fresh ephemeral keypairs per provider session.

The provider generates an X25519 ephemeral keypair for the session.

The coordinator generates an X25519 ephemeral keypair for the session.

The shared secret is:

```
shared_secret = X25519(coordinator_private, provider_public)
```

The session transcript is (field order as below):

```
transcript = SHA256(
  "macprovider/spec008/pillar-b/transcript/v1" ||   # prefix, NO trailing NUL
  field("provider_id",        provider_id) ||
  field("assigned_id",        assigned_id) ||
  field("provider_public",    provider_public) ||     # X25519 provider pubkey, 32 raw bytes
  field("coordinator_public", coordinator_public) ||  # X25519 coordinator pubkey, 32 raw bytes
  field("selected_aead",      selected_aead)           # e.g. "A256GCM"
)
```

**Framing (normative, v0.4 — interop-critical).** The `||` above is **not** bare
concatenation. The shipped code (`internal/tier2/pillar_b.go`, `writeTranscriptField`)
writes the fixed prefix string `macprovider/spec008/pillar-b/transcript/v1` (**no trailing
NUL byte**), then appends each subsequent field via a **length-prefixed, labeled** framing:
`field(label, value) = uint32-BE(len(label)) ‖ label ‖ uint32-BE(len(value)) ‖ value`.
The `label` bytes are themselves hashed into the transcript, so they are part of the
contract: the exact labels are **`provider_id`, `assigned_id`, `provider_public`,
`coordinator_public`, `selected_aead`** — NOT `provider_public_key` /
`coordinator_public_key` / `selected_aead_suite`. This framing (not plain concatenation,
and these exact labels) is what the provider-side signer MUST reproduce byte-for-byte;
v0.3's `||` notation was under-specified and not reproducible as written.

The AEAD keys are derived with HKDF-SHA256:

```
prk = HKDF-Extract(salt = transcript, IKM = shared_secret)
c2p_key = HKDF-Expand(prk, "macprovider/spec008/c2p/aead/v1", 32)
p2c_key = HKDF-Expand(prk, "macprovider/spec008/p2c/aead/v1", 32)
c2p_nonce_base = HKDF-Expand(prk, "macprovider/spec008/c2p/nonce/v1", 4)
p2c_nonce_base = HKDF-Expand(prk, "macprovider/spec008/p2c/nonce/v1", 4)
key_id = base64url(SHA256(transcript)[0:16])
```

The nonce for each encrypted frame is:

```
nonce = nonce_base || uint64_be(frame_counter)
```

Frame counters are per direction and start at 0. A frame counter MUST never be
reused with the same key. The coordinator and provider MUST close the provider
session if a counter would overflow.

### 6.5 AEAD envelope

Encrypted provider-leg messages use:

```json
{
  "encrypted": true,
  "enc": {
    "alg": "A256GCM",
    "kid": "base64url-key-id",
    "seq": 0,
    "nonce": "base64url-12-byte-nonce",
    "aad": "base64url-canonical-aad",
    "ciphertext": "base64url-ciphertext",
    "tag": "base64url-authentication-tag"
  }
}
```

#### 6.5.1 Request AAD (c2p)

**v0.4 correction — the on-wire canonical AAD is a binary length-prefixed blob, not
JSON.** The shipped `MarshalAEADAAD` (`internal/tier2/pillar_b.go`) produces, in exact
order: the prefix `macprovider/spec008/pillar-b/aad/v1\x00` (**with a trailing NUL byte**)
‖ `str(type)` ‖ `str(direction)` ‖ `str(request_id)` ‖ one `stream` byte (exactly `0x00`
for non-stream or `0x01` for stream) ‖ `str(provider_id)` ‖ `str(assigned_id)` ‖
`uint64-BE(seq)`, where `str(v) = uint32-BE(len(v)) ‖ v` (each string field is prefixed
with its length as a 32-bit big-endian integer). On decode, a JSON form is *also*
accepted as a backward-compatibility fallback when the prefix is absent — any JSON that
`json.Unmarshal`s into the AAD struct is accepted (it is **not** required to be
deterministic/canonical); the binary form above is the only shape ever emitted on the
wire. The provider-side signer/verifier MUST reproduce this binary framing. The JSON
below is retained only as a **field inventory** (which fields, and their values), NOT
the canonical byte encoding:

```json
{
  "type": "inference_request",
  "direction": "c2p",
  "request_id": "req-...",
  "stream": true,
  "provider_id": "m4-anon",
  "assigned_id": "provider-pool-id",
  "seq": 0
}
```

The AAD MUST NOT include:

- `routing_internal.conversation_key`,
- raw buyer conversation tags,
- raw `account_id`,
- sticky-entry IDs,
- API keys,
- provider tokens.

#### 6.5.2 Response AAD (p2c)

Response `aad` for `inference_response_chunk` uses the **same binary
length-prefixed canonical framing** as §6.5.1 (`direction: "p2c"`); the JSON below is
a field inventory, not the canonical byte encoding:

```json
{
  "type": "inference_response_chunk",
  "direction": "p2c",
  "request_id": "req-...",
  "seq": 0,
  "provider_id": "m4-anon",
  "assigned_id": "provider-pool-id",
  "stream": true
}
```

The response AAD MUST NOT include:

- `routing_internal.conversation_key`,
- raw buyer conversation tags,
- raw `account_id`,
- sticky-entry IDs,
- API keys,
- provider tokens.

The coordinator verifies p2c AAD before decrypting and before applying
Pillar D output safety.

Both c2p and p2c AAD authenticate `provider_id`, `assigned_id`, `request_id`,
`seq`, and `direction` so both parties commit to identical associated data for
every frame.

### 6.6 Encrypted request behavior

When Pillar B is enabled for a provider session, the coordinator MUST encrypt
the `body` value of SPEC-001 `inference_request` before that body crosses the
provider WebSocket.

The encrypted request MUST preserve cleartext metadata needed for routing and
correlation:

- `type`,
- `request_id`,
- `stream`,
- `encrypted`,
- `enc.alg`,
- `enc.kid`,
- `enc.seq`,
- `enc.nonce`,
- `enc.aad`,
- `enc.tag`.

The plaintext `body` field MUST be absent from an encrypted
`inference_request`.

The provider MUST decrypt the body before invoking its existing
`POST /v1/chat/completions` validation path.

### 6.7 Encrypted response behavior

When Pillar B is enabled for a provider session, the provider MUST encrypt
completion payloads before sending them to the coordinator.

For `inference_response_chunk`, the `data` value MUST be encrypted. The
cleartext `data` field MUST be absent.

For `inference_response_end`, terminal metadata MAY remain cleartext:

- `request_id`,
- `status`,
- `chunks_sent`,
- `usage`,
- `error` code class.

The provider MUST NOT put completion text inside cleartext terminal metadata.

The coordinator MUST decrypt response chunks before applying Pillar D output
safety and before writing to the buyer response.

#### 6.7.1 Decryption failure handling

On pre-commit AEAD failure, where no buyer bytes have been written, the
coordinator MUST:

- log MAJOR `T2.B aead_decrypt_failed`,
- avoid forwarding unauthenticated bytes to the buyer,
- close or quarantine the provider session,
- emit `T2.B encrypted_leg_session_closed`,
- return `tier2_aead_decrypt_failed` (HTTP 502) per §4.6.

SPEC-002 failover MAY be attempted for non-hard-pinned requests using a
different eligible provider. Hard-pinned requests MUST fail.

On post-commit AEAD failure, where streaming bytes have already been written
to the buyer, the coordinator MUST:

- log MAJOR `T2.B aead_decrypt_failed`,
- avoid forwarding additional bytes from the failed frame,
- emit a streaming SSE error event and close the buyer stream,
- close the provider session.

No retry or failover is attempted after buyer commit.

### 6.8 Fallback policy

`tier2.require_encrypted_leg` defaults to `false`.

When `tier2.require_encrypted_leg: false`:

- providers without Pillar B support remain routable under Tier-1 behavior,
- `/v1/models` MUST reveal that the provider/model entry is not uniformly
  encrypted,
- audit category `T2.B` MUST log fallback when a buyer request routes over an
  unencrypted leg and `tier2.observe_enabled: true` or any Pillar B
  configuration key is non-default.

Pillar B configuration is non-default when `encrypted_leg_aead` has been
changed, any `encrypted_leg_*` threshold is set to a non-default value, or an
encrypted provider exists for the model. Pure Tier-1 deployments with no
Pillar B config and no v2 providers remain exempt and unchanged.

When `tier2.require_encrypted_leg: true`:

- the coordinator MUST route only to providers with a negotiated Pillar B
  session,
- hard-pinned providers without a negotiated encrypted leg MUST fail with
  `tier2_hard_pin_predicate_failed`,
- requests with no eligible encrypted provider MUST return
  `503 tier2_encrypted_leg_required`.

All buyer-visible errors from this policy MUST follow §4.6 and §4.7.

### 6.9 Rekeying

The coordinator SHOULD rekey a Pillar B session after the earliest of:

- `tier2.encrypted_leg_rekey_after_requests` requests,
- `tier2.encrypted_leg_rekey_after_seconds` seconds,
- provider reconnect,
- AEAD frame counter exhaustion risk,
- operator-triggered key rotation.

Rekeying MUST NOT change sticky TTL, sticky key derivation, provider identity,
or model-hash state.

### 6.10 Coordinator restart behavior

Coordinator restart invalidates all in-memory Pillar B session keys.

- In-flight encrypted requests that have not yet committed buyer bytes MUST
  fail per SPEC-002's existing disconnect/timeout rules; the buyer receives
  the SPEC-002 503 or gateway error.
- In-flight streaming responses already committed to buyers MUST be treated as
  stream-closed; the buyer receives an incomplete stream.
- After restart, providers that reconnect MUST perform a fresh v2 auth
  handshake and key exchange before any encrypted frames are processed.
- If the coordinator can emit a `T2.B` event before shutdown, it SHOULD log
  `T2.B coordinator_restart_session_invalidated` for each active encrypted
  session at INFO severity.

Sticky state loss on coordinator restart remains governed by SPEC-004 §2
(cold-routing after in-memory loss). Pillar B key loss does not extend or
modify sticky TTL.

### 6.11 Pillar B acceptance criteria

**AC-B-1. ECDH session.**
A v2 mock provider and coordinator exchange X25519 public keys, derive the
same `key_id`, and successfully encrypt/decrypt a known test vector.

**AC-B-2. Request body encrypted on wire.**
With Pillar B enabled, a captured provider WebSocket frame for
`inference_request` contains no plaintext prompt bytes and has no cleartext
`body` field.

**AC-B-3. Response data encrypted on wire.**
With Pillar B enabled, a captured provider WebSocket frame for
`inference_response_chunk` contains no plaintext completion bytes and has no
cleartext `data` field.

**AC-B-4. Coordinator plaintext limitation.**
The coordinator can still apply routing, accounting, and Pillar D validation
after decryption. Docs and `/v1/models` do not describe Pillar B as
buyer-to-provider end-to-end encryption.

**AC-B-5. Default fallback.**
With `tier2.require_encrypted_leg: false`, an old provider that supports no
Pillar B fields remains routable and Tier-1 behavior is preserved.

**AC-B-6. Required encrypted leg.**
With `tier2.require_encrypted_leg: true`, an otherwise-routable old provider is
excluded and buyer receives `503 tier2_encrypted_leg_required` if no encrypted
provider remains.

---

## 7. Pillar C — Attestation

Pillar C lets a provider submit an attestation token that the coordinator
verifies and binds to the session. The name "hardware attestation" survives in
some buyer-visible field names (e.g. `hardware_attestation`, §13.3) and in the
aspirational MDA design, but the **shipped default is the self-signed
Secure-Enclave format** (`macprovider-se-p256-v1`, §7.4a), which proves only
key-custody + session binding, **not** hardware. Two formats reach positive
`attested` status at different trust strengths (`attestation_tier`, §7.3):

- **`macprovider-se-p256-v1`** (shipped, default-enabled): self-signed — verified
  against the provider's own submitted P-256 key, **no trust root**. Tier
  `self_signed`.
- **`apple-managed-device-attestation-acme-v1`** (aspirational/configured):
  validated against an operator-configured trust root with device-property
  matching. Would be the `hardware` tier — **not emitted by the shipped code**.

Sections §7.1–§7.3 describe the model and status; §7.4 the MDA data model; §7.4a
the shipped SE format; §7.4b the SE liveness re-challenge; §7.5–§7.8 the
verification flow, routing, disclosure, and acceptance criteria. Read
"hardware-attestation evidence" in the MDA-oriented prose below as the §7.4
aspirational path, not a description of the shipped default.

### 7.1 Threat model

Pillar C's **hardware-rooted MDA path** (§7.4, aspirational/configured) targets providers
lying about platform properties:

- a non-Apple-Silicon host claims to be Apple Silicon,
- a provider claims a RAM tier inconsistent with the attested hardware class,
- a provider sends a token from a different device.

**The shipped default `self_signed` path does NOT address the hardware/device items
above** — it verifies only key custody + session binding, and treats `hardware_family` /
`ram_gb` as unauthenticated self-asserted claims (§7.3, §7.4a). Both formats do address:

- a provider replays old attestation evidence (freshness + challenge binding, §7.5).

Pillar C does not prove:

- prompts are private from the provider,
- the provider will not inject malicious content,
- the MLX process cannot be tampered with after attestation,
- the exact model weights are loaded unless combined with Pillar A and a future
  runtime-measurement binding.

### 7.2 Recommended Apple starting point

The recommended Apple starting point for a Mac-hardware prototype is Managed
Device Attestation with ACME/device-management validation, not DeviceCheck
per-device bits alone.

Rationale:

- The target provider hardware is Mac, not only iOS.
- Apple's Managed Device Attestation is documented for Apple Silicon Macs on
  macOS 14 or later and is explicitly designed to provide cryptographic
  declarations of device properties through Apple attestation servers.
- DeviceCheck `DCDevice` is a fraud/state signal and does not by itself prove
  the provider binary or claimed RAM tier.
- App Attest is useful for validating an entitled app instance and Secure
  Enclave-backed app key, but the current Mac Provider distribution is a Swift
  CLI/LaunchAgent path. A future packaged, signed, entitled provider app MAY
  use App Attest as a sub-spec binding.

Therefore v0.2 defines the attestation data model generically and uses
`apple-managed-device-attestation-acme-v1` as the preferred prototype format.
If an operator can use neither managed-device enrollment **nor** the shipped self-signed
Secure-Enclave format (`macprovider-se-p256-v1`, §7.4a), the provider MUST report
attestation status as `"unsupported"` rather than simulating a weaker claim. (v0.4: the
default-enabled SE path is the shipped positive-attestation route for providers that
cannot obtain an Apple-MDA chain; it yields the `self_signed` tier, §7.3, not the
`hardware` tier — it is not a simulated MDA claim.)

### 7.3 Attestation status

For every provider session, the coordinator MUST compute one of:

- `attested`: token valid, fresh, bound to provider identity, and properties
  satisfy policy.
- `attestation_failed`: token present but invalid.
- `attestation_stale`: the token's **challenge (nonce) or freshness (`issued_at`/
  `expires_at`/`attestation_max_age_s`) check failed**. Note (v0.4, shipped): these checks
  run **before** format-specific signature verification (§7.5), so `attestation_stale`
  does **not** imply the token was cryptographically valid — a badly-signed token with a
  stale/mismatched challenge is classified stale, not failed. It is non-positive and is
  **excluded from routing only when `require_attestation: true`** (§7.6); under the default
  `require_attestation: false` a stale provider stays routable under Tier-1 behavior.
- `unsupported`: provider or platform does not support the configured
  attestation format.
- `not_required`: no attestation token present and
  `tier2.require_attestation: false`.
- `""` (empty, legacy): a pre-v2 / pre-attestation session that never carried an
  attestation status carries the empty zero value (`internal/pool/provider.go`). It is
  non-positive and, for the network-level aggregate (§7.7) and buyer disclosure (§13.3),
  counted the same as `unsupported`.

Only `attested` is a positive trust signal.

**Attestation tier (v0.4).** Orthogonal to the status above, the coordinator records
an **attestation tier** capturing *how strong* an `attested` result is, serialized as
`attestation_tier` on the provider (JSON `attestation_tier`, `omitempty`,
`internal/pool/provider.go`):

- `""` (empty): not attested, no tier established, **or** attested by a path the shipped
  WebSocket handler does not tag (see the tier-assignment gap below).
- `self_signed`: the provider proved possession of a P-256 key that it **asserts** is
  Secure-Enclave-backed, and bound it to the session/challenge, via the shipped
  **`macprovider-se-p256-v1`** format (§7.4a). This proves **key custody + session
  binding only**. It does **NOT** verify Secure-Enclave custody, Apple-Silicon
  provenance, or device identity: the coordinator checks a submitted P-256 public key,
  its self-signature, and the ECDH/session binding — the `hardware_family: apple_silicon`
  value is an **unauthenticated provider-supplied claim string** (`pillar_c.go`
  `attestationHardwareFamilyAllowed`), and a software P-256 key on any platform satisfies
  every check. It is a self-signed attestation, trusted at the tier the operator
  configures (`attestation_formats` includes it by default).
- `hardware`: a future/aspirational hardware-rooted tier (e.g. an Apple-Managed Device
  Attestation chain to a trusted root, §7.4). **The shipped code never emits this value**
  — the WebSocket handler assigns `attestation_tier` only on the SE path (see below);
  reserved.

**Tier-assignment gap (shipped, v0.4).** `attestation_tier` is set **only** when SE
verification succeeds (`internal/ws/server.go`, `entry.AttestationTier = "self_signed"`
guarded by a non-nil SE result). A successful **production MDA chain** or a **mock** root
also returns status `attested` (`pillar_c.go` `verifyProductionMDAChainShape`,
`mock_attested`) but carries an **empty** `attestation_tier`. Consumers therefore MUST
NOT assume every `attested` provider has a non-empty tier; a non-empty
`attestation_tier` is currently synonymous with the SE `self_signed` path. Promoting
MDA/mock to a labelled tier is a forward code change, out of scope for this spec-only pass.

This tier is the "attestation" half of the authority boundary SPEC-032 references when it
names SPEC-008 authoritative on attestation. Note (v0.4, forward): SPEC-032 currently only
*declares* SPEC-008 authoritative in its dependency header — it does **not** yet read
`attestation_tier`/`self_signed`, and its substantive attestation content is a deferred
future weight-binding proof, not a consumer of this tier. Should a future SPEC-032 (or any
other consumer) key off attestation, it MUST treat an empty tier on an `attested` provider
as "positively attested, strength not labelled", never as "not attested", and MUST NOT
treat `self_signed` as hardware-rooted trust (see §7.6/§13.3 for how the shipped surfaces
currently misgrade this).

### 7.4 Attestation data model

An attestation token submitted in SPEC-001 v2.0 candidate `auth_request`
MUST represent:

```json
{
  "format": "apple-managed-device-attestation-acme-v1",
  "token": "base64url-der-cbor-or-compact-jws-token",
  "challenge": "base64url-32-byte-coordinator-challenge",
  "issued_at": "2026-05-31T00:00:00Z",
  "expires_at": "2026-05-31T00:10:00Z",
  "provider_id": "m4-anon",
  "binary_version": "1.2.4",
  "claimed": {
    "hardware_family": "apple_silicon",
    "ram_gb": 16,
    "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "model_hash": "optional 64 lowercase hex chars"
  },
  "key_binding": {
    "provider_ecdh_public_key": "base64url-32-byte-x25519-public-key",
    "provider_signing_key_id": "optional-key-id"
  }
}
```

The provider MUST bind the token to:

- the coordinator's fresh challenge,
- `provider_id`,
- the session's provider ECDH public key when Pillar B is negotiated,
- the claimed hardware family,
- the claimed RAM tier when the selected attestation format can support it.

If the selected Apple attestation format cannot directly attest RAM size, the
coordinator MUST treat `ram_gb` as provider-reported and MUST NOT expose it as
attested. In that case `/v1/models` MAY still report `attested: true` for
Apple-Silicon device identity while separately reporting
`ram_tier_attested: false`.

Accepted `attestation_token.token` encodings are, **per format**:

- for `apple-managed-device-attestation-acme-v1` (§7.4): base64url-encoded raw DER
  or CBOR bytes, or compact JWS with exactly three dot-separated base64url segments;
- for `macprovider-se-p256-v1` (§7.4a): a **base64url-encoded JSON envelope**
  `{"attestation": {…}, "signature": "…"}` (the shipped SE encoding).

No other encodings are accepted **for a given format**. (v0.4 correction: v0.3 listed
only the DER/CBOR/JWS set and declared "no other encodings are accepted," which the
shipped, default-enabled `macprovider-se-p256-v1` path violates — see §7.4a. The
encoding rule is now scoped per format.)

**Size limits (shipped, two caps).** The maximum encoded `attestation_token.token` length
is 16384 bytes (16 KiB; `MaxAttestationTokenBytes`). Separately, the coordinator rejects
the **entire decoded attestation-token envelope** (the outer JSON object with `format`,
`token`, `challenge`, `claimed`, `key_binding`, signatures, …) when it exceeds 20480 bytes
(20 KiB; `MaxAttestationEnvelopeBytes = MaxAttestationTokenBytes + 4·1024`,
`internal/tier2/pillar_c.go`).

**Rejection transport (shipped, v0.4).** Attestation tokens are presented and verified on
the **provider WebSocket auth handshake**, not on a buyer HTTP request. In the shipped
verifier every rejection cause — over-limit (token or envelope), invalid base64url,
unparseable/invalid format, or signature/binding failure — collapses to attestation
**status `attestation_failed`** (`pillar_c.go`; the too-large case logs `T2.C
attestation_token_too_large`, others `attestation_failed`). Under
`require_attestation: true`, the coordinator sends a WS `auth_response` carrying that
failed status and closes the provider session with close code **4012**
(`CloseTier2AttestationFailed`); under optional attestation the session continues with
`attestation_failed` status. The `tier2_attestation_token_too_large` /
`tier2_attestation_token_invalid` **HTTP 400** codes catalogued in §4.6 are the
buyer-facing HTTP error catalog and are **not** emitted by the shipped WS verifier for a
provider-presented token — aligning that catalog with the WS `4012`/status path (or adding
an HTTP attestation-submission path) is a forward item.

### 7.4a Self-signed Secure-Enclave format (`macprovider-se-p256-v1`) — shipped (v0.4)

This is the **default-enabled, production attestation format** (in
`attestation_formats` by default; `internal/tier2/pillar_c_se.go`,
`internal/tier2/pillar_c.go`). It was absent from v0.3; v0.4 documents the shipped
reality. It yields `attestation_tier: self_signed` (§7.3).

**Token envelope.** `attestation_token.format = "macprovider-se-p256-v1"` and
`attestation_token.token` is the **unpadded base64url** (`base64.RawURLEncoding`; the
verifier trims surrounding whitespace first, and does not use the `.Strict()` variant)
encoding of this JSON object:

```json
{
  "attestation": {
    "publicKey": "base64(raw 64-byte P-256 x‖y, NO 0x04 prefix)",
    "encryptionPublicKey": "unpadded-base64url(32-byte X25519 pubkey)",
    "challenge": "…", "provider_id": "…", "ram_gb": 16, "...": "claims"
  },
  "signature": "base64(DER/ASN.1 ECDSA-P256 (ES256) signature)"
}
```

**Signature (body).** `signature` is a **DER/ASN.1 ECDSA (ES256)** signature (NOT raw
`r‖s`) over `SHA-256(canonical(attestation))`, verified with `ecdsa.VerifyASN1` against
the P-256 key in `attestation.publicKey`.

**Per-field base64 (shipped, interop-critical — the variants differ):**
- **Outer `attestation_token.token`**: unpadded base64url only (`base64.RawURLEncoding`).
- **Inner `attestation.publicKey` and the envelope's sibling `signature`** (the
  body-signature field is `signature` at the top level of the decoded
  `{"attestation":…, "signature":…}` wrapper — **not** nested inside `attestation`):
  decoded with a *flexible* base64 reader (`decodeFlexBase64`: tries standard **and**
  URL-safe alphabets, **with and without** padding), so a signer MAY use any of those four
  for those two fields.
- **Inner `attestation.encryptionPublicKey`**: this is **not** base64-decoded by the
  attestation verifier; it is compared **byte-for-byte as a string** against
  `key_binding.provider_ecdh_public_key`, which the coordinator emits as **unpadded
  base64url** (`base64.RawURLEncoding`, Pillar B). The provider MUST therefore serialize
  `encryptionPublicKey` as the exact unpadded-base64url string of its X25519 key, or the
  equality check fails.

**Key format.** The SE public key inside `attestation.publicKey` is the **raw 64-byte
uncompressed P-256 point `x‖y` WITHOUT the `0x04` prefix**. The coordinator does **NOT**
prepend `0x04`: it splits the exact 64 bytes into `X = bytes[0:32]`, `Y = bytes[32:64]`,
constructs the P-256 point directly, and **rejects the key unless the length is exactly 64
bytes AND `elliptic.P256().IsOnCurve(X, Y)`** (`pillar_c_se.go` `rawP256ToECDSA`). Both the
exact-64-byte length and the on-curve check are normative.

**Canonicalization (normative — interop-critical).** `canonical(attestation)` is the
output of **Go `encoding/json` marshalling of the decoded object** (`json.Marshal` on the
`map[string]interface{}` produced by `json.Unmarshal` of `attestation`) — i.e. **sorted
object keys**, Go's default **HTML-escaping ON**, and Go's default number formatting for
any JSON number (e.g. `ram_gb`). HTML-escaping ON means the bytes `<`, `>`, `&` are
emitted as the six-byte ASCII escape sequences **`\u003c`, `\u003e`, `\u0026`** (literal
backslash-u sequences, NOT the characters `<`/`>`/`&`), and U+2028 / U+2029 as `\u2028` / `\u2029` — they are **not** left as literal characters. This is
**NOT RFC-8785 (JCS)**: it is the byte-for-byte output of Go's standard library, and the
provider-side (Swift) signer MUST reproduce exactly these bytes (sign over the
Go-canonical re-marshalling, not over its own on-wire serialization). A future migration
to JCS is a **coordinated cross-repo (coordinator + Swift CLI) change**, out of scope for
v0.4.

**Session-binding signature (required).** In addition to the body signature, an SE token
MUST carry a second signature at `attestation_token.signature = {alg, signature}` (`alg`
= `"ES256"`, DER/ASN.1; `signature` = **unpadded base64url**) over
`SHA-256(binding_payload)`, verified with the same SE P-256 key. `binding_payload` is
`json.Marshal` of a **fixed-order 10-field struct** (`pillar_c.go`
`attestationBindingPayload`) — a signer MUST reproduce this struct, in this order, with
these exact JSON keys and value encodings:

```
binding_payload = json.Marshal({          // Go struct field order == emitted key order
  "version":                  "macprovider/spec008/attestation-binding/v1",
  "provider_id":              token.provider_id,
  "binary_version":           token.binary_version,
  "challenge":                token.challenge,                 // the base64url challenge string
  "auth_attempt_id":          <coordinator-assigned auth_attempt_id for this handshake>,
  "provider_ecdh_public_key": token.key_binding.provider_ecdh_public_key,
  "issued_at":                token.issued_at.UTC().Format(RFC3339),   // e.g. "2026-07-11T19:00:00Z"
  "expires_at":               token.expires_at.UTC().Format(RFC3339),
  "token_sha256":             unpadded_base64url( SHA-256( UTF-8(attestation_token.token) ) ),
  "claimed_sha256":           unpadded_base64url( SHA-256( json.Marshal(token.claimed) ) )
})
```

Notes that a re-implementer MUST honour: `token_sha256` hashes the **encoded token
string** (the base64url `token` field bytes, not its decoded content); `claimed_sha256`
hashes **Go's re-marshalling of `claimed`** (sorted keys, HTML-escaped — same canonical
rule as the body); timestamps are RFC3339 in **UTC**; both hashes and the outer
`signature` use **unpadded base64url**. A token whose body signature verifies but which
lacks a valid binding signature MUST be rejected (the shipped code requires it —
`pillar_c_se.go`, `pillar_c.go`). The token's `encryptionPublicKey` MUST equal the
session's `key_binding.provider_ecdh_public_key` when Pillar B is negotiated.

**What `self_signed` proves and does not.** It proves the provider holds the P-256 private
key matching the submitted public key, and bound that key to *this* session and challenge
(freshness + session binding). It does **NOT** verify that the key lives in a Secure
Enclave, that the host is Apple Silicon, or any device identity — `hardware_family:
apple_silicon` is an **unauthenticated self-asserted claim** any software P-256 key on any
platform can present. It does not chain to an Apple-attested device root, so it is not
proof of un-tampered hardware — it is a self-signed key-custody + session-liveness
attestation, trusted at the operator-configured tier. (The stronger `hardware` tier via
`apple-managed-device-attestation-acme-v1` remains §7.4's reserved path.)

### 7.4b SE liveness re-challenge protocol (`se_liveness_*`) — shipped (v0.4)

After a provider passes SE attestation (§7.4a) and its SE public key is recorded, the
coordinator periodically re-challenges it to confirm the **same key custodian is still
live on the session** (`internal/ws/se_liveness.go`, `internal/ws/messages.go`). This is
distinct from the Pillar-C auth `attestation_challenge` (which runs once at handshake).
v0.3 omitted this protocol entirely; a provider re-implementation that does not answer it
is closed after `se_liveness_max_failures` consecutive misses.

**Cadence.** A single sweep goroutine wakes every `se_liveness_interval_s` (default 300)
and, for each provider with a recorded SE key, launches at most one in-flight probe. Each
probe waits up to `se_liveness_timeout_s` (default 30) for a verified reply.

**Challenge (coordinator → provider).** JSON frame:

```json
{ "type": "se_liveness_challenge", "version": 1, "nonce": "…", "timestamp": "…" }
```
- `nonce` = **padded** base64url (`base64.URLEncoding`, *with* `=` padding — note this is
  **not** the RawURL variant used for the attestation token) of 32 fresh random bytes.
- `timestamp` = `now().UTC().Format(RFC3339)`.

**Response (provider → coordinator).** JSON frame:

```json
{ "type": "se_liveness_response", "version": 1,
  "nonce": "…", "timestamp": "…", "public_key": "…", "signature": "…" }
```
The provider MUST echo `nonce` and `timestamp` **byte-for-byte** and set `signature` =
**standard padded base64** (`base64.StdEncoding`) of a **DER/ASN.1 ECDSA (ES256)**
signature over `SHA-256( UTF-8( nonce ‖ timestamp ) )` — i.e. the SHA-256 of the string
concatenation of the echoed nonce and timestamp, with **no separator**.

**Verification.** The coordinator recomputes the digest from the *expected* nonce/timestamp
(rejecting any echo mismatch) and verifies the signature with the **stored** SE public key
from attestation (64 raw bytes `x‖y`; the `public_key` field in the response is not the
trust anchor — the attestation-time key is). Base64 variants are load-bearing and
asymmetric: the **challenge `nonce` is padded-URL** base64, the **response `signature` is
standard padded** base64.

**Failure handling.** On `se_liveness_max_failures` (default 3) **consecutive** failures
(bad signature, echo mismatch, or timeout) the coordinator marks the provider's
attestation stale and closes the session (`CloseTier2AttestationFailed`,
`se_liveness_stale`). A single pass resets the consecutive-failure counter. See §11.5 for
which of these knobs take effect on hot-reload.

### 7.5 Coordinator verification flow

The coordinator MUST generate a fresh random 32-byte attestation challenge per v2.0 auth
attempt and require the token to carry it. It then applies the following checks. **The
shipped order matters (`internal/tier2/pillar_c.go`): the identity/challenge/binding/
hardware-family/freshness checks below run *before* any format-specific signature
verification, so a token can be classified `attestation_failed`/`attestation_stale` without
its signature ever being checked** (§7.3):

1. Validate provider binding to `provider_id` (mismatch → `attestation_failed`).
2. Validate the token carries the coordinator's challenge (mismatch → `attestation_stale`).
3. Validate session binding to the provider ECDH public key when Pillar B is negotiated
   (mismatch → `attestation_failed`).
4. Validate the claimed hardware family against configured policy — a string-equality check
   on the self-asserted `hardware_family` (§7.3 — **not** a hardware proof).
5. Validate freshness against `issued_at`, `expires_at`, and `tier2.attestation_max_age_s`
   (expired/too-old → `attestation_stale`).
6. **Then** validate the token's cryptographic signature(s) **per format**:
   - for `macprovider-se-p256-v1` (§7.4a): verify the body signature and the required
     session-binding signature against the **submitted, self-signed** P-256 key — **no**
     `tier2.attestation_roots` entry is consulted (the SE path is dispatched *before* the
     root check and is accepted with an empty root set);
   - for `apple-managed-device-attestation-acme-v1` (§7.4) and the mock format: validate
     the certificate chain / token against `tier2.attestation_roots`.
7. Validate RAM tier only when the attestation format supplies a trustworthy RAM property.
8. Store the attestation status (and, on the SE path, the `self_signed` tier) in the
   provider pool entry.
9. Emit `T2.C` audit events for failures, unsupported formats, and successful
   attestations when audit sampling permits.

The coordinator MUST reject replayed challenges.

For the **MDA/mock formats**, the coordinator MUST reject tokens whose trust root is
absent from `tier2.attestation_roots`. This *verifier* root requirement does **not** apply
to the self-signed SE format (`macprovider-se-p256-v1`), which is verified
cryptographically against its own submitted key and is accepted with an empty
`attestation_roots` (§7.4a).

**Verifier vs startup-validation asymmetry (shipped, v0.4 — known gap).** The SE token
*verifier* needs no root, but **startup config validation** (`internal/config/config.go`;
§11.2) still rejects `require_attestation: true` with an empty `attestation_roots`,
unconditionally. So an operator who wants to **enforce attestation on an SE-only pool**
cannot start with empty roots — they must supply at least one (unused) `attestation_roots`
entry to satisfy startup even though the SE path never consults it. This is a shipped
constraint, not a spec preference; removing the root precondition for SE-only enforcement
is a forward config-validation change.

### 7.6 Routing predicate

`tier2.require_attestation` defaults to `false`.

When `tier2.require_attestation: false`:

- unsupported providers remain routable under Tier-1 behavior,
- when Pillar C disclosure is active on the coordinator `/v1/models` surface
  (`tier2.ConfigActive`, i.e. some `require_*` key, a catalog, `observe_enabled`, **or
  `behavioral_safety_enabled`** is set — so enabling Pillar D alone attaches the whole
  `tier2` block including attestation; a volunteered token or a merely-configured trust
  root does **not** activate it, §7.7),
  `/v1/models` MUST report attestation state accurately; at fully-default config the
  coordinator `/v1/models` omits the block entirely (the gateway surface still discloses
  per §13.3),
- operators MUST NOT describe unsupported providers as attested.

When `tier2.require_attestation: true`:

- the coordinator MUST route only to providers with status `attested`,
- hard-pinned providers without valid attestation MUST fail with
  `tier2_hard_pin_predicate_failed`,
- requests with no eligible attested provider MUST return
  `503 tier2_attestation_required`.

**What `require_attestation` does and does not require (v0.4).** The predicate gates on
attestation **status** `attested`, which **includes the `self_signed` (software-key SE)
tier** — it does **not** consult `attestation_tier` and therefore does **not** require
hardware-rooted attestation. With the shipped default formats, an operator setting
`require_attestation: true` is requiring "a valid self-signed key-custody + session
binding", not "trusted hardware". Requiring genuine hardware would need a
`hardware`-tier-gated predicate, which the shipped code does not yet implement (§7.3,
§13.3 overstatement note).

All buyer-visible attestation errors MUST follow §4.6 and §4.7.

### 7.7 `/v1/models` fields

**Shipped (v0.4): network-level attestation disclosure.** The shipped `/v1/models`
response exposes attestation **once at the top level** — `tier2.attestation` — not
per-model. The shipped object (`internal/buyer/server.go`, `attestationStateForProviders`)
is:

```json
"tier2": {
  "attestation": {
    "state": "all",                 // "none" | "all" | "partial" | "unsupported"
    "attested_provider_count": 2,
    "unsupported_provider_count": 0,
    "mixed": false                  // == (state == "partial")
  }
}
```

The shipped `state` enum (`attestationStateForProviders`, `internal/buyer/server.go`) is:
- `"none"` — no eligible providers counted;
- `"all"` — every counted provider is `attested`;
- `"partial"` — some but not all counted providers are `attested` (this is the "mixed"
  case; `mixed` is emitted as a **separate boolean** equal to `state == "partial"`, it is
  **not** a `state` value);
- `"unsupported"` — every counted provider is non-attested.

**Counting eligibility (shipped).** Only providers in `StateReady` are counted; busy or
other-state providers are excluded from both the numerator and denominator.

Field notes vs the v0.3 per-model block below: the shipped key is **`state`** (not
`status`); it emits `attested_provider_count`/`unsupported_provider_count`/`mixed` and
**does not** emit `failed_provider_count`, `ram_tier_attested_provider_count`, or
`format`; and it **collapses** `attestation_failed`/`attestation_stale`/`unsupported`/
`not_required` into the single non-positive `unsupported_provider_count` bucket (so the
failed-vs-unsupported split cannot be reconstructed from this surface). The `state` enum
**values** here are the same set §13.3 uses, but the two describe **different surfaces
with different activation**: this section is the coordinator's own `/v1/models`, which
attaches the `tier2` block only when `tier2.ConfigActive` is true (config-driven) and
counts `StateReady` providers; §13.3 is the buyer-visible gateway disclosure, which is
driven by `/internal/routing` and activates on **pool evidence** — the presence of **any**
`StateReady` provider (an all-negative/tokenless ready pool discloses `unsupported`) —
regardless of coordinator config. Do not read §13.3's pool-evidence activation as applying
to this `/v1/models` surface; and note this `/v1/models` block is absent (its `state` not
emitted) when `ConfigActive` is false, whereas §13.3's `none` means specifically an empty
ready pool. The Pillar A hash disclosure (§5.7) IS
emitted **per-model** and matches §5.7 field-for-field — attestation and hash disclosure
have different shapes on purpose.

With all `tier2.*` keys at defaults and no provider attestation evidence,
`/v1/models` MUST preserve Tier-1 buyer-visible behavior (no `tier2.attestation`
positive claims).

**Deferred (forward requirement): per-model attestation disclosure.** The v0.3
per-model `attestation{status, attested/unsupported/failed/ram_tier counts, format}`
block below is **not shipped** and is retained as a **forward enhancement**, not a
current requirement. It has product value (buyers seeing which specific models are
attested and at what tier) and SHOULD be implemented when attestation disclosure is
promoted to a buyer-facing product surface — at which point it MUST also carry
`attestation_tier` (§7.3) and the failed-vs-unsupported split. Until then the
network-level shape above is normative. *(Deferred v0.3 shape, for reference:)*

```json
{
  "attested": true,
  "attestation": {
    "status": "all_attested",
    "attested_provider_count": 2,
    "unsupported_provider_count": 0,
    "failed_provider_count": 0,
    "ram_tier_attested_provider_count": 0,
    "format": "apple-managed-device-attestation-acme-v1"
  }
}
```

### 7.8 Pillar C acceptance criteria

**AC-C-1. Valid MDA attestation.**
Given a valid `apple-managed-device-attestation-acme-v1` token over the coordinator
challenge and a **configured trust root**, **and with Pillar C disclosure active**
(`tier2.ConfigActive` — e.g. `require_attestation: true` or `observe_enabled: true`; a
configured root alone does **not** activate `ConfigActive`), the provider session is marked
`attested`, coordinator `/v1/models` reports the attested count, and `T2.C
attestation_valid` is logged. (The trust-root precondition applies to the MDA/mock formats
only; see AC-C-7 for the SE path. Without `ConfigActive`, verification and the `T2.C` log
still occur, but `/v1/models` omits the `tier2` block — §7.7.)

**AC-C-2. Replay rejected.**
Given a token generated over an old challenge, the coordinator marks the
session `attestation_stale`, logs `T2.C attestation_replay`, and excludes it
when `tier2.require_attestation: true`.

**AC-C-3. Wrong provider binding rejected.**
Given a token bound to provider A but sent by provider B, the coordinator
marks `attestation_failed` and logs `provider_binding_mismatch`.

**AC-C-4. Unsupported preserves Tier 1 by default.**
With `tier2.require_attestation: false`, an old provider with no attestation
token remains routable. When Pillar C observation is active, it is reported as
`"unsupported"`.

**AC-C-5. Required attestation filter.**
With `tier2.require_attestation: true`, unsupported providers are excluded and
buyer receives `503 tier2_attestation_required` when no attested provider
remains.

**AC-C-6. RAM tier honesty.**
If the selected attestation format does not supply RAM size, the coordinator MUST NOT
represent RAM as attested even when device identity is attested. (Scope note, v0.4: the
shipped network-level `/v1/models` `tier2.attestation` object exposes **no**
`ram_tier_attested` field at all — RAM-tier attestation counting belongs to the deferred
per-model disclosure block, §7.7. This AC therefore constrains internal RAM-attestation
state, not a shipped `/v1/models` field.)

**AC-C-7. Valid SE attestation without a trust root (shipped SE path).**
Given a valid `macprovider-se-p256-v1` token — a P-256 body signature over the
Go-canonical `attestation`, plus a valid `macprovider/spec008/attestation-binding/v1`
session-binding signature, with `encryptionPublicKey` equal to the session ECDH key — and
with `tier2.attestation_roots` **empty**, the provider session is marked `attested`,
`attestation_tier` is set to `self_signed`, and `T2.C attestation_valid`
(`se_p256_attested`) is logged. No trust root is required or consulted.

**AC-C-8. SE canonicalization / binding-payload fidelity.**
A `macprovider-se-p256-v1` token whose body signature is computed over any serialization
other than Go `encoding/json` of the decoded `attestation` (e.g. JCS, or emitting the
literal characters `<`/`>`/`&` rather than the escape sequences `\u003c`/`\u003e`/`\u0026`), or whose binding signature omits any of
the ten ordered `attestation-binding/v1` fields (§7.4a), MUST be rejected
(`se_p256_verification_failed`).

**AC-C-9. SE liveness re-challenge.**
Given an SE-attested provider, after `se_liveness_max_failures` consecutive liveness
probes fail (bad ES256 signature over `SHA-256(nonce‖timestamp)`, echo mismatch, or
timeout), the coordinator marks attestation stale and closes the session with
`se_liveness_stale`; a single passing probe resets the consecutive-failure counter (§7.4b).

---

## 8. Pillar D — Untrusted-provider behavioral safety

Pillar D adds coordinator-enforced output controls that do not trust provider
self-report.

### 8.1 Threat model

Pillar D reduces risk from a malicious or compromised provider that:

- emits oversized completions to exfiltrate data or attack buyers,
- emits invalid encoding or control characters to abuse downstream parsers,
- introduces abnormal latency patterns inconsistent with declared runtime
  behavior.

Pillar D does not prove the answer is truthful, harmless, or policy-compliant.
It is transport and relay safety, not semantic content moderation.

### 8.2 Enablement

`tier2.behavioral_safety_enabled` defaults to `false`.

When false, Pillar D MUST NOT change Tier-1 buyer-visible behavior.

When true, the coordinator MUST apply the enabled controls below to every
response chunk before writing it to the buyer. §8.6 defines how the global flag
and per-control flags compose.

### 8.3 Response size cap

The coordinator MUST enforce an output byte cap when Pillar D is enabled and
`tier2.output_size_cap_bytes` is configured to a positive integer.

When `tier2.output_size_cap_bytes: 0`, the size-cap control is disabled even
if `tier2.behavioral_safety_enabled: true`.

When the size-cap control is active, the effective cap is
`tier2.output_size_cap_bytes`. Implementations MAY use
`request.max_tokens * tier2.output_bytes_per_token_ceiling` or
`tier2.default_output_size_cap_bytes` to choose an operator-recommended cap,
but those helper values MUST NOT activate the size-cap control while
`output_size_cap_bytes` remains `0`.

The coordinator MUST count bytes after Pillar B decryption and before buyer
write.

The coordinator MUST stop forwarding completion bytes once the cap is reached.

For streaming responses, the coordinator SHOULD finish the stream with a
well-formed terminal event when it can do so without exceeding the cap. It MUST
log `T2.D oversized_completion_truncated`.

For non-streaming responses, the coordinator MUST return a valid JSON response
or an OpenAI-compatible error. It MUST NOT return malformed JSON solely because
the provider exceeded the cap.

If preserving UTF-8 validity requires truncating before the exact cap, the
coordinator MUST prefer valid UTF-8 and MUST log both configured cap and
emitted byte count.

### 8.4 Completion encoding validation

When Pillar D is enabled and `tier2.encoding_validation_enabled: true`, the
coordinator MUST reject provider completions that contain:

- non-UTF-8 bytes after frame decoding,
- invalid JSON in non-streaming completion bodies,
- invalid SSE `data:` framing in streaming completion chunks,
- embedded provider-control messages inside completion text.

The coordinator MUST apply validation after Pillar B decryption and before
buyer write.

Forbidden codepoint ranges after Pillar B decryption and before buyer write
are:

- C0 range U+0000-U+001F, except U+0009 (TAB), U+000A (LF), and U+000D (CR),
- U+007F (DEL),
- C1 range U+0080-U+009F.

Validation targets are:

- Streaming: the decoded completion text extracted from each SSE `data:`
  field. JSON string escapes in the SSE payload, such as `\u0000`, are decoded
  before validation; the escaped byte value is subject to the forbidden-range
  check.
- Non-streaming: the decoded completion text from the `content` field of the
  response JSON body. Invalid JSON in the body is rejected separately per the
  invalid-JSON rule above.
- SSE framing: the coordinator MUST NOT reject control bytes that are part of
  valid SSE framing, including newlines and colons in `data:` lines; only the
  completion text payload is checked.

On validation failure before buyer bytes are committed, the coordinator MUST
return an OpenAI-compatible error with code `tier2_output_encoding_invalid`.

On validation failure after streaming bytes are committed, the coordinator
MUST terminate the stream with an error event where possible, close the stream,
and log `T2.D output_encoding_rejected`.

### 8.5 Response-time anomaly logging

When Pillar D is enabled and `tier2.response_time_anomaly_enabled: true`, the
coordinator SHOULD log a WARN audit event when a provider's time-to-first-token
significantly exceeds its declared `model_load_time` baseline or a
coordinator-derived baseline.

The v0.2 anomaly threshold is:

```
ttft_ms > max(
  tier2.response_time_anomaly_min_ms,
  provider.model_load_time_ms * tier2.response_time_anomaly_factor
)
```

If the provider does not report `model_load_time_ms`, the coordinator SHOULD
use a rolling model/provider baseline. Missing baseline MUST NOT block routing.

An anomaly is a signal, not a failure. The coordinator SHOULD NOT reject the
request solely because of this control in v0.2.

### 8.6 Pillar D flag precedence matrix

The global `tier2.behavioral_safety_enabled` flag enables the Pillar D
framework. The per-control flags and effective cap determine disclosure:

| behavioral_safety_enabled | output_size_cap_bytes | encoding_validation_enabled | response_time_anomaly_enabled | Effective state | untrusted_provider_safety |
|---|---|---|---|---|---|
| false | any | any | any | disabled | `"none"` |
| true | 0 | false | false | size cap disabled; all controls off | `"none"` |
| true | >0 | false | false | size cap only | `"partial"` |
| true | 0 | true | false | encoding only | `"partial"` |
| true | 0 | false | true | TTFT only | `"partial"` |
| true | >0 | true | true | all controls | `"enforced"` |
| true | >0 | true | false | cap + encoding | `"partial"` |
| true | >0 | false | true | cap + TTFT | `"partial"` |
| true | 0 | true | true | encoding + TTFT | `"partial"` |

`"enforced"` requires size cap active (`output_size_cap_bytes > 0`), encoding
validation on, and TTFT anomaly logging on. Any missing control makes the
state `"partial"`. `"enforced"` means size cap and encoding validation are
hard-enforced; TTFT anomaly logging is a best-effort WARN signal that does not
reject responses.

### 8.7 Pillar D acceptance criteria

**AC-D-1. Exact cap on ASCII streaming.**
With Pillar D enabled and `tier2.output_size_cap_bytes: 32`, a provider that
streams 64 ASCII completion bytes causes the coordinator to forward exactly 32
completion bytes and log `T2.D oversized_completion_truncated`.

**AC-D-2. Valid UTF-8 preferred.**
With Pillar D enabled and a cap that falls inside a multi-byte UTF-8 code
point, the coordinator emits only complete code points and logs configured cap
plus actual emitted byte count.

**AC-D-3. Malformed encoding rejected.**
With Pillar D enabled, a provider chunk containing invalid UTF-8 is rejected
with `tier2_output_encoding_invalid` before buyer commit, or a streaming error
event after buyer commit.

**AC-D-4. Control character rejection.**
A provider response whose decoded completion text contains codepoints in the
forbidden ranges from §8.4 is rejected and logged as
`T2.D output_encoding_rejected`.

**AC-D-5. TTFT anomaly warning.**
Given `behavioral_safety_enabled: true`, `response_time_anomaly_enabled: true`,
`response_time_anomaly_factor: 5`, `response_time_anomaly_min_ms: 0`, and a
provider baseline `model_load_time_ms: 1000`, a provider response with TTFT
5001 ms logs a WARN audit event without rejecting the response solely for
TTFT.

`response_time_anomaly_min_ms: 0` disables the minimum floor and is suitable
for acceptance testing. Production deployments MAY set a higher floor to
reduce noise.

---

## 9. Phase roadmap

### 9.1 Phase 1: Pillar A

Phase 1 ships model catalog and hash verification.

Prerequisites:

- signed catalog format implemented,
- `tier2.catalog_path` configured for operators who want verification,
- coordinator provider-pool entry stores hash status,
- `/v1/models` exposes `hash_verified` and `hash_verification`,
- audit category `T2.A` implemented.

No SPEC-001 wire change is required. `model_hash` is optional and old
providers omit it.

Default flags:

- `tier2.require_hash_verified: false`

Production enablement:

- Operators MAY load a catalog and observe verification state without
  requiring it.
- Operators MAY set `tier2.require_hash_verified: true` only after enough
  providers report matching hashes for target models.

Disclosure transition:

- `/v1/models tier1_disclosure.model_hash_verified` MUST update from
  `"none"` to `"partial"` or `"all"` according to actual pool state.
- Mixed pools MUST disclose mixed state.

Estimated implementation scope: 2-4 engineering days for coordinator catalog
load, provider-field parsing, aggregation, tests, and disclosure update.

### 9.2 Phase 2: Pillars B and C

Phase 2 ships provider-leg encryption and attestation together. "Attestation"
here is, in the shipped code, the **self-signed Secure-Enclave** format
(`macprovider-se-p256-v1`, tier `self_signed`, §7.4a) — key-custody + session
binding, not hardware-rooted. The `hardware`-tier Apple-MDA path (§7.4) is
configured/aspirational and not emitted by the shipped code; do not read "Phase 2
ships hardware attestation" as a hardware-trust guarantee (§7.3, §13.3).

Prerequisites:

- SPEC-001 v2.0 handshake extension accepted,
- provider binary supports X25519 and AEAD envelope,
- coordinator supports X25519, HKDF, AEAD, and encrypted relay,
- attestation token format selected for first prototype,
- coordinator trust roots configured **for the MDA path only** — the shipped default
  `self_signed` SE path needs **no** trust root (SE verification precedes the root check,
  §7.4a/§7.5); roots become a startup-validation requirement only when
  `require_attestation: true` (§7.5, §11.2), not a universal Phase-2 prerequisite,
- `/v1/models` exposes encrypted-leg and attestation counts,
- audit categories `T2.B` and `T2.C` implemented.

SPEC-001 v2.0 is required because both pillars extend the provider
authentication/registration handshake.

Default flags:

- `tier2.require_encrypted_leg: false`
- `tier2.require_attestation: false`

Production enablement:

- Operators SHOULD observe encrypted/attested state before requiring it.
- Operators SHOULD require encrypted leg before requiring attestation if the
  attestation prototype has incomplete platform coverage.
- Operators MUST NOT claim provider-private prompts because Pillar B is not
  end-to-end encryption.

Disclosure transition:

- `/v1/models tier1_disclosure.provider_leg_encryption` MUST reflect partial
  or all encrypted provider-leg state.
- `/v1/models tier1_disclosure.hardware_attestation` MUST reflect partial or
  all attestation state.

Estimated implementation scope: 7-14 engineering days, excluding Apple
attestation enrollment or certificate-authority setup.

### 9.3 Phase 3: Pillar D

Phase 3 ships behavioral safety controls.

Prerequisites:

- coordinator relay loop has pre-buyer-write validation hooks,
- streaming and non-streaming paths share cap and encoding enforcement,
- audit category `T2.D` implemented,
- tests cover pre-commit and post-commit streaming behavior,
- docs explain that these controls do not make provider output trustworthy.

No SPEC-001 wire change is required.

Default flags:

- `tier2.behavioral_safety_enabled: false`
- `tier2.output_size_cap_bytes: 0`
- `tier2.encoding_validation_enabled: false`
- `tier2.response_time_anomaly_enabled: false`

Production enablement:

- Operators MAY enable Pillar D independently of Pillars A-C.
- Operators SHOULD enable Pillar D first in shadow/log-only mode if the
  implementation supports shadow decisions (shadow mode is optional and out of
  normative scope for v0.3).

Disclosure transition:

- `/v1/models tier1_disclosure.untrusted_provider_safety` MUST reflect whether
  Pillar D controls are disabled, partial, or enforced.

Estimated implementation scope: 3-6 engineering days for relay hooks, tests,
streaming edge cases, and audit logs.

### 9.4 Phase transition invariants

Each phase transition MUST:

- preserve all §2 survivability invariants,
- keep new `tier2.*` defaults Tier-1-preserving,
- update `/v1/models` disclosure automatically,
- emit structured audit logs for enforcement decisions,
- include deterministic acceptance tests before production enablement.

---

## 10. SPEC-001 v2.0 candidate annotations

This section is the normative reference for a future SPEC-001 v2.0 BUILD
session. It does not edit SPEC-001 v1.2.4.

### 10.1 Backward compatibility

Old providers may continue to send SPEC-001 v1 `hello`.

If the first provider message is `hello` with `version: 1`, the coordinator
MUST process the provider under Tier-1 semantics unless operator config
requires Tier-2 predicates that the provider cannot satisfy.

SPEC-001 v2.0 providers use `auth_request` messages. The coordinator MUST NOT
require v2.0 by default.

#### 10.1.1 First-message dispatch rule

The coordinator MUST apply this deterministic rule to the provider's first
WebSocket message:

1. If the message parses as JSON and `type == "auth_request"` and
   `version == 2`, process as SPEC-001 v2.0 auth flow.
2. If the message parses as JSON and `type == "hello"` and `version == 1`,
   process as SPEC-001 v1 (Tier-1 semantics).
3. Otherwise, close the WebSocket with close code 4000 and reason
   "unrecognized auth message" per §4.7.

The coordinator MUST NOT send any frame before the provider's first message.
No welcome or capability frame is required in v0.2; the first-message `type`
field is sufficient for dispatch.

#### 10.1.2 Future coordinator capability frame

A coordinator-capability frame MAY be defined in a SPEC-001 v2.1 annotation if
bidirectional negotiation is needed for cipher-suite selection before the
provider sends `auth_request`.

### 10.2 Candidate `auth_request` initial message

Direction: P->C.

Purpose: provider announces identity, model, Tier-2 capabilities, and
cryptographic material.

```jsonc
{
  "type": "auth_request",
  "version": 2,
  "stage": "initial",
  "provider_id": "m4-anon",
  "hostname": "Johns-MacBook-Pro.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 1, // default: 1 per SPEC-001 v1.2.4 §FR-9; increase only after parallel-generation validation
  "throughput_tps_estimate": 19.8,
  "binary_version": "2.0.0",
  "endpoint_url": null,
  "model_hash": "64 lowercase hex chars",
  "tier2_capabilities": {
    "encrypted_leg": true,
    "attestation": true,
    "aead_suites": ["A256GCM", "CHACHA20-POLY1305"]
  },
  "provider_ecdh_public_key": "base64url-32-byte-x25519-public-key"
}
```

Required fields:

- All SPEC-001 v1 `hello` required fields, mapped to `auth_request`.
- `type`: string, exactly `"auth_request"`.
- `version`: integer, exactly `2`.
- `stage`: string, `"initial"` or `"proof"`.

Optional fields:

- `model_hash`: string, lowercase hex SHA-256.
- `tier2_capabilities.encrypted_leg`: boolean.
- `tier2_capabilities.attestation`: boolean.
- `tier2_capabilities.aead_suites`: array of strings.
- `provider_ecdh_public_key`: string, base64url 32-byte X25519 public key.
- `attestation_token`: object, present only on `stage: "proof"` or when the
  selected format supports pre-challenge evidence.

### 10.3 Candidate `auth_challenge`

Direction: C->P.

Purpose: coordinator supplies freshness challenge, selected encryption suite,
and coordinator ECDH public key.

```json
{
  "type": "auth_challenge",
  "version": 2,
  "auth_attempt_id": "auth-550e8400-e29b-41d4-a716-446655440000",
  "assigned_id": "provider-pool-id",
  "attestation_challenge": "base64url-32-byte-random",
  "coordinator_ecdh_public_key": "base64url-32-byte-x25519-public-key",
  "selected_aead_suite": "A256GCM",
  "expires_at": "2026-05-31T00:10:00Z"
}
```

Required fields:

- `type`: string, exactly `"auth_challenge"`.
- `version`: integer, exactly `2`.
- `auth_attempt_id`: string.
- `assigned_id`: string.
- `attestation_challenge`: string, base64url 32 bytes.
- `coordinator_ecdh_public_key`: string, base64url 32 bytes when encrypted leg
  is negotiated.
- `selected_aead_suite`: string, one supported suite or `null` when disabled.
- `expires_at`: RFC 3339 timestamp.

### 10.4 Candidate `auth_request` proof message

Direction: P->C.

Purpose: provider returns attestation over the challenge.

```json
{
  "type": "auth_request",
  "version": 2,
  "stage": "proof",
  "auth_attempt_id": "auth-550e8400-e29b-41d4-a716-446655440000",
  "provider_id": "m4-anon",
  "attestation_token": {
    "format": "apple-managed-device-attestation-acme-v1",
    "token": "base64url-der-cbor-or-compact-jws-token",
    "challenge": "base64url-32-byte-random",
    "issued_at": "2026-05-31T00:00:00Z",
    "expires_at": "2026-05-31T00:10:00Z",
    "claimed": {
      "hardware_family": "apple_silicon",
      "ram_gb": 16
    }
  }
}
```

The example above shows the **MDA format** and is illustrative only — it is **not** a
complete accepted token. The normative `attestation_token` data model (all required
nested fields) is §7.4, and the shipped default-enabled **SE format** shape is §7.4a. In
particular the shipped coordinator parses and **binds** more than the example shows: a
token also carries `provider_id`, `key_binding.provider_ecdh_public_key`, and — for
`macprovider-se-p256-v1` — the top-level `signature` session-binding block (§7.4a); a
token missing **those** is rejected even though the illustrative JSON omits them.
`binary_version` is also carried and is folded into the signed binding payload (§7.4a),
but the shipped verifier does **not** require it to be non-empty — a correctly-signed token
with an empty/absent `binary_version` is accepted.

`attestation_token`:

- Type: object.
- Required when `tier2.require_attestation: true`.
- Optional when attestation is unsupported or not required.
- MUST include `format`, `token`, `challenge`, freshness fields, and the binding fields
  named above per §7.4/§7.4a.
- Accepted `token` encodings are **per format** (§7.4): for
  `apple-managed-device-attestation-acme-v1`, base64url-encoded raw DER/CBOR bytes or
  compact JWS with exactly three dot-separated base64url segments; for
  `macprovider-se-p256-v1`, the unpadded-base64url JSON envelope `{"attestation":…,
  "signature":…}` of §7.4a.
- Maximum encoded `token` length is 16384 bytes (16 KiB); the full decoded
  attestation-token envelope is separately capped at 20480 bytes (20 KiB) (§7.4).
- Oversized or malformed tokens (invalid base64url, invalid compact JWS, or decoded bytes
  not parseable as the declared format) are rejected on the **WS auth path**: the verifier
  returns attestation status `attestation_failed` (over-limit logs `T2.C
  attestation_token_too_large`), which under `require_attestation: true` yields a WS
  `auth_response` with the failed status and a close code `4012`
  (`CloseTier2AttestationFailed`). The HTTP-400 `tier2_attestation_token_too_large` /
  `tier2_attestation_token_invalid` codes in §4.6 are the buyer-facing catalog and are not
  emitted by the shipped WS verifier (see §7.4).

### 10.5 Candidate `auth_response`

Direction: C->P.

Purpose: coordinator accepts or rejects the provider and communicates Tier-2
session state.

```json
{
  "type": "auth_response",
  "version": 2,
  "status": "accepted",
  "assigned_id": "provider-pool-id",
  "heartbeat_interval_s": 30,
  "tier": "pinned",
  "recommended_binary_version": "2.0.0",
  "tier2_session": {
    "encrypted_leg": {
      "enabled": true,
      "alg": "A256GCM",
      "kid": "base64url-key-id",
      "rekey_after_requests": 10000,
      "rekey_after_seconds": 3600
    },
    "attestation": {
      "status": "attested",
      "ram_tier_attested": false
    },
    "model_hash": {
      "status": "hash_verified"
    }
  }
}
```

Rejected responses MUST include:

```json
{
  "type": "auth_response",
  "version": 2,
  "status": "rejected",
  "error": {
    "code": "attestation_failed",
    "message": "attestation failed"
  }
}
```

Rejected `auth_response.error.message` values MUST follow §4.7 and MUST NOT
include key material, raw attestation token bytes, JWS bodies, raw challenge
bytes, hash details beyond allowed prefixes, or trust-root internals.

### 10.6 Candidate encrypted `inference_request`

Direction: C->P.

Existing cleartext v1:

- `body`: string, required.

Encrypted v2:

```json
{
  "type": "inference_request",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "stream": true,
  "encrypted": true,
  "enc": {
    "alg": "A256GCM",
    "kid": "base64url-key-id",
    "seq": 0,
    "nonce": "base64url-12-byte-nonce",
    "aad": "base64url-canonical-aad",
    "ciphertext": "base64url-ciphertext",
    "tag": "base64url-authentication-tag"
  }
}
```

Rules:

- `body` MUST be absent when `encrypted: true`.
- `enc.ciphertext` decrypts to the exact v1 `body` string bytes.
- Old providers that omit encrypted-leg support MUST receive v1 cleartext
  `inference_request` unless `tier2.require_encrypted_leg: true`.

### 10.7 Candidate encrypted `inference_response_chunk`

Direction: P->C.

Encrypted v2:

```json
{
  "type": "inference_response_chunk",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "seq": 0,
  "encrypted": true,
  "enc": {
    "alg": "A256GCM",
    "kid": "base64url-key-id",
    "seq": 0,
    "nonce": "base64url-12-byte-nonce",
    "aad": "base64url-canonical-aad", // aad: base64url-canonical p2c AAD per §6.5.2 (direction: "p2c")
    "ciphertext": "base64url-ciphertext",
    "tag": "base64url-authentication-tag"
  }
}
```

Rules:

- `data` MUST be absent when `encrypted: true`.
- `enc.ciphertext` decrypts to the exact v1 `data` string bytes.
- `enc.aad` MUST use the §6.5.2 response AAD schema.

### 10.8 Candidate encrypted terminal message

`inference_response_end` remains mostly cleartext because it carries control
metadata and accounting usage. It MUST NOT carry completion text.

If a future SPEC-001 v2.0 session chooses to encrypt error text, it MAY add an
optional `enc_error` envelope. That is not required for SPEC-008 v0.2.

### 10.9 Close codes and fallback

SPEC-001 v2.0 SHOULD reserve close or rejection codes:

- `4010 tier2_encryption_required`
- `4011 tier2_attestation_required`
- `4012 tier2_attestation_failed`
- `4013 tier2_key_exchange_failed`
- `4014 tier2_unsupported_cipher`

Old providers that omit all v2 fields are treated as Tier-1-only.

WebSocket close reasons MUST follow §4.7. They MUST identify only the failure
class and MUST NOT include raw keys, nonces, secrets, attestation token bytes,
JWS bodies, raw challenge bytes, unredacted hashes, account identifiers, or
trust-root details.

---

## 11. Configuration

All new configuration keys live under `tier2` in `coordinator.yaml`.

Every default preserves Tier-1 behavior on the coordinator's own surfaces (subject to the
one shipped gateway-disclosure exception noted in §1.1 / §4.3 / §13.2).

### 11.1 Required shape

```yaml
tier2:
  # Explicit observation gate
  observe_enabled: false           # default false: no Tier-2 observe/log/API changes

  # Phase 1 / Pillar A
  catalog_path: ""                 # empty: no active model catalog
  catalog_public_key: ""           # empty unless catalog_path is set
  require_hash_verified: false     # default false: do not filter uncatalogued providers (hash_mismatch/hash_invalid are ALWAYS excluded from routing regardless — §5.5-5.6)

  # Phase 2 / Pillar B
  require_encrypted_leg: false     # default false: old providers route
  encrypted_leg_aead: "A256GCM"
  encrypted_leg_rekey_after_requests: 10000
  encrypted_leg_rekey_after_seconds: 3600

  # Phase 2 / Pillar C
  require_attestation: false       # default false: unsupported providers route
  attestation_roots: []            # empty: no required attestation trust roots
  attestation_max_age_s: 600
  attestation_formats:             # v0.4: shipped default includes the SE format
    - "apple-managed-device-attestation-acme-v1"
    - "macprovider-se-p256-v1"     # self-signed SE P-256 (§7.4a); default-enabled
  allow_mock_attestation: false    # default false; startup-only; enables the mock root for tests (§11.5)
  # SE liveness re-challenge (§7.4b):
  se_liveness_interval_s: 300      # stored on reload but NOT effective until restart (see §11.5)
  se_liveness_timeout_s: 30        # hot-reloadable (effective next probe)
  se_liveness_max_failures: 3      # hot-reloadable (effective next probe)

  # Phase 3 / Pillar D
  behavioral_safety_enabled: false # default false: no relay behavior change
  output_size_cap_bytes: 0         # 0: size-cap control disabled
  output_bytes_per_token_ceiling: 16    # helper only - never activates enforcement
  default_output_size_cap_bytes: 1048576 # helper only - never activates enforcement
  encoding_validation_enabled: false
  response_time_anomaly_enabled: false
  response_time_anomaly_factor: 5.0
  response_time_anomaly_min_ms: 10000

```

There is intentionally no `tier2.disclosure_update_enabled` flag. Accurate
Tier-2 disclosure is mandatory when any pillar is active and MUST NOT be
operator-overrideable.

There is intentionally no `tier2.phase` config flag. Disclosure phase is a
computed read-only value defined in §13.2.

### 11.2 Validation

Startup MUST fail when:

- `catalog_path` is non-empty and `catalog_public_key` is empty.
- `require_hash_verified: true` and no valid catalog can be loaded.
- `encrypted_leg_aead` is not a supported suite.
- `encrypted_leg_rekey_after_requests <= 0`.
- `encrypted_leg_rekey_after_seconds <= 0`.
- `require_attestation: true` and `attestation_roots` is empty.
- `attestation_max_age_s <= 0`.
- `output_bytes_per_token_ceiling <= 0`.
- `default_output_size_cap_bytes <= 0` (helper must be sane if operator uses
  it for cap selection).
- `behavioral_safety_enabled: true` and `encoding_validation_enabled: true`
  and `output_size_cap_bytes < 0`.
- `response_time_anomaly_factor <= 1.0`.
- `response_time_anomaly_min_ms < 0`.

Startup MUST NOT fail solely because all Tier-2 features are disabled.

`output_size_cap_bytes: 0` with `behavioral_safety_enabled: true` is valid -
the size-cap control is disabled while the Pillar D framework is active (§8.3
matrix row 2).

`tier2.observe_enabled` defaults to false and exists to allow
observe-without-enforce deployments. A deployment with all other `tier2.*` keys
at defaults and no `catalog_path` MUST also have `observe_enabled: false` to
qualify as a default-config deployment. Setting `observe_enabled: true` is an
explicit non-default operator opt-in that activates Tier-2 evidence
computation, audit events, and disclosure fields without enabling a required
routing predicate.

### 11.3 Default-off resolution for Pillar D

The Tier-2 hard rule is additive-only. Therefore encoding validation,
response-time anomaly logging, and output-size enforcement remain disabled
unless `tier2.behavioral_safety_enabled` and the relevant per-control setting
are explicitly enabled.

This v0.2 choice intentionally rejects any default that would allow a binary
upgrade alone to reject or truncate provider output that Tier 1 would have
forwarded.

### 11.4 Production invariants

Operators MAY choose stricter production values after observing compatibility.

Recommended production sequence:

1. Set `catalog_path` and observe Pillar A status.
2. Set `require_hash_verified: true` for models with enough verified capacity.
3. Deploy SPEC-001 v2.0 providers and observe encrypted-leg status.
4. Set `require_encrypted_leg: true` for pools where fallback is no longer
   needed.
5. Configure attestation roots and observe Pillar C status.
6. Set `require_attestation: true` only after unsupported-provider impact is
   acceptable.
7. Enable `behavioral_safety_enabled` in shadow/log-only mode if implemented,
   then enforcement mode.

Production operators MUST NOT use config to suppress disclosure of partial or
unsupported Tier-2 state.

### 11.5 Config lifecycle table

| Config key | Reload behavior | Effect on existing sessions |
|---|---|---|
| `catalog_path` / `catalog_public_key` | Startup only. Change requires restart. | N/A |
| `require_hash_verified` | Hot-reloadable (SIGHUP or equivalent). | Existing provider sessions are re-evaluated at next request; no mid-request ejection. |
| `require_encrypted_leg` | Hot-reloadable. | Existing unencrypted sessions are not immediately closed; re-evaluated at next provider reconnect or new session. |
| `encrypted_leg_aead` / rekey thresholds | Startup only. | N/A |
| `require_attestation` | Hot-reloadable. | Existing sessions are re-evaluated at next request. |
| `attestation_roots` / `attestation_formats` | Startup only. | N/A |
| `attestation_max_age_s` | Hot-reloadable. | Applies to next attestation validation. |
| `se_liveness_interval_s` | Reload updates the stored value, but the sweep ticker is constructed **once at startup** and never reset — the new interval does **NOT** take effect until coordinator restart (v0.4). | N/A until restart. |
| `se_liveness_timeout_s` / `se_liveness_max_failures` | Hot-reloadable (v0.4); read at each probe. | Applies to the next SE liveness probe. |
| `allow_mock_attestation` | Startup only (v0.4). | N/A — test/mock-root only. |
| `behavioral_safety_enabled` / Pillar D flags | Hot-reloadable. | Applied to next response chunk after reload completes. |
| `observe_enabled` | Hot-reloadable. | Applies to next provider registration or request. |
| `phase` | Computed/read-only; not operator-settable. | N/A |

Startup-only keys MUST cause coordinator startup failure if invalid.
Hot-reloadable keys log a reload event at INFO when changed.

---

## 12. Observability

Tier-2 enforcement events MUST emit structured audit logs. Logs MUST contain
enough context to reconstruct provider identity, request identity when
applicable, model identity, configured predicate, observed evidence, and final
decision.

### 12.1 Common fields

Every Tier-2 audit event MUST include:

- `event`
- `category`
- `severity`
- `request_id` when request-scoped
- `provider_id` when provider-scoped
- `assigned_id` when session-scoped
- `model_id` when model-scoped
- `tier2_phase`
- `pillar`
- `decision`
- `reason`
- `config_flag`
- `ts`

The event MUST NOT include:

- API keys,
- provider bearer tokens,
- raw buyer prompts,
- raw completion text,
- raw `account_id`,
- raw buyer conversation tag,
- `routing_internal.conversation_key`,
- ECDH private keys for coordinator or provider,
- X25519 shared secrets and HKDF-derived PRKs or OKMs,
- AEAD session keys and per-frame nonces beyond the key ID (`kid`),
- raw attestation token bytes or JWS body,
- raw attestation challenge bytes outside the challenge exchange,
- unredacted trust-root certificate material or private signing keys.

The `kid` value derived from the key transcript hash is permitted. A
`challenge_id` value is permitted when it is a short coordinator-assigned
identifier or the first 8 bytes of the challenge base64url-encoded.

### 12.2 Pillar A events

Pillar A MUST log:

- `model_hash_verified`
- `model_hash_mismatch`
- `model_hash_invalid`
- `catalog_signature_invalid`
- `catalog_load_failed`
- `hash_required_provider_excluded`

### 12.3 Pillar B events

Pillar B MUST log:

- `encrypted_leg_negotiated`
- `encrypted_leg_fallback`
- `encrypted_leg_required_provider_excluded`
- `key_exchange_failed`
- `aead_decrypt_failed`
- `aead_rekey`
- `encrypted_leg_session_closed`
- `coordinator_restart_session_invalidated`

### 12.4 Pillar C events

Pillar C MUST log:

- `attestation_valid`
- `attestation_failed`
- `attestation_stale`
- `attestation_unsupported`
- `attestation_required_provider_excluded`
- `attestation_root_missing`

### 12.5 Pillar D events

Pillar D MUST log:

- `oversized_completion_truncated`
- `output_encoding_rejected`
- `response_time_anomaly`
- `behavioral_safety_disabled_shadow_hit` when a shadow mode exists. Optional
  event; only emitted if the implementation provides a shadow mode, which is
  out of normative scope for v0.3.

### 12.6 Metrics

The coordinator SHOULD expose counters or metrics for:

- provider/model hash status counts,
- encrypted-leg capable session count,
- encrypted-leg required exclusions,
- attested/unsupported/failed provider counts,
- Pillar D truncation count,
- Pillar D encoding rejection count,
- TTFT anomaly count,
- `/v1/models` disclosure partial-state count.

---

## 13. Tier-2 disclosure update protocol

SPEC-006 §5.3.1 requires a top-level `tier1_disclosure` block and forbids
operator override. SPEC-008 extends that block to reflect actual Tier-2
enforcement state.

### 13.1 Non-operator-overrideable rule

The disclosure update MUST be automatic.

Operators MUST NOT configure the gateway or coordinator to claim stronger
Tier-2 state than enforcement evidence supports.

Operators MUST NOT suppress partial-pool state.

### 13.2 Required additive fields

The disclosure block MUST preserve existing SPEC-006 fields and add Tier-2
detail.

These additive fields appear only when §4.3 permits Tier-2 response changes.
With default config, the **coordinator's own** `/v1/models` disclosure block MUST remain
byte-identical to the SPEC-006 Tier-1 baseline. **This byte-identity is a coordinator-surface
property only** — the buyer-visible **gateway** disclosure activates on `/internal/routing`
pool evidence (any `StateReady` provider → non-`none` attestation state) independent of
coordinator `ConfigActive`, so it is **not** byte-identical at defaults (§4.3, §13.3). A
reimplementer MUST NOT treat "default config" as guaranteeing an unchanged buyer-visible
attestation surface through the gateway.

Default-config **coordinator** render - byte-identical to SPEC-006 v0.8.1 baseline. No
Tier-2 keys present. `version` string unchanged.

```json
{
  "tier1_disclosure": {
    "version": "v0.8",
    "plaintext_to_provider": true,
    "model_identity": "provider_reported",
    "hardware_attestation": "none",
    "tier2_milestone": "future",
    "sticky_affinity": {
      "enabled": false,
      "ttl_seconds": 0,
      "description": "Sticky affinity is disabled; related requests are not preferentially routed to the same provider."
    }
  }
}
```

Active-state render - only when §4.3 permits Tier-2 response changes:
`catalog_path` is non-empty, any `require_*` key is true,
`behavioral_safety_enabled: true`, or `observe_enabled: true`. `version`
string bumps to reflect active Tier-2 state.

```json
{
  "tier1_disclosure": {
    "version": "v0.8+tier2-v0.2",
    "plaintext_to_provider": true,
    "model_identity": "provider_reported",
    "hardware_attestation": "none",
    "tier2_milestone": "future",
    "sticky_affinity": {
      "enabled": false,
      "ttl_seconds": 0,
      "description": "Sticky affinity is disabled; related requests are not preferentially routed to the same provider."
    },
    "model_hash_verified": "none",
    "provider_leg_encryption": "none",
    "untrusted_provider_safety": "none",
    "tier2": {
      "phase": 0,
      "model_hash": {
        "state": "none",
        "verified_provider_count": 0,
        "uncatalogued_provider_count": 0,
        "mixed": false
      },
      "encrypted_leg": {
        "state": "none",
        "encrypted_provider_count": 0,
        "unencrypted_provider_count": 0,
        "mixed": false,
        "scope": "coordinator_to_provider_only"
      },
      "attestation": {
        "state": "none",
        "attested_provider_count": 0,
        "unsupported_provider_count": 0,
        "mixed": false
      },
      "behavioral_safety": {
        "state": "none",
        "size_cap": false,
        "encoding_validation": false,
        "ttft_anomaly_logging": false
      }
    }
  }
}
```

`version` MUST remain `"v0.8"` unless §4.3 permits Tier-2 response changes.

`tier2.phase` in the disclosure response is computed from active pillar state.
It is not operator-settable and does not appear in `coordinator.yaml`.

Allowed computed values are:

- `0`: no Tier-2 pillar is active (`catalog_path` empty, no observed **Pillar A
  model-hash** provider evidence, all `require_*` false, and
  `behavioral_safety_enabled: false`). Only Pillar A model-hash pool evidence can lift
  phase off `0` under `observe_enabled`; encrypted-leg and attestation pool evidence do
  **not** (see the pool-evidence-scope note below), so a default-config pool with ready
  encrypted/SE-attested providers still computes phase `0`. A default-config deployment
  also has `observe_enabled: false`.
- `1`: Pillar A is active (`catalog_path` non-empty or
  `require_hash_verified: true`, or provider `model_hash` evidence exists
  while `observe_enabled: true`), and Pillars B/C are not active.
- `2`: Pillar B or C is active — **shipped: driven by config only**,
  `require_encrypted_leg: true` or `require_attestation: true` (`internal/tier2`
  `PhaseForConfig…`). Pillar A may or may not be active.
- `3`: Pillar D is active (`behavioral_safety_enabled: true`) and Pillar B or
  C is also active. If Pillar A is also active, phase is still `3`.
- `"mixed"`: Pillar D is active but Pillars B/C are not active, meaning the
  operator deployed Phase 3 independently before Phase 2.

**Pool-evidence scope (shipped, v0.4).** The phase computation folds in **only Pillar A
model-hash** pool evidence (which can raise phase to `1` under `observe_enabled`).
Encrypted-leg and attestation **pool evidence do NOT affect phase** — only the
`require_encrypted_leg`/`require_attestation` flags do. So a default-config pool with
ready encrypted or SE-attested providers still computes phase `0`, even though the gateway
separately discloses `provider_leg_encryption`/`hardware_attestation` from that same pool
evidence (§13.3). This phase/disclosure skew is a shipped property, not a spec preference.

### 13.3 State values

For `model_hash_verified`, allowed values are:

- `"none"`: no active catalog or no providers report verified hashes.
- `"partial"`: at least one provider/model pair is verified and at least one
  routable provider/model pair is not verified.
- `"all"`: every currently routable provider/model pair is verified.

For `provider_leg_encryption`, allowed values are:

- `"none"`: no routable provider leg is Pillar-B encrypted.
- `"partial"`: some routable provider legs are encrypted and some are not.
- `"all"`: every currently routable provider leg is encrypted.

> **Trust overstatement — the `hardware_attestation` field name is a misnomer for the
> shipped SE path (v0.4, known gap).** The buyer-visible field is literally named
> `hardware_attestation`, but it is derived from the coordinator's attestation **status**
> aggregate (`attestationStateForProviders` → gateway `disclosure.HardwareAttestation`)
> **without consulting `attestation_tier`**. The shipped default-enabled attestation path
> is self-signed Secure-Enclave (`self_signed`, §7.3), which proves only software-key
> custody + session binding — **not** hardware. Consequently an all-`self_signed` pool of
> ordinary software P-256 keys is disclosed to buyers as **`hardware_attestation: "all"`**,
> a hardware-trust claim §7.3 explicitly denies. **Buyers and downstream specs MUST NOT
> read `hardware_attestation` as proof of trusted hardware** until it is gated on a
> genuinely hardware-rooted tier. Closing this — gating `hardware_attestation` on the
> `hardware` tier, renaming the field, or exposing tier-aware states/counts — is a
> forward, coordinated coordinator+gateway (`phase5-gateway`) code change, out of scope
> for this spec-only reconciliation; it is carried as a tracked follow-up.

For `hardware_attestation`, allowed values are (each reflects attestation **status**, not
strength — see the overstatement note above):

The value is computed by counting **every `StateReady` provider**
(`attestationStateForProviders`); a provider counts positive only when its status is
exactly `attested`, and **every other status — `unsupported`-format, `attestation_failed`,
`attestation_stale`, `not_required` (a tokenless optional v2 session), or the empty
legacy zero value — counts as negative**:

- `"none"`: **there are no `StateReady` providers at all** (empty ready pool). This is the
  *only* case that yields `none`.
- `"unsupported"`: at least one ready provider exists and **none** is `attested` — i.e.
  every ready provider is negative for any of the reasons above (not merely
  "unsupported-format"). A default-config, legacy/tokenless ready pool lands here.
- `"partial"`: some ready providers are `attested` and some are not.
- `"all"`: every ready provider is `attested`.

Derivation (columns count `StateReady` providers):

| StateReady providers | require_attestation | attested / negative split | hardware_attestation |
|---|---|---|---|
| none (empty ready pool) | any | — | `"none"` |
| ≥1, none attested (incl. tokenless/`not_required`/failed/stale/unsupported-format) | false | all negative | `"unsupported"` |
| ≥1, mixed | false | some attested, some negative | `"partial"` |
| ≥1, all attested | false | all attested | `"all"` |
| ≥1, all attested | true | all attested | `"all"` |
| ≥1, some negative | true | at least one attested | `"partial"`; else `"unsupported"` |

**Activation differs by surface (v0.4).** The **coordinator's own `/v1/models`** attaches
the `tier2` block only when `tier2.ConfigActive` is true (config-driven: a `require_*`
key, a catalog, `observe_enabled`, or `behavioral_safety_enabled` — so enabling Pillar D
alone attaches the whole block including attestation; §7.7) — so at default config it shows
nothing. The
**buyer-visible gateway disclosure**, however, is driven by the coordinator's
`/internal/routing` metadata, which computes the attestation aggregate from pool evidence
**regardless of config**, and the gateway treats **any non-`none` state — including
`unsupported`** — as active (`disclosure.go` `active()`). So the gateway surfaces
`hardware_attestation` **as soon as any `StateReady` provider exists at all**, even a
single legacy/tokenless one at otherwise-default coordinator config (which discloses
`hardware_attestation: "unsupported"`, §4.3) — attested evidence is **not** required to
activate it. `"none"` (suppression) applies only to an empty ready pool. (Note the
phase/attestation skew: `/internal/routing` phase is computed from config + model-hash
evidence and does **not** fold in encrypted-leg or attestation pool evidence, so a
default-config pool can surface a non-`none` `hardware_attestation` alongside phase `0`;
§13.2.)

For `untrusted_provider_safety`, allowed values are:

- `"none"`: Pillar D disabled.
- `"partial"`: only some Pillar D controls enabled.
- `"enforced"`: size cap, encoding validation, and TTFT anomaly logging are
  enabled. Size cap and encoding validation are hard-enforced; TTFT anomaly
  logging is a best-effort WARN signal that does not reject responses.

The exact mapping from Pillar D flags to these values is defined in §8.6.

### 13.4 Partial-pool example

If a model is served by four routable providers:

- two hash verified,
- one uncatalogued,
- one old provider with no `model_hash`,

then the model entry MUST have:

```json
{
  "hash_verified": false,
  "hash_verification": {
    "status": "partial",
    "verified_provider_count": 2,
    "uncatalogued_provider_count": 2
  }
}
```

The top-level disclosure MUST have:

```json
{
  "model_hash_verified": "partial",
  "tier2": {
    "model_hash": {
      "state": "partial",
      "verified_provider_count": 2,
      "uncatalogued_provider_count": 2,
      "mixed": true
    }
  }
}
```

It MUST NOT say `"all"`.

### 13.5 Plaintext disclosure remains true

`plaintext_to_provider` remains `true` even when Pillar B is fully enabled.

Reason: Pillar B encrypts the provider network leg, but the provider runtime
decrypts before inference and can technically observe prompts and outputs.

Buyer-facing language MUST make this distinction clear.

---

## 14. Acceptance criteria

All acceptance criteria are deterministic and MUST pass before SPEC-008 v0.4
is implementation-complete for the relevant phase.

### AC-T2-1: Survivability invariant (a)

Given sticky affinity enabled and two accounts using the same
`X-MacProvider-Conversation` tag, the gateway derives two different `conv:`
values because `account_id` remains in the HMAC message.

### AC-T2-2: Survivability invariant (b)

Given Pillar B enabled, captured provider WebSocket frames contain no
`routing_internal.conversation_key`, raw buyer conversation tag, or raw
`account_id` in cleartext AAD, ciphertext metadata, error messages, or
provider-visible logs.

### AC-T2-3: Survivability invariant (c)

`DELETE /v1/sticky` requires buyer authentication, purges only the caller's
account-scoped sticky entries, and no SPEC-001 provider message can purge or
list sticky entries.

### AC-T2-4: Survivability invariant (d)

Sticky TTL expiry occurs in coordinator state. A provider cannot extend TTL by
reporting readiness, attestation, encrypted-leg support, or cache state.

### AC-T2-5: Default Tier-1 behavior preservation

With every `tier2.*` key at its default value and no provider Tier-2 evidence,
no `catalog_path`, and a Tier-1 provider pool:

- provider selection is unchanged from Tier-1 behavior,
- the `tier1_disclosure` block in `/v1/models` contains exactly the SPEC-006
  v0.8.1 baseline keys - `version: "v0.8"`, `plaintext_to_provider`,
  `model_identity`, `hardware_attestation`, `tier2_milestone`,
  `sticky_affinity` - and none of the additive Tier-2 keys
  (`model_hash_verified`, `provider_leg_encryption`,
  `untrusted_provider_safety`, `tier2`),
- the `version` string is unchanged from `"v0.8"` unless §4.3 permits Tier-2
  response changes,
- no `hash_verified`, `hash_verification`, `attested`, `attestation`, or
  `tier2_session` fields appear in any response,
- no `T2.*` audit or log events are emitted (except the provider-triggered `T2.C`
  attestation diagnostic if a v2.0 provider volunteers a token, §4.3),
- `/v1/chat/completions` response bytes are identical to the Tier-1 baseline.

**Scope (v0.4).** This AC constrains the **coordinator's own** responses (`/v1/models`
`tier1_disclosure`, `/v1/chat/completions`), which are `ConfigActive`-gated and are
baseline-preserved at defaults. It does **not** cover the separate **gateway** buyer
disclosure, which is driven by the coordinator's `/internal/routing` metadata and — because
that metadata reports `hardware_attestation: "unsupported"` whenever any `StateReady`
provider exists (§13.3) — **does** change when a SPEC-008 gateway fronts even a Tier-1-only
pool. "Baseline preservation" here is a coordinator-surface property, not a whole-buyer-path
guarantee.

### AC-T2-6: Catalog signature rejection

Corrupting one byte in the active catalog body causes signature verification
failure and no corrupted catalog entry becomes active.

### AC-T2-7: Hash match routes correctly

A provider whose reported `model_hash` matches the active catalog is
`hash_verified` and remains routable.

### AC-T2-8: Hash mismatch rejects per model

A provider whose reported `model_hash` mismatches the catalog is excluded for
that model and emits `T2.A model_hash_mismatch`.

### AC-T2-9: Uncatalogued provider routes by default

An old provider with no `model_hash` routes when
`tier2.require_hash_verified: false`. When Pillar A observation is active, it
is represented as `"uncatalogued"` in `/v1/models`.

### AC-T2-10: Hash-required routing filter

With `tier2.require_hash_verified: true`, uncatalogued providers are excluded
and the buyer receives `503 tier2_hash_verified_required` if no verified
provider remains.

### AC-T2-11: Pillar B key exchange

A v2 provider and coordinator negotiate X25519 keys, derive matching AEAD
test vectors, and report `encrypted_leg.enabled: true`.

### AC-T2-12: Request encryption before WS crossing

With Pillar B enabled, captured `inference_request` provider WebSocket frames
contain encrypted `enc.ciphertext` and no cleartext prompt bytes.

### AC-T2-13: Response encryption before WS crossing

With Pillar B enabled, captured `inference_response_chunk` provider WebSocket
frames contain encrypted `enc.ciphertext` and no cleartext completion bytes.

### AC-T2-14: Encrypted-leg fallback

With `tier2.require_encrypted_leg: false`, an old provider without Pillar B
support remains routable. When Pillar B observation is active, disclosure
reports unencrypted or partial state.

### AC-T2-15: Encrypted-leg required rejection

With `tier2.require_encrypted_leg: true`, old providers without Pillar B
support are excluded and the buyer receives `503 tier2_encrypted_leg_required`
when no encrypted provider remains.

### AC-T2-16: Valid attestation propagates

Given a valid attestation token over the coordinator challenge **and Pillar C
disclosure active on the coordinator `/v1/models` surface** (`tier2.ConfigActive`, §7.7),
the provider is marked `attested`, coordinator `/v1/models` increments
`attested_provider_count`, and `T2.C attestation_valid` is logged. When attestation is
volunteered while all Tier-2 activation flags are at defaults, verification and the `T2.C`
log still occur but the coordinator `/v1/models` `tier2` block is omitted (the gateway
disclosure still reflects the provider per §13.3).

### AC-T2-17: Invalid attestation rejects when required

With `tier2.require_attestation: true`, an invalid or stale attestation token
excludes the provider and returns `503 tier2_attestation_required` if no
attested provider remains.

### AC-T2-18: Unsupported attestation routes by default

With `tier2.require_attestation: false`, an old provider routes and
preserves Tier-1 default behavior. When Pillar C disclosure is active, and every
counted (`StateReady`) provider is non-attested, `/v1/models` reports
`tier2.attestation.state: "unsupported"` (with `mixed: false`) — there is no per-model
`attested` field on this surface (§7.7).

### AC-T2-19: Pillar D exact ASCII byte cap

With Pillar D enabled and cap 32 bytes, a provider emitting 64 ASCII
completion bytes causes exactly 32 completion bytes to be forwarded and
`T2.D oversized_completion_truncated` to be logged.

### AC-T2-20: Pillar D malformed encoding rejection

With Pillar D enabled, invalid UTF-8 in a provider completion is rejected with
`tier2_output_encoding_invalid` before buyer commit or a streaming error event
after buyer commit.

### AC-T2-21: Pillar D response-time anomaly

Given `behavioral_safety_enabled: true`, `response_time_anomaly_enabled: true`,
`response_time_anomaly_factor: 5`, `response_time_anomaly_min_ms: 0`, and a
provider baseline `model_load_time_ms: 1000`, a provider response with TTFT
5001 ms logs `T2.D response_time_anomaly` at WARN without rejecting solely for
that reason. `response_time_anomaly_min_ms: 0` disables the minimum floor and
is suitable for acceptance testing; production deployments MAY set a higher
floor to reduce noise.

### AC-T2-22: Disclosure Phase 1 transition

After one provider/model pair becomes hash verified and one remains
uncatalogued, `/v1/models tier1_disclosure.model_hash_verified` is `"partial"`
and model entry counts show both states.

### AC-T2-23: Disclosure non-override

No coordinator or gateway config can force `/v1/models` to report `"all"` for
a pillar when current provider evidence is mixed, unsupported, failed, or
absent.

### AC-T2-24: Coordinator plaintext limitation

Pillar B documentation and `/v1/models` disclosure continue to state
`plaintext_to_provider: true` and do not claim buyer-to-provider end-to-end
encryption.

### AC-T2-25: Audit field hygiene

Tier-2 audit events include provider identity, request ID when applicable, and
reason, but do not include raw prompts, completions, API keys, account IDs,
buyer conversation tags, `conv:` values, ECDH private keys, shared secrets,
HKDF keys, AEAD keys, raw attestation token bytes, or raw challenge bytes.

### AC-T2-26: Hard-pin predicate preservation

With a buyer hard-pin to a provider that fails an enabled Tier-2 predicate, the
coordinator returns `tier2_hard_pin_predicate_failed` for that provider and
does not route to a different provider.

---

## 15. Audit categories

SPEC-008 inherits SPEC-002's audit namespace and adds Tier-2 categories.

### 15.1 T2.A — Model hash events

Condition:

- catalog load, verification, provider hash comparison, or hash-required
  routing predicate event.

Severity:

- INFO for `model_hash_verified`.
- WARN for `uncatalogued` when a catalog exists.
- MAJOR for `model_hash_mismatch`, `model_hash_invalid`, or
  `catalog_signature_invalid`.

Required fields:

- `provider_id`
- `assigned_id`
- `model_id`
- `reported_hash_prefix`
- `expected_hash_prefix`
- `catalog_id`
- `decision`
- `reason`

### 15.2 T2.B — Encrypted leg events

Condition:

- encrypted-leg negotiation, fallback, required exclusion, decryption failure,
  session closure, coordinator restart invalidation, or rekey.

Severity:

- INFO for negotiation, session closure, coordinator restart invalidation, and
  rekey.
- WARN for fallback when encrypted providers exist for the model.
- MAJOR for `aead_decrypt_failed` or required encrypted-leg exclusion.

Required fields:

- `provider_id`
- `assigned_id`
- `request_id` when request-scoped
- `alg`
- `kid`
- `decision`
- `reason`

Required fields MAY include `kid` but MUST NOT include shared secret, AEAD key,
or per-frame nonce.

### 15.3 T2.C — Attestation events

Condition:

- attestation validation, unsupported format, stale token, failed token, or
  required-attestation exclusion.

**Shipped (v0.4).** The emitter is `logAttestationEvent` (`internal/tier2/pillar_c.go`).

Shipped severity:

- **INFO** for valid attestation (`decision: allow`).
- **WARN** for every non-valid case — unsupported format, stale/expired, replayed
  (challenge mismatch), failed/invalid, provider-binding mismatch, and
  required-attestation exclusion. (The code does **not** emit a `MAJOR` level for these;
  the richer severity mapping below is a forward enhancement.)

Shipped T2.C-specific fields (the attestation event's own keys — the serialized log line
also carries zerolog's envelope: `level`, `message` = `"tier2 attestation event"`, and the
production logger's `time`):

- `event` (e.g. `attestation_valid`, `attestation_failed`, `attestation_stale`,
  `attestation_replay`, `provider_binding_mismatch`, `attestation_unsupported`,
  `attestation_root_missing`, `attestation_token_too_large`)
- `category` (always `"T2.C"`)
- `severity` (`INFO` | `WARN`)
- `provider_id`
- `pillar` (always `"C"`)
- `decision` (`allow` | `reject` | `observe`)
- `reason` (short machine token, e.g. `se_p256_attested`, `challenge_mismatch`,
  `missing_attestation_roots`)
- `config_flag` (the governing config key, e.g. `tier2.attestation_formats`)

`event`/`reason` preserve a coarse failed-vs-unsupported-vs-replay distinction, but the
per-session/trust context below is **not** currently available to operators. T2.C events
MUST NOT include raw attestation token bytes or JWS body.

**Deferred (forward enhancement).** A richer T2.C schema — adding `assigned_id`,
`attestation_format`, `trust_root_id`, `challenge_id` (a coordinator-assigned short ID,
not the raw 32-byte challenge), `attestation_status`, and `ram_tier_attested`, and
raising invalid/stale/replayed/binding-mismatch to `MAJOR` — has operational value and
SHOULD be implemented when attestation telemetry is prioritized. It is **not** a current
requirement; the shipped field set above is normative.

### 15.4 T2.D — Output safety events

Condition:

- response truncation, encoding rejection, response-time anomaly, or Pillar D
  shadow-mode finding only when shadow mode is implemented (out of normative
  scope for v0.3).

Severity:

- INFO for shadow-mode findings.
- WARN for TTFT anomaly or truncation.
- MAJOR for encoding rejection before buyer commit.

Required fields:

- `provider_id`
- `assigned_id`
- `request_id`
- `model_id`
- `stream`
- `configured_cap_bytes`
- `emitted_bytes`
- `validation_failure`
- `ttft_ms`
- `baseline_ms`
- `decision`
- `reason`

### 15.5 Audit discipline

Audits of SPEC-008 implementations MUST check:

- both default-off and enabled branches for every Tier-2 flag,
- mixed-pool disclosure,
- old-provider backward compatibility,
- hard-pin behavior under Tier-2 predicates,
- streaming and non-streaming relay behavior,
- survivability invariants (a)-(d),
- production copy for expectation drift.

Any claim that "Tier 2 is enabled" without specifying which pillars and what
fraction of the pool enforces them is a Category Y expectation-drift finding
inherited from SPEC-006.

---

## 16. Operator questions

1. Should the first Pillar C prototype require Managed Device Attestation
   enrollment for a small managed Mac pool, or should Mac Provider first ship
   an entitled packaged provider app so App Attest can be evaluated?
2. What source should be authoritative for RAM-tier attestation if Apple's
   selected attestation format does not expose RAM size directly?
3. Should a future SPEC-006 revision add server-side `/v1/models` query
   filtering for `hash_verified=true`, or is client-side filtering sufficient
   for v0.2?
4. Confirm the v0.2 default-off interpretation for Pillar D. The hard
   additive rule requires no `tier2.*` enforcement flag to default true, so
   encoding validation is opt-in rather than default-on.
5. Confirm that the operator-supplied trust-on-config model for
   `catalog_public_key` is acceptable, or specify a distribution/CA-backed
   alternative.
