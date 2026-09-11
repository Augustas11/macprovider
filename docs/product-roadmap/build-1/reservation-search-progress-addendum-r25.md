# Build 1 reservation search progress addendum R25

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

R25 corrects the exact rejected R24/R30 candidate. R25 and R24 are read
together. R25 replaces R24 sections 3, 4.1 through 4.3, and 5 wherever this
document speaks; all other R24 and accumulated R23 requirements remain
mandatory. R31 replaces R30 only where R31 says so and otherwise carries every
R30/R29 test forward. No earlier rejected text overrides an R25 rule.

The frozen failed review is
`docs/product-roadmap/build-1/reviews/reservation-search-progress-r24-plan-sol.md`,
SHA-256 `36fb0a20f3d0f118d244865f2d6904c732631e503bc90c965af7c485cab03e14`,
committed at `e45f80e6ad3b075e63a3568f2c526faf2272aa27`. It reports exactly
0 Critical, 4 High, 1 Medium, and 0 Low findings. The reviewed R24 and R30
inputs are `9bbaf6ad3edcfe3cbab33da045914fa5a52f4f209f2dc9ee7cd2cb6589eb5321`
and `6d5586836618a5d4b110a4f393e9368c7646141149c6998e87d371027ba0783f`.
This author slice changes only R25 and R31. It changes no Swift, C, test, SPEC,
release, deployment, operator-secret, or d-inference file.

## 1. Exact finding dispositions

| finding | required R25 correction | exact R31 proof |
|---|---|---|
| R24-PLAN-H1 pre-create identity contradiction | `L0 lock-create-authorized` has no leaf-derived field; `L1 lock-created` is published only after creation, leaf fsync, parent fsync, and identity capture | R31-03 |
| R24-PLAN-H2 mutable parent identity | one stable placement identity excludes directory size, mtime, ctime, and link count while retaining custody-root/path/device/inode/birthtime/ownership/mode/flags checks | R31-04 |
| R24-PLAN-H3 deleted bootstrap authority | schema v25 retains the raw nonce, exact intent bytes/SHA, bootstrap ID, and database identity in one immutable SQL row; the exact intent file is retained for the database lifetime and in backups | R31-02/R31-05 |
| R24-PLAN-H4 impossible provider-UID direct open | `TrustedCustodyDaemonV5`, running as root, is the only process allowed to create or open lock leaves; it passes one read-only locked FD through an authenticated, recorded, bounded handoff | R31-06 |
| R24-PLAN-M1 incomplete readiness inventory | all direct `MacProviderCLI`, `AutotuneRecommend`, resolver, verifier, durable-store, preflight, self-test, prefetch, and benchmark call edges are classified and gated | R31-07 |

No finding is downgraded, waived, or answered by reducing acceptance. The
implementation gate remains closed until an independent native GPT-5.6 Sol
review of the exact R25/R31 hashes reports zero Critical, High, and Medium
findings.

## 2. Frozen registries and schema v25

### 2.1 Registry and semantic bytes do not change

R25 does not alter R24 Appendix A, Appendix B, or Appendix C. The canonical
transition registry remains exactly 495 records, 68,992 bytes, SHA-256
`d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`.
The dispatch stream remains 1,309 bytes, SHA-256
`af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`.
The semantic tuple remains 97,959 bytes, SHA-256
`0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`.
`L0`, `L1`, and descriptor handoff are external custody protocol states; they
do not add, remove, rename, or renumber a SQL transition-registry record or
change its DML counts.

### 2.2 Machine-exact schema derivation

Schema v25 is derived from the exact 43,652-byte R23 Appendix A SQL stream,
SHA-256 `70b34abd8229e8a90bd45e0de6c283d33bf1af96a096193d9301e37dba7bf81f`,
by these three ordered byte transformations, each required to match exactly
once:

1. replace `PRAGMA user_version=23;\n` with `PRAGMA user_version=25;\n`;
2. replace `schema_version INTEGER NOT NULL CHECK(schema_version=23)` with
   `schema_version INTEGER NOT NULL CHECK(schema_version=25)`;
3. immediately before the first byte of `CREATE TABLE serving_slots(` insert
   the following one-line LF-terminated statement:

~~~sql
CREATE TABLE bootstrap_authority(id INTEGER PRIMARY KEY CHECK(id=1),database_instance_nonce BLOB NOT NULL CHECK(length(database_instance_nonce)=32),bootstrap_intent_bytes BLOB NOT NULL CHECK(length(bootstrap_intent_bytes) BETWEEN 1 AND 65536),bootstrap_intent_sha256 BLOB NOT NULL CHECK(length(bootstrap_intent_sha256)=32),bootstrap_id BLOB NOT NULL UNIQUE CHECK(length(bootstrap_id)=32),database_identity_sha256 BLOB NOT NULL UNIQUE CHECK(length(database_identity_sha256)=32),retention_policy TEXT NOT NULL CHECK(retention_policy='database-lifetime')) STRICT;
~~~

No other byte changes. The result is exactly 44,213 bytes, SHA-256
`2bcde8dd97fa1cb063ad09b41db8b895ec64cf6fa2fabd38b15c4d1dc671547e`,
and creates 24 non-internal tables and 11 non-auto indexes in SQLite. It has
`application_id=1297109587` and `user_version=25`. B3 inserts exactly one
`bootstrap_authority` row in the same transaction that creates and fills
`protocol_meta`. The inserted intent bytes are the exact already-durable final
intent file bytes, not decoded/re-encoded bytes. Application validation, not a
SQLite extension or trigger, must byte-compare the row SHA to SHA-256 of those
bytes and require both ID fields to equal independently recomputed values.

B3 now inserts exactly 1,560 logical rows: one `protocol_meta`, one
`bootstrap_authority`, 495 transition-registry, six fixed-state, 1,024 row-slot,
one GC-meta, and 32 serving-slot rows. This is one more than the inherited B3
shape and changes no post-bootstrap transition record or count. Zero/two
bootstrap-authority rows, 1,559/1,561 total inserted rows, or a partial B3
transaction rejects.

The row is immutable after B3. The permanent authorizer denies its INSERT
after the one B3 insertion and denies every UPDATE or DELETE. It is included
in startup table/count/schema allowlists, integrity checks, maximum-shape
accounting, backup envelopes, restores, and database destruction. There is no
online rotation or second row. Fresh replacement creates a different database
and row.

## 3. Retained bootstrap authority and exact identities

### 3.1 First durable object and lifetime

B0 still obtains exactly 32 bytes from `SecRandomCopyBytes` before candidate
main creation. A short read or failure leaves no durable identity. The first
complete durable object remains the prefix-resumable final bootstrap intent.
It contains the raw nonce and every R24 bootstrap operand. Once the intent is
durable, every retry uses those bytes and never draws another nonce.

R25 deletes R23 B6a's deletion action. The selected intent is never deleted,
renamed independently, truncated, rewritten, or replaced. It travels with the
candidate directory during B7 rename and remains directly addressable at the
same relative leaf in the selected authority for that database's lifetime.
At B3, the exact bytes, their SHA-256, the nonce, bootstrap ID, and database
identity are copied into `bootstrap_authority`. Before B3 commit, after every
bootstrap reopen, before B7, after every B8 recovery state, and at every normal
startup, the broker requires all of the following:

- the retained file is the expected regular root-owned, no-follow, one-link
  leaf at the captured directory entry;
- direct file bytes equal `bootstrap_authority.bootstrap_intent_bytes`;
- direct SHA equals both the row SHA and the SHA carried by the backup/format
  authority;
- the row nonce and operands independently recompute its bootstrap ID;
- the bootstrap ID and candidate-directory operand independently recompute its
  database identity;
- both recomputed IDs equal the row and `protocol_meta` bindings.

Any absence, partial prefix after B3, alternative nonce, same decoded values in
different bytes, row/file splice, or recomputation mismatch protects before a
catalog read or external effect. Exact unselected E0/E1 rollback may remove an
incomplete/unselected intent and retires that nonce. From B3 onward recovery is
forward-only. Offline destruction of the entire retired authority may remove
the selected intent together with the database; no online cleanup may remove
it.

The R23 recovery table is changed only as follows. P6 contains intent plus main
and its unique successor is B7 rename; P6a without an intent is invalid for
schema v25 and protects. P7, P8p, P8f, P8r, and S all contain the exact retained
intent. Every prefix/full intent crash before B3 follows E0/E1/E2 as before;
every B3 statement crash either exposes no committed `bootstrap_authority` row
or the complete row with the complete schema transaction. No state permits a
main file with a committed partial row.

### 3.2 Exact v25 bootstrap and database identities

