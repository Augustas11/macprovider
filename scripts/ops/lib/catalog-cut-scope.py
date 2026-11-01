#!/usr/bin/env python3
"""Classify why origin/main's catalog release is not the one Pearl serves.

cli-release.sh blocks candidate_cut while origin/main's catalog release is not
live (#2119): the candidate bakes it, and a canary whose baked catalog or rate
card is newer than Pearl's fails to join. A tuple's first native-MTP admission
cannot go live before that cut either: native_mtp_release_match.py requires
every admission entry in the scope packaged inside the signed CLI release that
native-mtp-admission-release.json binds, and only this cut packages it
(docs/runbooks/native-mtp-enablement.md "Order"). This classifier names the one
committed≠live state in which the cut may go first:

  * native-mtp-admission-release.json binds this catalog release to a CLI older
    than the candidate, and at least one committed admission entry's scope
    (model, artifact, hardware, RAM, slots) is absent from the admission feed
    that CLI's source commit packaged: this cut is what packages it;
  * every live feed verifies against Pearl's /v1/autotune-release digests, the
    policy_version is the same, and the rate card, demand rank, candidate and
    artifact catalogs equal the committed ones apart from their release stamps:
    no price, rate row or model row ships un-activated;
  * the continuous-batching policy keeps every live entry and adds entries only
    for those newly admitted models (the same qualification campaign).

It prints `admission_scope_only: <model keys>` and exits 0, or
`blocked: <reason>` and exits 1. Read-only: git objects and fetched bytes only.
The authoritative signed-release match still runs at catalog activation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

AUTOTUNE = "phase3-binary/catalog/autotune"
VERSION_FILE = "phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
SCOPE_FIELDS = ("model_key", "artifact_hash", "hardware_class", "ram_bytes", "qualified_slots")
# committed feed file -> (live /v1/autotune-release feed key, coordinator route)
FEEDS = {
    "rate-card.json": ("rate_card", "rate-card"),
    "demand-rank.json": ("demand_rank", "demand-rank"),
    "autotune-candidates.json": ("autotune_candidates", "autotune-candidates"),
    "autotune-artifacts.json": ("catalog_artifacts", "catalog-artifacts"),
    "continuous-batching-policy.json": ("continuous_batching_policy", "continuous-batching-policy"),
}
CB_FEED = "continuous-batching-policy.json"
# Per-release stamps. The rate card's `version` is its content digest, so it
# stays compared; elsewhere `version` is the release id.
STAMPS = {"generated_at", "version", "release_id", "candidate_catalog_sha256"}
RATE_CARD_STAMPS = {"generated_at"}


class Blocked(Exception):
    pass


def git_show(repo: pathlib.Path, commit: str, path: str) -> bytes | None:
    result = subprocess.run(["git", "-C", str(repo), "show", f"{commit}:{path}"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    return result.stdout if result.returncode == 0 else None


def load(data: bytes | None, what: str) -> dict:
    if data is None:
        raise Blocked(f"{what} is unreadable")
    try:
        obj = json.loads(data)
    except ValueError as exc:
        raise Blocked(f"{what} is not JSON: {exc}") from None
    if not isinstance(obj, dict):
        raise Blocked(f"{what} is not a JSON object")
    return obj


def semver(text: str) -> tuple[int, ...]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", text or ""):
        raise Blocked(f"version {text!r} is not x.y.z")
    return tuple(int(part) for part in text.split("."))


def scope(entry: object) -> tuple:
    return tuple(entry.get(f) for f in SCOPE_FIELDS) if isinstance(entry, dict) else ()


def strip(doc: dict, stamps: set[str]) -> dict:
    return {k: v for k, v in doc.items() if k not in stamps}


def cut_models(repo: pathlib.Path, commit: str, release_id: str, version: str) -> list[str]:
    binding = load(git_show(repo, commit, f"{AUTOTUNE}/native-mtp-admission-release.json"),
                   "native-mtp-admission-release.json")
    if binding.get("release_id") != release_id:
        raise Blocked(f"native-mtp-admission-release.json binds {binding.get('release_id')!r}, not {release_id}")
    bound = (binding.get("entry") or {}).get("source_commit")
    if not isinstance(bound, str) or not re.fullmatch(r"[0-9a-f]{40}", bound):
        raise Blocked("native-mtp-admission-release.json has no full source_commit")
    swift = git_show(repo, bound, VERSION_FILE)
    found = re.findall(rb'let binaryVersion\s*=\s*"([0-9.]+)"', swift or b"")
    if len(found) != 1:
        raise Blocked(f"bound release {bound} has no readable binaryVersion")
    bound_version = found[0].decode()
    if semver(bound_version) >= semver(version):
        raise Blocked(f"the admission binds v{bound_version}, not a CLI older than v{version}")
    # The CLI release bakes the catalog of its source commit; its admission
    # feed is the signed scope native_mtp_release_match.py checks against.
    packaged = git_show(repo, bound, f"{AUTOTUNE}/native-mtp-admission.json")
    packaged_scope = {scope(e) for e in (load(packaged, "bound admission").get("entries") or [])} if packaged else set()
    entries = load(git_show(repo, commit, f"{AUTOTUNE}/native-mtp-admission.json"),
                   "native-mtp-admission.json").get("entries")
    if not isinstance(entries, list) or not entries:
        raise Blocked("committed native-mtp-admission.json has no entries")
    models = sorted({e.get("model_key") for e in entries if scope(e) not in packaged_scope})
    if not models or not all(isinstance(m, str) and m for m in models):
        raise Blocked(f"every admission scope is already packaged in v{bound_version}; the native-MTP scope does not need this cut")
    return models


def cb_entries(doc: dict, what: str) -> list[str]:
    entries = doc.get("entries")
    if not isinstance(entries, list):
        raise Blocked(f"{what} has no entries list")
    # tuple_sha256 binds stamped catalog bytes; every other field is compared.
    return [json.dumps({k: v for k, v in e.items() if k != "tuple_sha256"}, sort_keys=True)
            for e in entries if isinstance(e, dict)]


def compare_feeds(repo: pathlib.Path, commit: str, committed_release: dict, live_dir: pathlib.Path,
                  models: list[str]) -> None:
    live_release = load((live_dir / "autotune-release").read_bytes() if (live_dir / "autotune-release").is_file() else None,
                        "Pearl /v1/autotune-release")
    if live_release.get("release_id") == committed_release.get("release_id"):
        raise Blocked("Pearl already serves the committed release")
    if live_release.get("policy_version") != committed_release.get("policy_version"):
        raise Blocked(f"policy_version {committed_release.get('policy_version')!r} differs from live {live_release.get('policy_version')!r}")
    live_feeds = live_release.get("feeds") if isinstance(live_release.get("feeds"), dict) else {}
    for name, (key, route) in FEEDS.items():
        path = live_dir / route
        raw = path.read_bytes() if path.is_file() else None
        want = (live_feeds.get(key) or {}).get("sha256") if isinstance(live_feeds.get(key), dict) else None
        if raw is None or not want or hashlib.sha256(raw).hexdigest() != want:
            raise Blocked(f"Pearl's live {route} does not verify against /v1/autotune-release")
        live = load(raw, f"live {route}")
        mine = load(git_show(repo, commit, f"{AUTOTUNE}/{name}"), name)
        if name == CB_FEED:
            if strip(dict(live, entries=None), STAMPS) != strip(dict(mine, entries=None), STAMPS):
                raise Blocked(f"{name} differs from live outside its entries")
            live_set, mine_set = cb_entries(live, f"live {route}"), cb_entries(mine, name)
            if any(e not in mine_set for e in live_set):
                raise Blocked(f"{name} changes or removes a live entry")
            added = {json.loads(e).get("model_key") for e in mine_set if e not in live_set}
            if not added <= set(models):
                raise Blocked(f"{name} adds entries for {sorted(added - set(models))}, which this cut does not admit")
            continue
        stamps = RATE_CARD_STAMPS if name == "rate-card.json" else STAMPS
        if strip(live, stamps) != strip(mine, stamps):
            raise Blocked(f"{name} differs from live beyond its release stamps; activate it first")


def classify(repo: pathlib.Path, commit: str, version: str, live_dir: pathlib.Path) -> str:
    release = load(git_show(repo, commit, f"{AUTOTUNE}/release.json"), "committed release.json")
    release_id = release.get("release_id")
    if not isinstance(release_id, str) or not release_id:
        raise Blocked("committed release.json has no release_id")
    models = cut_models(repo, commit, release_id, version)
    compare_feeds(repo, commit, release, live_dir, models)
    return "admission_scope_only: " + " ".join(models)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=pathlib.Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--version", required=True, help="the candidate binaryVersion")
    parser.add_argument("--live-dir", type=pathlib.Path, required=True,
                        help="autotune-release and the feed routes as fetched from the coordinator")
    args = parser.parse_args()
    try:
        print(classify(args.repo, args.commit, args.version, args.live_dir))
    except (Blocked, OSError) as exc:
        print(f"blocked: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
