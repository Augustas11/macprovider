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
| `phase3-binary/catalog/autotune/intake-decision.json` | no | §16.8 manifest; its digest becomes the ledger row's `intake_decision_sha256`. REQUIRED whenever the release adds a `listed` row or promotes a row to `recommendable`: absence then fails the release closed rather than silently recording `null`. |
| previous signed release DIRECTORY | — | `--previous-release-dir`, a REQUIRED input once an EARLIER release has been recorded with the artifact-bound feed set. Its `release.json`, feed digests, and detached signatures are verified against the trusted keyring, and its published artifact bindings must equal that release's ledger row exactly. |

`autotune-artifacts.json` and its `.sig` are the published outputs. Slice 2a
**generates, signs, binds, and records** them. Slice 2b **serves** them: the
coordinator buyer mux answers `/v1/catalog-artifacts` and
`/v1/catalog-artifacts.sig` once `autotune.catalog_artifacts_path` /
`autotune.catalog_artifacts_sig_path` are configured, nginx allows both routes
through exactly as the rate-card routes, and the live release gate verifies
that the served feed set equals the release's (see "Serving the feed" and
"What later slices must land before activation").

## Serving the feed (slice 2b)

The coordinator loads the artifact pair with the three base feeds at boot and
on SIGHUP reload (`buyer.LoadAutotuneFeeds`) and refuses to serve bytes it
cannot bind to the candidate catalog it serves beside them: signer `key_id`
equality with `autotune-candidates.json.sig` (§3.7.2 — a valid signature by a
second concurrently trusted key fails), `version` / `generated_at` /
`policy_version` equality, `candidate_catalog_sha256` equal to the served
candidate bytes (§3.7.4), the closed §3.7.4 identity matrix, and §3.7.5
primary-artifact consistency. Any mismatch fails startup, and on reload keeps
the prior served set. `/v1/autotune-release` reports a `catalog_artifacts`
entry only for an artifact-bound release, so a four-feed release keeps the
exact status shape v0.1 clients read.

**Configuring the pair is an activation-deploy step, not a default.** The
checked-in `phase4-coordinator/dist/coordinator.yaml` deliberately does not
name the two paths: a configured path whose file is absent fails startup
closed, and every release before activation is a four-feed release without the
file. Add the two keys (see the commented example in `coordinator.yaml.example`)
in the same deploy that installs the first artifact-bound release directory;
until then both routes answer 404 and `catalog-release.py status` lists the
step. Removing the two keys and reloading is the disablement path
(`docs/runbooks/byom-disablement-rollback.md`, row 11).

`scripts/verify-live-coordinator-release-gate.py` reads whether the release
binds `autotune-artifacts.json` (+ `.sig`) from `pearl-release.json`
`catalog.files`. Bound: the live feed must match the bound digest, verify under
the release keyring, be signed by the SAME `key_id` as the served candidate
catalog, and carry the served candidate bytes' digest and release stamp.
Unbound: `/v1/catalog-artifacts` and `.sig` must NOT be served. The gate's
summary line ends with `artifact_feed=bound|absent`.

## CLI consumption (slice 2c)

