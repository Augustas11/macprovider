package router

import (
	"fmt"
	"strings"
	"testing"
)

type thinkContentFilter interface {
	filterThinkContent(string) string
	flushThinkRemainder() string
}

func TestStreamingThinkFilterBoundaries(t *testing.T) {
	factories := map[string]func() thinkContentFilter{
		"responses": func() thinkContentFilter { return &responsesAdapter{} },
		"anthropic": func() thinkContentFilter { return &anthropicMessagesAdapter{} },
	}
	for name, newFilter := range factories {
		t.Run(name, func(t *testing.T) {
			check := func(t *testing.T, chunks []string, want string) {
				t.Helper()
				filter := newFilter()
				var got strings.Builder
				for _, chunk := range chunks {
					got.WriteString(filter.filterThinkContent(chunk))
				}
				got.WriteString(filter.flushThinkRemainder())
				if got.String() != want {
					t.Fatalf("chunks=%q got=%q want=%q", chunks, got.String(), want)
				}
				if got := filter.flushThinkRemainder(); got != "" {
					t.Fatalf("second flush=%q", got)
				}
			}
			open, close := "<think>", "</think>"
			for i := 0; i <= len(open); i++ {
				for j := 0; j <= len(close); j++ {
					t.Run(fmt.Sprintf("delimiters/%d/%d", i, j), func(t *testing.T) {
						check(t, []string{"before" + open[:i], open[i:] + "hidden" + close[:j], close[j:] + "after"}, "beforeafter")
					})
				}
			}
			for i := 1; i < len(open); i++ {
				t.Run(fmt.Sprintf("partial_open_eof/%d", i), func(t *testing.T) {
					check(t, []string{"visible", open[:i]}, "visible"+open[:i])
				})
			}
			for i := 0; i < len(close); i++ {
				t.Run(fmt.Sprintf("open_block_eof/%d", i), func(t *testing.T) {
					check(t, []string{"visible<think>", "hidden" + close[:i]}, "visible")
				})
			}
			t.Run("consecutive_blocks", func(t *testing.T) {
				check(t, []string{" <think>one</think><think>two</think>", " visible "}, "  visible ")
			})
			unicode := "🙂前<think>秘密🧠</think>後é"
			for i := 0; i <= len(unicode); i++ {
				t.Run(fmt.Sprintf("unicode_byte_split/%d", i), func(t *testing.T) {
					check(t, []string{unicode[:i], unicode[i:]}, "🙂前後é")
				})
			}
		})
	}
}

func TestStreamingThinkFilterRequestIsolation(t *testing.T) {
	factories := []func() thinkContentFilter{
		func() thinkContentFilter { return &responsesAdapter{} },
		func() thinkContentFilter { return &anthropicMessagesAdapter{} },
	}
	for i, newFirst := range factories {
		for j, newSecond := range factories {
			t.Run(fmt.Sprintf("%d/%d", i, j), func(t *testing.T) {
				first, second := newFirst(), newSecond()
				if got := first.filterThinkContent("<think>private"); got != "" {
					t.Fatalf("first filter leaked %q", got)
				}
				if got := second.filterThinkContent("public<th"); got != "public" {
					t.Fatalf("second filter=%q", got)
				}
				if got := first.filterThinkContent(" reasoning</think>first"); got != "first" {
					t.Fatalf("first filter=%q", got)
				}
				if got := second.flushThinkRemainder(); got != "<th" {
					t.Fatalf("second remainder=%q", got)
				}
			})
		}
	}
}
