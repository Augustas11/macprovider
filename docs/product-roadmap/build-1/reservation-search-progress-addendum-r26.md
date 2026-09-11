# Build 1 reservation search progress addendum R26

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

R26 corrects the exact rejected R25/R31 candidate. R26 and R25 are read
together. R26 replaces R25 sections 2.2, 3, 5.2 through 5.3, and 7 wherever
this document speaks; every other R25/R24/R23 requirement remains mandatory.
R32 replaces R31 only where R32 says so and otherwise carries every retained
R31/R30/R29 test forward. No rejected text overrides an R26 rule.

The exact reviewed parent is
`40d159d9b27e2a31b746ea3821f4bf6204081e5e`. The frozen failed review is
`docs/product-roadmap/build-1/reviews/reservation-search-progress-r25-plan-sol.md`,
SHA-256 `b14dcf4546c0208514141d1b1730baef1885219b5840bd7290d8d187232bcb5a`.
It reviewed R25 SHA-256
`75d7ae4cc0dabe7e8f22a6ca1ba4bff4a0338a72fc49a042c59d6a087787d9d2`
and R31 SHA-256
`7a3995baa5c5d89653176b3b3598e41d63d2d7d2a4b30b09188ef4818c345641`
and reports exactly 0 Critical, 4 High, 1 Medium, and 0 Low findings.
This author slice changes only R26 and R32. It changes no Swift, C, test, SPEC,
schema source, release, deployment, operator-secret, or d-inference file.

## 1. Fresh source reconciliation and exact dispositions

The review fetched `origin/main` at
`7c0aad111e44cb320641bcefae3bf56851e9aaaa`. That commit changes only the two
SPEC-039/FR-PKV10 prompt files under `audits/_prompts/`. It changes no Build 1
catalog, custody, reservation, CLI, app, schema, or test source and therefore
does not alter this correction. During R26 authoring the local remote-tracking
ref advanced first to `44df935cbbe10e194cfffdc9def3f454de464761`, which
implements an inert SPEC-039 paged-KV extraction primitive, and by the final
author check to `7128d1206afcf3cc857479e1d776ddc4899b020a`, which adds
SPEC-038/039 execution prompts plus a continuous-batching runbook change. Their
changed paths do not overlap Build 1 catalog/custody/reservation code or these
artifacts. Any later source/toolchain change still reopens the
postimplementation Swift inventory and complete-diff audit.

| finding | exact R26 correction | exact R32 proof |
|---|---|---|
| R25-PLAN-H1 root-owned retained intent has no executable path | one root daemon owns the registered intent root and is the sole creator, reader, prefix publisher, fsyncer, exporter, offline restorer, and retire/delete actor; every request uses the R25 public Mach-audit-bound authenticated connection, fixed operands, derived path, and a signed receipt | R32-03/R32-04 |
| R25-PLAN-H2 selected format omits intent SHA | selected format version 6 is one closed JCS object containing the intent SHA, database identity/generation, and source index needed for direct root lookup; B7 stores its exact SHA and B8 publishes only those bytes | R32-05 |
| R25-PLAN-H3 broker is assigned a root-owned worker record | the root daemon is the only creator, successor writer, heartbeat writer, terminal writer, and deleter of direct `serving-workers` records; the broker owns only SQLite CAS decisions and receives a durable daemon record SHA | R32-06 |
| R25-PLAN-H4 undefined post-B8 R4 rollback | B8 is irreversible; R4 is authoritative only before the format-v6 parent fsync/reopen decision, while every selected failure uses protection, same-version restore, or fresh forward replacement | R32-07 |
| R25-PLAN-M1 unreachable 65,536-byte legal intent | schema v26 admits exactly the sole 603-byte canonical `bootstrap_intent_v2`; an exact maximum vector is constructible, every other length and encoding rejects, and storage accounting uses 603 | R32-02/R32-04/R32-08 |

No finding is downgraded, waived, or answered by weakening acceptance. The
implementation gate remains closed until an independent native GPT-5.6 Sol
review of the exact R26/R32 byte hashes reports zero Critical, High, and Medium
findings.

## 2. Exact schema v26 and unchanged registries

### 2.1 Machine-exact derivation

Schema v26 is derived from the exact R25 44,213-byte SQL stream, SHA-256
`2bcde8dd97fa1cb063ad09b41db8b895ec64cf6fa2fabd38b15c4d1dc671547e`,
by four ordered byte transformations, each required to match exactly once:

