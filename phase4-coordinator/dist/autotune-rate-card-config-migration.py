#!/usr/bin/env python3
"""Render the reviewed B10 rate-card feed coordinator config migration."""
from __future__ import annotations

import argparse
import shutil
import sys

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    print("autotune-rate-card-config-migration.py requires PyYAML (pip install pyyaml)", file=sys.stderr)
    raise SystemExit(2) from exc


STATIC_FEED_FIELDS = (
    "rate_card_path",
    "rate_card_sig_path",
    "demand_rank_path",
    "demand_rank_sig_path",
    "autotune_candidates_path",
    "autotune_candidates_sig_path",
)
RATE_CARD_FIELDS = (
    "rate_card_path",
    "rate_card_sig_path",
)


def load_mapping(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        doc = yaml.safe_load(handle) or {}
    if not isinstance(doc, dict):
        raise SystemExit(f"{path}: expected a YAML mapping")
    return doc


def autotune_mapping(doc: dict, path: str) -> dict:
    value = doc.setdefault("autotune", {})
    if not isinstance(value, dict):
        raise SystemExit(f"{path}: autotune must be a YAML mapping")
    return value


def nonempty(value: object) -> bool:
    return isinstance(value, str) and value.strip() != ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only-static-feed-overlays", action="store_true")
    parser.add_argument("live_config")
    parser.add_argument("tracked_config")
    args = parser.parse_args()

    live = load_mapping(args.live_config)
    tracked = load_mapping(args.tracked_config)
    live_autotune = autotune_mapping(live, args.live_config)
    tracked_autotune = autotune_mapping(tracked, args.tracked_config)

    if args.only_static_feed_overlays and not any(
        field in live_autotune for field in STATIC_FEED_FIELDS
    ):
        with open(args.live_config, "r", encoding="utf-8") as handle:
            shutil.copyfileobj(handle, sys.stdout)
        return 0

    configured_static_feed = any(nonempty(live_autotune.get(field)) for field in STATIC_FEED_FIELDS)
    if not configured_static_feed:
        with open(args.live_config, "r", encoding="utf-8") as handle:
            shutil.copyfileobj(handle, sys.stdout)
        return 0

    changed = False
    for field in RATE_CARD_FIELDS:
        target = tracked_autotune.get(field)
        if not nonempty(target):
            raise SystemExit(f"{args.tracked_config}: missing required target autotune.{field}")
        current = live_autotune.get(field)
        if current == target:
            continue
        if nonempty(current):
            raise SystemExit(
                f"{args.live_config}: refusing to rewrite existing autotune.{field}: "
                f"live={current!r} tracked={target!r}"
            )
        live_autotune[field] = target
        changed = True

    if not changed:
        with open(args.live_config, "r", encoding="utf-8") as handle:
            shutil.copyfileobj(handle, sys.stdout)
    else:
        yaml.safe_dump(live, sys.stdout, sort_keys=False, default_flow_style=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
