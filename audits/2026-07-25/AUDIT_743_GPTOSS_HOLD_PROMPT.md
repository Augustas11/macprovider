# AUDIT — #743 interim gpt-oss demand recommendable=false

Review the complete fix for issue #743 interim (NOT the harmony parser).

```bash
git diff origin/main...HEAD
```

Intended: one field flip — `openai/gpt-oss-20b` demand `recommendable: false` in catalog source + baked demand JSON. Candidate `runtime_status` stays recommendable. Signed `dist/static` unchanged (live re-sign is a separate ops step).

Check: paid path cannot select gpt-oss; no accidental catalog corruption; tests pin the hold.

You are the CODE lane for this pass. Also note any SECURITY or ARCHITECT issues you see.

End with:
`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`
