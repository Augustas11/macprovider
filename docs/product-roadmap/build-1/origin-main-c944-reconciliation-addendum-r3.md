# Build 1 origin/main c944 reconciliation addendum r3

Status: proposed. This revision incorporates r1 SHA
`353fdb88df209785b44ea3c7358fa46b5e6aca608d19ee5121eb49bdeb020f39`
and r2 SHA
`d3093609329f0177318913544fc6d0b351a26d1104b9c8cf43f176e0ff9db44a`.
It supersedes only r2's publication owner/order and canonical-v2 shape. It
resolves H2-R, H5, and H4-R from independent GPT-5.6 Sol review SHA
`7a2ba41961a03c565b0f66b789966021f39e290886c1b9555617e5958e4a4544`.
All closed r2 requirements remain unchanged. Conflict resolution is blocked
until the complete r1+r2+r3 and r5+r6+r7 bundles pass a fresh independent gate
at zero Critical, High, and Medium.

## R3-01 — WS catalog/index owner and publication capability

The composite epoch additionally captures the WS `autotuneCatalogMu`
generation, exact active/compatible catalog pointers, and exact
`artifactIdentityIndex` pointer/value. This owner is distinct from buyer
`autotuneFeedsMu` and is required for hello, heartbeat, refresh, preparation,
and positive commit comparisons.

Replace positive-authority use of the split exported setters with one WS
publication capability that atomically installs a validated catalog plus member
index under the WS authority-publication owner and `autotuneCatalogMu`. The
existing `SetAutotuneCatalog` and `SetArtifactIdentityIndex` compatibility entry
points remain available only as fail-closed operations: each first invalidates
and advances paid admission authority, then clears or changes the WS catalog/
index generation. Neither can install or preserve a current positive preparer.
Only the combined capability returns the exact WS generation/pointers needed by
the coordinator epoch.

Boot/reload sequence is closed:

1. invalidate/advance paid authority;
2. validate candidate/artifact/rate/demand feeds and derive the member index;
3. validate Tier2 and billing publications;
4. atomically publish WS catalog plus index through the combined capability;
5. refresh session identities against that exact WS generation;
6. install the positive preparer bound to buyer-feed, WS catalog/index, Tier2,
   billing, session, and authority generations.

Any failure leaves paid authority invalidated. Buyer feed callbacks never call a
WS setter while holding `autotuneFeedsMu`; they build immutable data first and
hand it to the coordinator publisher. Inventory every production option,
startup/reload call, direct WS setter, observer, and positive test seam.

## R3-02 — two-phase SQLite-first commit order

Store serialization precedes all authority pins.

**Phase A:** acquire memory-store serialization, or reserve one SQLite
connection and complete `BEGIN IMMEDIATE`. Waiting, timeout, or cancellation in
this phase holds no WS, session, pool, feed, billing, settlement, Tier2, catalog,
or preparer pin.

**Phase B:** inside the already serialized store transaction, use bounded
try-locks in this order:

1. WS admission-authority publication (`modelAdmissionAuthorityMu`);
2. WS catalog/member-index publication (`autotuneCatalogMu`);
3. WS session publication (`sessionPublicationMu`);
4. selected session writer (`session.writeMu`);
5. pool provider pin/registry owner;
6. buyer artifact/feed publication (`autotuneFeedsMu`);
7. buyer billing publication (`billingMu`);
8. billing settlement configuration (`settlementMu`);
9. Tier2 default publication (`defaultPublicationMu`);
10. selected Tier2 catalog owner (`catalog.mu`).

Compare the replay key/head and every captured source value, insert/CAS the
event, then commit or roll back the store transaction. Release Phase-B owners in
reverse order, then release Phase-A serialization. No Phase-B acquisition may
block. Every failure and cancellation path rolls back and releases all acquired
owners. This preserves the existing external-`BEGIN IMMEDIATE` no-pins invariant
and the approved SQLite-first promotion architecture.

## R3-03 — complete canonical v2 settlement extension

Canonical v2 has one discriminator plus exactly 24 required authority fields.
The discriminator is `artifact_admission_schema` with exact value
`macprovider.artifact_admission.v2`. The closed 24-field set is:

**Member identity (6):** `artifact_feed_sha256`, `artifact_id`,
`artifact_hash`, `artifact_hash_algorithm`, `artifact_feed_signer_key_id`,
`candidate_catalog_sha256`.

**Release provenance (3):** `artifact_release_id`, `candidate_release_id`,
`candidate_signer_key_id`.

**Rate authority (5):** `admission_rate_card_sha256`,
`admission_rate_card_version`, `admission_rate_card_signer_key_id`,
`admission_rate_model_key`, `admission_billing_config_snapshot_id`.

**Captured economics (6):** `admission_prompt_rate_per_mtok`,
`admission_prompt_cache_hit_rate_per_mtok`,
`admission_completion_rate_per_mtok`, `admission_provider_share_bps`,
`admission_global_multiplier_ppm`, `admission_price_unit`.

**Session and expiry (4):** `admission_provider_session_id`,
`admission_provider_receipt_key_id`, `admission_authority_expires_at_unix_ms`,
`admission_probe_expires_at_unix_ms`.

All 24 fields are present together and none is JSON null. Strings, integers,
closed algorithms/units, digests, signer relationships, release equality,
model-key equality, session/key equality, rates/share/multiplier bounds, and
route-time expiry are validated by the closed v2 decoder before canonicalization
or settlement. Zero numeric rates remain valid where existing economics allow
zero; wrong JSON types fail.

`RouteSnapshot.Value()` includes the discriminator and all 24 fields for v2, so
they all participate in the RFC8785 canonical preimage and digest. Historical
c944 remains the exact discriminator-free six-field legacy shape using
`artifact_candidate_catalog_sha256`; it never gains the additional 18 fields.
No-extension remains empty. Extra, missing, duplicate, null, cross-group partial,
both-spelling, and unknown-version shapes reject. The discriminator is separate
from gateway settlement-policy version.

## R3 implementation stop conditions

Stop if a direct setter can retain positive authority, WS catalog/index cannot
be atomically versioned, any DB wait holds a Phase-B pin, any v2 authority field
is outside the canonical digest, or a historical c944 row requires rewriting.
These are blockers, not implementation discretion.
