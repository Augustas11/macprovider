# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-09-25T07:35:49.590Z

## Original task

# Codex audit: deploy exact-byte catalog canary expects the signed rate card (#1746)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-canary-ratecard`. Branch:
`fix/deploy-canary-rate-card-bytes`. Review `git diff origin/main...HEAD`.

## The change
- **The bug.** `phase4-coordinator/dist/deploy-pearl-vps.sh`
  `run_catalog_canary_mac_proof` hashes nine `catalog-release` files on the
  canary Mac, `rate-card.json` and `rate-card.json.sig` included. The
  exact-byte check after the pool-check loop built `expected` from only seven
  pinned files, so `actual != expected` was always true.
- **The fix.** `$STATIC_RATE_CARD_JSON` and `$STATIC_RATE_CARD_SIG` (the
  pinned `phase3-binary/dist/static` files) are passed to that check.
- **The test.** `check_deploy_static_feed_access.test.sh` used to require
  Tier-2 directly after the demand-rank sidecar, which encoded the gap. It now
  parses both sides and asserts the sets are equal.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: SECURITY / MONEY PATH

Check:
- The rate card is money-path pricing. Does requiring its exact bytes on the canary strengthen or weaken the deploy gate?
- Can the change let a deploy pass with an unverified or mismatched rate card?
- Rollback behaviour on canary failure is unchanged.

## Final prompt

# Codex audit: deploy exact-byte catalog canary expects the signed rate card (#1746)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-canary-ratecard`. Branch:
`fix/deploy-canary-rate-card-bytes`. Review `git diff origin/main...HEAD`.

## The change
- **The bug.** `phase4-coordinator/dist/deploy-pearl-vps.sh`
  `run_catalog_canary_mac_proof` hashes nine `catalog-release` files on the
  canary Mac, `rate-card.json` and `rate-card.json.sig` included. The
  exact-byte check after the pool-check loop built `expected` from only seven
  pinned files, so `actual != expected` was always true.
- **The fix.** `$STATIC_RATE_CARD_JSON` and `$STATIC_RATE_CARD_SIG` (the
  pinned `phase3-binary/dist/static` files) are passed to that check.
- **The test.** `check_deploy_static_feed_access.test.sh` used to require
  Tier-2 directly after the demand-rank sidecar, which encoded the gap. It now
  parses both sides and asserts the sets are equal.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: SECURITY / MONEY PATH

Check:
- The rate card is money-path pricing. Does requiring its exact bytes on the canary strengthen or weaken the deploy gate?
- Can the change let a deploy pass with an unverified or mismatched rate card?
- Rollback behaviour on canary failure is unchanged.

## Raw output

```text
Security/money-path audit: no findings.

- `phase4-coordinator/dist/deploy-pearl-vps.sh:4692-4693` now includes both rate-card files in the expected hash set.
- The canary proof hashes both files at `:4569-4570`; dictionary equality at `:4726` rejects missing, extra, or mismatched bytes.
- Existing release verification validates the rate-card signature before deployment (`scripts/catalog-release.py:4669-4717`).
- Canary failure still exits before commit; rollback behavior is unchanged.
- Existing focused test passed with exit 0:
  `bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh`
- `git diff --check` passed.

VERDICT: PASS


OpenAI Codex v0.156.1
--------
workdir: /Users/augstar/macprovider-canary-ratecard
model: gpt-5.6-luna
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 01a0d77c-2a5a-75f3-b236-9f7e62c9eba1
--------
user
# Codex audit: deploy exact-byte catalog canary expects the signed rate card (#1746)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-canary-ratecard`. Branch:
`fix/deploy-canary-rate-card-bytes`. Review `git diff origin/main...HEAD`.

## The change
- **The bug.** `phase4-coordinator/dist/deploy-pearl-vps.sh`
  `run_catalog_canary_mac_proof` hashes nine `catalog-release` files on the
  canary Mac, `rate-card.json` and `rate-card.json.sig` included. The
  exact-byte check after the pool-check loop built `expected` from only seven
  pinned files, so `actual != expected` was always true.
- **The fix.** `$STATIC_RATE_CARD_JSON` and `$STATIC_RATE_CARD_SIG` (the
  pinned `phase3-binary/dist/static` files) are passed to that check.
- **The test.** `check_deploy_static_feed_access.test.sh` used to require
  Tier-2 directly after the demand-rank sidecar, which encoded the gap. It now
  parses both sides and asserts the sets are equal.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: SECURITY / MONEY PATH

