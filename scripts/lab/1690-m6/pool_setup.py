#!/usr/bin/env python3
"""Create, publish, and promote one lab SPEC-042 Trusted Pool.

  pool_setup.py create NAME --encoding 1|2 [--runtime-allowlist csv] [--window-seconds N]
      (idempotent: a create that failed part way resumes from the coordinator's
      state for the pool, with fresh per-attempt operation ids)
  pool_setup.py manifest NAME --encoding 1|2 [--runtime-allowlist csv] [--window-seconds N]
      (appends the next manifest version, starting when the current one ends)
  pool_setup.py event NAME EVENT_TYPE [--provider-id ID]   (member_revoked etc.)
  pool_setup.py entry NAME --proposal BUNDLE.json | --remove POOL_MODEL_ID
      (#1816: edits LAB/pools/NAME/model-entries.json; the next `manifest`
      signs it as the pool_model_entries/v1 extension, or omits the extension
      once the list is empty, which revokes every entry)

create/manifest take --signer labtool|coordinator-cli. labtool (default) is
the #1690 lab signer. coordinator-cli signs with the reviewed
`coordinator-cli trust-pool-admin keygen/sign-root/sign-manifest` (keys under
LAB/pools/NAME/cli-keys) and is required for model entries: this script never
encodes or signs a policy core itself. A pool keeps the signer it was created
with.

Talks only to the lab coordinator admin surface on 127.0.0.1:19102 with the
lab operator key; pool keys and signed events live under LAB/pools/NAME.
"""
import argparse
import hashlib
import re
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
MODELS = os.environ.get("LAB_MLX_ID", "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
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


def coordinator_cli(*args):
    """The reviewed offline signer (`coordinator-cli trust-pool-admin ...`)."""
    cli = str(LAB / "bin" / "coordinator-cli")
    return subprocess.run([cli, "trust-pool-admin", *args], check=True, capture_output=True, text=True).stdout.strip()


CLI_AUTHORITY_KEY_ID = "lab-manifest-authority-1"
CLI_POLICY_KEY_ID = "lab-policy-signer-1"
CLI_ROOT_KEY_ID = "lab-root-issuer-1"
PROPOSAL_SCHEMA = "pool_model_proposal.v1"
# SPEC-042-R015 entry fields, as the CLI's pool_model_proposal.v1 bundle
# carries them (pricing in the SPEC-005 three-rate form).
ENTRY_FIELDS = ("pool_model_id", "artifact_hash_algorithm", "artifact_hash", "allowed_runtime_sources", "license",
                "paid_serving_attested", "pricing", "disclosure_class", "max_context_tokens")
PRICING_FIELDS = ("prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok")
POOL_MODEL_ID = re.compile(r"^pool/([A-Za-z0-9_-]{22})/([a-z0-9][a-z0-9-]{0,62})$")


def pool_signer(d, args):
    """The signer a pool was created with; a later run may not switch it."""
    want = getattr(args, "signer", "labtool")
    f = d / "signer"
    if f.exists():
        have = f.read_text().strip()
        if have != want:
            sys.exit(f"pool {d.name} is signed by {have}; pass --signer {have}")
        return have
    f.write_text(want + "\n")
    return want


def cli_window(d, prev_version, window_seconds):
    """Mirror labtool: genesis starts a minute ago; a successor starts when its
    predecessor ends, so windows never overlap."""
    windows = json.loads((d / "windows.json").read_text()) if (d / "windows.json").exists() else {}
    if prev_version is None:
        start = int(datetime.now(timezone.utc).timestamp()) - 60
    else:
        start = windows[str(prev_version)][1]
    return windows, start, start + window_seconds


def rfc3339(unix):
    return datetime.fromtimestamp(unix, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def cli_manifest(name, args, prev, op):
    """Sign the next manifest with coordinator-cli; model-entries.json, when it
    lists entries, rides in as the pool_model_entries/v1 extension."""
    d = pool_dir(name)
    keys = d / "cli-keys"
    prev_version = json.loads(prev.read_text())["manifest_version"] if prev else None
    windows, not_before, expires_at = cli_window(d, prev_version, args.window_seconds)
    out = d / f"signed-{op}.json"
    cmd = ["sign-manifest", "--identity", str(keys / "pool-identity.json"),
           "--root-issuer-key", str(keys / "root-issuer-key.pem"), "--root-issuer-key-id", CLI_ROOT_KEY_ID,
           "--policy-signer-key", str(keys / "policy-signer-key.pem"), "--operation-id", op,
           "--encoding", str(args.encoding), "--signer-set-version", "1", "--settlement-mode", args.settlement_mode,
           "--models", MODELS, "--min-binary-version", "1.8.33", "--min-attestation-tier", "hardware",
           "--retention-policy-id", "standard", "--min-eligible-members", "1",
           "--not-before", rfc3339(not_before), "--expires-at", rfc3339(expires_at), "--out", str(out)]
    if args.runtime_allowlist:
        cmd += ["--runtime-allowlist", args.runtime_allowlist]
    if prev:
        cmd += ["--prev", str(prev)]
    else:
        cmd += ["--manifest-authority-key", str(keys / "manifest-authority-key.pem")]
    entries = d / "model-entries.json"
    if entries.exists() and json.loads(entries.read_text()):
        cmd += ["--model-entries", str(entries)]
    coordinator_cli(*cmd)
    event = json.loads(out.read_text())
    windows[str(event["manifest_version"])] = [not_before, expires_at]
    (d / "windows.json").write_text(json.dumps(windows))
    return event


def entry_from_proposal(bundle, pool_id):
    """Project a CLI pool_model_proposal.v1 bundle onto one R015 entry. Only
    the closed shape and the pool binding are checked here; the coordinator
    is the authority for every other R015 rule and the pricing bounds."""
    if bundle.get("schema_version") != PROPOSAL_SCHEMA:
        sys.exit(f"proposal schema_version must be {PROPOSAL_SCHEMA}")
    extra = sorted(set(bundle) - set(ENTRY_FIELDS) - {"schema_version"})
    missing = sorted(set(ENTRY_FIELDS) - set(bundle))
    if extra or missing:
        sys.exit(f"proposal is not the closed R015 shape: missing={missing} extra={extra}")
    pricing = bundle["pricing"]
    if not isinstance(pricing, dict) or sorted(pricing) != sorted(PRICING_FIELDS):
        sys.exit(f"proposal pricing must be exactly {list(PRICING_FIELDS)}")
    m = POOL_MODEL_ID.match(str(bundle["pool_model_id"]))
    if m is None or m.group(1) != pool_id:
        sys.exit(f"proposal pool_model_id must be pool/{pool_id}/<slug>")
    return {k: bundle[k] for k in ENTRY_FIELDS}


def manifest_args(name, args, prev, op=None):
    op = op or f"op-{name}-manifest-{len(list(pool_dir(name).glob('manifest-v*.json'))) + 1}"
    out = ["pool-manifest", "--keys", str(pool_dir(name) / "keys.json"), "--op", op,
           "--encoding", str(args.encoding), "--settlement-mode", args.settlement_mode, "--models", MODELS,
           "--window-seconds", str(args.window_seconds)]
    if args.runtime_allowlist:
        out += ["--runtime-allowlist", args.runtime_allowlist]
    if prev:
        out += ["--prev", str(prev)]
    return out


def pool_dir(name):
    return LAB / "pools" / name


def pool_state(pool_id):
    """The coordinator's view of the pool (admin get-pool), or None before
    pool_created."""
    status, doc = admin("GET", f"/admin/trust-pools/pools/{pool_id}", expect=(200, 404))
    return doc.get("pool") if status == 200 else None


def next_attempt(d):
    """A per-run suffix for this pool's operation ids, persisted in the pool
    directory, so a retried create never reuses an operation id the
    coordinator already holds for a different body (409 operation_conflict)."""
    f = d / "attempt"
    n = int(f.read_text().strip()) + 1 if f.exists() else 1
    f.write_text(f"{n}\n")
    return n


def create(args):
    """Idempotent and resumable (#1750 F-3): an existing pool directory is
    reused, the pool keys are kept, and every step is decided from the
    coordinator's own state for the pool, so a create that failed part way
    finishes on the next run. pool_id is written only once the pool is
    active."""
    d = pool_dir(args.name)
    d.mkdir(parents=True, exist_ok=True)
    if (d / "pool_id").exists():
        print(f"pool {args.name} already created: {(d / 'pool_id').read_text().strip()}")
        return
    ensure_creator()
    signer = pool_signer(d, args)
    keys = d / "keys.json"
    if signer == "coordinator-cli":
        if not (d / "cli-keys").exists():
            coordinator_cli("keygen", "--out-dir", str(d / "cli-keys"), "--manifest-authority-key-id",
                            CLI_AUTHORITY_KEY_ID, "--policy-signer-key-id", CLI_POLICY_KEY_ID)
        pool_id = json.loads((d / "cli-keys" / "pool-identity.json").read_text())["pool_id"]
    else:
        if not keys.exists():
            labtool("pool-keygen", "--out", str(keys))
        pool_id = json.loads(keys.read_text())["pool_id"]
    op = f"op-{args.name}-a{next_attempt(d)}"
    print(f"pool {args.name} pool_id={pool_id} ({op})")
    state = pool_state(pool_id)
    if state is None:
        post_event({"operation_id": f"{op}-create", "timestamp_utc": now(), "event_type": "pool_created",
                    "pool_id": pool_id, "creator_account_id": CREATOR, "approval_record_id": APPROVAL})
        state = pool_state(pool_id)
    if not state.get("root_issuer_key_id"):
        _, nonce_doc = admin("POST", "/admin/trust-pools/root-registration-nonces", {
            "operation_id": f"{op}-nonce", "creator_account_id": CREATOR, "approval_record_id": APPROVAL,
            "current_approval_version": APPROVAL_VERSION, "launch_environment": "candidate", "purpose": "root_issuer_registration",
            "expires_at_utc": (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")})
        nonce = nonce_doc["root_registration_nonce"]
        if signer == "coordinator-cli":
            custody = d / "custody.json"
            custody.write_text(json.dumps({"class": "software", "description": "lab-only software custody"}))
            out = d / f"signed-{op}-root.json"
            coordinator_cli("sign-root", "--identity", str(d / "cli-keys" / "pool-identity.json"),
                            "--root-issuer-key", str(d / "cli-keys" / "root-issuer-key.pem"),
                            "--root-issuer-key-id", CLI_ROOT_KEY_ID, "--operation-id", f"{op}-root",
                            "--creator-account-id", CREATOR, "--approval-record-id", APPROVAL,
                            "--approval-version", APPROVAL_VERSION, "--launch-environment", "candidate",
                            "--custody-disclosure", str(custody), "--custody-class", "software",
                            "--display-name", f"Lab pool {args.name}", "--nonce", nonce["nonce"],
                            "--nonce-expiry", nonce["expires_at_utc"], "--out", str(out))
            root = json.loads(out.read_text())
        else:
            root = json.loads(labtool("pool-root", "--keys", str(keys), "--op", f"{op}-root", "--creator", CREATOR,
                                      "--approval", APPROVAL, "--approval-version", APPROVAL_VERSION,
                                      "--nonce", nonce["nonce"], "--nonce-expiry", nonce["expires_at_utc"]))
        (d / "root.json").write_text(json.dumps(root))
        post_event(root)
        state = pool_state(pool_id)
    if not state.get("manifest_version"):
        if signer == "coordinator-cli":
            manifest = cli_manifest(args.name, args, None, f"{op}-manifest")
        else:
            manifest = json.loads(labtool(*manifest_args(args.name, args, None, op=f"{op}-manifest")))
        (d / "manifest-v1.json").write_text(json.dumps(manifest))
        post_event(manifest)
        state = pool_state(pool_id)
    if PROVIDER not in (state.get("members") or []):
        post_event({"operation_id": f"{op}-member", "timestamp_utc": now(), "event_type": "member_admitted",
                    "pool_id": pool_id, "provider_id": PROVIDER})
    if BUYER not in (state.get("buyer_accounts") or []):
        post_event({"operation_id": f"{op}-buyer", "timestamp_utc": now(), "event_type": "buyer_authorized",
                    "pool_id": pool_id, "buyer_account_id": BUYER})
    if pool_state(pool_id).get("lifecycle") != "active":
        status, doc = admin("POST", f"/admin/trust-pools/pools/{pool_id}/promote", {"operation_id": f"{op}-promote", "reason": "lab-1690-m6"})
        print(f"  promote                -> {status}")
    (d / "pool_id").write_text(pool_id + "\n")


def manifest(args):
    d = pool_dir(args.name)
    versions = sorted(d.glob("manifest-v*.json"), key=lambda p: int(p.stem.split("-v")[1]))
    prev = versions[-1]
    if pool_signer(d, args) == "coordinator-cli":
        event = cli_manifest(args.name, args, prev, f"op-{args.name}-manifest-{len(versions) + 1}")
    else:
        event = json.loads(labtool(*manifest_args(args.name, args, prev)))
    (d / f"manifest-v{event['manifest_version']}.json").write_text(json.dumps(event))
    post_event(event)
    print(f"manifest v{event['manifest_version']} digest={event['manifest_core_digest']}")


def entry(args):
    """Add (from a proposal bundle) or remove one pool model entry in
    model-entries.json, kept strictly ascending by pool_model_id. Nothing is
    signed or submitted until the next `manifest`."""
    d = pool_dir(args.name)
    if pool_signer(d, args) != "coordinator-cli":
        sys.exit("model entries need a pool created with --signer coordinator-cli")
    pool_id = (d / "pool_id").read_text().strip()
    path = d / "model-entries.json"
    entries = json.loads(path.read_text()) if path.exists() else []
    if args.remove:
        kept = [e for e in entries if e["pool_model_id"] != args.remove]
        if len(kept) == len(entries):
            sys.exit(f"no entry {args.remove}")
        entries = kept
    else:
        new = entry_from_proposal(json.loads(pathlib.Path(args.proposal).read_text()), pool_id)
        if any(e["pool_model_id"] == new["pool_model_id"] for e in entries):
            sys.exit(f"entry {new['pool_model_id']} already present; --remove it first")
        entries.append(new)
    entries.sort(key=lambda e: e["pool_model_id"])
    path.write_text(json.dumps(entries, indent=2) + "\n")
    print(f"{len(entries)} model entr{'y' if len(entries) == 1 else 'ies'} staged for the next manifest")


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
        s.add_argument("--signer", choices=("labtool", "coordinator-cli"), default="labtool")
    m = sub.add_parser("entry")
    m.add_argument("name")
    m.add_argument("--signer", default="coordinator-cli", help=argparse.SUPPRESS)
    which = m.add_mutually_exclusive_group(required=True)
    which.add_argument("--proposal")
    which.add_argument("--remove")
    e = sub.add_parser("event")
    e.add_argument("name")
    e.add_argument("event_type")
    e.add_argument("--provider-id")
    args = p.parse_args()
    {"create": create, "manifest": manifest, "entry": entry, "event": event}[args.cmd](args)


if __name__ == "__main__":
    main()
