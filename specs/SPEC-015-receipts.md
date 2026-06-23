# SPEC-015 — Verifiable inference receipts

**Version:** 0.2.4 (2026-06-23, buyer-side verification — LOCKED)
**Depends on:** SPEC-001 v1.6, SPEC-002 v1.4 (v1.5 candidate `GET /v1/receipt-keys/<provider_id>` buyer-safe pubkey resolver), SPEC-005 v0.3, SPEC-006 v0.9, SPEC-008 v0.3, SPEC-011 v0.5, SPEC-013 v0.3

**Lock state:** Round-5 codex audit returned `READY TO LOCK` 0/0/0/0 across all three lenses (code, security, architect) on 2026-06-23 — see `specs/SPEC-015-v0-2-audit.md`. Five-round audit history captured 5 CRITICAL + 11 MAJOR + 6 MINOR findings, all resolved. CF6 confirmed round-1 CRITICALs (CF1 trust-root architecture, CF2 time-window validity, CF3 schema strictness) structurally closed, not papered over.

**Change log v0.2.4:**
- Round-4 codex audit fix pass (round 4 verdicts: security
  **READY TO LOCK** maintained; code + architect READY WITH FIX
  PASS, single convergent finding **CF8** flagging two
  stale-wording spots that v0.2.3 missed when adopting the
  strict-CLI contract):
  - **CF8 / C13 / A10 (stale provider-id wording in §10.4.1
    bundle field description and §10.1 HTTP 404 reason):**
    - §10.4.1 `provider_id` field description rewritten to
      align with the §10.4 "Provider-id requirements" strict
      contract — absent bundle `provider_id` falls back to
      `--provider-id` then single-match cache; if neither yields
      a value AND no `--pubkey` is supplied, exit `64` (not
      `inconclusive`). The "MAY produce `inconclusive` if no
      other identification path applies" phrasing is REMOVED.
    - §10.1 HTTP 404 paragraph updated to use `reason:
      "provider_id_not_in_pool"` per the §10.4.2 enum, not the
      now-warning-only `provider_id_unresolvable`.
- All three codex lenses now project to READY TO LOCK on round 5.
  v0.2.4 ships into the combined SPEC + IMPL PR per the
  [[feedback-bundle-spec-impl-one-pr]] convention if round 5
  confirms 0 CRITICAL / 0 MAJOR across all lenses.

**Change log v0.2.3:**
- Round-3 codex audit fix pass against
  `specs/SPEC-015-v0-2-audit.md` round-3 sections (round 3:
  security lens **READY TO LOCK** 0/0/0/0; code + architect
  READY WITH FIX PASS with 3 MAJOR + 1 MINOR converging on a
  single root cause CF7). Findings resolved:
  - **CF7 / C10 / A9 (provider-id absence is BOTH a usage error
    AND an inconclusive result — internal contradiction):** §10.4
    normalized around the strict CLI contract (Option A from the
    round-3 reading). Missing `--provider-id` in header+hashes
    mode without `--pubkey` is now exit code `64` (usage error)
    everywhere — at §10.4 input shapes, §10.4 "Provider-id
    requirements", §10.4.4 flag matrix, and the §10.4.3 exit-code
    table. The `inconclusive` matrix row for that combination is
    replaced with USAGE ERROR. Rationale: the verifier was
    misinvoked (missing essential argument), not failed at
    runtime; this matches the convention for missing `--receipt`
    / `--bundle`. `inconclusive` remains reserved for trust-root
    failures the verifier discovered during execution.
  - **C11 (`live_check_skipped.reason` enum incomplete):** the
    enum in §10.4.2 is extended with `provider_id_unresolvable`
    — emitted when explicit `--pubkey` was supplied AND no
    provider id is recoverable (the verifier can produce `valid`
    against the explicit key but the live divergence check is
    skipped because the resolver cannot be addressed). The
    enum is now `offline_flag` / `network_unreachable` /
    `provider_id_unresolvable`.
  - **C12 (§10.0 algorithm step 5 still pubkey-byte-oriented):**
    §10.0 step 5 rewritten to read "Resolve the trusted pubkey
    for the resolved `provider_id` per §10.2" instead of "for the
    receipt's provider_pubkey bytes." Aligns the algorithm summary
    with the §10.2 no-scan rule.

v0.2.3 is the LOCK candidate. Round 4 pending — target READY TO
LOCK across all three lenses (security is already there). On
clean round 4, v0.2 locks and bundles into the combined SPEC +
IMPL PR per [[feedback-bundle-spec-impl-one-pr]].

**Change log v0.2.2:**
- Round-2 codex audit fix pass against
  `specs/SPEC-015-v0-2-audit.md` round-2 sections (round 2 = 0
  CRITICAL, 4 MAJOR, 3 MINOR across code/security/architect
  lenses; verdict READY WITH FIX PASS on every lens). Findings
  resolved:
  - **CF4 / C7 / S6 (stale `/poolz` wording in §10.1 + AC-18;
    §10.1 ↔ §10.2.1 no-match semantics conflict):** §10.1
    rewritten to (a) eliminate `/poolz` references, (b) reserve
    `inconclusive` for fetch failure / provider_id unresolvable /
    no authoritative resolver answer, and (c) require `invalid`
    when the resolver returns an authoritative provider record
    whose current/previous keys do not match the receipt's
    `provider_pubkey`. AC-18 rewritten to reference
    `/v1/receipt-keys/<provider_id>` and the §10.2.1 grace-window
    semantics.
  - **CF5 / C8 / A7 (`--provider-id` is load-bearing but not
    first-class CLI input):** §10.4 expanded to make
    `--provider-id <id>` a first-class CLI input across all three
    input modes (header+hashes, bundle, stdin). §10.4.4 flag
    matrix gains explicit `--provider-id` rows covering required-
    vs-optional disposition per mode. §10.2 rule on no-provider-id
    `inconclusive` reframed as a normative escape hatch rather
    than an under-specified edge case.
  - **C9 (timestamp format split between Unix seconds and
    RFC3339):** §10.2 cache fields normalized — `fetched_at`,
    `rotated_at`, `expires_at` are stored as RFC3339 UTC strings
    in the cache to match the §10.7 wire shape. The receipt
    `unix_ts` remains Unix seconds (v0.1 wire contract — locked).
    Conversion happens once at the cache-write boundary.
  - **S7 (positive trust-boundary sentence reads like timestamp
    attestation):** §10.6 opening sentence reworded from "signed
    this tuple at the claimed `unix_ts`" to "signed a tuple
    containing the claimed `unix_ts`" to eliminate the
    quotability-out-of-context risk.
  - **A8 (`valid` does not disclaim receipt uniqueness):** §10.6
    "DOES NOT prove" list extended with a sixth bullet — `valid`
    does not prove that no other receipt was issued for the same
    response, or that this was the only provider-side attestation.
    Locks the surface against the same "narrow proof" misreading
    the §10.6 audit surfaces in round 1.

v0.2.2 is the LOCK candidate. If round 3 returns 0 CRITICAL / 0
MAJOR across all three lenses, v0.2.2 ships into the combined
SPEC + IMPL PR per the [[feedback-bundle-spec-impl-one-pr]]
convention.

**Change log v0.2.1:**
- Round-1 codex audit fix pass against
  `specs/SPEC-015-v0-2-audit.md` (round 1 = 6 CRITICAL, 8 MAJOR,
  3 MINOR across code/security/architect lenses; verdict DESIGN
  ROUND NEEDED). Findings resolved:
  - **CF1 / S1 / A1 / C2 (live `/poolz` is operator-only — buyer
    cannot use it as default trust root):** SPEC-015 v0.2.1
    introduces a **SPEC-002 v1.5 candidate annotation** for
    `GET /v1/receipt-keys/<provider_id>` — a public,
    unauthenticated, rate-limited endpoint exposing ONLY the
    receipt-key tuple `(provider_id, receipt_pubkey,
    receipt_pubkey_prev, rotated_at, expires_at)`. §10.2 rewritten
    to make this the default live source instead of operator-only
    `/poolz`. The new endpoint is pinned in §10.7 as a candidate
    annotation following the same parser-optional / additive /
    non-breaking pattern v0.1's three candidates used.
  - **CF2 / S2 (grace-window check missing on
    `receipt_pubkey_prev`):** §10.2.1 rewritten to require the
    receipt `unix_ts` to fall within `[rotated_at - 60s,
    expires_at]` — matching v0.1 AC-11's pre-existing invariant.
    A previous-key match outside the grace window is now `invalid`,
    not `valid`.
  - **CF2 / S3 (stale-cache fallback validates retired keys via
    provider-reported `unix_ts`):** §10.2 stale-cache rule
    rewritten. A stale entry (older than the 7-day TTL) MUST NOT
    produce `valid` — the result is `inconclusive` regardless of
    receipt `unix_ts`. The provider-reported timestamp is no longer
    load-bearing for trust-root validity per §10.6's existing
    posture that timestamp honesty is not proven.
  - **CF3 / C1 / A2 (bundle mode rejects ordinary OpenAI
    captures):** §10.4.1 rewritten to require `request` as the raw
    OpenAI request body as captured by the buyer. Absent §4.2
    optional fields canonicalize as JSON `null` per the locked
    v0.1 §4.2 rule. The "16-field minimum" requirement is
    REMOVED.
  - **C4 (`bundle_version` exit-code contradiction):** §10.4.1 +
    §10.4.3 + AC-25 now agree: unsupported `bundle_version` →
    exit `65` (input format error). §10.4.1 wording corrected.
  - **C3 (JSON output schema is examples, not contract):**
    §10.4.2 now pins a normative field table covering `valid`,
    `invalid`, and `inconclusive`, with required/optional
    disposition, enum values for `result`, `reason`, `details.field`,
    and `trust_source`, and a normative `warnings[]` array for
    explicit-vs-live divergence and non-default-coordinator signals.
  - **C5 (flag interaction matrix under-specified):** new §10.4.4
    pins a flag-interaction matrix covering `--offline`,
    `--quiet`, `--pubkey`, `--coordinator`, `--json`, `--explain`,
    `MACPROVIDER_COORDINATOR`.
  - **S4 (non-default coordinator trust hidden):** §10.4.2
    `trust_source` enum now carries a `coordinator_host` companion
    field whenever the source is live or cache-derived. JSON output
    includes the host explicitly.
  - **S5 (divergence warnings can disappear under `--quiet`):**
    §10.2 + §10.4.2 now require the explicit-vs-live divergence
    check to happen in ALL modes (including `--quiet`) and to be
    recorded in the JSON `warnings[]` array; `--quiet` suppresses
    only stderr emission, not the warning record itself.
  - **C6 (bundle `receipt` placeholder mislabeled):** §10.4.1
    example string corrected to reflect the
    `<base64(JCS(T))>.<base64(SIG)>` wire shape.
  - **A3 (per-provider `/poolz` variant undefined):** removed from
    §10.2; the new `/v1/receipt-keys/<provider_id>` endpoint
    replaces it.
  - **A4 (cache keys lose provider identity):** §10.2 cache now
    keyed by `(coordinator_host, provider_id, receipt_pubkey)`,
    not bare pubkey bytes.
  - **A5 (dep header candidate-only wording):** line 4 deps
    updated to reflect SPEC-002 v1.4 and SPEC-006 v0.9 absorbed
    locked status; new SPEC-002 v1.5 candidate annotation called
    out explicitly.
  - **A6 (AC-24 leaks "IMPL repo" boundary):** AC-24 rephrased to
    name the verifier implementation test suite and release
    artifacts, leaving repository layout to the BUILD prompt.

**Change log v0.2.0:**
- Promotes §10 from "informative; v0.2 normative" to NORMATIVE and
  expands it into six subsections covering the buyer-side
  `macprovider-verify` CLI contract.
  - **§10.1 Result semantics:** pins a three-valued result
    (`valid` / `invalid` / `inconclusive`). `inconclusive` is a
    first-class result; a verifier that collapses it into either
    of the others is non-conforming.
  - **§10.2 Pubkey resolution:** priority-ordered sources
    (explicit `--pubkey` → local cache → `/poolz`), 7-day cache TTL
    matching §7.5.2 rotation grace, explicit-vs-live divergence
    warning, and §10.2.1 rotation-grace behavior covering
    `receipt_pubkey_prev`.
  - **§10.3 Canonicalization parity:** bit-identical to the §3.2 /
    §4 / §5 provider-side rules; explicitly forbids a "lenient"
    verifier mode; mandates a Swift↔Go JCS parity CI gate.
  - **§10.4 Inputs, outputs, exit codes:** header+hashes / bundle /
    stdin input modes; bundle JSON shape pinned in §10.4.1
    (strict-mode rejection of unknown keys, `bundle_version` for
    future evolution); JSON-mode output schema in §10.4.2; exit
    codes 0/1/2/64/65 in §10.4.3 (per `sysexits.h`).
  - **§10.5 Network behavior:** verifier MUST NOT make any network
    call beyond `/poolz`; no telemetry / no analytics / no
    version-check beacon; single GET, 5-second timeout, no retries,
    no redirects beyond operator-named coordinator host.
  - **§10.6 Trust boundary:** uncompromising statement of what
    `valid` does and does not prove. Specifically: NOT model
    attestation (SPEC-011 / v0.3+), NOT timestamp honesty
    (Q4 / v0.3+), NOT privacy properties (SPEC-008), NOT pubkey
    trustworthiness (Q1 / v0.3+). Recommends `--explain` flag
    that prints §10.6 verbatim after a `valid` result.
- Extends §14 acceptance criteria with **AC-18 through AC-27**
  covering: `valid` path on fresh receipts, three tamper-detection
  `invalid` paths (output / prompt / timestamp), `inconclusive` on
  `/poolz` unreachable, offline `--pubkey` path with zero network,
  JSON-mode schema conformance, exit-code reachability, cache-TTL
  refresh, and rotation-grace `receipt_pubkey_prev` acceptance.
- Updates §15 Q4 (timestamp trust): partially addressed by §10.6
  (out of scope for `valid` result); full normative skew-check
  remains v0.3+ candidate.
- v0.1.x §§1-9, §11-13, §14 AC-1..AC-17, §16 README compatibility
  table are UNCHANGED. v0.1.3 issuance contract is preserved
  bit-identically. v0.2 adds the verifier contract on top.

**Change log v0.1.3:**
- Round-3 codex audit fix pass against `specs/SPEC-015-audit.md`
  (round 3 = 0 CRITICAL, 1 MAJOR, 3 MINOR; verdict READY WITH FIX
  PASS). Findings resolved:
  - **M1 (residual streaming normative clauses):** §5.2, §5.3, §5.4
    streaming/cancellation paragraphs and §12 streaming rows are
    now explicitly informative forward-compatibility guidance for
    v0.2+; v0.1.x emits NO receipt on any streaming path
    (regardless of finish_reason). Buyer-disconnect post-completion
    on a non-streaming response continues to receive a receipt
    with normal `finish_reason=stop` semantics — that is not a
    streaming case.
  - **m1 (§8.1 "one new field"):** corrected to "two new fields"
    matching §1.3.
  - **m2 (AC-11 stale "control frame" wording):** rewritten to
    reference reconnect-based rotation acceptance.
  - **m3 (v0.1.1 labels in v0.1.2 prose):** replaced with v0.1.3
    where the clause describes the current contract; v0.1 / v0.1.1
    / v0.1.2 retained only inside changelog and historical-design
    discussion.

