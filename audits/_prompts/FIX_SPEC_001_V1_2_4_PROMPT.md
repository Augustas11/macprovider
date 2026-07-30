# Fix prompt — SPEC-001 v1.2.3 → v1.2.4 (concurrency reality alignment)

Operator-paste prompt to close audit finding **H-003** from the
2026-05-29 independent security audit: SPEC-001 documents RAM-tier
defaults with max_concurrency > 1, but the Swift runtime has always
enforced a process-local semaphore of 1.

Spec-text-only patch. Single finding. SPEC-001 v1.2.3 → v1.2.4.

This is the Swift stream of the three-spec coordinated audit-response
cycle. Sibling prompts handle the Go (SPEC-002 v1.1.5) and product
(SPEC-006 v0.6) streams in parallel. Each is independently runnable;
no cross-stream coordination required beyond the final dependency-line
sync at commit time.

Run in **Claude Code** or **Codex CLI**. Expected duration: ~30-45 min.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are aligning SPEC-001 v1.2.3 to the Swift implementation's
actual concurrency behavior. The independent audit (H-003) caught
that SPEC-001 documents per-RAM-tier max_concurrency defaults
greater than 1 (e.g., 2 for 16GB, 3+ for higher), but the
phase3-binary runtime has always serialized MLX generation through
a process-local semaphore of 1 and overrides advertised concurrency
to 1 regardless of RAM.

Code reference (already correct):
  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:64
  // MLX generation is currently guarded by a process-local semaphore of 1.
  // Advertise the real runtime concurrency until the runtime is proven safe
  // for parallel generation.
  let capacityDefaults = ProviderCapacity(maxConcurrencyOverride: 1)

Pool evidence (live verification):
  augustass-macbook-air (8GB):  max_concurrency: 1
  air5 (16GB):                   max_concurrency: 1

The code is conservative. The SPEC describes RAM-tier defaults that
the code never realizes. This is documentation drift — a future
BUILD session reading the spec might implement parallel generation
breaking the safety property, OR a downstream consumer might rely
on advertised capacity that doesn't exist.

You will edit one file in place:
  /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md  v1.2.3 → v1.2.4

## Critical constraints

**1. Spec-text-only patch.** No Swift code changes (the code is
already correct). Verify with `git diff phase3-binary/` after edits
— should be empty.

**2. Locked backward-compat clause.** SPEC-001's verbatim
backward-compat statement near the top of the document must stay
byte-identical.

**3. Buyer API stability.** `POST /v1/chat/completions`,
`GET /v1/models`, `GET /healthz` semantics unchanged.

**4. SPEC-002, SPEC-003, SPEC-006 untouched.** Verify with
`git diff specs/SPEC-002-coordinator.md
specs/SPEC-003-open-onboarding.md specs/SPEC-006-buyer-api.md`
after edits — should be empty.

**5. Surgical scope.** Single finding. Three narrow edits:
- Change RAM-tier defaults to all-1
- Add normative paragraph locking semaphore-of-1
- Add forward-looking note about parallel-generation as deferred
  to a future revision (NOT a Tier 2 milestone; just a future
  candidate when proven safe)

**6. d-inference clean-room.** Do not inspect d-inference source.

## Required reading

1. `specs/SPEC-001-phase3-binary.md` v1.2.3 — full document. Focus
   on:
   - Wherever `max_concurrency` appears in any normative or
     example context
   - The capacity / RAM-tier section (likely in § 4 or § 5; locate
     via grep `max_concurrency` and `ram_gb`)
   - FR-9 (the auditor referenced FR-9 as the source of computed
     max_concurrency)
   - The verbatim backward-compat clause (must stay untouched)

