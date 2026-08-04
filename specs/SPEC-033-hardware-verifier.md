# SPEC-033 — Hardware-Evidence Verifier (`hardware-verifier.v2`)

**Status:** v0.6.2-draft
**Date:** 2026-07-29
**Depends on:** SPEC-023 (autotune — produces the benchmark/recommendation inputs the evidence document carries). **Consumed by:** SPEC-032 (autotune hardware-evidence admission "hello-gate") reads this spec's verdict via an **exact-`hardware-verifier.v2`** lookup and cross-references it as "the item-10 hardware-verifier verdict spec". This spec owns the `hardware-verifier.v2` decision semantics and the job/profile lifecycle; SPEC-032 owns how a `verified` profile gates admission.

**Producer / enqueue boundary (see §3.1):** the provider **binary** builds the evidence envelope (`phase3-binary/Sources/macprovider-cli/AutotuneHardwareEvidence.swift`) and submits it over an **authenticated HTTP `POST /v1/providers/hardware-evidence`** (`phase4-coordinator/internal/onboarding/hardware_evidence.go` `HandleHardwareEvidence`), which enqueues a `hardware_verification_jobs` row. SPEC-023 owns the *content* (benchmarks, recommended model); the HTTP envelope + enqueue + replay state machine are owned here.

**Numbering note.** Assigned canonical **SPEC-033** on 2026-07-12 (Wave C of the
2026-07-10 SPEC-vs-code drift audit; runbook item 10). Highest prior canonical spec
was SPEC-032. This document is the **reconstructed normative baseline** for a shipped,
production-live coordinator trust signal that ships **unspecced**.

**Source-of-truth discipline.** This is documentation of shipped behavior. The **code and
migrations are authoritative**; this spec MUST byte-match them and any disagreement is a spec
bug. The contract spans: the verifier (`phase4-coordinator/internal/stats/hardwareverify/verify.go`),
migrations **007, 008, 013, 015, 016, 017, 019** (`phase4-coordinator/internal/stats/migrations/`), the
deployment/role SQL (`phase4-coordinator/dist/stats-inventory-writer.sql`,
`dist/stats-hardware-verifier-bootstrap.sql`), the HTTP enqueue path
(`internal/onboarding/hardware_evidence.go`) and its producer
(`phase3-binary/.../AutotuneHardwareEvidence.swift`), the app-registration profile writer
(`internal/onboarding/apptrack.go`, `store_pg.go`), the operator inventory writer/demotion
(`cmd/stats-inventory-sync/main.go`), the runner (`cmd/stats-hardware-verifier/main.go`), and the
downstream consumers — SPEC-032 admission (`internal/autotune/evidence_pg.go`), the SPEC-017
hardware cache (`internal/stats/hardware/cache.go`), and the config-gated telemetry-drift evaluator
(`internal/pow/drift.go`, on the same exact-v2 `LatestVerified` lookup). **Where §2 summarizes DDL,
the migration and `dist/*.sql` files are the byte-authoritative shape.**

---

## 1. Purpose and scope

### 1.1 Purpose

A provider's autotune run (SPEC-023) produces a **hardware-evidence document**
(`hardware_evidence.autotune.v2`) describing its Apple-silicon chip, unified memory, OS/binary
versions, the exact probe protocol/executable identity, a stable `hardware_identity_hash`, and local model benchmarks. The provider binary
submits it (§3.1); a row lands in `hardware_verification_jobs`. The **hardware-evidence
verifier** is a coordinator-side **batch job** that reads pending jobs, runs a deterministic
ordered gate pipeline over each evidence document, and transitions the job to **`verified`**,
**`rejected`**, or the non-terminal **`waiting_trust`** — promoting a
`provider_hardware_profiles.verified = TRUE` row on success.

### 1.2 What `verified` means and who consumes it

`provider_hardware_profiles.verified` is consumed by **SPEC-032's hardware-evidence admission
lookup** (`internal/autotune/evidence_pg.go` `LatestVerified`) — and the same lookup also feeds the
config-gated **telemetry-drift** evaluator (`internal/pow/drift.go`) — which requires a
`verified = TRUE` profile joined to a `status='verified'` job carrying the **exact**
`hardware-verifier.v2:verified_trusted_hardware` decision reason. It is **not** itself a SPEC-002 tier/routing input — SPEC-002 tiers derive from
pinned config / unknown-id / rejection state, and SPEC-032 explicitly treats the hardware-evidence
signal as **orthogonal** to the SPEC-002/SPEC-003 tiers. This spec defines the verdict engine and
lifecycle; it does not define admission or tier weighting.

### 1.3 In scope

- The `hardware-verifier.v2` decision-reason taxonomy and the shipped success constant.
- The ordered verification algorithm (`Evaluate`) and every reject/wait reason.
- The submission/enqueue path and its replay state machine (§3.1).
- The job lifecycle state machine (`pending`/`waiting_trust`/`verified`/`rejected`).
- Verified-profile promotion, the DB-enforced re-verification, and the monotonicity guard.
- Batch/concurrency semantics; replay resistance (`evidence_sha256`).
- The full DB security model: least-privilege **column-level** grants and the **two** guard
  triggers; the operator-authority inventory-writer path; the post-verdict demotion lifecycle.
- The runner, its `Smoke` preflight, and systemd scheduling.
- The **exact-v2** downstream-consumer contract and legacy-`v1` grandfathering nuance.

### 1.4 Out of scope

- **Evidence production** (autotune benchmark generation, chip detection, `hardware_identity_hash`
  derivation) — SPEC-023 / provider-binary.
- **How `verified` gates admission / tiers** — SPEC-032 / SPEC-002.
- **Trust-root curation policy** — *how* an operator decides to insert a
  `hardware_verification_trust` row is operational policy; this spec defines only how a row is
  *matched*.
- **Benchmark authenticity.** The verifier does **not** prove benchmarks were executed on the
  claimed device (§10.2). Proof-of-weights / OPoI / attestation are SPEC-032 / SPEC-008.

---

## 2. Data model

Four tables plus **two** guard triggers, the migration-019 dual-control approval workflow, and
least-privilege **column-level** grants. Migrations
**007, 008, 013, 015, 016, 017, 019** plus the role SQL in `dist/stats-inventory-writer.sql` and
`dist/stats-hardware-verifier-bootstrap.sql` are the byte-authoritative DDL; the tables below are a
load-bearing summary — a reimplementation MUST read those files for exact column lists,
`NOT NULL`/`DEFAULT` clauses, `CHECK` constraints, indexes, roles, and grants.

### 2.1 `hardware_verification_jobs` — the work queue (migration 008)

