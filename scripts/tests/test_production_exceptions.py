#!/usr/bin/env python3
"""Unit tests for #615 production exception enforcement scaffolding."""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import production_exceptions as pe  # noqa: E402


NOW = datetime(2026, 7, 22, 12, 0, 0, tzinfo=timezone.utc)


def _minimal_entry(**overrides):
    base = {
        "id": "exc-test-sample",
        "status": "active",
        "environment": "pearl-production",
        "component": "coordinator",
        "policy_delta": "temporary relaxation for test",
        "authority_surface": "test overlay key",
        "reason": "unit test fixture",
        "owner": "ops/test",
        "issue": "https://github.com/Augustas11/macprovider/issues/615",
        "created_at": "2026-07-01T00:00:00Z",
        "expires_at": "2026-08-01T00:00:00Z",
        "scope": "unit-test only; must not widen to arbitrary providers",
        "removal_condition": "test complete",
        "rollback_command": "echo rollback",
        "post_removal_validation": "echo validate",
        "blocks_stable_promotion": True,
        "evidence": ["https://github.com/Augustas11/macprovider/issues/615"],
    }
    base.update(overrides)
    return base


def _minimal_register(entries=None):
    return {
        "$schema": "./production-exceptions.schema.json",
        "schema_version": pe.SCHEMA_VERSION,
        "updated_at": "2026-07-22T00:00:00Z",
        "updated_by": "unit-test",
        "environment": "pearl-production",
        "exceptions": entries or [_minimal_entry()],
        "open_questions": [],
    }


def _tombstones(rows=None):
    return {
        "schema_version": pe.TOMBSTONE_SCHEMA_VERSION,
        "updated_at": "2026-07-22T00:00:00Z",
        "updated_by": "unit-test",
        "environment": "pearl-production",
        "tombstones": rows or [],
    }


