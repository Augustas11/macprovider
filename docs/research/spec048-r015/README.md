# SPEC-048 R015 Native MTP Bench

This is the lab-only throughput gate for the native MTP campaign. Freeze the
policy JSON, including the exact hardware, OS/toolchain, provider/MLX revisions,
methodology, model, target, MTP, and tokenizer digests, before any measured run.
The runner records the policy SHA-256 in the header and every run record, and
refuses to run if the frozen environment or digests do not match observation.

Create the run-specific policy from the template, replace every zero digest and
review every field, then freeze and record its byte-exact hash before starting
the first warmup or measured request:

```bash
cp docs/research/spec048-r015/policy-template.json /path/to/frozen-policy.json
# Replace every REPLACE_/zero placeholder. Capture the exact Studio values with:
sysctl -n hw.model machdep.cpu.brand_string hw.memsize kern.osversion
xcodebuild -version
xcrun swift --version
# Set ram_gb to rounded GiB and provider_commit to the exact 40-hex revision.
shasum -a 256 /path/to/frozen-policy.json
chmod a-w /path/to/frozen-policy.json
```

Do not edit or regenerate the policy after measurement begins. Any change,
including whitespace, creates a different preregistration and requires a new
output file and a fresh run.

Build on the Mac Studio:

```bash
cd phase3-binary
swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS
```

Run the matrix and sustained cell:

```bash
MACPROVIDER_NATIVE_MTP_E2E=1 \
.build/release/macprovider-cli native-mtp-bench \
  --root /path/to/frozen-fixture \
  --model-id mlx-community/Qwen3.5-9B-4bit \
  --policy /path/to/frozen-policy.json \
  --out /path/to/native-mtp-r015.jsonl \
  --provider-commit <40-hex-provider-commit>
```

Resume one cell:

```bash
MACPROVIDER_NATIVE_MTP_E2E=1 \
.build/release/macprovider-cli native-mtp-bench \
  --root /path/to/frozen-fixture \
  --policy /path/to/frozen-policy.json \
  --out /path/to/native-mtp-r015.jsonl \
  --only-cell s8-p4096-o512 \
  --provider-commit <40-hex-provider-commit>
```

Resume uses the existing header, refuses any policy/model/artifact/commit
mismatch, skips already complete paired matrix blocks, and continues the
sustained window from its recorded elapsed duration.

Analyze:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/native_mtp_r015_analyze.py \
  /path/to/native-mtp-r015.jsonl \
  /path/to/frozen-policy.json
