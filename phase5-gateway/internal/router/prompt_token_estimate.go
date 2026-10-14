package router

import (
	"bytes"
	"encoding/json"
	"io"
	"unicode/utf8"
)

// SPEC-006 §7.2.1 (v0.9.54, #1570) content-class prompt-token estimates.
//
// bytes/4 is wrong in both directions: token-dense text (digits, code, JSON,
// emoji) needs up to one token per byte, so a bytes/4 reservation under-counts
// it and the provider's honest count is clamped; Cyrillic, CJK and indented
// code pack several bytes per token, so a bytes/4 context check over-counts it
// and rejects prompts a provider can serve.
//
// Both estimates walk the decoded JSON text (every string, key and scalar
// literal; no quotes, separators or escape sequences) and price each character
// class in milli-tokens. The weights were calibrated against the Qwen3.6
// tokenizer on prose, Go/Swift/Python code, JSON, digits, CSV, hex, base64,
// Chinese, Russian, emoji, indented code and punctuation. They MUST stay
// identical in the gateway and the coordinator.
type promptTokenClassWeights struct {
	letterRunDivisorMilli int64 // an ASCII letter run costs ceil(run*1000/divisor) milli-tokens
	digit                 int64
	space                 int64
	lineBreak             int64 // \n, \r, \t
	otherASCII            int64 // punctuation and controls
	twoByteRune           int64
	threeByteRune         int64
	fourByteRune          int64
}

// promptTokenUpperWeights is at or above the Qwen3.6 count on every
// calibration corpus except random letter strings and base64 (about 0.6-0.75x),
// and about 1.8x on prose and code.
var promptTokenUpperWeights = promptTokenClassWeights{
	letterRunDivisorMilli: 2500,
	digit:                 1200,
	space:                 250,
	lineBreak:             1000,
	otherASCII:            1000,
	twoByteRune:           600,
	threeByteRune:         1000,
	fourByteRune:          3000,
}

// promptTokenCentralWeights is at or below the Qwen3.6 count on every
// calibration corpus (0.8-1.0x on prose, code, JSON, Chinese and Russian).
var promptTokenCentralWeights = promptTokenClassWeights{
	letterRunDivisorMilli: 4500,
	digit:                 900,
	space:                 100,
	lineBreak:             500,
	otherASCII:            500,
	twoByteRune:           220,
	threeByteRune:         450,
	fourByteRune:          2000,
}

// promptTokenClassEstimate returns the class-weighted token estimate of the
// JSON body's decoded text, rounded up, and false when the body is not valid
// JSON.
func promptTokenClassEstimate(raw []byte, w promptTokenClassWeights) (int64, bool) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var milli int64
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return 0, false
		}
		switch v := tok.(type) {
		case string:
			milli += promptTokenClassTextMilli(v, w)
		case json.Number:
			milli += promptTokenClassTextMilli(string(v), w)
		case bool, nil:
			milli += promptTokenClassTextMilli("null", w)
		}
	}
	return (milli + 999) / 1000, true
}

func promptTokenClassTextMilli(s string, w promptTokenClassWeights) int64 {
	var milli, run int64
	flush := func() {
		if run > 0 {
			milli += (run*1_000_000 + w.letterRunDivisorMilli - 1) / w.letterRunDivisorMilli
			run = 0
		}
	}
	for _, r := range s {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z'):
			run++
			continue
		}
		flush()
		switch {
		case r >= '0' && r <= '9':
			milli += w.digit
		case r == ' ':
			milli += w.space
		case r == '\n' || r == '\r' || r == '\t':
			milli += w.lineBreak
		case r < utf8.RuneSelf:
			milli += w.otherASCII
		default:
			switch utf8.RuneLen(r) {
			case 2:
				milli += w.twoByteRune
			case 3:
				milli += w.threeByteRune
			default:
				milli += w.fourByteRune
			}
		}
	}
	flush()
	return milli
}
