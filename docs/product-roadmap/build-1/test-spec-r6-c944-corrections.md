# Build 1 test specification r6 — c944 reconciliation corrections

Status: proposed. This revision incorporates test r5 SHA-256
`75c942bba7bad61297de5a2567eb06ad436e1944522437f647135023136e6576`
and supersedes C944-02, C944-04, C944-05, C944-06, C944-07, rollback, and
observability coverage as stated below. It pairs with reconciliation plan r2.

## R6-01 — live route gate versus immutable settlement

Create generation G, route and persist one request, then publish G+1.

- The already-routed G request accepts an otherwise valid in-deadline receipt,
  settles exactly once, survives restart, and replays idempotently using only
  its immutable snapshot and billing snapshot.
- A mutation of the stored G canonical bytes, digest, selected member, price, or
  receipt tuple is rejected.
- A new pre-dispatch attempt using prepared G after G+1 is rejected with
  `artifact_authority_generation_stale` and creates no paid route snapshot.
- Instrumented current feed/index/keyring accessors must remain uncalled during
  delayed G settlement and replay.

## R6-02 — complete contention and setter matrix

Under `-race`, pause the positive path at each ordered owner: WS authority,
session publication, session writer, pool pin, feed publication, billing
publication, settlement configuration, Tier2 default publication, selected
catalog, and SQLite CAS. Concurrently exercise reload, disconnect, member/pin
change, feed/index replacement, billing change, Tier2 row change, expiry, and
cancellation. Assert either one coherent positive commit or a non-paid failure,
never a mixed authority; every pin/lock releases on success and every failure.

Table-drive every production boot/reload setter and authorized test publisher.
Fail each Tier2, billing, feed verification, member-index build, and final WS
installation stage. Paid admission must remain disabled until one complete
epoch installs. Direct component setters must be unable to install a positive
preparer. Include timeout/deadlock bounds and exact generation comparisons.

## R6-03 — journal v1/v2 restart matrix

- Original GGUF submit persists strict `byom_pending_offer.v2` with full local
  file identity and locator digest but sends none of that local proof on wire.
- Restart and unchanged retry: reopen no-follow, compare full identity,
  recompute digest under deadline, preserve the protected tuple, then create a
  fresh signature/timestamp/nonce/idempotency key and post.
- Reject in-place bytes, device/inode, size, high-precision mtime, pathname/
  resolved locator, missing file, digest, deadline, partial v2, and unknown-field
  changes before network mutation.
- V1 GGUF returns `gguf_retry_legacy_proof_missing`, permits status/terminal
  reconciliation and explicit withdrawal, and permits a fresh offer only after
  terminal truth removes the old journal. V1 non-GGUF retains existing retry.
- Prove the advisory digest cache alone cannot authorize retry and no local
  identity/path appears in request bytes or logs.

## R6-04 — exact snapshot classes and digest preimages

Use golden canonical JSON and SHA-256 from an actual unmodified c944-created
database fixture.

- No extension: no discriminator or artifact fields; existing settlement rules
  remain unchanged.
- Historical c944: no discriminator, exact legacy six keys including
  `artifact_candidate_catalog_sha256`; reconstructed legacy `Value()` canonical
  bytes equal stored `route_snapshot_canonical_json`, whose SHA-256 equals the
  stored digest.
- Canonical v2: discriminator `macprovider.artifact_admission.v2`, exact new six
  keys including `candidate_catalog_sha256`; reconstructed v2 canonical bytes
  and digest match storage.
- Reject raw-JSON hashing as the preimage, duplicate keys, both spellings,
  partial sets, unknown discriminator, unknown artifact keys, corrupt canonical
  bytes, changed digest, and missing evidence. Confirm the gateway policy version
  is unchanged and old rows are never rewritten.

## R6-05 — exact pricing calls

Use distinct member hash, row model ID/hash/revision, artifact ID, and model key.
Instrument the Tier2 resolver and signed/effective rate-card lookup APIs.

- Tier2 resolution receives the candidate row model identity.
- Both rate-card lookups receive only the coordinator pair-resolved model key.
- Install attractive malicious rates under the model ID, artifact ID, and a
  provider-asserted key; none may be selected.
- Persisted billing snapshot and receipt price match the coordinator-resolved
  model-key rate across restart and replay.

## R6-06 — observability assertions

Assert exactly one bounded event/counter for each failed composite publish,
stale prepared generation, stale member, historical decode, canonical decode,
unsupported schema, corrupt snapshot, retry identity change, and missing legacy
proof. Preserve the existing `artifact_identity_index_stale` signal. Assert logs
contain no local path, inode, private journal material, signed envelope, secret,
or key. High-cardinality member loops must not emit per-member storms.

## R6-07 — recovery preflight

Before any replay, test that the named backup ref resolves to the checkpoint SHA,
`git bundle verify` succeeds, private recovery directories/files have 0700/0600
permissions, and tracked/untracked SHA manifests reproduce the frozen tree.
Fail if manifests contain operator-secret names, `.env`, private keys, payout
material, build output, temp logs, or unrelated work. Build the reconciled branch
in a fresh hidden worktree from current `origin/main`; leave the source worktree
unchanged. After replay, require that commit and file manifests contain only the
intended Build 1 diff.

## Evidence and gate

R6 tests are additive to every applicable r4/r5 and upstream c944 test. Record
selected/pass/fail/skip counts, duration, command, base/head SHA, and log hash.
The full Swift, coordinator, gateway, integration, dist, vet, lint, governance,
Xcode, and complete-diff GPT-5.6 Sol audit requirements remain unchanged.
Fixture evidence does not qualify physical MLX execution, release signing,
deployment, or production settlement.
