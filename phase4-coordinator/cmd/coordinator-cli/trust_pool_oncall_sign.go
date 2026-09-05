package main

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// oncallSigningKeyEnv holds the Ed25519 operations-authority private key PEM.
// It is populated only inside the GitHub production-release environment by the
// build-signed-oncall-readiness workflow; it must never be committed or logged.
const oncallSigningKeyEnv = "MACPROVIDER_SPEC043_ONCALL_AUTHORITY_SIGNING_KEY_PEM"

// trustPoolOnCallSign signs an unsigned on-call readiness record with the
// Ed25519 operations-authority key and writes the signed record (ready for
// `trust-pool-oncall upsert`) to --out or stdout. Signing reuses
// trustpool.SignOnCallReadiness so the preimage is byte-identical to what the
// coordinator verifies. This subcommand is offline: it makes no HTTP request
// and needs no operator/base URL.
func trustPoolOnCallSign(args []string, getenv func(string) string, stdin io.Reader, stdout io.Writer) error {
	fs := flag.NewFlagSet("oncall-sign", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	inPath := fs.String("in", "", "unsigned on-call readiness JSON; use - for stdin")
	outPath := fs.String("out", "", "signed output path; empty writes to stdout")
	keyFile := fs.String("key-file", "", "Ed25519 private key PEM path; overrides "+oncallSigningKeyEnv)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*inPath) == "" {
		return fmt.Errorf("--in is required")
	}

	raw, err := readCLIInput(*inPath, stdin)
	if err != nil {
		return err
	}
	var rec trustpool.OnCallReadiness
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&rec); err != nil {
		return fmt.Errorf("unsigned on-call readiness JSON: %w", err)
	}
	var trailing struct{}
	if err := dec.Decode(&trailing); err != io.EOF {
		return fmt.Errorf("unsigned on-call readiness JSON must contain exactly one object")
	}
	if strings.TrimSpace(rec.OperationID) == "" {
		return fmt.Errorf("operation_id is required")
	}

	priv, err := loadOnCallSigningKey(*keyFile, getenv)
	if err != nil {
		return err
	}
	signed, err := trustpool.SignOnCallReadiness(priv, rec)
	if err != nil {
		return err
	}

	out, err := json.MarshalIndent(onCallReadinessRequest{
		OperationID:                           signed.OperationID,
		LaunchEnvironmentID:                   signed.LaunchEnvironmentID,
		RecordVersion:                         signed.RecordVersion,
		PrimaryOperatorContact:                signed.PrimaryOperatorContact,
		SecondaryOperatorContact:              signed.SecondaryOperatorContact,
		BreakGlassEscalationPath:              signed.BreakGlassEscalationPath,
		CompromiseNotificationChannel:         signed.CompromiseNotificationChannel,
		CreatorAgreementNotificationAck:       signed.CreatorAgreementNotificationAck,
		CreatorEmergencyNotificationMechanism: signed.CreatorEmergencyNotificationMechanism,
		LastConfirmedAtUTC:                    signed.LastConfirmedAtUTC,
		ConfirmationTTLSeconds:                signed.ConfirmationTTLSeconds,
		OperationsAuthorityPublicKey:          signed.OperationsAuthorityPublicKey,
		OperationsAuthoritySignature:          signed.OperationsAuthoritySignature,
	}, "", "  ")
	if err != nil {
		return err
	}
	out = append(out, '\n')
	if strings.TrimSpace(*outPath) == "" {
		_, err = stdout.Write(out)
		return err
	}
	return os.WriteFile(strings.TrimSpace(*outPath), out, 0o600)
}

func loadOnCallSigningKey(keyFile string, getenv func(string) string) (ed25519.PrivateKey, error) {
	var pemBytes []byte
	if strings.TrimSpace(keyFile) != "" {
		data, err := os.ReadFile(strings.TrimSpace(keyFile))
		if err != nil {
			return nil, fmt.Errorf("read signing key file: %w", err)
		}
		pemBytes = data
	} else {
		env := strings.TrimSpace(getenv(oncallSigningKeyEnv))
		if env == "" {
			return nil, fmt.Errorf("no signing key: set --key-file or %s", oncallSigningKeyEnv)
		}
		pemBytes = []byte(env)
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, fmt.Errorf("signing key is not PEM-encoded")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse Ed25519 PKCS8 private key: %w", err)
	}
	priv, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("signing key is not Ed25519")
	}
	return priv, nil
}
