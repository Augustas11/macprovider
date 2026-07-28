#!/usr/bin/env python3
"""Render the reviewed C2 timer field-scoped coordinator config migration."""
from __future__ import annotations

import argparse
import shutil
import sys

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    print("c2-timer-config-migration.py requires PyYAML (pip install pyyaml)", file=sys.stderr)
    raise SystemExit(2) from exc


FIELDS = (
    ("routing", "request_timeout_s"),
    ("provider_http", "timeout_s"),
)


def load_mapping(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        doc = yaml.safe_load(handle) or {}
    if not isinstance(doc, dict):
        raise SystemExit(f"{path}: expected a YAML mapping")
    return doc


def int_field(doc: dict, section: str, key: str, path: str) -> int | None:
    value = doc.get(section, {}).get(key) if isinstance(doc.get(section), dict) else None
    if value is None:
        return None
    if isinstance(value, bool):
        raise SystemExit(f"{path}: {section}.{key} must be an integer, got boolean")
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"{path}: {section}.{key} must be an integer") from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only-existing", action="store_true")
    parser.add_argument("live_config")
    parser.add_argument("tracked_config")
    args = parser.parse_args()

    live = load_mapping(args.live_config)
    tracked = load_mapping(args.tracked_config)
    changed = False

    for section, key in FIELDS:
        target = int_field(tracked, section, key, args.tracked_config)
        if target is None:
            raise SystemExit(f"{args.tracked_config}: missing required target {section}.{key}")

        current = int_field(live, section, key, args.live_config)
        if current is None and args.only_existing:
            continue
        if current is not None and target < current:
            raise SystemExit(
                f"refusing to lower {section}.{key}: live={current} tracked={target}"
            )
        if current == target:
            continue
        changed = True
        section_doc = live.setdefault(section, {})
        if not isinstance(section_doc, dict):
            raise SystemExit(f"{args.live_config}: {section} must be a YAML mapping")
        section_doc[key] = target

    if not changed:
        with open(args.live_config, "r", encoding="utf-8") as handle:
            shutil.copyfileobj(handle, sys.stdout)
    else:
        yaml.safe_dump(live, sys.stdout, sort_keys=False, default_flow_style=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
