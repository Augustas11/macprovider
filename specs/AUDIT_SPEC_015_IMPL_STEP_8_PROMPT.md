# AUDIT_SPEC_015_IMPL_STEP_8 - Gateway receipt response-header allowlist

Audit SPEC-015 Step 8 in `/private/tmp/macprovider-poc-spec015-step02-continue`. Do not edit files.

## Scope

Step 8 is limited to `phase5-gateway` response-header forwarding:

1. Add `X-MacProvider-Receipt` as the only newly allowed `X-MacProvider-*` response header for receipt-eligible non-streaming chat responses, including SPEC-001 null-usage provider errors.
2. Preserve request-boundary stripping of buyer-supplied/internal `X-MacProvider-*` headers.
3. Preserve stripping of non-allowlisted response headers, especially `X-MacProvider-Foo`, `X-MacProvider-Receipt-Pending`, and internal quota/route headers.
4. Keep streaming responses and generic upstream provider failures receipt-free even when upstream sends `X-MacProvider-Receipt`.
5. Do not log the receipt value.

## Files to inspect

- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/router/server_test.go`
- `phase5-gateway/implementation-notes.html`
- `specs/SPEC-015-receipts.md` §6 and §13
- `specs/SPEC-006-buyer-api.md` §17

## Validation evidence

Run or verify:

```bash
go test ./internal/router -run 'TestReceiptHeaderForwardedAndSiblingMacProviderHeadersStripped|TestNullUsageErrorReceiptHeaderForwarded|TestGenericProviderErrorReceiptHeaderStripped|TestStreamingReceiptHeaderStripped|TestProviderPinningHeadersStripped' -count=1
go test ./... -count=1
git diff --check
```

## Findings format

Report only Critical, High, or Medium findings. Include concrete file/line references. Final verdict must state counts as `0 Critical / 0 High / 0 Medium` when clean.

## Severity guide

- Critical: leaks private receipt material, disables existing gateway header stripping, forwards arbitrary `X-MacProvider-*`, logs receipt values, or breaks chat completions.
- High: forwards rejected SPEC-015 headers such as `X-MacProvider-Receipt-Pending`, exposes provider/route/quota internals, or changes request-boundary strip behavior.
- Medium: missing focused regression tests, ambiguous allowlist semantics, missed null-usage receipt forwarding, streaming/generic-error receipt exposure, or implementation-note/audit-prompt gaps that could cause future unsafe expansion.
