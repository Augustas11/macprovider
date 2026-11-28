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

from scripts import read_swiftpm_pins
from scripts import native_mtp_admission_sidecar as sidecar_gen
from scripts.tests import test_catalog_artifact_feed as artifact_feed

catalog_release = artifact_feed.catalog_release
ROOT = artifact_feed.ROOT
CATALOG = ROOT / "phase3-binary/catalog/autotune"
TRUSTED_KEYS_PATH = CATALOG / "trusted-keys.json"
PACKAGE_RESOLVED = ROOT / "phase3-binary/Package.resolved"
FORMAL_TUPLE = ROOT / "docs/research/spec048-r015/evidence-2026-10-02-a3b-formal/admission-tuple-input.json"
R015_EVIDENCE = ROOT / "docs/research/spec048-r015/evidence-2026-10-06-a3b-amended-gates-quiet-26a434"
G1_JOURNEY = ROOT / "docs/research/spec048-r014/evidence-2026-10-06-g1-mixed-row-26a434/journey-result.json"
KEY_ID = "native-mtp-rehearsal-test-v1"
INKLING_KEY_ID = "inkling2-native-mtp-rehearsal-test-v1"
MODEL_KEY = "qwen/qwen3.6-35b-a3b"
INKLING_MODEL_KEY = "thinkingmachines/inkling-2-mini"
INKLING_ARTIFACT_ID = "mlx-oq4e-mtp"
INKLING_FAMILY_ADAPTER = "inkling2_dspark_v1"
TARGET = ("mlx-community/Qwen3.6-35B-A3B-4bit", "38740b847e4cb78f352aba30aa41c76e08e6eb46",
          "3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1")
DRAFTER = ("mlx-community/Qwen3.6-35B-A3B-MTP-4bit", "0295b81421bf4d0fccca9a7c0fcfb1418dda3516",
           "fa01beecb6c1e76845e9880623c3b5a009baa602c52e9e9b5d12edc489a23fd2")
