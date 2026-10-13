package rewards

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// SPEC-050 MALIBU stake ledger. MALIBU an account's providers hold in the
// SPEC-021 ledger can be locked into a stake; the stake sizes a daily
// inference allowance owned by billing. This file is the v0.1 "ledger MALIBU"
// stake source (SPEC-050-R001). It writes only malibu_stake_events and never a
// provider_rewards_ledger row.

// MALIBUUnitsPerToken is the stake ledger's integer scale: 1 MALIBU = 1e8
// units, the NUMERIC(24,8) scale of provider_rewards_ledger.amount_malibu.
const MALIBUUnitsPerToken int64 = 100_000_000

// MaxStakeAmountUnits bounds one lock or unlock (10,000,000,000 MALIBU) so
// every sum stays inside int64.
const MaxStakeAmountUnits int64 = 10_000_000_000 * MALIBUUnitsPerToken

const (
	stakeEventLock   = "lock"
	stakeEventUnlock = "unlock"
)

var (
	ErrStakeInvalidAmount      = errors.New("stake: invalid MALIBU amount")
	ErrStakeNoGitHubIdentity   = errors.New("stake: account has no linked GitHub identity")
	ErrStakeNoOwnedProviders   = errors.New("stake: account owns no provider")
	ErrStakeInsufficient       = errors.New("stake: not enough MALIBU")
	ErrStakeIdempotencyReused  = errors.New("stake: idempotency key reused with a different request")
	ErrStakeInvalidIdempotency = errors.New("stake: invalid idempotency key")
	ErrStakeInvalidAccount     = errors.New("stake: invalid account")
	ErrStakeRateLimited        = errors.New("stake: too many stake changes in the last 24 hours")
	ErrStakeIdentityChanged    = errors.New("stake: account already staked under a different GitHub identity")
	ErrStakeAccountBound       = errors.New("stake: account stake would exceed its bound")
)

// maxStakeEventsPerDay bounds how many lock and unlock events one account
// may append in a rolling 24 hours, so the append-only ledger cannot be
// grown without limit by one account.
const maxStakeEventsPerDay = 200

var (
	stakeAmountPattern      = regexp.MustCompile(`^(0|[1-9][0-9]{0,10})(\.[0-9]{1,8})?$`)
	stakeIdempotencyPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
)

// ParseMALIBUUnits parses a positive decimal MALIBU string with at most 8
// fractional digits into ledger units.
func ParseMALIBUUnits(raw string) (int64, error) {
	if !stakeAmountPattern.MatchString(raw) {
		return 0, ErrStakeInvalidAmount
	}
	whole, frac, _ := strings.Cut(raw, ".")
	w, err := strconv.ParseInt(whole, 10, 64)
	if err != nil {
		return 0, ErrStakeInvalidAmount
	}
	frac = (frac + "00000000")[:8]
	f, err := strconv.ParseInt(frac, 10, 64)
	if err != nil {
		return 0, ErrStakeInvalidAmount
	}
	if w > MaxStakeAmountUnits/MALIBUUnitsPerToken {
		return 0, ErrStakeInvalidAmount
	}
	units := w*MALIBUUnitsPerToken + f
	if units <= 0 || units > MaxStakeAmountUnits {
		return 0, ErrStakeInvalidAmount
	}
	return units, nil
}

// FormatMALIBUUnits renders ledger units as a fixed 8-decimal MALIBU string.
func FormatMALIBUUnits(units int64) string {
	sign := ""
	if units < 0 {
		sign, units = "-", -units
	}
	return fmt.Sprintf("%s%d.%08d", sign, units/MALIBUUnitsPerToken, units%MALIBUUnitsPerToken)
}

// ProviderOwnerFunc returns the GitHub user id that owns a provider
// (provider_ownership in the coordinator SQLite DB).
type ProviderOwnerFunc func(ctx context.Context, providerID string) (githubUserID int64, ok bool, err error)

// StakeEvent is one append-only stake ledger row.
type StakeEvent struct {
	ID           int64
	AccountID    string
	GitHubUserID int64
	ProviderID   string
	EventType    string
	AmountUnits  int64
	CreatedAt    time.Time
	ReleaseAt    *time.Time
}

