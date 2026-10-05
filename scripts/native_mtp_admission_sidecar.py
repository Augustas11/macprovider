#!/usr/bin/env python3
"""Build the unsigned SPEC-023-R024 native-MTP admission sidecar.

The sidecar body is the exact closed object of SPEC-023 §12.5. This tool
renders it from two inputs and never signs anything:

- a committed tuple file (`macprovider.native-mtp-admission-tuple-input.v1`)
  holding every entry field fixed by the qualified tuple and its evidence, and
- a release file (`macprovider.native-mtp-admission-release-input.v1`) holding
  the fields only a release cut can know: release id, validity window, signer
  key ids, source commit, provider revision, reproducible build digest, live
  executable CDHash, challenge-bank and artifact-projection digests.

Output is canonical bytes (sorted keys, no insignificant whitespace, UTF-8),
the form the static-feed signer signs. The command also prints the
`sidecar_sha256` and the domain-separated `native_mtp_admission_tuple_sha256`
that the serving journey binds. Signing is an operator step with the
static-feed key (scripts/resign-autotune-static.sh `sign_one` procedure); this
script refuses to read any key.

Usage:
  python3 scripts/native_mtp_admission_sidecar.py build \\
      --tuple <tuple.json> --release <release.json> --out <native-mtp-admission.json>
  python3 scripts/native_mtp_admission_sidecar.py identity --sidecar <native-mtp-admission.json>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCHEMA_VERSION = "macprovider.native-mtp-admission.v1"
TUPLE_IDENTITY_SCHEMA = "macprovider.native-mtp-admission-tuple.v1"
TUPLE_IDENTITY_DOMAIN = "macprovider.native-mtp-admission-tuple.v1\n"
TUPLE_INPUT_SCHEMA = "macprovider.native-mtp-admission-tuple-input.v1"
RELEASE_INPUT_SCHEMA = "macprovider.native-mtp-admission-release-input.v1"
HASH_ALGORITHM = "macprovider.snapshot-manifest.v1"

SHA256 = re.compile(r"^[0-9a-f]{64}$")
CDHASH = re.compile(r"^[0-9a-f]{40}$")
# The Swift consumer accepts only SHA-1 object ids; emit only what it accepts.
COMMIT = re.compile(r"^[0-9a-f]{40}$")
ARTIFACT_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
# Envelope identifiers: the consumer's requireASCIIString (0x21...0x7e, no space).
ENVELOPE_ID = re.compile(r"^[\x21-\x7e]+$")
PLACEHOLDER_SHA256 = "0" * 64
# The Swift consumer accepts the stricter `[a-z0-9-]` subset of the SPEC-023
# grammar; emit only what it accepts.
HARDWARE_CLASS = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
EXCEPTION = re.compile(r"^(?:target|mtp)/[\x21-\x2e\x30-\x7e]+$")
RFC3339 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

EVIDENCE_KEYS = (
    "fit_evidence_sha256",
    "quality_evidence_sha256",
    "correctness_evidence_sha256",
    "state_rollback_evidence_sha256",
    "batch_evidence_sha256",
    "performance_evidence_sha256",
    "security_negative_evidence_sha256",
)

# Entry fields owned by the release cut; every other entry field comes from
# the committed tuple input.
RELEASE_ENTRY_KEYS = (
    "artifact_manifest_sha256",
    "provider_revision",
    "source_commit",
    "reproducible_build_sha256",
    "live_executable_cdhash",
    "challenge_bank_sha256",
)

ENTRY_KEYS = {
    "model_key", "artifact_id", "hash_algorithm", "artifact_hash",
    "artifact_manifest_sha256", "tokenizer_sha256", "decode_path",
    "mtp_manifest_sha256", "mtp_family_adapter", "mtp_state_class",
    "mtp_head_count", "proposal_depth", "complete_window_bytes_by_depth",
    "runtime_revision", "provider_revision", "source_commit",
    "reproducible_build_sha256", "live_executable_cdhash",
    "cache_state_classes", "hardware_class", "ram_bytes", "qualified_slots",
    "max_native_active_rows", "request_feature_profile", "max_prompt_tokens",
    "decrease_threshold_ppm", "increase_threshold_ppm",
    "max_verification_positions_per_committed_milli", "throughput_delta_ppm",
    "benchmark_policy_sha256", "challenge_bank_sha256", *EVIDENCE_KEYS,
    "quantization", "ordinary_baseline",
}
QUANTIZATION_KEYS = {
    "kind", "packed_data_dtype", "packed_layout", "scale_dtype", "scale_layout",
    "block_size_elements", "alignment_bytes", "padding_rule",
    "unquantized_exceptions", "per_layer_exceptions", "representation_manifest_sha256",
}
BASELINE_KEYS = {
    "decode_path", "runtime_revision", "provider_revision", "artifact_hash",
    "qualified_slots", "measurement_sha256", "aggregate_tps_milli",
}
TOP_KEYS = {
    "schema_version", "release_id", "issued_at", "expires_at", "signer_key_id",
    "challenge_bank_signer_key_id", "revocation_signer_key_id", "entries",
}
STATE_CLASSES = {"stageable_rewindable", "hybrid_stageable_rewindable"}
PROFILES = {"native_mtp_greedy_text_v1", "native_mtp_sampled_text_v1"}
INT_MAX = (1 << 63) - 1
MAX_PROPOSAL_DEPTH = 6


class SidecarError(ValueError):
    pass


def fail(path: str, message: str) -> None:
    raise SidecarError(f"{path}: {message}")


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys):
        raise SidecarError(f"duplicate JSON key in {sorted(k for k in set(keys) if keys.count(k) > 1)}")
    return dict(pairs)


def strict_json_loads(text: str) -> object:
    """json.loads that rejects duplicate object keys, as the Swift parser does."""
    return json.loads(text, object_pairs_hook=_reject_duplicate_keys)


def canonical_bytes(value: object) -> bytes:
    """Sorted-key compact UTF-8 JSON. For the ASCII strings, integers, nulls,
    and arrays this schema admits it is also the RFC 8785 JCS form."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def _int(value: object, path: str, lo: int, hi: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not lo <= value <= hi:
        fail(path, f"must be an integer in {lo}..{hi}")
    return value


