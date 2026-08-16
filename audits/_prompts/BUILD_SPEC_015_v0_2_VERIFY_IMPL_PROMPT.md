# BUILD_SPEC_015_v0_2_VERIFY_IMPL — buyer-side receipt verification CLI (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing any code.**

Your job is to implement SPEC-015 v0.2.4 (`specs/SPEC-015-receipts.md`, LOCKED 2026-06-23) buyer-side verification surface:

1. **One new Go module:** `phase7-verify/`, containing the `macprovider-verify` binary that implements the §10 verification contract.
2. **One SPEC-002 v1.5 candidate annotation absorbed in code:** the `GET /v1/receipt-keys/<provider_id>` public buyer-safe pubkey resolver endpoint on the coordinator (`phase4-coordinator`).

That is the entire v0.2 IMPL scope. v0.1.3 issuance is already LANDED via PR #123 (commit `e95c365` on `main`); this BUILD makes v0.1.3 receipts actually verifiable for buyers.

## What you are building

A standalone Go CLI binary at `phase7-verify/cmd/macprovider-verify/` that takes a v0.1.3 receipt (header bytes or bundle JSON) plus the buyer's recorded request/response, and returns a deterministic `valid`/`invalid`/`inconclusive` result with normative exit codes. The binary verifies signatures against the provider's ed25519 pubkey, which it resolves from one of three sources per §10.2 (explicit flag → local cache → live `GET /v1/receipt-keys/<provider_id>` on the configured coordinator).

The coordinator endpoint addition is one new buyer-port HTTP handler returning only the receipt-key tuple (no operator-sensitive fields), public/unauthenticated, rate-limited, with `Cache-Control: public, max-age=300`.

See `specs/SPEC-015-receipts.md` §10 (Verification, NORMATIVE in v0.2) and §10.7 (SPEC-002 v1.5 candidate annotation) for the full contract. Every MUST/MUST NOT/SHOULD in §10 is binding here.

## Repo conventions you MUST honour

1. **House style:** existing Go patterns live in `phase4-coordinator/internal/` and `phase5-gateway/internal/`. The new `phase7-verify/` module should match the existing testing (table-driven `_test.go`), error-handling (wrapped errors with context), and logging (structured slog) idioms — but with one critical exception: this module ships as a buyer-distributed binary, so it MUST stay **pure stdlib**. See §"Dependencies" below.
2. **No locked-spec edits beyond the one named candidate annotation.** v0.2.4 absorbs exactly one SPEC-002 v1.5 candidate:
   - `GET /v1/receipt-keys/<provider_id>` endpoint on the coordinator's buyer port. Public, unauthenticated, rate-limited. Response shape pinned in SPEC-015 §10.7. Absorb in Step 0.
   
   ANY other edit to SPEC-001/002/005/006/008/011/013/015 text is OUT OF SCOPE and is a critical violation. If you find yourself needing to change a locked spec, STOP and surface the issue.
3. **Audit-loop discipline (NON-NEGOTIABLE, per `feedback-build-audit-loop` memory):** after each numbered Step below, author `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_N_PROMPT.md`, fire it at codex via `omc ask codex "$(cat /path/to/prompt)"`, fix the findings, re-audit with `R<n+1>_PROMPT.md` if needed, loop until **0 CRITICAL, 0 MAJOR** for that step. Only then proceed to Step N+1. Existing pattern: SPEC-013 ran 21 audit rounds across 11 BUILD steps; the v0.2 IMPL should expect similar density given the security-critical surface (signature verification, trust root, exit-code reliability).
4. **Branching:** create `impl/spec-015-v0-2-step-NN` branches off `main` per logical PR group (see §"PR grouping" below). Do NOT develop on local `main`. Follow `CLAUDE.md` PR workflow: feature branch → IMPL audit loop on branch → push → PR → squash-merge → `git reset --hard origin/main` locally.
5. **One bundled PR per `feedback-bundle-spec-impl-one-pr`:** the v0.2 SPEC commits (already on `spec/015-receipts-v0-2` branch) + the IMPL work should land in a single PR to `main`. Rebase the IMPL branches onto `spec/015-receipts-v0-2` as you go; final PR targets `main` and squash-merges the bundle.
6. **AC-18 through AC-27 (SPEC-015 v0.2 §14) are the deterministic acceptance gate.** Every AC must have a mechanically-runnable test by the time the implementation is ready for the Step-10 integration acceptance run.
7. **`implementation-notes.md` per worktree.** As you work, maintain `phase4-coordinator/implementation-notes-spec-015-v0-2.md` (for the §10.7 endpoint) and `phase7-verify/implementation-notes.md` capturing:
   - Design decisions where the spec was ambiguous (e.g. on-disk cache schema, JSON Schema document location)
   - Deviations from the spec and why (there should be none for v0.2)
   - Tradeoffs considered (e.g. cache file format, rate-limit storage)
   - Open questions for operator review
