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

The tuple file holds one tuple input object, or a JSON array of them (one per
admitted model tuple, SPEC-048 0.1.35); `--tuple` may also be repeated. All
entries share the release-owned fields and are emitted sorted by the SPEC-023
entry key. A single tuple input produces the same bytes as before.

The `projection` command renders the release's
`native-mtp-artifact-manifest.json` from a JSON object keyed by `model_key`
whose values are the closed `{target, mtp, tokenizer, manifest}` artifact
objects: the v1 form for one model (byte-identical to the pre-0.1.35 file),
the v2 form keyed by `model_key` for more than one.

Output is canonical bytes (sorted keys, no insignificant whitespace, UTF-8),
the form the static-feed signer signs. The command also prints the
`sidecar_sha256` and the domain-separated `native_mtp_admission_tuple_sha256`
that the serving journey binds. Signing is an operator step with the
static-feed key (scripts/resign-autotune-static.sh `sign_one` procedure); this
script refuses to read any key.

Usage:
  python3 scripts/native_mtp_admission_sidecar.py build \\
      --tuple <tuple.json> [--tuple <tuple.json> ...] --release <release.json> \\
      --out <native-mtp-admission.json>
  python3 scripts/native_mtp_admission_sidecar.py identity --sidecar <native-mtp-admission.json>
  python3 scripts/native_mtp_admission_sidecar.py projection \\
      --models <projection-models.json> --out <native-mtp-artifact-manifest.json>
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
PROJECTION_V1_SCHEMA = "macprovider.native-mtp-artifact-projection.v1"
PROJECTION_V2_SCHEMA = "macprovider.native-mtp-artifact-projection.v2"
PROJECTION_ARTIFACTS = {"target", "mtp", "tokenizer", "manifest"}
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
# SPEC-048-R013 (0.1.51): optional together. Qualification-owned (tuple
# input): the decode path the tuple qualified on. A CLI that embeds the same
# digest serves the entry without a new admission (scripts/decode_path_digest.py).
# CLIs before the decode-path reader reject unknown entry keys, so these are
# published only once the bound release CLI embeds a digest (R014 item 10).
DECODE_PATH_KEYS = ("decode_path_digest", "metallib_sha256")
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
# SPEC-023 v0.22.27: each quantization exceptions array holds at most 1024
# entries (256 before); GLM-5.3-Flash carries 554 per-module overrides.
MAX_QUANTIZATION_EXCEPTIONS = 1024
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
    _sorted_unique(q["unquantized_exceptions"], f"{path}.unquantized_exceptions", MAX_QUANTIZATION_EXCEPTIONS, EXCEPTION)
    _sorted_unique(q["per_layer_exceptions"], f"{path}.per_layer_exceptions", MAX_QUANTIZATION_EXCEPTIONS, EXCEPTION)
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
    if not isinstance(entry, dict):
        fail(path, "must be an object")
    present = set(DECODE_PATH_KEYS) & entry.keys()
    if present and present != set(DECODE_PATH_KEYS):
        fail(path, f"decode-path binding needs both {list(DECODE_PATH_KEYS)}, got {sorted(present)}")
    entry = _exact_keys(entry, ENTRY_KEYS | present, path)
    for key in sorted(present):
        _str(entry[key], f"{path}.{key}", SHA256)
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
    # SPEC-048 MTP-2 (0.1.43): glm5_next serves native MTP on one active row.
    if entry["mtp_family_adapter"] == "glm5_next_mtp_v1" and bound > 1:
        fail(f"{path}.max_native_active_rows", "glm5_next_mtp_v1 signs at most 1 native active row")
    if bound > slots:
        fail(f"{path}.max_native_active_rows", "exceeds qualified_slots")
    if entry["request_feature_profile"] not in PROFILES:
        fail(f"{path}.request_feature_profile", "unsupported")
    # SPEC-048 MTP-2: the glm5_next drafter proposes greedily only.
    if entry["mtp_family_adapter"] == "glm5_next_mtp_v1" and entry["request_feature_profile"] != "native_mtp_greedy_text_v1":
        fail(f"{path}.request_feature_profile", "glm5_next_mtp_v1 is greedy only")
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


