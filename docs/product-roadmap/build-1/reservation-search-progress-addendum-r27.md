# Build 1 reservation search progress addendum R27

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

R27 corrects the rejected R26/R32 candidate. It is read after R23 through R26;
where this document speaks it replaces the earlier rule. All unaffected limits,
trust boundaries, generated transition records, acceptance criteria, and
negative tests remain mandatory. R33 replaces R32 only where R33 says so.
Nothing in a rejected revision overrides R27.

The exact author base is
`c9c46b03799a9314eb6a73a452ca21562af01d93`. The exact failed review is
`docs/product-roadmap/build-1/reviews/reservation-search-progress-r26-plan-sol.md`,
SHA-256 `ea22bd66871f033f0bb690311148eb3b090e95731cebbd37f09c770d5d837d46`.
It reviewed R26 SHA-256
`358e63153db080ee22424e567ab312c1465b2b89e3489519447322aba320c42d`
and R32 SHA-256
`80b4b213e81e89c674d450b176d3d3c39ac9d8b0cf15025abdcf1ea9d10cd1a8`
and reported 0 Critical, 7 High, 3 Medium, 1 Low, and 2 Informational
findings. The fetched `origin/main` is
`7128d1206afcf3cc857479e1d776ddc4899b020a`. This author slice writes only
R27 and R33. It changes no Swift, C, test, SPEC, release, deployment, secret,
or d-inference file.

## 1. Exact finding dispositions

| finding | correction | proof |
|---|---|---|
| H1 unsafe u63/JCS generation | one `DatabaseGenerationV1` domain uses exactly 20 ASCII decimal digits everywhere outside checked arithmetic; SQL, tuples, paths, identities, JSON, RPCs, receipts, backups, and worker records never encode it as a JSON number or tuple u63 | R33-02 |
| H2 incomplete worker split | sole `serving_worker_v3` is published below; eight closed authenticated RPCs and a signed broker SQL-CAS witness bind every SQL/root transition and restart | R33-06 |
| H3 undefined destructive proofs | exact signed `lease_set_zero_v1`, `broker_authority_state_witness_v1`, and single-use `maintenance_lease_v1` separate broker SQL facts from daemon-direct filesystem facts | R33-07 |
| H4 unbound receipt/envelope/root | every receipt carries request SHA; unsigned/final backup envelopes are acyclic; authority-root identity has one tuple, lifecycle, path, and golden | R33-03/05/07 |
| H5 undeployable privilege boundary | concrete SwiftPM/C-shim products, source roots, raw-XPC Mach services, launchd jobs, immutable anchors, signing/key/update/uninstall rules, and package gates are specified | R33-04/11 |
| H6 forwardable split transport | the challenge protocol is deleted; the daemon authenticates the exact received raw-XPC message with `SecCodeCreateWithXPCMessage` before semantic decode or root access | R33-04 |
| H7 nondurable B8 half | successful parent-directory fsync is the online boundary; after a crash, freshly reopening exact final format-v6 is the only recovery selection predicate; validation follows selection and can only protect | R33-08 |
| M1 unnamed/zero temp | one exact `.intent-v3.tmp-r27` path is registered; every prefix 0...618 has a successor, 619 resumes, and all dual/collision states protect | R33-03 |
| M2 impossible allocation assertion/unbounded XPC | the claim is narrowed to rejection after transport delivery but before tuple allocation, semantic decode, or root access; fixed connection/in-flight/body/FD/response caps are closed | R33-04 |
| M3 no frozen old-product gate | the signed 1.8.123 predecessor CLI, Malibu bundle, headless assets, updater, and installer are frozen and launched after B8 under syscall tracing | R33-09 |
| L1 origin path overlap | `ModelRuntime.swift` overlaps by path but its landed hunks are SPEC-038/039 scheduler work, not authority calls; the full eventual-base compiler inventory is still regenerated | R33-10 |

No finding is downgraded, waived, or closed by removing an outcome or weakening
a test. Implementation remains prohibited until an independent native GPT-5.6
Sol review of the exact R27/R33 bytes reports zero Critical, High, and Medium.

## 2. Schema v27 and the exact generation domain

### 2.1 `DatabaseGenerationV1`

The abstract value is an integer in `1...9223372036854775807`. Its sole
persistent and external spelling is `generation20`, exactly 20 ASCII bytes,
digits only, lexically greater than `00000000000000000000`, and lexically at
most `09223372036854775807`. Leading zeroes are mandatory. Parsing performs a
checked digit fold into `UInt64`, then rejects zero or a value above `Int64.max`,
and finally requires re-encoding to reproduce the same 20 bytes. Increment is
checked integer arithmetic followed immediately by canonical re-encoding.

`generation20` is a `tuple_v1` **text** field and a JSON string. It is never a
tuple u63, JSON number, `Double`, platform `Int` at a wire boundary, or
unvalidated path fragment. The SQL column is TEXT with BINARY collation.
Swift uses a value type whose only public constructors validate canonical
bytes; JavaScript and Go keep the value as a string until explicit checked
big-integer conversion. These vectors are normative:

| value | accepted external bytes |
|---:|---|
| 1 | `00000000000000000001` |
| 9007199254740991 | `00009007199254740991` |
| 9007199254740992 | `00009007199254740992` |
| 9007199254740993 | `00009007199254740993` |
| 9223372036854775807 | `09223372036854775807` |

Nineteen/twenty-one digits, plus signs, spaces, non-ASCII digits, all-zero,
`09223372036854775808`, and unpadded equivalents reject. This domain replaces
every earlier `database_generation:u63`; unrelated catalog, slot, transition,
custody, and GC generation counters remain their already bounded tuple u63s.

### 2.2 Machine-exact schema

Schema v27 is derived from the exact 44,295-byte R26 SQL stream, SHA-256
`b8c641a2f6ba8dfa73174c9bc04b5c2e552649a42fa0e09cbfb39b140bb3b86d`,
by these ordered, exactly-once byte substitutions:

1. `PRAGMA user_version=26;\n` becomes `PRAGMA user_version=27;\n`;
2. `schema_version INTEGER NOT NULL CHECK(schema_version=26)` becomes the same
   clause with `=27`;
