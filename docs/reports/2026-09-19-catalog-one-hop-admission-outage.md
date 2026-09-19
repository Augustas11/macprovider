# 2026-09-19 — one-hop catalog previous is the wrong primitive

Publishing `published-2026-09-19-openrouter-priced-v1` did not change the
model on the wire. The live fleet was still **Llama-3.2-3B**. It still
kicked most of the pool.

## What broke

Coordinator hello admission only loaded **current + one**
`.previous-target` line. Priced-v1's previous pointer was listed-v1. Every
provider whose frozen hello envelope was older than that hop got
`close_code=4001 catalog_incompatible`.

Public RPM went null at 14:28 UTC (the catalog SIGHUP), before the later
v1.8.163 binary swap. Lifetime stats were not wiped. `healthz requests_total`
reset because the coordinator process was new.

Hello `catalog_release_id` is **not** "which model this Mac serves". It is
the signed candidate-catalog **document** the CLI selected at `serve` start:

- live fetch of `/v1/autotune-candidates` if signature, policy, and freshness
  pass
- otherwise the **baked** catalog in that CLI binary

Fleet CLI is still `1.8.123`. That binary bakes
`published-2026-09-02-gpt-oss-120b-v1`. Llama-3.2-3B is a recommendable row
in gpt-oss-v1, inband-v1, listed-v1, and priced-v1 with the same artifact
identity and the same policy digest. So the same 3B boxes advertised four
different release IDs depending on when that process last started and whether
live fetch worked.

Restarting the Malibu app starts a new `serve`, re-fetches priced-v1, and
gets back in. Pearl does **not** push a catalog into a running provider.
Reconnect after a coordinator restart reuses the boot envelope.

## Why one hop is the wrong primitive

A catalog publish is not a fleet restart. Typical provider state after a cut:

1. processes that live-fetched the new current
2. processes that live-fetched the previous current and never restarted
3. processes on the CLI baked catalog (1.8.123 → gpt-oss-v1)

One retained previous covers (1) and maybe (2). It never covers (3), and it
stops covering (2) the moment you publish *again* (listed → priced used up
the hop while the fleet was still on inband).

Row-identity + `PolicyEquivalent` already gate stale *models*. The extra hop
was pretending to be a deploy interlock and was actually an accidental
kill-switch for anyone who had not bounced `serve`.

## Mitigation

Coordinator admission loads **current + up to three** deployer-recorded
`.previous-target` lines. A fourth line fails closed. It is not a walk of
`releases/`. Each loaded previous still has to match the selected model row
in current (identity + policy).

Pearl window for this cut, after the coordinator binary that can parse three
lines is live:

```
releases/published-2026-09-19-openrouter-listed-v1-b92b4470a6630240
releases/published-2026-09-16-inband-provenance-v1-fe30b22a21552429
releases/published-2026-09-02-gpt-oss-120b-v1-10b792ad574042c2
```

Do not write that three-line file onto v1.8.163: the old parser treats a
multiline pointer as invalid and will refuse previous catalogs entirely.

Catalog publish / freshness restamp must **prepend** the outgoing current and
keep at most three unique lines. Replacing the file with a single hop repeats
this outage on the next cut.
