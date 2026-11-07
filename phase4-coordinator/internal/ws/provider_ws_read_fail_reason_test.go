package ws

import (
	"fmt"
	"io"
	"net"
	"testing"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

func TestProviderWSReadFailReasonReportsPeerCloseCode(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want string
	}{
		{"nil", nil, "read_failed"},
		{"going_away", wsutil.ClosedError{Code: gobwas.StatusGoingAway}, "peer_close_1001"},
		{"wrapped_normal", fmt.Errorf("read: %w", wsutil.ClosedError{Code: gobwas.StatusNormalClosure, Reason: "bye"}), "peer_close_1000"},
		{"no_status", wsutil.ClosedError{Code: gobwas.StatusNoStatusRcvd}, "peer_close_1005"},
		{"net_closed", net.ErrClosed, "connection_closed"},
		{"eof", io.EOF, "eof"},
		{"other", fmt.Errorf("frame too large"), "read_failed"},
	}
	for _, tc := range cases {
		if got := providerWSReadFailReason(tc.err); got != tc.want {
			t.Errorf("%s: providerWSReadFailReason = %q, want %q", tc.name, got, tc.want)
		}
	}
}
