# R4 (verification only) — CODE lane (omc ask codex)


R3-H1 — FIXED — `CoordinatorClient.swift:6337–6343` restores local readiness and keepalive without clearing revocation; `:6447–6457` finalizes restoration and requires no pending transaction before retry. No changed-line regression identified.

R3-M1 — FIXED — `CoordinatorClient.swift:2220,2251,2553–2559` fences late restore cleanup by teardown epoch, preventing cleanup of a replacement session. Cancellation remains unjoined, but the reported cleanup race is fenced. No changed-line regression identified.

R3-M2 — PARTIAL — `AutoUpdateTests.swift:2407–2420` now checks swap refusal, unchanged bytes, and marker cleanup; it bypasses drain/restart and withdraws authorization before invocation. `:4089,4100–4107` still rejects before release resolution. Drain withdrawal and post-eviction rollback remain untested. No changed-line regression identified.

C1 — FIXED — `CoordinatorClient.swift:2220,2251,2554,2559` captures, checks, and advances the cleanup epoch; `CoordinatorClientTests.swift:7829` covers stale-epoch cleanup. No changed-line regression identified.

C2 — FIXED — `AutoUpdateMarker.swift:497–515,2623–2631` serializes policy persistence; `AutoUpdater.swift:1145–1159` holds that lock across final authorization and activation/restart. No changed-line regression identified.

VERDICT: C=0 H=0 M=1 L=0
