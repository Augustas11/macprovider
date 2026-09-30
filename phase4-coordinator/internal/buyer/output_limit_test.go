package buyer

import (
	"net/http"
	"testing"
)

func TestEffectiveMaxOutputTokensValidationAndProviderForwarding(t *testing.T) {
	tests := []struct {
		name      string
		values    []string
		want      int
		wantOK    bool
		wantError bool
	}{
		{name: "absent"},
		{name: "zero", values: []string{"0"}, want: 0, wantOK: true},
		{name: "positive", values: []string{"32768"}, want: 32768, wantOK: true},
		{name: "negative", values: []string{"-1"}, wantError: true},
		{name: "not integer", values: []string{"4.5"}, wantError: true},
		{name: "multiple", values: []string{"4096", "32768"}, wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			src := make(http.Header)
			for _, value := range tt.values {
				src.Add(effectiveMaxOutputTokensHeader, value)
			}

			got, ok, err := effectiveMaxOutputTokens(src)
			if (err != nil) != tt.wantError {
				t.Fatalf("error=%v wantError=%v", err, tt.wantError)
			}
			if got != tt.want || ok != tt.wantOK {
				t.Fatalf("limit=(%d,%v) want (%d,%v)", got, ok, tt.want, tt.wantOK)
			}

			dst := make(http.Header)
			setProviderMaxOutputTokensHeader(dst, src)
			if tt.wantOK {
				if value := dst.Get(providerMaxOutputTokensHeader); value != tt.values[0] {
					t.Fatalf("provider header=%q want %q", value, tt.values[0])
				}
			} else if value := dst.Get(providerMaxOutputTokensHeader); value != "" {
				t.Fatalf("provider header=%q want absent", value)
			}
		})
	}
}
