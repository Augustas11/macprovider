# Build prompt — SPEC-008 Phase 1 (Pillar A) implementation

Implements **SPEC-008 v0.3 Phase 1: model catalog + hash verification** as live
code in the macprovider coordinator and gateway.

Spec is locked at v0.3.  No spec edits in this session.  Code only.

Run in **Claude Code** or **Codex** rooted at `/Users/augstar/macprovider-poc`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===` into a
fresh session.

---

```
=== BEGIN PROMPT ===

You are implementing SPEC-008 v0.3 §§ 4–5, 9.1, 11–13 as working Go code in
the macprovider-poc repository.

Scope: Phase 1 (Pillar A) only — model catalog + hash verification.
Phase 2 (Pillars B + C) and Phase 3 (Pillar D) are explicitly out of scope
for this session.  Do not implement wire-extension fields, AEAD, X25519, or
behavioral safety controls.

The spec document is: specs/SPEC-008-tier2.md (version 0.3, already locked).
Read §§ 4–5, 9.1, 11–13, and 14 (AC-T2-1 through AC-T2-26) in full before
writing any code.

As you work, maintain phase4-coordinator/implementation-notes.html with:
- Design decisions: choices made where the spec was ambiguous.
- Deviations: places where you intentionally departed from the spec, and why.
- Tradeoffs: alternatives considered and why you picked what you did.
- Open questions: anything you would want the operator to confirm or revise.

---

## Repository layout you will touch

```
phase4-coordinator/
  internal/
    config/config.go           -- add Tier2Config struct
    ws/messages.go             -- add optional model_hash field to Hello
    pool/provider.go           -- add HashStatus + hash state to Provider / Registry
    tier2/                     -- NEW package (catalog load, signature verify, hash compare)
    buyer/server.go            -- update handleModels + selectProvider
  implementation-notes.html   -- running notes (always update)

phase5-gateway/
  internal/router/server.go   -- update makeTier1Disclosure; forward new hash fields
```

Do not edit any spec file.

---

## What Phase 1 (Pillar A) requires

### 1. Config — add Tier2Config to coordinator

Edit `phase4-coordinator/internal/config/config.go`.

Add a `Tier2Config` struct and a `Tier2 Tier2Config` field to `Config`.

Tier2Config fields (all must default to Tier-1-preserving values — see
SPEC-008 §11.1):

```go
type Tier2Config struct {
    // Observation gate
    ObserveEnabled bool `yaml:"observe_enabled"` // default false

    // Pillar A
    CatalogPath      string `yaml:"catalog_path"`       // default ""
    CatalogPublicKey string `yaml:"catalog_public_key"` // default ""; base64url Ed25519 public key
    RequireHashVerified bool `yaml:"require_hash_verified"` // default false

    // Pillar B (not implemented in Phase 1 — add keys so config loads cleanly)
    RequireEncryptedLeg            bool   `yaml:"require_encrypted_leg"`              // default false
    EncryptedLegAEAD               string `yaml:"encrypted_leg_aead"`                 // default "A256GCM"
    EncryptedLegRekeyAfterRequests int    `yaml:"encrypted_leg_rekey_after_requests"` // default 10000
    EncryptedLegRekeyAfterSeconds  int    `yaml:"encrypted_leg_rekey_after_seconds"`  // default 3600

    // Pillar C (not implemented in Phase 1 — add keys so config loads cleanly)
    RequireAttestation    bool     `yaml:"require_attestation"`     // default false
    AttestationRoots      []string `yaml:"attestation_roots"`       // default []
    AttestationMaxAgeS    int      `yaml:"attestation_max_age_s"`   // default 600
    AttestationFormats    []string `yaml:"attestation_formats"`     // default ["apple-managed-device-attestation-acme-v1"]

    // Pillar D (not implemented in Phase 1 — add keys so config loads cleanly)
    BehavioralSafetyEnabled      bool    `yaml:"behavioral_safety_enabled"`       // default false
    OutputSizeCapBytes            int     `yaml:"output_size_cap_bytes"`            // default 0
    OutputBytesPerTokenCeiling    int     `yaml:"output_bytes_per_token_ceiling"`   // default 16
    DefaultOutputSizeCapBytes     int     `yaml:"default_output_size_cap_bytes"`    // default 1048576
    EncodingValidationEnabled     bool    `yaml:"encoding_validation_enabled"`      // default false
    ResponseTimeAnomalyEnabled    bool    `yaml:"response_time_anomaly_enabled"`    // default false
    ResponseTimeAnomalyFactor     float64 `yaml:"response_time_anomaly_factor"`     // default 5.0
    ResponseTimeAnomalyMinMS      int     `yaml:"response_time_anomaly_min_ms"`     // default 10000
}
```

