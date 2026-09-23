# Audit — #1705 catalog row-continuity admission + CLI envelope refresh (round R7)

Method constraint (read first): this is a first-party software-correctness / proof
review. Do NOT author or construct malformed payloads or exploit inputs. Evaluate by
reading source and running EXISTING/NEW tests in the repo; describe any gap abstractly
(field + condition) in prose. Do not edit any file in the worktree.

Worktree: /Users/augstar/macprovider-1705 (branch fix/1705-catalog-row-continuity).
The complete fix under review is `git -C /Users/augstar/macprovider-1705 diff origin/main`
(committed + uncommitted working tree) PLUS the untracked file
`phase4-coordinator/cmd/coordinator/autotune_row_continuity_test.go`. Review the FULL
combined diff, and read surrounding code outside the diff where contracts meet it.

Context:
- Issue: `GH_TOKEN=$(gh auth token -u Augustas11) gh issue view 1705 --repo Augustas11/macprovider`.
- Governing contract: specs/SPEC-023-installer-autotune-recommend.md §3.6.1
  (SPEC-023-R010, v0.14.3 additions) and AC-CAT-22; SPEC-010-R004/R007 for identity
  binding. CONFORMANCE entry SPEC-023-R010.
- Coordinator: `.row-continuity-target` (<=8 `releases/<id>` lines) is loaded through the
  keyring-verified previous-candidate loader, tombstones dropped, marked
  `Catalog.RowContinuityOnly`; `catalogAdmissionWithCatalog` returns mode
  `row_continuity` for such documents and requires equal row identity +
  PolicyEquivalent; `admittedCandidateCatalogSHA256` excludes row_continuity so
  artifact-derived identity fails closed.
- CLI: `CoordinatorClient` catalog envelope becomes replaceable; on
  `catalog_incompatible` or an ack advertising a different current sha, a rate-limited
  refresher re-runs the signed live fetch and stages a new envelope for the next hello
  only when the served row's model_sha256 is unchanged. Malibu/CLI status copy for plain
  `catalog_incompatible` no longer says "install new software".

Useful commands:
- `cd phase4-coordinator && go test ./internal/ws -run 'RowContinuity|CatalogAdmission|Previous' -count=1`
- `cd phase4-coordinator && go test ./cmd/coordinator -run 'RowContinuity|Restamp|PreviousAutotune' -count=1`
- `cd phase3-binary && swift build --build-tests && swift test --skip-build --filter "CoordinatorClientTests.test(CatalogIncompatibleRefresh|HelloAckOn)|ServeCommandTests.testCatalogEnvelopeRefresh|StatusCommandTests.testPlainCatalogIncompatible"`
  (if swift build modifies phase3-binary/Package.resolved, restore it with
  `git checkout origin/main -- phase3-binary/Package.resolved`).

Output format: a findings list, each with severity CRITICAL/HIGH/MEDIUM/LOW/INFO,
file:line, the defect, a concrete failure scenario, and a suggested fix. Only report a
finding as C/H/M if you can point to the code path that produces the failure. End with
exactly one line: `VERDICT: C=<n> H=<n> M=<n> L=<n>`.

