# SPEC-018 v0.2.4 Draft Notes

Purpose: r4 polish absorption after all six r4 audit lanes returned READY TO LOCK.

## Polish Ledger

1. Critic m-2 - AC-44 fabricated SPEC-006 NTP citation
   - Location: `specs/SPEC-018-agentic-tool-calling.md` AC-44.
   - Edit: removed the SPEC-006 inheritance citation while preserving the 100 ms NTP-anchored skew bound, heartbeat verification, and skew-corrected p95 target.
   - Replacement: AC-44 now states that operators MUST run NTP on provider Macs and gateway hosts; this is a v0.2 prerequisite, not inherited from another SPEC; IMPL prompt will add `chrony` / `timesyncd` to the deployment checklist.
   - Verification: ran `rg -n -i 'ntp|clock|skew|time[- ]?sync|timesync|chrony' specs/SPEC-006-buyer-api.md specs/SPEC-006-design.md`; command returned no matches, confirming SPEC-006 does not contain NTP/clock/skew/time-sync language.

2. Critic m-3 - AC-56 vacuous total-decoded-prompt cap
   - Location: `specs/SPEC-018-agentic-tool-calling.md` AC-56, §10d.0 stable code table, and §10d.1 aggregate request-side caps/failure table.
   - Edit: deleted AC-56 entirely, removed the §10d.1 6 MiB decoded-prompt cap paragraph, removed `prompt_aggregate_too_large` from the stable code table, and removed the matching request-side failure row.
   - Rationale: AC-50's 4 MiB raw request-body cap plus AC-51/AC-52 aggregate decoded caps already bound aggregate prompt material; the 6 MiB decoded-prompt cap could not bind under a 4 MiB raw-body cap.
   - Verification: post-edit grep checks assert no current normative AC/code/table reference remains for `AC-56` or `prompt_aggregate_too_large`.

3. Architect m-1 - §3 subsection ordering callout
   - Location: `specs/SPEC-018-agentic-tool-calling.md` §3 heading.
   - Edit: added a subsection note explaining the intentional non-sequential order (§3.1-§3.6, then §3.8, then §3.7), why §3.8 physically precedes locked §3.7, and that §3.9 was deleted in v0.2.3 with pointer to §10c.1 Amendment 2.
   - Verification: `rg -n '^### 3\\.' specs/SPEC-018-agentic-tool-calling.md` shows the intended physical order and the §3.9 deleted stub.

4. Critic m-1 + Narrative m-1 - §3.9-deleted breadcrumb in §3
   - Location: `specs/SPEC-018-agentic-tool-calling.md` after §3.7 "Adding a new family".
   - Edit: added `### 3.9 [DELETED v0.2.3]` with a local explanation of the deleted v0.2.1 minimal prompt-echo guard, the three defects, and the v0.3 full echo-guard destination.
   - Verification: local §3 scan now exposes the deleted heading without requiring a reader to jump to §10c.1 first.

5. Critic Q-1 - locked-content vs draft-content amendment governance
   - Location: `specs/SPEC-018-agentic-tool-calling.md` §10c.1 after the amendment log.
   - Edit: added a note that §10c.1 covers both locked-content amendments and in-flight draft-content revisions under the same (a)-(d) discipline in v0.2.4, with possible governance refinement deferred to v0.3.
   - Verification: §10c.1 now explicitly names Amendment 1 as locked-content and Amendment 2 as in-flight draft-content.

## Versioning

- Header bumped to `0.2.4 (2026-06-27, r4 polish — AC-44 citation fix + AC-56 deletion + §3 ordering note + §3.9-deleted breadcrumb + §10c.1 governance note)`.
- Status updated to `Draft — codex 4-lane r4 0/0/0; Claude blind-spot r2 0/0/0; v0.2.4 r4 polish absorbed; LOCK CANDIDATE pending PR.`
- Change log now leads with v0.2.4 buyer-visible deltas, first bullet: `v0.2.4 is the SPEC PR candidate.`
