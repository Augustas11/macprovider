#!/usr/bin/env python3
"""Read the reviewed MLX dependency versions from SwiftPM Package.resolved."""

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


def normalized_location(value: str) -> str:
    return value.strip().lower().removesuffix(".git").rstrip("/")


def read_pins(path: Path) -> dict[str, str]:
    data = json.loads(path.read_text())
    pins: dict[str, str] = {}
    for pin in data.get("pins", []):
        identity = pin.get("identity", "")
        output_name = REQUIRED_PINS.get(identity)
        if output_name is None:
            continue
        if pin.get("kind") != "remoteSourceControl":
            raise ValueError(f"unexpected SwiftPM source kind for {identity}")
        if normalized_location(str(pin.get("location", ""))) != EXPECTED_LOCATIONS[identity]:
            raise ValueError(f"unexpected SwiftPM source location for {identity}")
        state = pin.get("state", {})
        version = state.get("version")
        revision = state.get("revision")
        if isinstance(version, str) and version and isinstance(revision, str) and revision:
            pins[output_name] = version
            pins[f"{output_name}_revision"] = revision

    required_fields = set(REQUIRED_PINS.values()) | {
        f"{name}_revision" for name in REQUIRED_PINS.values()
    }
    missing = sorted(required_fields - pins.keys())
    if missing:
        raise ValueError(f"missing required SwiftPM pins: {', '.join(missing)}")
    return pins


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} PACKAGE.RESOLVED", file=sys.stderr)
        return 2
    try:
        print(json.dumps(read_pins(Path(sys.argv[1])), sort_keys=True))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"failed to read SwiftPM pins: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