3. `database_generation INTEGER NOT NULL CHECK(database_generation BETWEEN 1 AND 9223372036854775807)` becomes
   `database_generation_text TEXT NOT NULL COLLATE BINARY CHECK(length(database_generation_text)=20 AND database_generation_text NOT GLOB '*[^0-9]*' AND database_generation_text>'00000000000000000000' AND database_generation_text<='09223372036854775807')`;
4. `CHECK(length(bootstrap_intent_bytes)=603)` becomes
   `CHECK(length(bootstrap_intent_bytes)=619)`.

The result is exactly 44,448 bytes, SHA-256
`434b4d4eb9370e6707ec12d6ca2ea584f47d2f970c4d633a96a87e7d14aa5e06`.
It executes with application ID 1297109587, user version 27, 24 non-internal
tables, and 11 explicit indexes. B3 still inserts exactly 1,560 logical rows.
The one immutable bootstrap row stores canonical generation text. The 495
transition records, 68,992-byte registry
`d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`,
1,309-byte dispatch
`af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`,
and 97,959-byte semantic manifest
`0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`
remain byte-identical; no DML record or count changes.

### 2.3 Identities, paths, intent, and format

The R24 12-field bootstrap order remains, with schema text `bootstrap_id_v2`,
domain `macprovider-r27/bootstrap-id-v2`, the v27 schema SHA, user version 27,
and broker protocol 1. At the established golden operands it is 305 bytes and
SHA-256
`2b3972d7b5d1866b4d6974ab0a5a8e871c4812c678c8a42d593ca423d4dab815`.
The R24 13-field database order remains, with schema text
`database_identity_v2`, domain `macprovider-r27/database-identity-v2`, that
bootstrap ID, the v27 schema SHA, and user version 27. It is 344 bytes and
SHA-256
`251788668b16ed037dc126fc0f3fffad4e6786ab6ce8b30b87f9ee59004f0b3b`.
Database generation is deliberately absent from both stable identity
preimages; every object that selects or acts on an instance carries the stable
database ID **and** generation text.

The exact final relative path is
`bootstrap-intents/<generation20>-<source-index-hex>.intent-v3`. The golden is
113 bytes and hashes under the inherited relative-path algorithm to
`bf22af8e0fb36f4df477331045d08fd90cf12350b98dadd85ece2ee5df43c48f`:

~~~text
bootstrap-intents/00000000000000000001-1111111111111111111111111111111111111111111111111111111111111111.intent-v3
~~~

The sole temp is the final path plus literal `.tmp-r27`. Its golden is 121
bytes and path SHA
`b743e2bf5240340a207adbbc055735e625350724345e39b167f05721f4265b52`.
No other temp spelling, random suffix, sibling search, or enumeration exists.

`bootstrap_intent_v3`, domain
`macprovider-r27/bootstrap-intent-v3`, has the same 20 fields as R26 except:
schema is `bootstrap_intent_v3`, daemon protocol is 5, field 3 is
`database_generation_text:text`, schema/user-version values are v27, and the
two path fields are the v3 path above. Every legal value is exactly 619 bytes.
At the golden operands its SHA is
`97c8ea16ed0c9acc384d529a67d2541203e40c7cb872d9786ae24dbe905c3638`.
R33 carries the complete 619-byte hex vector. Length and tag checks happen
before field allocation. A 618/620-byte value cannot be semantically decoded.

Selected `format.json` remains version 6 because no rejected proposal shipped.
Its exact eleven-key RFC8785 JCS object changes `databaseGeneration` to a
20-character JSON string and uses the R27 hashes. The generation-1/max-shape
object is exactly 806 bytes for **every** legal generation and hashes to
`bcc1bb0f65f72bf8980dc5fb7db1f42153f679a17435411dfb7b69f7b20019c0`:

~~~json
{"bootstrapID":"2b3972d7b5d1866b4d6974ab0a5a8e871c4812c678c8a42d593ca423d4dab815","bootstrapIntentSHA256":"97c8ea16ed0c9acc384d529a67d2541203e40c7cb872d9786ae24dbe905c3638","databaseDirectoryIdentitySHA256":"3333333333333333333333333333333333333333333333333333333333333333","databaseGeneration":"00000000000000000001","databaseIdentitySHA256":"251788668b16ed037dc126fc0f3fffad4e6786ab6ce8b30b87f9ee59004f0b3b","databaseLeaf":"catalog-state.sqlite3","registrySHA256":"d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63","schemaSHA256":"434b4d4eb9370e6707ec12d6ca2ea584f47d2f970c4d633a96a87e7d14aa5e06","semanticManifestSHA256":"0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee","sourceIndexSHA256":"1111111111111111111111111111111111111111111111111111111111111111","version":6}
~~~

## 3. Deployable privilege and transport contract

### 3.1 Products, modules, services, and anchors

Implementation adds these reviewed roots and no general-purpose privileged API:

| product/target | exact source root | role |
|---|---|---|
| C target `MacProviderXPCShim` | `phase3-binary/Sources/MacProviderXPCShim/` | thin public-libxpc/Security wrappers; no policy |
| library `MacProviderAuthorityProtocol` | `phase3-binary/Sources/MacProviderAuthorityProtocol/` | `tuple_v1`, generation, DTO, receipt, envelope codecs |
| executable `macprovider-authorityd` | `phase3-binary/Sources/macprovider-authorityd/` | root filesystem/key/worker authority |
| executable `macprovider-catalog-broker` | `phase3-binary/Sources/macprovider-catalog-broker/` | provider-UID sole SQLite connection and signed SQL witnesses |
| library `MacProviderCatalogClient` | `phase3-binary/Sources/MacProviderCatalogClient/` | opaque broker snapshots/actions for CLI and app |

The root plist is installed at
`/Library/LaunchDaemons/tech.malibu.macprovider.authorityd.plist`, label and
Mach service `tech.malibu.macprovider.authorityd`, `UserName=root`, one instance,
with no sockets or user-controlled arguments. The per-provider LaunchAgent is
`~/Library/LaunchAgents/tech.malibu.macprovider.catalog-broker.plist`, label and
Mach service `tech.malibu.macprovider.catalog-broker`, running as that provider
UID. The provider `serve` LaunchAgent remains unprivileged and becomes a broker
client. Only the daemon registers the authority Mach service; only the broker
registers the broker service.

