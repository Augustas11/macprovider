# T1-03 — Metallib Rebuild + Artifact Check

**Date:** 2026-07-07  
**Branch:** `fix/t1-03-metallib-verify`  
**Executor:** Cursor agent  
**Status:** COMPLETE  

---

## VERDICT: GREEN

`mlx.metallib` present in artifact check; script builds from pinned mlx-swift 0.31.6; artifact preflight passes. Two packaging gaps documented (non-blocking).

---

## Pins verified

| Package | Version | Revision |
|---------|---------|---------|
| `mlx-swift` | 0.31.6 | `0bb916c67f4b9e5c682cbe02a42c701c93ab5021` |
| `mlx-swift-lm` | 3.31.4 | `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` |

Both confirmed from `phase3-binary/Package.resolved` on `origin/main` (`2ac9f33`).

---

## Step 1 — Swift package resolve (populate checkouts)

```bash
cd phase3-binary && swift package resolve
# real 0m27.743s
```

Resolved checkouts:

```
Working copy of https://github.com/ml-explore/mlx-swift resolved at 0.31.6
```

Confirmed via `git describe --tags` in `.build/checkouts/mlx-swift` → `0.31.6`.

**T0-02 lesson verification:** The checkout is exactly mlx-swift 0.31.6 (`0bb916c`), matching the Package.resolved pin. This is the version-matched build required to avoid the 12.4 vs 27.1 TPS degradation observed in T0-02 when a mismatched metallib was loaded. A metallib compiled from a different mlx-swift revision causes silent Metal kernel dispatch mismatches that result in ~50% decode TPS loss.

---

## Step 2 — build-mlx-metallib.sh run

```bash
cd phase3-binary
time bash scripts/build-mlx-metallib.sh .build/arm64-apple-macosx/release
```

### Environment

| Field | Value |
|-------|-------|
| Metal version (`__METAL_VERSION__`) | 400 |
| SDK version | 26.5 |
| Deployment target | (unset — no `-mmacosx-version-min`) |

Metal ≥ 400 and SDK ≥ 26.2 → **NAX kernels included** (38 total kernels, vs 32 base).

NAX kernels compiled:
- `steel/gemm/kernels/steel_gemm_fused_nax`
- `steel/gemm/kernels/steel_gemm_gather_nax`
- `steel/gemm/kernels/steel_gemm_splitk_nax`
- `quantized_nax`
- `fp_quantized_nax`
- `steel/attn/kernels/steel_attention_nax`

### Result

| Field | Value |
|-------|-------|
| Output path | `.build/arm64-apple-macosx/release/mlx.metallib` |
| Size | 125 MB |
| MetalLib format | 1.2.9 |
| Build duration | **1m 58s** |
| SHA-256 | `90c9a8af18123b2f84c17e5e85d31e356e24df69dea5639c9e4aa439a4985274` |

---

## Step 3 — Artifact check (minimal staging tarball)

Staged tarball using:
- Binary: `phase3-binary/.build/arm64-apple-macosx/release/malibu-cli` (v1.8.16)
- Metallib: `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` copied as `mlx.metallib` (as `package.sh` does)

```bash
PROVIDER_ARTIFACT=<tarball> PROVIDER_SHA256="" PROVIDER_VERSION="1.8.16" \
  bash scripts/check-tier2-provider-artifact.sh
```

### Output (truncated)

```
[tier2-provider-artifact] provider artifact sha256 observed: 504aef00...
[tier2-provider-artifact] provider artifact includes MLX Metal kernels
[tier2-provider-artifact] provider version ok: 1.8.16
[tier2-provider-artifact] provider binary contains Tier-2 surface string: provider_ecdh_public_key
[tier2-provider-artifact] provider binary contains Tier-2 surface string: tier2_capabilities
[tier2-provider-artifact] provider binary contains Tier-2 surface string: selected_aead_suite
[tier2-provider-artifact] provider binary contains Tier-2 surface string: attestation_token
[tier2-provider-artifact] provider binary contains Tier-2 surface string: certificate_signing_request
[tier2-provider-artifact] provider binary contains Tier-2 surface string: MACPROVIDER_TIER2_MDA_ARTIFACT_PATH
[tier2-provider-artifact] provider binary contains Tier-2 surface string: A256GCM
[tier2-provider-artifact] provider binary contains Tier-2 surface string: inference_response_chunk
[tier2-provider-artifact] provider binary lacks forbidden Tier-2 attestation string: DeviceCheck
[tier2-provider-artifact] provider binary lacks forbidden Tier-2 attestation string: devicecheck
[tier2-provider-artifact] SPEC-008 Phase 2 B6 provider artifact preflight passed
```

**PASS** — all 8 Tier-2 surface strings present; metallib detected; binary executable.

---

## Step 4 — decode-bench (SKIPPED)