R25 uses the R24 field order and `tuple_v1` encoding with these substitutions:
domain `macprovider-r25/bootstrap-id-v1`, schema digest
`2bcde8dd97fa1cb063ad09b41db8b895ec64cf6fa2fabd38b15c4d1dc671547e`,
and `user_version:u63=25`. All other 12 bootstrap fields and types remain as
listed in R24 section 3.1. For nonce bytes `00...1f`, source-index `11` repeated
32 bytes, source-rows `22` repeated 32, the frozen registry/semantic digests,
application ID 1297109587, page size 4096, journal `DELETE`, and broker
protocol 1, the preimage is 305 bytes and hashes to
`64037a80513491ca37860906a07cccc02f0fe820d4f723d436de725fbc65a12c`.

The database tuple uses domain `macprovider-r25/database-identity-v1`, the
same R24 13-field order, that v25 bootstrap ID, the v25 schema digest, and
`user_version:u63=25`. With candidate-directory identity `33` repeated 32
bytes, its preimage is 344 bytes and hashes to
`093b75a7a504aa6aee4cbcf5d7dfe9aff5f945216c48d223aea8af2a6fc25b3f`.
These v25 values replace the R24 database golden vector everywhere. The frozen
registry and semantic digests do not change.

### 3.3 Backup, restore, replacement, and deletion

A supported backup contains the exact selected main bytes, exact retained
intent bytes, complete `bootstrap_authority` row, complete 44,213-byte schema,
registry/dispatch/semantic bytes, all R24 lock evidence, and an envelope that
binds every component SHA and byte length. Restore preserving identity requires
the same stopped authority, same captured root, same never-replaced lock
directory and leaves, and equality of the file, row, meta, and envelope copies
before selection. Restoring a raw main, omitting the intent, reconstructing
equivalent intent bytes, changing the row, using a new authority root, or
running the original concurrently rejects. Disaster recovery to a new root is
a fresh replacement with a new nonce and unequal bootstrap/database identity.

Backup creation and restore read the intent by its direct registered path; they
do not enumerate. A backup never contains signing private keys. Deleting a
backup cannot delete the live intent or rotate identity. Removing the selected
intent is authority corruption and protects; it is not a request to rebootstrap.

## 4. Stable lock-directory placement and two creation states

### 4.1 Stable placement identity

The root daemon creates and captures `artifact-locks` exactly as R24 requires,
but R25 replaces the inherited complete file-identity digest for this directory
with `directory_placement_identity_sha256`. It is SHA-256 of `tuple_v1` domain
`macprovider-r25/directory-placement-identity-v1` and these 14 fields in order:

1. `schema:text`, literal `directory_placement_identity_v1`;
2. `custody_root_file_identity_sha256:sha`, the unchanged complete R23 identity
   of the captured custody root;
3. `relative_path:bytes`, literal ASCII `artifact-locks`;
4. `relative_path_sha256:sha`, the R23 registered path digest;
5. `device_id:u63`;
6. `file_id:u63`;
7. `file_type:text`, literal `directory`;
8. `mode:u63`, `st_mode & 07777`, exactly octal 0700;
9. `owner_uid:u63`, exactly root;
10. `group_gid:u63`, the root group frozen at bootstrap;
11. `birthtime_seconds:u63`;
12. `birthtime_nanoseconds:u63`;
13. `user_flags:u63`, exactly zero;
14. `system_flags:u63`, exactly zero.

Directory byte length, mtime, mtime nanoseconds, ctime, ctime nanoseconds, and
link count are deliberately excluded because Darwin/APFS changed all of the
observed mutable values, including directory link count, during a permitted
regular-child create. They are never silently substituted for any retained
field. The daemon still captures their current values for before/after
diagnostic race comparison within one operation, requires link count within
2...1026, and records the exact pre/post counts in the durable L0/L1 operation
records. It permits a change only across the one serialized authorized leaf
creation. These mutable values do not enter a persistent identity or cause a previous
leaf binding to become stale solely because another authorized leaf was
created. The root-only directory, captured device/inode/birthtime, literal
leaf set, and one-create state machine remain the child-membership authority.
The daemon rejects every request for an unregistered child or subdirectory and
never offers a directory-enumeration API; root is part of the trusted boundary.

