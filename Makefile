# Root Makefile — one entry point for both Go services.
#
# Contributors: `make test` runs every Go test in the repo. `make vet` is
# the same for static checks. Per the 2026-06-10 audit (DEVE-6 / DOCS-8):
# keep CI and local on the same targets. CI jobs use the per-service
# targets below to preserve parallel jobs and failure isolation.

.PHONY: test test-coordinator test-coordinator-integration test-gateway test-integration test-dist \
        vet vet-coordinator vet-gateway \
        lint-coordinator \
        build-linux check check-exceptions fmt verify-autotune-catalog

test: test-coordinator test-gateway test-integration test-dist

verify-autotune-catalog:
	python3 scripts/catalog-release.py verify

test-coordinator:
	cd phase4-coordinator && go test ./...

# SPEC-017 Step 1 and provider-onboarding Postgres integration tests.
# Tagged with `integration` so
# `make test-coordinator` does NOT require a Docker daemon.
# CI runs this as a separate job that provides the daemon.
# Each stats case owns an isolated Postgres container; keep the package
# deadline above the observed hosted-runner setup/teardown envelope.
test-coordinator-integration:
	cd phase4-coordinator && go test -tags=integration -timeout 10m ./internal/stats/... ./internal/onboarding/... ./internal/rewards/... ./cmd/coordinator/...

# SPEC-017 AC-16 — golangci-lint with depguard + forbidigo.
# Pinned version so the target is hermetic on a fresh checkout.
lint-coordinator:
	@command -v golangci-lint >/dev/null 2>&1 || { \
		echo "golangci-lint not found; install: go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2"; \
		exit 1; \
	}
	cd phase4-coordinator && golangci-lint run --config=.golangci.yml ./...

test-gateway:
	cd phase5-gateway && go test ./...

# Cross-service integration harness (M2-9 / M3-11 / TEST-6 close-out).
# Builds the coordinator + gateway binaries and drives the real
# gateway↔coordinator boundary; the within-gateway integration_test.go
# mocks the coordinator via httptest, so this is the only suite that
# can catch a regression in the sticky-header forwarding contract or
# the M3-2 internalBearerAuthorized dual-credential gate.
test-integration:
	cd test/integration && go test -race -count=1 -timeout 5m ./...

