# Issue #266 Tranche 1 — SECURITY audit prompt

You are an independent security auditor. Read this prompt + the diff + the files referenced and report findings.

## Context

Issue #266 closes deferred follow-ups from PR #263 (SPEC-004 Pillars B/C/D/A bundled smart-router IMPL on the macprovider coordinator). Tranche 1 (this PR) lands four safety / correctness items:

1. SIGHUP `routing.model_classes` reconfig → `sticky.Map.InvalidateClass` for changed classes
2. Per-attempt FR-SR-17 routing-decision log fields populated on retry
3. Mid-request stable seed across UTC midnight (snapshot `dailyKey` into `forwardState`)
4. `sticky_account_mismatch` warn-log rate-limit per conversation_key

All four flags ship default-OFF in production. Phase 2 operator green-light flips them ON later.

## Changed files (read these in full)

- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/forward_state.go`
- `phase4-coordinator/internal/buyer/forward_with_failover.go`
- `phase4-coordinator/internal/buyer/sticky_mismatch_limiter.go`
- `phase4-coordinator/internal/buyer/iss266_t1_test.go`
- `phase4-coordinator/cmd/coordinator/main.go`

## What to audit (SECURITY lens)

Report severities CRITICAL / HIGH / MEDIUM / LOW. **MEDIUM and above gate merge.**

Focus on:

1. **Hostile-gateway exploitation of stickyMismatchLimiter map.** A gateway controls the `X-MacProvider-Internal-Conv` header (conversation_key). It can drive an arbitrary number of unique keys to grow the limiter's `entries` map. Is the MaxEntries cap (default 10000, matches stickyMap) actually enforced before unbounded growth? Are there race conditions where two goroutines simultaneously growing the map past cap could push it past cap? Review the mutex coverage and the lazy first-loop expiry sweep in evictOldestLocked.
2. **CRLF / log-injection via conversation_key.** The limiter doesn't log the key, but the underlying Warn DOES emit `provider_id` and `model_scope` (NOT the key). Are there any new fields in the per-attempt routing-decision log that an attacker controls AND that are emitted without zerolog sanitization?
3. **Account-attribution preservation under SIGHUP InvalidateClass.** When SIGHUP fires and InvalidateClass(name) purges entries, does it correctly purge entries that belong to OTHER accounts (yes, by design — class-membership-change requires invalidating all entries in that class scope across all accounts)? Is there a window where an account whose attribution survived a cross-account-mismatch attempt earlier could have its entry resurrected by a stale read?
4. **routingMu deadlock potential.** SetRoutingClasses takes routingMu.Lock(); resolveModelClass and snapshotModelClasses take routingMu.RLock(). Is there any path where a goroutine holding routingMu.RLock could call SetRoutingClasses (would deadlock)? Look at the hot path: SIGHUP handler calls SetRoutingClasses; the hot routing path calls resolveModelClass. They run in different goroutines so deadlock is not possible by construction, but verify.
5. **InvalidateClass(className) called with an attacker-influenced string.** The className comes from `cfg.Routing.ModelClasses` which is operator-controlled config, NOT from a buyer/provider request. So no attack surface there. But verify: is there any path where InvalidateClass could be triggered with a string from a request header? (Should be no — the change is one new SetRoutingClasses caller in main.go bound to config-reload only.)
6. **dailyKey snapshot at request entry.** A buyer cannot influence the daily-key value (it's `s.now().UTC().Format(...)`, derived from server clock). Verify there's no path where a header or request body could inject into dailyKey.
7. **Per-attempt log fields (AttemptIndex, RetryCount, RetryReason, Retried, PreflightResult).** Are these values derived solely from internal state (s.now, state.explicitRetries, classifier flags), with no attacker-controlled component that could be used for log shaping or pollution?
8. **TOCTOU on SetRoutingClasses.** SetRoutingClasses computes `changed = diffModelClasses(prev, next)` while holding the write lock, then drops the lock and calls InvalidateClass per name OUTSIDE the lock. Between dropping the lock and calling InvalidateClass, another goroutine could call SetRoutingClasses again. Result: the InvalidateClass calls operate on classes the operator has already changed AGAIN. Is this safe? (Answer: yes, because each InvalidateClass purges entries by class name string — re-running it for a class that's been re-changed is at worst a no-op; correctness is preserved because the LAST SetRoutingClasses caller wins the modelClasses snapshot.) But verify there's no race where stickyMap is updated by a hot-path Update concurrent with InvalidateClass, leading to a write the operator wanted purged surviving.
9. **modelClasses map mutation via snapshot.** snapshotModelClasses returns `cloneModelClasses(s.modelClasses)`. Verify the clone is deep (slices copied, not shared). If shared, an attacker who somehow obtains a returned map could mutate the live config. Test TestSetRoutingClasses_SnapshotIsReadable should be checked for sufficiency.
10. **Default-OFF posture preserved.** The PR ships with `routing.model_classes: {}` as the install default. Does the new code path activate any new behavior when classes is empty? (Should be no — diffModelClasses returns empty, SetRoutingClasses returns nil/0, InvalidateClass not called.)

## Output format

For each finding:
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
- **Location**: file:line
- **Issue**: 1-2 sentences
- **Evidence**: quoted code or attack scenario
- **Fix sketch**: what would resolve it

Final line MUST be:
```
SUMMARY: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>
```
