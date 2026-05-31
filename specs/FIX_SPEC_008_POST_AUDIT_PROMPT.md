# Fix Prompt — SPEC-008 Post-Build Cross-Check Audit

Self-contained Codex/Claude Code prompt.
Root: `/Users/augstar/macprovider-poc`.
No prior session context required. Read this file in full before touching any code.

Source: independent Claude cross-check audit of the SPEC-008 Phase 1 implementation,
run after the Codex three-pass audit returned CLEAR. Eleven findings across two
components. Two are HIGH (data race, disclosure availability), five are MEDIUM
(correctness/accuracy), four are LOW (dead code, maintenance).

After all fixes: `go test ./... -count=1` must pass in both
`phase4-coordinator/` and `phase5-gateway/`. `go build ./...` must succeed.
`git diff --check` must be clean.

---

## Fix 1 — ws.Server data race: SetTier2Config writes s.cfg.Tier2 under tier2Mu but concurrent readers access s.cfg.Auth/Pool without it

**Severity: HIGH — race detector fires on any SIGHUP concurrent with a provider WebSocket connection.**

### Root cause

`phase4-coordinator/internal/ws/server.go`:

- `SetTier2Config` (line 97-101) acquires `tier2Mu.Lock()` and writes `s.cfg.Tier2 = cfg`.
- `tier2Config()` (line 122-126) reads `s.cfg.Tier2` under `tier2Mu.RLock()`.

But `s.cfg` is a value-type `config.Config` struct. Writing `s.cfg.Tier2` (a
multi-word struct copy) races with concurrent reads of `s.cfg.Auth.OperatorKey`
(line 1108, in `authorizedOperator`), `s.cfg.Pool.WarmupGateEnabled` (lines 271,
323, in `handleConn`), and a dozen other `s.cfg.Pool.*` reads in helper methods —
none of which hold `tier2Mu`. The Go race detector will flag this on the first
concurrent SIGHUP + provider connection.

`buyer.Server` (phase4-coordinator/internal/buyer/server.go) avoids this correctly
by having a **separate** `tier2 config.Tier2Config` field (not embedded in `s.cfg`)
protected by its own mutex. Mirror that pattern in `ws.Server`.

### Fix required

In `phase4-coordinator/internal/ws/server.go`:

1. Add a separate `tier2 config.Tier2Config` field to the `Server` struct,
   immediately after `tier2Mu sync.RWMutex`. Keep `tier2Mu` as is.

2. Change `SetTier2Config` to write to `s.tier2`:
   ```go
   func (s *Server) SetTier2Config(cfg config.Tier2Config) {
       s.tier2Mu.Lock()
       defer s.tier2Mu.Unlock()
       s.tier2 = cfg
   }
   ```

3. Change `tier2Config()` to read from `s.tier2`:
   ```go
   func (s *Server) tier2Config() config.Tier2Config {
       s.tier2Mu.RLock()
       defer s.tier2Mu.RUnlock()
       return s.tier2
   }
   ```

4. In `NewServer`, initialise `s.tier2 = cfg.Tier2` alongside the rest of the
   struct initialisation (or in the existing `WithTier2Config` option if one exists).
   Search for any place that sets the initial tier2 config via the option path and
   ensure it writes to `s.tier2`, not `s.cfg.Tier2`.

5. After this change `s.cfg` is never written after construction, so all other
   `s.cfg.*` reads are safe without any lock.

6. Verify no code path writes `s.cfg.Tier2` directly outside of construction.
   Search: `grep -n "s\.cfg\.Tier2" phase4-coordinator/internal/ws/server.go`
   — after the fix the only hits should be the constructor.

### Acceptance test

Existing ws/server tests must continue to pass. No new test required; the race
detector (`go test -race ./...`) catching the absence of a race is the proof.

---

## Fix 2 — /v1/models returns 502 when /internal/routing is unreachable on a Tier-2-active coordinator

**Severity: HIGH — availability regression: /v1/models hard-fails when /internal/routing has a momentary blip, even though the buyer port and model data are healthy.**

### Root cause

`phase5-gateway/internal/router/server.go`, function `tier1DisclosureForModels`
(around line 853):

```go
metadata, ok := s.coordinatorRoutingMetadataFresh(ctx)
if !ok || !metadata.Tier2.ModelHash.Active {
    return disclosure, !(bodyActive || bodyMetadataActive)
}
```

