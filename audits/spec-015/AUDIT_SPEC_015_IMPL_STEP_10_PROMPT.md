# AUDIT_SPEC_015_IMPL_STEP_10_PROMPT — SDK compat + nginx config + perf bench

You are auditing SPEC-015 implementation Step 10 in the macprovider-poc repository.

## Scope

Review only the Step 10 delta for BUILD_SPEC_015_IMPL_PROMPT.md:

- pinned OpenAI SDK compatibility fixtures under `test/integration/spec015/sdk_compat/` plus `test/integration/spec015_sdk_fixture_test.go`;
- nginx receipt-header buffer config in the repo's actual deploy templates:
  - `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`;
  - `phase5-gateway/dist/nginx-api.malibu.tech.conf`;
- deploy gates `phase4-coordinator/dist/test/check_nginx_receipt_buffers_test.sh` and `phase4-coordinator/dist/test/check_nginx_receipt_header_live_test.sh` wired into `make test-dist`;
- Swift receipt construction perf benchmark `phase3-binary/Tests/macprovider-cliTests/ReceiptPerfTests.swift`;
- implementation notes updates in phase3, phase4, and phase5.

The build prompt names `deploy/nginx/*.conf`, but this repo stores deployable nginx templates in the module `dist/` directories above. Treat that path mapping as intentional and audit whether it is documented and mechanically tested.

## Required verdict format

Return findings grouped by severity: Critical, High, Medium, Low. For each finding include file/line references, the violated SPEC-015 or build-prompt requirement, exploit/regression impact, and a concrete fix.

The step passes only at **0 Critical / 0 High / 0 Medium**. Low findings may remain if explicitly non-blocking.

## Checks

1. AC-9 SDK compatibility: verify both fixtures are pinned to specific OpenAI SDK versions satisfying Python >= v1.0 and JavaScript >= v4.0, and that the scripts exercise `chat.completions.create` in both non-streaming and streaming mode against `MACPROVIDER_SPEC015_GATEWAY_URL`.
2. AC-15 nginx forwarding: verify the nginx buffer config is sufficient for a 4096-byte `X-MacProvider-Receipt` response header, is included in a repo deploy validation gate, and includes a runnable curl echo check for deployed nginx via `SPEC015_NGINX_ECHO_URL`.
3. AC-16 performance: verify the benchmark uses a representative 1024-output-token payload, performs 1000 measured `ReceiptBuilder.build` iterations after warmup, and asserts p95 < 5 ms without measuring unrelated setup/keychain work.
4. Ensure Step 10 does not change receipt semantics, signing material handling, gateway allowlist behavior, or production runtime behavior beyond nginx deploy configuration and test fixtures.
5. Verify implementation notes accurately document the actual path mapping, operational rollout gap, and any test limitations.

## Evidence available from implementation pass

Expected validation commands before final acceptance:

```bash
cd test/integration && go test ./... -count=1
make test-dist
cd phase3-binary && swift test --filter ReceiptPerfTests
cd phase3-binary && swift test
git diff --check
```