// StakeRequest is a lock or unlock. OwnedProviderIDs is the caller's current
// provider_ownership list for GitHubUserID; it bounds which MALIBU a lock may
// take and is ignored by unlock (a former owner can always unlock its own
// stake).
type StakeRequest struct {
	AccountID        string
	GitHubUserID     int64
	OwnedProviderIDs []string
	AmountUnits      int64
	IdempotencyKey   string
}

// StakeResult is the outcome of a lock or unlock. Replayed is true when the
// idempotency key had already been applied to the same request.
type StakeResult struct {
	Events   []StakeEvent
	Replayed bool
}

// StakePosition is an account's stake as the account view shows it.
type StakePosition struct {
	StakedUnits    int64 // locked and not unlocking (earning or maturing)
	UnlockingUnits int64 // unlocked, still inside the cooldown
	AvailableUnits int64 // withdrawable MALIBU of owned providers not locked by anyone
	NextReleaseAt  *time.Time
}

// AccountStake is one account's earning stake for a UTC day.
// GitHubUserID is the identity that owns the providers behind the stake.
type AccountStake struct {
	AccountID    string
	GitHubUserID int64
	Units        int64
}

// StakeLedger reads and appends malibu_stake_events through the
// rewards_writer pool.
type StakeLedger struct {
	db       *sql.DB
	cooldown time.Duration
	owner    ProviderOwnerFunc
	now      func() time.Time
}

// NewStakeLedger builds the ledger MALIBU stake source.
func NewStakeLedger(db *sql.DB, cooldown time.Duration, owner ProviderOwnerFunc) (*StakeLedger, error) {
	if db == nil {
		return nil, errors.New("stake: rewards database is required")
	}
	if cooldown <= 0 {
		return nil, errors.New("stake: unlock cooldown must be positive")
	}
	if owner == nil {
		return nil, errors.New("stake: provider owner lookup is required")
	}
	return &StakeLedger{db: db, cooldown: cooldown, owner: owner, now: func() time.Time { return time.Now().UTC() }}, nil
}

// SetNowForTest pins the ledger clock.
func (l *StakeLedger) SetNowForTest(now func() time.Time) { l.now = now }

// Name identifies the stake source in refresh audit records.
func (l *StakeLedger) Name() string { return "ledger_malibu_v1" }

func stakeRequestDigest(kind string, req StakeRequest) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s|%s|%d|%d", kind, req.AccountID, req.GitHubUserID, req.AmountUnits)))
	return hex.EncodeToString(sum[:])
}

func validateStakeRequest(req StakeRequest, needIdentity bool) error {
	if req.AccountID == "" || len(req.AccountID) > 128 {
		return ErrStakeInvalidAccount
	}
	if needIdentity && req.GitHubUserID <= 0 {
		return ErrStakeNoGitHubIdentity
	}
	if !stakeIdempotencyPattern.MatchString(req.IdempotencyKey) {
		return ErrStakeInvalidIdempotency
	}
	if req.AmountUnits <= 0 || req.AmountUnits > MaxStakeAmountUnits {
		return ErrStakeInvalidAmount
	}
	return nil
}

// Ledger aggregates are summed as NUMERIC in Postgres and clamped into int64
// before the cast, so no account or provider total can overflow.
const clampInt64 = `LEAST(GREATEST(%s, 0), 9223372036854775807)::BIGINT`

// withdrawableUnitsSQL is SPEC-021's canonical withdrawability predicate
// summed for one provider, in ledger units, before netting stake locks.
var withdrawableUnitsSQL = `
SELECT ` + fmt.Sprintf(clampInt64, `COALESCE(FLOOR(SUM(prl.amount_malibu) FILTER (
           WHERE prl.withdrawal_hold_reason IS NULL
             AND prl.amount_malibu > 0
             AND NOT prl.epoch_disposition_blocked
       ) * 100000000), 0)`) + `
  FROM malibu_rewards_ledger_with_disposition prl
 WHERE prl.provider_id = $1
   AND prl.amount_malibu IS NOT NULL`

