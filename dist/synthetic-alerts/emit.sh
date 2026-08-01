#!/bin/sh
# SPEC-016 §9 item 6 synthetic-alert emitter.
#
# Emits ONE synthetic structured-log line per enumerated payout PAGE/WARN event
# name, in the SAME zerolog-JSON shape the coordinator emits real events, so the
# operator can confirm in BetterStack that EACH event name fires its matcher
# BEFORE flipping `payout.enabled: true`.
#
# BetterStack matchers MUST key on the `event` field + the `severity` field, NOT
# the zerolog `level`. Some real events emit a PAGE severity at a non-error level
# (e.g. payout_reorg_orphan_recorded logs at warn level with severity=PAGE), so
# the `severity` field printed here is authoritative and always matches the
# catalog; the `level` field is cosmetic (derived from severity for realism).
#
# For a page_capable event (dynamic severity, e.g. payout_stale_outbox_backlog
# escalating WARN->PAGE), BOTH a WARN and a PAGE synthetic line are emitted so
# the operator verifies BOTH matchers.
#
# The DEFAULT set is the events the coordinator ACTUALLY emits — the true
# pre-enablement verification list. `spec-only-not-emitted` events (enumerated by
# the spec but never emitted by the code) are EXCLUDED from the default: emitting
# a synthetic line for them would let an operator "verify" a matcher for an event
# that can never fire (false readiness). They are available only via --reserved,
# marked `"reserved":true,"not_yet_emitted":true`, and are an implementation gap
# to close (wire the emission) before they count toward enablement.
#
# Every emitted line carries `"synthetic":true` and a `"note"` so these can
# NEVER be mistaken for a real incident. Source of truth is catalog.tsv (shared
# with the coordinator completeness test); this script hard-codes NO event list.
#
# Usage:
#   ./emit.sh                 Emit one synthetic line per EMITTED PAGE/WARN event (default)
#   ./emit.sh --include-info  Also emit the INFO-class events (§9 item 6 optional)
#   ./emit.sh --reserved      Emit ONLY the spec-only-not-emitted events (marked reserved)
#   ./emit.sh --event NAME    Emit just the one event NAME
#   ./emit.sh --list          Print the catalog (name severity status page_capable)
#   ./emit.sh --help          Show this help
#
# Output goes to stdout. On the coordinator host, pipe into the same journald
# stream the coordinator uses, e.g.:  ./emit.sh | systemd-cat -t macprovider-coordinator
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CATALOG="$SCRIPT_DIR/catalog.tsv"
SPEC_REF="SPEC-016 §9 item 6 synthetic-alert verification"
NOTE="SYNTHETIC verification emission - NOT a real incident - see dist/synthetic-alerts/README.md"
RESERVED_NOTE="RESERVED event - the coordinator does NOT emit this yet - NOT part of pre-enablement verification; wire the emission before relying on its matcher. SYNTHETIC."

if [ ! -f "$CATALOG" ]; then
	echo "emit.sh: catalog not found: $CATALOG" >&2
	exit 1
fi

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

INCLUDE_INFO=0
ONE_EVENT=""
MODE=emit

while [ $# -gt 0 ]; do
	case "$1" in
		--list) MODE=list ;;
		--reserved) MODE=reserved ;;
		--include-info) INCLUDE_INFO=1 ;;
		--event) shift; [ $# -gt 0 ] || { echo "emit.sh: --event needs a NAME" >&2; exit 2; }; ONE_EVENT="$1" ;;
		--help|-h) usage; exit 0 ;;
		*) echo "emit.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

# level_for SEVERITY -> zerolog level string. Cosmetic only; matchers key on the
# `severity` field, not `level`.
level_for() {
	case "$1" in
		PAGE) echo error ;;
		WARN) echo warn ;;
		*)    echo info ;;
	esac
}

# Stream the catalog data rows (comments/blank lines dropped).
rows() {
	grep -v '^[[:space:]]*#' "$CATALOG" | grep -v '^[[:space:]]*$'
}

