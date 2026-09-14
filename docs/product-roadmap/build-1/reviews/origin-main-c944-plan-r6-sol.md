# Independent GPT-5.6 Sol review — Build 1 c944 reconciliation plan r6

Date: 2026-09-10  
Reviewer: independent GPT-5.6 Sol plan-verification lane  
Verdict: **PASS — conflict resolution may proceed under the complete plan**  
Finding count: **0 Critical, 0 High, 0 Medium, 0 Low, 5 Info**  
Architectural status: **CLEAR**

## Reviewed inputs

- Historical Build 1 implementation base:
  `914f7cafcdbcfc1805a10f4f34167218341d5587`
- Fresh target `origin/main`:
  `c9445561e4fe00a073926ff2ab0fdb0536d00e37`
- Reconciliation r1 SHA-256:
  `353fdb88df209785b44ea3c7358fa46b5e6aca608d19ee5121eb49bdeb020f39`
- Reconciliation r2 SHA-256:
  `d3093609329f0177318913544fc6d0b351a26d1104b9c8cf43f176e0ff9db44a`
- Reconciliation r3 SHA-256:
  `1455757afbcbd2b9ce09f1698281fb67b893f0e5d80adaebe5016c79e5d7742f`
- Reconciliation r4 SHA-256:
  `d04e35782a967c79f9d9b7adc2e62ca727582e39f5f66ab2dc5dd64f9d82452d`
- Reconciliation r5 SHA-256:
  `11ab93ac1dd4f2b6c94600885bc1d18cfc40c799c73633e0e43293652376e02e`
- Reconciliation r6 SHA-256:
  `a4b03061e95fe78ec68ad4a02d2aba4a50ae9a364f953e6c0c57af4c9dd3890a`
- Test r5 SHA-256:
  `75c942bba7bad61297de5a2567eb06ad436e1944522437f647135023136e6576`
- Test r6 SHA-256:
  `69cded9a4aa91c68abccb9bd740f6a78e5c965d571401a8559946cbb9036ffec`
- Test r7 SHA-256:
  `179672cd03554a12eb18393ba520bf560e27f1d6c1f27c84653e10d5c83533d6`
- Test r8 SHA-256:
  `caa138875eca644117e7ebe0664c0b81892d0bb834626e9856684660d08ff479`
- Test r9 SHA-256:
  `76ef58c358a40f1cfa90f8a0afc08d2ae1a6feb44bfe5e4a6219a084b81b9b78`
- Test r10 SHA-256:
  `3225b7d5db321d936fb8326df392533d735fdb4f8fd29368c530c0c96ebe45b9`
- Prior r5 review SHA-256:
  `bd80648447d0e45ae1a334bf6e3cd1414f6bc8a7dc106b16df41da17ccfea296`

Every supplied hash was recomputed from the worktree and matched. After a fresh
fetch, `origin/main` still resolved to the exact target SHA above. The target
delta contains 47 paths, the tracked Build 1 diff contains 54 paths, and their
tracked overlap remains exactly 15 paths. No GPT-5.5 output was used as review
evidence. This was a direct GPT-5.6 Sol review; no subordinate review output was
used.

## Gate result

The required gate is met: **zero Critical, High, and Medium findings**.

Reconciliation r6 and test r10 close prior M7 at the exact interoperability
boundary. The common v2 schema accepts only integers from zero through
`9007199254740991` (`2^53 - 1`) after r5's exact token grammar and before each
field owner's narrower range. `9007199254740992` and every larger magnitude are
rejected before canonicalization, persistence, routing, or settlement. R10
requires comparison of exact canonical bytes and SHA-256 between the repository
canonicalizer and a separate RFC-8785-compatible binary64 serializer, including
`9007199254740990`, `9007199254740991`, and rejected
`9007199254740992` (`origin-main-c944-reconciliation-addendum-r6.md:9-29`;
`test-spec-r10-c944-safe-integers.md:8-26`).

