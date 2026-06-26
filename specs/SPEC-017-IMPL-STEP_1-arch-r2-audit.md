# SPEC-017 IMPL Step 1 architecture audit — round 2

Audit target: `impl/spec-017-step-1` Step 1 implementation diff (`origin/main...HEAD`, HEAD `0b3e87b`). Round-1 architecture findings are closed in the current diff: coordinator boot no longer runs migrations through `stats_rollup`, startup smoke now checks role identity and deny probes, and CI now has a post-install AC-16 fixture assertion step.

## A. Schema correctness — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings. The migrations still encode the locked §9.1 / §6.1 / §6.5 / §5.4.1 schema shape: no `stats_rollup_state`, no removed leaderboard bucket columns, no `partner_keys.rate_limit_burst`, seven split health components, no stored health `status`, `blocked_from_partner_projection` present, `provider_visibility_audit.id` and `partner_keys.id` backed by `BIGSERIAL`, `provider_rewards_ledger` present, and `stats_rewards_populated` pins the rewards-populated storage choice.

## B. Postgres role inventory — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings. The SPEC-017-owned grant migration keeps `stats_reader`, `stats_rollup`, and `provider_portal` inside the locked §7.2 inventory, skips `partner_keys_writer` by default, and does not grant TRUNCATE / ALTER / DROP. The IMPL-authored OLTP grant list matches the current local dependency specs: SPEC-002 v1.4.0 `provider_tokens` and SPEC-005 v0.3 `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs`.

## C. DB-connection mechanics — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings. The Step 1 wiring opens one pool per active runtime role, conditionally opens `partner_keys_writer` only behind `last_used_at_updates_enabled`, does not instantiate the CLI admin DSN, and fails closed when required DSNs or role-boundary smoke checks fail. The `/v1/stats/*` subtree is still not registered in Step 1.

## D. Package layout + import-graph lint — 0 CRITICAL / 1 HIGH / 0 MEDIUM

### **[HIGH] AC-16 lint config is not executable under the pinned golangci-lint version**

**Where:** `phase4-coordinator/.golangci.yml:28`; `.github/workflows/ci.yml:155`

**Evidence:**

```yaml
linters:
  default: none
  enable:
    - depguard
    - forbidigo
...
forbidigo:
  forbid:
    - pattern: 'os\.Exit'
```

and the CI job runs that target before the fixture assertion:

```yaml
- name: make lint-coordinator
  run: make lint-coordinator
```

With the pinned `golangci-lint v1.62.2`, the target is not clean:

```text
internal/stats/stats.go:34:10: use of `bool` forbidden ... (forbidigo)
internal/stats/store/doc.go:14:9: use of `store` forbidden ... (forbidigo)
internal/tier2/pillar_b.go:418:9: Error return value of `w.Write` is not checked (errcheck)
```

**Why it matters:** BUILD §D.2 / §D.3 and AC-16 require a CI-enforced import graph plus the `os.Exit` / `log.Fatal` ban. As written, the lint gate is structurally unusable: v1.62 does not disable the default linter set via `default: none`, and forbidigo's structured pattern key is `p`, not `pattern`, so the rule degenerates into broad false positives across ordinary identifiers. The CI job fails before it can provide the Step 1 AC-16 boundary guarantee.

**Fix:** Rewrite `.golangci.yml` using v1.62 syntax: `linters.disable-all: true`, enable only `depguard` and `forbidigo`, and express forbidigo entries as strings or `p:` maps, e.g. `- p: '^os\.Exit$'`, `- p: '^log\.Fatal$'`, `- p: '^log\.Fatalf$'`. Then rerun `make lint-coordinator` and the targeted `TestAC16ForbiddenImportFails|TestForbidigoOSExitRule` assertion with the pinned binary.

## E. Test coverage — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No separate architecture findings beyond the AC-16 lint-config blocker in category D. The Step 1 test inventory includes AC-9, AC-10 commit and rollback subcases, AC-19 no-row left-join default, and AC-20 operator-exact prohibition in the PR CI integration job.

## F. Cross-step seams to Step 2/3/4 — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings. Step 1 declares the expected config seams for rollout, CORS, trusted proxies, and optional partner-key last-used updates without adding concrete handlers, rollup tick SQL, CLI subcommands, nginx config, or unexpected production dependencies.

## Verdict

```text
Verdict: NEEDS FIX
CRITICAL: 0
HIGH: 1
MEDIUM: 0
LOW: 0
INFO: 0
```
