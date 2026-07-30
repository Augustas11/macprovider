CRITICAL (0):

HIGH (0):

MEDIUM (0):

LOW (1):
  L1. Stderr renders the new TLS warning only by kind, without the `ca_file_path` context.
      Evidence: `nonDefaultTLSTrustWarning` emits `kind=non_default_tls_trust` with `ca_file_path` when the env var is readable and `AppendCertsFromPEM` succeeds (`phase7-verify/internal/resolver/resolver.go:440`, `phase7-verify/internal/resolver/resolver.go:453`, `phase7-verify/internal/resolver/resolver.go:457`); JSON flattens warning fields with `json.Marshal`, so `ca_file_path` is present and control characters are escaped there (`phase7-verify/internal/cli/output.go:116`, `phase7-verify/internal/cli/output.go:132`); stderr has no specific case for `non_default_tls_trust` and falls through to `warning: <kind>` (`phase7-verify/internal/cli/output.go:186`, `phase7-verify/internal/cli/output.go:204`).
      Fix:     Add a dedicated `non_default_tls_trust` stderr renderer that prints a sanitized/quoted `ca_file_path` value, with a test covering control characters.

QUESTIONS (0):

VERDICT: security lane READY TO MERGE — #128 silent-trust gap closed
