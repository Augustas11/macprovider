# SPEC-037 v0.1.3 ceiling raise — audit verdicts

R1 (`omc ask codex` code + architect): HIGH — `KVDiskCacheStoreConfig.promotionCeilingHardMax` still 256 MiB while the resolver accepted 1 GiB. Security R1: 0 C/H/M.

Fix: store hard cap raised to 1 GiB; coupling test vs `KVDiskCacheConfig.hardStagingMaxBytes`.

R2 complete-diff re-audit:

| Lane | Result |
|---|---|
| code-reviewer | PASS 0/0/0 APPROVE |
| security-reviewer | PASS 0/0/0 |
| architect | PASS 0/0/0 |

Artifacts under `.omc/artifacts/ask/` (gitignored).
