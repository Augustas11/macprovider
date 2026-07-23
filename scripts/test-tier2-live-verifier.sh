#!/usr/bin/env bash
# Fixture-backed parser checks for scripts/verify-tier2-live.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="${TMPDIR:-/tmp}/tier2-live-verifier-test.$$"
mkdir -p "$TMP_ROOT"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf '[tier2-live-verifier-test] ERROR: %s\n' "$*" >&2
  exit 1
}

if ! grep -qF 'class NoRedirect' "$REPO_ROOT/scripts/verify-tier2-live.sh" ||
  ! grep -qF 'urllib.request.ProxyHandler({})' "$REPO_ROOT/scripts/verify-tier2-live.sh" ||
  ! grep -qF 'resp.read(MAX_RESPONSE_BYTES + 1)' "$REPO_ROOT/scripts/verify-tier2-live.sh"; then
  fail "live verifier must reject redirects, ambient proxies, and oversized responses"
fi

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    printf '%s\n' "--- $file ---" >&2
    cat "$file" >&2 || true
    fail "expected '$needle' in $file"
  fi
}

write_common() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/status.json" <<'JSON'
{"status":"up","degraded":false}
JSON
  cat >"$dir/healthz.json" <<'JSON'
{"status":"ok","pool_ready":1}
JSON
}

write_models() {
  local dir="$1"
  local mode="$2"
  case "$mode" in
    observe_all)
      cat >"$dir/models.json" <<'JSON'
{
  "data": [{"id":"mlx-community/test"}],
  "tier2": {
    "phase": 2,
    "model_hash": {
      "active": true,
      "state": "all",
      "require_verified": false,
      "catalog_configured": true,
      "catalog_available": true
    }
  }
}
JSON
      ;;
    encrypted_all)
      cat >"$dir/models.json" <<'JSON'
{
  "data": [{"id":"mlx-community/test"}],
  "tier1_disclosure": {
    "provider_leg_encryption": "all",
    "hardware_attestation": "unsupported",
    "tier2": {
      "encrypted_leg": {
        "state": "all",
        "encrypted_provider_count": 1,
        "unencrypted_provider_count": 0,
        "mixed": false,
        "scope": "coordinator_to_provider_only"
      },
      "attestation": {
        "state": "unsupported",
        "attested_provider_count": 0,
        "unsupported_provider_count": 1,
        "mixed": false
      }
    }
  },
  "tier2": {
    "phase": 2,
    "model_hash": {
      "active": true,
      "state": "all",
      "require_verified": true,
      "catalog_configured": true,
      "catalog_available": true
    },
    "encrypted_leg": {
      "state": "all",
      "encrypted_provider_count": 1,
      "unencrypted_provider_count": 0,
      "mixed": false,
      "scope": "coordinator_to_provider_only"
    },
    "attestation": {
      "state": "unsupported",
      "attested_provider_count": 0,
      "unsupported_provider_count": 1,
      "mixed": false
    }
  }
}
JSON
      ;;
    encrypted_partial)
      cat >"$dir/models.json" <<'JSON'
{
  "data": [{"id":"mlx-community/test"}],
  "tier1_disclosure": {
    "provider_leg_encryption": "partial",
    "hardware_attestation": "unsupported"
  },
  "tier2": {
    "phase": 2,
    "model_hash": {
      "active": true,
      "state": "all",
      "require_verified": true,
      "catalog_configured": true,
      "catalog_available": true
    },
    "encrypted_leg": {
      "state": "partial",
      "encrypted_provider_count": 1,
      "unencrypted_provider_count": 1,
      "mixed": true,
      "scope": "coordinator_to_provider_only"
    },
    "attestation": {
      "state": "unsupported",
      "attested_provider_count": 0,
      "unsupported_provider_count": 2,
      "mixed": false
    }
  }
}
JSON
      ;;
    attested_all)
      cat >"$dir/models.json" <<'JSON'
{
  "data": [{"id":"mlx-community/test"}],
  "tier1_disclosure": {
    "provider_leg_encryption": "all",
    "hardware_attestation": "all",
    "tier2": {
      "encrypted_leg": {
        "state": "all",
        "encrypted_provider_count": 1,
        "unencrypted_provider_count": 0,
        "mixed": false,
        "scope": "coordinator_to_provider_only"
      },
      "attestation": {
        "state": "all",
        "attested_provider_count": 1,
        "unsupported_provider_count": 0,
        "mixed": false
      }
    }
  },
  "tier2": {
    "phase": 2,
    "model_hash": {
      "active": true,
      "state": "all",
      "require_verified": true,
      "catalog_configured": true,
      "catalog_available": true
    },
    "encrypted_leg": {
      "state": "all",
      "encrypted_provider_count": 1,
      "unencrypted_provider_count": 0,
      "mixed": false,
      "scope": "coordinator_to_provider_only"
    },
    "attestation": {
      "state": "all",
      "attested_provider_count": 1,
      "unsupported_provider_count": 0,
      "mixed": false
    }
  }
}
JSON
      ;;
    attested_partial)
      cat >"$dir/models.json" <<'JSON'
{
  "data": [{"id":"mlx-community/test"}],
  "tier1_disclosure": {
    "provider_leg_encryption": "all",
    "hardware_attestation": "partial"
  },
  "tier2": {
    "phase": 2,
    "model_hash": {
      "active": true,
      "state": "all",
      "require_verified": true,
      "catalog_configured": true,
      "catalog_available": true
    },
    "encrypted_leg": {
      "state": "all",
      "encrypted_provider_count": 1,
      "unencrypted_provider_count": 0,
      "mixed": false,
      "scope": "coordinator_to_provider_only"
    },
    "attestation": {
      "state": "partial",
      "attested_provider_count": 1,
      "unsupported_provider_count": 1,
      "mixed": true
    }
  }
}
JSON
      ;;
    *)
      fail "unknown models fixture mode: $mode"
      ;;
  esac
}

