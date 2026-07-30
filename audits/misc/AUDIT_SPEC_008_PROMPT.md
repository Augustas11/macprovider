# Audit prompt — SPEC-008 v0.1 cross-model audit

Operator-paste prompt to audit SPEC-008 v0.1 (`specs/SPEC-008-tier2.md`),
Mac Provider's normative Tier-2 trust layer spec.

**Cross-model pattern:** the spec was drafted by Codex (executing
`specs/BUILD_SPEC_008_PROMPT.md`). For independence, the audit runs in
**Codex CLI first**. After Codex round 1 lands, run the same prompt in
Claude as round 2; both audit reports go into `specs/SPEC-008-audit.md`
as separate sections, matching the SPEC-006 audit history pattern.

Expected duration: ~60-90 min per model. SPEC-008 is 2,327 lines covering
four security pillars across three implementation phases, plus a mandatory
survivability audit, wire annotations, and 26 ACs. Bias toward thoroughness
— this spec gates Phase 1 implementation (Pillar A coordinator work) and a
future SPEC-001 v2.0 BUILD session.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session (round 1) or Claude Code session (round 2)
rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-008 v0.1, Mac Provider's Tier-2 trust layer spec at
/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md.

You are NOT here to validate, rewrite, or extend the spec. Find problems,
report them with specific severity and location, and let the operator decide
fixes. The operator has read the spec; they need an independent second (or
third) opinion on what is missing, wrong, or under-specified.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-008-audit.md

Format: structured audit report. Findings grouped by category, each finding
tagged with severity (CRITICAL / MAJOR / MINOR / QUESTION) and location
(section number + line range if possible). Match the rigor of the prior
audit reports in this repo (specs/SPEC-006-audit.md). If you are running
as round 2 (Claude after Codex), APPEND your section to the existing file,
do not overwrite Codex's round 1.

## Severity definitions

- **CRITICAL** — would cause production failure, security incident, silent
  regression of Tier-1 behavior, violation of a locked F-1.5 survivability
  invariant, or scope creep into a locked upstream spec. Also: any Tier-2
  feature that defaults to true (would break live Tier-1 deployments on
  binary upgrade).
- **MAJOR** — would cause significant operator burden, predictable
  implementer confusion, or a v0.2 patch within first month of Phase 1
  deployment. Unjustified numeric thresholds, hand-wavy requirements, "TBD"s
  disguised as OQs, missing fallback semantics, ambiguous failure modes, wire
  annotation fields that are too vague for a SPEC-001 v2.0 BUILD session.
- **MINOR** — quality issues that don't block v0.1 but should be cleaned in
  v0.2. Naming inconsistencies, missing cross-references, underspecified edge
  cases that won't fire frequently.
- **QUESTION** — genuinely unresolved design choices the spec couldn't decide
  alone. Operator input required. Distinguish from §16 OQs the spec already
  names — those are not findings unless they hide a CRITICAL/MAJOR underneath.

## Critical constraints to honor while auditing

**1. SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-004 v0.3.1, and SPEC-006
v0.8.1 are locked.** SPEC-008 layers on top of them. Any SPEC-008 clause
that requires normative edits to any of these locked specs is a CRITICAL
finding ("scope creep across spec boundary"). Wire extensions for Pillars B
and C must appear in SPEC-008 §10 as annotations only, not as modifications
to SPEC-001.

**2. Additive-only / Tier-1 backward compat.** With every `tier2.*` key at
its default value, coordinator behavior MUST be byte-identical to the current
Tier-1 production behavior. Any `tier2.*` flag that defaults to `true` (or
any default that changes Tier-1 routing, logging, or API responses) is a
CRITICAL finding.

**3. F-1.5 survivability invariants are non-negotiable.** The four invariants
from SPEC-006 §F-1.5 — HMAC collision resistance, provider cannot derive
`conv:`, deletion is account-scoped and authenticated, TTL is
coordinator-enforced — MUST all be preserved. If SPEC-008's §2 resolves them
but a later section proposes a design that violates any one, that section is
CRITICAL.

**4. Coordinator sees plaintext.** Pillar B provides coordinator-to-provider
channel confidentiality only. The coordinator must always be able to read
buyer prompts to route and account. Any Pillar B design that removes the
coordinator's ability to read plaintext is a CRITICAL architectural violation.

**5. Tier-2 disclosure is non-operator-overrideable.** The `tier1_disclosure`
auto-update behavior in `/v1/models` inherits SPEC-006 §5's non-overrideable
constraint. Any config flag that lets an operator falsify the disclosure block
is a CRITICAL finding.

**6. Clean-room.** Do NOT inspect d-inference (layr-labs) source.
NOASSERTION license. Any SPEC-008 clause that appears to require d-inference
inspection is a CRITICAL finding.

