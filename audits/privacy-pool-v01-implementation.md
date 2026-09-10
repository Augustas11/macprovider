# Privacy Pool v0.1 implementation evidence

This change implements all five local pilot stages behind default-off component flags: provider identity/key lifecycle, buyer-pinned encryption and single-use reservations, opaque dispatch and provider validation, existing usage settlement with truthful disclosure, and streaming/recovery. Only global-pool chat completions are supported. Required-mode pool selection, responses/messages, unavailable keys/components, and settlement enforce mode fail closed. Plaintext and SPEC-008 traffic retain their existing paths.

Providers read decrypted requests. Relays see routing metadata and responses, including echoed request content. This is request encryption, not confidential compute, provider-private execution, response encryption, or general public identity distribution. The operator provisions buyer pins independently; see [pilot custody and operation](../docs/runbooks/relay-blind-pilot-key-custody.md).

## Implementation surfaces

- `phase3-binary`: distinct durable Ed25519/X25519 identities, key advertisement/revocation, CryptoKit framing/decryption, secured claim journal, runtime-pinned token validation, evidence, and isolated fixture.
- `phase4-coordinator`: durable keys/reservations/consumption, authenticated opaque WebSocket dispatch and status recovery, no failover, clear-cap accounting, receipt/reward exclusions, and fresh capabilities.
- `phase5-gateway`: pinned reference buyer client, reservations and encrypted forwarding, durable replay/quota recovery, wallet compatibility, and per-request privacy/settlement metadata.
- `specs`: draft SPEC-041 contracts and narrowly reconciled dependencies; SPEC-041 conformance stays pending and production stays not deployed.
- `test/integration`, `test/fixtures`, and `scripts`: shared Go/Swift crypto vectors, real Swift loopback journeys, failure/crash tests, and non-promotable signed local evidence tooling.

## Verification

Commands were executed in the isolated task worktree. Interrupted runs are not counted as passing.

| Check | Result |
| --- | --- |
| Coordinator `go test ./... -count=1` and `go vet ./...` | Pass |
| Coordinator `go test -race ./internal/relayblind ./internal/buyer ./internal/ws -count=1` | Pass |
| Gateway `go test ./... -count=1`, `go vet ./...`, `GOOS=linux GOARCH=amd64 go build ./...` | Pass |
| Gateway race tests across crypto, client, router, SQLite, settlement journal | Pass |
| `make lint-coordinator` with pinned golangci-lint v2.12.2 | Pass, zero issues |
| `make vet` (coordinator, gateway, integration) | Pass |
| `make test-dist` | Pass, complete distribution/script suite |
| `python3 scripts/check_spec_governance.py --base-ref origin/main` | Pass |
| `make test-integration` | Pass, all packages; two opt-in SDK tests skipped (below) |
| Integration `go test -run '^TestRelayBlind' -race -count=1 -timeout 5m` | Pass |
| `bash scripts/test-relay-blind-parity.sh` | Pass |
| `swift test --filter RelayBlindProviderTests` | Pass, 13 tests |
| `swift test --filter 'InferenceRelay\|Tier2ProviderSession\|ModelRuntime'` | Pass, 83 selected tests; two overlap the provider selection, giving 94 unique passing tests combined |
| `python3 -m unittest scripts.tests.test_relay_blind_local_journey` | Pass, 3 tests |
| Full Swift suite | Not green: CoordinatorClient selection has 27 failures, independently reproduced on clean origin/main 6006f3135c106e7e13eb50171fcdf59f5cc54231 |
| Swift suite excluding CoordinatorClientTests | Interrupted during DoctorCommandTests after extended silence; not passing evidence |

The relay-only signed JSON log records 18 passed, zero skipped, and zero failed test actions. The broader integration run skips `TestSpec015SDKCompatAgainstGateway` (`SPEC015_SDK_COMPAT_GATEWAY` unset) and `TestSpec015SDKCompatLiveRunner` (`SPEC015_SDK_COMPAT_LIVE` and live URL unset). Docker is not exercised by this integration target; no Docker result is claimed.

The real Swift process-crash test kills the provider after its first chunk, restarts with the same persisted identity/session, replays the old dispatch, and proves no second output, one unknown-postdispatch journal entry, and exactly one settlement. Six durable provider crash cuts separately cover claim, decrypt, validation, partial output, terminal-send loss, and terminal-update loss. AEAD tampering reaches the Swift provider and produces typed rejection, one burned terminal claim, zero charge, and cleared hold. Tests cover cancellation, pre/post-dispatch disconnect, reconnect, cap underdeclaration/overreporting, replay/restart/concurrency, pin substitution, low-order keys, malformed envelopes, pool rejection, and rollback.

