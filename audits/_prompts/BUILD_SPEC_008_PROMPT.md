# Build prompt — SPEC-008 (Tier-2 Trust)

Operator-paste prompt that drafts **SPEC-008 — Tier-2 Trust Layer**: the
normative specification for Mac Provider's second trust tier, covering model
identity verification, provider-leg encryption, hardware attestation, and
untrusted-provider safety.

SPEC-008 does **not exist yet** as a normative document. It was filed as a
candidate at Decision log Entry 24 (2026-05-29) after an independent security
audit surfaced H-001, H-004, and H-006. This BUILD prompt is the first writing
pass.

Run in **Codex** or **Claude Code**. Expected duration: ~4-6 hours for a
thorough first draft. Output is `specs/SPEC-008-tier2.md` v0.1. No code
is written in this session; a separate AUDIT and then BUILD_PHASE_IMPL prompt
will follow after the spec is locked.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are writing SPEC-008 v0.1 — the normative specification for Mac Provider's
Tier-2 trust layer. Tier 2 is the planned hardening layer above the current
Tier 1 cooperative network. Your job is to produce a rigorous spec document
at the same standard as SPEC-002 v1.3.3 and SPEC-006 v0.8.1: numbered
sections, RFC 2119 normative language (MUST/SHOULD/MAY), deterministic
acceptance criteria, and a complete change log header.

Output location:
  /Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md

Target length: ~1000-1800 lines. This is a design-first spec; v0.1 locks
the architecture and normative requirements. A separate BUILD_IMPL prompt
will drive the implementation work AFTER audit and operator lock.

You are NOT writing code in this pass. You are writing the spec.

## Context: why SPEC-008 exists

The 2026-05-29 independent security audit (Decision log Entry 24) found:
- H-001: Privacy/trust claims exceed Tier 1 enforcement (prompts go plaintext
  to provider; "decentralized, no big cloud" language implies provider-private
  inference — false at Tier 1).
- H-004: Model identity is provider-reported, not cryptographically verified.
  An untrusted provider could advertise a model it is not actually running.
- H-006: Sticky caching (SPEC-006) shipped before Tier-2 trust controls creates
  a larger privacy surface than raw request forwarding.

SPEC-006 v0.8.1 closed the *disclosure* surface (Tier 1 limitations are now
normative §1.6; the product makes no privacy/attestation/integrity claims).
SPEC-008 closes the *enforcement* surface: it actually delivers the capabilities
that Tier 1 deliberately deferred.

The auditor's framing, adopted verbatim as SPEC-008's north-star mission:
> "MacProvider does not appear to contain a critical architectural flaw if its
> current Tier 1 system is positioned as a cooperative, provisional provider
> network with no claim of provider-private prompts, hardware attestation, or
> malicious-provider resistance. The high-severity risk is expectation drift."
> SPEC-008 turns the roadmap item into enforcement reality.

## Locked corpus (do NOT modify spec text of any of these)

  SPEC-001 v1.2.4  — phase3-binary provider WS protocol (locked; Tier-2
                     MAY require a v2.0 wire extension — spec that extension
                     here, but do NOT edit SPEC-001 in this session)
  SPEC-002 v1.3.3  — coordinator router
  SPEC-003 v0.7    — open onboarding / distribution
  SPEC-004 v0.3.1  — smart router (sticky affinity, model classes, retry)
  SPEC-006 v0.8.1  — buyer API gateway (Tier 1 disclosure language is
                     the normative baseline SPEC-008 builds on)

## First obligation: Tier-2 survivability audit (mandatory §2)

Before introducing any new Tier-2 capability, SPEC-008 MUST audit that the
current Tier 1 corpus survives Tier 2 unbroken. SPEC-006 §F-1.5 (the
survivability clause) defined four invariants a future SPEC-008 audit MUST
verify. Your §2 MUST state each invariant and resolve it with a normative
finding:

  (a) `account_id` remains inside the HMAC message and cross-account `conv:`
      collision remains structurally impossible — even after provider-leg
      encryption or channel-level re-keying.
  (b) The `conv:` value is NOT derivable by the provider from any observable
      traffic — even under Tier-2 where the coordinator-to-provider channel
      may change.
  (c) `DELETE /v1/sticky` remains account-scoped and authenticated — Tier-2
      MUST NOT introduce a provider-visible sticky lifecycle API.
  (d) TTL expiry remains coordinator-enforced (not provider-self-reported) —
      Tier-2 encryption does NOT shift TTL authority to the provider.