1. replace `PRAGMA user_version=25;\n` with
   `PRAGMA user_version=26;\n`;
2. replace `schema_version INTEGER NOT NULL CHECK(schema_version=25)` with
   `schema_version INTEGER NOT NULL CHECK(schema_version=26)`;
3. in `bootstrap_authority`, replace
   `id INTEGER PRIMARY KEY CHECK(id=1),database_instance_nonce` with
   `id INTEGER PRIMARY KEY CHECK(id=1),database_generation INTEGER NOT NULL CHECK(database_generation BETWEEN 1 AND 9223372036854775807),database_instance_nonce`;
4. replace
   `CHECK(length(bootstrap_intent_bytes) BETWEEN 1 AND 65536)` with
   `CHECK(length(bootstrap_intent_bytes)=603)`.

The result is exactly 44,295 bytes, SHA-256
`b8c641a2f6ba8dfa73174c9bc04b5c2e552649a42fa0e09cbfb39b140bb3b86d`.
It executes under the qualified SQLite library with application ID 1297109587,
user version 26, 24 non-internal tables, and 11 non-auto indexes. The
`bootstrap_authority` row remains the same single immutable B3 row and B3 still
inserts exactly 1,560 logical rows. Its `database_generation` is 1 for the
first R4-to-V5 cutover and exactly the prior selected database generation plus
1 for forward replacement. The permanent authorizer denies later insert,
update, or delete.

The R24 registry, dispatch, and semantic bytes do not change. They remain
495 records / 68,992 bytes / SHA-256
`d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`,
1,309 bytes / SHA-256
`af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`,
and 97,959 bytes / SHA-256
`0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`.
R26 adds no transition record and changes no generated DML count. The schema
version, schema SHA, intent codec, and format fence change; the transition
machine does not.

### 2.2 Revised bootstrap and database identities

The bootstrap tuple retains R25's exact 12-field order and types, with domain
`macprovider-r26/bootstrap-id-v1`, the v26 schema SHA above, and
`user_version:u63=26`. With nonce bytes `00...1f`, source-index `11` repeated
32 bytes, source-rows `22` repeated 32, the frozen registry and semantic
digests, application ID 1297109587, page size 4096, journal `DELETE`, and
broker protocol 1, its preimage is 305 bytes and hashes to
`7d4fc8547fe7d914363b401991b60446681e7551f546328de5404f798490e39c`.

The database tuple retains R25's exact 13-field order and types, with domain
`macprovider-r26/database-identity-v1`, that v26 bootstrap ID, the v26 schema
SHA, and `user_version:u63=26`. With candidate-directory identity `33`
repeated 32 bytes, its preimage is 344 bytes and hashes to
`55f0a242ffab0afcdc03474f3d32a230d7e1000013375032561afeea53f3bca0`.
Schema-25, R25-domain, or old digest inputs reject. No mutable catalog
generation, path timestamp, main-file inode, or wall time enters either ID.

## 3. One executable privileged bootstrap-intent authority

### 3.1 Actors, root, path, and fixed codec

`CatalogAuthorityBrokerV5` remains the provider-UID single SQLite owner.
`TrustedCustodyDaemonV5` advances its protocol to 4 and becomes the sole owner
of bootstrap-intent filesystem operations. The installer creates and pins one
root-owned, root-only, mode-0700 directory beneath its already captured daemon
state root:

~~~text
bootstrap-intents/
~~~

The provider UID cannot traverse this directory. A leaf has the exact derived
relative path
`bootstrap-intents/<generation20>-<source-index-hex>.intent-v2`, where
`generation20` is the positive u63 database generation rendered as exactly 20
ASCII decimal digits with leading zeroes and `source-index-hex` is exactly 64
lowercase hexadecimal characters. The golden relative path is 113 bytes:

~~~text
bootstrap-intents/00000000000000000001-1111111111111111111111111111111111111111111111111111111111111111.intent-v2
~~~

