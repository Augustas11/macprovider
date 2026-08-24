package router

import (
	"html"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestAccountTemplateDisplaysKeyAndSnippets(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	fullKey := "mp_test_key_once"
	req := httptest.NewRequest(http.MethodGet, "/account", nil)
	req.AddCookie(&http.Cookie{Name: "mp_new_api_key", Value: fullKey, Path: "/account"})
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	for _, want := range []string{
		`<code class="key" id="api-key">` + fullKey + `</code>`,
		`type="checkbox" id="saved" required`,
		`id="tab-curl"`,
		`id="tab-python"`,
		`id="tab-node"`,
		`curl https://api.malibu.tech/v1/chat/completions`,
		`OpenAI(`,
		`new OpenAI`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("account body missing %q", want)
		}
	}
	disclosureIndex := strings.Index(body, `<details class="disclosure-panel" open>`)
	keyIndex := strings.Index(body, `<code class="key" id="api-key">`+fullKey+`</code>`)
	if disclosureIndex < 0 {
		t.Fatalf("account disclosure is not visibly open before key")
	}
	if keyIndex < 0 || disclosureIndex > keyIndex {
		t.Fatalf("account disclosure must render before one-shot key")
	}
	if findCookie(resp, "mp_new_api_key") != "" {
		t.Fatalf("one-shot cookie was not unset")
	}
}

func TestAccountTemplateWithoutCookieDoesNotLeakKey(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	resp := assertStatus(t, h, http.MethodGet, "/account", "", "", "", http.StatusOK)
	body := resp.Body.String()
	if !strings.Contains(body, "No new API key to display") {
		t.Fatalf("state B body missing copy: %s", body)
	}
	if strings.Contains(body, "mp_") || strings.Contains(body, "mp_test_key_once") {
		t.Fatalf("state B leaked key-looking text: %s", body)
	}
}

func TestDocsRouteRendersMarkdown(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	resp := assertStatus(t, h, http.MethodGet, "/docs", "", "", "", http.StatusOK)
	body := resp.Body.String()
	for _, want := range []string{
		`<h1 id="getting-started">Getting started</h1>`,
		`id="api-reference"`,
		`id="disclosures"`,
		`id="quotas-and-limits"`,
		`/v1/feedback`,
		`Chat completions`,
		`deployment-configured`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("docs body missing %q", want)
		}
	}
	if strings.Contains(body, "120s") {
		t.Fatalf("docs body hard-codes stale timeout: %s", body)
	}
}

func TestTier1DisclosureMatchesSpecSection16(t *testing.T) {
	specPath := filepath.Join("..", "..", "..", "specs", "SPEC-006-buyer-api.md")
	raw, err := os.ReadFile(specPath)
	if err != nil {
		t.Fatalf("read spec: %v", err)
	}
	spec := normalizeDisclosureText(string(raw))
	for _, item := range tier1DisclosureText {
		if !strings.Contains(spec, normalizeDisclosureText(item.Text)) {
			t.Fatalf("%s disclosure drifted from SPEC-006 section 1.6", item.Key)
		}
	}

	rendered := renderAccountForDisclosureTest(t)
	for _, item := range tier1DisclosureText {
		if !strings.Contains(normalizeDisclosureText(rendered), normalizeDisclosureText(item.Text)) {
			t.Fatalf("%s disclosure missing from rendered account page", item.Key)
		}
	}

	docsRaw, err := pageFS.ReadFile("templates/docs.md")
	if err != nil {
		t.Fatalf("read docs markdown: %v", err)
	}
	consoleRaw, err := os.ReadFile(filepath.Join("..", "..", "..", "frontdoor", "console", "index.html"))
	if err != nil {
		t.Fatalf("read console html: %v", err)
	}
	for _, surface := range []struct {
		name string
		text string
	}{
		{name: "docs", text: string(docsRaw)},
		{name: "console", text: string(consoleRaw)},
	} {
		normalized := normalizeDisclosureText(surface.text)
		for _, item := range tier1DisclosureText {
			if !strings.Contains(normalized, normalizeDisclosureText(item.Text)) {
				t.Fatalf("%s disclosure missing from %s surface", item.Key, surface.name)
			}
		}
		for _, want := range []string{
			"before response bytes are committed",
			"provider_disconnected",
			"new request",
			"separate billable request",
			"cross-request overlapping output is not deduplicated",
			"must not double-charge overlapping output",
		} {
			if !strings.Contains(normalized, want) {
				t.Fatalf("%s surface missing streaming failover disclosure %q", surface.name, want)
			}
		}
		if strings.Contains(normalized, "Transparent streaming failover bills") {
			t.Fatalf("%s surface contains stale transparent streaming failover claim", surface.name)
		}
	}
}

