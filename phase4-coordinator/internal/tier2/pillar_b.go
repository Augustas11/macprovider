package tier2

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"

	"github.com/rs/zerolog"
)

const (
	PillarBAEADA256GCM = "A256GCM"
)

var (
	pillarBTranscriptPrefix = []byte("macprovider/spec008/pillar-b/transcript/v1")
	pillarBAADPrefix        = []byte("macprovider/spec008/pillar-b/aad/v1\x00")
)

type PillarBKeyMaterial struct {
	AEADSuite    string
	KeyID        string
	C2PKey       []byte
	P2CKey       []byte
	C2PNonceBase []byte
	P2CNonceBase []byte
	Transcript   []byte
}

type AEADEnvelope struct {
	Encrypted bool             `json:"encrypted"`
	Enc       AEADEnvelopeBody `json:"enc"`
}

type AEADEnvelopeBody struct {
	Alg        string `json:"alg"`
	Seq        uint64 `json:"seq"`
	Nonce      string `json:"nonce"`
	AAD        string `json:"aad"`
	Ciphertext string `json:"ciphertext"`
	Tag        string `json:"tag"`
	KID        string `json:"kid"`
}

type AEADFrameAAD struct {
	Type       string `json:"type"`
	Direction  string `json:"direction"`
	RequestID  string `json:"request_id"`
	Stream     bool   `json:"stream"`
	ProviderID string `json:"provider_id"`
	AssignedID string `json:"assigned_id"`
	Seq        uint64 `json:"seq"`
}

func NewX25519Keypair() (*ecdh.PrivateKey, []byte, error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	return priv, append([]byte(nil), priv.PublicKey().Bytes()...), nil
}

func ParseX25519PublicKey(raw string) (*ecdh.PublicKey, []byte, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, nil, fmt.Errorf("invalid X25519 public key encoding: %w", err)
	}
	if len(decoded) != 32 {
		return nil, nil, fmt.Errorf("X25519 public key must be 32 bytes")
	}
	pub, err := ecdh.X25519().NewPublicKey(decoded)
	if err != nil {
		return nil, nil, err
	}
	return pub, decoded, nil
}

func DerivePillarBKeys(coordinatorPrivate *ecdh.PrivateKey, providerPublic *ecdh.PublicKey, providerID, assignedID, selectedAEAD string) (PillarBKeyMaterial, error) {
	if selectedAEAD != PillarBAEADA256GCM {
		return PillarBKeyMaterial{}, fmt.Errorf("unsupported AEAD suite %q", selectedAEAD)
	}
	shared, err := coordinatorPrivate.ECDH(providerPublic)
	if err != nil {
		return PillarBKeyMaterial{}, err
	}
	return DerivePillarBKeysFromSharedSecret(shared, providerID, assignedID, providerPublic.Bytes(), coordinatorPrivate.PublicKey().Bytes(), selectedAEAD)
}

func DerivePillarBKeysFromSharedSecret(sharedSecret []byte, providerID, assignedID string, providerPublic, coordinatorPublic []byte, selectedAEAD string) (PillarBKeyMaterial, error) {
	if selectedAEAD != PillarBAEADA256GCM {
		return PillarBKeyMaterial{}, fmt.Errorf("unsupported AEAD suite %q", selectedAEAD)
	}
	if len(sharedSecret) != 32 || len(providerPublic) != 32 || len(coordinatorPublic) != 32 {
		return PillarBKeyMaterial{}, fmt.Errorf("pillar B key derivation requires 32-byte shared/public keys")
	}
	transcriptHash := sha256.New()
	transcriptHash.Write(pillarBTranscriptPrefix)
	writeTranscriptField(transcriptHash, "provider_id", []byte(providerID))
	writeTranscriptField(transcriptHash, "assigned_id", []byte(assignedID))
	writeTranscriptField(transcriptHash, "provider_public", providerPublic)
	writeTranscriptField(transcriptHash, "coordinator_public", coordinatorPublic)
	writeTranscriptField(transcriptHash, "selected_aead", []byte(selectedAEAD))
	transcript := transcriptHash.Sum(nil)
	prk := hkdfExtract(transcript, sharedSecret)
	keyHash := sha256.Sum256(transcript)
	return PillarBKeyMaterial{
		AEADSuite:    selectedAEAD,
		KeyID:        base64.RawURLEncoding.EncodeToString(keyHash[:16]),
		C2PKey:       hkdfExpand(prk, []byte("macprovider/spec008/c2p/aead/v1"), 32),
		P2CKey:       hkdfExpand(prk, []byte("macprovider/spec008/p2c/aead/v1"), 32),
		C2PNonceBase: hkdfExpand(prk, []byte("macprovider/spec008/c2p/nonce/v1"), 4),
		P2CNonceBase: hkdfExpand(prk, []byte("macprovider/spec008/p2c/nonce/v1"), 4),
		Transcript:   transcript,
	}, nil
}

