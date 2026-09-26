#!/usr/bin/env python3
"""Render the VM's *live* /opt/macprovider/coordinator.yaml from a tag's tracked
phase4-coordinator/dist/coordinator.yaml (stdin -> stdout).

Pearl's live yaml is operator-owned and differs from the tracked template; the
lane only requires that everything outside rewards.rate_card stays put. The
edits below are the E2 host's deliberate deviations from production, each one
because the VM does not run that subsystem:
  - stats.enabled false, onboarding.app_track_register_enabled false: no
    Postgres stats/onboarding service in the VM (not the seam under test);
  - settlement.verified_model_settlement_mode observe: fake providers (the
    E1 fake, ported) are not a signed-model-settlement surface;
  - providers: the harness's pinned fake providers + the canary stand-in.
Text edits only (the file keeps its 2-space layout and every comment), so the
lane's rate_card splice sees production-shaped bytes.
"""
import re
import sys

PROVIDERS = [
    ("e2e-prov-1", "http://127.0.0.1:19101", "E2E fake provider 1"),
    ("e2e-prov-2", "http://127.0.0.1:19102", "E2E fake provider 2"),
    ("e2e-canary-provider", "http://127.0.0.1:19190", "E2E canary stand-in (Mac, reverse tunnel)"),
]

text = sys.stdin.read()


def sub_in_block(block, key, value, text):
    m = re.search(r"(?m)^%s:\n((?:[ #].*\n|\n)*)" % re.escape(block), text)
    if not m:
        raise SystemExit("block %s not found" % block)
    body = m.group(1)
    new_body, n = re.subn(r"(?m)^(  %s:)[ \t]*[^\n#]*?([ \t]*(#.*)?)$" % re.escape(key),
                          lambda mm: "%s %s%s" % (mm.group(1), value, mm.group(2) or ""), body, count=1)
    if n != 1:
        raise SystemExit("key %s.%s not found" % (block, key))
    return text[:m.start(1)] + new_body + text[m.end(1):]


text = sub_in_block("stats", "enabled", "false", text)
text = sub_in_block("onboarding", "app_track_register_enabled", "false", text)
# Pearl's live storage.db_path is request-log.sqlite (deploy-pearl-vps.sh ACLs,
# stats-billing-mirror and the pricing lane all hardcode it); the tracked
# template says coordinator.db.
if 'db_path: "/var/lib/macprovider/coordinator.db"' in text:
    text = text.replace('db_path: "/var/lib/macprovider/coordinator.db"', 'db_path: "/var/lib/macprovider/request-log.sqlite"', 1)
elif 'db_path: "/var/lib/macprovider/request-log.sqlite"' not in text:
    raise SystemExit("storage.db_path not found")
text = sub_in_block("settlement", "verified_model_settlement_mode", "observe", text)

m = re.search(r"(?m)^providers:\n((?:  .*\n|\n)*)", text)
if not m:
    raise SystemExit("providers block not found")
block = "".join(
    '  - provider_id: "%s"\n    endpoint_url: "%s"\n    display_name: "%s"\n' % p for p in PROVIDERS
)
text = text[:m.start(1)] + block + "\n" + text[m.end(1):]
sys.stdout.write(text)
