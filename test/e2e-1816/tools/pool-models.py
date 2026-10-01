#!/usr/bin/env python3
"""#1816 e2e (fake-Pearl VM): SPEC-042 Trusted Pools with pool_model_entries/v1,
driven exactly as docs/runbooks/pool-scoped-model-admission.md says: every
core is signed by the reviewed `coordinator-cli trust-pool-admin sign-manifest
--encoding 2 [--pool-models FILE]`; this script never encodes or signs a core
itself. Adapted from scripts/lab/1690-m6/pool_setup.py (same creator approval
shape, window rule and record-only-accepted rule) for the VM coordinator.

State lives under /root/e2e/pools16/NAME: cli-keys/, pool-models.json (the
staged closed --pool-models input), manifest-vN.json (accepted only),
windows.json, pool_id, lock.

  init NAME [--allowlist CSV] [--window S]      keys + pool id (nothing sent)
  create NAME --members ID[,ID] --buyer ACCT     approval, root, genesis (staged entries), members, buyer, promote
  stage NAME --add SLUG ALG HASH RUNTIMES RATES MAXCTX [--license L]
  stage NAME --remove SLUG | --rates SLUG P,CH,C | --attest ACCT=RT | --unattest ACCT
  manifest NAME [--models-file F] [--start-after S] [--window S] [--allowlist CSV]
      sign + submit the next core; prints `accepted vN digest` or
      `refused HTTP CODE`; exit 0 when accepted, 3 when refused, 4 when the
      offline signer refused (stderr names the reason)
  delegate NAME --provider ID --owner-key PEM      ProviderPoolDelegationV1 grant + member_admitted
  event NAME TYPE [--provider-id ID]               member_revoked, ...
  lifecycle NAME STATE | promote NAME | get NAME | window NAME VERSION | latest NAME
  keeper [--lead S]   loop: re-sign each pool's staged entries into the next
                      window when the latest accepted window ends within S s
"""
import argparse, base64, fcntl, hashlib, json, os, pathlib, subprocess, sys, time, urllib.error, urllib.request
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(os.environ.get("E2E_POOLS", "/root/e2e/pools16"))
ADMIN = os.environ.get("E2E_ADMIN", "http://127.0.0.1:8444")
CLI = os.environ.get("E2E_COORDINATOR_CLI", "/root/e2e/bins/new/coordinator-cli-linux-amd64")
CREATOR = os.environ.get("E2E_CREATOR", "acct-e2e-1816-creator")
APPROVAL, APPROVAL_VERSION = "approval-e2e-1816-v1", "approval-version-1"
ROOT_KEY_ID = "e2e-1816-root-1"
MODELS = "e2e-1816-unused-model"   # model allowlist (catalog ids); entries carry the pool models
DEFAULT_WINDOW = int(os.environ.get("E2E_POOL_WINDOW_S", "120"))


