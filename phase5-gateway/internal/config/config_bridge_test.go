package config

import "testing"

// TestUpstreamCoordinatorBearerPrefersServiceToken locks in the M3-2
// bridge: when both ServiceToken and OperatorKey are set, the gateway
// MUST send ServiceToken on upstream calls. The audit-log line on the
// coordinator side then reports key=service_token, which is the signal
// the operator watches to know the cutover landed.
func TestUpstreamCoordinatorBearerPrefersServiceToken(t *testing.T) {
	c := CoordinatorConfig{OperatorKey: "operator", ServiceToken: "service"}
	if got := c.UpstreamCoordinatorBearer(); got != "service" {
		t.Fatalf("UpstreamCoordinatorBearer=%q want %q", got, "service")
	}
}

// TestUpstreamCoordinatorBearerFallsBackToOperatorKey verifies the
// pre-cutover state: a not-yet-configured ServiceToken falls back to
// OperatorKey so existing deployments keep working unchanged.
func TestUpstreamCoordinatorBearerFallsBackToOperatorKey(t *testing.T) {
	c := CoordinatorConfig{OperatorKey: "operator", ServiceToken: ""}
	if got := c.UpstreamCoordinatorBearer(); got != "operator" {
		t.Fatalf("UpstreamCoordinatorBearer=%q want %q", got, "operator")
	}
}
