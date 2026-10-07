# #1690 acceptance closeout — 2026-10-07

This is an in-progress evidence record, not an issue-completion or production
Creator-launch claim. #1879 merged at `bc117360106d91055221e01f0f8b0de4cd2ac550`;
signed-evidence integration and release acceptance continue under #1690. Existing coordinator v1.8.221
and the existing signed member CLI reporting v1.8.222 remain the serving
binaries. The latter is a private acceptance candidate, not a published stable
release: run `37493026731`, reviewed-main source
`7e68120b8ac0b92e8291a990c88b40f55bafcf5a`, channel `acceptance`. Its packaged
standalone CLI SHA-256 matches the serving member binary:
`fc3e54691585a0b0fa9509225fcac51ae89b6dba10f172a2f098f271b94bedcc`.

## Fresh isolated journeys

Both captures ran on the designated Mac Studio (`Mac15,14`) from reviewed
source `eedd1c1456242afab775072bef622a68c3b634a0`, with isolated test storage and
HTTP handlers. No production activation or live-provider replacement occurred.

- Layer2: `MACPROVIDER_CAPTURE_TRUSTED_POOL_LAYER2=1 go test ./internal/buyer
  -run '^TestJourneyTrustedPoolLayer2MVPCandidate$' -count=1 -v` — PASS, 1.018 s.
  Redacted artifact: `journeys/evidence/trusted-pool-layer2-20261007T043021Z.redacted.json`.
  SHA-256: `5f89940ccaa13581e5bef8c14140f039ee724473b280245389f64e1d3391e83f`.
- Creator MVP: `MACPROVIDER_CAPTURE_TRUSTED_POOL_CREATOR_MVP=1 go test
  ./internal/trustpool -run '^TestJourneyTrustedPoolCreatorMVPCandidate$'
  -count=1 -v` — PASS, 8.458 s.
  Redacted artifact: `journeys/evidence/trusted-pool-creator-mvp-20261007T043959Z.redacted.json`.
  SHA-256: `7d3700d668ccd7caa086d2a29a70e2d3ebba119ddde8bf7595f41fdd6d2db664`.

The protected main signing workflows subsequently signed both captures; see
the signing record below. Neither capture fills production conformance or
proves an external Creator launch.

## External-runtime capture correction

The private production capture `trusted-pool-external-runtime-20261007T053340Z`
stopped at the old `no-selector-no-pool` control: HTTP 200 disclosed
`mlx_cache`, a legitimate native global route for the same catalog model.
This is a failed capture, not signed journey authority or an external-engine
global bypass. Its original private responses are retained unchanged.
SPEC-006 and SPEC-042 permit that native route. The replacement negative is
`pool-native-selector`: selecting native on the llama.cpp-only M1 pool must
return 503 `engine_unavailable`, with zero route snapshots and ledger rows.
The corrected contract requires a new complete capture before signing.

The replacement `trusted-pool-external-runtime-20261007T053807Z` capture
passes all 11 builder steps against coordinator/gateway v1.8.221 and signed
CLI v1.8.222. Both llama.cpp requests have closed verified v4 receipts,
one payable enforce ledger credit, and matching debit/finality/ledger token
counts. All four corrected controls refuse with zero snapshots/ledger rows.
The run has zero holds/missing trailers; the single pre-existing hold remains
byte-identical global context. Buyer-visible usage vs debit remains the
explicit E2E-F1 observation, not a concealed failure.
Redacted artifact:
`journeys/evidence/trusted-pool-external-runtime-20261007T053807Z.redacted.json`.
SHA-256: `f696f31eb981f47ba310c25c6e71313ada7f9678a289b2970f74e7e5d47f37db`.
The operator-authored identity was qualified as `github-user:<login>` before
redaction to avoid collision with the public repository owner in accepted IDs;
the original metadata and all original HTTP/SQL captures remain private.
The protected workflow subsequently signed this artifact; see the signing
record below. Its production capture does not include the later #1879 CLI fix.

## Protected signing and bounded conformance integration

All three evidence-only workflows ran from reviewed main
`bc117360106d91055221e01f0f8b0de4cd2ac550`, with explicit operator approval of
the protected environment. No CLI publication or production activation occurs
through these workflows.

