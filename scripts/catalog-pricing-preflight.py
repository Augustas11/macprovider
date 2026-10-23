#!/usr/bin/env python3
"""Offline catalog pricing preflight: the two checks of
scripts/catalog-content-release.sh --preflight that need no Pearl.

#2112 merged a catalog release with a new rate row whose served artifact id
moved off `default` without an acknowledgement. The refusal surfaced only at
activation (content_gate lane pricing-unacked-move), after the CLI cut that
baked the release. This check runs on every change so the PR fails instead.

For the head commit's signed rate card against the base commit's (the release
Pearl serves when the PR lands on a caught-up main):
  1. pricing-unacked-move: every served name (catalog key or model_id of either
     release) that resolves to a different rate row needs an entry in the head
     acknowledged-pricing-moves.json (catalog-release.py pricing_model_moves,
     the content gate's rule).
  2. MoneyTable-A parity: the head dist/coordinator.yaml rewards.rate_card
     equals the head signed rate-card.json row for row (check_rate_card_parity,
     the rule the coordinator dry-load enforces as runtime rate-card parity).

Usage:
  scripts/catalog-pricing-preflight.py [--base REF] [--head REF]
      default head HEAD; default base merge-base(origin/main, head), or head~1
      when head is on origin/main.
  scripts/catalog-pricing-preflight.py --base-dir DIR --head-dir DIR
      DIR holds rate-card.json and autotune-candidates.json; the head DIR also
      holds acknowledged-pricing-moves.json and coordinator.yaml.

Exit 0 = pass (or no rate-row change); 3 = refused; 1 = malformed input.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FILES = {
    "rate-card.json": "phase3-binary/dist/static/rate-card.json",
    "autotune-candidates.json": "phase3-binary/dist/static/autotune-candidates.json",
    "acknowledged-pricing-moves.json": "phase3-binary/catalog/autotune/acknowledged-pricing-moves.json",
    "coordinator.yaml": "phase4-coordinator/dist/coordinator.yaml",
}


def load_catalog_release():
    spec = importlib.util.spec_from_file_location("catalog_release", ROOT / "scripts" / "catalog-release.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["catalog_release"] = module
    spec.loader.exec_module(module)
    return module


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()


def export_commit(ref: str, out: pathlib.Path) -> None:
    out.mkdir(parents=True)
    for name, path in FILES.items():
        (out / name).write_bytes(subprocess.run(
            ["git", "-C", str(ROOT), "show", f"{ref}:{path}"], check=True, capture_output=True).stdout)


def resolve_refs(base: str | None, head: str) -> tuple[str, str]:
    head_sha = git("rev-parse", f"{head}^{{commit}}")
    if base is not None:
        return git("rev-parse", f"{base}^{{commit}}"), head_sha
    merge_base = git("merge-base", "origin/main", head_sha)
    if merge_base == head_sha:
        merge_base = git("rev-parse", f"{head_sha}~1")
    return merge_base, head_sha


def check(cr, base_dir: pathlib.Path, head_dir: pathlib.Path) -> list[str]:
    """Refusal reasons; empty = pass."""
    base_rows = cr.pricing_credit_rows(cr.validate_rate_card((base_dir / "rate-card.json").read_bytes())["rows"])
    head_card = cr.validate_rate_card((head_dir / "rate-card.json").read_bytes())
    head_rows = cr.pricing_credit_rows(head_card["rows"])
    if base_rows == head_rows:
        return []
    names = set()
    for directory in (base_dir, head_dir):
        names |= cr.release_model_names(directory)
    acks = cr.load_pricing_move_acks(
        (head_dir / "acknowledged-pricing-moves.json").read_bytes(), "acknowledged-pricing-moves.json")
    moves = cr.pricing_model_moves(base_rows, head_rows, names | set(base_rows) | set(head_rows), acks)
    reasons = []
    for move in moves["models"]:
        if move["model"] in moves["unacknowledged_moves"]:
            reasons.append(
                f"pricing-unacked-move: served model {move['model']!r} moves rate row {move['old_row']!r} -> "
                f"{move['new_row']!r}; add {{\"model\": {json.dumps(move['model'])}, \"from_row\": "
                f"{json.dumps(move['old_row'])}, \"to_row\": {json.dumps(move['new_row'])}}} to "
                f"{FILES['acknowledged-pricing-moves.json']}")
    try:
        cr.check_rate_card_parity(head_card, (head_dir / "coordinator.yaml").read_text())
    except cr.CatalogError as exc:
        reasons.append(f"coordinator rate-card parity ({FILES['coordinator.yaml']}): {exc}")
    return reasons


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--base-dir", type=pathlib.Path)
    parser.add_argument("--head-dir", type=pathlib.Path)
    args = parser.parse_args(argv)
    if (args.base_dir is None) != (args.head_dir is None):
        parser.error("--base-dir and --head-dir go together")
    cr = load_catalog_release()
    try:
        with tempfile.TemporaryDirectory(prefix="catalog-pricing-preflight.") as tmp:
            if args.base_dir is not None:
                base_dir, head_dir, label = args.base_dir, args.head_dir, f"{args.base_dir} -> {args.head_dir}"
            else:
                base, head = resolve_refs(args.base, args.head)
                base_dir, head_dir, label = pathlib.Path(tmp, "base"), pathlib.Path(tmp, "head"), f"{base[:12]} -> {head[:12]}"
                export_commit(base, base_dir)
                export_commit(head, head_dir)
            reasons = check(cr, base_dir, head_dir)
    except (cr.CatalogError, OSError, subprocess.CalledProcessError, KeyError, ValueError) as exc:
        print(f"catalog-pricing-preflight: ERROR: {exc}", file=sys.stderr)
        return 1
    for reason in reasons:
        print(f"catalog-pricing-preflight: REFUSED {label}: {reason}", file=sys.stderr)
    if reasons:
        return 3
    print(f"catalog-pricing-preflight: ok {label}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