Columns include `id BIGSERIAL PK`, `provider_id`, `source CHECK (source IN ('autotune'))`,
`status CHECK (... 'pending','waiting_trust','verified','rejected') DEFAULT 'pending'`, `chip`,
`chip_normalized`, `unified_memory_gb CHECK (0..4096)`, `bandwidth_tier`, `os_version`,
`binary_version` (all `NOT NULL DEFAULT ''`), `benchmark_count CHECK (0..64)`,
`max_sustained_tps CHECK (>= 0)`, `generated_at`, `submitted_at DEFAULT now()`, `processed_at NULL`,
`decision_reason NOT NULL DEFAULT ''`, `evidence JSONB NOT NULL`, and
**`evidence_sha256 TEXT NOT NULL UNIQUE`** (replay guard). Indexes: a partial index on
`status IN ('pending','waiting_trust')` (batch scan) and `(provider_id, submitted_at DESC)`.

Note `benchmark_count` and `max_sustained_tps` are **persisted summary columns** the onboarding
enqueue path fills from the evidence; the migration-016 trigger re-checks them at promotion (§7).

### 2.2 `hardware_verification_trust` — operator-curated trust roots (migrations 008 + 019)

Migration 008 introduced trust roots keyed by `(provider_id, hardware_identity_hash)`.
Migration 019 is now authoritative for the effective shape: primary key
`(provider_id, hardware_identity_hash, source)`, plus `chip_normalized`, `unified_memory_gb`,
`trusted_by`, `trusted_at`, `expires_at NULL`, `notes`, and
`source CHECK (source IN ('inventory', 'operator_api'))`. A row asserts an operator vouches that
`hardware_identity_hash` for this provider is a genuine device with this chip + memory.
`expires_at IS NULL` or in the future ⇒ active. Inventory rows are written by the operator
trust-curation role (`stats_trust_inventory_writer`); durable dual-control approval rows are
written by migration-019 SECURITY DEFINER functions as `source='operator_api'`. The verifier reads
either active source.

### 2.3 `provider_hardware_profiles` — the verified output (migration 007)

`provider_id PK`, `chip`, `chip_normalized`, `unified_memory_gb CHECK (0..4096)`, `macos_version`,
`app_version`, `source CHECK (source IN ('app_register','cli_hello','operator'))`,
`verified BOOLEAN DEFAULT FALSE`, `last_reported_at`. A successful verdict upserts this row with
`verified=TRUE`, `source='cli_hello'` (§7). Index on `chip_normalized`.

### 2.4 `chip_hardware_profiles` — the known-chip catalog (migration 007)

`chip_normalized PK`, `display_chip NOT NULL`, `memory_bandwidth_gb_per_s BIGINT CHECK (>=0)`,
`network_power_kw DOUBLE PRECISION CHECK (>=0)`, `gpu_cores CHECK (>=0)`, `cpu_cores CHECK (>=0)`,
`updated_at DEFAULT now()`. Operator-curated. A job's `chip_normalized` MUST have a row here or
the job goes to `waiting_trust` (§5.5).

### 2.5 Guard trigger A — `provider_hardware_profiles_guard_verification` (migration 016, supersedes 007)

A `BEFORE INSERT/UPDATE` trigger on `provider_hardware_profiles`. **Migration 016 replaces the
migration-007 function** — 016 is authoritative:

- Under role `provider_onboarding`: `verified` is forced `FALSE` on insert, and forced `FALSE`
  whenever **`chip_normalized` OR `unified_memory_gb`** changes; otherwise preserved. A verified
  profile is thus **anchored to (chip, memory)** — it survives an `os/app/identity` change but is
  cleared on a chip- or memory-tuple change.
- Under role `stats_hardware_verifier` (the verifier): (a) an `UPDATE` moving `last_reported_at`
  **backward** RAISES; (b) `NEW.verified` MUST be `TRUE` ("may only promote"); (c) the trigger
  **independently RE-VERIFIES in the database** that a matching fresh job + active trust row +
  chip-profile row exists — the same `(provider_id, hardware_identity_hash, chip_normalized,
  unified_memory_gb)` trust join, a `chip_hardware_profiles` match, `generated_at >= now()-7d`,
  `status IN ('pending','waiting_trust')`, `benchmark_count > 0`, `max_sustained_tps > 0`,
  non-empty identity hash, and an **exact profile-tuple binding** (`os_version=macos_version`,
  `binary_version=app_version`, `generated_at=last_reported_at`) — else it RAISES. **The trust
  gate is enforced twice: in `Evaluate` (§5.5) and again in the DB at write time.**
- Other roles (e.g. `stats_inventory_writer`, §2.7) fall through to `RETURN NEW` — **not**
  trigger-constrained.

### 2.6 Guard trigger B — `hardware_verification_jobs_guard_verifier_update` (migration 008)