Every leaf operation starts from the captured custody-root FD, opens the literal
`artifact-locks` component with `openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`,
and compares `fstatat(AT_SYMLINK_NOFOLLOW)` with `fstat`. The full 14-field
placement identity must match before and after the leaf open/flock. Parent
rename, unlink/replacement, symlink, device or inode change, birthtime change,
mode/owner/group/flag change, link count outside 2...1026 or changing by
anything other than exactly +1 across the one authorized-create boundary,
ACL/xattr outside the explicit empty
allowlist, directory child of any type, or leaf name outside the 1,024
registered artifact digests protects. Root is the only writer. There is no
general filesystem API exposed over XPC. Thus excluding timestamps permits
only the already-authorized regular-leaf mutation; it does not weaken
placement, traversal, or ownership confinement.

Golden vector: custody-root identity `44` repeated 32 bytes; relative path
`artifact-locks`, whose path SHA is
`f17dbae407d2b854f2a2714bc52bec0997556d1bab0503dfc1ada974d15fcf64`;
device 16777229; file 12345; directory; mode 448; UID/GID zero; birthtime
1700000000 seconds and 123456789 ns; flags zero. The 268-byte tuple hashes to
`a278cc0e972bfa9e4138b67c25b16a4799508b386a87f218b3a5c9bd5aefe207`.

### 4.2 `L0 lock-create-authorized` and `L1 lock-created`

The first custody operation for an artifact uses two distinct durable states.
They are stored at the exact custody-operation path and linked by prior-record
SHA. The global one-open-custody-operation invariant prevents a second creator.

`L0 lock-create-authorized` is published and parent-fsynced before any create
call. It binds database identity, operation/source/model/release/artifact and
manifest identity, placement identity, exact relative lock path/path SHA, and
all existing custody path/cursor fields. It records the current parent link
count as `precreate` and a canonical-null `postcreate` count. Its
`artifact_lock_leaf_file_identity_sha256` and
`artifact_lock_identity_sha256` fields are **canonical null**. A non-null value
in L0 rejects; no placeholder, predicted inode, all-zero digest, path digest,
or caller assertion is accepted.

Only from exact L0 may the root daemon call
`openat(parentFD, leaf, O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600)`.
It verifies root UID/GID, regular type, mode 0600, link count one, size zero,
same device, empty ACL/xattr allowlist, and stable leaf `fstatat/fstat`; fsyncs
the leaf; fsyncs the parent; computes the complete R23 leaf identity; and then
publishes and parent-fsyncs `L1 lock-created`. L1 carries both non-null derived
digests and requires `postcreate=precreate+1`. C0 is the only successor of L1.
Every C0...C7 record also requires
both digests non-null and identical to L1.

Crash recovery is finite and exact:

| durable operation state | leaf state | only legal recovery |
|---|---|---|
| before complete L0 | absent | remove an exact prefix temp and retry L0; no leaf identity exists |
| before complete L0 | present | protect; no durable create authority exists |
| complete L0 | absent and current link count equals recorded precreate | execute the one create sequence, require postcreate=precreate+1, and publish L1 |
| complete L0 | exact pristine leaf and current link count equals precreate+1 | acquire `LOCK_EX`, repeat all direct checks, fsync leaf/parent, derive identity, publish L1; this is the only orphan adoption |
| complete L0 | any other leaf | protect without rename, unlink, chmod, chown, truncation, or replacement |
| complete L1 or C0...C7 | exact stored leaf | direct-open without CREATE/TRUNC, revalidate identity, continue the unique successor |
| complete L1 or C0...C7 | absent or different identity | protect; a published leaf is never recreated |

The L0-present adoption is safe only because the root-owned 0700 parent has one
named root daemon creator, L0 precedes create durably, and one custody operation
is open. Its result is a newly observed identity written only to L1. Recovery
does not claim that an identity existed in L0.

For an already published artifact leaf, a later custody operation skips L0/L1:
the daemon direct-opens and validates the SQL/receipt-derived leaf and begins at
C0 with both identities non-null and precreate/postcreate both equal to the
same observed current parent link count. An ENOENT or mismatch protects. The maximum
remains one never-unlinked leaf for each of 1,024 artifact slots.

### 4.3 Exact custody-operation v3 amendment

Only `custody_operation_v2` is superseded by `custody_operation_v3`. Its tuple
domain is `macprovider-r25/custody-operation-v3`, schema text is
`custody_operation_v3`, and daemon protocol is u63 3. Its complete field order
is:

~~~text
schema:text
daemon_protocol_version:u63
database_identity_sha256:sha
operation_uuid:uuid
row_ordinal:u63
transaction_uuid:uuid
model_id:text
release:text
artifact_sha256:sha
artifact_lock_creation_phase:text
artifact_lock_parent_placement_identity_sha256:sha
artifact_lock_parent_precreate_link_count:u63
artifact_lock_parent_postcreate_link_count:u63-or-null
artifact_lock_relative_path:bytes
artifact_lock_path_sha256:sha
artifact_lock_leaf_file_identity_sha256:sha-or-null
artifact_lock_identity_sha256:sha-or-null
manifest_sha256:sha
staging_receipt_sha256:sha
source_token_sha256:sha
temp_root_path_sha256:sha
temp_receipt_path_sha256:sha
final_root_path_sha256:sha
final_receipt_path_sha256:sha
entry_cursor:u63
flag_cursor:u63
receipt_byte_cursor:u63
custody_phase:text
prior_record_sha256:sha-or-null
record_sha256:sha
~~~

There are exactly 30 fields. `artifact_lock_creation_phase` is
`lock-create-authorized` only with `custody_phase=L0`, `lock-created` only with
`custody_phase=L1`, and `published` only with C0...C7. The two leaf-derived
fields and postcreate link count are null if and only if phase is L0. In L1,
postcreate equals checked precreate+1. In C0...C7 after L1 those counts retain
the L1 values; for an already published leaf they are equal to the same current
observation. Leaf fields are non-null in L1 and every C phase.
`prior_record_sha256` is null only at the first L0 or, for a previously
published leaf, the first C0; otherwise it names the exact predecessor.
`record_sha256` is SHA-256 of the tuple encoded with only that last field null.
All text/path/UUID/SHA limits and the R23 C0...C7 cursor rules remain.

The artifact-lock identity uses domain
`macprovider-r25/artifact-lock-identity-v1` and the same seven R24 fields, but
field 6 is the stable placement identity above. For v25 database golden ID,
artifact `ab` repeated 32, the unchanged 87-byte canonical leaf path/path SHA,
placement golden digest above, and leaf identity `55` repeated 32, the preimage
is 333 bytes and hashes to
`42fbdb037c2c1adad5af9f989a2cba31740af29311f4ac8c5cf520ba6762d744`.
All R24 receipt, SQL, serving, replacement, and GC bindings consume this v25
identity. R24 affected v2 codecs other than custody-operation retain their
field order and version but use the v25 database and artifact-lock values.

## 5. Coherent root daemon descriptor authority

### 5.1 Actors and open authority

`TrustedCustodyDaemonV5` is the root launch daemon already responsible for
staging-to-custody publication. R25 makes it the sole creator and sole opener
of `artifact-locks` and its mode-0600 root-owned leaves. The provider-UID
`CatalogAuthorityBrokerV5`, provider app/CLI, and inference worker never call
open/openat on that directory or pathname. Replacement and GC also request an
exclusive descriptor from the root daemon; R24's language assigning their
direct open to the broker is replaced.

The daemon accepts only its named NSXPC service. The current macOS SDK exposes
public `NSXPCConnection.processIdentifier` and `effectiveUserIdentifier` but no
public XPC audit-token getter. R25 therefore does not use the private
`xpc_connection_get_audit_token` SPI. On connection, the daemon returns a
random 32-byte, single-use challenge bound to that connection object, its
public PID/UID, current boot session, and a continuous-clock five-second
deadline. The client sends that challenge in one fixed-size message to the
daemon's separately named launchd Mach attestation port. The daemon receives
with `mach_msg` and `MACH_RCV_TRAILER_AUDIT`, takes the kernel-supplied
`audit_token_t` from the trailer, and requires its PID/UID to equal the live
NSXPC connection. It then passes that token as `kSecGuestAttributeAudit` to
`SecCodeCopyGuestWithAttributes`, derives pidversion/code identity with public
Security/proc APIs, consumes the challenge, and marks only that connection
authenticated. Invalidation, timeout, replay, PID/UID/token mismatch, or a
second message clears/denies the connection.

The authenticated identity must satisfy the installer-pinned broker designated
requirement, provider UID, current boot session, and approved cdhash/version.
Caller-supplied audit fields are comparisons only. A provider app, old broker,
wrong UID/team/cdhash, replayed connection, anonymous endpoint, or passed
directory/leaf FD is denied before path access. Requests contain one complete
catalog/custody/slot tuple; the daemon offers no caller-selected absolute path,
relative component, open flags, mode, unlink, rename, write, or generic file
operation.

