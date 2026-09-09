# Catalog artifact-feed release runbook (SPEC-023 §3.7)

**Authority:** `specs/SPEC-023-installer-autotune-recommend.md` §3.3.1, §3.5 (13),
§3.7.1–§3.7.8, §11 AC-CAT-1 … AC-CAT-19.
**Scope:** how an operator adds an artifact to the catalog artifact feed — a GGUF
artifact in particular — and cuts the first artifact-bound release.

The artifact feed gives one catalog model key a **set** of verified artifacts, so
a BYOM candidate served from a GGUF blob can match the same priced model key as
the MLX snapshot. It is a separate signed static feed on purpose: adding an
artifact set to a candidate row would fail-close every deployed provider (§3.7.1,
§12.2).

## Inputs the generator reads

| File | Published? | Purpose |
|---|---|---|
| `phase3-binary/catalog/autotune/autotune-artifacts-source.json` | no | operator-authored artifact set. `schema_version: macprovider.autotune-artifacts-source.v1`, closed top level `{schema_version, source, models}`. Its `models` block is the published feed's `models` block verbatim. |
| `phase3-binary/catalog/autotune/rate-card-source.json` | **never** | §3.3.1 rule 3 rate-card authoring source. Closed top level `{schema_version, generated_at, policy_version, usd_per_million_credits, provider_share_bps, global_multiplier_ppm, rows, classes}`. Never served, never baked, never bound in `release.json`, never in the ledger feed set. |
| `phase3-binary/catalog/autotune/intake-decision.json` | no | optional §16.8 manifest; its digest becomes the ledger row's `intake_decision_sha256`. Absent ⇒ `null`. |
| previous release's signed `autotune-artifacts.json` | — | `--previous-artifact-feed`, a REQUIRED input once any release has been recorded with the artifact-bound feed set. |

`autotune-artifacts.json` and its `.sig` are the published outputs, served at
`/v1/catalog-artifacts` and `/v1/catalog-artifacts.sig`.

## Current state

The source is committed and seeded with all ten catalog rows — each with its
primary MLX artifact copied from the signed candidate row, `verification_status:
"verified"`, and its §3.3.1 `rate_class`. **No release has been cut with it yet.**
Two operator gaps are deliberate and fail closed at generation:

1. **`size_bytes` is `null` on every seeded artifact.** Publishing a fabricated
   byte count into a signed feed is not acceptable, so the generator refuses to
   build a feed while any `size_bytes` is `null`
   (`size_bytes must be measured before the release is generated`). Measure the
   snapshot and fill the integer.
2. **No GGUF artifacts are seeded.** Real GGUF digests require pulling and
   hashing the blob; see below.

`verified_at` on the seeded primaries is `2026-09-02`, the date the candidate
release published those digests as operator-verified identities.

## Adding an artifact

Every artifact entry must match exactly one row of the §3.7.4 closed identity
matrix on all four identity fields; anything else fails the release closed.

| `runtime_format` | `hash_algorithm` | `source_ref.kind` | `allowed_runtime_sources` ⊆ |
|---|---|---|---|
| `mlx_safetensors` | `macprovider.snapshot-manifest.v1` | `huggingface_revision` | `{mlx_cache}` |
| `gguf` | `macprovider.gguf-file.v1` | `ollama_library_tag` | `{ollama_loopback, llamacpp_loopback, lmstudio_loopback, openai_compatible_loopback}` |

A `verified` artifact may never allow `openai_compatible_loopback` — an opaque
endpoint supplies no bytes to hash.

### Adding a GGUF artifact

1. Pull the exact tag and read the layer digest:

   ```bash
   ollama pull qwen3:8b
   ollama show qwen3:8b --modelfile   # or: ollama inspect, for the layer digest
   ```

2. Compute SHA-256 over the GGUF **file bytes**. That value is both `hash` and,
   prefixed, `source_ref.digest`:

   ```bash
   shasum -a 256 /path/to/model.gguf
   ```

3. Add the artifact under the model key, with a NEW `artifact_id` matching
   `^[a-z0-9][a-z0-9-]{0,63}$`:

   ```json
   "gguf-q4-k-m": {
     "runtime_format": "gguf",
     "quantization": "Q4_K_M",
     "source_ref": {
       "kind": "ollama_library_tag",
       "library_tag": "qwen3:8b",
       "digest": "sha256:<64-hex>"
     },
     "hash_algorithm": "macprovider.gguf-file.v1",
     "hash": "<the same 64-hex>",
     "size_bytes": 4900000000,
     "min_ram_gb": 12,
     "allowed_runtime_sources": ["ollama_loopback", "llamacpp_loopback"],
     "verification_status": "verified",
     "verified_at": "YYYY-MM-DD"
   }
   ```

   `source_ref.digest` MUST equal `"sha256:" + hash` exactly — same case, same
   digest. A mismatch binds two identities to one artifact and fails closed.

4. A GGUF artifact is **never** a settlement identity in v0.10.x. It reaches at
   most `catalog_matched`, `sandbox_probe_only`, and `network_visible_unpriced`.
   Only the model key's `primary_artifact_id` (an `mlx_safetensors` entry whose
   `hash` is the candidate row's `model_sha256`) may be priced or settled
   (§3.7.4, §13 Q14).

