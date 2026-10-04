package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

const (
	maxCBORSize  = 1 << 20
	maxCBORDepth = 8
	maxCBORItems = 4096
	maxCBORPairs = 64
)

// Kind is a CBOR major type this decoder accepts. Major type 6 (tags) and
// indefinite lengths are rejected. Floats are rejected; App Attest objects
// do not use them.
type Kind uint8

const (
	KindUint Kind = iota
	KindNeg
	KindBytes
	KindText
	KindArray
	KindMap
	KindBool
	KindNull
)

// Value is one definite-length CBOR item. Map keys keep their original type
// so a COSE key (integer keys, including negatives) round-trips.
type Value struct {
	Kind  Kind
	Uint  uint64
	Neg   int64
	Bytes []byte
	Text  string
	Array []Value
	Pairs []Pair
	Bool  bool
}

// Pair is one map entry in encoded order.
type Pair struct {
	Key Value
	Val Value
}

func (v Value) TextKey(name string) (Value, bool) {
	for _, pair := range v.Pairs {
		if pair.Key.Kind == KindText && pair.Key.Text == name {
			return pair.Val, true
		}
	}
	return Value{}, false
}

func (v Value) IntKey(key int64) (Value, bool) {
	for _, pair := range v.Pairs {
		switch pair.Key.Kind {
		case KindUint:
			if key >= 0 && pair.Key.Uint == uint64(key) {
				return pair.Val, true
			}
		case KindNeg:
			if pair.Key.Neg == key {
				return pair.Val, true
			}
		}
	}
	return Value{}, false
}

// Decode parses one CBOR value that occupies the entire buffer.
func Decode(data []byte) (Value, error) {
	value, n, err := DecodePrefix(data)
	if err != nil {
		return Value{}, err
	}
	if n != len(data) {
		return Value{}, fmt.Errorf("cbor: %d trailing bytes", len(data)-n)
	}
	return value, nil
}

// DecodePrefix parses one CBOR value and returns how many bytes it consumed.
func DecodePrefix(data []byte) (Value, int, error) {
	if len(data) > maxCBORSize {
		return Value{}, 0, fmt.Errorf("cbor: input exceeds %d bytes", maxCBORSize)
	}
	dec := &decoder{data: data}
	value, err := dec.item(0)
	if err != nil {
		return Value{}, 0, err
	}
	return value, dec.off, nil
}

type decoder struct {
	data  []byte
	off   int
	items int
}

func (d *decoder) item(depth int) (Value, error) {
	if depth > maxCBORDepth {
		return Value{}, errors.New("cbor: max depth exceeded")
	}
	d.items++
	if d.items > maxCBORItems {
		return Value{}, errors.New("cbor: max item count exceeded")
	}
	if d.off >= len(d.data) {
		return Value{}, errors.New("cbor: truncated")
	}
	head := d.data[d.off]
	d.off++
	major := head >> 5
	arg, err := d.argument(head & 0x1f)
	if err != nil {
		return Value{}, err
	}
	switch major {
	case 0:
		return Value{Kind: KindUint, Uint: arg}, nil
	case 1:
		if arg > uint64(math.MaxInt64) {
			return Value{}, errors.New("cbor: negative integer overflows int64")
		}
		return Value{Kind: KindNeg, Neg: -1 - int64(arg)}, nil
	case 2:
		buf, err := d.take(arg)
		if err != nil {
			return Value{}, err
		}
		return Value{Kind: KindBytes, Bytes: append([]byte(nil), buf...)}, nil
	case 3:
		buf, err := d.take(arg)
		if err != nil {
			return Value{}, err
		}
		return Value{Kind: KindText, Text: string(buf)}, nil
	case 4:
		if arg > maxCBORPairs {
			return Value{}, fmt.Errorf("cbor: array length %d exceeds %d", arg, maxCBORPairs)
		}
		items := make([]Value, 0, arg)
		for i := uint64(0); i < arg; i++ {
			child, err := d.item(depth + 1)
			if err != nil {
				return Value{}, err
			}
			items = append(items, child)
		}
		return Value{Kind: KindArray, Array: items}, nil
	case 5:
		if arg > maxCBORPairs {
			return Value{}, fmt.Errorf("cbor: map length %d exceeds %d", arg, maxCBORPairs)
		}
		pairs := make([]Pair, 0, arg)
		seen := make(map[string]struct{}, arg)
		for i := uint64(0); i < arg; i++ {
			key, err := d.item(depth + 1)
			if err != nil {
				return Value{}, err
			}
			val, err := d.item(depth + 1)
			if err != nil {
				return Value{}, err
			}
			mark, err := keyIdentity(key)
			if err != nil {
				return Value{}, err
			}
			if _, ok := seen[mark]; ok {
				return Value{}, errors.New("cbor: duplicate map key")
			}
			seen[mark] = struct{}{}
			pairs = append(pairs, Pair{Key: key, Val: val})
		}
		return Value{Kind: KindMap, Pairs: pairs}, nil
	case 7:
		return simple(head, arg)
	default:
		return Value{}, fmt.Errorf("cbor: unsupported major type %d", major)
	}
}

