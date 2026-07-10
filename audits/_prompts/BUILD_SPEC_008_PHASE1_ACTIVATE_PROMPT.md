# BUILD SPEC-008 Phase 1 Activation + Provider model_hash

## Context

You are working on **macprovider-poc** — a P2P Mac inference marketplace. The
coordinator runs at `coordinator.streamvc.live` (Pearl VPS, `159.223.165.194`).
The buyer-facing API gateway runs at `api.streamvc.live` (same VPS). Providers
are Mac machines (M1/M4) running the phase3-binary Swift CLI, each serving one
MLX model via a WebSocket connection to the coordinator.

**SPEC-008 Phase 1 (Pillar A) coordinator code is fully built and deployed.**
The coordinator already:
- loads a signed model catalog from `tier2.catalog_path`
- verifies provider-reported `model_hash` against catalog entries
- tracks `HashStatus` per provider (verified / mismatch / invalid / uncatalogued / catalog_unavailable)
- excludes `hash_mismatch` and `hash_invalid` providers from routing (always)
- optionally excludes `uncatalogued` providers when `require_hash_verified: true`
- exposes hash verification state in `/v1/models` Tier-2 disclosure fields

What is **not yet done** (this session's work):
1. **Catalog activation** — no catalog file exists, coordinator.yaml has no `tier2:` section
2. **Provider model_hash** — phase3-binary never sends `model_hash` in the WebSocket hello

---

## Task 1 — Catalog activation (operator + config)

### 1a. Generate Ed25519 signing keypair

Generate a catalog signing keypair. The coordinator config will hold only the
public key (`tier2.catalog_public_key`). Store the private key securely (the
operator keeps it offline; it is never deployed to the VPS).

Use `openssl` or Go's `crypto/ed25519`. Output:
- `catalog-signing-key.pub` — base64url-unpadded 32-byte Ed25519 public key
- `catalog-signing-key.priv` — private key (keep offline; do not commit)

### 1b. Compute model weight hashes on live providers

Current live models (from `/v1/models`):
- `mlx-community/Qwen2.5-7B-Instruct-4bit`
- `mlx-community/Llama-3.2-3B-Instruct-4bit`

Model weight files are at:
```
~/.cache/huggingface/hub/models--{org}--{model}/snapshots/{revision}/
```
where `{org}--{model}` uses `--` as separator (e.g. `mlx-community--Qwen2.5-7B-Instruct-4bit`).

**Hash scope decision:** Use `artifact_manifest` for the catalog entry — it is
robust to sharding and future weight updates. The manifest is a deterministic
JSON object listing all `.safetensors` shard filenames, byte sizes, and
per-shard SHA-256 hashes in lexicographic filename order. SHA-256 the manifest
itself (canonical UTF-8, no insignificant whitespace, lexicographic keys).

If the model has only one `.safetensors` file, `primary_weight_file` (direct
SHA-256 of that file) is acceptable and simpler.

Write a small Go or shell tool at `scripts/hash-model-weights.sh` (or
`scripts/hash-model-weights.go`) that:
- takes a model snapshot directory as input
- finds all `.safetensors` files, sorts them lexicographically
- computes per-file SHA-256 and total-manifest SHA-256
- prints the catalog-ready JSON entry

The operator runs this tool on each provider Mac (or via SSH) to collect the
hashes. The tool output is the `sha256` field value in the catalog entry.

### 1c. Build and sign the catalog file

Catalog format per SPEC-008 §5.2:

```json
{
  "version": 1,
  "catalog_id": "macprovider-tier2-model-catalog-2026-05-31",
  "issued_at": "2026-05-31T00:00:00Z",
  "expires_at": "2026-08-31T00:00:00Z",
  "models": [
    {
      "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "artifact_kind": "mlx_weight_file",
      "sha256": "<computed above>",
      "hash_scope": "artifact_manifest",
      "source": "operator-curated"
    },
    {
      "model_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "artifact_kind": "mlx_weight_file",
      "sha256": "<computed above>",
      "hash_scope": "artifact_manifest",
      "source": "operator-curated"
    }
  ],
  "signature": {
    "alg": "Ed25519",
    "key_id": "catalog-key-2026q2",
    "sig": "<base64url-unpadded Ed25519 signature over canonical catalog body>"
  }
}
```

Canonical catalog body for signing: the catalog object **without** the
`signature` member, serialized as UTF-8 with lexicographic object keys and no
insignificant whitespace.

Write a signing tool at `scripts/sign-catalog.go` (or shell using openssl) that
takes the unsigned catalog JSON + private key and outputs the signed catalog.

### 1d. Deploy catalog + coordinator config

Update `phase4-coordinator/dist/coordinator.yaml` (only the `tier2:` section —
do not change secrets or other config):

```yaml
tier2:
  catalog_path: /opt/macprovider/tier2-catalog.json
  catalog_public_key: <base64url-unpadded Ed25519 pubkey from 1a>
  require_hash_verified: false
```

Deploy:
1. SCP the signed catalog file to Pearl VPS at `/opt/macprovider/tier2-catalog.json`
2. SCP the updated `coordinator.yaml` (do not overwrite the live secrets —
   merge the `tier2:` section into the live config using SSH)
3. Restart the coordinator for first-time `catalog_path` / `catalog_public_key`
   activation. SPEC-008 marks those fields startup-only, so SIGHUP must be used
   only for later hot-reloadable Tier-2 fields or same-path catalog refreshes.

### 1e. Verify

After restart/reload:
- Coordinator logs should show `tier2 catalog loaded` with model count
- `GET https://api.streamvc.live/v1/models` (with `X-Demo-Token`) should show
  Tier-2 disclosure fields including `tier2.model_hash.state`
- Providers without model_hash will show `uncatalogued` (expected until Task 2)

---

## Task 2 — Provider model_hash in phase3-binary (Swift)

**File to edit:** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
**File to edit:** `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`

### 2a. Compute model hash at load time

In `ModelRuntime`, after the model directory is resolved and the model is
successfully loaded, compute the SHA-256 hash of the model weights.

The hash algorithm must match the catalog's `hash_scope`:

For `artifact_manifest` (recommended):
- enumerate all `.safetensors` files in `modelDirectory()`, sort lexicographically
- compute SHA-256 of each file
- build deterministic manifest JSON: `{"files":[{"name":"...","size":N,"sha256":"..."},...]}` (lexicographic keys, no whitespace, sorted by name)
- compute SHA-256 of the UTF-8 manifest bytes
- result is lowercase hex string (64 chars)

For `primary_weight_file` (single-shard models only):
- find the single `.safetensors` file in `modelDirectory()`
- return `nil` if zero or multiple `.safetensors` files exist (do not guess)

Store the hash as `var loadedModelHash: String?` on `ModelRuntime` (nil if
computation failed or no weight files found — never crash or log a fatal error
for a missing hash, Tier-1 behavior must be preserved).

Compute it lazily or at the end of `loadModel()` — it should not block the
model from being marked ready (compute in background after model is loaded,
or synchronously but only after MLX load completes).

### 2b. Expose hash via ProviderStatus

In `ProviderStatus.snapshot()`, include `modelHash: String?` in the snapshot
(or however the existing snapshot type is shaped). Add the field without
breaking existing callers.

### 2c. Include in hello message

In `CoordinatorClient.helloMessage()`, add:

```swift
if let hash = snapshot.modelHash {
    message["model_hash"] = hash
}
```

The field is omitted entirely when `modelHash` is nil — old coordinator behavior
is preserved (coordinator treats missing field as `uncatalogued`).

### 2d. Tests

Add tests in the phase3-binary test target:
- Unit test for the hash computation function (fixture directory with known files)
- Unit test that `helloMessage()` includes `model_hash` when hash is available
- Unit test that `helloMessage()` omits `model_hash` when hash is nil

### 2e. Build + release

```bash
cd phase3-binary
swift build -c release
# or use the existing build-release script
```

Verify it compiles. The updated binary is ready for distribution to provider
operators.

---

## Acceptance criteria

Phase 1 activation is complete when:

Use `specs/SPEC-008-PHASE1-ACCEPTANCE-RUNBOOK.md` as the executable activation
and verification handoff.

1. `GET https://api.streamvc.live/v1/models` with `X-Demo-Token` returns
   `tier2` disclosure block (not just `tier1_disclosure`) with
   `tier2.model_hash.state` field present.

2. Coordinator logs show catalog loaded and at least one provider showing
   `hash_verified` after updating to the new binary (or `uncatalogued` before
   binary update — that is also correct).

3. A provider running the updated phase3-binary shows `hash_verified` in the
   coordinator pool state (observable via the operator `/poolz` endpoint or
   coordinator logs).

4. `require_hash_verified: false` remains the live setting — **do not flip to
   true in this session**. That is a separate operator decision after verifying
   the pool is predominantly verified.

---

## Key files

```
phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift   # hello message (add model_hash)
phase3-binary/Sources/macprovider-cli/ModelRuntime.swift        # load + hash weights
phase4-coordinator/dist/coordinator.yaml                         # add tier2: section (example only, live config is on VPS)
specs/SPEC-008-tier2.md                                         # normative spec (§5.2 catalog, §5.3 hash algo, §5.4 wire field)
scripts/                                                        # new: hash-model-weights + sign-catalog tools
```

## SSH + deploy notes

- Pearl VPS: `ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194`
- Live coordinator config: `/opt/macprovider/coordinator.yaml` — contains real secrets, never overwrite wholesale
- Merge `tier2:` section only: read live config, add section, write back
- First-time `catalog_path` / `catalog_public_key` activation requires coordinator restart
- Coordinator SIGHUP is valid only for hot-reloadable Tier-2 fields or same-path catalog refreshes:
  `kill -HUP $(systemctl show -p MainPID --value macprovider-coordinator)`
- phase3-binary is distributed to provider operators — the built binary goes to `phase3-binary/dist/` for release

## Git identity

Before any `git push`: `gh auth switch -u Augustas11` (default account is `antfleet-ops` which lacks write access to this repo).
