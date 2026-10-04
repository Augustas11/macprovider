package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

// Apple's published sample from "Attestation Object Validation Guide"
// (developer.apple.com/documentation/devicecheck/attestation-object-validation-guide),
// fetched 2026-10-04. Team 1234567890, bundle com.example.myapp, challenge
// "example_server_challenge". The sample app passed the raw challenge bytes as
// clientDataHash: Apple's expected nonce equals SHA256(authData || challenge).
//
// Known errata on that page, checked here so a reader does not chase them:
// the documented "public key SHA256" value differs from the keyId although
// SHA256 of the leaf's uncompressed point equals the keyId (and the leaf CN);
// the documented bundle version is "1.0" while the sample carries "1"; the
// sample's aclBlob is not the documented SIP + Full Security value.
const (
	appleSampleKeyID       = "zgSY9YSD+7TaDXssY6WlOPVS1K3Lmk+pFhlcSWE+ZV0="
	appleSampleNonce       = "h7fQbZOkKU5G8BHma2zEAPC6sgcpl2xhlYC0KuYL/24="
	appleSampleRPIDHash    = "9EZtaPketsEGIMt+Y8coMkRoXuHWRntUFg51MXIFfwM="
	appleSampleChallenge   = "example_server_challenge"
	appleSampleAttestation = "" +
		"o2NmbXRvYXBwbGUtYXBwYXR0ZXN0Z2F0dFN0bXSiY3g1Y4JZBCEwggQdMIIDo6ADAgECAgYBnbE/C04wCgYIKoZIzj0EAwIw" +
		"TzEjMCEGA1UEAwwaQXBwbGUgQXBwIEF0dGVzdGF0aW9uIENBIDExEzARBgNVBAoMCkFwcGxlIEluYy4xEzARBgNVBAgMCkNh" +
		"bGlmb3JuaWEwHhcNMjYwNDIwMTgxMzEyWhcNMjYwNDIzMTgxMzEyWjCBkTFJMEcGA1UEAwxAY2UwNDk4ZjU4NDgzZmJiNGRh" +
		"MGQ3YjJjNjNhNWE1MzhmNTUyZDRhZGNiOWE0ZmE5MTYxOTVjNDk2MTNlNjU1ZDEaMBgGA1UECwwRQUFBIENlcnRpZmljYXRp" +
		"b24xEzARBgNVBAoMCkFwcGxlIEluYy4xEzARBgNVBAgMCkNhbGlmb3JuaWEwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARD" +
		"MlRKzzI9t3REPKrzOfVufpXHJPrCwUJZ82XiRFZQsrX7KFvPVJvLYFlEEudoKiQn7q2p+1Lf7QsasX7Qn6m9o4ICJjCCAiIw" +
		"DAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBPAwFAYDVR0lBA0wCwYJKoZIhvdjZAQYMHoGCSqGSIb3Y2QIBQRtMGukAwIB" +
		"Cr+JMAMCAQC/iTEDAgEAv4kyAwIBAL+JMwMCAQC/iTQeBBwxMjM0NTY3ODkwLmNvbS5leGFtcGxlLm15YXBwv4k2AwIBBL+J" +
		"NwMCAQC/iTkDAgEAv4k6AwIBAL+JOwMCAQCqAwIBADCB4AYJKoZIhvdjZAgHBIHSMIHPv4p4BgQEMjcuML+IUAMCAQK/inkJ" +
		"BAcxLjAuMjE2v4p7CQQHMjRBMzI1Yr+KfAYEBDI3LjC/in0GBAQyNy4wv4p+AwIBAL+KfwMCAQC/iwADAgEAv4sBAwIBAL+L" +
		"AgMCAQC/iwMDAgEAv4sEAwIBAb+LBQMCAQC/iwoQBA4yNC4xLjMyNS4wLjIsML+LCxAEDjI0LjEuMzI1LjAuMiwwv4sMEAQO" +
		"MjQuMS4zMjUuMC4yLDC/iAIKBAhpcGhvbmVvc7+IBQoECEludGVybmFsMDMGCSqGSIb3Y2QIAgQmMCShIgQgh7fQbZOkKU5G" +
		"8BHma2zEAPC6sgcpl2xhlYC0KuYL/24wWAYJKoZIhvdjZAgGBEswSaNHBEUwQwwCMTEwPTAKDANva2ShAwEB/zAJDAJvYaED" +
		"AQH/MAsMBG9zZ26hAwEB/zALDARvZGVsoQMBAf8wCgwDb2NroQMBAf8wCgYIKoZIzj0EAwIDaAAwZQIwIbzHaPbRKcm2sa4J" +
		"vDWyTX40yz9U2byxFxTho+HIM0HeYwF3HLyA3Nrqv3WDy/UdAjEApOoxL7zeQV0yhvasPe31+c1ZYuEDxEU6rDrheFcVMRZe" +
		"pvV10+hFxgIWVMSpQu09WQJHMIICQzCCAcigAwIBAgIQCbrF4bxAGtnUU5W8OBoIVDAKBggqhkjOPQQDAzBSMSYwJAYDVQQD" +
		"DB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5p" +
		"YTAeFw0yMDAzMTgxODM5NTVaFw0zMDAzMTMwMDAwMDBaME8xIzAhBgNVBAMMGkFwcGxlIEFwcCBBdHRlc3RhdGlvbiBDQSAx" +
		"MRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAErls3oHdN" +
		"ebI1j0Dn0fImJvHCX+8XgC3qs4JqWYdP+NKtFSV4mqJmBBkSSLY8uWcGnpjTY71eNw+/oI4ynoBzqYXndG6jWaL2bynbMq9F" +
		"XiEWWNVnr54mfrJhTcIaZs6Zo2YwZDASBgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFKyREFMzvb5oQf+nDKnl+url" +
		"5YqhMB0GA1UdDgQWBBQ+410cBBmpybQx+IR01uHhV3LjmzAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaQAwZgIxALu+" +
		"iI1zjQUCz7z9Zm0JV1A1vNaHLD+EMEkmKe3R+RToeZkcmui1rvjTqFQz97YNBgIxAKs47dDMge0ApFLDukT5k2NlU/7MKX8u" +
		"tN+fXr5aSsq2mVxLgg35BDhveAe7WJQ5t2dyZWNlaXB0WQ+JMIAGCSqGSIb3DQEHAqCAMIACAQExDzANBglghkgBZQMEAgEF" +
		"ADCABgkqhkiG9w0BBwGggCSABIID6DGCBUEwJAIBAgIBAQQcMTIzNDU2Nzg5MC5jb20uZXhhbXBsZS5teWFwcDCCBCsCAQMC" +
		"AQEEggQhMIIEHTCCA6OgAwIBAgIGAZ2xPwtOMAoGCCqGSM49BAMCME8xIzAhBgNVBAMMGkFwcGxlIEFwcCBBdHRlc3RhdGlv" +
		"biBDQSAxMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMB4XDTI2MDQyMDE4MTMxMloXDTI2MDQy" +
		"MzE4MTMxMlowgZExSTBHBgNVBAMMQGNlMDQ5OGY1ODQ4M2ZiYjRkYTBkN2IyYzYzYTVhNTM4ZjU1MmQ0YWRjYjlhNGZhOTE2" +
		"MTk1YzQ5NjEzZTY1NWQxGjAYBgNVBAsMEUFBQSBDZXJ0aWZpY2F0aW9uMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQI" +
		"DApDYWxpZm9ybmlhMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEQzJUSs8yPbd0RDyq8zn1bn6VxyT6wsFCWfNl4kRWULK1" +
		"+yhbz1Sby2BZRBLnaCokJ+6tqftS3+0LGrF+0J+pvaOCAiYwggIiMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgTwMBQG" +
		"A1UdJQQNMAsGCSqGSIb3Y2QEGDB6BgkqhkiG92NkCAUEbTBrpAMCAQq/iTADAgEAv4kxAwIBAL+JMgMCAQC/iTMDAgEAv4k0" +
		"HgQcMTIzNDU2Nzg5MC5jb20uZXhhbXBsZS5teWFwcL+JNgMCAQS/iTcDAgEAv4k5AwIBAL+JOgMCAQC/iTsDAgEAqgMCAQAw" +
		"geAGCSqGSIb3Y2QIBwSB0jCBz7+KeAYEBDI3LjC/iFADAgECv4p5CQQHMS4wLjIxNr+KewkEBzI0QTMyNWK/inwGBAQyNy4w" +
		"v4p9BgQEMjcuML+KfgMCAQC/in8DAgEAv4sAAwIBAL+LAQMCAQC/iwIDAgEAv4sDAwIBAL+LBAMCAQG/iwUDAgEAv4sKEAQO" +
		"MjQuMS4zMjUuMC4yLDC/iwsQBA4yNC4xLjMyNS4wLjIsML+LDBAEDjI0LjEuMzI1LjAuMiwwv4gCCgQIaXBob25lb3O/iAUK" +
		"BAhJbnRlcm5hbDAzBgkqhkiG92NkCAIEJjAkoSIEIIe30G2TpClORvAR5mtsxADwurIHKZdsYZWAtCrmC/9uMFgGCSqGSIb3" +
		"Y2QIBgRLMEmjRwRFMEMMAjExMD0wCgwDb2tkoQMBAf8wCQwCb2GhAwEB/zALDARvc2duoQMBAf8wCwwEb2RlbKEDAQH/MAoM" +
		"A29ja6EDAQH/MAoGCCoEggFdhkjOPQQDAgNoADBlAjAhvMdo9tEpybaxrgm8NbJNfjTLP1TZvLEXFOGj4cgzQd5jAXccvIDc" +
		"2uq/dYPL9R0CMQCk6jEvvN5BXTKG9qw97fX5zVli4QPERTqsOuF4VxUxFl6m9XXT6EXGAhZUxKlC7T0wIAIBBAIBAQQYZXhh" +
		"bXBsZV9zZXJ2ZXJfY2hhbGxlbmdlMGACAQUCAQEEWHJia3RNcTg5bXZEcFJDSy84bGNQaGRMNGRXUXo5T1hJd0hHZGU1eFFm" +
		"U3VJS3NOM09qT1dGOHUrdjBVQTRxOHZqQ1JnRUVKVGxjOUJ3aUl6TlNOT0hRPT0wDgIBBgIBAQQGQVRURVNUMBICAQcCAQEE" +
		"CnByb2R1Y3Rpb24wIAIBDAIBAQQYMjAyNi0wNC0yMVQxODoxMzoxMi4xNTNaMCACARUCAQEEGDIwMjYtMDctMjBUMTg6MTM6" +
		"MTIuMTUzWgAAAAAAAKCAMIIDrjCCA1SgAwIBAgIQZgI4gAAUJvddiw4VLF9uQzAKBggqhkjOPQQDAjB8MTAwLgYDVQQDDCdB" +
		"cHBsZSBBcHBsaWNhdGlvbiBJbnRlZ3JhdGlvbiBDQSA1IC0gRzExJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0" +
		"aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzAeFw0yNjAxMjAyMDIxMDlaFw0yNzAyMTgxODU4Mzla" +
		"MFoxNjA0BgNVBAMMLUFwcGxpY2F0aW9uIEF0dGVzdGF0aW9uIEZyYXVkIFJlY2VpcHQgU2lnbmluZzETMBEGA1UECgwKQXBw" +
		"bGUgSW5jLjELMAkGA1UEBhMCVVMwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ7GK7OxRmtilNRtEBEtKMDmVe0zb1bhR/g" +
		"Gm/t4o3vsPqww2oCpB9EbgBtWA5WimeAiQfzSICRQ4sgzqpMndxWo4IB2DCCAdQwDAYDVR0TAQH/BAIwADAfBgNVHSMEGDAW" +
		"gBTZF/5LZ5A4S5L0287VV4AUC489yTBDBggrBgEFBQcBAQQ3MDUwMwYIKwYBBQUHMAGGJ2h0dHA6Ly9vY3NwLmFwcGxlLmNv" +
		"bS9vY3NwMDMtYWFpY2E1ZzEwMTCCARwGA1UdIASCARMwggEPMIIBCwYJKoZIhvdjZAUBMIH9MIHDBggrBgEFBQcCAjCBtgyB" +
		"s1JlbGlhbmNlIG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0YW5jZSBvZiB0aGUgdGhl" +
		"biBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBjb25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFu" +
		"ZCBjZXJ0aWZpY2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMDUGCCsGAQUFBwIBFilodHRwOi8vd3d3LmFwcGxlLmNvbS9j" +
		"ZXJ0aWZpY2F0ZWF1dGhvcml0eTAdBgNVHQ4EFgQUNFWJcHRgDiLSumfPpVtpwiPxyigwDgYDVR0PAQH/BAQDAgeAMA8GCSqG" +
		"SIb3Y2QMDwQCBQAwCgYIKoZIzj0EAwIDSAAwRQIgHGeXuYJF0dbccgS3mwI8r/h78u/4k33XIMReiuRlwusCIQD8yFmEzsmh" +
		"LMKGqdSSdv3w0vYl3HX8fPiHRWl75h6qtDCCAvkwggJ/oAMCAQICEFb7g9Qr/43DN5kjtVqubr0wCgYIKoZIzj0EAwMwZzEb" +
		"MBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEG" +
		"A1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTkwMzIyMTc1MzMzWhcNMzQwMzIyMDAwMDAwWjB8MTAwLgYDVQQD" +
		"DCdBcHBsZSBBcHBsaWNhdGlvbiBJbnRlZ3JhdGlvbiBDQSA1IC0gRzExJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24g" +
		"QXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJLO" +
		"Y719hrGrKAo7HOGv+wSUgJGs9jHfpssoNW9ES+Eh5VfdEo2NuoJ8lb5J+r4zyq7NBBnxL0Ml+vS+s8uDfrqjgfcwgfQwDwYD" +
		"VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBS7sN6hWDOImqSKmd6+veuv2sskqzBGBggrBgEFBQcBAQQ6MDgwNgYIKwYBBQUH" +
		"MAGGKmh0dHA6Ly9vY3NwLmFwcGxlLmNvbS9vY3NwMDMtYXBwbGVyb290Y2FnMzA3BgNVHR8EMDAuMCygKqAohiZodHRwOi8v" +
		"Y3JsLmFwcGxlLmNvbS9hcHBsZXJvb3RjYWczLmNybDAdBgNVHQ4EFgQU2Rf+S2eQOEuS9NvO1VeAFAuPPckwDgYDVR0PAQH/" +
		"BAQDAgEGMBAGCiqGSIb3Y2QGAgMEAgUAMAoGCCqGSM49BAMDA2gAMGUCMQCNb6afoeDk7FtOc4qSfz14U5iP9NofWB7DdUr+" +
		"OKhMKoMaGqoNpmRt4bmT6NFVTO0CMGc7LLTh6DcHd8vV7HaoGjpVOz81asjF5pKw4WG+gElp5F8rqWzhEQKqzGHZOLdzSjCC" +
		"AkMwggHJoAMCAQICCC3F/IjSxUuVMAoGCCqGSM49BAMDMGcxGzAZBgNVBAMMEkFwcGxlIFJvb3QgQ0EgLSBHMzEmMCQGA1UE" +
		"CwwdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMB4XDTE0" +
		"MDQzMDE4MTkwNloXDTM5MDQzMDE4MTkwNlowZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBs" +
		"ZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwdjAQBgcqhkjOPQIB" +
		"BgUrgQQAIgNiAASY6S89QHKk7ZMicoETHN0QlfHFo05x3BQW2Q7lpgUqd2R7X04407scRLV/9R+2MmJdyemEW08wTxFaAP1Y" +
		"WAyl9Q8sTQdHE3Xal5eXbzFc7SudeyA72LlU2V6ZpDpRCjGjQjBAMB0GA1UdDgQWBBS7sN6hWDOImqSKmd6+veuv2sskqzAP" +
		"BgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQDAwNoADBlAjEAg+nBxBZeGl00GNnt7/RsDgBGS7jf" +
		"skYRxQ/95nqMoaZrzsID1Jz1k8Z0uGrfqiMVAjBtZooQytQN1E/NjUM+tIpjpTNu423aF7dkH8hTJvmIYnQ5Cxdby1GoDOgY" +
		"A+eisigAADGB/TCB+gIBATCBkDB8MTAwLgYDVQQDDCdBcHBsZSBBcHBsaWNhdGlvbiBJbnRlZ3JhdGlvbiBDQSA1IC0gRzEx" +
		"JjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJV" +
		"UwIQZgI4gAAUJvddiw4VLF9uQzANBglghkgBZQMEAgEFADAKBggqhkjOPQQDAgRHMEUCIFp+GIuJm5vqJhLtDX40gGP90KJt" +
		"LoPyzcLEuKHYMr9zAiEAgPafgwU16p2N6GvCC3Gj4BAb66R38+IP+Arn3QYbD9QAAAAAAABoYXV0aERhdGFY4vRGbWj5HrbB" +
		"BiDLfmPHKDJEaF7h1kZ7VBYOdTFyBX8DQAAAAABhcHBhdHRlc3QAAAAAAAAAACDOBJj1hIP7tNoNeyxjpaU49VLUrcuaT6kW" +
		"GVxJYT5lXaUBAgMmIAEhWCBDMlRKzzI9t3REPKrzOfVufpXHJPrCwUJZ82XiRFZQsiJYILX7KFvPVJvLYFlEEudoKiQn7q2p" +
		"+1Lf7QsasX7Qn6m9ondhcHBsZV9idW5kbGVfdmVyc2lvbl8wMWExeBxhcHBsZV92YWxpZGF0aW9uX2NhdGVnb3J5XzAxRAEA" +
		"AAA="
)

