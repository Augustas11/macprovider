# Reservation search progress R27/R33 final independent plan review (Sol)

Date: 2026-09-11

Reviewer: independent native GPT-5.6 Sol adversarial final gate

Verdict: **BLOCK — NOT APPROVED FOR IMPLEMENTATION**

## Gate result

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 6 |
| Medium | 3 |
| Low | 1 |
| Informational | 2 |

The pass condition is exactly zero Critical, High, and Medium findings. R27/R33
therefore fails the final plan gate. No predecessor finding or acceptance
requirement is waived, weakened, or downgraded.

Architecture status: **BLOCK**. Code/security recommendation: **REQUEST
CHANGES**.

## Frozen review inputs

- Exact reviewed commit:
  `9e5bcaefad0671ea1cd287a5f17b935f3d6a4e5d`
- Exact parent/failed predecessor review commit:
  `c9c46b03799a9314eb6a73a452ca21562af01d93`
- Fetched `origin/main`:
  `7128d1206afcf3cc857479e1d776ddc4899b020a`
- R27 SHA-256:
  `6c324d3e13b4373abdc61c7b02737e6324f346b5918a083f67576718d3b16d6f`
- R33 SHA-256:
  `5d4a911e90e7b135f292cd7b80eb8e841e116355f05654f0f049448984211f72`
- Failed R26 review artifact SHA-256:
  `ea22bd66871f033f0bb690311148eb3b090e95731cebbd37f09c770d5d837d46`
- Failed R26 review counts: 0 Critical, 7 High, 3 Medium, 1 Low, 2
  Informational.

Accumulated governing hashes reproduced:

| Input | SHA-256 |
|---|---|
| R23 | `eb49d8ab8493edfc53527fb9ae2729e56983eeb76cb043d4b0ec959675c344b2` |
| R29 | `77254fbb72d59763b333a219789922e492d32373454a08aa873d333a40c96f38` |
| R24 | `9bbaf6ad3edcfe3cbab33da045914fa5a52f4f209f2dc9ee7cd2cb6589eb5321` |
| R30 | `6d5586836618a5d4b110a4f393e9368c7646141149c6998e87d371027ba0783f` |
| R25 | `75d7ae4cc0dabe7e8f22a6ca1ba4bff4a0338a72fc49a042c59d6a087787d9d2` |
| R31 | `7a3995baa5c5d89653176b3b3598e41d63d2d7d2a4b30b09188ef4818c345641` |
| R26 | `358e63153db080ee22424e567ab312c1465b2b89e3489519447322aba320c42d` |
| R32 | `80b4b213e81e89c674d450b176d3d3c39ac9d8b0cf15025abdcf1ea9d10cd1a8` |

The reviewed commit adds only R27 and R33. `git diff --check` passed. The
worktree contained many unrelated tracked and untracked Build 1 paths before
this artifact; none was changed by this review. This review did not inspect
`d-inference` or operator secrets.

## Findings

### R27-PLAN-H1 — broker CAS witnesses and root worker successors form an unconstructible digest cycle and are not crash-reconstructible

**Severity: High**

**Evidence**

- `broker_sql_cas_witness_v1` signs both `successor_row_sha256` and
  `worker_record_sha256-or-null`, and its own final SHA is the value used by the
  root successor (`reservation-search-progress-addendum-r27.md:459-491`).
- The sole `serving_worker_v3` includes `broker CAS witness SHA` as field 34,
  required for every record after the first accepted record (`:417-456`).
- The prepared-to-running registered SQL transition stores the successor worker
  record SHA in `serving_slots.last_record_sha256`
  (`reservation-search-progress-addendum-r23.md:754,986-988`). R27 finalize
  requires the broker's prepared-to-running witness before authorityd publishes
  the running worker successor containing that witness SHA (`R27:500-504`).
- Therefore the witness SHA depends on the worker SHA through both its explicit
  worker field and complete successor-row digest, while the worker SHA depends
  on the witness SHA. Neither byte string can be constructed first.
- Independently, the claimed after-commit reconstruction says the witness is
  rebuilt from the current row, root predecessor, transition descriptor, and
  prior witness (`R27:476-486`), but the signed witness also contains a witness
  UUID, predecessor row digest, issued time, expiry time, and boot UUID. The
  existing serving row does not persist that complete precommit witness or all
  of those reconstruction operands; terminal-to-free also erases the complete
  predecessor row.

**Consequence**

