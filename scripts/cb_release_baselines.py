#!/usr/bin/env python3
"""Reviewed continuous-batching release-preservation baselines.

Adding, removing, disabling, or weakening a baseline is product-review scope: the
change must name the protected tuple and the reason. Release and catalog gates
that set a required baseline intentionally do not provide a runtime opt-out.
"""

CB_QUALIFIED_PROVENANCE_SOURCES = {"packaged_studio_campaign", "release_review", "operator_review"}
CB_POLICY_SCHEMA = "macprovider.continuous-batching-policy.v1"
CB_POLICY_TUPLE_SCHEMA = "macprovider.continuous-batching-policy-tuple.v1"
CB_POLICY_TUPLE_DOMAIN = b"macprovider.continuous-batching-policy-tuple.v1\n"
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
