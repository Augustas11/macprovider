package appattest

import (
	"errors"
	"fmt"
)

const (
	derMaxBytes = 16 << 10
	derMaxDepth = 16

	derClassUniversal = 0
	derClassContext   = 2

	derTagOctetString = 4
	derTagSequence    = 16
)

type derNode struct {
	Class       int
	Constructed bool
	Tag         int
	Content     []byte
	Children    []derNode
}

// parseDER parses one DER value that must consume data. It rejects
// indefinite and non-minimal lengths and nesting beyond derMaxDepth.
func parseDER(data []byte) (derNode, error) {
	if len(data) == 0 {
		return derNode{}, errors.New("der: empty")
	}
	if len(data) > derMaxBytes {
		return derNode{}, fmt.Errorf("der: value exceeds %d bytes", derMaxBytes)
	}
	node, n, err := parseDERAt(data, 0)
	if err != nil {
		return derNode{}, err
	}
	if n != len(data) {
		return derNode{}, fmt.Errorf("der: %d trailing bytes", len(data)-n)
	}
	return node, nil
}

func parseDERAt(data []byte, depth int) (derNode, int, error) {
	if depth > derMaxDepth {
		return derNode{}, 0, errors.New("der: max depth exceeded")
	}
	if len(data) < 2 {
		return derNode{}, 0, errors.New("der: truncated header")
	}
	head := data[0]
	node := derNode{Class: int(head >> 6), Constructed: head&0x20 != 0, Tag: int(head & 0x1f)}
	if node.Tag == 0x1f {
		// App Attest extensions use only low tag numbers.
		return derNode{}, 0, errors.New("der: high tag numbers are not used")
	}
	off := 1
	lengthByte := data[off]
	off++
	length := 0
	if lengthByte&0x80 == 0 {
		length = int(lengthByte)
	} else {
		n := int(lengthByte & 0x7f)
		if n == 0 {
			return derNode{}, 0, errors.New("der: indefinite length is rejected")
		}
		if n > 3 {
			return derNode{}, 0, errors.New("der: length field too wide")
		}
		if off+n > len(data) {
			return derNode{}, 0, errors.New("der: truncated length")
		}
		if data[off] == 0 {
			return derNode{}, 0, errors.New("der: non-minimal length")
		}
		for i := 0; i < n; i++ {
			length = (length << 8) | int(data[off+i])
		}
		off += n
		if length < 0x80 {
			return derNode{}, 0, errors.New("der: non-minimal length")
		}
	}
	if length > len(data)-off {
		return derNode{}, 0, errors.New("der: truncated content")
	}
	content := data[off : off+length]
	if node.Constructed {
		rest := content
		for len(rest) > 0 {
			child, used, err := parseDERAt(rest, depth+1)
			if err != nil {
				return derNode{}, 0, err
			}
			node.Children = append(node.Children, child)
			rest = rest[used:]
		}
	} else {
		node.Content = append([]byte(nil), content...)
	}
	return node, off + length, nil
}

func (n derNode) isOctetString() bool {
	return n.Class == derClassUniversal && n.Tag == derTagOctetString && !n.Constructed
}

func (n derNode) isSequence() bool {
	return n.Class == derClassUniversal && n.Tag == derTagSequence && n.Constructed
}

// nonceOctets returns the octets of SEQUENCE { [1] EXPLICIT OCTET STRING },
// the SPEC-049 §4.1 nonce extension shape.
func nonceOctets(der []byte) ([]byte, error) {
	node, err := parseDER(der)
	if err != nil {
		return nil, err
	}
	if !node.isSequence() || len(node.Children) != 1 {
		return nil, errors.New("der: nonce extension is not a one-element SEQUENCE")
	}
	wrap := node.Children[0]
	if wrap.Class != derClassContext || wrap.Tag != 1 || !wrap.Constructed || len(wrap.Children) != 1 {
		return nil, errors.New("der: nonce extension is not [1] EXPLICIT")
	}
	if !wrap.Children[0].isOctetString() {
		return nil, errors.New("der: nonce extension does not wrap an OCTET STRING")
	}
	return wrap.Children[0].Content, nil
}

// aclOctets returns the one OCTET STRING of the aclBlob extension: a
// SEQUENCE with exactly one element, either the OCTET STRING itself or a
// constructed context-specific tag wrapping exactly one OCTET STRING.
// Apple's published sample uses [3] EXPLICIT; Apple's text says only
// "a sequence with a single octet string".
func aclOctets(der []byte) ([]byte, error) {
	node, err := parseDER(der)
	if err != nil {
		return nil, err
	}
	if !node.isSequence() || len(node.Children) != 1 {
		return nil, errors.New("der: aclBlob is not a one-element SEQUENCE")
	}
	child := node.Children[0]
	if child.Class == derClassContext && child.Constructed {
		if len(child.Children) != 1 {
			return nil, errors.New("der: aclBlob context tag does not wrap one value")
		}
		child = child.Children[0]
	}
	if !child.isOctetString() {
		return nil, errors.New("der: aclBlob does not hold an OCTET STRING")
	}
	return child.Content, nil
}