**7. Locked design choices are read-only.** SPEC-008's §§1–2 restate the
BUILD prompt's locked architecture (four pillars, three phases, phase
ordering, survivability audit first). Any audit finding that recommends
changing a locked architectural choice is rejected unless the finding shows
structural incompatibility with another locked constraint.

## Required reading (in order, fully)

1. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md`
   v0.1 — the spec under audit. Read all 16 sections and all 26 ACs fully.
   Bias toward reading §2 (survivability audit), §§5-8 (Pillar specs), §10
   (SPEC-001 v2.0 annotations), §11 (config), §13 (disclosure protocol), and
   §14 (ACs) carefully — these encode the most precise commitments.

2. `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_008_PROMPT.md`
   — the BUILD prompt with the operator's locked architecture choices. The
   spec MUST match the "Locked architecture decisions" and "Hard rules" /
   "Anti-rules" sections of this prompt. Any deviation = MAJOR or CRITICAL
   depending on whether a locked decision was weakened or inverted.

3. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   v0.8.1 — focus on:
   - §1.6 (Tier-1 limitations — SPEC-008's normative baseline)
   - §F-1.5 (survivability clause, all four invariants — your §B audit)
   - §5 (`tier1_disclosure` block shape — SPEC-008 extends it in §13)
   - §13 (model identity caveat — SPEC-008 Pillar A closes this)
   - §19 (audit category Y / expectation drift — SPEC-008 must retire it)

4. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.3 — focus on:
   - §3 (provider state machine — Pillar A adds `hash_mismatch` rejection)
   - §5 (routing algorithm — Pillars A and B add new predicates)
   - §7.2 (provider WS auth — Pillars B+C extend the handshake)
   - §11 (audit categories — SPEC-008 inherits this namespace)

5. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on:
   - §3 (provider WS protocol — Pillars B+C require wire extensions here)
   - §6.2 (`/v1/models` shape — Pillar A adds `model_hash`; Pillar C adds
     `attestation_token`)
   Verify that SPEC-008 §10 annotations are precise enough for a future
   SPEC-001 v2.0 BUILD session to implement without additional design work.

6. `/Users/augstar/macprovider-poc/specs/SPEC-004-smart-router.md`
   v0.3.1 — focus on:
   - §2 (out-of-scope list — "Tier-2 attestation" is named there)
   - §4 (sticky-affinity semantics — SPEC-008 MUST NOT break these)
   Verify SPEC-008's survivability audit (§2) is consistent with SPEC-004's
   actual sticky implementation.

7. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   — read Entry 24 (2026-05-29) fully: the independent security audit,
   H-001/H-004/H-006 findings, and the SPEC-008 candidate scope. SPEC-008
   must close H-001, H-004, and H-006 without reopening previously-closed
   findings. Also read Entry 21 ("no premium positioning" rule extended here
   to "no privacy/attestation positioning until enforcement is live").

8. `/Users/augstar/macprovider-poc/specs/SPEC-006-audit.md` — your prior
   audit output, for tone and severity-bar continuity. Also review
   `specs/SPEC-001-audit.md` and `specs/SPEC-002-audit.md` for rigor bar.

## Audit categories — work through each

### Category A: Additive-only / default preservation (HIGHEST PRIORITY)

This is the category that gates whether SPEC-008 can be deployed without
touching the live Tier-1 coordinator configuration.

A.1  Walk every `tier2.*` config key in §11. For each, confirm the default
     value preserves Tier-1 behavior. Findings:
       - Any flag defaulting to `true` = CRITICAL (breaks live Tier-1)
       - Any flag with no default stated = MAJOR
       - Any flag whose default changes existing coordinator log format,
         routing behavior, or API response shape = CRITICAL

A.2  Verify the spec's "additive only" invariant is stated normatively (as a
     MUST), not just aspirationally. If it appears only in prose introduction
     without a MUST binding = MAJOR.

A.3  Verify §14 includes at least one AC (deterministically verifiable) that
     confirms all defaults leave Tier-1 behavior byte-identical. If absent or
     hand-wavy = MAJOR.

A.4  Verify the spec does NOT default `tier2.encoding_validation_enabled` to
     true without addressing whether it changes any existing Tier-1 log event
     (since encoding validation runs on existing relay path). If defaulting
     true silently adds new log entries to a Tier-1 deployment = MAJOR.

A.5  Verify that deploying SPEC-008 binaries to the live coordinator without
     any config change produces zero behavioral change — no new log lines,
     no changed routing decisions, no changed API response fields. If any
     section proposes behavior that activates without config change = CRITICAL.

### Category B: Survivability audit correctness (HIGHEST PRIORITY)

B.1  Walk each of the four F-1.5 invariants in SPEC-008 §2.1–2.4. For each:
       - Does the threat model name the correct adversary and attack vector?
       - Does the "Tier-1 mechanism" cite the correct SPEC-004 / SPEC-006
         section by number?
       - Does the "Normative preservation rule" contain a concrete MUST that
         would block a design that violates the invariant?
     A vague or circular resolution (e.g., "cleared because Tier 2 is
     additive") without a specific threat + mechanism = MAJOR per invariant.

B.2  Invariant (a) — HMAC collision resistance: verify §2.1's normative rule
     explicitly forbids using Pillar B session keys or AEAD nonces as inputs
     to sticky key derivation. If absent = CRITICAL.

B.3  Invariant (b) — provider cannot derive `conv:`: verify §2.2 explicitly
     states that Pillar B AEAD AAD MUST NOT include `conv:`, raw buyer tags,
     or raw `account_id`. If absent = CRITICAL.

B.4  Invariant (c) — deletion is account-scoped: verify §2.3 explicitly
     states providers MUST NOT receive any sticky lifecycle message type, and
     that SPEC-001 v2.0 candidate extensions MUST NOT add such a field.
     If absent or only "should" = MAJOR.

B.5  Invariant (d) — TTL is coordinator-enforced: verify §2.4 explicitly
     states that Pillar B session duration, AEAD re-key intervals,
     attestation lifetime, and model-hash status MUST NOT extend sticky TTL.
     If any one of these is missing from the exclusion list = MAJOR.

B.6  §2.5 conclusion: verify it references the four cleared invariants by
     letter (a)–(d) and states the requirement that any future SPEC-008
     revision reopening these properties must re-run §2. If the conclusion
     is aspirational rather than normative = MINOR.

B.7  Cross-check §2's Tier-1 mechanism descriptions against the actual SPEC-
     004 and SPEC-006 text you read. Any factual misstatement about how the
     current sticky implementation works = MAJOR (the survivability argument
     is only as good as its premise).

### Category C: Pillar A — Model catalog + hash verification

C.1  Catalog schema: does the spec define the catalog format precisely enough
     for an implementer to write a parser? Minimum: catalog_id, per-entry
     (model_id, sha256_hex, catalog_version, optional_signature). If schema
     is hand-wavy = MAJOR.

C.2  Hash algorithm binding: is SHA-256 over the model weight file the only
     hash? For large models, does the spec address incremental or chunked
     hashing? If large-model hashing is undefined = MAJOR.

C.3  Catalog signing: the spec requires a `tier2.catalog_public_key`. Is the
     signature scheme (algorithm, key format, signing scope) specified
     precisely enough to implement? If only "signed catalog" without algorithm
     = MAJOR.

C.4  Provider hash self-report threat model: the spec says Pillar A closes
     "honest-but-misconfigured" providers, not adversarial providers that lie.
     Verify this scope limitation is normative (not just advisory) in §5. If
     absent or weak = MAJOR (sets wrong operator expectations).

C.5  `hash_verified` field values: verify §5 defines all three states
     (`true`, `false`, `"uncatalogued"`) with normative behavior for each.
     Especially: does `false` (hash mismatch) route differently from
     `"uncatalogued"` (no hash provided)? If behavior is identical but
     disclosure is different, the distinction must be justified. If undefined
     = MAJOR.

C.6  Backward compat: old providers (no `model_hash` in registration) MUST
     be treated as `"uncatalogued"`, not rejected. Verify this is stated as
     a MUST. If only implied = MAJOR.

C.7  SPEC-001 v1.3 annotation: §5 should reference §10 for the exact
     optional `model_hash` field added to provider registration. If §5 makes
     wire claims not reflected in §10 = MAJOR. If §5 avoids wire detail but
     §10 is consistent, that's fine.

C.8  Routing predicate: verify §5 defines the `hash_verified` routing
     predicate as a hard filter when `tier2.require_hash_verified: true` and
     as a soft preference (not hard rejection) when false. If behavior under
     each flag value is undefined = MAJOR.

C.9  Rejection error: when a provider is rejected per-model for hash
     mismatch, does the spec define what the coordinator sends back to the
     buyer? If a mismatch empties the eligible pool, does the buyer get a
     503? What code/type? If undefined = MAJOR.

### Category D: Pillar B — Provider-leg encryption

D.1  AEAD cipher suite: verify the spec names AES-256-GCM as default and
     ChaCha20-Poly1305 as the operator-configurable alternative, and that the
     AEAD nonce construction (size, uniqueness per frame) is specified
     precisely. If nonce construction is hand-wavy = MAJOR.

D.2  Key exchange — X25519 ECDH: verify the ephemeral keypair lifecycle is
     precise: per-provider-session (not per-request), coordinator generates
     ephemeral keypair, provider publishes static pubkey in registration,
     KDF applied to shared secret. If per-request vs per-session is undefined
     = MAJOR. If KDF algorithm is unnamed = MAJOR.

D.3  Key derivation: what KDF? HKDF-SHA256? With what salt and info
     parameter? If undefined = MAJOR (implementers will diverge).

D.4  Re-key interval: does the spec define when/how the AEAD key rotates
     mid-session? If absent = MAJOR.

D.5  AAD (additional authenticated data): verify §6 specifies what fields
     go into the AEAD AAD for request frames and response frames. Missing AAD
     spec = MAJOR (AEAD without committed AAD is fragile).

D.6  Coordinator-sees-plaintext limitation: verify §6 contains a normative
     MUST NOT claiming buyer-to-provider E2E encryption. If absent or only
     advisory = MAJOR (per BUILD constraint).

D.7  Fallback behavior: with `tier2.require_encrypted_leg: false`, an old
     provider (no Pillar B support) MUST route normally. Verify the disclosure
     block correctly reflects `encrypted_leg: "partial"` or `"none"`. If
     fallback behavior is undefined = MAJOR.

D.8  Required-leg rejection: with `tier2.require_encrypted_leg: true`, verify
     the spec defines the exact error (status code, error type, error code)
     returned to the buyer when no encrypted provider is available. If absent
     = MAJOR.

D.9  Decryption failure handling: if the provider sends a ciphertext that
     fails AEAD authentication (tag mismatch), what does the coordinator do?
     Log and close WS? Route to different provider? If undefined = MAJOR.

D.10 Frame encapsulation: does §10 define the wire frame format for encrypted
     `inference_request` and `inference_response_chunk` precisely (field names,
     types, nesting)? Sufficient for a SPEC-001 v2.0 BUILD session to implement
     without additional design? If not = MAJOR.

D.11 Streaming: verify Pillar B applies per-chunk to streaming completions,
     not just non-streaming. If streaming handling is absent = MAJOR.

### Category E: Pillar C — Hardware attestation

E.1  Apple API selection: the spec must recommend App Attest or DeviceCheck
     and justify the choice. Verify the justification references the
     recommended API's actual capabilities (App Attest issues per-key
     assertion; DeviceCheck is per-device). If the choice is wrong or
     unjustified = MAJOR.

E.2  Coordinator CA validation flow: verify §7 describes the full validation
     chain — coordinator sends challenge, provider includes attestation token
     in registration, coordinator verifies against Apple's attestation CA or
     operator-configured root. The challenge-response mechanism (nonce in
     challenge, nonce in token) must prevent replay. If replay protection is
     absent = CRITICAL.

E.3  Attestation token lifetime: how long is a valid token good for before
     the coordinator requires re-attestation? Must be specified. If absent
     = MAJOR.

E.4  RAM-tier attestation: the spec notes in §16 that Apple's attestation
     format may not expose RAM size directly. Verify §7 addresses this
     limitation normatively (e.g., "RAM tier is provider-self-reported and
     treated as advisory until a binding Apple attestation path is identified").
     If the spec claims RAM-tier attestation without qualifying this gap
     = MAJOR.

E.5  `attested` field values: verify §7 defines `true`, `false`, and
     `"unsupported"` with behavior for each, matching the same pattern as
     Pillar A's `hash_verified` tristate. If any state is missing = MAJOR.

E.6  Required-attestation rejection: with `tier2.require_attestation: true`,
     verify the exact error (status code, type, code) is defined for the
     case where no attested provider remains. If absent = MAJOR.

E.7  SPEC-001 v2.0 annotation: verify §10 defines the `attestation_token`
     field in `auth_request` with type, maximum length, and encoding (base64?
     CBOR?). Precision check: can a SPEC-001 v2.0 BUILD session implement this
     without additional design decisions? If not = MAJOR.

E.8  Multi-provider pool: if some providers in a model's pool are attested and
     some are not, verify the spec defines routing behavior for each flag state
     (require/not-require) and that `/v1/models` reflects the partial state.
     If partial-pool attestation disclosure is absent = MAJOR.

### Category F: Pillar D — Untrusted-provider behavioral safety

F.1  Response size cap: verify §8 specifies the cap is enforced at the
     coordinator byte level on the relay stream (not at token level, not
     estimated). Exact enforcement point in the relay loop must be named. If
     "byte-level" is asserted without naming the relay code path = MAJOR.

F.2  Cap configuration: is `tier2.output_size_cap_bytes` the only cap lever,
     or does the spec also say the coordinator enforces `max_tokens` from the
     request? Verify the relationship between the two caps. If undefined = MAJOR.

F.3  Streaming cap: verify truncation applies per-chunk, not just at
     end-of-stream. If only end-of-stream = MAJOR (defeats the exfiltration
     threat model for streaming responses).

F.4  Encoding validation: verify §8 defines exactly which control characters
     are rejected (i.e., C0/C1 range outside normal JSON whitespace?) and
     whether this applies to the full completion or only to the JSON envelope
     fields. If boundary is vague = MAJOR.

F.5  Encoding rejection pre-commit: verify the spec handles both the
     pre-buyer-commit case (reject before any bytes forwarded) and the
     post-commit case (streaming error event mid-stream). If only one case is
     handled = MAJOR.

F.6  Response-time anomaly: TTFT threshold is "significantly exceeds
     `model_load_time` baseline." What is "significantly"? If not defined
     numerically or by a configurable factor = MAJOR.

F.7  Shadow mode: verify §8 specifies a shadow-mode or default-off behavior
     for Pillar D enforcement flags. If Pillar D enforcement activates without
     a named config flag, or if the spec is unclear whether `tier2.encoding_
     validation_enabled: true` is the default = CRITICAL (A.4 overlap).

F.8  Pillar D and hard-pin: verify that Pillar D's truncation and encoding
     checks apply even to hard-pin-selected providers, i.e., Pillar D is a
     coordinator output filter not a routing predicate. If Pillar D is
     incorrectly modeled as a routing filter = MAJOR.

### Category G: Phase roadmap and dependencies

G.1  Phase 1 prerequisites: verify §9 states that Phase 1 (Pillar A) can
     ship without any SPEC-001 wire change and is backward-compatible with
     all currently registered providers. If any Phase 1 requirement implies
     a wire change = CRITICAL.

G.2  Phase 2 prerequisites: verify §9 states Pillars B and C require
     SPEC-001 v2.0. Verify the spec says they ship together to avoid a
     two-step wire migration, and explains why. If the two-together rationale
     is absent = MINOR.

G.3  Phase 3 positioning: verify §9 states Pillar D can ship incrementally
     and is not hard-dependent on Phase 2. If Phase 3 is incorrectly gated
     on Phase 2 = MAJOR.

G.4  Config flag per phase: verify §9 (or §11) specifies which config flags
     gate each phase. If the phase-flag mapping is absent or ambiguous =
     MAJOR.

G.5  Disclosure transition per phase: verify §9 and §13 together specify
     what the `tier1_disclosure` block looks like after each phase transition.
     Phase 1 → hash_verified partial or full? Phase 2 → encrypted_leg appears?
     If per-phase disclosure state is undefined = MAJOR.

G.6  Phase estimate realism: the BUILD handback said Phase 1 is ~2-4 days;
     Phase 2 is ~7-14 days excluding Apple attestation setup; Phase 3 is ~3-6
     days. Check §9's estimates against the actual scope of the four pillars.
     Significant underestimation = QUESTION. This is an advisory check, not
     a MAJOR/CRITICAL finding.

### Category H: SPEC-001 v2.0 annotations precision

This is the section that must be precise enough for a future SPEC-001 v2.0
BUILD session. If any field is vague here, that BUILD session will make
undocumented design decisions.

H.1  Pillar B key exchange fields in `auth_request`:
       - Does §10 name all new fields (e.g., `ecdh_pubkey`, `enc_alg`)?
       - Type: bytes/base64/hex?
       - Required vs optional per protocol version?
       - Old providers omit → treated as Tier-1 (stated as MUST)?
     Missing any of these = MAJOR per field.

H.2  Pillar B fields in `inference_request`:
       - Does §10 name the encrypted payload envelope fields (e.g.,
         `enc.ciphertext`, `enc.nonce`, `enc.tag`)?
       - Clear enough to write a decoder? If not = MAJOR.

H.3  Pillar C attestation token field in `auth_request`:
       - Does §10 name the field, type, max length, encoding?
       - Is it in the same WS frame as the Pillar B key exchange, or a
         separate message? If separate, is the message ordering defined?
     If absent = MAJOR.

H.4  Backward compat rule: §10 must contain a MUST stating that providers
     omitting the new fields are treated as Tier-1-only. If absent = MAJOR.

H.5  Version negotiation: does §10 specify how the coordinator signals
     SPEC-001 v2.0 capability to the provider (e.g., in the welcome message
     or auth handshake)? If absent = MAJOR. Without version negotiation, old
     and new providers cannot coexist safely.

H.6  No locked spec edits: verify §10 does not propose normative changes to
     SPEC-001 v1.2.4 text. It must only annotate proposed v2.0 extensions.
     If §10 edits any locked SPEC-001 section = CRITICAL.

### Category I: Configuration completeness

I.1  Walk every new `tier2.*` key named anywhere in §§5-8 and §12 (audit
     events). Each must appear in §11 with a default, type, and one-line
     description. Missing entry in §11 = MAJOR per key.

I.2  Verify §11 contains at minimum these keys (as specified in BUILD prompt):
     `tier2.catalog_path`, `tier2.catalog_public_key`,
     `tier2.require_hash_verified`, `tier2.require_encrypted_leg`,
     `tier2.require_attestation`, `tier2.output_size_cap_bytes`,
     `tier2.encoding_validation_enabled`. Any missing = MAJOR.

I.3  Type precision: verify each key's type is specified (bool, string, int,
     bytes). "configurable" without a type = MINOR.

I.4  Hot-reload: does the spec address whether `tier2.*` flags are hot-
     reloadable (coordinator reads on startup only vs watches the config file)?
     If absent = MAJOR (operators need to know whether a config change requires
     a coordinator restart).

I.5  Interaction between flags: if `tier2.require_hash_verified: true` and
     `tier2.require_encrypted_leg: true` are both set, and a provider passes
     hash but not encryption, what happens? Verify conjunction semantics are
     specified. If undefined = MAJOR.

### Category J: Observability and audit categories

J.1  Verify §15 defines T2.A, T2.B, T2.C, and T2.D categories matching the
     four pillars. Each must specify: condition, severity levels, and required
     log fields. Missing any of the four categories = MAJOR.

J.2  Audit field hygiene: verify §15 (or §12) explicitly states that Tier-2
     audit events MUST NOT include raw prompts, completions, API keys, account
     IDs, buyer conversation tags, or `conv:` values. If absent = CRITICAL.

J.3  Audit field hygiene AC: verify §14 contains AC-T2-25 or equivalent that
     tests this constraint. If absent = MAJOR.

J.4  Severity calibration: verify audit severity levels in §15 are consistent
     with the threat model. A `model_hash_mismatch` at INFO would be a MAJOR
     finding; it should be MAJOR or CRITICAL in the audit log. Review each
     severity assignment.

J.5  Coordinator restart survivability: if the coordinator restarts, do
     in-flight Pillar B sessions lose their keys? What happens to in-flight
     requests? If undefined = MAJOR.

J.6  Audit category namespace: §15 says SPEC-008 inherits SPEC-002's audit
     namespace. Verify that T2.A/B/C/D do not conflict with any existing
     SPEC-002 audit category names. If there is a namespace collision = MAJOR.

### Category K: Tier-2 disclosure update protocol

K.1  Partial-pool case: verify §13 addresses the case where a model is served
     by a mixed pool (some providers hash-verified, some uncatalogued). Does
     the spec define the `tier1_disclosure` field values for this case
     precisely? "partial" must be a named state, not inferred. If absent
     = MAJOR.

K.2  Non-operator-overrideable: verify §13 contains a normative MUST that the
     `tier1_disclosure` update cannot be overridden by coordinator config. If
     only advisory = CRITICAL (per BUILD constraint).

K.3  Phase transition: verify §13 states exactly what disclosure fields change
     on each phase transition (Phase 1 / Phase 2 / Phase 3). If per-phase
     disclosure state transitions are undefined = MAJOR.

K.4  Buyer-observable granularity: verify §13 defines disclosure at model-
     and-provider granularity, not just at pool level. A pool that is 50%
     verified must not report as 100% verified. The per-entry vs per-pool
     representation must be specified. If absent = MAJOR.

K.5  `/v1/models` response shape change: verify that adding new fields to the
     `tier1_disclosure` block is backward compatible with SPEC-006 §5's locked
     endpoint contract. If SPEC-008 §13 proposes breaking changes to the
     `/v1/models` shape = CRITICAL.

### Category L: Acceptance criteria quality

L.1  Count: verify there are exactly 26 ACs (AC-T2-1 through AC-T2-26) per
     the spec's claim. If the count mismatches = MINOR.

L.2  Determinism: each AC must have a deterministic verification step
     (test setup, action, observable outcome). If any AC is hand-wavy
     ("the system should work correctly") = MAJOR per AC.

L.3  Required coverage — verify ACs exist for ALL of:
       - Survivability invariants (a)–(d) still hold end-to-end
       - Pillar A: hash match routes, hash mismatch rejects per-model,
         uncatalogued routes with `hash_verified: false`
       - Pillar A: `require_hash_verified: true` empties pool → 503
       - Pillar B: key exchange completes, payload encrypted in WS frame
       - Pillar B: fallback when `require_encrypted_leg: false`
       - Pillar B: rejection when `require_encrypted_leg: true` + no encrypted
         provider
       - Pillar C: valid attestation → `attested: true` in `/v1/models`
       - Pillar C: invalid attestation → rejected when required
       - Pillar C: unsupported attestation → routes when not required
       - Pillar D: oversized completion truncated at exact byte cap
       - Pillar D: invalid UTF-8 rejected pre-commit
       - Pillar D: TTFT anomaly logged without rejection
       - All defaults leave Tier-1 behavior byte-identical
       - Disclosure block updates on Phase 1 transition
       - Disclosure non-override (operator cannot force `"all"` for partial pool)
       - Coordinator plaintext limitation stated in `/v1/models` disclosure
       - Audit field hygiene (no sensitive data in Tier-2 audit events)
       - Hard-pin + Tier-2 predicate interaction
     Missing coverage for any of the above = MAJOR.

L.4  Quantified thresholds: where an AC specifies "N bytes" or "N ms,"
     the value must match the config key it corresponds to (e.g., AC-T2-19
     uses 32 bytes and 64 bytes to test the cap). If any AC's threshold is
     inconsistent with the spec's defined config key behavior = MAJOR.

L.5  Hard-pin AC: verify AC-T2-26 (hard-pin + Tier-2 predicate) specifies
     that the coordinator returns the failure for the hard-pinned provider
     and does NOT silently route to a different provider. If it only tests
     the routing outcome without asserting no-reroute = MINOR.

### Category M: Cross-spec coherence

M.1  SPEC-004 sticky-affinity: verify SPEC-008 does not inadvertently create
     a provider-side sticky state path. Any Pillar B or C field that gives the
     provider information about routing decisions = MAJOR.

M.2  SPEC-002 provider state machine: Pillar A adds `hash_mismatch` as a new
     rejection reason for individual models. Verify SPEC-008 §5 is consistent
     with SPEC-002 §3's state machine — specifically that a provider rejected
     per-model for hash mismatch is still able to register and serve other
     models. If SPEC-008 implies full-provider rejection rather than per-model
     = MAJOR.

M.3  SPEC-002 routing: Pillars A and B add new routing predicates. Verify
     SPEC-008 specifies where in SPEC-002's routing algorithm these predicates
     apply (after pool selection? before warm-up gate? after breaker check?).
     If unspecified = MAJOR.

M.4  SPEC-006 `/v1/models` shape: verify SPEC-008's proposed additions to
     `tier1_disclosure` are additive (new fields only) and do not rename or
     remove existing SPEC-006 §5 fields. Any removal or rename = CRITICAL.

M.5  SPEC-006 Tier-1 disclosure §1.6: SPEC-008 must not undermine the
     normative limitations in §1.6 by claiming Tier-2 capabilities before
     pillars are live. Verify §1.3 / §1.4 of SPEC-008 clearly states that
     §1.6 remains authoritative until a pillar is deployed and verified.
     If absent = MAJOR.

M.6  SPEC-001 v1.2.4 backward compat: old providers (on v1.2.4 binary) must
     work against a SPEC-008 coordinator without modification. Verify SPEC-008
     §§5-8 each confirm this per pillar. Missing per-pillar backward compat
     statement = MAJOR per pillar.

M.7  Decision log Entry 24: verify SPEC-008 closes H-001 (expectation drift),
     H-004 (model identity unverified), and H-006 (sticky cache + no trust)
     with normative MUST clauses. If any finding is only addressed in a
     "SHOULD" or prose observation = MAJOR per finding.

### Category N: Security properties

N.1  Key material in audit logs: verify §12 and §15 explicitly forbid logging
     ECDH private keys, AEAD keys, derived shared secrets, or raw attestation
     tokens. If absent = CRITICAL.

N.2  Key material in error messages: verify §§6-7 forbid returning key
     material or attestation tokens in buyer-visible error responses or
     coordinator-to-provider close reasons. If absent = MAJOR.

N.3  Attestation replay protection: verify §7 specifies that the coordinator
     generates a fresh challenge nonce per attestation attempt and that the
     coordinator validates the nonce is present in the attestation token.
     If absent = CRITICAL.

N.4  Catalog signature: if the coordinator catalog is operator-supplied, a
     compromised operator could supply a catalog with wrong hashes to whitelist
     malicious models. Verify §5 addresses the trust model for the catalog
     itself. If operator-supplied catalog is trusted without a trust chain
     = QUESTION (may be acceptable given coordinator trust model, but must
     be called out).

N.5  AEAD nonce reuse: verify §6 specifies that nonces are never reused
     within a session. If nonce uniqueness is not addressed = CRITICAL.

N.6  Channel downgrade attack: a malicious provider could pretend not to
     support Pillar B (omit ECDH pubkey) to force cleartext routing. Verify
     §6 addresses this when `tier2.require_encrypted_leg: false` — what is
     the coordinator's obligation to log the downgrade? If a silent fallback
     with no audit event is allowed = MAJOR.

N.7  Attestation pinning: if a provider's attestation token is valid, can a
     different provider replay it? Verify §7 binds the token to the specific
     provider connection (e.g., via provider_id or connection challenge). If
     absent = CRITICAL.

N.8  Hash mismatch information leak: when the coordinator rejects a provider
     for a hash mismatch, does the rejection message reveal the expected hash?
     If yes = MAJOR (exposes catalog contents to the provider).

## Output format

Produce `/Users/augstar/macprovider-poc/specs/SPEC-008-audit.md` with
this structure:

```
# SPEC-008 v0.1 audit report