func simple(head byte, arg uint64) (Value, error) {
	info := head & 0x1f
	switch info {
	case 20:
		return Value{Kind: KindBool, Bool: false}, nil
	case 21:
		return Value{Kind: KindBool, Bool: true}, nil
	case 22:
		return Value{Kind: KindNull}, nil
	case 24:
		return Value{}, fmt.Errorf("cbor: simple value %d is not used", arg)
	case 25, 26, 27:
		return Value{}, errors.New("cbor: floating point is not used")
	case 31:
		return Value{}, errors.New("cbor: indefinite length is rejected")
	default:
		return Value{}, fmt.Errorf("cbor: unsupported simple value %d", info)
	}
}

func (d *decoder) argument(info byte) (uint64, error) {
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

func (d *decoder) take(n uint64) ([]byte, error) {
	if n > uint64(len(d.data)-d.off) {
		return nil, errors.New("cbor: truncated")
	}
	start := d.off
	d.off += int(n)
	return d.data[start:d.off], nil
}

func keyIdentity(key Value) (string, error) {
	switch key.Kind {
	case KindUint:
		return fmt.Sprintf("u:%d", key.Uint), nil
	case KindNeg:
		return fmt.Sprintf("n:%d", key.Neg), nil
	case KindText:
		return "t:" + key.Text, nil
	case KindBytes:
		return "b:" + string(key.Bytes), nil
	case KindBool:
		if key.Bool {
			return "bool:1", nil
		}
		return "bool:0", nil
	case KindNull:
		return "null", nil
	default:
		return "", errors.New("cbor: map key must be an integer, string, bytes, bool, or null")
	}
}

// Encode writes a definite-length CBOR value. Map pair order is preserved.
func Encode(value Value) ([]byte, error) {
	var buf []byte
	out, err := encodeInto(buf, value, 0)
	if err != nil {
		return nil, err
	}
	if len(out) > maxCBORSize {
		return nil, fmt.Errorf("cbor: encoded value exceeds %d bytes", maxCBORSize)
	}
	return out, nil
}

func encodeInto(dst []byte, value Value, depth int) ([]byte, error) {
	if depth > maxCBORDepth {
		return nil, errors.New("cbor: max depth exceeded")
	}
	switch value.Kind {
	case KindUint:
		return appendArgument(dst, 0, value.Uint), nil
	case KindNeg:
		if value.Neg >= 0 {
			return nil, errors.New("cbor: negative value must be < 0")
		}
		return appendArgument(dst, 1, uint64(-1-value.Neg)), nil
	case KindBytes:
		dst = appendArgument(dst, 2, uint64(len(value.Bytes)))
		return append(dst, value.Bytes...), nil
	case KindText:
		dst = appendArgument(dst, 3, uint64(len(value.Text)))
		return append(dst, value.Text...), nil
	case KindArray:
		if len(value.Array) > maxCBORPairs {
			return nil, fmt.Errorf("cbor: array length %d exceeds %d", len(value.Array), maxCBORPairs)
		}
		dst = appendArgument(dst, 4, uint64(len(value.Array)))
		for _, child := range value.Array {
			var err error
			dst, err = encodeInto(dst, child, depth+1)
			if err != nil {
				return nil, err
			}
		}
		return dst, nil
	case KindMap:
		if len(value.Pairs) > maxCBORPairs {
			return nil, fmt.Errorf("cbor: map length %d exceeds %d", len(value.Pairs), maxCBORPairs)
		}
		dst = appendArgument(dst, 5, uint64(len(value.Pairs)))
		for _, pair := range value.Pairs {
			var err error
			dst, err = encodeInto(dst, pair.Key, depth+1)
			if err != nil {
				return nil, err
			}
			dst, err = encodeInto(dst, pair.Val, depth+1)
			if err != nil {
				return nil, err
			}
		}
		return dst, nil
	case KindBool:
		if value.Bool {
			return append(dst, 0xf5), nil
		}
		return append(dst, 0xf4), nil
	case KindNull:
		return append(dst, 0xf6), nil
	default:
		return nil, errors.New("cbor: cannot encode value")
	}
}

func appendArgument(dst []byte, major byte, n uint64) []byte {
	prefix := major << 5
	switch {
	case n < 24:
		return append(dst, prefix|byte(n))
	case n <= 0xff:
		return append(dst, prefix|24, byte(n))
	case n <= 0xffff:
		dst = append(dst, prefix|25, 0, 0)
		binary.BigEndian.PutUint16(dst[len(dst)-2:], uint16(n))
		return dst
	case n <= 0xffffffff:
		dst = append(dst, prefix|26, 0, 0, 0, 0)
		binary.BigEndian.PutUint32(dst[len(dst)-4:], uint32(n))
		return dst
	default:
		dst = append(dst, prefix|27, 0, 0, 0, 0, 0, 0, 0, 0)
		binary.BigEndian.PutUint64(dst[len(dst)-8:], n)
		return dst
	}
}

func uintValue(n uint64) Value { return Value{Kind: KindUint, Uint: n} }

func negValue(n int64) Value { return Value{Kind: KindNeg, Neg: n} }

func bytesValue(b []byte) Value { return Value{Kind: KindBytes, Bytes: b} }

func textValue(s string) Value { return Value{Kind: KindText, Text: s} }
