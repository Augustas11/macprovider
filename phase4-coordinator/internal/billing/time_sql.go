package billing

import (
	"strings"
	"time"
)

func sqliteTimeText(t time.Time) string {
	return t.UTC().Format(time.RFC3339Nano)
}

func sqliteTimeRange(column string) string {
	column = strings.TrimSpace(column)
	return "julianday(" + column + ") >= julianday(?) AND julianday(" + column + ") < julianday(?)"
}

func sqliteTimeSince(column string) string {
	column = strings.TrimSpace(column)
	return "julianday(" + column + ") >= julianday(?)"
}
