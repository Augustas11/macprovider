# Build 1 catalog read lifecycle addendum r1

Date: 2026-09-10. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.
Worktree: product-build-1. Review base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Resolves proposed corrections for B1-SEC-M1 and B1-SEC-M2 in
`reviews/security-combined-r2-astra.md`. This is a material SPEC-044 local
projection/read-contract amendment. Independent review of this exact artifact
must return zero Critical/High/Medium before runtime edits. Root owns normative
amendments after approval. Existing transaction-control r4, snapshot-resources
r2, cleanup and signed adoption safeguards remain in force.

## 1. Established defects and required outcome

The actual app `refreshCatalogEconomics` includes `--ctl-socket-path` even for
`--local-activation`; the real parsed `ModelsCatalogEconomicsCommand` requires
that override to be nil before preparing a bound context. Do not weaken the CLI
check. The app must supply its fixed config only on this bound path.

`runCatalogRead` currently expires its UI continuation after ten seconds while
`MalibuModelCLI.run` continues waiting for its child. The weak shared
`ModelCLIProcessCancellation` is neither a request handle nor a single-flight
reservation. `DurableModelDiscovery.discover` performs a complete nil-deadline
hash, and `makeModelCatalogLocalActions` independently performs a second such
hash. Fixing only one call site is insufficient. The fresh projection required
by `reconcileCatalogTransaction` repeats this work after terminal prepare or
evaluate. These are source-established defects, not measured physical-model
throughput claims.

Outcome: quick browsing/recovery enumeration remains bounded and honest; a
selected local artifact can be fully verified through an observable, cancellable,
finite read that can exceed ten seconds. Exactly one app-owned catalog read may
exist until its child exits and is reaped, including timeout/app restart. Partial
hashes, file metadata and historical seals never establish readiness. A complete
fresh verification can satisfy the existing terminal-plus-fresh-projection gate
without immediately starting the same hash again.

## 2. Choice and alternatives

Selected: a quick projection plus optional exact-target verification read. The
quick projection does not read weight file contents. Verification hashes one
signed primary target and shares its request-local inspection between discovery
and action construction. The app offers **Verify local files** for an existing
unverified target, and automatically uses this same read after a succeeded
prepare/evaluate terminal when fresh local readiness is required.

A supervised all-catalog read would fix child leakage with fewer wire changes,
but every refresh would still wait for every installed model, and unrelated slow
models would block recovery of the selected transaction. A larger fixed timer
alone neither exposes useful progress nor fixes duplicate whole-catalog hashing.
A metadata/seal-backed ready cache is rejected: it converts past verification
into current readiness. Resumable persisted partial hashes are deliberately out
of scope. The target read may restart hashing from zero after cancellation; it
never restarts itself automatically in a loop.

## 3. Exact app argv and compatibility

Centralize production argv construction in a non-UI helper
`MalibuCatalogReadArguments.make(mode:requestID:paths:)`. Tests must invoke this
helper; no independently hand-maintained bridge argument array.

Negotiated quick mode produces exactly this option surface (order is stable):

```
models catalog-economics --json --config FIXED_CONFIG --local-activation
  --app-read-request UUID --app-read-mode quick
  --read-lock-fd 199 --read-lifetime-fd 200
```

Verification mode adds to that surface, replacing `quick` with `verify`:

```
--verify-local-model CANONICAL_MODEL_ID --expected-context-sha256 LOWERCASE_SHA256
```

`UUID` is a fresh lowercase canonical UUID identifying only this ephemeral read,
not a transaction UUID or operation generation. Target is the exact canonical
signed model ID from the most recent accepted protocol-2 row; expected context
is that projection's opaque transaction context SHA-256. No arbitrary paths,
socket overrides, provider IDs, model overrides, cache overrides, feed overrides,
coordinator overrides or runtime credential options are added by the app.