2. `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
   lines 60-80 — read the actual semaphore-of-1 override comment +
   code. Your spec text MUST be consistent with this code reality.

3. `phase3-binary/Sources/MacProviderCore/Config.swift` line 32+ —
   note that `maxConcurrencyOverride` is the user-tunable override
   that defaults to `nil` (which then resolves to 1 in
   MacProviderCLI.swift). The override mechanism stays — the
   normative ceiling is what changes.

4. The audit report excerpt (read carefully):

   > H-003: Advertised Capacity May Exceed Actual Runtime Concurrency
   >
   > MacProvider's documented RAM-tier capacity model allows multiple
   > concurrent requests on higher-memory machines, but the inspected
   > Swift runtime serializes model inference through a single
   > concurrency gate. If the coordinator or buyer API routes traffic
   > based on advertised concurrency rather than actual runtime
   > capability, the system may over-admit work, trigger queue
   > pressure, or misrepresent provider capacity.
   >
   > Recommendation: Make advertised max_concurrency match enforced
   > runtime concurrency until real batching or safe parallelism is
   > implemented.

## Findings to fix

### F-601-V4-1 — Align RAM-tier defaults to the semaphore-of-1 reality.

**Location:** SPEC-001's RAM-tier table or FR-9 (locate via grep).

**Problem:** SPEC-001 documents max_concurrency values >1 for
specific RAM tiers (e.g., 2 for 16GB, possibly 3+ for higher), but
the Swift runtime enforces 1 unconditionally. The code comment is
explicit:

> MLX generation is currently guarded by a process-local semaphore
> of 1. Advertise the real runtime concurrency until the runtime is
> proven safe for parallel generation.

**Fix:**

1. **Update the RAM-tier table** (or wherever the default
   concurrency mapping lives): set max_concurrency to 1 for ALL
   RAM tiers. Don't remove the table; just lock the value.

2. **Add a normative paragraph** to the capacity/FR-9 section:

   > Until provider runtime parallel generation is proven safe
   > under MLX (catalog reasoning, memory pressure analysis,
   > stability validation), advertised `max_concurrency` MUST be 1
   > for all RAM tiers. The provider runtime enforces this via a
   > process-local semaphore of 1 around MLX generation calls.
   > Operators MAY set `max_concurrency_override` in
   > `~/.config/macprovider/config.yaml` (or via
   > `MACPROVIDER_MAX_CONCURRENCY_OVERRIDE` env) for experimental
   > use, but the default and recommended value is 1.
   >
   > This is a deliberate safety floor, not an architectural ceiling.
   > A future SPEC-001 revision MAY raise the default when parallel
   > generation has been validated under concurrent buyer load
   > without quality, latency, or memory regressions. Until then,
   > consumers (coordinator routing, buyer-API gateways, capacity
   > reporting) MUST treat advertised values >1 as opt-in operator
   > overrides, not normative defaults.

3. **Add an audit-category entry** in SPEC-001's audit section (if
   such a section exists; if not, add as a v1.2.4 lesson note):

   > Advertised provider capability MUST match enforced runtime
   > capability. Spec values that the code never realizes are a
   > drift class equivalent to Entry 18's SIGTERM=drain conflation
   > and Entry 19's WithTokenValidator always-on: both produce
   > silent failures of the form "the system describes a capability
   > that does not exist in practice." Future spec revisions
   > documenting capacity MUST cite the code path that realizes
   > them.

### Spec text catch-up

Add to SPEC-001 v1.2.4's change log:

> **v1.2.4 (2026-05-29, audit response, concurrency reality
> alignment):** Aligns the RAM-tier max_concurrency documentation
> to the Swift runtime's enforced semaphore-of-1 reality
> (H-003 from the 2026-05-29 independent security audit). Spec
> previously documented per-tier defaults >1; runtime always
> overrode to 1. No code change required. Future parallel
> generation deferred to a SPEC-001 v1.3 candidate pending runtime
> validation.

Update "Depends on" line — unchanged (no upstream spec
dependency changes).

## Verification gate

After the edits:

1. `git diff phase3-binary/` MUST be empty (code already correct).
2. `git diff specs/SPEC-002-coordinator.md
   specs/SPEC-003-open-onboarding.md specs/SPEC-006-buyer-api.md`
   MUST be empty.
3. The verbatim backward-compat clause is byte-identical to v1.2.3.
4. Every occurrence of `max_concurrency` in normative SPEC-001 text
   says either "1" (in the default table) OR is documented as an
   operator override.
5. No SPEC-001 example or FR claims max_concurrency >1 as a
   normative behavior.

If your edits exceed ~80 added lines in SPEC-001, stop and re-check
scope. This is a single-finding alignment patch.

When done, print a 150-word handback summary covering:
- F-601-V4-1 closure status
- The new normative ceiling (semaphore-of-1)
- The operator override mechanism preserved
- Whether SPEC-001 v1.2.4 is READY TO LOCK
- Filed for future cycle: SPEC-001 v1.3 candidate (parallel
  generation when runtime is proven safe)

Then stop. The operator commits SPEC-001 v1.2.4 in coordination
with SPEC-002 v1.1.5 + SPEC-006 v0.6 (the sibling audit-response
patches).

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~10 min):

1. `git diff specs/SPEC-001-phase3-binary.md` — version bump, change
   log entry, RAM-tier table values now all 1, normative paragraph
   added.
2. `git diff phase3-binary/` — should be empty.
3. `git diff specs/SPEC-002-coordinator.md specs/SPEC-003-open-onboarding.md
   specs/SPEC-006-buyer-api.md` — should be empty.
4. Verify the verbatim backward-compat clause survived untouched.

After all three audit-response FIX prompts execute (this one +
SPEC-002 v1.1.5 + SPEC-006 v0.6), commit as a coordinated set:

```
Audit-response Tier A patches: SPEC-001 v1.2.4 + SPEC-002 v1.1.5 + SPEC-006 v0.6

Closes H-001 + H-002 + H-003 from 2026-05-29 independent security
audit. Spec-text only; no code changes. Three coordinated narrow
patches matching the three-stream FIX pattern.

SPEC-001 v1.2.4 — concurrency reality alignment (H-003)
SPEC-002 v1.1.5 — production invariants for public WS auth (H-002)
SPEC-006 v0.6  — explicit Tier 1 disclosure language (H-001)

H-004 (model integrity), H-005 (billing settlement), H-006 (sticky
caching) deferred per audit-response triage: H-004 to Tier 2 work,
H-005 to BUILD_PHASE5 Phase C verification, H-006 to forward-looking
note in SPEC-006.
```

This SPEC-001 v1.2.4 patch is the smallest of the three (single
finding, narrow alignment). The bigger work is SPEC-002 v1.1.5
(production invariants) and SPEC-006 v0.6 (disclosure language).

After all three land, BUILD_PHASE5 unlocks against the
audit-hardened spec corpus.
