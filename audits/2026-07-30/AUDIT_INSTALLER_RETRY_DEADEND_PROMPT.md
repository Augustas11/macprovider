# Audit: installer retry dead-end fix (fix/installer-first-try-live)

## Scope
Full diff of branch `fix/installer-first-try-live` vs `origin/main`. Two files:
- `phase3-binary/dist/install.sh` — `prefetch_upgrade_autotune_model`
- `phase3-binary/dist/test/provider_upgrade_transaction.test.sh` — regression cases

## Context / intent
An installer that finds an existing on-disk install (`EXISTING_INSTALL_WAS_PRESENT=1`)
took an "upgrade" path that pins the fresh recommendation to the exact
signed-catalog model id read from the existing config
(`model_catalog_model_id`). If that field is empty (prior install was
donor-mode, never-started, or a minimally-seeded config from an interrupted
first run) and the stored recommendation is stale, the code hit
`die 6 "stale upgrade recommendation lacks an exact signed-catalog model
identity"`. Because Malibu's "Retry" re-runs the installer, this dead-ended the
retry loop permanently with no running provider to protect.

The fix: when there is no pinned catalog model id AND no provider service is
actually running (`INSTALL_TX_SERVICE_WAS_ACTIVE=0`), fall through to a full
fresh recommendation (`return 0`, leaving the empty candidate id so the caller
runs an unpinned `run_autotune_recommend_apply`). When a provider service IS
running, keep failing closed so a live earner is never stopped for a blind
re-tune.

## Money-path invariants to check
1. Does the fall-through ever cause a RUNNING provider to be stopped/replaced
   without protection? (Confirm `INSTALL_TX_SERVICE_WAS_ACTIVE` is set before
   `prefetch_upgrade_autotune_model` runs, and is the right signal.)
2. Downstream: after `return 0` with empty `AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID`,
   trace the caller (search `prefetch_upgrade_autotune_model` call site and the
   `AUTOTUNE_RECOMMENDATION_REQUIRED` block). Does the unpinned
   `run_autotune_recommend_apply` path correctly benchmark + apply a paid model,
   start the provider, and require coordinator buyer-serving admission before
   commit? Any way this bypasses signature/catalog/artifact verification?
3. Is there a state where the old `die 6` was actually protecting against
   something real (e.g. a live paid provider whose config lost its catalog id)
   that the new `INSTALL_TX_SERVICE_WAS_ACTIVE` gate fails to cover?
4. Transaction safety: does falling through change cutover/rollback ordering
   vs the original? (`mark_install_cutover_started`, `ensure_port_free`,
   `commit_install_transaction`.)
5. Test correctness: do the new regression cases actually exercise the branch,
   and are the mocked globals (`die`, `log`, `INSTALL_TX_SERVICE_WAS_ACTIVE`)
   faithful to runtime?

## Bar
Report CRITICAL / HIGH / MEDIUM / LOW / INFO. Bar for merge: 0 C / 0 H / 0 M.
Cite exact file:line. Do not propose stylistic churn.