## Round 1 (Codex, 2026-MM-DDTHH:MM:SSZ)

### Summary
- N CRITICAL findings
- M MAJOR findings
- K MINOR findings
- L QUESTIONS

### CRITICAL findings

C1. [Title]
    **Location:** § X.Y, line range
    **Finding:** [description]
    **Why it matters:** [impact]
    **Suggested fix:** [if obvious; "operator decision" if not]

(repeat for each critical finding)

### MAJOR findings
M1. ...

### MINOR findings
m1. ...

### Operator questions surfaced
q1. ...

### Verdict
- READY TO LOCK (zero CRITICAL, zero MAJOR-blocking — Phase 1 BUILD can proceed)
- READY WITH FIX PASS (CRITICALs all closable in narrow FIX_SPEC_008_V0_2 prompt)
- ANOTHER DESIGN ROUND NEEDED (architectural CRITICALs, fix won't suffice)

## Round 2 (Claude, 2026-MM-DDTHH:MM:SSZ)
(appended in round 2; do NOT overwrite round 1)

[same structure]

### Round 2 notes on Round 1
- Findings I confirm
- Findings I disagree with (and why)
- New findings round 1 missed
- Verdict (mine, independent of round 1)
```

## Self-verification before declaring audit complete

- [ ] Read every section of SPEC-008 v0.1 (all 16 sections, all 26 ACs).
- [ ] Compared SPEC-008 §§1-2 and §§5-8 against BUILD prompt's locked
      architecture. Drift documented.
- [ ] Walked each Category A through N. Even if no findings, noted
      "no findings" explicitly.
- [ ] Severity for each finding chosen against the definitions above,
      not subjectively.
- [ ] Location (section number, line range when applicable) on every
      finding.
- [ ] Suggested fix for CRITICAL findings (operator may accept or reject;
      the suggestion is data, not prescription).
- [ ] Verdict (READY / READY+FIX / DESIGN ROUND NEEDED) at end.
- [ ] Checked §10 wire annotations for SPEC-001 v2.0 precision — a BUILD
      session reading only §10 should be able to implement without asking
      design questions.
- [ ] Checked §11 config defaults — every new key defaults to Tier-1-no-
      change behavior.
- [ ] Checked §13 partial-pool disclosure case explicitly.
- [ ] Checked §15 audit field hygiene for sensitive data exposure.

When done, print a 200-word handback summary:
- finding count by severity
- top 3 most impactful findings
- the verdict + one-sentence rationale

Then stop. Do NOT begin drafting a fix prompt. The operator decides whether
to fix, retry the audit, or escalate to a design round.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~30 min per round):

1. Read the Codex round 1 findings start to finish.
2. For each CRITICAL: confirm whether it's real or a false alarm (misread of
   the spec).
3. For each MAJOR: same triage.
4. After round 1: run the same prompt in Claude for round 2. Claude appends
   to the same file.
5. After round 2: cross-reference. Findings both audits agree on are high-
   confidence. Findings only one audit raised need operator triage.

## How to use the audit output

- **READY TO LOCK from both rounds**: spec locks at v0.1. Proceed to Phase 1
  implementation: `BUILD_SPEC_008_PHASE1_PROMPT.md` (Pillar A — coordinator
  catalog service, no SPEC-001 wire change).
- **READY WITH FIX PASS**: draft `FIX_SPEC_008_V0_2_PROMPT.md` covering only
  CRITICAL findings. Run, audit again (round 3 + 4 if needed). Lock at v0.2.
- **ANOTHER DESIGN ROUND NEEDED**: re-open the design exploration. One or
  more pillar's architectural choices may be wrong or under-specified.

## Phase unlock sequence after spec lock

1. Phase 1 BUILD: `BUILD_SPEC_008_PHASE1_PROMPT.md` — Pillar A only,
   coordinator-only, no SPEC-001 wire change. Backward compatible.
2. Phase 2 SPEC: `BUILD_SPEC_001_V2_0_PROMPT.md` — implement §10 wire
   extensions for Pillars B+C. Requires a SPEC-001 v2.0 session.
3. Phase 2 BUILD: `BUILD_SPEC_008_PHASE2_PROMPT.md` — Pillars B+C together,
   after SPEC-001 v2.0 is locked.
4. Phase 3 BUILD: `BUILD_SPEC_008_PHASE3_PROMPT.md` — Pillar D, incremental.

## Historic note

SPEC-006 audit round 1 surfaced findings that led to a FIX_SPEC_006_V0_2 pass
before the spec locked. Expect SPEC-008 to follow a similar pattern — the
Pillar B key exchange and Pillar C attestation sections are the highest-
complexity areas and most likely sources of MAJOR-or-above findings.
```
