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

- #613 NOT closed by Entry 172; Air exception only. This file does not claim
  complete two-Mac physical-journey conformance.
- First fresh referred-provider invite-earn journey: PASS (see section below).
- Exception register row `exc-entry172-air-referral-activation` is `expired` on
  that terminal journey success per SPEC-034 §8 / Entry 172. Status is not
  `removed` until Pearl referral flags are rolled back and
  `post_removal_validation` passes.
- Pearl flags were still live at the time of the journey PASS evidence below;
  flag roll-off remains an operator follow-up.
- #658 was not started or modified.
- This evidence file records docs/register evidence only; it does not implement
  #615 enforcement.

## Fresh referred-provider invite-earn PASS (2026-07-21)

Result: PASS for the Entry 172 first fresh referred-provider journey on Air5.
Invite earn closed. Secrets, invite codes, challenges, HMAC material, and
provider bearers are omitted.

Provider and model:

- Host: Air5 (`MacBook-Air-5.local`)
- `provider_id`: `mp-90542c0bcf7c4d303795cd10bda3830d`
- Model: `mlx-community/Qwen3-8B-4bit`
- Model hash:
  `1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877`
- Campaign: `prebeta_20260719`
- Issuer: `tn6skbiu4cfeiffs` (`base_capacity=1`)

Buyer / settlement evidence (Pearl):

- Buyer hit: HTTP 200
- `request_log.id=19241`
- `settlement_attempt_outputs.id=6020` (`terminal_state=normal_done`)
- `settlement_route_snapshots.id=458` (`spec008_hash_status=hash_verified`,
  hash `1f591f9c…`)
- `settlement_receipt_verdicts.id=458` (`settlement_outcome=verified`,
  `receipt_result=valid`, `closed=1`)

454 → 458 nuance (honest):

- Serving qualification and issuer rows for this fresh provider already existed
  from an earlier Qwen verified verdict `454`
  (`evidence_id=settlement-verdict:454`, `issuer_id=tn6skbiu4cfeiffs`,
  `qualified_at=2026-07-21T14:13:04Z`).
- Those tables are one row per `(campaign, provider_id)`, so buyer hit
  `request_log.id=19241` / verdict `458` did not create duplicate
  qualification or issuer rows.
- The issuer remained valid after verdict `458`; invite earn for this fresh
  journey is closed on issuer `tn6skbiu4cfeiffs`.

Operator-local evidence pointers (path names only; not committed):

- Scratchpad:
  `/Users/augstar/macprovider-entry172-ops/scratchpad/air5-fresh-referred-journey-20260721.md`
- Buyer-proof artifact dir:
  `/Users/augstar/macprovider-entry172-ops/scratchpad/air5-buyer-proof-qwen-20260721T142102Z`

Register follow-up:

- Exception id: `exc-entry172-air-referral-activation` (#615 register).
- Status transition: `active` → `expired` on terminal journey PASS.
- Do not mark `removed` until flag roll-off + post-removal validation.
- Do not treat this PASS as #613 two-Mac conformance.

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