Add startup validation per SPEC-008 §11.2:
- Fail if `catalog_path` non-empty and `catalog_public_key` empty.
- Fail if `require_hash_verified: true` and no valid catalog can be loaded at
  startup.
- Fail if `encrypted_leg_aead` is not a recognized suite name when
  `require_encrypted_leg: true` (accept any value when Pillar B is not active;
  this is Phase 1 only).
- Fail if `response_time_anomaly_factor <= 1.0`.
- Do NOT fail if all Tier-2 features are disabled.

### 2. Provider Hello — add optional model_hash field

Edit `phase4-coordinator/internal/ws/messages.go`.

Add to `Hello`:
```go
ModelHash string `json:"model_hash,omitempty"` // SPEC-008 §5.4 SPEC-001 v1.3 candidate
```

Old providers omit this field.  The coordinator MUST admit old providers
under default Tier-1 behavior (SPEC-008 §5.4).

### 3. Pool — hash status

Edit `phase4-coordinator/internal/pool/provider.go`.

Add a `HashStatus` string type and constants:
```go
type HashStatus string

const (
    HashStatusVerified          HashStatus = "hash_verified"
    HashStatusMismatch          HashStatus = "hash_mismatch"
    HashStatusInvalid           HashStatus = "hash_invalid"
    HashStatusUncatalogued      HashStatus = "uncatalogued"
    HashStatusCatalogUnavailable HashStatus = "catalog_unavailable"
)
```

Add to `Provider` struct:
```go
ModelHash   string     `json:"model_hash,omitempty"`
HashStatus  HashStatus `json:"hash_status,omitempty"` // computed by tier2 catalog verifier
```

`HashStatus` is set by the catalog verifier at admission time (see §5 below).
Default (zero value) is treated as `"uncatalogued"` by routing and disclosure.

Update `RoutingEligible()` to add hash exclusion logic:
- If `HashStatus` is `hash_mismatch` or `hash_invalid`, the provider is NOT
  routing-eligible regardless of `require_hash_verified`.
- The hash-mismatch exclusion is unconditional at default config per
  SPEC-008 §5.6: positive evidence of false identity must be excluded even
  without the strict enforcement flag.

### 4. Catalog package — NEW internal/tier2

Create `phase4-coordinator/internal/tier2/catalog.go` (and test file).

This package is responsible for:
- Loading and Ed25519-signature-verifying a JSON catalog file at startup.
- Exposing a `VerifyProviderHash(modelID, reportedHash string) HashStatus`
  function used by the admission path.
- Exposing an `Active() bool` function that returns true when a valid catalog
  is loaded.
- Exposing aggregate counts for `/v1/models` disclosure:
  `HashCounts(modelID string) HashCounts` where `HashCounts` has
  `Verified, Uncatalogued, Mismatch, Invalid int`.

Catalog JSON schema (SPEC-008 §5.2):
```json
{
  "version": 1,
  "catalog_id": "...",
  "issued_at": "...",
  "expires_at": "...",
  "models": [
    {
      "model_id": "...",
      "artifact_kind": "mlx_weight_file",
      "sha256": "64 lowercase hex chars",
      "hash_scope": "primary_weight_file",
      "source": "operator-curated",
      "notes": "optional"
    }
  ],
  "signature": {
    "alg": "Ed25519",
    "key_id": "...",
    "sig": "base64url-unpadded signature over canonical body"
  }
}
```

Canonical body for signature: catalog object WITHOUT the `signature` member,
serialized with deterministic JSON (UTF-8, lexicographic keys, no
insignificant whitespace, arrays in declared order) per SPEC-008 §5.2.