Its R23 relative-path digest is
`b72d90e1fa0224f307bad960ed543e2b97b3e3c3d1a7f89f3b5ae78dfe827c75`.
The corresponding provider-owned candidate directory is the exact registered
path
`ModelTransactions/.retention-v2/.reservation-migration/retirement/v2-bootstrap/<generation20>-<source-index-hex>/`.
Before B7 the daemon direct-opens that path; after B7 it direct-opens the fixed
`ModelTransactions/.retention-v2/.reservation-migration/retirement/v2/`
successor and requires the same directory identity. Both present protects.
The daemon derives every component from typed operands after validating range
and canonical spelling. The RPC has no absolute path, arbitrary relative path,
open flag, mode, directory FD, rename target, or generic file operation.
The daemon opens its captured root and `bootstrap-intents` component-wise with
`openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`, byte-compares
`fstatat(...AT_SYMLINK_NOFOLLOW)` and `fstat`, and rejects replacement,
symlink, device, owner, mode, flags, ACL, or xattr drift.

`bootstrap_intent_v2` is canonical R23 `tuple_v1` with domain
`macprovider-r26/bootstrap-intent-v2` and exactly these fields:

| # | field | type | exact value or source |
|---:|---|---|---|
| 1 | schema | text | `bootstrap_intent_v2` |
| 2 | daemon_protocol_version | u63 | 4 |
| 3 | database_generation | u63 | 1...9223372036854775807 |
| 4 | database_instance_nonce | bytes | exactly 32 CSPRNG bytes |
| 5 | bootstrap_id | sha | recomputed R26 bootstrap ID |
| 6 | database_identity_sha256 | sha | recomputed R26 database ID |
| 7 | source_index_sha256 | sha | exact frozen R4 selector bytes |
| 8 | source_rows_sha256 | sha | exact frozen source-row transcript |
| 9 | schema_sha256 | sha | v26 schema SHA above |
| 10 | registry_sha256 | sha | frozen 495-record SHA |
| 11 | semantic_manifest_sha256 | sha | frozen semantic SHA |
| 12 | candidate_directory_identity_sha256 | sha | daemon independently opens the derived candidate directory and captures it |
| 13 | application_id | u63 | 1297109587 |
| 14 | user_version | u63 | 26 |
| 15 | page_size | u63 | 4096 |
| 16 | journal_mode | text | `DELETE` |
| 17 | broker_protocol | u63 | 1 |
| 18 | retention_policy | text | `database-lifetime` |
| 19 | intent_relative_path | bytes | exact 113-byte derived path |
| 20 | intent_path_sha256 | sha | R23 relative-path digest of field 19 |

Every legal value has exactly the same serialized shape: 603 bytes. There is
no extension, padding, optional field, alternate null, or ignored suffix. For
the golden inputs in section 2.2 and generation 1, the complete 603-byte tuple
hashes to
`f3ca14bafd5a3f53274068a8cacc5f761e7c55a8acab91a0a7df911e1db8301d`.
The independently reproduced full hex vector is:

~~~text
6d616370726f76696465722d7232362f626f6f7473747261702d696e74656e742d763200000000140300000013626f6f7473747261705f696e74656e745f76320100000000000000040100000000000000010400000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f067d4fc8547fe7d914363b401991b60446681e7551f546328de5404f798490e39c0655f0a242ffab0afcdc03474f3d32a230d7e1000013375032561afeea53f3bca006111111111111111111111111111111111111111111111111111111111111111106222222222222222222222222222222222222222222222222222222222222222206b8c641a2f6ba8dfa73174c9bc04b5c2e552649a42fa0e09cbfb39b140bb3b86d06d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63060640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee06333333333333333333333333333333333333333333333333333333333333333301000000004d50525301000000000000001a010000000000001000030000000644454c455445010000000000000001030000001164617461626173652d6c69666574696d650400000071626f6f7473747261702d696e74656e74732f30303030303030303030303030303030303030312d313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131312e696e74656e742d763206b72d90e1fa0224f307bad960ed543e2b97b3e3c3d1a7f89f3b5ae78dfe827c75
~~~

The decoder requires exactly 603 bytes before allocating or hashing. Lengths
0...602 and 604...65,536, a 65,537th byte, changed type/order/domain, alternate
integer width, uppercase path hex, noncanonical generation text, or equivalent
decoded values in different bytes reject before a file or SQL effect.

### 3.2 Exact authenticated operations and receipts

Every bootstrap RPC uses R25's single-use five-second challenge, public
NSXPC PID/UID comparison, `MACH_RCV_TRAILER_AUDIT`,
`kSecGuestAttributeAudit`, pidversion, boot session, designated requirement,
and approved broker cdhash. The daemon ignores caller assertions as authority.
Invalidation, replay, PID reuse, UID/team/cdhash/version mismatch, challenge
forwarding, or timeout denies before opening the intent root.

