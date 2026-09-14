# Independent GPT-5.6 Sol review — Build 1 c944 reconciliation plan r4

Date: 2026-09-10  
Reviewer: independent GPT-5.6 Sol plan-verification lane  
Verdict: **FAIL — conflict resolution and implementation remain blocked**  
Finding count: **0 Critical, 0 High, 1 Medium, 0 Low, 4 Info**

## Reviewed inputs

- Historical Build 1 implementation base:
  `914f7cafcdbcfc1805a10f4f34167218341d5587`
- Fresh target `origin/main`:
  `c9445561e4fe00a073926ff2ab0fdb0536d00e37`
- Reconciliation r1, verified SHA-256:
  `353fdb88df209785b44ea3c7358fa46b5e6aca608d19ee5121eb49bdeb020f39`
- Reconciliation r2, verified SHA-256:
  `d3093609329f0177318913544fc6d0b351a26d1104b9c8cf43f176e0ff9db44a`
- Reconciliation r3, verified SHA-256:
  `1455757afbcbd2b9ce09f1698281fb67b893f0e5d80adaebe5016c79e5d7742f`
- Reconciliation r4, verified SHA-256:
  `d04e35782a967c79f9d9b7adc2e62ca727582e39f5f66ab2dc5dd64f9d82452d`
- Test specification r5, verified SHA-256:
  `75c942bba7bad61297de5a2567eb06ad436e1944522437f647135023136e6576`
- Test specification r6, verified SHA-256:
  `69cded9a4aa91c68abccb9bd740f6a78e5c965d571401a8559946cbb9036ffec`
- Test specification r7, verified SHA-256:
  `179672cd03554a12eb18393ba520bf560e27f1d6c1f27c84653e10d5c83533d6`
- Test specification r8, verified SHA-256:
  `caa138875eca644117e7ebe0664c0b81892d0bb834626e9856684660d08ff479`
- Prior failed r3 review, verified SHA-256:
  `c585a4062fe06f9d5208d2e9c8688330e12293beba22ce1528951da6c053ca4d`

This review inspected the complete exact r1-r4 and r5-r8 bundles, target c944
through `git show origin/main:<path>`, the dirty Build 1 implementation at its
historical base, all production and test references to the affected WS
publishers, the SQLite append path, and the relevant SPEC-005, SPEC-010,
SPEC-011, SPEC-015, SPEC-022, SPEC-023, SPEC-044, and SPEC-047 contracts. The
target delta from the historical base contains 47 paths. No GPT-5.5 output was
used as evidence. This is a pre-implementation plan gate, so implementation
tests were not run.

## Gate result

The required zero-Critical/High/Medium gate is not met. R4 closes the prior H6,
M4, and M5 findings at their reported boundaries: it mandates a conflict-free
SPEC-047 successor before runtime work, makes the existing direct admission
setter fail closed, binds positive publication to an opaque one-shot WS
catalog/index token, and requires raw-token null rejection for every field.
The complete bundle nevertheless leaves one narrower normative ambiguity: the
runtime and tests reject exponent and fractional JSON number tokens even when
their value is an integer, while the required authoritative amendment specifies
only the JSON type `integer` and never owns that lexical restriction.

## Finding

### M6 — The normative amendment does not own the decoder's integer-token grammar

**Severity:** Medium  
**Confidence:** High from the exact plan/spec text.  
**Disposition:** New gate finding; it does not downgrade prior H6.

**Evidence:** R3 defines the eight numeric members only as “integers” and says
wrong JSON types fail
(`origin-main-c944-reconciliation-addendum-r3.md:79-108`). R4-01 requires the
new SPEC-047 version to own the complete envelope and cite existing economics
owners, but its normative-amendment instructions add only all-or-none, non-null,
unknown/extra/duplicate-key, relationship, and canonical-preimage rules; they do
not require SPEC-047 to define a lexical JSON-number grammar
(`origin-main-c944-reconciliation-addendum-r4.md:16-54`). The separate runtime
section requires rejection of floating-point and exponent forms and accepts zero
only as an exact integer-valued JSON number (`r4:82-93`). R8 then requires every
numeric field to reject fractional and exponent forms (`test-spec-r8-c944-normative-null-setter.md:27-43`).

