CRITICAL (0):
HIGH (0):
MEDIUM (2):
  M1. AST extraction silently ignores valid reason constants without direct literal values
      Evidence: phase7-verify/internal/verify/enum_drift_test.go:79
      Fix:     Return an error for any reasonXxx const that lacks an explicit string literal value, or implement Go const expression carry-forward/alias evaluation instead of continuing silently.
  M2. Duplicate Go reason values collapse before the schema bijection check
      Evidence: phase7-verify/internal/verify/enum_drift_test.go:128
      Fix:     Track value-to-const collisions while building expected and fail when two reasonXxx constants resolve to the same schema reason value.
LOW (1):
  L1. Reserved marker substring match accepts negated prose such as "NOT RESERVED"
      Evidence: phase7-verify/internal/verify/enum_drift_test.go:190
      Fix:     Match explicit marker forms such as FORWARD-COMPAT: or RESERVED: on comment lines instead of arbitrary substrings.
QUESTIONS (0):
