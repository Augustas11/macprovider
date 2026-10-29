# Provider CLI 1.8.277 and the next release cut

Updated 2026-10-29 from main at `7c55c5ed2`. This is a narrative snapshot;
parsed release-control rows remain in [the CLI train](cli-release-train.md).
Catalog state and provider publication are separate release actions.

## Published 1.8.277

[v1.8.277](https://github.com/Augustas11/macprovider/releases/tag/v1.8.277)
was promoted on 2026-10-28 at 23:11:16 UTC from
`11c4107744116ac426b0eab4cd37a20c511526a9`. The public release records
promotion of the exact bytes after signed physical acceptance.

The cut includes these main-history changes:

| Change | Main commit | Release scope |
| --- | --- | --- |
| #2152 native MTP | `202ff416c` | Shared iterator, family gate and multi-entry sidecar; exact GLM sampled/tool-history implementation. Source inclusion does not grant sampled serving admission. |
| #2168 agent-prefix retention | `2aca0f374` | Keyed prompt snapshots retained within serving memory headroom. |
| #2177 retention after model swaps | `82efc1628` | Prior model geometry no longer denies retention for the newly loaded model. |
| CB backend cancellation latch | `1d5c7b05e` | Re-arm paged-KV and DeepSeek V4 backends after the cancellation barrier drains, preserving later admissions. |
| #2173 LFM2.5 preparation | `4d68e41fb` | Native loader, tool conversations and reference-plan snapshots; catalog activation remains subject to the quality gate. |
| #2176 Qwen3.8 preparation | `1f61e8943` | Official template identity, reasoning-effort mapping and tool history; catalog activation is separate. |
| Package override hotfix | `ef34cda03` | Remove global `SWIFT_ACTIVE_COMPILATION_CONDITIONS` / `OTHER_SWIFT_FLAGS` overrides that stripped package Swift settings, including `SWIFT_PACKAGE`. |
| #2179 family compatibility | `e7ccd0826` | GLM cached-prefill stride alignment, Qwen3.5 warm-cache anchor and serial keyed handling for FP32 caches while preserving ordinary CB. |
| #2163 Bonsai | `b422e0681` | Native Ternary-Bonsai 2B loading with bounded cache and row residency. |
| #2169 app features / #2175 update recovery | `0239dd1de` / `521a40199` | Create, Agents and Tasks; recovery of expired prepared update handoffs after lifecycle supersession. |

The unpublished **1.8.276 was withdrawn**, and the candidate was rolled back
to **1.8.274**. It is not a stable fallback release. The cancellation-latch
correction above was included before staging and promoting 1.8.277. The earlier
version-only staging commit was `46f89df09`; `956663e4e` also restored
source-built swift-syntax in the release build. The signed-byte carry-forward
record landed in `307fffe43`.

## Native-MTP identity and admission

The 1.8.277 identity rebind landed through #2182 (`54b3d48f2`).
`7848d292b` then corrected both signed entries and their ordinary baselines
from runtime revision `c8be0f618df1e0df230137a3cbe932aa798d602b` to the
released fork pin `36d24585f9373c2661f61f5e5b485c8d66c43a2b`.
Existing qualification sources and measurement hashes remain historical evidence;
the identity rebind is not a new benchmark.

The same commit added the release-match guard; `2b0161a7c` also rejects
ambiguous admission sets. Before native-bound activation, the guard checks
model/artifact, runtime revision, hardware and RAM, qualified slots, embedded
decode digest and metallib against the verified signed release. A signed policy
alone cannot override a mismatch. See [native-MTP enablement](../runbooks/native-mtp-enablement.md#the-one-final-dual-field-rebind).

GLM-5.3-Flash remains **greedy live** (`native_mtp_greedy_text_v1`), one native
row at depth one; sampled qualification remains pending under #2144. The
sampled/tool-history implementation shipped in the CLI does not expand that
live grant. The catalog also binds Qwen3.6-35B-A3B to
`native_mtp_sampled_text_v1`; this snapshot does not independently establish
current live use of that family.

## Main content for the next cut

These commits are on main after the 1.8.277 source, not in its signed bytes:

| Change | Main commit | Next-cut requirement |
| --- | --- | --- |
| #2183 Create/watchdog work | `f332d1c9e`, `f1b845d6d` | Preserve intentional creative holds, allow the first-use download budget, report transport failures and re-adopt validated provider state after restarts; retain diagnostic redaction. These commits are present on main even though #2183's PR metadata has no merge commit. |
| W1 / C2 follow-up | `e018ba9c0` | W1: recover an armed unresponsive process after three consecutive unanswered status probes, preserving operator pause. C2: serialize image/LLM residency on 16 GB systems even when a memory sample appears to permit overlap. |
| #2153 retention budget | `5c730ebf8`, `8d5c45109` | Reserve reachable serving capacity rather than every logical pool token while preserving serving, native-verification, staging and free-memory bounds. `8d5c45109` is the CPU-safe regression-fixture follow-up, not the production budget edit itself. |
| Conversation-cache counters | `7c55c5ed2` | Per-model cumulative cache outcomes and residency in status/heartbeat, bounded coordinator history and observed-window reporting. Requires both the next CLI cut and coordinator runtime update. |
| Lab Metal target | `2f6f93177` | Align qualification builds with the release deployment target and resolved Metal checkout; reject target drift before measurement. Tooling inclusion does not establish qualification. |
| Serving-journey waiver | `0933ce211` | Honor only the exact authorized sampled-1.8.277 sidecar's serving-journey export waiver. Qualification, immutable source binding and release-match checks remain mandatory. |

The next cut **needs a native-MTP identity rebind**: main's embedded decode
path is now `f468a5252f5159cb40a011612f897cdbe9967f4fb9515cf17533eea8c305d20f`,
whereas the 1.8.277 admission binds
`27d5e3e2ea04cd5d9cc7800b85d521af4e35a06acb75754c8924d9b63dc2e8b0`.
Review the changed decode-path sources, preserve applicable qualification under
SPEC-048 MTP-13, and bind the final signed release identity through the guarded
catalog activation flow. A digest mismatch must not be waived or described as
proof of new sampled qualification. The narrowly scoped journey waiver does not
supply that authority.

The cache-counter coordinator portion is tracked in the
[coordinator train](coordinator-release-train.md#release-coordination-update-2026-10-29).
The [engine matrix](../runbooks/MLX_ENGINE_UPGRADE_MATRIX.md#serving-family-snapshot-2026-10-29)
separates runtime support, signed grants and unknown live status.