Both modes retain the CLI rejection of model/supported-model/socket/coordinator/
provider overrides for bound local activation. Newly introduced app-read mode
also rejects all discovery namespace/cache/origin/skip overrides, including
`--skip-coordinator-status`, before setup or action reservation. Flags with the
wrong combination, invalid UUID/digest, verify without target/context, quick
with target/context, or partial FD options fail nonzero. Existing default
protocol-1 CLI behavior and its documented standalone overrides are unchanged.
Explicit standalone local activation without app-read mode remains a quick
projection; it gains no hidden full-hash work. These unpublished protocol-2
amendments do not introduce projection version 3 merely to preserve this
unmerged intermediate version.

The result-restoration call currently sharing `runCatalogRead` must also move
to this owned read API. Fresh-live-peer `models transaction result UUID --model
TARGET --expected-kind evaluate_model --operation-generation GENERATION --json
--config FIXED_CONFIG` adds `--app-read-request READ_UUID --app-read-mode result
--expected-context-sha256 DIGEST --read-lock-fd 199 --read-lifetime-fd 200`.
Only that read-only subcommand accepts mode `result`; it uses the same early
lifetime/lock validation, ten-second total budget and existing full JSON output.
Root must add the explicit parsed read options to that command, validate its
fresh projection context against the same consumed config before selecting the
journal, and retain exact target/kind/generation guards. No target verification
or heartbeat privilege is added. Offline pending status/cancel/result retains
the existing control r4 launcher and mutually rejects these app-read flags.

## 4. Quick projection and complete verification semantics

Protocol 2 adds one required closed per-row field `local_verification`:

```
{"state":"not_applicable|missing|unverified|verified|invalid|incomplete"}
```

The shown pipe notation denotes six enum values, not a literal wire string.
No paths, hashes of private config, file lists or source locations appear here.
`not_applicable` covers rows outside the signed primary local activation set.
`missing` requires a bounded observation that the exact artifact location does
not exist; a failed/incomplete observation is not absence. `unverified` means an
exact local location exists but no complete hash was performed in this read.
`verified` requires this read's full exact signed artifact/config verification.
`invalid` requires an actual observed validation failure. `incomplete` means a
read/limit/deadline prevented a conclusion. Protocol 1 omits this field and
keeps its current codec/behavior.

For local activation rows, `weights_present_locally=true`, a local `ready`
runtime state and available evaluate/adopt actions require `verified` in this
request. Quick mode emits no `verified` state. Current-serving evidence remains
separate and may still identify the incumbent; the app must not turn that label
into local byte-verification evidence. Existing coordinator admission/pricing
fields keep their own fresh authority rules; local verification grants none.

`unverified`/`incomplete` rows display **Local files need verification**, have
`weights_present_locally=false` (no verified local readiness assertion), and use
new protocol-2 runtime state `verification_required` for noncurrent rows. They
must not say files are missing. Their prepare/evaluate/adopt actions are
unavailable with new closed reason `local_verification_required`. This prevents
an unverified existing artifact from being presented as an overwrite/prepare
shortcut. `invalid` remains blocked with `local_artifact_invalid`; destructive
repair of published corrupt artifacts is outside this correction. `missing`
can expose the already authorized prepare flow. Cleanup recoveries are projected
independently of weight verification and remain separately displayed.

Quick discovery may inspect bounded metadata to distinguish these states, but
must not trust metadata, a successful prior transaction or
`ModelCatalogArtifactSeal` as current verification. A durable row, including an
unverified/invalid/incomplete row, continues to shadow any sibling HF cache row;
a cached metadata-ready row cannot overwrite its failure. For other local rows
inside the signed primary activation set, the same no-current-hash/no-ready
rule applies. Ordinary protocol-1 discovery callers remain conservative under
their existing contracts.

Quick projection setup/reservation remains exactly the previously authorized
private journal setup behavior; this read is not permission to prepare weights,
change config, stop providers, evaluate, adopt, offer or mutate admissions.

