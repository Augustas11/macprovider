package ws

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

// TestReferralCloseReasonPreservesToken is the FIX-570 A10 / contract C-1
// regression: the WS credential-bootstrap close frame must carry the specific
// referral_<token> reason, not collapse every non-missing failure to
// referral_invalid.
func TestReferralCloseReasonPreservesToken(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{auth.ErrReferralInvalid, "referral_invalid"},
		{auth.ErrReferralExpired, "referral_expired"},
		{auth.ErrReferralRevoked, "referral_revoked"},
		{auth.ErrReferralExhausted, "referral_exhausted"},
		{auth.ErrReferralConflict, "referral_invalid"},
	}
	for _, c := range cases {
		if got := referralCloseReason(c.err); got != c.want {
			t.Errorf("referralCloseReason(%v) = %q, want %q", c.err, got, c.want)
		}
	}
}