### Never rebind an `artifact_id`

An `artifact_id` is bound to bytes forever. To change an artifact's bytes:
publish the new bytes under a **new** `artifact_id` and retire the old id by
publishing it with `verification_status: "blocked"`. Removing the pair and
reintroducing it later with different bytes fails exactly the same way — removal
is not an escape hatch. The generator reconstructs prior bindings from the
release ledger plus `--previous-artifact-feed`, so an auditor holding those two
inputs can reach the same verdict without trusting the generator.

## Class rate rows

`rate_class` lives on the artifact feed's model entry, never on a candidate row.
The generator expands `rate-card-source.json` into the published `rate-card.json`
`rows` and checks parity against the coordinator inline fallback rows.

- An explicit source `rows` entry always wins; the class expansion for that key
  is discarded.
- Class expansion fills only keys with no explicit row. A `recommendable` key
  whose class has no rates in `classes` fails the release closed.
- Classes carry **only** the three credit-rate fields. `provider_share_bps` and
  `global_multiplier_ppm` are release-global and are materialised onto every
  published row from the source's top level.
- The first class-expanded release must publish a `rows` map byte-identical to
  the preceding release's. The seeded source does exactly that: every current key
  has an explicit row, so nothing reprices.
- `class-30b-moe`, `class-32b`, and `class-70b` are deliberately unseeded. The
  current rows in those classes price away from each other, and reconciling them
  is a separate reviewed pricing release (§13 Q15).

To change or add a coordinator fallback row:

```bash
python3 scripts/catalog-release.py emit-coordinator-rate-card
```

Paste the emitted `rewards.rate_card:` rows into
`phase4-coordinator/dist/coordinator.yaml`, keeping the existing provenance
comments. The generator emits rather than rewrites because that file carries
reviewed money-path commentary. The §3.3.1 rule-9 parity gate then refuses to cut
a release until both sides agree row-for-row and the release-global
`provider_share_bps / 10000` and `global_multiplier_ppm / 1000000` equal
`rewards.provider_share` and `rewards.global_multiplier`.

## Cutting the first artifact-bound release

The activation release must be a **new** `release_id`: an already-published
release may not be enriched with an artifact feed. Bump the candidate catalog
`version`/`generated_at` as for any release, then:

```bash
# 1. Author: fill every size_bytes, add artifacts, set rate_class per key.
$EDITOR phase3-binary/catalog/autotune/autotune-artifacts-source.json

# 2. Generate. Omit --previous-artifact-feed only for the FIRST artifact-bound
#    release; it is required for every release after that.
python3 scripts/catalog-release.py generate \
  --signer-key-id streamvc-autotune-static-v4

# 3. Sign every feed with the SAME static-feed key (signer equality is checked).
bash scripts/resign-autotune-static.sh

# 4. Verify the whole release, including the artifact feed's signature.
python3 scripts/catalog-release.py verify
bash scripts/test-catalog-release.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_catalog_artifact_feed
```

`generate` writes `autotune-artifacts.json` to both
`phase3-binary/catalog/autotune/` and `phase3-binary/dist/static/`, binds it in
`release.json` by `sha256`/`bytes`/`version`/`signer_key_id`, and records the
release in a `macprovider.autotune-release-ledger.v3` row carrying
`artifact_bindings` (one element per published `(model_key, artifact_id)`,
regardless of `verification_status`, ascending by `model_key` then `artifact_id`)
and `intake_decision_sha256`.

Serving: add exact `location = /v1/catalog-artifacts` and
`location = /v1/catalog-artifacts.sig` allow-through blocks before the generic
`location /v1/ { return 404; }` in
`phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`, proxying to
`http://127.0.0.1:8443` with no `Authorization` requirement, exactly as the
rate-card routes do.

## Stage A vs Stage B

**Stage A (now).** The feed is generated, signed, served, bound in `release.json`,
and recorded in the artifact-bound ledger feed set. It **MUST NOT** be added to
the compatibility-set manifest's `components.catalog.files` map, which stays the
exact nine-name set the deployed updater enforces. Only the producer-side
`release.json` `feeds` check in `scripts/compatibility-set-manifest.py` is widened
to the five-feed set; that script runs on the release host and in acceptance,
never on an installed provider. A Stage-A release therefore validates and installs
on every previously shipped updater.

**Stage B (later revision, gated).** `autotune-artifacts.json` and its `.sig` may
join `components.catalog.files` (an eleven-name set) only when BOTH hold: a bridge
CLI accepting the widened map has shipped as a stable release, AND the
previous-stable release for the self-update path is at or after that bridge
version. Until both hold, Stage B is prohibited.

Stage A is weaker than Stage B **for the compatibility-set manifest only**.
Signature verification, release binding, primary-artifact consistency, and the
§3.7.6 failure classes all apply in full at Stage A.

## Rollback

Deleting `autotune-artifacts-source.json` before a release cut removes the feed
from the next release entirely and restores v0.1 behaviour; it deletes no
provider state. After activation the artifact-bound feed set is mandatory going
forward, so withdraw individual artifacts by publishing them `blocked` rather than
reverting the feed set. See `docs/runbooks/byom-disablement-rollback.md` row 11.
