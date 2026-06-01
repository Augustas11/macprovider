package sqlite

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

var _ storage.ExplorerStore = (*Store)(nil)

type listCursor struct {
	TS string `json:"ts,omitempty"`
	ID string `json:"id"`
}

type activityCursor struct {
	TS     string `json:"ts"`
	Rank   int    `json:"rank"`
	Source string `json:"source"`
	ID     string `json:"id"`
}

func (s *Store) ExplorerListBuyers(ctx context.Context, q storage.ExplorerBuyerQuery) (storage.ExplorerBuyerList, error) {
	cursorID, err := decodeListID(q.Cursor)
	if err != nil {
		return storage.ExplorerBuyerList{}, err
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT a.account_id, a.status, a.quota_class, a.concurrency_class, a.created_at,
		       COALESCE(SUM(ue.total_tokens), 0) AS used_tokens,
		       COALESCE(SUM(CASE WHEN qr.status = 'active' THEN qr.reserved_tokens ELSE 0 END), 0) AS reserved_tokens,
		       COALESCE(MAX(ue.created_at), '') AS last_usage_time,
		       COALESCE((SELECT request_id FROM usage_events u2 WHERE u2.account_id = a.account_id ORDER BY u2.created_at DESC, u2.request_id DESC LIMIT 1), '') AS last_request_id,
		       COALESCE((SELECT COUNT(*) FROM concurrency_reservations cr WHERE cr.account_id = a.account_id AND cr.status = 'active'), 0) AS active_concurrency,
		       COALESCE((SELECT COUNT(*) FROM feedback_events f WHERE f.account_id = a.account_id AND f.created_at >= ? AND f.created_at < ?), 0) AS feedback_count,
		       COALESCE((SELECT AVG(rating) FROM feedback_events f WHERE f.account_id = a.account_id AND f.created_at >= ? AND f.created_at < ?), -1) AS average_rating
		FROM accounts a
		LEFT JOIN account_identities ai ON ai.account_id = a.account_id
		LEFT JOIN api_keys ak ON ak.account_id = a.account_id
		LEFT JOIN usage_events ue ON ue.account_id = a.account_id AND ue.created_at >= ? AND ue.created_at < ?
		LEFT JOIN quota_reservations qr ON qr.account_id = a.account_id AND qr.created_at >= ? AND qr.created_at < ?
		WHERE (? = '' OR a.account_id > ?)
		  AND (? = '' OR a.status = ?)
		  AND (? = '' OR a.quota_class = ?)
		  AND (? = '' OR a.concurrency_class = ?)
		  AND (? = '' OR a.account_id = ?)
		  AND (? = '' OR ai.email = ?)
		  AND (? = '' OR ((? = 0 AND lower(ai.email) LIKE ? || '%') OR (? = 1 AND ai.email GLOB ? || '*')))
		  AND (? = '' OR ak.status = ?)
		GROUP BY a.account_id, a.status, a.quota_class, a.concurrency_class, a.created_at
		ORDER BY a.account_id ASC
		LIMIT ?`,
		encodeTime(q.From), encodeTime(q.To), encodeTime(q.From), encodeTime(q.To),
		encodeTime(q.From), encodeTime(q.To), encodeTime(q.From), encodeTime(q.To),
		cursorID, cursorID, q.Status, q.Status, q.QuotaClass, q.QuotaClass,
		q.ConcurrencyClass, q.ConcurrencyClass, q.AccountID, q.AccountID,
		q.Email, q.Email, q.EmailPrefix, boolInt(hasUpperASCII(q.EmailPrefix)), foldEmail(q.EmailPrefix), boolInt(hasUpperASCII(q.EmailPrefix)), q.EmailPrefix,
		q.KeyStatus, q.KeyStatus, q.Limit+1)
	if err != nil {
		return storage.ExplorerBuyerList{}, err
	}

	out := storage.ExplorerBuyerList{Partial: false, Error: nil}
	for rows.Next() {
		var item storage.ExplorerBuyerSummary
		var created, lastUsage, lastRequest string
		var avg float64
		if err := rows.Scan(&item.AccountID, &item.Status, &item.QuotaClass, &item.ConcurrencyClass, &created,
			&item.DailyTokensUsed, &item.DailyTokensReserved, &lastUsage, &lastRequest,
			&item.ActiveConcurrencyReservations, &item.FeedbackCount, &avg); err != nil {
			return storage.ExplorerBuyerList{}, err
		}
		item.CreatedAt = decodeTime(created)
		item.DailyTokenLimit = 0
		item.DailyTokensRemaining = 0
		if lastUsage != "" {
			t := decodeTime(lastUsage)
			item.LastUsageTime = &t
		}
		if lastRequest != "" {
			item.LastRequestID = &lastRequest
		}
		if avg >= 0 {
			item.AverageRating = &avg
		}
		out.Items = append(out.Items, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return storage.ExplorerBuyerList{}, err
	}
	if err := rows.Close(); err != nil {
		return storage.ExplorerBuyerList{}, err
	}
	if len(out.Items) > q.Limit {
		next := encodeListID(out.Items[q.Limit-1].AccountID)
		out.NextCursor = &next
		out.Items = out.Items[:q.Limit]
	}
	for i := range out.Items {
		out.Items[i].Identities, err = s.explorerIdentities(ctx, out.Items[i].AccountID)
		if err != nil {
			return storage.ExplorerBuyerList{}, err
		}
		out.Items[i].APIKeys, err = s.explorerAPIKeys(ctx, out.Items[i].AccountID)
		if err != nil {
			return storage.ExplorerBuyerList{}, err
		}
	}
	out.Summary, err = s.explorerBuyerRollup(ctx, q.From, q.To)
	return out, err
}

func (s *Store) ExplorerBuyerDetail(ctx context.Context, accountID string, q storage.ExplorerDetailQuery) (storage.ExplorerBuyerDetail, error) {
	account, err := s.explorerBuyerByID(ctx, accountID, q.From, q.To)
	if err != nil {
		return storage.ExplorerBuyerDetail{}, err
	}
	out := storage.ExplorerBuyerDetail{
		AccountID: account.AccountID,
		Account: storage.ExplorerBuyerAccount{
			Status: account.Status, QuotaClass: account.QuotaClass,
			ConcurrencyClass: account.ConcurrencyClass, CreatedAt: account.CreatedAt,
		},
		Identities: account.Identities,
		APIKeys:    account.APIKeys,
		Partial:    false,
		Error:      nil,
	}
	if out.Usage.Events, err = s.explorerUsageEvents(ctx, accountID, "", q.From, q.To, q.Limit); err != nil {
		return storage.ExplorerBuyerDetail{}, err
	}
	for _, ev := range out.Usage.Events {
		out.Usage.TokensWindow += ev.TotalTokens
		out.Usage.TokensToday += ev.TotalTokens
		if out.Usage.LastUsageTime == nil || ev.CreatedAt.After(*out.Usage.LastUsageTime) {
			t := ev.CreatedAt
			id := ev.RequestID
			out.Usage.LastUsageTime = &t
			out.Usage.LastRequestID = &id
		}
	}
	if out.Quota.Reservations, err = s.explorerQuotaReservations(ctx, accountID, "", q.From, q.To, q.Limit); err != nil {
		return storage.ExplorerBuyerDetail{}, err
	}
	for _, reservation := range out.Quota.Reservations {
		switch reservation.Status {
		case "active":
			out.Quota.ActiveReservedTokens += reservation.ReservedTokens
		case "expired":
			out.Quota.ExpiredReservations++
		}
	}
	if out.Concurrency.Reservations, err = s.explorerConcurrencyReservations(ctx, accountID, "", q.From, q.To, q.Limit); err != nil {
		return storage.ExplorerBuyerDetail{}, err
	}
	for _, reservation := range out.Concurrency.Reservations {
		if reservation.Status == "active" {
			out.Concurrency.ActiveReservations++
		}
	}
	if out.Feedback.Events, err = s.explorerFeedbackEvents(ctx, accountID, "", q.From, q.To, q.Limit); err != nil {
		return storage.ExplorerBuyerDetail{}, err
	}
	out.Feedback.Count = len(out.Feedback.Events)
	if out.Feedback.Count > 0 {
		var sum float64
		for _, ev := range out.Feedback.Events {
			sum += float64(ev.Rating)
		}
		avg := sum / float64(out.Feedback.Count)
		out.Feedback.AverageRating = &avg
	}
	if out.Audit.Events, err = s.explorerAuditEvents(ctx, accountID, "", q.From, q.To, q.Limit); err != nil {
		return storage.ExplorerBuyerDetail{}, err
	}
	return out, nil
}

func (s *Store) ExplorerListSessions(ctx context.Context, q storage.ExplorerSessionQuery) (storage.ExplorerSessionList, error) {
	cursor, err := decodeListCursor(q.Cursor)
	if err != nil {
		return storage.ExplorerSessionList{}, err
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT request_id, account_id, demo_identity, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at
		FROM usage_events
		WHERE created_at >= ? AND created_at < ?
		  AND (? = '' OR account_id = ?)
		  AND (? = '' OR created_at < ? OR (created_at = ? AND request_id < ?))
		ORDER BY created_at DESC, request_id DESC
		LIMIT ?`,
		encodeTime(q.From), encodeTime(q.To), q.AccountID, q.AccountID,
		cursor.TS, cursor.TS, cursor.TS, cursor.ID, q.Limit+1)
	if err != nil {
		return storage.ExplorerSessionList{}, err
	}
	defer rows.Close()
	out := storage.ExplorerSessionList{Partial: false, Error: nil}
	for rows.Next() {
		item, err := scanUsage(rows)
		if err != nil {
			return storage.ExplorerSessionList{}, err
		}
		out.Items = append(out.Items, item)
	}
	if err := rows.Err(); err != nil {
		return storage.ExplorerSessionList{}, err
	}
	if len(out.Items) > q.Limit {
		last := out.Items[q.Limit-1]
		next := encodeListCursor(last.CreatedAt, last.RequestID)
		out.NextCursor = &next
		out.Items = out.Items[:q.Limit]
	}
	return out, nil
}

