# SPEC-033 — Hardware-Evidence Verifier (`hardware-verifier.v2`)

**Status:** v0.2-draft
**Date:** 2026-07-12
**Depends on:** SPEC-023 (autotune — produces the benchmark/recommendation inputs the evidence document carries). **Consumed by:** SPEC-032 (autotune hardware-evidence admission "hello-gate") reads this spec's verdict via an **exact-`hardware-verifier.v2`** lookup and cross-references it as "the item-10 hardware-verifier verdict spec". This spec owns the `hardware-verifier.v2` decision semantics and the job/profile lifecycle; SPEC-032 owns how a `verified` profile gates admission.

**Producer / enqueue boundary (see §3.1):** the provider **binary** builds the evidence envelope (`phase3-binary/Sources/macprovider-cli/AutotuneHardwareEvidence.swift`) and submits it over an **authenticated HTTP `POST /v1/providers/hardware-evidence`** (`phase4-coordinator/internal/onboarding/hardware_evidence.go` `HandleHardwareEvidence`), which enqueues a `hardware_verification_jobs` row. SPEC-023 owns the *content* (benchmarks, recommended model); the HTTP envelope + enqueue + replay state machine are owned here.

**Numbering note.** Assigned canonical **SPEC-033** on 2026-07-12 (Wave C of the
2026-07-10 SPEC-vs-code drift audit; runbook item 10). Highest prior canonical spec
was SPEC-032. This document is the **reconstructed normative baseline** for a shipped,
production-live coordinator trust signal that ships **unspecced**.

**Source-of-truth discipline.** This is documentation of shipped behavior. The **code and
migrations are authoritative**; this spec MUST byte-match them and any disagreement is a spec
bug. The contract spans: the verifier (`phase4-coordinator/internal/stats/hardwareverify/verify.go`),
migrations **007, 008, 015, 016, 017** (`phase4-coordinator/internal/stats/migrations/`), the
HTTP enqueue path (`internal/onboarding/hardware_evidence.go`), the operator inventory
writer/demotion (`cmd/stats-inventory-sync/main.go`), the runner
(`cmd/stats-hardware-verifier/main.go`), and the exact-v2 downstream consumers
(`internal/onboarding/hardware_evidence.go`, `internal/autotune/evidence_pg.go`). **Where §2
summarizes DDL, the migration files are the byte-authoritative shape.**

---

## 1. Purpose and scope

### 1.1 Purpose

A provider's autotune run (SPEC-023) produces a **hardware-evidence document**
(`hardware_evidence.autotune.v1`) describing its Apple-silicon chip, unified memory, OS/binary
versions, a stable `hardware_identity_hash`, and local model benchmarks. The provider binary
submits it (§3.1); a row lands in `hardware_verification_jobs`. The **hardware-evidence
verifier** is a coordinator-side **batch job** that reads pending jobs, runs a deterministic
ordered gate pipeline over each evidence document, and transitions the job to **`verified`**,
**`rejected`**, or the non-terminal **`waiting_trust`** — promoting a
`provider_hardware_profiles.verified = TRUE` row on success.

### 1.2 What `verified` means and who consumes it

`provider_hardware_profiles.verified` is consumed by **SPEC-032's hardware-evidence admission
lookup** (`internal/autotune/evidence_pg.go`), which requires a `verified = TRUE` profile joined
to a `status='verified'` job carrying the **exact** `hardware-verifier.v2:verified_trusted_hardware`
decision reason. It is **not** itself a SPEC-002 tier/routing input — SPEC-002 tiers derive from
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

Four tables plus **two** guard triggers and least-privilege **column-level** grants. Migrations
**007, 008, 015, 016, 017** are the byte-authoritative DDL; the tables below are a load-bearing
summary — a reimplementation MUST read the migrations for exact column lists, `NOT NULL`/`DEFAULT`
clauses, `CHECK` constraints, indexes, and grants.

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

### 2.2 `hardware_verification_trust` — operator-curated trust roots (migration 008)

