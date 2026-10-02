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

An admission policy names the tuple's `qualified_slots`,
`max_native_active_rows` (the bound), and `maximum_prompt_tokens` (the signed
SPEC-023-R024 `max_prompt_tokens`, at least 1536), and contains exactly the
SPEC-048 MTP-15 mandatory matrix: `slots` 1..bound, `prompt_tokens` 1536 and
4096 at or below the cap plus the cap itself, `max_tokens` 128 and 512, and
`gated_cells` at slot counts bound + 1 and `qualified_slots` (prompt 1536,
output 512); `sustained_cell_id` is `s<qualified_slots>-p1536-o512`. The bench
refuses, and the analyzer fails closed on, any other matrix; only exploratory
pilots may run less.
Cells at or below `max_native_active_rows` are native-eligible and gate the
native improvement; cells above it are gated and must prove every admission
honored the bound (`effective_paths[].other_active_rows`, header
`run_metrics_version` 3) and stay non-inferior to ordinary at the frozen
`gated_*` thresholds. Gated cells also need a staggered `arrival_interval_ms`
> 0 and must show the in-flight depth-zero hold: native runs carry the
scheduler's `gated_depth_zero_rounds`, `gated_hold_episodes`,
`gated_depth_restorations`, `gated_held_finishes_clean`, and
`gated_held_unresolved` (`run_metrics_version` 4).

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

Run the matrix and the sustained window as separate phases (for example in
separate lab windows); the sustained phase appends to the same `--out`,
reuses the sustained cell's matrix records, and never re-runs them:

```bash
MACPROVIDER_NATIVE_MTP_E2E=1 \
.build/release/macprovider-cli native-mtp-bench \
  --root /path/to/frozen-fixture \
  --policy /path/to/frozen-policy.json \
  --out /path/to/native-mtp-r015.jsonl \
  --only-cell s8-p1536-o512 --phase matrix \
  --provider-commit <40-hex-provider-commit>
MACPROVIDER_NATIVE_MTP_E2E=1 \
.build/release/macprovider-cli native-mtp-bench \
  --root /path/to/frozen-fixture \
  --policy /path/to/frozen-policy.json \
  --out /path/to/native-mtp-r015.jsonl \
  --phase sustained \
  --provider-commit <40-hex-provider-commit>
```

Resume one cell:

```bash
MACPROVIDER_NATIVE_MTP_E2E=1 \
.build/release/macprovider-cli native-mtp-bench \
  --root /path/to/frozen-fixture \
  --policy /path/to/frozen-policy.json \
  --out /path/to/native-mtp-r015.jsonl \
  --only-cell s1-p4096-o512 \
  --provider-commit <40-hex-provider-commit>
```

Resume uses the existing header, refuses any policy/model/artifact/commit
mismatch, skips already complete paired matrix blocks, and continues the
sustained window from its recorded elapsed duration.

Analyze:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/native_mtp_r015_analyze.py \
  /path/to/native-mtp-r015.jsonl \
  /path/to/frozen-policy.json > analysis.json
PYTHONDONTWRITEBYTECODE=1 python3 scripts/native_mtp_r015_analyze.py \
  /path/to/native-mtp-r015.jsonl \
  /path/to/frozen-policy.json --format markdown > analysis.md
```

The default output is one JSON document. The throughput gate reads decode
throughput (`aggregate_decode_tps`: tokens after each request's first, over
the run's earliest first token to latest completion); TTFT is gated
separately, and prefill-inclusive throughput is reported under
`informational_metrics.end_to_end_throughput`. Records from benches before
header `run_metrics_version` 2 have decode throughput derived from
per-request throughput, TTFT, and tokens (`decode_tps_sources`).

Plain release builds must not include `MACPROVIDER_LAB_HARNESS`, and release,
signing, and CI scripts must not pass that flag.