func (s *Store) ExplorerSessionDetail(ctx context.Context, requestID string) (storage.ExplorerSessionDetail, error) {
	out := storage.ExplorerSessionDetail{RequestID: requestID, Partial: false, Error: nil}
	usage, err := s.explorerUsageEvents(ctx, "", requestID, time.Time{}, time.Time{}, 1)
	if err != nil {
		return storage.ExplorerSessionDetail{}, err
	}
	if len(usage) > 0 {
		out.UsageEvent = &usage[0]
	}
	quota, err := s.explorerQuotaReservations(ctx, "", requestID, time.Time{}, time.Time{}, 1)
	if err != nil {
		return storage.ExplorerSessionDetail{}, err
	}
	if len(quota) > 0 {
		out.QuotaReservation = &quota[0]
	}
	concurrency, err := s.explorerConcurrencyReservations(ctx, "", requestID, time.Time{}, time.Time{}, 1)
	if err != nil {
		return storage.ExplorerSessionDetail{}, err
	}
	if len(concurrency) > 0 {
		out.ConcurrencyReservation = &concurrency[0]
	}
	out.FeedbackEvents, err = s.explorerFeedbackEvents(ctx, "", requestID, time.Time{}, time.Time{}, 50)
	if err != nil {
		return storage.ExplorerSessionDetail{}, err
	}
	out.AuditEvents, err = s.explorerAuditEvents(ctx, "", requestID, time.Time{}, time.Time{}, 50)
	if err != nil {
		return storage.ExplorerSessionDetail{}, err
	}
	if out.UsageEvent == nil && out.QuotaReservation == nil && out.ConcurrencyReservation == nil && len(out.FeedbackEvents) == 0 && len(out.AuditEvents) == 0 {
		return storage.ExplorerSessionDetail{}, storage.ErrNotFound
	}
	return out, nil
}

