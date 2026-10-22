# SPEC-051 - Multi-Mac Shard Groups

**Version:** 0.1.0

```json
{
  "spec_id": "SPEC-051",
  "title": "Multi-Mac Shard Groups",
  "version": "0.1.0",
  "path": "specs/SPEC-051-multi-mac-shard-groups.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["multi-mac-shard-groups"],
  "supersedes": [],
  "depends_on": ["SPEC-001", "SPEC-002", "SPEC-003", "SPEC-005", "SPEC-006", "SPEC-008", "SPEC-010", "SPEC-015", "SPEC-022", "SPEC-023", "SPEC-027", "SPEC-032", "SPEC-033", "SPEC-036", "SPEC-038", "SPEC-041", "SPEC-042", "SPEC-044", "SPEC-047", "SPEC-049"],
  "implementation_status": "pending-reconciliation",
  "production_status": "not-deployed",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "DECISION_REQUIRED",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/2084",
    "rationale": "SPEC-051 v0.1.0 defines single-owner multi-Mac shard groups: pipeline-parallel serving of one catalog model across co-located Macs on one wired LAN, with one provider identity, minimum-of-members trust, a framed stage transport, one head-signed receipt with chained per-member sub-receipts, and explicit failure semantics. Every requirement stays pending until a paid gateway request is served by a qualified shard group and settled at the catalog price."
  }
}
```

**Change log v0.1.0 (2026-10-22, Related: #2084):** First draft. Single-owner
pipeline groups over Thunderbolt-bridge IP or Ethernet. Tensor parallelism and
RDMA over Thunderbolt 5 are reserved values, not served. Multi-owner groups
and intra-group earnings splits are reserved.

## 1. Purpose and scope

Some catalog models do not fit in one Mac's memory (400B+ MoE models at
4-bit, 1T-class models). SPEC-051 lets one owner serve such a model across
several of their own Macs on one wired LAN. The model is split by layer range
(pipeline parallelism): each Mac holds a contiguous range of layers and its
own KV cache, and passes one boundary activation per token to the next Mac.
To the network the group is one provider serving one catalog model at the
catalog price.

The outcome is memory capacity, not single-stream speed. Pipeline decode of
one request runs at about one Mac's speed; aggregate throughput needs several
requests in flight across stages (SPEC-051-R017). The go/no-go rule in
SPEC-051-R026 decides whether a sharded tuple is worth admitting.

In scope for v0.1:

- shard groups of one owner's Macs on one wired LAN, pipeline mode only;
- the group record, member admission, and the trust and privacy rules;
- the stage transport between members (framing, integrity, deadlines,
  heartbeats);
- group health, routing to the group head, and dispatch;
- one buyer receipt per request with per-member sub-receipts;
- billing as one provider at the catalog price;
- failure semantics before and after the first streamed token;
- qualification of a sharded tuple before catalog intake.

Out of scope for v0.1, reserved:

- tensor parallelism (`parallelism_mode = tensor`) and RDMA over Thunderbolt 5
  (`interconnect_class = rdma-tb5`). Both are enum values from the first
  draft so a later revision adds them as an engine mode, not a protocol
  redesign. A v0.1 coordinator refuses both (SPEC-051-R005);
- groups whose members belong to different owners, and any split of group
  earnings between members (SPEC-051-R020);
- groups across sites or over the public internet, and Wi-Fi links
  (SPEC-051-R007);
- Trusted Pool serving (SPEC-042) and relay-blind or privacy-class requests
  (SPEC-041, SPEC-049) by a group (SPEC-051-R009).

Single-Mac serving is unchanged (SPEC-051-R024).

## 2. Dependencies and authority

SPEC-051 owns the authority domain `multi-mac-shard-groups`: the shard group
concept, the group record and epoch, member and spare roles, layer placement
validity, interconnect admissibility, the stage transport frame and its
supervision, the group attestation and member sub-receipts, group failure
semantics, and sharded-tuple qualification and its decision rule.

Consumed contracts, owned elsewhere. SPEC-051 cites them and does not restate
or change them:

