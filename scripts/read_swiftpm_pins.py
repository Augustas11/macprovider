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
mlx-swift fork revision pins it: at 12d26ef6 the ``Source/Cmlx/mlx`` gitlink is
https://github.com/Augustas11/mlx at 4e9a71dc (``SPEC048_MLX_CORE_REVISION``),
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
# 3.32.3-macprovider.85 (#2451, #2448) on 3.32.3-macprovider.84: Three
# GLM5Next commits on 3.32.3-macprovider.84 add prefill slices
# (`glm5NextPrefillSlicesKey`): the routed and shared experts and dense MLPs
# run once over consecutive balanced chunks, while router, hyper-connections
# and attention stay per chunk, bit-identical to separate forwards; on NAX
# GPUs slices join only when the wide gather_qmm call keeps their row tile.
# Plus a Qwen4Exp join/leave test and a GLM5NextTests type-check split. Other
# model families and decode are unchanged.
SPEC048_MLX_SWIFT_LM_TAG = "3.32.3-macprovider.85"
SPEC048_MLX_SWIFT_LM_REVISION = "8aa564dbf780cb4bd88e3fb591981eae868780f4"
SPEC048_MLX_SWIFT_LM_UPSTREAM_BASE = "3b339ad6e3b3f44c8121ecff5131c7fd55e075e6"
SPEC048_MLX_SWIFT_FORK = "https://github.com/Augustas11/mlx-swift"
SPEC048_MLX_SWIFT_TAG = "0.32.3-macprovider.25"
# Fork tag 0.32.3-macprovider.25: upstream mlx-swift 0.32.3 with the MLX core
# submodule on the core fork below (.22 plus three commits that move the core
# gitlink to the stock-order route and regenerate the quantized jit sources);
# .25 is .24 (7fbcada9) plus a synchronous eval that waits for the device
# without holding the process-wide evalLock (Swift layer only, core gitlink
# unchanged).
SPEC048_MLX_SWIFT_REVISION = "12d26ef6c6d65ba3a265a2b65c3c9380d9c22bd7"
SPEC048_MLX_SWIFT_UPSTREAM_BASE = "19601207e9a0de51e03ee6ec0c3c5f3784275075"
# Fork tag v0.32.4-macprovider.15, seven commits on v0.32.4-macprovider.14
# (upstream MLX v0.32.4) that add the stock-order small-row route
# (MLX_METAL_SMALL_M_ROW_INVARIANT=2) and its qmv_mma partial-sum count: the
# reviewed Source/Cmlx/mlx gitlink of SPEC048_MLX_SWIFT_REVISION. Package.resolved does
# not carry it, so read_production_pins cannot check it; the production gate
# for the core revision is MLXCoreStreamPropagationTests
# (testResolvedCoreIsTheReviewedForkRevision), which compares the resolved
# mlx-swift gitlink and core HEAD with this value in CI.
SPEC048_MLX_CORE_FORK = "https://github.com/Augustas11/mlx"
SPEC048_MLX_CORE_TAG = "v0.32.4-macprovider.15"
SPEC048_MLX_CORE_REVISION = "4e9a71dc9e765f739003868f38d3aca05871e70d"
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