func (s *Store) ExplorerActivity(ctx context.Context, q storage.ExplorerActivityQuery) (storage.ExplorerActivityList, error) {
	cursor, err := decodeActivityCursor(nonEmpty(q.Cursor, q.SinceCursor))
	if err != nil {
		return storage.ExplorerActivityList{}, err
	}
	newer := q.SinceCursor != ""
	rows, err := s.db.QueryContext(ctx, `
		SELECT created_at, source_rank, event_type, source_id, request_id, account_id, key_id, status, tokens
		FROM (
			SELECT created_at, 80 AS source_rank, 'usage' AS event_type, request_id AS source_id, request_id, account_id, '' AS key_id, outcome AS status, total_tokens AS tokens FROM usage_events
			UNION ALL
			SELECT created_at, 70 AS source_rank, 'quota_reservation' AS event_type, request_id AS source_id, request_id, account_id, '' AS key_id, status, reserved_tokens AS tokens FROM quota_reservations
			UNION ALL
				SELECT created_at, 65 AS source_rank, 'api_key_event' AS event_type, CAST(event_id AS TEXT) AS source_id, request_id, account_id, key_id, event_type AS status, 0 AS tokens FROM api_key_events
				UNION ALL
				SELECT created_at, 60 AS source_rank, 'feedback' AS event_type, event_id AS source_id, request_id, account_id, '' AS key_id, scope AS status, 0 AS tokens FROM feedback_events
			UNION ALL
			SELECT created_at, 50 AS source_rank, event_type, event_id AS source_id, request_id, account_id, '' AS key_id, actor AS status, 0 AS tokens FROM audit_events
			UNION ALL
			SELECT created_at, 40 AS source_rank, 'capacity_signal' AS event_type, event_id AS source_id, '' AS request_id, '' AS account_id, '' AS key_id, signal AS status, 0 AS tokens FROM capacity_signal_events
			UNION ALL
			SELECT created_at, 30 AS source_rank, 'signup' AS event_type, event_id AS source_id, '' AS request_id, account_id, '' AS key_id, provider AS status, 0 AS tokens FROM signup_events
			UNION ALL
			SELECT created_at, 20 AS source_rank, 'demo_usage' AS event_type, request_id AS source_id, request_id, '' AS account_id, '' AS key_id, 'demo' AS status, total_tokens AS tokens FROM demo_usage_events
			UNION ALL
			SELECT created_at, 10 AS source_rank, 'demo_session' AS event_type, event_id AS source_id, '' AS request_id, '' AS account_id, '' AS key_id, 'demo' AS status, 0 AS tokens FROM demo_session_events
		)
		WHERE created_at >= ? AND created_at < ?
		  AND (? = '' OR event_type = ?)
		  AND (? = '' OR account_id = ?)
		  AND (? = '' OR request_id = ?)
		  AND (? = '' OR
		       (? = 0 AND (created_at < ? OR (created_at = ? AND source_rank < ?) OR (created_at = ? AND source_rank = ? AND source_id < ?))) OR
		       (? = 1 AND (created_at > ? OR (created_at = ? AND source_rank > ?) OR (created_at = ? AND source_rank = ? AND source_id > ?))))
			ORDER BY
				CASE WHEN ? = 1 THEN created_at END ASC,
				CASE WHEN ? = 1 THEN source_rank END ASC,
				CASE WHEN ? = 1 THEN source_id END ASC,
				CASE WHEN ? = 0 THEN created_at END DESC,
				CASE WHEN ? = 0 THEN source_rank END DESC,
				CASE WHEN ? = 0 THEN source_id END DESC
			LIMIT ?`,
		encodeTime(q.From), encodeTime(q.To), q.Type, q.Type, q.AccountID, q.AccountID, q.RequestID, q.RequestID,
		cursor.TS, boolInt(newer), cursor.TS, cursor.TS, cursor.Rank, cursor.TS, cursor.Rank, cursor.ID,
		boolInt(newer), cursor.TS, cursor.TS, cursor.Rank, cursor.TS, cursor.Rank, cursor.ID,
		boolInt(newer), boolInt(newer), boolInt(newer), boolInt(newer), boolInt(newer), boolInt(newer), q.Limit+1)
	if err != nil {
		return storage.ExplorerActivityList{}, err
	}
	defer rows.Close()
	out := storage.ExplorerActivityList{Partial: false, Error: nil}
	for rows.Next() {
		var created, eventType, sourceID, requestID, accountID, keyID, status string
		var rank int
		var tokens int64
		if err := rows.Scan(&created, &rank, &eventType, &sourceID, &requestID, &accountID, &keyID, &status, &tokens); err != nil {
			return storage.ExplorerActivityList{}, err
		}
		t := decodeTime(created)
		ev := storage.ExplorerActivityEvent{
			EventTimeUTC: t,
			EventType:    eventType,
			Severity:     severityFor(eventType, status),
			Source:       "gateway",
			SourceID:     sourceID,
			LinkTarget:   linkTarget(eventType, requestID, accountID),
			Cursor:       encodeActivityCursor(t, rank, eventType, sourceID),
		}
		if requestID != "" {
			ev.RequestID = &requestID
		}
		if accountID != "" {
			ev.AccountID = &accountID
		}
		if keyID != "" {
			ev.KeyID = &keyID
		}
		if status != "" {
			ev.Status = &status
		}
		if tokens > 0 {
			ev.Tokens = &tokens
		}
		out.Items = append(out.Items, ev)
	}
	if err := rows.Err(); err != nil {
		return storage.ExplorerActivityList{}, err
	}
	if len(out.Items) > q.Limit {
		next := out.Items[q.Limit-1].Cursor
		out.NextCursor = &next
		out.Items = out.Items[:q.Limit]
	}
	if len(out.Items) > 0 {
		latestIndex := 0
		if newer {
			latestIndex = len(out.Items) - 1
		}
		latest := out.Items[latestIndex].Cursor
		out.LatestCursor = &latest
	}
	return out, nil
}