func MarshalAEADAAD(aad AEADFrameAAD) ([]byte, error) {
	buf := bytes.NewBuffer(make([]byte, 0, len(pillarBAADPrefix)+len(aad.Type)+len(aad.Direction)+len(aad.RequestID)+len(aad.ProviderID)+len(aad.AssignedID)+29))
	buf.Write(pillarBAADPrefix)
	if err := writeAADString(buf, aad.Type); err != nil {
		return nil, err
	}
	if err := writeAADString(buf, aad.Direction); err != nil {
		return nil, err
	}
	if err := writeAADString(buf, aad.RequestID); err != nil {
		return nil, err
	}
	if aad.Stream {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	if err := writeAADString(buf, aad.ProviderID); err != nil {
		return nil, err
	}
	if err := writeAADString(buf, aad.AssignedID); err != nil {
		return nil, err
	}
	var seq [8]byte
	binary.BigEndian.PutUint64(seq[:], aad.Seq)
	buf.Write(seq[:])
	return buf.Bytes(), nil
}

func DecodeAEADAAD(encoded string) (AEADFrameAAD, []byte, error) {
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return AEADFrameAAD{}, nil, fmt.Errorf("invalid pillar B AAD: %w", err)
	}
	if bytes.HasPrefix(raw, pillarBAADPrefix) {
		aad, err := parseBinaryAEADAAD(raw)
		if err != nil {
			return AEADFrameAAD{}, nil, err
		}
		return aad, raw, nil
	}
	var aad AEADFrameAAD
	if err := json.Unmarshal(raw, &aad); err != nil {
		return AEADFrameAAD{}, nil, fmt.Errorf("invalid pillar B AAD JSON: %w", err)
	}
	return aad, raw, nil
}

func writeAADString(w io.Writer, value string) error {
	if len(value) > int(^uint32(0)) {
		return fmt.Errorf("pillar B AAD field too large")
	}
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(value)))
	if _, err := w.Write(length[:]); err != nil {
		return err
	}
	_, err := io.WriteString(w, value)
	return err
}

func parseBinaryAEADAAD(raw []byte) (AEADFrameAAD, error) {
	reader := bytes.NewReader(raw[len(pillarBAADPrefix):])
	readString := func(name string) (string, error) {
		var length uint32
		if err := binary.Read(reader, binary.BigEndian, &length); err != nil {
			return "", fmt.Errorf("invalid pillar B AAD %s length: %w", name, err)
		}
		if uint64(length) > uint64(reader.Len()) {
			return "", fmt.Errorf("invalid pillar B AAD %s length", name)
		}
		value := make([]byte, length)
		if _, err := io.ReadFull(reader, value); err != nil {
			return "", fmt.Errorf("invalid pillar B AAD %s: %w", name, err)
		}
		return string(value), nil
	}
	var aad AEADFrameAAD
	var err error
	if aad.Type, err = readString("type"); err != nil {
		return AEADFrameAAD{}, err
	}
	if aad.Direction, err = readString("direction"); err != nil {
		return AEADFrameAAD{}, err
	}
	if aad.RequestID, err = readString("request_id"); err != nil {
		return AEADFrameAAD{}, err
	}
	streamFlag, err := reader.ReadByte()
	if err != nil {
		return AEADFrameAAD{}, fmt.Errorf("invalid pillar B AAD stream: %w", err)
	}
	switch streamFlag {
	case 0:
		aad.Stream = false
	case 1:
		aad.Stream = true
	default:
		return AEADFrameAAD{}, fmt.Errorf("invalid pillar B AAD stream flag")
	}
	if aad.ProviderID, err = readString("provider_id"); err != nil {
		return AEADFrameAAD{}, err
	}
	if aad.AssignedID, err = readString("assigned_id"); err != nil {
		return AEADFrameAAD{}, err
	}
	if reader.Len() < 8 {
		return AEADFrameAAD{}, fmt.Errorf("invalid pillar B AAD seq")
	}
	var seq [8]byte
	if _, err := io.ReadFull(reader, seq[:]); err != nil {
		return AEADFrameAAD{}, fmt.Errorf("invalid pillar B AAD seq: %w", err)
	}
	aad.Seq = binary.BigEndian.Uint64(seq[:])
	if reader.Len() != 0 {
		return AEADFrameAAD{}, fmt.Errorf("invalid pillar B AAD trailing data")
	}
	return aad, nil
}

