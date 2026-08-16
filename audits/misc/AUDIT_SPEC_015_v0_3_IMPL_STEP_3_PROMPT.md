# IMPL audit prompt — SPEC-015 v0.3 IMPL Step 3 (nginx + Pearl deploy gates)

You are auditing the Step 3 implementation in `phase4-coordinator/dist/`.

Output: APPEND to `specs/SPEC-015-v0-3-IMPL-STEP_3-audit.md`. Run all
THREE lenses (CODE, SECURITY, ARCHITECT). End each with VERDICT + COUNTS.

User policy: 0 CRITICAL + 0 HIGH + 0 MEDIUM target.

## What landed in Step 3

- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf` — new
  `location /catalog/ { proxy_pass 127.0.0.1:8443 ... }` block. Mirrors
  the v0.2 `/v1/receipt-keys/` proxy. Declared BEFORE the catch-all
  `location / { return 404; }`.
- `phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh` —
  static assertion that the `/catalog/` block exists, proxies to the
  buyer port, and precedes the catch-all 404. Wired into
  `Makefile`'s `test-dist` target.
- `phase4-coordinator/dist/coordinator.yaml.example` — new `tier2:`
  block with `public_catalog_base_url` populated for Pearl
  (`https://coordinator.malibu.tech`) and commented placeholders for
  the other §M.4 / SPEC-008 catalog config.

## Severity definitions

- **CRITICAL** — locked-spec edits; nginx config that opens an
  unauthenticated operator-port surface or proxies to the wrong
  internal port; deploy gate that silently exits 0 when the new
  routes are missing; example yaml introducing a secret on disk.
- **HIGH** — AC-39 deploy-time path not verifiable from the static
  check; missing buffer-size / proxy-read-timeout settings on the new
  block; ordering issue that would let nginx route `/catalog/` to the
  catch-all 404; example yaml value that mismatches the locked SPEC
  (`Ed25519` casing, base64url encoding).
- **MEDIUM** — comment drift; missing comment explaining trust posture;
  example yaml that doesn't follow the existing house comment style;
  missing test entry in `Makefile`.
- **LOW** — polish; deferrable.

## Constraints

1. SPEC-015 v0.3.3 LOCKED — no SPEC changes.
2. No locked-spec line-3 shifts.
3. `/poolz` remains operator-only at the nginx level (no public proxy
   added to /poolz).
4. The new `/catalog/` block uses the BUYER port (8443), NOT the
   operator port (8444).
5. The new block MUST be active BEFORE the catch-all 404; otherwise
   nginx routes /catalog/ to the catch-all and the buyer-side
   verifier cannot fetch the catalog.

## Required reading

1. `specs/SPEC-015-receipts.md` §M.4 (catalog endpoints).
2. `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` Step 3.
3. `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf` —
   the new `/catalog/` block and surrounding ordering.
4. `phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh`
   — the new static check.
5. `phase4-coordinator/dist/test/check_nginx_receipt_buffers_test.sh`
   — for comparison (the v0.2 pattern).
6. `Makefile` `test-dist` target.
7. `phase4-coordinator/dist/coordinator.yaml.example` — the new
   `tier2:` block.
8. `beta/DECISION_CRITERIA.md` Entry 80 — `RequireHashVerified`
   default unchanged.

## Categories

CODE  C.1 nginx /catalog/ block — proxy_pass target, headers, timeout.
      C.2 Block ordering — declared before catch-all 404.
      C.3 Comment block — describes purpose, posture, anchor section
          reference.
      C.4 check_nginx_catalog_routes_test.sh — assertion completeness;
          regex robustness against future comment-drift; correct
          handling of the dual `location / {` blocks (port 80
          redirect vs TLS catch-all 404).
      C.5 Makefile wiring — new check in `test-dist`.
      C.6 coordinator.yaml.example — tier2 section, comment style.

SECURITY  S.1 No new auth-bypass surface — `/catalog/` is public per
              §M.4 + v0.2 §10.7 precedent.
          S.2 No private key surface — `/catalog/pubkey` returns only
              the public key; example yaml leaves
              `catalog_public_key` commented (operator fills in).
          S.3 Block ordering — verify routing is unambiguous.

ARCHITECT  A.1 Build-prompt Step 3 coverage.
           A.2 No locked-spec shifts.
           A.3 Composes with v0.2 nginx (`/v1/receipt-keys/`) shape.
           A.4 Entry 80 orthogonality — yaml example does NOT flip
               `require_hash_verified` to true.

Each finding cites file:line. End each lens with VERDICT + COUNTS.
