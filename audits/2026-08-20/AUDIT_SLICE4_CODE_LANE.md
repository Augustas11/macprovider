CODE-REVIEW LANE — SPEC-042 slice 4 (active-policy selection). Read AUDIT_SLICE4_COMMON_CONTEXT.md first.

Focus:
- Are all 6 per-core acceptance checks present, correctly ordered, non-bypassable?
- Half-open window math: overlaps() = a.nb < b.exp && b.nb < a.exp; contains() = nb <= now < exp.
  Any off-by-one? Adjacent windows (b==c) correctly non-overlapping? Boundary belongs to later window?
- Active selection: is "at most one active" actually guaranteed by the overlap rejection? Does
  ActivePolicy scan all and return the right one? pool_policy_stale on before-earliest / gap / after-expiry?
- Chain + monotonic: genesis prev=zeros; strictly increasing version; rollback on <=. First-core seeding.
- Deep-copy: are PrevManifestCoreHash + ModelAllowlist the only mutable slices on PolicyCore? Any other
  slice/map field that still aliases? Is the returned core fully immutable?
- Empty history -> stale; nil authLog handling; error sentinels distinct + errors.Is works.
- Test coverage: do the behavioral vectors pin selection at boundaries/gaps, and do reject tests assert
  the SPECIFIC sentinel per failure mode?

Report Critical/High/Medium/Low with file:line + concrete fix. Bar: 0 C/H/M.
