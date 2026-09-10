package relayblind

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const transcriptDomain = "macprovider/spec041/relay-blind/transcript/v1"
const requestKeyInfo = "macprovider/spec041/request/aead/v1"
const requestNonceInfo = "macprovider/spec041/request/aead-nonce/v1"

func (r KeyRecord) EncryptionPublicKey() ([]byte, error) {
	if err := r.validateStructure(); err != nil {
		return nil, err
	}
	return decodeBase64URLFixed(r.PublicKey, 32)
}

func (r ReservationResponse) NewEnvelope(requestID string, issuedAt time.Time, replayNonce []byte) (Envelope, error) {
	if err := r.Validate(); err != nil || len(replayNonce) != 32 {
		return Envelope{}, ErrInvalidEnvelope
	}
	return Envelope{
		Version:              EnvelopeVersion,
		Mode:                 ModeRequired,
		EndpointFamily:       r.EndpointFamily,
		Model:                r.Model,
		ProviderModel:        r.ProviderModel,
		Stream:               r.Stream,
		RequestID:            requestID,
		MaxOutputTokens:      r.MaxOutputTokens,
		InputTokenUpperBound: r.InputTokenUpperBound,
		ReservationTokenCap:  r.ReservationTokenCap,
		ProviderBinding:      r.ProviderBinding,
		BuyerBinding:         r.BuyerBinding,
		KeyRecordDigest:      r.KeyRecordDigest,
		KID:                  r.KID,
		RequestReplayNonce:   encodeBase64URL(replayNonce),
		IssuedAtUnix:         issuedAt.Unix(),
		Algorithm:            Algorithm,
	}, nil
}

func NewSignedKeyRecord(publicKey []byte, identityPrivateKey ed25519.PrivateKey, models []string, maxEncryptedRequestBytes uint64, notBefore, expiresAt time.Time) (KeyRecord, error) {
	if len(identityPrivateKey) != ed25519.PrivateKeySize {
		return KeyRecord{}, ErrInvalidKeyRecord
	}
	identityPublicKey := identityPrivateKey.Public().(ed25519.PublicKey)
	fingerprint := sha256.Sum256(identityPublicKey)
	record := KeyRecord{
		Algorithm:                Algorithm,
		PublicKey:                encodeBase64URL(publicKey),
		IdentityFingerprint:      encodeBase64URL(fingerprint[:]),
		Models:                   append([]string(nil), models...),
		MaxEncryptedRequestBytes: maxEncryptedRequestBytes,
		EndpointFamilies:         []string{EndpointChatCompletions},
		SignatureAlgorithm:       SignatureAlgorithm,
		NotBeforeUnix:            notBefore.Unix(),
		ExpiresAtUnix:            expiresAt.Unix(),
	}
	immutable, err := record.ImmutableFraming()
	if err != nil {
		return KeyRecord{}, err
	}
	kidDigest := sha256.Sum256(immutable)
	record.KID = encodeBase64URL(kidDigest[:16])
	signed, err := record.SignedFraming()
	if err != nil {
		return KeyRecord{}, err
	}
	recordDigest := sha256.Sum256(signed)
	record.KeyRecordDigest = encodeBase64URL(recordDigest[:])
	record.Signature = encodeBase64URL(ed25519.Sign(identityPrivateKey, signed))
	if err := record.validateStructure(); err != nil {
		return KeyRecord{}, err
	}
	return record, nil
}

func (r KeyRecord) ImmutableFraming() ([]byte, error) {
	if err := r.validateImmutable(); err != nil {
		return nil, err
	}
	publicKey, _ := decodeBase64URLFixed(r.PublicKey, 32)
	fingerprint, _ := decodeBase64URLFixed(r.IdentityFingerprint, 32)
	var framed bytes.Buffer
	if err := writeFrame(&framed, []byte(r.Algorithm)); err != nil {
		return nil, err
	}
	if err := writeFrame(&framed, publicKey); err != nil {
		return nil, err
	}
	if err := writeFrame(&framed, fingerprint); err != nil {
		return nil, err
	}
	if err := writeArray(&framed, r.Models); err != nil {
		return nil, err
	}
	writeU64(&framed, r.MaxEncryptedRequestBytes)
	if err := writeArray(&framed, r.EndpointFamilies); err != nil {
		return nil, err
	}
	if err := writeFrame(&framed, []byte(r.SignatureAlgorithm)); err != nil {
		return nil, err
	}
	return framed.Bytes(), nil
}

