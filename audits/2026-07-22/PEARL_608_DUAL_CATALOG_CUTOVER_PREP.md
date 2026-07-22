# Pearl #608 dual-catalog cutover prep (read-only)

**Date:** 2026-07-22T15:42Z  
**Scope:** Read-only Pearl inventory + dual-file removal prep for
[#608](https://github.com/Augustas11/macprovider/issues/608).  
**Mutation:** none (no `/opt/macprovider` edits, no restarts, no publishes,
no exception flips, no `require_hash_verified` changes).

## 1. Pearl inventory (redacted)

### Autotune / network release (active)

| Field | Value |
| --- | --- |
| `current` symlink | `releases/published-2026-07-10-catalog-recovery-v1` |
| `release_id` | `published-2026-07-10-catalog-recovery-v1` |
| `release.json` sha256 | `43944f7577b5e8c124bbe91e9c20e7b14919ff0a86cc1ce613e8334647b4d7ef` |
| `autotune-candidates.json` (current) sha256 | `776182f6230eff098345b188322dba0c7fce47a6da46447432991ffdc37eabda` |
| Feed members in `release.json` | `autotune-candidates.json`, `demand-rank.json` only |
| Signer key id | `streamvc-autotune-static-v4` |
| Config path | `/opt/macprovider/autotune/current/autotune-candidates.json` |

Stale top-level leftover (not the configured path):

- `/opt/macprovider/autotune/autotune-candidates.json` sha256
  `c1e9b5fb8ce5ef1db805136055a6c9bfb02c0f91ad65d9564a1681b9256915dd`
- version label inside that file: `published-2026-07-07-p2-qwen3-8b`

### Tier-2 dual file

| Field | Value |
| --- | --- |
| Path | `/opt/macprovider/tier2-catalog.json` |
| Present | yes |
| size / mtime | 3449 bytes / 2026-07-20 15:58:08 UTC |
| sha256 | `309f67affe840974d04b571db86f343933e3a5785a388d4a39d61c3da0fe1874` |
| `catalog_id` | `macprovider-tier2-model-catalog-2026-07-07-p2-qwen3-8b` |
| model count | 9 |
| `hash_scope` sample | `artifact_manifest` (not `macprovider.snapshot-manifest.v1`) |
| signature | present |

Sample model ids (no secrets): gemma-4-26b, gpt-oss-20b, Llama-3.2-3B,
Meta-Llama-3.1-8B, Nemotron-3-Nano-30B, Qwen2.5-Coder-32B, Qwen3-32B,
Qwen3-8B, Qwen3-Coder-30B.

### Drift matrix (current autotune vs Tier-2 by `model_id`)

**Drift: YES — 1 CONFLICT, 8 AGREE**

| Status | model_id | notes |
| --- | --- | --- |
| CONFLICT | `mlx-community/Llama-3.2-3B-Instruct-4bit` | autotune `e7e5bff4…` vs tier2 `3975387f…` |
| AGREE | remaining 8 overlapping ids | includes live Qwen3-Coder `10adb5da…` |

### Coordinator flags (read-only excerpts)

- Unit: `macprovider-coordinator.service` **active**
  (`ActiveEnterTimestamp=2026-07-22 07:38:21 UTC`)
- Binary mtime matches that restart; sha256
  `e99c32a433752877fdc75e7b449033edab9473c4ce350ebf184963b50532d02d`
- `strings` probe: **0** hits for `identity conflict` / `catalogbind`
  → Pearl binary predates #682 fail-closed binding (merged later same day)
- `autotune.*_path` → `/opt/macprovider/autotune/current/...`
- `tier2.catalog_path` → `/opt/macprovider/tier2-catalog.json`
- `tier2.require_hash_verified` → **false**
- `tier2.model_hash_legacy_until` → **absent**
- Advertised `latest_binary_version` → `1.8.49`
- Overlay: `proof_of_weights.require_autotune_hello_gate: false`
- `macprovider-pearl-updater.timer` → disabled / inactive

### Journal (48h, redacted)

- `model_hash_uncatalogued` count ≈ 9 (all before 07:38 restart;
  Qwen3-Coder, `decision=allow`, prefixes `10adb5da`)
- Since restart: `model_hash_verified` / `hash_match` for Qwen3-8B and
  Qwen3-Coder; `uncatalogued_since_restart=0`
- `identity conflict` count = 0 (expected: catalogbind not in live binary)

### Exception register (repo)

- `exc-catalog-compatibility-bridges` → **active**
- `exc-tier2-hash-mismatch-containment` → **active**
  (`require_hash_verified=false`; #609 owns enforce flip — out of scope)

## 2. Gap list vs remaining #608 bullets

| #608 remaining item | Prod / repo truth now |
| --- | --- |
| Ledger / compatibility-set membership for signed Tier-2 bytes | **Gap.** `release-ledger.json` / Pearl `release.json` feeds are only `autotune-candidates.json` + `demand-rank.json`. Zero `tier2` feed keys. Repo `tier2-identity-binding.json` is local projection only. |
| Physical dual-file removal path | **Gap (prep only).** Dual file still present; independent authority still live via `tier2.catalog_path`. Live mutate gated in repo (#688) but Pearl binary not yet carrying that lineage. **Do not delete yet.** |
| Explicit Tier-2 `macprovider.snapshot-manifest.v1` `hash_scope` | **Gap.** Live Tier-2 rows use `artifact_manifest`. `derive-tier2` correctly disabled until SPEC-008 enum gains snapshot-manifest scope. |
| Exception clearance + Pearl journey proof | **Gap.** Exception remains active. Qwen agrees and post-restart verify events look healthy, but Llama conflict + dual authority block clearance. |
| Ordering vs #609 | Physical identity proof already noted PASS for Qwen canonical hash; **#609 enforce flip not in scope.** Keep `require_hash_verified=false` until algorithm fail-closed + buyer_serving proof. |

### Already true (do not re-implement)

- Repo Partial #682: fail-closed `catalogbind` + binding tooling
- Repo Partial #688: retire live `activate-tier2-observe.sh --apply`;
  deploy-only mutate gate
- Qwen3-Coder identity agrees across current autotune + Tier-2 at `10adb5da…`
- Deploy refuse / check-tier2-binding tooling exists in repo (not yet
  proven on Pearl against the live Llama conflict)

## 3. Cutover prep checklist (future window — do not execute)

Ordered steps, rollback, and stop-conditions for a later dual-file removal
window.

### Prerequisites (code + signed assets)

1. **Resolve Llama-3.2 CONFLICT** so overlapping hashes agree with
   `published-2026-07-10-catalog-recovery-v1` (`e7e5bff4…`), via a reviewed
   Tier-2 republish bound through `check-tier2-binding` — **or** a new
   network release that intentionally carries the Tier-2 hash (prefer
   autotune-as-admission authority).
2. Add signed Tier-2 bytes as a **ledger / compatibility-set feed member**
   of the same release envelope (atomic publish/rollback).
3. Land explicit Tier-2 `hash_scope` for `macprovider.snapshot-manifest.v1`
   (SPEC-008); only then re-enable `derive-tier2`.
4. Promote Pearl coordinator binary that includes #682 `catalogbind` +
   #688 mutate gate (live binary currently lacks both strings).
5. Keep `tier2.require_hash_verified=false` throughout this window
   (#609 separate).

### Pre-flight (read-only)

6. Re-run drift matrix: `CONFLICT=0` on all overlapping `model_id`s.
7. Confirm `release.json` / ledger include Tier-2 feed digest matching
   staged `/opt/macprovider/tier2-catalog.json` (or successor path).
8. Confirm `check-tier2-binding` + `deploy-pearl-vps.sh` dry path refuse
   stale Tier-2 restore.
9. Snapshot rollback artifacts: previous release dir, previous Tier-2
   bytes+sig, previous coordinator binary/yaml unit paths (document only
   until execute window).

### Execute window (future; not this prep)

10. Deploy release that binds autotune + Tier-2 identity atomically.
11. Verify coordinator starts with no `identity conflict`; Tier-2
    consumer resolves from release-bound authority.
12. Only after N healthy buyer_serving cycles with
    `model_hash_uncatalogued=0` for active-release rows: remove or
    tombstone independent `/opt/macprovider/tier2-catalog.json` dual path
    and config pointer as designed by the finish slice.
13. Clear `exc-catalog-compatibility-bridges` only after journey proof.

### Rollback

- Restore previous autotune `current` symlink + matching Tier-2 bytes from
  the pre-window snapshot **together** (never Tier-2 alone).
- Restore previous coordinator binary/config if bind/start fails.
- Leave `require_hash_verified=false`.

### Stop-conditions (abort window)

- Any overlapping `model_id` hash CONFLICT
- Coordinator start/reload fails on catalogbind
- Spike of `model_hash_uncatalogued` / `hash_mismatch` for active-release
  models after cutover
- Attempt to flip `#609` enforce in the same window
- Ledger/tombstone evolution failure or unsigned Tier-2 bytes

## 4. #609 dependency note (enforce flip NOT in scope)

After #608 dual-authority removal, **still required before**
`tier2.require_hash_verified=true`:

1. Coordinator promote with Entry 170 algorithm fail-closed for missing /
   unknown `model_hash_algorithm`.
2. Physical providers report
   `model_hash_algorithm=macprovider.snapshot-manifest.v1` into
   `buyer_serving`.
3. Zero reliance on `MODEL_HASH_LEGACY_UNTIL` / legacy bridge events.
4. Single release-bound identity authority already live (this issue), so
   enforce cannot reintroduce dual-file drift.

This prep does **not** start #609 and must not mutate
`require_hash_verified`.

## 5. Top 5 cutover prerequisites (summary)

1. Fix Llama-3.2 hash CONFLICT (`e7e5…` vs `3975…`).
2. Ledger/compatibility-set membership for signed Tier-2 bytes.
3. Explicit Tier-2 `macprovider.snapshot-manifest.v1` hash_scope; keep
   `derive-tier2` disabled until then.
4. Promote Pearl coordinator with #682/#688 lineage (catalogbind +
   deploy-only mutate).
5. Dual-file removal + Pearl journey proof, then clear
   `exc-catalog-compatibility-bridges` — without #609 enforce flip.