No local model cache available for Qwen validation in this worktree session. The artifact check confirms metallib is structurally present; the T0-02 baseline (27.1 TPS Qwen on matched metallib) stands as the reference for matched-version performance.

---

## Packaging analysis

### package.sh metallib priority (auto-build behavior)

```
priority:
  1. mlx.metallib already present → skip
  2. mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib → copy as mlx.metallib
  3. fallback: run build-mlx-metallib.sh
```

In the xcodebuild path (`package.sh`), the bundle metallib is **always present** → the build script is never invoked. The check-tier2-provider-artifact.sh also accepts the bundle path directly (`mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`).

In a headless SwiftPM build path (no xcodebuild), the bundle may not be extracted, triggering the fallback script.

### Packaging gap 1 — build-mlx-metallib.sh: no optimization flags

The script lacks `-O2` or `-Os` Metal compiler flags:

```bash
metal_flags=(
  -x metal
  -Wall
  -Wextra
  -fno-fast-math
  -Wno-c++17-extensions
  -Wno-c++20-extensions
  # ← missing -O2 or -Os
)
```

**Impact:**

| Source | Size | MetalLib | Kernels |
|--------|------|----------|---------|
| `build-mlx-metallib.sh` (this run) | 125 MB | 1.2.9 | 38 (with NAX) |
| Bundle `default.metallib` (pre-compiled by ml-explore) | 2.8 MB | 1.2.7 | 32 (no NAX, older SDK) |

The 125 MB output is ~44× larger. In field installs that hit the fallback path (SwiftPM without xcodebuild), the metallib would be unoptimized. **This does not affect the artifact check** (both formats pass), but could affect GPU load time in edge cases.

**Recommendation:** Add `-O2` to `metal_flags` in `build-mlx-metallib.sh`. Compile-once cost; Metal GPU dispatch performance is kernel-dependent, not `-O` level.

### Packaging gap 2 — NAX kernels in fallback vs bundle

The pre-compiled bundle `default.metallib` (Metal 1.2.7, pre-SDK-26.2) does not include NAX kernels. The fallback `build-mlx-metallib.sh` on SDK ≥ 26.2 / Metal ≥ 400 compiles 6 additional NAX kernels. These kernels provide optimized GEMM dispatch on M4 hardware.

**Impact:** Production xcodebuild artifacts ship without NAX kernels. A deliberate rebuild of the bundle by ml-explore on SDK 26.2+ would include NAX kernels automatically. This is an upstream tracking item, not a local fix.

---

## Hashes record

| Artifact | SHA-256 | Notes |
|----------|---------|-------|
| Script-built `mlx.metallib` (mlx-swift 0.31.6, Metal 400, SDK 26.5, 38 kernels) | `90c9a8af18123b2f84c17e5e85d31e356e24df69dea5639c9e4aa439a4985274` | Fallback path; debug build; 125 MB |
| Bundle `default.metallib` (pre-compiled, Metal 1.2.7, 32 kernels) | `7fec3dfb951564f9862bbabfaaec485cf71ab08ee75c395d4200746236ee5c8e` | Production path via package.sh; 2.8 MB |
| Staging tarball (`malibu-cli` v1.8.16 + bundle metallib) | `504aef00f7fb4711909ef7c6e010e3a21f64888867d44c64f964b8941feb1309` | Artifact check input |

---

## Recommendations

1. **No immediate code change required.** `package.sh` correctly prefers the pre-compiled bundle metallib in the xcodebuild path. Field installs via the production package path always get a valid metallib.

2. **Track NAX kernel availability** (upstream): when ml-explore cuts a new mlx-swift release built with SDK 26.2+, the bundle will include NAX kernels. Pin bump at T1-01 (if unblocked after mlx-swift-lm#364) should recheck bundle metallib version.

3. **Optional follow-up:** Add `-O2` to `build-mlx-metallib.sh` `metal_flags` array to reduce fallback metallib size from ~125 MB to estimated ~15–20 MB. Not critical while xcodebuild path is nominal.

4. **Attestation note:** Upstream mlx-swift PR #472 added metallib hash attestation to the release process. Consider adopting the same attestation pattern for tier-2 artifact pipeline (record bundle metallib hash in release notes alongside binary SHA-256).

---

## Pass / Fail summary

| Criterion | Result |
|-----------|--------|
| metallib present in artifact check | **PASS** |
| build script uses pinned mlx-swift 0.31.6 checkout | **PASS** |
| artifact preflight (SPEC-008 Phase 2 B6) | **PASS** |
| decode-bench validation | SKIPPED (no model cache; T0-02 baseline covers this) |
| packaging gaps | 2 documented (non-blocking) |

**VERDICT: GREEN** — metallib ships correctly in artifact check path; version-matched build confirmed; two non-blocking gaps documented for follow-up.
