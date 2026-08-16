## Verdict

REQUEST CHANGES

Blocking count: 0 CRITICAL / 1 HIGH / 0 MEDIUM / 1 LOW / 1 INFO

## Required reading + commands run

Required reading:

- `CLAUDE.md`
- `specs/SPEC-017-network-stats-api.md`
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md`
- `specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md`
- `specs/SPEC-017-IMPL-STEP_4-convergence.md`
- `specs/SPEC-017-IMPL-STEP_4C-r5-convergence.md`
- `OPS.md`
- `docs/network-stats-api/CHANGELOG.md`
- SPEC-017 migrations under `phase4-coordinator/internal/stats/migrations/`
- Stats runtime code under `phase4-coordinator/internal/stats/`
- Coordinator entrypoint, CLI, nginx, and tests under `phase4-coordinator/cmd/coordinator/` and `phase4-coordinator/dist/`

Commands run:

- `pwd && git status -sb && git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD && git merge-base HEAD main`
- `git diff --name-only $(git merge-base HEAD main)..HEAD`
- `sed -n '1,260p' CLAUDE.md`
- `nl -ba specs/SPEC-017-network-stats-api.md | sed -n '1128,1210p;1510,1552p;1590,1760p;2288,2388p'`
- `nl -ba specs/BUILD_SPEC_017_IMPL_PROMPT.md | sed -n '18,28p;520,620p;700,760p;900,1020p'`
- `nl -ba OPS.md | sed -n '617,786p'`
- `nl -ba docs/network-stats-api/CHANGELOG.md | sed -n '1,90p'`
- `rg -n "6\\.6\\.2|disclosure|sign-off|signoff|exact_earnings|earnings_usd|partner_key|Authorization|stats_request|prometheus|DefaultRegisterer|burst=59|nodelay|provider_portal|partner_keys_admin_dsn|--config|CHANGELOG|AC-17|AC-8" specs OPS.md docs phase4-coordinator`
- `nl -ba phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql | sed -n '1,260p'`
- `nl -ba phase4-coordinator/internal/stats/migrations/002_bootstrap_health_and_rewards.up.sql | sed -n '1,240p'`
- `nl -ba phase4-coordinator/internal/stats/migrations/003_roles.up.sql | sed -n '1,220p'`
- `nl -ba phase4-coordinator/internal/stats/migrations/004_grants.up.sql | sed -n '1,220p'`
- `nl -ba phase4-coordinator/internal/stats/migrations/005_oltp_source_grants.up.sql | sed -n '1,220p'`
- `nl -ba phase4-coordinator/internal/stats/stats.go | sed -n '1,220p'`
- `nl -ba phase4-coordinator/cmd/coordinator/main.go | sed -n '500,570p'`
- `nl -ba phase4-coordinator/internal/stats/handlers.go | sed -n '1,220p;400,520p;760,860p'`
- `nl -ba phase4-coordinator/internal/stats/auth.go | sed -n '1,220p'`
- `nl -ba phase4-coordinator/internal/stats/middleware.go | sed -n '1,260p'`
- `nl -ba phase4-coordinator/internal/stats/metrics/metrics.go | sed -n '1,260p'`
- `nl -ba phase4-coordinator/internal/stats/rollup/leaderboard.go | sed -n '1,260p'`
- `nl -ba phase4-coordinator/internal/stats/rollup/rebuild.go | sed -n '1,260p'`
- `nl -ba phase4-coordinator/internal/stats/rollup/runner.go | sed -n '1,260p'`
- `nl -ba phase4-coordinator/cmd/coordinator/partnerkeys.go | sed -n '130,380p;480,550p'`
- `nl -ba phase4-coordinator/cmd/coordinator/admin_dsn_parse.go | sed -n '1,220p'`
- `nl -ba phase4-coordinator/cmd/coordinator/visibility.go | sed -n '1,260p'`
- `nl -ba phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go | sed -n '240,380p;540,660p;874,950p'`
- `nl -ba phase4-coordinator/dist/nginx/stats-shared.conf | sed -n '1,120p'`
- `nl -ba phase4-coordinator/dist/nginx/nginx-stats.malibu.tech.conf | sed -n '100,190p'`
- `nl -ba phase4-coordinator/dist/nginx/nginx-coordinator.malibu.tech.conf | sed -n '200,280p'`
- `nl -ba phase4-coordinator/dist/test/check_nginx_stats_test.sh | sed -n '180,330p'`
- `printf '%s\n' AC-{1..22} | shuf -n 5` failed locally because `shuf` is not installed.
- `python3 - <<'PY'
import random
acs=[f'AC-{i}' for i in range(1,23)]
r=random.Random(173264606)
print('\n'.join(r.sample(acs,5)))
PY`
- `go test ./internal/stats/...`
- `go test ./cmd/coordinator -run 'TestDispatch|TestAdminDSN|TestPartner|TestVisibility|TestAC17|TestIssue|TestStep4C'`
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh`