For each invariant: state the threat model, the Tier-1 mechanism that
currently satisfies it, and the normative MUST that Tier-2 engineering MUST
obey to preserve it. If any invariant would be broken by a proposed Tier-2
design, that design MUST be rejected or restructured before §2 can clear.

This section is the survivability certificate. It must be written before the
pillars (§4+) can be accepted as non-regressive.

## Locked architecture decisions (do not relitigate)

### Four pillars, three phases

SPEC-008 is structured as four pillars across three implementation phases.
Phases respect the hard rule that Pillar A ships first (coordinator-only, no
SPEC-001 wire change), Pillars B+C ship together (require SPEC-001 v2.0 wire
extension), and Pillar D applies throughout.

**Pillar A — Model catalog + cryptographic hash verification**
- The coordinator maintains a signed catalog of known-good model artifacts:
  model_id → expected SHA-256 hash of the model weight file (or a
  coordinator-endorsed hash if weights are large and hashed incrementally).
- On provider registration, the coordinator REQUESTS the provider's
  `model_hash` for each advertised model. The provider computes and returns it.
  The coordinator compares to the catalog.
- Providers whose reported hash does not match the catalog for a given model
  MUST be rejected for that model (they may still serve other models that DO
  match, or provisional-only models outside the catalog).
- `/v1/models` response MUST gain a `hash_verified: true | false | "uncatalogued"`
  field per model entry. Buyers MUST be able to filter to `hash_verified: true`.
- Pillar A requires no SPEC-001 wire change: `model_hash` is added to the
  provider registration WS message as an optional field (backward compat; old
  providers omit it, treated as `"uncatalogued"`). Specify this extension as a
  SPEC-001 v1.3 candidate annotation — do NOT edit SPEC-001.
- Out of scope: weight download by the coordinator; the coordinator trusts the
  provider's hash self-report but validates it against the catalog. The threat
  Pillar A closes is honest-but-misconfigured providers (wrong model loaded),
  not adversarial providers that lie about their hash.

**Pillar B — Provider-leg encryption (channel confidentiality)**
- Buyer prompts and completions MUST be encrypted in transit on the
  coordinator-to-provider leg, so a passive network observer cannot read them.
- Design: TLS is already the baseline for the WebSocket leg. Pillar B adds an
  application-layer envelope: the coordinator wraps the `inference_request`
  payload with an AEAD cipher (AES-256-GCM or ChaCha20-Poly1305; operator
  configurable, default AES-256-GCM) under a per-session key. The provider
  decrypts before calling the local MLX runtime.
- Key exchange: ephemeral ECDH (X25519) handshake embedded in the provider WS
  auth/registration flow. The coordinator generates an ephemeral keypair per
  provider session; the provider publishes its public key in the registration
  message. Derive a shared secret; use it as AEAD key.
- This is NOT end-to-end buyer-to-provider encryption. The coordinator sees
  plaintext (it must route and account). Pillar B provides network-path
  confidentiality and closes the "passive eavesdropper on the provider WS link"
  threat. Document this scope clearly as a normative limitation.
- Pillar B REQUIRES a SPEC-001 wire change (new fields in `auth_request` and
  `inference_request` messages). Specify the wire extension here as a SPEC-001
  v2.0 candidate. Do NOT edit SPEC-001 in this session; annotate the extension
  requirement precisely enough for a future SPEC-001 v2.0 session to implement it.
- Backward compat: if a provider does not advertise Pillar B support, the
  coordinator MUST fall back to unencrypted Tier-1 routing (configurable:
  `tier2.require_encrypted_leg: false` by default; set true to reject
  unencrypted providers).

**Pillar C — Hardware attestation**
- A provider SHOULD be able to submit a hardware attestation report (e.g.,
  Apple Secure Enclave assertion, TPM quote, or a signed Apple Silicon chip ID)
  proving that the inference binary is running on genuine Apple Silicon hardware
  of the claimed RAM tier.
- The coordinator validates the attestation against Apple's attestation CA (or
  the operator's configured attestation root). Providers with valid attestation
  are marked `attested: true`; buyers can filter to attested providers.
- Pillar C is the highest-complexity pillar. v0.1 MUST specify the attestation
  data model and verification flow in enough detail to unblock a prototype, but
  MAY defer the exact Apple attestation API binding (DeviceCheck / App Attest
  / Secure Enclave assertions) to a sub-spec. State which Apple API is the
  recommended starting point and why.
