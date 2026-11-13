#!/usr/bin/env python3
"""Read the reviewed MLX dependency versions from SwiftPM Package.resolved.

Two entry points:

* ``read_pins`` parses pins for reporting (the upstream watch). It accepts an
  upstream source at any version, or a SPEC-048 fork at its reviewed revision,
  so it can describe historical and mixed graphs.
* ``read_production_pins`` is the production gate. It requires the complete
  authorized SPEC-048 fork tuple: mlx-swift-lm AND mlx-swift both resolved from
  the Augustas11 forks at their exact reviewed revisions. Upstream or mixed
  stacks fail closed, because either half alone silently drops fork patches.

Package.resolved does not list the MLX core (``mlx``) submodule. The reviewed
mlx-swift fork revision pins it: at 0f93fa38 the ``Source/Cmlx/mlx`` gitlink is
https://github.com/Augustas11/mlx at 0f26baba (``SPEC048_MLX_CORE_REVISION``),
so requiring that exact mlx-swift revision transitively pins the core fork.

The CLI runs the production gate; ``--historical`` selects ``read_pins``.
"""

import json
import sys
from pathlib import Path


REQUIRED_PINS = {
    "mlx-swift": "mlx_swift",
    "mlx-swift-lm": "mlx_swift_lm",
    "swift-transformers": "swift_transformers",
    "swift-jinja": "swift_jinja",
}

EXPECTED_LOCATIONS = {
    "mlx-swift": "https://github.com/ml-explore/mlx-swift",
    "mlx-swift-lm": "https://github.com/ml-explore/mlx-swift-lm",
    "swift-transformers": "https://github.com/huggingface/swift-transformers",
    "swift-jinja": "https://github.com/huggingface/swift-jinja",
}