## 5. One CLI verification result and final authority/placement checks

CLI introduces `ModelCatalogReadRequest` (mode, read UUID, optional exact target,
expected opaque context, monotonic budget/cancellation/progress callbacks) and
`ModelCatalogLocalInspection` keyed by signed model key plus canonical ID,
revision and expected artifact hash. It carries request-local states and, only
on full success, the canonical inspection and stable placement observation.
It is never persisted or treated as a new trust root.

`ModelsCatalogEconomicsCommand.run(context:)` prepares config/environment/root
once through the existing context loader. Both modes use its same resolved
config for all consumers. Quick setup and finalization keep their approved
single-read order. Verify mode must compare the expected opaque context before
any hash or reservation: use read-only finalization of the existing prepared
root, fail if roots/context changed or are missing, and do not create a new
store to satisfy the expectation. At final emission, revalidate this same
prepared context/root identity; no config reread or environment rebinding.

The command resolves the exact authenticated primary target once, with the
existing supported-model/catalog/feed checks. Verification cannot select a
candidate UUID, sibling revision, arbitrary local path, or all-model wildcard.
Pass its one inspection map into both `BYOMDiscoveryRunner`/durable discovery
and `makeModelCatalogLocalActions`; those projection consumers must not call
`canonicalArtifactHash` themselves. Other command callers may request their
existing verification policy explicitly; no silent readiness weakening.

Full hashing uses the existing canonical hash format and strict relative path
policy. Extend its read API to accept a monotonic budget, cancellation callback,
and measured-byte progress callback. Check before/after each enumeration/open/
read and between 1 MiB chunks. Bound enumeration to the existing snapshot
limit of 10,000 entries and relative paths to 4,096 UTF-8 bytes; config capture
is limited to 8 MiB. Reject arithmetic overflow and duplicate paths. Large
weight files stream without in-memory accumulation. No partial digest is reused.

For this verified projection path hold the exact root/parent placement
descriptors; use no-follow descriptor-relative regular-file opens, reject
symlinks/hardlinks and unsafe placement, compare each opened file's identity,
size/mtime/ctime before and after hashing, and compare the bounded full metadata
snapshot before/after. Before final document construction, recheck root
placement and complete snapshot against those observations. Replacement,
rename, mutation, added/deleted files or changed config invalidates the result.
Do not claim protection against a malicious same-UID actor able to rewrite
process memory; retain the existing same-UID boundary. This check is evidence
for the observation window, not a guarantee that bytes can never change after
emission. Prepare/evaluate/adopt continue their own execution-time validation.

After hashing, reload current feed/admission/runtime/hardware observations for
final projection generation, using the same captured config. Resolve the target
again and require the same signed key/canonical ID/revision/hash and relevant
feed identity; changed/expired authority yields an incomplete/unavailable result,
never a ready result from the old selection. This intentional final authority
refresh is not a second config load or second artifact hash. Generate timestamps,
sequence and context at final publication, not at read start. Actions/recoveries
are reserved/loaded only from this final current authority and exact root.

## 6. Bounded wire progress

Quick mode emits the existing one-document JSON projection on stdout. Verify
mode emits closed JSONL `model_catalog_read_event.v1` objects with required keys:

```
schema, request_id, event_sequence, target_model_id, model_key,
kind, bytes_completed, error_code, projection
```

`schema` is exactly `model_catalog_read_event.v1`; request and target/key are
exactly bound; sequence starts at 1 and strictly increases. Kinds are
`accepted`, `progress`, `completed`, `failed`. `bytes_completed` is a nonnegative
UInt64 count of artifact bytes actually hashed (zero before hashing, monotonic;
no percent/total guessed from model estimates). `error_code` is null except
failed, when it is one of `verification_incomplete`, `artifact_invalid`,
`authority_changed`, `context_changed`, `read_limit_exceeded`.
`projection` is null except completed, where it is the complete final validated
protocol-2 projection containing the exact target's verified state. Exactly one
terminal event is permitted. Duplicate/unknown keys, unknown enums, sequence or
target mismatch, a ready result without complete final projection, trailing data
or nonzero exit after completed fail the app read. Process exit zero and complete
EOF are required before accepting the terminal projection. A failed read does
not overwrite current rows with false missing/ready information.