def opkey():
    for line in open("/etc/macprovider/coordinator.env"):
        if line.startswith("OPERATOR_KEY="):
            return line.split("=", 1)[1].strip()


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def rfc3339(unix):
    return datetime.fromtimestamp(unix, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def admin(method, path, body=None):
    req = urllib.request.Request(ADMIN + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + opkey(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    try:
        doc = json.loads(raw) if raw.strip() else {}
    except ValueError:
        doc = {"raw": raw[:300].decode("utf-8", "replace")}
    return status, doc


def must(method, path, body=None, ok=(200, 201, 202)):
    status, doc = admin(method, path, body)
    print("  %-5s %-58s -> %s" % (method, path[:58], status), file=sys.stderr)
    if status not in ok:
        sys.exit("%s %s -> %s: %s" % (method, path, status, json.dumps(doc)[:600]))
    return doc


def cli(*args):
    p = subprocess.run([CLI, "trust-pool-admin", *args], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip()[:600])
    return p.stdout.strip()


def d_(name):
    return ROOT / name


def pool_id(name):
    return (d_(name) / "pool_id").read_text().strip()


def h(s):
    return hashlib.sha256(s.encode()).hexdigest()


def load_models(d):
    p = d / "pool-models.json"
    return json.loads(p.read_text()) if p.exists() else {"model_entries": [], "attested_members": []}


def save_models(d, m):
    m["model_entries"].sort(key=lambda e: e["pool_model_id"])
    m["attested_members"].sort(key=lambda a: a["provider_account_id"])
    (d / "pool-models.json").write_text(json.dumps(m, indent=2) + "\n")


def versions(d):
    return sorted((int(p.stem.split("-v")[1]) for p in d.glob("manifest-v*.json")))


def windows(d):
    p = d / "windows.json"
    return json.loads(p.read_text()) if p.exists() else {}


class Lock:
    def __init__(self, d):
        self.f = open(d / "lock", "w")

    def __enter__(self):
        fcntl.flock(self.f, fcntl.LOCK_EX)

    def __exit__(self, *a):
        fcntl.flock(self.f, fcntl.LOCK_UN)


def sign_and_submit(name, models_file=None, start_after=0, window=None, allowlist=None):
    """Sign the next core (genesis when none accepted) and submit it. Returns
    (state, detail): accepted/refused/signer_refused."""
    d = d_(name)
    cfg = json.loads((d / "config.json").read_text())
    window = window or cfg["window"]
    allowlist = cfg["allowlist"] if allowlist is None else allowlist
    vs = versions(d)
    wins = windows(d)
    now = int(time.time())
    if vs:
        prev = d / ("manifest-v%d.json" % vs[-1])
        prev_end = wins[str(vs[-1])][1]
        start = max(prev_end, now - 5 if prev_end < now else prev_end) + start_after
    else:
        prev = None
        start = now - 60 + start_after
    end = start + window
    attempt = int((d / "attempt").read_text()) + 1 if (d / "attempt").exists() else 1
    (d / "attempt").write_text(str(attempt))
    op = "op-%s-%s-m%d" % (name, cfg["run_id"], attempt)
    out = d / ("signed-%s.json" % op)
    keys = d / "cli-keys"
    args = ["sign-manifest", "--identity", str(keys / "pool-identity.json"), "--root-issuer-key", str(keys / "root-issuer-key.pem"),
            "--root-issuer-key-id", ROOT_KEY_ID, "--policy-signer-key", str(keys / "policy-signer-key.pem"), "--operation-id", op,
            "--encoding", "2", "--signer-set-version", "1", "--settlement-mode", "enforce", "--runtime-allowlist", allowlist,
            "--models", MODELS, "--min-binary-version", "1.8.33", "--min-attestation-tier", "self_signed",
            "--retention-policy-id", "standard", "--min-eligible-members", "1",
            "--not-before", rfc3339(start), "--expires-at", rfc3339(end), "--out", str(out)]
    args += ["--prev", str(prev)] if prev else ["--manifest-authority-key", str(keys / "manifest-authority-key.pem")]
    mf = pathlib.Path(models_file) if models_file else d / "pool-models.json"
    m = json.loads(mf.read_text()) if mf.exists() else {"model_entries": [], "attested_members": []}
    if m["model_entries"] or m["attested_members"]:
        args += ["--pool-models", str(mf)]
    try:
        cli(*args)
    except RuntimeError as e:
        return "signer_refused", str(e)
    ev = json.loads(out.read_text())
    status, doc = admin("POST", "/admin/trust-pools/events", ev)
    if status not in (200, 201, 202):
        code = (doc.get("error") or {}).get("code") if isinstance(doc.get("error"), dict) else doc.get("error")
        return "refused", "HTTP %s %s %s" % (status, code, json.dumps(doc)[:300])
    # Every accepted core is recorded (it is the next --prev), even one a
    # refusal test expected to be refused.
    wins[str(ev["manifest_version"])] = [start, end]
    (d / "windows.json").write_text(json.dumps(wins))
    (d / ("manifest-v%d.json" % ev["manifest_version"])).write_text(json.dumps(ev))
    return "accepted", "v%s %s %s %s" % (ev["manifest_version"], ev["manifest_core_digest"], start, end)


def cmd_init(a):
    """Pool keys and local config only (nothing is sent): the pool id is known
    before the genesis manifest, so entries can be staged into it."""
    d = d_(a.name)
    d.mkdir(parents=True, exist_ok=False)
    (d / "config.json").write_text(json.dumps({"allowlist": a.allowlist, "window": a.window, "run_id": os.urandom(4).hex(), "keeper": True}))
    cli("keygen", "--out-dir", str(d / "cli-keys"), "--manifest-authority-key-id", "e2e-1816-authority-1",
        "--policy-signer-key-id", "e2e-1816-policy-1")
    pid = json.loads((d / "cli-keys" / "pool-identity.json").read_text())["pool_id"]
    (d / "pool_id").write_text(pid + "\n")
    print(pid)


def cmd_create(a):
    """Creator approval, pool_created, root, genesis manifest (with the staged
    entries), members, buyer, promote: runbook section 3/4 order."""
    d = d_(a.name)
    cfg = json.loads((d / "config.json").read_text())
    run_id = cfg["run_id"]
    pid = pool_id(a.name)
    ts = datetime.now(timezone.utc)
    f = lambda days: (ts + timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    must("POST", "/admin/trust-pools/creators", {
        "creator_account_id": CREATOR, "approval_record_id": APPROVAL, "current_approval_version": APPROVAL_VERSION,
        "public_display_name": "E2E 1816 Creator", "legal_support_contact": "legal@e2e.invalid",
        "billing_contact": "billing@e2e.invalid", "emergency_notification_endpoint": "https://e2e.invalid/emergency",
        "acknowledged_max_response_time": "15m", "allowed_product_category": "design-partner",
        "data_retention_category": "standard", "support_owner": "e2e-ops", "allowed_launch_environment": "candidate",
        "creator_agreement_id": "agreement-e2e-1816", "creator_agreement_version": "v1",
        "creator_agreement_expires_at_utc": f(30), "creator_agreement_grace_ends_at_utc": f(31),
        "pricing_schedule_id": "pricing-e2e-1816", "pricing_schedule_version": "v1",
        "prohibited_claim_acknowledgment_hash": h("claims"), "buyer_disclosure_commitment_hash": h("disclosure"),
        "approval_criteria_hash": h("criteria"), "approved_by": "e2e-operator",
        "approved_at_utc": (ts - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"), "status": "enabled"})
    nd = must("POST", "/admin/trust-pools/root-registration-nonces", {
        "operation_id": "op-%s-%s-nonce" % (a.name, run_id), "creator_account_id": CREATOR, "approval_record_id": APPROVAL,
        "current_approval_version": APPROVAL_VERSION, "launch_environment": "candidate", "purpose": "root_issuer_registration",
        "expires_at_utc": (ts + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")})
    nonce = nd["root_registration_nonce"]
    must("POST", "/admin/trust-pools/events", {"operation_id": "op-%s-%s-create" % (a.name, run_id), "timestamp_utc": now_iso(),
                                               "event_type": "pool_created", "pool_id": pid, "creator_account_id": CREATOR,
                                               "approval_record_id": APPROVAL})
    (d / "custody.json").write_text(json.dumps({"class": "software", "description": "e2e VM software custody"}))
    root_out = d / "root.json"
    cli("sign-root", "--identity", str(d / "cli-keys" / "pool-identity.json"), "--root-issuer-key", str(d / "cli-keys" / "root-issuer-key.pem"),
        "--root-issuer-key-id", ROOT_KEY_ID, "--operation-id", "op-%s-%s-root" % (a.name, run_id), "--creator-account-id", CREATOR,
        "--approval-record-id", APPROVAL, "--approval-version", APPROVAL_VERSION, "--launch-environment", "candidate",
        "--custody-disclosure", str(d / "custody.json"), "--custody-class", "software", "--display-name", "E2E pool " + a.name,
        "--nonce", nonce["nonce"], "--nonce-expiry", nonce["expires_at_utc"], "--out", str(root_out))
    must("POST", "/admin/trust-pools/events", json.loads(root_out.read_text()))
    with Lock(d):
        state, detail = sign_and_submit(a.name)
    if state != "accepted":
        sys.exit("genesis manifest %s: %s" % (state, detail))
    print("  genesis " + detail, file=sys.stderr)
    for p in [x for x in a.members.split(",") if x]:
        must("POST", "/admin/trust-pools/events", {"operation_id": "op-%s-%s-member-%s" % (a.name, run_id, p), "timestamp_utc": now_iso(),
                                                   "event_type": "member_admitted", "pool_id": pid, "provider_id": p})
    must("POST", "/admin/trust-pools/events", {"operation_id": "op-%s-%s-buyer" % (a.name, run_id), "timestamp_utc": now_iso(),
                                               "event_type": "buyer_authorized", "pool_id": pid, "buyer_account_id": a.buyer})
    must("POST", "/admin/trust-pools/pools/%s/promote" % pid, {"operation_id": "op-%s-%s-promote" % (a.name, run_id), "reason": "e2e-1816"})
    print(pid)


def cmd_stage(a):
    d = d_(a.name)
    pid = pool_id(a.name)
    with Lock(d):
        m = load_models(d)
        if a.add:
            slug, alg, hsh, runtimes, rates, maxctx = a.add
            p, ch, c = (int(x) for x in rates.split(","))
            m["model_entries"].append({"pool_model_id": "pool/%s/%s" % (pid, slug), "artifact_hash_algorithm": alg, "artifact_hash": hsh,
                                       "allowed_runtime_sources": sorted(runtimes.split(",")), "license": a.license,
                                       "paid_serving_attested": True,
                                       "pricing": {"prompt_rate_per_mtok": p, "prompt_cache_hit_rate_per_mtok": ch, "completion_rate_per_mtok": c},
                                       "disclosure_class": "pool_attested_unverified", "max_context_tokens": int(maxctx)})
        elif a.remove:
            m["model_entries"] = [e for e in m["model_entries"] if e["pool_model_id"] != "pool/%s/%s" % (pid, a.remove)]
        elif a.rates:
            slug, rates = a.rates
            p, ch, c = (int(x) for x in rates.split(","))
            for e in m["model_entries"]:
                if e["pool_model_id"] == "pool/%s/%s" % (pid, slug):
                    e["pricing"] = {"prompt_rate_per_mtok": p, "prompt_cache_hit_rate_per_mtok": ch, "completion_rate_per_mtok": c}
        elif a.attest:
            acct, rt = a.attest.split("=", 1)
            m["attested_members"].append({"provider_account_id": acct, "runtime_classes": sorted(rt.split(","))})
        elif a.unattest:
            m["attested_members"] = [x for x in m["attested_members"] if x["provider_account_id"] != a.unattest]
        out = pathlib.Path(a.out) if a.out else d / "pool-models.json"
        if a.out:
            m["model_entries"].sort(key=lambda e: e["pool_model_id"])
            out.write_text(json.dumps(m, indent=2) + "\n")
        else:
            save_models(d, m)
    print("%d entries, %d attested members -> %s" % (len(m["model_entries"]), len(m["attested_members"]), out))


def cmd_manifest(a):
    d = d_(a.name)
    with Lock(d):
        state, detail = sign_and_submit(a.name, a.models_file, a.start_after, a.window, a.allowlist)
    print(state, detail)
    sys.exit({"accepted": 0, "refused": 3, "signer_refused": 4}[state])


def cmd_delegate(a):
    """SPEC-043 ProviderPoolDelegationV1 grant signed by the provider owner key
    (openssl Ed25519), then member_admitted with the delegation id (as
    test/integration/trusted_pool_model_r016_journey_test.go does)."""
    d = d_(a.name)
    pid = pool_id(a.name)
    cfg = json.loads((d / "config.json").read_text())
    version = versions(d)[-1]
    # SPEC-043-R006: a new grant binds to the policy-terms digest, which a
    # window/version/chain-only rotation keeps; coordinator-cli computes it.
    terms = cli("policy-terms-digest", "--manifest", str(d / ("manifest-v%d.json" % version)))
    digest = dict(l.split("=", 1) for l in terms.splitlines() if "=" in l)["manifest_terms_digest"]
    pub = subprocess.run(["openssl", "pkey", "-in", a.owner_key, "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout[-32:]
    issued = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(minutes=1)
    env = "candidate"
    # A member stays bound across rotations that keep the policy terms; a
    # change to any term (entries, prices, attestations, allowlists,
    # settlement mode, predicates, signer set) drops it until its owner
    # revokes the old grant and delegates for the new terms (run once that
    # core is active). A grant for the current terms is already live.
    prior_path = d / ("delegation-%s.json" % a.provider)
    if prior_path.exists():
        prior = json.loads(prior_path.read_text())
        # Pre-terms state files recorded a core-bound grant.
        prior_field = prior.get("binding", "manifest_core_digest")
        prior_digest = prior.get("digest", prior.get("manifest_core_digest"))
        if prior_field == "manifest_terms_digest" and prior_digest == digest:
            print("delegation %s for member %s already binds the current policy terms (v%d)" % (prior["delegation_id"], a.provider, version))
            return
        rfields = {"schema_version": "provider-pool-delegation-revocation-v1", "creator_account_id": CREATOR, "pool_id": pid,
                   "provider_identity": a.provider, "delegation_id": prior["delegation_id"],
                   "operation_id": "e2e-deleg-revoke-op-%s-%s" % (cfg["run_id"], prior["delegation_id"]),
                   prior_field: prior_digest, "environment_network_id": env,
                   "coordinator_audience": "macprovider/spec043/coordinator-audience/v1/" + env, "provider_owner_key_id": "e2e-owner-key-1",
                   "provider_owner_key_version": "1", "revoked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "revocation_semantics": "owner_revocable"}
        rmsg = d / "delegation-revocation.msg"
        rmsg.write_bytes(b"macprovider/spec043/provider-pool-delegation-revocation-sig/v1" +
                         json.dumps(rfields, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())
        rsig = subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", a.owner_key, "-in", str(rmsg)], check=True, capture_output=True).stdout
        must("POST", "/admin/trust-pools/events", {
            "operation_id": "e2e-deleg-revoke-%s-%s" % (cfg["run_id"], prior["delegation_id"]), "timestamp_utc": now_iso(),
            "event_type": "delegation_revoked", "pool_id": pid, "creator_account_id": CREATOR, "provider_id": a.provider,
            "delegation_id": prior["delegation_id"], "delegation_operation_id": rfields["operation_id"],
            prior_field: prior_digest, "environment_network_id": env,
            "coordinator_audience": rfields["coordinator_audience"], "provider_owner_key_id": rfields["provider_owner_key_id"],
            "provider_owner_key_version": rfields["provider_owner_key_version"], "delegation_revoked_at": rfields["revoked_at"],
            "provider_pool_delegation_revocation_signature": base64.b64encode(rsig).decode()})
    fields = {"schema_version": "provider-pool-delegation-v1", "creator_account_id": CREATOR, "pool_id": pid, "provider_identity": a.provider,
              "delegation_id": "e2e-deleg-%s-%s-v%d" % (cfg["run_id"], a.provider, version),
              "operation_id": "e2e-deleg-op-%s-%s-v%d" % (cfg["run_id"], a.provider, version),
              "manifest_terms_digest": digest, "environment_network_id": env,
              "coordinator_audience": "macprovider/spec043/coordinator-audience/v1/" + env, "provider_owner_key_id": "e2e-owner-key-1",
              "provider_owner_key_version": "1", "provider_owner_public_key": base64.b64encode(pub).decode(),
              "issued_at": issued.strftime("%Y-%m-%dT%H:%M:%SZ"), "expires_at": (issued + timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "revocation_semantics": "owner_revocable"}
    canonical = json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    msg = d / "delegation.msg"
    msg.write_bytes(b"macprovider/spec043/provider-pool-delegation-sig/v1" + canonical)
    sig = subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", a.owner_key, "-in", str(msg)], check=True, capture_output=True).stdout
    must("POST", "/admin/trust-pools/events", {
        "operation_id": "e2e-deleg-grant-%s-%s-v%d" % (cfg["run_id"], a.provider, version), "timestamp_utc": now_iso(), "event_type": "delegation_granted",
        "pool_id": pid, "creator_account_id": CREATOR, "provider_id": a.provider, "delegation_id": fields["delegation_id"],
        "delegation_operation_id": fields["operation_id"], "manifest_terms_digest": digest, "environment_network_id": env,
        "coordinator_audience": fields["coordinator_audience"], "provider_owner_key_id": fields["provider_owner_key_id"],
        "provider_owner_key_version": fields["provider_owner_key_version"], "provider_owner_public_key": fields["provider_owner_public_key"],
        "delegation_issued_at": fields["issued_at"], "delegation_expires_at": fields["expires_at"],
        "provider_pool_delegation_signature": base64.b64encode(sig).decode()})
    must("POST", "/admin/trust-pools/events", {"operation_id": "e2e-deleg-admit-%s-%s-v%d" % (cfg["run_id"], a.provider, version), "timestamp_utc": now_iso(),
                                               "event_type": "member_admitted", "pool_id": pid, "provider_id": a.provider,
                                               "delegation_id": fields["delegation_id"]})
    prior_path.write_text(json.dumps({"delegation_id": fields["delegation_id"], "binding": "manifest_terms_digest", "digest": digest}))
    print("delegated member %s admitted under v%d" % (a.provider, version))


def cmd_event(a):
    cfg = json.loads((d_(a.name) / "config.json").read_text())
    body = {"operation_id": "op-%s-%s-%s-%d" % (a.name, cfg["run_id"], a.event_type, time.time_ns()), "timestamp_utc": now_iso(),
            "event_type": a.event_type, "pool_id": pool_id(a.name)}
    if a.provider_id:
        body["provider_id"] = a.provider_id
    status, doc = admin("POST", "/admin/trust-pools/events", body)
    print(status, json.dumps(doc)[:300])
    sys.exit(0 if status in (200, 201, 202) else 3)


def cmd_lifecycle(a):
    cfg = json.loads((d_(a.name) / "config.json").read_text())
    status, doc = admin("POST", "/admin/trust-pools/pools/%s/lifecycle" % pool_id(a.name),
                        {"operation_id": "op-%s-%s-lc-%s-%d" % (a.name, cfg["run_id"], a.state, time.time_ns()), "lifecycle": a.state, "reason": "e2e-1816"})
    print(status, json.dumps(doc)[:300])
    sys.exit(0 if status in (200, 201, 202) else 3)


def cmd_promote(a):
    cfg = json.loads((d_(a.name) / "config.json").read_text())
    status, doc = admin("POST", "/admin/trust-pools/pools/%s/promote" % pool_id(a.name),
                        {"operation_id": "op-%s-%s-promote-%d" % (a.name, cfg["run_id"], time.time_ns()), "reason": "e2e-1816"})
    print(status, json.dumps(doc)[:300])
    sys.exit(0 if status in (200, 201, 202) else 3)


def cmd_get(a):
    status, doc = admin("GET", "/admin/trust-pools/pools/%s" % pool_id(a.name))
    print(json.dumps(doc, indent=1, sort_keys=True))


def cmd_window(a):
    w = windows(d_(a.name)).get(str(a.version))
    if not w:
        sys.exit(1)
    print("%d %d" % (w[0], w[1]))


def cmd_latest(a):
    vs = versions(d_(a.name))
    print(vs[-1] if vs else 0)


def cmd_keeper(a):
    while True:
        for d in sorted(ROOT.glob("*/config.json")):
            name = d.parent.name
            cfg = json.loads(d.read_text())
            if not cfg.get("keeper", True) or (d.parent / "keeper.off").exists():
                continue
            with Lock(d.parent):
                vs, wins = versions(d.parent), windows(d.parent)
                if not vs:
                    continue
                end = wins[str(vs[-1])][1]
                if end - time.time() > a.lead:
                    continue
                state, detail = sign_and_submit(name)
            print("%s keeper %s %s %s" % (time.strftime("%H:%M:%S"), name, state, detail), flush=True)
        time.sleep(5)


p = argparse.ArgumentParser()
sub = p.add_subparsers(dest="cmd", required=True)
s = sub.add_parser("init"); s.add_argument("name"); s.add_argument("--allowlist", default=""); s.add_argument("--window", type=int, default=DEFAULT_WINDOW)
s = sub.add_parser("create"); s.add_argument("name"); s.add_argument("--members", default=""); s.add_argument("--buyer", required=True)
s = sub.add_parser("stage"); s.add_argument("name"); s.add_argument("--out")
g = s.add_mutually_exclusive_group(required=True)
g.add_argument("--add", nargs=6, metavar=("SLUG", "ALG", "HASH", "RUNTIMES", "RATES", "MAXCTX"))
g.add_argument("--remove"); g.add_argument("--rates", nargs=2); g.add_argument("--attest"); g.add_argument("--unattest")
s.add_argument("--license", default="Apache-2.0")
s = sub.add_parser("manifest"); s.add_argument("name"); s.add_argument("--models-file"); s.add_argument("--start-after", type=int, default=0)
s.add_argument("--window", type=int); s.add_argument("--allowlist")
s = sub.add_parser("delegate"); s.add_argument("name"); s.add_argument("--provider", required=True); s.add_argument("--owner-key", required=True)
s = sub.add_parser("event"); s.add_argument("name"); s.add_argument("event_type"); s.add_argument("--provider-id")
s = sub.add_parser("lifecycle"); s.add_argument("name"); s.add_argument("state")
for c in ("promote", "get", "latest"):
    s = sub.add_parser(c); s.add_argument("name")
s = sub.add_parser("window"); s.add_argument("name"); s.add_argument("version", type=int)
s = sub.add_parser("keeper"); s.add_argument("--lead", type=int, default=50)
a = p.parse_args()
globals()["cmd_" + a.cmd](a)
