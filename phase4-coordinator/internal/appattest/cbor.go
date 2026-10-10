package appattest

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

// Bounds for App Attest objects. An attestation is at most 16 KiB on the
// wire (SPEC-033 §5.7.1), so these leave headroom without allowing a
// provider to make the decoder allocate unboundedly.
const (
	maxCBORSize  = 64 << 10
	maxCBORDepth = 8
	maxCBORItems = 4096
	maxCBORPairs = 64
)

// cborKind is a CBOR major type this decoder accepts. Tags (major type 6),
// indefinite lengths, floats, and undefined are rejected; App Attest
// objects use none of them.
type cborKind uint8

const (
	kindUint cborKind = iota
	kindNeg
	kindBytes
	kindText
	kindArray
	kindMap
	kindBool
	kindNull
)

// cborValue is one definite-length CBOR item. Map keys keep their original
// type so a COSE key (integer keys, including negatives) can be read.
type cborValue struct {
	Kind  cborKind
	Uint  uint64
	Neg   int64
	Bytes []byte
	Text  string
	Array []cborValue
	Pairs []cborPair
	Bool  bool
}

type cborPair struct {
	Key cborValue
	Val cborValue
}

func (v cborValue) textKey(name string) (cborValue, bool) {
	for _, pair := range v.Pairs {
		if pair.Key.Kind == kindText && pair.Key.Text == name {
			return pair.Val, true
		}
	}
	return cborValue{}, false
}

func (v cborValue) intKey(key int64) (cborValue, bool) {
	for _, pair := range v.Pairs {
		switch pair.Key.Kind {
		case kindUint:
			if key >= 0 && pair.Key.Uint == uint64(key) {
				return pair.Val, true
			}
		case kindNeg:
			if pair.Key.Neg == key {
				return pair.Val, true
			}
		}
	}
	return cborValue{}, false
}

// onlyTextKeys reports whether a map has exactly the named text keys.
// Duplicates are already rejected by the decoder.
func (v cborValue) onlyTextKeys(names ...string) bool {
	if v.Kind != kindMap || len(v.Pairs) != len(names) {
		return false
	}
	for _, name := range names {
		if _, ok := v.textKey(name); !ok {
			return false
		}
	}
	return true
}

// decodeCBOR parses one CBOR value that occupies the entire buffer.
func decodeCBOR(data []byte) (cborValue, error) {
	value, n, err := decodeCBORPrefix(data)
	if err != nil {
		return cborValue{}, err
	}
	if n != len(data) {
		return cborValue{}, fmt.Errorf("cbor: %d trailing bytes", len(data)-n)
	}
	return value, nil
}

// decodeCBORPrefix parses one CBOR value and returns the bytes it consumed.
func decodeCBORPrefix(data []byte) (cborValue, int, error) {
	if len(data) > maxCBORSize {
		return cborValue{}, 0, fmt.Errorf("cbor: input exceeds %d bytes", maxCBORSize)
	}
	dec := &cborDecoder{data: data}
	value, err := dec.item(0)
	if err != nil {
		return cborValue{}, 0, err
	}
	return value, dec.off, nil
}

type cborDecoder struct {
	data  []byte
	off   int
	items int
}

