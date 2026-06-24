## Lens — CODE — Round 1

### HIGH

1. `phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh:27-32` — The nginx route check can pass even if the `/catalog/` block is later changed to proxy to the operator port. The script first proves an active `location /catalog/ {` exists, but its buyer-port assertion is a repo-wide grep for `proxy_pass http://127.0.0.1:8443` over all active nginx text. The existing `/v1/receipt-keys/` block already contains that same buyer-port proxy at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:149-155`, so a bad `/catalog/` block using `127.0.0.1:8444` would still satisfy line 30. That leaves the Step 3 static gate unable to verify the specific `/catalog/` proxy target required by `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:183` and the audit prompt's C.4 category.

   Fix: parse the active `/catalog/` block and assert the `proxy_pass http://127.0.0.1:8443` directive inside that block only. While touching the parser, also fail closed if the TLS catch-all 404 anchor is missing; lines 41-47 currently skip the ordering assertion when `CATCHALL_LINE` is empty.

### LOW

- None.

Verification evidence:
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:170-176` currently routes `/catalog/` to buyer port `127.0.0.1:8443` before the catch-all `location /` at lines 205-207.
- `Makefile:33-37` wires `check_nginx_catalog_routes_test.sh` into `test-dist`.
- `bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh` passed, but the false-positive gap above means this is not sufficient evidence for the proxy-target claim.
- `make test-dist` passed; live nginx smoke was skipped by the existing optional guard.
- `git diff --check` passed.

VERDICT: FIX REQUIRED
COUNTS: CRITICAL 0 / HIGH 1 / MEDIUM 0 / LOW 0

## Lens — SECURITY — Round 1

### Findings

- None.

Security checks:
- `/catalog/` is public per `specs/SPEC-015-receipts.md:3308-3322` and `3330-3353`; the nginx block is unauthenticated but proxies only to buyer port `127.0.0.1:8443` at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:170-176`.
- `/poolz` remains an exact operator endpoint on provider port `127.0.0.1:8444` with `Authorization` forwarding at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:122-129`; no public `/poolz` proxy was added.
- The YAML example leaves `catalog_public_key` commented at `phase4-coordinator/dist/coordinator.yaml.example:102-104` and adds no private key or secret-bearing catalog material.
- The public-key response shape in comments preserves base64url-unpadded + capital-E `Ed25519` at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:158-167`, matching `specs/SPEC-015-receipts.md:3350-3363`.

VERDICT: READY
COUNTS: CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0

## Lens — ARCHITECT — Round 1

### HIGH

1. `phase4-coordinator/dist/deploy-pearl-vps.sh:53-83` / `phase4-coordinator/dist/check-deploy-config.sh:1-189` — The Step 3 deploy-time gate is not integrated into the actual Pearl deploy path. The build prompt requires `check-deploy-config.sh` to assert the new nginx routes and fail non-zero when they are missing (`specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:183-190`). The implementation instead adds a standalone test under `make test-dist` (`Makefile:33-37`), while `deploy-pearl-vps.sh` step 0 only invokes `check-deploy-config.sh` before uploading and installing the nginx site. Because `check-deploy-config.sh` has no nginx-conf input or `/catalog/` assertions, an operator-run deploy can still proceed with a stale local `nginx-coordinator.streamvc.live.conf` that lacks the SPEC-015 v0.3 catalog routes.

   Fix: put the catalog route assertion on the same operational path as the Pearl deploy gate. Acceptable shapes include making `check-deploy-config.sh` validate the nginx site path, or having `deploy-pearl-vps.sh` invoke `check_nginx_catalog_routes_test.sh` before the upload at `phase4-coordinator/dist/deploy-pearl-vps.sh:229`. The gate should fail closed before any remote mutation.

### LOW

- None.