def _str(value: object, path: str, pattern: re.Pattern | None = None, max_bytes: int = 128) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > max_bytes:
        fail(path, f"must be a 1..{max_bytes} byte string")
    # Printable ASCII only: the Swift consumer canonicalizes strings (Unicode
    # normalization) before hashing the tuple identity, so a non-ASCII value
    # could hash differently there than here.
    if any(not 0x20 <= ord(ch) <= 0x7E for ch in value):
        fail(path, "must be printable ASCII")
    # The consumer rejects strings with leading or trailing whitespace.
    if value != value.strip():
        fail(path, "must not have leading or trailing whitespace")
    if pattern is not None and not pattern.match(value):
        fail(path, f"does not match {pattern.pattern}")
    return value


def _exact_keys(obj: object, keys: set[str], path: str) -> dict:
    if not isinstance(obj, dict):
        fail(path, "must be an object")
    missing, extra = keys - obj.keys(), obj.keys() - keys
    if missing or extra:
        fail(path, f"missing {sorted(missing)} extra {sorted(extra)}")
    return obj


def _sorted_unique(values: object, path: str, max_items: int, pattern: re.Pattern) -> list[str]:
    if not isinstance(values, list) or len(values) > max_items:
        fail(path, f"must be an array of at most {max_items}")
    for index, item in enumerate(values):
        _str(item, f"{path}[{index}]", pattern)
    encoded = [v.encode("utf-8") for v in values]
    if encoded != sorted(encoded) or len(set(values)) != len(values):
        fail(path, "must be bytewise sorted and unique")
    return values


