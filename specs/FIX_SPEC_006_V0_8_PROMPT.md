# Fix prompt — SPEC-006 v0.7 → v0.8 (Pillar A enablement: gateway-derived conversation key + sticky-caching gate satisfied)

Operator-paste prompt to revise `specs/SPEC-006-buyer-api.md` from v0.7 to
v0.8 as the **sibling spec movement** required to unblock SPEC-004 v0.2
Pillar A (sticky session affinity, KV-cache reuse). SPEC-004 v0.2 fully
specifies the routing-side contract; SPEC-006 v0.8 must specify the
gateway-side derivation, transport, disclosure, and lift the v0.7 §1.3
sticky-caching prohibition by satisfying its five preconditions.

This is a **spec-text-only patch** to SPEC-006. No code, no other specs.

## What this stream owns

| Layer | From | To |
|-------|------|----|
| Spec document | SPEC-006 v0.7 | SPEC-006 v0.8 |
| Gateway code | (no change in this stream) | (no change) |
| SPEC-004 contract surface | already specified in v0.2 (`routing_internal.conversation_key`, `conv:` namespace) | unchanged — v0.8 FULFILLS the contract, MUST NOT alter it |
| Other specs | (locked) | (locked) |

## Why this exists

SPEC-004 v0.2 independent audit verdict was ACCEPT, with Pillar A
(sticky session affinity) implementation explicitly gated on this sibling
revision. v0.7 §1.3 prohibits provider-side caching of any kind until five
preconditions are met (single-tenant ownership, explicit lifecycle, crypto
tenant isolation, buyer disclosure, Tier-2 survivability). SPEC-006 v0.8's
job is to **satisfy each of those five preconditions** — not delete the
guard — and to define the gateway-side mechanics (key derivation, transport
to the coordinator, and the refreshed H-006 disclosure language).

## Sibling status

- **SPEC-004 v0.2** (committed) — defines the routing-side contract. SPEC-006
  v0.8 MUST conform to it; if any spec-text in v0.7 contradicts the SPEC-004
  v0.2 contract surface, fix v0.7's text in v0.8 (do NOT alter SPEC-004).
- **No SPEC-001 / SPEC-002 / SPEC-003 / SPEC-004 wire change.** All movement
  is SPEC-006-internal + the new gateway→coordinator internal field.

---

