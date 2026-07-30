# SPEC-015 Step 11 Handoff

Worktree: `/private/tmp/macprovider-poc-spec015-step02-continue`
Branch: `impl/spec-015-receipts-runtime-cont`
Base checkpoint before this step: `6f50d1a Prove receipt compatibility at deployment boundaries`

## User Standing Instructions

- Continue SPEC-015 until all steps are complete.
- Commit each step, but create only one PR after all steps finish.
- Use native subagents for auditors, not OMX/OMC.
- Run code, security, and architecture auditors until there are 0 Critical/High/Medium findings.
- Do not ask edit-permission questions for normal local edits.

## Step 11 Changes In This Checkpoint

- Added SPEC-015 acceptance manifest and runner under `test/integration/spec015/`.
- Wired required CI job `spec-015-acceptance` into `.github/workflows/ci.yml` and `ci-required`.
- Added cross-service receipt-enabled integration path through gateway -> coordinator -> fake provider.
- Added acceptance verifier helper that validates receipt tuple shape, signature, current/previous `/poolz` trust, grace-window slack, and tuple `provider_pubkey` binding.
- Added coordinator receipt forwarding trust gate so untrusted providers cannot spoof `X-MacProvider-Receipt`.
- Added coordinator trusted null-usage provider error pass-through preserving status/body/receipt.
- Added gateway-local reject tests proving auth/quota/kill-switch failures do not expose receipt headers.
- Added Swift receipt key persistence/perf/hash assertions for the acceptance gate.
- Added Node SDK `package-lock.json`; runner now uses `npm ci`.
- Added Python SDK `requirements.lock` placeholder and runner now uses `pip --require-hashes`; see blocker below.

## Auditor Results From This Session

Fresh native auditors found and we fixed:

- Code HIGH: cross-service AC-5/AC-6 fixture used raw byte hashes instead of SPEC-015 canonical prompt/output hashes.
  - Fixed by changing fake provider receipt construction and cross-service assertions to canonical prompt/output hash helpers.
- Code/Security/Architecture MEDIUM: verifier did not bind tuple `provider_pubkey` to selected `/poolz` trust key.
  - Fixed by validating the tuple key against current/previous trust and adding mismatch-negative coverage.
- Code/Security HIGH/MEDIUM before latest audit: coordinator forwarded receipts from untrusted providers and dropped trusted null-usage receipts.
  - Fixed with trust gating and pass-through tests.

Known remaining auditor blocker:

- Security MEDIUM: `test/integration/spec015/sdk_compat/python/requirements.lock` is not a real hash-locked transitive dependency lock. The Go fixture test now intentionally fails until the lock includes real pinned transitive deps and `--hash=sha256:` entries.

## Validation Evidence

Passing in this sandbox:

- `cd test/integration && go test -race -count=1 -timeout 5m ./spec015`
- `cd test/integration && go test -race -count=1 -timeout 5m . -run TestSpec015ReceiptEnabledCrossServiceHeaderVerifies`
- `cd test/integration && go test -count=1 ./spec015 -run 'TestReceiptVerifier|TestSpec015AcceptanceCriteria'`
- `cd phase4-coordinator && go test ./internal/buyer -count=1 -run 'TestHTTPForwarding(StripsReceiptFromProviderWithoutPublishedReceiptKey|PassesReceiptFromProviderWithPublishedReceiptKey|PassesTrustedNullUsageReceipt)'`
- `bash -n test/integration/spec015/sdk_compat/run.sh test/integration/spec015/run_acceptance.sh`
- `node --check test/integration/spec015/sdk_compat/js/smoke_openai_node.mjs`
- `git diff --check`

Expected/current failing guard:

- `cd test/integration && go test -count=1 . -run TestSpec015SDKCompatFixturePinsOpenAISDKs`
- Current failure: `python lock must include transitive dependency anyio==`

Sandbox validation gaps:

- Full buyer/coordinator tests and SDK runner can hit local port bind restrictions: `bind: operation not permitted`.
- Swift socket/Keychain-backed tests are partially sandbox-limited.
- `bash test/integration/spec015/sdk_compat/run.sh` cannot start its local fixture server in this sandbox due port bind restriction.

## Hard Blocker Details

The Python hash lock could not be generated here because artifact access is unavailable:

- `pip download -r python/requirements.txt` fails with DNS resolution errors for `pypi.org`.
- Direct `curl`/Python URL fetch to `pypi.org` and `files.pythonhosted.org` fails.
- `curl --resolve ...` direct-IP TLS attempts fail immediately.
- `node_repl` fetch path fails before execution with `sandboxCwd must be an absolute file URI`.
- A dependency-expert subagent also could not verify real SHA-256 hashes and correctly refused to write placeholders.

## Next Session Continuation Steps

1. In a network-enabled environment, replace `test/integration/spec015/sdk_compat/python/requirements.lock` with a real lock generated from `openai==1.30.1`, including all transitive dependencies and hashes:

   ```bash
   cd test/integration/spec015/sdk_compat/python
   pip-compile --generate-hashes --output-file=requirements.lock requirements.txt
   ```

   If `pip-compile` is unavailable, use an equivalent resolver, but do not hand-write unverified hashes.

2. Run:

   ```bash
   cd test/integration && go test -count=1 . -run TestSpec015SDKCompatFixturePinsOpenAISDKs
   bash test/integration/spec015/sdk_compat/run.sh
   ```

   The runner needs network for SDK installs and either a supplied gateway URL or permission to bind the local compatibility server.

3. Rerun full Step 11 validation in a permissive environment:

   ```bash
   bash test/integration/spec015/run_acceptance.sh
   cd test/integration && go test -race -count=1 -timeout 5m ./...
   cd phase4-coordinator && go test ./... -count=1
   cd phase5-gateway && go test ./... -count=1
   cd phase3-binary && swift test --parallel --filter "ReceiptKeyStoreTests|HTTPServerReceiptTests|ReceiptBuilderTests|PromptCanonicalizerTests|OutputCanonicalizerTests|RotateKeyCommandTests|CoordinatorClientTests|ReceiptPerfTests"
   make test-dist
   ```

4. Spawn fresh native code, security, and architecture auditors. Continue fixing until all three report `0 Critical/High/Medium`.

5. Only after auditors clear, write `specs/SPEC-015-IMPL-STEP_11-audit.md` and continue later SPEC-015 steps. Do not open the PR until all steps finish.