That boundary matches the protocol dependency. RFC 8785 requires JCS input to
be I-JSON, requires number data to be expressible as IEEE-754 binary64, and uses
ECMAScript number serialization. RFC 7493 identifies integers in the inclusive
range `[-(2^53)+1, (2^53)-1]` as interoperable exact integers. The proposed v2
grammar is non-negative, so its exact common ceiling is `2^53 - 1`.

The target repository helper currently emits Go `int64` and integer
`json.Number` values with exact decimal formatting
(`phase4-coordinator/internal/jcs/jcs.go:63-72,116-132`). An independent
ECMAScript probe confirmed exact serialization at `9007199254740990` and
`9007199254740991`, while `9007199254740993` becomes `9007199254740992` and
`9223372036854775807` becomes `9223372036854776000`. R6 therefore removes the
cross-implementation ambiguity without changing the repository's typed `int64`
storage.

## Findings

### Critical

None.

### High

None.

### Medium

None.

### Low

None.

## Prior-finding disposition

| Finding | Result | Independent evidence |
|---|---|---|
| H1 — live generation used by historical settlement | **Closed** | R2 ends mutable authority at route-snapshot creation and limits later receipt verification, settlement, recovery, and replay to immutable route/billing snapshots and the receipt tuple. R6 tests a G route after G+1 and requires current feed/index/keyring accessors to remain unused (`r2:14-29`; `test r6:8-20`). This matches SPEC-022's immutable per-attempt snapshot rule and the target settlement recompute path. |
| H2/H2-R — incomplete publication owner graph | **Closed** | R3 adds the target's distinct WS `autotuneCatalogMu`, exact catalog/index pointers and generation, combined publication, invalidating split setters, session refresh, and the complete buyer/billing/Tier2 generations (`r3:14-45`). R4 makes positive installation consume a one-shot exact-server token from that publication (`r4:56-80`). R7/R8 exercise all split, combined, token, boot, reload, observer, and test seams under race. |
| H3 — GGUF retry lacks durable original file identity | **Closed** | R2 journal v2 stores the original descriptor-derived device/inode/size/high-precision mtime, resolved locator digest, algorithm, and computed digest in the private journal, then requires no-follow reopen and full deadline-bounded rehash before a freshly signed retry. Legacy v1 GGUF cannot retry (`r2:76-98`). Test r6 enumerates every identity, path, byte, digest, missing-file, and deadline substitution (`test r6:38-52`). |
| H4/H4-R — contradictory or incomplete snapshot schemas | **Closed** | R3 defines exactly one discriminator plus 24 required v2 fields, all present and canonicalized, while preserving the exact discriminator-free c944 six-field spelling and no-extension class (`r3:77-116`). R4 adds strict raw-token classification; R7/R8 cover exact shapes, every missing field, duplicates, extras, nulls, wrong types, both spellings, canonical substitution, restart, and replay. |
| H5 — authority pins precede SQLite serialization | **Closed** | R3 requires memory serialization or a reserved connection plus successful `BEGIN IMMEDIATE` before any authority pin, followed by ten ordered, bounded, non-blocking Phase-B acquisitions and reverse release (`r3:47-75`). This matches `sqliteutil.Transact`, whose callback runs only after `BEGIN IMMEDIATE` succeeds (`phase4-coordinator/internal/sqliteutil/transact.go:17-30,45-89`). R7 covers external-lock wait, cancellation, every owner, insert/CAS/commit failure, release, and subsequent progress. |
| H6 — no authoritative SPEC-047 successor | **Closed** | R4 requires the SPEC-047 successor before runtime work and updates the document version, change history, README, AUTHORITY, CONFORMANCE, and actual R003/R008 selectors. It normatively owns exact historical/v2/no-extension classes and the 24-field canonical envelope (`r4:16-54`). R5 adds the exact lexical grammar; r6 adds the exact safe-integer ceiling. R8-R10 require governance agreement and non-zero selector execution. |
| M1 — ambiguous pricing lookup identity | **Closed** | R2 makes the coordinator pair-resolved candidate-row `model_key` the sole signed/effective rate lookup key; model ID, artifact ID, and provider assertion cannot select a rate (`r2:131-144`). Test r6 installs attractive malicious rows under those other identities and requires the persisted billing snapshot and receipt price to retain the resolved model-key rate (`test r6:73-83`). This preserves c944's member-pair wire identity separately from row/Tier2 and pricing identity. |
| M2 — recovery anchor is not durable | **Closed** | R2 requires a named backup ref, verified private bundle, tracked patch, untracked manifest, SHA manifest, 0700/0600 permissions, a frozen source checkout, and a fresh hidden c944 worktree (`r2:146-168`). Test r6 verifies exact ref/bundle identity, permissions, exclusions, source preservation, and intended landing diff (`test r6:94-103`). |
| M3 — new fail-closed boundaries lack bounded observability | **Closed** | R2 owns a stable low-cardinality reason set, exactly one bounded signal per failure, no member-loop storms, and explicit local-path/inode/journal/envelope/key redaction (`r2:170-193`). Test r6 asserts signal counts and forbidden-material absence (`test r6:85-92`). |
| M4 — numeric JSON null can collapse to zero | **Closed** | R4 requires duplicate-aware `json.RawMessage` retention, exact keys, and literal-null rejection before scalar decoding (`r4:82-93`). Test r8 substitutes null independently into all eight numeric fields, keeps valid numeric zero distinct, and rejects missing, quoted, fractional, exponent, overflow, boolean, array, object, extra, duplicate, trailing, and both-spelling cases before persistence or settlement (`test r8:27-43`). |
| M5 — direct positive-preparer setter bypass | **Closed** | R4 removes or makes `SetModelAdmissionAuthority` fail closed and permits positive installation only through the opaque combined-publication token. Token replacement, reuse, cross-server use, split setters, clear, reload, generation drift, and failed publication invalidate it (`r4:56-80`). Test r8 inventories and races direct, combined, token-consuming, production, same-package, and cross-package seams (`test r8:45-68`). |
| M6 — lexical integer grammar is not normative | **Closed** | R5 requires SPEC-047 to own the exact token grammar `0|[1-9][0-9]*`, rejecting negative and `-0`, fractions, exponent forms, quoted numbers, null, booleans, arrays, and objects before canonicalization (`r5:9-31`). Test r9 applies that grammar independently to all eight fields, including whitespace and leading-zero behavior, and requires the actual decoder selector in R008 (`test r9:7-27`). |
| M7 — int64 range exceeds exact JCS/I-JSON interchange | **Closed** | R6 supersedes r5's int64 maximum with inclusive `0..9007199254740991`, before owner bounds, and forbids any accepted v2 value from relying on Go's wider integer serialization (`r6:9-29`). R10 tests the boundary on all eight fields and compares repository canonical bytes/digest with a separate binary64 serializer (`test r10:8-26`). |

