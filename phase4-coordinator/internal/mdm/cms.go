package mdm

// signMobileconfig creates a CMS SignedData (PKCS#7) envelope for a
// .mobileconfig plist, enabling macOS to display the signer's identity at
// install time. Signing is install-time trust only — it does not affect the
// SCEP or MDM protocol trust chain inside the profile.
//
// Implements RFC 5652 §5 SignedData with:
//   - SHA-256 digest algorithm
//   - RSA or ECDSA (P-256) signature algorithm, inferred from the key type
//   - Explicit signed attributes (content type + message digest)
//   - The signing certificate embedded in the CertificateSet

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"fmt"
	"math/big"
	"time"
)

// ASN.1 OIDs used in CMS/PKCS#7 SignedData.
var (
	oidPKCS7SignedData   = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 2}
	oidPKCS7Data         = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 1}
	oidSHA256            = asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 2, 1}
	oidRSA               = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 1}
	oidECDSAWithSHA256   = asn1.ObjectIdentifier{1, 2, 840, 10045, 4, 3, 2}
	oidAttrContentType   = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 9, 3}
	oidAttrMessageDigest = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 9, 4}
	oidAttrSigningTime   = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 9, 5}
)

// signedAttribute is a CMS SignedAttribute (RFC 5652 §5.3).
type signedAttribute struct {
	Type   asn1.ObjectIdentifier
	Values asn1.RawValue `asn1:"set"`
}

// issuerAndSerialNumber identifies the signer by certificate issuer + serial.
type issuerAndSerialNumber struct {
	Issuer       pkix.RDNSequence
	SerialNumber *big.Int
}