def _timestamp(value: object, path: str) -> datetime:
    text = _str(value, path, RFC3339)
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def validate_quantization(q: object, path: str) -> None:
    q = _exact_keys(q, QUANTIZATION_KEYS, path)
    kind = q["kind"]
    if kind not in {"base", "mlx_affine", "mlx_mxfp8"}:
        fail(f"{path}.kind", "unsupported")
    _sorted_unique(q["unquantized_exceptions"], f"{path}.unquantized_exceptions", 256, EXCEPTION)
    _sorted_unique(q["per_layer_exceptions"], f"{path}.per_layer_exceptions", 256, EXCEPTION)
    _str(q["representation_manifest_sha256"], f"{path}.representation_manifest_sha256", SHA256)
    if kind == "mlx_affine":
        expected = {
            "packed_data_dtype": "uint32",
            "packed_layout": "mlx_array_native_v1",
            "scale_dtype": "bfloat16",
            "scale_layout": "per_block",
            "alignment_bytes": None,
            "padding_rule": "none",
        }
        for key, value in expected.items():
            if q[key] != value:
                fail(f"{path}.{key}", f"must be {value!r} for mlx_affine")
        if q["block_size_elements"] not in (32, 64, 128) or isinstance(q["block_size_elements"], bool):
            fail(f"{path}.block_size_elements", "must be 32, 64, or 128 for mlx_affine")
    elif kind == "base":
        for key in ("packed_data_dtype", "packed_layout", "scale_dtype", "scale_layout", "padding_rule"):
            if q[key] != "none":
                fail(f"{path}.{key}", "must be none for base")
        if q["block_size_elements"] is not None or q["alignment_bytes"] is not None:
            fail(path, "base numeric fields must be null")
        if q["unquantized_exceptions"] or q["per_layer_exceptions"]:
            fail(path, "base exception arrays must be empty")
    else:
        fail(f"{path}.kind", "mlx_mxfp8 is not admitted until SPEC-048-R012 qualifies an artifact")