**Change log v0.1.2:**
- Round-2 codex audit fix pass against `specs/SPEC-015-audit.md`
  (4 CRITICAL, 4 MAJOR, 2 MINOR; verdict DESIGN ROUND NEEDED).
  Findings resolved:
  - **C1 (`X-MacProvider-Receipt-Pending` unauthorized 2nd X-MacProvider-*
    header):** The pending correlator header is REMOVED. v0.1.2 adds
    exactly ONE buyer-visible response header
    (`X-MacProvider-Receipt`) as the only SPEC-006 v0.9 candidate
    allowlist addition. §6.3 rewritten to be silent on the wire side
    for streaming.
  - **C2 (rotation control frame outside SPEC-001 candidate):**
    The `provider_receipt_public_key_rotate` WS control frame is
    REMOVED. v0.1.2 rotation is via reconnect: the binary closes the
    current WS, generates a fresh keypair, reconnects with the new
    `provider_receipt_public_key` in the existing v2 `auth_request`
    initial-stage frame. The coordinator infers rotation by
    comparing the new pubkey against the previously-known one for
    this `provider_id`. §7.5 rewritten; §7.5.1 (rotate frame schema)
    deleted.
  - **C3 (streaming deferral drifts from BUILD prompt):** v0.1.2
    explicitly narrows the SPEC-015 v0.1.x mission to
    **non-streaming responses only**. Streaming receipts are NOT in
    v0.1.x; they are v0.2+ scope with explicit READMe/mission
    truth-in-advertising guidance. The BUILD prompt's "MUST be
    present, but where" question is answered as "not present in
    v0.1.x; v0.2+ design". §1.1, §1.2, §6, §15 Q5 rewritten.
  - **C4 (contradictory retention MUST/SHOULD):** The §6.3 SHOULD
    permitting bounded server-side retention is REMOVED. v0.1.2
    pins server-side receipt-body persistence as PROHIBITED. A v0.2+
    streaming-receipt design will name its own retention contract
    or use buyer-held-only delivery.
  - **M1 (`/poolz` candidate field count):** §1.3 now explicitly
    names the two SPEC-002 v1.4 candidate fields:
    `receipt_pubkey` and `receipt_pubkey_prev`.
  - **M2 (AC-9 non-executable):** AC-9 dropped from the normative
    list; the byte-equivalence invariant moves to §5.5 informative.
    ACs renumbered 1–17.
  - **M3 (`model_id` verbatim + NFC):** `model_id` is now pinned as
    ASCII-only per SPEC-001 v1.5 §6.4 (which is already
    ASCII-oriented), so NFC normalization is a no-op for
    `model_id`. NFC normalization applies only to natural-language
    strings in messages/output. §3.1, §3.2, §4.2 wording aligned.
  - **M4 (rotation Keychain write race):** v0.1.2 rotation writes
    the new key to Keychain only AFTER coordinator acceptance via
    successful reconnect auth. If the reconnect fails, the binary
    keeps the previous key active. §7.5 rewritten.
  - **m1 (v0.1 changelog mentions SSE):** added a parenthetical
    note on the v0.1 change-log entry that v0.1.1+ supersedes the
    SSE delivery design.
  - **m2 (SPEC-011 §3.8 citation):** corrected to SPEC-011 v0.5
    R-3.8.3 drain semantics.

**Change log v0.1.1:**
- Round-1 codex audit fix pass against `specs/SPEC-015-audit.md`
  (3 CRITICAL, 8 MAJOR, 4 MINOR, 2 QUESTIONS). Findings resolved:
  - **C1 (streaming SDK incompat):** Streaming receipt delivery is
    deferred to v0.x pending a verified OpenAI-SDK-compatible
    encoding. v0.1.1 emits `X-MacProvider-Receipt` on non-streaming
    responses ONLY. Streaming responses are accompanied by a
    `X-MacProvider-Receipt-Pending: <request_id>` response header for
    forward compatibility; the receipt body itself is NOT included in
    the SSE stream in v0.1.1. §6.3 rewritten; §15 Q5 expanded.
  - **C2 (proof-stage auth_request scope):** `provider_receipt_public_key`
    is restricted to the SPEC-001 v1.5 §6.7.1 initial-stage frame
    only. The proof-stage echo is dropped. §7.2 rewritten.
  - **C3 (coordinator ALTER TABLE):** v0.1.1 no longer prescribes
    SPEC-002 storage mechanics. The coordinator MUST surface the
    pubkey on `/poolz` (SPEC-002 v1.4 candidate, unchanged); the
    durable-storage mechanism is named by the future BUILD spec, not
    pinned here. §7.3 and §13 rewritten.
  - **M1 / q2 (prompt-hash field coverage):** the prompt canonical
    object expands from 10 to 16 keys, adding `presence_penalty`,
    `frequency_penalty`, `logit_bias`, `logprobs`, `top_logprobs`,
    `n`. §4.2 updated.
  - **M2 (JCS reuse mismatch):** v0.1.1 names two required additive
    extensions to `RFC8785JCS.swift` — RFC 8785 §3.2.2.3 float
    handling and an explicit NFC normalization step on string inputs.
    §3.2 rewritten.
  - **M3 (grace window mixed time+count):** v0.1.1 uses a single
    7-day time-based grace window; the request-count threshold is
    dropped. §7.5.2, AC-12 updated.
  - **M4 (AC-R8 byte-identity impossible):** AC-8 now requires the
    streaming response carries a pending request_id correlator, not
    byte-identity. AC-9 unchanged on `output_hash`.
  - **M5 (Keychain race):** §7.1 now requires atomic insert-or-load
    on `errSecDuplicateItem`.
  - **M6 (audit event field-list contradiction):** §11 names exact
    four fields once.
  - **M7 (CLI name drift):** the manual rotation flag is now
    `macprovider rotate-key`, matching the BUILD prompt.
  - **M8 (README schema divergence not explained):** new §16.1
    compatibility table.
  - **m1 (RFC 8895):** corrected to WHATWG HTML SSE.
  - **m2 (AC numbering):** AC-R1..R18 → AC-1..18.
  - **m3 (model_id wording):** clarified case-insensitive match,
    verbatim storage.
  - **m4 (README line range):** corrected to 117–128.
  - **q1 (provider_id in tuple):** RESOLVED. Provider identity in
    the receipt is the pubkey itself; `provider_id` remains
    out-of-band via `/poolz`. Rationale added to §3.1.

**Change log v0.1 (historical; SSE delivery design + AC numbering
superseded by v0.1.1/v0.1.2):**
- Initial draft following the design rationale captured in §2.
- Defines the per-response signed receipt: a base64 ed25519 signature
  over a JCS-canonicalized seven-field tuple (`model_id`, `prompt_hash`,
  `output_hash`, `provider_pubkey`, `ttft_ms`, `tokens_out`, `unix_ts`).
- Specifies prompt and output canonicalization, the
  `X-MacProvider-Receipt` wire header for both non-streaming and SSE
  responses, the provider ed25519 keypair lifecycle (Keychain storage,
  publication on the v2 `auth_request` initial-stage frame, manual
  rotation with a grace window), and the v0.1 pubkey trust root
  (`/poolz`).
- Defers model-hash binding to SPEC-011's domain (v0.3+ in this SPEC),
  buyer verification CLI to v0.2, on-chain anchoring outside scope,
  request_id replay binding to Open Q2, and cross-segment route binding
  to Open Q3.
- Acceptance criteria AC-1 through AC-18 are deterministic and
  implementer-verifiable.

---

## 0. Operator-paste invocation block

```
Implement SPEC-015 v0.1. As you work, maintain a running
phase3-binary/implementation-notes.html and (when coordinator/gateway
work begins) phase4-coordinator/implementation-notes.html and
phase5-gateway/implementation-notes.html that capture anything I
should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Scope and mission

SPEC-015 defines **per-response signed receipts** for MacProvider
inference: a small, transport-attached, offline-verifiable proof that
binds the response a buyer received to the provider that produced it,
the prompt that requested it, and a small set of provider-reported
quality signals.

This is the v0.1 normative floor. It pins:

- The receipt tuple and its canonical encoding.
- The signature algorithm.
- The wire transport (HTTP response header on non-streaming
  responses only; streaming responses carry no v0.1.x receipt — see
  §6.3).
- The provider keypair lifecycle (generation, storage, publication,
  manual rotation).
- The v0.1 pubkey trust root.
- Behavior on receipt-issuance failure.

The `README.md` line 22 ("Every response will carry a signed receipt
binding (prompt, output, provider) — verifiable inference, without a
datacenter (planned, not yet implemented)") and the §"Roadmap"
schema block at `README.md:117-128` describe the product surface. As
of v0.1 LOCK, `grep -r receipt phase3-binary phase4-coordinator
phase5-gateway` returns zero implementation; this SPEC is the
contract that closes that gap.

### 1.1 In scope (v0.1.x)

v0.1.x covers **non-streaming chat completions only**. Streaming is
out of scope for v0.1.x; see §1.2 and §15 Q5 for the deferral.

- The receipt tuple and JCS canonical encoding.
- ed25519 signature algorithm and base64 encoding.
- Prompt canonicalization rules.
- Output canonicalization rules (for non-streaming responses; the
  byte-equivalence invariant in §5.5 is forward-compatibility
  guidance for the v0.2+ streaming design but is not testable in
  v0.1.x).
- Tool-call commitment inside `output_hash`.
- The `X-MacProvider-Receipt` HTTP response header value format.
- Receipt-emission preconditions and the explicit omission cases
  (non-streaming responses only).
- Provider keypair generation, macOS Keychain storage, and publication
  on the SPEC-001 v2 `auth_request` initial-stage frame via a new
  parser-optional `provider_receipt_public_key` field annotated as a
  SPEC-001 v1.6 candidate extension.
- Manual key rotation (`macprovider rotate-key`) performed via WS
  reconnect — no new control frames; the rotated pubkey is
  republished on the next `auth_request` initial-stage frame using
  the existing single-field SPEC-001 v1.6 candidate.
- Pubkey trust root: the coordinator's `/poolz` JSON gains exactly
  two per-provider fields: `receipt_pubkey` (current) and
  `receipt_pubkey_prev` (previous, populated for 7 days after
  rotation). This is the SPEC-002 v1.4 candidate annotation.
- Acceptance criteria implementers can mechanically verify.

### 1.2 Out of scope for v0.1.x

SPEC-015 v0.1.x does NOT specify:

- **Streaming chat completions.** Streaming `POST /v1/chat/completions`
  responses do NOT carry receipts in v0.1.x. The round-1 audit C1 + the
  round-2 audit C1/C3 surfaced that the OpenAI Python and JavaScript
  SDKs JSON-parse every non-`[DONE]` SSE `data:` payload and that
  v0.1's proposed terminal `event: receipt` block would raise on a
  base64 receipt string. v0.1.2 chose to narrow the v0.1.x mission
  to non-streaming receipts rather than introduce a second
  buyer-visible header (which would itself exceed the SPEC-006 v0.9
  candidate scope). Streaming receipts are v0.2+; the design space
  is summarized in §15 Q5. README and operator-facing copy MUST be
  honest that v0.1.x receipts only cover non-streaming requests.
- **Buyer verification CLI.** `macprovider verify <receipt.json>` is a
  separate work item tracked as v0.2. v0.1 issues receipts; v0.2
  verifies them. State of v0.2: not started; this SPEC will bump to
  v0.2 with the verifier surface once that work begins.
- **Model-hash binding.** Whether the receipt commits to which
  *weights* ran (sha256 of the loaded model) is SPEC-011's territory.
  SPEC-011 v0.5 §3.3.1 already specifies provider-reported
  `heartbeat.model_hash` (raw 64-character lowercase hex). Folding
  that into the receipt tuple — so a buyer can verify "which weights
  served me" — is deferred to SPEC-015 v0.3+ contingent on
  SPEC-011's catalog-signing posture (operator decision per
  `beta/DECISION_CRITERIA.md` Entry 80, Q3 tier-2 posture). v0.1
  binds *which name was requested* and *what content was produced*,
  not which weights served it.
- **On-chain anchoring.** Periodic Merkle roots of issued receipts
  posted anywhere durable (chain, AntFeed, ENS-published manifest) are
  gated on a Cluster D-tokens go/no-go decision the operator has not
  made. v0.1 says nothing about it.
- **Request-id binding for replay-style verification.** Whether the
  receipt commits to a `request_id` and where the buyer would obtain
  its expected `request_id` is unresolved. See §15 Q2.
- **Multi-segment route binding.** Once Cluster F sharding lands a
  single response may have multiple provider segments; receipt-per-
  segment vs receipt-per-response with embedded route list is
  unresolved. See §15 Q3. v0.1 assumes one provider per response.
- **TUF-style trust-root signing of `/poolz`.** v0.1 acknowledges the
  trust root is operator-mutable (the coordinator publishes the
  pubkey list); strengthening it is v0.3+. See §15 Q1.

### 1.3 Relationship to locked specs

SPEC-001 v1.5 remains the authoritative provider binary and provider
WebSocket protocol. SPEC-015 v0.1 **MUST NOT** edit SPEC-001 v1.5
text; it ANNOTATES one additive, parser-optional field
(`provider_receipt_public_key`) on the v2 `auth_request` initial-stage
frame, marked here as a SPEC-001 v1.6 candidate extension. Until that
candidate field lands in SPEC-001 the field MUST NOT appear on the
wire from a v1.5 binary; the receipt-issuing path on the provider
side is enabled only by a binary at SPEC-001 v1.6 or later. This
mirrors SPEC-008's SPEC-001 v2.0 annotation pattern.

SPEC-002 v1.3.5 remains the authoritative coordinator router spec.
SPEC-015 v0.1.x ANNOTATES exactly two additive, optional response
fields on each `/poolz` provider object — `receipt_pubkey` (current
pubkey) and `receipt_pubkey_prev` (previous pubkey populated only
during the 7-day rotation grace window) — marked here as a single
SPEC-002 v1.4 candidate annotation pair. SPEC-002 §7 surfaces
(`/poolz` shape, internal forwarding) are otherwise unchanged.

SPEC-005 v0.3 remains the authoritative billing/settlement spec.
SPEC-015 v0.1 reuses SPEC-005's effective completion-token accounting
unmodified: `tokens_out` in the receipt is the same `int64` value the
billing path uses for `effective_completion_tokens` per
SPEC-005 §4 derivation. SPEC-015 v0.1 MUST NOT change SPEC-005's
formula, refund matrix, or null-usage error treatment.

SPEC-006 v0.8.3 remains the authoritative gateway buyer-API spec.
SPEC-015 v0.1 adds one buyer-visible response header
(`X-MacProvider-Receipt`) and registers it on the SPEC-006 §17
response-pass-through allowlist as a SPEC-006 v0.9 candidate
extension. SPEC-006 §17 header-strip rules (the gateway strips any
non-allowlisted `X-MacProvider-*` response header) otherwise apply
unchanged. The OpenAI SDK drop-in contract is preserved: the receipt
header is additive metadata; absence does not break SDK clients;
presence does not violate any OpenAI shape because OpenAI clients
ignore unknown response headers.

SPEC-008 v0.3 remains the authoritative Tier-2 trust layer. SPEC-015
v0.1 is orthogonal to SPEC-008. Specifically:

- Receipt issuance is independent of Pillar A model-hash verification
  (SPEC-008 §5.3). A receipt issued under v0.1 makes no claim about
  weight identity; SPEC-008 Pillar A makes that claim separately at
  admission and routing time.
- Receipt issuance is independent of Pillar B encrypted-leg AEAD
  (SPEC-008 §6). The receipt is computed over the cleartext request
  and response as observed at the provider; if the provider-leg is
  later AEAD-encrypted per Pillar B, the receipt is still computed
  over the same plaintext at the provider boundary before encryption.
- Receipt issuance is independent of Pillar C attestation. v0.1's
  trust root for the provider receipt pubkey is `/poolz`. If Pillar C
  is enabled, the attestation token does NOT bind the receipt key;
  v0.3+ MAY re-anchor receipt pubkeys to Pillar C attestations.
- Receipt field names MUST NOT collide with SPEC-008 wire fields.
  This SPEC uses `provider_receipt_public_key` to distinguish from
  SPEC-008 `provider_ecdh_public_key` (`auth_request` initial-stage
  per SPEC-001 v1.5 §6.7.1).

SPEC-011 v0.5 remains the authoritative warm-swap spec. Receipt
issuance MUST observe a model swap: a receipt MUST NOT be emitted for
a response whose model load changed mid-response (SPEC-011 v0.5
R-3.8.3 drain semantics already prevent this, but §7.4 below makes
the invariant explicit on the receipt side).

SPEC-013 v0.3 remains the authoritative `autotune` CLI subcommand
spec. SPEC-015 v0.1 reuses
`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` (added by
SPEC-013) for canonical encoding; no parallel canonicalizer is
permitted.

### 1.4 North-star requirement

A buyer who has fetched a provider's receipt pubkey from `/poolz` MUST
be able to verify, offline, that:

1. The response they hold came from a provider holding that pubkey,
2. The response was bound to a prompt they can canonicalize and hash
   themselves to compare against `prompt_hash`,
3. The output they hold canonicalizes to a digest matching
   `output_hash`,
4. The provider-reported `ttft_ms`, `tokens_out`, and `unix_ts` are
   committed to the signed tuple and cannot be silently revised after
   the fact.

If any of (1)–(4) fails for a verifier that follows §3 canonicalization
correctly, the receipt is invalid and the verifier MUST reject it.

A buyer who does NOT trust `/poolz` (operator-mutable list) MUST
explicitly acknowledge that the v0.1 trust root is the coordinator
operator. v0.3+ stronger roots are §15 Q1.

---

## 2. Design rationale (informative)

The "verifiable inference" tag in the README is the central
differentiator from operator-trusted inference networks. The bar is
not academic ZK-verifiable inference (covered in
`doc/internal/zk-verifiable-inference-design.md` as exploratory) — it
is the minimum mechanism that lets a buyer prove a specific provider
served a specific prompt-output pair.

v0.1's design choices and their justifications:

- **ed25519 over JCS-canonical JSON.** ed25519 keys are small (32-byte
  pubkey, 64-byte signature), signing is fast (~50 µs on Apple Silicon),
  and the algorithm is widely implemented. JCS (RFC 8785) gives an
  unambiguous canonical form for JSON that survives field-order
  permutations and floating-point representation; the in-house Swift
  implementation at
  `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` is
  battle-tested by SPEC-013.
- **Seven-field tuple.** The set was chosen to cover the four
  buyer-observable claims (model name, prompt content, output content,
  provider identity) plus three provider-reported quality signals
  (ttft, output token count, timestamp). It deliberately does NOT
  cover model-hash, request-id, or route — those are scoped to
  v0.3+, v0.2 verification, and Open Q3 respectively.
- **Response header transport.** A header is the lowest-friction
  surface that OpenAI clients tolerate unchanged. Body inclusion was
  rejected: it would force every buyer SDK to learn a new response
  shape and would break OpenAI SDK drop-in (SPEC-006 §C.1).
- **Streaming receipts deferred to v0.2+.** Two rejected designs
  (v0.1 terminal `event: receipt` SSE block and v0.1.1
  `X-MacProvider-Receipt-Pending` correlator header) demonstrated
  that an SDK-compatible streaming receipt transport needs its own
  design pass. v0.1.x explicitly carries no receipt on streaming
  responses; v0.2+ will design the streaming transport. See §6.3
  and §15 Q5.
- **Manual rotation with a time-based grace window.** Auto-rotation
  has operational hazards (key churn, in-flight verification
  failures); v0.1.1 defers it. Manual rotation is a CLI flag; the
  coordinator retains the previous pubkey for **7 days** after the
  new one is published, so receipts that left the provider under
  the old key remain verifiable while a buyer is still polling
  `/poolz`. The v0.1 draft mixed a time threshold with a
  request-count threshold; the round-1 audit M3 flagged the mix as
  unimplementable without a counter contract; v0.1.1 uses time
  only.

---

## 3. Receipt content and canonical encoding

### 3.1 The receipt tuple

Every receipt is a JCS-canonicalized JSON object with EXACTLY the
following seven fields and no others:

| Field | Type | Definition |
|---|---|---|
| `model_id` | string | The buyer-requested model identifier. SPEC-001 v1.5 §6.4 model identifiers are ASCII-only and matched case-insensitively; v0.1.3 inherits this and requires `model_id` strings in the tuple to be ASCII-only. The receipt stores the original buyer-submitted `model` string verbatim (no case-fold). Because the string is ASCII-only, the §3.2 NFC normalization step is a no-op on this field; conformant verifiers MUST reject any receipt whose `model_id` contains a non-ASCII byte. |
| `prompt_hash` | string | Lowercase hex sha256 of the JCS-canonical encoding of the canonical prompt object defined in §4. 64 lowercase hex characters, no `sha256:` prefix. |
| `output_hash` | string | Lowercase hex sha256 of the JCS-canonical encoding of the canonical output object defined in §5. 64 lowercase hex characters, no `sha256:` prefix. |
| `provider_pubkey` | string | Base64 (standard, padded, no URL-safe substitution) of the provider's 32-byte ed25519 public key. Exactly 44 ASCII characters. |
| `ttft_ms` | int64 | Time-to-first-token in milliseconds, measured at the provider from request-accepted to first-output-byte-emitted. Non-negative. For non-streaming responses, this is the full generation latency. |
| `tokens_out` | int64 | Provider-reported output token count, the same `int64` value SPEC-005 §4 names `effective_completion_tokens`. Non-negative. See §7.6 for null-usage and error cases. |
| `unix_ts` | int64 | Provider's response-completion timestamp, Unix seconds UTC. Non-negative. Provider clock; see §15 Q4 for cross-check semantics. |

**Field omissions and extras.** A receipt object MUST contain
EXACTLY these seven keys. Verifiers MUST reject receipts with missing
or extra keys. There are no optional fields in v0.1.

**Why `provider_id` is NOT in the tuple (resolves audit q1).** The
buyer's cryptographic root of trust in the receipt is the
`provider_pubkey` field. The human/operator-facing `provider_id`
ULID is the coordinator's mutable label for that pubkey in `/poolz`
(§8). v0.1's design choice is to bind only the pubkey because:

1. The pubkey is the unforgeable identity for verification — a buyer
   who has fetched `(provider_id, receipt_pubkey)` from `/poolz`
   already trusts that mapping or does not.
2. Including `provider_id` would double-bind to an operator-mutable
   label without strengthening the cryptographic claim.
3. If `/poolz` later strengthens to a TUF-style signed root (§15 Q1),
   the trust upgrade lands on the `/poolz` side without re-signing
   historical receipts.

A v0.x+ MAY revisit this if §15 Q1 trust-root strengthening lands and
the operator wants the receipt to commit to a stable opaque
identifier independent of the pubkey.

**Types.** `model_id`, `prompt_hash`, `output_hash`, and
`provider_pubkey` are JSON strings. `ttft_ms`, `tokens_out`, and
`unix_ts` are JSON numbers that fit in int64. Implementations MUST
serialize them as JSON integers (no decimal point, no exponent) and
verifiers MUST reject any non-integer numeric encoding. JCS already
constrains numeric formatting to a canonical decimal representation;
v0.1 forbids fractional or exponential numerics for these three
fields explicitly.

### 3.2 Canonical encoding for signing

Let `T` be the receipt tuple object. The signing input MUST be
`JCS(T)` as defined by RFC 8785, with the additive profile pinned
below. The implementation reuses
`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` and MUST
extend it with two clearly-named additions:

1. **Object key order:** UTF-16 code-unit lexicographic, per
   RFC 8785 §3.2.3. Already implemented at
   `RFC8785JCS.swift:44-46`.
2. **String escape rules:** RFC 8785 §3.2.2.5. Already implemented
   at `RFC8785JCS.swift:48-75` for U+0000–U+001F, `"`, `\\`, and
   U+FFFD.
