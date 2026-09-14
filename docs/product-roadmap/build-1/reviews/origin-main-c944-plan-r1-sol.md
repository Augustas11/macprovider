# Independent GPT-5.6 Sol review — Build 1 c944 reconciliation plan r1

Date: 2026-09-10  
Reviewer: independent GPT-5.6 Sol plan-verification lane  
Verdict: **FAIL — implementation remains blocked**  
Finding count: **0 Critical, 4 High, 3 Medium, 0 Low, 2 Info**

## Reviewed inputs

- Old Build 1 base: `914f7cafcdbcfc1805a10f4f34167218341d5587`
- New upstream base: `c9445561e4fe00a073926ff2ab0fdb0536d00e37`
- Plan: `origin-main-c944-reconciliation-addendum-r1.md`, verified SHA-256
  `353fdb88df209785b44ea3c7358fa46b5e6aca608d19ee5121eb49bdeb020f39`
- Test specification: `test-spec-r5-c944-compatibility.md`, verified SHA-256
  `75c942bba7bad61297de5a2567eb06ad436e1944522437f647135023136e6576`
- Supporting reconciliation analysis: `origin-main-c944-reconciliation-sol.md`,
  verified SHA-256
  `41ee62f8ea0962c75667f2f7b79fb06ac4d192a7d4fe8d87ae7eb5c5039a8e64`
- Active slice-4 overlap assessment: `active-byom-slice4-overlap-sol.md`,
  verified SHA-256
  `46b8764ff797d1c0137a2d4704569337fd600885af982bf866dcdca147e665c5`

The review inspected the c944 implementation with `git show`, the complete
dirty Build 1 worktree at old base 914f7, the normative c944 SPEC-010 R007 and
SPEC-047 R003/R004/R006 clauses, and the proposed acceptance matrix. This was a
read-only plan review; no implementation tests were run because the gate asks
whether the plan and tests are safe and sufficient before conflict resolution.

## Gate result

The zero-Critical/High/Medium requirement is not met. The plan must be revised,
the companion test specification must be revised where identified below, and a
fresh independent gate must review the exact new hashes. None of the following
findings may be dropped, weakened, or treated as implementation-time discretion.

## Findings

### H1 — Live generation comparison at settlement violates immutable historical settlement

**Severity:** High

**Evidence:** The plan says that “commit, status refresh, route snapshot, retry,
and settlement compare the same generation”
(`origin-main-c944-reconciliation-addendum-r1.md:76-78`). C944 SPEC-010 R007(d)
instead requires settlement to re-verify the six values against the immutable
snapshot and explicitly forbids consulting a current feed, manifest, or keyring
to repair it (`c944:specs/SPEC-010-model-catalog.md:1128-1136`). C944’s loader
reconstructs the snapshot-carried fields and recomputes the stored digest; it
does not compare a current feed generation
(`c944:phase4-coordinator/internal/billing/settlement_receipts.go:784-889`). The
test spec does not contain the decisive positive case: route under generation G,
publish G+1, then accept a valid in-deadline receipt/replay for the immutable G
attempt. Its delayed/replayed wording says only that receipts are rejected
(`test-spec-r5-c944-compatibility.md:68-74`).

**Consequence:** A valid request routed under G can be denied settlement after a
routine feed reload to G+1. That changes already captured money-path truth and
violates c944. Conversely, implementing “same generation” loosely could tempt a
settlement-time current-feed repair, which c944 forbids.

**Required correction:** Split the lifecycle contract explicitly. Promotion,
status refresh, retry authorization, and pre-dispatch route admission must reject
a stale prepared/current generation. The route snapshot must capture the exact
immutable generation content/digests, but receipt verification and replay must
use only the stored snapshot, its schema-specific canonical bytes/digest, the
captured billing snapshot, and the receipt tuple. They must never require the
live generation to remain current. Add positive and negative tests that route
under G, publish G+1, settle/replay the valid G attempt successfully, reject a
mutated G snapshot, and reject a new pre-dispatch attempt that still presents G.

### H2 — The stated publication and lock model omits mutable authorities acquired by the positive commit

**Severity:** High

