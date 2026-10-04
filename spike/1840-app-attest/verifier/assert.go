package main

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"fmt"
)

// Assertion is one generateAssertion payload plus the exact clientData bytes
// the app hashed.
type Assertion struct {
	Body       []byte
	ClientData []byte
}

// AssertReport records the counters used to prove the attested key advanced.
type AssertReport struct {
	AppID           string
	Counters        []uint32
	PublicKeySHA256 []byte
}

// VerifyAssertions checks each assertion with the attested P-256 key and
// requires the authenticator counters to increase.
func VerifyAssertions(pub *ecdsa.PublicKey, team, bundle string, items []Assertion, policy CategoryPolicy) (AssertReport, error) {
	var report AssertReport
	id, err := appID(team, bundle)
	if err != nil {
		return report, err
	}
	report.AppID = id
	if pub == nil {
		return report, fmt.Errorf("attested public key is required")
	}
	keyHash, err := publicKeyHash(pub)
	if err != nil {
		return report, err
	}
	report.PublicKeySHA256 = keyHash
	if len(items) < 2 {
		return report, fmt.Errorf("need two assertions to show the counter increasing")
	}
	rp := sha256.Sum256([]byte(id))
	var previous uint32
	for i, item := range items {
		counter, err := verifyOneAssertion(pub, rp[:], item, policy)
		if err != nil {
			return report, fmt.Errorf("assertion %d: %w", i, err)
		}
		if i > 0 && counter <= previous {
			return report, fmt.Errorf("assertion %d counter %d does not increase past %d", i, counter, previous)
		}
		if i == 0 && counter == 0 {
			return report, fmt.Errorf("first assertion counter is 0")
		}
		previous = counter
		report.Counters = append(report.Counters, counter)
	}
	return report, nil
}

func verifyOneAssertion(pub *ecdsa.PublicKey, rpID []byte, item Assertion, policy CategoryPolicy) (uint32, error) {
	if len(item.ClientData) == 0 {
		return 0, fmt.Errorf("clientData is empty")
	}
	obj, err := Decode(item.Body)
	if err != nil {
		return 0, fmt.Errorf("cbor: %w", err)
	}
	if obj.Kind != KindMap {
		return 0, fmt.Errorf("assertion is not a map")
	}
	sig, ok := obj.TextKey("signature")
	if !ok || sig.Kind != KindBytes || len(sig.Bytes) == 0 {
		return 0, fmt.Errorf("signature is missing")
	}
	auth, ok := obj.TextKey("authenticatorData")
	if !ok || auth.Kind != KindBytes {
		return 0, fmt.Errorf("authenticatorData is missing")
	}
	info, err := parseAuthData(auth.Bytes)
	if err != nil {
		return 0, err
	}
	if !bytesEqual(info.RPIDHash, rpID) {
		return 0, fmt.Errorf("rpIdHash does not match the App ID")
	}
	clientHash := sha256.Sum256(item.ClientData)
	nonceInput := make([]byte, 0, len(auth.Bytes)+len(clientHash))
	nonceInput = append(nonceInput, auth.Bytes...)
	nonceInput = append(nonceInput, clientHash[:]...)
	nonce := sha256.Sum256(nonceInput)
	// "signature is valid for nonce": the signature is ECDSA-SHA256 over the
	// message nonce, so the P-256 digest is SHA-256(nonce). Interoperable
	// server implementations verify it this way; the macOS 27 run confirms it.
	digest := sha256.Sum256(nonce[:])
	if !ecdsa.VerifyASN1(pub, digest[:], sig.Bytes) {
		return 0, fmt.Errorf("signature does not verify")
	}
	if info.HasExtensions {
		category, err := validationCategory(info.Extensions)
		if err != nil {
			return 0, err
		}
		if err := checkCategory(category, policy); err != nil {
			return 0, err
		}
		if _, err := extensionBundleVersion(info.Extensions); err != nil {
			return 0, err
		}
	}
	return info.Counter, nil
}
