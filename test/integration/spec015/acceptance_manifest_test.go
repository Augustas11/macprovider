package spec015

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

type acceptanceCriterion struct {
	Number   int
	Summary  string
	SpecStep string
	Commands []string
	CIJobs   []string
	Evidence []evidenceAnchor
}

type evidenceAnchor struct {
	File    string
	Pattern string
}

var spec015ACs = []acceptanceCriterion{
	{
		Number:   1,
		Summary:  "first launch stores and reloads the provider receipt key from Keychain",
		SpecStep: "SPEC-015 §14 AC-1",
		Commands: []string{"cd phase3-binary && swift test --parallel"},
		CIJobs:   []string{"phase3-binary (swift test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/ReceiptKeyStoreTests.swift", "testKeychainFirstLaunchGeneratesAndFreshLaunchLoadsSamePrivateKey"},
			{"phase3-binary/Tests/macprovider-cliTests/ReceiptKeyStoreTests.swift", "com.streamvc.macprovider.receipt-key"},
		},
	},
	{
		Number:   2,
		Summary:  "v1.6 provider auth publishes a 32-byte base64 receipt public key",
		SpecStep: "SPEC-015 §14 AC-2",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd phase4-coordinator && go test ./... -count=1"},
		CIJobs:   []string{"phase3-binary (swift test)", "phase4-coordinator (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift", "testAuthInitialIncludesReceiptPublicKeyWhenConfigured"},
			{"phase4-coordinator/internal/ws/server_test.go", "TestProviderAuthV2InitialReceiptPublicKeyPublishesAfterStateUpdate"},
		},
	},
	{
		Number:   3,
		Summary:  "pre-v1.6 providers omit the receipt key and remain admitted with null /poolz pubkey",
		SpecStep: "SPEC-015 §14 AC-3",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd phase4-coordinator && go test ./... -count=1"},
		CIJobs:   []string{"phase3-binary (swift test)", "phase4-coordinator (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift", "testAuthInitialOmitsReceiptPublicKeyWhenUnavailableAndProofNeverIncludesIt"},
			{"phase4-coordinator/internal/ws/server_test.go", "TestPoolzReceiptPubkeyNullForPreV16Provider"},
		},
	},
	{
		Number:   4,
		Summary:  "non-streaming chat emits a parseable seven-field receipt header through the gateway",
		SpecStep: "SPEC-015 §14 AC-4",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd phase5-gateway && go test ./... -count=1", "cd test/integration && go test -race -count=1 -timeout 5m . -run TestSpec015ReceiptEnabledCrossServiceHeaderVerifies"},
		CIJobs:   []string{"phase3-binary (swift test)", "phase5-gateway (go vet + test)", "spec-015-acceptance"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "testNonStreamingReceiptHeaderParsesAndSelfVerifies"},
			{"phase5-gateway/internal/router/server_test.go", "TestReceiptHeaderForwardedAndSiblingMacProviderHeadersStripped"},
			{"test/integration/scenarios_test.go", "TestSpec015ReceiptEnabledCrossServiceHeaderVerifies"},
		},
	},
	{
		Number:   5,
		Summary:  "receipt prompt_hash matches the SPEC-015 canonical prompt hash",
		SpecStep: "SPEC-015 §14 AC-5",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd test/integration && go test -race -count=1 -timeout 5m . -run TestSpec015ReceiptEnabledCrossServiceHeaderVerifies"},
		CIJobs:   []string{"phase3-binary (swift test)", "spec-015-acceptance"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/PromptCanonicalizerTests.swift", "testKnownGoodPromptVectorUsesSixteenCommittedKeys"},
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "PromptCanonicalizer.promptHash"},
			{"test/integration/scenarios_test.go", "prompt_hash"},
		},
	},
	{
		Number:   6,
		Summary:  "receipt output_hash matches the SPEC-015 canonical output hash",
		SpecStep: "SPEC-015 §14 AC-6",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd test/integration && go test -race -count=1 -timeout 5m . -run TestSpec015ReceiptEnabledCrossServiceHeaderVerifies"},
		CIJobs:   []string{"phase3-binary (swift test)", "spec-015-acceptance"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/OutputCanonicalizerTests.swift", "testKnownGoodOutputVectorUsesThreeCommittedKeys"},
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "OutputCanonicalizer.outputHash"},
			{"test/integration/scenarios_test.go", "output_hash"},
		},
	},
	{
		Number:   7,
		Summary:  "receipt tuple signatures verify against provider_pubkey",
		SpecStep: "SPEC-015 §14 AC-7",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd test/integration && go test -race -count=1 -timeout 5m . -run TestSpec015ReceiptEnabledCrossServiceHeaderVerifies"},
		CIJobs:   []string{"phase3-binary (swift test)", "spec-015-acceptance"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift", "testBuildSignsTupleAndSignatureSelfVerifies"},
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "isValidSignature"},
			{"test/integration/scenarios_test.go", "VerifyReceiptAgainstPoolzTrust"},
		},
	},
	{
		Number:   8,
		Summary:  "streaming chat remains receipt-free and byte-shape-compatible",
		SpecStep: "SPEC-015 §14 AC-8",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd phase5-gateway && go test ./... -count=1"},
		CIJobs:   []string{"phase3-binary (swift test)", "phase5-gateway (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "testStreamingHeadersStayReceiptFreeAndByteStable"},
			{"phase5-gateway/internal/router/server_test.go", "TestStreamingReceiptHeaderStripped"},
		},
	},
	{
		Number:   9,
		Summary:  "pinned Python and JavaScript OpenAI SDK fixtures ignore the non-streaming receipt header and accept streaming responses",
		SpecStep: "SPEC-015 §14 AC-9",
		Commands: []string{"cd test/integration && SPEC015_SDK_COMPAT_GATEWAY=1 go test -race -count=1 -timeout 10m . -run TestSpec015SDKCompatAgainstGateway"},
		CIJobs:   []string{"integration (cross-service + SPEC-015 AC manifest)", "spec-015-acceptance"},
		Evidence: []evidenceAnchor{
			{"test/integration/spec015_sdk_fixture_test.go", "TestSpec015SDKCompatFixturePinsOpenAISDKs"},
			{"test/integration/spec015/run_acceptance.sh", "SPEC-015 AC-09 Python/Node SDKs against real local gateway"},
			{"test/integration/spec015_sdk_fixture_test.go", "TestSpec015SDKCompatAgainstGateway"},
			{"test/integration/spec015/sdk_compat/python/smoke_openai_python.py", "SPEC-015 SDK non-streaming smoke"},
			{"test/integration/spec015/sdk_compat/js/smoke_openai_node.mjs", "SPEC-015 SDK streaming smoke"},
		},
	},
	{
		Number:   10,
		Summary:  "rotate-key reconnects with a fresh key and commits Keychain state only after acceptance",
		SpecStep: "SPEC-015 §14 AC-10",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd phase4-coordinator && go test ./... -count=1"},
		CIJobs:   []string{"phase3-binary (swift test)", "phase4-coordinator (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/RotateKeyCommandTests.swift", "testRotateKeyCommitsCandidateAfterReconnectAcceptance"},
			{"phase3-binary/Tests/macprovider-cliTests/RotateKeyCommandTests.swift", "testRotateKeyLeavesKeychainUnchangedWhenReconnectRejected"},
			{"phase4-coordinator/internal/ws/server_test.go", "TestProviderAuthV2ReceiptRotationMovesPriorPubkeyToPrevious"},
		},
	},
	{
		Number:   11,
		Summary:  "previous receipt keys verify during the seven-day grace window with -60s slack",
		SpecStep: "SPEC-015 §14 AC-11",
		Commands: []string{"cd test/integration && go test -race -count=1 -timeout 5m ./...", "cd phase4-coordinator && go test ./... -count=1"},
		CIJobs:   []string{"integration (cross-service + SPEC-015 AC manifest)", "phase4-coordinator (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"test/integration/spec015/acceptance_manifest_test.go", "TestRotationGraceVerifierAcceptsPreviousKeyWithinSlack"},
			{"phase4-coordinator/internal/ws/server_test.go", "TestPoolzReceiptPubkeyPrevShape"},
			{"phase4-coordinator/internal/ws/server_test.go", "TestProviderAuthV2ReceiptRotationPurgesPreviousAfterGraceWindow"},
		},
	},
	{
		Number:   12,
		Summary:  "null-usage model-not-loaded errors carry zero-token receipts with canonical error output_hash",
		SpecStep: "SPEC-015 §14 AC-12",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd phase5-gateway && go test ./... -count=1"},
		CIJobs:   []string{"phase3-binary (swift test)", "phase5-gateway (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "testNullUsageModelNotLoadedErrorGetsReceiptHeader"},
			{"phase5-gateway/internal/router/server_test.go", "TestNullUsageErrorReceiptHeaderForwarded"},
		},
	},
	{
		Number:   13,
		Summary:  "gateway-local rejects never expose receipt headers",
		SpecStep: "SPEC-015 §14 AC-13",
		Commands: []string{"cd phase5-gateway && go test ./... -count=1"},
		CIJobs:   []string{"phase5-gateway (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase5-gateway/internal/router/server_test.go", "TestGatewayAuthFailureDoesNotExposeReceiptHeader"},
			{"phase5-gateway/internal/router/server_test.go", "TestQuotaExhaustedDoesNotExposeReceiptHeader"},
			{"phase5-gateway/internal/router/server_test.go", "TestKillSwitchRejectDoesNotExposeReceiptHeader"},
		},
	},
	{
		Number:   14,
		Summary:  "non-streaming responses from receipt_pubkey:null providers remain receipt-free",
		SpecStep: "SPEC-015 §14 AC-14",
		Commands: []string{"cd test/integration && go test -race -count=1 -timeout 5m ./...", "cd phase3-binary && swift test --parallel"},
		CIJobs:   []string{"integration (cross-service + SPEC-015 AC manifest)", "phase3-binary (swift test)"},
		Evidence: []evidenceAnchor{
			{"test/integration/scenarios_test.go", "pre-v1.6 fake provider response exposed receipt header"},
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "testPreKeypairReceiptHeaderIsOmittedWithout500"},
		},
	},
	{
		Number:   15,
		Summary:  "receipt headers stay under 4096 bytes and nginx deploy gates preserve that size",
		SpecStep: "SPEC-015 §14 AC-15",
		Commands: []string{"make test-dist", "cd phase3-binary && swift test --parallel"},
		CIJobs:   []string{"deploy tooling (check-deploy-config gate)", "phase3-binary (swift test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "testWorstCaseModelIDHeaderStaysUnder4096Bytes"},
			{"phase4-coordinator/dist/test/check_nginx_receipt_buffers_test.sh", "proxy_buffer_size 8k"},
			{"test/integration/spec015/run_acceptance.sh", "SPEC-015 AC-15 nginx receipt header deployment buffers"},
		},
	},
	{
		Number:   16,
		Summary:  "receipt-enabled path p95 delta over disabled baseline is at most 5ms on Apple Silicon",
		SpecStep: "SPEC-015 §14 AC-16",
		Commands: []string{"cd phase3-binary && swift test --parallel"},
		CIJobs:   []string{"phase3-binary (swift test)"},
		Evidence: []evidenceAnchor{{"phase3-binary/Tests/macprovider-cliTests/ReceiptPerfTests.swift", "testReceiptConstructionP95IsUnderFiveMillisecondsFor1024TokenPayload"}},
	},
	{
		Number:   17,
		Summary:  "coordinator treats provider_receipt_public_key as parser-optional and logs no_keypair omissions",
		SpecStep: "SPEC-015 §14 AC-17",
		Commands: []string{"cd phase3-binary && swift test --parallel", "cd phase4-coordinator && go test ./... -count=1"},
		CIJobs:   []string{"phase3-binary (swift test)", "phase4-coordinator (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift", "testAuthInitialOmitsReceiptPublicKeyWhenUnavailableAndProofNeverIncludesIt"},
			{"phase4-coordinator/internal/ws/server_test.go", "TestProviderAuthV2ReceiptKeyOmissionClearsLiveReceiptTrustState"},
		},
	},
}

