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
	cd phase4-coordinator && go test -tags=integration -timeout 10m ./internal/stats/... ./internal/onboarding/... ./cmd/coordinator/...

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
	bash scripts/test-production-exceptions.sh
	bash scripts/test-coordinator-advertised-version-test.sh
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
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_provider_prebeta_journey_result
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_journey_result_tools
	bash scripts/test-acceptance-candidate-metadata.sh
	bash scripts/test-acceptance-promotion.sh
	bash scripts/test-release-toolchain.sh
	bash scripts/test-release-publication-provenance.sh
	bash scripts/test-compatibility-set-manifest.sh
	bash scripts/test-compatibility-artifact-index.sh
	bash scripts/test-release-discovery-head.sh
	bash scripts/test-release-discovery-transport.sh
	bash scripts/test-renew-release-discovery-head.sh
	bash scripts/test-tier2-provider-artifact.sh
	bash scripts/test-tier2-provider-release.sh
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v ops/pearl-updater/test_pearl_updater.py
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v ops/pearl-updater/test_tier2_enforcement_watchdog.py
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v ops/pearl/config/test_pearl_config_reconcile.py
	bash scripts/test-tier2-enforcement-safety.sh
	bash ops/pearl-updater/test_transaction_gate_systemd.sh
	bash phase3-binary/dist/test/check_baked_static_feed_sync.test.sh
	bash scripts/test-catalog-release.sh
	bash -n phase4-coordinator/dist/deploy-pearl-vps.sh
	bash -n phase4-coordinator/dist/deploy-malibu-emission-pearl.sh
	bash -n phase4-coordinator/dist/deploy-opoi-v0-pearl.sh
	bash -n phase5-gateway/dist/deploy-pearl-vps.sh
	bash phase4-coordinator/dist/test/check_deploy_config_test.sh
	bash phase4-coordinator/dist/test/c2_timer_config_migration_test.sh
	bash phase4-coordinator/dist/test/coord_deploy_c2_precheck.test.sh
	bash phase4-coordinator/dist/test/check_nginx_receipt_buffers_test.sh
	bash phase4-coordinator/dist/test/check_nginx_api_perf_tuning_test.sh
	bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh
	bash phase4-coordinator/dist/test/check_nginx_stats_test.sh
	bash phase4-coordinator/dist/test/check_stats_inventory_deploy_test.sh
	bash phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
	bash phase4-coordinator/dist/test/coord_deploy_config_mode_test.sh
	bash phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh
	bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
	bash phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh
	bash phase4-coordinator/dist/test/coord_deploy_smoke_probe.test.sh
	bash phase4-coordinator/dist/test/check_pearl_tls_test.sh
	bash phase4-coordinator/dist/test/check_pearl_tcp_test.sh
	SPEC015_NGINX_LIVE_OPTIONAL=$${SPEC015_NGINX_LIVE_OPTIONAL:-1} bash phase4-coordinator/dist/test/check_nginx_receipt_header_live_test.sh
	MACPROVIDER_HTTP2_LIVE_OPTIONAL=$${MACPROVIDER_HTTP2_LIVE_OPTIONAL:-1} bash phase4-coordinator/dist/test/check_nginx_http2_live_test.sh
	bash scripts/test-install-config-token-preserve.sh
	bash scripts/test-install-provider-id-preserve.sh
	bash scripts/test-install-launchd-enable.sh
	bash scripts/test-install-version-pin.sh
	bash scripts/test-install-amfi-retry.sh
	bash phase3-binary/dist/test/install_referral_handoff.test.sh
	bash phase3-binary/dist/test/install_fresh_evidence.test.sh
	bash phase3-binary/dist/test/install_upgrade_evidence_rollback.test.sh
	bash phase3-binary/dist/test/install_lifecycle_state.test.sh
	bash phase3-binary/dist/test/install_transaction_lock.test.sh
	bash phase3-binary/dist/test/install_coordinator_admission.test.sh
	bash phase3-binary/dist/test/provider_upgrade_transaction.test.sh
	bash scripts/test-watchdog-inline-drift.sh
	bash phase3-binary/dist/test/watchdog_health_scope.test.sh
	bash phase3-binary/dist/test/watchdog_rollback_paths.test.sh
	bash ops/macprovider-watchdog/Scripts/test-ac-19-20-watchdog-recovery.sh
	node --test test/e2e/canary-buyer/probe.test.mjs test/e2e/canary-buyer/safety.test.mjs
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