3. **NEW (extension required for v0.1.3): NFC normalization on
   natural-language strings.** Every JSON string value entering the
   canonical form that may contain non-ASCII bytes — specifically,
   prompt/output canonical-object string fields per §§4–5 — MUST be
   Unicode-normalized to NFC (Unicode 15.1) BEFORE escape.
   Implementations MUST extend `RFC8785JCS.swift` with a pre-escape
   NFC step using `String.precomposedStringWithCanonicalMapping`.
   Pre-normalized inputs (already NFC) are a no-op. Tuple-level
   string fields (`model_id`, `prompt_hash`, `output_hash`,
   `provider_pubkey`) are ASCII-only by their respective field
   definitions (§3.1), so NFC is a no-op on those fields by
   construction.
4. **NEW (extension required for v0.1.3): JSON number handling for
   floats.** RFC 8785 §3.2.2.3 specifies the canonical decimal
   representation for JSON numbers including IEEE 754 doubles.
   `RFC8785JCS.swift` v1 supports only `int`; v0.1.3 receipt
   implementations MUST extend `RFC8785JCS.swift`'s `Value` enum
   with a `double(Double)` case implementing RFC 8785 §3.2.2.3 (the
   ECMAScript `Number.prototype.toString` derived format). The
   prompt canonical object (§4) contains `temperature`, `top_p`,
   `presence_penalty`, `frequency_penalty` as floats and is the
   driver for this extension.
5. No whitespace, no insignificant separators, no trailing newline.

The signing input is the UTF-8 bytes of `JCS(T)`.

The receipt tuple itself (§3.1) contains only strings and integers,
so the receipt SIGNING step itself does not exercise the float
extension. Floats appear in the §4 prompt canonical object that
feeds `prompt_hash`. Both extensions are MANDATORY for a v0.1.3
conformant provider implementation; an implementation lacking either
MUST NOT emit receipts.

### 3.3 Signature

`SIG = ed25519_sign(provider_receipt_private_key, UTF-8(JCS(T)))`.

`SIG` is exactly 64 bytes. The on-wire encoding is base64 (standard,
padded; no URL-safe substitution) — exactly 88 ASCII characters.

### 3.4 Receipt object on the wire

The full receipt artifact transmitted on the wire is the
JCS-canonical tuple plus the signature. The `X-MacProvider-Receipt`
header value MUST be:

```
<base64(JCS(T))>.<base64(SIG)>
```

That is: standard padded base64 of the UTF-8 bytes of `JCS(T)`,
then a literal ASCII period (`0x2E`), then standard padded base64
of the 64-byte signature. No whitespace, no other delimiters, no
trailing characters.

The two base64 segments are independently decodable so a verifier
can reconstruct `JCS(T)` and check `ed25519_verify(provider_pubkey,
JCS(T), SIG)`. This format was chosen over JWS (compact serialization)
because v0.1 does not need a header (no algorithm agility, no key id
indirection — `provider_pubkey` is in the payload). A v0.x+ may
migrate to JWS once algorithm agility is needed; that migration is
NOT part of v0.1.

**Maximum size.** `JCS(T)` is bounded by the field sizes:
`model_id` ≤ 256 bytes (SPEC-001 v1.5 model-id constraint),
`prompt_hash`/`output_hash` = 64 hex chars each, `provider_pubkey` =
44 chars, three int64 numerals ≤ 20 chars each. With JSON
overhead, `JCS(T)` ≤ 600 bytes; base64 expands by 4/3, so the header
value is ≤ ~830 ASCII bytes. Implementations MUST permit a
generous `X-MacProvider-Receipt` header up to 4096 bytes to leave
headroom for v0.2+ field additions and to avoid edge-case nginx
truncation.

---

## 4. Prompt canonicalization

The `prompt_hash` field commits to the buyer's request. The
canonicalization rule MUST be deterministic across implementations so
a verifier with the same request body produces the same hash.

### 4.1 Source of the prompt

The provider canonicalizes the **request body it received** at the
point of inference, NOT the buyer's original HTTP body. For the v0.1
single-provider routing case (one provider per response, see §1.2)
the gateway-to-coordinator-to-provider forwarding preserves the
relevant fields byte-for-byte; see §4.5 for the normative subset.

### 4.2 The canonical prompt object

The provider MUST construct the canonical prompt object as follows:

```
{
  "model": <request.model>,                          // verbatim string
  "messages": [<canonical_message>, ...],            // see §4.3
  "tools": [<canonical_tool>, ...] | null,           // see §4.4
  "temperature": <float|null>,
  "top_p": <float|null>,
  "max_tokens": <int|null>,
  "stop": <string|array<string>|null>,
  "seed": <int|null>,
  "response_format": <object|null>,
  "tool_choice": <string|object|null>,
  "presence_penalty": <float|null>,
  "frequency_penalty": <float|null>,
  "logit_bias": <object|null>,
  "logprobs": <bool|null>,
  "top_logprobs": <int|null>,
  "n": <int|null>
}
```

A field that is absent from the request body MUST be encoded as JSON
`null` in the canonical prompt object. The object MUST contain
EXACTLY these sixteen keys; no other request fields enter
`prompt_hash` in v0.1.

The sixteen keys are the union of OpenAI chat-completion fields the
provider observes and that materially affect the output distribution
or the response shape. The audit-driven expansion from v0.1's
ten-key list closed the "weak prompt binding" gap surfaced in the
round-1 audit M1: `presence_penalty`, `frequency_penalty`,
`logit_bias`, `logprobs`, `top_logprobs`, and `n` were missing in
v0.1 and could have let two responses differ on sampling while their
receipts hashed identical prompts.

Implementations MUST NOT include OpenAI fields outside this list
(`user`, `stream`, `stream_options`, `store`, `metadata`,
`function_call`, `functions`, etc.) even if the buyer sent them.
v0.1.3 deliberately excludes fields that are non-deterministic on
the provider side (`stream`, `stream_options`) or operationally
noisy (`user`, `metadata`), and excludes legacy aliases
(`function_call`, `functions`) in favor of `tools` and
`tool_choice`. A v0.2+ may widen the subset; verifiers built against
v0.1.3 MUST hash exactly these sixteen keys.

### 4.3 Canonical message object

Each message in `messages` MUST canonicalize to:

```
{
  "role": <string>,                                  // "system" | "user" | "assistant" | "tool"
  "content": <canonical_content>,                    // string or array; see §4.3.1
  "name": <string|null>,
  "tool_call_id": <string|null>,                     // for role:"tool" messages
  "tool_calls": [<canonical_tool_call>, ...] | null  // for role:"assistant" with tool calls
}
```

Each message MUST contain EXACTLY these five keys; fields absent from
the buyer-supplied message are encoded as JSON `null`.

#### 4.3.1 Canonical content

`content` is one of:

- A JSON string (the common case for text-only messages). The string
  MUST be Unicode-normalized to NFC (Unicode 15.1 stabilization). A
  request that contains pre-NFC content (decomposed sequences,
  legacy escapes) is normalized at the provider before hashing.
- A JSON array of content parts, used for OpenAI multimodal-style
  messages. Each part MUST canonicalize to one of:
  - `{"type":"text","text":<nfc-string>}`
  - `{"type":"image_url","image_url":{"url":<string>,"detail":<string|null>}}`
  - `{"type":"input_audio","input_audio":{"data":<string>,"format":<string>}}`
  Each part object MUST contain EXACTLY the keys named for its type.

If the buyer sent `content: null` (legacy OpenAI shape for
assistant tool-call messages), the canonical form is JSON `null`.

#### 4.3.2 Newline and whitespace handling

Within a content string:

- `\r\n` and bare `\r` MUST be normalized to `\n` before NFC.
- Trailing whitespace MUST NOT be stripped. Some prompts legitimately
  end with whitespace and a strip would silently change `prompt_hash`.
- Leading whitespace MUST NOT be stripped, same reason.
- Internal whitespace runs MUST NOT be collapsed.

### 4.4 Canonical tool object

Each tool in `tools` MUST canonicalize to:

```
{
  "type": "function",
  "function": {
    "name": <string>,
    "description": <string|null>,
    "parameters": <json-schema-object|null>
  }
}
```

`parameters` is a JSON Schema object as supplied; JCS canonicalizes
the object recursively. v0.1 does NOT reorder or normalize the
schema beyond JCS's standard sort.

### 4.5 The provider-observed request body

The §4.1–§4.4 fields MUST be passed end-to-end from buyer to provider
without modification. SPEC-006 v0.8.3 §17 already enforces this for
the OpenAI request body (gateway forwards the body verbatim);
SPEC-002 v1.3.5 §5 already enforces it on the coordinator. Receipts
issued under v0.1 inherit this invariant. If a future gateway or
coordinator change rewrites any of the §4.2 fields between buyer and
provider (e.g. coercing `temperature` defaults), receipts will fail
verification against the buyer's raw body — this is a deliberate
detection mechanism, not a bug.

---

## 5. Output canonicalization

The `output_hash` field commits to the output the provider produced.

### 5.1 The canonical output object

The provider MUST construct the canonical output object as follows:

```
{
  "content": <nfc-string>,                           // see §5.2
  "tool_calls": [<canonical_tool_call>, ...] | null, // see §5.3
  "finish_reason": <string>                          // v0.1.x non-streaming: "stop" | "length" | "tool_calls" | "content_filter" | "error" (v0.2+ streaming may add "cancelled")
}
```

The object MUST contain EXACTLY these three keys.

### 5.2 `content`

- For non-streaming responses (the only receipt-bearing path in
  v0.1.x): the full `choices[0].message.content` string as the
  provider produced it, NFC-normalized.
- For responses where the assistant message contains ONLY tool calls
  (no text content), `content` is the JSON empty string `""`.
- For responses with no content emitted at all (e.g., immediate
  error after token allocation), see §5.4.

*Informative forward-compatibility note (v0.2+):* a future
streaming receipt design will need to canonicalize the concatenated
`choices[0].delta.content` chunks. NFC normalization across chunk
boundaries is not associative, so a future v0.2+ design MUST NFC-
normalize the concatenated result once at end-of-stream, not
per-chunk. This guidance is not testable in v0.1.x and binds only
the v0.2+ streaming design.