class ProductionExceptionsTests(unittest.TestCase):
    def test_committed_register_validates(self):
        doc = pe.load_json(pe.default_register_path(ROOT))
        tombstones = pe.load_json(pe.default_tombstone_path(ROOT))
        result = pe.validate_register(doc, now=NOW, tombstones=tombstones)
        self.assertEqual(result.errors, [], [f.format() for f in result.errors])

    def test_duplicate_ids_fail(self):
        doc = _minimal_register(
            [_minimal_entry(id="exc-dup"), _minimal_entry(id="exc-dup", expires_at="2026-09-01T00:00:00Z")]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code == "duplicate_ids" for f in result.errors))

    def test_ownerless_fails(self):
        doc = _minimal_register([_minimal_entry(owner="TBD")])
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code == "ownerless" for f in result.errors))

    def test_clock_boundary_expired_active_fail_closed(self):
        doc = _minimal_register(
            [_minimal_entry(status="active", expires_at="2026-07-22T12:00:00Z")]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code == "expired_active" for f in result.errors))

        doc2 = _minimal_register(
            [_minimal_entry(status="active", expires_at="2026-07-22T12:00:01Z")]
        )
        result2 = pe.validate_register(doc2, now=NOW, tombstones=_tombstones())
        self.assertFalse(any(f.code == "expired_active" for f in result2.errors))

    def test_null_expiry_requires_reason(self):
        entry = _minimal_entry(expires_at=None)
        entry.pop("expiry_unknown_reason", None)
        doc = _minimal_register([entry])
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code == "expiry_unknown" for f in result.errors))

    def test_scope_mismatch_environment(self):
        doc = _minimal_register(
            [_minimal_entry(environment="staging", scope="staging only")]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code in {"environment", "scope_mismatch"} for f in result.errors))

    def test_scope_widening_rejected(self):
        doc = _minimal_register(
            [_minimal_entry(scope="all providers in production without bounds")]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code == "scope_mismatch" for f in result.errors))

    def test_deploy_default_warns_expired_status(self):
        doc = _minimal_register(
            [_minimal_entry(status="expired", expires_at="2026-07-26T23:59:59Z")]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        gated = pe.apply_gate_policy(result, "deploy", enforce=False)
        self.assertEqual(gated.errors, [])
        self.assertTrue(any(f.code == "status_expired" for f in gated.warnings))

    def test_promote_fails_expired_and_unbounded(self):
        doc = _minimal_register(
            [
                _minimal_entry(status="expired", expires_at="2026-07-26T23:59:59Z"),
                _minimal_entry(
                    id="exc-unbounded",
                    expires_at=None,
                    expiry_unknown_reason="no pearl evidence yet",
                ),
            ]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        gated = pe.apply_gate_policy(result, "promote", enforce=False)
        codes = {f.code for f in gated.errors}
        self.assertIn("status_expired", codes)
        self.assertIn("unbounded_active", codes)

    def test_anti_resurrection_on_stale_sync(self):
        removed = _minimal_entry(id="exc-removed-sample", status="removed")
        current = _minimal_register([removed])
        stale = _minimal_register(
            [_minimal_entry(id="exc-removed-sample", status="active", expires_at="2026-08-01T00:00:00Z")]
        )
        tombstones = _tombstones(
            [
                {
                    "id": "exc-removed-sample",
                    "removed_at": "2026-07-20T00:00:00Z",
                    "removal_evidence": "unit-test removal evidence",
                    "authority_surface": "test overlay key",
                }
            ]
        )
        result = pe.simulate_config_sync_restore(current, stale, tombstones)
        self.assertTrue(any(f.code == "resurrection" for f in result.errors))

    def test_tombstone_blocks_non_removed_status(self):
        doc = _minimal_register([_minimal_entry(id="exc-ghost", status="active")])
        tombstones = _tombstones(
            [
                {
                    "id": "exc-ghost",
                    "removed_at": "2026-07-20T00:00:00Z",
                    "removal_evidence": "unit-test",
                    "authority_surface": "test",
                }
            ]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=tombstones)
        self.assertTrue(any(f.code == "resurrection" for f in result.errors))

    def test_health_report_redacts_secrets_and_lists_active(self):
        doc = _minimal_register(
            [
                _minimal_entry(
                    policy_delta="uses Bearer SUPERSECRETTOKEN123 and still temporary",
                    reason="password: hunter2 should not appear",
                )
            ]
        )
        report = pe.build_health_report(doc, now=NOW)
        blob = json.dumps(report)
        self.assertNotIn("SUPERSECRETTOKEN123", blob)
        self.assertNotIn("hunter2", blob)
        self.assertIn("[REDACTED]", blob)
        self.assertTrue(report["secrets_redacted"])
        self.assertEqual(report["counts"]["active"], 1)

    def test_cli_gate_and_report_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            register = tmp_path / "production-exceptions.json"
            tombs = tmp_path / "removed-exception-tombstones.json"
            register.write_text(json.dumps(_minimal_register()), encoding="utf-8")
            tombs.write_text(json.dumps(_tombstones()), encoding="utf-8")
            out = tmp_path / "report.json"
            rc = pe.main(
                [
                    "--register",
                    str(register),
                    "--tombstones",
                    str(tombs),
                    "--now",
                    "2026-07-22T12:00:00Z",
                    "report",
                    "-o",
                    str(out),
                ]
            )
            self.assertEqual(rc, 0)
            self.assertTrue(out.is_file())
            rc_gate = pe.main(
                [
                    "--register",
                    str(register),
                    "--tombstones",
                    str(tombs),
                    "--now",
                    "2026-07-22T12:00:00Z",
                    "gate",
                    "--mode",
                    "deploy",
                ]
            )
            self.assertEqual(rc_gate, 0)

    def test_previous_removed_restored_detected(self):
        previous = _minimal_register(
            [_minimal_entry(id="exc-was-removed", status="removed")]
        )
        nxt = copy.deepcopy(previous)
        nxt["exceptions"][0]["status"] = "active"
        nxt["exceptions"][0]["expires_at"] = "2026-08-01T00:00:00Z"
        result = pe.validate_register(
            nxt, now=NOW, tombstones=_tombstones(), previous_doc=previous
        )
        self.assertTrue(any(f.code == "resurrection" for f in result.errors))


if __name__ == "__main__":
    unittest.main()