A `BEFORE UPDATE` trigger on `hardware_verification_jobs`: under `stats_hardware_verifier`, an
update whose `OLD.status` is **not** `pending`/`waiting_trust` RAISES ("may not update finalized
jobs"), and `NEW.status` MUST be one of `waiting_trust`/`verified`/`rejected`. This is the
DB-level counterpart of the application's terminal-safe `WHERE` (§6).

### 2.7 Least-privilege roles and grants

- **`stats_hardware_verifier`** (the verifier): `SELECT` on the jobs/trust/chip/profile tables;
  `UPDATE` on the job status/decision columns; the promotion `INSERT/UPDATE` on
  `provider_hardware_profiles` — all gated by triggers A/B. Created **`NOLOGIN`** by migration 008,
  but the operator bootstrap (`dist/stats-hardware-verifier-bootstrap.sql`) `ALTER`s it to
  **`LOGIN`** with a password so the runner can connect — so it is a login role in a real
  deployment.
- **`provider_onboarding`** (the enqueue path): **column-level** `INSERT` on the job columns
  (including `status`, but the shipped enqueue always inserts `pending`) and **column-limited
  `SELECT`** — `id, provider_id, status, submitted_at, evidence_sha256` (008), `decision_reason`
  (015), **`generated_at, evidence`** (013, for the SPEC-032 W2 hello gate — the §10.2 leakage
  boundary), and job `chip_normalized, unified_memory_gb` (017); on profiles, `last_reported_at`
  (007) and `provider_id, chip_normalized, unified_memory_gb, verified` (017). It also has column
  `INSERT`/`UPDATE` on profiles for `chip, chip_normalized, unified_memory_gb, macos_version,
  app_version, source, last_reported_at` (007) — **but `verified` is NOT among them**, and trigger
  A forces `verified=FALSE` on any insert and on any chip/memory change: **onboarding can never
  self-promote.** (Precisely: trigger A forces FALSE on insert/chip/memory-change but **preserves**
  `OLD.verified` on a same-tuple update — see §10.1; a compromised onboarding SQL role could insert
  a terminal-`status` job, *read* all evidence, and flip `source` on already-verified rows to escape
  demotion, but still cannot *set* the `verified` bit — §10.1, §10.2.)
- **`stats_inventory_writer`** (operator inventory sync, §7.3; role/grants defined in
  `dist/stats-inventory-writer.sql`, not a migration): full `INSERT/UPDATE` on
  `provider_hardware_profiles` **including `verified`**, and **not** constrained by trigger A. This
  is an **operator-authority** path, not a provider-reachable one (§10.1).
- **`stats_trust_inventory_writer`** (also `dist/stats-inventory-writer.sql`): writes
  `hardware_verification_trust` (the trust roots).
- **`hardware_trust_definer` / `hardware_trust_requester` /
  `hardware_trust_approver`** (migration 019): the durable operator approval path for
  providers parked in `waiting_trust` with
  `decision_reason='missing_trusted_hardware_identity'`. The request and approve roles are split
  so one operator key cannot both request and approve the same hardware trust root. The
  SECURITY DEFINER functions derive `(provider_id, hardware_identity_hash, chip_normalized,
  unified_memory_gb)` from the bound `hardware_verification_jobs` row instead of trusting
  caller-supplied tuple values, require two distinct operators, and write only
  `hardware_verification_trust.source='operator_api'` rows. Inventory roots remain
  `source='inventory'`; migration 019 widens the trust-root primary key to
  `(provider_id, hardware_identity_hash, source)` so operator API approvals and inventory sync
  own independent rows and cannot clobber each other.

### 2.8 Migration 019 operator approval coupling

Migration 019 is part of this spec's byte-authoritative data model even though it was added after
the reconstructed v0.6.1 baseline. It changes trust-root storage and approval workflow, not
provider-submitted evidence semantics:

- `hardware_verification_trust.source` distinguishes inventory-managed roots from
  `operator_api` roots created by the dual-control approval functions.
- `hardware_trust_pending` records open approval requests bound to a real
  `hardware_verification_jobs` row. Approval is allowed only while that job remains
  `waiting_trust` for `missing_trusted_hardware_identity`.
- request/approve/revoke functions are SECURITY DEFINER functions owned by
  `hardware_trust_definer`; EXECUTE is split across requester and approver roles.
- deploy/rollback sequencing is coupled to the stats-inventory-sync binary because the migration
  widens the trust-root primary key from two columns to three. Operators MUST quiesce old
  two-column inventory sync before applying the migration and MUST pair rollback with the matching
  older binary, as documented in the migration file.

---

## 3. Evidence document schema (`hardware_evidence.autotune.v2`)

The `evidence` JSONB decodes to (`hardwareverify.Evidence`):

```
schema_version           string   // MUST equal "hardware_evidence.autotune.v2"
provider_id              string
generated_at             string   // RFC3339
probe_protocol           string   // MUST equal "spec-023-harmony-stream.v2"
hardware {
  chip                   string
  memory_gb              int
  bandwidth_tier         string
  detected               bool
  os_version             string
  binary_version         string
  hardware_identity_hash string   // lowercase hex SHA-256 (64 chars)
  executable_sha256      string   // lowercase hex SHA-256 of the submitting CLI executable
}
candidate_catalog_sha256 string    // lowercase hex SHA-256
recommended_model        string
benchmarks []{
  model_key, model_id                  string
  sustained_tps                        float64
  ttft_ms                              int
  swap_detected, thermal_throttle_detected bool
  artifact_sha256, candidate_catalog_sha256 string
  benchmark_id                         string  // optional
  candidate_row_identity               string  // required; MUST be 64 lowercase hex
  generated_at                         string  // RFC3339
  binary_version, hardware_identity_hash string
}
```

A **lowercase hex SHA-256** is exactly 64 chars in `[0-9a-f]` (`isLowerSHA256`). The v2
`candidate_row_identity` is required by the HTTP handler, verifier, and downstream SPEC-032
admission. The coordinator also requires the top-level probe protocol and executable digest to
bind the submitted measurements to the released probe contract; a v1 document is not accepted
by the v2 path.

### 3.1 Submission and replay (enqueue path)

The provider binary POSTs the envelope to **`POST /v1/providers/hardware-evidence`** with its
authenticated bearer identity; the handler (`HandleHardwareEvidence`) binds the job to the
**authenticated** `provider_id` (a provider cannot enqueue for another provider). The handler:

- enforces **strict request validation**: `POST`-only; a bounded body; **unknown-field rejection**
  (strict JSON); numeric precision/range checks; and field-binding checks (including the required
  protocol, executable digest, and 64-lowercase-hex `candidate_row_identity`);
- applies **two rate limiters**: an **IP** limiter (`10/min`, HTTP `429` `Retry-After: 60`) and a
  **per-provider** limiter (HTTP `429` `Retry-After: 600`). The per-provider limit is **broader
  than a fixed window**: a new *distinct* evidence submission is rejected while the provider has
  **any** non-terminal (`pending`/`waiting_trust`) job **OR** any job submitted within the last 10
  minutes (`hardware_evidence.go`), so a provider cannot flood the queue while one job is
  outstanding;
- computes a **canonical** SHA-256 of the evidence (`canonicalEvidenceSHA`) → `evidence_sha256`;
- in the **same transaction**, upserts a **`source='cli_hello'` profile row** *before* inserting
  the job (the upsert **omits `verified`**, so trigger A governs it: `FALSE` on an initial insert or
  a chip/memory change, but **`OLD.verified` preserved** on an unchanged existing tuple — so a
  re-submitting already-verified provider keeps `verified=TRUE`), then inserts a `pending` job
  (unique on `evidence_sha256`);
- returns a **replay state machine** result (`hardwareEvidenceResponseStatus`), **fail-closed**: a
  duplicate is accepted (2xx) **only** while `pending`, while `waiting_trust`, or when already
  `verified` **with `decision_reason == hardware-verifier.v2:verified_trusted_hardware` exactly**.
  Every other finalized/unknown/legacy state (`rejected`, `v1:verified`, …) returns HTTP `409`
  `evidence_replay_not_accepted` — a rejected or legacy decision cannot be laundered through a 2xx
  replay; new evidence must be resubmitted.

The pre-job `cli_hello` profile upsert is why a later app-registration (§10.4 R1) finds an existing
row to convert.

**SPEC-033-R001 — Preserve provider hardware-profile writes under least privilege.** The
authenticated CLI evidence-enqueue path and the signed app-registration profile path MUST execute
under the column-limited `provider_onboarding` role without requiring `SELECT` on write-only
profile payload columns. On conflict, each path MUST keep `source` coordinator-controlled, MUST
NOT write `verified`, and MUST NOT replace a profile whose `last_reported_at` is newer than the
incoming observation.

---

## 4. Decision constants, versioning, and downstream acceptance

- **Verifier version:** `hardware-verifier.v2` (`verifierDecisionVersion`).
- **Evidence schema version:** `hardware_evidence.autotune.v2` (`evidenceSchemaVersion`).
- **Probe protocol:** `spec-023-harmony-stream.v2`; this is an immutable binding for the
  context-bounded Harmony stream probe used by Stage 1 and Stage 2.
- **Success constant:** `hardware-verifier.v2:verified_trusted_hardware` (`VerifiedDecisionReason`).
- **Reject/wait reasons** are persisted as `hardware-verifier.v2:<bare reason>` —
  `rejectJob`/`waitTrustJob` prefix the version at write time (e.g.
  `hardware-verifier.v2:chip_mismatch`, `hardware-verifier.v2:missing_trusted_hardware_identity`,
  `hardware-verifier.v2:missing_trusted_chip_profile`). `Evaluate` returns the bare reason; only
  success returns the pre-prefixed `VerifiedDecisionReason`.

**Legacy `hardware-verifier.v1:verified` and downstream acceptance (two consumer classes).** The
*verifier* grandfathers legacy terminal rows only in the sense that it scans **only**
`pending`/`waiting_trust`, so a legacy `verified` row is never re-evaluated. Downstream, there are
**two distinct consumer classes**:

- **Exact-v2 (job-reason) consumers** require `decision_reason = VerifiedDecisionReason`: onboarding
  replay (`hardware_evidence.go`; its test rejects `hardware-verifier.v1:verified`), SPEC-032's
  evidence lookup (`internal/autotune/evidence_pg.go` `LatestVerified`), and the same `LatestVerified`
  feeding the config-gated telemetry-drift evaluator (`internal/pow/drift.go`). A legacy `v1:verified`
  row is **not** a current trusted verdict for these.
- **Verified-bit consumers** gate on `provider_hardware_profiles.verified = TRUE` **without**
  inspecting any job reason: the **SPEC-017 hardware cache** (`internal/stats/hardware/cache.go`
  selects `WHERE verified = TRUE`) and the demotion predicate's supporting-job clause (§7.3), which
  accepts any `status='verified'` job. For these, the **bit**, not the v2 reason, is authoritative.

So "downstream requires the exact v2 reason" is true for the *reason* consumers but **not**
universal — the verified bit is a second, coarser signal.

> **Naming drift closed.** The live success constant is `hardware-verifier.v2:verified_trusted_hardware`
> (v2, not v1). Earlier drift assumed a `v1` verifier.

---

## 5. Verification algorithm (`Evaluate`)

`Evaluate(job)` runs `evaluateAt(job, now)` with `now = time.Now().UTC()`. It is a
**deterministic, ordered, short-circuit** gate pipeline: the **first** failing gate wins; only a
job passing every gate returns `{Verified: true, Reason: VerifiedDecisionReason}`. Order is
normative. Time bounds: `maxEvidenceAge = 7*24h`; `futureSkew = 5m`; `t` is **stale** if
`t < now - maxEvidenceAge` and **future-skewed** if `t > now + futureSkew`.

### 5.1 Job-envelope gates (reject)

`missing_provider_id`; `stale_job` (`job.generated_at` out of window); `memory_out_of_range`
(`job.unified_memory_gb < 8` or `> 4096` — the verifier's `>= 8` floor is **stricter** than the
table's `>= 0` CHECK); `missing_evidence`; `invalid_evidence_json`.

### 5.2 Evidence-consistency gates (reject)

`schema_version_mismatch`; `provider_id_mismatch`; `invalid_evidence_generated_at`;
`evidence_generated_at_mismatch` (evidence timestamp not **exactly equal** to `job.generated_at`);
`stale_evidence`.

### 5.3 Hardware-claim cross-check gates (reject)

`chip_mismatch` (`normalizeChip(evidence.hardware.chip) != job.chip_normalized`; `normalizeChip`
lowercases, trims, collapses internal whitespace); `memory_mismatch`; `bandwidth_tier_mismatch`
(case-insensitive, trimmed); `os_version_mismatch` (trimmed exact); `binary_version_mismatch`
(trimmed exact); `invalid_hardware_identity_hash`; `invalid_candidate_catalog_sha256`.

### 5.4 Benchmark gates (reject)

`missing_benchmarks`. Then per benchmark, in list order: `missing_benchmark_model_binding` (blank
`model_key` or `model_id`); `duplicate_benchmark_model_key` (a `strings.TrimSpace(model_key)` seen
earlier in the same document — so `"m"` and `" m "` collide); `invalid_benchmark_artifact_sha256`;
`benchmark_catalog_mismatch`; `benchmark_binary_version_mismatch`;
`benchmark_hardware_identity_mismatch`; `invalid_benchmark_generated_at`; `stale_benchmark`;
`invalid_benchmark_tps` (NaN/±Inf/`<= 0`); `invalid_benchmark_ttft` (`<= 0`). After the loop:
`missing_positive_benchmark`; `missing_chip_normalized`.

### 5.5 Trust gates (→ `waiting_trust`, NOT reject)

- `missing_trusted_hardware_identity` — no active `hardware_verification_trust` row matches
  `(provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb)` with
  `expires_at IS NULL OR expires_at > now()`.
- `missing_trusted_chip_profile` — no `chip_hardware_profiles` row for this `chip_normalized`.

(Computed in the batch SELECT as `trust_matched`/`chip_profile_matched`, read as
`job.TrustMatched`/`job.ChipProfileMatched`.)

### 5.6 Success

Passing every gate returns `hardware-verifier.v2:verified_trusted_hardware`.

---

## 6. Job lifecycle state machine

- The batch scan selects `status IN ('pending','waiting_trust')`. **`waiting_trust` is
  non-terminal**: it is re-evaluated on every run, so once an operator later inserts the missing
  trust or chip-profile row, the same job promotes without re-submission.
- `verified` and `rejected` are terminal (never re-scanned). Trigger B (§2.6) forbids the verifier
  from reopening them at the DB layer.
- A `waiting_trust` job that later hits a **reject** gate (e.g. its evidence has since gone stale
  — the age gates use the *current* `now`) transitions to `rejected`.
- All transitions set `processed_at = now()` + `decision_reason`, guarded by
  `WHERE id = $1 AND status IN ('pending','waiting_trust')` (terminal-safe; mirrored by trigger B).

---

## 7. Verified-profile promotion and demotion

### 7.1 Promotion (`promoteJob`)

On a `verified` verdict, `promoteJob` upserts `provider_hardware_profiles` with `source='cli_hello'`,
`verified=TRUE`, `last_reported_at = evidence.generated_at`, `ON CONFLICT (provider_id) DO UPDATE
... verified=TRUE` **only** `WHERE provider_hardware_profiles.last_reported_at <= EXCLUDED.last_reported_at`
(monotonicity guard). Trigger A (§2.5) independently re-verifies the trust join and RAISES if it
does not hold — so a promotion that passed `Evaluate` but whose **persisted** `benchmark_count`/
`max_sustained_tps`/tuple disagree with the trigger's checks **RAISES and rolls the whole batch
back** rather than promoting. The job row is then set `status='verified'` in the **same
transaction**.

### 7.2 No-op upsert

If a **newer** profile already exists (`last_reported_at > EXCLUDED`), the conflict `UPDATE`
matches **zero rows** — the existing (newer) profile is left intact — yet the job is still marked
`verified`. So a `verified` verdict does **not** unconditionally rewrite the profile; it promotes
**iff** no newer profile blocks it (§12 AC-HV-1).

### 7.3 Post-verdict demotion (operator inventory sync) — best-effort (one escape R1, one ergonomics gap R2)

`provider_hardware_profiles.verified` is not permanent, but demotion is **best-effort — it has one
documented escape (R1) and one operator-ergonomics gap (R2) (§10.4)** — it is NOT a reliable
revocation guarantee. The operator
inventory sync (`cmd/stats-inventory-sync`, role `stats_inventory_writer`) runs
`applyTrustDemotions`. The exact predicate (`main.go`) sets `verified = FALSE` for every profile
where `verified = TRUE` **AND** `source = 'cli_hello'` **AND `NOT EXISTS`** a **combined witness** —
a `status='verified'` job that **both** exactly matches the profile's tuple (provider,
`chip_normalized`, `unified_memory_gb`, `os_version→macos_version`, `binary_version→app_version`,
`generated_at→last_reported_at`) **and**
is joined to an **active** trust row (`expires_at IS NULL OR > now()`). In words: **retention
requires that one combined (matching-verified-job ∧ active-trust) proof still exist; demotion fires
when it does not** — so *either* trust loss/expiry *or* profile-tuple drift (no matching job) is
independently sufficient. Consequences:

- It only touches `source='cli_hello'` profiles — a profile converted to `app_register` (§10.4 R1)
  is never demoted (the load-bearing escape).
- Because the witness needs *both* the matching job and active trust, **tuple/profile drift can
  demote even while a trust row remains** — trust removal is sufficient but not the only trigger.
- `applyTrustDemotions` (and trust reconciliation) runs only when the sync input carries ≥ 1
  trusted-hardware identity; an operator reaches **zero *active* trust** by supplying a placeholder
  identity with a past `expires_at` (§10.4 R2) rather than an empty section.

The same tool also directly upserts operator profiles (`source='operator'`, `verified` from an
operator-authored YAML) — an operator-authority write path outside the evidence pipeline (§10.1).

---

## 8. Concurrency and batching

`ProcessPending(ctx, limit)` opens **one transaction**, scans up to `limit` (default 100) jobs
`ORDER BY id` with **`FOR UPDATE SKIP LOCKED`**, decides each, applies the writes, commits once.
`SKIP LOCKED` lets multiple instances run concurrently without contending; a failure at any job
rolls the whole batch back (`defer tx.Rollback()`). `Processed{Verified, Rejected, Waiting}` is
the batch tally.

---

## 9. Idempotency and replay resistance

- `evidence_sha256` is `UNIQUE` and computed by a **canonical** hash (`canonicalEvidenceSHA`); the
  enqueue path keys on it, so the **same evidence document creates at most one queue row** — a
  replay collides and is routed through the fail-closed replay state machine (§3.1).
- A provider-authenticated install/update resubmission is replay-safe only when it repeats the
  **same canonical evidence document** (`evidence_sha256`) for the same provider. A changed
  document with the same `hardware_identity_hash` is not an admission-success replay: it goes
  through the normal admission cap, rate limiting, and trust flow. This prevents a provider from
  relabeling changed evidence as an already-accepted hardware-root replay.
- **One queue row does NOT mean one evaluation.** A `waiting_trust` job is re-`Evaluate`d on every
  batch run until it reaches a terminal state; this is by design (§6). Idempotency is preserved by
  the terminal-safe write `WHERE` + trigger B: a job cannot double-promote or be reopened.
- Net: **at most one active queue row per canonical evidence document; exactly one *terminal
  verdict* committed for that document; possibly many interim `waiting_trust` evaluations.**

---

## 10. Security model — precise guarantees and non-guarantees

### 10.1 A provider cannot self-certify (holds)

No provider-reachable path sets `provider_hardware_profiles.verified = TRUE`:

- The provider-reachable profile-write paths (the enqueue upsert §3.1, **and** signed
  app-registration §10.4 R1) both run as `provider_onboarding` — a role with **no `verified` write
  grant**, and trigger A forces `verified=FALSE` on any insert and on any chip/memory change
  (§2.5, §2.7). So **no provider path can create an initial `verified=TRUE`**. A **compromised**
  onboarding SQL role can, however, do more than insert terminal-status jobs and read all evidence
  (§10.2): because it holds column `UPDATE` on profiles including **`source`** (007), and trigger A
  **preserves** `OLD.verified` on a same-tuple update, it can run
  `UPDATE provider_hardware_profiles SET source='app_register' WHERE verified=TRUE` to
  **mass-convert** every verified row and escape demotion — the R1 gap (§10.4) at cross-provider
  scale. It still **cannot set** the `verified` bit (not in its column grant; trigger forces FALSE
  on insert). Initial self-certification therefore holds even under role compromise.
- `verified=TRUE` is writable by exactly **two** roles, **neither provider-reachable**:
  (1) `stats_hardware_verifier` — the only shipped **application** writer is `promoteJob`, and the
  trust join is enforced both in `Evaluate` (§5.5) and in the DB trigger (§2.5); the *role* also
  has direct `INSERT/UPDATE` on `verified`, but trigger A trust-gates any such write (a direct
  qualifying insert is possible only *with* a matching fresh job + active trust); (2)
  `stats_inventory_writer`, an **operator-authority** path syncing an operator-authored YAML
  (`source='operator'`), the same
  trust level as curating a trust row.

So: **a provider without an operator-curated trust row can reach at best `waiting_trust`, never
`verified`.** This is the load-bearing property and it holds.

### 10.2 What `verified` does NOT prove (non-guarantees — do not overstate)

- **Not benchmark authenticity / not anti-splicing.** The verifier does **no** signature,
  proof-of-possession, or artifact verification: `artifact_sha256` is only *shape*-checked (64 hex),
  and the per-benchmark identity/version/catalog checks are **string-equality** consistency checks
  over provider-controlled fields. A provider that legitimately holds a trusted
  `hardware_identity_hash` can attach that value **consistently** to fabricated or another-device
  benchmark numbers; nothing binds the benchmarks to execution on the physical device. The
  guarantee is **string-level self-consistency + an operator trust anchor**, not proof the
  benchmarks ran on that hardware.
- **Cross-provider borrow is blocked, self-fabrication is not.** The trust match keys on
  `provider_id`, and the enqueue binds `provider_id` to the authenticated bearer, so a provider
  cannot match **another** provider's trust row. It can, however, fabricate benchmark numbers for
  **its own** trusted identity.
- **`verified` is (chip, memory)-anchored, not identity-anchored, and not permanent.** Trigger A
  clears `verified` only on a chip/memory change, so a previously-verified provider can change its
  `hardware_identity_hash` (or move to another same-chip/same-memory device) and **retain**
  `verified` until a chip/memory change or a §7.3 demotion. The verified bit is a
  standing (chip, memory) capacity assertion — and its revocation is **best-effort, not
  guaranteed** (§10.4).
- **Read-access leakage boundary.** Migration 013 grants `provider_onboarding` column `SELECT` on
  `hardware_verification_jobs.(generated_at, evidence)` (needed by the SPEC-032 W2 hello gate).
  There is no row-level policy, so a compromise of that **network-facing** onboarding SQL role can
  read **every** provider's raw evidence JSON — hardware identity hashes, OS/binary metadata, and
  benchmark values. This is a disclosed leakage boundary, not a promotion path (that role still
  cannot set `verified`).

### 10.3 Defense in depth (the trust/promotion join is enforced twice — but only that join)

The **trust-row + chip-profile + summary-positivity + freshness + exact-profile-tuple** promotion
check is enforced in **application code** (`Evaluate` §5.5 + `promoteJob`) **and again in the
database** (trigger A re-runs that join at write time, §2.5), so a logic bug in the app layer that
let a bad *trust match* through would still RAISE at the DB. **This duplication covers only the
trust/promotion join, NOT the full §5 pipeline** — trigger A does **not** re-check schema/provider
consistency, benchmark artifact/catalog/binary/identity binding, benchmark timestamps, or TTFT/TPS
validity; those gates exist only in `Evaluate`. Trigger B (§2.6) separately prevents the verifier
from reopening finalized jobs.

### 10.4 Revocation gaps (known shipped weaknesses — MUST close, disclosed not papered over)

Initial self-certification is impossible (§10.1, holds). Revocation of an already-`verified`
profile is weaker: there is **one genuine revocation *escape* (R1)** and, separately, **one
operator-*ergonomics* gap (R2)** that is not itself an escape. SPEC-033 documents both as known
issues; closing them is code follow-up, not a spec change:

- **R1 — `app_register` source-flip escape.** A signed provider **app-registration**
  (`internal/onboarding/apptrack.go` → `store_pg.go` `UpsertProviderHardwareProfile`) upserts the
  profile with `source='app_register'`. For an unchanged (chip, memory) tuple, trigger A preserves
  `OLD.verified` but does **not** reset `source`. Demotion (§7.3) only touches `source='cli_hello'`,
  and the downstream consumers — SPEC-032 admission (`evidence_pg.go`), the SPEC-017 hardware cache
  (`internal/stats/hardware/cache.go`), and the telemetry-drift evaluator (`internal/pow/drift.go`)
  (§4) — gate on the `verified` **bit** (or the exact-v2 job) without rechecking `source` or current
  trust. So a legitimately-verified provider can re-register the
  same chip/memory, flip its row to `app_register`, and **retain `verified=TRUE` past a later trust
  removal/expiry** (SPEC-032 admission is then bounded only by the evidence-TTL freshness join, not
  by trust). MUST-close: demotion should not be `source='cli_hello'`-scoped, or admission should
  re-check current trust.
- **R2 — no direct empty-trust reconciliation (ergonomics, NOT a revocation impossibility).**
  `validateInventory` rejects an **empty** `trusted_hardware` section and omitting it leaves roots
  untouched, so there is no *direct* "delete the last physical trust row" operation. **However,
  zero *active* trust IS reachable** and DOES demote: an operator supplies a **placeholder identity
  with a past `expires_at`** (validation accepts any parseable RFC3339, not requiring a future
  time). That keeps the trust count > 0 (so reconciliation and `applyTrustDemotions` run and delete
  all other roots), while the placeholder is **inactive** everywhere the code applies the
  `expires_at > now()` predicate — both promotion (`verify.go`) and the demotion witness
  (`main.go`). So revocation to zero-active-trust is achievable; the residual is only the missing
  *ergonomic* empty-section path (and the final physical row cannot be deleted, only expired).
  Minor MUST-close: accept an explicit empty/zero-trust reconciliation so operators need not use an
  expired-placeholder workaround.

---

## 11. Runner and operations

- **Binary:** `cmd/stats-hardware-verifier/main.go` — opens the store, runs `Smoke`, then
  `ProcessPending`, prints `stats-hardware-verifier: verified=<n> rejected=<n> waiting=<n>`.
- **`Smoke(ctx)` preflight** MUST pass before processing: asserts `current_user =
  'stats_hardware_verifier'` (fail-closed on a mis-provisioned DSN) and that the four tables are
  readable. A `Smoke` failure MUST abort before any job is touched.
- **Pool:** `MaxOpenConns=2`, `MaxIdleConns=1` — a periodic batch worker, not a hot-path service.
- **Scheduling (shipped):** a systemd **oneshot** service (`stats-hardware-verifier.service`,
  `Type=oneshot`, `ConditionPathExists=/etc/macprovider-stats/stats-hardware-verifier.env`, hardened
  with `ProtectSystem=strict`/`NoNewPrivileges`/`PrivateTmp`) driven by a **timer**
  (`stats-hardware-verifier.timer`: `OnBootSec=2min`, `OnUnitActiveSec=1min`) — i.e. it runs ~1
  minute after each prior activation. Because `waiting_trust` is non-terminal, a provider verified
  only after an operator adds a trust row is promoted by the next timer firing with no provider
  action.

---

## 12. Acceptance criteria

- **AC-HV-1 (success + monotonic promotion).** A job whose evidence passes every §5 gate and whose
  `(provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb)` matches an active
  trust row (and a chip profile) MUST become `status='verified'` with
  `decision_reason='hardware-verifier.v2:verified_trusted_hardware'`. It MUST upsert
  `provider_hardware_profiles.verified=TRUE` **when no newer profile exists**; when a newer profile
  exists the conflict update is a **no-op** (existing newer profile retained) and the job is still
  marked verified (§7.2). The migration-016 trigger MUST independently re-verify the trust join and
  MUST roll the batch back if it does not hold (§2.5, §7.1).
- **AC-HV-2 (ordered reasons).** For each gate in §5, a job failing exactly that gate first MUST
  persist `decision_reason='hardware-verifier.v2:<that reason>'`. Gate order is normative.
- **AC-HV-3 (waiting is non-terminal, subject to freshness).** A job missing only a trust row or
  chip profile MUST become `waiting_trust` (not `rejected`). Once the operator-curated row exists it
  MUST promote on a later run **provided the job still passes every preceding §5 gate** — in
  particular, `Evaluate` re-runs the `stale_job`/`stale_evidence` gates against the *current* `now`
  before the trust gates, so a `waiting_trust` job whose evidence has aged past `maxEvidenceAge` is
  **rejected**, not promoted, and requires resubmission. No re-submission is needed only while the
  evidence remains fresh.
- **AC-HV-4 (no self-certification of the profile bit).** No `provider_onboarding` write may set
  `provider_hardware_profiles.verified=TRUE` (no grant + trigger A). This is a statement about the
  **profile verified bit**, independent of job `status` (a compromised onboarding role could insert
  a terminal-status job but still cannot flip the profile bit).
- **AC-HV-5 (monotonic timestamp).** An older evidence document MUST NOT overwrite a newer verified
  profile (`last_reported_at` guard, application + trigger A).
- **AC-HV-6 (replay = one row, one verdict).** Two submissions of the same document MUST NOT create
  two jobs (`evidence_sha256` UNIQUE); a terminal **verdict** is committed at most once; a
  `waiting_trust` job MAY be evaluated on many runs. HTTP replay MUST be fail-closed: only
  `pending`/`waiting_trust`/exact-v2-`verified` yield a 2xx (§3.1).
- **AC-HV-7 (batch isolation).** Concurrent verifier instances MUST NOT double-process a job
  (`FOR UPDATE SKIP LOCKED` + terminal-safe write `WHERE` + trigger B).
- **AC-HV-8 (Smoke fail-closed).** A run whose `Smoke` preflight fails MUST abort before touching
  any job.
- **AC-HV-9 (legacy grandfathering + two consumer classes).** A `hardware-verifier.v1:verified` row
  MUST remain terminal and MUST NOT be re-evaluated by the verifier. **Exact-v2 job-reason
  consumers** (onboarding replay, SPEC-032 admission, the telemetry-drift evaluator) MUST accept
  only the exact `hardware-verifier.v2:verified_trusted_hardware` reason. **Verified-bit consumers**
  (SPEC-017 cache, the §7.3 demotion supporting-job clause) gate on `verified=TRUE` without a reason
  check (§4) — the spec MUST NOT claim exact-v2 is universal.
- **AC-HV-10 (demotion is best-effort, correct predicate).** On the next sync, a `verified`,
  `source='cli_hello'` profile is demoted to `verified=FALSE` **iff no combined witness exists** —
  i.e. no `status='verified'` job that both exactly matches the profile tuple and is joined to an
  **active** trust row (§7.3). So *either* trust loss/expiry *or* profile-tuple drift is sufficient
  to demote; retention requires the combined proof. Demotion runs only when the sync input carries
  ≥ 1 trust identity (zero *active* trust is reachable via an expired placeholder — §10.4 R2). It
  does **not** touch `source='app_register'` profiles (§10.4 R1). Demotion is best-effort, not a
  guarantee.
- **AC-HV-11 (chip/memory re-verification).** A `provider_onboarding` update that changes
  `chip_normalized` or `unified_memory_gb` MUST clear `verified` (trigger A).
- **AC-HV-12 (revocation calibration documented).** The spec MUST disclose the R1 `app_register`
  source-flip escape (a genuine revocation gap) and the R2 empty-trust *ergonomics* limitation
  (zero *active* trust is reachable via an expired placeholder and does demote — §10.4) as known
  shipped behavior, rather than assert unconditional revocability **or** overstate R2 as a hard
  impossibility.

---

## Change log

**v0.6.2-draft (2026-07-29) — A2 migration-019 roster reconciliation.**
SPEC-033's source-of-truth roster now includes migration 019, which added the durable
dual-control operator hardware-trust approval path. §2.7/§2.8 document the
`operator_api` trust-root source, three-column trust-root primary key, split
requester/approver roles, SECURITY DEFINER functions, and stats-inventory-sync deploy/rollback
coupling. No verifier algorithm or evidence-document semantics changed.

**v0.6.1-draft (2026-07-17) — stable requirement mapping for physical acceptance.**
Defines SPEC-033-R001 for the existing §2.7/§3.1 least-privilege hardware-profile write contract.
The requirement covers both coordinator-owned onboarding paths whose conflict updates share the
same column-limited runtime role. No provider authority, verifier decision, or production state
changes.

**v0.6-draft (2026-07-12) — audit reconciliation (SPEC-033 R5, 3-lane codex).**
R5 confirmed the entire spec against code — all three lanes returned **0 C/H/M** except one shared
MEDIUM: a leftover §7.3 lead phrase ("has documented escape paths", plural) contradicting the
heading and §10.4 (R2 is not an escape). Fixed to "one documented escape (R1) and one
operator-ergonomics gap (R2)". No other change.

**v0.5-draft (2026-07-12) — audit reconciliation (SPEC-033 R4, 3-lane codex).**
R4 verified all R3 fixes against code (0 HIGH on all three lanes); remaining items were
internal-consistency/precision:
- **§10.4/§7.3 framing** (shared MEDIUM): revocation has **one escape (R1)** + **one operator
  ergonomics gap (R2)**, not "two escape paths".
- **§10.1/§2.7** (security MEDIUM): a *compromised* `provider_onboarding` role holds column
  `UPDATE` on profiles **including `source`** (007), so with trigger A preserving `OLD.verified` on
  a same-tuple update it can mass-flip `source='app_register'` to escape demotion at cross-provider
  scale — still cannot *set* `verified`. Also qualified "only via `promoteJob`" as the only
  *application* path (the verifier role has trust-gated direct SQL).
- **§7.3** (LOW): the exact-tuple field is `chip_normalized`, not raw `chip`.
- **§3** (LOW): `candidate_row_identity` is discarded by `Evaluate` but IS decoded/used downstream
  (`evidence_pg.go`/`gate.go`) — "handler-only" was wrong.
- **Telemetry-drift consumer** (LOW): propagated to the header roster, §1.2, §10.4, and AC-HV-9.

**v0.4-draft (2026-07-12) — audit reconciliation (SPEC-033 R3, 3-lane codex).**
R3 confirmed every v0.3 scope/consumer/grant fix and narrowed to predicate-precision:
- **§7.3 + AC-HV-10 demotion predicate corrected** (unanimous HIGH): the shipped SQL demotes a
  `cli_hello` verified profile **iff no combined (exact-tuple verified job ∧ active trust) witness
  exists** — so trust loss *or* tuple drift each suffice; the prior "all three conjunctive
  conditions" wording was inverted.
- **§10.4 R2 recalibrated** (unanimous HIGH): zero *active* trust is reachable (expired-placeholder
  identity) and does demote, so R2 is an empty-section **ergonomics** limitation, not a hard
  revocation impossibility (v0.3 overstated it). R1 `app_register` escape unchanged (confirmed real).
- **§3.1** pre-job `cli_hello` upsert **preserves** `OLD.verified` on an unchanged existing tuple
  (only insert/chip/memory-change forces FALSE) — reinforcing R1.
- **AC-HV-3** qualified: `waiting_trust` promotes only if the job still passes the §5 freshness gates.
- **§3** `candidate_row_identity` is an HTTP-handler field and is not part of the
  pre-v2 `hardwareverify.Benchmark` decode shape; the v2 contract now propagates and
  validates it through the verifier and downstream gate. **§4** adds the telemetry-drift
  (`internal/pow/drift.go`) exact-v2 consumer.

**v0.3-draft (2026-07-12) — audit reconciliation (SPEC-033 R2, 3-lane codex).**
R2 confirmed the §3/§5/§6/§8 core and the no-initial-self-certification property, and caught a
unanimous HIGH plus scope residuals — v0.2 overstated *revocation*:
- **§10.4 added + §7.3/§10.1/§10.2 corrected**: revocation is best-effort with two documented
  shipped escape paths — **R1** `app_register` source-flip (a verified provider re-registers the
  same chip/memory, flips `source`, and evades the `cli_hello`-scoped demotion while SPEC-032/
  SPEC-017 consumers ignore source/trust) and **R2** last-root/zero-trust non-removal (the
  inventory tool rejects an empty `trusted_hardware` and skips demotion when no trust identity is
  present). Both are MUST-close, disclosed not papered over.
- **§10.3 narrowed**: the DB trigger re-verifies only the trust/promotion join, not the full §5
  pipeline.
- **§4 corrected**: two downstream consumer classes — exact-v2 job-reason consumers *and*
  verified-**bit** consumers (SPEC-017 hardware cache; the demotion supporting-job clause); the
  exact-v2 claim is not universal.
- **§3/§3.1 expanded**: `candidate_row_identity`; strict body/unknown-field/precision/range/binding
  validation; the real dual rate-limiters (IP `10/min` `Retry-After 60`; per-provider — any
  non-terminal job or a job within 10 min — `Retry-After 600`); the pre-job `cli_hello` profile
  upsert.
- **§2.7/header expanded**: migration **013** grants (`generated_at, evidence` → the §10.2 leakage
  boundary) + 017/007 grants; role/grant `dist/*.sql`; the verifier role is `NOLOGIN` by migration
  but `ALTER`ed to `LOGIN` by the operator bootstrap.
- **§12**: AC-HV-9 (two consumer classes), AC-HV-10 (best-effort demotion), new AC-HV-12
  (revocation gaps disclosed).

**v0.2-draft (2026-07-12) — audit reconciliation (SPEC-033 R1, 3-lane codex).**
Round-1 audit confirmed §3/§4-constants/§5-gate-orders/§6/§8/§11-runner accurate, and corrected an
**under-scoping**: the reconstruction had followed `verify.go` + migrations 007/008 only. v0.2
expands to the full shipped contract:
- **§2 rewritten**: migration **016** trigger (supersedes 007) with in-DB trust re-verification and
  chip-**or-memory** de-verification; the migration-**008** finalized-job guard trigger (previously
  omitted); column-level grants; the `stats_inventory_writer` operator-authority role.
- **§3.1 added**: the authenticated `POST /v1/providers/hardware-evidence` enqueue path, canonical
  `evidence_sha256`, 10-minute rate limit, and the fail-closed replay state machine.
- **§4 corrected**: downstream consumers require the **exact** v2 reason (onboarding replay +
  SPEC-032 `evidence_pg.go`) — legacy `v1:verified` is terminal but not a current trusted verdict
  downstream; fixed a non-existent `trust_missing` example to the real
  `missing_trusted_hardware_identity` / `missing_trusted_chip_profile`.
- **§7 expanded**: the no-op-upsert outcome, the DB re-verification raise-on-mismatch, and the
  post-verdict **demotion** lifecycle (`applyTrustDemotions`).
- **§9 corrected**: one queue row ≠ one evaluation (`waiting_trust` re-evaluated).
- **§10 rewritten**: precise guarantees — a provider cannot self-certify (holds), but `verified` is
  **not** benchmark-authenticity/anti-splice (string-consistency + operator anchor only), is
  (chip, memory)-anchored (not identity-anchored) and revocable; two `verified` writers exist
  (verifier + operator inventory); defense-in-depth (trust gate enforced twice).
- **§1 boundary corrected**: `verified` is consumed by SPEC-032's admission lookup, not a direct
  SPEC-002 tier input; producer is the HTTP endpoint, SPEC-023 owns evidence content.
- **§11 scheduling**: systemd oneshot + timer (not "periodic invocation").
- **§12**: fixed AC-HV-1 (no-op/monotonic + DB re-verify), AC-HV-4 (profile bit vs job status),
  AC-HV-6 (one row/one verdict), AC-HV-9 (exact-v2 downstream); added AC-HV-10 (demotion) and
  AC-HV-11 (chip/memory re-verification).

**v0.1-draft (2026-07-12) — reconstructed baseline (runbook item 10).** First canonical spec for
the shipped `hardware-verifier.v2` verifier; superseded by v0.2 above.
