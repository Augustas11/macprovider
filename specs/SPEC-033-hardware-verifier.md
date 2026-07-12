# SPEC-033 — Hardware-Evidence Verifier (`hardware-verifier.v2`)

**Status:** v0.1-draft
**Date:** 2026-07-12
**Depends on:** SPEC-002 (coordinator provider state machine; `provider_hardware_profiles.verified` is a routing/tier input), SPEC-003 (open onboarding; the App/CLI hello that submits evidence), SPEC-023 (autotune — produces the `hardware_evidence.autotune.v1` evidence document this verifier consumes). SPEC-032 (autotune hardware-evidence admission "hello-gate") **consumes this spec's verdict as an input** and cross-references it as "the item-10 hardware-verifier verdict spec"; SPEC-033 owns the `hardware-verifier.v2` decision semantics, SPEC-032 owns how the resulting `verified` profile gates admission.

**Numbering note.** Assigned canonical **SPEC-033** on 2026-07-12 (Wave C of the
2026-07-10 SPEC-vs-code drift audit; runbook item 10). Highest prior canonical spec
was SPEC-032. This document is the **reconstructed normative baseline** for a shipped,
production-live coordinator trust signal that ships **unspecced**: the batch
**hardware-evidence verifier** that promotes a provider's autotune hardware evidence to a
`verified` hardware profile, emitting `hardware-verifier.v2:*` decision reasons. The shipped
success constant is `hardware-verifier.v2:verified_trusted_hardware` (the code is at
`phase4-coordinator/internal/stats/hardwareverify/verify.go`; the runner is
`phase4-coordinator/cmd/stats-hardware-verifier/main.go`). **This spec is documentation of
shipped behavior — it MUST NOT diverge from that code; the code is the source of truth and any
disagreement is a spec bug.**

---

## 1. Purpose and scope

### 1.1 Purpose

A provider's autotune run (SPEC-023) produces a signed-shape **hardware-evidence document**
(`hardware_evidence.autotune.v1`) describing the provider's Apple-silicon chip, unified memory,
OS/binary versions, a stable `hardware_identity_hash`, and a set of local model benchmarks. The
provider submits it during onboarding; a row lands in `hardware_verification_jobs`. The
**hardware-evidence verifier** is a coordinator-side **batch job** that reads pending jobs,
runs a deterministic ordered gate pipeline over each evidence document, and transitions the job
to **`verified`**, **`rejected`**, or the non-terminal **`waiting_trust`** state — promoting a
`provider_hardware_profiles.verified = TRUE` row on success.

`provider_hardware_profiles.verified` is a downstream routing/tier input (SPEC-002 provider
state; SPEC-032 admission gate). This spec defines **only** the verdict engine: what makes
evidence verifiable, the decision-reason taxonomy, the job/profile state machine, and the
security model that prevents a provider from self-certifying.

### 1.2 In scope

- The `hardware-verifier.v2` decision-reason taxonomy and the shipped success constant.
- The ordered verification algorithm (`Evaluate`) and every reject/wait reason it can emit.
- The job lifecycle state machine (`pending` / `waiting_trust` / `verified` / `rejected`).
- The verified-profile promotion (upsert) semantics and monotonicity guard.
- Batch/concurrency semantics (`FOR UPDATE SKIP LOCKED`, batch limit, single transaction).
- Idempotency / replay resistance (`evidence_sha256` uniqueness).
- The database security model: least-privilege roles and the profile-verification trigger.
- The runner and its preflight `Smoke` contract.

### 1.3 Out of scope

- **How the evidence is produced.** Autotune benchmark generation, chip detection, and the
  `hardware_identity_hash` derivation are SPEC-023 / provider-binary concerns. This spec treats
  the evidence document as an untrusted input to validate.
- **How `verified` gates admission or tiers.** SPEC-032 (hello-gate) and SPEC-002 own that.
- **The trust-root curation policy.** *How* an operator decides to insert a
  `hardware_verification_trust` row (attestation review, manual vetting) is an operational
  policy; this spec defines only how a trust row is *matched*.
