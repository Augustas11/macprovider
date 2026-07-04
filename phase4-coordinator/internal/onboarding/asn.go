package onboarding

import (
	"context"
	"fmt"
	"net/netip"
	"sort"
	"strings"
)

type StaticASNResolver struct {
	entries []asnEntry
}

type asnEntry struct {
	prefix netip.Prefix
	asn    string
}

func NewStaticASNResolver(prefixes map[string]string) (*StaticASNResolver, error) {
	out := &StaticASNResolver{entries: make([]asnEntry, 0, len(prefixes))}
	for rawPrefix, rawASN := range prefixes {
		prefix, err := netip.ParsePrefix(strings.TrimSpace(rawPrefix))
		if err != nil {
			return nil, fmt.Errorf("parse ASN prefix %q: %w", rawPrefix, err)
		}
		asn := strings.TrimSpace(rawASN)
		if asn == "" {
			return nil, fmt.Errorf("ASN for prefix %q is empty", rawPrefix)
		}
		out.entries = append(out.entries, asnEntry{prefix: prefix, asn: asn})
	}
	sort.Slice(out.entries, func(i, j int) bool {
		return out.entries[i].prefix.Bits() > out.entries[j].prefix.Bits()
	})
	return out, nil
}

func (r *StaticASNResolver) ResolveASN(ctx context.Context, ip netip.Addr) (string, bool, error) {
	if r == nil {
		return "", false, nil
	}
	for _, entry := range r.entries {
		if entry.prefix.Contains(ip) {
			return entry.asn, true, nil
		}
	}
	return "", false, nil
}