The installer creates, component-checks, and records these anchors before
launch:

- root: `/Library/Application Support/Malibu/MacProviderAuthority/v1`,
  root:wheel 0700, with root-owned `bootstrap-intents`, `artifact-locks`,
  `lock-handoffs`, `serving-workers`, `maintenance`, `receipts`, and `keys`;
- provider placement:
  `/Library/Application Support/Malibu/MacProviderAuthority/v1/providers/<uid>/data-v5`.
  `providers` and the canonical-decimal `<uid>` parent are root-owned and not
  traversable or writable by the provider. `data-v5` is installer-created,
  provider-owned 0700 and holds
  only broker database/format and fixed signed-witness leaves. The provider can
  mutate children but cannot unlink, rename, or replace its placement root.
  UID is taken from the signed install receipt, never RPC text or `$HOME`.

At broker startup, the authenticated broker sends the closed tuple
`open_provider_authority_request_v1` under domain
`macprovider-r27/open-provider-authority-request-v1`: schema, protocol 5,
request UUID, provider UID, install-receipt SHA, authority-root identity SHA,
and provider-root identity SHA. Authorityd opens the exact `data-v5` component,
revalidates placement, and returns one `O_RDONLY|O_DIRECTORY|O_CLOEXEC` FD plus
a request-bound receipt. The broker VFS uses only `openat` relative to that FD;
it never receives a parent FD or absolute path. Closing/invalidation ends the
capability. CLI/app/worker clients cannot request it. Authorityd opens no SQLite
file and provider UID cannot replace the directory entry.

Every traversal starts from `/` or an installer-opened/pinned parent and opens
each literal component using `openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`.
`fstatat(AT_SYMLINK_NOFOLLOW)` is byte-compared with `fstat`; device, inode,
birthtime, type, owner, group, mode, flags, ACL/xattr allowlist, and component
name must match the signed install receipt. Mutable directory timestamps and
size never form persistent identity. Leaves use registered derived names only,
`O_NOFOLLOW|O_CLOEXEC`, and `O_CREAT|O_EXCL` only in the named creation state.

`authority_root_identity_sha256` is SHA-256 of tuple domain
`macprovider-r27/authority-root-identity-v1`, fields in order:
`schema:text=authority_root_identity_v1, install_receipt_sha256:sha,
absolute_path:bytes, absolute_path_sha256:sha, parent_chain_sha256:sha,
device_id:u63, file_id:u63, file_type:text=directory, mode:u63=0700,
owner_uid:u63=0, group_gid:u63=0, birthtime_seconds:u63,
birthtime_nanoseconds:u63, user_flags:u63=0, system_flags:u63=0`.
The path is the literal 59 UTF-8 bytes above; its registered-path SHA is
`148e1b60fb4d76b59bd145b6e515a4bf77f9d1edf3f13c2cf86eaaf001979ae4`.
With install receipt `55` x32, parent chain `66` x32, device 7, inode 9,
birthtime 1700000000.123456789, its 336-byte preimage hashes to
`b1fe4bf7e7a17761822264c9d7562c28e6cee25d7c6c538ecf455a686794f992`.
The identity is captured at installation, signed into the install receipt,
revalidated at each daemon start and before every mutating operation, and never
rotated in place. Replacement requires stopped destructive migration or a new
authority identity and therefore cannot preserve a database identity.

`provider_root_identity_sha256` uses domain
`macprovider-r27/provider-root-identity-v1` and the same stable placement field
order as the R25 directory identity: schema `provider_root_identity_v1`,
authority-root identity SHA, relative path bytes/SHA, device, inode, literal
`directory`, mode 0700, provider UID, provider primary GID, birthtime seconds/
nanoseconds, user flags 0, system flags 0. Its relative path is exactly
`providers/<canonical-uid>/data-v5`; UID has no leading zero. Golden UID 501,
GID 20, device 7, inode 10, birthtime 1700000001.987654321 gives path
`providers/501/data-v5`, 21 bytes/SHA
`94023778ffccea6ea05fe42fbe22768945b3b1ea1ac54e103ba441c3f0443ded`,
and a 263-byte tuple/SHA
`02f196c7c4a5772e0c5ecd6f443c71a9d48b5a664b64b403c2bfabeb10ec4227`.
Mutable child effects may change timestamps/size but never these fields.

### 3.2 Signing and key lifecycle

All four shipped Mach-facing binaries/libraries use hardened runtime and the
repository Developer ID team. Plists contain literal versioned binary paths.
The install receipt pins package receipt SHA, Team ID, designated-requirement
text and SHA, executable CDHash allowlist, protocol range, anchor identities,
and daemon/broker public-key IDs. The root daemon key is nonexportable in the
System Keychain with an ACL/designated requirement limited to authorityd. The
broker key is nonexportable in the provider login Keychain with ACL limited to
the broker. Private bytes never enter a worktree, receipt, backup, log, RPC, or
test fixture.

An upgrade first installs versioned binaries, verifies package/signatures and
both designated requirements, adds a finite `{old,new}` CDHash/key overlap,
quiesces new operations, drains all 32 slots, starts and probes the new daemon,
then the new broker, and atomically switches plists. Old keys verify retained
receipts but cannot sign new protocol-5 operations after cutover. The finite
overlap is removed only after all retained objects are re-signed by an explicit
compatible successor or retired. Failure before B8 restores old plists and
binaries. Once any format-v6 is durably selected, an incompatible old broker,
CLI, app, or installer is refused; it never rolls schema or authority bytes
back. Uninstall refuses while a selected database, retained intent, worker,
backup lease, or maintenance lease exists. Explicit whole-authority destruction
requires the stopped signed proof in section 6 and removes keys/anchors only
after database and intent retirement receipts are durable.

### 3.3 One non-forwardable raw-XPC message

