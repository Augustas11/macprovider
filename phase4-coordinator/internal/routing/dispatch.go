package routing

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
)

// RewriteModel rewrites the `model` field in an OpenAI-style chat-
// completions request body so the upstream provider receives the
// provider's actual model_id rather than the buyer's class-name (or
// model-alias) request. Byte-identical to pre-extraction
// `buyer.dispatchBodyForProvider` (issue #266 T2 refactor):
//
//   - When the buyer-requested model already EQUALS the provider's
//     model_id (case-insensitive), the raw body is returned unchanged
//     except for being copied to a fresh slice (so callers may safely
//     keep `rawBody` for retry use).
//   - Otherwise the body is parsed as a single JSON object, the
//     UNIQUE top-level `model` field is located, and ONLY the value
//     bytes are replaced with `json.Marshal(providerModelID)`. All
//     surrounding whitespace, key ordering, and non-model fields are
//     preserved verbatim — billing keys off the raw body hash and
//     must observe the same bytes the buyer sent.
//
// Errors (rewrite path only — see "precondition" below):
//   - body is not a JSON object
//   - body contains a non-string object key
//   - body has zero `model` fields
//   - body has duplicate `model` fields
//   - body has a non-canonical-cased model field (e.g. "Model": ...)
//   - underlying json.Decoder errors
//
// The non-canonical-case check defends against header-smuggling
// scenarios where a buyer-trusted gateway might match on "model"
// but a downstream provider might match on "Model"; rejecting at
// the rewrite boundary keeps the canonical-name contract intact.
//
// **Precondition**: when `requestedModel` and `providerModelID`
// compare equal under `strings.EqualFold`, the match-skip path
// fires AND DOES NOT validate the JSON body shape (duplicate /
// non-canonical / non-object checks all run only on the rewrite
// branch). The match-skip path is byte-identical to the pre-#266
// `buyer.dispatchBodyForProvider` behaviour; in the buyer flow
// the body is already validated upstream by `validateChatRequest`
// before reaching dispatch. **Callers outside the buyer pipeline
// MUST run their own JSON-shape validation before invoking
// `RewriteModel` if they need the dup/case/object checks** —
// this helper alone is not sufficient to enforce them on the
// match-skip path. Issue #266 T2 R1 SEC audit LOW (documented;
// not changing the production flow because the validateChatRequest
// upstream gate already covers it).
func RewriteModel(rawBody []byte, requestedModel, providerModelID string) ([]byte, error) {
	if strings.EqualFold(requestedModel, providerModelID) {
		return append([]byte(nil), rawBody...), nil
	}

	dec := json.NewDecoder(bytes.NewReader(rawBody))
	token, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if delim, ok := token.(json.Delim); !ok || delim != '{' {
		return nil, errors.New("chat request body is not a JSON object")
	}
	type replacement struct {
		start int
		end   int
	}
	var replacements []replacement
	for dec.More() {
		keyToken, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, ok := keyToken.(string)
		if !ok {
			return nil, errors.New("chat request body contains a non-string object key")
		}
		keyEnd := int(dec.InputOffset())
		valueStart, err := jsonValueStart(rawBody, keyEnd)
		if err != nil {
			return nil, err
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return nil, err
		}
		if key == "model" {
			replacements = append(replacements, replacement{start: valueStart, end: int(dec.InputOffset())})
		} else if strings.EqualFold(key, "model") {
			return nil, errors.New("chat request body contains non-canonical model field")
		}
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	if len(replacements) == 0 {
		return nil, errors.New("chat request body missing model field")
	}
	if len(replacements) > 1 {
		return nil, errors.New("chat request body contains duplicate model fields")
	}
	model, err := json.Marshal(providerModelID)
	if err != nil {
		return nil, err
	}
	out := append([]byte(nil), rawBody...)
	r := replacements[0]
	next := make([]byte, 0, len(out)-(r.end-r.start)+len(model))
	next = append(next, out[:r.start]...)
	next = append(next, model...)
	next = append(next, out[r.end:]...)
	return next, nil
}

// jsonValueStart locates the byte offset of the first character of a
// JSON object value, given the byte offset immediately past the key
// (i.e. after the closing quote of the key string). Skips JSON
// whitespace, requires a `:` separator, then skips trailing
// whitespace before the value. Used by RewriteModel to compute the
// EXACT byte range to splice out when replacing the `model` field's
// value without disturbing surrounding formatting.
func jsonValueStart(raw []byte, keyEnd int) (int, error) {
	i := keyEnd
	for i < len(raw) && (raw[i] == ' ' || raw[i] == '\n' || raw[i] == '\r' || raw[i] == '\t') {
		i++
	}
	if i >= len(raw) || raw[i] != ':' {
		return 0, errors.New("chat request body object key missing colon")
	}
	i++
	for i < len(raw) && (raw[i] == ' ' || raw[i] == '\n' || raw[i] == '\r' || raw[i] == '\t') {
		i++
	}
	if i >= len(raw) {
		return 0, errors.New("chat request body object key missing value")
	}
	return i, nil
}