func TestAppleSampleAttestation(t *testing.T) {
	root, err := loadAppleRoot()
	if err != nil {
		t.Fatal(err)
	}
	attestation := mustB64(t, appleSampleAttestation)
	keyID := mustB64(t, appleSampleKeyID)
	in := AttestInput{
		Attestation:    attestation,
		KeyID:          keyID,
		ClientDataHash: []byte(appleSampleChallenge),
		Team:           "1234567890",
		Bundle:         "com.example.myapp",
		Env:            EnvProduction,
		Category:       CategoryPolicy{Value: 1},
		BundleVersion:  "1",
		ACL:            ACLRecord,
		Now:            time.Date(2026, 4, 21, 12, 0, 0, 0, time.UTC),
		Root:           root,
	}
	report, err := VerifyAttestation(in)
	if err != nil {
		t.Fatalf("Apple sample failed: %v", err)
	}
	if !bytes.Equal(report.PublicKeySHA256, keyID) {
		t.Fatalf("key hash %x", report.PublicKeySHA256)
	}
	if !bytes.Equal(report.RPIDHash, mustB64(t, appleSampleRPIDHash)) {
		t.Fatalf("rpIdHash %x", report.RPIDHash)
	}
	if report.Counter != 0 || report.AAGUID != "appattest" || report.CertCount != 2 {
		t.Fatalf("counter=%d aaguid=%q certs=%d", report.Counter, report.AAGUID, report.CertCount)
	}
	if report.ValidationCategory != 1 || report.BundleVersion != "1" {
		t.Fatalf("category=%d version=%q", report.ValidationCategory, report.BundleVersion)
	}
	if !report.ACLPresent || report.ACLFullSecurity || len(report.ACLInner) == 0 {
		t.Fatalf("acl present=%t full=%t inner=%d", report.ACLPresent, report.ACLFullSecurity, len(report.ACLInner))
	}
	if !strings.Contains(report.ACLInnerDump, "osgn") {
		t.Fatalf("acl inner dump:\n%s", report.ACLInnerDump)
	}

	ext, ok := findExtension(report.Leaf, oidAttestNonce)
	if !ok {
		t.Fatal("nonce extension missing")
	}
	got, err := explicitOctet(ext.Value, 1)
	if err != nil || !bytes.Equal(got, mustB64(t, appleSampleNonce)) {
		t.Fatalf("nonce extension %x: %v", got, err)
	}

	// Each negative flips one input; every one must fail closed.
	hashed := sha256.Sum256([]byte(appleSampleChallenge))
	mutations := map[string]func(*AttestInput){
		"acl require":        func(in *AttestInput) { in.ACL = ACLRequire },
		"hashed challenge":   func(in *AttestInput) { in.ClientDataHash = hashed[:] },
		"other team":         func(in *AttestInput) { in.Team = "0987654321" },
		"other bundle":       func(in *AttestInput) { in.Bundle = "tech.malibu.app" },
		"development":        func(in *AttestInput) { in.Env = EnvDevelopment },
		"developer id class": func(in *AttestInput) { in.Category = CategoryPolicy{Value: 6} },
		"bundle version":     func(in *AttestInput) { in.BundleVersion = "1.0" },
		"after leaf expiry":  func(in *AttestInput) { in.Now = time.Date(2026, 4, 24, 0, 0, 0, 0, time.UTC) },
		"other key id":       func(in *AttestInput) { in.KeyID = mustB64(t, appleSampleRPIDHash) },
	}
	for name, mutate := range mutations {
		bad := in
		mutate(&bad)
		if _, err := VerifyAttestation(bad); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func mustB64(t *testing.T, value string) []byte {
	t.Helper()
	out, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		t.Fatal(err)
	}
	return out
}