Ed25519 public key format: 32 bytes, base64url-unpadded, from
`config.Tier2.CatalogPublicKey`.

Use Go stdlib `crypto/ed25519` for verification.
Use encoding/json for parsing; implement deterministic canonical serialization
by marshaling the catalog body (excluding `signature`) into a sorted map or
struct and re-encoding with `json.Marshal` (Go's map key ordering is
non-deterministic; use a struct or sort keys manually).

`VerifyProviderHash` behavior:
- If no active catalog: return `HashStatusCatalogUnavailable`.
- If model ID not in catalog: return `HashStatusUncatalogued`.
- If reported hash is empty or provider did not send model_hash:
  return `HashStatusUncatalogued`.
- If reported hash fails the `^[0-9a-f]{64}$` regexp:
  return `HashStatusInvalid`.
- If reported hash matches catalog SHA-256 (case-insensitive compare
  after normalizing to lowercase): return `HashStatusVerified`.
- Otherwise: return `HashStatusMismatch`.

Emit structured log events per SPEC-008 §12.2 / §15.1:
- `T2.A model_hash_verified` (INFO) when a provider hash matches.
- `T2.A model_hash_mismatch` (MAJOR) when a provider hash mismatches.
- `T2.A model_hash_invalid` (MAJOR) when a provider hash is syntactically
  invalid.
- `T2.A catalog_signature_invalid` (MAJOR) on verification failure at load.
- `T2.A catalog_load_failed` (MAJOR) on file read or parse error.
- `T2.A hash_required_provider_excluded` (MAJOR) when
  `require_hash_verified: true` excludes a provider with
  `uncatalogued`/`catalog_unavailable` status.

Log event fields MUST include:
  `event`, `category: "T2.A"`, `severity`, `provider_id`, `assigned_id`,
  `model_id`, `reported_hash_prefix` (first 8 hex chars or empty),
  `expected_hash_prefix` (first 8 hex chars or empty), `catalog_id`,
  `decision`, `reason`, `ts`.

MUST NOT include: full hash, API keys, account IDs, raw prompts, or any
field forbidden by SPEC-008 §12.1.

### 5. Wire up catalog verification in provider admission

Edit `phase4-coordinator/internal/ws/admission.go` (the provider admission
path that processes Hello messages).

After a `Hello` is accepted:
1. Call `catalog.VerifyProviderHash(hello.ModelID, hello.ModelHash)`.
2. Store the result in the `pool.Provider.HashStatus` and `pool.Provider.ModelHash`
   fields before the provider is added to the pool.
3. If the result is `hash_mismatch` or `hash_invalid`:
   - Log the T2.A event.
   - Do NOT reject the provider's connection (the provider may serve other
     models that verify; in single-model mode it will simply be
     routing-ineligible per §5.5 and §5.6).
   - Set the provider state to the computed HashStatus.
4. If `tier2.require_hash_verified: true` and the result is `uncatalogued`
   or `catalog_unavailable`:
   - Log `T2.A hash_required_provider_excluded`.
   - The provider MUST be excluded from routing. You MAY either reject
     admission or set HashStatus and rely on `RoutingEligible()`.

When `tier2.*` all at defaults and no `catalog_path`:
- The catalog is inactive; all providers get `HashStatusUncatalogued`.
- `RoutingEligible()` is unchanged from Tier-1 (no hash check when
  `hash_mismatch`/`hash_invalid` are impossible without a catalog).

### 6. Update routing — require_hash_verified predicate

Edit `phase4-coordinator/internal/buyer/server.go` in `selectProvider` (or
wherever SPEC-002/SPEC-004 routing happens).

Per SPEC-008 §4.5 and §5.6:
- Hash-verified/mismatch/invalid checks are ALREADY handled by
  `RoutingEligible()` (§3 above excludes mismatch/invalid at all times).
- When `tier2.require_hash_verified: true`, also exclude providers whose
  `HashStatus` is `uncatalogued` or `catalog_unavailable`.
- Apply this predicate at EVERY selection step (initial, preflight
  fallback, SPEC-004 retry, hard-pin validation) — not just once.
