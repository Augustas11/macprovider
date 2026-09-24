#!/usr/bin/env python3
"""Create, publish, and promote one lab SPEC-042 Trusted Pool.

  pool_setup.py create NAME --encoding 1|2 [--runtime-allowlist csv] [--window-seconds N]
  pool_setup.py manifest NAME --encoding 1|2 [--runtime-allowlist csv] [--window-seconds N]
      (appends the next manifest version, starting when the current one ends)
  pool_setup.py event NAME EVENT_TYPE [--provider-id ID]   (member_revoked etc.)

Talks only to the lab coordinator admin surface on 127.0.0.1:19102 with the
lab operator key; pool keys and signed events live under LAB/pools/NAME.
"""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

LAB = pathlib.Path(os.environ.get("LAB", "/Users/a1/lab-1690-m6"))
ADMIN = "http://127.0.0.1:19102"
CREATOR = "acct-lab-1690-creator"
APPROVAL = "approval-lab-1690-v1"
APPROVAL_VERSION = "approval-version-1"
PROVIDER = "lab-1690-m6-provider"
BUYER = "acct-lab-1690-buyer"
MODELS = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
LABTOOL = str(LAB / "bin" / "labtool")


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def admin(method, path, body=None, expect=(200, 201, 202)):
    key = json.loads((LAB / "keys" / "secrets.json").read_text())["operator_key"]
    req = urllib.request.Request(ADMIN + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as err:
        status, raw = err.code, err.read()
    doc = json.loads(raw) if raw.strip() else {}
    if status not in expect:
        sys.exit(f"{method} {path} -> {status}: {json.dumps(doc)[:600]}")
    return status, doc


def post_event(event):
    status, doc = admin("POST", "/admin/trust-pools/events", event)
    print(f"  {event['event_type']:<22} -> {status}")
    return doc


def h(s):
    return hashlib.sha256(s.encode()).hexdigest()


def ensure_creator():
    ts = datetime.now(timezone.utc)
    body = {
        "creator_account_id": CREATOR, "approval_record_id": APPROVAL, "current_approval_version": APPROVAL_VERSION,
        "public_display_name": "Lab 1690 M6 Creator", "legal_support_contact": "legal@lab.invalid",
        "billing_contact": "billing@lab.invalid", "emergency_notification_endpoint": "https://lab.invalid/emergency",
        "acknowledged_max_response_time": "15m", "allowed_product_category": "design-partner",
        "data_retention_category": "standard", "support_owner": "lab-ops", "allowed_launch_environment": "candidate",
        "creator_agreement_id": "agreement-lab-1690", "creator_agreement_version": "v1",
        "creator_agreement_expires_at_utc": (ts + timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "creator_agreement_grace_ends_at_utc": (ts + timedelta(days=31)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pricing_schedule_id": "pricing-lab-1690", "pricing_schedule_version": "v1",
        "prohibited_claim_acknowledgment_hash": h("lab prohibited claims"), "buyer_disclosure_commitment_hash": h("lab disclosure"),
        "approval_criteria_hash": h("lab approval criteria"), "approved_by": "lab-operator",
        "approved_at_utc": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "status": "enabled",
    }
    status, _ = admin("POST", "/admin/trust-pools/creators", body)
    print(f"creator upsert -> {status}")


def labtool(*args):
    return subprocess.run([LABTOOL, *args], check=True, capture_output=True, text=True).stdout.strip()


def manifest_args(name, args, prev):
    out = ["pool-manifest", "--keys", str(pool_dir(name) / "keys.json"), "--op", f"op-{name}-manifest-{len(list(pool_dir(name).glob('manifest-v*.json'))) + 1}",
           "--encoding", str(args.encoding), "--settlement-mode", args.settlement_mode, "--models", MODELS,
           "--window-seconds", str(args.window_seconds)]
    if args.runtime_allowlist:
        out += ["--runtime-allowlist", args.runtime_allowlist]
    if prev:
        out += ["--prev", str(prev)]
    return out


def pool_dir(name):
    return LAB / "pools" / name


def create(args):
    d = pool_dir(args.name)
    d.mkdir(parents=True, exist_ok=False)
    ensure_creator()
    pool_id = labtool("pool-keygen", "--out", str(d / "keys.json"))
    print(f"pool {args.name} pool_id={pool_id}")
    _, nonce_doc = admin("POST", "/admin/trust-pools/root-registration-nonces", {
        "operation_id": f"op-{args.name}-nonce", "creator_account_id": CREATOR, "approval_record_id": APPROVAL,
        "current_approval_version": APPROVAL_VERSION, "launch_environment": "candidate", "purpose": "root_issuer_registration",
        "expires_at_utc": (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")})
    nonce = nonce_doc["root_registration_nonce"]
    post_event({"operation_id": f"op-{args.name}-create", "timestamp_utc": now(), "event_type": "pool_created",
                "pool_id": pool_id, "creator_account_id": CREATOR, "approval_record_id": APPROVAL})
    root = json.loads(labtool("pool-root", "--keys", str(d / "keys.json"), "--op", f"op-{args.name}-root", "--creator", CREATOR,
                              "--approval", APPROVAL, "--approval-version", APPROVAL_VERSION,
                              "--nonce", nonce["nonce"], "--nonce-expiry", nonce["expires_at_utc"]))
    (d / "root.json").write_text(json.dumps(root))
    post_event(root)
    manifest = json.loads(labtool(*manifest_args(args.name, args, None)))
    (d / "manifest-v1.json").write_text(json.dumps(manifest))
    post_event(manifest)
    post_event({"operation_id": f"op-{args.name}-member", "timestamp_utc": now(), "event_type": "member_admitted",
                "pool_id": pool_id, "provider_id": PROVIDER})
    post_event({"operation_id": f"op-{args.name}-buyer", "timestamp_utc": now(), "event_type": "buyer_authorized",
                "pool_id": pool_id, "buyer_account_id": BUYER})
    status, doc = admin("POST", f"/admin/trust-pools/pools/{pool_id}/promote", {"operation_id": f"op-{args.name}-promote", "reason": "lab-1690-m6"})
    print(f"  promote                -> {status}")
    (d / "pool_id").write_text(pool_id + "\n")


def manifest(args):
    d = pool_dir(args.name)
    versions = sorted(d.glob("manifest-v*.json"), key=lambda p: int(p.stem.split("-v")[1]))
    prev = versions[-1]
    event = json.loads(labtool(*manifest_args(args.name, args, prev)))
    (d / f"manifest-v{event['manifest_version']}.json").write_text(json.dumps(event))
    post_event(event)
    print(f"manifest v{event['manifest_version']} digest={event['manifest_core_digest']}")


def event(args):
    pool_id = (pool_dir(args.name) / "pool_id").read_text().strip()
    body = {"operation_id": f"op-{args.name}-{args.event_type}-{datetime.now().timestamp():.0f}", "timestamp_utc": now(),
            "event_type": args.event_type, "pool_id": pool_id}
    if args.provider_id:
        body["provider_id"] = args.provider_id
    post_event(body)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for cmd in ("create", "manifest"):
        s = sub.add_parser(cmd)
        s.add_argument("name")
        s.add_argument("--encoding", type=int, default=2)
        s.add_argument("--runtime-allowlist", default="")
        s.add_argument("--settlement-mode", default="enforce")
        s.add_argument("--window-seconds", type=int, default=30 * 24 * 3600)
    e = sub.add_parser("event")
    e.add_argument("name")
    e.add_argument("event_type")
    e.add_argument("--provider-id")
    args = p.parse_args()
    {"create": create, "manifest": manifest, "event": event}[args.cmd](args)


if __name__ == "__main__":
    main()
