package billing

import (
	"strings"
	"time"
)

func sqliteTimeText(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000000000Z")
}

func sqliteTimeRange(column string) string {
	column = strings.TrimSpace(column)
	return column + " >= ? AND " + column + " < ?"
}

func sqliteTimeSince(column string) string {
	column = strings.TrimSpace(column)
	return column + " >= ?"
}

func sqliteTimeBefore(column string) string {
	column = strings.TrimSpace(column)
	return column + " < ?"
}

func normalizeSQLiteTimeText(raw string) (string, bool) {
	t, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(raw))
	if err != nil {
		return raw, false
	}
	return sqliteTimeText(t), true
}
