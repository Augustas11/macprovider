//go:build !testclock

package cli

import "time"

// envClockOverride returns nil in production builds. The test-only
// `testclock` build tag swaps in an implementation that honors
// MACPROVIDER_VERIFY_NOW_UNIX, used by integration tests to pin the
// verifier's "now" against frozen receipt fixtures. Keeping this off
// production builds prevents an attacker who can set env vars from
// silencing clock_skew or expanding the grace-window check.
func envClockOverride(getenv func(string) string) func() time.Time {
	_ = getenv
	return nil
}