CLI emits accepted after selector/context checks and progress heartbeats at
most five seconds apart from an independent timer; bytes only advance when the
hash loop reports actual reads. Heartbeat is liveness, not successful I/O or
readiness. The app says **Verifying local files**, shows measured bytes, and
exposes **Stop verification**. Delay beyond 30 seconds is explicitly disclosed.
No raw filesystem paths, credential errors or private context details are copied
into progress. CLI stderr remains bounded diagnostics, not authorization.

Quick has ten seconds total. Verify has 1,800 seconds total from request
reservation including executable validation/config/setup/hash/finalization,
requires its first accepted event within ten seconds, fails after 15 seconds
without a well-formed heartbeat, and has a 60-second no-byte-advance limit once
hashing starts. Bounded nonhash phases share the initial/final ten-second phase
limits; the final phase does not reset the 1,800-second total budget. These are
finite engineering limits, not a claim that every model/disk finishes in time.
A model taking 20 or 120 seconds can finish one verification without a succession
of ten-second restarts. A stalled or excessively slow model remains incomplete,
retains pending custody, and offers an explicit retry after child exit.

Output limits: 8 MiB total stdout, 64 KiB stderr, 1 MiB per JSONL line (including
final projection), 4,096 events. Validate projection size before encoding the
completed line; oversized output fails closed. A bounded rate limiter prevents
per-chunk callback floods; bytes can be coalesced, never fabricated. Five-second
heartbeats over 1,800 seconds fit the event bound.

## 7. App read ownership, cancellation and restart

Add a dedicated `MalibuCatalogReadRunner` and typed `CatalogReadHandle`, rather
than calling generic `run` and trying to cancel its weak current process. It
owns one reservation nonce, exact directly spawned PID/process object, pipes,
read deadline, output/parser state and completion latch. Both quick projection
and fresh-peer result restoration use this owned read surface. Verification
uses the same single-flight slot. Calls while occupied return busy; do not queue
unbounded replacement tasks. A result can be delivered once only, and callbacks
must match the still-current nonce. Discard late bytes/results after cancellation
or expiry even when the child eventually exits zero.

Reserve before executable resolution. Resolve/validate the existing managed
live-peer executable off MainActor and check nonce/expiry immediately before
normal spawn. Read-only helpers use the existing trusted installed executable
and adjacent resources, not mutation-owner snapshots. There is no arbitrary
saved executable path, nil-peer mutation fallback or signature bypass. If
preflight blocks after expiry, retain its worker/slot until return and forbid a
late spawn. Do not occupy the transaction-control resource worker for a
30-minute read; controls retain their independent ten-second custody and lease.

The read runner uses a separate fixed owner-private
`ModelTransactions/catalog-read.lock` (0600, parent 0700) for cross-app-instance
single flight. Hold its flock throughout preflight and child lifetime; duplicate
the same open description to child FD 199, and keep it until exact child exit.
FD 200 is the read end of an app-owned lifetime pipe. Child descriptors are
installed with normal spawn file actions (no suspended-child/guardian chain);
only intended copies have CLOEXEC cleared. Never reuse `control.lock` for this
read or hold the mutation-control lease across verification.