- Pillar C REQUIRES a SPEC-001 wire change (new `attestation_token` field in
  `auth_request`). Annotate as SPEC-001 v2.0 candidate — same session as
  Pillar B's wire extension.

**Pillar D — Untrusted-provider behavioral safety**
- Pillars A-C reduce the attack surface but do not eliminate the risk of a
  malicious provider that: passes hash verification (correct model loaded) +
  attestation (real hardware) but still injects content or exfiltrates data.
- Pillar D is behavioral: the coordinator enforces output constraints that
  catch common malicious-provider patterns without trusting the provider's
  self-report.
- Required constraints in v0.1 scope:
  - Response size cap: coordinator MUST enforce `max_tokens` at the byte level
    on the completion stream, truncating if the provider exceeds it (closes
    exfiltration-via-oversized-completion).
  - Completion encoding validation: coordinator MUST reject completions that
    contain non-UTF-8 or that embed control characters outside the expected
    completion JSON envelope (closes steganographic channel via encoding abuse).
  - Response time anomaly: coordinator SHOULD log a WARN audit event when a
    provider's time-to-first-token significantly exceeds the declared
    `model_load_time` baseline (possible signal of non-standard runtime).
- Pillar D adds no SPEC-001 wire change. It is coordinator-internal enforcement
  on the existing inference stream.

### Phase ordering

- **Phase 1 (Pillar A):** model catalog + hash verification. Coordinator-only.
  No SPEC-001 wire change. Backward compat — old providers treated as
  `"uncatalogued"`. Lowest-risk; ships first.
- **Phase 2 (Pillars B + C):** provider-leg encryption + hardware attestation.
  Requires SPEC-001 v2.0. Both pillars share the same WS handshake extension,
  so they ship together to avoid a two-step wire migration.
- **Phase 3 (Pillar D):** untrusted-provider safety. Coordinator-internal;
  ships incrementally into Phase 1 or Phase 2 (no hard dependency on either).

### Tier-2 disclosure update

When ANY Tier-2 pillar is live, `/v1/models` MUST update the
`hardware_attestation` and `model_hash_verified` fields in `tier1_disclosure`
(SPEC-006 §5) to reflect actual enforcement state, not static Tier-1 defaults.
The upgrade is a per-model, per-provider granularity signal — a pool that is
50% Phase-1-verified and 50% uncatalogued MUST represent that in the
`tier1_disclosure` block rather than claiming uniform verification.

## Required reading (read fully before writing)

