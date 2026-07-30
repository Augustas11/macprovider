# SPEC-015 v0.4 audit

Scope: v0.4 deltas only, centered on §N "Settlement-capable receipts" in
`specs/SPEC-015-receipts.md`. v0.1/v0.2/v0.3 locked history was treated as
fixed unless a v0.4 clause contradicted it.

Required lock bar: 0 critical / 0 high / 0 medium across code, security,
architect, adversarial verification, and product design critic lanes.

## Final status

SPEC-015 v0.4 is locked at `0.4.2` on 2026-06-30.

Final counts:

| Lane | Final round | Result | Critical | High | Medium |
|---|---:|---|---:|---:|---:|
| Codex code | R3 | READY | 0 | 0 | 0 |
| Codex security | R2 | READY | 0 | 0 | 0 |
| Codex architect | R1 | READY | 0 | 0 | 0 |
| Claude adversarial verification | R1 | READY | 0 | 0 | 0 |
| Claude product design critic | R1 | READY | 0 | 0 | 0 |

Clean lanes were not refired after reaching 0/0/0.

## Codex code lane

### Round 1

Artifact:
`.omc/artifacts/ask/codex-audit-spec-015-v0-4-code-prompt-you-are-auditing-specs-spec--2026-06-30T17-07-29-354Z.md`

Verdict: NEEDS REVISION, 0 critical / 5 high / 2 medium.

Findings:

- `CODE-H-1`: `usage` was not strict enough to implement as a signed tuple
  field.
- `CODE-H-2`: route snapshot digest was not concretely defined and omitted
  SPEC-022-required snapshot fields.
- `CODE-H-3`: streaming `output_hash` canonicalization was not implementable
  enough.
- `CODE-H-4`: chargeability rows were not deterministic.
- `CODE-H-5`: receipt-key binding allowed incompatible implementations.
- `CODE-M-1`: timestamp policy was too abstract for runnable tests.
- `CODE-M-2`: acceptance criteria were not runnable enough for BUILD IMPL.

Resolution: v0.4.1 pinned the strict `usage` object, exact
`route_snapshot_v1` digest input, `provider_receipt_key_id` fingerprint
algorithm, streaming output-prefix hash/range rules, deterministic
terminal-state chargeability, exact terminal timestamp authority, and runnable
AC-43 through AC-71.

### Round 2

Artifact:
`.omc/artifacts/ask/codex-audit-spec-015-v0-4-code-r2-prompt-you-are-re-auditing-specs-2026-06-30T17-13-51-487Z.md`

Verdict: NEEDS REVISION, 0 critical / 2 high / 0 medium.

Findings:

- `CODE-H-1`: v0.4 non-streaming `output_hash` was not deterministically
  implementable because §N.5 defined streaming `stream_output_prefix_v1` but
  allowed non-streaming implementations to use the legacy §5 three-key object
  when "byte-equivalent".
- `CODE-H-2`: v0.4 `attempt_n` used one-based numbering while locked
  SPEC-002/SPEC-005 and current ledger identity use zero-based attempts.

Resolution: v0.4.2 pins streaming and non-streaming settlement output hashing
to the same `settlement_output_v1` JCS object and aligns `attempt_n` with the
zero-based SPEC-002/SPEC-005 ledger identity.

### Round 3

Artifact:
`.omc/artifacts/ask/codex-audit-spec-015-v0-4-code-r3-prompt-you-are-re-auditing-specs-2026-06-30T17-17-53-581Z.md`

Verdict: READY, 0 critical / 0 high / 0 medium.

Closure evidence:

- `CODE-H-1` closed by §N.5 requiring
  `output_hash = sha256(UTF-8(JCS(settlement_output_v1)))` for both streaming
  and non-streaming attempts, and by prohibiting the legacy §5 three-key object
  as the v0.4 settlement hash input.
- `CODE-H-2` closed by §N.1 defining `attempt_n` as zero-based with first
  attempt `0` and retries/failovers incrementing by exactly `1`.
- R1 code findings remained closed across strict usage, route-snapshot digest,
  streaming canonicalization, deterministic chargeability, receipt-key binding,
  timestamp policy, and runnable acceptance criteria.

## Codex security lane

### Round 1

Artifact:
`.omc/artifacts/ask/codex-audit-spec-015-v0-4-security-prompt-you-are-auditing-specs-s-2026-06-30T17-07-52-325Z.md`

Verdict: NEEDS REVISION, 0 critical / 2 high / 3 medium.

Findings:

- `SEC-H-1`: provider-influenced terminal timestamps could weaken late-receipt
  quarantine.
- `SEC-H-2`: route snapshots omitted SPEC-022 route-validity fields.
- `SEC-M-1`: streaming prefix canonicalization/overlap detection was not
  locked.
- `SEC-M-2`: chargeability delegated partial-output rules.
- `SEC-M-3`: v0.4 redaction conflicted with raw pubkeys in
  `receipt_rotation_detected`.

Resolution: v0.4.1 made coordinator/gateway ledger timestamps authoritative,
expanded route snapshots, pinned half-open prefix ranges and overlap authority,
made the chargeability table deterministic, and changed v0.4 rotation audit
rows to fingerprint-only public-key fields.

### Round 2

Artifact:
`.omc/artifacts/ask/codex-audit-spec-015-v0-4-security-r2-prompt-you-are-re-auditing-s-2026-06-30T17-12-31-640Z.md`

Verdict: READY, 0 critical / 0 high / 0 medium.

## Codex architect lane

Artifact:
`.omc/artifacts/ask/codex-audit-spec-015-v0-4-architect-prompt-you-are-auditing-specs--2026-06-30T17-06-35-791Z.md`

Verdict: READY, 0 critical / 0 high / 0 medium.

## Claude adversarial verification lane

Execution: Claude subscription CLI, not API, using
`claude --setting-sources project,local --disallowedTools Bash,Edit,Read,Write,Task --permission-mode dontAsk --output-format text --print ...`.

Verdict: READY, 0 critical / 0 high / 0 medium.

Low advisories were handled or accepted:

- Prompt-hash authority must be coordinator/gateway canonical material.
- Terminal timestamp authority must be coordinator/gateway recorded and only
  echoed by the provider receipt.
- Route snapshot needed paid entrypoint plus provider session/generation ids.
- Wrong `signature_key_alg` needed an explicit AC.
- Usage field names needed pinning.

## Claude product design critic lane

Execution: Claude subscription CLI, not API, using the same subscription CLI
mode as the adversarial lane.

Verdict: READY, 0 critical / 0 high / 0 medium.

Low advisories:

- Provider-facing diagnosis should expose reason codes for rejected settlement
  receipts.
- Buyer/product disclosure placement must stay visible enough to avoid
  overclaiming; AC-68 remains the controlling product claim boundary.