The R25 NSXPC/challenge/Mach split is deleted. Authorityd uses public libxpc
`xpc_connection_create_mach_service` listener APIs. Each operation is one
received XPC dictionary. Before reading `body`, duplicating `fd`, semantically
decoding a tuple, opening an anchor, or dispatching work, the handler calls
`SecCodeCreateWithXPCMessage` on that **same received dictionary**, validates
the resulting dynamic code against the allowed designated requirement/CDHash,
and compares `xpc_connection_get_euid`/PID to the method's allowed actor. An
exec, exited process, stale connection, PID reuse, forwarded body, or message
created by a different process execution therefore cannot inherit authority.
Connection invalidation cancels uncommitted work and closes every duplicated FD.

The dictionary has exactly `body` (XPC data) and, only for worker accept, `fd`
(XPC FD). Replies have exactly `body` and never an FD except serving offer and
broker startup. Each may also contain its one method-specific artifact or
directory FD. Unknown keys/types
reject. Transport has necessarily allocated the XPC object before the handler;
the enforceable claim is rejection before tuple-field allocation, semantic
decode, signature verification work beyond caller identity, or root access.

Hard limits are: 64 live connections globally, 8 per effective UID, 32 in-flight
RPCs globally, 4 per UID, 1 per connection, zero application queued requests,
4,096 body bytes except backup restore/export metadata up to 262,144 bytes,
one FD only on accept/offer, and 262,144 response bytes. The daemon checks XPC
data length directly before copying. Counters increment before admission and
decrement exactly once on reply, error, cancellation, or invalidation. First
over returns `resource_exhausted` and is not queued. There is no challenge table.
Request UUID/predecessor/state make each RPC idempotent; replay with different
bytes rejects. A bounded 256-entry, 30-second in-memory duplicate cache only
accelerates same-boot identical replies and is not correctness authority.

Compile-shaped public boundaries are frozen:

~~~swift
public struct DatabaseGenerationV1: Sendable, Hashable, Codable {
    public let canonical20: String
    public init(canonical20: String) throws
    public func checkedSuccessor() throws -> DatabaseGenerationV1
}
public struct AuthorityRequestV1: Sendable { public let canonicalTuple: Data }
public struct AuthorityReplyV1: Sendable { public let canonicalTuple: Data }
public protocol AuthorityTransport: Sendable {
    func call(_ request: AuthorityRequestV1, descriptor: FileHandle?) async throws -> AuthorityReplyV1
}
public struct ServingOfferRequestV1: Sendable { public let tuple: Data }
public struct ServingAcceptRequestV1: Sendable { public let tuple: Data; public let artifactFD: FileHandle }
public struct ServingFinalizeRequestV1: Sendable { public let tuple: Data }
public struct ServingHeartbeatRequestV1: Sendable { public let tuple: Data }
public struct ServingTerminalRequestV1: Sendable { public let tuple: Data }
public struct ServingAbnormalTerminalRequestV1: Sendable { public let tuple: Data }
public struct ServingRecoveryRequestV1: Sendable { public let tuple: Data }
public struct ServingDeleteRequestV1: Sendable { public let tuple: Data }
public enum ServingAuthorityRequestV1: Sendable {
    case offer(ServingOfferRequestV1), accept(ServingAcceptRequestV1)
    case finalize(ServingFinalizeRequestV1), heartbeat(ServingHeartbeatRequestV1)
    case terminal(ServingTerminalRequestV1)
    case abnormalTerminal(ServingAbnormalTerminalRequestV1)
    case recovery(ServingRecoveryRequestV1), delete(ServingDeleteRequestV1)
}
public protocol CatalogBrokerClient: Sendable {
    func snapshot(_ request: CatalogSnapshotRequestV5) async throws -> CatalogSnapshotV5
    func perform(_ request: CatalogActionRequestV5) async throws -> CatalogActionResultV5
}
~~~

No `Codable` synthesis defines wire bytes. Every DTO calls the one strict
`TupleV1Decoder`, which consumes exact type/order/count/domain, has per-field and
aggregate limits before allocation, rejects trailing bytes, and returns typed
values including `DatabaseGenerationV1`. JCS decoding first rejects duplicate/
extra keys and JSON numeric generation, then validates the 20-byte string and
requires byte equality with independently emitted JCS.

## 4. Request and receipt rules

Every **serving** protocol-5 request is a closed `tuple_v1` whose first fields are
`schema:text, daemon_protocol_version:u63=5, rpc_request_uuid:uuid,
database_identity_sha256:sha, database_generation_text:text,
slot_ordinal:u63-or-null, slot_generation:u63-or-null,
permit_uuid:uuid-or-null, request_uuid:uuid-or-null,
request_sha256:sha-or-null, expected_predecessor_sha256:sha-or-null` followed
only by the method fields named below. Nullability is method-fixed, not caller
choice. `request_sha256` for a model request is always SHA-256 of the exact
opaque request bytes and is repeated in its pin, worker, SQL row, completion,
CAS witness, and every daemon request/receipt.

The bootstrap create/read/export/restore/retire tuples retain R26 order but use
protocol 5, generation text, 619-byte intent, R27 identities, and add as their
last field the applicable signed state/maintenance object SHA. The exact
method request SHA is `SHA256(canonical request tuple bytes)`. Every successful
daemon reply ends in one `daemon_receipt_v2`, domain
`macprovider-r27/daemon-receipt-v2`, with these 26 fields:

1. schema `daemon_receipt_v2`; 2. protocol 5; 3. operation enum; 4. RPC request
UUID; 5. **request tuple SHA**; 6. database ID; 7. generation text; 8. slot
ordinal nullable; 9. slot generation nullable; 10. permit nullable; 11. model
request UUID nullable; 12. model request SHA nullable; 13. predecessor object
SHA nullable; 14. successor object SHA nullable; 15. response payload SHA;
16. authority-root identity SHA; 17. provider-root identity SHA; 18. provider
UID; 19. authenticated PID; 20. authenticated pidversion; 21. authenticated
CDHash; 22. boot UUID; 23. issued continuous ns; 24. expiry continuous ns;
25. daemon key ID; 26. 64-byte Ed25519 signature over fields 1...25 using
domain `macprovider-r27/daemon-receipt-unsigned-v2`.