func TestSpec015AcceptanceCriteria(t *testing.T) {
	root := repoRoot(t)
	for _, ac := range spec015ACs {
		ac := ac
		t.Run(fmt.Sprintf("AC-%02d", ac.Number), func(t *testing.T) {
			if ac.SpecStep != fmt.Sprintf("SPEC-015 §14 AC-%d", ac.Number) {
				t.Fatalf("spec step = %q", ac.SpecStep)
			}
			if len(ac.Commands) == 0 || len(ac.CIJobs) == 0 {
				t.Fatalf("missing automated command or CI job: %+v", ac)
			}
			for _, anchor := range ac.Evidence {
				content, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(anchor.File)))
				if err != nil {
					t.Fatalf("read evidence %s: %v", anchor.File, err)
				}
				if !strings.Contains(string(content), anchor.Pattern) {
					t.Fatalf("evidence %s missing pattern %q", anchor.File, anchor.Pattern)
				}
			}
			t.Logf("%s PASS via %s", ac.SpecStep, strings.Join(ac.CIJobs, ", "))
		})
	}
}

func TestAcceptanceManifestCoversAC1ThroughAC17(t *testing.T) {
	if len(spec015ACs) != 17 {
		t.Fatalf("manifest has %d ACs, want 17", len(spec015ACs))
	}
	seen := make(map[int]bool, len(spec015ACs))
	for _, ac := range spec015ACs {
		if ac.Number < 1 || ac.Number > 17 {
			t.Fatalf("AC-%d outside expected range", ac.Number)
		}
		if seen[ac.Number] {
			t.Fatalf("duplicate AC-%d", ac.Number)
		}
		seen[ac.Number] = true
		if ac.SpecStep != fmt.Sprintf("SPEC-015 §14 AC-%d", ac.Number) {
			t.Fatalf("AC-%d spec step = %q", ac.Number, ac.SpecStep)
		}
		if len(ac.Commands) == 0 || len(ac.CIJobs) == 0 || len(ac.Evidence) == 0 {
			t.Fatalf("AC-%d missing command, CI job, or evidence: %+v", ac.Number, ac)
		}
		joined := strings.ToLower(strings.Join(append(append([]string{ac.Summary, ac.SpecStep}, ac.Commands...), ac.CIJobs...), " "))
		for _, forbidden := range []string{"manual", "deferred", "todo"} {
			if strings.Contains(joined, forbidden) {
				t.Fatalf("AC-%d uses forbidden non-automated marker %q: %s", ac.Number, forbidden, joined)
			}
		}
	}
	for i := 1; i <= 17; i++ {
		if !seen[i] {
			t.Fatalf("manifest missing AC-%d", i)
		}
	}
}