**Evidence:** The plan’s generation contains four feed selections and the member
index, and its lock order names only authority publication, session publication/
writer, pool, then store CAS (`origin-main-c944-reconciliation-addendum-r1.md:69-81`).
The dirty Build 1 positive guard actually acquires, after the WS/session/pool
locks, `autotuneFeedsMu`, `billingMu`, the billing store’s `settlementMu`,
`tier2.defaultPublicationMu`, and the selected catalog’s `mu` before the guarded
SQLite append (`phase4-coordinator/internal/ws/model_admission_authority.go:78-124`,
`phase4-coordinator/internal/buyer/model_admission_guard.go:47-106`,
`phase4-coordinator/internal/tier2/model_admission_guard.go:7-27`). The c944 reload
path independently publishes Tier2, billing config, WS catalog, buyer feeds, and
then the artifact index through existing setters
(`c944:phase4-coordinator/cmd/coordinator/main.go:3196-3266`; c944
`phase4-coordinator/internal/ws/server.go:554-580`). The proposed artifact-only
generation neither contains the exact Tier2 catalog pointer/material nor the
immutable billing config snapshot, and the plan does not say how legacy separate
setters are removed, encapsulated, or made incapable of bypassing the generation.
C944-04 asks only generic lock-order probes, not contention against every named
owner and setter (`test-spec-r5-c944-compatibility.md:47-55`).

**Consequence:** The implementation can still commit a member from one feed
generation with Tier2 row material or effective rates from another publication,
or deadlock/livelock under reload because the real lock graph was not selected
before editing. This is a positive-settlement authority race, not merely an
observability issue.

**Required correction:** Define the complete owner graph and one enforceable
global acquisition order for the WS authority, session publication, session
writer, pool, artifact/feed publication, billing publication, settlement config,
Tier2 default publication, Tier2 catalog, and SQLite CAS. State whether Tier2
material and the persisted billing snapshot are members of the immutable
authority object or separately captured/pinned values; either way, the exact
comparison and release order must be normative. Inventory every boot/reload/test
setter and either route it through the single publisher or make it impossible to
create paid authority while components disagree. Extend C944-04 with a
table-driven contention matrix covering every owner, failed billing/Tier2/feed
stage, every existing setter, and pin release on every failure path under
`-race`.

### H3 — Retry-time inode/path validation has no durable original identity to compare

**Severity:** High

**Evidence:** The plan requires retry to reopen the file and verify device,
inode, size, and digest (`origin-main-c944-reconciliation-addendum-r1.md:83-90`),
and C944-07 requires changed bytes, inode replacement, pathname replacement,
deadline expiry, and removal to fail (`test-spec-r5-c944-compatibility.md:76-83`).
The dirty journal record persists only `schema`, `generation`, and the signed
wire envelope (`phase3-binary/Sources/macprovider-cli/BYOMPendingOfferJournal.swift:11-15,99-120`).
That envelope carries artifact hashes but no local path, device, inode, mtime, or
locator (`phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:1024-1069`).
The retry runtime loads this record and current discovery, then builds a fresh
signed package while preserving the original artifact-hash tuple
(`phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift:1893-1913`). C944’s
`BYOMArtifactFileIdentity` and `BYOMArtifactEvidence` do contain path,
device/inode, size, high-precision mtime, and locator digest, but that evidence is
not in the Build 1 pending journal
(`c944:phase3-binary/Sources/macprovider-cli/BYOMArtifactDigest.swift:60-121`).
The discovery digest cache is explicitly advisory and cannot become mutation
authority (`c944:.../BYOMArtifactDigest.swift:235-280`). The plan also says
“reusing an offer signature,” although the current retry builder creates a fresh
signature.

**Consequence:** Digest recomputation alone cannot distinguish a same-byte inode
or pathname substitution. There is no authoritative original device/inode/path
value to satisfy the proposed comparison after restart. Treating the advisory
cache as that authority would weaken c944’s trust boundary. Existing v1 pending
journals also have no specified safe retry behavior.

**Required correction:** Define a closed private journal v2 (or an equivalently
atomic, strictly paired private record) that captures the original
`BYOMArtifactFileIdentity` and locator digest at the original submit, alongside
the protected offer tuple. Keep this local material out of the wire request. On
retry, resolve/open without following unsafe substitutions, compare the opened
descriptor’s full identity to the recorded identity, recompute the full digest
under the deadline, require it to equal the protected tuple, and only then
fresh-sign/post. Specify that legacy v1 GGUF journals lacking this proof cannot
retry and require an explicit safe reconciliation/new offer path. Revise the
wording and tests from “signature reuse” to preservation of the protected tuple
followed by fresh signing, and test v1/v2 restart behavior.

### H4 — The snapshot migration contract is internally contradictory and lacks a usable discriminator

**Severity:** High