No Critical finding existed in the prior plan-review lineage, and this fresh
review found none.

## Information findings

### I1 — Field-owner bounds remain intact after the common ceiling

**Severity:** Info  
**Disposition:** Accepted as required implementation behavior.

The eight v2 numeric fields are configuration snapshot ID; three rates;
provider share; global multiplier; and two expiries. R6 applies the common
safe-integer ceiling first, then preserves positive-only configuration/expiry,
non-negative rates and multiplier, and provider-share `0..10000`. Those match
the current evidence validator and SPEC-005's stored money fields
(`phase4-coordinator/internal/billing/artifact_admission.go:29-39,42-58`;
`specs/SPEC-005-billing.md:831-835`). R8/R10 distinguish schema-ceiling
acceptance from the narrower owner verdict, including valid zero where the
economics owner permits it.

### I2 — Trust, pricing, and settlement identities stay separated

**Severity:** Info  
**Disposition:** Preserve through reconciliation.

Target c944 resolves a globally unique canonical `(algorithm, hash)` member,
retains release/feed provenance, pins the first verified session identity, uses
candidate-row material for Tier2, and requires the pair-resolved model key for
pricing. SPEC-047 v0.1.4 requires all six feed-derived values in the immutable
route record and forbids current-feed repair during settlement. R1-R3 retain
these distinct domains while adding captured rate, session, receipt-key, and
expiry authority. Listed-only members remain non-paid; direct row-bound primary
and feed-derived primary/non-primary classes remain distinct.

