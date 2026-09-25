# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-09-25T07:35:56.027Z

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
## Lane: CODE

Check:
- Correctness of the argv order and the basename mapping.
- Whether the pinned rate-card paths are the same bytes the deploy verifies and activates.
- Whether the test would catch any future divergence between the proven and expected sets.
- Any other file the proof reads that the check omits, or the reverse.

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
## Lane: CODE

Check:
- Correctness of the argv order and the basename mapping.
- Whether the pinned rate-card paths are the same bytes the deploy verifies and activates.
- Whether the test would catch any future divergence between the proven and expected sets.
- Any other file the proof reads that the check omits, or the reverse.

## Raw output

```text
No findings. The CODE lane passes:

- `deploy-pearl-vps.sh:4562-4576` hashes nine files; `:4682-4694` supplies the matching nine expected paths. Rate-card JSON and signature precede Tier-2 correctly.
- The pinned rate-card paths are used consistently for upload, staging, release verification, smoke comparison, and final byte checking (`:3340-3341`, `:3659-3664`, `:4692-4693`).
- The regression test compares the proven and expected basename sets (`check_deploy_static_feed_access.test.sh:487-512`), catching future set divergence.
- Existing test passed with exit 0. No malformed payloads were constructed.

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
session id: 01a0d77c-2ada-7013-9f35-6a76384c0be2
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
## Lane: CODE

Check:
- Correctness of the argv order and the basename mapping.
- Whether the pinned rate-card paths are the same bytes the deploy verifies and activates.
- Whether the test would catch any future divergence between the proven and expected sets.
- Any other file the proof reads that the check omits, or the reverse.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: failed to parse hooks config /Users/augstar/.codex/hooks.json: unknown field `state`, expected `description` or `hooks` at line 2 column 9
codex
I’ll audit the requested diff as a read-only code lane, trace the catalog-proof file sets and argv/basename mapping, then run only the existing targeted test. I’ll report only evidence-backed C/H/M findings with file:line, scenario, and fix, ending with the required verdict.
exec
/bin/bash -lc 'git diff --name-only origin/main...HEAD' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
phase4-coordinator/dist/deploy-pearl-vps.sh
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh

exec
/bin/bash -lc 'rg -n -C 8 "run_catalog_canary_mac_proof|STATIC_RATE_CARD|rate-card|demand-rank|catalog-release|expected|actual" phase4-coordinator/dist/deploy-pearl-vps.sh test/integration/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-canary-ratecard
 exited 2 in 0ms:
rg: test/integration/check_deploy_static_feed_access.test.sh: No such file or directory (os error 2)
phase4-coordinator/dist/deploy-pearl-vps.sh-45-#                    token sources are unset. Default:
phase4-coordinator/dist/deploy-pearl-vps.sh-46-#                    macprovider.catalog-canary.operator-token.
phase4-coordinator/dist/deploy-pearl-vps.sh-47-#   CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT optional Keychain account.
phase4-coordinator/dist/deploy-pearl-vps.sh-48-#                    Default: current USER.
phase4-coordinator/dist/deploy-pearl-vps.sh-49-#   CATALOG_CANARY_SSH_TARGET required for production deploys. SSH target for
phase4-coordinator/dist/deploy-pearl-vps.sh-50-#                    the operator-controlled canary Mac (for example user@host).
phase4-coordinator/dist/deploy-pearl-vps.sh-51-#   CATALOG_CANARY_SSH_KEY default: ~/.ssh/macprovider_canary_ed25519
phase4-coordinator/dist/deploy-pearl-vps.sh-52-#                    Key used only to read exact installed catalog bytes.
phase4-coordinator/dist/deploy-pearl-vps.sh:53:#   CATALOG_CANARY_INSTALL_DIR default: macprovider/catalog-release
phase4-coordinator/dist/deploy-pearl-vps.sh-54-#                    Catalog path relative to the canary user's home.
phase4-coordinator/dist/deploy-pearl-vps.sh-55-#   --dry-run-local  developer-only: run the old local-config C2 check using
phase4-coordinator/dist/deploy-pearl-vps.sh-56-#                    GATEWAY_CONFIG and exit before any SSH mutation.
phase4-coordinator/dist/deploy-pearl-vps.sh-57-#   GATEWAY_CONFIG   used only with --dry-run-local. Production deploys validate
phase4-coordinator/dist/deploy-pearl-vps.sh-58-#                    the gateway config installed on Pearl.
phase4-coordinator/dist/deploy-pearl-vps.sh-59-#   GATEWAY_REMOTE_CONFIG  installed gateway config path on Pearl.
phase4-coordinator/dist/deploy-pearl-vps.sh-60-#                    Default: /opt/macprovider/gateway.yaml.
phase4-coordinator/dist/deploy-pearl-vps.sh-61-#   C2C_COORD_OPERATOR_KEY_SHA256, C2C_COORD_SERVICE_TOKEN_SHA256,
--
phase4-coordinator/dist/deploy-pearl-vps.sh-151-EMAIL="${EMAIL:-augstar@gmail.com}"
phase4-coordinator/dist/deploy-pearl-vps.sh-152-CATALOG_CANARY_PROVIDER_ID="${CATALOG_CANARY_PROVIDER_ID:-}"
phase4-coordinator/dist/deploy-pearl-vps.sh-153-CATALOG_CANARY_AUTH_TOKEN="${CATALOG_CANARY_AUTH_TOKEN:-}"
phase4-coordinator/dist/deploy-pearl-vps.sh-154-CATALOG_CANARY_AUTH_TOKEN_FILE="${CATALOG_CANARY_AUTH_TOKEN_FILE:-}"
phase4-coordinator/dist/deploy-pearl-vps.sh-155-CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE="${CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE:-macprovider.catalog-canary.operator-token}"
phase4-coordinator/dist/deploy-pearl-vps.sh-156-CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT="${CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT:-${USER:-}}"
phase4-coordinator/dist/deploy-pearl-vps.sh-157-CATALOG_CANARY_SSH_TARGET="${CATALOG_CANARY_SSH_TARGET:-}"
phase4-coordinator/dist/deploy-pearl-vps.sh-158-CATALOG_CANARY_SSH_KEY="${CATALOG_CANARY_SSH_KEY:-$HOME/.ssh/macprovider_canary_ed25519}"
phase4-coordinator/dist/deploy-pearl-vps.sh:159:CATALOG_CANARY_INSTALL_DIR="${CATALOG_CANARY_INSTALL_DIR:-macprovider/catalog-release}"
phase4-coordinator/dist/deploy-pearl-vps.sh-160-CONFIG_MODE="${CONFIG_MODE:-preserve-live}"
phase4-coordinator/dist/deploy-pearl-vps.sh-161-case "$CONFIG_MODE" in
phase4-coordinator/dist/deploy-pearl-vps.sh-162-  preserve-live|apply-tracked) ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-163-  *)
phase4-coordinator/dist/deploy-pearl-vps.sh-164-    echo "aborting deploy: CONFIG_MODE must be preserve-live or apply-tracked, got: $CONFIG_MODE" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-165-    exit 2
phase4-coordinator/dist/deploy-pearl-vps.sh-166-    ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-167-esac
--
phase4-coordinator/dist/deploy-pearl-vps.sh-299-  if [ -z "$tag_object" ] || [ "$peeled_count" != 1 ] || [ "$peeled_commit" != "$head" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-300-    echo "aborting deploy: $tag is not the protected remote annotated tag for HEAD on $release_tag_remote" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-301-    return 1
phase4-coordinator/dist/deploy-pearl-vps.sh-302-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-303-  printf '%s %s\n' "$tag" "$head"
phase4-coordinator/dist/deploy-pearl-vps.sh-304-}
phase4-coordinator/dist/deploy-pearl-vps.sh-305-
phase4-coordinator/dist/deploy-pearl-vps.sh-306-_coordinator_verify_deployed_version() {
phase4-coordinator/dist/deploy-pearl-vps.sh:307:  local healthz_body="$1" expected_version="$2" deployed_version
phase4-coordinator/dist/deploy-pearl-vps.sh-308-  deployed_version=$(printf '%s' "$healthz_body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version', '?'))" 2>/dev/null || echo "?")
phase4-coordinator/dist/deploy-pearl-vps.sh-309-  if [ "$deployed_version" = "?" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-310-    echo "  CRITICAL provenance MISSING: /healthz returned no \"version\" field" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-311-    echo "           This almost certainly means the deployed binary predates the" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-312-    echo "           M0-5 instrumentation (PR #18) and the rollback gate is bypassed." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:313:    echo "           Expected was: $expected_version" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-314-    echo "           See audits/2026-06-10/ROLLBACK_PROCEDURE.md to replace the live binary." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-315-    return 7
phase4-coordinator/dist/deploy-pearl-vps.sh:316:  elif [ "$deployed_version" = "$expected_version" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:317:    echo "  provenance OK: deployed=$deployed_version | expected=$expected_version"
phase4-coordinator/dist/deploy-pearl-vps.sh-318-  else
phase4-coordinator/dist/deploy-pearl-vps.sh:319:    echo "  aborting deploy: provenance mismatch: deployed=$deployed_version | expected=$expected_version" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-320-    echo "       (deployed binary does not match the exact local release tag — rollback before commit)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-321-    return 8
phase4-coordinator/dist/deploy-pearl-vps.sh-322-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-323-}
phase4-coordinator/dist/deploy-pearl-vps.sh-324-
phase4-coordinator/dist/deploy-pearl-vps.sh-325-_tier2_migration_gate_remote_script() {
phase4-coordinator/dist/deploy-pearl-vps.sh-326-  cat <<'SH'
phase4-coordinator/dist/deploy-pearl-vps.sh-327-set -eu
--
phase4-coordinator/dist/deploy-pearl-vps.sh-488-if [ "$DRY_RUN_LOCAL" != "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-489-  COORDINATOR_RELEASE_IDENTITY="$(_coordinator_release_tag_version "$MODULE_DIR")" || exit 2
phase4-coordinator/dist/deploy-pearl-vps.sh-490-  COORDINATOR_RELEASE_VERSION="${COORDINATOR_RELEASE_IDENTITY%% *}"
phase4-coordinator/dist/deploy-pearl-vps.sh-491-  COORDINATOR_RELEASE_COMMIT="${COORDINATOR_RELEASE_IDENTITY#* }"
phase4-coordinator/dist/deploy-pearl-vps.sh-492-  echo "  release tag OK: $COORDINATOR_RELEASE_VERSION @ $COORDINATOR_RELEASE_COMMIT"
phase4-coordinator/dist/deploy-pearl-vps.sh-493-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-494-
phase4-coordinator/dist/deploy-pearl-vps.sh-495-# #1688: scripts/catalog-verifier-bundle.txt is the one list of files every
phase4-coordinator/dist/deploy-pearl-vps.sh:496:# shipped copy of catalog-release.py needs beside it. Entries become archive
phase4-coordinator/dist/deploy-pearl-vps.sh-497-# paths and remote file names, so reject anything but plain scripts/<name>.
phase4-coordinator/dist/deploy-pearl-vps.sh-498-_parse_catalog_verifier_bundle() {
phase4-coordinator/dist/deploy-pearl-vps.sh-499-  _bundle_seen=" "
phase4-coordinator/dist/deploy-pearl-vps.sh-500-  while IFS= read -r _bundle_line || [ -n "$_bundle_line" ]; do
phase4-coordinator/dist/deploy-pearl-vps.sh-501-    case "$_bundle_line" in '#'*) continue ;; esac
phase4-coordinator/dist/deploy-pearl-vps.sh-502-    if ! printf '%s\n' "$_bundle_line" | grep -Eq '^scripts/[A-Za-z0-9._-]+$' ||
phase4-coordinator/dist/deploy-pearl-vps.sh-503-      [ "$_bundle_line" = "scripts/." ] || [ "$_bundle_line" = "scripts/.." ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-504-      echo "aborting deploy: invalid catalog verifier bundle entry: '$_bundle_line'" >&2
--
phase4-coordinator/dist/deploy-pearl-vps.sh-509-        echo "aborting deploy: duplicate catalog verifier bundle entry: $_bundle_line" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-510-        return 1
phase4-coordinator/dist/deploy-pearl-vps.sh-511-        ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-512-    esac
phase4-coordinator/dist/deploy-pearl-vps.sh-513-    _bundle_seen="$_bundle_seen$_bundle_line "
phase4-coordinator/dist/deploy-pearl-vps.sh-514-    printf '%s\n' "$_bundle_line"
phase4-coordinator/dist/deploy-pearl-vps.sh-515-  done
phase4-coordinator/dist/deploy-pearl-vps.sh-516-  case "$_bundle_seen" in
phase4-coordinator/dist/deploy-pearl-vps.sh:517:    *" scripts/catalog-release.py "*) ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-518-    *)
phase4-coordinator/dist/deploy-pearl-vps.sh:519:      echo "aborting deploy: catalog verifier bundle must list scripts/catalog-release.py" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-520-      return 1
phase4-coordinator/dist/deploy-pearl-vps.sh-521-      ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-522-  esac
phase4-coordinator/dist/deploy-pearl-vps.sh-523-}
phase4-coordinator/dist/deploy-pearl-vps.sh-524-
phase4-coordinator/dist/deploy-pearl-vps.sh-525-PINNED_DEPLOY_INPUT_DIR=""
phase4-coordinator/dist/deploy-pearl-vps.sh-526-PINNED_REPOSITORY_DIR=""
phase4-coordinator/dist/deploy-pearl-vps.sh-527-PINNED_DIST_DIR="$DIST_DIR"
--
phase4-coordinator/dist/deploy-pearl-vps.sh-556-  # Issue #1721: the exact-copy gates below compare Pearl's live coordinator,
phase4-coordinator/dist/deploy-pearl-vps.sh-557-  # coordinator-cli, and stats sidecars with these bytes and never install
phase4-coordinator/dist/deploy-pearl-vps.sh-558-  # different ones. Take them from the verified signed Pearl runtime release
phase4-coordinator/dist/deploy-pearl-vps.sh-559-  # that macprovider-pearl-update installs, never from a local dist/ build.
phase4-coordinator/dist/deploy-pearl-vps.sh-560-  PINNED_RUNTIME_ARTIFACT_DIR="$PINNED_DEPLOY_INPUT_DIR/pearl-runtime-release"
phase4-coordinator/dist/deploy-pearl-vps.sh-561-  install -d -m 0700 "$PINNED_RUNTIME_ARTIFACT_DIR"
phase4-coordinator/dist/deploy-pearl-vps.sh-562-  GH_HOST=github.com bash "$REPO_ROOT/scripts/verify-pearl-runtime-release.sh" \
phase4-coordinator/dist/deploy-pearl-vps.sh-563-    --tag "$COORDINATOR_RELEASE_VERSION" \
phase4-coordinator/dist/deploy-pearl-vps.sh:564:    --expected-commit "$COORDINATOR_RELEASE_COMMIT" \
phase4-coordinator/dist/deploy-pearl-vps.sh-565-    --repository "Augustas11/macprovider" \
phase4-coordinator/dist/deploy-pearl-vps.sh-566-    --remote "origin" \
phase4-coordinator/dist/deploy-pearl-vps.sh-567-    --deploy-artifacts-dir "$PINNED_RUNTIME_ARTIFACT_DIR"
phase4-coordinator/dist/deploy-pearl-vps.sh-568-  PINNED_STATIC_FEEDS_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/dist/static"
phase4-coordinator/dist/deploy-pearl-vps.sh-569-  PINNED_AUTOTUNE_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/catalog/autotune"
phase4-coordinator/dist/deploy-pearl-vps.sh-570-  PINNED_SCRIPTS_DIR="$PINNED_DEPLOY_INPUT_DIR/scripts"
phase4-coordinator/dist/deploy-pearl-vps.sh-571-else
phase4-coordinator/dist/deploy-pearl-vps.sh-572-  PINNED_REPOSITORY_DIR="$REPO_ROOT"
--
phase4-coordinator/dist/deploy-pearl-vps.sh-578-if ! printf '%s' "$EMAIL" | grep -Eq '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
phase4-coordinator/dist/deploy-pearl-vps.sh-579-  echo "aborting deploy: EMAIL is not a valid address: '$EMAIL'" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-580-  exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-581-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-582-if [ "$DRY_RUN_LOCAL" != "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-583-  _load_catalog_canary_auth_token
phase4-coordinator/dist/deploy-pearl-vps.sh-584-  if ! printf '%s' "$CATALOG_CANARY_PROVIDER_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
phase4-coordinator/dist/deploy-pearl-vps.sh-585-    echo "aborting deploy: CATALOG_CANARY_PROVIDER_ID is required and must be a safe provider ID" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:586:    echo "  Select a provider expected to reconnect after restart; deployment commits only after pool admission." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-587-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-588-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-589-  if ! _validate_catalog_canary_auth_token "$CATALOG_CANARY_AUTH_TOKEN"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-590-    echo "aborting deploy: CATALOG_CANARY_AUTH_TOKEN is required and must be a safe 32-512 character bearer token" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-591-    echo "  Provide it via CATALOG_CANARY_AUTH_TOKEN, CATALOG_CANARY_AUTH_TOKEN_FILE, or macOS Keychain service=$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE account=$CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-592-    echo "  The deploy will later prove this secret matches Pearl's coordinator operator key by SHA-256; it never copies key material from Pearl." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-593-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-594-  fi
--
phase4-coordinator/dist/deploy-pearl-vps.sh-658-# installed below alongside the coordinator vhost.
phase4-coordinator/dist/deploy-pearl-vps.sh-659-NGINX_STATS_SHARED="$PINNED_DIST_DIR/nginx-snippets/stats-shared.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-660-NGINX_STATS_SECHEADERS="$PINNED_DIST_DIR/nginx-snippets/stats-security-headers.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-661-NGINX_STATS_CORS_429="$PINNED_DIST_DIR/nginx-snippets/cors-429.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-662-NGINX_STATS_PROXY_PUBLIC="$PINNED_DIST_DIR/nginx-snippets/stats-proxy-public.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-663-NGINX_STATS_PROXY_PARTNER="$PINNED_DIST_DIR/nginx-snippets/stats-proxy-partner.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-664-NGINX_STATS_SITE="$PINNED_DIST_DIR/nginx-stats.malibu.tech.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-665-# SPEC-023 signed recommendation feeds served on the buyer mux at
phase4-coordinator/dist/deploy-pearl-vps.sh:666:# /v1/rate-card, /v1/demand-rank and /v1/autotune-candidates (+ .sig sidecars).
phase4-coordinator/dist/deploy-pearl-vps.sh-667-# Files live in phase3-binary/dist/static/ in the repo. Deploy installs
phase4-coordinator/dist/deploy-pearl-vps.sh-668-# them into /opt/macprovider/autotune/ for coordinator startup load.
phase4-coordinator/dist/deploy-pearl-vps.sh-669-STATIC_FEEDS_DIR="$PINNED_STATIC_FEEDS_DIR"
phase4-coordinator/dist/deploy-pearl-vps.sh:670:STATIC_DEMAND_JSON="$STATIC_FEEDS_DIR/demand-rank.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:671:STATIC_DEMAND_SIG="$STATIC_FEEDS_DIR/demand-rank.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-672-STATIC_AUTOTUNE_JSON="$STATIC_FEEDS_DIR/autotune-candidates.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-673-STATIC_AUTOTUNE_SIG="$STATIC_FEEDS_DIR/autotune-candidates.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh:674:STATIC_RATE_CARD_JSON="$STATIC_FEEDS_DIR/rate-card.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:675:STATIC_RATE_CARD_SIG="$STATIC_FEEDS_DIR/rate-card.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-676-STATIC_ARTIFACTS_JSON="$STATIC_FEEDS_DIR/autotune-artifacts.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-677-STATIC_ARTIFACTS_SIG="$STATIC_FEEDS_DIR/autotune-artifacts.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-678-AUTOTUNE_RELEASE_MANIFEST="$PINNED_AUTOTUNE_DIR/release.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-679-AUTOTUNE_TRUSTED_KEYS="$PINNED_AUTOTUNE_DIR/trusted-keys.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-680-AUTOTUNE_TIER2_JSON="$PINNED_AUTOTUNE_DIR/tier2-catalog.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:681:AUTOTUNE_RELEASE_VERIFY="$PINNED_SCRIPTS_DIR/catalog-release.py"
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
phase4-coordinator/dist/deploy-pearl-vps.sh:693:  python3 -I "$PINNED_REPOSITORY_DIR/scripts/catalog-release.py" verify
phase4-coordinator/dist/deploy-pearl-vps.sh-694-else
phase4-coordinator/dist/deploy-pearl-vps.sh-695-  PINNED_GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"
phase4-coordinator/dist/deploy-pearl-vps.sh-696-  env -u OPENSSL_BIN -u MACPROVIDER_INTAKE_AUDIT_DIR \
phase4-coordinator/dist/deploy-pearl-vps.sh-697-    GIT_DIR="$PINNED_GIT_DIR" \
phase4-coordinator/dist/deploy-pearl-vps.sh-698-    GIT_NO_REPLACE_OBJECTS=1 \
phase4-coordinator/dist/deploy-pearl-vps.sh-699-    CATALOG_RELEASE_BASE_REF="$COORDINATOR_RELEASE_COMMIT^" \
phase4-coordinator/dist/deploy-pearl-vps.sh:700:    python3 -I "$PINNED_REPOSITORY_DIR/scripts/catalog-release.py" verify
phase4-coordinator/dist/deploy-pearl-vps.sh-701-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-702-# SPEC-023 §3.7.8 Stage A: release.json decides whether the artifact feed and
phase4-coordinator/dist/deploy-pearl-vps.sh-703-# its sidecar are members of the immutable release envelope. verify-directory
phase4-coordinator/dist/deploy-pearl-vps.sh-704-# rejects a five-feed release.json beside nine files (and nine-file bytes
phase4-coordinator/dist/deploy-pearl-vps.sh-705-# beside a stray pair), so presence must follow the binding exactly, and a
phase4-coordinator/dist/deploy-pearl-vps.sh-706-# bound release whose feed is missing from the checkout aborts here.
phase4-coordinator/dist/deploy-pearl-vps.sh-707-AUTOTUNE_ARTIFACT_BOUND="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-708-import json, pathlib, sys
--
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
phase4-coordinator/dist/deploy-pearl-vps.sh:770:    ("demand-rank.json", pathlib.Path(sys.argv[6])),
phase4-coordinator/dist/deploy-pearl-vps.sh:771:    ("demand-rank.json.sig", pathlib.Path(sys.argv[7])),
phase4-coordinator/dist/deploy-pearl-vps.sh:772:    ("rate-card.json", pathlib.Path(sys.argv[8])),
phase4-coordinator/dist/deploy-pearl-vps.sh:773:    ("rate-card.json.sig", pathlib.Path(sys.argv[9])),
phase4-coordinator/dist/deploy-pearl-vps.sh-774-)
phase4-coordinator/dist/deploy-pearl-vps.sh-775-# Artifact-bound release (SPEC-023 §3.7.8): the pair is part of the
phase4-coordinator/dist/deploy-pearl-vps.sh-776-# content-addressed envelope; both arguments are empty otherwise.
phase4-coordinator/dist/deploy-pearl-vps.sh-777-if sys.argv[10] or sys.argv[11]:
phase4-coordinator/dist/deploy-pearl-vps.sh-778-    assets += (
phase4-coordinator/dist/deploy-pearl-vps.sh-779-        ("autotune-artifacts.json", pathlib.Path(sys.argv[10])),
phase4-coordinator/dist/deploy-pearl-vps.sh-780-        ("autotune-artifacts.json.sig", pathlib.Path(sys.argv[11])),
phase4-coordinator/dist/deploy-pearl-vps.sh-781-    )
--
phase4-coordinator/dist/deploy-pearl-vps.sh-796-AUTOTUNE_RELEASE_DIR_NAME="$AUTOTUNE_RELEASE_ID-$(printf '%s' "$AUTOTUNE_RELEASE_CONTENT_SHA256" | cut -c1-16)"
phase4-coordinator/dist/deploy-pearl-vps.sh-797-# #1688 A2: the tag's release ledger rides the pinned deploy inputs so Pearl's
phase4-coordinator/dist/deploy-pearl-vps.sh-798-# compare-live can tell a live release this tag descends from (activate) from
phase4-coordinator/dist/deploy-pearl-vps.sh-799-# a catalog regression (refuse). The staged release dir never carries it.
phase4-coordinator/dist/deploy-pearl-vps.sh-800-AUTOTUNE_RELEASE_LEDGER="$PINNED_AUTOTUNE_DIR/release-ledger.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-801-[ -f "$AUTOTUNE_RELEASE_LEDGER" ] || { echo "missing required file: $AUTOTUNE_RELEASE_LEDGER" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-802-# The ledger records whole-file Tier-2 digests only; a Tier-2 freshness re-sign
phase4-coordinator/dist/deploy-pearl-vps.sh-803-# of a historical row is proven by its stripped content, looked up from the
phase4-coordinator/dist/deploy-pearl-vps.sh:804:# pinned commit's git history (catalog-release.py tier2-content-index) and
phase4-coordinator/dist/deploy-pearl-vps.sh-805-# shipped digest-pinned beside the ledger.
phase4-coordinator/dist/deploy-pearl-vps.sh-806-AUTOTUNE_TIER2_CONTENT_INDEX=""
phase4-coordinator/dist/deploy-pearl-vps.sh-807-if [ "$DRY_RUN_LOCAL" != "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-808-  AUTOTUNE_TIER2_CONTENT_INDEX="$PINNED_DEPLOY_INPUT_DIR/tier2-content-index.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:809:  python3 -I "$PINNED_SCRIPTS_DIR/catalog-release.py" tier2-content-index --repo "$REPO_ROOT" \
phase4-coordinator/dist/deploy-pearl-vps.sh-810-    --rev "$COORDINATOR_RELEASE_COMMIT" --ledger "$AUTOTUNE_RELEASE_LEDGER" > "$AUTOTUNE_TIER2_CONTENT_INDEX" || {
phase4-coordinator/dist/deploy-pearl-vps.sh-811-    echo "aborting deploy: could not build the Tier-2 content index from $COORDINATOR_RELEASE_COMMIT history" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-812-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-813-  }
phase4-coordinator/dist/deploy-pearl-vps.sh-814-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-815-# Operator override for a compare-live regression verdict. Printable ASCII,
phase4-coordinator/dist/deploy-pearl-vps.sh-816-# 1-200 chars, one line; it reaches Pearl only as base64.
phase4-coordinator/dist/deploy-pearl-vps.sh-817-CATALOG_REGRESSION_OVERRIDE_REASON="${CATALOG_REGRESSION_OVERRIDE_REASON:-}"
--
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
phase4-coordinator/dist/deploy-pearl-vps.sh:887:# paths in each template match the expected hostname, so an env-only
phase4-coordinator/dist/deploy-pearl-vps.sh-888-# DOMAIN override paired with a stale template can't issue a cert for
phase4-coordinator/dist/deploy-pearl-vps.sh-889-# one hostname and install a vhost for another.
phase4-coordinator/dist/deploy-pearl-vps.sh-890-_assert_vhost_template() {
phase4-coordinator/dist/deploy-pearl-vps.sh:891:  local f="$1" expected_host="$2"
phase4-coordinator/dist/deploy-pearl-vps.sh:892:  local host_esc="${expected_host//./\\.}"
phase4-coordinator/dist/deploy-pearl-vps.sh-893-  # R3 ARCH MED: anchor the active cert directives to the EXPECTED
phase4-coordinator/dist/deploy-pearl-vps.sh-894-  # hostname's letsencrypt path — not just any letsencrypt path. A
phase4-coordinator/dist/deploy-pearl-vps.sh:895:  # wrong active cert + commented expected cert would otherwise pass.
phase4-coordinator/dist/deploy-pearl-vps.sh-896-  if ! grep -Eq "^[[:space:]]*ssl_certificate[[:space:]]+/etc/letsencrypt/live/${host_esc}/fullchain\\.pem;" "$f"; then
phase4-coordinator/dist/deploy-pearl-vps.sh:897:    echo "aborting deploy: $f is missing an active 'ssl_certificate /etc/letsencrypt/live/$expected_host/fullchain.pem;' directive" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-898-    echo "  Edit the file to uncomment the cert path for this hostname; the deploy script no longer rewrites it." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-899-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-900-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-901-  if ! grep -Eq "^[[:space:]]*ssl_certificate_key[[:space:]]+/etc/letsencrypt/live/${host_esc}/privkey\\.pem;" "$f"; then
phase4-coordinator/dist/deploy-pearl-vps.sh:902:    echo "aborting deploy: $f is missing an active 'ssl_certificate_key /etc/letsencrypt/live/$expected_host/privkey.pem;' directive" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-903-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-904-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-905-  if ! grep -Eq "^[[:space:]]*server_name[[:space:]]+${host_esc}[[:space:]]*;" "$f"; then
phase4-coordinator/dist/deploy-pearl-vps.sh:906:    echo "aborting deploy: $f does not contain server_name $expected_host;" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-907-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-908-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-909-}
phase4-coordinator/dist/deploy-pearl-vps.sh-910-_assert_vhost_template "$NGINX_SITE"       "$DOMAIN"
phase4-coordinator/dist/deploy-pearl-vps.sh-911-_assert_vhost_template "$NGINX_STATS_SITE" "${STATS_DOMAIN:-stats.malibu.tech}"
phase4-coordinator/dist/deploy-pearl-vps.sh-912-
phase4-coordinator/dist/deploy-pearl-vps.sh-913-SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p 22 $VPS_USER@$VPS_HOST"
phase4-coordinator/dist/deploy-pearl-vps.sh-914-SCP="scp -i $SSH_KEY -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -P 22"
--
phase4-coordinator/dist/deploy-pearl-vps.sh-1071-    echo "  Either set stats.enabled: true in coordinator.yaml, or drop STATS_REQUIRED=1." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1072-    exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1073-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1074-}
phase4-coordinator/dist/deploy-pearl-vps.sh-1075-
phase4-coordinator/dist/deploy-pearl-vps.sh-1076-# Issue #582 (MEDIUM #6) — stats-inventory-sync restore-on-failure state.
phase4-coordinator/dist/deploy-pearl-vps.sh-1077-# The old 2-column sidecar is quiesced (stop+disable) BEFORE migration 019
phase4-coordinator/dist/deploy-pearl-vps.sh-1078-# widens hardware_verification_trust's PRIMARY KEY, so an abort that happens
phase4-coordinator/dist/deploy-pearl-vps.sh:1079:# BEFORE the schema/binary actually become incompatible (before 019 is applied
phase4-coordinator/dist/deploy-pearl-vps.sh-1080-# and before the new 3-column sidecar binary is installed) must RESTORE the
phase4-coordinator/dist/deploy-pearl-vps.sh-1081-# sidecar to its pre-quiesce state rather than strand it stopped. These are
phase4-coordinator/dist/deploy-pearl-vps.sh-1082-# ARMED before the quiesce (search "MEDIUM #6" at the quiesce step) and consumed
phase4-coordinator/dist/deploy-pearl-vps.sh-1083-# by the EXIT trap through _sidecar_restore_on_abort.
phase4-coordinator/dist/deploy-pearl-vps.sh-1084-#   SIDECAR_QUIESCE_ATTEMPTED — set to 1 immediately before the quiesce SSH.
phase4-coordinator/dist/deploy-pearl-vps.sh-1085-#   Parity marker (/opt/macprovider/.coordinator-deploy-sidecar-parity-required,
phase4-coordinator/dist/deploy-pearl-vps.sh-1086-#   touched just before the migration apply) records that the schema may now be
phase4-coordinator/dist/deploy-pearl-vps.sh-1087-#   3-column; once set — or once the release transaction is ARMED at step 4, whose
--
phase4-coordinator/dist/deploy-pearl-vps.sh-1353-# guard was effectively disabled.
phase4-coordinator/dist/deploy-pearl-vps.sh-1354-# M1-6 follow-up: production deploy reads the gateway config installed on
phase4-coordinator/dist/deploy-pearl-vps.sh-1355-# Pearl, not a local sample or developer config. Local validation is available
phase4-coordinator/dist/deploy-pearl-vps.sh-1356-# only through --dry-run-local and exits before any SSH mutation.
phase4-coordinator/dist/deploy-pearl-vps.sh-1357-CHECK_SCRIPT="$DIST_DIR/check-deploy-config.sh"
phase4-coordinator/dist/deploy-pearl-vps.sh-1358-C2C_PROOF_SCRIPT="$DIST_DIR/lib/c2c_runtime_proof.py"
phase4-coordinator/dist/deploy-pearl-vps.sh-1359-MERGE_OVERLAY_SCRIPT="$DIST_DIR/merge-yaml-overlay.py"
phase4-coordinator/dist/deploy-pearl-vps.sh-1360-C2_TIMER_MIGRATION_SCRIPT="$DIST_DIR/c2-timer-config-migration.py"
phase4-coordinator/dist/deploy-pearl-vps.sh:1361:RATE_CARD_CONFIG_MIGRATION_SCRIPT="$DIST_DIR/autotune-rate-card-config-migration.py"
phase4-coordinator/dist/deploy-pearl-vps.sh-1362-if [ ! -x "$CHECK_SCRIPT" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-1363-  echo "aborting deploy: check-deploy-config.sh missing or not executable: $CHECK_SCRIPT" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1364-  exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1365-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1366-if [ ! -r "$C2C_PROOF_SCRIPT" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-1367-  echo "aborting deploy: runtime credential proof helper missing or unreadable: $C2C_PROOF_SCRIPT" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1368-  exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1369-fi
--
phase4-coordinator/dist/deploy-pearl-vps.sh-1371-  echo "aborting deploy: YAML overlay merge helper missing or not executable: $MERGE_OVERLAY_SCRIPT" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1372-  exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1373-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1374-if [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ] && [ ! -x "$C2_TIMER_MIGRATION_SCRIPT" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-1375-  echo "aborting deploy: C2 timer migration helper missing or not executable: $C2_TIMER_MIGRATION_SCRIPT" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1376-  exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1377-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1378-if [ ! -x "$RATE_CARD_CONFIG_MIGRATION_SCRIPT" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:1379:  echo "aborting deploy: rate-card config migration helper missing or not executable: $RATE_CARD_CONFIG_MIGRATION_SCRIPT" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1380-  exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1381-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1382-if [ "$DRY_RUN_LOCAL" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-1383-  echo "  --dry-run-local set — validating local GATEWAY_CONFIG and exiting before deploy" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1384-  GATEWAY_CONFIG_DEFAULT="$DIST_DIR/../../phase5-gateway/dist/gateway.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-1385-  GATEWAY_CONFIG="${GATEWAY_CONFIG:-$GATEWAY_CONFIG_DEFAULT}"
phase4-coordinator/dist/deploy-pearl-vps.sh-1386-  if [ ! -f "$GATEWAY_CONFIG" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-1387-    echo "aborting deploy dry-run: local gateway config not found for C2 cross-check ($GATEWAY_CONFIG)." >&2
--
phase4-coordinator/dist/deploy-pearl-vps.sh-1451-      echo "aborting deploy: could not sanitize C2 timer migrated coordinator config for local validation" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1452-      exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1453-    }
phase4-coordinator/dist/deploy-pearl-vps.sh-1454-    DEPLOY_CONFIG="$C2_TIMER_MIGRATED_CONFIG_VALIDATION_TMP"
phase4-coordinator/dist/deploy-pearl-vps.sh-1455-    echo "  C2_TIMER_CONFIG_MIGRATION=1 — validating reviewed field-scoped timer raise"
phase4-coordinator/dist/deploy-pearl-vps.sh-1456-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1457-  RATE_CARD_CONFIG_MIGRATION_ACTIVE=0
phase4-coordinator/dist/deploy-pearl-vps.sh-1458-  RATE_CARD_MIGRATION_INPUT="${C2_TIMER_MIGRATED_CONFIG_TMP:-${LIVE_COORDINATOR_CONFIG_RAW_TMP:-$DEPLOY_CONFIG}}"
phase4-coordinator/dist/deploy-pearl-vps.sh:1459:  RATE_CARD_MIGRATED_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-coordinator-rate-card-config.XXXXXXXX)" || {
phase4-coordinator/dist/deploy-pearl-vps.sh:1460:    echo "aborting deploy: mktemp failed for rate-card migrated coordinator config" >&2; exit 5;
phase4-coordinator/dist/deploy-pearl-vps.sh-1461-  }
phase4-coordinator/dist/deploy-pearl-vps.sh:1462:  RATE_CARD_MIGRATED_CONFIG_VALIDATION_TMP="$(umask 077 && mktemp -t macprovider-coordinator-rate-card-config-validation.XXXXXXXX)" || {
phase4-coordinator/dist/deploy-pearl-vps.sh:1463:    echo "aborting deploy: mktemp failed for sanitized rate-card migrated coordinator config" >&2; exit 5;
phase4-coordinator/dist/deploy-pearl-vps.sh-1464-  }
phase4-coordinator/dist/deploy-pearl-vps.sh-1465-  python3 "$RATE_CARD_CONFIG_MIGRATION_SCRIPT" "$RATE_CARD_MIGRATION_INPUT" "$CONFIG" > "$RATE_CARD_MIGRATED_CONFIG_TMP" || {
phase4-coordinator/dist/deploy-pearl-vps.sh:1466:    echo "aborting deploy: could not render reviewed rate-card feed config migration" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1467-    exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1468-  }
phase4-coordinator/dist/deploy-pearl-vps.sh-1469-  reject_redacted_install_candidate "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-1470-  if ! cmp -s "$RATE_CARD_MIGRATION_INPUT" "$RATE_CARD_MIGRATED_CONFIG_TMP"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-1471-    RATE_CARD_CONFIG_MIGRATION_ACTIVE=1
phase4-coordinator/dist/deploy-pearl-vps.sh-1472-    sanitize_live_config_for_local_validation < "$RATE_CARD_MIGRATED_CONFIG_TMP" > "$RATE_CARD_MIGRATED_CONFIG_VALIDATION_TMP" || {
phase4-coordinator/dist/deploy-pearl-vps.sh:1473:      echo "aborting deploy: could not sanitize rate-card migrated coordinator config for local validation" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1474-      exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1475-    }
phase4-coordinator/dist/deploy-pearl-vps.sh-1476-    DEPLOY_CONFIG="$RATE_CARD_MIGRATED_CONFIG_VALIDATION_TMP"
phase4-coordinator/dist/deploy-pearl-vps.sh:1477:    echo "  B10 rate-card migration — adding release-bound autotune.rate_card_* paths"
phase4-coordinator/dist/deploy-pearl-vps.sh-1478-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1479-  COORDINATOR_REMOTE_OVERLAY="/etc/macprovider/coordinator.pearl-overlays.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-1480-  C2_TIMER_MIGRATION_OVERLAY_ACTIVE=0
phase4-coordinator/dist/deploy-pearl-vps.sh-1481-  RATE_CARD_MIGRATION_OVERLAY_ACTIVE=0
phase4-coordinator/dist/deploy-pearl-vps.sh-1482-  COORDINATOR_EFFECTIVE_OVERLAY_TMP=""
phase4-coordinator/dist/deploy-pearl-vps.sh-1483-  if $SSH "test -f '$COORDINATOR_REMOTE_OVERLAY'"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-1484-    COORDINATOR_OVERLAY_CONFIG_RAW_TMP="$(umask 077 && mktemp -t macprovider-coordinator-live-overlay-raw.XXXXXXXX)" || {
phase4-coordinator/dist/deploy-pearl-vps.sh-1485-      echo "aborting deploy: mktemp failed for raw installed coordinator overlay copy" >&2; exit 5;
--
phase4-coordinator/dist/deploy-pearl-vps.sh-1516-          echo "aborting deploy: could not sanitize C2 timer migrated coordinator overlay for local validation" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1517-          exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1518-        }
phase4-coordinator/dist/deploy-pearl-vps.sh-1519-        COORDINATOR_EFFECTIVE_OVERLAY_TMP="$C2_TIMER_MIGRATED_OVERLAY_VALIDATION_TMP"
phase4-coordinator/dist/deploy-pearl-vps.sh-1520-        echo "  C2_TIMER_CONFIG_MIGRATION=1 — Pearl overlay carries timer fields and will be migrated field-scope"
phase4-coordinator/dist/deploy-pearl-vps.sh-1521-      fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1522-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1523-    RATE_CARD_OVERLAY_MIGRATION_INPUT="${C2_TIMER_MIGRATED_OVERLAY_TMP:-$COORDINATOR_OVERLAY_CONFIG_RAW_TMP}"
phase4-coordinator/dist/deploy-pearl-vps.sh:1524:    RATE_CARD_MIGRATED_OVERLAY_TMP="$(umask 077 && mktemp -t macprovider-coordinator-rate-card-overlay.XXXXXXXX)" || {
phase4-coordinator/dist/deploy-pearl-vps.sh:1525:      echo "aborting deploy: mktemp failed for rate-card migrated coordinator overlay" >&2; exit 5;
phase4-coordinator/dist/deploy-pearl-vps.sh-1526-    }
phase4-coordinator/dist/deploy-pearl-vps.sh:1527:    RATE_CARD_MIGRATED_OVERLAY_VALIDATION_TMP="$(umask 077 && mktemp -t macprovider-coordinator-rate-card-overlay-validation.XXXXXXXX)" || {
phase4-coordinator/dist/deploy-pearl-vps.sh:1528:      echo "aborting deploy: mktemp failed for sanitized rate-card migrated coordinator overlay" >&2; exit 5;
phase4-coordinator/dist/deploy-pearl-vps.sh-1529-    }
phase4-coordinator/dist/deploy-pearl-vps.sh-1530-    python3 "$RATE_CARD_CONFIG_MIGRATION_SCRIPT" --only-static-feed-overlays "$RATE_CARD_OVERLAY_MIGRATION_INPUT" "$CONFIG" > "$RATE_CARD_MIGRATED_OVERLAY_TMP" || {
phase4-coordinator/dist/deploy-pearl-vps.sh:1531:      echo "aborting deploy: could not render reviewed rate-card overlay migration" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1532-      exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1533-    }
phase4-coordinator/dist/deploy-pearl-vps.sh-1534-    reject_redacted_install_candidate "$RATE_CARD_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-1535-    if ! cmp -s "$RATE_CARD_OVERLAY_MIGRATION_INPUT" "$RATE_CARD_MIGRATED_OVERLAY_TMP"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-1536-      RATE_CARD_MIGRATION_OVERLAY_ACTIVE=1
phase4-coordinator/dist/deploy-pearl-vps.sh-1537-      sanitize_live_config_for_local_validation < "$RATE_CARD_MIGRATED_OVERLAY_TMP" > "$RATE_CARD_MIGRATED_OVERLAY_VALIDATION_TMP" || {
phase4-coordinator/dist/deploy-pearl-vps.sh:1538:        echo "aborting deploy: could not sanitize rate-card migrated coordinator overlay for local validation" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1539-        exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1540-      }
phase4-coordinator/dist/deploy-pearl-vps.sh-1541-      COORDINATOR_EFFECTIVE_OVERLAY_TMP="$RATE_CARD_MIGRATED_OVERLAY_VALIDATION_TMP"
phase4-coordinator/dist/deploy-pearl-vps.sh:1542:      echo "  B10 rate-card migration — Pearl overlay carries static feed fields and will receive rate-card paths"
phase4-coordinator/dist/deploy-pearl-vps.sh-1543-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-1544-    DEPLOY_EFFECTIVE_CONFIG_TMP="$(umask 077 && mktemp -t macprovider-coordinator-effective-config.XXXXXXXX)" || {
phase4-coordinator/dist/deploy-pearl-vps.sh-1545-      echo "aborting deploy: mktemp failed for effective coordinator config" >&2; exit 5;
phase4-coordinator/dist/deploy-pearl-vps.sh-1546-    }
phase4-coordinator/dist/deploy-pearl-vps.sh-1547-    python3 "$MERGE_OVERLAY_SCRIPT" "$DEPLOY_CONFIG" "$COORDINATOR_EFFECTIVE_OVERLAY_TMP" > "$DEPLOY_EFFECTIVE_CONFIG_TMP" || {
phase4-coordinator/dist/deploy-pearl-vps.sh-1548-      echo "aborting deploy: could not merge coordinator base config with Pearl overlay" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1549-      exit 5
phase4-coordinator/dist/deploy-pearl-vps.sh-1550-    }
--
phase4-coordinator/dist/deploy-pearl-vps.sh-1718-dig +short "$DOMAIN" | grep -q "$VPS_HOST" || { echo "DNS for $DOMAIN does not resolve to $VPS_HOST yet" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-1719-
phase4-coordinator/dist/deploy-pearl-vps.sh-1720-# Install the durable pre-start recovery guard before any release file can be
phase4-coordinator/dist/deploy-pearl-vps.sh-1721-# replaced. It rolls back an armed transaction on boot/restart whenever the
phase4-coordinator/dist/deploy-pearl-vps.sh-1722-# controller-held deploy lock is no longer present.
phase4-coordinator/dist/deploy-pearl-vps.sh-1723-RECOVERY_DEPLOY_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-recovery.XXXXXXXX')
phase4-coordinator/dist/deploy-pearl-vps.sh-1724-case "$RECOVERY_DEPLOY_TMP" in
phase4-coordinator/dist/deploy-pearl-vps.sh-1725-  /tmp/macprovider-recovery.*) ;;
phase4-coordinator/dist/deploy-pearl-vps.sh:1726:  *) echo "aborting deploy: unexpected recovery staging path: $RECOVERY_DEPLOY_TMP" >&2; exit 1 ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-1727-esac
phase4-coordinator/dist/deploy-pearl-vps.sh-1728-$SCP "$DEPLOY_RECOVER" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/coordinator-deploy-recover"
phase4-coordinator/dist/deploy-pearl-vps.sh-1729-$SCP "$DEPLOY_GUARD" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/10-deploy-transaction-guard.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-1730-$SCP "$DEPLOY_RECOVERY_SERVICE" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/macprovider-coordinator-deploy-recovery.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-1731-$SCP "$DEPLOY_WATCHDOG_SERVICE" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/macprovider-coordinator-deploy-watchdog.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-1732-RECOVERY_INPUT_MANIFEST_TMP="$(umask 077 && mktemp -t macprovider-recovery-inputs.XXXXXXXX)" || {
phase4-coordinator/dist/deploy-pearl-vps.sh-1733-  echo "aborting deploy: mktemp failed for recovery input manifest" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-1734-  exit 2
--
phase4-coordinator/dist/deploy-pearl-vps.sh-2107-  mv -f "$_prior_next" "$_prior"
phase4-coordinator/dist/deploy-pearl-vps.sh-2108-  rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
phase4-coordinator/dist/deploy-pearl-vps.sh-2109-  for unit in stats-inventory-sync.timer stats-inventory-sync.service; do
phase4-coordinator/dist/deploy-pearl-vps.sh-2110-    load_state=$(systemctl show -p LoadState --value "$unit")
phase4-coordinator/dist/deploy-pearl-vps.sh-2111-    [ "$load_state" = not-found ] && continue
phase4-coordinator/dist/deploy-pearl-vps.sh-2112-    if [ "$unit" = stats-inventory-sync.timer ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-2113-      systemctl disable "$unit" >/dev/null
phase4-coordinator/dist/deploy-pearl-vps.sh-2114-    else
phase4-coordinator/dist/deploy-pearl-vps.sh:2115:      # The oneshot service has no [Install] section and is expected to be
phase4-coordinator/dist/deploy-pearl-vps.sh-2116-      # static; the timer is the only persistent activation path.
phase4-coordinator/dist/deploy-pearl-vps.sh-2117-      systemctl disable "$unit" >/dev/null 2>&1 || true
phase4-coordinator/dist/deploy-pearl-vps.sh-2118-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-2119-    systemctl stop "$unit"
phase4-coordinator/dist/deploy-pearl-vps.sh-2120-    active_state=$(systemctl show -p ActiveState --value "$unit")
phase4-coordinator/dist/deploy-pearl-vps.sh-2121-    case "$active_state" in
phase4-coordinator/dist/deploy-pearl-vps.sh-2122-      inactive|failed) ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-2123-      *) echo "stats-inventory-sync unit did not quiesce before migration: $unit state=$active_state" >&2; exit 1 ;;
--
phase4-coordinator/dist/deploy-pearl-vps.sh-2418-    AND NOT has_function_privilege(current_user, 'request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
phase4-coordinator/dist/deploy-pearl-vps.sh-2419-    AND NOT has_function_privilege(current_user, 'approve_provider_auth_policy_exemption(uuid,text)'::regprocedure, 'EXECUTE')
phase4-coordinator/dist/deploy-pearl-vps.sh-2420-  ) THEN
phase4-coordinator/dist/deploy-pearl-vps.sh-2421-    RAISE EXCEPTION 'auth policy cutover DSN does not map to the least-privilege cutover role';
phase4-coordinator/dist/deploy-pearl-vps.sh-2422-  END IF;
phase4-coordinator/dist/deploy-pearl-vps.sh-2423-END
phase4-coordinator/dist/deploy-pearl-vps.sh-2424-\$\$;
phase4-coordinator/dist/deploy-pearl-vps.sh-2425-SQL
phase4-coordinator/dist/deploy-pearl-vps.sh:2426:    echo "  ok: auth-policy split DSN roles have expected EXECUTE privileges"
phase4-coordinator/dist/deploy-pearl-vps.sh-2427-    psql_preflight_service hardware_trust_request_preflight "$ONBOARDING_HARDWARE_TRUST_REQUEST_DSN" <<SQL >/dev/null
phase4-coordinator/dist/deploy-pearl-vps.sh-2428-DO \$\$
phase4-coordinator/dist/deploy-pearl-vps.sh-2429-BEGIN
phase4-coordinator/dist/deploy-pearl-vps.sh-2430-  IF NOT (
phase4-coordinator/dist/deploy-pearl-vps.sh-2431-    current_user = 'hardware_trust_requester'
phase4-coordinator/dist/deploy-pearl-vps.sh-2432-    AND session_user = current_user
phase4-coordinator/dist/deploy-pearl-vps.sh-2433-    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolinherit AND NOT rolreplication AND NOT rolbypassrls)
phase4-coordinator/dist/deploy-pearl-vps.sh-2434-    AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles granted ON granted.oid = m.roleid JOIN pg_roles member ON member.oid = m.member WHERE member.rolname = current_user OR granted.rolname = current_user)
--
phase4-coordinator/dist/deploy-pearl-vps.sh-2465-    AND has_function_privilege(current_user, 'revoke_hardware_trust_approval(uuid,text,text,text,text)'::regprocedure, 'EXECUTE')
phase4-coordinator/dist/deploy-pearl-vps.sh-2466-    AND NOT has_function_privilege(current_user, 'request_hardware_trust_approval(uuid,bigint,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
phase4-coordinator/dist/deploy-pearl-vps.sh-2467-  ) THEN
phase4-coordinator/dist/deploy-pearl-vps.sh-2468-    RAISE EXCEPTION 'hardware trust approve DSN does not map to the least-privilege approver role';
phase4-coordinator/dist/deploy-pearl-vps.sh-2469-  END IF;
phase4-coordinator/dist/deploy-pearl-vps.sh-2470-END
phase4-coordinator/dist/deploy-pearl-vps.sh-2471-\$\$;
phase4-coordinator/dist/deploy-pearl-vps.sh-2472-SQL
phase4-coordinator/dist/deploy-pearl-vps.sh:2473:    echo "  ok: hardware-trust split DSN roles have expected EXECUTE privileges"
phase4-coordinator/dist/deploy-pearl-vps.sh-2474-    verifier_env=/etc/macprovider-stats/stats-hardware-verifier.env
phase4-coordinator/dist/deploy-pearl-vps.sh-2475-    # FIX 8 (issue #582): reaching here means hardware-trust approval is enabled
phase4-coordinator/dist/deploy-pearl-vps.sh-2476-    # (ONBOARDING_HARDWARE_TRUST_REQUEST_DSN/APPROVE_DSN are required above), so
phase4-coordinator/dist/deploy-pearl-vps.sh-2477-    # the stats-hardware-verifier that PROMOTES approved waiting_trust jobs must
phase4-coordinator/dist/deploy-pearl-vps.sh-2478-    # be provisioned too. Without its env the verifier timer is left disabled
phase4-coordinator/dist/deploy-pearl-vps.sh-2479-    # (see step 9's `[ -f "$verifier_env" ]` enable gate), so an operator
phase4-coordinator/dist/deploy-pearl-vps.sh-2480-    # approval commits a trust root that NO timer ever promotes to verified.
phase4-coordinator/dist/deploy-pearl-vps.sh-2481-    # Fail closed rather than shipping a coordinator that accepts approvals it
--
phase4-coordinator/dist/deploy-pearl-vps.sh-2522-    AND session_user = current_user
phase4-coordinator/dist/deploy-pearl-vps.sh-2523-    AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls)
phase4-coordinator/dist/deploy-pearl-vps.sh-2524-    AND has_schema_privilege(current_user, 'public', 'USAGE')
phase4-coordinator/dist/deploy-pearl-vps.sh-2525-    AND has_table_privilege(current_user, 'hardware_verification_jobs', 'SELECT')
phase4-coordinator/dist/deploy-pearl-vps.sh-2526-    AND has_table_privilege(current_user, 'hardware_verification_trust', 'SELECT')
phase4-coordinator/dist/deploy-pearl-vps.sh-2527-    AND has_table_privilege(current_user, 'chip_hardware_profiles', 'SELECT')
phase4-coordinator/dist/deploy-pearl-vps.sh-2528-    AND has_table_privilege(current_user, 'provider_hardware_profiles', 'SELECT')
phase4-coordinator/dist/deploy-pearl-vps.sh-2529-    -- FIX 5 (round-8, issue #582): assert the FULL column write surface the verifier
phase4-coordinator/dist/deploy-pearl-vps.sh:2530:    -- actually writes across promoteJob/waitTrustJob/rejectJob
phase4-coordinator/dist/deploy-pearl-vps.sh-2531-    -- (internal/stats/hardwareverify/verify.go), not just status+verified. A partial
phase4-coordinator/dist/deploy-pearl-vps.sh-2532-    -- check would pass a DSN missing (e.g.) processed_at or last_reported_at that then
phase4-coordinator/dist/deploy-pearl-vps.sh-2533-    -- fails the FIRST time the verifier tries to finalize a job, after operators have
phase4-coordinator/dist/deploy-pearl-vps.sh-2534-    -- already committed approvals. Cross-checked against migration 008's grants.
phase4-coordinator/dist/deploy-pearl-vps.sh-2535-    -- hardware_verification_jobs: UPDATE(status, processed_at, decision_reason).
phase4-coordinator/dist/deploy-pearl-vps.sh-2536-    AND has_column_privilege(current_user, 'hardware_verification_jobs', 'status', 'UPDATE')
phase4-coordinator/dist/deploy-pearl-vps.sh-2537-    AND has_column_privilege(current_user, 'hardware_verification_jobs', 'processed_at', 'UPDATE')
phase4-coordinator/dist/deploy-pearl-vps.sh-2538-    AND has_column_privilege(current_user, 'hardware_verification_jobs', 'decision_reason', 'UPDATE')
--
phase4-coordinator/dist/deploy-pearl-vps.sh-2629-    # The REAL trigger for trust reconciliation — and therefore for this gate — is
phase4-coordinator/dist/deploy-pearl-vps.sh-2630-    # whether the inventory YAML DECLARES a trusted_hardware section, NOT whether a
phase4-coordinator/dist/deploy-pearl-vps.sh-2631-    # DSN happens to be set. Mirror the sidecar's UnmarshalYAML "omitted vs explicit
phase4-coordinator/dist/deploy-pearl-vps.sh-2632-    # {}" contract (cmd/stats-inventory-sync/main.go): an OMITTED top-level
phase4-coordinator/dist/deploy-pearl-vps.sh-2633-    # `trusted_hardware` key leaves every trust root untouched (no-op); a PRESENT key
phase4-coordinator/dist/deploy-pearl-vps.sh-2634-    # — INCLUDING an explicit `trusted_hardware: {}` revoke-all, or a bare null — makes
phase4-coordinator/dist/deploy-pearl-vps.sh-2635-    # the sidecar reconcile trust and REQUIRES both STATS_TRUST_INVENTORY_DSN and the
phase4-coordinator/dist/deploy-pearl-vps.sh-2636-    # 019 schema. Key the gate's applicability on that presence: if trusted_hardware is
phase4-coordinator/dist/deploy-pearl-vps.sh:2637:    # declared, the deploy must be able to actually perform the reconciliation, else
phase4-coordinator/dist/deploy-pearl-vps.sh-2638-    # step 9 re-enables a sidecar whose reconciliation fails permanently (warning-only)
phase4-coordinator/dist/deploy-pearl-vps.sh-2639-    # and the deploy completes silently broken.
phase4-coordinator/dist/deploy-pearl-vps.sh-2640-    #
phase4-coordinator/dist/deploy-pearl-vps.sh-2641-    # Detect presence with a real YAML parser (PyYAML), never a sed/grep-for-structure
phase4-coordinator/dist/deploy-pearl-vps.sh-2642-    # hand-parse. PyYAML is not guaranteed on the VPS and the file could be malformed,
phase4-coordinator/dist/deploy-pearl-vps.sh-2643-    # so FAIL CLOSED: only a cleanly-parsed mapping that PROVABLY lacks the key is
phase4-coordinator/dist/deploy-pearl-vps.sh-2644-    # treated as omitted (no-op). Missing parser, unreadable/unparseable YAML, a
phase4-coordinator/dist/deploy-pearl-vps.sh:2645:    # non-mapping document, or any unexpected error all mean we cannot prove omission —
phase4-coordinator/dist/deploy-pearl-vps.sh-2646-    # treat trust reconciliation as declared (require DSN+019) rather than risk the
phase4-coordinator/dist/deploy-pearl-vps.sh-2647-    # silent break.
phase4-coordinator/dist/deploy-pearl-vps.sh-2648-    #   exit 0 => trusted_hardware PRESENT (or presence could not be disproven; fail-closed)
phase4-coordinator/dist/deploy-pearl-vps.sh-2649-    #   exit 1 => trusted_hardware PROVABLY OMITTED (cleanly-parsed mapping without the key)
phase4-coordinator/dist/deploy-pearl-vps.sh-2650-    trusted_hardware_present() {
phase4-coordinator/dist/deploy-pearl-vps.sh-2651-      TH_YAML_FILE="$1" python3 <<'PY'
phase4-coordinator/dist/deploy-pearl-vps.sh-2652-import os
phase4-coordinator/dist/deploy-pearl-vps.sh-2653-import sys
--
phase4-coordinator/dist/deploy-pearl-vps.sh-2679-        sys.exit(1)
phase4-coordinator/dist/deploy-pearl-vps.sh-2680-    sys.stderr.write(
phase4-coordinator/dist/deploy-pearl-vps.sh-2681-        "%s is not a YAML mapping; cannot prove trusted_hardware is omitted "
phase4-coordinator/dist/deploy-pearl-vps.sh-2682-        "— assuming present (fail-closed)\n" % path
phase4-coordinator/dist/deploy-pearl-vps.sh-2683-    )
phase4-coordinator/dist/deploy-pearl-vps.sh-2684-    sys.exit(0)
phase4-coordinator/dist/deploy-pearl-vps.sh-2685-except SystemExit:
phase4-coordinator/dist/deploy-pearl-vps.sh-2686-    raise
phase4-coordinator/dist/deploy-pearl-vps.sh:2687:except Exception as exc:  # never let an unexpected error read as "omitted"
phase4-coordinator/dist/deploy-pearl-vps.sh-2688-    sys.stderr.write(
phase4-coordinator/dist/deploy-pearl-vps.sh:2689:        "unexpected error determining trusted_hardware presence in %s: %s "
phase4-coordinator/dist/deploy-pearl-vps.sh-2690-        "— assuming present (fail-closed)\n" % (path, exc)
phase4-coordinator/dist/deploy-pearl-vps.sh-2691-    )
phase4-coordinator/dist/deploy-pearl-vps.sh-2692-    sys.exit(0)
phase4-coordinator/dist/deploy-pearl-vps.sh-2693-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-2694-    }
phase4-coordinator/dist/deploy-pearl-vps.sh-2695-    trusted_hardware_present_rc=0
phase4-coordinator/dist/deploy-pearl-vps.sh-2696-    trusted_hardware_present "$inventory_yaml" || trusted_hardware_present_rc=$?
phase4-coordinator/dist/deploy-pearl-vps.sh-2697-    if [ "$trusted_hardware_present_rc" -eq 1 ]; then
--
phase4-coordinator/dist/deploy-pearl-vps.sh-2774-    # still never be mistaken for a clean-absent DSN.
phase4-coordinator/dist/deploy-pearl-vps.sh-2775-    #   exit 0 => STATS_TRUST_INVENTORY_DSN present (value on stdout)
phase4-coordinator/dist/deploy-pearl-vps.sh-2776-    #   exit 1 => cleanly absent (missing DSN while trusted_hardware is declared => abort)
phase4-coordinator/dist/deploy-pearl-vps.sh-2777-    #   exit 2 => the env file could not be parsed to decide (malformed line, etc.)
phase4-coordinator/dist/deploy-pearl-vps.sh-2778-    trust_dsn=""
phase4-coordinator/dist/deploy-pearl-vps.sh-2779-    trust_dsn_rc=0
phase4-coordinator/dist/deploy-pearl-vps.sh-2780-    trust_dsn="$(read_env_value "$inventory_env" STATS_TRUST_INVENTORY_DSN)" || trust_dsn_rc=$?
phase4-coordinator/dist/deploy-pearl-vps.sh-2781-    if [ "$trust_dsn_rc" -ne 0 ] && [ "$trust_dsn_rc" -ne 1 ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:2782:      # Parse/malformed error (exit 2) — or any other unexpected nonzero. FAIL CLOSED:
phase4-coordinator/dist/deploy-pearl-vps.sh-2783-      # a malformed unrelated line (that systemd itself tolerates) could hide a valid
phase4-coordinator/dist/deploy-pearl-vps.sh-2784-      # STATS_TRUST_INVENTORY_DSN, so we cannot safely conclude the sidecar has no 019
phase4-coordinator/dist/deploy-pearl-vps.sh-2785-      # dependency. Refusing to deploy is the only safe option.
phase4-coordinator/dist/deploy-pearl-vps.sh-2786-      echo "aborting deploy: $inventory_env could not be parsed to determine STATS_TRUST_INVENTORY_DSN (read_env_value rc=$trust_dsn_rc);" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-2787-      echo "  the stats-inventory-sync sidecar / migration-019 schema coupling cannot be safely verified — fix the env file before deploying." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-2788-      exit 12
phase4-coordinator/dist/deploy-pearl-vps.sh-2789-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-2790-    if [ "$trust_dsn_rc" -eq 1 ] || [ -z "$trust_dsn" ]; then
--
phase4-coordinator/dist/deploy-pearl-vps.sh-2890-  [ -f "$TCP_BBR_MODULES_LOAD" ] || { echo "missing required file: $TCP_BBR_MODULES_LOAD" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-2891-  TCP_SYSCTL_UNEXPECTED=$($SSH 'for path in /etc/sysctl.d/*macprovider*; do
phase4-coordinator/dist/deploy-pearl-vps.sh-2892-    [ -e "$path" ] || continue
phase4-coordinator/dist/deploy-pearl-vps.sh-2893-    [ "$(basename "$path")" = "99-macprovider-tcp.conf" ] && continue
phase4-coordinator/dist/deploy-pearl-vps.sh-2894-    printf "%s\n" "$path"
phase4-coordinator/dist/deploy-pearl-vps.sh-2895-  done
phase4-coordinator/dist/deploy-pearl-vps.sh-2896-  exit 0')
phase4-coordinator/dist/deploy-pearl-vps.sh-2897-  if [ -n "$TCP_SYSCTL_UNEXPECTED" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:2898:    log "  WARN: found unexpected macprovider sysctl artifacts on Pearl:"
phase4-coordinator/dist/deploy-pearl-vps.sh:2899:    while IFS= read -r unexpected_sysctl; do
phase4-coordinator/dist/deploy-pearl-vps.sh:2900:      [ -n "$unexpected_sysctl" ] || continue
phase4-coordinator/dist/deploy-pearl-vps.sh:2901:      log "    $unexpected_sysctl"
phase4-coordinator/dist/deploy-pearl-vps.sh-2902-    done <<EOF
phase4-coordinator/dist/deploy-pearl-vps.sh-2903-$TCP_SYSCTL_UNEXPECTED
phase4-coordinator/dist/deploy-pearl-vps.sh-2904-EOF
phase4-coordinator/dist/deploy-pearl-vps.sh-2905-    log "  These are not managed by this deploy; consider removing after verifying they are stale."
phase4-coordinator/dist/deploy-pearl-vps.sh-2906-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-2907-  TCP_SYSCTL_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-tcp.XXXXXXXX') || {
phase4-coordinator/dist/deploy-pearl-vps.sh-2908-    echo "failed to create remote TCP sysctl staging directory" >&2; exit 1;
phase4-coordinator/dist/deploy-pearl-vps.sh-2909-  }
phase4-coordinator/dist/deploy-pearl-vps.sh-2910-  case "$TCP_SYSCTL_TMP" in
phase4-coordinator/dist/deploy-pearl-vps.sh-2911-    /tmp/macprovider-tcp.*) ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-2912-    *)
phase4-coordinator/dist/deploy-pearl-vps.sh:2913:      echo "aborting deploy: TCP sysctl mktemp produced unexpected path: '$TCP_SYSCTL_TMP'" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-2914-      exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-2915-      ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-2916-  esac
phase4-coordinator/dist/deploy-pearl-vps.sh-2917-  if ! $SCP "$TCP_SYSCTL" "$VPS_USER@$VPS_HOST:$TCP_SYSCTL_TMP/macprovider-tcp.conf"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-2918-    $SSH "rm -rf $TCP_SYSCTL_TMP" 2>/dev/null || true
phase4-coordinator/dist/deploy-pearl-vps.sh-2919-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-2920-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-2921-  if ! $SCP "$TCP_BBR_MODULES_LOAD" "$VPS_USER@$VPS_HOST:$TCP_SYSCTL_TMP/tcp_bbr.conf"; then
--
phase4-coordinator/dist/deploy-pearl-vps.sh-2962-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-2963-    if ! modprobe tcp_bbr >/dev/null 2>&1; then
phase4-coordinator/dist/deploy-pearl-vps.sh-2964-      echo "ABORT: tcp_bbr kernel module exists but failed to load on $(hostname) (kernel $kernel)." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-2965-      exit 10
phase4-coordinator/dist/deploy-pearl-vps.sh-2966-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-2967-
phase4-coordinator/dist/deploy-pearl-vps.sh-2968-    expect_sysctl() {
phase4-coordinator/dist/deploy-pearl-vps.sh-2969-      key="$1"
phase4-coordinator/dist/deploy-pearl-vps.sh:2970:      expected="$2"
phase4-coordinator/dist/deploy-pearl-vps.sh:2971:      actual="$(sysctl -n "$key" 2>/dev/null || true)"
phase4-coordinator/dist/deploy-pearl-vps.sh:2972:      if [ "$actual" != "$expected" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:2973:        echo "ABORT: sysctl $key mismatch: expected $expected, got ${actual:-<unset>}" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-2974-        return 1
phase4-coordinator/dist/deploy-pearl-vps.sh-2975-      fi
phase4-coordinator/dist/deploy-pearl-vps.sh-2976-      return 0
phase4-coordinator/dist/deploy-pearl-vps.sh-2977-    }
phase4-coordinator/dist/deploy-pearl-vps.sh-2978-
phase4-coordinator/dist/deploy-pearl-vps.sh-2979-    all_tcp_sysctls_applied() {
phase4-coordinator/dist/deploy-pearl-vps.sh:2980:      while IFS='=' read -r key expected; do
phase4-coordinator/dist/deploy-pearl-vps.sh-2981-        key="$(printf '%s' "$key" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
phase4-coordinator/dist/deploy-pearl-vps.sh:2982:        expected="$(printf '%s' "$expected" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
phase4-coordinator/dist/deploy-pearl-vps.sh-2983-        [ -n "$key" ] || continue
phase4-coordinator/dist/deploy-pearl-vps.sh-2984-        [ "${key:0:1}" = "#" ] && continue
phase4-coordinator/dist/deploy-pearl-vps.sh:2985:        expect_sysctl "$key" "$expected" || return 1
phase4-coordinator/dist/deploy-pearl-vps.sh-2986-      done < "$tmp_conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-2987-      return 0
phase4-coordinator/dist/deploy-pearl-vps.sh-2988-    }
phase4-coordinator/dist/deploy-pearl-vps.sh-2989-
phase4-coordinator/dist/deploy-pearl-vps.sh-2990-    if [ -f /etc/sysctl.d/99-macprovider-tcp.conf ] &&
phase4-coordinator/dist/deploy-pearl-vps.sh-2991-       [ -f /etc/modules-load.d/tcp_bbr.conf ] &&
phase4-coordinator/dist/deploy-pearl-vps.sh-2992-       cmp -s "$tmp_conf" /etc/sysctl.d/99-macprovider-tcp.conf &&
phase4-coordinator/dist/deploy-pearl-vps.sh-2993-       cmp -s "$tmp_modules_load" /etc/modules-load.d/tcp_bbr.conf &&
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3016-  case "$TCP_SYSCTL_RESULT" in
phase4-coordinator/dist/deploy-pearl-vps.sh-3017-    already)
phase4-coordinator/dist/deploy-pearl-vps.sh-3018-      log "  TCP sysctl overrides — already applied"
phase4-coordinator/dist/deploy-pearl-vps.sh-3019-      ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-3020-    applied)
phase4-coordinator/dist/deploy-pearl-vps.sh-3021-      log "  TCP sysctl overrides applied: bbr + slow_start_after_idle=0 + 16MB buffers"
phase4-coordinator/dist/deploy-pearl-vps.sh-3022-      ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-3023-    *)
phase4-coordinator/dist/deploy-pearl-vps.sh:3024:      echo "unexpected TCP sysctl deploy result: $TCP_SYSCTL_RESULT" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3025-      exit 10
phase4-coordinator/dist/deploy-pearl-vps.sh-3026-      ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-3027-  esac
phase4-coordinator/dist/deploy-pearl-vps.sh-3028-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3029-
phase4-coordinator/dist/deploy-pearl-vps.sh-3030-BACKUP_TS=$(date -u +%Y%m%dT%H%M%SZ)
phase4-coordinator/dist/deploy-pearl-vps.sh-3031-log "step 4/9: upload binary + config + nginx site (with rollback snapshot)"
phase4-coordinator/dist/deploy-pearl-vps.sh-3032-# Arm one coordinator release transaction before replacing any live file. The
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3215-# user (root). The wider /tmp permissions (1777) don't matter because
phase4-coordinator/dist/deploy-pearl-vps.sh-3216-# the fresh subdir denies traversal.
phase4-coordinator/dist/deploy-pearl-vps.sh-3217-DEPLOY_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-deploy.XXXXXXXX') || {
phase4-coordinator/dist/deploy-pearl-vps.sh-3218-  echo "failed to create remote staging directory" >&2; exit 1;
phase4-coordinator/dist/deploy-pearl-vps.sh-3219-}
phase4-coordinator/dist/deploy-pearl-vps.sh-3220-case "$DEPLOY_TMP" in
phase4-coordinator/dist/deploy-pearl-vps.sh-3221-  /tmp/macprovider-deploy.*) ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-3222-  *)
phase4-coordinator/dist/deploy-pearl-vps.sh:3223:    echo "aborting deploy: mktemp produced unexpected path: '$DEPLOY_TMP'" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3224-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-3225-    ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-3226-esac
phase4-coordinator/dist/deploy-pearl-vps.sh-3227-log "  staging dir: $DEPLOY_TMP (root:root 0700)"
phase4-coordinator/dist/deploy-pearl-vps.sh-3228-$SSH "install -d -o root -g root -m 0700 $DEPLOY_TMP/scripts"
phase4-coordinator/dist/deploy-pearl-vps.sh-3229-
phase4-coordinator/dist/deploy-pearl-vps.sh-3230-DEPLOY_INPUT_MANIFEST_TMP="$(umask 077 && mktemp -t macprovider-deploy-inputs.XXXXXXXX)" || {
phase4-coordinator/dist/deploy-pearl-vps.sh-3231-  echo "aborting deploy: mktemp failed for deploy input manifest" >&2
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3238-_append_deploy_input_digest "$BINARY" "coordinator-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3239-_append_deploy_input_digest "$CLI_BINARY" "coordinator-cli-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3240-_append_deploy_input_digest "$STATS_INVENTORY_BINARY" "stats-inventory-sync-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3241-_append_deploy_input_digest "$STATS_BILLING_MIRROR_BINARY" "stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3242-_append_deploy_input_digest "$STATS_HARDWARE_VERIFIER_BINARY" "stats-hardware-verifier-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3243-if [ "$CONFIG_MODE" = "apply-tracked" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3244-  _append_deploy_input_digest "$CONFIG" "coordinator.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3245-elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3246:  _append_deploy_input_digest "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.rate-card-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3247-elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3248-  _append_deploy_input_digest "$C2_TIMER_MIGRATED_CONFIG_TMP" "coordinator.c2-timer-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3249-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3250-if [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3251:  _append_deploy_input_digest "$RATE_CARD_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.rate-card-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3252-elif [ "${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3253-  _append_deploy_input_digest "$C2_TIMER_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.c2-timer-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3254-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3255-for _deploy_input in \
phase4-coordinator/dist/deploy-pearl-vps.sh-3256-  "$SERVICE=macprovider-coordinator.service" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3257-  "$STATS_INVENTORY_SERVICE=stats-inventory-sync.service" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3258-  "$STATS_INVENTORY_TIMER=stats-inventory-sync.timer" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3259-  "$STATS_BILLING_MIRROR_SERVICE=stats-billing-mirror.service" \
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3262-  "$STATS_HARDWARE_VERIFIER_TIMER=stats-hardware-verifier.timer" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3263-  "$NGINX_SITE=nginx-coordinator-full.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3264-  "$NGINX_STATS_SHARED=nginx-stats-shared.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3265-  "$NGINX_STATS_SECHEADERS=nginx-stats-security-headers.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3266-  "$NGINX_STATS_CORS_429=nginx-stats-cors-429.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3267-  "$NGINX_STATS_PROXY_PUBLIC=nginx-stats-proxy-public.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3268-  "$NGINX_STATS_PROXY_PARTNER=nginx-stats-proxy-partner.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh-3269-  "$NGINX_STATS_SITE=nginx-stats.malibu.tech.conf" \
phase4-coordinator/dist/deploy-pearl-vps.sh:3270:  "$STATIC_DEMAND_JSON=demand-rank.json" \
phase4-coordinator/dist/deploy-pearl-vps.sh:3271:  "$STATIC_DEMAND_SIG=demand-rank.json.sig" \
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
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3296-$SCP "$BINARY"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3297-$SCP "$CLI_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-cli-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3298-$SCP "$STATS_INVENTORY_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3299-$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3300-$SCP "$STATS_HARDWARE_VERIFIER_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh-3301-if [ "$CONFIG_MODE" = "apply-tracked" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3302-  $SCP "$CONFIG" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3303-elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3304:  $SCP "$RATE_CARD_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.rate-card-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3305-elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3306-  $SCP "$C2_TIMER_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.c2-timer-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3307-else
phase4-coordinator/dist/deploy-pearl-vps.sh-3308-  log "  CONFIG_MODE=preserve-live — not uploading tracked coordinator.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3309-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3310-if [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3311:  $SCP "$RATE_CARD_MIGRATED_OVERLAY_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3312-elif [ "${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3313-  $SCP "$C2_TIMER_MIGRATED_OVERLAY_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.pearl-overlays.c2-timer-migration.yaml"
phase4-coordinator/dist/deploy-pearl-vps.sh-3314-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3315-$SCP "$SERVICE"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/macprovider-coordinator.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-3316-$SCP "$STATS_INVENTORY_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-3317-$SCP "$STATS_INVENTORY_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh-3318-$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"
phase4-coordinator/dist/deploy-pearl-vps.sh-3319-$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3328-# trip on missing zone names.).
phase4-coordinator/dist/deploy-pearl-vps.sh-3329-$SCP "$NGINX_STATS_SHARED"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-shared.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3330-$SCP "$NGINX_STATS_SECHEADERS" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-security-headers.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3331-$SCP "$NGINX_STATS_CORS_429"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-cors-429.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3332-$SCP "$NGINX_STATS_PROXY_PUBLIC"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-proxy-public.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3333-$SCP "$NGINX_STATS_PROXY_PARTNER" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-proxy-partner.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3334-$SCP "$NGINX_STATS_SITE"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats.malibu.tech.conf"
phase4-coordinator/dist/deploy-pearl-vps.sh-3335-# SPEC-023 v1.7.3 signed static feeds
phase4-coordinator/dist/deploy-pearl-vps.sh:3336:$SCP "$STATIC_DEMAND_JSON"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:3337:$SCP "$STATIC_DEMAND_SIG"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json.sig"
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
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3373-$SCP "$DEPLOY_INPUT_MANIFEST_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/deploy-inputs.sha256"
phase4-coordinator/dist/deploy-pearl-vps.sh-3374-$SSH "cd $DEPLOY_TMP && shasum -a 256 -c deploy-inputs.sha256 >/dev/null"
phase4-coordinator/dist/deploy-pearl-vps.sh-3375-echo "  staged deploy input digests OK"
phase4-coordinator/dist/deploy-pearl-vps.sh-3376-# #1688: run the exact verify-directory the staging block below runs, over the
phase4-coordinator/dist/deploy-pearl-vps.sh-3377-# same file set, before the config backup and any live config/release
phase4-coordinator/dist/deploy-pearl-vps.sh-3378-# mutation, so a verifier bundle that cannot verify on Pearl aborts early.
phase4-coordinator/dist/deploy-pearl-vps.sh-3379-# CATALOG_RELEASE_FILES must name exactly the files staged into
phase4-coordinator/dist/deploy-pearl-vps.sh-3380-# \$_autotune_stage below (deploy_catalog_verifier_closure.test.sh pins this).
phase4-coordinator/dist/deploy-pearl-vps.sh:3381:CATALOG_RELEASE_FILES="demand-rank.json demand-rank.json.sig autotune-candidates.json autotune-candidates.json.sig rate-card.json rate-card.json.sig tier2-catalog.json release.json trusted-keys.json"
phase4-coordinator/dist/deploy-pearl-vps.sh-3382-if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3383-  CATALOG_RELEASE_FILES="$CATALOG_RELEASE_FILES autotune-artifacts.json autotune-artifacts.json.sig"
phase4-coordinator/dist/deploy-pearl-vps.sh-3384-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3385-if ! $SSH "set -e
phase4-coordinator/dist/deploy-pearl-vps.sh-3386-  _preflight=$DEPLOY_TMP/catalog-preflight
phase4-coordinator/dist/deploy-pearl-vps.sh-3387-  rm -rf \$_preflight
phase4-coordinator/dist/deploy-pearl-vps.sh-3388-  install -d -m 0700 \$_preflight
phase4-coordinator/dist/deploy-pearl-vps.sh-3389-  for _f in $CATALOG_RELEASE_FILES; do cp $DEPLOY_TMP/\$_f \$_preflight/\$_f; done
phase4-coordinator/dist/deploy-pearl-vps.sh-3390-  _rc=0
phase4-coordinator/dist/deploy-pearl-vps.sh:3391:  python3 -I $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_preflight --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub || _rc=\$?
phase4-coordinator/dist/deploy-pearl-vps.sh-3392-  rm -rf \$_preflight
phase4-coordinator/dist/deploy-pearl-vps.sh-3393-  exit \$_rc"; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3394-  echo "aborting deploy: staged catalog release failed remote verify-directory preflight on the VPS (before config backup or release staging)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3395-  exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-3396-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3397-
phase4-coordinator/dist/deploy-pearl-vps.sh-3398-# #1688 A2: runtime-only stays runtime-only. Compare the staged release with
phase4-coordinator/dist/deploy-pearl-vps.sh-3399-# live autotune/current by CONTENT (weekly renewals re-id the live release on
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3416-    releases/[A-Za-z0-9]*) ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-3417-    *) echo \"invalid existing autotune current target: \$_live\" >&2; exit 1 ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-3418-  esac
phase4-coordinator/dist/deploy-pearl-vps.sh-3419-  case \"\$_live\" in
phase4-coordinator/dist/deploy-pearl-vps.sh-3420-    *[!A-Za-z0-9._/-]*|*/*/*) echo \"unsafe existing autotune current target: \$_live\" >&2; exit 1 ;;
phase4-coordinator/dist/deploy-pearl-vps.sh-3421-  esac
phase4-coordinator/dist/deploy-pearl-vps.sh-3422-  _live_t2_overlay=''
phase4-coordinator/dist/deploy-pearl-vps.sh-3423-  if [ -e /etc/macprovider/coordinator.pearl-overlays.yaml ]; then _live_t2_overlay='--tier2-coordinator-overlay /etc/macprovider/coordinator.pearl-overlays.yaml'; fi
phase4-coordinator/dist/deploy-pearl-vps.sh:3424:  python3 -I $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory /opt/macprovider/autotune/\$_live --tier2-coordinator-config /opt/macprovider/coordinator.yaml \$_live_t2_overlay --allow-expired-tier2 >&2 || exit 4
phase4-coordinator/dist/deploy-pearl-vps.sh-3425-  _compare=$DEPLOY_TMP/catalog-compare
phase4-coordinator/dist/deploy-pearl-vps.sh-3426-  rm -rf \$_compare
phase4-coordinator/dist/deploy-pearl-vps.sh-3427-  install -d -m 0700 \$_compare
phase4-coordinator/dist/deploy-pearl-vps.sh-3428-  for _f in $CATALOG_RELEASE_FILES; do cp $DEPLOY_TMP/\$_f \$_compare/\$_f; done
phase4-coordinator/dist/deploy-pearl-vps.sh-3429-  printf '%s\\n' \"\$_live\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3430-  _rc=0
phase4-coordinator/dist/deploy-pearl-vps.sh:3431:  python3 -I $DEPLOY_TMP/scripts/catalog-release.py compare-live --incoming \$_compare --live /opt/macprovider/autotune/\$_live --ledger $DEPLOY_TMP/release-ledger.json --tier2-content-index $DEPLOY_TMP/tier2-content-index.json || _rc=\$?
phase4-coordinator/dist/deploy-pearl-vps.sh-3432-  rm -rf \$_compare
phase4-coordinator/dist/deploy-pearl-vps.sh-3433-  exit \$_rc")" || CATALOG_COMPARE_RC=$?
phase4-coordinator/dist/deploy-pearl-vps.sh-3434-CATALOG_LIVE_TARGET="${CATALOG_COMPARE_OUT%%$'\n'*}"
phase4-coordinator/dist/deploy-pearl-vps.sh-3435-CATALOG_COMPARE_JSON=""
phase4-coordinator/dist/deploy-pearl-vps.sh-3436-case "$CATALOG_COMPARE_OUT" in *$'\n'*) CATALOG_COMPARE_JSON="${CATALOG_COMPARE_OUT#*$'\n'}" ;; esac
phase4-coordinator/dist/deploy-pearl-vps.sh-3437-if [ "$CATALOG_COMPARE_RC" = "4" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3438-  echo "aborting deploy: the LIVE catalog release autotune/current failed verify-directory on the VPS (signature, keyring, Tier-2, or manifest binding); refusing to classify or touch it — repair the live release first" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3439-  exit 1
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3594-     ! cmp -s $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3595-    echo "refusing stats-hardware-verifier replacement from direct deploy: install the signed matching stats sidecar release first" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3596-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-3597-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3598-  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier
phase4-coordinator/dist/deploy-pearl-vps.sh-3599-  if [ '$CONFIG_MODE' = 'apply-tracked' ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3600-    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.yaml /opt/macprovider/coordinator.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3601-  elif [ '${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}' = '1' ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3602:    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.rate-card-migration.yaml /opt/macprovider/coordinator.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3603-  elif [ '$C2_TIMER_CONFIG_MIGRATION' = '1' ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3604-    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.c2-timer-migration.yaml /opt/macprovider/coordinator.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3605-  else
phase4-coordinator/dist/deploy-pearl-vps.sh-3606-    echo '  preserving live /opt/macprovider/coordinator.yaml'
phase4-coordinator/dist/deploy-pearl-vps.sh-3607-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3608-  if [ '${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3609:    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3610-  elif [ '${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3611-    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.c2-timer-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3612-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3613-  install -d -o root -g macprovider -m 0750 /etc/macprovider
phase4-coordinator/dist/deploy-pearl-vps.sh-3614-  if [ -e /etc/macprovider/coordinator.pearl-overlays.yaml ] && [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3615-    echo 'refusing unsafe coordinator overlay path: /etc/macprovider/coordinator.pearl-overlays.yaml' >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3616-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-3617-  fi
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3647-  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
phase4-coordinator/dist/deploy-pearl-vps.sh-3648-  if ! mkdir \$_autotune_lock; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3649-    echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3650-    exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-3651-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3652-  trap 'rm -rf \"\$_autotune_stage\"; rmdir \"\$_autotune_lock\" 2>/dev/null || true' EXIT
phase4-coordinator/dist/deploy-pearl-vps.sh-3653-  rm -rf \$_autotune_stage
phase4-coordinator/dist/deploy-pearl-vps.sh-3654-  install -d -o root -g macprovider -m 0750 \$_autotune_stage
phase4-coordinator/dist/deploy-pearl-vps.sh:3655:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json \$_autotune_stage/demand-rank.json
phase4-coordinator/dist/deploy-pearl-vps.sh:3656:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json.sig \$_autotune_stage/demand-rank.json.sig
phase4-coordinator/dist/deploy-pearl-vps.sh-3657-  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json \$_autotune_stage/autotune-candidates.json
phase4-coordinator/dist/deploy-pearl-vps.sh-3658-  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json.sig \$_autotune_stage/autotune-candidates.json.sig
phase4-coordinator/dist/deploy-pearl-vps.sh:3659:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json \$_autotune_stage/rate-card.json
phase4-coordinator/dist/deploy-pearl-vps.sh:3660:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json.sig \$_autotune_stage/rate-card.json.sig$AUTOTUNE_ARTIFACT_INSTALL_LINES
phase4-coordinator/dist/deploy-pearl-vps.sh-3661-  install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json
phase4-coordinator/dist/deploy-pearl-vps.sh-3662-  install -o root -g macprovider -m 0640 $DEPLOY_TMP/release.json \$_autotune_stage/release.json
phase4-coordinator/dist/deploy-pearl-vps.sh-3663-  install -o root -g macprovider -m 0640 $DEPLOY_TMP/trusted-keys.json \$_autotune_stage/trusted-keys.json
phase4-coordinator/dist/deploy-pearl-vps.sh:3664:  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_stage --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
phase4-coordinator/dist/deploy-pearl-vps.sh-3665-  sync
phase4-coordinator/dist/deploy-pearl-vps.sh-3666-  if [ -e \$_autotune_release ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3667-    if ! diff -qr \$_autotune_stage \$_autotune_release >/dev/null; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3668-      echo 'catalog release envelope $AUTOTUNE_RELEASE_DIR_NAME already exists with different bytes' >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3669-      exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-3670-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3671-    rm -rf \$_autotune_stage
phase4-coordinator/dist/deploy-pearl-vps.sh-3672-  else
phase4-coordinator/dist/deploy-pearl-vps.sh-3673-    mv \$_autotune_stage \$_autotune_release
phase4-coordinator/dist/deploy-pearl-vps.sh-3674-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh:3675:  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_release --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
phase4-coordinator/dist/deploy-pearl-vps.sh-3676-  # First rollout: the new on-disk coordinator config already points at
phase4-coordinator/dist/deploy-pearl-vps.sh-3677-  # autotune/current. Establish that path as soon as the immutable release is
phase4-coordinator/dist/deploy-pearl-vps.sh-3678-  # staged so an abort before the late restart gate cannot leave the next
phase4-coordinator/dist/deploy-pearl-vps.sh-3679-  # service restart without feeds. Existing rollouts remain untouched here.
phase4-coordinator/dist/deploy-pearl-vps.sh-3680-  if [ ! -e \$_autotune_root/current ] && [ ! -L \$_autotune_root/current ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3681-    ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME \$_autotune_root/current.bootstrap
phase4-coordinator/dist/deploy-pearl-vps.sh-3682-    mv -Tf \$_autotune_root/current.bootstrap \$_autotune_root/current
phase4-coordinator/dist/deploy-pearl-vps.sh-3683-  fi
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3730-# STATS_REQUIRED=1 is set.
phase4-coordinator/dist/deploy-pearl-vps.sh-3731-#
phase4-coordinator/dist/deploy-pearl-vps.sh-3732-# This sequence is idempotent and never mutates a working production
phase4-coordinator/dist/deploy-pearl-vps.sh-3733-# vhost when there is nothing to change. Earlier versions wrote the
phase4-coordinator/dist/deploy-pearl-vps.sh-3734-# stub over the full vhost AND used in-place sed surgery on the full
phase4-coordinator/dist/deploy-pearl-vps.sh-3735-# config (corrupted brace balance). Both removed in #244 R1; the dist/
phase4-coordinator/dist/deploy-pearl-vps.sh-3736-# nginx confs now ship with active ssl_certificate directives and the
phase4-coordinator/dist/deploy-pearl-vps.sh-3737-# pre-upload assertion at the top of this script refuses to deploy
phase4-coordinator/dist/deploy-pearl-vps.sh:3738:# unless they remain active and bound to the expected hostname.
phase4-coordinator/dist/deploy-pearl-vps.sh-3739-
phase4-coordinator/dist/deploy-pearl-vps.sh-3740-# SPEC-017 v0.1.8 Step 4.B — stats.malibu.tech is a first-class
phase4-coordinator/dist/deploy-pearl-vps.sh-3741-# public hostname per SPEC §7.1; deploy applies the SAME ACME
phase4-coordinator/dist/deploy-pearl-vps.sh-3742-# stub + certbot + full-vhost pipeline used for the coordinator
phase4-coordinator/dist/deploy-pearl-vps.sh-3743-# hostname (round-4 ARCH r2 H1 / CODE r2 C1 fix).
phase4-coordinator/dist/deploy-pearl-vps.sh-3744-STATS_DOMAIN="${STATS_DOMAIN:-stats.malibu.tech}"
phase4-coordinator/dist/deploy-pearl-vps.sh-3745-
phase4-coordinator/dist/deploy-pearl-vps.sh-3746-# Classify domains by cert state on the remote host (#244 R1+R2+R3).
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4115-  " || { echo "aborting deploy: live catalog changed since compare-live or could not be pinned" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-4116-  # Post-restart smokes and the canary prove the LIVE release, not the tag's.
phase4-coordinator/dist/deploy-pearl-vps.sh-4117-  [ -n "$PINNED_DEPLOY_INPUT_DIR" ] || { echo "aborting deploy: no pinned input dir for the live catalog snapshot" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh-4118-  CATALOG_LIVE_SNAPSHOT="$PINNED_DEPLOY_INPUT_DIR/live-catalog"
phase4-coordinator/dist/deploy-pearl-vps.sh-4119-  mkdir -m 0700 "$CATALOG_LIVE_SNAPSHOT"
phase4-coordinator/dist/deploy-pearl-vps.sh-4120-  # shellcheck disable=SC2086 # fixed release file names
phase4-coordinator/dist/deploy-pearl-vps.sh-4121-  $SSH "tar -C /opt/macprovider/autotune/$CATALOG_LIVE_TARGET -cf - $CATALOG_RELEASE_FILES" | tar -xf - -C "$CATALOG_LIVE_SNAPSHOT" ||
phase4-coordinator/dist/deploy-pearl-vps.sh-4122-    { echo "aborting deploy: could not snapshot the live catalog release" >&2; exit 1; }
phase4-coordinator/dist/deploy-pearl-vps.sh:4123:  STATIC_DEMAND_JSON="$CATALOG_LIVE_SNAPSHOT/demand-rank.json"
phase4-coordinator/dist/deploy-pearl-vps.sh:4124:  STATIC_DEMAND_SIG="$CATALOG_LIVE_SNAPSHOT/demand-rank.json.sig"
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
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4263-  }
phase4-coordinator/dist/deploy-pearl-vps.sh-4264-  echo "  catalog OK: $CATALOG_SUMMARY"
phase4-coordinator/dist/deploy-pearl-vps.sh-4265-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4266-
phase4-coordinator/dist/deploy-pearl-vps.sh-4267-# SPEC-023 signed recommendation feeds smoke (buyer mux via nginx).
phase4-coordinator/dist/deploy-pearl-vps.sh-4268-log "  verifying coordinator can read autotune feeds as macprovider"
phase4-coordinator/dist/deploy-pearl-vps.sh-4269-$SSH "set -e
phase4-coordinator/dist/deploy-pearl-vps.sh-4270-  sudo -u macprovider test -r /opt/macprovider/autotune/current/autotune-candidates.json
phase4-coordinator/dist/deploy-pearl-vps.sh:4271:  sudo -u macprovider test -r /opt/macprovider/autotune/current/demand-rank.json
phase4-coordinator/dist/deploy-pearl-vps.sh:4272:  sudo -u macprovider test -r /opt/macprovider/autotune/current/rate-card.json
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
phase4-coordinator/dist/deploy-pearl-vps.sh:4284:    "/v1/demand-rank|demand-rank.json|$STATIC_DEMAND_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh:4285:    "/v1/demand-rank.sig|demand-rank.json.sig|$STATIC_DEMAND_SIG" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4286-    "/v1/autotune-candidates|autotune-candidates.json|$STATIC_AUTOTUNE_JSON" \
phase4-coordinator/dist/deploy-pearl-vps.sh-4287-    "/v1/autotune-candidates.sig|autotune-candidates.json.sig|$STATIC_AUTOTUNE_SIG"; do
phase4-coordinator/dist/deploy-pearl-vps.sh-4288-  STATIC_PATH="${STATIC_SPEC%%|*}"
phase4-coordinator/dist/deploy-pearl-vps.sh-4289-  STATIC_REST="${STATIC_SPEC#*|}"
phase4-coordinator/dist/deploy-pearl-vps.sh-4290-  STATIC_NAME="${STATIC_REST%%|*}"
phase4-coordinator/dist/deploy-pearl-vps.sh-4291-  STATIC_EXPECTED="${STATIC_REST#*|}"
phase4-coordinator/dist/deploy-pearl-vps.sh-4292-  STATIC_SMOKE_BODY="$STATIC_SMOKE_DIR/$STATIC_NAME"
phase4-coordinator/dist/deploy-pearl-vps.sh-4293-  echo "  GET https://$DOMAIN$STATIC_PATH -> expect 200"
--
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
--
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
phase4-coordinator/dist/deploy-pearl-vps.sh:4366:    expected_provider_id,
phase4-coordinator/dist/deploy-pearl-vps.sh:4367:    expected_release_id,
phase4-coordinator/dist/deploy-pearl-vps.sh:4368:    expected_policy_version,
phase4-coordinator/dist/deploy-pearl-vps.sh:4369:    expected_digest,
phase4-coordinator/dist/deploy-pearl-vps.sh:4370:    expected_signer,
phase4-coordinator/dist/deploy-pearl-vps.sh-4371-) = sys.argv[1:]
phase4-coordinator/dist/deploy-pearl-vps.sh-4372-home = os.path.expanduser("~")
phase4-coordinator/dist/deploy-pearl-vps.sh-4373-nofollow = getattr(os, "O_NOFOLLOW", 0)
phase4-coordinator/dist/deploy-pearl-vps.sh-4374-nonblock = getattr(os, "O_NONBLOCK", 0)
phase4-coordinator/dist/deploy-pearl-vps.sh-4375-directory_flags = os.O_RDONLY | os.O_DIRECTORY | nofollow
phase4-coordinator/dist/deploy-pearl-vps.sh-4376-
phase4-coordinator/dist/deploy-pearl-vps.sh-4377-def open_dir(path):
phase4-coordinator/dist/deploy-pearl-vps.sh-4378-    if os.path.isabs(path):
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4395-
phase4-coordinator/dist/deploy-pearl-vps.sh-4396-def read_regular_at(directory_fd, name, limit, require_owner=True):
phase4-coordinator/dist/deploy-pearl-vps.sh-4397-    fd = os.open(name, os.O_RDONLY | nofollow | nonblock, dir_fd=directory_fd)
phase4-coordinator/dist/deploy-pearl-vps.sh-4398-    try:
phase4-coordinator/dist/deploy-pearl-vps.sh-4399-        info = os.fstat(fd)
phase4-coordinator/dist/deploy-pearl-vps.sh-4400-        if not stat.S_ISREG(info.st_mode):
phase4-coordinator/dist/deploy-pearl-vps.sh-4401-            raise SystemExit(f"canary path is not a regular file: {name}")
phase4-coordinator/dist/deploy-pearl-vps.sh-4402-        if require_owner and info.st_uid != os.getuid():
phase4-coordinator/dist/deploy-pearl-vps.sh:4403:            raise SystemExit(f"canary file has unexpected owner: {name}")
phase4-coordinator/dist/deploy-pearl-vps.sh-4404-        if info.st_size > limit:
phase4-coordinator/dist/deploy-pearl-vps.sh-4405-            raise SystemExit(f"oversized canary file: {name}")
phase4-coordinator/dist/deploy-pearl-vps.sh-4406-        chunks = []
phase4-coordinator/dist/deploy-pearl-vps.sh-4407-        remaining = limit + 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4408-        while remaining:
phase4-coordinator/dist/deploy-pearl-vps.sh-4409-            chunk = os.read(fd, min(65536, remaining))
phase4-coordinator/dist/deploy-pearl-vps.sh-4410-            if not chunk:
phase4-coordinator/dist/deploy-pearl-vps.sh-4411-                break
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4420-
phase4-coordinator/dist/deploy-pearl-vps.sh-4421-def open_parent_and_name(path):
phase4-coordinator/dist/deploy-pearl-vps.sh-4422-    normalized = os.path.normpath(path)
phase4-coordinator/dist/deploy-pearl-vps.sh-4423-    parent, name = os.path.split(normalized)
phase4-coordinator/dist/deploy-pearl-vps.sh-4424-    if not name or name in {".", ".."}:
phase4-coordinator/dist/deploy-pearl-vps.sh-4425-        raise SystemExit(f"unsafe canary file path: {path}")
phase4-coordinator/dist/deploy-pearl-vps.sh-4426-    return open_dir(parent or "."), name
phase4-coordinator/dist/deploy-pearl-vps.sh-4427-
phase4-coordinator/dist/deploy-pearl-vps.sh:4428:def running_text_vnode_path(pid, binary_info, expected_binary, runner=subprocess.run):
phase4-coordinator/dist/deploy-pearl-vps.sh-4429-    fields = runner(
phase4-coordinator/dist/deploy-pearl-vps.sh-4430-        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-F", "Dfin"],
phase4-coordinator/dist/deploy-pearl-vps.sh-4431-        check=True,
phase4-coordinator/dist/deploy-pearl-vps.sh-4432-        stdout=subprocess.PIPE,
phase4-coordinator/dist/deploy-pearl-vps.sh-4433-        stderr=subprocess.PIPE,
phase4-coordinator/dist/deploy-pearl-vps.sh-4434-        text=True,
phase4-coordinator/dist/deploy-pearl-vps.sh-4435-        timeout=10,
phase4-coordinator/dist/deploy-pearl-vps.sh-4436-    ).stdout.splitlines()
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4453-        normalized_text_path = (
phase4-coordinator/dist/deploy-pearl-vps.sh-4454-            os.path.normpath(text_path.removesuffix(" (deleted)"))
phase4-coordinator/dist/deploy-pearl-vps.sh-4455-            if text_path is not None
phase4-coordinator/dist/deploy-pearl-vps.sh-4456-            else None
phase4-coordinator/dist/deploy-pearl-vps.sh-4457-        )
phase4-coordinator/dist/deploy-pearl-vps.sh-4458-        if (
phase4-coordinator/dist/deploy-pearl-vps.sh-4459-            text_device == binary_info.st_dev
phase4-coordinator/dist/deploy-pearl-vps.sh-4460-            and text_inode == binary_info.st_ino
phase4-coordinator/dist/deploy-pearl-vps.sh:4461:            and normalized_text_path == expected_binary
phase4-coordinator/dist/deploy-pearl-vps.sh-4462-        ):
phase4-coordinator/dist/deploy-pearl-vps.sh-4463-            return normalized_text_path
phase4-coordinator/dist/deploy-pearl-vps.sh-4464-    return None
phase4-coordinator/dist/deploy-pearl-vps.sh-4465-
phase4-coordinator/dist/deploy-pearl-vps.sh-4466-catalog_fd = open_dir(catalog_path)
phase4-coordinator/dist/deploy-pearl-vps.sh-4467-install_path = os.path.dirname(os.path.normpath(catalog_path)) or "."
phase4-coordinator/dist/deploy-pearl-vps.sh-4468-install_fd = open_dir(install_path)
phase4-coordinator/dist/deploy-pearl-vps.sh-4469-config_fd = provider_config_fd = binary_fd = None
phase4-coordinator/dist/deploy-pearl-vps.sh-4470-try:
phase4-coordinator/dist/deploy-pearl-vps.sh-4471-    provider_config_fd = open_dir(".config/macprovider")
phase4-coordinator/dist/deploy-pearl-vps.sh-4472-    provider_bytes, _ = read_regular_at(provider_config_fd, "provider_id", 1024)
phase4-coordinator/dist/deploy-pearl-vps.sh-4473-    provider_id = provider_bytes.decode("utf-8").strip()
phase4-coordinator/dist/deploy-pearl-vps.sh:4474:    if provider_id != expected_provider_id:
phase4-coordinator/dist/deploy-pearl-vps.sh-4475-        raise SystemExit(
phase4-coordinator/dist/deploy-pearl-vps.sh:4476:            f"canary provider identity mismatch: expected={expected_provider_id} actual={provider_id}"
phase4-coordinator/dist/deploy-pearl-vps.sh-4477-        )
phase4-coordinator/dist/deploy-pearl-vps.sh-4478-
phase4-coordinator/dist/deploy-pearl-vps.sh-4479-    plist_dir_fd = open_dir("Library/LaunchAgents")
phase4-coordinator/dist/deploy-pearl-vps.sh-4480-    try:
phase4-coordinator/dist/deploy-pearl-vps.sh-4481-        plist_bytes, _ = read_regular_at(
phase4-coordinator/dist/deploy-pearl-vps.sh-4482-            plist_dir_fd, "live.malibu.provider.plist", 1024 * 1024
phase4-coordinator/dist/deploy-pearl-vps.sh-4483-        )
phase4-coordinator/dist/deploy-pearl-vps.sh-4484-    finally:
phase4-coordinator/dist/deploy-pearl-vps.sh-4485-        os.close(plist_dir_fd)
phase4-coordinator/dist/deploy-pearl-vps.sh-4486-    plist = plistlib.loads(plist_bytes)
phase4-coordinator/dist/deploy-pearl-vps.sh-4487-    arguments = plist.get("ProgramArguments")
phase4-coordinator/dist/deploy-pearl-vps.sh-4488-    if not isinstance(arguments, list) or len(arguments) < 4 or arguments[1:3] != ["serve", "--config"]:
phase4-coordinator/dist/deploy-pearl-vps.sh:4489:        raise SystemExit("canary provider LaunchAgent has unexpected ProgramArguments")
phase4-coordinator/dist/deploy-pearl-vps.sh-4490-
phase4-coordinator/dist/deploy-pearl-vps.sh-4491-    binary_fd = os.open(
phase4-coordinator/dist/deploy-pearl-vps.sh-4492-        "macprovider-cli", os.O_RDONLY | nofollow | nonblock, dir_fd=install_fd
phase4-coordinator/dist/deploy-pearl-vps.sh-4493-    )
phase4-coordinator/dist/deploy-pearl-vps.sh-4494-    binary_info = os.fstat(binary_fd)
phase4-coordinator/dist/deploy-pearl-vps.sh-4495-    if not stat.S_ISREG(binary_info.st_mode) or binary_info.st_uid != os.getuid() or binary_info.st_mode & 0o111 == 0:
phase4-coordinator/dist/deploy-pearl-vps.sh-4496-        raise SystemExit("canary installation binary is not a safe executable")
phase4-coordinator/dist/deploy-pearl-vps.sh-4497-    install_absolute = install_path if os.path.isabs(install_path) else os.path.join(home, install_path)
phase4-coordinator/dist/deploy-pearl-vps.sh:4498:    expected_binary = os.path.normpath(os.path.join(install_absolute, "macprovider-cli"))
phase4-coordinator/dist/deploy-pearl-vps.sh:4499:    if os.path.normpath(arguments[0]) != expected_binary:
phase4-coordinator/dist/deploy-pearl-vps.sh-4500-        raise SystemExit("canary LaunchAgent does not use the catalog installation root")
phase4-coordinator/dist/deploy-pearl-vps.sh-4501-
phase4-coordinator/dist/deploy-pearl-vps.sh-4502-    launchd = subprocess.run(
phase4-coordinator/dist/deploy-pearl-vps.sh-4503-        ["launchctl", "print", f"gui/{os.getuid()}/live.malibu.provider"],
phase4-coordinator/dist/deploy-pearl-vps.sh-4504-        check=True,
phase4-coordinator/dist/deploy-pearl-vps.sh-4505-        stdout=subprocess.PIPE,
phase4-coordinator/dist/deploy-pearl-vps.sh-4506-        stderr=subprocess.PIPE,
phase4-coordinator/dist/deploy-pearl-vps.sh-4507-        text=True,
phase4-coordinator/dist/deploy-pearl-vps.sh-4508-        timeout=10,
phase4-coordinator/dist/deploy-pearl-vps.sh-4509-    ).stdout
phase4-coordinator/dist/deploy-pearl-vps.sh-4510-    match = re.search(r"(?m)^\s*pid = ([0-9]+)\s*$", launchd)
phase4-coordinator/dist/deploy-pearl-vps.sh-4511-    if match is None:
phase4-coordinator/dist/deploy-pearl-vps.sh-4512-        raise SystemExit("canary provider LaunchAgent has no live PID")
phase4-coordinator/dist/deploy-pearl-vps.sh-4513-    pid = int(match.group(1))
phase4-coordinator/dist/deploy-pearl-vps.sh:4514:    process_path = running_text_vnode_path(pid, binary_info, expected_binary)
phase4-coordinator/dist/deploy-pearl-vps.sh-4515-    if process_path is None:
phase4-coordinator/dist/deploy-pearl-vps.sh-4516-        raise SystemExit("live canary provider text vnode is stale or not the verified installation binary")
phase4-coordinator/dist/deploy-pearl-vps.sh-4517-
phase4-coordinator/dist/deploy-pearl-vps.sh-4518-    config_fd, config_name = open_parent_and_name(arguments[3])
phase4-coordinator/dist/deploy-pearl-vps.sh-4519-    config_bytes, _ = read_regular_at(config_fd, config_name, 1024 * 1024)
phase4-coordinator/dist/deploy-pearl-vps.sh-4520-    config_text = config_bytes.decode("utf-8")
phase4-coordinator/dist/deploy-pearl-vps.sh-4521-    port_match = re.search(r'(?m)^\s*port:\s*"?([0-9]+)"?\s*(?:#.*)?$', config_text)
phase4-coordinator/dist/deploy-pearl-vps.sh-4522-    if port_match is None or not (1 <= int(port_match.group(1)) <= 65535):
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4539-    with opener.open(f"http://127.0.0.1:{port}/v1/status", timeout=10) as response:
phase4-coordinator/dist/deploy-pearl-vps.sh-4540-        if response.status != 200:
phase4-coordinator/dist/deploy-pearl-vps.sh-4541-            raise SystemExit(f"canary local status returned HTTP {response.status}")
phase4-coordinator/dist/deploy-pearl-vps.sh-4542-        local_status = json.loads(response.read(1024 * 1024))
phase4-coordinator/dist/deploy-pearl-vps.sh-4543-    catalog = local_status.get("catalog")
phase4-coordinator/dist/deploy-pearl-vps.sh-4544-    coordinator = local_status.get("coordinator")
phase4-coordinator/dist/deploy-pearl-vps.sh-4545-    assigned_id = coordinator.get("session") if isinstance(coordinator, dict) else None
phase4-coordinator/dist/deploy-pearl-vps.sh-4546-    if (
phase4-coordinator/dist/deploy-pearl-vps.sh:4547:        local_status.get("provider_id") != expected_provider_id
phase4-coordinator/dist/deploy-pearl-vps.sh-4548-        or local_status.get("network_state") != "buyer_serving"
phase4-coordinator/dist/deploy-pearl-vps.sh-4549-        or not isinstance(coordinator, dict)
phase4-coordinator/dist/deploy-pearl-vps.sh-4550-        or coordinator.get("connected") is not True
phase4-coordinator/dist/deploy-pearl-vps.sh-4551-        or not isinstance(assigned_id, str)
phase4-coordinator/dist/deploy-pearl-vps.sh-4552-        or not assigned_id
phase4-coordinator/dist/deploy-pearl-vps.sh-4553-        or not isinstance(catalog, dict)
phase4-coordinator/dist/deploy-pearl-vps.sh:4554:        or catalog.get("release_id") != expected_release_id
phase4-coordinator/dist/deploy-pearl-vps.sh:4555:        or catalog.get("policy_version") != expected_policy_version
phase4-coordinator/dist/deploy-pearl-vps.sh:4556:        or catalog.get("digest") != expected_digest
phase4-coordinator/dist/deploy-pearl-vps.sh:4557:        or catalog.get("signer_key_id") != expected_signer
phase4-coordinator/dist/deploy-pearl-vps.sh-4558-        or re.fullmatch(r"[0-9a-f]{64}", str(catalog.get("row_identity", "")).lower()) is None
phase4-coordinator/dist/deploy-pearl-vps.sh-4559-    ):
phase4-coordinator/dist/deploy-pearl-vps.sh:4560:        raise SystemExit("live canary provider status does not match the expected identity and catalog")
phase4-coordinator/dist/deploy-pearl-vps.sh-4561-
phase4-coordinator/dist/deploy-pearl-vps.sh-4562-    names = (
phase4-coordinator/dist/deploy-pearl-vps.sh-4563-        "release.json",
phase4-coordinator/dist/deploy-pearl-vps.sh-4564-        "trusted-keys.json",
phase4-coordinator/dist/deploy-pearl-vps.sh-4565-        "autotune-candidates.json",
phase4-coordinator/dist/deploy-pearl-vps.sh-4566-        "autotune-candidates.json.sig",
phase4-coordinator/dist/deploy-pearl-vps.sh:4567:        "demand-rank.json",
phase4-coordinator/dist/deploy-pearl-vps.sh:4568:        "demand-rank.json.sig",
phase4-coordinator/dist/deploy-pearl-vps.sh:4569:        "rate-card.json",
phase4-coordinator/dist/deploy-pearl-vps.sh:4570:        "rate-card.json.sig",
phase4-coordinator/dist/deploy-pearl-vps.sh-4571-        "tier2-catalog.json",
phase4-coordinator/dist/deploy-pearl-vps.sh-4572-    )
phase4-coordinator/dist/deploy-pearl-vps.sh-4573-    hashes = {}
phase4-coordinator/dist/deploy-pearl-vps.sh-4574-    for name in names:
phase4-coordinator/dist/deploy-pearl-vps.sh-4575-        payload, _ = read_regular_at(catalog_fd, name, 2 * 1024 * 1024)
phase4-coordinator/dist/deploy-pearl-vps.sh-4576-        hashes[name] = hashlib.sha256(payload).hexdigest()
phase4-coordinator/dist/deploy-pearl-vps.sh-4577-    print(json.dumps({
phase4-coordinator/dist/deploy-pearl-vps.sh-4578-        "provider_id": provider_id,
--
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
--
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
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4711-    or re.fullmatch(r"[0-9a-f]{64}", pool_row) is None
phase4-coordinator/dist/deploy-pearl-vps.sh-4712-    or local_catalog.get("release_id") != pool.get("catalog_release_id")
phase4-coordinator/dist/deploy-pearl-vps.sh-4713-    or local_catalog.get("policy_version") != pool.get("catalog_policy_version")
phase4-coordinator/dist/deploy-pearl-vps.sh-4714-    or str(local_catalog.get("digest", "")).lower() != str(pool.get("catalog_candidate_sha256", "")).lower()
phase4-coordinator/dist/deploy-pearl-vps.sh-4715-    or local_catalog.get("signer_key_id") != pool.get("catalog_signer_key_id")
phase4-coordinator/dist/deploy-pearl-vps.sh-4716-    or str(local_catalog.get("row_identity", "")).lower() != pool_row
phase4-coordinator/dist/deploy-pearl-vps.sh-4717-):
phase4-coordinator/dist/deploy-pearl-vps.sh-4718-    raise SystemExit("canary local catalog proof is not bound to the coordinator-admitted envelope")
phase4-coordinator/dist/deploy-pearl-vps.sh:4719:actual = proof.get("files")
phase4-coordinator/dist/deploy-pearl-vps.sh:4720:if not isinstance(actual, dict):
phase4-coordinator/dist/deploy-pearl-vps.sh-4721-    raise SystemExit("canary proof is missing installed file hashes")
phase4-coordinator/dist/deploy-pearl-vps.sh:4722:expected = {}
phase4-coordinator/dist/deploy-pearl-vps.sh-4723-for raw_path in sys.argv[4:]:
phase4-coordinator/dist/deploy-pearl-vps.sh-4724-    path = pathlib.Path(raw_path)
phase4-coordinator/dist/deploy-pearl-vps.sh:4725:    expected[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
phase4-coordinator/dist/deploy-pearl-vps.sh:4726:if actual != expected:
phase4-coordinator/dist/deploy-pearl-vps.sh:4727:    missing = sorted(set(expected) - set(actual))
phase4-coordinator/dist/deploy-pearl-vps.sh:4728:    extra = sorted(set(actual) - set(expected))
phase4-coordinator/dist/deploy-pearl-vps.sh:4729:    changed = sorted(name for name in set(actual) & set(expected) if actual[name] != expected[name])
phase4-coordinator/dist/deploy-pearl-vps.sh-4730-    raise SystemExit(f"canary catalog byte mismatch: missing={missing} extra={extra} changed={changed}")
phase4-coordinator/dist/deploy-pearl-vps.sh-4731-PY
phase4-coordinator/dist/deploy-pearl-vps.sh-4732-then
phase4-coordinator/dist/deploy-pearl-vps.sh-4733-  echo "SPEC-023 canary failed: installed catalog bytes do not match the verified deployment release" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4734-  exit 1
phase4-coordinator/dist/deploy-pearl-vps.sh-4735-fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4736-echo "  SPEC-023 exact-byte canary OK: selected provider's live process uses the verified catalog release"
phase4-coordinator/dist/deploy-pearl-vps.sh-4737-
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4752-  # silently passing the `[ "$STATS" = "000" ]` failure branch.
phase4-coordinator/dist/deploy-pearl-vps.sh-4753-  if ! STATS_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$STATS_DOMAIN/v1/stats/health?deploy_smoke=$STATS_SMOKE_NONCE" 2>/dev/null); then
phase4-coordinator/dist/deploy-pearl-vps.sh-4754-    STATS_STATUS="000"
phase4-coordinator/dist/deploy-pearl-vps.sh-4755-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4756-  if [ "$STATS_STATUS" != "200" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4757-    if [ "$STATS_STATUS" = "000" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4758-      echo "  ABORT: $STATS_DOMAIN /v1/stats/health unreachable (TLS handshake or DNS failed)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4759-    else
phase4-coordinator/dist/deploy-pearl-vps.sh:4760:      echo "  ABORT: $STATS_DOMAIN /v1/stats/health returned status=$STATS_STATUS (expected 200)" >&2
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
phase4-coordinator/dist/deploy-pearl-vps.sh-4772-  if [ "$STATS_OVERVIEW_STATUS" != "200" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4773:    echo "  ABORT: $STATS_DOMAIN /v1/stats/overview returned status=$STATS_OVERVIEW_STATUS (expected 200)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4774-    rm -f "$STATS_HEADERS"
phase4-coordinator/dist/deploy-pearl-vps.sh-4775-    exit 9
phase4-coordinator/dist/deploy-pearl-vps.sh-4776-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4777-  if ! tr -d '\r' < "$STATS_HEADERS" | grep -Eiq '^access-control-allow-origin:[[:space:]]*(\*|https://www\.malibu\.tech)[[:space:]]*$'; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4778-    echo "  ABORT: $STATS_DOMAIN /v1/stats/overview did not return a Malibu-compatible Access-Control-Allow-Origin header" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4779-    sed 's/^/    /' "$STATS_HEADERS" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4780-    rm -f "$STATS_HEADERS"
phase4-coordinator/dist/deploy-pearl-vps.sh-4781-    exit 9
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4783-  rm -f "$STATS_HEADERS"
phase4-coordinator/dist/deploy-pearl-vps.sh-4784-  echo "  ok: $STATS_DOMAIN /v1/stats/overview responded 200 with Malibu-compatible CORS"
phase4-coordinator/dist/deploy-pearl-vps.sh-4785-
phase4-coordinator/dist/deploy-pearl-vps.sh-4786-  echo "  GET https://$STATS_DOMAIN/v1/stats/leaderboard?deploy_smoke=<nonce> -> expect 200"
phase4-coordinator/dist/deploy-pearl-vps.sh-4787-  if ! STATS_LEADERBOARD_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$STATS_DOMAIN/v1/stats/leaderboard?deploy_smoke=$STATS_SMOKE_NONCE" 2>/dev/null); then
phase4-coordinator/dist/deploy-pearl-vps.sh-4788-    STATS_LEADERBOARD_STATUS="000"
phase4-coordinator/dist/deploy-pearl-vps.sh-4789-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4790-  if [ "$STATS_LEADERBOARD_STATUS" != "200" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4791:    echo "  ABORT: $STATS_DOMAIN /v1/stats/leaderboard returned status=$STATS_LEADERBOARD_STATUS (expected 200)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4792-    echo "  stats.enabled=true in $DEPLOY_CONFIG — Malibu stats population smoke is mandatory." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4793-    exit 9
phase4-coordinator/dist/deploy-pearl-vps.sh-4794-  else
phase4-coordinator/dist/deploy-pearl-vps.sh-4795-    echo "  ok: $STATS_DOMAIN /v1/stats/leaderboard responded 200"
phase4-coordinator/dist/deploy-pearl-vps.sh-4796-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4797-else
phase4-coordinator/dist/deploy-pearl-vps.sh-4798-  # Stats disabled in deployed config. If STATS_REQUIRED=1, the operator
phase4-coordinator/dist/deploy-pearl-vps.sh-4799-  # explicitly asked for strict mode but disabled stats — that's

exec
/bin/bash -lc 'git status -sb && git diff --stat origin/main...HEAD && git diff -- phase4-coordinator/dist/deploy-pearl-vps.sh test/integration/check_deploy_static_feed_access.test.sh origin/main...HEAD' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
## fix/deploy-canary-rate-card-bytes...origin/fix/deploy-canary-rate-card-bytes
?? audits/2026-09-25-deploy-canary-rate-card/
 phase4-coordinator/dist/deploy-pearl-vps.sh        |  2 ++
 .../test/check_deploy_static_feed_access.test.sh   | 29 +++++++++++++++++++---
 2 files changed, 28 insertions(+), 3 deletions(-)

codex
The branch contains only the two requested tracked changes; there is also an untracked `audits/2026-09-25-deploy-canary-rate-card/` directory, which I’m leaving untouched. The test path is `phase4-coordinator/dist/test/...`, so I’m narrowing the review to the exact patch and surrounding proof invocation now.
exec
/bin/bash -lc "sed -n '4528,4740p' phase4-coordinator/dist/deploy-pearl-vps.sh" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    )
    if str(pid) not in listener.stdout.split():
        raise SystemExit("live canary provider PID does not own its configured status port")
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, _request, _fp, _code, _message, _headers, _new_url):
            raise RuntimeError("canary local status redirect refused")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(f"http://127.0.0.1:{port}/v1/status", timeout=10) as response:
        if response.status != 200:
            raise SystemExit(f"canary local status returned HTTP {response.status}")
        local_status = json.loads(response.read(1024 * 1024))
    catalog = local_status.get("catalog")
    coordinator = local_status.get("coordinator")
    assigned_id = coordinator.get("session") if isinstance(coordinator, dict) else None
    if (
        local_status.get("provider_id") != expected_provider_id
        or local_status.get("network_state") != "buyer_serving"
        or not isinstance(coordinator, dict)
        or coordinator.get("connected") is not True
        or not isinstance(assigned_id, str)
        or not assigned_id
        or not isinstance(catalog, dict)
        or catalog.get("release_id") != expected_release_id
        or catalog.get("policy_version") != expected_policy_version
        or catalog.get("digest") != expected_digest
        or catalog.get("signer_key_id") != expected_signer
        or re.fullmatch(r"[0-9a-f]{64}", str(catalog.get("row_identity", "")).lower()) is None
    ):
        raise SystemExit("live canary provider status does not match the expected identity and catalog")

    names = (
        "release.json",
        "trusted-keys.json",
        "autotune-candidates.json",
        "autotune-candidates.json.sig",
        "demand-rank.json",
        "demand-rank.json.sig",
        "rate-card.json",
        "rate-card.json.sig",
        "tier2-catalog.json",
    )
    hashes = {}
    for name in names:
        payload, _ = read_regular_at(catalog_fd, name, 2 * 1024 * 1024)
        hashes[name] = hashlib.sha256(payload).hexdigest()
    print(json.dumps({
        "provider_id": provider_id,
        "assigned_id": assigned_id,
        "launchd_pid": pid,
        "executable_path": process_path,
        "local_status": local_status,
        "files": hashes,
    }, sort_keys=True))
finally:
    for fd in (config_fd, provider_config_fd, binary_fd, install_fd, catalog_fd):
        if fd is not None:
            os.close(fd)
PY
}

# A coordinator restart can make a healthy provider rotate its PID and assigned
# session while its recovery watchdog drains in-flight work. Retry the complete
# Mac proof and bind each admission query to the session from that same attempt;
# never carry an assigned_id across retries. This mirrors the signed updater's
# full-proof retry and keeps every success predicate fail-closed.
CANARY_PROVIDER_QUERY=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CATALOG_CANARY_PROVIDER_ID")
(umask 077 && printf 'header = "Authorization: Bearer %s"\n' "$CATALOG_CANARY_AUTH_TOKEN" > "$CANARY_CURL_CONFIG")
CANARY_OK=0
CANARY_LAST_ERROR="canary proof did not start"
CANARY_STATUS="000"
CANARY_ATTEMPT=1
CANARY_MAX_ATTEMPTS=36
CANARY_RECOVERY_TIMEOUT_S=180
CANARY_RECOVERY_DEADLINE=$((SECONDS + CANARY_RECOVERY_TIMEOUT_S))
while [ "$CANARY_ATTEMPT" -le "$CANARY_MAX_ATTEMPTS" ] && [ "$SECONDS" -lt "$CANARY_RECOVERY_DEADLINE" ]; do
  rm -f "$CANARY_INSTALLED_BODY" "$CANARY_POOL_BODY"
  CANARY_PROOF_ERROR="$STATIC_SMOKE_DIR/catalog-canary-proof.err"
  CANARY_REMAINING_S=$((CANARY_RECOVERY_DEADLINE - SECONDS))
  CANARY_PROOF_TIMEOUT_S=45
  if [ "$CANARY_REMAINING_S" -lt "$CANARY_PROOF_TIMEOUT_S" ]; then
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
  "$STATIC_RATE_CARD_JSON" \
  "$STATIC_RATE_CARD_SIG" \
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

exec
/bin/bash -lc "sed -n '1,260p' phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
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
/bin/bash -lc 'git diff --no-ext-diff --unified=80 origin/main...HEAD -- phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
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
diff --git a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
index a7745788..292e99c4 100755
--- a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
+++ b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
@@ -407,154 +407,177 @@ _catalog_canary_auth_token_matches_operator_key "$HEX64" "$(printf '%s' "$HEX64_
 
 deadline_alarm_tmp="$(mktemp)"
 trap 'rm -f "$token_validator_tmp" "$token_loader_tmp" "$canary_operator_guard_tmp" "$deadline_alarm_tmp"; rm -rf "$token_file_dir" "$security_mock_dir"' EXIT
 awk '/^_run_with_deadline_alarm\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" > "$deadline_alarm_tmp"
 grep -qF '_run_with_deadline_alarm()' "$deadline_alarm_tmp" ||
   fail "deploy must keep an extractable subprocess deadline helper"
 # shellcheck disable=SC1090
 . "$deadline_alarm_tmp"
 deadline_start="$SECONDS"
 if _run_with_deadline_alarm 1 sh -c 'sleep 30'; then
   fail "subprocess deadline helper must terminate a hung command"
 fi
 [ "$((SECONDS - deadline_start))" -lt 5 ] ||
   fail "subprocess deadline helper did not enforce its wall-clock bound"
 _run_with_deadline_alarm 2 sh -c 'exit 0' ||
   fail "subprocess deadline helper must preserve successful commands"
 
 deadline_parser_tmp="$(mktemp)"
 trap 'rm -f "$token_validator_tmp" "$token_loader_tmp" "$canary_operator_guard_tmp" "$deadline_alarm_tmp" "$deadline_parser_tmp"; rm -rf "$token_file_dir" "$security_mock_dir"' EXIT
 awk '/^_parse_model_hash_legacy_until\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" > "$deadline_parser_tmp"
 grep -qF '_parse_model_hash_legacy_until()' "$deadline_parser_tmp" ||
   fail "deploy must keep an extractable MODEL_HASH_LEGACY_UNTIL parser"
 # shellcheck disable=SC1090
 . "$deadline_parser_tmp"
 deadline='2030-01-02T03:04:05Z'
 [ "$(_parse_model_hash_legacy_until "  $deadline  ")" = "$deadline" ] ||
   fail "legacy deadline parser must accept an unquoted scalar"
 [ "$(_parse_model_hash_legacy_until "  \"$deadline\"  ")" = "$deadline" ] ||
   fail "legacy deadline parser must strip matching double quotes"
 [ "$(_parse_model_hash_legacy_until "  '$deadline'  ")" = "$deadline" ] ||
   fail "legacy deadline parser must strip matching single quotes"
 [ -z "$(_parse_model_hash_legacy_until '   ')" ] ||
   fail "legacy deadline parser must preserve an absent deadline as empty"
 if _parse_model_hash_legacy_until '2030-01-02T03:04:05Z trailing' >/dev/null 2>&1; then
   fail "legacy deadline parser must reject multiple scalar tokens"
 fi
 
 grep -q 'CATALOG_CANARY_SSH_TARGET is required' "$DEPLOY_SH" ||
   fail "deploy must require a trusted canary host for exact installed-byte verification"
 
 grep -q 'StrictHostKeyChecking=yes' "$DEPLOY_SH" ||
   fail "trusted canary verification must check the SSH host key"
 
 ! grep -q '/usr/bin/proc_pidpath' "$DEPLOY_SH" ||
   fail "Mac canary proof must not depend on nonexistent /usr/bin/proc_pidpath"
 
 grep -q 'assigned_id=\$CANARY_ASSIGNED_QUERY&details=deployment' "$DEPLOY_SH" ||
   fail "deploy must gate completion on the exact proved provider session"
 
 proof_retry_line=$(grep -nF 'if run_catalog_canary_mac_proof "$CANARY_PROOF_TIMEOUT_S" > "$CANARY_INSTALLED_BODY"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 session_rebind_line=$(grep -nF 'read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY <<< "$CANARY_BINDING"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 session_query_line=$(grep -nF 'CANARY_STATUS=$(curl --config "$CANARY_CURL_CONFIG"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 [ -n "$proof_retry_line" ] && [ -n "$session_rebind_line" ] && [ -n "$session_query_line" ] &&
   [ "$proof_retry_line" -lt "$session_rebind_line" ] && [ "$session_rebind_line" -lt "$session_query_line" ] ||
   fail "each canary recovery attempt must re-prove the Mac and bind the query to that attempt's session"
 
 grep -q 'CANARY_RECOVERY_DEADLINE=' "$DEPLOY_SH" &&
   grep -q '_run_with_deadline_alarm "$timeout_s" "${CANARY_SSH\[@\]}"' "$DEPLOY_SH" &&
   grep -q 'rm -f "$CANARY_INSTALLED_BODY" "$CANARY_POOL_BODY"' "$DEPLOY_SH" &&
   grep -q 'waiting for exact catalog canary recovery' "$DEPLOY_SH" ||
   fail "deploy must retry full canary proof within a wall-clock deadline and discard stale attempt output"
 
 grep -q 'os.O_RDONLY | nofollow | nonblock' "$DEPLOY_SH" ||
   fail "Mac proof must open untrusted file entries without blocking on special files"
 
 grep -q 'value.get("assigned_id") != sys.argv\[3\]' "$DEPLOY_SH" ||
   fail "deploy must reject coordinator evidence for a different assigned session"
 
 grep -q 'local_status.get("network_state") != "buyer_serving"' "$DEPLOY_SH" ||
   fail "deploy must prove the canary Mac reports buyer-serving network state"
 
 grep -q 'value.get("buyer_serving") is not True' "$DEPLOY_SH" ||
   fail "deploy canary must require explicit buyer-serving capacity"
 
 grep -q 'value.get("catalog_evidence_source") != "provider_reported"' "$DEPLOY_SH" ||
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
   grep -q 'catalog.get("policy_version") != expected_policy_version' "$DEPLOY_SH" &&
   grep -q 'catalog.get("row_identity", "")' "$DEPLOY_SH" &&
   grep -q 'canary local catalog proof is not bound to the coordinator-admitted envelope' "$DEPLOY_SH" ||
   fail "deploy canary must cross-bind exact policy and row between coordinator and Mac proof"
 
 grep -q 'canary catalog byte mismatch' "$DEPLOY_SH" ||
   fail "deploy must compare exact installed canary catalog bytes before commit"
 
 grep -q 'canary provider identity mismatch' "$DEPLOY_SH" &&
   grep -q 'live canary provider text vnode is stale or not the verified installation binary' "$DEPLOY_SH" &&
   grep -q 'live canary provider status does not match the expected identity and catalog' "$DEPLOY_SH" ||
   fail "exact-byte proof must bind the named provider, live process, and local catalog status"
 
 grep -q 'O_NOFOLLOW' "$DEPLOY_SH" && grep -q 'dir_fd=' "$DEPLOY_SH" ||
   fail "trusted canary files must be opened no-follow through directory file descriptors"
 
 # SPEC-023 §3.7.8 Stage A (BYOM v0.2 slice 2b-ii): release.json decides whether
 # the artifact feed and its sidecar are members of the immutable envelope; a
 # bound release whose checkout lacks them aborts before upload, and when bound
 # they are content-addressed, digest-recorded, uploaded, and staged beside the
 # other feeds so verify-directory on Pearl sees the exact five-feed envelope.
 grep -q 'AUTOTUNE_ARTIFACT_BOUND="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST"' "$DEPLOY_SH" &&
   grep -q 'release.json binds autotune-artifacts.json but' "$DEPLOY_SH" ||
   fail "deploy must read artifact-feed binding from release.json and abort a bound release without the pair"
 grep -q '("autotune-artifacts.json", pathlib.Path(sys.argv\[10\]))' "$DEPLOY_SH" &&
   grep -q '("autotune-artifacts.json.sig", pathlib.Path(sys.argv\[11\]))' "$DEPLOY_SH" ||
   fail "deploy must content-address the artifact feed pair into the release envelope when bound"
 grep -q '_append_deploy_input_digest "$STATIC_ARTIFACTS_JSON" "autotune-artifacts.json"' "$DEPLOY_SH" &&
   grep -q '_append_deploy_input_digest "$STATIC_ARTIFACTS_SIG" "autotune-artifacts.json.sig"' "$DEPLOY_SH" ||
   fail "deploy must record the artifact feed pair in the deploy input manifest when bound"
 grep -q '$DEPLOY_TMP/autotune-artifacts.json \\$_autotune_stage/autotune-artifacts.json' "$DEPLOY_SH" &&
   grep -q '$DEPLOY_TMP/autotune-artifacts.json.sig \\$_autotune_stage/autotune-artifacts.json.sig' "$DEPLOY_SH" &&
   grep -q 'rate-card.json.sig$AUTOTUNE_ARTIFACT_INSTALL_LINES' "$DEPLOY_SH" ||
   fail "deploy must stage the artifact feed pair into the release envelope beside the other feeds when bound"
 
 grep -q '/v1/demand-rank' "$DEPLOY_SH" ||
   fail "deploy smoke must probe /v1/demand-rank"
 grep -q '/v1/rate-card.sig' "$DEPLOY_SH" ||
   fail "deploy smoke must probe /v1/rate-card.sig"
 
 grep -q 'chmod o+x /opt/macprovider' "$DEPLOY_SH" &&
   fail "deploy must not chmod o+x /opt/macprovider for legacy nginx static feeds"
 
 grep -q 'KEEP_DOWNLOADS=1 scripts/verify-tier2-provider-release.sh' "$CATALOG_RUNBOOK" &&
   grep -q 'prior provider live' "$CATALOG_RUNBOOK" &&
   grep -q 'MACPROVIDER_EMERGENCY_ROLLBACK=1' "$CATALOG_RUNBOOK" ||
   fail "catalog runbook must prefetch without mutation and document bounded emergency rollback"
 
 grep -qF '/usr/bin/security add-generic-password' "$CATALOG_RUNBOOK" &&
   grep -qF 'do not pass the token in argv' "$CATALOG_RUNBOOK" &&
   grep -qF '/usr/bin/stat -f %Lp "$CATALOG_CANARY_AUTH_TOKEN_FILE"' "$CATALOG_RUNBOOK" &&
   ! grep -qF -- '-w "$CATALOG_CANARY_AUTH_TOKEN"' "$CATALOG_RUNBOOK" ||
   fail "catalog runbook must provision stable canary secrets without PATH lookup or argv token exposure"
 
 grep -q 'PEARL_UPDATER_PROVIDER_ADMISSION_POLICY=bridge_required' "$PEARL_RUNBOOK" &&
   grep -q 'PEARL_UPDATER_MINIMUM_POOL_READY_AFTER_ROLLOUT=' "$PEARL_RUNBOOK" &&
   grep -q 'PEARL_UPDATER_MINIMUM_BRIDGE_REMAINING_S=' "$PEARL_RUNBOOK" &&
   ! grep -q 'proc_pidpath' "$PEARL_RUNBOOK" ||
   fail "Pearl rollout runbook must bind bridge capacity policy and valid Mac proof tooling"
 
 grep -q 'set -euo pipefail' "$CATALOG_RUNBOOK" &&
   grep -q 'legacy_bridge is not zero' "$CATALOG_RUNBOOK" &&
   grep -q 'test "$(wc -l <"$EVIDENCE")" -ge 31' "$CATALOG_RUNBOOK" ||
   fail "catalog runbook must provide fail-fast continuous zero-bridge evidence"
 
 echo "PASS: deploy autotune feed access guards present"

exec
/bin/bash -lc "git show origin/main:phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '4660,4740p'; git show origin/main:phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh | sed -n '1,220p'" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
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

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '650,690p;4380,4590p;4678,4734p'" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
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

exec
/bin/bash -lc "rg -n -C 3 'STATIC_(AUTOTUNE|DEMAND|RATE_CARD)|rate-card\\.json|demand-rank\\.json|autotune-candidates\\.json|tier2-catalog\\.json|release\\.json|trusted-keys\\.json' phase4-coordinator/dist/deploy-pearl-vps.sh" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
418-    root_label = f"{root_label}/{component}"
419-    root_fd = open_dir_at(root_fd, component, root_label)
420-
421:legacy_fd = open_file_at(root_fd, "tier2-catalog.json", f"{ROOT}/tier2-catalog.json", absent_ok=True)
422-if legacy_fd is None:
423-    sys.exit(0)
424-
--
464-release_fd = open_dir_at(releases_fd, release_name, f"{ROOT}/autotune/releases/{release_name}")
465-current_fd = open_file_at(
466-    release_fd,
467:    "tier2-catalog.json",
468:    f"{ROOT}/autotune/releases/{release_name}/tier2-catalog.json",
469-)
470-if not compare_fd(legacy_fd, current_fd):
471-    die("legacy Tier-2 catalog bytes differ from active autotune/current release")
--
667-# Files live in phase3-binary/dist/static/ in the repo. Deploy installs
668-# them into /opt/macprovider/autotune/ for coordinator startup load.
669-STATIC_FEEDS_DIR="$PINNED_STATIC_FEEDS_DIR"
670:STATIC_DEMAND_JSON="$STATIC_FEEDS_DIR/demand-rank.json"
671:STATIC_DEMAND_SIG="$STATIC_FEEDS_DIR/demand-rank.json.sig"
672:STATIC_AUTOTUNE_JSON="$STATIC_FEEDS_DIR/autotune-candidates.json"
673:STATIC_AUTOTUNE_SIG="$STATIC_FEEDS_DIR/autotune-candidates.json.sig"
674:STATIC_RATE_CARD_JSON="$STATIC_FEEDS_DIR/rate-card.json"
675:STATIC_RATE_CARD_SIG="$STATIC_FEEDS_DIR/rate-card.json.sig"
676-STATIC_ARTIFACTS_JSON="$STATIC_FEEDS_DIR/autotune-artifacts.json"
677-STATIC_ARTIFACTS_SIG="$STATIC_FEEDS_DIR/autotune-artifacts.json.sig"
678:AUTOTUNE_RELEASE_MANIFEST="$PINNED_AUTOTUNE_DIR/release.json"
679:AUTOTUNE_TRUSTED_KEYS="$PINNED_AUTOTUNE_DIR/trusted-keys.json"
680:AUTOTUNE_TIER2_JSON="$PINNED_AUTOTUNE_DIR/tier2-catalog.json"
681-AUTOTUNE_RELEASE_VERIFY="$PINNED_SCRIPTS_DIR/catalog-release.py"
682-AUTOTUNE_TIER2_VERIFIER="$PINNED_SCRIPTS_DIR/sign-catalog.go"
683-CATALOG_SOURCE="${CATALOG_SOURCE:-$AUTOTUNE_TIER2_JSON}"
--
699-    CATALOG_RELEASE_BASE_REF="$COORDINATOR_RELEASE_COMMIT^" \
700-    python3 -I "$PINNED_REPOSITORY_DIR/scripts/catalog-release.py" verify
701-fi
702:# SPEC-023 §3.7.8 Stage A: release.json decides whether the artifact feed and
703-# its sidecar are members of the immutable release envelope. verify-directory
704:# rejects a five-feed release.json beside nine files (and nine-file bytes
705-# beside a stray pair), so presence must follow the binding exactly, and a
706-# bound release whose feed is missing from the checkout aborts here.
707-AUTOTUNE_ARTIFACT_BOUND="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
--
714-AUTOTUNE_ARTIFACT_CONTENT_SIG=""
715-if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
716-  [ -f "$STATIC_ARTIFACTS_JSON" ] && [ -f "$STATIC_ARTIFACTS_SIG" ] || {
717:    echo "aborting deploy: release.json binds autotune-artifacts.json but $STATIC_FEEDS_DIR lacks the feed or its sidecar" >&2
718-    exit 1
719-  }
720-  AUTOTUNE_ARTIFACT_CONTENT_JSON="$STATIC_ARTIFACTS_JSON"
--
732-)"
733-AUTOTUNE_CANDIDATE_SHA256="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
734-import json, pathlib, sys
735:print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["autotune-candidates.json"]["sha256"])
736-PY
737-)"
738-AUTOTUNE_CANDIDATE_SIGNER_KEY_ID="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
739-import json, pathlib, sys
740:print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["autotune-candidates.json"]["signer_key_id"])
741-PY
742-)"
743-AUTOTUNE_TIER2_SHA256="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" <<'PY'
744-import json, pathlib, sys
745:print(json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]["tier2-catalog.json"]["sha256"])
746-PY
747-)"
748-AUTOTUNE_RELEASE_CONTENT_SHA256="$(python3 - \
749-  "$AUTOTUNE_RELEASE_MANIFEST" \
750-  "$AUTOTUNE_TRUSTED_KEYS" \
751-  "$AUTOTUNE_TIER2_JSON" \
752:  "$STATIC_AUTOTUNE_JSON" \
753:  "$STATIC_AUTOTUNE_SIG" \
754:  "$STATIC_DEMAND_JSON" \
755:  "$STATIC_DEMAND_SIG" \
756:  "$STATIC_RATE_CARD_JSON" \
757:  "$STATIC_RATE_CARD_SIG" \
758-  "$AUTOTUNE_ARTIFACT_CONTENT_JSON" \
759-  "$AUTOTUNE_ARTIFACT_CONTENT_SIG" <<'PY'
760-import hashlib
--
762-import sys
763-
764-assets = (
765:    ("release.json", pathlib.Path(sys.argv[1])),
766:    ("trusted-keys.json", pathlib.Path(sys.argv[2])),
767:    ("tier2-catalog.json", pathlib.Path(sys.argv[3])),
768:    ("autotune-candidates.json", pathlib.Path(sys.argv[4])),
769:    ("autotune-candidates.json.sig", pathlib.Path(sys.argv[5])),
770:    ("demand-rank.json", pathlib.Path(sys.argv[6])),
771:    ("demand-rank.json.sig", pathlib.Path(sys.argv[7])),
772:    ("rate-card.json", pathlib.Path(sys.argv[8])),
773:    ("rate-card.json.sig", pathlib.Path(sys.argv[9])),
774-)
775-# Artifact-bound release (SPEC-023 §3.7.8): the pair is part of the
776-# content-addressed envelope; both arguments are empty otherwise.
--
867-         "$STATS_BILLING_MIRROR_SERVICE" "$STATS_BILLING_MIRROR_TIMER" \
868-         "$STATS_HARDWARE_VERIFIER_SERVICE" "$STATS_HARDWARE_VERIFIER_TIMER" "$NGINX_SITE" \
869-         "$NGINX_STATS_SHARED" "$NGINX_STATS_SECHEADERS" "$NGINX_STATS_SITE" \
870:         "$STATIC_DEMAND_JSON" "$STATIC_DEMAND_SIG" \
871:         "$STATIC_AUTOTUNE_JSON" "$STATIC_AUTOTUNE_SIG" \
872:         "$STATIC_RATE_CARD_JSON" "$STATIC_RATE_CARD_SIG" \
873-         "$AUTOTUNE_RELEASE_MANIFEST" "$AUTOTUNE_TRUSTED_KEYS" "$AUTOTUNE_TIER2_JSON" \
874-         "$AUTOTUNE_RELEASE_VERIFY" "$AUTOTUNE_TIER2_VERIFIER"; do
875-  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
--
1337-if [ "$DRY_RUN_LOCAL" != "1" ]; then
1338-  log "step 0b/9: verify legacy Tier-2 migration bridge"
1339-  $SSH "$(_tier2_migration_gate_remote_script)" || {
1340:    echo "aborting deploy: legacy /opt/macprovider/tier2-catalog.json does not match active autotune/current release" >&2
1341-    exit 5
1342-  }
1343-fi
--
1651-# root stages signed bytes under immutable /opt/macprovider/autotune/releases/
1652-# and activation atomically switches root-owned autotune/current. The deploy
1653-# never writes Tier-2 through the current symlink or through the old independent
1654:# /opt/macprovider/tier2-catalog.json bridge.
1655:CATALOG_REMOTE_PATH_CANONICAL="/opt/macprovider/autotune/current/tier2-catalog.json"
1656-if [ -n "$CATALOG_REMOTE_PATH" ]; then
1657-  if [ "$CATALOG_REMOTE_PATH" != "$CATALOG_REMOTE_PATH_CANONICAL" ]; then
1658-    echo "aborting deploy: tier2.catalog_path must be exactly '$CATALOG_REMOTE_PATH_CANONICAL'" >&2
--
1670-  fi
1671-  if [ ! -f "$CATALOG_SOURCE" ]; then
1672-    echo "aborting deploy: configured tier2.catalog_path requires release-bound Tier-2 catalog artifact, missing: $CATALOG_SOURCE" >&2
1673:    echo "  Default source is $AUTOTUNE_TIER2_JSON; any override must match release.json." >&2
1674-    exit 5
1675-  fi
1676-  TMP_CATALOG_PUBKEY="$(mktemp)"
--
1681-  cp "$CATALOG_SOURCE" "$TMP_CATALOG_PINNED"
1682-  CATALOG_PIN_SHA="$(shasum -a 256 "$TMP_CATALOG_PINNED" | awk '{print $1}')"
1683-  if [ "$CATALOG_PIN_SHA" != "$AUTOTUNE_TIER2_SHA256" ]; then
1684:    echo "aborting deploy: Tier-2 source digest does not match release.json feed binding" >&2
1685:    echo "  source=$CATALOG_PIN_SHA release.json=$AUTOTUNE_TIER2_SHA256" >&2
1686-    exit 5
1687-  fi
1688-  if ! cmp -s "$TMP_CATALOG_PINNED" "$AUTOTUNE_TIER2_JSON"; then
--
1697-  # #608 Partial: refuse deploy when Tier-2 identity drifts from the autotune
1698-  # release about to be activated. Overlapping model_id rows must agree on
1699-  # artifact hash; Tier-2-only / autotune-only rows remain allowed for now.
1700:  if [ ! -f "$STATIC_AUTOTUNE_JSON" ]; then
1701:    echo "aborting deploy: cannot bind Tier-2 identity without $STATIC_AUTOTUNE_JSON" >&2
1702-    exit 5
1703-  fi
1704-  python3 "$AUTOTUNE_RELEASE_VERIFY" check-tier2-binding \
1705:    --candidate "$STATIC_AUTOTUNE_JSON" \
1706-    --tier2 "$TMP_CATALOG_PINNED" || {
1707-    echo "aborting deploy: Tier-2 catalog conflicts with autotune release identity (#608)" >&2
1708-    exit 5
--
3097-    cp -p /opt/macprovider/coordinator.yaml \"\$_rollback_stage/coordinator.yaml\"
3098-    touch \"\$_rollback_stage/had-config\"
3099-  fi
3100:  if [ -L /opt/macprovider/tier2-catalog.json ] || { [ -e /opt/macprovider/tier2-catalog.json ] && [ ! -f /opt/macprovider/tier2-catalog.json ]; }; then
3101-    echo 'unsafe existing Tier-2 catalog path' >&2
3102-    exit 1
3103-  fi
3104:  if [ -f /opt/macprovider/tier2-catalog.json ]; then
3105:    cp -p /opt/macprovider/tier2-catalog.json \"\$_rollback_stage/tier2-catalog.json\"
3106-    touch \"\$_rollback_stage/had-tier2-catalog\"
3107-  fi
3108-  if [ -e /etc/systemd/system/macprovider-coordinator.service ] || [ -L /etc/systemd/system/macprovider-coordinator.service ]; then
--
3267-  "$NGINX_STATS_PROXY_PUBLIC=nginx-stats-proxy-public.conf" \
3268-  "$NGINX_STATS_PROXY_PARTNER=nginx-stats-proxy-partner.conf" \
3269-  "$NGINX_STATS_SITE=nginx-stats.malibu.tech.conf" \
3270:  "$STATIC_DEMAND_JSON=demand-rank.json" \
3271:  "$STATIC_DEMAND_SIG=demand-rank.json.sig" \
3272:  "$STATIC_AUTOTUNE_JSON=autotune-candidates.json" \
3273:  "$STATIC_AUTOTUNE_SIG=autotune-candidates.json.sig" \
3274:  "$STATIC_RATE_CARD_JSON=rate-card.json" \
3275:  "$STATIC_RATE_CARD_SIG=rate-card.json.sig" \
3276:  "$AUTOTUNE_RELEASE_MANIFEST=release.json" \
3277-  "$AUTOTUNE_RELEASE_LEDGER=release-ledger.json" \
3278-  "$AUTOTUNE_TIER2_CONTENT_INDEX=tier2-content-index.json" \
3279:  "$AUTOTUNE_TRUSTED_KEYS=trusted-keys.json"; do
3280-  _append_deploy_input_digest "${_deploy_input%%=*}" "${_deploy_input#*=}"
3281-done
3282-for _bundle_path in $CATALOG_VERIFIER_BUNDLE; do
--
3287-  _append_deploy_input_digest "$STATIC_ARTIFACTS_SIG" "autotune-artifacts.json.sig"
3288-fi
3289-if [ -n "$CATALOG_REMOTE_PATH" ]; then
3290:  _append_deploy_input_digest "$TMP_CATALOG_PINNED" "tier2-catalog.json"
3291-  _append_deploy_input_digest "$TMP_CATALOG_PUBKEY" "tier2-catalog.pub"
3292-else
3293:  _append_deploy_input_digest "$AUTOTUNE_TIER2_JSON" "tier2-catalog.json"
3294-fi
3295-
3296-$SCP "$BINARY"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
--
3333-$SCP "$NGINX_STATS_PROXY_PARTNER" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-proxy-partner.conf"
3334-$SCP "$NGINX_STATS_SITE"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats.malibu.tech.conf"
3335-# SPEC-023 v1.7.3 signed static feeds
3336:$SCP "$STATIC_DEMAND_JSON"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json"
3337:$SCP "$STATIC_DEMAND_SIG"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json.sig"
3338:$SCP "$STATIC_AUTOTUNE_JSON"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-candidates.json"
3339:$SCP "$STATIC_AUTOTUNE_SIG"    "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-candidates.json.sig"
3340:$SCP "$STATIC_RATE_CARD_JSON"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/rate-card.json"
3341:$SCP "$STATIC_RATE_CARD_SIG"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/rate-card.json.sig"
3342-AUTOTUNE_ARTIFACT_INSTALL_LINES=""
3343-if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
3344-  $SCP "$STATIC_ARTIFACTS_JSON"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-artifacts.json"
--
3349-  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-artifacts.json \$_autotune_stage/autotune-artifacts.json
3350-  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-artifacts.json.sig \$_autotune_stage/autotune-artifacts.json.sig"
3351-fi
3352:$SCP "$AUTOTUNE_RELEASE_MANIFEST" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/release.json"
3353:$SCP "$AUTOTUNE_TRUSTED_KEYS"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/trusted-keys.json"
3354-$SCP "$AUTOTUNE_RELEASE_LEDGER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/release-ledger.json"
3355-$SCP "$AUTOTUNE_TIER2_CONTENT_INDEX" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-content-index.json"
3356:$SCP "$AUTOTUNE_TIER2_JSON"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.json"
3357-for _bundle_path in $CATALOG_VERIFIER_BUNDLE; do
3358-  $SCP "$PINNED_SCRIPTS_DIR/${_bundle_path#scripts/}" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/$_bundle_path"
3359-done
--
3367-    echo "aborting deploy: pinned Tier-2 catalog digest changed before upload ($UPLOAD_CATALOG_SHA != $CATALOG_PIN_SHA)" >&2
3368-    exit 5
3369-  fi
3370:  $SCP "$TMP_CATALOG_PINNED" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.json"
3371-  $SCP "$TMP_CATALOG_PUBKEY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.pub"
3372-fi
3373-$SCP "$DEPLOY_INPUT_MANIFEST_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/deploy-inputs.sha256"
--
3378-# mutation, so a verifier bundle that cannot verify on Pearl aborts early.
3379-# CATALOG_RELEASE_FILES must name exactly the files staged into
3380-# \$_autotune_stage below (deploy_catalog_verifier_closure.test.sh pins this).
3381:CATALOG_RELEASE_FILES="demand-rank.json demand-rank.json.sig autotune-candidates.json autotune-candidates.json.sig rate-card.json rate-card.json.sig tier2-catalog.json release.json trusted-keys.json"
3382-if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
3383-  CATALOG_RELEASE_FILES="$CATALOG_RELEASE_FILES autotune-artifacts.json autotune-artifacts.json.sig"
3384-fi
--
3652-  trap 'rm -rf \"\$_autotune_stage\"; rmdir \"\$_autotune_lock\" 2>/dev/null || true' EXIT
3653-  rm -rf \$_autotune_stage
3654-  install -d -o root -g macprovider -m 0750 \$_autotune_stage
3655:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json \$_autotune_stage/demand-rank.json
3656:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json.sig \$_autotune_stage/demand-rank.json.sig
3657:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json \$_autotune_stage/autotune-candidates.json
3658:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json.sig \$_autotune_stage/autotune-candidates.json.sig
3659:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json \$_autotune_stage/rate-card.json
3660:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json.sig \$_autotune_stage/rate-card.json.sig$AUTOTUNE_ARTIFACT_INSTALL_LINES
3661:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json
3662:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/release.json \$_autotune_stage/release.json
3663:  install -o root -g macprovider -m 0640 $DEPLOY_TMP/trusted-keys.json \$_autotune_stage/trusted-keys.json
3664-  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_stage --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
3665-  sync
3666-  if [ -e \$_autotune_release ]; then
--
4110-      echo \"autotune/current moved since compare-live (\$_current); re-run the deploy\" >&2
4111-      exit 1
4112-    }
4113:    rm -f /opt/macprovider/tier2-catalog.json
4114-    rm -rf $DEPLOY_TMP
4115-  " || { echo "aborting deploy: live catalog changed since compare-live or could not be pinned" >&2; exit 1; }
4116-  # Post-restart smokes and the canary prove the LIVE release, not the tag's.
--
4120-  # shellcheck disable=SC2086 # fixed release file names
4121-  $SSH "tar -C /opt/macprovider/autotune/$CATALOG_LIVE_TARGET -cf - $CATALOG_RELEASE_FILES" | tar -xf - -C "$CATALOG_LIVE_SNAPSHOT" ||
4122-    { echo "aborting deploy: could not snapshot the live catalog release" >&2; exit 1; }
4123:  STATIC_DEMAND_JSON="$CATALOG_LIVE_SNAPSHOT/demand-rank.json"
4124:  STATIC_DEMAND_SIG="$CATALOG_LIVE_SNAPSHOT/demand-rank.json.sig"
4125:  STATIC_AUTOTUNE_JSON="$CATALOG_LIVE_SNAPSHOT/autotune-candidates.json"
4126:  STATIC_AUTOTUNE_SIG="$CATALOG_LIVE_SNAPSHOT/autotune-candidates.json.sig"
4127:  STATIC_RATE_CARD_JSON="$CATALOG_LIVE_SNAPSHOT/rate-card.json"
4128:  STATIC_RATE_CARD_SIG="$CATALOG_LIVE_SNAPSHOT/rate-card.json.sig"
4129:  AUTOTUNE_RELEASE_MANIFEST="$CATALOG_LIVE_SNAPSHOT/release.json"
4130:  AUTOTUNE_TRUSTED_KEYS="$CATALOG_LIVE_SNAPSHOT/trusted-keys.json"
4131:  AUTOTUNE_TIER2_JSON="$CATALOG_LIVE_SNAPSHOT/tier2-catalog.json"
4132-  CATALOG_LIVE_IDENTITY="$(python3 - "$AUTOTUNE_RELEASE_MANIFEST" "$CATALOG_LIVE_RELEASE_ID" <<'PY'
4133-import json, pathlib, sys
4134-manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
4135-if manifest.get("release_id") != sys.argv[2]:
4136-    raise SystemExit("live catalog snapshot release_id differs from the compare-live verdict")
4137:feed = manifest["feeds"]["autotune-candidates.json"]
4138-print(manifest["release_id"], manifest["policy_version"], feed["sha256"], feed["signer_key_id"])
4139-PY
4140-)" || { echo "aborting deploy: live catalog snapshot does not match compare-live" >&2; exit 1; }
--
4173-  fi
4174-  ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME \"\$_catalog_root/current.next\"
4175-  mv -Tf \"\$_catalog_root/current.next\" \"\$_catalog_root/current\"
4176:  rm -f /opt/macprovider/tier2-catalog.json
4177-  rm -rf $DEPLOY_TMP
4178-" || { echo "aborting deploy: catalog activation failed or autotune/current moved since compare-live" >&2; exit 1; }
4179-fi
--
4267-# SPEC-023 signed recommendation feeds smoke (buyer mux via nginx).
4268-log "  verifying coordinator can read autotune feeds as macprovider"
4269-$SSH "set -e
4270:  sudo -u macprovider test -r /opt/macprovider/autotune/current/autotune-candidates.json
4271:  sudo -u macprovider test -r /opt/macprovider/autotune/current/demand-rank.json
4272:  sudo -u macprovider test -r /opt/macprovider/autotune/current/rate-card.json
4273-" || {
4274-  echo "aborting smoke: macprovider cannot read /opt/macprovider/autotune/*" >&2
4275-  exit 1
--
4279-  exit 1
4280-}
4281-for STATIC_SPEC in \
4282:    "/v1/rate-card|rate-card.json|$STATIC_RATE_CARD_JSON" \
4283:    "/v1/rate-card.sig|rate-card.json.sig|$STATIC_RATE_CARD_SIG" \
4284:    "/v1/demand-rank|demand-rank.json|$STATIC_DEMAND_JSON" \
4285:    "/v1/demand-rank.sig|demand-rank.json.sig|$STATIC_DEMAND_SIG" \
4286:    "/v1/autotune-candidates|autotune-candidates.json|$STATIC_AUTOTUNE_JSON" \
4287:    "/v1/autotune-candidates.sig|autotune-candidates.json.sig|$STATIC_AUTOTUNE_SIG"; do
4288-  STATIC_PATH="${STATIC_SPEC%%|*}"
4289-  STATIC_REST="${STATIC_SPEC#*|}"
4290-  STATIC_NAME="${STATIC_REST%%|*}"
--
4301-    exit 1
4302-  fi
4303-done
4304:cp "$AUTOTUNE_RELEASE_MANIFEST" "$STATIC_SMOKE_DIR/release.json"
4305:cp "$AUTOTUNE_TRUSTED_KEYS" "$STATIC_SMOKE_DIR/trusted-keys.json"
4306:cp "$AUTOTUNE_TIER2_JSON" "$STATIC_SMOKE_DIR/tier2-catalog.json"
4307:cp "$STATIC_RATE_CARD_JSON" "$STATIC_SMOKE_DIR/rate-card.json"
4308:cp "$STATIC_RATE_CARD_SIG" "$STATIC_SMOKE_DIR/rate-card.json.sig"
4309-python3 "$AUTOTUNE_RELEASE_VERIFY" verify-directory --directory "$STATIC_SMOKE_DIR"
4310-AUTOTUNE_STATUS_BODY="$STATIC_SMOKE_DIR/autotune-release-status.json"
4311-STATUS=$(curl -sS -o "$AUTOTUNE_STATUS_BODY" -w '%{http_code}' --max-time 10 --max-filesize 65536 "https://$DOMAIN/v1/autotune-release")
--
4560-        raise SystemExit("live canary provider status does not match the expected identity and catalog")
4561-
4562-    names = (
4563:        "release.json",
4564:        "trusted-keys.json",
4565:        "autotune-candidates.json",
4566:        "autotune-candidates.json.sig",
4567:        "demand-rank.json",
4568:        "demand-rank.json.sig",
4569:        "rate-card.json",
4570:        "rate-card.json.sig",
4571:        "tier2-catalog.json",
4572-    )
4573-    hashes = {}
4574-    for name in names:
--
4685-  "$CATALOG_CANARY_PROVIDER_ID" \
4686-  "$AUTOTUNE_RELEASE_MANIFEST" \
4687-  "$AUTOTUNE_TRUSTED_KEYS" \
4688:  "$STATIC_AUTOTUNE_JSON" \
4689:  "$STATIC_AUTOTUNE_SIG" \
4690:  "$STATIC_DEMAND_JSON" \
4691:  "$STATIC_DEMAND_SIG" \
4692:  "$STATIC_RATE_CARD_JSON" \
4693:  "$STATIC_RATE_CARD_SIG" \
4694-  "$AUTOTUNE_TIER2_JSON" <<'PY'
4695-import hashlib, json, pathlib, re, sys
4696-

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh | sed -n '430,515p'" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
   430	. "$deadline_parser_tmp"
   431	deadline='2030-01-02T03:04:05Z'
   432	[ "$(_parse_model_hash_legacy_until "  $deadline  ")" = "$deadline" ] ||
   433	  fail "legacy deadline parser must accept an unquoted scalar"
   434	[ "$(_parse_model_hash_legacy_until "  \"$deadline\"  ")" = "$deadline" ] ||
   435	  fail "legacy deadline parser must strip matching double quotes"
   436	[ "$(_parse_model_hash_legacy_until "  '$deadline'  ")" = "$deadline" ] ||
   437	  fail "legacy deadline parser must strip matching single quotes"
   438	[ -z "$(_parse_model_hash_legacy_until '   ')" ] ||
   439	  fail "legacy deadline parser must preserve an absent deadline as empty"
   440	if _parse_model_hash_legacy_until '2030-01-02T03:04:05Z trailing' >/dev/null 2>&1; then
   441	  fail "legacy deadline parser must reject multiple scalar tokens"
   442	fi
   443	
   444	grep -q 'CATALOG_CANARY_SSH_TARGET is required' "$DEPLOY_SH" ||
   445	  fail "deploy must require a trusted canary host for exact installed-byte verification"
   446	
   447	grep -q 'StrictHostKeyChecking=yes' "$DEPLOY_SH" ||
   448	  fail "trusted canary verification must check the SSH host key"
   449	
   450	! grep -q '/usr/bin/proc_pidpath' "$DEPLOY_SH" ||
   451	  fail "Mac canary proof must not depend on nonexistent /usr/bin/proc_pidpath"
   452	
   453	grep -q 'assigned_id=\$CANARY_ASSIGNED_QUERY&details=deployment' "$DEPLOY_SH" ||
   454	  fail "deploy must gate completion on the exact proved provider session"
   455	
   456	proof_retry_line=$(grep -nF 'if run_catalog_canary_mac_proof "$CANARY_PROOF_TIMEOUT_S" > "$CANARY_INSTALLED_BODY"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
   457	session_rebind_line=$(grep -nF 'read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY <<< "$CANARY_BINDING"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
   458	session_query_line=$(grep -nF 'CANARY_STATUS=$(curl --config "$CANARY_CURL_CONFIG"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
   459	[ -n "$proof_retry_line" ] && [ -n "$session_rebind_line" ] && [ -n "$session_query_line" ] &&
   460	  [ "$proof_retry_line" -lt "$session_rebind_line" ] && [ "$session_rebind_line" -lt "$session_query_line" ] ||
   461	  fail "each canary recovery attempt must re-prove the Mac and bind the query to that attempt's session"
   462	
   463	grep -q 'CANARY_RECOVERY_DEADLINE=' "$DEPLOY_SH" &&
   464	  grep -q '_run_with_deadline_alarm "$timeout_s" "${CANARY_SSH\[@\]}"' "$DEPLOY_SH" &&
   465	  grep -q 'rm -f "$CANARY_INSTALLED_BODY" "$CANARY_POOL_BODY"' "$DEPLOY_SH" &&
   466	  grep -q 'waiting for exact catalog canary recovery' "$DEPLOY_SH" ||
   467	  fail "deploy must retry full canary proof within a wall-clock deadline and discard stale attempt output"
   468	
   469	grep -q 'os.O_RDONLY | nofollow | nonblock' "$DEPLOY_SH" ||
   470	  fail "Mac proof must open untrusted file entries without blocking on special files"
   471	
   472	grep -q 'value.get("assigned_id") != sys.argv\[3\]' "$DEPLOY_SH" ||
   473	  fail "deploy must reject coordinator evidence for a different assigned session"
   474	
   475	grep -q 'local_status.get("network_state") != "buyer_serving"' "$DEPLOY_SH" ||
   476	  fail "deploy must prove the canary Mac reports buyer-serving network state"
   477	
   478	grep -q 'value.get("buyer_serving") is not True' "$DEPLOY_SH" ||
   479	  fail "deploy canary must require explicit buyer-serving capacity"
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

exec
/bin/bash -lc 'git diff --check origin/main...HEAD && git diff --name-status origin/main...HEAD' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
M	phase4-coordinator/dist/deploy-pearl-vps.sh
M	phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh

codex
The source trace shows the fix’s positional mapping is internally aligned: the proof hashes nine catalog basenames in order, and the post-loop checker now receives nine corresponding expected paths, with the two rate-card arguments inserted before Tier-2. The same static rate-card variables are used for release input hashing, upload/staging, smoke verification, and the final expected-byte check; I’m running the existing regression test to validate the repository’s intended guard.
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 4724ms:
/var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/tmp.wk8zXOV93n: line 1: 50068 Alarm clock: 14         python3 -c '
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
/bin/bash -lc "nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '720,790p;3200,3310p;3328,3388p;4040,4150p;4258,4320p'" in /Users/augstar/macprovider-canary-ratecard
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
  3200	    systemctl stop "$unit"
  3201	    active_state=$(systemctl show -p ActiveState --value "$unit")
  3202	    case "$active_state" in
  3203	      inactive|failed) ;;
  3204	      *) echo "sidecar unit did not stop: $unit state=$active_state" >&2; exit 1 ;;
  3205	    esac
  3206	  done
  3207	'
  3208	
  3209	# Issue #244 R5 SEC CRITICAL — stage uploaded artifacts into a fresh
  3210	# per-deploy root-owned 0700 directory instead of predictable /tmp/X
  3211	# names. Otherwise any local user (including a compromised macprovider
  3212	# UID) can race the SCP/install window and substitute their own
  3213	# systemd unit, binary, or nginx config — which root then installs.
  3214	# `mktemp -d` returns a fresh dir with mode 0700 owned by the SSH
  3215	# user (root). The wider /tmp permissions (1777) don't matter because
  3216	# the fresh subdir denies traversal.
  3217	DEPLOY_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-deploy.XXXXXXXX') || {
  3218	  echo "failed to create remote staging directory" >&2; exit 1;
  3219	}
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
  3301	if [ "$CONFIG_MODE" = "apply-tracked" ]; then
  3302	  $SCP "$CONFIG" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.yaml"
  3303	elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
  3304	  $SCP "$RATE_CARD_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.rate-card-migration.yaml"
  3305	elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
  3306	  $SCP "$C2_TIMER_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.c2-timer-migration.yaml"
  3307	else
  3308	  log "  CONFIG_MODE=preserve-live — not uploading tracked coordinator.yaml"
  3309	fi
  3310	if [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
  3328	# trip on missing zone names.).
  3329	$SCP "$NGINX_STATS_SHARED"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-shared.conf"
  3330	$SCP "$NGINX_STATS_SECHEADERS" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-security-headers.conf"
  3331	$SCP "$NGINX_STATS_CORS_429"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-cors-429.conf"
  3332	$SCP "$NGINX_STATS_PROXY_PUBLIC"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-proxy-public.conf"
  3333	$SCP "$NGINX_STATS_PROXY_PARTNER" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-proxy-partner.conf"
  3334	$SCP "$NGINX_STATS_SITE"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats.malibu.tech.conf"
  3335	# SPEC-023 v1.7.3 signed static feeds
  3336	$SCP "$STATIC_DEMAND_JSON"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json"
  3337	$SCP "$STATIC_DEMAND_SIG"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/demand-rank.json.sig"
  3338	$SCP "$STATIC_AUTOTUNE_JSON"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-candidates.json"
  3339	$SCP "$STATIC_AUTOTUNE_SIG"    "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-candidates.json.sig"
  3340	$SCP "$STATIC_RATE_CARD_JSON"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/rate-card.json"
  3341	$SCP "$STATIC_RATE_CARD_SIG"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/rate-card.json.sig"
  3342	AUTOTUNE_ARTIFACT_INSTALL_LINES=""
  3343	if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
  3344	  $SCP "$STATIC_ARTIFACTS_JSON"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-artifacts.json"
  3345	  $SCP "$STATIC_ARTIFACTS_SIG"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/autotune-artifacts.json.sig"
  3346	  # Staged into the immutable envelope beside the other feeds (remote script
  3347	  # below); the coordinator serves the pair only once its config names it.
  3348	  AUTOTUNE_ARTIFACT_INSTALL_LINES="
  3349	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-artifacts.json \$_autotune_stage/autotune-artifacts.json
  3350	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-artifacts.json.sig \$_autotune_stage/autotune-artifacts.json.sig"
  3351	fi
  3352	$SCP "$AUTOTUNE_RELEASE_MANIFEST" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/release.json"
  3353	$SCP "$AUTOTUNE_TRUSTED_KEYS"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/trusted-keys.json"
  3354	$SCP "$AUTOTUNE_RELEASE_LEDGER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/release-ledger.json"
  3355	$SCP "$AUTOTUNE_TIER2_CONTENT_INDEX" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-content-index.json"
  3356	$SCP "$AUTOTUNE_TIER2_JSON"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.json"
  3357	for _bundle_path in $CATALOG_VERIFIER_BUNDLE; do
  3358	  $SCP "$PINNED_SCRIPTS_DIR/${_bundle_path#scripts/}" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/$_bundle_path"
  3359	done
  3360	if [ -n "$CATALOG_REMOTE_PATH" ]; then
  3361	  if [ -z "${TMP_CATALOG_PINNED:-}" ] || [ ! -f "$TMP_CATALOG_PINNED" ]; then
  3362	    echo "aborting deploy: pinned Tier-2 catalog snapshot missing before upload" >&2
  3363	    exit 5
  3364	  fi
  3365	  UPLOAD_CATALOG_SHA="$(shasum -a 256 "$TMP_CATALOG_PINNED" | awk '{print $1}')"
  3366	  if [ "$UPLOAD_CATALOG_SHA" != "$CATALOG_PIN_SHA" ]; then
  3367	    echo "aborting deploy: pinned Tier-2 catalog digest changed before upload ($UPLOAD_CATALOG_SHA != $CATALOG_PIN_SHA)" >&2
  3368	    exit 5
  3369	  fi
  3370	  $SCP "$TMP_CATALOG_PINNED" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.json"
  3371	  $SCP "$TMP_CATALOG_PUBKEY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.pub"
  3372	fi
  3373	$SCP "$DEPLOY_INPUT_MANIFEST_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/deploy-inputs.sha256"
  3374	$SSH "cd $DEPLOY_TMP && shasum -a 256 -c deploy-inputs.sha256 >/dev/null"
  3375	echo "  staged deploy input digests OK"
  3376	# #1688: run the exact verify-directory the staging block below runs, over the
  3377	# same file set, before the config backup and any live config/release
  3378	# mutation, so a verifier bundle that cannot verify on Pearl aborts early.
  3379	# CATALOG_RELEASE_FILES must name exactly the files staged into
  3380	# \$_autotune_stage below (deploy_catalog_verifier_closure.test.sh pins this).
  3381	CATALOG_RELEASE_FILES="demand-rank.json demand-rank.json.sig autotune-candidates.json autotune-candidates.json.sig rate-card.json rate-card.json.sig tier2-catalog.json release.json trusted-keys.json"
  3382	if [ "$AUTOTUNE_ARTIFACT_BOUND" = "bound" ]; then
  3383	  CATALOG_RELEASE_FILES="$CATALOG_RELEASE_FILES autotune-artifacts.json autotune-artifacts.json.sig"
  3384	fi
  3385	if ! $SSH "set -e
  3386	  _preflight=$DEPLOY_TMP/catalog-preflight
  3387	  rm -rf \$_preflight
  3388	  install -d -m 0700 \$_preflight
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

exec
/bin/bash -lc "rg -n 'CATALOG_REMOTE_PATH|CATALOG_LIVE_SNAPSHOT|STATIC_FEEDS_DIR|PINNED_STATIC_FEEDS_DIR|PINNED_DEPLOY_INPUT_DIR' phase4-coordinator/dist/deploy-pearl-vps.sh" in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
525:PINNED_DEPLOY_INPUT_DIR=""
529:PINNED_STATIC_FEEDS_DIR="$DIST_DIR/../../phase3-binary/dist/static"
533:  PINNED_DEPLOY_INPUT_DIR="$(umask 077 && mktemp -d -t macprovider-deploy-inputs.XXXXXXXX)" || {
537:  trap 'rm -rf "${PINNED_DEPLOY_INPUT_DIR:-}"' EXIT HUP INT TERM
550:    | tar -xf - -C "$PINNED_DEPLOY_INPUT_DIR"
551:  PINNED_REPOSITORY_DIR="$PINNED_DEPLOY_INPUT_DIR/repository"
555:  PINNED_DIST_DIR="$PINNED_DEPLOY_INPUT_DIR/phase4-coordinator/dist"
560:  PINNED_RUNTIME_ARTIFACT_DIR="$PINNED_DEPLOY_INPUT_DIR/pearl-runtime-release"
568:  PINNED_STATIC_FEEDS_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/dist/static"
569:  PINNED_AUTOTUNE_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/catalog/autotune"
570:  PINNED_SCRIPTS_DIR="$PINNED_DEPLOY_INPUT_DIR/scripts"
669:STATIC_FEEDS_DIR="$PINNED_STATIC_FEEDS_DIR"
670:STATIC_DEMAND_JSON="$STATIC_FEEDS_DIR/demand-rank.json"
671:STATIC_DEMAND_SIG="$STATIC_FEEDS_DIR/demand-rank.json.sig"
672:STATIC_AUTOTUNE_JSON="$STATIC_FEEDS_DIR/autotune-candidates.json"
673:STATIC_AUTOTUNE_SIG="$STATIC_FEEDS_DIR/autotune-candidates.json.sig"
674:STATIC_RATE_CARD_JSON="$STATIC_FEEDS_DIR/rate-card.json"
675:STATIC_RATE_CARD_SIG="$STATIC_FEEDS_DIR/rate-card.json.sig"
676:STATIC_ARTIFACTS_JSON="$STATIC_FEEDS_DIR/autotune-artifacts.json"
677:STATIC_ARTIFACTS_SIG="$STATIC_FEEDS_DIR/autotune-artifacts.json.sig"
717:    echo "aborting deploy: release.json binds autotune-artifacts.json but $STATIC_FEEDS_DIR lacks the feed or its sidecar" >&2
808:  AUTOTUNE_TIER2_CONTENT_INDEX="$PINNED_DEPLOY_INPUT_DIR/tier2-content-index.json"
1145:# Earlier the trap was inside the `if [ -n "$CATALOG_REMOTE_PATH" ]`
1173:  rm -rf "${PINNED_DEPLOY_INPUT_DIR:-}"
1642:CATALOG_REMOTE_PATH="$(yaml_tier2_value catalog_path)"
1655:CATALOG_REMOTE_PATH_CANONICAL="/opt/macprovider/autotune/current/tier2-catalog.json"
1656:if [ -n "$CATALOG_REMOTE_PATH" ]; then
1657:  if [ "$CATALOG_REMOTE_PATH" != "$CATALOG_REMOTE_PATH_CANONICAL" ]; then
1658:    echo "aborting deploy: tier2.catalog_path must be exactly '$CATALOG_REMOTE_PATH_CANONICAL'" >&2
1659:    echo "  Got: '$CATALOG_REMOTE_PATH'." >&2
1710:  echo "  ok: pinned release-bound catalog sha256=$CATALOG_PIN_SHA verifies, binds to autotune release, and will activate at $CATALOG_REMOTE_PATH"
3289:if [ -n "$CATALOG_REMOTE_PATH" ]; then
3360:if [ -n "$CATALOG_REMOTE_PATH" ]; then
4117:  [ -n "$PINNED_DEPLOY_INPUT_DIR" ] || { echo "aborting deploy: no pinned input dir for the live catalog snapshot" >&2; exit 1; }
4118:  CATALOG_LIVE_SNAPSHOT="$PINNED_DEPLOY_INPUT_DIR/live-catalog"
4119:  mkdir -m 0700 "$CATALOG_LIVE_SNAPSHOT"
4121:  $SSH "tar -C /opt/macprovider/autotune/$CATALOG_LIVE_TARGET -cf - $CATALOG_RELEASE_FILES" | tar -xf - -C "$CATALOG_LIVE_SNAPSHOT" ||
4123:  STATIC_DEMAND_JSON="$CATALOG_LIVE_SNAPSHOT/demand-rank.json"
4124:  STATIC_DEMAND_SIG="$CATALOG_LIVE_SNAPSHOT/demand-rank.json.sig"
4125:  STATIC_AUTOTUNE_JSON="$CATALOG_LIVE_SNAPSHOT/autotune-candidates.json"
4126:  STATIC_AUTOTUNE_SIG="$CATALOG_LIVE_SNAPSHOT/autotune-candidates.json.sig"
4127:  STATIC_RATE_CARD_JSON="$CATALOG_LIVE_SNAPSHOT/rate-card.json"
4128:  STATIC_RATE_CARD_SIG="$CATALOG_LIVE_SNAPSHOT/rate-card.json.sig"
4129:  AUTOTUNE_RELEASE_MANIFEST="$CATALOG_LIVE_SNAPSHOT/release.json"
4130:  AUTOTUNE_TRUSTED_KEYS="$CATALOG_LIVE_SNAPSHOT/trusted-keys.json"
4131:  AUTOTUNE_TIER2_JSON="$CATALOG_LIVE_SNAPSHOT/tier2-catalog.json"
4237:if [ -n "$CATALOG_REMOTE_PATH" ]; then

exec
/bin/bash -lc 'git diff --unified=5 origin/main...HEAD -- phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-canary-ratecard
 succeeded in 0ms:
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
No findings. The CODE lane passes:

- `deploy-pearl-vps.sh:4562-4576` hashes nine files; `:4682-4694` supplies the matching nine expected paths. Rate-card JSON and signature precede Tier-2 correctly.
- The pinned rate-card paths are used consistently for upload, staging, release verification, smoke comparison, and final byte checking (`:3340-3341`, `:3659-3664`, `:4692-4693`).
- The regression test compares the proven and expected basename sets (`check_deploy_static_feed_access.test.sh:487-512`), catching future set divergence.
- Existing test passed with exit 0. No malformed payloads were constructed.

VERDICT: PASS
tokens used
71 660

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