# The reviewed SPEC-048 fork tuple (R003). This module is its single source in
# scripts: the upstream watch imports these names, and a test checks them
# against the SPEC-048 fork table.
SPEC048_MLX_SWIFT_LM_FORK = "https://github.com/Augustas11/mlx-swift-lm"
# 3.32.3-macprovider.60 (#2328) on 3.32.3-macprovider.58: the Qwen2-VL commit
# of 3.32.3-macprovider.59 (#2327: post-vision decode uses fused
# non-traditional RoPE when the three M-RoPE axes share one rope delta) and
# the Gemma 4 commits b2a45b0 (packed assistant drafter, embedded assistant
# loader, target hidden-state and shared-K/V emission) and e198b9b (Gemma 4
# layers attend through a cache that owns attention, so batched rows attend
# only over their own keys), which the provider's gemma4_mtp_v1 adapter needs.
# 3.32.3-macprovider.58 (#2335) on 3.32.3-macprovider.56: MLX core
# v0.32.4-macprovider.14 (via mlx-swift 0.32.3-macprovider.22): one row of a
# qualifying affine weight takes affine_qmv_mma1, a single-row kernel with
# qmv_mma's exact reduction order, and rows 2-16 take qmv_mma; a row is
# bit-identical alone and in a batch because the two kernels are bit-identical
# (checked on M5 and M3 Ultra GPUs; not on M1, M2 or M4). The switch point is a
# speed choice (M3 Ultra, Llama 3.1 8B 4-bit, aggregate tok/s: 1 row 93 on
# qmv_mma1 against 75 on qmv_mma, 2 rows 120 against 146).
# MLX_METAL_SMALL_M_ROW_INVARIANT, read once per process, keeps that window by
# default; 0 skips it for the fork's pre-window small-row routing (per-row qmv
# below the qmm limit), which the provider sets only for a serial-only serve
# process (SPEC-038 FR-CB9). Decode tok/s for the core change is not yet
# measured on the merged build.
# 3.32.3-macprovider.56 (#2305) is .49 plus four DeepSeek V4-only prefill commits (tile pipelining, grouped MoE expert launches, grouped gather_qmm, expert-batch memory bound):
# attention and indexer prefill tiles are evaluated one ahead (asyncEval, at
# most two in flight) and on the M3 Ultra the MoE prefill groups wide-route experts into one launch per row-count group and serves gathered plain and split-K runs with sorted gather_qmm (single-row experts and declined gathers stay per expert), in ascending-id expert batches of at most 49,152 routed rows, with the per-token sum over the selected experts in ascending expert order in float32. Outputs are bit-identical to the per-expert loop.
# 3.32.3-macprovider.49 (#2307) is .48 plus one tests-only commit
# (GLM-5-Next row-invariance up to the provider decode bound, TF32-derived
# tolerances); no library code changes.
# 3.32.3-macprovider.48 (#2111) is .47 plus the DeepSeek V4 campaign commits
# (reference arithmetic, DSpark drafter, shared MXFP8 multi-row tiles and
# row-invariant decode kernels).
# 3.32.3-macprovider.47 (#2256) is .44 (MiniMax) plus the mlx-swift
# 0.32.3-macprovider.18 pin: core v0.32.4-macprovider.10 sends every small-M
# affine product whose K is not a multiple of 128 (gpt-oss) to qmv_wide for
# every row count on gen 15 and 16 GPUs; other shapes and gen 17 keep their
# routes.
# 3.32.3-macprovider.44 (#2189, #2284) is .43 (#2230) plus four exact MiniMax M3
# decode fusions and the seeded fused-norm test (MiniMaxM3.swift and its tests
# only).
# 3.32.3-macprovider.43 (#2230) is .42 plus the Mamba2 segsum batch-mask fix
# and upstream #728, #703, #712, #747 and #754 (#740 left out).
# 3.32.3-macprovider.42 (#2254, #2255) is .40 plus the GPT-OSS SwiGLU bf16
# clip and a lab-only gpt-oss per-layer dump (GPTOSS.swift and its tests only).
# 3.32.3-macprovider.40 (#2231) is .38 plus the LiquidAI LFM3 text model
# (`lfm3`, upstream #750), its #756 hardening and registry entry.
# 3.32.3-macprovider.38 (#2265) is .35 (`c9d8a93`) plus two commits: the
# mlx-swift 0.32.3-macprovider.13 pin (#2234) and GLM-5-Next projecting 1...8
# decode tokens with one kernel. .35 (#2270) on .32 adds the `ricursive` text
# model (Ripple-65B Preview) and its prefill chunk. .32 (#2244, #2189) on .25
# maps a Hugging Face per-layer quantization map to module paths at load.
SPEC048_MLX_SWIFT_LM_TAG = "3.32.3-macprovider.60"
SPEC048_MLX_SWIFT_LM_REVISION = "a4b4b536d8ef2c05b55e54db4f672e60c6c31d5b"
SPEC048_MLX_SWIFT_LM_UPSTREAM_BASE = "3b339ad6e3b3f44c8121ecff5131c7fd55e075e6"
SPEC048_MLX_SWIFT_FORK = "https://github.com/Augustas11/mlx-swift"
SPEC048_MLX_SWIFT_TAG = "0.32.3-macprovider.22"
# Fork tag 0.32.3-macprovider.22: upstream mlx-swift 0.32.3 with the MLX core
# submodule on the core fork below.
SPEC048_MLX_SWIFT_REVISION = "0f93fa380369a1abd1e17757a465cf42a72d8f69"
SPEC048_MLX_SWIFT_UPSTREAM_BASE = "19601207e9a0de51e03ee6ec0c3c5f3784275075"
# Fork tag v0.32.4-macprovider.14, seven commits on v0.32.4-macprovider.7
# (upstream MLX v0.32.4): the reviewed Source/Cmlx/mlx gitlink of SPEC048_MLX_SWIFT_REVISION. Package.resolved does
# not carry it, so read_production_pins cannot check it; the production gate
# for the core revision is MLXCoreStreamPropagationTests
# (testResolvedCoreIsTheReviewedForkRevision), which compares the resolved
# mlx-swift gitlink and core HEAD with this value in CI.
SPEC048_MLX_CORE_FORK = "https://github.com/Augustas11/mlx"
SPEC048_MLX_CORE_TAG = "v0.32.4-macprovider.14"
SPEC048_MLX_CORE_REVISION = "0f26baba0d1c1a10d74e7133614e0dc7f409ff80"
SPEC048_MLX_CORE_UPSTREAM_BASE = "36969c094354086e15d2a327a9c50feb20b9cf11"
# The separate C symbol preserves the existing quantized-matmul ABI.
SPEC048_MLX_C_FORK = "https://github.com/Augustas11/mlx-c"
SPEC048_MLX_C_TAG = "v0.6.0-macprovider.2"
SPEC048_MLX_C_REVISION = "2b1ff2b5b5129a6115771da32e1bac3b6b01ab01"
SPEC048_MLX_C_UPSTREAM_BASE = "ebc88f10caa1b625e6b581437a8dea6df8a70085"