The closed interface has exactly five methods:

| method/domain | exact ordered `tuple_v1` request fields |
|---|---|
| create-or-resume / `macprovider-r26/bootstrap-intent-create-request-v1` | `schema:text, protocol:u63=4, request_uuid:uuid, database_generation:u63, source_index_sha256:sha, source_rows_sha256:sha, schema_sha256:sha, registry_sha256:sha, semantic_manifest_sha256:sha, application_id:u63, user_version:u63, page_size:u63, journal_mode:text, broker_protocol:u63, candidate_directory_identity_sha256:sha` |
| read / `macprovider-r26/bootstrap-intent-read-request-v1` | `schema:text, protocol:u63=4, request_uuid:uuid, database_generation:u63, source_index_sha256:sha, expected_database_identity_sha256:sha, expected_intent_sha256:sha` |
| export / `macprovider-r26/bootstrap-intent-export-request-v1` | all read fields, then `backup_uuid:uuid, main_sha256:sha, main_byte_length:u63, format_sha256:sha, backup_envelope_unsigned_sha256:sha` |
| restore / `macprovider-r26/bootstrap-intent-restore-request-v1` | `schema:text, protocol:u63=4, request_uuid:uuid, database_generation:u63, source_index_sha256:sha, expected_database_identity_sha256:sha, expected_intent_sha256:sha, intent_bytes:bytes(603), export_receipt:bytes, backup_uuid:uuid, backup_envelope_sha256:sha, main_sha256:sha, main_byte_length:u63, format_sha256:sha, candidate_directory_identity_sha256:sha, maintenance_lease_sha256:sha` |
| retire / `macprovider-r26/bootstrap-intent-retire-request-v1` | `schema:text, protocol:u63=4, request_uuid:uuid, database_generation:u63, source_index_sha256:sha, database_identity_sha256:sha, intent_sha256:sha, reason:text, main_state:text, sql_state:text, live_lease_set_sha256:sha, successor_database_identity_sha256:sha-or-null, successor_format_sha256:sha-or-null` |

Schema text is respectively `bootstrap_intent_create_request_v1`,
`bootstrap_intent_read_request_v1`, `bootstrap_intent_export_request_v1`,
`bootstrap_intent_restore_request_v1`, or
`bootstrap_intent_retire_request_v1`; `main_state` is
`absent|terminal`, `sql_state` is `absent|terminal`, and successor fields are
non-null only for `forward-replacement-drained`. Each request is at most 3,072
bytes, each signed receipt and embedded export receipt is at most 1,024 bytes,
and the containing XPC value is at most 4,096 bytes. Restore's intent is exactly
603 bytes. Alternate fields, nulls, order, domains, trailing bytes, or an
oversized value rejects before filesystem access.

Retire null/state rules are closed: `cancelled-before-main` requires
`main_state=absent`, `sql_state=absent`, an empty canonical lease-set SHA, and
both successor fields null; `forward-replacement-drained` requires both states
`terminal`, an empty canonical lease-set SHA, and both successor fields
non-null and equal to the exact selected format-v6 successor;
`whole-authority-destroy` requires both states `terminal`, an empty canonical
lease-set SHA, and both successor fields null. No other combination decodes.

1. `createOrResumeBootstrapIntent`: request tuple domain
   `macprovider-r26/bootstrap-intent-create-request-v1`; fields are schema,
   protocol 4, request UUID, database generation, source-index/source-rows/
   schema/registry/semantic SHAs, application ID, user version, page size,
   journal mode, broker protocol, and derived candidate-directory identity.
   The daemon independently opens the fixed candidate path, compares its
   identity, verifies generation 1 with an R4 fence or prior selected
   generation +1 from the exact fixed format path, and generates 32 nonce
   bytes only if no exact leaf exists. It recomputes both IDs and all 603
   intent bytes. It opens only the derived `.tmp` leaf with
   `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC`, mode 0600, writes only an
   exact prefix, fsyncs, renames to the derived final leaf, fsyncs the parent,
   reopens read-only without CREATE, and returns the bytes and receipt. An
   existing complete 603-byte temp is decoded/recomputed and may finish the
   rename without drawing a nonce. A 1...602-byte root-owned temp is not an
   identity: because the daemon never returns bytes or permits main creation
   before final-leaf durability, restart direct-unlinks that exact temp,
   parent-fsyncs, retires the incomplete nonce, and starts with fresh CSPRNG
   bytes. An existing final leaf must byte-match and never draws a nonce. A
   temp over 603 bytes, temp plus final, main before final receipt, or any
   ownership/path/identity mismatch protects without unlinking.