def validate_entry(entry: object, path: str) -> dict:
    entry = _exact_keys(entry, ENTRY_KEYS, path)
    _str(entry["model_key"], f"{path}.model_key")
    _str(entry["artifact_id"], f"{path}.artifact_id", ARTIFACT_ID)
    if entry["hash_algorithm"] != HASH_ALGORITHM:
        fail(f"{path}.hash_algorithm", f"must be {HASH_ALGORITHM}")
    for key in ("artifact_hash", "artifact_manifest_sha256", "tokenizer_sha256", "mtp_manifest_sha256",
                "reproducible_build_sha256", "benchmark_policy_sha256", "challenge_bank_sha256", *EVIDENCE_KEYS):
        _str(entry[key], f"{path}.{key}", SHA256)
        # An all-zero digest is the committed "evidence pending" placeholder;
        # a signable sidecar must bind real evidence bytes.
        if entry[key] == PLACEHOLDER_SHA256:
            fail(f"{path}.{key}", "is the pending-evidence placeholder; bind the real evidence digest")
    if entry["decode_path"] != "native_mtp":
        fail(f"{path}.decode_path", "must be native_mtp")
    _str(entry["mtp_family_adapter"], f"{path}.mtp_family_adapter")
    if entry["mtp_state_class"] not in STATE_CLASSES:
        fail(f"{path}.mtp_state_class", "unsupported")
    _int(entry["mtp_head_count"], f"{path}.mtp_head_count", 1, 16)
    # SPEC-023-R024 / SPEC-048 0.1.23: a verify row (depth + 1 tokens) must stay
    # inside the fused MoE envelope of seven tokens per row.
    depth = _int(entry["proposal_depth"], f"{path}.proposal_depth", 1, MAX_PROPOSAL_DEPTH)
    slots = _int(entry["qualified_slots"], f"{path}.qualified_slots", 2, 8)
    windows = entry["complete_window_bytes_by_depth"]
    if not isinstance(windows, list) or len(windows) != depth + 1:
        fail(f"{path}.complete_window_bytes_by_depth", "must have proposal_depth + 1 values")
    for index, value in enumerate(windows):
        _int(value, f"{path}.complete_window_bytes_by_depth[{index}]", 1, INT_MAX)
    if windows != sorted(windows) or windows[-1] * slots > INT_MAX:
        fail(f"{path}.complete_window_bytes_by_depth", "must be nondecreasing and fit max*slots")
    _str(entry["runtime_revision"], f"{path}.runtime_revision")
    _str(entry["provider_revision"], f"{path}.provider_revision")
    _str(entry["source_commit"], f"{path}.source_commit", COMMIT)
    _str(entry["live_executable_cdhash"], f"{path}.live_executable_cdhash", CDHASH)
    classes = _sorted_unique(entry["cache_state_classes"], f"{path}.cache_state_classes", 16, re.compile(r"^[a-z_]+$"))
    if not classes or not set(classes) <= STATE_CLASSES or entry["mtp_state_class"] not in classes:
        fail(f"{path}.cache_state_classes", "must be admitted state classes containing mtp_state_class")
    _str(entry["hardware_class"], f"{path}.hardware_class", HARDWARE_CLASS)
    _int(entry["ram_bytes"], f"{path}.ram_bytes", 1, INT_MAX)
    bound = _int(entry["max_native_active_rows"], f"{path}.max_native_active_rows", 1, 8)
    if bound > slots:
        fail(f"{path}.max_native_active_rows", "exceeds qualified_slots")
    if entry["request_feature_profile"] not in PROFILES:
        fail(f"{path}.request_feature_profile", "unsupported")
    _int(entry["max_prompt_tokens"], f"{path}.max_prompt_tokens", 1, 1_048_576)
    low = _int(entry["decrease_threshold_ppm"], f"{path}.decrease_threshold_ppm", 0, 1_000_000)
    high = _int(entry["increase_threshold_ppm"], f"{path}.increase_threshold_ppm", 0, 1_000_000)
    if low >= high:
        fail(f"{path}.increase_threshold_ppm", "must exceed decrease_threshold_ppm")
    _int(entry["max_verification_positions_per_committed_milli"],
         f"{path}.max_verification_positions_per_committed_milli", 1000, 4000)
    _int(entry["throughput_delta_ppm"], f"{path}.throughput_delta_ppm", -1_000_000, 1_000_000)
    validate_quantization(entry["quantization"], f"{path}.quantization")
    baseline = _exact_keys(entry["ordinary_baseline"], BASELINE_KEYS, f"{path}.ordinary_baseline")
    if baseline["decode_path"] != "ordinary":
        fail(f"{path}.ordinary_baseline.decode_path", "must be ordinary")
    for key in ("runtime_revision", "provider_revision", "artifact_hash"):
        if baseline[key] != entry[key]:
            fail(f"{path}.ordinary_baseline.{key}", "must equal the entry value")
    if baseline["qualified_slots"] != slots:
        fail(f"{path}.ordinary_baseline.qualified_slots", "must equal the entry value")
    _str(baseline["measurement_sha256"], f"{path}.ordinary_baseline.measurement_sha256", SHA256)
    _int(baseline["aggregate_tps_milli"], f"{path}.ordinary_baseline.aggregate_tps_milli", 1, INT_MAX)
    return entry


def validate_sidecar(body: object) -> dict:
    body = _exact_keys(body, TOP_KEYS, "$")
    if body["schema_version"] != SCHEMA_VERSION:
        fail("$.schema_version", f"must be {SCHEMA_VERSION}")
    _str(body["release_id"], "$.release_id", ENVELOPE_ID)
    issued = _timestamp(body["issued_at"], "$.issued_at")
    expires = _timestamp(body["expires_at"], "$.expires_at")
    if not issued < expires <= issued + timedelta(days=90):
        fail("$.expires_at", "must be after issued_at and at most 90 days later")
    for key in ("signer_key_id", "challenge_bank_signer_key_id", "revocation_signer_key_id"):
        _str(body[key], f"$.{key}", ENVELOPE_ID)
    entries = body["entries"]
    if not isinstance(entries, list) or not 1 <= len(entries) <= 256:
        fail("$.entries", "must hold 1..256 entries")
    keys = []
    for index, entry in enumerate(entries):
        validate_entry(entry, f"$.entries[{index}]")
        keys.append([
            entry["model_key"], entry["artifact_id"], entry["hardware_class"], str(entry["ram_bytes"]),
            str(entry["qualified_slots"]), str(entry["proposal_depth"]), entry["quantization"]["kind"],
        ])
    if any(not a < b for a, b in zip(keys, keys[1:])):
        fail("$.entries", "must be unique and sorted by the SPEC-023 sort key")
    return body


