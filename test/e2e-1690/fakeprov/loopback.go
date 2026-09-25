package main

// #1690 e2e: a fake SPEC-042 Trusted Pool member that claims an external
// loopback runtime (runtime_source, e.g. llamacpp_loopback) so a pool-routed
// buyer request settles as pool_operator_attested (SPEC-022 R-12). Test
// scaffolding only. What it adds to the native fake:
//   - a durable provider admission key (Ed25519 seed file) enrolled through
//     the v2 auth identity signature (provider_admission_public_key in the
//     initial frame; identity_signature over the JCS tuple in the proof,
//     phase4-coordinator/internal/ws/identity_signature.go);
//   - runtime_source + a GGUF model identity (macprovider.gguf-file.v1) in
//     the hello, state_update and heartbeats;
//   - `fakeprov offer`: the signed model-admission offer
//     (POST /v1/provider/model-admission/offers, canonicalMap in
//     phase4-coordinator/internal/ws/model_admission.go) that binds the
//     runtime class the coordinator derives (SPEC-042-R004).
// The receipt is the unchanged v0.4 tuple; its model_hash is the GGUF hash.

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// modelHashAlgorithm is the canonical identity algorithm sent with
// model_hash (snapshot-manifest for native MLX, gguf-file for GGUF members).
var modelHashAlgorithm = snapshotManifestV1

func loadOrCreateAdmissionKey(path string) (ed25519.PrivateKey, error) {
	if raw, err := os.ReadFile(path); err == nil {
		seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, fmt.Errorf("admission key file %s: bad seed", path)
		}
		return ed25519.NewKeyFromSeed(seed), nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, []byte(base64.StdEncoding.EncodeToString(seed)+"\n"), 0o600); err != nil {
		return nil, err
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

// transcriptSHA256 is base64(sha256(JCS(initial frame))), decoded the way the
// coordinator decodes it (UseNumber) so integers keep their JSON spelling.
func transcriptSHA256(frame []byte) (string, error) {
	dec := json.NewDecoder(bytes.NewReader(frame))
	dec.UseNumber()
	var raw map[string]any
	if err := dec.Decode(&raw); err != nil {
		return "", err
	}
	canonical, err := spec015CanonicalJSON(raw)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return base64.StdEncoding.EncodeToString(sum[:]), nil
}

func identitySignature(priv ed25519.PrivateKey, authAttemptID, providerID, binaryVersion, ecdhPub, transcript string) (string, error) {
	canonical, err := spec015CanonicalJSON(map[string]any{
		"auth_attempt_id":          authAttemptID,
		"provider_id":              providerID,
		"binary_version":           binaryVersion,
		"provider_ecdh_public_key": ecdhPub,
		"transcript_sha256":        transcript,
	})
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonical)), nil
}

// runOffer: fakeprov offer -coord-http URL -provider-id ID -token-file F
//
//	-admission-key-file K -runtime-source S -served-model-ref R
//	-catalog-key KEY -gguf-sha256 H [-out FILE]
func runOffer(args []string) int {
	fs := flag.NewFlagSet("offer", flag.ContinueOnError)
	coordHTTP := fs.String("coord-http", "http://127.0.0.1:8444", "coordinator provider-port base URL")
	providerID := fs.String("provider-id", "", "provider id")
	tokenFile := fs.String("token-file", "", "provider bearer token file")
	keyFile := fs.String("admission-key-file", "", "admission key seed file (enrolled by a prior serve session)")
	runtimeSource := fs.String("runtime-source", "llamacpp_loopback", "runtime_source")
	servedRef := fs.String("served-model-ref", "llamacpp:qwen2.5-0.5b-instruct-q4_k_m", "served_model_ref")
	catalogKey := fs.String("catalog-key", "", "catalog_model_key")
	ggufSHA := fs.String("gguf-sha256", "", "macprovider.gguf-file.v1 artifact hash")
	out := fs.String("out", "", "write the coordinator response here")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fail := func(format string, a ...any) int {
		fmt.Fprintf(os.Stderr, "fakeprov offer: "+format+"\n", a...)
		return 1
	}
	tok, err := os.ReadFile(*tokenFile)
	if err != nil {
		return fail("token: %v", err)
	}
	priv, err := loadOrCreateAdmissionKey(*keyFile)
	if err != nil {
		return fail("key: %v", err)
	}
	pub := priv.Public().(ed25519.PublicKey)
	digest := sha256.Sum256(pub)
	cand := sha256.Sum256([]byte(*providerID + "|" + *servedRef + "|" + *ggufSHA))
	candidateID := "byom_" + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(cand[:]))
	disc := sha256.Sum256([]byte("e2e-1690 discovery " + candidateID))
	eval := sha256.Sum256([]byte("e2e-1690 evaluation " + candidateID))
	stamp := time.Now().UTC()
	signed := map[string]any{
		"signature_domain":         "macprovider.model_admission.offer.v1",
		"provider_id":              *providerID,
		"candidate_id":             candidateID,
		"runtime_source":           *runtimeSource,
		"served_model_ref":         *servedRef,
		"catalog_model_key":        *catalogKey,
		"discovery_digest_sha256":  hex.EncodeToString(disc[:]),
		"evaluation_digest_sha256": hex.EncodeToString(eval[:]),
		"artifact_hashes":          map[string]any{"macprovider.gguf-file.v1": *ggufSHA},
		"advisory_capabilities": map[string]any{
			"chat_completions": true, "streaming": true, "tool_call_passthrough": nil,
			"structured_output_passthrough": nil, "json_mode": nil, "usage_reporting": true,
			"max_context_tokens": 8192, "quantization": nil, "family": nil, "runtime_version": nil,
		},
		"fit_evidence_source":        "local_discovery",
		"local_readiness":            "ready",
		"requested_disclosure_class": "catalog_binding_requested",
		"timestamp":                  stamp.Format(time.RFC3339Nano),
		"nonce":                      fmt.Sprintf("e2e-nonce-%d", stamp.UnixNano()),
		"idempotency_key":            fmt.Sprintf("e2e-offer-%d", stamp.UnixNano()),
		"signing_key_digest":         hex.EncodeToString(digest[:]),
		"cli_version":                advertisedBinaryVersion(),
	}
	canonical, err := spec015CanonicalJSON(signed)
	if err != nil {
		return fail("jcs: %v", err)
	}
	body := map[string]any{"schema": "model_admission_offer_submit.v1", "signature_algorithm": "ed25519",
		"provider_signature": base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonical))}
	for k, v := range signed {
		body[k] = v
	}
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, strings.TrimRight(*coordHTTP, "/")+"/v1/provider/model-admission/offers", bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(tok)))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fail("post: %v", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if *out != "" {
		_ = os.WriteFile(*out, respBody, 0o600)
	}
	fmt.Printf("offer candidate_id=%s status=%d body=%s\n", candidateID, resp.StatusCode, truncate(respBody))
	if resp.StatusCode/100 != 2 {
		return 1
	}
	return 0
}
