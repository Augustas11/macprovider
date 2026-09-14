# Independent GPT-5.6 Sol review — Build 1 c944 reconciliation plan r5

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
- Reconciliation r5, verified SHA-256:
  `11ab93ac1dd4f2b6c94600885bc1d18cfc40c799c73633e0e43293652376e02e`
- Test specification r5, verified SHA-256:
  `75c942bba7bad61297de5a2567eb06ad436e1944522437f647135023136e6576`
- Test specification r6, verified SHA-256:
  `69cded9a4aa91c68abccb9bd740f6a78e5c965d571401a8559946cbb9036ffec`
- Test specification r7, verified SHA-256:
  `179672cd03554a12eb18393ba520bf560e27f1d6c1f27c84653e10d5c83533d6`
- Test specification r8, verified SHA-256:
  `caa138875eca644117e7ebe0664c0b81892d0bb834626e9856684660d08ff479`
- Test specification r9, verified SHA-256:
  `76ef58c358a40f1cfa90f8a0afc08d2ae1a6feb44bfe5e4a6219a084b81b9b78`
- Prior failed r4 review, verified SHA-256:
  `0dbfdb5d8a413971eb9d00258e5ec6a9884ae5cecb9a859654e96751903a9744`

This review independently inspected the complete exact r1-r5 and r5-r9
bundles, the target c944 delta from the historical base, the dirty Build 1
implementation at that base, the affected settlement, publication, SQLite,
journal, schema, pricing, rollback, and observability paths, and the relevant
SPEC-005, SPEC-010, SPEC-011, SPEC-015, SPEC-022, SPEC-023, SPEC-044, and
SPEC-047 contracts. It also checked the bundle's numeric-domain assumptions
against RFC 8785 and its I-JSON dependency, RFC 7493. No GPT-5.5 output was used
as evidence. This is a pre-implementation plan gate, so implementation tests
were not run.

## Gate result

The required zero-Critical/High/Medium gate is not met. R5 and R9 close M6's
lexical ambiguity: they require the exact non-negative JSON-token grammar `0`
or `[1-9][0-9]*` and reject negative, fractional, exponent, quoted, null,
boolean, array, and object forms before canonicalization. The bundle nevertheless
defines the accepted magnitude through signed-int64 maximum while requiring the
same values to participate in an RFC8785 canonical digest. Integers above
`9007199254740991` cannot be expected to survive exact I-JSON interchange, and
the repository's current Go helper emits such `int64` values differently from
the ECMAScript serialization RFC 8785 requires.

## Finding

### M7 — The int64 numeric domain is wider than exact RFC8785 interchange

**Severity:** Medium  
**Confidence:** High from the exact plan, RFC contracts, target implementation,
and a reproducible ECMAScript probe.  
**Disposition:** New gate finding. R5 resolves M6's lexical grammar but introduces
an incompatible upper bound.

**Evidence:** R5 requires every numeric v2 member to use `0|[1-9][0-9]*`, then
accepts magnitudes through `9223372036854775807` and canonicalizes the validated
`int64` (`origin-main-c944-reconciliation-addendum-r5.md:13-31`). R9 requires
`9223372036854775807` to reach every field's owner range check, so this is an
intentional supported protocol value rather than an overflow-only rejection
fixture (`test-spec-r9-c944-integer-grammar.md:9-25`). R3 places all eight
numeric fields inside the exact RFC8785 preimage and digest
(`origin-main-c944-reconciliation-addendum-r3.md:79-116`), and R7 requires exact
RFC8785 canonical bytes and digest (`test-spec-r7-c944-owner-schema-corrections.md:63-90`).

