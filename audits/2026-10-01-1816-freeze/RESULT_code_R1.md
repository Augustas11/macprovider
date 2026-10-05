Freeze verdict: **BLOCK**. Static review of the complete campaign diff found 11 issues. Broad local CI was not run because this host’s MacProvider policy forbids CI-parity workloads.

1. **HIGH — NEW — Unbounded, duplicated trust-pool replay inside the ledger writer transaction**

   Files: [hotpath.go:159](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/hotpath.go:159), [hotpath.go:256](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/hotpath.go:256), [pool_operator_attestation.go:40](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/trustpool/pool_operator_attestation.go:40), [durable_store.go:2251](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/trustpool/durable_store.go:2251), [recovery.go:408](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/recovery.go:408), [recovery.go:579](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/recovery.go:579)

   Defect: each settlement fence executes `SELECT ... FROM trustpool_events ORDER BY id` and JSON-decodes the entire global event log while holding `BEGIN IMMEDIATE`. Loopback pool-model settlement evaluates the same fence twice; recovery repeats the pattern.

   Failure: 100k events across unrelated pools plus concurrent settlement → one request scans the full history twice while holding the single SQLite writer, causing queued/time-out ledger writes and recreating the #1775 starvation class.

   Fix: use the existing pool index with a pool/id-bounded query or a compact materialized fence projection. Cache one fence result per attempt. Add tests proving unrelated events are not visited and loopback settlement evaluates the fence once.

2. **HIGH — NEW — Pool-model pricing-bound changes are accepted on SIGHUP but ignored**

   Files: [main.go:1130](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator/main.go:1130), [main.go:1146](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator/main.go:1146), [main.go:3943](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator/main.go:3943), [main.go:4088](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator/main.go:4088)

   Defect: manifest acceptance and buyer routing close over startup `pool_model_pricing_bounds`. Reload neither updates those closures nor rejects the change, yet records the candidate config as applied.

   Failure: start with maximum completion rate 5000, then reload maximum 1000 or remove bounds → reload succeeds, but new routes and manifests continue using 5000, contrary to the applied configuration and SPEC-005-R015.

   Fix: use one atomically reloadable bounds snapshot shared by acceptance, binding, routing, and listing, or reject bounds changes as startup-only. Test tightening and removal across SIGHUP.

3. **HIGH — NEW — Provider-owner authority changes are accepted on reload but ignored**

   Files: [main.go:1202](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator/main.go:1202), [main.go:1217](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator/main.go:1217), [main.go:3505](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator/main.go:3505), [main.go:4088](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator/main.go:4088)

   Defect: `provider_owner_public_keys` and `provider_owner_account_ids` are installed only at startup. SIGHUP reload updates creator-admin fields but silently leaves both owner-authority surfaces stale.

   Failure: operator rotates `K-old` to `K-new` or removes provider `p1` from `acct-old`, then reloads → the coordinator still accepts delegation material signed by `K-old` and still treats `p1` as owned by `acct-old`, preserving R016 routing authority the operator intended to remove.

   Fix: atomically reload both mappings and trigger binding reevaluation, or reject changes as startup-only. Add key-rotation and account-removal SIGHUP tests.

4. **MEDIUM — NEW — Status claims `pool_attested_earning` from stale event shape alone**

   Files: [model_admission.go:2150](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/ws/model_admission.go:2150), [model_admission.go:2676](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/ws/model_admission.go:2676), [model_admission.go:2750](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/ws/model_admission.go:2750)

   Defect: guidance emits `pool_attested_earning` whenever the latest event is pool-scoped `catalog_priced`; it does not verify the current R010/R011 membership, attestation, manifest, bounds, session, or receipt predicates.

   Failure: remove a member’s R016 attestation or invalidate the pool, then request status before the asynchronous sweep—or while the sweep is failing → the CLI says the model earns in its pool although routing rejects every attempt.

   Fix: re-evaluate the current earning predicate when encoding status and fail closed to a non-earning guidance value if it cannot be proven. Test every invalidation before sweep completion and under store errors.

5. **MEDIUM — NEW — `/v1/models` counts pool providers that routing rejects**

   Files: [pool_model_route.go:453](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:453), [pool_model_route.go:488](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:488), [pool_model_route.go:153](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:153)

   Defect: listed capacity checks membership, state, cached binding IDs, runtime, and artifact pair, but omits current R016/creator authority, durable binding head, generation, bounds, enforce mode, receipt key, and validated release generation.

   Failure: remove a delegated member’s R016 attestation → `/v1/models` still reports `provider_count: 1` and nonzero slots, while chat returns `pool_no_eligible_member`.

   Fix: derive capacity from the same current eligibility predicate used for selection, preferably with batched admission-head reads. Add negative listing tests for stale bindings, removed attestations, absent receipts, and missing bounds.

