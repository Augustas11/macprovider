#!/usr/bin/env python3
"""#1690 e2e: create, publish and promote one SPEC-042 Trusted Pool on the VM
coordinator (adapted from scripts/lab/1690-m6/pool_setup.py). Runbook section
4 order: creator approval, root nonce, pool_created, signed root, signed v2
manifest (runtime_allowlist, settlement enforce), member_admitted,
buyer_authorized, promote. Launch environment `candidate` (see the plan: the
production_activation evidence of runbook sections 1-3/5-7 is out of scope).
  pool-setup.py create NAME --buyer ACCOUNT --provider ID --models M [--runtime-allowlist csv] [--encoding 2]
  pool-setup.py lifecycle NAME STATE          (set-lifecycle, e.g. paused / active)
  pool-setup.py manifest NAME [--runtime-allowlist csv]   (next manifest version)
"""
import argparse, hashlib, json, os, pathlib, subprocess, sys, urllib.error, urllib.request
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path("/root/e2e/pools")
ADMIN = "http://127.0.0.1:8444"
LABTOOL = "/root/e2e/bins/labtool"
CREATOR, APPROVAL, APPROVAL_VERSION = "acct-e2e-1690-creator", "approval-e2e-1690-v1", "approval-version-1"


def opkey():
    for line in open("/etc/macprovider/coordinator.env"):
        if line.startswith("OPERATOR_KEY="):
            return line.split("=", 1)[1].strip()


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def admin(method, path, body=None, expect=(200, 201, 202)):
    req = urllib.request.Request(ADMIN + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + opkey(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    doc = json.loads(raw) if raw.strip() else {}
    print("  %-6s %-60s -> %s" % (method, path[:60], status))
    if status == 500 and (doc.get("error") or {}).get("code") == "registry_refresh_failed":
        # The event is already durable (the handler appends before it
        # republishes); the post-append registry refresh lost a race with the
        # periodic refresher. Recorded as a finding; the operator sequence
        # continues once the refresher republishes.
        print("  REGISTRY_REFRESH_FAILED %s %s (event durable; continuing)" % (method, path))
        import time; time.sleep(3)
        return status, doc
    if status not in expect:
        sys.exit("%s %s -> %s: %s" % (method, path, status, json.dumps(doc)[:600]))
    return status, doc


def h(s):
    return hashlib.sha256(s.encode()).hexdigest()


def labtool(*args):
    return subprocess.run([LABTOOL, *args], check=True, capture_output=True, text=True).stdout.strip()


def creator():
    ts = datetime.now(timezone.utc)
    f = lambda d: (ts + timedelta(days=d)).strftime("%Y-%m-%dT%H:%M:%SZ")
    admin("POST", "/admin/trust-pools/creators", {
        "creator_account_id": CREATOR, "approval_record_id": APPROVAL, "current_approval_version": APPROVAL_VERSION,
        "public_display_name": "E2E 1690 Creator", "legal_support_contact": "legal@e2e.invalid",
        "billing_contact": "billing@e2e.invalid", "emergency_notification_endpoint": "https://e2e.invalid/emergency",
        "acknowledged_max_response_time": "15m", "allowed_product_category": "design-partner",
        "data_retention_category": "standard", "support_owner": "e2e-ops", "allowed_launch_environment": "candidate",
        "creator_agreement_id": "agreement-e2e-1690", "creator_agreement_version": "v1",
        "creator_agreement_expires_at_utc": f(30), "creator_agreement_grace_ends_at_utc": f(31),
        "pricing_schedule_id": "pricing-e2e-1690", "pricing_schedule_version": "v1",
        "prohibited_claim_acknowledgment_hash": h("claims"), "buyer_disclosure_commitment_hash": h("disclosure"),
        "approval_criteria_hash": h("criteria"), "approved_by": "e2e-operator",
        "approved_at_utc": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "status": "enabled"})


def manifest_args(d, a, prev):
    n = len(list(d.glob("manifest-v*.json"))) + 1
    out = ["pool-manifest", "--keys", str(d / "keys.json"), "--op", "op-%s-manifest-%d" % (d.name, n), "--encoding", str(a.encoding),
           "--settlement-mode", "enforce", "--models", a.models, "--window-seconds", str(30 * 24 * 3600)]
    if a.runtime_allowlist:
        out += ["--runtime-allowlist", a.runtime_allowlist]
    if prev:
        out += ["--prev", str(prev)]
    return out


def create(a):
    d = ROOT / a.name
    d.mkdir(parents=True, exist_ok=False)
    creator()
    pool_id = labtool("pool-keygen", "--out", str(d / "keys.json"))
    _, nd = admin("POST", "/admin/trust-pools/root-registration-nonces", {
        "operation_id": "op-%s-nonce" % a.name, "creator_account_id": CREATOR, "approval_record_id": APPROVAL,
        "current_approval_version": APPROVAL_VERSION, "launch_environment": "candidate", "purpose": "root_issuer_registration",
        "expires_at_utc": (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")})
    nonce = nd["root_registration_nonce"]
    admin("POST", "/admin/trust-pools/events", {"operation_id": "op-%s-create" % a.name, "timestamp_utc": now(), "event_type": "pool_created",
                                                "pool_id": pool_id, "creator_account_id": CREATOR, "approval_record_id": APPROVAL})
    root = json.loads(labtool("pool-root", "--keys", str(d / "keys.json"), "--op", "op-%s-root" % a.name, "--creator", CREATOR,
                              "--approval", APPROVAL, "--approval-version", APPROVAL_VERSION, "--nonce", nonce["nonce"], "--nonce-expiry", nonce["expires_at_utc"]))
    admin("POST", "/admin/trust-pools/events", root)
    m = json.loads(labtool(*manifest_args(d, a, None)))
    (d / "manifest-v1.json").write_text(json.dumps(m))
    admin("POST", "/admin/trust-pools/events", m)
    admin("POST", "/admin/trust-pools/events", {"operation_id": "op-%s-member" % a.name, "timestamp_utc": now(), "event_type": "member_admitted",
                                                "pool_id": pool_id, "provider_id": a.provider})
    admin("POST", "/admin/trust-pools/events", {"operation_id": "op-%s-buyer" % a.name, "timestamp_utc": now(), "event_type": "buyer_authorized",
                                                "pool_id": pool_id, "buyer_account_id": a.buyer})
    admin("POST", "/admin/trust-pools/pools/%s/promote" % pool_id, {"operation_id": "op-%s-promote" % a.name, "reason": "e2e-1690"})
    (d / "pool_id").write_text(pool_id + "\n")
    print(pool_id)


def lifecycle(a):
    pool_id = (ROOT / a.name / "pool_id").read_text().strip()
    op = "op-%s-lifecycle-%s-%d" % (a.name, a.state, int(datetime.now().timestamp()))
    admin("POST", "/admin/trust-pools/pools/%s/lifecycle" % pool_id, {"operation_id": op, "lifecycle": a.state, "reason": "e2e-1690"})


def promote(a):
    pool_id = (ROOT / a.name / "pool_id").read_text().strip()
    admin("POST", "/admin/trust-pools/pools/%s/promote" % pool_id, {"operation_id": "op-%s-promote-%d" % (a.name, int(datetime.now().timestamp())), "reason": "e2e-1690 resume"})


def manifest(a):
    d = ROOT / a.name
    prev = sorted(d.glob("manifest-v*.json"), key=lambda p: int(p.stem.split("-v")[1]))[-1]
    ev = json.loads(labtool(*manifest_args(d, a, prev)))
    (d / ("manifest-v%s.json" % ev["manifest_version"])).write_text(json.dumps(ev))
    admin("POST", "/admin/trust-pools/events", ev)


p = argparse.ArgumentParser()
sub = p.add_subparsers(dest="cmd", required=True)
c = sub.add_parser("create"); c.add_argument("name"); c.add_argument("--buyer", required=True); c.add_argument("--provider", required=True)
c.add_argument("--models", required=True); c.add_argument("--runtime-allowlist", default=""); c.add_argument("--encoding", type=int, default=2)
l = sub.add_parser("lifecycle"); l.add_argument("name"); l.add_argument("state")
m = sub.add_parser("manifest"); m.add_argument("name"); m.add_argument("--models", required=True); m.add_argument("--runtime-allowlist", default=""); m.add_argument("--encoding", type=int, default=2)
r = sub.add_parser("promote"); r.add_argument("name")
a = p.parse_args()
{"create": create, "lifecycle": lifecycle, "manifest": manifest, "promote": promote}[a.cmd](a)