def admission_tuple_sha256(release_id: str, sidecar_sha256: str, entry: dict) -> str:
    identity = {
        "schema_version": TUPLE_IDENTITY_SCHEMA,
        "release_id": release_id,
        "sidecar_sha256": sidecar_sha256,
        "entry": entry,
    }
    return hashlib.sha256(TUPLE_IDENTITY_DOMAIN.encode("utf-8") + canonical_bytes(identity)).hexdigest()


def build(tuple_input: dict, release_input: dict) -> bytes:
    tuple_input = _exact_keys(tuple_input, {"schema_version", "entry"}, "$tuple")
    if tuple_input["schema_version"] != TUPLE_INPUT_SCHEMA:
        fail("$tuple.schema_version", f"must be {TUPLE_INPUT_SCHEMA}")
    fixed = tuple_input["entry"]
    if not isinstance(fixed, dict):
        fail("$tuple.entry", "must be an object")
    owned = set(RELEASE_ENTRY_KEYS) & fixed.keys()
    if owned:
        fail("$tuple.entry", f"release-owned fields {sorted(owned)} must come from the release input")
    release_input = _exact_keys(
        release_input,
        {"schema_version", "release_id", "issued_at", "expires_at", "signer_key_id",
         "challenge_bank_signer_key_id", "revocation_signer_key_id", "entry"},
        "$release",
    )
    if release_input["schema_version"] != RELEASE_INPUT_SCHEMA:
        fail("$release.schema_version", f"must be {RELEASE_INPUT_SCHEMA}")
    release_entry = _exact_keys(release_input["entry"], set(RELEASE_ENTRY_KEYS), "$release.entry")
    entry = {**fixed, **release_entry}
    baseline = dict(entry.get("ordinary_baseline") or {})
    if "provider_revision" in baseline:
        fail("$tuple.entry.ordinary_baseline.provider_revision", "is release-owned; omit it")
    baseline["provider_revision"] = release_entry["provider_revision"]
    entry["ordinary_baseline"] = baseline
    body = {key: release_input[key] for key in TOP_KEYS - {"entries"}}
    body["schema_version"] = SCHEMA_VERSION
    body["entries"] = [entry]
    return canonical_bytes(validate_sidecar(body))


def identity(sidecar_bytes: bytes) -> dict:
    body = validate_sidecar(strict_json_loads(sidecar_bytes.decode("utf-8")))
    sidecar_sha = hashlib.sha256(sidecar_bytes).hexdigest()
    return {
        "sidecar_sha256": sidecar_sha,
        "native_mtp_admission_tuple_sha256": [
            admission_tuple_sha256(body["release_id"], sidecar_sha, entry) for entry in body["entries"]
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    build_parser = sub.add_parser("build")
    build_parser.add_argument("--tuple", type=Path, required=True)
    build_parser.add_argument("--release", type=Path, required=True)
    build_parser.add_argument("--out", type=Path, required=True)
    identity_parser = sub.add_parser("identity")
    identity_parser.add_argument("--sidecar", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            data = build(strict_json_loads(args.tuple.read_text("utf-8")), strict_json_loads(args.release.read_text("utf-8")))
            args.out.write_bytes(data)
            print(json.dumps(identity(data), indent=2, sort_keys=True))
        else:
            print(json.dumps(identity(args.sidecar.read_bytes()), indent=2, sort_keys=True))
    except (SidecarError, json.JSONDecodeError, OSError) as exc:
        print(f"native_mtp_admission_sidecar: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