2. `readBootstrapIntent`: request domain
   `macprovider-r26/bootstrap-intent-read-request-v1`; fields are schema,
   protocol, request UUID, database generation, source-index SHA, expected
   database ID, and expected intent SHA. The daemon derives the one path,
   direct-opens read-only/no-follow, requires root:wheel 0600 regular one-link
   603-byte identity, decodes and recomputes every field/ID/SHA, and returns
   exact bytes plus a fresh signed receipt. There is no enumerate/list API.
3. `exportBootstrapIntent`: adds backup UUID, exact main SHA/length,
   format-v6 SHA, and backup-envelope unsigned SHA to the read request. The
   stopped broker and zero-serving-slot predicates are mandatory. The daemon
   returns exact bytes and a signed export receipt binding those values. It
   never exports its signing key.
4. `restoreBootstrapIntent`: accepts only the exact 603 bytes, a valid export
   receipt/key-chain, backup UUID/envelope SHA, expected fixed operands, and a
   stopped-authority maintenance lease. The daemon independently validates the
   same authority-root and candidate-directory identities and the broker's
   exact main/SQL/format proof before opening the derived final leaf. An exact
   existing leaf is a read-only idempotent success. If and only if the leaf is
   absent and every signed backup predicate matches, it uses the same
   exclusive prefix/fsync/rename/parent-fsync publisher. It never overwrites,
   truncates, repairs different bytes, restores into a new root, or restores
   while the original is live. A new root requires fresh forward replacement
   with unequal nonce/bootstrap/database IDs.
5. `retireBootstrapIntent`: request domain
   `macprovider-r26/bootstrap-intent-retire-request-v1`; fields are schema,
   protocol, request UUID, generation/source/database/intent identities,
   reason `cancelled-before-main|forward-replacement-drained|whole-authority-destroy`,
   and the exact broker SQL/main/lease proof for that reason. Before main
   creation it may remove the exact temp or final unselected leaf after proving
   that no main, B3 row, response lease, worker, or backup exists. After
   selection it may remove only the old leaf after the successor crossed B8,
   old serving and backup leases drained, and old SQL became terminal. It
   direct-unlinks one derived leaf, parent-fsyncs, and returns a signed receipt.

Every successful operation returns `bootstrap_intent_receipt_v1`, tuple domain
`macprovider-r26/bootstrap-intent-receipt-v1`. Its fields in order are schema,
protocol 4, operation `create|read|export|restore|retire`, request UUID, database
generation, source-index SHA, database ID, intent SHA, byte length literal
603, relative path bytes, path SHA, authority-root placement SHA,
candidate-directory identity SHA, provider UID, broker PID/pidversion/cdhash,
boot UUID, issued continuous ns, backup UUID non-null exactly for export/
restore and null for create/read/retire, backup-envelope SHA with the same null
rule, daemon key ID as 1...64 canonical ASCII `[A-Za-z0-9._-]`, and 64-byte
Ed25519 signature over the preceding fields using domain
`macprovider-r26/bootstrap-intent-receipt-unsigned-v1`. The response bytes must
hash to its intent SHA for create/read/export/restore. Retire returns no intent
bytes and its receipt proves the exact leaf is absent after parent fsync. A
receipt is request-bound and cannot authorize a later mutation, other database,
restore, backup, or path.

Each method closes every root, directory, temporary, and final FD on success,
error, cancellation, connection invalidation, or response-serialization
failure. Returned intent bytes are an immutable 603-byte XPC value, not a file
descriptor or capability. The daemon retains no caller FD and the broker
receives no privileged FD. Error replies are closed typed codes and contain no
path, nonce, intent bytes, audit token, inode, or signing detail.

The root daemon is also the only retire/delete actor. It denies deletion while
the matching candidate exists, the exact format-v6 fence selects the database,
any broker/worker/backup lease is live, or replacement has not irreversibly
selected and drained its successor. After successful forward replacement, it
may delete exactly the old derived leaf under a signed retirement request and
parent-fsync; a crash repeats the same direct-path decision. Initial
pre-main E0/E1 cancellation may delete only the exact partial leaf and retires
its nonce. Whole-authority destruction is a stopped, explicit operator action.
No online GC or ordinary cancellation can delete a selected intent.

