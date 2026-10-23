package main

// #2084 (test/e2e-2084): the provider half of the SPEC-008 Pillar B encrypted
// leg, so a -ws-relay fake can serve inference over the WebSocket tunnel the
// way the real CLI does. Every v2 session negotiates it (the coordinator
// refuses a session without an AEAD suite), and once negotiated every
// tunnelled inference_request arrives sealed and every response frame must be
// sealed. Byte-for-byte the coordinator's internal/tier2 Pillar B (transcript,
// HKDF, A256GCM, binary AAD), re-implemented here because that package is
// internal to the coordinator module.

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"sync"
)

const tier2AEAD = "A256GCM"

var (
	tier2TranscriptPrefix = []byte("macprovider/spec008/pillar-b/transcript/v1")
	tier2AADPrefix        = []byte("macprovider/spec008/pillar-b/aad/v1\x00")
)

type tier2Session struct {
	mu           sync.Mutex
	providerID   string
	assignedID   string
	keyID        string
	c2pKey       []byte
	p2cKey       []byte
	c2pNonceBase []byte
	p2cNonceBase []byte
	p2cCounter   uint64
}

type tier2Envelope struct {
	Alg        string `json:"alg"`
	Seq        uint64 `json:"seq"`
	Nonce      string `json:"nonce"`
	AAD        string `json:"aad"`
	Ciphertext string `json:"ciphertext"`
	Tag        string `json:"tag"`
	KID        string `json:"kid"`
}

func tier2TranscriptField(w *bytes.Buffer, label string, value []byte) {
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(len(label)))
	w.Write(n[:])
	w.WriteString(label)
	binary.BigEndian.PutUint32(n[:], uint32(len(value)))
	w.Write(n[:])
	w.Write(value)
}

func tier2HKDFExpand(prk, info []byte, length int) []byte {
	var out, previous []byte
	for counter := byte(1); len(out) < length; counter++ {
		h := hmac.New(sha256.New, prk)
		h.Write(previous)
		h.Write(info)
		h.Write([]byte{counter})
		previous = h.Sum(nil)
		out = append(out, previous...)
	}
	return out[:length]
}

// newTier2Session derives the session keys from the provider's X25519 key and
// the coordinator's public key from auth_challenge.
func newTier2Session(priv *ecdh.PrivateKey, coordinatorPublicB64, providerID, assignedID string) (*tier2Session, error) {
	raw, err := base64.RawURLEncoding.DecodeString(coordinatorPublicB64)
	if err != nil || len(raw) != 32 {
		return nil, fmt.Errorf("coordinator ECDH public key: %v", err)
	}
	pub, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return nil, err
	}
	shared, err := priv.ECDH(pub)
	if err != nil {
		return nil, err
	}
	var t bytes.Buffer
	t.Write(tier2TranscriptPrefix)
	tier2TranscriptField(&t, "provider_id", []byte(providerID))
	tier2TranscriptField(&t, "assigned_id", []byte(assignedID))
	tier2TranscriptField(&t, "provider_public", priv.PublicKey().Bytes())
	tier2TranscriptField(&t, "coordinator_public", raw)
	tier2TranscriptField(&t, "selected_aead", []byte(tier2AEAD))
	transcript := sha256.Sum256(t.Bytes())
	mac := hmac.New(sha256.New, transcript[:])
	mac.Write(shared)
	prk := mac.Sum(nil)
	keyHash := sha256.Sum256(transcript[:])
	return &tier2Session{
		providerID: providerID, assignedID: assignedID,
		keyID:        base64.RawURLEncoding.EncodeToString(keyHash[:16]),
		c2pKey:       tier2HKDFExpand(prk, []byte("macprovider/spec008/c2p/aead/v1"), 32),
		p2cKey:       tier2HKDFExpand(prk, []byte("macprovider/spec008/p2c/aead/v1"), 32),
		c2pNonceBase: tier2HKDFExpand(prk, []byte("macprovider/spec008/c2p/nonce/v1"), 4),
		p2cNonceBase: tier2HKDFExpand(prk, []byte("macprovider/spec008/p2c/nonce/v1"), 4),
	}, nil
}

