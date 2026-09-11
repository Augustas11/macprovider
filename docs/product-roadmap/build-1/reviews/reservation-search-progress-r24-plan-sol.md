# Build 1 reservation search progress R24/R30 — independent adversarial plan review

Date: 2026-09-11. Reviewer: native GPT-5.6 Sol, high reasoning.

## Verdict

**REQUEST CHANGES. Architectural status: BLOCK.**

Exact finding count: **0 Critical, 4 High, 1 Medium, 0 Low**.

R24/R30 do not meet the mandatory zero-Critical/High/Medium reservation gate.
No Swift, C, SQLite/VFS, custody, serving, replacement, or GC implementation is
authorized from this review. This review changes no source, test, SPEC, release,
deployment, or operator-secret file.

## Frozen inputs and independent checks

- Reviewed commit:
  `ca0638df84e01ec44c76481e08cd441abeccd83e`.
- Prior failed review commit:
  `a7a13dfe52db450c786ab36d8608cb1a9eeccc70`.
- Frozen prior review SHA-256:
  `09b93232b98287ce3623e88a877f13c00949a2ec968d7afe741d31f13430c199`.
- R24 SHA-256:
  `9bbaf6ad3edcfe3cbab33da045914fa5a52f4f209f2dc9ee7cd2cb6589eb5321`.
- R30 SHA-256:
  `6d5586836618a5d4b110a4f393e9368c7646141149c6998e87d371027ba0783f`.
- R23 Appendix A is 43,652 bytes and hashes to
  `70b34abd8229e8a90bd45e0de6c283d33bf1af96a096193d9301e37dba7bf81f`.
  The exact SQL created 23 tables and 11 non-auto indexes in an in-memory
  SQLite database. Its unchanged `protocol_meta` schema has no raw bootstrap
  nonce, bootstrap-intent SHA, or database-identity column.
- `git diff --check a7a13dfe ca0638df` passed. The reviewed commit changes
  exactly R24 and R30.
- R24 Appendix A's Python generator produced 495 records and 68,992 canonical
  bytes, byte-identical to Appendix B, SHA-256
  `d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`.
  A separate Node generator using independently expressed ranges and field
  mappings produced the same 495 records, bytes, and digest.
- A separate Node tuple encoder reproduced the 27,602-byte R23 Appendix C body
  SHA `c7b3594a76d118dd766082411407e267fa850a6364985422b8a9b0e64eaf6ae6`,
  1,309-byte R24 dispatch SHA
  `af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`,
  and 97,959-byte semantic tuple SHA
  `0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`.
  It also reproduced the 305-byte bootstrap, 344-byte database, path, and
  333-byte artifact-lock golden vectors published by R24.
- The exact Appendix A plus permanent authorizer rejected `ANALYZE` and
  `PRAGMA optimize`, and created no `sqlite_stat*` object. This closes the prior
  ANALYZE contradiction.
- All 191 dirty production Swift files parsed successfully with
  `xcrun swiftc -frontend -parse`; their sorted path manifest hashes to
  `ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`.
  Dirty source and callsites were inspected but not modified.
- Environment: macOS 26.5 build 25F71, Darwin 25.5.0 arm64; Python 3.14.7
  with SQLite 3.53.4; Swift 6.3.3, swift-driver 1.148.6.
- Independent code-review and architecture lanes both converged on the exact
  four High and one Medium findings below. The code lane returned REQUEST
  CHANGES; the architecture lane returned BLOCK.

### Executable counterexamples

Creating the first leaf in a captured directory retained the directory inode
but changed both `mtime_ns` and `ctime_ns`. R24's inherited complete file
identity therefore changed under R24's own valid lock-creation operation.

The unlink/recreate oracle held a shared `flock` on device/inode
`[16777229,124847731]`, replaced the pathname with
`[16777229,124847732]`, and acquired an exclusive `flock` on the replacement.
This confirms the need for inode identity, but does not repair the creation and
parent-identity contradictions below.

## Critical (0)

None.

## High (4)