### 3.3 Bootstrap, startup, and recovery order

Before main creation the broker obtains a complete create receipt and 603
bytes, independently decodes/recomputes them, and byte-compares the daemon's
candidate-directory identity. B3 atomically inserts the same bytes, SHA,
nonce, IDs, and database generation. The broker never opens the root intent
path. The broker is statically and dynamically forbidden to create or open the
main until final-leaf durability and a valid create receipt; thus a discarded
partial temp can never orphan SQL identity. Every pre-B8 restart freezes the
same R4 source, derives the same generation/source path, and calls
create-or-resume; after a final leaf exists the daemon either returns the same
bytes or protects. From committed B3 onward the row must match the
receipt and daemon read. P6 retains the root leaf and advances to B7; P6a
without it is invalid.

Every selected startup first validates exact format-v6 bytes, extracts the
typed generation/source/ID/intent SHA, authenticates to the daemon, and obtains
a read receipt. It verifies format-to-receipt-to-bytes before SQLite open,
then opens the selected database and requires byte equality with the immutable
row plus independent ID recomputation. Missing daemon, root, leaf, receipt,
row, or format value; stale key; partial bytes; alternate encoding; identity
splice; timeout; or disagreement protects before catalog read, readiness,
serving, custody, pricing, admission, or settlement.

## 4. Selected format authority version 6

The catalog-authority protocol remains V5, but schema v26 is selected only by
format version 6. `format.json` is the canonical JCS UTF-8 object with exactly
these keys, types, and meanings:

| key | type | exact value |
|---|---|---|
| `bootstrapID` | string | lowercase R26 bootstrap-ID hex |
| `bootstrapIntentSHA256` | string | lowercase SHA of exact 603 intent bytes |
| `databaseDirectoryIdentitySHA256` | string | lowercase captured directory-identity hex |
| `databaseGeneration` | integer | positive u63 matching the immutable row |
| `databaseIdentitySHA256` | string | lowercase R26 database-ID hex |
| `databaseLeaf` | string | `catalog-state.sqlite3` |
| `registrySHA256` | string | frozen registry hex |
| `schemaSHA256` | string | v26 schema hex |
| `semanticManifestSHA256` | string | frozen semantic hex |
| `sourceIndexSHA256` | string | lowercase frozen source-index hex |
| `version` | integer | 6 |

No missing/extra key, alternate spelling, JSON number form, whitespace, BOM,
CR, trailing LF, uppercase hex, duplicate key, or version 5 is accepted. With
the golden values above, exact JCS is 785 bytes and hashes to
`483d1677d7846df3c4e0ff838039226f59925b7a0ae55c9cda14c00a58608c83`:

~~~json
{"bootstrapID":"7d4fc8547fe7d914363b401991b60446681e7551f546328de5404f798490e39c","bootstrapIntentSHA256":"f3ca14bafd5a3f53274068a8cacc5f761e7c55a8acab91a0a7df911e1db8301d","databaseDirectoryIdentitySHA256":"3333333333333333333333333333333333333333333333333333333333333333","databaseGeneration":1,"databaseIdentitySHA256":"55f0a242ffab0afcdc03474f3d32a230d7e1000013375032561afeea53f3bca0","databaseLeaf":"catalog-state.sqlite3","registrySHA256":"d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63","schemaSHA256":"b8c641a2f6ba8dfa73174c9bc04b5c2e552649a42fa0e09cbfb39b140bb3b86d","semanticManifestSHA256":"0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee","sourceIndexSHA256":"1111111111111111111111111111111111111111111111111111111111111111","version":6}
~~~

B7 computes these bytes only after a fresh daemon read receipt and commits
their SHA with state `ready`. B8 prefix-writes only
`format.json.tmp-v6`, fsyncs it, renames it over `format.json`, fsyncs the
fixed parent, reopens both format and daemon intent, then releases R4. The
prefix and crash tables use the exact v6 bytes; an old `.tmp-v5`, selected v5
object, intent SHA absent from format, or format/SQL/daemon mismatch protects.
The backup envelope contains exact format bytes/SHA and the root signed export
receipt. Restore validates all three copies before selection.
There is no in-place schema-25/format-5 upgrade and no compatibility decoder
for those rejected proposal bytes. An existing selected R4 installation builds
a fresh schema-v26 candidate and crosses B8 once; an exact selected format 5,
schema 25, or intent without the v2/path/generation bindings protects. A
selected schema-v26 backup restores only with exact format 6.