The provider CLI fetches `/v1/catalog-artifacts` and its sidecar through the
same §3.5 procedure as the other feeds (`AutotuneStaticInputs.loadArtifactFeed`,
`phase3-binary/Sources/macprovider-cli/AutotuneArtifactFeed.swift`), then
BINDS the feed to the candidate catalog selected for the same release: signer
`key_id` equality with the candidate feed (a valid signature by a second
concurrently trusted key fails), `version` / `generated_at` / `policy_version`
equality, `candidate_catalog_sha256` equal to the selected candidate bytes,
and §3.7.5 primary-artifact consistency. Its four warning classes
(`catalog_artifact_feed_fallback_used` / `_integrity_failure` /
`_update_required` / `_stale`) fail closed for artifact-derived capabilities
only — the loader yields no usable feed under any of the last three — and are
never paid-trust or network-submission blockers (§3.7.6 rule 6). The
compiled-in fallback is `bakedArtifactFeedBase64` (base64 of the exact signed
bytes) together with `bakedArtifactFeedSignerKeyID`, the release-manifest-bound
signer read from the artifact sidecar at `generate`; on the compiled-in path the
CLI enforces the three-way identity candidate signer == artifact signer ==
manifest-bound signer, and on the live path the two authenticated signers it
holds (SPEC-023 §3.7.2 as amended in v0.10.2: the `release.json` leg is
enforced at generation and by the consumers that hold the manifest — `verify`,
the acceptance signer, the live release gate; the coordinator loader enforces
cross-feed signer equality). For a
rate-card-bound release both are `nil` and the CLI behaves exactly as v0.1. A bare `generate` bakes the signer from the sidecar on disk at that moment; the shippable bake is the re-run inside `scripts/resign-autotune-static.sh` after signing, and `verify` fails drift on anything else.
Freshness (§3.7.6 rules 3–4) is applied to whichever artifact bytes were
selected, the compiled-in fallback included, so an offline binary gets no
usable feed once its baked feed is 14 days old. The transcripts that make the
live selection are `autotune --recommend`, `--recommend-prefetch`, `--consume`,
and `models catalog-economics`: each loads the artifact feed for the selected
candidate release beside the three v0.1 feeds (`loadRecommendationInputs`);
the first three carry its warnings in the same warning sets, and
`catalog-economics` — whose SPEC-044 projection codes are a closed v0.1 enum —
reports them on stderr. Callers that consume only the three v0.1 feeds
(recommendation freshness, the `serve` preflight, `models
adopt-recommendation`) skip the artifact fetch. A compiled-in snapshot the CLI cannot decode is
`catalog_artifact_feed_integrity_failure` with no usable feed, never a crash.
BYOM identity is resolved against the compiled-in release in every command
(`discover`, `evaluate`, `offer`, `catalog-economics`) through the one offline
qualified selection — the same bound-and-fresh verdict the loader would reach
for those bytes without transport — so all commands agree on one authority
(SPEC-046: discovery is offline and never creates catalog authority). The
matcher has two legs under that one authority. A catalog key the usable
artifact feed covers is decided by the ARTIFACT leg alone: an MLX cache entry
matches a `huggingface_revision` artifact only when one of its snapshot
directories IS the artifact's `revision` (the immutable half of the source
reference as the adapter observed it — a directory name, not a locally
computed hash; the coordinator resolves by verified hash, SPEC-047 §R001);
a GGUF `library_tag` never matches until the adapter reports the layer digest
(slice 3). A repo id, row key, or tag alone is a mutable name and mints no
identity for a covered key. A key the feed does not cover — every key when no
usable feed exists, which includes any binary more than 14 days past its
baked feed's stamp between release cuts — keeps the v0.1 name-level row
match with `catalog_match_unverified` (§3.7.6 rule 6). Only a `verified`
artifact whose `allowed_runtime_sources` include the reporting adapter, of a
`listed` or `recommendable` row (§3.2: `candidate` and `blocked` rows are
never BYOM-matchable), and only when exactly one model key answers. The closed
schema, identity matrix, uniqueness, and
binding rules are pinned across the generator, the coordinator, and the CLI by
the shared corpus `scripts/tests/fixtures/artifact_feed_conformance.json`.

## GGUF settlement identity (slice 3, SPEC-010 v1.7 R007)

A model key's identity is the SET of `verified` artifacts the release-bound
feed publishes for it (SPEC-010-R007). On the coordinator the expected-identity
set is derived at startup from the same loaded feeds as the admitted catalog
(`buyer.BuildArtifactIdentityIndex` → `artifactidentity.Index`, nil for a
rate-card-bound release), so it is release-bound by construction: it resolves
nothing for a provider admitted against another candidate-catalog digest. The
heartbeat/hello verifier keeps the v1.6 primary-row path unchanged; a pair
that is not the row's own is verified only by EXACT member equality for the
session's admitted key, and the session then carries the member and the feed
provenance. A verified member settles: the BYOM admission predicate, the
route snapshot, and settlement carry the SPEC-047-R003 six values
(`artifact_feed_sha256`, `artifact_id`, `artifact_hash`,
`artifact_hash_algorithm`, `artifact_feed_signer_key_id`,
`artifact_candidate_catalog_sha256`) — all six or none, bound into the
snapshot digest, recovered on the settlement recompute path, never looked up
in a current feed. `macprovider.gguf-file.v1` is a canonical wire pair.

On the CLI (R007(a)) the GGUF digest is computed over the COMPLETE bytes of
the blob the local Ollama store serves — `$OLLAMA_MODELS` or
`~/.ollama/models`, manifest → model layer → `blobs/sha256-<hex>`; the
manifest's layer digest only LOCATES the blob and is never reported.
`models evaluate` and `models offer` are the deliberate commands that hash.
The blob is opened once and the identity (path, size, inode, mtime at
filesystem precision) is taken from that open descriptor before and after
hashing, then the name is re-resolved and must still name that same file, so
a rewrite or a substituted path fails closed. The evaluation-time hash has
an explicit budget (`BYOMEvaluationLimits.artifactHashSeconds`, 60 s; SPEC-046-R005): on expiry
nothing is recorded and the candidate simply stays without artifact
identity. The offer always recomputes (under its own explicit budget,
`BYOMModelAdmissionRuntime.artifactHashBudgetSeconds`, 600 s; expiry fails the
offer closed with `artifactHashingTimedOut`) and re-validates the binding right
before the signed package leaves the machine. The digest is recorded for
that exact file identity in `~/.config/macprovider/byom/artifact-digests.json`
(0600), so `models discover` (read-only) reports
`identity_state: artifact_hash_available` and matches a `verified` GGUF
artifact by the COMPUTED digest without hashing. The offer package carries
it as `artifact_hashes["macprovider.gguf-file.v1"]`.