`\r\n` → `\n` and bare `\r` → `\n` apply, identical to §4.3.2.
No whitespace stripping.

### 5.3 `tool_calls`

If the assistant emitted one or more tool calls, the receipt commits
to all of them inside `output_hash`, not as a separate field. Each
tool call MUST canonicalize to:

```
{
  "id": <string>,
  "type": "function",
  "function": {
    "name": <string>,
    "arguments": <string>      // the JSON-stringified argument blob the assistant emitted, byte-for-byte
  }
}
```

For non-streaming responses in v0.1.x, a single completed tool call
MUST appear with its full `arguments` string. Tool calls MUST appear
in `tool_calls` in the emission order the assistant produced them.

*Informative forward-compatibility note (v0.2+):* the OpenAI SSE
shape emits `choices[0].delta.tool_calls[].function.arguments` as a
partial string across many chunks. A v0.2+ streaming receipt design
MUST concatenate those deltas in emission order to match the
non-streaming `arguments` byte-for-byte. Not testable in v0.1.x.

The `arguments` field is a string, NOT a parsed JSON object. v0.1
deliberately commits to the byte-exact string the assistant emitted
so a verifier can rebuild it from streaming chunks without parsing
hazards. A v0.x+ may add a parsed-object commitment alongside, but
v0.1's `output_hash` covers the string form only.

### 5.4 `finish_reason`

`finish_reason` is the same value SPEC-005 §3 maps to billing
treatment. For v0.1.x non-streaming receipts, `finish_reason` is one
of `"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`, or
`"error"`. When the provider returns SPEC-001 null-usage error
classes (`error_model_not_loaded`, `error_context_exceeded`,
`error_queue_full`, `error_internal`), `finish_reason` MUST be
`"error"` and `content` is the empty string. See §7.6 for the
emission rule in this case.

*Informative forward-compatibility note (v0.2+):* the OpenAI SDKs
treat a buyer disconnect on a streaming response as
`finish_reason="cancelled"`. v0.1.x streaming requests carry no
receipt regardless of `finish_reason`; a v0.2+ design that emits
streaming receipts will need to canonicalize the cancelled case.

### 5.5 The `output_hash` invariant (informative; forward-compat)

v0.1.x receipts cover non-streaming responses only (§6.3). The
canonical output object defined in §5.1–§5.3 is therefore exercised
only by non-streaming output.

For forward compatibility with v0.2+ streaming receipts: when a
v0.2+ design adds streaming receipts, identical output bytes
emitted in streaming and non-streaming modes MUST hash to the same
`output_hash`. v0.1.x §5.2's "concatenated output" guidance is
preserved to support that future invariant; in v0.1.x it has no
testable consequence and is informative.

---

## 6. Wire transport

### 6.1 Header name

The receipt is delivered in the HTTP response as:

```
X-MacProvider-Receipt: <base64(JCS(T))>.<base64(SIG)>
```

The header name `X-MacProvider-Receipt` is NEW in SPEC-015 v0.1.
SPEC-006 v0.8.3 §17 lists `X-MacProvider-Provider`,
`X-MacProvider-Route`, `X-MacProvider-Session`,
`X-MacProvider-Conversation`, `X-MacProvider-Internal-Conv`,
`X-MacProvider-Pref`, `X-MacProvider-Retry`. `X-MacProvider-Receipt`
does not collide. SPEC-006 v0.9 (candidate, deferred to SPEC-015 v0.1
+ SPEC-006 v0.9 absorption) MUST add `X-MacProvider-Receipt` to the
buyer-facing response-pass-through allowlist so the gateway does not
strip it on the buyer hop.

### 6.2 Non-streaming responses

For a non-streaming `POST /v1/chat/completions` (request body
`stream: false` or absent), the provider MUST emit
`X-MacProvider-Receipt` on the inference response. The header value
is set BEFORE the response body is written. The header is forwarded
by coordinator and gateway untouched.

### 6.3 Streaming responses (out of scope in v0.1.x)

v0.1.x DOES NOT issue receipts for streaming
`POST /v1/chat/completions` responses. Provider, coordinator, and
gateway MUST treat a streaming request as receipt-free: no
`X-MacProvider-Receipt` header is emitted; no SSE event is added;
no `data:` payload is altered. The SSE stream's wire shape is
exactly what SPEC-001 v1.5 and SPEC-006 v0.8.3 already specify.

This is a deliberate v0.1.x scope narrowing in response to round-1
audit C1 and round-2 audit C1/C3. Both rounds established that:

- The v0.1 plan to emit a terminal `event: receipt` SSE block is
  incompatible with the OpenAI Python and JavaScript SDKs' stream
  loops (Python: `openai/_streaming.py`; JavaScript:
  `openai-node/streaming.ts`).
- The v0.1.1 plan to emit an `X-MacProvider-Receipt-Pending`
  correlator header introduces a second buyer-visible
  `X-MacProvider-*` response header that exceeds the single-field
  SPEC-006 v0.9 candidate allowlist annotation.
- Embedding the receipt as an extra field on the final
  chat-completion chunk is unverified across SDK versions and
  needs its own SDK-compatibility study.

v0.2+ will design a streaming receipt transport with an
SDK-compatibility ACs. Until then, README and operator-facing copy
MUST disclose that v0.1.x receipts cover non-streaming responses
only. A buyer who needs receipts for streaming traffic in v0.1.x
has two options:

1. Issue the same request non-streaming and verify against a
   pinned `seed` (idempotent if the model is deterministic).
2. Wait for v0.2+ streaming receipt body delivery.

§15 Q5 is the open design question for streaming receipts.

### 6.4 Omission cases

For non-streaming responses, the receipt MUST be omitted (no
`X-MacProvider-Receipt` header) in the following cases:

1. The provider's receipt keypair has not yet been generated (first
   launch before Keychain setup completes). See §7.1.
2. The buyer disconnected before any token was emitted AND the
   provider has no committed `tokens_out` value (`tokens_out: 0` is
   committable; see §7.6).
3. The response was served by a SPEC-001 binary at version `< v1.6`
   (no `provider_receipt_public_key` published).
4. The model swap mid-response invariant is violated (see §7.4) — the
   provider MUST close the response with a 500-class error and MUST
   NOT emit a receipt.
5. The request was streaming. v0.1.x emits no receipts for streaming
   responses (§6.3).

When a receipt is omitted, the provider MUST NOT emit a placeholder,
empty value, or `X-MacProvider-Receipt: omitted` sentinel. Header
absence is the signal.

---

## 7. Provider keypair lifecycle

### 7.1 Generation

On first launch of `phase3-binary serve` at SPEC-001 v1.6 or later,
the binary MUST perform an atomic insert-or-load against macOS
Keychain to obtain its receipt private key:

1. Construct the Keychain query with:
   - `kSecClass = kSecClassGenericPassword`
   - `kSecAttrService = "com.streamvc.macprovider.receipt-key"`
   - `kSecAttrAccount = <provider_id>`
   - `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
   - `kSecAttrSynchronizable = false`
2. Attempt `SecItemCopyMatching` with that query. If a record is
   present, decode the 32-byte raw private key from `kSecValueData`
   and skip to step 5.
3. If `SecItemCopyMatching` returns `errSecItemNotFound`, generate a
   fresh ed25519 keypair using
   `CryptoKit.Curve25519.Signing.PrivateKey.init()` and call
   `SecItemAdd` with the query plus
   `kSecValueData = privateKey.rawRepresentation`.
4. If `SecItemAdd` returns `errSecDuplicateItem`, another `serve`
   process won the race: discard the just-generated keypair, repeat
   step 2 to load the winning private key, then proceed. The binary
   MUST NOT cache the lost candidate.
5. Cache the loaded private key for the lifetime of the `serve`
   process. Refresh from Keychain on `SIGHUP` or process restart.

The atomic insert-or-load above closes the round-1 audit M5 race:
two simultaneous `serve` launches with the same `provider_id` MUST
converge to a single private key (the first SecItemAdd wins; the
loser falls back to load).

The pubkey is derivable from the private key; the binary MUST NOT
store the pubkey separately. The Keychain item is per-`provider_id`
so reinstalling the binary with a different `provider_id` produces a
different keypair.

### 7.2 Publication on WS auth

On the next v2 `auth_request` initial-stage frame (SPEC-001 v1.5
§6.7.1, candidate extension SPEC-001 v1.6), the binary MUST add the
optional field:

```
"provider_receipt_public_key": "<base64-32-byte-ed25519-public-key>"
```

The field name is `provider_receipt_public_key` to mirror the
existing SPEC-008 `provider_ecdh_public_key` field and to make the
key purpose unambiguous. Encoding is standard padded base64 (44
ASCII characters).

The field MUST be parser-optional on the coordinator side (a
pre-v1.6 binary that does NOT carry the field MUST still admit
successfully; the coordinator MUST treat that provider as
non-receipt-issuing and the gateway MUST NOT emit
`X-MacProvider-Receipt` for responses routed through that provider).

**The proof-stage frame (SPEC-001 v1.5 §6.7.2) is NOT modified by
v0.1.1.** The round-1 audit C2 surfaced that the v0.1 plan to echo
`provider_receipt_public_key` on the proof-stage frame exceeds the
single-field SPEC-001 v1.6 candidate boundary; SPEC-001 v1.5 R-6.7.6
limits proof-stage byte-identity rules to `supported_models[]` and
`publishes_supported_models`. v0.1.1 restricts the candidate
annotation to the initial-stage frame ONLY. A future SPEC-015
revision that needs proof-stage echo MUST file it as a separate
SPEC-001 candidate with its own compatibility analysis.

### 7.3 Coordinator receipt-pubkey surface

The coordinator stores `provider_receipt_public_key` on the in-memory
provider struct alongside the existing `provider_ecdh_public_key`
storage (see `phase4-coordinator/internal/pool/provider.go`,
SPEC-008 v0.3 §5.5). The field MUST be exposed on `/poolz` per §8
below; that exposure (with `receipt_pubkey` and
`receipt_pubkey_prev`) is the SPEC-002 v1.4 candidate annotation
v0.1.3 pins.

**Persistence across restart is an implementation concern, not a
v0.1.3 normative requirement.** The round-1 audit C3 surfaced that
the v0.1 plan to mandate
`ALTER TABLE providers ADD COLUMN receipt_pubkey TEXT` exceeds the
`/poolz` SPEC-002 v1.4 candidate boundary AND prescribes a schema
(`providers` table) that does not exist in the locked SPEC-002
v1.3.5 surface. v0.1.3 deliberately scopes the SPEC-002 candidate
annotation to the `/poolz` shape change and defers the
durable-storage mechanism to the implementation BUILD spec
(`BUILD_SPEC_015_IMPL_*_PROMPT.md`, not yet written).

The implementation BUILD spec MAY choose any of:

- In-memory only on the coordinator: providers republish their
  pubkey on every reconnect, the coordinator never persists. This
  is acceptable because reconnect is the existing recovery path
  (SPEC-002 v1.3.5 §4 admission semantics).
- Durable in a new SPEC-002 candidate column on the existing
  `provider_tokens` or admission audit table, named as a separate
  SPEC-002 candidate annotation.
- Durable in a v0.x dedicated `receipt_pubkeys` table.

v0.1.3 ACs 10–11 verify the runtime surface (the pubkey is exposed
on `/poolz`, the rotation grace window behavior holds) without
asserting a specific storage mechanism.

### 7.4 Rotation under model swap

A receipt MUST commit to a single provider running a single set of
weights for the duration of the response. If a SPEC-011 v0.5 warm
swap is initiated mid-response, the in-flight response MUST drain
under the old `ModelRuntime` per SPEC-011 §3.8.4. The receipt is
emitted from the same `ModelRuntime` instance that produced the
output; no special handling is required for the receipt itself.

If a binary or coordinator bug causes a mid-response swap that
violates the drain invariant, the provider MUST close the response
with an HTTP 500 error envelope and MUST NOT emit a receipt. This is
a fail-closed default; the alternative (emit a receipt over partial
output) would silently weaken the binding.

### 7.5 Manual rotation (via reconnect)

v0.1.x defines manual rotation only. Auto-rotation is deferred to a
later version.

The binary MUST support the CLI flag:

```
macprovider rotate-key
```

Rotation is performed via WebSocket reconnect, NOT via a new control
frame. The round-2 audit C2 established that introducing a new
provider→coordinator WS frame would exceed the single-field
SPEC-001 v1.6 candidate annotation. The reconnect-based design
reuses the already-authorized initial-stage `auth_request` field.

When `macprovider rotate-key` is invoked:

1. The binary generates a fresh ed25519 keypair IN MEMORY ONLY. The
   new keypair is NOT yet written to Keychain.
2. The binary closes the current WS connection cleanly.
3. The binary opens a fresh WS connection and sends a v2
   `auth_request` initial-stage frame carrying the NEW
   `provider_receipt_public_key`.
4. If the coordinator accepts the auth and proof stages (returning
   `auth_response.accepted=true`), the binary atomically swaps
   Keychain:
   - Move the existing Keychain item at
     `(service=com.streamvc.macprovider.receipt-key,
       account=<provider_id>)` to
     `(service=com.streamvc.macprovider.receipt-key.prev,
       account=<provider_id>)`.
   - Add the new keypair at the original `(service, account)`.
   The `.prev` Keychain item is retained for a 7-day operator
   recovery window and is auto-deleted by the next `serve` launch
   that detects it older than 7 days.
5. If the reconnect fails (coordinator rejects auth, network down,
   timeout), the binary discards the in-memory new keypair, restores
   the WS connection using the OLD Keychain-resident key, and
   surfaces the rotation failure to the operator
   (`macprovider rotate-key` exits non-zero with a clear error
   message).
6. The coordinator infers rotation by comparing the new pubkey
   against the previously-known one for this `provider_id`. On
   detection:
   - The coordinator moves the prior pubkey to `receipt_pubkey_prev`
     with `rotated_at = now`.
   - Sets `receipt_pubkey` to the new value.
   - Updates `/poolz` accordingly (§8).
7. The binary signs all NEW receipts emitted after step 4 with the
   new private key. There is no in-flight rotation window for the
   PROVIDER side — by construction the old key is unreachable from
   the moment a new WS connection is established.

The previous-pubkey grace window described in §7.5.1 covers buyers
whose `/poolz` cache still points at the old key at rotation time.

#### 7.5.1 Grace window semantics

During the grace window, the coordinator's `/poolz` response carries
both pubkeys:

```
"receipt_pubkey": "<new-base64>",
"receipt_pubkey_prev": {
  "pubkey": "<old-base64>",
  "rotated_at": <unix-seconds>,
  "expires_at": <unix-seconds>
}
```

`expires_at` is `rotated_at + 7 * 86400`. After expiration the
coordinator removes the `receipt_pubkey_prev` block. v0.2 verifiers
MUST accept receipts signed under either `receipt_pubkey` or
`receipt_pubkey_prev` during the grace window.

The grace window is time-only in v0.1.3. A v0.x+ may add a
request-count-bounded short-circuit (e.g. "after the rotated
provider has signed 10000 receipts under the new key, the previous
key MAY be retired early"), but that requires a counter contract
v0.1.3 deliberately does not pin.

### 7.6 Null-usage / error receipts

When the provider returns a SPEC-001 null-usage error
(`error_model_not_loaded`, `error_context_exceeded`,
`error_queue_full`, `error_internal`) per SPEC-005 v0.3 §3 X-1 row:

- `tokens_out` MUST be `0`.
- `output_hash` MUST be the sha256 hex of the canonical output object
  with `content=""`, `tool_calls=null`, `finish_reason="error"`.
- `ttft_ms` MUST be the elapsed milliseconds from request-accepted
  to error-emitted (i.e. the "time to error", which is
  observationally useful for the buyer).
- `unix_ts` is set normally.

The receipt is emitted. This is deliberate: the buyer paying zero
under SPEC-005 X-1 still gets a signed acknowledgement that the
provider was reached and produced an error response. This closes a
SPEC-006 v0.8.2 ambiguity: the v0.8.2 X-1 row debited the buyer
zero quota but said nothing about whether the buyer learned what
the provider did.

If the provider was never reached (gateway-internal failure,
coordinator preflight rejection, no provider available), no receipt
is emitted because there is no provider to sign one. The error
envelope SPEC-006 §H normalizes the response shape; the absence of
`X-MacProvider-Receipt` distinguishes "provider never ran this" from
"provider ran and errored".

---

## 8. Pubkey trust root

### 8.1 v0.1 trust root: `/poolz`

Buyers retrieve the provider receipt pubkey from the coordinator's
`/poolz` endpoint (SPEC-002 v1.3.5 §7). v0.1.x ANNOTATES two new fields
per provider object, marked as SPEC-002 v1.4 candidate:

```
{
  "provider_id": "p_01HK4Z3VYE...",
  "state": "ready",
  "model": "...",
  ...
  "receipt_pubkey": "<base64-32-byte-ed25519>" | null,
  "receipt_pubkey_prev": null | { "pubkey": "...", "rotated_at": ..., "expires_at": ... }
}
```

`receipt_pubkey` is `null` for providers whose binary is at SPEC-001
< v1.6 (no key published). Such providers MUST NOT have
`X-MacProvider-Receipt` headers on responses they serve; the gateway
MUST omit the header if the upstream coordinator's chosen provider
has `receipt_pubkey: null`.

`receipt_pubkey_prev` is `null` outside the rotation grace window.

### 8.2 Buyer fetch ergonomics

Buyers SHOULD cache `/poolz` responses for short windows (≤ 60
seconds) to avoid hammering the endpoint on every verification.
SPEC-002 v1.3.5 already permits `/poolz` caching at this cadence per
§7.4.

### 8.3 Operator-mutability and the limits of v0.1's trust root

The coordinator operator can rewrite `/poolz` at any time; v0.1's
trust root is therefore "the coordinator operator does not lie about
which pubkey corresponds to which provider". This is consistent with
the rest of the MacProvider Tier-1 trust posture (SPEC-006 v0.8.3
§1.6) and is acknowledged in the README:

> Buyer prompts and provider responses are processed as plaintext on
> provider hardware … This is acceptable for cooperative deployments
> where buyer and provider have an established trust relationship; it
> is NOT a private-inference guarantee.

A stronger trust root — TUF-style operator-signed `/poolz`, an
external anchor at AntFeed, or a Cluster D-token-anchored registry —
is §15 Q1 and explicitly out of scope for v0.1. Implementers
documenting v0.1 to buyers MUST be honest about this limit; v0.1
receipts protect against provider misbehavior, NOT against
coordinator-operator misbehavior.

### 8.4 Future migration off `/poolz`

When a v0.3+ stronger root lands, the wire format of receipts
(§3.4) MUST be unchanged. Only `provider_pubkey` source-of-truth
changes. This forward-compatibility commitment is binding on v0.1
implementers: do NOT bake `/poolz`-specific assumptions into the
verification path; the verifier takes a `provider_pubkey` argument
out-of-band and verifies against it.

---

## 9. Receipt emission timeline

For a non-streaming response:

```
t0: provider receives request from coordinator
t1: provider begins inference (load model, accept prompt)
t2: first output token emitted             → ttft_ms = (t2 - t1) / ms
t3: last output token emitted, finish_reason set, tokens_out known
t4: provider canonicalizes prompt object → prompt_hash
t5: provider canonicalizes output object → output_hash
t6: provider builds tuple T with unix_ts = floor(t3 / second)
t7: provider computes SIG = ed25519_sign(privkey, JCS(T))
t8: provider writes X-MacProvider-Receipt header
t9: provider writes response body
```

Streaming responses are out of scope in v0.1.x (§6.3); no receipt
is emitted, no header is added, and steps t4–t9 do not run on the
streaming path.

---

## 10. Verification (v0.2 NORMATIVE)

v0.1 carried this section as a sketch (`informative; v0.2
normative`). v0.2 promotes it to normative: buyers MUST be able to
use the algorithm below — implemented by the v0.2 `macprovider-verify`
CLI (binary contract per §10.4) — to obtain a deterministic
verification result for any v0.1.3-shape receipt.

### 10.0 Core algorithm (preserved from v0.1)

A buyer with the receipt header value and a trusted provider pubkey
verifies as follows:

```
1. Split the header value on the first '.' → (b64_tuple, b64_sig).
2. Decode JCS_T = base64_decode(b64_tuple).
3. Decode SIG = base64_decode(b64_sig). Reject if len(SIG) != 64.
4. Parse JCS_T as JSON to confirm well-formed and contains exactly
   the seven SPEC-015 §3.1 keys.