Validation evidence:

- Branch was `impl/spec-017-step-1`, HEAD was `264a606`, merge base with `main` was `e816dffb82cb08a9c8010a467498f9e6a1ac09f9`.
- `go test ./internal/stats/...` passed.
- `go test ./cmd/coordinator -run 'TestDispatch|TestAdminDSN|TestPartner|TestVisibility|TestAC17|TestIssue|TestStep4C'` passed.
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` passed `nginx -t` but skipped the request-path assertions because the upstream mock failed to start.
- Random AC sample using seed `173264606`: AC-2, AC-4, AC-5, AC-7, AC-12.

## Findings

### CRITICAL

None.

### HIGH

1. AC-17 is not implemented as written: `partner-keys issue` prints metadata to stdout before the raw token.

Evidence:

- `specs/SPEC-017-network-stats-api.md:2347` says AC-17 invokes `coordinator partner-keys issue --label X`.
- `specs/SPEC-017-network-stats-api.md:2349` says the command "Prints exactly one 47-character token beginning `mpk_` to stdout".
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md:549` says "Print raw token to stdout exactly ONCE."
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md:559` repeats the AC-17 stdout contract.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:287` prints a metadata line to stdout with `id`, `label`, `prefix`, `created_by`, `rotated_from_id`, and `created_at`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:347` then prints the raw token to stdout.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:250` recasts the contract as "metadata first, then a single line with the raw token", which is not the SPEC or build prompt wording.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:248` through `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:257` implement `extractRawTokenLine`, so the AC-17 tests only verify that some stdout line is a token.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:270` through `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:304` and `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:309` through `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:358` pass while permitting extra stdout.
- `specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md:47` marks AC-17 PASS, but the cited tests do not prove the exact stdout contract.

Risk:

- This is a silent SPEC AC failure. A production operator or automation that captures stdout as the newly issued secret receives metadata plus secret instead of exactly one token. That can break secret-ingestion scripts, cause accidental persistence of non-secret metadata in secret stores, or train downstream tooling to parse around an output shape the locked SPEC does not allow. The current tests make the failure look green.

Fix direction:

- Make stdout token-only for `partner-keys issue`: either move the metadata line to stderr, suppress it, or put it behind an explicit non-default verbose flag.
- Preserve `--token-out` semantics so raw token material is written only to the requested file when that flag is used.
- Replace `extractRawTokenLine` assertions with a whole-stdout assertion such as `^mpk_[A-Za-z0-9_-]{43}\n?$`, plus a negative assertion that stdout contains no `id=`, `label=`, `prefix=`, or other metadata.

### MEDIUM

None.

### LOW

1. The `provider_portal` grants migration still describes a now-resolved SPEC deviation.

Evidence:

- `specs/SPEC-017-network-stats-api.md:1713` through `specs/SPEC-017-network-stats-api.md:1724` explicitly bless the v0.1.8 erratum granting `provider_portal` `SELECT`, `INSERT`, and `UPDATE` on `stats.provider_visibility`.
- `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:86` through `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:118` still describe the same grant as an "IMPL-authored deviation from locked SPEC §7.2.3" and a "SPEC v0.2 candidate".