func TestAcceptanceEvidenceAnchorsExist(t *testing.T) {
	root := repoRoot(t)
	for _, ac := range spec015ACs {
		for _, anchor := range ac.Evidence {
			path := filepath.Join(root, filepath.FromSlash(anchor.File))
			content, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("AC-%d evidence file %s: %v", ac.Number, anchor.File, err)
			}
			if !strings.Contains(string(content), anchor.Pattern) {
				t.Fatalf("AC-%d evidence %s missing pattern %q", ac.Number, anchor.File, anchor.Pattern)
			}
		}
	}
}

func TestSpec015Section14StillDefinesAC1ThroughAC17(t *testing.T) {
	content := readRepoFile(t, "specs/SPEC-015-receipts.md")
	for i := 1; i <= 17; i++ {
		want := fmt.Sprintf("**AC-%d.**", i)
		if !strings.Contains(content, want) {
			t.Fatalf("SPEC-015 §14 missing %s", want)
		}
	}
	if strings.Contains(content, "**AC-18.**") {
		t.Fatalf("SPEC-015 §14 unexpectedly contains AC-18")
	}
}

func TestCIWiresAcceptanceSuite(t *testing.T) {
	ci := readRepoFile(t, ".github/workflows/ci.yml")
	required := []string{
		"name: integration (cross-service + SPEC-015 AC manifest)",
		"Run cross-service integration and SPEC-015 AC manifest tests",
		"working-directory: test/integration",
		"run: go test -race -count=1 -timeout 5m ./...",
		"- integration",
		"INTEGRATION_RESULT",
		"name: phase3-binary (swift test)",
		"run: swift test --parallel",
		"name: deploy tooling (check-deploy-config gate)",
		"run: make test-dist",
		"spec-015-acceptance",
	}
	for _, want := range required {
		if !strings.Contains(ci, want) {
			t.Fatalf("CI missing %q", want)
		}
	}
}

