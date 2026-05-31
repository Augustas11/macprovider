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