# #2028 audit carry: every reviewed revision and upstream base is a full
# lowercase 40-hex Git object id, checked at import so a truncated or
# mistyped constant fails every consumer instead of matching nothing.
_REVISION_CONSTANTS = {
    "SPEC048_MLX_SWIFT_LM_REVISION": SPEC048_MLX_SWIFT_LM_REVISION,
    "SPEC048_MLX_SWIFT_LM_UPSTREAM_BASE": SPEC048_MLX_SWIFT_LM_UPSTREAM_BASE,
    "SPEC048_MLX_SWIFT_REVISION": SPEC048_MLX_SWIFT_REVISION,
    "SPEC048_MLX_SWIFT_UPSTREAM_BASE": SPEC048_MLX_SWIFT_UPSTREAM_BASE,
    "SPEC048_MLX_CORE_REVISION": SPEC048_MLX_CORE_REVISION,
    "SPEC048_MLX_CORE_UPSTREAM_BASE": SPEC048_MLX_CORE_UPSTREAM_BASE,
    "SPEC048_MLX_C_REVISION": SPEC048_MLX_C_REVISION,
    "SPEC048_MLX_C_UPSTREAM_BASE": SPEC048_MLX_C_UPSTREAM_BASE,
}
for _name, _value in _REVISION_CONSTANTS.items():
    if not (len(_value) == 40 and all(ch in "0123456789abcdef" for ch in _value)):
        raise ValueError(f"{_name} must be a lowercase 40-hex Git object id")

# Each reviewed fork is accepted only at its exact revision with no version.
REVIEWED_FORK_PINS = {
    "mlx-swift-lm": (SPEC048_MLX_SWIFT_LM_FORK, SPEC048_MLX_SWIFT_LM_REVISION),
    "mlx-swift": (SPEC048_MLX_SWIFT_FORK, SPEC048_MLX_SWIFT_REVISION),
}


def normalized_location(value: str) -> str:
    return value.strip().lower().removesuffix(".git").rstrip("/")


def is_reviewed_fork_pin(identity: str, location: str, revision: object) -> bool:
    reviewed = REVIEWED_FORK_PINS.get(identity)
    return (
        reviewed is not None
        and location == normalized_location(reviewed[0])
        and revision == reviewed[1]
    )


def read_pins(path: Path) -> dict[str, str]:
    return _read(path)[0]


def read_production_pins(path: Path) -> dict[str, str]:
    pins, fork_identities = _read(path)
    missing_forks = sorted(set(REVIEWED_FORK_PINS) - fork_identities)
    if missing_forks:
        raise ValueError(
            "production requires the SPEC-048 fork tuple; not resolved from the "
            f"reviewed fork: {', '.join(missing_forks)}"
        )
    return pins


def _read(path: Path) -> tuple[dict[str, str], set[str]]:
    data = json.loads(path.read_text())
    pins: dict[str, str] = {}
    fork_identities: set[str] = set()
    for pin in data.get("pins", []):
        identity = pin.get("identity", "")
        output_name = REQUIRED_PINS.get(identity)
        if output_name is None:
            continue
        if pin.get("kind") != "remoteSourceControl":
            raise ValueError(f"unexpected SwiftPM source kind for {identity}")
        location = normalized_location(str(pin.get("location", "")))
        state = pin.get("state", {})
        version = state.get("version")
        revision = state.get("revision")
        if location != normalized_location(EXPECTED_LOCATIONS[identity]):
            if is_reviewed_fork_pin(identity, location, revision) and version is None:
                pins[output_name] = revision
                pins[f"{output_name}_revision"] = revision
                fork_identities.add(identity)
                continue
            raise ValueError(f"unexpected SwiftPM source location for {identity}")
        if isinstance(version, str) and version and isinstance(revision, str) and revision:
            pins[output_name] = version
            pins[f"{output_name}_revision"] = revision

    required_fields = set(REQUIRED_PINS.values()) | {
        f"{name}_revision" for name in REQUIRED_PINS.values()
    }
    missing = sorted(required_fields - pins.keys())
    if missing:
        raise ValueError(f"missing required SwiftPM pins: {', '.join(missing)}")
    return pins, fork_identities


def main() -> int:
    args = sys.argv[1:]
    reader = read_production_pins
    if args[:1] == ["--historical"]:
        reader = read_pins
        args = args[1:]
    if len(args) != 1:
        print(
            f"usage: {Path(sys.argv[0]).name} [--historical] PACKAGE.RESOLVED",
            file=sys.stderr,
        )
        return 2
    try:
        print(json.dumps(reader(Path(args[0])), sort_keys=True))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"failed to read SwiftPM pins: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
