package integration

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
	"net"
)

// Wire-only SPEC-008 client: fixture keys remain in RAM; no service internals
// are imported. This prevents a mocked probe from bypassing the actual relay.
type build1CipherState struct {
	c2pKey          []byte
	c2pSequence     uint64
	key             []byte
	nonceBase       []byte
	kid, assignedID string
	seq             uint64
}

func makeBuild1Cipher(private *ecdh.PrivateKey, providerID string, raw []byte) (*build1CipherState, error) {
	var challenge struct {
		AssignedID string `json:"assigned_id"`
		Public     string `json:"coordinator_ecdh_public_key"`
	}
	if err := json.Unmarshal(raw, &challenge); err != nil {
		return nil, err
	}
	publicBytes, err := base64.RawURLEncoding.DecodeString(challenge.Public)
	if err != nil {
		return nil, err
	}
	public, err := ecdh.X25519().NewPublicKey(publicBytes)
	if err != nil {
		return nil, err
	}
	shared, err := private.ECDH(public)
	if err != nil {
		return nil, err
	}
	h := sha256.New()
	h.Write([]byte("macprovider/spec008/pillar-b/transcript/v1"))
	fields := []struct {
		label string
		value []byte
	}{{"provider_id", []byte(providerID)}, {"assigned_id", []byte(challenge.AssignedID)}, {"provider_public", private.PublicKey().Bytes()}, {"coordinator_public", publicBytes}, {"selected_aead", []byte("A256GCM")}}
	for _, field := range fields {
		_ = binary.Write(h, binary.BigEndian, uint32(len(field.label)))
		h.Write([]byte(field.label))
		_ = binary.Write(h, binary.BigEndian, uint32(len(field.value)))
		h.Write(field.value)
	}
	transcript := h.Sum(nil)
	extract := hmac.New(sha256.New, transcript)
	extract.Write(shared)
	prk := extract.Sum(nil)
	expand := func(info string, n int) []byte {
		h := hmac.New(sha256.New, prk)
		h.Write([]byte(info))
		h.Write([]byte{1})
		return h.Sum(nil)[:n]
	}
	kid := sha256.Sum256(transcript)
	return &build1CipherState{c2pKey: expand("macprovider/spec008/c2p/aead/v1", 32), key: expand("macprovider/spec008/p2c/aead/v1", 32), nonceBase: expand("macprovider/spec008/p2c/nonce/v1", 4), kid: base64.RawURLEncoding.EncodeToString(kid[:16]), assignedID: challenge.AssignedID}, nil
}
func (p *fakeProvider) writeBuild1Encrypted(conn net.Conn, kind, requestID string, plain []byte) error {
	c := p.build1Cipher
	if c == nil {
		return fmt.Errorf("fixture encrypted session missing")
	}
	seq := c.seq
	c.seq++
	aad := bytes.NewBufferString("macprovider/spec008/pillar-b/aad/v1\x00")
	put := func(s string) { _ = binary.Write(aad, binary.BigEndian, uint32(len(s))); aad.WriteString(s) }
	put(kind)
	put("p2c")
	put(requestID)
	aad.WriteByte(0)
	put(p.providerID)
	put(c.assignedID)
	_ = binary.Write(aad, binary.BigEndian, seq)
	nonce := make([]byte, 12)
	copy(nonce, c.nonceBase)
	binary.BigEndian.PutUint64(nonce[4:], seq)
	block, err := aes.NewCipher(c.key)
	if err != nil {
		return err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return err
	}
	sealed := gcm.Seal(nil, nonce, plain, aad.Bytes())
	enc := base64.RawURLEncoding.EncodeToString
	return writeJSONFrame(conn, map[string]any{"type": kind, "request_id": requestID, "encrypted": true, "enc": map[string]any{"alg": "A256GCM", "seq": seq, "nonce": enc(nonce), "aad": enc(aad.Bytes()), "ciphertext": enc(sealed[:len(sealed)-16]), "tag": enc(sealed[len(sealed)-16:]), "kid": c.kid}})
}

func (p *fakeProvider) openBuild1Request(raw []byte) (string, error) {
	var env struct {
		Encrypted bool `json:"encrypted"`
		Enc       struct {
			Seq        uint64 `json:"seq"`
			Nonce      string `json:"nonce"`
			AAD        string `json:"aad"`
			Ciphertext string `json:"ciphertext"`
			Tag        string `json:"tag"`
			KID        string `json:"kid"`
		} `json:"enc"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return "", err
	}
	c := p.build1Cipher
	if !env.Encrypted || env.Enc.Seq != c.c2pSequence || env.Enc.KID != c.kid {
		return "", fmt.Errorf("invalid fixture c2p encrypted envelope")
	}
	dec := base64.RawURLEncoding.DecodeString
	nonce, err := dec(env.Enc.Nonce)
	if err != nil {
		return "", err
	}
	aad, err := dec(env.Enc.AAD)
	if err != nil {
		return "", err
	}
	data, err := dec(env.Enc.Ciphertext)
	if err != nil {
		return "", err
	}
	tag, err := dec(env.Enc.Tag)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(c.c2pKey)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	plain, err := gcm.Open(nil, nonce, append(data, tag...), aad)
	if err != nil {
		return "", err
	}
	var req struct {
		Type string `json:"type"`
		Body string `json:"body"`
	}
	if err = json.Unmarshal(plain, &req); err != nil {
		return "", err
	}
	if req.Type != "inference_request_plaintext" {
		return "", fmt.Errorf("unexpected fixture plaintext type")
	}
	c.c2pSequence++
	return req.Body, nil
}