# Deploy-tooling tests (bash + python3, no Go build). Guards the fail-closed
# pre-deploy gate in phase4-coordinator/dist/check-deploy-config.sh — notably
# that an env:NAME-indirected secret is deferred to runtime rather than
# false-failing the gate (the 2026-06-17 regression that forced SKIP_C2_CHECK=1).
test-dist:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_upstream_watch
	node --test phase3-binary/app/Tests/MalibuTests/payout-signer-chain.test.mjs
	bash scripts/test-production-exceptions.sh
	bash scripts/test-coordinator-advertised-version-test.sh
	bash scripts/test-cli-se-entitlements.sh
	bash scripts/test-malibu-independent-release.sh
	bash scripts/test-release-tag-target.sh
	bash scripts/test-pearl-runtime-release.sh
	bash scripts/test-live-coordinator-release-gate.sh
	bash scripts/test-release-security-posture.sh
	bash scripts/test-malibu-bootstrap-bridge.sh
	bash scripts/test-recover-malibu-publication.sh
	bash scripts/test-acceptance-candidate-security.sh
	bash scripts/test-signed-payout-journey-workflow.sh
	bash scripts/test-signed-provider-prebeta-journey-workflow.sh
	bash scripts/test-signed-buyer-paid-path-journey-workflow.sh
	bash scripts/test-signed-buyer-crash-recovery-journey-workflow.sh
	bash scripts/test-signed-buyer-enforce-journey-workflow.sh
	bash scripts/test-signed-local-consumer-endpoint-journey-workflow.sh
	bash scripts/test-signed-trusted-pool-creator-mvp-journey-workflow.sh
	bash scripts/test-signed-trusted-pool-layer2-journey-workflow.sh
	bash scripts/test-signed-pool-promotion-transition-workflow.sh
	bash scripts/test-spec043-production-release-key-provision.sh
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_provider_prebeta_journey_result
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_buyer_paid_path_journey_result
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_buyer_crash_recovery_journey_result
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_buyer_enforce_journey_result
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_local_consumer_endpoint_evidence_capture
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_local_consumer_endpoint_journey_result
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_trusted_pool_creator_mvp_journey_result
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_trusted_pool_layer2_journey_result
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_pool_promotion_transition
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_pool_rejection_timing_floor
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_journey_result_tools
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_provider_prebeta_payout_posture
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_malibu_fleet_ledger
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_openrouter_mlx_candidates
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_openrouter_pricing_engine
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_openrouter_pricing_receipt
	bash scripts/test-acceptance-candidate-metadata.sh
	bash scripts/test-acceptance-promotion.sh
	bash scripts/test-release-toolchain.sh
	bash scripts/test-release-publication-provenance.sh
	bash scripts/test-compatibility-set-manifest.sh
	bash scripts/test-compatibility-artifact-index.sh
	bash scripts/test-agent-onboarding-skill.sh
	bash scripts/test-agent-onboarding-publication.sh
	bash scripts/test-release-discovery-head.sh
	bash scripts/test-release-discovery-transport.sh
	bash scripts/test-select-public-discovery-transport.sh
	bash scripts/test-renew-release-discovery-head.sh
	bash scripts/test-tier2-provider-artifact.sh
	bash scripts/test-tier2-provider-release.sh
	bash scripts/test-tier2-activation-safety.sh
	bash scripts/test-tier2-attestation-safety.sh
	bash scripts/test-tier2-behavioral-safety.sh
	bash scripts/test-tier2-encrypted-leg-safety.sh
	bash scripts/test-tier2-live-verifier.sh
	bash scripts/test-tier2-mda-artifact.sh
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v ops/pearl-updater/test_pearl_updater.py
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v ops/pearl-updater/test_tier2_enforcement_watchdog.py
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v ops/pearl/config/test_pearl_config_reconcile.py
	bash scripts/test-tier2-enforcement-safety.sh
	bash ops/pearl-updater/test_transaction_gate_systemd.sh
	bash phase3-binary/dist/test/check_baked_static_feed_sync.test.sh
	bash phase3-binary/dist/test/install_python3_clt_guard.test.sh
	bash phase3-binary/dist/test/install_1286_fresh_mac_e2e.test.sh
	bash scripts/test-catalog-release.sh
	bash scripts/test-autotune-gate-matrix.sh
	bash -n phase4-coordinator/dist/deploy-pearl-vps.sh
	bash -n phase4-coordinator/dist/deploy-malibu-emission-pearl.sh
	bash -n phase4-coordinator/dist/deploy-opoi-v0-pearl.sh
	bash -n phase5-gateway/dist/deploy-pearl-vps.sh
	bash phase4-coordinator/dist/test/check_deploy_config_test.sh
	bash phase4-coordinator/dist/test/c2_timer_config_migration_test.sh
	bash phase4-coordinator/dist/test/autotune_rate_card_config_migration_test.sh
	bash phase4-coordinator/dist/test/coord_deploy_c2_precheck.test.sh
	bash phase4-coordinator/dist/test/check_nginx_receipt_buffers_test.sh
	bash phase4-coordinator/dist/test/check_nginx_api_perf_tuning_test.sh
	bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh
	bash phase4-coordinator/dist/test/check_nginx_stats_test.sh
	bash phase4-coordinator/dist/test/check_nginx_mdm_enroll_routes_test.sh
	bash phase4-coordinator/dist/test/check_nginx_referral_routes_test.sh
	bash phase4-coordinator/dist/test/check_stats_inventory_deploy_test.sh
	bash phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
	bash phase4-coordinator/dist/test/coord_deploy_config_mode_test.sh
	bash phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh
	bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
	bash phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh
	bash phase4-coordinator/dist/test/coord_deploy_smoke_probe.test.sh
	bash phase4-coordinator/dist/test/coord_deploy_drift_redact.test.sh
	bash phase4-coordinator/dist/test/coord_deploy_tier2_migration_gate.test.sh
	bash phase4-coordinator/dist/test/check_monitor_email_mute_test.sh
	bash phase4-coordinator/dist/test/check_monitor_sandbox_test.sh
	bash phase4-coordinator/dist/test/check_pearl_tls_test.sh
	bash phase4-coordinator/dist/test/check_pearl_tcp_test.sh
	SPEC015_NGINX_LIVE_OPTIONAL=$${SPEC015_NGINX_LIVE_OPTIONAL:-1} bash phase4-coordinator/dist/test/check_nginx_receipt_header_live_test.sh
	MACPROVIDER_HTTP2_LIVE_OPTIONAL=$${MACPROVIDER_HTTP2_LIVE_OPTIONAL:-1} bash phase4-coordinator/dist/test/check_nginx_http2_live_test.sh
	bash scripts/test-install-config-token-preserve.sh
	bash scripts/test-install-provider-id-preserve.sh
	bash scripts/test-install-launchd-enable.sh
	bash scripts/test-install-version-pin.sh
	bash scripts/test-install-amfi-retry.sh
	bash scripts/test-install-autotune-recommend-config.sh
	bash phase3-binary/dist/test/install_referral_handoff.test.sh
	bash phase3-binary/dist/test/install_fresh_evidence.test.sh
	bash phase3-binary/dist/test/install_upgrade_evidence_rollback.test.sh
	bash phase3-binary/dist/test/install_launchd_migration.test.sh
	bash phase3-binary/dist/test/install_lifecycle_state.test.sh
	bash phase3-binary/dist/test/install_transaction_lock.test.sh
	bash phase3-binary/dist/test/install_coordinator_admission.test.sh
	bash phase3-binary/dist/test/provider_upgrade_transaction.test.sh
	bash phase3-binary/dist/test/install_bundled_repair.test.sh
	bash phase3-binary/dist/test/install_headless_fleet.test.sh
	bash phase3-binary/dist/test/install_port_validation.test.sh
	bash phase3-binary/dist/test/install_prefix.test.sh
	bash phase3-binary/dist/test/uninstall_path_safety.test.sh
	bash scripts/test-watchdog-inline-drift.sh
	bash phase3-binary/dist/test/watchdog_health_scope.test.sh
	bash phase3-binary/dist/test/watchdog_rollback_paths.test.sh
	bash ops/macprovider-watchdog/Scripts/test-ac-19-20-watchdog-recovery.sh
	node --test test/e2e/canary-buyer/probe.test.mjs test/e2e/canary-buyer/safety.test.mjs
	node --test frontdoor/provider-portal/mining-health.test.mjs
	bash test/e2e/canary-buyer/run-canary.test.sh
	PYTHONDONTWRITEBYTECODE=1 python3 test/e2e/aead-rekey-oneshot/test_aead_rekey_oneshot.py

vet: vet-coordinator vet-gateway vet-integration

vet-coordinator:
	cd phase4-coordinator && go vet ./...

vet-gateway:
	cd phase5-gateway && go vet ./...

vet-integration:
	cd test/integration && go vet ./...

build-linux:
	phase4-coordinator/scripts/build-linux.sh
	phase5-gateway/scripts/build-linux.sh

check-exceptions:
	python3 scripts/check-production-exceptions.py validate
	python3 scripts/check-production-exceptions.py report

check: check-exceptions
	phase4-coordinator/dist/check-deploy-config.sh \
		phase4-coordinator/dist/coordinator.yaml \
		phase5-gateway/dist/gateway.yaml

fmt:
	cd phase4-coordinator && gofmt -w .
	cd phase5-gateway && gofmt -w .