// lockedUnitsSQL is all MALIBU still locked on a provider at $2: every lock
// minus unlocks whose cooldown has ended (SPEC-050-R003). Withdrawal netting
// uses it, so even a lock placed by a former owner keeps MALIBU out of a
// withdrawal.
var lockedUnitsSQL = `
SELECT ` + fmt.Sprintf(clampInt64, `COALESCE(SUM(CASE
           WHEN event_type = 'lock' THEN amount_units
           WHEN release_at <= $2 THEN -amount_units
           ELSE 0 END), 0)`) + `
  FROM malibu_stake_events
 WHERE provider_id = $1`

// ownerLockedUnitsSQL counts only locks placed by the provider's current
// owner $3 (SPEC-050-R002): a lock is effective only while the provider is
// owned by the identity that placed it, so a former owner's lock can neither
// earn nor keep the current owner from staking.
var ownerLockedUnitsSQL = `
SELECT ` + fmt.Sprintf(clampInt64, `COALESCE(SUM(CASE
           WHEN event_type = 'lock' THEN amount_units
           WHEN release_at <= $2 THEN -amount_units
           ELSE 0 END), 0)`) + `
  FROM malibu_stake_events
 WHERE provider_id = $1 AND github_user_id = $3`

func saturatingAdd(a, b int64) int64 {
	if b > 0 && a > (1<<63-1)-b {
		return 1<<63 - 1
	}
	return a + b
}

type queryRower interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func providerWithdrawableUnits(ctx context.Context, q queryRower, providerID string) (int64, error) {
	var units int64
	if err := q.QueryRowContext(ctx, withdrawableUnitsSQL, providerID).Scan(&units); err != nil {
		return 0, fmt.Errorf("stake: withdrawable MALIBU: %w", err)
	}
	return units, nil
}

func providerOwnerLockedUnits(ctx context.Context, q queryRower, providerID string, owner int64, now time.Time) (int64, error) {
	var units int64
	if err := q.QueryRowContext(ctx, ownerLockedUnitsSQL, providerID, now, owner).Scan(&units); err != nil {
		return 0, fmt.Errorf("stake: locked MALIBU: %w", err)
	}
	return units, nil
}