- **SPEC-001** owns the provider wire protocol. The group registration and
  group heartbeat messages are additions to that protocol (§7, open gap).
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
- **SPEC-042** owns Trusted Pools.

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
| Group provider identity | The one provider identity the network sees for the group. Its session is held by the head. |
| Member device identity | A member's own enrolled provider identity (SPEC-003). It is never buyer-visible and never separately routable while in an active group epoch. |
| Group epoch | A strictly increasing unsigned 64-bit integer naming one exact membership and layer placement. |
| Boundary activation | The hidden-state tensor one stage sends to the next for one request and one step. |
| Hop | One transfer of a boundary activation between adjacent stages, or of a token ID from the last stage to the head. |
| Micro-batch | A set of request rows that move through the stages together in one step. |
| Sharded tuple | A catalog model tuple served in `pipeline` mode over one interconnect class with a given stage count. |

## 4. Configuration

Coordinator `coordinator.yaml`, section `shard_groups`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `max_members` | int 2..8 | `4` | Upper bound on active members plus spares in one group. |
| `max_link_rtt_p99_us` | int 200..5000 | `2000` | Upper bound on each link's measured p99 heartbeat round trip (SPEC-051-R007). |
| `required_frame_protection.thunderbolt-ip` | enum | `crc32c` | Minimum frame protection on a point-to-point Thunderbolt-bridge link (SPEC-051-R011). |
| `required_frame_protection.ethernet` | enum | `hmac-sha256` | Minimum frame protection on an Ethernet link (SPEC-051-R011). |

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
the public internet. A group serves exactly one catalog model at a time.

### SPEC-051-R002 - One group provider identity, member device identities

Each group MUST have exactly one group provider identity, enrolled under
SPEC-003 like any provider and distinct from every member device identity.
Only the head holds the group provider identity's coordinator session and
credentials. Every member MUST also hold its own enrolled member device
identity and authenticate it to the coordinator for admission
(SPEC-051-R003) and health (SPEC-051-R015). Buyer-visible surfaces, receipts
(SPEC-051-R018) and the measured-performance store (SPEC-002-R005) MUST name
only the group provider identity. Member device identities appear only in the
group record, the group attestation (SPEC-051-R019), and operator surfaces. A
member device identity MUST belong to at most one group at a time.

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
mismatch MUST fail group registration.

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
record signed by the group provider identity. The coordinator MUST store each
accepted record append-only and refuse any record whose `group_epoch` is not
strictly greater than the last accepted epoch for that group. The record MUST
carry exactly these fields:

| Field | Meaning |
|---|---|
| `schema` | Exactly `macprovider.shard-group-record.v1`. |
| `group_provider_id` | The group provider identity. |
| `group_epoch` | Unsigned 64-bit integer, strictly increasing per group. |
| `parallelism_mode` | Closed enum `pipeline` \| `tensor`. v0.1 accepts only `pipeline`; `tensor` is reserved and MUST be refused. |
| `interconnect_class` | Closed enum `thunderbolt-ip` \| `ethernet` \| `rdma-tb5`. v0.1 accepts `thunderbolt-ip` and `ethernet`; `rdma-tb5` is reserved and MUST be refused. There is no Wi-Fi value. |
| `frame_protection` | Closed enum `crc32c` \| `hmac-sha256` \| `aead-chacha20poly1305` (SPEC-051-R011). |
| `transport_version` | The stage-transport version every member runs. |
| `model` | The catalog model id and its exact signed catalog tuple: catalog release identity, model key, and `(hash_algorithm, hash)` artifact identity under SPEC-010-R001 and SPEC-010-R007. |
| `num_layers` | The model's transformer layer count. |
| `stages` | Ordered list of `{stage_index, member_device_id, layer_start, layer_end}`. |
| `spares` | List of `{member_device_id, stage_index}`; may be empty. |
| `supervision` | The SPEC-051 §4 group configuration values. |

