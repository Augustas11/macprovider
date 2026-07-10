CRITICAL (0): None.

HIGH (0): None.

MEDIUM (0): None.

LOW (0): None.

QUESTIONS (0): None.

Security review notes:

- SEC-1 disclosure surface: `auth_state` is a `pool.AuthState` enum/string read from `pool.Provider.AuthState`. The defined values are `bearer_validated`, `self_minted`, `bearerless_duplicate`, `mint_failed`, plus legacy empty string. This does not expose bearer tokens, token hashes, source IPs, or other credential material. The same provider projection already exposes more operationally sensitive identifiers/statuses such as `provider_id`, `assigned_id`, `hostname`, `model_id`, `token_status`, and `token_prefix`, so adding admission-state classification is not a new credential disclosure boundary.

- SEC-2 authorization boundary: `/admin/explorer/providers` and `/admin/explorer/providers/{id}` are dispatched only after `Handler.ServeHTTP` calls `h.authorized(r)`. That helper uses `auth.OperatorOnlyBearerMatches(r.Header, h.cfg.Auth.OperatorKey)`, whose contract is human-admin/operator-only and explicitly denies empty operator keys and gateway service tokens. Item 4 changes only the provider JSON map and tests; no handler routing or auth predicate changed.

- SEC-3 cross-surface consistency: `/poolz` is also operator-only via `Server.handlePoolz` -> `s.authorizedOperator(r)` -> `auth.OperatorOnlyBearerMatches`. Its response embeds `pool.Provider`, whose `AuthState` JSON tag is `auth_state`; therefore `/poolz` already exposes the same field at the same auth tier. Explorer alignment is appropriate because it prevents operators from needing to cross-reference `/poolz` to identify SPEC-003 FR-C9.4 non-routable duplicate sessions.

- SEC-4 no write path: the change is a read-only projection in `providerMap`: `"auth_state": p.AuthState`. `Store.Providers` and `Store.ProviderDetail` receive a pool snapshot/provider, enrich it with token status reads, and serialize JSON. No new mutation, database write, registry update, token minting, or auth-state transition is introduced.

VERDICT: security lane READY TO MERGE