Descriptor transfer uses `NSFileHandle`, whose SDK declaration conforms to
`NSSecureCoding`, over that authenticated NSXPC connection. The daemon and
receiver immediately duplicate into owned raw descriptors and close the
transport objects at the specified handoff step. No private XPC descriptor or
audit-token SPI is allowed.

For serving, the daemon derives the leaf path from the artifact SHA, performs
the root-to-leaf direct validation in section 4, opens it
`O_RDONLY|O_NOFOLLOW|O_CLOEXEC`, compares receipt/SQL-supplied identities,
takes `LOCK_SH`, and revalidates. It passes that read-only descriptor. A worker
cannot write/truncate through it. For replacement/GC, it opens the same way,
takes nonblocking `LOCK_EX`, revalidates, performs only the separately
authorized custody action, and closes. Exclusive success on a wrong inode never
authorizes an action.

### 5.2 Bounded authenticated serving handoff

The broker first allocates a prepared SQL serving slot and obtains the signed
R24 serving pin bound to the exact request bytes. It then calls the daemon with
that complete tuple. The daemon writes one root-owned direct record at
`lock-handoffs/<slot-ordinal>-<slot-generation>.handoff-v1`. There are exactly
32 possible live paths, derived from the fixed SQL slots; neither actor
enumerates the directory. A new generation cannot overwrite a nonterminal
record. The record is prefix-written, fsynced, renamed, and parent-fsynced.

`lock_handoff_v1` uses domain `macprovider-r25/lock-handoff-v1` and these 32 fields
in order: schema text; daemon protocol u63=3; database identity SHA; permit UUID;
slot ordinal/generation u63; request UUID/SHA; model/release text; artifact SHA;
custody generation u63 and event SHA; catalog-binding SHA; artifact-lock SHA;
provider UID u63; broker PID/pidversion u63 and cdhash SHA; worker PID,
pidversion, start seconds/nanoseconds, cdhash, and process group, each canonical
null in `offered` and non-null in `accepted`; boot UUID; issued and deadline
continuous ns, with deadline at most issue+5 seconds; target child FD u63,
literal 203; phase text `offered|accepted|expired|quarantined`; prior-record SHA null only in
offered; record SHA computed with itself null. A protection successor may set
phase to `expired` or `quarantined`: worker fields remain null when the
predecessor was offered and remain the exact non-null values when it was
accepted. Such a record never authorizes release; the broker must complete the
section 5.3 process-and-exclusive-lock proof. The root signing key signs an
otherwise identical `lock_handoff_ticket_v1` tuple omitting phase/prior/record
and adding daemon key ID then signature, for 31 ticket fields. Every field is
covered. A serialized record or ticket over 8,192 bytes rejects before write or
FD transfer.

The handoff sequence is fixed:

1. daemon authenticates the broker, validates identities, opens read-only,
   takes shared lock, publishes `offered`, and returns the FD plus signed ticket;
2. broker verifies ticket, uses `posix_spawn` file actions to duplicate only
   that FD to child FD 203 with `FD_CLOEXEC` clear, closes its copy, and gives
   the ticket to the child;
3. the child connects independently to the daemon, whose kernel audit token
   must match the approved worker code and provider UID, and presents the exact
   ticket/permit plus an XPC duplicate of its inherited FD 203; the daemon
   verifies that returned proof FD is read-only and has the exact expected leaf
   identity, closes only that proof duplicate, independently validates PID/
   pidversion/start/cdhash/process group, and publishes `accepted`;
4. only after `accepted` is durable does the daemon close its retained sender
   descriptor; it returns the accepted record SHA to the broker;
5. the broker publishes the matching serving-worker record and CASes the SQL
   slot to running, then sends a finalize bound to that CAS generation; the
   daemon deletes and parent-fsyncs the handoff record. The worker alone retains
   FD 203 through completion and exit.

Before accepted, daemon and child may briefly share the same open file
description; that only delays exclusive acquisition. After accepted, root and
broker retain no duplicate. The worker verifies `F_GETFD` has `FD_CLOEXEC`
clear, `F_GETFL & O_ACCMODE` is `O_RDONLY`, and checks `fstat`, target FD 203,
ticket, pin, exact request SHA, and one-request framing before
opening artifact bytes. It rejects a writable descriptor, extra request,
different artifact/request/slot, expired ticket, inherited unexpected FD, or
identity mismatch.

