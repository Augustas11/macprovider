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

---

## Queued (priority order)

| ID | Scope | Exit criterion | Area |
|---|---|---|---|
| **P3** | Dashboard log tail wiring (SPEC-026 Step 3 Item 6) | `LogTailView` shows live provider stderr/out tail on dashboard when lines exist (hidden when empty as of v1.8.18) | Malibu UI |

---

## Done

| ID | Shipped | PR / release | Notes |
|---|---|---|---|
| **P4** | 2026-07-07 | (infra PR pending) | `download.malibu.tech` on Pearl nginx + name.com DNS; Sparkle + `latest.dmg` live |
| **P2b** | 2026-07-07 | v1.8.19 (#459 + release) | Autotune feeds on buyer mux `/v1/*`; Pearl deploy + Sparkle release |
| **P2a** | 2026-07-07 | #458 | Autotune `--recommend`/`--apply` hardening |
| **R1** | 2026-07-07 | v1.8.18 (#457) | Sparkle live + dashboard stats clipping fix |
| Pearl static feeds | 2026-07-07 | #454 | Baked catalog sync + nginx EACCES hardening (superseded by P2b buyer mux) |
| Malibu P1 diagnostics | 2026-07-07 | #455 | Provider log tail + stale-catalog UX on onboarding |
| Sparkle in-app updates | 2026-07-07 | #456 | Sparkle in Malibu.app |
| CLI update UI in dashboard | 2026-07-06 | v1.8.16 | Overflow fixed in v1.8.18 |

---

## FAQ

### Update paths (post v1.8.19)

| Path | What it updates |
|---|---|
| **Sparkle** (`Check for Updates…`) | Whole `Malibu.app` bundle via `https://download.malibu.tech/appcast.xml` |
| **CLI self-update** | Disabled under `--managed-by malibu-app` |

### Download host (P4 — live)

Pearl VPS nginx static host. DNS: `download.malibu.tech` **A** → `159.223.165.194`.

Operator scripts (repo):

1. `bash scripts/setup-malibu-download-pearl.sh` — nginx + Let's Encrypt + docroot
2. `bash scripts/publish-malibu-latest-dmg.sh vX.Y.Z` — after GitHub release tag
3. `bash scripts/verify-malibu-download.sh`

GitHub Actions secrets: `MALIBU_DOWNLOAD_VPS_HOST`, `MALIBU_DOWNLOAD_SSH_KEY`.

### SPEC-025 phases vs this file

| SPEC-025 §11 | Status |
|---|---|
| P2 signing / `.dmg` | Done |
| P3 Sparkle | Live (v1.8.19) |
| P4 landing page | **Partial** — download endpoint live; `malibu.tech/host` HTML redesign + troubleshoot page not started |
| P5+ WalletConnect, Homebrew | Backlog |