func SealPillarBFrame(key, nonceBase []byte, keyID string, seq uint64, aad AEADFrameAAD, plaintext []byte) (AEADEnvelope, error) {
	if aad.Seq != seq {
		return AEADEnvelope{}, fmt.Errorf("AAD seq does not match frame seq")
	}
	nonce, err := pillarBNonce(nonceBase, seq)
	if err != nil {
		return AEADEnvelope{}, err
	}
	aadRaw, err := MarshalAEADAAD(aad)
	if err != nil {
		return AEADEnvelope{}, err
	}
	gcm, err := newA256GCM(key)
	if err != nil {
		return AEADEnvelope{}, err
	}
	sealed := gcm.Seal(nil, nonce, plaintext, aadRaw)
	tagStart := len(sealed) - gcm.Overhead()
	return AEADEnvelope{
		Encrypted: true,
		Enc: AEADEnvelopeBody{
			Alg:        PillarBAEADA256GCM,
			Seq:        seq,
			Nonce:      base64.RawURLEncoding.EncodeToString(nonce),
			AAD:        base64.RawURLEncoding.EncodeToString(aadRaw),
			Ciphertext: base64.RawURLEncoding.EncodeToString(sealed[:tagStart]),
			Tag:        base64.RawURLEncoding.EncodeToString(sealed[tagStart:]),
			KID:        keyID,
		},
	}, nil
}

func OpenPillarBFrame(key, nonceBase []byte, keyID string, expectedSeq uint64, expectedAAD AEADFrameAAD, envelope AEADEnvelope) ([]byte, error) {
	if !envelope.Encrypted {
		return nil, fmt.Errorf("frame is not encrypted")
	}
	if envelope.Enc.Alg != PillarBAEADA256GCM {
		return nil, fmt.Errorf("pillar B unsupported AEAD algorithm")
	}
	if envelope.Enc.KID != keyID {
		return nil, fmt.Errorf("pillar B key id mismatch")
	}
	if envelope.Enc.Seq != expectedSeq {
		return nil, fmt.Errorf("pillar B sequence mismatch")
	}
	expectedNonce, err := pillarBNonce(nonceBase, expectedSeq)
	if err != nil {
		return nil, err
	}
	nonce, err := base64.RawURLEncoding.DecodeString(envelope.Enc.Nonce)
	if err != nil {
		return nil, fmt.Errorf("invalid pillar B nonce: %w", err)
	}
	if !bytes.Equal(nonce, expectedNonce) {
		return nil, fmt.Errorf("pillar B nonce mismatch")
	}
	expectedAAD.Seq = expectedSeq
	expectedAADRaw, err := MarshalAEADAAD(expectedAAD)
	if err != nil {
		return nil, err
	}
	decodedAAD, aadRaw, err := DecodeAEADAAD(envelope.Enc.AAD)
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(aadRaw, expectedAADRaw) {
		if bytes.HasPrefix(aadRaw, pillarBAADPrefix) || decodedAAD != expectedAAD {
			return nil, fmt.Errorf("pillar B AAD mismatch")
		}
	}
	ciphertext, err := base64.RawURLEncoding.DecodeString(envelope.Enc.Ciphertext)
	if err != nil {
		return nil, fmt.Errorf("invalid pillar B ciphertext: %w", err)
	}
	tag, err := base64.RawURLEncoding.DecodeString(envelope.Enc.Tag)
	if err != nil {
		return nil, fmt.Errorf("invalid pillar B tag: %w", err)
	}
	gcm, err := newA256GCM(key)
	if err != nil {
		return nil, err
	}
	sealed := append(ciphertext, tag...)
	return gcm.Open(nil, nonce, sealed, aadRaw)
}

