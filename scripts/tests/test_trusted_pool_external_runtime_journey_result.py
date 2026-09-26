from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    SIGNED_JOURNEY_RESULT_ALLOWED_KEYS,
    SIGNED_JOURNEY_RESULT_REQUIRED_KEYS,
    TRUSTED_POOL_EXTERNAL_RUNTIME_ARTIFACT_ID,
    TRUSTED_POOL_EXTERNAL_RUNTIME_JOURNEY_ID,
    TRUSTED_POOL_EXTERNAL_RUNTIME_STEP_ID_ORDER,
    ValidationResult,
    _expect_keys,
    _validate_trusted_pool_external_runtime_journey_result,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
GGUF = "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff"
DIGEST = "d" * 64
POOL = "pool-m1-test"
MEMBER = "mp-member-test-0001"
BUYER = "acct-buyer-test-0001"
OPERATOR_ACCOUNT = "acct-malibu-ops-m1"


def load_builder():
    path = REPO_ROOT / "scripts" / "build-trusted-pool-external-runtime-journey-result.py"
    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("trusted_pool_external_runtime_builder", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


BUILDER = load_builder()


def write(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(value, (bytes, str)):
        path.write_bytes(value if isinstance(value, bytes) else value.encode("utf-8"))
    else:
        path.write_text(json.dumps(value), encoding="utf-8")


def headers(status: int, *, request_id: str = "", engine: str = "", provider: str = "") -> str:
    reason = {200: "OK", 400: "Bad Request", 503: "Service Unavailable"}[status]
    lines = [f"HTTP/2 {status} {reason}"]
    if request_id:
        lines.append(f"x-request-id: {request_id}")
    if engine:
        lines.append(f"x-macprovider-engine: {engine}")
    if provider:
        lines.append(f"x-provider-id: {provider}")
    lines.append("content-type: application/json")
    return "\r\n".join(lines) + "\r\n\r\n"


def make_capture(root: Path) -> Path:
    capture = root / "capture"
    write(capture / "run.json", {
        "run_id": "trusted-pool-external-runtime-20260926T010203Z",
        "captured_at": "2026-09-26T01:02:03Z",
        "expires_at": "2099-01-01",
        "source_commit": "a" * 40,
        "coordinator_version": "v1.8.200",
        "accepted_id": "Augustas11/macprovider:v1.8.201@" + "b" * 40,
        "member_cli_sha256": "c" * 64,
        "llama_server_build": "b11149",
        "gguf_sha256": GGUF,
        "gguf_artifact_id": "gguf-q4-k-m",
        "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
        "operator_role": "pearl-actor",
        "operator_identity": "operator-person-name",
        "hardware_profile": "mac-studio-m3-ultra-256gb",
        "pool_id": POOL,
        "member_provider_id": MEMBER,
        "buyer_account_id": BUYER,
        "pool_operator_account_id": OPERATOR_ACCOUNT,
    })
    write(capture / "preconditions.json", {
        key: {"status": "pass", "observed": {"passed": True, "gateway_schema": 14, "build": "v1.8.200", "contains_commit": "747557cc"}, "checked_at": "2026-09-26T00:00:00Z"}
        for key in ("P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8", "payout-disabled")
    })
    write(capture / "gateway-holds.json", {
        phase: {"held_reservations": 0, "missing_trailer_log_count": 0} for phase in ("before", "after")
    })
    write(capture / "pool/get-pool.json", {"pool": {
        "pool_id": POOL, "creator_account_id": OPERATOR_ACCOUNT, "lifecycle": "active", "routeable": True,
        "launch_environment": "candidate", "manifest_version": 1, "manifest_core_digest": DIGEST,
        "members": [MEMBER], "revoked": [], "buyer_accounts": [BUYER],
    }})
    write(capture / "pool/manifest-accepted.json", {
        "event_type": "manifest_accepted", "pool_id": POOL, "manifest_version": 1, "manifest_core_digest": DIGEST,
    })
    write(capture / "pool/trustpool-events.json", [
        {"event_type": "pool_created", "n": 1}, {"event_type": "root_issuer_registered", "n": 1},
        {"event_type": "manifest_accepted", "n": 1}, {"event_type": "member_admitted", "n": 1},
        {"event_type": "buyer_authorized", "n": 1}, {"event_type": "lifecycle_changed", "n": 1},
    ])
    for kind, rid, tokens in (("nonstream", "req-ns-1", (40, 12)), ("stream", "req-st-1", (38, 9))):
        base = capture / "requests" / kind
        coord = f"coord-{kind}"
        write(base / "response.headers", headers(200, request_id=rid, engine="llamacpp_loopback", provider=MEMBER))
        if kind == "nonstream":
            write(base / "response.json", {
                "choices": [{"message": {"role": "assistant", "content": "2, 3, 5"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 52, "completion_tokens": tokens[1]},
            })
        else:
            chunks = [
                {"choices": [{"delta": {"content": "1 2 3"}, "finish_reason": None}]},
                {"choices": [{"delta": {"content": " 4 5"}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": tokens[0], "completion_tokens": tokens[1]}},
            ]
            write(base / "response.sse", "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n")
        write(base / "request_log.json", [{"request_id": coord, "attempt_n": 1, "status": "ok", "pool_id": POOL}])
        write(base / "route_snapshots.json", [{
            "request_id": coord, "attempt_n": 1, "route_snapshot_mode": "enforce", "pool_id": POOL,
            "runtime_source": "llamacpp_loopback", "manifest_version": 1, "manifest_core_digest": DIGEST,
            "pool_generation": 4, "pool_operator_account_id": OPERATOR_ACCOUNT,
            "expected_catalog_model_hash": GGUF, "artifact_hash": GGUF, "artifact_id": "gguf-q4-k-m",
        }])
        write(base / "attempt_outputs.json", [{"request_id": coord, "attempt_n": 1, "terminal_state": "normal_done", "usage_source": "pool_operator_attested"}])
        write(base / "receipt_verdicts.json", [{
            "request_id": coord, "attempt_n": 1, "receipt_version": 4, "receipt_result": "valid",
            "settlement_outcome": "verified", "reason": "verified_settlement", "closed": 1, "pool_label_status": "verified",
        }])
        write(base / "ledger.json", [{
            "id": 7, "request_id": coord, "provider_id": MEMBER, "status": "credited", "charged_prompt_tokens": tokens[0],
            "completion_tokens": tokens[1], "usage_source": "pool_operator_attested", "provider_credits": 900,
            "quarantined": 0, "settlement_policy_mode": "enforce", "payable": 1,
        }])
        write(base / "quota_reservations.json", [{"request_id": rid, "status": "settled", "settled_tokens": sum(tokens), "settlement_hold": 0}])
        write(base / "usage_events.json", [{"request_id": rid, "prompt_tokens": tokens[0], "completion_tokens": tokens[1], "token_source": "pool_operator_attested", "outcome": "settled"}])
        write(base / "finality.json", {
            "request_id": coord, "closed": True, "outcome": "verified", "token_source": "pool_operator_attested",
            "prompt_tokens": tokens[0], "completion_tokens": tokens[1], "total_tokens": sum(tokens),
        })
    for name, (status, code) in BUILDER.NEGATIVE_CONTROLS.items():
        base = capture / "controls" / name
        write(base / "response.headers", headers(status, request_id=f"req-{name}"))
        write(base / "response.json", {"error": {"code": code, "message": "x"}})
        write(base / "route_snapshots.json", "")
        write(base / "ledger.json", "")
    return capture


def valid_signed(**overrides):
    signed = {
        "journey_id": TRUSTED_POOL_EXTERNAL_RUNTIME_JOURNEY_ID,
        "execution_mode": "production-operator-internal-pool",
        "environment": {"class": "production-operator-internal-pool", "hardware_profile": "studio", "candidate": "x"},
        "requirement_ids": ["SPEC-022-R012"],
        "observations": {
            "settlement_mode": "enforce",
            "enforce_activated": True,
            "enforce_scope": "pool",
            "production_coordinator": True,
            "launch_environment": "candidate",
            "payout_ready_mutated": False,
            "raw_prompt_output_redacted": True,
            "bearer_tokens_redacted": True,
            "buyer_visible_usage_equals_debit": False,
        },
        "candidate_identity": {
            "coordinator_version": "v1.8.200",
            "accepted_id": "Augustas11/macprovider:v1.8.201@" + "b" * 40,
            "member_cli_sha256": "c" * 64,
            "llama_server_build": "b11149",
            "gguf_sha256": GGUF,
            "gguf_artifact_id": "gguf-q4-k-m",
            "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "pool_id": POOL,
            "manifest_version": 1,
            "manifest_core_digest": DIGEST,
            "runtime_source": "llamacpp_loopback",
            "fingerprint_salt": "f" * 64,
        },
        "artifacts": [{"id": TRUSTED_POOL_EXTERNAL_RUNTIME_ARTIFACT_ID, "sha256": "e" * 64, "source": "journeys/evidence/x"}],
        "steps": [
            {"id": step_id, "status": "pass", "artifacts": [TRUSTED_POOL_EXTERNAL_RUNTIME_ARTIFACT_ID]}
            for step_id in TRUSTED_POOL_EXTERNAL_RUNTIME_STEP_ID_ORDER
        ],
    }
    signed.update(overrides)
    return signed


def validate(signed, requirement_id="SPEC-022-R012", journeys=None):
    result = ValidationResult()
    _validate_trusted_pool_external_runtime_journey_result(
        signed,
        requirement_id,
        journeys if journeys is not None else [TRUSTED_POOL_EXTERNAL_RUNTIME_JOURNEY_ID],
        signed["artifacts"],
        signed["steps"],
        "evidence[0]",
        result,
    )
    return result.errors


class TrustedPoolExternalRuntimeValidatorTests(unittest.TestCase):
    def test_valid_payload_promotes_each_mapped_requirement(self) -> None:
        for requirement_id in ("SPEC-022-R012", "SPEC-042-R013", "SPEC-042-R014"):
            signed = valid_signed(requirement_ids=[requirement_id])
            self.assertEqual([], validate(signed, requirement_id), requirement_id)

    def test_rejects_unmapped_requirement(self) -> None:
        signed = valid_signed(requirement_ids=["SPEC-022-R007"])
        self.assertTrue(any("cannot promote SPEC-022-R007" in error for error in validate(signed, "SPEC-022-R007")))

    def test_rejects_observe_or_isolated_claims(self) -> None:
        signed = valid_signed()
        signed["observations"]["settlement_mode"] = "observe"
        self.assertTrue(any("settlement_mode" in error for error in validate(signed)))
        signed = valid_signed()
        signed["observations"]["payout_ready_mutated"] = True
        self.assertTrue(any("payout_ready_mutated" in error for error in validate(signed)))
        signed = valid_signed()
        signed["observations"]["isolated_environment"] = True
        self.assertTrue(validate(signed))

    def test_rejects_wrong_runtime_and_missing_identity(self) -> None:
        signed = valid_signed()
        signed["candidate_identity"]["runtime_source"] = "ollama_loopback"
        self.assertTrue(any("runtime_source" in error for error in validate(signed)))
        signed = valid_signed()
        del signed["candidate_identity"]["gguf_sha256"]
        self.assertTrue(any("candidate_identity" in error for error in validate(signed)))

    def test_rejects_missing_or_reordered_steps(self) -> None:
        signed = valid_signed()
        signed["steps"] = signed["steps"][:-1]
        self.assertTrue(any("missing" in error for error in validate(signed)))
        signed = valid_signed()
        signed["steps"] = list(reversed(signed["steps"]))
        self.assertTrue(any("ordered" in error for error in validate(signed)))

    def test_rejects_unmapped_journey_and_wrong_mode(self) -> None:
        self.assertTrue(validate(valid_signed(), journeys=["JOURNEY-BUYER-PAID-PATH"]))
        self.assertTrue(validate(valid_signed(execution_mode="isolated-candidate-paid-path")))

    def test_signed_payload_allowlist_accepts_candidate_identity(self) -> None:
        self.assertIn("candidate_identity", SIGNED_JOURNEY_RESULT_ALLOWED_KEYS)
        self.assertIn("observations", SIGNED_JOURNEY_RESULT_ALLOWED_KEYS)
        self.assertLessEqual(SIGNED_JOURNEY_RESULT_REQUIRED_KEYS, SIGNED_JOURNEY_RESULT_ALLOWED_KEYS)

    def test_journey_definition_lists_the_step_ids(self) -> None:
        text = (REPO_ROOT / "journeys" / f"{TRUSTED_POOL_EXTERNAL_RUNTIME_JOURNEY_ID}.md").read_text(encoding="utf-8")
        for step_id in TRUSTED_POOL_EXTERNAL_RUNTIME_STEP_ID_ORDER:
            self.assertIn(f"`{step_id}`", text)

    def test_conformance_maps_journey_without_promoting(self) -> None:
        conformance = json.loads((REPO_ROOT / "specs" / "CONFORMANCE.json").read_text(encoding="utf-8"))
        rows = {row["requirement_id"]: row for row in conformance["requirements"]}
        for requirement_id in ("SPEC-022-R012", "SPEC-042-R013", "SPEC-042-R014"):
            self.assertIn(TRUSTED_POOL_EXTERNAL_RUNTIME_JOURNEY_ID, rows[requirement_id]["journeys"])
            self.assertEqual("pending", rows[requirement_id]["state"])


class TrustedPoolExternalRuntimeCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.capture = make_capture(self.root)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def build(self):
        return BUILDER.build_evidence(self.capture)

    def assert_rejected(self, fragment: str) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            self.build()
        self.assertIn(fragment, stderr.getvalue())

    def mutate_rows(self, relative: str, **changes) -> None:
        path = self.capture / relative
        rows = json.loads(path.read_text())
        for row in rows:
            row.update(changes)
        path.write_text(json.dumps(rows))

    def mutate_object(self, relative: str, **changes) -> None:
        path = self.capture / relative
        value = json.loads(path.read_text())
        value.update(changes)
        path.write_text(json.dumps(value))

    def test_valid_capture_builds_redacted_evidence(self) -> None:
        evidence = self.build()
        self.assertEqual(BUILDER.EVIDENCE_SCHEMA, evidence["schema_version"])
        self.assertEqual(list(TRUSTED_POOL_EXTERNAL_RUNTIME_STEP_ID_ORDER), [s["id"] for s in evidence["steps"]])
        self.assertEqual(["SPEC-022-R012", "SPEC-042-R013", "SPEC-042-R014"], evidence["requirement_ids"])
        # E2E-F1: buyer-visible prompt tokens differ from the debit; recorded, not failed.
        self.assertFalse(evidence["observations"]["buyer_visible_usage_equals_debit"])
        text = json.dumps(evidence)
        for raw in (MEMBER, BUYER, OPERATOR_ACCOUNT, "operator-person-name", "2, 3, 5", "1 2 3"):
            self.assertNotIn(raw, text)
        # The payload helpers accept what capture produced.
        BUILDER.require_observations(evidence["observations"])
        BUILDER.require_candidate_identity(evidence["candidate_identity"])
        BUILDER.require_steps(evidence["steps"])
        signed = valid_signed(
            observations=evidence["observations"],
            candidate_identity=evidence["candidate_identity"],
            environment=evidence["environment"],
            steps=evidence["steps"],
        )
        self.assertEqual([], validate(signed))

    def test_rejects_unverified_receipt(self) -> None:
        self.mutate_rows("requests/nonstream/receipt_verdicts.json", settlement_outcome="quarantined")
        self.assert_rejected("receipt verdict")

    def test_rejects_global_or_observe_route(self) -> None:
        self.mutate_rows("requests/stream/route_snapshots.json", route_snapshot_mode="observe")
        self.assert_rejected("route_snapshot_mode")

    def test_rejects_wrong_gguf_identity(self) -> None:
        self.mutate_rows("requests/stream/route_snapshots.json", artifact_hash="f" * 64)
        self.assert_rejected("artifact_hash")

    def test_rejects_debit_not_equal_finality(self) -> None:
        self.mutate_rows("requests/nonstream/usage_events.json", completion_tokens=13)
        self.assert_rejected("tokens must be equal")

    def test_rejects_quarantined_or_second_payable_credit(self) -> None:
        self.mutate_rows("requests/nonstream/ledger.json", quarantined=1)
        self.assert_rejected("quarantined")

    def test_rejects_held_reservation(self) -> None:
        self.mutate_rows("requests/stream/quota_reservations.json", settlement_hold=1)
        self.assert_rejected("held")

    def test_rejects_control_that_dispatched(self) -> None:
        write(self.capture / "controls/pool-ollama-selector/route_snapshots.json", [{"request_id": "x"}])
        self.assert_rejected("route snapshot")

    def test_rejects_control_wrong_code(self) -> None:
        write(self.capture / "controls/uppercase-selector/response.json", {"error": {"code": "engine_unavailable"}})
        self.assert_rejected("error.code")

    def test_rejects_delegated_member(self) -> None:
        rows = json.loads((self.capture / "pool/trustpool-events.json").read_text())
        rows.append({"event_type": "delegation_granted", "n": 1})
        write(self.capture / "pool/trustpool-events.json", rows)
        self.assert_rejected("delegated")

    def test_rejects_manifest_digest_drift(self) -> None:
        self.mutate_object("pool/manifest-accepted.json", manifest_core_digest="9" * 64)
        self.assert_rejected("manifest digest")

    def test_rejects_failed_precondition(self) -> None:
        path = self.capture / "preconditions.json"
        value = json.loads(path.read_text())
        value["P4"]["status"] = "fail"
        path.write_text(json.dumps(value))
        self.assert_rejected("P4")

    def test_rejects_wrong_engine_header(self) -> None:
        write(self.capture / "requests/nonstream/response.headers",
              headers(200, request_id="req-ns-1", engine="mlx_cache", provider=MEMBER))
        self.assert_rejected("X-MacProvider-Engine")

    def test_rejects_stream_without_done(self) -> None:
        path = self.capture / "requests/stream/response.sse"
        path.write_text(path.read_text().replace("data: [DONE]\n\n", ""))
        self.assert_rejected("[DONE]")

    def test_fingerprints_are_salted_per_run(self) -> None:
        # #1690 review LOW: a bare sha256 of a known id links runs and is
        # reversible by dictionary; fingerprints are HMAC-SHA256 under a
        # random per-run salt recorded in candidate_identity.
        import hashlib
        import hmac

        first, second = self.build(), self.build()
        salt = first["candidate_identity"]["fingerprint_salt"]
        self.assertRegex(salt, r"^[0-9a-f]{64}$")
        self.assertNotEqual(salt, second["candidate_identity"]["fingerprint_salt"])
        member_fp = first["pool"]["member_fingerprints"][0]
        self.assertNotEqual(hashlib.sha256(MEMBER.encode()).hexdigest(), member_fp)
        self.assertEqual(hmac.new(bytes.fromhex(salt), MEMBER.encode(), hashlib.sha256).hexdigest(), member_fp)
        self.assertNotEqual(member_fp, second["pool"]["member_fingerprints"][0])
        signed = valid_signed(candidate_identity=first["candidate_identity"])
        self.assertEqual([], validate(signed))
        del signed["candidate_identity"]["fingerprint_salt"]
        self.assertTrue(any("candidate_identity" in error for error in validate(signed)))

    def set_observed(self, key: str, observed) -> None:
        path = self.capture / "preconditions.json"
        value = json.loads(path.read_text())
        value[key]["observed"] = observed
        path.write_text(json.dumps(value))

    def test_rejects_free_text_observed(self) -> None:
        # codex R1: observed is structured facts, never free text.
        for bad in ("P1 ok", "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123", f"buyer {BUYER} ready", [], {}):
            with self.subTest(bad=bad):
                self.set_observed("P1", bad)
                self.assert_rejected("preconditions.P1.observed")

    def test_rejects_credential_like_observed_facts(self) -> None:
        # codex R1: OPERATOR_KEY=<64 hex>-style credentials, prompts and
        # completions cannot ride in a fact name or value.
        for bad in (
            {"operator_key": "a" * 64},
            {"value": "OPERATOR_KEY=" + "a" * 64},
            {"value": "0123456789abcdef0123456789abcdef"},
            {"value": "c2stbGl2ZS1BQkNERUZHSElKS0xNTk9Q"},
            {"value": "Tell me a story about a dragon"},
            {"bearer": True},
            {"count": -1},
            {"count": 2**53 + 1},
            {"value": "v1.8.200.1234567:89ab"},
            {"value": "a.b.c.d.e.f.g.h.i.j.k"},
            {"Value": 1},
            {f"f{i}": 1 for i in range(9)},
        ):
            with self.subTest(bad=bad):
                self.set_observed("P2", bad)
                self.assert_rejected("preconditions.P2.observed")

    def test_rejects_symlinked_capture_parent(self) -> None:
        # codex R1: every component of the capture path is checked, not only
        # the leaf directory.
        real_parent = self.root / "real-parent"
        real_parent.mkdir()
        moved = real_parent / "capture"
        self.capture.rename(moved)
        link_parent = self.root / "link-parent"
        link_parent.symlink_to(real_parent, target_is_directory=True)
        self.capture = link_parent / "capture"
        self.assert_rejected("symlinked path component")

    def test_rejects_symlinked_capture_subdirectory(self) -> None:
        requests = self.capture / "requests"
        elsewhere = self.root / "elsewhere-requests"
        requests.rename(elsewhere)
        requests.symlink_to(elsewhere, target_is_directory=True)
        self.assert_rejected("absent or unsafe")

    def test_rejects_free_form_run_descriptors(self) -> None:
        # codex R2 LOW: model_id, operator_role and hardware_profile reach
        # signed evidence, so they get strict patterns in capture and payload.
        for field, bad in (
            ("model_id", "not a repo id"),
            ("model_id", "owner/name/extra"),
            ("model_id", "x" * 97 + "/y"),
            ("operator_role", "Pearl Actor"),
            ("operator_role", "role;rm -rf"),
            ("hardware_profile", "Mac Studio M3 Ultra 256GB"),
            ("hardware_profile", "a" * 49),
        ):
            with self.subTest(field=field, bad=bad):
                path = self.capture / "run.json"
                original = path.read_text()
                value = json.loads(original)
                value[field] = bad
                path.write_text(json.dumps(value))
                self.assert_rejected(f"run.json.{field}")
                path.write_text(original)
        evidence = self.build()
        for location, mutate in (
            ("candidate_identity.model_id", lambda e: e["candidate_identity"].__setitem__("model_id", "not a repo id")),
            ("operator.role", lambda e: e["operator"].__setitem__("role", "Pearl Actor")),
            ("environment.hardware_profile", lambda e: e["environment"].__setitem__("hardware_profile", "Mac Studio")),
        ):
            with self.subTest(location=location):
                bad = json.loads(json.dumps(evidence))
                mutate(bad)
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
                    BUILDER.require_run_descriptors(bad)
                self.assertIn(location, stderr.getvalue())

    def test_observed_facts_accept_bounds(self) -> None:
        # The largest exact integer and a 19-character token still pass.
        self.set_observed("P3", {"count": 2**53, "version": "v1.8.200-rc.1:abcd1"})
        self.build()

    def test_payload_revalidates_committed_evidence(self) -> None:
        # #1690 review L-6: payload signs committed evidence, which may have
        # been edited after capture; it re-runs the redaction checks.
        import inspect

        self.assertIn("revalidate_committed_evidence(evidence)", inspect.getsource(BUILDER.build_payload))
        evidence = self.build()
        BUILDER.revalidate_committed_evidence(evidence)
        for label, mutate in (
            ("free text observed", lambda e: e["preconditions"]["P1"].__setitem__("observed", "OPERATOR_KEY=" + "a" * 64)),
            ("credential fact", lambda e: e["preconditions"]["P2"].__setitem__("observed", {"token": "abc"})),
            ("raw identity field", lambda e: e["pool"].__setitem__("buyer_account_id", BUYER)),
            ("raw id as a fingerprint", lambda e: e["pool"].__setitem__("creator_account_fingerprint", OPERATOR_ACCOUNT)),
            ("raw member", lambda e: e["pool"].__setitem__("member_fingerprints", [MEMBER])),
            ("raw provider", lambda e: e["requests"]["nonstream"]["response"].__setitem__("provider_fingerprint", MEMBER)),
        ):
            with self.subTest(label=label):
                bad = json.loads(json.dumps(evidence))
                mutate(bad)
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
                    BUILDER.revalidate_committed_evidence(bad)

    def test_builder_requirement_ids_are_bounded(self) -> None:
        evidence = {"requirement_ids": ["SPEC-022-R012", "SPEC-022-R007"]}
        with self.assertRaises(SystemExit):
            BUILDER.parse_requirement_ids("SPEC-022-R007", evidence)
        self.assertEqual(["SPEC-022-R012"], BUILDER.parse_requirement_ids("SPEC-022-R012", evidence))
        with self.assertRaises(SystemExit):
            BUILDER.parse_requirement_ids("SPEC-042-R014", evidence)

    def test_payload_rejects_evidence_outside_the_journey_prefix(self) -> None:
        with self.assertRaises(SystemExit):
            BUILDER.require_evidence_source(REPO_ROOT, "journeys/evidence/buyer-paid-path-x.redacted.json")


if __name__ == "__main__":
    unittest.main()