The mandatory finalize/termination bridge cannot emit canonical signed bytes.
A crash after SQL commit but before delivery can produce a committed SQL state
for which byte-identical witness recovery is impossible. Implementations must
invent an unhashed placeholder, a side journal, or a different ordering, each
outside the reviewed protocol and its storage/replay bounds.

**Required correction**

Define an acyclic two-phase construction. Persist every precommit witness
operand in bounded authoritative SQL state before the effect, and ensure the
SQL successor digest does not include a record whose digest includes that same
witness. Publish exact intermediate/final codecs and DML, crash recovery for
each commit/fsync boundary, and independent no-cycle/reconstruction tests.

### R27-PLAN-H2 — exact-message code authentication still has no public source for the signed pidversion identity

**Severity: High**

**Evidence**

- R27 authenticates the same received dictionary with
  `SecCodeCreateWithXPCMessage`, but obtains UID/PID from the connection
  (`reservation-search-progress-addendum-r27.md:269-279`). Receipts then sign
  authenticated PID and pidversion (`:362-372`), and worker reconnect and
  abnormal recovery rely on PID/pidversion/start/CDHash/boot (`:431-433,
  542-555`).
- The SDK says `SecCodeCreateWithXPCMessage` uses the audit token associated
  with the exact message, while `xpc_connection_get_pid` can go stale and be
  reused. The public `audit_token_to_pidversion` function requires an
  `audit_token_t`; no public libxpc API in the inspected headers returns the
  message audit token.
- R33-04's ordered instrumentation records code/requirement/CDHash/UID but not
  an exact-message pidversion or process-start derivation before decode/root
  access (`test-spec-r33-reservation-r27-corrections.md:126-158`). R33-05 also
  checks authenticated code/UID while omitting the receipt PID/pidversion
  derivation (`:159-192`).

**Consequence**

The plan can bind code identity to one message, but it cannot populate or prove
the process-execution fields it makes signed authority. A racy connection-PID
lookup can pass the written gate and reintroduce the exec/PID-reuse gap that H6
was meant to close.

**Required correction**

Specify a public, compile-tested way to derive the exact message's
process-execution identity, including pidversion and every signed receipt field,
or replace those fields with a fully specified public binding. Extend R33-04/05
to observe and mutate that exact binding before tuple decode and root access.

### R27-PLAN-H3 — backup restore has no closed data plane for the main database bytes

**Severity: High**

**Evidence**

- Retained R25 requires backup/restore of the exact selected main bytes
  (`reservation-search-progress-addendum-r25.md:157-173`).
- R27 restore carries main SHA/length and envelope/witness/lease metadata but no
  main bytes, source FD, staged leaf, path, or confined capability
  (`reservation-search-progress-addendum-r27.md:392-402`).
- R27 explicitly forbids moving the main bytes through XPC (`:638-645`) while
  naming same-authority restore as the post-B8 recovery path (`:740-744`).
- R33-07 demands an exact stopped export/restore and rejects raw copied main,
  but supplies no authorized source or transfer protocol (`test-spec-r33-reservation-r27-corrections.md:240-265`).

**Consequence**

The named recovery operation is not implementable from the closed RPCs.
Implementation would have to add arbitrary-path access, an unreviewed FD
capability, or a broker-private copy mechanism that the splice, crash, size,
and root-identity tests do not cover.

**Required correction**

Define the bounded backup-main component, custody location, opener, FD/path
confinement, identity/hash verification, transfer direction, crash cleanup,
replay rules, and at-limit/first-over tests. Bind that capability to the restore
request, export receipt, envelope, state witness, and consumed lease.

### R27-PLAN-H4 — the privileged raw-XPC FD grammar is contradictory

**Severity: High**

**Evidence**

- Broker startup must receive one provider-root directory FD
  (`reservation-search-progress-addendum-r27.md:193-203`).
- R27 then says replies carry no FD except serving offer and broker startup,
  but immediately allows each reply a method-specific artifact or directory FD
  (`:282-286`).
- The hard-limit rule says one FD only on accept/offer, omitting the required
  broker-startup reply (`:288-298`).
- R33-04 uses a third, clearer grammar: offer reply, accept request, and broker
  startup reply each have exactly one specific FD and every other direction has
  none (`test-spec-r33-reservation-r27-corrections.md:150-158`). R33 does not
  explicitly state that this replaces the contradictory R27 transport rule.

**Consequence**

