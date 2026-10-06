#!/usr/bin/env python3
"""Test-key catalog release for the native-MTP enablement rehearsal (SPEC-048 R014, #1770).

LAB ONLY. This drives the production release tooling (`catalog-release.py
generate` -> sign -> `generate` -> `verify` -> `verify-directory`, and the
revocation slot presigner) over a throwaway copy of the committed catalog,
signed by a throwaway Ed25519 key it creates. The output is what the isolated
Studio coordinator serves to a lab-harness provider build whose
`MACPROVIDER_LAB_STATIC_FEED_*` override trusts that key. A release build never
trusts it, and nothing here can reach the production signing key.

The release adds, on top of the committed catalog:

- the native-MTP admission set for the lab binary (sidecar, store-layout
  projection manifest, signed self-test bank) bound in ledger v4;
- a `mixed` continuous-batching policy entry for the lab binary's runtime
  tuple (D-CB stand-in; the production entry is an external input);
- 24 hours of pre-signed revocation slots.

The tuple input is the committed A3B tuple with its runtime revision moved to
the campaign pin, its benchmark policy moved to the amended R015 policy, and
its pending evidence digests filled with the digest of a rehearsal marker, so
the generator accepts it. That sidecar is rehearsal-only by construction: it
names the throwaway signer and the lab binary's ad-hoc CDHash.

Usage (from the repository root, Python 3.10+, OpenSSL 3):
  python3 -m scripts.native_mtp_rehearsal_release --facts lab-facts.json --work DIR
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone

from scripts.tests import test_catalog_artifact_feed as artifact_feed

catalog_release = artifact_feed.catalog_release
ROOT = artifact_feed.ROOT
CATALOG = ROOT / "phase3-binary/catalog/autotune"
FORMAL_TUPLE = ROOT / "docs/research/spec048-r015/evidence-2026-10-02-a3b-formal/admission-tuple-input.json"
R015_EVIDENCE = ROOT / "docs/research/spec048-r015/evidence-2026-10-06-a3b-amended-gates-quiet-26a434"
G1_JOURNEY = ROOT / "docs/research/spec048-r014/evidence-2026-10-06-g1-mixed-row-26a434/journey-result.json"
KEY_ID = "native-mtp-rehearsal-test-v1"
MODEL_KEY = "qwen/qwen3.6-35b-a3b"
TARGET = ("mlx-community/Qwen3.6-35B-A3B-4bit", "38740b847e4cb78f352aba30aa41c76e08e6eb46",
          "3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1")
DRAFTER = ("mlx-community/Qwen3.6-35B-A3B-MTP-4bit", "0295b81421bf4d0fccca9a7c0fcfb1418dda3516",
           "fa01beecb6c1e76845e9880623c3b5a009baa602c52e9e9b5d12edc489a23fd2")
TOKENIZER_SHA256 = "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"
MTP_MANIFEST_SHA256 = "7b38a336fa246a285ee23cc990351989bf2ee6c040506a2b793ee24e463f35a7"
FACT_KEYS = {
    "source_commit", "binary_sha256", "live_executable_cdhash", "provider_cli_version",
    "metallib_sha256", "hardware_class", "kernel_identifier", "tokenizer_sha256", "chat_template_sha256",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def stamp(value: datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def store_path(member: tuple[str, str, str]) -> str:
    repo, revision, digest = member
    return f"{repo.replace('/', '--')}/{revision}/{digest}"


class RehearsalRelease(artifact_feed.HermeticRelease):
    """The hermetic release harness, keyed by throwaway rehearsal key ids.

    The harness rewinds the committed catalog to the release before the
    artifact-feed activation, because the committed artifact-bound releases
    are signed by the production key this rehearsal never holds. The
    rehearsal then re-cuts the activation and the native-MTP release with the
    throwaway key, so every continuity check runs for real."""

    KEY_ID = KEY_ID
    ALT_KEY_ID = KEY_ID + "-unused-alt"

    def __init__(self, root: pathlib.Path, openssl: str):
        root.mkdir(parents=True)
        super().__init__(root, openssl)
        os.chmod(self.key, 0o600)
        os.chmod(self.alt_key, 0o600)
        der = subprocess.run([openssl, "pkey", "-in", str(self.key), "-pubout", "-outform", "DER"],
                             check=True, capture_output=True).stdout
        self.public_key_base64 = base64.b64encode(der[-32:]).decode("ascii")
        private_der = subprocess.run([openssl, "pkey", "-in", str(self.key), "-outform", "DER"],
                                     check=True, capture_output=True).stdout
        self.seed_file = root / "signing.seed.base64"
        self.seed_file.write_text(base64.b64encode(private_der[-32:]).decode("ascii"))
        os.chmod(self.seed_file, 0o600)


def tuple_input() -> dict:
    value = json.loads(FORMAL_TUPLE.read_text())
    entry = value["entry"]
    marker = sha256(b"macprovider native-MTP enablement rehearsal: test-key evidence placeholder\n")
    for key, item in list(entry.items()):
        if item == "0" * 64:
            entry[key] = marker
    entry["runtime_revision"] = "ca8c384c4fb6bc7d2fbb7c70a18c34b935701805"
    entry["ordinary_baseline"]["runtime_revision"] = entry["runtime_revision"]
    entry["benchmark_policy_sha256"] = sha256((R015_EVIDENCE / "policy.json").read_bytes())
    analysis = sha256((R015_EVIDENCE / "analysis.json").read_bytes())
    for key in ("performance_evidence_sha256", "fit_evidence_sha256"):
        entry[key] = analysis
    entry["ordinary_baseline"]["measurement_sha256"] = analysis
    return value


def projection_manifest() -> bytes:
    target, drafter = store_path(TARGET), store_path(DRAFTER)
    return canonical({
        "schema_version": "macprovider.native-mtp-artifact-projection.v1",
        "artifacts": {
            "target": {"path": target, "sha256": TARGET[2]},
            "mtp": {"path": drafter, "sha256": DRAFTER[2]},
            "tokenizer": {"path": f"{target}/tokenizer.json", "sha256": TOKENIZER_SHA256},
            "manifest": {"path": f"{drafter}/config.json", "sha256": MTP_MANIFEST_SHA256},
        },
    })


def challenge_bank(release_id: str, issued: datetime) -> bytes:
    """The hardware-measured challenge of the G1 journey run (step 12)."""
    journey = json.loads(G1_JOURNEY.read_text())
    entries = [step["details"]["challenge_bank_entry"] for step in journey["steps"]
               if "challenge_bank_entry" in step.get("details", {})]
    if len(entries) != 1:
        raise SystemExit("expected exactly one challenge_bank_entry in the G1 journey result")
    return canonical({
        "schema_version": "macprovider.native-mtp-challenge-bank.v1",
        "release_id": release_id,
        "issued_at": stamp(issued),
        "expires_at": stamp(issued + timedelta(days=7)),
        "signer_key_id": KEY_ID,
        "entries": entries,
    })


def cb_policy_source(facts: dict) -> dict:
    return {
        "schema_version": catalog_release.CB_POLICY_SOURCE_SCHEMA,
        "entries": [{
            "model_key": MODEL_KEY,
            "model_id": MODEL_KEY,
            "model_sha256": TARGET[2],
            "tokenizer_sha256": facts["tokenizer_sha256"],
            "chat_template_sha256": facts["chat_template_sha256"],
            "cache_class": "mixed",
            "kv_dtype": "fp16",
            "requires_moe": True,
            "hardware_class": facts["hardware_class"],
            "metallib_sha256": facts["metallib_sha256"],
            "kernel_identifier": facts["kernel_identifier"],
            "rollout": "canary",
            "cached_turns_accepted": False,
            "provenance": {
                "source": "operator_review",
                "status": "qualified",
                "evidence_id": "native-mtp-enablement-rehearsal-test-key",
                "package_manifest_sha256": facts["binary_sha256"],
                "studio_campaign_sha256": sha256(b"native-mtp-enablement-rehearsal"),
                "provider_cli_version": facts["provider_cli_version"],
                "live_executable_cdhash": facts["live_executable_cdhash"],
            },
        }],
    }


NATIVE_FILES = (
    "native-mtp-admission.json", "native-mtp-admission.json.sig", "native-mtp-artifact-manifest.json",
    "native-mtp-selftest-bank.json", "native-mtp-selftest-bank.json.sig",
)


def build(facts: dict, work: pathlib.Path, now: datetime) -> dict:
    missing = FACT_KEYS - facts.keys()
    if missing:
        raise SystemExit(f"facts file is missing {sorted(missing)}")
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    os.chmod(work, 0o700)
    openssl = catalog_release.openssl_executable()
    release_id = f"published-{now:%Y-%m-%d}-native-mtp-rehearsal-v1"
    generated_at = stamp(now)
    with RehearsalRelease(work / "repo", openssl) as release:
        catalog = release.catalog
        # Re-cut the artifact-feed activation with the throwaway key, before
        # any native or CB input exists; it is the native cut's previous release.
        release.bump(f"published-{now:%Y-%m-%d}-rehearsal-activation-v1", stamp(now - timedelta(minutes=1)))
        release.cut(activate_artifact_feed=True)
        previous = release.stage(work / "previous")

        manifest = projection_manifest()
        bank = challenge_bank(release_id, now)
        (catalog / "native-mtp-artifact-manifest.json").write_bytes(manifest)
        (catalog / "native-mtp-selftest-bank.json").write_bytes(bank)
        (catalog / "native-mtp-admission-tuple.json").write_text(json.dumps(tuple_input(), indent=2))
        (catalog / "native-mtp-admission-release.json").write_text(json.dumps({
            "schema_version": "macprovider.native-mtp-admission-release-input.v1",
            "release_id": release_id,
            "issued_at": generated_at,
            "expires_at": stamp(now + timedelta(days=80)),
            "signer_key_id": KEY_ID,
            "challenge_bank_signer_key_id": KEY_ID,
            "revocation_signer_key_id": KEY_ID,
            "entry": {
                "artifact_manifest_sha256": sha256(manifest),
                "provider_revision": facts["source_commit"],
                "source_commit": facts["source_commit"],
                "reproducible_build_sha256": facts["binary_sha256"],
                "live_executable_cdhash": facts["live_executable_cdhash"],
                "challenge_bank_sha256": sha256(bank),
            },
        }, indent=2))
        (catalog / "continuous-batching-policy-source.json").write_text(
            json.dumps(cb_policy_source(facts), indent=2, sort_keys=True) + "\n")
        saved = {name: getattr(catalog_release, name)
                 for name in ("NATIVE_MTP_TUPLE_INPUT_PATH", "NATIVE_MTP_RELEASE_INPUT_PATH")}
        catalog_release.NATIVE_MTP_TUPLE_INPUT_PATH = catalog / "native-mtp-admission-tuple.json"
        catalog_release.NATIVE_MTP_RELEASE_INPUT_PATH = catalog / "native-mtp-admission-release.json"
        try:
            release.bump(release_id, generated_at)
            catalog_release.generate(KEY_ID, previous_release_dir=previous)
            release.sign()
            for name in ("native-mtp-admission.json", "native-mtp-selftest-bank.json"):
                release.sign_into(release.static, name, (release.static / name).read_bytes())
            catalog_release.generate(KEY_ID, previous_release_dir=previous)
            catalog_release.verify()
            out = work / "catalog"
            release.stage(out)
            for name in NATIVE_FILES:
                shutil.copy2(release.static / name, out / name)
            catalog_release.verify_directory(out, allow_expired_tier2=True)
        finally:
            for name, value in saved.items():
                setattr(catalog_release, name, value)
        sidecar = (out / "native-mtp-admission.json").read_bytes()
        identity = catalog_release.NATIVE_MTP_SIDECAR_GENERATOR.identity(sidecar)

    slot_start = now.replace(minute=now.minute - now.minute % 10, second=0, microsecond=0)
    subprocess.run([
        sys.executable, str(ROOT / "scripts/native_mtp_revocation_slots.py"), "build",
        "--key-file", str(release.seed_file), "--key-id", KEY_ID,
        "--revoked", str(CATALOG / "native-mtp-revocations-source.json"),
        "--start", stamp(slot_start), "--days", "1", "--out", str(work / "revocations"),
    ], check=True, env=dict(os.environ, OPENSSL_BIN=openssl))
    subprocess.run([
        sys.executable, str(ROOT / "scripts/native_mtp_revocation_slots.py"), "verify",
        "--dir", str(work / "revocations"), "--key-id", KEY_ID, "--public-key-base64", release.public_key_base64,
    ], check=True, env=dict(os.environ, OPENSSL_BIN=openssl))
    summary = {
        "schema_version": "macprovider.native-mtp-rehearsal-release.v1",
        "release_id": release_id,
        "generated_at": generated_at,
        "key_id": KEY_ID,
        "public_key_base64": release.public_key_base64,
        "facts": facts,
        "sidecar_sha256": identity["sidecar_sha256"],
        "native_mtp_admission_tuple_sha256": identity["native_mtp_admission_tuple_sha256"],
        "artifact_manifest_sha256": sha256(manifest),
        "challenge_bank_sha256": sha256(bank),
        "drafter": {"repo_id": DRAFTER[0], "revision": DRAFTER[1], "sha256": DRAFTER[2]},
        "catalog_files": {p.name: sha256(p.read_bytes()) for p in sorted((work / "catalog").iterdir())},
        "revocation_slots": len(list((work / "revocations").glob("*.json"))),
    }
    (work / "rehearsal-release.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--facts", type=pathlib.Path, required=True)
    parser.add_argument("--work", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)
    summary = build(json.loads(args.facts.read_text()), args.work, datetime.now(timezone.utc).replace(microsecond=0))
    print(json.dumps({k: summary[k] for k in ("release_id", "key_id", "sidecar_sha256", "revocation_slots")}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
