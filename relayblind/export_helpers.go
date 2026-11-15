package relayblind

import "bytes"

// Exported wrappers for the coordinator package, which calls these
// helpers. The implementations stay unexported.
func ValidCDHash(value string) bool {
	return validCDHash(value)
}

func ValidTeamID(value string) bool {
	return validTeamID(value)
}

func EncodeBase64URL(value []byte) string {
	return encodeBase64URL(value)
}

func DecodeBase64URLFixed(value string, size int) ([]byte, error) {
	return decodeBase64URLFixed(value, size)
}

func WriteFrame(dst *bytes.Buffer, value []byte) error {
	return writeFrame(dst, value)
}

func WriteU64(dst *bytes.Buffer, value uint64) {
	writeU64(dst, value)
}

func WriteI64(dst *bytes.Buffer, value int64) {
	writeI64(dst, value)
}

func VisibleASCII(value string, max int) bool {
	return visibleASCII(value, max)
}

func DecodeClosed(raw []byte, dst any, fields []string) error {
	return decodeClosed(raw, dst, fields)
}

func RejectDuplicateJSONKeys(raw []byte) error {
	return rejectDuplicateJSONKeys(raw)
}

func (a PrivacyKeyAttestation) Validate() error {
	return a.validate()
}
