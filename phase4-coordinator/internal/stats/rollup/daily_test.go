package rollup

import "testing"
import "time"

func TestCompleteDayWindowOmitsOpenDay(t *testing.T) {
	now := time.Date(2026, 9, 24, 17, 40, 0, 0, time.UTC)
	start, end := completeDayWindow(now, 0)
	wantEnd := time.Date(2026, 9, 24, 0, 0, 0, 0, time.UTC)
	wantStart := wantEnd.AddDate(0, 0, -90)
	if !start.Equal(wantStart) || !end.Equal(wantEnd) {
		t.Fatalf("window = %s .. %s, want %s .. %s", start, end, wantStart, wantEnd)
	}
}

func TestCompleteDayWindowStartsAfterPartialHistory(t *testing.T) {
	now := time.Date(2026, 9, 24, 17, 40, 0, 0, time.UTC)
	since := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC).Unix()
	start, end := completeDayWindow(now, since)
	wantStart := time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC)
	wantEnd := time.Date(2026, 9, 24, 0, 0, 0, 0, time.UTC)
	if !start.Equal(wantStart) || !end.Equal(wantEnd) {
		t.Fatalf("window = %s .. %s, want %s .. %s", start, end, wantStart, wantEnd)
	}
}

func TestCompleteDayWindowKeepsMidnightBoundary(t *testing.T) {
	now := time.Date(2026, 9, 24, 1, 0, 0, 0, time.UTC)
	since := time.Date(2026, 6, 26, 0, 0, 0, 0, time.UTC).Unix()
	start, _ := completeDayWindow(now, since)
	want := time.Date(2026, 6, 26, 0, 0, 0, 0, time.UTC)
	if !start.Equal(want) {
		t.Fatalf("start = %s, want %s", start, want)
	}
}