func LogEncryptedLegRequiredMissing(logger zerolog.Logger, providerID, assignedID, modelID string) {
	logger.Warn().
		Str("event", "encrypted_leg_required_missing").
		Str("category", "T2.B").
		Str("severity", "WARN").
		Str("provider_id", providerID).
		Str("assigned_id", assignedID).
		Str("model_id", modelID).
		Str("pillar", "B").
		Str("decision", "reject").
		Str("reason", "encrypted_leg_required_missing").
		Str("config_flag", "tier2.require_encrypted_leg").
		Msg("tier2 encrypted leg required provider excluded")
}

func LogAEADDecryptFailed(logger zerolog.Logger, providerID, assignedID, requestID, reason string) {
	logger.Error().
		Str("event", "aead_decrypt_failed").
		Str("category", "T2.B").
		Str("severity", "MAJOR").
		Str("provider_id", providerID).
		Str("assigned_id", assignedID).
		Str("request_id", requestID).
		Str("pillar", "B").
		Str("decision", "reject").
		Str("reason", reason).
		Msg("tier2 encrypted leg AEAD decrypt failed")
}

func LogEncryptedLegSessionClosed(logger zerolog.Logger, providerID, assignedID, requestID, reason string) {
	logger.Warn().
		Str("event", "encrypted_leg_session_closed").
		Str("category", "T2.B").
		Str("severity", "WARN").
		Str("provider_id", providerID).
		Str("assigned_id", assignedID).
		Str("request_id", requestID).
		Str("pillar", "B").
		Str("decision", "close").
		Str("reason", reason).
		Msg("tier2 encrypted leg session closed")
}

func LogAEADRekey(logger zerolog.Logger, providerID, assignedID, requestID, reason string) {
	configFlag := "tier2.encrypted_leg_rekey_after_requests"
	if reason == "age_threshold" {
		configFlag = "tier2.encrypted_leg_rekey_after_seconds"
	}
	logger.Info().
		Str("event", "aead_rekey").
		Str("category", "T2.B").
		Str("severity", "INFO").
		Str("provider_id", providerID).
		Str("assigned_id", assignedID).
		Str("request_id", requestID).
		Str("pillar", "B").
		Str("decision", "close").
		Str("reason", reason).
		Str("config_flag", configFlag).
		Msg("tier2 encrypted leg session rekeyed")
}

func newA256GCM(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("A256GCM key must be 32 bytes")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func pillarBNonce(nonceBase []byte, seq uint64) ([]byte, error) {
	if len(nonceBase) != 4 {
		return nil, fmt.Errorf("pillar B nonce base must be 4 bytes")
	}
	nonce := make([]byte, 12)
	copy(nonce[:4], nonceBase)
	binary.BigEndian.PutUint64(nonce[4:], seq)
	return nonce, nil
}

func writeTranscriptField(w io.Writer, label string, value []byte) {
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(label)))
	w.Write(lenBuf[:])
	w.Write([]byte(label))
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(value)))
	w.Write(lenBuf[:])
	w.Write(value)
}

func hkdfExtract(salt, ikm []byte) []byte {
	h := hmac.New(sha256.New, salt)
	h.Write(ikm)
	return h.Sum(nil)
}

func hkdfExpand(prk, info []byte, length int) []byte {
	hashLen := sha256.Size
	if length <= 0 || length > 255*hashLen {
		panic("invalid HKDF output length")
	}
	var out []byte
	var previous []byte
	counter := byte(1)
	for len(out) < length {
		h := hmac.New(sha256.New, prk)
		h.Write(previous)
		h.Write(info)
		h.Write([]byte{counter})
		previous = h.Sum(nil)
		out = append(out, previous...)
		counter++
	}
	return out[:length]
}

func randomBytes(n int, reader io.Reader) ([]byte, error) {
	if reader == nil {
		reader = rand.Reader
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(reader, b); err != nil {
		return nil, err
	}
	return b, nil
}
