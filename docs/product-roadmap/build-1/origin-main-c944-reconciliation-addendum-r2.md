# Build 1 origin/main c944 reconciliation addendum r2

Status: proposed. This revision incorporates r1 SHA-256
`353fdb88df209785b44ea3c7358fa46b5e6aca608d19ee5121eb49bdeb020f39`
and supersedes its lifecycle, publication, retry, schema, pricing, rollback, and
observability sections. It resolves H1-H4 and M1-M3 from independent review
`origin-main-c944-plan-r1-sol.md`, SHA-256
`247eedb98279dc60511f8276d01d8d7810901f073889ee47b9c490f2d5f8f339`.
All other r1 scope, acceptance remapping, non-goals, and qualification caveats
remain mandatory. Conflicted implementation remains blocked until an
independent GPT-5.6 Sol review of r1+r2 and test r5+r6 reports zero Critical,
High, and Medium findings.

## R2-01 — route-time freshness and historical settlement

Live authority ends at immutable route-snapshot creation. Promotion, positive
status refresh, retry authorization, and pre-dispatch routing compare the exact
current composite authority generation and reject stale prepared authority.
The route snapshot captures the selected member, row/rate material, all six feed
values when applicable, and their authenticated digests.

After routing, receipt verification, delayed settlement, reconciliation, and
replay use only the immutable stored route snapshot, its schema-specific
canonical JSON/digest, the stored billing snapshot, and the signed receipt tuple.
They never consult or repair from the current feed, index, candidate catalog,
rate card, or keyring. A request routed under generation G therefore remains
settleable within its existing receipt rules after G+1 publishes. A new request
presenting G after G+1 publishes is rejected before dispatch. Mutation of the
stored G snapshot is always rejected.

## R2-02 — complete publication and lock ownership

The coordinator owns a paid-admission publication epoch. Each epoch identifies:

- the exact four signed feed selections and derived artifact member index;
- the exact Tier2 default publication generation and selected catalog pointer,
  row identity, revision, digest, eligibility, and model key;
- the exact effective billing configuration generation and persisted billing
  snapshot/rate row selected by that model key; and
- the WS admission-authority generation that installs the preparer/commit guard.

Tier2 and billing remain separately owned components; their immutable selected
values and generations are captured and pinned into the prepared authority.
They are not copied into a second mutable catalog. A prepared commit compares
every captured generation, pointer identity, row/rate value, and feed/member
value before the guarded SQLite CAS.

The single acquisition order is:

1. WS admission-authority publication (`modelAdmissionAuthorityMu`);
2. WS session publication (`sessionPublicationMu`);
3. selected session writer (`session.writeMu`);
4. pool provider pin/registry owner;
5. buyer artifact/feed publication (`autotuneFeedsMu`);
6. buyer billing publication (`billingMu`);
7. billing settlement configuration (`settlementMu`);
8. Tier2 default publication (`defaultPublicationMu`);
9. selected Tier2 catalog owner (`catalog.mu`);
10. guarded SQLite append/CAS.

All release occurs in reverse order. Try-lock failure, expiry, cancellation, or
comparison failure releases every acquired owner and emits no positive event.
No callback takes an earlier owner while holding a later owner.

Boot/reload first disables paid admission and increments the WS authority epoch.
It then validates and publishes Tier2, billing, the four feeds, and the member
index through one coordinator orchestration function. Only after all stages
succeed does it install a preparer bound to the exact completed epoch. Failure
leaves paid admission disabled and preserves the last immutable status as
historical only. Existing component setters remain package-internal, but every
boot/reload production call site and test helper capable of creating positive
authority routes through this orchestrator; direct setters cannot install a
positive WS preparer. The implementation inventories every setter/call site and
tests each failed stage plus concurrent invocation under `-race`.

## R2-03 — private pending-offer journal v2

`byom_pending_offer.v2` is a closed, bounded, private record. It retains the v1
generation and signed envelope and adds an optional `artifact_file_identity`.
For a GGUF protected tuple this field is mandatory and contains the exact
original `BYOMArtifactFileIdentity`, locator digest, algorithm, and computed
digest returned by the original submit-time opened-descriptor validation. It
remains only in the existing 0700/0600 local journal, is never sent on the wire,
and is never logged. Unknown/partial fields fail closed.

Original submission persists v2 atomically with the protected tuple before the
network mutation. Retry resolves and opens the current blob through the same
no-follow store path, compares device, inode, size, high-precision mtime,
resolved locator and locator digest with the recorded identity, recomputes the
complete digest under the existing deadline, and requires equality with the
protected tuple. Only then does it create a fresh timestamp, nonce,
idempotency key, and signature and post the retry.

Legacy v1 GGUF records lack this proof and cannot retry. They remain readable
for status/terminal reconciliation and explicit withdrawal; after coordinator
truth is terminal and the v1 record is reconciled, a new offer may be created
from fresh evidence. V1 non-GGUF records retain their existing protected-tuple
retry behavior. The advisory digest cache never supplies mutation authority.

