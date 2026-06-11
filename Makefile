# Root Makefile — one entry point for both Go services.
#
# Contributors: `make test` runs every Go test in the repo. `make vet` is
# the same for static checks. Per the 2026-06-10 audit (DEVE-6 / DOCS-8):
# keep CI and local on the same targets. CI jobs use the per-service
# targets below to preserve parallel jobs and failure isolation.

.PHONY: test test-coordinator test-gateway \
        vet vet-coordinator vet-gateway \
        build-linux check fmt

test: test-coordinator test-gateway

test-coordinator:
	cd phase4-coordinator && go test ./...

test-gateway:
	cd phase5-gateway && go test ./...

vet: vet-coordinator vet-gateway

vet-coordinator:
	cd phase4-coordinator && go vet ./...

vet-gateway:
	cd phase5-gateway && go vet ./...

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