## Evidence boundaries

The signed local journey artifact is `ephemeral_test_only`, signed with an ephemeral P-256 test key that is deleted after capture. It binds the test log and source snapshot, verifies required test names actually passed, and cannot promote SPEC conformance. The verified artifact and public test key are checked in under [local test evidence](evidence/privacy-pool-v01-local/README.md), bound to clean commit `956498f3fee52988d37d777e7f2fe0c2a8381676`; subsequent changes are documentation/evidence, test-fixture portability, and CLI help copy; runtime behavior is unchanged. No production identity signature or hardware journey is fabricated.

A separate cached Llama-3.2-3B-Instruct-4bit self-test passed on local Apple M5/arm64 using the real MLX Metal runtime (four-token bound, about 1.61 tokens/second). It used no model download or external service and emitted no prompt/generated text in reported evidence. This proves local model runtime operation only. The complete buyer/gateway/coordinator/Swift encrypted journey uses a deterministic backend, not that model.

Production activation, independently trusted deployment journey signatures, a complete encrypted journey using production model weights, and release/notarization qualification remain external readiness work. None was authorized or performed. Receipt v0.4 is unchanged; unsupported verified-model and verified-work claims are excluded while ordinary usage accounting remains active.

## Review and remaining low-severity limits

The five independent native review lanes are code, security, architecture, adversarial verification, and product design. GPT-6 Astra was available and used for adversarial plan and final verification; no substitution was made. All five lanes report zero Critical, High, and Medium findings. Material findings were repaired and affected checks rerun. Review snapshots and detailed findings are retained in ignored local `.omx/reviews/` artifacts; the final PR records disposition.

Two availability limitations are carried explicitly: expired active-state references can temporarily delay same-kid renewal until reservation cleanup fences them; the provider's cumulative revocation file has a 16 KiB read ceiling and no expiry pruning, so extensive repeated revocation can require operator maintenance before new startup. Both fail closed and do not authorize replay, stale-key use, or duplicate settlement. Do not delete revocations still inside signed expiry plus replay retention.

Historical signed journey evidence for existing plaintext/verified-settlement requirements remains historical. SPEC-006-R002/R003 and SPEC-022-R005/R008 return to pending because this change modifies their mapped selector bytes and historical signatures cannot attest the new implementation. Local regressions pass; fresh independently trusted journey evidence is required to restore conformant status. No signature is replaced or redated, and SPEC-041 is not promoted.

## Linux CI fixture follow-up

Initial Linux CI rejected positive pin fixtures under world-writable `/tmp`, as the production verifier correctly requires safe ancestry. Three test files now create private, cleaned-up fixtures under a non-symlinked home directory. Production pin validation is unchanged. All five independent review lanes cleared this delta with zero Critical/High/Medium findings.

Verification passed in `golang:1.26.6-bookworm` on Linux/arm64 as unprivileged UID/GID 1000, with `/tmp` mode 1777 and the source mounted read-only: both relayblind packages ran `go test ./internal/relayblind -run '^TestReadIdentityPinRejectsSymlinksAndPermissions$' -race -count=1`; the client ran `go test ./cmd/relay-blind-client -run 'TestRunAPIKeyAndWalletSession|TestRunDoesNotRetryEncryptedRequest|TestRunRejectsRelaySubstitutedRecordBeforeEncryptedSend' -race -count=1`. Full affected packages also passed locally under the race detector. This is targeted Linux container evidence, distinct from the broader integration target's lack of Docker coverage.

The unchanged trusted-pool timing test also passed twice locally after its initial hosted-runner timing failure; no threshold or assertion was weakened. Merge remains gated on the new CI run.

The subsequent full Swift CI run completed 2,698 test actions with one public-language failure: the new serve flag help exposed a specification identifier. The help now says “Opt into the default-off relay-blind request encryption pilot.” The existing `swift test --filter 'StatusCommandTests/testRoutineCLIHelpUsesCanonicalPublicLanguage'` regression passes; no assertion, flag behavior, or security policy changed. The lockfile was restored after local SwiftPM resolution.
