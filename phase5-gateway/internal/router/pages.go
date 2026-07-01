package router

import (
	"bytes"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"html/template"
	"net/http"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/parser"
)

//go:embed templates/account.html templates/docs.md
var pageFS embed.FS

var accountTemplate = template.Must(template.ParseFS(pageFS, "templates/account.html"))

var docsMarkdown = goldmark.New(goldmark.WithParserOptions(parser.WithAutoHeadingID()))

type disclosureItem struct {
	Key  string
	Text string
}

var tier1DisclosureText = []disclosureItem{
	{
		Key:  "plaintext_to_provider",
		Text: "Buyer prompts and provider responses are processed as plaintext on provider hardware. Providers can technically observe prompts and outputs that route through their machine. This is acceptable for cooperative deployments where buyer and provider have an established trust relationship; it is NOT a private-inference guarantee.",
	},
	{
		Key:  "hardware_attestation",
		Text: "There is no hardware attestation or runtime integrity check on providers. The coordinator admits providers based on `provider_id` match (pinned tier) or rate-limited provisional admission. Once admitted, the provider runtime is trusted to faithfully serve requests; SPEC-006 v0.8 does NOT cryptographically verify this.",
	},
	{
		Key:  "model_identity",
		Text: "Model identity is provider-reported. When `/v1/models` aggregates the pool's served models, the model identifier reflects what the provider's binary advertises. SPEC-006 v0.8 does NOT cryptographically verify the loaded model against a catalog of known artifact hashes.",
	},
	{
		Key:  "model_verification_limit",
		Text: modelVerificationLimitDisclosure,
	},
	{
		Key:  "tier2_milestone",
		Text: "The product makes NO privacy, attestation, integrity, untrusted-provider, or malicious-provider claims. Any buyer-facing language, including front-door copy, docs, error messages, API responses, marketing material, and this spec, MUST be consistent with properties 1-4.",
	},
}

type accountPageData struct {
	APIKey      string
	HasAPIKey   bool
	Disclosures []disclosureItem
	ScriptNonce string
}

func (s *Server) handleAccount(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	apiKey := ""
	if cookie, err := r.Cookie("mp_new_api_key"); err == nil {
		apiKey = cookie.Value
		http.SetCookie(w, &http.Cookie{Name: "mp_new_api_key", Value: "", Path: "/account", HttpOnly: true, Secure: s.secureCookies(), SameSite: http.SameSiteLaxMode, MaxAge: -1})
	}
	scriptNonce, err := newScriptNonce()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "nonce_unavailable", "Account page unavailable")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	setNoStoreHeaders(w.Header())
	setBrowserSecurityHeaders(w.Header(), scriptNonce)
	w.WriteHeader(http.StatusOK)
	_ = accountTemplate.Execute(w, accountPageData{
		APIKey:      apiKey,
		HasAPIKey:   apiKey != "",
		Disclosures: tier1DisclosureText,
		ScriptNonce: scriptNonce,
	})
}

func (s *Server) handleDocs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	source, err := pageFS.ReadFile("templates/docs.md")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "docs_missing", "Documentation unavailable")
		return
	}
	var body bytes.Buffer
	if err := docsMarkdown.Convert(source, &body); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "docs_render_failed", "Documentation unavailable")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=300")
	setBrowserSecurityHeaders(w.Header(), "")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Mac Provider docs</title><style>body{margin:0;background:#0d1117;color:#c9d1d9;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}main{max-width:920px;margin:0 auto;padding:40px 20px 64px}a{color:#58a6ff}pre{overflow:auto;background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px}code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}h1,h2{color:#f0f6fc;line-height:1.2}h1{font-size:34px}h2{margin-top:36px;border-top:1px solid #30363d;padding-top:24px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #30363d;padding:8px;text-align:left}.note{border-left:3px solid #58a6ff;padding:8px 14px;background:#161b22}</style></head><body><main>`))
	_, _ = body.WriteTo(w)
	_, _ = w.Write([]byte(`</main></body></html>`))
}

func newScriptNonce() (string, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(nonce[:]), nil
}