- Hard-pinned providers that fail the predicate MUST return:
  HTTP 400, error code `tier2_hard_pin_predicate_failed`,
  message "Hard-pinned provider `{provider_id}` does not satisfy enabled
  Tier-2 predicates."
- If no eligible provider remains and `require_hash_verified: true`:
  HTTP 503, error code `tier2_hash_verified_required`,
  message "No hash-verified provider available for model `{model_id}`."
- If no eligible provider remains due to mismatch exclusion at default config
  (positive evidence of false identity, all catalogued providers are
  excluded): HTTP 503, error code `tier2_hash_mismatch`,
  message "Provider `{provider_id}` hash verification failed; excluded
  from pool."

Error envelopes MUST follow SPEC-006 OpenAI-compatible shape:
```json
{"error": {"code": "...", "type": "...", "message": "..."}}
```

### 7. Update /v1/models — coordinator-side hash fields

Edit `phase4-coordinator/internal/buyer/server.go`, `handleModels`.

Per SPEC-008 §5.7:
When Pillar A is active (§4.3 gate: `catalog_path` non-empty, or
`require_hash_verified: true`, or `observe_enabled: true`), add to each
`modelEntry`:
```go
HashVerified     interface{}        `json:"hash_verified,omitempty"`   // true | false | "uncatalogued"
HashVerification *hashVerification  `json:"hash_verification,omitempty"`
```
where `hashVerification` is:
```go
type hashVerification struct {
    Status                  string `json:"status"` // "all_verified" | "partial" | "all_uncatalogued" | "mismatch" etc.
    VerifiedProviderCount   int    `json:"verified_provider_count"`
    UncataloguedProviderCount int  `json:"uncatalogued_provider_count"`
    MismatchProviderCount   int    `json:"mismatch_provider_count"`
    InvalidProviderCount    int    `json:"invalid_provider_count"`
    Catalogued              bool   `json:"catalogued"`
}
```

`hash_verified` value per SPEC-008 §5.7:
- `true`: every currently routable provider for that model is `hash_verified`.
- `"uncatalogued"`: every currently routable provider is `uncatalogued`.
- `false`: mixed, mismatch, invalid, or catalog unavailable.

`hash_verification.status`:
- `"all_verified"` when all routable providers are `hash_verified`.
- `"all_uncatalogued"` when all routable providers are `uncatalogued`.
- `"partial"` when at least one verified and at least one not verified.
- `"mismatch"` when any mismatch or invalid exists.
- `"catalog_unavailable"` when catalog is not loaded.

When Pillar A is NOT active (all defaults, no catalog_path, not
observe_enabled), the `hash_verified` and `hash_verification` fields MUST be
absent — the response MUST be byte-identical to Tier-1.

### 8. Update gateway disclosure — Tier-2 state in tier1_disclosure

Edit `phase5-gateway/internal/router/server.go`, `makeTier1Disclosure`.

The gateway calls the coordinator's `/v1/models` to get model data and adds
`tier1_disclosure` on top.  The gateway's disclosure MUST reflect actual
Tier-2 state from coordinator data per SPEC-008 §13.

Current behavior: disclosure returns the SPEC-006 v0.8 baseline with fixed
`"none"` values for hash, encryption, attestation.

New behavior:
1. After fetching coordinator `/v1/models`, inspect model entries for
   `hash_verified` and `hash_verification` fields (if present).
2. Compute aggregate `model_hash_verified` disclosure value:
   - `"all"` if every model with `hash_verification` present has
     `hash_verified == true`.
   - `"partial"` if at least one model has some verified and some not.
   - `"none"` if no model has any verified providers.
3. When Pillar A is active (any model entry has `hash_verification` key),
   add additive Tier-2 fields per §13.2:
   - `"model_hash_verified"`: computed value above.
   - `"provider_leg_encryption": "none"` (Phase 1 only).
   - `"untrusted_provider_safety": "none"` (Phase 1 only).
   - `"tier2"` object with `phase`, `model_hash`, `encrypted_leg`,
     `attestation`, `behavioral_safety` per §13.2 active-state render.
   - Change `version` to `"v0.8+tier2-v0.2"`.
