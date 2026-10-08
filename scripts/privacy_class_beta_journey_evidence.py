#!/usr/bin/env python3
"""Closed evidence contract for JOURNEY-PRIVACY-CLASS-BETA (SPEC-049).

The journey contract (`journeys/JOURNEY-PRIVACY-CLASS-BETA.md`) fixes the exact
closed `macprovider.privacy-class-beta-evidence.v1` object. This module owns
that contract for three consumers: `build-privacy-class-beta-journey-result.py`
(which composes the evidence from a reviewed bundle and projects the unsigned
journey-result payload) and `check_spec_governance.py` (which re-runs the same
checks over a signed payload's source, so a hand-authored payload carrying a
valid acceptance signature still cannot claim anything its bundle does not
show).

The reviewed bundle is the directory next to the evidence object:

    journeys/evidence/privacy-class-beta-<captured_at compact>.redacted.json
    journeys/evidence/privacy-class-beta-<captured_at compact>/MANIFEST.sha256
    journeys/evidence/privacy-class-beta-<captured_at compact>/<kit step dir>/...

`MANIFEST.sha256` lists every other bundle file exactly once with its SHA-256,
so `redaction_manifest_sha256` binds the whole reviewed bundle. Every step
`artifact_sha256` must be the digest of that step's designated bundle file, and
every observation boolean is recomputed here from the bundle files; the
evidence object's own booleans are compared against the recomputation and are
never trusted.

Nothing in this module signs or promotes anything.
"""

from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from check_spec_governance import (
    DuplicateJSONKeyError,
    JOURNEY_RESULT_PAYLOAD_SCHEMA,
    _unique_json_object,
    verify_pinned_public_ecdsa_sha256,
)


JOURNEY_ID = "JOURNEY-PRIVACY-CLASS-BETA"
JOURNEY_PATH = "journeys/JOURNEY-PRIVACY-CLASS-BETA.md"
JOURNEY_ID_V2 = "JOURNEY-PRIVACY-CLASS-BETA-V2"
JOURNEY_PATH_V2 = "journeys/JOURNEY-PRIVACY-CLASS-BETA-V2.md"
EVIDENCE_SCHEMA = "macprovider.privacy-class-beta-evidence.v1"
EVIDENCE_SCHEMA_V2 = "macprovider.privacy-class-beta-evidence.v2"
EXECUTION_MODE = "provider-privacy-class-beta"
EVIDENCE_PREFIX = "journeys/evidence/privacy-class-beta-"
EVIDENCE_SUFFIX = ".redacted.json"
ARTIFACT_ID = "redacted-privacy-class-beta"
MANIFEST_ARTIFACT_ID = "privacy-class-beta-redaction-manifest"
MANIFEST_NAME = "MANIFEST.sha256"
REPOSITORY = "Augustas11/macprovider"
MAX_EVIDENCE_LIFETIME = timedelta(days=90)

# Journey "Completion": the signed result names every requirement mapped to the
# journey except these four. SPEC-049-R023 also needs a staged canary and
# three-lane audits; the other three also cover plain relay-blind work.
EXCLUDED_REQUIREMENT_IDS = frozenset({"SPEC-049-R023", "SPEC-022-R014", "SPEC-015-R007", "SPEC-001-R005"})

EVIDENCE_KEYS = (
    "schema_version",
    "journey_id",
    "requirement_ids",
    "captured_at",
    "expires_at",
    "release_tag",
    "binary_sha256",
    "code_cdhash",
    "team_id",
    "signing_identifier",
    "steps",
    "observations",
    "redaction_manifest_sha256",
)

STEP_ID_ORDER = (
    "step-01-bind-signed-release",
    "step-02-privacy-mode-start",
    "step-03-debugger-attach-refused",
    "step-04-core-dump-and-env-refused",
    "step-05-unsigned-build-refused",
    "step-06-sip-off-refused",
    "step-07-canary-stream",
    "step-08-canary-nonstream",
    "step-09-redaction-sweep",
    "step-10-downgrade-negatives",
    "step-11-stale-posture-and-quarantine",
    "step-12-kill-switch",
    "step-13-enforce-canary",
    "step-14-no-capability-provider-excluded",
    "step-15-tampered-receipt-quarantined",
    "step-16-redaction-review",
)

STEP_ID_ORDER_V2 = (
    *STEP_ID_ORDER,
    "step-17-auto-mode-eligibility",
    "step-18-auto-enrollment-distinct-identities",
    "step-19-key-change-quarantine-reenroll",
    "step-20-release-derived-approval",
    "step-21-operator-signed-directory",
)

# The run kit records each contract step in a directory of the same name. Its
# extra preflight directories hold inputs of a contract step: 00b/00c/01b are
# the signed-candidate verification, install, and isolated-stack binding that
# step-01 records; 00a/99 are the live-provider identity before and after the
# run (the isolation half of `unreleased_local_binary_connected_to_live_coordinator`).
KIT_STEP_IDS = (
    "step-00a-isolation-preflight",
    "step-00b-verify-candidate",
    "step-00c-install-cli",
    "step-01-bind-signed-release",
    "step-01b-isolated-stack",
    *STEP_ID_ORDER[1:15],
    "step-99-live-provider-untouched",
    "step-16-redaction-review",
)

KIT_STEP_IDS_V2 = (
    *KIT_STEP_IDS[:-1],
    "step-17-auto-mode-eligibility",
    "step-18-auto-enrollment-distinct-identities",
    "step-19-key-change-quarantine-reenroll",
    "step-20-release-derived-approval",
    "step-21-operator-signed-directory",
    KIT_STEP_IDS[-1],
)

# The one bundle file each step's `artifact_sha256` names.
STEP_PRIMARY_ARTIFACTS = {
    "step-01-bind-signed-release": "step-01-bind-signed-release/binding.txt",
    "step-02-privacy-mode-start": "step-02-privacy-mode-start/probe-disclosure.json",
    "step-03-debugger-attach-refused": "step-03-debugger-attach-refused/summary.txt",
    "step-04-core-dump-and-env-refused": "step-04-core-dump-and-env-refused/rlimit-core.txt",
    "step-05-unsigned-build-refused": "step-05-unsigned-build-refused/resigned-adhoc/result.txt",
    "step-06-sip-off-refused": "step-06-sip-off-refused/result.txt",
    "step-07-canary-stream": "step-07-canary-stream/disclosure.json",
    "step-08-canary-nonstream": "step-08-canary-nonstream/disclosure.json",
    "step-09-redaction-sweep": "step-09-redaction-sweep/receipts.json",
    "step-10-downgrade-negatives": "step-10-downgrade-negatives/no-failover.json",
    "step-11-stale-posture-and-quarantine": "step-11-stale-posture-and-quarantine/status-after-restart.txt",
    "step-12-kill-switch": "step-12-kill-switch/held-reservation.txt",
    "step-13-enforce-canary": "step-13-enforce-canary/enforce.json",
    "step-14-no-capability-provider-excluded": "step-14-no-capability-provider-excluded/excluded.json",
    "step-15-tampered-receipt-quarantined": "step-15-tampered-receipt-quarantined/quarantined.json",
    "step-16-redaction-review": "step-16-redaction-review/evidence-sweep.json",
    "step-17-auto-mode-eligibility": "primary/v2/auto-mode.json",
    "step-18-auto-enrollment-distinct-identities": "primary/v2/enrollment.json",
    "step-19-key-change-quarantine-reenroll": "primary/v2/reenroll.json",
    "step-20-release-derived-approval": "primary/v2/release-derived-approval.json",
    "step-21-operator-signed-directory": "primary/v2/directory.json",
}

STEP_ASSERTIONS = {
    "step-01-bind-signed-release": "signed notarized hardened-runtime release bound by cdhash, team, and identifier to signed release metadata and the isolated stack",
    "step-02-privacy-mode-start": "privacy mode started, privacy key records accepted and memory-only, posture verified by the coordinator",
    "step-03-debugger-attach-refused": "user and root lldb and root dtrace attach refused while the provider stayed eligible",
    "step-04-core-dump-and-env-refused": "core dumps off, diagnostic env, KV disk tier, loopback runtime, and relay-blind off refused before network, DYLD_* inert",
    "step-05-unsigned-build-refused": "re-signed, unsigned, and local debug builds exit non-zero before network",
    "step-06-sip-off-refused": "SIP-disabled lab Mac exits sip_disabled before network with zero connections",
    "step-07-canary-stream": "stream canary decrypted and verified with exact disclosure and headers",
    "step-08-canary-nonstream": "non-stream canary decrypted and verified with exact disclosure and headers",
    "step-09-redaction-sweep": "zero canary, canary-hash, and buyer-key matches; one content-free relay-blind settlement receipt per privacy attempt",
    "step-10-downgrade-negatives": "downgrade, replay, and wrong-key attempts rejected with zero dispatch; tamper and truncation say do not resubmit",
    "step-11-stale-posture-and-quarantine": "stale posture ineligible without quarantine; unapproved cdhash quarantine and key revocation survive restart",
    "step-12-kill-switch": "kill switch rejects held and next privacy requests; relay-blind and plaintext unaffected; re-enable recovers",
    "step-13-enforce-canary": "enforce snapshot before dispatch, closed relay_blind_settled verdict, payable credit, debit equals credit, verified counters unchanged",
    "step-14-no-capability-provider-excluded": "provider without relay_blind_settlement_receipt_v1 never reserved; typed unavailable before quota",
    "step-15-tampered-receipt-quarantined": "withheld, tampered, and v0.4 receipts closed quarantined with zero payable credit and buyer refund",
    "step-16-redaction-review": "redacted bundle reviewed; automated secret sweep clean; no private path remains",
    "step-17-auto-mode-eligibility": "automatic mode enters privacy only on an eligible signed host, falls back safely, and honors explicit opt-out",
    "step-18-auto-enrollment-distinct-identities": "first verified posture enrolls one provider identity and rejects cross-provider key reuse",
    "step-19-key-change-quarantine-reenroll": "key changes quarantine without replacing enrollment; operator reenroll revokes old state and admits new keys",
    "step-20-release-derived-approval": "signed release metadata approves the tested code identity and withdrawal or denial removes eligibility",
    "step-21-operator-signed-directory": "operator-signed identity directory verifies signatures, expiry, revocation, and v0.2 residual disclosures",
}

TRUE_OBSERVATIONS = (
    "hardening_applied_before_network_verified",
    "privacy_key_memory_only_verified",
    "posture_verified_by_coordinator",
    "debugger_attach_refused_verified",
    "core_dumps_disabled_verified",
    "diagnostic_env_refused_verified",
    "dyld_env_inert_verified",
    "unsigned_or_resigned_build_refused_verified",
    "sip_off_host_refused_verified",
    "stream_frames_decrypted_and_verified",
    "nonstream_frames_decrypted_and_verified",
    "disclosure_strings_exact_verified",
    "canary_absent_from_all_artifacts_verified",
    "downgrade_attempts_rejected_verified",
    "tampered_or_truncated_response_rejected_verified",
    "stale_posture_ineligible_verified",
    "quarantine_durable_across_restart_verified",
    "kill_switch_blocks_all_phases_verified",
    "relay_blind_and_plaintext_unaffected_verified",
    "exactly_one_content_free_settlement_receipt_verified",
    "enforce_snapshot_before_dispatch_verified",
    "relay_blind_settled_verdict_closed_verified",
    "relay_blind_credit_payable_verified",
    "buyer_debit_equals_provider_credit_usage_verified",
    "verified_count_delta_zero_verified",
    "no_capability_provider_excluded_verified",
    "tampered_or_missing_receipt_quarantined_and_refunded_verified",
)
FALSE_OBSERVATIONS = (
    "plaintext_observed_at_relay",
    "failover_or_alternate_provider_observed",
    "silent_downgrade_observed",
    "plaintext_derived_receipt_or_telemetry_emitted_for_privacy_request",
    "relay_blind_request_reported_as_verified",
    "privacy_key_written_to_disk",
    "unreleased_local_binary_connected_to_live_coordinator",
    "secret_or_canary_persisted",
)

TRUE_OBSERVATIONS_V2_EXTENSION = (
    "auto_mode_eligible_host_enters_privacy_verified",
    "auto_mode_ineligible_host_falls_back_without_privacy_records_verified",
    "explicit_optout_disables_privacy_class_verified",
    "auto_enrollment_binds_distinct_provider_identities_verified",
    "cross_provider_key_reuse_refused_verified",
    "enrollment_key_change_quarantines_and_revokes_records_verified",
    "operator_reenroll_revokes_old_enrollment_and_admits_new_keys_verified",
    "release_metadata_approves_tested_code_identity_verified",
    "release_identity_withdrawal_or_denial_removes_eligibility_verified",
    "identity_directory_signature_expiry_and_revocation_verified",
    "expanded_v2_residual_disclosures_exact_verified",
)
FALSE_OBSERVATIONS_V2_EXTENSION = (
    "automatic_mode_advertised_privacy_records_when_ineligible",
    "enrollment_replaced_by_key_change_without_operator_reenroll",
    "denied_release_identity_remained_eligible",
    "unsigned_expired_or_revoked_directory_accepted",
    "v2_residual_disclosure_omitted",
)


@dataclass(frozen=True)
class EvidenceProfile:
    schema: str
    journey_id: str
    journey_path: str
    step_ids: tuple[str, ...]
    kit_step_ids: tuple[str, ...]
    true_observations: tuple[str, ...]
    false_observations: tuple[str, ...]
    excluded_requirement_ids: frozenset[str]
    artifact_id: str
    manifest_artifact_id: str
    operator_fingerprint_domain: str
    summary: str


PROFILE_V1 = EvidenceProfile(
    schema=EVIDENCE_SCHEMA,
    journey_id=JOURNEY_ID,
    journey_path=JOURNEY_PATH,
    step_ids=STEP_ID_ORDER,
    kit_step_ids=KIT_STEP_IDS,
    true_observations=TRUE_OBSERVATIONS,
    false_observations=FALSE_OBSERVATIONS,
    excluded_requirement_ids=EXCLUDED_REQUIREMENT_IDS,
    artifact_id=ARTIFACT_ID,
    manifest_artifact_id=MANIFEST_ARTIFACT_ID,
    operator_fingerprint_domain="macprovider.privacy-class-beta.operator.v1",
    summary="signed notarized release passed every JOURNEY-PRIVACY-CLASS-BETA step on Apple Silicon",
)
PROFILE_V2 = EvidenceProfile(
    schema=EVIDENCE_SCHEMA_V2,
    journey_id=JOURNEY_ID_V2,
    journey_path=JOURNEY_PATH_V2,
    step_ids=STEP_ID_ORDER_V2,
    kit_step_ids=KIT_STEP_IDS_V2,
    true_observations=(*TRUE_OBSERVATIONS, *TRUE_OBSERVATIONS_V2_EXTENSION),
    false_observations=(*FALSE_OBSERVATIONS, *FALSE_OBSERVATIONS_V2_EXTENSION),
    excluded_requirement_ids=frozenset({"SPEC-049-R023"}),
    artifact_id="redacted-privacy-class-beta-v2",
    manifest_artifact_id="privacy-class-beta-v2-redaction-manifest",
    operator_fingerprint_domain="macprovider.privacy-class-beta.operator.v2",
    summary="signed notarized v0.2 release passed the full privacy-class beta v2 journey on Apple Silicon",
)
PROFILES_BY_SCHEMA = {profile.schema: profile for profile in (PROFILE_V1, PROFILE_V2)}
PROFILES_BY_JOURNEY = {profile.journey_id: profile for profile in (PROFILE_V1, PROFILE_V2)}

# SPEC-049-R020 exact strings.
PRIVACY_CLASS = "operator_constrained_beta_v1"
PRIVACY_ASSURANCE = "device_bound_self_attested_beta"
PRIVACY_SCOPE = (
    "request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; "
    "ordinary_operator_access_paths_constrained_on_approved_signed_runtime; "
    "posture_self_attested_device_bound_not_code_bound"
)
PRIVACY_RESIDUAL_RISKS = (
    "modified_binary_can_forge_posture_se_key_device_bound_not_code_bound",
    "root_sip_bypass_kernel_or_firmware_compromise",
    "physical_or_hardware_attack",
    "gpu_and_unified_memory_residue",
    "encrypted_swap_and_hibernation_images",
    "compromise_of_the_live_runtime_process",
    "malicious_signed_release_or_supply_chain",
    "crash_report_register_and_stack_residue",
    "secure_boot_level_not_evaluated",
    "immutable_prompt_strings_not_zeroized",
    "relays_observe_sizes_timing_and_token_counts",
)
PRIVACY_RESIDUAL_RISKS_V2 = (
    *PRIVACY_RESIDUAL_RISKS,
    "provider_identity_enrolled_on_first_attested_session",
    "coordinator_operator_signs_provider_identity_directory",
)
SETTLEMENT_DISCLOSURE = (
    "verified_model_settlement: unavailable_for_relay_blind_request\n"
    "usage_settlement: standard_usage_settlement_and_clear_cap_enforcement_still_apply\n"
)
RB_PROFILE = "relay-blind-settlement-v1"
RB_ENTRYPOINT = "coordinator_buyer_v1_relay_blind_chat_completions"
RB_BASIS = "relay_blind_envelope_digest_v1"
RB_SETTLED = "relay_blind_settled"
REFUSED_ENTITLEMENTS = (
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-dyld-environment-variables",
)
DIAGNOSTIC_ENV_VARS = (
    "MACPROVIDER_CB_TRACE",
    "MACPROVIDER_PERF_TRACE",
    "MACPROVIDER_KEEPALIVE_DEBUG",
    "MACPROVIDER_ALLOW_TEST_FIXTURES",
)
CANARY_NEEDLE_CLASSES = frozenset(
    ["buyer_ephemeral_key"]
    + [
        f"{name}{suffix}"
        for name in ("canary_prompt", "completion_canary", "prompt_canary")
        for suffix in ("", "_sha256_b64", "_sha256_b64url", "_sha256_hex", "_sha256_hex_upper")
        if not (name == "canary_prompt" and suffix == "")
    ]
)
REVIEW_NEEDLE_CLASSES = CANARY_NEEDLE_CLASSES | {
    "buyer_api_key",
    "journey_secret_demo_secret",
    "journey_secret_gateway_service_token",
    "journey_secret_key_hash_secret",
    "journey_secret_operator_key",
    "provider_token",
}
QUARANTINE_CASES = {
    "ws-corrupted-end-frame-privacy": "missing_receipt_deadline_elapsed",
    "fault-tamper-field": "signature_verify_failed",
    "fault-v04": "v04_receipt_on_relay_blind_snapshot",
    "fault-v04-member": "missing_receipt_deadline_elapsed",
}

REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CDHASH_RE = re.compile(r"^[0-9a-f]{40}$")
TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
SIGNING_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$")
RELEASE_TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
COMPACT_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
MANIFEST_LINE_RE = re.compile(r"^([0-9a-f]{64})  \./([A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*)$")
SAFE_COMPONENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MAX_BUNDLE_FILE_BYTES = 8 << 20
MAX_BUNDLE_FILES = 1024

# Fail-closed scan of every reviewed bundle file. The review replaced the lab
# home with `<lab-home>`; any home path, key block, credential shape, email,
# non-loopback IPv4 literal, or non-loopback URL host left behind fails.
BUNDLE_FORBIDDEN_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("a home path", re.compile(r"(?<![A-Za-z0-9_.>-])/(?:Users|home)/")),
    ("a JSON-escaped home path", re.compile(r"\\/(?:Users|home)\\/")),
    ("a home-relative path", re.compile(r"(?:^|[\s\"'=,;(\[])~/")),
    ("a per-user temporary path", re.compile(r"(?:/private)?/var/folders/")),
    ("a private key block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("a bearer credential", re.compile(r"(?i)\bbearer\s+(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}")),
    ("an API key", re.compile(r"\bmp_[A-Za-z0-9_-]{16,}\b")),
    ("an API key", re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")),
    ("a GitHub token", re.compile(r"\b(?:ghp|gho|ghs|ghu)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b")),
    ("an AWS key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("an email address", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")),
)
# Every DNS-shaped token is treated as a hostname unless it is a file name with
# a known extension, an Apple reverse-DNS subsystem id, or one of the fixed
# non-host identifiers the run records. Unknown suffixes fail closed.
DNS_TOKEN_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])((?:[A-Za-z0-9](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9])?\.)+([A-Za-z]{1,63}))(?![A-Za-z0-9_-])"
)
VERSION_TOKEN_RE = re.compile(r"^[vV]?[0-9]+(?:\.[0-9]+)+$")
# tcp_input flag sets in Apple network logs, such as S.E or P.E.
TCP_FLAGS_TOKEN_RE = re.compile(r"^[A-Z](?:\.[A-Z])+$")
NON_HOST_SUFFIXES = frozenset({
    "txt", "json", "jsonl", "tsv", "db", "log", "meta", "stderr", "stdout", "status", "sig", "err", "yaml", "yml",
    "gz", "dmg", "ips", "xml", "plist", "dylib", "sh", "py", "md", "pem", "metallib", "bundle", "patch", "tar",
})
NON_HOST_TOKENS = frozenset({
    "live.malibu.provider.cli", "hw.model", "machdep.cpu", "quarantine.reason", "encryption.current", "bytes.fromhex",
})
IPV6_CANDIDATE_RE = re.compile(r"(?<![0-9A-Za-z:])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![0-9A-Za-z:])")
IPV4_RE = re.compile(r"(?<![0-9A-Za-z.])([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(?![0-9.])")
URL_HOST_RE = re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://([^/:\s\"'<>]+)")
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost"})


class PrivacyEvidenceError(Exception):
    """Raised when evidence or its bundle fails the closed contract."""


def fail(message: str) -> None:
    raise PrivacyEvidenceError(message)


# ---------------------------------------------------------------- bundle


class Bundle:
    """A reviewed bundle whose every file is bound by MANIFEST.sha256."""

    def __init__(self, relative_dir: str, files: dict[str, bytes], manifest_bytes: bytes) -> None:
        self.relative_dir = relative_dir
        self.files = files
        self.manifest_bytes = manifest_bytes
        self.manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()

    @property
    def manifest_source(self) -> str:
        return f"{self.relative_dir}/{MANIFEST_NAME}"

    def raw(self, path: str) -> bytes:
        if path not in self.files:
            fail(f"bundle file is missing: {path}")
        return self.files[path]

    def text(self, path: str) -> str:
        try:
            return self.raw(path).decode("utf-8")
        except UnicodeDecodeError:
            fail(f"bundle file is not UTF-8: {path}")
            raise AssertionError("unreachable")

    def sha256(self, path: str) -> str:
        return hashlib.sha256(self.raw(path)).hexdigest()

    def json(self, path: str) -> Any:
        return parse_json(self.text(path), path)

    def json_object(self, path: str) -> dict[str, Any]:
        value = self.json(path)
        if not isinstance(value, dict):
            fail(f"{path} must hold a JSON object")
        return value

    def lines(self, path: str) -> list[str]:
        return [line for line in self.text(path).splitlines() if line.strip()]

    def fields(self, path: str) -> dict[str, str]:
        """`key=value` tokens of a kit record file; later keys must not repeat."""
        return parse_fields(self.text(path), path)


def parse_json(text: str, label: str) -> Any:
    try:
        return json.loads(text, object_pairs_hook=_unique_json_object)
    except DuplicateJSONKeyError as exc:
        fail(f"{label}: duplicate JSON object key {exc.args[0]!r}")
    except json.JSONDecodeError as exc:
        fail(f"{label}: invalid JSON: {exc}")
    raise AssertionError("unreachable")


def parse_fields(text: str, label: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in text.splitlines():
        for token in line.split():
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            if key in fields:
                fail(f"{label}: repeated field {key!r}")
            fields[key] = value
    return fields


def bundle_dir_for_source(source: str) -> str:
    if not source.startswith(EVIDENCE_PREFIX) or not source.endswith(EVIDENCE_SUFFIX):
        fail(f"evidence source must match {EVIDENCE_PREFIX}*{EVIDENCE_SUFFIX}")
    compact = source[len(EVIDENCE_PREFIX) : -len(EVIDENCE_SUFFIX)]
    if not COMPACT_RE.fullmatch(compact):
        fail("evidence source must be named privacy-class-beta-<captured_at as YYYYMMDDTHHMMSSZ>.redacted.json")
    return source[: -len(EVIDENCE_SUFFIX)]


def require_no_symlink_components(root: Path, relative: str) -> Path:
    candidate = root
    for component in Path(relative).parts:
        candidate = candidate / component
        if candidate.is_symlink():
            fail(f"repository path must not traverse a symlink: {relative}")
    return candidate


def load_bundle(root: Path, relative_dir: str) -> Bundle:
    if not relative_dir.startswith(EVIDENCE_PREFIX) or Path(relative_dir).is_absolute() or ".." in Path(relative_dir).parts:
        fail(f"reviewed bundle must be a repository-relative {EVIDENCE_PREFIX}* directory")
    directory = require_no_symlink_components(root, relative_dir)
    try:
        directory.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, ValueError):
        fail(f"reviewed bundle must stay inside the repository: {relative_dir}")
    if not directory.is_dir():
        fail(f"reviewed bundle directory is absent: {relative_dir}")
    files: dict[str, bytes] = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink():
            fail(f"reviewed bundle must not contain symlinks: {relative}")
        if path.is_dir():
            continue
        if not path.is_file():
            fail(f"reviewed bundle may hold only regular files: {relative}")
        if not all(SAFE_COMPONENT_RE.fullmatch(part) for part in relative.split("/")):
            fail(f"reviewed bundle path has an unsafe component: {relative}")
        data = path.read_bytes()
        if len(data) > MAX_BUNDLE_FILE_BYTES:
            fail(f"reviewed bundle file is too large: {relative}")
        files[relative] = data
        if len(files) > MAX_BUNDLE_FILES:
            fail("reviewed bundle holds too many files")
    manifest = files.pop(MANIFEST_NAME, None)
    if manifest is None:
        fail(f"reviewed bundle has no {MANIFEST_NAME}")
    listed: dict[str, str] = {}
    previous = b""
    try:
        manifest_text = manifest.decode("utf-8")
    except UnicodeDecodeError:
        fail(f"{MANIFEST_NAME} is not UTF-8")
    if not manifest_text.endswith("\n"):
        fail(f"{MANIFEST_NAME} must end with a newline")
    for number, line in enumerate(manifest_text[:-1].split("\n"), start=1):
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
        missing = sorted(set(files) - set(listed))
        extra = sorted(set(listed) - set(files))
        fail(f"{MANIFEST_NAME} must list exactly the bundle files (unlisted={missing}, absent={extra})")
    for relative, digest in listed.items():
        if hashlib.sha256(files[relative]).hexdigest() != digest:
            fail(f"bundle file does not match {MANIFEST_NAME}: {relative}")
    return Bundle(relative_dir, files, manifest)