Architecture checks:
- Locked SPEC-015 line 3 remains `**Version:** 0.3.3 ... LOCKED`; `git diff -- specs/SPEC-015-receipts.md specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md beta/DECISION_CRITERIA.md` is empty.
- The nginx route mirrors the v0.2 `/v1/receipt-keys/` buyer-port shape at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:149-176`.
- Entry 80 orthogonality is preserved: `phase4-coordinator/internal/config/config.go:344-349` still defaults `RequireHashVerified` to false, and the YAML example documents `require_hash_verified: false` only as a commented placeholder at `phase4-coordinator/dist/coordinator.yaml.example:98-109`.

VERDICT: FIX REQUIRED
COUNTS: CRITICAL 0 / HIGH 1 / MEDIUM 0 / LOW 0

## Lens — CODE — Round 2

### Findings

- None.

Round-2 closure checks:
- CODE-HIGH is closed. `phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh:31-55` extracts `proxy_pass` directives from inside the active `/catalog/` block only, asserts the buyer-port target `127.0.0.1:8443`, and fails closed on zero or multiple `proxy_pass` directives. This removes the round-1 false pass from the existing `/v1/receipt-keys/` buyer-port block at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:149-155`.
- The ordering assertion now anchors on the TLS catch-all `location / { return 404; }` and fails closed if that anchor is missing at `phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh:57-70`.
- The nginx block itself still matches the Step 3 shape: `/catalog/` is declared at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:170-176`, proxies to `http://127.0.0.1:8443`, forwards host/client headers, sets `proxy_read_timeout 10s`, and appears before the catch-all 404 at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:204-207`.
- `Makefile:33-37` keeps the catalog route check wired into `test-dist`.
- `phase4-coordinator/dist/coordinator.yaml.example:98-109` uses the existing commented-operator-input style for `catalog_path`, `catalog_public_key`, and `require_hash_verified`, while setting Pearl's `public_catalog_base_url`.

Verification evidence:
- `bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh` passed.
- `make test-dist` passed; the optional live nginx smoke skipped under `SPEC015_NGINX_LIVE_OPTIONAL=1`.
- A restore-on-exit mutation that changed only the `/catalog/` block to `proxy_pass http://127.0.0.1:8444;` exited 1 with `FAIL: /catalog/ block proxy_pass is not 127.0.0.1:8443 (buyer port); got:         proxy_pass http://127.0.0.1:8444;`.
- `git diff --check` passed.

VERDICT: READY
COUNTS: CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0

## Lens — SECURITY — Round 2

### Findings

- None.

Security checks:
- `/catalog/` remains public by design per `specs/SPEC-015-receipts.md:3308-3322` and `specs/SPEC-015-receipts.md:3328-3368`; nginx proxies it only to buyer port `127.0.0.1:8443` at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:170-176`.
- No public `/poolz` route was added. The existing `/poolz` surface remains on provider/operator port `127.0.0.1:8444` with authorization forwarding at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:120-129`.
- The `/catalog/` comment states the unauthenticated buyer-endpoint posture, internal rate-limit ownership, public cache posture, signed-catalog trust model, and 404 behavior at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:158-168`.
- `phase4-coordinator/dist/coordinator.yaml.example:98-109` introduces no secret material. `catalog_public_key` stays commented as an operator-populated public key placeholder, and `public_catalog_base_url` is the public Pearl URL.
- The block ordering is unambiguous: `/catalog/` is before the TLS catch-all 404, and the static gate now fails closed if the catch-all anchor cannot be found.

Verification evidence:
- `bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh` passed.
- `make test-dist` passed; the optional live nginx smoke skipped under `SPEC015_NGINX_LIVE_OPTIONAL=1`.
- `git diff --check` passed.

VERDICT: READY
COUNTS: CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0

## Lens — ARCHITECT — Round 2

### Findings

- None.

Architecture checks:
- ARCHITECT-HIGH is closed. `phase4-coordinator/dist/deploy-pearl-vps.sh:87-95` invokes `check_nginx_catalog_routes_test.sh` during step 0, before `step 1/9: confirm SSH + DNS` at `phase4-coordinator/dist/deploy-pearl-vps.sh:97-99` and before any upload/install phase. Failure exits 5 with `aborting deploy: nginx /catalog/ routes missing or misconfigured`.
- The deploy integration satisfies the Step 3 pre-upload gate intent from `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:183-190`: an outdated local `nginx-coordinator.streamvc.live.conf` now blocks the Pearl deploy before remote mutation.
- The new `/catalog/` route composes with the v0.2 `/v1/receipt-keys/` shape: both are public buyer-port routes with the same core proxy/header pattern at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:149-176`.
- Locked files were not shifted: `git diff -- specs/SPEC-015-receipts.md specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md beta/DECISION_CRITERIA.md` is empty.
- Entry 80 orthogonality is preserved. `phase4-coordinator/internal/config/config.go:348` still defaults `RequireHashVerified` to `false`, and `phase4-coordinator/dist/coordinator.yaml.example:98-109` documents `require_hash_verified: false` only as a commented operator placeholder while adding `public_catalog_base_url`.

Verification evidence:
- `bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh` passed.
- `make test-dist` passed; the optional live nginx smoke skipped under `SPEC015_NGINX_LIVE_OPTIONAL=1`.
- A restore-on-exit `/catalog/` mutation to operator port 8444 exited non-zero, proving the pre-upload deploy gate now has a meaningful stale-nginx failure condition.
- `git diff --check` passed.

VERDICT: READY
COUNTS: CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0