func (r KeyRecord) SignedFraming() ([]byte, error) {
	immutable, err := r.ImmutableFraming()
	if err != nil {
		return nil, err
	}
	var framed bytes.Buffer
	framed.Write(immutable)
	writeI64(&framed, r.NotBeforeUnix)
	writeI64(&framed, r.ExpiresAtUnix)
	return framed.Bytes(), nil
}

func (r KeyRecord) Digest() (string, error) {
	signed, err := r.SignedFraming()
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(signed)
	return encodeBase64URL(digest[:]), nil
}

func (r KeyRecord) Verify(pin IdentityPin, now time.Time) error {
	if err := pin.Verify(now); err != nil {
		return err
	}
	if err := r.validateStructure(); err != nil {
		return err
	}
	nowUnix := now.Unix()
	if r.NotBeforeUnix > nowUnix+int64(MaxKeyFutureSkew/time.Second) || r.ExpiresAtUnix <= nowUnix {
		return fmt.Errorf("%w: validity window", ErrInvalidKeyRecord)
	}
	pub, _ := decodeBase64URLFixed(pin.IdentityPublicKey, ed25519.PublicKeySize)
	if subtle.ConstantTimeCompare([]byte(r.IdentityFingerprint), []byte(pin.Fingerprint)) != 1 {
		return fmt.Errorf("%w: identity fingerprint mismatch", ErrInvalidKeyRecord)
	}
	for _, model := range r.Models {
		if !contains(pin.Models, model) {
			return fmt.Errorf("%w: model outside pin scope", ErrInvalidKeyRecord)
		}
	}
	if !contains(pin.EndpointFamilies, EndpointChatCompletions) {
		return fmt.Errorf("%w: endpoint outside pin scope", ErrInvalidKeyRecord)
	}
	signed, _ := r.SignedFraming()
	signature, _ := decodeBase64URLFixed(r.Signature, ed25519.SignatureSize)
	if !ed25519.Verify(ed25519.PublicKey(pub), signed, signature) {
		return fmt.Errorf("%w: signature", ErrInvalidKeyRecord)
	}
	return nil
}

func ValidateKeyRenewal(previous, next KeyRecord, pin IdentityPin, now time.Time) error {
	if err := previous.Verify(pin, now); err != nil {
		return err
	}
	if err := next.Verify(pin, now); err != nil {
		return err
	}
	previousImmutable, _ := previous.ImmutableFraming()
	nextImmutable, _ := next.ImmutableFraming()
	if previous.KID != next.KID || !bytes.Equal(previousImmutable, nextImmutable) {
		return fmt.Errorf("%w: immutable key substitution", ErrInvalidKeyRecord)
	}
	if next.NotBeforeUnix != previous.NotBeforeUnix || next.ExpiresAtUnix < previous.ExpiresAtUnix {
		return fmt.Errorf("%w: non-monotonic renewal", ErrInvalidKeyRecord)
	}
	return nil
}

func (p IdentityPin) Verify(now time.Time) error {
	if err := p.validateStructure(); err != nil {
		return err
	}
	if p.Revoked || now.Unix() < p.NotBeforeUnix || now.Unix() >= p.ExpiresAtUnix {
		return fmt.Errorf("%w: unavailable", ErrInvalidPin)
	}
	return nil
}

func (p IdentityPin) VerifyRecord(record KeyRecord, now time.Time) error {
	return record.Verify(p, now)
}

