# SPEC audit R1 — BYOM v0.2 slice 3 (SPEC-010 v1.7 / SPEC-023 v0.10.3 / SPEC-047 v0.1.4)

**Diff reviewed:** `git diff origin/main...HEAD` at `74888327`. **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 0 H / 4 M / 2 L |
| security-reviewer | **0 C / 0 H / 0 M** / 1 L — at the bar |
| architect | 0 C / 0 H / 2 M / 1 L / 1 I |

All resolved in the commit that adds this record:
- **M (code, architect):** R001 still required the row digest for every snapshot-manifest report; R004's retained-Tier-2-proof clause and R006's §3.2-validation sentence assumed the primary path. Each now scopes to the selected identity: primary path unchanged; a secondary snapshot verifies at the member's revision against the member's hash and reports that digest; retained proof of the primary row is never proof of another member; warm swap validates under the selected artifact's algorithm.
- **M (code, architect) / L (security):** the primary six-value exemption was broader than SPEC-047-R003 / AC-CAT-20. Narrowed everywhere (R007(d), R004, SPEC-023 §3.7 intro, §3.7.7, AC-CAT-17, SPEC-047-R003): only a primary identity bound directly through the signed candidate row is exempt; every feed-derived binding, the feed's primary entry included, carries and re-verifies all six.
- **M (code):** the §15 artifact-substitution threat-model row still restricted settlement to the primary; it now describes the R007 protections.
- **L (code, architect):** SPEC-023 §3.7.7 and SPEC-047-R003 restated R007's exclusion list; both now cite R007(b).
- **L (code):** R007(b) now distinguishes a failed artifact-derived verification from the independent primary-row outcome (stale feed + valid primary pair verifies through the row); AC-CAT-17 states the case.
- **I (architect):** R007(a) now requires the digest to be recomputed over the file resolved for the runtime instance and fail closed on file-identity change; blob resolution and serving continuity remain the runtime path's concern (R007(e)).

R2 runs the code-reviewer and architect lanes; the security lane met the bar.
