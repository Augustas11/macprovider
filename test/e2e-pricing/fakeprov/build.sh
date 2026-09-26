#!/usr/bin/env bash
# Build fakeprov for the tier-E2 VM (linux/amd64) and the canary Mac
# (darwin/arm64) into ./dist/. Offline: uses the local module cache only.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist
export CGO_ENABLED=0 GOFLAGS=-mod=mod GOPROXY=off
GOOS=linux GOARCH=amd64 go build -trimpath -o dist/fakeprov-linux-amd64 .
GOOS=darwin GOARCH=arm64 go build -trimpath -o dist/fakeprov-darwin-arm64 .
ls -l dist/
