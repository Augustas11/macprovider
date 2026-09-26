#!/usr/bin/env python3
"""Offline-only Gate A5 focal-row OPoI paired-evidence counter (schema v4)."""

import argparse
import base64
import hashlib
import json
import math
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from collections import Counter
from datetime import datetime
from datetime import timezone
from pathlib import Path


VERSION = 4
INPUT_SCHEMA = "malibu.gate_a5_opoi_completed_evidence"
PLAN_SCHEMA = "malibu.gate_a5_opoi_plan"
RECEIPT_SCHEMA = "malibu.gate_a5_opoi_plan_receipt"
RAW_SCHEMA = "malibu.gate_a5_opoi_raw_events"
SOURCE_REVIEW_SCHEMA = "malibu.gate_a5_opoi_source_review"
REPORT_SCHEMA = "malibu.gate_a5_opoi_false_positive_report"

COUNTER_REVISION = "gate-a5-focal-row-opoi-counter-v4"
PLAN_NAMESPACE = "malibu-gate-a5-opoi-plan-v4"
RECEIPT_NAMESPACE = "malibu-gate-a5-opoi-plan-receipt-v4"
SOURCE_REVIEW_NAMESPACE = "malibu-gate-a5-opoi-source-review-v4"
EVIDENCE_NAMESPACE = "malibu-gate-a5-opoi-evidence-v4"
SSH_KEYGEN = "/usr/bin/ssh-keygen"

MIN_SAMPLE_SIZE = 60
MAX_PAIRS = 4096
THRESHOLD = 0.05
CONFIDENCE_LEVEL = 0.95
MAX_INPUT_BYTES = 4 << 20
MAX_RAW_BYTES = 8 << 20
MAX_AUXILIARY_BYTES = 1 << 20
MAX_REPORT_BYTES = 16 << 20
MAX_JSONL_LINE_BYTES = 256 << 10
MAX_TOKENS = 250_000
MAX_DEPTH = 12
MAX_STRING = 4096
MAX_NUMBER_TOKEN = 32

HEX_DIGEST = re.compile(r"^[0-9a-f]{64}$")
PRINCIPAL = re.compile(r"^[A-Za-z0-9._@+-]{1,128}$")
KEY_TYPE = re.compile(
    r"^(ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)|ssh-rsa)$"
)

TUPLE_FIELDS = frozenset(
    {
        "hardware",
        "model",
        "quantization",
        "kv_mode",
        "runtime_revision",
        "binary_version",
    }
)
CAMPAIGN_FIELDS = frozenset({"campaign_id", "provider_id", "run_id"})
ARTIFACT_FIELDS = frozenset(
    {"packaged_artifact_sha256", "runtime_bundle_sha256"}
)
EVALUATOR_FIELDS = frozenset(
    {"evaluator_revision", "challenge_bank_revision"}
)
WINDOW_FIELDS = frozenset({"start", "end"})
PLAN_FIELDS = frozenset(
    {
        "schema",
        "version",
        "campaign",
        "tuple",
        "artifact",
        "evaluator",
        "window",
        "max_pair_gap_seconds",
        "sampling_design",
        "scheduled_pairs",
    }
)
SAMPLING_FIELDS = frozenset(
    {
        "selection_method",
        "selection_seed",
        "frame_revision",
        "frame_sha256",
        "candidate_frame",
        "workload_strata",
        "challenge_design",
        "arm_order_method",
    }
)
FRAME_FIELDS = frozenset(
    {"challenge_id", "workload_stratum", "challenge_payload_sha256"}
)
SCHEDULE_FIELDS = frozenset(
    {
        "pair_id",
        "selection_index",
        "selection_digest",
        "challenge_id",
        "challenge_payload_sha256",
        "challenge_issuance_id",
        "workload_stratum",
        "scheduled_at",
        "arm_order",
        "batch_request_id",
        "batch_event_id",
        "serial_request_id",
        "serial_event_id",
        "intended_batch_depth",
        "companions",
    }
)
SCHEDULE_STRING_FIELDS = frozenset(
    {
        "pair_id",
        "selection_digest",
        "challenge_id",
        "challenge_issuance_id",
        "workload_stratum",
        "scheduled_at",
        "arm_order",
        "batch_request_id",
        "batch_event_id",
        "serial_request_id",
        "serial_event_id",
    }
)
COMPANION_FIELDS = frozenset(
    {
        "request_id",
        "event_id",
        "row_index",
        "challenge_id",
        "challenge_payload_sha256",
        "workload_stratum",
    }
)
COMPANION_STRING_FIELDS = frozenset(
    {"request_id", "event_id", "challenge_id", "workload_stratum"}
)
DOCUMENT_FIELDS = frozenset(
    {
        "schema",
        "version",
        "plan",
        "plan_sha256",
        "plan_receipt",
        "raw_bundle_sha256",
        "source_review",
        "pairs",
    }
)
RECEIPT_FIELDS = frozenset(
    {"schema", "version", "plan_sha256", "received_at"}
)
SOURCE_REVIEW_FIELDS = frozenset(
    {
        "schema",
        "version",
        "plan_sha256",
        "raw_bundle_sha256",
        "reviewer_identity",
        "reviewer_role",
        "reviewed_at",
        "disposition",
    }
)
PAIR_FIELDS = frozenset({"pair_id", "batching", "serial_control"})
RAW_FIELDS = frozenset({"schema", "version", "captures"})
CAPTURE_FIELDS = frozenset(
    {
        "locator",
        "identity",
        "challenge",
        "response",
        "evaluation",
        "runtime",
        "provenance",
        "observed_at",
    }
)
IDENTITY_FIELDS = frozenset(
    {"event_id", "pair_id", "arm", "request_id", "workload_stratum"}
)
CHALLENGE_FIELDS = frozenset(
    {"challenge_id", "challenge_issuance_id", "payload", "payload_sha256"}
)
RESPONSE_FIELDS = frozenset({"transcript", "transcript_sha256"})
EVALUATION_FIELDS = frozenset(
    {"evaluator_revision", "challenge_bank_revision", "output"}
)
EVALUATOR_OUTPUTS = frozenset({"pass", "fail"})
PROVENANCE_FIELDS = frozenset({"campaign", "tuple", "artifact"})
EVENT_FIELDS = frozenset(
    {
        "event_id",
        "observed_at",
        "campaign",
        "tuple",
        "artifact",
        "evaluator",
        "pair_id",
        "arm",
        "challenge_id",
        "challenge_issuance_id",
        "request_id",
        "workload_stratum",
        "opoi_pass",
        "execution",
        "source_capture_sha256",
    }
)
EVENT_STRING_FIELDS = frozenset(
    {
        "event_id",
        "observed_at",
        "pair_id",
        "arm",
        "challenge_id",
        "challenge_issuance_id",
        "request_id",
        "workload_stratum",
    }
)
EXECUTION_FIELDS = frozenset(
    {"mode", "forward_id", "row_count", "row_index", "members"}
)
MEMBER_FIELDS = frozenset(
    {
        "event_id",
        "request_id",
        "row_index",
        "challenge_id",
        "challenge_payload_sha256",
        "workload_stratum",
    }
)
MEMBER_STRING_FIELDS = frozenset(
    {"event_id", "request_id", "challenge_id", "workload_stratum"}
)


class InputError(ValueError):
    """A stable, reason-coded rejection of untrusted campaign input."""


def canonical_json(value):
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode()
    except (OverflowError, RecursionError, TypeError, ValueError) as error:
        raise InputError("canonicalization_failed") from error


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def exact_object(value, fields):
    return isinstance(value, dict) and set(value) == fields


def nonempty_string(value):
    return isinstance(value, str) and bool(value.strip()) and len(value) <= MAX_STRING


def strict_int(value):
    return type(value) is int