**Evidence:** The plan correctly calls for a distinct historical decode and
digest-recompute path over `artifact_candidate_catalog_sha256`, but also says to
reject unknown schema versions without naming a route-snapshot or artifact-
extension schema field (`origin-main-c944-reconciliation-addendum-r1.md:58-67`).
The only version selected later is an admission-event schema
(`origin-main-c944-reconciliation-addendum-r1.md:92-96`). Both c944 and dirty
Build 1 retain `RouteSnapshotPolicyVersion = "spec022-prereq-v1"`; that field is
settlement policy and is consumed by the gateway, not an artifact-extension
schema discriminator (`c944:phase4-coordinator/internal/billing/route_snapshot.go:18-31`,
`phase5-gateway/internal/router/chat_proxy.go:73-80`). C944 computes the snapshot
digest from canonical JSON of `RouteSnapshot.Value()` and later decodes
`route_snapshot_json`, reconstructs the value, canonicalizes, and compares the
digest (`c944:phase4-coordinator/internal/billing/route_snapshot.go:102-156`;
`c944:phase4-coordinator/internal/billing/settlement_receipts.go:784-889`). The
test spec contradicts both c944 and the plan by rejecting a decode/remarshal
digest “in place of original-byte verification”
(`test-spec-r5-c944-compatibility.md:57-66`). The stored raw
`route_snapshot_json` was never the digest preimage; the separately stored
canonical JSON was.

**Consequence:** There is no unambiguous implementation target for canonical,
historical, future-unknown, and no-extension records. Hashing the raw stored JSON
would reject valid c944 rows; silently using key presence as an undocumented
schema can accept ambiguous future records; reusing the policy version for this
purpose creates a coordinator/gateway rollout problem.

**Required correction:** Specify an independent artifact-extension/snapshot
schema discriminator for new records, with an explicit legacy classifier for
c944 rows, closed allowed key sets, duplicate-key rejection, all-or-none rules,
and exact canonical preimage algorithms for each class. Preserve c944 by strict
decode into its historical value shape, reproduce its legacy canonical JSON,
compare that byte-for-byte with `route_snapshot_canonical_json`, and compare its
SHA-256 with `route_snapshot_digest`; do not hash raw `route_snapshot_json`.
Define the no-extension and future-version behavior without changing the
gateway policy-version contract. Correct C944-05 accordingly and add golden
canonical bytes/digests from an actual c944 database row plus canonical-new,
no-extension, duplicate-key, both-spelling, partial, corrupt-canonical, and
unknown-version fixtures.

### M1 — The identity section assigns rate lookup to two different domains

**Severity:** Medium

**Evidence:** The plan says the candidate row model ID/hash is used for “Tier2
eligibility and rate lookup,” then separately says the economics `model_key`
selects the authoritative rate (`origin-main-c944-reconciliation-addendum-r1.md:43-52`).
C944 SPEC-010 R007(c) states that row model ID is the served/routed identity, the
row key is a separate namespace, and pricing remains model-key scoped
(`c944:specs/SPEC-010-model-catalog.md:1115-1127`). Dirty Build 1 resolves the
candidate row by model ID, resolves both signed and effective rate rows by the
resolved key, and stores that key in `CatalogModelKey`
(`phase4-coordinator/internal/buyer/model_admission_authority.go:99-118,142-166`).
C944-02’s phrase “row/model-key values” does not state which value each lookup
must use (`test-spec-r5-c944-compatibility.md:30-36`).

**Consequence:** A conflict resolver can implement price selection by row model
ID/hash or allow a provider assertion to choose a rate, while still claiming to
follow one of the plan’s bullets. A fixture with distinct values detects some
swaps but does not resolve the normative ambiguity.

**Required correction:** State one exact mapping: the member algorithm/hash is
wire and settlement identity; candidate row `model_id` plus row hash/revision is
the Tier2 material/served-row identity; the pair-resolved row `model_key` is the
only signed/effective rate-card lookup key; artifact ID and feed provenance prove
membership; provider-asserted key is advisory equality only. Make C944-02 assert
each lookup API/key separately and include a malicious rate row under the model
ID and artifact ID to prove neither can be selected.

### M2 — The rollback anchor is not durably named and the procedure mutates the only recovery checkout

**Severity:** Medium

