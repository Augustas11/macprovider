package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"
	"unicode/utf8"
)

const (
	derMaxBytes = 256 * 1024
	derMaxDepth = 16
)

type derClass int

const (
	derUniversal derClass = iota
	derApplication
	derContext
	derPrivate
)

type derNode struct {
	Class       derClass
	Constructed bool
	Tag         int
	Content     []byte
	Children    []derNode
}

// parseDER parses one DER value that must consume data.
func parseDER(data []byte) (derNode, error) {
	if len(data) == 0 {
		return derNode{}, fmt.Errorf("der: empty")
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
		return derNode{}, 0, fmt.Errorf("der: max depth exceeded")
	}
	if len(data) == 0 {
		return derNode{}, 0, fmt.Errorf("der: truncated header")
	}
	head := data[0]
	class := derClass(head >> 6)
	constructed := head&0x20 != 0
	tag := int(head & 0x1f)
	off := 1
	if tag == 0x1f {
		tag = 0
		seen := false
		for {
			if off >= len(data) {
				return derNode{}, 0, fmt.Errorf("der: truncated tag")
			}
			b := data[off]
			off++
			seen = true
			if tag > (1 << 24) {
				return derNode{}, 0, fmt.Errorf("der: tag too large")
			}
			tag = (tag << 7) | int(b&0x7f)
			if b&0x80 == 0 {
				break
			}
		}
		if !seen || tag < 0x1f {
			return derNode{}, 0, fmt.Errorf("der: non-minimal long tag")
		}
	}
	if off >= len(data) {
		return derNode{}, 0, fmt.Errorf("der: truncated length")
	}
	lengthByte := data[off]
	off++
	var length int
	if lengthByte&0x80 == 0 {
		length = int(lengthByte)
	} else {
		n := int(lengthByte & 0x7f)
		if n == 0 {
			return derNode{}, 0, fmt.Errorf("der: indefinite length is rejected")
		}
		if n > 4 {
			return derNode{}, 0, fmt.Errorf("der: length field too wide")
		}
		if off+n > len(data) {
			return derNode{}, 0, fmt.Errorf("der: truncated length")
		}
		if data[off] == 0 {
			return derNode{}, 0, fmt.Errorf("der: non-minimal length")
		}
		for i := 0; i < n; i++ {
			length = (length << 8) | int(data[off+i])
		}
		off += n
		if length < 0x80 {
			return derNode{}, 0, fmt.Errorf("der: non-minimal length")
		}
	}
	if length < 0 || off+length > len(data) {
		return derNode{}, 0, fmt.Errorf("der: truncated content")
	}
	content := data[off : off+length]
	node := derNode{Class: class, Constructed: constructed, Tag: tag}
	if constructed {
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

// explicitOctet returns the contents of SEQUENCE { [tag] EXPLICIT OCTET STRING }.
// Apple's nonce extension uses tag 1.
func explicitOctet(der []byte, tag int) ([]byte, error) {
	node, err := parseDER(der)
	if err != nil {
		return nil, err
	}
	if node.Class != derUniversal || node.Tag != 16 || !node.Constructed {
		return nil, fmt.Errorf("der: expected SEQUENCE")
	}
	if len(node.Children) != 1 {
		return nil, fmt.Errorf("der: expected one child in SEQUENCE, got %d", len(node.Children))
	}
	wrap := node.Children[0]
	if wrap.Class != derContext || wrap.Tag != tag || !wrap.Constructed || len(wrap.Children) != 1 {
		return nil, fmt.Errorf("der: expected constructed context [%d] around one value", tag)
	}
	oct := wrap.Children[0]
	if oct.Class != derUniversal || oct.Tag != 4 || oct.Constructed {
		return nil, fmt.Errorf("der: expected OCTET STRING inside context [%d]", tag)
	}
	return oct.Content, nil
}

// singleOctet returns the one OCTET STRING in a SEQUENCE, either as the
// sequence's only child or wrapped in one explicit context tag.
func singleOctet(der []byte) ([]byte, error) {
	node, err := parseDER(der)
	if err != nil {
		return nil, err
	}
	if node.Class != derUniversal || node.Tag != 16 || !node.Constructed || len(node.Children) != 1 {
		return nil, fmt.Errorf("der: expected SEQUENCE with one child")
	}
	child := node.Children[0]
	if child.Class == derContext && child.Constructed && len(child.Children) == 1 {
		child = child.Children[0]
	}
	if child.Class != derUniversal || child.Tag != 4 || child.Constructed {
		return nil, fmt.Errorf("der: expected one OCTET STRING in the SEQUENCE")
	}
	return child.Content, nil
}

// dumpDER renders a best-effort DER tree. Primitive OCTET STRINGs that
// themselves contain one complete DER value are shown encapsulated, which is
// how the aclBlob carries its inner policy.
func dumpDER(der []byte) (string, error) {
	node, err := parseDER(der)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	writeDER(&b, node, 0, true)
	return b.String(), nil
}

func writeDER(b *strings.Builder, node derNode, indent int, encapsulate bool) {
	pad := strings.Repeat("  ", indent)
	fmt.Fprintf(b, "%s%s", pad, derLabel(node))
	if node.Constructed {
		b.WriteString(" {\n")
		for _, child := range node.Children {
			writeDER(b, child, indent+1, encapsulate)
		}
		fmt.Fprintf(b, "%s}\n", pad)
		return
	}
	switch {
	case node.Class == derUniversal && node.Tag == 1:
		switch {
		case len(node.Content) == 1 && node.Content[0] == 0x00:
			b.WriteString(" false\n")
		case len(node.Content) == 1 && node.Content[0] == 0xff:
			b.WriteString(" true\n")
		default:
			fmt.Fprintf(b, " raw:%s\n", hex.EncodeToString(node.Content))
		}
	case node.Class == derUniversal && node.Tag == 2:
		fmt.Fprintf(b, " %s\n", formatInteger(node.Content))
	case node.Class == derUniversal && node.Tag == 4:
		fmt.Fprintf(b, " (%d bytes) %s\n", len(node.Content), hex.EncodeToString(node.Content))
		if encapsulate {
			if inner, err := parseDER(node.Content); err == nil {
				b.WriteString(pad + "  encapsulated:\n")
				writeDER(b, inner, indent+2, false)
			}
		}
	case node.Class == derUniversal && node.Tag == 6:
		if oid, err := decodeOID(node.Content); err == nil {
			fmt.Fprintf(b, " %s\n", oid)
		} else {
			fmt.Fprintf(b, " hex:%s\n", hex.EncodeToString(node.Content))
		}
	case node.Class == derUniversal && (node.Tag == 12 || node.Tag == 19 || node.Tag == 22):
		if utf8.Valid(node.Content) && printableText(node.Content) {
			fmt.Fprintf(b, " %q\n", string(node.Content))
		} else {
			fmt.Fprintf(b, " hex:%s\n", hex.EncodeToString(node.Content))
		}
	case node.Class == derUniversal && node.Tag == 5:
		b.WriteString("\n")
	default:
		fmt.Fprintf(b, " (%d bytes) %s\n", len(node.Content), hex.EncodeToString(node.Content))
	}
}

func derLabel(node derNode) string {
	if node.Class == derUniversal {
		name := universalName(node.Tag)
		if node.Constructed && (node.Tag == 16 || node.Tag == 17) {
			return name
		}
		if node.Constructed {
			return name + " CONSTRUCTED"
		}
		return name
	}
	class := "CONTEXT"
	switch node.Class {
	case derApplication:
		class = "APPLICATION"
	case derPrivate:
		class = "PRIVATE"
	}
	form := "PRIMITIVE"
	if node.Constructed {
		form = "CONSTRUCTED"
	}
	return fmt.Sprintf("%s [%d] %s", class, node.Tag, form)
}

func universalName(tag int) string {
	switch tag {
	case 1:
		return "BOOLEAN"
	case 2:
		return "INTEGER"
	case 3:
		return "BIT STRING"
	case 4:
		return "OCTET STRING"
	case 5:
		return "NULL"
	case 6:
		return "OID"
	case 12:
		return "UTF8STRING"
	case 16:
		return "SEQUENCE"
	case 17:
		return "SET"
	case 19:
		return "PRINTABLESTRING"
	case 22:
		return "IA5STRING"
	case 23:
		return "UTCTIME"
	case 24:
		return "GENERALIZEDTIME"
	default:
		return fmt.Sprintf("UNIVERSAL %d", tag)
	}
}

func formatInteger(content []byte) string {
	if len(content) == 0 {
		return "empty"
	}
	n := new(big.Int).SetBytes(content)
	if content[0]&0x80 != 0 {
		// Two's-complement negative.
		limit := new(big.Int).Lsh(big.NewInt(1), uint(8*len(content)))
		n.Sub(n, limit)
	}
	return fmt.Sprintf("%s (0x%s)", n.String(), hex.EncodeToString(content))
}

func printableText(b []byte) bool {
	for _, c := range b {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}
	return true
}

func decodeOID(content []byte) (string, error) {
	if len(content) == 0 {
		return "", fmt.Errorf("empty oid")
	}
	var parts []int
	first := int(content[0])
	parts = append(parts, first/40, first%40)
	value := 0
	used := false
	for _, b := range content[1:] {
		if value > (1 << 24) {
			return "", fmt.Errorf("oid component too large")
		}
		value = (value << 7) | int(b&0x7f)
		used = true
		if b&0x80 == 0 {
			parts = append(parts, value)
			value = 0
			used = false
		}
	}
	if used {
		return "", fmt.Errorf("truncated oid")
	}
	var b strings.Builder
	for i, part := range parts {
		if i > 0 {
			b.WriteByte('.')
		}
		fmt.Fprintf(&b, "%d", part)
	}
	return b.String(), nil
}

func hexDump(data []byte) string {
	if len(data) == 0 {
		return ""
	}
	var b strings.Builder
	for off := 0; off < len(data); off += 32 {
		end := off + 32
		if end > len(data) {
			end = len(data)
		}
		if off > 0 {
			b.WriteByte('\n')
		}
		fmt.Fprintf(&b, "%04x  %s", off, hex.EncodeToString(data[off:end]))
	}
	return b.String()
}

// bytesEqual reports whether a and b are equal without branching on secret
// length differences. Callers here compare public attestation fields.
func bytesEqual(a, b []byte) bool {
	return bytes.Equal(a, b)
}
