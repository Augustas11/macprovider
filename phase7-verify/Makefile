# phase7-verify Makefile.
#
# The verifier must remain pure Go for reproducible buyer-side binaries.
# Cross-compilation targets set GOOS, GOARCH, and CGO_ENABLED explicitly.

BINARY := macprovider-verify
CMD := ./cmd/macprovider-verify
DIST_DIR := dist

.PHONY: build build-all test vet clean

build:
	CGO_ENABLED=0 go build -o $(BINARY) $(CMD)

build-all: clean
	mkdir -p $(DIST_DIR)
	GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o $(DIST_DIR)/$(BINARY)-darwin-arm64 $(CMD)
	GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -o $(DIST_DIR)/$(BINARY)-darwin-amd64 $(CMD)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o $(DIST_DIR)/$(BINARY)-linux-amd64 $(CMD)

test:
	go test ./...

vet:
	go vet ./...

clean:
	rm -f $(BINARY)
	rm -rf $(DIST_DIR)
