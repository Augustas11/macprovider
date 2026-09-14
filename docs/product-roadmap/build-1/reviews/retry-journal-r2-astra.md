# Independent retry-journal material-change gate — revision 2

Verdict: **APPROVED FOR IMPLEMENTATION** for this bounded journal addition. Open findings: **0 Critical, 0 High, 0 Medium, 0 Low**. Main plan-r4/test-spec-r4 approval remains unchanged.

Approved addendum: `retry-journal-addendum-r2.md`, SHA-256 `00deea5e17f6cbdf47dd209f63dbfc56e21e770681b83d886d7750d5d585ec6c`, independently checked. Context remains dependency `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e` plus incomplete WIP. The reviewer read the complete revised addendum and compared its complete diff against r1, using the independently inspected Swift runtime/status/request and coordinator retry tuple/reservation code recorded in [the r1 review](retry-journal-r1-astra.md). Only this review file was written. No implementation, tests, operator-store inspection or external operations were performed.

## Finding disposition

**R1 M1 is closed at plan level.** R2 selects the conservative one-unresolved-attempt policy: a different offer B is rejected before HTTP while A remains unresolved; A's complete signed envelope is retained rather than replaced with a marker. Replacement requires explicit authoritative terminal reconciliation. The per-candidate operation lock spans read, journal update, HTTP and reconciliation, while journal generations reject stale completion callbacks. New tests explicitly cover A accepted/response lost, attempted B, byte-identical A retention, timeout/crash and delayed A responses after replacement.

This removes the identified recovery-critical data loss. A local timeout, missing status or generic error is not authoritative terminal rejection and must not be treated as permission to discard A. The revised plan's retention and terminal-reconciliation requirements preserve that distinction.

## Scope and retained implementation obligations

The journal persists an exact validated closed signed envelope and bounded lifecycle metadata, not bearer tokens, private keys or arbitrary discovery documents. The stated private permissions, contained regular files without symlink traversal, atomic writes, identity-derived filenames and payload/count bounds remain applicable. “Validated signed envelope” includes verification of the original canonical signature under the matching current admission public identity before creating a fresh retry signature. Enforce the total count bound atomically across distinct candidate operations, and bound reads before decoding. These are retained interpretations of the approved validation and bounds requirements, not claims that current WIP already implements them.

Retries still require fresh nonce/time/idempotency and current signing identity, use the exact original protected tuple, and depend on coordinator pending-state, tuple, signature and CAS checks. No local journal authorizes a probe, admission transition or positive settlement. Missing/corrupt/stale/key-mismatched records fail closed; no reconstruction from incomplete status is permitted. Explicit withdrawal remains separate and must never be performed silently to make a retry possible.

The existing negative and compatibility tests remain required, supplemented by the replacement/ambiguity cases added in r2. Actual implementation must pass fresh tests and the full cumulative audit gates of the main plan. Plan approval does not validate WIP code or waive operator-custody isolation. Physical preparation-to-settled-request acceptance remains mandatory and unproven.
