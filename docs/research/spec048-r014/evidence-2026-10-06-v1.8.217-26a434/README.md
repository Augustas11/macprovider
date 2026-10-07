# SPEC-048-R014 rehearsal on published CLI v1.8.217 (Studio build 26A434)

This directory rehearses the SPEC-048-R014 native-MTP enablement gate against
the already-signed, published CLI `v1.8.217`. The goal is for the next CLI
cut to only re-confirm the gate and find nothing new.

This is rehearsal evidence only. Nothing in it is signed, `CONFORMANCE.json`
is unchanged, and nothing is enabled. Native MTP stays default-off.

Spec reference: `SPEC-048` 0.1.25 (`origin/mtp/step-overhead`), MTP-14.

## Runner

`scripts/native_mtp_r014_journey.py` runs on the Mac Studio lab host,
noninteractively, under the lab window lock. It uses three helper modules:
`native_mtp_r014_isolated.py`, `native_mtp_r014_release.py`, and
`native_mtp_r014_summary.py`.

```bash
python3 native_mtp_r014_journey.py run --config run-config.json \
  --phases identity,live,records,revocation,lab-hw,signed-serve,lab-neg,lab-journey,isolated,release-assets,updater,live
python3 native_mtp_r014_journey.py summarize --evidence <evidence-dir>
```

The runner writes:

- one `checks/<item>.json` per R014 item;
- `records/` for structured evidence;
- `raw/` for logs;
- `result.json` and `result.md` for the summary.

Verdicts are computed from the records, so you can rerun a subset of phases.
`run-config.json` is a sanitized copy of the configuration used here. Private host roots are replaced with logical placeholders; it is not directly executable.

### Two binaries, by necessity

1. **The signed release**, `macprovider-cli` 1.8.217 (sha256 `a6ea51d7…`,
   cdhash `df44bcf4…`, Developer ID `YF7XNRJUG4`), from `~/cli217`. The sha
   was verified before use.
2. **A lab build of the exact release commit** `71f22d36c`, built on the
   Studio with `-DMACPROVIDER_LAB_HARNESS` (sha256 `3e2135b3…`). This is
   needed because the signed binary doesn't contain the hidden
   `native-mtp-journey-e2e`, `native-mtp-hardware-e2e`, or `native-mtp-bench`
   commands. All three are compiled out of release builds
   (`NativeMTPJourneyE2ECommand.swift:9`, `MacProviderCLI.swift:59-63`).
   `strings` finds zero occurrences in the signed binary, and invoking the
   command falls through to `serve` help.

`identity.json` records both binaries, the host, and the metallib.

### Isolation

- **Lab lock.** `~/.lab-window.lock` was held from 2026-10-06T10:31:53Z to
  11:33:53Z (`lab-lock.json`). No foreign lock was found.
- **Ports.** Every loopback port is in the 193xx block; the runner refuses
  live ports.
- **No join.** Every signed `serve` ran `--no-join` with a private
  `CFFIXED_USER_HOME`, lifecycle root, control socket, and TMPDIR. The one
  exception is the isolated-coordinator phase: it joined a coordinator and
  gateway built from the release source on 127.0.0.1, using SQLite, with
  settlement observe and the job off.
- **Clones, not the live store.** Model snapshots and fixtures were
  APFS-cloned into the work directory. The live model store and the shared
  `q36-a3b-cat` fixture were only read.
- **Updater sandbox.** The updater phase ran the previous release under
  `sandbox-exec`. The sandbox denied every `launchctl` exec and every write to
  the live install, config, LaunchAgents, pools, and `/Applications`.
- **Contact with production.** Nothing touched the live provider, the
  `:18120`/`:18130` pools, `<operator-home>/malibu-m1-pool`, Pearl, or any live
  config. The only contacts with `coordinator.malibu.tech` were read-only
  public GETs of the native-MTP revocation feed: one by the runner, and one
  by the released serve path itself. The latter is hard-coded and has no
  override.
- **Live provider restart (not caused by this run).** The live provider
  restarted at about 10:44Z, outside this run. Its watchdog log shows failed
  `/v1/health` checks from 09:30Z, before the lock was taken. The runner
  never signals or executes a running provider binary. It reads versions from
  the signed compatibility set.

