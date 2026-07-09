package mdm

// SignMobileconfig creates a CMS SignedData (PKCS#7) envelope for a
// .mobileconfig plist, enabling macOS to display the signer's identity at
// install time. Signing is install-time trust only — it does not affect the
// SCEP or MDM protocol trust chain inside the profile.
//
// Implements RFC 5652 §5 SignedData with:
//   - SHA-256 digest algorithm
//   - RSA or ECDSA (P-256) signature algorithm, inferred from the key type
//   - Explicit signed attributes (content type, signing time, message digest)
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

// SignMobileconfig produces a DER-encoded CMS SignedData wrapping the given
// plist bytes. The content is embedded (encapContentInfo.eContent present).
func SignMobileconfig(content []byte, cert *x509.Certificate, key crypto.Signer) ([]byte, error) {
	// 1. Compute the message digest of the content.
	digest := sha256.Sum256(content)

	// 2. Build the signed attributes: contentType, signingTime, messageDigest.
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

	// signedAttrsInner is the concatenation of attribute DER encodings wrapped
	// as an IMPLICIT [0] SET in the SignerInfo.
	signedAttrsInner := append(attrContentType, attrSigningTime...)
	signedAttrsInner = append(signedAttrsInner, attrMessageDigest...)

	// 3. Signature is computed over the DER SET encoding of signedAttrs
	//    (RFC 5652 §5.4 — re-tagged as universal SET 0x31).
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

	// 4. Build IssuerAndSerialNumber using the raw DER issuer from the cert.
	//    cert.RawIssuer is the already-encoded Name (SEQUENCE of SETs).
	sidDER, err := marshalIssuerAndSN(cert.RawIssuer, cert.SerialNumber)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal issuerAndSN: %w", err)
	}

	signerInfoDER, err := buildSignerInfoDER(sidDER, signedAttrsInner, sigAlgOID, sigBytes)
	if err != nil {
		return nil, fmt.Errorf("cms: build signerInfo: %w", err)
	}

	// 5. EncapsulatedContentInfo with the plist bytes.
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

	// 7. Certificates [0] IMPLICIT — raw certificate DER.
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

	// 9. SignedData SEQUENCE { version(1), digestAlgs, encapCI, certs[0], signerInfos }.
	versionDER, err := asn1.Marshal(1)
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

// marshalIssuerAndSN encodes IssuerAndSerialNumber by embedding raw DER issuer
// bytes directly, avoiding round-trip issues with pkix.RDNSequence re-ordering.
func marshalIssuerAndSN(rawIssuer []byte, serial *big.Int) ([]byte, error) {
	serialDER, err := asn1.Marshal(serial)
	if err != nil {
		return nil, fmt.Errorf("cms: marshal serial: %w", err)
	}
	inner := append(rawIssuer, serialDER...)
	return marshalSEQUENCE(inner)
}

// marshalAttribute encodes a CMS Attribute as:
// SEQUENCE { OID, SET { preEncodedValue } }
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

// buildSignerInfoDER assembles the raw DER bytes for a SignerInfo.
func buildSignerInfoDER(sidDER, signedAttrsInner []byte, sigAlgOID asn1.ObjectIdentifier, sigBytes []byte) ([]byte, error) {
	vDER, err := asn1.Marshal(1)
	if err != nil {
		return nil, err
	}
	digestAlgDER, err := asn1.Marshal(pkix.AlgorithmIdentifier{Algorithm: oidSHA256})
	if err != nil {
		return nil, err
	}
	// signedAttrs stored as IMPLICIT [0] SET (context-specific, tag 0).
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

// mustMarshalOID panics on error — OID constants are static and failure is a
// programming error.
func mustMarshalOID(oid asn1.ObjectIdentifier) []byte {
	b, err := asn1.Marshal(oid)
	if err != nil {
		panic(fmt.Sprintf("cms: marshal OID %v: %v", oid, err))
	}
	return b
}
