package providerhttp

import (
	"net/http"
	"time"
)

var Client = &http.Client{
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

// Init sets the HTTP client timeout. Call once at startup before serving requests.
func Init(timeoutS int) {
	Client = &http.Client{
		Timeout: time.Duration(timeoutS) * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// OriginHeader marks every coordinator HTTP-direct dispatch to a provider
// (buyer traffic, canary probes, warmup gates). A provider treats a request
// carrying it as network traffic, never as local chat, whether or not the
// request also carries settlement metadata (SPEC-001-R011).
const (
	OriginHeader           = "X-MacProvider-Origin"
	OriginCoordinatorValue = "coordinator"
)

// SetCoordinatorOrigin stamps the coordinator origin marker on h.
func SetCoordinatorOrigin(h http.Header) {
	h.Set(OriginHeader, OriginCoordinatorValue)
}
