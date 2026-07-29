# B10 — Sign the rate card

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

**Gated on**: a signing-mechanism choice. Independent of G0.

## Problem / shape
`/v1/rate-card` is the only unsigned input on the earnings path (roadmap §4.2,
F2) — the actual money input to autotune ranking, fetched unsigned
(`rate_card.go:39`) while the advisory TPS numbers get full Ed25519 protection.
Signing it is a wire-contract change to a SPEC-023-defined plain-JSON endpoint
(`SPEC-023:273, :283`) whose signing *mechanism* is undecided: detached sidecar
(like the catalog feed) vs folding into the signed release unit. Small, but a
contract change with an open shape — pull out of A7 for exactly that reason.