When `!ok` (routing fetch failed) **and** `bodyActive=true` (coordinator /v1/models
already returned hash_verification rows), the expression evaluates to
`!(true || ...)` = `false`, causing `handleModels` to write a 502
`tier2_metadata_unavailable` response.

The fail-closed policy is correct when there is no hash evidence from the body —
the gateway cannot know whether tier2 is active. But when the coordinator /v1/models
response already contains hash_verification data (`bodyActive=true`), the hash
state IS known from the body itself; the only thing missing is the `phase` field
from the metadata. A safe phase=1 fallback is both accurate (Pillar A is active, as
evidenced by the body rows) and avoids the availability regression.

### Fix required

In `tier1DisclosureForModels`, replace:

```go
metadata, ok := s.coordinatorRoutingMetadataFresh(ctx)
if !ok || !metadata.Tier2.ModelHash.Active {
    return disclosure, !(bodyActive || bodyMetadataActive)
}
phase = tier2PhaseFromMetadata(metadata.Tier2.Phase)
if !bodyActive {
    state = disclosureStateFromMetadata(metadata.Tier2.ModelHash.State)
}
```

with:

```go
metadata, ok := s.coordinatorRoutingMetadataFresh(ctx)
if !ok {
    // If the body already contains hash rows the state is derived from those;
    // use phase=1 (Pillar A) as a safe fallback when metadata is unavailable.
    // If there is no body hash data but top-level tier2 metadata was present,
    // fail closed — we cannot safely synthesise a disclosure.
    if bodyActive {
        phase = 1
        // fall through: state is derived from body rows below (bodyActive branch)
    } else {
        return disclosure, !bodyMetadataActive
    }
} else if !metadata.Tier2.ModelHash.Active {
    return disclosure, !(bodyActive || bodyMetadataActive)
} else {
    phase = tier2PhaseFromMetadata(metadata.Tier2.Phase)
    if !bodyActive {
        state = disclosureStateFromMetadata(metadata.Tier2.ModelHash.State)
    }
}
```

The net effect:
- `/internal/routing` down + body has hash rows → proceed with phase=1, body-derived state. No 502.
- `/internal/routing` down + body has only top-level `tier2` metadata (no rows) → 502 (fail closed, correct).
- `/internal/routing` down + no tier2 data anywhere → Tier-1 fallback success (unchanged behaviour).

### Acceptance test

Add a gateway test `TestModelsDisclosureUsesPhase1FallbackWhenRoutingUnavailableButBodyHasHashRows`:
- Coordinator `/v1/models` returns a model entry with `hash_verified=true`,
  `hash_verification` rows (verified_provider_count=1).
- Coordinator `/internal/routing` returns HTTP 503.
- Expect gateway `/v1/models` → HTTP 200 with
  `tier1_disclosure.tier2.phase == 1` and
  `tier1_disclosure.model_hash_verified == "all"`.

---

## Fix 3 — disclosureStateFromMetadata silently maps coordinator "required" → "none", hiding active enforcement

**Severity: MEDIUM — buyer disclosure says "no hash verification" when hash enforcement is active and is the precise reason no providers are serving.**

### Root cause

`phase5-gateway/internal/router/server.go`, `disclosureStateFromMetadata` (line 897):

```go
func disclosureStateFromMetadata(state string) string {
    switch state {
    case "all", "partial", "none":
        return state
    default:
        return "none"
    }
}
```

The coordinator's `internalTier2Metadata` (buyer/server.go line 294-296) emits
`state = "required"` when `active && cfg.RequireHashVerified`. This value reaches
the gateway's metadata-fallback path and silently becomes `"none"` via the default
case, making the disclosure look identical to a coordinator where no enforcement is
configured.

### Fix required

**Step A — make the mapping explicit** in `disclosureStateFromMetadata`:

```go
func disclosureStateFromMetadata(state string) string {
    switch state {
    case "all", "partial", "none":
        return state
    case "required":
        // Enforcement is active but no providers are currently serving;
        // ModelHashVerified is "none" (no verified models available).
        return "none"
    default:
        return "none"
    }
}
```

This clarifies intent and prevents future state strings from silently collapsing.

**Step B — fix the root source** in `buyer/server.go`,
`internalTier2Metadata` (lines 291-303):

The `state` field should reflect the actual aggregate hash coverage across all
current providers, not just the config flag. Replace the binary
`"none"` / `"required"` computation with a three-value computation that mirrors
what `applyHashVerification` produces for individual model entries:

```go
modelHashState := "none"
if active {
    providers := s.pool.Snapshot()
    // aggregate all base-routable providers across all models
    var verified, mismatched, uncatalogued int
    for _, p := range providers {
        if !baseRoutingEligible(p) {
            continue
        }
        switch s.effectiveHashStatus(p, cfg) {
        case pool.HashStatusVerified:
            verified++
        case pool.HashStatusMismatch, pool.HashStatusInvalid:
            mismatched++
        case pool.HashStatusUncatalogued, pool.HashStatusCatalogUnavailable:
            uncatalogued++
        }
    }
    total := verified + mismatched + uncatalogued
    switch {
    case total == 0 || (mismatched == 0 && uncatalogued == 0 && verified == 0):
        if cfg.RequireHashVerified {
            modelHashState = "required"
        }
    case verified == total:
        modelHashState = "all"
    case verified > 0:
        modelHashState = "partial"
    default:
        modelHashState = "none"
    }
}
```

After this change the `/internal/routing` response carries `"all"`, `"partial"`,
`"none"`, or `"required"` (empty-pool enforcement), which the gateway's
`disclosureStateFromMetadata` handles correctly.

### Acceptance test

Add a coordinator test `TestInternalRoutingReflectsActualHashCoverage`:
- Pool with one verified provider: metadata state = `"all"`.
- Pool with one verified + one uncatalogued: state = `"partial"`.
- Pool empty + RequireHashVerified=true: state = `"required"`.
- Pool empty + RequireHashVerified=false (observe): state = `"none"`.

---

## Fix 4 — observedModelHashEvidence returns true for providers whose ModelHash was stored before tier2 was active

**Severity: MEDIUM — phase reporting overstates trust posture after SIGHUP activates tier2 on a coordinator with pre-existing provider connections.**

### Root cause

`phase4-coordinator/internal/ws/server.go` `handleConn` stores `hello.ModelHash`
into the pool unconditionally (line 261-262), even when `!tier2.ModelHashActive(...)`.
The hash value is stored as evidence of what the provider reported, but no
`VerifyProviderHash` call was made and `HashStatus` is `""` (empty).

`buyer/server.go` `observedModelHashEvidence` (line 318-324) iterates the pool and
returns `true` if any provider has a non-empty `ModelHash`. When tier2 is later
activated via SIGHUP (`ObserveEnabled=true`, no catalog), this function finds the
pre-existing stored hashes and reports `observedModelHash=true`.

`PhaseForConfigWithModelHashEvidence` then evaluates `cfg.ObserveEnabled &&
observedModelHash` → `pillarA=true` → returns Phase 1.

But no tier2 verification has ever been performed for those providers. Phase 1
overstates actual trust posture.

### Fix required

`observedModelHashEvidence` must only count providers that have been actually
processed by tier2 — i.e., providers whose `HashStatus` is non-empty (any value
other than `""`). An empty `HashStatus` means tier2 was inactive at registration
time and the hash was never checked.

```go
func (s *Server) observedModelHashEvidence() bool {
    for _, p := range s.pool.Snapshot() {
        if strings.TrimSpace(p.ModelHash) != "" && p.HashStatus != "" {
            return true
        }
    }
    return false
}
```

After this change, only providers that connected while tier2 was active (and thus
had `VerifyProviderHash` called, setting a non-empty `HashStatus`) contribute to the
phase evidence signal. Providers from before tier2 was activated are excluded until
they reconnect or are refreshed by `RefreshTier2HashStatuses`.

### Acceptance test

Add a buyer test `TestObservedModelHashEvidenceIgnoresPreTier2Hashes`:
- Register a provider with `ModelHash="abc…"` but `HashStatus=""` (simulates
  pre-activation pool entry).
- Server has `ObserveEnabled=true`.
- Call `/internal/routing` and assert `tier2.phase == 0` (not 1).

---

## Fix 5 — post-Configure RequireHashVerified guard fires on expired catalog with misleading "startup catalog" message

**Severity: MEDIUM — operator diagnoses a startup issue when the actual problem is that the running catalog has expired.**

### Root cause

`phase4-coordinator/cmd/coordinator/main.go`, `reloadTier2Config` (line 141):

```go
if cfg.Tier2.RequireHashVerified && !tier2.Active() {
    logger.Error().Msg("tier2 config reload rejected: require_hash_verified requires the startup catalog to be active")
    return
}
```