**Evidence:** The plan creates one local checkpoint commit and rebases that same
dirty Build 1 worktree, calling the pre-rebase commit the rollback anchor
(`origin-main-c944-reconciliation-addendum-r1.md:127-135,195-202`). After a
successful rebase, the branch points at rewritten commits; unless another ref or
bundle names the original checkpoint, the alleged anchor is reachable only by
reflog and eventual object retention. `git rebase --abort` helps only while a
rebase is active. The supporting independent analysis prescribed freezing a
patch, untracked manifest, and checksums in private recovery storage before
touching the dirty tree and recommended replay from a clean c944 base
(`origin-main-c944-reconciliation-sol.md:445-459`). The repository’s worktree
contract also prefers fresh isolated task worktrees for write-heavy work.

**Consequence:** A semantic problem found after rebase completion lacks the
promised deterministic rollback path, and editing the sole dirty checkout makes
forensic comparison against the original Build 1 state harder. A giant
checkpoint can also accidentally carry review/log artifacts into the landing
diff unless its contents are enumerated.

**Required correction:** Before replay, record the tracked patch, untracked
manifest and hashes in private recovery storage; create a named local backup ref
or bundle for the exact checkpoint SHA; and perform the c944 replay in a fresh
hidden task worktree while leaving the original frozen checkout untouched. Name
the rollback ref/SHA and exact restore procedure. Add a preflight assertion that
the checkpoint manifest contains no secrets or out-of-scope generated evidence,
and a post-replay assertion that `origin/main..HEAD` contains only intended Build
1 landing changes.

### M3 — Runtime observability is not specified or tested for the new fail-closed boundaries

**Severity:** Medium

**Evidence:** The “observability” section records reconciliation commands and
file hashes only (`origin-main-c944-reconciliation-addendum-r1.md:195-202`). It
does not define runtime signals for failed composite rebuild/publication,
generation mismatch, stale selected member/provenance, historical-vs-new
snapshot decode, unsupported schema, or retry file-identity failure. C944-04 and
C944-05 assert functional rejection but no stable reason classification or
operator-visible signal (`test-spec-r5-c944-compatibility.md:47-66`). C944 already
uses an explicit `artifact_identity_index_stale` event for one upstream failure
class (`c944:phase4-coordinator/internal/ws/server.go:1402-1408`), establishing a
neighboring operational pattern.

**Consequence:** A safe fail-closed implementation can silently remove paid
capacity or strand retries after reload/migration, while operators cannot tell a
mixed generation, schema incompatibility, stale member, billing mismatch, and
local file substitution apart. That weakens rollback decisions and makes the
new guarantees difficult to verify outside unit tests.

**Required correction:** Define stable bounded reason codes and low-cardinality
logs/counters for each new rejection/publication outcome, including old/new
generation identifiers or non-sensitive digests where safe. Require tests for
one emitted signal per failed rebuild, stale prepared commit, historical/new
decode path, unsupported/corrupt schema, and retry identity failure, with no
local path or sensitive material logged. Include these signals in the final
reconciliation evidence and later rollout runbook; keep the present no-deploy
scope unchanged.

## Confirmed points

### I1 — The plan does not assume unlanded slice 4

**Severity:** Info

The plan explicitly excludes `feat/byom-v02-slice4-decision-path` in the trigger
contract, normative compatibility section, and non-goals
(`origin-main-c944-reconciliation-addendum-r1.md:15-16,38-39,204-207`). This
matches the independently hashed active-slice assessment: slice 4 remains
unlanded and cannot be treated as current authority. No plan or acceptance step
was found that depends on its runtime implementation.

### I2 — Provider pointer ownership and preparation UX have the right direction

**Severity:** Info

The deep-copy and complete-comparison requirement for `ArtifactIdentity`, nested
member/provenance, and `IdentityPin` is concrete and is paired with mutation and
replacement tests (`origin-main-c944-reconciliation-addendum-r1.md:83-87`;
`test-spec-r5-c944-compatibility.md:38-45`). The preparation scope also
truthfully limits the local command to supported primary MLX without narrowing
the coordinator’s R007 member contract, and C944-08 tests the separation
(`origin-main-c944-reconciliation-addendum-r1.md:92-99`;
`test-spec-r5-c944-compatibility.md:85-92`). These decisions should remain in the
revision.

## Required disposition

Revise the plan and test specification to close H1-H4 and M1-M3. Preserve the
confirmed c944 member model, six-field all-or-none evidence, complete provider
snapshot ownership, primary-MLX preparation scope, qualification caveats, and
slice-4 exclusion. The next gate must review the entire revised artifacts rather
than a finding-only patch and must again require zero Critical, High, and Medium.
