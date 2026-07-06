# Code Audit Prompt — Control Plane and Deploy Hardening R1

Audit the implementation on branch `fix/deepsec-control-plane-and-deploy` from the code-correctness lens.

Scope:
- `phase5-gateway/internal/router/admin.go`
- `phase5-gateway/internal/router/admin_metrics.go`
- `phase5-gateway/internal/router/admin_test.go` / relevant admin coverage in `server_test.go` and `integration_test.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/internal/storage/sqlite/store_test.go`
- `phase5-gateway/internal/storage/interfaces.go`
- `phase5-gateway/internal/storage/types.go`
- `phase5-gateway/dist/deploy-pearl-vps.sh`
- `phase5-gateway/dist/test/gateway_deploy_*.test.sh`
- `phase4-coordinator/dist/deploy-pearl-vps.sh`
- `phase4-coordinator/dist/test/coord_deploy_*.test.sh`
- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/internal/config/config_test.go`
- `phase4-coordinator/internal/config/config_env_test.go`
- coordinator test fixture updates under `phase4-coordinator/cmd/coordinator/`

Check:
- Failed admin state writes cannot return 200.
- Kill-switch compare-and-swap handles version mismatch and commit errors correctly.
- Capacity transitions do not ignore tier or pause persistence failures.
- Gateway deploy snapshot and rollback use the installed config's `storage.db_path`.
- Gateway deploy production C2 check validates the installed Pearl config copy and logs its SHA-256.
- Coordinator deploy static-feed smoke does not write predictable `/tmp` files.
- Coordinator drift diff output redacts Postgres DSN passwords at the diff-print boundary.
- Coordinator config load rejects weak operator keys with specific errors and preserves strong-key fixtures.

Return findings ordered by severity with concrete file/line references. Use `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, or `INFO`. State `0 C/H/M` explicitly if no blockers are found.