- **Proof-of-weights / OPoI / model-hash attestation.** Those are SPEC-032 / SPEC-008.

---

## 2. Data model

Four tables (migrations `007_hardware_profiles`, `008_hardware_verification_jobs`) plus a
verification-guard trigger.

### 2.1 `hardware_verification_jobs` — the work queue

Columns (normative shape; `phase4-coordinator/internal/stats/migrations/008_hardware_verification_jobs.up.sql`):

| Column | Type / constraint | Meaning |
| --- | --- | --- |
| `id` | `BIGSERIAL` PK | job id; processing order |
| `provider_id` | `TEXT NOT NULL` | provider the evidence claims to be from |
| `source` | `TEXT CHECK (source IN ('autotune'))` | only autotune-sourced jobs exist |
| `status` | `TEXT CHECK (... 'pending','waiting_trust','verified','rejected') DEFAULT 'pending'` | job state |
| `chip`, `chip_normalized` | `TEXT NOT NULL` | claimed chip + normalized form |
| `unified_memory_gb` | `INT CHECK (0..4096)` | claimed unified memory |
| `bandwidth_tier`, `os_version`, `binary_version` | `TEXT NOT NULL DEFAULT ''` | claimed metadata |
| `benchmark_count` | `INT CHECK (0..64) DEFAULT 0` | summary count |
| `max_sustained_tps` | `DOUBLE PRECISION CHECK (>= 0)` | summary metric |
| `generated_at` | `TIMESTAMPTZ NOT NULL` | when the provider generated the evidence |
| `submitted_at` | `TIMESTAMPTZ DEFAULT now()` | when the job was enqueued |
| `processed_at` | `TIMESTAMPTZ NULL` | when the verifier decided |
| `decision_reason` | `TEXT NOT NULL DEFAULT ''` | the emitted `hardware-verifier.v2:*` (or legacy) reason |
| `evidence` | `JSONB NOT NULL` | the full evidence document |
| `evidence_sha256` | `TEXT NOT NULL UNIQUE` | **replay guard** — a duplicate evidence document cannot enqueue twice |

Partial index on `status IN ('pending','waiting_trust')` supports the batch scan.

### 2.2 `hardware_verification_trust` — operator-curated trust roots

`(provider_id, hardware_identity_hash)` PK, plus `chip_normalized`, `unified_memory_gb`,
`trusted_by`, `trusted_at`, `expires_at NULL`, `notes`. A row asserts "this operator vouches
that `hardware_identity_hash` for this provider is a genuine device with this chip + memory."
`expires_at IS NULL` (or in the future) means active. **Only an operator/trust-curation role
writes this table; the verifier only reads it.** This is the human-in-the-loop trust anchor
that makes self-certification impossible (§10).

### 2.3 `provider_hardware_profiles` — the verified output

`provider_id` PK, `chip`, `chip_normalized`, `unified_memory_gb`, `macos_version`,
`app_version`, `source TEXT CHECK (source IN ('app_register','cli_hello','operator'))`,
`verified BOOLEAN DEFAULT FALSE`, `last_reported_at`. A successful verdict upserts this row
with `verified = TRUE`, `source = 'cli_hello'` (§7).

### 2.4 `chip_hardware_profiles` — the known-chip catalog

`chip_normalized` PK plus physical characteristics (`memory_bandwidth_gb_per_s`,
`network_power_kw`, `gpu_cores`, `cpu_cores`). A job's `chip_normalized` MUST have a row here
or the job goes to `waiting_trust` (§5.5). Operator-curated.

### 2.5 Verification guard trigger

`provider_hardware_profiles_guard_verification` (a `BEFORE INSERT/UPDATE` trigger) is a
**defense-in-depth** DB guard, independent of application code:

- Under role `provider_onboarding`: `verified` is forced to `FALSE` on insert, and forced back
  to `FALSE` whenever `chip_normalized` changes; otherwise preserved. **A provider-onboarding
  writer can never set `verified = TRUE`.**
- Under role `stats_hardware_verifier` (the verifier): an `UPDATE` that moves
  `last_reported_at` **backward** RAISES — enforcing timestamp monotonicity at the DB layer,
  matching the application-level guard in §7.

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
  model_key                 string
  model_id                  string
  sustained_tps             float64
  ttft_ms                   int
  swap_detected             bool
  thermal_throttle_detected bool
  artifact_sha256           string  // lowercase hex SHA-256
  candidate_catalog_sha256  string
  benchmark_id              string  // optional
  generated_at              string  // RFC3339
  binary_version            string
  hardware_identity_hash    string
}
```

A **lowercase hex SHA-256** is exactly 64 characters, each in `[0-9a-f]` (`isLowerSHA256`).
Uppercase, wrong length, or non-hex fails the relevant gate.

---

## 4. Decision constants and versioning

- **Verifier version:** `hardware-verifier.v2` (`verifierDecisionVersion`).
- **Evidence schema version:** `hardware_evidence.autotune.v1` (`evidenceSchemaVersion`).
- **Success constant:** `hardware-verifier.v2:verified_trusted_hardware`
  (`VerifiedDecisionReason`). This is the exported constant other components match on.
- **Reject/wait reasons** are persisted as `hardware-verifier.v2:<reason>` — the verifier
  prefixes the bare reason with the version at write time in `rejectJob` / `waitTrustJob`
  (e.g. `hardware-verifier.v2:chip_mismatch`, `hardware-verifier.v2:trust_missing`). The
  `Evaluate` function returns the bare reason; only the success path returns the
  already-prefixed `VerifiedDecisionReason`.
- **Legacy `hardware-verifier.v1:verified`** rows predate this version and MUST be treated as
  terminal `verified` (grandfathered): the verifier only scans `pending`/`waiting_trust`, so a
  legacy `verified` row is never re-evaluated, and downstream consumers treat any
  `status = 'verified'` row as verified regardless of version prefix.

> **Naming note (the drift this spec closes).** The shipped success constant is
> `hardware-verifier.v2:verified_trusted_hardware`, **not** a `v1` reason. Earlier drift
> assumed a `v1` verifier; the live constant is `v2`. This spec is authoritative on the `v2`
> taxonomy.

---

## 5. Verification algorithm (`Evaluate`)

`Evaluate(job)` runs `evaluateAt(job, now)` with `now = time.Now().UTC()`. It is a
**deterministic, ordered, short-circuit** gate pipeline: the **first** failing gate wins and
its reason is returned; only a job that passes every gate returns
`{Verified: true, Reason: VerifiedDecisionReason}`. The order below is normative — a
reimplementation MUST emit the same reason for the same first-failing condition.

Time bounds: `maxEvidenceAge = 7 * 24h`; `futureSkew = 5m`. A timestamp `t` is **stale** if
`t < now - maxEvidenceAge`, and **future-skewed** if `t > now + futureSkew`; either is a
failure on the relevant gate.

### 5.1 Job-envelope gates (reject)

In order: `missing_provider_id` (blank `provider_id`); `stale_job` (`job.generated_at`
out of the age/skew window); `memory_out_of_range` (`job.unified_memory_gb < 8` or `> 4096`);
`missing_evidence` (empty `evidence`); `invalid_evidence_json` (JSON decode fails).

> Note the verifier's `>= 8` GB floor is stricter than the table's `>= 0` CHECK — the DB
> accepts smaller values but the verifier rejects them.

### 5.2 Evidence-consistency gates (reject)

`schema_version_mismatch` (`schema_version != hardware_evidence.autotune.v1`);
`provider_id_mismatch` (`evidence.provider_id != job.provider_id`);
`invalid_evidence_generated_at` (not RFC3339); `evidence_generated_at_mismatch`
(`evidence.generated_at` not **exactly equal** to `job.generated_at`); `stale_evidence`
(evidence timestamp out of window).

### 5.3 Hardware-claim cross-check gates (reject)

The evidence's self-described hardware MUST match the job columns the onboarding path already
recorded: `chip_mismatch` (`normalizeChip(evidence.hardware.chip) != job.chip_normalized`,
where `normalizeChip` lowercases, trims, and collapses internal whitespace);
`memory_mismatch`; `bandwidth_tier_mismatch` (case-insensitive, trimmed);
`os_version_mismatch` (trimmed, exact); `binary_version_mismatch` (trimmed, exact);
`invalid_hardware_identity_hash` (not lowercase-hex SHA-256);
`invalid_candidate_catalog_sha256`.

### 5.4 Benchmark gates (reject)

`missing_benchmarks` (empty list). Then, per benchmark, in list order:
`missing_benchmark_model_binding` (blank `model_key` or `model_id`);
`duplicate_benchmark_model_key` (a `model_key` seen earlier in the same document);
`invalid_benchmark_artifact_sha256`; `benchmark_catalog_mismatch`
(`benchmark.candidate_catalog_sha256 != evidence.candidate_catalog_sha256`);
`benchmark_binary_version_mismatch` (`!= evidence.hardware.binary_version`);
`benchmark_hardware_identity_mismatch` (`!= evidence.hardware.hardware_identity_hash`);
`invalid_benchmark_generated_at`; `stale_benchmark`; `invalid_benchmark_tps` (NaN, ±Inf, or
`<= 0`); `invalid_benchmark_ttft` (`<= 0`). After the loop: `missing_positive_benchmark` (no
benchmark has a finite `sustained_tps > 0`) and `missing_chip_normalized` (blank
`job.chip_normalized`).

### 5.5 Trust gates (→ `waiting_trust`, NOT reject)

The final two gates are **trust-anchor** checks. They do **not** reject; they return a reason
the caller routes to the non-terminal `waiting_trust` state (§6):

- `missing_trusted_hardware_identity` — no active `hardware_verification_trust` row matches
  `(provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb)` with
  `expires_at IS NULL OR expires_at > now()`.
- `missing_trusted_chip_profile` — no `chip_hardware_profiles` row for this `chip_normalized`.

(The two `EXISTS` sub-queries are computed in the batch SELECT as `trust_matched` /
`chip_profile_matched` and read by `Evaluate` as `job.TrustMatched` / `job.ChipProfileMatched`.)

### 5.6 Success

Passing every gate returns `hardware-verifier.v2:verified_trusted_hardware`.

---

## 6. Job lifecycle state machine

```
                submit (onboarding)
                      │
                      ▼
                  ┌────────┐   trust/chip-profile absent    ┌───────────────┐
                  │pending │ ─────────────────────────────▶ │ waiting_trust │
                  └───┬────┘                                └──────┬────────┘
        reject gate │  │ all gates pass          all gates pass /  │ trust/chip
                    │  │                          reject gate hits  │ still absent
                    ▼  ▼                                            │ (re-scanned)
              ┌──────────┐        ┌──────────┐                      │
              │ rejected │        │ verified │◀─────────────────────┘
              └──────────┘        └──────────┘