def digest_string(value):
    return isinstance(value, str) and HEX_DIGEST.fullmatch(value) is not None


def utf8_digest_matches(value, expected):
    if not isinstance(value, str) or not digest_string(expected):
        return False
    try:
        return expected == sha256(value.encode())
    except UnicodeError:
        return False


def parse_utc(value):
    if not nonempty_string(value):
        raise InputError("utc_timestamp_invalid")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        offset = parsed.utcoffset()
    except (AttributeError, OverflowError, TypeError, ValueError) as error:
        raise InputError("utc_timestamp_invalid") from error
    if parsed.tzinfo is None or offset != timezone.utc.utcoffset(parsed):
        raise InputError("utc_timestamp_invalid")
    return parsed


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InputError("duplicate_json_key")
        result[key] = value
    return result


def bounded_int(token):
    if len(token.lstrip("-")) > MAX_NUMBER_TOKEN:
        raise InputError("numeric_token_too_long")
    return int(token)


def prescan_json(text):
    tokens = 0
    index = 0
    quoted = False
    escaped = False
    while index < len(text):
        character = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
                tokens += 1
        elif character == '"':
            quoted = True
        elif character in "{}[],:":
            tokens += 1
        elif character == "-" or character.isdigit():
            end = index + 1
            while end < len(text) and text[end] in "0123456789+-.eE":
                end += 1
            if end - index > MAX_NUMBER_TOKEN:
                raise InputError("numeric_token_too_long")
            tokens += 1
            index = end - 1
        elif character in "tfn":
            tokens += 1
        if tokens > MAX_TOKENS:
            raise InputError("structural_token_limit_exceeded")
        index += 1
    if quoted:
        raise InputError("malformed_json")


def loads_bounded(raw):
    try:
        text = raw.decode()
        prescan_json(text)
        value = json.loads(
            text,
            object_pairs_hook=reject_duplicate_keys,
            parse_int=bounded_int,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                InputError("non_finite_json_number")
            ),
        )
    except InputError:
        raise
    except (OverflowError, RecursionError, TypeError, UnicodeError, ValueError) as error:
        raise InputError("malformed_json") from error

    stack = [(value, 1)]
    nodes = 0
    while stack:
        current, depth = stack.pop()
        nodes += 1
        if nodes > MAX_TOKENS:
            raise InputError("structural_token_limit_exceeded")
        if depth > MAX_DEPTH:
            raise InputError("nesting_limit_exceeded")
        if isinstance(current, str) and len(current) > MAX_STRING:
            raise InputError("string_limit_exceeded")
        if isinstance(current, dict):
            stack.extend((item, depth + 1) for item in current.values())
        elif isinstance(current, list):
            stack.extend((item, depth + 1) for item in current)
    return value


def read_limited_stream(stream, limit):
    chunks = []
    remaining = limit + 1
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    data = b"".join(chunks)
    if len(data) > limit:
        raise InputError("input_too_large")
    return data


def readfile(
    path,
    limit,
    unreadable_reason="input_unreadable",
    irregular_reason="input_not_regular_file",
):
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise InputError(irregular_reason)
        if metadata.st_size > limit:
            raise InputError("input_too_large")

        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > limit:
            raise InputError("input_too_large")
        return data
    except InputError:
        raise
    except OSError as error:
        raise InputError(unreadable_reason) from error
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def load_document(path):
    if str(path) == "-":
        raw = read_limited_stream(sys.stdin.buffer, MAX_INPUT_BYTES)
    else:
        raw = readfile(path, MAX_INPUT_BYTES)

    if str(path) != "-" and Path(path).suffix == ".jsonl":
        rows = []
        for line in raw.splitlines():
            if len(line) > MAX_JSONL_LINE_BYTES:
                raise InputError("jsonl_line_too_large")
            if line.strip():
                rows.append(loads_bounded(line))
        if (
            not rows
            or not isinstance(rows[0], dict)
            or "pairs" in rows[0]
            or any(not isinstance(row, dict) for row in rows[1:])
        ):
            raise InputError("jsonl_header_invalid")
        document = dict(rows[0])
        document["pairs"] = rows[1:]
        return document
    return loads_bounded(raw)


def frame_rank_digest(sampling, entry):
    if not isinstance(sampling, dict) or not exact_object(entry, FRAME_FIELDS):
        raise InputError("selection_input_invalid")
    if not all(
        nonempty_string(entry.get(field))
        for field in ("challenge_id", "workload_stratum")
    ) or not digest_string(entry.get("challenge_payload_sha256")):
        raise InputError("selection_input_invalid")
    seed = sampling.get("selection_seed")
    revision = sampling.get("frame_revision")
    if not nonempty_string(seed) or not nonempty_string(revision):
        raise InputError("selection_input_invalid")
    return sha256(canonical_json({"seed": seed, "frame_revision": revision, "entry": entry}))


def ranked_frame(sampling):
    frame = sampling.get("candidate_frame") if isinstance(sampling, dict) else None
    if not isinstance(frame, list):
        raise InputError("selection_input_invalid")
    ranked = {stratum: [] for stratum in sampling.get("workload_strata", [])}
    for entry in frame:
        if not exact_object(entry, FRAME_FIELDS):
            raise InputError("selection_input_invalid")
        stratum = entry.get("workload_stratum")
        if stratum not in ranked:
            raise InputError("selection_input_invalid")
        ranked[stratum].append((frame_rank_digest(sampling, entry), entry))
    for entries in ranked.values():
        entries.sort(key=lambda item: (item[0], canonical_json(item[1])))
    return ranked


def expected_selection(sampling, index):
    if not strict_int(index) or index < 0:
        raise InputError("selection_input_invalid")
    strata = sampling.get("workload_strata") if isinstance(sampling, dict) else None
    if not isinstance(strata, list) or not strata:
        raise InputError("selection_input_invalid")
    stratum = strata[index % len(strata)]
    ordinal = index // len(strata)
    ranked = ranked_frame(sampling).get(stratum, [])
    if ordinal >= len(ranked):
        raise InputError("selection_input_invalid")
    digest, entry = ranked[ordinal]
    return stratum, ordinal, digest, entry


def selection_digest(sampling, scheduled_pair):
    if not isinstance(scheduled_pair, dict):
        raise InputError("selection_input_invalid")
    _stratum, _ordinal, digest, _entry = expected_selection(
        sampling, scheduled_pair.get("selection_index")
    )
    return digest


def expected_arm_order(seed, stratum, ordinal):
    if (
        not nonempty_string(seed)
        or not nonempty_string(stratum)
        or not strict_int(ordinal)
        or ordinal < 0
    ):
        raise InputError("arm_order_input_invalid")
    seed_is_even = int(sha256((seed + "|" + stratum).encode())[0], 16) % 2 == 0
    return (
        "batch_then_serial"
        if seed_is_even == (ordinal % 2 == 0)
        else "serial_then_batch"
    )


def validate_named_strings(value, fields, digest_fields=frozenset()):
    if not exact_object(value, fields):
        return False
    for field, item in value.items():
        if field in digest_fields:
            if not digest_string(item):
                return False
        elif not nonempty_string(item):
            return False
    return True