`tier2.Active()` calls `activeCatalogLocked()` which returns `nil` when the catalog
has expired at runtime (active pointer is non-nil but `nowUTC() >= ExpiresAt`).
This causes the guard to fire on catalog expiry, not just on "catalog was never
loaded". The error message says "startup catalog" but the actual condition is
"current active catalog has expired (or was never loaded)".

Additionally, on a fresh first-boot failure followed by a SIGHUP, the guard fires
correctly but the message is still misleading.

### Fix required

Replace the guard with a more precise check and message:

```go
if cfg.Tier2.RequireHashVerified && !tier2.Active() {
    if tier2.Configured() {
        logger.Error().Msg("tier2 config reload rejected: require_hash_verified requires an active (non-expired) catalog; the current catalog has expired or failed to load")
    } else {
        logger.Error().Msg("tier2 config reload rejected: require_hash_verified requires a configured catalog")
    }
    return
}
```

`tier2.Configured()` returns `true` when `Configure` was previously called with a
non-empty `CatalogPath`, giving the operator a signal about whether the catalog was
once present (and has since expired or failed) vs never configured.

No test change required; the message correction is a pure UX improvement.

---

## Fix 6 — tier2Phase1Blocked constant declared but never used; default in tier2PhaseFromMetadata returns 1 for unknown phase values

**Severity: LOW — dead code and incorrect gateway fallback for future/unknown phase values.**

### Part A — tier2Phase1Blocked unused constant

`phase4-coordinator/cmd/coordinator/main.go` (line 172):

```go
const (
    tier2HotReloadable tier2ReloadFieldClass = "hot_reloadable"
    tier2StartupOnly   tier2ReloadFieldClass = "startup_only"
    tier2Phase1Blocked tier2ReloadFieldClass = "phase1_blocked"  // never used
)
```

`tier2Phase1Blocked` is declared but never assigned to any field in
`tier2ReloadFieldClasses`. `config.Load()` (which calls `Validate()`) is the sole
Phase 1 enforcement gate, making this constant's intended second-layer guard absent.

**Fix**: Either wire it up for the Phase 1-unimplemented fields **or** remove it.
Given that `config.Load()` provides complete protection, removing the constant is
the honest choice and avoids the impression of a defence-in-depth guard that is not
actually active.

Remove the `tier2Phase1Blocked` constant declaration. Add a comment above
`tier2ReloadFieldClasses` explaining that Phase 1 blocking is handled by
`config.Validate()` (called inside `config.Load()`), so all future-phase fields
(RequireEncryptedLeg, RequireAttestation, BehavioralSafetyEnabled, etc.) are
correctly listed as `tier2HotReloadable` — they are safe to accept in config because
`Load()` will reject them before `reloadTier2Config` proceeds:

```go
// Fields not listed here default to startup-only (SIGHUP rejected if changed).
// Phase-1-blocked fields (RequireEncryptedLeg, RequireAttestation,
// BehavioralSafetyEnabled, etc.) are listed as hot-reloadable because
// config.Load() → config.Validate() rejects them before reloadTier2Config
// reaches the field-class check. When Phase 2/3 removes those blocks, update
// the field class here.
var tier2ReloadFieldClasses = map[string]tier2ReloadFieldClass{ ... }
```

### Part B — dead `case int:` branch and wrong default in tier2PhaseFromMetadata

`phase5-gateway/internal/router/server.go`, `tier2PhaseFromMetadata` (line 906):

```go
case int:                              // unreachable: JSON unmarshal into `any` always produces float64
    if v == 0 || v == 1 || v == 2 || v == 3 {
        return v
    }
...
return 1  // default — wrong for unknown/future phase values
```

`json.Unmarshal` into an `any` field always produces `float64` for JSON numbers,
never `int`. The `case int:` branch is dead code. The `return 1` default is also
wrong: an unknown or out-of-range phase value (e.g. phase=5 from a future spec)
would be represented as Phase 1 to buyers, misrepresenting the trust tier.

**Fix**:

1. Remove the `case int:` branch.
2. Change the default `return` from `1` to `0`:

```go
func tier2PhaseFromMetadata(phase any) any {
    switch v := phase.(type) {
    case string:
        if v == "mixed" {
            return v
        }
    case float64:
        if v == 0 || v == 1 || v == 2 || v == 3 {
            return int(v)
        }
    case json.Number:
        i, err := v.Int64()
        if err == nil && i >= 0 && i <= 3 {
            return int(i)
        }
    }
    return 0  // unknown phase: safe default, does not claim enforcement
}
```