## R2-04 — snapshot schema and canonical digest compatibility

Add an independent artifact-extension discriminator
`artifact_admission_schema`. It does not replace or change the gateway's
`route_snapshot_policy_version`.

Closed classes are:

- **No extension:** discriminator and every artifact-extension key absent.
- **Historical c944:** discriminator absent and exactly the historical six-key
  set, including `artifact_candidate_catalog_sha256`.
- **Canonical Build 1:** discriminator exactly
  `macprovider.artifact_admission.v2` and exactly the canonical six-key set,
  including `candidate_catalog_sha256`.
- **Future/invalid:** unknown discriminator, duplicate JSON keys, both sixth-key
  spellings, partial set, or other artifact-extension keys; reject.

Use the repository's bounded strict JSON path, extended to detect duplicate
keys before struct decoding. For a historical row, reconstruct the exact legacy
`RouteSnapshot.Value()` key shape, RFC8785-canonicalize it, require byte equality
with stored `route_snapshot_canonical_json`, and require its SHA-256 to equal
`route_snapshot_digest`. Canonical v2 uses the same process with its new value
shape. Raw `route_snapshot_json` is decoded input and is never itself the digest
preimage. Settlement never rewrites an old row or reconstructs missing evidence
from current feeds.

Golden fixtures include canonical bytes and digests produced by unmodified c944
code, canonical v2, no extension, duplicate keys, both spellings, partial data,
corrupt stored canonical bytes, changed digest, and unknown version. A migration
is additive schema support, not a data rewrite.

## R2-05 — exact pricing identity

- Canonical member algorithm/hash is the provider wire and settlement identity.
- Candidate row `model_id`, row hash, and revision are the Tier2/served-row
  identity and eligibility material.
- The pair-resolved candidate row `model_key` is the only key accepted by signed
  and effective rate-card lookup APIs.
- Artifact ID plus feed provenance proves membership.
- A provider-asserted catalog/model key is only an equality check against the
  coordinator result and never selects a row or price.

Tests install malicious, otherwise-valid rate rows under the model ID and
artifact ID and prove neither can be selected. Receipt price must equal the
persisted billing snapshot selected with the coordinator-resolved model key.

## R2-06 — durable recovery and replay workspace

Before replay, freeze the current worktree and create a local checkpoint commit.
After secret/path hygiene and an enumerated intended-file manifest pass, create:

- named ref `refs/codex/backups/product-build-1-pre-c944/<checkpoint-sha>`;
- bundle `/Users/augstar/.codex/recovery/macprovider/build1-c944/<checkpoint-sha>.bundle`;
- private tracked patch, untracked-file manifest, and SHA-256 manifest under the
  same 0700 recovery directory, with files 0600.

The recovery manifest excludes `.build`, derived data, temp logs, operator
secrets, payout material, private keys, environment files, and unrelated
evidence. Verification checks the bundle and resolves the named ref to the exact
checkpoint SHA without printing sensitive contents.

Create fresh hidden worktree
`/Users/augstar/.codex/worktrees/macprovider/product-build-1-c944` on branch
`codex/product-build-1-c944` from current `origin/main`. Replay/cherry-pick the
checkpoint there and resolve the approved conflicts. Leave the original Build 1
worktree frozen for comparison. Restore uses either the named ref in a fresh
worktree or the verified bundle if the ref is absent. Before review, assert that
`git log origin/main..HEAD` and the complete file manifest contain only intended
Build 1 changes; remove generated runtime artifacts from the landing diff.

## R2-07 — runtime observability

Use stable low-cardinality reason codes and counters:

- `artifact_authority_publish_failed`
- `artifact_authority_generation_stale`
- `artifact_member_stale`
- existing `artifact_identity_index_stale`
- `artifact_snapshot_legacy_verified`
- `artifact_snapshot_schema_unsupported`
- `artifact_snapshot_corrupt`
- `gguf_retry_identity_changed`
- `gguf_retry_legacy_proof_missing`

Publication/stale logs may include numeric old/new generations, release ID, and
non-sensitive digest identifiers already treated as public authority metadata.
Snapshot logs include schema class and reason. Retry logs include only reason and
candidate state; they never include a local path, inode, provider secret, signed
envelope, key, or private journal bytes. Each failed rebuild emits one bounded
failure signal, not one per member. Tests assert exactly one signal for failed
publication, stale commit, legacy/new decode selection, unsupported/corrupt
schema, changed retry identity, and missing v1 proof, and assert forbidden local
material is absent. Acceptance evidence records counters/reasons without
claiming deployment.

## R2 stop conditions

Conflict resolution may start only after the exact r1+r2 plan bundle and r5+r6
test bundle pass the independent gate. Reconciliation stops on an ambiguous
historical digest, unowned setter, lock-order inversion, missing recovery
artifact, or inability to preserve c944 member settlement and Build 1 authority
together. Such a stop is a named implementation blocker, never a passed test.