5. Resolve the trusted pubkey for the resolved `provider_id` per
   §10.2 (sources: explicit `--pubkey` → cached entry → live
   `GET /v1/receipt-keys/<provider_id>`). The verifier MUST NOT
   resolve by scanning across providers for a matching
   `provider_pubkey`; `provider_id` is the resolver address. If
   the trust root cannot reach a verdict → `inconclusive`
   (§10.1).
6. ed25519_verify(trusted_pubkey, JCS_T, SIG). Reject on failure
   → `invalid` (§10.1).
7. Canonicalize the buyer's recorded request prompt per §4 →
   prompt_hash_local. If != receipt.prompt_hash → `invalid`.
8. Canonicalize the buyer's recorded response output per §5 →
   output_hash_local. If != receipt.output_hash → `invalid`.
9. → `valid` (§10.1).
```

The optional `unix_ts` skew check that appeared in v0.1's sketch is
removed from the v0.2 core algorithm. Per §10.6, the timestamp is
NOT proven by a `valid` result; cross-checking against buyer-side
received-at remains a v0.3+ candidate (§15 Q4). A v0.2 verifier MAY
emit an informational warning if `unix_ts` is wildly off (e.g.
> 24h skew vs. system clock), but MUST NOT downgrade the result to
`invalid` on skew alone.

### 10.1 Result semantics (the tri-state)

A verifier MUST return exactly one of three results for any
(receipt, request, response) input:

| Result | Meaning | Exit code |
|---|---|---|
| `valid` | Signature verifies, canonical hashes match, pubkey resolved to a trusted source | 0 |
| `invalid` | Signature fails OR a canonical hash mismatches OR pubkey is known-revoked | 1 |
| `inconclusive` | Pubkey could not be resolved AND no explicit pubkey was supplied | 2 |

A verifier MUST NOT collapse `inconclusive` into either of the other
results. In particular, a verifier MUST NOT report `valid` when the
pubkey is unresolved, even if a signature self-verifies against a
pubkey embedded in the receipt: an unrooted pubkey is unrooted,
regardless of the signature's internal consistency.

`inconclusive` is the correct result when ANY of the following
hold AND no explicit `--pubkey` was supplied AND the verifier
passed §10.4 input validation (i.e. `provider_id` was obtainable
at parse time per §10.4 "Provider-id requirements"):

- The configured coordinator's `GET /v1/receipt-keys/<provider_id>`
  endpoint (§10.7) is unreachable (network down, DNS failure, 5xx,
  timeout, rate-limited via 429) AND no fresh cached entry exists
  for `(coordinator_host, provider_id, receipt_pubkey)`, OR
- The §10.7 endpoint returns HTTP 404 for the `provider_id` — an
  authoritative "this provider is unknown to me" answer, treated
  as `inconclusive` with `reason: "provider_id_not_in_pool"`
  because the receipt itself may predate provider removal, OR
- The cache holds only a stale entry (older than the §10.2 7-day
  TTL) AND the live fetch fails.

The "provider_id is not addressable at all" case (no CLI arg, no
bundle field, no single-match cache) is NOT an `inconclusive`
case in v0.2 — it is an exit-64 usage error per §10.4. The
verifier rejects the invocation at parse time and never reaches
the result-determination algorithm. See §10.4 "Provider-id
requirements" for the exit-64 contract.

`invalid` (not `inconclusive`) is the correct result when ANY of
the following hold:

- The resolver returns an authoritative provider record for the
  resolved `provider_id` (HTTP 200, parseable response) whose
  `receipt_pubkey` and `receipt_pubkey_prev.pubkey` are BOTH
  different from the receipt's embedded `provider_pubkey` — the
  coordinator has explicitly named the keys it endorses for this
  provider and the receipt's key is not among them, OR
- The resolver returns a `receipt_pubkey_prev` match BUT the
  receipt's `unix_ts` falls outside the §10.2.1 grace window, OR
- The signature check fails against a successfully-resolved
  trusted pubkey, OR
- Either canonical hash mismatches.

The boundary between `inconclusive` and `invalid` is the
authoritative-resolver-answer test: if the trust root reached a
verdict ("no, I don't endorse this key for this provider"), the
receipt is `invalid`; if the trust root could not reach a verdict
(unreachable, identity unresolvable), the receipt is
`inconclusive`. A receipt MUST NOT be `inconclusive` when the
coordinator's authoritative response excludes its
`provider_pubkey` — that case is a coordinator-rejected forgery
(or retired key), not an environmental failure.

The HTTP 404 response from the §10.7 endpoint (provider not in
the current pool) is a degenerate case: it is authoritative
("this `provider_id` is unknown to me") but the receipt itself may
predate the provider's removal. v0.2 verifiers MUST treat 404 as
`inconclusive` with `reason: "provider_id_not_in_pool"` per the
§10.4.2 reason enum. v0.3+ MAY revisit this if the coordinator
gains a "retired but historic" state.

### 10.2 Pubkey resolution

A verifier MUST resolve the pubkey it trusts against, in this
priority order:

1. **Explicit:** A pubkey supplied by the caller via
   `--pubkey <44-char base64>`. Used for offline / air-gap
   verification. When supplied alongside `--provider-id`, the
   verifier MUST treat the pair as the trusted root regardless of
   live coordinator state. The explicit pubkey wins the
   verification result; live divergence is reported via
   `warnings[]` per §10.4.2, not via result downgrade.
2. **Cached:** A pubkey stored locally from a prior
   `GET /v1/receipt-keys/<provider_id>` fetch (§10.7), keyed by
   the tuple `(coordinator_host, provider_id, receipt_pubkey)`.
   Cache entries MUST carry a `fetched_at` timestamp, the
   `rotated_at` and `expires_at` timestamps as returned by the
   coordinator, and the corresponding `receipt_pubkey_prev`
   record (if any) for grace-window verification. All three
   timestamps MUST be stored as RFC3339 UTC strings matching the
   §10.7 wire shape; conversion from the receipt's Unix-seconds
   `unix_ts` to RFC3339 (or vice versa) happens at the cache
   boundary, not at every comparison. The receipt `unix_ts`
   itself remains Unix seconds per the locked v0.1 wire contract.
   - **Fresh entry** (cache `fetched_at` ≤ 7 days before `now()`):
     used directly.
   - **Stale entry** (cache `fetched_at` > 7 days before `now()`):
     MUST trigger a
     fresh live fetch. On fetch success, replace the entry. On
     fetch failure, the verifier MUST NOT use the stale entry to
     produce `valid` — the result is `inconclusive`. The
     provider-reported `unix_ts` MUST NOT be used to revalidate
     a stale cache entry (per §10.6, timestamp honesty is not
     proven; staleness is a coordinator-attested property, not a
     buyer-derivable one).
   - The 7-day TTL matches §7.5.2 rotation grace; a key that has
     not rotated within 7 days remains valid via fresh-fetch
     refresh.
3. **Live:** A fetch of `GET /v1/receipt-keys/<provider_id>`
   (§10.7 — SPEC-002 v1.5 candidate annotation, public /
   unauthenticated / rate-limited) on the coordinator named in
   the verifier's config (default: `coordinator.streamvc.live`).
   MUST be a single `GET` over HTTPS with a 5-second timeout and
   no retries. On success, the verifier MUST update its cache
   (write `fetched_at = now()`) before continuing. The verifier
   MUST NOT fall back to `GET /poolz`: that endpoint is
   operator-only per SPEC-002 v1.4 §FR-O2 and is not buyer-safe.

`provider_id` resolution: when the bundle provides `provider_id`,
the verifier uses it directly. When `provider_id` is absent, the
verifier MUST NOT scan all known providers. The fallback order is:
(1) explicit `--provider-id` CLI argument, (2) a single matching
cached entry's `provider_id` under the configured coordinator. If
neither yields a `provider_id` AND no `--pubkey` is supplied, the
verifier exits `64` per §10.4 "Provider-id requirements" — the
verifier MUST NOT emit `inconclusive` for missing-input cases.
Pubkey-byte scanning across providers re-introduces the
identity-loss problem audit A4 named.

**Explicit-vs-live divergence handling (S5):** Whenever an
explicit pubkey is supplied AND the verifier is not running with
`--offline`, the verifier MUST attempt the live `/v1/receipt-keys`
fetch in the background. If the live pubkey for the supplied
`provider_id` differs from the explicit one, the verifier MUST
record a `warnings[]` entry in JSON output with kind
`explicit_vs_live_divergence` and the differing live pubkey. The
explicit pubkey still wins for `result`; the warning is recorded
regardless of `--quiet` (which suppresses only stderr emission,
not the warning record itself). With `--offline`, the live check
is skipped and a `warnings[]` entry of kind `live_check_skipped`
is recorded for output transparency.

If sources (1), (2), and (3) all fail to yield a trusted pubkey
(no explicit, no fresh cached entry, `/v1/receipt-keys`
unreachable or returns no matching entry), the result is
`inconclusive`. A verifier MUST NOT fall back to "trust the
receipt's embedded `provider_pubkey` on faith."

#### 10.2.1 Rotation-grace behavior

A receipt issued under the previous key during the §7.5.2 rotation
grace window MUST verify `valid` ONLY when ALL of the following
hold:

1. The resolved `/v1/receipt-keys/<provider_id>` response (live or
   cached) contains a non-null `receipt_pubkey_prev` block with a
   `pubkey` field matching the receipt's `provider_pubkey`.
2. The receipt's `unix_ts` satisfies
   `rotated_at - 60s ≤ unix_ts ≤ expires_at`, where `rotated_at`
   and `expires_at` are taken from the `receipt_pubkey_prev`
   block.

The `-60s` slack matches the v0.1 AC-11 invariant and absorbs
provider-side clock skew within the rotation moment. A previous-
key match OUTSIDE this interval MUST verify `invalid`, NOT
`valid` or `inconclusive`: the coordinator has explicitly named the
window during which the previous key was endorsed, and a receipt
outside it is one of (a) a clock-cheating provider attempting to
extend the grace, (b) a stale receipt the buyer is presenting late
(out of contract), or (c) a forgery. None of these warrant
`valid`.

A receipt whose `provider_pubkey` matches neither `receipt_pubkey`
nor `receipt_pubkey_prev.pubkey` for the resolved `provider_id`
MUST be `invalid`, not `inconclusive`: the coordinator has
explicitly stated which keys it endorses for this provider, and
the receipt's key is not among them.

### 10.3 Canonicalization parity

The verifier MUST canonicalize the buyer-held prompt and response
using **bit-identical** rules to those §3.2 and §§4-5 pin for the
provider-side signing path. Specifically:

- JCS per RFC 8785, with the SPEC-015 v0.1.1 §3.2 extensions
  (RFC 8785 §3.2.2.3 float handling and explicit NFC normalization
  of natural-language strings).
- Prompt canonical object per §4.2 (16-key shape).
- Output canonical object per §5.1 (`content` / `tool_calls` /
  `finish_reason`).

A v0.2-compliant verifier that diverges from these rules is
non-conforming. A verifier MUST NOT add a "lenient" mode that
accepts non-canonical inputs: doing so destroys the cryptographic
property that makes verification meaningful.

If a buyer's tool has re-serialized or pretty-printed the response
JSON before passing it to `macprovider verify`, the canonicalization
step (which re-parses the response to its abstract value and
re-emits canonical bytes) MUST still reproduce the same
`output_hash` the provider signed. If it does not, the receipt is
`invalid`, not "verifier needs to be more lenient."

The Go port of `RFC8785JCS.swift` shipped with the v0.2 verify CLI
MUST include a parity test (`testdata/jcs_parity.json` — same
inputs, same canonical outputs across Swift and Go) wired as a CI
gate. Any drift between the two implementations MUST fail CI
before the verify binary can be released.

### 10.4 Inputs, outputs, exit codes

The verifier MUST accept these input shapes:

1. **Header + hashes mode:** `macprovider verify --receipt <base64>
   --prompt-hash <hex> --output-hash <hex> [--provider-id <id>]` —
   for callers who have already canonicalized and hashed the
   request/response. `--provider-id` is REQUIRED in this mode
   UNLESS `--pubkey` is also supplied (see §10.4 "Provider-id
   requirements" below); without it the live resolver cannot be
   addressed.
2. **Bundle mode:** `macprovider verify --bundle <path>
   [--provider-id <id>]` — bundle JSON shape pinned in §10.4.1.
   The bundle's `provider_id` field MAY be omitted; if so,
   `--provider-id` becomes REQUIRED for online verification.
   `--provider-id` (when supplied) MUST match the bundle's
   `provider_id` (when also present); a mismatch is a usage error
   (exit 64).
3. **Stdin mode:** `cat bundle.json | macprovider verify -
   [--provider-id <id>]` — same shape as bundle mode, read from
   stdin. Same `--provider-id` rules.

A verifier MAY accept additional input shapes (e.g. raw HTTP
response capture) as long as they reduce to one of the three above
before the §10.0 algorithm runs.

**Provider-id requirements (CF5 / CF7 normative):** The §10.7
resolver endpoint is addressed by `provider_id`. The verifier MUST
obtain `provider_id` from one of:

1. The `--provider-id <id>` CLI argument (first-class input).
2. The bundle's `provider_id` field (bundle/stdin modes only).
3. A single matching cached entry for `receipt_pubkey` under the
   configured coordinator (degenerate "I've seen exactly one of
   these before" path; verifier MUST NOT scan multiple cached
   entries).

**Without `--pubkey` (online verification path):** `provider_id`
MUST be obtained from (1)/(2)/(3) before the verifier runs. If
none of those sources yield a `provider_id`, the verifier MUST
reject the invocation with exit code `64` (usage error) and a
clear error message naming `--provider-id` as the missing input.
The verifier MUST NOT run to completion and emit `inconclusive` in
this case: the receipt may be perfectly valid, but the buyer has
not supplied enough information to reach the trust root. This is
a CLI contract violation, not a trust-root failure. Other
"missing required argument" cases (`--receipt`, `--bundle`) follow
the same exit-64 convention.

**With explicit `--pubkey`:** online verification does NOT require
`provider_id` to produce `valid` — the explicit pubkey serves as
the trust root. The verifier MUST still attempt to record
`provider_id` (from sources 1/2/3) for output reporting and the
live divergence-warning check (§10.2). If no `provider_id` is
recoverable AND the verifier is online, JSON output emits
`provider_id: null` and `warnings[]` gains a
`live_check_skipped` entry with `reason:
"provider_id_unresolvable"`. The verifier MUST NOT
fingerprint-scan across providers under any circumstance.

The verifier MUST NOT use `inconclusive` as a substitute for the
missing-provider-id exit-64 case: `inconclusive` is reserved for
trust-root failures the verifier discovered during execution, not
for CLI contract violations the verifier knows at parse time.

#### 10.4.1 Bundle JSON shape

```json
{
  "bundle_version": 1,
  "receipt": "<base64(JCS(T))>.<base64(SIG)>",
  "request": { "model": "...", "messages": [ ... ], ... },
  "response": { "id": "...", "choices": [ ... ], "usage": { ... } },
  "provider_id": "m1-anon"
}
```

- `bundle_version` (REQUIRED, integer): pinned to `1` in v0.2.x. A
  verifier MUST reject any other value as an **input format error**
  with exit code `65` per §10.4.3. (Unsupported `bundle_version` is
  data that the verifier cannot parse, not a CLI usage mistake.)
  v0.3+ MAY introduce `bundle_version: 2` for additive fields;
  v0.3+ verifiers MUST continue to accept `bundle_version: 1`.
- `receipt` (REQUIRED, string): the verbatim value of the
  `X-MacProvider-Receipt` response header, which per §3.4 has the
  shape `<base64(JCS(T))>.<base64(SIG)>` (two base64 segments
  separated by a literal `.`).
- `request` (REQUIRED, object): the OpenAI
  `/v1/chat/completions` request body as captured by the buyer.
  This is the raw request as the buyer's HTTP client saw it; the
  verifier MUST NOT require pre-canonicalization or pre-population
  of optional fields. Any §4.2 canonical-prompt field absent from
  the captured request canonicalizes as JSON `null` per the locked
  v0.1 §4.2 rule. Buyers who use the OpenAI SDK with only the
  required `model` + `messages` parameters MUST be able to bundle
  the SDK-sent request unchanged and have it verify.
- `response` (REQUIRED, object): the OpenAI completion response
  as captured by the buyer. Same rule: raw, no pre-canonicalization.
- `provider_id` (OPTIONAL, string): the provider identifier as
  surfaced by the coordinator. When present, this is used as the
  primary key for §10.2 step 2/3 pubkey resolution and §10.2.1
  rotation-grace lookup. When absent, the verifier follows the
  §10.4 "Provider-id requirements" fallback order (explicit
  `--provider-id`, then single-match cache); if neither yields a
  `provider_id` AND no `--pubkey` is supplied, the verifier exits
  `64` (usage error) before any verification runs. The verifier
  MUST NOT emit `inconclusive` for missing-input cases.

A v0.2 verifier MUST reject unknown top-level keys with exit code
`65` (input format error per §10.4.3). This prevents future
ambiguity about field semantics and forces forward-compatibility
changes through the `bundle_version` bump.

#### 10.4.2 Output modes

`--json` MUST emit a single line of JSON conforming to the field
table below.

**Top-level fields:**

| Field | Disposition | Type | Notes |
|---|---|---|---|
| `result` | REQUIRED | enum string | One of `valid`, `invalid`, `inconclusive`. |
| `reason` | REQUIRED | enum string | See "reason values" table below. |
| `provider_id` | REQUIRED-when-resolved, else `null` | string\|null | The coordinator-attested `provider_id` used for pubkey lookup. `null` when result is `inconclusive` and no provider could be identified. |
| `model_id` | REQUIRED-when-resolved, else `null` | string\|null | Read from the receipt tuple. `null` only when the tuple itself could not be parsed (a `65` exit-code path that produces no JSON anyway). |
| `signed_at` | REQUIRED-when-resolved, else `null` | integer\|null | The receipt's `unix_ts`. Same null rule as `model_id`. |
| `trust_source` | REQUIRED | enum string | One of `explicit_pubkey`, `cache`, `live`, `none`. The last only when `result == "inconclusive"`. |
| `coordinator_host` | REQUIRED-when-trust_source-is-network-derived, else `null` | string\|null | The coordinator host that supplied the trust root. Required when `trust_source` is `cache` (cache origin host) or `live`. `null` for `explicit_pubkey` (no coordinator involved) and `none`. |
| `details` | REQUIRED-when-invalid, else absent | object | See "details schema" below. MUST be present when `result == "invalid"`. MUST be absent otherwise. |
| `warnings` | OPTIONAL | array of objects | Each entry has a `kind` (enum) and `kind`-specific fields. See "warnings schema" below. Array MAY be empty or absent when no warnings apply. |

**`reason` values (enum, exhaustive for v0.2.x):**

- For `valid`: `signature_and_canonicalization_match`
- For `invalid`: `signature_verify_failed`, `prompt_hash_mismatch`,
  `output_hash_mismatch`, `pubkey_not_endorsed`,
  `previous_key_outside_grace_window`, `bundle_pubkey_provider_mismatch`
- For `inconclusive`: `pubkey_unresolvable`,
  `provider_id_not_in_pool`, `cache_stale_and_live_unreachable`

v0.3+ MAY extend the enum additively; v0.3+ verifiers MUST emit
v0.2-known values for v0.2-mapped cases.

**`details` schema (REQUIRED when `result == "invalid"`):**

| Field | Type | Notes |
|---|---|---|
| `field` | enum string | One of `signature`, `prompt_hash`, `output_hash`, `pubkey`, `grace_window`. |
| `computed` | string | The value the verifier computed (hex for hashes, base64 for pubkey, etc.). Absent only when `field == "signature"` (the signature check is opaque). |
| `receipt` | string | The value carried by the receipt for comparison. |
| `extra` | object | OPTIONAL, `field`-specific extra context (e.g. `rotated_at`/`expires_at`/`unix_ts` for `grace_window`). |

**`warnings[]` schema:**

| `kind` value | Additional fields | When emitted |
|---|---|---|
| `explicit_vs_live_divergence` | `live_pubkey` (string), `coordinator_host` (string) | Explicit `--pubkey` was used AND a live `/v1/receipt-keys` fetch succeeded AND returned a different pubkey for the same `provider_id`. |
| `live_check_skipped` | `reason` (one of `offline_flag`, `network_unreachable`, `provider_id_unresolvable`) | The live divergence check did not run. `offline_flag`: `--offline` was passed. `network_unreachable`: live fetch failed (network down, 5xx, timeout, 429). `provider_id_unresolvable`: explicit `--pubkey` was supplied AND no `provider_id` was recoverable from CLI, bundle, or cache (the verifier had nothing to address the resolver with). |
| `non_default_coordinator` | `coordinator_host` (string) | A non-default coordinator (i.e. not `coordinator.streamvc.live`) was used as the trust-root source. |
| `clock_skew` | `unix_ts` (int), `system_time` (int), `delta_seconds` (int) | Receipt `unix_ts` differs from the verifier's system clock by more than 24 hours. Informational only — does NOT downgrade `result` per §10.6. |

A verifier MUST emit `warnings[]` entries regardless of `--quiet`
(which suppresses only stderr emission, not the JSON record).

**Example outputs:**

```json
{"result":"valid","reason":"signature_and_canonicalization_match","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"live","coordinator_host":"coordinator.streamvc.live","warnings":[]}
```

```json
{"result":"invalid","reason":"output_hash_mismatch","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"live","coordinator_host":"coordinator.streamvc.live","details":{"field":"output_hash","computed":"ab12...","receipt":"cd34..."}}
```

```json
{"result":"inconclusive","reason":"cache_stale_and_live_unreachable","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"none","coordinator_host":null,"warnings":[{"kind":"live_check_skipped","reason":"network_unreachable"}]}
```

**Default (non-JSON) human-readable output** is a single line:

```
valid (m1-anon · qwen2.5-7b-instruct-q4 · signed 2026-06-23T08:00Z · trust=live@coordinator.streamvc.live)
invalid: output_hash mismatch (computed=ab12... receipt=cd34...)
inconclusive: cache stale and /v1/receipt-keys unreachable on coordinator.streamvc.live
```

When the `trust_source` is `live` or `cache`, the human-mode line
MUST include the coordinator host (rendered as
`trust=<source>@<host>`). Warnings MUST be printed to stderr (one
per line, prefixed `warning:`) unless `--quiet` suppresses stderr.

The v0.2 CLI SHOULD include a `--explain` flag that prints §10.6
verbatim to stderr after a `valid` result, so a buyer who reads
`valid` is reminded of what `valid` does and does not mean.

#### 10.4.3 Exit codes

| Code | Meaning |
|---|---|
| 0 | `valid` |
| 1 | `invalid` (signature, canonicalization, coordinator-rejected pubkey, or previous-key-outside-grace-window) |
| 2 | `inconclusive` (pubkey unresolvable, provider_id not in pool per §10.7 404, cache stale + live unreachable) |
| 64 | usage error (per `sysexits.h`, `EX_USAGE`) — unknown CLI flag, missing required CLI argument, mutually-exclusive flags combined (e.g. `--bundle` + `--receipt`), invalid value format for a CLI flag (e.g. malformed `--pubkey` base64) |
| 65 | input format error (per `sysexits.h`, `EX_DATAERR`) — malformed bundle JSON, missing required bundle field, unknown bundle top-level key, unsupported `bundle_version`, malformed receipt header value (cannot split on `.`), base64 decode failure on tuple or signature, tuple JSON not well-formed or wrong key set |

These exit codes are normative. Scripts and CI pipelines WILL rely
on them. A future v0.3+ verifier MUST preserve the 0/1/2/64/65
mapping; adding new exit codes for new failure modes is allowed
only in the >65 range (e.g. 66 for cache-corruption diagnostics).

**`64` vs `65` boundary:** `64` is for problems with how the
verifier was *invoked*; `65` is for problems with the *data* the
verifier was asked to verify. An unsupported `bundle_version` is
data the verifier cannot parse, so it is `65`. A typo'd flag is
how the verifier was invoked, so it is `64`. A malformed
`--pubkey` argument is `64` (the flag value is malformed,
preventing invocation), but a malformed `receipt` field inside a
syntactically-valid bundle is `65` (the bundle was accepted, but
its receipt content is unparseable).

#### 10.4.4 Flag interaction matrix

The v0.2 CLI flags are listed in §10.4. This matrix pins their
interaction semantics for combinations that are not obvious from
individual flag descriptions.

| Flag combination | Live `/v1/receipt-keys` fetch? | Divergence warning? | Stderr emission? | Result downgrade? |
|---|---|---|---|---|
| (no `--pubkey`, no `--offline`) | YES (default path) | n/a | per-mode | n/a |
| `--pubkey P` (no `--offline`) | YES (background, for divergence check) | YES if live differs | per `--quiet` | NO — explicit wins |
| `--pubkey P --offline` | NO | n/a — `live_check_skipped` warning emitted | per `--quiet` | NO |
| `--offline` (no `--pubkey`) | NO | n/a | per `--quiet` | `inconclusive` if cache miss / stale |
| `--quiet` (alone) | per other flags | per other flags | SUPPRESSED (stderr only) | NO |
| `--quiet --json` | per other flags | per other flags | SUPPRESSED (stderr); warnings still in JSON `warnings[]` | NO |
| `--coordinator H` (or env) | YES, against host `H` | per other flags | per `--quiet` | NO; `non_default_coordinator` warning if `H != coordinator.streamvc.live` |
| `--explain` | per other flags | per other flags | §10.6 verbatim printed to stderr after valid result | NO |
| `--bundle B --receipt R` | n/a | n/a | n/a | USAGE ERROR (exit 64) — mutually exclusive |
| `--bundle -` (stdin mode) | per other flags | per other flags | per `--quiet` | NO |
| `--provider-id I` + header+hashes mode (no `--pubkey`) | YES, addressed by `I` | n/a (no explicit) | per `--quiet` | NO if resolver responds; `inconclusive` if `I` returns 404 |
| `--provider-id I` + header+hashes mode + `--pubkey P` | YES (background only) | YES if live differs | per `--quiet` | NO — explicit wins |
| `--provider-id I` + bundle mode where bundle also has `provider_id: J` and `I != J` | n/a | n/a | n/a | USAGE ERROR (exit 64) — mismatched provider identity |
| `--provider-id I` + bundle mode where bundle has `provider_id: I` (or none) | per other flags | per other flags | per `--quiet` | NO |
| header+hashes mode (no `--provider-id`, no `--pubkey`) | n/a | n/a | n/a | USAGE ERROR (exit 64) — `--provider-id` required for online verification without explicit pubkey |
| bundle/stdin mode (no bundle `provider_id`, no `--provider-id`, no `--pubkey`, no single-match cache entry) | n/a | n/a | n/a | USAGE ERROR (exit 64) — same as above; provider id unobtainable for online verification |
| header+hashes mode + `--pubkey P` (no `--provider-id`) | NO (no `provider_id` to address) | n/a | per `--quiet`; `live_check_skipped` warning with `reason: provider_id_unresolvable` | NO — explicit pubkey wins; `provider_id: null` in JSON output |

**`--provider-id` summary:** REQUIRED for online verification in
header+hashes mode unless `--pubkey` is supplied. OPTIONAL in
bundle/stdin modes when the bundle carries `provider_id` (the
bundle field takes precedence on absence; mismatch is a usage
error). When neither source provides `provider_id` AND no
`--pubkey` is supplied, the verifier rejects the invocation with
exit code `64` per §10.4 "Provider-id requirements" — the
verifier MUST NOT scan and MUST NOT emit `inconclusive` in this
case (it is a CLI contract violation, not a trust-root failure).

The matrix is normative. A verifier MUST NOT introduce flag
combinations whose semantics aren't covered here or aren't
trivially derivable from §10.4 / §10.4.2 / §10.5. A v0.3+ verifier
MAY add new flags; if a new flag interacts with any v0.2 flag, the
v0.3+ spec MUST extend this matrix.

`--quiet` semantics (final): suppresses all stderr emission
(including `warning:` lines and `--explain` output). Does NOT
suppress JSON `warnings[]` records. Does NOT change exit code.

### 10.5 Network behavior

The verifier MUST NOT make any network call beyond
`GET /v1/receipt-keys/<provider_id>` (§10.7) on the configured
coordinator host for pubkey resolution. No telemetry. No opt-in
analytics. No version-check beacon. No crash reporting. No update
check. No fallback to `/poolz` (which is operator-only per SPEC-002
v1.4 §FR-O2). A buyer running
`macprovider verify --offline --pubkey <p> ...` on an air-gapped
Mac MUST observe zero network traffic (verifiable via packet
capture or a network sandbox that denies all egress).

The live fetch is a single `GET` over HTTPS with a 5-second
connection-plus-read timeout. No retries. The verifier MUST NOT
follow HTTP redirects beyond the configured coordinator host
(default: `coordinator.streamvc.live`; configurable via
`--coordinator` flag or `MACPROVIDER_COORDINATOR` environment
variable). Redirects whose `Location` resolves to a different host
MUST be treated as a fetch failure (contributing to `inconclusive`
when no fresh cache exists), not silently followed. A redirect to
the SAME host (e.g. http→https upgrade) MAY be followed.

A buyer who wants different timeout / retry semantics MUST
pre-populate the cache and run with `--offline`. The verifier MUST
NOT expose `--timeout` or `--retries` flags in v0.2: variability
in fetch semantics across deployments would make `inconclusive`
mean different things to different buyers.

When the configured coordinator host is NOT the default
`coordinator.streamvc.live`, the verifier MUST record a
`non_default_coordinator` warning per §10.4.2 in every output
(JSON and human-mode stderr unless `--quiet`). The trust boundary
is coordinator-specific; making non-default coordinators visible
is a buyer-protection invariant.

### 10.6 Trust boundary

A `valid` result from `macprovider verify` proves **exactly this**:
a holder of the provider's private key signed a canonical tuple
containing the values (`model_id`, `prompt_hash`, `output_hash`,
`provider_pubkey`, `ttft_ms`, `tokens_out`, `unix_ts`), AND the
pubkey that signature checks against is the one the coordinator
publishes for the resolved `provider_id` at verification time (or
was within the §7.5.2 rotation grace window per §10.2.1).

The phrasing "signed a tuple containing `unix_ts`" is deliberate:
the signature commits the holder of the private key to the claimed
timestamp value, but does NOT prove that value reflects the real
wall-clock time at signing. The signed-at attestation is about
content, not chronology.

A `valid` result DOES NOT prove:

- **That the response was generated by the model named in
  `model_id`.** Model-hash binding is the SPEC-011 v0.5
  catalog-signing surface; folding `model_hash` into the receipt
  tuple is the v0.3+ candidate per §15 Q6. A v0.2 verifier MUST
  NOT silently treat `valid` as "model attestation."
- **That `unix_ts` is honest.** The timestamp is provider-reported.
  The verifier MAY optionally cross-check against a buyer-recorded
  received-at timestamp with an operator-set skew window, but v0.2
  does NOT require this check (see §15 Q4), and a `valid` result
  without skew-check does NOT attest to timestamp honesty.
- **That no other party also saw the response.** Privacy
  properties are SPEC-008 / Cluster E territory and are orthogonal
  to receipt verification. A receipt with `valid` says nothing
  about whether the operator, the coordinator, the gateway, or
  another buyer also observed the response bytes.
- **That the pubkey itself is trustworthy in some absolute sense.**
  v0.1's §8 trust root (`/poolz`) is operator-mutable. The v0.1
  SPEC is honest about this; v0.2 inherits that honesty without
  weakening it. The §15 Q1 stronger-trust-root work (TUF-style
  signing, on-chain anchor) is v0.3+ scope.
- **That the response was delivered to the buyer who is now
  verifying it.** A receipt commits to (prompt, output, provider);
  it does not commit to `request_id` or a buyer-supplied nonce.
  Replay-resistance is §15 Q2 (v0.2 verifier scope per the v0.1
  text, now deferred to v0.3+ — see §15 Q2 update below).
- **That this was the only receipt issued for this response.** A
  receipt does not commit to uniqueness. A provider could in
  principle issue multiple receipts for the same canonical
  (prompt, output) tuple — to different buyers, on different
  reconnects, or by re-running the same prompt. Each receipt
  independently verifies on its own merits; `valid` says nothing
  about whether another `valid` receipt also exists. This matters
  for accounting (a buyer cannot use a receipt as proof of
  sole-delivery for billing-dispute purposes) and is orthogonal
  to the replay-resistance concern above.

A `valid` result from `macprovider verify` is therefore a narrow,
specific proof: cryptographic evidence that some holder of the
provider's signing key — which the coordinator currently endorses
— attests to having produced this (prompt → output) mapping. It
is necessary for verifiable inference. It is not sufficient.
SPEC-015 v0.3+ closes the remaining gaps (model attestation,
timestamp honesty, replay resistance, stronger trust root) in
priority order determined by audit-loop and operator demand.

A verifier's human-mode output line for `valid` SHOULD frame this
scope visibly — e.g. by including the phrase `signed by m1-anon`
rather than `verified m1-anon`. The `--explain` flag of §10.4.2
exists precisely to make this trust boundary unmissable to a
buyer who is about to act on a `valid` result.

### 10.7 SPEC-002 v1.5 candidate annotation: `GET /v1/receipt-keys/<provider_id>`

v0.2's verifier contract depends on a public, buyer-callable
pubkey-resolution endpoint that the locked SPEC-002 v1.4 surface
does not provide (`GET /poolz` is operator-only per §FR-O2;
`GET /v1/pool/check` does not return receipt-key material). v0.2
pins the buyer endpoint as a SPEC-002 v1.5 **candidate annotation**
following the same parser-optional / additive / non-breaking
pattern v0.1 used for `receipt_pubkey` (SPEC-002 v1.4 candidate)
and `provider_receipt_public_key` (SPEC-001 v1.6 candidate).

A SPEC-002 v1.5 release MUST add the endpoint as specified below;
SPEC-015 v0.2 implementations MAY use it before SPEC-002 v1.5 LOCK
provided the coordinator returns the exact shape.

**Endpoint:** `GET /v1/receipt-keys/<provider_id>`

- **Host placement:** Same nginx route split as the existing
  buyer-facing `GET /v1/pool/check` (SPEC-002 v1.4 §FR-O3) — i.e.
  on the `buyer_port` route, NOT the operator `/poolz` route.
- **Authentication:** NONE (public). A buyer with no operator
  credentials MUST be able to call this endpoint. Pubkey
  attestation is a public-trust-root surface — the same property
  TUF / on-chain anchoring (§15 Q1) layers on top of.
- **Rate limiting:** Operator-configurable; recommended floor
  `10 req/sec` per source IP, with a `429` response on overage.
  This protects the coordinator against amplification attacks
  while leaving headroom for batch buyer-side verification.
- **Caching headers:** Response MUST include `Cache-Control: public,
  max-age=300` (5 minutes). Verifiers SHOULD NOT bypass this cache
  via `Cache-Control: no-cache` request headers — staleness up to
  5 minutes is acceptable for receipt verification, and bypass
  attacks would defeat the rate-limit.

**Response (success, HTTP 200):**

```json
{
  "provider_id": "m1-anon",
  "receipt_pubkey": "<44-char base64 ed25519 pubkey>",
  "receipt_pubkey_prev": null | {
    "pubkey": "<44-char base64 ed25519 pubkey>",
    "rotated_at": "<RFC3339 UTC>",
    "expires_at": "<RFC3339 UTC>"
  },
  "fetched_at": "<RFC3339 UTC; server-side now()>"
}
```

The `receipt_pubkey` and `receipt_pubkey_prev` fields MUST be
sourced from the same coordinator memory the SPEC-002 v1.4 §FR-O2
`/poolz` response reads (i.e. the in-memory `Provider.ReceiptPubkey`
state per §13). Response MUST NOT leak any operator-sensitive
field (e.g. `endpoint_url`, `hostname`, `connected_at`,
`slots_total`, `throughput_tps_estimate`) — only the receipt-key
tuple.

**Response (error):**

- **404** — `provider_id` not in the current pool. Body is the
  SPEC-002 §FR-X-N standard JSON error envelope with
  `error.code = provider_not_found`. The verifier treats this as
  `inconclusive` with `reason: "provider_id_not_in_pool"`, NOT
  `invalid`: the provider may have been retired, but the receipt
  is not necessarily a forgery.
- **429** — rate limit exceeded. Verifier treats as a fetch
  failure (contributing to `inconclusive` if no cache), MUST NOT
  retry within the same verification invocation.
- **5xx** — coordinator internal failure. Same fetch-failure
  treatment as `429`.

**Reference behavior on rotation:** Within the §7.5.2 7-day grace
window, the response carries BOTH `receipt_pubkey` (the new key)
AND `receipt_pubkey_prev` (the previous key block, with
`rotated_at` and `expires_at`). After the grace window expires,
the coordinator MUST drop `receipt_pubkey_prev` (set to `null`).
This precisely mirrors the existing `/poolz` `receipt_pubkey_prev`
shape so SPEC-002 v1.5 reuses the v1.4 data model.

**Why this is a candidate annotation, not an operator demand:**
the SPEC-002 v1.5 amendment is additive (new endpoint, no changes
to existing endpoints), non-breaking (`/poolz` retains operator-
only access), parser-optional (a SPEC-002 v1.4 coordinator without
the new endpoint returns `404`; verifier treats as `inconclusive`
and falls back to explicit/cache). This matches the SPEC-008 v0.3
§5.3 / §5.7 candidate-annotation pattern used throughout the
v0.1-line cross-cuts.

---

## 11. Audit categories

The following audit categories are added (SPEC-006 v0.9 candidate
absorption; tracked locally for now):

- `receipt_issued`: emitted by the provider when a receipt is written
  to the response. Event-specific fields: `model_id`, `tokens_out`,
  `ttft_ms`, `unix_ts`. The audit-record envelope (`provider_id`,
  `request_id`, event timestamp) is inherited from the common
  SPEC-005 v0.3 §6 audit-sink envelope and MUST NOT be duplicated
  inside the event-specific block. Implementations MUST NOT log the
  receipt's `provider_pubkey`, `prompt_hash`, `output_hash`, or
  signature into the audit sink: the receipt is a buyer-held proof,
  not a server-side audit row.
- `receipt_omitted`: emitted by the provider/coordinator/gateway when
  a receipt is suppressed per §6.4. Fields: `provider_id`,
  `request_id`, `reason` (`pre_v1_6_binary` | `no_keypair` |
  `model_swap_violation` | `pre_token_cancel` | `streaming_request`).
- `receipt_rotation_detected`: emitted by the coordinator when a
  reconnecting provider's `auth_request.provider_receipt_public_key`
  differs from the previously-known pubkey for that `provider_id`.
  Fields: `provider_id`, `old_pubkey`, `new_pubkey`, `rotated_at`.
  This event replaces the v0.1/v0.1.1 `receipt_rotate_request` and
  `receipt_rotate_invalid` events, which are no longer emitted
  because v0.1.2 rotation is reconnect-based, not control-frame
  based.

`receipt_issued` is a high-cardinality event (one per response). Its
audit destination is the existing SPEC-005 v0.3 §6 billing audit
sink; the four event-specific scalar fields named above
(`model_id`, `tokens_out`, `ttft_ms`, `unix_ts`) plus the inherited
audit envelope are the complete v0.1.3 audit shape.

---

## 12. Failure modes summary

All rows below describe **non-streaming** `POST /v1/chat/completions`
behavior. Streaming requests carry no receipt regardless of outcome.

| Condition | Receipt? | Header value | finish_reason | tokens_out |
|---|---|---|---|---|
| Normal non-streaming completion | yes (header) | populated | `stop` \| `length` \| `tool_calls` \| `content_filter` | reported |
| Streaming request (any outcome) | no (v0.1.x out of scope; v0.2+ design pending) | absent | n/a | n/a |
| Buyer HTTP disconnect mid-response on non-streaming | no | absent | n/a | n/a (provider has no full response to commit to and no buyer to deliver a receipt to) |
| Provider returns SPEC-001 null-usage error | yes | populated | `error` | `0` |
| Pre-v1.6 binary | no | absent | n/a | n/a |
| Model swap drain violation (defensive) | no, 500 returned | absent | n/a | n/a |
| Gateway/coordinator internal failure (provider never reached) | no | absent | n/a | n/a |

SPEC-005 v0.3 §X-1 settlement semantics for non-streaming
disconnects continue to apply on the billing side; v0.1.x simply
declines to emit a receipt for the partial-response disconnect case
because there is no buyer-deliverable receipt to commit to. A
v0.2+ design that captures partial-response receipts is open
design space.

---

## 13. Storage and persistence

v0.1.3 pins ONLY the provider-side Keychain storage (because the
private key is a security-critical artifact) and the audit-log
emission (because audit events are observable behavior). Coordinator
and gateway storage are implementation concerns named in the future
BUILD spec, per the §7.3 deferral.

| Surface | Field | Type | Notes |
|---|---|---|---|
| Provider Keychain | `com.streamvc.macprovider.receipt-key/<provider_id>` | 32-byte raw ed25519 private key | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `Synchronizable=false` |
| Coordinator memory | `Provider.ReceiptPubkey []byte` | 32 bytes | populated on auth, lifetime tied to WS session unless the BUILD spec adds durable storage |
| Audit log | `receipt_issued` event | JSON | per response, fields per §11 |

The coordinator and gateway MUST NOT store the receipt value (the
`X-MacProvider-Receipt` header bytes) server-side under v0.1.x. The
receipt is buyer-held proof; persisting it server-side would defeat
the offline-verifiability property and create a server-side trove
of prompt/output digests the operator does not need. There is no
exception in v0.1.x: streaming receipts are out of scope (§6.3), so
no server-side retention is needed for any v0.1.x receipt path. A
future v0.2+ streaming-receipt design that needs server-side
storage MUST name its own retention contract and re-establish the
buyer-held-proof posture or accept the v0.1.x divergence
explicitly.

---

## 14. Acceptance criteria

Each AC is independently verifiable from outside this SPEC.

**AC-1.** A v1.6 `phase3-binary serve` process on first launch
generates an ed25519 keypair, stores it in macOS Keychain at
service `com.streamvc.macprovider.receipt-key` account
`<provider_id>`, and on a fresh launch with the same `provider_id`
reads the same private key bytes from Keychain (verify by computing
the public key from the stored private key and comparing against the
expected pubkey).

**AC-2.** A v1.6 binary's v2 `auth_request` initial-stage frame
carries `provider_receipt_public_key` as a 44-character base64
string. Decoding it yields exactly 32 bytes.

**AC-3.** A v1.5 binary (pre-v1.6) does NOT carry
`provider_receipt_public_key` on the auth frame; the coordinator
admits it successfully and its `/poolz` row shows
`receipt_pubkey: null`.

**AC-4.** For a v1.6 provider serving a non-streaming
`POST /v1/chat/completions` with a fixed model, prompt, and
`temperature: 0`, the response carries an `X-MacProvider-Receipt`
header. The value parses as `<base64>.<base64>`. The first base64
decodes to UTF-8 JSON containing exactly the seven SPEC-015 §3.1
keys; the second base64 decodes to exactly 64 bytes.

**AC-5.** For the same request as AC-4, recomputing the canonical
prompt object per §4 and hashing it yields a 64-character lowercase
hex string identical to `receipt.prompt_hash`.

**AC-6.** For the same request as AC-4, recomputing the canonical
output object per §5 from the response body and hashing it yields a
64-character lowercase hex string identical to `receipt.output_hash`.

**AC-7.** For the same request as AC-4,
`ed25519_verify(receipt.provider_pubkey, base64_decode(b64_tuple),
base64_decode(b64_sig))` returns true.

**AC-8.** For a streaming `POST /v1/chat/completions`, the response
carries NO `X-MacProvider-Receipt` header AND NO additional
`X-MacProvider-*` response header beyond what SPEC-006 v0.8.3 §17
already allowlists. The SSE stream itself is exactly what SPEC-001
v1.5 and SPEC-006 v0.8.3 already specify (no extra `event:` blocks,
no non-OpenAI-shaped `data:` payloads). Receipts for streaming
requests are out of scope in v0.1.x.

**AC-9.** The OpenAI Python SDK ≥ v1.0 and the OpenAI JavaScript
SDK ≥ v4.0, with `base_url` pointing at the SPEC-006 gateway, MUST
complete `chat.completions.create(...)` (non-streaming) AND
`chat.completions.create(stream=True)` successfully against a v1.6
provider. The non-streaming response carries an
`X-MacProvider-Receipt` header (which the SDK ignores transparently);
the streaming response carries no SPEC-015 wire changes. The SDK
MUST NOT raise on either request shape.

**AC-10.** Running `macprovider rotate-key` on a connected
v1.6 binary causes the binary to close its current WS connection
and reconnect with a freshly-generated keypair in the v2
`auth_request` initial-stage `provider_receipt_public_key` field.
On successful reconnect, the coordinator's `/poolz` row for this
provider reflects the new pubkey under `receipt_pubkey` and the old
pubkey under `receipt_pubkey_prev` with
`rotated_at` = the reconnect time. The next response after rotation
is signed with the new key. If reconnect fails (coordinator rejects
auth or network failure), the CLI exits non-zero, the Keychain
state is unchanged, and the binary continues signing with the old
key on its restored WS session.

**AC-11.** During the 7-day rotation grace window, a buyer who
fetches `/poolz`, sees `receipt_pubkey_prev.expires_at` in the
future, and verifies a receipt against `receipt_pubkey_prev.pubkey`
succeeds for receipts whose `unix_ts` is between
`receipt_pubkey_prev.rotated_at - 60` and
`receipt_pubkey_prev.expires_at`. The −60 s slack covers in-flight
requests on the old key at rotation time (a provider may have begun
signing a receipt with the old key up to ~60 s before the
reconnect-based rotation was accepted by the coordinator).

**AC-12.** A SPEC-001 null-usage error response (e.g.
`error_model_not_loaded`) on a v1.6 provider carries an
`X-MacProvider-Receipt` header with `tokens_out: 0`,
`output_hash` equal to the sha256 of the canonical output object
`{"content":"","tool_calls":null,"finish_reason":"error"}`, and
verifies cleanly against the provider pubkey.

**AC-13.** A request that the gateway rejects before reaching any
provider (auth failure, quota exhausted, kill switch on) does NOT
carry an `X-MacProvider-Receipt` header.

**AC-14.** A non-streaming request routed to a coordinator-recorded
provider whose `receipt_pubkey` is `null` (pre-v1.6 binary) does
NOT carry an `X-MacProvider-Receipt` header.

**AC-15.** The `X-MacProvider-Receipt` header value is ≤ 4096
ASCII bytes for the v0.1.3 tuple shape; nginx between gateway and
buyer MUST be configured (or already configured) to forward headers
of this size without truncation.

**AC-16.** The receipt-issuing path MUST NOT introduce >5 ms p95
overhead over the existing SPEC-001 v1.5 baseline for a
1024-output-token completion on the smallest supported model. The
overhead is dominated by SHA-256 + ed25519_sign on a payload of ≤
600 bytes; on Apple Silicon, both are sub-millisecond.

**AC-17.** The SPEC-001 v1.6 candidate annotation
(`provider_receipt_public_key` field on `auth_request` initial-stage
ONLY) MUST be parser-optional on the coordinator: a v1.6 binary
that omits the field due to keypair-generation failure MUST still
admit successfully, the coordinator MUST log
`receipt_omitted: reason=no_keypair`, and the provider MUST be
flagged in its `/poolz` row as `receipt_pubkey: null` until a
subsequent reconnect with the field present.

### v0.2 additions: verifier acceptance criteria

**AC-18.** `macprovider verify --bundle <fresh-receipt-bundle.json>`
MUST exit `0` with `result: "valid"` for a bundle whose receipt
was issued by a v1.6 binary against a matching prompt/response,
where `GET /v1/receipt-keys/<bundle.provider_id>` (§10.7) on the
configured coordinator returns the issuing pubkey as
`receipt_pubkey` (current key) at the time of verification.

**AC-19.** Flipping a single byte in
`response.choices[0].message.content` of the bundle and re-running
`macprovider verify --bundle ...` MUST exit `1` with
`result: "invalid"`, `details.field: "output_hash"`, and the
non-matching computed/receipt hash pair populated.

**AC-20.** Flipping a single character in
`request.messages[0].content` (e.g. a single Unicode codepoint
change) MUST exit `1` with `result: "invalid"` and
`details.field: "prompt_hash"`.

**AC-21.** Mutating any byte of the base64-decoded signed tuple
(e.g. flipping the last digit of `unix_ts`) without re-signing
MUST exit `1` with `result: "invalid"` and `reason` referencing
signature verification failure (the signature check fails before
any field-level mismatch is reported).

**AC-22.** With `GET /v1/receipt-keys/<provider_id>` unreachable
(configured coordinator host returns connection refused, 5xx, or
timeout within the §10.5 5-second budget) AND no fresh cached
entry for `(coordinator_host, provider_id, receipt_pubkey)` AND no
`--pubkey` argument, `macprovider verify --bundle <bundle.json>`
MUST exit `2` with `result: "inconclusive"`,
`trust_source: "none"`, and a `warnings[]` entry of kind
`live_check_skipped` with `reason: "network_unreachable"`.

**AC-23.** `macprovider verify --offline --pubkey
<correct-44-char-base64> --provider-id <id> --bundle <bundle.json>`
MUST exit `0` with `result: "valid"` AND emit ZERO network traffic
to any host. (Test this by running in a sandbox that denies all
egress; observe exit 0 and no DNS / TCP attempts.) JSON output
MUST include a `warnings[]` entry of kind `live_check_skipped`
with `reason: "offline_flag"`.

**AC-24.** `macprovider verify --json` output MUST be exactly one
line of JSON conforming to the §10.4.2 field table. The verifier
implementation's release artifact MUST include a JSON-Schema
document covering `valid`, `invalid`, and `inconclusive` outputs
(including the `details` and `warnings[]` shapes), and the
verifier's test suite MUST validate every output across its
acceptance fixtures against that schema. The schema document MUST
be addressable from the release (e.g. published alongside the
binary) so independent buyer-side automation can validate verifier
output without re-deriving the schema from this spec.

**AC-25.** Each of the five normative exit codes (`0`, `1`, `2`,
`64`, `65`) MUST be reachable by a concrete invocation pinned in
the verifier's acceptance test suite. `64` is reachable e.g. via
`macprovider verify --unknown-flag` or `macprovider verify
--pubkey badbase64== --bundle good.json` (malformed flag value).
`65` is reachable e.g. via `macprovider verify --bundle
<malformed.json>`, a bundle with `bundle_version: 99`, a bundle
with an unknown top-level key, or a receipt header value that
fails to split on `.`. The `64` vs `65` boundary defined in
§10.4.3 MUST hold across all paths.

**AC-26.** A cache entry whose `fetched_at` is more than 7 days
before the verifier's wall clock MUST trigger a fresh
`GET /v1/receipt-keys/<provider_id>` fetch on the next
verification attempt that would use it. The acceptance test suite
MUST verify this by mocking the cache `fetched_at` and asserting
an outgoing HTTP `GET /v1/receipt-keys/...` call is made against
the configured coordinator host. If the live fetch fails AND no
fresh source remains, the verifier MUST exit `2`
(`inconclusive`); the stale entry MUST NOT be used to produce
`valid` per §10.2.

**AC-27.** A receipt issued during the §7.5.2 7-day rotation
grace window verifies `valid` if and only if ALL of the following
hold simultaneously: (a) the resolved `/v1/receipt-keys/<provider_id>`
response contains a non-null `receipt_pubkey_prev` block whose
`pubkey` field matches the receipt's `provider_pubkey`, AND (b)
the receipt's `unix_ts` satisfies `rotated_at - 60s ≤ unix_ts ≤
expires_at` per the previous-key block. A previous-key match
OUTSIDE this interval MUST verify `invalid` with
`reason: "previous_key_outside_grace_window"`. A receipt whose
`provider_pubkey` appears in neither `receipt_pubkey` nor
`receipt_pubkey_prev.pubkey` for the resolved `provider_id` MUST
verify `invalid` with `reason: "pubkey_not_endorsed"` (not
`inconclusive`).

---

## 15. Open questions

These are flagged for v0.x audit cycles and are NOT resolved in
v0.1. Implementers MUST NOT pin behavior in v0.1 that pre-decides
these.

**Q1: Stronger trust root.** Should the buyer-facing
`GET /v1/receipt-keys/<provider_id>` endpoint (SPEC-015 v0.2 §10.7
candidate annotation) eventually be signed by an offline operator
key (TUF-style) or anchored to an external registry (AntFeed
provider listing, an on-chain Cluster D-token registry)? v0.2
inherits v0.1's honest acknowledgement that the coordinator-
returned pubkey set is operator-mutable; v0.2 narrows the
buyer-exposed surface from the operator-only `/poolz` to the
public `/v1/receipt-keys` endpoint, but does NOT add a signature
or anchor on top. The §10.7 endpoint is the natural foundation
for the v0.3+ work — TUF / on-chain anchoring would sign the
response shape pinned in §10.7. v0.3+ candidate.

**Q2: Replay-resistance and request-id binding.** The receipt does
NOT bind `request_id`. A malicious replay of the response body to a
different buyer would yield the same `output_hash` for the same
prompt. Should the receipt commit to `request_id` or a buyer-supplied
nonce? If so, where does the buyer obtain its expected `request_id`?
v0.2 §10.6 (trust boundary) names replay-resistance as explicitly
NOT proven by a `valid` result; full normative replay-binding is
deferred to v0.3+ pending operator decision and audit input.

**Q3: Cross-provider routing.** Once Cluster F sharding lands, a
single response may span multiple provider segments. Receipt-per-
segment with a buyer-side concatenation rule, or receipt-per-response
with an embedded route list signed by an aggregating coordinator?
v0.4+ candidate.

**Q4: Timestamp trust.** `unix_ts` is provider-reported. Should the
buyer cross-check against the coordinator's response timestamp, and
what skew window is acceptable? **Partially addressed in v0.2:**
§10.6 names timestamp honesty as explicitly NOT proven by a `valid`
result; §10.0 step 9 removes the v0.1-sketch optional skew check
to avoid implying timestamp attestation. Full normative skew-check
(buyer-recorded received-at vs `unix_ts` with operator-set window)
remains v0.3+ candidate pending coordinator-side timestamp surface
and operator skew-policy decision.

**Q5: Streaming receipt delivery mechanism.** v0.1's terminal
`event: receipt` SSE block was rejected in the round-1 audit (C1)
because the OpenAI Python and JavaScript SDKs JSON-parse every
non-`[DONE]` `data:` payload and would raise on a base64 receipt
string. v0.1.1's `X-MacProvider-Receipt-Pending` correlator header
was rejected in the round-2 audit (C1) because it added a second
buyer-visible `X-MacProvider-*` response header outside the single
SPEC-006 v0.9 candidate allowlist annotation. v0.1.2 therefore drops
streaming receipt delivery entirely.

v0.2+ MUST choose one of:

(a) An OpenAI-shape extra field on the final chat-completion chunk
    (e.g. `x_macprovider_receipt` on the last `data: {...}` payload).
    Requires verifying that both SDKs' Pydantic / zod parsers
    tolerate the extra field across pinned versions.
(b) A separate `GET /v1/receipts/<request_id>` endpoint on the
    gateway, with a clearly-bounded retention contract and
    buyer-correlator delivery via an SPEC-006 v0.x candidate
    response header annotation.
(c) An HTTP trailer when the buyer SDK supports it (rare today).
(d) Acceptance that streaming requests never carry receipts — the
    buyer who needs a receipt issues a non-streaming equivalent.

v0.1.2 makes NO choice. The wire format §3.4 of the receipt body
itself MUST remain unchanged across (a)/(b)/(c)/(d). The §6 wire
contract for non-streaming responses is locked in v0.1.2 and v0.2+
MUST NOT change it.

**Q6: Model-hash binding (SPEC-011 cross-cut).** Folding
`heartbeat.model_hash` (SPEC-011 v0.5 §3.3.1) into the receipt
tuple makes the receipt commit to which weights served the buyer.
Gated on SPEC-011 catalog-signing readiness (`beta/DECISION_CRITERIA.md`
Entry 80, Q3 tier-2 posture). v0.3+ candidate.

---

## 16. README compatibility and references

### 16.1 README v1 schema → SPEC-015 v0.1.1 compatibility table

The README §"Roadmap" block at lines 117–128 sketches a v1 receipt
schema. SPEC-015 v0.1.1 changes several field names and conventions
relative to that sketch. The differences are deliberate; the audit
M8 finding required explicit per-field justification.

| README sketch field | SPEC-015 v0.1.1 field | Change | Why |
|---|---|---|---|
| `model` | `model_id` | Renamed | Matches SPEC-001 v1.5 §6.4 and SPEC-002 v1.3.5 naming; `model_id` is the canonical identifier in the rest of the corpus. |
| `prompt_hash: "sha256:7c3f..."` | `prompt_hash: "<64 lowercase hex>"` | Prefix stripped | The receipt only ever uses sha256; embedding the algorithm name doubles the payload and invites parser ambiguity. Verifiers know the algorithm from the SPEC version. |
| `output_hash: "sha256:9b2a..."` | `output_hash: "<64 lowercase hex>"` | Prefix stripped | Same as `prompt_hash`. |
| `provider_id: "m1-anon"` | (NOT in tuple; in `/poolz` only) | Field removed from receipt | The cryptographic identity is the pubkey; `provider_id` is an operator-mutable label and is intentionally out-of-band via `/poolz`. See §3.1 "Why `provider_id` is NOT in the tuple". |
| `provider_pubkey: "ed25519:..."` | `provider_pubkey: "<44-char base64>"` | Algorithm prefix stripped | Same reasoning as the hash prefixes; v0.1.1 pins ed25519. Algorithm agility is v0.x+. |
| `ttft_ms: 646` | `ttft_ms: <int64>` | Unchanged semantics | Pinned as int64. |
| `tokens_out: 142` | `tokens_out: <int64>` | Unchanged semantics | Reused from SPEC-005 §4 `effective_completion_tokens`. |
| `ts: "2026-06-04T12:34:56Z"` | `unix_ts: <int64 Unix seconds UTC>` | Renamed + integerized | RFC3339 strings introduce a canonicalization surface (decimal subseconds, timezone offsets, separator characters) that doesn't add value; integer Unix seconds is unambiguous. |
| `sig: "ed25519:..."` | (transported as the post-`.` segment of the `X-MacProvider-Receipt` header value, not as a tuple field) | Moved out of tuple, prefix stripped | The signature MUST NOT be inside the signed payload. v0.1.1's `<base64-tuple>.<base64-sig>` envelope keeps the two cleanly separated. |
| "issued by the gateway" (README §"Roadmap" prose) | Issued by the PROVIDER | Architectural change | The gateway does not know the provider's private key, by design. Provider-side signing is what makes the receipt verifiable against `/poolz`'s `receipt_pubkey` without trusting the operator. The README will be updated when v0.1.1 lands to reflect provider-side issuance. |

### 16.2 References

- README.md:22 — the verifiable-inference vapor claim this SPEC
  closes.
- README.md:117–128 — the v1 receipt schema sketch (compatibility
  table above explains each deviation).
- `audits/2026-06-10/REPO_AUDIT.md` — Open Question 1 (receipts
  unimplemented) the audit raised.
- `beta/DECISION_CRITERIA.md` Entries 79–81 — operator context for
  the 2-person beta posture in which v0.1 ships.
- SPEC-001 v1.5 §6.7 — v2 `auth_request` handshake, which v0.1
  annotates with the `provider_receipt_public_key` field.
- SPEC-002 v1.3.5 §7 — `/poolz` shape, which v0.1 annotates with
  `receipt_pubkey`.
- SPEC-005 v0.3 §3 X-1 row — null-usage settlement, which v0.1's
  §7.6 receipt for null-usage errors composes with.
- SPEC-005 v0.3 §4 — `effective_completion_tokens` derivation,
  which `tokens_out` reuses.
- SPEC-006 v0.8.3 §17 — header allowlist; SPEC-015 v0.1 adds
  `X-MacProvider-Receipt` to the response pass-through allowlist as
  a SPEC-006 v0.9 candidate.
- SPEC-008 v0.3 §5.3, §6 — Pillar A model-hash and Pillar B
  encrypted-leg semantics; v0.1 is orthogonal to both.
- SPEC-011 v0.5 §3.3.1, §3.8 — `model_hash` heartbeat and warm-swap
  drain; v0.1's §7.4 invariant relies on §3.8.
- SPEC-013 v0.3 — `autotune` subcommand; this SPEC reuses
  `RFC8785JCS.swift` from SPEC-013's implementation.
- RFC 8785 — JSON Canonicalization Scheme.
- RFC 8032 — EdDSA / ed25519.
- `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` —
  in-house JCS implementation.
