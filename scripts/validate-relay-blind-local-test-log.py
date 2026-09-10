#!/usr/bin/env python3
"""Require every local relay-blind journey test to have actually passed."""

from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_TESTS = {
    "TestRelayBlindReservationFailClosedAcrossRealServices",
    "TestRelayBlindReservationFailClosedAcrossRealServices/default_off",
    "TestRelayBlindReservationFailClosedAcrossRealServices/gateway_only_mixed_version",
    "TestRelayBlindReservationFailClosedAcrossRealServices/provider_lacks_signed_key",
    "TestRelayBlindDisabledEnvelopeDoesNotLeakOpaqueMaterial",
    "TestRelayBlindReplaySurvivesGatewayRestartAndEnableCycle",
    "TestRelayBlindConcurrentEnvelopeAdmitsAtMostOnce",
    "TestRelayBlindSwiftProviderNonstreamEndToEnd",
    "TestRelayBlindSwiftProviderStreamEndToEnd",
    "TestRelayBlindSwiftProviderReconnectRecovery",
    "TestRelayBlindSwiftProviderDisconnectBoundaries/disconnect_before_dispatch",
    "TestRelayBlindSwiftProviderDisconnectBoundaries/disconnect_after_first_chunk",
    "TestRelayBlindSwiftProviderDisconnectBoundaries/buyer_cancel_after_first_chunk",
    "TestRelayBlindSwiftProviderDisconnectBoundaries/process_crash_after_first_chunk",
    "TestRelayBlindSwiftProviderDisconnectBoundaries/underdeclared_input_bound",
    "TestRelayBlindSwiftProviderDisconnectBoundaries/tampered_aead",
    "TestRelayBlindReservationRejectsPoolSelectionBeforeQuota",
}


def nonpassing_tests(path: Path) -> dict[str, str]:
    actions: dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            test, action = event.get("Test"), event.get("Action")
            if test in REQUIRED_TESTS and action in {"pass", "fail", "skip"}:
                actions[test] = action
    return {name: actions.get(name, "missing") for name in sorted(REQUIRED_TESTS) if actions.get(name) != "pass"}


def main() -> int:
    bad = nonpassing_tests(Path(sys.argv[1]))
    if bad:
        print("required relay-blind tests did not pass: " + json.dumps(bad, sort_keys=True), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