// accountIdentity is the one GitHub identity an account has staked under,
// or 0 before its first lock (SPEC-050-R002: the identity is fixed).
func accountIdentity(ctx context.Context, q interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}, accountID string) (int64, error) {
	rows, err := q.QueryContext(ctx, `SELECT DISTINCT github_user_id FROM malibu_stake_events WHERE account_id = $1 LIMIT 2`, accountID)
	if err != nil {
		return 0, fmt.Errorf("stake: account identity: %w", err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return 0, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	switch len(ids) {
	case 0:
		return 0, nil
	case 1:
		return ids[0], nil
	}
	return 0, ErrStakeIdentityChanged
}

// replay returns the events already written for (account, key). A different
// request under the same key is ErrStakeIdempotencyReused.
func replayStakeEvents(ctx context.Context, tx *sql.Tx, accountID, key, digest string) ([]StakeEvent, bool, error) {
	rows, err := tx.QueryContext(ctx, `
        SELECT id, account_id, github_user_id, provider_id, event_type, amount_units, created_at, release_at, request_digest
          FROM malibu_stake_events
         WHERE account_id = $1 AND idempotency_key = $2
         ORDER BY id`, accountID, key)
	if err != nil {
		return nil, false, fmt.Errorf("stake: replay lookup: %w", err)
	}
	defer rows.Close()
	var events []StakeEvent
	for rows.Next() {
		var ev StakeEvent
		var release sql.NullTime
		var gotDigest string
		if err := rows.Scan(&ev.ID, &ev.AccountID, &ev.GitHubUserID, &ev.ProviderID, &ev.EventType, &ev.AmountUnits, &ev.CreatedAt, &release, &gotDigest); err != nil {
			return nil, false, err
		}
		if gotDigest != digest {
			return nil, false, ErrStakeIdempotencyReused
		}
		if release.Valid {
			t := release.Time.UTC()
			ev.ReleaseAt = &t
		}
		ev.CreatedAt = ev.CreatedAt.UTC()
		events = append(events, ev)
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	return events, len(events) > 0, nil
}

func lockAdvisory(ctx context.Context, tx *sql.Tx, key string) error {
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, key)
	return err
}

func (l *StakeLedger) begin(ctx context.Context, accountID string) (*sql.Tx, error) {
	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("stake: begin: %w", err)
	}
	// One stake mutation per account at a time, so a concurrent retry of the
	// same idempotency key waits and then replays.
	if err := lockAdvisory(ctx, tx, "malibu_stake_account:"+accountID); err != nil {
		_ = tx.Rollback()
		return nil, fmt.Errorf("stake: account lock: %w", err)
	}
	return tx, nil
}

func insertStakeEvent(ctx context.Context, tx *sql.Tx, ev StakeEvent, key, digest string) (StakeEvent, error) {
	var release any
	if ev.ReleaseAt != nil {
		release = *ev.ReleaseAt
	}
	err := tx.QueryRowContext(ctx, `
        INSERT INTO malibu_stake_events
            (account_id, github_user_id, provider_id, event_type, amount_units, created_at, release_at, idempotency_key, request_digest)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        RETURNING id`,
		ev.AccountID, ev.GitHubUserID, ev.ProviderID, ev.EventType, ev.AmountUnits, ev.CreatedAt, release, key, digest).Scan(&ev.ID)
	if err != nil {
		return StakeEvent{}, fmt.Errorf("stake: insert event: %w", err)
	}
	return ev, nil
}

// checkStakeRate refuses a change that would take the account past
// maxStakeEventsPerDay events in a rolling 24 hours, counting every event the
// change appends.
func (l *StakeLedger) checkStakeRate(ctx context.Context, tx *sql.Tx, accountID string, adding int) error {
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM malibu_stake_events WHERE account_id = $1 AND created_at > $2`,
		accountID, l.now().Add(-24*time.Hour)).Scan(&n); err != nil {
		return fmt.Errorf("stake: rate check: %w", err)
	}
	if n+adding > maxStakeEventsPerDay {
		return ErrStakeRateLimited
	}
	return nil
}

type stakeSlice struct {
	ProviderID string
	Units      int64
}

// allocateStake takes amount from slices in the given order. It returns
// ErrStakeInsufficient, and no allocation, when the slices cannot cover it.
func allocateStake(slices []stakeSlice, amount int64) ([]stakeSlice, error) {
	var out []stakeSlice
	remaining := amount
	for _, s := range slices {
		if remaining == 0 {
			break
		}
		if s.Units <= 0 {
			continue
		}
		take := s.Units
		if take > remaining {
			take = remaining
		}
		out = append(out, stakeSlice{ProviderID: s.ProviderID, Units: take})
		remaining -= take
	}
	if remaining > 0 {
		return nil, ErrStakeInsufficient
	}
	return out, nil
}

func sortedUniqueProviders(ids []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// Lock moves withdrawable MALIBU of the account's owned providers into its
// stake, in ascending provider_id order (SPEC-050-R002). Each provider is
// held under an advisory lock while its ownership is re-read, "withdrawable
// minus locked" is computed, and the event is inserted, so no two locks can
// take the same MALIBU and a stale ownership list cannot lock a provider the
// account no longer owns.
func (l *StakeLedger) Lock(ctx context.Context, req StakeRequest) (StakeResult, error) {
	if err := validateStakeRequest(req, true); err != nil {
		return StakeResult{}, err
	}
	digest := stakeRequestDigest(stakeEventLock, req)
	tx, err := l.begin(ctx, req.AccountID)
	if err != nil {
		return StakeResult{}, err
	}
	defer tx.Rollback()
	if events, ok, err := replayStakeEvents(ctx, tx, req.AccountID, req.IdempotencyKey, digest); err != nil || ok {
		return StakeResult{Events: events, Replayed: ok}, err
	}
	identity, err := accountIdentity(ctx, tx, req.AccountID)
	if err != nil {
		return StakeResult{}, err
	}
	if identity != 0 && identity != req.GitHubUserID {
		return StakeResult{}, ErrStakeIdentityChanged
	}
	var staked int64
	if err := tx.QueryRowContext(ctx, `SELECT `+fmt.Sprintf(clampInt64, `COALESCE(SUM(CASE WHEN event_type = 'lock' THEN amount_units ELSE -amount_units END), 0)`)+`
          FROM malibu_stake_events WHERE account_id = $1`, req.AccountID).Scan(&staked); err != nil {
		return StakeResult{}, fmt.Errorf("stake: account stake: %w", err)
	}
	if staked > MaxStakeAmountUnits-req.AmountUnits {
		return StakeResult{}, ErrStakeAccountBound
	}
	owned := sortedUniqueProviders(req.OwnedProviderIDs)
	if len(owned) == 0 {
		return StakeResult{}, ErrStakeNoOwnedProviders
	}
	now := l.now()
	slices := make([]stakeSlice, 0, len(owned))
	for _, providerID := range owned {
		if err := lockAdvisory(ctx, tx, "malibu_stake_provider:"+providerID); err != nil {
			return StakeResult{}, fmt.Errorf("stake: provider lock: %w", err)
		}
		owner, ok, err := l.owner(ctx, providerID)
		if err != nil {
			return StakeResult{}, fmt.Errorf("stake: provider owner: %w", err)
		}
		if !ok || owner != req.GitHubUserID {
			continue
		}
		withdrawable, err := providerWithdrawableUnits(ctx, tx, providerID)
		if err != nil {
			return StakeResult{}, err
		}
		locked, err := providerOwnerLockedUnits(ctx, tx, providerID, owner, now)
		if err != nil {
			return StakeResult{}, err
		}
		slices = append(slices, stakeSlice{ProviderID: providerID, Units: withdrawable - locked})
	}
	if len(slices) == 0 {
		return StakeResult{}, ErrStakeNoOwnedProviders
	}
	alloc, err := allocateStake(slices, req.AmountUnits)
	if err != nil {
		return StakeResult{}, err
	}
	if err := l.checkStakeRate(ctx, tx, req.AccountID, len(alloc)); err != nil {
		return StakeResult{}, err
	}
	var events []StakeEvent
	for _, a := range alloc {
		ev, err := insertStakeEvent(ctx, tx, StakeEvent{
			AccountID: req.AccountID, GitHubUserID: req.GitHubUserID, ProviderID: a.ProviderID,
			EventType: stakeEventLock, AmountUnits: a.Units, CreatedAt: now,
		}, req.IdempotencyKey, digest)
		if err != nil {
			return StakeResult{}, err
		}
		events = append(events, ev)
	}
	if err := tx.Commit(); err != nil {
		return StakeResult{}, fmt.Errorf("stake: commit: %w", err)
	}
	return StakeResult{Events: events}, nil
}

// accountStakeByProvider is each provider's current (locked minus unlocked)
// stake of the account.
func accountStakeByProvider(ctx context.Context, q interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}, accountID string) ([]stakeSlice, error) {
	rows, err := q.QueryContext(ctx, `
        SELECT provider_id,
               `+fmt.Sprintf(clampInt64, `COALESCE(SUM(CASE WHEN event_type = 'lock' THEN amount_units ELSE -amount_units END), 0)`)+`
          FROM malibu_stake_events
         WHERE account_id = $1
         GROUP BY provider_id
         ORDER BY provider_id DESC`, accountID)
	if err != nil {
		return nil, fmt.Errorf("stake: account stake: %w", err)
	}
	defer rows.Close()
	var out []stakeSlice
	for rows.Next() {
		var s stakeSlice
		if err := rows.Scan(&s.ProviderID, &s.Units); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// Unlock stops stake earning from the next refresh and releases it after the
// cooldown (SPEC-050-R004), taking providers in descending provider_id order.
// It needs no current GitHub link: the account unlocks under the identity it
// staked with, whoever owns the providers now.
func (l *StakeLedger) Unlock(ctx context.Context, req StakeRequest) (StakeResult, error) {
	if err := validateStakeRequest(req, false); err != nil {
		return StakeResult{}, err
	}
	tx, err := l.begin(ctx, req.AccountID)
	if err != nil {
		return StakeResult{}, err
	}
	defer tx.Rollback()
	identity, err := accountIdentity(ctx, tx, req.AccountID)
	if err != nil {
		return StakeResult{}, err
	}
	if identity == 0 {
		return StakeResult{}, ErrStakeInsufficient
	}
	req.GitHubUserID = identity
	digest := stakeRequestDigest(stakeEventUnlock, req)
	if events, ok, err := replayStakeEvents(ctx, tx, req.AccountID, req.IdempotencyKey, digest); err != nil || ok {
		return StakeResult{Events: events, Replayed: ok}, err
	}
	stakes, err := accountStakeByProvider(ctx, tx, req.AccountID)
	if err != nil {
		return StakeResult{}, err
	}
	alloc, err := allocateStake(stakes, req.AmountUnits)
	if err != nil {
		return StakeResult{}, err
	}
	if err := l.checkStakeRate(ctx, tx, req.AccountID, len(alloc)); err != nil {
		return StakeResult{}, err
	}
	now := l.now()
	release := now.Add(l.cooldown)
	var events []StakeEvent
	for _, a := range alloc {
		ev, err := insertStakeEvent(ctx, tx, StakeEvent{
			AccountID: req.AccountID, GitHubUserID: identity, ProviderID: a.ProviderID,
			EventType: stakeEventUnlock, AmountUnits: a.Units, CreatedAt: now, ReleaseAt: &release,
		}, req.IdempotencyKey, digest)
		if err != nil {
			return StakeResult{}, err
		}
		events = append(events, ev)
	}
	if err := tx.Commit(); err != nil {
		return StakeResult{}, fmt.Errorf("stake: commit: %w", err)
	}
	return StakeResult{Events: events}, nil
}

// Position reports the account's stake for the account view.
func (l *StakeLedger) Position(ctx context.Context, accountID string, ownedProviderIDs []string) (StakePosition, error) {
	now := l.now()
	var pos StakePosition
	var next sql.NullTime
	if err := l.db.QueryRowContext(ctx, `
        SELECT `+fmt.Sprintf(clampInt64, `COALESCE(SUM(CASE WHEN event_type = 'lock' THEN amount_units ELSE -amount_units END), 0)`)+`,
               `+fmt.Sprintf(clampInt64, `COALESCE(SUM(amount_units) FILTER (WHERE event_type = 'unlock' AND release_at > $2), 0)`)+`,
               MIN(release_at) FILTER (WHERE event_type = 'unlock' AND release_at > $2)
          FROM malibu_stake_events
         WHERE account_id = $1`, accountID, now).Scan(&pos.StakedUnits, &pos.UnlockingUnits, &next); err != nil {
		return StakePosition{}, fmt.Errorf("stake: position: %w", err)
	}
	if next.Valid {
		t := next.Time.UTC()
		pos.NextReleaseAt = &t
	}
	for _, providerID := range sortedUniqueProviders(ownedProviderIDs) {
		owner, ok, err := l.owner(ctx, providerID)
		if err != nil {
			return StakePosition{}, fmt.Errorf("stake: provider owner: %w", err)
		}
		if !ok {
			continue
		}
		withdrawable, err := providerWithdrawableUnits(ctx, l.db, providerID)
		if err != nil {
			return StakePosition{}, err
		}
		locked, err := providerOwnerLockedUnits(ctx, l.db, providerID, owner, now)
		if err != nil {
			return StakePosition{}, err
		}
		if free := withdrawable - locked; free > 0 {
			pos.AvailableUnits = saturatingAdd(pos.AvailableUnits, free)
		}
	}
	return pos, nil
}

// stakeEarningRow is one (account, provider, GitHub identity) aggregate of
// the events created before the day start.
type stakeEarningRow struct {
	AccountID    string
	ProviderID   string
	GitHubUserID int64
	MaturedLock  int64 // locks created at or before dayStart - minAge
	Unlocked     int64 // unlocks created before dayStart
}

// computeEarningStakes applies SPEC-050-R004: earning = matured locks minus
// unlocks, floored at zero, only for the provider's current owner, and capped
// so a provider's withdrawable MALIBU is counted once across all accounts.
func computeEarningStakes(rows []stakeEarningRow, withdrawable map[string]int64, owner map[string]int64) []AccountStake {
	type key struct{ account, provider string }
	matured := map[key]int64{}
	unlocked := map[key]int64{}
	seen := map[key]bool{}
	var keys []key
	for _, r := range rows {
		k := key{r.AccountID, r.ProviderID}
		if !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
		unlocked[k] = saturatingAdd(unlocked[k], r.Unlocked)
		if own, ok := owner[r.ProviderID]; ok && own == r.GitHubUserID {
			matured[k] = saturatingAdd(matured[k], r.MaturedLock)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].provider != keys[j].provider {
			return keys[i].provider < keys[j].provider
		}
		return keys[i].account < keys[j].account
	})
	remaining := map[string]int64{}
	for p, w := range withdrawable {
		remaining[p] = w
	}
	perAccount := map[string]int64{}
	githubOf := map[string]int64{}
	for _, k := range keys {
		earning := matured[k] - unlocked[k]
		if earning <= 0 {
			continue
		}
		if room := remaining[k.provider]; earning > room {
			earning = room
		}
		if earning <= 0 {
			continue
		}
		remaining[k.provider] -= earning
		perAccount[k.account] = saturatingAdd(perAccount[k.account], earning)
		githubOf[k.account] = owner[k.provider]
	}
	out := make([]AccountStake, 0, len(perAccount))
	for account, units := range perAccount {
		out = append(out, AccountStake{AccountID: account, GitHubUserID: githubOf[account], Units: units})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AccountID < out[j].AccountID })
	return out
}

// EarningStakes returns every account's earning stake for the UTC day that
// starts at dayStart (SPEC-050-R004). Only events created before dayStart
// count, so a late refresh gives the same answer as an on-time one.
func (l *StakeLedger) EarningStakes(ctx context.Context, dayStart time.Time, minAge time.Duration) ([]AccountStake, error) {
	maturedBy := dayStart.Add(-minAge)
	rows, err := l.db.QueryContext(ctx, `
        SELECT account_id, provider_id, github_user_id,
               `+fmt.Sprintf(clampInt64, `COALESCE(SUM(amount_units) FILTER (WHERE event_type = 'lock' AND created_at <= $2), 0)`)+`,
               `+fmt.Sprintf(clampInt64, `COALESCE(SUM(amount_units) FILTER (WHERE event_type = 'unlock'), 0)`)+`
          FROM malibu_stake_events
         WHERE created_at < $1
         GROUP BY account_id, provider_id, github_user_id
         ORDER BY provider_id, account_id, github_user_id`, dayStart, maturedBy)
	if err != nil {
		return nil, fmt.Errorf("stake: earning events: %w", err)
	}
	var agg []stakeEarningRow
	providers := map[string]bool{}
	for rows.Next() {
		var r stakeEarningRow
		if err := rows.Scan(&r.AccountID, &r.ProviderID, &r.GitHubUserID, &r.MaturedLock, &r.Unlocked); err != nil {
			rows.Close()
			return nil, err
		}
		agg = append(agg, r)
		providers[r.ProviderID] = true
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()
	withdrawable := map[string]int64{}
	owner := map[string]int64{}
	for providerID := range providers {
		w, err := providerWithdrawableUnits(ctx, l.db, providerID)
		if err != nil {
			return nil, err
		}
		withdrawable[providerID] = w
		gh, ok, err := l.owner(ctx, providerID)
		if err != nil {
			return nil, fmt.Errorf("stake: provider owner: %w", err)
		}
		if ok {
			owner[providerID] = gh
		}
	}
	return computeEarningStakes(agg, withdrawable, owner), nil
}
