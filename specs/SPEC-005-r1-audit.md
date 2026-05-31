# SPEC-005 v0.1 Codex R1 self-audit

## Executive summary

**Verdict: READY WITH FIX PASS.**

SPEC-005 v0.1 is directionally sound: it encodes all D1-D12 locked
operator decisions in § 2, keeps SPEC-002 `request_log` read-only,
defines integer credit arithmetic, mirrors every SPEC-006 § 17.7 D3
request state, names the out-of-scope guards, and includes a normative
D9 recovery algorithm.

The draft is not ready to lock without a v0.2 fix pass. The blocking
issues are precision gaps, not architecture reversals: stable
`provider_id` derivation from current `request_log` facts is
underspecified, recovery cannot deterministically reconstruct
historical rate-card snapshots after config changes, D1-D12 references
are too concentrated in traceability appendices instead of relevant
normative sections, and § 11 endpoint contracts need full JSON examples
plus rate-limit posture.

Finding count:

- CRITICAL: 0
- MAJOR: 7
- MINOR: 4
- QUESTIONS: 3

## CRITICAL findings

No CRITICAL findings.

## MAJOR findings

### M-1. D1-D12 normative references are incomplete outside § 2

- **Severity:** MAJOR
- **Section reference:** § 1, § 5-§ 13, § 16, Appendix B
- **Description:** All 12 decisions are encoded in § 2 and traceable in
  Appendix B, but several relevant normative sections do not explicitly
  cite the decision they implement, so the pre-commitments are easier to
  drift during later edits.
- **Proposed fix:** Add inline `(D#)` citations and one normative
  "This section implements D#" sentence in each section that enforces a
  locked decision.

### M-2. Stable `provider_id` derivation is underspecified

- **Severity:** MAJOR
- **Section reference:** § 4.2, § 4.3, § 8
- **Description:** The draft correctly keys credits on stable
  `provider_id`, but current SPEC-002 `request_log` exposes
  `provider_assigned_id`, not a stable `provider_id`; the draft does not
  specify how the hot path or recovery path resolves assigned session ID
  to stable provider ID without mutating `request_log`.
- **Proposed fix:** Add a normative provider-identity snapshot contract,
  either as a new side table or as required hot-path fields, that maps
  `request_id`, `attempt_n`, and `provider_assigned_id` to stable
  `provider_id`.

### M-3. Recovery cannot reconstruct historical rate-card snapshots
after config changes

- **Severity:** MAJOR
- **Section reference:** § 5.3, § 10.2-§ 10.4, § 13.2
- **Description:** The hot path snapshots rates onto ledger rows, but
  D9 recovery rows are created from `request_log` after a crash; if
  `coordinator.yaml` changes between the original request and recovery,
  the scan lacks a deterministic request-time rate-card snapshot.
- **Proposed fix:** Add a `ledger_config_snapshots` side table or an
  equivalent effective-at config snapshot requirement that recovery uses
  to price historical rows deterministically.

### M-4. `attempt_n` fallback ordering is not deterministic enough

- **Severity:** MAJOR
- **Section reference:** § 4.2, § 8.2, § 20 OQ-1
- **Description:** The draft says the first row uses `attempt_n=0` and
  one explicit retry uses `attempt_n=1`, but it does not define the
  ordering key for "first" and "second" when current `request_log` lacks
  `attempt_n`.
- **Proposed fix:** Define fallback ordering as `request_log.id ASC`
  within each `request_id` and quarantine any state that cannot produce
  a unique ordinal.

### M-5. § 11 endpoints do not include complete JSON examples or rate-limit posture

- **Severity:** MAJOR
- **Section reference:** § 11.1-§ 11.5, § 17
- **Description:** The BUILD prompt required request schema, response
  schema, auth, rate-limit posture, and JSON examples for all four
  endpoints; v0.1 lists fields and auth but omits concrete example
  bodies and rate-limit behavior.
- **Proposed fix:** Add one request/response contract, JSON example,
  auth failure shape, and rate-limit statement for each of the four
  endpoints.

### M-6. Acceptance criteria for D1-D12 are too self-referential

