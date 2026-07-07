# Malibu + provider workstream runbook

**Purpose:** Track *session* priority slices (P1, P2, …) without colliding with
SPEC-025 rollout phases (P0–P6) or unrelated spec numbering elsewhere in the
repo.

**How to use**

- Add rows under **Queued** with a one-line scope + exit criterion.
- When work starts, move to **In flight** with PR link.
- When merged/shipped, move to **Done** with release tag or commit.
- Decisions that change product direction still go in `beta/DECISION_CRITERIA.md`;
  this file is the *what's next* board only.

**Naming:** `P1`, `P2` here mean *next/next-next session priorities*, not
`specs/SPEC-025-native-mac-app.md` §11 phases.

---

## In flight

| ID | Scope | Exit criterion | Notes |
|---|---|---|---|
| **R1** | **Cut v1.8.18** — Sparkle live + dashboard layout fix | Tag ships signed `Malibu-v1.8.18.dmg` + `appcast.xml`; `publish-malibu-latest-dmg.sh` pushes both | PR in progress |

---

## Queued (priority order)

| ID | Scope | Exit criterion | Area |
|---|---|---|---|
| **P2a** | **Harden autotune `--apply`** | `recommend` does not fail entirely when an unrelated catalog row has a bad HF cache (e.g. Llama hash mismatch); scope benchmarks to `--candidate-models` or skip rows that fail artifact verification before Stage 1 | CLI / autotune |
| **P2b** | **Consolidate static feeds into buyer API** *(future)* | Live autotune catalog + demand-rank served from coordinator buyer mux (like `/v1/rate-card`); drop Pearl nginx `/opt/macprovider/static/` copy step; keep Ed25519 signatures + baked fallback | Coordinator / ops |
| **P3** | Dashboard log tail wiring (SPEC-026 Step 3 Item 6) | `LogTailView` shows live provider stderr/out tail on dashboard when lines exist (hidden when empty as of v1.8.18) | Malibu UI |

---

## Done

| ID | Shipped | PR / release | Notes |
|---|---|---|---|
| Pearl static feeds | 2026-07-07 | #454 | Baked catalog sync + nginx EACCES hardening |
| Malibu P1 diagnostics | 2026-07-07 | #455 | Provider log tail + stale-catalog UX on onboarding |
| Sparkle in-app updates | 2026-07-07 | #456 → `main` `47d838d` | Sparkle code on main; goes live with R1 |
| CLI update UI in dashboard | 2026-07-06 | v1.8.16 (`c73d4fe`) | Added CLI version + update rows; overflow fixed in v1.8.18 |

---

## Release checklist (R1 — v1.8.18)

1. [x] Fix dashboard right-panel overflow (scroll + hide empty log tail).
2. [x] Bump `MARKETING_VERSION` / `CoordinatorClient.binaryVersion` → `1.8.18`.
3. [ ] Tag `v1.8.18`; confirm CI release attaches `appcast.xml` (`SPARKLE_EDDSA_PRIVATE_KEY` set ✓).
4. [ ] `bash scripts/publish-malibu-latest-dmg.sh v1.8.18` → `latest.dmg` + `appcast.xml` on `download.malibu.tech`.
5. [ ] Smoke: **Check for Updates…** on a test Mac finds feed.

---

## FAQ

### Can I update Malibu before v1.8.18 ships?

| Path | Works today? | What it updates |
|---|---|---|
| **CLI update button** (`Update to v1.8.16`) | Yes on builds ≤ v1.8.16 that still ship the old dashboard | Bundled `macprovider-cli` via catalog/`install.sh` — **not** the `.app` shell |
| **Sparkle** (`Check for Updates…`) | After R1 | Whole `Malibu.app` bundle via `appcast.xml` |

After v1.8.18: Sparkle owns app updates; CLI self-update stays off under `--managed-by malibu-app`.

### SPEC-025 phases vs this file

| SPEC-025 §11 | Status |
|---|---|
| P2 signing / `.dmg` | Done (release pipeline) |
| P3 Sparkle | Live after R1 |
| P4 landing page | Not started |
| P5+ WalletConnect, Homebrew | Backlog |