```

Plain release builds must not include `MACPROVIDER_LAB_HARNESS`, and release,
signing, and CI scripts must not pass that flag.

## Round overhead findings

## Measured bottleneck

The depth-1 Qwen 3.5/3.6 MTP path does not perform its expensive model call in
the usual proposal branch. `Qwen35MTPDraftModel.commitDrafterState` advances the
MTP cache and computes the next seed token; the following `draftBlock` normally
returns that cached seed without a model forward. The previous bridge therefore
paid one serialized MTP forward per committed row during finalize, plus one
`MTPDrafterContainer.perform` and one `eval` boundary per row in both proposal
and finalize.

The MacProvider-side change in this worktree removes work that does not require
a dependency API change:

- proposal uses one drafter-container hop for the complete scheduler round and
  one combined evaluation boundary;
- finalize uses one drafter-container hop and one combined drafter-cache
  evaluation boundary for all committed rows; and
- paged-attention target commits return their dirty arrays and evaluate all
  rows/layers together instead of synchronizing once per row and layer.

These changes preserve the existing per-request state maps, rollback of
tentative drafter writes, and SPEC-048-R006 target transactions. They remove
host/container and MLX synchronization overhead, but the pinned fork still
executes the Qwen MTP model body once per row because its public stateful API
has scalar cache positions.

## Required fork work

The pinned `c4bc3461673e9f035c5f11bf41dda120d4baee1d` API is insufficient for a
single Qwen drafter model forward across arbitrary scheduler rows. Although
`draftMTPTokenBlock` is batch-shaped, `MTPDrafterState` owns row-local
`KVCacheSimple` instances, `Qwen35MTPPredictor` accepts one scalar
`positionOffset`, and commit rows are ragged (one token after rejection, two
after accepting the depth-1 proposal). A correct fork implementation must pack
those caches with per-row live lengths, use batch RoPE offsets and a padding
mask, scatter only each row's valid appended state, and return row-local states.
It must also defer the commit advance into the next round's packed proposal so
terminal rows do not perform an unused MTP forward. The MTP computation cannot
be eliminated for continuing rows; it is moved out of finalize and performed
once for the packed batch.

[`fork-batched-drafter.diff`](fork-batched-drafter.diff) records the dependency
surface, a concrete ragged-cache Qwen35 packed implementation, and the
independently safe recurrent-commit change. It is deliberately not applied to
the SwiftPM checkout. The provider-side integration is present behind
`MACPROVIDER_MLX_PACKED_DRAFTER`: it calls `advanceAndProposePacked` once during
the next proposal round for all continuing rows. Finalize records only the
accepted row-local transition, so terminal rows perform no unused drafter
forward. A reviewed successor to `c4bc3461` must land with
fork-level exactness tests before enabling that compilation condition. Until
then, the required unchanged pin compiles the exact scalar compatibility path,
which still removes its per-row actor and evaluation fences.

## Packed-verify overhead

Compared with ordinary shared decode, packed verification additionally emits
target hidden/shared-KV continuation state, checkpoints recurrent state,
constructs row transactions, slices every row back out, and resolves those
transactions on the host. Concrete redundant work and estimated M3 Ultra cost
per scheduler round are:

| Item | Location | Estimate | Disposition |
|---|---|---:|---|
| Per-row/per-layer paged commit `eval` fences | `PagedKVRuntimeBridge.swift`, `PendingMTPResolution.commit` | 2–8 ms at 8 rows | Fixed locally with one combined eval. |
| Per-row drafter container hops and cache eval fences | proposal/finalize bridge paths | 1–3 ms at 2 rows; 5–12 ms at 8 rows | Fixed locally; model bodies remain serial. |
| Per-row recurrent `eval(selected)` | fork `MTPPackedTargetVerification.swift` | 3–10 ms at 8 rows | Fork diff publishes lazy state; the next packed cache consumer evaluates it with its graph. |
| Destructive recurrent checkpoint restore plus base/final slices | fork `rowTransactions()` | 1–4 ms at 8 rows | Requires fork-owned snapshot handles or deferred slicing. |
| Repacking recurrent row states every verify | fork `packRows()` | 1–3 ms at 8 rows | Requires a reusable packed state carrier in the fork. |
| Continuation hidden/shared-KV validation, host offset reads, and per-row slicing | fork continuation extraction | 1–5 ms at 8 rows, context dependent | Packed drafter should consume packed continuation state directly. |
| Extra hidden/shared-KV emission and recurrent checkpoint split inside target forward | Qwen target/fork facade | remainder of the measured 9.4 ms two-row verify gap | Required today; profile emit/checkpoint-off variants before changing. |

The two-row same-token-count observation bounds the all-in verify premium:
ordinary four-slot decode is 18.4 ms for four tokens, while two-row packed
verify is 27.8 ms for four tokens, a measured 9.4 ms (about 50%) excess. The
individual estimates above are attribution ranges, not independently measured
totals, and overlap where one synchronization realizes multiple lazy arrays.

At eight rows, batching the actual commit advance should turn the measured
31.5 ms of serialized commit work into roughly one 6–10 ms packed MTP forward
plus a single state scatter/eval, saving about 20–25 ms per round. At two rows,
the corresponding estimate is a reduction from 11.6 ms to roughly 5–7 ms,
saving about 5–7 ms. Removing the remaining proposal container/eval loop should
save most of the measured 2.2 ms (two rows) and 8.5 ms (eight rows) host-side
proposal phase, while leaving token extraction and dictionary bookkeeping.
