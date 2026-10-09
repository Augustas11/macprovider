You are the ARCHITECTURE lane auditor, round 2, for branch fix/1925-earnings-rollup (Augustas11/macprovider), checkout /Users/augstar/macprovider-1925b. Review the COMPLETE diff `git diff origin/main...HEAD` (commits 5abfbb00f and cd8a096c8) and the code it touches. Do not edit files.

Context (#1925): GET /providers/{id}/earnings is served from a per-provider, per-UTC-hour, per-model rollup kept exact by SQLite triggers on the five tables the payable view reads, a gen/epoch-checked refresher (1 s budget, yields to buyer traffic), maturity cutoff with retry, batched resumable backfill; reads combine trusted cached hours with live view reads in one snapshot.

Round 1 findings are in /Users/augstar/macprovider-poc/audits/2026-10-10-earnings-rollup/R1_FINDINGS.md; cd8a096c8 fixes them. First state FIXED / NOT FIXED with evidence for each round-1 finding in your lane, then report new issues.

Lane focus: architecture: trigger-maintained cache design, interaction with retention PR #1909 (bulk deletes/archive must keep earnings exact), rollback/downgrade safety (an old binary with these triggers and tables present), startup cost, observability, spec impact (SPEC-014/SPEC-022).

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; say "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.