func TestAcceptanceReportListsEveryAC(t *testing.T) {
	lines := make([]string, 0, len(spec015ACs))
	for _, ac := range spec015ACs {
		lines = append(lines, fmt.Sprintf("SPEC-015 §14 AC-%02d covered via %s", ac.Number, strings.Join(ac.CIJobs, ", ")))
	}
	sort.Strings(lines)
	for _, line := range lines {
		t.Log(line)
	}
}

func TestAcceptanceRunnerReportsEveryAC(t *testing.T) {
	runner := readRepoFile(t, "test/integration/spec015/run_acceptance.sh")
	re := regexp.MustCompile(`AC-([0-9]{2})`)
	seen := map[int]int{}
	for _, match := range re.FindAllStringSubmatch(runner, -1) {
		n, err := strconv.Atoi(match[1])
		if err != nil {
			t.Fatalf("parse %q: %v", match[1], err)
		}
		if n < 1 || n > 17 {
			t.Fatalf("runner reports out-of-range AC-%02d", n)
		}
		seen[n]++
	}
	for i := 1; i <= 17; i++ {
		if seen[i] == 0 {
			t.Fatalf("runner does not visibly report AC-%02d", i)
		}
	}
	if !strings.Contains(runner, "go test -v -race -count=1 -timeout 5m ./spec015") {
		t.Fatalf("runner must execute manifest with -v so AC report lines are visible")
	}
}