One conforming implementation must reject the broker's required directory
capability; another can interpret “method-specific” as authority to attach FDs
to additional replies. This is capability confusion at a root service boundary.

**Required correction**

Publish one exact per-method request/reply dictionary grammar: broker-startup
reply only directory FD, offer reply only locked artifact FD, accept request
only proof FD, and no FD anywhere else. Include each direction in caps,
counter/cleanup rules, and negative tests.

### R27-PLAN-H5 — the inherited handoff path cannot reproduce R27's required lengths or restart identity

**Severity: High**

**Evidence**

- R25's retained exact handoff path is
  `lock-handoffs/<slot-ordinal>-<slot-generation>.handoff-v1`
  (`reservation-search-progress-addendum-r25.md:400-411`). At maximum values it
  is 47 bytes and its `.tmp-r27` successor would be 55 bytes.
- R27 defines the worker path but only states that “corresponding handoff” paths
  are 84/92 bytes; it publishes no replacement spelling or digest
  (`reservation-search-progress-addendum-r27.md:451-456`). Those lengths are
  obtainable only by inventing an added hyphen and permit UUID.
- Recovery forbids enumeration and relies on directly derived handoff/worker
  paths (`R25:464-475`; `R27:535-555,596-603`). R33-06 asserts only 84/92
  lengths and never supplies the missing canonical path bytes/SHA
  (`test-spec-r33-reservation-r27-corrections.md:193-239`).

**Consequence**

Independent implementations cannot address the same root object after restart.
They may orphan the retained R25 leaf, derive an unreviewed R27 leaf, or disagree
about slot padding and permit inclusion, breaking recovery and storage proofs.

**Required correction**

Publish the exact final and temp handoff relative paths, generation and slot
spellings, permit inclusion rule, path digests, replacement statement for R25,
and collision/dual-codec crash table. Test the complete bytes and hashes, not
only lengths.

### R27-PLAN-H6 — whole-authority destruction lacks an authenticated operator-intent protocol

**Severity: High**

**Evidence**

- The public broker boundary exposes opaque `perform` actions without an actor
  or authorization contract (`reservation-search-progress-addendum-r27.md:303-326`).
- `broker_authority_state_witness_v1` can set purpose `destroy` and binds only a
  trigger request SHA plus broker signing identity (`:561-589`). Authorityd
  authenticates the broker witness and issues the maintenance lease (`:591-613`).
- R27 says whole-authority destruction additionally requires “explicit stopped
  operator intent,” but defines no tuple/domain, authenticated actor, privilege
  acquisition, signature, freshness, single-use identity, or receipt for that
  intent (`:646-654`). R33-07 and R33-11 execute destruction but do not supply
  the missing authority object (`test-spec-r33-reservation-r27-corrections.md:240-265,324-345`).

**Consequence**

The root daemon can only distinguish a broker-signed destroy request from other
broker requests, not prove that an authorized operator requested irreversible
anchor, database, receipt, and key deletion. A same-UID client path or broker
compromise becomes sufficient authority for whole-authority destruction.

**Required correction**

Define the operator authorization mechanism and exact signed/request-bound,
single-use destroy-intent codec; constrain which binary/identity can obtain it;
bind it through broker witness, maintenance lease, consumed state, deletion
receipt, and restart reconciliation; add unauthorized same-UID, replay, stale,
wrong-root, and partial-destruction tests.

### R27-PLAN-M1 — the intent storage maximum excludes an explicitly preserved collision state

**Severity: Medium**

**Evidence**

- Restart preserves, without unlinking, `temp + final` and other ambiguous
  intent states (`reservation-search-progress-addendum-r27.md:656-674`).
- The two-generation bound permits one selected final plus a candidate final and
  candidate temp. At 619 bytes each this reachable protected state is 1,857
  bytes.
- The storage table allows only 1,238 bytes and rolls that value into the
  653,398-byte daemon total (`:683-706`). R33-12 repeats 619 bytes/two
  generations without constructing the protected three-file state
  (`test-spec-r33-reservation-r27-corrections.md:346-365`).

**Consequence**

The claimed physical maximum and first-over reservation can be exceeded by a
required evidence-preserving crash state. A reservation sized to the plan can
fail while attempting to protect evidence or admit a successor.

**Required correction**

Enumerate every reachable final/prefix/collision combination, raise the intent
and aggregate maxima (at least 1,857 and 654,017 for this case), and test exact
at-limit/first-over recovery without deleting ambiguous evidence.

