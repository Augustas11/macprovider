# CLI Release Train — control surface

**This file is the single source of truth for provider CLI releases.** Work happens
across many sessions and agents; before cutting, testing, or promoting a CLI
build, read this file, and after any release-affecting action update it in the
same commit/PR. If reality and this file disagree, fix this file.

## How to track the next CLI

The shipped-207 table below records the completed net change from fleet
**1.8.123** to **1.8.207**. Start the next-candidate table only when another
CLI/Malibu/installer change merges.

1. A PR that changes `phase3-binary/` (CLI, Malibu.app, installer) **merges** →
   add one row the same day. Status `merged`.
2. A PR is open but not merged → status `in progress`. It is **not** in the
   next candidate.
3. Cut a candidate off `main` → every `merged` row is in that build. If a row
   is still `in progress`, wait or leave it out of scope.
4. Promote that candidate to the fleet → bump “Current promoted stable”, delete
   the shipped rows, start a new table.

Do not put spec-only or CONFORMANCE-only PRs here. They do not change the
binary the Mac runs.

## Core rule (do not violate)

- Private, non-promotable candidate tags do not bump `binaryVersion`; their
  identity lives in the signed `compatibility_set_id`
  (`owner/repo:vX.Y.Z@<commit>`).
- A `promotion_ready=true` candidate **must already carry its final CLI and
  Malibu version in the accepted bytes**. Promotion publishes those exact
  bytes; it cannot rewrite a signed binary. The version-identity bump therefore
  lands immediately before the final candidate cut, while the checked-in and
  live coordinator recommendation remain on the previous stable until
  publication succeeds.
- Promotion then advances the live coordinator `latest_binary_version` and
  `compatibility_set.target_id`, and triggers fleet autoupdate.
- Cut the promotable candidate off the **current `main` tip after all in-scope
  changes are merged** — never promote a candidate that predates a merged
  in-scope change.

Pearl coordinator/gateway release numbering is independent from the provider
CLI train. Pearl currently reports runtime `v1.8.223` and recommends provider
`1.8.223`; failed or superseded runtime attempts remain consumed tags. Public
provider release `v1.8.223` is published, and none of those tags may be reused
by either train. The historical promotion table below is not today's version
selection.

## Current published release and fleet target

Verified 2026-10-10 against public release metadata, the release train
(`scripts/ops/cli-release.sh status`) and live health:

| Field | Value |
|---|---|
| GitHub provider release | [v1.8.232](https://github.com/Augustas11/macprovider/releases/tag/v1.8.232) (published 2026-10-09 23:22Z) |
| Signed compatibility-set id | `Augustas11/macprovider:v1.8.232@36758c05c18dcedea1a321aa6b3120c6678640c0` |
| Pearl runtime / recommended provider | `v1.8.236` / `1.8.232` |
| Admission | Repository policy (#1919): every well-formed release from this repository connects and gets the recommendation; 42 exact revocations (the v1.8.34–v1.8.123 seed) make those builds update-only. No accepted-id list. |
| Canary | Studio canary on 1.8.232 passed with CB live-verified; e2e gate recorded as CF-232-E2E (below). |
| Installer | `get.malibu.tech/install.sh` matches the v1.8.232 `dist/install.sh` (train step `install_sh_vs_release: parity`). |
| Release mirror | `download.malibu.tech/releases/v1.8.232/` byte-identical to GitHub (33 assets verified); `latest.json` promoted from `v1.8.224` to `v1.8.232` on 2026-10-10 with `publish-release-mirror.sh --promote-latest`. |

## Next CLI release — net changes vs 1.8.232

One candidate, one Studio canary, one promotion. Nothing is recommended to the
fleet before the canary passes.

| PR / branch | Change | Status |
|---|---|---|
| #1910 | Capacity shedding and prefill fairness; measured concurrency calibration | merged |
| #1937 | Attested-hardware auto-trust, pending hardware checks non-fatal, engine-run CLI fixes, operator pause survives coordinator drains | merged |
| #1919 | Provider side of repository admission (`binary_version` must equal the compatibility-id version) | merged |
| #1927 | MLX runtime to mlx-swift-lm 3.32.3 / MLX 0.32 through the forks; Swift 6.3 / Xcode 26.6 toolchain; kernel-route-invariant CB prefill grouping | merged (`0117e6a72`) |
| #1947 | CB/MTP simplification: CB on by default, per-Mac self-check (batched-vs-alone exactness at every granted slot count, net-gain check) picks the served slots; signed CB/MTP policy becomes revocation-only; native MTP model-keyed | in progress (draft PR, Studio re-run and audit) |
| #1944 | Calendar-expiry removal (catalog, native-MTP sidecar, discovery head, autotune feed age); native MTP keeps the last verified revocation set when the feed ages out | merged (`3833ae851`) |
| #1946 | Rollback lever: a Mac on an exactly revoked build may update down to the coordinator-recommended, validly signed release (coordinator path only, never the discovery rail) | in progress: fixing the two R4 MEDIUMs (test coverage; full signed compatibility-id check), then one verification round; rides this release |

Before the cut: run the CLI train's pending one-time `privacy_release_setup` step
(`privacy_class.release_code_identities` on Pearl, #1934), so the new build's
privacy code identity is admitted from signed release metadata instead of a
hand-added cdhash.

Deploy steps this release adds (from the CB/MTP bundle):
- Re-baseline the signed native-MTP challenge bank on the #1927 runtime before the
  coordinator canary runs; otherwise the canary correctly fails native MTP.
- Raise Pearl `pool.max_concurrency_ceiling` (default 8) so a Mac's self-checked
  grant above 8 (the Studio measured 16 for Qwen3.6) is routed in full.

Release plan:
1. Cut the candidate from `main` after every row above is merged.
2. Studio canary through `cli-release.sh` (`canary_smoke`), with the self-check
   decision read from `/v1/status`. One-off, outside the train: the same
   candidate on one house M1 8GB for about 30 minutes of serving, through the
   proven private-candidate install recipe.
3. Promotion and recommendation bump.
4. The Pearl runtime train for the coordinator side follows (#1944, CB/MTP
   coordinator canary, #1942); see the coordinator release train.

Rollback after promotion (#1946): set the recommendation back to the previous
good version and revoke the bad build exactly through `cli-release.sh`; Macs on
the revoked build update down and serve again. The coordinator signal ships in
the runtime train that follows the CLI release.

## Historical fully documented 207 promotion

| Field | Value |
|---|---|
| Version | **1.8.207** |
| Compat-set id | `Augustas11/macprovider:v1.8.207@d98b74a6a158000dabaecb89d75886b6817e9d0f` |
| Coordinator `target_id` / `latest_binary_version` | `1.8.207` |
| Promotion | Immutable release [v1.8.207](https://github.com/Augustas11/macprovider/releases/tag/v1.8.207), promotion run [36526004611](https://github.com/Augustas11/macprovider/actions/runs/36526004611), final rollout verification run [36529821734](https://github.com/Augustas11/macprovider/actions/runs/36529821734) |
| Public installer / China mirror | `get.malibu.tech/install.sh` matches the released installer at SHA-256 `8a68f82b254023671715dd45f06895b4a552e35430f3afc97ff3d83c69dccde5`; consumer health resolves `v1.8.207`; `download.malibu.tech/releases/latest.json` points to `v1.8.207` and all 24 mirrored assets were byte-compared with GitHub |

## Next CLI candidate — net changes vs 1.8.207

Promotion-ready candidate cut, authorized 2026-10-08, for `v1.8.224`. **Not yet
signed.** [Acceptance run 37743452851](https://github.com/Augustas11/macprovider/actions/runs/37743452851)
at `ac7cfde0516cf69c0e2ce3f919329f9052786202` was cancelled during the unsigned
build (07:37Z), as were the three earlier attempts; no signed 224 bytes and no
tag exist. It was stopped because the checked-in coordinator recommendation
still advertised `1.8.207`, so `scripts/release-staged-version-policy.sh` would
have treated 207 rather than the live stable 223 as the previous stable for the
updater-path checks. The three `latest_binary_version` rows move to `1.8.223`
in the release-train PR; the candidate is then cut from that merged main tip
with `promotion_ready=true` and `strict_post_migration`. Version-only
[#1896](https://github.com/Augustas11/macprovider/pull/1896) carries identity
224. Existing BYOM/privacy source acceptance and unchanged decode qualification
carry forward. Keep the fleet recommendation and compatibility target on 223
until signed-byte installation, buyer-path and promotion gates pass. Native MTP
and CB activation stay in [#1894](https://github.com/Augustas11/macprovider/pull/1894),
which re-binds to the signed 224 identity after this cut.

Backend check for this train: privacy #1871/#1892 change coordinator/gateway
directory, enrollment and grouped model-scope validation. Live runtime223
predates those changes, so the corresponding paired backend runtime needs a
new deployment; identity admission/target config alone cannot ship that code.
BYOM #1895 itself is CLI-only. No backend deployment or privacy activation was
performed by this candidate cut. Follow the existing Pearl rollout ordering
and keep deployment separate from catalog/config activation.

Privacy automatic enrollment [#1871](https://github.com/Augustas11/macprovider/pull/1871)
merged on 2026-10-08 as `d6e8bb2ff370d7368d3a1bb79d28b935bc2a72b6`,
with antfleet-ops approval. Product source `60d97dacf51047e10100622eeba1a093d76b63da`
passed [CI](https://github.com/Augustas11/macprovider/actions/runs/37711353541)
and [spec-index](https://github.com/Augustas11/macprovider/actions/runs/37711353502).
The final `3175f1c7` head differed only by release-train documentation;
the operator explicitly authorized admin merge without repeating CI on that delta.
Source builds for the CLI, coordinator, operator CLI, gateway and buyer client
passed on the designated Studio; final source audit reconciliation was clear.
The signed 16-step baseline and subsequent regression/audit evidence are retained.
These results do not assert signed V2 enrollment acceptance or fleet activation.

Next activation sequence: include the merged enrollment changes in the next
signed CLI train after the remaining in-scope slices land; verify changed
enrollment/directory behavior on Studio; deploy the matching Pearl runtime;
authorize the signed release identity and a current v0.2 activation exception;
configure the signed directory and buyer key distribution; canary private
stream/nonstream traffic under load, then promote and verify eligible-fleet
automatic enrollment, preserving explicit opt-outs. Close #1749 only after
its buyer-path, disclosure, support-matrix and incident criteria are evidenced.
No candidate identity is reserved by this entry. Published CLI 1.8.223 does
not contain these newly merged enrollment changes; updating to 223 alone
does not activate network-wide privacy.

Privacy post-#1895 source acceptance on 2026-10-08: exact combined head
`2329c3ae036477b1c747dcf0cf6c4ab6fc480027` built on the designated Studio
(release 183.68s; debug 18.19s). The release executable SHA-256 is
`7811ceae336ace4ae9160903ce9852bbe3e7508f3b6addbe47d5e533a1bbc8af`.
Both Qwen artifact/catalog model names completed native stream and nonstream
requests from the verified worktree executable. Six isolated encrypted-stack
E2Es passed with no skips in 11.606s: private stream/nonstream, redaction,
automatic enrollment with signed-directory discovery, wrong-directory-key
rejection, and enrollment key-change quarantine. The encrypted cases use the
debug fixture; they are not signed native-runtime acceptance. Live provider
bytes were unchanged, and retained dependency revisions did not change.
An additional local Swift unit-test attempt could not compile because the
Studio Command Line Tools lack XCTest; the executed #1895 Swift CI passed.
These source checks support proceeding to a consolidated promotion-ready
candidate; they do not cut a candidate, authorize production enablement or
replace final signed-identity and changed buyer-path confirmation.

Privacy network activation handback, 2026-10-09 (SPEC-049 §8.3, Related:
#1749). Live changes: the signed CLI 1.8.224 code identity is approved on
production, and eligible 1.8.224 providers enrolled automatically (six
enrolled plus the operator-pinned canary). Buyer confirmation through the
public gateway with the reviewed reference client passed for identity pin and
signed directory, each stream and non-stream; directory-selected private
requests were also served by enrolled Llama providers. Every private request
settled as `relay_blind_settled`; ordinary traffic stayed healthy. Synthetic
load on the canary was paused for 37 seconds for the pin/directory run and
restarted. Findings carried to #1911: reservation selection bound the first
provider for a model regardless of free slots, and private requests lose free
slots to sustained plaintext load. The approval still carries the old dated
expiry until a runtime containing `43180f577` is deployed and the approve
step is rerun.

Privacy activation follow-up [#1892](https://github.com/Augustas11/macprovider/pull/1892)
merged on 2026-10-08 as `394bf61aea689075ac5506c506484cc75168649a`,
with antfleet-ops approval and all checks green. The accepted campaign includes
exact signed-catalog/artifact model scopes, grouped
key-record budget, compatible reservation parsing, bounded rejection reasons,
and reliable isolated-stack migration/bootstrap and executable provenance.
Studio worktree release/debug builds and native stream/nonstream model-name
checks passed; encrypted automatic-enrollment transport fixtures passed.
Linux privacy/backend/updater and repeated real-service boundary checks passed.
Consolidated source `e8c525982` built successfully on the designated Studio;
the complete code, security and architecture audit lanes report 0C/0H/0M.
Final [CI](https://github.com/Augustas11/macprovider/actions/runs/37730968917)
and [spec-index](https://github.com/Augustas11/macprovider/actions/runs/37730968835)
passed without manual reruns.
These separate results are not signed native-runtime or fleet activation.
Reuse the retained signed baseline and unchanged decode qualification; resolve
campaign findings before one reviewed train cut, then confirm the final signed
identity and changed buyer path. No candidate version is reserved here, and
#1749 remains open until private traffic is actually serving on eligible fleet
providers, including new joins.

BYOM completion campaign [#1895](https://github.com/Augustas11/macprovider/pull/1895)
merged normally on 2026-10-08 as `9bb865b823ac7278315846ce4d0ed762994c0084`,
after all 16 checks passed on reviewed head `0e4aead880e6265039474d698bc5f89d55357268`
and antfleet-ops approved that exact head. The complete code, security and
architecture audit lanes were clear. [CI](https://github.com/Augustas11/macprovider/actions/runs/37736012113)
and [spec-index](https://github.com/Augustas11/macprovider/actions/runs/37736012108)
passed. Pool-only GGUF startup can use bounded advisory upstream counts when
there is no signed sibling tokenizer; pinned recount, identity checks and the
production floor remain enforced where applicable. Protected-file credential
custody no longer blocks a positively proven consumer-user GUI updater;
headless/system and ambiguous topology remain denied.

On the designated Studio, the isolated source release build passed. That exact
source served Ollama without joining the coordinator: startup measured
13.0164 TPS, bounded nonstream output and streaming content with `[DONE]`
passed. This is local source evidence, not signed-candidate paid acceptance.
No new CLI was cut by this merge. #1690 remains 2/6 actually complete despite
its closed GitHub state: updated signed-candidate Ollama paid acceptance,
supported previous-stable installation/restart, formal mixed rollout/rollback,
and final acceptance/conformance reconciliation are still pending. Reuse the
existing release and acceptance paths; no new harness or signing tooling is
required by this campaign.

Private signed compatibility set
`Augustas11/macprovider:v1.8.212@d806dcf203a94f813aadbe458c8de578be476bd0`
was produced by acceptance run [37075501296](https://github.com/Augustas11/macprovider/actions/runs/37075501296)
under workflow control commit `dac2ab8df6d1acd7bf54df61b2a604ac609780a4`,
but is superseded: it predates the operator-pause lifecycle fix and is not
promotion-ready. The final **v1.8.213** promotion-ready private compatibility
set `Augustas11/macprovider:v1.8.213@8b2d857f2e47c5b783b1e9caa876ea41a8f653e1`
was signed, notarized, and stapled by acceptance run
[37092159775](https://github.com/Augustas11/macprovider/actions/runs/37092159775).
Independent exact-set, code-signature, notarization, stapling, Gatekeeper, and
embedded/standalone CLI byte-identity checks passed. Promotion verification for
the release-bound continuous-batching policy pair was corrected by #1838 and
replayed successfully against those exact accepted bytes. Physical acceptance
passed on the designated M3 Ultra Studio on 2026-10-03: the exact signed CLI
(`9ee225a55ae1f1a54c66cde5a53c45bad8a7c4b470c2f9e4e859391d12aa0ecc`)
replaced 1.8.207 through the established payload-only swap while preserving the
operator config and launchd definitions; Pearl accepted the exact private set
without changing its 1.8.207 target or recommendation; the provider joined as
`serving_buyers`; operator pause was acknowledged and survived a full
provider/watchdog restart; resume restored buyer serving; and a bounded local
Qwen3.6 request completed successfully. The Pearl relay and buyer runner were
then restored. The candidate remains unpromoted, untagged publicly, and
unpublished. Runtime tag `v1.8.211` and private candidate identity `v1.8.212`
are consumed and must not be reused.

| Net change in CLI / Malibu / installer | Status | PR |
|---|---|---|
| Pool model status names the qualifying pool and says eligible to earn only on qualifying settled requests. Malibu clears stale positive bindings when status readback is unavailable, inactive, or mismatched; eligibility wording does not claim current paid work or income. | merged `00700349b` 2026-10-07; awaiting a reviewed signed CLI/app release | [#1883](https://github.com/Augustas11/macprovider/pull/1883) ([#1880](https://github.com/Augustas11/macprovider/issues/1880)) |
| Automatic privacy-class eligibility and enrollment, preserving explicit opt-out and refusing ineligible posture; fleet availability still requires signed-release acceptance, approved identity, directory configuration and staged rollout. | merged `d6e8bb2ff` 2026-10-08; not yet released or activated fleet-wide | [#1871](https://github.com/Augustas11/macprovider/pull/1871) (#1749) |
| Exact catalog/artifact privacy model scopes share one signed key record; reservation parsers accept grouped scopes while keeping exact request binding. Bounded rejection diagnostics and isolated-stack bootstrap/provenance fixes complete the source campaign. | merged `394bf61ae` 2026-10-08; source accepted, signed identity and live activation pending | [#1892](https://github.com/Augustas11/macprovider/pull/1892) (#1749) |
| Pool-only GGUF advisory startup TPS without a catalog sibling, and protected-file consumer GUI updater/recovery under positively proven topology. Money-path counting and headless/system restrictions are unchanged. | merged `9bb865b82` 2026-10-08; isolated Studio source smoke passed, signed-candidate acceptance pending | [#1895](https://github.com/Augustas11/macprovider/pull/1895) (#1690) |
| Operator pause remains authoritative when coordinator drain first moves the provider to `network_offline` or `coordinator_unavailable`; only the operator command may write those pause transitions. | merged `9384e5280` 2026-10-03 | #1834 (#1770) |
| Qwen3.6 35B-A3B ordinary decode uses the fused A3B MoE kernels (fork pin `Augustas11/mlx-swift-lm@b1811029`): decode and verify rows of at most 7 tokens stay fused at any batch size in chunks of at most 7, prefill stays on the stock kernel, and exact per-tensor layout validation gates the path. Studio qualification: ordinary decode 1.25x / 1.15x / 0.97x vs stock at 1 / 2 / 8 rows, 0 parity mismatches in 36 paired blocks, bit-identical run to run. `MLX_LM_QWEN35_FUSED_MOE=0` disables it. `KVBuildIdentity` changes, so prior KV cold-tier entries miss once. Native MTP stays default-off; the native-MTP lab tooling is compiled only under `DEBUG \|\| MACPROVIDER_LAB_HARNESS`, and signed R024 `proposal_depth` is capped at 6. | merged `280f0e95d` 2026-10-05 | #1832 (#1770) |
| Privacy-class work settles under production `enforce`: a relay-blind route snapshot, a provider-signed content-free `relay-blind-settlement-v1` receipt, and the `relay_blind_settled` outcome, which is never `verified`. The provider withholds the receipt on any unvalidated usage or frame failure. | merged `d4d73c253` 2026-10-05 | #1853 (#1749) |
| Privacy posture challenges and all frames are sent only after the provider handshake ack. | merged `e03a7cb9e` 2026-10-05 | #1852 (#1749) |
| Operator-constrained privacy class (SPEC-049) ships default-off as a Beta: providers advertise it only under verified operator posture, and the coordinator kill switch and revocation survive restart. Physical acceptance is the #1839 journey. | merged `07d5b0d3a` 2026-10-04 | #1846 (#1749) |
| Privacy-class audit follow-ups: the test-only privacy fixture is compiled out of release builds and relay opacity is enforced. | merged `cbb632b33` 2026-10-04 | #1847 (#1749) |
| Release metadata carries the signed provider CLI code identity (`provider_code_identity` in `pearl-release.json`), required from 1.8.214; it feeds SPEC-049 approved code identities. | merged `04ee6e6a6` 2026-10-04 | #1848 (#1842) |
| The promoter accepts the release-bound continuous-batching policy pair as exact accepted bytes. | merged `f4d80c273` 2026-10-03 | #1838 |
| Non-hybrid continuous batching reports sampled tokens to the scheduler per decode step instead of delivering 16-token lockstep-window bursts, while block release and terminal completion remain hop-boundary operations. | merged `f096d7320` 2026-10-02 | #1828 |
| SwiftNIO is updated from 2.101.3 to 2.103.0. | merged `90c1ab060` 2026-10-02 | #1827 |
| swift-jinja is updated from 2.4.2 to 2.5.1. | merged `e797059c3` 2026-10-02 | #1826 |
| Native MTP is production-reachable only through exact signed artifact, admission, load, batching, and fail-closed serving gates; the feature remains default-off pending the formal campaign. | merged `b29b7b8f5` 2026-10-02 | #1820 (#1770) |
| Hybrid recurrent-cache reuse captures exact canonical reply-end checkpoints and fails closed when serial natural EOS has advanced beyond the publishable token state. | merged `65ee6791a` 2026-10-01 | #1819 |
| Native MLX serving rejects unsupported non-zero presence/frequency penalties instead of accepting no-op buyer controls, and balances long prefill spans. | merged `2b1de5040` 2026-10-01 | #1818 |
| The proven gpt-oss 120B mixed sliding-window paged-KV topology is admitted only for its exact measured identity, configuration, topology, and fresh-probe evidence. | merged `b01da4940` 2026-10-01 | #1815 |
| Pool-authorized loopback streaming receipts now bind `normal_done` output hashes to the buyer-delivered byte snapshot only. Complete receipts fail closed when the relay cannot prove every accepted frame was sent, final content is not byte-exact with delivered UTF-8 bytes, or post-tool-call content was suppressed after tool calls opened. | merged `d700ab749` 2026-10-01 | #1814 (#1787) |
| Rotating-window parity measurement follows upstream cache presentation without broadening production admission. | merged `a736d2b94` 2026-10-01 | #1813 |
| Autotune matched-floor recommendations now use verified artifact bytes as the residency authority when local artifact facts are available, instead of treating catalog `min_ram_gb` as the model-size truth. Recommend/apply/adoption/warm-switch/live-facts paths now preserve R018 context while capping slots from measured bytes, with recursive artifact byte accounting and checked KV arithmetic. | merged `427f24d15` 2026-10-01 | #1811 (#1794) |
| Production continuous batching requires a signed release policy; the shipped policy remains empty until packaged Studio evidence authorizes exact tuples. | merged `b55463f6f` 2026-09-30 | #1803 (#1778) |
| An unset paged-KV pool now covers the provider's advertised maximum context instead of silently rejecting requests above the former 16K default; explicit operator values remain unchanged. | merged `1b504306a` 2026-09-30 | #1802 |
| Continuous-batch rows stay inside the buyer's authenticated reserved-output budget. Gateway reserved-output metadata now flows through coordinator HTTP, clear WebSocket, and Tier-2 dispatch without rewriting the request body or receipt prompt hash; prompt-at-cap and output-overflow failures return terminal buyer 413 responses with no retry, failover, breaker fault, credit, or debit. Hardware campaign used an isolated `--no-join` Studio provider and did not connect a local build to live Malibu. | merged `9eb1553b` 2026-09-30 | #1806 |
| Signed-policy hybrid-cache admission accepts the measured `mixed` cache identity. The isolated source-built Studio campaign passed automatic policy activation, local proof, paged-KV attach, batch depth 4, and scheduler-admitted HTTP 200s for Qwen3.5 27B and Qwen3.5 35B-A3B. This evidence is prequalification only: production policy remains empty and the source-built candidate was never connected to live Malibu. | merged `1c7041800` 2026-09-30 | #1808 (#1778) |
| Recurrent-hybrid isolation verification now mirrors the production full-prompt `TokenIterator` lifecycle. On the designated M3 Ultra Studio, the isolated verifier-only candidate passed exact 48-token, two-row shared-forward parity, unequal-row isolation, peer leave/rejoin, and paged-KV attach eligibility for Qwen3.5 27B, Qwen3.5 35B-A3B, and Qwen3.8 27B. All required CI checks and the adversarial/code/security/architecture audits passed. | merged `6d1810506` 2026-09-30 | #1809 (#1778) |
| Autotune artifact downloads now fail before transfer when the temporary or destination filesystem cannot safely hold the model, with bounded size discovery, reserved-space admission, and cleanup coverage. | merged `621928aeb` 2026-09-30 | #1796 |
| Connected providers now run under `caffeinate -ims`: macOS may sleep the display while system idle sleep remains inhibited for serving. Lid-close and reconnect caveats remain explicit. | merged `acc9d087d` 2026-09-30 | #1798 |
| Malibu onboarding now shows the current autotune model and bounded progress from a sanitized process probe and paid-yield output, without exposing raw subprocess text. | merged `1f03be5cf` 2026-09-30 | #1799 |
| The public uninstaller now fails closed around transaction locking and service-state proof, removes the full installed surface, and preserves only the exact lifecycle tombstone required for recovery. | merged `25dbe1f8c` 2026-09-30 | #1797 |

## Shipped CLI 1.8.207 — net changes vs 1.8.123

Candidate **207** was promoted from exact accepted commit `d98b74a6` on
2026-09-29. The Studio serving canary now runs the signed public 207 payload
with `qwen/qwen3.6-35b-a3b`, and Pearl recommends compatibility set 207.
Private candidate 202 was removed from the accepted set after the 207 cut.
(Since SPEC-002-R004, 117 and 123 are not in the live allowlist and are in
the one-time revocation seed: they connect update-only and auto-update.)


| Net change in CLI / Malibu / installer | Status | PR |
|---|---|---|
| Baked OpenRouter priced catalog + GLM served-id rate rewrite | merged | #1612 (#1603 listed bake) |
| Uncatalogued BYOM loopback serve holds WS instead of self-flapping | merged | #1609 |
| Serve stays connected while BYOM admission is pending | merged | #1557 |
| MLX `models offer` sends snapshot hash (catalog-match works) | merged | #1548 |
| Malibu shows BYOM admission states | merged | #1497 |
| Discover OpenAI-compatible loopback models | merged | #1457 |
| Discover LM Studio and llama.cpp loopback models | merged | #1480 |
| CLI uses catalog artifact feed (baked fallback) | merged | #1468 |
| GGUF file identity hash (does not make Ollama earn) | merged | #1469 |
| BYOM offer-submit can be disabled | merged | #1448 |
| 16 GB Macs get Llama 3.1 8B, not 3B, from recommend | merged | #1488 |
| Headless Mini install + system-domain uninstall | merged | #1494 |
| First-install no longer false `rollback_failed` | merged | #1443 |
| Sparkle public key only on the v1.8.39 bridge build | merged | #1450 |
| Prepare/stage catalog artifacts without turning them on | merged | #1525 #1530 #1533 |
| Storage / Build 1 prep stays private until activation | merged | #1504 #1506 #1507 #1510 #1519 #1525 |
| SPEC-038 attach needs measured runtime evidence | merged | #1502 |
| SPEC-039 attach without sticky reattach | merged | #1475 |
| FR-PKV10 extract exists; serving still off | merged | #1476 |
| Paged KV sticky billing parity | merged | #1489 |
| Reward eligibility not claimed from the wrong state | merged | #1466 (`422fc2f1`) |
| Relay-blind encryption pilot for buyer prompt/content, default off | merged | #1467 |
| Pricing metadata only from validated endpoints | merged | #1455 |
| Security fixes F05–F11 across wallet and provider update boundaries | merged | #1454 |
| Signed conformance evidence path made reproducible and protectable (#1433) | merged | #1459 |
| OpenRouter slot-delta / stale-capacity routing on CLI path | merged | #1571 #1535 |
| Installer 404 fix: paginate latest-release lookup, de-quadratic parser | merged | #1582 (#1574) |
| Live Ollama serve + Gemma tokens (non-earning) | merged | #1576 (#1569) |
| Drop independent 256-message chat cap | merged | #1595 (#1594) |
| Concat-safe native tool-call streaming (hold XML args until `</function>`) | merged | #1596 |
| Recover inner Qwen function-XML when `</tool_call>` is missing | merged | #1599 |
| Fresh-Mac install bootstraps pinned python3 instead of CLT GUI die 8 | merged | #1610 (#1575) |
| SPEC-038 on-device parity + MoE-isolation self-measurement | merged | #1591 |
| Paged-KV attach gates so SPEC-038/039 can engage on real MoE hardware | merged | #1597 |
| Opt-in empirical max_batch concurrency calibration | merged | #1590 |
| Qwen hybrid JSON tool_call recovery, concat-safe prefixes, follow-up content deltas | merged | #1626 |
| Conversation-keyed serial serve allocates trimmable `KVCacheSimple` (FR-CI2 can skip prefill) | merged | #1634 |
| SPEC-038 scheduler uses compiled lockstep decode windows (buyer CB still off) | merged | #1635 |
| FR-CB15 leftover harness (MSB-03/05, usage, isolation, drain, replay) + MoE promotion review (flag stays false) | merged | #1640 |
| Qwen leftover `</tool_call>` after a valid tool JSON must not kill the stream | merged | #1653 |
| Login keychain for KV disk DEKs (naked CLI can persist KVS-01a) | merged | #1648 |
| SPEC-038 AC-23 MoE promotion evidence available on production scheduler (buyer CB still off) | merged | #1650 |
| Sanitized reason-coded stderr on CB prefill fail-close (buyer API stays generic 503) | merged | #1656 |
| Studio CB serve-path: accept bfloat16 KV + per-row compiled writeback (isolated 18080 HTTP 200; buyer CB still off) | merged | #1661 |
| Stop serial Qwen tool turns after the first complete valid call (omitted/`false` `parallel_tool_calls`; leftover markup must not hang) | merged | #1662 |
| Keep CB canary streams alive past the first lockstep hop | merged | #1665 |
| Pearl keyed first-turn chats enter Studio CB canary (positive cache hits stay serial until AC-26) | merged | #1666 |
| SPEC-038 FR-CB10 per-tuple acceptance coverage enforced fail-closed (see precondition below before cutting) | merged | #1672 |
| SPEC-038 FR-CB6 accepts batched-vs-serial numeric ties so MoE CB can attach | merged | #1608 |
| install.sh: fresh-install paid-yield recommend is resumable, visible, and bounded | merged | #1613 (#1605) |
| Admit `gpt_oss` only behind SPEC-039 proof gates | merged | #1617 |
| install.sh: unblock provider recovery after catalog and evidence retries | merged | #1620 |
| Prove CB scales on M3 Ultra via compiled contiguous decode (MSB command) | merged | #1623 |
| install.sh: keep pool-ready providers alive during admission lag | merged | #1625 |
| install.sh: fail SSH installs before inaccessible Keychain work | merged | #1627 |
| install.sh: preserve hardware-evidence retry guidance before rollback | merged | #1631 |
| Stage Lane A artifact preparation path | merged | #1649 |
| Build 1 Lane A private OrcaRouter/Qwen staging path: signed complete-revision authority, durable private preparation, scoped 4-bit runtime binding, isolated staging admission, and correlated route/receipt/settlement evidence. Staging-only: no public-catalog publication, production activation, payout, or automatic paid-provider qualification. | merged `3ec784c69` | #1658 (#1642) |
| Raise FR-KVP9 promotion hard ceiling to 1 GiB for KVS-01b | merged | #1655 |
| Close proved #1616 recovery-hardening gaps (installed identity, buyer-serving reason, evidence record, dangling launchd repair) | merged | #1668 |
| Drop slot reservation once the Mac has the chat | merged | #1670 |
| Keep four seats admitting four chats after a late Mac busy report | merged | #1674 |
| Correct Qwen3.6 artifact identity so providers can use the signed row (catalog) | merged | #1686 |
| Stop loopback runtimes from signing settlement receipts | merged | #1707 (#1695) |
| Provider WebSocket relay admission follows advertised seats and warm swaps | merged | #1687 |
| Refresh embedded Tier-2 identity/catalog bindings for the current model set | merged | #1692 |
| Disable optional template thinking for final-answer mode by loaded-artifact capability | merged | #1700 |
| Running provider refreshes its signed catalog envelope on `catalog_incompatible` or a newer hello ack and adopts it only for the same served row identity (no Malibu restart after a content cut). Compatibility-set rejections keep their own reason. Malibu/CLI status says "Catalog refresh needed", not "software update required" | merged `3abf42a8` | #1714 (#1705) |
| Qwen3.6 continuous batching (greedy rows): batched-output fixes (frozen compiled-decode offset, end-of-turn stops, drain-race hang, ragged rows, per-window host KV copy), Qwen3.6 hybrid cache (#1731), AC-25 lifecycle codes plus bounded admission wait, CB queue pressure relayed as `error_queue_full`, `mlx_cache_limit_mb`, revision-bound FR-CB10 acceptance (`metallib_sha256`, `kernel_identifier`). Default off; live on the Studio as `v1.8.192` | merged `36946873` | #1716 (#1646) |
| Continuous batching follow-ups: batched sampled rows (AC-6b), Qwen3.6 hybrid cache reuse and batched cached turns (AC-26, flag off by default), in-place paged KV (steady 1.5k × 4 decode 43 → 65 tok/s), bounded decode window while prefilling, provider LaunchAgent `ProcessType` `Standard` (single-stream decode 22 → 38 tok/s). Studio candidate `v1.8.195` | merged `03627cda` | #1742 (#1646) |
| Continuous-batching qualification closeout: AC-25 receipt and warm-swap lifecycle coverage, durable replay proof, falsifiable Gate A5 counter-evidence, and modeled promotion economics. Production default remains off because Gate A5 did not converge. | merged `0197f379` | #1757 (#1646) |
| China supply path: release self-update mirror, pinned Python bootstrap mirror, content-addressed model mirror/import verification, sanitized rejected-mirror diagnostics, and signed-manifest transfer bounds. The production Qwen3 8B origin is seeded; the reviewed signed Darwin release, public installer/release mirror, and #1756 mainland hardware run remain gates. | merged `ddaa551b` | #1745 (#1737, #1756) |
| Malibu app credential handoff no longer races stdout capture. | in progress | #1747 |
| Signed provider release discovery pages past newer Pearl-only releases instead of treating the newest repository tag as the CLI release; client, verifier, and freshness alarm share bounded pagination and UInt64 transport-sequence semantics. | merged `9636a125` | #1753 (#1737, #1756) |
| Engine-agnostic serving on Trusted Pools (#1690), provider side: SPEC-015 0.4.10 pool-authorized loopback receipts (`PoolRuntimeAuthorization`, receipt eligibility), llama.cpp / Ollama / mlx_lm.server loopback runtimes with engine selection, delivered-only accounting, and lab e2e fixes: a llama.cpp buyer disconnect ends with a `buyer_cancel` receipt over the delivered prefix (E2E-F3); rotate-key swaps the signing key the process actually uses (E2E-F9, pre-existing); native streams stay byte-identical to the receipt across split UTF-8 characters (E2E-F13, pre-existing). | merged `747557cc` 2026-09-25 | #1719 (#1690) |
| #1690 follow-up, provider side: the CLI consumes the SPEC-023 v0.19.1 GGUF `huggingface_revision` + `file_path` artifact tuple (older CLIs reject a feed that carries it); LM Studio (`lmstudio_loopback`) and oMLX (`omlx_loopback`) runtimes and engine-select values; cancelled-stream billing on every external engine (per-chunk logprobs/timings or a tokenizer pinned to the hash-verified snapshot, inside the coordinator's 2 s cancel window; a streamed tool call stays unattested); catalog source gains the Llama-3.2-3B `gguf-q4-k-m` artifact and 17 measured MLX sizes (catalog-lane JSON; activation is a separate signed cut). | merged `8d1880bc` 2026-09-27 | #1754 (#1690) |
| Compatible-row batched prefill with bounded prompt/decode headroom. Release eligibility remains gated on the isolated Studio campaign. | merged `95a6563d` | #1762 (#1758) |
| Exact hybrid continuous batching for `qwen/qwen3.5-27b`, `qwen/qwen3.5-35b-a3b`, and `qwen/qwen3.8-27b`: full-prompt commitment with first-token sampling from final-prefill logits, production 512-token prefill partition, one-token hybrid decode lockstep, and a 48-token load-time shared-forward parity gate. Studio campaign passed exact L511/L512/L513 parity, leftovers isolation/replay/drain/usage gates, and rows=8 throughput at 1.807× / 2.471× / 1.817× serial. | merged `38229a8c3` 2026-09-28 | #1776 (#1773) |
| Page keep-0 sliding-window layers with a windowed mask so mixed RotatingKV (gpt-oss) can use paged KV. Compiled decode stays off for sliding. Production attach and the Qwen hybrid allowlist stay fail-closed until Studio parity. | merged `5c09c5c9a` 2026-09-29 | #1785 (#1780) |
| Node-operator UX (#1689): honest `status --advanced` (readiness layers, probe-vs-sustained TPS, context source); `provider verify` bound to the live coordinator; `provider context explain | set --apply | rollback --no-restart` with installed-service-aware restart; 4K context fix (declared head_dim / hybrid layers) with context × slots memory bound and draft cap; in-config `max_context_override_provenance`; model-switch recompute; `models verify-artifact | identity | prepare --profile catalog`; CLI holds through coordinator `catalog_material_missing`. Studio lab E2E rounds 1–4 PASS. Operators with a stored 4K recommendation need a fresh `autotune --recommend`. Coordinator side (SPEC-022 R-2.7, `/poolz` gate) ships with the next Pearl runtime ≥ v1.8.193 | merged `57686a84` | #1713 (#1689) |
| BYOM v0.2 slice 2a: catalog artifact feed generator, class rate rows, ledger v3 (catalog sources only, no Swift changes) | merged | #1461 (#1453) |
| Ship catalog content release without a Pearl runtime cut (`not-buyer-serving.json` only, catalog-lane; binary unchanged) | merged | #1706 (#1688) |

Catalog-json-only rule: rule 1 above ("a PR that changes `phase3-binary/`
merges → add one row") is a path rule, not a compiled-binary rule, so a PR
that only touches JSON sources under `phase3-binary/catalog/` still gets a
row even though it does not change the Swift binary the fleet runs; #1461 and
#1706 are rows on that basis, each noted as catalog-only above.

#1658 is a compiled provider-CLI change and therefore belongs on this train,
but its physical proof is deliberately staging-only. The committed evidence
records staging commit `58ea66f17ac3a057c2f8cd3112f92226ae989101`; merged source
`3ec784c6977bdbb8367dd29b0866b60393c5011a` passed the full GitHub matrix and
three-lane audit but was not represented as a physically rerun binary. Its
private OrcaRouter/Qwen tuple remains absent from the public catalog and does
not by itself make the next CLI promotable.

#1453 is **CLOSED** (2026-09-19); it does not gate a future promotion. #1569
is a later CLI. Spec promotion #1583 is not a CLI change.

Historical pre-207 record: coordinator/gateway on live Pearl was **v1.8.191**
@ `98e3e4af` (including #1728), fleet Macs and the coordinator recommendation
were on provider binary **1.8.123**, and the Studio served signed private
candidate **195**. That campaign was not a fleet-promotion authority.

#1632 / #1638 / #1639 (coordinator leftover rewrite + gateway R014) are
coordinator/gateway, not CLI rows. #1653 **is** a CLI row (above); its
`InferenceRelay` drop is in `v1.8.174`.

#1600 is the install.sh consumer-health alarm
(scripts/CI), not the Mac binary. Curl-channel `get.malibu.tech/install.sh`
was republished **from `main`** on 2026-09-19 after #1610 (SHA-256
`c90fb44d9a780041233928f4376d7d92b71af087d034ae44c3a275fd9381d7c4`, pearl
backup `install.sh.bak-20260919T121720Z`) so `curl | bash` already had #1582
pagination and the #1575/#1610 CLT-stub bootstrap. At that point consumer
health was green against fleet **v1.8.123**, while the parity alarm remained
red until the successor stable tag carried matching installer bytes. Current
public 1.8.207 parity and mirror status are recorded in “Current promoted
stable” above.

`install.sh` on `main` has moved past served bytes: #1613, #1620, #1625,
#1627, #1631, and #1745 all touch `phase3-binary/dist/install.sh` after the
2026-09-19 republish and are **not** in the served `c90fb44d…` bytes. As of
2026-09-27, the public installer still has SHA-256
`c90fb44d9a780041233928f4376d7d92b71af087d034ae44c3a275fd9381d7c4`
and contains none of the #1745 release-mirror, Python-mirror, or
`download.malibu.tech` markers. Do not assume the curl-channel one-liner
carries them until the next republish.

### China supply state after #1745

The production Qwen3 8B model origin is live as of 2026-09-27. PR #1745
merged as `ddaa551b24731ee8be3f92782b6ebb236ff4513e`; Malibu route PR #133
merged as `ec82f738ffe512994dc242512930991856a2d0d1`; and
`models.malibu.tech` resolves to `76.76.21.21` with valid Vercel TLS. The
content-addressed snapshot for
`mlx-community/Qwen3-8B-4bit@545dc4251c05440727734bcd94334791f6ab0192`
is published at signed model hash
`1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877`.
All 11 payload sizes match the signed manifest, every non-weight payload was
downloaded and hash-checked, and the full 4,607,835,174-byte public weights
object streamed with SHA-256
`f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8`.

This closes only the production model-origin blocker. Public release
`v1.8.200` has Linux Pearl assets only; it has no signed Darwin provider CLI.
`download.malibu.tech/releases/` and
`download.malibu.tech/releases/v1.8.200/checksums.txt` return 404. Do not call
the China supply track green until a reviewed signed post-#1745 CLI and its
installer/release mirror are published and #1756 passes from a clean mainland
Mac with the prohibited resolver boundary active.

### Continuous-batching continuity before candidate promotion or upgrade

SPEC-038 FR-CB10 requires exact signed-policy coverage for coordinator-joined
serving. Since #1803 (`b55463f6f`), `continuous_batching_accepted_tuples` is
an isolated `--no-join` test input; it cannot authorize production batching.
Keeping `continuous_batching: canary` in configuration is insufficient.

Before recommending or installing successor bytes, preserve each previously
active qualified hardware/model/cache tuple. Publish reviewed policy coverage
for the successor's exact provider version, live executable CDHash, package
manifest and campaign evidence before the successor is recommended. Reuse
unchanged decode qualification; never copy an old CDHash grant to new bytes.
An empty policy, rollout `off`, or identity mismatch is a capability loss,
even when feed signature verification and provider join succeed.

After the signed upgrade and restart, verify `policy.load_status=live_verified`,
`policy.authorized=true`, `policy.local_proof_result=passed`,
`paged_kv_decision=attached`, and `active=true`, then confirm a scheduler-admitted
serving request through the Malibu gateway. Ready/connected alone is insufficient.
An intentional disable requires an explicit reviewed operator decision; do not
silently reinterpret missing coverage as intentional. See
[the signed-policy enable gate](../runbooks/continuous-batching-enable-gate.md)
and [the regression investigation](../runbooks/continuous-batching-upgrade-continuity.md).

## Active candidate

Shared-namespace update (2026-10-07): runtime **v1.8.221** carries the deployed
#1874 settlement fixes. Provider **v1.8.222** is a signed private acceptance
candidate serving the #1690 pool members, not a public stable release. Provider
**v1.8.217** remains published and the fleet recommendation remains **v1.8.207**.
Refresh both release trains and remote tags before reserving another shared
identity; this status update does not allocate a successor version.

| Field | Value |
|---|---|
| Private acceptance candidate | **v1.8.222** (Malibu build 222), signed from reviewed-main source `7e68120b8ac0b92e8291a990c88b40f55bafcf5a`, acceptance run [37493026731](https://github.com/Augustas11/macprovider/actions/runs/37493026731). The serving pool-member CLI matches the packaged standalone SHA-256 `fc3e54691585a0b0fa9509225fcac51ae89b6dba10f172a2f098f271b94bedcc`. It carries #1874's Trusted Pool cancel-receipt fixes and passed the fresh 11-step production external-runtime capture. It predates #1879's reviewed startup-tokenizer fix; no public release, fleet promotion, or successor-candidate packaging/updater acceptance is claimed. See [the closeout evidence](../../audits/2026-10-07-1690-closeout/README.md). |
| Historical 217 acceptance set | Then-private **v1.8.217** compatibility set `Augustas11/macprovider:v1.8.217@71f22d36c3ef11c99d3572f63bb0283f73f19aa5`, acceptance run [37389822832](https://github.com/Augustas11/macprovider/actions/runs/37389822832) (signed 2026-10-06 00:27Z), candidate/control commit `71f22d36c`, `checksums.txt` SHA-256 `f2e83cd76834b946ec209dad5a19ba88ad677d951fd5b33e96890525f7e9d2be`. Independently verified: every `checksums.txt` entry matches, the standalone CLI passes strict `codesign` verification and reports `1.8.217`, the DMG is stapled and Gatekeeper-accepted as Notarized Developer ID, and the embedded and standalone `macprovider-cli` are byte-identical (SHA-256 `a6ea51d7ad19359a21fac63995194523264035fbca2ab32dceeede9d9da739bb`). Subsequently installed and published; see the serving-canary and promotion rows below. The private acceptance set expired 2026-10-07 00:27Z and is not a successor promotion candidate. Previous build v1.8.215 (run [37305423870](https://github.com/Augustas11/macprovider/actions/runs/37305423870)) was superseded before promotion because it predates #1832. Fleet-recommended candidate remains **v1.8.207** @ `d98b74a6a`. |
| Mac Studio serving canary | Signed public **217** @ `71f22d36c`, swapped in 2026-10-06 04:03–04:05Z through the established payload-only operator swap (config and LaunchAgents byte-identical; 213 payload kept at `/Users/a1/macprovider.pre-217-20261006T040351Z`). It serves `qwen/qwen3.6-35b-a3b` on the fused A3B MoE path (kill switch unset), joins under the 217 compatibility set on the 10-01 catalog, and resolves the signed CB policy (`live_verified`, zero entries, so CB stays off by policy). Buyer path down about 2m11s. |
| Off-train E2E candidate | `v1.8.167` @ `7f833a2f63ddee6b2e146c821341099d89aec169` ([run 35417249468](https://github.com/Augustas11/macprovider/actions/runs/35417249468)) — signed hold-branch CLI used for the 2026-09-19 Pearl Track B run |
| Older | `v1.8.163` @ `8c0c51d2`; `v1.8.164` @ `eb30981c` (BYOM #1576 `cdbb0257` + #1591 + #1590 + #1593); CLI artifact `v1.8.166` @ `00ce3625` (not the Pearl runtime tag); CLI `v1.8.172` @ `c512d342`; CLI `v1.8.174` @ `0c276ebb`; CLI `v1.8.175` @ `d02798db` |
| Status | **207 promoted and live; 212 superseded without launch; 213 physically accepted but superseded without promotion by operator decision on 2026-10-04; 214 cut and journey-accepted but superseded without promotion on 2026-10-05, because relay-blind work was refused under production settlement `enforce` until #1853; 215 cut on 2026-10-05 but superseded without promotion because it predates #1832.** Pearl `target_id` and `latest_binary_version` remain 207. Public installer parity, consumer health, mirror byte identity, signed discovery rollout, Studio join, and a bounded real-buyer response are green for 207. |
| Consumed identities | Runtime identities through **v1.8.221** and provider candidates through **v1.8.222** are consumed/reserved. The private 222 candidate must not be reused for the later #1879 source. Runtime **v1.8.220** was signed at `6d49a4f16` by [run 37468267969](https://github.com/Augustas11/macprovider/actions/runs/37468267969); deployed runtime 221 and private provider 222 are recorded in the [#1690 evidence](../../audits/2026-10-07-1690-closeout/README.md). Refresh both trains and remote tags before reserving the next number. |
| Promotion candidate | **v1.8.217 is published** (immutable release [v1.8.217](https://github.com/Augustas11/macprovider/releases/tag/v1.8.217), promotion run [37412526946](https://github.com/Augustas11/macprovider/actions/runs/37412526946), published 2026-10-06 04:14:52Z). Verified after publication: `checksums.txt` SHA-256 `f2e83cd7…` equals the signed set, the tarball and DMG `macprovider-cli` are byte-identical (`a6ea51d7…`), download.malibu.tech serves identical tarball and checksums, and `get.malibu.tech/install.sh` matches `phase3-binary/dist/install.sh`. Physical acceptance: fused e2e on the signed binary (fused vs stock, batch invariance, cancellation, memory, kill switch) and the Studio install/join smoke above. **Operator decision 2026-10-06: the fleet recommendation stays on 1.8.207** (Pearl `target_id` / `latest_binary_version` unchanged, mirror `latest.json` stays v1.8.207). The next CLI candidate bundles the native-MTP step-overhead fixes (branch `mtp/step-overhead`, gated on a new R015) with the #1690 CLI fixes (branch `fix/1690-loopback-startup-throughput`), and that candidate is the one recommended to the fleet. |
| Candidate 202 CB-canary confirmation (2026-09-28) | Isolated Studio loopback serve of the **signed** 202 binary (`--no-join`, ephemeral id, :8092, live :8080/201 untouched) confirmed `qwen/qwen3.6-35b-a3b` **paged-KV attach eligible** (runtime parity `established=true`, cross-row MoE isolation `proven=true`) and a keyless **scheduler-admitted batched 200** with a stable `X-Request-ID` (`event=batching_admitted action=scheduler_admitted`), hash `3fed776d…`. Measured throughput (harness, v1.8.201 same source): 2.86× aggregate vs serial at 8 rows, bit-exact parity. On candidate 202 the qwen3.5/qwen3.8 hybrids fail parity and are excluded; #1776 fixes them only in the deferred successor candidate. Buyer `continuous_batching` was already canary in live config; the 201→202 serving swap (operator-tools/swap-202.sh, 2026-09-28) made 202 the live Studio provider — a3b now served BATCHED (scheduler_admitted) at ~2.86x. |
| Notable merges after candidate 186 | #1707 (`5ada77e1`, CLI); #1714 (`3abf42a8`, CLI + Malibu); #1706 (`2b352720`, catalog-lane file only — binary unchanged); #1713 (`57686a84`, node-operator UX — shipped in `v1.8.192`); #1742 (`03627cda`, shipped in Studio candidate `v1.8.195`); #1757 (`0197f379`, CB qualification closeout); #1745 (`ddaa551b`, China supply path); #1762 (`95a6563d`, batched prefill); #1658 (`3ec784c69`, Build 1 private staging path); #1753 (`9636a125`, signed provider-release discovery, merged after candidate 201); #1771 (`e29ea2976`, Qwen3.6 MoE paged-KV admission, shipped in candidate 202); #1776 (`38229a8c3`, Qwen3.5/Qwen3.8 exact CB parity, merged after candidate 202); #1785 (`5c09c5c9a`, keep-0 sliding-window paged KV, merged after candidate 202); #1808 (`1c7041800`, mixed-cache signed-policy admission); #1809 (`6d1810506`, recurrent-hybrid verifier lifecycle). Coordinator/gateway settlement recovery continued separately through #1728, live in Pearl runtime `v1.8.191`. |
| Why candidate 186 exists | Prove #1700 final-answer rendering, strict-pinned buyer quality, eight-seat routing, and durable settlement on one signed Studio-only build (soak proof; live seats since reduced to one — see Mac Studio serving canary above). |

### #1690 merged source and remaining release gates (2026-10-08)

[PR #1879](https://github.com/Augustas11/macprovider/pull/1879) merged at
`bc117360106d91055221e01f0f8b0de4cd2ac550`. It resolves startup throughput's
stream-fragment counting with artifact-bound pinned tokenization and records
the reviewed capability-aware Ollama qualification profile. Fresh
[CI](https://github.com/Augustas11/macprovider/actions/runs/37592545986) and
[spec-index](https://github.com/Augustas11/macprovider/actions/runs/37592546005)
passed on the reviewed head; combined code, security, and architecture reviews
finished with zero CRITICAL/HIGH/MEDIUM findings. This is merged source, not
proof that the fix has shipped in the private 222 candidate or a public release.

Layer2 [signing run 37597017902](https://github.com/Augustas11/macprovider/actions/runs/37597017902)
and creator [signing run 37597062267](https://github.com/Augustas11/macprovider/actions/runs/37597062267)
succeeded, as did external-runtime
[signing/promotion run 37597012552](https://github.com/Augustas11/macprovider/actions/runs/37597012552)
(completed 2026-10-07 09:09Z). All three exported envelopes passed targeted
signature, artifact-binding, expiry and current-selector verification at the
original integration base. After #1883/#1876, only the three external-runtime
promotion rows still pass current-selector validation. Layer2 R010 and creator
R007 selectors drifted; their older signed captures remain historical only.
Fresh unsigned Layer2 `20261007T122927Z` and creator `20261007T122939Z` captures
passed on merged source `62a9a459de59f759e09fbe88a9015e738da367ae`. Protected
signing and reviewed signature integration follow after those capture bytes
land on main. Workflow success alone is not landed conformance.
These evidence-only workflows neither publish a CLI nor activate an external
Creator launch.

The reviewed captures landed in #1886 (`080eb8404`). Fresh Layer2
[run 37625849934](https://github.com/Augustas11/macprovider/actions/runs/37625849934)
and Creator
[run 37625855687](https://github.com/Augustas11/macprovider/actions/runs/37625855687)
then succeeded from that main commit. All 16 fresh signature, artifact-binding,
expiry and current-selector mappings passed targeted integration verification.
Fresh signatures landed in #1887 and remain evidence-only (Layer2 expiry
2026-10-14; Creator 2026-10-07, now historical). No Layer2/Creator conformance
promotion, external Creator launch or binary release is claimed.

The release/closure gates still outstanding are:

- Layer2/Creator protected signatures landed in #1887 (`743f9ec0d`), with
  unchanged pending conformance states. Fresh BYOM discovery capture
  [`20261007T161811Z`](../../journeys/evidence/provider-byom-discovery-20261007T161811Z.redacted.json)
  passed all ten hermetic steps on `9c8c87dbff8ee00ba2c72f7923e1dce268c42e78`,
  superseding the failed compilation attempt as current unsigned evidence.
  Reviewed unsigned capture landed in #1889 (`bf88db0c1`). Exact PR-head CI
  [37708073165](https://github.com/Augustas11/macprovider/actions/runs/37708073165)
  subsequently passed. Current-main CI
  [37712605781](https://github.com/Augustas11/macprovider/actions/runs/37712605781)
  passed at `855149bd0` before protected signing
  [37715135336](https://github.com/Augustas11/macprovider/actions/runs/37715135336)
  completed after antfleet-ops approval. Its exported capture and envelope
  hashes, pinned public-key signature, expiry, artifact bindings and both
  current-source mappings passed integration verification. The protected output
  promotes only R001/R008; reviewed integration merged in #1891 after green CI
  and exact-head review. This does not prove
  released-CLI acceptance or complete #1690.
- All five released223 isolated `serve` selector/identity legs were executed
  successfully, including real hello hashes, runtime model translation and503
  drift refusals without another upstream chat. The additional `openai:` control
  rejected startup but did not match the runner's expected error wording.
  Conformance reconciliation remains pending; no new harness/tooling PR is
  required or being opened. This does not activate five engines in production.
- [CLI v1.8.223](https://github.com/Augustas11/macprovider/releases/tag/v1.8.223)
  was published from reviewed `9c8c87dbff8ee00ba2c72f7923e1dce268c42e78` by
  [release run 37642806955](https://github.com/Augustas11/macprovider/actions/runs/37642806955).
  Final public tarball/package/DMG CLI byte identity and signing/notarization
  proof are reconciled in the
  [closeout record](../../audits/2026-10-07-1690-closeout/README.md#public-v18223-package-proof-reconciliation--2026-10-08).
  Anonymous discovery passed on both223 and previous stable217. Fresh public223
  Llama/Ollama streaming and non-streaming requests each passed through the223
  gateway/coordinator while both external members remained222, with valid v0.4
  receipts, payable credits, closed verified finality and no settlement holds.
  Selection refusal checks passed, including a refunded wrong-allowlist reservation.
  This establishes mixed222/223 settlement, not public223 provider reacceptance.
  Public223 external-member transition/paid reacceptance, previous-stable
  installation/restart, receipt-authorization omission and
  disclosure reconciliation remain pending. Existing envelopes remain unchanged.
- Complete formal mixed-version rollout/rollback acceptance. Recorded
  217/219/222 coexistence is not a rolling-restart proof; a refused v1-only
  rollback preflight is not rollback readiness. Current `p1816` preflight passed
  with131 route snapshots,63 v2 manifests and no unresolved pool verdicts;
  the actual drill remains pending.
- Complete the final closure audit and reconcile #1690's required gates.

Current native/llama.cpp comparison and capability-aware Ollama measurements
passed their scoped profiles. Ollama's cached API-counter measurements are not
strict M0 token-ID/cache-free parity, runtime perplexity, billing authority, or
release acceptance. Full measurements and limitations remain in the
[closeout evidence](../../audits/2026-10-07-1690-closeout/README.md).
No release identity, live binary, or fleet recommendation changes in this
documentation update. #1690 remains open.

## E2E tracks (independent gates)

A release is promotable only when every in-scope track is GREEN. Normally the
evidence belongs to the same combined candidate. A recorded operator acceptance
may carry forward evidence when the final candidate changes only release
identity or changes outside that track's exercised path; the record must name
the carried evidence, the excluded delta, and the exact-candidate checks that
remain mandatory.

For v1.8.207, the signed 201/202 Studio evidence is accepted for Tracks A, C,
D, and F without repeating those expensive campaigns. The post-202 delta is
bounded: #1776 admits the separately measured Qwen3.5/Qwen3.8 identities, while
#1785 adds an isolated sliding-window measurement path but keeps production
attach fail-closed for that class. The exact signed 207 must still pass
install/join smoke, checksum and embedded CLI byte-identity verification, and
Pearl compatibility-set admission. Track E remains mandatory before the final
mainland-provider installer handoff.

### Track A — OpenRouter readiness

- **Owner / tracker:** #1570
- **Harness:** `scripts/openrouter_readiness_probe.py` · runbook
  `docs/runbooks/openrouter-provider-apply.md`
- **Gate:** benchmark success ≥ 0.95, TTFT p95 ≤ 5000ms, output tps ≥ 10, 0
  502/non-capacity failures; saturation sheds cleanly (early 429, no upstream
  errors); chat (paid+free), models, privacy, health/provenance, wholesale
  statement all pass. `--filing-mode` for the final application (prod URLs +
  benchmark ≥ 100).
- **Last run:** 2026-09-21 wholesale `acct_openrouter` `mp_` key against
  signed Studio **v1.8.176** serving
  `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` (not the Llama 3B fleet).
  Pearl **v1.8.174**. Artifacts:
  `~/.local/state/macprovider/openrouter-readiness/openrouter-readiness-20260921T130140Z-qwen30-studio-176-wholesale.json`
  (idle + ladder + sat) and
  `…T130616Z-qwen30-studio-176-wholesale-soak100.json`.
  Soak 100@4 **FAIL** 45/100 HTTP 200, **55× 429** `no_provider_available`,
  **0× 503**. Idle 16/16 200 but TTFT p95 6362ms (gate ≤5000). Sat 16@8:
  2×200 + 6×429. Ladder clean only through conc=2; conc=4 sheds 5/8.
  Same shape as 175 (49/100). Keyed first-turn CB did not lift Pearl 4-wide
  success. Do not raise slots. Do not set CB `on`. Do not promote.
- **Candidate 201 prequalification (2026-09-28):** live signed 201 serving
  Qwen3.6 35B-A3B passed the applicable public buyer surfaces: chat, models,
  privacy, and health; a clean 16-request idle repeat was 16/16 with TTFT p50
  1765 ms, p95 4546 ms (gate 5000 ms), and 108.475 output tok/s. A true
  16-simultaneous overload produced 8 successful streams plus 8 early 429
  `account_concurrency_exceeded`, with no 5xx or non-capacity failures. The
  earlier sample taken immediately around the load campaign measured 6024 ms
  p95, so retain both results as contention evidence. This is not filing
  evidence: paid+free chat and the wholesale statement were not rerun. For the
  207 China installer release, the operator accepts this evidence without an
  exact-candidate Track A repeat; OpenRouter filing remains a separate gate.

### Track B — BYOM Ollama / Gemma

- **Owner / tracker:** #1569 (not #1453)
- **Harness:** `test/e2e/byom/gemma_runtime_journey.py` · runbook
  `test/e2e/byom/GEMMA-RUNTIME-JOURNEY-RUNBOOK.md` (onboarding sibling:
  `test/e2e/byom/run-cli-onboarding-e2e.py`)
- **Gate:** one signed CLI process serving `ollama:gemma3:270m` with
  `runtime_source=ollama_loopback` and `macprovider.gguf-file.v1`; coordinator
  synthetic probe returns `synthetic_probe_passed` and
  `synthetic_probe_completion_tokens > 0`; `catalog_model_key` stays null;
  never `catalog_priced` / `settlement_capable`. Delete this provider's
  `model_admission_events` after the run or catalog Llama de-routes.
- **Last run:** 2026-09-19 live Pearl (`wss://coordinator.malibu.tech/ws/provider`)
  with signed `v1.8.167` @ `7f833a2f`. Serve `ollama:gemma3:270m` /
  `ollama_loopback`. Offer coordinator-backed,
  `coordinator_event_id` `bcdbd3cedfa2e4149b4094ddb6ae6629fc131fd7e78aa7954fdc4a67555506c6`.
  Probe: `synthetic_probe_passed` → `network_admitted_unsettled`,
  `synthetic_probe_completion_tokens=4`. Admission rows deleted afterward;
  stock earner restored to `1.8.123` `buyer_serving` / `live_verified`.
  A signed candidate from a non-install path must not re-exec into
  `~/macprovider/macprovider-cli` (that is how 167 first looked like an MLX
  load). Re-run Track B on the next candidate (it will include #1609) before
  promoting a BYOM-serve CLI. `v1.8.168` does **not** include the hold.

### Track C — Pi / Qwen tool-call smoke (this cut)

- **Owner / tracker:** #1594, #1596, #1599 (Pearl coordinator already hotfixed;
  this track proves the **Mac CLI**).
- **Gate:** against a candidate-installed provider: stream+tools bash args are
  one complete JSON object; leaked `<function=bash>…</function>` without
  `</tool_call>` becomes `tool_calls` (Pi runs bash, no XML in chat); CLI no
  longer returns `messages_too_long` at 256. Prefill TTFT on Pi’s ~4.5k system
  prompt is **not** a gate — that is hardware, not this cut.
- **Last run:** 2026-09-21 Pi 0.85.1 json vs OpenRouter
  `qwen/qwen3-coder-30b-a3b-instruct` on live `api.malibu.tech` + signed Studio
  **v1.8.175**. Same prompt as 171/174: Makefile `test-dist` first command,
  then `gh pr view 1638`. Malibu **PASS** (53.47s / 34.53s; `ls`/`read`/`bash`
  executed; leftover `missingEndDelimiter` did not hang; answers
  `bash scripts/test-openai-wire-compat.sh` and PR 1638 MERGED). OpenRouter
  **PASS** 29.97s. `~/.pi/agent/settings.json` untouched. Do not promote. Do
  not set CB `on`.
- **Candidate 201 prequalification (2026-09-28):** Pi 0.85.1 json against the
  live Qwen3.6 35B-A3B route executed `read` and `bash`, returned the correct
  `test-dist` first command and repository commit, and exited cleanly in
  24.78s. The run used an isolated Pi config; the real
  `~/.pi/agent/settings.json` mtime was unchanged. For 207, this evidence is
  accepted without repeating the Pi campaign; exact signed-207 install/join
  smoke remains mandatory.

### Track D — Studio Qwen final-answer and settlement recovery

- **Owner / tracker:** #1700, with settlement dependency #1699.
- **Gate:** install one reviewed and signed post-#1700 candidate on the Studio;
  strict-pin real Malibu buyer requests to it; verify exact final answers,
  useful coding/debug/test work, and a multi-turn tool scenario; classify the
  same request IDs through durable settlement evidence. Then pass at least
  95/100 unique coding chats at concurrency 4 and exactly 16/16 at concurrency
  8, with eight requests observed in flight and no recurring routing, queue,
  transport, malformed-answer, or incomplete-answer failures.
- **Pre-merge isolated proof:** the local #1700 release build passed exact-answer
  and no-thinking checks across all 11 loadable cached catalog artifacts: nine
  Qwen-family artifacts spanning Qwen2.5, Qwen3 Coder/Instruct, Qwen3, Qwen3.5,
  Qwen3.6, and Qwen3.8, plus GLM-4.5-Air and Nemotron-3-Nano. The fix is driven
  by the loaded template's
  `enable_thinking` capability, not a family-name guess. This proves local HTTP
  rendering only; it does not satisfy buyer routing, billing, receipt, or
  settlement gates.
- **Historical candidate 186 result:** answer quality passed;
  the strict-pinned buyer soak reached **99/100 at concurrency 4** and **16/16
  at concurrency 8**, with all successful replies free of thinking text and
  eight seats observed in flight (historical — live seats were reduced to one
  on 2026-09-24; see Active candidate above). Durable evidence was **113/116
  complete**; the three incomplete settlements keep this track open. #1728
  is merged and now **live** in Pearl runtime `v1.8.191` @ `98e3e4af` (since
  2026-09-24 05:23Z), so the settlement-complete rerun is unblocked — run it
  against this runtime before closing Track D. During this historical campaign,
  fleet recommendation and `binaryVersion` remained at 1.8.123; the later
  1.8.207 promotion superseded that hold.
- **Candidate 201 prequalification (2026-09-28):** Qwen3.6 35B-A3B completed
  100/100 buyer requests at concurrency 4 with 12,800 completion tokens, zero
  non-capacity failures, and valid usage. The adjacent c8 harness window was
  16/16 HTTP 200; the topology-correct 16-simultaneous overload admitted eight
  and shed eight cleanly. Pearl read-only evidence for the 110-request campaign
  window was 110/110 HTTP 200/no-error, `normal_done`, output available, and
  valid canonical usage JSON, with zero quarantine and zero billing faults.
  Pi supplied the final-answer/tool execution proof. For 207, the operator
  accepts this evidence without repeating the quality, multi-turn, or
  concurrency campaign. Prefix-cache billing is separately deferred until the
  #1768 coordinator fix is deployed and is not a 207 China-installer gate.

### Track E — China install and Qwen3 8B without GitHub or Hugging Face

- **Owner / tracker:** #1756, implementation #1745.
- **Gate:** on a clean Apple Silicon Mac under a mainland-China network
  vantage, install from the public Malibu entrypoint using a reviewed signed
  post-#1745 CLI; acquire the pinned Python bootstrap and Qwen3 8B through the
  approved Malibu mirrors; reproduce the signed model hash; start the provider
  and complete inference. A resolver-level deny/capture must prove zero GitHub,
  Hugging Face, LFS, Xet, or CAS lookups/connections throughout install and
  acquisition. A configured fallback variable or proxy is not proof.
- **Status:** production model origin **GREEN**: `models.malibu.tech`, TLS,
  immutable routing, manifest, sizes, and full weights hash are verified.
  Signed provider-release discovery #1753 is merged in `9636a125`, closing the
  source-side newest-tag/CLI-selection gap. The track remains **OPEN** because
  candidate 201 predates #1753 and is private, the latest public release is
  Pearl-only, `download.malibu.tech/releases/` is unseeded, the served
  installer predates #1745, and no released-binary mainland run has passed.
  Cut signed candidate 207 from post-#1753 `main`; do not substitute the
  earlier ad-hoc local build or Vietnam boundary exercise for this gate.

### Track F — Studio batched-prefill qualification

- **Owner / tracker:** #1758, implementation #1762 (`95a6563d`).
- **Candidate floor:** a reviewed, signed provider CLI cut from `main` at or
  after `95a6563d`. Candidate 195 predates the batched-prefill implementation
  and cannot satisfy this track.
- **Gate:** on the Studio and the exact packaged Metal runtime tuple, run four
  concurrent 1.5k-token prompts with 128 output tokens and keep worst first
  token under 20 seconds; run four concurrent 4k-token prompts with 128 output
  tokens and keep worst first token under 45 seconds; run four concurrent
  8k-token prompts without `continuous_batching_block_extension_failed`, using
  bounded queueing/backpressure if the block pool cannot admit all rows.
  Decode parity, cross-row isolation, cancellation, duplicate-terminal,
  receipt, and warm-swap boundaries must remain green.
- **Status:** **Accepted for the 207 China installer release from candidate
  201/202 evidence.** On
  2026-09-28 the signed packaged candidate, serving Qwen3.6 35B-A3B, completed
  1.5k×4 at 4/4 with 9.189s worst TTFT, 4k×4 at 4/4 with 16.042s worst
  TTFT, and 8k×4 at 4/4 with 25.730s worst TTFT. All rows produced 128 output
  tokens; no block-extension, OOM, queue, or backpressure failure appeared,
  and the provider returned ready/idle with stable RSS. Candidate 201 contains
  #1762, so this is valid performance prequalification. Cancellation,
  duplicate-terminal, receipt, and warm-swap boundaries were not repeated in
  this live pass. The operator accepts the existing signed-candidate evidence
  for 207 under the bounded post-202 delta recorded above; no expensive
  exact-207 Track F repeat is required.

### Track G — signed-policy hybrid activation (#1778)

- **Candidate floor:** a reviewed provider CLI cut from `main` at or after
  `6d1810506`, then signed, notarized, stapled, and packaged by the protected
  acceptance workflow. Source-built and verifier-only binaries cannot satisfy
  this track.
- **Prequalification:** **GREEN.** The designated M3 Ultra Studio passed the
  exact Qwen3.5 27B, Qwen3.5 35B-A3B, and Qwen3.8 27B tuples with 48-token,
  two-row shared-forward parity and zero row failures or cross-row
  divergences. The run used an isolated `--no-join` provider; it did not alter
  the installed live provider or prove Malibu routing, billing, receipts, or
  settlement. See the
  [durable Studio evidence](../../audits/2026-09-30-issue-1778-verifier/RESULT_studio.md).
- **Release gate:** **OPEN.** Repeat the three exact tuples on the packaged
  signed bytes without lab shims and capture automatic signed-policy
  activation plus scheduler-admitted HTTP evidence. Prove byte identity
  between the final Malibu.app and standalone-tarball `macprovider-cli`, and
  verify update from the previous stable release.
- **Live gate:** **OPEN and requires explicit authorization.** With the exact
  reviewed release candidate, prove real Malibu coordinator/gateway/buyer
  routing, billing, v0.4 receipts and settlement, warm swap, rollback, and a
  controlled nonempty signed production-policy rollout. Do not connect a
  locally built or unreleased binary to the live coordinator.
- **Closure rule:** keep #1778 open until both open gates have durable evidence.

- **Carry-forward CF-230-E2E (1.8.230, candidate `15ec4ebd5`, run 37912670009):** carry forward the 1.8.224 in-scope e2e. 1.8.230 changes no decode-path code: it adds the native-MTP Keychain-stall change from PR 1901, the CB upgrade release gate from PR 1904, the `creator` command group from PR 1908, and drops per-binary CB/native-MTP binding and calendar-expiry gates (PR 1918). Live proof on the designated Studio, 2026-10-09 10:50-10:55Z: payload-only swap to the exact signed candidate; `canary_smoke --probe` recorded binary 1.8.230, exact compatibility set, coordinator connected, CB active with the existing signed policy authorized and `live_verified`, paged KV attached; a gateway buyer request for `qwen/qwen3.6-35b-a3b` returned 200 with native-MTP target forwards 0 -> 66.

- **Carry-forward CF-232-E2E (1.8.232, candidate `36758c05c`, run 37957112917):** carry forward the 1.8.230 in-scope decode e2e (no decode-path change for native MLX). 1.8.232 adds the #1923 BYOM polish (claim credential store, creator revoke/lifecycle, `--from-proposal`, `restart`, pool selection in offers, mlx_lm.server and LM Studio resolution). In-scope e2e for those changes ran live on the exact signed candidate on the designated Studio, 2026-10-09 22:25-22:51Z: payload-only swap of the live provider; `canary_smoke --probe` recorded binary 1.8.232, exact compatibility set, coordinator connected, CB active and `live_verified`, paged KV attached. Three fresh provider identities on 1.8.232 (Ollama, LM Studio GGUF, mlx_lm.server MLX snapshot) were bootstrapped with referral codes, claimed through the portal, proposed with `models propose --yes` (signed `requested_pool_model_id`), added to a self-serve pool by a v2 manifest signed with `creator manifest sign --from-proposal` and admitted; one paid buyer request per engine through the public gateway returned 200 with `X-MacProvider-Engine` `ollama_loopback`, `lmstudio_loopback`, `mlxlm_loopback`, each credited (`provider_reported`, not quarantined).

## Promotion gate (checklist)

1. All in-scope CLI rows above are `merged`.
2. Cut one candidate off `main` (`acceptance-candidate.yml`). Do **not** reuse
   `v1.8.163` / `v1.8.164` / `v1.8.167` / `v1.8.168`.
3. In-scope e2e green on that candidate, or an explicit carry-forward record
   under the rule above. For 1.8.217, the fused A3B MoE ordinary path (#1832)
   is in scope with its Studio qualification at `7d55924eb`; native MTP
   remains default-off and out of scope. Earlier signed
   candidate evidence may carry forward only where the table and track record
   explicitly permit it.
4. Privacy code identity registered on Pearl before any canary or fleet
   provider runs the candidate: `scripts/ops/cli-release.sh` step
   `privacy_release_identity` copies the verified candidate
   `pearl-release.json` + `.sig` into Pearl's
   `privacy_class.release_code_identities.metadata_dir` as `v<ver>.json`
   (hot, no restart). While Pearl has no `metadata_dir`, step
   `privacy_release_setup` comes first and `next --run` performs the one-time
   setup (`docs/runbooks/privacy-class-beta-operations.md` "One-time setup")
   with one coordinator restart, staging the identity right after. CLI 1.8.230 shipped without this and
   every upgraded provider's privacy advertisement was refused for ~12 h.
5. Exact signed-candidate install/join smoke. Verify the installed CLI advertises
   1.8.217, joins through Pearl's exact compatibility set, preserves operator
   pause through coordinator drain, and serves a bounded request. Do not touch
   the designated Studio until the operator releases its current session lock.
   The canary probe also fails when Pearl's coordinator journal shows its
   privacy advertisement rejected as `posture_unapproved_code_identity` in
   the last 10 minutes, or when the running coordinator does not positively
   hold the candidate's registrations (item 6).
6. Registrations gate (`registrations`, read-only over `PEARL_SSH`), checked
   on every status, also after publication, so it gates promotion, the
   recommendation bump and rollout verification. It passes only when the
   RUNNING coordinator holds every registration: the candidate
   `compatibility_set_id` is admitted by the live policy (SPEC-002-R004:
   well-formed, from the `target_id` repository, not in `revoked_ids`;
   `/healthz` must equal the applied config) and the on-disk config's
   sha256 equals the running process's boot `coordinator_config_applied`
   digests (restart-only fields), `privacy_class.enabled` is true, and the
   candidate `code_cdhash` is approved either by a `v<ver>.json` that
   verifies and that the coordinator reports as loaded
   (`relayblind_privacy_release_identity_loaded`), or by an unexpired
   `approved_code_identities` entry in that applied config. Unknown fails
   closed, including an unknown candidate `compatibility_set_id` (from fresh
   ops state it is derived only from the trusted-signer `v<ver>` tag); the
   refusal names the missing item. The promotion dispatch runs
   `_check-registrations` against Pearl immediately before
   `gh workflow run`. `promote-acceptance-candidate.yml` cannot reach Pearl,
   so it does not re-check registrations itself: approve its
   production-release deployment only from `cli-release.sh` (the approval
   step is shown only while `status` still passes this gate).
7. Signed release tag (`release_tag`): `promote-acceptance-candidate.yml`
   runs `scripts/verify-release-tag-target.sh "$TAG" "$CANDIDATE_SHA" origin
   --require-existing`, so `v<ver>` must already be an annotated tag on the
   candidate SHA. `cli-release.sh next --run` creates it with the operator's
   git signing key (`git tag -s -a v<ver> -m "macprovider-cli <ver>"
   <candidate_sha>`), checks it with `git verify-tag`, pushes it and confirms
   origin's target. An existing `v<ver>` counts only when it is annotated,
   peels to the candidate, and its exact remote tag object is signed by an
   explicitly approved signer: an SSH signature verified only against
   `MACPROVIDER_RELEASE_TAG_ALLOWED_SIGNERS` (default
   `~/.config/macprovider/release-tag-allowed-signers`, never the checkout's
   git config), or an OpenPGP signature whose `VALIDSIG` fingerprint is in
   `MACPROVIDER_RELEASE_TAG_GPG_FINGERPRINTS`. An unsigned or unapproved tag,
   a tag on another commit, or a lightweight tag is refused. Promotion of 1.8.224, 1.8.230 and 1.8.232 failed
   until this tag was made by hand.
8. Physical acceptance (`promote-acceptance-candidate.yml`) publishes the exact
   versioned bytes and moves the fleet; it does not rewrite `binaryVersion`.
9. `verify-live-coordinator-release-rollout` before publishing discovery.
   `cli-release.sh` runs `_check-privacy-rejections` before the dispatch: it
   samples `relayblind_privacy_posture_rejections_total{reason="posture_unapproved_code_identity"}`
   twice, `PRIVACY_REJECTION_WINDOW_SECONDS` (default 180) apart, within one
   coordinator invocation, and refuses on any new rejection. When the
   coordinator restarted in between (the counter resets) or the metric is not
   served, it counts the unit journal's rejection lines across the window. The lifetime count is only reported, so historical rejections
   never block; a provider that keeps being rejected does, until its identity
   is registered or denied.
10. Byte-identity check: `docs/runbooks/provider-cli-release-verification.md`.
11. Curl-channel `https://get.malibu.tech/install.sh`:
   - **On promotion:** republish from the promoted tag (or confirm served
     bytes still match that tag) so `scripts/check-install-sh-parity.sh`
     against the tag is green. Confirm
     `scripts/check-install-sh-consumer-health.sh` is green (#1600 / #1588).
   - **Off-cycle from `main`:** allowed when the public one-liner must
     change before the next CLI promotion (fresh-Mac CLT wall, pagination).
     Record date + SHA-256 in this file. Expect the parity alarm vs the
     current stable tag to go red until a successor stable includes the
     same `install.sh`. Do not skip consumer-health after a main publish.

## Session protocol

- **Lab campaigns** (Studio / real-Mac e2e): do **not** cut a candidate because
  a CLI-row PR merged. Iterate on a draft campaign PR with a local
  `swift build -c release` on the box. Cut **one** candidate after that
  campaign lands, or when the operator asks. Runbook:
  `docs/runbooks/lab-campaign-loop.md`.
- Update this file when a CLI change merges, a candidate is cut, or an e2e
  track runs. If the update is **only** this file (or other docs), push
  direct to `origin/main` — no PR, do not wait for CI. If it rides with a
  code change, put it in that PR. A merged CLI row is not by itself a cut
  trigger.
- Republish `get.malibu.tech/install.sh` from `main` or from a tag → update
  this file the same day (date, SHA-256, whether parity vs current stable is
  expected red).
- Live-coordinator candidate test: no Pearl admission edit. Since
  SPEC-002-R004 the coordinator admits every well-formed release identity
  from the `target_id` repository; step `pearl_accepted_ids` only checks that
  the running policy admits the candidate. `accepted_ids` is deprecated and
  ignored. To keep a bad build off buyer traffic, add its exact identity to
  `compatibility_set.revoked_ids` (SIGHUP-reloadable): it reconnects
  update-only and still receives the recommendation. A foreign-repository or
  malformed set is closed 4001 with its code, and a v2 CLI reports that code
  instead of `Expected auth_challenge v2`.
- Every new CLI version needs two Pearl registrations, not one: the
  compatibility set above and the privacy code identity. Stage the identity
  with `scripts/ops/cli-release.sh next --run` at step
  `privacy_release_identity`; never hand-edit `approved_code_identities` for a
  signed release. `cli-release.sh status` reports the live state as facts
  `privacy_release_metadata_dir` and `privacy_release_identity`.
- Never hand-make the `v<ver>` release tag: `cli-release.sh` step
  `release_tag` signs, verifies and pushes it on the verified candidate SHA.
  It needs the operator's git signing key configured (`user.signingkey`, and
  `gpg.format ssh` for an SSH key) in the checkout that runs the step.
- Pearl coordinator/gateway runtime: **one cut of current `main`**. Do not
  dual-dispatch `pearl-runtime-release.yml` from two sessions. Record owner +
  payload + live tag in the Pearl paragraph above before/after apply.