1. `specs/SPEC-006-buyer-api.md`
   - §1.6 (Tier 1 disclosure — the normative baseline SPEC-008 supersedes
     per pillar as each ships)
   - §F-1.5 (Tier-2 survivability clause and the four invariants — mandatory
     input to §2 of SPEC-008)
   - §5 (`tier1_disclosure` block in `/v1/models` — SPEC-008 extends it)
   - §13 (model identity caveat — SPEC-008 closes this with Pillar A)
   - §19 (audit category Y — expectation drift; SPEC-008's job is to retire it)
   - §22 (production launch gate checklist — SPEC-008 adds Tier-2 gate items)

2. `specs/SPEC-002-coordinator.md`
   - §3 (provider state machine, FR-P5 — Pillar A adds `hash_mismatch` as a
     new rejection reason)
   - §5 (routing algorithm — Pillar A and B add new routing predicates:
     `hash_verified` and `encrypted_leg` filters)
   - §7.2 (provider WS auth — Pillars B+C extend the registration handshake)
   - §11 (audit categories — SPEC-008 adds new Tier-2 audit categories)

3. `specs/SPEC-001-phase3-binary.md`
   - §3 (provider WS protocol — Pillars B+C require wire extensions; study
     the existing `auth_request` and `inference_request` shapes precisely)
   - §6.2 (`/v1/models` shape — Pillar A adds `model_hash` to provider
     registration; Pillar C adds `attestation_token`)

4. `specs/SPEC-004-smart-router.md`
   - §2 (out-of-scope list — "Tier-2 attestation" is named there; SPEC-008
     is exactly that scope)
   - §4 (Pillar A sticky affinity — Tier-2 MUST NOT break SPEC-004 sticky
     semantics; the F-1.5 invariants bind here)

5. `beta/DECISION_CRITERIA.md`
   - Entry 24 (2026-05-29) — the full independent audit response. Read the
     H-001, H-004, H-006 findings and the "Spec corpus at Entry-24 commit"
     section. The SPEC-008 candidate scope is stated verbatim there.
   - Entry 21 — "no premium positioning" rule; SPEC-008 extends this to "no
     privacy/attestation positioning until enforcement is live."

## What SPEC-008 must contain (sections, in order)

0. **Operator-paste invocation block** (verbatim preamble, same as SPEC-002 §0).
1. **Scope and mission** — what SPEC-008 covers, what it defers, relationship to
   SPEC-001/002/004/006. One paragraph on the north-star mission (close the
   enforcement gap between Tier-1 disclosure and Tier-2 enforcement). Explicit
   in-scope: Pillars A-D, Phase 1-3 roadmap, survivability audit. Explicit
   out-of-scope: rewards (SPEC-005), AntFeed (SPEC-007), billing, multi-region,
   buyer-to-provider end-to-end encryption (not in scope — coordinator sees
   plaintext).
2. **Tier-2 survivability audit** — mandatory (see "First obligation" above).
   Four invariants from SPEC-006 §F-1.5 resolved with normative findings.
   Each resolution is a MUST. If any invariant cannot be preserved by the
   proposed Tier-2 design, this section MUST note the conflict and the design
   MUST be revised before the spec can advance beyond v0.1.
3. **Terms and definitions** — Tier 1, Tier 2, catalog, hash verification,
   attested provider, encrypted leg, uncatalogued provider, behavioral safety,
   survivability invariant, SPEC-001 v2.0 candidate.
4. **Architecture overview** — how Tier 2 layers onto the Tier 1 coordinator
   (a pipeline diagram: provider registration → [Pillar C attest?] → [Pillar A
   hash verify?] → routing eligible → [Pillar B encrypt leg?] → request relay
   → [Pillar D output validate] → response to buyer). Show which pillars the
   coordinator enforces vs which require provider changes.
5. **Pillar A — Model catalog + hash verification** — full normative spec.
   Catalog schema, hash algorithm (SHA-256), provider registration extension,
   `/v1/models` `hash_verified` field, routing predicate, rejection behavior,
   SPEC-001 v1.3 annotation (new optional field only; backward compat
   guaranteed). Acceptance criteria for Pillar A.
6. **Pillar B — Provider-leg encryption** — full normative spec. AEAD cipher
   suite, X25519 ECDH key exchange in provider WS registration, per-session key
   derivation, fallback policy (`require_encrypted_leg` flag), SPEC-001 v2.0
   wire extension annotation. Limitation: coordinator-to-provider channel only;
   coordinator sees plaintext (normative, non-negotiable, non-overridable).
   Acceptance criteria for Pillar B.
7. **Pillar C — Hardware attestation** — full normative spec. Attestation data
   model, recommended Apple API (App Attest or DeviceCheck — justify the
   choice), coordinator CA validation flow, `attested: true | false | "unsupported"`
   per provider in `/v1/models`, routing predicate, SPEC-001 v2.0 wire extension
   annotation (same handshake extension as Pillar B). Acceptance criteria for
   Pillar C.
8. **Pillar D — Untrusted-provider behavioral safety** — full normative spec.
   Three enforcement constraints (size cap, encoding validation, response-time
   anomaly logging) with exact enforcement points in the coordinator relay loop.
   Acceptance criteria for Pillar D.
9. **Phase roadmap** — Phase 1 (Pillar A only, ships first), Phase 2 (Pillars
   B+C together, requires SPEC-001 v2.0), Phase 3 (Pillar D, incremental).
   Each phase: prerequisites, coordinator config flags, `/v1/models`
   `tier1_disclosure` updates required on each phase transition.
10. **SPEC-001 v2.0 candidate annotations** — a precise description of the
    two wire extensions (Pillar B key exchange fields + Pillar C attestation
    token) the coordinator needs from SPEC-001 v2.0. This section is a
    normative reference for the future SPEC-001 v2.0 BUILD session. Include
    exact field names, types, and the backward-compat rule (old providers omit
    these fields and are treated as Tier-1-only). Do NOT edit SPEC-001 in this
    session.
11. **Configuration** — new `tier2.*` keys in `coordinator.yaml`. At minimum:
    `tier2.catalog_path`, `tier2.catalog_public_key`, `tier2.require_hash_verified`
    (default false, Pillar A opt-in), `tier2.require_encrypted_leg` (default
    false, Pillar B opt-in), `tier2.require_attestation` (default false, Pillar
    C opt-in), `tier2.output_size_cap_bytes` (Pillar D; default = max_tokens
    ceiling), `tier2.encoding_validation_enabled` (default true, Pillar D).
    All new flags MUST default to preserving current Tier-1 behavior so the
    live coordinator is not changed by merely deploying SPEC-008 binaries.
12. **Observability** — new audit categories (model hash mismatch, attestation
    failure, encrypted leg fallback, output encoding rejection, oversized
    completion truncation). All Tier-2 enforcement events MUST emit structured
    audit log entries with enough context to reconstruct provider identity,
    request_id, and rejection reason.
13. **Tier-2 disclosure update protocol** — normative rules for how the
    `tier1_disclosure` block in `/v1/models` (SPEC-006 §5) updates as Tier-2
    pillars go live. Must cover the partial-pool case (mixed verified/uncatalogued
    providers). The disclosure update MUST NOT be operator-overrideable.
14. **Acceptance criteria** — AC-T2-1 through AC-T2-N. Each AC MUST be
    deterministically verifiable. At minimum cover: survivability invariants
    hold (a)-(d); Pillar A hash match routes correctly + hash mismatch rejects
    per-model; uncatalogued provider routes with `hash_verified: false`; Pillar
    B key exchange completes and payload encrypted before crossing WS; fallback
    to Tier-1 unencrypted when `require_encrypted_leg: false`; Pillar C
    attestation validates + attested flag propagates to `/v1/models`; Pillar D
    truncates oversized completion at exact byte cap; Pillar D rejects malformed
    encoding; all defaults leave Tier-1 behavior byte-identical; disclosure
    block updates correctly on Phase 1 transition.
15. **Audit categories** — new entries for Tier-2 enforcement events. Inherit
    SPEC-002's category namespace; add T2.A (hash mismatch), T2.B (encrypted
    leg event), T2.C (attestation event), T2.D (output safety event). Each
    category: condition, severity, required log fields.