Returning `0` for unknown/invalid phase values is conservative: it signals "no
verified enforcement" rather than falsely claiming Phase 1.

Update the `intFromModelField` helper (around line 981) the same way if it also has
a dead `case int:` branch.

---

## Fix 7 — effectiveHashStatus re-verifies all providers from scratch on every routing request

**Severity: LOW (efficiency and dual-path consistency) — unnecessary catalog lock contention; pool-stored HashStatus is already kept current by RefreshTier2HashStatuses.**

### Root cause

`phase4-coordinator/internal/buyer/server.go`, `effectiveHashStatus` (line 441):

```go
func (s *Server) effectiveHashStatus(p pool.Provider, cfg config.Tier2Config) pool.HashStatus {
    if !tier2.ModelHashActive(cfg) {
        return p.HashStatus
    }
    if strings.TrimSpace(p.ModelHash) == "" && p.HashStatus != "" && !tier2.CatalogUnavailable() {
        return p.HashStatus
    }
    return tier2.VerifyProviderHash(p.ModelID, p.ModelHash)
}
```

This calls `tier2.VerifyProviderHash` (acquires `global.mu.RLock()`) for every
provider on every routing request and every `/v1/models` call. Meanwhile,
`ws.Server.RefreshTier2HashStatuses()` already bulk-updates `pool.Provider.HashStatus`
at connect time and on every SIGHUP. The pool-stored `HashStatus` is the authoritative
freshly-computed value.

Using `effectiveHashStatus` to re-derive what the pool already has creates:
- O(N providers) unnecessary catalog read-lock acquisitions per request.
- Two independent code paths for hash status (pool field vs live computation)
  that can produce different results between a SIGHUP reload completing and the
  buyer server's tier2 config being updated.

### Fix required

Prefer the pool-stored `HashStatus` when it is non-empty, and only fall back to
`VerifyProviderHash` for providers that were registered before the current tier2
config was activated (i.e., `HashStatus == ""`):

```go
func (s *Server) effectiveHashStatus(p pool.Provider, cfg config.Tier2Config) pool.HashStatus {
    if !tier2.ModelHashActive(cfg) {
        return p.HashStatus
    }
    // Prefer pool-stored status: it is set at connect time and refreshed on
    // SIGHUP by RefreshTier2HashStatuses. Only fall back to live verification
    // for providers that connected before tier2 was activated (HashStatus=="").
    if p.HashStatus != "" {
        return p.HashStatus
    }
    // Provider connected before tier2 was active: compute now.
    return tier2.VerifyProviderHash(p.ModelID, p.ModelHash)
}
```

Remove the `CatalogUnavailable()` guard in the middle branch — it was protecting
against a now-unnecessary early-return path and adds a second lock acquisition.

Ensure `RefreshTier2HashStatuses` is called in `reloadTier2Config` **after** both
`wsServer.SetTier2Config` and `buyerServer.SetTier2Config` so the pool is in sync
before the first request using the new config reaches `effectiveHashStatus`. This is
already the case in the current code; verify it remains so.

### Acceptance test

Existing tests cover the routing behaviour. Verify with a focused test that a
provider whose `HashStatus` was pre-set to `HashStatusMismatch` in the pool is
excluded by `effectiveHashStatus` without calling `VerifyProviderHash` (can be
verified by configuring a catalog-less tier2 config where `VerifyProviderHash`
would return `HashStatusUncatalogued`, not `HashStatusMismatch`).

---

## Fix 8 — VerifyProviderHash duplicates CatalogUnavailable inline logic

**Severity: LOW (maintenance) — two code paths must be kept in sync; a future update to one can silently diverge from the other.**

### Root cause

`phase4-coordinator/internal/tier2/catalog.go`, `VerifyProviderHash` (line 322):

```go
catalog := activeCatalogLocked(st)
if catalog == nil {
    if st.configured && (st.loadFailed || st.active != nil) {
        return pool.HashStatusCatalogUnavailable
    }
    return pool.HashStatusUncatalogued
}
```

The condition `st.configured && (st.loadFailed || st.active != nil)` is a manual
inline duplicate of the logic inside `CatalogUnavailable()`. Any future change to
the unavailability definition in `CatalogUnavailable()` must also be applied here.

