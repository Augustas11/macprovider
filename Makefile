# Root Makefile — one entry point for both Go services.
#
# Contributors: `make test` runs every Go test in the repo. `make vet` is
# the same for static checks. Per the 2026-06-10 audit (DEVE-6 / DOCS-8):
# keep CI and local on the same targets. CI jobs use the per-service
# targets below to preserve parallel jobs and failure isolation.

.PHONY: test test-coordinator test-gateway test-integration test-dist \
        vet vet-coordinator vet-gateway \
        build-linux check fmt

test: test-coordinator test-gateway test-integration test-dist

test-coordinator:
	cd phase4-coordinator && go test ./...

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
	bash phase4-coordinator/dist/test/check_deploy_config_test.sh

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

check:
	phase4-coordinator/dist/check-deploy-config.sh \
		phase4-coordinator/dist/coordinator.yaml \
		phase5-gateway/dist/gateway.yaml

fmt:
	cd phase4-coordinator && gofmt -w .
	cd phase5-gateway && gofmt -w .