[RFC 8785 section 3.1](https://www.rfc-editor.org/rfc/rfc8785.html#section-3.1)
requires canonicalized JSON number data to be expressible as IEEE 754
double-precision values and recommends strings when longer integer precision is
needed. Its number serialization is the ECMAScript algorithm
([section 3.2.2.3](https://www.rfc-editor.org/rfc/rfc8785.html#section-3.2.2.3)).
The incorporated I-JSON contract states that a sender cannot expect exact
receipt of an integer whose absolute value exceeds `9007199254740991`
([RFC 7493 section 2.2](https://www.rfc-editor.org/rfc/rfc7493.html#section-2.2)).

Target c944's JCS helper serializes `int64` and integer `json.Number` inputs with
exact Go decimal formatting
(`c9445561:phase4-coordinator/internal/jcs/jcs.go:63-72,116-123`), so it would emit the
literal `9223372036854775807`. A conforming ECMAScript parse/serialization path
does not preserve that value:

```text
$ node -e 'for (const s of ["9007199254740991","9007199254740992","9007199254740993","9223372036854775807"]) console.log(s+" -> "+JSON.stringify(JSON.parse(s)))'
9007199254740991 -> 9007199254740991
9007199254740992 -> 9007199254740992
9007199254740993 -> 9007199254740992
9223372036854775807 -> 9223372036854776000
```

The downstream owners do not eliminate the mismatch. SPEC-005 permits any
non-negative stored prompt rate, completion rate, and global multiplier, while
only provider share has the narrower `0..10000` constraint
(`specs/SPEC-005-billing.md:831-835`). R5 also states that positive configuration
and expiry values use their existing bounds after parsing (`r5:26-28`). Thus at
least some values above the exact-interchange limit can proceed to
canonicalization and persistence under the proposed contract.

**Consequence:** A Go producer/consumer following the repository helper can hash
different canonical bytes than a JCS producer, recovery tool, or auditor using
the RFC-required ECMAScript number model. The same accepted v2 evidence can
therefore produce unequal route digests across implementations, causing valid
historical money-path evidence to be rejected after interchange or letting a
rounded value be interpreted differently from the value the original component
priced and persisted. R9 would certify the unsafe domain rather than expose it.

**Required correction:** Keep the lexical grammar and typed `int64` storage, but
change the normative accepted maximum for every numeric JSON token in this
RFC8785 envelope to exactly `9007199254740991` (`2^53 - 1`). Apply the existing
owner-defined range after that common check. Update R9 so `9007199254740991`
reaches each owner range check, while `9007199254740992`, larger integers,
`9223372036854775807`, and signed-int64 overflow fail before canonicalization or
persistence. If full signed-int64 values are a hard product requirement, define
them as canonically formatted JSON strings or replace RFC8785 with a fully named
custom canonical profile across every producer, consumer, recovery tool, SPEC,
and golden fixture; the current combination is not interoperable.

## Prior-finding disposition

| Finding | Result | Evidence |
|---|---|---|
| H1 live generation at historical settlement | **Closed** | R2 ends live authority at route-snapshot creation and confines receipt verification, delayed settlement, restart, reconciliation, and replay to the immutable route/billing evidence (`r2:14-29`). R6 proves a G route settles after G+1 and instruments current feed/index/keyring accessors to remain unused (`r6:8-20`). |
| H2/H2-R complete publication ownership | **Closed** | R3 adds target c944's distinct WS `autotuneCatalogMu`, catalog/index pointer and generation, combined publication, fail-closed split setters, and exact session refresh (`r3:14-45`). R7 pauses each concrete owner and setter and covers every boot/reload path (`r7:12-32`). |
| H3 durable GGUF retry identity | **Closed** | R2 requires private journal v2 to retain original descriptor-derived identity and locator digest, then reopen no-follow and fully rehash before retry; v1 GGUF cannot retry (`r2:76-98`). R6 exercises unchanged restart plus every named identity, locator, byte, digest, and deadline substitution (`r6:38-52`). |
| H4/H4-R exact historical and v2 schemas | **Closed apart from M7's numeric domain** | R3 enumerates exactly one discriminator plus 24 fields and preserves c944's exact discriminator-free six-field legacy spelling and empty class (`r3:77-116`). R7 supplies full-shape canonical, rejection, settlement, restart, and replay proof (`r7:63-90`). |
| H5 SQLite-first ordering | **Closed** | R3 makes memory serialization or a successful SQLite `BEGIN IMMEDIATE` Phase A before every authority pin, then uses ordered bounded Phase-B try-locks with rollback and reverse release (`r3:47-75`). R7 covers external-BEGIN wait, cancellation, every owner, injected failures, release, and deadlock bounds (`r7:34-61`). |
| H6 missing authoritative SPEC-047 successor | **Closed at the reported owner/version boundary; M7 requires one numeric-bound revision** | R4 requires the SPEC-047 successor before runtime, updates version/governance/selectors, and owns exact historical/v2/no-extension classes and canonical inclusion (`r4:16-54`). R8 makes those selectors and governance checks executable (`r8:12-25`). |
| M1 exact rate-lookup domain | **Closed** | Only the coordinator pair-resolved `model_key` may enter signed/effective rate lookups, with malicious rows under other identities required to fail (`r2:131-144`; `r6:73-83`). |
| M2 durable rollback/recovery | **Closed** | R2 defines the named ref, verified private bundle and manifests, frozen source checkout, and fresh hidden c944 replay worktree (`r2:146-168`); R6 verifies ref, bundle, permissions, manifests, source preservation, and intended diff (`r6:94-103`). |
| M3 bounded observability | **Closed** | R2 owns stable low-cardinality codes, one bounded signal, and explicit redactions (`r2:170-193`); R6 asserts exact signal counts and forbidden-material absence (`r6:85-92`). |
| M4 numeric null collapsing to zero | **Closed** | R4 requires duplicate-aware raw-token keyset and null validation before typed decode (`r4:82-93`). R8 substitutes null independently into all eight numeric fields and distinguishes it from valid raw zero (`r8:27-43`). |
| M5 direct positive-preparer setter bypass | **Closed** | R4 removes or makes `SetModelAdmissionAuthority` fail closed and makes positive installation consume an opaque one-shot exact-server/generation token (`r4:56-80`). R8 inventories and races all direct, combined, token-consuming, production, and test call sites (`r8:45-68`). |
| M6 lexical integer grammar | **Closed** | R5 normatively owns the exact non-negative token grammar and all rejected forms (`r5:11-31`). R9 proves the grammar on every numeric field and selects the decoder tests through SPEC-047 R003/R008 (`r9:7-27`). M7 is the remaining magnitude/canonicalization defect. |

## Confirmed design and proof boundaries

### I1 — Historical settlement remains immutable

**Severity:** Info

R2 cleanly separates live route-time freshness from snapshot-only delayed
settlement. The dirty Build 1 path reconstructs artifact evidence from the
stored route and compares the stored canonical bytes/digest and billing
configuration without repairing from current feeds. R6 adds restart, replay,
mutation, and accessor-call proof. No remaining live-generation dependency was
found in the planned historical settlement path.

### I2 — Publication and SQLite ownership are complete

**Severity:** Info

Target c944 exposes a distinct WS catalog/index owner and split setters; the
dirty Build 1 path also has the direct admission-authority setter. R3/R4 include
both surfaces, bind positive publication to one exact catalog/index generation,
and place every authority pin after memory serialization or successful SQLite
`BEGIN IMMEDIATE`. R7/R8 cover the actual owners, setters, observers, token
lifecycle, failures, cancellation, and races. No remaining lock inversion or
positive setter bypass was found.

### I3 — Identity, pricing, and retry authority remain separated

**Severity:** Info

The canonical member pair remains wire and settlement identity, the candidate
row remains served/Tier2 identity, and only the pair-resolved model key selects
rates. The private retry journal retains local file identity without exposing it
on wire, and retry regains mutation authority only after fresh no-follow open,
identity comparison, and full digest verification. The plan preserves these
boundaries across restart and replay.

### I4 — Acceptance and rollback evidence remain bounded

**Severity:** Info

R5-R9 remain additive to the complete validation matrix and require exact
commands, SHAs, selected/pass/fail/skip counts, durations, and log hashes.
Skipped, interrupted, zero-selected, stale, and fixture-only results do not pass.
The private recovery bundle/ref/manifests are verified before replay, while MLX,
signed release/feed, hardware, deployment, economic activation, and production
settlement qualification remain explicitly outside deterministic acceptance.

## Verification performed

- Recomputed every supplied plan, test, and prior-review SHA-256; all matched.
- Confirmed the historical base and target commit identities exactly.
- Reviewed the full `914f7caf..c9445561` target delta and affected dirty Build 1
  implementation without editing source, tests, or plans.
- Compared the proposed numeric domain with RFC 8785/RFC 7493 and reproduced
  ECMAScript rounding using the command and output above.
- Did not run implementation suites because the plan gate fails before conflict
  reconciliation or implementation. No interrupted or unselected run is claimed.

## Required disposition

Revise r5 and r9 to impose the exact common maximum `9007199254740991`, while
retaining every earlier r1-r5 and r5-r9 requirement. Recompute changed artifact
hashes and run a fresh independent GPT-5.6 Sol gate over the complete exact
bundle. Conflict resolution and implementation remain blocked until that review
reports zero Critical, High, and Medium findings.