## Result

See `result.md` for the full table.

Counts: 9 PASS, 11 FAIL, 2 not applicable, and R015 recorded (not re-run).

| R014 item | Verdict | Evidence |
| --- | --- | --- |
| 1 conformance of R001..R013/R015/R016 + supporting | FAIL (0/21 conformant, all `pending`; operator gate) | `checks/item1-conformance.json` |
| 1 tuple absent from emergency-revocation feed | FAIL: no feed is published (HTTP 404 for v5 and v4 at the production origin) | `records/revocation-feed-probe.json` |
| 1 sidecar generation + tuple-sha binding | FAIL: the lab sidecar is admitted by the production serve-path loader and its tuple sha recomputes in `scripts/native_mtp_admission_sidecar.py`, but no sidecar can be bound to the release (see below) | `records/lab-sidecar-identity.json`, `records/production-generator-rehearsal.json`, `delivery-path.md` |
| 2 upstream dependency (R003) | PASS: the release pins `b181102984a4`, and the R003 review closed 2026-10-05 | `checks/item2-upstream-dependency.json` |
| 3 capability/manifest negatives | PASS, 21/21 (see below) | `records/lab-manifest-negatives.json`, `records/signed-serve.json` |
| 3 exact greedy parity | PASS (step-04) | `records/lab-journey-result.json` |
| 3 cache/state rollback | PASS (step-05) | same |
| 3 termination | PASS (step-06, step-09) | same |
| 3 mixed-row | **FAIL: runtime finding below** | same, plus `diag/` |
| 3 capacity | PASS (step-07/08 load-gate, slot, and prompt-cap checks) | same |
| 3 fairness | PASS by proxy: R015 gated-cell p95 TTFT UB is +2.8% at s2 and +1.2% at s8, against the 10% bound. The release harness has no dedicated ready-to-decode-wait fixture. | `checks/item3-fairness.json` |
| 3 accounting | FAIL: usage and terminal parity holds for native rows (lab), but receipt and billing for native rows can't be exercised because no release admits the tuple | `checks/item3-accounting.json` |
| 4 MXFP8 | not applicable (`mlx_affine` 4-bit) | |
| 5 FR-CB15/Gate A5 + FR-PKV13 | FAIL: 217 attaches paged KV and batches the tuple to depth 8, but the release's signed CB policy has `entries: []`, there is no FR-CB15/FR-PKV13 record for `qwen3.6-35b-a3b`, and Gate A5 is NOT GREEN | `records/cb15-a5-pkv13.json` |
| 5 R015 | RECORDED, FAIL: one-slot decode lower bound +10.0% to +13.6% against the +15% gate (10-06, policy `2c8a2344…`); fix is draft PR #1862 | `checks/item5-r015.json` |
| 6 signed serving journey | FAIL: none exists; the harness covers 6 of 15 steps | `checks/item6-serving-journey.json` |
| 7 three-lane audit | not applicable to this rehearsal | |
| 8 isolated loopback, release candidate | PASS: default-off, R010 status object present, ordinary stream and non-stream, 8-way batching | `records/signed-serve.json` |
| 8 native admission e2e via isolated coordinator | FAIL: real buyer requests are served through the gateway (ordinary), but the serve path rejects `revocation_state_unavailable` and no tuple offer is sent | `records/isolated-coordinator.json` |
| 8 config-enable, then disable | FAIL on enable (the coordinator loads the signed canary bank, but the provider never offers a tuple); disable falls back to ordinary and every request returns 200 | same |
| 8 Malibu.app vs tarball byte identity | PASS: both embedded CLIs are `a6ea51d7…`, signed `provider_code_identity` matches, checksums match, `verify-malibu-release-artifacts.sh` passes | `records/release-asset-identity.json` |
| 8 updater 1.8.207 → 1.8.217 | FAIL: rollout state (see below) | `records/updater-path.json` |
| 9 no unreleased binary on the live coordinator | FAIL: rollout state (see below) | `live-binaries.json` |

### Item 3 capability negatives in detail

The 21 sub-checks combine two sources:

- **Seven lab manifest mutations, each rejected before load on hardware.**
  The mutations are a duplicate tensor, an extra `mtp.*` tensor, a hidden
  weight file, a symlinked weight, wrong quantization bits, a missing weight
  file, and an oversized header.
- **Signed-release serve-path rejections, with ordinary decode still
  serving.** The reasons were `sidecar_missing` (no sidecar), and
  `revocation_state_unavailable` for both the foreign-signer sidecar and the
  tampered sidecar next to a cloned bundle.

## Runtime finding: mixed-row parity (item 3)

`native-mtp-journey-e2e` step-07/08 fails on the 217 source. Rows 0-3 of the
8-row batch differ from the ordinary batched oracle. Row 0 is native and
load-gated; rows 1-3 are ordinary, two downgraded and one with a conversation
key. The ordinary control batch reproduces itself.

The failure is deterministic. It repeated identically in two more runs: at 8
slots (`diag/journey-diag-1.json`) and at 4 slots, where all four rows differ
(`diag/journey-diag-s4.json`). The first divergence falls 40-100 tokens into
generation.

**Root cause.** The fault is in `PagedKVRuntimeBridge.swift:832-848`
(`canSharePrefillForward`), specifically `:836-838`. A prefill group that
contains any native-MTP prompt-prefill row is never given the shared batched
prefill forward. Every row of that group falls back to the serial
per-row prefill at `:719-760`.

The ordinary runtime prefills the same equal-length co-admitted rows in one
shared `[B, L]` forward, which is not bit-equal to serial `[1, L]` prefill.
So:

- the native row and its co-admitted ordinary peers start decode from
  slightly different KV and recurrent state;
- greedy argmax flips tens of tokens later;
- rows admitted in a later prefill group (rows 4-7) match exactly.

**Confirmation.** A lab-only diagnostic build changed only the journey
harness: it gave each row a different prompt length, so neither runtime can
share the prefill forward. With that change, all 8 rows matched and every
executed journey step passed (`diag/journey-diag-unequal.json`, exit 0;
patch in `diag/diag-patch-full.diff`, binary sha in
`diag/diag-binary-sha256.txt`). The patch is not committed.

**Impact.** Enabling native MTP changes the bytes that *ordinary* requests
receive whenever they are co-admitted in one prefill group with a native
request. That violates the MTP-7 requirement that the mixed-load fixture
"match the ordinary batched oracle" and the R005 multi-row oracle.

**Prior misdiagnosis.** The 2026-10-02 journey run attributed the same
failure (`journey-hardware-result.json`, rows 3 and 5) to arrival timing.
The deterministic-composition control rules timing out.

**Still present.** The guard is unchanged on `origin/main`
(`PagedKVRuntimeBridge.swift:849`) and on `origin/mtp/step-overhead`.

## Rollout-state findings (not runtime bugs)

- **Updater.** The 1.8.207 updater truthfully reports "Already up to date".
  The newest signed discovery transport, `release-discovery-v1-2393341797793794`
  (issued 2026-10-06T02:03:59Z), still targets
  `v1.8.207@d98b74a6…`, and the coordinator still recommends 1.8.207.
  1.8.217 is GitHub "Latest", but the previous stable won't be offered it
  until the post-publication rollout publishes its transport.
- **Item 9.** Two `malibu-m1-pool` processes run CLI 1.8.219 (sha
  `c66be23c…`, Developer ID signed, staged by #1865, not a published release)
  against `wss://coordinator.malibu.tech`. The live provider and
  `malibu-1816-native` run the published 1.8.217 bytes. R014.9 requires no
  unreleased binary on the live coordinator at enablement time.

## Sidecar delivery (the main open question)

See `delivery-path.md`. In short: v1.8.217 has no delivery path for a
production admission sidecar.

- Nothing writes `native-mtp-admission.json`, and no release or catalog
  member carries it.
- The release serve path accepts only a static-feed-key (v5) signature that
  binds the release's CDHash and source commit.
- It also requires a revocation feed, which the production coordinator does
  not serve.

The only committed tuple input (2026-10-02) still carries placeholder
evidence digests. It also binds the superseded runtime `ef4ff856` and policy
`30934c07`, and the generator refuses it.