def validate_sampling_design(sampling):
    if not exact_object(sampling, SAMPLING_FIELDS):
        return False
    if (
        sampling.get("selection_method")
        != "sha256_ranked_without_replacement"
        or sampling.get("challenge_design") != "unique_without_replacement"
        or sampling.get("arm_order_method") != "seeded_balanced_alternation"
        or not nonempty_string(sampling.get("selection_seed"))
        or not nonempty_string(sampling.get("frame_revision"))
        or not digest_string(sampling.get("frame_sha256"))
    ):
        return False
    strata = sampling.get("workload_strata")
    if not isinstance(strata, list) or not strata:
        return False
    if not all(nonempty_string(stratum) for stratum in strata):
        return False
    if len(set(strata)) != len(strata):
        return False
    frame = sampling.get("candidate_frame")
    if not isinstance(frame, list) or not frame or len(frame) > MAX_PAIRS * 4:
        return False
    identities = []
    for entry in frame:
        if (
            not exact_object(entry, FRAME_FIELDS)
            or not nonempty_string(entry.get("challenge_id"))
            or entry.get("workload_stratum") not in strata
            or not digest_string(entry.get("challenge_payload_sha256"))
        ):
            return False
        identities.append(entry["challenge_id"])
    try:
        frame_digest = sha256(canonical_json(frame))
    except InputError:
        return False
    return (
        len(set(identities)) == len(identities)
        and sampling["frame_sha256"] == frame_digest
        and all(
            any(entry["workload_stratum"] == stratum for entry in frame)
            for stratum in strata
        )
    )


def validate_companion_schedule(companion, intended_depth):
    if not exact_object(companion, COMPANION_FIELDS):
        return False
    if not all(
        nonempty_string(companion.get(field)) for field in COMPANION_STRING_FIELDS
    ):
        return False
    row_index = companion.get("row_index")
    return (
        digest_string(companion.get("challenge_payload_sha256"))
        and strict_int(row_index)
        and 1 <= row_index < intended_depth
    )


def validate_plan(plan):
    reasons = []
    if not exact_object(plan, PLAN_FIELDS):
        return ["plan_fields_invalid"]
    if (
        plan.get("schema") != PLAN_SCHEMA
        or not strict_int(plan.get("version"))
        or plan.get("version") != VERSION
    ):
        reasons.append("plan_schema_version_invalid")
    if not validate_named_strings(plan.get("campaign"), CAMPAIGN_FIELDS):
        reasons.append("campaign_invalid")
    if not validate_named_strings(plan.get("tuple"), TUPLE_FIELDS):
        reasons.append("tuple_invalid")
    if not validate_named_strings(
        plan.get("artifact"), ARTIFACT_FIELDS, ARTIFACT_FIELDS
    ):
        reasons.append("artifact_invalid")
    if not validate_named_strings(plan.get("evaluator"), EVALUATOR_FIELDS):
        reasons.append("evaluator_invalid")

    window = plan.get("window")
    if not exact_object(window, WINDOW_FIELDS):
        reasons.append("window_invalid")
    else:
        try:
            start = parse_utc(window.get("start"))
            end = parse_utc(window.get("end"))
            if not 0 < (end - start).total_seconds() <= 3600:
                reasons.append("window_invalid")
        except InputError:
            reasons.append("window_invalid")

    maximum_gap = plan.get("max_pair_gap_seconds")
    if not strict_int(maximum_gap) or not 0 < maximum_gap <= 60:
        reasons.append("max_pair_gap_invalid")

    sampling = plan.get("sampling_design")
    if not validate_sampling_design(sampling):
        reasons.append("sampling_design_invalid")
        sampling = None

    scheduled_pairs = plan.get("scheduled_pairs")
    if not isinstance(scheduled_pairs, list):
        return sorted(set(reasons + ["scheduled_pairs_invalid"]))
    if not MIN_SAMPLE_SIZE <= len(scheduled_pairs) <= MAX_PAIRS:
        reasons.append("sample_size_invalid")

    pair_ids = Counter()
    issuance_ids = Counter()
    request_ids = Counter()
    event_ids = Counter()
    challenge_ids = Counter()
    stratum_counts = Counter()
    stratum_orders = {}

    for index, scheduled in enumerate(scheduled_pairs):
        if not exact_object(scheduled, SCHEDULE_FIELDS):
            reasons.append("scheduled_pair_invalid")
            continue
        if not all(
            nonempty_string(scheduled.get(field))
            for field in SCHEDULE_STRING_FIELDS
        ):
            reasons.append("scheduled_pair_invalid")
            continue
        if not digest_string(scheduled.get("selection_digest")):
            reasons.append("selection_invalid")
        if not digest_string(scheduled.get("challenge_payload_sha256")):
            reasons.append("selection_invalid")
        try:
            parse_utc(scheduled.get("scheduled_at"))
        except InputError:
            reasons.append("scheduled_time_invalid")

        selection_index = scheduled.get("selection_index")
        if not strict_int(selection_index) or selection_index != index:
            reasons.append("selection_invalid")
        elif sampling is not None:
            try:
                expected_stratum, ordinal, expected_digest, expected_entry = (
                    expected_selection(sampling, index)
                )
                if scheduled.get("selection_digest") != selection_digest(
                    sampling, scheduled
                ):
                    reasons.append("selection_invalid")
                if (
                    scheduled.get("workload_stratum") != expected_stratum
                    or scheduled.get("challenge_id") != expected_entry["challenge_id"]
                    or scheduled.get("challenge_payload_sha256")
                    != expected_entry["challenge_payload_sha256"]
                    or scheduled.get("selection_digest") != expected_digest
                ):
                    reasons.append("selection_frame_mismatch")
                if scheduled.get("arm_order") != expected_arm_order(
                    sampling["selection_seed"], expected_stratum, ordinal
                ):
                    reasons.append("arm_order_bias")
            except InputError:
                reasons.append("selection_invalid")

        stratum = scheduled.get("workload_stratum")
        if sampling is None or stratum not in sampling["workload_strata"]:
            reasons.append("stratum_invalid")
        else:
            stratum_counts[stratum] += 1
            stratum_orders.setdefault(stratum, Counter())[scheduled.get("arm_order")] += 1

        intended_depth = scheduled.get("intended_batch_depth")
        companions = scheduled.get("companions")
        if (
            not strict_int(intended_depth)
            or intended_depth < 2
            or not isinstance(companions, list)
            or len(companions) != intended_depth - 1
        ):
            reasons.append("companion_schedule_incomplete")
            companions = []
        else:
            valid_companions = all(
                validate_companion_schedule(companion, intended_depth)
                for companion in companions
            )
            row_indexes = {
                companion["row_index"]
                for companion in companions
                if validate_companion_schedule(companion, intended_depth)
            }
            if (
                not valid_companions
                or row_indexes != set(range(1, intended_depth))
            ):
                reasons.append("companion_schedule_invalid")

        pair_ids[scheduled["pair_id"]] += 1
        issuance_ids[scheduled["challenge_issuance_id"]] += 1
        request_ids[scheduled["batch_request_id"]] += 1
        request_ids[scheduled["serial_request_id"]] += 1
        event_ids[scheduled["batch_event_id"]] += 1
        event_ids[scheduled["serial_event_id"]] += 1
        challenge_ids[scheduled["challenge_id"]] += 1
        for companion in companions:
            if not validate_companion_schedule(companion, intended_depth):
                continue
            request_ids[companion["request_id"]] += 1
            event_ids[companion["event_id"]] += 1
            challenge_ids[companion["challenge_id"]] += 1

    identity_counters = (pair_ids, issuance_ids, request_ids, event_ids)
    if any(count > 1 for counter in identity_counters for count in counter.values()):
        reasons.append("duplicate_scheduled_identity")
    if any(count > 1 for count in challenge_ids.values()):
        reasons.append("challenge_selection_not_unique")
    if sampling is not None:
        expected_strata = set(sampling["workload_strata"])
        if (
            set(stratum_counts) != expected_strata
            or max(stratum_counts.values(), default=0)
            - min(stratum_counts.values(), default=0)
            > 1
        ):
            reasons.append("workload_strata_unbalanced")
        for stratum in expected_strata:
            orders = stratum_orders.get(stratum, Counter())
            if (
                set(orders) != {"batch_then_serial", "serial_then_batch"}
                or abs(orders["batch_then_serial"] - orders["serial_then_batch"]) > 1
            ):
                reasons.append("stratum_arm_order_unbalanced")
    return sorted(set(reasons))


