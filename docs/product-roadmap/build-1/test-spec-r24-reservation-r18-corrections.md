# Build 1 reservation search progress — test specification R24

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR
IMPLEMENTATION**. Governing candidate:
`reservation-search-progress-addendum-r18.md`, plus only the R16 clauses that
R18 explicitly retains. R24 supersedes R23 where they conflict and retains its
unaffected compatibility, A0...A8 economics, observability, physical evidence,
and acceptance-labeling cases.

All evidence must be fresh. Skipped, interrupted, timed-out, zero-selected,
fixture-only, synthetic-only, or historical runs cannot pass claims they do not
execute. Production and independent codecs may share frozen bytes only.

## R24-01 — frozen boundary

Recompute and record SHA-256 for R18, R24, the failed R17 review, and
`origin/main` `1d2c930bad81704dd0acc0322226725d8b64aceb`. Prove the working source
is still R4 and contains no v9 selector, v4 lease authorization, v6 lease
state, v2 custody, v2 fresh receipt, adoption recapture head, or indexed GC.

## R24-02 — bootstrap ledger within the selected limit

Independently encode generation zero, revision one, every ledger item, and
bootstrap close for R=0,1,31,32,33,1,024. Require directory intent/adoption and
close selectors to leave units/carriers at zero, both exact 4,096-byte charges,
20 isolated slots per row/fixed entry, six named genesis records, 44 addressable
page slots, and release of every unused slot. Derive
`unitLimit=20*(R+1)+50` and `carrierLimit=2*(R+1)+6` from ledger rows. Prove
consumed+released equals each limit, no cross-row/category reuse, and rejection
before fence on a 45th genesis page, hidden selector unit, double directory
charge, byte overflow, or topology exceeding its encoded byte limit.

Run the supported prior binary against the v4 fence/v9 selector and require
read-only rejection. Inject death at every mkdirat/open/no-follow/identity,
file and directory fsync, selector temp/rename/fsync, old-source revalidation,
format fence, each ledger carrier, and close boundary. Recovery selects only R4,
generation zero, revision one, a ledger prefix, or exact close.

## R24-03 — coherent lease progress and control binding

Using an independent encoder, generate 63/64-edge commit and A1/A2 abort traces.
For reserve, reserve-open, every progress, close, and terminal transition require
the R18 presence matrix, one stable authorization, exact predecessor/successor
state digests, generation +1, mandatory control authorization, mandatory
projected-entry digest, and direct promoted-root lookup equal to projected JCS.

Mutate every authorization/debit/counter/state/revision/generation/edge/category,
base selector, root, projected entry, and predecessor/successor digest. Reject
before temp creation. The 65th edge rejects. Replay converges without a second
debit. Race 64 processes and kill the flock holder at every P0...P6 boundary;
exactly one successor advances, every return closes flock/descriptors, and no
PID/time/expiry authority appears.

## R24-04 — registry-legal promoted roots

Freeze one- and two-carrier mutations for every subset of six changed roots,
including unchanged empty, changed-to-empty, and changed-to-nonempty. Independently
resolve receipt, activation, and checkpoint snapshots against the terminal
carrier; all six results must equal successor roots. Accept locals/promotions
only in the three named terminal-carrier contexts and only to lower slots.
Reject local selected roots, carrier-zero/sibling/future/self references,
branch with zero/two alternatives, promotion scalar mismatch, empty-root
promotion, or selector/leaf/work/custody objects containing locals.

## R24-05 — complete literal codec

Build a declarative independent registry from R18 and the reproduced R17 suffix
rows. Fail registry construction if any key lacks exactly one scalar/reference/
object type, enum constraint, null rule, and digest rule. Freeze minimum,
maximum, empty, generation-zero, pending, continuation, close, abort, protected,
terminal, verification, custody, adoption-recapture, and GC vectors.

For every schema mutate missing/duplicate/unknown keys, null, schema/version,
enum, scalar width, `2^53-1`, `2^53`, wide carry/overflow, float/exponent,
NFC, hex case/length, base64 padding, path traversal, union member, reference
context, framing length/hash/padding, and every `*SHA256` family. Require one
production and one independent result to agree. Enumerate all sequence schemas
and require the entry-digest sequence root to accept only its leaf. Enumerate
every evidenceKind and reject free-form kinds. Freeze complete bytes for
verification head, checkpoint/chunk chain, fresh receipt, custody head/record,
recapture head/checkpoint, GC head/checkpoint/candidate, and drain receipt.

## R24-06 — acyclic custody and fresh receipt

Independently encode C(n) verifying -> H(k) complete -> C(n+1)
verification-complete -> F -> C(n+2) verified. Build a dependency DAG from all
digest references and require topological order with no self/future edge.
Inject death before/after every write, file fsync, head replacement and parent
fsync. Recovery publishes only the byte-identical missing successor. Reject F
binding C(n+2), verified custody lacking F, F lacking C(n+1)/H(k), generation
gaps, forked heads, or any state/null mismatch.