func (e Envelope) AAD() ([]byte, error) {
	if err := e.validateStructure(false); err != nil {
		return nil, err
	}
	ephemeral, _ := decodeBase64URLFixed(e.BuyerEphemeralPublicKey, 32)
	replayNonce, _ := decodeBase64URLFixed(e.RequestReplayNonce, 32)
	var framed bytes.Buffer
	for _, value := range []string{e.Version, e.Mode, e.EndpointFamily, e.Model, e.ProviderModel} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	if e.Stream {
		writeU64(&framed, 1)
	} else {
		writeU64(&framed, 0)
	}
	if err := writeFrame(&framed, []byte(e.RequestID)); err != nil {
		return nil, err
	}
	writeU64(&framed, uint64(e.MaxOutputTokens))
	writeU64(&framed, uint64(e.InputTokenUpperBound))
	writeU64(&framed, uint64(e.ReservationTokenCap))
	for _, value := range []string{e.ProviderBinding, e.BuyerBinding, e.KeyRecordDigest, e.KID} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	if err := writeFrame(&framed, ephemeral); err != nil {
		return nil, err
	}
	if err := writeFrame(&framed, replayNonce); err != nil {
		return nil, err
	}
	writeI64(&framed, e.IssuedAtUnix)
	if err := writeFrame(&framed, []byte(e.Algorithm)); err != nil {
		return nil, err
	}
	return framed.Bytes(), nil
}

func (e Envelope) Validate(now time.Time, maxSkew time.Duration) error {
	if err := e.validateStructure(true); err != nil {
		return err
	}
	if maxSkew < 0 || e.IssuedAtUnix < now.Add(-maxSkew).Unix() || e.IssuedAtUnix > now.Add(maxSkew).Unix() {
		return fmt.Errorf("%w: timestamp", ErrInvalidEnvelope)
	}
	return nil
}

func (e Envelope) Digest() (string, error) {
	if err := e.validateStructure(true); err != nil {
		return "", err
	}
	raw, err := json.Marshal(e)
	if err != nil {
		return "", err
	}
	return DigestEnvelopeBytes(raw)
}

func DigestEnvelopeBytes(raw []byte) (string, error) {
	if _, err := ParseEnvelope(raw); err != nil {
		return "", err
	}
	digest := sha256.Sum256(raw)
	return encodeBase64URL(digest[:]), nil
}

func (e Envelope) Encrypt(plaintext, providerPublicKey, buyerPrivateKey []byte) (Envelope, error) {
	if len(plaintext) == 0 || len(plaintext) > MaxEncryptedRequestBytes {
		return Envelope{}, fmt.Errorf("%w: plaintext size", ErrInvalidEnvelope)
	}
	privateKey, err := ecdh.X25519().NewPrivateKey(buyerPrivateKey)
	if err != nil {
		return Envelope{}, fmt.Errorf("%w: buyer private key", ErrInvalidEnvelope)
	}
	peer, err := ecdh.X25519().NewPublicKey(providerPublicKey)
	if err != nil {
		return Envelope{}, fmt.Errorf("%w: provider public key", ErrInvalidEnvelope)
	}
	e.BuyerEphemeralPublicKey = encodeBase64URL(privateKey.PublicKey().Bytes())
	e.Ciphertext = ""
	e.Tag = ""
	aad, err := e.AAD()
	if err != nil {
		return Envelope{}, err
	}
	aead, nonce, err := deriveAEAD(privateKey, peer, aad)
	if err != nil {
		return Envelope{}, err
	}
	sealed := aead.Seal(nil, nonce, plaintext, aad)
	tagStart := len(sealed) - aead.Overhead()
	e.Ciphertext = encodeBase64URL(sealed[:tagStart])
	e.Tag = encodeBase64URL(sealed[tagStart:])
	if err := e.validateStructure(true); err != nil {
		return Envelope{}, err
	}
	return e, nil
}