func (d *cborDecoder) item(depth int) (cborValue, error) {
	if depth > maxCBORDepth {
		return cborValue{}, errors.New("cbor: max depth exceeded")
	}
	d.items++
	if d.items > maxCBORItems {
		return cborValue{}, errors.New("cbor: max item count exceeded")
	}
	if d.off >= len(d.data) {
		return cborValue{}, errors.New("cbor: truncated")
	}
	head := d.data[d.off]
	d.off++
	major := head >> 5
	arg, err := d.argument(head & 0x1f)
	if err != nil {
		return cborValue{}, err
	}
	switch major {
	case 0:
		return cborValue{Kind: kindUint, Uint: arg}, nil
	case 1:
		if arg > uint64(math.MaxInt64) {
			return cborValue{}, errors.New("cbor: negative integer overflows int64")
		}
		return cborValue{Kind: kindNeg, Neg: -1 - int64(arg)}, nil
	case 2:
		buf, err := d.take(arg)
		if err != nil {
			return cborValue{}, err
		}
		return cborValue{Kind: kindBytes, Bytes: append([]byte(nil), buf...)}, nil
	case 3:
		buf, err := d.take(arg)
		if err != nil {
			return cborValue{}, err
		}
		return cborValue{Kind: kindText, Text: string(buf)}, nil
	case 4:
		if arg > maxCBORPairs {
			return cborValue{}, fmt.Errorf("cbor: array length %d exceeds %d", arg, maxCBORPairs)
		}
		items := make([]cborValue, 0, arg)
		for i := uint64(0); i < arg; i++ {
			child, err := d.item(depth + 1)
			if err != nil {
				return cborValue{}, err
			}
			items = append(items, child)
		}
		return cborValue{Kind: kindArray, Array: items}, nil
	case 5:
		if arg > maxCBORPairs {
			return cborValue{}, fmt.Errorf("cbor: map length %d exceeds %d", arg, maxCBORPairs)
		}
		pairs := make([]cborPair, 0, arg)
		seen := make(map[string]struct{}, arg)
		for i := uint64(0); i < arg; i++ {
			key, err := d.item(depth + 1)
			if err != nil {
				return cborValue{}, err
			}
			val, err := d.item(depth + 1)
			if err != nil {
				return cborValue{}, err
			}
			mark, err := cborKeyIdentity(key)
			if err != nil {
				return cborValue{}, err
			}
			if _, ok := seen[mark]; ok {
				return cborValue{}, errors.New("cbor: duplicate map key")
			}
			seen[mark] = struct{}{}
			pairs = append(pairs, cborPair{Key: key, Val: val})
		}
		return cborValue{Kind: kindMap, Pairs: pairs}, nil
	case 7:
		return cborSimple(head)
	default:
		return cborValue{}, fmt.Errorf("cbor: unsupported major type %d", major)
	}
}

func cborSimple(head byte) (cborValue, error) {
	switch head & 0x1f {
	case 20:
		return cborValue{Kind: kindBool, Bool: false}, nil
	case 21:
		return cborValue{Kind: kindBool, Bool: true}, nil
	case 22:
		return cborValue{Kind: kindNull}, nil
	default:
		return cborValue{}, errors.New("cbor: unsupported simple or floating-point value")
	}
}

func (d *cborDecoder) argument(info byte) (uint64, error) {
	switch {
	case info < 24:
		return uint64(info), nil
	case info == 24:
		buf, err := d.take(1)
		if err != nil {
			return 0, err
		}
		return uint64(buf[0]), nil
	case info == 25:
		buf, err := d.take(2)
		if err != nil {
			return 0, err
		}
		return uint64(binary.BigEndian.Uint16(buf)), nil
	case info == 26:
		buf, err := d.take(4)
		if err != nil {
			return 0, err
		}
		return uint64(binary.BigEndian.Uint32(buf)), nil
	case info == 27:
		buf, err := d.take(8)
		if err != nil {
			return 0, err
		}
		return binary.BigEndian.Uint64(buf), nil
	case info == 31:
		return 0, errors.New("cbor: indefinite length is rejected")
	default:
		return 0, fmt.Errorf("cbor: reserved additional info %d", info)
	}
}

func (d *cborDecoder) take(n uint64) ([]byte, error) {
	if n > uint64(len(d.data)-d.off) {
		return nil, errors.New("cbor: truncated")
	}
	start := d.off
	d.off += int(n)
	return d.data[start:d.off], nil
}

func cborKeyIdentity(key cborValue) (string, error) {
	switch key.Kind {
	case kindUint:
		return fmt.Sprintf("u:%d", key.Uint), nil
	case kindNeg:
		return fmt.Sprintf("n:%d", key.Neg), nil
	case kindText:
		return "t:" + key.Text, nil
	case kindBytes:
		return "b:" + string(key.Bytes), nil
	default:
		return "", errors.New("cbor: map key must be an integer, text, or byte string")
	}
}
