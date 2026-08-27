#!/usr/bin/env python3
"""Build, sign, and strictly validate a macprovider compatibility-set manifest."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile


ENVELOPE_SCHEMA = "macprovider.compatibility-set-envelope.v1"
PAYLOAD_SCHEMA = "macprovider.compatibility-set.v1"
SIGNATURE_ALGORITHM = "ecdsa-p256-sha256"
DEFAULT_KEY_ID = "macprovider-release-p256-v1"
MAX_INPUT_BYTES = 1024 * 1024
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
TAG = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")

# Minimum provider-CLI version whose manifest parser ACCEPTS a given
# provider_cli.designated_identifier. A release whose declared minimum-supported
# client floor is BELOW the value here cannot be installed by clients in the gap:
# they reject the compatibility-set manifest at parse time and strand with no
# self-heal path. The Malibu rebrand (identifier tolerance landed in v1.8.95,
# commit 9c78c988) orphaned every <=1.8.94 client this way. Keep this table in
# lockstep with the client parser's accepted-identifier tolerance in
# phase3-binary/Sources/macprovider-cli/CompatibilitySetManifest.swift.
CLIENT_IDENTIFIER_FLOORS = {
    "live.malibu.provider.cli": (1, 8, 95),
    "live.streamvc.macprovider.cli": (0, 0, 0),
}


def parse_semver(value: str) -> tuple[int, int, int]:
    """Parse 'X.Y.Z' or 'vX.Y.Z' into a comparable tuple; raise on malformed."""
    text = value[1:] if value.startswith("v") else value
    if not SEMVER.fullmatch(text):
        fail(f"malformed version {value!r}: expected X.Y.Z or vX.Y.Z")
    major, minor, patch = (int(part) for part in text.split("."))
    return (major, minor, patch)


CATALOG_FILES = (
    "release.json",
    "trusted-keys.json",
    "tier2-catalog.json",
    "autotune-candidates.json",
    "autotune-candidates.json.sig",
    "demand-rank.json",
    "demand-rank.json.sig",
    "rate-card.json",
    "rate-card.json.sig",
)
LOCAL_ARTIFACT_FILES = {
    "install_contract": "install.sh",
    "provider_plist_template": "provider-launch-agent.plist.template",
    "updater_metadata": "updater-rollback.json",
    "watchdog_plist_template": "watchdog-launch-agent.plist.template",
    "watchdog_script": "watchdog.sh",
}
ROLLBACK_MEMBERS = (
    "catalog",
    "launchd",
    "malibu_app",
    "provider_cli",
    "release_resources",
    "updater_rollback",
    "watchdog",
)
REQUIRED_EXTERNAL_GATES = ("coordinator_admission",)
PRESERVED_STATE_INVARIANTS = ("credentials", "identity", "operator_config")
ROLLBACK_PLAN_SCHEMA = "macprovider.compatibility-set-rollback-plan.v1"
ACTIVATION_CHECKPOINTS = (
    "owned_resources_removed",
    "owned_resources_activated",
    "watchdog_script_activated",
    "provider_plist_activated",
    "watchdog_plist_activated",
    "binary_activated",
    "malibu_app_activated",
)
ROLLBACK_ORDER = (
    "release_resources",
    "catalog",
    "updater_rollback",
    "watchdog",
    "launchd",
    "malibu_app",
    "provider_cli",
)


class ManifestError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ManifestError(message)


def exact_keys(value: dict, expected: set[str], label: str) -> None:
    actual = set(value)
    missing = expected - actual
    unknown = actual - expected
    if missing:
        fail(f"{label}: missing fields {sorted(missing)}")
    if unknown:
        fail(f"{label}: unknown fields {sorted(unknown)}")


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def strict_json(data: bytes, label: str, require_canonical: bool = True) -> dict:
    def reject_pairs(pairs: list[tuple[str, object]]) -> dict:
        result: dict = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label}: duplicate object key {key!r}")
            result[key] = value
        return result

    def reject_constant(value: str) -> object:
        fail(f"{label}: non-standard numeric constant {value}")

    def reject_float(value: str) -> object:
        fail(f"{label}: floating-point values are forbidden")

    try:
        text = data.decode("utf-8")
        decoder = json.JSONDecoder(
            object_pairs_hook=reject_pairs,
            parse_constant=reject_constant,
            parse_float=reject_float,
        )
        value, end = decoder.raw_decode(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label}: invalid JSON: {exc}")
    if text[end:].strip():
        fail(f"{label}: trailing JSON data")
    if not isinstance(value, dict):
        fail(f"{label}: top level must be an object")
    if require_canonical and data != canonical_bytes(value):
        fail(f"{label}: JSON must use canonical sorted compact encoding with one trailing newline")
    return value


def read_regular(path: pathlib.Path, label: str) -> bytes:
    try:
        info = path.lstat()
    except OSError as exc:
        fail(f"{label}: cannot stat {path}: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(f"{label}: must be a regular non-symlink file: {path}")
    if info.st_size > MAX_INPUT_BYTES:
        fail(f"{label}: exceeds {MAX_INPUT_BYTES} bytes")
    try:
        return path.read_bytes()
    except OSError as exc:
        fail(f"{label}: cannot read {path}: {exc}")


def atomic_write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.is_symlink():
        fail(f"output must not be a symlink: {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def string(value: object, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value or value.strip() != value:
        fail(f"{label}: must be a non-empty trimmed string")
    if pattern is not None and not pattern.fullmatch(value):
        fail(f"{label}: invalid value {value!r}")
    return value


def integer(value: object, label: str, minimum: int, maximum: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not minimum <= value <= maximum:
        fail(f"{label}: must be an integer in {minimum}...{maximum}")
    return value


def boolean(value: object, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label}: must be a boolean")
    return value


def validate_rollout(value: object) -> dict:
    if not isinstance(value, dict):
        fail("coordinator_admission.rollout: must be an object")
    exact_keys(value, {"bridge_duration_seconds", "enforce_provider_admission", "mode"}, "coordinator_admission.rollout")
    mode = string(value["mode"], "coordinator_admission.rollout.mode")
    enforce = boolean(value["enforce_provider_admission"], "coordinator_admission.rollout.enforce_provider_admission")
    duration = integer(value["bridge_duration_seconds"], "coordinator_admission.rollout.bridge_duration_seconds", 0, 86400)
    expected = {
        "bridge_required": (False, 86400),
        "strict_post_migration": (True, 0),
    }.get(mode)
    if expected is None or (enforce, duration) != expected:
        fail("coordinator_admission.rollout: policy fields are inconsistent")
    return value


def validate_catalog(value: object) -> None:
    if not isinstance(value, dict):
        fail("components.catalog: must be an object")
    exact_keys(value, {"activation", "files", "policy_version", "release_id", "schema_version"}, "components.catalog")
    if value["activation"] != "local":
        fail("components.catalog.activation: unsupported value")
    if value["schema_version"] != "macprovider.autotune-release.v1":
        fail("components.catalog.schema_version: unsupported value")
    string(value["release_id"], "components.catalog.release_id")
    string(value["policy_version"], "components.catalog.policy_version")
    files = value["files"]
    if not isinstance(files, dict):
        fail("components.catalog.files: must be an object")
    exact_keys(files, set(CATALOG_FILES), "components.catalog.files")
    for name, digest in files.items():
        string(digest, f"components.catalog.files.{name}", HEX64)


def validate_artifact(value: object, expected_path: str, label: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{label}: must be an object")
    exact_keys(value, {"path", "sha256"}, label)
    if value["path"] != expected_path:
        fail(f"{label}.path: unsupported value")
    string(value["sha256"], f"{label}.sha256", HEX64)
    return value


def validate_rollback_plan(data: bytes) -> dict:
    value = strict_json(data, "updater rollback plan")
    exact_keys(
        value,
        {
            "activation_checkpoints",
            "metadata_version",
            "protocol",
            "rollback_order",
            "rollback_scope",
            "schema_version",
        },
        "updater rollback plan",
    )
    expected = {
        "activation_checkpoints": list(ACTIVATION_CHECKPOINTS),
        "metadata_version": 1,
        "protocol": "macprovider.compatibility-set-transaction.v1",
        "rollback_order": list(ROLLBACK_ORDER),
        "rollback_scope": "all_activated_local_members",
        "schema_version": ROLLBACK_PLAN_SCHEMA,
    }
    if value != expected:
        fail("updater rollback plan: unsupported execution contract")
    return value


def validate_payload(value: object) -> dict:
    if not isinstance(value, dict):
        fail("signed: must be an object")
    exact_keys(
        value,
        {"artifact_binding", "compatibility_set_id", "components", "release", "schema_version", "transaction"},
        "signed",
    )
    if value["schema_version"] != PAYLOAD_SCHEMA:
        fail("signed.schema_version: unsupported value")

    release = value["release"]
    if not isinstance(release, dict):
        fail("signed.release: must be an object")
    exact_keys(release, {"commit", "repository", "tag", "version"}, "signed.release")
    repository = string(release["repository"], "signed.release.repository", REPOSITORY)
    tag = string(release["tag"], "signed.release.tag", TAG)
    version = string(release["version"], "signed.release.version", SEMVER)
    commit = string(release["commit"], "signed.release.commit", HEX40)
    if version != tag.removeprefix("v"):
        fail("signed.release.version: must equal the release tag without v")
    if value["compatibility_set_id"] != f"{repository}:{tag}@{commit}":
        fail("signed.compatibility_set_id: does not match the release identity")

    binding = value["artifact_binding"]
    if not isinstance(binding, dict):
        fail("signed.artifact_binding: must be an object")
    exact_keys(binding, {"embedded_container_hashes", "mode"}, "signed.artifact_binding")
    if binding != {
        "embedded_container_hashes": "excluded_to_avoid_self_reference",
        "mode": "signed_release_checksums",
    }:
        fail("signed.artifact_binding: unsupported binding policy")

    components = value["components"]
    if not isinstance(components, dict):
        fail("signed.components: must be an object")
    exact_keys(
        components,
        {"catalog", "coordinator_admission", "launchd", "malibu_app", "provider_cli", "updater_rollback", "watchdog"},
        "signed.components",
    )
    validate_catalog(components["catalog"])

    malibu = components["malibu_app"]
    if not isinstance(malibu, dict):
        fail("components.malibu_app: must be an object")
    exact_keys(
        malibu,
        {"activation", "bundle_id", "compatibility_handoff", "minimum_status_reader", "version"},
        "components.malibu_app",
    )
    if malibu["bundle_id"] != "tech.malibu.app":
        fail("components.malibu_app.bundle_id: unsupported value")
    if malibu["activation"] != "cli_owned_if_installed" or malibu["compatibility_handoff"] != {
        "delivery": "signed_dmg_transaction_member",
        "embedded_manifest_path": "Contents/Resources/compatibility-set.json",
        "provider_mutation": "forbidden",
        "reader_compatibility": "backward_compatible",
    }:
        fail("components.malibu_app: unsupported artifact handoff")
    string(malibu["version"], "components.malibu_app.version", SEMVER)
    integer(malibu["minimum_status_reader"], "components.malibu_app.minimum_status_reader", 1, 1)

    cli = components["provider_cli"]
    if not isinstance(cli, dict):
        fail("components.provider_cli: must be an object")
    exact_keys(cli, {"activation", "designated_identifier", "platform", "status_contract", "version"}, "components.provider_cli")
    if cli["activation"] != "local" or cli["designated_identifier"] != "live.malibu.provider.cli" or cli["platform"] != "darwin-arm64" or cli["status_contract"] != "macprovider.local-status.v1":
        fail("components.provider_cli: unsupported executable identity or contract")
    string(cli["version"], "components.provider_cli.version", SEMVER)

    launchd = components["launchd"]
    if not isinstance(launchd, dict):
        fail("components.launchd: must be an object")
    exact_keys(launchd, {"activation", "contract", "install_contract", "label", "plist_template"}, "components.launchd")
    if launchd.get("activation") != "local" or launchd.get("contract") != "macprovider.launch-agent.v1" or launchd.get("label") != "live.malibu.provider":
        fail("components.launchd: unsupported service contract")
    validate_artifact(launchd["install_contract"], "compatibility-set-local/install.sh", "components.launchd.install_contract")
    validate_artifact(
        launchd["plist_template"],
        "compatibility-set-local/provider-launch-agent.plist.template",
        "components.launchd.plist_template",
    )

    watchdog = components["watchdog"]
    if not isinstance(watchdog, dict):
        fail("components.watchdog: must be an object")
    exact_keys(watchdog, {"activation", "contract", "monitored_label", "plist_template", "script", "service_label"}, "components.watchdog")
    if (
        watchdog.get("activation") != "local"
        or watchdog.get("contract") != "macprovider.exact-service-pid-watchdog.v1"
        or watchdog.get("monitored_label") != "live.malibu.provider"
        or watchdog.get("service_label") != "live.malibu.provider-watchdog"
    ):
        fail("components.watchdog: unsupported supervision contract")
    validate_artifact(watchdog["script"], "compatibility-set-local/watchdog.sh", "components.watchdog.script")
    validate_artifact(
        watchdog["plist_template"],
        "compatibility-set-local/watchdog-launch-agent.plist.template",
        "components.watchdog.plist_template",
    )

    admission = components["coordinator_admission"]
    if not isinstance(admission, dict):
        fail("components.coordinator_admission: must be an object")
    exact_keys(admission, {"activation", "handshake", "policy_version", "rollout", "scope", "version"}, "components.coordinator_admission")
    if (
        admission["activation"] != "required_remote_gate"
        or admission["handshake"] != "accepted_set_echo_v1"
        or admission["scope"] != "remote_coordinator_policy"
        or admission["policy_version"] != "provider-admission.v1"
        or admission["version"] != version
    ):
        fail("components.coordinator_admission: unsupported version")
    validate_rollout(admission["rollout"])

    updater = components["updater_rollback"]
    if not isinstance(updater, dict):
        fail("components.updater_rollback: must be an object")
    exact_keys(updater, {"activation", "metadata", "metadata_version", "protocol"}, "components.updater_rollback")
    if updater["activation"] != "local":
        fail("components.updater_rollback.activation: unsupported value")
    integer(updater["metadata_version"], "components.updater_rollback.metadata_version", 1, 1)
    if updater["protocol"] != "macprovider.compatibility-set-transaction.v1":
        fail("components.updater_rollback.protocol: unsupported value")
    validate_artifact(
        updater["metadata"],
        "compatibility-set-local/updater-rollback.json",
        "components.updater_rollback.metadata",
    )

    transaction = value["transaction"]
    if not isinstance(transaction, dict):
        fail("signed.transaction: must be an object")
    exact_keys(
        transaction,
        {"activation", "autoupdate_scope", "maintenance_lease", "membership", "preflight", "readiness_proof", "rollback"},
        "signed.transaction",
    )
    if transaction["activation"] != "crash_recoverable_local_activation_group" or transaction["autoupdate_scope"] != "compatibility_cohort":
        fail("signed.transaction: unsupported activation or autoupdate scope")
    membership = transaction["membership"]
    if not isinstance(membership, dict):
        fail("signed.transaction.membership: must be an object")
    exact_keys(membership, {"local_activation_group", "preserved_state_invariants", "required_external_gates"}, "signed.transaction.membership")
    if (
        membership["local_activation_group"] != list(ROLLBACK_MEMBERS)
        or membership["required_external_gates"] != list(REQUIRED_EXTERNAL_GATES)
        or membership["preserved_state_invariants"] != list(PRESERVED_STATE_INVARIANTS)
    ):
        fail("signed.transaction.membership: unsupported member classification")
    lease = transaction["maintenance_lease"]
    if not isinstance(lease, dict):
        fail("signed.transaction.maintenance_lease: must be an object")
    exact_keys(lease, {"maximum_seconds", "protocol"}, "signed.transaction.maintenance_lease")
    if lease["protocol"] != "macprovider.maintenance-lease.v1":
        fail("signed.transaction.maintenance_lease.protocol: unsupported value")
    integer(lease["maximum_seconds"], "signed.transaction.maintenance_lease.maximum_seconds", 60, 1200)
    if transaction["preflight"] != {"mode": "exact_target_set", "remote_gate": "coordinator_acceptance_required"}:
        fail("signed.transaction.preflight: unsupported value")
    proof = transaction["readiness_proof"]
    if not isinstance(proof, dict):
        fail("signed.transaction.readiness_proof: must be an object")
    exact_keys(proof, {"compatibility_set_echo", "contract", "network_state", "timeout_seconds"}, "signed.transaction.readiness_proof")
    if proof["compatibility_set_echo"] != "exact" or proof["contract"] != "macprovider.local-status.v1" or proof["network_state"] != "buyer_serving":
        fail("signed.transaction.readiness_proof: unsupported proof")
    integer(proof["timeout_seconds"], "signed.transaction.readiness_proof.timeout_seconds", 60, 1200)
    rollback = transaction["rollback"]
    if not isinstance(rollback, dict):
        fail("signed.transaction.rollback: must be an object")
    exact_keys(rollback, {"members", "mode"}, "signed.transaction.rollback")
    if rollback["mode"] != "local_activation_group" or rollback["members"] != list(ROLLBACK_MEMBERS):
        fail("signed.transaction.rollback: must cover the canonical ordered member set")
    return value


def validate_payload_artifacts(payload: dict, payload_directory: pathlib.Path) -> None:
    if not payload_directory.is_dir() or payload_directory.is_symlink():
        fail(f"payload directory must be a non-symlink directory: {payload_directory}")
    components = payload["components"]
    descriptors = (
        components["launchd"]["install_contract"],
        components["launchd"]["plist_template"],
        components["updater_rollback"]["metadata"],
        components["watchdog"]["script"],
        components["watchdog"]["plist_template"],
    )
    local_directory = payload_directory / "compatibility-set-local"
    expected_names = set(LOCAL_ARTIFACT_FILES.values())
    try:
        actual_names = {entry.name for entry in local_directory.iterdir()}
    except OSError as exc:
        fail(f"payload local-artifact directory cannot be read: {exc}")
    if actual_names != expected_names:
        fail(f"payload local-artifact members mismatch: got {sorted(actual_names)}, expected {sorted(expected_names)}")
    for descriptor in descriptors:
        path = payload_directory / descriptor["path"]
        artifact_data = read_regular(path, f"payload artifact {descriptor['path']}")
        actual = hashlib.sha256(artifact_data).hexdigest()
        if actual != descriptor["sha256"]:
            fail(f"payload artifact digest mismatch: {descriptor['path']}")
        if descriptor["path"] == "compatibility-set-local/updater-rollback.json":
            validate_rollback_plan(artifact_data)
    for name, expected in components["catalog"]["files"].items():
        actual = hashlib.sha256(read_regular(payload_directory / "catalog-release" / name, f"payload catalog {name}")).hexdigest()
        if actual != expected:
            fail(f"payload catalog digest mismatch: {name}")


def parse_signature(value: object) -> bytes:
    if not isinstance(value, dict):
        fail("signature: must be an object")
    exact_keys(value, {"algorithm", "key_id", "signature"}, "signature")
    if value["algorithm"] != SIGNATURE_ALGORITHM:
        fail("signature.algorithm: unsupported value")
    string(value["key_id"], "signature.key_id", KEY_ID)
    encoded = string(value["signature"], "signature.signature")
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (ValueError, base64.binascii.Error) as exc:
        fail(f"signature.signature: invalid base64: {exc}")
    if base64.b64encode(decoded).decode("ascii") != encoded:
        fail("signature.signature: base64 is not canonical")
    if not 64 <= len(decoded) <= 80:
        fail("signature.signature: invalid P-256 DER signature length")
    return decoded


def validate_envelope(data: bytes, require_signature: bool) -> dict:
    envelope = strict_json(data, "compatibility-set manifest")
    exact_keys(envelope, {"schema_version", "signatures", "signed"}, "compatibility-set manifest")
    if envelope["schema_version"] != ENVELOPE_SCHEMA:
        fail("compatibility-set manifest: unsupported envelope schema")
    validate_payload(envelope["signed"])
    signatures = envelope["signatures"]
    if not isinstance(signatures, list) or len(signatures) > 1:
        fail("compatibility-set manifest: signatures must contain at most one entry")
    if require_signature and len(signatures) != 1:
        fail("compatibility-set manifest: exactly one release signature is required")
    if signatures:
        parse_signature(signatures[0])
    return envelope


def catalog_component(catalog_directory: pathlib.Path, catalog_feed_directory: pathlib.Path) -> dict:
    catalog_bytes = {
        name: read_regular(
            (catalog_directory if name in {"release.json", "trusted-keys.json", "tier2-catalog.json"} else catalog_feed_directory) / name,
            f"catalog {name}",
        )
        for name in CATALOG_FILES
    }
    manifest = strict_json(catalog_bytes["release.json"], "catalog release.json", require_canonical=False)
    exact_keys(
        manifest,
        {"feeds", "generated_at", "policy_version", "release_id", "schema_version"},
        "catalog release.json",
    )
    feeds = manifest["feeds"]
    if not isinstance(feeds, dict):
        fail("catalog release.json feeds: must be an object")
    exact_keys(feeds, {"autotune-candidates.json", "demand-rank.json", "rate-card.json", "tier2-catalog.json"}, "catalog release.json feeds")
    for name, record in feeds.items():
        if not isinstance(record, dict):
            fail(f"catalog release.json feed {name}: must be an object")
        exact_keys(record, {"bytes", "sha256", "signer_key_id", "version"}, f"catalog release.json feed {name}")
        integer(record["bytes"], f"catalog release.json feed {name}.bytes", 1, MAX_INPUT_BYTES)
        string(record["sha256"], f"catalog release.json feed {name}.sha256", HEX64)
        string(record["signer_key_id"], f"catalog release.json feed {name}.signer_key_id")
        string(record["version"], f"catalog release.json feed {name}.version")
        if record["bytes"] != len(catalog_bytes[name]):
            fail(f"catalog release.json feed {name}: byte count does not match packaged feed")
        if record["sha256"] != hashlib.sha256(catalog_bytes[name]).hexdigest():
            fail(f"catalog release.json feed {name}: digest does not match packaged feed")
        if name not in {"tier2-catalog.json", "rate-card.json"} and record["version"] != manifest["release_id"]:
            fail(f"catalog release.json feed {name}: version does not match release_id")
    return {
        "activation": "local",
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(catalog_bytes.items())},
        "policy_version": string(manifest["policy_version"], "catalog policy_version"),
        "release_id": string(manifest["release_id"], "catalog release_id"),
        "schema_version": string(manifest["schema_version"], "catalog schema_version"),
    }


def rollout(policy: str) -> dict:
    if policy == "bridge_required":
        return {"bridge_duration_seconds": 86400, "enforce_provider_admission": False, "mode": policy}
    if policy == "strict_post_migration":
        return {"bridge_duration_seconds": 0, "enforce_provider_admission": True, "mode": policy}
    fail(f"unsupported provider admission policy: {policy}")


def local_artifact(local_directory: pathlib.Path, name: str) -> dict:
    filename = LOCAL_ARTIFACT_FILES[name]
    data = read_regular(local_directory / filename, f"local compatibility artifact {filename}")
    if name == "updater_metadata":
        validate_rollback_plan(data)
    return {
        "path": f"compatibility-set-local/{filename}",
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def build_manifest(args: argparse.Namespace) -> dict:
    tag = string(args.tag, "tag", TAG)
    commit = string(args.commit, "commit", HEX40)
    repository = string(args.repository, "repository", REPOSITORY)
    version = tag.removeprefix("v")
    malibu_app_version = string(
        args.malibu_app_version or version,
        "malibu app version",
        SEMVER,
    )
    provider_cli_version = string(
        args.provider_cli_version or version,
        "provider CLI version",
        SEMVER,
    )
    local_directory = pathlib.Path(args.local_artifacts_directory)
    payload = {
        "artifact_binding": {
            "embedded_container_hashes": "excluded_to_avoid_self_reference",
            "mode": "signed_release_checksums",
        },
        "compatibility_set_id": f"{repository}:{tag}@{commit}",
        "components": {
            "catalog": catalog_component(
                pathlib.Path(args.catalog_directory),
                pathlib.Path(args.catalog_feed_directory),
            ),
            "coordinator_admission": {
                "activation": "required_remote_gate",
                "handshake": "accepted_set_echo_v1",
                "policy_version": "provider-admission.v1",
                "rollout": rollout(args.provider_admission_policy),
                "scope": "remote_coordinator_policy",
                "version": version,
            },
            "launchd": {
                "activation": "local",
                "contract": "macprovider.launch-agent.v1",
                "install_contract": local_artifact(local_directory, "install_contract"),
                "label": "live.malibu.provider",
                "plist_template": local_artifact(local_directory, "provider_plist_template"),
            },
            "malibu_app": {
                "activation": "cli_owned_if_installed",
                "bundle_id": "tech.malibu.app",
                "compatibility_handoff": {
                    "delivery": "signed_dmg_transaction_member",
                    "embedded_manifest_path": "Contents/Resources/compatibility-set.json",
                    "provider_mutation": "forbidden",
                    "reader_compatibility": "backward_compatible",
                },
                "minimum_status_reader": 1,
                "version": malibu_app_version,
            },
            "provider_cli": {
                "activation": "local",
                "designated_identifier": "live.malibu.provider.cli",
                "platform": "darwin-arm64",
                "status_contract": "macprovider.local-status.v1",
                "version": provider_cli_version,
            },
            "updater_rollback": {
                "activation": "local",
                "metadata": local_artifact(local_directory, "updater_metadata"),
                "metadata_version": 1,
                "protocol": "macprovider.compatibility-set-transaction.v1",
            },
            "watchdog": {
                "activation": "local",
                "contract": "macprovider.exact-service-pid-watchdog.v1",
                "monitored_label": "live.malibu.provider",
                "plist_template": local_artifact(local_directory, "watchdog_plist_template"),
                "script": local_artifact(local_directory, "watchdog_script"),
                "service_label": "live.malibu.provider-watchdog",
            },
        },
        "release": {
            "commit": commit,
            "repository": repository,
            "tag": tag,
            "version": version,
        },
        "schema_version": PAYLOAD_SCHEMA,
        "transaction": {
            "activation": "crash_recoverable_local_activation_group",
            "autoupdate_scope": "compatibility_cohort",
            "maintenance_lease": {
                "maximum_seconds": 1200,
                "protocol": "macprovider.maintenance-lease.v1",
            },
            "membership": {
                "local_activation_group": list(ROLLBACK_MEMBERS),
                "required_external_gates": list(REQUIRED_EXTERNAL_GATES),
                "preserved_state_invariants": list(PRESERVED_STATE_INVARIANTS),
            },
            "preflight": {
                "mode": "exact_target_set",
                "remote_gate": "coordinator_acceptance_required",
            },
            "readiness_proof": {
                "compatibility_set_echo": "exact",
                "contract": "macprovider.local-status.v1",
                "network_state": "buyer_serving",
                "timeout_seconds": 1200,
            },
            "rollback": {
                "members": list(ROLLBACK_MEMBERS),
                "mode": "local_activation_group",
            },
        },
    }
    envelope = {"schema_version": ENVELOPE_SCHEMA, "signatures": [], "signed": payload}
    validate_envelope(canonical_bytes(envelope), require_signature=False)
    return envelope


def openssl_binary(raw: str | None) -> str:
    candidate = raw or os.environ.get("OPENSSL_BIN") or shutil.which("openssl")
    if not candidate:
        fail("openssl executable was not found")
    resolved = os.path.abspath(candidate)
    if not os.path.isfile(resolved) or not os.access(resolved, os.X_OK):
        fail(f"openssl is not executable: {resolved}")
    return resolved


def run_openssl(arguments: list[str], label: str) -> None:
    try:
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False)
    except subprocess.TimeoutExpired:
        fail(f"{label}: openssl timed out")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        fail(f"{label}: openssl failed: {detail}")


def verify_signature(envelope: dict, public_key: pathlib.Path, openssl: str) -> None:
    key_bytes = read_regular(public_key, "public key")
    signature = parse_signature(envelope["signatures"][0])
    with tempfile.TemporaryDirectory(prefix="macprovider-compatibility-verify.") as directory:
        root = pathlib.Path(directory)
        payload_path = root / "payload.json"
        signature_path = root / "signature.der"
        key_path = root / "public.pem"
        payload_path.write_bytes(canonical_bytes(envelope["signed"]))
        signature_path.write_bytes(signature)
        key_path.write_bytes(key_bytes)
        run_openssl(
            [openssl, "dgst", "-sha256", "-verify", str(key_path), "-signature", str(signature_path), str(payload_path)],
            "signature verification",
        )


def command_generate(args: argparse.Namespace) -> None:
    envelope = build_manifest(args)
    atomic_write(pathlib.Path(args.output), canonical_bytes(envelope))


def command_sign(args: argparse.Namespace) -> None:
    input_path = pathlib.Path(args.input)
    envelope = validate_envelope(read_regular(input_path, "manifest"), require_signature=False)
    if envelope["signatures"]:
        fail("manifest is already signed")
    private_key = pathlib.Path(args.private_key)
    read_regular(private_key, "private key")
    key_id = string(args.key_id, "key id", KEY_ID)
    openssl = openssl_binary(args.openssl)
    with tempfile.TemporaryDirectory(prefix="macprovider-compatibility-sign.") as directory:
        root = pathlib.Path(directory)
        payload_path = root / "payload.json"
        signature_path = root / "signature.der"
        payload_path.write_bytes(canonical_bytes(envelope["signed"]))
        run_openssl(
            [openssl, "dgst", "-sha256", "-sign", str(private_key), "-out", str(signature_path), str(payload_path)],
            "manifest signing",
        )
        signature = signature_path.read_bytes()
    encoded = base64.b64encode(signature).decode("ascii")
    envelope["signatures"] = [{"algorithm": SIGNATURE_ALGORITHM, "key_id": key_id, "signature": encoded}]
    output = pathlib.Path(args.output or args.input)
    rendered = canonical_bytes(envelope)
    validate_envelope(rendered, require_signature=True)
    atomic_write(output, rendered)


def command_validate(args: argparse.Namespace) -> None:
    envelope = validate_envelope(read_regular(pathlib.Path(args.input), "manifest"), args.require_signature)
    release = envelope["signed"]["release"]
    admission = envelope["signed"]["components"]["coordinator_admission"]["rollout"]
    checks = (
        (args.expected_tag, release["tag"], "release tag"),
        (args.expected_commit, release["commit"], "release commit"),
        (args.expected_provider_admission_policy, admission["mode"], "provider admission policy"),
        (
            args.expected_malibu_app_version,
            envelope["signed"]["components"]["malibu_app"]["version"],
            "Malibu app version",
        ),
        (
            args.expected_provider_cli_version,
            envelope["signed"]["components"]["provider_cli"]["version"],
            "provider CLI version",
        ),
    )
    for expected, actual, label in checks:
        if expected is not None and expected != actual:
            fail(f"{label} mismatch: got {actual!r}, expected {expected!r}")
    if args.payload_directory:
        validate_payload_artifacts(envelope["signed"], pathlib.Path(args.payload_directory))
    if args.public_key:
        if len(envelope["signatures"]) != 1:
            fail("a public key requires exactly one manifest signature")
        if args.expected_key_id and envelope["signatures"][0]["key_id"] != args.expected_key_id:
            fail("manifest signature key id mismatch")
        verify_signature(envelope, pathlib.Path(args.public_key), openssl_binary(args.openssl))
    elif args.require_signature:
        fail("--require-signature also requires --public-key")


def command_client_floor(args: argparse.Namespace) -> None:
    """Report — and optionally assert — the minimum client version that can
    accept this manifest's provider-CLI identifier, so a release cannot silently
    orphan the clients between the declared support floor and that minimum."""
    envelope = validate_envelope(read_regular(pathlib.Path(args.input), "manifest"), args.require_signature)
    identifier = envelope["signed"]["components"]["provider_cli"]["designated_identifier"]
    floor = CLIENT_IDENTIFIER_FLOORS.get(identifier)
    if floor is None:
        fail(
            f"unrecognized provider_cli.designated_identifier {identifier!r}: add its "
            "minimum-accepting client version to CLIENT_IDENTIFIER_FLOORS (and confirm "
            "the client parser tolerates it) before releasing"
        )
    required = ".".join(str(part) for part in floor)
    if args.assert_min_supported is not None:
        declared = parse_semver(args.assert_min_supported)
        if declared < floor:
            fail(
                f"declared minimum-supported client {args.assert_min_supported} is below "
                f"{required}, the oldest client that accepts identifier {identifier!r}. "
                f"Clients in [{args.assert_min_supported}, {required}) reject this manifest "
                "and strand with no self-heal path. Bump the supported-client floor to "
                f"{required} (and ship a bridge/reinstall path for the orphaned range) "
                "before releasing."
            )
    print(required)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subcommands = root.add_subparsers(dest="command", required=True)

    generate = subcommands.add_parser("generate", help="generate an unsigned deterministic envelope")
    generate.add_argument("--tag", required=True)
    generate.add_argument("--commit", required=True)
    generate.add_argument("--repository", default="Augustas11/macprovider")
    generate.add_argument("--malibu-app-version")
    generate.add_argument("--provider-cli-version")
    generate.add_argument("--provider-admission-policy", choices=("bridge_required", "strict_post_migration"), required=True)
    generate.add_argument("--catalog-directory", required=True)
    generate.add_argument("--catalog-feed-directory", required=True)
    generate.add_argument("--local-artifacts-directory", required=True)
    generate.add_argument("--output", required=True)
    generate.set_defaults(handler=command_generate)

    sign = subcommands.add_parser("sign", help="attach one release-key signature to an unsigned envelope")
    sign.add_argument("--input", required=True)
    sign.add_argument("--output")
    sign.add_argument("--private-key", required=True)
    sign.add_argument("--key-id", default=DEFAULT_KEY_ID)
    sign.add_argument("--openssl")
    sign.set_defaults(handler=command_sign)

    validate = subcommands.add_parser("validate", help="strictly validate an envelope and optional signature")
    validate.add_argument("--input", required=True)
    validate.add_argument("--require-signature", action="store_true")
    validate.add_argument("--public-key")
    validate.add_argument("--expected-key-id", default=DEFAULT_KEY_ID)
    validate.add_argument("--expected-tag")
    validate.add_argument("--expected-commit")
    validate.add_argument("--expected-malibu-app-version")
    validate.add_argument("--expected-provider-cli-version")
    validate.add_argument("--expected-provider-admission-policy", choices=("bridge_required", "strict_post_migration"))
    validate.add_argument("--payload-directory")
    validate.add_argument("--openssl")
    validate.set_defaults(handler=command_validate)

    client_floor = subcommands.add_parser(
        "client-floor",
        help="print the minimum client version that accepts this manifest's CLI identifier; "
        "with --assert-min-supported, fail if the declared support floor is below it",
    )
    client_floor.add_argument("--input", required=True)
    client_floor.add_argument("--require-signature", action="store_true")
    client_floor.add_argument(
        "--assert-min-supported",
        help="declared minimum-supported client version (X.Y.Z or vX.Y.Z); fail if below the manifest's floor",
    )
    client_floor.set_defaults(handler=command_client_floor)
    return root


def main() -> None:
    args = parser().parse_args()
    try:
        args.handler(args)
    except ManifestError as exc:
        raise SystemExit(f"compatibility-set-manifest: {exc}") from exc


if __name__ == "__main__":
    main()