Unknown fields, missing fields, and enum values outside these sets MUST be
refused.

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
2. a v0.1 group MUST NOT be eligible for relay-blind requests (SPEC-041) or
   privacy-class requests (SPEC-049), because their plaintext boundary is one
   provider process (SPEC-049-R009, SPEC-049-R011) and a group moves
   prompt-equivalent data between processes and Macs; the coordinator MUST
   exclude groups from those routes before reservation;
3. a v0.1 group MUST NOT serve Trusted Pool traffic (SPEC-042);
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

### SPEC-051-R016 - Routing to the head only

The coordinator MUST reserve and dispatch group requests only to the head's
group provider session, and MUST NOT dispatch any buyer request to a member
device identity while it is in an active group epoch, for the group's model
or any other. Phase-aware ranking (SPEC-002-R006) MUST use the group's own
measured performance (SPEC-002-R005), not any member's. Buyer ownership
exclusion (SPEC-002-R008) applies to the group's owner.

### SPEC-051-R017 - Cross-stage micro-batching

The head MUST schedule so that, whenever at least `S` requests are active,
at least `S` micro-batches are in flight across the `S` stages, and each stage
MUST batch its rows under SPEC-038 within its own engine. Sampling MUST run on
the last stage, and only token IDs travel back to the head. Prefill MUST be
pipelined in chunks across stages. Each stage MUST hold only its own layers'
KV. The group MUST advertise to the coordinator a concurrency limit no larger
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
took part, each signed by that member's device identity key, carrying:
`member_device_id`, `group_epoch`, `stage_index`, `layer_start`, `layer_end`,
the request ID, prompt tokens processed, decode steps processed, and
`in_digest` and `out_digest`. `in_digest` is the SHA-256 chain over the exact
payload bytes of every frame for that request the member received on its
upstream link, in sequence order; `out_digest` is the same over every frame it
sent downstream. The coordinator MUST verify every signature and that, for
each pair of adjacent stages, `out_digest` of stage `i` equals `in_digest` of
stage `i+1`, and that the last stage's token `out_digest` equals the head's
token `in_digest`. A failed check MUST attribute the fault to the member at
the first broken link, MUST be recorded against that member device identity,
and MUST make the request's settlement evidence fail SPEC-022 verification
for that attempt. When a spare replaced a member mid-request
(SPEC-051-R022), the attestation MUST carry both members' sub-receipts with
the step ranges each covered, and the chain MUST hold within each range.

### SPEC-051-R020 - Billing and settlement as one provider

A group request MUST be priced and settled exactly as a single-provider
request for the same catalog tuple: the SPEC-005 formula at the signed
catalog price (SPEC-005-R011), SPEC-022 verified-model settlement for the
group provider identity, and SPEC-047 admission state for the group's tuple
(SPEC-047-R001, SPEC-047-R003). There MUST be one ledger row set per
attempt, credited to the group provider identity; members earn nothing
separately. Because a v0.1 group has one owner, the owner receives the
group's provider credit. Any split of earnings between members is reserved
and MUST NOT be computed or paid in v0.1; a group record or ledger field that
claims a split MUST be refused.

### SPEC-051-R021 - Failure before the first token

When a group attempt fails before the head has streamed the first output
token to the buyer path (member death, link failure, missed deadline, chain
break, or unavailability), the head MUST abort the attempt across all members
and report a retryable provider failure that carries no completion. The
coordinator MUST retry the request on another provider or group under
SPEC-005-R006 multi-attempt attribution, and the failed group attempt MUST
NOT produce a buyer debit or provider credit. The buyer sees an error only if
every attempt fails, in the SPEC-006-R002 envelope.

### SPEC-051-R022 - Failure after the first token

When an active member fails after the first token was streamed:

1. if a healthy spare holds that stage's layers, the head MUST start a new
   group epoch with the spare in that stage, rebuild the spare's KV for the
   request's delivered prefix (prompt plus every token already delivered)
   from retained boundary activations or recomputation, and resume at the
   next undelivered token step, within `replay_deadline_ms`;