```
=== BEGIN PROMPT ===

You are revising `specs/SPEC-006-buyer-api.md` from v0.7 to v0.8 to enable
SPEC-004 v0.2 Pillar A (sticky session affinity) by satisfying v0.7 § 1.3's
five sticky-caching preconditions and specifying the gateway-side derivation,
transport, and privacy disclosure for the conversation key that SPEC-004 v0.2
requires (`routing_internal.conversation_key`, `conv:` namespace).

## Locked corpus (do NOT modify spec text in this phase)
  SPEC-001 v1.2.4   — phase3-binary provider WS protocol (LOCKED; no wire change)
  SPEC-002 v1.3.3   — coordinator request router
  SPEC-003 v0.7    — open onboarding
  SPEC-004 v0.2    — smart router (the CONTRACT this stream fulfills; do NOT alter)

## Required reading
1. `specs/SPEC-006-buyer-api.md` — the file you are revising. Read in full:
   - § 1.3 (the sticky-caching prohibition; its 5 preconditions are your
     normative requirements list)
   - § 1.6 (Tier-1 plaintext-to-provider disclosure; 4 normative properties +
     production-gate appearance points)
   - § 5.3.1 (`/v1/models` `tier1_disclosure` block — the disclosure surface
     buyers see)
   - § 19 (audit categories — expectation-drift)
   - § 22 (8-item production launch gate checklist)
2. `specs/SPEC-004-smart-router.md` v0.2 — the contract you fulfill:
   - FR-SR-2 lines ~160–195: `routing_internal.conversation_key`, `conv:`
     namespace requirement, "MUST NOT be accepted from direct buyer traffic"
   - § 6 "Gateway-derived internal fields" + the redaction MUST
   - § 11 implementation hand-off: the SPEC-006 v0.8 gate
   - AC-SR-15: the `session_ended` regression Pillar A MUST NOT break
3. `phase5-gateway/internal/router/server.go` for grounding only (do NOT
   propose code changes in this stream): note where buyer headers are
   parsed today and where the gateway already mints internal tokens
   (`auth.StateToken`, `mp_oauth_session` cookie) — establish that the
   gateway already has a "derive an internal token" capability you can reuse
   the pattern of.

## Mandatory changes (numbered; each MUST land in normative text)

### F-1. Lift § 1.3's sticky-caching prohibition by SATISFYING its 5 preconditions in v0.8
Do NOT delete § 1.3 or remove the guard. Rewrite it so v0.8 explicitly meets
each of the five preconditions (existing § 1.3 already lists them — keep the
language, add v0.8's satisfaction clauses):
  1. **Single-tenant, non-transferable.** State that
     `routing_internal.conversation_key` MUST be scoped to a single
     `account_id`; the gateway MUST refuse to derive or forward a key
     attributable to more than one account. Cross-account spoofing MUST be
     structurally impossible at the gateway, not advisory.
  2. **Explicit lifecycle.** Creation rule (when the gateway mints/derives a
     key on a buyer request), eviction rule (the coordinator's
     `routing.sticky_ttl_s` per SPEC-004 §5 is authoritative, but the gateway
     MUST cite it), and buyer-triggered deletion (a buyer-facing mechanism
     to invalidate sticky for their account — define the API shape; e.g.
     `DELETE /v1/sticky` or a header `X-MacProvider-Sticky-Reset: true`).
  3. **Tenant isolation is cryptographically enforced; cache keys include
     account ID plus per-request entropy.** Define the derivation precisely.
     The `conv:` opaque part MUST include the account_id (or its
     hash/derivation) so a `conv:` value belonging to account A cannot
     match a sticky entry created by account B even if the buyer-supplied
     tag collides. Specify the algorithm (suggested: HMAC-based, with a
     server-side secret; pick one and pin it). State that the algorithm is
     a normative MUST so two gateway instances derive the same key for the
     same inputs.
  4. **Buyer-facing disclosure.** See F-3.
  5. **Tier-2 survivability.** State the constraint that v0.8 sticky semantics
     do NOT break under a future Tier-2 (SPEC-008) attestation/encryption
     regime: e.g. a sticky entry's TTL and account-scoping survives; the
     conversation_key derivation does not depend on plaintext-only assumptions.

### F-2. Define the buyer-facing API mechanism for opting into / out of sticky affinity, and the gateway→coordinator transport for `routing_internal.conversation_key`

Two sub-decisions to make in normative text:

  **F-2a Derivation source (the buyer-side input).** Pick ONE option and
  document the rationale. Choose between:
  - **(i) Buyer-supplied opaque tag**: a new buyer header (suggested
    `X-MacProvider-Conversation:`) carrying an opaque buyer-chosen string.
    The gateway sanitizes (length/charset cap), prefixes the
    account-scoping per F-1.3, and emits the derived `conv:` value to the
    coordinator. Simplest, explicit, no magic. RECOMMENDED.
  - **(ii) Gateway-derived deterministic hash of request shape**: gateway
    hashes (e.g.) the first N normalized messages and uses that to detect
    "same conversation as last time." No buyer change required, but heuristic
    and harder to audit; carries cache-poisoning risk if hash collides.
  - **(iii) Gateway-managed session token**: a sticky cookie/token issued
    on first request; buyer echoes it. Heavier auth model; touches existing
    auth surface.

  Pick (i) unless there's a compelling reason otherwise; document the choice.

  **F-2b Transport to the coordinator.** The conversation_key is NEVER a
  buyer header to the coordinator (SPEC-004 v0.2 forbids that). Define how
  the gateway transports it on the gateway→coordinator hop. Options:
  - **(i) Distinct internal HTTP header** prefixed to clearly mark it as
    gateway-only (e.g. `X-MacProvider-Internal-Conv:` — note that the
    coordinator's nginx vhost or auth layer MUST strip any such header that
    might arrive from external callers). RECOMMENDED for symmetry with the
    other `X-MacProvider-*` headers.
  - **(ii) Sidecar JSON field on the existing coordinator request body.**
    Heavier change to the request shape.

  Pick (i) unless there's a reason otherwise; document. State the MUST that
  the coordinator's externally-reachable surface (nginx) strips this header
  on any path that could be hit from outside the gateway — this is the
  "MUST NOT be accepted from direct buyer traffic" defense from SPEC-004
  v0.2 § 6, made concrete on the deployment layer.

### F-3. Refresh the H-006 / § 1.6 / § 5.3.1 disclosure language to reflect that sticky affinity exists in v0.8

The v0.7 disclosure language ("no provider-side caching of any kind") becomes
factually wrong the moment Pillar A is implementable. v0.8 MUST:
  - Update § 1.6's plaintext-to-provider properties to add a 5th normative
    property: when sticky affinity is enabled for an account, a buyer's
    related requests are PREFERENTIALLY routed to a single provider for up
    to `sticky_ttl_s` (per SPEC-004), and that provider can therefore
    observe and correlate more of the buyer's traffic than under default
    round-robin routing.
  - Update § 5.3.1 `/v1/models` `tier1_disclosure` block to surface a
    `sticky_affinity` sub-object: `enabled: bool` (true once an operator
    flips `routing.sticky_enabled: true`), `ttl_seconds`, and a one-sentence
    plain-language description of the privacy tradeoff.
  - Update § 19 audit-category language so future audits check the
    sticky-on disclosure parity (every place the v0.7 § 1.6 disclosure must
    appear, the v0.8 sticky disclosure must also appear: signup flow, single-
    page docs, `/v1/models`, SDK READMEs).
  - The disclosure MUST distinguish the DEFAULT case (`sticky_enabled:
    false`, no sticky, no new privacy posture) from the ENABLED case so
    operators running the default config don't have to surface unnecessary
    language. The disclosure is conditional on the operator's config.

### F-4. Add a new launch-gate item to § 22 (production launch gate checklist)

The 8-item checklist (PG-1 to PG-8 by audit numbering) becomes 9 items in
v0.8:
  - **PG-9. Sticky affinity disclosure parity.** Before `routing.sticky_enabled`
    is set to `true` in production, the v0.8 § 1.6/§5.3.1 disclosure language
    MUST appear in (a) the signup flow, (b) single-page docs, (c)
    `/v1/models tier1_disclosure.sticky_affinity`, (d) any SDK README the
    operator distributes. Operators who keep `sticky_enabled: false` (the
    default) do NOT need to surface this language; PG-9 is conditional on
    the config flip.

State PG-9 in the same prose style as PG-1 to PG-8.

### F-5. Reference SPEC-004 v0.2 explicitly as a sibling

Add a one-paragraph note (likely in § 1.4 "Relationship to SPEC-001"-style
form, or a new § 1.8 "Relationship to SPEC-004") that:
  - SPEC-004 v0.2 defines the routing-side contract for sticky affinity
    (`routing_internal.conversation_key`, `conv:` namespace, ε-cohort
    promotion, breaker composition, etc.).
  - SPEC-006 v0.8 fulfills the gateway side (derivation, transport,
    disclosure) and the v0.7 § 1.3 preconditions.
  - Pillar A implementation may proceed when BOTH v0.2 and v0.8 are
    audited-ACCEPT and a SPEC-004 build prompt for Pillars B/C/D/A is run.

## Decisions Codex MUST make in v0.8 (no "operator decides" left)

Bake each of these into normative text. Pick the recommended option unless
there's a documented spec-level reason otherwise.
- F-2a derivation source: **buyer-supplied opaque tag via
  `X-MacProvider-Conversation:`** (recommended (i)).
- F-2b internal transport: **distinct internal header
  `X-MacProvider-Internal-Conv:`** (recommended (i)) with nginx strip MUST.
- F-1.3 algorithm: pick HMAC-SHA256 over `(account_id, buyer_tag)` with a
  gateway-side secret rotated per the existing `MACPROVIDER_KEY_HASH_SECRET`
  rotation cadence; document the algorithm and the secret-source field.
- F-1.2 buyer deletion: pick `DELETE /v1/sticky` (account-scoped, returns
  `{purged: true, entries: N}`) — REST-shaped, no header magic.
- Default posture: `routing.sticky_enabled: false` (matches SPEC-004 v0.2);
  v0.8 MUST NOT change this default.

## Hard rules
- **No SPEC-001 / SPEC-002 / SPEC-004 wire-contract change.** This stream
  fulfills SPEC-004 v0.2's existing contract surface; if a v0.7 line
  contradicts SPEC-004 v0.2, fix v0.7's line in v0.8.
- **Spec-text only.** No code in this stream. The gateway implementation of
  v0.8 ships in a follow-on BUILD prompt.
- **§ 1.3 GUARD STAYS — it is satisfied, not deleted.** Every one of the 5
  preconditions MUST be explicitly satisfied with a normative MUST clause.
  This protects against future regressions.
- **Conditional disclosure.** The new sticky-related § 1.6 / § 5.3.1 /
  § 22 PG-9 language activates only when `routing.sticky_enabled: true`. The
  default config posture (sticky off) MUST require no additional buyer-facing
  disclosure surface beyond v0.7.
- **No buyer header at coordinator.** The `routing_internal.conversation_key`
  MUST never be accepted from a buyer header at the coordinator; the only
  legitimate source is the gateway-derived internal transport (F-2b), and
  the nginx strip MUST be normative (so a future nginx misconfig is a
  documented violation).
- **Account-scoping is structural, not advisory.** Cross-account `conv:`
  collisions MUST be impossible by construction (F-1.3 HMAC with account_id),
  not "MUST not be sent" guidance.

## Anti-rules
- Do not implement, scope, or pre-empt SPEC-005 (rewards/billing) or
  SPEC-007 (AntFeed seller integration); both stay deferred.
- Do not introduce Tier-2 attestation/encryption in v0.8 — only the
  forward-compatibility constraint (F-1.5 above).
- Do not alter the v0.7 § 1.6 four normative properties (1-4); ADD a fifth
  for sticky. The original four MUST be preserved verbatim where they appear
  in disclosure surfaces.

## Output requirements
- Edit `specs/SPEC-006-buyer-api.md` in place; bump version header to v0.8.
- Add a v0.8 changelog entry that summarizes: F-1 (preconditions satisfied
  with the 5 specific clauses), F-2 (derivation + transport choices), F-3
  (refreshed disclosure), F-4 (PG-9), F-5 (SPEC-004 sibling reference).
- Do NOT modify any other spec file. Do NOT create new spec files.

## Self-verification checklist (before declaring done)
- [ ] § 1.3 still has the 5 preconditions; each is now followed by a
      normative MUST clause specifying how v0.8 satisfies it.
- [ ] The conversation_key derivation algorithm (HMAC) is precise enough
      that two gateway instances would derive byte-identical keys for the
      same inputs.
- [ ] Buyer-supplied tag is normatively sanitized (length cap, charset);
      the cross-account spoof is structurally impossible (not just MUST-not).
- [ ] Internal transport header is defined, the nginx strip MUST is stated,
      and the coordinator MUST NEVER accept the header from a buyer-reachable
      path.
- [ ] `DELETE /v1/sticky` (or chosen mechanism) is defined: auth requirement,
      response shape, idempotency, account scope.
- [ ] § 1.6 has a 5th normative property describing the sticky-on privacy
      posture; original 4 properties unchanged.
- [ ] `/v1/models tier1_disclosure` adds `sticky_affinity {enabled,
      ttl_seconds, description}` — conditional on operator config flip.
- [ ] § 22 PG-9 added; conditional language is clear (only required when
      `sticky_enabled: true`).
- [ ] SPEC-004 v0.2 sibling note present; no contradiction with v0.2
      contract surface.
- [ ] Defaults preserve the v0.7 buyer-visible behavior at
      `sticky_enabled: false`.
- [ ] No SPEC-001 / SPEC-002 / SPEC-004 wire-contract change introduced.
- [ ] Version header bumped to v0.8; changelog entry added.

=== END PROMPT ===
```

## After running this prompt
1. Run an independent audit on v0.8 — the audit MUST verify:
   - All 5 v0.7 § 1.3 preconditions are normatively satisfied (not deleted).
   - The HMAC-based account-scoping makes cross-account `conv:` collision
     structurally impossible.
   - The internal transport header is unspoofable from a buyer-reachable
     path (nginx strip + coordinator boundary check both stated).
   - The new disclosure language activates conditionally (operator-flip
     gated) and the default (sticky off) preserves v0.7 buyer-visible
     behavior.
   - No SPEC-004 v0.2 contract surface is altered.
2. If ACCEPT, write a **`BUILD_SPEC_004_A_IMPL_PROMPT`** (or fold A into
   the existing B/C/D build prompt) so Pillar A can be implemented.
3. Pillars B/C/D do NOT depend on v0.8 — they may proceed in parallel from
   SPEC-004 v0.2 alone.
