package router

import "net/http"

const corsMaxAge = "3600"

var corsAllowedHeaders = "Accept, Anthropic-Beta, Anthropic-Version, Authorization, Content-Type, X-Api-Key, X-Demo-Token, X-Request-ID"

func (s *Server) withCORS(method string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowed := s.corsOriginAllowed(origin)
		if r.Method == http.MethodOptions {
			if !allowed || r.Header.Get("Access-Control-Request-Method") != method {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			setCORSHeaders(w.Header(), origin)
			w.Header().Set("Access-Control-Allow-Methods", method)
			w.Header().Set("Access-Control-Allow-Headers", corsAllowedHeaders)
			w.Header().Set("Access-Control-Max-Age", corsMaxAge)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if allowed {
			setCORSHeaders(w.Header(), origin)
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) corsOriginAllowed(origin string) bool {
	if origin == "" {
		return false
	}
	for _, allowed := range s.cfg.CORS.AllowedOrigins {
		if origin == allowed {
			return true
		}
	}
	return false
}

func setCORSHeaders(h http.Header, origin string) {
	h.Set("Access-Control-Allow-Origin", origin)
	h.Set("Access-Control-Allow-Credentials", "false")
	h.Set("Access-Control-Expose-Headers", "X-Request-ID")
	h.Add("Vary", "Origin")
}
