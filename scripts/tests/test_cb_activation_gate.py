#!/usr/bin/env python3
"""Hermetic tests for scripts/cb_activation_gate.py."""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cb_activation_gate", REPO / "scripts" / "cb_activation_gate.py")
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

NOW = "2026-10-06T12:00:00Z"
H = lambda c: c * 64  # noqa: E731
CDHASH = "ab" * 20

TUPLE = {
    "model_id": "example/model-a",
    "model_sha256": H("1"),
    "tokenizer_sha256": H("2"),
    "chat_template_sha256": H("3"),
    "cache_class": "mixed",
    "kv_dtype": "fp16",
    "requires_moe": True,
    "hardware_class": "m3-ultra-512",
    "metallib_sha256": H("4"),
    "kernel_identifier": "paged-kv-v1",
    "provider_cli_version": "1.8.217",
    "live_executable_cdhash": CDHASH,
}


def entry(rollout: str = "canary", **overrides) -> dict:
    t = dict(TUPLE, **overrides)
    return {
        "tuple_sha256": H("9"),
        "model_key": t["model_id"],
        "model_id": t["model_id"],
        "model_sha256": t["model_sha256"],
        "tokenizer_sha256": t["tokenizer_sha256"],
        "chat_template_sha256": t["chat_template_sha256"],
        "cache_class": t["cache_class"],
        "kv_dtype": t["kv_dtype"],
        "requires_moe": t["requires_moe"],
        "hardware_class": t["hardware_class"],
        "metallib_sha256": t["metallib_sha256"],
        "kernel_identifier": t["kernel_identifier"],
        "rollout": rollout,
        "cached_turns_accepted": False,
        "provenance": {
            "source": "packaged_studio_campaign",
            "status": "qualified",
            "evidence_id": "ev-1",
            "package_manifest_sha256": H("5"),
            "studio_campaign_sha256": H("6"),
            "provider_cli_version": t["provider_cli_version"],
            "live_executable_cdhash": t["live_executable_cdhash"],
        },
    }


def policy(*entries: dict, release: str = "rel-b", generated: str = "2026-10-01T00:00:00Z", expires: str = "2026-12-01T00:00:00Z") -> dict:
    return {
        "schema_version": gate.POLICY_SCHEMA,
        "release_id": release,
        "policy_version": "autotune-policy-v1",
        "generated_at": generated,
        "expires_at": expires,
        "candidate_catalog_sha256": H("7"),
        "signer_key_id": "key-1",
        "entries": list(entries),
    }


def provider(pid: str, *, cb: dict | None | str = "active", model: str = "example/model-a", slots_free: int = 3) -> dict:
    row = {"provider_id": pid, "model_id": model, "state": "ready", "routing_eligible": True, "slots_free": slots_free, "slots_total": 8}
    if cb == "active":
        row["continuous_batching"] = {"active": True, "authorization_source": "coordinator", "runtime_tuple": dict(TUPLE)}
    elif cb == "inactive":
        row["continuous_batching"] = {"active": False, "authorization_source": "coordinator", "runtime_tuple": None}
    elif isinstance(cb, dict):
        row["continuous_batching"] = cb
    return row


def poolz(*rows: dict, reports: bool = True) -> dict:
    summary = {"ready": len(rows)}
    if reports:
        summary["continuous_batching_active"] = 0
        summary["continuous_batching_reporting"] = 0
    return {"pool": list(rows), "summary": summary}


def now():
    return gate._now(NOW)


class PreflightTests(unittest.TestCase):
    def test_active_tuple_still_authorized_passes(self) -> None:
        r = gate.preflight(poolz(provider("p1")), policy(entry()), policy(entry(), release="rel-a"), now())
        self.assertEqual(r["at_risk"], [])
        self.assertEqual(r["cb_active"], 1)

    def test_empty_incoming_policy_deauthorizes_active_tuple(self) -> None:
        r = gate.preflight(poolz(provider("p1")), policy(), policy(entry(), release="rel-a"), now())
        kinds = [x["kind"] for x in r["at_risk"]]
        self.assertIn("active_tuple_deauthorized", kinds)

    def test_rollout_off_and_expired_policy_do_not_authorize(self) -> None:
        for incoming in (policy(entry("off")), policy(entry(), expires="2026-10-06T11:00:00Z"),
                         policy(entry(), generated="2026-10-06T13:00:00Z")):
            r = gate.preflight(poolz(provider("p1")), incoming, None, now())
            self.assertTrue(r["at_risk"], incoming)

    def test_any_identity_field_change_deauthorizes(self) -> None:
        for field in ("metallib_sha256", "provider_cli_version", "live_executable_cdhash", "hardware_class"):
            value = "ff" * 20 if field == "live_executable_cdhash" else (H("f") if field.endswith("sha256") else "other")
            r = gate.preflight(poolz(provider("p1")), policy(entry(**{field: value})), None, now())
            self.assertTrue(r["at_risk"], field)

    def test_inactive_and_non_coordinator_sources_are_unaffected(self) -> None:
        baked = {"active": True, "authorization_source": "baked_empty_off", "runtime_tuple": None}
        r = gate.preflight(poolz(provider("p1", cb="inactive"), provider("p2", cb=baked)), policy(), None, now())
        self.assertEqual(r["at_risk"], [])

    def test_active_without_tuple_fails_closed(self) -> None:
        cb = {"active": True, "authorization_source": "coordinator", "runtime_tuple": None}
        r = gate.preflight(poolz(provider("p1", cb=cb)), policy(entry()), None, now())
        self.assertEqual(r["at_risk"][0]["kind"], "active_tuple_unreported")

    def test_old_coordinator_falls_back_to_policy_diff(self) -> None:
        rows = poolz(provider("p1", cb=None), reports=False)
        r = gate.preflight(rows, policy(), policy(entry(), release="rel-a"), now())
        self.assertFalse(r["coordinator_reports_cb"])
        self.assertEqual(r["at_risk"][0]["kind"], "live_tuple_dropped")
        self.assertEqual(r["at_risk"][0]["providers"], ["p1"])
        self.assertTrue(r["warnings"])

    def test_policy_diff_ignores_models_nobody_serves(self) -> None:
        rows = poolz(provider("p1", cb=None, model="example/other"), reports=False)
        r = gate.preflight(rows, policy(), policy(entry(), release="rel-a"), now())
        self.assertEqual(r["at_risk"], [])
        self.assertEqual(len(r["dropped_tuples"]), 1)

    def test_policy_diff_skips_reporting_providers(self) -> None:
        r = gate.preflight(poolz(provider("p1", cb="inactive")), policy(), policy(entry(), release="rel-a"), now())
        self.assertEqual(r["at_risk"], [])

    def test_malformed_inputs_refuse(self) -> None:
        bad_policy = policy(entry())
        bad_policy["entries"][0]["requires_moe"] = "yes"
        with self.assertRaises(gate.GateError):
            gate.preflight(poolz(provider("p1")), bad_policy, None, now())
        with self.assertRaises(gate.GateError):
            gate.preflight({"pool": "x"}, policy(), None, now())
        with self.assertRaises(gate.GateError):
            gate.preflight(poolz(provider("p1"), provider("p1")), policy(), None, now())
        with self.assertRaises(gate.GateError):
            gate.preflight(poolz(provider("p1", cb={"active": "yes"})), policy(), None, now())
        wrong = policy()
        wrong["schema_version"] = "other"
        with self.assertRaises(gate.GateError):
            gate.preflight(poolz(), wrong, None, now())