### R24-PLAN-H1 — `lock-create-pending` requires an identity before its leaf exists

**Evidence.** R24 lines 232-239 require the custody intent to enter
`lock-create-pending` before the first `openat(...O_CREAT|O_EXCL...)` creates the
leaf. Lines 255-262 define `artifact_lock_identity_sha256` with the leaf's full
file-identity digest. Lines 316-320 nevertheless make that value non-null in
`lock-create-pending` and every successor. R30 lines 101-107 preserves the same
order, and lines 125-131 calls the pre-lock null permitted only before
`lock-create-pending`.

**Consequence.** The required durable pre-create intent cannot be encoded: its
mandatory leaf identity does not exist yet. An implementation must either
invent a digest, create before publishing the required intent, or violate the
codec null rule.

**Required correction.** Permit null lock identity in an exact durable
pre-create phase, then add a distinct post-create phase that captures and binds
the leaf identity after creation and fsync. Specify crash recovery and complete
codec vectors at both boundaries.

### R24-PLAN-H2 — valid leaf creation invalidates the parent identity R24 freezes

**Evidence.** R24 lines 216-224 records the `artifact-locks` directory's
complete R23 file-identity digest and protects on any identity change. It
revalidates that digest before and after every leaf open. R23 lines 1082-1088
include mtime and ctime seconds and nanoseconds in the complete identity. R24
lines 233-248 then creates and fsyncs a child leaf before recording its identity.
The Darwin counterexample above confirms that child creation changes the
parent's mtime and ctime while retaining its inode.

**Consequence.** The first legitimate lock leaf changes the frozen parent
identity. If the implementation refreshes the parent digest, every previously
recorded artifact-lock identity becomes stale because lines 255-262 include the
parent digest. If it does not refresh, the first post-create revalidation
protects the authority. The plan cannot publish and retain its 1,024 lock
objects under its own rules.

**Required correction.** Define a stable parent placement identity that omits
metadata changed by authorized child operations, or define a serialized parent
generation/receipt that advances on each permitted mutation and updates all
dependent bindings without weakening rename, replacement, device, or inode
checks. Add first-through-1,024th creation and restart vectors.

### R24-PLAN-H3 — the bootstrap identity lifecycle depends on an intent R23 deletes

**Evidence.** R24 lines 119-127 puts the raw nonce and all identity operands in
the first durable bootstrap intent. Lines 169-172 say that immutable intent
retains the nonce and operands; lines 185-187 bind its SHA into every supported
offline backup. R24 does not replace R23's unchanged B6a rule: R23 lines
168-179 deletes the exact bootstrap intent and fsyncs its directory after
selection. The unchanged R23 Appendix A `protocol_meta` declaration stores
`bootstrap_id` and source/schema/registry/semantic values but no raw nonce or
bootstrap-intent SHA.

**Consequence.** After B6a/B8, the selected authority no longer has the object
that R24 requires for recomputation, backup-envelope construction, and restore
proof. The published lifecycle cannot distinguish preservation from rotation
using its stated durable data.

**Required correction.** Either retain the selected nonce-bearing intent for
the database lifetime, or atomically persist the nonce and intent digest in a
specified selected-database metadata object before B6a. If SQL changes, publish
the revised exact DDL/schema hash/counts and tests. Define deletion, backup,
restore, rebootstrap, and replacement vectors from the retained bytes.

### R24-PLAN-H4 — the provider-UID broker cannot open root-owned lock objects

**Evidence.** R23 lines 70-77 defines `CatalogAuthorityBrokerV5` as a
provider-UID launch agent and makes it the catalog/custody caller. R24 lines
216-220 makes `artifact-locks` root-owned mode 0700. Lines 242-248 makes each
leaf root-owned mode 0600 and assigns its direct open/stat/flock work to the
broker. Lines 291-300 likewise assigns direct opens to replacement and GC. A
provider-UID process cannot traverse the root-owned 0700 directory or open the
root-owned 0600 leaf. R23's separate root daemon custody creation does not
specify an authenticated lock-open or descriptor-transfer protocol.

