# Security Audit Prompt — Control Plane and Deploy Hardening R1

Audit the implementation on branch `fix/deepsec-control-plane-and-deploy` from the security lens. Security lane bar: report LOW findings too; expected merge state is `0 C/H/M/L`.

Scope:
- `phase5-gateway/internal/router/admin.go`
- `phase5-gateway/internal/router/admin_metrics.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/dist/deploy-pearl-vps.sh`
- `phase5-gateway/dist/test/gateway_deploy_*.test.sh`
- `phase4-coordinator/dist/deploy-pearl-vps.sh`
- `phase4-coordinator/dist/test/coord_deploy_*.test.sh`
- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/internal/config/config_test.go`

Security invariants:
- Admin state mutations that fail cannot return success; failed write responses are not HTTP 200.
- Concurrent kill-switch updates cannot silently overwrite each other; stale versions return conflict with current version.
- Deploy snapshot and rollback operate on the DB path configured in the installed VPS gateway config, not a local assumption.
- Production C2 precheck validates the gateway config installed on the VPS, not a local sample or developer config.
- Deploy logs do not expose plaintext Postgres DSN passwords.
- Deploy temp files for static-feed smoke are unpredictable, mode-restricted, and cleaned up on exit.
- Coordinator boot refuses placeholder, short, repeated-zero, and low-entropy operator keys with specific errors.

Return findings ordered by severity with concrete file/line references. Include exploitability and remediation. State `0 C/H/M/L` explicitly if clean.
