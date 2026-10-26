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
mlx-swift fork revision pins it: at 29d3b933 the ``Source/Cmlx/mlx`` gitlink is
https://github.com/Augustas11/mlx at 2f512e39 (``SPEC048_MLX_CORE_REVISION``),
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
# Fork tag 3.32.3-macprovider.10.9.1 (branch campaign/2111-dsv4-fidelity):
# 3.32.3-macprovider.10.5 (c8be0f61) plus DeepSeek V4 fidelity to DeepSeek's
# reference (carried overlap window, exact indexer top-k, float32 numerics).
SPEC048_MLX_SWIFT_LM_TAG = "3.32.3-macprovider.10.9.1"
SPEC048_MLX_SWIFT_LM_REVISION = "098c33964e6c7bb9ac9695d5f18ed4cc87252e67"
SPEC048_MLX_SWIFT_LM_UPSTREAM_BASE = "3b339ad6e3b3f44c8121ecff5131c7fd55e075e6"
SPEC048_MLX_SWIFT_FORK = "https://github.com/Augustas11/mlx-swift"
SPEC048_MLX_SWIFT_TAG = "0.32.3-macprovider.9"
# Fork tag 0.32.3-macprovider.9: upstream mlx-swift 0.32.3 with the MLX core
# submodule on the core fork below.
SPEC048_MLX_SWIFT_REVISION = "29d3b93375cc56cd2649b40e4310a8bc445e9874"
SPEC048_MLX_SWIFT_UPSTREAM_BASE = "19601207e9a0de51e03ee6ec0c3c5f3784275075"
# Fork tag v0.32.4-macprovider.4 on upstream MLX v0.32.4: the reviewed
# Source/Cmlx/mlx gitlink of SPEC048_MLX_SWIFT_REVISION. Package.resolved does
# not carry it, so read_production_pins cannot check it; the production gate
# for the core revision is MLXCoreStreamPropagationTests
# (testResolvedCoreIsTheReviewedForkRevision), which compares the resolved
# mlx-swift gitlink and core HEAD with this value in CI.
SPEC048_MLX_CORE_FORK = "https://github.com/Augustas11/mlx"
SPEC048_MLX_CORE_TAG = "v0.32.4-macprovider.4"
SPEC048_MLX_CORE_REVISION = "2f512e3997349c8648f5d7c5113eb2c825aa242d"
SPEC048_MLX_CORE_UPSTREAM_BASE = "36969c094354086e15d2a327a9c50feb20b9cf11"

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
