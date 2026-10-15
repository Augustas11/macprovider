package router

import "strings"

// streamThinkFilter holds reasoning-delimiter state for one adapter request.
// Its zero value is ready to consume content; never share it between requests.
type streamThinkFilter struct {
	thinkPending string
	thinkInBlock bool
}

func (a *streamThinkFilter) filterThinkContent(s string) string {
	input := a.thinkPending + s
	a.thinkPending = ""
	var out strings.Builder
	for input != "" {
		if a.thinkInBlock {
			if end := strings.Index(input, "</think>"); end >= 0 {
				input = input[end+len("</think>"):]
				a.thinkInBlock = false
				continue
			}
			a.thinkPending = longestSuffixThatPrefixes(input, "</think>")
			return out.String()
		}
		if start := strings.Index(input, "<think>"); start >= 0 {
			out.WriteString(input[:start])
			input = input[start+len("<think>"):]
			a.thinkInBlock = true
			continue
		}
		a.thinkPending = longestSuffixThatPrefixes(input, "<think>")
		out.WriteString(input[:len(input)-len(a.thinkPending)])
		return out.String()
	}
	return out.String()
}

func (a *streamThinkFilter) flushThinkRemainder() string {
	if a.thinkInBlock {
		a.thinkPending = ""
		return ""
	}
	remainder := a.thinkPending
	a.thinkPending = ""
	return remainder
}

func longestSuffixThatPrefixes(s, prefix string) string {
	max := len(prefix) - 1
	if len(s) < max {
		max = len(s)
	}
	for n := max; n > 0; n-- {
		suffix := s[len(s)-n:]
		if strings.HasPrefix(prefix, suffix) {
			return suffix
		}
	}
	return ""
}
