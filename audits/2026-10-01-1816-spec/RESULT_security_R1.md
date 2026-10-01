No merge-blocking SECURITY findings.

- **LOW — [SPEC-023:3764](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-023-installer-autotune-recommend.md:3764)**  
  `pool_proven_evidence.source_sha256` refers to source bytes retained under §16.8, but §16.8 only defines the existing stats, offer-intake, and demand-rank sources. It does not define an authenticated source endpoint/schema/file or work bounds for the new settlement aggregate. This weakens reconstructibility and permits inconsistent evidence generation.  
  **Fix:** Define the exact closed source schema, authenticated endpoint or snapshot procedure, retained filename, canonical bytes, size/row ceilings, build timeout, and mandatory re-derivation of counts, suppression, licensing, and window fields.

- **LOW — [SPEC-047:192](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-047-network-model-admission.md:192)**  
  The journey requires the session to be absent from “global paid routing and buyer-final debit.” Read literally, this could prohibit the authorized pool route’s buyer-final debit, contradicting the paid settlement contract.  
  **Fix:** Say it is absent from “global paid routing and any global/poolless buyer-final debit,” while explicitly requiring buyer-final debit for the authorized pool route.

All seven new conformance requirements remain `pending` with empty implementation/test evidence, and the gaps accurately acknowledge the missing runtime work.

VERDICT: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 2 LOW / 0 INFO  
TOTALS: C=0 H=0 M=0 L=2 I=0