def valid_schedule_map(plan):
    if validate_plan(plan):
        return {}
    return {scheduled["pair_id"]: scheduled for scheduled in plan["scheduled_pairs"]}


def expected_raw_event_ids(schedule):
    event_ids = set()
    for scheduled in schedule.values():
        event_ids.add(scheduled["batch_event_id"])
        event_ids.add(scheduled["serial_event_id"])
        event_ids.update(
            companion["event_id"] for companion in scheduled["companions"]
        )
    return event_ids


def validate_member(member):
    return (
        exact_object(member, MEMBER_FIELDS)
        and all(nonempty_string(member.get(field)) for field in MEMBER_STRING_FIELDS)
        and strict_int(member.get("row_index"))
        and member.get("row_index") >= 0
        and digest_string(member.get("challenge_payload_sha256"))
    )


def validate_execution(execution):
    if not exact_object(execution, EXECUTION_FIELDS):
        return False
    if not nonempty_string(execution.get("mode")):
        return False
    forward_id = execution.get("forward_id")
    if forward_id is not None and not nonempty_string(forward_id):
        return False
    if (
        not strict_int(execution.get("row_count"))
        or execution.get("row_count") < 1
        or not strict_int(execution.get("row_index"))
        or execution.get("row_index") < 0
    ):
        return False
    members = execution.get("members")
    return isinstance(members, list) and all(validate_member(member) for member in members)


def validate_event_shape(event):
    if not exact_object(event, EVENT_FIELDS):
        return False
    if not all(nonempty_string(event.get(field)) for field in EVENT_STRING_FIELDS):
        return False
    try:
        parse_utc(event.get("observed_at"))
    except InputError:
        return False
    return (
        validate_named_strings(event.get("campaign"), CAMPAIGN_FIELDS)
        and validate_named_strings(event.get("tuple"), TUPLE_FIELDS)
        and validate_named_strings(
            event.get("artifact"), ARTIFACT_FIELDS, ARTIFACT_FIELDS
        )
        and validate_named_strings(event.get("evaluator"), EVALUATOR_FIELDS)
        and type(event.get("opoi_pass")) is bool
        and digest_string(event.get("source_capture_sha256"))
        and validate_execution(event.get("execution"))
    )


def validate_source_capture(capture):
    if not exact_object(capture, CAPTURE_FIELDS):
        return False
    identity = capture.get("identity")
    challenge = capture.get("challenge")
    response = capture.get("response")
    evaluation = capture.get("evaluation")
    runtime = capture.get("runtime")
    provenance = capture.get("provenance")
    if (
        not nonempty_string(capture.get("locator"))
        or not exact_object(identity, IDENTITY_FIELDS)
        or not all(nonempty_string(value) for value in identity.values())
        or not exact_object(challenge, CHALLENGE_FIELDS)
        or not nonempty_string(challenge.get("challenge_id"))
        or not nonempty_string(challenge.get("challenge_issuance_id"))
        or not nonempty_string(challenge.get("payload"))
        or not utf8_digest_matches(
            challenge.get("payload"),
            challenge.get("payload_sha256"),
        )
        or not exact_object(response, RESPONSE_FIELDS)
        or not nonempty_string(response.get("transcript"))
        or not utf8_digest_matches(
            response.get("transcript"),
            response.get("transcript_sha256"),
        )
        or not exact_object(evaluation, EVALUATION_FIELDS)
        or not nonempty_string(evaluation.get("evaluator_revision"))
        or not nonempty_string(evaluation.get("challenge_bank_revision"))
        or evaluation.get("output") not in EVALUATOR_OUTPUTS
        or not validate_execution(runtime)
        or not exact_object(provenance, PROVENANCE_FIELDS)
        or not validate_named_strings(provenance.get("campaign"), CAMPAIGN_FIELDS)
        or not validate_named_strings(provenance.get("tuple"), TUPLE_FIELDS)
        or not validate_named_strings(
            provenance.get("artifact"),
            ARTIFACT_FIELDS,
            ARTIFACT_FIELDS,
        )
    ):
        return False
    try:
        parse_utc(capture.get("observed_at"))
    except InputError:
        return False
    return True


def derive_event(capture):
    if not validate_source_capture(capture):
        raise InputError("source_capture_invalid")
    identity = capture["identity"]
    challenge = capture["challenge"]
    evaluation = capture["evaluation"]
    provenance = capture["provenance"]
    return {
        "event_id": identity["event_id"],
        "observed_at": capture["observed_at"],
        "campaign": provenance["campaign"],
        "tuple": provenance["tuple"],
        "artifact": provenance["artifact"],
        "evaluator": {
            "evaluator_revision": evaluation["evaluator_revision"],
            "challenge_bank_revision": evaluation["challenge_bank_revision"],
        },
        "pair_id": identity["pair_id"],
        "arm": identity["arm"],
        "challenge_id": challenge["challenge_id"],
        "challenge_issuance_id": challenge["challenge_issuance_id"],
        "request_id": identity["request_id"],
        "workload_stratum": identity["workload_stratum"],
        "opoi_pass": evaluation["output"] == "pass",
        "execution": capture["runtime"],
        "source_capture_sha256": sha256(canonical_json(capture)),
    }


def parse_raw_bundle(raw, expected_ids):
    reasons = []
    records = {}
    if (
        not exact_object(raw, RAW_FIELDS)
        or raw.get("schema") != RAW_SCHEMA
        or not strict_int(raw.get("version"))
        or raw.get("version") != VERSION
        or not isinstance(raw.get("captures"), list)
    ):
        return {}, ["raw_bundle_invalid"]

    locators = set()
    for capture in raw["captures"]:
        if not validate_source_capture(capture):
            reasons.append("source_capture_invalid")
            continue
        locator = capture["locator"]
        if locator in locators:
            reasons.append("source_locator_replayed")
            continue
        locators.add(locator)
        event = derive_event(capture)
        event_id = event["event_id"]
        if event_id in records:
            reasons.append("source_event_identity_replayed")
            continue
        records[event_id] = {"capture": capture, "event": event}

    if set(records) != expected_ids:
        reasons.append("source_event_identity_set_mismatch")
    return records, sorted(set(reasons))


def validate_trust_file(path, principal, role):
    data = readfile(
        path,
        MAX_AUXILIARY_BYTES,
        role + "_trust_unreadable",
        role + "_trust_not_regular_file",
    )
    try:
        lines = data.decode().splitlines()
        parts = lines[0].split(" ")
        valid = (
            len(lines) == 1
            and len(parts) == 3
            and parts[0] == principal
            and isinstance(principal, str)
            and PRINCIPAL.fullmatch(principal) is not None
            and KEY_TYPE.fullmatch(parts[1]) is not None
            and "*" not in principal
            and "," not in principal
        )
        if not valid:
            raise ValueError
        key_blob = base64.b64decode(parts[2], validate=True)
        if not key_blob:
            raise ValueError
    except (IndexError, TypeError, UnicodeError, ValueError) as error:
        raise InputError(role + "_trust_invalid") from error
    fingerprint = (
        "SHA256:"
        + base64.b64encode(hashlib.sha256(key_blob).digest()).decode().rstrip("=")
    )
    return data, fingerprint


