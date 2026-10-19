#!/usr/bin/env python3
"""Reviewed continuous-batching release-preservation baselines.

Adding, removing, disabling, or weakening a baseline is product-review scope: the
change must name the protected tuple and the reason. Release and catalog gates
that set a required baseline intentionally do not provide a runtime opt-out.
"""

from __future__ import annotations

CB_QUALIFIED_PROVENANCE_SOURCES = {"packaged_studio_campaign", "release_review", "operator_review"}
CB_POLICY_SCHEMA = "macprovider.continuous-batching-policy.v1"
CB_POLICY_TUPLE_SCHEMA = "macprovider.continuous-batching-policy-tuple.v1"
CB_POLICY_TUPLE_DOMAIN = b"macprovider.continuous-batching-policy-tuple.v1\n"
# SPEC-038 FR-CB11 (v0.3.22): optional signed served-slot ceiling per entry,
# a JSON integer in 1..32 (`ProviderCapacity.maxConcurrencyOverrideLimit`).
CB_POLICY_OPTIONAL_ENTRY_FIELDS = {"max_served_slots"}
CB_MAX_SERVED_SLOTS_LIMIT = 32


# SPEC-023 v0.22.28 rollout gate, as the v0.17.1 artifact-feed floor: the
# oldest SPEC-023 consumer (provider CLI and coordinator) that must read every
# CB policy a release publishes. Strict readers reject a whole policy with an
# unknown entry field, so a field introduced by a later revision is refused
# until this floor is raised, in a reviewed change, after every consumer
# implements it.
CB_POLICY_CONSUMER_FLOOR = (0, 22, 27)
# optional CB policy entry field -> the SPEC-023 revision that made it legal.
CB_POLICY_FIELD_MIN_CONSUMER = {"max_served_slots": (0, 22, 28)}


def valid_max_served_slots(value: object) -> bool:
    return type(value) is int and 1 <= value <= CB_MAX_SERVED_SLOTS_LIMIT


def cb_policy_consumer_floor_violation(entries: list, floor: tuple | None = None) -> str | None:
    """The first entry field the consumer floor cannot read, as a message."""
    floor = CB_POLICY_CONSUMER_FLOOR if floor is None else floor
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            continue
        for field, needed in sorted(CB_POLICY_FIELD_MIN_CONSUMER.items()):
            if field in entry and floor < needed:
                return (
                    f"entries[{index}].{field} needs every consumer at SPEC-023 "
                    f"v{'.'.join(map(str, needed))}; the consumer floor is "
                    f"v{'.'.join(map(str, floor))} (raise CB_POLICY_CONSUMER_FLOOR only after the rollout)"
                )
    return None


REQUIRED_CB_BASELINES = {
    "studio-qwen3.6-a3b-v1": {
        "model_key": "qwen/qwen3.6-35b-a3b",
        "model_id": "qwen/qwen3.6-35b-a3b",
        "model_sha256": "3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1",
        "tokenizer_sha256": "eec97aac7c5f9ba9159d4784222300eccf5ff2e6b4aeb193c8c939c912633510",
        "chat_template_sha256": "9cf4f46deaa06769f3240ada331ac0f348694db48ec2e8b51068935f77bb18f9",
        "cache_class": "mixed",
        "kv_dtype": "fp16",
        "requires_moe": True,
        "hardware_class": "apple-silicon:Apple M3 Ultra:ram-256gb",
        "metallib_sha256": "84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf",
        "kernel_identifier": "macprovider_paged_kv_gather_v1",
        "cached_turns_accepted": False,
    },
}
