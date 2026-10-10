#!/usr/bin/env python3
"""Evidence contract for JOURNEY-NATIVE-MTP-SERVING and JOURNEY-NATIVE-MTP-RELEASE.

A run writes a reviewed redacted bundle, `journeys/evidence/native-mtp-<serving|release>-<ts>/`,
holding `MANIFEST.sha256` (`<sha256>  ./<path>` per file, sorted) and the
step artifacts. `compose_evidence` recomputes the closed evidence object the
journey document defines from that bundle; every digest and boolean is derived
from a bundle file, never self-asserted. `build_payload` validates committed
evidence against its bundle at a reviewed commit and projects the unsigned
journey-result payload `sign-journey-result.py` signs; `validate_signed_payload`
is the governance re-check before any conformance promotion.

Bundle layout (serving):
  native-mtp-admission.json        the signed sidecar bytes (SPEC-023-R024)
  r015-policy.json                 the frozen SPEC-048-R015 benchmark policy
  steps/<step-id>.json             one `macprovider.native-mtp-journey-step.v1` per step

Bundle layout (release):
  steps/<step-id>.json, reviews/<code|security|architecture>.json,
  target-ref-attestation.json, serving-journey-result.signed.json,
  native-mtp-admission.json
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "Augustas11/macprovider"
EVIDENCE_DIR = "journeys/evidence/"
EVIDENCE_SUFFIX = ".redacted.json"
MANIFEST_NAME = "MANIFEST.sha256"
STEP_SCHEMA = "macprovider.native-mtp-journey-step.v1"
REVIEW_SCHEMA = "macprovider.native-mtp-review-verdict.v1"
PAYLOAD_SCHEMA = "macprovider.journey-result.v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
OBJECT_ID_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
COMPACT_RE = re.compile(r"^\d{8}T\d{6}Z$")
SAFE_COMPONENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MANIFEST_LINE_RE = re.compile(r"^([0-9a-f]{64})  \./([A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*)$")
MAX_BUNDLE_FILES = 512
MAX_BUNDLE_FILE_BYTES = 8 << 20

SERVING = "serving"
RELEASE = "release"
JOURNEY_IDS = {SERVING: "JOURNEY-NATIVE-MTP-SERVING", RELEASE: "JOURNEY-NATIVE-MTP-RELEASE"}
EVIDENCE_SCHEMAS = {
    SERVING: "macprovider.native-mtp-serving-evidence.v1",
    RELEASE: "macprovider.native-mtp-release-evidence.v1",
}
EXPIRY_DAYS = {SERVING: 90, RELEASE: 30}
R015_POLICY_SCHEMA = "macprovider.native-mtp-r015-policy.v1"

SERVING_REQUIREMENTS = sorted([
    "SPEC-023-R024", "SPEC-030-R021", "SPEC-031-R033", "SPEC-036-R018", "SPEC-038-R018", "SPEC-039-R015",
    *(f"SPEC-048-R{n:03d}" for n in range(1, 14)), "SPEC-048-R015", "SPEC-048-R016",
])
RELEASE_REQUIREMENTS = ["SPEC-048-R014"]

SERVING_STEPS = [
    "step-01-bind-tuple", "step-02-capability-negatives", "step-03-artifact-security-negatives",
    "step-04-serial-token-oracle", "step-05-cache-state-boundary", "step-06-streaming-stop",
    "step-07-mixed-multirow", "step-08-capacity-and-depth-zero", "step-09-cancellation",
    "step-10-warm-swap", "step-11-accounting", "step-12-native-canary",
    "step-13-mxfp8-independent-and-combined", "step-14-studio-and-tier-benchmark",
    "step-15-redaction-review",
]
MXFP8_STEP = "step-13-mxfp8-independent-and-combined"
RELEASE_STEPS = [
    "step-01-preconditions", "step-02-review-verdicts", "step-03-final-binary-binding",
    "step-04-isolated-loopback", "step-05-release-assets", "step-06-production-config",
    "step-07-redaction",
]

# Every serving observation is the value of one named check in one step
# artifact; required-false observations are the negation of a "no ..." check.
# (observation, step, check, required value)
OBSERVATION_SOURCES: list[tuple[str, str, str, bool]] = [
    ("artifact_manifest_fail_closed_verified", "step-02-capability-negatives", "artifact_manifest_fail_closed", True),
    ("emergency_tuple_revocation_verified", "step-02-capability-negatives", "emergency_tuple_revocation", True),
    ("path_traversal_rejected_verified", "step-03-artifact-security-negatives", "path_traversal_rejected", True),
    ("external_reference_rejected_verified", "step-03-artifact-security-negatives", "external_reference_rejected", True),
    ("allocation_and_decompression_bounds_verified", "step-03-artifact-security-negatives", "allocation_and_decompression_bounds", True),
    ("ordinary_decode_remained_available_verified", "step-02-capability-negatives", "ordinary_decode_remained_available", True),
    ("exact_greedy_token_parity_verified", "step-04-serial-token-oracle", "exact_greedy_token_parity", True),
    ("exact_transaction_rewind_verified", "step-05-cache-state-boundary", "exact_transaction_rewind", True),
    ("streaming_and_terminal_parity_verified", "step-06-streaming-stop", "streaming_and_terminal_parity", True),
    ("mixed_multirow_isolation_verified", "step-07-mixed-multirow", "mixed_multirow_isolation", True),
    ("capacity_bound_verified", "step-08-capacity-and-depth-zero", "capacity_bound", True),
    ("cancellation_release_verified", "step-09-cancellation", "cancellation_release", True),
    ("cache_persistence_exclusion_verified", "step-09-cancellation", "cache_persistence_exclusion", True),
    ("warm_swap_tuple_isolation_verified", "step-10-warm-swap", "warm_swap_tuple_isolation", True),
    ("receipt_and_accounting_invariance_verified", "step-11-accounting", "receipt_and_accounting_invariance", True),
    ("benchmark_preregistered_verified", "step-14-studio-and-tier-benchmark", "benchmark_preregistered", True),
    ("material_production_economics_gate_verified", "step-14-studio-and-tier-benchmark", "material_production_economics_gate", True),
    ("all_advertised_hardware_tiers_verified", "step-14-studio-and-tier-benchmark", "all_advertised_hardware_tiers", True),
    ("native_path_canary_verified", "step-12-native-canary", "native_path_canary", True),
    ("native_path_selftest_verified", "step-12-native-canary", "native_path_selftest", True),
    ("losslessness_claimed_path_diagnostic_inconclusive_verified", "step-12-native-canary", "losslessness_claimed_path_diagnostic_inconclusive", True),
    ("compute_integrity_claimed_path_diagnostic_inconclusive_verified", "step-12-native-canary", "compute_integrity_claimed_path_diagnostic_inconclusive", True),
    ("classic_spec_evidence_reused_as_native_mtp", "step-01-bind-tuple", "native_mtp_evidence_only", False),
    ("post_output_path_switch_observed", "step-06-streaming-stop", "no_post_output_path_switch", False),
    ("cross_row_state_bleed_observed", "step-07-mixed-multirow", "no_cross_row_state_bleed", False),
    ("memory_overcommit_observed", "step-08-capacity-and-depth-zero", "no_memory_overcommit", False),
    ("native_mtp_field_entered_receipt_or_billing", "step-11-accounting", "no_native_mtp_field_in_receipt_or_billing", False),
    ("unreleased_local_binary_connected_to_live_coordinator", "step-01-bind-tuple", "no_unreleased_local_binary_on_live_coordinator", False),
    ("secret_or_model_private_material_persisted", "step-15-redaction-review", "no_secret_or_model_private_material", False),
]
OBSERVATIONS = [name for name, _, _, _ in OBSERVATION_SOURCES]

SERVING_KEYS = {
    "schema_version", "journey_id", "native_mtp_admission_tuple_sha256", "requirement_ids", "captured_at",
    "expires_at", "sidecar_sha256", "benchmark_policy_sha256", "steps", "observations", "mxfp8",
    "redaction_manifest_sha256",
}
RELEASE_KEYS = {
    "schema_version", "journey_id", "requirement_ids", "native_mtp_admission_tuple_sha256", "release_id",
    "base_commit", "head_commit", "head_tree_oid", "production_repository", "production_ref", "target_commit",
    "target_ref_attestation_sha256", "diff_sha256", "reviewed_paths_sha256", "dirty", "source_commit",
    "build_sha256", "serving_journey_result_sha256", "sidecar_sha256", "code_review_sha256",
    "security_review_sha256", "architecture_review_sha256", "steps", "captured_at", "expires_at",
    "redaction_manifest_sha256",
}
REVIEW_KEYS = {
    "schema_version", "lane", "reviewer_id", "tool_version", "production_repository", "production_ref",
    "target_commit", "target_ref_attestation_sha256", "base_commit", "head_commit", "head_tree_oid",
    "diff_sha256", "reviewed_paths_sha256", "captured_at", "critical", "high", "medium", "low", "info", "verdict",
}
REVIEW_LANES = ("code", "security", "architecture")
STEP_KEYS = {"schema_version", "step_id", "status", "checks", "details"}


class NativeMTPEvidenceError(ValueError):
    pass


def fail(message: str) -> None:
    raise NativeMTPEvidenceError(message)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _no_duplicates(pairs: list[tuple[str, Any]]) -> dict:
    out: dict = {}
    for key, value in pairs:
        if key in out:
            fail(f"duplicate JSON key {key!r}")
        out[key] = value
    return out


def parse_json(data: bytes, label: str) -> Any:
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_no_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label}: invalid JSON: {exc}")


def parse_timestamp(value: object, label: str) -> datetime:
    if not isinstance(value, str) or not TIMESTAMP_RE.fullmatch(value):
        fail(f"{label} must be RFC3339 UTC seconds")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def rfc3339(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def exact_keys(value: object, keys: set[str], label: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    if set(value) != keys:
        fail(f"{label} keys differ (missing={sorted(keys - set(value))}, extra={sorted(set(value) - keys)})")
    return value


@dataclass
class Bundle:
    relative_dir: str
    files: dict[str, bytes]
    manifest: bytes

    @property
    def manifest_sha256(self) -> str:
        return sha256(self.manifest)

    def require(self, relative: str) -> bytes:
        if relative not in self.files:
            fail(f"bundle {self.relative_dir} lacks {relative}")
        return self.files[relative]

    def json(self, relative: str) -> Any:
        return parse_json(self.require(relative), f"{self.relative_dir}/{relative}")


def bundle_dir_for_source(kind: str, source: str) -> str:
    prefix = f"{EVIDENCE_DIR}native-mtp-{kind}-"
    if not source.startswith(prefix) or not source.endswith(EVIDENCE_SUFFIX):
        fail(f"evidence source must match {prefix}<YYYYMMDDTHHMMSSZ>{EVIDENCE_SUFFIX}")
    if not COMPACT_RE.fullmatch(source[len(prefix):-len(EVIDENCE_SUFFIX)]):
        fail("evidence source must be named by its capture time YYYYMMDDTHHMMSSZ")
    return source[: -len(EVIDENCE_SUFFIX)]


def load_bundle(root: Path, relative_dir: str) -> Bundle:
    if Path(relative_dir).is_absolute() or ".." in Path(relative_dir).parts or not relative_dir.startswith(EVIDENCE_DIR):
        fail("bundle must be a repository-relative journeys/evidence/ directory")
    directory = root / relative_dir
    for parent in [directory, *directory.parents]:
        if parent == root:
            break
        if parent.is_symlink():
            fail(f"bundle path must not traverse a symlink: {relative_dir}")
    if not directory.is_dir():
        fail(f"bundle directory is absent: {relative_dir}")
    files: dict[str, bytes] = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink():
            fail(f"bundle must not contain symlinks: {relative}")
        if path.is_dir():
            continue
        if not all(SAFE_COMPONENT_RE.fullmatch(part) for part in relative.split("/")):
            fail(f"bundle path has an unsafe component: {relative}")
        data = path.read_bytes()
        if len(data) > MAX_BUNDLE_FILE_BYTES:
            fail(f"bundle file is too large: {relative}")
        files[relative] = data
        if len(files) > MAX_BUNDLE_FILES:
            fail("bundle holds too many files")
    manifest = files.pop(MANIFEST_NAME, None)
    if manifest is None:
        fail(f"bundle has no {MANIFEST_NAME}")
    text = manifest.decode("utf-8", errors="strict")
    if not text.endswith("\n"):
        fail(f"{MANIFEST_NAME} must end with a newline")
    listed: dict[str, str] = {}
    previous = b""
    for number, line in enumerate(text[:-1].split("\n"), start=1):
        match = MANIFEST_LINE_RE.fullmatch(line)
        if match is None:
            fail(f"{MANIFEST_NAME}:{number} must be '<sha256>  ./<path>'")
        digest, relative = match.groups()
        key = ("./" + relative).encode()
        if key <= previous:
            fail(f"{MANIFEST_NAME}:{number} paths must be unique and sorted")
        previous = key
        listed[relative] = digest
    if set(listed) != set(files):
        fail(f"{MANIFEST_NAME} must list exactly the bundle files")
    for relative, digest in listed.items():
        if sha256(files[relative]) != digest:
            fail(f"bundle file does not match {MANIFEST_NAME}: {relative}")
    return Bundle(relative_dir, files, manifest)


def manifest_bytes(files: dict[str, bytes]) -> bytes:
    """The canonical MANIFEST.sha256 for `files` (used by the runner and tests)."""
    lines = [f"{sha256(data)}  ./{relative}" for relative, data in sorted(files.items(), key=lambda item: ("./" + item[0]).encode())]
    return ("\n".join(lines) + "\n").encode()


def step_artifact(bundle: Bundle, step_id: str) -> tuple[dict, str]:
    relative = f"steps/{step_id}.json"
    data = bundle.require(relative)
    step = exact_keys(parse_json(data, relative), STEP_KEYS, relative)
    if step["schema_version"] != STEP_SCHEMA or step["step_id"] != step_id:
        fail(f"{relative}: schema_version or step_id mismatch")
    checks = step["checks"]
    if not isinstance(checks, dict) or not checks or not all(isinstance(k, str) and isinstance(v, bool) for k, v in checks.items()):
        fail(f"{relative}: checks must be a nonempty object of booleans")
    if not isinstance(step["details"], dict):
        fail(f"{relative}: details must be an object")
    if step["status"] != "pass" or not all(checks.values()):
        failed = sorted(name for name, ok in checks.items() if not ok)
        fail(f"{relative}: step did not pass (status={step['status']!r}, failed checks={failed})")
    return step, sha256(data)


def _sidecar_generator():
    spec = importlib.util.spec_from_file_location("native_mtp_admission_sidecar", ROOT / "scripts" / "native_mtp_admission_sidecar.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def validated_sidecar_entry(sidecar: bytes, entry_index: object) -> tuple[dict, str]:
    """Return the selected sidecar entry and its canonical SPEC-023-R024 identity."""
    generator = _sidecar_generator()
    try:
        body = generator.validate_sidecar(generator.strict_json_loads(sidecar.decode("utf-8")))
    except (generator.SidecarError, UnicodeDecodeError) as exc:
        fail(f"native-mtp-admission.json: {exc}")
    if not isinstance(entry_index, int) or isinstance(entry_index, bool) or not 0 <= entry_index < len(body["entries"]):
        fail("step-01 details.entry_index must name one sidecar entry")
    entry = body["entries"][entry_index]
    return entry, generator.admission_tuple_sha256(body["release_id"], sha256(sidecar), entry)


def admission_tuple_sha256(sidecar: bytes, entry_index: object) -> str:
    """The canonical SPEC-023-R024 identity of one entry of a signed sidecar."""
    _, tuple_sha = validated_sidecar_entry(sidecar, entry_index)
    return tuple_sha


# --------------------------------------------------------------------------- serving

def compose_serving(bundle: Bundle, *, captured_at: str, expires_at: str | None = None) -> dict[str, Any]:
    captured = parse_timestamp(captured_at, "captured_at")
    expires = parse_timestamp(expires_at, "expires_at") if expires_at else captured + timedelta(days=EXPIRY_DAYS[SERVING])
    steps: dict[str, dict] = {}
    digests: dict[str, str] = {}
    mxfp8 = f"steps/{MXFP8_STEP}.json" in bundle.files
    for step_id in SERVING_STEPS:
        if step_id == MXFP8_STEP and not mxfp8:
            continue
        steps[step_id], digests[step_id] = step_artifact(bundle, step_id)
    sidecar = bundle.require("native-mtp-admission.json")
    policy = bundle.require("r015-policy.json")
    entry_index = steps["step-01-bind-tuple"]["details"].get("entry_index")
    entry, tuple_sha = validated_sidecar_entry(sidecar, entry_index)
    if entry["provider_revision"] != entry["source_commit"] or entry["ordinary_baseline"]["provider_revision"] != entry["source_commit"]:
        fail("selected sidecar entry provider_revision must equal source_commit")
    if entry["benchmark_policy_sha256"] != sha256(policy):
        fail("r015-policy.json is not the benchmark policy the sidecar entry binds")
    policy_body = parse_json(policy, "r015-policy.json")
    if not isinstance(policy_body, dict) or policy_body.get("schema") != R015_POLICY_SCHEMA:
        fail(f"r015-policy.json schema must be {R015_POLICY_SCHEMA}")
    if policy_body.get("provider_commit") != entry["source_commit"]:
        fail("r015-policy.json provider_commit must equal the selected sidecar entry source_commit")
    observations: dict[str, bool] = {}
    for name, step_id, check, required in OBSERVATION_SOURCES:
        value = steps[step_id]["checks"].get(check)
        if value is not True:
            fail(f"observation {name} needs check {check!r} in {step_id}")
        observations[name] = required
    mxfp8_value = None
    if mxfp8:
        details = steps[MXFP8_STEP]["details"]
        mxfp8_value = {
            "independent_qualification_sha256": details.get("independent_qualification_sha256"),
            "combined_requalification_sha256": details.get("combined_requalification_sha256"),
        }
        if not all(isinstance(v, str) and SHA256_RE.fullmatch(v) for v in mxfp8_value.values()):
            fail(f"{MXFP8_STEP} must carry both MXFP8 qualification digests")
    return {
        "schema_version": EVIDENCE_SCHEMAS[SERVING],
        "journey_id": JOURNEY_IDS[SERVING],
        "native_mtp_admission_tuple_sha256": tuple_sha,
        "requirement_ids": list(SERVING_REQUIREMENTS),
        "captured_at": rfc3339(captured),
        "expires_at": rfc3339(expires),
        "sidecar_sha256": sha256(sidecar),
        "benchmark_policy_sha256": sha256(policy),
        "steps": [{"step_id": step_id, "status": "pass", "artifact_sha256": digests[step_id]} for step_id in steps],
        "observations": observations,
        "mxfp8": mxfp8_value,
        "redaction_manifest_sha256": bundle.manifest_sha256,
    }


# --------------------------------------------------------------------------- release

def git(root: Path, *args: str) -> bytes:
    completed = subprocess.run(["git", *args], cwd=root, capture_output=True, check=False)
    if completed.returncode != 0:
        fail(f"git {' '.join(args[:2])} failed: {completed.stderr.decode(errors='replace').strip()}")
    return completed.stdout


def review_subject(root: Path, base: str, head: str, exclusions: set[str]) -> tuple[list[str], str, str]:
    paths = [line for line in git(root, "diff", "--name-only", "--no-renames", "-z", base, head).decode().split("\0") if line]
    paths = sorted({path for path in paths if path not in exclusions}, key=lambda p: p.encode())
    if not paths:
        fail("review subject is empty")
    paths_digest = sha256("".join(f"{path}\n" for path in paths).encode())
    diff = git(root, "-c", "core.quotepath=off", "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", base, head, "--", *paths)
    return paths, paths_digest, sha256(diff)


def compose_release(root: Path, bundle: Bundle, *, captured_at: str, expires_at: str | None = None, release_id: str,
                    base_commit: str, head_commit: str, target_commit: str, build_sha256: str) -> dict[str, Any]:
    captured = parse_timestamp(captured_at, "captured_at")
    expires = parse_timestamp(expires_at, "expires_at") if expires_at else captured + timedelta(days=EXPIRY_DAYS[RELEASE])
    for label, value in (("base_commit", base_commit), ("head_commit", head_commit), ("target_commit", target_commit)):
        if not OBJECT_ID_RE.fullmatch(value):
            fail(f"{label} must be a full lowercase object id")
    if not SHA256_RE.fullmatch(build_sha256):
        fail("build_sha256 must be lowercase 64-hex")
    digests = {}
    for step_id in RELEASE_STEPS:
        _, digests[step_id] = step_artifact(bundle, step_id)
    # The review subject excludes only what is generated after the reviews:
    # this release manifest, its signature, and its bundle (which holds the
    # three verdicts, the post-cut step artifacts, and the ref attestation).
    exclusions = {f"{bundle.relative_dir}{EVIDENCE_SUFFIX}", f"{bundle.relative_dir}{EVIDENCE_SUFFIX}.sig"}
    exclusions |= {f"{bundle.relative_dir}/{relative}" for relative in bundle.files} | {f"{bundle.relative_dir}/{MANIFEST_NAME}"}
    _, paths_digest, diff_digest = review_subject(root, base_commit, head_commit, exclusions)
    head_tree = git(root, "rev-parse", f"{head_commit}^{{tree}}").decode().strip()
    attestation = bundle.require("target-ref-attestation.json")
    attestation_obj = parse_json(attestation, "target-ref-attestation.json")
    if not isinstance(attestation_obj, dict) or attestation_obj.get("ref") != "refs/heads/main" or (attestation_obj.get("object") or {}).get("sha") != target_commit:
        fail("target-ref-attestation.json must be the hosting API answer for refs/heads/main at target_commit")
    reviews = {}
    for lane in REVIEW_LANES:
        relative = f"reviews/{lane}.json"
        data = bundle.require(relative)
        review = exact_keys(parse_json(data, relative), REVIEW_KEYS, relative)
        expected = {
            "schema_version": REVIEW_SCHEMA, "lane": lane, "production_repository": REPOSITORY,
            "production_ref": "refs/heads/main", "target_commit": target_commit,
            "target_ref_attestation_sha256": sha256(attestation), "base_commit": base_commit,
            "head_commit": head_commit, "head_tree_oid": head_tree, "diff_sha256": diff_digest,
            "reviewed_paths_sha256": paths_digest, "verdict": "approved", "critical": 0, "high": 0, "medium": 0,
        }
        for key, value in expected.items():
            if review[key] != value:
                fail(f"{relative}: {key} must be {value!r}")
        for key in ("low", "info"):
            if not isinstance(review[key], int) or isinstance(review[key], bool) or review[key] < 0:
                fail(f"{relative}: {key} must be an unsigned integer")
        reviews[lane] = sha256(data)
    sidecar = bundle.require("native-mtp-admission.json")
    serving = bundle.require("serving-journey-result.signed.json")
    entry_index = parse_json(bundle.require("steps/step-03-final-binary-binding.json"), "step-03")["details"].get("entry_index")
    return {
        "schema_version": EVIDENCE_SCHEMAS[RELEASE],
        "journey_id": JOURNEY_IDS[RELEASE],
        "requirement_ids": list(RELEASE_REQUIREMENTS),
        "native_mtp_admission_tuple_sha256": admission_tuple_sha256(sidecar, entry_index),
        "release_id": release_id,
        "base_commit": base_commit,
        "head_commit": head_commit,
        "head_tree_oid": head_tree,
        "production_repository": REPOSITORY,
        "production_ref": "refs/heads/main",
        "target_commit": target_commit,
        "target_ref_attestation_sha256": sha256(attestation),
        "diff_sha256": diff_digest,
        "reviewed_paths_sha256": paths_digest,
        "dirty": False,
        "source_commit": head_commit,
        "build_sha256": build_sha256,
        "serving_journey_result_sha256": sha256(serving),
        "sidecar_sha256": sha256(sidecar),
        "code_review_sha256": reviews["code"],
        "security_review_sha256": reviews["security"],
        "architecture_review_sha256": reviews["architecture"],
        "steps": [{"step_id": step_id, "status": "pass", "artifact_sha256": digests[step_id]} for step_id in RELEASE_STEPS],
        "captured_at": rfc3339(captured),
        "expires_at": rfc3339(expires),
        "redaction_manifest_sha256": bundle.manifest_sha256,
    }


def validate_release_git(root: Path, evidence: dict) -> None:
    base, head, target = evidence["base_commit"], evidence["head_commit"], evidence["target_commit"]
    if base != target:
        fail("base_commit must equal target_commit")
    if git(root, "merge-base", target, head).decode().strip() != base or base == head:
        fail("base_commit must be the merge base of target and head and a strict ancestor of head")
    if evidence["source_commit"] != head or evidence["dirty"] is not False:
        fail("source_commit must equal head_commit and dirty must be false")


# --------------------------------------------------------------------------- shared

def validate_evidence(root: Path, kind: str, source: str, evidence: object, *, now: datetime | None = None) -> Bundle:
    keys = SERVING_KEYS if kind == SERVING else RELEASE_KEYS
    evidence = exact_keys(evidence, keys, "evidence")
    bundle = load_bundle(root, bundle_dir_for_source(kind, source))
    captured = parse_timestamp(evidence["captured_at"], "captured_at")
    expires = parse_timestamp(evidence["expires_at"], "expires_at")
    if not captured < expires <= captured + timedelta(days=EXPIRY_DAYS[kind]):
        fail(f"expires_at must be after captured_at and at most {EXPIRY_DAYS[kind]} days later")
    # expires_at is structural only (#1938, SPEC-048 0.1.28): unchanged
    # evidence stays usable after it; a decode-path change requires a new run.
    del now
    compact = bundle.relative_dir.rsplit("-", 1)[-1]
    if compact != captured.strftime("%Y%m%dT%H%M%SZ"):
        fail("bundle name must be its captured_at")
    if kind == SERVING:
        expected = compose_serving(bundle, captured_at=evidence["captured_at"], expires_at=evidence["expires_at"])
    else:
        validate_release_git(root, evidence)
        expected = compose_release(
            root, bundle, captured_at=evidence["captured_at"], expires_at=evidence["expires_at"],
            release_id=evidence["release_id"], base_commit=evidence["base_commit"],
            head_commit=evidence["head_commit"], target_commit=evidence["target_commit"],
            build_sha256=evidence["build_sha256"],
        )
    if evidence != expected:
        differing = sorted(key for key in keys if evidence.get(key) != expected.get(key))
        fail(f"evidence must equal the bundle recomputation (differs: {differing})")
    return bundle


def signed_expiry_date(expires_at: str) -> str:
    expires = parse_timestamp(expires_at, "expires_at")
    return ((expires + timedelta(seconds=1)).date() - timedelta(days=1)).isoformat()


def project_payload(kind: str, evidence: dict, source: str, evidence_sha256: str, bundle: Bundle, *, source_sha: str, evidence_sha: str) -> dict[str, Any]:
    if kind == SERVING and serving_source_commit(bundle) != source_sha:
        fail("--source-sha must equal the selected sidecar entry source_commit")
    if kind == RELEASE and evidence["source_commit"] != source_sha:
        fail("--source-sha must equal the release evidence source_commit")
    steps = [item["step_id"] for item in evidence["steps"]]
    return {
        "schema_version": PAYLOAD_SCHEMA,
        "journey_id": JOURNEY_IDS[kind],
        "requirement_ids": list(evidence["requirement_ids"]),
        "repository": {"name": REPOSITORY, "commit": source_sha},
        "evidence_repository": {"name": REPOSITORY, "commit": evidence_sha},
        "captured_at": evidence["captured_at"],
        "expires_at": signed_expiry_date(evidence["expires_at"]),
        "operator": {
            "role": "native-mtp-campaign-operator",
            "identity_fingerprint": sha256(f"macprovider.native-mtp.operator.v1\n{bundle.manifest_sha256}".encode()),
        },
        "environment": {
            "class": f"provider-native-mtp-{kind}",
            "hardware_profile": "apple-silicon-mac-studio-m3-ultra-256gb",
            "candidate": f"native-mtp-tuple:{evidence['native_mtp_admission_tuple_sha256']}",
        },
        "artifacts": [
            {"id": f"native-mtp-{kind}-evidence", "sha256": evidence_sha256, "source": source},
            {"id": f"native-mtp-{kind}-redaction-manifest", "sha256": bundle.manifest_sha256, "source": f"{bundle.relative_dir}/{MANIFEST_NAME}"},
        ],
        "result": {"status": "pass", "summary": f"every {JOURNEY_IDS[kind]} step passed for the bound native-MTP tuple"},
        "steps": [
            {"id": step, "status": "pass", "artifacts": [f"native-mtp-{kind}-evidence", f"native-mtp-{kind}-redaction-manifest"]}
            for step in steps
        ],
        "redaction": {"secrets_redacted": True, "operator_identity_redacted": True, "local_account_names_redacted": True},
        "run_id": Path(source).name[: -len(EVIDENCE_SUFFIX)],
        "execution_mode": f"provider-native-mtp-{kind}",
        "observations": dict(evidence.get("observations") or {}),
    }


def kind_for_journey(journey_id: str) -> str:
    for kind, value in JOURNEY_IDS.items():
        if value == journey_id:
            return kind
    fail(f"not a native-MTP journey: {journey_id}")
    raise AssertionError


def git_file_bytes(root: Path, commit: str, relative: str) -> bytes | None:
    completed = subprocess.run(["git", "show", f"{commit}:{relative}"], cwd=root, capture_output=True, check=False)
    return completed.stdout if completed.returncode == 0 else None


def serving_source_commit(bundle: Bundle) -> str:
    step, _ = step_artifact(bundle, "step-01-bind-tuple")
    entry_index = step["details"].get("entry_index")
    entry, _ = validated_sidecar_entry(bundle.require("native-mtp-admission.json"), entry_index)
    source_commit = entry["source_commit"]
    if entry["provider_revision"] != source_commit or entry["ordinary_baseline"]["provider_revision"] != source_commit:
        fail("selected sidecar entry provider_revision must equal source_commit")
    return source_commit


def build_payload(root: Path, kind: str, source: str, *, source_sha: str, evidence_sha: str, now: datetime | None = None) -> dict[str, Any]:
    for label, value in (("--source-sha", source_sha), ("--evidence-sha", evidence_sha)):
        if not OBJECT_ID_RE.fullmatch(value):
            fail(f"{label} must be a full lowercase commit id")
    if subprocess.run(["git", "merge-base", "--is-ancestor", source_sha, evidence_sha], cwd=root, check=False).returncode != 0:
        fail("--source-sha must be an ancestor of --evidence-sha")
    data = (root / source).read_bytes()
    evidence = parse_json(data, source)
    bundle = validate_evidence(root, kind, source, evidence, now=now)
    if git_file_bytes(root, evidence_sha, source) != data:
        fail("committed evidence bytes must match --evidence-sha")
    for relative, content in [(MANIFEST_NAME, bundle.manifest), *bundle.files.items()]:
        if git_file_bytes(root, evidence_sha, f"{bundle.relative_dir}/{relative}") != content:
            fail(f"bundle file must match --evidence-sha: {relative}")
    return project_payload(kind, evidence, source, sha256(data), bundle, source_sha=source_sha, evidence_sha=evidence_sha)


def validate_signed_payload(root: Path, signed: dict[str, Any], requirement_id: str, journeys: list[str]) -> list[str]:
    """Governance: reopen the committed evidence and require the signed payload
    to equal the builder projection, so a hand-authored payload cannot overclaim."""
    errors: list[str] = []
    try:
        kind = kind_for_journey(str(signed.get("journey_id")))
    except NativeMTPEvidenceError as exc:
        return [str(exc)]
    if JOURNEY_IDS[kind] not in journeys:
        errors.append(f"requirement journeys must include {JOURNEY_IDS[kind]!r}")
    artifacts = signed.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 2 or not isinstance(artifacts[0], dict):
        return errors + ["signed.artifacts must be exactly the evidence and its bundle manifest"]
    source = artifacts[0].get("source")
    repository, evidence_repository = signed.get("repository") or {}, signed.get("evidence_repository") or {}
    try:
        data = (root / str(source)).read_bytes()
        evidence = parse_json(data, str(source))
        bundle = validate_evidence(root, kind, str(source), evidence)
        expected = project_payload(
            kind, evidence, str(source), sha256(data), bundle,
            source_sha=str(repository.get("commit")), evidence_sha=str(evidence_repository.get("commit")),
        )
    except (NativeMTPEvidenceError, OSError) as exc:
        return errors + [f"signed.artifacts[0].source: {exc}"]
    if requirement_id not in expected["requirement_ids"]:
        errors.append(f"{JOURNEY_IDS[kind]} result cannot promote {requirement_id}")
    if signed != expected:
        differing = sorted(key for key in set(signed) | set(expected) if signed.get(key) != expected.get(key))
        errors.append(f"signed payload must equal the builder projection of its evidence (differs: {differing})")
    return errors