func (e Envelope) Decrypt(providerPrivateKey []byte) ([]byte, error) {
	if err := e.validateStructure(true); err != nil {
		return nil, err
	}
	privateKey, err := ecdh.X25519().NewPrivateKey(providerPrivateKey)
	if err != nil {
		return nil, fmt.Errorf("%w: provider private key", ErrInvalidEnvelope)
	}
	ephemeralBytes, _ := decodeBase64URLFixed(e.BuyerEphemeralPublicKey, 32)
	peer, err := ecdh.X25519().NewPublicKey(ephemeralBytes)
	if err != nil {
		return nil, fmt.Errorf("%w: buyer public key", ErrInvalidEnvelope)
	}
	aad, err := e.AAD()
	if err != nil {
		return nil, err
	}
	aead, nonce, err := deriveAEAD(privateKey, peer, aad)
	if err != nil {
		return nil, err
	}
	ciphertext, _ := decodeBase64URL(e.Ciphertext)
	tag, _ := decodeBase64URLFixed(e.Tag, aead.Overhead())
	sealed := append(append([]byte(nil), ciphertext...), tag...)
	plaintext, err := aead.Open(nil, nonce, sealed, aad)
	if err != nil {
		return nil, fmt.Errorf("%w: authentication failed", ErrInvalidEnvelope)
	}
	return plaintext, nil
}

func deriveAEAD(privateKey *ecdh.PrivateKey, peer *ecdh.PublicKey, aad []byte) (cipher.AEAD, []byte, error) {
	shared, err := privateKey.ECDH(peer)
	if err != nil {
		return nil, nil, fmt.Errorf("%w: invalid X25519 peer", ErrInvalidEnvelope)
	}
	var zero [32]byte
	if len(shared) != len(zero) || subtle.ConstantTimeCompare(shared, zero[:]) == 1 {
		return nil, nil, fmt.Errorf("%w: all-zero X25519 shared secret", ErrInvalidEnvelope)
	}
	transcriptInput := append([]byte(transcriptDomain), aad...)
	transcript := sha256.Sum256(transcriptInput)
	key, err := hkdf.Key(sha256.New, shared, transcript[:], requestKeyInfo, 32)
	if err != nil {
		return nil, nil, err
	}
	nonce, err := hkdf.Key(sha256.New, shared, transcript[:], requestNonceInfo, 12)
	if err != nil {
		return nil, nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, err
	}
	return aead, nonce, nil
}

func (r KeyRecord) validateImmutable() error {
	if r.Algorithm != Algorithm || r.SignatureAlgorithm != SignatureAlgorithm || !validSortedModels(r.Models) || !validEndpointFamilies(r.EndpointFamilies) || r.MaxEncryptedRequestBytes == 0 || r.MaxEncryptedRequestBytes > MaxEncryptedRequestBytes {
		return ErrInvalidKeyRecord
	}
	if _, err := decodeBase64URLFixed(r.PublicKey, 32); err != nil {
		return ErrInvalidKeyRecord
	}
	if _, err := decodeBase64URLFixed(r.IdentityFingerprint, 32); err != nil {
		return ErrInvalidKeyRecord
	}
	return nil
}

func (r KeyRecord) validateStructure() error {
	if err := r.validateImmutable(); err != nil {
		return err
	}
	if r.NotBeforeUnix < 0 || r.ExpiresAtUnix <= r.NotBeforeUnix || r.ExpiresAtUnix-r.NotBeforeUnix > int64(MaxKeyLifetime/time.Second) {
		return ErrInvalidKeyRecord
	}
	immutable, _ := r.ImmutableFraming()
	kidDigest := sha256.Sum256(immutable)
	if r.KID != encodeBase64URL(kidDigest[:16]) {
		return ErrInvalidKeyRecord
	}
	digest, _ := r.Digest()
	if r.KeyRecordDigest != digest {
		return ErrInvalidKeyRecord
	}
	if _, err := decodeBase64URLFixed(r.Signature, ed25519.SignatureSize); err != nil {
		return ErrInvalidKeyRecord
	}
	return nil
}