- **Severity:** MAJOR
- **Section reference:** § 18 AC-D1 through AC-D12
- **Description:** The AC-D1 through AC-D12 checks verify that the spec
  text contains decision anchors, but they do not independently verify
  implementation behavior for each decision.
- **Proposed fix:** Keep the text-presence checks as traceability ACs,
  but add behavior-level deterministic fixtures for each D decision.

### M-7. H-005 reconciliation tolerance is not specified precisely

- **Severity:** MAJOR
- **Section reference:** § 10.3, § 11.3, § 18 AC-H005
- **Description:** The draft requires reconciliation delta reporting but
  does not specify whether the accepted tolerance is exactly 0 credits,
  split-rounding-aware, or some bounded value.
- **Proposed fix:** Define H-005 reconciliation as zero tolerance on
  gross credits computed from the same § 5.3 formula, with provider and
  operator split rounding reconciled separately.

## MINOR findings

### N-1. AC-NO-ONCHAIN grep test is ambiguous

- **Severity:** MINOR
- **Section reference:** § 18 AC-NO-ONCHAIN, Appendix G
- **Description:** The AC says to grep for AntFeed/on-chain/USDC terms,
  but the spec intentionally contains those words in out-of-scope
  guards, so a literal keyword grep would false-fail.
- **Proposed fix:** Change the AC to grep for prohibited call/import/
  config patterns, while allowing out-of-scope explanatory mentions.

### N-2. `usage_source='provider_not_reached'` is confusing

- **Severity:** MINOR
- **Section reference:** § 4.3, § 6.2
- **Description:** The storage contract permits
  `usage_source='provider_not_reached'`, but § 6.2 says no ledger row is
  written for provider-not-reached states.
- **Proposed fix:** Remove the enum value or explicitly reserve it for
  reconciliation summaries outside `ledger_request_credits`.

### N-3. Appendix E duplicates AC content heavily

- **Severity:** MINOR
- **Section reference:** Appendix E
- **Description:** Appendix E repeats every acceptance criterion in a
  second fixture-detail catalog; useful for traceability, but it makes
  v0.1 noisier than necessary.
- **Proposed fix:** In v0.2, keep fixture detail only where it adds
  information not already present in § 18.

### N-4. Admin JSON error shape is not normalized

- **Severity:** MINOR
- **Section reference:** § 17
- **Description:** § 17 says admin endpoints do not need OpenAI-shaped
  errors, but it does not define the coordinator-admin JSON error
  envelope.
- **Proposed fix:** Add a simple admin/provider endpoint error envelope
  such as `{"error":{"code":"...","message":"..."}}`.

## QUESTIONS for the operator

### Q-1. Should v0.2 add a `ledger_config_snapshots` table?

- **Severity:** QUESTION
- **Section reference:** § 10, § 13
- **Description:** Deterministic recovery after rate-card changes needs
  an effective-at config source, and a side table is the cleanest
  SPEC-005-local option.
- **Proposed fix:** Operator decides whether to add
  `ledger_config_snapshots` in SPEC-005 v0.2 or constrain recovery to
  hot-path rows with already snapshotted rates.

### Q-2. Should provider identity snapshots be a side table or embedded columns only?

- **Severity:** QUESTION
- **Section reference:** § 4, § 8
- **Description:** Stable `provider_id` can be resolved at hot-path time
  and stored directly on ledger rows, but recovery from current
  `request_log` may need a durable assigned-session-to-provider mapping.
- **Proposed fix:** Operator chooses between adding a
  `ledger_provider_session_snapshots` table or requiring the SPEC-002
  cross-spec patch to include stable `provider_id`.

### Q-3. Should SPEC-005 implementation wait for the SPEC-002 `attempt_n` patch?

- **Severity:** QUESTION
- **Section reference:** § 4.2, § 8.4, § 20 OQ-1
- **Description:** The v0.1 fallback is safe but limited; implementing
  before the SPEC-002 patch means multi-retry accounting is quarantined
  rather than fully credited.
- **Proposed fix:** Operator decides whether v0.2 requires the
  SPEC-002 patch before build, or permits the quarantining fallback for
  the first implementation pass.
