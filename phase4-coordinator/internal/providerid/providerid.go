package providerid

import (
	"fmt"
	"regexp"
)

var pattern = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)

// Validate is the canonical ProviderID grammar. The "/" delimiter is reserved
// by pool.Provider.SortKey (ProviderID + "/" + AssignedID), so provider IDs
// must stay delimiter-free across config, admission, and durable trustpool
// events.
func Validate(s string) error {
	if !pattern.MatchString(s) {
		return fmt.Errorf("invalid provider_id %q", s)
	}
	return nil
}
