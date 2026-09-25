LOW — stale coordinator release-train baseline
`docs/releases/coordinator-release-train.md:131,137-141`

The “Next coordinator release” section still says it is net against `v1.8.190` and retains #1728/#1713, although the same document states Pearl is already on `v1.8.193` containing them. An operator could misread the v1.8.194 payload and duplicate already-live work.

INFO — architecture and integrity checks pass

- Runtime lane is correct: buyer-serving re-hashes make content-lane evidence (e) `NO_GO`; `compare-live` independently returns `descends`.
- New Tier-2 `catalog_id` is correct for changed model entries, not an expiry-only renewal. Its broad admission revocation effect is explicitly documented and requires journal counting plus provider re-admission.
- The seven-row deferred buyer-E2E bar is honest given no provider currently serves them. Keeping #1735 open and requiring Studio verification plus strict-pinned buyer/settlement evidence when each first gains a provider is the correct closure bar.
- Old-hash reconnects being fenced under SPEC-023-R010 is expected because `model_sha256` is part of row identity.
- All eight hashes match `sweep.json`; MATCH rows and requested semantic fields are unchanged; Tier-2 tuples match candidates.
- `catalog-release.py verify`, `test-catalog-release.sh`, and `git diff --check` pass.

VERDICT: C=0 H=0 M=0 L=1
