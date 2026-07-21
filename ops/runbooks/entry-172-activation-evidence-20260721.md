# Entry 172 Activation Evidence - 2026-07-21

Redacted checked-in summary of the controlled Entry 172 activation evidence.
Codes, challenges, HMAC material, X bearer tokens, and provider bearers are
intentionally omitted.

## Result

PASS LIVE. The reversible Entry 172 referral flags were left live after the
controlled activation sequence completed.

Final four Pearl referral flags:

- `require_for_registration=true`
- `enable_public_validation=true`
- `enable_join_links=true`
- `enable_social_invite_bonus=true`

Campaign metadata:

- Campaign: `prebeta_20260719`
- Key id: `k1`
- HMAC value: redacted
- X bearer material: redacted
- Seed: `launch_entry172_retry`
- Seed operation id: `3bc003a4-6e0a-42e3-90d3-816ccd41a163`
- Referral code: redacted and not committed

## Executed Baseline

- Public release tag: `v1.8.56`
- CLI: `1.8.56`
- Malibu asset: `Malibu-v1.8.56.dmg`
- Malibu asset SHA-256:
  `b5889de597363b2ecb1df823da93a5ecc555e91d75f8e5eb7208917071f1867b`
- CLI darwin-arm64 SHA-256:
  `55b642c3a600fac8a2dc170971c6c2f990d47dc9075e05cad001b9d596c2ffc8`
- Vercel deploy: `dpl_9SPBC3yygAV9oWvaviAbgmsrB1TG`
- Live join bundle: `/assets/join-D6XXjCu1.js`

## Proof Gates

- D1 hostile-origin CORS: PASS, redacted.
- D2 allowed-origin validation: PASS, redacted.
- D3 fragment-free edge path and log check: PASS, redacted.
- D4 immutable live join download: PASS. The live `/j` target resolved to the
  GitHub `v1.8.56` `Malibu-v1.8.56.dmg` asset and downloaded bytes matched the
  SHA-256 above.
- D5 Copy -> Download -> Paste journey: PASS by operator manual/headed-browser
  confirmation under the resume #3 policy. Server-side code/challenge material
  remained redacted and was not pasted into this file.
- F X exactly-once reward: PASS, redacted. Evidence showed exactly one social
  grant row for the provider/campaign and replay/no-op audit behavior for
  response-loss recovery; X bearer and provider bearer material are omitted.

## Boundaries

- #613 NOT closed by Entry 172; Air exception only.
- The first fresh referred-provider journey is still required.
- The exception remains active until the earliest of
  `2026-07-26T23:59:59Z`, terminal success/failure of the first fresh
  referred-provider journey, or any earlier controlled-sequence failure.
- #658 was not started or modified.
- This evidence file records docs/register evidence only; it does not implement
  #615 enforcement.

## Backup Path Names

Path names only are recorded here; backup contents and secrets are not included.

- `/etc/macprovider/coordinator.pearl-overlays.yaml.entry172-failed-20260721T113322Z`
- `/var/lib/macprovider/coordinator.db.entry172-pre-seed-replace-20260721T114506Z`
- `/etc/macprovider/coordinator.pearl-overlays.yaml.entry172-C-pre-enable-20260721T114550Z`
- `/etc/macprovider/coordinator.pearl-overlays.yaml.entry172-D-failed-20260721T115151Z`
- `/etc/macprovider/coordinator.pearl-overlays.yaml.entry172-phase1-remove-download-url-20260721T120744Z`
- `/etc/macprovider/coordinator.pearl-overlays.yaml.entry172-phase2-C-pre-enable-20260721T121019Z`
- `/etc/macprovider/coordinator.pearl-overlays.yaml.entry172-D5-failed-20260721T121559Z`
- `/etc/macprovider/coordinator.pearl-overlays.yaml.entry172-resume3-C-pre-enable-20260721T122613Z`
- `/etc/macprovider/coordinator.pearl-overlays.yaml.entry172-resume3-E-pre-social-20260721T123103Z`