func (s *Store) ExplorerHealth(ctx context.Context, since time.Time) (storage.ExplorerHealth, error) {
	out := storage.ExplorerHealth{CheckedAtUTC: time.Now().UTC(), GatewayHealth: "ok", PublicStatus: "ok"}
	tier, err := s.GetCapacityTier(ctx)
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.CapacityTier = tier.Tier
	out.CapacitySignalsFiring, err = s.count(ctx, `SELECT COUNT(*) FROM capacity_signal_events WHERE firing = 1`)
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.ActiveAccountsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM accounts WHERE status = 'active'`)
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.NewAccountsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM accounts WHERE created_at >= ?`, encodeTime(since))
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.ActiveAPIKeys, err = s.count(ctx, `SELECT COUNT(*) FROM api_keys WHERE status = 'active'`)
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.ActiveQuotaReservations, err = s.count(ctx, `SELECT COUNT(*) FROM quota_reservations WHERE status = 'active'`)
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.ExpiredQuotaReservations, err = s.count(ctx, `SELECT COUNT(*) FROM quota_reservations WHERE status = 'expired'`)
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.ActiveConcurrencyReservations, err = s.count(ctx, `SELECT COUNT(*) FROM concurrency_reservations WHERE status = 'active'`)
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.UsageEventsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM usage_events WHERE created_at >= ?`, encodeTime(since))
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.DemoUsageEventsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM demo_usage_events WHERE created_at >= ?`, encodeTime(since))
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.QuotaReservationsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM quota_reservations WHERE created_at >= ?`, encodeTime(since))
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.SignupEventsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM signup_events WHERE created_at >= ?`, encodeTime(since))
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.FeedbackEventsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM feedback_events WHERE created_at >= ?`, encodeTime(since))
	if err != nil {
		return storage.ExplorerHealth{}, err
	}
	out.AuditEventsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM audit_events WHERE created_at >= ?`, encodeTime(since))
	return out, err
}

