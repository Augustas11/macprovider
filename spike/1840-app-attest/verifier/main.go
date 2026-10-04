package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}
	var code int
	switch os.Args[1] {
	case "verify-attestation":
		code = cmdVerifyAttestation(os.Args[2:])
	case "verify-assertion":
		code = cmdVerifyAssertion(os.Args[2:])
	case "dump":
		code = cmdDump(os.Args[2:])
	case "-h", "--help", "help":
		usage(os.Stdout)
		code = 0
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		usage(os.Stderr)
		code = 2
	}
	os.Exit(code)
}

func usage(w io.Writer) {
	fmt.Fprintf(w, `appattest-verify — App Attest spike verifier

usage:
  appattest-verify verify-attestation --result result.json --team TEAMID --bundle tech.malibu.app [--env production|development] [--expect-category N|any] [--bundle-version VER] [--acl require|record]
  appattest-verify verify-assertion --result result.json --team TEAMID --bundle tech.malibu.app [--env production|development] [--expect-category N|any] [--bundle-version VER] [--acl require|record]
  appattest-verify dump --result result.json

On macOS the App ID is TEAMID.<code signing identifier>; --bundle must be the
app's signing identifier, which build-and-sign.sh sets to the bundle id.
clientDataHash is SHA-256(nonce_b64 bytes), matching the spike app.
--acl require (default) fails unless the aclBlob equals Apple's documented
SIP + Full Security value; --acl record only reports it.
The Apple App Attestation Root CA is embedded. verify-assertion rechecks the
attestation before trusting the leaf public key and requires each client_data
JSON "challenge" to equal nonce_b64. Receipt fraud-metric calls are not
performed.
`)
}

type commonFlags struct {
	result        string
	team          string
	bundle        string
	env           Environment
	category      CategoryPolicy
	bundleVersion string
	acl           ACLPolicy
}

func parseCommon(name string, args []string) (commonFlags, error) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	result := fs.String("result", "", "path to the spike result JSON")
	team := fs.String("team", "", "Apple Team ID")
	bundle := fs.String("bundle", "tech.malibu.app", "bundle identifier")
	envName := fs.String("env", "production", "production or development")
	category := fs.String("expect-category", "", "validation category, or 'any' (default 6 for production, 3 for development)")
	bundleVersion := fs.String("bundle-version", "", "expected apple_bundle_version_01; empty records the value")
	aclName := fs.String("acl", string(ACLRequire), "require or record the documented SIP + Full Security aclBlob")
	if err := fs.Parse(args); err != nil {
		return commonFlags{}, err
	}
	if fs.NArg() != 0 {
		return commonFlags{}, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	if *result == "" || *team == "" || *bundle == "" {
		return commonFlags{}, fmt.Errorf("--result, --team, and --bundle are required")
	}
	env, err := parseEnvironment(*envName)
	if err != nil {
		return commonFlags{}, err
	}
	acl, err := parseACLPolicy(*aclName)
	if err != nil {
		return commonFlags{}, err
	}
	policy := CategoryPolicy{Value: env.defaultCategory()}
	if *category != "" {
		if strings.EqualFold(*category, "any") {
			policy = CategoryPolicy{Any: true}
		} else {
			n, err := strconv.ParseUint(*category, 10, 32)
			if err != nil {
				return commonFlags{}, fmt.Errorf("--expect-category: %w", err)
			}
			policy = CategoryPolicy{Value: uint32(n)}
		}
	}
	out := commonFlags{
		result:        *result,
		team:          *team,
		bundle:        *bundle,
		env:           env,
		category:      policy,
		bundleVersion: *bundleVersion,
		acl:           acl,
	}
	return out, nil
}

func cmdVerifyAttestation(args []string) int {
	flags, err := parseCommon("verify-attestation", args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		return 2
	}
	report, err := verifyResultAttestation(flags)
	writeAttestReport(os.Stdout, report, err)
	if err != nil {
		return 1
	}
	return 0
}