The returned proof FD in step 3 is the sole exception to the no-caller-FD rule:
it is accepted only on the authenticated worker connection for the one live
ticket after the daemon has already selected and opened the canonical leaf.
It can prove possession but can never select a path, artifact, identity, flags,
or operation. Any other passed descriptor is rejected and closed.

### 5.3 Crash and restart closure

The fixed SQL slot and direct handoff/worker paths are the only restart index.
For each of 32 slots the broker asks the daemon for that exact handoff path; no
directory enumeration or `waitpid` ownership is inferred.

- crash before `offered` durability leaves no returned FD;
- crash after `offered` and before spawn closes daemon-held FDs on daemon death;
  broker recovery tries the canonical exclusive lock and closes or quarantines
  the prepared slot under the retained R23 process rules;
- broker crash after receipt but before spawn leaves the daemon copy until the
  five-second deadline, after which it closes, marks the record expired, and
  requires broker recovery to prove process absence plus exclusive lock before
  clearance;
- crash after spawn but before worker accept is resolved by exact process
  identity plus exclusive-lock observation; ambiguity quarantines and retains
  the artifact;
- crash after accepted but before SQL running leaves a prepared slot plus an
  accepted record and worker identity. Replacement broker either completes the
  matching worker-record/CAS transition or terminates that exact process and
  requires both process absence and canonical exclusive lock before release;
- daemon restart after accepted has no inherited FD but the worker may hold it;
  it uses the direct record and public process/lock checks and never recreates a
  leaf or assumes descriptor absence;
- crash after SQL running but before handoff-record deletion is cleanup-only;
  exact matching running state permits deletion, mismatch quarantines.

Permission error, unavailable audit identity, deadline uncertainty, record
splice, duplicate accept, broker/worker identity change, stale generation,
same-path new inode, or unknown process/lock state quarantines. GC/replacement
never proceeds from timeout, record absence, or provider assertion alone.

## 6. Complete post-B8 CLI/autotune readiness cutover

R25 extends R24 section 5 and R23 Appendix E with every inspected live direct
durable read. Each named declaration must be present in the generated AST/SIL
inventory even when its source line moves.

| current owner and callsites | post-B8 classification and required consumer |
|---|---|
| `MacProviderCLI.swift` `ServeCommand.localRuntimeTargetAuthorities` and its `CachedModelArtifactResolver.verifiedExistingArtifact` call | serve startup consumes one `CatalogAuthorityV5.runtimeTargets` snapshot; an omitted/unavailable model is not runtime-ready |
| `runDraftModelArtifactPreflight`, its `ModelRuntime.localModelDirectory`, and `ModelArtifactVerifier.canonicalArtifactHash` | broker snapshot when the path is under durable/custody roots or receipts/coordinator join are enabled; only an explicitly provider-owned staging path may use `UntrustedPreparationInspection` |
| `runModelArtifactPreflight`, `requireContainedDurablePathIfOwned`, `resolveVerifiedLoadPath`, `isExistingDirectory`, every `artifactURL`, `validatedContainedDirectory`, and `canonicalArtifactHash` edge | replaced by one broker `resolveServeArtifact` response bound to database/catalog/custody/lock identity; no CLI open/stat/hash fallback |
| `runModelCatalogPreflight`, its `snapshotURL`, `contains`, both direct `adoptVerifiedStaging` calls, durable `artifactURL`, and durable hash edge | staging input may be inspected as untrusted preparation; custody adoption and resulting canonical path/readiness come only from authenticated broker/custody RPC |
| `runServeStartupPreflights`, `ServeCommand.run`, `SelfTestCommand.run`, and `SelfTestCommand.modelLoadPath` | consume the same generation-bound broker response and typed failure; self-test does not regain direct durable authority |
| `AutotuneRecommend.swift` `CachedModelArtifactResolver.durableStore`, `verifiedArtifact`, `prefetchedArtifactPreservingExisting`, both `verifiedExistingArtifact` overloads, `snapshotURL`, `prefetchSnapshotURL` | Hugging Face/provider staging remains untrusted preparation; any durable existence, containment, hash/config, adoption, or path result comes from broker RPC |
| `AutotuneRecommendationBenchmarker.prefetchArtifacts`, `benchmarks`, `AutotuneArtifactPrefetchReceipt.validatedArtifacts`, and every call into `verifiedExistingArtifact` | receipt paths are staging references until broker adoption; benchmark workers receive a broker-issued serving pin/FD or a separately typed staging-only probe that can never mint durable readiness |
| `ModelArtifactVerifier.canonicalArtifactHash`, both `inspectCanonicalArtifact` overloads, `ModelCatalogVerifiedArtifactObservation`, and their file enumeration/hash helpers | callable after B8 only inside broker/custody implementation or through `UntrustedPreparationInspection` proven component-confined to provider staging; direct CLI/app/autotune durable/custody use is a build failure |
| `DurableModelArtifactStore.artifactURL`, `validatedContainedDirectory`, `contains`, `adoptVerifiedStaging`, and all direct URL/root accessors | broker/custody implementation only after B8; public CLI/autotune consumers use typed opaque snapshot/adoption results |