INKLING_TARGET = (
    "mlx-community/Inkling-2-Mini-oQ4e-mtp",
    "3eea042751cd296b7266628a8342c1749242e1fe",
    "75509c7fcd864d109d542676ed14763a2c5c570c731f3c1d1180d0207b6b9b34",
)
INKLING_DEFAULT_PROMPT_TOKEN_IDS = [791, 6864, 315, 9822, 374, 220]
TOKENIZER_SHA256 = "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"
MTP_MANIFEST_SHA256 = "7b38a336fa246a285ee23cc990351989bf2ee6c040506a2b793ee24e463f35a7"
FACT_KEYS = {
    "source_commit", "binary_sha256", "live_executable_cdhash", "provider_cli_version",
    "metallib_sha256", "hardware_class", "kernel_identifier", "tokenizer_sha256", "chat_template_sha256",
}
INKLING_FACT_KEYS = {
    "source_commit", "binary_sha256", "live_executable_cdhash", "provider_cli_version",
    "metallib_sha256", "hardware_class", "kernel_identifier",
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


def validate_throwaway_key_not_in_trusted_keys(
    key_id: str,
    public_key_base64: str,
    trusted_keys_path: pathlib.Path = TRUSTED_KEYS_PATH,
) -> None:
    """Refuses any throwaway rehearsal release whose key id or public key
    appears in the committed production trusted-keys.json."""
    trusted = json.loads(trusted_keys_path.read_text("utf-8"))
    keys = trusted.get("keys", {})
    if key_id in keys:
        raise ValueError(f"throwaway key_id {key_id!r} must not appear in {trusted_keys_path.name}")
    for trusted_id, meta in keys.items():
        if isinstance(meta, dict) and meta.get("public_key_base64") == public_key_base64:
            raise ValueError(
                f"throwaway public key matches production key {trusted_id!r} in {trusted_keys_path.name}"
            )


def current_decode_path_digest() -> str:
    output = subprocess.check_output(
        [sys.executable, str(ROOT / "scripts/decode_path_digest.py")],
        text=True,
    ).strip().splitlines()[-1].strip()
    if len(output) != 64:
        raise SystemExit(f"unexpected decode_path_digest output: {output!r}")
    return output


def probe_model_identity(
    cli_bin: pathlib.Path | str,
    model_dir: pathlib.Path,
    *,
    mtp_dir: pathlib.Path | None = None,
    skip_artifact_hash: bool = False,
) -> dict:
    """Invokes `macprovider-cli models native-mtp-identity --model-dir <dir> --json`
    on the target box so representation_manifest_sha256, tokenizer_sha256, and
    mtp_manifest_sha256 are never hardcoded."""
    cmd = [
        str(cli_bin),
        "models",
        "native-mtp-identity",
        "--model-dir",
        str(model_dir),
        "--json",
    ]
    if mtp_dir is not None:
        cmd.extend(["--mtp-dir", str(mtp_dir)])
    if skip_artifact_hash:
        cmd.append("--skip-artifact-hash")
    proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
    identity = json.loads(proc.stdout)
    if identity.get("schema") != "macprovider.models-native-mtp-identity.v1":
        raise SystemExit(f"unexpected models native-mtp-identity schema: {identity.get('schema')!r}")
    quant = identity.get("quantization") or {}
    for field, value in (
        ("tokenizer_sha256", identity.get("tokenizer_sha256")),
        ("mtp_manifest_sha256", identity.get("mtp_manifest_sha256")),
        ("quantization.representation_manifest_sha256", quant.get("representation_manifest_sha256")),
    ):
        if not isinstance(value, str) or len(value) != 64:
            raise SystemExit(f"models native-mtp-identity returned invalid {field}: {value!r}")
    return identity


class RehearsalRelease(artifact_feed.HermeticRelease):
    """The hermetic release harness, keyed by throwaway rehearsal key ids.

    The harness rewinds the committed catalog to the release before the
    artifact-feed activation, because the committed artifact-bound releases
    are signed by the production key this rehearsal never holds. The
    rehearsal then re-cuts the activation and the native-MTP release with the
    throwaway key, so every continuity check runs for real."""

    KEY_ID = KEY_ID
    ALT_KEY_ID = KEY_ID + "-unused-alt"

    def __init__(
        self,
        root: pathlib.Path,
        openssl: str,
        *,
        key_id: str | None = None,
        trusted_keys_path: pathlib.Path = TRUSTED_KEYS_PATH,
        preserve_current_catalog: bool = False,
    ):
        self._preserve_current_catalog = preserve_current_catalog
        if key_id is not None:
            self.KEY_ID = key_id
            self.ALT_KEY_ID = f"{key_id}-unused-alt"
        root.mkdir(parents=True)
        super().__init__(root, openssl)
        os.chmod(self.key, 0o600)
        os.chmod(self.alt_key, 0o600)
        der = subprocess.run([openssl, "pkey", "-in", str(self.key), "-pubout", "-outform", "DER"],
                             check=True, capture_output=True).stdout
        self.public_key_base64 = base64.b64encode(der[-32:]).decode("ascii")
        validate_throwaway_key_not_in_trusted_keys(
            self.KEY_ID,
            self.public_key_base64,
            trusted_keys_path=trusted_keys_path,
        )
        private_der = subprocess.run([openssl, "pkey", "-in", str(self.key), "-outform", "DER"],
                                     check=True, capture_output=True).stdout
        self.seed_file = root / "signing.seed.base64"
        self.seed_file.write_text(base64.b64encode(private_der[-32:]).decode("ascii"))
        os.chmod(self.seed_file, 0o600)

    def rewind_to_pre_activation(self) -> None:
        if not self._preserve_current_catalog:
            super().rewind_to_pre_activation()
            return
        # Keep every current committed model (including models admitted after
        # the historical artifact-feed activation, such as thinkingmachines/inkling-2-mini)
        # while synthesizing a clean pre-activation v2 base ledger row so the
        # throwaway key can cut a fresh activation release and native-MTP release.
        base_id = "published-2026-01-01-rehearsal-base-v1"
        base_ts = "2026-01-01T00:00:00Z"
        for name in (
            "autotune-artifacts.json",
            "intake-decision.json",
            "market-peg-bind.json",
            "native-mtp-admission.json",
            "native-mtp-admission-tuple.json",
            "native-mtp-admission-release.json",
            "native-mtp-variants.json",
        ):
            (self.catalog / name).unlink(missing_ok=True)
        for name in ("continuous-batching-policy.json", "continuous-batching-policy-source.json"):
            path = self.catalog / name
            if path.exists():
                obj = json.loads(path.read_text("utf-8"))
                obj["entries"] = []
                path.write_bytes(catalog_release.canonical_bytes(obj))
        self.bump(base_id, base_ts)
        candidate_bytes = (self.catalog / "autotune-candidates.json").read_bytes()
        candidate_obj = json.loads(candidate_bytes)
        demand_bytes = (self.catalog / "demand-rank.json").read_bytes()
        rate_card_path = self.catalog / "rate-card.json"
        rate_card_obj = json.loads(rate_card_path.read_text("utf-8"))
        rate_card_obj["generated_at"] = base_ts
        rate_card_bytes = catalog_release.canonical_bytes(rate_card_obj)
        rate_card_path.write_bytes(rate_card_bytes)
        cb_path = self.catalog / "continuous-batching-policy.json"
        cb_obj = json.loads(cb_path.read_text("utf-8"))
        cb_obj.update(
            release_id=base_id,
            generated_at=base_ts,
            candidate_catalog_sha256=catalog_release.sha256(candidate_bytes),
        )
        cb_bytes = catalog_release.canonical_bytes(cb_obj)
        cb_path.write_bytes(cb_bytes)
        tier2_bytes = (self.catalog / "tier2-catalog.json").read_bytes()
        tier2_obj = json.loads(tier2_bytes)
        feeds = {
            "autotune-candidates.json": {
                "bytes": len(candidate_bytes),
                "sha256": catalog_release.sha256(candidate_bytes),
                "signer_key_id": self.KEY_ID,
                "version": base_id,
            },
            "continuous-batching-policy.json": {
                "bytes": len(cb_bytes),
                "sha256": catalog_release.sha256(cb_bytes),
                "signer_key_id": self.KEY_ID,
                "version": base_id,
            },
            "demand-rank.json": {
                "bytes": len(demand_bytes),
                "sha256": catalog_release.sha256(demand_bytes),
                "signer_key_id": self.KEY_ID,
                "version": base_id,
            },
            "rate-card.json": {
                "bytes": len(rate_card_bytes),
                "sha256": catalog_release.sha256(rate_card_bytes),
                "signer_key_id": self.KEY_ID,
                "version": rate_card_obj["version"],
            },
            "tier2-catalog.json": {
                "bytes": len(tier2_bytes),
                "sha256": catalog_release.sha256(tier2_bytes),
                "signer_key_id": "tier2-test-key",
                "version": tier2_obj["catalog_id"],
            },
        }
        ledger = {
            "schema_version": catalog_release.LEDGER_SCHEMA_V2,
            "releases": {
                base_id: {
                    "feeds": feeds,
                    "generated_at": base_ts,
                    "policy_version": candidate_obj["policy_version"],
                }
            },
            "tombstones": {},
        }
        (self.catalog / "release-ledger.json").write_bytes(catalog_release.ledger_bytes(ledger))
        binding_path = self.catalog / "tier2-identity-binding.json"
        binding = json.loads(binding_path.read_text("utf-8"))
        binding.update(
            autotune_candidates_sha256=catalog_release.sha256(candidate_bytes),
            generated_at=base_ts,
            release_id=base_id,
        )
        binding_path.write_text(json.dumps(binding, indent=2, sort_keys=True) + "\n", "utf-8")
        (self.catalog / "release.json").write_text(json.dumps({
            "feeds": feeds,
            "generated_at": base_ts,
            "policy_version": candidate_obj["policy_version"],
            "release_id": base_id,
            "schema_version": "macprovider.autotune-release.v1",
        }, indent=2, sort_keys=True) + "\n", "utf-8")


def runtime_revision() -> str:
    """The mlx-swift-lm revision the provider resolves.

    Read through the production pin gate, which fails closed unless
    Package.resolved names the complete SPEC-048 fork tuple (mlx-swift-lm and
    mlx-swift forks at their reviewed revisions), so the rehearsal can never
    stamp an identity the build does not resolve.
    """
    try:
        revision = read_swiftpm_pins.read_production_pins(PACKAGE_RESOLVED).get(
            "mlx_swift_lm_revision"
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read the mlx-swift-lm pin from {PACKAGE_RESOLVED}: {error}")
    if not isinstance(revision, str) or len(revision) != 40:
        raise SystemExit(f"{PACKAGE_RESOLVED} has no mlx-swift-lm revision")
    return revision


def tuple_input() -> dict:
    value = json.loads(FORMAL_TUPLE.read_text())
    entry = value["entry"]
    marker = sha256(b"macprovider native-MTP enablement rehearsal: test-key evidence placeholder\n")
    for key, item in list(entry.items()):
        if item == "0" * 64:
            entry[key] = marker
    entry["runtime_revision"] = runtime_revision()
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


# Kept inside the 90-day window that CLIs built before #1938 still enforce.
ADMISSION_VALIDITY = timedelta(days=80)


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
        # Structural window only (#1938): providers no longer stop running the
        # bank after expires_at, so it shares the admission window instead of
        # forcing a weekly re-sign.
        "expires_at": stamp(issued + ADMISSION_VALIDITY),
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
            "expires_at": stamp(now + ADMISSION_VALIDITY),
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


# MARK: - Inkling 2 Mini (`inkling2_dspark_v1`) shared lab + production builders


def _resolve_inkling_artifact_hash(facts: dict, identity: dict) -> str:
    return str(identity.get("artifact_hash") or facts.get("artifact_hash") or INKLING_TARGET[2])


def inkling_tuple_input(
    facts: dict,
    identity: dict,
    *,
    decode_path_digest: str | None = None,
    proposal_depth: int = 6,
    max_prompt_tokens: int = 32768,
    evidence_digests: dict[str, str] | None = None,
    rehearsal_placeholder_evidence: bool = True,
) -> dict:
    """Single source of truth for the `thinkingmachines/inkling-2-mini`
    (`inkling2_dspark_v1`) native-MTP admission tuple input used by both the
    throwaway lab release and the production `catalog-activate.sh` signing
    inputs."""
    artifact_hash = _resolve_inkling_artifact_hash(facts, identity)
    resolved_runtime_rev = str(facts.get("runtime_revision") or runtime_revision())
    resolved_decode_digest = str(
        decode_path_digest
        or facts.get("decode_path_digest")
        or identity.get("decode_path_digest")
        or current_decode_path_digest()
    )
    resolved_metallib = facts.get("metallib_sha256") or identity.get("metallib_sha256")
    if not isinstance(resolved_metallib, str) or len(resolved_metallib) != 64:
        raise SystemExit("inkling tuple requires a 64-hex metallib_sha256 in facts or CLI identity")
    resolved_hw = str(facts.get("hardware_class") or identity.get("hardware_class") or "")
    if not resolved_hw:
        raise SystemExit("inkling tuple requires hardware_class in facts or CLI identity")
    ram_bytes = int(facts.get("ram_bytes") or identity.get("ram_bytes") or (32 * 1024 * 1024 * 1024))
    quant_info = identity.get("quantization") or {}
    rep_sha = quant_info.get("representation_manifest_sha256")
    if not isinstance(rep_sha, str) or len(rep_sha) != 64:
        raise SystemExit("inkling identity is missing quantization.representation_manifest_sha256")

    marker = sha256(b"macprovider inkling2_dspark_v1 native-MTP rehearsal: test-key evidence placeholder\n")
    ev = dict(evidence_digests or facts.get("evidence_digests") or {})
    default_ev = marker if rehearsal_placeholder_evidence else ("0" * 64)

    def ev_digest(name: str) -> str:
        return str(ev.get(name) or default_ev)

    return {
        "schema_version": sidecar_gen.TUPLE_INPUT_SCHEMA,
        "entry": {
            "model_key": INKLING_MODEL_KEY,
            "artifact_id": INKLING_ARTIFACT_ID,
            "artifact_hash": artifact_hash,
            "hash_algorithm": "macprovider.snapshot-manifest.v1",
            "tokenizer_sha256": identity["tokenizer_sha256"],
            "mtp_manifest_sha256": identity["mtp_manifest_sha256"],
            "mtp_family_adapter": INKLING_FAMILY_ADAPTER,
            "mtp_head_count": 3,
            "mtp_state_class": "hybrid_stageable_rewindable",
            "cache_state_classes": ["hybrid_stageable_rewindable"],
            "decode_path": "native_mtp",
            "decode_path_digest": resolved_decode_digest,
            "metallib_sha256": resolved_metallib,
            "hardware_class": resolved_hw,
            "ram_bytes": ram_bytes,
            "runtime_revision": resolved_runtime_rev,
            "qualified_slots": 1,
            "max_native_active_rows": 1,
            "max_prompt_tokens": max_prompt_tokens,
            "proposal_depth": proposal_depth,
            "complete_window_bytes_by_depth": [1024 * (i + 1) for i in range(proposal_depth + 1)],
            "request_feature_profile": "native_mtp_greedy_text_v1",
            "increase_threshold_ppm": 700000,
            "decrease_threshold_ppm": 400000,
            "max_verification_positions_per_committed_milli": 2500,
            "throughput_delta_ppm": int(facts.get("throughput_delta_ppm", 10000)),
            "benchmark_policy_sha256": ev_digest("benchmark_policy_sha256"),
            "correctness_evidence_sha256": ev_digest("correctness_evidence_sha256"),
            "quality_evidence_sha256": ev_digest("quality_evidence_sha256"),
            "state_rollback_evidence_sha256": ev_digest("state_rollback_evidence_sha256"),
            "batch_evidence_sha256": ev_digest("batch_evidence_sha256"),
            "security_negative_evidence_sha256": ev_digest("security_negative_evidence_sha256"),
            "performance_evidence_sha256": ev_digest("performance_evidence_sha256"),
            "fit_evidence_sha256": ev_digest("fit_evidence_sha256"),
            "ordinary_baseline": {
                "decode_path": "ordinary",
                "runtime_revision": resolved_runtime_rev,
                "artifact_hash": artifact_hash,
                "qualified_slots": 1,
                "measurement_sha256": ev_digest("performance_evidence_sha256"),
                "aggregate_tps_milli": int(facts.get("ordinary_aggregate_tps_milli", 29000)),
            },
            "quantization": {
                "kind": "mlx_oq4e",
                "packed_data_dtype": "uint32",
                "packed_layout": "mlx_array_native_v1",
                "scale_dtype": "bfloat16",
                "scale_layout": "per_block",
                "block_size_elements": 64,
                "alignment_bytes": None,
                "padding_rule": "none",
                "unquantized_exceptions": [],
                "per_layer_exceptions": [],
                "representation_manifest_sha256": rep_sha,
            },
        },
    }


def inkling_projection_entry(
    facts: dict,
    identity: dict,
    *,
    repo_id: str = INKLING_TARGET[0],
    revision: str = INKLING_TARGET[1],
) -> dict:
    """Embedded `checkpoint_mtp` projection entry (`mtp == target`,
    `manifest == target/config.json`, `tokenizer == target/tokenizer.json`)."""
    artifact_hash = _resolve_inkling_artifact_hash(facts, identity)
    target_path = store_path((repo_id, revision, artifact_hash))
    return {
        "target": {"path": target_path, "sha256": artifact_hash},
        "mtp": {"path": target_path, "sha256": artifact_hash},
        "manifest": {"path": f"{target_path}/config.json", "sha256": identity["mtp_manifest_sha256"]},
        "tokenizer": {"path": f"{target_path}/tokenizer.json", "sha256": identity["tokenizer_sha256"]},
    }


def inkling_challenge_entry(
    facts: dict,
    identity: dict,
    *,
    prompt_token_ids: list[int] | None = None,
    max_completion_tokens: int = 32,
    fixed_proposal_depth: int = 6,
    challenge_id: str = "native-mtp-selftest-inkling2-mini-0001",
) -> dict:
    """Challenge bank entry for Inkling's serial native-MTP self-check
    (prompt token IDs drive ordinary vs native greedy parity in-process)."""
    artifact_hash = _resolve_inkling_artifact_hash(facts, identity)
    prompt = list(prompt_token_ids or facts.get("prompt_token_ids") or INKLING_DEFAULT_PROMPT_TOKEN_IDS)
    if not prompt or not all(isinstance(t, int) and not isinstance(t, bool) and t >= 0 for t in prompt):
        raise SystemExit("inkling prompt_token_ids must be a non-empty list of non-negative integers")
    expected_tokens = list(facts.get("expected_token_ids") or [0])
    expected_token_bytes = ("[" + ",".join(str(t) for t in expected_tokens) + "]").encode("utf-8")
    expected_counters = dict(
        facts.get("expected_counters")
        or {"accepted": 0, "rejected": 0, "bonus": 0, "committed": max(0, len(expected_tokens) - 1)}
    )
    return {
        "challenge_id": challenge_id,
        "model_id": INKLING_MODEL_KEY,
        "model_hash": artifact_hash,
        "tokenizer_sha256": identity["tokenizer_sha256"],
        "artifact_sha256": artifact_hash,
        "mtp_manifest_sha256": identity["mtp_manifest_sha256"],
        "prompt_token_ids": prompt,
        "max_completion_tokens": max_completion_tokens,
        "fixed_proposal_depth": fixed_proposal_depth,
        "expected_token_ids": expected_tokens,
        "expected_token_id_sha256": sha256(expected_token_bytes),
        "expected_terminal_reason": "length",
        "expected_counters": expected_counters,
        "expected_committed_state_sha256": str(
            facts.get("expected_committed_state_sha256")
            or sha256(b"inkling2-dspark-v1-serial-selfcheck-state\n")
        ),
    }


def inkling_challenge_bank(
    release_id: str,
    issued: datetime,
    signer_key_id: str,
    entries: list[dict],
) -> bytes:
    return canonical({
        "schema_version": "macprovider.native-mtp-challenge-bank.v1",
        "release_id": release_id,
        "issued_at": stamp(issued),
        "expires_at": stamp(issued + ADMISSION_VALIDITY),
        "signer_key_id": signer_key_id,
        "entries": entries,
    })


def inkling_cb_policy_entry(
    facts: dict,
    identity: dict,
    *,
    evidence_id: str = "inkling2-native-mtp-cb-rehearsal-test-key",
    rollout: str = "canary",
) -> dict:
    artifact_hash = _resolve_inkling_artifact_hash(facts, identity)
    cb_tok = facts.get("cb_tokenizer_sha256") or identity.get("cb_tokenizer_sha256") or facts.get("tokenizer_sha256")
    chat_tmpl = facts.get("chat_template_sha256") or identity.get("chat_template_sha256")
    if not isinstance(cb_tok, str) or len(cb_tok) != 64:
        raise SystemExit("inkling CB entry requires 64-hex cb_tokenizer_sha256 / tokenizer_sha256")
    if not isinstance(chat_tmpl, str) or len(chat_tmpl) != 64:
        raise SystemExit("inkling CB entry requires 64-hex chat_template_sha256")
    return {
        "model_key": INKLING_MODEL_KEY,
        "model_id": INKLING_MODEL_KEY,
        "model_sha256": artifact_hash,
        "tokenizer_sha256": cb_tok,
        "chat_template_sha256": chat_tmpl,
        "cache_class": "mixed",
        "kv_dtype": "fp16",
        "requires_moe": True,
        "hardware_class": str(facts.get("hardware_class") or identity.get("hardware_class")),
        "metallib_sha256": str(facts.get("metallib_sha256") or identity.get("metallib_sha256")),
        "kernel_identifier": str(facts["kernel_identifier"]),
        "rollout": rollout,
        "cached_turns_accepted": False,
        "provenance": {
            "source": "operator_review",
            "status": "qualified",
            "evidence_id": evidence_id,
            "package_manifest_sha256": str(facts["binary_sha256"]),
            "studio_campaign_sha256": sha256(evidence_id.encode("utf-8")),
            "provider_cli_version": str(facts["provider_cli_version"]),
            "live_executable_cdhash": str(facts["live_executable_cdhash"]),
        },
    }


def resolve_inkling_identity(
    *,
    identity: dict | None = None,
    cli_bin: pathlib.Path | str | None = None,
    model_dir: pathlib.Path | None = None,
    skip_artifact_hash: bool = False,
) -> dict:
    if identity is not None:
        return identity
    if model_dir is None:
        raise SystemExit(
            "inkling requires --model-dir (to invoke `models native-mtp-identity --model-dir <dir> --json`) "
            "or --identity-json"
        )
    return probe_model_identity(
        cli_bin or "macprovider-cli",
        model_dir,
        skip_artifact_hash=skip_artifact_hash,
    )


def build_inkling(
    facts: dict,
    work: pathlib.Path,
    now: datetime,
    *,
    identity: dict | None = None,
    cli_bin: pathlib.Path | str | None = None,
    model_dir: pathlib.Path | None = None,
    skip_artifact_hash: bool = False,
    decode_path_digest: str | None = None,
    prompt_token_ids: list[int] | None = None,
    key_id: str = INKLING_KEY_ID,
    trusted_keys_path: pathlib.Path = TRUSTED_KEYS_PATH,
) -> dict:
    """Builds a throwaway-key static-feed release + 24h revocation slots for
    `thinkingmachines/inkling-2-mini` (`inkling2_dspark_v1`)."""
    missing = INKLING_FACT_KEYS - facts.keys()
    if missing:
        raise SystemExit(f"facts file is missing {sorted(missing)}")
    resolved_identity = resolve_inkling_identity(
        identity=identity,
        cli_bin=cli_bin,
        model_dir=model_dir,
        skip_artifact_hash=skip_artifact_hash,
    )
    resolved_decode_digest = str(
        decode_path_digest
        or facts.get("decode_path_digest")
        or resolved_identity.get("decode_path_digest")
        or current_decode_path_digest()
    )
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    os.chmod(work, 0o700)
    openssl = catalog_release.openssl_executable()
    release_id = f"published-{now:%Y-%m-%d}-inkling2-native-mtp-rehearsal-v1"
    generated_at = stamp(now)

    tuple_obj = inkling_tuple_input(
        facts,
        resolved_identity,
        decode_path_digest=resolved_decode_digest,
        rehearsal_placeholder_evidence=True,
    )
    proj_entry = inkling_projection_entry(facts, resolved_identity)
    manifest = sidecar_gen.build_projection({INKLING_MODEL_KEY: proj_entry})
    challenge = inkling_challenge_entry(facts, resolved_identity, prompt_token_ids=prompt_token_ids)
    bank = inkling_challenge_bank(release_id, now, key_id, [challenge])
    cb_source = {
        "schema_version": catalog_release.CB_POLICY_SOURCE_SCHEMA,
        "entries": [inkling_cb_policy_entry(facts, resolved_identity)],
    }

    with RehearsalRelease(
        work / "repo",
        openssl,
        key_id=key_id,
        trusted_keys_path=trusted_keys_path,
        preserve_current_catalog=True,
    ) as release:
        catalog = release.catalog
        release.bump(f"published-{now:%Y-%m-%d}-inkling2-rehearsal-activation-v1", stamp(now - timedelta(minutes=1)))
        release.cut(activate_artifact_feed=True)
        previous = release.stage(work / "previous")

        (catalog / "native-mtp-artifact-manifest.json").write_bytes(manifest)
        (catalog / "native-mtp-selftest-bank.json").write_bytes(bank)
        (catalog / "native-mtp-admission-tuple.json").write_text(json.dumps(tuple_obj, indent=2) + "\n")
        (catalog / "native-mtp-admission-release.json").write_text(json.dumps({
            "schema_version": "macprovider.native-mtp-admission-release-input.v1",
            "release_id": release_id,
            "issued_at": generated_at,
            "expires_at": stamp(now + ADMISSION_VALIDITY),
            "signer_key_id": key_id,
            "challenge_bank_signer_key_id": key_id,
            "revocation_signer_key_id": key_id,
            "provider_decode_path_digest": resolved_decode_digest,
            "entry": {
                "artifact_manifest_sha256": sha256(manifest),
                "provider_revision": facts["source_commit"],
                "source_commit": facts["source_commit"],
                "reproducible_build_sha256": facts["binary_sha256"],
                "live_executable_cdhash": facts["live_executable_cdhash"],
                "challenge_bank_sha256": sha256(bank),
            },
        }, indent=2) + "\n")
        (catalog / "continuous-batching-policy-source.json").write_text(
            json.dumps(cb_source, indent=2, sort_keys=True) + "\n"
        )
        saved = {name: getattr(catalog_release, name)
                 for name in ("NATIVE_MTP_TUPLE_INPUT_PATH", "NATIVE_MTP_RELEASE_INPUT_PATH")}
        catalog_release.NATIVE_MTP_TUPLE_INPUT_PATH = catalog / "native-mtp-admission-tuple.json"
        catalog_release.NATIVE_MTP_RELEASE_INPUT_PATH = catalog / "native-mtp-admission-release.json"
        try:
            release.bump(release_id, generated_at)
            catalog_release.generate(key_id, previous_release_dir=previous)
            release.sign()
            for name in ("native-mtp-admission.json", "native-mtp-selftest-bank.json"):
                release.sign_into(release.static, name, (release.static / name).read_bytes())
            catalog_release.generate(key_id, previous_release_dir=previous)
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
        sidecar_ident = catalog_release.NATIVE_MTP_SIDECAR_GENERATOR.identity(sidecar)

    slot_start = now.replace(minute=now.minute - now.minute % 10, second=0, microsecond=0)
    subprocess.run([
        sys.executable, str(ROOT / "scripts/native_mtp_revocation_slots.py"), "build",
        "--key-file", str(release.seed_file), "--key-id", key_id,
        "--revoked", str(CATALOG / "native-mtp-revocations-source.json"),
        "--start", stamp(slot_start), "--days", "1", "--out", str(work / "revocations"),
    ], check=True, env=dict(os.environ, OPENSSL_BIN=openssl))
    subprocess.run([
        sys.executable, str(ROOT / "scripts/native_mtp_revocation_slots.py"), "verify",
        "--dir", str(work / "revocations"), "--key-id", key_id, "--public-key-base64", release.public_key_base64,
    ], check=True, env=dict(os.environ, OPENSSL_BIN=openssl))
    summary = {
        "schema_version": "macprovider.native-mtp-rehearsal-release.v1",
        "model_key": INKLING_MODEL_KEY,
        "mtp_family_adapter": INKLING_FAMILY_ADAPTER,
        "release_id": release_id,
        "generated_at": generated_at,
        "key_id": key_id,
        "public_key_base64": release.public_key_base64,
        "decode_path_digest": resolved_decode_digest,
        "facts": facts,
        "observed_identity": resolved_identity,
        "sidecar_sha256": sidecar_ident["sidecar_sha256"],
        "native_mtp_admission_tuple_sha256": sidecar_ident["native_mtp_admission_tuple_sha256"],
        "artifact_manifest_sha256": sha256(manifest),
        "challenge_bank_sha256": sha256(bank),
        "catalog_files": {p.name: sha256(p.read_bytes()) for p in sorted((work / "catalog").iterdir())},
        "revocation_slots": len(list((work / "revocations").glob("*.json"))),
    }
    (work / "rehearsal-release.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return summary


def build_inkling_production_inputs(
    facts: dict,
    out_dir: pathlib.Path,
    now: datetime,
    *,
    identity: dict | None = None,
    cli_bin: pathlib.Path | str | None = None,
    model_dir: pathlib.Path | None = None,
    skip_artifact_hash: bool = False,
    decode_path_digest: str | None = None,
    prompt_token_ids: list[int] | None = None,
    catalog_dir: pathlib.Path = CATALOG,
    signer_key_id: str = "streamvc-autotune-static-v5",
    release_id: str | None = None,
    evidence_digests: dict[str, str] | None = None,
) -> dict:
    """Emits the merged production signing inputs for `thinkingmachines/inkling-2-mini`
    (`inkling2_dspark_v1`) from the exact same builders as `build_inkling`,
    ready to be copied into `phase3-binary/catalog/autotune/` and signed via
    `scripts/ops/catalog-activate.sh`."""
    missing = INKLING_FACT_KEYS - facts.keys()
    if missing:
        raise SystemExit(f"facts file is missing {sorted(missing)}")
    resolved_identity = resolve_inkling_identity(
        identity=identity,
        cli_bin=cli_bin,
        model_dir=model_dir,
        skip_artifact_hash=skip_artifact_hash,
    )
    resolved_decode_digest = str(
        decode_path_digest
        or facts.get("decode_path_digest")
        or resolved_identity.get("decode_path_digest")
        or current_decode_path_digest()
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    generated_at = stamp(now)
    resolved_release_id = release_id or f"published-{now:%Y-%m-%d}-inkling2-native-mtp-v1"

    # 1. Merge native-mtp-admission-tuple.json
    existing_tuples = json.loads((catalog_dir / "native-mtp-admission-tuple.json").read_text("utf-8"))
    if isinstance(existing_tuples, dict):
        existing_tuples = [existing_tuples]
    kept_tuples = [t for t in existing_tuples if t.get("entry", {}).get("model_key") != INKLING_MODEL_KEY]
    inkling_tuple = inkling_tuple_input(
        facts,
        resolved_identity,
        decode_path_digest=resolved_decode_digest,
        evidence_digests=evidence_digests,
        rehearsal_placeholder_evidence=False,
    )
    merged_tuples = kept_tuples + [inkling_tuple]
    merged_tuples.sort(key=lambda t: (
        t["entry"]["model_key"],
        t["entry"]["artifact_id"],
        t["entry"]["hardware_class"],
    ))

    # 2. Merge native-mtp-artifact-manifest.json (v2 keyed by model_key)
    existing_proj = json.loads((catalog_dir / "native-mtp-artifact-manifest.json").read_text("utf-8"))
    if existing_proj.get("schema_version") == sidecar_gen.PROJECTION_V2_SCHEMA:
        models_map = dict(existing_proj["models"])
    else:
        raise SystemExit("expected v2 projection manifest in committed catalog")
    models_map[INKLING_MODEL_KEY] = inkling_projection_entry(facts, resolved_identity)
    merged_manifest = sidecar_gen.build_projection(models_map)

    # 3. Merge native-mtp-selftest-bank.json
    existing_bank = json.loads((catalog_dir / "native-mtp-selftest-bank.json").read_text("utf-8"))
    kept_challenges = [e for e in existing_bank.get("entries", []) if e.get("model_id") != INKLING_MODEL_KEY]
    inkling_challenge = inkling_challenge_entry(facts, resolved_identity, prompt_token_ids=prompt_token_ids)
    merged_bank = inkling_challenge_bank(
        resolved_release_id,
        now,
        signer_key_id,
        kept_challenges + [inkling_challenge],
    )

    # 4. Build native-mtp-admission-release.json
    release_input = {
        "schema_version": sidecar_gen.RELEASE_INPUT_SCHEMA,
        "release_id": resolved_release_id,
        "issued_at": generated_at,
        "expires_at": stamp(now + ADMISSION_VALIDITY),
        "signer_key_id": signer_key_id,
        "challenge_bank_signer_key_id": signer_key_id,
        "revocation_signer_key_id": signer_key_id,
        "provider_decode_path_digest": resolved_decode_digest,
        "entry": {
            "artifact_manifest_sha256": sha256(merged_manifest),
            "provider_revision": facts["source_commit"],
            "source_commit": facts["source_commit"],
            "reproducible_build_sha256": facts["binary_sha256"],
            "live_executable_cdhash": facts["live_executable_cdhash"],
            "challenge_bank_sha256": sha256(merged_bank),
        },
    }

    # 5. Merge continuous-batching-policy-source.json
    existing_cb = json.loads((catalog_dir / "continuous-batching-policy-source.json").read_text("utf-8"))
    kept_cb = [
        e for e in existing_cb.get("entries", [])
        if not (e.get("model_key") == INKLING_MODEL_KEY and e.get("hardware_class") == facts["hardware_class"])
    ]
    inkling_cb = inkling_cb_policy_entry(
        facts,
        resolved_identity,
        evidence_id=str(facts.get("cb_evidence_id") or "inkling2-native-mtp-cb-production"),
    )
    merged_cb = {
        "schema_version": catalog_release.CB_POLICY_SOURCE_SCHEMA,
        "entries": kept_cb + [inkling_cb],
    }

    (out_dir / "native-mtp-admission-tuple.json").write_text(
        json.dumps(merged_tuples, indent=2, sort_keys=True) + "\n", "utf-8"
    )
    (out_dir / "native-mtp-artifact-manifest.json").write_bytes(merged_manifest)
    (out_dir / "native-mtp-selftest-bank.json").write_bytes(merged_bank)
    (out_dir / "native-mtp-admission-release.json").write_text(
        json.dumps(release_input, indent=2, sort_keys=True) + "\n", "utf-8"
    )
    (out_dir / "continuous-batching-policy-source.json").write_text(
        json.dumps(merged_cb, indent=2, sort_keys=True) + "\n", "utf-8"
    )

    # Validate sidecar buildability immediately whenever real evidence digests are supplied.
    has_placeholder = any(v == "0" * 64 for v in inkling_tuple["entry"].values() if isinstance(v, str))
    sidecar_ident = None
    if not has_placeholder:
        sidecar_bytes = sidecar_gen.build(merged_tuples, release_input)
        sidecar_ident = sidecar_gen.identity(sidecar_bytes)

    return {
        "schema_version": "macprovider.native-mtp-production-inputs.v1",
        "model_key": INKLING_MODEL_KEY,
        "mtp_family_adapter": INKLING_FAMILY_ADAPTER,
        "release_id": resolved_release_id,
        "signer_key_id": signer_key_id,
        "decode_path_digest": resolved_decode_digest,
        "artifact_manifest_sha256": sha256(merged_manifest),
        "challenge_bank_sha256": sha256(merged_bank),
        "sidecar_identity": sidecar_ident,
        "pending_evidence_placeholders": has_placeholder,
        "out_dir": str(out_dir),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--facts", type=pathlib.Path, required=True)
    parser.add_argument("--work", type=pathlib.Path, required=True)
    parser.add_argument("--profile", choices=("qwen-a3b", "inkling2"), default="qwen-a3b")
    parser.add_argument("--mode", choices=("rehearsal", "production-inputs"), default="rehearsal")
    parser.add_argument("--cli-bin", type=str, default="macprovider-cli")
    parser.add_argument("--model-dir", type=pathlib.Path, default=None)
    parser.add_argument("--identity-json", type=pathlib.Path, default=None)
    parser.add_argument("--skip-artifact-hash", action="store_true")
    parser.add_argument("--decode-path-digest", type=str, default=None)
    parser.add_argument("--prompt-token-ids", type=str, default=None,
                        help="Comma-separated prompt token IDs for the Inkling serial self-check challenge.")
    parser.add_argument("--key-id", type=str, default=None)
    parser.add_argument("--release-id", type=str, default=None)
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc).replace(microsecond=0)
    facts = json.loads(args.facts.read_text("utf-8"))
    if args.profile == "qwen-a3b":
        if args.mode != "rehearsal":
            raise SystemExit("--mode production-inputs is supported for --profile inkling2")
        summary = build(facts, args.work, now)
        print(json.dumps({k: summary[k] for k in ("release_id", "key_id", "sidecar_sha256", "revocation_slots")}))
        return 0

    identity = json.loads(args.identity_json.read_text("utf-8")) if args.identity_json else None
    prompt_tokens = (
        [int(tok.strip()) for tok in args.prompt_token_ids.split(",") if tok.strip()]
        if args.prompt_token_ids
        else None
    )
    if args.mode == "production-inputs":
        summary = build_inkling_production_inputs(
            facts,
            args.work,
            now,
            identity=identity,
            cli_bin=args.cli_bin,
            model_dir=args.model_dir,
            skip_artifact_hash=args.skip_artifact_hash,
            decode_path_digest=args.decode_path_digest,
            prompt_token_ids=prompt_tokens,
            signer_key_id=args.key_id or "streamvc-autotune-static-v5",
            release_id=args.release_id,
        )
        print(json.dumps(summary, sort_keys=True))
        return 0

    summary = build_inkling(
        facts,
        args.work,
        now,
        identity=identity,
        cli_bin=args.cli_bin,
        model_dir=args.model_dir,
        skip_artifact_hash=args.skip_artifact_hash,
        decode_path_digest=args.decode_path_digest,
        prompt_token_ids=prompt_tokens,
        key_id=args.key_id or INKLING_KEY_ID,
    )
    print(json.dumps({k: summary[k] for k in ("release_id", "key_id", "sidecar_sha256", "revocation_slots")}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