**Consequence.** A literal provider-UID broker cannot execute the mandatory
lock lifecycle. Running it as root contradicts the frozen actor boundary;
relaxing ownership contradicts R24; accepting a caller FD contradicts the
direct-open and identity rules.

**Required correction.** Choose one authority model. Either make lock objects
provider-owned and keep all direct opens in the broker, or assign root-owned
creation/opening to a named root daemon and specify authenticated XPC request,
audit-token binding, descriptor transfer, identity revalidation, lifetime,
restart, denial, and confused-deputy tests.

## Medium (1)

### R24-PLAN-M1 — the readiness migration still omits live durable-read callsites

**Evidence.** R24 lines 345-367 adds six readiness files/types and bans
post-B8 catalog/readiness/action/economics calls to durable-root URL,
containment, and verifier operations outside the broker. R30 lines 145-169
requires call-edge enumeration only for the named inspection/discovery surface,
four consumers, and app snapshot consumers. Current dirty production Swift has
additional direct durable-root authority in `MacProviderCLI.swift` lines
895-923 and 939-945, which validates containment and computes canonical
artifact hashes during load-path resolution. `AutotuneRecommend.swift` lines
3707-3778 and its verifier path directly resolve, validate, hash, inspect, and
adopt durable artifacts. R23 Appendix E lines 1414-1416 classifies only those
files' direct `adoptVerifiedStaging` calls, not these reads and hashes.

**Consequence.** The generated target inventory can pass while CLI/autotune
paths still directly inspect durable bytes after B8. R24 supplies no explicit
broker ownership, dead-code proof, or runtime prohibition for these callsites,
so they can bypass the single snapshot/readiness authority or remain ambiguous
during implementation.

**Required correction.** Add every `MacProviderCLI.swift`,
`AutotuneRecommend.swift`, `ModelArtifactVerifier`, and durable-store callsite to
the normative pre/post-B8 inventory. Classify each as broker-owned,
provider-owned staging-only, or unreachable after B8. Add AST/SIL and runtime
fault tests proving no post-B8 CLI/app/autotune path opens, stats, enumerates,
hashes, or inspects durable/custody bytes outside the broker.

## Low (0)

None.

## Prior R23 finding disposition

| Prior finding | R24/R30 disposition |
|---|---|
| R23-PLAN-H1 complete 495-record registry | **Closed.** Two independent generators reproduce the same complete bytes and published digest. |
| R23-PLAN-H2 database identity definition | **Open.** R24 defines reproducible tuples, but H3 makes the selected lifecycle and backup/restore inputs unavailable. |
| R23-PLAN-H3 canonical artifact lock object | **Open.** R24 defines path and inode binding, but H1, H2, and H4 make creation and operation impossible. |
| R23-PLAN-M1 Swift readiness inventory | **Open.** R24 closes the originally named omissions but leaves the M1 direct durable-read paths unclassified. |
| R23-PLAN-M2 `ANALYZE` contradiction | **Closed.** R24/R30 now permanently deny it and qualify the as-grown database. |
| R23-PLAN-L1 wrong correction cross-references | **Closed.** R24/R30 replace the mappings with exact tests. |

## Accumulated-plan assessment

The exact registry, dispatch, semantic tuple, database and artifact-lock golden
vectors are reproducible. R24/R30 also repair the ANALYZE gate and prior
cross-references. The inherited single broker, rollback-journal VFS controls,
main authority lock, supervisor/request framing, staging/custody evidence,
serving records, GC codec binding, and migration fail-closed rules remain
structurally specified where R24 does not amend them. No additional gate-level
finding was found in those retained sections.

Those strengths do not cure the four contradictory identity/actor lifecycles
or the incomplete Swift authority inventory. R24/R30 must be revised and the
complete accumulated reservation plan independently reviewed again to exact
**0 Critical, 0 High, 0 Medium** before implementation resumes. Physical MLX
lazy-read qualification remains a later implementation acceptance test; it
cannot waive this plan gate.

No `d-inference` source was inspected.
