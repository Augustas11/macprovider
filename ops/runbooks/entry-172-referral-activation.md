# Entry 172 Referral Activation Runbook

## 0. Status / Scope Banner

Docs-only activation checklist for Decision Entry 172 and [SPEC-034 §8](../../specs/SPEC-034-referral-gated-prebeta.md#8-activation-rollback-and-acceptance).

This runbook does not flip production flags, deploy services, create seed codes, write live databases, or cut a release. It describes the operator path for a later controlled private-prebeta activation.

Air exception is not #613 complete. It does not close #613, mark the two-Mac journey conformant, or claim fresh-provider redemption evidence.

Register row: [`exc-entry172-air-referral-activation`](../exceptions/production-exceptions.json) in the #615 production exception register.

Expiry: this exception expires at `2026-07-26T23:59:59Z`, on terminal success or failure of the first fresh referred-provider journey, or on any earlier controlled-sequence failure, whichever occurs first.

Last successful activation evidence: [`entry-172-activation-evidence-20260721.md`](./entry-172-activation-evidence-20260721.md) records the redacted PASS LIVE result for the v1.8.56 execution baseline. Future re-runs must still re-confirm current release tags, asset hashes, deploy IDs, and live flag state before any operation.

Fail closed if any checklist item below is unmet.

## 1. Preconditions

- [ ] Base includes merge `f91b7b6c` / #663 or newer. #663 is the #615 production exception register baseline; #658 remains open for the trust-preserving bridge and physical journey needed for continuous discovery.
- [ ] Exact fragment-aware signed clients are public and verified before any flag change.
  - Last executed public release tag: `v1.8.56`.
  - Last executed CLI baseline: `1.8.56`; CLI darwin-arm64 SHA-256 `55b642c3a600fac8a2dc170971c6c2f990d47dc9075e05cad001b9d596c2ffc8`.
  - Last executed Malibu asset: `Malibu-v1.8.56.dmg`; SHA-256 `b5889de597363b2ecb1df823da93a5ecc555e91d75f8e5eb7208917071f1867b`.
  - Operator must re-confirm latest releases at future execution time and record exact tags, asset names, SHA-256 values, notarization/signature evidence, deploy IDs, and fixed Vercel download asset.
- [ ] Coordinator route and nginx route are present: `location = /v1/referrals/validate` proxies to `127.0.0.1:8443`; historical `/j/` remains an access-log-off, `Cache-Control: no-store`, HTTP 404 tombstone.
- [ ] Vercel `malibu.tech/j` is the only public download authority for the join landing page; invite material uses fragment-only URLs:
  - `https://malibu.tech/j#/<code>`
  - `https://malibu.tech/j#/<code>?c=<64-lowercase-hex>`
- [ ] Sponsor provider is already admitted and buyer-serving before activation work starts.
- [ ] Pearl overlay secrets are not in git. Required secret/config names only:
  - `referrals.campaign = "<CAMPAIGN>"`
  - `referrals.current_key_id = "<KEY_ID>"`
  - `referrals.hmac_keys.<KEY_ID>` sourced from `$MAL_REFERRAL_SECRET`
  - optional `referrals.x_api_bearer_token` sourced from `$X_API_BEARER_TOKEN`
- [ ] Checked-in defaults remain false in `phase4-coordinator/dist/coordinator.yaml`:
  - `referrals.require_for_registration: false`
  - `referrals.enable_public_validation: false`
  - `referrals.enable_join_links: false`
  - `referrals.enable_social_invite_bonus: false`
- [ ] Live prior values are recorded before any Pearl overlay change:

```bash
ssh pearl 'sudo grep -A20 "^referrals:" /etc/macprovider/coordinator.yaml'
```

Record:

```text
require_for_registration=<PRIOR_REQUIRE_FOR_REGISTRATION>
enable_public_validation=<PRIOR_ENABLE_PUBLIC_VALIDATION>
enable_join_links=<PRIOR_ENABLE_JOIN_LINKS>
enable_social_invite_bonus=<PRIOR_ENABLE_SOCIAL_INVITE_BONUS>
campaign=<PRIOR_CAMPAIGN>
current_key_id=<PRIOR_KEY_ID>
hmac_keys_present=<Y/N>
x_api_bearer_token_present=<Y/N>
```

## 2. Secret + Campaign Prep

Do not run these commands from this docs PR. The operator runs them offline during the activation window.

Generate a 32+ byte HMAC secret offline:

```bash
umask 077
openssl rand -base64 32 > referral-hmac-secret.txt
wc -c referral-hmac-secret.txt
```

Store the generated value only on Pearl, in the coordinator overlay/env path used by the deployed service. Never commit it to this repo and never pass it on argv.

Suggested placeholder names:

```text
<CAMPAIGN>=prebeta_2026_entry172
<KEY_ID>=entry172_k1
$MAL_REFERRAL_SECRET=<offline 32+ byte secret>
$X_API_BEARER_TOKEN=<optional X API bearer, if social proof will run>
```

Dry-run seed creation first:

```bash
ssh pearl
cd /opt/macprovider/coordinator
sudo -u macprovider env MAL_REFERRAL_SECRET="$MAL_REFERRAL_SECRET" \
  ./coordinator-cli create-seed-referral \
  --db /var/lib/macprovider/coordinator.db \
  --campaign "<CAMPAIGN>" \
  --key-id "<KEY_ID>" \
  --secret-env MAL_REFERRAL_SECRET \
  --seed-id "<SEED_ID>" \
  --max-uses <MAX_USES> \
  --expires-at "2026-07-26T23:59:59Z"
```

Apply only after the dry-run output is reviewed and recorded:

```bash
sudo -u macprovider env MAL_REFERRAL_SECRET="$MAL_REFERRAL_SECRET" \
  ./coordinator-cli create-seed-referral \
  --db /var/lib/macprovider/coordinator.db \
  --campaign "<CAMPAIGN>" \
  --key-id "<KEY_ID>" \
  --secret-env MAL_REFERRAL_SECRET \
  --seed-id "<SEED_ID>" \
  --max-uses <MAX_USES> \
  --expires-at "2026-07-26T23:59:59Z" \
  --apply \
  --operation-id "<UUID>" \
  --actor "<OPERATOR_EMAIL>" \
  --reason "Entry 172 private-prebeta seed"
```

Record the applied output and audit context:

```text
seed_id=<SEED_ID>
max_uses=<MAX_USES>
operation_id=<UUID>
actor=<OPERATOR_EMAIL>
reason=Entry 172 private-prebeta seed
referral_code=<REDACTED; do not paste into git>
```

Mutation pointers, all dry-run first and all with placeholder-only examples:

```bash
./coordinator-cli adjust-seed-referral --db /var/lib/macprovider/coordinator.db --campaign "<CAMPAIGN>" --key-id "<KEY_ID>" --secret-env MAL_REFERRAL_SECRET --seed-id "<SEED_ID>" --max-uses <NEW_MAX_USES>
./coordinator-cli replace-seed-referral --db /var/lib/macprovider/coordinator.db --campaign "<CAMPAIGN>" --key-id "<KEY_ID>" --secret-env MAL_REFERRAL_SECRET --old-seed-id "<OLD_SEED_ID>" --new-seed-id "<NEW_SEED_ID>" --max-uses <MAX_USES>
./coordinator-cli revoke-referral --db /var/lib/macprovider/coordinator.db --campaign "<CAMPAIGN>" --issuer-id "<SEED_ID>"
```

For apply mode, add `--apply --operation-id "<UUID>" --expect-state "<DRY_RUN_EXPECTED_STATE>" --actor "<OPERATOR_EMAIL>" --reason "<REASON>"` where the command requires expected state.

## 3. Controlled Enable Sequence

Entry 172 order is binding. Do not reorder.

### A. Deploy or Confirm Exact Sources With Flags Off

- [ ] Exact signed/notarized CLI and Malibu assets are public and immutable.
- [ ] Coordinator and nginx route are deployed or confirmed on Pearl.
- [ ] Vercel `https://malibu.tech/j` source is deployed or confirmed and points to the fixed reviewed download asset.
- [ ] Live flags are still at recorded prior/off values before continuing:

```bash
ssh pearl 'sudo grep -A20 "^referrals:" /etc/macprovider/coordinator.yaml'
```

### B. Confirm Sponsor Buyer-Serving

- [ ] Sponsor provider is admitted.
- [ ] Sponsor provider serves a buyer request successfully.
- [ ] Record provider ID, model, request ID, status, and timestamp.

### C. Enable Public Validation and Join Links

Do not edit checked-in `phase4-coordinator/dist/coordinator.yaml`. Edit only Pearl overlay/live config.

Current coordinator config validation requires `enable_join_links=true` to have both `require_for_registration=true` and `enable_public_validation=true`. Therefore:

- Default posture: keep `require_for_registration=false` unless the operator explicitly chooses Entry 172 registration enforcement.
- If the operator does not choose registration enforcement, stop here; `enable_join_links=true` is not valid for the current coordinator.
- If the operator explicitly chooses Entry 172 registration enforcement, set the live Pearl overlay as one reviewed config transaction:

```yaml
referrals:
  require_for_registration: true
  enable_public_validation: true
  enable_join_links: true
  enable_social_invite_bonus: false
  campaign: "<CAMPAIGN>"
  current_key_id: "<KEY_ID>"
  hmac_keys:
    <KEY_ID>: "${MAL_REFERRAL_SECRET}"
  join_base_url: "https://malibu.tech/j"
  x_api_bearer_token: ""
```

Restart or reload using the existing Pearl coordinator procedure only after config syntax validation passes. Record the exact config backup path produced by the deploy/restart procedure.

### D. Proof Gates Before Continuing

All proof gates in this section must pass before enabling social bonus.

Hostile-origin CORS rejection:

```bash
curl -i -sS \
  -H 'Origin: https://malibu.tech.evil.test' \
  -H 'Content-Type: application/json' \
  --data '{"code":"<REDACTED_TEST_CODE>"}' \
  https://coordinator.streamvc.live/v1/referrals/validate
```

Expected: HTTP 403 and no `Access-Control-Allow-Origin` header.

Allowed-origin validation shape:

```bash
curl -i -sS \
  -H 'Origin: https://malibu.tech' \
  -H 'Content-Type: application/json' \
  --data '{"code":"<REDACTED_TEST_CODE>"}' \
  https://coordinator.streamvc.live/v1/referrals/validate
```

Expected: no credentials CORS header, `Cache-Control: no-store`, JSON response, and no challenge or fragment material in the URL.

Fragment-free edge request paths:

```bash
curl -i -sS 'https://malibu.tech/j#/<REDACTED_TEST_CODE>?c=<64-lowercase-hex>'
```

Expected: origin and edge logs show only `/j`; `<REDACTED_TEST_CODE>` and `<64-lowercase-hex>` never appear in server request paths, query strings, or logs.

Public immutable download works:

```bash
curl -I -sS 'https://malibu.tech/j'
curl -I -sS '<FIXED_PUBLIC_MALIBU_DOWNLOAD_URL>'
```

Expected: landing page is reachable; fixed download URL resolves to the reviewed signed/notarized Malibu asset.

Copy -> Download -> Paste path (headed/manual proof, not headless CDP download-event proof):

```text
1. Copy exactly: https://malibu.tech/j#/<REDACTED_TEST_CODE>
2. Open it in a browser.
3. Confirm Malibu download starts from the fixed public authority.
4. Complete the install/open flow.
5. Paste the code into Malibu/CLI when prompted.
6. Confirm no server URL/log contains the code or challenge.
```

### E. Enable Social Invite Bonus Only for Sponsor Test

Only after A-D pass, enable social for the sponsor proof:

```yaml
referrals:
  require_for_registration: true
  enable_public_validation: true
  enable_join_links: true
  enable_social_invite_bonus: true
  campaign: "<CAMPAIGN>"
  current_key_id: "<KEY_ID>"
  hmac_keys:
    <KEY_ID>: "${MAL_REFERRAL_SECRET}"
  join_base_url: "https://malibu.tech/j"
  x_api_bearer_token: "${X_API_BEARER_TOKEN}"
```

Restart or reload through the same coordinator procedure and record the config backup path.

### F. Prove One Real X Initial-Plus-Dwell Exactly-Once Reward

- [ ] Sponsor starts from buyer-serving state.
- [ ] Sponsor obtains one invite URL in exact fragment grammar.
- [ ] Sponsor posts the exact X URL/challenge flow.
- [ ] Coordinator verifies the public post after the configured dwell.
- [ ] Exactly one bonus grant is recorded for the sponsor.
- [ ] Recheck/retry of the same proof is a no-op and does not grant again.
- [ ] Record proof IDs, audit event IDs, provider ID, campaign, and final invite capacity.

### G. Decision Point

PASS: the operator may keep the reversible private-prebeta flags live under Entry 172 until the earliest expiry condition.

FAIL or expiry: immediately roll back the four flags to prior values:

- `require_for_registration`
- `enable_public_validation`
- `enable_join_links`
- `enable_social_invite_bonus`

`require_for_registration=true` is appropriate only when the Entry 172 controlled sequence is being executed and the operator explicitly chooses registration enforcement. Otherwise leave it false. This runbook does not create a broader registration policy.

## 4. Immediate Rollback

Restore exactly the recorded prior values:

```yaml
referrals:
  require_for_registration: <PRIOR_REQUIRE_FOR_REGISTRATION>
  enable_public_validation: <PRIOR_ENABLE_PUBLIC_VALIDATION>
  enable_join_links: <PRIOR_ENABLE_JOIN_LINKS>
  enable_social_invite_bonus: <PRIOR_ENABLE_SOCIAL_INVITE_BONUS>
```

If Entry 172 started from checked-in defaults, rollback values are:

```yaml
referrals:
  require_for_registration: false
  enable_public_validation: false
  enable_join_links: false
  enable_social_invite_bonus: false
```

Rollback command path:

```bash
ssh pearl
sudo cp -a /etc/macprovider/coordinator.yaml "/etc/macprovider/coordinator.yaml.entry172-failed-$(date -u +%Y%m%dT%H%M%SZ)"
sudoedit /etc/macprovider/coordinator.yaml
sudo systemctl restart macprovider-coordinator
curl -i -sS \
  -H 'Origin: https://malibu.tech' \
  -H 'Content-Type: application/json' \
  --data '{"code":"<REDACTED_TEST_CODE>"}' \
  https://coordinator.streamvc.live/v1/referrals/validate
```

When `enable_public_validation=false`, confirm the public validate route is no longer mounted by the coordinator. The nginx exact route may still proxy, but the coordinator should return the normal disabled/not-found behavior rather than live validation.

Confirm durable state is preserved per [SPEC-034 §8](../../specs/SPEC-034-referral-gated-prebeta.md#8-activation-rollback-and-acceptance): committed attribution, tokens, invites, grants, and audit remain intact. Rollback suppresses admission/public validation/join/social exposure; it does not delete committed referral state.

Notify:

```text
owner/operator:
release security/provider lifecycle:
referral activation/security:
```

Capture:

```text
rollback timestamp:
rollback actor:
trigger: failure | expiry | terminal journey result
pre-rollback flag values:
post-rollback flag values:
config backup path:
healthz result:
validate-route result:
durable-state preservation check:
```

## 5. Evidence Log Template

| Timestamp UTC | Actor | Precondition SHA / versions | Proof C public validation + join | Proof D gates | Seed op IDs | X reward proof ID | Final flag values | Rollback performed Y/N |
|---|---|---|---|---|---|---|---|---|
| `<UTC>` | `<OPERATOR_EMAIL>` | `repo=<SHA>; cli=<VERSION>; malibu=<VERSION>; coordinator=<VERSION>; vercel=<DEPLOY_ID>` | `pass/fail + evidence path` | `CORS=<pass/fail>; fragment-free=<pass/fail>; download=<pass/fail>; copy-download-paste=<pass/fail>` | `<UUIDs>` | `<proof/audit id>` | `require_for_registration=<value>; enable_public_validation=<value>; enable_join_links=<value>; enable_social_invite_bonus=<value>` | `<Y/N + backup path>` |

## 6. Explicit Non-Goals / Follow-Ups

- This runbook does not close #613, #658, #582, #617, #661, or any Lane C work.
- #658 still needs the trust-preserving bridge plus physical update, rollback, buyer-serving, and renewal evidence for continuous discovery.
- The first available fresh referred provider must still complete the missing redemption journey.
- Lane C / #615 owns exception inventory. Do not implement #615 from this runbook.
- This runbook does not implement the #658 discovery bridge.
- This runbook does not deploy, tag, publish, change nginx, change checked-in flag defaults, write live DB rows, create real HMAC secrets, or create real seed codes.
