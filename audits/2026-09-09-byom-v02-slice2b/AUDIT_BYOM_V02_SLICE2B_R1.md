# Audit R1 — BYOM v0.2 slice 2b: coordinator serving of the SPEC-023 artifact feed + live release gate

**Branch:** `feat/byom-v02-slice2b-artifact-feed-serving` (stacked on slice 2a head `0292b369`, PR #1461)
**Date:** 2026-09-09
**Prompt:** `audits/2026-09-09-byom-v02-slice2b/AUDIT_BYOM_V02_SLICE2B_PROMPT.md`
**Authority:** SPEC-023 v0.10.0 §3.5, §3.7.2–§3.7.6, §3.7.8 Stage A.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R1 verdicts (working-tree diff `git diff 0292b369`, 16 files)

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 0 INFO — REQUEST CHANGES |
| security-reviewer | **0 CRITICAL / 0 HIGH / 0 MEDIUM / 2 LOW / 0 INFO — merge bar met** |
| architect | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 1 INFO |

All three lanes confirmed: release binding (version / policy / generated_at /
candidate digest / signer equality incl. the second-trusted-key case), atomic
SIGHUP reload keeping the prior served set, literal-bytes serving through the
shared handler, 404 + unchanged `/v1/autotune-release` shape for four-feed
releases, exact nginx allow-through blocks, the gate's bidirectional presence
agreement with 404-only absence, Stage A nine-name map untouched, no secrets.

## Findings and resolutions

### N1 — MEDIUM (code-reviewer + architect; security LOW-1): Go decoding collapsed a present JSON `null` with an absent optional field

`*string` fields (`rate_class`, `notes`, the `source_ref` variant fields) and
the required-but-nullable `verified_at` decoded a present `null` and an absent
key to the same nil, so a signed feed the generator's `exact_keys` / type
validation rejects (null-valued optional string, `verified_at` omitted,
cross-variant `source_ref` field present as null) could pass the coordinator.

**Resolution.** `presentString` (optional; present null is a wrong-typed field)
and `requiredNullableString` (`verified_at`: must be present, may be null)
record presence in `UnmarshalJSON`, following the existing
`optionalProvenanceString` / `nullableRank` pattern; the validator closes the
`source_ref` key set per `kind` by presence. Go table cases added: `verified_at`
omitted, `verified_at` null on a verified artifact, `notes:null`,
`rate_class:null`, cross-variant `source_ref` field present as null and as a
value.

### N2 — LOW (architect; security LOW-2): identity rules and gate guards without individual regression cases

**Resolution.** Go table cases added for `policy_version` drift, one hash under
two model keys, GGUF `digest`/`hash` inequality, primary `repo_id` drift, plus a
positive case accepting a declared GGUF secondary. Gate fixtures added for
artifact `version` and `policy_version` drift (re-signed), body and sidecar
metadata-digest mismatch, bound sidecar route absent, unbound sidecar-only
served, and a live-mode probe test proving only 404 is "absent" (200 = served;
500 / redirect / transport failure = gate error).

### N3 — INFO (architect): stale `cmd_status` docstring

**Resolution.** Reworded: the generator produces and binds, the coordinator
serves and the gate verifies (slice 2b); packaging/publishing is still pending.

## Validation after the R1 fixes

- `cd phase4-coordinator && go test ./internal/buyer -run 'CatalogArtifacts|AutotuneFeeds|AutotuneRelease' -count=1` — ok
- `bash scripts/test-live-coordinator-release-gate.sh` — PASS
- `python3 scripts/catalog-release.py status` / `verify` — ok
- `git diff --check` — clean

R2 re-fires the code-reviewer and architect lanes only; the security lane met
the bar in R1 and is not re-run.