CLI app-read option validation installs a read-only lifetime monitor before
config/resources/hash work. It verifies FD 199 is the expected fixed lock inode,
owner/mode and locked open description (independent LOCK_EX|NB cannot succeed),
and FD 200 is a read-only pipe. On pipe EOF/parent exit or its own absolute budget
expiry, the monitor exits this read helper. This monitor does not signal any
mutation owner, candidate, provider or saved PID. It closes/exits only its own
process. Missing/invalid FDs fail before discovery/setup. The app also closes
its lifetime write end on abandonment and enforces its exact child termination
independently. Thus an app crash during hash cannot leave an unbounded orphan;
a replacement app sees the retained read lease until the old child exits.

On timeout, explicit stop or task cancellation: revoke nonce, close lifetime
write end, send TERM only to this unreaped direct child, then KILL after one
second if it remains alive; observe exit/reap on the owning worker. Do not
release the slot/lock merely because the UI continuation has reported timeout.
The UI can promptly show **Verification stopped; waiting for the reader to
exit** while retaining the busy state. Pathological uninterruptible kernel I/O
may delay reap; do not claim termination or start a replacement during that
condition. No process-group kill and no signaling a PID after wait/reap. Bounded
nonblocking pipe reads must not await EOF forever from a stray inherited writer;
close them on completion/limit. No child process is spawned by this read CLI.

## 8. Pending completion and UI recovery

A succeeded prepare/evaluate terminal still cannot clear pending state by
itself. Quick projection can restore catalog/recovery context without hashing.
Then invoke exact-target verify with that fresh context. A completed verified
projection is itself the required fresh projection; consume it through the same
strict codec/freshness gate and do not immediately issue another quick projection
that discards its readiness. Evaluate result retrieval retains exact
UUID/kind/generation and full existing recommendation validation. Only after
verified terminal plus final fresh verified projection (and evaluation document
where applicable) may the existing durable pending clear run.

Cancellation/failure/cleanup terminal recovery does not require a successful
weight hash unless an existing contract specifically requires ready bytes; it
uses a fresh quick projection and the already verified terminal. This avoids
requiring an absent/corrupt artifact to become ready in order to acknowledge a
cancelled preparation or completed staging cleanup. A succeeded prepare/evaluate
with incomplete verification remains explicitly pending with **Retry local
verification**; never report transaction failure solely because the read timed
out, and never rerun the mutation owner. App restart reloads pending custody and
queries exact status first, then repeats this read flow. It does not resurrect
partial hashes or infer completion from a persisted read UUID.

A later quick refresh may honestly return unverified state. The app may retain
only the normal unexpired accepted verified projection until replacement/expiry,
never merge stale verified bits into a newer projection. Subsequent mutation
execution always revalidates its own signed inputs and artifacts.

## 9. Ownership and implementation boundaries after approval

App owner: production argv helper, strict event/row codec, dedicated read
runner/handle and separate private read lock, progress/stop/incomplete UI,
reconciliation wiring, Xcode unit and real child lifecycle tests. No generic
mutation cancellation changes. Root CLI owner: parsed app-read options and
pre-config lifetime monitor, context loader integration, request/budget and
inspection map orchestration, final authority refresh and SPEC-001/SPEC-044
amendments. Coordinate bounded edits to `ModelsSubcommand.swift` explicitly.
Root also owns the bounded fresh-peer result-read options/lifetime integration.
CLI discovery/action owner assigned by root: `DurableModelDiscovery`,
`BYOMDiscoveryRunner` projection policy, canonical verifier callbacks/descriptor
validation, and `makeModelCatalogLocalActions` consuming inspection results.
Do not edit retention reservation/archive scheduling methods as part of this
fix. Bridge owner: actual app argv artifact -> real parsed CLI composition tests.
No dependencies, credentials, production deployment or signed release changes.

## 10. Required validation before completion

