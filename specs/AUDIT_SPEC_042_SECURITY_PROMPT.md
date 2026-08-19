# AUDIT SPEC-042 — Security / Threat-Model Lane

You are threat-modeling a specification, not code. Subject:
`specs/SPEC-042-pool-control-plane.md` (Layer 2 "Trusted Pool / subnet"
control-plane manifest), status `draft-skeleton`.

Read first:
- `specs/SPEC-042-pool-control-plane.md` (subject)
- `specs/SPEC-041-relay-blind-request-encryption.md` (Layer 3 privacy boundary — the SPEC-042 pools must NOT overclaim relative to this)
- `specs/SPEC-008-*.md` (Tier-2 trust evidence: SE key custody vs. MDA hardware attestation semantics)

## Verified ground-truth facts

- Live prod: `require_attestation=false`, `require_encrypted_leg=false`
  (network-global fail-open); `verified_model_settlement_mode=enforce`;
  `live_mda_enabled=true` but observe-only/non-gating; `payout.enabled=false`.
- SE self-signed evidence proves key custody/liveness only, NOT hardware-rooted
  attestation. `sipEnabled`/`secureBootEnabled` in the SE blob are client-set
  and unchecked pending MDA.

## Your lane: does the security posture actually hold?

Report findings on:

1. **Tenant isolation soundness (R005).** Can a request bearing pool_id=P ever
   reach a non-member, a different pool's member, or a global provider? Look for
   any downgrade/spill/failover path the SPEC leaves open. Is "fail closed if no
   eligible member" fully specified, or are there race/timing windows (member
   revoked mid-request, predicate freshness expiring mid-route)?
2. **Predicate enforcement vs. fail-open network default (R004).** The SPEC makes
   pools override a fail-open network default. Is the override actually forced at
   route time, or can a pool inherit the network's false default through any
   unstated path? Are the attestation-tier semantics honest (SE≠hardware)? Can a
   client-set posture field satisfy a predicate?
3. **Manifest integrity (R001).** Signature scope, immutable-core vs. mutable
   split, downgrade of a confidentiality predicate mid-pool, manifest rollback,
   replay of an old signed manifest, `pool_id` substitution/collision.
4. **Membership & revocation (R003).** Revocation freshness bound, restart
   durability, TTL-vs-durable blocklist gap, re-admission of a revoked provider,
   cross-pool identity reuse enabling re-linkage.
5. **Claim honesty / overclaim (R009).** Does anything in the SPEC let a Layer 2
   pool imply privacy, unlinkability, provider-blindness, or confidential compute
   that it does not deliver? Metadata linkage in R006/R007 must be disclosed as
   linkable, not anonymized. Flag any residual overclaim.
6. **Metadata / side-channel leakage (R007).** Buyer IP, sticky routing
   correlation, aggregate-health provider identification, retention policy
   escape hatches.
7. **Settlement/revenue-split abuse (R006).** Can the creator split be evaded,
   or can pool labeling be forged to misattribute settlement?
8. **Rollout/downgrade safety (R010).** Mixed-binary states, disable/re-enable
   turning a rejected request into an accepted one, error-taxonomy gaps that
   leak whether a predicate failed vs. no capacity.

## Output format

Per finding: severity (CRITICAL / HIGH / MEDIUM / LOW / INFO), title, location,
a concrete attack/abuse scenario (attacker capability → step → impact), and a
fix. End with `VERDICT: <PASS|PARTIAL|FAIL> — C:<n> H:<n> M:<n> L:<n> I:<n>`.
Bar is 0 Critical/High/Medium. Report honestly; do not inflate or suppress.
`(Open)`-marked items are acceptable at skeleton stage UNLESS the openness
itself creates an exploitable ambiguity in a stated MUST — then rate it.