16. **Operator questions** — any genuinely unresolved design questions surfaced
    during drafting. Keep short; if you find yourself listing many, re-read
    the locked-architecture section.

## Hard rules

- **Additive only.** With all `tier2.*` flags at their defaults, coordinator
  behavior MUST be byte-identical to the current Tier-1 production behavior.
  Tier-2 features are opt-in per flag. Deploying the SPEC-008 binary without
  changing config MUST NOT change any live behavior.
- **Do NOT edit locked specs.** SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-004
  v0.3.1, SPEC-006 v0.8.1 are locked. Wire extensions go in §10 of SPEC-008
  as SPEC-001 v2.0 annotations, not as edits to SPEC-001.
- **F-1.5 invariants are non-negotiable.** If any proposed Tier-2 design
  conflicts with survivability invariants (a)-(d), the design MUST be rejected
  or restructured. §2 must clear before §4-8 are finalized.
- **Coordinator sees plaintext.** Pillar B provides network-path
  confidentiality (coordinator-to-provider channel), NOT buyer-to-provider
  end-to-end encryption. The coordinator decrypts nothing from buyers and
  re-encrypts nothing TO buyers. This limitation MUST be stated normatively
  in Pillar B (§6) and is non-overrideable.
- **Tier-2 disclosure is non-operator-overrideable.** The `tier1_disclosure`
  block behavior (auto-update to reflect actual pillar state) inherits
  SPEC-006 §5's non-overrideable constraint.
- **Clean-room.** Do NOT inspect d-inference (layr-labs) source.
  NOASSERTION license. Design from public specs + this repo only.

## Anti-rules

- Do not design rewards/billing (SPEC-005), AntFeed integration (SPEC-007),
  or any change to the buyer API wire contract (SPEC-006 §5 endpoint shapes
  are locked).
- Do not propose buyer-to-provider end-to-end encryption (out of scope;
  coordinator must see plaintext to route and account).
- Do not make any `tier2.*` flag default to true (would break live Tier-1
  deployments on binary upgrade).
- Do not edit SPEC-001, SPEC-002, SPEC-004, or SPEC-006 in this session.
  SPEC-001 v2.0 wire extensions are annotations in §10 only.

## Output file

`specs/SPEC-008-tier2.md` (normative spec; version 0.1)

Header template:

```
# SPEC-008 — Tier-2 Trust Layer

**Version:** 0.1 (2026-05-31, initial normative draft)
**Depends on:** SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-004 v0.3.1,
               SPEC-006 v0.8.1

**Change log v0.1:**
- Initial draft. Tier-2 survivability audit (§2) clears the four F-1.5
  invariants defined in SPEC-006 §F-1.5.
- Defines four pillars (model catalog, provider-leg encryption, hardware
  attestation, untrusted-provider safety) across three implementation phases.
- Annotates SPEC-001 v2.0 wire extensions required for Pillars B and C.
- All Tier-2 features opt-in; Tier-1 behavior unchanged at defaults.
```

## Self-verification checklist

Before declaring the spec complete, verify:

- [ ] §2 (Survivability audit) explicitly addresses all four F-1.5 invariants
      (a)-(d) with normative MUST resolutions — not just references to them.
- [ ] §5-8 (Pillar specs) each contain: threat model, normative requirements,
      config flag, and at least 3 deterministic acceptance criteria.
- [ ] §10 (SPEC-001 v2.0 annotations) contains exact field names and types for
      both Pillar B (key exchange) and Pillar C (attestation token) extensions.
- [ ] §11 (Config) lists ALL new `tier2.*` keys with their defaults, and every
      default preserves Tier-1 behavior.
- [ ] §14 (Acceptance criteria) has ≥15 deterministically verifiable items.
- [ ] §13 (Disclosure update protocol) covers the partial-pool mixed-state case.
- [ ] Header has `Depends on: SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-004
      v0.3.1, SPEC-006 v0.8.1`.
- [ ] No changes proposed to any locked spec.
- [ ] Pillar B §6 contains a normative limitation clause stating the
      coordinator sees plaintext and Pillar B is channel-only confidentiality.
- [ ] No `tier2.*` flag defaults to true.
- [ ] `tier1_disclosure` update protocol stated as non-operator-overrideable.

If you find yourself wanting to propose a change to a locked spec, STOP —
file it as a note in §16 (Operator questions), then continue.

## When done

Print a 200-word handback summary covering:
- What the spec defines (one paragraph)
- What it explicitly defers (one paragraph)
- Estimated implementation scope per phase (rough days estimate)
- Genuine open questions for the operator (bulleted list)

Then stop. Do NOT begin implementation. The operator will run
`AUDIT_SPEC_008_PROMPT.md` (to be drafted) before any code work begins.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~60 min):

1. Read `specs/SPEC-008-tier2.md` start to finish.
2. Verify §2 (Survivability audit) clears all four F-1.5 invariants with
   normative findings — not just restates them.
3. Verify every `tier2.*` config flag defaults to Tier-1-no-change behavior.
4. Verify §10 (SPEC-001 v2.0 annotations) is precise enough to hand directly
   to a SPEC-001 v2.0 BUILD session without further design work.
5. Verify §13 (Disclosure update) handles the partial-pool case explicitly.
6. Verify AC count ≥15 and each AC is deterministically verifiable.

If clean: draft `AUDIT_SPEC_008_PROMPT.md` following the SPEC-006 audit
pattern (Codex + Claude independent review, cross-spec coherence check).

If issues: file fix prompt under `FIX_SPEC_008_V0_2_PROMPT.md`.

After audit + fix cycles: spec locks. Phase 1 implementation (Pillar A)
can then proceed as `BUILD_SPEC_008_PHASE1_PROMPT.md` — coordinator catalog
service only, no SPEC-001 wire change. Phase 2 (Pillars B+C) requires
SPEC-001 v2.0 first.

## Why this prompt is structured this way

The survivability audit (§2) is intentionally the first substantive section,
not an appendix. This forces the executing session to confirm that Tier-2
does not break the current Tier-1 corpus before writing a single new capability.
If §2 fails (a proposed Tier-2 design breaks F-1.5 invariant (b), say), the
design in §6 must be revised before the spec can advance. This mirrors the
audit-before-build discipline from Decision log Entry 24 lesson (2): "verifying
audit findings against code matters even for high-confidence auditors."

The three-phase ordering (Pillar A ships before Pillars B+C) exists because
Pillar A (model catalog) requires zero SPEC-001 wire change and closes H-004
(model identity unverified) immediately. Shipping Phase 1 fast delivers
real trust-layer value — the hash-verified flag in /v1/models — while the
more complex SPEC-001 v2.0 wire extension work for Pillars B+C is in progress.