### R27-PLAN-M2 — the authoritative worker ordinal table duplicates field 21

**Severity: Medium**

**Evidence**

- The sole worker codec says fields 1...35 form the unsigned tuple and 36...37
  form the final tuple, but its table lists `accepted handoff SHA` twice at
  ordinal 21 (`reservation-search-progress-addendum-r27.md:417-444`).
- R33-06 requires generating a checked-in complete 37-field ordinal table from
  R27 (`test-spec-r33-reservation-r27-corrections.md:193-201`). Literal
  generation produces 38 rows or a duplicate ordinal; silently deduplicating is
  an unreviewed normalization.

**Consequence**

The sole signed root record does not have one machine-exact field map, so strict
independent codec generators can disagree even though the supplied 1,486-byte
golden can be reproduced by assuming the duplicate is editorial.

**Required correction**

Remove the duplicate, publish all 37 rows individually with exact type/null/state
rules, and regenerate the golden from that literal table in two implementations.

### R27-PLAN-M3 — the claimed author oracle package is not replayable from the reviewed bytes

**Severity: Medium**

**Evidence**

- R27 says R33 records exact executable commands
  (`reservation-search-progress-addendum-r27.md:752-762`).
- R33's command `sha256sum reservation-search-progress-r26-plan-sol.md R26 R32`
  uses nonexistent shorthand paths; `python3 independent_schema_tuple_jcs_oracle.py`
  names a file absent from the repository; and
  `rg public-xpc-and-security-symbols SDK` searches a literal nonexistent path
  (`test-spec-r33-reservation-r27-corrections.md:367-390`).
- Corrected independent inline programs reproduced the declared schema, tuple,
  path, JCS, and worker vectors, but those are reviewer work, not replayable
  author evidence shipped with R33.

**Consequence**

The author-time “fresh results” and exact-command claim cannot be independently
rerun from the proposed artifacts, weakening the required handoff to later
implementation and final verification.

**Required correction**

Preserve the independent oracle sources and exact repo-relative commands,
including tool versions and expected full output. Make the command block
executable verbatim in a clean checkout.

### R27-PLAN-L1 — the format-hash sentence is ambiguous across distinct legal generations

**Severity: Low**

**Evidence**

- R27 says the format object is 806 bytes for every generation and “hashes to”
  one digest (`reservation-search-progress-addendum-r27.md:137-152`).
- All five legal objects are 806 bytes, but their hashes are distinct; only the
  displayed generation-1 object hashes to `bcc1bb0f...019c0`. R33-02 correctly
  requires distinct objects and applies that SHA only to generation 1
  (`test-spec-r33-reservation-r27-corrections.md:78-95`).

**Consequence**

R33 resolves the intended test behavior, but an implementer reading the
normative R27 sentence alone can mistake the generation-1 golden for a universal
format hash.

**Required correction**

State explicitly that 806 is invariant while the displayed SHA is only the
generation-1 golden and every other generation recomputes a distinct SHA.

## Informational observations

### R27-PLAN-I1 — exact schema, registry, tuple, path, JCS, and worker goldens reproduce under the intended interpretation

Independent extraction and encoders reproduced:

- schema: 44,448 bytes,
  `434b4d4eb9370e6707ec12d6ca2ea584f47d2f970c4d633a96a87e7d14aa5e06`;
  SQLite 3.53.4 reported application ID 1297109587, user version 27, 24
  non-internal tables, and 11 explicit indexes;
- registry: 495 records / 68,992 bytes /
  `d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`;
- dispatch: 1,309 bytes /
  `af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`;
- semantic tuple: 97,959 bytes /
  `0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`;
- bootstrap/database tuples: 305/
  `2b3972d7b5d1866b4d6974ab0a5a8e871c4812c678c8a42d593ca423d4dab815`
  and 344/
  `251788668b16ed037dc126fc0f3fffad4e6786ab6ce8b30b87f9ee59004f0b3b`;
- intent/final/temp: 619/
  `97c8ea16ed0c9acc384d529a67d2541203e40c7cb872d9786ae24dbe905c3638`,
  113/`bf22af8e0fb36f4df477331045d08fd90cf12350b98dadd85ece2ee5df43c48f`,
  and 121/`b743e2bf5240340a207adbbc055735e625350724345e39b167f05721f4265b52`;