func tier2AAD(typ, direction, requestID string, stream bool, providerID, assignedID string, seq uint64) []byte {
	var b bytes.Buffer
	b.Write(tier2AADPrefix)
	str := func(s string) {
		var n [4]byte
		binary.BigEndian.PutUint32(n[:], uint32(len(s)))
		b.Write(n[:])
		b.WriteString(s)
	}
	str(typ)
	str(direction)
	str(requestID)
	if stream {
		b.WriteByte(1)
	} else {
		b.WriteByte(0)
	}
	str(providerID)
	str(assignedID)
	var s [8]byte
	binary.BigEndian.PutUint64(s[:], seq)
	b.Write(s[:])
	return b.Bytes()
}

func tier2GCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func tier2Nonce(base []byte, seq uint64) []byte {
	nonce := make([]byte, 12)
	copy(nonce[:4], base)
	binary.BigEndian.PutUint64(nonce[4:], seq)
	return nonce
}

// open decrypts a coordinator-to-provider frame of the given type.
func (s *tier2Session) open(typ, requestID string, stream bool, env tier2Envelope) ([]byte, error) {
	aad := tier2AAD(typ, "c2p", requestID, stream, s.providerID, s.assignedID, env.Seq)
	ct, err := base64.RawURLEncoding.DecodeString(env.Ciphertext)
	if err != nil {
		return nil, err
	}
	tag, err := base64.RawURLEncoding.DecodeString(env.Tag)
	if err != nil {
		return nil, err
	}
	gcm, err := tier2GCM(s.c2pKey)
	if err != nil {
		return nil, err
	}
	return gcm.Open(nil, tier2Nonce(s.c2pNonceBase, env.Seq), append(ct, tag...), aad)
}

// seal encrypts one provider-to-coordinator frame and returns the wire frame.
func (s *tier2Session) seal(typ, requestID string, stream bool, plaintext []byte) (map[string]any, error) {
	s.mu.Lock()
	seq := s.p2cCounter
	s.p2cCounter++
	s.mu.Unlock()
	aad := tier2AAD(typ, "p2c", requestID, stream, s.providerID, s.assignedID, seq)
	gcm, err := tier2GCM(s.p2cKey)
	if err != nil {
		return nil, err
	}
	nonce := tier2Nonce(s.p2cNonceBase, seq)
	sealed := gcm.Seal(nil, nonce, plaintext, aad)
	cut := len(sealed) - gcm.Overhead()
	return map[string]any{"type": typ, "request_id": requestID, "encrypted": true, "enc": tier2Envelope{
		Alg: tier2AEAD, Seq: seq, Nonce: base64.RawURLEncoding.EncodeToString(nonce), AAD: base64.RawURLEncoding.EncodeToString(aad),
		Ciphertext: base64.RawURLEncoding.EncodeToString(sealed[:cut]), Tag: base64.RawURLEncoding.EncodeToString(sealed[cut:]), KID: s.keyID,
	}}, nil
}

// sealedSender wraps a session's frame sender: inference response chunks and
// terminals are sealed (chunks in the response_chunk_plaintext_envelope
// form), everything else is sent as is.
func (p *fakeProvider) sealedSender(send func(map[string]any) error, stream bool) func(map[string]any) error {
	t := p.currentTier2()
	if t == nil {
		return send
	}
	return func(frame map[string]any) error {
		typ, _ := frame["type"].(string)
		rid, _ := frame["request_id"].(string)
		var plaintext []byte
		var err error
		switch typ {
		case "inference_response_chunk":
			plaintext, err = json.Marshal(map[string]any{"type": "inference_response_chunk_plaintext", "seq": frame["seq"], "data": frame["data"]})
		case "inference_response_end":
			plaintext, err = json.Marshal(frame)
		default:
			return send(frame)
		}
		if err != nil {
			return err
		}
		sealed, err := t.seal(typ, rid, stream, plaintext)
		if err != nil {
			return err
		}
		return send(sealed)
	}
}

func (p *fakeProvider) currentTier2() *tier2Session {
	p.tier2Mu.Lock()
	defer p.tier2Mu.Unlock()
	return p.tier2
}

func (p *fakeProvider) setTier2(t *tier2Session) {
	p.tier2Mu.Lock()
	p.tier2 = t
	p.tier2Mu.Unlock()
}