| ID | Required evidence |
|---|---|
| CR-01 | Xcode drives actual `refreshCatalogEconomics`/verification/result restoration through an argv-capturing owned-runner seam; writes the exact array received at the spawn boundary as a JSON artifact. This tests the helper's real caller, not merely the helper in isolation. A compiled CLI fixture entry reads those unchanged bytes, installs genuine fixture lock/lifetime FDs, and uses real `parseAsRoot`, then `run(context:)` with isolated signed fixture dependencies. Assert bound digest, clean-install prepare action, existing-unverified row, exact verified evaluate/adopt eligibility and separate cleanup recovery. No separately authored equivalent argv. |
| CR-02 | Feed/context-valid baseline versus same actual argv plus forbidden socket/model/provider/coordinator/cache override; mismatch fails before setup/hash/reservation. Verify wrong target/key, context/config inode/bytes/root/environment namespace, invalid UUID and malformed FD mode rejected. Protocol-1 parsed CLI regression remains unchanged. |
| CR-03 | Count actual verifier reads: quick reads zero weight bytes; verified target hashes once despite discovery and action builder consumers; unrelated installed model reads zero weight bytes. Missing/unverified/incomplete/invalid/verified states and cache-shadow precedence cannot promote metadata to ready. |
| CR-04 | Real owned helper process pauses its actual read through an explicit compiled test seam beyond ten seconds. Quick times out, exact child exits/reaps, repeated refresh remains busy until exit, and late valid JSON cannot repopulate rows. TERM-ignoring helper is KILLed after grace; verify waitpid/exit and lock release. No shell or subprocess family fixture. |
| CR-05 | Verify helper makes measured byte progress for more than ten seconds (at least 20 seconds) and completes once with final verified projection. Assert heartbeat <=5s, no duplicate scan, completion accepted and no ten-second restart. Separately block bytes >60s and suppress heartbeats >15s; failure retains slot until reap and never claims ready. Budget tests may inject monotonic clock, but one real wall-clock slow-read case is mandatory. |
| CR-06 | Kill only the test app/runner host while child is hashing; inherited pipe EOF causes child exit, a second host cannot acquire read lock/start before exit, then succeeds. Negative wrong-lock inode/permissions/read-only-pipe tests. Confirm transaction owner/control helper is untouched and can perform status/cancel during long catalog verification. |
| CR-07 | Mutation at file open/read/finalization; root rename, symlink/hardlink, same-size content mutation with changed ctime, config replacement and signed authority rotation/expiry invalidate final verified projection. Test before/after snapshot plus descriptor placement; unchanged fixtures succeed. A historical artifact seal alone never succeeds. |
| CR-08 | Truncated/malformed/duplicate-key/oversized/out-of-order/wrong-request/wrong-target JSONL; completed followed by nonzero exit/trailing event; fake byte progress, stalled progress, final projection overflow. App returns incomplete/unavailable, bounded memory, no late callbacks or action permission. |
| CR-09 | Actual parsed prepare/evaluate fixture terminal followed by actual target verification read >10s and fresh projection, then durable clear. Interrupted verification preserves exact pending; restart/status/retry completes once. Cancelled prepare and cleanup terminal reconcile with quick projection without hashing absent/corrupt weights. No automatic mutation rerun. |
| CR-10 | Real macOS Xcode targeted and full app suites; CLI targeted command/discovery/verifier tests and broader suite; final combined code/security/architecture review against actual landing diff, zero C/H/M. Record argv artifact, source manifest, commands, exit status and log hashes. |

Fixtures prove argv/parser composition, resource ownership, hash/readiness logic
and recovery scheduling. They cannot qualify production-signed app/CLI identity,
real model performance, MLX model recommendation, incumbent drain/restart, remote
admission or settled credit. Existing zero valid signing identities remains an
explicit qualification blocker. A signed full-model hardware journey, including
verification elapsed/bytes/storage conditions and the complete pending recovery
path, is separate required release evidence. The previously demonstrated tiny
MLX arithmetic/resource load is not substituted for that journey. If a supported
real model exceeds the finite verification limits, report it incomplete and
reopen the design/qualification gate rather than silently lengthening deadlines,
skipping full verification, or caching readiness.
