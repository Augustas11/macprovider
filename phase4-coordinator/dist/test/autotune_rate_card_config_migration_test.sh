#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE="$SCRIPT_DIR/../autotune-rate-card-config-migration.py"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$MIGRATE" ] || fail "migration helper is missing or not executable"

wd="$(mktemp -d)"
trap 'rm -rf "$wd"' EXIT

cat >"$wd/tracked.yaml" <<'YAML'
autotune:
  rate_card_path: /opt/macprovider/autotune/current/rate-card.json
  rate_card_sig_path: /opt/macprovider/autotune/current/rate-card.json.sig
  demand_rank_path: /opt/macprovider/autotune/current/demand-rank.json
  demand_rank_sig_path: /opt/macprovider/autotune/current/demand-rank.json.sig
  autotune_candidates_path: /opt/macprovider/autotune/current/autotune-candidates.json
  autotune_candidates_sig_path: /opt/macprovider/autotune/current/autotune-candidates.json.sig
YAML

cat >"$wd/live-two-feed.yaml" <<'YAML'
auth:
  operator_key: env:COORDINATOR_OPERATOR_KEY
autotune:
  demand_rank_path: /opt/macprovider/autotune/current/demand-rank.json
  demand_rank_sig_path: /opt/macprovider/autotune/current/demand-rank.json.sig
  autotune_candidates_path: /opt/macprovider/autotune/current/autotune-candidates.json
  autotune_candidates_sig_path: /opt/macprovider/autotune/current/autotune-candidates.json.sig
YAML

python3 "$MIGRATE" "$wd/live-two-feed.yaml" "$wd/tracked.yaml" >"$wd/migrated.yaml"
grep -q 'rate_card_path: /opt/macprovider/autotune/current/rate-card.json' "$wd/migrated.yaml" ||
  fail "base migration did not add rate_card_path"
grep -q 'rate_card_sig_path: /opt/macprovider/autotune/current/rate-card.json.sig' "$wd/migrated.yaml" ||
  fail "base migration did not add rate_card_sig_path"
grep -q 'operator_key: env:COORDINATOR_OPERATOR_KEY' "$wd/migrated.yaml" ||
  fail "base migration did not preserve unrelated raw config fields"

cat >"$wd/no-feed.yaml" <<'YAML'
autotune:
  enforce_provider_admission: true
YAML
python3 "$MIGRATE" "$wd/no-feed.yaml" "$wd/tracked.yaml" >"$wd/no-feed-out.yaml"
cmp -s "$wd/no-feed.yaml" "$wd/no-feed-out.yaml" ||
  fail "migration must not enable static feeds for a no-feed config"

cat >"$wd/overlay-two-feed.yaml" <<'YAML'
autotune:
  demand_rank_path: /opt/macprovider/autotune/current/demand-rank.json
  autotune_candidates_path: /opt/macprovider/autotune/current/autotune-candidates.json
YAML
python3 "$MIGRATE" --only-static-feed-overlays "$wd/overlay-two-feed.yaml" "$wd/tracked.yaml" >"$wd/overlay-migrated.yaml"
grep -q 'rate_card_path: /opt/macprovider/autotune/current/rate-card.json' "$wd/overlay-migrated.yaml" ||
  fail "overlay migration did not add rate_card_path for static-feed overlay"

cat >"$wd/unrelated-overlay.yaml" <<'YAML'
routing:
  request_timeout_s: 900
YAML
python3 "$MIGRATE" --only-static-feed-overlays "$wd/unrelated-overlay.yaml" "$wd/tracked.yaml" >"$wd/unrelated-overlay-out.yaml"
cmp -s "$wd/unrelated-overlay.yaml" "$wd/unrelated-overlay-out.yaml" ||
  fail "overlay migration must leave unrelated overlays unchanged"

cat >"$wd/conflicting-rate-card.yaml" <<'YAML'
autotune:
  rate_card_path: /tmp/rate-card.json
  demand_rank_path: /opt/macprovider/autotune/current/demand-rank.json
YAML
if python3 "$MIGRATE" "$wd/conflicting-rate-card.yaml" "$wd/tracked.yaml" >"$wd/rate-card-conflict.out" 2>&1; then
  fail "migration must reject existing non-canonical rate_card_path"
fi
grep -q 'refusing to rewrite existing autotune.rate_card_path' "$wd/rate-card-conflict.out" ||
  fail "conflict rejection did not name the existing rate_card_path"

echo "PASS: autotune rate-card config migration is field-scoped"