On the coordinator, `artifact_hashes` keys are the SPEC-010-R002 algorithm
names (a closed set; the names carry dots), a member is tied to the candidate
row whose `model_id` the session serves (hello's `model_catalog_model_id`; the
row KEY is a different namespace and an asserted key must agree with the
resolved one), only a validated catalog envelope (`current` / `previous`
admission) can bind a release, a compatible-previous release has no loaded
artifact feed and so stays primary-only, a `listed` row's member never settles,
and the identity a session FIRST verifies (the primary pair or one member) is
pinned for the session (`pool.Provider.IdentityPin`) — a later heartbeat or
refresh verifying a different identity is a mismatch, the pin survives
mismatches and hash-less reports, and only a model change resets it. A stale feed logs
`artifact_identity_index_stale` once per refresh. `scripts/verify-tier2-live.sh`
accepts both canonical algorithms in its ready-cohort check.

What this slice does NOT do: the provider CLI has no GGUF serving runtime, and
SPEC-046 does not proxy buyer traffic, so a served GGUF model cannot yet
report the wire pair in hello/heartbeat. R007 defines the identity that
runtime path will report; the path itself is a later runtime slice.

## Activation state

The artifact feed is **never** activated implicitly. Committing
`autotune-artifacts-source.json` changes nothing: `generate`,
`scripts/resign-autotune-static.sh`, and the scheduled freshness renewal keep
producing the rate-card-bound four-feed release they produce today, and the
source is schema-validated only (unmeasured `size_bytes` is legal in an
unactivated source). The state is read from the release ledger and one explicit
flag:

| State | Condition | Generator behaviour |
|---|---|---|
| pre-activation | no earlier artifact-bound ledger row, no published feed, no flag | four-feed release; source **structurally** validated only |
| activation | `--activate-artifact-feed` on a NEW `release_id`, or the idempotent re-run of that same release | builds, binds, and records the feed; no previous release required |
| post-activation | an EARLIER ledger row is artifact-bound | feed is mandatory; `--previous-release-dir` is required |

**Pre-activation validation is structural only, deliberately.** Schema closure,
the identity-tuple matrix, `artifact_id` grammar, GGUF digest equality, and global
`(hash_algorithm, hash)` uniqueness are properties of the source document alone
and always run. Consistency with the CANDIDATE CATALOG — every `listed` /
`recommendable` row having a `verified`, identity-identical primary artifact, and
every `recommendable` row declaring a `rate_class` — runs at activation and at
every artifact-bound cut, NOT on the four-feed train. So an ordinary candidate
change (adding a row, updating a `model_sha256`, `model_revision`, or
`min_ram_gb`) does not block a pre-activation four-feed release against a source
that has not caught up yet; nothing is serving that source. `status` reports the
drift as an unmet prerequisite, and `--activate-artifact-feed` refuses on it.

Regenerating the SAME `release_id` — what `resign-autotune-static.sh` does
before and after replacing the sidecars — excludes that release's own ledger row
from the rebinding history, so the sign/re-generate/verify sequence is
idempotent and needs no previous-release input.

Print the current state and everything still blocking activation:

```bash
python3 scripts/catalog-release.py status
```

`--activate-artifact-feed` refuses while any generator-side prerequisite it
lists is unmet.

### Distribution surfaces (all landed)

Every surface Stage A needs has landed; this table is the single map of
where each one lives and what it enforces. `status` reports the generator-side
prerequisites and the activation-deploy step that still gate the first
artifact-bound cut, and would list any future surface here as pending:

| Surface | File | Change | Status |
|---|---|---|---|
| CLI release payload | `phase3-binary/dist/package.sh`, `scripts/acceptance-candidate-metadata.py`, `scripts/compatibility-set-manifest.py` | NOT a payload member at Stage A: the deployed updater and installer enforce the exact nine-name `catalog-release/` set, so the feed never rides in the provider tarball and the payload validators reject it there; the CLI's fallback is the snapshot compiled into the binary (§3.7.2), baked by `catalog-release.py generate` as `bakedArtifactFeedBase64` + `bakedArtifactFeedSignerKeyID` (nil for a rate-card-bound release) | **resolved (slice 2b-ii); baked (slice 2c)** |
| GitHub release assets | `.github/workflows/release.yml`, `.github/workflows/acceptance-candidate.yml`, `scripts/sign-acceptance-candidate.sh`, `scripts/acceptance-candidate-metadata.py`, `scripts/verify-acceptance-promotion.py`, `scripts/verify-pearl-runtime-release.sh` | when `release.json` binds the feed, both files are carried as unsigned inputs into the acceptance signer, published as release assets, listed in `checksums.txt` / `release-assets.txt` / provenance, bound in `pearl-release.json` `catalog.files`, required by the promotion inventory, and downloaded + verified by the Pearl runtime release check; never `compatibility-artifact-index` roles (the deployed updater enforces the exact seventeen) | **landed (slice 2b-ii)** |
| live release gate | `scripts/verify-live-coordinator-release-gate.py` | served feed set must equal the release's; bound feed signer-equal and release-bound | **landed (slice 2b)** |
| coordinator serving | `phase4-coordinator/internal/buyer`, `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf` | `/v1/catalog-artifacts` (+ `.sig`) on the buyer mux, release-bound at load; exact nginx allow-through blocks before `location /v1/ { return 404; }` | **landed (slice 2b)** |
| scheduled renewal | `scripts/renew-autotune-static-feed.sh` | once `status` reports `post-activation`, the renewal fetches the live coordinator's `current` release directory from Pearl as the previous signed release (or uses `AUTOTUNE_PREVIOUS_RELEASE_DIR` when set) and `generate` authenticates it; the monthly freshness cron therefore cannot fail closed at generate after activation | **landed (slice 2b-ii)** |
| coordinator deploy | `phase4-coordinator/dist/deploy-pearl-vps.sh` | when `release.json` binds the feed, the pair is uploaded, content-addressed into the immutable release envelope, and staged beside the other feeds (a bound release whose checkout lacks the pair aborts before upload; `verify-directory` on Pearl re-checks the envelope) | **landed (slice 2b-ii)** |

**Deferred requirements** (recorded by the ledger, not enforced by this slice;
`status` lists the first): the §16.8 intake-decision manifest schema and
tier-change completeness (AC-CAT-21) are owned by the listed-tier intake
slice (SPEC-023-R006) — `intake_decision_sha256` records the digest of
whatever `intake-decision.json` holds. Separately, `autotune-artifacts-source.json`
is a named, versioned, never-published release input that SPEC-023 §3.7 does
not yet name the way §3.3.1 rule 3 names `rate-card-source.json`; the next
SPEC-023 revision adds that rule (closed top level `{schema_version, source,
models}`, `size_bytes: null` staging allowance, never served/baked/bound/
ledgered).

`components.catalog.files` stays the exact nine-name set in every one of these
(Stage A, below).

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
release ledger plus the authenticated `--previous-release-dir`, so an auditor
holding those two inputs can reach the same verdict without trusting the
generator. `verify` applies the same rule to the ledger's whole history, so a
hand-assembled release that reuses a `(model_key, artifact_id)` under different
bytes is rejected even though generation never produced it.

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

Post-activation, a class change is authored in `autotune-artifacts-source.json`
before the feed that publishes it exists, so the source and the published feed
legitimately disagree and the plain emitter refuses (`must agree`). Run it with
`--from-source` to project the AUTHORED classes (it prints a NOTICE saying so);
paste the rows, then cut the release that publishes the feed. The rule-8 gate
means the ACTIVATION release itself may not change any row: reprice in a
separate reviewed release before or after it.

Paste the emitted `rewards.rate_card:` rows into
`phase4-coordinator/dist/coordinator.yaml`, keeping the existing provenance
comments. The generator emits rather than rewrites because that file carries
reviewed money-path commentary. The §3.3.1 rule-9 release gate then refuses to
cut a release until both sides agree row-for-row and the release-global
`provider_share_bps / 10000` and `global_multiplier_ppm / 1000000` equal
`rewards.provider_share` and `rewards.global_multiplier`.

Runtime overlays are guarded separately: when the coordinator boots or accepts
a SIGHUP while signed rate-card bytes are or remain served, it compares the
signed rate card against the overlay-effective `rewards.*` and
`stats.rollup.usd_per_million_credits` before Tier-2 staging, billing reload,
settlement config publication, catalog swaps, or feed swaps. A Pearl overlay
(`coordinator.pearl-overlays.yaml`) that would price settlement differently
from the signed public feed now fails boot or SIGHUP closed; disabling a live
signed feed still requires restart because clearing feed paths on SIGHUP retains
the incumbent signed release.

