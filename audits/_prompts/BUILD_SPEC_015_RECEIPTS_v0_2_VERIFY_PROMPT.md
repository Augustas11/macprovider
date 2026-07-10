# BUILD_SPEC_015 — Receipts v0.2: buyer-side verification CLI (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing anything.**

Your job is to bump `specs/SPEC-015-receipts.md` from **v0.1 (locked, issuance-only)** to **v0.2** by appending a normative section for **buyer-side receipt verification** and writing the implementation BUILD prompt for the verify CLI.

This work is downstream of SPEC-015 v0.1 (issuance). Do NOT start until v0.1 is locked and merged on `main` — verify the change-log entry for v0.1 exists at the top of the file before you touch it.

## Why this exists (read first)

SPEC-015 v0.1 defines receipt **issuance**: every response carries `X-MacProvider-Receipt`, an ed25519 signature over a canonical 7-field tuple. v0.1 makes the receipt *exist*. It does not yet let a buyer prove it.

v0.2 closes that gap. After v0.2 lands, a buyer can run:

```
macprovider verify <receipt>
```

and get a deterministic yes/no answer that the response they hold was actually signed by the provider that claimed to serve it. Without v0.2, receipts are signed-but-unchecked headers — the cryptographic equivalent of marketing.

The thesis-buyer (long-running personal agents, dev workflows, privacy-sensitive tooling per `README.md`) doesn't get *any* differentiating verifiability until this ships. v0.1 is the contract; v0.2 is the verification.

## Repo conventions you MUST honour

Same as for v0.1 — re-read `specs/BUILD_SPEC_015_RECEIPTS_v0_1_PROMPT.md` §"Repo conventions you MUST honour" if you haven't. In particular:

- Line 3 of `specs/SPEC-015-receipts.md` is the version of record. v0.2 means the line reads `**Version:** 0.2 (YYYY-MM-DD, ...)`.
- Append a new `**Change log v0.2:**` block at the top of the change log section (newest first). State exactly what landed and which findings (if any) it closes.
- Bump the `**Depends on:**` line only if v0.2 newly depends on a SPEC v0.1 didn't.
- House voice: terse, normative, MUST/SHOULD/MAY per RFC 2119.

## What v0.2 MUST normatively add to SPEC-015

### §V (new) — Verification semantics

A buyer who holds a receipt `R` and an output payload `O` (and the corresponding request `Q`) MUST be able to determine one of three deterministic results:

| Result | Meaning |
|---|---|
| `valid` | Signature checks, canonicalization matches, pubkey resolves to a known provider |
| `invalid` | Signature does NOT check, OR canonicalization mismatch, OR known-bad pubkey |
| `inconclusive` | Pubkey could not be resolved (e.g., `/poolz` unreachable AND no cached pubkey) — verifier MUST NOT report `valid` in this case |

`inconclusive` is a first-class result, distinct from `invalid`. State this MUST. A verifier that collapses `inconclusive` into either of the others is non-conforming.

### §V.1 — Pubkey resolution

The verifier MUST resolve the provider pubkey via one of the following sources, in priority order:

1. A pubkey passed explicitly by the caller (`--pubkey <base64>` or equivalent) — for offline / air-gap verification
2. A locally-cached pubkey for the `provider_id` referenced in the receipt's `provider_pubkey` (cache TTL: define in v0.2)
3. A live fetch from `/poolz/<provider_id>` or the extended `/poolz` JSON per SPEC-015 v0.1 §X

Define exactly what TTL the local cache has and what cache invalidation looks like when a provider rotates keys (SPEC-015 v0.1 §"Provider keypair lifecycle" defines the rotation grace window — match it).

Define what happens when source (1) is provided but disagrees with source (3): the explicit pubkey wins (offline-first), but the verifier MUST emit a warning in non-quiet output that the live pubkey differs.

### §V.2 — Canonicalization parity

The verifier MUST use the **bit-identical** canonical encoding rules pinned in v0.1 §"Canonicalization." Re-state the dependency explicitly: any v0.2-compliant verifier that diverges from v0.1's canonicalization is non-conforming.

Be opinionated about one specific failure mode: if a buyer's tool re-pretty-prints JSON output before passing it to `macprovider verify`, the JCS canonicalization will reproduce the same bytes the provider hashed. State this in §V.2 so implementers don't add a "be lenient" mode that defeats the whole point.

### §V.3 — Inputs and outputs

The verifier MUST accept at least these input shapes:

1. **Header-only mode:** `macprovider verify --receipt <base64>` plus `--prompt-hash <hex> --output-hash <hex>` etc., for callers who already have the hashed values
2. **Bundle mode:** `macprovider verify --bundle <path.json>` where the bundle is a single JSON file containing the receipt + the prompt + the output, exactly as the buyer holds them
3. **Stdin mode:** `cat bundle.json | macprovider verify -` for pipelines

