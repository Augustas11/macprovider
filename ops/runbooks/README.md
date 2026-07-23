# Ops runbooks

| Track | Runbook | Scope |
|-------|---------|-------|
| **B — Proof of Weights** | [`proof-of-weights-implementation.md`](./proof-of-weights-implementation.md) | W1–W4 integrity (hello gate, model-class probes, drift alerts) |
| **A — OPoI** | [`opoi-challenge-implementation.md`](./opoi-challenge-implementation.md) | Liveness canaries |
| **A — OPoI Pearl** | [`opoi-pearl-deploy.md`](./opoi-pearl-deploy.md) | Pearl canary overlay deploy |
| **C — $MALIBU bootstrap** | [`malibu-bootstrap-emission.md`](./malibu-bootstrap-emission.md) | Emission ledger, caps, Trusted unlock, Malibu UI |
| **C — MALIBU Pearl** | [`malibu-pearl-deploy.md`](./malibu-pearl-deploy.md) | Session C4 Pearl migration + overlay |
| **Catalog release + provider upgrade** | [`catalog-release-provider-upgrade.md`](./catalog-release-provider-upgrade.md) | Signed publication, coordinator activation, provider transaction, rollback |
| **#608 Llama Tier-2 republish** | [`608-llama-tier2-republish.md`](./608-llama-tier2-republish.md) | Reviewed `stage-tier2-republish` staging for the live Llama-3.2 autotune/Tier-2 CONFLICT; Pearl apply steps not yet executed |
| **B — Entry 172 referrals** | [`entry-172-referral-activation.md`](./entry-172-referral-activation.md) | Reversible private-prebeta referral activation checklist |
| **#615 production exceptions** | [`production-exception-register.md`](./production-exception-register.md) | Machine-readable production exception register maintenance |
| **#582 stranger onboarding** | [`582-stranger-hardware-trust-onboarding.md`](./582-stranger-hardware-trust-onboarding.md) | No-exception install → evidence → durable trust approve → admit → ready |
| **#540 AEAD rekey** | [`540-aead-rekey-oneshot.md`](./540-aead-rekey-oneshot.md) | Isolated, approved, no-retry request/age rekey evidence |
| **#584 emergency-disable drill** | [`584-emergency-disable-drill.md`](./584-emergency-disable-drill.md) | Pearl kill-switch drill paper; never re-enables timer/gates |
| **#584 physical baselines** | [`584-physical-baseline-matrix.md`](./584-physical-baseline-matrix.md) | Per-tier floors + thermal/memory collection matrix before re-enable |