| Journey | Successful workflow | Signed envelope SHA-256 | Expiry |
| --- | --- | --- | --- |
| External runtime | [37597012552](https://github.com/Augustas11/macprovider/actions/runs/37597012552) | `a2f113817f92238e23fba66418c2022cb7c268337be27f831cdc7cf48bf1e19f` | 2026-10-14 |
| Layer2 | [37597017902](https://github.com/Augustas11/macprovider/actions/runs/37597017902) | `01eb2d50a357e4cd7f356dbfeb3f000f3ffba9fec345a0cab95eded20f11ee8f` | 2026-10-14 |
| Creator MVP | [37597062267](https://github.com/Augustas11/macprovider/actions/runs/37597062267) | `8fda5df88f98961101363a931b6a01a537d8b07a6cd899714ef4ca170b2169d6` | 2026-10-07 |

Signed envelopes accompany the existing redacted captures under
`journeys/evidence/`. Targeted integration verification passed the pinned public
key signatures, payload/artifact binding, expiry and current implementation/test
selector checks for all 19 covered requirements (3 external, 4 Layer2, 12
creator) at the original integration base. Downloaded redacted captures match committed bytes; envelope hashes
match workflow export manifests. External-runtime workflow output promotes only
SPEC-022-R012 and SPEC-042-R013/R014. Other rows and spec-level status are
preserved. Layer2 and creator remain evidence-only: their signatures do not
promote full SPEC-042/043 rows or authorize a Creator launch. Short-lived
isolated evidence must be recaptured after expiry, not extended by re-signing.

Post-#1883/#1876 revalidation against `62a9a459de59f759e09fbe88a9015e738da367ae`
still passes all three external-runtime promotion rows. The older Layer2
SPEC-042-R010 gateway selector and creator SPEC-043-R007 buyer selector have
changed, so those two signed captures are historical, not current-base evidence.
No Layer2 or creator conformance claim is made from them.

Fresh isolated captures passed on that exact merged source:
`journeys/evidence/trusted-pool-layer2-20261007T122927Z.redacted.json` and
`journeys/evidence/trusted-pool-creator-mvp-20261007T122939Z.redacted.json`.
These are **unsigned** until their reviewed capture commit lands on main and
the protected signing workflows run. They do not authorize conformance
promotion, a live Creator launch, or deployment. Fresh protected signatures and
their reviewed integration remain a follow-up gate for #1690.

## Production SPEC-043-R007 timing

Five runs used Pearl's public production gateway, the unchanged 150 ms server
floor, 200 samples per class, and class order shuffled each round. The llama.cpp
pool was paused only for each run and verified active/routeable after restoration.
Gateway-wide service and the Ollama pool were not paused. Credentials and pool
identities are absent from the retained numeric samples and evaluator outputs.

| UTC run start | Measurement client | p95 gap, ms | p99 gap, ms | Minimum U-test p | Result |
| --- | --- | ---: | ---: | ---: | --- |
| 04:29:13 | Original client, TLS context per request | 18.3721 | 0.4294 | 0.3883 | FAIL (p95 > 15 ms) |
| 04:33:03 | Same client with experimental shared TLS context | 0.3881 | 2.7482 | 0.3303 | PASS, diagnostic comparison only |
| 04:39:02 | Corrected repository tool, no context monkeypatch | 0.7843 | 1.7374 | 0.5286 | PASS, historical production remeasure |
| 05:24:07 | Corrected repository tool with fail-closed redirects | 1.0472 | 2.9109 | 0.0606 | PASS, historical class-unbound measurement |
| 05:49:19 | Corrected tool with private pre/post class-state binding | 0.5310 | 1.5553 | 0.3056 | PASS, current official production remeasure |

The comparison supports eliminating repeated client TLS setup as measurement
noise; it does not establish a universal absence of a timing oracle. All runs,
including the failure, are retained as `r007-<timestamp>.samples.json` and
`r007-<timestamp>.result.json`. The experimental result is explicitly
machine-marked `diagnostic_only` / `production_remeasure_complete: false`;
its original evaluator claim and original output SHA-256 are recorded without
treating that claim as authoritative. The earlier runs lack the new pre/post
class-state binding and are historical comparisons, not current closeout
authority; their original outputs and source claims remain intact.
The official result binds its source
blob, tool SHA-256, sample SHA-256 and nonexperimental command shape.
Evaluation uses nearest-rank percentiles and
the unchanged thresholds: p95 <= 15 ms, p99 <= 25 ms, minimum two-sided
Mann–Whitney p >= 0.01. The final client requires exactly HTTP 503 and parsed
JSON `error.code == "pool_unavailable"`; each sample still opens a fresh HTTP
connection and rejects all redirects without forwarding credentials. The current
05:49:19 measurement tool SHA-256 is
`94acbc1044eb682a1a5ba267057d5ba632ff245693c29f6e9f44a0865b788c61`.
The earlier results retain their original source hashes as historical evidence.
Private operator captures at 05:49:20Z and 05:50:59Z bind distinct unknown,
existing unauthorized, and paused buyer-authorized pool inputs, the credential,
tool, samples, nonce and salt. The post-check precedes the pre-check's expiry;
both Pearl deployment locks cover the entire pause/capture/measure/restore window.
The unauthorized pool was `created` and nonrouteable: it satisfies the existing
pool/nonmembership class, but adds a lifecycle rejection predicate. This is not
a pure active-routeable authorization-isolation test. Public projections are
salted, operator-authored proof, not server-signed attestations; raw admin
responses remain private. The tool first emits a pending result, and only the
operator finalizer promotes it after verifying the actual post-check.

Targeted regression command:
`PYTHONDONTWRITEBYTECODE=1 python3 -W error::ResourceWarning -m unittest
scripts.tests.test_pool_rejection_timing_floor` — 30 tests PASS.

## Mixed-version coexistence

`mixed-version-coexistence-summary.json` retains the read-only 05:40:35–05:41:02Z
window: coordinator/gateway v1.8.221 and native CLI 217 plus pool CLIs 222
were ready with stable service/provider identities and distinct process scopes.
Accepted IDs include cohorts 217, 219 and 222. This is bounded coexistence
evidence, not a formal rolling-restart proof or a whole-session no-restart claim.
The v1-only rollback preflight correctly refused incompatible manifest history
(exit 3); rollback readiness is not claimed. The filtered `/poolz` row was not
derived by this collector. Original private snapshots remain operator-only.

## Still blocking completion

- Protected signing completed as recorded above. Reviewed integration of the
  signed envelopes and three external-runtime conformance rows is the current
  gate; Layer2 and creator full-row production conformance is not claimed.
- Before operator-approved cleanup, the gateway had 20 global ACTIVE
  settlement-held reservations. The scoped
  released-binary relay-blind reconciler returned `held=1`, `errors=0` for the
  latest reservation; it did not refund or debit it. Ordinary release dry-runs
  proposed releasing 19 older holds with inconclusive finality. The operator
  explicitly approved those exact 19 releases. Rechecked and applied through
  the existing released gateway's audited endpoint: 17,433 reserved quota
  tokens returned, zero buyer debits/cash transfers, active backlog 20 -> 1.
  `historical-holds-approved-release-summary.json` records the bounded result;
  per-reservation dry-run/apply records remain in the private operator store.
  The newer relay-blind hold is excluded and remains held. The production
  journey's old global-zero hold check is broader than SPEC-022-R012 and
  SPEC-042-R013/R014: their forward acceptance requirements concern the
  pool requests' own finality, debit and ledger credit. Global draining is a
  separate rollback precondition. The versioned run-scoped check now passes
  for the fresh production capture; unrelated backlog remains explicit operational context, not
  a global-health or rollback-readiness claim. Financial SQL has not been
  manually rewritten.
- A carried #1863 MEDIUM concerned startup TPS trusting stream fragmentation
  rather than a trusted token count. The closeout patch uses the existing
  artifact-bound pinned tokenizer, with SPEC-001 v1.9.31 / SPEC-002 v1.6.9.
  `swift test --jobs 2 --filter OpenAICompatibleLoopbackRuntimeTests` on
  Studio exited 1 before running tests: the installed Command Line Tools
  toolchain lacks XCTest. Its generated lockfile change was restored. GitHub
  macOS/Xcode verification and combined review subsequently passed for #1879
  (CI `37592545986`, spec-index `37592546005`, zero C/H/M across all three
  review lanes). Reviewed signed rollout remains pending; no unreviewed local
  binary has replaced a live provider.
- Final acceptance of the bounded mixed-version proof remains pending. Current
  Llama qualification and the amended capability-aware Ollama profile are
  evidenced below; this does not qualify future engine/model entries. Public external Creator launch is a separate SPEC-043 scope;
  no named external operator or hardware-backed production root is fabricated.

## Freeze verification and carried limitations

### Current-model measurements

The isolated throughput capture
[`current-model-throughput-20261007T065853Z.json`](current-model-throughput-20261007T065853Z.json)
passes Llama-3.2-3B native/llama.cpp actual prompt-token parity at c=1/4/8,
prompt1024/decode256, n=5. llama.cpp aggregate p50 is 166.77/197.83/191.95
tok/s; the recorded production-native serial baseline is 222.47 tok/s.
Native contiguous-batched figures are not presented as production throughput.
The full capture exited nonzero because Ollama reported 1,023 cached prompt
tokens; no cache-free Ollama pass is claimed.

The quality-only confirmation
[`current-model-quality-20261007T071549Z.json`](current-model-quality-20261007T071549Z.json)
passes actual corpus, evaluated-input and scored-target token-hash equality.
It uses ctx512, the first150 full chunks, and 38,250 scored targets. Llama
requires BOS128000 once in the corpus and at each chunk's first position;
corrected native PPL11.2307 vs llama.cpp10.6216 supersedes the incomparable
no-BOS native result. Qwen2.5-0.5B uses no BOS: native PPL17.7674 vs exact
Ollama GGUF artifact PPL15.1892, measured by llama.cpp, not Ollama runtime.
Quantizations differ; these are artifact-aware comparisons, not isolated
runtime-quality effects or proof of Ollama API token identity.

The opt-in BOS fix built on the Studio in179.97s after an initial compile
failure was corrected. New unit tests await GitHub CI. Three full-diff review
lanes cleared the code increment at0C/H/M; published custom-corpus hashes carry
the same equality/dictionary limitation as custom prompt hashes. Required
checks, protected signing, mixed rollout and signed-release acceptance remain
pending. Integration of newer main also requires fresh signed BYOM discovery
evidence for the changed version-lock selector; historical signed captures are
retained unchanged, not treated as proof of that changed selector.

The focused Python regression command covering timing, external-runtime evidence,
and BYOM contract locks passed 102 tests in 6.604s. A first invocation failed
because it named a nonexistent lock-test module; the corrected command passed.
The subsequent timing-only wording correction passed all 30 timing tests in
5.888s. The measured tool remains anchored to commit `8daa9f1d6317` and its
recorded exact blob/hash, rather than implying the later wording was measured.
The PR declaration check passed. A local full governance run was terminated
when its resource use exceeded the operator-host boundary; its result is not a
PASS. GitHub Actions owns the full governance and build/test gates.

Security review carries three non-gating LOW limitations: published pool IDs
can reveal linkage to salted timing fingerprints; custom Ollama prompt hashes
are unsalted and reveal equality/dictionary matches; Ollama model evidence binds
the filesystem mapping, not cryptographically the running process. The Ollama
tool is operator-only/nonbilling and is operational measurement, not strict
same-M0 native-token/cache/perplexity qualification. None of these observations
grants settlement trust, completes model qualification, or activates an external
Creator launch.

### Approved capability-aware Ollama qualification

On 2026-10-07 the operator approved the separate
[capability-aware protocol](../../docs/runbooks/runtime-agnostic-engine-qualification.md).
The fresh
[`current-model-ollama-capability-20261007T080540Z.json`](current-model-ollama-capability-20261007T080540Z.json)
passes that profile: all 65 measured requests at c=1/4/8 and n=5 completed with
1024 reported prompt tokens, 257 reported eval tokens, 1023 reported cached
prompt tokens and `done_reason=length`. The isolated runtime is Ollama0.34.4,
and the exact Qwen2.5-0.5B GGUF digest matches the earlier artifact-quality proof.

| Concurrency | End-to-end API eval tokens/s, p50 | First-content TTFT p50 / p95 |
|---|---|---|
| 1 | 278.23 | 8.23 / 9.19 ms |
| 4 | 759.24 | 12.78 / 15.06 ms |
| 8 | 1100.83 | 17.11 / 22.15 ms |

These are cached operational measurements, not an uncached native-M0 ratio.
The first content chunk is not proven to contain exactly one token; the legacy
subtract-one decode metric is a proxy. The primary end-to-end metric uses actual
API-reported eval counts over each complete request round. Requested count fields
are labeled as targets; per-request samples preserve achieved counters.

This completes the amended current Ollama engine/model measurement and
artifact-quality arms only. It does not retroactively pass the failed cached
strict attempt, assert native token parity or Ollama runtime PPL, grant billing
trust, or accept a release. The isolated source05781fe70 build passed in182.62s;
new Swift tests and all required CI checks remain pending. Full combined
code/security/architecture reviews cleared the tool at0C/H/M before measurement.