def entry_sort_key(entry: dict) -> list[str]:
    """SPEC-023 §12.5 entry order: (model_key, artifact_id, hardware_class,
    ram_bytes, qualified_slots, proposal_depth, quantization.kind), bytewise."""
    return [
        entry["model_key"], entry["artifact_id"], entry["hardware_class"], str(entry["ram_bytes"]),
        str(entry["qualified_slots"]), str(entry["proposal_depth"]), entry["quantization"]["kind"],
    ]


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
        keys.append(entry_sort_key(entry))
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


def _tuple_entry(tuple_input: object, path: str) -> dict:
    tuple_input = _exact_keys(tuple_input, {"schema_version", "entry"}, path)
    if tuple_input["schema_version"] != TUPLE_INPUT_SCHEMA:
        fail(f"{path}.schema_version", f"must be {TUPLE_INPUT_SCHEMA}")
    fixed = tuple_input["entry"]
    if not isinstance(fixed, dict):
        fail(f"{path}.entry", "must be an object")
    owned = set(RELEASE_ENTRY_KEYS) & fixed.keys()
    if owned:
        fail(f"{path}.entry", f"release-owned fields {sorted(owned)} must come from the release input")
    if "provider_revision" in (fixed.get("ordinary_baseline") or {}):
        fail(f"{path}.entry.ordinary_baseline.provider_revision", "is release-owned; omit it")
    return fixed


def build(tuple_input: dict | list, release_input: dict) -> bytes:
    """Render the sidecar from one tuple input object or a list of them.

    Every tuple's entry takes the same release-owned fields (one release, one
    projection manifest, one challenge bank) and the entries are sorted by the
    SPEC-023 key; a duplicate key fails. One tuple input renders exactly the
    bytes it rendered before multi-entry support."""
    if isinstance(tuple_input, list):
        if not tuple_input:
            fail("$tuple", "must hold at least one tuple input")
        if len(tuple_input) > 256:
            fail("$tuple", "must hold at most 256 tuple inputs")
        fixed_entries = [_tuple_entry(item, f"$tuple[{index}]") for index, item in enumerate(tuple_input)]
    else:
        fixed_entries = [_tuple_entry(tuple_input, "$tuple")]
    release_keys = {"schema_version", "release_id", "issued_at", "expires_at", "signer_key_id",
                    "challenge_bank_signer_key_id", "revocation_signer_key_id", "entry"}
    if isinstance(release_input, dict) and "provider_decode_path_digest" in release_input:
        release_keys.add("provider_decode_path_digest")
    release_input = _exact_keys(release_input, release_keys, "$release")
    # SPEC-048-R013 (0.1.51): the digest embedded in the bound release CLI
    # (`decode_path_digest.py --binary`). A decode-path entry is published only
    # when the bound CLI embeds that same digest: the CLI then reads the field,
    # and its decode path is the one the tuple qualified on.
    provider_digest = release_input.get("provider_decode_path_digest")
    if provider_digest is not None:
        _str(provider_digest, "$release.provider_decode_path_digest", SHA256)
    for index, fixed in enumerate(fixed_entries):
        if "decode_path_digest" not in fixed:
            continue
        if provider_digest is None:
            fail(f"$tuple[{index}].entry.decode_path_digest",
                 "needs $release.provider_decode_path_digest: publish a decode-path entry only once "
                 "the bound release CLI embeds a decode-path digest (SPEC-048-R014 item 10)")
        if fixed["decode_path_digest"] != provider_digest:
            fail(f"$tuple[{index}].entry.decode_path_digest",
                 "differs from the bound release CLI's decode path; requalify (AGENTS.md rule 2)")
    if release_input["schema_version"] != RELEASE_INPUT_SCHEMA:
        fail("$release.schema_version", f"must be {RELEASE_INPUT_SCHEMA}")
    release_entry = _exact_keys(release_input["entry"], set(RELEASE_ENTRY_KEYS), "$release.entry")
    entries = []
    for fixed in fixed_entries:
        entry = {**fixed, **release_entry}
        baseline = dict(entry.get("ordinary_baseline") or {})
        baseline["provider_revision"] = release_entry["provider_revision"]
        entry["ordinary_baseline"] = baseline
        entries.append(entry)
    if len(entries) > 1:
        # Validate before sorting so a malformed entry reports its input index.
        for index, entry in enumerate(entries):
            validate_entry(entry, f"$tuple[{index}].entry")
        entries.sort(key=lambda entry: [part.encode("utf-8") for part in entry_sort_key(entry)])
    body = {key: release_input[key] for key in TOP_KEYS - {"entries"}}  # provider_decode_path_digest is input-only
    body["schema_version"] = SCHEMA_VERSION
    body["entries"] = entries
    return canonical_bytes(validate_sidecar(body))


