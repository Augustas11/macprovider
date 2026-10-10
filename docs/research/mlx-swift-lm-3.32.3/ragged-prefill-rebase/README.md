# Ragged shared prefill on the 3.32.3 runtime (rebase onto #1910)

Studio M3 Ultra, isolated loopback serves (ports 18191-18196), CB on,
greedy, 48 max tokens, metallib `f42aef60…`. The live provider was not
touched. Scripts: `../build/pgp.sh` + `../build/prefill_group_probe.py`
(equal-length prompts in pairs and quads behind a decoding anchor), and
`../build/rpp.sh` + `../build/ragged_prefill_probe.py` (keyed `conv:`
prompts of different lengths sent together, staggered long prompts, and four
staggered copies of one 1337-token prompt). Every row is compared exactly
(reasoning + content) with the same request sent alone. `groups.txt` counts
the CB trace's `prefill_shared` calls; the three `rows=2 chunk=1` calls in
each run are the startup batched-isolation probe.

## Builds (`swift build -c release`)

| Tag | Source | Executable SHA-256 |
| --- | --- | --- |
| `rbb` (before) | branch rebased onto `origin/main` with #1910, no integration: ragged selector without the grouping rule, chunk shortening, one padded attention call | `fdc2822690b8094d583380118d2d6e3e78ad412a46dcfa339b9c16280dafc73c` |
| `rba` (interim) | grouping rule in the ragged selector and natural chunks only; attention still one padded call | `9cd6c05798b97c5dd34dd62343089b6d5bc0b1535ecbde2972e13cf949fa0797` |
| `rbf` (after) | `rba` plus per-row causal attention in ragged forwards (the committed integration) | `d2d148c1a22839318d469cc3afb381c64ea4d5031f55087972399d311ce80494` |

## Results (grouped rows differing from their lone run)

| Probe | Model / mode | before `rbb` | interim `rba` | after `rbf` |
| --- | --- | --- | --- | --- |
| equal-length pairs/quads (pgp) | A3B fused MoE on | 69/108, decode-8 5/14 | 0/108, 0/14 | 0/108, 0/14 |
| equal-length pairs/quads (pgp) | A3B fused MoE off | 63/108, decode-8 6/14 | 0/108, 0/14 | 0/108, 0/14 |
| keyed equal-length pairs/quads (pgp) | 27B | 3/108, decode-8 0/14 | 0/108, 0/14 | 0/108, 0/14 |
| ragged arrivals, short + long (rpp) | A3B fused on | 13/24 | 0/24 | 0/24 |
| ragged arrivals, short + long (rpp) | A3B fused off | 9/24 | 0/24 | 0/24 |
| ragged arrivals, short + long (rpp) | 27B | 3/24 | 0/24 | 0/24 |
| staggered identical 1337-token prompts | A3B fused on | 7/12 | 0/24 | 0/12 |
| staggered identical 1337-token prompts | A3B fused off | 3/12 | n/a | 0/12 |
| staggered identical 1337-token prompts | 27B | 0/12 | 0/24 | 0/12 |

Groups the before build formed that the rule forbids: ragged groups of 7- and
21-token keyed tails (below both bounds), equal-offset groups of 36/57/86-token
chunks on A3B (below 128), and shortened chunks (258/259/304/305 tokens cut
from 418-710-token prompts). The after build's only ragged groups are
443-token chunks of the staggered identical prompts (A3B 3 groups of 3 rows
per mode, 27B one group of 4), and every row matched.

## Attention: per-row boolean mask vs lone causal

Bitwise SDPA check on the Studio (bfloat16, 16 query / 2 KV heads): rows
zero-padded to the group's longest key length under the per-row boolean mask,
against each row alone with the causal mask.

| Head dim | MLX route for prompt chunks | Padded rows bit-equal to lone |
| --- | --- | --- |
| 128 | fused steel attention | all (own keys 2064-8228, padded to 4096-8228) |
| 256 | unfused SDPA (matmul, `where`, softmax, matmul) | no: 3128 keys padded to 4096 differ by 7.5e-9; 4028→4228 and 2064→4164 by 2.4e-4; 7128→8228 by 1.2e-4 |

Slicing each row's own keys out of the padded buffer and attending with the
causal mask is bit-equal to the lone call in every case at both head dims.
`PagedKVRaggedPrefillBatchLayerCache` does that, and
`testRaggedPrefillAttentionMatchesLoneCausalAttentionBitwise` pins it.

## Startup probes (`rbf`)

| Model | Parity | Batched isolation | CB | Grouping |
| --- | --- | --- | --- | --- |
| A3B fused MoE on | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0` | `active=True paged=attached proof=passed slots=8` | `min_grouped_chunk_tokens=128` |
| A3B fused MoE off | `established=true`, 640/640 | same | same | `min_grouped_chunk_tokens=128` |
| 27B | `established=true`, 1024/1024 | same | same | `min_grouped_chunk_tokens=33` |