The cited current owner rules do not close this distinction. For example,
SPEC-005 declares rates and configuration values as integer columns/values and
defines their ranges and arithmetic, but it does not define the lexical form of
these new SPEC-047 JSON members. Target c944 has no v2 fields at all: SPEC-047
v0.1.4 owns only the historical six-field optional record
(`c9445561:specs/SPEC-047-network-model-admission.md:117`), and its route snapshot
uses typed `int64` values only after construction
(`c9445561:phase4-coordinator/internal/billing/route_snapshot.go:38-170`). Thus
the missing rule cannot be inherited from c944 compatibility behavior.

**Consequence:** The normative successor can describe a value such as `1e3` or
`1.0` as an integer-valued JSON number while the mandated decoder rejects it.
Another conforming producer or recovery tool can therefore emit a value that it
reasonably considers valid under the owner SPEC but that this implementation
classifies as corrupt. Conversely, a later decoder can accept such a token while
still claiming the SPEC's integer type, creating inconsistent closed-envelope
and canonicalization behavior on persisted money-path evidence. The tests would
prove implementation behavior that the authoritative versioned contract does
not require.

**Required correction:** Extend R4-01 so the SPEC-047 amendment explicitly owns
the lexical grammar for all eight numeric v2 members. State whether the accepted
form is a base-10 JSON token matching `-?(0|[1-9][0-9]*)` or a narrower
non-negative form, whether `-0` is accepted, the exact int64/safe-canonicalization
bounds, and that fraction and exponent syntax are rejected even when the value
is mathematically integral. Preserve each owner-defined range and zero-valid
rule after token parsing. Extend R8-01 so the amended R003/R008 requirement and
its selected conformance tests prove this lexical contract, then retain the
existing R8-02 per-field matrix unchanged.

## Prior-finding disposition

| Finding | Result | Evidence |
|---|---|---|
| H1 live generation at historical settlement | **Closed** | R2 separates live pre-dispatch freshness from immutable snapshot-only receipt verification, settlement, restart, reconciliation, and replay; R6 proves G remains settleable after G+1 while a new G route fails (`r2:14-29`; `r6:8-20`). |
| H2/H2-R complete publication ownership | **Closed** | R3 adds the actual WS `autotuneCatalogMu`, active/compatible catalog and member-index pointer/generation, combined publication, fail-closed split setters, and session refresh (`r3:14-45`). R7 pauses each concrete owner and setter (`r7:12-32`). |
| H3 durable GGUF retry identity | **Closed** | R2 defines private journal v2 with original descriptor-derived identity and a fresh no-follow full rehash; legacy GGUF v1 cannot retry. R6 covers restart and every named substitution (`r2:76-98`; `r6:38-52`). |
| H4/H4-R exact historical and v2 schemas | **Closed apart from new M6** | R3 enumerates one discriminator plus exactly 24 fields and preserves the discriminator-free c944 six-field spelling and empty class. R7 supplies exact canonical-byte/digest and rejection coverage (`r3:77-116`; `r7:63-90`). |
| H5 SQLite-first ordering | **Closed** | R3 makes memory serialization or successful SQLite `BEGIN IMMEDIATE` Phase A, with no authority pins while waiting, followed by ordered bounded Phase-B try-locks and rollback/release (`r3:47-75`). R7 tests external-BEGIN, cancellation, every owner, CAS/commit failures, and deadlock bounds (`r7:34-61`). |
| H6 missing authoritative SPEC-047 successor | **Closed at the reported owner/version boundary** | R4-01 requires the c944 SPEC-047 v0.1.4 successor before runtime and updates version-of-record metadata, governance indexes, selectors, exact legacy/v2/no-extension classes, relationships, canonical inclusion, and no-rewrite behavior (`r4:16-54`). M6 is the remaining lexical precision gap. |
| M1 exact rate-lookup domain | **Closed** | Only the coordinator pair-resolved `model_key` enters signed/effective rate lookups; malicious rows under model ID, artifact ID, or provider assertion are tested (`r2:131-144`; `r6:73-83`). |
| M2 durable rollback/recovery | **Closed** | The named ref, verified bundle, private patch/manifests and permissions, frozen source checkout, fresh c944 worktree, exact restoration, and intended-diff checks are required and executable (`r2:146-168`; `r6:94-103`). |
| M3 bounded observability | **Closed** | Stable low-cardinality codes, one-signal requirements, no member storms, and explicit sensitive local-material exclusions are stated and tested (`r2:170-193`; `r6:85-92`). |
| M4 numeric null collapsing to zero | **Closed** | R4 requires duplicate-aware `json.RawMessage` tokenization, exact key membership, and null rejection before typed decode. R8 substitutes null individually into all eight numeric fields and distinguishes valid raw zero (`r4:82-93`; `r8:27-43`). |
| M5 direct positive-preparer setter bypass | **Closed** | R4 makes `SetModelAdmissionAuthority` fail closed or removes it, requires all positive installation to consume an opaque one-shot exact-server/generation token, and migrates production/test callers. R8 inventories and races every direct, combined, and token-consuming call site (`r4:56-80`; `r8:45-68`). |

