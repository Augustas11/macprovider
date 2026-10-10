Lane: SECURITY REVIEW, focus MONEY-PATH SAFETY AND AVAILABILITY. Can the rollup
overcount (inflate pool-proven evidence that drives catalog graduation) or leak
identity through the closed frame? Can an attacker-influenced snapshot field
(json values from routing) poison the rollup (type confusion in
json_extract manifest_version, non-hex hashes, empty pool ids)? Does any new read
or write hold the single writer connection long enough to starve the hot path
(6 s INSERT timeout), or hold a read snapshot long enough to block WAL checkpoints?
Does the rollup table add sensitive data at rest beyond what the hot DB already
holds (it keeps request ids/provider ids/account-scope hashes after retention
archives evidence)? Any SQL built by string concatenation from untrusted input?
