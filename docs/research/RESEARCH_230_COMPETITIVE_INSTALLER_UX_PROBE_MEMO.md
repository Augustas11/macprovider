<!-- Preface added during commit (the codex probe was fired before operator caught SPEC-018 was already taken by SPEC-018-agentic-tool-calling). All references to "SPEC-018" in this memo should be read as "SPEC-023 — Installer-Integrated Autotune Recommend." The codex output is preserved verbatim below for audit-trail integrity. -->

**Part 1 — Competitive Sweep**

Scope note: I did not inspect `Layr-Labs/d-inference` source. Darkbloom findings below use only public marketing / console pages.

| Network | Provider install flow shape | Hardware-specific workload recommendation? | Who picks workload? | Earnings projected before commit? | Mapping to macprovider |
|---|---|---:|---|---:|---|
| vast.ai | Host setup + web host dashboard; host installs Ubuntu/drivers/Vast host software and lists GPU capacity. Vast describes hosts as sellers of GPU resources. ([docs.vast.ai](https://docs.vast.ai/host/hosting-overview?utm_source=openai)) | No model/job recommendation found in public provider docs; docs emphasize host pricing and market metrics, not workload choice. ([docs.vast.ai](https://docs.vast.ai/guides/instances/pricing?utm_source=openai)) ([docs.vast.ai](https://docs.vast.ai/host/market-metrics?utm_source=openai)) | Buyer/client brings workload; host lists capacity and sets terms/prices. ([vast.ai](https://vast.ai/hosting?srsltid=AfmBOoqEBAEhejjVEzuGkxyUicg5GYBql6zwXO9tsjXXikIq2FdMlU2y&utm_source=openai)) | Partial: earnings/pricing tools exist, but not “this model on this Mac earns $X/hr.” Market metrics help hosts price machines. ([docs.vast.ai](https://docs.vast.ai/host/market-metrics?utm_source=openai)) | Raw GPU marketplace; closest pattern is pricing guidance, not model recommendation. |
| RunPod | Buyer-side pods/serverless; formerly Community Cloud, but docs now say RunPod is no longer accepting new Community Cloud hosts. ([docs.runpod.io](https://docs.runpod.io/pods/choose-a-pod?utm_source=openai)) | No provider-side workload recommendation found. Public docs focus on users selecting GPU/template/image. ([docs.runpod.io](https://docs.runpod.io/runpodctl/reference/runpodctl-pod?utm_source=openai)) | Buyer chooses GPU type/template/image; platform assigns machine. ([docs.runpod.io](https://docs.runpod.io/api-reference/pods/POST/pods?utm_source=openai)) | Buyer sees cost per hour for pods; no public provider earnings recommendation. ([docs.runpod.io](https://docs.runpod.io/pods/pricing?utm_source=openai)) | Not a current open provider onboarding analogue. |
| io.net | IO Worker portal + OS-specific worker install + dashboard. ([io.net](https://io.net/docs/guides/workers/quick-start-guide)) | No model/job recommendation found; docs describe adding GPU/CPU and network orchestration/assignment. ([io.net](https://io.net/docs/guides/workers/io-worker)) | Network/customer jobs use supplied compute; supplier manages device, not model choice. ([io.net](https://io.net/docs/guides/workers/io-worker)) | Yes after/through dashboard: real-time earnings and compute-job metrics, not pre-commit model-ranked earnings. ([io.net](https://io.net/docs/guides/workers/rewards-wallets)) | Supplier dashboard, not installer recommendation. |
| Akash Network | Provider Console / Kubernetes provider service / Helm-style provider build; tenants deploy SDL manifests. ([akash.network](https://akash.network/providers/)) | No workload recommendation; provider bid engine evaluates tenant orders and submits bids. ([akash.network](https://akash.network/docs/providers/architecture/overview/?utm_source=openai)) | Tenant defines workload in SDL; providers bid; tenant accepts lease. ([akash.network](https://akash.network/docs/getting-started/core-concepts/?utm_source=openai)) | Yes, but at provider-capacity level: Akash advertises a Provider Calculator to estimate earnings. ([akash.network](https://akash.network/providers/)) | Has provider earnings estimation, but not “which model should I run?” |
| Aethir | Cloud Host portal / registration / staking / server registration. ([docs.aethir.com](https://docs.aethir.com/aethir-cloud/aethir-cloud-host/cloud-host-portal-guide/get-started?utm_source=openai)) | No public workload recommendation found; docs/blog describe Cloud Hosts providing GPUs for AI, gaming, training, Web3 workloads. ([aethir.com](https://aethir.com/blog-posts/step-by-step-guide-onboarding-as-an-aethir-cloud-host?utm_source=openai)) | Network/client demand uses supplied GPU resources; host does not appear to pick a model. | Public materials claim rewards based on GPU usage, uptime, and performance; no inspected pre-commit per-workload projection. ([ecosystem.aethir.com](https://ecosystem.aethir.com/blog-posts/how-to-monetize-gpus-with-decentralized-cloud-hosting-a-comprehensive-guide?utm_source=openai)) | Managed DePIN supply pool; recommendation problem mostly hidden from host. |
| Render Network | Node operator waitlist/onboarding; docs say team follows up with onboarding info. ([know.rendernetwork.com](https://know.rendernetwork.com/general-render-network/what-role-am-i/how-to-get-started-1?utm_source=openai)) | No model/job recommendation; node eligibility/benchmarking uses GPU/OctaneBench-style assessment. ([know.rendernetwork.com](https://know.rendernetwork.com/general-render-network/what-role-am-i/how-to-get-started-1/render-compute-network-gpu-compute-node-waitlist-faq?utm_source=openai)) | Creator/network assigns render or compute jobs to suitable nodes. Public docs frame GPU owners loaning compute to creators. ([know.rendernetwork.com](https://know.rendernetwork.com/?utm_source=openai)) | Partial: reward/emissions docs and node requirements exist; no public “this workload earns $X/hr” installer projection. ([medium.com](https://medium.com/render-token/compute-client-node-reward-mechanism-update-6b867e348030?utm_source=openai)) | Benchmarking/eligibility analogue, not choice recommendation. |
| Bittensor / Targon / Templar | Subnet-specific miner setup; Bittensor says miners research subnets based on expertise/hardware. ([docs.learnbittensor.org](https://docs.learnbittensor.org/miners?utm_source=openai)) | No central recommendation; each subnet defines its own incentive mechanism. ([docs.learnbittensor.org](https://docs.learnbittensor.org/subnets/understanding-subnets?utm_source=openai)) Targon docs are miner setup for confidential compute. ([docs.targon.com](https://docs.targon.com/providers/miner/?utm_source=openai)) Templar miners train on assigned data/share gradients. ([docs.tplr.ai](https://docs.tplr.ai/miners/?utm_source=openai)) | Subnet protocol defines work; validators score miner output and rewards. ([docs.tplr.ai](https://docs.tplr.ai/validators/weight-setting/?utm_source=openai)) | Not as simple pre-commit $/hr; emissions depend on subnet competition, quality, weights. ([docs.learnbittensor.org](https://docs.learnbittensor.org/subnets/understanding-subnets?utm_source=openai)) | Closest “choose a subnet” problem, but no installer-level ranked yield UX. |
| Helium | Mobile app / gateway onboarding; hotspot location and device setup. ([apps.apple.com](https://apps.apple.com/us/app/helium-hotspot/id1450463605?utm_source=openai)) | Not workload recommendation; rewards depend on coverage/data transfer. ([docs.helium.com](https://docs.helium.com/mobile/5g-on-helium/?utm_source=openai)) | Network protocols assign rewards for coverage/data, not operator-selected workload. ([medium.com](https://medium.com/helium-foundation/off-chain-proof-of-coverage-is-live-e5f0493e2bca?utm_source=openai)) | Third-party tools exist, but official docs focus on reward mechanics, not pre-commit workload projection. | Tokenomics/location-density analogue, not compute/model analogue. |
| Together.ai | Buyer/developer cloud API: serverless models, dedicated endpoints, GPU clusters. ([docs.together.ai](https://docs.together.ai/intro?utm_source=openai)) ([docs.together.ai](https://docs.together.ai/docs/gpu-clusters-overview?utm_source=openai)) | No public provider onboarding surface found. | Together operates/aggregates infrastructure; user picks model/endpoint. ([docs.together.ai](https://docs.together.ai/docs/serverless/models?utm_source=openai)) | Buyer-side pricing, no provider earnings projection. | Not a provider-marketplace UX. |
| Lepton / NVIDIA DGX Cloud Lepton | Managed AI platform / marketplace connecting developers to cloud providers. ([docs.nvidia.com](https://docs.nvidia.com/dgx-cloud/lepton/guides/?utm_source=openai)) | No public independent provider onboarding UX found in inspected docs. | Buyer/developer deploys endpoints/jobs; Lepton abstracts providers. | Buyer-side cost/availability surface, not provider yield. | Marketplace broker, but provider UX is not public/self-serve. |
| Modal | Developer serverless GPU functions; users specify GPU requirements/fallback ordering. ([modal.com](https://modal.com/docs/guide/gpu?utm_source=openai)) | No provider onboarding. | Developer chooses workload/function and GPU request. | Buyer-side usage pricing, not provider earnings. | Useful only as buyer-side GPU selection UX. |
| Replicate | Developer model hosting; custom models are deployed on Replicate GPU cluster. ([replicate.com](https://replicate.com/docs/get-started/deploy-a-custom-model?utm_source=openai)) | No provider onboarding; docs cover choosing deployment hardware. ([replicate.com](https://replicate.com/docs/topics/models/hardware?utm_source=openai)) | Model owner/user picks model and hardware; Replicate runs infrastructure. ([replicate.com](https://replicate.com/docs?utm_source=openai)) | Buyer/model-owner cost control, not provider yield. | Not competitive provider-side surface. |
| Darkbloom / d-inference public pages only | CLI installer during alpha; native menu bar app planned. ([darkbloom.dev](https://darkbloom.dev/)) | **Yes, public earnings calculator shows “Auto-selected: most profitable for your hardware.”** It takes Mac type/chip/memory and model catalog compatibility. ([darkbloom.dev](https://darkbloom.dev/)) ([console.darkbloom.dev](https://console.darkbloom.dev/earn)) | Public pages say coordinator matches demand to verified Mac providers; installer page says provider chooses availability. ([darkbloom.dev](https://darkbloom.dev/)) | Yes: earnings calculator estimates usage earnings plus base reward, with demand/utilization caveats. ([console.darkbloom.dev](https://console.darkbloom.dev/earn)) | This partially refutes the hypothesis: not a large generic GPU marketplace, but a close Apple-Silicon inference competitor has a public hardware-to-model earnings calculator. |

**Part 1 conclusion:** Major raw-GPU/decentralized compute networks do not show an installer-time “best model for your hardware” UX, but Darkbloom publicly ships a close earnings-calculator version of the pattern, so SPEC-018 should frame macprovider’s wedge as “installer-integrated, local autotune recommendation,” not “no one has any model-yield recommender.”

**Part 2 — Closest UX Analogues**

1. **StakingRewards.com**
   - Pattern: compare many assets/providers by yield and risk, not just headline APR; StakingRewards describes itself as comparing 90+ providers and 120+ assets with risk grades. ([stakingrewards.com](https://www.stakingrewards.com/?utm_source=openai))
   - Apply: `autotune --recommend` should rank by expected net `$/hr`, but also show risk/confidence fields: demand confidence, thermal risk, memory headroom, and staleness.
   - Pattern: calculator starts from input stake amount and compares returns across assets/providers. ([stakingrewards.com](https://www.stakingrewards.com/calculator?utm_source=openai))
   - Apply: Mac hardware should be auto-detected, then projected across model candidates rather than making the operator manually inspect a rate card.

2. **Lido / RocketPool-style staking dashboards**
   - Pattern: Lido’s calculator displays stake amount, APR, monthly rewards, yearly rewards, and a direct action. ([lido.fi](https://lido.fi/how-lido-works/apr-and-rewards-calculator?utm_source=openai))
   - Apply: install transcript should show “recommended model,” “expected hourly,” “monthly at assumed utilization,” and “start provider” in one compact decision block.
   - Pattern: single-pool dashboards are good at explaining assumptions next to the number.
   - Apply: show assumptions inline: utilization, electricity estimate, rate-card version, benchmark date.

3. **WhatToMine**
   - Pattern: user enters hashrate/power; output is a profitability table, with caveat that final results vary and calculations use mean values. ([whattomine.com](https://whattomine.com/?utm_source=openai))
   - Apply: output should be a ranked table of 3-5 models with mean estimate plus caveat: demand varies, thermal throttling can change realized yield.
   - Pattern: defaults are adapted for known GPU configurations. ([whattomine.com](https://whattomine.com/?utm_source=openai))
   - Apply: auto-detect Mac profile and use known benchmark defaults, but allow override for electricity price / availability hours.

4. **NiceHash**
   - Pattern: profitability calculator supports hashrate, device, and device comparison modes. ([nicehash.com](https://www.nicehash.com/profitability-calculator?utm_source=openai))
   - Apply: support `--json` for machines and a human table for install; include “this Mac vs default Mac tier” comparison.
   - Pattern: QuickMiner benchmarks GPUs and automatically profit-switches to the most profitable algorithm at the moment. ([nicehash.com](https://www.nicehash.com/support/mining-help/quickminer/quickminer-profit-switching?utm_source=openai))
   - Apply: macprovider v0.1 should not auto-switch silently, but it should make re-running recommendation cheap and explicit.

5. **Yield aggregators: Yearn / Beefy / Convex class**
   - Pattern: Beefy shows predicted APY, includes compounding, and says displayed APY includes vault fees. ([docs.beefy.finance](https://docs.beefy.finance/beefy-products/vaults?utm_source=openai))
   - Apply: `expected_net_usd_per_hour` should be net of platform fee and estimated electricity, not just gross token revenue.
   - Pattern: Yearn docs emphasize APY methodology and vault risk inheritance. ([docs.yearn.fi](https://docs.yearn.fi/getting-started/guides/how-apy-works?utm_source=openai)) ([docs.yearn.fi](https://docs.yearn.fi/developers/security/risks/?utm_source=openai))
   - Apply: expose formula/inputs: rate card, measured tokens/sec, expected utilization, electricity, memory tier, and demand confidence.

6. **Cloud cost calculators: AWS / GCP**
   - Pattern: AWS Pricing Calculator estimates workloads/resources/architecture changes in real time, but warns actual fees depend on usage. ([aws.amazon.com](https://aws.amazon.com/aws-cost-management/aws-pricing-calculator/?utm_source=openai)) ([docs.aws.amazon.com](https://docs.aws.amazon.com/cost-management/latest/userguide/pricing-calculator.html?utm_source=openai))
   - Apply: recommendation should state it is an estimate, not a guarantee; realized earnings depend on buyer traffic.
   - Pattern: GCP calculator lets users add/configure products and share estimates. ([cloud.google.com](https://cloud.google.com/products/calculator?utm_source=openai))
   - Apply: JSON output should be reproducible/shareable for support: include `rate_card_version`, `benchmark_id`, and `generated_at`.

7. **Electricity-plan comparison sites**
   - Pattern: plan comparison starts with ZIP/usage and ranks plans using current rates/preferences; some update rates daily. ([choosetexaspower.org](https://www.choosetexaspower.org/?utm_source=openai))
   - Apply: recommendation should include local electricity as a first-class input and show data freshness.
   - Pattern: savings calculators show monthly/yearly estimates, annual savings, and savings percentage. ([energyogre.com](https://www.energyogre.com/savings?utm_source=openai))
   - Apply: show “recommended vs default” delta: `+$0.18/hr`, `+23% vs default`, or “donor-tier, expected net near zero.”
   - Pattern: utility tools compare current plan vs alternatives using past usage. ([sce.com](https://www.sce.com/save-money/rates-financing/rate-plan-comparison-tool?utm_source=openai))
   - Apply: `macprovider status` should compare current configured model against the latest recommendation.

**Part 2 conclusion:** The best import pattern is WhatToMine/NiceHash ranking plus staking-dashboard assumption disclosure: ranked candidates, net yield, confidence, staleness, and explicit “recommended vs alternatives” deltas.

**Part 3 — Differentiation Framing**

macprovider’s provider-install UX sits in a gap left by most decentralized GPU networks. Vast, RunPod, io.net, Akash, Aethir, Render, and Bittensor generally expose raw capacity, bids, node eligibility, subnet incentives, or buyer-selected workloads; their public provider flows do not show an installer-time recommendation that says “given this hardware, run this model to earn the most.” That difference follows from their market structure: the buyer brings a container, manifest, render job, or subnet task, while the provider supplies capacity or competes under a protocol.

The closest competitive exception is Darkbloom. Its public pages show an Apple-Silicon inference network, a CLI provider install path, and an earnings calculator that auto-selects the “most profitable” model for a chosen Mac hardware profile. That means macprovider should not claim the entire idea is unobserved. The sharper wedge is that SPEC-018 makes the recommendation local, installer-integrated, benchmark-backed, and machine-readable via `autotune --recommend`, rather than only a web estimate.

The right UX lineage is not generic cloud hosting. It is staking calculators and mining profitability calculators. StakingRewards-style surfaces rank heterogeneous yield options and disclose risk; WhatToMine/NiceHash-style surfaces translate hardware, power, rates, and current market data into ranked profitability. macprovider has the same shape: detected hardware plus measured tokens/sec plus a per-model rate card plus demand assumptions yields a ranked recommendation.

This will not create demand where none exists. SPEC-018 answers “which model should this provider run, given known rates and measured local performance?” It does not answer “will buyers show up?” The UX must say that clearly: expected `$/hr` is an estimate conditioned on demand, utilization, uptime, electricity, and the current rate card.

**Part 3 conclusion:** Frame SPEC-018 as installer-integrated yield recommendation for inference providers: competitive against raw-capacity marketplaces, informed by staking/mining calculators, and honest that recommendation optimizes model choice, not market demand.

**Part 4 — v0.1 SPEC Implications**

1. **Output schema for `autotune --recommend`**
   - Tie-back: WhatToMine/NiceHash rank alternatives; Beefy/Yearn disclose net APY/risk; AWS/GCP preserve estimate assumptions.
   - Suggested JSON shape:

```json
{
  "schema_version": "autotune_recommend.v1",
  "generated_at": "2026-06-30T12:00:00Z",
  "hardware": {
    "machine": "MacBook Pro",
    "chip": "M4 Max",
    "memory_gb": 48,
    "detected": true
  },
  "inputs": {
    "rate_card_version": "2026-06-30",
    "electricity_usd_per_kwh": 0.15,
    "assumed_utilization": 0.8,
    "availability_hours_per_day": 18
  },
  "recommended_model": "qwen3-14b",
  "candidates": [
    {
      "rank": 1,
      "model": "qwen3-14b",
      "fits": true,
      "expected_net_usd_per_hour": 0.42,
      "expected_gross_usd_per_hour": 0.47,
      "electricity_usd_per_hour": 0.03,
      "platform_fee_usd_per_hour": 0.02,
      "tokens_per_second": 41.2,
      "memory_headroom_gb": 8.1,
      "confidence": "medium",
      "why": "highest net yield among compatible models"
    }
  ],
  "comparison": {
    "default_model": "gemma-7b",
    "recommended_delta_usd_per_hour": 0.18,
    "recommended_delta_percent": 75
  },
  "warnings": [
    "Earnings depend on buyer demand and realized utilization."
  ]
}
```

2. **Install transcript copy**
   - Tie-back: Lido gives monthly/yearly rewards next to APR; electricity-plan tools show savings vs current/default; Darkbloom discloses demand caveats.
   - Happy path:

```text
Detected MacBook Pro M4 Max, 48 GB unified memory.
Benchmarked 4 compatible models against rate card 2026-06-30.

Recommended: qwen3-14b
Expected net: $0.42/hr at 80% utilization
Why: +$0.18/hr vs default gemma-7b, 8.1 GB memory headroom

This is an estimate, not a guarantee. Actual earnings depend on buyer demand,
uptime, thermal state, and rate-card changes.

Start provider with qwen3-14b? [Y/n]
```

   - Donor-tier path:

```text
Detected MacBook Air M1, 8 GB unified memory.
No paid model currently clears the minimum net-yield threshold.

Best compatible option: tinyllama
Expected net: $0.00-$0.01/hr before demand risk
Recommendation: donor mode only

You can still run a provider to support network coverage, but this Mac is
not expected to earn meaningful revenue on the current rate card.
Enable donor mode? [y/N]
```

3. **Re-tune cadence + UX**
   - Tie-back: NiceHash profit-switching shows market-aware re-optimization, but automatic switching is risky for inference provider stability.
   - v0.1 decision: make `autotune --recommend` rerunnable and idempotent; do not silently switch models.
   - Trigger recommendation prompts on install, manual `macprovider autotune --recommend`, and rate-card version change.
   - Store last recommendation summary with `generated_at`, `rate_card_version`, and `benchmark_id`.

4. **Donor-mode opt-in**
   - Tie-back: electricity-plan sites show “you could save $X” before switching; macprovider should show “you would earn $X less” before override.
   - v0.1 decision: require explicit opt-in for non-recommended or below-threshold operation:
     - CLI: `macprovider configure --model tinyllama --donor-mode`
     - YAML: `donor_mode: true`
     - Install prompt default: No
   - Warning copy: “This choice is estimated to earn `$X/hr` less than the recommended model” or “below minimum revenue threshold.”

5. **Status-command integration**
   - Tie-back: utility tools compare current plan vs alternatives using actual/past usage; io.net dashboards show earnings and compute job metrics.
   - v0.1 decision: `macprovider status` should include:
     - current model
     - last measured `tokens/sec`
     - observed earnings last hour/day if available
     - estimate from last recommendation
     - stale recommendation warning
     - better available model, if any

```text
Model: gemma-7b
Estimated net: $0.24/hr
Observed last 24h: $3.10 total
Recommendation stale: rate card changed 2026-06-30

Run: macprovider autotune --recommend
Potential improvement: qwen3-14b estimated $0.42/hr (+$0.18/hr)
```

**Part 4 conclusion:** SPEC-018 v0.1 should specify a ranked, net-yield JSON contract; install copy with assumptions and deltas; explicit re-tune triggers; donor-mode guardrails; and status integration that compares current model to the latest recommendation.

**Part 5 — Liftable One-Line Conclusions**

- Part 1: Major decentralized GPU networks mostly avoid the provider model-choice problem; Darkbloom is the notable close exception with a public hardware-to-model earnings calculator.
- Part 2: Import the WhatToMine/NiceHash ranked-profitability pattern and the staking-dashboard assumption/risk-disclosure pattern.
- Part 3: macprovider’s wedge is installer-integrated, benchmark-backed model yield recommendation for heterogeneous consumer inference hardware.
- Part 4: v0.1 should lock the recommendation as a transparent ranked estimate, not a guaranteed income claim or silent auto-switcher.


OpenAI Codex v0.142.2
**Part 1 — Competitive Sweep**

Scope note: I did not inspect `Layr-Labs/d-inference` source. Darkbloom findings below use only public marketing / console pages.

| Network | Provider install flow shape | Hardware-specific workload recommendation? | Who picks workload? | Earnings projected before commit? | Mapping to macprovider |
|---|---|---:|---|---:|---|
| vast.ai | Host setup + web host dashboard; host installs Ubuntu/drivers/Vast host software and lists GPU capacity. Vast describes hosts as sellers of GPU resources. ([docs.vast.ai](https://docs.vast.ai/host/hosting-overview?utm_source=openai)) | No model/job recommendation found in public provider docs; docs emphasize host pricing and market metrics, not workload choice. ([docs.vast.ai](https://docs.vast.ai/guides/instances/pricing?utm_source=openai)) ([docs.vast.ai](https://docs.vast.ai/host/market-metrics?utm_source=openai)) | Buyer/client brings workload; host lists capacity and sets terms/prices. ([vast.ai](https://vast.ai/hosting?srsltid=AfmBOoqEBAEhejjVEzuGkxyUicg5GYBql6zwXO9tsjXXikIq2FdMlU2y&utm_source=openai)) | Partial: earnings/pricing tools exist, but not “this model on this Mac earns $X/hr.” Market metrics help hosts price machines. ([docs.vast.ai](https://docs.vast.ai/host/market-metrics?utm_source=openai)) | Raw GPU marketplace; closest pattern is pricing guidance, not model recommendation. |
| RunPod | Buyer-side pods/serverless; formerly Community Cloud, but docs now say RunPod is no longer accepting new Community Cloud hosts. ([docs.runpod.io](https://docs.runpod.io/pods/choose-a-pod?utm_source=openai)) | No provider-side workload recommendation found. Public docs focus on users selecting GPU/template/image. ([docs.runpod.io](https://docs.runpod.io/runpodctl/reference/runpodctl-pod?utm_source=openai)) | Buyer chooses GPU type/template/image; platform assigns machine. ([docs.runpod.io](https://docs.runpod.io/api-reference/pods/POST/pods?utm_source=openai)) | Buyer sees cost per hour for pods; no public provider earnings recommendation. ([docs.runpod.io](https://docs.runpod.io/pods/pricing?utm_source=openai)) | Not a current open provider onboarding analogue. |
| io.net | IO Worker portal + OS-specific worker install + dashboard. ([io.net](https://io.net/docs/guides/workers/quick-start-guide)) | No model/job recommendation found; docs describe adding GPU/CPU and network orchestration/assignment. ([io.net](https://io.net/docs/guides/workers/io-worker)) | Network/customer jobs use supplied compute; supplier manages device, not model choice. ([io.net](https://io.net/docs/guides/workers/io-worker)) | Yes after/through dashboard: real-time earnings and compute-job metrics, not pre-commit model-ranked earnings. ([io.net](https://io.net/docs/guides/workers/rewards-wallets)) | Supplier dashboard, not installer recommendation. |
| Akash Network | Provider Console / Kubernetes provider service / Helm-style provider build; tenants deploy SDL manifests. ([akash.network](https://akash.network/providers/)) | No workload recommendation; provider bid engine evaluates tenant orders and submits bids. ([akash.network](https://akash.network/docs/providers/architecture/overview/?utm_source=openai)) | Tenant defines workload in SDL; providers bid; tenant accepts lease. ([akash.network](https://akash.network/docs/getting-started/core-concepts/?utm_source=openai)) | Yes, but at provider-capacity level: Akash advertises a Provider Calculator to estimate earnings. ([akash.network](https://akash.network/providers/)) | Has provider earnings estimation, but not “which model should I run?” |
| Aethir | Cloud Host portal / registration / staking / server registration. ([docs.aethir.com](https://docs.aethir.com/aethir-cloud/aethir-cloud-host/cloud-host-portal-guide/get-started?utm_source=openai)) | No public workload recommendation found; docs/blog describe Cloud Hosts providing GPUs for AI, gaming, training, Web3 workloads. ([aethir.com](https://aethir.com/blog-posts/step-by-step-guide-onboarding-as-an-aethir-cloud-host?utm_source=openai)) | Network/client demand uses supplied GPU resources; host does not appear to pick a model. | Public materials claim rewards based on GPU usage, uptime, and performance; no inspected pre-commit per-workload projection. ([ecosystem.aethir.com](https://ecosystem.aethir.com/blog-posts/how-to-monetize-gpus-with-decentralized-cloud-hosting-a-comprehensive-guide?utm_source=openai)) | Managed DePIN supply pool; recommendation problem mostly hidden from host. |
| Render Network | Node operator waitlist/onboarding; docs say team follows up with onboarding info. ([know.rendernetwork.com](https://know.rendernetwork.com/general-render-network/what-role-am-i/how-to-get-started-1?utm_source=openai)) | No model/job recommendation; node eligibility/benchmarking uses GPU/OctaneBench-style assessment. ([know.rendernetwork.com](https://know.rendernetwork.com/general-render-network/what-role-am-i/how-to-get-started-1/render-compute-network-gpu-compute-node-waitlist-faq?utm_source=openai)) | Creator/network assigns render or compute jobs to suitable nodes. Public docs frame GPU owners loaning compute to creators. ([know.rendernetwork.com](https://know.rendernetwork.com/?utm_source=openai)) | Partial: reward/emissions docs and node requirements exist; no public “this workload earns $X/hr” installer projection. ([medium.com](https://medium.com/render-token/compute-client-node-reward-mechanism-update-6b867e348030?utm_source=openai)) | Benchmarking/eligibility analogue, not choice recommendation. |
| Bittensor / Targon / Templar | Subnet-specific miner setup; Bittensor says miners research subnets based on expertise/hardware. ([docs.learnbittensor.org](https://docs.learnbittensor.org/miners?utm_source=openai)) | No central recommendation; each subnet defines its own incentive mechanism. ([docs.learnbittensor.org](https://docs.learnbittensor.org/subnets/understanding-subnets?utm_source=openai)) Targon docs are miner setup for confidential compute. ([docs.targon.com](https://docs.targon.com/providers/miner/?utm_source=openai)) Templar miners train on assigned data/share gradients. ([docs.tplr.ai](https://docs.tplr.ai/miners/?utm_source=openai)) | Subnet protocol defines work; validators score miner output and rewards. ([docs.tplr.ai](https://docs.tplr.ai/validators/weight-setting/?utm_source=openai)) | Not as simple pre-commit $/hr; emissions depend on subnet competition, quality, weights. ([docs.learnbittensor.org](https://docs.learnbittensor.org/subnets/understanding-subnets?utm_source=openai)) | Closest “choose a subnet” problem, but no installer-level ranked yield UX. |
| Helium | Mobile app / gateway onboarding; hotspot location and device setup. ([apps.apple.com](https://apps.apple.com/us/app/helium-hotspot/id1450463605?utm_source=openai)) | Not workload recommendation; rewards depend on coverage/data transfer. ([docs.helium.com](https://docs.helium.com/mobile/5g-on-helium/?utm_source=openai)) | Network protocols assign rewards for coverage/data, not operator-selected workload. ([medium.com](https://medium.com/helium-foundation/off-chain-proof-of-coverage-is-live-e5f0493e2bca?utm_source=openai)) | Third-party tools exist, but official docs focus on reward mechanics, not pre-commit workload projection. | Tokenomics/location-density analogue, not compute/model analogue. |
| Together.ai | Buyer/developer cloud API: serverless models, dedicated endpoints, GPU clusters. ([docs.together.ai](https://docs.together.ai/intro?utm_source=openai)) ([docs.together.ai](https://docs.together.ai/docs/gpu-clusters-overview?utm_source=openai)) | No public provider onboarding surface found. | Together operates/aggregates infrastructure; user picks model/endpoint. ([docs.together.ai](https://docs.together.ai/docs/serverless/models?utm_source=openai)) | Buyer-side pricing, no provider earnings projection. | Not a provider-marketplace UX. |
| Lepton / NVIDIA DGX Cloud Lepton | Managed AI platform / marketplace connecting developers to cloud providers. ([docs.nvidia.com](https://docs.nvidia.com/dgx-cloud/lepton/guides/?utm_source=openai)) | No public independent provider onboarding UX found in inspected docs. | Buyer/developer deploys endpoints/jobs; Lepton abstracts providers. | Buyer-side cost/availability surface, not provider yield. | Marketplace broker, but provider UX is not public/self-serve. |
| Modal | Developer serverless GPU functions; users specify GPU requirements/fallback ordering. ([modal.com](https://modal.com/docs/guide/gpu?utm_source=openai)) | No provider onboarding. | Developer chooses workload/function and GPU request. | Buyer-side usage pricing, not provider earnings. | Useful only as buyer-side GPU selection UX. |
| Replicate | Developer model hosting; custom models are deployed on Replicate GPU cluster. ([replicate.com](https://replicate.com/docs/get-started/deploy-a-custom-model?utm_source=openai)) | No provider onboarding; docs cover choosing deployment hardware. ([replicate.com](https://replicate.com/docs/topics/models/hardware?utm_source=openai)) | Model owner/user picks model and hardware; Replicate runs infrastructure. ([replicate.com](https://replicate.com/docs?utm_source=openai)) | Buyer/model-owner cost control, not provider yield. | Not competitive provider-side surface. |
| Darkbloom / d-inference public pages only | CLI installer during alpha; native menu bar app planned. ([darkbloom.dev](https://darkbloom.dev/)) | **Yes, public earnings calculator shows “Auto-selected: most profitable for your hardware.”** It takes Mac type/chip/memory and model catalog compatibility. ([darkbloom.dev](https://darkbloom.dev/)) ([console.darkbloom.dev](https://console.darkbloom.dev/earn)) | Public pages say coordinator matches demand to verified Mac providers; installer page says provider chooses availability. ([darkbloom.dev](https://darkbloom.dev/)) | Yes: earnings calculator estimates usage earnings plus base reward, with demand/utilization caveats. ([console.darkbloom.dev](https://console.darkbloom.dev/earn)) | This partially refutes the hypothesis: not a large generic GPU marketplace, but a close Apple-Silicon inference competitor has a public hardware-to-model earnings calculator. |

**Part 1 conclusion:** Major raw-GPU/decentralized compute networks do not show an installer-time “best model for your hardware” UX, but Darkbloom publicly ships a close earnings-calculator version of the pattern, so SPEC-018 should frame macprovider’s wedge as “installer-integrated, local autotune recommendation,” not “no one has any model-yield recommender.”

**Part 2 — Closest UX Analogues**

1. **StakingRewards.com**
   - Pattern: compare many assets/providers by yield and risk, not just headline APR; StakingRewards describes itself as comparing 90+ providers and 120+ assets with risk grades. ([stakingrewards.com](https://www.stakingrewards.com/?utm_source=openai))
   - Apply: `autotune --recommend` should rank by expected net `$/hr`, but also show risk/confidence fields: demand confidence, thermal risk, memory headroom, and staleness.
   - Pattern: calculator starts from input stake amount and compares returns across assets/providers. ([stakingrewards.com](https://www.stakingrewards.com/calculator?utm_source=openai))
   - Apply: Mac hardware should be auto-detected, then projected across model candidates rather than making the operator manually inspect a rate card.

2. **Lido / RocketPool-style staking dashboards**
   - Pattern: Lido’s calculator displays stake amount, APR, monthly rewards, yearly rewards, and a direct action. ([lido.fi](https://lido.fi/how-lido-works/apr-and-rewards-calculator?utm_source=openai))
   - Apply: install transcript should show “recommended model,” “expected hourly,” “monthly at assumed utilization,” and “start provider” in one compact decision block.
   - Pattern: single-pool dashboards are good at explaining assumptions next to the number.
   - Apply: show assumptions inline: utilization, electricity estimate, rate-card version, benchmark date.

3. **WhatToMine**
   - Pattern: user enters hashrate/power; output is a profitability table, with caveat that final results vary and calculations use mean values. ([whattomine.com](https://whattomine.com/?utm_source=openai))
   - Apply: output should be a ranked table of 3-5 models with mean estimate plus caveat: demand varies, thermal throttling can change realized yield.
   - Pattern: defaults are adapted for known GPU configurations. ([whattomine.com](https://whattomine.com/?utm_source=openai))
   - Apply: auto-detect Mac profile and use known benchmark defaults, but allow override for electricity price / availability hours.

4. **NiceHash**
   - Pattern: profitability calculator supports hashrate, device, and device comparison modes. ([nicehash.com](https://www.nicehash.com/profitability-calculator?utm_source=openai))
   - Apply: support `--json` for machines and a human table for install; include “this Mac vs default Mac tier” comparison.
   - Pattern: QuickMiner benchmarks GPUs and automatically profit-switches to the most profitable algorithm at the moment. ([nicehash.com](https://www.nicehash.com/support/mining-help/quickminer/quickminer-profit-switching?utm_source=openai))
   - Apply: macprovider v0.1 should not auto-switch silently, but it should make re-running recommendation cheap and explicit.

5. **Yield aggregators: Yearn / Beefy / Convex class**
   - Pattern: Beefy shows predicted APY, includes compounding, and says displayed APY includes vault fees. ([docs.beefy.finance](https://docs.beefy.finance/beefy-products/vaults?utm_source=openai))
   - Apply: `expected_net_usd_per_hour` should be net of platform fee and estimated electricity, not just gross token revenue.
   - Pattern: Yearn docs emphasize APY methodology and vault risk inheritance. ([docs.yearn.fi](https://docs.yearn.fi/getting-started/guides/how-apy-works?utm_source=openai)) ([docs.yearn.fi](https://docs.yearn.fi/developers/security/risks/?utm_source=openai))
   - Apply: expose formula/inputs: rate card, measured tokens/sec, expected utilization, electricity, memory tier, and demand confidence.

6. **Cloud cost calculators: AWS / GCP**
   - Pattern: AWS Pricing Calculator estimates workloads/resources/architecture changes in real time, but warns actual fees depend on usage. ([aws.amazon.com](https://aws.amazon.com/aws-cost-management/aws-pricing-calculator/?utm_source=openai)) ([docs.aws.amazon.com](https://docs.aws.amazon.com/cost-management/latest/userguide/pricing-calculator.html?utm_source=openai))
   - Apply: recommendation should state it is an estimate, not a guarantee; realized earnings depend on buyer traffic.
   - Pattern: GCP calculator lets users add/configure products and share estimates. ([cloud.google.com](https://cloud.google.com/products/calculator?utm_source=openai))
   - Apply: JSON output should be reproducible/shareable for support: include `rate_card_version`, `benchmark_id`, and `generated_at`.

7. **Electricity-plan comparison sites**
   - Pattern: plan comparison starts with ZIP/usage and ranks plans using current rates/preferences; some update rates daily. ([choosetexaspower.org](https://www.choosetexaspower.org/?utm_source=openai))
   - Apply: recommendation should include local electricity as a first-class input and show data freshness.
   - Pattern: savings calculators show monthly/yearly estimates, annual savings, and savings percentage. ([energyogre.com](https://www.energyogre.com/savings?utm_source=openai))
   - Apply: show “recommended vs default” delta: `+$0.18/hr`, `+23% vs default`, or “donor-tier, expected net near zero.”
   - Pattern: utility tools compare current plan vs alternatives using past usage. ([sce.com](https://www.sce.com/save-money/rates-financing/rate-plan-comparison-tool?utm_source=openai))
   - Apply: `macprovider status` should compare current configured model against the latest recommendation.

**Part 2 conclusion:** The best import pattern is WhatToMine/NiceHash ranking plus staking-dashboard assumption disclosure: ranked candidates, net yield, confidence, staleness, and explicit “recommended vs alternatives” deltas.

**Part 3 — Differentiation Framing**

macprovider’s provider-install UX sits in a gap left by most decentralized GPU networks. Vast, RunPod, io.net, Akash, Aethir, Render, and Bittensor generally expose raw capacity, bids, node eligibility, subnet incentives, or buyer-selected workloads; their public provider flows do not show an installer-time recommendation that says “given this hardware, run this model to earn the most.” That difference follows from their market structure: the buyer brings a container, manifest, render job, or subnet task, while the provider supplies capacity or competes under a protocol.

The closest competitive exception is Darkbloom. Its public pages show an Apple-Silicon inference network, a CLI provider install path, and an earnings calculator that auto-selects the “most profitable” model for a chosen Mac hardware profile. That means macprovider should not claim the entire idea is unobserved. The sharper wedge is that SPEC-018 makes the recommendation local, installer-integrated, benchmark-backed, and machine-readable via `autotune --recommend`, rather than only a web estimate.

The right UX lineage is not generic cloud hosting. It is staking calculators and mining profitability calculators. StakingRewards-style surfaces rank heterogeneous yield options and disclose risk; WhatToMine/NiceHash-style surfaces translate hardware, power, rates, and current market data into ranked profitability. macprovider has the same shape: detected hardware plus measured tokens/sec plus a per-model rate card plus demand assumptions yields a ranked recommendation.

This will not create demand where none exists. SPEC-018 answers “which model should this provider run, given known rates and measured local performance?” It does not answer “will buyers show up?” The UX must say that clearly: expected `$/hr` is an estimate conditioned on demand, utilization, uptime, electricity, and the current rate card.

**Part 3 conclusion:** Frame SPEC-018 as installer-integrated yield recommendation for inference providers: competitive against raw-capacity marketplaces, informed by staking/mining calculators, and honest that recommendation optimizes model choice, not market demand.

**Part 4 — v0.1 SPEC Implications**

1. **Output schema for `autotune --recommend`**
   - Tie-back: WhatToMine/NiceHash rank alternatives; Beefy/Yearn disclose net APY/risk; AWS/GCP preserve estimate assumptions.
   - Suggested JSON shape:

```json
{
  "schema_version": "autotune_recommend.v1",
  "generated_at": "2026-06-30T12:00:00Z",
  "hardware": {
    "machine": "MacBook Pro",
    "chip": "M4 Max",
    "memory_gb": 48,
    "detected": true
  },
  "inputs": {
    "rate_card_version": "2026-06-30",
    "electricity_usd_per_kwh": 0.15,
    "assumed_utilization": 0.8,
    "availability_hours_per_day": 18
  },
  "recommended_model": "qwen3-14b",
  "candidates": [
    {
      "rank": 1,
      "model": "qwen3-14b",
      "fits": true,
      "expected_net_usd_per_hour": 0.42,
      "expected_gross_usd_per_hour": 0.47,
      "electricity_usd_per_hour": 0.03,
      "platform_fee_usd_per_hour": 0.02,
      "tokens_per_second": 41.2,
      "memory_headroom_gb": 8.1,
      "confidence": "medium",
      "why": "highest net yield among compatible models"
    }
  ],
  "comparison": {
    "default_model": "gemma-7b",
    "recommended_delta_usd_per_hour": 0.18,
    "recommended_delta_percent": 75
  },
  "warnings": [
    "Earnings depend on buyer demand and realized utilization."
  ]
}
```

2. **Install transcript copy**
   - Tie-back: Lido gives monthly/yearly rewards next to APR; electricity-plan tools show savings vs current/default; Darkbloom discloses demand caveats.
   - Happy path:

```text
Detected MacBook Pro M4 Max, 48 GB unified memory.
Benchmarked 4 compatible models against rate card 2026-06-30.

Recommended: qwen3-14b
Expected net: $0.42/hr at 80% utilization
Why: +$0.18/hr vs default gemma-7b, 8.1 GB memory headroom

This is an estimate, not a guarantee. Actual earnings depend on buyer demand,
uptime, thermal state, and rate-card changes.

Start provider with qwen3-14b? [Y/n]
```

   - Donor-tier path:

```text
Detected MacBook Air M1, 8 GB unified memory.
No paid model currently clears the minimum net-yield threshold.

Best compatible option: tinyllama
Expected net: $0.00-$0.01/hr before demand risk
Recommendation: donor mode only

You can still run a provider to support network coverage, but this Mac is
not expected to earn meaningful revenue on the current rate card.
Enable donor mode? [y/N]
```

3. **Re-tune cadence + UX**
   - Tie-back: NiceHash profit-switching shows market-aware re-optimization, but automatic switching is risky for inference provider stability.
   - v0.1 decision: make `autotune --recommend` rerunnable and idempotent; do not silently switch models.
   - Trigger recommendation prompts on install, manual `macprovider autotune --recommend`, and rate-card version change.
   - Store last recommendation summary with `generated_at`, `rate_card_version`, and `benchmark_id`.

4. **Donor-mode opt-in**
   - Tie-back: electricity-plan sites show “you could save $X” before switching; macprovider should show “you would earn $X less” before override.
   - v0.1 decision: require explicit opt-in for non-recommended or below-threshold operation:
     - CLI: `macprovider configure --model tinyllama --donor-mode`
     - YAML: `donor_mode: true`
     - Install prompt default: No
   - Warning copy: “This choice is estimated to earn `$X/hr` less than the recommended model” or “below minimum revenue threshold.”

5. **Status-command integration**
   - Tie-back: utility tools compare current plan vs alternatives using actual/past usage; io.net dashboards show earnings and compute job metrics.
   - v0.1 decision: `macprovider status` should include:
     - current model
     - last measured `tokens/sec`
     - observed earnings last hour/day if available
     - estimate from last recommendation
     - stale recommendation warning
     - better available model, if any

```text
Model: gemma-7b
Estimated net: $0.24/hr
Observed last 24h: $3.10 total
Recommendation stale: rate card changed 2026-06-30

Run: macprovider autotune --recommend
Potential improvement: qwen3-14b estimated $0.42/hr (+$0.18/hr)
```

**Part 4 conclusion:** SPEC-018 v0.1 should specify a ranked, net-yield JSON contract; install copy with assumptions and deltas; explicit re-tune triggers; donor-mode guardrails; and status integration that compares current model to the latest recommendation.

**Part 5 — Liftable One-Line Conclusions**

- Part 1: Major decentralized GPU networks mostly avoid the provider model-choice problem; Darkbloom is the notable close exception with a public hardware-to-model earnings calculator.
- Part 2: Import the WhatToMine/NiceHash ranked-profitability pattern and the staking-dashboard assumption/risk-disclosure pattern.
- Part 3: macprovider’s wedge is installer-integrated, benchmark-backed model yield recommendation for heterogeneous consumer inference hardware.
- Part 4: v0.1 should lock the recommendation as a transparent ranked estimate, not a guaranteed income claim or silent auto-switcher.
tokens used
248 684

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
