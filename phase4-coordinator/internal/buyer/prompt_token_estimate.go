package buyer

import (
	"bytes"
	"encoding/json"
	"io"
	"unicode/utf8"
)

// SPEC-006 §7.2.1 (v0.9.54, #1570) content-class prompt-token estimates.
//
// bytes/4 is wrong in both directions: token-dense text (digits, code, JSON,
// base64, emoji, rare scripts) needs up to one token per byte, so a bytes/4
// reservation under-counts it and the provider's honest count is clamped;
// Cyrillic, CJK and indented code pack several bytes per token, so a bytes/4
// context check over-counts it and rejects prompts a provider can serve.
//
// Both estimates walk the decoded JSON text (every string, key and scalar
// literal; no quotes, separators or escape sequences) and price each character
// class in milli-tokens. A run of ASCII letters and digits is priced as a unit:
// letters only, digits only, or mixed (identifiers, hex, base64). The weights
// were calibrated against the Qwen3.6 tokenizer; SPEC-006 §7.2.1 lists the
// corpora. They MUST stay identical in the gateway and the coordinator.
type promptTokenClassWeights struct {
	// A letters-only run of n letters costs n*1000/letterDivisor milli-tokens
	// for its first longLetterRun letters and n*1000/longLetterDivisor for the
	// rest (longLetterRun 0 = no long-run rate). Rounded up per run.
	letterDivisorMilli     int64
	longLetterRun          int64
	longLetterDivisorMilli int64
	mixedAlnumChar         int64 // per character of a run with letters and digits
	digit                  int64 // per character of a digits-only run
	space                  int64
	lineBreak              int64 // \n, \r, \t
	otherASCII             int64 // punctuation and controls
	twoByteRune            int64
	threeByteRune          int64
	fourByteRune           int64
}

// promptTokenUpperWeights is at or above the Qwen3.6 count on every
// calibration corpus, including random letters, base64, hex and random
// non-Latin characters; about 1.8-2x on prose and code and about 4.5-5x on
// Chinese and Russian prose.
var promptTokenUpperWeights = promptTokenClassWeights{
	letterDivisorMilli:     2500,
	longLetterRun:          12,
	longLetterDivisorMilli: 1500,
	mixedAlnumChar:         1000,
	digit:                  1200,
	space:                  250,
	lineBreak:              1000,
	otherASCII:             1000,
	twoByteRune:            1100,
	threeByteRune:          2200,
	fourByteRune:           3000,
}

// promptTokenCentralWeights is at or below the Qwen3.6 count on every
// calibration corpus (0.9-1.0x on prose, code, JSON, Chinese and Russian).
var promptTokenCentralWeights = promptTokenClassWeights{
	letterDivisorMilli: 4500,
	mixedAlnumChar:     500,
	digit:              900,
	space:              100,
	lineBreak:          500,
	otherASCII:         500,
	twoByteRune:        220,
	threeByteRune:      450,
	fourByteRune:       2000,
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
		case bool:
			if v {
				milli += promptTokenClassTextMilli("true", w)
			} else {
				milli += promptTokenClassTextMilli("false", w)
			}
		case nil:
			milli += promptTokenClassTextMilli("null", w)
		}
	}
	return (milli + 999) / 1000, true
}

func promptTokenClassTextMilli(s string, w promptTokenClassWeights) int64 {
	var milli, letters, digits int64
	flush := func() {
		switch {
		case letters > 0 && digits > 0:
			milli += (letters + digits) * w.mixedAlnumChar
		case letters > 0:
			short, long := letters, int64(0)
			if w.longLetterRun > 0 && letters > w.longLetterRun {
				short, long = w.longLetterRun, letters-w.longLetterRun
			}
			milli += ceilDiv(short*1_000_000, w.letterDivisorMilli)
			if long > 0 {
				milli += ceilDiv(long*1_000_000, w.longLetterDivisorMilli)
			}
		case digits > 0:
			milli += digits * w.digit
		}
		letters, digits = 0, 0
	}
	for _, r := range s {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z'):
			letters++
			continue
		case r >= '0' && r <= '9':
			digits++
			continue
		}
		flush()
		switch {
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

func ceilDiv(n, d int64) int64 {
	return (n + d - 1) / d
}
