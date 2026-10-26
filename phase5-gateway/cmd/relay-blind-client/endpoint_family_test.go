package main

import (
	"github.com/augstar/macprovider-gateway/internal/relayblind"
	"testing"
)

func TestValidateOriginalEndpointFamilyRequests(t *testing.T) {
	for _, tc := range []struct{ family, body, path string }{
		{relayblind.EndpointResponses, `{"model":"model-a","input":"hello","max_output_tokens":8}`, "/v1/responses"},
		{relayblind.EndpointMessages, `{"model":"model-a","messages":[{"role":"user","content":"hello"}],"max_tokens":8}`, "/v1/messages"},
	} {
		t.Run(tc.family, func(t *testing.T) {
			opts := options{endpointFamily: tc.family, model: "model-a", maxOutputTokens: 8}
			if err := validateInnerRequest([]byte(tc.body), opts); err != nil {
				t.Fatal(err)
			}
			if got := relayBlindInferencePath(tc.family); got != tc.path {
				t.Fatalf("route=%s", got)
			}
			opts.maxOutputTokens = 9
			if err := validateInnerRequest([]byte(tc.body), opts); err == nil {
				t.Fatal("output cap mismatch accepted")
			}
		})
	}
}
