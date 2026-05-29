# Fix prompt — SPEC-006 v0.5 → v0.6 (Tier 1 disclosure + audit-response language)

Operator-paste prompt to close audit findings **H-001** (privacy
claims exceed enforcement), **H-004** (model integrity for untrusted
providers), and **H-006** (sticky caching forward-looking guard) from
the 2026-05-29 independent security audit.

This is the highest-leverage of the three audit-response patches:
**positioning language matters more than architecture here.** Done
right, the spec text locks the operator into language discipline
that prevents the "expectation drift" failure mode the auditor
identified.

Spec-text-only patch. Three findings + audit-derived production
gate checklist + brand-positioning language. SPEC-006 v0.5 → v0.6.

This is the product stream of the three-spec coordinated audit-
response cycle. Sibling prompts handle SPEC-001 v1.2.4 (concurrency)
and SPEC-002 v1.1.5 (production WS invariants). Each is
independently runnable.

Run in **Claude Code** or **Codex CLI**. Expected duration: ~60-90 min
(language-heavy, requires careful prose).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are adding Tier 1 disclosure language to SPEC-006 v0.5 so the
buyer-facing surface cannot drift into implying privacy guarantees
the current architecture doesn't provide. This is the highest-
leverage of three audit-response patches: the auditor's framing of
"expectation drift" maps precisely onto language we use in
front-door copy, API docs, error messages, marketing material,
and the spec itself.

You will edit one file in place:
  /Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md  v0.5 → v0.6

## The audit framing (read this first)

The independent audit's executive opinion is the most useful
external lens we have:

> "MacProvider does not appear to contain a critical architectural
> flaw if its current Tier 1 system is positioned as a cooperative,
> provisional provider network with no claim of provider-private
> prompts, hardware attestation, or malicious-provider resistance.
>
> The high-severity risk is expectation drift: MacProvider's
> roadmap points toward a stronger trust and privacy model, but
> the current implementation and specifications do not yet enforce
> those security properties."

The auditor caught three specific drift surfaces:
- H-001 privacy claims exceed enforcement (providers can read
  plaintext prompts and outputs in Tier 1; the spec must say so
  explicitly)
- H-004 model integrity is provider-reported, not cryptographically
  verified (label model identity as provider-reported until Tier 2
  catalog exists)
- H-006 sticky single-tenant caching, if it ships before Tier 2
  trust controls, creates privacy surface larger than raw request
  forwarding

The spec must close all three by language discipline, not by
adding new architecture. Tier 2 controls are out of scope for
SPEC-006; what's in scope is preventing language drift toward
Tier 2 claims.

## Critical constraints

**1. Spec-text-only patch.** No code changes. Verify with
`git diff phase5-gateway/` after edits — should be empty.

**2. Locked design choices unchanged.** SPEC-006 § 2 operator
pre-commitments are read-only. The patches add new sections; they
don't modify § 2.

**3. SPEC-001, SPEC-002, SPEC-003 untouched.** Verify with
`git diff specs/SPEC-001-phase3-binary.md
specs/SPEC-002-coordinator.md specs/SPEC-003-open-onboarding.md`
after edits — should be empty.

**4. No new operator decisions.** The patches don't add D-CROSS-7
or change any prior D-CROSS-N. They lock disclosure language only.

**5. Surgical scope.** Three findings, ~6 narrow additions:
- § 1.6 (or appropriate scope/out-of-scope section): Tier 1
  positioning paragraph
- § 5 (failure modes / status): Tier 1 disclosure surface in
  /v1/status response
- § 13 (documentation contract): required disclosure copy
- § 12 (front-door contract): signup-flow disclosure language
- Audit category addition for "expectation drift"
- Production launch gate checklist (verbatim from audit's section
  "Production Gate Recommendations")

**6. d-inference clean-room.** Do not inspect d-inference source.

## Required reading

1. `specs/SPEC-006-buyer-api.md` v0.5 — full document. Focus on:
   - § 1 (scope, out-of-scope)
   - § 2 (locked decisions — READ-ONLY; do not modify)
   - § 5 (failure modes, status endpoint shape)
   - § 8 (provider transparency — current language about NOT
     leaking provider IDs)
   - § 12 (front-door contract)
   - § 13 (documentation contract)
   - § 19 (audit categories)

2. `specs/SPEC-002-coordinator.md` v1.1.4 — § 1 (tier 1 scope
   definition; auditor referenced this) and § 7.1 (auth modes).

3. The audit report's H-001, H-004, H-006 findings + the
   Production Gate Recommendations section (8 items).

4. `beta/DECISION_CRITERIA.md` Entries 21, 22, 23 — the
   discipline of "no premium positioning" and the audit-pattern
   lessons. The v0.6 patch should extend this discipline to
   explicit language gates.

