# LFM2.5 candidate intake

These are unsigned, additive release inputs for `liquidai/lfm2.5-24b-a2b`.
They do not replace the current signed catalog. The native runtime fix rides
the next signed CLI cut; a later catalog release merges these rows and runs
the normal generator, signing and `scripts/ops/catalog-activate.sh` path.
Do not copy these standalone documents over the multi-model release inputs.

The candidate and artifact rows pin the official 4-bit snapshot and its
complete 12-file manifest. Its snapshot hash is SHA-256 over sorted
`path + "\n" + size_bytes + "\n" + sha256 + "\n"` entries. The existing
`class-20b-moe` rate class supplies the staged prompt/cache-hit/completion
rates: 0.05 / 0.0125 / 0.10 USD per million tokens at the current credit
conversion. No demand rank is invented: rank is null, demand weight and
provider target are zero, and recommendable is false.

Status remains `candidate`. SPEC-039's exact-identity provisional exception
permits ordinary-CB evaluation, not production qualification or native MTP.
Reference parity passes 256/256 at 1k/8k/32k; four-row scheduler decode is
51.26 tok/s against 40.54 serial (+26.43%). Production attach, signed policy,
automatic FR-CB10 and buyer-UX gates remain required. The prior fixed-budget
coding quality gate failed and is not reclassified by these parity results.

The 20 GiB working-set minimum requires the runtime's model-scoped 512 MiB
MLX freed-buffer cache cap. The largest capped observed footprint was
16.426 GiB, rounded up to 20 GiB; the separate 4 GiB catalog reserve makes
hardware eligibility 24 GiB. This estimate does not prove fit on physical
24 GiB hardware. Uncapped 64k failed the reserve requirement.

License: LFM Open License v1.0. Commercial eligibility must be checked for
Malibu and each provider separately, including its annual-revenue condition
(under US$10 million); redistribution must retain the license and notices.
Verified artifact bytes do not grant unrestricted commercial eligibility.

No `intake-decision.json` is owed for candidate staging: the monthly runbook
requires entries only for admission to `listed` or promotion to
`recommendable`. Neither occurs here. A later listed admission must supply
the runbook's real demand/supply and fit decision; a later promotion must
clear its additional quality, pricing and conformance gates. No release is
cut or activated by this PR.