// signMobileconfig produces a DER-encoded CMS SignedData wrapping the given
// plist bytes. The content is embedded (encapContentInfo.eContent present).
func signMobileconfig(content []byte, cert *x509.Certificate, key crypto.Signer) ([]byte, error) {
	// 1. Compute the message digest of the content.
	digest := sha256.Sum256(content)

	// 2. Build the signed attributes (content type, signing time, message digest).
	//    Order matters: attributes must be in DER SET order (OID-sorted) for
	//    correct signature verification, but encoding/asn1 does not auto-sort
	//    SET OF — we order them by OID value manually.
	//
	//    OID ordering: 1.2.840.113549.1.9.3 (contentType) < 1.2.840.113549.1.9.4
	//    (messageDigest) < 1.2.840.113549.1.9.5 (signingTime) by DER SET rules.
	//    Actually, RFC 5652 says ordered SET is not required for SignedAttributes
	//    (they are defined as IMPLICIT [0] SET OF Attribute, receiver must re-sort).
	//    We build them in a deterministic order that produces a valid signature.

	contentTypeVal, err := asn1.Marshal(oidPKCS7Data)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal content type value: %w", err)
	}
	digestVal, err := asn1.Marshal(digest[:])
	if err != nil {
		return nil, fmt.Errorf("cms: marshal digest value: %w", err)
	}
	signingTimeVal, err := asn1.Marshal(time.Now().UTC())
	if err != nil {
		return nil, fmt.Errorf("cms: marshal signing time: %w", err)
	}

	// Each Attribute is SEQUENCE { OID, SET { value } }.
	// Build as raw bytes so we control the SET encoding precisely.
	attrContentType, err := marshalAttribute(oidAttrContentType, contentTypeVal)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal contentType attr: %w", err)
	}
	attrSigningTime, err := marshalAttribute(oidAttrSigningTime, signingTimeVal)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal signingTime attr: %w", err)
	}
	attrMessageDigest, err := marshalAttribute(oidAttrMessageDigest, digestVal)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal messageDigest attr: %w", err)
	}

	// signedAttrsBytes is the concatenation of attribute DER encodings, which
	// will be wrapped in an explicit SET tag for both storage and signing.
	signedAttrsInner := append(attrContentType, attrSigningTime...)
	signedAttrsInner = append(signedAttrsInner, attrMessageDigest...)

	// 3. Compute the signature over the DER SET encoding of signedAttrs.
	//    RFC 5652 §5.4: the message authentication code is computed over the
	//    complete DER encoding of the SignedAttributes, re-tagged as a SET
	//    (tag 0x31) — NOT as the IMPLICIT [0] tag used in the SignerInfo.
	signedAttrsDER, err := marshalSET(signedAttrsInner)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal signed attributes SET: %w", err)
	}
	signedAttrsHash := sha256.Sum256(signedAttrsDER)

	var sigAlgOID asn1.ObjectIdentifier
	var sigBytes []byte

	switch k := key.(type) {
	case *rsa.PrivateKey:
		sigAlgOID = oidRSA
		sigBytes, err = k.Sign(rand.Reader, signedAttrsHash[:], crypto.SHA256)
		if err != nil {
			return nil, fmt.Errorf("cms: RSA sign: %w", err)
		}
	case *ecdsa.PrivateKey:
		sigAlgOID = oidECDSAWithSHA256
		sigBytes, err = k.Sign(rand.Reader, signedAttrsHash[:], crypto.SHA256)
		if err != nil {
			return nil, fmt.Errorf("cms: ECDSA sign: %w", err)
		}
	default:
		return nil, fmt.Errorf("cms: unsupported key type %T", key)
	}

	// 4. Build SignerInfo.
	//    SignerInfo version is 1 when using issuerAndSerialNumber (RFC 5652 §5.3).
	issuerRDN := pkix.RDNSequence{}
	if err := issuerRDN.FillFromRDNSequence(&cert.Issuer); err != nil {
		return nil, fmt.Errorf("cms: encode issuer: %w", err)
	}
	issuerDER, err := asn1.Marshal(issuerRDN)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal issuer: %w", err)
	}
	issuerAndSN := issuerAndSerialNumber{
		SerialNumber: cert.SerialNumber,
	}
	if rest, err2 := asn1.Unmarshal(issuerDER, &issuerAndSN.Issuer); err2 != nil || len(rest) != 0 {
		return nil, fmt.Errorf("cms: unmarshal issuer RDN: %w", err2)
	}
	sidDER, err := asn1.Marshal(issuerAndSN)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal issuerAndSN: %w", err)
	}

	signerInfoDER, err := buildSignerInfoDER(sidDER, signedAttrsInner, sigAlgOID, sigBytes)
	if err != nil {
		return nil, fmt.Errorf("cms: build signerInfo: %w", err)
	}

	// 5. Build EncapsulatedContentInfo with the plist bytes.
	contentDER, err := asn1.Marshal(content) // OCTET STRING
	if err != nil {
		return nil, fmt.Errorf("cms: marshal content: %w", err)
	}
	eContentTagged := asn1.RawValue{Class: asn1.ClassContextSpecific, Tag: 0, IsCompound: true, Bytes: contentDER}
	eContentDER, err := asn1.Marshal(eContentTagged)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal eContent explicit: %w", err)
	}
	eciDER, err := marshalSEQUENCE(append(mustMarshalOID(oidPKCS7Data), eContentDER...))
	if err != nil {
		return nil, fmt.Errorf("cms: build encapContentInfo: %w", err)
	}

	// 6. DigestAlgorithmIdentifiers SET { AlgorithmIdentifier }.
	digestAlgDER, err := asn1.Marshal(pkix.AlgorithmIdentifier{Algorithm: oidSHA256})
	if err != nil {
		return nil, fmt.Errorf("cms: marshal digestAlg: %w", err)
	}
	digestAlgSetDER, err := marshalSET(digestAlgDER)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal digestAlg SET: %w", err)
	}

	// 7. Certificates [0] IMPLICIT — the raw certificate DER bytes.
	certTagged := asn1.RawValue{Class: asn1.ClassContextSpecific, Tag: 0, IsCompound: true, Bytes: cert.Raw}
	certsDER, err := asn1.Marshal(certTagged)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal certificates: %w", err)
	}

	// 8. SignerInfos SET { SignerInfo }.
	signerInfosSetDER, err := marshalSET(signerInfoDER)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal signerInfos SET: %w", err)
	}

	// 9. SignedData SEQUENCE {version(1), digestAlgs, encapCI, certs[0], signerInfos}.
	versionDER, err := asn1.Marshal(1) // version = 1
	if err != nil {
		return nil, fmt.Errorf("cms: marshal version: %w", err)
	}
	signedDataInner := make([]byte, 0,
		len(versionDER)+len(digestAlgSetDER)+len(eciDER)+len(certsDER)+len(signerInfosSetDER))
	signedDataInner = append(signedDataInner, versionDER...)
	signedDataInner = append(signedDataInner, digestAlgSetDER...)
	signedDataInner = append(signedDataInner, eciDER...)
	signedDataInner = append(signedDataInner, certsDER...)
	signedDataInner = append(signedDataInner, signerInfosSetDER...)
	signedDataDER, err := marshalSEQUENCE(signedDataInner)
	if err != nil {
		return nil, fmt.Errorf("cms: build signedData: %w", err)
	}

	// 10. ContentInfo SEQUENCE { OID pkcs7SignedData, [0] EXPLICIT signedData }.
	signedDataExplicit := asn1.RawValue{
		Class:      asn1.ClassContextSpecific,
		Tag:        0,
		IsCompound: true,
		Bytes:      signedDataDER,
	}
	signedDataExplicitDER, err := asn1.Marshal(signedDataExplicit)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal signedData explicit: %w", err)
	}
	ciInner := append(mustMarshalOID(oidPKCS7SignedData), signedDataExplicitDER...)
	return marshalSEQUENCE(ciInner)
}

