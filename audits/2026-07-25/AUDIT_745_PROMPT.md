# AUDIT — #745 --model overrides model_artifact_path

Full fix: `git diff origin/main...HEAD`

Issue: serve --model set identity but not artifact; autotune benched incumbent.

Fix: ConfigLoader.applyCLI clears model_artifact_path+SHA when CLI --model disagrees with configured artifact. Fresh install path preserved. Same-path keeps SHA.

AC-1..5 in issue. Prefer fail-closed/clear over silent incumbent.

Report findings CRITICAL/HIGH/MEDIUM/LOW/INFO. End with:
`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`
PASS only if 0 C/H/M.