2. otherwise, or if replay does not finish within `replay_deadline_ms`, the
   head MUST terminate the stream with an explicit error in the SPEC-006-R002
   envelope, and the attempt MUST be billed for the prompt and the tokens
   actually delivered only (SPEC-005 §6.4).

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

### SPEC-051-R024 - Isolation from single-Mac serving

A provider that is not a member of an active group MUST serve exactly as it
would without SPEC-051: its wire messages, admission, routing, receipts,
billing, continuous batching, decode paths and performance MUST NOT change.
The sharded serving path MUST run only on Macs whose owner configured a group,
and only for tuples qualified under SPEC-051-R025. A coordinator or CLI
without SPEC-051 support MUST continue to serve single-Mac traffic unchanged.

### SPEC-051-R025 - Qualification before catalog intake

A sharded tuple MUST NOT enter `catalog_priced` or `settlement_capable`
(SPEC-047-R001) until a qualification record for that tuple exists. The record
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

A tuple that fails any condition MUST NOT enter catalog intake as a sharded
tuple. The decision cites these measured numbers, not a side metric.

### SPEC-051-R027 - Version skew

The coordinator MUST accept group registration only from a head and members
whose wire versions advertise SPEC-051 support, and MUST refuse a group record
it cannot fully validate. A coordinator without SPEC-051 support does not know
the group messages, so the head MUST NOT serve group traffic when its group
registration is not acknowledged; its members' single-Mac sessions are then
unaffected. A member whose transport version differs from the group record's
MUST refuse to join that epoch.

## 6. Implementation, tests, and journeys

The machine-readable mapping is in `CONFORMANCE.json`. No requirement has
mapped implementation yet. The intended split:

- Stage transport, supervision, and stage engine: `phase3-binary/`
  (provider CLI) on the MLX fork's per-model pipeline split and per-stage
  weight loading.
- Group registration, health, routing, group attestation verification:
  `phase4-coordinator/`.
- Ledger and settlement: unchanged SPEC-005 and SPEC-022 code paths, keyed by
  the group provider identity.

Journeys: a two-Mac lab group serving a small model that also fits on one Mac
(parity and transport numbers, SPEC-051-R025), and the live proof, a paid
gateway request served by a qualified group and settled at the catalog price.

## 7. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-051-R001`..`R027` | `DECISION_REQUIRED` | `@Augustas11` | `#2084` | Implementation, tests, and a paid gateway request served by a qualified group |
| `SPEC-051-R005`, `R015`, `R027` | `DECISION_REQUIRED` | `@Augustas11` | `#2084` | SPEC-001 amendment adding the group registration and group heartbeat messages to the provider wire protocol |
| `SPEC-051-R025` | `DECISION_REQUIRED` | `@Augustas11` | `#2084` | SPEC-023/SPEC-010 amendment for how a signed catalog row names a sharded tuple and its buyer-grade floor |
| `SPEC-051-R021` | `DECISION_REQUIRED` | `@Augustas11` | `#2084` | SPEC-005 confirmation that a pre-first-token group abort maps to the zero-row provider-not-reached accounting path |

## 8. Current contract notes

- A decode hop for a 7168-wide model is one bf16 vector of 14,336 bytes. The
  wire is not the bottleneck on any wired link; per-hop software latency is,
  which is why SPEC-051-R026 measures it in the running engine.
- One request in a pipeline gets about one Mac's decode speed. Group revenue
  comes from requests overlapping across stages (SPEC-051-R017).
- The receipt tuple is locked by SPEC-015, so per-member data travels in the
  group attestation bound to the receipt digest, not inside the tuple.
- Activation digests chain exactly because both ends hash the same
  transmitted bytes. Cross-chip floating-point drift affects parity checks
  (SPEC-051-R025), not the chain.
- Nothing in SPEC-051 withdraws, disables or reprices a group on a schedule.

## 9. Evidence

None yet. Qualification records and the live journey will be listed here and
in `CONFORMANCE.json`.

## 10. Changelog and history

- v0.1.0 (2026-10-22, Related: #2084): first draft.
