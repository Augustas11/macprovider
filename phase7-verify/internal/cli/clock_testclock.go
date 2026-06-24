//go:build testclock

package cli

import (
	"strconv"
	"time"
)

// envClockOverride is enabled only when the binary is built with
// `-tags=testclock`. Integration tests use this to freeze "now" against
// committed receipt fixtures (which carry a fixed unix_ts) so that
// clock_skew warnings don't fire as the fixtures age past 24h.
func envClockOverride(getenv func(string) string) func() time.Time {
	v := getenv("MACPROVIDER_VERIFY_NOW_UNIX")
	if v == "" {
		return nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return nil
	}
	return func() time.Time { return time.Unix(n, 0).UTC() }
}