def assert_bundle_redacted(bundle: Bundle) -> None:
    public_binary_signatures = {
        "primary/v2/sources/release_signature.sig",
        "primary/v2/sources/release_invalid_signature.sig",
    }
    for path, data in sorted(bundle.files.items()):
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            if path in public_binary_signatures and 1 <= len(data) <= 512:
                # Exact ECDSA signature bytes are public cryptographic evidence,
                # not operator material. Still run the textual secret/path
                # patterns over replacement-decoded bytes; every other reviewed
                # artifact remains strictly UTF-8.
                text = data.decode("utf-8", errors="replace")
            else:
                fail(f"reviewed bundle file {path} is not UTF-8")
        for label, pattern in BUNDLE_FORBIDDEN_PATTERNS:
            if pattern.search(text):
                fail(f"reviewed bundle file {path} contains {label}")
        for match in IPV4_RE.finditer(text):
            octets = [int(item) for item in match.groups()]
            if all(octet <= 255 for octet in octets) and octets[0] != 127 and octets != [0, 0, 0, 0]:
                fail(f"reviewed bundle file {path} contains a non-loopback IPv4 literal")
        for match in DNS_TOKEN_RE.finditer(text):
            token, suffix = match.group(1), match.group(2)
            if suffix.lower() in NON_HOST_SUFFIXES or token in NON_HOST_TOKENS or token == "com.apple" or token.startswith("com.apple."):
                continue
            if VERSION_TOKEN_RE.fullmatch(token) or TCP_FLAGS_TOKEN_RE.fullmatch(token):
                continue
            fail(f"reviewed bundle file {path} contains a hostname-shaped token")
        for match in IPV6_CANDIDATE_RE.finditer(text):
            try:
                address = ipaddress.IPv6Address(match.group(0))
            except ValueError:
                continue
            if not address.is_loopback and not address.is_unspecified:
                fail(f"reviewed bundle file {path} contains a non-loopback IPv6 literal")
        for match in URL_HOST_RE.finditer(text):
            if match.group(1).lower() not in LOOPBACK_HOSTS:
                fail(f"reviewed bundle file {path} contains a non-loopback URL host")


# ---------------------------------------------------------------- checks


def expect(condition: bool, errors: list[str], message: str) -> None:
    if not condition:
        errors.append(message)


