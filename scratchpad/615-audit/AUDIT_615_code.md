# Partial #615 CODE Audit — Exception Enforcement Scaffolding

## Verdict

**REQUEST CHANGES — required gate is not met.**

Audited tip: `f3d71718a3032e045130684c815f54c3c5a16dc3` on
`fix/615-exception-enforcement`.

| Severity | Count |
| --- | ---: |
| CRITICAL | 0 |
| HIGH | 3 |
| MEDIUM | 7 |
| LOW | 3 |
| INFO | 1 |

Required merge gate: **0 CRITICAL / 0 HIGH / 0 MEDIUM**. Actual result:
**0 / 3 / 7 — FAIL**.

Architectural status: **BLOCK**. The happy paths execute, but the implementation
has release/deploy bypasses and false-pass surfaces in the three core promises:
stable-promotion blocking, durable anti-resurrection, and secret-free reporting.

## Scope and evidence

Reviewed:

- `scripts/production_exceptions.py`
- `scripts/check-production-exceptions.py`
- `scripts/test-production-exceptions.sh`
- `scripts/tests/test_production_exceptions.py`
- `phase4-coordinator/dist/check-deploy-config.sh`
- `phase4-coordinator/dist/deploy-pearl-vps.sh`
- `phase5-gateway/dist/deploy-pearl-vps.sh`
- `.github/workflows/promote-acceptance-candidate.yml`
- `scripts/test-acceptance-promotion.sh`
- `Makefile`, `OPS.md`, the register schema/register/tombstones, and
  `ops/runbooks/production-exception-register.md`

Fresh checks run from the requested worktree:

- `git diff --check origin/main...HEAD` — PASS
- `bash scripts/test-production-exceptions.sh` — PASS, 14 unit tests
- `bash phase4-coordinator/dist/test/check_deploy_config_test.sh` — PASS,
  61 assertions
- `bash scripts/test-acceptance-promotion.sh` — PASS
- `python3 -m unittest -v scripts.tests.test_production_exceptions` — PASS,
  14 tests

The passing suite does not exercise the false-pass cases below. Adversarial
in-memory fixtures reproduced each validator/report issue without modifying the
worktree.

## HIGH findings

### H1 — `blocks_stable_promotion=true` is not enforced by the promotion gate

Evidence:

- `scripts/production_exceptions.py:276-281` only type-checks the field.
- `scripts/production_exceptions.py:581-593` upgrades only
  `status_expired`, `unbounded_active`, and `expiry_soon`.
- `ops/runbooks/production-exception-register.md:43-46` tells operators to set
  the field when an active exception makes #615 or rollout evidence incomplete.
- The workflow invokes this incomplete policy at
  `.github/workflows/promote-acceptance-candidate.yml:54-60`.

Reproduction: a future-bounded active row and a planned row, each with
`blocks_stable_promotion=true`, both produced zero promote errors. Once the
current expired/unbounded rows are cleaned up, either row can coexist with a
public stable promotion even though the register explicitly marks it blocking.
The existing promotion test at
`scripts/tests/test_production_exceptions.py:133-148` checks only expired and
unbounded rows; its fixture defaults the blocking bit to true but never asserts
that the bit itself is enforced.

Required fix: derive a promotion-blocking finding from
`blocks_stable_promotion=true` for every status intended to block, document the
exact status semantics, and add bounded-active/planned true/false CLI tests.

### H2 — Removed rows are not required to have tombstones, defeating durable anti-resurrection

Evidence:

- The runbook requires a tombstone when a row becomes removed at
  `ops/runbooks/production-exception-register.md:26-33`.
- `scripts/production_exceptions.py:370-385` checks only the direction
  "tombstone exists -> current row must remain removed".
- Ordinary deploy/promote gates call validation without `previous_doc` at
  `scripts/production_exceptions.py:653-675`.

Reproduction: a `status=removed` row with an empty tombstone register validated
with zero errors. Changing that same ID back to `status=active` with the
tombstone register still empty also validated with zero resurrection errors.
After a removed row is deleted from the current register, no durable history
remains for `sync-check` to consult.

Required fix: require every removed register ID to exist in a valid tombstone
set before validate/deploy/promote can pass, and cover both missing-tombstone
removal and later ordinary-gate resurrection.

### H3 — The report can emit secret material while asserting that secrets were redacted

Evidence:

- `scripts/production_exceptions.py:71-75` matches only a narrow set of inline
  patterns and does not redact complete PEM blocks.
- `scripts/production_exceptions.py:526-540` emits `owner` without any redaction
  and redacts only four free-text fields.
- `scripts/production_exceptions.py:560-564` unconditionally sets
  `secrets_redacted=true` and claims that HMAC secrets, referral codes, and
  private keys are absent.
- The runbook makes the same no-secrets claim at
  `ops/runbooks/production-exception-register.md:71-81`.

Reproductions:

- `owner="Bearer FAKEOWNERSECRETSENTINEL"` was emitted verbatim.
- A raw 64-hex HMAC-like sentinel in `policy_delta` was emitted verbatim.
- Private-key bodies are not consumed by the header-only regex, and generic
  PKCS#8 `BEGIN PRIVATE KEY` is not covered by the `[A-Z ]+PRIVATE KEY` pattern
  as written.
- In all cases the report still returned `secrets_redacted=true`.

Required fix: sanitize every emitted string, redact entire PEM blocks, define
and test conservative handling for opaque credential-like values, and never
emit an unconditional redaction-success assertion that was not established.

## MEDIUM findings

### M1 — `sync-check` discards tombstone validation errors and accepts malformed inputs

`simulate_config_sync_restore()` calls `validate_tombstones(tombstones)` at
`scripts/production_exceptions.py:483`, discards its `ValidationResult`, then
creates a fresh result at line 484. It also never structurally validates the
current or stale register before merging them.

Reproduction: a malformed tombstone document with a wrong schema/environment
and non-array `tombstones`, a current register that no longer contains the old
ID, and a stale active row returned zero errors. The CLI would print
`sync-check: OK` at `scripts/production_exceptions.py:694-712`.

Fix: create one result first, retain all tombstone/register validation errors,
abort comparison on malformed inputs, and add malformed-file CLI tests.

### M2 — The stdlib validator accepts documents rejected by the committed schema

The runbook claims dependency-free structural validation is always on at
`ops/runbooks/production-exception-register.md:35-41,63-65`, and the deploy
section says malformed registers hard-fail. However:

- The schema requires `$schema` and forbids unknown root/row/question fields at
  `ops/exceptions/production-exceptions.schema.json:5-15,73-76,199-202`.
- Evidence items and open-question strings are constrained at
  `ops/exceptions/production-exceptions.schema.json:69-71,172-176,214-230`.
- `scripts/production_exceptions.py:201-390` does not enforce those rules and
  regex-checks `updated_at`/`created_at` without verifying real calendar values.

Reproduction: a document with unknown root/entry/question fields, non-string or
empty evidence values, empty question text, non-string evidence target, and
semantic-invalid timestamp shapes produced zero stdlib validation errors.

Fix: implement schema parity in the stdlib validator or make real schema
validation a CI/runtime dependency; narrow the documentation only if deliberate
non-parity remains.

### M3 — Placeholder-owner rejection is trivial to bypass

`_owner_ok()` at `scripts/production_exceptions.py:164-168` rejects only exact
case-insensitive values from the list at lines 57-69. Values such as
`TBD - assign ops`, `unknown owner`, and `TODO/team` all validated with zero
owner errors, contradicting the ownerless/placeholder hard-fail claim in
`ops/runbooks/production-exception-register.md:93-99`.

Fix: reject placeholder tokens using carefully bounded prefix/word rules and add
variant tests, while retaining tests for legitimate owner names.

### M4 — Gateway `SKIP_C2_CHECK=1` bypasses the exception gate too

The exception gate lives only in
`phase4-coordinator/dist/check-deploy-config.sh:345-360`. Coordinator deploys
with the C2 opt-out still call that shared script at
`phase4-coordinator/dist/deploy-pearl-vps.sh:638-642`, so the exception check
runs. Gateway deploys take a different branch:
`phase5-gateway/dist/deploy-pearl-vps.sh:221-223` skips the shared script
entirely. An option documented as a C2-only escape therefore also bypasses
malformed-register, clock-expired-active, and resurrection enforcement.

Fix: separate the exception gate from the C2 check or always invoke the shared
script in coordinator-only mode on the gateway opt-out branch. Add a gateway
deploy-path assertion.

### M5 — The documented `sync-check` command does not parse