### Fix required

Replace the inline condition with a call to the public `CatalogUnavailable()` logic.
Since `VerifyProviderHash` already copies `global.st` under `RLock` before
releasing, and `CatalogUnavailable()` re-acquires the lock internally, you should
instead extract the check into an unexported helper that operates on an already-read
`state` value:

```go
// catalogUnavailableLocked returns true when a catalog was configured but is
// not currently usable (load failed or expired). Must be called with a copy of
// global.st already read.
func catalogUnavailableLocked(st state) bool {
    return st.configured && activeCatalogLocked(st) == nil && (st.loadFailed || st.active != nil)
}
```

Use `catalogUnavailableLocked(st)` inside `VerifyProviderHash` and call it from
`CatalogUnavailable()` as well (acquiring the lock once, reading state, then
calling the helper). This eliminates the duplication while avoiding a
double-lock.

---

## Fix 9 — tier2ReloadFieldClasses has no compile-time enforcement; missing fields silently default to startup-only

**Severity: LOW (maintenance) — future Tier2Config fields not added to the map block SIGHUP with no diagnostic output.**

### Root cause

`phase4-coordinator/cmd/coordinator/main.go`, `tier2StartupFieldsChanged` (line 151):

The function iterates `reflect.TypeOf(config.Tier2Config{})` fields and looks up
each field name in `tier2ReloadFieldClasses`. If a field is **absent** from the map,
the `!ok` branch treats it as startup-only and blocks SIGHUP. No log entry names the
offending field; the operator sees only "startup-only tier2 fields require restart".

### Fix required

1. **Add diagnostic logging** in `tier2StartupFieldsChanged`: when an unregistered
   field has changed (the `!ok || class != tier2HotReloadable` branch fires), log
   the field name before returning `true`. This gives the operator immediate
   diagnostic output.

2. **Add a unit test** `TestTier2ReloadFieldClassesCoversAllTier2ConfigFields` in
   `phase4-coordinator/cmd/coordinator/` that reflects over `config.Tier2Config` and
   asserts every exported field appears in `tier2ReloadFieldClasses`. The test should
   fail compilation-style at test time if a new field is added without updating the
   map:

   ```go
   func TestTier2ReloadFieldClassesCoversAllTier2ConfigFields(t *testing.T) {
       typ := reflect.TypeOf(config.Tier2Config{})
       for i := 0; i < typ.NumField(); i++ {
           name := typ.Field(i).Name
           if _, ok := tier2ReloadFieldClasses[name]; !ok {
               t.Errorf("Tier2Config field %q is not registered in tier2ReloadFieldClasses; "+
                   "add it as tier2HotReloadable or tier2StartupOnly", name)
           }
       }
   }
   ```

This test acts as the compile-time enforcement mechanism: any new field added to
`Tier2Config` without updating the map will cause this test to fail.

---

## Final verification

After completing all fixes, run in order:

```bash
cd /Users/augstar/macprovider-poc

# Coordinator
cd phase4-coordinator
go build ./...
go test ./... -count=1
go test -race ./... -count=1 -run TestTier2

# Gateway
cd ../phase5-gateway
go build ./...
go test ./... -count=1

# Clean diff
cd ..
git diff --check
```

All tests must pass. The race detector run on tier2-related coordinator tests must
complete without data race reports.

---

## Summary of changes by file

| File | Issues addressed |
|------|-----------------|
| `phase4-coordinator/internal/ws/server.go` | Fix 1 (data race) |
| `phase5-gateway/internal/router/server.go` | Fix 2 (502 regression), Fix 6B (dead branch + wrong default) |
| `phase5-gateway/internal/router/server.go` | Fix 3A (disclosureStateFromMetadata explicit mapping) |
| `phase4-coordinator/internal/buyer/server.go` | Fix 3B (internalTier2Metadata real state), Fix 4 (observedModelHashEvidence), Fix 7 (effectiveHashStatus efficiency) |
| `phase4-coordinator/cmd/coordinator/main.go` | Fix 5 (guard message), Fix 6A (remove tier2Phase1Blocked), Fix 9 (field-coverage test + logging) |
| `phase4-coordinator/internal/tier2/catalog.go` | Fix 8 (CatalogUnavailable dedup) |
| `phase4-coordinator/cmd/coordinator/main_test.go` | Fix 9 (new coverage test) |