- authority/provider roots: 59/
  `148e1b60fb4d76b59bd145b6e515a4bf77f9d1edf3f13c2cf86eaaf001979ae4`,
  336/`b1fe4bf7e7a17761822264c9d7562c28e6cee25d7c6c538ecf455a686794f992`,
  21/`94023778ffccea6ea05fe42fbe22768945b3b1ea1ac54e103ba441c3f0443ded`,
  and 263/`02f196c7c4a5772e0c5ecd6f443c71a9d48b5a664b64b403c2bfabeb10ec4227`;
- five format vectors: all 806 bytes and distinct; generation 1 is
  `bcc1bb0f65f72bf8980dc5fb7db1f42153f679a17435411dfb7b69f7b20019c0`;
- worker maximum: 1,486 bytes /
  `e17519ab19ecb088bdb59c2675283574518120ef5e01e9a1e00d2d0342908fee`,
  after interpreting the duplicate ordinal as one field; worker paths 85/93.

These are shape checks, not evidence that the blocked protocols can be safely
constructed or recovered.

### R27-PLAN-I2 — current inventory and package facts reproduce but do not prove eventual acceptance

The current accumulated inventory contains 191 production Swift files under
the CLI/Malibu roots. `ModelRuntime.swift` is a literal path overlap between
`7c0aad11` and `7128d120`; the inspected hunks are paged-KV scheduler bridge
work. `Package.swift` currently has only the existing library/CLI products, as
expected before the proposed five roots are implemented. The SDK declares all
named libxpc/Security functions. The repository version constant is 1.8.123.
These facts support R27's implementation inventory premise, not signed-package,
physical-Mac, Xcode, actual-MLX, predecessor-asset, release, or production
acceptance.

## Independent commands and results

The following fresh checks were run from
`/Users/augstar/.codex/worktrees/macprovider/product-build-1`:

~~~text
git fetch --prune origin
git rev-parse 9e5bcaef HEAD origin/main
# 9e5bcaefad0671ea1cd287a5f17b935f3d6a4e5d
# 9e5bcaefad0671ea1cd287a5f17b935f3d6a4e5d
# 7128d1206afcf3cc857479e1d776ddc4899b020a

shasum -a 256 R27 R33 failed-review R23-R26 R29-R32
# every full digest in Frozen review inputs reproduced

git show --name-status --format=fuller 9e5bcaef
# exactly two added Markdown files: R27 and R33

git diff --check 9e5bcaef^ 9e5bcaef -- R27 R33
# exit 0, no output

python3 independent inline schema/SQLite oracle
# R23 43652/70b34a...81f; R25 44213/2bcde8...47e;
# R26 44295/b8c641...86d; R27 44448/434b4d...e06
# SQLite 3.53.4 / application 1297109587 / user 27 / tables 24 / indexes 11

python3 R24 literal registry/dispatch/semantic extraction and tuple oracle
# registry 68992/d9426b...f63/495 records
# dispatch 1309/af142c...fb/13 records
# R23 semantic body 27602/c7b359...ae6
# semantic tuple 97959/0640f9...aee

python3 independent tuple/path/JCS/worker encoders
# all values listed in R27-PLAN-I1 reproduced
# format hashes distinct across all five legal generation strings
# inherited handoff path 47/55; invented permit-bearing path alone is 84/92
# declared daemon total 653398; three-file protected intent state makes 654017

xcrun --sdk macosx --show-sdk-path
rg SecCodeCreateWithXPCMessage|xpc_connection_get_pid|audit_token_to_pidversion SDK
# named symbols declared; connection PID header explicitly warns of staleness/reuse

find CLI Malibu -type f -name '*.swift' | sort | wc -l
# 191

git diff --name-only 7c0aad11 7128d120 -- ModelRuntime.swift
# phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
~~~

No Swift/Xcode/package/physical-Mac/actual-MLX/release suite was run because the
reviewed change is a plan proposal and the required implementation and frozen
asset evidence do not yet exist. No such suite is reported as passed.

## Predecessor closure result

R27 materially fixes the 20-digit generation representation, deployable target
inventory, request-bound receipts, acyclic backup metadata envelopes, durable
B8 selection, exact zero-byte temp successor, bounded XPC counters, frozen
predecessor gate, and broader eventual-base inventory. The predecessor H2/H3/H6
closures remain incomplete because the CAS bridge is cyclic/non-recoverable,
pidversion is not derivable from the specified public exact-message API, and
destructive operator authority is undefined. New blockers exist in restore data
movement, FD grammar, and handoff addressing. The plan cannot proceed to
implementation.