func cmdVerifyAssertion(args []string) int {
	flags, err := parseCommon("verify-assertion", args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		return 2
	}
	attestReport, attestErr := verifyResultAttestation(flags)
	writeAttestReport(os.Stdout, attestReport, attestErr)
	if attestErr != nil {
		fmt.Fprintf(os.Stdout, "assertion_result: fail\n")
		return 1
	}
	result, _, err := loadResult(flags.result)
	if err != nil {
		fmt.Fprintf(os.Stdout, "assertion_result: fail\nerror: %s\n", err)
		return 1
	}
	records, err := result.assertionList()
	if err != nil {
		fmt.Fprintf(os.Stdout, "assertion_result: fail\nerror: %s\n", err)
		return 1
	}
	items := make([]Assertion, 0, len(records))
	for i, record := range records {
		body, err := decodeB64(record.AssertionB64)
		if err != nil {
			fmt.Fprintf(os.Stdout, "assertion_result: fail\nerror: assertion %d: %s\n", i, err)
			return 1
		}
		client, err := record.clientBytes()
		if err != nil {
			fmt.Fprintf(os.Stdout, "assertion_result: fail\nerror: assertion %d: %s\n", i, err)
			return 1
		}
		if err := checkClientChallenge(client, result.NonceB64); err != nil {
			fmt.Fprintf(os.Stdout, "assertion_result: fail\nerror: assertion %d: %s\n", i, err)
			return 1
		}
		items = append(items, Assertion{Body: body, ClientData: client})
	}
	assertReport, err := VerifyAssertions(attestReport.PublicKey, flags.team, flags.bundle, items, flags.category)
	writeAssertReport(os.Stdout, assertReport, err)
	if err != nil {
		return 1
	}
	return 0
}

func verifyResultAttestation(flags commonFlags) (AttestReport, error) {
	root, err := loadAppleRoot()
	if err != nil {
		return AttestReport{}, err
	}
	result, _, err := loadResult(flags.result)
	if err != nil {
		return AttestReport{AppID: flags.team + "." + flags.bundle}, err
	}
	attestation, err := decodeB64(result.AttestationB64)
	if err != nil {
		return AttestReport{}, fmt.Errorf("attestation_b64: %w", err)
	}
	keyID, err := decodeB64(result.KeyID)
	if err != nil {
		return AttestReport{}, fmt.Errorf("key_id: %w", err)
	}
	challenge, err := decodeB64(result.NonceB64)
	if err != nil {
		return AttestReport{}, fmt.Errorf("nonce_b64: %w", err)
	}
	clientDataHash := sha256.Sum256(challenge)
	return VerifyAttestation(AttestInput{
		Attestation:    attestation,
		KeyID:          keyID,
		ClientDataHash: clientDataHash[:],
		Team:           flags.team,
		Bundle:         flags.bundle,
		Env:            flags.env,
		Category:       flags.category,
		BundleVersion:  flags.bundleVersion,
		ACL:            flags.acl,
		Now:            time.Now(),
		Root:           root,
	})
}

// checkClientChallenge enforces Apple's assertion step "the embedded challenge
// in the client data matches the earlier challenge". The spike app embeds
// nonce_b64 as the "challenge" member of its posture JSON.
func checkClientChallenge(client []byte, nonceB64 string) error {
	if nonceB64 == "" {
		return fmt.Errorf("result has no nonce_b64 to compare the client data challenge with")
	}
	var doc struct {
		Challenge *string `json:"challenge"`
	}
	if err := json.Unmarshal(client, &doc); err != nil {
		return fmt.Errorf("client_data is not JSON: %w", err)
	}
	if doc.Challenge == nil || *doc.Challenge != nonceB64 {
		return fmt.Errorf("client_data challenge does not match nonce_b64")
	}
	return nil
}