## Findings to fix

### F-606-V6-1 (H-001) — Tier 1 plaintext-to-provider disclosure.

**Location:** new § 1.6 (or appended to existing scope/out-of-
scope), plus references in § 12 (front-door contract) and § 13
(documentation contract).

**Problem:** SPEC-006 v0.5's positioning implicitly invites the
inference that providers can't read buyer prompts. The reality:
providers process plaintext in their local runtime. This is fine
for Tier 1 cooperative inference; it MUST be explicit so buyers
don't form false expectations.

**Fix:** Add a normative section to SPEC-006:

> **§ 1.6 Tier 1 disclosure (plaintext cooperative inference).**
>
> SPEC-006 v0.5 is a Tier 1 cooperative inference product. The
> following properties hold:
>
> 1. **Buyer prompts and provider responses are processed as
>    plaintext on provider hardware.** Providers can technically
>    observe inputs and outputs that route through their machine.
>    This is acceptable for cooperative deployments where buyer
>    and provider have an established trust relationship; it is
>    NOT a private-inference guarantee.
>
> 2. **There is no hardware attestation or runtime integrity
>    check on providers.** The coordinator admits providers based
>    on `provider_id` match (pinned tier) or rate-limited
>    provisional admission. Once admitted, the provider runtime
>    is trusted to faithfully serve requests; SPEC-006 v0.6 does
>    NOT cryptographically verify this.
>
> 3. **Model identity is provider-reported.** When `/v1/models`
>    aggregates the pool's served models, the model identifier
>    reflects what the provider's binary advertises. SPEC-006
>    v0.6 does NOT cryptographically verify the loaded model
>    against a catalog of known artifact hashes.
>
> 4. **The product makes NO privacy, attestation, integrity,
>    untrusted-provider, or malicious-provider claims.** Any
>    buyer-facing language (front-door, docs, error messages,
>    API responses, marketing material) MUST be consistent with
>    properties 1-3.
>
> These limitations are deliberate. Tier 2 (a future SPEC-008
> milestone, not in v0.6 scope) would add hardware attestation,
> provider-leg encryption, model catalog enforcement, and
> untrusted-provider safety. Until Tier 2 ships, all four
> limitations are normative and MUST be preserved in product
> language.
>
> **Production gate:** This disclosure MUST appear (in
> substantively equivalent language) in:
> - The front-door signup flow before the user receives an API
>   key (one paragraph, prominent)
> - The single-page docs (curl + SDK examples page)
> - The `/v1/models` response as a top-level `tier1_disclosure`
>   field with the same plaintext-to-provider wording
> - The README.md of any client SDK distributed by the operator
>
> Add normative implementation requirements:
>
> **§ 5.X Tier 1 disclosure surface (/v1/models extension).**
>
> The `/v1/models` response MUST include a top-level field:
>
> ```json
> "tier1_disclosure": {
>   "version": "v0.6",
>   "plaintext_to_provider": true,
>   "model_identity": "provider_reported",
>   "hardware_attestation": "none",
>   "tier2_milestone": "future"
> }
> ```
>
> Buyers consuming this field SHOULD display its content (in
> human-readable form) before sending sensitive prompts. Gateway
> implementations MUST set this field automatically; operator
> override is forbidden (no opt-out via config).

### F-606-V6-2 (H-004) — Model identity labeled provider-reported.

**Location:** § 5.5 /v1/models response semantics.

**Problem:** SPEC-006 v0.5's `/v1/models` returns
`{"id":"mlx-community/Llama-...", "owned_by":"macprovider"}`. The
`id` reflects what the provider advertises; the gateway aggregates
and forwards. The auditor's H-004 warns: "buyers may receive
responses from an unintended or degraded model while believing
they are using a specific advertised model."

**Fix:** Add a normative note in § 5.5:

> The `id` field returned by `/v1/models` reflects the model
> identifier as advertised by the serving provider binary. The
> coordinator does NOT cryptographically verify the loaded model
> weights against a catalog of expected artifact hashes. Buyers
> SHOULD treat `id` as provider-reported and NOT as a verified
> integrity claim. A future SPEC-006 (or SPEC-008 Tier 2) revision
> MAY introduce coordinator-managed model catalog + verified hash
> policy; until then, model identity verification is out of scope.

Plus require this caveat in the docs page (extend the § 13
documentation contract):

> The single-page docs MUST include a "Model identity caveat"
> subsection explaining that model `id` is provider-reported,
> not cryptographically verified.

### F-606-V6-3 (H-006) — Sticky caching forward-looking guard.

