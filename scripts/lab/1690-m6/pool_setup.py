#!/usr/bin/env python3
"""Create, publish, and promote one lab SPEC-042 Trusted Pool.

  pool_setup.py create NAME --encoding 1|2 [--runtime-allowlist csv] [--window-seconds N]
      (idempotent: a create that failed part way resumes from the coordinator's
      state for the pool, with fresh per-attempt operation ids)
  pool_setup.py manifest NAME --encoding 1|2 [--runtime-allowlist csv] [--window-seconds N]
      (appends the next manifest version, starting when the current one ends)
  pool_setup.py event NAME EVENT_TYPE [--provider-id ID]   (member_revoked etc.)
  pool_setup.py entry NAME --proposal BUNDLE.json --license SPDX --paid-serving-attested
                    [--prompt-rate N --cache-hit-rate N --completion-rate N]
                    [--max-context-tokens N]
  pool_setup.py entry NAME --remove POOL_MODEL_ID
  pool_setup.py entry NAME --attest ACCOUNT=RUNTIME[,RUNTIME] | --unattest ACCOUNT
      (#1816: edits LAB/pools/NAME/pool-models.json, the closed
      `sign-manifest --pool-models` input {"model_entries": [...],
      "attested_members": [...]}; the next `manifest` signs it as the
      pool_model_entries/v1 and pool_attested_members/v1 extensions, or omits
      them once both lists are empty, which revokes every entry)

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
# The CLI's closed pool_model_proposal.v1 bundle (`models propose --json`).
PROPOSAL_FIELDS = ("schema", "generated_at", "cli_version", "pool_id", "provider_id", "candidate_id",
                   "served_model_ref", "runtime_source", "display_name", "catalog_model_key", "model_entry",
                   "creator_requirements", "evidence", "offer_status", "warnings")
# SPEC-042-R015 entry fields: the bundle's model_entry and coordinator-cli's
# --pool-models model_entries[] item use the same names (pricing in the
# SPEC-005 three-rate form).
ENTRY_FIELDS = ("pool_model_id", "artifact_hash_algorithm", "artifact_hash", "allowed_runtime_sources", "license",
                "paid_serving_attested", "pricing", "disclosure_class", "max_context_tokens")
PRICING_FIELDS = ("prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok")
# coordinator-cli --pool-models top level and attested_members[] item.
POOL_MODELS_FIELDS = ("model_entries", "attested_members")
ATTESTED_MEMBER_FIELDS = ("provider_account_id", "runtime_classes")
POOL_MODELS_FILE = "pool-models.json"
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
    """Sign the next manifest with coordinator-cli; pool-models.json, when it
    lists entries or attested members, rides in through --pool-models as the
    pool_model_entries/v1 and pool_attested_members/v1 extensions."""
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
    models = load_pool_models(d)
    if models["model_entries"] or models["attested_members"]:
        cmd += ["--pool-models", str(d / POOL_MODELS_FILE)]
    coordinator_cli(*cmd)
    event = json.loads(out.read_text())
    windows[str(event["manifest_version"])] = [not_before, expires_at]
    (d / "windows.json").write_text(json.dumps(windows))
    return event


def entry_from_proposal(bundle, pool_id, creator):
    """Project a CLI pool_model_proposal.v1 bundle plus the creator-owned
    fields onto one R015 entry in coordinator-cli's --pool-models shape. The
    bundle's model_entry leaves license and paid_serving_attested null (and
    pricing/max_context_tokens null when the provider suggested none); the
    creator supplies them here. Only the closed shape and the pool binding are
    checked; the coordinator is the authority for every other R015 rule and
    the pricing bounds."""
    if bundle.get("schema") != PROPOSAL_SCHEMA:
        sys.exit(f"proposal schema must be {PROPOSAL_SCHEMA}")
    extra = sorted(set(bundle) - set(PROPOSAL_FIELDS))
    missing = sorted(set(PROPOSAL_FIELDS) - set(bundle))
    if extra or missing:
        sys.exit(f"proposal is not the closed {PROPOSAL_SCHEMA} shape: missing={missing} extra={extra}")
    if bundle["pool_id"] != pool_id:
        sys.exit(f"proposal is for pool {bundle['pool_id']}, not {pool_id}")
    proposed = bundle["model_entry"]
    if not isinstance(proposed, dict) or sorted(proposed) != sorted(ENTRY_FIELDS):
        sys.exit(f"proposal model_entry must be exactly {list(ENTRY_FIELDS)}")
    m = POOL_MODEL_ID.match(str(proposed["pool_model_id"]))
    if m is None or m.group(1) != pool_id:
        sys.exit(f"proposal pool_model_id must be pool/{pool_id}/<slug>")
    entry = {k: proposed[k] for k in ENTRY_FIELDS}
    if not creator.get("license"):
        sys.exit("--license is required: the creator names the licence it reviewed")
    if not creator.get("paid_serving_attested"):
        sys.exit("--paid-serving-attested is required: the creator attests paid serving")
    entry["license"] = creator["license"]
    entry["paid_serving_attested"] = True
    rates = [creator.get(k) for k in PRICING_FIELDS]
    if any(r is not None for r in rates):
        if any(r is None for r in rates):
            sys.exit("give all three of --prompt-rate, --cache-hit-rate, --completion-rate, or none")
        entry["pricing"] = dict(zip(PRICING_FIELDS, rates))
    pricing = entry["pricing"]
    if not isinstance(pricing, dict) or sorted(pricing) != sorted(PRICING_FIELDS):
        sys.exit(f"pricing must be exactly {list(PRICING_FIELDS)} (the proposal had none; pass the creator rates)")
    if creator.get("max_context_tokens") is not None:
        entry["max_context_tokens"] = creator["max_context_tokens"]
    if not isinstance(entry["max_context_tokens"], int):
        sys.exit("max_context_tokens is required (the proposal had none; pass --max-context-tokens)")
    return entry


def load_pool_models(d):
    """The staged --pool-models input, always both closed lists."""
    path = d / POOL_MODELS_FILE
    doc = json.loads(path.read_text()) if path.exists() else {k: [] for k in POOL_MODELS_FIELDS}
    if sorted(doc) != sorted(POOL_MODELS_FIELDS):
        sys.exit(f"{path} must be exactly {list(POOL_MODELS_FIELDS)}")
    return doc


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
    """Add (from a proposal bundle) or remove one pool model entry, or add or
    remove one R016 attested member, in pool-models.json. Entries stay
    strictly ascending by pool_model_id and members by provider_account_id.
    Nothing is signed or submitted until the next `manifest`."""
    d = pool_dir(args.name)
    if pool_signer(d, args) != "coordinator-cli":
        sys.exit("model entries need a pool created with --signer coordinator-cli")
    pool_id = (d / "pool_id").read_text().strip()
    models = load_pool_models(d)
    entries, members = models["model_entries"], models["attested_members"]
    if getattr(args, "attest", None):
        account, _, classes = args.attest.partition("=")
        runtimes = sorted(c for c in classes.split(",") if c)
        if not account or not runtimes:
            sys.exit("--attest needs ACCOUNT=RUNTIME[,RUNTIME]")
        if any(m["provider_account_id"] == account for m in members):
            sys.exit(f"member {account} already attested; --unattest it first")
        members.append({"provider_account_id": account, "runtime_classes": runtimes})
    elif getattr(args, "unattest", None):
        kept = [m for m in members if m["provider_account_id"] != args.unattest]
        if len(kept) == len(members):
            sys.exit(f"no attested member {args.unattest}")
        members = kept
    elif args.remove:
        kept = [e for e in entries if e["pool_model_id"] != args.remove]
        if len(kept) == len(entries):
            sys.exit(f"no entry {args.remove}")
        entries = kept
    else:
        creator = {
            "license": getattr(args, "license", None),
            "paid_serving_attested": getattr(args, "paid_serving_attested", False),
            "prompt_rate_per_mtok": getattr(args, "prompt_rate", None),
            "prompt_cache_hit_rate_per_mtok": getattr(args, "cache_hit_rate", None),
            "completion_rate_per_mtok": getattr(args, "completion_rate", None),
            "max_context_tokens": getattr(args, "max_context_tokens", None),
        }
        new = entry_from_proposal(json.loads(pathlib.Path(args.proposal).read_text()), pool_id, creator)
        if any(e["pool_model_id"] == new["pool_model_id"] for e in entries):
            sys.exit(f"entry {new['pool_model_id']} already present; --remove it first")
        entries.append(new)
    entries.sort(key=lambda e: e["pool_model_id"])
    members.sort(key=lambda m: m["provider_account_id"])
    (d / POOL_MODELS_FILE).write_text(json.dumps({"model_entries": entries, "attested_members": members}, indent=2) + "\n")
    print(f"{len(entries)} model entr{'y' if len(entries) == 1 else 'ies'} and {len(members)} attested "
          f"member{'' if len(members) == 1 else 's'} staged for the next manifest")


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
    which.add_argument("--proposal", help="a CLI pool_model_proposal.v1 bundle")
    which.add_argument("--remove", help="a pool_model_id to drop")
    which.add_argument("--attest", help="ACCOUNT=RUNTIME[,RUNTIME]: an R016 attested member")
    which.add_argument("--unattest", help="an attested provider_account_id to drop")
    m.add_argument("--license", help="creator: pinned SPDX id or LicenseRef-*")
    m.add_argument("--paid-serving-attested", action="store_true", help="creator: the licence permits paid serving")
    m.add_argument("--prompt-rate", type=int)
    m.add_argument("--cache-hit-rate", type=int)
    m.add_argument("--completion-rate", type=int)
    m.add_argument("--max-context-tokens", type=int)
    e = sub.add_parser("event")
    e.add_argument("name")
    e.add_argument("event_type")
    e.add_argument("--provider-id")
    args = p.parse_args()
    {"create": create, "manifest": manifest, "entry": entry, "event": event}[args.cmd](args)


if __name__ == "__main__":
    main()
