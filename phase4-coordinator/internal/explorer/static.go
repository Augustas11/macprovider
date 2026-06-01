package explorer

import (
	"embed"
	"net/http"
	"strings"
)

//go:embed static
var staticFS embed.FS

func (h *Handler) serveStatic(w http.ResponseWriter, r *http.Request, path string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeExplorerError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	target := "static/index.html"
	if path != "/" {
		target = "static/" + strings.TrimPrefix(path, "/")
	}
	if strings.HasSuffix(target, ".css") {
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
	} else if strings.HasSuffix(target, ".js") {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	} else {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
	}
	data, err := staticFS.ReadFile(target)
	if err != nil {
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
