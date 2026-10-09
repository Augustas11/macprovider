You are the ARCHITECTURE lane auditor for PR #1934 (Augustas11/macprovider), branch ops/release-registrations, checkout /Users/augstar/macprovider-release-registrations. Review the COMPLETE diff `git diff origin/main...HEAD` and the code it touches. Do not edit files and do not contact Pearl or GitHub.

Context: CLI 1.8.230 shipped while Pearl approved only the 1.8.224 privacy code identity, so upgraded providers' privacy advertisements were rejected for ~12 h unnoticed; promotion also kept failing for a missing signed tag. This PR adds train steps and gates so every CLI release registers itself and promotion is refused until it has, plus coordinator metrics and a rollout check.

Lane focus: architecture/process: does this actually close the class of failure (a new CLI missing any coordinator-side registration) — compare against all per-binary registrations (compatibility_set accepted_ids/target_id, privacy approved_code_identities, release identity dir, CB/MTP feeds, version floors); ordering in the train; the one-time Pearl setup; restart requirements; rollback; AGENTS.md rules 5, 8 and 10; docs consistency (privacy runbook, release train, README).

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; say "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.