## 5. Root-daemon ownership of serving-worker direct records

The R23 direct path and `serving_worker_v1` codec remain unchanged. R26 makes
the actor boundary literal: only `TrustedCustodyDaemonV5` may create, prefix
publish, fsync, rename, heartbeat-successor, terminal-successor, quarantine,
or delete a root-owned mode-0600
`serving-workers/<slot>-<generation>-<permit>.worker-v1` leaf. The provider
broker never opens that directory and never writes a direct worker record.
It owns the fixed SQLite slot state and serial CAS authority only.

The exact handoff is five steps:

1. the broker atomically allocates one SQL slot in `prepared`, obtains the
   exact request-bound pin, and asks the authenticated daemon for an offer;
2. the daemon direct-opens and locks the artifact, durably publishes
   `lock_handoff_v1:offered`, and returns the read-only locked FD plus ticket;
3. the broker spawns the worker with FD 203; the independently authenticated
   worker returns proof, and the daemon durably publishes the accepted
   handoff;
4. the daemon closes its sender duplicate, durably prefix-publishes the first
   `serving_worker_v1:running` record from the accepted kernel-derived worker
   identity and exact pin/ticket fields, and returns both accepted-handoff and
   worker-record SHAs to the broker;
5. the broker byte-compares those SHAs and CASes the exact SQL slot
   `prepared -> running`; only after that one-row CAS does it send finalize,
   and the daemon direct-validates the CAS receipt, deletes/fsyncs the handoff
   record, and retains the worker record.

A crash between any two effects exposes a directly addressable predecessor.
The daemon's worker connection, not caller PID fields, authorizes heartbeat.
Each heartbeat validates audit token, boot/PID/pidversion/start/cdhash/process
group, permit/slot/generation/request/pin, exact predecessor SHA and sequence;
the daemon alone publishes sequence +1. Cancellation and termination requests
come from the authenticated broker, but the daemon validates the exact SQL CAS
receipt before publishing `terminating`. The daemon publishes the terminal
worker successor only after its signed completion/process proof. Deletion is
allowed only after the broker's exact terminal SQL CAS and no live FD/worker
identity remains.

On either daemon or broker restart, the broker walks exactly the 32 fixed SQL
slots and asks the daemon for the one derived handoff and worker path for each
nonfree slot. The daemon direct-opens those paths; neither enumerates. The
matrix is closed:

| SQL | handoff | worker record | only successor |
|---|---|---|---|
| prepared | absent/offered | absent | retry the exact offer or quarantine; no worker inference |
| prepared | accepted | absent | require the original authenticated worker to re-prove FD/identity, publish first worker, or quarantine |
| prepared | accepted/absent | exact running | broker performs the same prepared-to-running CAS or quarantines on process ambiguity |
| running | absent | exact nonterminal | resume heartbeat/serve under exact identity |
| running | present | exact nonterminal | validate the compatible handoff predecessor, finalize it, or quarantine |
| running | any | absent/different | protect slot, revoke dispatch, and quarantine; never reconstruct from PID alone |
| terminal | absent | exact terminal | verify SQL terminal CAS then daemon deletes direct record |
| free | any record | any record | protect; slot reuse is forbidden until exact prior generation is terminal and removed |

`kill(pid,0)`, timeout, reboot, or missing `waitpid` ownership never proves
completion. A reboot permits only the accumulated canonical-exclusive-lock and
verified boot-change recovery, with stale records quarantined until SQL and
signed completion reconcile. The 33rd slot/record rejects. A direct record
created, modified, or deleted by the provider UID must fail the real cross-UID
test and protect rather than be adopted.

## 6. Irreversible cutover and compatible recovery

R25's undefined postselection R4 restore claim is deleted. The only rollback
boundary is the durable B8 format-v6 parent fsync plus successful reopen:

- before that boundary, the exact R4 selector remains the only selected
  authority; a v26 candidate failure leaves R4 serving and retains or protects
  the directly known candidate for forward retry. Exact E0/E1 cancellation is
  the only deletion exception;
- at that boundary, format version 6, its SQL SHA, the daemon intent receipt,
  immutable row, database ID, and directory identity all match. V5/schema-v26
  becomes selected irreversibly and R4 is fenced from every runtime read/write;
