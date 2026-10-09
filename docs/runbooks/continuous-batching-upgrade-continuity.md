# Continuous-batching upgrade continuity

Related: #1893.

## Adversarial verification of the reported regression

The runtime authorization boundary is intentional. SPEC-038 FR-CB10 requires
an authentic release-bound SPEC-023 policy, exact measured identity, local
proof, and paged-KV attachment. The missing boundary was operational continuity:
a signed empty policy could pass release catalog checks, and a joined provider
could pass upgrade readiness while a previously active tuple serial-routed.

The release-train record distinguishes these milestones:

- Signed 202: the 2026-09-28 Studio swap explicitly recorded scheduler-admitted
  A3B serving and approximately 2.86x aggregate throughput.
- Public 207 (`d98b74a6`) predates mandatory signed-policy authorization.
- #1803 (`b55463f6f`, 2026-09-30) introduced that authority with an empty policy.
  Runtime tag 209 contains it, but is not evidence of a provider deployment.
- Signed private provider 213 (`8b2d857f`) replaced 207 on Studio on 2026-10-03.
  Its source policy is empty. It is the first affected installed provider
  candidate established by package/source history; loss is inferred from the
  exact policy and fail-closed runtime, because no contemporaneous inactive
  status capture is recorded.
- Public signed 217: the 2026-10-06 Studio record directly reports
  `live_verified` with zero policy entries and CB off. This is the first
  directly recorded inactive release, not evidence that 223 caused the loss.
  GitHub release metadata checked on 2026-10-09 shows it is also the first
  public Darwin provider release after 207: intervening published 208, 209,
  210, 211 and 216 contain no Darwin tarball or Malibu DMG. 213, 214 and 215
  were private acceptance candidates, not public provider releases.
  Compare [207](https://github.com/Augustas11/macprovider/releases/tag/v1.8.207)
  and [217](https://github.com/Augustas11/macprovider/releases/tag/v1.8.217).

See [the release train](../releases/cli-release-train.md), especially its
213 physical acceptance and historical Studio canary rows. Current `main`
contains exact signed 224 coverage. Do not restore historical 223 by downgrading
a newer live provider.

A read-only observation on 2026-10-09 found the designated Studio serving
signed 224 on `published-2026-10-09-native-mtp-v224-v2`, with CB `active=true`,
`live_verified`, `authorized=true`, `local_proof_result=passed` and paged KV
`attached`. The coordinator recommends 224. This supersedes the issue's old
operational snapshot, but does not by itself establish a request-correlated
Malibu gateway acceptance proof. Keep that acceptance item open; do not claim
that a status observation completes the issue.

## Existing qualification

Reuse the [formal A3B evidence](../research/spec048-r015/evidence-2026-10-02-a3b-formal/README.md),
[amended gate evidence](../research/spec048-r015/evidence-2026-10-06-a3b-amended-gates-quiet-26a434/README.md),
and [217 CB gate record](../research/spec048-r014/evidence-2026-10-06-v1.8.217-26a434/records/cb15-a5-pkv13.json).
This continuity change does not change the decode path and does not justify a
new qualification benchmark. New package identities still require reviewed
release-bound policy coverage; prior qualification is not an identity grant.

## Release and upgrade acceptance

Use `scripts/ops/cli-release.sh status`, then `next`, for the release train,
and `scripts/ops/catalog-activate.sh status`, then `next`, for policy publication.
Only `next --run` may execute a live mutation. One session owns the live lock.
Do not replace a live Malibu-joined provider with a local unreleased build.
A successor package must preserve qualified tuple coverage before promotion
and recommendation, and preserve runtime activation after upgrade. A provider
being connected does not meet this gate. Record any intentional disable in a
reviewed operator decision with its exact tuple and reason.

## Enforced source gates

The reviewed `studio-qwen3.6-a3b-v1` baseline in
`scripts/cb_release_baselines.py` preserves model, tokenizer/template, hardware,
cache/KV and kernel identity independently of release-specific grant digests.
Catalog publication and renewal retain it; public promotion and discovery gates
require coverage for the successor's signed code identity. A policy may include
both old and successor grants during the transition. Do not revoke the old grant
before the provider upgrade has completed.

The CLI canary gate requires a fresh status observation and the existing
provider-attributed gateway proof, including movement of the CB scheduler's
`shared_forward_calls` counter. Generic request counters cannot satisfy CB
acceptance. Old status-only markers and journey run IDs
cannot substitute for that activation observation. Upgrade markers preserve the
prior active model/cache tuple across both automatic upgrade rails and manual
managed-provider updates; readiness and rollback cleanup retain the marker until
CB is healthy. Missing managed status blocks the swap, and CB loss records a
bounded `continuous_batching_preservation_*` reason through update events.

Adding another qualified release baseline or intentionally disabling a protected
one requires a reviewed change naming the tuple, operator decision and reason.
There is no runtime switch that exempts an unexplained loss from continuity.
Signed successor upgrade/rollback acceptance and request-correlated live gateway
proof remain release acceptance gates; source tests do not replace them.