6. **MEDIUM — NEW — Native proposals demand loopback-only manifest controls**

   Files: [PoolModelProposal.swift:291](/Users/augstar/macprovider-1816-pool-models/phase3-binary/Sources/macprovider-cli/PoolModelProposal.swift:291), [PoolModelProposal.swift:294](/Users/augstar/macprovider-1816-pool-models/phase3-binary/Sources/macprovider-cli/PoolModelProposal.swift:294)

   Defect: every proposal includes `runtime_source_in_runtime_allowlist` and `attested_member_required_for_non_creator_account`, including native `mlx_cache`. Native MLX must not appear in `runtime_allowlist` or R016 member attestations.

   Failure: propose a native MLX snapshot → creator guidance asks for invalid or irrelevant policy fields, leading to a rejected manifest or incorrect setup.

   Fix: emit these requirements only for external loopback runtimes. Add an exact native proposal test.

7. **MEDIUM — NEW — Explicit CLI configuration errors silently fall back to production**

   Files: [BYOMLiveCatalogMatcher.swift:34](/Users/augstar/macprovider-1816-pool-models/phase3-binary/Sources/macprovider-cli/BYOMLiveCatalogMatcher.swift:34), [BYOMLiveCatalogMatcher.swift:55](/Users/augstar/macprovider-1816-pool-models/phase3-binary/Sources/macprovider-cli/BYOMLiveCatalogMatcher.swift:55), [ModelsSubcommand.swift:465](/Users/augstar/macprovider-1816-pool-models/phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:465), [ModelsSubcommand.swift:486](/Users/augstar/macprovider-1816-pool-models/phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:486)

   Defect: `try? ConfigLoader.load` suppresses missing/unreadable/invalid explicit config errors. Feed resolution then defaults to the production coordinator and proposal generation loses configured provider/model/artifact hints.

   Failure: `models propose ... --config ./staging.yaml` with a misspelled or malformed file → the command may consult production feeds and inspect default artifacts instead of failing on the explicit staging configuration.

   Fix: propagate configuration errors whenever a path was explicitly supplied. Fall back to production only after successful configuration loading with no coordinator override. Add missing-file and malformed-YAML tests.

8. **LOW — NEW — Signer does not enforce actual top-level JSON EOF**

   Files: [trust_pool_sign.go:888](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator-cli/trust_pool_sign.go:888), [trust_pool_sign.go:893](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator-cli/trust_pool_sign.go:893), [trust_pool_sign_models_test.go:161](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/cmd/coordinator-cli/trust_pool_sign_models_test.go:161)

   Defect: `Decoder.More()` is an array/object helper, not an EOF check; it accepts malformed trailing `]` or `}`.

   Failure: valid `pool-models.json` followed by `]` → signer accepts the malformed file and signs the first object.

   Fix: perform a second decode and require `io.EOF`. Test closing delimiters, scalars, and a second object.

9. **LOW — NEW — Claimed exact proposal fixture is already asymmetric with Swift**

   Files: [PoolModelProposalTests.swift:98](/Users/augstar/macprovider-1816-pool-models/phase3-binary/Tests/macprovider-cliTests/PoolModelProposalTests.swift:98), [PoolModelProposalTests.swift:121](/Users/augstar/macprovider-1816-pool-models/phase3-binary/Tests/macprovider-cliTests/PoolModelProposalTests.swift:121), [pool_model_proposal.v1.json:23](/Users/augstar/macprovider-1816-pool-models/scripts/lab/1690-m6/testdata/pool_model_proposal.v1.json:23)

   Defect: the test promises exact bundle symmetry but checks only that fixture requirement codes belong to the enum. Swift emits `attested_member_required_for_non_creator_account`; the Python/lab fixture omits it.

   Failure: creator-requirement output changes → Swift and lab tooling fixtures drift while all current tests pass.

   Fix: align the fixture and builder, then compare `creator_requirements` exactly for loopback and native proposals.

10. **LOW — NEW — `/v1/models` loses a valid pool selection after a blank duplicate header**

   Files: [server.go:372](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/server.go:372), [pool_selection.go:86](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/pool_selection.go:86)

   Defect: the new models handler gates resolution using `Header.Get`, which sees only the first value; the resolver correctly scans all values.

   Failure: headers `X-MacProvider-Pool-Select: ` followed by `X-MacProvider-Pool-Select: poolA` → chat resolves `poolA`, but `/v1/models` skips resolution and returns the global list.

   Fix: always call the resolver, or gate on `Header.Values`. Add a blank-then-valid duplicate-header test.

11. **LOW — PRE-EXISTING — Browser clients cannot use the #1690 engine selector**

   Files: [cors.go:7](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/cors.go:7), [engine_selection.go:14](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/engine_selection.go:14), [cors_test.go:78](/Users/augstar/macprovider-1816-pool-models/phase5-gateway/internal/router/cors_test.go:78)

   Defect: `X-MacProvider-Engine-Select` is omitted from CORS allowed headers, and tests do not assert it.

   Failure: browser sends the #1690 engine selector → preflight omits it, so the browser blocks the request before routing.

   Fix: add the header to `corsAllowedHeaders` and the CORS regression test.

TOTALS: C=0 H=3 M=4 L=4 I=0