Receipts expire after 30 seconds for mutation authority. Retained export,
terminal, and delete evidence remains verifiable after time expiry but cannot
authorize a new mutation. Changing any byte with the same request UUID changes
field 5 and rejects. Every method-specific response payload includes the full
signed canonical object bytes needed by the broker, not merely its SHA.

The bootstrap method tuples are closed as follows; commas preserve exact order
and each tuple uses the displayed `macprovider-r27/...-request-v1` domain:

- `bootstrap-intent-create`: `schema, protocol, rpc_request_uuid,
  database_identity_sha256, database_generation_text, source_index_sha256,
  source_rows_sha256, schema_sha256, registry_sha256,
  semantic_manifest_sha256, application_id, user_version, page_size,
  journal_mode, broker_protocol, candidate_directory_identity_sha256`;
- `bootstrap-intent-read`: `schema, protocol, rpc_request_uuid,
  database_identity_sha256, database_generation_text, source_index_sha256,
  expected_intent_sha256`;
- `bootstrap-intent-export`: every read field, then `backup_uuid,
  main_sha256, main_byte_length, format_sha256,
  backup_envelope_unsigned_sha256, broker_state_witness_bytes,
  broker_state_witness_sha256`;
- `bootstrap-intent-restore`: every read field, then `intent_bytes,
  backup_uuid, unsigned_envelope_bytes, unsigned_envelope_sha256,
  export_receipt_bytes, export_receipt_sha256, final_envelope_bytes,
  final_envelope_sha256, main_sha256, main_byte_length, format_sha256,
  candidate_directory_identity_sha256, broker_state_witness_bytes,
  broker_state_witness_sha256, maintenance_lease_bytes,
  maintenance_lease_sha256`;
- `bootstrap-intent-retire`: every read field, then `reason, main_state,
  sql_state, lease_set_zero_bytes, lease_set_zero_sha256,
  successor_database_identity_sha256-or-null,
  successor_generation_text-or-null, successor_format_sha256-or-null,
  broker_state_witness_bytes, broker_state_witness_sha256,
  maintenance_lease_bytes, maintenance_lease_sha256`.

The schema strings equal the method names with hyphens replaced by underscores
and `_request_v1` appended. SHA and UUID fields use their tuple types; byte
objects use bytes; bounded counts/scalars use u63; generation uses text; only
the three explicitly nullable successor fields may be null. Export/restore may
use the 262,144-byte metadata exception; the other request tuples are at most
4,096 bytes.

## 5. Authoritative serving records and eight RPCs

### 5.1 Sole worker codec

All R23/R24 `serving_worker_v1/v2` prose is replaced by one codec.
`serving_worker_v3` final domain is `macprovider-r27/serving-worker-v3`; its
unsigned signature domain is `macprovider-r27/serving-worker-unsigned-v3`.
Fields 1...35 form the unsigned tuple; fields 36...37 complete the final tuple:

| # | field | type/rule |
|---:|---|---|
| 1-4 | schema, daemon protocol, database ID, generation text | `serving_worker_v3`, 5, SHA, canonical20 |
| 5-9 | slot ordinal/generation, permit, request UUID/SHA | slot 0...31; exact one-request identity |
| 10-14 | model ID, release, catalog generation, row ordinal, transaction UUID | exact selected catalog row |
| 15-20 | artifact SHA, artifact-lock identity SHA, custody generation/event SHA, catalog-binding SHA, serving-pin SHA | exact trusted custody/pin |
| 21 | accepted handoff SHA | exact `lock_handoff_v1:accepted` |
| 22-28 | worker PID, pidversion, start sec/nsec, CDHash, process group, boot UUID | kernel/code-derived identity |
| 29-30 | heartbeat sequence/time | checked monotonic successor |
| 31 | state | `accepted|running|terminating|completed|cancelled|failed|expired|quarantined` |
| 32 | terminal outcome | null through terminating; equals state for a terminal state |
| 33 | terminal evidence SHA | null through terminating; required terminal |
| 34 | broker CAS witness SHA | null only in first `accepted`; required afterwards |
| 35 | predecessor worker-record SHA | null only for first `accepted`; required afterwards |
| 36-37 | daemon key ID, Ed25519 signature bytes | signature covers fields 1...35 |

The record SHA is SHA-256 of the final tuple and is not a self-field. Exact
maximum UTF-8 model ID 512, release 128, key ID 64, maximum scalar values, and
64-byte signature serialize to 1,486 bytes, SHA-256
`e17519ab19ecb088bdb59c2675283574518120ef5e01e9a1e00d2d0342908fee`.
That golden uses `m` x512, `r` x128, `k` x64, every SHA/signature byte `ff`,
every UUID byte `ff`, generation text `09223372036854775807`, each scalar at
its governing maximum (row 1023, custody 8, slot 31, nanoseconds 999999999),
and terminal state/outcome `quarantined`; the signature is fixture bytes, not
claimed cryptographic verification.
The implementation keeps an 8,192-byte defensive transport/file cap; bytes
1,487...8,192 cannot be legal records and reject, as does byte 8,193. The direct final path is
`serving-workers/<slot2>-<slot-generation>-<permit-lower-uuid>.worker-v3` and
the only prefix is that path plus `.tmp-r27`. Slot is two decimal digits; slot
generation is canonical unsigned decimal without leading zero because it is a
bounded non-JCS internal u63. Its maximum-width final path is 85 bytes and temp
is 93; corresponding handoff maximum paths are 84 and 92 bytes. Both path SHAs are stored in the SQL row's
registered `record_path_sha256`/worker record chain. Final/prefix are one
successor pair; dual or a different codec protects.

### 5.2 Signed broker SQL-CAS witness

`broker_sql_cas_witness_v1`, final domain
`macprovider-r27/broker-sql-cas-witness-v1`, signs an unsigned tuple domain
`macprovider-r27/broker-sql-cas-witness-unsigned-v1` with fields:
`schema, protocol=1, witness_uuid, rpc_request_sha256, issuer_key_id,
issuer_designated_requirement_sha256, issuer_cdhash, database_identity_sha256,
database_generation_text, slot_ordinal, slot_generation, permit_uuid,
request_uuid, request_sha256, transition_name, predecessor_row_sha256,
successor_row_sha256, worker_record_sha256-or-null,
predecessor_commit_generation, successor_commit_generation,
predecessor_witness_sha256-or-null, issued_boot_uuid,
issued_continuous_ns, expiry_continuous_ns, signature`.
The signature covers all preceding fields. Commit generations are exact
`protocol_meta.generation` values and successor equals predecessor +1.