Check:
- The rate card is money-path pricing. Does requiring its exact bytes on the canary strengthen or weaken the deploy gate?
- Can the change let a deploy pass with an unverified or mismatched rate card?
- Rollback behaviour on canary failure is unchanged.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: failed to parse hooks config /Users/augstar/.codex/hooks.json: unknown field `state`, expected `description` or `hooks` at line 2 column 9
codex
Target: determine whether the deploy canary now enforces exact-byte equality for the signed rate card without weakening the money-path gate. I’ll inspect `origin/main...HEAD`, trace the deploy check and its existing test, then run only the relevant existing tests; no payload construction or code changes.
exec
/bin/bash -lc 'git status --short --branch && git diff --stat origin/main...HEAD && git diff --name-only origin/main...HEAD && git diff --unified=80 origin/main...HEAD -- phase4-coordinator/dist/deploy-pearl-vps.sh scripts/tests/check_deploy_static_feed_access.test.sh test 2>/dev/null' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 31ms:
phase4-coordinator/dist/deploy-pearl-vps.sh
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
diff --git a/phase4-coordinator/dist/deploy-pearl-vps.sh b/phase4-coordinator/dist/deploy-pearl-vps.sh
index 008c3925..3f00b577 100755
--- a/phase4-coordinator/dist/deploy-pearl-vps.sh
+++ b/phase4-coordinator/dist/deploy-pearl-vps.sh
@@ -4612,160 +4612,162 @@ while [ "$CANARY_ATTEMPT" -le "$CANARY_MAX_ATTEMPTS" ] && [ "$SECONDS" -lt "$CAN
     CANARY_PROOF_TIMEOUT_S="$CANARY_REMAINING_S"
   fi
   if run_catalog_canary_mac_proof "$CANARY_PROOF_TIMEOUT_S" > "$CANARY_INSTALLED_BODY" 2> "$CANARY_PROOF_ERROR"; then
     CANARY_BINDING=$(python3 - "$CANARY_INSTALLED_BODY" <<'PY'
 import json, pathlib, re, sys
 proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
 assigned_id = proof.get("assigned_id")
 row_identity = proof.get("local_status", {}).get("catalog", {}).get("row_identity")
 if not isinstance(assigned_id, str) or not assigned_id or any(ch.isspace() for ch in assigned_id):
     raise SystemExit("canary proof has no safe assigned coordinator session")
 if re.fullmatch(r"[0-9a-f]{64}", str(row_identity).lower()) is None:
     raise SystemExit("canary proof has no exact catalog row identity")
 print(assigned_id, str(row_identity).lower())
 PY
 ) || CANARY_BINDING=""
     if [ -n "$CANARY_BINDING" ]; then
       read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY <<< "$CANARY_BINDING"
       CANARY_ASSIGNED_QUERY=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CANARY_ASSIGNED_ID")
       CANARY_STATUS=$(curl --config "$CANARY_CURL_CONFIG" -sS -o "$CANARY_POOL_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 \
         "https://$DOMAIN/v1/pool/check?provider_id=$CANARY_PROVIDER_QUERY&assigned_id=$CANARY_ASSIGNED_QUERY&details=deployment" || true)
       if [ "$CANARY_STATUS" = "200" ] && python3 - \
         "$CANARY_POOL_BODY" "$CATALOG_CANARY_PROVIDER_ID" "$CANARY_ASSIGNED_ID" \
         "$AUTOTUNE_RELEASE_ID" "$AUTOTUNE_POLICY_VERSION" "$AUTOTUNE_CANDIDATE_SHA256" \
         "$AUTOTUNE_CANDIDATE_SIGNER_KEY_ID" "$CANARY_CATALOG_ROW_IDENTITY" <<'PY'
 import json, sys
 value = json.load(open(sys.argv[1], encoding="utf-8"))
 if (
     value.get("provider_id") != sys.argv[2]
     or value.get("assigned_id") != sys.argv[3]
     or value.get("buyer_serving") is not True
     or value.get("catalog_evidence_source") != "provider_reported"
     or value.get("catalog_admission_mode") != "current"
     or value.get("catalog_release_id") != sys.argv[4]
     or value.get("catalog_policy_version") != sys.argv[5]
     or value.get("catalog_candidate_sha256") != sys.argv[6]
     or value.get("catalog_signer_key_id") != sys.argv[7]
     or str(value.get("catalog_row_identity", "")).lower() != sys.argv[8]
 ):
     raise SystemExit(1)
 PY
       then
         CANARY_OK=1
         break
       fi
       CANARY_LAST_ERROR="exact session $CANARY_ASSIGNED_ID was not buyer-serving (status=$CANARY_STATUS)"
     else
       CANARY_LAST_ERROR="could not bind the live Mac session and catalog row"
     fi
   else
     CANARY_PROOF_RC=$?
     CANARY_LAST_ERROR="trusted Mac proof failed (exit=$CANARY_PROOF_RC)"
   fi
   CANARY_REMAINING_S=$((CANARY_RECOVERY_DEADLINE - SECONDS))
   if [ "$CANARY_ATTEMPT" -lt "$CANARY_MAX_ATTEMPTS" ] && [ "$CANARY_REMAINING_S" -gt 0 ]; then
     echo "  waiting for exact catalog canary recovery ($CANARY_ATTEMPT/$CANARY_MAX_ATTEMPTS): $CANARY_LAST_ERROR" >&2
     CANARY_SLEEP_S=5
     if [ "$CANARY_REMAINING_S" -lt "$CANARY_SLEEP_S" ]; then
       CANARY_SLEEP_S="$CANARY_REMAINING_S"
     fi
     sleep "$CANARY_SLEEP_S"
   fi
   CANARY_ATTEMPT=$((CANARY_ATTEMPT + 1))
 done
 rm -f "$CANARY_CURL_CONFIG"
 if [ "$CANARY_OK" != "1" ]; then
   echo "SPEC-023 canary failed after $((CANARY_ATTEMPT - 1)) full proof attempts within ${CANARY_RECOVERY_TIMEOUT_S}s: $CANARY_LAST_ERROR" >&2
   echo "  last status=$CANARY_STATUS body=$(head -c 300 "$CANARY_POOL_BODY" 2>/dev/null || true)" >&2
   exit 1
 fi
 
 if ! python3 - \
   "$CANARY_INSTALLED_BODY" \
   "$CANARY_POOL_BODY" \
   "$CATALOG_CANARY_PROVIDER_ID" \
   "$AUTOTUNE_RELEASE_MANIFEST" \
   "$AUTOTUNE_TRUSTED_KEYS" \
   "$STATIC_AUTOTUNE_JSON" \
   "$STATIC_AUTOTUNE_SIG" \
   "$STATIC_DEMAND_JSON" \
   "$STATIC_DEMAND_SIG" \
+  "$STATIC_RATE_CARD_JSON" \
+  "$STATIC_RATE_CARD_SIG" \
   "$AUTOTUNE_TIER2_JSON" <<'PY'
 import hashlib, json, pathlib, re, sys
 
 proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
 pool = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
 if proof.get("provider_id") != sys.argv[3] or not isinstance(proof.get("launchd_pid"), int):
     raise SystemExit("canary proof is not bound to the selected provider and live process")
 local_status = proof.get("local_status", {})
 local_catalog = local_status.get("catalog", {})
 local_coordinator = local_status.get("coordinator", {})
 pool_row = str(pool.get("catalog_row_identity", "")).lower()
 if (
     pool.get("provider_id") != sys.argv[3]
     or pool.get("assigned_id") != proof.get("assigned_id")
     or local_status.get("network_state") != "buyer_serving"
     or local_coordinator.get("connected") is not True
     or local_coordinator.get("session") != proof.get("assigned_id")
     or re.fullmatch(r"[0-9a-f]{64}", pool_row) is None
     or local_catalog.get("release_id") != pool.get("catalog_release_id")
     or local_catalog.get("policy_version") != pool.get("catalog_policy_version")
     or str(local_catalog.get("digest", "")).lower() != str(pool.get("catalog_candidate_sha256", "")).lower()
     or local_catalog.get("signer_key_id") != pool.get("catalog_signer_key_id")
     or str(local_catalog.get("row_identity", "")).lower() != pool_row
 ):
     raise SystemExit("canary local catalog proof is not bound to the coordinator-admitted envelope")
 actual = proof.get("files")
 if not isinstance(actual, dict):
     raise SystemExit("canary proof is missing installed file hashes")
 expected = {}
 for raw_path in sys.argv[4:]:
     path = pathlib.Path(raw_path)
     expected[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
 if actual != expected:
     missing = sorted(set(expected) - set(actual))
     extra = sorted(set(actual) - set(expected))
     changed = sorted(name for name in set(actual) & set(expected) if actual[name] != expected[name])
     raise SystemExit(f"canary catalog byte mismatch: missing={missing} extra={extra} changed={changed}")
 PY
 then
   echo "SPEC-023 canary failed: installed catalog bytes do not match the verified deployment release" >&2
   exit 1
 fi
 echo "  SPEC-023 exact-byte canary OK: selected provider's live process uses the verified catalog release"
 
 # R3+R4+R5 stats smoke check on STATS_DOMAIN.
 #
 # R5 ARCH MED-1: coordinator's `stats.enabled` defaults FALSE — when
 # it's not set or set to false, /v1/stats/* routes don't exist. Hitting
 # them blind would flag a perfectly valid stats-disabled deploy as
 # degraded. Parse `stats.enabled` from the same effective coordinator.yaml
 # the restarted service uses; gate the smoke check on it.
 STATS_ENABLED_LOCAL="$(yaml_block_value stats enabled)"
 if [ "$STATS_ENABLED_LOCAL" = "true" ]; then
   STATS_SMOKE_NONCE="${BACKUP_TS:-$(date -u +%Y%m%dT%H%M%SZ)}-$$"
   echo "  GET https://$STATS_DOMAIN/v1/stats/health?deploy_smoke=<nonce> -> expect 200"
   # R4 CODE/SEC convergent HIGH — DON'T use `STATS=$(curl ... || echo 000)`:
   # curl prints `000` to stdout AND exits non-zero on TLS/DNS failure, so
   # the `|| echo 000` appends another `000` producing `STATS=000000` and
   # silently passing the `[ "$STATS" = "000" ]` failure branch.
   if ! STATS_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$STATS_DOMAIN/v1/stats/health?deploy_smoke=$STATS_SMOKE_NONCE" 2>/dev/null); then
     STATS_STATUS="000"
   fi
   if [ "$STATS_STATUS" != "200" ]; then
     if [ "$STATS_STATUS" = "000" ]; then
       echo "  ABORT: $STATS_DOMAIN /v1/stats/health unreachable (TLS handshake or DNS failed)" >&2
     else
       echo "  ABORT: $STATS_DOMAIN /v1/stats/health returned status=$STATS_STATUS (expected 200)" >&2
     fi
     echo "  stats.enabled=true in $DEPLOY_CONFIG — public stats smoke is mandatory." >&2
     exit 9
   fi
   echo "  ok: $STATS_DOMAIN /v1/stats/health responded 200"
 
   echo "  GET https://$STATS_DOMAIN/v1/stats/overview?deploy_smoke=<nonce> with Malibu Origin -> expect 200 + CORS"
   STATS_HEADERS="$(mktemp -t macprovider-stats-headers.XXXXXX)"
   if ! STATS_OVERVIEW_STATUS=$(curl -sS -D "$STATS_HEADERS" -o /dev/null -w '%{http_code}' --max-time 10 -H "Origin: https://www.malibu.tech" "https://$STATS_DOMAIN/v1/stats/overview?deploy_smoke=$STATS_SMOKE_NONCE" 2>/dev/null); then
     STATS_OVERVIEW_STATUS="000"
   fi
   if [ "$STATS_OVERVIEW_STATUS" != "200" ]; then
     echo "  ABORT: $STATS_DOMAIN /v1/stats/overview returned status=$STATS_OVERVIEW_STATUS (expected 200)" >&2

codex
The diff is narrowly scoped: the deploy verifier now includes both static rate-card paths in the expected hash set, and the shell test changes from a one-sided Tier-2 check to set equality. I’m tracing argument ordering, file provenance, and failure handling next, including the surrounding canary proof logic.
exec
/bin/bash -lc "git diff origin/main...HEAD -- phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh && git show origin/main:phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh | sed -n '1,260p'" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
diff --git a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
index a7745788..292e99c4 100755
--- a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
+++ b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
@@ -484,9 +484,32 @@ grep -q 'value.get("catalog_evidence_source") != "provider_reported"' "$DEPLOY_S
 grep -q 'value.get("catalog_admission_mode") != "current"' "$DEPLOY_SH" ||
   fail "deploy canary must reject legacy and previous catalog admissions"
 
-grep -A1 -F '  "$STATIC_DEMAND_SIG" \' "$DEPLOY_SH" |
-  grep -qF '  "$AUTOTUNE_TIER2_JSON" <<'"'"'PY'"'"'' ||
-  fail "deploy canary expected-byte set must include the release-bound Tier-2 catalog"
+# The Mac proof hashes every name in its `names` tuple, and the exact-byte
+# check compares that dict to the basenames of its expected argv files, so
+# the two sets must be equal. Before this check the rate card and its sidecar
+# were proven but never expected, so no canary could pass.
+python3 - "$DEPLOY_SH" <<'PY' || fail "deploy canary expected-byte set must equal the file set the Mac proof hashes"
+import re, sys
+text = open(sys.argv[1], encoding="utf-8").read()
+names_block = re.search(r'\n    names = \(\n(.*?)\n    \)\n', text, re.S)
+if names_block is None:
+    raise SystemExit("canary proof names tuple not found")
+proven = set(re.findall(r'"([^"]+)"', names_block.group(1)))
+check = re.search(r'  "\$CATALOG_CANARY_PROVIDER_ID" \\\n((?:  "\$[A-Z0-9_]+" \\\n)*)  "\$([A-Z0-9_]+)" <<\'PY\'\nimport hashlib, json, pathlib, re, sys\n\nproof = json.loads', text)
+if check is None:
+    raise SystemExit("canary exact-byte check argv not found")
+variables = re.findall(r'"\$([A-Z0-9_]+)"', check.group(1)) + [check.group(2)]
+basenames = set()
+for variable in variables:
+    assignment = re.search(r'(?m)^' + variable + r'="[^"\n]*/([^/"\n]+)"$', text)
+    if assignment is None:
+        raise SystemExit(f"no path assignment for {variable}")
+    basenames.add(assignment.group(1))
+if basenames != proven:
+    raise SystemExit(f"proven={sorted(proven)} expected={sorted(basenames)}")
+if "tier2-catalog.json" not in basenames or "rate-card.json.sig" not in basenames:
+    raise SystemExit("expected set must include the Tier-2 catalog and the signed rate card")
+PY
 
 grep -q 'value.get("catalog_candidate_sha256") != sys.argv\[6\]' "$DEPLOY_SH" ||
   fail "deploy canary must match the active candidate catalog digest"
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
RECOVER_SH="$SCRIPT_DIR/../coordinator-deploy-recover.sh"
WATCHDOG_UNIT="$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-watchdog.service"
CATALOG_RUNBOOK="$SCRIPT_DIR/../../../ops/runbooks/catalog-release-provider-upgrade.md"
PEARL_RUNBOOK="$SCRIPT_DIR/../../../ops/runbooks/pearl-release-updater.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"
bash -n "$RECOVER_SH"
[ -f "$WATCHDOG_UNIT" ] || fail "remote deploy watchdog unit is missing"

grep -q '_autotune_release=\\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME' "$DEPLOY_SH" ||
  fail "deploy must stage a content-addressed immutable catalog envelope"

grep -q 'AUTOTUNE_RELEASE_CONTENT_SHA256=' "$DEPLOY_SH" &&
  grep -q 'trusted-keys.json' "$DEPLOY_SH" &&
  grep -q 'asset_digest = hashlib.sha256(path.read_bytes()).hexdigest()' "$DEPLOY_SH" ||
  fail "deploy must content-address catalog envelopes by the full catalog asset set"

grep -q 'install .*tier2-catalog.json \\$_autotune_stage/tier2-catalog.json' "$DEPLOY_SH" &&
  grep -q 'verify-directory --directory \\$_autotune_stage --tier2-public-key-file' "$DEPLOY_SH" ||
  fail "deploy must stage and authenticate Tier-2 inside the release envelope"

grep -q 'CATALOG_REMOTE_PATH_CANONICAL="/opt/macprovider/autotune/current/tier2-catalog.json"' "$DEPLOY_SH" ||
  fail "deploy must accept only the release-bound Tier-2 current path"

grep -q 'never.*writes Tier-2 through the current symlink' "$DEPLOY_SH" &&
  grep -q 'root-owned immutable release directories' "$DEPLOY_SH" ||
  fail "deploy must explain root-owned immutable staging and pointer activation"

activation_line=$(grep -nF 'ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
stage_tier2_line=$(grep -nF 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
legacy_remove_line=$(grep -nF 'rm -f /opt/macprovider/tier2-catalog.json' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
restart_line=$(grep -nF 'systemctl restart macprovider-coordinator' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$stage_tier2_line" ] && [ -n "$activation_line" ] &&
  [ "$stage_tier2_line" -lt "$activation_line" ] ||
  fail "Tier-2 must be staged in the immutable release before current activation"
[ -n "$legacy_remove_line" ] && [ -n "$restart_line" ] &&
  [ "$activation_line" -lt "$legacy_remove_line" ] && [ "$legacy_remove_line" -lt "$restart_line" ] ||
  fail "deploy must remove the independent Tier-2 bridge after current activation and before coordinator restart"

if grep -Eq 'install .* /opt/macprovider/tier2-catalog\.json|install .* \$CATALOG_REMOTE_PATH_CANONICAL' "$DEPLOY_SH"; then
  fail "successful deploy must not install Tier-2 through the independent path or current symlink"
fi

grep -q '_tier2_migration_gate_remote_script()' "$DEPLOY_SH" &&
  grep -q 'legacy Tier-2 catalog bytes differ from active autotune/current release' "$DEPLOY_SH" ||
  fail "deploy must preflight legacy Tier-2 bridge byte equality before mutation"
grep -q 'ROOT = "/opt/macprovider"' "$DEPLOY_SH" &&
  ! grep -q 'MACPROVIDER_ROOT' "$DEPLOY_SH" &&
  grep -q 'O_NOFOLLOW' "$DEPLOY_SH" &&
  grep -q 'dir_fd=' "$DEPLOY_SH" &&
  grep -q 'info.st_nlink != 1' "$DEPLOY_SH" ||
  fail "Tier-2 migration gate must be fixed-root and no-follow/dirfd hardened"
grep -q 'unsafe transient autotune/current.next exists before deploy activation' "$DEPLOY_SH" &&
  grep -q 'unsafe autotune/.previous-target contents before Tier-2 migration' "$DEPLOY_SH" ||
  fail "Tier-2 migration gate must reject unsafe current.next and .previous-target state"
# #1688: scripts/autotune_window.py is the single .previous-target writer
# (no-follow O_EXCL temp + atomic rename live there); deploy logs the plan and
# applies it against the target it just read, before the current swap.
window_plan='python3 -I $DEPLOY_TMP/scripts/autotune_window.py plan --root \"\$_catalog_root\" --incoming releases/$AUTOTUNE_RELEASE_DIR_NAME'
window_apply='python3 -I $DEPLOY_TMP/scripts/autotune_window.py apply --root \"\$_catalog_root\" --incoming releases/$AUTOTUNE_RELEASE_DIR_NAME --expect-current \"\$_previous\"'
plan_line=$(grep -nF "$window_plan" "$DEPLOY_SH" | cut -d: -f1)
apply_line=$(grep -nF "$window_apply" "$DEPLOY_SH" | cut -d: -f1)
swap_line=$(grep -nF 'mv -Tf \"\$_catalog_root/current.next\" \"\$_catalog_root/current\"' "$DEPLOY_SH" | cut -d: -f1)
deploy_tmp_rm_line=$(grep -nF -x '  rm -rf $DEPLOY_TMP' "$DEPLOY_SH" | cut -d: -f1)
[ -n "$plan_line" ] && [ -n "$apply_line" ] && [ -n "$swap_line" ] && [ -n "$deploy_tmp_rm_line" ] &&
  [ "$plan_line" -lt "$apply_line" ] && [ "$apply_line" -lt "$swap_line" ] && [ "$swap_line" -lt "$deploy_tmp_rm_line" ] ||
  fail "deploy must log then apply the autotune_window.py window before the current swap, keeping DEPLOY_TMP until after it"
if grep -Eq "os\.rename\(tmp_name, '\.previous-target'|\.previous-target\.tmp\.|> *[^ ]*\.previous-target" "$DEPLOY_SH"; then
  fail "deploy keeps an inline .previous-target writer; use scripts/autotune_window.py"
fi

grep -q 'sudo -u macprovider test -r /opt/macprovider/autotune/current/autotune-candidates.json' "$DEPLOY_SH" ||
  fail "deploy smoke must verify macprovider can read autotune feeds"
grep -q 'sudo -u macprovider test -r /opt/macprovider/autotune/current/rate-card.json' "$DEPLOY_SH" ||
  fail "deploy smoke must verify macprovider can read the signed rate-card feed"

grep -q 'mv -Tf.*current.next.*current' "$DEPLOY_SH" ||
  fail "deploy must atomically activate the verified release"

grep -q 'restore_regular had-coordinator coordinator' "$RECOVER_SH" ||
  fail "catalog rollback must restore the previous coordinator binary"

grep -q 'restore_regular had-config coordinator.yaml' "$RECOVER_SH" ||
  fail "catalog rollback must restore the previous coordinator config"
grep -q 'snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay' "$DEPLOY_SH" &&
  grep -q 'restore_regular had-overlay coordinator.pearl-overlays.yaml' "$RECOVER_SH" ||
  fail "catalog rollback must restore the previous coordinator overlay"
grep -q 'overlay-config-backup-name' "$DEPLOY_SH" &&
  grep -q 'overlay-config-backup-name' "$RECOVER_SH" ||
  fail "catalog rollback must preserve overlay dated backup collisions"

grep -q 'COORDINATOR_DEPLOY_ARMED=1' "$DEPLOY_SH" ||
  fail "deploy must arm rollback before replacing live coordinator files"

grep -q '_rollback_stage=.*stage' "$DEPLOY_SH" ||
  fail "deploy must construct rollback state outside the published snapshot path"

grep -q 'touch.*_rollback_stage/complete' "$DEPLOY_SH" ||
  fail "deploy must mark a fully constructed rollback snapshot"

grep -q 'mv.*_rollback_stage.*_rollback' "$DEPLOY_SH" ||
  fail "deploy must atomically publish the complete rollback snapshot"

grep -q 'restore_link_or_file had-service-unit macprovider-coordinator.service' "$RECOVER_SH" ||
  fail "coordinator rollback must restore the previous systemd unit"

grep -q 'release-was-absent' "$RECOVER_SH" ||
  fail "coordinator rollback must remove a newly staged uncommitted release"

grep -q 'restore_link_or_file had-wants-link' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve exact service enablement or masking state"

grep -q 'had-recovery-helper' "$DEPLOY_SH" && grep -q 'had-recovery-helper' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve its durable recovery guard"

grep -q 'had-previous-target' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve the prior catalog bridge state"

grep -q 'had-tier2-catalog' "$DEPLOY_SH" && grep -q 'restore_regular had-tier2-catalog' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve the exact Tier-2 signed catalog"

grep -q 'had-coordinator-cli' "$DEPLOY_SH" && grep -q 'restore_regular had-coordinator-cli' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve the matching operator CLI"

for marker in had-stats-inventory-binary had-stats-billing-binary had-stats-hardware-binary \
  had-stats-inventory-service had-stats-inventory-timer \
  had-stats-billing-service had-stats-billing-timer \
  had-stats-hardware-service had-stats-hardware-timer; do
  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
    fail "coordinator rollback coverage missing for $marker"
done

for marker in had-nginx-stats-shared had-nginx-stats-security-headers \
  had-nginx-stats-cors-429 had-nginx-stats-proxy-public \
  had-nginx-stats-proxy-partner had-nginx-coordinator-site \
  had-nginx-stats-site had-nginx-coordinator-enabled had-nginx-stats-enabled; do
  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
    fail "nginx rollback coverage missing for $marker"
done

grep -q 'snapshot_acl /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" &&
  grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
  fail "request-log ACL changes must be captured and restored"

grep -q 'try-reload-or-restart nginx' "$RECOVER_SH" ||
  fail "rollback must validate and activate the restored nginx graph"

freeze_line=$(grep -nF '# Freeze sidecar execution for the release window.' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
binary_install_line=$(grep -nF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
sidecar_activate_line=$(grep -nF '# Sidecars remain frozen until every coordinator/catalog/canary check has' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
commit_line=$(grep -nF 'touch /opt/macprovider/.coordinator-deploy-rollback/committed' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$freeze_line" ] && [ -n "$binary_install_line" ] && [ "$freeze_line" -lt "$binary_install_line" ] ||
  fail "stats sidecars must freeze before transaction binaries are replaced"
[ -n "$sidecar_activate_line" ] && [ -n "$commit_line" ] && [ "$sidecar_activate_line" -lt "$commit_line" ] ||
  fail "stats sidecars must reactivate only as the final pre-commit mutation"

grep -q 'flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" ||
  fail "deploy must hold a controller-lifetime remote lock"

grep -q 'flock -n /run/lock/macprovider-pearl-updater.lock flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" &&
  grep -q 'unsafe global Pearl deployment lock' "$DEPLOY_SH" ||
  fail "direct deploy and signed updater must share one validated global mutation lock"

grep -q 'cmp -s \$DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator' "$DEPLOY_SH" &&
  ! grep -q 'install -o root -g macprovider -m 0750 \$DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator' "$DEPLOY_SH" ||
  fail "direct catalog deploy must not replace one half of the signed coordinator/gateway pair"

grep -qF 'tier2_require_hash_verified()' "$DEPLOY_SH" &&
  grep -qF 'tracked-config deploy cannot change tier2.require_hash_verified' "$DEPLOY_SH" &&
  grep -qF 'if [ "$CONFIG_MODE" = "apply-tracked" ]; then' "$DEPLOY_SH" ||
  fail "tracked-config deploy must hard-block every Tier-2 enforcement state transition"
enforcement_mode_line=$(grep -nF 'if [ "$CONFIG_MODE" = "apply-tracked" ]; then' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
enforcement_guard_line=$(grep -nF 'tracked-config deploy cannot change tier2.require_hash_verified' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
apply_tracked_drift_line=$(grep -nF 'CONFIG_MODE=apply-tracked may install tracked coordinator.yaml only when it already matches live' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$enforcement_mode_line" ] && [ -n "$enforcement_guard_line" ] && [ -n "$apply_tracked_drift_line" ] &&
  [ "$enforcement_mode_line" -lt "$enforcement_guard_line" ] &&
  [ "$enforcement_guard_line" -lt "$apply_tracked_drift_line" ] ||
  fail "Tier-2 enforcement transition guard must run before tracked-config drift handling"
tier2_parser_tmp="$(mktemp)"
awk '/^tier2_require_hash_verified\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" >"$tier2_parser_tmp"
# shellcheck disable=SC1090
. "$tier2_parser_tmp"
rm -f "$tier2_parser_tmp"
[ "$(printf 'tier2:\n  require_hash_verified: false\npool:\n' | tier2_require_hash_verified)" = "false" ] ||
  fail "Tier-2 transition parser must read the live false posture"
[ "$(printf 'tier2:\n  require_hash_verified: true\npool:\n' | tier2_require_hash_verified)" = "true" ] ||
  fail "Tier-2 transition parser must read the candidate true posture"
[ "$(printf 'tier2:\n    require_hash_verified: true\npool:\n' | tier2_require_hash_verified)" = "true" ] ||
  fail "Tier-2 transition parser must read valid four-space YAML"
if printf 'tier2:\n  require_hash_verified: false\n  require_hash_verified: true\n' |
  tier2_require_hash_verified >/dev/null; then
  fail "Tier-2 transition parser must reject duplicate enforcement keys"
fi
if printf 'tier2:\n  nested:\n    require_hash_verified: true\n' |
  tier2_require_hash_verified >/dev/null; then
  fail "Tier-2 transition parser must reject a missing direct enforcement key"
fi

grep -qF 'tier2-enforcement-transaction.json' "$DEPLOY_SH" ||
  fail "direct deploy must refuse an active Tier-2 enforcement transaction"

grep -q 'O_NOFOLLOW' "$DEPLOY_SH" && grep -q 'info.st_nlink != 1' "$DEPLOY_SH" &&
  grep -q 'unsafe coordinator deploy lock' "$DEPLOY_SH" ||
  fail "deploy lock setup must reject symlinks, hardlinks, and unsafe ownership/modes"

grep -q 'sidecar unit did not stop:' "$DEPLOY_SH" ||
  fail "deploy must prove every loaded sidecar is inactive before replacement"

grep -q 'recover interrupted coordinator deploy' "$DEPLOY_SH" ||
  fail "deploy must recover an interrupted transaction before reading live state"

grep -q 'CRITICAL: coordinator deploy rollback failed' "$DEPLOY_SH" ||
  fail "deploy must report rollback failure distinctly"

grep -q 'systemctl start --no-block macprovider-coordinator-deploy-watchdog.service' "$DEPLOY_SH" ||
  fail "deploy must arm a remote watchdog that survives controller loss"

[ "$(grep -c 'coordinator-deploy-recover --recover-under-global' "$DEPLOY_SH")" -eq 2 ] ||
  fail "controller-held recovery must not recursively reacquire the global deploy lock"

grep -q 'TimeoutStartSec=infinity' "$WATCHDOG_UNIT" &&
  grep -q 'ExecStart=/opt/macprovider/coordinator-deploy-recover --recover' "$WATCHDOG_UNIT" &&
  grep -q 'GLOBAL_LOCK_FILE=' "$RECOVER_SH" &&
  grep -q '\$FLOCK 7' "$RECOVER_SH" &&
  grep -q '\$FLOCK 9' "$RECOVER_SH" &&
  grep -q '\$FLOCK 8' "$RECOVER_SH" ||
  fail "remote watchdog recovery must own the global, deploy, and operation locks in order"

grep -q 'flock -s 8' "$DEPLOY_SH" ||
  fail "live deploy mutations must hold the shared operation barrier"

armed_line=$(grep -nF 'touch "$DEPLOY_LOCK_WATCHDOG_ARMED"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
holder_line=$(grep -nF 'DEPLOY_LOCK_PID=$!' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$armed_line" ] && [ -n "$holder_line" ] && [ "$armed_line" -lt "$holder_line" ] ||
  fail "local lock-loss watchdog must be armed before the holder can exit"

grep -q 'kill -TERM.*DEPLOY_CONTROLLER_PID' "$DEPLOY_SH" ||
  fail "lock loss must fail-stop the controller"

grep -q '\["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-F", "Dfin"\]' "$DEPLOY_SH" &&
  grep -q 'text_device == binary_info.st_dev' "$DEPLOY_SH" &&
  grep -q 'text_inode == binary_info.st_ino' "$DEPLOY_SH" &&
  ! grep -q 'process_info = os.stat(process_path' "$DEPLOY_SH" ||
  fail "canary executable proof must compare the running text vnode, not the replaced pathname"

grep -q 'Requires=macprovider-coordinator-deploy-recovery.service' "$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-guard.conf" ||
  fail "coordinator startup must recover orphaned deploy transactions"

grep -q 'ExecStart=/opt/macprovider/coordinator-deploy-recover --pre-start' "$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-recovery.service" ||
  fail "coordinator startup recovery must run as a separate root oneshot"

exec
/bin/bash -lc "rg -n -C 35 'run_catalog_canary_mac_proof|STATIC_RATE_CARD|exact-byte canary|canary catalog byte mismatch' phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase3-binary phase4-coordinator specs docs 2>/dev/null" in /Users/augstar/macprovider-canary-ratecard
exec
/bin/bash -lc 'git diff origin/main...HEAD --check && git log --oneline --decorate -8 origin/main..HEAD' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 43ms:
--
phase4-coordinator/dist/deploy-pearl-vps.sh-639-STATS_INVENTORY_TIMER="$PINNED_DIST_DIR/stats-inventory-sync.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh-640-STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-641-STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh-642-STATS_HARDWARE_VERIFIER_SERVICE="$PINNED_DIST_DIR/stats-hardware-verifier.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-643-STATS_HARDWARE_VERIFIER_TIMER="$PINNED_DIST_DIR/stats-hardware-verifier.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh-644-NGINX_SITE="$PINNED_DIST_DIR/nginx-coordinator.malibu.tech.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-645-TCP_SYSCTL="$PINNED_DIST_DIR/sysctl.d/99-macprovider-tcp.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-646-TCP_BBR_MODULES_LOAD="$PINNED_DIST_DIR/modules-load.d/tcp_bbr.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-647-# SPEC-017 v0.1.8 Step 4.B — additional nginx artifacts the
phase4-coordinator/dist/deploy-pearl-vps.sh-648-# coordinator vhost depends on:
phase4-coordinator/dist/deploy-pearl-vps.sh-649-#   - stats-shared.conf is the http-context snippet declaring the
phase4-coordinator/dist/deploy-pearl-vps.sh-650-#     `$public_rl_key` map, the per-endpoint `stats_*` zones, the
phase4-coordinator/dist/deploy-pearl-vps.sh-651-#     `stats_public` cache, and the `stats_redacted` log format.
phase4-coordinator/dist/deploy-pearl-vps.sh-652-#     Both the coordinator vhost and the stats vhost reference
phase4-coordinator/dist/deploy-pearl-vps.sh-653-#     these names; without the snippet installed first, `nginx -t`
phase4-coordinator/dist/deploy-pearl-vps.sh-654-#     fails (Step 4.B CODE r1 CRITICAL).
phase4-coordinator/dist/deploy-pearl-vps.sh-655-#   - nginx-stats.malibu.tech.conf is the standalone
phase4-coordinator/dist/deploy-pearl-vps.sh-656-#     `stats.malibu.tech` vhost.
phase4-coordinator/dist/deploy-pearl-vps.sh-657-# Both files MUST exist before this deploy proceeds; they are
phase4-coordinator/dist/deploy-pearl-vps.sh-658-# installed below alongside the coordinator vhost.
phase4-coordinator/dist/deploy-pearl-vps.sh-659-NGINX_STATS_SHARED="$PINNED_DIST_DIR/nginx-snippets/stats-shared.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-660-NGINX_STATS_SECHEADERS="$PINNED_DIST_DIR/nginx-snippets/stats-security-headers.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-661-NGINX_STATS_CORS_429="$PINNED_DIST_DIR/nginx-snippets/cors-429.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-662-NGINX_STATS_PROXY_PUBLIC="$PINNED_DIST_DIR/nginx-snippets/stats-proxy-public.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-663-NGINX_STATS_PROXY_PARTNER="$PINNED_DIST_DIR/nginx-snippets/stats-proxy-partner.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-664-NGINX_STATS_SITE="$PINNED_DIST_DIR/nginx-stats.malibu.tech.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-665-# SPEC-023 signed recommendation feeds served on the buyer mux at
phase4-coordinator/dist/deploy-pearl-vps.sh-666-# /v1/rate-card, /v1/demand-rank and /v1/autotune-candidates (+ .sig sidecars).
phase4-coordinator/dist/deploy-pearl-vps.sh-667-# Files live in phase3-binary/dist/static/ in the repo. Deploy installs
phase4-coordinator/dist/deploy-pearl-vps.sh-668-# them into /opt/macprovider/autotune/ for coordinator startup load.
phase4-coordinator/dist/deploy-pearl-vps.sh-669-STATIC_FEEDS_DIR="$PINNED_STATIC_FEEDS_DIR"
phase4-coordinator/dist/deploy-pearl-vps.sh-670-STATIC_DEMAND_JSON="$STATIC_FEEDS_DIR/demand-rank.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-671-STATIC_DEMAND_SIG="$STATIC_FEEDS_DIR/demand-rank.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-672-STATIC_AUTOTUNE_JSON="$STATIC_FEEDS_DIR/autotune-candidates.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-673-STATIC_AUTOTUNE_SIG="$STATIC_FEEDS_DIR/autotune-candidates.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh:674:STATIC_RATE_CARD_JSON="$STATIC_FEEDS_DIR/rate-card.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:675:STATIC_RATE_CARD_SIG="$STATIC_FEEDS_DIR/rate-card.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-676-STATIC_ARTIFACTS_JSON="$STATIC_FEEDS_DIR/autotune-artifacts.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-677-STATIC_ARTIFACTS_SIG="$STATIC_FEEDS_DIR/autotune-artifacts.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-678-AUTOTUNE_RELEASE_MANIFEST="$PINNED_AUTOTUNE_DIR/release.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-679-AUTOTUNE_TRUSTED_KEYS="$PINNED_AUTOTUNE_DIR/trusted-keys.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-680-AUTOTUNE_TIER2_JSON="$PINNED_AUTOTUNE_DIR/tier2-catalog.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-681-AUTOTUNE_RELEASE_VERIFY="$PINNED_SCRIPTS_DIR/catalog-release.py"
phase4-coordinator/dist/deploy-pearl-vps.sh-682-AUTOTUNE_TIER2_VERIFIER="$PINNED_SCRIPTS_DIR/sign-catalog.go"
phase4-coordinator/dist/deploy-pearl-vps.sh-683-CATALOG_SOURCE="${CATALOG_SOURCE:-$AUTOTUNE_TIER2_JSON}"
phase4-coordinator/dist/deploy-pearl-vps.sh-684-
phase4-coordinator/dist/deploy-pearl-vps.sh-685-# Repository-level verification reads the complete source tree and Git history.
phase4-coordinator/dist/deploy-pearl-vps.sh-686-# Execute immutable bytes archived from the signed release commit, while giving
phase4-coordinator/dist/deploy-pearl-vps.sh-687-# the verifier read-only object access for the ledger comparison against that
phase4-coordinator/dist/deploy-pearl-vps.sh-688-# commit's direct parent. Isolated Python plus the pinned base ref prevent the
phase4-coordinator/dist/deploy-pearl-vps.sh-689-# caller's worktree, import path, or CATALOG_RELEASE_BASE_REF from weakening the
phase4-coordinator/dist/deploy-pearl-vps.sh-690-# gate. The smaller verifier bundle remains authoritative for staged and remote
phase4-coordinator/dist/deploy-pearl-vps.sh-691-# verify-directory checks.
phase4-coordinator/dist/deploy-pearl-vps.sh-692-if [ "$DRY_RUN_LOCAL" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-693-  python3 -I "$PINNED_REPOSITORY_DIR/scripts/catalog-release.py" verify
phase4-coordinator/dist/deploy-pearl-vps.sh-694-else
phase4-coordinator/dist/deploy-pearl-vps.sh-695-  PINNED_GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"
phase4-coordinator/dist/deploy-pearl-vps.sh-696-  env -u OPENSSL_BIN -u MACPROVIDER_INTAKE_AUDIT_DIR \
phase4-coordinator/dist/deploy-pearl-vps.sh-697-    GIT_DIR="$PINNED_GIT_DIR" \
phase4-coordinator/dist/deploy-pearl-vps.sh-698-    GIT_NO_REPLACE_OBJECTS=1 \
phase4-coordinator/dist/deploy-pearl-vps.sh-699-    CATALOG_RELEASE_BASE_REF="$COORDINATOR_RELEASE_COMMIT^" \
phase4-coordinator/dist/deploy-pearl-vps.sh-700-    python3 -I "$PINNED_REPOSITORY_DIR/scripts/catalog-release.py" verify
phase4-coordinator/dist/deploy-pearl-vps.sh-701-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-702-# SPEC-023 §3.7.8 Stage A: release.json decides whether the artifact feed and
phase4-coordinator/dist/deploy-pearl-vps.sh-703-# its sidecar are members of the immutable release envelope. verify-directory
phase4-coordinator/dist/deploy-pearl-vps.sh-704-# rejects a five-feed release.json beside nine files (and nine-file bytes
phase4-coordinator/dist/deploy-pearl-vps.sh-705-# beside a stray pair), so presence must follow the binding exactly, and a
phase4-coordinator/dist/deploy-pearl-vps.sh-706-# bound release whose feed is missing from the checkout aborts here.
phase4-coordinator/dist/deploy-pearl-vps.sh-707-AUTOTUNE_ARTIFACT_BOUND="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-708-import json, pathlib, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-709-feeds = json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]
phase4-coordinator/dist/deploy-pearl-vps.sh-710-print("bound" if "autotune-artifacts.json" in feeds else "unbound")
--
phase4-coordinator/dist/deploy-pearl-vps.sh-721-  AUTOTUNE_ARTIFACT_CONTENT_SIG="$STATIC_ARTIFACTS_SIG"
phase4-coordinator/dist/deploy-pearl-vps.sh-722-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-723-AUTOTUNE_RELEASE_ID="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-724-import json, pathlib, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-725-print(json.loads(pathlib.Path(sys.argv[1]).read_text())["release_id"])
phase4-coordinator/dist/deploy-pearl-vps.sh-726-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-727-)"
phase4-coordinator/dist/deploy-pearl-vps.sh-728-AUTOTUNE_POLICY_VERSION="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-729-import json, pathlib, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-730-print(json.loads(pathlib.Path(sys.argv[1]).read_text())["policy_version"])
phase4-coordinator/dist/deploy-pearl-vps.sh-731-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-732-)"
phase4-coordinator/dist/deploy-pearl-vps.sh-733-AUTOTUNE_CANDIDATE_SHA256="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-734-import json, pathlib, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-735-print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["autotune-candidates.json"]["sha256"])
phase4-coordinator/dist/deploy-pearl-vps.sh-736-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-737-)"
phase4-coordinator/dist/deploy-pearl-vps.sh-738-AUTOTUNE_CANDIDATE_SIGNER_KEY_ID="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-739-import json, pathlib, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-740-print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["autotune-candidates.json"]["signer_key_id"])
phase4-coordinator/dist/deploy-pearl-vps.sh-741-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-742-)"
phase4-coordinator/dist/deploy-pearl-vps.sh-743-AUTOTUNE_TIER2_SHA256="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-744-import json, pathlib, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-745-print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["tier2-catalog.json"]["sha256"])
phase4-coordinator/dist/deploy-pearl-vps.sh-746-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-747-)"
phase4-coordinator/dist/deploy-pearl-vps.sh-748-AUTOTUNE_RELEASE_CONTENT_SHA256="$(python3 - \
phase4-coordinator/dist/deploy-pearl-vps.sh-749-  "$AUTOTUNE_RELEASE_MANIFEST" \
phase4-coordinator/dist/deploy-pearl-vps.sh-750-  "$AUTOTUNE_TRUSTED_KEYS" \
phase4-coordinator/dist/deploy-pearl-vps.sh-751-  "$AUTOTUNE_TIER2_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-752-  "$STATIC_AUTOTUNE_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-753-  "$STATIC_AUTOTUNE_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh-754-  "$STATIC_DEMAND_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-755-  "$STATIC_DEMAND_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh:756:  "$STATIC_RATE_CARD_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh:757:  "$STATIC_RATE_CARD_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh-758-  "$AUTOTUNE_ARTIFACT_CONTENT_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-759-  "$AUTOTUNE_ARTIFACT_CONTENT_SIG" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-760-import hashlib
phase4-coordinator/dist/deploy-pearl-vps.sh-761-import pathlib
phase4-coordinator/dist/deploy-pearl-vps.sh-762-import sys
phase4-coordinator/dist/deploy-pearl-vps.sh-763-
phase4-coordinator/dist/deploy-pearl-vps.sh-764-assets = (
phase4-coordinator/dist/deploy-pearl-vps.sh-765-    ("release.json", pathlib.Path(sys.argv[1])),
phase4-coordinator/dist/deploy-pearl-vps.sh-766-    ("trusted-keys.json", pathlib.Path(sys.argv[2])),
phase4-coordinator/dist/deploy-pearl-vps.sh-767-    ("tier2-catalog.json", pathlib.Path(sys.argv[3])),
phase4-coordinator/dist/deploy-pearl-vps.sh-768-    ("autotune-candidates.json", pathlib.Path(sys.argv[4])),
phase4-coordinator/dist/deploy-pearl-vps.sh-769-    ("autotune-candidates.json.sig", pathlib.Path(sys.argv[5])),
phase4-coordinator/dist/deploy-pearl-vps.sh-770-    ("demand-rank.json", pathlib.Path(sys.argv[6])),
phase4-coordinator/dist/deploy-pearl-vps.sh-771-    ("demand-rank.json.sig", pathlib.Path(sys.argv[7])),
phase4-coordinator/dist/deploy-pearl-vps.sh-772-    ("rate-card.json", pathlib.Path(sys.argv[8])),
phase4-coordinator/dist/deploy-pearl-vps.sh-773-    ("rate-card.json.sig", pathlib.Path(sys.argv[9])),
phase4-coordinator/dist/deploy-pearl-vps.sh-774-)
phase4-coordinator/dist/deploy-pearl-vps.sh-775-# Artifact-bound release (SPEC-023 §3.7.8): the pair is part of the
phase4-coordinator/dist/deploy-pearl-vps.sh-776-# content-addressed envelope; both arguments are empty otherwise.
phase4-coordinator/dist/deploy-pearl-vps.sh-777-if sys.argv[10] or sys.argv[11]:
phase4-coordinator/dist/deploy-pearl-vps.sh-778-    assets += (
phase4-coordinator/dist/deploy-pearl-vps.sh-779-        ("autotune-artifacts.json", pathlib.Path(sys.argv[10])),
phase4-coordinator/dist/deploy-pearl-vps.sh-780-        ("autotune-artifacts.json.sig", pathlib.Path(sys.argv[11])),
phase4-coordinator/dist/deploy-pearl-vps.sh-781-    )
phase4-coordinator/dist/deploy-pearl-vps.sh-782-digest = hashlib.sha256()
phase4-coordinator/dist/deploy-pearl-vps.sh-783-for name, path in assets:
phase4-coordinator/dist/deploy-pearl-vps.sh-784-    asset_digest = hashlib.sha256(path.read_bytes()).hexdigest()
phase4-coordinator/dist/deploy-pearl-vps.sh-785-    digest.update(name.encode("utf-8"))
phase4-coordinator/dist/deploy-pearl-vps.sh-786-    digest.update(b"\0")
phase4-coordinator/dist/deploy-pearl-vps.sh-787-    digest.update(asset_digest.encode("ascii"))
phase4-coordinator/dist/deploy-pearl-vps.sh-788-    digest.update(b"\n")
phase4-coordinator/dist/deploy-pearl-vps.sh-789-print(digest.hexdigest())
phase4-coordinator/dist/deploy-pearl-vps.sh-790-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-791-)"
phase4-coordinator/dist/deploy-pearl-vps.sh-792-if ! printf '%s' "$AUTOTUNE_RELEASE_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
--
phase4-coordinator/dist/deploy-pearl-vps.sh-837-  case "$CATALOG_WINDOW_OVERRIDE_REASON" in
phase4-coordinator/dist/deploy-pearl-vps.sh-838-    *$'\n'*|*$'\r'*)
phase4-coordinator/dist/deploy-pearl-vps.sh-839-      echo "aborting deploy: CATALOG_WINDOW_OVERRIDE_REASON must be a single line" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-840-      exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-841-      ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-842-  esac
phase4-coordinator/dist/deploy-pearl-vps.sh-843-  if ! printf '%s' "$CATALOG_WINDOW_OVERRIDE_REASON" | LC_ALL=C grep -Eq '^[ -~]{1,200}$'; then
phase4-coordinator/dist/deploy-pearl-vps.sh-844-    echo "aborting deploy: CATALOG_WINDOW_OVERRIDE_REASON must be 1-200 printable ASCII characters" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-845-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-846-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-847-  CATALOG_WINDOW_OVERRIDE_B64="$(printf '%s' "$CATALOG_WINDOW_OVERRIDE_REASON" | base64 | tr -d '\n')"
phase4-coordinator/dist/deploy-pearl-vps.sh-848-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-849-# Appends one catalog override record to Pearl's root-only 0600 JSONL audit
phase4-coordinator/dist/deploy-pearl-vps.sh-850-# log (O_APPEND|O_NOFOLLOW, regular file only, fsync). $1 = base64 of the
phase4-coordinator/dist/deploy-pearl-vps.sh-851-# record JSON object without "ts"; $2 = fixed logger message. The append
phase4-coordinator/dist/deploy-pearl-vps.sh-852-# primitive itself lives in scripts/lib/catalog-window-override.sh, shared
phase4-coordinator/dist/deploy-pearl-vps.sh-853-# with the catalog-content lane.
phase4-coordinator/dist/deploy-pearl-vps.sh-854-_append_catalog_window_override() {
phase4-coordinator/dist/deploy-pearl-vps.sh-855-  $SSH "$(cwo_override_remote_command "$1" "$2" macprovider-deploy)"
phase4-coordinator/dist/deploy-pearl-vps.sh-856-}
phase4-coordinator/dist/deploy-pearl-vps.sh-857-
phase4-coordinator/dist/deploy-pearl-vps.sh-858-# coordinator-cli is required ALONGSIDE the daemon (SPEC-003 v0.8.3
phase4-coordinator/dist/deploy-pearl-vps.sh-859-# FR-C9.4 strict-reject path still requires `coordinator-cli
phase4-coordinator/dist/deploy-pearl-vps.sh-860-# revoke-token` for the used-token-persist-failure case; routine
phase4-coordinator/dist/deploy-pearl-vps.sh-861-# prune-tokens / list-tokens also belong on Pearl). Production deploys
phase4-coordinator/dist/deploy-pearl-vps.sh-862-# stage it and the stats sidecars from the verified signed release above;
phase4-coordinator/dist/deploy-pearl-vps.sh-863-# DRY_RUN_LOCAL reads dist/. Fail closed — do NOT silently deploy with a
phase4-coordinator/dist/deploy-pearl-vps.sh-864-# stale CLI.
phase4-coordinator/dist/deploy-pearl-vps.sh-865-for f in "$BINARY" "$CLI_BINARY" "$STATS_INVENTORY_BINARY" "$STATS_BILLING_MIRROR_BINARY" "$STATS_HARDWARE_VERIFIER_BINARY" \
phase4-coordinator/dist/deploy-pearl-vps.sh-866-         "$CONFIG" "$SERVICE" "$DEPLOY_RECOVER" "$DEPLOY_GUARD" "$DEPLOY_RECOVERY_SERVICE" "$DEPLOY_WATCHDOG_SERVICE" "$STATS_INVENTORY_SERVICE" "$STATS_INVENTORY_TIMER" \
phase4-coordinator/dist/deploy-pearl-vps.sh-867-         "$STATS_BILLING_MIRROR_SERVICE" "$STATS_BILLING_MIRROR_TIMER" \
phase4-coordinator/dist/deploy-pearl-vps.sh-868-         "$STATS_HARDWARE_VERIFIER_SERVICE" "$STATS_HARDWARE_VERIFIER_TIMER" "$NGINX_SITE" \
phase4-coordinator/dist/deploy-pearl-vps.sh-869-         "$NGINX_STATS_SHARED" "$NGINX_STATS_SECHEADERS" "$NGINX_STATS_SITE" \
phase4-coordinator/dist/deploy-pearl-vps.sh-870-         "$STATIC_DEMAND_JSON" "$STATIC_DEMAND_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh-871-         "$STATIC_AUTOTUNE_JSON" "$STATIC_AUTOTUNE_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh:872:         "$STATIC_RATE_CARD_JSON" "$STATIC_RATE_CARD_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh-873-         "$AUTOTUNE_RELEASE_MANIFEST" "$AUTOTUNE_TRUSTED_KEYS" "$AUTOTUNE_TIER2_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-874-         "$AUTOTUNE_RELEASE_VERIFY" "$AUTOTUNE_TIER2_VERIFIER"; do
phase4-coordinator/dist/deploy-pearl-vps.sh-875-  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-876-done
phase4-coordinator/dist/deploy-pearl-vps.sh-877-
phase4-coordinator/dist/deploy-pearl-vps.sh-878-# Issue #244 R1+R2 — replace the defensive sed (silently re-rewriting
phase4-coordinator/dist/deploy-pearl-vps.sh-879-# commented cert directives) with a pre-upload assertion that the dist
phase4-coordinator/dist/deploy-pearl-vps.sh-880-# vhosts ship with ACTIVE ssl_certificate + ssl_certificate_key
phase4-coordinator/dist/deploy-pearl-vps.sh-881-# directives AND server_name matching the deploy hostname. The dist
phase4-coordinator/dist/deploy-pearl-vps.sh-882-# confs are the single source of truth; the deploy script no longer
phase4-coordinator/dist/deploy-pearl-vps.sh-883-# "fixes up" the templates. If the assertion fails, the operator must
phase4-coordinator/dist/deploy-pearl-vps.sh-884-# edit the dist conf in place.
phase4-coordinator/dist/deploy-pearl-vps.sh-885-#
phase4-coordinator/dist/deploy-pearl-vps.sh-886-# R2 ARCH MEDIUM-2: also assert server_name + /etc/letsencrypt/live/<d>/
phase4-coordinator/dist/deploy-pearl-vps.sh-887-# paths in each template match the expected hostname, so an env-only
phase4-coordinator/dist/deploy-pearl-vps.sh-888-# DOMAIN override paired with a stale template can't issue a cert for
phase4-coordinator/dist/deploy-pearl-vps.sh-889-# one hostname and install a vhost for another.
phase4-coordinator/dist/deploy-pearl-vps.sh-890-_assert_vhost_template() {
phase4-coordinator/dist/deploy-pearl-vps.sh-891-  local f="$1" expected_host="$2"
phase4-coordinator/dist/deploy-pearl-vps.sh-892-  local host_esc="${expected_host//./\\.}"
phase4-coordinator/dist/deploy-pearl-vps.sh-893-  # R3 ARCH MED: anchor the active cert directives to the EXPECTED
phase4-coordinator/dist/deploy-pearl-vps.sh-894-  # hostname's letsencrypt path — not just any letsencrypt path. A
phase4-coordinator/dist/deploy-pearl-vps.sh-895-  # wrong active cert + commented expected cert would otherwise pass.
phase4-coordinator/dist/deploy-pearl-vps.sh-896-  if ! grep -Eq "^[[:space:]]*ssl_certificate[[:space:]]+/etc/letsencrypt/live/${host_esc}/fullchain\\.pem;" "$f"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-897-    echo "aborting deploy: $f is missing an active 'ssl_certificate /etc/letsencrypt/live/$expected_host/fullchain.pem;' directive" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-898-    echo "  Edit the file to uncomment the cert path for this hostname; the deploy script no longer rewrites it." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-899-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-900-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-901-  if ! grep -Eq "^[[:space:]]*ssl_certificate_key[[:space:]]+/etc/letsencrypt/live/${host_esc}/privkey\\.pem;" "$f"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-902-    echo "aborting deploy: $f is missing an active 'ssl_certificate_key /etc/letsencrypt/live/$expected_host/privkey.pem;' directive" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-903-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-904-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-905-  if ! grep -Eq "^[[:space:]]*server_name[[:space:]]+${host_esc}[[:space:]]*;" "$f"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-906-    echo "aborting deploy: $f does not contain server_name $expected_host;" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-907-    exit 1
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3239-_append_deploy_input_digest "$CLI_BINARY" "coordinator-cli-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3240-_append_deploy_input_digest "$STATS_INVENTORY_BINARY" "stats-inventory-sync-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3241-_append_deploy_input_digest "$STATS_BILLING_MIRROR_BINARY" "stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3242-_append_deploy_input_digest "$STATS_HARDWARE_VERIFIER_BINARY" "stats-hardware-verifier-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3243-if [ "$CONFIG_MODE" = "apply-tracked" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3244-  _append_deploy_input_digest "$CONFIG" "coordinator.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3245-elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3246-  _append_deploy_input_digest "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.rate-card-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3247-elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3248-  _append_deploy_input_digest "$C2_TIMER_MIGRATED_CONFIG_TMP" "coordinator.c2-timer-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3249-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3250-if [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3251-  _append_deploy_input_digest "$RATE_CARD_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.rate-card-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3252-elif [ "${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3253-  _append_deploy_input_digest "$C2_TIMER_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.c2-timer-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3254-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3255-for _deploy_input in \
phase4-coordinator/dist/deploy-pearl-vps.sh-3256-  "$SERVICE=macprovider-coordinator.service" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3257-  "$STATS_INVENTORY_SERVICE=stats-inventory-sync.service" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3258-  "$STATS_INVENTORY_TIMER=stats-inventory-sync.timer" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3259-  "$STATS_BILLING_MIRROR_SERVICE=stats-billing-mirror.service" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3260-  "$STATS_BILLING_MIRROR_TIMER=stats-billing-mirror.timer" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3261-  "$STATS_HARDWARE_VERIFIER_SERVICE=stats-hardware-verifier.service" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3262-  "$STATS_HARDWARE_VERIFIER_TIMER=stats-hardware-verifier.timer" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3263-  "$NGINX_SITE=nginx-coordinator-full.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3264-  "$NGINX_STATS_SHARED=nginx-stats-shared.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3265-  "$NGINX_STATS_SECHEADERS=nginx-stats-security-headers.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3266-  "$NGINX_STATS_CORS_429=nginx-stats-cors-429.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3267-  "$NGINX_STATS_PROXY_PUBLIC=nginx-stats-proxy-public.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3268-  "$NGINX_STATS_PROXY_PARTNER=nginx-stats-proxy-partner.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3269-  "$NGINX_STATS_SITE=nginx-stats.malibu.tech.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3270-  "$STATIC_DEMAND_JSON=demand-rank.json" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3271-  "$STATIC_DEMAND_SIG=demand-rank.json.sig" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3272-  "$STATIC_AUTOTUNE_JSON=autotune-candidates.json" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3273-  "$STATIC_AUTOTUNE_SIG=autotune-candidates.json.sig" \
phase4-coordinator/dist/deploy-pearl-vps.sh:3274:  "$STATIC_RATE_CARD_JSON=rate-card.json" \
phase4-coordinator/dist/deploy-pearl-vps.sh:3275:  "$STATIC_RATE_CARD_SIG=rate-card.json.sig" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3276-  "$AUTOTUNE_RELEASE_MANIFEST=release.json" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3277-  "$AUTOTUNE_RELEASE_LEDGER=release-ledger.json" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3278-  "$AUTOTUNE_TIER2_CONTENT_INDEX=tier2-content-index.json" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3279-  "$AUTOTUNE_TRUSTED_KEYS=trusted-keys.json"; do
phase4-coordinator/dist/deploy-pearl-vps.sh-3280-  _append_deploy_input_digest "${_deploy_input%%=*}" "${_deploy_input#*=}"
phase4-coordinator/dist/deploy-pearl-vps.sh-3281-done
phase4-coordinator/dist/deploy-pearl-vps.sh-3282-for _bundle_path in $CATALOG_VERIFIER_BUNDLE; do
phase4-coordinator/dist/deploy-pearl-vps.sh-3283-  _append_deploy_input_digest "$PINNED_SCRIPTS_DIR/${_bundle_path#scripts/}" "$_bundle_path"
phase4-coordinator/dist/deploy-pearl-vps.sh-3284-done
phase4-coordinator/dist/deploy-pearl-vps.sh-3285-if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3286-  _append_deploy_input_digest "$STATIC_ARTIFACTS_JSON" "autotune-artifacts.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3287-  _append_deploy_input_digest "$STATIC_ARTIFACTS_SIG" "autotune-artifacts.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-3288-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3289-if [ -n "$CATALOG_REMOTE_PATH" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3290-  _append_deploy_input_digest "$TMP_CATALOG_PINNED" "tier2-catalog.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3291-  _append_deploy_input_digest "$TMP_CATALOG_PUBKEY" "tier2-catalog.pub"
phase4-coordinator/dist/deploy-pearl-vps.sh-3292-else
phase4-coordinator/dist/deploy-pearl-vps.sh-3293-  _append_deploy_input_digest "$AUTOTUNE_TIER2_JSON" "tier2-catalog.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3294-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3295-
phase4-coordinator/dist/deploy-pearl-vps.sh-3296-$SCP "$BINARY"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3297-$SCP "$CLI_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-cli-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3298-$SCP "$STATS_INVENTORY_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3299-$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3300-$SCP "$STATS_HARDWARE_VERIFIER_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3301-if [ "$CONFIG_MODE" = "apply-tracked" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3302-  $SCP "$CONFIG" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3303-elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3304-  $SCP "$RATE_CARD_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.rate-card-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3305-elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3306-  $SCP "$C2_TIMER_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.c2-timer-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3307-else
phase4-coordinator/dist/deploy-pearl-vps.sh-3308-  log "  CONFIG_MODE=preserve-live — not uploading tracked coordinator.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3309-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3310-if [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3311-  $SCP "$RATE_CARD_MIGRATED_OVERLAY_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3312-elif [ "${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3313-  $SCP "$C2_TIMER_MIGRATED_OVERLAY_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.pearl-overlays.c2-timer-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3314-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3315-$SCP "$SERVICE"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/macprovider-coordinator.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-3316-$SCP "$STATS_INVENTORY_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-3317-$SCP "$STATS_INVENTORY_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh-3318-$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-3319-$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh-3320-$SCP "$STATS_HARDWARE_VERIFIER_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-3321-$SCP "$STATS_HARDWARE_VERIFIER_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh-3322-$SCP "$NGINX_SITE"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-coordinator-full.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3323-# SPEC-017 v0.1.8 Step 4.B artifacts (snippet must land at
phase4-coordinator/dist/deploy-pearl-vps.sh-3324-# /etc/nginx/conf.d/ so the http-context declarations are visible
phase4-coordinator/dist/deploy-pearl-vps.sh-3325-# to BOTH the coordinator vhost (for /v1/stats/* allow-through)
phase4-coordinator/dist/deploy-pearl-vps.sh-3326-# and the stats vhost. Installation step below is wired BEFORE
phase4-coordinator/dist/deploy-pearl-vps.sh-3327-# the coordinator vhost full-TLS install so `nginx -t` does not
phase4-coordinator/dist/deploy-pearl-vps.sh-3328-# trip on missing zone names.).
phase4-coordinator/dist/deploy-pearl-vps.sh-3329-$SCP "$NGINX_STATS_SHARED"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-shared.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3330-$SCP "$NGINX_STATS_SECHEADERS" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-security-headers.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3331-$SCP "$NGINX_STATS_CORS_429"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-cors-429.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3332-$SCP "$NGINX_STATS_PROXY_PUBLIC"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-proxy-public.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3333-$SCP "$NGINX_STATS_PROXY_PARTNER" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-proxy-partner.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3334-$SCP "$NGINX_STATS_SITE"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats.malibu.tech.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3335-# SPEC-023 v1.7.3 signed static feeds
phase4-coordinator/dist/deploy-pearl-vps.sh-3336-$SCP "$STATIC_DEMAND_JSON"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3337-$SCP "$STATIC_DEMAND_SIG"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-3338-$SCP "$STATIC_AUTOTUNE_JSON"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-candidates.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3339-$SCP "$STATIC_AUTOTUNE_SIG"    "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-candidates.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh:3340:$SCP "$STATIC_RATE_CARD_JSON"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/rate-card.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:3341:$SCP "$STATIC_RATE_CARD_SIG"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/rate-card.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-3342-AUTOTUNE_ARTIFACT_INSTALL_LINES=""
phase4-coordinator/dist/deploy-pearl-vps.sh-3343-if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3344-  $SCP "$STATIC_ARTIFACTS_JSON"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-artifacts.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3345-  $SCP "$STATIC_ARTIFACTS_SIG"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-artifacts.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-3346-  # Staged into the immutable envelope beside the other feeds (remote script
phase4-coordinator/dist/deploy-pearl-vps.sh-3347-  # below); the coordinator serves the pair only once its config names it.
phase4-coordinator/dist/deploy-pearl-vps.sh-3348-  AUTOTUNE_ARTIFACT_INSTALL_LINES="
phase4-coordinator/dist/deploy-pearl-vps.sh-3349-  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-artifacts.json \$_autotune_stage/autotune-artifacts.json
phase4-coordinator/dist/deploy-pearl-vps.sh-3350-  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-artifacts.json.sig \$_autotune_stage/autotune-artifacts.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-3351-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3352-$SCP "$AUTOTUNE_RELEASE_MANIFEST" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/release.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3353-$SCP "$AUTOTUNE_TRUSTED_KEYS"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/trusted-keys.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3354-$SCP "$AUTOTUNE_RELEASE_LEDGER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/release-ledger.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3355-$SCP "$AUTOTUNE_TIER2_CONTENT_INDEX" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-content-index.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3356-$SCP "$AUTOTUNE_TIER2_JSON"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3357-for _bundle_path in $CATALOG_VERIFIER_BUNDLE; do
phase4-coordinator/dist/deploy-pearl-vps.sh-3358-  $SCP "$PINNED_SCRIPTS_DIR/${_bundle_path#scripts/}" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/$_bundle_path"
phase4-coordinator/dist/deploy-pearl-vps.sh-3359-done
phase4-coordinator/dist/deploy-pearl-vps.sh-3360-if [ -n "$CATALOG_REMOTE_PATH" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3361-  if [ -z "${TMP_CATALOG_PINNED:-}" ] || [ ! -f "$TMP_CATALOG_PINNED" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3362-    echo "aborting deploy: pinned Tier-2 catalog snapshot missing before upload" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3363-    exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-3364-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3365-  UPLOAD_CATALOG_SHA="$(shasum -a 256 "$TMP_CATALOG_PINNED" | awk '{print $1}')"
phase4-coordinator/dist/deploy-pearl-vps.sh-3366-  if [ "$UPLOAD_CATALOG_SHA" != "$CATALOG_PIN_SHA" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3367-    echo "aborting deploy: pinned Tier-2 catalog digest changed before upload ($UPLOAD_CATALOG_SHA != $CATALOG_PIN_SHA)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3368-    exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-3369-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3370-  $SCP "$TMP_CATALOG_PINNED" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3371-  $SCP "$TMP_CATALOG_PUBKEY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.pub"
phase4-coordinator/dist/deploy-pearl-vps.sh-3372-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3373-$SCP "$DEPLOY_INPUT_MANIFEST_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/deploy-inputs.sha256"
phase4-coordinator/dist/deploy-pearl-vps.sh-3374-$SSH "cd $DEPLOY_TMP && shasum -a 256 -c deploy-inputs.sha256 >/dev/null"
phase4-coordinator/dist/deploy-pearl-vps.sh-3375-echo "  staged deploy input digests OK"
phase4-coordinator/dist/deploy-pearl-vps.sh-3376-# #1688: run the exact verify-directory the staging block below runs, over the
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4092-)" || { echo "aborting deploy: could not build the window coverage override record" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-4093-      _append_catalog_window_override "$CATALOG_OVERRIDE_RECORD_B64" "catalog window coverage override used for $AUTOTUNE_RELEASE_DIR_NAME"
phase4-coordinator/dist/deploy-pearl-vps.sh-4094-      log "  AUDIT TRAIL: override appended to /var/lib/macprovider/catalog-window-overrides.jsonl"
phase4-coordinator/dist/deploy-pearl-vps.sh-4095-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4096-    ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-4097-  equivalent) ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-4098-  *) echo "aborting deploy: unknown compare-live verdict" >&2; exit 1 ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-4099-esac
phase4-coordinator/dist/deploy-pearl-vps.sh-4100-
phase4-coordinator/dist/deploy-pearl-vps.sh-4101-if [ "$CATALOG_VERDICT" = "equivalent" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4102-  # #1688 A2: content-equivalent live catalog. No current swap, no window
phase4-coordinator/dist/deploy-pearl-vps.sh-4103-  # apply; the immutable release staged above stays for forensics/rollback.
phase4-coordinator/dist/deploy-pearl-vps.sh-4104-  log "  catalog unchanged; runtime-only deploy keeps live release $CATALOG_LIVE_RELEASE_ID"
phase4-coordinator/dist/deploy-pearl-vps.sh-4105-  $SSH "set -e
phase4-coordinator/dist/deploy-pearl-vps.sh-4106-    exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
phase4-coordinator/dist/deploy-pearl-vps.sh-4107-    flock -s 8
phase4-coordinator/dist/deploy-pearl-vps.sh-4108-    _current=\$(readlink /opt/macprovider/autotune/current 2>/dev/null || true)
phase4-coordinator/dist/deploy-pearl-vps.sh-4109-    [ \"\$_current\" = '$CATALOG_LIVE_TARGET' ] || {
phase4-coordinator/dist/deploy-pearl-vps.sh-4110-      echo \"autotune/current moved since compare-live (\$_current); re-run the deploy\" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4111-      exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4112-    }
phase4-coordinator/dist/deploy-pearl-vps.sh-4113-    rm -f /opt/macprovider/tier2-catalog.json
phase4-coordinator/dist/deploy-pearl-vps.sh-4114-    rm -rf $DEPLOY_TMP
phase4-coordinator/dist/deploy-pearl-vps.sh-4115-  " || { echo "aborting deploy: live catalog changed since compare-live or could not be pinned" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-4116-  # Post-restart smokes and the canary prove the LIVE release, not the tag's.
phase4-coordinator/dist/deploy-pearl-vps.sh-4117-  [ -n "$PINNED_DEPLOY_INPUT_DIR" ] || { echo "aborting deploy: no pinned input dir for the live catalog snapshot" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-4118-  CATALOG_LIVE_SNAPSHOT="$PINNED_DEPLOY_INPUT_DIR/live-catalog"
phase4-coordinator/dist/deploy-pearl-vps.sh-4119-  mkdir -m 0700 "$CATALOG_LIVE_SNAPSHOT"
phase4-coordinator/dist/deploy-pearl-vps.sh-4120-  # shellcheck disable=SC2086 # fixed release file names
phase4-coordinator/dist/deploy-pearl-vps.sh-4121-  $SSH "tar -C /opt/macprovider/autotune/$CATALOG_LIVE_TARGET -cf - $CATALOG_RELEASE_FILES" | tar -xf - -C "$CATALOG_LIVE_SNAPSHOT" ||
phase4-coordinator/dist/deploy-pearl-vps.sh-4122-    { echo "aborting deploy: could not snapshot the live catalog release" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-4123-  STATIC_DEMAND_JSON="$CATALOG_LIVE_SNAPSHOT/demand-rank.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4124-  STATIC_DEMAND_SIG="$CATALOG_LIVE_SNAPSHOT/demand-rank.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-4125-  STATIC_AUTOTUNE_JSON="$CATALOG_LIVE_SNAPSHOT/autotune-candidates.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4126-  STATIC_AUTOTUNE_SIG="$CATALOG_LIVE_SNAPSHOT/autotune-candidates.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh:4127:  STATIC_RATE_CARD_JSON="$CATALOG_LIVE_SNAPSHOT/rate-card.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:4128:  STATIC_RATE_CARD_SIG="$CATALOG_LIVE_SNAPSHOT/rate-card.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-4129-  AUTOTUNE_RELEASE_MANIFEST="$CATALOG_LIVE_SNAPSHOT/release.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4130-  AUTOTUNE_TRUSTED_KEYS="$CATALOG_LIVE_SNAPSHOT/trusted-keys.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4131-  AUTOTUNE_TIER2_JSON="$CATALOG_LIVE_SNAPSHOT/tier2-catalog.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4132-  CATALOG_LIVE_IDENTITY="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" "$CATALOG_LIVE_RELEASE_ID" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-4133-import json, pathlib, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-4134-manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
phase4-coordinator/dist/deploy-pearl-vps.sh-4135-if manifest.get("release_id") != sys.argv[2]:
phase4-coordinator/dist/deploy-pearl-vps.sh-4136-    raise SystemExit("live catalog snapshot release_id differs from the compare-live verdict")
phase4-coordinator/dist/deploy-pearl-vps.sh-4137-feed = manifest["feeds"]["autotune-candidates.json"]
phase4-coordinator/dist/deploy-pearl-vps.sh-4138-print(manifest["release_id"], manifest["policy_version"], feed["sha256"], feed["signer_key_id"])
phase4-coordinator/dist/deploy-pearl-vps.sh-4139-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-4140-)" || { echo "aborting deploy: live catalog snapshot does not match compare-live" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-4141-  read -r AUTOTUNE_RELEASE_ID AUTOTUNE_POLICY_VERSION AUTOTUNE_CANDIDATE_SHA256 AUTOTUNE_CANDIDATE_SIGNER_KEY_ID <<< "$CATALOG_LIVE_IDENTITY"
phase4-coordinator/dist/deploy-pearl-vps.sh-4142-else
phase4-coordinator/dist/deploy-pearl-vps.sh-4143-log "  activating verified autotune release $AUTOTUNE_RELEASE_ID"
phase4-coordinator/dist/deploy-pearl-vps.sh-4144-$SSH "set -e
phase4-coordinator/dist/deploy-pearl-vps.sh-4145-  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
phase4-coordinator/dist/deploy-pearl-vps.sh-4146-  flock -s 8
phase4-coordinator/dist/deploy-pearl-vps.sh-4147-  _catalog_root=/opt/macprovider/autotune
phase4-coordinator/dist/deploy-pearl-vps.sh-4148-  _previous=\$(readlink \"\$_catalog_root/current\" 2>/dev/null || true)
phase4-coordinator/dist/deploy-pearl-vps.sh-4149-  # #1688 A2: activate only over the current compare-live judged (staging may
phase4-coordinator/dist/deploy-pearl-vps.sh-4150-  # have bootstrapped current to this release when none existed).
phase4-coordinator/dist/deploy-pearl-vps.sh-4151-  case \"\$_previous\" in
phase4-coordinator/dist/deploy-pearl-vps.sh-4152-    '$CATALOG_LIVE_TARGET') ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-4153-    releases/$AUTOTUNE_RELEASE_DIR_NAME) [ '$CATALOG_VERDICT' = bootstrap ] || { echo 'autotune/current moved since compare-live; re-run the deploy' >&2; exit 1; } ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-4154-    *) echo \"autotune/current moved since compare-live (\$_previous); re-run the deploy\" >&2; exit 1 ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-4155-  esac
phase4-coordinator/dist/deploy-pearl-vps.sh-4156-  case \"\$_previous\" in
phase4-coordinator/dist/deploy-pearl-vps.sh-4157-    ''|releases/[A-Za-z0-9]*) ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-4158-    *) echo \"invalid existing autotune current target: \$_previous\" >&2; exit 1 ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-4159-  esac
phase4-coordinator/dist/deploy-pearl-vps.sh-4160-  case \"\$_previous\" in
phase4-coordinator/dist/deploy-pearl-vps.sh-4161-    *[!A-Za-z0-9._/-]*|*'/../'*|*'/..'|*'/./'*|*'/.'|*'//'|releases/|releases) echo \"unsafe existing autotune current target: \$_previous\" >&2; exit 1 ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-4162-  esac
phase4-coordinator/dist/deploy-pearl-vps.sh-4163-  [ ! -e \"\$_catalog_root/current.next\" ] && [ ! -L \"\$_catalog_root/current.next\" ] || {
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4247-    echo "aborting smoke: mktemp failed" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4248-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4249-  }
phase4-coordinator/dist/deploy-pearl-vps.sh-4250-  STATUS=$(curl -sS -o "$CATALOG_SMOKE_TMP" -w '%{http_code}' --max-time 10 --max-filesize 1048576 "https://$DOMAIN/catalog/current")
phase4-coordinator/dist/deploy-pearl-vps.sh-4251-  if [ "$STATUS" != "200" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4252-    echo "coordinator /catalog/current check failed: status=$STATUS body=$(head -c 300 "$CATALOG_SMOKE_TMP")" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4253-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4254-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4255-  # #292 R1 ARCH MED: `echo "$(python3 ...)"` under set -e is silent on
phase4-coordinator/dist/deploy-pearl-vps.sh-4256-  # python failure — echo succeeds regardless, so invalid JSON (or a
phase4-coordinator/dist/deploy-pearl-vps.sh-4257-  # 200 response body that isn't the catalog schema) prints
phase4-coordinator/dist/deploy-pearl-vps.sh-4258-  # "catalog OK:" and the deploy proceeds. Assign first, check exit
phase4-coordinator/dist/deploy-pearl-vps.sh-4259-  # explicitly, then echo.
phase4-coordinator/dist/deploy-pearl-vps.sh-4260-  CATALOG_SUMMARY=$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("catalog_id=%s models=%d" % (c.get("catalog_id"), len(c.get("models", []))))' "$CATALOG_SMOKE_TMP") || {
phase4-coordinator/dist/deploy-pearl-vps.sh-4261-    echo "coordinator /catalog/current smoke: python3 parse failed on 200 body (head -c 300: $(head -c 300 "$CATALOG_SMOKE_TMP"))" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4262-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4263-  }
phase4-coordinator/dist/deploy-pearl-vps.sh-4264-  echo "  catalog OK: $CATALOG_SUMMARY"
phase4-coordinator/dist/deploy-pearl-vps.sh-4265-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4266-
phase4-coordinator/dist/deploy-pearl-vps.sh-4267-# SPEC-023 signed recommendation feeds smoke (buyer mux via nginx).
phase4-coordinator/dist/deploy-pearl-vps.sh-4268-log "  verifying coordinator can read autotune feeds as macprovider"
phase4-coordinator/dist/deploy-pearl-vps.sh-4269-$SSH "set -e
phase4-coordinator/dist/deploy-pearl-vps.sh-4270-  sudo -u macprovider test -r /opt/macprovider/autotune/current/autotune-candidates.json
phase4-coordinator/dist/deploy-pearl-vps.sh-4271-  sudo -u macprovider test -r /opt/macprovider/autotune/current/demand-rank.json
phase4-coordinator/dist/deploy-pearl-vps.sh-4272-  sudo -u macprovider test -r /opt/macprovider/autotune/current/rate-card.json
phase4-coordinator/dist/deploy-pearl-vps.sh-4273-" || {
phase4-coordinator/dist/deploy-pearl-vps.sh-4274-  echo "aborting smoke: macprovider cannot read /opt/macprovider/autotune/*" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4275-  exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4276-}
phase4-coordinator/dist/deploy-pearl-vps.sh-4277-STATIC_SMOKE_DIR=$(umask 077 && mktemp -d -t macprovider-autotune-probe.XXXXXXXX) || {
phase4-coordinator/dist/deploy-pearl-vps.sh-4278-  echo "aborting smoke: mktemp -d failed for autotune feed probe" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4279-  exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4280-}
phase4-coordinator/dist/deploy-pearl-vps.sh-4281-for STATIC_SPEC in \
phase4-coordinator/dist/deploy-pearl-vps.sh:4282:    "/v1/rate-card|rate-card.json|$STATIC_RATE_CARD_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh:4283:    "/v1/rate-card.sig|rate-card.json.sig|$STATIC_RATE_CARD_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4284-    "/v1/demand-rank|demand-rank.json|$STATIC_DEMAND_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4285-    "/v1/demand-rank.sig|demand-rank.json.sig|$STATIC_DEMAND_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4286-    "/v1/autotune-candidates|autotune-candidates.json|$STATIC_AUTOTUNE_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4287-    "/v1/autotune-candidates.sig|autotune-candidates.json.sig|$STATIC_AUTOTUNE_SIG"; do
phase4-coordinator/dist/deploy-pearl-vps.sh-4288-  STATIC_PATH="${STATIC_SPEC%%|*}"
phase4-coordinator/dist/deploy-pearl-vps.sh-4289-  STATIC_REST="${STATIC_SPEC#*|}"
phase4-coordinator/dist/deploy-pearl-vps.sh-4290-  STATIC_NAME="${STATIC_REST%%|*}"
phase4-coordinator/dist/deploy-pearl-vps.sh-4291-  STATIC_EXPECTED="${STATIC_REST#*|}"
phase4-coordinator/dist/deploy-pearl-vps.sh-4292-  STATIC_SMOKE_BODY="$STATIC_SMOKE_DIR/$STATIC_NAME"
phase4-coordinator/dist/deploy-pearl-vps.sh-4293-  echo "  GET https://$DOMAIN$STATIC_PATH -> expect 200"
phase4-coordinator/dist/deploy-pearl-vps.sh-4294-  STATUS=$(curl -sS -o "$STATIC_SMOKE_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 "https://$DOMAIN$STATIC_PATH")
phase4-coordinator/dist/deploy-pearl-vps.sh-4295-  if [ "$STATUS" != "200" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4296-    echo "SPEC-023 autotune feed smoke failed: $STATIC_PATH status=$STATUS body=$(head -c 200 "$STATIC_SMOKE_BODY")" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4297-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4298-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4299-  if ! cmp -s "$STATIC_EXPECTED" "$STATIC_SMOKE_BODY"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4300-    echo "SPEC-023 autotune feed smoke failed: $STATIC_PATH bytes differ from staged release" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4301-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4302-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4303-done
phase4-coordinator/dist/deploy-pearl-vps.sh-4304-cp "$AUTOTUNE_RELEASE_MANIFEST" "$STATIC_SMOKE_DIR/release.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4305-cp "$AUTOTUNE_TRUSTED_KEYS" "$STATIC_SMOKE_DIR/trusted-keys.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4306-cp "$AUTOTUNE_TIER2_JSON" "$STATIC_SMOKE_DIR/tier2-catalog.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:4307:cp "$STATIC_RATE_CARD_JSON" "$STATIC_SMOKE_DIR/rate-card.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:4308:cp "$STATIC_RATE_CARD_SIG" "$STATIC_SMOKE_DIR/rate-card.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-4309-python3 "$AUTOTUNE_RELEASE_VERIFY" verify-directory --directory "$STATIC_SMOKE_DIR"
phase4-coordinator/dist/deploy-pearl-vps.sh-4310-AUTOTUNE_STATUS_BODY="$STATIC_SMOKE_DIR/autotune-release-status.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4311-STATUS=$(curl -sS -o "$AUTOTUNE_STATUS_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 "https://$DOMAIN/v1/autotune-release")
phase4-coordinator/dist/deploy-pearl-vps.sh-4312-if [ "$STATUS" != "200" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4313-  echo "SPEC-023 autotune release status failed: status=$STATUS body=$(head -c 200 "$AUTOTUNE_STATUS_BODY")" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4314-  exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4315-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4316-python3 - "$AUTOTUNE_STATUS_BODY" "$AUTOTUNE_RELEASE_ID" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-4317-import json, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-4318-status = json.load(open(sys.argv[1], encoding="utf-8"))
phase4-coordinator/dist/deploy-pearl-vps.sh-4319-if status.get("status") != "live_verified" or status.get("release_id") != sys.argv[2]:
phase4-coordinator/dist/deploy-pearl-vps.sh-4320-    raise SystemExit("coordinator autotune release metadata does not match activated release")
phase4-coordinator/dist/deploy-pearl-vps.sh-4321-for name in ("autotune_candidates", "demand_rank", "rate_card"):
phase4-coordinator/dist/deploy-pearl-vps.sh-4322-    feed = status.get("feeds", {}).get(name, {})
phase4-coordinator/dist/deploy-pearl-vps.sh-4323-    if len(feed.get("sha256", "")) != 64 or not feed.get("signer_key_id"):
phase4-coordinator/dist/deploy-pearl-vps.sh-4324-        raise SystemExit(f"coordinator autotune release metadata is incomplete for {name}")
phase4-coordinator/dist/deploy-pearl-vps.sh-4325-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-4326-echo "  SPEC-023 autotune feeds exact-byte and signature verification OK"
phase4-coordinator/dist/deploy-pearl-vps.sh-4327-
phase4-coordinator/dist/deploy-pearl-vps.sh-4328-# A perfect catalog endpoint does not prove the exact canary process completed
phase4-coordinator/dist/deploy-pearl-vps.sh-4329-# the hello compatibility gate. First prove the live Mac process and capture its
phase4-coordinator/dist/deploy-pearl-vps.sh-4330-# assigned coordinator session; then query authenticated coordinator evidence
phase4-coordinator/dist/deploy-pearl-vps.sh-4331-# for that exact session below.
phase4-coordinator/dist/deploy-pearl-vps.sh-4332-CANARY_POOL_BODY="$STATIC_SMOKE_DIR/catalog-canary-pool.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4333-CANARY_CURL_CONFIG="$STATIC_SMOKE_DIR/catalog-canary-curl.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-4334-
phase4-coordinator/dist/deploy-pearl-vps.sh-4335-# Provider hello fields are authenticated self-report, so they are not exact
phase4-coordinator/dist/deploy-pearl-vps.sh-4336-# installation proof. Read the release bundle from the operator-controlled
phase4-coordinator/dist/deploy-pearl-vps.sh-4337-# canary Mac over host-key-checked SSH and compare every shipped catalog file
phase4-coordinator/dist/deploy-pearl-vps.sh-4338-# with the locally verified release. This makes the deployment commit depend on
phase4-coordinator/dist/deploy-pearl-vps.sh-4339-# independent canary-host custody of the exact bytes, not on replayable public
phase4-coordinator/dist/deploy-pearl-vps.sh-4340-# catalog identifiers in a provider hello.
phase4-coordinator/dist/deploy-pearl-vps.sh-4341-CANARY_INSTALLED_BODY="$STATIC_SMOKE_DIR/catalog-canary-installed.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-4342-CANARY_SSH=(
phase4-coordinator/dist/deploy-pearl-vps.sh-4343-  ssh
phase4-coordinator/dist/deploy-pearl-vps.sh-4344-  -i "$CATALOG_CANARY_SSH_KEY"
phase4-coordinator/dist/deploy-pearl-vps.sh-4345-  -o BatchMode=yes
phase4-coordinator/dist/deploy-pearl-vps.sh-4346-  -o IdentitiesOnly=yes
phase4-coordinator/dist/deploy-pearl-vps.sh-4347-  -o StrictHostKeyChecking=yes
phase4-coordinator/dist/deploy-pearl-vps.sh-4348-  -o ConnectTimeout=10
phase4-coordinator/dist/deploy-pearl-vps.sh-4349-  -o ServerAliveInterval=15
phase4-coordinator/dist/deploy-pearl-vps.sh-4350-  -o ServerAliveCountMax=3
phase4-coordinator/dist/deploy-pearl-vps.sh-4351-  "$CATALOG_CANARY_SSH_TARGET"
phase4-coordinator/dist/deploy-pearl-vps.sh-4352-)
phase4-coordinator/dist/deploy-pearl-vps.sh:4353:run_catalog_canary_mac_proof() {
phase4-coordinator/dist/deploy-pearl-vps.sh-4354-  local timeout_s="$1"
phase4-coordinator/dist/deploy-pearl-vps.sh-4355-  _run_with_deadline_alarm "$timeout_s" "${CANARY_SSH[@]}" python3 - \
phase4-coordinator/dist/deploy-pearl-vps.sh-4356-  "$CATALOG_CANARY_INSTALL_DIR" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4357-  "$CATALOG_CANARY_PROVIDER_ID" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4358-  "$AUTOTUNE_RELEASE_ID" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4359-  "$AUTOTUNE_POLICY_VERSION" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4360-  "$AUTOTUNE_CANDIDATE_SHA256" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4361-  "$AUTOTUNE_CANDIDATE_SIGNER_KEY_ID" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-4362-import hashlib, json, os, plistlib, re, stat, subprocess, sys, urllib.request
phase4-coordinator/dist/deploy-pearl-vps.sh-4363-
phase4-coordinator/dist/deploy-pearl-vps.sh-4364-(
phase4-coordinator/dist/deploy-pearl-vps.sh-4365-    catalog_path,
phase4-coordinator/dist/deploy-pearl-vps.sh-4366-    expected_provider_id,
phase4-coordinator/dist/deploy-pearl-vps.sh-4367-    expected_release_id,
phase4-coordinator/dist/deploy-pearl-vps.sh-4368-    expected_policy_version,
phase4-coordinator/dist/deploy-pearl-vps.sh-4369-    expected_digest,
phase4-coordinator/dist/deploy-pearl-vps.sh-4370-    expected_signer,
phase4-coordinator/dist/deploy-pearl-vps.sh-4371-) = sys.argv[1:]
phase4-coordinator/dist/deploy-pearl-vps.sh-4372-home = os.path.expanduser("~")
phase4-coordinator/dist/deploy-pearl-vps.sh-4373-nofollow = getattr(os, "O_NOFOLLOW", 0)
phase4-coordinator/dist/deploy-pearl-vps.sh-4374-nonblock = getattr(os, "O_NONBLOCK", 0)
phase4-coordinator/dist/deploy-pearl-vps.sh-4375-directory_flags = os.O_RDONLY | os.O_DIRECTORY | nofollow
phase4-coordinator/dist/deploy-pearl-vps.sh-4376-
phase4-coordinator/dist/deploy-pearl-vps.sh-4377-def open_dir(path):
phase4-coordinator/dist/deploy-pearl-vps.sh-4378-    if os.path.isabs(path):
phase4-coordinator/dist/deploy-pearl-vps.sh-4379-        current = os.open("/", directory_flags)
phase4-coordinator/dist/deploy-pearl-vps.sh-4380-        parts = [part for part in path.split("/") if part]
phase4-coordinator/dist/deploy-pearl-vps.sh-4381-    else:
phase4-coordinator/dist/deploy-pearl-vps.sh-4382-        current = os.open(home, directory_flags)
phase4-coordinator/dist/deploy-pearl-vps.sh-4383-        parts = [part for part in path.split("/") if part]
phase4-coordinator/dist/deploy-pearl-vps.sh-4384-    try:
phase4-coordinator/dist/deploy-pearl-vps.sh-4385-        for part in parts:
phase4-coordinator/dist/deploy-pearl-vps.sh-4386-            if part in {".", ".."}:
phase4-coordinator/dist/deploy-pearl-vps.sh-4387-                raise SystemExit(f"unsafe canary path component: {part}")
phase4-coordinator/dist/deploy-pearl-vps.sh-4388-            next_fd = os.open(part, directory_flags, dir_fd=current)
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4579-        "assigned_id": assigned_id,
phase4-coordinator/dist/deploy-pearl-vps.sh-4580-        "launchd_pid": pid,
phase4-coordinator/dist/deploy-pearl-vps.sh-4581-        "executable_path": process_path,
phase4-coordinator/dist/deploy-pearl-vps.sh-4582-        "local_status": local_status,
phase4-coordinator/dist/deploy-pearl-vps.sh-4583-        "files": hashes,
phase4-coordinator/dist/deploy-pearl-vps.sh-4584-    }, sort_keys=True))
phase4-coordinator/dist/deploy-pearl-vps.sh-4585-finally:
phase4-coordinator/dist/deploy-pearl-vps.sh-4586-    for fd in (config_fd, provider_config_fd, binary_fd, install_fd, catalog_fd):
phase4-coordinator/dist/deploy-pearl-vps.sh-4587-        if fd is not None:
phase4-coordinator/dist/deploy-pearl-vps.sh-4588-            os.close(fd)
phase4-coordinator/dist/deploy-pearl-vps.sh-4589-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-4590-}
phase4-coordinator/dist/deploy-pearl-vps.sh-4591-
phase4-coordinator/dist/deploy-pearl-vps.sh-4592-# A coordinator restart can make a healthy provider rotate its PID and assigned
phase4-coordinator/dist/deploy-pearl-vps.sh-4593-# session while its recovery watchdog drains in-flight work. Retry the complete
phase4-coordinator/dist/deploy-pearl-vps.sh-4594-# Mac proof and bind each admission query to the session from that same attempt;
phase4-coordinator/dist/deploy-pearl-vps.sh-4595-# never carry an assigned_id across retries. This mirrors the signed updater's
phase4-coordinator/dist/deploy-pearl-vps.sh-4596-# full-proof retry and keeps every success predicate fail-closed.
phase4-coordinator/dist/deploy-pearl-vps.sh-4597-CANARY_PROVIDER_QUERY=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CATALOG_CANARY_PROVIDER_ID")
phase4-coordinator/dist/deploy-pearl-vps.sh-4598-(umask 077 && printf 'header = "Authorization: Bearer %s"\n' "$CATALOG_CANARY_AUTH_TOKEN" > "$CANARY_CURL_CONFIG")
phase4-coordinator/dist/deploy-pearl-vps.sh-4599-CANARY_OK=0
phase4-coordinator/dist/deploy-pearl-vps.sh-4600-CANARY_LAST_ERROR="canary proof did not start"
phase4-coordinator/dist/deploy-pearl-vps.sh-4601-CANARY_STATUS="000"
phase4-coordinator/dist/deploy-pearl-vps.sh-4602-CANARY_ATTEMPT=1
phase4-coordinator/dist/deploy-pearl-vps.sh-4603-CANARY_MAX_ATTEMPTS=36
phase4-coordinator/dist/deploy-pearl-vps.sh-4604-CANARY_RECOVERY_TIMEOUT_S=180
phase4-coordinator/dist/deploy-pearl-vps.sh-4605-CANARY_RECOVERY_DEADLINE=$((SECONDS + CANARY_RECOVERY_TIMEOUT_S))
phase4-coordinator/dist/deploy-pearl-vps.sh-4606-while [ "$CANARY_ATTEMPT" -le "$CANARY_MAX_ATTEMPTS" ] && [ "$SECONDS" -lt "$CANARY_RECOVERY_DEADLINE" ]; do
phase4-coordinator/dist/deploy-pearl-vps.sh-4607-  rm -f "$CANARY_INSTALLED_BODY" "$CANARY_POOL_BODY"
phase4-coordinator/dist/deploy-pearl-vps.sh-4608-  CANARY_PROOF_ERROR="$STATIC_SMOKE_DIR/catalog-canary-proof.err"
phase4-coordinator/dist/deploy-pearl-vps.sh-4609-  CANARY_REMAINING_S=$((CANARY_RECOVERY_DEADLINE - SECONDS))
phase4-coordinator/dist/deploy-pearl-vps.sh-4610-  CANARY_PROOF_TIMEOUT_S=45
phase4-coordinator/dist/deploy-pearl-vps.sh-4611-  if [ "$CANARY_REMAINING_S" -lt "$CANARY_PROOF_TIMEOUT_S" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4612-    CANARY_PROOF_TIMEOUT_S="$CANARY_REMAINING_S"
phase4-coordinator/dist/deploy-pearl-vps.sh-4613-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh:4614:  if run_catalog_canary_mac_proof "$CANARY_PROOF_TIMEOUT_S" > "$CANARY_INSTALLED_BODY" 2> "$CANARY_PROOF_ERROR"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4615-    CANARY_BINDING=$(python3 - "$CANARY_INSTALLED_BODY" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-4616-import json, pathlib, re, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-4617-proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
phase4-coordinator/dist/deploy-pearl-vps.sh-4618-assigned_id = proof.get("assigned_id")
phase4-coordinator/dist/deploy-pearl-vps.sh-4619-row_identity = proof.get("local_status", {}).get("catalog", {}).get("row_identity")
phase4-coordinator/dist/deploy-pearl-vps.sh-4620-if not isinstance(assigned_id, str) or not assigned_id or any(ch.isspace() for ch in assigned_id):
phase4-coordinator/dist/deploy-pearl-vps.sh-4621-    raise SystemExit("canary proof has no safe assigned coordinator session")
phase4-coordinator/dist/deploy-pearl-vps.sh-4622-if re.fullmatch(r"[0-9a-f]{64}", str(row_identity).lower()) is None:
phase4-coordinator/dist/deploy-pearl-vps.sh-4623-    raise SystemExit("canary proof has no exact catalog row identity")
phase4-coordinator/dist/deploy-pearl-vps.sh-4624-print(assigned_id, str(row_identity).lower())
phase4-coordinator/dist/deploy-pearl-vps.sh-4625-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-4626-) || CANARY_BINDING=""
phase4-coordinator/dist/deploy-pearl-vps.sh-4627-    if [ -n "$CANARY_BINDING" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4628-      read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY <<< "$CANARY_BINDING"
phase4-coordinator/dist/deploy-pearl-vps.sh-4629-      CANARY_ASSIGNED_QUERY=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CANARY_ASSIGNED_ID")
phase4-coordinator/dist/deploy-pearl-vps.sh-4630-      CANARY_STATUS=$(curl --config "$CANARY_CURL_CONFIG" -sS -o "$CANARY_POOL_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 \
phase4-coordinator/dist/deploy-pearl-vps.sh-4631-        "https://$DOMAIN/v1/pool/check?provider_id=$CANARY_PROVIDER_QUERY&assigned_id=$CANARY_ASSIGNED_QUERY&details=deployment" || true)
phase4-coordinator/dist/deploy-pearl-vps.sh-4632-      if [ "$CANARY_STATUS" = "200" ] && python3 - \
phase4-coordinator/dist/deploy-pearl-vps.sh-4633-        "$CANARY_POOL_BODY" "$CATALOG_CANARY_PROVIDER_ID" "$CANARY_ASSIGNED_ID" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4634-        "$AUTOTUNE_RELEASE_ID" "$AUTOTUNE_POLICY_VERSION" "$AUTOTUNE_CANDIDATE_SHA256" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4635-        "$AUTOTUNE_CANDIDATE_SIGNER_KEY_ID" "$CANARY_CATALOG_ROW_IDENTITY" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-4636-import json, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-4637-value = json.load(open(sys.argv[1], encoding="utf-8"))
phase4-coordinator/dist/deploy-pearl-vps.sh-4638-if (
phase4-coordinator/dist/deploy-pearl-vps.sh-4639-    value.get("provider_id") != sys.argv[2]
phase4-coordinator/dist/deploy-pearl-vps.sh-4640-    or value.get("assigned_id") != sys.argv[3]
phase4-coordinator/dist/deploy-pearl-vps.sh-4641-    or value.get("buyer_serving") is not True
phase4-coordinator/dist/deploy-pearl-vps.sh-4642-    or value.get("catalog_evidence_source") != "provider_reported"
phase4-coordinator/dist/deploy-pearl-vps.sh-4643-    or value.get("catalog_admission_mode") != "current"
phase4-coordinator/dist/deploy-pearl-vps.sh-4644-    or value.get("catalog_release_id") != sys.argv[4]
phase4-coordinator/dist/deploy-pearl-vps.sh-4645-    or value.get("catalog_policy_version") != sys.argv[5]
phase4-coordinator/dist/deploy-pearl-vps.sh-4646-    or value.get("catalog_candidate_sha256") != sys.argv[6]
phase4-coordinator/dist/deploy-pearl-vps.sh-4647-    or value.get("catalog_signer_key_id") != sys.argv[7]
phase4-coordinator/dist/deploy-pearl-vps.sh-4648-    or str(value.get("catalog_row_identity", "")).lower() != sys.argv[8]
phase4-coordinator/dist/deploy-pearl-vps.sh-4649-):
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4657-    else
phase4-coordinator/dist/deploy-pearl-vps.sh-4658-      CANARY_LAST_ERROR="could not bind the live Mac session and catalog row"
phase4-coordinator/dist/deploy-pearl-vps.sh-4659-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4660-  else
phase4-coordinator/dist/deploy-pearl-vps.sh-4661-    CANARY_PROOF_RC=$?
phase4-coordinator/dist/deploy-pearl-vps.sh-4662-    CANARY_LAST_ERROR="trusted Mac proof failed (exit=$CANARY_PROOF_RC)"
phase4-coordinator/dist/deploy-pearl-vps.sh-4663-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4664-  CANARY_REMAINING_S=$((CANARY_RECOVERY_DEADLINE - SECONDS))
phase4-coordinator/dist/deploy-pearl-vps.sh-4665-  if [ "$CANARY_ATTEMPT" -lt "$CANARY_MAX_ATTEMPTS" ] && [ "$CANARY_REMAINING_S" -gt 0 ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4666-    echo "  waiting for exact catalog canary recovery ($CANARY_ATTEMPT/$CANARY_MAX_ATTEMPTS): $CANARY_LAST_ERROR" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4667-    CANARY_SLEEP_S=5
phase4-coordinator/dist/deploy-pearl-vps.sh-4668-    if [ "$CANARY_REMAINING_S" -lt "$CANARY_SLEEP_S" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4669-      CANARY_SLEEP_S="$CANARY_REMAINING_S"
phase4-coordinator/dist/deploy-pearl-vps.sh-4670-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4671-    sleep "$CANARY_SLEEP_S"
phase4-coordinator/dist/deploy-pearl-vps.sh-4672-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4673-  CANARY_ATTEMPT=$((CANARY_ATTEMPT + 1))
phase4-coordinator/dist/deploy-pearl-vps.sh-4674-done
phase4-coordinator/dist/deploy-pearl-vps.sh-4675-rm -f "$CANARY_CURL_CONFIG"
phase4-coordinator/dist/deploy-pearl-vps.sh-4676-if [ "$CANARY_OK" != "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4677-  echo "SPEC-023 canary failed after $((CANARY_ATTEMPT - 1)) full proof attempts within ${CANARY_RECOVERY_TIMEOUT_S}s: $CANARY_LAST_ERROR" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4678-  echo "  last status=$CANARY_STATUS body=$(head -c 300 "$CANARY_POOL_BODY" 2>/dev/null || true)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4679-  exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4680-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4681-
phase4-coordinator/dist/deploy-pearl-vps.sh-4682-if ! python3 - \
phase4-coordinator/dist/deploy-pearl-vps.sh-4683-  "$CANARY_INSTALLED_BODY" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4684-  "$CANARY_POOL_BODY" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4685-  "$CATALOG_CANARY_PROVIDER_ID" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4686-  "$AUTOTUNE_RELEASE_MANIFEST" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4687-  "$AUTOTUNE_TRUSTED_KEYS" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4688-  "$STATIC_AUTOTUNE_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4689-  "$STATIC_AUTOTUNE_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4690-  "$STATIC_DEMAND_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4691-  "$STATIC_DEMAND_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh:4692:  "$STATIC_RATE_CARD_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh:4693:  "$STATIC_RATE_CARD_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4694-  "$AUTOTUNE_TIER2_JSON" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-4695-import hashlib, json, pathlib, re, sys
phase4-coordinator/dist/deploy-pearl-vps.sh-4696-
phase4-coordinator/dist/deploy-pearl-vps.sh-4697-proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
phase4-coordinator/dist/deploy-pearl-vps.sh-4698-pool = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
phase4-coordinator/dist/deploy-pearl-vps.sh-4699-if proof.get("provider_id") != sys.argv[3] or not isinstance(proof.get("launchd_pid"), int):
phase4-coordinator/dist/deploy-pearl-vps.sh-4700-    raise SystemExit("canary proof is not bound to the selected provider and live process")
phase4-coordinator/dist/deploy-pearl-vps.sh-4701-local_status = proof.get("local_status", {})
phase4-coordinator/dist/deploy-pearl-vps.sh-4702-local_catalog = local_status.get("catalog", {})
phase4-coordinator/dist/deploy-pearl-vps.sh-4703-local_coordinator = local_status.get("coordinator", {})
phase4-coordinator/dist/deploy-pearl-vps.sh-4704-pool_row = str(pool.get("catalog_row_identity", "")).lower()
phase4-coordinator/dist/deploy-pearl-vps.sh-4705-if (
phase4-coordinator/dist/deploy-pearl-vps.sh-4706-    pool.get("provider_id") != sys.argv[3]
phase4-coordinator/dist/deploy-pearl-vps.sh-4707-    or pool.get("assigned_id") != proof.get("assigned_id")
phase4-coordinator/dist/deploy-pearl-vps.sh-4708-    or local_status.get("network_state") != "buyer_serving"
phase4-coordinator/dist/deploy-pearl-vps.sh-4709-    or local_coordinator.get("connected") is not True
phase4-coordinator/dist/deploy-pearl-vps.sh-4710-    or local_coordinator.get("session") != proof.get("assigned_id")
phase4-coordinator/dist/deploy-pearl-vps.sh-4711-    or re.fullmatch(r"[0-9a-f]{64}", pool_row) is None
phase4-coordinator/dist/deploy-pearl-vps.sh-4712-    or local_catalog.get("release_id") != pool.get("catalog_release_id")
phase4-coordinator/dist/deploy-pearl-vps.sh-4713-    or local_catalog.get("policy_version") != pool.get("catalog_policy_version")
phase4-coordinator/dist/deploy-pearl-vps.sh-4714-    or str(local_catalog.get("digest", "")).lower() != str(pool.get("catalog_candidate_sha256", "")).lower()
phase4-coordinator/dist/deploy-pearl-vps.sh-4715-    or local_catalog.get("signer_key_id") != pool.get("catalog_signer_key_id")
phase4-coordinator/dist/deploy-pearl-vps.sh-4716-    or str(local_catalog.get("row_identity", "")).lower() != pool_row
phase4-coordinator/dist/deploy-pearl-vps.sh-4717-):
phase4-coordinator/dist/deploy-pearl-vps.sh-4718-    raise SystemExit("canary local catalog proof is not bound to the coordinator-admitted envelope")
phase4-coordinator/dist/deploy-pearl-vps.sh-4719-actual = proof.get("files")
phase4-coordinator/dist/deploy-pearl-vps.sh-4720-if not isinstance(actual, dict):
phase4-coordinator/dist/deploy-pearl-vps.sh-4721-    raise SystemExit("canary proof is missing installed file hashes")
phase4-coordinator/dist/deploy-pearl-vps.sh-4722-expected = {}
phase4-coordinator/dist/deploy-pearl-vps.sh-4723-for raw_path in sys.argv[4:]:
phase4-coordinator/dist/deploy-pearl-vps.sh-4724-    path = pathlib.Path(raw_path)
phase4-coordinator/dist/deploy-pearl-vps.sh-4725-    expected[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
phase4-coordinator/dist/deploy-pearl-vps.sh-4726-if actual != expected:
phase4-coordinator/dist/deploy-pearl-vps.sh-4727-    missing = sorted(set(expected) - set(actual))
phase4-coordinator/dist/deploy-pearl-vps.sh-4728-    extra = sorted(set(actual) - set(expected))
phase4-coordinator/dist/deploy-pearl-vps.sh-4729-    changed = sorted(name for name in set(actual) & set(expected) if actual[name] != expected[name])
phase4-coordinator/dist/deploy-pearl-vps.sh:4730:    raise SystemExit(f"canary catalog byte mismatch: missing={missing} extra={extra} changed={changed}")
phase4-coordinator/dist/deploy-pearl-vps.sh-4731-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-4732-then
phase4-coordinator/dist/deploy-pearl-vps.sh-4733-  echo "SPEC-023 canary failed: installed catalog bytes do not match the verified deployment release" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4734-  exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4735-fi
phase4-coordinator/dist/deploy-pearl-vps.sh:4736:echo "  SPEC-023 exact-byte canary OK: selected provider's live process uses the verified catalog release"
phase4-coordinator/dist/deploy-pearl-vps.sh-4737-
phase4-coordinator/dist/deploy-pearl-vps.sh-4738-# R3+R4+R5 stats smoke check on STATS_DOMAIN.
phase4-coordinator/dist/deploy-pearl-vps.sh-4739-#
phase4-coordinator/dist/deploy-pearl-vps.sh-4740-# R5 ARCH MED-1: coordinator's `stats.enabled` defaults FALSE — when
phase4-coordinator/dist/deploy-pearl-vps.sh-4741-# it's not set or set to false, /v1/stats/* routes don't exist. Hitting
phase4-coordinator/dist/deploy-pearl-vps.sh-4742-# them blind would flag a perfectly valid stats-disabled deploy as
phase4-coordinator/dist/deploy-pearl-vps.sh-4743-# degraded. Parse `stats.enabled` from the same effective coordinator.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-4744-# the restarted service uses; gate the smoke check on it.
phase4-coordinator/dist/deploy-pearl-vps.sh-4745-STATS_ENABLED_LOCAL="$(yaml_block_value stats enabled)"
phase4-coordinator/dist/deploy-pearl-vps.sh-4746-if [ "$STATS_ENABLED_LOCAL" = "true" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4747-  STATS_SMOKE_NONCE="${BACKUP_TS:-$(date -u +%Y%m%dT%H%M%SZ)}-$$"
phase4-coordinator/dist/deploy-pearl-vps.sh-4748-  echo "  GET https://$STATS_DOMAIN/v1/stats/health?deploy_smoke=<nonce> -> expect 200"
phase4-coordinator/dist/deploy-pearl-vps.sh-4749-  # R4 CODE/SEC convergent HIGH — DON'T use `STATS=$(curl ... || echo 000)`:
phase4-coordinator/dist/deploy-pearl-vps.sh-4750-  # curl prints `000` to stdout AND exits non-zero on TLS/DNS failure, so
phase4-coordinator/dist/deploy-pearl-vps.sh-4751-  # the `|| echo 000` appends another `000` producing `STATS=000000` and
phase4-coordinator/dist/deploy-pearl-vps.sh-4752-  # silently passing the `[ "$STATS" = "000" ]` failure branch.
phase4-coordinator/dist/deploy-pearl-vps.sh-4753-  if ! STATS_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$STATS_DOMAIN/v1/stats/health?deploy_smoke=$STATS_SMOKE_NONCE" 2>/dev/null); then
phase4-coordinator/dist/deploy-pearl-vps.sh-4754-    STATS_STATUS="000"
phase4-coordinator/dist/deploy-pearl-vps.sh-4755-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4756-  if [ "$STATS_STATUS" != "200" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4757-    if [ "$STATS_STATUS" = "000" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4758-      echo "  ABORT: $STATS_DOMAIN /v1/stats/health unreachable (TLS handshake or DNS failed)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4759-    else
phase4-coordinator/dist/deploy-pearl-vps.sh-4760-      echo "  ABORT: $STATS_DOMAIN /v1/stats/health returned status=$STATS_STATUS (expected 200)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4761-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4762-    echo "  stats.enabled=true in $DEPLOY_CONFIG — public stats smoke is mandatory." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4763-    exit 9
phase4-coordinator/dist/deploy-pearl-vps.sh-4764-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4765-  echo "  ok: $STATS_DOMAIN /v1/stats/health responded 200"
phase4-coordinator/dist/deploy-pearl-vps.sh-4766-
phase4-coordinator/dist/deploy-pearl-vps.sh-4767-  echo "  GET https://$STATS_DOMAIN/v1/stats/overview?deploy_smoke=<nonce> with Malibu Origin -> expect 200 + CORS"
phase4-coordinator/dist/deploy-pearl-vps.sh-4768-  STATS_HEADERS="$(mktemp -t macprovider-stats-headers.XXXXXX)"
phase4-coordinator/dist/deploy-pearl-vps.sh-4769-  if ! STATS_OVERVIEW_STATUS=$(curl -sS -D "$STATS_HEADERS" -o /dev/null -w '%{http_code}' --max-time 10 -H "Origin: https://www.malibu.tech" "https://$STATS_DOMAIN/v1/stats/overview?deploy_smoke=$STATS_SMOKE_NONCE" 2>/dev/null); then
phase4-coordinator/dist/deploy-pearl-vps.sh-4770-    STATS_OVERVIEW_STATUS="000"
phase4-coordinator/dist/deploy-pearl-vps.sh-4771-  fi
--
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-421-_run_with_deadline_alarm 2 sh -c 'exit 0' ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-422-  fail "subprocess deadline helper must preserve successful commands"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-423-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-424-deadline_parser_tmp="$(mktemp)"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-425-trap 'rm -f "$token_validator_tmp" "$token_loader_tmp" "$canary_operator_guard_tmp" "$deadline_alarm_tmp" "$deadline_parser_tmp"; rm -rf "$token_file_dir" "$security_mock_dir"' EXIT
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-426-awk '/^_parse_model_hash_legacy_until\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" > "$deadline_parser_tmp"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-427-grep -qF '_parse_model_hash_legacy_until()' "$deadline_parser_tmp" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-428-  fail "deploy must keep an extractable MODEL_HASH_LEGACY_UNTIL parser"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-429-# shellcheck disable=SC1090
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-430-. "$deadline_parser_tmp"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-431-deadline='2030-01-02T03:04:05Z'
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-432-[ "$(_parse_model_hash_legacy_until "  $deadline  ")" = "$deadline" ] ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-433-  fail "legacy deadline parser must accept an unquoted scalar"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-434-[ "$(_parse_model_hash_legacy_until "  \"$deadline\"  ")" = "$deadline" ] ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-435-  fail "legacy deadline parser must strip matching double quotes"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-436-[ "$(_parse_model_hash_legacy_until "  '$deadline'  ")" = "$deadline" ] ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-437-  fail "legacy deadline parser must strip matching single quotes"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-438-[ -z "$(_parse_model_hash_legacy_until '   ')" ] ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-439-  fail "legacy deadline parser must preserve an absent deadline as empty"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-440-if _parse_model_hash_legacy_until '2030-01-02T03:04:05Z trailing' >/dev/null 2>&1; then
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-441-  fail "legacy deadline parser must reject multiple scalar tokens"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-442-fi
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-443-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-444-grep -q 'CATALOG_CANARY_SSH_TARGET is required' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-445-  fail "deploy must require a trusted canary host for exact installed-byte verification"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-446-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-447-grep -q 'StrictHostKeyChecking=yes' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-448-  fail "trusted canary verification must check the SSH host key"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-449-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-450-! grep -q '/usr/bin/proc_pidpath' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-451-  fail "Mac canary proof must not depend on nonexistent /usr/bin/proc_pidpath"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-452-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-453-grep -q 'assigned_id=\$CANARY_ASSIGNED_QUERY&details=deployment' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-454-  fail "deploy must gate completion on the exact proved provider session"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-455-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:456:proof_retry_line=$(grep -nF 'if run_catalog_canary_mac_proof "$CANARY_PROOF_TIMEOUT_S" > "$CANARY_INSTALLED_BODY"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-457-session_rebind_line=$(grep -nF 'read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY <<< "$CANARY_BINDING"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-458-session_query_line=$(grep -nF 'CANARY_STATUS=$(curl --config "$CANARY_CURL_CONFIG"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-459-[ -n "$proof_retry_line" ] && [ -n "$session_rebind_line" ] && [ -n "$session_query_line" ] &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-460-  [ "$proof_retry_line" -lt "$session_rebind_line" ] && [ "$session_rebind_line" -lt "$session_query_line" ] ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-461-  fail "each canary recovery attempt must re-prove the Mac and bind the query to that attempt's session"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-462-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-463-grep -q 'CANARY_RECOVERY_DEADLINE=' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-464-  grep -q '_run_with_deadline_alarm "$timeout_s" "${CANARY_SSH\[@\]}"' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-465-  grep -q 'rm -f "$CANARY_INSTALLED_BODY" "$CANARY_POOL_BODY"' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-466-  grep -q 'waiting for exact catalog canary recovery' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-467-  fail "deploy must retry full canary proof within a wall-clock deadline and discard stale attempt output"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-468-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-469-grep -q 'os.O_RDONLY | nofollow | nonblock' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-470-  fail "Mac proof must open untrusted file entries without blocking on special files"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-471-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-472-grep -q 'value.get("assigned_id") != sys.argv\[3\]' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-473-  fail "deploy must reject coordinator evidence for a different assigned session"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-474-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-475-grep -q 'local_status.get("network_state") != "buyer_serving"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-476-  fail "deploy must prove the canary Mac reports buyer-serving network state"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-477-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-478-grep -q 'value.get("buyer_serving") is not True' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-479-  fail "deploy canary must require explicit buyer-serving capacity"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-480-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-481-grep -q 'value.get("catalog_evidence_source") != "provider_reported"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-482-  fail "deploy must treat coordinator catalog fields as provider-reported compatibility evidence"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-483-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-484-grep -q 'value.get("catalog_admission_mode") != "current"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-485-  fail "deploy canary must reject legacy and previous catalog admissions"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-486-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-487-# The Mac proof hashes every name in its `names` tuple, and the exact-byte
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-488-# check compares that dict to the basenames of its expected argv files, so
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-489-# the two sets must be equal. Before this check the rate card and its sidecar
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-490-# were proven but never expected, so no canary could pass.
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-491-python3 - "$DEPLOY_SH" <<'PY' || fail "deploy canary expected-byte set must equal the file set the Mac proof hashes"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-492-import re, sys
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-493-text = open(sys.argv[1], encoding="utf-8").read()
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-494-names_block = re.search(r'\n    names = \(\n(.*?)\n    \)\n', text, re.S)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-495-if names_block is None:
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-496-    raise SystemExit("canary proof names tuple not found")
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-497-proven = set(re.findall(r'"([^"]+)"', names_block.group(1)))
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-498-check = re.search(r'  "\$CATALOG_CANARY_PROVIDER_ID" \\\n((?:  "\$[A-Z0-9_]+" \\\n)*)  "\$([A-Z0-9_]+)" <<\'PY\'\nimport hashlib, json, pathlib, re, sys\n\nproof = json.loads', text)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-499-if check is None:
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-500-    raise SystemExit("canary exact-byte check argv not found")
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-501-variables = re.findall(r'"\$([A-Z0-9_]+)"', check.group(1)) + [check.group(2)]
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-502-basenames = set()
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-503-for variable in variables:
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-504-    assignment = re.search(r'(?m)^' + variable + r'="[^"\n]*/([^/"\n]+)"$', text)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-505-    if assignment is None:
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-506-        raise SystemExit(f"no path assignment for {variable}")
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-507-    basenames.add(assignment.group(1))
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-508-if basenames != proven:
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-509-    raise SystemExit(f"proven={sorted(proven)} expected={sorted(basenames)}")
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-510-if "tier2-catalog.json" not in basenames or "rate-card.json.sig" not in basenames:
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-511-    raise SystemExit("expected set must include the Tier-2 catalog and the signed rate card")
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-512-PY
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-513-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-514-grep -q 'value.get("catalog_candidate_sha256") != sys.argv\[6\]' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-515-  fail "deploy canary must match the active candidate catalog digest"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-516-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-517-grep -q 'read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-518-  grep -q 'catalog.get("policy_version") != expected_policy_version' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-519-  grep -q 'catalog.get("row_identity", "")' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-520-  grep -q 'canary local catalog proof is not bound to the coordinator-admitted envelope' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-521-  fail "deploy canary must cross-bind exact policy and row between coordinator and Mac proof"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-522-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:523:grep -q 'canary catalog byte mismatch' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-524-  fail "deploy must compare exact installed canary catalog bytes before commit"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-525-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-526-grep -q 'canary provider identity mismatch' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-527-  grep -q 'live canary provider text vnode is stale or not the verified installation binary' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-528-  grep -q 'live canary provider status does not match the expected identity and catalog' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-529-  fail "exact-byte proof must bind the named provider, live process, and local catalog status"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-530-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-531-grep -q 'O_NOFOLLOW' "$DEPLOY_SH" && grep -q 'dir_fd=' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-532-  fail "trusted canary files must be opened no-follow through directory file descriptors"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-533-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-534-# SPEC-023 §3.7.8 Stage A (BYOM v0.2 slice 2b-ii): release.json decides whether
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-535-# the artifact feed and its sidecar are members of the immutable envelope; a
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-536-# bound release whose checkout lacks them aborts before upload, and when bound
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-537-# they are content-addressed, digest-recorded, uploaded, and staged beside the
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-538-# other feeds so verify-directory on Pearl sees the exact five-feed envelope.
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-539-grep -q 'AUTOTUNE_ARTIFACT_BOUND="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST"' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-540-  grep -q 'release.json binds autotune-artifacts.json but' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-541-  fail "deploy must read artifact-feed binding from release.json and abort a bound release without the pair"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-542-grep -q '("autotune-artifacts.json", pathlib.Path(sys.argv\[10\]))' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-543-  grep -q '("autotune-artifacts.json.sig", pathlib.Path(sys.argv\[11\]))' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-544-  fail "deploy must content-address the artifact feed pair into the release envelope when bound"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-545-grep -q '_append_deploy_input_digest "$STATIC_ARTIFACTS_JSON" "autotune-artifacts.json"' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-546-  grep -q '_append_deploy_input_digest "$STATIC_ARTIFACTS_SIG" "autotune-artifacts.json.sig"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-547-  fail "deploy must record the artifact feed pair in the deploy input manifest when bound"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-548-grep -q '$DEPLOY_TMP/autotune-artifacts.json \\$_autotune_stage/autotune-artifacts.json' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-549-  grep -q '$DEPLOY_TMP/autotune-artifacts.json.sig \\$_autotune_stage/autotune-artifacts.json.sig' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-550-  grep -q 'rate-card.json.sig$AUTOTUNE_ARTIFACT_INSTALL_LINES' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-551-  fail "deploy must stage the artifact feed pair into the release envelope beside the other feeds when bound"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-552-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-553-grep -q '/v1/demand-rank' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-554-  fail "deploy smoke must probe /v1/demand-rank"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-555-grep -q '/v1/rate-card.sig' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-556-  fail "deploy smoke must probe /v1/rate-card.sig"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-557-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-558-grep -q 'chmod o+x /opt/macprovider' "$DEPLOY_SH" &&

 succeeded in 131ms:
751a83a43 (HEAD -> fix/deploy-canary-rate-card-bytes, origin/fix/deploy-canary-rate-card-bytes) Expect the signed rate card in the deploy's exact-byte catalog canary

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '560,700p;950,1070p;4240,4385p;4590,4745p'" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
   560	  PINNED_RUNTIME_ARTIFACT_DIR="$PINNED_DEPLOY_INPUT_DIR/pearl-runtime-release"
   561	  install -d -m 0700 "$PINNED_RUNTIME_ARTIFACT_DIR"
   562	  GH_HOST=github.com bash "$REPO_ROOT/scripts/verify-pearl-runtime-release.sh" \
   563	    --tag "$COORDINATOR_RELEASE_VERSION" \
   564	    --expected-commit "$COORDINATOR_RELEASE_COMMIT" \
   565	    --repository "Augustas11/macprovider" \
   566	    --remote "origin" \
   567	    --deploy-artifacts-dir "$PINNED_RUNTIME_ARTIFACT_DIR"
   568	  PINNED_STATIC_FEEDS_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/dist/static"
   569	  PINNED_AUTOTUNE_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/catalog/autotune"
   570	  PINNED_SCRIPTS_DIR="$PINNED_DEPLOY_INPUT_DIR/scripts"
   571	else
   572	  PINNED_REPOSITORY_DIR="$REPO_ROOT"
   573	  CATALOG_VERIFIER_BUNDLE="$(_parse_catalog_verifier_bundle < "$PINNED_SCRIPTS_DIR/catalog-verifier-bundle.txt")" || exit 2
   574	fi
   575	
   576	# Email validator — RFC-conformant pre-validation is overkill; we just
   577	# need to reject metacharacters that would split a shell arg.
   578	if ! printf '%s' "$EMAIL" | grep -Eq '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
   579	  echo "aborting deploy: EMAIL is not a valid address: '$EMAIL'" >&2
   580	  exit 1
   581	fi
   582	if [ "$DRY_RUN_LOCAL" != "1" ]; then
   583	  _load_catalog_canary_auth_token
   584	  if ! printf '%s' "$CATALOG_CANARY_PROVIDER_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
   585	    echo "aborting deploy: CATALOG_CANARY_PROVIDER_ID is required and must be a safe provider ID" >&2
   586	    echo "  Select a provider expected to reconnect after restart; deployment commits only after pool admission." >&2
   587	    exit 1
   588	  fi
   589	  if ! _validate_catalog_canary_auth_token "$CATALOG_CANARY_AUTH_TOKEN"; then
   590	    echo "aborting deploy: CATALOG_CANARY_AUTH_TOKEN is required and must be a safe 32-512 character bearer token" >&2
   591	    echo "  Provide it via CATALOG_CANARY_AUTH_TOKEN, CATALOG_CANARY_AUTH_TOKEN_FILE, or macOS Keychain service=$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE account=$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT." >&2
   592	    echo "  The deploy will later prove this secret matches Pearl's coordinator operator key by SHA-256; it never copies key material from Pearl." >&2
   593	    exit 1
   594	  fi
   595	  if ! printf '%s' "$CATALOG_CANARY_SSH_TARGET" | grep -Eq '^([A-Za-z_][A-Za-z0-9._-]*@)?[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$'; then
   596	    echo "aborting deploy: CATALOG_CANARY_SSH_TARGET is required and must be a safe SSH target" >&2
   597	    exit 1
   598	  fi
   599	  if [ ! -f "$CATALOG_CANARY_SSH_KEY" ] || [ ! -r "$CATALOG_CANARY_SSH_KEY" ]; then
   600	    echo "aborting deploy: CATALOG_CANARY_SSH_KEY is not a readable regular file: $CATALOG_CANARY_SSH_KEY" >&2
   601	    exit 1
   602	  fi
   603	  if ! printf '%s' "$CATALOG_CANARY_INSTALL_DIR" | grep -Eq '^[A-Za-z0-9._/-]+$' ||
   604	     printf '%s' "/$CATALOG_CANARY_INSTALL_DIR/" | grep -Eq '/\.\.?/'; then
   605	    echo "aborting deploy: CATALOG_CANARY_INSTALL_DIR must be a safe path without parent traversal" >&2
   606	    exit 1
   607	  fi
   608	fi
   609	
   610	# R1 ARCH HIGH-2 — the baked-in vhost templates hardcode
   611	# server_name=coordinator.malibu.tech and the matching certbot live
   612	# paths. Refuse if $DOMAIN was overridden to something else; otherwise
   613	# we'd issue a cert for the override domain while installing a vhost
   614	# with a non-matching server_name.
   615	if [ "$DOMAIN" != "coordinator.malibu.tech" ]; then
   616	  echo "aborting deploy: DOMAIN override ($DOMAIN) does not match the baked-in vhost template" >&2
   617	  echo "  dist/nginx-coordinator.malibu.tech.conf has server_name=coordinator.malibu.tech hardcoded." >&2
   618	  echo "  Edit the conf file in lockstep, or remove the DOMAIN env override." >&2
   619	  exit 1
   620	fi
   621	if [ "${STATS_DOMAIN:-stats.malibu.tech}" != "stats.malibu.tech" ]; then
   622	  echo "aborting deploy: STATS_DOMAIN override (${STATS_DOMAIN}) does not match the baked-in vhost template" >&2
   623	  exit 1
   624	fi
   625	
   626	BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/coordinator-linux-amd64"
   627	CLI_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/coordinator-cli-linux-amd64"
   628	STATS_INVENTORY_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-inventory-sync-linux-amd64"
   629	STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"
   630	STATS_HARDWARE_VERIFIER_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-hardware-verifier-linux-amd64"
   631	CONFIG="$PINNED_DIST_DIR/coordinator.yaml"
   632	DEPLOY_CONFIG="$CONFIG"
   633	SERVICE="$PINNED_DIST_DIR/macprovider-coordinator.service"
   634	DEPLOY_RECOVER="$PINNED_DIST_DIR/coordinator-deploy-recover.sh"
   635	DEPLOY_GUARD="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-guard.conf"
   636	DEPLOY_RECOVERY_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-recovery.service"
   637	DEPLOY_WATCHDOG_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-watchdog.service"
   638	STATS_INVENTORY_SERVICE="$PINNED_DIST_DIR/stats-inventory-sync.service"
   639	STATS_INVENTORY_TIMER="$PINNED_DIST_DIR/stats-inventory-sync.timer"
   640	STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"
   641	STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"
   642	STATS_HARDWARE_VERIFIER_SERVICE="$PINNED_DIST_DIR/stats-hardware-verifier.service"
   643	STATS_HARDWARE_VERIFIER_TIMER="$PINNED_DIST_DIR/stats-hardware-verifier.timer"
   644	NGINX_SITE="$PINNED_DIST_DIR/nginx-coordinator.malibu.tech.conf"
   645	TCP_SYSCTL="$PINNED_DIST_DIR/sysctl.d/99-macprovider-tcp.conf"
   646	TCP_BBR_MODULES_LOAD="$PINNED_DIST_DIR/modules-load.d/tcp_bbr.conf"
   647	# SPEC-017 v0.1.8 Step 4.B — additional nginx artifacts the
   648	# coordinator vhost depends on:
   649	#   - stats-shared.conf is the http-context snippet declaring the
   650	#     `$public_rl_key` map, the per-endpoint `stats_*` zones, the
   651	#     `stats_public` cache, and the `stats_redacted` log format.
   652	#     Both the coordinator vhost and the stats vhost reference
   653	#     these names; without the snippet installed first, `nginx -t`
   654	#     fails (Step 4.B CODE r1 CRITICAL).
   655	#   - nginx-stats.malibu.tech.conf is the standalone
   656	#     `stats.malibu.tech` vhost.
   657	# Both files MUST exist before this deploy proceeds; they are
   658	# installed below alongside the coordinator vhost.
   659	NGINX_STATS_SHARED="$PINNED_DIST_DIR/nginx-snippets/stats-shared.conf"
   660	NGINX_STATS_SECHEADERS="$PINNED_DIST_DIR/nginx-snippets/stats-security-headers.conf"
   661	NGINX_STATS_CORS_429="$PINNED_DIST_DIR/nginx-snippets/cors-429.conf"
   662	NGINX_STATS_PROXY_PUBLIC="$PINNED_DIST_DIR/nginx-snippets/stats-proxy-public.conf"
   663	NGINX_STATS_PROXY_PARTNER="$PINNED_DIST_DIR/nginx-snippets/stats-proxy-partner.conf"
   664	NGINX_STATS_SITE="$PINNED_DIST_DIR/nginx-stats.malibu.tech.conf"
   665	# SPEC-023 signed recommendation feeds served on the buyer mux at
   666	# /v1/rate-card, /v1/demand-rank and /v1/autotune-candidates (+ .sig sidecars).
   667	# Files live in phase3-binary/dist/static/ in the repo. Deploy installs
   668	# them into /opt/macprovider/autotune/ for coordinator startup load.
   669	STATIC_FEEDS_DIR="$PINNED_STATIC_FEEDS_DIR"
   670	STATIC_DEMAND_JSON="$STATIC_FEEDS_DIR/demand-rank.json"
   671	STATIC_DEMAND_SIG="$STATIC_FEEDS_DIR/demand-rank.json.sig"
   672	STATIC_AUTOTUNE_JSON="$STATIC_FEEDS_DIR/autotune-candidates.json"
   673	STATIC_AUTOTUNE_SIG="$STATIC_FEEDS_DIR/autotune-candidates.json.sig"
   674	STATIC_RATE_CARD_JSON="$STATIC_FEEDS_DIR/rate-card.json"
   675	STATIC_RATE_CARD_SIG="$STATIC_FEEDS_DIR/rate-card.json.sig"
   676	STATIC_ARTIFACTS_JSON="$STATIC_FEEDS_DIR/autotune-artifacts.json"
   677	STATIC_ARTIFACTS_SIG="$STATIC_FEEDS_DIR/autotune-artifacts.json.sig"
   678	AUTOTUNE_RELEASE_MANIFEST="$PINNED_AUTOTUNE_DIR/release.json"
   679	AUTOTUNE_TRUSTED_KEYS="$PINNED_AUTOTUNE_DIR/trusted-keys.json"
   680	AUTOTUNE_TIER2_JSON="$PINNED_AUTOTUNE_DIR/tier2-catalog.json"
   681	AUTOTUNE_RELEASE_VERIFY="$PINNED_SCRIPTS_DIR/catalog-release.py"
   682	AUTOTUNE_TIER2_VERIFIER="$PINNED_SCRIPTS_DIR/sign-catalog.go"
   683	CATALOG_SOURCE="${CATALOG_SOURCE:-$AUTOTUNE_TIER2_JSON}"
   684	
   685	# Repository-level verification reads the complete source tree and Git history.
   686	# Execute immutable bytes archived from the signed release commit, while giving
   687	# the verifier read-only object access for the ledger comparison against that
   688	# commit's direct parent. Isolated Python plus the pinned base ref prevent the
   689	# caller's worktree, import path, or CATALOG_RELEASE_BASE_REF from weakening the
   690	# gate. The smaller verifier bundle remains authoritative for staged and remote
   691	# verify-directory checks.
   692	if [ "$DRY_RUN_LOCAL" = "1" ]; then
   693	  python3 -I "$PINNED_REPOSITORY_DIR/scripts/catalog-release.py" verify
   694	else
   695	  PINNED_GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"
   696	  env -u OPENSSL_BIN -u MACPROVIDER_INTAKE_AUDIT_DIR \
   697	    GIT_DIR="$PINNED_GIT_DIR" \
   698	    GIT_NO_REPLACE_OBJECTS=1 \
   699	    CATALOG_RELEASE_BASE_REF="$COORDINATOR_RELEASE_COMMIT^" \
   700	    python3 -I "$PINNED_REPOSITORY_DIR/scripts/catalog-release.py" verify
   950	    in_block && line ~ /^[^[:space:]#][^:]*:/ { exit }
   951	    in_block {
   952	      if (line ~ "^[[:space:]]*" key ":[[:space:]]*") {
   953	        sub("^[[:space:]]*" key ":[[:space:]]*", "", line)
   954	        gsub(/^"|"$/, "", line)
   955	        gsub(/^'\''|'\''$/, "", line)
   956	        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
   957	        print line
   958	        exit
   959	      }
   960	    }
   961	  ' "$file"
   962	}
   963	
   964	# Local validation may need to read Pearl's live coordinator.yaml in
   965	# CONFIG_MODE=preserve-live. Preserve env:NAME references because later gates
   966	# prove those runtime variables on Pearl; mask inline secret material before it
   967	# can land in a local temp file or logs.
   968	redact_dsn() {
   969	  sed -E 's#(postgres(ql)?://[^:/@[:space:]]+:)[^@[:space:]]+@#\1***@#g'
   970	}
   971	sanitize_live_config_for_local_validation() {
   972	  awk '
   973	    function indent_of(s) {
   974	      match(s, /^[[:space:]]*/)
   975	      return RLENGTH
   976	    }
   977	    function mask_scalar(s) {
   978	      sub(/:.*/, ": <MASKED>", s)
   979	      return s
   980	    }
   981	    function suppress_secret_continuation(s) {
   982	      skip_secret_block = 1
   983	      secret_block_indent = indent_of(s)
   984	    }
   985	    function mask_secret_scalar(s) {
   986	      suppress_secret_continuation(s)
   987	      return mask_scalar(s)
   988	    }
   989	    skip_secret_block && $0 ~ /^[[:space:]]*(#|$)/ { next }
   990	    skip_secret_block {
   991	      if (indent_of($0) > secret_block_indent) {
   992	        next
   993	      }
   994	      skip_secret_block = 0
   995	    }
   996	    /^[^[:space:]#][^:]*:[[:space:]]*/ {
   997	      in_auth = ($0 ~ /^auth:[[:space:]]*(#.*)?$/)
   998	      in_referrals = ($0 ~ /^referrals:[[:space:]]*(#.*)?$/)
   999	      in_secret_map = 0
  1000	    }
  1001	    in_auth && /^[[:space:]]*operator_keys:[[:space:]]*(#.*)?$/ {
  1002	      in_secret_map = 1
  1003	      secret_map_indent = indent_of($0)
  1004	      print
  1005	      next
  1006	    }
  1007	    in_referrals && /^[[:space:]]*hmac_keys:[[:space:]]*(#.*)?$/ {
  1008	      in_secret_map = 1
  1009	      secret_map_indent = indent_of($0)
  1010	      print
  1011	      next
  1012	    }
  1013	    in_secret_map && $0 !~ /^[[:space:]]*(#|$)/ {
  1014	      current_indent = indent_of($0)
  1015	      if (current_indent <= secret_map_indent) {
  1016	        in_secret_map = 0
  1017	      }
  1018	    }
  1019	    in_secret_map && /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*/ {
  1020	      if ($0 ~ /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*env:[A-Za-z_][A-Za-z0-9_]*([[:space:]]*(#.*)?)?$/) {
  1021	        suppress_secret_continuation($0)
  1022	        print
  1023	      } else {
  1024	        print mask_secret_scalar($0)
  1025	      }
  1026	      next
  1027	    }
  1028	    /^[[:space:]]*catalog_public_key:[[:space:]]*/ { print; next }
  1029	    /^[[:space:]]*[a-zA-Z0-9_]*(_key|_secret|_token|_dsn|dsn):[[:space:]]*/ {
  1030	      if ($0 ~ /^[[:space:]]*[a-zA-Z0-9_]*(_key|_secret|_token|_dsn|dsn):[[:space:]]*env:[A-Za-z_][A-Za-z0-9_]*([[:space:]]*(#.*)?)?$/) {
  1031	        suppress_secret_continuation($0)
  1032	        print
  1033	      } else {
  1034	        print mask_secret_scalar($0)
  1035	      }
  1036	      next
  1037	    }
  1038	    { print }
  1039		  ' | redact_dsn
  1040	}
  1041	reject_redacted_install_candidate() {
  1042	  local path="$1" label="$2"
  1043	  if grep -Eq '(<MASKED>|postgres(ql)?://[^[:space:]]+:\*\*\*@)' "$path"; then
  1044	    echo "aborting deploy: refusing to install redacted validation data as $label" >&2
  1045	    echo "  C2 timer migration install candidates must come from raw 0600 live config copies, never sanitized validation copies." >&2
  1046	    exit 5
  1047	  fi
  1048	}
  1049	normalize_yaml() {
  1050	  # Mask any field whose name ends in _key / _secret / _token, then strip
  1051	  # pure-comment lines and blanks so the drift check focuses on semantic
  1052	  # differences (values + structure) rather than comment-placement noise.
  1053	  sanitize_live_config_for_local_validation \
  1054	    | sed -E 's/^([[:space:]]*[a-zA-Z0-9_]*(_key|_secret|_token)):[[:space:]]*.*$/\1: <MASKED>/' \
  1055	    | sed -E 's/[[:space:]]+#.*$//' \
  1056	    | grep -vE '^[[:space:]]*(#|$)'
  1057	}
  1058	print_config_drift_diff() {
  1059	  redact_dsn | sed 's/^/    /' >&2
  1060	}
  1061	
  1062	# R5 ARCH M1 — early coherence check: if the operator set
  1063	# STATS_REQUIRED=1 but coordinator.yaml has stats.enabled=false (or
  1064	# unset), the deploy would restart the binary then exit 9 in step 8.
  1065	# Catch it BEFORE any SSH mutation.
  1066	assert_stats_required_matches_effective_config() {
  1067	  [ "${STATS_REQUIRED:-0}" = "1" ] || return 0
  1068	  _stats_enabled_pre="$(yaml_block_value stats enabled)"
  1069	  if [ "$_stats_enabled_pre" != "true" ]; then
  1070	    echo "aborting deploy: STATS_REQUIRED=1 but stats.enabled is not true in $DEPLOY_CONFIG ('$_stats_enabled_pre')." >&2
  4240	  # the smoke response to a predictable operator-Mac /tmp path. A
  4241	  # local attacker on the operator's workstation could pre-place a
  4242	  # symlink at /tmp/macprovider-catalog-current.json (or race the
  4243	  # curl -o open) to redirect the write. mktemp under umask 077
  4244	  # picks an unpredictable name with 0600 perms; cleanup rides the
  4245	  # unconditional EXIT trap registered above.
  4246	  CATALOG_SMOKE_TMP=$(umask 077 && mktemp -t macprovider-catalog-current.XXXXXXXX) || {
  4247	    echo "aborting smoke: mktemp failed" >&2
  4248	    exit 1
  4249	  }
  4250	  STATUS=$(curl -sS -o "$CATALOG_SMOKE_TMP" -w '%{http_code}' --max-time 10 --max-filesize 1048576 "https://$DOMAIN/catalog/current")
  4251	  if [ "$STATUS" != "200" ]; then
  4252	    echo "coordinator /catalog/current check failed: status=$STATUS body=$(head -c 300 "$CATALOG_SMOKE_TMP")" >&2
  4253	    exit 1
  4254	  fi
  4255	  # #292 R1 ARCH MED: `echo "$(python3 ...)"` under set -e is silent on
  4256	  # python failure — echo succeeds regardless, so invalid JSON (or a
  4257	  # 200 response body that isn't the catalog schema) prints
  4258	  # "catalog OK:" and the deploy proceeds. Assign first, check exit
  4259	  # explicitly, then echo.
  4260	  CATALOG_SUMMARY=$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("catalog_id=%s models=%d" % (c.get("catalog_id"), len(c.get("models", []))))' "$CATALOG_SMOKE_TMP") || {
  4261	    echo "coordinator /catalog/current smoke: python3 parse failed on 200 body (head -c 300: $(head -c 300 "$CATALOG_SMOKE_TMP"))" >&2
  4262	    exit 1
  4263	  }
  4264	  echo "  catalog OK: $CATALOG_SUMMARY"
  4265	fi
  4266	
  4267	# SPEC-023 signed recommendation feeds smoke (buyer mux via nginx).
  4268	log "  verifying coordinator can read autotune feeds as macprovider"
  4269	$SSH "set -e
  4270	  sudo -u macprovider test -r /opt/macprovider/autotune/current/autotune-candidates.json
  4271	  sudo -u macprovider test -r /opt/macprovider/autotune/current/demand-rank.json
  4272	  sudo -u macprovider test -r /opt/macprovider/autotune/current/rate-card.json
  4273	" || {
  4274	  echo "aborting smoke: macprovider cannot read /opt/macprovider/autotune/*" >&2
  4275	  exit 1
  4276	}
  4277	STATIC_SMOKE_DIR=$(umask 077 && mktemp -d -t macprovider-autotune-probe.XXXXXXXX) || {
  4278	  echo "aborting smoke: mktemp -d failed for autotune feed probe" >&2
  4279	  exit 1
  4280	}
  4281	for STATIC_SPEC in \
  4282	    "/v1/rate-card|rate-card.json|$STATIC_RATE_CARD_JSON" \
  4283	    "/v1/rate-card.sig|rate-card.json.sig|$STATIC_RATE_CARD_SIG" \
  4284	    "/v1/demand-rank|demand-rank.json|$STATIC_DEMAND_JSON" \
  4285	    "/v1/demand-rank.sig|demand-rank.json.sig|$STATIC_DEMAND_SIG" \
  4286	    "/v1/autotune-candidates|autotune-candidates.json|$STATIC_AUTOTUNE_JSON" \
  4287	    "/v1/autotune-candidates.sig|autotune-candidates.json.sig|$STATIC_AUTOTUNE_SIG"; do
  4288	  STATIC_PATH="${STATIC_SPEC%%|*}"
  4289	  STATIC_REST="${STATIC_SPEC#*|}"
  4290	  STATIC_NAME="${STATIC_REST%%|*}"
  4291	  STATIC_EXPECTED="${STATIC_REST#*|}"
  4292	  STATIC_SMOKE_BODY="$STATIC_SMOKE_DIR/$STATIC_NAME"
  4293	  echo "  GET https://$DOMAIN$STATIC_PATH -> expect 200"
  4294	  STATUS=$(curl -sS -o "$STATIC_SMOKE_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 "https://$DOMAIN$STATIC_PATH")
  4295	  if [ "$STATUS" != "200" ]; then
  4296	    echo "SPEC-023 autotune feed smoke failed: $STATIC_PATH status=$STATUS body=$(head -c 200 "$STATIC_SMOKE_BODY")" >&2
  4297	    exit 1
  4298	  fi
  4299	  if ! cmp -s "$STATIC_EXPECTED" "$STATIC_SMOKE_BODY"; then
  4300	    echo "SPEC-023 autotune feed smoke failed: $STATIC_PATH bytes differ from staged release" >&2
  4301	    exit 1
  4302	  fi
  4303	done
  4304	cp "$AUTOTUNE_RELEASE_MANIFEST" "$STATIC_SMOKE_DIR/release.json"
  4305	cp "$AUTOTUNE_TRUSTED_KEYS" "$STATIC_SMOKE_DIR/trusted-keys.json"
  4306	cp "$AUTOTUNE_TIER2_JSON" "$STATIC_SMOKE_DIR/tier2-catalog.json"
  4307	cp "$STATIC_RATE_CARD_JSON" "$STATIC_SMOKE_DIR/rate-card.json"
  4308	cp "$STATIC_RATE_CARD_SIG" "$STATIC_SMOKE_DIR/rate-card.json.sig"
  4309	python3 "$AUTOTUNE_RELEASE_VERIFY" verify-directory --directory "$STATIC_SMOKE_DIR"
  4310	AUTOTUNE_STATUS_BODY="$STATIC_SMOKE_DIR/autotune-release-status.json"
  4311	STATUS=$(curl -sS -o "$AUTOTUNE_STATUS_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 "https://$DOMAIN/v1/autotune-release")
  4312	if [ "$STATUS" != "200" ]; then
  4313	  echo "SPEC-023 autotune release status failed: status=$STATUS body=$(head -c 200 "$AUTOTUNE_STATUS_BODY")" >&2
  4314	  exit 1
  4315	fi
  4316	python3 - "$AUTOTUNE_STATUS_BODY" "$AUTOTUNE_RELEASE_ID" <<'PY'
  4317	import json, sys
  4318	status = json.load(open(sys.argv[1], encoding="utf-8"))
  4319	if status.get("status") != "live_verified" or status.get("release_id") != sys.argv[2]:
  4320	    raise SystemExit("coordinator autotune release metadata does not match activated release")
  4321	for name in ("autotune_candidates", "demand_rank", "rate_card"):
  4322	    feed = status.get("feeds", {}).get(name, {})
  4323	    if len(feed.get("sha256", "")) != 64 or not feed.get("signer_key_id"):
  4324	        raise SystemExit(f"coordinator autotune release metadata is incomplete for {name}")
  4325	PY
  4326	echo "  SPEC-023 autotune feeds exact-byte and signature verification OK"
  4327	
  4328	# A perfect catalog endpoint does not prove the exact canary process completed
  4329	# the hello compatibility gate. First prove the live Mac process and capture its
  4330	# assigned coordinator session; then query authenticated coordinator evidence
  4331	# for that exact session below.
  4332	CANARY_POOL_BODY="$STATIC_SMOKE_DIR/catalog-canary-pool.json"
  4333	CANARY_CURL_CONFIG="$STATIC_SMOKE_DIR/catalog-canary-curl.conf"
  4334	
  4335	# Provider hello fields are authenticated self-report, so they are not exact
  4336	# installation proof. Read the release bundle from the operator-controlled
  4337	# canary Mac over host-key-checked SSH and compare every shipped catalog file
  4338	# with the locally verified release. This makes the deployment commit depend on
  4339	# independent canary-host custody of the exact bytes, not on replayable public
  4340	# catalog identifiers in a provider hello.
  4341	CANARY_INSTALLED_BODY="$STATIC_SMOKE_DIR/catalog-canary-installed.json"
  4342	CANARY_SSH=(
  4343	  ssh
  4344	  -i "$CATALOG_CANARY_SSH_KEY"
  4345	  -o BatchMode=yes
  4346	  -o IdentitiesOnly=yes
  4347	  -o StrictHostKeyChecking=yes
  4348	  -o ConnectTimeout=10
  4349	  -o ServerAliveInterval=15
  4350	  -o ServerAliveCountMax=3
  4351	  "$CATALOG_CANARY_SSH_TARGET"
  4352	)
  4353	run_catalog_canary_mac_proof() {
  4354	  local timeout_s="$1"
  4355	  _run_with_deadline_alarm "$timeout_s" "${CANARY_SSH[@]}" python3 - \
  4356	  "$CATALOG_CANARY_INSTALL_DIR" \
  4357	  "$CATALOG_CANARY_PROVIDER_ID" \
  4358	  "$AUTOTUNE_RELEASE_ID" \
  4359	  "$AUTOTUNE_POLICY_VERSION" \
  4360	  "$AUTOTUNE_CANDIDATE_SHA256" \
  4361	  "$AUTOTUNE_CANDIDATE_SIGNER_KEY_ID" <<'PY'
  4362	import hashlib, json, os, plistlib, re, stat, subprocess, sys, urllib.request
  4363	
  4364	(
  4365	    catalog_path,
  4366	    expected_provider_id,
  4367	    expected_release_id,
  4368	    expected_policy_version,
  4369	    expected_digest,
  4370	    expected_signer,
  4371	) = sys.argv[1:]
  4372	home = os.path.expanduser("~")
  4373	nofollow = getattr(os, "O_NOFOLLOW", 0)
  4374	nonblock = getattr(os, "O_NONBLOCK", 0)
  4375	directory_flags = os.O_RDONLY | os.O_DIRECTORY | nofollow
  4376	
  4377	def open_dir(path):
  4378	    if os.path.isabs(path):
  4379	        current = os.open("/", directory_flags)
  4380	        parts = [part for part in path.split("/") if part]
  4381	    else:
  4382	        current = os.open(home, directory_flags)
  4383	        parts = [part for part in path.split("/") if part]
  4384	    try:
  4385	        for part in parts:
  4590	}
  4591	
  4592	# A coordinator restart can make a healthy provider rotate its PID and assigned
  4593	# session while its recovery watchdog drains in-flight work. Retry the complete
  4594	# Mac proof and bind each admission query to the session from that same attempt;
  4595	# never carry an assigned_id across retries. This mirrors the signed updater's
  4596	# full-proof retry and keeps every success predicate fail-closed.
  4597	CANARY_PROVIDER_QUERY=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CATALOG_CANARY_PROVIDER_ID")
  4598	(umask 077 && printf 'header = "Authorization: Bearer %s"\n' "$CATALOG_CANARY_AUTH_TOKEN" > "$CANARY_CURL_CONFIG")
  4599	CANARY_OK=0
  4600	CANARY_LAST_ERROR="canary proof did not start"
  4601	CANARY_STATUS="000"
  4602	CANARY_ATTEMPT=1
  4603	CANARY_MAX_ATTEMPTS=36
  4604	CANARY_RECOVERY_TIMEOUT_S=180
  4605	CANARY_RECOVERY_DEADLINE=$((SECONDS + CANARY_RECOVERY_TIMEOUT_S))
  4606	while [ "$CANARY_ATTEMPT" -le "$CANARY_MAX_ATTEMPTS" ] && [ "$SECONDS" -lt "$CANARY_RECOVERY_DEADLINE" ]; do
  4607	  rm -f "$CANARY_INSTALLED_BODY" "$CANARY_POOL_BODY"
  4608	  CANARY_PROOF_ERROR="$STATIC_SMOKE_DIR/catalog-canary-proof.err"
  4609	  CANARY_REMAINING_S=$((CANARY_RECOVERY_DEADLINE - SECONDS))
  4610	  CANARY_PROOF_TIMEOUT_S=45
  4611	  if [ "$CANARY_REMAINING_S" -lt "$CANARY_PROOF_TIMEOUT_S" ]; then
  4612	    CANARY_PROOF_TIMEOUT_S="$CANARY_REMAINING_S"
  4613	  fi
  4614	  if run_catalog_canary_mac_proof "$CANARY_PROOF_TIMEOUT_S" > "$CANARY_INSTALLED_BODY" 2> "$CANARY_PROOF_ERROR"; then
  4615	    CANARY_BINDING=$(python3 - "$CANARY_INSTALLED_BODY" <<'PY'
  4616	import json, pathlib, re, sys
  4617	proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
  4618	assigned_id = proof.get("assigned_id")
  4619	row_identity = proof.get("local_status", {}).get("catalog", {}).get("row_identity")
  4620	if not isinstance(assigned_id, str) or not assigned_id or any(ch.isspace() for ch in assigned_id):
  4621	    raise SystemExit("canary proof has no safe assigned coordinator session")
  4622	if re.fullmatch(r"[0-9a-f]{64}", str(row_identity).lower()) is None:
  4623	    raise SystemExit("canary proof has no exact catalog row identity")
  4624	print(assigned_id, str(row_identity).lower())
  4625	PY
  4626	) || CANARY_BINDING=""
  4627	    if [ -n "$CANARY_BINDING" ]; then
  4628	      read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY <<< "$CANARY_BINDING"
  4629	      CANARY_ASSIGNED_QUERY=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CANARY_ASSIGNED_ID")
  4630	      CANARY_STATUS=$(curl --config "$CANARY_CURL_CONFIG" -sS -o "$CANARY_POOL_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 \
  4631	        "https://$DOMAIN/v1/pool/check?provider_id=$CANARY_PROVIDER_QUERY&assigned_id=$CANARY_ASSIGNED_QUERY&details=deployment" || true)
  4632	      if [ "$CANARY_STATUS" = "200" ] && python3 - \
  4633	        "$CANARY_POOL_BODY" "$CATALOG_CANARY_PROVIDER_ID" "$CANARY_ASSIGNED_ID" \
  4634	        "$AUTOTUNE_RELEASE_ID" "$AUTOTUNE_POLICY_VERSION" "$AUTOTUNE_CANDIDATE_SHA256" \
  4635	        "$AUTOTUNE_CANDIDATE_SIGNER_KEY_ID" "$CANARY_CATALOG_ROW_IDENTITY" <<'PY'
  4636	import json, sys
  4637	value = json.load(open(sys.argv[1], encoding="utf-8"))
  4638	if (
  4639	    value.get("provider_id") != sys.argv[2]
  4640	    or value.get("assigned_id") != sys.argv[3]
  4641	    or value.get("buyer_serving") is not True
  4642	    or value.get("catalog_evidence_source") != "provider_reported"
  4643	    or value.get("catalog_admission_mode") != "current"
  4644	    or value.get("catalog_release_id") != sys.argv[4]
  4645	    or value.get("catalog_policy_version") != sys.argv[5]
  4646	    or value.get("catalog_candidate_sha256") != sys.argv[6]
  4647	    or value.get("catalog_signer_key_id") != sys.argv[7]
  4648	    or str(value.get("catalog_row_identity", "")).lower() != sys.argv[8]
  4649	):
  4650	    raise SystemExit(1)
  4651	PY
  4652	      then
  4653	        CANARY_OK=1
  4654	        break
  4655	      fi
  4656	      CANARY_LAST_ERROR="exact session $CANARY_ASSIGNED_ID was not buyer-serving (status=$CANARY_STATUS)"
  4657	    else
  4658	      CANARY_LAST_ERROR="could not bind the live Mac session and catalog row"
  4659	    fi
  4660	  else
  4661	    CANARY_PROOF_RC=$?
  4662	    CANARY_LAST_ERROR="trusted Mac proof failed (exit=$CANARY_PROOF_RC)"
  4663	  fi
  4664	  CANARY_REMAINING_S=$((CANARY_RECOVERY_DEADLINE - SECONDS))
  4665	  if [ "$CANARY_ATTEMPT" -lt "$CANARY_MAX_ATTEMPTS" ] && [ "$CANARY_REMAINING_S" -gt 0 ]; then
  4666	    echo "  waiting for exact catalog canary recovery ($CANARY_ATTEMPT/$CANARY_MAX_ATTEMPTS): $CANARY_LAST_ERROR" >&2
  4667	    CANARY_SLEEP_S=5
  4668	    if [ "$CANARY_REMAINING_S" -lt "$CANARY_SLEEP_S" ]; then
  4669	      CANARY_SLEEP_S="$CANARY_REMAINING_S"
  4670	    fi
  4671	    sleep "$CANARY_SLEEP_S"
  4672	  fi
  4673	  CANARY_ATTEMPT=$((CANARY_ATTEMPT + 1))
  4674	done
  4675	rm -f "$CANARY_CURL_CONFIG"
  4676	if [ "$CANARY_OK" != "1" ]; then
  4677	  echo "SPEC-023 canary failed after $((CANARY_ATTEMPT - 1)) full proof attempts within ${CANARY_RECOVERY_TIMEOUT_S}s: $CANARY_LAST_ERROR" >&2
  4678	  echo "  last status=$CANARY_STATUS body=$(head -c 300 "$CANARY_POOL_BODY" 2>/dev/null || true)" >&2
  4679	  exit 1
  4680	fi
  4681	
  4682	if ! python3 - \
  4683	  "$CANARY_INSTALLED_BODY" \
  4684	  "$CANARY_POOL_BODY" \
  4685	  "$CATALOG_CANARY_PROVIDER_ID" \
  4686	  "$AUTOTUNE_RELEASE_MANIFEST" \
  4687	  "$AUTOTUNE_TRUSTED_KEYS" \
  4688	  "$STATIC_AUTOTUNE_JSON" \
  4689	  "$STATIC_AUTOTUNE_SIG" \
  4690	  "$STATIC_DEMAND_JSON" \
  4691	  "$STATIC_DEMAND_SIG" \
  4692	  "$STATIC_RATE_CARD_JSON" \
  4693	  "$STATIC_RATE_CARD_SIG" \
  4694	  "$AUTOTUNE_TIER2_JSON" <<'PY'
  4695	import hashlib, json, pathlib, re, sys
  4696	
  4697	proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
  4698	pool = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
  4699	if proof.get("provider_id") != sys.argv[3] or not isinstance(proof.get("launchd_pid"), int):
  4700	    raise SystemExit("canary proof is not bound to the selected provider and live process")
  4701	local_status = proof.get("local_status", {})
  4702	local_catalog = local_status.get("catalog", {})
  4703	local_coordinator = local_status.get("coordinator", {})
  4704	pool_row = str(pool.get("catalog_row_identity", "")).lower()
  4705	if (
  4706	    pool.get("provider_id") != sys.argv[3]
  4707	    or pool.get("assigned_id") != proof.get("assigned_id")
  4708	    or local_status.get("network_state") != "buyer_serving"
  4709	    or local_coordinator.get("connected") is not True
  4710	    or local_coordinator.get("session") != proof.get("assigned_id")
  4711	    or re.fullmatch(r"[0-9a-f]{64}", pool_row) is None
  4712	    or local_catalog.get("release_id") != pool.get("catalog_release_id")
  4713	    or local_catalog.get("policy_version") != pool.get("catalog_policy_version")
  4714	    or str(local_catalog.get("digest", "")).lower() != str(pool.get("catalog_candidate_sha256", "")).lower()
  4715	    or local_catalog.get("signer_key_id") != pool.get("catalog_signer_key_id")
  4716	    or str(local_catalog.get("row_identity", "")).lower() != pool_row
  4717	):
  4718	    raise SystemExit("canary local catalog proof is not bound to the coordinator-admitted envelope")
  4719	actual = proof.get("files")
  4720	if not isinstance(actual, dict):
  4721	    raise SystemExit("canary proof is missing installed file hashes")
  4722	expected = {}
  4723	for raw_path in sys.argv[4:]:
  4724	    path = pathlib.Path(raw_path)
  4725	    expected[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
  4726	if actual != expected:
  4727	    missing = sorted(set(expected) - set(actual))
  4728	    extra = sorted(set(actual) - set(expected))
  4729	    changed = sorted(name for name in set(actual) & set(expected) if actual[name] != expected[name])
  4730	    raise SystemExit(f"canary catalog byte mismatch: missing={missing} extra={extra} changed={changed}")
  4731	PY
  4732	then
  4733	  echo "SPEC-023 canary failed: installed catalog bytes do not match the verified deployment release" >&2
  4734	  exit 1
  4735	fi
  4736	echo "  SPEC-023 exact-byte canary OK: selected provider's live process uses the verified catalog release"
  4737	
  4738	# R3+R4+R5 stats smoke check on STATS_DOMAIN.
  4739	#
  4740	# R5 ARCH MED-1: coordinator's `stats.enabled` defaults FALSE — when
  4741	# it's not set or set to false, /v1/stats/* routes don't exist. Hitting
  4742	# them blind would flag a perfectly valid stats-disabled deploy as
  4743	# degraded. Parse `stats.enabled` from the same effective coordinator.yaml
  4744	# the restarted service uses; gate the smoke check on it.
  4745	STATS_ENABLED_LOCAL="$(yaml_block_value stats enabled)"

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '4360,4595p'" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
  4360	  "$AUTOTUNE_CANDIDATE_SHA256" \
  4361	  "$AUTOTUNE_CANDIDATE_SIGNER_KEY_ID" <<'PY'
  4362	import hashlib, json, os, plistlib, re, stat, subprocess, sys, urllib.request
  4363	
  4364	(
  4365	    catalog_path,
  4366	    expected_provider_id,
  4367	    expected_release_id,
  4368	    expected_policy_version,
  4369	    expected_digest,
  4370	    expected_signer,
  4371	) = sys.argv[1:]
  4372	home = os.path.expanduser("~")
  4373	nofollow = getattr(os, "O_NOFOLLOW", 0)
  4374	nonblock = getattr(os, "O_NONBLOCK", 0)
  4375	directory_flags = os.O_RDONLY | os.O_DIRECTORY | nofollow
  4376	
  4377	def open_dir(path):
  4378	    if os.path.isabs(path):
  4379	        current = os.open("/", directory_flags)
  4380	        parts = [part for part in path.split("/") if part]
  4381	    else:
  4382	        current = os.open(home, directory_flags)
  4383	        parts = [part for part in path.split("/") if part]
  4384	    try:
  4385	        for part in parts:
  4386	            if part in {".", ".."}:
  4387	                raise SystemExit(f"unsafe canary path component: {part}")
  4388	            next_fd = os.open(part, directory_flags, dir_fd=current)
  4389	            os.close(current)
  4390	            current = next_fd
  4391	        return current
  4392	    except BaseException:
  4393	        os.close(current)
  4394	        raise
  4395	
  4396	def read_regular_at(directory_fd, name, limit, require_owner=True):
  4397	    fd = os.open(name, os.O_RDONLY | nofollow | nonblock, dir_fd=directory_fd)
  4398	    try:
  4399	        info = os.fstat(fd)
  4400	        if not stat.S_ISREG(info.st_mode):
  4401	            raise SystemExit(f"canary path is not a regular file: {name}")
  4402	        if require_owner and info.st_uid != os.getuid():
  4403	            raise SystemExit(f"canary file has unexpected owner: {name}")
  4404	        if info.st_size > limit:
  4405	            raise SystemExit(f"oversized canary file: {name}")
  4406	        chunks = []
  4407	        remaining = limit + 1
  4408	        while remaining:
  4409	            chunk = os.read(fd, min(65536, remaining))
  4410	            if not chunk:
  4411	                break
  4412	            chunks.append(chunk)
  4413	            remaining -= len(chunk)
  4414	        value = b"".join(chunks)
  4415	        if len(value) > limit:
  4416	            raise SystemExit(f"oversized canary file: {name}")
  4417	        return value, info
  4418	    finally:
  4419	        os.close(fd)
  4420	
  4421	def open_parent_and_name(path):
  4422	    normalized = os.path.normpath(path)
  4423	    parent, name = os.path.split(normalized)
  4424	    if not name or name in {".", ".."}:
  4425	        raise SystemExit(f"unsafe canary file path: {path}")
  4426	    return open_dir(parent or "."), name
  4427	
  4428	def running_text_vnode_path(pid, binary_info, expected_binary, runner=subprocess.run):
  4429	    fields = runner(
  4430	        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-F", "Dfin"],
  4431	        check=True,
  4432	        stdout=subprocess.PIPE,
  4433	        stderr=subprocess.PIPE,
  4434	        text=True,
  4435	        timeout=10,
  4436	    ).stdout.splitlines()
  4437	    text_device = text_inode = text_path = None
  4438	    for field in fields:
  4439	        if field.startswith("f"):
  4440	            text_device = text_inode = text_path = None
  4441	        elif field.startswith("D"):
  4442	            try:
  4443	                text_device = int(field[1:], 0)
  4444	            except ValueError:
  4445	                raise SystemExit("lsof returned an invalid text-vnode device")
  4446	        elif field.startswith("i"):
  4447	            try:
  4448	                text_inode = int(field[1:])
  4449	            except ValueError:
  4450	                raise SystemExit("lsof returned an invalid text-vnode inode")
  4451	        elif field.startswith("n"):
  4452	            text_path = field[1:]
  4453	        normalized_text_path = (
  4454	            os.path.normpath(text_path.removesuffix(" (deleted)"))
  4455	            if text_path is not None
  4456	            else None
  4457	        )
  4458	        if (
  4459	            text_device == binary_info.st_dev
  4460	            and text_inode == binary_info.st_ino
  4461	            and normalized_text_path == expected_binary
  4462	        ):
  4463	            return normalized_text_path
  4464	    return None
  4465	
  4466	catalog_fd = open_dir(catalog_path)
  4467	install_path = os.path.dirname(os.path.normpath(catalog_path)) or "."
  4468	install_fd = open_dir(install_path)
  4469	config_fd = provider_config_fd = binary_fd = None
  4470	try:
  4471	    provider_config_fd = open_dir(".config/macprovider")
  4472	    provider_bytes, _ = read_regular_at(provider_config_fd, "provider_id", 1024)
  4473	    provider_id = provider_bytes.decode("utf-8").strip()
  4474	    if provider_id != expected_provider_id:
  4475	        raise SystemExit(
  4476	            f"canary provider identity mismatch: expected={expected_provider_id} actual={provider_id}"
  4477	        )
  4478	
  4479	    plist_dir_fd = open_dir("Library/LaunchAgents")
  4480	    try:
  4481	        plist_bytes, _ = read_regular_at(
  4482	            plist_dir_fd, "live.malibu.provider.plist", 1024 * 1024
  4483	        )
  4484	    finally:
  4485	        os.close(plist_dir_fd)
  4486	    plist = plistlib.loads(plist_bytes)
  4487	    arguments = plist.get("ProgramArguments")
  4488	    if not isinstance(arguments, list) or len(arguments) < 4 or arguments[1:3] != ["serve", "--config"]:
  4489	        raise SystemExit("canary provider LaunchAgent has unexpected ProgramArguments")
  4490	
  4491	    binary_fd = os.open(
  4492	        "macprovider-cli", os.O_RDONLY | nofollow | nonblock, dir_fd=install_fd
  4493	    )
  4494	    binary_info = os.fstat(binary_fd)
  4495	    if not stat.S_ISREG(binary_info.st_mode) or binary_info.st_uid != os.getuid() or binary_info.st_mode & 0o111 == 0:
  4496	        raise SystemExit("canary installation binary is not a safe executable")
  4497	    install_absolute = install_path if os.path.isabs(install_path) else os.path.join(home, install_path)
  4498	    expected_binary = os.path.normpath(os.path.join(install_absolute, "macprovider-cli"))
  4499	    if os.path.normpath(arguments[0]) != expected_binary:
  4500	        raise SystemExit("canary LaunchAgent does not use the catalog installation root")
  4501	
  4502	    launchd = subprocess.run(
  4503	        ["launchctl", "print", f"gui/{os.getuid()}/live.malibu.provider"],
  4504	        check=True,
  4505	        stdout=subprocess.PIPE,
  4506	        stderr=subprocess.PIPE,
  4507	        text=True,
  4508	        timeout=10,
  4509	    ).stdout
  4510	    match = re.search(r"(?m)^\s*pid = ([0-9]+)\s*$", launchd)
  4511	    if match is None:
  4512	        raise SystemExit("canary provider LaunchAgent has no live PID")
  4513	    pid = int(match.group(1))
  4514	    process_path = running_text_vnode_path(pid, binary_info, expected_binary)
  4515	    if process_path is None:
  4516	        raise SystemExit("live canary provider text vnode is stale or not the verified installation binary")
  4517	
  4518	    config_fd, config_name = open_parent_and_name(arguments[3])
  4519	    config_bytes, _ = read_regular_at(config_fd, config_name, 1024 * 1024)
  4520	    config_text = config_bytes.decode("utf-8")
  4521	    port_match = re.search(r'(?m)^\s*port:\s*"?([0-9]+)"?\s*(?:#.*)?$', config_text)
  4522	    if port_match is None or not (1 <= int(port_match.group(1)) <= 65535):
  4523	        raise SystemExit("canary provider config has no valid local status port")
  4524	    port = int(port_match.group(1))
  4525	    listener = subprocess.run(
  4526	        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
  4527	        check=False,
  4528	        stdout=subprocess.PIPE,
  4529	        stderr=subprocess.PIPE,
  4530	        text=True,
  4531	        timeout=10,
  4532	    )
  4533	    if str(pid) not in listener.stdout.split():
  4534	        raise SystemExit("live canary provider PID does not own its configured status port")
  4535	    class NoRedirect(urllib.request.HTTPRedirectHandler):
  4536	        def redirect_request(self, _request, _fp, _code, _message, _headers, _new_url):
  4537	            raise RuntimeError("canary local status redirect refused")
  4538	    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
  4539	    with opener.open(f"http://127.0.0.1:{port}/v1/status", timeout=10) as response:
  4540	        if response.status != 200:
  4541	            raise SystemExit(f"canary local status returned HTTP {response.status}")
  4542	        local_status = json.loads(response.read(1024 * 1024))
  4543	    catalog = local_status.get("catalog")
  4544	    coordinator = local_status.get("coordinator")
  4545	    assigned_id = coordinator.get("session") if isinstance(coordinator, dict) else None
  4546	    if (
  4547	        local_status.get("provider_id") != expected_provider_id
  4548	        or local_status.get("network_state") != "buyer_serving"
  4549	        or not isinstance(coordinator, dict)
  4550	        or coordinator.get("connected") is not True
  4551	        or not isinstance(assigned_id, str)
  4552	        or not assigned_id
  4553	        or not isinstance(catalog, dict)
  4554	        or catalog.get("release_id") != expected_release_id
  4555	        or catalog.get("policy_version") != expected_policy_version
  4556	        or catalog.get("digest") != expected_digest
  4557	        or catalog.get("signer_key_id") != expected_signer
  4558	        or re.fullmatch(r"[0-9a-f]{64}", str(catalog.get("row_identity", "")).lower()) is None
  4559	    ):
  4560	        raise SystemExit("live canary provider status does not match the expected identity and catalog")
  4561	
  4562	    names = (
  4563	        "release.json",
  4564	        "trusted-keys.json",
  4565	        "autotune-candidates.json",
  4566	        "autotune-candidates.json.sig",
  4567	        "demand-rank.json",
  4568	        "demand-rank.json.sig",
  4569	        "rate-card.json",
  4570	        "rate-card.json.sig",
  4571	        "tier2-catalog.json",
  4572	    )
  4573	    hashes = {}
  4574	    for name in names:
  4575	        payload, _ = read_regular_at(catalog_fd, name, 2 * 1024 * 1024)
  4576	        hashes[name] = hashlib.sha256(payload).hexdigest()
  4577	    print(json.dumps({
  4578	        "provider_id": provider_id,
  4579	        "assigned_id": assigned_id,
  4580	        "launchd_pid": pid,
  4581	        "executable_path": process_path,
  4582	        "local_status": local_status,
  4583	        "files": hashes,
  4584	    }, sort_keys=True))
  4585	finally:
  4586	    for fd in (config_fd, provider_config_fd, binary_fd, install_fd, catalog_fd):
  4587	        if fd is not None:
  4588	            os.close(fd)
  4589	PY
  4590	}
  4591	
  4592	# A coordinator restart can make a healthy provider rotate its PID and assigned
  4593	# session while its recovery watchdog drains in-flight work. Retry the complete
  4594	# Mac proof and bind each admission query to the session from that same attempt;
  4595	# never carry an assigned_id across retries. This mirrors the signed updater's

codex
The source trace shows the canary proof hashes nine names, including `rate-card.json` and its signature, while the post-loop verifier now hashes the same nine basenames from the pinned release inputs. Because the verifier compares dictionaries with `actual != expected`, any omitted, extra, or byte-different rate-card file fails closed before commit. I’m running the repository’s existing focused test now.
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 2968ms:
/var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/tmp.mCb8MrZflE: line 1: 48770 Alarm clock: 14         python3 -c '
import os
import signal
import sys

timeout_s = int(sys.argv[1])
if timeout_s < 1:
    raise SystemExit("deadline must be at least one second")
signal.alarm(timeout_s)
os.execvp(sys.argv[2], sys.argv[2:])
' "$timeout_s" "$@"
PASS: deploy autotune feed access guards present

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh | sed -n '480,530p'" in /Users/augstar/macprovider-canary-ratecard
exec
/bin/bash -lc "rg -n '"'^    names = '"\\("'$|''^    '"\\)"'$|STATIC_RATE_CARD_(JSON|SIG)=|verify-directory --directory|AUTOTUNE_RELEASE_CONTENT_SHA256|_append_deploy_input_digest.*rate-card'"' phase4-coordinator/dist/deploy-pearl-vps.sh" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
674:STATIC_RATE_CARD_JSON="$STATIC_FEEDS_DIR/rate-card.json"
675:STATIC_RATE_CARD_SIG="$STATIC_FEEDS_DIR/rate-card.json.sig"
748:AUTOTUNE_RELEASE_CONTENT_SHA256="$(python3 - \
781:    )
796:AUTOTUNE_RELEASE_DIR_NAME="$AUTOTUNE_RELEASE_ID-$(printf '%s' "$AUTOTUNE_RELEASE_CONTENT_SHA256" | cut -c1-16)"
1270:    )
2370:    )
2393:    )
2416:    )
2440:    )
2463:    )
2683:    )
2691:    )
3246:  _append_deploy_input_digest "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.rate-card-migration.yaml"
3251:  _append_deploy_input_digest "$RATE_CARD_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.rate-card-migration.yaml"
3274:  "$STATIC_RATE_CARD_JSON=rate-card.json" \
3275:  "$STATIC_RATE_CARD_SIG=rate-card.json.sig" \
3391:  python3 -I $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_preflight --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub || _rc=\$?
3424:  python3 -I $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory /opt/macprovider/autotune/\$_live --tier2-coordinator-config /opt/macprovider/coordinator.yaml \$_live_t2_overlay --allow-expired-tier2 >&2 || exit 4
3664:  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_stage --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
3675:  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_release --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
4127:  STATIC_RATE_CARD_JSON="$CATALOG_LIVE_SNAPSHOT/rate-card.json"
4128:  STATIC_RATE_CARD_SIG="$CATALOG_LIVE_SNAPSHOT/rate-card.json.sig"
4309:python3 "$AUTOTUNE_RELEASE_VERIFY" verify-directory --directory "$STATIC_SMOKE_DIR"
4493:    )
4532:    )
4562:    names = (
4572:    )

 succeeded in 0ms:
   480	
   481	grep -q 'value.get("catalog_evidence_source") != "provider_reported"' "$DEPLOY_SH" ||
   482	  fail "deploy must treat coordinator catalog fields as provider-reported compatibility evidence"
   483	
   484	grep -q 'value.get("catalog_admission_mode") != "current"' "$DEPLOY_SH" ||
   485	  fail "deploy canary must reject legacy and previous catalog admissions"
   486	
   487	# The Mac proof hashes every name in its `names` tuple, and the exact-byte
   488	# check compares that dict to the basenames of its expected argv files, so
   489	# the two sets must be equal. Before this check the rate card and its sidecar
   490	# were proven but never expected, so no canary could pass.
   491	python3 - "$DEPLOY_SH" <<'PY' || fail "deploy canary expected-byte set must equal the file set the Mac proof hashes"
   492	import re, sys
   493	text = open(sys.argv[1], encoding="utf-8").read()
   494	names_block = re.search(r'\n    names = \(\n(.*?)\n    \)\n', text, re.S)
   495	if names_block is None:
   496	    raise SystemExit("canary proof names tuple not found")
   497	proven = set(re.findall(r'"([^"]+)"', names_block.group(1)))
   498	check = re.search(r'  "\$CATALOG_CANARY_PROVIDER_ID" \\\n((?:  "\$[A-Z0-9_]+" \\\n)*)  "\$([A-Z0-9_]+)" <<\'PY\'\nimport hashlib, json, pathlib, re, sys\n\nproof = json.loads', text)
   499	if check is None:
   500	    raise SystemExit("canary exact-byte check argv not found")
   501	variables = re.findall(r'"\$([A-Z0-9_]+)"', check.group(1)) + [check.group(2)]
   502	basenames = set()
   503	for variable in variables:
   504	    assignment = re.search(r'(?m)^' + variable + r'="[^"\n]*/([^/"\n]+)"$', text)
   505	    if assignment is None:
   506	        raise SystemExit(f"no path assignment for {variable}")
   507	    basenames.add(assignment.group(1))
   508	if basenames != proven:
   509	    raise SystemExit(f"proven={sorted(proven)} expected={sorted(basenames)}")
   510	if "tier2-catalog.json" not in basenames or "rate-card.json.sig" not in basenames:
   511	    raise SystemExit("expected set must include the Tier-2 catalog and the signed rate card")
   512	PY
   513	
   514	grep -q 'value.get("catalog_candidate_sha256") != sys.argv\[6\]' "$DEPLOY_SH" ||
   515	  fail "deploy canary must match the active candidate catalog digest"
   516	
   517	grep -q 'read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY' "$DEPLOY_SH" &&
   518	  grep -q 'catalog.get("policy_version") != expected_policy_version' "$DEPLOY_SH" &&
   519	  grep -q 'catalog.get("row_identity", "")' "$DEPLOY_SH" &&
   520	  grep -q 'canary local catalog proof is not bound to the coordinator-admitted envelope' "$DEPLOY_SH" ||
   521	  fail "deploy canary must cross-bind exact policy and row between coordinator and Mac proof"
   522	
   523	grep -q 'canary catalog byte mismatch' "$DEPLOY_SH" ||
   524	  fail "deploy must compare exact installed canary catalog bytes before commit"
   525	
   526	grep -q 'canary provider identity mismatch' "$DEPLOY_SH" &&
   527	  grep -q 'live canary provider text vnode is stale or not the verified installation binary' "$DEPLOY_SH" &&
   528	  grep -q 'live canary provider status does not match the expected identity and catalog' "$DEPLOY_SH" ||
   529	  fail "exact-byte proof must bind the named provider, live process, and local catalog status"
   530	

exec
/bin/bash -lc 'git diff --check origin/main...HEAD && git status --short' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
?? audits/2026-09-25-deploy-canary-rate-card/

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '720,820p;3220,3300p;4040,4150p;3620,3690p'" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
   720	  AUTOTUNE_ARTIFACT_CONTENT_JSON="$STATIC_ARTIFACTS_JSON"
   721	  AUTOTUNE_ARTIFACT_CONTENT_SIG="$STATIC_ARTIFACTS_SIG"
   722	fi
   723	AUTOTUNE_RELEASE_ID="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
   724	import json, pathlib, sys
   725	print(json.loads(pathlib.Path(sys.argv[1]).read_text())["release_id"])
   726	PY
   727	)"
   728	AUTOTUNE_POLICY_VERSION="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
   729	import json, pathlib, sys
   730	print(json.loads(pathlib.Path(sys.argv[1]).read_text())["policy_version"])
   731	PY
   732	)"
   733	AUTOTUNE_CANDIDATE_SHA256="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
   734	import json, pathlib, sys
   735	print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["autotune-candidates.json"]["sha256"])
   736	PY
   737	)"
   738	AUTOTUNE_CANDIDATE_SIGNER_KEY_ID="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
   739	import json, pathlib, sys
   740	print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["autotune-candidates.json"]["signer_key_id"])
   741	PY
   742	)"
   743	AUTOTUNE_TIER2_SHA256="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
   744	import json, pathlib, sys
   745	print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["tier2-catalog.json"]["sha256"])
   746	PY
   747	)"
   748	AUTOTUNE_RELEASE_CONTENT_SHA256="$(python3 - \
   749	  "$AUTOTUNE_RELEASE_MANIFEST" \
   750	  "$AUTOTUNE_TRUSTED_KEYS" \
   751	  "$AUTOTUNE_TIER2_JSON" \
   752	  "$STATIC_AUTOTUNE_JSON" \
   753	  "$STATIC_AUTOTUNE_SIG" \
   754	  "$STATIC_DEMAND_JSON" \
   755	  "$STATIC_DEMAND_SIG" \
   756	  "$STATIC_RATE_CARD_JSON" \
   757	  "$STATIC_RATE_CARD_SIG" \
   758	  "$AUTOTUNE_ARTIFACT_CONTENT_JSON" \
   759	  "$AUTOTUNE_ARTIFACT_CONTENT_SIG" <<'PY'
   760	import hashlib
   761	import pathlib
   762	import sys
   763	
   764	assets = (
   765	    ("release.json", pathlib.Path(sys.argv[1])),
   766	    ("trusted-keys.json", pathlib.Path(sys.argv[2])),
   767	    ("tier2-catalog.json", pathlib.Path(sys.argv[3])),
   768	    ("autotune-candidates.json", pathlib.Path(sys.argv[4])),
   769	    ("autotune-candidates.json.sig", pathlib.Path(sys.argv[5])),
   770	    ("demand-rank.json", pathlib.Path(sys.argv[6])),
   771	    ("demand-rank.json.sig", pathlib.Path(sys.argv[7])),
   772	    ("rate-card.json", pathlib.Path(sys.argv[8])),
   773	    ("rate-card.json.sig", pathlib.Path(sys.argv[9])),
   774	)
   775	# Artifact-bound release (SPEC-023 §3.7.8): the pair is part of the
   776	# content-addressed envelope; both arguments are empty otherwise.
   777	if sys.argv[10] or sys.argv[11]:
   778	    assets += (
   779	        ("autotune-artifacts.json", pathlib.Path(sys.argv[10])),
   780	        ("autotune-artifacts.json.sig", pathlib.Path(sys.argv[11])),
   781	    )
   782	digest = hashlib.sha256()
   783	for name, path in assets:
   784	    asset_digest = hashlib.sha256(path.read_bytes()).hexdigest()
   785	    digest.update(name.encode("utf-8"))
   786	    digest.update(b"\0")
   787	    digest.update(asset_digest.encode("ascii"))
   788	    digest.update(b"\n")
   789	print(digest.hexdigest())
   790	PY
   791	)"
   792	if ! printf '%s' "$AUTOTUNE_RELEASE_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
   793	  echo "invalid autotune release_id: $AUTOTUNE_RELEASE_ID" >&2
   794	  exit 1
   795	fi
   796	AUTOTUNE_RELEASE_DIR_NAME="$AUTOTUNE_RELEASE_ID-$(printf '%s' "$AUTOTUNE_RELEASE_CONTENT_SHA256" | cut -c1-16)"
   797	# #1688 A2: the tag's release ledger rides the pinned deploy inputs so Pearl's
   798	# compare-live can tell a live release this tag descends from (activate) from
   799	# a catalog regression (refuse). The staged release dir never carries it.
   800	AUTOTUNE_RELEASE_LEDGER="$PINNED_AUTOTUNE_DIR/release-ledger.json"
   801	[ -f "$AUTOTUNE_RELEASE_LEDGER" ] || { echo "missing required file: $AUTOTUNE_RELEASE_LEDGER" >&2; exit 1; }
   802	# The ledger records whole-file Tier-2 digests only; a Tier-2 freshness re-sign
   803	# of a historical row is proven by its stripped content, looked up from the
   804	# pinned commit's git history (catalog-release.py tier2-content-index) and
   805	# shipped digest-pinned beside the ledger.
   806	AUTOTUNE_TIER2_CONTENT_INDEX=""
   807	if [ "$DRY_RUN_LOCAL" != "1" ]; then
   808	  AUTOTUNE_TIER2_CONTENT_INDEX="$PINNED_DEPLOY_INPUT_DIR/tier2-content-index.json"
   809	  python3 -I "$PINNED_SCRIPTS_DIR/catalog-release.py" tier2-content-index --repo "$REPO_ROOT" \
   810	    --rev "$COORDINATOR_RELEASE_COMMIT" --ledger "$AUTOTUNE_RELEASE_LEDGER" > "$AUTOTUNE_TIER2_CONTENT_INDEX" || {
   811	    echo "aborting deploy: could not build the Tier-2 content index from $COORDINATOR_RELEASE_COMMIT history" >&2
   812	    exit 1
   813	  }
   814	fi
   815	# Operator override for a compare-live regression verdict. Printable ASCII,
   816	# 1-200 chars, one line; it reaches Pearl only as base64.
   817	CATALOG_REGRESSION_OVERRIDE_REASON="${CATALOG_REGRESSION_OVERRIDE_REASON:-}"
   818	CATALOG_REGRESSION_OVERRIDE_B64=""
   819	if [ -n "$CATALOG_REGRESSION_OVERRIDE_REASON" ]; then
   820	  case "$CATALOG_REGRESSION_OVERRIDE_REASON" in
  3220	case "$DEPLOY_TMP" in
  3221	  /tmp/macprovider-deploy.*) ;;
  3222	  *)
  3223	    echo "aborting deploy: mktemp produced unexpected path: '$DEPLOY_TMP'" >&2
  3224	    exit 1
  3225	    ;;
  3226	esac
  3227	log "  staging dir: $DEPLOY_TMP (root:root 0700)"
  3228	$SSH "install -d -o root -g root -m 0700 $DEPLOY_TMP/scripts"
  3229	
  3230	DEPLOY_INPUT_MANIFEST_TMP="$(umask 077 && mktemp -t macprovider-deploy-inputs.XXXXXXXX)" || {
  3231	  echo "aborting deploy: mktemp failed for deploy input manifest" >&2
  3232	  exit 2
  3233	}
  3234	_append_deploy_input_digest() {
  3235	  local source_path="$1" remote_name="$2"
  3236	  shasum -a 256 "$source_path" | awk -v name="$remote_name" '{ print $1 "  " name }' >> "$DEPLOY_INPUT_MANIFEST_TMP"
  3237	}
  3238	_append_deploy_input_digest "$BINARY" "coordinator-linux-amd64"
  3239	_append_deploy_input_digest "$CLI_BINARY" "coordinator-cli-linux-amd64"
  3240	_append_deploy_input_digest "$STATS_INVENTORY_BINARY" "stats-inventory-sync-linux-amd64"
  3241	_append_deploy_input_digest "$STATS_BILLING_MIRROR_BINARY" "stats-billing-mirror-linux-amd64"
  3242	_append_deploy_input_digest "$STATS_HARDWARE_VERIFIER_BINARY" "stats-hardware-verifier-linux-amd64"
  3243	if [ "$CONFIG_MODE" = "apply-tracked" ]; then
  3244	  _append_deploy_input_digest "$CONFIG" "coordinator.yaml"
  3245	elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
  3246	  _append_deploy_input_digest "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.rate-card-migration.yaml"
  3247	elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
  3248	  _append_deploy_input_digest "$C2_TIMER_MIGRATED_CONFIG_TMP" "coordinator.c2-timer-migration.yaml"
  3249	fi
  3250	if [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
  3251	  _append_deploy_input_digest "$RATE_CARD_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.rate-card-migration.yaml"
  3252	elif [ "${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
  3253	  _append_deploy_input_digest "$C2_TIMER_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.c2-timer-migration.yaml"
  3254	fi
  3255	for _deploy_input in \
  3256	  "$SERVICE=macprovider-coordinator.service" \
  3257	  "$STATS_INVENTORY_SERVICE=stats-inventory-sync.service" \
  3258	  "$STATS_INVENTORY_TIMER=stats-inventory-sync.timer" \
  3259	  "$STATS_BILLING_MIRROR_SERVICE=stats-billing-mirror.service" \
  3260	  "$STATS_BILLING_MIRROR_TIMER=stats-billing-mirror.timer" \
  3261	  "$STATS_HARDWARE_VERIFIER_SERVICE=stats-hardware-verifier.service" \
  3262	  "$STATS_HARDWARE_VERIFIER_TIMER=stats-hardware-verifier.timer" \
  3263	  "$NGINX_SITE=nginx-coordinator-full.conf" \
  3264	  "$NGINX_STATS_SHARED=nginx-stats-shared.conf" \
  3265	  "$NGINX_STATS_SECHEADERS=nginx-stats-security-headers.conf" \
  3266	  "$NGINX_STATS_CORS_429=nginx-stats-cors-429.conf" \
  3267	  "$NGINX_STATS_PROXY_PUBLIC=nginx-stats-proxy-public.conf" \
  3268	  "$NGINX_STATS_PROXY_PARTNER=nginx-stats-proxy-partner.conf" \
  3269	  "$NGINX_STATS_SITE=nginx-stats.malibu.tech.conf" \
  3270	  "$STATIC_DEMAND_JSON=demand-rank.json" \
  3271	  "$STATIC_DEMAND_SIG=demand-rank.json.sig" \
  3272	  "$STATIC_AUTOTUNE_JSON=autotune-candidates.json" \
  3273	  "$STATIC_AUTOTUNE_SIG=autotune-candidates.json.sig" \
  3274	  "$STATIC_RATE_CARD_JSON=rate-card.json" \
  3275	  "$STATIC_RATE_CARD_SIG=rate-card.json.sig" \
  3276	  "$AUTOTUNE_RELEASE_MANIFEST=release.json" \
  3277	  "$AUTOTUNE_RELEASE_LEDGER=release-ledger.json" \
  3278	  "$AUTOTUNE_TIER2_CONTENT_INDEX=tier2-content-index.json" \
  3279	  "$AUTOTUNE_TRUSTED_KEYS=trusted-keys.json"; do
  3280	  _append_deploy_input_digest "${_deploy_input%%=*}" "${_deploy_input#*=}"
  3281	done
  3282	for _bundle_path in $CATALOG_VERIFIER_BUNDLE; do
  3283	  _append_deploy_input_digest "$PINNED_SCRIPTS_DIR/${_bundle_path#scripts/}" "$_bundle_path"
  3284	done
  3285	if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
  3286	  _append_deploy_input_digest "$STATIC_ARTIFACTS_JSON" "autotune-artifacts.json"
  3287	  _append_deploy_input_digest "$STATIC_ARTIFACTS_SIG" "autotune-artifacts.json.sig"
  3288	fi
  3289	if [ -n "$CATALOG_REMOTE_PATH" ]; then
  3290	  _append_deploy_input_digest "$TMP_CATALOG_PINNED" "tier2-catalog.json"
  3291	  _append_deploy_input_digest "$TMP_CATALOG_PUBKEY" "tier2-catalog.pub"
  3292	else
  3293	  _append_deploy_input_digest "$AUTOTUNE_TIER2_JSON" "tier2-catalog.json"
  3294	fi
  3295	
  3296	$SCP "$BINARY"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
  3297	$SCP "$CLI_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-cli-linux-amd64"
  3298	$SCP "$STATS_INVENTORY_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync-linux-amd64"
  3299	$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"
  3300	$SCP "$STATS_HARDWARE_VERIFIER_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier-linux-amd64"
  3620	    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  3621	  fi
  3622	  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
  3623	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service
  3624	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer
  3625	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
  3626	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
  3627	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.service /etc/systemd/system/stats-hardware-verifier.service
  3628	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.timer /etc/systemd/system/stats-hardware-verifier.timer
  3629	  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
  3630	    # Mutate only objects captured at the transaction boundary. WAL/SHM files
  3631	    # can appear while the old coordinator is still running; granting an ACL
  3632	    # to a newly appeared, unsnapshotted file would make exact rollback
  3633	    # impossible.
  3634	    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
  3635	    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite
  3636	    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-wal
  3637	    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-shm
  3638	  elif [ -f /var/lib/macprovider/request-log.sqlite ]; then
  3639	    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
  3640	  fi
  3641	  # Stage the complete immutable catalog release. Activation happens only
  3642	  # after the late connected-provider safeguard immediately before restart.
  3643	  _autotune_root=/opt/macprovider/autotune
  3644	  _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
  3645	  _autotune_lock=\$_autotune_release.lock
  3646	  _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
  3647	  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
  3648	  if ! mkdir \$_autotune_lock; then
  3649	    echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
  3650	    exit 1
  3651	  fi
  3652	  trap 'rm -rf \"\$_autotune_stage\"; rmdir \"\$_autotune_lock\" 2>/dev/null || true' EXIT
  3653	  rm -rf \$_autotune_stage
  3654	  install -d -o root -g macprovider -m 0750 \$_autotune_stage
  3655	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json \$_autotune_stage/demand-rank.json
  3656	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json.sig \$_autotune_stage/demand-rank.json.sig
  3657	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json \$_autotune_stage/autotune-candidates.json
  3658	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json.sig \$_autotune_stage/autotune-candidates.json.sig
  3659	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json \$_autotune_stage/rate-card.json
  3660	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json.sig \$_autotune_stage/rate-card.json.sig$AUTOTUNE_ARTIFACT_INSTALL_LINES
  3661	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json
  3662	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/release.json \$_autotune_stage/release.json
  3663	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/trusted-keys.json \$_autotune_stage/trusted-keys.json
  3664	  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_stage --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
  3665	  sync
  3666	  if [ -e \$_autotune_release ]; then
  3667	    if ! diff -qr \$_autotune_stage \$_autotune_release >/dev/null; then
  3668	      echo 'catalog release envelope $AUTOTUNE_RELEASE_DIR_NAME already exists with different bytes' >&2
  3669	      exit 1
  3670	    fi
  3671	    rm -rf \$_autotune_stage
  3672	  else
  3673	    mv \$_autotune_stage \$_autotune_release
  3674	  fi
  3675	  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_release --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
  3676	  # First rollout: the new on-disk coordinator config already points at
  3677	  # autotune/current. Establish that path as soon as the immutable release is
  3678	  # staged so an abort before the late restart gate cannot leave the next
  3679	  # service restart without feeds. Existing rollouts remain untouched here.
  3680	  if [ ! -e \$_autotune_root/current ] && [ ! -L \$_autotune_root/current ]; then
  3681	    ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME \$_autotune_root/current.bootstrap
  3682	    mv -Tf \$_autotune_root/current.bootstrap \$_autotune_root/current
  3683	  fi
  3684	  rmdir \$_autotune_lock
  3685	  trap - EXIT
  3686	"
  3687	
  3688	# nginx + Let's Encrypt strategy (issue #244 R1+R2+R3+R4 — TLS-safety hardening):
  3689	#
  3690	# Domain classification (step 4b) produces FOUR states:
  4040	value = json.loads(raw)
  4041	covered, uncovered, total = value["covered"], value["uncovered"], value["advertised_total"]
  4042	if not isinstance(total, int) or not isinstance(covered, list) or not isinstance(uncovered, list):
  4043	    raise SystemExit("coverage report has the wrong shape")
  4044	if (rc == "4") != bool(uncovered):
  4045	    raise SystemExit(f"coverage exit {rc} does not match its report")
  4046	def rid(v):
  4047	    if not isinstance(v, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,191}", v) is None:
  4048	        raise SystemExit("coverage report carries an unsafe release id")
  4049	    return v
  4050	def sha(v):
  4051	    if not isinstance(v, str) or re.fullmatch(r"[0-9a-f]{64}", v) is None:
  4052	        raise SystemExit("coverage report carries a malformed sha")
  4053	    return v
  4054	def count(v):
  4055	    if not isinstance(v, int) or v < 0:
  4056	        raise SystemExit("coverage report carries a bad count")
  4057	    return v
  4058	records = []
  4059	print(f"    window coverage: {len(covered)} admissible release(s), {count(total)} catalog-advertising provider(s), {len(uncovered)} uncovered", file=sys.stderr)
  4060	for entry in covered:
  4061	    print(f"      admissible {rid(entry['release_id'])} sha={sha(entry['sha'])[:16]}", file=sys.stderr)
  4062	for entry in uncovered:
  4063	    record = {"release_id": rid(entry["release_id"]), "sha": sha(entry["sha"]),
  4064	              "providers": count(entry["providers"]), "routing_eligible": count(entry["routing_eligible"])}
  4065	    records.append(record)
  4066	    print(f"      UNCOVERED {record['release_id']} sha={record['sha'][:16]} providers={record['providers']} routing_eligible={record['routing_eligible']}", file=sys.stderr)
  4067	print(json.dumps(records, sort_keys=True, separators=(",", ":")))
  4068	PY
  4069	)" || { echo "aborting deploy: window coverage output is malformed" >&2; exit 1; }
  4070	    if [ "$CATALOG_COVERAGE_RC" = "4" ]; then
  4071	      if [ -z "$CATALOG_WINDOW_OVERRIDE_B64" ]; then
  4072	        echo "aborting deploy: activating $AUTOTUNE_RELEASE_ID would drop catalog release(s) connected providers still advertise;" >&2
  4073	        echo "  those providers would be rejected catalog_incompatible on their next hello. Wait until they move to an admissible" >&2
  4074	        echo "  release, or set CATALOG_WINDOW_OVERRIDE_REASON='<why>' to activate anyway (logged on Pearl)." >&2
  4075	        exit 1
  4076	      fi
  4077	      log "  WINDOW COVERAGE OVERRIDE: activating $AUTOTUNE_RELEASE_ID although connected providers advertise dropped releases"
  4078	      CATALOG_OVERRIDE_RECORD_B64="$(python3 - "$CATALOG_WINDOW_OVERRIDE_B64" "$CATALOG_COVERAGE_UNCOVERED" "$AUTOTUNE_RELEASE_DIR_NAME" "$CATALOG_LIVE_TARGET" "$CATALOG_LIVE_RELEASE_ID" "$COORDINATOR_RELEASE_VERSION" "$COORDINATOR_RELEASE_COMMIT" <<'PY'
  4079	import base64, json, sys
  4080	reason_b64, uncovered, incoming, live_target, live_id, tag, commit = sys.argv[1:]
  4081	record = {
  4082	    "kind": "window_coverage",
  4083	    "reason": base64.b64decode(reason_b64, validate=True).decode("ascii"),
  4084	    "uncovered": json.loads(uncovered),
  4085	    "incoming": incoming,
  4086	    "live": {"target": live_target, "release_id": live_id},
  4087	    "tag": tag,
  4088	    "commit": commit,
  4089	}
  4090	print(base64.b64encode(json.dumps(record, sort_keys=True).encode("ascii")).decode("ascii"))
  4091	PY
  4092	)" || { echo "aborting deploy: could not build the window coverage override record" >&2; exit 1; }
  4093	      _append_catalog_window_override "$CATALOG_OVERRIDE_RECORD_B64" "catalog window coverage override used for $AUTOTUNE_RELEASE_DIR_NAME"
  4094	      log "  AUDIT TRAIL: override appended to /var/lib/macprovider/catalog-window-overrides.jsonl"
  4095	    fi
  4096	    ;;
  4097	  equivalent) ;;
  4098	  *) echo "aborting deploy: unknown compare-live verdict" >&2; exit 1 ;;
  4099	esac
  4100	
  4101	if [ "$CATALOG_VERDICT" = "equivalent" ]; then
  4102	  # #1688 A2: content-equivalent live catalog. No current swap, no window
  4103	  # apply; the immutable release staged above stays for forensics/rollback.
  4104	  log "  catalog unchanged; runtime-only deploy keeps live release $CATALOG_LIVE_RELEASE_ID"
  4105	  $SSH "set -e
  4106	    exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  4107	    flock -s 8
  4108	    _current=\$(readlink /opt/macprovider/autotune/current 2>/dev/null || true)
  4109	    [ \"\$_current\" = '$CATALOG_LIVE_TARGET' ] || {
  4110	      echo \"autotune/current moved since compare-live (\$_current); re-run the deploy\" >&2
  4111	      exit 1
  4112	    }
  4113	    rm -f /opt/macprovider/tier2-catalog.json
  4114	    rm -rf $DEPLOY_TMP
  4115	  " || { echo "aborting deploy: live catalog changed since compare-live or could not be pinned" >&2; exit 1; }
  4116	  # Post-restart smokes and the canary prove the LIVE release, not the tag's.
  4117	  [ -n "$PINNED_DEPLOY_INPUT_DIR" ] || { echo "aborting deploy: no pinned input dir for the live catalog snapshot" >&2; exit 1; }
  4118	  CATALOG_LIVE_SNAPSHOT="$PINNED_DEPLOY_INPUT_DIR/live-catalog"
  4119	  mkdir -m 0700 "$CATALOG_LIVE_SNAPSHOT"
  4120	  # shellcheck disable=SC2086 # fixed release file names
  4121	  $SSH "tar -C /opt/macprovider/autotune/$CATALOG_LIVE_TARGET -cf - $CATALOG_RELEASE_FILES" | tar -xf - -C "$CATALOG_LIVE_SNAPSHOT" ||
  4122	    { echo "aborting deploy: could not snapshot the live catalog release" >&2; exit 1; }
  4123	  STATIC_DEMAND_JSON="$CATALOG_LIVE_SNAPSHOT/demand-rank.json"
  4124	  STATIC_DEMAND_SIG="$CATALOG_LIVE_SNAPSHOT/demand-rank.json.sig"
  4125	  STATIC_AUTOTUNE_JSON="$CATALOG_LIVE_SNAPSHOT/autotune-candidates.json"
  4126	  STATIC_AUTOTUNE_SIG="$CATALOG_LIVE_SNAPSHOT/autotune-candidates.json.sig"
  4127	  STATIC_RATE_CARD_JSON="$CATALOG_LIVE_SNAPSHOT/rate-card.json"
  4128	  STATIC_RATE_CARD_SIG="$CATALOG_LIVE_SNAPSHOT/rate-card.json.sig"
  4129	  AUTOTUNE_RELEASE_MANIFEST="$CATALOG_LIVE_SNAPSHOT/release.json"
  4130	  AUTOTUNE_TRUSTED_KEYS="$CATALOG_LIVE_SNAPSHOT/trusted-keys.json"
  4131	  AUTOTUNE_TIER2_JSON="$CATALOG_LIVE_SNAPSHOT/tier2-catalog.json"
  4132	  CATALOG_LIVE_IDENTITY="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" "$CATALOG_LIVE_RELEASE_ID" <<'PY'
  4133	import json, pathlib, sys
  4134	manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
  4135	if manifest.get("release_id") != sys.argv[2]:
  4136	    raise SystemExit("live catalog snapshot release_id differs from the compare-live verdict")
  4137	feed = manifest["feeds"]["autotune-candidates.json"]
  4138	print(manifest["release_id"], manifest["policy_version"], feed["sha256"], feed["signer_key_id"])
  4139	PY
  4140	)" || { echo "aborting deploy: live catalog snapshot does not match compare-live" >&2; exit 1; }
  4141	  read -r AUTOTUNE_RELEASE_ID AUTOTUNE_POLICY_VERSION AUTOTUNE_CANDIDATE_SHA256 AUTOTUNE_CANDIDATE_SIGNER_KEY_ID <<< "$CATALOG_LIVE_IDENTITY"
  4142	else
  4143	log "  activating verified autotune release $AUTOTUNE_RELEASE_ID"
  4144	$SSH "set -e
  4145	  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  4146	  flock -s 8
  4147	  _catalog_root=/opt/macprovider/autotune
  4148	  _previous=\$(readlink \"\$_catalog_root/current\" 2>/dev/null || true)
  4149	  # #1688 A2: activate only over the current compare-live judged (staging may
  4150	  # have bootstrapped current to this release when none existed).

exec
/bin/bash -lc "rg -n -C 8 'rate-card|verify-directory|signature' scripts/catalog-release.py phase4-coordinator/dist/scripts/catalog-release.py phase3-binary/catalog/autotune/release.json phase3-binary/dist/static 2>/dev/null | head -n 240" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
phase3-binary/catalog/autotune/release.json-7-      "version": "published-2026-09-25-artifact-hash-correction-v1"
phase3-binary/catalog/autotune/release.json-8-    },
phase3-binary/catalog/autotune/release.json-9-    "demand-rank.json": {
phase3-binary/catalog/autotune/release.json-10-      "bytes": 1995,
phase3-binary/catalog/autotune/release.json-11-      "sha256": "a60273212954fd07108a044d2093dea740ba494a6fd584e0d6b2b105fa664fa3",
phase3-binary/catalog/autotune/release.json-12-      "signer_key_id": "streamvc-autotune-static-v4",
phase3-binary/catalog/autotune/release.json-13-      "version": "published-2026-09-25-artifact-hash-correction-v1"
phase3-binary/catalog/autotune/release.json-14-    },
phase3-binary/catalog/autotune/release.json:15:    "rate-card.json": {
phase3-binary/catalog/autotune/release.json-16-      "bytes": 3690,
phase3-binary/catalog/autotune/release.json-17-      "sha256": "20d62a3d8c934560566ca94a861a6c7a203472e38c7f7d9db85959ae5d661173",
phase3-binary/catalog/autotune/release.json-18-      "signer_key_id": "streamvc-autotune-static-v4",
phase3-binary/catalog/autotune/release.json-19-      "version": "bab7acfb9d1b40b7bbfc3da90bb40689ab8e7c7f6c53065c07143c1e5ed32bd4"
phase3-binary/catalog/autotune/release.json-20-    },
phase3-binary/catalog/autotune/release.json-21-    "tier2-catalog.json": {
phase3-binary/catalog/autotune/release.json-22-      "bytes": 6860,
phase3-binary/catalog/autotune/release.json-23-      "sha256": "5e5dbf2b9c3584d6382a03675e6936c18db6cc589c988f25b2caa2f55cf31009",
--
scripts/catalog-release.py-56-GO_REJECTED_RELEASES_GENERATED = ROOT / "phase4-coordinator" / "internal" / "autotune" / "rejected_release_ids.generated.go"
scripts/catalog-release.py-57-KEYS_PATH = CATALOG_DIR / "trusted-keys.json"
scripts/catalog-release.py-58-MANIFEST_PATH = CATALOG_DIR / "release.json"
scripts/catalog-release.py-59-LEDGER_PATH = CATALOG_DIR / "release-ledger.json"
scripts/catalog-release.py-60-TIER2_BINDING_PATH = CATALOG_DIR / "tier2-identity-binding.json"
scripts/catalog-release.py-61-TIER2_BINDING_SCHEMA = "macprovider.tier2-identity-binding.v1"
scripts/catalog-release.py-62-TIER2_CATALOG_PATH = CATALOG_DIR / "tier2-catalog.json"
scripts/catalog-release.py-63-TIER2_CATALOG_FEED_NAME = "tier2-catalog.json"
scripts/catalog-release.py:64:RATE_CARD_FEED_NAME = "rate-card.json"
scripts/catalog-release.py-65-ARTIFACT_FEED_NAME = "autotune-artifacts.json"
scripts/catalog-release.py-66-ARTIFACT_FEED_PATH = CATALOG_DIR / ARTIFACT_FEED_NAME
scripts/catalog-release.py-67-ARTIFACT_SOURCE_PATH = CATALOG_DIR / "autotune-artifacts-source.json"
scripts/catalog-release.py-68-ARTIFACT_SOURCE_SCHEMA = "macprovider.autotune-artifacts-source.v1"
scripts/catalog-release.py-69-ARTIFACT_FEED_SOURCE_VALUE = "operator_curated_autotune_artifact_catalog"
scripts/catalog-release.py:70:RATE_CARD_SOURCE_PATH = CATALOG_DIR / "rate-card-source.json"
scripts/catalog-release.py:71:RATE_CARD_SOURCE_SCHEMA = "macprovider.rate-card-source.v1"
scripts/catalog-release.py-72-MARKET_PEG_BIND_PATH = CATALOG_DIR / "market-peg-bind.json"
scripts/catalog-release.py-73-MARKET_PEG_BIND_SCHEMA = "macprovider.market-peg-bind.v1"
scripts/catalog-release.py-74-INTAKE_DECISION_PATH = CATALOG_DIR / "intake-decision.json"
scripts/catalog-release.py-75-LEDGER_SCHEMA_V2 = "macprovider.autotune-release-ledger.v2"
scripts/catalog-release.py-76-LEDGER_SCHEMA_V3 = "macprovider.autotune-release-ledger.v3"
scripts/catalog-release.py-77-LEGACY_LEDGER_FEEDS = frozenset({"autotune-candidates.json", "demand-rank.json"})
scripts/catalog-release.py-78-TIER2_BOUND_LEDGER_FEEDS = LEGACY_LEDGER_FEEDS | {TIER2_CATALOG_FEED_NAME}
scripts/catalog-release.py-79-RATE_CARD_BOUND_LEDGER_FEEDS = TIER2_BOUND_LEDGER_FEEDS | {RATE_CARD_FEED_NAME}
--
scripts/catalog-release.py-555-            fail(f"trusted key {key_id}: Ed25519 public key must be 32 bytes")
scripts/catalog-release.py-556-        if row["status"] != "retired":
scripts/catalog-release.py-557-            result[key_id] = raw
scripts/catalog-release.py-558-    return result
scripts/catalog-release.py-559-
scripts/catalog-release.py-560-
scripts/catalog-release.py-561-def parse_sidecar(data: bytes, label: str) -> tuple[str, bytes]:
scripts/catalog-release.py-562-    value = strict_json(data, label)
scripts/catalog-release.py:563:    exact_keys(value, {"key_id", "alg", "signature"}, {"key_id", "alg", "signature"}, label)
scripts/catalog-release.py-564-    if value["alg"] != "ed25519" or not isinstance(value["key_id"], str):
scripts/catalog-release.py-565-        fail(f"{label}: invalid key_id or alg")
scripts/catalog-release.py-566-    try:
scripts/catalog-release.py:567:        signature = base64.b64decode(value["signature"], validate=True)
scripts/catalog-release.py-568-    except (ValueError, TypeError) as exc:
scripts/catalog-release.py:569:        fail(f"{label}: invalid signature base64: {exc}")
scripts/catalog-release.py:570:    if base64.b64encode(signature).decode("ascii") != value["signature"]:
scripts/catalog-release.py:571:        fail(f"{label}: signature base64 is not canonical")
scripts/catalog-release.py:572:    if len(signature) != 64:
scripts/catalog-release.py:573:        fail(f"{label}: Ed25519 signature must be 64 bytes")
scripts/catalog-release.py:574:    return value["key_id"], signature
scripts/catalog-release.py-575-
scripts/catalog-release.py-576-
scripts/catalog-release.py-577-def root_trusted_executable(candidate: str) -> bool:
scripts/catalog-release.py-578-    path = pathlib.Path(candidate)
scripts/catalog-release.py-579-    if not path.is_absolute() or ".." in path.parts:
scripts/catalog-release.py-580-        return False
scripts/catalog-release.py-581-    try:
scripts/catalog-release.py-582-        resolved = path.resolve(strict=True)
--
scripts/catalog-release.py-636-        if result.returncode == 0 and version and int(version.group(1)) >= 3:
scripts/catalog-release.py-637-            return candidate
scripts/catalog-release.py-638-
scripts/catalog-release.py-639-    if override:
scripts/catalog-release.py-640-        fail("OPENSSL_BIN must identify a trusted OpenSSL 3 or newer executable; LibreSSL and OpenSSL 1.x are unsupported")
scripts/catalog-release.py-641-    fail("OpenSSL 3 or newer is required for Ed25519 catalog verification; LibreSSL and OpenSSL 1.x are unsupported")
scripts/catalog-release.py-642-
scripts/catalog-release.py-643-
scripts/catalog-release.py:644:def verify_ed25519(public_key: bytes, signature: bytes, message: bytes, label: str) -> None:
scripts/catalog-release.py-645-    # RFC 8410 SubjectPublicKeyInfo prefix for a raw Ed25519 public key.
scripts/catalog-release.py-646-    spki = bytes.fromhex("302a300506032b6570032100") + public_key
scripts/catalog-release.py-647-    with tempfile.TemporaryDirectory(prefix="macprovider-catalog-verify-") as tmp:
scripts/catalog-release.py-648-        tmpdir = pathlib.Path(tmp)
scripts/catalog-release.py-649-        pub_path = tmpdir / "public.der"
scripts/catalog-release.py:650:        sig_path = tmpdir / "signature.bin"
scripts/catalog-release.py-651-        msg_path = tmpdir / "message.bin"
scripts/catalog-release.py-652-        pub_path.write_bytes(spki)
scripts/catalog-release.py:653:        sig_path.write_bytes(signature)
scripts/catalog-release.py-654-        msg_path.write_bytes(message)
scripts/catalog-release.py-655-        try:
scripts/catalog-release.py-656-            result = subprocess.run(
scripts/catalog-release.py-657-                [openssl_executable(), "pkeyutl", "-verify", "-pubin", "-inkey", str(pub_path),
scripts/catalog-release.py-658-                 "-keyform", "DER", "-rawin", "-in", str(msg_path), "-sigfile", str(sig_path)],
scripts/catalog-release.py-659-                stdout=subprocess.PIPE,
scripts/catalog-release.py-660-                stderr=subprocess.PIPE,
scripts/catalog-release.py-661-                text=True,
scripts/catalog-release.py-662-                timeout=OPENSSL_VERIFY_TIMEOUT_SECONDS,
scripts/catalog-release.py-663-            )
scripts/catalog-release.py-664-        except subprocess.TimeoutExpired:
scripts/catalog-release.py:665:            fail(f"{label}: signature verification timed out")
scripts/catalog-release.py-666-    if result.returncode != 0:
scripts/catalog-release.py:667:        fail(f"{label}: signature verification failed")
scripts/catalog-release.py-668-
scripts/catalog-release.py-669-
scripts/catalog-release.py-670-def generated_swift(
scripts/catalog-release.py-671-    candidate: bytes,
scripts/catalog-release.py-672-    demand: bytes,
scripts/catalog-release.py-673-    rate_card: bytes,
scripts/catalog-release.py-674-    signer_key_id: str | None = None,
scripts/catalog-release.py-675-    artifacts: bytes | None = None,
--
scripts/catalog-release.py-677-    """The compiled-in snapshot the CLI falls back to (SPEC-023 §3.5, §3.7.2).
scripts/catalog-release.py-678-
scripts/catalog-release.py-679-    `artifacts` is the published artifact feed of an artifact-bound release,
scripts/catalog-release.py-680-    baked as base64 (`bakedArtifactFeedBase64`) so the compiled bytes are the
scripts/catalog-release.py-681-    exact signed bytes whatever string escapes the feed carries, together with
scripts/catalog-release.py-682-    the release-manifest-bound signer of that feed
scripts/catalog-release.py-683-    (`bakedArtifactFeedSignerKeyID`, read from the artifact sidecar — the
scripts/catalog-release.py-684-    generator's signer-equality gate makes it equal to `release.json`'s
scripts/catalog-release.py:685:    binding). A rate-card-bound release bakes `nil`, which the CLI treats
scripts/catalog-release.py-686-    exactly like v0.1 (§3.7.6 rule 6). Baking is how the feed reaches the
scripts/catalog-release.py-687-    provider — it is never a payload member (§3.7.8 Stage A).
scripts/catalog-release.py-688-    """
scripts/catalog-release.py-689-    trusted = keyring()
scripts/catalog-release.py-690-    swift_keys = "\n".join(
scripts/catalog-release.py-691-        f'        "{key_id}": "{base64.b64encode(raw).decode()}",'
scripts/catalog-release.py-692-        for key_id, raw in sorted(trusted.items())
scripts/catalog-release.py-693-    )
--
scripts/catalog-release.py-734-        if candidate_obj[field] != demand_obj[field]:
scripts/catalog-release.py-735-            fail(f"candidate and demand {field} must match the atomic release")
scripts/catalog-release.py-736-
scripts/catalog-release.py-737-
scripts/catalog-release.py-738-def validate_release_inputs(candidate_obj: dict, demand_obj: dict, rate_card_obj: dict) -> None:
scripts/catalog-release.py-739-    validate_pair(candidate_obj, demand_obj)
scripts/catalog-release.py-740-    for field in ("generated_at", "policy_version"):
scripts/catalog-release.py-741-        if candidate_obj[field] != rate_card_obj[field]:
scripts/catalog-release.py:742:            fail(f"rate-card {field} must match the atomic release")
scripts/catalog-release.py-743-
scripts/catalog-release.py-744-
scripts/catalog-release.py-745-def validate_market_peg_bind(data: bytes) -> dict:
scripts/catalog-release.py-746-    value = strict_json(data, "market-peg-bind")
scripts/catalog-release.py-747-    fields = {"schema_version", "content_digest", "policy_digest", "engine_sha256", "ranking_window_end_date"}
scripts/catalog-release.py-748-    exact_keys(value, fields, fields, "market-peg-bind")
scripts/catalog-release.py-749-    if value["schema_version"] != MARKET_PEG_BIND_SCHEMA:
scripts/catalog-release.py-750-        fail(f"market-peg-bind: schema_version must be {MARKET_PEG_BIND_SCHEMA}")
--
scripts/catalog-release.py-859-            policy,
scripts/catalog-release.py-860-            min_provider_targets=min_targets,
scripts/catalog-release.py-861-            recommendable_catalog=candidate_obj,
scripts/catalog-release.py-862-            now=datetime.fromisoformat(rate_proposal["generated_at"].replace("Z", "+00:00")).astimezone(timezone.utc),
scripts/catalog-release.py-863-        )
scripts/catalog-release.py-864-    except (openrouter_pricing_engine.EngineError, KeyError, TypeError, ValueError) as error:
scripts/catalog-release.py-865-        fail(f"market-peg replay failed: {error}")
scripts/catalog-release.py-866-    if canonical_sorted_bytes(rate_proposal) != canonical_sorted_bytes(replayed_rate):
scripts/catalog-release.py:867:        fail("market-peg: rate-card proposal does not equal the engine replay")
scripts/catalog-release.py-868-    if canonical_sorted_bytes(demand_proposal) != canonical_sorted_bytes(replayed_demand):
scripts/catalog-release.py-869-        fail("market-peg: demand-rank proposal does not equal the engine replay")
scripts/catalog-release.py-870-    rates_by_model = {
scripts/catalog-release.py-871-        row["model_id"]: row["proposed_rates"]
scripts/catalog-release.py-872-        for bucket in ("added", "changed", "unchanged")
scripts/catalog-release.py-873-        for row in replayed_rate[bucket]
scripts/catalog-release.py-874-    }
scripts/catalog-release.py-875-    recommendable = {key for key, row in candidate_obj["rows"].items() if row.get("runtime_status") == "recommendable"}
--
scripts/catalog-release.py-881-        if published is None:
scripts/catalog-release.py-882-            fail(f"market-peg: recommendable row {key!r} has no published rate row")
scripts/catalog-release.py-883-        for published_field, proposal_field in (
scripts/catalog-release.py-884-            ("prompt_rate_per_mtok", "prompt_rate_per_mtok"),
scripts/catalog-release.py-885-            ("prompt_cache_hit_rate_per_mtok", "prompt_cache_hit_rate_per_mtok"),
scripts/catalog-release.py-886-            ("completion_rate_per_mtok", "completion_rate_per_mtok"),
scripts/catalog-release.py-887-        ):
scripts/catalog-release.py-888-            if published[published_field] != proposal_rates[proposal_field]:
scripts/catalog-release.py:889:                fail(f"market-peg: rate-card row {key!r}.{published_field} does not match the proposal")
scripts/catalog-release.py-890-        if demand_obj["rows"][key]["demand_weight"] != replayed_demand["rows"][key]["demand_weight"]:
scripts/catalog-release.py-891-            fail(f"market-peg: demand-rank row {key!r}.demand_weight does not match the proposal")
scripts/catalog-release.py-892-    if demand_obj.get("source") != replayed_demand.get("source"):
scripts/catalog-release.py-893-        fail("market-peg: demand-rank source does not match the OpenRouter proposal")
scripts/catalog-release.py-894-    if not rates_by_model:
scripts/catalog-release.py-895-        fail("market-peg: replay produced no proposal rates")
scripts/catalog-release.py-896-    minimum_key = min(rates_by_model, key=lambda key: rates_by_model[key]["completion_rate_per_mtok"])
scripts/catalog-release.py-897-    minimum_rates = rates_by_model[minimum_key]
scripts/catalog-release.py-898-    for field in ("prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok"):
scripts/catalog-release.py-899-        if rate_card_obj["rows"]["default"][field] != minimum_rates[field]:
scripts/catalog-release.py:900:            fail(f"market-peg: rate-card default.{field} does not match the minimum-completion mapped row")
scripts/catalog-release.py-901-
scripts/catalog-release.py-902-
scripts/catalog-release.py-903-def rate_card_projection_hash(value: dict) -> str:
scripts/catalog-release.py-904-    def json_number(raw: int | float) -> str:
scripts/catalog-release.py-905-        if isinstance(raw, int):
scripts/catalog-release.py-906-            return str(raw)
scripts/catalog-release.py-907-        if raw.is_integer():
scripts/catalog-release.py-908-            return str(int(raw))
--
scripts/catalog-release.py-938-        '},"usd_per_million_credits":',
scripts/catalog-release.py-939-        json_number(value["usd_per_million_credits"]),
scripts/catalog-release.py-940-        "}",
scripts/catalog-release.py-941-    ])
scripts/catalog-release.py-942-    return sha256("".join(parts).encode())
scripts/catalog-release.py-943-
scripts/catalog-release.py-944-
scripts/catalog-release.py-945-def validate_rate_card(data: bytes) -> dict:
scripts/catalog-release.py:946:    value = strict_json(data, "rate-card")
scripts/catalog-release.py-947-    exact_keys(
scripts/catalog-release.py-948-        value,
scripts/catalog-release.py-949-        {"version", "policy_version", "generated_at", "usd_per_million_credits", "rows"},
scripts/catalog-release.py-950-        {"version", "policy_version", "generated_at", "usd_per_million_credits", "rows"},
scripts/catalog-release.py:951:        "rate-card",
scripts/catalog-release.py-952-    )
scripts/catalog-release.py-953-    if not isinstance(value["version"], str) or not value["version"].strip() or value["version"].strip() != value["version"]:
scripts/catalog-release.py:954:        fail("rate-card: version required")
scripts/catalog-release.py-955-    if not isinstance(value["policy_version"], str) or not value["policy_version"].strip() or value["policy_version"].strip() != value["policy_version"]:
scripts/catalog-release.py:956:        fail("rate-card: policy_version required")
scripts/catalog-release.py:957:    parse_time(value["generated_at"], "rate-card generated_at")
scripts/catalog-release.py-958-    usd = value["usd_per_million_credits"]
scripts/catalog-release.py-959-    if not isinstance(usd, (int, float)) or isinstance(usd, bool) or not math.isfinite(usd) or usd < 0:
scripts/catalog-release.py:960:        fail("rate-card: usd_per_million_credits must be finite and >= 0")
scripts/catalog-release.py-961-    rows = value["rows"]
scripts/catalog-release.py-962-    if not isinstance(rows, dict) or not rows:
scripts/catalog-release.py:963:        fail("rate-card: rows required")
scripts/catalog-release.py-964-    if "default" not in rows:
scripts/catalog-release.py:965:        fail("rate-card: default row required")
scripts/catalog-release.py-966-    row_fields = {
scripts/catalog-release.py-967-        "prompt_rate_per_mtok",
scripts/catalog-release.py-968-        "prompt_cache_hit_rate_per_mtok",
scripts/catalog-release.py-969-        "completion_rate_per_mtok",
scripts/catalog-release.py-970-        "provider_share_bps",
scripts/catalog-release.py-971-        "global_multiplier_ppm",
scripts/catalog-release.py-972-    }
scripts/catalog-release.py-973-    for key, row in rows.items():
scripts/catalog-release.py-974-        if key != "default":
scripts/catalog-release.py-975-            if not MODEL_KEY.fullmatch(key):
scripts/catalog-release.py:976:                fail(f"rate-card row {key}: invalid model key")
scripts/catalog-release.py-977-            # Same invariant as `validate_rate_card_source`, in the SHARED
scripts/catalog-release.py:978:            # validator so `verify-directory` and the parity gate enforce it on
scripts/catalog-release.py-979-            # bytes they did not generate: billing resolves exact spelling first.
scripts/catalog-release.py-980-            normalized = normalize_model_key(key)
scripts/catalog-release.py-981-            if normalized != key:

exec
/bin/bash -lc "rg -n '"'^def verify_directory|verify_directory'"\\(|RATE_CARD_BOUND|verify.*sidecar|release\\[\"feeds\"\\]' scripts/catalog-release.py && nl -ba scripts/catalog-release.py | sed -n '1140,1285p'" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
79:RATE_CARD_BOUND_LEDGER_FEEDS = TIER2_BOUND_LEDGER_FEEDS | {RATE_CARD_FEED_NAME}
80:ARTIFACT_BOUND_LEDGER_FEEDS = RATE_CARD_BOUND_LEDGER_FEEDS | {ARTIFACT_FEED_NAME}
2237:        if feed_names not in (LEGACY_LEDGER_FEEDS, TIER2_BOUND_LEDGER_FEEDS, RATE_CARD_BOUND_LEDGER_FEEDS, ARTIFACT_BOUND_LEDGER_FEEDS):
2242:                f"{sorted(RATE_CARD_BOUND_LEDGER_FEEDS)} (rate-card bound) or "
2382:    if set(base_feeds) != TIER2_BOUND_LEDGER_FEEDS or set(current_feeds) != RATE_CARD_BOUND_LEDGER_FEEDS:
2450:        if feed_names not in (RATE_CARD_BOUND_LEDGER_FEEDS, ARTIFACT_BOUND_LEDGER_FEEDS):
2453:                f"{sorted(RATE_CARD_BOUND_LEDGER_FEEDS)} feed membership"
4654:        verify_ed25519(public_key, signature, body, sidecar_path.name)
4662:def verify_directory(
4717:        verify_ed25519(public_key, signature, body, sidecar_path.name)
5328:            verify_directory(release)
5852:            verify_directory(
  1140	            continue
  1141	        name = rate_classes[key]
  1142	        entry = source_obj["classes"].get(name)
  1143	        if entry is None:
  1144	            fail(
  1145	                f"rate-card expansion: model key {key!r} declares rate_class {name!r} "
  1146	                "but the rate-card source has no rates for that class, and no explicit "
  1147	                f"row resolves for it by exact key or NormalizeModelKey ({normalized!r})"
  1148	            )
  1149	        owner = class_owner.get(normalized)
  1150	        if owner is not None:
  1151	            if owner[1] != name:
  1152	                fail(
  1153	                    f"rate-card expansion: model keys {owner[0]!r} and {key!r} both normalize to "
  1154	                    f"{normalized!r} but declare rate classes {owner[1]!r} and {name!r}; one "
  1155	                    "normalized key prices one way"
  1156	                )
  1157	            continue
  1158	        class_owner[normalized] = (key, name)
  1159	        rows[normalized] = dict(entry)
  1160	    for row in rows.values():
  1161	        row["provider_share_bps"] = source_obj["provider_share_bps"]
  1162	        row["global_multiplier_ppm"] = source_obj["global_multiplier_ppm"]
  1163	    value = {
  1164	        "generated_at": source_obj["generated_at"],
  1165	        "policy_version": source_obj["policy_version"],
  1166	        "rows": rows,
  1167	        "usd_per_million_credits": source_obj["usd_per_million_credits"],
  1168	        "version": "",
  1169	    }
  1170	    value["version"] = rate_card_projection_hash(value)
  1171	    rate_card = canonical_sorted_bytes(value)
  1172	    rate_card_obj = validate_rate_card(rate_card)
  1173	    require_recommendable_rate_rows(candidate_obj, rate_card_obj)
  1174	    return rate_card
  1175	
  1176	
  1177	def require_recommendable_rate_rows(candidate_obj: dict, rate_card_obj: dict) -> None:
  1178	    """SPEC-023 §3.3.1 rule 7 / AC-CAT-10: every `recommendable` candidate row MUST
  1179	    resolve to a concrete published rate row by exact key or `NormalizeModelKey`.
  1180	    Reaching only the `default` row does not satisfy the authoring-time invariant.
  1181	    """
  1182	    rows = rate_card_obj["rows"]
  1183	    for key, row in sorted(candidate_obj["rows"].items()):
  1184	        if row["runtime_status"] != "recommendable":
  1185	            continue
  1186	        if key in rows and key != "default":
  1187	            key_row = rows[key]
  1188	        else:
  1189	            normalized = normalize_model_key(key)
  1190	            if normalized not in rows or normalized == "default":
  1191	                fail(
  1192	                    f"rate-card: recommendable candidate row {key!r} resolves to no rate-card "
  1193	                    f"row by exact key or NormalizeModelKey ({normalized!r}); the default row "
  1194	                    "does not satisfy SPEC-023 §3.3.1 rule 7"
  1195	                )
  1196	            key_row = rows[normalized]
  1197	        served = row.get("model_id")
  1198	        if isinstance(served, str) and served:
  1199	            served_row = resolved_rate_row(rows, served)
  1200	            if served_row is None:
  1201	                fail(
  1202	                    f"rate-card: recommendable candidate row {key!r} served model_id {served!r} "
  1203	                    "resolves to no rate-card row by exact key or NormalizeModelKey; the default "
  1204	                    "row does not satisfy SPEC-023 §3.3.1 rule 7"
  1205	                )
  1206	            if served_row != key_row:
  1207	                fail(
  1208	                    f"rate-card: recommendable candidate row {key!r} and served model_id "
  1209	                    f"{served!r} resolve to different rate-card rows"
  1210	                )
  1211	
  1212	
  1213	def resolved_rate_row(rows: dict, key: str) -> dict | None:
  1214	    if key in rows and key != "default":
  1215	        return rows[key]
  1216	    normalized = normalize_model_key(key)
  1217	    if normalized in rows and normalized != "default":
  1218	        return rows[normalized]
  1219	    return None
  1220	
  1221	
  1222	def parse_coordinator_rewards(text: str) -> tuple[float, float, dict[str, dict]]:
  1223	    """Read `rewards.provider_share`, `rewards.global_multiplier`, and the inline
  1224	    `rewards.rate_card` fallback rows from the committed coordinator config.
  1225	
  1226	    Deliberately a narrow, fail-closed reader for exactly the block SPEC-023
  1227	    §3.3.1 rule 4 maps into, rather than a YAML dependency (this repo pins its
  1228	    dependency set) or a `sed`-shaped rewrite. Anything it does not recognise
  1229	    inside the block fails the release closed instead of being ignored.
  1230	    """
  1231	    share: str | None = None
  1232	    multiplier: str | None = None
  1233	    rows: dict[str, dict] = {}
  1234	    in_rewards = False
  1235	    in_rate_card = False
  1236	    current: str | None = None
  1237	    for raw_line in text.splitlines():
  1238	        if "\t" in raw_line:
  1239	            if raw_line.strip().startswith("#") or not raw_line.strip():
  1240	                continue
  1241	            if not in_rewards:
  1242	                # Tabs outside the block are the YAML loader's concern, not
  1243	                # this indentation parser's; do not misreport them as a
  1244	                # rewards-block defect.
  1245	                continue
  1246	            if raw_line[:1] not in (" ", "\t"):
  1247	                break  # a new top-level key ends the rewards block
  1248	            fail("coordinator.yaml: tabs are not permitted in the rewards block")
  1249	        line = re.sub(r"(?:(?<=\s)|^)#.*$", "", raw_line).rstrip()
  1250	        if not line.strip():
  1251	            continue
  1252	        indent = len(line) - len(line.lstrip(" "))
  1253	        body = line.strip()
  1254	        if indent == 0:
  1255	            if in_rewards:
  1256	                break
  1257	            in_rewards = body == "rewards:"
  1258	            continue
  1259	        if not in_rewards:
  1260	            continue
  1261	        if indent == 2:
  1262	            in_rate_card = False
  1263	            current = None
  1264	            if body == "rate_card:":
  1265	                in_rate_card = True
  1266	            elif body.startswith("provider_share:"):
  1267	                share = body.split(":", 1)[1].strip()
  1268	            elif body.startswith("global_multiplier:"):
  1269	                multiplier = body.split(":", 1)[1].strip()
  1270	            continue
  1271	        if not in_rate_card:
  1272	            continue
  1273	        if indent == 4:
  1274	            if not body.endswith(":"):
  1275	                fail(f"coordinator.yaml: unexpected rewards.rate_card entry {body!r}")
  1276	            current = body[:-1].strip().strip("\"'")
  1277	            if current in rows:
  1278	                fail(f"coordinator.yaml: duplicate rewards.rate_card row {current!r}")
  1279	            rows[current] = {}
  1280	            continue
  1281	        if indent == 6 and current is not None:
  1282	            name, _, value = body.partition(":")
  1283	            name = name.strip()
  1284	            if name not in COORDINATOR_RATE_FIELD_MAP.values():
  1285	                fail(f"coordinator.yaml: rewards.rate_card.{current}.{name} is not a credit field")

exec
/bin/bash -lc "nl -ba scripts/catalog-release.py | sed -n '4610,4745p'" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
  4610	    # `--previous-release-dir` this re-derives the same verdict `generate` reached
  4611	    # from the same authenticated input. Without it the verdict is not
  4612	    # reconstructible, and `verify` says so instead of passing silently: a
  4613	    # hand-assembled artifact-bound release that admits or promotes a row while
  4614	    # recording `null` is exactly what a silent pass would bless.
  4615	    if artifact_obj is not None:
  4616	        history = release_history(ledger, release_id)
  4617	        if previous_release_dir is not None:
  4618	            previous_release = load_previous_release(previous_release_dir, history)
  4619	            previous_tiers = previous_candidate_admission(candidate_obj, history, previous_release)
  4620	            require_intake_decision(
  4621	                candidate_obj,
  4622	                previous_tiers,
  4623	                intake_decision_digest(),
  4624	                activation=latest_artifact_bound_release(history) is None,
  4625	            )
  4626	            check_intake_decision_manifest(
  4627	                candidate_obj, artifact_obj, demand_obj, demand, previous_tiers,
  4628	                intake_audit_dir if intake_audit_dir is not None else default_intake_audit_dir(),
  4629	            )
  4630	            print(
  4631	                f"verified intake-decision transitions for {release_id} against "
  4632	                f"{previous_release['release_id']}"
  4633	            )
  4634	        else:
  4635	            # Without the previous release the TRANSITION rule cannot be
  4636	            # re-derived, but the committed manifest itself is still checked
  4637	            # against this release's inputs and retained sources.
  4638	            check_intake_decision_manifest(
  4639	                candidate_obj, artifact_obj, demand_obj, demand, None,
  4640	                intake_audit_dir if intake_audit_dir is not None else default_intake_audit_dir(),
  4641	            )
  4642	            print(
  4643	                f"verify: NOTICE: release {release_id} is artifact-bound and its "
  4644	                "intake_decision_sha256 transition rule (SPEC-023 §3.7.8) was NOT re-derived; "
  4645	                "pass --previous-release-dir <previous signed release directory> to check it"
  4646	            )
  4647	    keys = keyring()
  4648	    for path, body in expected.items():
  4649	        sidecar_path = pathlib.Path(str(path) + ".sig")
  4650	        key_id, signature = parse_sidecar(sidecar_path.read_bytes(), sidecar_path.name)
  4651	        public_key = keys.get(key_id)
  4652	        if public_key is None:
  4653	            fail(f"{sidecar_path.name}: unknown or retired key_id {key_id}")
  4654	        verify_ed25519(public_key, signature, body, sidecar_path.name)
  4655	    print(
  4656	        f"verified catalog release {candidate_obj['version']} "
  4657	        f"candidate={sha256(candidate)} demand={sha256(demand)} rate_card={sha256(rate_card)} "
  4658	        f"tier2_binding={sha256(TIER2_BINDING_PATH.read_bytes())} tier2_catalog={sha256(tier2)}"
  4659	    )
  4660	
  4661	
  4662	def verify_directory(
  4663	    directory: pathlib.Path,
  4664	    tier2_public_key_file: pathlib.Path | None = None,
  4665	    tier2_coordinator_config: pathlib.Path | None = None,
  4666	    tier2_coordinator_overlay: pathlib.Path | None = None,
  4667	    allow_expired_tier2: bool = False,
  4668	) -> None:
  4669	    candidate_path = directory / "autotune-candidates.json"
  4670	    demand_path = directory / "demand-rank.json"
  4671	    rate_card_path = directory / RATE_CARD_FEED_NAME
  4672	    for path in (candidate_path, demand_path, rate_card_path):
  4673	        if not path.exists():
  4674	            fail(f"release directory is missing required {path.name} feed")
  4675	    candidate = candidate_path.read_bytes()
  4676	    demand = demand_path.read_bytes()
  4677	    rate_card = rate_card_path.read_bytes()
  4678	    candidate_obj = validate_candidate(candidate)
  4679	    demand_obj = validate_demand(demand)
  4680	    rate_card_obj = validate_rate_card(rate_card)
  4681	    validate_release_inputs(candidate_obj, demand_obj, rate_card_obj)
  4682	    if candidate != canonical_bytes(candidate_obj) or demand != canonical_bytes(demand_obj) or rate_card != canonical_bytes(rate_card_obj):
  4683	        fail("release directory feeds are not deterministic canonical bytes")
  4684	    tier2_path = directory / "tier2-catalog.json"
  4685	    if not tier2_path.exists():
  4686	        fail("release directory is missing required tier2-catalog.json feed")
  4687	    tier2 = tier2_path.read_bytes()
  4688	    tier2_obj = validate_tier2_catalog(tier2, allow_expired=allow_expired_tier2)
  4689	    tier2_signer_key_id = verify_tier2_signature(
  4690	        tier2, tier2_public_key_file, tier2_coordinator_config, tier2_coordinator_overlay, allow_expired_tier2
  4691	    )
  4692	    check_tier2_binding(candidate, tier2)
  4693	    artifact_path = directory / ARTIFACT_FEED_NAME
  4694	    artifacts = artifact_obj = None
  4695	    signed_feeds = [(candidate_path, candidate), (demand_path, demand), (rate_card_path, rate_card)]
  4696	    if artifact_path.exists():
  4697	        artifacts = artifact_path.read_bytes()
  4698	        artifact_obj = validate_artifact_feed(artifacts, candidate, candidate_obj)
  4699	        if artifacts != canonical_sorted_bytes(artifact_obj):
  4700	            fail("release directory artifact feed is not deterministic canonical bytes")
  4701	        require_recommendable_rate_rows(candidate_obj, rate_card_obj)
  4702	        signed_feeds.append((artifact_path, artifacts))
  4703	    expected_manifest = manifest(
  4704	        candidate, demand, rate_card, candidate_obj, demand_obj, rate_card_obj, directory,
  4705	        tier2=tier2, tier2_obj=tier2_obj, tier2_signer_key_id=tier2_signer_key_id,
  4706	        artifacts=artifacts, artifact_obj=artifact_obj,
  4707	    )
  4708	    if (directory / "release.json").read_bytes() != expected_manifest:
  4709	        fail("release directory manifest does not bind the feed bytes")
  4710	    keys = keyring(directory / "trusted-keys.json")
  4711	    for path, body in signed_feeds:
  4712	        sidecar_path = pathlib.Path(str(path) + ".sig")
  4713	        key_id, signature = parse_sidecar(sidecar_path.read_bytes(), sidecar_path.name)
  4714	        public_key = keys.get(key_id)
  4715	        if public_key is None:
  4716	            fail(f"{sidecar_path.name}: unknown or retired key_id {key_id}")
  4717	        verify_ed25519(public_key, signature, body, sidecar_path.name)
  4718	    binding_path = directory / "tier2-identity-binding.json"
  4719	    if binding_path.exists():
  4720	        validate_tier2_identity_binding(binding_path.read_bytes(), candidate, candidate_obj)
  4721	        print(f"verified repo-local tier2 identity binding for {candidate_obj['version']}")
  4722	    print(f"verified tier2 catalog {tier2_obj['catalog_id']} feed membership against release {candidate_obj['version']}")
  4723	    print(f"verified release directory {candidate_obj['version']} candidate={sha256(candidate)} demand={sha256(demand)} rate_card={sha256(rate_card)}")
  4724	
  4725	
  4726	def cmd_emit_coordinator_rate_card(output_path: pathlib.Path | None, from_source: bool = False) -> None:
  4727	    """Emit the `rewards.rate_card:` block that the release's published rate card
  4728	    requires of `phase4-coordinator/dist/coordinator.yaml` (SPEC-023 §3.3.1 rule 4).
  4729	
  4730	    The generator emits rather than rewrites: coordinator.yaml carries reviewed
  4731	    money-path provenance comments, so the operator pastes the changed rows into
  4732	    the reviewed config and the rule-9 parity gate (`check_rate_card_parity`,
  4733	    enforced by `generate` and `verify`) then refuses to cut a release until the
  4734	    two sides agree row-for-row.
  4735	
  4736	    The `rate_class` map comes from `authoring_rate_classes`, so a class-only row
  4737	    projects its coordinator fallback BEFORE the activation release publishes the
  4738	    artifact feed. Emitting is a projection of reviewed authoring inputs, not a
  4739	    verification of published bytes: requiring the published feed here would make
  4740	    the first activation circular, since the release that publishes it will not be
  4741	    cut until parity already holds.
  4742	    """
  4743	    candidate_obj = validate_candidate((CATALOG_DIR / "autotune-candidates.json").read_bytes())
  4744	    if from_source:
  4745	        # Post-activation the source and the published feed legitimately

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '700,725p;3660,3680p;4280,4312p' && git diff --unified=5 origin/main...HEAD" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
   700	    python3 -I "$PINNED_REPOSITORY_DIR/scripts/catalog-release.py" verify
   701	fi
   702	# SPEC-023 §3.7.8 Stage A: release.json decides whether the artifact feed and
   703	# its sidecar are members of the immutable release envelope. verify-directory
   704	# rejects a five-feed release.json beside nine files (and nine-file bytes
   705	# beside a stray pair), so presence must follow the binding exactly, and a
   706	# bound release whose feed is missing from the checkout aborts here.
   707	AUTOTUNE_ARTIFACT_BOUND="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
   708	import json, pathlib, sys
   709	feeds = json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]
   710	print("bound" if "autotune-artifacts.json" in feeds else "unbound")
   711	PY
   712	)"
   713	AUTOTUNE_ARTIFACT_CONTENT_JSON=""
   714	AUTOTUNE_ARTIFACT_CONTENT_SIG=""
   715	if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
   716	  [ -f "$STATIC_ARTIFACTS_JSON" ] && [ -f "$STATIC_ARTIFACTS_SIG" ] || {
   717	    echo "aborting deploy: release.json binds autotune-artifacts.json but $STATIC_FEEDS_DIR lacks the feed or its sidecar" >&2
   718	    exit 1
   719	  }
   720	  AUTOTUNE_ARTIFACT_CONTENT_JSON="$STATIC_ARTIFACTS_JSON"
   721	  AUTOTUNE_ARTIFACT_CONTENT_SIG="$STATIC_ARTIFACTS_SIG"
   722	fi
   723	AUTOTUNE_RELEASE_ID="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
   724	import json, pathlib, sys
   725	print(json.loads(pathlib.Path(sys.argv[1]).read_text())["release_id"])
  3660	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json.sig \$_autotune_stage/rate-card.json.sig$AUTOTUNE_ARTIFACT_INSTALL_LINES
  3661	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json
  3662	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/release.json \$_autotune_stage/release.json
  3663	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/trusted-keys.json \$_autotune_stage/trusted-keys.json
  3664	  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_stage --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
  3665	  sync
  3666	  if [ -e \$_autotune_release ]; then
  3667	    if ! diff -qr \$_autotune_stage \$_autotune_release >/dev/null; then
  3668	      echo 'catalog release envelope $AUTOTUNE_RELEASE_DIR_NAME already exists with different bytes' >&2
  3669	      exit 1
  3670	    fi
  3671	    rm -rf \$_autotune_stage
  3672	  else
  3673	    mv \$_autotune_stage \$_autotune_release
  3674	  fi
  3675	  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_release --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
  3676	  # First rollout: the new on-disk coordinator config already points at
  3677	  # autotune/current. Establish that path as soon as the immutable release is
  3678	  # staged so an abort before the late restart gate cannot leave the next
  3679	  # service restart without feeds. Existing rollouts remain untouched here.
  3680	  if [ ! -e \$_autotune_root/current ] && [ ! -L \$_autotune_root/current ]; then
  4280	}
  4281	for STATIC_SPEC in \
  4282	    "/v1/rate-card|rate-card.json|$STATIC_RATE_CARD_JSON" \
  4283	    "/v1/rate-card.sig|rate-card.json.sig|$STATIC_RATE_CARD_SIG" \
  4284	    "/v1/demand-rank|demand-rank.json|$STATIC_DEMAND_JSON" \
  4285	    "/v1/demand-rank.sig|demand-rank.json.sig|$STATIC_DEMAND_SIG" \
  4286	    "/v1/autotune-candidates|autotune-candidates.json|$STATIC_AUTOTUNE_JSON" \
  4287	    "/v1/autotune-candidates.sig|autotune-candidates.json.sig|$STATIC_AUTOTUNE_SIG"; do
  4288	  STATIC_PATH="${STATIC_SPEC%%|*}"
  4289	  STATIC_REST="${STATIC_SPEC#*|}"
  4290	  STATIC_NAME="${STATIC_REST%%|*}"
  4291	  STATIC_EXPECTED="${STATIC_REST#*|}"
  4292	  STATIC_SMOKE_BODY="$STATIC_SMOKE_DIR/$STATIC_NAME"
  4293	  echo "  GET https://$DOMAIN$STATIC_PATH -> expect 200"
  4294	  STATUS=$(curl -sS -o "$STATIC_SMOKE_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 "https://$DOMAIN$STATIC_PATH")
  4295	  if [ "$STATUS" != "200" ]; then
  4296	    echo "SPEC-023 autotune feed smoke failed: $STATIC_PATH status=$STATUS body=$(head -c 200 "$STATIC_SMOKE_BODY")" >&2
  4297	    exit 1
  4298	  fi
  4299	  if ! cmp -s "$STATIC_EXPECTED" "$STATIC_SMOKE_BODY"; then
  4300	    echo "SPEC-023 autotune feed smoke failed: $STATIC_PATH bytes differ from staged release" >&2
  4301	    exit 1
  4302	  fi
  4303	done
  4304	cp "$AUTOTUNE_RELEASE_MANIFEST" "$STATIC_SMOKE_DIR/release.json"
  4305	cp "$AUTOTUNE_TRUSTED_KEYS" "$STATIC_SMOKE_DIR/trusted-keys.json"
  4306	cp "$AUTOTUNE_TIER2_JSON" "$STATIC_SMOKE_DIR/tier2-catalog.json"
  4307	cp "$STATIC_RATE_CARD_JSON" "$STATIC_SMOKE_DIR/rate-card.json"
  4308	cp "$STATIC_RATE_CARD_SIG" "$STATIC_SMOKE_DIR/rate-card.json.sig"
  4309	python3 "$AUTOTUNE_RELEASE_VERIFY" verify-directory --directory "$STATIC_SMOKE_DIR"
  4310	AUTOTUNE_STATUS_BODY="$STATIC_SMOKE_DIR/autotune-release-status.json"
  4311	STATUS=$(curl -sS -o "$AUTOTUNE_STATUS_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 "https://$DOMAIN/v1/autotune-release")
  4312	if [ "$STATUS" != "200" ]; then
diff --git a/phase4-coordinator/dist/deploy-pearl-vps.sh b/phase4-coordinator/dist/deploy-pearl-vps.sh
index 008c3925..3f00b577 100755
--- a/phase4-coordinator/dist/deploy-pearl-vps.sh
+++ b/phase4-coordinator/dist/deploy-pearl-vps.sh
@@ -4687,10 +4687,12 @@ if ! python3 - \
   "$AUTOTUNE_TRUSTED_KEYS" \
   "$STATIC_AUTOTUNE_JSON" \
   "$STATIC_AUTOTUNE_SIG" \
   "$STATIC_DEMAND_JSON" \
   "$STATIC_DEMAND_SIG" \
+  "$STATIC_RATE_CARD_JSON" \
+  "$STATIC_RATE_CARD_SIG" \
   "$AUTOTUNE_TIER2_JSON" <<'PY'
 import hashlib, json, pathlib, re, sys
 
 proof = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
 pool = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
diff --git a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
index a7745788..292e99c4 100755
--- a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
+++ b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
@@ -482,13 +482,36 @@ grep -q 'value.get("catalog_evidence_source") != "provider_reported"' "$DEPLOY_S
   fail "deploy must treat coordinator catalog fields as provider-reported compatibility evidence"
 
 grep -q 'value.get("catalog_admission_mode") != "current"' "$DEPLOY_SH" ||
   fail "deploy canary must reject legacy and previous catalog admissions"
 
-grep -A1 -F '  "$STATIC_DEMAND_SIG" \' "$DEPLOY_SH" |
-  grep -qF '  "$AUTOTUNE_TIER2_JSON" <<'"'"'PY'"'"'' ||
-  fail "deploy canary expected-byte set must include the release-bound Tier-2 catalog"
+# The Mac proof hashes every name in its `names` tuple, and the exact-byte
+# check compares that dict to the basenames of its expected argv files, so
+# the two sets must be equal. Before this check the rate card and its sidecar
+# were proven but never expected, so no canary could pass.
+python3 - "$DEPLOY_SH" <<'PY' || fail "deploy canary expected-byte set must equal the file set the Mac proof hashes"
+import re, sys
+text = open(sys.argv[1], encoding="utf-8").read()
+names_block = re.search(r'\n    names = \(\n(.*?)\n    \)\n', text, re.S)
+if names_block is None:
+    raise SystemExit("canary proof names tuple not found")
+proven = set(re.findall(r'"([^"]+)"', names_block.group(1)))
+check = re.search(r'  "\$CATALOG_CANARY_PROVIDER_ID" \\\n((?:  "\$[A-Z0-9_]+" \\\n)*)  "\$([A-Z0-9_]+)" <<\'PY\'\nimport hashlib, json, pathlib, re, sys\n\nproof = json.loads', text)
+if check is None:
+    raise SystemExit("canary exact-byte check argv not found")
+variables = re.findall(r'"\$([A-Z0-9_]+)"', check.group(1)) + [check.group(2)]
+basenames = set()
+for variable in variables:
+    assignment = re.search(r'(?m)^' + variable + r'="[^"\n]*/([^/"\n]+)"$', text)
+    if assignment is None:
+        raise SystemExit(f"no path assignment for {variable}")
+    basenames.add(assignment.group(1))
+if basenames != proven:
+    raise SystemExit(f"proven={sorted(proven)} expected={sorted(basenames)}")
+if "tier2-catalog.json" not in basenames or "rate-card.json.sig" not in basenames:
+    raise SystemExit("expected set must include the Tier-2 catalog and the signed rate card")
+PY
 
 grep -q 'value.get("catalog_candidate_sha256") != sys.argv\[6\]' "$DEPLOY_SH" ||
   fail "deploy canary must match the active candidate catalog digest"
 
 grep -q 'read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY' "$DEPLOY_SH" &&

codex
Security/money-path audit: no findings.

- `phase4-coordinator/dist/deploy-pearl-vps.sh:4692-4693` now includes both rate-card files in the expected hash set.
- The canary proof hashes both files at `:4569-4570`; dictionary equality at `:4726` rejects missing, extra, or mismatched bytes.
- Existing release verification validates the rate-card signature before deployment (`scripts/catalog-release.py:4669-4717`).
- Canary failure still exits before commit; rollback behavior is unchanged.
- Existing focused test passed with exit 0:
  `bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh`
- `git diff --check` passed.

VERDICT: PASS
tokens used
97 396

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