4. When Pillar A is NOT active:
   - Return the exact SPEC-006 v0.8 baseline — `version: "v0.8"`,
     `plaintext_to_provider`, `model_identity`, `hardware_attestation`,
     `tier2_milestone`, `sticky_affinity` only.
   - No Tier-2 keys present.

The gateway's `tier1Disclosure` struct and `makeTier1Disclosure` function
need to be extended to carry optional Tier-2 fields.  Use `omitempty` on all
new fields so they are absent when Pillar A is not active.

`plaintext_to_provider` remains `true` always (SPEC-008 §13.5).

This update MUST NOT be operator-overrideable.  There is no config flag that
suppresses or overrides disclosure of Tier-2 state.

### 9. Tests

Write tests in:
- `phase4-coordinator/internal/tier2/catalog_test.go`:
  - Load and verify a known-good test catalog (embed a fixture).
  - Reject a catalog with one byte changed in the body.
  - Reject a catalog with an expired `expires_at`.
  - Verify hash match returns `hash_verified`.
  - Verify hash mismatch returns `hash_mismatch`.
  - Verify empty `model_hash` returns `uncatalogued`.
  - Verify syntactically invalid hash returns `hash_invalid`.
  - Verify unknown model_id returns `uncatalogued`.
  - AC-A-1: `catalog_signature_invalid` is logged on corruption.
- `phase4-coordinator/internal/buyer/server_test.go` (add cases):
  - AC-A-5: `require_hash_verified: true` + uncatalogued provider → 503
    `tier2_hash_verified_required`.
  - AC-A-3 / AC-A-4: mismatch excluded; uncatalogued routes at default.
  - AC-T2-5: all defaults → coordinator `/v1/models` response has no
    `hash_verified`, `hash_verification`, or `tier2*` fields.
  - AC-T2-8: hash mismatch excluded from routing.
  - AC-T2-10: require_hash_verified filter.

All existing tests MUST continue to pass.

### 10. coordinator.yaml.example update

Edit (or create) `phase4-coordinator/coordinator.yaml.example`.

Add a commented-out `tier2:` block with all Phase 1 keys and their defaults,
with comments citing the relevant SPEC-008 section.  Example:

```yaml
# tier2:
#   # §4.3 — observation gate; default false; set true to activate Tier-2
#   # evidence logging without enforcement.
#   observe_enabled: false
#
#   # §5 Pillar A — model catalog + hash verification
#   catalog_path: ""                # path to signed catalog JSON; empty = no catalog
#   catalog_public_key: ""          # Ed25519 public key (base64url-unpadded); required when catalog_path non-empty
#   require_hash_verified: false    # default false; set true to route only hash_verified providers
#
#   # Pillar B/C/D keys — not active in Phase 1; include for forward compat
#   require_encrypted_leg: false
#   encrypted_leg_aead: "A256GCM"
#   ...
```

---

## Spec references (read before implementing each section)

- §4.3 Default behavior preservation — the additive-only hard rule.
- §4.5 Additive routing integration — WHERE to insert Tier-2 predicates.
- §4.6 Error table — exact HTTP status, code, type, message for every
  Tier-2 buyer error.
- §4.7 Redaction rule — what MUST NOT appear in error messages or logs.
- §5 Pillar A (all subsections) — the normative spec for this phase.
- §9.1 Phase 1 prerequisites and production enablement sequence.
- §11.1 Config shape (canonical reference for all key names and defaults).
- §11.2 Startup validation.
- §12.1 Common audit log fields.
- §12.2 Pillar A audit events.
- §13 Disclosure update protocol (entire section).
- §15.1 T2.A audit category.
- §14 AC-T2-1 through AC-T2-26 (use as the definition of done).

---

## Hard rules

1. **Additive only.** With all `tier2.*` keys at defaults and no `catalog_path`,
   every coordinator response, log event, and pool operation MUST be
   byte-identical to the current Tier-1 behavior.  Deploying the new binary
   without config changes MUST NOT change any live behavior.

2. **Only Phase 1.**  Do not implement X25519, ECDH, AEAD, Pillar B key
   exchange, Pillar C attestation tokens, or Pillar D output controls.  Add
   config keys (so the YAML loads cleanly) but do not write their logic.