The broker computes both row digests from the complete schema-order SQL row,
builds and signs the witness before `BEGIN IMMEDIATE`, performs the exact
registered two-row serving template with those predicates, commits, re-reads
the row/meta on the same connection, and only then sends the witness. A crash
after commit can deterministically reconstruct byte-identical unsigned fields
from the current row, direct daemon predecessor, fixed transition descriptor,
and prior accepted witness; Ed25519 is deterministic. The witness UUID is the
first 16 bytes of SHA-256 of tuple domain
`macprovider-r27/broker-sql-cas-witness-id-v1` over every field above except
`witness_uuid` and `signature`, so reconstruction cannot choose a new identity.
A precommit witness is not
authority: the daemon accepts it only with the exact expected root predecessor
and publishes its SHA in the root successor. Replay then fails predecessor or
slot-generation CAS. Daemon restart verifies signature/key chain, request SHA,
database/generation, complete predecessor/successor row digests returned in the
broker recovery request, commit +1, prior witness chain, and direct root record;
it never opens SQLite.

### 5.3 Eight closed RPCs

All use the common header and `daemon_receipt_v2`; all returned object bytes are
inside the response payload and bound by response payload SHA.

| RPC/domain | caller and method fields | only successful effect/result |
|---|---|---|
| offer / `macprovider-r27/serving-offer-request-v1` | broker; full `serving_pin_v1` bytes/SHA, artifact-lock identity, worker requirement SHA | daemon locks exact artifact, publishes offered handoff, returns ticket/handoff bytes and one read-only FD |
| accept / `.../serving-accept-request-v1` | worker; ticket, handoff SHA, pin SHA, worker launch nonce SHA; exactly one XPC FD | same message audit identity and passed FD must match; daemon publishes accepted handoff then first `accepted` worker v3 and returns its full bytes |
| finalize / `.../serving-finalize-request-v1` | broker; full prepared-to-running CAS witness bytes/SHA and accepted worker SHA | verifies witness, publishes `running` worker successor containing witness SHA, removes/fsyncs handoff, returns full successor |
| heartbeat / `.../serving-heartbeat-request-v1` | same worker connection; predecessor record bytes/SHA, next sequence/time | publishes one running successor, returns full bytes |
| terminal / `.../serving-terminal-request-v1` | worker; predecessor and exact signed completion bytes/SHA after closing its artifact FD | daemon independently acquires the exclusive artifact lock, publishes one normal terminal successor, returns full bytes |
| abnormal-terminal / `.../serving-abnormal-terminal-request-v1` | broker; predecessor, terminating/quarantine CAS witness, reason | daemon independently proves process absence/identity change and exclusive lock or verified reboot; publishes failed/expired/quarantined terminal successor |
| recovery / `.../serving-recovery-request-v1` | broker; exact SQL row bytes/SHA, last witness bytes/SHA nullable | daemon direct-opens only the derived handoff/worker leaves and returns signed full bytes or signed absence; never enumerates or changes state |
| delete / `.../serving-delete-request-v1` | broker; terminal-to-free CAS witness, exact terminal worker bytes/SHA | daemon independently rechecks root/process/lock, then deletes/fsyncs terminal worker and returns delete receipt |

After the eleven common header fields, exact method field order is:

- offer: `serving_pin_bytes, serving_pin_sha256,
  artifact_lock_identity_sha256, worker_requirement_sha256`;
- accept: `ticket_uuid, handoff_bytes, handoff_sha256, serving_pin_sha256,
  worker_launch_nonce_sha256`; the XPC FD is outside tuple bytes;
- finalize: `broker_cas_witness_bytes, broker_cas_witness_sha256,
  accepted_worker_bytes, accepted_worker_sha256`;
- heartbeat: `predecessor_worker_bytes, predecessor_worker_sha256,
  next_heartbeat_sequence, next_heartbeat_continuous_ns`;
- terminal: `predecessor_worker_bytes, predecessor_worker_sha256,
  serving_completion_bytes, serving_completion_sha256`;
- abnormal-terminal: `predecessor_worker_bytes,
  predecessor_worker_sha256, broker_cas_witness_bytes,
  broker_cas_witness_sha256, abnormal_reason`;
- recovery: `sql_row_bytes, sql_row_sha256,
  last_broker_cas_witness_bytes-or-null,
  last_broker_cas_witness_sha256-or-null`;
- delete: `broker_cas_witness_bytes, broker_cas_witness_sha256,
  terminal_worker_bytes, terminal_worker_sha256`.

Bytes/SHAs are adjacent and must recompute; counters/status use u63, reason uses
text, and only fields named `or-null` accept tuple null. The full domains replace
the `...` abbreviation in the table with literal `macprovider-r27`; schema is
the domain suffix with hyphens changed to underscores. No other field or order
is accepted.

Offer, accept, finalize, heartbeat, terminal, abnormal terminal, recovery, and
delete have distinct schema strings and exactly the listed fields. An operation
may be repeated only with byte-identical request tuple and exact predecessor;
same UUID/different bytes, wrong actor, key, database/generation, slot, permit,
request bytes/SHA, pin, handoff, record, witness, heartbeat, or state rejects.
No ciphertext or serving pin may move to a different provider/model/artifact.
After authorityd restart a still-live worker reconnects with a heartbeat request
on a new raw-XPC connection; exact-message code identity plus the worker-record
PID/pidversion/start/CDHash/boot tuple, inherited artifact FD, request identity,
and predecessor SHA must all match. A numeric PID or prior connection alone is
never sufficient.

