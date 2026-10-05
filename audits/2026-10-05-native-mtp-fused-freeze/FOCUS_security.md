LANE: SECURITY REVIEW.

Focus:
- Supply chain: the pinned fork revision 9c1cd900 and its new Metal kernel source (MLXFast custom kernels) execute for every A3B buyer request. Review for out-of-bounds reads/writes in kernel index arithmetic (grid/threadgroup sizing vs output shapes, expert indices from the router, per-chunk token counts), uninitialized scratch, and any state shared across calls or streams that could leak one request's data into another request's output.
- Cross-request isolation under continuous batching: chunked evaluation concatenates rows from different buyers in one call; confirm no row can influence another row's output beyond the documented bf16 non-determinism and no data flows between chunks.
- Lab-only code (journey/bench/hardware harnesses, proposal override, batch-composition fence, token probe): confirm it cannot be reached in a release build or through any network-facing path, and that the lab-flag guard test enforces that.
- Scripts that read evidence (post-gateway replay analyzer, R015 analyzer, sidecar generator): handling of untrusted JSON (duplicate keys, path/key leakage, raw conversation text rejection), never reading signing keys.
- SPEC/CONFORMANCE edits: anything that weakens a fail-closed rule, mints or upgrades a trust tier, or lets an unsigned/unqualified tuple activate.