def verify_signature(payload, signature_path, trust, principal, namespace, role):
    signature = readfile(
        signature_path,
        MAX_AUXILIARY_BYTES,
        role + "_signature_unreadable",
        role + "_signature_not_regular_file",
    )
    with tempfile.TemporaryDirectory() as directory:
        signature_copy = Path(directory) / "signature"
        trust_copy = Path(directory) / "trust"
        signature_copy.write_bytes(signature)
        trust_copy.write_bytes(trust)
        try:
            result = subprocess.run(
                [
                    SSH_KEYGEN,
                    "-Y",
                    "verify",
                    "-f",
                    str(trust_copy),
                    "-I",
                    principal,
                    "-n",
                    namespace,
                    "-s",
                    str(signature_copy),
                ],
                input=canonical_json(payload),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise InputError(role + "_verifier_failed") from error
    if result.returncode:
        raise InputError(role + "_signature_invalid")
    return sha256(signature)


def verify_authenticity(document, paths, principals):
    if not isinstance(document, dict):
        raise InputError("document_fields_invalid")
    payloads = {
        "plan": document.get("plan"),
        "receipt": document.get("plan_receipt"),
        "source_review": document.get("source_review"),
        "evidence": document,
    }
    if any(not isinstance(payloads[role], dict) for role in payloads):
        raise InputError("authenticity_payload_invalid")
    if payloads["source_review"].get("reviewer_identity") != principals.get("reviewer"):
        raise InputError("source_review_identity_mismatch")

    result = {"scheme": "ssh-signature", "verified": True}
    fingerprints = []
    namespaces = {
        "plan": PLAN_NAMESPACE,
        "receipt": RECEIPT_NAMESPACE,
        "source_review": SOURCE_REVIEW_NAMESPACE,
        "evidence": EVIDENCE_NAMESPACE,
    }
    trust_roles = {
        "plan": "plan",
        "receipt": "reviewer",
        "source_review": "reviewer",
        "evidence": "evidence",
    }
    for role in ("plan", "receipt", "source_review", "evidence"):
        trust_role = trust_roles[role]
        trust, fingerprint = validate_trust_file(
            paths[trust_role + "_trust"], principals[trust_role], role
        )
        fingerprints.append(fingerprint)
        result[role] = {
            "namespace": namespaces[role],
            "signer_principal": principals[trust_role],
            "key_fingerprint": fingerprint,
            "trust_sha256": sha256(trust),
            "signature_sha256": verify_signature(
                payloads[role],
                paths[role + "_signature"],
                trust,
                principals[trust_role],
                namespaces[role],
                role,
            ),
        }
    if len(set(principals.values())) < 3:
        raise InputError("signer_principals_not_independent")
    if len(set(fingerprints)) < 3:
        raise InputError("signer_fingerprints_not_independent")
    return result


def binomial_cdf(successes, trials, probability):
    if probability <= 0:
        return 1.0
    if probability >= 1:
        return 1.0 if successes >= trials else 0.0
    log_probability = math.log(probability)
    log_inverse = math.log1p(-probability)
    log_terms = [
        math.lgamma(trials + 1)
        - math.lgamma(index + 1)
        - math.lgamma(trials - index + 1)
        + index * log_probability
        + (trials - index) * log_inverse
        for index in range(successes + 1)
    ]
    maximum = max(log_terms)
    scaled_sum = math.fsum(math.exp(term - maximum) for term in log_terms)
    try:
        return min(1.0, math.exp(maximum) * scaled_sum)
    except OverflowError:
        return 1.0


def clopper_pearson_upper(successes, trials):
    if not trials:
        return None
    if successes >= trials:
        return 1.0
    lower = successes / trials
    upper = 1.0
    alpha = 1.0 - CONFIDENCE_LEVEL
    for _iteration in range(80):
        midpoint = (lower + upper) / 2.0
        if binomial_cdf(successes, trials, midpoint) > alpha:
            lower = midpoint
        else:
            upper = midpoint
    return upper


def counter_source_sha256():
    try:
        return sha256(Path(__file__).read_bytes())
    except OSError as error:
        raise InputError("counter_source_unreadable") from error


def empty_report(reason, canonical_input_digest=None):
    return {
        "schema": REPORT_SCHEMA,
        "version": VERSION,
        "counter_revision": COUNTER_REVISION,
        "counter_source_sha256": counter_source_sha256(),
        "canonical_input_sha256": canonical_input_digest,
        "plan_sha256": None,
        "raw_bundle_sha256": None,
        "authenticity": None,
        "focal_row_zero_eligible_denominator": 0,
        "focal_row_zero_false_positive_numerator": 0,
        "focal_row_zero_false_positive_rate": None,
        "threshold": THRESHOLD,
        "one_sided_confidence_level": CONFIDENCE_LEVEL,
        "focal_row_zero_false_positive_rate_upper_bound": None,
        "passed": False,
        "invalid_count": 0,
        "inconclusive_count": 0,
        "gate_reasons": [reason],
        "details": [],
        "enforcement_boundary": "offline_manual_future_release_quality_evidence_only",
    }


def validate_document(document):
    reasons = []
    if not exact_object(document, DOCUMENT_FIELDS):
        return ["document_fields_invalid"], {}, None
    if (
        document.get("schema") != INPUT_SCHEMA
        or not strict_int(document.get("version"))
        or document.get("version") != VERSION
    ):
        reasons.append("input_schema_version_invalid")

    plan = document.get("plan")
    plan_reasons = validate_plan(plan)
    reasons.extend(plan_reasons)
    plan_digest = sha256(canonical_json(plan))
    if not digest_string(document.get("plan_sha256")) or document.get(
        "plan_sha256"
    ) != plan_digest:
        reasons.append("plan_digest_mismatch")

    receipt = document.get("plan_receipt")
    if (
        not exact_object(receipt, RECEIPT_FIELDS)
        or receipt.get("schema") != RECEIPT_SCHEMA
        or not strict_int(receipt.get("version"))
        or receipt.get("version") != VERSION
        or receipt.get("plan_sha256") != plan_digest
    ):
        reasons.append("plan_receipt_mismatch")
    else:
        try:
            received_at = parse_utc(receipt.get("received_at"))
            window = plan.get("window") if isinstance(plan, dict) else None
            if not isinstance(window, dict):
                raise InputError("utc_timestamp_invalid")
            if received_at >= parse_utc(window.get("start")):
                reasons.append("plan_receipt_not_pre_window")
        except InputError:
            reasons.append("plan_receipt_time_invalid")

    if not digest_string(document.get("raw_bundle_sha256")):
        reasons.append("raw_bundle_digest_invalid")
    source_review = document.get("source_review")
    if (
        not exact_object(source_review, SOURCE_REVIEW_FIELDS)
        or source_review.get("schema") != SOURCE_REVIEW_SCHEMA
        or not strict_int(source_review.get("version"))
        or source_review.get("version") != VERSION
        or source_review.get("plan_sha256") != plan_digest
        or source_review.get("raw_bundle_sha256") != document.get("raw_bundle_sha256")
        or not nonempty_string(source_review.get("reviewer_identity"))
        or source_review.get("reviewer_role") != "independent_source_reviewer"
        or source_review.get("disposition") != "approved"
    ):
        reasons.append("source_review_mismatch")
    else:
        try:
            reviewed_at = parse_utc(source_review.get("reviewed_at"))
            if reviewed_at < parse_utc(plan["window"]["end"]):
                reasons.append("source_review_not_post_collection")
        except (InputError, KeyError, TypeError):
            reasons.append("source_review_time_invalid")
    pairs = document.get("pairs")
    if not isinstance(pairs, list):
        reasons.append("document_pairs_invalid")
    elif len(pairs) > MAX_PAIRS:
        reasons.append("document_pairs_too_many")

    schedule = valid_schedule_map(plan)
    return sorted(set(reasons)), schedule, plan_digest


def expected_members(scheduled):
    members = [
        {
            "event_id": scheduled["batch_event_id"],
            "request_id": scheduled["batch_request_id"],
            "row_index": 0,
            "challenge_id": scheduled["challenge_id"],
            "challenge_payload_sha256": scheduled["challenge_payload_sha256"],
            "workload_stratum": scheduled["workload_stratum"],
        }
    ]
    members.extend(
        {
            "event_id": companion["event_id"],
            "request_id": companion["request_id"],
            "row_index": companion["row_index"],
            "challenge_id": companion["challenge_id"],
            "challenge_payload_sha256": companion["challenge_payload_sha256"],
            "workload_stratum": companion["workload_stratum"],
        }
        for companion in scheduled["companions"]
    )
    return members


def binding_mismatches(event, plan, scheduled, arm, companion=None):
    expected = {
        "campaign": plan["campaign"],
        "tuple": plan["tuple"],
        "artifact": plan["artifact"],
        "evaluator": plan["evaluator"],
        "pair_id": scheduled["pair_id"],
        "arm": arm,
        "challenge_issuance_id": scheduled["challenge_issuance_id"],
    }
    if companion is None:
        expected.update(
            {
                "challenge_id": scheduled["challenge_id"],
                "workload_stratum": scheduled["workload_stratum"],
                "event_id": scheduled[
                    "batch_event_id" if arm == "batching" else "serial_event_id"
                ],
                "request_id": scheduled[
                    "batch_request_id"
                    if arm == "batching"
                    else "serial_request_id"
                ],
            }
        )
    else:
        expected.update(
            {
                "challenge_id": companion["challenge_id"],
                "workload_stratum": companion["workload_stratum"],
                "event_id": companion["event_id"],
                "request_id": companion["request_id"],
            }
        )
    return any(event.get(field) != value for field, value in expected.items())


def source_binding_mismatches(capture, plan, scheduled, companion=None):
    challenge = capture.get("challenge", {})
    evaluation = capture.get("evaluation", {})
    expected_payload = (
        scheduled["challenge_payload_sha256"]
        if companion is None
        else companion["challenge_payload_sha256"]
    )
    return (
        challenge.get("payload_sha256") != expected_payload
        or evaluation.get("evaluator_revision") != plan["evaluator"]["evaluator_revision"]
        or evaluation.get("challenge_bank_revision")
        != plan["evaluator"]["challenge_bank_revision"]
    )


def validate_pair_timing(pair, plan, scheduled):
    reasons = []
    try:
        batch_time = parse_utc(pair["batching"]["observed_at"])
        serial_time = parse_utc(pair["serial_control"]["observed_at"])
        scheduled_time = parse_utc(scheduled["scheduled_at"])
        window_start = parse_utc(plan["window"]["start"])
        window_end = parse_utc(plan["window"]["end"])
        maximum_gap = plan["max_pair_gap_seconds"]
    except (InputError, KeyError, TypeError):
        return ["observation_time_invalid"]

    if (
        abs((batch_time - serial_time).total_seconds()) > maximum_gap
        or abs((batch_time - scheduled_time).total_seconds()) > maximum_gap
        or abs((serial_time - scheduled_time).total_seconds()) > maximum_gap
        or not (window_start <= batch_time < window_end)
        or not (window_start <= serial_time < window_end)
    ):
        reasons.append("observation_timing_invalid")
    arm_order = scheduled["arm_order"]
    if (
        arm_order == "batch_then_serial"
        and batch_time >= serial_time
        or arm_order == "serial_then_batch"
        and serial_time >= batch_time
    ):
        reasons.append("arm_order_observation_mismatch")
    return reasons


def validate_companion_events(records, plan, scheduled, batch_event, batch_execution):
    reasons = []
    used_ids = []
    try:
        batch_time = parse_utc(batch_event["observed_at"])
        scheduled_time = parse_utc(scheduled["scheduled_at"])
        window_start = parse_utc(plan["window"]["start"])
        window_end = parse_utc(plan["window"]["end"])
        maximum_gap = plan["max_pair_gap_seconds"]
    except (InputError, KeyError, TypeError):
        return ["batch_companion_time_invalid"], used_ids

    for companion in scheduled["companions"]:
        record = records.get(companion["event_id"])
        if record is None:
            reasons.append("batch_companion_missing")
            continue
        event = record["event"]
        used_ids.append(event["event_id"])
        if binding_mismatches(
            event, plan, scheduled, "batch_companion", companion
        ):
            reasons.append("batch_companion_binding_mismatch")
        execution = event.get("execution", {})
        members = execution.get("members")
        own_member = (
            members[companion["row_index"]]
            if isinstance(members, list) and len(members) > companion["row_index"]
            else None
        )
        if (
            source_binding_mismatches(record["capture"], plan, scheduled, companion)
            or execution.get("mode") != batch_execution.get("mode")
            or execution.get("forward_id") != batch_execution.get("forward_id")
            or execution.get("row_count") != batch_execution.get("row_count")
            or members != batch_execution.get("members")
            or execution.get("row_index") != companion["row_index"]
            or own_member != {
                "event_id": companion["event_id"],
                "request_id": companion["request_id"],
                "row_index": companion["row_index"],
                "challenge_id": companion["challenge_id"],
                "challenge_payload_sha256": companion["challenge_payload_sha256"],
                "workload_stratum": companion["workload_stratum"],
            }
        ):
            reasons.append("batch_companion_membership_mismatch")
        # Companion outcomes are retained and type-checked for auditability, but
        # are semantically ignored by the paired false-positive calculation.
        if type(event.get("opoi_pass")) is not bool:
            reasons.append("batch_companion_outcome_invalid")
        try:
            companion_time = parse_utc(event.get("observed_at"))
            if (
                not (window_start <= companion_time < window_end)
                or abs((companion_time - scheduled_time).total_seconds())
                > maximum_gap
                or abs((companion_time - batch_time).total_seconds()) > maximum_gap
            ):
                reasons.append("batch_companion_timing_invalid")
        except InputError:
            reasons.append("batch_companion_time_invalid")
    return sorted(set(reasons)), used_ids


def validate_observation_record(pair, key, records, plan, scheduled):
    reasons = []
    record = pair.get(key)
    if not validate_event_shape(record):
        return None, [key + "_raw_event_mismatch"]
    event = record
    event_id = event.get("event_id")
    source_record = records.get(event_id)
    if not isinstance(event_id, str) or source_record is None or event != source_record["event"]:
        return None, [key + "_raw_event_mismatch"]
    arm = "batching" if key == "batching" else "serial_control"
    if binding_mismatches(event, plan, scheduled, arm):
        reasons.append(key + "_binding_mismatch")
    if source_binding_mismatches(source_record["capture"], plan, scheduled):
        reasons.append(key + "_source_binding_mismatch")
    if type(event.get("opoi_pass")) is not bool:
        reasons.append(key + "_outcome_invalid")
    return event, reasons


def measure(document, raw_bundle, raw_bundle_digest, authenticity=None):
    canonical_input_digest = sha256(canonical_json(document))
    reasons, schedule, plan_digest = validate_document(document)
    plan = document.get("plan") if isinstance(document, dict) else None
    pairs = document.get("pairs") if isinstance(document, dict) else None

    if not isinstance(document, dict):
        raise InputError("document_fields_invalid")
    if document.get("raw_bundle_sha256") != raw_bundle_digest:
        reasons.append("raw_bundle_file_digest_mismatch")
    expected_ids = expected_raw_event_ids(schedule)
    records, raw_reasons = parse_raw_bundle(raw_bundle, expected_ids)
    reasons.extend(raw_reasons)
    if not isinstance(authenticity, dict) or authenticity.get("verified") is not True:
        reasons.append("authenticity_not_verified")

    if not isinstance(pairs, list):
        pairs = []
    pair_ids = Counter()
    for pair in pairs:
        if isinstance(pair, dict) and nonempty_string(pair.get("pair_id")):
            pair_ids[pair["pair_id"]] += 1
        else:
            pair_ids["<invalid>"] += 1
    if set(pair_ids) != set(schedule) or any(
        count != 1 for count in pair_ids.values()
    ):
        reasons.append("sampling_plan_incomplete")

    used_event_ids = Counter()
    forward_ids = Counter()
    eligible = 0
    numerator = 0
    invalid = 0
    inconclusive = 0
    details = []

    for index, pair in enumerate(pairs[:MAX_PAIRS]):
        pair_reasons = []
        pair_id = pair.get("pair_id") if isinstance(pair, dict) else None
        scheduled = schedule.get(pair_id) if isinstance(pair_id, str) else None
        batch_pass = None
        serial_pass = None

        if not exact_object(pair, PAIR_FIELDS) or scheduled is None:
            pair_reasons.append("pair_invalid")
        else:
            batch_event, batch_reasons = validate_observation_record(
                pair, "batching", records, plan, scheduled
            )
            serial_event, serial_reasons = validate_observation_record(
                pair, "serial_control", records, plan, scheduled
            )
            pair_reasons.extend(batch_reasons)
            pair_reasons.extend(serial_reasons)

            if batch_event is not None:
                used_event_ids[batch_event["event_id"]] += 1
                batch_pass = batch_event["opoi_pass"]
                execution = batch_event["execution"]
                expected_execution = {
                    "mode": "continuous_batching",
                    "forward_id": execution.get("forward_id"),
                    "row_count": scheduled["intended_batch_depth"],
                    "row_index": 0,
                    "members": expected_members(scheduled),
                }
                if (
                    not nonempty_string(execution.get("forward_id"))
                    or execution != expected_execution
                ):
                    pair_reasons.append("batch_membership_invalid")
                else:
                    forward_ids[execution["forward_id"]] += 1
                companion_reasons, companion_ids = validate_companion_events(
                    records, plan, scheduled, batch_event, execution
                )
                pair_reasons.extend(companion_reasons)
                used_event_ids.update(companion_ids)

            if serial_event is not None:
                used_event_ids[serial_event["event_id"]] += 1
                serial_pass = serial_event["opoi_pass"]
                serial_member = {
                    "event_id": serial_event["event_id"],
                    "request_id": serial_event["request_id"],
                    "row_index": 0,
                    "challenge_id": serial_event["challenge_id"],
                    "challenge_payload_sha256": scheduled["challenge_payload_sha256"],
                    "workload_stratum": serial_event["workload_stratum"],
                }
                expected_execution = {
                    "mode": "serial",
                    "forward_id": None,
                    "row_count": 1,
                    "row_index": 0,
                    "members": [serial_member],
                }
                if serial_event["execution"] != expected_execution:
                    pair_reasons.append("serial_execution_invalid")

            pair_reasons.extend(validate_pair_timing(pair, plan, scheduled))

        pair_reasons = sorted(set(pair_reasons))
        if pair_reasons:
            classification = "invalid"
            invalid += 1
        elif serial_pass is False:
            classification = "inconclusive"
            inconclusive += 1
            pair_reasons = ["serial_control_failed"]
        else:
            eligible += 1
            if batch_pass is False:
                numerator += 1
                classification = "false_positive"
                pair_reasons = ["batch_failed_serial_passed"]
            else:
                classification = "eligible_pass"
        details.append(
            {
                "index": index,
                "pair_id": pair_id,
                "classification": classification,
                "reasons": pair_reasons,
            }
        )

    if set(used_event_ids) != expected_ids or any(
        count != 1 for count in used_event_ids.values()
    ):
        reasons.append("replayed_or_unused_observation_identity")
    if any(count != 1 for count in forward_ids.values()):
        reasons.append("repeated_measured_forward_id")

    upper_bound = clopper_pearson_upper(numerator, eligible)
    rate = numerator / eligible if eligible else None
    if invalid:
        reasons.append("invalid_pairs_present")
    if inconclusive:
        reasons.append("inconclusive_pairs_present")
    if eligible < MIN_SAMPLE_SIZE:
        reasons.append("minimum_eligible_sample_not_met")
    if eligible and numerator * 100 >= eligible * 5:
        reasons.append("threshold_not_met")
    if upper_bound is None or upper_bound >= THRESHOLD:
        reasons.append("confidence_bound_not_met")

    reasons = sorted(set(reasons))
    return {
        "schema": REPORT_SCHEMA,
        "version": VERSION,
        "counter_revision": COUNTER_REVISION,
        "counter_source_sha256": counter_source_sha256(),
        "canonical_input_sha256": canonical_input_digest,
        "plan_sha256": plan_digest,
        "raw_bundle_sha256": raw_bundle_digest,
        "authenticity": authenticity,
        "focal_row_zero_eligible_denominator": eligible,
        "focal_row_zero_false_positive_numerator": numerator,
        "focal_row_zero_false_positive_rate": rate,
        "threshold": THRESHOLD,
        "one_sided_confidence_level": CONFIDENCE_LEVEL,
        "focal_row_zero_false_positive_rate_upper_bound": upper_bound,
        "passed": not reasons,
        "invalid_count": invalid,
        "inconclusive_count": inconclusive,
        "gate_reasons": reasons,
        "details": details,
        "enforcement_boundary": "offline_manual_future_release_quality_evidence_only",
    }


def write_all(descriptor, data):
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise OSError("short write")
        offset += written


def write_new(path, data):
    destination = Path(path)
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        directory = os.open(destination.parent, directory_flags)
    except OSError as error:
        raise InputError("output_parent_untrusted") from error

    temporary_name = "." + destination.name + "." + secrets.token_hex(8)
    descriptor = None
    try:
        descriptor = os.open(
            temporary_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory,
        )
        write_all(descriptor, data)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.link(
            temporary_name,
            destination.name,
            src_dir_fd=directory,
            dst_dir_fd=directory,
            follow_symlinks=False,
        )
        os.fsync(directory)
    except FileExistsError as error:
        raise InputError("output_already_exists") from error
    except OSError as error:
        raise InputError("output_write_failed") from error
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        try:
            os.unlink(temporary_name, dir_fd=directory)
        except FileNotFoundError:
            pass
        except OSError:
            pass
        try:
            os.close(directory)
        except OSError:
            pass


def validate_receipt_payload(receipt, plan=None):
    if (
        not exact_object(receipt, RECEIPT_FIELDS)
        or receipt.get("schema") != RECEIPT_SCHEMA
        or not strict_int(receipt.get("version"))
        or receipt.get("version") != VERSION
        or not digest_string(receipt.get("plan_sha256"))
    ):
        raise InputError("receipt_preflight_failed")
    try:
        received = parse_utc(receipt.get("received_at"))
        if plan is not None:
            if receipt["plan_sha256"] != sha256(canonical_json(plan)):
                raise InputError("receipt_preflight_failed")
            if received >= parse_utc(plan["window"]["start"]):
                raise InputError("receipt_preflight_failed")
    except (InputError, KeyError, TypeError) as error:
        raise InputError("receipt_preflight_failed") from error


def validate_completed_pairs_preflight(document, schedule, records):
    pairs = document.get("pairs")
    if not isinstance(pairs, list) or len(pairs) != len(schedule):
        return False
    seen_pair_ids = set()
    used_event_ids = Counter()
    forward_ids = Counter()
    plan = document["plan"]
    for pair in pairs:
        if not exact_object(pair, PAIR_FIELDS):
            return False
        pair_id = pair.get("pair_id")
        if (
            not nonempty_string(pair_id)
            or pair_id in seen_pair_ids
            or pair_id not in schedule
        ):
            return False
        seen_pair_ids.add(pair_id)
        scheduled = schedule[pair_id]
        events = {}
        for key, arm in (
            ("batching", "batching"),
            ("serial_control", "serial_control"),
        ):
            event = pair.get(key)
            if not validate_event_shape(event):
                return False
            if (
                records.get(event["event_id"], {}).get("event") != event
                or binding_mismatches(event, plan, scheduled, arm)
                or source_binding_mismatches(
                    records[event["event_id"]]["capture"],
                    plan,
                    scheduled,
                )
            ):
                return False
            events[key] = event
            used_event_ids[event["event_id"]] += 1

        batch_execution = events["batching"]["execution"]
        expected_batch_execution = {
            "mode": "continuous_batching",
            "forward_id": batch_execution.get("forward_id"),
            "row_count": scheduled["intended_batch_depth"],
            "row_index": 0,
            "members": expected_members(scheduled),
        }
        if (
            batch_execution != expected_batch_execution
            or not nonempty_string(batch_execution.get("forward_id"))
        ):
            return False
        forward_ids[batch_execution["forward_id"]] += 1

        companion_reasons, companion_ids = validate_companion_events(
            records,
            plan,
            scheduled,
            events["batching"],
            batch_execution,
        )
        if companion_reasons:
            return False
        used_event_ids.update(companion_ids)

        serial_event = events["serial_control"]
        expected_serial_execution = {
            "mode": "serial",
            "forward_id": None,
            "row_count": 1,
            "row_index": 0,
            "members": [
                {
                    "event_id": serial_event["event_id"],
                    "request_id": serial_event["request_id"],
                    "row_index": 0,
                    "challenge_id": serial_event["challenge_id"],
                    "challenge_payload_sha256": scheduled["challenge_payload_sha256"],
                    "workload_stratum": serial_event["workload_stratum"],
                }
            ],
        }
        if serial_event["execution"] != expected_serial_execution:
            return False
        if validate_pair_timing(pair, plan, scheduled):
            return False

    expected_event_ids = expected_raw_event_ids(schedule)
    return (
        seen_pair_ids == set(schedule)
        and set(used_event_ids) == expected_event_ids
        and all(count == 1 for count in used_event_ids.values())
        and all(count == 1 for count in forward_ids.values())
    )


def preparation_payload(document, role, raw_bundle=None, raw_bundle_digest=None):
    if not isinstance(document, dict):
        raise InputError("preparation_input_invalid")
    if role == "plan":
        payload = (
            document
            if document.get("schema") == PLAN_SCHEMA
            else document.get("plan")
        )
        if validate_plan(payload):
            raise InputError("plan_preflight_failed")
        return payload
    if role == "receipt":
        payload = document.get("plan_receipt")
        embedded_plan = document.get("plan")
        if not isinstance(embedded_plan, dict) or not isinstance(payload, dict):
            raise InputError("receipt_preflight_failed")
        if validate_plan(embedded_plan):
            raise InputError("receipt_preflight_failed")
        validate_receipt_payload(payload, embedded_plan)
        return payload
    if role == "source_review":
        payload = document.get("source_review")
        reasons, _schedule, plan_digest = validate_document(document)
        allowed = {"document_pairs_invalid", "document_pairs_too_many"}
        if (
            not isinstance(payload, dict)
            or raw_bundle_digest is None
            or document.get("raw_bundle_sha256") != raw_bundle_digest
            or payload.get("plan_sha256") != plan_digest
            or payload.get("raw_bundle_sha256") != raw_bundle_digest
            or any(reason not in allowed for reason in reasons)
        ):
            raise InputError("source_review_preflight_failed")
        return payload
    if role == "evidence":
        reasons, schedule, _digest = validate_document(document)
        if raw_bundle is None or raw_bundle_digest is None:
            raise InputError("evidence_preflight_failed")
        records, raw_reasons = parse_raw_bundle(
            raw_bundle,
            expected_raw_event_ids(schedule),
        )
        preflight_report = measure(
            document,
            raw_bundle,
            raw_bundle_digest,
            {"verified": True},
        )
        if (
            reasons
            or raw_reasons
            or document.get("raw_bundle_sha256") != raw_bundle_digest
            or not validate_completed_pairs_preflight(document, schedule, records)
            or not preflight_report["passed"]
        ):
            raise InputError("evidence_preflight_failed")
        return document
    raise InputError("preparation_mode_invalid")


def build_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("--raw-bundle")
    parser.add_argument("--output")
    parser.add_argument("--also-stdout", action="store_true")
    for role in ("plan", "receipt", "source_review", "evidence"):
        option_role = role.replace("_", "-")
        parser.add_argument(
            "--" + option_role + "-signature",
            dest=role + "_signature",
        )
        parser.add_argument(
            "--prepare-" + option_role + "-payload",
            dest="prepare_" + role + "_payload",
        )
    for role in ("plan", "reviewer", "evidence"):
        parser.add_argument("--" + role + "-trust")
        parser.add_argument("--" + role + "-principal")
    return parser


def main(argv=None):
    parser = build_parser()
    arguments = parser.parse_args(argv)
    selected = [
        (role, getattr(arguments, "prepare_" + role + "_payload"))
        for role in ("plan", "receipt", "source_review", "evidence")
        if getattr(arguments, "prepare_" + role + "_payload")
    ]
    if selected:
        try:
            if len(selected) != 1:
                raise InputError("preparation_mode_invalid")
            document = load_document(arguments.input)
            role, output_path = selected[0]
            raw_bundle = None
            raw_digest = None
            if role in ("source_review", "evidence"):
                if not arguments.raw_bundle:
                    raise InputError(role + "_preflight_failed")
                raw_bytes = readfile(arguments.raw_bundle, MAX_RAW_BYTES)
                raw_bundle = loads_bounded(raw_bytes)
                raw_digest = sha256(raw_bytes)
            write_new(
                output_path,
                canonical_json(preparation_payload(document, role, raw_bundle, raw_digest)),
            )
            return 0
        except (
            AttributeError,
            InputError,
            KeyError,
            OverflowError,
            TypeError,
            ValueError,
        ):
            return 3

    paths = {}
    principals = {}
    for role in ("plan", "receipt", "source_review", "evidence"):
        paths[role + "_signature"] = getattr(arguments, role + "_signature")
    for role in ("plan", "reviewer", "evidence"):
        paths[role + "_trust"] = getattr(arguments, role + "_trust")
        principals[role] = getattr(arguments, role + "_principal")
    required = [
        arguments.raw_bundle,
        arguments.output,
        *paths.values(),
        *principals.values(),
    ]
    if not all(required):
        parser.error(
            "report mode requires raw bundle and three signature/trust/principal sets"
        )

    canonical_input_digest = None
    try:
        document = load_document(arguments.input)
        canonical_input_digest = sha256(canonical_json(document))
        raw_bytes = readfile(
            arguments.raw_bundle,
            MAX_RAW_BYTES,
            "raw_bundle_unreadable",
            "raw_bundle_not_regular_file",
        )
        raw_bundle = loads_bounded(raw_bytes)
        authenticity = verify_authenticity(document, paths, principals)
        report = measure(
            document,
            raw_bundle,
            sha256(raw_bytes),
            authenticity,
        )
    except InputError as error:
        report = empty_report(str(error), canonical_input_digest)
    except (AttributeError, KeyError, OverflowError, TypeError, ValueError):
        report = empty_report("input_validation_failed", canonical_input_digest)

    try:
        report_bytes = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode()
        if len(report_bytes) > MAX_REPORT_BYTES:
            raise InputError("report_too_large")
        write_new(arguments.output, report_bytes)
        if arguments.also_stdout:
            sys.stdout.buffer.write(report_bytes)
            sys.stdout.buffer.flush()
    except BrokenPipeError:
        try:
            null_descriptor = os.open(os.devnull, os.O_WRONLY)
            os.dup2(null_descriptor, sys.stdout.fileno())
            os.close(null_descriptor)
        except OSError:
            pass
        return 3
    except InputError:
        return 3
    return 0 if report["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