The migration must preserve the user journeys: serve preflight, self-test,
recommendation prefetch, candidate benchmark, adoption, catalog list/action,
economics, and app readiness. They receive typed states
`ready|needs_preparation|unavailable|protected`, database identity, catalog
generation/binding, custody generation/event, artifact-lock identity, verified
byte/config evidence, and freshness generation from one broker snapshot. They
may display or pass the broker-returned canonical load handle/path only for the
authorized operation; path existence alone is never readiness.

The post-B8 static gate parses every production Swift file and generates
declarations plus call edges for the symbols above and the R24/R23 target set.
Swift compiler AST/SIL evidence, not regex alone, must prove no path from CLI,
app, autotune, self-test, or benchmark entrypoints reaches a durable/custody
open, stat, enumeration, containment, hash, config inspection, or adoption
outside the broker/custody boundary. Runtime fault injection mounts durable and
custody roots behind an open/stat/enumeration trap. Broker unavailable, stale,
wrong generation/database/lock identity, malformed reply, cancellation, and
timeout must produce the typed state with zero trapped calls. Valid provider
staging tests prove their root is disjoint and their results cannot populate a
catalog binding, readiness, pricing, admission, or settlement field.

## 7. Compatibility, rollout, observability, and non-goals

Schema v25 has no in-place migration from a selected R4 or hypothetical
unapproved R23/R24 database. Before B8 only the existing R4 compatibility path
may run. Selection creates a fresh v25 candidate, retains R4 until final B8
fsync/reopen succeeds, and rolls back to R4 on any preselection failure. After
B8, schema 23, missing `bootstrap_authority`, deleted intent, custody-operation
v2, provider-opened root lock FD, and direct CLI/autotune durable reads reject.
Rollback after selection stops v25 serving and restores R4 only through the
existing explicit rollback procedure; it does not reinterpret v25 receipts.

Metrics may expose schema version, truncated database/placement/lock prefixes,
bootstrap-authority match boolean, handoff phase/reason, fixed-slot headroom,
and typed readiness. They expose no nonce, intent bytes, absolute path,
device/inode, request/model bytes, audit token, signing key, or full digest.

R25 adds no pricing, admission, settlement, reward, enforcement, release,
deployment, production activation, hardware qualification, general root file
service, or d-inference authority. Plan approval is neither implementation nor
physical Mac acceptance. The existing actual-MLX lazy-read race remains a
mandatory later implementation qualification.

The bounded-storage delta is explicit: one SQL row with intent BLOB at most
65,536 bytes; one retained final intent file at most 65,536 bytes; and at most
32 live handoff records of 8,192 bytes each. Prefix publication can temporarily
double the retained-intent and handoff bytes, so the new external peak is at
most 655,360 bytes. R25 adds no unbounded table, directory, journal, receipt,
or history. The existing 448 MiB main-file, 64 MiB rollback-journal, 32 serving
slot, and 1,024 artifact-slot hard limits remain and must pass the revised
maximum-shape fixture including these bytes.

## 8. Implementation slices after approval

1. Check in schema-v25 derivation/golden fixtures and bootstrap crash tests.
2. Implement stable placement identity and L0/L1 custody-operation v3 without
   serving changes.
3. Implement the authenticated root-daemon open/handoff state machine and its
   32-slot recovery tests.
4. Cut all readiness, preflight, self-test, autotune, and benchmark durable
   reads over to broker snapshots and staging-only inspection types.
5. Run targeted Swift/SQLite/XPC tests, full SwiftPM and applicable Xcode tests,
   then independent code, security, and architecture audits over the complete
   diff. Any material architecture/contract/test-strategy change reopens the
   plan gate.