func (s *Store) explorerBuyerByID(ctx context.Context, accountID string, from, to time.Time) (storage.ExplorerBuyerSummary, error) {
	list, err := s.ExplorerListBuyers(ctx, storage.ExplorerBuyerQuery{From: from, To: to, AccountID: accountID, Limit: 1})
	if err != nil {
		return storage.ExplorerBuyerSummary{}, err
	}
	if len(list.Items) == 0 {
		return storage.ExplorerBuyerSummary{}, storage.ErrNotFound
	}
	return list.Items[0], nil
}

func (s *Store) explorerIdentities(ctx context.Context, accountID string) ([]storage.ExplorerIdentity, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT provider, provider_user_id, email, created_at
		FROM account_identities
		WHERE account_id = ?
		ORDER BY provider, provider_user_id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storage.ExplorerIdentity
	for rows.Next() {
		var item storage.ExplorerIdentity
		var created string
		if err := rows.Scan(&item.Provider, &item.ProviderUserID, &item.Email, &created); err != nil {
			return nil, err
		}
		item.CreatedAt = decodeTime(created)
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) explorerAPIKeys(ctx context.Context, accountID string) ([]storage.ExplorerAPIKey, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT key_id, key_hash_prefix, status, created_at, revoked_at
		FROM api_keys
		WHERE account_id = ?
		ORDER BY created_at DESC, key_id DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storage.ExplorerAPIKey
	for rows.Next() {
		var item storage.ExplorerAPIKey
		var created, revoked string
		if err := rows.Scan(&item.KeyID, &item.KeyHashPrefix, &item.Status, &created, &revoked); err != nil {
			return nil, err
		}
		item.CreatedAt = decodeTime(created)
		item.RevokedAt = nullableTime(revoked)
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) explorerBuyerRollup(ctx context.Context, from, to time.Time) (storage.ExplorerBuyerRollup, error) {
	var out storage.ExplorerBuyerRollup
	var err error
	out.ActiveAccountsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM accounts WHERE status = 'active'`)
	if err != nil {
		return out, err
	}
	out.NewAccountsWindow, err = s.count(ctx, `SELECT COUNT(*) FROM accounts WHERE created_at >= ? AND created_at < ?`, encodeTime(from), encodeTime(to))
	if err != nil {
		return out, err
	}
	out.ActiveAPIKeys, err = s.count(ctx, `SELECT COUNT(*) FROM api_keys WHERE status = 'active'`)
	if err != nil {
		return out, err
	}
	out.BlockedAccounts, err = s.count(ctx, `SELECT COUNT(*) FROM accounts WHERE status = 'blocked'`)
	return out, err
}

func (s *Store) explorerUsageEvents(ctx context.Context, accountID, requestID string, from, to time.Time, limit int) ([]storage.ExplorerUsageEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT request_id, account_id, demo_identity, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at
		FROM usage_events
		WHERE (? = '' OR account_id = ?)
		  AND (? = '' OR request_id = ?)
		  AND (? = '' OR created_at >= ?)
		  AND (? = '' OR created_at < ?)
		ORDER BY created_at DESC, request_id DESC
		LIMIT ?`, accountID, accountID, requestID, requestID, timeParam(from), timeParam(from), timeParam(to), timeParam(to), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storage.ExplorerUsageEvent
	for rows.Next() {
		item, err := scanUsage(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) explorerQuotaReservations(ctx context.Context, accountID, requestID string, from, to time.Time, limit int) ([]storage.ExplorerQuotaReservation, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT account_id, request_id, window_date, reserved_tokens, settled_tokens, status, expires_at, created_at, settled_at
		FROM quota_reservations
		WHERE (? = '' OR account_id = ?)
		  AND (? = '' OR request_id = ?)
		  AND (? = '' OR created_at >= ?)
		  AND (? = '' OR created_at < ?)
		ORDER BY created_at DESC, request_id DESC
		LIMIT ?`, accountID, accountID, requestID, requestID, timeParam(from), timeParam(from), timeParam(to), timeParam(to), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storage.ExplorerQuotaReservation
	for rows.Next() {
		var item storage.ExplorerQuotaReservation
		var expires, created, settled string
		if err := rows.Scan(&item.AccountID, &item.RequestID, &item.WindowDate, &item.ReservedTokens, &item.SettledTokens, &item.Status, &expires, &created, &settled); err != nil {
			return nil, err
		}
		item.ExpiresAt = decodeTime(expires)
		item.CreatedAt = decodeTime(created)
		item.SettledAt = nullableTime(settled)
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) explorerConcurrencyReservations(ctx context.Context, accountID, requestID string, from, to time.Time, limit int) ([]storage.ExplorerConcurrencyReservation, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT account_id, request_id, status, expires_at, created_at, released_at
		FROM concurrency_reservations
		WHERE (? = '' OR account_id = ?)
		  AND (? = '' OR request_id = ?)
		  AND (? = '' OR created_at >= ?)
		  AND (? = '' OR created_at < ?)
		ORDER BY created_at DESC, request_id DESC
		LIMIT ?`, accountID, accountID, requestID, requestID, timeParam(from), timeParam(from), timeParam(to), timeParam(to), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storage.ExplorerConcurrencyReservation
	for rows.Next() {
		var item storage.ExplorerConcurrencyReservation
		var expires, created, released string
		if err := rows.Scan(&item.AccountID, &item.RequestID, &item.Status, &expires, &created, &released); err != nil {
			return nil, err
		}
		item.ExpiresAt = decodeTime(expires)
		item.CreatedAt = decodeTime(created)
		item.ReleasedAt = nullableTime(released)
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) explorerFeedbackEvents(ctx context.Context, accountID, requestID string, from, to time.Time, limit int) ([]storage.ExplorerFeedbackEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT event_id, request_id, account_id, scope, rating, comment, created_at
		FROM feedback_events
		WHERE (? = '' OR account_id = ?)
		  AND (? = '' OR request_id = ?)
		  AND (? = '' OR created_at >= ?)
		  AND (? = '' OR created_at < ?)
		ORDER BY created_at DESC, event_id DESC
		LIMIT ?`, accountID, accountID, requestID, requestID, timeParam(from), timeParam(from), timeParam(to), timeParam(to), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storage.ExplorerFeedbackEvent
	for rows.Next() {
		var item storage.ExplorerFeedbackEvent
		var created string
		if err := rows.Scan(&item.EventID, &item.RequestID, &item.AccountID, &item.Scope, &item.Rating, &item.Comment, &created); err != nil {
			return nil, err
		}
		item.CreatedAt = decodeTime(created)
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) explorerAuditEvents(ctx context.Context, accountID, requestID string, from, to time.Time, limit int) ([]storage.ExplorerAuditEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT event_id, request_id, account_id, actor, event_type, payload_json, created_at
		FROM audit_events
		WHERE (? = '' OR account_id = ?)
		  AND (? = '' OR request_id = ?)
		  AND (? = '' OR created_at >= ?)
		  AND (? = '' OR created_at < ?)
		ORDER BY created_at DESC, event_id DESC
		LIMIT ?`, accountID, accountID, requestID, requestID, timeParam(from), timeParam(from), timeParam(to), timeParam(to), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storage.ExplorerAuditEvent
	for rows.Next() {
		var item storage.ExplorerAuditEvent
		var created string
		if err := rows.Scan(&item.EventID, &item.RequestID, &item.AccountID, &item.Actor, &item.EventType, &item.PayloadJSON, &created); err != nil {
			return nil, err
		}
		item.CreatedAt = decodeTime(created)
		out = append(out, item)
	}
	return out, rows.Err()
}

func scanUsage(rows interface {
	Scan(dest ...any) error
}) (storage.ExplorerUsageEvent, error) {
	var item storage.ExplorerUsageEvent
	var created string
	err := rows.Scan(&item.RequestID, &item.AccountID, &item.DemoIdentity, &item.WindowDate, &item.PromptTokens, &item.CompletionTokens, &item.TotalTokens, &item.TokenSource, &item.Outcome, &created)
	item.CreatedAt = decodeTime(created)
	return item, err
}

func (s *Store) count(ctx context.Context, query string, args ...any) (int, error) {
	var n int
	if err := s.db.QueryRowContext(ctx, query, args...).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

func foldEmail(v string) string {
	return strings.ToLower(strings.TrimSpace(v))
}

func hasUpperASCII(v string) bool {
	for _, ch := range v {
		if ch >= 'A' && ch <= 'Z' {
			return true
		}
	}
	return false
}

func nullableTime(v string) *time.Time {
	if v == "" {
		return nil
	}
	t := decodeTime(v)
	return &t
}

func timeParam(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return encodeTime(t)
}

func encodeListID(id string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(id))
}

func decodeListID(raw string) (string, error) {
	if raw == "" {
		return "", nil
	}
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return "", storage.ErrBadCursor
	}
	return string(b), nil
}

func encodeListCursor(ts time.Time, id string) string {
	b, _ := json.Marshal(listCursor{TS: encodeTime(ts), ID: id})
	return base64.RawURLEncoding.EncodeToString(b)
}

func decodeListCursor(raw string) (listCursor, error) {
	if raw == "" {
		return listCursor{}, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return listCursor{}, storage.ErrBadCursor
	}
	var c listCursor
	if err := json.Unmarshal(b, &c); err != nil {
		return listCursor{}, storage.ErrBadCursor
	}
	if c.TS == "" || c.ID == "" {
		return listCursor{}, storage.ErrBadCursor
	}
	return c, nil
}

func encodeActivityCursor(ts time.Time, rank int, source, id string) string {
	b, _ := json.Marshal(activityCursor{TS: encodeTime(ts), Rank: rank, Source: source, ID: id})
	return base64.RawURLEncoding.EncodeToString(b)
}

func decodeActivityCursor(raw string) (activityCursor, error) {
	if raw == "" {
		return activityCursor{}, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return activityCursor{}, storage.ErrBadCursor
	}
	var c activityCursor
	if err := json.Unmarshal(b, &c); err != nil {
		return activityCursor{}, storage.ErrBadCursor
	}
	if c.TS == "" || c.ID == "" {
		return activityCursor{}, storage.ErrBadCursor
	}
	return c, nil
}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func severityFor(eventType, status string) string {
	if strings.Contains(eventType, "error") || strings.Contains(status, "blocked") || strings.Contains(status, "failed") {
		return "error"
	}
	return "info"
}

func linkTarget(eventType, requestID, accountID string) string {
	if requestID != "" {
		return "session:" + requestID
	}
	if accountID != "" {
		return "buyer:" + accountID
	}
	if strings.HasPrefix(eventType, "demo") {
		return ""
	}
	return "gateway:" + eventType
}