```

- The batch scan selects `status IN ('pending','waiting_trust')`. **`waiting_trust` is
  non-terminal**: a job parked there is re-evaluated on every subsequent run, so once an
  operator later inserts the missing `hardware_verification_trust` or `chip_hardware_profiles`
  row, the same job promotes to `verified` without re-submission.
- `verified` and `rejected` are **terminal** (never re-scanned).
- A `waiting_trust` job that later hits a **reject** gate (e.g. its evidence has since gone
  stale) transitions to `rejected` — the age gates are evaluated against the *current* `now`.
- All three transitions set `processed_at = now()` and `decision_reason`, and are guarded by
  `WHERE id = $1 AND status IN ('pending','waiting_trust')` so a concurrently-terminalized job
  is not overwritten.

---

## 7. Verified-profile promotion

On a `verified` verdict, `promoteJob` upserts `provider_hardware_profiles`:

- `INSERT ... VALUES (provider_id, chip, chip_normalized, unified_memory_gb, os_version→macos_version, binary_version→app_version, source='cli_hello', verified=TRUE, generated_at→last_reported_at)`.
- `ON CONFLICT (provider_id) DO UPDATE SET ... verified = TRUE, last_reported_at = EXCLUDED.last_reported_at` **only** `WHERE provider_hardware_profiles.last_reported_at <= EXCLUDED.last_reported_at` — a **monotonicity guard**: an older evidence document can never overwrite a newer verified profile (and the §2.5 trigger enforces the same invariant at the DB layer under the verifier role).
- The job row is then set to `status='verified'`, guarded by the same terminal-safe `WHERE`.

Both writes happen in the **same transaction** as the scan (§8), so a profile promotion and its
job terminalization commit atomically.

---

## 8. Concurrency and batching

- `ProcessPending(ctx, limit)` opens **one transaction**, scans up to `limit` (default 100)
  jobs `ORDER BY id` with **`FOR UPDATE SKIP LOCKED`**, decides each, applies the writes, and
  commits once. `SKIP LOCKED` lets multiple verifier instances run concurrently without
  contending on the same jobs.
- The scan and all decision writes share the transaction; a failure at any job rolls the whole
  batch back (`defer tx.Rollback()`), so a batch is all-or-nothing.
- `Processed{Verified, Rejected, Waiting}` counts the batch outcome for the runner to log.

---

## 9. Idempotency and replay resistance

- `hardware_verification_jobs.evidence_sha256` is `UNIQUE`. The onboarding submit path keys on
  the evidence hash, so the **same evidence document cannot enqueue two jobs** — a replayed
  submission collides on the unique constraint. Verification is therefore evaluated at most
  once per distinct evidence document.
- The verifier itself is naturally idempotent: terminal states are never re-scanned, and the
  terminal-safe `WHERE status IN ('pending','waiting_trust')` on every write means a
  double-processed job (e.g. across a crash/retry) cannot double-promote.

---

## 10. Security model — why a provider cannot self-certify

Verification trust does **not** come from the evidence being well-formed; a provider fully
controls its own evidence document. Trust comes from **operator-curated anchors** the provider
cannot write:

1. **Trust-root gate (§5.5).** `verified` requires a matching active
   `hardware_verification_trust` row keyed on `(provider_id, hardware_identity_hash,
   chip_normalized, unified_memory_gb)`. Only an operator/trust-curation role writes that
   table. Absent a trust row, the best a provider can reach is `waiting_trust` — never
   `verified`.
2. **Known-chip gate (§5.5).** The `chip_normalized` must exist in the operator-curated
   `chip_hardware_profiles` catalog.
3. **DB least-privilege + trigger (§2.5).** The verifier runs as `stats_hardware_verifier`; the
   onboarding submitter runs as `provider_onboarding`. The
   `provider_hardware_profiles_guard_verification` trigger **forces `verified = FALSE`** for any
   write by `provider_onboarding` and forbids the verifier from moving `last_reported_at`
   backward. Even a SQL-injection or logic bug in the onboarding path cannot set
   `verified = TRUE`; only the verifier role, going through `promoteJob`, can — and only after
   the trust gates pass.
4. **Evidence self-consistency (§5.2–5.4)** binds every benchmark to the same
   `hardware_identity_hash`, `binary_version`, and `candidate_catalog_sha256`, so a provider
   cannot splice a trusted device's identity onto another device's benchmarks within one
   document.

The security property is: **`verified` ⟺ (well-formed self-consistent fresh evidence) ∧
(operator-anchored trust for this exact identity+chip+memory)**. The provider supplies the
former; only an operator supplies the latter.

---

## 11. Runner and operations

- **Binary:** `phase4-coordinator/cmd/stats-hardware-verifier/main.go` — opens the store with a
  DSN, runs `Smoke`, then `ProcessPending`, and prints
  `stats-hardware-verifier: verified=<n> rejected=<n> waiting=<n>`.
- **`Smoke(ctx)` preflight** MUST pass before processing: it asserts `current_user =
  'stats_hardware_verifier'` (fail-closed on a mis-provisioned DSN) and that the four tables
  (`hardware_verification_jobs`, `hardware_verification_trust`, `provider_hardware_profiles`,
  `chip_hardware_profiles`) are readable. A `Smoke` failure MUST abort the run before any job
  is touched.
- **Connection pool:** capped small (`MaxOpenConns=2`, `MaxIdleConns=1`) — this is a periodic
  batch worker, not a hot-path service.
- **Scheduling** is operational (a periodic invocation of the binary). Because `waiting_trust`
  is non-terminal and re-scanned, a provider verified only after an operator adds a trust row
  is promoted by the next scheduled run with no provider action.

---

## 12. Acceptance criteria

- **AC-HV-1 (success constant).** A job with well-formed, self-consistent, fresh evidence whose
  `(provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb)` matches an active
  trust row and whose `chip_normalized` is in `chip_hardware_profiles` MUST become `verified`
  with `decision_reason = 'hardware-verifier.v2:verified_trusted_hardware'` and MUST upsert
  `provider_hardware_profiles.verified = TRUE`.
- **AC-HV-2 (ordered reasons).** For each gate in §5, a job failing exactly that gate first MUST
  persist `decision_reason = 'hardware-verifier.v2:<that reason>'`. Gate order is normative.
- **AC-HV-3 (waiting is non-terminal).** A job missing only a trust row or chip profile MUST
  become `waiting_trust` (not `rejected`), and MUST promote to `verified` on a later run once
  the missing operator-curated row exists — with no re-submission.
- **AC-HV-4 (no self-certification).** No write by `provider_onboarding` may set
  `provider_hardware_profiles.verified = TRUE` (trigger-enforced); a provider without a trust
  row MUST NOT reach `verified`.
- **AC-HV-5 (monotonic promotion).** An older evidence document MUST NOT overwrite a newer
  verified profile (`last_reported_at` guard, application + trigger).
- **AC-HV-6 (replay).** Two submissions of the same evidence document MUST NOT create two jobs
  (`evidence_sha256` UNIQUE); verification is evaluated at most once per distinct document.
- **AC-HV-7 (batch isolation).** Concurrent verifier instances MUST NOT double-process a job
  (`FOR UPDATE SKIP LOCKED` + terminal-safe write `WHERE`).
- **AC-HV-8 (Smoke fail-closed).** A run whose `Smoke` preflight fails (wrong DB role or an
  unreadable table) MUST abort before touching any job.
- **AC-HV-9 (legacy grandfathering).** A `hardware-verifier.v1:verified` row MUST remain
  terminal-`verified` and MUST NOT be re-evaluated.

---

## Change log

**v0.1-draft (2026-07-12) — reconstructed baseline (runbook item 10).**
- First canonical spec for the shipped `hardware-verifier.v2` evidence verifier
  (`phase4-coordinator/internal/stats/hardwareverify/verify.go`). Documents the decision-reason
  taxonomy, the ordered gate pipeline, the `pending`/`waiting_trust`/`verified`/`rejected` state
  machine, promotion + monotonicity, batch/concurrency, `evidence_sha256` replay resistance, and
  the least-privilege + trigger security model that makes provider self-certification impossible.
- Closes the naming drift: the live success constant is
  `hardware-verifier.v2:verified_trusted_hardware` (v2, not v1); legacy `v1:verified` rows are
  grandfathered.
- Spec-only, no code change: the code is the source of truth and this document byte-matches it.