Risk:

- This does not change database behavior, but it misleads future operators and auditors into relitigating a Round-1 issue that the Round-2 SPEC erratum already resolved.

Fix direction:

- Update the migration comments to say the `SELECT` grant is required by the SPEC-017 v0.1.8 §7.2.3 erratum and is no longer a candidate deviation.

### INFO

1. Local nginx validation was only partial in this audit environment.

Evidence:

- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` reported `ok: nginx -t passes against composed config`.
- The same run then reported `SKIP: upstream mock failed to start`, so the local request-path checks in that script did not execute.
- Static inspection still found `burst=59 nodelay` on all three network stats endpoints in both nginx configs, auth-aware cache bypass/no-cache, and redacted access log format in the included shared config.

Risk:

- Not actionable against production by itself, but this audit cannot claim it personally re-executed the full local nginx request-path harness.

Fix direction:

- For final release evidence, rerun the nginx script in an environment where the upstream mock starts and attach the full request-path output.

## Category sweep

A. Cross-step interaction bugs: PASS. Role grants and DSN separation hold across reader, rollup, provider portal, and admin CLI pools; no handler path receives the admin DSN and the rollup pool cannot read `stats.partner_keys`.

B. Step 4.B contract reconciliation: PASS. SPEC §5.6 now explicitly requires `burst=59 nodelay`; both nginx configs implement that directive on `/health`, `/network`, and `/leaderboard`.

C. Money-path drift: PASS. The exact-USD partner projection is only added after successful partner-key authentication, public cache responses bypass and no-store authenticated requests, structured logs redact request headers, metrics use closed labels or integer partner-key IDs, and CLI list output exposes only metadata. The AC-17 stdout defect above is a partner-key issuance contract failure, not an exact-USD projection leak.

D. Test surface honesty: FAIL. The random AC sample AC-2, AC-4, AC-5, AC-7, and AC-12 matched their cited production paths, but AC-17 is a "looks-like-PASS" case: tests accept metadata on stdout even though the SPEC says stdout is exactly one raw token.

E. `/metrics` endpoint surface: PASS. The provider server creates a dedicated `prometheus.NewRegistry()` and mounts `promhttp.HandlerFor(statsRegistry, ...)`; stats metrics use closed endpoint/status labels or integer IDs, so default-registerer side effects do not land in this registry.

F. Migration safety: PASS. Migration ordering is coherent, bootstrap seed inserts use `ON CONFLICT DO NOTHING`, roles are NOLOGIN, grants are explicit, and no seed conflict on a stock or hot-upgrade path was found.

G. CHANGELOG honesty: PASS. The v0.1.8 entry accurately summarizes the locked public behavior without claiming §6.6.2 production sign-off is complete.

H. OPS.md runbook executability: PASS. The §10 coordinator CLI examples now consistently pass `--config /opt/macprovider/coordinator.yaml`, include failure guidance, and align with the documented admin DSN resolution path.

I. §6.6.2 sign-off gate non-bypassability: PASS under the Round-2 contract. The binary does not block direct admin-DSN issuance, but SPEC §6.6.2 and the convergence record now frame the gate as operationally enforced through OPS.md §10.5, not as a code-level insert guard.

J. Anything else: FAIL. Independent CLI-output inspection found the AC-17 stdout mismatch that the 22-AC sweep did not catch.

## Final recommendation

Do not lock PR #173 at HEAD `264a606`. The Round-2 fixes resolved the prior architecture objections around `burst=59 nodelay`, `provider_portal` `SELECT`, and runbook `--config`, and I did not find a live exact-USD leak, metrics-registry leak, migration-order break, or role/DSN privilege escalation. However, AC-17 still silently fails its locked stdout contract while the test suite reports green. That is a HIGH blocker under the stated severity bar, so the release remains `REQUEST CHANGES` until the CLI output and AC-17 tests are corrected.