**Location:** new bullet in § 1.3 out-of-scope or § 1.6 disclosure.

**Problem:** The auditor's H-006 notes sticky single-tenant caching
appears in roadmap discussion but, if shipped before Tier 2 trust
controls, creates privacy surface larger than raw request
forwarding. SPEC-006 v0.5 explicitly omits caching, but the spec
text doesn't forbid future drift toward implementing it without
the necessary tenant-isolation work.

**Fix:** Add to § 1.3 out-of-scope OR § 1.6 disclosure:

> **No provider-side caching of any kind in v0.6.** Sticky single-
> tenant caching, prompt-result cache, KV cache reuse across
> requests, or any other form of provider-side request state
> retention is OUT OF SCOPE for v0.6. A future revision MAY
> introduce caching only if all of the following are true:
> - The cache is buyer-owned, single-tenant, non-transferable
>   across buyers
> - The cache has explicit lifecycle (creation, eviction,
>   buyer-triggered deletion)
> - Tenant isolation is cryptographically enforced (cache keys
>   include account ID + per-request entropy)
> - Buyer-facing disclosure explicitly states cache existence
>   and retention semantics
> - The cache survives the Tier 1 → Tier 2 transition with
>   privacy guarantees that match Tier 2 trust controls
>
> Any partial implementation of caching that doesn't meet ALL of
> the above MUST NOT ship. This is a forward-looking guard
> against the H-006 audit finding.

### F-606-V6-4 — Audit category for expectation drift.

**Location:** § 19 audit categories.

**Fix:** Add:

> **Category Y: Expectation drift between roadmap and current
> enforcement.**
>
> SPEC-006 documents future Tier 2 capabilities (hardware
> attestation, encrypted provider execution, model catalog
> enforcement) as roadmap targets. Audit cycles MUST verify that
> spec text, front-door copy, API docs, error messages, and
> external positioning material do NOT promise these capabilities
> as currently shipping. The discipline is:
>
> - Tier 1 properties are normative
> - Tier 2 properties are roadmap (out of scope, but discussable
>   as future)
> - Anything that conflates the two = MAJOR finding
>
> Reference: 2026-05-29 independent security audit H-001 — the
> language "Your prompts never touch AWS, GCP, or Azure" is
> technically true but invites buyers to infer providers can't
> see prompts. Both Tier 1 and Tier 2 statements must hold
> simultaneously; either-or framing is the drift class to catch.

### F-606-V6-5 — Production launch gate checklist (verbatim from audit).

**Location:** new § 22 (after § 21 if it exists, or wherever
"Operator questions" lives in v0.5).

**Fix:** Add the audit's 8-item Production Gate Recommendations
section verbatim (or near-verbatim) as a normative launch
checklist. The operator MUST execute ALL 8 items before SPEC-006
v0.6 ships publicly via api.streamvc.live:

> **§ 22 Production launch gate checklist.**
>
> Adapted from the 2026-05-29 independent security audit's
> "Production Gate Recommendations" section. Operator MUST execute
> all 8 items before SPEC-006 v0.6 is deployed to production with
> public buyer access.
>
> 1. Provider tokens MUST be mandatory in production.
>    [SPEC-002 v1.1.5 § 7.X PG-1]
> 2. Provider WebSocket endpoints MUST be shielded by proxy-level
>    rate limits and connection caps.
>    [SPEC-002 v1.1.5 § 7.X PG-2]
> 3. The public gateway MUST expose only buyer API endpoints; it
>    MUST NOT expose coordinator internals.
>    [SPEC-002 v1.1.4 § 7 nginx routing block]
> 4. Advertised provider concurrency MUST equal enforced runtime
>    concurrency. [SPEC-001 v1.2.4]
> 5. Model identity MUST be either cryptographically verified or
>    clearly labeled as provider-reported. [§ 5.5 above]
> 6. Buyer disconnect, provider disconnect, timeout, and
>    cancellation MUST produce exactly one accounting outcome.
>    [§ 7.2 + § 17 in v0.5; SPEC-001 v1.2.3 § 6.6 cancel-usage]
> 7. Tier 1 documentation MUST clearly state that provider-side
>    prompts are plaintext to the provider runtime. [§ 1.6 above]
> 8. Any privacy, attestation, or hardware-trust claim MUST be
>    blocked until Tier 2 enforcement is live. [§ 1.6 above]
>
> This checklist is the operator-side counterpart to SPEC-006
> v0.6's spec-side disclosure language. Together they implement
> the audit's recommendation: "Keep Tier 1 narrow, explicit, and
> operationally hardened, while treating provider-private prompts,
> attestation, model integrity, and marketplace-grade settlement
> as separate Tier 2 launch gates."

