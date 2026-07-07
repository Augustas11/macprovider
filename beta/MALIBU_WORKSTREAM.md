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
| **P2a** | **Harden autotune `--apply`** | `recommend` does not fail entirely when an unrelated catalog row has a bad HF cache; `--candidate-models` scopes recommend probes | PR in progress |

---

## Queued (priority order)

| ID | Scope | Exit criterion | Area |
|---|---|---|---|
| **P2b** | **Consolidate static feeds into buyer API** *(future)* | Live autotune catalog + demand-rank served from coordinator buyer mux (like `/v1/rate-card`); drop Pearl nginx `/opt/macprovider/static/` copy step; keep Ed25519 signatures + baked fallback | Coordinator / ops |
| **P3** | Dashboard log tail wiring (SPEC-026 Step 3 Item 6) | `LogTailView` shows live provider stderr/out tail on dashboard when lines exist (hidden when empty as of v1.8.18) | Malibu UI |

---

## Done

| ID | Shipped | PR / release | Notes |
|---|---|---|---|
| **R1** | 2026-07-07 | v1.8.18 (#457) | Sparkle live + dashboard stats clipping fix |
| Pearl static feeds | 2026-07-07 | #454 | Baked catalog sync + nginx EACCES hardening |
| Malibu P1 diagnostics | 2026-07-07 | #455 | Provider log tail + stale-catalog UX on onboarding |
| Sparkle in-app updates | 2026-07-07 | #456 | Sparkle in Malibu.app |
| CLI update UI in dashboard | 2026-07-06 | v1.8.16 | Overflow fixed in v1.8.18 |

---

## FAQ

### Update paths (post v1.8.18)

| Path | What it updates |
|---|---|
| **Sparkle** (`Check for Updates…`) | Whole `Malibu.app` bundle via `appcast.xml` |
| **CLI self-update** | Disabled under `--managed-by malibu-app` |

### SPEC-025 phases vs this file

| SPEC-025 §11 | Status |
|---|---|
| P2 signing / `.dmg` | Done |
| P3 Sparkle | Live (v1.8.18) |
| P4 landing page | Not started |
| P5+ WalletConnect, Homebrew | Backlog |