Abnormal recovery iterates literal slots 0...31. For each nonfree slot it
obtains signed recovery evidence, terminalizes any process only under exact
identity plus lock/verified-reboot proof, signs and commits the registered
quarantine/free witnesses, deletes the root record, and executes the existing
free CAS which increments slot generation. It continues after per-slot typed
failures while making that slot unavailable. The acceptance fixture fills all
32 slots, kills/execs/reboots every worker across the defined cases, and must
end with 32 free rows, no handoff/worker leaves, and all generations +1. A
33rd slot always rejects before spawn. Timeout, `kill(pid,0)`, or `ECHILD`
alone never terminalizes or frees anything.

## 6. Destructive maintenance, backup, restore, and retirement

### 6.1 Signed zero-lease and broker state

`lease_set_zero_v1`, final domain `macprovider-r27/lease-set-zero-v1` and
unsigned domain `macprovider-r27/lease-set-zero-unsigned-v1`, contains
schema/protocol, database ID, generation text, 32 ordered entries each holding
slot ordinal/generation/state/complete row SHA, `nonfree_count:u63=0`,
`open_operation_count:u63=0`, `snapshot_lease_count:u63=0`,
`backup_session_count:u63=0`, `broker_client_count:u63=0`, database connection
count 0, broker boot UUID, observation continuous ns, broker key ID, and
signature over the unsigned domain. All slot states must be `free`; an omitted,
duplicated, unordered, or nonfree slot rejects.

`broker_authority_state_witness_v1`, domains
`macprovider-r27/broker-authority-state-witness-{unsigned-,}v1`, contains:
schema/protocol, witness UUID, purpose `export|restore|retire|destroy`, exact
trigger request SHA, broker issuer key/designated-requirement/CDHash, database
ID/generation, bootstrap/intent/schema/registry/semantic/format SHAs, main file
identity/SHA/length, exact SQL state `absent|terminal`, exact format state
`absent|selected-successor|selected-self`, lease-set bytes/SHA, SQLite close
return code 0, last transaction committed boolean, `F_FULLFSYNC` return code 0
for main and parent directory, rollback-journal/WAL/SHM states all `absent`,
boot UUID, monotonically persisted broker maintenance sequence, issued and
expiry continuous times (maximum five seconds), predecessor state-witness SHA
nullable only at sequence 1, and broker signature. It is created only after
the broker rejects new clients, drains operations, verifies zero leases on the
single SQLite connection, commits, runs integrity/FK checks, closes SQLite,
directly checks journal state, full-fsyncs main/parent, and reopens no database.
The broker stores its latest signed witness at one fixed provider-root leaf by
prefix/fsync/rename/parent-fsync; sequence/predecessor make replay closed.

### 6.2 Daemon-issued maintenance lease

Authorityd authenticates the witness, directly reopens/re-hashes the exact
main/format files component-wise, checks main identity/length/hash, directly
requires the registered journal/WAL/SHM leaves absent, checks its own live XPC
operation count, handoff/worker final/prefix set at all 32 derived paths, open
artifact-lock FD set, backup leases, and existing maintenance leaf. It does not
open SQLite or accept an unsigned SQL claim.

If broker and daemon facts agree, it publishes exactly one root-owned
`maintenance/current.lease-v1` containing domain
`macprovider-r27/maintenance-lease-v1`, schema/protocol, lease UUID, purpose,
trigger request SHA, broker state-witness SHA, lease-set SHA, database ID,
generation text, main/format/root identities, daemon boot UUID, daemon sequence,
issued/expiry (maximum 30 seconds), predecessor maintenance SHA nullable only
on first issue, state `active|consumed`, daemon key ID, and signature. Restore
or retire must present the active bytes/SHA and exact trigger request SHA.
Before the destructive filesystem effect, daemon atomically writes a consumed
successor and fsyncs; replay of either active or consumed lease has no second
effect. Crash before consumed publication leaves no effect; crash after it
reconciles the one derived target and completes or returns the same receipt.
Expired/stale boot, sequence, request, witness, key, root, main, journal, live
lease, connection, worker, backup, or alternate-purpose values reject.

### 6.3 Acyclic backup envelopes

`backup_envelope_unsigned_v1`, domain
`macprovider-r27/backup-envelope-unsigned-v1`, has exactly:
schema/protocol, backup UUID, database ID/generation, bootstrap ID, intent bytes
(619)/SHA, database-directory identity, authority-root identity, provider-root
identity, main component length/SHA, exact format bytes (806)/SHA, schema
length/SHA, registry length/SHA, dispatch length/SHA, semantic length/SHA,
artifact-lock-set count/digest, 32-free-slot lease-set bytes/SHA, broker state
witness bytes/SHA, creation boot/time, and broker key ID. No receipt or envelope
SHA occurs inside it. Its SHA is over these exact bytes.

Export request binds that unsigned SHA and state witness SHA. The daemon export
receipt binds the exact request SHA, unsigned SHA, intent SHA, root identity,
backup UUID, main/format hashes, and response bytes. Only then does the broker
construct `backup_envelope_v1`, final domain
`macprovider-r27/backup-envelope-v1` and signature domain
`macprovider-r27/backup-envelope-signature-v1`, fields: schema/protocol,
`unsigned_envelope_bytes`, `unsigned_envelope_sha256`,
`export_receipt_bytes`, `export_receipt_sha256`, broker key ID, and broker
signature. Fields 1...7 are signed and field 8 is the signature. The final envelope SHA is computed
after the signature and is not embedded in either envelope.

Restore request binds final envelope bytes/SHA, unsigned bytes/SHA, export
receipt bytes/SHA, new signed state-witness SHA, and active maintenance lease
SHA. The daemon independently parses and recomputes both envelopes, verifies
both key chains and the export request SHA, compares root/database/generation/
main/format/intent operands, and restores only into the same authority root.
Splicing any component, length, receipt, key, root, generation, backup UUID, or
request changes a bound digest and rejects. Metadata envelopes are capped at
262,144 bytes; main bytes are a separately hashed bounded component and are
never copied through XPC.

Retire uses the same state-witness/maintenance chain. Cancel-before-main
requires absent SQL/main and zero leases; replacement retirement requires the
exact durably selected successor format, terminal old SQL, and zero leases;
whole-authority destroy requires explicit stopped operator intent plus terminal
SQL and zero leases. The daemon directly verifies filesystem facts and uses
the signed broker proof only for broker-owned SQL state. It deletes only the
one derived intent after consumed-lease publication and parent fsync.

