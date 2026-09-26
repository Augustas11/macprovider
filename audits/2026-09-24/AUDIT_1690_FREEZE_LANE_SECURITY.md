Read `audits/2026-09-24/AUDIT_1690_FREEZE_COMMON.md` first.

**Lane: security and money path.** Check:
- whether anything lets a loopback runtime produce settlement credit or a signed receipt
- whether the pool-label verdict path can alter outcome, usage or ledger columns, or attribute disputed traffic
- whether the candidate-env gate can be bypassed (reload, replay, config paths)
- the loopback HTTP client path allowlist and origin handling (loopback-only?)
- request-size caps
- whether the operator-pause runner can leave a provider paused on any exit path
- whether the new config validation can brick a production coordinator at startup

Evaluate by reading only.