## R24-07 — selected batching and final full freshness

On the physical supported artifact, run full current SPEC-001 hashing,
pre/post identity capture, immutable-flag installation, H/C/F/C publication,
then the selected adoption recapture scan in 4,096-entry/8-MiB/four-FD quanta.
Kill/restart every quantum and prove exact cursor/transcript continuation.
Batched readiness must never authorize pending.

For the final call mutate every manifest entry/root by content, inode, mode,
owner, flags, rename, unlink, hard link, symlink, extra entry, timestamp restore,
and path escape before its check, after its check, and immediately before both
custody/catalog fsyncs. Require rejection or demonstrated filesystem prevention;
no stale batch may pass. Record complete-recapture time/FDs over six cold runs.
If p95 exceeds eight seconds/four FDs, or root-and-descendant immutability does
not prevent all listed mutations for the interval, mark the artifact/filesystem
profile blocked and keep adoption feature-gated. Never weaken to batched proof.

## R24-08 — one 20-unit capacity graph

Generate every literal 174 per-row and 320 fixed R16 transition. Expand each to
reserve/payload/terminal-close and each mutation to T target records plus exactly
receipt/activation/checkpoint. Assert U=T+3<=20, one carrier iff U<=16, two
otherwise, all changed-root top records in the terminal carrier, no receipt in
carrier zero, exactly one selected receipt, and no
unnamed unit. Derive independently:

```text
units(R)=10,460R+19,270
Rmax=430,554,457,681
units(Rmax)=4,503,599,627,362,530
units(Rmax+1)=4,503,599,627,372,990
units(1,024)=10,730,310
carrierCount(R)<=1,046R+1,928
carrierCount(Rmax)<=450,359,962,736,254
carrierCount(1,024)<=1,073,032
```

Exercise R=0,1,31,32,33,1,024,Rmax,Rmax+1 with checked wide arithmetic.
Reject a second receipt, 18th target, 21st unit, absent terminal record,
unknown transition, first over byte/unit/carrier/row/off_t/quota/inode/free-space
limit, or a durable carrier treated as progress before P5.

## R24-09 — bounded indexed GC and fairness

At maximum product shape, freeze GC head/checkpoint/candidate bytes and validate
sorted, cycle-free linkage and transcript. Run 10,000 queued candidates with
corrupt, missing, active, pending, released, huge-manifest, and blocked-I/O
cases. Each invocation processes at most one candidate, 256 entries, 8 MiB,
1,024 syscalls, four FDs and six seconds; verify a selected cursor after each
quantum and nonblocking typed busy with no mutation. No candidate receives a
second quantum before every eligible peer receives one.

Race GC continuously with adoption, serving, replacement, drain and release.
Prove adoption/serving never wait on gc.lock, custody releases between quanta,
heartbeat continues, and direct custody/catalog/drain evidence is revalidated
before deletion. Kill at every flag-clear/unlink/root/fsync/cursor boundary;
resume the exact reverse-depth prefix and protect on unexpected name, identity,
symlink, path escape, fork or stale queue entry.

## R24-10 — finite SHA split oracle

Generate the exact seeded B set for every R18 length and record its size/digest.
In one pass per payload capture independent continuation state at every B offset,
then clone each state and finish its immutable suffix. Before execution compute
and assert at most 4,096 completions and at most 96 GiB aggregate suffix
compression; fail generation if either bound is exceeded. Compare all results
to one-shot SHA-256 and assert <64 MiB writable extra RSS and <30 minutes on
recorded hardware. Mutate all eight words, every bit of total count, tail
length/content, and padding boundary. Require failure and independently verify
0/55/56/63/64/65, 1-MiB buffer, 64-MiB checkpoint, final-byte, and 256 seeded
random cases are represented where in range.

## R24-11 — retained recovery, economics, and broader gates

Repeat R23's P0...P6 death matrix, A1/A2 eight-slot abort, A3/A4/all A5/A6
forward-only economics, compatibility, observability and negative taxonomy
tests using v9 types and the single-receipt graph. Preserve full admitted
581,632/696,320 charge after A3, exact A4/A5/A6 transfer, incumbent availability,
and truthful cancellation results.

Then run targeted Swift tests, complete `swift test`, Malibu Xcode tests,
CLI/app bridge, governance, prior-binary compatibility, max-shape measurement,
and the physical prepared-artifact verification/adoption/MLX-open case. Record
commands, selected/executed counts, durations, failures, skips, timeouts, peak
FD/RSS, hardware, and fixture/real-service boundaries. Independent native
GPT-5.6 Sol code, security, and architecture audits over the complete diff must
each report zero Critical, High, and Medium findings.

Acceptance continues to separate implementation, fresh local verification,
physical filesystem/hardware qualification, signed-feed/release evidence,
deployed services, and production qualification. Reservation fixtures cannot
pass the real signed-feed -> preparation -> admission -> MLX -> settlement
journey.
