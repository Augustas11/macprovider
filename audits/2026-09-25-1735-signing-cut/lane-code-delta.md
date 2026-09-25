# Audit (CODE lane, delta): #1735 signing cut follow-up commit

Repository: /Users/augstar/macprovider-1735-sign. Read-only: do NOT edit files. The code lane already passed commit be60fd7b with 0/0/0/0. Review ONLY `git diff be60fd7b..HEAD -- phase3-binary/Tests` (commit 1127ce81).

The new baked catalog release has generated_at 2026-09-25T00:54:00Z. Swift tests pinned fixture dates (fetched feed version/generated_at, test clocks `now`, fixture catalog generated_at, rate-card generated_at) earlier than that, so the baked catalog became newer than the fetched fixture or fixtures read as future-dated; 22 tests failed vs 0 on origin/main. The commit shifts those dates +2 days (09-23->09-25, 09-24->09-26) and one stale-window `now` 10-09->10-11 to keep its original 15-day gap. Check: are any assertions weakened or semantics changed (e.g. a staleness/expiry/freshness boundary now tested on the other side, ordering between dates inverted, a test now vacuous)? Local result: swift test filtered Autotune|ModelsSubcommand|Doctor|ConsumeTrusted 493 tests 0 failures; ServeCommandTests 77 tests 0 failures.

Output findings CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line and failure scenario, then `VERDICT: C=<n> H=<n> M=<n> L=<n>`.