3. **Do not edit spec files.**  `specs/SPEC-008-tier2.md` and all other
   `specs/` documents are read-only in this session.

4. **Do not edit SPEC-001, SPEC-002, SPEC-004, or SPEC-006.**  Their
   implementations are in `phase4-coordinator` and `phase5-gateway`; you
   may extend them additively.

5. **Redaction rule (§4.7).**  Error messages, log events, and WebSocket close
   reasons MUST NOT include raw hashes (beyond 8-char prefix), keys, nonces,
   account IDs, `conv:` values, or buyer prompts.

6. **Disclosure is non-operator-overrideable.**  There is no config flag that
   suppresses `tier1_disclosure` Tier-2 fields once Pillar A is active.

7. **All existing tests must pass.**  Run `go test ./...` in both
   `phase4-coordinator` and `phase5-gateway` before declaring done.

8. **Git.**  When all tests pass, commit using the existing repo conventions
   (user.name=a11, user.email=augstar@gmail.com).  Commit message:
   `feat(tier2): implement SPEC-008 Phase 1 — Pillar A model catalog + hash verification`.

---

## Definition of done

Phase 1 is complete when ALL of the following acceptance criteria pass:

**Survivability (unchanged from Tier 1):**
- AC-T2-1: sticky HMAC collision-resistance unchanged.
- AC-T2-2: no Tier-2 field leaks `conv:` or account ID.
- AC-T2-3: `DELETE /v1/sticky` still account-scoped; no provider can purge sticky.
- AC-T2-4: sticky TTL still coordinator-enforced.

**Default preservation:**
- AC-T2-5: all `tier2.*` at defaults + no catalog → zero behavioral change,
  zero new `/v1/models` fields, zero T2.* log events.

**Pillar A:**
- AC-T2-6: corrupted catalog byte → signature verification fails; no entry
  activated; `T2.A catalog_signature_invalid` logged.
- AC-T2-7: hash match → provider `hash_verified`, remains routable.
- AC-T2-8: hash mismatch → provider excluded for that model;
  `T2.A model_hash_mismatch` logged.
- AC-T2-9: old provider (no `model_hash`) → `uncatalogued`, routes at default
  config; represented as `"uncatalogued"` when Pillar A observation active.
- AC-T2-10: `require_hash_verified: true` + only uncatalogued providers →
  503 `tier2_hash_verified_required`.

**Disclosure:**
- AC-T2-22: after one verified + one uncatalogued provider for same model →
  `tier1_disclosure.model_hash_verified: "partial"`.
- AC-T2-23: no config can force disclosure to claim `"all"` when pool is
  mixed or unsupported.
- AC-T2-24: `plaintext_to_provider: true` always.
- AC-T2-25: T2.A audit events include required fields and exclude forbidden
  fields (§12.1).
- AC-T2-26: hard-pin to mismatch/excluded provider → 400
  `tier2_hard_pin_predicate_failed`; coordinator does NOT route to another.

All existing non-Tier-2 tests must continue to pass.

---

## When done

1. Run `go test ./...` in `phase4-coordinator` and `phase5-gateway`.
2. Ensure `implementation-notes.html` is updated with decisions and open
   questions.
3. Print a ≤150-word handback: what was implemented, what was skipped
   (Phase 2/3), any open questions for the operator.
4. Commit.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~30 min):

1. Read `phase4-coordinator/implementation-notes.html`.
2. Run `go test ./...` independently to confirm all tests pass.
3. Verify that `tier2:` block absent from `coordinator.yaml` → zero behavior
   change at runtime.
4. Verify `curl GET /v1/models` with `catalog_path` set returns `hash_verified`
   field per §5.7.
5. Verify `T2.A model_hash_mismatch` appears in logs for a mismatch provider.
6. Verify AC-T2-5 (no Tier-2 keys in models response at default config).

If clean: file `BUILD_SPEC_008_PHASE2_PROMPT.md` for Pillars B + C (requires
SPEC-001 v2.0 first).

If issues: file `FIX_SPEC_008_PHASE1_V0_2_PROMPT.md` following the fix-pass
pattern from `FIX_SPEC_008_V0_3_PROMPT.md`.
```