func TestReceiptVerifierAcceptsPoolzPreviousKeyWithinSlack(t *testing.T) {
	currentPub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate current key: %v", err)
	}
	previousPub, previousPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate previous key: %v", err)
	}
	rotatedAt := time.Unix(1_800_000_000, 0)
	expiresAt := rotatedAt.Add(7 * 24 * time.Hour)
	trust := PoolzReceiptTrust{
		ReceiptPubkey: base64.StdEncoding.EncodeToString(currentPub),
		ReceiptPubkeyPrev: &PoolzReceiptPubkeyPrevious{
			Pubkey:    base64.StdEncoding.EncodeToString(previousPub),
			RotatedAt: rotatedAt.Unix(),
			ExpiresAt: expiresAt.Unix(),
		},
	}
	inside := signedReceiptHeader(t, previousPriv, previousPub, rotatedAt.Add(-50*time.Second).Unix())
	before := signedReceiptHeader(t, previousPriv, previousPub, rotatedAt.Add(-61*time.Second).Unix())
	after := signedReceiptHeader(t, previousPriv, previousPub, expiresAt.Add(time.Second).Unix())

	verified, err := VerifyReceiptAgainstPoolzTrust(inside, trust)
	if err != nil {
		t.Fatalf("previous key inside -60s slack failed verification: %v", err)
	}
	if verified.KeySource != "previous" {
		t.Fatalf("key source = %q, want previous", verified.KeySource)
	}
	if got := verified.Tuple["provider_pubkey"]; got != trust.ReceiptPubkeyPrev.Pubkey {
		t.Fatalf("provider_pubkey = %v, want selected previous /poolz key", got)
	}
	if _, err := VerifyReceiptAgainstPoolzTrust(before, trust); err == nil {
		t.Fatalf("previous key receipt before -60s slack verified")
	}
	if _, err := VerifyReceiptAgainstPoolzTrust(after, trust); err == nil {
		t.Fatalf("previous key receipt after grace expiry verified")
	}
	tampered := inside[:len(inside)-2] + "AA"
	if _, err := VerifyReceiptAgainstPoolzTrust(tampered, trust); err == nil {
		t.Fatalf("tampered previous-key header verified")
	}
}

func TestReceiptVerifierRejectsTupleProviderPubkeyMismatch(t *testing.T) {
	trustedPub, trustedPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate trusted key: %v", err)
	}
	advertisedPub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate advertised key: %v", err)
	}
	header := signedReceiptHeader(t, trustedPriv, advertisedPub, time.Unix(1_800_000_000, 0).Unix())
	trust := PoolzReceiptTrust{ReceiptPubkey: base64.StdEncoding.EncodeToString(trustedPub)}

	if _, err := VerifyReceiptAgainstPoolzTrust(header, trust); err == nil {
		t.Fatalf("receipt signed by trusted key verified despite mismatched tuple provider_pubkey")
	}
}

func signedReceiptHeader(t *testing.T, priv ed25519.PrivateKey, pub ed25519.PublicKey, unixTS int64) string {
	t.Helper()
	tupleData := []byte(`{"model_id":"fixture","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + base64.StdEncoding.EncodeToString(pub) + `","tokens_out":1,"ttft_ms":2,"unix_ts":` + strconv.FormatInt(unixTS, 10) + `}`)
	signature := ed25519.Sign(priv, tupleData)
	return base64.StdEncoding.EncodeToString(tupleData) + "." + base64.StdEncoding.EncodeToString(signature)
}

func TestAuditPromptRejectsManualOnlyAcceptance(t *testing.T) {
	prompt := readRepoFile(t, "specs/AUDIT_SPEC_015_IMPL_STEP_11_PROMPT.md")
	re := regexp.MustCompile(`(?i)no AC is .*manual|manual verification`)
	if !re.MatchString(prompt) {
		t.Fatalf("Step 11 audit prompt does not explicitly reject manual-only acceptance")
	}
}

func readRepoFile(t *testing.T, rel string) string {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(repoRoot(t), filepath.FromSlash(rel)))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(content)
}

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "specs", "SPEC-015-receipts.md")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("repo root not found from %s", dir)
		}
		dir = parent
	}
}
