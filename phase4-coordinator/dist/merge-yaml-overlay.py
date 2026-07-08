#!/usr/bin/env python3
"""Shallow-merge two YAML mapping documents (overlay keys win)."""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    print("merge-yaml-overlay.py requires PyYAML (pip install pyyaml)", file=sys.stderr)
    raise SystemExit(2) from exc


def merge(base: dict, overlay: dict) -> dict:
    out = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value)
        else:
            out[key] = value
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: merge-yaml-overlay.py <base.yaml> <overlay.yaml>", file=sys.stderr)
        return 2
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        base = yaml.safe_load(f) or {}
    with open(sys.argv[2], "r", encoding="utf-8") as f:
        overlay = yaml.safe_load(f) or {}
    if not isinstance(base, dict) or not isinstance(overlay, dict):
        print("both inputs must be YAML mappings", file=sys.stderr)
        return 2
    yaml.safe_dump(merge(base, overlay), sys.stdout, sort_keys=False, default_flow_style=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
