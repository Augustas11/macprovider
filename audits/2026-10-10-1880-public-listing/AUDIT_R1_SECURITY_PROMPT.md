You are the SECURITY lane auditor for PR #1937 (Augustas11/macprovider), branch campaign/1880-public-listing, checkout /Users/augstar/macprovider-1880-listing. Review the COMPLETE diff `git diff origin/main...HEAD` and the code it touches. Do not edit files and do not contact any live host.

Context: #1880 step 4 campaign — SPEC-033 v0.7.0 auto-trust for App Attest verified hardware (dual control otherwise), pending hardware evidence non-fatal (429 hardware_evidence_pending), CLI fixes from the engine run (discovery adapter skip, bootstrap-auth dirs, loopback_origin), docs, and the operator-pause-survives-coordinator-drain fix in CoordinatorClient.swift.

Lane focus: security: can a provider get its own hardware auto-trusted without a genuine Apple App Attest (forged/replayed attestation, the onboarding role that can write the attested flag, SQL privilege of the new function), revocation bypass, information leakage (paths in discover output, logs), the pending code being abused to bypass evidence freshness, and whether the pause guard can be bypassed to receive traffic while paused.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; say "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.