### Spec text catch-up

Add to SPEC-006 v0.6's change log:

> **v0.6 (2026-05-29, audit response, Tier 1 disclosure language
> + production launch gate):** Closes H-001 (privacy claims
> exceed enforcement), H-004 (model integrity is provider-
> reported), H-006 (sticky caching forward-looking guard) from
> the 2026-05-29 independent security audit. Six additions:
> § 1.6 plaintext-to-provider disclosure (4 normative properties);
> § 5.X /v1/models extension with `tier1_disclosure` block;
> § 5.5 model identity provider-reported note; § 1.3 sticky-
> caching guard; § 19 expectation-drift audit category; § 22
> production launch gate checklist (8 items adapted from audit
> recommendations). Sibling patches (SPEC-001 v1.2.4 + SPEC-002
> v1.1.5) close H-002 and H-003. H-005 (billing settlement) is
> largely already covered by D-CROSS-1 (refund matrix) +
> SPEC-001 v1.2.3 cancel-usage normative; verification deferred
> to BUILD_PHASE5 Phase C end-to-end test. No code changes; v0.6
> implementation contract for BUILD_PHASE5 expanded by these
> additions.

Update "Depends on:" line — bump SPEC-001 v1.2.3 → v1.2.4, SPEC-002
v1.1.4 → v1.1.5 (the sibling patches).

## Verification gate

After the edits:

1. `git diff phase5-gateway/` MUST be empty (code already not
   yet implemented; the patch is documentation expansion).
2. `git diff specs/SPEC-001-phase3-binary.md
   specs/SPEC-002-coordinator.md specs/SPEC-003-open-onboarding.md`
   MUST be empty.
3. § 1.6 contains 4 Tier 1 properties + production gate.
4. § 5 contains the `/v1/models` `tier1_disclosure` block.
5. § 1.3 (or § 1.6) contains the sticky-caching guard.
6. § 19 audit category Y exists.
7. § 22 production launch gate has 8 items mapping to source
   specs.
8. SPEC-006 § 2 locked decisions unchanged.

If your edits exceed ~400 added lines in SPEC-006, stop and
re-check scope. The patches are substantial but bounded.

When done, print a 250-word handback summary covering:
- F-606-V6-1 closure (H-001 disclosure)
- F-606-V6-2 closure (H-004 model identity)
- F-606-V6-3 closure (H-006 caching guard)
- F-606-V6-4 + F-606-V6-5 (audit category + production gate)
- Whether SPEC-006 v0.6 is READY TO LOCK
- Key implementation reminder: BUILD_PHASE5 Phase D MUST implement
  the `/v1/models` tier1_disclosure block per § 5.X; the gateway
  MUST NOT allow operator override; the front-door MUST include
  the § 1.6 disclosure paragraph in signup flow

Then stop. The operator commits SPEC-006 v0.6 in coordination
with SPEC-001 v1.2.4 + SPEC-002 v1.1.5.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~25 min — most substantial of the
three):

1. `git diff specs/SPEC-006-buyer-api.md` — version bump, change
   log, 6 normative additions, no § 2 changes.
2. `git diff phase5-gateway/` — should be empty.
3. `git diff specs/SPEC-001-phase3-binary.md
   specs/SPEC-002-coordinator.md specs/SPEC-003-open-onboarding.md`
   — should be empty.
4. **Most important:** verify the § 1.6 disclosure language is
   precise — "providers can technically observe prompts and
   outputs" must be the wording (not euphemisms or hedges).
5. § 5.X `tier1_disclosure` block schema is unambiguous and
   non-overridable.
6. § 22 production launch gate's 8 items each map to a source
   spec section.

## What this patch unblocks

SPEC-006 v0.6 + SPEC-001 v1.2.4 + SPEC-002 v1.1.5 land as a
coordinated set. BUILD_PHASE5 then implements:

- Phase C: refund matrix per D-CROSS-1 (already in v0.5;
  reaffirmed)
- Phase D: front-door signup flow MUST include § 1.6 disclosure
  paragraph; `/v1/models` MUST emit `tier1_disclosure` block;
  docs MUST include model identity caveat
- Phase E: production launch gate § 22 executed as a checklist
  before api.streamvc.live opens to public buyers

The audit response transforms from "we agree with the audit" to
"the audit findings are normatively encoded in the spec corpus,
visible in product UI, and gated before launch."

## Why this is the highest-leverage patch of the three

SPEC-001 v1.2.4 fixes one bug (concurrency). SPEC-002 v1.1.5
documents operational invariants. SPEC-006 v0.6 changes how the
product communicates itself to every buyer who signs up. The
expectation-drift class is at the language layer; this patch
closes it at the language layer.