class CompareTests(unittest.TestCase):
    def snap(self, *rows, reports=True):
        return gate.snapshot_record(poolz(*rows, reports=reports))

    def test_snapshot_counts(self) -> None:
        s = self.snap(provider("p1", slots_free=4), provider("p2", cb="inactive", slots_free=2))
        self.assertEqual(s["cb_active_ids"], ["p1"])
        self.assertEqual(s["free_slots"], 6)

    def test_lost_cb_provider_fails(self) -> None:
        r = gate.compare(self.snap(provider("p1")), self.snap(provider("p1", cb="inactive")),
                         max_cb_drop=0, max_free_drop_pct=25, free_slack=2)
        self.assertEqual(r["failures"], ["cb_active_dropped"])
        self.assertEqual(r["cb_lost_providers"], ["p1"])

    def test_free_slot_drop_beyond_tolerance_fails(self) -> None:
        r = gate.compare(self.snap(provider("p1", slots_free=8)), self.snap(provider("p1", slots_free=3)),
                         max_cb_drop=0, max_free_drop_pct=25, free_slack=2)
        self.assertEqual(r["failures"], ["free_slots_dropped"])
        r = gate.compare(self.snap(provider("p1", slots_free=8)), self.snap(provider("p1", slots_free=4)),
                         max_cb_drop=0, max_free_drop_pct=25, free_slack=2)
        self.assertEqual(r["failures"], [])

    def test_cb_not_judged_when_either_side_lacks_reporting(self) -> None:
        r = gate.compare(self.snap(provider("p1", cb=None), reports=False), self.snap(provider("p1", cb="inactive")),
                         max_cb_drop=0, max_free_drop_pct=25, free_slack=2)
        self.assertFalse(r["cb_judged"])
        self.assertEqual(r["failures"], [])


class CliTests(unittest.TestCase):
    def run_cli(self, *args: str) -> tuple[int, dict | None]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = gate.main(list(args))
        text = out.getvalue().strip()
        return rc, json.loads(text) if text else None

    def write(self, d: Path, name: str, value: object) -> str:
        path = d / name
        path.write_text(json.dumps(value))
        return str(path)

    def test_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            pz = self.write(d, "poolz.json", poolz(provider("p1")))
            good = self.write(d, "good.json", policy(entry()))
            empty = self.write(d, "empty.json", policy())
            self.assertEqual(self.run_cli("preflight", "--poolz-json", pz, "--incoming-policy-json", good, "--now", NOW)[0], 0)
            rc, report = self.run_cli("preflight", "--poolz-json", pz, "--incoming-policy-json", empty, "--now", NOW)
            self.assertEqual(rc, 4)
            self.assertEqual(report["schema"], gate.SCHEMA)
            self.assertEqual(self.run_cli("preflight", "--poolz-json", str(d / "missing"), "--incoming-policy-json", good)[0], 1)
            rc, before = self.run_cli("snapshot", "--poolz-json", pz)
            self.assertEqual(rc, 0)
            b = self.write(d, "before.json", before)
            after = self.write(d, "after.json", gate.snapshot_record(poolz(provider("p1", cb="inactive"))))
            self.assertEqual(self.run_cli("compare", "--before", b, "--after", after)[0], 5)
            self.assertEqual(self.run_cli("compare", "--before", b, "--after", b)[0], 0)
            self.assertEqual(self.run_cli("compare", "--before", b, "--after", pz)[0], 1)

    def test_shipped_policy_parses(self) -> None:
        shipped = json.loads((REPO / "phase3-binary/catalog/autotune/continuous-batching-policy.json").read_text())
        gate.policy_identities(copy.deepcopy(shipped), now())


if __name__ == "__main__":
    unittest.main()
