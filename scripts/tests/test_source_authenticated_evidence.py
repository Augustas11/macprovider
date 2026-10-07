import base64
import copy
import datetime as dt
import importlib.util
import json
import pathlib
import subprocess
import re
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "source_authenticated_evidence.py"
spec = importlib.util.spec_from_file_location("source_authenticated_evidence", SCRIPT)
sae = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = sae
spec.loader.exec_module(sae)

NOW = dt.datetime(2026, 10, 7, 12, 0, 10, tzinfo=dt.timezone.utc)
GENERATED = "2026-10-07T12:00:00.000Z"
NOT_BEFORE = "2026-10-07T11:00:00.000Z"
NOT_AFTER = "2026-10-07T13:00:00.000Z"
SOURCE_SHA = "a" * 40
NONCE = base64.urlsafe_b64encode(b"n" * 32).decode("ascii").rstrip("=")


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


class Fixture:
    def __init__(self, tmp: pathlib.Path):
        self.tmp = tmp
        self.private = tmp / "source-ed25519.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(self.private)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        der = subprocess.run(["openssl", "pkey", "-in", str(self.private), "-pubout", "-outform", "DER"], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
        self.public = der[-32:]
        self.expected = sae.ExpectedExport(
            producer="gateway",
            role="refusal_export",
            instance_id="gateway-prod-a",
            source_sha=SOURCE_SHA,
            run_id="run-1880",
            challenge_nonce=NONCE,
            domain=sae.SIGNATURE_DOMAIN_NAME,
            now=NOW,
            max_age_seconds=300,
        )

    def signed(self):
        return {
            "schema_version": sae.SIGNED_SCHEMA,
            "producer": "gateway",
            "role": "refusal_export",
            "instance_id": "gateway-prod-a",
            "source_sha": SOURCE_SHA,
            "export_id": "123e4567-e89b-42d3-a456-426614174000",
            "run_id": "run-1880",
            "challenge_nonce": NONCE,
            "generated_at": GENERATED,
            "request_scopes": ["0" * 64, "1" * 64],
            "snapshot": {"schema_version": "foundation_only", "record_count": 1},
            "records": [{"schema_version": "opaque_future_record", "row_id": 1, "commitment": "2" * 64}],
        }

    def registry(self):
        return {
            "schema_version": sae.REGISTRY_SCHEMA,
            "keys": [
                {
                    "key_id": "source-key-1",
                    "algorithm": "ed25519",
                    "public_key": b64url(self.public),
                    "producer": "gateway",
                    "instance_id": "gateway-prod-a",
                    "permitted_roles": ["refusal_export"],
                    "permitted_domains": [sae.SIGNATURE_DOMAIN_NAME],
                    "not_before": NOT_BEFORE,
                    "not_after": NOT_AFTER,
                    "revoked_at": None,
                    "reviewed_source_constraints": {
                        "source_sha_allowlist": [SOURCE_SHA],
                        "notes": "reviewed test deployment key",
                    },
                }
            ],
        }

    def coordinator_expected(self):
        return sae.ExpectedExport(
            producer="coordinator",
            role="no_dispatch_refusal",
            instance_id="coordinator-prod-a",
            source_sha=SOURCE_SHA,
            run_id="run-1880",
            challenge_nonce=NONCE,
            domain=sae.SIGNATURE_DOMAIN_NAME,
            now=NOW,
            max_age_seconds=300,
        )

    def coordinator_registry(self):
        registry = self.registry()
        registry["keys"][0]["producer"] = "coordinator"
        registry["keys"][0]["instance_id"] = "coordinator-prod-a"
        registry["keys"][0]["permitted_roles"] = ["no_dispatch_refusal"]
        return registry

    def coordinator_snapshot(self):
        return {
            "schema_version": "macprovider.coordinator-source-snapshot.v1",
            "producer_contract_version": "coordinator-no-dispatch-v1",
            "registry_bundle_digest": "sha256:" + sae.sha256_hex(sae.canonical_bytes(self.coordinator_registry())),
            "closure_table_schema": "coordinator_source_no_dispatch_closures.v1",
            "db_fence_schema": "coordinator_source_no_dispatch_fence.v1",
            "record_schema": "macprovider.coordinator-no-dispatch-record.v1",
            "canonicalization": "ascii-jcs-subset-v1",
            "scope_hmac": "hmac-sha256-length-prefixed-v1",
        }

    def coordinator_record(self, scope="0" * 64, terminal_kind="model_not_found_no_dispatch"):
        status, error_class = {
            "model_not_found_no_dispatch": (404, "no_provider_advertised_requested_model"),
            "pool_unavailable_no_dispatch": (503, "pool_unavailable"),
        }[terminal_kind]
        return {
            "schema_version": "macprovider.coordinator-no-dispatch-record.v1",
            "source": "coordinator",
            "record_kind": "no_dispatch_terminal",
            "request_scope_commitment": scope,
            "projection_status": "closed_terminal",
            "terminal_kind": terminal_kind,
            "privacy": {
                "raw_account_id_emitted": False,
                "raw_external_request_id_emitted": False,
                "raw_internal_request_id_emitted": False,
                "raw_rejected_model_emitted": False,
                "request_log_model_blank_for_unserved": True,
            },
            "request_log_summary": {
                "count": 1,
                "status": status,
                "attempt_n": 0,
                "provider_assigned": False,
                "error_message_class": error_class,
                "terminal_kind_source": "coordinator_source_no_dispatch_closures.terminal_kind",
            },
            "settlement_absence": {
                "fence": "sqlite_triggers_no_future_writes_v1",
                "ledger_request_credits": {"count": 0, "max_id": 0},
                "settlement_route_snapshots": {"count": 0, "max_id": 0},
                "settlement_attempt_outputs": {"count": 0, "max_id": 0},
                "settlement_receipt_verdicts": {"count": 0, "max_id": 0},
            },
            "closure": {
                "schema_version": "macprovider.coordinator-no-dispatch-closure.v1",
                "closed_at_utc": GENERATED,
                "closure_id_hmac": "f" * 64,
            },
        }

    def coordinator_signed(self):
        return {
            "schema_version": sae.SIGNED_SCHEMA,
            "producer": "coordinator",
            "role": "no_dispatch_refusal",
            "instance_id": "coordinator-prod-a",
            "source_sha": SOURCE_SHA,
            "export_id": "123e4567-e89b-42d3-a456-426614174001",
            "run_id": "run-1880",
            "challenge_nonce": NONCE,
            "generated_at": GENERATED,
            "request_scopes": ["0" * 64, "1" * 64],
            "snapshot": self.coordinator_snapshot(),
            "records": [
                self.coordinator_record("0" * 64, "model_not_found_no_dispatch"),
                self.coordinator_record("1" * 64, "pool_unavailable_no_dispatch"),
            ],
        }

    def coordinator_envelope(self, signed=None):
        return self.envelope(self.coordinator_signed() if signed is None else signed)

    def coordinator_validate(self, envelope=None, signed=None):
        if envelope is None:
            envelope = self.coordinator_envelope(signed)
        return self.validate(envelope=envelope, registry=self.coordinator_registry(), expected=self.coordinator_expected())

    def sign(self, signed: dict) -> bytes:
        message = sae.SIGNATURE_DOMAIN + sae.canonical_bytes(signed)
        msg = self.tmp / "message.bin"
        sig = self.tmp / "signature.bin"
        msg.write_bytes(message)
        subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(self.private), "-rawin", "-in", str(msg), "-out", str(sig)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return sig.read_bytes()

    def envelope(self, signed=None):
        signed = copy.deepcopy(self.signed() if signed is None else signed)
        signed_bytes = sae.canonical_bytes(signed)
        return {
            "schema_version": sae.ENVELOPE_SCHEMA,
            "signed": signed,
            "signatures": [
                {
                    "algorithm": "ed25519",
                    "key_id": "source-key-1",
                    "signed_sha256": sae.sha256_hex(signed_bytes),
                    "signature": b64url(self.sign(signed)),
                }
            ],
        }

    def validate(self, envelope=None, registry=None, expected=None):
        return sae.validate_envelope(envelope or self.envelope(), registry or self.registry(), expected or self.expected)


class SourceAuthenticatedEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory(prefix="source-evidence-test.")
        self.fx = Fixture(pathlib.Path(self.tmpdir.name))

    def tearDown(self):
        self.tmpdir.cleanup()

    def assert_rejected(self, fragment, mutate_envelope=None, mutate_registry=None, expected=None):
        envelope = self.fx.envelope()
        registry = self.fx.registry()
        if mutate_envelope:
            mutate_envelope(envelope)
        if mutate_registry:
            mutate_registry(registry)
        with self.assertRaises(sae.EvidenceError) as cm:
            self.fx.validate(envelope, registry, expected or self.fx.expected)
        self.assertIn(fragment, str(cm.exception))

    def test_accepts_real_ed25519_signature_over_domain_and_jcs_signed_bytes(self):
        result = self.fx.validate()
        self.assertEqual(result["key_id"], "source-key-1")
        self.assertEqual(result["record_count"], 1)

    def test_rejects_digest_only_signature_and_tampered_signed_body(self):
        def digest_only(env):
            digest = bytes.fromhex(env["signatures"][0]["signed_sha256"])
            msg = self.fx.tmp / "digest.bin"
            sig = self.fx.tmp / "digest.sig"
            msg.write_bytes(digest)
            subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(self.fx.private), "-rawin", "-in", str(msg), "-out", str(sig)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            env["signatures"][0]["signature"] = b64url(sig.read_bytes())
        self.assert_rejected("Ed25519 verification failed", digest_only)
        self.assert_rejected("does not match SHA256", lambda e: e["signed"]["records"][0].__setitem__("commitment", "3" * 64))

    def test_rejects_signature_omission_extra_signature_and_algorithm_confusion(self):
        self.assert_rejected("exactly one signature", lambda e: e.__setitem__("signatures", []))
        self.assert_rejected("exactly one signature", lambda e: e["signatures"].append(copy.deepcopy(e["signatures"][0])))
        self.assert_rejected("must equal ed25519", lambda e: e["signatures"][0].__setitem__("algorithm", "rsa"))

    def test_rejects_key_role_domain_producer_instance_source_confusion(self):
        self.assert_rejected("does not authorize signed role", mutate_registry=lambda r: r["keys"][0].__setitem__("permitted_roles", ["other_role"]))
        self.assert_rejected("does not authorize actual signature domain", mutate_registry=lambda r: r["keys"][0].__setitem__("permitted_domains", ["other_domain"]))
        self.assert_rejected("does not authorize signed producer", mutate_registry=lambda r: r["keys"][0].__setitem__("producer", "coordinator"))
        self.assert_rejected("does not authorize signed instance_id", mutate_registry=lambda r: r["keys"][0].__setitem__("instance_id", "gateway-prod-b"))
        self.assert_rejected("does not authorize signed source_sha", mutate_registry=lambda r: r["keys"][0]["reviewed_source_constraints"].__setitem__("source_sha_allowlist", ["b" * 40]))


    def test_export_signature_cannot_be_authorized_by_challenge_only_domain_even_if_caller_agrees(self):
        challenge_domain = "macprovider.refusal-proof-challenge-response.v1"
        expected = sae.ExpectedExport(
            "gateway",
            "refusal_export",
            "gateway-prod-a",
            SOURCE_SHA,
            "run-1880",
            NONCE,
            challenge_domain,
            NOW,
        )
        self.assert_rejected("actual signature domain", mutate_registry=lambda r: r["keys"][0].__setitem__("permitted_domains", [challenge_domain]), expected=expected)

    def test_expected_context_validation_is_not_only_cli_side(self):
        with self.assertRaisesRegex(sae.EvidenceError, "max_age_seconds"):
            self.fx.validate(expected=sae.ExpectedExport("gateway", "refusal_export", "gateway-prod-a", SOURCE_SHA, "run-1880", NONCE, sae.SIGNATURE_DOMAIN_NAME, NOW, 0))
        non_utc = dt.datetime(2026, 10, 7, 20, 0, 10, tzinfo=dt.timezone(dt.timedelta(hours=8)))
        with self.assertRaisesRegex(sae.EvidenceError, "must be UTC"):
            self.fx.validate(expected=sae.ExpectedExport("gateway", "refusal_export", "gateway-prod-a", SOURCE_SHA, "run-1880", NONCE, sae.SIGNATURE_DOMAIN_NAME, non_utc))

    def test_registry_keeps_inactive_nonselected_keys_without_poisoning_valid_signer(self):
        def add_inactive(r):
            for key_id, not_before, not_after, revoked_at in [
                ("expired-key", "2026-10-07T09:00:00.000Z", "2026-10-07T10:00:00.000Z", None),
                ("future-key", "2026-10-07T13:00:00.000Z", "2026-10-07T14:00:00.000Z", None),
                ("revoked-key", "2026-10-07T09:00:00.000Z", "2026-10-07T14:00:00.000Z", "2026-10-07T10:00:00.000Z"),
            ]:
                row = copy.deepcopy(r["keys"][0])
                row["key_id"] = key_id
                row["not_before"] = not_before
                row["not_after"] = not_after
                row["revoked_at"] = revoked_at
                r["keys"].append(row)
        registry = self.fx.registry()
        add_inactive(registry)
        self.fx.validate(registry=registry)

    def test_selected_key_validity_and_export_time_are_enforced(self):
        self.assert_rejected("selected key is expired", mutate_registry=lambda r: r["keys"][0].__setitem__("not_after", "2026-10-07T11:59:59.000Z"))
        self.assert_rejected("selected key is revoked", mutate_registry=lambda r: r["keys"][0].__setitem__("revoked_at", "2026-10-07T11:59:59.000Z"))
        self.assert_rejected("selected key is not yet valid", mutate_registry=lambda r: r["keys"][0].__setitem__("not_before", "2026-10-07T12:00:11.000Z"))
        self.assert_rejected("validity window", mutate_registry=lambda r: r["keys"][0].__setitem__("not_before", "2026-10-07T12:00:01.000Z"))
        self.assert_rejected("selected key is expired", mutate_registry=lambda r: r["keys"][0].__setitem__("not_after", "2026-10-07T12:00:00.000Z"))
        with self.assertRaisesRegex(sae.EvidenceError, "empty"):
            sae.validate_registry({"schema_version": sae.REGISTRY_SCHEMA, "keys": []}, now=NOW)
        self.assert_rejected("duplicate key_id", mutate_registry=lambda r: r["keys"].append(copy.deepcopy(r["keys"][0])))

    def test_rejects_caller_expected_run_nonce_deployment_and_freshness_mismatch(self):
        self.assert_rejected("expected run_id", expected=sae.ExpectedExport("gateway", "refusal_export", "gateway-prod-a", SOURCE_SHA, "run-other", NONCE, sae.SIGNATURE_DOMAIN_NAME, NOW))
        self.assert_rejected("expected challenge_nonce", expected=sae.ExpectedExport("gateway", "refusal_export", "gateway-prod-a", SOURCE_SHA, "run-1880", b64url(b"x" * 32), sae.SIGNATURE_DOMAIN_NAME, NOW))
        self.assert_rejected("expected instance_id", expected=sae.ExpectedExport("gateway", "refusal_export", "gateway-prod-b", SOURCE_SHA, "run-1880", NONCE, sae.SIGNATURE_DOMAIN_NAME, NOW))
        stale_now = dt.datetime(2026, 10, 7, 12, 6, 0, tzinfo=dt.timezone.utc)
        self.assert_rejected("too old", expected=sae.ExpectedExport("gateway", "refusal_export", "gateway-prod-a", SOURCE_SHA, "run-1880", NONCE, sae.SIGNATURE_DOMAIN_NAME, stale_now))

    def test_rejects_duplicate_json_keys_bool_as_int_floats_unicode_and_bad_base64(self):
        with self.assertRaisesRegex(sae.EvidenceError, "duplicate JSON key"):
            sae.load_json_bytes(b'{"schema_version":"x","schema_version":"y"}')
        self.assert_rejected("must be an integer", lambda e: e["signed"]["records"][0].__setitem__("row_id", True))
        with self.assertRaisesRegex(sae.EvidenceError, "floats"):
            sae.load_json_bytes(b'{"x":1.25}')
        self.assert_rejected("printable ASCII", lambda e: e["signed"].__setitem__("run_id", "run-\u2603"))
        self.assert_rejected("does not match", lambda e: e["signatures"][0].__setitem__("signature", "not+url"))


    def test_schema_contract_notes_match_authoritative_validator_limits(self):
        registry_schema = json.loads((pathlib.Path(__file__).resolve().parents[2] / "schemas/source-evidence-key-registry-v1.schema.json").read_text())
        self.assertEqual(registry_schema["properties"]["keys"]["minItems"], 1)
        self.assertIn("key_id uniqueness", registry_schema["properties"]["keys"]["description"])
        envelope_schema = json.loads((pathlib.Path(__file__).resolve().parents[2] / "schemas/source-authenticated-export-envelope-v1.schema.json").read_text())
        request_scopes = envelope_schema["$defs"]["signed"]["properties"]["request_scopes"]
        self.assertTrue(request_scopes["uniqueItems"])
        self.assertIn("sorted lexicographically", request_scopes["description"])

    def test_actual_validator_rejects_empty_registry_duplicate_key_and_unsorted_scopes(self):
        with self.assertRaisesRegex(sae.EvidenceError, "empty"):
            sae.validate_registry({"schema_version": sae.REGISTRY_SCHEMA, "keys": []}, now=NOW)
        self.assert_rejected("duplicate key_id", mutate_registry=lambda r: r["keys"].append(copy.deepcopy(r["keys"][0])))
        self.assert_rejected("sorted", lambda e: e["signed"].__setitem__("request_scopes", ["1" * 64, "0" * 64]))

    def test_rejects_replay_wrong_run_nonce_unsorted_scopes_truncation_and_record_cap(self):
        self.assert_rejected("expected run_id", lambda e: e["signed"].__setitem__("run_id", "run-replay"))
        self.assert_rejected("expected challenge_nonce", lambda e: e["signed"].__setitem__("challenge_nonce", b64url(b"r" * 32)))
        self.assert_rejected("sorted", lambda e: e["signed"].__setitem__("request_scopes", ["1" * 64, "0" * 64]))
        self.assert_rejected("extra", lambda e: e["signed"].__setitem__("truncated", True))
        self.assert_rejected("at most 1000 records", lambda e: e["signed"].__setitem__("records", [{"row_id": i} for i in range(1001)]))


    def test_hostile_large_or_deep_json_fails_closed_without_traceback(self):
        with tempfile.TemporaryDirectory(prefix="source-load.") as td:
            too_large = pathlib.Path(td) / "large.json"
            too_large.write_bytes(b" " * (sae.MAX_INPUT_BYTES + 1))
            with self.assertRaisesRegex(sae.EvidenceError, "exceeds"):
                sae.load_json_file(too_large)
        deep = "[" * 20000 + "]" * 20000
        with self.assertRaisesRegex(sae.EvidenceError, "nesting"):
            sae.load_json_bytes(deep.encode("ascii"))
        value = []
        root = value
        for _ in range(70):
            child = []
            value.append(child)
            value = child
        with self.assertRaisesRegex(sae.EvidenceError, "nesting"):
            sae.canonical_bytes(root)

    def test_rejects_malformed_or_noncanonical_public_key_and_wrong_signature_key(self):
        self.assert_rejected("32 bytes", mutate_registry=lambda r: r["keys"][0].__setitem__("public_key", b64url(b"short")))
        with tempfile.TemporaryDirectory(prefix="other-key.") as other:
            other_fx = Fixture(pathlib.Path(other))
            self.assert_rejected("Ed25519 verification failed", mutate_registry=lambda r: r["keys"][0].__setitem__("public_key", b64url(other_fx.public)))

    def test_coordinator_no_dispatch_projection_accepts_real_ed25519_closed_records(self):
        result = self.fx.coordinator_validate()
        self.assertEqual(result["key_id"], "source-key-1")
        self.assertEqual(result["record_count"], 2)
        self.assertEqual(result["typed_projection"], "coordinator_no_dispatch_closed_terminal_v1")
        self.assertEqual(result["terminal_kinds"], ["model_not_found_no_dispatch", "pool_unavailable_no_dispatch"])

    def test_coordinator_projection_rejects_missing_extra_partial_and_inconsistent_shapes(self):
        def reject(fragment, mutate):
            signed = self.fx.coordinator_signed()
            mutate(signed)
            with self.assertRaises(sae.EvidenceError) as cm:
                self.fx.coordinator_validate(signed=signed)
            self.assertIn(fragment, str(cm.exception))

        reject("missing", lambda s: s["snapshot"].pop("db_fence_schema"))
        reject("extra", lambda s: s["records"][0].__setitem__("raw_request_id", "leak"))
        reject("one-for-one", lambda s: s["records"].pop())
        reject("exactly equal sorted request_scopes", lambda s: s["records"][0].__setitem__("request_scope_commitment", "2" * 64))
        reject("must contain closed records", lambda s: (s.__setitem__("request_scopes", []), s.__setitem__("records", [])))
        reject("must equal macprovider.coordinator-no-dispatch-record.v1", lambda s: s["snapshot"].__setitem__("record_schema", "other"))

    def test_coordinator_projection_rejects_nonclosed_or_nonprivate_record_claims(self):
        def reject(fragment, mutate):
            signed = self.fx.coordinator_signed()
            mutate(signed["records"][0])
            with self.assertRaises(sae.EvidenceError) as cm:
                self.fx.coordinator_validate(signed=signed)
            self.assertIn(fragment, str(cm.exception))

        reject("closed_terminal", lambda r: r.__setitem__("projection_status", "snapshot_only_non_promotable"))
        reject("must be false", lambda r: r["privacy"].__setitem__("raw_rejected_model_emitted", True))
        reject("must be true", lambda r: r["privacy"].__setitem__("request_log_model_blank_for_unserved", False))
        reject("integer in 0..0", lambda r: r["settlement_absence"]["ledger_request_credits"].__setitem__("count", 1))
        reject("integer in 0..0", lambda r: r["settlement_absence"]["settlement_receipt_verdicts"].__setitem__("max_id", 42))
        reject("provider_assigned", lambda r: r["request_log_summary"].__setitem__("provider_assigned", True))
        reject("attempt_n", lambda r: r["request_log_summary"].__setitem__("attempt_n", 1))

    def test_coordinator_projection_rejects_terminal_reason_mismatch_and_tamper(self):
        signed = self.fx.coordinator_signed()
        signed["records"][0]["request_log_summary"]["status"] = 503
        with self.assertRaisesRegex(sae.EvidenceError, "must equal 404"):
            self.fx.coordinator_validate(signed=signed)

        signed = self.fx.coordinator_signed()
        signed["records"][1]["request_log_summary"]["error_message_class"] = "no_provider_advertised_requested_model"
        with self.assertRaisesRegex(sae.EvidenceError, "pool_unavailable"):
            self.fx.coordinator_validate(signed=signed)

        envelope = self.fx.coordinator_envelope()
        envelope["signed"]["records"][0]["closure"]["closure_id_hmac"] = "e" * 64
        with self.assertRaisesRegex(sae.EvidenceError, "does not match SHA256"):
            self.fx.coordinator_validate(envelope=envelope)

        signed = self.fx.coordinator_signed()
        signed["snapshot"]["registry_bundle_digest"] = "sha256:" + "b" * 64
        with self.assertRaisesRegex(sae.EvidenceError, "canonical registry bytes"):
            self.fx.coordinator_validate(signed=signed)

        signed = self.fx.coordinator_signed()
        signed["records"][0]["closure"]["closed_at_utc"] = "2026-10-07T12:00:01.000Z"
        with self.assertRaisesRegex(sae.EvidenceError, "generated_at"):
            self.fx.coordinator_validate(signed=signed)

    def test_other_roles_remain_opaque_authenticity_only(self):
        result = self.fx.validate()
        self.assertEqual(result["typed_projection"], "opaque_authenticity_only")
        envelope = self.fx.envelope()
        envelope["signed"]["records"][0]["schema_version"] = "not_a_known_schema"
        envelope = self.fx.envelope(envelope["signed"])
        result = self.fx.validate(envelope=envelope)
        self.assertEqual(result["typed_projection"], "opaque_authenticity_only")

    def test_cli_uses_fixed_registry_path_and_fails_closed_without_reviewed_registry(self):
        with tempfile.TemporaryDirectory(prefix="source-cli.") as td:
            envelope = pathlib.Path(td) / "envelope.json"
            envelope.write_text(json.dumps(self.fx.envelope()), encoding="utf-8")
            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(envelope),
                    "--producer", "gateway",
                    "--role", "refusal_export",
                    "--instance-id", "gateway-prod-a",
                    "--source-sha", SOURCE_SHA,
                    "--run-id", "run-1880",
                    "--challenge-nonce", NONCE,
                    "--domain", sae.SIGNATURE_DOMAIN_NAME,
                    "--now", "2026-10-07T12:00:10.000Z",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("source-evidence-key-registry-v1.json", result.stderr)
            self.assertIn("reviewed production registry is not enrolled", result.stderr)
            self.assertIn("fail closed", result.stderr)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
