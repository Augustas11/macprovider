#!/usr/bin/env python3
"""Hermetic tests for hardware-trust waiting alerts in macprovider-monitor."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MONITOR_PATH = ROOT / "phase4-coordinator/dist/monitor/macprovider-monitor.py"


def load_monitor():
    spec = importlib.util.spec_from_file_location("macprovider_monitor", MONITOR_PATH)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class HardwareTrustWaitingAlertsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = load_monitor()

    def test_new_job_emits_waiting_new(self):
        now = datetime(2026, 8, 7, 12, 0, tzinfo=timezone.utc)
        alerts, state = self.m.hardware_trust_waiting_alerts(
            {},
            {"hardware_trust_waiting": {"job_ids": []}},
            {
                "waiting_trust": [
                    {
                        "job_id": 42,
                        "provider_id": "mp-abc",
                        "decision_reason": "missing_trusted_hardware_identity",
                        "approvable": True,
                    }
                ],
                "count": 1,
            },
            now=now,
        )
        self.assertEqual(len(alerts), 1)
        sev, kind, msg = alerts[0]
        self.assertEqual(sev, "WARN")
        self.assertEqual(kind, self.m.KIND_HARDWARE_TRUST)
        self.assertIn("hardware_trust_waiting_new", msg)
        self.assertIn("job_id=42", msg)
        self.assertEqual(state["job_ids"], [42])
        self.assertEqual(state["first_seen_utc"], "2026-08-07T12:00:00Z")
        self.assertFalse(state["stale_alerted"])

    def test_stale_backlog_alerts_once(self):
        now = datetime(2026, 8, 7, 12, 10, tzinfo=timezone.utc)
        prev = {
            "hardware_trust_waiting": {
                "job_ids": [7],
                "first_seen_utc": "2026-08-07T12:00:00Z",
                "stale_alerted": False,
            }
        }
        payload = {
            "waiting_trust": [
                {
                    "job_id": 7,
                    "provider_id": "p_one",
                    "decision_reason": "missing_trusted_hardware_identity",
                    "approvable": True,
                }
            ]
        }
        alerts, state = self.m.hardware_trust_waiting_alerts({}, prev, payload, now=now)
        self.assertEqual(len(alerts), 1)
        self.assertIn("hardware_trust_waiting_stale", alerts[0][2])
        self.assertTrue(state["stale_alerted"])

        alerts2, state2 = self.m.hardware_trust_waiting_alerts({}, {"hardware_trust_waiting": state}, payload, now=now + timedelta(minutes=3))
        self.assertEqual(alerts2, [])
        self.assertTrue(state2["stale_alerted"])

    def test_kind_not_muted_by_default(self):
        muted = self.m.muted_kinds({})
        self.assertNotIn(self.m.KIND_HARDWARE_TRUST, muted)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as _:
        raise SystemExit(unittest.main(verbosity=2))
