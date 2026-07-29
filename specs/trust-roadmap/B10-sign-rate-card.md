# B10 — Sign the rate card

**Type**: implementation slice — SPEC-023 v0.8.6 signed rate-card feed.

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

**Status (2026-07-29)**: in implementation on branch `feature/trust-b10-sign-rate-card`.

**Signing mechanism chosen**: detached Ed25519 `.sig` sidecar, matching the
existing SPEC-023 `demand-rank` / `autotune-candidates` static-feed mechanism.
The coordinator does not hold signing keys; it verifies and serves literal
static `rate-card.json` bytes from disk when configured.
Pearl deploy includes a reviewed field-scoped migration for existing
two-feed live configs, adding only `autotune.rate_card_path` and
`autotune.rate_card_sig_path` before validation/restart while preserving the
release-bound `/opt/macprovider/autotune/current/...` feed paths.

**Gated on**: PR merge and three-lane audit loop reaching 0 C / 0 H / 0 M.
Independent of G0.

## Problem / shape
`/v1/rate-card` is the only unsigned input on the earnings path (roadmap §4.2,
F2) — the actual money input to autotune ranking, fetched unsigned
(`rate_card.go:39`) while the advisory TPS numbers get full Ed25519 protection.
Signing it is a wire-contract change to a SPEC-023-defined plain-JSON endpoint.
B10 uses a detached sidecar and also binds `rate-card.json` into the static
release manifest/ledger. The rate-card feed keeps its own projection-hash
`version`; it does not reuse the candidate/demand catalog release ID.
