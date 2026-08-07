# Prebeta public-stats + download pin honesty (P6)

## `nodes_hardware_attested` == 0

Live overview (2026-08-07): `nodes_online=4`, `nodes_hardware_attested=0`.

This is **not** a rollup bug. Pool counting (SPEC-017) requires
`AttestationStatusAttested` **and** `AttestationTierHardware` (SE hardware
attestation). Operator **Trusted** hardware-trust grants (#582 dual-control)
do **not** set SE `AttestationTierHardware`. Self-signed SE keys also do not
count (by design — see `poolsnapshot` tests).

**Do not** treat this field as “Trusted providers online.” Until SE hardware
attestation is productized, expect `0` even with Trusted Macs serving.

**Marketing / dashboard:** prefer `nodes_online` (and request/token totals).
Do not cite `nodes_hardware_attested` as the live fleet size.

Optional follow-up (separate SPEC): add `nodes_trusted` from the rewards/trust
store if product needs a public Trusted count.

## Malibu public download pin

Checked `https://github.com/.../malibu` `host/index.html` CTA:

- Pin: `…/releases/download/v1.8.69/Malibu-v1.8.69.dmg` — asset **exists** (HTTP 302).
- Latest GitHub release titled “Malibu 1.8.50” also has `Malibu-v1.8.50.dmg`.

Pin is an immutable release URL (SPEC-025), not `latest.dmg` — good. Drift to
watch: marketing pin (`1.8.69`) vs newest Malibu release listing (`1.8.50`).
Confirm which build outside providers should install before changing the pin.

## Per-request earnings tick

Deferred polish on P1: dashboard line like `+$0.0004 · 412 tok` when a credit
lands. Not required for counter motion once adaptive precision ships.