def step06_loopback_listener(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    match = re.fullmatch(r"(?:127\.0\.0\.1|\[::1\]):([1-9][0-9]{0,4})", value)
    return match is not None and 1 <= int(match.group(1)) <= 65535 and int(match.group(1)) != 8080


def privacy_disclosure(fingerprint: str, residual_risks: tuple[str, ...] = PRIVACY_RESIDUAL_RISKS) -> str:
    block = (
        f"privacy class satisfied; identity fingerprint={fingerprint}\n"
        f"privacy_class: {PRIVACY_CLASS}\n"
        f"assurance: {PRIVACY_ASSURANCE}\n"
        f"scope: {PRIVACY_SCOPE}\n"
    )
    block += "".join(f"residual_risks: {risk}\n" for risk in residual_risks)
    return block + SETTLEMENT_DISCLOSURE



# ---------------------------------------------------------------- primary helpers

PRIMARY_SCHEMA = "macprovider.privacy-class-beta-primary.v1"
V2_SOURCE_PROFILE = "macprovider.privacy-class-beta-v2-source.v1"
# SHA-256 of ops/pearl-updater/release-signing-public.pem. A coherent metadata,
# signature, and attacker-supplied public key tuple is not release approval.
TRUSTED_RELEASE_SIGNING_PUBLIC_KEY_SHA256 = "fb5b6af6026e74bcf278acbc4f2d2204d9ebf8909d800c420def6b57ec8a06ee"
V2_SOURCE_CONTRACT = {
    "auto-mode.json": {
        "auto_launch": "evidence/v2-raw/auto-mode/launch.json",
        "auto_config": "evidence/v2-raw/auto-mode/config.json",
        "auto_sessions": "evidence/v2-raw/auto-mode/sessions.json",
        "auto_logs": "evidence/v2-raw/auto-mode/logs.json",
        "auto_db_before": "evidence/v2-raw/auto-mode/db-before.json",
        "auto_db_after": "evidence/v2-raw/auto-mode/db-after.json",
    },
    "enrollment.json": {
        "enrollment_before": "evidence/v2-raw/enrollment/before.json",
        "enrollment_after_first": "evidence/v2-raw/enrollment/after-first.json",
        "enrollment_after_second": "evidence/v2-raw/enrollment/after-second.json",
        "enrollment_after_reuse": "evidence/v2-raw/enrollment/after-reuse.json",
        "enrollment_after_failed_posture": "evidence/v2-raw/enrollment/after-failed-posture.json",
        "enrollment_clients": "evidence/v2-raw/enrollment/clients.json",
    },
    "reenroll.json": {
        "reenroll_initial": "evidence/v2-raw/reenroll/initial.json",
        "reenroll_key_change": "evidence/v2-raw/reenroll/key-change.json",
        "reenroll_expiry_retry": "evidence/v2-raw/reenroll/expiry-retry.json",
        "reenroll_operator_clear": "evidence/v2-raw/reenroll/operator-clear.json",
        "reenroll_after": "evidence/v2-raw/reenroll/after.json",
        "reenroll_clients": "evidence/v2-raw/reenroll/clients.json",
    },
    "release-derived-approval.json": {
        "release_metadata": "evidence/v2-raw/release/pearl-release.json",
        "release_signature": "evidence/v2-raw/release/pearl-release.json.sig",
        "release_invalid_metadata": "evidence/v2-raw/release/invalid-pearl-release.json",
        "release_invalid_signature": "evidence/v2-raw/release/invalid-pearl-release.json.sig",
        "release_public_key": "evidence/v2-raw/release/release-signing-public.pem",
        "release_file_stats": "evidence/v2-raw/release/file-stats.json",
        "release_eligibility": "evidence/v2-raw/release/eligibility.json",
        "release_approved_db": "evidence/v2-raw/release/approved-db.json",
        "release_denied_db": "evidence/v2-raw/release/denied-db.json",
        "release_withdrawn_db": "evidence/v2-raw/release/withdrawn-db.json",
    },
    "directory.json": {
        "directory_envelope": "evidence/v2-raw/directory/envelope.json",
        "directory_public_key": "evidence/v2-raw/directory/public-key.json",
        "directory_gateway_body": "evidence/v2-raw/directory/gateway-body.json",
        "directory_gateway_headers": "evidence/v2-raw/directory/gateway-headers.json",
        "directory_clients": "evidence/v2-raw/directory/clients.json",
        "directory_store": "evidence/v2-raw/directory/store.json",
        "directory_disclosure": "evidence/v2-raw/directory/disclosure.json",
    },
}
V2_DB_TABLES = (
    "privacy_class_enrollment",
    "relay_blind_key_records",
    "privacy_class_quarantine",
    "relay_blind_reservations",
    "privacy_class_operator_clear",
)
V2_DB_COLUMNS = {
    "privacy_class_enrollment": (
        "provider_id", "identity_fingerprint", "se_fingerprint", "team_id",
        "signing_identifier", "code_cdhash", "binary_version",
        "enrolled_at_unix", "revoked_at_unix", "revoked_reason",
    ),
    "relay_blind_key_records": (
        "provider_id", "kid", "assigned_session", "key_record_digest",
        "not_before_unix", "expires_at_unix", "accepted_at_unix",
        "revoked_at_unix", "revocation_retained_until_unix", "key_class",
    ),
    "privacy_class_quarantine": (
        "provider_id", "reason", "quarantined_at_unix", "expires_at_unix",
    ),
    "relay_blind_reservations": (
        "provider_id", "assigned_session", "key_record_digest", "kid", "model",
        "expires_at_unix", "state", "created_at_unix", "privacy_class",
        "terminal_code", "terminal_at_unix",
    ),
    "privacy_class_operator_clear": (
        "provider_id", "cleared_at_unix", "clear_generation",
    ),
}
# Facts the 1.8.215 run never recorded. Their observations rest on the
# indirect evidence named in the predicates; DYLD_* inertness is
# procedure-attested (the run-version kit line plus the recorded outputs).
NOT_RECOVERABLE_ITEMS = (
    "hardening-complete timestamp",
    "privacy frame sequence and final-frame count",
    "posture challenge/acceptance rows",
    "P_TRACED/CS_DEBUGGED",
    "DYLD invocation environment",
)
REWARD_TABLE_RE = re.compile(r"(reward|emission|unlock|verified_work|referral_serving|referral_social_grants)", re.I)
PRIVACY_KEY_ATTESTATION_DOMAIN = "macprovider/spec049/key-attestation/v1"


def b64url_bytes(value: Any) -> bytes | None:
    if not isinstance(value, str) or not value or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        return None
    try:
        return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (ValueError, TypeError):
        return None


def b64url_hex(value: Any) -> str:
    raw = b64url_bytes(value)
    return raw.hex() if raw is not None and len(raw) == 32 else ""


def utc_unix(value: Any) -> int | None:
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?", value.strip())
    if not match:
        return None
    base = datetime.strptime(f"{match.group(1)}T{match.group(2)}", "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    zone = match.group(4)
    if zone and zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        digits = zone[1:].replace(":", "")
        base -= sign * timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    return int(base.timestamp())


def privacy_posture(event: dict[str, Any]) -> int | None:
    usage = event.get("usage_macprovider_privacy")
    if not isinstance(usage, dict) or event.get("status") != 200:
        return None
    value = usage.get("posture_verified_at_unix")
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def _frame(data: bytes) -> bytes:
    return len(data).to_bytes(4, "big") + data


def key_record_signed_framing(record: dict[str, Any]) -> bytes:
    """SPEC-041 key-record signing input (relayblind KeyRecord.SignedFraming)."""
    public = b64url_bytes(record["public_key"])
    fingerprint = b64url_bytes(record["identity_fingerprint"])
    if public is None or len(public) != 32 or fingerprint is None or len(fingerprint) != 32:
        raise ValueError("key record key or fingerprint")
    models, families = record["models"], record["endpoint_families"]
    if not isinstance(models, list) or not isinstance(families, list):
        raise TypeError("key record arrays")
    framed = _frame(str(record["alg"]).encode()) + _frame(public) + _frame(fingerprint)
    framed += len(models).to_bytes(4, "big") + b"".join(_frame(str(item).encode()) for item in models)
    framed += int(record["max_encrypted_request_bytes"]).to_bytes(8, "big")
    framed += len(families).to_bytes(4, "big") + b"".join(_frame(str(item).encode()) for item in families)
    framed += _frame(str(record["signature_algorithm"]).encode())
    for value in (record["not_before_unix"], record["expires_at_unix"]):
        if not isinstance(value, int) or isinstance(value, bool):
            raise TypeError("key record time")
        framed += (value & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big")
    return framed


def attestation_framing(attestation: dict[str, Any]) -> bytes:
    """SPEC-049 key-attestation signing input (relayblind PrivacyKeyAttestation.Framing)."""
    framed = b""
    for value in (
        PRIVACY_KEY_ATTESTATION_DOMAIN,
        attestation["version"],
        attestation["key_record_digest"],
        attestation["privacy_class"],
        attestation["assurance"],
        attestation["binary_version"],
        attestation["code_cdhash"],
    ):
        if not isinstance(value, str):
            raise TypeError("attestation string field")
        data = value.encode("utf-8")
        framed += len(data).to_bytes(4, "big") + data
    for value in (attestation["not_before_unix"], attestation["expires_at_unix"]):
        if not isinstance(value, int) or isinstance(value, bool):
            raise TypeError("attestation time field")
        framed += (value & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big")
    return framed


# Ed25519 (RFC 8032 section 6 reference arithmetic); verification only needs
# public data, so no third-party dependency is required.
_ED_P = 2**255 - 19
_ED_Q = 2**252 + 27742317777372353535851937790883648493
_ED_D = -121665 * pow(121666, _ED_P - 2, _ED_P) % _ED_P
_ED_I = pow(2, (_ED_P - 1) // 4, _ED_P)


def _ed_add(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    A = (y1 - x1) * (y2 - x2) % _ED_P
    B = (y1 + x1) * (y2 + x2) % _ED_P
    C = t1 * 2 * _ED_D * t2 % _ED_P
    D = z1 * 2 * z2 % _ED_P
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F % _ED_P, G * H % _ED_P, F * G % _ED_P, E * H % _ED_P)


def _ed_mul(s: int, point: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    result = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            result = _ed_add(result, point)
        point = _ed_add(point, point)
        s >>= 1
    return result


def _ed_equal(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> bool:
    return (a[0] * b[2] - b[0] * a[2]) % _ED_P == 0 and (a[1] * b[2] - b[1] * a[2]) % _ED_P == 0


def _ed_recover_x(y: int, sign: int) -> int | None:
    if y >= _ED_P:
        return None
    x2 = (y * y - 1) * pow(_ED_D * y * y + 1, _ED_P - 2, _ED_P)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_ED_P + 3) // 8, _ED_P)
    if (x * x - x2) % _ED_P != 0:
        x = x * _ED_I % _ED_P
    if (x * x - x2) % _ED_P != 0:
        return None
    if (x & 1) != sign:
        x = _ED_P - x
    return x


_ED_GY = 4 * pow(5, _ED_P - 2, _ED_P) % _ED_P
_ED_GX = _ed_recover_x(_ED_GY, 0)
_ED_G = (_ED_GX, _ED_GY, 1, _ED_GX * _ED_GY % _ED_P)


def _ed_compress(point: tuple[int, int, int, int]) -> bytes:
    zinv = pow(point[2], _ED_P - 2, _ED_P)
    x, y = point[0] * zinv % _ED_P, point[1] * zinv % _ED_P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _ed_decompress(data: bytes) -> tuple[int, int, int, int] | None:
    if len(data) != 32:
        return None
    y = int.from_bytes(data, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _ed_recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % _ED_P)


def _ed_hash_int(data: bytes) -> int:
    return int.from_bytes(hashlib.sha512(data).digest(), "little")


def ed25519_verify(public: bytes, message: bytes, signature: bytes) -> bool:
    if len(public) != 32 or len(signature) != 64:
        return False
    point = _ed_decompress(public)
    rs = _ed_decompress(signature[:32])
    if point is None or rs is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _ED_Q:
        return False
    h = _ed_hash_int(signature[:32] + public + message) % _ED_Q
    return _ed_equal(_ed_mul(s, _ED_G), _ed_add(rs, _ed_mul(h, point)))


def ed25519_sign(seed: bytes, message: bytes) -> tuple[bytes, bytes]:
    """Test helper: (public key, signature) for a 32-byte seed."""
    digest = hashlib.sha512(seed).digest()
    a = int.from_bytes(digest[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    public = _ed_compress(_ed_mul(a, _ED_G))
    r = _ed_hash_int(digest[32:] + message) % _ED_Q
    big_r = _ed_compress(_ed_mul(r, _ED_G))
    s = (r + _ed_hash_int(big_r + public + message) * a) % _ED_Q
    return public, big_r + int.to_bytes(s, 32, "little")


class V2RawSourceView:
    """Verifier-owned v0.2 source-fact projection helpers.

    The capture composer uses this same view to derive primary/v2 manifests
    from finalized raw captures. `Checks` uses it to recompute and compare
    those manifests, so the source-to-summary rules live in one place.
    """

    def __init__(
        self,
        source_bytes,
        binding,
        trusted_release_public_key_sha256: str = TRUSTED_RELEASE_SIGNING_PUBLIC_KEY_SHA256,
    ) -> None:
        self._source_bytes = source_bytes
        self._binding_loader = binding if callable(binding) else None
        self._binding = None if callable(binding) else binding
        self.trusted_release_public_key_sha256 = trusted_release_public_key_sha256

    def source_bytes(self, manifest: str, kind: str) -> bytes:
        return self._source_bytes(manifest, kind)

    def binding(self) -> dict[str, str]:
        if self._binding is None:
            self._binding = self._binding_loader()
        return self._binding

    def source_json(self, manifest: str, kind: str) -> Any:
        path = V2_SOURCE_CONTRACT[manifest][kind]
        try:
            text = self.source_bytes(manifest, kind).decode("utf-8")
        except UnicodeDecodeError:
            fail(f"{path} must be UTF-8 JSON")
        return parse_json(text, path)

    def snapshot(self, manifest: str, kind: str) -> tuple[int, dict[str, list[dict[str, Any]]]]:
        label = V2_SOURCE_CONTRACT[manifest][kind]
        doc = self.source_json(manifest, kind)
        if not isinstance(doc, dict) or set(doc) != {"captured_at_unix", "tables"}:
            fail(f"{label} must carry exactly captured_at_unix and tables")
        captured = doc.get("captured_at_unix")
        tables = doc.get("tables")
        if not isinstance(captured, int) or isinstance(captured, bool) or captured <= 0:
            fail(f"{label}.captured_at_unix must be a positive integer")
        if not isinstance(tables, dict) or set(tables) != set(V2_DB_TABLES):
            fail(f"{label}.tables must be the closed v2 table set")
        result: dict[str, list[dict[str, Any]]] = {}
        for name in V2_DB_TABLES:
            export = tables[name]
            if not isinstance(export, dict) or set(export) != {"table", "columns", "dropped_columns", "row_count", "truncated", "rows"}:
                fail(f"{label}.{name} must be a complete primary row export")
            columns, rows = export.get("columns"), export.get("rows")
            if export.get("table") != name or export.get("truncated") is not False or not isinstance(columns, list) or not all(isinstance(item, str) for item in columns):
                fail(f"{label}.{name} must identify a complete untruncated table")
            if tuple(columns) != V2_DB_COLUMNS[name]:
                fail(f"{label}.{name} columns must be the closed public-state projection {list(V2_DB_COLUMNS[name])}")
            if not isinstance(export.get("dropped_columns"), list) or not isinstance(rows, list) or export.get("row_count") != len(rows):
                fail(f"{label}.{name} row metadata is invalid")
            if not all(isinstance(row, dict) and set(row) == set(columns) for row in rows):
                fail(f"{label}.{name} rows must exactly match columns")
            result[name] = rows
        return captured, result

    def clients(self, manifest: str, kind: str) -> tuple[int, dict[str, dict[str, Any]]]:
        label = V2_SOURCE_CONTRACT[manifest][kind]
        doc = self.source_json(manifest, kind)
        if not isinstance(doc, dict) or set(doc) != {"captured_at_unix", "attempts"}:
            fail(f"{label} must carry exactly captured_at_unix and attempts")
        captured, attempts = doc.get("captured_at_unix"), doc.get("attempts")
        if not isinstance(captured, int) or isinstance(captured, bool) or not isinstance(attempts, list):
            fail(f"{label} has invalid capture types")
        by_case: dict[str, dict[str, Any]] = {}
        required = {"case", "status", "provider_id", "response_excerpt"}
        for attempt in attempts:
            if not isinstance(attempt, dict) or set(attempt) != required:
                fail(f"{label} attempt must carry exactly {sorted(required)}")
            name = attempt.get("case")
            if not isinstance(name, str) or not name or name in by_case:
                fail(f"{label} attempt cases must be non-empty and unique")
            status = attempt.get("status")
            excerpt = attempt.get("response_excerpt")
            if not isinstance(status, int) or isinstance(status, bool) or not isinstance(excerpt, dict):
                fail(f"{label} attempt status/response types are invalid")
            if attempt.get("provider_id") is not None and not isinstance(attempt.get("provider_id"), str):
                fail(f"{label} attempt provider_id must be string or null")
            posture = error_code = None
            if set(excerpt) == {"usage_macprovider_privacy"}:
                usage = excerpt["usage_macprovider_privacy"]
                if not isinstance(usage, dict) or set(usage) != {"posture_verified_at_unix"} or not isinstance(usage["posture_verified_at_unix"], int) or isinstance(usage["posture_verified_at_unix"], bool):
                    fail(f"{label} successful response excerpt must carry the observed posture time")
                posture = usage["posture_verified_at_unix"]
            elif set(excerpt) == {"error"}:
                error = excerpt["error"]
                if not isinstance(error, dict) or set(error) != {"code"} or not isinstance(error["code"], str):
                    fail(f"{label} error response excerpt must carry the actual code")
                error_code = error["code"]
            else:
                fail(f"{label} response excerpt must be the closed usage or error shape")
            if (status == 200) is not (posture is not None):
                fail(f"{label} HTTP status must agree with the captured response excerpt")
            by_case[name] = {**attempt, "error_code": error_code, "privacy_posture_verified_at_unix": posture}
        return captured, by_case

    @staticmethod
    def active_enrollments(tables: dict[str, list[dict[str, Any]]]) -> list[dict[str, Any]]:
        return [row for row in tables["privacy_class_enrollment"] if row.get("revoked_at_unix") in (None, 0)]

    @staticmethod
    def privacy_keys(tables: dict[str, list[dict[str, Any]]]) -> list[dict[str, Any]]:
        return [row for row in tables["relay_blind_key_records"] if row.get("key_class") == "privacy"]

    @staticmethod
    def row_identity(rows: list[dict[str, Any]], keys: tuple[str, ...]) -> set[tuple[Any, ...]]:
        return {tuple(row.get(key) for key in keys) for row in rows}

    def auto_mode(self, errors: list[str]) -> dict[str, Any]:
        launch = self.source_json("auto-mode.json", "auto_launch")
        config = self.source_json("auto-mode.json", "auto_config")
        sessions = self.source_json("auto-mode.json", "auto_sessions")
        logs = self.source_json("auto-mode.json", "auto_logs")
        before_at, before = self.snapshot("auto-mode.json", "auto_db_before")
        after_at, after = self.snapshot("auto-mode.json", "auto_db_after")
        for value, label, keys in ((launch, "launch", {"cases"}), (config, "config", {"cases"}), (sessions, "sessions", {"cases"}), (logs, "logs", {"lines"})):
            if not isinstance(value, dict) or set(value) != keys or not isinstance(next(iter(value.values())), list):
                fail(f"auto-mode {label} capture has an invalid closed shape")
        required = {"automatic-eligible", "automatic-ineligible", "automatic-hardening-fallback", "explicit-optout", "explicit-relay-blind"}

        def indexed(rows: list[Any], keys: set[str], label: str) -> dict[str, dict[str, Any]]:
            out = {}
            for row in rows:
                if not isinstance(row, dict) or set(row) != keys or not isinstance(row.get("name"), str) or row["name"] in out:
                    fail(f"auto-mode {label} rows must have a closed shape and unique names")
                out[row["name"]] = row
            if set(out) != required:
                fail(f"auto-mode {label} cases must be exactly {sorted(required)}")
            return out

        launches = indexed(launch["cases"], {"name", "executable_sha256", "arguments", "started_at_unix"}, "launch")
        configs = indexed(config["cases"], {"name", "privacy_class_requested", "relay_blind_requested"}, "config")
        captured_sessions = indexed(sessions["cases"], {"name", "provider_id", "accepted_at_unix", "claims", "effective_mode"}, "session")
        log_rows = logs["lines"]
        if not all(isinstance(row, dict) and set(row) == {"name", "stream", "line"} and row.get("name") in required and row.get("stream") in ("stdout", "stderr") and isinstance(row.get("line"), str) for row in log_rows):
            fail("auto-mode logs must be closed captured output lines")
        before_keys = self.privacy_keys(before)
        after_keys = self.privacy_keys(after)
        expected_modes = {
            "automatic-eligible": (None, None, "privacy", 1, True),
            "automatic-ineligible": (None, None, "ordinary", 0, False),
            "automatic-hardening-fallback": (None, None, "ordinary", 0, False),
            "explicit-optout": (False, None, "ordinary", 0, False),
            "explicit-relay-blind": (None, True, "plain_relay_blind", 0, False),
        }
        recomputed = []
        for name in required:
            cli, cfg, session = launches[name], configs[name], captured_sessions[name]
            arguments = cli.get("arguments")
            expect(isinstance(arguments, dict) and set(arguments) == {"privacy_class_beta", "relay_blind_enabled"}, errors, f"{name} launch must capture only the two non-secret mode arguments")
            expect(cli.get("executable_sha256") == self.binding()["binary_sha256"], errors, f"{name} launch must bind the tested executable bytes")
            expect(all(isinstance(cli[key], int) and not isinstance(cli[key], bool) for key in ("started_at_unix",)), errors, f"{name} launch time must be integral")
            requested, relay_requested, outcome, delta, claimed = expected_modes[name]
            expect(cfg["privacy_class_requested"] is requested and cfg["relay_blind_requested"] is relay_requested, errors, f"{name} config must select the expected mode")
            expect(arguments == {"privacy_class_beta": requested, "relay_blind_enabled": relay_requested}, errors, f"{name} launch arguments and loaded config must agree")
            expect(session["effective_mode"] == outcome and isinstance(session["claims"], list), errors, f"{name} session must capture the expected effective mode")
            provider = session.get("provider_id")
            before_count = sum(row.get("provider_id") == provider and row.get("revoked_at_unix") in (None, 0) for row in before_keys)
            after_count = sum(row.get("provider_id") == provider and row.get("revoked_at_unix") in (None, 0) for row in after_keys)
            expect(after_count - before_count == delta, errors, f"{name} privacy key advertisement delta must be {delta}")
            expect(("privacy_class" in session["claims"]) is claimed, errors, f"{name} privacy claim must match recomputed mode")
            expect(before_at <= cli["started_at_unix"] <= session["accepted_at_unix"] <= after_at, errors, f"{name} capture ordering is invalid")
            reasons: list[str] = []
            for row in log_rows:
                if row["name"] != name:
                    continue
                match = re.fullmatch(r"privacy_class auto_(?:ineligible|hardening_failed) reasons=([a-z0-9_,]+)", row["line"].rstrip("\n"))
                if match:
                    reasons.extend(match.group(1).split(","))
            if name == "automatic-ineligible":
                expect(bool(reasons), errors, "automatic-ineligible must carry the actual bounded fallback log")
            if name == "automatic-hardening-fallback":
                expect("configuration_changed" in reasons, errors, "automatic hardening fallback must capture configuration_changed")
            recomputed.append({
                "name": name, "mode": "off" if requested is False or relay_requested is not None else "automatic",
                "source": "launch/config/session/log/db", "outcome": outcome, "bounded_reasons": sorted(set(reasons)),
                "privacy_key_record_count": delta, "claims": session["claims"],
                "mode_decision_unix": cli["started_at_unix"], "credentials_resolution_unix": session["accepted_at_unix"],
            })
        return {"cases": sorted(recomputed, key=lambda item: item["name"])}

    def enrollment(self, errors: list[str]) -> dict[str, Any]:
        before_at, before = self.snapshot("enrollment.json", "enrollment_before")
        first_at, first = self.snapshot("enrollment.json", "enrollment_after_first")
        second_at, second = self.snapshot("enrollment.json", "enrollment_after_second")
        reuse_at, reuse = self.snapshot("enrollment.json", "enrollment_after_reuse")
        failed_at, failed = self.snapshot("enrollment.json", "enrollment_after_failed_posture")
        clients_at, clients = self.clients("enrollment.json", "enrollment_clients")
        expect(before_at < first_at < second_at < reuse_at < failed_at <= clients_at, errors, "enrollment phase snapshots must be strictly ordered")
        before_rows, first_rows, second_rows = map(self.active_enrollments, (before, first, second))
        new_first = [row for row in first_rows if row not in before_rows]
        new_second = [row for row in second_rows if row not in first_rows]
        expect(len(new_first) == 1 and len(new_second) == 1, errors, "the two admissions must each add exactly one active enrollment")
        recomputed = []
        for case, row, phase in (("first-admission", new_first[0] if new_first else {}, first), ("second-admission", new_second[0] if new_second else {}, second)):
            attempt = clients.get(case) or {}
            enrolled = row.get("enrolled_at_unix")
            posture = attempt.get("privacy_posture_verified_at_unix")
            expect(attempt.get("status") == 200 and attempt.get("error_code") is None and attempt.get("provider_id") == row.get("provider_id"), errors, f"{case} must be an actual successful client capture")
            expect(isinstance(enrolled, int) and isinstance(posture, int) and enrolled <= posture <= clients_at, errors, f"{case} must prove enrollment commit before successful posture admission")
            expect(sum(item.get("provider_id") == row.get("provider_id") for item in second_rows) == 1, errors, f"{case} provider must have one active enrollment")
            keys = [item for item in self.privacy_keys(phase) if item.get("provider_id") == row.get("provider_id") and item.get("revoked_at_unix") in (None, 0)]
            expect(bool(keys) and all(isinstance(item.get("accepted_at_unix"), int) and item["accepted_at_unix"] <= enrolled and isinstance(item.get("expires_at_unix"), int) and item["expires_at_unix"] > posture for item in keys), errors, f"{case} enrollment must be backed by fresh accepted privacy key rows")
            recomputed.append({"provider_id": row.get("provider_id"), "identity_fingerprint": row.get("identity_fingerprint"), "se_fingerprint": row.get("se_fingerprint"), "enrollment_committed_unix": enrolled, "posture_verified_unix": posture, "active_rows_for_provider": 1})
        pairs = {(row.get("identity_fingerprint"), row.get("se_fingerprint")) for row in second_rows}
        expect(all(isinstance(identity, str) and re.fullmatch(r"[A-Za-z0-9_-]{43}", identity) and isinstance(se, str) and re.fullmatch(r"[A-Za-z0-9_-]{43}", se) for identity, se in pairs), errors, "enrollment fingerprints must be canonical base64url SHA-256 values")
        expect(len({row.get("provider_id") for row in second_rows}) == len(second_rows) and len(pairs) == len(second_rows), errors, "active providers must have genuinely distinct identity and Secure Enclave key pairs")
        expect(self.row_identity(self.active_enrollments(reuse), ("provider_id", "identity_fingerprint", "se_fingerprint", "enrolled_at_unix")) == self.row_identity(second_rows, ("provider_id", "identity_fingerprint", "se_fingerprint", "enrolled_at_unix")), errors, "cross-provider reuse must create no enrollment")
        expect(self.row_identity(self.active_enrollments(failed), ("provider_id", "identity_fingerprint", "se_fingerprint", "enrolled_at_unix")) == self.row_identity(second_rows, ("provider_id", "identity_fingerprint", "se_fingerprint", "enrolled_at_unix")), errors, "failed posture must create no enrollment")
        reuse_attempt, failed_attempt = clients.get("cross-provider-reuse") or {}, clients.get("failed-posture") or {}
        expect(reuse_attempt.get("status") != 200 and reuse_attempt.get("error_code") == "privacy_enrollment_key_in_use", errors, "cross-provider key reuse must return the runtime privacy_enrollment_key_in_use code")
        expect(failed_attempt.get("status") != 200 and isinstance(failed_attempt.get("error_code"), str) and failed_attempt["error_code"].startswith("privacy_"), errors, "failed posture must carry an actual privacy error")
        return {
            "enrollments": recomputed,
            "cross_provider_reuse": {"result_code": reuse_attempt.get("error_code"), "quarantine_rows_created": len(reuse["privacy_class_quarantine"]) - len(second["privacy_class_quarantine"]), "enrollment_rows_created": len(reuse["privacy_class_enrollment"]) - len(second["privacy_class_enrollment"])},
            "failed_posture": {"result_code": failed_attempt.get("error_code"), "enrollment_rows_created": len(failed["privacy_class_enrollment"]) - len(reuse["privacy_class_enrollment"])},
        }

    def key_change_reenroll(self, errors: list[str]) -> dict[str, Any]:
        initial_at, initial = self.snapshot("reenroll.json", "reenroll_initial")
        changed_at, changed = self.snapshot("reenroll.json", "reenroll_key_change")
        retry_at, retry = self.snapshot("reenroll.json", "reenroll_expiry_retry")
        clear_at, clear = self.snapshot("reenroll.json", "reenroll_operator_clear")
        after_at, after = self.snapshot("reenroll.json", "reenroll_after")
        clients_at, clients = self.clients("reenroll.json", "reenroll_clients")
        expect(initial_at < changed_at < retry_at < clear_at < after_at <= clients_at, errors, "reenroll phase snapshots must be strictly ordered")
        active_initial = self.active_enrollments(initial)
        expect(len(active_initial) == 1, errors, "reenroll initial snapshot must have one active enrollment")
        provider = active_initial[0].get("provider_id") if active_initial else None
        old_fingerprint = active_initial[0].get("identity_fingerprint") if active_initial else None
        changed_quarantine = [row for row in changed["privacy_class_quarantine"] if row.get("provider_id") == provider]
        retry_quarantine = [row for row in retry["privacy_class_quarantine"] if row.get("provider_id") == provider]
        expect(len(changed_quarantine) == 1 and changed_quarantine[0].get("reason") == "privacy_enrollment_key_changed", errors, "key-change snapshot must hold the runtime quarantine reason")
        expect(len(retry_quarantine) == 1 and retry_quarantine[0].get("reason") == "privacy_enrollment_key_changed" and retry_quarantine[0].get("quarantined_at_unix", 0) > changed_quarantine[0].get("expires_at_unix", 0), errors, "post-expiry retry must create a later privacy_enrollment_key_changed quarantine")
        initial_keys = [row for row in self.privacy_keys(initial) if row.get("provider_id") == provider and row.get("revoked_at_unix") in (None, 0)]
        revoked_keys = [row for row in self.privacy_keys(changed) if row.get("provider_id") == provider and row.get("revoked_at_unix") not in (None, 0)]
        expect(bool(initial_keys) and len(revoked_keys) >= len(initial_keys), errors, "key change must revoke the provider's active privacy keys")
        expect(self.row_identity(self.active_enrollments(changed), ("provider_id", "identity_fingerprint", "enrolled_at_unix")) == self.row_identity(active_initial, ("provider_id", "identity_fingerprint", "enrolled_at_unix")), errors, "key change must not replace the enrollment")
        clear_active = self.active_enrollments(clear)
        revoked_old = [row for row in clear["privacy_class_enrollment"] if row.get("provider_id") == provider and row.get("identity_fingerprint") == old_fingerprint and row.get("revoked_at_unix") not in (None, 0)]
        operator_rows = [row for row in clear["privacy_class_operator_clear"] if row.get("provider_id") == provider]
        rejected = [row for row in clear["relay_blind_reservations"] if row.get("provider_id") == provider and row.get("privacy_class") == 1 and row.get("state") == "rejected" and row.get("terminal_code") == "relay_blind_key_expired"]
        expect(bool(revoked_old) and not any(row.get("provider_id") == provider for row in clear_active), errors, "operator reenroll must revoke the old active enrollment")
        expect(len(operator_rows) == 1 and isinstance(operator_rows[0].get("clear_generation"), int) and operator_rows[0]["clear_generation"] > 0, errors, "operator reenroll must durably advance operator-clear generation")
        expect(not any(row.get("provider_id") == provider for row in clear["privacy_class_quarantine"]) and bool(rejected), errors, "operator reenroll must clear quarantine and reject held reservations")
        new_active = [row for row in self.active_enrollments(after) if row.get("provider_id") == provider]
        admission = clients.get("post-reenroll-admission") or {}
        expect(len(new_active) == 1 and new_active[0].get("identity_fingerprint") != old_fingerprint, errors, "post-reenroll admission must create one new identity")
        expect(admission.get("status") == 200 and admission.get("provider_id") == provider and isinstance(admission.get("privacy_posture_verified_at_unix"), int) and new_active and new_active[0].get("enrolled_at_unix", 0) <= admission["privacy_posture_verified_at_unix"], errors, "new enrollment must commit before the successful post-reenroll posture")
        return {
            "initial": {"active_enrollment_rows": len(active_initial), "identity_fingerprint": old_fingerprint},
            "key_change": {"quarantine_reason": changed_quarantine[0].get("reason") if changed_quarantine else None, "privacy_key_records_revoked_count": len(revoked_keys), "active_enrollment_replacements": len(self.active_enrollments(changed)) - len(active_initial)},
            "post_expiry_retry": {"quarantine_reason": retry_quarantine[0].get("reason") if retry_quarantine else None},
            "operator_reenroll": {"revoked_old_enrollment_count": len(revoked_old), "held_privacy_reservations_rejected_count": len(rejected), "quarantine_rows_remaining": sum(row.get("provider_id") == provider for row in clear["privacy_class_quarantine"])},
            "after_reenroll": {"new_active_enrollment_rows": len(new_active), "identity_fingerprint": new_active[0].get("identity_fingerprint") if new_active else None},
        }

    def release_approval(self, errors: list[str]) -> dict[str, Any]:
        identity = self.binding()
        payload = self.source_bytes("release-derived-approval.json", "release_metadata")
        signature = self.source_bytes("release-derived-approval.json", "release_signature")
        invalid_payload = self.source_bytes("release-derived-approval.json", "release_invalid_metadata")
        invalid_signature = self.source_bytes("release-derived-approval.json", "release_invalid_signature")
        public_key = self.source_bytes("release-derived-approval.json", "release_public_key")
        expect(hashlib.sha256(public_key).hexdigest() == self.trusted_release_public_key_sha256, errors, "release metadata public key must equal the repository-trusted release signing key")
        metadata_doc = parse_json(payload.decode("utf-8"), V2_SOURCE_CONTRACT["release-derived-approval.json"]["release_metadata"])
        provider_identity = metadata_doc.get("provider_code_identity") if isinstance(metadata_doc, dict) else None
        if not isinstance(provider_identity, dict) or set(provider_identity) != {"asset", "member", "binary_version", "binary_sha256", "team_id", "signing_identifier", "slices"}:
            fail("signed release metadata must carry one closed provider_code_identity")
        slices = provider_identity.get("slices")
        if not isinstance(slices, list) or len(slices) != 1 or not isinstance(slices[0], dict) or set(slices[0]) != {"arch", "code_cdhash"}:
            fail("signed release metadata must carry one closed arm64 slice")
        approved = {"team_id": provider_identity.get("team_id"), "signing_identifier": provider_identity.get("signing_identifier"), "code_cdhash": slices[0].get("code_cdhash"), "binary_version": provider_identity.get("binary_version")}
        expect(provider_identity.get("member") == "macprovider-cli" and slices[0].get("arch") == "arm64", errors, "release metadata must name the arm64 macprovider-cli")
        expect(provider_identity.get("binary_sha256") == identity["binary_sha256"] and provider_identity.get("asset") == f"macprovider-cli-v{identity['binary_version']}-darwin-arm64.tar.gz", errors, "release metadata must bind the tested binary bytes")
        for key in approved:
            expect(approved[key] == identity[key], errors, f"cryptographically verified release identity {key} must equal step-01")
        verified = verify_pinned_public_ecdsa_sha256(public_key, self.trusted_release_public_key_sha256, payload, signature)
        invalid_verified = verify_pinned_public_ecdsa_sha256(public_key, self.trusted_release_public_key_sha256, invalid_payload, invalid_signature)
        expect(verified, errors, "release metadata signature must cryptographically verify over exact bytes")
        invalid_doc = parse_json(invalid_payload.decode("utf-8"), V2_SOURCE_CONTRACT["release-derived-approval.json"]["release_invalid_metadata"])
        invalid_identity = invalid_doc.get("provider_code_identity") if isinstance(invalid_doc, dict) else None
        invalid_schema = isinstance(invalid_identity, dict) and set(invalid_identity) == {"asset", "member", "binary_version", "binary_sha256", "team_id", "signing_identifier", "slices"}
        expect(invalid_verified and not invalid_schema, errors, "invalid metadata fixture must be trusted-key-signed exact bytes that fail the provider identity schema")
        stats = self.source_json("release-derived-approval.json", "release_file_stats")
        if not isinstance(stats, dict) or set(stats) != {"metadata", "signature", "public_key"}:
            fail("release file stats must be a closed lstat capture")
        stat_keys = {"regular", "symlink", "bytes"}
        if not all(isinstance(value, dict) and set(value) == stat_keys and isinstance(value.get("regular"), bool) and isinstance(value.get("symlink"), bool) and isinstance(value.get("bytes"), int) for value in stats.values()):
            fail("release file stats entries must carry regular, symlink, and bytes")
        expect(stats["metadata"] == {"regular": True, "symlink": False, "bytes": len(payload)} and stats["signature"] == {"regular": True, "symlink": False, "bytes": len(signature)} and stats["public_key"] == {"regular": True, "symlink": False, "bytes": len(public_key)}, errors, "release lstat capture must match the exact exported file bytes")
        captures = self.source_json("release-derived-approval.json", "release_eligibility")
        if not isinstance(captures, dict) or set(captures) != {"approved", "denied", "withdrawn", "invalid_metadata"}:
            fail("release eligibility capture must have approved, denied, withdrawn, and invalid_metadata phases")
        phase_keys = {"approved_code_identities", "denied_cdhashes", "metadata_directory_present", "provider_id", "client_status", "client_response_excerpt"}
        for phase, value in captures.items():
            if not isinstance(value, dict) or set(value) != phase_keys or not isinstance(value.get("approved_code_identities"), list) or not isinstance(value.get("denied_cdhashes"), list):
                fail(f"release eligibility {phase} capture has an invalid closed shape")
            if not isinstance(value.get("provider_id"), str) or not isinstance(value.get("client_status"), int) or not isinstance(value.get("client_response_excerpt"), dict):
                fail(f"release eligibility {phase} client capture types are invalid")

        def release_error(phase: str) -> str | None:
            excerpt = captures[phase]["client_response_excerpt"]
            if set(excerpt) == {"usage_macprovider_privacy"}:
                usage = excerpt["usage_macprovider_privacy"]
                if not isinstance(usage, dict) or set(usage) != {"posture_verified_at_unix"} or not isinstance(usage["posture_verified_at_unix"], int):
                    fail(f"release eligibility {phase} success excerpt is invalid")
                return None
            if set(excerpt) == {"error"} and isinstance(excerpt["error"], dict) and set(excerpt["error"]) == {"code"} and isinstance(excerpt["error"]["code"], str):
                return excerpt["error"]["code"]
            fail(f"release eligibility {phase} response excerpt is invalid")
            raise AssertionError("unreachable")

        approved_at, _approved_db = self.snapshot("release-derived-approval.json", "release_approved_db")
        denied_at, denied_db = self.snapshot("release-derived-approval.json", "release_denied_db")
        withdrawn_at, _withdrawn_db = self.snapshot("release-derived-approval.json", "release_withdrawn_db")
        expect(approved_at < denied_at < withdrawn_at, errors, "release eligibility DB captures must be ordered")
        expect(approved in captures["approved"]["approved_code_identities"] and captures["approved"]["client_status"] == 200 and release_error("approved") is None, errors, "verified release identity must be loaded before eligible admission")
        provider = captures["denied"]["provider_id"]
        denied_quarantine = [row for row in denied_db["privacy_class_quarantine"] if row.get("provider_id") == provider and row.get("reason") == "posture_denied_code_identity"]
        denied_revoked = [row for row in self.privacy_keys(denied_db) if row.get("provider_id") == provider and row.get("revoked_at_unix") not in (None, 0)]
        expect(identity["code_cdhash"] in captures["denied"]["denied_cdhashes"] and release_error("denied") == "posture_denied_code_identity" and bool(denied_quarantine) and bool(denied_revoked), errors, "denied cdhash must produce the actual quarantine and key revocation state")
        expect(captures["withdrawn"]["metadata_directory_present"] is False and approved not in captures["withdrawn"]["approved_code_identities"] and captures["withdrawn"]["client_status"] != 200 and release_error("withdrawn") is not None, errors, "withdrawal capture must remove release-derived eligibility")
        expect(captures["invalid_metadata"]["approved_code_identities"] == [] and captures["invalid_metadata"]["client_status"] != 200 and release_error("invalid_metadata") is not None, errors, "trusted-key-signed invalid metadata must contribute no identity and no eligible admission")
        return {
            "approved_identity": approved,
            "metadata": {"signature_result": "verified" if verified else "rejected", "regular_file": stats["metadata"]["regular"] and not stats["metadata"]["symlink"], "signature_regular_file": stats["signature"]["regular"] and not stats["signature"]["symlink"], "failed_metadata_identity_count": len(captures["invalid_metadata"]["approved_code_identities"])},
            "eligibility": {"before_withdrawal": "eligible" if captures["approved"]["client_status"] == 200 else "ineligible", "after_denied_cdhash": "quarantined" if denied_quarantine else "ineligible", "after_withdrawal_or_expiry": "ineligible" if captures["withdrawn"]["client_status"] != 200 else "eligible"},
        }

    def directory(self, errors: list[str]) -> dict[str, Any]:
        envelope_raw = self.source_bytes("directory.json", "directory_envelope")
        gateway_raw = self.source_bytes("directory.json", "directory_gateway_body")
        envelope = parse_json(envelope_raw.decode("utf-8"), "directory envelope")
        public_doc = self.source_json("directory.json", "directory_public_key")
        headers = self.source_json("directory.json", "directory_gateway_headers")
        clients = self.source_json("directory.json", "directory_clients")
        store = self.source_json("directory.json", "directory_store")
        disclosure = self.source_json("directory.json", "directory_disclosure")
        if not isinstance(envelope, dict) or set(envelope) != {"version", "key_id", "payload", "signature"}:
            fail("directory envelope must be a closed object")
        if not isinstance(public_doc, dict) or set(public_doc) != {"algorithm", "public_key"} or public_doc.get("algorithm") != "ed25519":
            fail("directory public key capture must be a closed Ed25519 pin")
        public = b64url_bytes(public_doc.get("public_key"))
        payload = b64url_bytes(envelope.get("payload"))
        signature = b64url_bytes(envelope.get("signature"))
        if public is None or len(public) != 32 or payload is None or signature is None or len(signature) != 64:
            fail("directory key, payload, and signature must be canonical base64url bytes")
        canonical = lambda raw: base64.urlsafe_b64encode(raw).decode().rstrip("=")
        expect(public_doc.get("public_key") == canonical(public) and envelope.get("payload") == canonical(payload) and envelope.get("signature") == canonical(signature), errors, "directory key, payload, and signature encodings must be canonical base64url")
        key_id = base64.urlsafe_b64encode(hashlib.sha256(public).digest()).decode().rstrip("=")
        signed = _frame(b"macprovider/spec049/identity-directory/v1") + _frame(payload)
        signature_ok = ed25519_verify(public, signed, signature)
        expect(envelope.get("version") == "privacy-identity-directory-envelope-v1" and envelope.get("key_id") == key_id and signature_ok, errors, "directory signature must verify over exact payload bytes under the pinned key")
        payload_doc = parse_json(payload.decode("utf-8"), "directory payload")
        if not isinstance(payload_doc, dict) or set(payload_doc) != {"version", "privacy_class", "issued_at_unix", "expires_at_unix", "entries"}:
            fail("directory payload must be a closed object")
        entries = payload_doc.get("entries")
        if not isinstance(entries, list):
            fail("directory entries must be a list")
        def canonical_b64url32(value: Any) -> bytes | None:
            raw = b64url_bytes(value)
            if raw is None or len(raw) != 32 or value != canonical(raw):
                return None
            return raw

        fingerprints: list[str] = []
        enrolled_entries: set[tuple[str, str, int, bool]] = set()
        operator_pin_entries = 0
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"identity_public_key", "fingerprint", "se_public_key_fingerprint", "source", "enrolled_at_unix", "revoked"}:
                fail("directory entries must be closed objects")
            identity_key = b64url_bytes(entry.get("identity_public_key"))
            expect(identity_key is not None and len(identity_key) == 32 and entry.get("identity_public_key") == canonical(identity_key) and canonical(hashlib.sha256(identity_key).digest()) == entry.get("fingerprint"), errors, "directory entry fingerprint must derive from its canonical public key")
            se_fingerprint = canonical_b64url32(entry.get("se_public_key_fingerprint"))
            enrolled_at = entry.get("enrolled_at_unix")
            source = entry.get("source")
            revoked = entry.get("revoked")
            expect(se_fingerprint is not None and isinstance(enrolled_at, int) and not isinstance(enrolled_at, bool) and enrolled_at >= 0 and source in ("enrolled", "operator_pin") and isinstance(revoked, bool), errors, "directory entries must have typed source/revocation/enrollment fields and canonical 32-byte SE fingerprints")
            if source == "enrolled" and isinstance(entry.get("fingerprint"), str) and se_fingerprint is not None and isinstance(enrolled_at, int) and not isinstance(enrolled_at, bool) and isinstance(revoked, bool):
                enrolled_entries.add((entry["fingerprint"], entry["se_public_key_fingerprint"], enrolled_at, revoked))
            elif source == "operator_pin":
                operator_pin_entries += 1
            fingerprints.append(entry.get("fingerprint"))
        expect(all(isinstance(item, str) for item in fingerprints) and fingerprints == sorted(fingerprints) and len(fingerprints) == len(set(fingerprints)), errors, "directory entries must be uniquely sorted by fingerprint")
        issued, expires = payload_doc.get("issued_at_unix"), payload_doc.get("expires_at_unix")
        expect(payload_doc.get("version") == "privacy-identity-directory-v1" and payload_doc.get("privacy_class") == PRIVACY_CLASS, errors, "directory payload version and privacy class must be exact")
        expect(isinstance(issued, int) and not isinstance(issued, bool) and issued >= 0 and isinstance(expires, int) and not isinstance(expires, bool) and expires >= 0 and 60 <= expires - issued <= 3600, errors, "directory validity window must be bounded")
        if not isinstance(headers, dict) or set(headers) != {"status", "cache_control", "content_type", "captured_at_unix", "store_error_code"}:
            fail("directory gateway headers must be a closed capture")
        expect(gateway_raw == envelope_raw, errors, "gateway directory response body must be byte-identical to the signed envelope")
        expect(headers.get("status") == 200 and headers.get("cache_control") == "no-store" and headers.get("content_type") == "application/json" and isinstance(headers.get("captured_at_unix"), int) and not isinstance(headers.get("captured_at_unix"), bool) and headers.get("captured_at_unix") >= 0 and issued <= headers["captured_at_unix"] < expires, errors, "gateway capture must be fresh, JSON, and no-store")
        expect(headers.get("store_error_code") == "privacy_class_unavailable", errors, "directory store error capture must fail closed")
        if not isinstance(store, dict) or set(store) != {"enrollments", "quarantined_provider_ids"} or not isinstance(store.get("enrollments"), list) or not isinstance(store.get("quarantined_provider_ids"), list):
            fail("directory store capture must be closed enrollment/quarantine rows")
        quarantined_provider_ids = store["quarantined_provider_ids"]
        expect(all(isinstance(item, str) and item for item in quarantined_provider_ids) and len(quarantined_provider_ids) == len(set(quarantined_provider_ids)), errors, "directory quarantined provider ids must be non-empty unique strings")
        quarantined = set(quarantined_provider_ids) if all(isinstance(item, str) for item in quarantined_provider_ids) else set()
        store_entries: set[tuple[str, str, int, bool]] = set()
        seen_store_rows: set[tuple[str, str, str, int]] = set()
        for row in store["enrollments"]:
            if not isinstance(row, dict) or set(row) != {"provider_id", "identity_fingerprint", "se_fingerprint", "enrolled_at_unix", "revoked_at_unix"}:
                fail("directory enrollment store rows must be closed provider/identity/SE/enrollment/revocation facts")
            provider_id = row.get("provider_id")
            identity_fingerprint = row.get("identity_fingerprint")
            se_fingerprint = row.get("se_fingerprint")
            enrolled_at = row.get("enrolled_at_unix")
            revoked_at = row.get("revoked_at_unix")
            valid_row = (
                isinstance(provider_id, str) and bool(provider_id) and
                canonical_b64url32(identity_fingerprint) is not None and
                canonical_b64url32(se_fingerprint) is not None and
                isinstance(enrolled_at, int) and not isinstance(enrolled_at, bool) and enrolled_at >= 0 and
                (revoked_at is None or (isinstance(revoked_at, int) and not isinstance(revoked_at, bool) and revoked_at >= 0))
            )
            expect(valid_row, errors, "directory enrollment store rows must carry typed canonical fingerprints and timestamps")
            if valid_row:
                store_key = (provider_id, identity_fingerprint, se_fingerprint, enrolled_at)
                expect(store_key not in seen_store_rows, errors, "directory enrollment store rows must not contain duplicates")
                seen_store_rows.add(store_key)
                store_entries.add((identity_fingerprint, se_fingerprint, enrolled_at, revoked_at not in (None, 0) or provider_id in quarantined))
        active_entries = {row for row in enrolled_entries if row[3] is False}
        revoked_entries = {row for row in enrolled_entries if row[3] is True}
        expect(operator_pin_entries == 0, errors, "directory operator_pin entries require raw configured operator pin facts")
        expect(store_entries == enrolled_entries and bool(active_entries) and bool(revoked_entries), errors, "directory enrolled entries must exactly match store identity/SE/enrollment/revocation facts")
        if not isinstance(clients, dict) or set(clients) != {"captured_at_unix", "attempts"} or not isinstance(clients.get("attempts"), list):
            fail("directory client negatives must be a closed capture")
        attempts = {row.get("case"): row for row in clients["attempts"] if isinstance(row, dict) and set(row) == {"case", "accepted", "error_code"}}
        expect(set(attempts) == {"tampered", "expired", "revoked", "wrong_key"} and all(row.get("accepted") is False and isinstance(row.get("error_code"), str) for row in attempts.values()), errors, "directory client must reject every closed negative case")
        tampered = bytes([payload[0] ^ 1]) + payload[1:]
        expect(not ed25519_verify(public, _frame(b"macprovider/spec049/identity-directory/v1") + _frame(tampered), signature), errors, "tampered directory payload must fail signature verification")
        wrong_public = hashlib.sha256(public).digest()
        expect(not ed25519_verify(wrong_public, signed, signature), errors, "wrong pinned directory key must fail verification")
        expect(isinstance(clients.get("captured_at_unix"), int) and not isinstance(clients.get("captured_at_unix"), bool) and clients["captured_at_unix"] >= 0 and clients["captured_at_unix"] >= expires, errors, "expired negative capture must be at or after expiry")
        if not isinstance(disclosure, dict) or set(disclosure) != {"residual_risks"} or not isinstance(disclosure.get("residual_risks"), list):
            fail("directory disclosure must be a closed residual-risk capture")
        expect(disclosure["residual_risks"] == list(PRIVACY_RESIDUAL_RISKS_V2), errors, "directory disclosure must contain the exact v2 residual-risk list")
        return {
            "directory": {"signature_result": "verified" if signature_ok else "rejected", "public_key_pin": public_doc["public_key"], "key_id": key_id, "entry_count": len(entries), "revoked_entry_count": sum(row.get("revoked") is True for row in entries), "ttl_seconds": expires - issued, "body_sha256": hashlib.sha256(envelope_raw).hexdigest()},
            "client_rejections": {name: "rejected" for name in sorted(attempts)},
            "gateway": {"body_sha256": hashlib.sha256(gateway_raw).hexdigest(), "cache_control": headers.get("cache_control"), "store_error_code": headers.get("store_error_code")},
            "disclosure": disclosure,
        }

    def manifest(self, manifest: str, errors: list[str]) -> dict[str, Any]:
        if manifest == "auto-mode.json":
            return self.auto_mode(errors)
        if manifest == "enrollment.json":
            return self.enrollment(errors)
        if manifest == "reenroll.json":
            return self.key_change_reenroll(errors)
        if manifest == "release-derived-approval.json":
            return self.release_approval(errors)
        if manifest == "directory.json":
            return self.directory(errors)
        fail(f"unknown v2 source manifest: {manifest}")


class Checks:
    """Bundle predicates. Each returns a list of failures; empty means it holds."""

    def __init__(
        self,
        bundle: Bundle,
        profile: EvidenceProfile = PROFILE_V1,
        *,
        trusted_release_public_key_sha256: str = TRUSTED_RELEASE_SIGNING_PUBLIC_KEY_SHA256,
    ) -> None:
        self.b = bundle
        self.profile = profile
        self.trusted_release_public_key_sha256 = trusted_release_public_key_sha256
        self._cache: dict[str, list[str]] = {}

    def run(self, name: str) -> list[str]:
        if name not in self._cache:
            errors: list[str] = []
            try:
                getattr(self, f"p_{name}")(errors)
            except PrivacyEvidenceError as exc:
                errors.append(str(exc))
            except (KeyError, TypeError, ValueError, AttributeError, IndexError) as exc:
                errors.append(f"malformed artifact: {type(exc).__name__}: {exc}")
            self._cache[name] = [f"{name}: {item}" for item in errors]
        return self._cache[name]

    # -- shared readers

    def identity(self, instance: str) -> dict[str, Any]:
        return self.b.json_object(f"step-01b-isolated-stack/identity-{instance}.json")

    def provider_id(self, instance: str) -> str:
        value = self.b.json_object(f"step-01b-isolated-stack/credentials-import-{instance}.txt").get("provider_id")
        if not isinstance(value, str) or not value:
            fail(f"credentials-import-{instance}.txt must name provider_id")
        return value

    def binding(self) -> dict[str, str]:
        text = self.b.text("step-01-bind-signed-release/binding.txt")
        patterns = {
            "hardware": r"^hardware=(?P<hardware_model>[A-Za-z0-9,]+) .+ ram_bytes=(?P<ram_bytes>[0-9]+)$",
            "macos": r"^macos=(?P<macos>[0-9.]+) build=(?P<macos_build>[A-Za-z0-9]+)$",
            "sip": r"^sip=System Integrity Protection status: (?P<sip>enabled)\.$",
            "release": r"^binary_version=(?P<binary_version>[0-9]+\.[0-9]+\.[0-9]+) release_tag=(?P<release_tag>\S+) compatibility_set_id=(?P<compatibility_set_id>\S+)$",
            "code": r"^binary_sha256=(?P<binary_sha256>[0-9a-f]{64}) cdhash=(?P<code_cdhash>[0-9a-f]{40}) team_id=(?P<team_id>\S+) signing_identifier=(?P<signing_identifier>\S+) flags=(?P<flags>\S+)$",
            "commit": r"^coordinator_gateway_source_commit=(?P<source_commit>[0-9a-f]{40})$",
            "coordinator": r"^coordinator sha256=(?P<coordinator_sha256>[0-9a-f]{64})$",
            "coordinator_cli": r"^coordinator-cli sha256=(?P<coordinator_cli_sha256>[0-9a-f]{64})$",
            "gateway": r"^gateway sha256=(?P<gateway_sha256>[0-9a-f]{64})$",
            "client": r"^relay-blind-client sha256=(?P<client_sha256>[0-9a-f]{64})$",
            "coordinator_config": r"^coordinator\.yaml sha256=(?P<coordinator_config_sha256>[0-9a-f]{64})$",
            "gateway_config": r"^gateway\.yaml sha256=(?P<gateway_config_sha256>[0-9a-f]{64})$",
            "provider_config": r"^provider privacy config sha256=(?P<provider_config_sha256>[0-9a-f]{64})$",
            "approved": r"^(?P<approved_source>approved_code_identities from signed pearl-release\.json \(step-00b\))$",
        }
        lines = text.splitlines()
        if len(lines) != len(patterns):
            fail(f"binding.txt must hold exactly {len(patterns)} lines")
        values: dict[str, str] = {}
        for line in lines:
            matched = [re.fullmatch(pattern, line) for pattern in patterns.values()]
            hits = [match for match in matched if match is not None]
            if len(hits) != 1:
                fail(f"binding.txt has an unexpected line: {line[:40]!r}")
            for key, value in hits[0].groupdict().items():
                if key in values:
                    fail(f"binding.txt repeats {key}")
                values[key] = value
        return values

    def disclosure(self) -> str:
        risks = PRIVACY_RESIDUAL_RISKS_V2 if self.profile is PROFILE_V2 else PRIVACY_RESIDUAL_RISKS
        return privacy_disclosure(self.identity("privacy")["relay_blind_fingerprint"], risks)

    def disclosure_json(self, path: str, minimum_posture: int = 1) -> list[str]:
        errors: list[str] = []
        doc = self.b.json_object(path)
        expected_keys = {"chat_events", "pass", "posture_verified_at_unix", "response_headers_exact", "stderr_block_exact", "usage_privacy_exact"}
        expect(set(doc) == expected_keys, errors, f"{path} must carry exactly {sorted(expected_keys)}")
        for key in ("pass", "response_headers_exact", "stderr_block_exact", "usage_privacy_exact"):
            expect(doc.get(key) is True, errors, f"{path}.{key} must be true")
        events = doc.get("chat_events")
        expect(isinstance(events, int) and not isinstance(events, bool) and events >= 1, errors, f"{path}.chat_events must be >= 1")
        posture = doc.get("posture_verified_at_unix")
        expect(
            isinstance(posture, int) and not isinstance(posture, bool) and posture >= minimum_posture,
            errors,
            f"{path}.posture_verified_at_unix must be a coordinator posture time at or after provider start",
        )
        return errors

    def client_ok(self, prefix: str, block: str) -> list[str]:
        errors: list[str] = []
        meta = self.b.fields(f"{prefix}.meta")
        expect(meta.get("exit") == "0", errors, f"{prefix}.meta exit must be 0")
        expect(meta.get("stdout_bytes", "0").isdigit() and int(meta["stdout_bytes"]) > 0, errors, f"{prefix}.meta stdout_bytes must be > 0")
        expect(self.b.text(f"{prefix}.stderr") == block, errors, f"{prefix}.stderr must be exactly the expected disclosure")
        return errors

    def client_refused(self, prefix: str, *, stderr_suffix: str | None = None, stderr_contains: str | None = None) -> list[str]:
        errors: list[str] = []
        meta = self.b.fields(f"{prefix}.meta")
        expect(meta.get("exit") not in (None, "0"), errors, f"{prefix}.meta exit must be non-zero")
        expect(meta.get("stdout_bytes") == "0", errors, f"{prefix}.meta stdout_bytes must be 0")
        stderr = self.b.text(f"{prefix}.stderr")
        expect(stderr.startswith("relay-blind-client: "), errors, f"{prefix}.stderr must be a relay-blind-client error")
        if stderr_suffix is not None:
            expect(stderr.rstrip("\n").endswith(stderr_suffix), errors, f"{prefix}.stderr must end with {stderr_suffix!r}")
        if stderr_contains is not None:
            expect(stderr_contains in stderr, errors, f"{prefix}.stderr must contain {stderr_contains!r}")
        return errors

    def code_record(self, path: str) -> tuple[list[dict[str, Any]], dict[str, str]]:
        objects: list[dict[str, Any]] = []
        fields: dict[str, str] = {}
        for line in self.b.lines(path):
            if line.startswith("{"):
                value = parse_json(line, path)
                if not isinstance(value, dict):
                    fail(f"{path} JSON line must be an object")
                objects.append(value)
            else:
                for key, value in parse_fields(line, path).items():
                    if key in fields:
                        fail(f"{path}: repeated field {key!r}")
                    fields[key] = value
        return objects, fields

    def proxy_code(self, path: str, route: str, code: str, *, dispatches: str | None = "0") -> list[str]:
        errors: list[str] = []
        objects, fields = self.code_record(path)
        verdicts = [item for item in objects if "expected" in item]
        expect(len(verdicts) == 1, errors, f"{path} must hold one proxy-code verdict")
        if verdicts:
            verdict = verdicts[0]
            expect(verdict.get("pass") is True, errors, f"{path} verdict must pass")
            expect(verdict.get("expected") == code and verdict.get("observed") == code, errors, f"{path} must observe {code}")
            expect(verdict.get("path") == route, errors, f"{path} must be on {route}")
            status = verdict.get("status")
            expect(isinstance(status, int) and 400 <= status < 600, errors, f"{path} status must be an HTTP error")
        if dispatches is not None:
            expect(fields.get("dispatches_since") == dispatches, errors, f"{path} dispatches_since must be {dispatches}")
        return errors

    def hardening_refusal(self, directory: str, *, exits: tuple[str, ...] = ("78",)) -> dict[str, Any]:
        result = self.b.fields(f"{directory}/result.txt")
        errors: list[str] = []
        expect(result.get("exit") in exits, errors, f"{directory} exit must be one of {exits}")
        expect(result.get("blackhole_connections") == "0", errors, f"{directory} must make zero network connections")
        expect(result.get("listener_19329") == "0", errors, f"{directory} must open no listener")
        expect(self.b.text(f"{directory}/stdout.txt") == "", errors, f"{directory} stdout must be empty")
        stderr = self.b.text(f"{directory}/stderr.txt")
        match = re.fullmatch(r"FATAL privacy_class_hardening_failed reasons=([a-z0-9_,]+)\n", stderr)
        reasons = set(match.group(1).split(",")) if match else set()
        return {"errors": errors, "reasons": reasons, "stderr": stderr, "fatal": match is not None}

    def sweep_clean(self, path: str, classes: frozenset[str] | set[str], *, minimum_files: int = 1) -> list[str]:
        errors: list[str] = []
        doc = self.b.json_object(path)
        expect(set(doc) == {"match_count", "matches", "needle_classes", "roots"}, errors, f"{path} keys must be the sweep report keys")
        expect(doc.get("match_count") == 0 and doc.get("matches") == [], errors, f"{path} must have zero matches")
        expect(doc.get("needle_classes") == sorted(classes), errors, f"{path} must sweep exactly {sorted(classes)}")
        roots = doc.get("roots")
        expect(isinstance(roots, list) and bool(roots), errors, f"{path} must name sweep roots")
        scanned = 0
        for root in roots if isinstance(roots, list) else []:
            expect(isinstance(root, dict) and root.get("present") is True, errors, f"{path} every root must be present")
            if isinstance(root, dict):
                expect(root.get("unreadable", 0) == 0, errors, f"{path} root {root.get('root')!r} has unreadable files")
                count = root.get("files_scanned")
                if isinstance(count, int) and not isinstance(count, bool):
                    scanned += count
        expect(scanned >= minimum_files, errors, f"{path} must scan at least {minimum_files} file(s)")
        return errors

    # -- step-01

    def p_bind_release(self, errors: list[str]) -> None:
        values = self.binding()
        tag, version = values["release_tag"], values["binary_version"]
        commit = values["source_commit"]
        team, ident, cdhash = values["team_id"], values["signing_identifier"], values["code_cdhash"]
        expect(RELEASE_TAG_RE.fullmatch(tag) is not None and tag == f"v{version}", errors, "release_tag must be v<binary_version>")
        expect(values["compatibility_set_id"] == f"{REPOSITORY}:{tag}@{commit}", errors, "compatibility_set_id must bind the release tag to the source commit")
        expect("runtime" in values["flags"].split(","), errors, "binary must be hardened-runtime")
        expect(TEAM_ID_RE.fullmatch(team) is not None, errors, "team_id has invalid format")
        expect(SIGNING_IDENTIFIER_RE.fullmatch(ident) is not None, errors, "signing_identifier has invalid format")
        dvvv = self.b.text("step-01-bind-signed-release/codesign-dvvv.txt").splitlines()
        expect(f"Identifier={ident}" in dvvv, errors, "codesign Identifier must match")
        expect(f"TeamIdentifier={team}" in dvvv, errors, "codesign TeamIdentifier must match")
        expect(f"CDHash={cdhash}" in dvvv, errors, "codesign CDHash must match")
        expect(any(line.startswith("CodeDirectory ") and "(runtime)" in line for line in dvvv), errors, "codesign flags must be runtime")
        expect(any(line.startswith("Authority=Developer ID Application: ") and line.endswith(f"({team})") for line in dvvv), errors, "binary must be Developer ID signed by the team")
        verify = self.b.text("step-01-bind-signed-release/codesign-verify.txt")
        expect(": valid on disk\n" in verify and ": satisfies its Designated Requirement\n" in verify, errors, "codesign --verify --strict must pass")
        expect("source=Notarized Developer ID\n" in self.b.text("step-01-bind-signed-release/spctl.txt"), errors, "binary must be notarized")
        entitlements = self.b.text("step-01-bind-signed-release/entitlements.xml")
        for entitlement in REFUSED_ENTITLEMENTS:
            expect(entitlement not in entitlements, errors, f"binary carries refused entitlement {entitlement}")
        # Signed release metadata (step-00b) and install (step-00c).
        expect(self.b.text("step-00b-verify-candidate/pearl-release-signature.txt") == "Verified OK\n", errors, "pearl-release.json signature must verify")
        checks = self.b.lines("step-00b-verify-candidate/checksums-verify.txt")
        expect(bool(checks) and all(line.endswith(": OK") for line in checks), errors, "every release checksum must verify")
        for member in (f"macprovider-cli-{tag}-darwin-arm64.tar.gz", "pearl-release.json", "pearl-release.json.sig"):
            expect(f"{member}: OK" in checks, errors, f"release checksum for {member} must verify")
        expect(self.b.text("step-00b-verify-candidate/compatibility-set-id.txt") == values["compatibility_set_id"] + "\n", errors, "compatibility set id must match binding")
        identity = self.b.json_object("step-00b-verify-candidate/provider-code-identity.json")
        expect(identity.get("binary_sha256") == values["binary_sha256"], errors, "signed provider_code_identity.binary_sha256 must match")
        expect(identity.get("binary_version") == version, errors, "signed provider_code_identity.binary_version must match")
        expect(identity.get("team_id") == team and identity.get("signing_identifier") == ident, errors, "signed provider_code_identity team/identifier must match")
        expect(identity.get("slices") == [{"arch": "arm64", "code_cdhash": cdhash}], errors, "signed provider_code_identity cdhash must match")
        expect(identity.get("asset") == f"macprovider-cli-{tag}-darwin-arm64.tar.gz", errors, "signed provider_code_identity asset must be the release tarball")
        approved = self.b.text("step-00b-verify-candidate/approved-code-identities.yaml")
        for line in (f"- team_id: {team}", f"  signing_identifier: {ident}", f"  code_cdhash: {cdhash}", f'  binary_version: "{version}"'):
            expect(line in approved.splitlines(), errors, f"approved_code_identities must contain {line.strip()!r}")
        expect(self.b.text("step-00c-install-cli/binary-sha256.txt") == values["binary_sha256"] + "\n", errors, "installed binary sha256 must match")
        expect(self.b.text("step-00c-install-cli/version.txt") == version + "\n", errors, "installed binary version must match")
        # Isolated stack identities are the same release.
        for instance in ("privacy", "plain"):
            doc = self.identity(instance)
            expect(doc.get("code_cdhash") == cdhash and doc.get("team_id") == team and doc.get("binary_version") == version, errors, f"identity-{instance} must be the release binary")
            expect(doc.get("se_key_backend") == "file", errors, f"identity-{instance} must use the journey-private file key")
            import_record = self.b.json_object(f"step-01b-isolated-stack/credentials-import-{instance}.txt")
            expect(import_record.get("status") == "ok", errors, f"credentials import {instance} must succeed")
        expect(self.b.text("step-01b-isolated-stack/coordinator-validate.txt") == "config: ok\n", errors, "isolated coordinator config must validate")

    # -- step-02

    def p_privacy_start(self, errors: list[str]) -> None:
        timing = self.b.fields("step-02-privacy-mode-start/timing.txt")
        start, ready = int(timing["provider_start_unix"]), int(timing["privacy_records_ready_unix"])
        expect(start <= ready, errors, "privacy records must be ready after provider start")
        expect(self.b.text("step-02-privacy-mode-start/posture-rejections.txt") == "0\n", errors, "posture must never be rejected")
        errors.extend(self.client_ok("step-02-privacy-mode-start/posture-probe", self.disclosure()))

    def p_posture_verified(self, errors: list[str]) -> None:
        timing = self.b.fields("step-02-privacy-mode-start/timing.txt")
        errors.extend(self.disclosure_json("step-02-privacy-mode-start/probe-disclosure.json", int(timing["provider_start_unix"])))
        expect(self.b.text("step-02-privacy-mode-start/posture-rejections.txt") == "0\n", errors, "posture must never be rejected")

    def p_key_memory_only(self, errors: list[str]) -> None:
        errors.extend(self.sweep_clean("step-02-privacy-mode-start/privacy-key-on-disk-sweep.json", {"privacy_record_value"}))
        doc = self.b.json_object("step-02-privacy-mode-start/privacy-key-on-disk-sweep.json")
        roots = [root.get("root", "") for root in doc.get("roots", []) if isinstance(root, dict)]
        expect(any(root.endswith("/state/privacy") for root in roots), errors, "key sweep must cover the privacy state directory")
        expect(self.b.text("step-02-privacy-mode-start/unexpected-state-files.txt") == "", errors, "serve must add no unexpected state files")
        rows = self.b.lines("step-02-privacy-mode-start/key-records.txt")
        expect(bool(rows), errors, "privacy key records must be advertised")
        for row in rows:
            parts = row.split("|")
            expect(len(parts) == 6 and parts[1] == "privacy", errors, "privacy provider must advertise only privacy key records")
            if len(parts) == 6:
                expect(parts[4].isdigit() and 0 < int(parts[4]) <= 3600, errors, "privacy key record lifetime must be at most 3600s")

    # -- step-03

    def p_debugger(self, errors: list[str]) -> None:
        directory = "step-03-debugger-attach-refused"
        summary = self.b.fields(f"{directory}/summary.txt")
        for key in ("lldb_user_exit", "lldb_root_exit", "dtrace_root_exit"):
            expect(summary.get(key) not in (None, "0"), errors, f"{key} must be non-zero")
        expect(summary.get("attached") == "0", errors, "no debugger may attach")
        for name in ("lldb-user.txt", "lldb-root.txt"):
            text = self.b.text(f"{directory}/{name}")
            expect("error: attach failed" in text, errors, f"{name} must show a refused attach")
            expect(re.search(r"Process [0-9]+ (stopped|detached)", text) is None, errors, f"{name} must not show an attach")
        expect("failed to grab pid" in self.b.text(f"{directory}/dtrace-root.txt"), errors, "dtrace pid attach must be refused")
        control = self.b.text(f"{directory}/lldb-root-control.txt")
        expect("control_attach=ok exit=0" in control and re.search(r"Process [0-9]+ stopped", control) is not None, errors, "root lldb must attach to the unhardened control")
        errors.extend(self.client_ok(f"{directory}/eligible-after", self.disclosure()))

    # -- step-04

    def p_core_dumps(self, errors: list[str]) -> None:
        rlimit = self.b.lines("step-04-core-dump-and-env-refused/rlimit-core.txt")
        expect(rlimit == ["launch_shell_ulimit_c=unlimited (start_provider)", "posture_accepted_with_core_dumps_disabled=1"], errors, "provider must be launched with an unlimited core limit")
        # SPEC-049-R006: a posture is accepted only with core_dumps_disabled=true.
        errors.extend(self.run("posture_verified"))
        crash = self.b.fields("step-09-redaction-sweep/forced-crash.txt")
        expect(crash.get("core_file") == "none", errors, "the forced crash must write no core file")
        expect(crash.get("crashed_pid", "").isdigit(), errors, "the forced crash must name the provider pid")
        summary = self.b.json_object("step-09-redaction-sweep/crash-report-summary.json")
        expect((summary.get("exception") or {}).get("signal") == "SIGSEGV", errors, "the provider must have crashed with SIGSEGV")
        expect((summary.get("header") or {}).get("app_name") == "macprovider-cli", errors, "the crash report must be the provider's")
        system = self.b.json_object("step-09-redaction-sweep/sweep-system.json")
        cores = [root for root in system.get("roots", []) if isinstance(root, dict) and root.get("root") == "/cores"]
        expect(len(cores) == 1 and cores[0].get("present") is True and cores[0].get("files_scanned") == 0, errors, "/cores must hold no file newer than the journey start")

    def p_diag_env(self, errors: list[str]) -> None:
        for variable in DIAGNOSTIC_ENV_VARS:
            refusal = self.hardening_refusal(f"step-04-core-dump-and-env-refused/env-{variable}")
            errors.extend(refusal["errors"])
            expect(refusal["fatal"] and {"diagnostic_env", f"env_{variable.lower()}"} <= refusal["reasons"], errors, f"{variable} must be refused with its bounded reason")

    def p_config_refusals(self, errors: list[str]) -> None:
        base = "step-04-core-dump-and-env-refused"
        for case, reason in (("kv-disk-tier", "kv_disk_tier_enabled"), ("loopback-runtime", "loopback_runtime")):
            refusal = self.hardening_refusal(f"{base}/{case}")
            errors.extend(refusal["errors"])
            expect(refusal["fatal"] and reason in refusal["reasons"], errors, f"{case} must be refused with {reason}")
        refusal = self.hardening_refusal(f"{base}/relay-blind-disabled", exits=("1",))
        errors.extend(refusal["errors"])
        expect(
            refusal["stderr"] == "Error: Invalid privacy_class_beta=true; expected relay_blind_enabled true\n",
            errors,
            "relay-blind disabled must be refused at config validation",
        )

    def p_dyld(self, errors: list[str]) -> None:
        directory = "step-04-core-dump-and-env-refused/env-dyld"
        expect(self.b.fields(f"{directory}/result.txt").get("exit") == "0", errors, "DYLD_* run must exit 0 (inert)")
        expect(self.b.text(f"{directory}/stdout.txt") == self.binding()["binary_version"] + "\n", errors, "DYLD_* run must print only the version")
        expect(self.b.text(f"{directory}/stderr.txt") == "", errors, "dyld must emit no output")

    # -- step-05

    def p_unsigned(self, errors: list[str]) -> None:
        base = "step-05-unsigned-build-refused"
        adhoc = self.hardening_refusal(f"{base}/resigned-adhoc")
        errors.extend(adhoc["errors"])
        expect(adhoc["fatal"] and "team_id_missing" in adhoc["reasons"], errors, "re-signed release must be refused (team_id_missing)")
        debug = self.hardening_refusal(f"{base}/local-debug-build")
        errors.extend(debug["errors"])
        expect(debug["fatal"] and {"get_task_allow", "team_id_missing"} <= debug["reasons"], errors, "local debug build must be refused")
        unsigned = self.hardening_refusal(f"{base}/unsigned", exits=("137", "9"))
        errors.extend(unsigned["errors"])
        expect("Killed: 9" in unsigned["stderr"], errors, "unsigned release must be killed by the kernel")
        codesign = self.b.text(f"{base}/adhoc-codesign.txt").splitlines()
        release_cdhash = self.binding()["code_cdhash"]
        expect("Signature=adhoc" in codesign and "TeamIdentifier=not set" in codesign, errors, "re-signed binary must be ad hoc with no team")
        expect(f"CDHash={release_cdhash}" not in codesign, errors, "re-signed binary must not keep the release cdhash")
        expect(re.fullmatch(r"source_tarball_sha256=[0-9a-f]{64}\n", self.b.text(f"{base}/debug-build.txt")) is not None, errors, "debug build must record its source tarball")

    # -- step-06

    def p_sip_off(self, errors: list[str]) -> None:
        base = "step-06-sip-off-refused"
        expect(self.b.text(f"{base}/sip.txt") == "System Integrity Protection status: disabled.\n", errors, "lab host SIP must be disabled")
        host = re.search(r"^hw\.model: (\S+)$", self.b.text(f"{base}/host.txt"), re.M)
        expect(host is not None, errors, "lab host model must be recorded")
        if host is not None:
            same_hardware = host.group(1) == self.binding()["hardware_model"]
            if self.profile is PROFILE_V2:
                expect(same_hardware, errors, "v2 SIP-off host must be the designated Studio hardware")
                if same_hardware:
                    self.v2_same_studio_sip_off(base, host.group(1), errors)
            else:
                expect(not same_hardware, errors, "SIP-off lab host must be a different Mac")
        expect(self.b.fields(f"{base}/result.txt") == {"exit": "78", "conns_bytes": "0"}, errors, "SIP-off run must exit 78 with zero connection bytes")
        expect(self.b.text(f"{base}/conns.txt") == "", errors, "SIP-off run must make no connection")
        stderr = re.fullmatch(r"FATAL privacy_class_hardening_failed reasons=([a-z0-9_,]+)\n", self.b.text(f"{base}/stderr.txt"))
        expect(stderr is not None and "sip_disabled" in stderr.group(1).split(","), errors, "SIP-off run must be refused with sip_disabled")

    def v2_same_studio_sip_off(self, base: str, hardware_model: str, errors: list[str]) -> None:
        restored = self.b.json_object(f"{base}/restored-validation.json")
        expected_restored_keys = {
            "schema",
            "step_id",
            "physical_pass_claimed",
            "manual_step06_ready_for_import",
            "packet_sha256",
            "offline_packet_public_projection",
            "raw_artifact_sha256",
            "restored_host",
            "known_network_observation_limit",
        }
        expect(set(restored) == expected_restored_keys, errors, "v2 same-Studio SIP proof must be the closed restored-validation schema")
        expect(restored.get("schema") == "macprovider.privacy-lab-v2.step06-restored-validation.v1", errors, "v2 same-Studio SIP proof must be the Step06 restored-validation schema")
        expect(restored.get("step_id") == "step-06-sip-off-refused", errors, "v2 same-Studio SIP proof must bind step-06")
        expect(restored.get("physical_pass_claimed") is False, errors, "v2 same-Studio restored proof must not claim physical PASS")
        expect(restored.get("manual_step06_ready_for_import") is True, errors, "v2 same-Studio restored proof must be ready for import")
        expect(isinstance(restored.get("packet_sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", restored["packet_sha256"]) is not None, errors, "v2 same-Studio restored proof must bind the offline packet digest")
        projection = restored.get("offline_packet_public_projection")
        self.v2_same_studio_public_projection(projection, errors)

        raw_hashes = restored.get("raw_artifact_sha256")
        expected_raw = {"sip.txt", "host.txt", "stderr.txt", "conns.txt", "connection-observation.json", "result.txt"}
        expect(isinstance(raw_hashes, dict) and set(raw_hashes) == expected_raw, errors, "v2 same-Studio restored proof must bind every Step06 raw artifact hash")
        if isinstance(raw_hashes, dict):
            for name in sorted(expected_raw):
                digest = raw_hashes.get(name)
                expect(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None, errors, f"v2 same-Studio restored proof hash for {name} must be SHA-256")
                if isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest):
                    expect(digest == self.b.sha256(f"{base}/{name}"), errors, f"v2 same-Studio restored proof hash for {name} must match the reviewed artifact")

        restored_host = restored.get("restored_host")
        expect(isinstance(restored_host, dict) and set(restored_host) == {"local_hostname", "hardware_model", "sip_status"}, errors, "v2 same-Studio restored host must be closed")
        if isinstance(restored_host, dict):
            expect(restored_host.get("hardware_model") == hardware_model, errors, "v2 same-Studio restored host must match the SIP-disabled host hardware")
            expect(restored_host.get("sip_status") == "System Integrity Protection status: enabled.", errors, "v2 same-Studio restored host must show SIP restored before import")
            expect(isinstance(restored_host.get("local_hostname"), str) and bool(restored_host["local_hostname"]), errors, "v2 same-Studio restored host must name the prepared Studio host")
            host_text = self.b.text(f"{base}/host.txt")
            expect(f"LocalHostName: {restored_host.get('local_hostname')}\n" in host_text, errors, "v2 same-Studio SIP-disabled host must match the restored host name")
            if isinstance(projection, dict):
                prepared_host = projection.get("prepared_host")
                if isinstance(prepared_host, dict):
                    expect(prepared_host.get("local_hostname") == restored_host.get("local_hostname"), errors, "v2 same-Studio prepared host must match the restored host name")
                    expect(prepared_host.get("hardware_model") == restored_host.get("hardware_model"), errors, "v2 same-Studio prepared host must match the restored hardware")

        observation = self.b.json_object(f"{base}/connection-observation.json")
        expected_observation_keys = {
            "schema",
            "listener",
            "accepted_connections",
            "received_bytes",
            "window_started_unix",
            "window_ended_unix",
            "known_limit",
        }
        expect(set(observation) == expected_observation_keys, errors, "v2 same-Studio connection observation must be closed")
        expect(observation.get("schema") == "macprovider.privacy-lab-v2.step06-connection-observation.v1", errors, "v2 same-Studio connection observation schema must match the helper")
        expect(step06_loopback_listener(observation.get("listener")), errors, "v2 same-Studio connection observation must bind a non-live loopback listener")
        expect(all(type(observation.get(key)) is int and observation[key] == 0 for key in ("accepted_connections", "received_bytes")), errors, "v2 same-Studio helper-owned listener must accept zero connections and zero bytes as integer counts")
        started = observation.get("window_started_unix")
        ended = observation.get("window_ended_unix")
        expect(isinstance(started, int) and not isinstance(started, bool) and isinstance(ended, int) and not isinstance(ended, bool) and started > 0 and ended >= started, errors, "v2 same-Studio connection observation must bind a valid run window")
        expect(observation.get("known_limit") == "helper-owned exact loopback listener during provider run window; not a global packet capture", errors, "v2 same-Studio connection observation must disclose its helper-owned listener limit")
        if isinstance(projection, dict):
            expect(projection.get("coordinator_listener") == observation.get("listener"), errors, "v2 same-Studio projected listener must match the observed listener")
        limit = restored.get("known_network_observation_limit")
        expect(isinstance(limit, str) and "helper-owned loopback listener accepted zero connections" in limit and "not a global packet capture" in limit, errors, "v2 same-Studio restored proof must disclose the network observation limit")

    def v2_same_studio_public_projection(self, projection: Any, errors: list[str]) -> None:
        values = self.binding()
        if not isinstance(projection, dict) or set(projection) != {
            "schema",
            "step_id",
            "candidate",
            "provider_config_sha256",
            "binding_file_sha256",
            "prepared_host",
            "coordinator_listener",
        }:
            errors.append("v2 same-Studio restored proof must include the closed public offline-packet projection")
            return
        expect(projection.get("schema") == "macprovider.privacy-lab-v2.step06-offline-packet-public-projection.v1", errors, "v2 same-Studio public projection schema must match")
        expect(projection.get("step_id") == "step-06-sip-off-refused", errors, "v2 same-Studio public projection must bind step-06")
        candidate = projection.get("candidate")
        if not isinstance(candidate, dict) or set(candidate) != {"binary_sha256", "team_id", "signing_identifier", "cdhash"}:
            errors.append("v2 same-Studio public projection candidate binding must be closed")
        else:
            expect(candidate.get("binary_sha256") == values["binary_sha256"], errors, "v2 same-Studio public projection must bind the tested candidate bytes")
            expect(candidate.get("team_id") == values["team_id"], errors, "v2 same-Studio public projection must bind the tested team id")
            expect(candidate.get("signing_identifier") == values["signing_identifier"], errors, "v2 same-Studio public projection must bind the tested signing identifier")
            expect(candidate.get("cdhash") == values["code_cdhash"], errors, "v2 same-Studio public projection must bind the tested cdhash")
        expect(projection.get("provider_config_sha256") == values["provider_config_sha256"], errors, "v2 same-Studio public projection must bind the tested provider config")
        expect(projection.get("binding_file_sha256") == self.b.sha256("step-01-bind-signed-release/binding.txt"), errors, "v2 same-Studio public projection must bind the reviewed release binding file")
        prepared_host = projection.get("prepared_host")
        if not isinstance(prepared_host, dict) or set(prepared_host) != {"local_hostname", "hardware_model", "sip_status"}:
            errors.append("v2 same-Studio public projection prepared host must be closed")
        else:
            expect(prepared_host.get("hardware_model") == values["hardware_model"], errors, "v2 same-Studio public projection must bind the designated Studio hardware")
            expect(prepared_host.get("sip_status") == "System Integrity Protection status: enabled.", errors, "v2 same-Studio public projection must be prepared with SIP enabled")
            expect(isinstance(prepared_host.get("local_hostname"), str) and bool(prepared_host["local_hostname"]), errors, "v2 same-Studio public projection must bind the prepared host name")
        listener = projection.get("coordinator_listener")
        expect(step06_loopback_listener(listener), errors, "v2 same-Studio public projection must bind a non-live loopback listener")

    # -- step-07 / step-08

    def p_stream(self, errors: list[str]) -> None:
        errors.extend(self.canary("step-07-canary-stream", "stream"))

    def p_nonstream(self, errors: list[str]) -> None:
        errors.extend(self.canary("step-08-canary-nonstream", "nonstream"))

    def canary(self, step: str, mode: str) -> list[str]:
        errors = self.client_ok(f"{step}/canary-{mode}", self.disclosure())
        meta = self.b.fields(f"{step}/canary-{mode}.meta")
        expect(meta.get("completion_canary_in_decrypted_output") in ("yes", "no"), errors, f"{step} must record the decrypted-output canary check")
        errors.extend(self.disclosure_json(f"{step}/disclosure.json"))
        return errors

    def p_disclosure_exact(self, errors: list[str]) -> None:
        block = self.disclosure()
        for prefix in (
            "step-02-privacy-mode-start/posture-probe",
            "step-03-debugger-attach-refused/eligible-after",
            "step-07-canary-stream/canary-stream",
            "step-08-canary-nonstream/canary-nonstream",
            "step-10-downgrade-negatives/replay-first",
            "step-11-stale-posture-and-quarantine/recovered-after-stale",
            "step-12-kill-switch/recovered",
            "step-13-enforce-canary/enforce-stream",
            "step-13-enforce-canary/enforce-nonstream",
        ):
            errors.extend(self.client_ok(prefix, block))
        for path in (
            "step-02-privacy-mode-start/probe-disclosure.json",
            "step-07-canary-stream/disclosure.json",
            "step-08-canary-nonstream/disclosure.json",
            "step-13-enforce-canary/disclosure-stream.json",
            "step-13-enforce-canary/disclosure-nonstream.json",
        ):
            errors.extend(self.disclosure_json(path))
        plain = self.identity("plain")["relay_blind_fingerprint"]
        plain_block = (
            f"relay-blind satisfied; identity fingerprint={plain}\n"
            "scope: request_content_hidden_from_relays; provider_reads_request; responses_visible_to_relays\n"
        ) + SETTLEMENT_DISCLOSURE
        for prefix in ("step-12-kill-switch/plain-relay-blind", "step-13-enforce-canary/enforce-plain-relay-blind"):
            errors.extend(self.client_ok(prefix, plain_block))

    # -- step-09

    def p_sweeps_clean(self, errors: list[str]) -> None:
        errors.extend(self.sweep_clean("step-09-redaction-sweep/sweep-journey.json", CANARY_NEEDLE_CLASSES, minimum_files=1000))
        errors.extend(self.sweep_clean("step-09-redaction-sweep/sweep-system.json", CANARY_NEEDLE_CLASSES, minimum_files=1))
        errors.extend(self.sweep_clean("step-13-enforce-canary/sweep-journey.json", CANARY_NEEDLE_CLASSES, minimum_files=1000))
        system = self.b.json_object("step-09-redaction-sweep/sweep-system.json")
        roots = {root.get("root") for root in system.get("roots", []) if isinstance(root, dict)}
        expect({"/cores", "/Library/Logs/DiagnosticReports", "<lab-home>/Library/Logs/DiagnosticReports"} <= roots, errors, "system sweep must cover crash-report and core directories")
        expect(self.b.text("step-09-redaction-sweep/sweep-journey.txt").startswith("sweep: ") and self.b.text("step-09-redaction-sweep/sweep-journey.txt").endswith(" 0 matches\n"), errors, "journey sweep summary must report 0 matches")
        expect(self.b.text("step-09-redaction-sweep/sweep-system.txt").endswith(" 0 matches\n"), errors, "system sweep summary must report 0 matches")

    def p_receipts(self, errors: list[str]) -> None:
        doc = self.b.json_object("step-09-redaction-sweep/receipts.json")
        attempts = doc.get("attempts")
        expect(isinstance(attempts, list) and len(attempts) >= 2, errors, "receipts must cover the dispatched privacy attempts")
        expect(doc.get("dispatched_privacy_attempts") == (len(attempts) if isinstance(attempts, list) else -1), errors, "every dispatched privacy attempt must be checked")
        expect(doc.get("failing") == [] and doc.get("pass") is True, errors, "no receipt attempt may fail")
        expect(doc.get("undispatched_privacy_verdicts") == 0, errors, "undispatched privacy attempts must have no verdict")
        expect(doc.get("x_macprovider_receipt_headers") == 0, errors, "no X-MacProvider-Receipt header may reach the buyer")
        expect(doc.get("other_receipt_telemetry_trace_hits") == {}, errors, "no other receipt, telemetry, or trace row may name a privacy request")
        true_fields = (
            "attempt_output_without_content",
            "audit_outbox_same_receipt",
            "closed",
            "facts_without_prompt_hash",
            "pass",
            "prompt_hash_is_envelope_digest",
            "receipt_present",
            "response_body_bytes_equal",
            "response_body_sha256_equals_captured_frames",
        )
        for index, attempt in enumerate(attempts if isinstance(attempts, list) else []):
            for key in true_fields:
                expect(attempt.get(key) is True, errors, f"receipt attempt {index}.{key} must be true")
            expect(attempt.get("verdict_rows") == 1, errors, f"receipt attempt {index} must have exactly one verdict")
            expect(attempt.get("receipt_version") == RB_PROFILE and attempt.get("receipt_profile") == RB_PROFILE, errors, f"receipt attempt {index} must be {RB_PROFILE}")
            expect(attempt.get("settlement_outcome") == RB_SETTLED, errors, f"receipt attempt {index} must settle {RB_SETTLED}")
        expect(self.b.text("step-09-redaction-sweep/artifact-dirs.txt") == "", errors, "no receipt, telemetry, trace, or cache directory may exist")

    # -- step-10

    def p_downgrade(self, errors: list[str]) -> None:
        base = "step-10-downgrade-negatives"
        chat, reserve = "/v1/chat/completions", "/v1/relay-blind/route-reservations"
        for case, route in (("strip-header", chat), ("inject-header", chat), ("plaintext-header", chat), ("pool-scoped", reserve), ("engine-select", reserve)):
            errors.extend(self.proxy_code(f"{base}/{case}.code.json", route, "privacy_class_downgrade_rejected"))
        for case in ("plaintext-header", "pool-scoped", "engine-select"):
            expect(self.b.text(f"{base}/{case}.status") == "400\n", errors, f"{case} must be HTTP 400")
        errors.extend(self.client_refused(f"{base}/strip-header", stderr_suffix="do not resubmit"))
        errors.extend(self.client_refused(f"{base}/inject-header"))
        errors.extend(self.proxy_code(f"{base}/replay.code.json", chat, "relay_blind_replay"))
        expect(self.b.text(f"{base}/replay.status") == "409\n", errors, "replay must be HTTP 409")
        errors.extend(self.client_ok(f"{base}/replay-first", self.disclosure()))
        objects, fields = self.code_record(f"{base}/wrong-key-record.code.json")
        expect(objects == [] and fields == {"dispatches_since": "0"}, errors, "wrong key record must send nothing")
        errors.extend(self.client_refused(f"{base}/wrong-key-record", stderr_contains="identity fingerprint mismatch"))

    def p_tamper_truncate(self, errors: list[str]) -> None:
        base = "step-10-downgrade-negatives"
        for case, reason in (("tampered", "privacy frame authentication failed"), ("truncated", "privacy response missing final frame")):
            objects, fields = self.code_record(f"{base}/{case}.code.json")
            mutated = [item for item in objects if set(item) == {"chat_events", "pass"}]
            expect(len(mutated) == 1 and mutated[0].get("pass") is True, errors, f"{case} must show the relay mutated the response")
            expect(fields.get("dispatches_since") == "1", errors, f"{case} must be one dispatched request")
            errors.extend(self.client_refused(f"{base}/{case}", stderr_suffix="do not resubmit", stderr_contains=reason))

    def p_no_failover(self, errors: list[str]) -> None:
        doc = self.b.json_object("step-10-downgrade-negatives/no-failover.json")
        by_provider = doc.get("privacy_reservations_by_provider")
        privacy = self.provider_id("privacy")
        expect(doc.get("pass") is True and isinstance(by_provider, dict) and list(by_provider) == [privacy], errors, "every privacy reservation must name the privacy provider")
        if isinstance(by_provider, dict):
            count = by_provider.get(privacy)
            expect(isinstance(count, int) and not isinstance(count, bool) and count >= 1, errors, "privacy reservations must exist")

    # -- step-11

    def status(self, path: str) -> dict[str, str]:
        values: dict[str, str] = {}
        for line in self.b.lines(path):
            key, _, value = line.partition("=")
            if key in values:
                fail(f"{path} repeats {key}")
            values[key] = value
        return values

    def p_stale(self, errors: list[str]) -> None:
        base = "step-11-stale-posture-and-quarantine"
        # The gate refuses a stale posture at reservation (unavailable) or, when
        # the posture ages out between reservation and consume, at chat.
        at_reservation = self.proxy_code(f"{base}/stale.code.json", "/v1/relay-blind/route-reservations", "privacy_class_unavailable", dispatches=None)
        at_chat = self.proxy_code(f"{base}/stale.code.json", "/v1/chat/completions", "privacy_class_posture_stale", dispatches=None)
        if at_reservation and at_chat:
            errors.extend(at_reservation)
        errors.extend(self.client_refused(f"{base}/stale"))
        expect(self.status(f"{base}/status-after-stale.txt").get("quarantine_count") == "0", errors, "stale posture must not quarantine")
        errors.extend(self.client_ok(f"{base}/recovered-after-stale", self.disclosure()))

    def p_quarantine_durable(self, errors: list[str]) -> None:
        base = "step-11-stale-posture-and-quarantine"
        privacy = self.provider_id("privacy")
        before = self.status(f"{base}/status-unapproved.txt")
        after = self.status(f"{base}/status-after-restart.txt")
        for label, status in (("unapproved", before), ("after restart", after)):
            expect(status.get("quarantine_count") == "1", errors, f"quarantine {label} must hold one provider")
            expect(status.get("quarantine.provider_id") == privacy, errors, f"quarantine {label} must name the privacy provider")
            expect(status.get("quarantine.reason") == "posture_unapproved_code_identity", errors, f"quarantine {label} must be posture_unapproved_code_identity")
        expect(
            before.get("quarantine.quarantined_at_unix") == after.get("quarantine.quarantined_at_unix") is not None,
            errors,
            "the same quarantine must survive the coordinator restart",
        )
        keys = self.b.lines(f"{base}/keys-after-quarantine.txt")
        expect(bool(keys) and all(row.split("|")[1:] == ["privacy", "1"] for row in keys), errors, "every privacy key record must be revoked")
        errors.extend(self.proxy_code(f"{base}/quarantined.code.json", "/v1/relay-blind/route-reservations", "privacy_class_unavailable", dispatches=None))
        errors.extend(self.client_refused(f"{base}/quarantined"))
        expect(self.status(f"{base}/unquarantine.txt").get("quarantine_count") == "0", errors, "operator unquarantine must clear the quarantine")
        errors.extend(self.client_ok(f"{base}/recovered-after-restart", self.disclosure()))

    # -- step-12

    def p_kill_switch(self, errors: list[str]) -> None:
        base = "step-12-kill-switch"
        disabled = self.status(f"{base}/disable.txt")
        expect(disabled.get("disabled") == "1" and bool(disabled.get("reason")), errors, "kill switch must be disabled with a reason")
        errors.extend(self.proxy_code(f"{base}/held.code.json", "/v1/chat/completions", "privacy_class_disabled", dispatches=None))
        errors.extend(self.client_refused(f"{base}/held", stderr_suffix="do not resubmit"))
        held = self.b.lines(f"{base}/held-reservation.txt")
        expect(bool(held) and all(row == "rejected|privacy_class_disabled" for row in held), errors, "held predispatch reservation must be rejected privacy_class_disabled")
        errors.extend(self.proxy_code(f"{base}/next.code.json", "/v1/relay-blind/route-reservations", "privacy_class_disabled", dispatches=None))
        errors.extend(self.client_refused(f"{base}/next"))
        enabled = self.status(f"{base}/enable.txt")
        expect(enabled.get("disabled") == "0", errors, "re-enable must clear the kill switch")
        expect(int(enabled.get("updated_at_unix", "0")) > int(disabled.get("updated_at_unix", "0")), errors, "re-enable must follow disable")
        errors.extend(self.client_ok(f"{base}/recovered", self.disclosure()))

    def p_unaffected(self, errors: list[str]) -> None:
        base = "step-12-kill-switch"
        meta = self.b.fields(f"{base}/plain-relay-blind.meta")
        expect(meta.get("exit") == "0" and int(meta.get("stdout_bytes", "0")) > 0, errors, "plain relay-blind must succeed while disabled")
        expect(self.b.text(f"{base}/plain-relay-blind.stderr").startswith("relay-blind satisfied; identity fingerprint="), errors, "plain relay-blind must be served")
        expect(self.b.text(f"{base}/plaintext.status") == "200\n", errors, "plaintext must succeed while disabled")

    # -- step-13

    def enforce_attempts(self) -> list[dict[str, Any]]:
        doc = self.b.json_object("step-13-enforce-canary/enforce.json")
        attempts = doc.get("attempts")
        if not isinstance(attempts, list) or not all(isinstance(item, dict) for item in attempts):
            fail("enforce.json attempts must be objects")
        privacy = sum(1 for item in attempts if item.get("privacy_class") is True)
        plain = sum(1 for item in attempts if item.get("privacy_class") is False)
        if (privacy, plain) != (2, 1) or len(attempts) != 3:
            fail("enforce canary must hold two privacy attempts and one plain relay-blind attempt")
        if (doc.get("expected_privacy"), doc.get("expected_plain"), doc.get("privacy_attempts"), doc.get("plain_attempts")) != (2, 1, 2, 1):
            fail("enforce.json attempt counts must match the canary plan")
        return attempts

    def p_enforce_config(self, errors: list[str]) -> None:
        config = self.b.lines("step-13-enforce-canary/coordinator-settlement-config.txt")
        expect("  verified_model_settlement_mode: enforce" in config, errors, "journey coordinator must be in settlement enforce")
        expect(f"  enforce_settlement_profile: {RB_PROFILE}" in config, errors, f"journey coordinator must enforce {RB_PROFILE}")
        for instance in ("privacy", "plain"):
            doc = self.b.json_object(f"step-13-enforce-canary/capability-{instance}.json")
            sessions = doc.get("sessions") or []
            expect(doc.get("provider_id") == self.provider_id(instance) and doc.get("expected_capability") is True and bool(sessions), errors, f"{instance} provider must advertise the settlement capability")
            expect(all(item.get("relay_blind_settlement_receipt_v1") is True for item in sessions), errors, f"{instance} provider sessions must advertise relay_blind_settlement_receipt_v1")

    def p_enforce_snapshot(self, errors: list[str]) -> None:
        for index, attempt in enumerate(self.enforce_attempts()):
            snapshot = attempt.get("snapshot") or {}
            expect(attempt.get("snapshots") == 1 and attempt.get("state") == "terminal", errors, f"attempt {index} must have one route snapshot")
            expect(snapshot.get("entrypoint") == RB_ENTRYPOINT and snapshot.get("basis") == RB_BASIS and snapshot.get("mode") == "enforce", errors, f"attempt {index} snapshot must be the relay-blind enforce entrypoint and basis")
            for key in ("prompt_hash_is_envelope_digest", "prompt_hash_is_sha256_of_proxied_envelope_bytes", "created_before_provider_validation", "decision_before_provider_validation"):
                expect(snapshot.get(key) is True, errors, f"attempt {index} snapshot.{key} must be true")

    def p_enforce_verdict(self, errors: list[str]) -> None:
        for index, attempt in enumerate(self.enforce_attempts()):
            verdict = attempt.get("verdict") or {}
            expect(attempt.get("verdicts") == 1, errors, f"attempt {index} must have one verdict")
            expect(verdict.get("outcome") == RB_SETTLED and verdict.get("closed") is True and verdict.get("result") == "valid", errors, f"attempt {index} verdict must be closed {RB_SETTLED}")
            expect(verdict.get("profile") == RB_PROFILE and verdict.get("version") == RB_PROFILE, errors, f"attempt {index} verdict must be {RB_PROFILE}")
            expect(verdict.get("binds_snapshot_digest") is True, errors, f"attempt {index} verdict must bind the snapshot digest")

    def p_enforce_credit(self, errors: list[str]) -> None:
        for index, attempt in enumerate(self.enforce_attempts()):
            money = attempt.get("money") or {}
            expect(attempt.get("payable_credits") == 1, errors, f"attempt {index} must have one payable credit")
            expect(money.get("credit_policy_mode") == "enforce", errors, f"attempt {index} credit must be under enforce")
            credits = money.get("provider_credits")
            expect(isinstance(credits, int) and not isinstance(credits, bool) and credits > 0, errors, f"attempt {index} provider credit must be positive")

    def p_enforce_debit(self, errors: list[str]) -> None:
        for index, attempt in enumerate(self.enforce_attempts()):
            money = attempt.get("money") or {}
            expect(attempt.get("gateway_reservations") == 1 and attempt.get("gateway_usage_rows") == 1, errors, f"attempt {index} must have one gateway reservation and usage row")
            expect(money.get("gateway_status") == "settled" and money.get("gateway_settlement_mode") == "enforce", errors, f"attempt {index} gateway reservation must settle under enforce")
            expect(money.get("gateway_internal_request_id_matches") is True, errors, f"attempt {index} gateway reservation must be the same request")
            prompt, completion = money.get("credited_prompt_tokens"), money.get("credited_completion_tokens")
            expect(money.get("debited_prompt_tokens") == prompt and money.get("debited_completion_tokens") == completion, errors, f"attempt {index} debit must equal the credited usage")
            if isinstance(prompt, int) and isinstance(completion, int):
                expect(money.get("debited_total_tokens") == prompt + completion == money.get("gateway_settled_tokens"), errors, f"attempt {index} settled tokens must equal the credited total")

    def p_counters(self, errors: list[str]) -> None:
        before = self.b.json_object("step-13-enforce-canary/counters-before.json")
        after = self.b.json_object("step-13-enforce-canary/counters-after.json")
        expect(set(before) == set(after) and any(key.endswith(":verified_verdicts") for key in after), errors, "counters must cover the verified-only consumers")
        delta = {key: after.get(key, 0) - before.get(key, 0) for key in sorted(set(before) | set(after))}
        expect(all(value == 0 for value in delta.values()), errors, "verified, referral, and reward counters must not move")
        recorded = self.b.json_object("step-13-enforce-canary/counters-delta.json")
        expect(recorded == {"delta": delta, "pass": True}, errors, "counters-delta.json must equal the recomputed delta")

    # -- step-14

    def p_no_capability(self, errors: list[str]) -> None:
        base = "step-14-no-capability-provider-excluded"
        old = self.b.json_object(f"{base}/identity-old.json")
        expect(old.get("binary_version") != self.binding()["binary_version"], errors, "excluded provider must be an older release")
        old_id = None
        for case in ("privacy", "plain"):
            doc = self.b.json_object(f"{base}/capability-old-{case}.json")
            old_id = old_id or doc.get("provider_id")
            sessions = doc.get("sessions") or []
            expect(doc.get("pass") is True and doc.get("expected_capability") is False and bool(sessions), errors, f"old {case} session must be observed")
            for session in sessions:
                expect(session.get("relay_blind_settlement_receipt_v1") is False, errors, f"old {case} session must lack the settlement capability")
                expect(session.get("routing_eligible") is True and session.get("hash_status") == "hash_verified" and session.get("receipt_key_pinned") is True, errors, f"old {case} session must otherwise be routable")
        expect(isinstance(old_id, str) and old_id not in (self.provider_id("privacy"), self.provider_id("plain")), errors, "old provider must be a distinct provider")
        # One old provider identity across both capability snapshots, its own
        # credential import, and the exclusion rows.
        ids = {self.b.json_object(f"{base}/capability-old-{case}.json").get("provider_id") for case in ("privacy", "plain")}
        ids.add(self.b.json_object(f"{base}/credentials-import-old.txt").get("provider_id"))
        expect(ids == {old_id}, errors, "every step-14 record must name the same old provider")
        errors.extend(self.proxy_code(f"{base}/old-privacy.code.json", "/v1/relay-blind/route-reservations", "privacy_class_unavailable", dispatches=None))
        errors.extend(self.proxy_code(f"{base}/old-relay-blind.code.json", "/v1/relay-blind/route-reservations", "relay_blind_provider_unsupported", dispatches=None))
        errors.extend(self.client_refused(f"{base}/old-privacy"))
        errors.extend(self.client_refused(f"{base}/old-relay-blind"))
        quota = self.b.fields(f"{base}/quota.txt")
        expect(quota.get("gateway_quota_reservations_before") == quota.get("after") is not None, errors, "no quota may be reserved before the typed unavailable error")
        excluded = self.b.json_object(f"{base}/excluded.json")
        tables = {"ledger_request_credits", "relay_blind_reservations", "settlement_attempt_outputs", "settlement_receipt_verdicts", "settlement_route_snapshots"}
        expect(excluded.get("provider_id") == old_id and excluded.get("pass") is True, errors, "exclusion check must name the old provider")
        expect(excluded.get("rows") == {table: 0 for table in tables}, errors, "no reservation, snapshot, verdict, output, or credit may name the old provider")
        expect(self.b.text(f"{base}/old-pearl-release-signature.txt") == "Verified OK\n", errors, "old release metadata must verify")

    # -- step-15

    def p_receipt_quarantine(self, errors: list[str]) -> None:
        base = "step-15-tampered-receipt-quarantined"
        cases_tsv: dict[str, tuple[str, str]] = {}
        for row in self.b.lines(f"{base}/cases.tsv"):
            name, request_id, reason_re = row.split("\t")
            cases_tsv[name] = (request_id, reason_re)
        expect(set(cases_tsv) == set(QUARANTINE_CASES), errors, f"cases.tsv must hold exactly {sorted(QUARANTINE_CASES)}")
        expect(all(request_id for request_id, _ in cases_tsv.values()), errors, "every case must name its dispatched request")
        expect(len({request_id for request_id, _ in cases_tsv.values()}) == len(cases_tsv), errors, "every case must be a distinct request")
        doc = self.b.json_object(f"{base}/quarantined.json")
        cases = {item.get("case"): item for item in doc.get("cases", []) if isinstance(item, dict)}
        expect(doc.get("pass") is True and set(cases) == set(QUARANTINE_CASES) and len(doc.get("cases", [])) == len(QUARANTINE_CASES), errors, "quarantined.json must cover every case once")
        for name, reason in QUARANTINE_CASES.items():
            case = cases.get(name) or {}
            verdicts = case.get("verdicts") or []
            expect(len(verdicts) == 1, errors, f"{name} must have one verdict")
            if len(verdicts) == 1:
                verdict = verdicts[0]
                expect(verdict.get("closed") == 1 and verdict.get("settlement_outcome") == "quarantined", errors, f"{name} must be closed quarantined")
                expect(verdict.get("reason") == reason, errors, f"{name} must be quarantined for {reason}")
                pattern = cases_tsv.get(name, ("", "^$"))[1]
                expect(re.search(pattern, verdict.get("reason") or "") is not None, errors, f"{name} reason must match cases.tsv")
                expect(verdict.get("receipt_result") == "invalid", errors, f"{name} receipt must be invalid")
            expect(case.get("payable_credits") == 0, errors, f"{name} must have zero payable credit")
            expect(case.get("relay_blind_snapshot") is True and case.get("internal_request_id_present") is True, errors, f"{name} must be a relay-blind snapshot request")
            gateway = case.get("gateway") or []
            refunded = len(gateway) == 1 and (
                gateway[0].get("status") == "refunded" or (gateway[0].get("status") == "settled" and gateway[0].get("settled_tokens") == 0)
            )
            expect(refunded and case.get("buyer_refunded") is True, errors, f"{name} buyer reservation must be refunded")
            expect(all(item.get("total_tokens") == 0 for item in case.get("gateway_usage") or []), errors, f"{name} must debit no usage")
        tamper = ((cases.get("fault-v04") or {}).get("verdicts") or [{}])[0]
        expect(tamper.get("receipt_version") == "4", errors, "v0.4 case must present a v0.4 receipt")
        expect(self.b.json_object(f"{base}/wsproxy-mutation.json") == {"encrypted_end_frames_corrupted": 1}, errors, "withheld case must corrupt exactly one encrypted end frame")
        errors.extend(self.client_refused(f"{base}/withheld-privacy", stderr_suffix="do not resubmit"))

    def p_isolated_fault_build(self, errors: list[str]) -> None:
        build = self.b.text("step-15-tampered-receipt-quarantined/fault-build.txt").splitlines()
        expect("Signature=adhoc" in build and "TeamIdentifier=not set" in build, errors, "fault injector must be an unreleased ad-hoc build")
        doc = self.b.json_object("step-15-tampered-receipt-quarantined/quarantined.json")
        for case in doc.get("cases", []):
            if isinstance(case, dict) and str(case.get("case", "")).startswith("fault-"):
                # The fault build's requests settled against the isolated
                # journey coordinator's relay-blind snapshot store.
                expect(case.get("relay_blind_snapshot") is True and bool(case.get("verdicts")), errors, f"{case.get('case')} must be recorded by the isolated coordinator")

    # -- step-16 / isolation

    def p_review(self, errors: list[str]) -> None:
        base = "step-16-redaction-review"
        # The sweep ran over every bundle file except the three step-16 wrote
        # after it (its own report, the private-path list, the observation draft).
        errors.extend(self.sweep_clean(f"{base}/evidence-sweep.json", REVIEW_NEEDLE_CLASSES, minimum_files=len([path for path in self.b.files if not path.startswith("primary/")]) - 3))
        listed = self.b.lines(f"{base}/files-with-private-paths.txt")
        expect(all(line.startswith("<lab-home>/journey-1839/evidence/") for line in listed), errors, "private-path list must itself be redacted")
        try:
            assert_bundle_redacted(self.b)
        except PrivacyEvidenceError as exc:
            errors.append(str(exc))

    def p_live_untouched(self, errors: list[str]) -> None:
        before = self.b.text("step-00a-isolation-preflight/live-before.txt")
        after = self.b.text("step-99-live-provider-untouched/live-after.txt")
        expect(before == after and before != "", errors, "live provider identity must be unchanged")
        expect(self.b.text("step-99-live-provider-untouched/diff.txt") == "", errors, "live provider diff must be empty")
        fields = parse_fields(before, "live-before.txt")
        expect(fields.get("launchctl_live_provider", "").isdigit() and fields.get("launchctl_live_provider") == fields.get("listener_8080_pid"), errors, "live provider pid and listener must be recorded")

    # -- primary data (post-hoc exports under primary/, see
    #    scripts/lab/privacy-class-beta/extract-primary-evidence.py)

    def results_times(self) -> list[tuple[str, int]]:
        rows = []
        for line in self.b.lines("results.tsv"):
            stamp, step = line.split("\t")[:2]
            rows.append((step, int(parse_datetime(stamp, "results.tsv").timestamp())))
        return rows

    def window(self, step: str) -> tuple[int, int]:
        """Inclusive [previous results row, own results row] in unix seconds."""
        rows = self.results_times()
        for index, (name, end) in enumerate(rows):
            if name == step:
                start = rows[index - 1][1] if index else end
                return start, end
        fail(f"results.tsv has no {step}")
        raise AssertionError("unreachable")

    def primary(self, relative: str) -> dict[str, Any]:
        doc = self.b.json_object(f"primary/{relative}")
        if doc.get("schema_version") != PRIMARY_SCHEMA:
            fail(f"primary/{relative} is not a {PRIMARY_SCHEMA} export")
        return doc

    def rows(self, database: str, table: str) -> list[dict[str, Any]]:
        doc = self.b.json_object(f"primary/db/{database}/{table}.json")
        rows = doc.get("rows")
        if doc.get("table") != table or not isinstance(rows, list) or doc.get("truncated") is not False:
            fail(f"primary/db/{database}/{table}.json must be a complete row export")
        if not all(isinstance(row, dict) for row in rows) or doc.get("row_count") != len(rows):
            fail(f"primary/db/{database}/{table}.json row_count must equal its rows")
        inventory = (self.primary("db/inventory.json").get("databases") or {}).get(database) or {}
        if inventory.get(table) != len(rows):
            fail(f"primary/db/{database}/{table}.json must export every row the inventory counts")
        return rows

    def reservations(self) -> list[dict[str, Any]]:
        return self.rows("relay-blind.db", "relay_blind_reservations")

    def snapshots(self) -> list[dict[str, Any]]:
        rows = self.rows("coordinator.db", "settlement_route_snapshots")
        if f"primary/db/coordinator.db.route-snapshots/settlement_route_snapshots.json" in self.b.files:
            known = {(row.get("request_id"), row.get("provider_id"), row.get("route_snapshot_digest")) for row in rows}
            for row in self.rows("coordinator.db.route-snapshots", "settlement_route_snapshots"):
                if (row.get("request_id"), row.get("provider_id"), row.get("route_snapshot_digest")) not in known:
                    rows.append(row)
        return rows

    def by_request(self, rows: list[dict[str, Any]], request_id: str) -> list[dict[str, Any]]:
        return [row for row in rows if row.get("request_id") == request_id]

    def proxy_events(self) -> list[dict[str, Any]]:
        events = self.primary("logs/proxy-events.json").get("events")
        if not isinstance(events, list):
            fail("primary proxy events must be a list")
        return [event for event in events if isinstance(event, dict)]

    def coordinator_events(self) -> list[dict[str, Any]]:
        events = self.primary("logs/coordinator-events.json").get("events")
        if not isinstance(events, list):
            fail("primary coordinator events must be a list")
        return [event for event in events if isinstance(event, dict)]

    def snapshot_checks(self, reservation: dict[str, Any], snapshot: dict[str, Any], errors: list[str], label: str) -> None:
        envelope_hex = b64url_hex(reservation.get("envelope_digest"))
        expect(snapshot.get("paid_entrypoint") == RB_ENTRYPOINT and snapshot.get("prompt_hash_basis") == RB_BASIS, errors, f"{label} snapshot must be the relay-blind entrypoint and envelope basis")
        expect(bool(envelope_hex) and snapshot.get("prompt_hash") == envelope_hex, errors, f"{label} snapshot prompt_hash must be the envelope digest")
        canonical = snapshot.get("route_snapshot_canonical_json")
        expect(
            isinstance(canonical, str) and hashlib.sha256(canonical.encode("utf-8")).hexdigest() == snapshot.get("route_snapshot_digest"),
            errors,
            f"{label} route_snapshot_digest must be the SHA-256 of its canonical JSON",
        )

    def p_primary_integrity(self, errors: list[str]) -> None:
        summary = self.primary("summary.json")
        expect(summary.get("log_utc_offset") == "-07:00", errors, "primary exports must declare the run log offset")
        expect(summary.get("warnings") == [], errors, "the primary extraction must finish without warnings")
        recorded = [str(item).split(":", 1)[0] for item in summary.get("not_recoverable") or []]
        expect(recorded == list(NOT_RECOVERABLE_ITEMS), errors, f"primary/summary.json must record exactly the not-recoverable items {list(NOT_RECOVERABLE_ITEMS)}")
        inventory = self.primary("db/inventory.json").get("databases") or {}
        for database in ("coordinator.db", "gateway.db", "relay-blind.db", "provider_connection_events.db"):
            expect(database in inventory, errors, f"primary inventory must cover {database}")
        raw = self.primary("sweep/raw-files.json")
        files = raw.get("files") or []
        expect(bool(files) and raw.get("total_needle_matches") == 0 and all(item.get("needle_matches") == 0 for item in files), errors, "the raw run data must hold zero needle matches")
        roots = {str(item.get("path", "")).split("/", 1)[0] for item in files}
        expect({"db", "logs", "evidence"} <= roots, errors, "the raw sweep must cover db, logs, and evidence")
        digests = self.primary("sweep/salted-needle-digests.json")
        forms: dict[str, dict[str, int]] = {}
        for item in digests.get("digests") or []:
            forms.setdefault(str(item.get("class")), {}).setdefault(str(item.get("form")), 0)
            forms[str(item.get("class"))][str(item.get("form"))] += 1
        expect(set(forms) == set(REVIEW_NEEDLE_CLASSES), errors, "salted digests must cover exactly the review needle classes")
        for klass, counts in forms.items():
            expect(
                set(counts) <= {"raw", "json", "utf16le"} and counts.get("raw", 0) >= 1 and counts.get("raw") == counts.get("utf16le"),
                errors,
                f"salted digests for {klass} must carry the raw and UTF-16LE form of every needle",
            )
        expect(re.fullmatch(r"[0-9a-f]{64}", str(digests.get("salt", ""))) is not None, errors, "salted digests must publish a 32-byte salt")

    def p_primary_canary_recheck(self, errors: list[str]) -> None:
        doc = self.primary("sweep/salted-needle-digests.json")
        salt = bytes.fromhex(str(doc.get("salt", "")))
        by_length: dict[int, set[str]] = {}
        for item in doc.get("digests") or []:
            length, digest = item.get("length"), item.get("sha256")
            if isinstance(length, int) and length > 0 and isinstance(digest, str):
                by_length.setdefault(length, set()).add(digest)
        expect(len(salt) == 32 and bool(by_length), errors, "salted needle digests are malformed")
        if errors:
            return
        for path, data in sorted(self.b.files.items()):
            if path == "primary/sweep/salted-needle-digests.json":
                continue
            for length, wanted in by_length.items():
                for start in range(0, len(data) - length + 1):
                    if hashlib.sha256(salt + data[start : start + length]).hexdigest() in wanted:
                        errors.append(f"{path} contains a swept needle")
                        return

    def p_primary_key_attestation(self, errors: list[str]) -> None:
        identity = self.identity("privacy")
        public = b64url_bytes(identity.get("relay_blind_identity_public_key"))
        values = self.binding()
        privacy = self.provider_id("privacy")
        start, end = self.window("step-02-privacy-mode-start")
        rows = [row for row in self.rows("relay-blind.db", "relay_blind_key_records") if row.get("provider_id") == privacy]
        privacy_rows = [row for row in rows if row.get("key_class") == "privacy"]
        expect(bool(privacy_rows), errors, "the privacy provider must have privacy key records")
        expect(any(start - 600 <= int(row.get("not_before_unix") or 0) <= end for row in privacy_rows), errors, "a privacy key must be minted by the step-02 start")
        expect(all(row.get("key_class") == "privacy" for row in rows), errors, "the privacy provider must advertise only privacy key records")
        for row in privacy_rows:
            label = f"key {row.get('kid')}"
            record = row.get("record_json")
            attestation = row.get("privacy_attestation_json")
            signature = row.get("privacy_attestation_signature")
            if not isinstance(record, dict) or not isinstance(attestation, dict) or not isinstance(signature, str):
                errors.append(f"{label} must export its key record, attestation, and signature")
                continue
            nb, exp = row.get("not_before_unix"), row.get("expires_at_unix")
            expect(isinstance(nb, int) and isinstance(exp, int) and 0 < exp - nb <= 3600, errors, f"{label} lifetime must be at most 3600s")
            expect(record.get("identity_fingerprint") == identity.get("relay_blind_fingerprint"), errors, f"{label} must name the pinned identity")
            expect(record.get("key_record_digest") == row.get("key_record_digest") == attestation.get("key_record_digest"), errors, f"{label} attestation must bind the key record digest")
            expect(record.get("not_before_unix") == nb == attestation.get("not_before_unix") and record.get("expires_at_unix") == exp == attestation.get("expires_at_unix"), errors, f"{label} attestation must bind the key window")
            expect(attestation.get("version") == "privacy-key-attestation-v1" and attestation.get("privacy_class") == PRIVACY_CLASS and attestation.get("assurance") == PRIVACY_ASSURANCE, errors, f"{label} attestation must be the beta class")
            expect(attestation.get("code_cdhash") == values["code_cdhash"] and attestation.get("binary_version") == values["binary_version"], errors, f"{label} attestation must name the release code identity")
            try:
                framing = attestation_framing(attestation)
                ok = public is not None and ed25519_verify(public, framing, b64url_bytes(signature) or b"")
            except (TypeError, ValueError, KeyError):
                ok = False
            expect(ok, errors, f"{label} attestation signature must verify under the pinned identity key")
            try:
                signed = key_record_signed_framing(record)
                digest_ok = base64.urlsafe_b64encode(hashlib.sha256(signed).digest()).rstrip(b"=").decode() == record.get("key_record_digest")
                record_ok = public is not None and ed25519_verify(public, signed, b64url_bytes(record.get("signature")) or b"")
            except (TypeError, ValueError, KeyError):
                digest_ok = record_ok = False
            expect(digest_ok, errors, f"{label} key_record_digest must be the SHA-256 of its signed framing")
            expect(record_ok, errors, f"{label} key record signature must verify under the pinned identity key")
            models = record.get("models")
            expect(
                isinstance(models, list) and bool(models) and len(set(map(str, models))) == len(models) and all(isinstance(item, str) and item.strip() == item and item for item in models),
                errors,
                f"{label} key record must name unique non-empty models",
            )
            expect(record.get("endpoint_families") == ["chat_completions"], errors, f"{label} key record scope must be chat completions")
            expect(record.get("alg") == "x25519-hkdf-sha256-a256gcm-v1" and record.get("signature_algorithm") == "ed25519", errors, f"{label} key record algorithms must be the SPEC-041 suite")
            size = record.get("max_encrypted_request_bytes")
            expect(isinstance(size, int) and not isinstance(size, bool) and 0 < size <= 16 << 20, errors, f"{label} key record request limit must be positive")
            kid = b64url_bytes(record.get("kid"))
            expect(kid is not None and len(kid) == 16 and record.get("kid") == row.get("kid"), errors, f"{label} key record kid must be the 16-byte row kid")

    def p_primary_posture(self, errors: list[str]) -> None:
        privacy = self.provider_id("privacy")
        timing = self.b.fields("step-02-privacy-mode-start/timing.txt")
        started = int(timing["provider_start_unix"])
        stale_start, stale_end = self.window("step-11-stale-posture-and-quarantine")
        for event in self.coordinator_events():
            message = str(event.get("message") or event.get("msg") or "")
            if event.get("provider_id") != privacy:
                continue
            if "privacy posture: response rejected" in message:
                errors.append("the coordinator rejected a privacy posture of the privacy provider")
            if "privacy posture: response timed out" in message:
                stamp = utc_unix(event.get("time_utc"))
                expect(stamp is not None and stale_start <= stamp <= stale_end + 60, errors, "posture timeouts may occur only around the step-11 freeze")
        start, end = self.window("step-02-privacy-mode-start")
        postures = [privacy_posture(event) for event in self.proxy_events() if start <= int(event.get("at_unix") or 0) <= end]
        expect(any(value is not None and value >= started for value in postures), errors, "a coordinator-verified posture must follow the step-02 provider start")

    def p_primary_posture_after_attach(self, errors: list[str]) -> None:
        start, end = self.window("step-03-debugger-attach-refused")
        postures = [privacy_posture(event) for event in self.proxy_events() if start <= int(event.get("at_unix") or 0) <= end]
        # SPEC-049-R006 accepts a posture only with p_traced=false and
        # cs_debugged=false; this one was verified after the attach attempts began.
        expect(any(value is not None and value > start for value in postures), errors, "a posture verified after the attach attempts began must exist")

    def p_primary_first_connect(self, errors: list[str]) -> None:
        privacy = self.provider_id("privacy")
        timing = self.b.fields("step-02-privacy-mode-start/timing.txt")
        started = int(timing["provider_start_unix"])
        start, end = self.window("step-02-privacy-mode-start")
        accepted = [
            utc_unix(event.get("time_utc"))
            for event in self.coordinator_events()
            if event.get("provider_id") == privacy and "auth_response accepted" in str(event.get("reason") or event.get("message") or "")
        ]
        in_step = [stamp for stamp in accepted if stamp is not None and start - 600 <= stamp <= end]
        expect(bool(in_step) and min(in_step) >= started, errors, "the privacy provider's first accepted session must follow its start")
        # The process's own unified log: its first network flow must follow the
        # process start. This bounds, but cannot prove, hardening-before-network
        # (no hardening-complete line exists; see primary/summary.json).
        crashed = self.b.fields("step-09-redaction-sweep/forced-crash.txt").get("crashed_pid", "")
        if not crashed.isdigit():
            fail("forced-crash.txt must name the privacy provider pid")
        unified = self.primary(f"logs/unified-provider-{crashed}.json")
        connects = [
            utc_unix(event.get("time_utc"))
            for event in unified.get("network_events") or []
            if "flow:start_connect" in str(event.get("message", ""))
        ]
        connects = [stamp for stamp in connects if stamp is not None]
        first_entry = utc_unix(unified.get("first_entry_utc"))
        expect(bool(connects) and first_entry is not None and min(connects) >= started and min(connects) >= first_entry, errors, "the privacy provider's first network flow must follow its process start")

    def p_primary_canary_completion(self, errors: list[str]) -> None:
        privacy = self.provider_id("privacy")
        start, _ = self.window("step-05-unsigned-build-refused")
        _, end = self.window("step-08-canary-nonstream")
        outputs = self.rows("coordinator.db", "settlement_attempt_outputs")
        for stream in (1, 0):
            matched = [
                row for row in self.reservations()
                if row.get("privacy_class") == 1 and row.get("provider_id") == privacy and row.get("stream") == stream
                and row.get("dispatched_at_unix") is not None and start - 1 <= int(row.get("created_at_unix") or 0) <= end + 1
            ]
            expect(bool(matched), errors, f"a {'stream' if stream else 'non-stream'} canary reservation must be dispatched")
            for row in matched:
                done = self.by_request(outputs, str(row.get("internal_request_id")))
                expect(len(done) == 1 and done[0].get("terminal_state") == "normal_done" and done[0].get("output_available") == 1, errors, "a canary attempt must complete normally at the coordinator")
        chats = [event for event in self.proxy_events() if event.get("path") == "/v1/chat/completions" and start - 1 <= int(event.get("at_unix") or 0) <= end + 1 and privacy_posture(event) is not None]
        expect(len(chats) >= 2 and all(event.get("status") == 200 and event.get("mutated") is False and int(event.get("body_len") or 0) > 0 for event in chats), errors, "both canary responses must reach the buyer unmodified")

    def p_primary_receipts(self, errors: list[str]) -> None:
        _, end = self.window("step-09-redaction-sweep")
        reservations = [row for row in self.reservations() if row.get("privacy_class") == 1 and int(row.get("created_at_unix") or 0) <= end]
        dispatched = [row for row in reservations if row.get("dispatched_at_unix") is not None and row.get("internal_request_id")]
        expect(len(dispatched) >= 4, errors, "steps 02-08 must dispatch at least four privacy requests")
        verdicts = self.rows("coordinator.db", "settlement_receipt_verdicts")
        outputs = self.rows("coordinator.db", "settlement_attempt_outputs")
        outbox = self.rows("coordinator.db", "settlement_receipt_audit_outbox")
        snapshots = self.snapshots()
        for row in dispatched:
            request = str(row["internal_request_id"])
            label = f"privacy request {request}"
            found = self.by_request(verdicts, request)
            shots = self.by_request(snapshots, request)
            outs = self.by_request(outputs, request)
            if len(found) != 1 or len(shots) != 1 or len(outs) != 1:
                errors.append(f"{label} must have exactly one verdict, snapshot, and attempt output")
                continue
            verdict, shot, out = found[0], shots[0], outs[0]
            facts = verdict.get("facts_json") if isinstance(verdict.get("facts_json"), dict) else {}
            expect(verdict.get("receipt_present") == 1 and verdict.get("receipt_version") == RB_PROFILE and verdict.get("receipt_profile") == RB_PROFILE, errors, f"{label} must carry one {RB_PROFILE} receipt")
            expect(verdict.get("settlement_outcome") == RB_SETTLED and verdict.get("closed") == 1 and verdict.get("receipt_result") == "valid", errors, f"{label} must settle closed {RB_SETTLED}")
            self.snapshot_checks(row, shot, errors, label)
            expect(verdict.get("prompt_hash") == shot.get("prompt_hash"), errors, f"{label} receipt must bind the envelope digest")
            expect("prompt_hash" not in facts, errors, f"{label} receipt facts must carry no plaintext prompt hash")
            expect(bool(verdict.get("output_hash")) and verdict.get("output_hash") == out.get("output_hash") == facts.get("output_hash"), errors, f"{label} response_body_sha256 must be the captured frame digest")
            expect(out.get("settlement_output_canonical_json") in ("", None), errors, f"{label} attempt output must carry no content")
            bound = self.by_request(outbox, request)
            expect(bool(bound) and all(item.get("settlement_receipt_verdict_id") == verdict.get("id") and item.get("receipt_version") in (None, "", RB_PROFILE) for item in bound), errors, f"{label} audit outbox must hold records naming only its one receipt")
            checks = verdict.get("checks_json") if isinstance(verdict.get("checks_json"), dict) else {}
            expect(checks.get("signature_verified") is True and checks.get("route_snapshot_matched") is True and checks.get("output_hash_matched") is True, errors, f"{label} receipt signature, snapshot, and output checks must have passed")
        undispatched = {str(value) for row in reservations if row.get("dispatched_at_unix") is None for value in (row.get("request_id"), row.get("internal_request_id")) if value}
        expect(not any(row.get("request_id") in undispatched for row in verdicts), errors, "undispatched privacy requests must have no receipt verdict")
        hits = self.primary("db/request-id-crossref.json").get("hits") or {}
        for key in hits:
            table = key.split(":", 1)[-1].split(".", 1)[0]
            if re.search(r"receipt|telemetry|trace", table) and table not in ("settlement_receipt_verdicts", "settlement_receipt_audit_outbox"):
                errors.append(f"{key} names a privacy request")
        headers = [event for event in self.proxy_events() if any(str(name).lower() == "x-macprovider-receipt" for name in (event.get("response_macprovider_headers") or {}))]
        expect(not headers, errors, "no X-MacProvider-Receipt header may reach the buyer")

    def enforce_rows(self) -> list[dict[str, Any]]:
        start, end = self.window("step-13-enforce-canary")
        return [row for row in self.reservations() if start < int(row.get("created_at_unix") or 0) <= end and row.get("dispatched_at_unix") is not None]

    def p_primary_enforce(self, errors: list[str]) -> None:
        rows = self.enforce_rows()
        expect(sorted(row.get("privacy_class") for row in rows) == [0, 1, 1], errors, "step-13 must dispatch two privacy and one plain relay-blind request")
        start, end = self.window("step-13-enforce-canary")
        proxied = {event.get("request_envelope_sha256") for event in self.proxy_events() if start <= int(event.get("at_unix") or 0) <= end}
        verdicts = self.rows("coordinator.db", "settlement_receipt_verdicts")
        credits = self.rows("coordinator.db", "spec022_payable_request_credits")
        quotas = self.rows("gateway.db", "quota_reservations")
        usage = self.rows("gateway.db", "usage_events")
        snapshots = self.snapshots()
        for row in rows:
            request, provider = str(row.get("internal_request_id")), row.get("provider_id")
            label = f"enforce request {request}"
            shots = [item for item in self.by_request(snapshots, request) if item.get("provider_id") == provider]
            found = [item for item in self.by_request(verdicts, request) if item.get("provider_id") == provider]
            paid = [item for item in self.by_request(credits, request) if item.get("provider_id") == provider]
            if len(shots) != 1 or len(found) != 1 or len(paid) != 1:
                errors.append(f"{label} must have one snapshot, verdict, and payable credit")
                continue
            shot, verdict, credit = shots[0], found[0], paid[0]
            self.snapshot_checks(row, shot, errors, label)
            expect(shot.get("route_snapshot_mode") == "enforce", errors, f"{label} snapshot must be enforce")
            expect(shot.get("prompt_hash") in proxied, errors, f"{label} prompt_hash must be the SHA-256 of the proxied envelope bytes")
            # dispatched_at_unix has one-second resolution, so ordering is
            # proven by the provider-signed receipt instead: the coordinator
            # verified the signature over a tuple naming this snapshot's digest,
            # which the provider can learn only from the dispatch frame, and the
            # signed issue time follows the route decision.
            checks = verdict.get("checks_json") if isinstance(verdict.get("checks_json"), dict) else {}
            facts = verdict.get("facts_json") if isinstance(verdict.get("facts_json"), dict) else {}
            issued = facts.get("issued_at_unix_ms")
            expect(checks.get("signature_verified") is True and checks.get("route_snapshot_matched") is True, errors, f"{label} provider-signed receipt must bind the snapshot digest")
            decided = shot.get("route_decision_ts_unix_ms")
            expect(
                isinstance(issued, int) and not isinstance(issued, bool) and isinstance(decided, int) and not isinstance(decided, bool) and 0 < decided < issued,
                errors,
                f"{label} snapshot route decision must precede the signed receipt",
            )
            expect(verdict.get("settlement_outcome") == RB_SETTLED and verdict.get("closed") == 1 and verdict.get("receipt_result") == "valid", errors, f"{label} verdict must be closed {RB_SETTLED}")
            expect(verdict.get("receipt_profile") == RB_PROFILE and verdict.get("receipt_version") == RB_PROFILE and verdict.get("route_snapshot_mode") == "enforce", errors, f"{label} verdict must be the enforce relay-blind profile")
            expect(verdict.get("route_snapshot_digest") == shot.get("route_snapshot_digest"), errors, f"{label} verdict must bind the snapshot digest")
            expect(credit.get("settlement_policy_mode") == "enforce" and int(credit.get("provider_credits") or 0) > 0, errors, f"{label} credit must be payable under enforce")
            gateway = [item for item in quotas if item.get("relay_blind_internal_request_id") == request or (row.get("envelope_digest") and item.get("relay_blind_envelope_digest") == row.get("envelope_digest"))]
            if len(gateway) != 1:
                errors.append(f"{label} must have one gateway reservation")
                continue
            quota = gateway[0]
            debits = [item for item in usage if item.get("account_id") == quota.get("account_id") and item.get("request_id") == quota.get("request_id")]
            if len(debits) != 1:
                errors.append(f"{label} must have one gateway usage row")
                continue
            debit = debits[0]
            expect(quota.get("status") == "settled" and quota.get("relay_blind_settlement_mode", "enforce") == "enforce", errors, f"{label} gateway reservation must settle under enforce")
            expect(debit.get("prompt_tokens") == credit.get("prompt_tokens") and debit.get("completion_tokens") == credit.get("completion_tokens"), errors, f"{label} buyer debit must equal the provider-credited usage")
            expect(quota.get("settled_tokens") == debit.get("total_tokens") == int(debit.get("prompt_tokens") or 0) + int(debit.get("completion_tokens") or 0), errors, f"{label} settled tokens must equal the debited total")

    def p_primary_counters(self, errors: list[str]) -> None:
        start, _ = self.window("step-13-enforce-canary")
        _, end = self.window("step-13-enforce-canary")
        inventory = self.primary("db/inventory.json").get("databases") or {}
        for database, tables in inventory.items():
            for table in tables:
                if not REWARD_TABLE_RE.search(table):
                    continue
                for row in self.rows(database, table):
                    for column, value in row.items():
                        stamp = utc_unix(value) if isinstance(value, str) and ("_at" in column or column.endswith("_utc")) else None
                        if stamp is not None and start <= stamp <= end:
                            errors.append(f"{database}:{table} gained a row during the enforce canary")
                            break
        verified = [row for row in self.rows("coordinator.db", "settlement_receipt_verdicts") if row.get("settlement_outcome") == "verified" and start * 1000 <= int(row.get("received_at_unix_ms") or 0) <= (end + 1) * 1000]
        expect(not verified, errors, "no verified verdict may be recorded during the enforce canary")
        requests = {str(row.get("internal_request_id")) for row in self.enforce_rows()}
        credits = [row for row in self.rows("coordinator.db", "ledger_request_credits") if row.get("request_id") in requests]
        expect(
            len(requests) == 3 and sorted(str(row.get("request_id")) for row in credits) == sorted(requests),
            errors,
            "every enforce request must have exactly one ledger credit",
        )
        expect(
            all(row.get("rewards_excluded") == 1 and row.get("positive_verification_excluded") == 1 for row in credits),
            errors,
            "relay-blind enforce credits must be excluded from verified-work rewards and positive verification",
        )

    def p_primary_kill_switch_refund(self, errors: list[str]) -> None:
        start, end = self.window("step-12-kill-switch")
        held = [row for row in self.reservations() if row.get("privacy_class") == 1 and start <= int(row.get("created_at_unix") or 0) <= end and row.get("terminal_code") == "privacy_class_disabled"]
        expect(len(held) == 1, errors, "step-12 must hold exactly one privacy reservation rejected privacy_class_disabled")
        quotas = self.rows("gateway.db", "quota_reservations")
        usage = self.rows("gateway.db", "usage_events")
        for row in held:
            expect(row.get("state") == "rejected" and row.get("dispatched_at_unix") is None, errors, "the held privacy reservation must be rejected predispatch")
            opened, closed = int(row.get("created_at_unix") or 0), int(row.get("terminal_at_unix") or 0)
            expect(closed >= opened, errors, "the held reservation must record its rejection time")
            # The gateway reserves buyer quota only when the chat is consumed;
            # a reservation rejected first never reserves, so the refund is
            # that no quota reservation or usage debit exists in its lifetime.
            linked = [item for item in quotas if (row.get("internal_request_id") and item.get("relay_blind_internal_request_id") == row.get("internal_request_id")) or (row.get("envelope_digest") and item.get("relay_blind_envelope_digest") == row.get("envelope_digest"))]
            during = [item for item in quotas if opened <= (utc_unix(item.get("created_at")) or 0) <= closed + 1]
            for quota in linked + during:
                expect(quota.get("status") == "refunded" or (quota.get("status") == "settled" and quota.get("settled_tokens") == 0), errors, "no buyer quota may be charged for the held request")
            debits = [item for item in usage if opened <= (utc_unix(item.get("created_at")) or 0) <= closed + 1 and int(item.get("total_tokens") or 0) > 0]
            expect(not debits, errors, "no buyer usage may be debited during the held request")

    def p_primary_receipt_quarantine(self, errors: list[str]) -> None:
        verdicts = self.rows("coordinator.db", "settlement_receipt_verdicts")
        credits = self.rows("coordinator.db", "spec022_payable_request_credits")
        quotas = self.rows("gateway.db", "quota_reservations")
        usage = self.rows("gateway.db", "usage_events")
        for row in self.b.lines("step-15-tampered-receipt-quarantined/cases.tsv"):
            name, request, _ = row.split("\t")
            reason = QUARANTINE_CASES.get(name)
            found = self.by_request(verdicts, request)
            expect(len(found) == 1 and found[0].get("closed") == 1 and found[0].get("settlement_outcome") == "quarantined" and found[0].get("reason") == reason, errors, f"{name} must be closed quarantined for {reason}")
            expect(not self.by_request(credits, request), errors, f"{name} must have no payable credit")
            gateway = [item for item in quotas if item.get("relay_blind_internal_request_id") == request]
            expect(len(gateway) == 1 and (gateway[0].get("status") == "refunded" or (gateway[0].get("status") == "settled" and gateway[0].get("settled_tokens") == 0)), errors, f"{name} buyer reservation must be refunded")
            for quota in gateway:
                expect(all(int(item.get("total_tokens") or 0) == 0 for item in usage if item.get("account_id") == quota.get("account_id") and item.get("request_id") == quota.get("request_id")), errors, f"{name} must debit no usage")

    def p_primary_fault_isolation(self, errors: list[str]) -> None:
        plain = self.provider_id("plain")
        start, end = self.window("step-15-tampered-receipt-quarantined")
        urls = [line.get("text", "").split("coordinator_url:", 1)[1].strip() for line in self.primary("logs/provider-plain-lines.json").get("lines") or [] if "coordinator_url:" in str(line.get("text", ""))]
        expect(bool(urls) and all(re.fullmatch(r"ws://127\.0\.0\.1:193[0-9]{2}/ws/provider", url) for url in urls), errors, "every plain/fault provider start must target the loopback journey coordinator")
        accepted = [
            utc_unix(event.get("time_utc"))
            for event in self.coordinator_events()
            if event.get("provider_id") == plain and "auth_response accepted" in str(event.get("reason") or event.get("message") or "")
        ]
        expect(any(stamp is not None and start <= stamp <= end for stamp in accepted), errors, "the fault build's session must be accepted by the isolated journey coordinator")
        events = self.rows("provider_connection_events.db", "provider_connection_events")
        sessions = {
            str(row.get("session_id")): utc_unix(row.get("occurred_at_utc"))
            for row in events
            if row.get("provider_id") == plain and row.get("kind") == "auth_accepted" and row.get("outcome") == "success"
        }
        snapshots = self.snapshots()
        for line in self.b.lines("step-15-tampered-receipt-quarantined/cases.tsv"):
            name, request, _ = line.split("\t")
            if not name.startswith("fault-"):
                continue
            shots = self.by_request(snapshots, request)
            session = str(shots[0].get("provider_session_id")) if len(shots) == 1 else ""
            accepted_at = sessions.get(session)
            expect(bool(session) and accepted_at is not None and start <= accepted_at <= end, errors, f"{name} must be served by a session the journey coordinator accepted during step-15")

    def p_primary_dyld_procedure(self, errors: list[str]) -> None:
        record = self.primary("procedure/dyld.json")
        script = record.get("kit_script") or {}
        lines = [str(item.get("text", "")) for item in script.get("dyld_lines") or []]
        expect(re.fullmatch(r"[0-9a-f]{64}", str(script.get("sha256", ""))) is not None, errors, "the DYLD procedure must name the kit script digest")
        expect(any("DYLD_INSERT_LIBRARIES=" in line and "DYLD_PRINT_LIBRARIES=1" in line for line in lines) and any("--version" in line for line in lines), errors, "the kit must set DYLD_INSERT_LIBRARIES and DYLD_PRINT_LIBRARIES on the --version run")
        captured = int(parse_datetime(self.b.lines("results.tsv")[0].split("\t")[0], "results.tsv").timestamp())
        mtime = utc_unix(script.get("mtime_utc"))
        expect(mtime is not None and mtime <= captured, errors, "the kit script must predate the run")

    # -- v0.2 evidence extension

    def primary_v2(self, relative: str) -> dict[str, Any]:
        doc = self.primary(f"v2/{relative}")
        if doc.get("profile") != V2_SOURCE_PROFILE:
            fail(f"primary/v2/{relative} must be a v2 source-fact export")
        provenance = doc.get("provenance")
        if not isinstance(provenance, dict) or set(provenance) != {"raw_sources"} or not isinstance(provenance.get("raw_sources"), list):
            fail(f"primary/v2/{relative} must carry provenance.raw_sources")
        expected = V2_SOURCE_CONTRACT.get(relative)
        if expected is None:
            fail(f"primary/v2/{relative} has no source contract")
        found: dict[str, dict[str, str]] = {}
        for item in provenance["raw_sources"]:
            if not isinstance(item, dict) or set(item) != {"kind", "path", "sha256"}:
                fail(f"primary/v2/{relative} provenance rows must carry exactly kind, path, and sha256")
            kind = item.get("kind")
            if not isinstance(kind, str) or kind in found or kind not in expected:
                fail(f"primary/v2/{relative} provenance kinds must be closed and unique")
            if item.get("path") != expected[kind]:
                fail(f"primary/v2/{relative} provenance path for {kind} is not the closed raw path")
            if not isinstance(item.get("sha256"), str) or not SHA256_RE.fullmatch(item["sha256"]):
                fail(f"primary/v2/{relative} provenance sha256 must be lowercase sha256")
            suffix = Path(expected[kind]).suffix
            exported = f"primary/v2/sources/{kind}{suffix}"
            if exported not in self.b.files or self.b.sha256(exported) != item["sha256"]:
                fail(f"primary/v2/{relative} source {kind} is absent or its digest is not provenance-bound")
            found[kind] = item
        if set(found) != set(expected):
            fail(f"primary/v2/{relative} provenance kinds must be exactly {sorted(expected)}")
        if not isinstance(doc.get("raw_source_sha256"), str) or not SHA256_RE.fullmatch(doc["raw_source_sha256"]):
            fail(f"primary/v2/{relative} must carry raw_source_sha256")
        return doc

    def require_keys(self, doc: dict[str, Any], keys: set[str], label: str, errors: list[str]) -> None:
        expect(set(doc) == keys, errors, f"{label} must carry exactly {sorted(keys)}")

    def v2_source_bytes(self, manifest: str, kind: str) -> bytes:
        doc = self.primary_v2(manifest)
        source = V2_SOURCE_CONTRACT[manifest].get(kind)
        if source is None:
            fail(f"primary/v2/{manifest} does not declare source kind {kind}")
        item = next(row for row in doc["provenance"]["raw_sources"] if row["kind"] == kind)
        path = f"primary/v2/sources/{kind}{Path(source).suffix}"
        raw = self.b.raw(path)
        if hashlib.sha256(raw).hexdigest() != item["sha256"]:
            fail(f"{path} does not match its raw provenance digest")
        return raw

    def v2_source_json(self, manifest: str, kind: str) -> Any:
        path = V2_SOURCE_CONTRACT[manifest][kind]
        try:
            text = self.v2_source_bytes(manifest, kind).decode("utf-8")
        except UnicodeDecodeError:
            fail(f"{path} must be UTF-8 JSON")
        return parse_json(text, path)

    def v2_snapshot(self, manifest: str, kind: str) -> tuple[int, dict[str, list[dict[str, Any]]]]:
        label = V2_SOURCE_CONTRACT[manifest][kind]
        doc = self.v2_source_json(manifest, kind)
        if not isinstance(doc, dict) or set(doc) != {"captured_at_unix", "tables"}:
            fail(f"{label} must carry exactly captured_at_unix and tables")
        captured = doc.get("captured_at_unix")
        tables = doc.get("tables")
        if not isinstance(captured, int) or isinstance(captured, bool) or captured <= 0:
            fail(f"{label}.captured_at_unix must be a positive integer")
        if not isinstance(tables, dict) or set(tables) != set(V2_DB_TABLES):
            fail(f"{label}.tables must be the closed v2 table set")
        result: dict[str, list[dict[str, Any]]] = {}
        for name in V2_DB_TABLES:
            export = tables[name]
            if not isinstance(export, dict) or set(export) != {"table", "columns", "dropped_columns", "row_count", "truncated", "rows"}:
                fail(f"{label}.{name} must be a complete primary row export")
            columns, rows = export.get("columns"), export.get("rows")
            if export.get("table") != name or export.get("truncated") is not False or not isinstance(columns, list) or not all(isinstance(item, str) for item in columns):
                fail(f"{label}.{name} must identify a complete untruncated table")
            if tuple(columns) != V2_DB_COLUMNS[name]:
                fail(f"{label}.{name} columns must be the closed public-state projection {list(V2_DB_COLUMNS[name])}")
            if not isinstance(export.get("dropped_columns"), list) or not isinstance(rows, list) or export.get("row_count") != len(rows):
                fail(f"{label}.{name} row metadata is invalid")
            if not all(isinstance(row, dict) and set(row) == set(columns) for row in rows):
                fail(f"{label}.{name} rows must exactly match columns")
            result[name] = rows
        return captured, result

    def v2_clients(self, manifest: str, kind: str) -> tuple[int, dict[str, dict[str, Any]]]:
        label = V2_SOURCE_CONTRACT[manifest][kind]
        doc = self.v2_source_json(manifest, kind)
        if not isinstance(doc, dict) or set(doc) != {"captured_at_unix", "attempts"}:
            fail(f"{label} must carry exactly captured_at_unix and attempts")
        captured, attempts = doc.get("captured_at_unix"), doc.get("attempts")
        if not isinstance(captured, int) or isinstance(captured, bool) or not isinstance(attempts, list):
            fail(f"{label} has invalid capture types")
        by_case: dict[str, dict[str, Any]] = {}
        required = {"case", "status", "provider_id", "response_excerpt"}
        for attempt in attempts:
            if not isinstance(attempt, dict) or set(attempt) != required:
                fail(f"{label} attempt must carry exactly {sorted(required)}")
            name = attempt.get("case")
            if not isinstance(name, str) or not name or name in by_case:
                fail(f"{label} attempt cases must be non-empty and unique")
            status = attempt.get("status")
            excerpt = attempt.get("response_excerpt")
            if not isinstance(status, int) or isinstance(status, bool) or not isinstance(excerpt, dict):
                fail(f"{label} attempt status/response types are invalid")
            if attempt.get("provider_id") is not None and not isinstance(attempt.get("provider_id"), str):
                fail(f"{label} attempt provider_id must be string or null")
            posture = error_code = None
            if set(excerpt) == {"usage_macprovider_privacy"}:
                usage = excerpt["usage_macprovider_privacy"]
                if not isinstance(usage, dict) or set(usage) != {"posture_verified_at_unix"} or not isinstance(usage["posture_verified_at_unix"], int) or isinstance(usage["posture_verified_at_unix"], bool):
                    fail(f"{label} successful response excerpt must carry the observed posture time")
                posture = usage["posture_verified_at_unix"]
            elif set(excerpt) == {"error"}:
                error = excerpt["error"]
                if not isinstance(error, dict) or set(error) != {"code"} or not isinstance(error["code"], str):
                    fail(f"{label} error response excerpt must carry the actual code")
                error_code = error["code"]
            else:
                fail(f"{label} response excerpt must be the closed usage or error shape")
            if (status == 200) is not (posture is not None):
                fail(f"{label} HTTP status must agree with the captured response excerpt")
            by_case[name] = {**attempt, "error_code": error_code, "privacy_posture_verified_at_unix": posture}
        return captured, by_case

    def v2_view(self) -> V2RawSourceView:
        return V2RawSourceView(
            lambda manifest, kind: self.v2_source_bytes(manifest, kind),
            self.binding,
            self.trusted_release_public_key_sha256,
        )

    @staticmethod
    def active_enrollments(tables: dict[str, list[dict[str, Any]]]) -> list[dict[str, Any]]:
        return [row for row in tables["privacy_class_enrollment"] if row.get("revoked_at_unix") in (None, 0)]

    @staticmethod
    def privacy_keys(tables: dict[str, list[dict[str, Any]]]) -> list[dict[str, Any]]:
        return [row for row in tables["relay_blind_key_records"] if row.get("key_class") == "privacy"]

    @staticmethod
    def row_identity(rows: list[dict[str, Any]], keys: tuple[str, ...]) -> set[tuple[Any, ...]]:
        return {tuple(row.get(key) for key in keys) for row in rows}

    def p_v2_auto_mode(self, errors: list[str]) -> None:
        doc = self.primary_v2("auto-mode.json")
        self.require_keys(doc, {"schema_version", "profile", "provenance", "raw_source_sha256", "cases"}, "primary/v2/auto-mode.json", errors)
        recomputed = self.v2_view().auto_mode(errors)
        cases = {item.get("name"): item for item in doc.get("cases", []) if isinstance(item, dict)}
        required = {"automatic-eligible", "automatic-ineligible", "automatic-hardening-fallback", "explicit-optout", "explicit-relay-blind"}
        expect(set(cases) == required and len(doc.get("cases", [])) == len(required), errors, "auto-mode summary cases must cover the closed v2 set exactly once")
        expect(doc.get("cases") == recomputed["cases"], errors, "auto-mode summary must equal independent raw-source recomputation")

    def p_v2_enrollment(self, errors: list[str]) -> None:
        doc = self.primary_v2("enrollment.json")
        self.require_keys(doc, {"schema_version", "profile", "provenance", "raw_source_sha256", "enrollments", "cross_provider_reuse", "failed_posture"}, "primary/v2/enrollment.json", errors)
        recomputed = self.v2_view().enrollment(errors)
        expect(doc.get("enrollments") == recomputed["enrollments"], errors, "enrollment summary must equal independent snapshot/client recomputation")
        expect(doc.get("cross_provider_reuse") == recomputed["cross_provider_reuse"], errors, "reuse summary must equal source deltas")
        expect(doc.get("failed_posture") == recomputed["failed_posture"], errors, "failed-posture summary must equal source deltas")

    def p_v2_key_change_reenroll(self, errors: list[str]) -> None:
        doc = self.primary_v2("reenroll.json")
        self.require_keys(doc, {"schema_version", "profile", "provenance", "raw_source_sha256", "initial", "key_change", "post_expiry_retry", "operator_reenroll", "after_reenroll"}, "primary/v2/reenroll.json", errors)
        recomputed = self.v2_view().key_change_reenroll(errors)
        expect(all(doc.get(key) == value for key, value in recomputed.items()), errors, "reenroll summary must equal independent phase-snapshot/client recomputation")

    def p_v2_release_approval(self, errors: list[str]) -> None:
        doc = self.primary_v2("release-derived-approval.json")
        self.require_keys(doc, {"schema_version", "profile", "provenance", "raw_source_sha256", "approved_identity", "metadata", "eligibility"}, "primary/v2/release-derived-approval.json", errors)
        recomputed = self.v2_view().release_approval(errors)
        expect(all(doc.get(key) == value for key, value in recomputed.items()), errors, "release summary must equal signature, identity, configuration, and client recomputation")

    def p_v2_directory(self, errors: list[str]) -> None:
        doc = self.primary_v2("directory.json")
        self.require_keys(doc, {"schema_version", "profile", "provenance", "raw_source_sha256", "directory", "client_rejections", "gateway", "disclosure"}, "primary/v2/directory.json", errors)
        recomputed = self.v2_view().directory(errors)
        expect(all(doc.get(key) == value for key, value in recomputed.items()), errors, "directory summary must equal signature, store, gateway, client, and disclosure recomputation")


STEP_PREDICATES: dict[str, tuple[str, ...]] = {
    "step-01-bind-signed-release": ("bind_release",),
    "step-02-privacy-mode-start": ("privacy_start", "posture_verified", "key_memory_only", "primary_key_attestation", "primary_posture", "primary_first_connect"),
    "step-03-debugger-attach-refused": ("debugger", "primary_posture_after_attach"),
    "step-04-core-dump-and-env-refused": ("core_dumps", "diag_env", "config_refusals", "dyld", "primary_dyld_procedure"),
    "step-05-unsigned-build-refused": ("unsigned",),
    "step-06-sip-off-refused": ("sip_off",),
    "step-07-canary-stream": ("stream", "primary_canary_completion"),
    "step-08-canary-nonstream": ("nonstream", "primary_canary_completion"),
    "step-09-redaction-sweep": ("sweeps_clean", "receipts", "core_dumps", "primary_integrity", "primary_receipts", "primary_canary_recheck"),
    "step-10-downgrade-negatives": ("downgrade", "tamper_truncate", "no_failover"),
    "step-11-stale-posture-and-quarantine": ("stale", "quarantine_durable"),
    "step-12-kill-switch": ("kill_switch", "unaffected", "primary_kill_switch_refund"),
    "step-13-enforce-canary": ("enforce_config", "enforce_snapshot", "enforce_verdict", "enforce_credit", "enforce_debit", "counters", "sweeps_clean", "disclosure_exact", "primary_enforce", "primary_counters"),
    "step-14-no-capability-provider-excluded": ("no_capability",),
    "step-15-tampered-receipt-quarantined": ("receipt_quarantine", "isolated_fault_build", "primary_receipt_quarantine", "primary_fault_isolation"),
    "step-16-redaction-review": ("review", "primary_integrity", "primary_canary_recheck"),
    "step-17-auto-mode-eligibility": ("v2_auto_mode",),
    "step-18-auto-enrollment-distinct-identities": ("v2_enrollment",),
    "step-19-key-change-quarantine-reenroll": ("v2_key_change_reenroll",),
    "step-20-release-derived-approval": ("v2_release_approval",),
    "step-21-operator-signed-directory": ("v2_directory",),
}

# A true observation holds when all its predicates hold. A must-be-false
# observation is false only when all the predicates refuting it hold. The
# primary_* predicates recompute from the raw-row and log exports under
# primary/; the others read the run kit's step artifacts.
OBSERVATION_PREDICATES: dict[str, tuple[str, ...]] = {
    "hardening_applied_before_network_verified": ("privacy_start", "posture_verified", "diag_env", "config_refusals", "unsigned", "sip_off", "primary_first_connect"),
    "privacy_key_memory_only_verified": ("key_memory_only", "primary_key_attestation"),
    "posture_verified_by_coordinator": ("posture_verified", "primary_posture"),
    "debugger_attach_refused_verified": ("debugger", "primary_posture_after_attach"),
    "core_dumps_disabled_verified": ("core_dumps", "primary_posture"),
    "diagnostic_env_refused_verified": ("diag_env",),
    "dyld_env_inert_verified": ("dyld", "primary_dyld_procedure"),
    "unsigned_or_resigned_build_refused_verified": ("unsigned",),
    "sip_off_host_refused_verified": ("sip_off",),
    "stream_frames_decrypted_and_verified": ("stream", "primary_canary_completion"),
    "nonstream_frames_decrypted_and_verified": ("nonstream", "primary_canary_completion"),
    "disclosure_strings_exact_verified": ("disclosure_exact",),
    "canary_absent_from_all_artifacts_verified": ("sweeps_clean", "review", "primary_integrity", "primary_canary_recheck"),
    "downgrade_attempts_rejected_verified": ("downgrade",),
    "tampered_or_truncated_response_rejected_verified": ("tamper_truncate",),
    "stale_posture_ineligible_verified": ("stale",),
    "quarantine_durable_across_restart_verified": ("quarantine_durable",),
    "kill_switch_blocks_all_phases_verified": ("kill_switch", "primary_kill_switch_refund"),
    "relay_blind_and_plaintext_unaffected_verified": ("unaffected",),
    "exactly_one_content_free_settlement_receipt_verified": ("receipts", "primary_receipts"),
    "enforce_snapshot_before_dispatch_verified": ("enforce_config", "enforce_snapshot", "primary_enforce"),
    "relay_blind_settled_verdict_closed_verified": ("enforce_verdict", "primary_enforce"),
    "relay_blind_credit_payable_verified": ("enforce_credit", "primary_enforce"),
    "buyer_debit_equals_provider_credit_usage_verified": ("enforce_debit", "primary_enforce"),
    "verified_count_delta_zero_verified": ("counters", "primary_counters"),
    "no_capability_provider_excluded_verified": ("no_capability",),
    "tampered_or_missing_receipt_quarantined_and_refunded_verified": ("receipt_quarantine", "primary_receipt_quarantine"),
    "plaintext_observed_at_relay": ("sweeps_clean", "stream", "nonstream", "primary_canary_recheck"),
    "failover_or_alternate_provider_observed": ("no_failover", "no_capability"),
    "silent_downgrade_observed": ("downgrade", "tamper_truncate"),
    "plaintext_derived_receipt_or_telemetry_emitted_for_privacy_request": ("receipts", "sweeps_clean", "primary_receipts"),
    "relay_blind_request_reported_as_verified": ("enforce_verdict", "counters", "disclosure_exact", "primary_enforce", "primary_counters"),
    "privacy_key_written_to_disk": ("key_memory_only",),
    "unreleased_local_binary_connected_to_live_coordinator": ("live_untouched", "isolated_fault_build", "unsigned", "sip_off", "primary_fault_isolation"),
    "secret_or_canary_persisted": ("sweeps_clean", "review", "primary_integrity", "primary_canary_recheck"),
    "auto_mode_eligible_host_enters_privacy_verified": ("v2_auto_mode",),
    "auto_mode_ineligible_host_falls_back_without_privacy_records_verified": ("v2_auto_mode",),
    "explicit_optout_disables_privacy_class_verified": ("v2_auto_mode",),
    "auto_enrollment_binds_distinct_provider_identities_verified": ("v2_enrollment",),
    "cross_provider_key_reuse_refused_verified": ("v2_enrollment",),
    "enrollment_key_change_quarantines_and_revokes_records_verified": ("v2_key_change_reenroll",),
    "operator_reenroll_revokes_old_enrollment_and_admits_new_keys_verified": ("v2_key_change_reenroll",),
    "release_metadata_approves_tested_code_identity_verified": ("v2_release_approval",),
    "release_identity_withdrawal_or_denial_removes_eligibility_verified": ("v2_release_approval",),
    "identity_directory_signature_expiry_and_revocation_verified": ("v2_directory",),
    "expanded_v2_residual_disclosures_exact_verified": ("v2_directory",),
    "automatic_mode_advertised_privacy_records_when_ineligible": ("v2_auto_mode",),
    "enrollment_replaced_by_key_change_without_operator_reenroll": ("v2_key_change_reenroll",),
    "denied_release_identity_remained_eligible": ("v2_release_approval",),
    "unsigned_expired_or_revoked_directory_accepted": ("v2_directory",),
    "v2_residual_disclosure_omitted": ("v2_directory",),
}


# ---------------------------------------------------------------- recompute


def parse_results(bundle: Bundle, profile: EvidenceProfile = PROFILE_V1) -> tuple[str, dict[str, str]]:
    rows: dict[str, str] = {}
    first: str | None = None
    previous = ""
    for line in bundle.lines("results.tsv"):
        parts = line.split("\t")
        if len(parts) != 4 or not DATETIME_Z_RE.fullmatch(parts[0]):
            fail("results.tsv rows must be <RFC3339>\\t<step>\\t<status>\\t<detail>")
        if parts[1] in rows:
            fail(f"results.tsv repeats {parts[1]}")
        if parts[0] < previous:
            fail("results.tsv must be in time order")
        rows[parts[1]] = parts[2]
        first = first or parts[0]
        previous = parts[0]
    if set(rows) != set(profile.kit_step_ids):
        fail(f"results.tsv must hold exactly the kit steps {list(profile.kit_step_ids)}")
    if list(rows)[0] != profile.kit_step_ids[0]:
        fail("results.tsv must start with the isolation preflight")
    for step, status in rows.items():
        allowed = {"PASS", "MANUAL"} if step == "step-16-redaction-review" else {"PASS"}
        if status not in allowed:
            fail(f"results.tsv {step} must be {sorted(allowed)}, got {status}")
    assert first is not None
    return first, rows


_RECOMPUTE_CACHE: dict[str, tuple[dict[str, list[str]], dict[str, bool]]] = {}


def recompute(bundle: Bundle, profile: EvidenceProfile = PROFILE_V1) -> tuple[dict[str, list[str]], dict[str, bool]]:
    """Return step failures and recomputed observations for a bundle.

    MANIFEST.sha256 binds every bundle file, so its digest keys a per-process
    cache; the salted canary recheck is the slow part.
    """
    cache_key = f"{profile.schema}:{bundle.manifest_sha256}"
    cached = _RECOMPUTE_CACHE.get(cache_key)
    if cached is not None:
        return {step: list(errors) for step, errors in cached[0].items()}, dict(cached[1])
    result = _recompute(bundle, profile)
    _RECOMPUTE_CACHE[cache_key] = result
    return {step: list(errors) for step, errors in result[0].items()}, dict(result[1])


def _recompute(bundle: Bundle, profile: EvidenceProfile) -> tuple[dict[str, list[str]], dict[str, bool]]:
    checks = Checks(bundle, profile)
    step_errors = {
        step: [error for name in STEP_PREDICATES[step] for error in checks.run(name)]
        for step in profile.step_ids
    }
    observations: dict[str, bool] = {}
    for name in profile.true_observations:
        observations[name] = all(not checks.run(predicate) for predicate in OBSERVATION_PREDICATES[name])
    for name in profile.false_observations:
        observations[name] = not all(not checks.run(predicate) for predicate in OBSERVATION_PREDICATES[name])
    return step_errors, observations


def release_identity(bundle: Bundle) -> dict[str, str]:
    values = Checks(bundle).binding()
    return {
        "release_tag": values["release_tag"],
        "binary_sha256": values["binary_sha256"],
        "code_cdhash": values["code_cdhash"],
        "team_id": values["team_id"],
        "signing_identifier": values["signing_identifier"],
        "source_commit": values["source_commit"],
        "hardware_model": values["hardware_model"],
    }


def profile_for_schema(schema: Any) -> EvidenceProfile:
    if not isinstance(schema, str) or schema not in PROFILES_BY_SCHEMA:
        fail(f"schema_version must be one of {sorted(PROFILES_BY_SCHEMA)}")
    return PROFILES_BY_SCHEMA[schema]


def profile_for_name(name: str) -> EvidenceProfile:
    if name == "v1":
        return PROFILE_V1
    if name == "v2":
        return PROFILE_V2
    fail("profile must be 'v1' or 'v2'")
    raise AssertionError("unreachable")


def journey_requirement_ids(root: Path, profile: EvidenceProfile = PROFILE_V1) -> list[str]:
    """Requirements mapped to the journey, minus the Completion exclusions.

    The mapping comes from `specs/CONFORMANCE.json` and must equal the journey
    file's `Requirements:` header, so neither can drift on its own.
    """
    try:
        conformance = json.loads((root / "specs" / "CONFORMANCE.json").read_text(encoding="utf-8"), object_pairs_hook=_unique_json_object)
        journey_text = (root / profile.journey_path).read_text(encoding="utf-8")
    except (OSError, json.JSONDecodeError, DuplicateJSONKeyError) as exc:
        fail(f"cannot read the journey requirement mapping: {exc}")
    mapped = {
        row["requirement_id"]
        for row in conformance.get("requirements", [])
        if isinstance(row, dict) and isinstance(row.get("requirement_id"), str) and profile.journey_id in (row.get("journeys") or [])
    }
    header = re.search(r"^Requirements:(.*?)^Authority domains:", journey_text, re.M | re.S)
    if header is None:
        fail(f"{profile.journey_path} must carry a Requirements: header")
    declared = set(re.findall(r"SPEC-[0-9]{3}-R[0-9]{3}", header.group(1)))
    if mapped != declared:
        fail(f"CONFORMANCE.json and {profile.journey_path} disagree on the journey requirements")
    if not profile.excluded_requirement_ids <= mapped:
        fail("every Completion exclusion must be mapped to the journey")
    return sorted(mapped - profile.excluded_requirement_ids)


def parse_datetime(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not DATETIME_Z_RE.fullmatch(value):
        fail(f"{label} must be RFC3339 UTC seconds")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def format_datetime(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def compose_evidence(root: Path, bundle_dir: str, *, expires_at: str | None = None, profile: EvidenceProfile | str = PROFILE_V1) -> dict[str, Any]:
    """Compose the closed evidence object from a reviewed bundle."""
    bundle = load_bundle(root, bundle_dir)
    if isinstance(profile, str):
        profile = profile_for_name(profile)
    if profile not in (PROFILE_V1, PROFILE_V2):
        fail("compose_evidence profile must be PROFILE_V1 or PROFILE_V2")
    captured_at, _ = parse_results(bundle, profile)
    step_errors, observations = recompute(bundle, profile)
    failures = [error for errors in step_errors.values() for error in errors]
    if failures:
        fail("reviewed bundle does not prove every step: " + "; ".join(failures))
    for name, value in observations.items():
        if value is not (name in profile.true_observations):
            fail(f"observation {name} recomputes to {value} from the bundle; the contract requires {name in profile.true_observations}")
    captured = parse_datetime(captured_at, "captured_at")
    expiry = parse_datetime(expires_at, "expires_at") if expires_at else captured + MAX_EVIDENCE_LIFETIME
    identity = release_identity(bundle)
    evidence = {
        "schema_version": profile.schema,
        "journey_id": profile.journey_id,
        "requirement_ids": journey_requirement_ids(root, profile),
        "captured_at": captured_at,
        "expires_at": format_datetime(expiry),
        "release_tag": identity["release_tag"],
        "binary_sha256": identity["binary_sha256"],
        "code_cdhash": identity["code_cdhash"],
        "team_id": identity["team_id"],
        "signing_identifier": identity["signing_identifier"],
        "steps": [
            {"step_id": step, "status": "pass", "artifact_sha256": bundle.sha256(STEP_PRIMARY_ARTIFACTS[step])}
            for step in profile.step_ids
        ],
        "observations": {name: observations[name] for name in (*profile.true_observations, *profile.false_observations)},
        "redaction_manifest_sha256": bundle.manifest_sha256,
    }
    return evidence


def validate_evidence(root: Path, source: str, evidence: dict[str, Any], *, now: datetime | None = None) -> Bundle:
    """Validate the closed evidence object against its bundle; return the bundle."""
    if set(evidence) != set(EVIDENCE_KEYS):
        fail(f"evidence must carry exactly {list(EVIDENCE_KEYS)} (extra={sorted(set(evidence) - set(EVIDENCE_KEYS))}, missing={sorted(set(EVIDENCE_KEYS) - set(evidence))})")
    profile = profile_for_schema(evidence.get("schema_version"))
    if evidence.get("journey_id") != profile.journey_id:
        fail(f"journey_id must equal {profile.journey_id!r}")
    requirement_ids = evidence.get("requirement_ids")
    if not isinstance(requirement_ids, list) or not all(isinstance(item, str) and REQUIREMENT_RE.fullmatch(item) for item in requirement_ids):
        fail("requirement_ids must be an array of requirement IDs")
    if requirement_ids != sorted(set(requirement_ids)):
        fail("requirement_ids must be sorted and unique")
    if requirement_ids != journey_requirement_ids(root, profile):
        fail(f"requirement_ids must be every requirement mapped to {profile.journey_id} except {sorted(profile.excluded_requirement_ids)}")
    captured = parse_datetime(evidence.get("captured_at"), "captured_at")
    expires = parse_datetime(evidence.get("expires_at"), "expires_at")
    if not captured < expires <= captured + MAX_EVIDENCE_LIFETIME:
        fail("expires_at must be after captured_at and no more than 90 days later")
    if now is not None and expires <= now:
        fail("evidence has expired")
    names = (*profile.true_observations, *profile.false_observations)
    observations = evidence.get("observations")
    if not isinstance(observations, dict) or set(observations) != set(names):
        fail(f"observations must contain exactly the {len(names)} contract booleans")
    if not all(isinstance(value, bool) for value in observations.values()):
        fail("observations must be booleans")
    bundle_dir = bundle_dir_for_source(source)
    if bundle_dir[len(EVIDENCE_PREFIX) :] != captured.strftime("%Y%m%dT%H%M%SZ"):
        fail("evidence file name must carry the compact captured_at")
    bundle = load_bundle(root, bundle_dir)
    if evidence.get("redaction_manifest_sha256") != bundle.manifest_sha256:
        fail("redaction_manifest_sha256 must equal the SHA-256 of the bundle MANIFEST.sha256")
    run_start, _ = parse_results(bundle, profile)
    if evidence["captured_at"] != run_start:
        fail("captured_at must equal the journey start recorded in results.tsv")
    identity = release_identity(bundle)
    for key, pattern in (("release_tag", RELEASE_TAG_RE), ("binary_sha256", SHA256_RE), ("code_cdhash", CDHASH_RE), ("team_id", TEAM_ID_RE), ("signing_identifier", SIGNING_IDENTIFIER_RE)):
        value = evidence.get(key)
        if not isinstance(value, str) or not pattern.fullmatch(value):
            fail(f"{key} has invalid format")
        if value != identity[key]:
            fail(f"{key} must equal the bound release identity recorded by step-01")
    steps = evidence.get("steps")
    if not isinstance(steps, list) or len(steps) != len(profile.step_ids):
        fail(f"steps must contain each of the {len(profile.step_ids)} journey steps exactly once")
    bundle_digests = {hashlib.sha256(data).hexdigest() for data in bundle.files.values()}
    for index, (step, expected_id) in enumerate(zip(steps, profile.step_ids)):
        if not isinstance(step, dict) or list(step) != ["step_id", "status", "artifact_sha256"]:
            fail(f"steps[{index}] must be exactly {{step_id, status, artifact_sha256}}")
        if step["step_id"] != expected_id:
            fail(f"steps[{index}].step_id must be {expected_id} (numeric order, each once)")
        if step["status"] != "pass":
            fail(f"{expected_id}.status must be 'pass'")
        digest = step["artifact_sha256"]
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest) or digest not in bundle_digests:
            fail(f"{expected_id}.artifact_sha256 must resolve to a file in the reviewed bundle")
        if digest != bundle.sha256(STEP_PRIMARY_ARTIFACTS[expected_id]):
            fail(f"{expected_id}.artifact_sha256 must be the digest of {STEP_PRIMARY_ARTIFACTS[expected_id]}")
    step_errors, recomputed = recompute(bundle, profile)
    failures = [error for errors in step_errors.values() for error in errors]
    if failures:
        fail("reviewed bundle does not prove every step: " + "; ".join(failures))
    for name in names:
        required = name in profile.true_observations
        if recomputed[name] is not required:
            fail(f"observation {name} recomputes to {recomputed[name]} from the bundle; the contract requires {required}")
        if observations[name] is not recomputed[name]:
            fail(f"observation {name} disagrees with the bundle")
    return bundle


# ---------------------------------------------------------------- payload


def operator_fingerprint(manifest_sha256: str, profile: EvidenceProfile = PROFILE_V1) -> str:
    # The closed evidence object carries no operator identity; the signed
    # payload binds a non-identifying digest of the reviewed bundle instead.
    return hashlib.sha256(f"{profile.operator_fingerprint_domain}\n{manifest_sha256}".encode()).hexdigest()


def signed_expiry_date(expires_at: str) -> str:
    # Signed results expire at the end of a calendar date; choose the last date
    # that ends no later than the evidence expires_at.
    expires = parse_datetime(expires_at, "expires_at")
    return ((expires + timedelta(seconds=1)).date() - timedelta(days=1)).isoformat()


def project_payload(evidence: dict[str, Any], source: str, evidence_sha256: str, bundle: Bundle, *, source_sha: str, evidence_sha: str) -> dict[str, Any]:
    profile = profile_for_schema(evidence.get("schema_version"))
    identity = release_identity(bundle)
    run_id = Path(source).name[: -len(EVIDENCE_SUFFIX)]
    return {
        "schema_version": JOURNEY_RESULT_PAYLOAD_SCHEMA,
        "journey_id": profile.journey_id,
        "requirement_ids": list(evidence["requirement_ids"]),
        "repository": {"name": REPOSITORY, "commit": source_sha},
        "evidence_repository": {"name": REPOSITORY, "commit": evidence_sha},
        "captured_at": evidence["captured_at"],
        "expires_at": signed_expiry_date(evidence["expires_at"]),
        "operator": {"role": "acceptance-operator", "identity_fingerprint": operator_fingerprint(bundle.manifest_sha256, profile)},
        "environment": {
            "class": EXECUTION_MODE,
            "hardware_profile": f"apple-silicon-{identity['hardware_model'].lower().replace(',', '-')}",
            "candidate": f"release:{evidence['release_tag']}",
        },
        "candidate_identity": {
            "release_tag": evidence["release_tag"],
            "binary_sha256": evidence["binary_sha256"],
            "code_cdhash": evidence["code_cdhash"],
            "team_id": evidence["team_id"],
            "signing_identifier": evidence["signing_identifier"],
        },
        "artifacts": [
            {"id": profile.artifact_id, "sha256": evidence_sha256, "source": source},
            {"id": profile.manifest_artifact_id, "sha256": bundle.manifest_sha256, "source": bundle.manifest_source},
        ],
        "result": {"status": "pass", "summary": profile.summary},
        "steps": [
            {"id": step, "status": "pass", "assertion": STEP_ASSERTIONS[step], "artifacts": [profile.artifact_id, profile.manifest_artifact_id]}
            for step in profile.step_ids
        ],
        "redaction": {"secrets_redacted": True, "operator_identity_redacted": True, "local_account_names_redacted": True},
        "run_id": run_id,
        "execution_mode": EXECUTION_MODE,
        "observations": dict(evidence["observations"]),
    }


def load_evidence(root: Path, source: str) -> tuple[dict[str, Any], bytes]:
    if Path(source).is_absolute() or ".." in Path(source).parts:
        fail("evidence source must be repository-relative")
    bundle_dir_for_source(source)
    path = require_no_symlink_components(root, source)
    if not path.is_file():
        fail(f"evidence source is absent: {source}")
    data = path.read_bytes()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        fail("evidence source is not UTF-8")
    evidence = parse_json(text, source)
    if not isinstance(evidence, dict):
        fail("evidence must be a JSON object")
    return evidence, data


def git_file_bytes(root: Path, commit: str, source: str) -> bytes | None:
    completed = subprocess.run(["git", "show", f"{commit}:{source}"], cwd=root, capture_output=True, check=False)
    return completed.stdout if completed.returncode == 0 else None


def git_ok(root: Path, *args: str) -> bool:
    return subprocess.run(["git", *args], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode == 0


def build_payload(root: Path, source: str, *, source_sha: str, evidence_sha: str, now: datetime | None = None) -> dict[str, Any]:
    for label, value in (("--source-sha", source_sha), ("--evidence-sha", evidence_sha)):
        if not COMMIT_RE.fullmatch(value):
            fail(f"{label} must be a 40-character lowercase hex commit")
        if not git_ok(root, "cat-file", "-e", f"{value}^{{commit}}"):
            fail(f"{label} is not a reachable commit")
    if not git_ok(root, "merge-base", "--is-ancestor", source_sha, evidence_sha):
        fail("--source-sha must be an ancestor of --evidence-sha")
    evidence, data = load_evidence(root, source)
    bundle = validate_evidence(root, source, evidence, now=now or datetime.now(timezone.utc))
    if release_identity(bundle)["source_commit"] != source_sha:
        fail("--source-sha must equal the coordinator/gateway source commit bound by step-01")
    if git_file_bytes(root, evidence_sha, source) != data:
        fail("redacted evidence source bytes must match --evidence-sha")
    for relative, content in [(MANIFEST_NAME, bundle.manifest_bytes), *bundle.files.items()]:
        if git_file_bytes(root, evidence_sha, f"{bundle.relative_dir}/{relative}") != content:
            fail(f"reviewed bundle file must match --evidence-sha: {relative}")
    return project_payload(evidence, source, hashlib.sha256(data).hexdigest(), bundle, source_sha=source_sha, evidence_sha=evidence_sha)


def validate_signed_payload(root: Path, signed: dict[str, Any], requirement_id: str, journeys: list[str]) -> list[str]:
    """Governance re-validation of a signed payload against its committed source."""
    errors: list[str] = []
    journey_id = signed.get("journey_id")
    profile = PROFILES_BY_JOURNEY.get(journey_id) if isinstance(journey_id, str) else None
    if profile is None:
        return [f"signed.journey_id must be one of {sorted(PROFILES_BY_JOURNEY)}"]
    if profile.journey_id not in journeys:
        errors.append(f"privacy-class beta requirement journeys must include {profile.journey_id!r}")
    artifacts = signed.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 2 or not all(isinstance(item, dict) for item in artifacts):
        return errors + ["signed.artifacts must be exactly the redacted evidence and its bundle manifest"]
    source = artifacts[0].get("source")
    if artifacts[0].get("id") != profile.artifact_id or not isinstance(source, str):
        return errors + [f"signed.artifacts[0] must be {profile.artifact_id}"]
    repository = signed.get("repository")
    evidence_repository = signed.get("evidence_repository")
    if not isinstance(repository, dict) or not isinstance(evidence_repository, dict):
        return errors + ["signed payload must bind repository and evidence_repository"]
    try:
        evidence, data = load_evidence(root, source)
        bundle = validate_evidence(root, source, evidence)
        if release_identity(bundle)["source_commit"] != repository.get("commit"):
            fail("signed.repository.commit must equal the source commit bound by step-01")
        expected = project_payload(
            evidence,
            source,
            hashlib.sha256(data).hexdigest(),
            bundle,
            source_sha=str(repository.get("commit")),
            evidence_sha=str(evidence_repository.get("commit")),
        )
    except PrivacyEvidenceError as exc:
        return errors + [f"signed.artifacts[0].source: {exc}"]
    if requirement_id not in expected["requirement_ids"]:
        errors.append(f"privacy-class beta journey-result cannot promote {requirement_id}")
    if signed != expected:
        differing = sorted(key for key in set(signed) | set(expected) if signed.get(key) != expected.get(key))
        errors.append(f"signed payload must equal the builder projection of its source evidence (differs: {differing})")
    return errors