`(provider_id, hardware_identity_hash)` PK, plus `chip_normalized`, `unified_memory_gb`,
`trusted_by`, `trusted_at`, `expires_at NULL`, `notes`. A row asserts an operator vouches that
`hardware_identity_hash` for this provider is a genuine device with this chip + memory.
`expires_at IS NULL` or in the future ⇒ active. Written only by the operator trust-curation role
(`stats_trust_inventory_writer`); the verifier only reads it.

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
  `provider_hardware_profiles` — all gated by triggers A/B. `NOLOGIN`.
- **`provider_onboarding`** (the enqueue path): **column-level** `INSERT` on the job columns
  (including `status`, but the shipped enqueue always inserts `pending`) and **column-limited
  `SELECT`** (`id, provider_id, status, submitted_at, evidence_sha256, decision_reason`, and —
  migration 017 — `provider_id, chip_normalized, unified_memory_gb, verified` on profiles). It has
  **no `verified` write grant** and trigger A forces `verified=FALSE` regardless: **onboarding can
  never self-promote.** (A compromised onboarding SQL role could insert a job with a terminal
  `status`, but that cannot set a profile's `verified` bit — §10.1.)
- **`stats_inventory_writer`** (operator inventory sync, §7.3): full `INSERT/UPDATE` on
  `provider_hardware_profiles` **including `verified`**, and **not** constrained by trigger A. This
  is an **operator-authority** path, not a provider-reachable one (§10.1).
- **`stats_trust_inventory_writer`**: writes `hardware_verification_trust` (the trust roots).

---

## 3. Evidence document schema (`hardware_evidence.autotune.v1`)

The `evidence` JSONB decodes to (`hardwareverify.Evidence`):

```
schema_version           string   // MUST equal "hardware_evidence.autotune.v1"
provider_id              string
generated_at             string   // RFC3339
hardware {
  chip                   string
  memory_gb              int
  bandwidth_tier         string
  detected               bool
  os_version             string
  binary_version         string
  hardware_identity_hash string   // lowercase hex SHA-256 (64 chars)
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
  generated_at                         string  // RFC3339
  binary_version, hardware_identity_hash string
}
```

A **lowercase hex SHA-256** is exactly 64 chars in `[0-9a-f]` (`isLowerSHA256`).

### 3.1 Submission and replay (enqueue path)

The provider binary POSTs the envelope to **`POST /v1/providers/hardware-evidence`** with its
authenticated bearer identity; the handler (`HandleHardwareEvidence`) binds the job to the
**authenticated** `provider_id` (a provider cannot enqueue for another provider). The handler:

- computes a **canonical** SHA-256 of the evidence (`canonicalEvidenceSHA`) → `evidence_sha256`;
- **rate-limits**: if a recent job for this provider exists within a 10-minute window, returns
  HTTP `429` with `Retry-After: 600`;
- inserts a `pending` job (unique on `evidence_sha256`);
- returns a **replay state machine** result (`hardwareEvidenceResponseStatus`), which is
  **fail-closed**: a duplicate is accepted (2xx) **only** while `pending`, while `waiting_trust`,
  or when already `verified` **with `decision_reason == hardware-verifier.v2:verified_trusted_hardware`
  exactly**. Every other finalized/unknown/legacy state (`rejected`, `v1:verified`, …) returns
  HTTP `409` `evidence_replay_not_accepted` — a rejected or legacy decision cannot be laundered
  through a 2xx replay; new evidence must be resubmitted.

---

## 4. Decision constants, versioning, and downstream acceptance

- **Verifier version:** `hardware-verifier.v2` (`verifierDecisionVersion`).
- **Evidence schema version:** `hardware_evidence.autotune.v1` (`evidenceSchemaVersion`).
- **Success constant:** `hardware-verifier.v2:verified_trusted_hardware` (`VerifiedDecisionReason`).
- **Reject/wait reasons** are persisted as `hardware-verifier.v2:<bare reason>` —
  `rejectJob`/`waitTrustJob` prefix the version at write time (e.g.
  `hardware-verifier.v2:chip_mismatch`, `hardware-verifier.v2:missing_trusted_hardware_identity`,
  `hardware-verifier.v2:missing_trusted_chip_profile`). `Evaluate` returns the bare reason; only
  success returns the pre-prefixed `VerifiedDecisionReason`.

**Legacy `hardware-verifier.v1:verified` and downstream acceptance.** The *verifier* grandfathers
legacy terminal rows only in the sense that it scans **only** `pending`/`waiting_trust`, so a
legacy `verified` row is never re-evaluated. **Downstream consumers do NOT accept arbitrary
`status='verified'` rows** — they require the **exact** current v2 reason:

- onboarding replay accepts a `verified` job only when `decision_reason == VerifiedDecisionReason`
  (`hardware_evidence.go`; its test rejects `hardware-verifier.v1:verified`);
- SPEC-032's evidence lookup filters on `decision_reason = VerifiedDecisionReason`
  (`internal/autotune/evidence_pg.go`).

So a legacy `v1:verified` row is terminal and unscanned, but is **not** treated as a *current
trusted verdict* by downstream consumers; only the exact v2 reason is.

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

### 7.3 Post-verdict demotion (operator inventory sync)

`provider_hardware_profiles.verified` is not permanent. The operator inventory sync
(`cmd/stats-inventory-sync`, role `stats_inventory_writer`) runs `applyTrustDemotions`, which sets
`verified = FALSE` for every `source='cli_hello'` profile that **no longer** has a matching active
trust row (trust removed or `expires_at` passed). So **removing/expiring a trust root demotes the
previously-verified providers** on the next sync. The same tool also directly upserts operator
profiles (`source='operator'`, `verified` from an operator-authored YAML) — an operator-authority
write path outside the evidence pipeline (§10.1).

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
- **One queue row does NOT mean one evaluation.** A `waiting_trust` job is re-`Evaluate`d on every
  batch run until it reaches a terminal state; this is by design (§6). Idempotency is preserved by
  the terminal-safe write `WHERE` + trigger B: a job cannot double-promote or be reopened.
- Net: **exactly one queue row per distinct document; exactly one *terminal verdict* committed;
  possibly many interim `waiting_trust` evaluations.**

---

## 10. Security model — precise guarantees and non-guarantees

### 10.1 A provider cannot self-certify (holds)

No provider-reachable path sets `provider_hardware_profiles.verified = TRUE`:

- The only provider-reachable write path is the authenticated enqueue (§3.1), which runs as
  `provider_onboarding` — a role with **no `verified` write grant**, and trigger A forces
  `verified=FALSE` for it regardless (§2.5, §2.7). The worst a compromised onboarding SQL role can
  do is insert a job row with a terminal `status`; it still cannot flip a profile's `verified` bit.
- `verified=TRUE` is writable by exactly **two** roles, **neither provider-reachable**:
  (1) `stats_hardware_verifier`, only via `promoteJob` **and** only if the trust join passes both
  in `Evaluate` (§5.5) and in the DB trigger (§2.5); (2) `stats_inventory_writer`, an
  **operator-authority** path syncing an operator-authored YAML (`source='operator'`), the same
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
  standing (chip, memory) capacity assertion, revocable by trust removal.

### 10.3 Defense in depth (the trust gate is enforced twice)

The trust/chip/freshness match is checked in **application code** (`Evaluate`, §5.5) **and again
in the database** (trigger A re-runs the full join at write time, §2.5). A logic bug that let
`Evaluate` pass a bad job would still be caught by the DB trigger, which RAISES and rolls back.
Trigger B (§2.6) additionally prevents the verifier from reopening finalized jobs or moving them to
an out-of-band status.

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
- **AC-HV-3 (waiting is non-terminal).** A job missing only a trust row or chip profile MUST become
  `waiting_trust` (not `rejected`) and MUST promote on a later run once the operator-curated row
  exists — no re-submission.
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
- **AC-HV-9 (legacy grandfathering + exact-v2 downstream).** A `hardware-verifier.v1:verified` row
  MUST remain terminal and MUST NOT be re-evaluated by the verifier; **downstream consumers MUST
  accept only the exact `hardware-verifier.v2:verified_trusted_hardware` reason** as a current
  trusted verdict (§4), so a legacy row is not honored downstream.
- **AC-HV-10 (demotion).** Removing or expiring a `hardware_verification_trust` row MUST demote the
  affected `source='cli_hello'` profiles to `verified=FALSE` on the next inventory sync (§7.3).
- **AC-HV-11 (chip/memory re-verification).** A `provider_onboarding` update that changes
  `chip_normalized` or `unified_memory_gb` MUST clear `verified` (trigger A).

---

## Change log

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
