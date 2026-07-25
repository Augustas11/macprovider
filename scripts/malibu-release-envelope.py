#!/usr/bin/env python3
"""Generate and validate independently versioned signed Malibu releases.

The release envelope and discovery index deliberately do not derive provider
compatibility from Malibu's marketing version.  Both documents bind the exact
provider compatibility-set identity instead.  Signatures use DER ECDSA P-256
over SHA-256(context || NUL || CanonicalJSON(signed)).
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata


ENVELOPE_SCHEMA = "malibu-release-envelope.v1"
INDEX_SCHEMA = "malibu-release-index.v1"
KEYRING_SCHEMA = "malibu-release-keyring.v1"
REVOCATIONS_SCHEMA = "malibu-release-revocations.v1"
ROLLBACK_SCHEMA = "malibu-release-rollback.v1"
ROTATION_SCHEMA = "malibu-release-key-rotation.v1"
SIGNATURE_ALGORITHM = "ecdsa-p256-sha256"
ENVELOPE_CONTEXT = b"malibu.release-envelope.v1"
INDEX_CONTEXT = b"malibu.release-index.v1"
ROLLBACK_CONTEXT = b"malibu.release-rollback.v1"
ROTATION_RETIRING_CONTEXT = b"malibu.release-key-rotation.v1.retiring"
ROTATION_SUCCESSOR_CONTEXT = b"malibu.release-key-rotation.v1.successor"
INITIAL_KEY_ID = "macprovider-release-p256-v1"
INITIAL_PUBLIC_KEY_SHA256 = "2cd6171cea8cd7964c12292e3443078c2b3d0cdcc20ae600fe8261090392c7f8"
EXPECTED_BUNDLE_ID = "tech.malibu.app"
EXPECTED_TEAM_ID = "YF7XNRJUG4"
EXPECTED_CLI_IDENTIFIER = "live.streamvc.macprovider.cli"
EXPECTED_CLI_VERSION = "1.8.40"
EXPECTED_SET_ID = "Augustas11/macprovider:v1.8.40@18638472fe3e885f3534eeac29ab89b4c7ffdd7a"
EXPECTED_SET_SHA256 = "fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c"
MAX_INDEX_TTL_SECONDS = 7 * 24 * 60 * 60
MAX_FUTURE_SKEW_SECONDS = 300
MAX_JSON_BYTES = 1_048_576
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
KEY_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
PROTOCOL = re.compile(r"v[1-9][0-9]*")
ASSET = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,255}")
OPERATOR = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@:/-]{2,127}")
INCIDENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}")


class ContractError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ContractError(message)


def _reject_surrogates(value: str, label: str) -> None:
    if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
        fail(f"{label}: unpaired Unicode surrogate")


def _utf16_sort_key(value: str) -> bytes:
    _reject_surrogates(value, "object key")
    return value.encode("utf-16-be")


def _canonical_text(value: object) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        fail("CanonicalJSON: floating-point values are forbidden by this contract")
    if isinstance(value, str):
        _reject_surrogates(value, "string")
        normalized = unicodedata.normalize("NFC", value)
        return json.dumps(normalized, ensure_ascii=False, separators=(",", ":"))
    if isinstance(value, list):
        return "[" + ",".join(_canonical_text(item) for item in value) + "]"
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            fail("CanonicalJSON: object keys must be strings")
        return "{" + ",".join(
            json.dumps(key, ensure_ascii=False, separators=(",", ":"))
            + ":"
            + _canonical_text(value[key])
            for key in sorted(value, key=_utf16_sort_key)
        ) + "}"
    fail(f"CanonicalJSON: unsupported value type {type(value).__name__}")


def canonical_bytes(value: object) -> bytes:
    return _canonical_text(value).encode("utf-8")


def read_regular(path: pathlib.Path, label: str) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label}: cannot read {path}: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label}: must be a regular non-symlink file")
    if metadata.st_size > MAX_JSON_BYTES:
        fail(f"{label}: exceeds {MAX_JSON_BYTES} bytes")
    return path.read_bytes()


def strict_load(
    path: pathlib.Path,
    label: str,
    *,
    require_canonical: bool = False,
    allow_final_newline: bool = False,
) -> dict:
    raw = read_regular(path, label)

    def pairs_hook(pairs: list[tuple[str, object]]) -> dict:
        result: dict = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label}: duplicate object key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs_hook,
            parse_float=lambda _: fail(f"{label}: floating-point values are forbidden"),
            parse_constant=lambda item: fail(f"{label}: invalid number {item}"),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label}: invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label}: top-level value must be an object")
    canonical = canonical_bytes(value)
    accepted = raw == canonical or (allow_final_newline and raw == canonical + b"\n")
    if require_canonical and not accepted:
        fail(f"{label}: document is not exact CanonicalJSON")
    return value


def exact_keys(value: dict, expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        fail(f"{label}: fields differ (missing={sorted(expected - actual)}, unknown={sorted(actual - expected)})")


def require_dict(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{label}: must be an object")
    return value


def require_list(value: object, label: str) -> list:
    if not isinstance(value, list):
        fail(f"{label}: must be an array")
    return value


def require_string(value: object, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        fail(f"{label}: invalid value")
    return value


def require_positive_int(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        fail(f"{label}: must be a positive integer")
    return value


def require_exact(value: object, expected: object, label: str) -> None:
    if value != expected:
        fail(f"{label}: expected {expected!r}")


def parse_timestamp(value: object, label: str) -> dt.datetime:
    if not isinstance(value, str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value) is None:
        fail(f"{label}: must be an RFC3339 UTC timestamp with whole seconds")
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        fail(f"{label}: invalid timestamp")


def parse_now(value: str | None) -> dt.datetime:
    if value is None:
        return dt.datetime.now(dt.timezone.utc)
    return parse_timestamp(value, "--now")


def validate_artifact(value: object, label: str, expected_name: str | None = None) -> dict:
    row = require_dict(value, label)
    exact_keys(row, {"name", "sha256"}, label)
    name = require_string(row["name"], ASSET, f"{label}.name")
    require_string(row["sha256"], HEX64, f"{label}.sha256")
    if expected_name is not None and name != expected_name:
        fail(f"{label}.name: expected {expected_name}")
    return row


def validate_signature_shape(value: object, label: str) -> dict:
    signature = require_dict(value, label)
    exact_keys(signature, {"algorithm", "key_id", "signature"}, label)
    require_exact(signature["algorithm"], SIGNATURE_ALGORITHM, f"{label}.algorithm")
    require_string(signature["key_id"], KEY_ID, f"{label}.key_id")
    if not isinstance(signature["signature"], str) or not signature["signature"] or "=" in signature["signature"]:
        fail(f"{label}.signature: must be non-empty unpadded base64url")
    try:
        base64.urlsafe_b64decode(signature["signature"] + "=" * (-len(signature["signature"]) % 4))
    except ValueError:
        fail(f"{label}.signature: invalid base64url")
    return signature


def validate_envelope_payload(
    value: object,
    *,
    now: dt.datetime,
    minimum_build: int = 0,
    minimum_generation: int = 0,
    expected_set_id: str = EXPECTED_SET_ID,
    expected_set_sha256: str = EXPECTED_SET_SHA256,
) -> tuple[int, int]:
    payload = require_dict(value, "envelope.signed")
    exact_keys(
        payload,
        {"app", "artifacts", "envelope_generation", "legacy_bootstrap", "publication", "runtime_posture", "supported_provider"},
        "envelope.signed",
    )

    app = require_dict(payload["app"], "envelope.signed.app")
    exact_keys(app, {"build", "bundle_id", "designated_requirement", "entry_count", "marketing_version", "release_tag", "root_mode", "source_commit", "team_id", "tree_sha256"}, "envelope.signed.app")
    build = require_positive_int(app["build"], "envelope.signed.app.build")
    require_positive_int(app["entry_count"], "envelope.signed.app.entry_count")
    root_mode = require_positive_int(app["root_mode"], "envelope.signed.app.root_mode")
    if root_mode > 0o7777:
        fail("envelope.signed.app.root_mode: invalid mode")
    require_string(app["tree_sha256"], HEX64, "envelope.signed.app.tree_sha256")
    if build < minimum_build:
        fail("envelope: app build rollback")
    version = require_string(app["marketing_version"], SEMVER, "envelope.signed.app.marketing_version")
    require_exact(app["release_tag"], f"malibu-v{version}", "envelope.signed.app.release_tag")
    require_exact(app["bundle_id"], EXPECTED_BUNDLE_ID, "envelope.signed.app.bundle_id")
    require_exact(app["team_id"], EXPECTED_TEAM_ID, "envelope.signed.app.team_id")
    require_string(app["source_commit"], HEX40, "envelope.signed.app.source_commit")
    if not isinstance(app["designated_requirement"], str) or EXPECTED_BUNDLE_ID not in app["designated_requirement"] or EXPECTED_TEAM_ID not in app["designated_requirement"]:
        fail("envelope.signed.app.designated_requirement: must bind the exact bundle and Team IDs")

    generation = require_positive_int(payload["envelope_generation"], "envelope.signed.envelope_generation")
    if generation < minimum_generation:
        fail("envelope: generation rollback")

    artifacts = require_dict(payload["artifacts"], "envelope.signed.artifacts")
    exact_keys(artifacts, {"bundled_provider_cli", "dmg"}, "envelope.signed.artifacts")
    validate_artifact(artifacts["dmg"], "envelope.signed.artifacts.dmg", f"Malibu-v{version}.dmg")
    bundled_cli = require_dict(artifacts["bundled_provider_cli"], "envelope.signed.artifacts.bundled_provider_cli")
    exact_keys(bundled_cli, {"sha256", "version"}, "envelope.signed.artifacts.bundled_provider_cli")
    require_exact(bundled_cli["version"], EXPECTED_CLI_VERSION, "envelope.signed.artifacts.bundled_provider_cli.version")
    require_string(bundled_cli["sha256"], HEX64, "envelope.signed.artifacts.bundled_provider_cli.sha256")

    publication = require_dict(payload["publication"], "envelope.signed.publication")
    exact_keys(publication, {"published_at"}, "envelope.signed.publication")
    published_at = parse_timestamp(publication["published_at"], "envelope.signed.publication.published_at")
    if published_at > now + dt.timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
        fail("envelope: publication timestamp is future-dated")

    posture = require_dict(payload["runtime_posture"], "envelope.signed.runtime_posture")
    exact_keys(posture, {"hardened_runtime", "notarized", "stapled"}, "envelope.signed.runtime_posture")
    for field in ("hardened_runtime", "notarized", "stapled"):
        require_exact(posture[field], True, f"envelope.signed.runtime_posture.{field}")

    supported = require_dict(payload["supported_provider"], "envelope.signed.supported_provider")
    exact_keys(supported, {"capabilities", "compatibility_sets", "provider_mutation"}, "envelope.signed.supported_provider")
    require_exact(supported["provider_mutation"], "forbidden", "envelope.signed.supported_provider.provider_mutation")
    capabilities = require_dict(supported["capabilities"], "envelope.signed.supported_provider.capabilities")
    exact_keys(capabilities, {"admission_recovery", "control_socket", "credential_handoff", "local_status_reader"}, "envelope.signed.supported_provider.capabilities")
    for name, raw_versions in capabilities.items():
        versions = require_list(raw_versions, f"capability {name}")
        if not versions or len(set(versions)) != len(versions):
            fail(f"capability {name}: versions must be non-empty and unique")
        for item in versions:
            require_string(item, PROTOCOL, f"capability {name}")

    sets = require_list(supported["compatibility_sets"], "envelope.signed.supported_provider.compatibility_sets")
    if len(sets) != 1:
        fail("envelope: exactly one provider compatibility set is supported")
    compatibility = require_dict(sets[0], "provider compatibility set")
    exact_keys(compatibility, {"id", "manifest_sha256", "provider_cli"}, "provider compatibility set")
    require_exact(compatibility["id"], expected_set_id, "provider compatibility set.id")
    require_exact(compatibility["manifest_sha256"], expected_set_sha256, "provider compatibility set.manifest_sha256")
    cli = require_dict(compatibility["provider_cli"], "provider compatibility set.provider_cli")
    exact_keys(cli, {"designated_identifier", "team_id", "version"}, "provider compatibility set.provider_cli")
    require_exact(cli["version"], EXPECTED_CLI_VERSION, "provider compatibility set.provider_cli.version")
    require_exact(cli["team_id"], EXPECTED_TEAM_ID, "provider compatibility set.provider_cli.team_id")
    require_exact(cli["designated_identifier"], EXPECTED_CLI_IDENTIFIER, "provider compatibility set.provider_cli.designated_identifier")

    bootstrap = require_dict(payload["legacy_bootstrap"], "envelope.signed.legacy_bootstrap")
    exact_keys(bootstrap, {"allowed_source_cohorts", "backend_handoff_required", "caller_selected_target", "expires_at", "no_downgrade", "target_cli_version", "target_manifest_sha256"}, "envelope.signed.legacy_bootstrap")
    require_exact(bootstrap["backend_handoff_required"], True, "legacy_bootstrap.backend_handoff_required")
    require_exact(bootstrap["caller_selected_target"], False, "legacy_bootstrap.caller_selected_target")
    require_exact(bootstrap["no_downgrade"], True, "legacy_bootstrap.no_downgrade")
    require_exact(bootstrap["target_cli_version"], EXPECTED_CLI_VERSION, "legacy_bootstrap.target_cli_version")
    require_exact(bootstrap["target_manifest_sha256"], expected_set_sha256, "legacy_bootstrap.target_manifest_sha256")
    # This timestamp gates only use of the optional legacy-bootstrap bridge.
    # It is still schema-validated and signed here, but expiry must not disable
    # ordinary app discovery/install after the bridge window closes.
    parse_timestamp(bootstrap["expires_at"], "legacy_bootstrap.expires_at")
    cohorts = require_list(bootstrap["allowed_source_cohorts"], "legacy_bootstrap.allowed_source_cohorts")
    if not cohorts:
        fail("legacy_bootstrap.allowed_source_cohorts: must not be empty")
    seen_cohorts: set[tuple[str, str]] = set()
    for raw_cohort in cohorts:
        cohort = require_dict(raw_cohort, "legacy bootstrap cohort")
        exact_keys(cohort, {
            "app_build", "app_entry_count", "app_root_mode", "app_tree_sha256",
            "app_version", "cli_version",
        }, "legacy bootstrap cohort")
        key = (
            require_string(cohort["app_version"], SEMVER, "legacy bootstrap cohort.app_version"),
            require_string(cohort["cli_version"], SEMVER, "legacy bootstrap cohort.cli_version"),
        )
        require_positive_int(cohort["app_build"], "legacy bootstrap cohort.app_build")
        require_positive_int(cohort["app_entry_count"], "legacy bootstrap cohort.app_entry_count")
        root_mode = require_positive_int(cohort["app_root_mode"], "legacy bootstrap cohort.app_root_mode")
        if root_mode > 0o7777:
            fail("legacy bootstrap cohort.app_root_mode: invalid mode")
        require_string(cohort["app_tree_sha256"], HEX64, "legacy bootstrap cohort.app_tree_sha256")
        if key in seen_cohorts:
            fail("legacy_bootstrap.allowed_source_cohorts: duplicate cohort")
        seen_cohorts.add(key)

    return build, generation


def validate_index_payload(
    value: object,
    *,
    now: dt.datetime,
    expected_channel: str,
    minimum_index_generation: int,
    minimum_build: int,
    minimum_envelope_generation: int,
    expected_envelope_sha256: str,
    expected_keyring_generation: int,
    expected_keyring_sha256: str,
    expected_revocations_generation: int,
    expected_revocations_sha256: str,
    installed_transaction: bool = False,
) -> tuple[int, int, int, str]:
    payload = require_dict(value, "index.signed")
    exact_keys(payload, {"channel", "envelope", "expires_at", "index_generation", "issued_at", "minimum_accepted_envelope_generation", "trust"}, "index.signed")
    require_exact(payload["channel"], expected_channel, "index.signed.channel")
    index_generation = require_positive_int(payload["index_generation"], "index.signed.index_generation")
    if index_generation < minimum_index_generation:
        fail("index: generation rollback")
    issued_at = parse_timestamp(payload["issued_at"], "index.signed.issued_at")
    expires_at = parse_timestamp(payload["expires_at"], "index.signed.expires_at")
    if issued_at > now + dt.timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
        fail("index: future-dated")
    if expires_at <= now and not installed_transaction:
        fail("index: expired")
    if expires_at <= issued_at or (expires_at - issued_at).total_seconds() > MAX_INDEX_TTL_SECONDS:
        fail("index: validity exceeds the seven-day TTL")
    minimum_accepted = require_positive_int(payload["minimum_accepted_envelope_generation"], "index.signed.minimum_accepted_envelope_generation")
    if minimum_accepted < minimum_envelope_generation:
        fail("index: minimum accepted envelope generation rollback")
    envelope = require_dict(payload["envelope"], "index.signed.envelope")
    exact_keys(envelope, {"build", "generation", "name", "sha256"}, "index.signed.envelope")
    build = require_positive_int(envelope["build"], "index.signed.envelope.build")
    generation = require_positive_int(envelope["generation"], "index.signed.envelope.generation")
    name = require_string(envelope["name"], ASSET, "index.signed.envelope.name")
    digest = require_string(envelope["sha256"], HEX64, "index.signed.envelope.sha256")
    if build < minimum_build:
        fail("index: app build rollback")
    if generation < minimum_accepted or generation < minimum_envelope_generation:
        fail("index: envelope generation rollback")
    if digest != expected_envelope_sha256:
        fail("index: envelope digest mismatch")
    trust = require_dict(payload["trust"], "index.signed.trust")
    exact_keys(
        trust,
        {"keyring_generation", "keyring_sha256", "revocations_generation", "revocations_sha256"},
        "index.signed.trust",
    )
    require_exact(trust["keyring_generation"], expected_keyring_generation, "index trust keyring generation")
    require_exact(trust["keyring_sha256"], expected_keyring_sha256, "index trust keyring digest")
    require_exact(trust["revocations_generation"], expected_revocations_generation, "index trust revocations generation")
    require_exact(trust["revocations_sha256"], expected_revocations_sha256, "index trust revocations digest")
    return index_generation, build, generation, name


def validate_replay_state(value: object, label: str) -> dict:
    state = require_dict(value, label)
    exact_keys(state, {"build", "envelope_generation", "envelope_sha256", "index_generation"}, label)
    return {
        "build": require_positive_int(state["build"], f"{label}.build"),
        "envelope_generation": require_positive_int(state["envelope_generation"], f"{label}.envelope_generation"),
        "envelope_sha256": require_string(state["envelope_sha256"], HEX64, f"{label}.envelope_sha256"),
        "index_generation": require_positive_int(state["index_generation"], f"{label}.index_generation"),
    }


def validate_rollback_payload(
    value: object,
    *,
    now: dt.datetime,
    current_state: dict,
    target_state: dict,
) -> str:
    payload = require_dict(value, "rollback.signed")
    exact_keys(payload, {"current", "expires_at", "incident", "issued_at", "issuer", "nonce", "target"}, "rollback.signed")
    issued_at = parse_timestamp(payload["issued_at"], "rollback.signed.issued_at")
    expires_at = parse_timestamp(payload["expires_at"], "rollback.signed.expires_at")
    if issued_at > now + dt.timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
        fail("rollback: future-dated")
    if expires_at <= now:
        fail("rollback: expired")
    if expires_at <= issued_at or (expires_at - issued_at).total_seconds() > 3600:
        fail("rollback: validity exceeds one hour")
    require_string(payload["incident"], INCIDENT, "rollback.signed.incident")
    require_string(payload["issuer"], OPERATOR, "rollback.signed.issuer")
    nonce = require_string(payload["nonce"], HEX64, "rollback.signed.nonce")
    bound_current = validate_replay_state(payload["current"], "rollback.signed.current")
    bound_target = validate_replay_state(payload["target"], "rollback.signed.target")
    if bound_current != current_state or bound_target != target_state:
        fail("rollback: current or target state binding differs")
    numeric_fields = ("index_generation", "build", "envelope_generation")
    if any(
        bound_target[field] > bound_current[field]
        for field in numeric_fields
    ) or not any(bound_target[field] < bound_current[field] for field in numeric_fields):
        fail("rollback: target must be a strictly older state")
    return nonce


def consume_authorization_receipt(directory: pathlib.Path, *, kind: str, nonce: str, details: dict) -> None:
    try:
        directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        metadata = directory.lstat()
    except OSError as error:
        fail(f"authorization receipt directory: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        fail("authorization receipt directory: must be a non-symlink directory")
    if metadata.st_uid != os.geteuid():
        fail("authorization receipt directory: owner differs from current user")
    os.chmod(directory, 0o700)
    digest = hashlib.sha256(kind.encode() + b"\x00" + nonce.encode()).hexdigest()
    receipt = directory / f"{kind}-{digest}.json"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(receipt, flags, 0o600)
    except FileExistsError:
        fail("authorization: nonce was already consumed")
    except OSError as error:
        fail(f"authorization receipt: could not create atomically: {error}")
    try:
        data = canonical_bytes({"details": details, "kind": kind, "nonce": nonce, "schema_version": "malibu-release-authorization-receipt.v1"})
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        directory_descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except Exception:
        receipt.unlink(missing_ok=True)
        raise


def validate_authorization_receipt(
    directory: pathlib.Path,
    *,
    kind: str,
    nonce: str,
    expected_details: dict[str, str],
) -> None:
    digest = hashlib.sha256(kind.encode() + b"\x00" + nonce.encode()).hexdigest()
    receipt = directory / f"{kind}-{digest}.json"
    raw = read_regular(receipt, "authorization receipt")
    metadata = receipt.lstat()
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
        fail("authorization receipt: owner or mode is insecure")
    value = strict_load(receipt, "authorization receipt", require_canonical=True)
    exact_keys(value, {"details", "kind", "nonce", "schema_version"}, "authorization receipt")
    require_exact(value["schema_version"], "malibu-release-authorization-receipt.v1", "authorization receipt.schema_version")
    require_exact(value["kind"], kind, "authorization receipt.kind")
    require_exact(value["nonce"], nonce, "authorization receipt.nonce")
    details = require_dict(value["details"], "authorization receipt.details")
    for key, expected in expected_details.items():
        require_exact(details.get(key), expected, f"authorization receipt.details.{key}")
    if raw != canonical_bytes(value):
        fail("authorization receipt: document is not exact CanonicalJSON")


def validate_rotation_payload(
    value: object,
    *,
    now: dt.datetime,
    current: tuple[int, str, int, str],
    successor: tuple[int, str, int, str],
    retiring_key_id: str,
    successor_key_id: str,
    overlap_index_sha256: str,
    minimum_index_generation: int,
) -> str:
    payload = require_dict(value, "rotation.signed")
    exact_keys(
        payload,
        {"audit", "current_trust", "expires_at", "incident", "issued_at", "issuer", "overlap_index", "rotation_id", "successor_trust"},
        "rotation.signed",
    )
    issued_at = parse_timestamp(payload["issued_at"], "rotation.signed.issued_at")
    expires_at = parse_timestamp(payload["expires_at"], "rotation.signed.expires_at")
    if issued_at > now + dt.timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
        fail("rotation: future-dated")
    if expires_at <= now:
        fail("rotation: expired")
    if expires_at <= issued_at or (expires_at - issued_at).total_seconds() > 86400:
        fail("rotation: validity exceeds one day")
    require_string(payload["incident"], INCIDENT, "rotation.signed.incident")
    require_string(payload["issuer"], OPERATOR, "rotation.signed.issuer")
    rotation_id = require_string(payload["rotation_id"], HEX64, "rotation.signed.rotation_id")

    def trust_binding(raw: object, label: str, key_label: str, key_id: str, expected: tuple[int, str, int, str]) -> None:
        binding = require_dict(raw, label)
        exact_keys(binding, {"keyring_generation", "keyring_sha256", "revocations_generation", "revocations_sha256", key_label}, label)
        actual = (
            require_positive_int(binding["keyring_generation"], f"{label}.keyring_generation"),
            require_string(binding["keyring_sha256"], HEX64, f"{label}.keyring_sha256"),
            require_positive_int(binding["revocations_generation"], f"{label}.revocations_generation"),
            require_string(binding["revocations_sha256"], HEX64, f"{label}.revocations_sha256"),
        )
        if actual != expected or binding[key_label] != key_id:
            fail(f"{label}: trust binding differs")

    trust_binding(payload["current_trust"], "rotation.signed.current_trust", "retiring_key_id", retiring_key_id, current)
    trust_binding(payload["successor_trust"], "rotation.signed.successor_trust", "successor_key_id", successor_key_id, successor)
    if successor[0] <= current[0]:
        fail("rotation: successor keyring generation must advance")
    overlap = require_dict(payload["overlap_index"], "rotation.signed.overlap_index")
    exact_keys(overlap, {"index_generation", "sha256"}, "rotation.signed.overlap_index")
    if require_positive_int(overlap["index_generation"], "rotation overlap index generation") <= minimum_index_generation:
        fail("rotation: overlap index generation must advance")
    require_exact(overlap["sha256"], overlap_index_sha256, "rotation overlap index digest")
    audit = require_dict(payload["audit"], "rotation.signed.audit")
    exact_keys(audit, {"report_sha256", "reviewer"}, "rotation.signed.audit")
    require_string(audit["report_sha256"], HEX64, "rotation.signed.audit.report_sha256")
    require_string(audit["reviewer"], OPERATOR, "rotation.signed.audit.reviewer")
    return rotation_id


def load_trusted_key(
    keyring_path: pathlib.Path,
    revocations_path: pathlib.Path,
    *,
    expected_key_id: str,
    minimum_keyring_generation: int,
) -> tuple[pathlib.Path, int, str, int, str]:
    keyring = strict_load(
        keyring_path,
        "Malibu release keyring",
        require_canonical=True,
        allow_final_newline=True,
    )
    exact_keys(keyring, {"generation", "keys", "schema_version"}, "Malibu release keyring")
    require_exact(keyring["schema_version"], KEYRING_SCHEMA, "Malibu release keyring.schema_version")
    generation = require_positive_int(keyring["generation"], "Malibu release keyring.generation")
    if generation < minimum_keyring_generation:
        fail("Malibu release keyring: generation rollback")
    keys = require_list(keyring["keys"], "Malibu release keyring.keys")
    seen: set[str] = set()
    selected: dict | None = None
    for raw in keys:
        key = require_dict(raw, "Malibu release key")
        exact_keys(key, {"algorithm", "key_id", "public_key_path", "public_key_spki_sha256", "status"}, "Malibu release key")
        key_id = require_string(key["key_id"], KEY_ID, "Malibu release key.key_id")
        if key_id in seen:
            fail("Malibu release keyring: duplicate key_id")
        seen.add(key_id)
        require_exact(key["algorithm"], SIGNATURE_ALGORITHM, "Malibu release key.algorithm")
        require_string(key["public_key_spki_sha256"], HEX64, "Malibu release key.public_key_spki_sha256")
        if key["status"] not in ("active", "retiring"):
            fail("Malibu release key.status: invalid value")
        if key_id == expected_key_id:
            selected = key
    if selected is None:
        fail("Malibu release keyring: unknown key_id")

    # The first Malibu release key is the root of trust.  A keyring is policy,
    # not an authority that may redefine that bootstrap key.  Enforce both the
    # reviewed key bytes and their fixed sibling filename here so every caller
    # (ordinary validation, overlap rotation, and retirement) gets the same
    # fail-closed bootstrap behavior before following any rotation policy.
    if expected_key_id == INITIAL_KEY_ID:
        require_exact(
            selected["public_key_spki_sha256"],
            INITIAL_PUBLIC_KEY_SHA256,
            "initial release key digest",
        )
        require_exact(
            selected["public_key_path"],
            "release-signing-public.pem",
            "initial release key path",
        )

    revocations_raw = read_regular(revocations_path, "Malibu release revocations")
    revocations = strict_load(
        revocations_path,
        "Malibu release revocations",
        require_canonical=True,
        allow_final_newline=True,
    )
    exact_keys(revocations, {"generation", "issued_at", "keyring_generation", "revoked_key_ids", "revoked_keyring_generations", "schema_version"}, "Malibu release revocations")
    require_exact(revocations["schema_version"], REVOCATIONS_SCHEMA, "Malibu release revocations.schema_version")
    revocations_generation = require_positive_int(revocations["generation"], "Malibu release revocations.generation")
    require_exact(revocations["keyring_generation"], generation, "Malibu release revocations.keyring_generation")
    parse_timestamp(revocations["issued_at"], "Malibu release revocations.issued_at")
    revoked_ids = require_list(revocations["revoked_key_ids"], "Malibu release revocations.revoked_key_ids")
    revoked_generations = require_list(revocations["revoked_keyring_generations"], "Malibu release revocations.revoked_keyring_generations")
    if len(set(revoked_ids)) != len(revoked_ids) or any(KEY_ID.fullmatch(item) is None for item in revoked_ids if isinstance(item, str)) or any(not isinstance(item, str) for item in revoked_ids):
        fail("Malibu release revocations: invalid or duplicate revoked key ID")
    if len(set(revoked_generations)) != len(revoked_generations) or any(isinstance(item, bool) or not isinstance(item, int) or item < 1 for item in revoked_generations):
        fail("Malibu release revocations: invalid or duplicate revoked keyring generation")
    if expected_key_id in revoked_ids:
        fail("Malibu release keyring: key_id is revoked")
    if generation in revoked_generations:
        fail("Malibu release keyring: generation is revoked")

    public_key_path_value = selected["public_key_path"]
    if not isinstance(public_key_path_value, str) or not public_key_path_value:
        fail("Malibu release key.public_key_path: invalid value")
    public_key_path = (keyring_path.parent / public_key_path_value).resolve()
    public_key_pem = read_regular(public_key_path, "Malibu release public key")
    conversion = subprocess.run(
        ["openssl", "pkey", "-pubin", "-outform", "DER"],
        input=public_key_pem,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if conversion.returncode != 0:
        fail("Malibu release public key: invalid PEM")
    digest = hashlib.sha256(conversion.stdout).hexdigest()
    if digest != selected["public_key_spki_sha256"]:
        fail("Malibu release public key: SPKI digest mismatch")
    details = subprocess.run(
        ["openssl", "pkey", "-pubin", "-text", "-noout"],
        input=public_key_pem.decode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
    )
    if details.returncode != 0 or "P-256" not in details.stdout or "prime256v1" not in details.stdout:
        fail("Malibu release public key: must be ECDSA P-256")
    return (
        public_key_path,
        generation,
        hashlib.sha256(read_regular(keyring_path, "Malibu release keyring")).hexdigest(),
        revocations_generation,
        hashlib.sha256(revocations_raw).hexdigest(),
    )


def signature_bytes(context: bytes, payload: dict) -> bytes:
    return context + b"\x00" + canonical_bytes(payload)


def sign_document(unsigned: dict, schema: str, context: bytes, private_key: pathlib.Path, key_id: str) -> dict:
    exact_keys(unsigned, {"schema_version", "signed"}, "unsigned document")
    require_exact(unsigned["schema_version"], schema, "unsigned document.schema_version")
    require_string(key_id, KEY_ID, "key_id")
    signed = require_dict(unsigned["signed"], "unsigned document.signed")
    signature = sign_payload(signed, context, private_key, key_id)
    return {
        "schema_version": schema,
        "signature": signature,
        "signed": signed,
    }


def sign_payload(signed: dict, context: bytes, private_key: pathlib.Path, key_id: str) -> dict:
    require_string(key_id, KEY_ID, "key_id")
    process = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(private_key)],
        input=signature_bytes(context, signed),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        fail(f"could not sign document: {process.stderr.decode('utf-8', errors='replace').strip()}")
    encoded = base64.urlsafe_b64encode(process.stdout).decode().rstrip("=")
    return {"algorithm": SIGNATURE_ALGORITHM, "key_id": key_id, "signature": encoded}


def verify_document(document: dict, schema: str, context: bytes, public_key: pathlib.Path) -> None:
    exact_keys(document, {"schema_version", "signature", "signed"}, "signed document")
    require_exact(document["schema_version"], schema, "signed document.schema_version")
    verify_signature(document["signature"], require_dict(document["signed"], "signed document.signed"), context, public_key)


def verify_signature(signature_value: object, signed: dict, context: bytes, public_key: pathlib.Path) -> None:
    signature = validate_signature_shape(signature_value, "signed document.signature")
    encoded = signature["signature"]
    try:
        raw_signature = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    except ValueError:
        fail("signed document.signature: invalid base64url")
    with tempfile.NamedTemporaryFile() as signature_file:
        signature_file.write(raw_signature)
        signature_file.flush()
        process = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(public_key), "-signature", signature_file.name],
            input=signature_bytes(context, signed),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    if process.returncode != 0:
        fail("signed document: invalid ECDSA P-256 signature")


def atomic_write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.is_symlink():
        fail("output must not be a symlink")
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
        temporary.unlink(missing_ok=True)


def add_common_validation(sub: argparse.ArgumentParser) -> None:
    sub.add_argument("--keyring", required=True, type=pathlib.Path)
    sub.add_argument("--revocations", required=True, type=pathlib.Path)
    sub.add_argument("--expected-key-id", default=INITIAL_KEY_ID)
    sub.add_argument("--minimum-keyring-generation", type=int, default=1)
    sub.add_argument("--now")


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    canonical = commands.add_parser("canonicalize")
    canonical.add_argument("--input", required=True, type=pathlib.Path)

    for name in ("sign-envelope", "sign-index", "sign-rollback"):
        sub = commands.add_parser(name)
        sub.add_argument("--input", required=True, type=pathlib.Path, help="canonical unsigned document")
        sub.add_argument("--private-key", required=True, type=pathlib.Path)
        sub.add_argument("--key-id", default=INITIAL_KEY_ID)
        sub.add_argument("--output", required=True, type=pathlib.Path)
        sub.add_argument("--now")

    sign_rotation = commands.add_parser("sign-rotation")
    sign_rotation.add_argument("--input", required=True, type=pathlib.Path, help="canonical unsigned rotation payload")
    sign_rotation.add_argument("--retiring-private-key", required=True, type=pathlib.Path)
    sign_rotation.add_argument("--retiring-key-id", required=True)
    sign_rotation.add_argument("--successor-private-key", required=True, type=pathlib.Path)
    sign_rotation.add_argument("--successor-key-id", required=True)
    sign_rotation.add_argument("--overlap-index", required=True, type=pathlib.Path)
    sign_rotation.add_argument("--output", required=True, type=pathlib.Path)
    sign_rotation.add_argument("--now")

    envelope = commands.add_parser("validate-envelope")
    envelope.add_argument("--input", required=True, type=pathlib.Path)
    envelope.add_argument("--minimum-build", type=int, default=0)
    envelope.add_argument("--minimum-envelope-generation", type=int, default=0)
    envelope.add_argument("--expected-set-id", default=EXPECTED_SET_ID)
    envelope.add_argument("--expected-set-sha256", default=EXPECTED_SET_SHA256)
    add_common_validation(envelope)

    index = commands.add_parser("validate-index")
    index.add_argument("--input", required=True, type=pathlib.Path)
    index.add_argument("--envelope", required=True, type=pathlib.Path)
    index.add_argument("--expected-channel", default="stable")
    index.add_argument("--minimum-index-generation", type=int, default=0)
    index.add_argument("--minimum-build", type=int, default=0)
    index.add_argument("--minimum-envelope-generation", type=int, default=0)
    index.add_argument(
        "--installed-transaction",
        action="store_true",
        help="validate signed package/install evidence without treating discovery expiry as revocation",
    )
    add_common_validation(index)

    rollback = commands.add_parser("validate-rollback")
    rollback.add_argument("--input", required=True, type=pathlib.Path)
    rollback.add_argument("--current-state", required=True, type=pathlib.Path)
    rollback.add_argument("--target-state", required=True, type=pathlib.Path)
    rollback.add_argument("--receipt-directory", required=True, type=pathlib.Path)
    add_common_validation(rollback)

    rotation = commands.add_parser("validate-rotation")
    rotation.add_argument("--input", required=True, type=pathlib.Path)
    rotation.add_argument("--current-keyring", required=True, type=pathlib.Path)
    rotation.add_argument("--current-revocations", required=True, type=pathlib.Path)
    rotation.add_argument("--successor-keyring", required=True, type=pathlib.Path)
    rotation.add_argument("--successor-revocations", required=True, type=pathlib.Path)
    rotation.add_argument("--retiring-key-id", required=True)
    rotation.add_argument("--successor-key-id", required=True)
    rotation.add_argument("--overlap-index", required=True, type=pathlib.Path)
    rotation.add_argument("--minimum-index-generation", required=True, type=int)
    rotation.add_argument("--receipt-directory", required=True, type=pathlib.Path)
    rotation.add_argument("--now")

    trust = commands.add_parser("validate-trust")
    trust.add_argument("--keyring", required=True, type=pathlib.Path)
    trust.add_argument("--revocations", required=True, type=pathlib.Path)
    trust.add_argument("--expected-key-id", default=INITIAL_KEY_ID)
    trust.add_argument("--minimum-keyring-generation", type=int, default=1)

    args = parser.parse_args()
    try:
        now = parse_now(getattr(args, "now", None))
        if args.command == "canonicalize":
            sys.stdout.buffer.write(canonical_bytes(strict_load(args.input, "input")))
            return 0

        if args.command == "sign-rotation":
            unsigned = strict_load(args.input, "unsigned rotation", require_canonical=True)
            exact_keys(unsigned, {"schema_version", "signed"}, "unsigned rotation")
            require_exact(unsigned["schema_version"], ROTATION_SCHEMA, "unsigned rotation.schema_version")
            signed = require_dict(unsigned["signed"], "unsigned rotation.signed")
            current = require_dict(signed.get("current_trust"), "rotation current trust")
            successor = require_dict(signed.get("successor_trust"), "rotation successor trust")
            validate_rotation_payload(
                signed,
                now=now,
                current=(current.get("keyring_generation"), current.get("keyring_sha256"), current.get("revocations_generation"), current.get("revocations_sha256")),
                successor=(successor.get("keyring_generation"), successor.get("keyring_sha256"), successor.get("revocations_generation"), successor.get("revocations_sha256")),
                retiring_key_id=args.retiring_key_id,
                successor_key_id=args.successor_key_id,
                overlap_index_sha256=hashlib.sha256(read_regular(args.overlap_index, "overlap index")).hexdigest(),
                minimum_index_generation=0,
            )
            result = {
                "schema_version": ROTATION_SCHEMA,
                "signatures": {
                    "retiring": sign_payload(signed, ROTATION_RETIRING_CONTEXT, args.retiring_private_key, args.retiring_key_id),
                    "successor": sign_payload(signed, ROTATION_SUCCESSOR_CONTEXT, args.successor_private_key, args.successor_key_id),
                },
                "signed": signed,
            }
            atomic_write(args.output, canonical_bytes(result))
            return 0

        if args.command in ("sign-envelope", "sign-index", "sign-rollback"):
            unsigned = strict_load(args.input, "unsigned document", require_canonical=True)
            if args.command == "sign-envelope":
                validate_envelope_payload(unsigned.get("signed"), now=now)
                result = sign_document(unsigned, ENVELOPE_SCHEMA, ENVELOPE_CONTEXT, args.private_key, args.key_id)
            elif args.command == "sign-index":
                payload = require_dict(unsigned.get("signed"), "unsigned index.signed")
                envelope = require_dict(payload.get("envelope"), "unsigned index envelope")
                trust = require_dict(payload.get("trust"), "unsigned index trust")
                validate_index_payload(
                    payload,
                    now=now,
                    expected_channel=payload.get("channel"),
                    minimum_index_generation=0,
                    minimum_build=0,
                    minimum_envelope_generation=0,
                    expected_envelope_sha256=envelope.get("sha256"),
                    expected_keyring_generation=trust.get("keyring_generation"),
                    expected_keyring_sha256=trust.get("keyring_sha256"),
                    expected_revocations_generation=trust.get("revocations_generation"),
                    expected_revocations_sha256=trust.get("revocations_sha256"),
                )
                result = sign_document(unsigned, INDEX_SCHEMA, INDEX_CONTEXT, args.private_key, args.key_id)
            else:
                current_state = validate_replay_state(unsigned.get("signed", {}).get("current"), "rollback.signed.current")
                target_state = validate_replay_state(unsigned.get("signed", {}).get("target"), "rollback.signed.target")
                validate_rollback_payload(unsigned.get("signed"), now=now, current_state=current_state, target_state=target_state)
                result = sign_document(unsigned, ROLLBACK_SCHEMA, ROLLBACK_CONTEXT, args.private_key, args.key_id)
            atomic_write(args.output, canonical_bytes(result))
            return 0

        if args.command == "validate-rotation":
            current_result = load_trusted_key(
                args.current_keyring,
                args.current_revocations,
                expected_key_id=args.retiring_key_id,
                minimum_keyring_generation=1,
            )
            successor_retiring = load_trusted_key(
                args.successor_keyring,
                args.successor_revocations,
                expected_key_id=args.retiring_key_id,
                minimum_keyring_generation=current_result[1] + 1,
            )
            successor_result = load_trusted_key(
                args.successor_keyring,
                args.successor_revocations,
                expected_key_id=args.successor_key_id,
                minimum_keyring_generation=current_result[1] + 1,
            )
            current_keyring = strict_load(args.current_keyring, "current keyring", require_canonical=True, allow_final_newline=True)
            successor_keyring = strict_load(args.successor_keyring, "successor keyring", require_canonical=True, allow_final_newline=True)
            current_ids = {row["key_id"]: row["status"] for row in current_keyring["keys"]}
            successor_ids = {row["key_id"]: row["status"] for row in successor_keyring["keys"]}
            if args.retiring_key_id == args.successor_key_id or args.successor_key_id in current_ids:
                fail("rotation: successor key must be new")
            if current_ids.get(args.retiring_key_id) not in ("active", "retiring"):
                fail("rotation: retiring key is absent from current policy")
            if successor_ids.get(args.retiring_key_id) != "retiring" or successor_ids.get(args.successor_key_id) != "active":
                fail("rotation: overlap policy must retain retiring key and activate successor")
            document = strict_load(args.input, "rotation authorization", require_canonical=True)
            exact_keys(document, {"schema_version", "signatures", "signed"}, "rotation authorization")
            require_exact(document["schema_version"], ROTATION_SCHEMA, "rotation authorization.schema_version")
            signatures = require_dict(document["signatures"], "rotation signatures")
            exact_keys(signatures, {"retiring", "successor"}, "rotation signatures")
            signed = require_dict(document["signed"], "rotation signed")
            if validate_signature_shape(signatures["retiring"], "retiring signature")["key_id"] != args.retiring_key_id:
                fail("rotation: retiring signature key differs")
            if validate_signature_shape(signatures["successor"], "successor signature")["key_id"] != args.successor_key_id:
                fail("rotation: successor signature key differs")
            verify_signature(signatures["retiring"], signed, ROTATION_RETIRING_CONTEXT, current_result[0])
            verify_signature(signatures["successor"], signed, ROTATION_SUCCESSOR_CONTEXT, successor_result[0])
            overlap_data = read_regular(args.overlap_index, "overlap index")
            rotation_id = validate_rotation_payload(
                signed,
                now=now,
                current=(current_result[1], current_result[2], current_result[3], current_result[4]),
                successor=(successor_result[1], successor_result[2], successor_result[3], successor_result[4]),
                retiring_key_id=args.retiring_key_id,
                successor_key_id=args.successor_key_id,
                overlap_index_sha256=hashlib.sha256(overlap_data).hexdigest(),
                minimum_index_generation=args.minimum_index_generation,
            )
            consume_authorization_receipt(
                args.receipt_directory,
                kind="rotation-overlap",
                nonce=rotation_id,
                details={
                    "current_keyring_sha256": current_result[2],
                    "successor_keyring_sha256": successor_result[2],
                    "retiring_key_id": args.retiring_key_id,
                    "successor_key_id": args.successor_key_id,
                },
            )
            return 0

        trust_result = load_trusted_key(
            args.keyring,
            args.revocations,
            expected_key_id=args.expected_key_id,
            minimum_keyring_generation=args.minimum_keyring_generation,
        )
        public_key, keyring_generation, keyring_sha256, revocations_generation, revocations_sha256 = trust_result

        if args.command == "validate-trust":
            return 0

        document = strict_load(args.input, "signed document", require_canonical=True)
        signature = validate_signature_shape(document.get("signature"), "signed document.signature")
        if signature["key_id"] != args.expected_key_id:
            fail("signed document: unexpected key_id")

        if args.command == "validate-rollback":
            verify_document(document, ROLLBACK_SCHEMA, ROLLBACK_CONTEXT, public_key)
            current_state = validate_replay_state(strict_load(args.current_state, "current state"), "current state")
            target_state = validate_replay_state(strict_load(args.target_state, "target state"), "target state")
            nonce = validate_rollback_payload(
                document["signed"],
                now=now,
                current_state=current_state,
                target_state=target_state,
            )
            consume_authorization_receipt(
                args.receipt_directory,
                kind="rollback",
                nonce=nonce,
                details={"current_envelope_sha256": current_state["envelope_sha256"], "target_envelope_sha256": target_state["envelope_sha256"]},
            )
            return 0

        if args.command == "validate-envelope":
            verify_document(document, ENVELOPE_SCHEMA, ENVELOPE_CONTEXT, public_key)
            validate_envelope_payload(
                document["signed"],
                now=now,
                minimum_build=args.minimum_build,
                minimum_generation=args.minimum_envelope_generation,
                expected_set_id=args.expected_set_id,
                expected_set_sha256=args.expected_set_sha256,
            )
            return 0

        envelope_document = strict_load(args.envelope, "signed envelope", require_canonical=True)
        envelope_signature = validate_signature_shape(envelope_document.get("signature"), "signed envelope.signature")
        if envelope_signature["key_id"] != args.expected_key_id:
            fail("signed envelope: unexpected key_id")
        verify_document(envelope_document, ENVELOPE_SCHEMA, ENVELOPE_CONTEXT, public_key)
        envelope_build, envelope_generation = validate_envelope_payload(
            envelope_document["signed"],
            now=now,
            minimum_build=args.minimum_build,
            minimum_generation=args.minimum_envelope_generation,
        )
        verify_document(document, INDEX_SCHEMA, INDEX_CONTEXT, public_key)
        envelope_digest = hashlib.sha256(canonical_bytes(envelope_document)).hexdigest()
        _, indexed_build, indexed_generation, _ = validate_index_payload(
            document["signed"],
            now=now,
            expected_channel=args.expected_channel,
            minimum_index_generation=args.minimum_index_generation,
            minimum_build=args.minimum_build,
            minimum_envelope_generation=args.minimum_envelope_generation,
            expected_envelope_sha256=envelope_digest,
            expected_keyring_generation=keyring_generation,
            expected_keyring_sha256=keyring_sha256,
            expected_revocations_generation=revocations_generation,
            expected_revocations_sha256=revocations_sha256,
            installed_transaction=args.installed_transaction,
        )
        if indexed_build != envelope_build or indexed_generation != envelope_generation:
            fail("index: build/generation differs from signed envelope")
        return 0
    except ContractError as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