func cmdDump(args []string) int {
	fs := flag.NewFlagSet("dump", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	resultPath := fs.String("result", "", "path to the spike result JSON")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *resultPath == "" || fs.NArg() != 0 {
		fmt.Fprintf(os.Stderr, "--result is required\n")
		return 2
	}
	data, err := os.ReadFile(*resultPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		return 1
	}
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, data, "", "  "); err != nil {
		fmt.Fprintf(os.Stderr, "result is not JSON: %s\n", err)
		return 1
	}
	os.Stdout.Write(pretty.Bytes())
	if pretty.Len() == 0 || pretty.Bytes()[pretty.Len()-1] != '\n' {
		fmt.Fprintln(os.Stdout)
	}
	result, _, err := loadResult(*resultPath)
	if err != nil {
		fmt.Fprintf(os.Stdout, "decode_error: %s\n", err)
		return 1
	}
	fmt.Fprintf(os.Stdout, "is_supported: %t\nsecure_enclave_available: %t\n", result.IsSupported, result.SecureEnclaveAvailable)
	if result.AttestError != nil {
		fmt.Fprintf(os.Stdout, "attest_error: %s %d %s\n", result.AttestError.Domain, result.AttestError.Code, result.AttestError.Description)
	}
	if result.AttestationB64 == "" {
		fmt.Fprintf(os.Stdout, "attestation: absent\n")
		return 0
	}
	raw, err := decodeB64(result.AttestationB64)
	if err != nil {
		fmt.Fprintf(os.Stdout, "attestation_decode_error: %s\n", err)
		return 0
	}
	summary, err := summarizeAttestation(raw)
	fmt.Fprintln(os.Stdout, summary)
	if err != nil {
		fmt.Fprintf(os.Stdout, "attestation_decode_error: %s\n", err)
	}
	return 0
}

func summarizeAttestation(raw []byte) (string, error) {
	var b strings.Builder
	obj, err := Decode(raw)
	if err != nil {
		return "", err
	}
	if fmtValue, ok := obj.TextKey("fmt"); ok && fmtValue.Kind == KindText {
		fmt.Fprintf(&b, "fmt: %s\n", fmtValue.Text)
	}
	stmt, ok := obj.TextKey("attStmt")
	if !ok || stmt.Kind != KindMap {
		return b.String(), fmt.Errorf("attStmt is missing")
	}
	if x5c, ok := stmt.TextKey("x5c"); ok && x5c.Kind == KindArray {
		fmt.Fprintf(&b, "x5c_count: %d\n", len(x5c.Array))
		for i, item := range x5c.Array {
			if item.Kind != KindBytes {
				continue
			}
			fmt.Fprintf(&b, "x5c_%d_bytes: %d\n", i, len(item.Bytes))
		}
		if len(x5c.Array) > 0 && x5c.Array[0].Kind == KindBytes {
			if leaf, _, err := parseX5C(x5c.Array[:1]); err == nil {
				fmt.Fprintf(&b, "leaf_subject: %s\n", leaf.Subject.String())
				fmt.Fprintf(&b, "leaf_issuer: %s\n", leaf.Issuer.String())
				if acl, ok := findExtension(leaf, oidAttestACL); ok {
					fmt.Fprintf(&b, "acl_blob_present: true\nacl_blob_hex:\n%s\n", hexDump(acl.Value))
					if dump, err := dumpDER(acl.Value); err == nil {
						fmt.Fprintf(&b, "acl_blob_der:\n%s", dump)
					} else {
						fmt.Fprintf(&b, "acl_blob_der_error: %s\n", err)
					}
				} else {
					fmt.Fprintf(&b, "acl_blob_present: false\n")
				}
			}
		}
	}
	if auth, ok := obj.TextKey("authData"); ok && auth.Kind == KindBytes {
		info, err := parseAuthData(auth.Bytes)
		if err != nil {
			fmt.Fprintf(&b, "auth_data_error: %s\n", err)
		} else {
			fmt.Fprintf(&b, "aaguid: %s\ncounter: %d\nflags: 0x%02x\n", printableAAGUID(info.AAGUID), info.Counter, info.Flags)
			if info.HasExtensions {
				if category, err := validationCategory(info.Extensions); err == nil {
					fmt.Fprintf(&b, "validation_category: %d\n", category)
				}
				if version, err := extensionBundleVersion(info.Extensions); err == nil {
					fmt.Fprintf(&b, "bundle_version_extension: %s\n", version)
				}
			}
		}
	}
	return b.String(), nil
}

