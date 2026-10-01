#!/usr/bin/env python3
"""#1816 e2e (GAP D4): a LAB-signed copy of a catalog release whose blocked
row carries a given artifact, for the blocked artifact-feed identity case.

Takes the release feeds the coordinator serves now (--feeds DIR holding
autotune-candidates.json, autotune-artifacts.json, rate-card.json,
demand-rank.json and, when present, continuous-batching-policy.json), marks
--model-key's candidate row runtime_status=blocked, adds a verified GGUF
artifact with --blocked-hash to that model in the artifact feed (rebinding
candidate_catalog_sha256 to the new candidate bytes), and re-signs every feed
with the lab Ed25519 key (--key, an openssl PEM; never an operator key) under
--key-id. Writes the feeds + .sig sidecars to --out and prints the lab public
key (base64, raw 32 bytes) for autotune.public_keys.

The Pearl updater only installs releases signed by the trusted keyring, so a
lab release is installed by pointing the coordinator's autotune paths at
--out and SIGHUP (vm/s4-refusals.sh), as
test/integration/trusted_pool_model_blocked_artifact_test.go does.

Usage: make-lab-blocked-release.py --feeds DIR --key PEM --key-id ID
                                   --blocked-hash HEX64 --out DIR
                                   [--model-key google-gemma-4-26b-a4b-it]
"""
import argparse, base64, hashlib, json, pathlib, re, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--feeds", required=True)
ap.add_argument("--key", required=True)
ap.add_argument("--key-id", required=True)
ap.add_argument("--blocked-hash", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--model-key", default="google-gemma-4-26b-a4b-it")
a = ap.parse_args()
if not re.fullmatch(r"[0-9a-f]{64}", a.blocked_hash):
    sys.exit("--blocked-hash must be 64 lowercase hex")
feeds, out = pathlib.Path(a.feeds), pathlib.Path(a.out)
out.mkdir(parents=True, exist_ok=True)


def dump(obj):
    return (json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def sign(name, raw):
    (out / name).write_bytes(raw)
    sig = subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", a.key, "-in", str(out / name)],
                         check=True, capture_output=True).stdout
    (out / (name + ".sig")).write_text(json.dumps({"key_id": a.key_id, "alg": "ed25519", "signature": base64.b64encode(sig).decode()}))


cat = json.loads((feeds / "autotune-candidates.json").read_text())
if a.model_key not in cat["rows"]:
    sys.exit("no candidate row %r" % a.model_key)
cat["rows"][a.model_key]["runtime_status"] = "blocked"
cat_raw = dump(cat)
art = json.loads((feeds / "autotune-artifacts.json").read_text())
art["candidate_catalog_sha256"] = hashlib.sha256(cat_raw).hexdigest()
model = art["models"].get(a.model_key)
if model is None:
    sys.exit("no artifact-feed model %r" % a.model_key)
model["artifacts"]["gguf-lab-blocked"] = {
    "allowed_runtime_sources": ["llamacpp_loopback"], "hash": a.blocked_hash, "hash_algorithm": "macprovider.gguf-file.v1",
    "min_ram_gb": 4, "notes": "Lab-signed blocked identity (#1816 GAP D4).", "quantization": "q4_k_m", "runtime_format": "gguf",
    "size_bytes": 1024, "source_ref": {"kind": "huggingface_revision", "repo_id": "lab/blocked-GGUF", "revision": "ab" * 20,
                                       "file_path": "blocked-Q4_K_M.gguf"},
    "verification_status": "verified", "verified_at": "2026-10-01"}
sign("autotune-candidates.json", cat_raw)
sign("autotune-artifacts.json", dump(art))
for name in ("rate-card.json", "demand-rank.json", "continuous-batching-policy.json"):
    if (feeds / name).exists():
        sign(name, (feeds / name).read_bytes())
pub = subprocess.run(["openssl", "pkey", "-in", a.key, "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout[-32:]
print(base64.b64encode(pub).decode())