## Cutting the first artifact-bound release

The activation release must be a **new** `release_id`: an already-published
release may not be enriched with an artifact feed. Bump the candidate catalog
`version`/`generated_at` as for any release, then:

```bash
# 1. Author: fill every size_bytes, add artifacts, set rate_class per key.
$EDITOR phase3-binary/catalog/autotune/autotune-artifacts-source.json

# 2. Confirm nothing is still blocking activation.
python3 scripts/catalog-release.py status

# 3. Activate. The flag is REQUIRED for the first artifact-bound release and is
#    refused once one exists; every later release passes --previous-release-dir
#    instead.
python3 scripts/catalog-release.py generate \
  --signer-key-id streamvc-autotune-static-v4 \
  --activate-artifact-feed

# 4. Sign every feed with the SAME static-feed key (signer equality is checked).
#    The signer re-runs `generate` with the same artifact-feed inputs, so pass
#    them through the environment rather than editing the script.
AUTOTUNE_ACTIVATE_ARTIFACT_FEED=1 bash scripts/resign-autotune-static.sh

# 5. Verify the whole release, including the artifact feed's signature.
python3 scripts/catalog-release.py verify
bash scripts/test-catalog-release.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_catalog_artifact_feed
```

Every release AFTER the activation release names the previous signed release
directory instead of the flag:

```bash
python3 scripts/catalog-release.py generate \
  --signer-key-id streamvc-autotune-static-v4 \
  --previous-release-dir /path/to/<previous-release-id>-<candidate-sha16>
AUTOTUNE_PREVIOUS_RELEASE_DIR=/path/to/<previous-release-id>-<candidate-sha16> \
  bash scripts/resign-autotune-static.sh
python3 scripts/catalog-release.py verify \
  --previous-release-dir /path/to/<previous-release-id>-<candidate-sha16>
```

`scripts/renew-autotune-static-feed.sh` reads the same two variables and, once a
release is artifact-bound, stages `autotune-artifacts.json` and its `.sig` into
the release directory it gates with `verify-directory`.

`generate` writes `autotune-artifacts.json` to both
`phase3-binary/catalog/autotune/` and `phase3-binary/dist/static/`, binds it in
`release.json` by `sha256`/`bytes`/`version`/`signer_key_id`, and records the
release in a `macprovider.autotune-release-ledger.v3` row carrying
`artifact_bindings` (one element per published `(model_key, artifact_id)`,
regardless of `verification_status`, ascending by `model_key` then `artifact_id`)
and `intake_decision_sha256`.

**Intake decisions.** `intake_decision_sha256` may be `null` only for a release
that adds no `listed` row and promotes no row to `recommendable`. The generator
compares this release's candidate `runtime_status` per key against the previous
release's — from `--previous-release-dir`, or, for the activation release, from
the ledger's recorded candidate digest, which proves the rows are unchanged when
the catalog was only re-stamped. If a transition is present and
`intake-decision.json` is absent, the release fails closed; if prior state cannot
be established after activation, it fails closed too.

`verify` re-derives that same transition verdict only when it is given the same
authenticated input: run `verify --previous-release-dir <previous signed release
directory>` after every post-activation cut. Without the flag, an artifact-bound
release is verified in every other respect and `verify` prints an explicit
`NOTICE` that the §3.7.8 transition rule was not re-derived — it never passes the
rule silently. `verify-directory` has no ledger and no previous release, so a
hand-assembled staged release is checked for transitions **only** by `verify
--previous-release-dir` in the repository that holds the ledger.

**Carried item for the first activation release cut.** CI runs
`python3 scripts/catalog-release.py verify` with no previous-release snapshot, so
post-activation CI will print the NOTICE rather than enforce the transition rule.
Wiring a previous-release snapshot into that job belongs with the activation
release cut, when the first artifact-bound release directory exists to snapshot;
until then the enforcement point is the operator `generate` run, which fails
closed. See `audits/2026-09-09-byom-v02-slice2a/AUDIT_BYOM_V02_SLICE2A_R3.md`.

Serving is a 2b/2c surface: see "What the 2b/2c slices must land before
activation" above.

## Stage A vs Stage B

**Stage A (now).** The feed is generated, signed, bound in `release.json`, and
recorded in the artifact-bound ledger feed set. It is **not served**: packaging,
publishing, the live gate, and the coordinator routes are 2b/2c surfaces this
slice deliberately ships none of. It **MUST NOT** be added to
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
