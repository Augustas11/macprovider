# Build 1 test specification r7 — c944 owner and schema corrections

Status: proposed. This revision incorporates test r5 SHA-256
`75c942bba7bad61297de5a2567eb06ad436e1944522437f647135023136e6576`
and test r6 SHA-256
`69cded9a4aa91c68abccb9bd740f6a78e5c965d571401a8559946cbb9036ffec`.
It supersedes r6 owner-contention coverage and r6's canonical-v2 field count.
It pairs with reconciliation plan r3 and resolves H2-R, H5, and H4-R from
independent GPT-5.6 Sol review SHA
`7a2ba41961a03c565b0f66b789966021f39e290886c1b9555617e5958e4a4544`.

## R7-01 — WS catalog/index publication ownership

Run the positive preparation/commit path under `-race` while pausing the actual
WS `autotuneCatalogMu` owner. Exercise each concrete publication surface:

- `SetAutotuneCatalog`;
- `SetArtifactIdentityIndex`;
- the new combined catalog/index publisher;
- the buyer feed observer/callback;
- every production boot and reload caller; and
- every authorized test publisher.

The two split setters must first invalidate/advance paid authority and must
never retain or install a positive preparer. The combined publisher must expose
one exact WS catalog/index generation and pointer pair. Positive preparation
must bind that generation; session identity refresh and the final commit must
compare it exactly. Fail candidate verification, member-index construction,
Tier2/billing validation, combined publication, and session refresh one stage at
a time. Every failure leaves paid authority disabled and emits one bounded
sanitized event. Prove the buyer observer never calls a WS setter while holding
`autotuneFeedsMu`.

## R7-02 — SQLite-first two-phase contention matrix

For SQLite, acquire an external `BEGIN IMMEDIATE`, start promotion, and prove
the blocked Phase-A wait holds no Phase-B owner or preparer pin. Repeat for
cancellation and deadline expiry. Preserve the existing external-BEGIN
regression test.

For the memory store, pause its serialization owner before Phase B and prove no
Phase-B owner is held. After memory serialization or SQLite `BEGIN IMMEDIATE`
succeeds, pause each bounded Phase-B acquisition in exact order:

1. `modelAdmissionAuthorityMu`;
2. `autotuneCatalogMu`;
3. `sessionPublicationMu`;
4. selected `session.writeMu`;
5. pool provider pin/registry owner;
6. buyer `autotuneFeedsMu`;
7. buyer `billingMu`;
8. billing `settlementMu`;
9. Tier2 `defaultPublicationMu`;
10. selected Tier2 `catalog.mu`.

At every pause, mutate the next owner and independently exercise timeout,
cancellation, disconnect, reload, expiry, and injected compare/insert/CAS/
commit failure. The result must be either one coherent committed route or a
non-paid typed failure. Rollback must occur, every owner must release in reverse
order, and no subsequent operation may deadlock. No Phase-B acquisition may
block beyond its bounded try-lock contract.

## R7-03 — exact canonical v2 authority envelope

Golden-test a canonical v2 snapshot containing the discriminator
`artifact_admission_schema=macprovider.artifact_admission.v2` plus exactly all
24 required fields named in plan r3: six member-identity, three release,
five rate-authority, six captured-economics, and four session/expiry fields.
Assert exact RFC8785 canonical bytes and digest from `RouteSnapshot.Value()`,
then settle, restart, and replay idempotently from only the immutable route and
billing snapshots.

Table-drive rejection for:

- each required field missing individually and at least one missing field from
  every semantic group;
- an extra field, duplicate key, JSON null, wrong JSON type, unknown schema,
  both catalog-hash spellings, or any cross-group partial envelope;
- invalid/unsupported hash algorithm or price unit;
- digest, signer, release, model-key, session, receipt-key, expiry, rate,
  provider-share, or multiplier mismatch; and
- canonical-byte substitution, raw-JSON hashing, or digest substitution.

Zero numeric rates must pass when the existing economics contract permits
zero. Historical c944 fixtures must remain discriminator-free with exactly the
six legacy fields and `artifact_candidate_catalog_sha256`; reconstruction must
match their stored canonical bytes and digest without rewriting the row.
No-extension snapshots must remain empty. Delayed historical and v2 settlement
must not consult current feed/index/keyring state, while a new route using a
stale prepared generation must fail before paid snapshot creation.

## Evidence and gate

R7 is additive to all unaffected r5/r6 and upstream c944 tests. Record exact
commands, base/head SHA, selected/pass/fail/skip counts, duration, and log hash.
Run targeted race tests first, then the full coordinator, gateway, integration,
Swift, Xcode, dist, vet, lint, and governance checks required by the changed
surface. A zero-selected, skipped, interrupted, fixture-only, or historical run
is not acceptance evidence. Physical signed-feed, MLX, hardware, release, and
production settlement qualification remain separate blockers.
