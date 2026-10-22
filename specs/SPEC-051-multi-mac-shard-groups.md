# SPEC-051 - Multi-Mac Shard Groups

**Version:** 0.2.2

```json
{
  "spec_id": "SPEC-051",
  "title": "Multi-Mac Shard Groups",
  "version": "0.2.2",
  "path": "specs/SPEC-051-multi-mac-shard-groups.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["multi-mac-shard-groups"],
  "supersedes": [],
  "depends_on": ["SPEC-001", "SPEC-002", "SPEC-003", "SPEC-005", "SPEC-006", "SPEC-008", "SPEC-010", "SPEC-015", "SPEC-022", "SPEC-023", "SPEC-027", "SPEC-032", "SPEC-033", "SPEC-036", "SPEC-038", "SPEC-041", "SPEC-042", "SPEC-043", "SPEC-044", "SPEC-047", "SPEC-049"],
  "implementation_status": "partial",
  "production_status": "not-deployed",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "DECISION_REQUIRED",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/2084",
    "rationale": "SPEC-051 v0.2.0 defines single-owner multi-Mac shard groups serving Trusted Pool traffic: pipeline-parallel serving of one pool model across one owner's co-located Macs on one wired LAN, with the head's provider identity as the group identity, minimum-of-members trust, a creator-signed pool_shard_groups/v1 authorization, a framed stage transport, the group wire messages, one head-signed receipt with a group attestation of chained per-member sub-receipts, and explicit failure semantics. Every requirement stays pending until a paid Trusted Pool request is served by a shard group through the gateway and settled at the pool price."
  }
}
```