Define the exact JSON shape of the bundle. Suggested fields: `receipt` (base64), `request` (the OpenAI-shape `messages` array), `response` (the OpenAI-shape completion or stream-replay), `provider_id` (optional, allows pubkey resolution).

Output MUST support at least two modes:

1. **Human mode (default):** one-line summary + exit code 0/1/2 for valid/invalid/inconclusive
2. **JSON mode:** `--json` outputs a structured result with `result`, `reason`, `provider_id`, `model_id`, `signed_at`, and (if invalid) a `details` block explaining which field mismatched

Exit codes MUST be:
- `0` → valid
- `1` → invalid (signature/canonicalization)
- `2` → inconclusive (pubkey unreachable)
- `64` → usage error (per `sysexits.h`)
- `65` → input format error (malformed bundle/receipt)

State these exit codes normatively. Scripts will rely on them.

### §V.4 — Network behaviour

The verifier MUST NOT make any network call beyond `/poolz` for pubkey resolution. State this normatively — no telemetry, no opt-in analytics, no version-check beacon. A buyer running `macprovider verify` on an air-gapped Mac with a cached pubkey MUST get a deterministic result with zero network traffic.

Define the timeout for the `/poolz` fetch and the retry policy. v0.2 floor suggestion: single attempt, 5-second timeout, no retries — if the buyer wants offline-first behaviour they use `--pubkey` or pre-populate the cache.

### §V.5 — Trust boundary statement

State explicitly: the verifier proves that **a holder of the provider's private key signed this tuple at the claimed timestamp**. It does NOT prove:
- That the response was actually generated by the model named in `model_id` (model-hash binding is deferred to SPEC-011 integration in a future SPEC-015 v0.3)
- That the timestamp is honest (defer to v0.3+ if the audit loop surfaces a need)
- That no other party also saw the response (privacy properties are SPEC-008 / Cluster E territory)

Be brutally clear about this. A buyer who reads `valid` should know exactly what they got and didn't get.

### §V.6 — Acceptance criteria (extend existing v0.1 AC numbering)

Add ACs for:
- `valid` path with a freshly-issued receipt and matching prompt/output
- `invalid` path with a tampered output (single byte flipped in the response)
- `invalid` path with a tampered prompt
- `invalid` path with a tampered timestamp
- `inconclusive` path with `/poolz` unreachable and no cached pubkey
- Offline `--pubkey` path producing `valid` without network access
- JSON-mode output matching the documented schema
- Exit-code semantics (each of 0/1/2/64/65)
- Cache-TTL behaviour (expired cache + reachable `/poolz` → fresh fetch)
- Rotation-grace behaviour (old pubkey from cache + receipt issued during grace window → `valid`)

Each AC should reference a concrete test command an implementer can run.

## What v0.2 MUST explicitly defer (do not creep)