8. **No silent capability degradation.** If a step uncovers that an AC is not satisfiable as written, STOP and surface the gap. Do NOT relax the AC; either fix the implementation or escalate back to a SPEC-015 v0.2.5+ spec revision.

## Files you should read before writing code

1. `specs/SPEC-015-receipts.md` v0.2.4 LOCKED — particularly §§10, 10.7, 14 (AC-18..AC-27), and 15 (open questions for context on deferred work).
2. `specs/SPEC-015-v0-2-audit.md` — the 5-round audit history. Round-1 CF1/CF2/CF3 explain WHY the v0.2 architecture is shaped the way it is. Read these to avoid re-introducing patterns the audit closed.
3. `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` — the in-house Swift JCS implementation. Your Go JCS port (Step 2) MUST produce bit-identical canonical bytes for every input the Swift signer accepts.
4. `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift` and `OutputCanonicalizer.swift` — the prompt and output canonicalization shipped via PR #123. Your Go versions in Step 4 must match these byte-for-byte.
5. `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift` — the signing-side reference. The tuple keys, signing order, base64 envelope, and 64-byte signature contract you verify against.
6. `phase4-coordinator/internal/pool/` and `phase4-coordinator/cmd/coordinator/main.go` — where the `/poolz` `receipt_pubkey` / `receipt_pubkey_prev` data lives and where to add the new `/v1/receipt-keys/<provider_id>` route.
7. `phase5-gateway/` — read enough to confirm the gateway already forwards `X-MacProvider-Receipt` per SPEC-006 v0.9. No gateway changes in v0.2.
8. `CLAUDE.md` (this repo) — PR workflow, git identity routing, dirty-main restoration steps.

## Dependencies (HARD constraint)

- **Pure-Go stdlib only.** No third-party imports. `crypto/ed25519`, `crypto/sha256`, `encoding/base64`, `encoding/json`, `net/http`, `os`, `flag`, etc. The buyer is auditing this binary; every transitive dependency is a foot-gun. JCS is implemented inline (~300 lines) per Step 2.
- **No cgo.** Cross-compile cleanly for `darwin/arm64`, `darwin/amd64`, `linux/amd64`.
- **Reuse the Swift JCS via copy-paste with attribution, NOT via Go module import.** The Swift file is the spec reference; the Go port is a hand-translation with parity tests.
- **License:** verify the main repo's `LICENSE` file applies. If `phase7-verify/LICENSE` is empty or absent, copy the main repo's license (or apply MIT/Apache-2.0 per operator decision before shipping public binaries).

## Step decomposition (10 steps)

Each step lands on its own `impl/spec-015-v0-2-step-NN` branch. Each step goes through the audit loop before the next step starts. Step-NN PRs target `spec/015-receipts-v0-2`; the final PR (Step 10) rebases the chain onto `main` and bundles SPEC + IMPL together.

### Step 0 — SPEC-002 v1.5 candidate absorption (coordinator endpoint)

**Branch:** `impl/spec-015-v0-2-step-00`  
**Module:** `phase4-coordinator/`  
**SPEC reference:** §10.7