**Change log v0.2.2 (2026-10-22, Related: #2084):** A head never builds a
chain at an epoch the coordinator already accepted (SPEC-051-R023): it keeps
the last accepted epoch in an owner-only state file and builds every chain,
after a takeover, a lost member or a restart, at the configured epoch or one
above the last accepted, whichever is higher. A member joins a head at the
epoch the head's first frame names when it is not below the member's
configured epoch, and refuses a lower one.

**Change log v0.2.1 (2026-10-22, Related: #2084):** Defines the takeover
attestation (SPEC-051-R019): after a spare replaced a lost member and the head
replayed the delivered prefix into it, the attestation is one segment in the
new epoch from step 0 whose sub-receipts cover the whole recomputed prefix,
plus a `takeover` object naming the epoch it replaced and a closed reason
code. The lost member's sub-receipt is not required. The coordinator verifies
the takeover against its accepted epochs and stores the epoch change and
reason with the attestation.

**Change log v0.2.0 (2026-10-22, Related: #2084):** Trusted Pools are the
product for sharding. A v0.2 group serves only Trusted Pool traffic of a pool
whose creator-signed active core names the group in the new
`pool_shard_groups/v1` policy extension (SPEC-051-R028), and every member must
be a current member of that pool with the group's single owner. Global
(poolless), relay-blind and privacy-class traffic stay excluded. The group
provider identity is now the head Mac's own enrolled provider identity, which
also names stage 0, because one Mac holds one hardware binding (R002). Adds the
group wire messages and capability flags (R029), the pool disclosure of
multi-Mac serving (R030), the group attestation object carried on
`inference_response_end` (R019), the `error_shard_group_failed` pre-first-token
status (R021), the coordinator availability rules (R015), and the coordinator
`shard_groups` configuration keys. Resolves three of the four v0.1 open gaps
from existing specs: the wire messages are specified here as SPEC-001
extensions (repo convention, as SPEC-036 does for its scoring messages); a
Trusted Pool sharded tuple is a SPEC-042-R015 pool model entry, so global
catalog intake (R025, R026) does not gate pool serving; and pre-first-token
and mid-stream failures map onto the existing SPEC-005 §6 rows with no
group-specific billing (R021, R022).

**Change log v0.1.0 (2026-10-22, Related: #2084):** First draft. Single-owner
pipeline groups over Thunderbolt-bridge IP or Ethernet. Tensor parallelism and
RDMA over Thunderbolt 5 are reserved values, not served. Multi-owner groups
and intra-group earnings splits are reserved.

## 1. Purpose and scope

Some models do not fit in one Mac's memory (400B+ MoE models at
4-bit, 1T-class models). SPEC-051 lets one owner serve such a model across
several of their own Macs on one wired LAN. The model is split by layer range
(pipeline parallelism): each Mac holds a contiguous range of layers and its
own KV cache, and passes one boundary activation per token to the next Mac.
To the network the group is one provider serving one model at that model's
price on the route it serves (in v0.2, a Trusted Pool model at its
creator-signed price).

The outcome is memory capacity, not single-stream speed. Pipeline decode of
one request runs at about one Mac's speed; aggregate throughput needs several
requests in flight across stages (SPEC-051-R017). The go/no-go rule in
SPEC-051-R026 decides whether a sharded tuple is worth admitting.

Trusted Pools (SPEC-042, SPEC-043) are the product for sharding. A shard group
is one owner's co-located Macs; a Trusted Pool is run by one accountable
creator who names the groups allowed to serve it and discloses multi-Mac
serving to its buyers. v0.2 groups serve only that traffic.

In scope for v0.2:

- shard groups of one owner's Macs on one wired LAN, pipeline mode only,
  serving Trusted Pool traffic of pools that authorize them (SPEC-051-R028);
- the group record, member admission, and the trust and privacy rules;
- the stage transport between members (framing, integrity, deadlines,
  heartbeats);
- the group wire messages between head, members and coordinator
  (SPEC-051-R029);
- group health, routing to the group head, and dispatch;
- one buyer receipt per request with per-member sub-receipts;
- billing as one provider at the pool model's creator-signed price;
- failure semantics before and after the first streamed token;
- qualification of a sharded tuple before global catalog intake.

Out of scope for v0.2, reserved:

- tensor parallelism (`parallelism_mode = tensor`) and RDMA over Thunderbolt 5
  (`interconnect_class = rdma-tb5`). Both are enum values from the first
  draft so a later revision adds them as an engine mode, not a protocol
  redesign. A v0.2 coordinator refuses both (SPEC-051-R005);
- groups whose members belong to different owners, and any split of group
  earnings between members (SPEC-051-R020);
- groups across sites or over the public internet, and Wi-Fi links
  (SPEC-051-R007);
- global (poolless) traffic served by a group: a sharded catalog tuple needs
  a SPEC-023/SPEC-010 row shape that does not exist yet (§7);
- relay-blind or privacy-class requests (SPEC-041, SPEC-049) by a group
  (SPEC-051-R009).

Single-Mac serving is unchanged (SPEC-051-R024).

## 2. Dependencies and authority

SPEC-051 owns the authority domain `multi-mac-shard-groups`: the shard group
concept, the group record and epoch, member and spare roles, layer placement
validity, interconnect admissibility, the stage transport frame and its
supervision, the group attestation and member sub-receipts, group failure
semantics, and sharded-tuple qualification and its decision rule.

Consumed contracts, owned elsewhere. SPEC-051 cites them and does not restate
or change them:

- **SPEC-001** owns the provider wire protocol. The group messages, the two
  capability flags, the `group_attestation` member and the
  `error_shard_group_failed` status are SPEC-001 extensions specified here
  (SPEC-051-R029), the convention SPEC-036 uses for its scoring messages.
- **SPEC-002** owns admission and routing: release admission
  (SPEC-002-R004), the measured-performance store (SPEC-002-R005),
  phase-aware selection (SPEC-002-R006), and buyer ownership exclusion
  (SPEC-002-R008). SPEC-002-R002 owns trusted-routing state.
- **SPEC-003** owns provider onboarding identity; **SPEC-027** owns provider
  proof of ownership. Owner equality in SPEC-051-R001 uses those records.
- **SPEC-005** owns the billing formula, failed-request accounting
  (SPEC-005-R004, §6) and multi-attempt attribution (SPEC-005-R006).
  SPEC-005-R011 owns the signed rate card.
- **SPEC-006** owns the buyer API and error envelope (SPEC-006-R002).
- **SPEC-008** owns Tier-2 trust evidence; **SPEC-032** owns the
  proof-of-weights hello gate (SPEC-032-R001..R003); **SPEC-033** owns the
  hardware-evidence verifier and attested-hardware trust (SPEC-033-R002).
- **SPEC-010** owns catalog model identity (SPEC-010-R001, SPEC-010-R004,
  SPEC-010-R007); **SPEC-023** owns the signed catalog document schema and
  model-fit policy; **SPEC-044** owns catalog economics display
  (SPEC-044-R014); **SPEC-047** owns the network admission state machine
  (SPEC-047-R001) and its settlement boundary (SPEC-047-R003).
- **SPEC-015** owns the receipt tuple, its canonical encoding and signature
  (§3), and receipt-key lifecycle (SPEC-015-R003). The v0.4 tuple is locked;
  SPEC-051 does not add a field to it.
- **SPEC-022** owns verified-model settlement (SPEC-022-R002, SPEC-022-R003,
  SPEC-022-R004). **SPEC-036** owns compute-integrity scoring and its
  tolerance (SPEC-036-R022).
- **SPEC-038** owns continuous batching inside one engine.
- **SPEC-041** and **SPEC-049** own relay-blind and privacy-class requests,
  including in-process plaintext (SPEC-049-R009, SPEC-049-R011).
- **SPEC-042** owns Trusted Pools: the pool manifest and its v2 extension
  mechanism (SPEC-042-R001), membership (SPEC-042-R003), route isolation
  (SPEC-042-R005), pool-scoped settlement labels (SPEC-042-R006), and pool
  model entries (SPEC-042-R015). SPEC-051 defines the body of one extension,
  `pool_shard_groups/v1` (SPEC-051-R028), under that mechanism.
- **SPEC-043** owns creator onboarding, the single-operator membership model
  (SPEC-043-R006) and the promise surfaces (SPEC-043-R009). SPEC-051-R030 adds
  the multi-Mac disclosure those surfaces carry.

SPEC-051 mints no trust tier, attestation label, or privacy label, and
upgrades or downgrades none. It only defines how a group inherits existing
labels from its members (SPEC-051-R004).

## 3. Terms

| Term | Meaning |
|---|---|
| Shard group | A set of one owner's Macs on one wired LAN that together serve one catalog model by layer range. |
| Member | A Mac in the group that holds one stage's layers. |
| Stage | One contiguous layer range `[layer_start, layer_end)` held by exactly one active member. |
| Head | The member at stage 0. It holds the embedding and the first layers, holds the group's coordinator session, receives dispatch, streams tokens to the buyer path, and signs receipts. |
| Last stage | The member holding the final layers and the LM head. It samples the next token and returns the token ID to the head. |
| Spare | An admitted member with a stage's layers loaded and no active role. It can replace that stage's member (SPEC-051-R022). |
| Group provider identity | The one provider identity the network sees for the group: the head Mac's own enrolled provider identity (SPEC-003). It also names stage 0 in the group record. |
| Member device identity | A non-head member's own enrolled provider identity (SPEC-003). It is never buyer-visible and never separately routable while its session advertises `shard_member_v1`. |
| Head session | The head's coordinator session under the group provider identity, advertising `shard_group_head_v1`. |
| Member session | A non-head member's own coordinator session, advertising `shard_member_v1`. |
| Group epoch | A strictly increasing unsigned 64-bit integer naming one exact membership and layer placement. |
| Boundary activation | The hidden-state tensor one stage sends to the next for one request and one step. |
| Hop | One transfer of a boundary activation between adjacent stages, or of a token ID from the last stage to the head. |
| Micro-batch | A set of request rows that move through the stages together in one step. |
| Sharded tuple | A model tuple served in `pipeline` mode over one interconnect class with a given stage count. In v0.2 it is a SPEC-042-R015 pool model entry. |

## 4. Configuration

Coordinator `coordinator.yaml`, section `shard_groups`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `max_members` | int 2..8 | `4` | Upper bound on active members plus spares in one group. |
| `max_link_rtt_p99_us` | int 200..5000 | `2000` | Upper bound on each link's measured p99 heartbeat round trip (SPEC-051-R007). |
| `required_frame_protection.thunderbolt-ip` | enum | `crc32c` | Minimum frame protection on a point-to-point Thunderbolt-bridge link (SPEC-051-R011). |
| `required_frame_protection.ethernet` | enum | `hmac-sha256` | Minimum frame protection on an Ethernet link (SPEC-051-R011). |
| `group_heartbeat_stale_multiple` | int 2..10 | `3` | A group heartbeat older than this many coordinator `heartbeat_interval_s` periods makes the group unavailable (SPEC-051-R015). |
| `supported_transport_versions` | list of int | `[1]` | Stage-transport versions the coordinator accepts in a group record (SPEC-051-R027). |

Group configuration on the head (owner-local, carried in the group record):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `heartbeat_interval_ms` | int 20..1000 | `100` | Heartbeat period on the control channel (SPEC-051-R014). |
| `heartbeat_miss_limit` | int 2..10 | `3` | Consecutive missed heartbeats after which a member is dead. |
| `decode_hop_deadline_ms` | int 50..2000 | `500` | Receive deadline for one decode hop (SPEC-051-R013). |
| `prefill_chunk_deadline_ms` | int 500..4000 | `3000` | Receive deadline for one prefill chunk hop. |
| `replay_deadline_ms` | int 1000..30000 | `10000` | Time allowed to bring a spare up to the delivered prefix (SPEC-051-R022). |

Values outside these bounds MUST fail configuration load or group
registration. These values are tuning, not gates: none of them disables or
withdraws a group on a schedule.

## 5. Normative requirements

### SPEC-051-R001 - Shard group scope: one owner, one LAN

A shard group MUST consist of two or more Macs, at most `max_members`
including spares, that are all owned by the same owner as recorded under
SPEC-003 onboarding identity and SPEC-027 proof of ownership, and that are
reachable from each other only over a wired link on one local network
(SPEC-051-R007). The group provider identity MUST be owned by that same
owner. The coordinator MUST refuse registration of a group in which any
member's owner differs from the group provider identity's owner, and MUST
move a registered group to unavailable (SPEC-051-R015) when any member's
ownership record changes. No member may be a Mac outside the owner's control,
a hosted or rented machine of another party, or a Mac reachable only across
the public internet. A group serves exactly one model at a time. The coordinator reads owner
equality from the SPEC-003 ownership claim of each identity; an identity with
no claim has no owner and cannot be in a group.

### SPEC-051-R002 - One group provider identity, member device identities

Each group MUST have exactly one group provider identity: the head Mac's own
enrolled provider identity under SPEC-003. It names stage 0 in the group record
(SPEC-051-R005), holds the head session, and signs the group record, receipts
and group attestations with its SPEC-015 receipt key. Every other member MUST
hold its own enrolled member device identity, distinct from the group provider
identity, and authenticate it on its own member session for admission
(SPEC-051-R003) and health (SPEC-051-R015). Buyer-visible surfaces, receipts
(SPEC-051-R018) and the measured-performance store (SPEC-002-R005) MUST name
only the group provider identity. Member device identities appear only in the
group record, the group attestation (SPEC-051-R019), and operator surfaces. A
member device identity MUST belong to at most one group at a time; the
coordinator MUST refuse a group record or member hello that would place it in
a second group.

One Mac carries one hardware binding (SPEC-033), which is why the head does not
hold a second identity for itself. While its session advertises
`shard_group_head_v1`, the group provider identity serves only group traffic
(SPEC-051-R016).

### SPEC-051-R003 - Every member passes the full single-provider admission bar

Every member and every spare MUST independently pass the full admission bar a
single provider must pass to serve paid traffic, with no group exemption:
release admission (SPEC-002-R004), hardware evidence (SPEC-033), the
proof-of-weights hello gate for the files it loads (SPEC-032-R001..R003,
scoped by SPEC-051-R008), Tier-2 evidence where the served tuple requires it
(SPEC-008), and any sanction or revocation that would block it as a single
provider. A member that fails or loses any of these MUST make the group
unavailable (SPEC-051-R015). All active members and spares MUST run the same
stage-transport version and the same engine identity for the sharded tuple; a
mismatch MUST fail group registration. Each non-head member meets this bar
through its own member session: its hello names the group's model id and the
full artifact pair it verified its files against, exactly as the head's does,
and passes every hello gate a single provider would.

### SPEC-051-R004 - Group trust is the minimum of its members

For every trust tier, attestation-strength label, hardware-evidence verdict,
and routing-trust state defined by another spec (including SPEC-002-R002,
SPEC-008, SPEC-032, and SPEC-033-R002), the group's value MUST be the minimum
of its active members' and spares' values under that label's own ordering in
its owning spec. Where a label has no total order, the group holds the label
only if every member holds it with an equal value. A member lacking a label
means the group lacks it. A group MUST NOT hold any label, tier, or attestation
strength that is not held by every member, MUST NOT mint a new one, and MUST
NOT upgrade any member's. The coordinator MUST recompute the group's values
whenever any member's value changes and apply the result before the next
reservation.

### SPEC-051-R005 - Group record

The head MUST register each group epoch with the coordinator as one group
record signed by the group provider identity's SPEC-015 receipt key, sent in
`shard_group_register` on the head session (SPEC-051-R029). The coordinator MUST store each
accepted record append-only and refuse any record whose `group_epoch` is not
strictly greater than the last accepted epoch for that group. A re-send of the
latest accepted record with identical JCS bytes (a reconnecting head) is
acknowledged without a new row; any other record at that epoch is refused. The record MUST
carry exactly these fields:

| Field | Meaning |
|---|---|
| `schema` | Exactly `macprovider.shard-group-record.v1`. |
| `group_provider_id` | The group provider identity. |
| `group_epoch` | Integer in `[1, 2^53 - 1]`, strictly increasing per group. |
| `parallelism_mode` | Closed enum `pipeline` \| `tensor`. v0.2 accepts only `pipeline`; `tensor` is reserved and MUST be refused. |
| `interconnect_class` | Closed enum `thunderbolt-ip` \| `ethernet` \| `rdma-tb5`. v0.2 accepts `thunderbolt-ip` and `ethernet`; `rdma-tb5` is reserved and MUST be refused. There is no Wi-Fi value. |
| `frame_protection` | Closed enum `crc32c` \| `hmac-sha256` \| `aead-chacha20poly1305` (SPEC-051-R011). |
| `transport_version` | The stage-transport version every member runs; one of `supported_transport_versions`. |
| `model` | Object `{model_id, pool_model_id, artifact_hash_algorithm, artifact_hash}`: the head's hello model id, the SPEC-042-R015 `pool_model_id` the group serves, and that entry's exact artifact pair (`macprovider.snapshot-manifest.v1` and 64 lowercase hex). The pair MUST equal the head session's reported model hash pair. |
| `num_layers` | The model's transformer layer count, `[2, 4096]`. |
| `max_concurrency` | The group's request concurrency limit, `[1, 256]`, at most the head session's hello `max_concurrency` (SPEC-051-R017). |
| `stages` | Ordered list of `{stage_index, member_device_id, layer_start, layer_end}`. Stage 0's `member_device_id` is the group provider identity. |
| `spares` | List of `{member_device_id, stage_index}` with `stage_index >= 1`; may be empty. The head has no spare. |
| `supervision` | Object with exactly the five SPEC-051 §4 group configuration keys. |

Unknown fields, missing fields, and enum values outside these sets MUST be
refused. Active members plus spares MUST number at most `max_members`.

### SPEC-051-R006 - Layer placement validity

The coordinator MUST refuse a group record unless: the stages are numbered
`0..S-1` with `S >= 2`; stage ranges are non-empty, contiguous, in order, and
cover `[0, num_layers)` exactly once; stage 0 holds the embedding and the last
stage holds the final norm and LM head; each active member appears in exactly
one stage; and each spare names an existing stage. Layer counts MAY be uneven.
Each member MUST report, before registration, that its stage's weights, its
KV budget for the group's advertised concurrency, and its runtime reserve fit
within its memory under SPEC-023 model-fit policy applied to that stage; a
member that cannot fit its stage MUST NOT register.

### SPEC-051-R007 - Interconnect admissibility

Every link between adjacent stages, between the last stage and the head, and
between the head and each spare MUST be a wired link of the group's
`interconnect_class`: IP over a Thunderbolt bridge for `thunderbolt-ip`, or
wired Ethernet for `ethernet`. Each member MUST report the operating-system
interface type carrying each of its stage links, and the coordinator MUST
refuse registration when any link is carried by a Wi-Fi interface, a VPN or
tunnel interface, or a route that leaves the local network. The head MUST
measure each link's heartbeat round trip and report its p99; the coordinator
MUST refuse registration, and make a registered group unavailable, while any
link's p99 exceeds `max_link_rtt_p99_us`.

### SPEC-051-R008 - Member weight identity

Each member MUST verify every weight file it loads against the signed
artifact identity named in the group record (SPEC-010-R001, SPEC-010-R007),
and MUST load only files that belong to that artifact. The proof-of-weights
hello gate (SPEC-032-R001) for a member MUST cover exactly the files holding
its stage's layers. The group MAY report the tuple's `model_hash` for
admission, route snapshots and settlement (SPEC-010-R004, SPEC-022-R002) only
when every active member and spare verified its files against the same signed
catalog row; otherwise the group MUST be treated as having no verified model
identity.

### SPEC-051-R009 - Privacy: every member sees the prompt

Boundary activations can be inverted to recover prompt tokens, so every
member MUST be treated as seeing the full prompt and output. Consequently:

1. the group's privacy posture is the most restrictive constraint of any
   member under SPEC-051-R004, and a group never advertises a privacy property
   that any member lacks;
2. a group MUST NOT be eligible for relay-blind requests (SPEC-041) or
   privacy-class requests (SPEC-049), because their plaintext boundary is one
   provider process (SPEC-049-R009, SPEC-049-R011) and a group moves
   prompt-equivalent data between processes and Macs; the coordinator MUST
   exclude groups from those routes before reservation;
3. a group MUST serve only Trusted Pool traffic of a pool whose active core
   authorizes it and discloses multi-Mac serving (SPEC-051-R028,
   SPEC-051-R030), and MUST NOT serve global (poolless) traffic;
4. no member may be outside the owner's control (SPEC-051-R001);
5. members MUST NOT write boundary activation payloads, prompt text or output
   text to disk, logs, crash reports or telemetry, and MUST release a
   request's activations and KV when the request ends.

Transport encryption (SPEC-051-R011) protects against the network, not
against members, and MUST NOT be described as a privacy property of the
group.

### SPEC-051-R010 - Stage transport framing

Members MUST exchange boundary activations, token IDs and control messages
only through the SPEC-051 stage transport over TCP on the links of
SPEC-051-R007, with a data channel and a separate control channel per link.
Every frame MUST start with a fixed header carrying: magic, transport version,
frame type (`activation`, `token`, `control`, `heartbeat`, `abort`), the group
epoch, the per-link sequence number, the request ID, the micro-batch ID, the
token step, source and destination stage, the layer range that produced the
payload, payload dtype and shape, payload length, and the frame's deadline.
The frame MUST end with a CRC32C over header and payload, followed by the
authentication tag when `frame_protection` requires one. A receiver MUST
discard a frame and treat the link as failed when the magic, version or
epoch does not match its current epoch, the length disagrees with dtype and
shape, or the check value or tag fails. The serving path MUST NOT use
`mlx.launch`, an `mx.distributed` group, or distributed `mlx_lm.server` as
the transport or lifecycle owner.

### SPEC-051-R011 - Frame integrity and authentication

Every frame MUST carry CRC32C. A link MUST use at least the frame protection
that `required_frame_protection` sets for its interconnect class, and the
group record's `frame_protection` MUST meet that minimum. For `hmac-sha256`
and `aead-chacha20poly1305`, keys MUST be fresh per group epoch and per link,
derived from a mutually authenticated handshake between the two members'
device identity keys; keys MUST NOT be sent to or derivable by the
coordinator and MUST NOT be reused across epochs. A frame whose tag fails
MUST be discarded and the link treated as failed.

### SPEC-051-R012 - Sequencing and no silent retransmit

Each link direction MUST number frames with a strictly increasing sequence
number starting at zero for each epoch. A receiver MUST treat a gap, a
duplicate or a reordering as a link failure, not skip or reorder silently.
The stage transport MUST NOT retransmit a frame at the application layer.
Only the head emits tokens toward the buyer, and it MUST emit each
`(request ID, token step)` at most once; no member may resend a token step to
the head after it was received, and the head MUST NOT re-emit a delivered
token step under any recovery path.

### SPEC-051-R013 - Per-hop deadlines and prefill chunks

Every blocking receive on the data channel MUST have a deadline:
`decode_hop_deadline_ms` for a decode hop and `prefill_chunk_deadline_ms`
for a prefill chunk hop. A missed deadline MUST be treated as a member
failure handled by SPEC-051-R021 or SPEC-051-R022. Prefill MUST be chunked so
that one stage's compute for one chunk stays below the prefill chunk deadline
and well below the operating system's GPU command-buffer watchdog.

### SPEC-051-R014 - Heartbeats and peer death

Each member MUST send a heartbeat on the control channel to its neighbours
and to the head every `heartbeat_interval_ms`, independent of data traffic. A
member that misses `heartbeat_miss_limit` consecutive heartbeats MUST be
declared dead by every member that observes it. On a peer death, a link
failure, or an `abort` frame, every remaining member MUST stop the affected
epoch's in-flight work and release its buffers within two heartbeat
intervals. No member may block, spin, or wait indefinitely on a dead peer, and
peer loss MUST NOT terminate a surviving member's process.

### SPEC-051-R015 - Group health and availability

A group MUST be available only while every active member is healthy: its
member device identity is admitted (SPEC-051-R003), its heartbeats are
current, its links meet SPEC-051-R007, its weights are verified
(SPEC-051-R008), and the group record's epoch is the latest accepted one.
The head MUST report per-member health in its group heartbeat to the
coordinator, and each member MUST also report its own health under its member
device identity. When any active member is unhealthy, the coordinator MUST
mark the group unavailable before the next reservation. A spare's health
affects only whether replay is possible (SPEC-051-R022), not availability.

The coordinator evaluates availability whenever a group record, member hello,
group heartbeat, member or head session change arrives, and at least once per
second. The group is available only when all of these hold, and otherwise
names the first failing condition as its reason code:

1. the head session is connected, advertises `shard_group_head_v1` and not
   `shard_member_v1`, is WebSocket-tunnelled, and its reported model pair
   still equals the record's (`head_session_invalid`);
2. the latest accepted record exists for the group (`group_not_registered`);
3. every active non-head member has an accepted `shard_member_hello` for
   that epoch (`member_not_joined`) on a member session that is still the one
   it joined from (`member_session_missing`);
4. every active member session, and the head session, passes every
   routing-state gate of a single provider except free slots and the
   member-session exclusion itself: authenticated bearer, no quarantine,
   no compute-integrity suspension, no admission sandbox, evidence or ceiling
   exclusion, no pending catalog re-check, handshake or receipt-key
   publication, a published receipt key, and state `ready` or `busy`
   (`member_not_admissible`);
5. for SPEC-051-R004, no active member holds a lower provider tier,
   attestation tier, encrypted-leg capability or attestation status than the
   head; the group then holds exactly the head's labels, which are the
   minimum (`trust_label_above_member`);
6. every active member and the group provider identity have the same
   SPEC-003 owner (`owner_mismatch`);
7. a group heartbeat for the epoch arrived within
   `group_heartbeat_stale_multiple` coordinator heartbeat intervals
   (`group_heartbeat_stale`), reports every active member healthy
   (`member_unhealthy`), and reports every required link on the
   `interconnect_class` interface type (`link_interface_invalid`) with
   `rtt_p99_us <= max_link_rtt_p99_us` (`link_rtt_exceeded`).

The coordinator MUST send `shard_group_status` (SPEC-051-R029) to the head on
every change of availability or reason.

### SPEC-051-R016 - Routing to the head only

The coordinator MUST reserve and dispatch group requests only to the head
session, and MUST NOT dispatch any buyer request to a member session, for the
group's model or any other. A head session is routable only while its group
is available (SPEC-051-R015), only on a pool route that SPEC-051-R028
authorizes, and only for the pool model the group record names. It MUST NOT be
selected for global, relay-blind or privacy-class requests, nor dispatched over
HTTP-direct forwarding. Phase-aware ranking (SPEC-002-R006) MUST use the group's own
measured performance (SPEC-002-R005), not any member's. Buyer ownership
exclusion (SPEC-002-R008) applies to the group's owner.

### SPEC-051-R017 - Cross-stage micro-batching

The head MUST schedule so that, whenever at least `S` requests are active,
at least `S` micro-batches are in flight across the `S` stages, and each stage
MUST batch its rows under SPEC-038 within its own engine. Sampling MUST run on
the last stage, and only token IDs travel back to the head. Prefill MUST be
pipelined in chunks across stages. Each stage MUST hold only its own layers'
KV. The group MUST advertise to the coordinator a concurrency limit no larger
than its record's `max_concurrency`, and for a global sharded tuple no larger
than the concurrency it was qualified at (SPEC-051-R025).

### SPEC-051-R018 - One buyer receipt per request, signed by the head

For each served request the group MUST produce exactly one SPEC-015 receipt,
signed by the head with the group provider identity's receipt key
(SPEC-015-R003). The receipt tuple, canonical encoding, signature and wire
form MUST be exactly those of SPEC-015 §3, with `provider_pubkey` the group's
receipt key, `ttft_ms` measured at the head, and `tokens_out` the tokens the
head delivered. No member other than the head signs buyer receipts, and no
per-member receipt is sent to the buyer path in its place.

### SPEC-051-R019 - Group attestation with chained member sub-receipts

For each served request the head MUST produce one group attestation object,
signed by the group provider identity and bound to the SPEC-015 receipt by
the SHA-256 of that receipt's canonical tuple bytes, and send it to the
coordinator with the receipt. It MUST embed one sub-receipt per member that
took part, each signed by that member's SPEC-015 receipt key, carrying:
`member_device_id`, `group_epoch`, `stage_index`, `layer_start`, `layer_end`,
the request ID, prompt tokens processed, decode steps processed, and
`in_digest` and `out_digest`. `in_digest` is the SHA-256 chain over the exact
payload bytes of every frame for that request the member received on its
upstream link, in sequence order; `out_digest` is the same over every frame it
sent downstream. The coordinator MUST verify every signature and that, for
each pair of adjacent stages, `out_digest` of stage `i` equals `in_digest` of
stage `i+1`, and that the last stage's token `out_digest` equals the head's
token `in_digest`. A failed check MUST attribute the fault to the member at
the first broken link (the downstream member, whose `in_digest` disagrees; the
head for the token return link), MUST be recorded against that member device identity,
and MUST make the request's settlement evidence fail SPEC-022 verification
for that attempt. When a spare replaced a member mid-request
(SPEC-051-R022), the head replays the request's delivered prefix into the
spare, so every member of the new epoch processes the request from its first
prompt token: the attestation is then a takeover attestation (item 6), whose
one segment in the new epoch covers the whole recomputed prefix. The lost
member's sub-receipt is not required, because a lost member cannot sign.

Wire form and verification:

1. The attestation travels as the `group_attestation` member of the
   `inference_response_end` frame that carries the receipt (SPEC-051-R029).
   A head-session end frame with a non-empty `receipt` and no valid
   attestation fails this requirement.
2. The object has exactly the keys `schema`
   (`macprovider.shard-group-attestation.v1`), `group_provider_id`,
   `request_id`, `attempt_n`, `receipt_tuple_sha256`, `segments`, and
   `signature`, plus `takeover` on a takeover attestation (item 6), and no
   other key. `request_id`, `attempt_n` and `group_provider_id` MUST equal
   the receipt tuple's `request_id`, `attempt_n` and `provider_id`.
   `signature` is the head session receipt key's Ed25519 signature over the
   UTF-8 bytes `macprovider.shard-group-attestation.v1` and a line feed,
   followed by the RFC 8785 (JCS) bytes of the object without `signature`.
3. `segments` is a non-empty list of `{group_epoch, step_start, step_end,
   sub_receipts}`. Epochs strictly increase, the first segment starts at step
   0, each segment starts where the previous ended, and every segment but a
   single one is non-empty. Each epoch MUST be an accepted record of this
   group.
4. `sub_receipts` lists one signed sub-receipt per active stage of that
   epoch, in stage order, each `{sub_receipt, public_key, signature}`.
   `sub_receipt` has exactly the keys `member_device_id`, `group_epoch`,
   `stage_index`, `layer_start`, `layer_end`, `request_id` (the coordinator
   request id string), `prompt_tokens`, `decode_steps`, `in_digest` and
   `out_digest` (64 lowercase hex each). `public_key` is base64 of the raw
   32-byte Ed25519 key; `signature` is that key's signature over the UTF-8
   bytes `macprovider.shard-sub-receipt.v1` and a line feed, followed by the
   JCS bytes of `sub_receipt`. Member, epoch, stage and layers MUST match that
   epoch's record; `request_id` MUST equal the attestation's. For stage 0,
   `public_key` MUST be the head session's receipt key; for any other stage,
   the receipt key its member session carried when its member hello for that
   epoch was accepted.
5. On any failure the coordinator MUST store the verdict with the fault kind
   and the first faulty member device identity, and MUST drop the receipt
   from the attempt before settlement, so the attempt settles exactly as a
   SPEC-022 attempt without a receipt. On success it MUST store the
   attestation with the receipt tuple digest, keyed by request, attempt and
   group provider identity.
6. A takeover attestation carries `takeover`: an object with exactly the keys
   `from_group_epoch` (the epoch the spare replaced, an accepted record of
   this group) and `reason`, one of `peer_closed`, `peer_dead`,
   `deadline_missed`, `peer_error` and `link_error` (how the head lost the
   member). It MUST have exactly one segment, in an epoch greater than
   `from_group_epoch`, starting at step 0 and ending at the request's last
   token step; the chain checks of item 4 apply to it unchanged. A null or
   malformed `takeover` fails with fault kind `attestation_malformed`; one
   that names an unknown epoch or reason, comes with more than one segment or
   names a segment epoch not above `from_group_epoch` fails with fault kind
   `takeover_invalid`; both against the group provider identity. On
   success the coordinator stores `from_group_epoch` and `reason` with the
   attestation, so every takeover is recorded with the attempt it served.

### SPEC-051-R020 - Billing and settlement as one provider

A group request MUST be priced and settled exactly as a single-provider
request for the same tuple on the same route: on a Trusted Pool route, the
SPEC-005 formula at the pool model entry's creator-signed rates (SPEC-005-R015,
SPEC-042-R015), the pool-scoped settlement label and route fence
(SPEC-042-R006), SPEC-022 verified-model settlement for the group provider
identity, and the SPEC-047-R011 pool-scoped binding of the head session; for a
global sharded tuple, once one exists, the signed catalog price
(SPEC-005-R011) and SPEC-047 admission state (SPEC-047-R001, SPEC-047-R003). There MUST be one ledger row set per
attempt, credited to the group provider identity; members earn nothing
separately. Because a group has one owner, the owner receives the group's
provider credit. Any split of earnings between members is reserved and MUST
NOT be computed or paid; a group record or ledger field that
claims a split MUST be refused.

### SPEC-051-R021 - Failure before the first token

When a group attempt fails before the head has streamed the first output
token to the buyer path (member death, link failure, missed deadline, chain
break, or unavailability), the head MUST abort the attempt across all members
and report a retryable provider failure that carries no completion: an
`inference_response_end` with `status` `error_shard_group_failed`,
`chunks_sent` 0, `retryable` true and no `receipt`. The coordinator MUST treat
it exactly as a provider disconnect before the first chunk: retry the request
on another eligible provider or group under the SPEC-005 §8 multi-attempt
attribution (SPEC-005-R006), with the failed attempt written as a SPEC-005
§6.11 breaker-qualifying row whose gross, provider and operator credits are
zero. The failed group attempt therefore produces no buyer debit and no
provider credit. The buyer sees an error only if every attempt fails, in the
SPEC-006-R002 envelope. A coordinator that receives `error_shard_group_failed`
from any session other than a head session, or after the first chunk, treats
it as an ordinary provider error.

### SPEC-051-R022 - Failure after the first token

When an active member fails after the first token was streamed:

1. if a healthy spare holds that stage's layers, the head MUST start a new
   group epoch with the spare in that stage, rebuild the spare's KV for the
   request's delivered prefix (prompt plus every token already delivered)
   from retained boundary activations or recomputation, and resume at the
   next undelivered token step, within `replay_deadline_ms`;
2. otherwise, or if replay does not finish within `replay_deadline_ms`, the
   head MUST terminate the stream with an `inference_response_end` whose
   `status` is `error_shard_group_failed`, which the buyer path renders as an
   explicit error in the SPEC-006-R002 envelope, and the attempt MUST be
   billed exactly as a single provider's mid-stream provider failure under
   SPEC-005 §6: the §6.4 partial-stream row (prompt plus delivered tokens,
   never more) with the §6.11 FR-P11a override applied as SPEC-005 applies it
   to every provider. SPEC-051 adds no group-specific billing row.

The group MUST NOT regenerate, rewrite, or re-emit any token the buyer path
already received (SPEC-051-R012), and MUST NOT silently retry the request from
the start once a token was delivered. A resumed stream continues from the
delivered prefix; tokens after the replay point MAY differ from those an
uninterrupted run would have sampled.

### SPEC-051-R023 - Epoch changes

Any change of membership, layer placement, interconnect class, frame
protection, model, or supervision values MUST use a new group epoch and a new
group record. A member MUST refuse frames of any epoch other than its current
one. Requests in flight under an old epoch MUST either complete under that
epoch or follow SPEC-051-R022; they MUST NOT continue on a mix of epochs
except through a recorded replay.

Because the coordinator refuses any epoch at or below the last one it
accepted (SPEC-051-R005), a head MUST NOT build a chain at such an epoch. The
head MUST persist the last epoch the coordinator accepted for its group
(written atomically and durably, readable only by the owner) and build every
chain, including after a takeover, a lost member or a restart, at the higher
of its configured epoch and the last accepted epoch plus one. When the
coordinator answers `epoch_not_increasing`, the head records that epoch as
seen and rebuilds above it. A member's current epoch is the one the head's
first frame on a new link names (for an authenticated link, the epoch its key
agreement signs): a member MUST accept it when it is not below the member's
configured epoch (for a spare, the epoch after its group's), MUST refuse a
lower one, and sends nothing on the link before that first frame. Its member
hello and sub-receipts name that epoch.

### SPEC-051-R024 - Isolation from single-Mac serving

A provider that is not a member of an active group MUST serve exactly as it
would without SPEC-051: its wire messages, admission, routing, receipts,
billing, continuous batching, decode paths and performance MUST NOT change.
The sharded serving path MUST run only on Macs whose owner configured a group,
and only for tuples qualified under SPEC-051-R025. A coordinator or CLI
without SPEC-051 support MUST continue to serve single-Mac traffic unchanged.
A pool whose active core carries no `pool_shard_groups/v1` extension routes
exactly as without SPEC-051.

### SPEC-051-R025 - Qualification before catalog intake

A global sharded tuple MUST NOT enter `catalog_priced` or
`settlement_capable` (SPEC-047-R001) until a qualification record for that
tuple exists. A Trusted Pool sharded tuple is a SPEC-042-R015 pool model entry
under the creator's attestation (`pool_attested_unverified`); it needs no
qualification record to serve its own pool, and its creator SHOULD use the
same measurements before naming a group in `pool_shard_groups/v1`. The record
MUST be measured end to end on a real group of that interconnect class and
stage count, through the SPEC-051 transport and engine, and MUST report:

1. parity: for a model that also fits on one Mac, greedy output token IDs
   identical to single-Mac output over the qualification prompt set; for a
   model that does not, agreement with a reference implementation within the
   SPEC-036-R022 tolerance;
2. single-stream decode output tokens per second and TTFT at concurrency 1;
3. hop overhead: per-hop transport p50 and p99 latency in the running engine,
   and the share of per-token decode time spent outside stage compute;
4. aggregate output tokens per second at concurrency 1, `S` and `2S`.

### SPEC-051-R026 - Go/no-go decision rule

A sharded tuple qualifies only when all of these hold in its qualification
record:

1. hop overhead is at most 5% of per-token decode time at concurrency 1, and
   per-decode-hop p99 is at most 1 ms; a per-decode-hop p99 above 5 ms is
   no-go for that interconnect class regardless of the other numbers;
2. single-stream decode meets the buyer-grade floor for the tuple, which is
   the catalog's published floor for that model when one exists and
   otherwise 10 output tokens per second;
3. the group's aggregate earnings rate at its qualified concurrency (aggregate
   output tokens per second times the catalog price) is at least the sum of
   the members' standalone earnings rates, each being the best catalog tuple
   that member can serve alone at its measured throughput (SPEC-002-R005)
   times its catalog price.

A tuple that fails any condition MUST NOT enter global catalog intake as a
sharded tuple. The decision cites these measured numbers, not a side metric.

### SPEC-051-R027 - Version skew

The coordinator MUST accept group registration only from a head and members
whose sessions advertise the SPEC-051 capability flags (SPEC-051-R029), and
MUST refuse a group record it cannot fully validate. A coordinator without SPEC-051 support does not know
the group messages, so the head MUST NOT serve group traffic when its group
registration is not acknowledged; its members' single-Mac sessions are then
unaffected. A member whose transport version differs from the group record's
MUST refuse to join that epoch.

### SPEC-051-R028 - Trusted Pool authorization (`pool_shard_groups/v1`)

A shard group MUST serve a pool's traffic only while that pool's active
SPEC-042 v2 policy core carries the `pool_shard_groups/v1` extension naming the
group provider identity. The extension is trust-bearing signed core data under
the SPEC-042-R001 extension mechanism; its body is a 32-bit count from 1 to 64
followed by that many entries in strictly ascending byte order of
`group_provider_id`, each encoding exactly, in this order under the
SPEC-041-R002 framing:

1. `group_provider_id`: length-prefixed ASCII matching `^[a-zA-Z0-9_.-]{1,64}$`;
2. `pool_model_id`: length-prefixed, equal to the `pool_model_id` of an entry
   in the same core's `pool_model_entries/v1` whose `allowed_runtime_sources`
   contains `mlx_cache`;
3. `max_members`: unsigned 64-bit integer in `[2, 8]`.

Duplicate or out-of-order ids, a count outside `[1, 64]`, a `pool_model_id`
with no such entry, a bound outside `[2, 8]`, a non-canonical body, or a core
whose settlement mode is not `enforce` invalidate the whole core at
acceptance. A core without the extension keeps its exact bytes and authorizes
no group.

At every route attempt on a pool route, the coordinator MUST additionally
require of a head session that: its group provider identity is named in the
active core's extension; the head's pool-scoped binding (SPEC-047-R011) is to
that pool and to the entry's `pool_model_id`; the group's active members plus
spares number at most the entry's `max_members`; and every active member and
the group provider identity are current members of the pool (SPEC-042-R003)
meeting the pool's binary floor (SPEC-042-R004). Because the group has one
owner (SPEC-051-R001), every member is then owned by the pool creator or
admitted under the creator's delegation from that one owner (SPEC-043-R006).
A failure of any check excludes the head from that attempt; it MUST NOT fall
back to global routing (SPEC-042-R005).

Removing the group from the extension, or removing its pool model entry, stops
new selection at the next accepted generation. Attempts already dispatched
settle from their route snapshot under SPEC-042-R015.

### SPEC-051-R029 - Group wire messages

All group messages are JSON text frames on the provider WebSocket, parsed
strictly: unknown, missing or duplicate keys and out-of-range values are
refused. Integers are JSON numbers in `[0, 2^53 - 1]`. Signatures are base64
(standard alphabet, padded) Ed25519 signatures of exactly 64 bytes.

Capabilities, in the v2 `auth_request.tier2_capabilities` object:

- `shard_group_head_v1` (boolean): the session is a head session. It is not
  routable until its group is available (SPEC-051-R015), and then only as
  SPEC-051-R016 and SPEC-051-R028 allow.
- `shard_member_v1` (boolean): the session is a member session. It is never
  routable. A session advertising both is a member session and cannot
  register a group.

Head to coordinator:

- `shard_group_register`: `{type, version: 1, record, record_signature}`.
  `record` is the SPEC-051-R005 group record; `record_signature` is the head
  session receipt key's signature over the UTF-8 bytes
  `macprovider.shard-group-record.v1` and a line feed, followed by the JCS
  bytes of `record`.
  `record.group_provider_id` MUST equal the head session's provider id.
- `shard_group_heartbeat`: `{type, version: 1, group_provider_id, group_epoch,
  members, links}`. `members` lists exactly the record's active members and
  spares, each once, as `{member_device_id, healthy}`. `links` lists exactly
  the required links as `{from_member_device_id, to_member_device_id,
  interface_type, rtt_p99_us}`: stage `i` to stage `i+1`, the last stage to
  stage 0, and stage 0 to each spare. `interface_type` is one of
  `thunderbolt`, `ethernet`, `wifi`, `vpn`, `other`; only `thunderbolt` (for
  `thunderbolt-ip`) or `ethernet` (for `ethernet`) is admissible. The head
  MUST send it at least once per coordinator `heartbeat_interval_s` and
  immediately on any member health or link change.

Member to coordinator, on the member session:

- `shard_member_hello`: `{type, version: 1, group_provider_id, group_epoch,
  member_device_id, role, stage_index, layer_start, layer_end,
  transport_version, artifact_hash_algorithm, artifact_hash, weights_verified,
  stage_fits, links}`. `member_device_id` MUST equal the session's provider
  id; `role` is `stage` or `spare`; the stage fields name the stage it holds
  or backs; `weights_verified` and `stage_fits` MUST be true
  (SPEC-051-R006, SPEC-051-R008); `links` lists
  `{peer_member_device_id, interface_type}` for every stage link the member
  carries (its upstream and downstream neighbours, the last stage's
  downstream neighbour being stage 0; a spare's link to stage 0). The
  coordinator accepts it only against the accepted record for that epoch,
  with every value equal to the record and every link admissible, and then
  binds the member's current receipt key to that epoch. A hello for an epoch
  not yet registered is kept and evaluated when the record arrives.

Coordinator to head:

- `shard_group_register_result`: `{type, version: 1, group_provider_id,
  group_epoch, accepted, reason}`; `reason` is empty when accepted.
- `shard_group_status`: `{type, version: 1, group_provider_id, group_epoch,
  available, reason}`; `reason` is a SPEC-051-R015 code, empty when
  available. The head MUST NOT accept group work it cannot serve and MUST NOT
  treat itself as serving before it receives `available: true`.

Coordinator to member:

- `shard_member_hello_result`: `{type, version: 1, group_provider_id,
  group_epoch, accepted, reason}`, sent on each hello and again when a kept
  hello is accepted at registration.

Registration reason codes: `invalid_record`, `signature_invalid`,
`not_group_head_session`, `epoch_not_increasing`, `mode_reserved`,
`interconnect_reserved`, `frame_protection_below_minimum`,
`transport_version_unsupported`, `placement_invalid`, `too_many_members`,
`model_mismatch`, `member_conflict`, `owner_mismatch`, `store_unavailable`.
Member hello reason codes: `invalid_hello`, `not_member_session`,
`group_not_registered`, `epoch_superseded`, `record_mismatch`,
`link_interface_invalid`, `weights_unverified`, `member_conflict`.

Inference frames are unchanged except for two additions on
`inference_response_end` from a head session: the `group_attestation` member
(SPEC-051-R019) and the `error_shard_group_failed` status (SPEC-051-R021,
SPEC-051-R022).

### SPEC-051-R030 - Pool disclosure of multi-Mac serving

While a pool's active core carries `pool_shard_groups/v1`, its
`pool_policy.json` and `pool_status.json` (SPEC-042-R008, SPEC-043-R009) MUST
carry a `multi_mac_serving` object with `enabled: true`, the sorted distinct
`pool_model_ids` the extension names, the largest `max_members`, and the
disclosure text "Requests for these models may be served by a group of up to
N Macs owned by one operator on one local network. Every Mac in the group
processes the full prompt and output." with N the largest `max_members`. The
object MUST NOT name provider identities (SPEC-042 §2, SPEC-006). A pool
without the extension omits the object, so its documents are unchanged. The
creator's reviewed distribution artifact and announcements (SPEC-043-R008)
MUST carry the same statement. The disclosure describes exposure, not
protection: it MUST NOT describe transport encryption as a privacy property
(SPEC-051-R009).

## 6. Implementation, tests, and journeys

The machine-readable mapping is in `CONFORMANCE.json`. The split:

- Stage transport, supervision, stage engine, and the provider half of the
  group messages: `phase3-binary/` (provider CLI).
- Group registration, member binding, availability, routing gates, the
  `pool_shard_groups/v1` extension, the disclosure object, group attestation
  verification and storage, and the pre-first-token failover mapping:
  `phase4-coordinator/` (`internal/shardgroup`, `internal/ws`,
  `internal/buyer`, `internal/poolmanifest`, `internal/trustpool`).
- Ledger and settlement: unchanged SPEC-005, SPEC-022 and SPEC-042 pool code
  paths, keyed by the group provider identity.

Journeys: a two-Mac lab group serving a small model that also fits on one Mac
(parity and transport numbers, SPEC-051-R025), and the live proof: a paid
Trusted Pool request through the gateway, served by a group the pool's core
authorizes, and settled at the pool price.

## 7. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-051-R001`..`R030` | `DECISION_REQUIRED` | `@Augustas11` | `#2084` | Provider implementation, tests, and a paid Trusted Pool request through the gateway served by an authorized group |
| `SPEC-051-R025`, `R026` (global tuples only) | `DECISION_REQUIRED` | `@Augustas11` | `#2084` | SPEC-023/SPEC-010 amendment for how a signed catalog row names a sharded tuple and its buyer-grade floor, before any global (poolless) group serving |

Resolved in v0.2.0 from existing specs: the group wire messages are SPEC-001
extensions specified in SPEC-051-R029; a pre-first-token group abort maps onto
the SPEC-005 §6.11 zero-credit failover row, not the §6.2 zero-row path,
because the provider was reached (SPEC-051-R021); a mid-stream failure follows
SPEC-005 §6 exactly as for a single provider (SPEC-051-R022).

## 8. Current contract notes

- A decode hop for a 7168-wide model is one bf16 vector of 14,336 bytes. The
  wire is not the bottleneck on any wired link; per-hop software latency is,
  which is why SPEC-051-R026 measures it in the running engine.
- One request in a pipeline gets about one Mac's decode speed. Group revenue
  comes from requests overlapping across stages (SPEC-051-R017).
- The receipt tuple is locked by SPEC-015, so per-member data travels in the
  group attestation bound to the receipt digest, not inside the tuple.
- The pool label binds the group transitively: the route snapshot carries the
  pool id and the manifest core digest whose `pool_shard_groups/v1` extension
  named the group, and the receipt signs the route snapshot digest.
- Activation digests chain exactly because both ends hash the same
  transmitted bytes. Cross-chip floating-point drift affects parity checks
  (SPEC-051-R025), not the chain.
- Nothing in SPEC-051 withdraws, disables or reprices a group on a schedule.

## 9. Evidence

None yet. Qualification records and the live journey will be listed here and
in `CONFORMANCE.json`.

## 10. Changelog and history

- v0.2.2 (2026-10-22, Related: #2084): epochs after a takeover (R023): the
  head persists the last accepted epoch and builds above it; members follow
  the head to a later epoch and refuse an earlier one.
- v0.2.1 (2026-10-22, Related: #2084): takeover attestation (R019 item 6):
  one new-epoch segment from step 0, a `takeover` object with the replaced
  epoch and reason, no sub-receipt from the lost member; the coordinator
  records the takeover with the attestation.
- v0.2.0 (2026-10-22, Related: #2084): Trusted Pool serving, head identity as
  group identity, `pool_shard_groups/v1`, group wire messages, disclosure,
  attestation wire form, failure-status mapping; R028-R030 added.
- v0.1.0 (2026-10-22, Related: #2084): first draft.