now_utc() {
	# RFC3339 with nanoseconds where the platform supports it; falls back cleanly.
	date -u +%Y-%m-%dT%H:%M:%S.%N%z 2>/dev/null | sed 's/\([0-9][0-9]\)$/:\1/' \
		|| date -u +%Y-%m-%dT%H:%M:%SZ
}

# emit_one NAME SEVERITY STATUS -> one JSON line with an authoritative severity.
# A `spec-only-not-emitted` event is marked reserved/not_yet_emitted so an
# operator can never mistake it for a real, verifiable pre-enablement alert.
emit_one() {
	_name=$1; _severity=$2; _status=$3
	_level=$(level_for "$_severity")
	_ts=$(now_utc)
	if [ "$_status" = "spec-only-not-emitted" ]; then
		printf '{"level":"%s","event":"%s","severity":"%s","synthetic":true,"reserved":true,"not_yet_emitted":true,"catalog_status":"%s","spec_ref":"%s","note":"%s","ts_utc":"%s","time":"%s"}\n' \
			"$_level" "$_name" "$_severity" "$_status" "$SPEC_REF" "$RESERVED_NOTE" "$_ts" "$_ts"
	else
		printf '{"level":"%s","event":"%s","severity":"%s","synthetic":true,"catalog_status":"%s","spec_ref":"%s","note":"%s","ts_utc":"%s","time":"%s"}\n' \
			"$_level" "$_name" "$_severity" "$_status" "$SPEC_REF" "$NOTE" "$_ts" "$_ts"
	fi
}

# emit_row NAME SEVERITY STATUS PAGE_CAPABLE -> emit the floor line, plus a PAGE
# escalation line when the event is page_capable (and the floor is not PAGE).
emit_row() {
	_n=$1; _s=$2; _st=$3; _pc=$4
	emit_one "$_n" "$_s" "$_st"
	if [ "$_pc" = "page_capable" ] && [ "$_s" != "PAGE" ]; then
		emit_one "$_n" "PAGE" "$_st"
	fi
}

if [ "$MODE" = list ]; then
	printf '%-52s %-8s %-22s %s\n' "EVENT" "SEVERITY" "STATUS" "PAGE_CAPABLE"
	rows | while IFS='	' read -r name severity status page; do
		printf '%-52s %-8s %-22s %s\n' "$name" "$severity" "$status" "$page"
	done
	exit 0
fi

if [ "$MODE" = reserved ]; then
	# ONLY the spec-only-not-emitted events, clearly marked reserved. These are
	# an IMPLEMENTATION gap: the code never emits them, so they are NOT part of
	# the pre-enablement per-event verification set.
	rows | while IFS='	' read -r name severity status page; do
		[ "$status" = "spec-only-not-emitted" ] && emit_row "$name" "$severity" "$status" "$page" || :
	done
	exit 0
fi

if [ -n "$ONE_EVENT" ]; then
	found=0
	while IFS='	' read -r name severity status page; do
		[ "$name" = "$ONE_EVENT" ] || continue
		emit_row "$name" "$severity" "$status" "$page"
		found=1
		break
	done <<EOF
$(rows)
EOF
	if [ "$found" -eq 0 ]; then
		echo "emit.sh: no such event in catalog: $ONE_EVENT" >&2
		exit 3
	fi
	exit 0
fi

# Default: synthetic line(s) per PAGE/WARN event that the code actually emits.
# spec-only-not-emitted events are EXCLUDED (they can never fire — see --reserved);
# INFO events only with --include-info.
rows | while IFS='	' read -r name severity status page; do
	[ "$status" = "spec-only-not-emitted" ] && continue
	case "$severity" in
		PAGE|WARN) emit_row "$name" "$severity" "$status" "$page" ;;
		INFO) [ "$INCLUDE_INFO" -eq 1 ] && emit_row "$name" "$severity" "$status" "$page" || : ;;
	esac
done