- **Bulk / batch verification** (`macprovider verify-all <dir>`). v0.2 is single-receipt only.
- **Receipt explorer / inspection UI** (`macprovider explain <receipt>` showing decoded fields without signature check). Defer to v0.3.
- **Model-hash binding integration.** When SPEC-011 enforcement flips on and `model_hash` becomes a receipt field, v0.3 will extend verification. Reference SPEC-011 explicitly and say v0.3.
- **HSM / Yubikey / hardware-backed buyer trust roots.** Defer.
- **Cross-provider chain verification** (relevant once Cluster F sharding lands). Defer.
- **`/poolz` signing / TUF-style trust root.** Open question Q1 from v0.1 — escalate to v0.3 if the v0.2 audit loop closes on it. Do not invent it in v0.2.
- **Buyer-side SDK integration** (the Python / TypeScript SDKs from Cluster C #6 / #7). The CLI is the v0.2 normative contract; SDKs wrap it as a separate work item.

## CLI implementation contract (this goes into the BUILD prompt, NOT into SPEC-015 itself)

Once SPEC-015 v0.2 is locked, the implementation BUILD prompt MUST pin:

### Binary location and name

- Standalone Go binary at `phase7-verify/cmd/macprovider-verify/` (suggest a new directory; current Go modules live in `phase4-coordinator/` and `phase5-gateway/`). State the rationale: buyer-side tools should not require building the provider/coordinator stack.
- Binary name on disk: `macprovider-verify`. Default install location: `/usr/local/bin/`.
- Distribution: GitHub Release artifacts (macOS arm64 + Linux amd64 at minimum). State whether Homebrew tap / `brew install` is in-scope for v0.2 or deferred (recommendation: defer to v0.3, ship binaries first).

### Dependencies

- **Pure-Go, no cgo, no networking libraries beyond stdlib.** The whole point is auditability. `crypto/ed25519` is in stdlib. JCS canonicalization can be done in <300 lines.
- Reuse any existing JCS implementation **only via copy-paste with attribution**, not via Go module import — keeps the verify binary single-package, no transitive dependencies for a buyer to audit.
- License: same as the main repo (verify if the main repo has an explicit LICENSE; if not, this is a precondition to shipping public binaries).

### Versioning

- Verify CLI version is independent of SPEC-015 version. State a compatibility matrix in the BUILD prompt: e.g., `macprovider-verify v1.x` verifies `SPEC-015 v0.2.x` receipts.
- `macprovider-verify --version` prints both the binary version and the highest SPEC version it can verify.

### Tests

- Golden-bundle fixtures committed to the repo: a handful of `testdata/*.bundle.json` files covering each AC path.
- One end-to-end test that boots a tiny mock `/poolz` server and runs the binary against it.
- Negative fixtures (tampered output, tampered prompt, expired pubkey cache) MUST be in `testdata/` so the test suite verifies the binary fails them.

## Files you should read before writing

- `specs/SPEC-015-receipts.md` (v0.1 LOCKED) — this is the contract you're extending
- `README.md` — the thesis statement
- `specs/SPEC-006-buyer-api.md` — house style for a buyer-facing surface
- `specs/SPEC-013-cli-autotune.md` (or whichever spec defines the existing `macprovider` CLI shape) — so the verify CLI doesn't invent flag conventions that disagree with the rest of the CLI
- `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` — the existing JCS implementation, so the Go port stays bit-identical
- `beta/DECISION_CRITERIA.md` — particularly the v0.1 lock entry, for context on what audit findings produced v0.1's shape
- The v0.1 audit transcript (`specs/AUDIT_SPEC_015_*.md` files) — knowing what got *deferred* from v0.1 tells you what might land in v0.2

## Audit-loop discipline (NON-NEGOTIABLE)

Same rule as v0.1, per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-spec-audit-loop-before-pr.md`:

> Freshly-written SPECs go through codex audit → fix → re-audit → loop until 0 CRITICAL/MAJOR BEFORE push/PR.

Workflow:

1. On a fresh branch off `origin/main`, name suggestion `spec/015-receipts-v0-2`, edit `specs/SPEC-015-receipts.md` to bump to v0.2 with the verification section appended. Do NOT push yet.
2. Author `specs/AUDIT_SPEC_015_V0_2_PROMPT.md` — an audit prompt that asks codex to find CRITICAL/MAJOR/MINOR findings against the v0.2 deltas only (do not re-audit v0.1; it's locked).
3. Run the audit. Apply fixes. Bump to v0.2.1 / v0.3 per findings (use semver). Re-audit.
4. Loop until **0 CRITICAL, 0 MAJOR**. Each MINOR either gets fixed or acknowledged in the change log with a `deferred-to-vX` tag.
5. ONLY THEN push and open a PR.

Expect 2-4 audit rounds. v0.2 is a smaller delta than v0.1, so fewer findings — but the audit will hammer on:
- Whether `inconclusive` is genuinely distinct from `invalid` or just a fancy alias
- Whether the offline `--pubkey` mode has a clear threat model
- Whether the JSON output schema is locked enough that a future v0.3 doesn't break consumers
- Whether the "no telemetry" claim is enforceable or just aspirational

## Implementation BUILD prompt (separate, after SPEC v0.2 locks)

After SPEC-015 v0.2 is LOCKED and merged:

1. Write `specs/BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` — a step-by-step implementation prompt for the verify CLI, in the same shape as `BUILD_SPEC_013_*` if it exists, or `BUILD_PHASE5_PROMPT.md` as a fallback template.
2. Implementation follows the BUILD audit-loop pattern per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-build-audit-loop.md` — every step audited by codex before merging.
3. Implementation MUST NOT begin until v0.2 SPEC is locked. The SPEC is the contract; the BUILD is the code that fulfils it.

## Quality bar

A great v0.2 reads like SPEC-006 §§ 5–7: every verifier behaviour mode has a normative MUST/SHOULD, every output shape has a worked example, every CLI flag has documented semantics. The trust-boundary statement (§V.5) is the section the security audit will scrutinize hardest — be uncompromising about what `valid` does and does not mean.

A bad v0.2 lets `inconclusive` rot into "treat as valid for now," collapses the offline mode into the online mode "for simplicity," or forgets to specify exit codes. The audit loop will catch this; better if you catch it yourself first.

## Final deliverables when you're done

1. `specs/SPEC-015-receipts.md` at v0.2.x that passed the audit loop with 0 CRITICAL/MAJOR
2. `specs/AUDIT_SPEC_015_V0_2_PROMPT.md` plus the audit transcript
3. A pushed branch and an open PR linking the SPEC delta, the audit prompt, and audit results
4. An appended entry to `beta/DECISION_CRITERIA.md` noting SPEC-015 v0.2 LOCKED, what landed, deferred items, audit-round count
5. `specs/BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md` queued up for the implementation session that follows
6. NO implementation code in this session — v0.2 is normative spec only

**You're not done when the spec exists. You're done when the audit loop closes, the PR is open, and the IMPL prompt is staged for the next session.**
