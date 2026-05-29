package router

import "net/http"

func setNoStoreHeaders(h http.Header) {
	h.Set("Cache-Control", "no-store")
	h.Set("Pragma", "no-cache")
	h.Set("Expires", "0")
}

func setBrowserSecurityHeaders(h http.Header) {
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Permissions-Policy", "geolocation=(), microphone=(), camera=(), payment=()")
	h.Set("Content-Security-Policy", "default-src 'none'; base-uri 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; form-action 'self'")
}