func (p IdentityPin) validateStructure() error {
	if p.Version != PinVersion || !validSortedModels(p.Models) || !validEndpointFamilies(p.EndpointFamilies) || p.NotBeforeUnix < 0 || p.ExpiresAtUnix <= p.NotBeforeUnix {
		return ErrInvalidPin
	}
	pub, err := decodeBase64URLFixed(p.IdentityPublicKey, ed25519.PublicKeySize)
	if err != nil {
		return ErrInvalidPin
	}
	if _, err := decodeBase64URLFixed(p.Fingerprint, sha256.Size); err != nil {
		return ErrInvalidPin
	}
	digest := sha256.Sum256(pub)
	if subtle.ConstantTimeCompare([]byte(p.Fingerprint), []byte(encodeBase64URL(digest[:]))) != 1 {
		return ErrInvalidPin
	}
	return nil
}

func (e Envelope) validateStructure(requireCiphertext bool) error {
	if e.Version != EnvelopeVersion || e.Mode != ModeRequired || e.EndpointFamily != EndpointChatCompletions || e.Algorithm != Algorithm || !validModelID(e.Model) || !validModelID(e.ProviderModel) || !visibleASCII(e.RequestID, MaxIdentifierBytes) || e.IssuedAtUnix < 0 {
		return ErrInvalidEnvelope
	}
	cap, err := checkedTokenCap(e.InputTokenUpperBound, e.MaxOutputTokens)
	if err != nil || cap != e.ReservationTokenCap {
		return ErrInvalidEnvelope
	}
	for _, value := range []string{e.ProviderBinding, e.BuyerBinding, e.KeyRecordDigest} {
		if _, err := decodeBase64URLFixed(value, 32); err != nil {
			return ErrInvalidEnvelope
		}
	}
	if _, err := decodeBase64URLFixed(e.KID, 16); err != nil {
		return ErrInvalidEnvelope
	}
	if _, err := decodeBase64URLFixed(e.BuyerEphemeralPublicKey, 32); err != nil {
		return ErrInvalidEnvelope
	}
	if _, err := decodeBase64URLFixed(e.RequestReplayNonce, 32); err != nil {
		return ErrInvalidEnvelope
	}
	if requireCiphertext {
		ciphertext, err := decodeBase64URL(e.Ciphertext)
		if err != nil || len(ciphertext) == 0 || len(ciphertext) > MaxEncryptedRequestBytes {
			return ErrInvalidEnvelope
		}
		if _, err := decodeBase64URLFixed(e.Tag, 16); err != nil {
			return ErrInvalidEnvelope
		}
	}
	return nil
}

func encodeBase64URL(value []byte) string {
	return base64.RawURLEncoding.EncodeToString(value)
}

func decodeBase64URL(value string) ([]byte, error) {
	if value == "" || bytes.ContainsAny([]byte(value), "= \t\r\n") {
		return nil, errors.New("noncanonical base64url")
	}
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(value)
	if err != nil || encodeBase64URL(decoded) != value {
		return nil, errors.New("noncanonical base64url")
	}
	return decoded, nil
}

func decodeBase64URLFixed(value string, size int) ([]byte, error) {
	decoded, err := decodeBase64URL(value)
	if err != nil || len(decoded) != size {
		return nil, errors.New("invalid base64url length")
	}
	return decoded, nil
}

func writeFrame(dst *bytes.Buffer, value []byte) error {
	if uint64(len(value)) > uint64(^uint32(0)) {
		return errors.New("frame too large")
	}
	var size [4]byte
	binary.BigEndian.PutUint32(size[:], uint32(len(value)))
	dst.Write(size[:])
	dst.Write(value)
	return nil
}

func writeArray(dst *bytes.Buffer, values []string) error {
	if uint64(len(values)) > uint64(^uint32(0)) {
		return errors.New("array too large")
	}
	var count [4]byte
	binary.BigEndian.PutUint32(count[:], uint32(len(values)))
	dst.Write(count[:])
	for _, value := range values {
		if err := writeFrame(dst, []byte(value)); err != nil {
			return err
		}
	}
	return nil
}

func writeU64(dst *bytes.Buffer, value uint64) {
	var framed [8]byte
	binary.BigEndian.PutUint64(framed[:], value)
	dst.Write(framed[:])
}

func writeI64(dst *bytes.Buffer, value int64) {
	writeU64(dst, uint64(value))
}
