package buyer

// promptTokenClassGoldenCases pins the SPEC-006 §7.2.1 class estimates. The
// same table is in phase4-coordinator/internal/buyer and
// phase5-gateway/internal/router; keep them identical.
var promptTokenClassGoldenCases = []struct {
	name           string
	body           string
	upper, central int64
}{
	{"prose", `{"messages":[{"role":"user","content":"The quick brown fox jumps over the lazy dog."}]}`, 27, 15},
	{"digits", `{"messages":[{"role":"user","content":"0123456789 0123456789"}]}`, 34, 24},
	{"code", `{"messages":[{"role":"user","content":"func main() {\n\tfmt.Println(\"hi\")\n}\n"}]}`, 31, 17},
	{"cyrillic", `{"messages":[{"role":"user","content":"Машинное обучение"}]}`, 28, 9},
	{"cjk_escaped", `{"messages":[{"role":"user","content":"\u4e2d\u6587"}]}`, 14, 7},
	{"emoji", `{"messages":[{"role":"user","content":"😀😀"}]}`, 16, 10},
	{"scalars", `{"max_tokens":128,"stream":true,"stop":null,"logprobs":false}`, 21, 13},
	{"mixed_alnum", `{"messages":[{"role":"user","content":"sha256 a1b2c3d4 aGVsbG8gd29ybGQ="}]}`, 40, 21},
	{"long_letters", `{"messages":[{"role":"user","content":"pneumonoultramicroscopicsilicovolcanoconiosis"}]}`, 36, 16},
}