## Lane: ARCHITECTURE REVIEW
Focus: does the design satisfy SPEC-023-R010 items 1-4 and AC-CAT-22 as written
(including "admission mode records row continuity", "diagnostics preserve A's release
ID and full catalog body digest", "hello ack still advertises C"); is the SPEC v0.14.3
text consistent with the code (no over- or under-claiming) and with the rest of
SPEC-023 / SPEC-010 / SPEC-047; CONFORMANCE entry honesty (state, mappings, gap); the
operational model (who maintains `.row-continuity-target`, interaction with deploy /
renew / rollback scripts and open PR #1706 which makes scripts/autotune_window.py the
only `.previous-target` writer); CLI/coordinator layering (refresher reuse of serve-start
verification vs duplicated logic drift); Malibu status-state model coherence.

## Round R2 notes
R1 findings and dispositions (verify each is resolved; do not re-report resolved items):
- R1 HIGH "branch reverts #1709/#1710 loopback settlement bar / settlement retry": stale
  base artifact — branch is now rebased onto origin/main afbee248; confirm
  `git diff origin/main` no longer touches those files.
- R1 HIGH (arch) CLI refresher adopted on unchanged model_sha256 only: fixed —
  `refreshCatalogEnvelopeIfDue` now requires refreshed row identity == advertised row
  identity (row identity binds policy digest); SPEC §3.6.1 provider-refresh text updated.
- R1 MEDIUM "unchanged" ignored signer: fixed — unchanged requires same sha AND signer.
- R1 LOW dot-segment target lines: fixed in parseReleaseTargetLine + tests.
- R1 LOW artifact identity test omitted row_continuity: fixed.
- R1 LOW release-id/sha key collision in buildCompatibleCatalogSet: carried as LOW
  (pre-existing map design; release IDs are operator-controlled non-hex names).
- R1 INFO PR #1706 validator must learn `row_continuity`: carried to the PR body as a
  cross-PR composition note.
Note: SPEC-023 is now v0.15.1 (origin/main took v0.14.3 for #1694 and v0.15.0 for #1706).

## Round R3 notes
R2 findings and dispositions (verify; do not re-report resolved items):
- R2 SECURITY HIGH catalog reload left diverged older-document sessions routable:
  fixed — `closeCatalogDivergedSessions` (server.go) runs at the start of
  `refreshSessionIdentities`, which every release publication calls; any
  `previous`/`row_continuity`/`current` session whose resolved document is not the new
  active one is closed `catalog_incompatible` once its row identity or PolicyEquivalent
  policy diverges, independent of the hello/PoW gate. Unresolvable sessions keep the
  pre-existing catalog-unavailable handling (deliberate: a misconfigured reload must not
  mass-close the fleet). Test: TestCatalogRowContinuitySessionsAreRecheckedOnPublication.
  The residual window between publication and this sweep is the same synchronous call
  chain (publish → afterReleasePublished → refreshSessionIdentities).
- R2 ARCH MEDIUM compatibility-set rejections collapsed into catalog_incompatible:
  fixed — codes prefixed `compatibility_set` now classify with reason
  `compatibility_update_required` (Malibu keeps software-update guidance for it), and
  the refresh trigger keys on the exact `catalog_incompatible` reason. Test:
  testCompatibilitySetRejectionDoesNotRefreshCatalog.
- LOW release-id/sha key namespace: carried LOW.
- INFO #1706 composition: will be posted as a cross-PR comment on #1706 and in the PR body.
The CODE lane passed R2 at 0/0/0 and is not re-run.

## Round R4 notes
The branch is rebased onto origin/main 5c664563 (includes #1706 catalog-content lane
and #1703). Review the FULL `git diff origin/main` (+ the untracked cmd/coordinator test).
R3 findings and dispositions (verify; do not re-report resolved items):
- R3 SECURITY HIGH diverged session routable during closeSession's delayed teardown:
  fixed — `fenceCatalogDivergedSession` marks the session `StateUnavailable`
  synchronously before queuing the close (precedent: relay.go and trust-revocation
  eviction). Test asserts RoutingEligible()==false immediately after SetAutotuneCatalog.
- R3 ARCH HIGH admission/publication not linearized: fixed — `registerProviderSession`
  re-checks the registered session against the active snapshot right after registration
  (evict-not-refuse, mirroring the trust revalidation TOCTOU design). Linearization:
  publish completes before its sweep snapshots the pool; registration completes before
  its re-check snapshots the catalog; so either the sweep sees the registered session or
  the re-check sees the new catalog. Test:
  TestRegisterFencesSessionWhoseCatalogRowDivergedBeforeRegistration (internal).
- #1706 composition: `AutotuneReleaseRoot` / `PreviousTargetPath` shared by
  `.row-continuity-target` (disabled with the window when PreviousTargetPath=/dev/null);
  `--validate-autotune-release` labels row-continuity entries `row_continuity`;
  scripts/autotune_window.py accepts it. Known limitation (declared LOW): the R015
  coverage check counts a row_continuity pair as covered although it admits only
  unchanged rows; post-activation evidence (d) and the divergence sweep catch a changed
  row.
- LOW release-id/sha namespace collision: carried LOW.

## Round R5 notes
Rebased onto origin/main 57022da8 (includes #1711 WAL checkpoint safeguards and #1702
ceiling pin); `git diff origin/main` no longer touches those.
R4 findings and dispositions (verify; do not re-report resolved items):
- R4 SECURITY HIGH unresolvable row_continuity document kept its session: fixed —
  `fenceCatalogDivergedSession` fences and closes a `row_continuity` session whose
  document no longer resolves. `previous`/`current` sessions whose document leaves the
  retained set keep the PRE-EXISTING catalog-unavailable handling (unchanged by this
  diff; deliberately not widened so a window rotation cannot mass-close the fleet —
  the very outage #1705 fixes). Test case "row-continuity evidence no longer loaded".
- R4 ARCH MEDIUM validators did not see the live `.row-continuity-target`: fixed —
  deploy-pearl-vps.sh, scripts/lib/autotune-activate.sh (renewal) and
  scripts/catalog-content-release.sh install the live file into their validation root;
  deploy_catalog_window_coverage.test.sh proves a row-continuity-only provider is
  covered (and fails without the change); renew/content tests guard the line; renew
  golden regenerated (single intended line).
- R4 LOW R015 coverage release-level for row_continuity: carried LOW, now documented in
  SPEC §3.6.1 (post-publication re-check enforces per-row equivalence).
- LOW release-id/sha namespace: carried LOW.

## Round R6 notes
R5: SECURITY lane passed 0/0/0 (LOWs only) and is not re-run; CODE lane passed at R2.
R5 ARCH HIGH (registration exposed a ready provider before the catalog re-check): fixed —
`registerProviderSession` publishes catalog-bound sessions (catalogEnvelopeAdmissionMode
and admitted state ready/busy) as `draining`, runs the re-check, and promotes via
`MarkState(admittedState)` only if not fenced; `registerProviderSessionLocked` records
the admitted state in the operator admission snapshot. The internal test uses
`catalogRecheckPendingHook` (nil in production) to assert the session is not
RoutingEligible during the pending interval, and that an equivalent session is promoted
to ready. Full coordinator suite and `make test-integration` (race) pass.
Carried LOWs: release-id/sha namespace; release-level row_continuity coverage.

## Round R7 notes
R6 (independent architect lane) MEDIUM — the draining pending marker could undo a
concurrent drain — fixed: `Provider.CatalogRecheckPending` (json:"-") is set on the
entry before registration, read only by `RoutingEligible()`, and cleared by
`Registry.ClearCatalogRecheckPending` after the re-check passes; State is never touched
by the hold, and the admission snapshot records the real state. `ServingCapable` is left
unchanged (it is evidence-pinned by a conformant requirement; the hold is microseconds
and routing is the invariant). Test: TestCatalogRecheckReleaseKeepsConcurrentDrain.
R6 INFO CONFORMANCE mappings added. Carried LOWs unchanged.