## Confirmed design and proof boundaries

### I1 — Token-bound publication is feasible and complete

**Severity:** Info

The dirty Build 1 tree currently exposes `SetModelAdmissionAuthority` and calls it
from coordinator startup plus same-package and cross-package tests
(`phase4-coordinator/internal/ws/model_admission_authority.go:37-50`;
`phase4-coordinator/cmd/coordinator/main.go:993`). Target c944 separately exposes
`SetAutotuneCatalog` and `SetArtifactIdentityIndex` under `autotuneCatalogMu`, and
the reload observer currently publishes them in separate operations
(`c9445561:phase4-coordinator/internal/ws/server.go:558-586`;
`c9445561:phase4-coordinator/cmd/coordinator/main.go:951-967,3251-3266`). R4's
unconstructible one-shot token, fail-closed compatibility setters, real-call-site
migration, and R8 call-site/race matrix directly cover this graph. Direct-row
primary and feed-derived member applicability remain distinct through r1/r5;
requiring a coherent paid epoch does not add artifact evidence to the direct-row
snapshot.

### I2 — Locking and SQLite ordering are implementable

**Severity:** Info

The present dirty guard takes authority, session publication/writer, pool,
buyer-feed, billing, settlement, and Tier2/catalog pins, while the SQLite guarded
append already serializes through a transaction. R3 inserts the missing WS
catalog/index owner in the only safe location and explicitly prohibits blocking
Phase-B acquisition before the store transaction. R7 tests both memory and
SQLite serialization, every try-lock boundary, cancellation, rollback, reverse
release, and subsequent progress. No unresolved inversion or token-publication
cycle was found.

### I3 — Trust, pricing, and settlement authority remain separated correctly

**Severity:** Info

C944's verified-member pair remains wire/receipt/settlement identity, the
candidate row remains Tier2/served identity, and the pair-resolved model key is
the rate domain. Current session exclusions and pool pinning remain route-time
authority; captured rates, share, multiplier, receipt key, and billing snapshot
become immutable v2 evidence. R2 correctly ends live feed authority at route
creation and forbids delayed settlement from consulting current feeds, indexes,
or keyrings. The direct-row primary exemption and feed-derived six-value
requirement match SPEC-010-R007(d).

### I4 — Acceptance evidence is scoped honestly

**Severity:** Info

R5-R8 require exact selected/pass/fail/skip counts, durations, commands,
base/head SHAs, and log hashes; zero-selected, skipped, interrupted, stale, and
fixture-only runs do not pass. They retain full coordinator, gateway,
integration, Swift, Xcode, dist, vet, lint, governance, and complete-diff audit
gates. They also keep physical MLX, signed release/feed, hardware, deployment,
economic activation, and production settlement qualification separate from
deterministic fixture evidence.

## Required disposition

Revise the normative amendment and conformance obligation to close M6 without
weakening any r1-r4 or r5-r8 requirement. Recompute the changed artifact hashes
and run a fresh independent GPT-5.6 Sol gate over the complete exact bundle.
Conflict resolution and implementation remain blocked until that review reports
zero Critical, High, and Medium findings.
