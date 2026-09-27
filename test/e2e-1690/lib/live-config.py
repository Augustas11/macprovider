#!/usr/bin/env python3
"""Render the VM's live /opt/macprovider/coordinator.yaml from a tree's tracked
phase4-coordinator/dist/coordinator.yaml (stdin -> stdout). Adapted from the
#1693 harness (test/e2e-pricing/lib/live-config.py). Text edits only, so the
file keeps production bytes everywhere else. Deliberate deviations, each
because the VM does not run that subsystem:
  - stats.enabled false, onboarding.app_track_register_enabled false;
  - storage.db_path request-log.sqlite (Pearl's live path; the tracked
    template says coordinator.db);
  - providers: the pinned fake providers.
settlement.verified_model_settlement_mode stays `enforce`, as in production.
"""
import re
import sys

PROVIDERS = [
    ("e2e-prov-1", "http://127.0.0.1:19101", "E2E fake provider 1"),
    ("e2e-prov-2", "http://127.0.0.1:19102", "E2E fake provider 2"),
    ("e2e-prov-3", "http://127.0.0.1:19103", "E2E fake provider 3 (pool member)"),
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
text = sub_in_block("storage", "db_path", '"/var/lib/macprovider/request-log.sqlite"', text)
m = re.search(r"(?m)^providers:\n((?:  .*\n|\n)*)", text)
if not m:
    raise SystemExit("providers block not found")
block = "".join('  - provider_id: "%s"\n    endpoint_url: "%s"\n    display_name: "%s"\n' % p for p in PROVIDERS)
text = text[:m.start(1)] + block + "\n" + text[m.end(1):]
sys.stdout.write(text)