func writeAttestReport(w io.Writer, report AttestReport, err error) {
	if err != nil {
		fmt.Fprintf(w, "result: fail\n")
	} else {
		fmt.Fprintf(w, "result: pass\n")
	}
	if root, rootErr := loadAppleRoot(); rootErr == nil {
		fmt.Fprintf(w, "root_sha256: %s\n", fingerprint(root))
	}
	if report.AppID != "" {
		fmt.Fprintf(w, "app_id: %s\n", report.AppID)
	}
	if len(report.PublicKeySHA256) > 0 {
		fmt.Fprintf(w, "leaf_public_key_sha256: %x\n", report.PublicKeySHA256)
	}
	if len(report.RPIDHash) > 0 {
		fmt.Fprintf(w, "rp_id_hash: %s\n", hex.EncodeToString(report.RPIDHash))
	}
	if report.AAGUID != "" {
		fmt.Fprintf(w, "aaguid: %s\n", report.AAGUID)
	}
	if report.Leaf != nil {
		fmt.Fprintf(w, "counter: %d\nflags: 0x%02x\ncert_count: %d\n", report.Counter, report.Flags, report.CertCount)
	}
	if report.HasCategory {
		fmt.Fprintf(w, "validation_category: %d\n", report.ValidationCategory)
	}
	if report.BundleVersion != "" {
		fmt.Fprintf(w, "bundle_version_extension: %s\n", report.BundleVersion)
	}
	if report.ReceiptLen > 0 {
		fmt.Fprintf(w, "receipt_bytes: %d\nreceipt_sequence_prefix: %t\n", report.ReceiptLen, report.ReceiptSequencePrefix)
	}
	fmt.Fprintf(w, "acl_blob_present: %t\n", report.ACLPresent)
	fmt.Fprintf(w, "acl_blob_full_security: %t\n", report.ACLFullSecurity)
	if report.ACLPresent {
		fmt.Fprintf(w, "acl_blob_hex:\n%s\nacl_blob_der:\n%s", hexDump(report.ACLRaw), report.ACLDump)
		if len(report.ACLInner) > 0 {
			fmt.Fprintf(w, "acl_blob_inner_b64: %s\n", base64.StdEncoding.EncodeToString(report.ACLInner))
		}
		if report.ACLInnerDump != "" {
			fmt.Fprintf(w, "acl_blob_inner_der:\n%s", report.ACLInnerDump)
		}
	}
	if err != nil {
		fmt.Fprintf(w, "error: %s\n", err)
	}
}

func writeAssertReport(w io.Writer, report AssertReport, err error) {
	if err != nil {
		fmt.Fprintf(w, "assertion_result: fail\n")
	} else {
		fmt.Fprintf(w, "assertion_result: pass\n")
	}
	if report.AppID != "" {
		fmt.Fprintf(w, "assertion_app_id: %s\n", report.AppID)
	}
	if len(report.PublicKeySHA256) > 0 {
		fmt.Fprintf(w, "assertion_leaf_public_key_sha256: %x\n", report.PublicKeySHA256)
	}
	fmt.Fprintf(w, "assertion_count: %d\n", len(report.Counters))
	for i, counter := range report.Counters {
		fmt.Fprintf(w, "counter_%d: %d\n", i, counter)
	}
	increases := len(report.Counters) >= 2
	for i := 1; i < len(report.Counters); i++ {
		if report.Counters[i] <= report.Counters[i-1] {
			increases = false
		}
	}
	fmt.Fprintf(w, "counter_increases: %t\n", increases && err == nil)
	if err != nil {
		fmt.Fprintf(w, "assertion_error: %s\n", err)
	}
}