The runbook places `--tombstones` after the `sync-check` subcommand at
`ops/runbooks/production-exception-register.md:142-147`. Argparse defines that
option only on the root parser at `scripts/production_exceptions.py:719-728`;
the sync subparser at lines 757-771 defines only `--current` and `--stale`.

Fresh reproduction exited 2 with:

```text
error: unrecognized arguments: --tombstones ops/exceptions/removed-exception-tombstones.json
```

Moving `--tombstones` before `sync-check` succeeds. Fix the runbook and/or make
the option valid on the subparser, then cover the documented CLI form.

### M6 — Promotion evaluates the dispatch snapshot, not current main authority

The workflow checks out `${{ github.sha }}` at
`.github/workflows/promote-acceptance-candidate.yml:47-52` and runs the gate
against that copy at lines 54-60. It fetches current `origin/main` only much
later at lines 306-316 and proves candidate/control ancestry, not that the
exception register and tombstones being gated equal current main.

The protected environment limits deployment to main, which narrows this risk,
but a rerun or already-dispatched main workflow can evaluate a stale main
snapshot after the authoritative register changes. An ancestor check continues
to pass while current main may contain a newly expired, unbounded, or tombstoned
row.

Fix: bind the gate to freshly fetched current main (or require the workflow SHA
to equal current main immediately before release mutation) and add a stale-main
negative test.

### M7 — Promote/enforced mode hard-fails `expiry_soon` beyond the stated gate contract

The shared audit contract and CLI help state that promote fails closed on
expired and unbounded-active rows. The runbook's stable-promotion list at
`ops/runbooks/production-exception-register.md:123-133` also omits approaching
expiry. Nevertheless `scripts/production_exceptions.py:586-592` upgrades
`expiry_soon` to an error for both promote and enforced deploy.

Reproduction: an otherwise valid active row expiring one hour after the test
clock produced a promote error solely for `expiry_soon`.

Fix: either remove `expiry_soon` from promote upgrades or explicitly change the
contract, CLI help, workflow comments, runbook stable-promotion list, and tests
to establish that stricter availability tradeoff.

## LOW findings

### L1 — Wiring tests prove text presence, not execution semantics

`scripts/test-production-exceptions.sh:55-66` and the added assertion in
`scripts/test-acceptance-promotion.sh:27-40` search for literal command text.
A commented-out command or unreachable block can satisfy these checks. The
deploy integration suite runs the shared script only against the committed
default-pass inventory, so removing the exception call would not cause a
specific negative assertion to fail.

Add behavioral fixtures that make the exception gate fail through each deploy
and promote surface, and assert ordering before release mutation.

### L2 — Report clock state ignores the caller's `--alert-hours`

Validation receives `args.alert_hours` at
`scripts/production_exceptions.py:629-638`, but `build_health_report()` uses the
constant `DEFAULT_ALERT_HOURS` at lines 504-523. A report generated with a
non-default alert window can therefore disagree with its own embedded validation
warnings. Also, a future expiry outside the window is labeled `within_window`,
which reads opposite to the comparison.

Pass the selected window into report generation and use an unambiguous state
name such as `outside_alert_window`.

### L3 — One stale restore can emit duplicate resurrection findings

`check_anti_resurrection()` can emit one tombstone and one previous-removed
finding at `scripts/production_exceptions.py:451-462`, and
`simulate_config_sync_restore()` repeats a tombstone check at lines 487-500.
A single restored ID can therefore produce multiple identical-code errors,
inflating counts and operator noise.

Deduplicate by `(code, exception_id)` or remove the redundant second pass after
validation errors are correctly retained.

## INFO

### I1 — Current happy paths and CI attachment are present

`make test-dist` includes `scripts/test-production-exceptions.sh`, and CI invokes
`make test-dist` in both the coordinator and isolated dist-tooling jobs. Wrapper
imports and repository-root inference worked from the requested worktree. The
fresh passing tests listed above establish that current checked-in paths execute;
they do not clear the uncovered false-pass cases.

## Required remediation before re-audit

1. Enforce the explicit promotion-blocking bit and tombstone completeness.
2. Make report redaction truthful and comprehensive for every emitted string.
3. Fail `sync-check` on malformed inputs and add end-to-end CLI coverage.
4. Close the gateway C2-opt-out bypass and bind promotion to current main.
5. Bring stdlib validation into schema parity, including placeholder-owner and
   semantic timestamp tests.
6. Resolve/document `expiry_soon` promotion policy and replace text-only wiring
   assertions with negative behavioral tests.