func TestProviderPartnerDocsIncludeLateReceiptDeadlineDisclosure(t *testing.T) {
	for _, path := range []string{
		filepath.Join("..", "..", "..", "phase3-binary", "README.md"),
		filepath.Join("..", "..", "..", "phase3-binary", "dist", "README-partner.md"),
		filepath.Join("..", "..", "..", "docs", "legacy", "phase1", "provider-economics.md"),
	} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read provider docs %s: %v", path, err)
		}
		text := string(raw)
		for _, want := range []string{
			"pending_deadline_seconds",
			"non-settling",
			"non-recoverable",
			"future operator-review exception spec",
		} {
			if !strings.Contains(text, want) {
				t.Fatalf("provider docs %s missing %q", path, want)
			}
		}
	}
}

func TestConsoleStaticContracts(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "frontdoor", "console", "index.html"))
	if err != nil {
		t.Fatalf("read console html: %v", err)
	}
	html := string(raw)
	for _, want := range []string{
		`docs#api-reference`,
		`r.headers.get("X-Request-ID")`,
		`minting=null;throw e`,
		`.compliance-copy{`,
	} {
		if !strings.Contains(html, want) {
			t.Fatalf("console missing %q", want)
		}
	}
	if strings.Contains(html, ".compliance-copy{position:absolute") || strings.Contains(html, "left:-10000px") {
		t.Fatal("console compliance disclosure must be visible, not positioned off-screen")
	}
	chatIndex := strings.Index(html, `<div class="chat-messages" id="chatMessages">`)
	disclosureIndex := strings.Index(html, `<section class="compliance-copy" aria-label="Tier 1 disclosure">`)
	inputIndex := strings.Index(html, `<div class="input-dock">`)
	mainCloseIndex := strings.Index(html, `</main>`)
	if chatIndex < 0 || disclosureIndex < 0 || inputIndex < 0 || mainCloseIndex < 0 {
		t.Fatal("console disclosure placement anchors missing")
	}
	if disclosureIndex < chatIndex || disclosureIndex > inputIndex || disclosureIndex > mainCloseIndex {
		t.Fatal("console disclosure must render inside the main chat scroll area before the input dock")
	}
	if strings.Contains(html, "innerHTML") {
		t.Fatal("console must build status/dashboard DOM with textContent, not innerHTML")
	}
}

func renderAccountForDisclosureTest(t *testing.T) string {
	t.Helper()
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	req := httptest.NewRequest(http.MethodGet, "/account", nil)
	req.AddCookie(&http.Cookie{Name: "mp_new_api_key", Value: "mp_test_key_once", Path: "/account"})
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("account status=%d body=%s", resp.Code, resp.Body.String())
	}
	re := regexp.MustCompile(`<[^>]+>`)
	text := re.ReplaceAllString(resp.Body.String(), "")
	return html.UnescapeString(text)
}

func normalizeDisclosureText(text string) string {
	text = strings.ReplaceAll(text, "`", "")
	text = strings.ReplaceAll(text, "**", "")
	return strings.Join(strings.Fields(text), " ")
}
