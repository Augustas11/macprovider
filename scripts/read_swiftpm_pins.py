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
mlx-swift fork revision pins it: at 52ae025c the ``Source/Cmlx/mlx`` gitlink is
https://github.com/Augustas11/mlx at cde15ff7 (``SPEC048_MLX_CORE_REVISION``),
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
# 3.33.0-macprovider.90 (#2487) on 3.33.0-macprovider.89:
# 3.33.0-macprovider.89 plus the Inkling 2 DSpark draft
# (Inkling2DSparkDraftModel, loaded from mtp.safetensors and bound to the
# loaded target), staged and rewound rounds over the target's attention rings
# and convolution tails (ConvolutionTailCache, CacheListRoundStrategy), target
# hidden-state taps and exact one-dispatch verify rows; the shared MLXLMCommon
# changes are opt-in (MTPExactVerifyLimitModel and MTPChunkedPromptHiddenModel
# target protocols, and round staging of an attention plus convolution-tail
# CacheList, which it refused before), so no other model's decode path
# changes; the tag is cut from this revision at merge.
SPEC048_MLX_SWIFT_LM_TAG = "3.33.0-macprovider.90"
SPEC048_MLX_SWIFT_LM_REVISION = "39f7e60d87e0dee5ee87c62e11db4d81afdf223f"
SPEC048_MLX_SWIFT_LM_UPSTREAM_BASE = "ca661dc6885f8603e911746838b60d312439a368"
SPEC048_MLX_SWIFT_FORK = "https://github.com/Augustas11/mlx-swift"
SPEC048_MLX_SWIFT_TAG = "0.33.0-macprovider.28"
# Fork tag 0.33.0-macprovider.28 (engine-333): the fork patch stack rebased onto
# upstream mlx-swift 0.33.0 plus mlx-swift PR 522; its Source/Cmlx/mlx gitlink
# is cde15ff75 and Source/Cmlx/mlx-c is 33d88bf. Prior: 0.32.3-macprovider.27
# (e7243b3d, #2451) is .26 (aaa82655) plus the dense qmm_t 64-row tile gitlink
# and the QmmTileTests bit-identity test; .26 (#2462) added the per-op small-M
# route (SmallMRoute, withSmallMRoute). The tag is cut from this revision at
# merge.
SPEC048_MLX_SWIFT_REVISION = "52ae025cbfac595328bd7fad23c8bce560bbe57c"
SPEC048_MLX_SWIFT_UPSTREAM_BASE = "7ede4fd6d05f63305c1c0ebf4f8c1909a637c574"
# Fork tag v0.32.4-macprovider.18 (engine-333): v0.32.4-macprovider.17
# (6c2ac790) plus cherry-picks of ml-explore/mlx #4883, #4881 and #4930.
# .17 (#2451) is v0.32.4-macprovider.16 (dd68f1d2) plus one commit: dense qmm_t
# takes a 64-row tile from 1024 rows for affine bfloat16 group-64 weights. .16 (#2462) is v0.32.4-macprovider.15 (4e9a71dc)
# plus three commits that add a thread-scoped per-op small-row route captured
# on QuantizedMatmul (carried through its vjp/jvp) and a discriminating 2-row
# GPU route test; .15 is seven commits on v0.32.4-macprovider.14 (upstream MLX
# v0.32.4) that add the stock-order small-row route
# (MLX_METAL_SMALL_M_ROW_INVARIANT=2) and its qmv_mma partial-sum count. This
# is the reviewed Source/Cmlx/mlx gitlink of SPEC048_MLX_SWIFT_REVISION; the
# tag is cut from it at the campaign freeze. Package.resolved does
# not carry it, so read_production_pins cannot check it; the production gate
# for the core revision is MLXCoreStreamPropagationTests
# (testResolvedCoreIsTheReviewedForkRevision), which compares the resolved
# mlx-swift gitlink and core HEAD with this value in CI.
SPEC048_MLX_CORE_FORK = "https://github.com/Augustas11/mlx"
SPEC048_MLX_CORE_TAG = "v0.32.4-macprovider.18"
SPEC048_MLX_CORE_REVISION = "cde15ff75e719a47677d7953657ee319ba50deee"
SPEC048_MLX_CORE_UPSTREAM_BASE = "36969c094354086e15d2a327a9c50feb20b9cf11"
# The separate C symbol preserves the existing quantized-matmul ABI.
# v0.8.0-macprovider.5 (engine-333): mlx-c v0.8.0 plus the fork's reference-
# prefill and small-M route bindings (the v0.6.0-macprovider.4 commit 70f188c
# ported); its CMake FetchContent pins MLX core cde15ff75. Prior:
# v0.6.0-macprovider.4 (#2462): v0.6.0-macprovider.2 (2b1ff2b5) plus one commit
# that binds the per-op small-M route scope (mlx/c/small_m_route.h). Tag .3
# (07f7ae44) is a separate line on .2 and was never pinned; .4 is cut from
# this revision at the campaign freeze.
SPEC048_MLX_C_FORK = "https://github.com/Augustas11/mlx-c"
SPEC048_MLX_C_TAG = "v0.8.0-macprovider.5"
SPEC048_MLX_C_REVISION = "33d88bf44b974d73f978ba3ebee046fd941d13bf"
SPEC048_MLX_C_UPSTREAM_BASE = "a26f2d584a14ec619ae8db9a09be03becd47598a"

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
