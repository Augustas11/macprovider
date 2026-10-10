package appattest

import (
	"bytes"
	"testing"
)

func TestCBORDecodesAppAttestShapes(t *testing.T) {
	// {1:2, 3:-7, -1:1, -2:h'0102', "fmt":"apple-appattest"}
	raw := []byte{0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x42, 0x01, 0x02, 0x63, 'f', 'm', 't', 0x6f}
	raw = append(raw, "apple-appattest"...)
	value, err := decodeCBOR(raw)
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := value.intKey(3); !ok || v.Kind != kindNeg || v.Neg != -7 {
		t.Fatalf("alg %#v", v)
	}
	if v, ok := value.intKey(-2); !ok || !bytes.Equal(v.Bytes, []byte{1, 2}) {
		t.Fatalf("x %#v", v)
	}
	if v, ok := value.textKey("fmt"); !ok || v.Text != AttestationFormat {
		t.Fatalf("fmt %#v", v)
	}
	if value.onlyTextKeys("fmt") {
		t.Fatal("onlyTextKeys ignored integer keys")
	}
	// Multi-byte lengths.
	long := append([]byte{0x59, 0x01, 0x00}, make([]byte, 256)...)
	if v, err := decodeCBOR(long); err != nil || len(v.Bytes) != 256 {
		t.Fatalf("256-byte string: %v", err)
	}
}

func TestCBORRejectsUnsupportedAndMalformed(t *testing.T) {
	cases := map[string][]byte{
		"empty":                  nil,
		"indefinite bytes":       {0x5f},
		"indefinite text":        {0x7f},
		"indefinite array":       {0x9f},
		"indefinite map":         {0xbf},
		"reserved info":          {0x1c},
		"tag":                    {0xc0, 0x01},
		"half float":             {0xf9, 0x00, 0x00},
		"single float":           {0xfa, 0x00, 0x00, 0x00, 0x00},
		"undefined":              {0xf7},
		"truncated bytes":        {0x41},
		"trailing":               {0x01, 0x02},
		"duplicate key":          {0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02},
		"array key":              {0xa1, 0x80, 0x01},
		"oversized array length": {0x98, 0xff},
		"length beyond input":    {0x5a, 0xff, 0xff, 0xff, 0xff},
		"negative overflow":      {0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
	}
	for name, input := range cases {
		if _, err := decodeCBOR(input); err == nil {
			t.Errorf("%s: accepted %x", name, input)
		}
	}
	nested := append(bytes.Repeat([]byte{0x81}, maxCBORDepth+1), 0x01)
	if _, err := decodeCBOR(nested); err == nil {
		t.Fatal("over-deep array accepted")
	}
	ok := append(bytes.Repeat([]byte{0x81}, maxCBORDepth), 0x01)
	if _, err := decodeCBOR(ok); err != nil {
		t.Fatalf("depth limit too strict: %v", err)
	}
	if _, err := decodeCBOR(make([]byte, maxCBORSize+1)); err == nil {
		t.Fatal("oversized input accepted")
	}
}

func TestCBORPrefixLeavesTheTail(t *testing.T) {
	value, n, err := decodeCBORPrefix([]byte{0x01, 0x02})
	if err != nil || n != 1 || value.Uint != 1 {
		t.Fatalf("prefix = %#v n=%d err=%v", value, n, err)
	}
}

func TestDERExtensionShapes(t *testing.T) {
	nonce := bytes.Repeat([]byte{0x5a}, 32)
	documented := append([]byte{0x30, 0x24, 0xa1, 0x22, 0x04, 0x20}, nonce...)
	got, err := nonceOctets(documented)
	if err != nil || !bytes.Equal(got, nonce) {
		t.Fatalf("nonce: %v", err)
	}
	for name, bad := range map[string][]byte{
		"tag 2":       append([]byte{0x30, 0x24, 0xa2, 0x22, 0x04, 0x20}, nonce...),
		"no wrapper":  append([]byte{0x30, 0x22, 0x04, 0x20}, nonce...),
		"trailing":    append(append([]byte{0x30, 0x24, 0xa1, 0x22, 0x04, 0x20}, nonce...), 0x00),
		"indefinite":  {0x30, 0x80, 0x00, 0x00},
		"non-minimal": append([]byte{0x30, 0x81, 0x24, 0xa1, 0x22, 0x04, 0x20}, nonce...),
	} {
		if _, err := nonceOctets(bad); err == nil {
			t.Errorf("nonce %s accepted", name)
		}
	}
	acl := RequiredACLBlob()
	direct := append([]byte{0x30, byte(len(acl) + 2), 0x04, byte(len(acl))}, acl...)
	wrapped := append([]byte{0x30, byte(len(acl) + 4), 0xa3, byte(len(acl) + 2), 0x04, byte(len(acl))}, acl...)
	for name, value := range map[string][]byte{"direct": direct, "wrapped": wrapped} {
		got, err := aclOctets(value)
		if err != nil || !bytes.Equal(got, acl) {
			t.Fatalf("acl %s: %v", name, err)
		}
	}
	two := append(append([]byte{0x30, byte(2*len(acl) + 4)}, append([]byte{0x04, byte(len(acl))}, acl...)...), append([]byte{0x04, byte(len(acl))}, acl...)...)
	if _, err := aclOctets(two); err == nil {
		t.Fatal("two-element aclBlob accepted")
	}
}