// marshalAttribute encodes a CMS Attribute as:
// SEQUENCE { OID, SET { preEncodedValue } }
// where preEncodedValue is already DER-encoded.
func marshalAttribute(oid asn1.ObjectIdentifier, valueDER []byte) ([]byte, error) {
	oidDER, err := asn1.Marshal(oid)
	if err != nil {
		return nil, err
	}
	setDER, err := marshalSET(valueDER)
	if err != nil {
		return nil, err
	}
	return marshalSEQUENCE(append(oidDER, setDER...))
}

// buildSignerInfoDER assembles the raw DER bytes for a SignerInfo:
//
//	SignerInfo ::= SEQUENCE {
//	  version              INTEGER (1),
//	  sid                  IssuerAndSerialNumber,
//	  digestAlgorithm      AlgorithmIdentifier,
//	  signedAttrs     [0] IMPLICIT SET OF Attribute,
//	  signatureAlgorithm   AlgorithmIdentifier,
//	  signature            OCTET STRING
//	}
func buildSignerInfoDER(sidDER, signedAttrsInner []byte, sigAlgOID asn1.ObjectIdentifier, sigBytes []byte) ([]byte, error) {
	vDER, err := asn1.Marshal(1)
	if err != nil {
		return nil, err
	}
	digestAlgDER, err := asn1.Marshal(pkix.AlgorithmIdentifier{Algorithm: oidSHA256})
	if err != nil {
		return nil, err
	}
	// signedAttrs is stored as IMPLICIT [0] SET (class context-specific, tag 0).
	// We use the raw bytes of the inner attributes and wrap with the implicit tag.
	signedAttrsImplicit := asn1.RawValue{
		Class:      asn1.ClassContextSpecific,
		Tag:        0,
		IsCompound: true,
		Bytes:      signedAttrsInner,
	}
	signedAttrsDER, err := asn1.Marshal(signedAttrsImplicit)
	if err != nil {
		return nil, err
	}
	sigAlgDER, err := asn1.Marshal(pkix.AlgorithmIdentifier{Algorithm: sigAlgOID})
	if err != nil {
		return nil, err
	}
	sigDER, err := asn1.Marshal(sigBytes)
	if err != nil {
		return nil, err
	}
	inner := make([]byte, 0, len(vDER)+len(sidDER)+len(digestAlgDER)+len(signedAttrsDER)+len(sigAlgDER)+len(sigDER))
	inner = append(inner, vDER...)
	inner = append(inner, sidDER...)
	inner = append(inner, digestAlgDER...)
	inner = append(inner, signedAttrsDER...)
	inner = append(inner, sigAlgDER...)
	inner = append(inner, sigDER...)
	return marshalSEQUENCE(inner)
}

// marshalSEQUENCE wraps inner bytes in a DER SEQUENCE (tag 0x30).
func marshalSEQUENCE(inner []byte) ([]byte, error) {
	return asn1.Marshal(asn1.RawValue{
		Class:      asn1.ClassUniversal,
		Tag:        asn1.TagSequence,
		IsCompound: true,
		Bytes:      inner,
	})
}

// marshalSET wraps inner bytes in a DER SET (tag 0x31).
func marshalSET(inner []byte) ([]byte, error) {
	return asn1.Marshal(asn1.RawValue{
		Class:      asn1.ClassUniversal,
		Tag:        asn1.TagSet,
		IsCompound: true,
		Bytes:      inner,
	})
}

// mustMarshalOID marshals an OID to DER. Panics on error (OIDs are static
// constants — failure is a programming error, not a runtime condition).
func mustMarshalOID(oid asn1.ObjectIdentifier) []byte {
	b, err := asn1.Marshal(oid)
	if err != nil {
		panic(fmt.Sprintf("cms: marshal OID %v: %v", oid, err))
	}
	return b
}
