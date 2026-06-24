package spec014pairing

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestSpec014V02FullPairingHandoff(t *testing.T) {
	coord := startCoordinator(t, true, nil)
	db := openDB(t, coord.dbPath)
	providerID := "spec014-provider-" + randHex(t, 4)
	conn, ack := dialProvider(t, coord.providerURL, providerID)
	defer conn.Close()

	assignedToken, _ := ack["assigned_provider_token"].(string)
	pairOT, _ := ack["pair_ot"].(string)
	claimURL, _ := ack["claim_url"].(string)
	if assignedToken == "" || pairOT == "" || claimURL == "" {
		t.Fatalf("hello_ack missing pairing fields: %#v", ack)
	}
	if !strings.Contains(claimURL, "/claim?ot="+pairOT) {
		t.Fatalf("claim_url %q does not carry pair_ot %q", claimURL, pairOT)
	}

	binaryHome := t.TempDir()
	binaryTranscript := writeClaimURLBeforeOpen(t, binaryHome, pairOT, claimURL)

	startClient := &http.Client{
		Timeout: 5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	startURL := coord.providerURL + "/v1/auth/github/start?return_to=%2Fclaim&pair_ot=" + pairOT
	resp, err := startClient.Get(startURL)
	if err != nil {
		t.Fatalf("github start: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("github start status=%d want 302", resp.StatusCode)
	}
	var pending string
	if err := db.QueryRow(`SELECT pending_pair_ot FROM oauth_states WHERE pending_pair_ot = ?`, pairOT).Scan(&pending); err != nil {
		t.Fatalf("oauth_states.pending_pair_ot not persisted: %v", err)
	}

	sessionID := seedSession(t, db, pairOT)
	status, body := postBind(t, authClient(t, sessionID), coord.providerURL, `{}`)
	if status != http.StatusOK {
		t.Fatalf("pending pair bind status=%d body=%s", status, string(body))
	}
	var bindResp map[string]any
	if err := json.Unmarshal(body, &bindResp); err != nil {
		t.Fatalf("decode bind response: %v body=%s", err, string(body))
	}
	if bindResp["provider_id"] != providerID || bindResp["github_login"] != "octo" {
		t.Fatalf("bind response=%#v, want provider_id=%s login=octo", bindResp, providerID)
	}

	event := readOwnershipEvent(t, conn, providerID)
	if event["github_login"] != "octo" {
		t.Fatalf("ownership_event=%#v, want github_login=octo", event)
	}
	completeBinaryClaim(t, binaryHome, providerID, event)

	status, body = getProviders(t, authClient(t, sessionID), coord.providerURL)
	if status != http.StatusOK {
		t.Fatalf("providers status=%d body=%s", status, string(body))
	}
	if !strings.Contains(string(body), providerID) {
		t.Fatalf("providers body %s does not include %s", string(body), providerID)
	}

	assertBurnFirstAgainstLiveCoordinator(t, coord.providerURL, db)
	assertPairOTNotLeaked(t, pairOT, coord.logs.String(), binaryTranscript)
}

func writeClaimURLBeforeOpen(t *testing.T, home, pairOT, claimURL string) string {
	t.Helper()
	configDir := filepath.Join(home, ".config", "macprovider")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	claimPath := filepath.Join(configDir, "claim_url")
	body := "pair_ot=" + pairOT + "\nclaim_url=" + claimURL + "\n"
	if err := os.WriteFile(claimPath, []byte(body), 0o600); err != nil {
		t.Fatalf("write claim_url: %v", err)
	}
	info, err := os.Stat(claimPath)
	if err != nil {
		t.Fatalf("stat claim_url: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("claim_url mode=%#o want 0600", info.Mode().Perm())
	}
	openMarker := filepath.Join(configDir, "open.attempted")
	if _, err := os.Stat(openMarker); !os.IsNotExist(err) {
		t.Fatalf("open marker exists before claim_url write barrier")
	}
	if err := os.WriteFile(openMarker, []byte(time.Now().UTC().Format(time.RFC3339Nano)), 0o600); err != nil {
		t.Fatalf("write open marker: %v", err)
	}
	return "claim_url=" + claimURL + "\n"
}

func completeBinaryClaim(t *testing.T, home, providerID string, event map[string]any) {
	t.Helper()
	configDir := filepath.Join(home, ".config", "macprovider")
	if event["event"] != "bound" {
		t.Fatalf("unexpected ownership event: %#v", event)
	}
	if err := os.Remove(filepath.Join(configDir, "claim_url")); err != nil {
		t.Fatalf("delete claim_url: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "owner.txt"), []byte("provider_id="+providerID+"\ngithub_login=octo\n"), 0o600); err != nil {
		t.Fatalf("write owner.txt: %v", err)
	}
	if _, err := os.Stat(filepath.Join(configDir, "claim_url")); !os.IsNotExist(err) {
		t.Fatalf("claim_url still exists after ownership event")
	}
	owner, err := os.ReadFile(filepath.Join(configDir, "owner.txt"))
	if err != nil {
		t.Fatalf("read owner.txt: %v", err)
	}
	if !strings.Contains(string(owner), providerID) {
		t.Fatalf("owner.txt=%q missing provider_id %s", string(owner), providerID)
	}
}

func getProviders(t *testing.T, c *http.Client, baseURL string) (int, []byte) {
	t.Helper()
	resp, err := c.Get(baseURL + "/v1/auth/me/providers")
	if err != nil {
		t.Fatalf("get providers: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

func assertBurnFirstAgainstLiveCoordinator(t *testing.T, baseURL string, db *sql.DB) {
	t.Helper()
	pairOT := seedPairOT(t, db, "burn-first-"+randHex(t, 4))
	sessionA := seedSession(t, db, "")
	sessionB := seedSession(t, db, "")
	body := fmt.Sprintf(`{"pair_ot":%q}`, pairOT)
	statuses := make(chan int, 2)
	var wg sync.WaitGroup
	for _, sessionID := range []string{sessionA, sessionB} {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			status, _ := postBind(t, authClient(t, id), baseURL, body)
			statuses <- status
		}(sessionID)
	}
	wg.Wait()
	close(statuses)
	seen := map[int]int{}
	for status := range statuses {
		seen[status]++
	}
	if seen[http.StatusOK] != 1 || seen[http.StatusGone] != 1 {
		t.Fatalf("burn-first concurrent bind statuses=%v, want one 200 and one 410", seen)
	}
}

func assertPairOTNotLeaked(t *testing.T, pairOT, coordinatorLogs, binaryTranscript string) {
	t.Helper()
	if strings.Contains(coordinatorLogs, pairOT) {
		t.Fatalf("pair_ot leaked in coordinator logs")
	}
	allowed := "claim_url=https://portal.example/claim?ot=" + pairOT + "\n"
	if strings.ReplaceAll(binaryTranscript, allowed, "") != "" {
		t.Fatalf("binary transcript contains pair_ot outside claim_url line: %q", binaryTranscript)
	}
}