## 7. Bootstrap publication and irreversible B8

Create opens only the exact temp using
`O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC`, mode 0600. After any crash, temp
lengths 0...618 are validated as exact prefixes of the deterministic tuple,
then unlinked and parent-fsynced; their nonce is retired and a fresh nonce is
used. This expressly contains the requested 0...602 range. Exact 619 bytes is
decoded/recomputed and may rename without a new nonce. Above 619, a non-prefix,
wrong ownership/identity, unexpected existing temp collision, temp plus final,
or two possible sources protects without unlinking. Exact final alone returns
idempotently after byte/identity verification. No main open/create is permitted
until final parent fsync and signed create receipt.

B8 writes and fsyncs exact 806-byte `format.json.tmp-v6`, renames it over the
fixed `format.json`, and calls parent-directory fsync. A successful parent fsync
is the sole online irreversible boundary. Reopen and all daemon/SQL validation
happen **after** selection; failure protects V5 and never re-enables R4.

After a crash, a fresh component-wise reopen of an exact final format-v6 is the
durable recovery selection predicate, whether the prior fsync returned before
the process died or the filesystem made the rename durable during an ambiguous
fsync. Exact old R4 final plus absent/partial temp is preselection; exact old R4
plus full valid temp resumes rename/fsync; exact v6 final is selected; malformed
or dual selector state protects. There is no durable state whose authority
depends on remembering a successful reopen. After the selected predicate, no
R4 open, read, write, readiness, economics, serving, or rollback is allowed.

## 8. Bounded physical state

The following maxima are independent of generation width because generation
text is always 20 bytes:

| class | bound |
|---|---:|
| SQL bootstrap intent | 619 bytes |
| selected plus candidate intent final/prefix | 1,238 bytes |
| format final plus temp | 1,612 bytes |
| 32 handoff final plus 32 prefixes | 524,288 bytes |
| 32 worker final plus 32 prefixes | 95,104 bytes |
| active/consumed maintenance final plus prefix | 8,192 bytes |
| root install/key manifests | 24,576 bytes |
| authorityd protocol files total | 653,398 bytes |
| backup metadata envelope | 262,144 bytes per bounded active backup session |

The protocol-file total is 1,238 + 524,288 + 95,104 + 8,192 + 24,576.
Format/SQL/backup components are accounted in their owning budgets, not counted
twice. One broker permits one active backup session. Existing 448 MiB main,
64 MiB rollback journal, 1,024 row, 32 serving-slot, registry/event/counter, and
free-space bounds remain. A third intent generation, second temp, 33rd handoff
or worker, 8,193-byte record, second maintenance leaf, 262,145-byte envelope,
or first-over connection/RPC is rejected before mutation.

## 9. Compatibility, migration inventory, and implementation order

The post-B8 inventory now includes every production Swift/C/header/plist/script
under all five new target roots, `phase3-binary/Package.swift`, both launchd
plists, app `project.yml`, installer/uninstaller/update/package scripts, plus
the accumulated 191 CLI/Malibu Swift files. It retains every R31 direct durable
caller, including MacProviderCLI, AutotuneRecommend, ModelCatalogLocalInspection,
DurableModelDiscovery, ModelCatalogRead, ModelManagement, BYOMDiscovery,
ModelRuntime, and every app/headless consumer. AST, SIL/call-graph, string-literal,
binary-symbol, plist, codesign, package-payload, and syscall gates forbid direct
R4/custody/durable authority after B8 outside the broker/daemon.

The fetched delta from `7c0aad11` to `7128d120` has a literal
`ModelRuntime.swift` path overlap. Its hunks add SPEC-038/039 paged-KV scheduler
bridging and do not alter an authority callsite. This is read-only evidence;
the complete inventory and all tests are regenerated from the eventual merged
base, so no prior 191-file digest is reused as proof.

The frozen supported predecessor is binary version 1.8.123 from exact
`origin/main` above. Before implementation merges, the release manifest must
pin SHA-256/signing/notarization identities for its standalone CLI, Malibu.app
embedded CLI/app bundle, provider/headless plists, updater metadata, installer,
and uninstaller. R33 launches those immutable bytes against selected v6 and
requires fail-closed/no-R4 behavior. If any predecessor entrypoint touches R4
or presents readiness/economics, implementation must add the pre-B8 installer
minimum-version fence and protected ownership boundary before B8; the test is
not waived and old bytes are not modified.

After plan approval, slices are: normative SPEC update; canonical codecs and
goldens; XPC shim/protocol library; signed installer anchors and daemon; broker
and state/CAS witnesses; bootstrap/backup/B8; serving lifecycle; accumulated
client/app migration; frozen-predecessor/release/physical-Mac acceptance; then
complete-diff code, security, and architecture audits. Architecture, wire,
scope, or test-strategy changes reopen the plan gate.

Rollback is code rollback only before B8. After B8 only same-version recovery,
supported restore, or fresh forward replacement exists. Metrics expose counts,
protocol/version, truncated IDs, freshness, and typed protection states; never
paths, tuple/request/model bytes, nonce, audit token, key, inode, or full digest.

R27 adds no pricing, admission, settlement, rewards, payout, enforcement,
release, deployment, production activation, hardware qualification, or general
root file service. A plan gate is not implementation or product acceptance.

## 10. Author verification record

Fresh author oracles ran on Darwin 25.5.0 arm64 with Apple Swift 6.3.3, Python
3.14.7/SQLite 3.53.4, shell SQLite 3.51.0, and Node 22.23.2. Independent tuple
and JCS encoders reproduced R26 before deriving the R27 vectors. Public SDK
headers declare `SecCodeCreateWithXPCMessage`, `xpc_connection_get_euid`,
`xpc_connection_get_pid`, `xpc_dictionary_get_data`, `xpc_fd_create`, and
`xpc_fd_dup`. These prove API and plan shape, not the mandatory signed package,
cross-UID, PID-reuse, physical-Mac, app, actual-MLX, or production evidence.
R33 records exact executable commands and expected results. Final R27/R33 file
hashes are reported outside these self-referential artifacts.