def _projection_artifacts(value: object, path: str) -> dict:
    artifacts = _exact_keys(value, PROJECTION_ARTIFACTS, path)
    for name in sorted(PROJECTION_ARTIFACTS):
        artifact = _exact_keys(artifacts[name], {"path", "sha256"}, f"{path}.{name}")
        _str(artifact["path"], f"{path}.{name}.path", max_bytes=1024)
        if artifact["path"].startswith("/") or ".." in artifact["path"].split("/"):
            fail(f"{path}.{name}.path", "must be a relative path without '..'")
        _str(artifact["sha256"], f"{path}.{name}.sha256", SHA256)
    return artifacts


def build_projection(models: object) -> bytes:
    """SPEC-048 0.1.35 projection manifest: v1 for one model_key (the exact
    pre-0.1.35 bytes), v2 keyed by model_key for more than one."""
    if not isinstance(models, dict) or not 1 <= len(models) <= 256:
        fail("$models", "must be an object of 1..256 model_key entries")
    for model_key, artifacts in models.items():
        _str(model_key, f"$models[{model_key!r}]")
        _projection_artifacts(artifacts, f"$models[{model_key!r}]")
    if len(models) == 1:
        (artifacts,) = models.values()
        return canonical_bytes({"schema_version": PROJECTION_V1_SCHEMA, "artifacts": artifacts})
    return canonical_bytes({"schema_version": PROJECTION_V2_SCHEMA, "models": models})


def read_projection(manifest_bytes: bytes, model_keys: list[str], model_key: str) -> dict:
    """Select `model_key`'s artifacts from either projection form, as the
    consumer does. `model_keys` are the sidecar's entry model keys: a v1 file
    serves exactly one distinct model key, a v2 file exactly the set named."""
    value = strict_json_loads(manifest_bytes.decode("utf-8"))
    if not isinstance(value, dict):
        fail("$projection", "must be an object")
    distinct = set(model_keys)
    if model_key not in distinct:
        fail("$projection", f"model_key {model_key!r} is not an entry of the sidecar")
    if value.get("schema_version") == PROJECTION_V1_SCHEMA:
        value = _exact_keys(value, {"schema_version", "artifacts"}, "$projection")
        if len(distinct) != 1:
            fail("$projection", "a v1 projection serves exactly one model_key")
        return _projection_artifacts(value["artifacts"], "$projection.artifacts")
    if value.get("schema_version") == PROJECTION_V2_SCHEMA:
        value = _exact_keys(value, {"schema_version", "models"}, "$projection")
        models = value["models"]
        if not isinstance(models, dict) or set(models) != distinct:
            fail("$projection.models", "must name exactly the sidecar's model keys")
        return _projection_artifacts(models[model_key], f"$projection.models[{model_key!r}]")
    fail("$projection.schema_version", f"must be {PROJECTION_V1_SCHEMA} or {PROJECTION_V2_SCHEMA}")


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
    build_parser.add_argument("--tuple", type=Path, required=True, action="append")
    build_parser.add_argument("--release", type=Path, required=True)
    build_parser.add_argument("--out", type=Path, required=True)
    identity_parser = sub.add_parser("identity")
    identity_parser.add_argument("--sidecar", type=Path, required=True)
    projection_parser = sub.add_parser("projection")
    projection_parser.add_argument("--models", type=Path, required=True)
    projection_parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            loaded = [strict_json_loads(path.read_text("utf-8")) for path in args.tuple]
            tuples: dict | list = loaded[0] if len(loaded) == 1 else [
                item for value in loaded for item in (value if isinstance(value, list) else [value])
            ]
            data = build(tuples, strict_json_loads(args.release.read_text("utf-8")))
            args.out.write_bytes(data)
            print(json.dumps(identity(data), indent=2, sort_keys=True))
        elif args.command == "projection":
            data = build_projection(strict_json_loads(args.models.read_text("utf-8")))
            args.out.write_bytes(data)
            print(json.dumps({"artifact_manifest_sha256": hashlib.sha256(data).hexdigest()}, indent=2))
        else:
            print(json.dumps(identity(args.sidecar.read_bytes()), indent=2, sort_keys=True))
    except (SidecarError, json.JSONDecodeError, OSError) as exc:
        print(f"native_mtp_admission_sidecar: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
