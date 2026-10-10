# PR #1944 (#1938) three-lane Codex audit

Gate: 0 CRITICAL / 0 HIGH / 0 MEDIUM per lane. Two anchored rounds; no third round needed.

| Round | Code | Security | Architecture |
|---|---|---|---|
| R1 (head 47ea2b7a8) | 0/0/2/7 | 0/0/2/0 | 0/0/3/1 |
| R2 (head dd1d0e9a4) | 0/0/0/2 | 0/0/0/0 | 0/0/0/0 |

R1 MEDIUMs, all FIXED in dd1d0e9a4 and confirmed in R2:
- Evidence supersession ordered by provider generated_at (code, security): now by coordinator job id.
- Native-MTP journey evidence rejected on age (code, architecture): structural only.
- Agreement renewal after grace paused a routing pool (architecture): routing validity decides.
- Discovery renewal removal left pre-v0.1.22 CLIs without recovery (architecture): on-demand workflow and ops entry point restored, unscheduled.
- SPEC-049 overstated withdrawal by entry removal (security): wording qualified.

R1 LOWs: all nine code LOWs and the architecture LOW fixed in dd1d0e9a4.

R2 LOWs (code), fixed in the follow-up commit:
- Stale comments (config.go ApprovedCodeIdentity, ApplyRouteGates, renewal test header, orphan earliestDeadline comment).
- SPEC-023 §12.5 / SPEC-048 0.1.31 wording on when native MTP stays off (store/anchor integrity failures included).

Prompts: AUDIT_R{1,2}_{CODE,SECURITY,ARCHITECTURE}_PROMPT.md. Results: R{1,2}_*_RESULT.md.

SPEC-048 was renumbered on rebase onto #1927 (which took 0.1.28/0.1.29): this campaign's entries are 0.1.30 (structural sidecar/journey expiry) and 0.1.31 (revocation fail-to-last-known). The audit prompts cite the pre-rebase numbers.