### I3 — Historical migration remains additive and byte-stable

**Severity:** Info  
**Disposition:** Preserve both digest paths permanently.

Target c944 serializes the sixth historical key as
`artifact_candidate_catalog_sha256` in `RouteSnapshot.Value()` and reconstructs
it on settlement (`origin/main:phase4-coordinator/internal/billing/route_snapshot.go:79-88,148-155`;
`settlement_receipts.go:835-889`). The bundle correctly keeps that exact
discriminator-free class, introduces `candidate_catalog_sha256` only under the
v2 discriminator, rejects both/partial/unknown shapes, compares reconstructed
canonical bytes plus digest, and prohibits rewrite or reconstruction from live
authority.

### I4 — Publication and SQLite lock plans cover the concrete code owners

**Severity:** Info  
**Disposition:** Implement the stated order literally and retain race proofs.

The target exposes split WS catalog/index setters under `autotuneCatalogMu`; the
dirty Build 1 tree exposes `SetModelAdmissionAuthority`; and its prepared guard
currently pins WS authority/session, pool, buyer feeds/billing, settlement, and
Tier2/catalog owners. R3/R4 account for those concrete surfaces, insert the WS
catalog/index owner, make positive publication token-bound, and retain the
SQLite-first no-pins-while-waiting invariant. No unresolved ownership cycle or
setter bypass remains in the plan.

### I5 — Evidence and rollout boundaries remain honest

**Severity:** Info  
**Disposition:** Retain as acceptance caveats.

R5-R10 require exact commands, base/head SHAs, selected/pass/fail/skip counts,
durations, and log hashes; zero-selected, skipped, interrupted, stale, and
fixture-only results do not pass. The bundle also preserves dependency pins and
keeps physical MLX, signed release/feed, hardware, deployment, enforcement,
economic activation, and production settlement outside deterministic local
acceptance.

## Verification performed

- Recomputed all 13 supplied SHA-256 values; all matched exactly.
- Fetched/pruned `origin` and reconfirmed target
  `c9445561e4fe00a073926ff2ab0fdb0536d00e37`.
- Reviewed the full 47-path base-to-target delta, the 54-path tracked Build 1
  diff, and the exact 15-path overlap at the authority boundaries named by the
  plan.
- Inspected target c944 SPEC-005, SPEC-010, SPEC-011, SPEC-015, SPEC-022,
  SPEC-023, SPEC-044, and SPEC-047 plus AUTHORITY/CONFORMANCE ownership.
- Inspected the target JCS number path, artifact index, provider identity pin,
  WS catalog/index setters, buyer feed observer, route snapshot, and settlement
  reconstruction, plus the dirty Build 1 schema, authority setter, guarded
  memory/SQLite commit, and buyer/Tier2/billing/pool pin paths.
- Cross-checked the numeric boundary against RFC 8785 sections 3.1 and 3.2.2.3
  and RFC 7493 section 2.2, then reproduced the ECMAScript boundary behavior
  with Node.js.
- Did not run implementation suites: this is the required pre-conflict plan
  gate and no reconciled c944 implementation exists. No implementation test is
  claimed passed.

## Recommendation

**APPROVE the complete r1-r6/r5-r10 plan bundle for conflict-resolution
implementation.** This approval does not approve the unreconciled source tree,
deployment, release, economic activation, or merge. After implementation, run
the complete targeted and broad validation matrix and fresh full-diff GPT-5.6
Sol code, security, and architecture gates at zero Critical, High, and Medium.