**What lands:**
1. New HTTP handler `GET /v1/receipt-keys/{provider_id}` on the buyer-port mux (alongside `/v1/pool/check`, NOT the operator-port `/poolz`).
2. Handler reads the in-memory `Provider.ReceiptPubkey` + `Provider.ReceiptPubkeyPrev` (already present from PR #123) and returns the §10.7 response shape:
   ```json
   {
     "provider_id": "...",
     "receipt_pubkey": "...",
     "receipt_pubkey_prev": null | { "pubkey": "...", "rotated_at": "...", "expires_at": "..." },
     "fetched_at": "<server now() RFC3339 UTC>"
   }
   ```
3. Public/unauthenticated — no bearer key check.
4. Rate limiter: 10 req/sec/IP token bucket; over-quota returns HTTP 429 with `Retry-After: 1` header.
5. `Cache-Control: public, max-age=300` on success.
6. HTTP 404 with `error.code = "provider_not_found"` envelope when `provider_id` is not in pool (use the existing coordinator error envelope helper).
7. Response MUST NOT leak any field outside `(provider_id, receipt_pubkey, receipt_pubkey_prev, fetched_at)` — explicitly verify the marshaled JSON excludes `endpoint_url`, `hostname`, `connected_at`, `slots_total`, `throughput_tps_estimate`, etc.

**Tests (table-driven):**
- 200 with current key only (provider with no rotation history)
- 200 with `receipt_pubkey_prev` populated (provider in grace window)
- 200 with `receipt_pubkey: null` (pre-v1.6 binary in pool)
- 404 for unknown `provider_id`
- 429 after 11 requests in 1 second from same IP
- Response body excludes operator-sensitive fields (assert by JSON-key whitelist)
- `Cache-Control` header present on success, absent on 404/429
- Concurrent requests don't race on the rate-limit counter

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_0_PROMPT.md` — fire at codex. Findings to expect: rate-limit storage design (in-memory vs. shared), redaction completeness, response-shape compliance.

**Done when:** 0 CRITICAL / 0 MAJOR on the IMPL audit AND a sanity-check that running `curl http://buyer-port/v1/receipt-keys/<id>` against a local coordinator returns the expected shape.

---

### Step 1 — `phase7-verify/` module scaffold

**Branch:** `impl/spec-015-v0-2-step-01`  
**Module:** `phase7-verify/` (new)

**What lands:**
1. New Go module: `phase7-verify/go.mod` with `go 1.22` (or whatever the repo currently uses; check `phase4-coordinator/go.mod`). Module path: `github.com/Augustas11/macprovider/phase7-verify`.
2. Directory layout:
   ```
   phase7-verify/
     cmd/macprovider-verify/main.go
     internal/jcs/         (Step 2)
     internal/canon/        (Step 4 — prompt+output canonicalization)
     internal/receipt/     (Step 3)
     internal/cache/       (Step 5)
     internal/resolver/    (Step 5)
     internal/verify/      (Step 6)
     internal/cli/         (Step 7-9)
     testdata/             (golden fixtures)
     README.md             (build instructions, version compat table)
     LICENSE               (matching main repo)
     go.mod
     go.sum                (empty — no external deps)
   ```
3. `main.go` skeleton: handles `--version`, `--help`, and a placeholder dispatch on subcommand `verify`. `--version` outputs both the binary version AND the highest SPEC-015 version it can verify (per BUILD prompt requirement; pin both as constants).
4. `Makefile` target `make verify` building for `darwin/arm64`, `darwin/amd64`, `linux/amd64`.
5. Empty placeholders for each internal package (just `package <name>` and a `// TODO: Step N` comment).
6. CI job in `.github/workflows/ci.yml` adding a `phase7-verify (go vet + test)` job.

**Tests:**
- `go vet ./phase7-verify/...` passes
- `go test ./phase7-verify/...` passes (empty)
- `go build ./phase7-verify/cmd/macprovider-verify` produces a runnable binary
- `./macprovider-verify --version` prints expected format
- `./macprovider-verify --help` prints usage including all flags from §10.4

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_1_PROMPT.md` — focus: directory hygiene, zero external deps invariant, CI gate setup, version-string format.

**Done when:** 0 CRITICAL/MAJOR; `go.sum` is empty proving zero external deps.

---

### Step 2 — JCS port (Go, pure stdlib)

**Branch:** `impl/spec-015-v0-2-step-02`  
**Module:** `phase7-verify/internal/jcs/`  
**SPEC reference:** §3.2, §10.3

**What lands:**
1. Hand-port `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` to `internal/jcs/jcs.go` — pure stdlib. Include:
   - RFC 8785 base JCS (recursive object/array/scalar canonicalization)
   - RFC 8785 §3.2.2.3 ECMAScript double encoding
   - Explicit NFC normalization on natural-language string inputs (use `golang.org/x/text/unicode/norm` — EXCEPTION to "no external deps" because NFC is a standard part of Unicode and the `x/text` module is golang.org/x stdlib-adjacent. CONFIRM with audit; if rejected, hand-port NFC tables.)
2. Public API: `func Canonicalize(value Value) ([]byte, error)`. `Value` is a sum type mirroring the Swift `Value` enum (object/array/string/rawString/int/double/bool/null).
3. Helper: `func CanonicalizeJSON(raw []byte) ([]byte, error)` — parse JSON to `Value` and canonicalize.

**Tests:**
- `testdata/jcs_parity.json` — at least 50 input/output pairs, generated by running Swift JCS on diverse inputs (numbers, unicode, nested objects). Each entry: `{"input": <any>, "expected_canonical": "<bytes hex>"}`.
- Table-driven test: every fixture entry MUST produce the expected bytes byte-for-byte.
- Edge cases: empty object/array, single-element, deeply nested (10+ levels), unicode NFC vs NFD inputs (both canonicalize to NFC), very large numbers (int64 max, float Infinity/NaN — these should error, not silently produce wrong bytes).
- A CI step that runs the Swift JCS test suite AND the Go JCS test suite against the SAME fixtures and fails on any mismatch.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_2_PROMPT.md` — focus: NFC handling correctness, ECMAScript double-encoding edge cases (1e-7 vs 0.0000001, etc.), Swift↔Go parity completeness.

**Done when:** Swift↔Go parity CI gate passes with the same fixture set. AC-24's JSON Schema parity test will reuse this fixture pattern.

---

### Step 3 — Receipt parser + signature verifier

**Branch:** `impl/spec-015-v0-2-step-03`  
**Module:** `phase7-verify/internal/receipt/`  
**SPEC reference:** §3.1, §3.3, §3.4, §10.0 steps 1-4 and 6

**What lands:**
1. Header parser: split `X-MacProvider-Receipt` value on the first `.` into `(b64_tuple, b64_sig)`. Errors → distinct typed errors (`ErrHeaderShape`, `ErrBase64Decode`, `ErrSigLength`).
2. Tuple decoder: base64-decode → `[]byte` → JSON-parse → struct `Tuple` with fields `ModelID`, `PromptHash`, `OutputHash`, `ProviderPubkey`, `TTFTms`, `TokensOut`, `UnixTS`. Reject if tuple JSON contains any key not in the seven-element set, or is missing any of the seven. Field types per §3.1.
3. ed25519 verifier wrapper: `func Verify(tuple []byte, sig []byte, pubkey []byte) bool` using `crypto/ed25519`. Note: pass the RAW JCS tuple bytes (not re-canonicalized), since what the provider signed IS those exact bytes.
4. Public API: `func Parse(header string) (Tuple, RawTupleBytes, Sig, error)` — returns the parsed tuple AND the raw JCS bytes for downstream verification.

**Tests:**
- Golden header: a real v0.1.3 receipt from the existing integration tests (`test/integration/`). Verify it parses and the signature checks against the known pubkey.
- Tampered tuple (flip one byte of `b64_tuple`): parse succeeds; verify FAILS.
- Tampered signature (flip one byte of `b64_sig`): parse succeeds; verify FAILS.
- Header with no `.`: `ErrHeaderShape`.
- Header with malformed base64: `ErrBase64Decode`.
- Signature wrong length (63 or 65 bytes after decode): `ErrSigLength`.
- Tuple missing a required key: parse-time error.
- Tuple with an extra key: parse-time error.
- Tuple with wrong type for a key (`tokens_out` as string): parse-time error.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_3_PROMPT.md` — focus: signature side-channel resistance (constant-time?), tuple parse strictness, error taxonomy completeness.

**Done when:** 0 CRITICAL/MAJOR; golden v0.1.3 receipts from the integration test corpus verify correctly.

---

### Step 4 — Prompt and output canonicalization

**Branch:** `impl/spec-015-v0-2-step-04`  
**Module:** `phase7-verify/internal/canon/`  
**SPEC reference:** §4, §5, §10.3

**What lands:**
1. `func CanonicalPrompt(request map[string]any) (jcs []byte, hash [32]byte, err error)` — implements §4.2 (16-field canonical prompt object), §4.3 (canonical message), §4.4 (canonical tool). Mirrors `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift` byte-for-byte.
2. `func CanonicalOutput(response map[string]any) (jcs []byte, hash [32]byte, err error)` — implements §5.1 (canonical output: content/tool_calls/finish_reason). Mirrors `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift`.
3. The raw OpenAI request/response shapes per §10.4.1 — absent fields canonicalize as JSON `null` per the locked v0.1 §4.2 rule.

**Tests:**
- Take 10 real (request, response, receipt) triples from `test/integration/testdata/` (or generate fresh by running a local v1.6 provider). For each: canonical-prompt-hash MUST match `receipt.prompt_hash`; canonical-output-hash MUST match `receipt.output_hash`.
- Buyer-flexibility test: same request with extra OpenAI fields the buyer didn't read (e.g. `stream: false` made explicit) MUST still produce the same hash — absent + present-as-default are equivalent under canonicalization.
- Pretty-printed vs minified JSON input: same canonical hash.
- Unicode NFC test: input message with mixed NFC/NFD characters canonicalizes to NFC and produces stable hash.
- `tool_calls` with various shapes (no calls, one call, multiple calls).

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_4_PROMPT.md` — focus: cross-language fidelity, edge cases in tool-call canonicalization, the "raw buyer capture" promise from §10.4.1.

**Done when:** End-to-end test combining Step 3 (parser) + Step 4 (canon) against real receipts produces matching hashes.

---

### Step 5 — Cache + pubkey resolver

**Branch:** `impl/spec-015-v0-2-step-05`  
**Module:** `phase7-verify/internal/cache/` and `phase7-verify/internal/resolver/`  
**SPEC reference:** §10.2, §10.2.1, §10.5, §10.7

**What lands:**
1. **Cache** (`internal/cache/`):
   - On-disk file format: JSON-Lines at `~/.config/macprovider/verify-cache.jsonl` (XDG-respecting; create dir if missing). Each line is a cache entry:
     ```json
     {"coordinator_host":"...","provider_id":"...","receipt_pubkey":"...","receipt_pubkey_prev":null|{...},"fetched_at":"<RFC3339>"}
     ```
   - Atomic write: temp file + `os.Rename`. Crash-safe.
   - 7-day TTL check on read; entries older than 7 days return `(entry, isStale=true)`.
   - Stale handling per §10.2: a stale entry MAY be returned to the caller, but the resolver MUST treat it as needing fresh fetch; if live fetch fails, stale cannot produce `valid` (returns `inconclusive`).
2. **Resolver** (`internal/resolver/`):
   - HTTP client: `http.Client` with `Timeout: 5*time.Second`, no retries.
   - Custom `CheckRedirect`: only follow redirects whose Location host matches the configured coordinator host; redirect to different host → error → fetch failure.
   - `func Resolve(provider_id string, explicit *Pubkey, offline bool, coordinator string) (ResolvedRoot, error)` — implements §10.2 three-source priority.
   - `ResolvedRoot` carries: `(Pubkey, PubkeyPrev, RotatedAt, ExpiresAt, TrustSource, CoordinatorHost, Warnings)`.
   - Warnings: emit `live_check_skipped` (with reason enum), `explicit_vs_live_divergence`, `non_default_coordinator` per §10.4.2.
   - Explicit pubkey → still attempts background live fetch in non-offline non-quiet mode for divergence check.
3. Rate-limit/429 handling: on 429 with `Retry-After`, treat as fetch failure for THIS verification; do NOT retry within the invocation.

**Tests:**
- Cache write→read round-trip preserves all fields incl. RFC3339 timestamps.
- Atomic-write: kill the process mid-write (simulated via fault injection on the temp file), assert cache file is either old or new, never corrupted partial.
- Stale entry detection: write entry with `fetched_at = now - 8d`, read returns `isStale=true`.
- Resolver: explicit pubkey wins; cache hit (fresh) used when no explicit; cache miss → live fetch.
- Live 404 → `inconclusive` with `provider_id_not_in_pool`.
- Live unreachable → if no cache, `inconclusive`; if stale cache, `inconclusive` (NOT `valid`, per §10.2 round-1 S3 fix).
- Live success populates cache.
- Cross-host redirect → fetch failure.
- `--coordinator` env var override works.
- AC-26: stale entry + reachable live fetch triggers HTTP GET; assert call made.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_5_PROMPT.md` — focus: cache file race conditions, redirect bypass attempts, "no network beyond /v1/receipt-keys" invariant (no DNS calls for telemetry, no retries, no version-check beacons).

**Done when:** 0 CRITICAL/MAJOR; manual smoke: hit a real `coordinator.malibu.tech` `/v1/receipt-keys/<id>` after Step 0 ships, parse response, populate cache.

---

### Step 6 — Verification algorithm

**Branch:** `impl/spec-015-v0-2-step-06`  
**Module:** `phase7-verify/internal/verify/`  
**SPEC reference:** §10.0, §10.1, §10.2.1, §10.6

**What lands:**
1. `func Verify(input VerifyInput, opts VerifyOpts) VerifyResult` — runs the §10.0 9-step algorithm.
2. `VerifyResult` has: `Result` (enum valid/invalid/inconclusive), `Reason` (enum from §10.4.2), `Details` (only for invalid), `Warnings`, `TrustSource`, `CoordinatorHost`, `ProviderID`, `ModelID`, `SignedAt`.
3. Tri-state logic per §10.1:
   - `valid`: signature checks AND canonical hashes match AND pubkey resolved to trusted source.
   - `invalid`: signature fails OR canonical hash mismatches OR resolver returned authoritative no-match OR previous-key outside grace window.
   - `inconclusive`: live unreachable + no cache; OR 404 from §10.7 (`provider_id_not_in_pool`); OR stale-cache + live-fail.
4. Rotation-grace check (§10.2.1): when receipt's `provider_pubkey` matches `receipt_pubkey_prev.pubkey`, require `rotated_at - 60s ≤ unix_ts ≤ expires_at`. Otherwise `invalid` with `previous_key_outside_grace_window`.
5. Strict no-scan rule: never iterate over all known pubkeys; only consider the resolved pubkey for the resolved provider_id.

**Tests (these map 1:1 to AC-18..AC-27):**
- **AC-18:** valid path: fresh receipt + matching prompt/response + resolver returns issuing pubkey → exit 0, result valid.
- **AC-19:** flip byte in response.choices[0].message.content → exit 1, result invalid, reason `output_hash_mismatch`, details.field `output_hash`.
- **AC-20:** flip char in request.messages[0].content → exit 1, result invalid, reason `prompt_hash_mismatch`.
- **AC-21:** mutate base64-decoded tuple byte → exit 1, result invalid, reason `signature_verify_failed`.
- **AC-22:** mock resolver unreachable + no cache + no `--pubkey` → exit 2, inconclusive, warnings entry `live_check_skipped` reason `network_unreachable`.
- **AC-23:** `--offline --pubkey <p> --provider-id <id>` + valid bundle → exit 0, valid, ZERO network traffic (assert via mock that no HTTP attempt made).
- **AC-24:** JSON-mode output validates against JSON Schema; schema published as release artifact.
- **AC-25:** each of 0/1/2/64/65 reachable by a concrete documented invocation.
- **AC-26:** cache entry with `fetched_at = now-8d` triggers live fetch; assert HTTP call made.
- **AC-27:** receipt signed by previous key within grace window AND prev key in `/v1/receipt-keys` response → valid; same key but `unix_ts > expires_at` → invalid with `previous_key_outside_grace_window`.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_6_PROMPT.md` — focus: tri-state distinctness (no path collapses inconclusive into valid), grace-window boundary correctness, no-scan invariant enforcement.

**Done when:** all 10 ACs pass via the test suite.

---

### Step 7 — CLI: flags, modes, exit codes

**Branch:** `impl/spec-015-v0-2-step-07`  
**Module:** `phase7-verify/internal/cli/` and `cmd/macprovider-verify/main.go`  
**SPEC reference:** §10.4, §10.4.1, §10.4.3, §10.4.4

**What lands:**
1. Flag parsing (`flag` stdlib or hand-rolled): `--receipt`, `--prompt-hash`, `--output-hash`, `--bundle`, `--pubkey`, `--provider-id`, `--json`, `--offline`, `--quiet`, `--coordinator`, `--explain`, `--help`, `--version`.
2. Environment: `MACPROVIDER_COORDINATOR` overrides default when `--coordinator` not supplied.
3. Three input modes per §10.4: header+hashes, bundle, stdin (`-`).
4. Bundle parser: strict mode — reject unknown top-level keys (exit 65). Validate `bundle_version: 1`; any other value → exit 65. Validate required fields.
5. Provider-id requirements (CF7 strict contract): in header+hashes mode without `--pubkey`, `--provider-id` is required; if missing AND not derivable from bundle/single-match cache → exit 64 with usage error message naming `--provider-id`.
6. Mutual exclusion validation: `--bundle` + `--receipt` together → exit 64.
7. Exit codes per §10.4.3 table — 0/1/2/64/65 strictly. Pipeline-friendly.

**Tests (covering §10.4.4 matrix):**
- Every row of the §10.4.4 flag matrix has a corresponding test.
- AC-25 — each of 0/1/2/64/65 reachable.
- `MACPROVIDER_COORDINATOR=https://other.example` works.
- Bundle stdin mode: `cat bundle.json | macprovider-verify -` parses correctly.
- Invalid bundle JSON → exit 65.
- Bundle with `bundle_version: 99` → exit 65.
- `--unknown-flag` → exit 64.
- `--pubkey` with malformed base64 → exit 64 (flag-value-format error).
- Bundle with extra top-level key → exit 65.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_7_PROMPT.md` — focus: flag interaction edge cases, exit-code boundary correctness (every 64-vs-65 case in §10.4.3), strict-mode bundle rejection.

**Done when:** every cell of §10.4.4 matrix has a passing test.

---

### Step 8 — Output formatting (human + JSON)

**Branch:** `impl/spec-015-v0-2-step-08`  
**Module:** `phase7-verify/internal/cli/output.go`  
**SPEC reference:** §10.4.2, §10.6

**What lands:**
1. JSON-mode output: emit exactly one line of JSON per the §10.4.2 field table. Use `encoding/json` with a strict struct; do not let unknown fields leak in.
2. Human-mode output: one-line summary per the §10.4.2 examples. Include `trust=<source>@<host>` when source is live/cache.
3. `warnings[]` array with the four warning kinds (`explicit_vs_live_divergence`, `live_check_skipped`, `non_default_coordinator`, `clock_skew`). Emit per §10.4.2 — `--quiet` suppresses stderr emission of warnings, NOT the JSON `warnings[]` record.
4. `--explain` flag: after `valid` result, print §10.6 verbatim to stderr (literal text embedded as a Go string constant, sourced from `specs/SPEC-015-receipts.md`).
5. JSON Schema document at `phase7-verify/schemas/output.schema.json` — covers all three result types with required/optional dispositions. This is the AC-24 published artifact.

**Tests:**
- AC-24: `--json` output validates against `output.schema.json` for each result type across `testdata/*.bundle.json` fixtures.
- `--quiet --json`: stderr empty; JSON still includes `warnings[]`.
- `--explain` after valid: §10.6 text appears on stderr; exit code still 0.
- Non-default coordinator: `non_default_coordinator` warning emitted in both modes.
- Clock skew >24h: `clock_skew` warning emitted; result is NOT downgraded.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_8_PROMPT.md` — focus: JSON Schema completeness (does it accept every legal output? does it reject every illegal one?), `--quiet` semantics correctness.

**Done when:** AC-24 schema gate passes.

---

### Step 9 — End-to-end fixtures + integration test

**Branch:** `impl/spec-015-v0-2-step-09`  
**Module:** `phase7-verify/testdata/`, `phase7-verify/integration_test.go`

**What lands:**
1. Golden bundle fixtures in `testdata/`:
   - `valid_fresh.bundle.json`
   - `valid_prev_key_in_grace.bundle.json`
   - `invalid_tampered_output.bundle.json`
   - `invalid_tampered_prompt.bundle.json`
   - `invalid_tampered_unix_ts.bundle.json`
   - `invalid_pubkey_not_endorsed.bundle.json`
   - `invalid_prev_key_outside_grace.bundle.json`
   - `inconclusive_resolver_404.bundle.json`
   - `inconclusive_stale_cache_live_fail.bundle.json`
   - `malformed_bundle.json` (exit 65)
   - `malformed_receipt.bundle.json` (exit 65)
2. Mock `/v1/receipt-keys` HTTP server in `integration_test.go` — serves `/v1/receipt-keys/{id}` from a fixture map.
3. End-to-end test boots mock server + runs the real compiled binary against each fixture, asserts result/exit-code/JSON-schema-validation/warnings shape.
4. CI job runs the integration test in <60 seconds.

**Tests:** every fixture has a corresponding expected outcome documented in `testdata/EXPECTED_RESULTS.md` and asserted by the integration test.

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_9_PROMPT.md` — focus: fixture coverage completeness, fixture generation reproducibility (can a v0.3+ implementer regenerate from a v1.6 provider?), absence of "implementation noise" in fixtures (every field matters).

**Done when:** integration test passes in CI; fixture-generation script documented in `testdata/README.md`.

---

### Step 10 — Release artifacts + final acceptance

**Branch:** `impl/spec-015-v0-2-step-10`  
**Module:** `phase7-verify/`, `.github/workflows/release.yml`

**What lands:**
1. Release pipeline: GitHub Actions workflow producing `macprovider-verify-<version>-darwin-arm64`, `-darwin-amd64`, `-linux-amd64` on tag push.
2. JSON Schema document `phase7-verify/schemas/output.schema.json` (already built in Step 8) attached to release artifacts (AC-24 release-addressable schema).
3. Top-level `phase7-verify/README.md` for buyers: install instructions, version compatibility table (`macprovider-verify v1.x verifies SPEC-015 v0.2.x receipts`), one-command quickstart.
4. Version constants — `phase7-verify/internal/version.go`:
   ```go
   const BinaryVersion = "1.0.0"
   const MaxSPECVersion = "0.2.4"
   ```
   `--version` output: `macprovider-verify 1.0.0 (verifies up to SPEC-015 v0.2.4)`.
5. SDK compat verification: ensure the OpenAI Python SDK still works end-to-end against the live gateway (no regression in receipt-header forwarding from PR #123). One test invocation documented in `phase7-verify/integration_test.go`.

**Final acceptance (run all of these):**
- All 10 ACs (AC-18..AC-27) pass in `phase7-verify` CI
- JCS parity gate (Swift↔Go) passes
- Cross-service integration test still passes (no regression)
- README.md "Roadmap" section updated to remove the "planned, not yet implemented" caveat on receipts (or at least update it to reflect v0.2 verification shipping)
- `beta/DECISION_CRITERIA.md` Entry XX appended: SPEC-015 v0.2.4 LOCKED + IMPL shipped + audit-round counts
- `phase7-verify/README.md` lists every CLI flag with documented semantics

**Audit prompt:** `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_10_PROMPT.md` — final integration-acceptance audit. Focus: release-artifact reproducibility, version-compat table correctness, README accuracy.

**Done when:** Final PR opens with the bundle (SPEC v0.2.4 + IMPL steps 0-10).

---

## PR grouping (recommended)

Use these PR groups, all targeting `spec/015-receipts-v0-2` initially, then rebased onto `main` for the final bundle:

- **PR A: Step 0 — coordinator endpoint (SPEC-002 v1.5 candidate absorption).** Lands the buyer-safe `/v1/receipt-keys/<provider_id>` route. Reviewable separately because it's the locked-spec-adjacent change.
- **PR B: Steps 1-2 — module scaffold + JCS port.** Foundations; reviewable as a unit.
- **PR C: Steps 3-4 — receipt parsing + canonicalization.** The crypto-adjacent layer.
- **PR D: Steps 5-6 — resolver + verification algorithm.** The core verifier logic + AC-18..AC-27 tests.
- **PR E: Steps 7-8 — CLI surface + output formatting.** The buyer-facing layer.
- **PR F: Steps 9-10 — fixtures + release pipeline + final acceptance.** Closes the loop.

After all PRs A-F merge to `spec/015-receipts-v0-2`: rebase onto `main` and open the FINAL PR targeting `main` that bundles SPEC + all IMPL commits. The final PR is the only thing main sees.

## Acceptance / lock gate

Before opening the final PR to `main`:

1. All of AC-18 through AC-27 pass in CI.
2. JCS Swift↔Go parity CI gate passes.
3. Cross-service integration test passes (no v0.1.3 regression).
4. JSON Schema document validates every result-type output across every fixture.
5. Binary builds clean for darwin/arm64, darwin/amd64, linux/amd64 with zero external Go modules in `go.sum`.
6. `phase7-verify/README.md` is buyer-comprehensible (passes a colleague-read-it-cold check).
7. `beta/DECISION_CRITERIA.md` entry appended.

## Final deliverables when you're done

1. A pushed final PR to `main` containing SPEC-015 v0.2.4 LOCK commits + IMPL Steps 0-10 + decision-log entry, all squash-merge-ready.
2. `phase7-verify/macprovider-verify` binary buildable from source on macOS arm64.
3. Audit transcripts: `specs/AUDIT_SPEC_015_v0_2_IMPL_STEP_<0..10>_PROMPT.md` and any `R<n>_PROMPT.md` re-audit prompts, plus the corresponding audit reports in `specs/SPEC-015-v0-2-impl-audit.md`.
4. JSON Schema artifact at `phase7-verify/schemas/output.schema.json` published alongside the release binary.
5. README updates closing the "planned, not yet implemented" caveat on receipts.

## What you must NOT do

- Do NOT change the v0.1.3 wire contract (`X-MacProvider-Receipt` header bytes, JCS rules, the 7-field tuple, the prompt/output canonical shapes). The verifier MUST verify EXISTING receipts byte-for-byte. Any change to the wire contract requires v0.2 SPEC revision, which is out of scope here.
- Do NOT add any external Go module to `phase7-verify/go.sum` beyond stdlib. (Exception: `golang.org/x/text/unicode/norm` for NFC if the Step-2 audit approves it; otherwise hand-port.)
- Do NOT make the verifier scan across providers by pubkey bytes. The `provider_id`-addressed resolver + no-scan rule is normative per §10.2; violating it is a CRITICAL audit finding.
- Do NOT collapse `inconclusive` into `valid` or `invalid` anywhere. The tri-state is normative.
- Do NOT skip the audit loop on any Step. Codex round-1 on v0.2 SPEC found 6 CRITICAL findings — the IMPL surface is similarly likely to surface real issues, and the audit catches them cheap.
- Do NOT implement v0.3 features (bulk verification, receipt explorer, model-hash binding, TUF-style signed `/v1/receipt-keys`, HSM trust roots, SDK integrations). These are explicitly deferred per SPEC-015 §15 and §10.7.
- Do NOT modify `phase3-binary`, `phase5-gateway`, or `phase6-*` code beyond Step 0's coordinator endpoint addition. v0.2 is a pure additive layer; existing modules stay untouched.

## Operator-pending items to anticipate (not in this BUILD scope)

- **Pearl VPS coordinator deployment:** after Step 0 lands, the `/v1/receipt-keys/<provider_id>` endpoint must be deployed to the production coordinator (`coordinator.malibu.tech`). This is an operator step, not a BUILD step.
- **nginx route exposure:** the buyer port nginx config must route `/v1/receipt-keys/*` through to the coordinator. Check `nginx.conf` placement when Step 0 is reviewed.
- **Public binary distribution decision:** GitHub Release vs Homebrew tap vs both. v0.2 ships GitHub Release only per BUILD prompt; Homebrew tap is deferred to v0.3.
- **README/docs updates:** the "verifiable inference" claim at README line 22 can finally drop its "planned, not yet implemented" caveat once v0.2 ships. Operator decision on exact wording.

---

**You're not done when the code compiles. You're done when every AC passes, the audit loop closes at 0 CRITICAL/MAJOR per step, the final PR opens against `main`, and a buyer who has never read this prompt can run `macprovider-verify --bundle <real-bundle>` against a real provider's receipt and get a deterministic verdict.**