- after that boundary, failure protects V5 and makes readiness/serving
  unavailable. Recovery may complete the same hot-journal predecessor,
  restore the same version/identity from a supported stopped backup, or build
  a fresh schema-v26 forward replacement with generation +1 and unequal
  nonce/bootstrap/database IDs. It may never select or write R4, schema 23/25,
  or format 5, reinterpret V5 receipts, or expose stale readiness/economics.

At B8 restart, exact old R4 format means preselection; exact format-v6 means
selected and requires the full v6/daemon/SQL proof. A full fsynced
`format.json.tmp-v6` with old R4 format resumes the one rename. Both final
formats, an unrecognized format, bad prefix, missing intent, or durability
ambiguity protects without choosing by timestamp. There is no R4 downgrade
state machine, operator shortcut, or compatibility decoder. A future product
requirement for downgrade must first define a separately reviewed destructive
migration and cannot preserve admission, receipt, or readiness claims.

## 7. Bounded storage and implementation order

One database contains one 603-byte intent BLOB. The root daemon retains at
most the selected 603-byte leaf and one forward candidate/prefix; it rejects a
third generation until the old database has been irreversibly retired. The 32
handoff paths remain at most 8,192 bytes each, with at most one prefix
successor per path. The corrected new-object peak is therefore at most
526,097 bytes: 603 SQL bytes + two 603-byte root leaves + 32 final and 32
prefix handoff records. The format final/temp pair adds at most 1,570 bytes
within the already bounded format budget. The inherited 448 MiB main-file,
64 MiB rollback-journal, 32 serving-slot, 1,024 row-slot, record, event, and
counter bounds remain. A 604-byte intent, third retained generation, second
prefix, 33rd handoff, oversized record, or hidden history rejects before write.

After approval, implementation remains phased and reviewable:

1. approve required SPEC-001/SPEC-044 changes for schema v26, format v6,
   privileged intent custody, irreversible cutover, and worker-record actor;
2. check in independent schema/tuple/JCS goldens and crash fixtures;
3. add the five-method root intent service and real authenticated cross-UID
   tests before the broker consumes it;
4. implement bootstrap/B3/B7/B8/startup/backup/restore against receipts;
5. move every direct worker-record mutation into the root daemon and add the
   five-step/restart tests;
6. complete the accumulated post-B8 Swift migration, maximum-shape, actual-MLX,
   Xcode, release-asset, integration, and three-lane full-diff gates.

Rollback for each pre-B8 implementation slice is code rollback while R4
remains selected. Once a real B8 selection occurs, runtime rollback is
forbidden; only forward recovery above is supported. Metrics expose version,
truncated IDs, intent-match boolean, daemon receipt status, worker phase,
slot/generation headroom, and typed protection reason. They expose no nonce,
intent/request/model bytes, path, audit token, private key, or full digest.

R26 adds no pricing, admission, settlement, reward, enforcement, release,
deployment, production activation, hardware qualification, general root file
service, or d-inference authority. Plan approval is not implementation, and
fixture evidence is not cross-UID, actual-MLX, app, release, deployed, or
production evidence.

## 8. R26 author execution record

Fresh author-time checks ran on Darwin 25.5.0 arm64 with Python 3.14.7,
SQLite 3.53.4, Node, and Apple Swift 6.3.3. Two independent Python/Node
encoders reproduced the schema/identity/intent/format sizes and hashes recorded
above. The exact R24 registry/dispatch/semantic streams reproduced unchanged.
The derived intent path was exercised with `openat`/`O_NOFOLLOW`/`O_EXCL`,
mode and one-link checks, byte-exact reopen, prefix crash states, and
replacement attacks in a same-UID temporary hierarchy; that is a plan-shape
oracle, not the mandatory root/provider XPC proof. Public SDK headers still
expose `MACH_RCV_TRAILER_AUDIT`, `kSecGuestAttributeAudit`, public NSXPC
PID/UID, `NSFileHandle: NSSecureCoding`, and public FD transfer, and still do
not expose a public XPC audit-token getter.

The production Swift inventory was regenerated from both CLI and Malibu app
source roots, every path parsed with `xcrun swiftc -frontend -parse`, and the
R31 direct durable-read symbols remain implementation work. The precise
counts/hashes and commands are recorded in R32. `git diff --check` and the
two-path author scope check run after final bytes are written. Final R26/R32
file SHA-256 values are reported with the review handoff rather than embedded
inside either hashed artifact, which would be self-referential.
