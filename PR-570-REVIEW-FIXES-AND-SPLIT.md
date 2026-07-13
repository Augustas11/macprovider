# PR #570 — Adversarial + Product Review: Fixes Catalog & Split Recommendation

**PR:** `feat: gate pre-beta registration with referrals` — https://github.com/Augustas11/macprovider/pull/570
**Branch:** `feat/referral-gated-prebeta` (base `main`)
**Reviewed base → head:** `f3aff9a` (merge-base) → `f3542c8` (original PR) → **26 fix commits** on top
**Size after fixes:** 61 files, **+11,101 / −228** (was +5,417/−169 as submitted)
**Status of tree at this checkpoint:** all gates green (see [Validation](#validation)).

> This document is a deliberate **stop point** after five rounds of fix implementation.
> It (1) catalogs every fix applied and (2) recommends splitting this PR into smaller,
> independently-reviewable PRs. **The round-5 fixes are implemented and fully tested but have
> NOT yet been re-audited** — a round-6 adversarial/product pass would be required to claim a
> verified `0 C/H/M`. See [Convergence status](#convergence-status).

---

## 1. What the PR does

Gates every public *first* provider-credential mint behind one durable, transactional referral
authority; adds post-serving provider invites and an optional verified-X sharing bonus (no change to
trust/payout/routing/admission/serving state); ships the join landing route, coordinator APIs,
installer/CLI/App transport, dashboard advocacy UI, metrics, operator seed/revoke controls; makes
App-track PostgreSQL + SQLite minting crash-safe with a pending-mint saga + reconciler; preserves
existing-provider repair/reconnect.

## 2. Review method

Two independent **codex** review lanes were run each round against the full diff + worktree:
- **Adversarial reviewer** — correctness/security/money-path/auth defects (tries to *break* the code).
- **Product-design critic** — flows, incentives, failure UX, operator ergonomics.

The PR body claimed `C0/H0/M0` from both lanes. The independent re-review did **not** reproduce that;
it found substantial defects and the loop drove them down over four audit rounds + five fix rounds.

### Verdict trajectory (C/H/M/L per lane)

| Audit round | Adversarial (code) | Product-design | Notes |
|---|---|---|---|
| R1 | **C2 H0 M2 L0** | **C1 H7 M6 L1** | vs PR body's claimed C0/H0/M0 |
| R2 | C1 H4 M4 L2 | C1 H3 M6 L1 | caught regressions in R1 fixes |
| R4 | C1 H3 M3 L0 | C1 H5 M6 L2 | narrowing; recovery/reservation interplay surfaced |
| R5 | *fixes implemented, not yet re-audited* | *same* | stopped here per request |

**Design discovery (R4):** the two subsystems that kept regenerating criticals —
**lost-response token-rotation recovery** and **preflight capacity reservation** — were **added by
this review loop's own R1 fixes** (to satisfy the R1 findings PROD-C1 "unrecoverable bearer" and
PROD-H1 "no reservation during install"). They interact with each other, with the crash reconciler,
nonce-replay, and cross-attempt sagas, and are the dominant source of recurring HIGH/CRITICAL
findings. This directly motivates the split in §5.

---

## 3. Complete fix catalog

Severity at time of finding. Each row → the commit that resolved it. `ADV` = adversarial lane,
`PROD` = product lane.

### Round 1 (against the submitted PR)

| ID | Sev | Finding | Fix | Commit |
|---|---|---|---|---|
| ADV-C1 | CRIT | Provider bearer serialized to `manual-provider.json` via `KERN_PROCARGS2` env capture | Bearer transported over an anonymous stdin pipe (`--token-fd 0`), never the child env; recovery snapshot redacts token/secret/key-shaped env entries | `db5d5b7` |
| ADV-C2 | CRIT | Reconciliation deleted a *committed* credential when the replay nonce was pruned (65s) before the 2-min reconcile (`ProviderRegistrationPrepared` joined the prunable nonce table) | Durable `provider_register_attempts` marker (migration 018) written atomically with identity; ack error no longer ignored | `db5d5b7` |
| PROD-C1 | CRIT | Committed-but-undelivered mint left an unrecoverable bearer | Idempotent re-disclosure for the same signed attempt *(reworked in R3/R5 — see below)* | `db5d5b7` |
| ADV-M1 | MED | Social-verify capacity ignored live reservations (over-counted) | Subtract live reservations, clamp ≥0 | `3af18ca` |
| PROD-H1 | HIGH | Advisory validation didn't reserve a scarce invite during a 10–30 min install | Preflight `POST /v1/referrals/reserve` + installer claims reservation, threaded to mint | `660aa81`, `bd8cb2b` |
| PROD-H3 | HIGH | One transient X post permanently tripled invite capacity | Deferred, dwell-gated (30 min), author-bound bonus via promotion reconciler | `21e4c8b` |
| PROD-H2 | HIGH | Expired/revoked join links → unexplained raw 404 | Branded "no longer available" pages + request-access CTA | `cad87af` |
| PROD-H4 | HIGH | Revoked provider issuer had no replacement path | Audited `replace-referral-issuer` CLI | `4d8841f` |
| PROD-H5 | HIGH | `create-seed-referral` silently upserted live campaigns | Insert-only + audited `adjust-seed-referral` (dry-run/apply/actor/reason) | `4d8841f` |
| PROD-H7 | HIGH | Revocation/expiry retroactively broke bootstrap recovery | Custody-proven recovery ignores later issuer lifecycle for an already-bound provider | `f1ed431` |
| PROD-M1..M6, L1 | MED/LOW | invite-URL-vs-code paste, lost referral reason, policy-discovery false-gate, hardcoded bonus copy, disabled-flag dead links, no request-access path, "reopen X post" label | Various client/route/copy fixes | R1–R5 commits |
| ADV-M2 | MED | Concurrent Share-on-X double-submit left a stale challenge | In-flight/generation guard | `5bac171` |
| PROD-M5 | MED | Disabling both flags dead-linked circulated invites | `/j/` route permanently mounted, open-beta fallback | `bd8cb2b` |

### Round 2 → Round 3 (regressions/residuals in R1 fixes)

| ID | Sev | Finding | Fix | Commit |
|---|---|---|---|---|
| R2 C1 | CRIT | R1 recovery re-ran identity prepare with the used nonce + server `now` → compensation deleted the rotated token | Recovery reworked to not re-prepare/compensate | `f1ed431` (further fixed R5) |
| R2 H2 | HIGH | WS/CLI bootstrap never consumed the installer reservation → cap-one invite blocked its own mint | `referral_reservation_id` on `AuthRequest`, bound into the verified transcript, consumed atomically at `MintBootstrapToken` | `11f24e8` |
| R2 ADV-H1 | HIGH | Rollback relaunched `--token-fd 0` with empty stdin (bearer lost) | Token-FD processes detected, not relaunched with DEVNULL; restart handed to Malibu app-managed | `fa706ff` |
| R2 H3 | HIGH | Reserve endpoint allowed indefinite capacity denial | Absolute reservation lifetime cap *(hardened again in R5 — lineage)* | `fa706ff` |
| R2 M4/M6 | MED | replace-issuer hardcoded capacity 1; revoke had no audit | `--base-uses` required; audited revoke; per-subcommand help | `3af18ca` |
| R2 L1 | LOW | Durable attempt table had no retention caller | Documented operator-privileged prune (revoked from runtime role) | `6e6f46b` |

### Round 4 → Round 5 (deeper interactions; several were regressions from my own R3 fixes)

| ID | Sev | Finding | Fix | Commit |
|---|---|---|---|---|
| R4 ADV-H1 | HIGH | CLI sent `referral_reservation_id` only in the proof frame → transcript-equality rejected every reservation bootstrap | Send it in the initial frame too | `99b6eb0` |
| R4 ADV-H2 / PROD-C1 | CRIT | `MintBootstrapToken` consumed the reservation unconditionally → lost-response retry found it gone → `ErrReferralExhausted` | Consume only for a *new* redemption; `redeemReferralTx` is idempotent for the existing binding so recovery proceeds. Test covers reserve→mint→lost→retry | `99b6eb0` |
| R4 C1a | CRIT | Recovery mutated SQLite (revoked token, replaced saga) **before** proving durable commitment; keyed the match on unsigned `source_ip` (identical signed replay from a different NAT missed → destroyed the credential); saga replacement was provider-scoped not attempt-bound | Prove `ProviderRegistrationPrepared` **first**; key match on replay-stable **signed** fields only `(provider_id, nonce, ts_utc)`; attempt-bound compare-and-swap saga replacement, all in one SQLite tx. HTTP-level cross-source-IP replay test added | `0d8a38e` |
| R4 ADV-H3 / PROD-H3 | HIGH | Lifetime cap defeated by delete-recreate (new `created_at`); expiry misreported as `now+ttl` | Reservation **lineage** anchor surviving natural expiry (60-min cap) + post-expiry cooldown; return the **stored** expiry; distinct `reservation_expired` reason | `97e75d2` |
| R4 PROD-H1 | HIGH | Request-access CTA pointed at `malibu.tech/request-access` (production 404) | Explicit validated `referrals.request_access_url` config; CTA hidden when unset; no dead default | `6fcfe98` |
| R4 PROD-H4 / ADV-M3 + M2(prod) | HIGH/MED | replace-issuer verified against its own ad-hoc flags (circular); dropped earned/pending X bonus | CLI loads the **deployed** policy via `--config`, rejects mismatch, validates under deployed policy, dry-run default; successor carries earned bonus + rebinds pending review | `6e61a5c` |
| R4 PROD-H2 | HIGH | "Recover Existing" couldn't recover a missing bearer → identity-import loop | Missing-bearer recovery made non-looping; routes to Start-New when the protocol can't recover without the bearer | `fcef7cc` |
| R4 PROD-H5 (client) | HIGH | Lost-response recovery only worked for an immediate replay | Durable persist + replay of the exact signed attempt across restart (`PendingRegisterAttemptStore`) | `0dfd933` |
| R4 M1 (adv) | MED | `HandleJoin` returned raw 404 on operational errors | Branded retryable **503** for operational errors; 404 only for `ErrReferralInvalid` | `60f8db3` |
| R4 M2 (adv) | MED | X 403 always classified terminal | Body-classified: terminal only on proven deletion/protection; ambiguous 403 = transient | `60f8db3` |
| R4 M3/M4/L2/M6 (prod) | MED/LOW | X-review UI invisible/permanent; 0→2 bonus copy; Start-New no confirm/undo | Legible pending/eligible/retrying + failed-with-reason UI; honest bonus copy; Start-New confirm dialog + session undo | `721f32c`, `fcef7cc` |
| R4 M5 (prod) | MED | Seed revoke preview hid blast radius | Preview shows redemptions/live-reservations/remaining; `--apply` requires a confirmed snapshot | `4b18304` |
| L1 (spec) | LOW | SPEC-034 drifted from implementation | SPEC-034 → v0.3.0 (canonical enums, lineage/expiry, recovery preconditions, audited ops) | `cd8b660` |

---

## 4. Validation

Run on the combined tree at this checkpoint (both agents' commits interleaved):

- **Go** (`phase4-coordinator`): `go build ./...` ✅ · `go vet ./...` ✅ · `go test ./... -count=1` ✅ (0 failures) ·
  `go test -race ./internal/auth ./internal/referralapi ./internal/onboarding ./internal/ws` ✅
- **Swift CLI** (`phase3-binary`): `swift build` ✅ · `swift test` ✅ (1182 tests, 8 skipped, 0 failures)
- **Malibu app** (`phase3-binary/app`, xcodebuild): ✅ 164 tests, 0 failures (incl. 13 new)
- **Installer**: `bash -n install.sh` ✅ · `dist/test/*.test.sh` ✅ (12 passed)

PG-dependent tests (`store_pg_attempt_integration_test.go`) are `//go:build integration` and run in
the coordinator's Postgres CI lane, not the default `go test ./...`.

---

## 5. Recommendation: split PR #570

At **61 files / +11k lines** spanning Go coordinator, Swift app, CLI, installer, SQL migrations,
and spec — touching money-path minting, auth, and crash recovery — this PR is too large to review or
land safely as one unit. The five audit rounds show *why*: reviewers could not hold the whole surface
at once, and the riskiest subsystems (recovery, reservation) repeatedly hid defects behind the volume.

Split along the natural subsystem fault lines below. **PR-A is the actual requirement of Malibu
issue #46; the rest are additive and flag-gated.** Recommended landing order top-to-bottom.

### PR-A — Referral gate core *(foundational, lowest risk — land first)*
The credential-authority gate itself: HMAC codes, issuers, redemptions, the enforcement boundary
across the three first-mint paths (v1/v2 tokenless, credential-bootstrap, App-track register),
`POST /v1/referrals/validate`, config block, issuer/redemption migrations.
- `internal/auth/referrals.go` (codes/issuers/redemptions/validate), `internal/auth/tokens.go`
  (referral gate on the mint paths, minus recovery/reservation), `internal/config/config.go`
  (referrals block), `internal/ws/{server,messages,admission}.go` (referral on WS mint, minus
  reservation), `cmd/coordinator/main.go` wiring, nginx route for `/validate`.
- **Why first:** everything else depends on it; it is the feature issue #46 asks for; it is the most
  reviewable in isolation.

### PR-B — Join landing + operator CLI *(low risk, operator-facing)*
`/j/<code>` route + branded pages (exhausted/expired/revoked/open-beta, request-access URL),
seed/adjust/revoke/**replace** CLI + `referral_admin_audit`.
- `internal/referralapi/handler.go` (join/pages), `cmd/coordinator-cli/main.go`, audit migration,
  `dist/coordinator.yaml` (`request_access_url`). Depends on PR-A.

### PR-C — Advocacy / X social bonus *(isolatable, flag-gated `enable_social_invite_bonus`)*
Post-serving invites, dwell-gated author-bound X verification, promotion reconciler, dashboard
advocacy UI + status API.
- `internal/referralapi/{xapi,serving}.go`, social tables, promotion reconciler in
  `cmd/coordinator/main.go`, `app/.../Dashboard/{ReferralInviteController,DashboardWindow}.swift`.
  Depends on PR-A.

### PR-D — App-track crash-safe minting + lost-response recovery ⚠️ *(HIGHEST RISK — isolate)*
Pending-mint saga, durable `provider_register_attempts` marker, crash reconciler, and committed-attempt
recovery (the C1/C1a/C1b/ADV-H2/ADV-H4 subsystem).
- `internal/onboarding/{apptrack,store_pg}.go`, migration 018, recovery in `internal/auth/tokens.go`,
  `RegisterClient.swift` durable persist/replay.
- **Why isolate:** generated a CRITICAL in **every** audit round. Deserves a dedicated PR with
  concentrated adversarial review (esp. an HTTP-level lost-response + cross-source-IP + concurrent-
  attempt matrix). **Consider whether the auto-recovery is worth its risk for pre-beta at all** — the
  triggering finding (PROD-C1) is a rare lost-response edge case that is operator-recoverable; a
  simpler "detect committed, return a clear await-reconciliation/use-bearer response" may be safer
  than automatic token rotation.

### PR-E — Preflight capacity reservation ⚠️ *(MEDIUM-HIGH RISK — isolate or reconsider)*
Reserve endpoint, reservations table + lineage/cooldown, installer preflight, WS/App consumption.
- `ReserveReferralCapacity` + reservation tables in `internal/auth/*.go`, `HandleReserve`,
  installer preflight in `install.sh`, `CoordinatorClient.swift` forwarding.
- **Why isolate:** repeat HIGH findings (indefinite-hold DoS on public cap-one codes). For an
  unauthenticated public code, a reservation is inherently a first-come hold; full closure needs
  identity-bound reservations. **Reconsider whether advisory validation (the original behavior)
  suffices for pre-beta**, deferring authoritative reservation until identity-proof is wired.

### PR-F — Existing-provider repair / missing-bearer / client transport
MalibuAgent pipe-bearer transport, install.sh recovery redaction + token-fd handling, onboarding
states, missing-bearer routing, Start-New confirm/undo.
- `app/.../Agent/{MalibuAgent,CLIChildProcess}.swift`, `app/.../Onboarding/*`, `app/.../System/*`,
  `install.sh`, `MacProviderCLI.swift`. Largely independent of the referral tables (depends on PR-A
  only where onboarding surfaces referral reasons).

**Minimal shippable pre-beta = PR-A + PR-B + PR-C** (gate + operator tooling + advocacy), all behind
`require_for_registration` / `enable_social_invite_bonus` (default off). PR-D and PR-E carry the
residual risk and can land later or be simplified.

---

## 6. Convergence status & residuals

- **Not yet re-audited:** the round-5 fixes (incl. the C1a recovery redesign and H3 lineage) are
  implemented and pass all tests, but a **round-6** adversarial + product pass has not run. Do not
  claim a verified `0 C/H/M` until it does. Prior rounds show fixes to this subsystem sometimes
  introduced new criticals — a re-audit is warranted, especially on PR-D/PR-E scope.
- **PROD-H5 server half:** the client persists+replays the exact signed attempt, but full closure
  needs the coordinator to exempt committed-attempt recovery from ordinary ±60s skew / 5-min cooldown
  (client half shipped in `0dfd933`; server exemption is a follow-up).
- **PROD-H2 scope decision:** a true server-side missing-bearer recovery protocol for a *confirmed*
  identity was not built; the flow is made non-looping and routed to Start-New. If seamless recovery
  is desired, a receipt-key/identity-proof recovery protocol is a follow-up (fits PR-D).
- **Migration 018** was edited in place (PK now excludes `source_ip`). Safe **only** because 018 was
  introduced on this unmerged branch and never deployed. If any part ships before the rest, use an
  ALTER-based `019` instead.
- **Cross-lane status fields** (`review_last_attempt_at`, `review_next_attempt_at`,
  `review_failure_reason`, `review_retry_allowed`, `configured_bonus_uses`, `reservation_expired`)
  are decoded defensively on the Swift side; keep the Go field names and Swift `CodingKeys` in sync
  when splitting.
- **LOW residuals carried:** operator-scheduled retention of `provider_register_attempts`
  (prune revoked from the runtime role by design); `beta/DECISION_CRITERIA.md` intentionally not
  touched (decision-log entry should be added when the split lands, reflecting shipped state).
