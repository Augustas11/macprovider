# AUDIT: SPEC-023 v3 keypair rotation + catalog re-sign — ARCHITECT lens

## Change under audit

Branch: `fix/spec023-catalog-v3-resign` on top of `origin/main` (v1.7.9 + install.sh AMFI retry).

Read the DIFF with:

```
git -C /Users/augstar/macprovider-catalog-v3 diff origin/main
```

See `specs/AUDIT_SPEC_023_V3_KEY_ROTATION_CODE_PROMPT.md` for the file
list and CODE-lane context.

## What the change does — architect-relevant summary

- Rotates the SPEC-023 signing key v2 → v3.
- Republishes the live catalog with **advisory** `min_sustained_tps`
  values calibrated for M-Base hardware, so `tps_below_gate` warnings
  become rare rather than common.
- Formalizes SPEC-023 v0.2 to lock in the v1.7.9 "gates are advisory,
  not hard" semantics, the v2 → v3 key rotation, and the catalog value
  cuts. The SPEC-023 v0.1 previously described the gates as hard
  blocks; v0.2 corrects that.
- Adds a repo-committed re-sign script + key-handling docs so the next
  operator can rotate without archaeology.

## ARCHITECT lens — what to audit

Focus on architectural fit, scope discipline, naming, and long-term
maintenance. Other lenses cover correctness (CODE) and security posture
(SECURITY).

1. **SPEC-023 v0.2 amendment shape.** The v0.2 change-log entry is a
   two-part bundle: (i) advisory-gate reclassification (which shipped
   as v1.7.9), (ii) v2→v3 key rotation + catalog cuts (this PR). Argue
   whether bundling (i) + (ii) into one SPEC version is right, or
   whether (i) should have been v0.1.1 and (ii) v0.2. Consider that
   (i) is already shipped and the amendment retroactively documents
   it.
2. **`min_sustained_tps` field name.** The v0.2 amendment notes the
   field is now advisory, not a hard minimum, and suggests future
   hard-floor policy should use `hard_min_sustained_tps` rather than
   overloading this name. Argue whether the current bundle should
   also (a) rename to `advisory_min_sustained_tps` for clarity now,
   or (b) keep the name to preserve signed-catalog compatibility with
   any offline / air-gapped provider. Recommend.
3. **Baked vs. live catalog drift.** The live feed at
   `coordinator.streamvc.live/static/autotune-candidates.json`
   contains only `runtime_status=recommendable` rows (5 models); the
   baked catalog in `AutotuneRecommend.swift` also contains
   `runtime_status=listed` (qwen3-32b, qwen2.5-coder) and
   `runtime_status=blocked` (google-gemma, nvidia-nemotron) rows for
   test-fixture stability. Argue whether this drift is a smell or an
   intentional feature. If a smell, propose the smallest cleanup.
4. **Repo-committed re-sign script + off-repo key.** The script is at
   `scripts/resign-autotune-static.sh` and reads the private key from
   an operator-local path. Compare with alternatives:
   - CI-only signing (private key in GitHub Actions secrets): trades
     latency + tooling complexity for stricter enforcement.
   - Local-only signing but no committed script (script lives in
     operator's local dotfiles): no discoverability.
   - Current: committed script, off-repo key.

   Argue whether the current choice is right for this repo's
   operational scale.
5. **Rotation cadence.** SPEC-023 v0.1 introduced v2 on 2026-07-01;
   v0.2 rotates to v3 on 2026-07-03. Two rotations in three days.
   Argue whether the operational cost of a rotation (bump keyID +
   pubkey + tests + regen sigs + release + deploy) is right-sized
   or whether we should adopt a rotation SLA (e.g. "rotate every 12
   months" or "rotate on incident only"). Recommend.
6. **v1.7.9 → v1.7.10 client cohort trajectory.** Older v1.7.9- clients
   in the field will start falling back to their baked catalog once
   the live feed goes v3-signed. Argue observability:
   - Providers running v1.7.9 will emit `candidate_catalog_fallback_used`
     warnings but keep working.
   - Do we have coordinator-side telemetry that surfaces the
     fraction of v1.7.9 vs v1.7.10 providers over time?
   - If yes, note where. If no, is that a scope gap we should file?
7. **Baked catalog `min_sustained_tps` sync.** Baked values in
   `AutotuneRecommend.swift` mirror live-feed cuts for the 4 rows we
   lowered, plus `qwen3-32b` stays at 30 in baked (M-Max-tight) even
   though it's 15 in live. Argue whether baked should track live
   exactly, or whether it's OK for baked to be conservatively tighter
   (i.e., a v1.7.10 offline provider gets a stricter local floor than
   an online one).
8. **`AutotuneStaticInputs.publicKeyName` static constant.** The
   change updates `publicKeyName` from
   `"autotune_static_json_ed25519_v2"` to `"...v3"`. This constant
   doesn't appear to be used in code paths I can see other than the
   public-key baking line. Argue whether this constant serves any
   purpose beyond documentation, or whether it's dead metadata that
   should be dropped in a future cleanup.
9. **`scripts/resign-autotune-static.sh` companion tests.** The
   AMFI-retry PR (#336) added a committed shell test. Should this PR
   also add a committed test for `resign-autotune-static.sh`
   (round-trip: sign → verify against baked pubkey)? Consider that the
   script depends on an operator-local private key file that isn't
   present in CI.
10. **v3 → v4 rotation procedure in the keys/README.** The README
    documents a 10-step rotation procedure. Argue whether that
    procedure is complete and whether it should be codified as a
    `scripts/rotate-autotune-static-key.sh` helper (semi-automated)
    to reduce future rotation risk.
11. **DECISION_CRITERIA entry.** Should this PR also add a decision-log
    entry in `beta/DECISION_CRITERIA.md` capturing the v0.2 amendment
    rationale (soft gates + v3 rotation + M-Base cuts)? House style has
    Entries 1-21 covering prior decisions of similar weight.

## Bar

CRITICAL / HIGH / MEDIUM must be fixed. LOW / INFO may ship with
PR-body documentation. Return findings as a structured list.