write_poolz() {
  local dir="$1"
  local mode="$2"
  case "$mode" in
    encrypted)
      cat >"$dir/poolz.json" <<'JSON'
{"pool":[{"provider_id":"encrypted","model_id":"mlx-community/test","binary_version":"1.2.6","state":"ready","slots_free":1,"routing_eligible":true,"hash_status":"hash_verified","model_hash_algorithm":"macprovider.snapshot-manifest.v1","model_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","encrypted_leg":true,"attestation_status":"unsupported"}]}
JSON
      ;;
    encrypted_old)
      cat >"$dir/poolz.json" <<'JSON'
{"pool":[{"provider_id":"encrypted-old","model_id":"mlx-community/test","binary_version":"1.2.5","state":"ready","slots_free":1,"routing_eligible":true,"hash_status":"hash_verified","model_hash_algorithm":"macprovider.snapshot-manifest.v1","model_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","encrypted_leg":true,"attestation_status":"unsupported"}]}
JSON
      ;;
    plain)
      cat >"$dir/poolz.json" <<'JSON'
{"pool":[{"provider_id":"plain","model_id":"mlx-community/test","binary_version":"1.2.6","state":"ready","slots_free":1,"routing_eligible":true,"hash_status":"hash_verified","model_hash_algorithm":"macprovider.snapshot-manifest.v1","model_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","encrypted_leg":false,"attestation_status":"unsupported"}]}
JSON
      ;;
    attested)
      cat >"$dir/poolz.json" <<'JSON'
{"pool":[{"provider_id":"attested","model_id":"mlx-community/test","binary_version":"1.2.6","state":"ready","slots_free":1,"routing_eligible":true,"hash_status":"hash_verified","model_hash_algorithm":"macprovider.snapshot-manifest.v1","model_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","encrypted_leg":true,"attestation_status":"attested"}]}
JSON
      ;;
    unsupported)
      cat >"$dir/poolz.json" <<'JSON'
{"pool":[{"provider_id":"unsupported","model_id":"mlx-community/test","binary_version":"1.2.6","state":"ready","slots_free":1,"routing_eligible":true,"hash_status":"hash_verified","model_hash_algorithm":"macprovider.snapshot-manifest.v1","model_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","encrypted_leg":true,"attestation_status":"unsupported"}]}
JSON
      ;;
    missing_algorithm)
      cat >"$dir/poolz.json" <<'JSON'
{"pool":[{"provider_id":"missing-algorithm","model_id":"mlx-community/test","binary_version":"1.8.60","state":"ready","slots_free":1,"routing_eligible":true,"hash_status":"hash_verified","model_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
JSON
      ;;
    malformed_hash)
      cat >"$dir/poolz.json" <<'JSON'
{"pool":[{"provider_id":"malformed-hash","model_id":"mlx-community/test","binary_version":"1.8.60","state":"ready","slots_free":1,"routing_eligible":true,"hash_status":"hash_verified","model_hash_algorithm":"macprovider.snapshot-manifest.v1","model_hash":"abc123"}]}
JSON
      ;;
    not_routable)
      cat >"$dir/poolz.json" <<'JSON'
{"pool":[{"provider_id":"not-routable","model_id":"mlx-community/test","binary_version":"1.8.60","state":"ready","slots_free":1,"routing_eligible":false,"hash_status":"hash_verified","model_hash_algorithm":"macprovider.snapshot-manifest.v1","model_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
JSON
      ;;
    *)
      fail "unknown pool fixture mode: $mode"
      ;;
  esac
}

make_fixture() {
  local name="$1"
  local models_mode="$2"
  local pool_mode="$3"
  local dir="$TMP_ROOT/$name"
  write_common "$dir"
  write_models "$dir" "$models_mode"
  write_poolz "$dir" "$pool_mode"
  printf '%s\n' "$dir"
}

run_verify() {
  local dir="$1"
  local mode="$2"
  VERIFY_TIER2_FIXTURES="$dir" "$REPO_ROOT/scripts/verify-tier2-live.sh" "$mode"
}

encrypted_ok="$(make_fixture encrypted-ok encrypted_all encrypted)"
run_verify "$encrypted_ok" --b6-ready >"$TMP_ROOT/b6-ready-ok.out"
assert_contains "$TMP_ROOT/b6-ready-ok.out" '"mode": "b6-ready"'
assert_contains "$TMP_ROOT/b6-ready-ok.out" '"ready_b6_provider_count": 1'

run_verify "$encrypted_ok" --encrypted-leg >"$TMP_ROOT/encrypted-ok.out"
assert_contains "$TMP_ROOT/encrypted-ok.out" '"provider_leg_encryption": "all"'
assert_contains "$TMP_ROOT/encrypted-ok.out" '"ready_encrypted_provider_count": 1'

run_verify "$encrypted_ok" --enforced >"$TMP_ROOT/enforced-ok.out"
assert_contains "$TMP_ROOT/enforced-ok.out" '"mode": "enforced"'
assert_contains "$TMP_ROOT/enforced-ok.out" '"snapshot_manifest_provider_count": 1'

enforce_ready_ok="$(make_fixture enforce-ready-ok observe_all encrypted)"
run_verify "$enforce_ready_ok" --enforce-ready >"$TMP_ROOT/enforce-ready-ok.out"
assert_contains "$TMP_ROOT/enforce-ready-ok.out" '"mode": "enforce-ready"'
assert_contains "$TMP_ROOT/enforce-ready-ok.out" '"require_verified": false'

missing_algorithm="$(make_fixture missing-algorithm encrypted_all missing_algorithm)"
if run_verify "$missing_algorithm" --enforced >"$TMP_ROOT/missing-algorithm.out" 2>"$TMP_ROOT/missing-algorithm.err"; then
  fail "expected enforced verification to reject a missing snapshot algorithm"
fi
assert_contains "$TMP_ROOT/missing-algorithm.err" "snapshot-manifest"

malformed_hash="$(make_fixture malformed-hash encrypted_all malformed_hash)"
if run_verify "$malformed_hash" --enforced >"$TMP_ROOT/malformed-hash.out" 2>"$TMP_ROOT/malformed-hash.err"; then
  fail "expected enforced verification to reject a malformed model hash"
fi
assert_contains "$TMP_ROOT/malformed-hash.err" "snapshot-manifest"

not_routable="$(make_fixture not-routable encrypted_all not_routable)"
if run_verify "$not_routable" --enforced >"$TMP_ROOT/not-routable.out" 2>"$TMP_ROOT/not-routable.err"; then
  fail "expected enforced verification to reject a non-routable provider"
fi
assert_contains "$TMP_ROOT/not-routable.err" "buyer-routable"

encrypted_disclosure_bad="$(make_fixture encrypted-disclosure-bad encrypted_partial encrypted)"
if run_verify "$encrypted_disclosure_bad" --b6-ready >"$TMP_ROOT/b6-disclosure-bad.out" 2>"$TMP_ROOT/b6-disclosure-bad.err"; then
  fail "expected B6 readiness disclosure failure"
fi
assert_contains "$TMP_ROOT/b6-disclosure-bad.err" "provider_leg_encryption"

if run_verify "$encrypted_disclosure_bad" --encrypted-leg >"$TMP_ROOT/encrypted-disclosure-bad.out" 2>"$TMP_ROOT/encrypted-disclosure-bad.err"; then
  fail "expected encrypted-leg disclosure failure"
fi
assert_contains "$TMP_ROOT/encrypted-disclosure-bad.err" "provider_leg_encryption"

encrypted_old="$(make_fixture encrypted-old encrypted_all encrypted_old)"
if run_verify "$encrypted_old" --b6-ready >"$TMP_ROOT/b6-old.out" 2>"$TMP_ROOT/b6-old.err"; then
  fail "expected B6 readiness old-provider failure"
fi
assert_contains "$TMP_ROOT/b6-old.err" "below v1.2.6"

encrypted_pool_bad="$(make_fixture encrypted-pool-bad encrypted_all plain)"
if run_verify "$encrypted_pool_bad" --encrypted-leg >"$TMP_ROOT/encrypted-pool-bad.out" 2>"$TMP_ROOT/encrypted-pool-bad.err"; then
  fail "expected encrypted-leg pool failure"
fi
assert_contains "$TMP_ROOT/encrypted-pool-bad.err" "missing encrypted_leg=true"

attested_ok="$(make_fixture attested-ok attested_all attested)"
run_verify "$attested_ok" --attested >"$TMP_ROOT/attested-ok.out"
assert_contains "$TMP_ROOT/attested-ok.out" '"hardware_attestation": "all"'
assert_contains "$TMP_ROOT/attested-ok.out" '"ready_attested_provider_count": 1'

attested_disclosure_bad="$(make_fixture attested-disclosure-bad attested_partial attested)"
if run_verify "$attested_disclosure_bad" --attested >"$TMP_ROOT/attested-disclosure-bad.out" 2>"$TMP_ROOT/attested-disclosure-bad.err"; then
  fail "expected attested disclosure failure"
fi
assert_contains "$TMP_ROOT/attested-disclosure-bad.err" "hardware_attestation"

attested_pool_bad="$(make_fixture attested-pool-bad attested_all unsupported)"
if run_verify "$attested_pool_bad" --attested >"$TMP_ROOT/attested-pool-bad.out" 2>"$TMP_ROOT/attested-pool-bad.err"; then
  fail "expected attested pool failure"
fi
assert_contains "$TMP_ROOT/attested-pool-bad.err" "not encrypted+attested"

printf '[tier2-live-verifier-test] ok\n'
