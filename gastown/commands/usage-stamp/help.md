Attribute a session's model spend to the bead it was spent on.

Gas City already meters token usage, but it meters it per SESSION: every
`kind:"model"` row in `<city>/.gc/usage.jsonl` carries model, input_tokens,
output_tokens, cache_read_tokens and cache_creation_tokens keyed by
`session_id`/`worker` and by nothing else. Beads separately record which
session claimed them (`metadata.gc.session_id`). This command performs the
join, so per-bead and per-PRD spend stop reading empty.

Usage:
  gc gastown usage-stamp <bead-id>
  gc gastown usage-stamp <bead-id> --dry-run
  gc gastown usage-stamp <bead-id> --session gk-3q5 --session-name gastown__polecat-gk-3q5

Session identity is taken from GC_SESSION_ID/GC_SESSION_NAME when present,
and otherwise read off the bead's own `gc.session_id`. That fallback is what
lets a later caller — a refinery bridge at close, or a backfill sweep — stamp
a bead it did not itself work.

Stamps under the `usage.` metadata prefix:

  usage.status                 metered | unmetered
  usage.session_id             the session the spend was joined from
  usage.model                  dominant model (most output tokens)
  usage.provider               provider for the dominant model
  usage.input_tokens           summed across every matched row
  usage.output_tokens
  usage.cache_read_tokens
  usage.cache_creation_tokens
  usage.models                 per-model breakdown, only when >1 contributed
  usage.unmetered_reason       why nothing was measured, only when unmetered

UNMETERED IS NOT ZERO. When no rows match, this writes `usage.status=unmetered`
plus a reason and NO token fields, because a bead reporting 0 in / 0 out is
indistinguishable from work that was genuinely free. A session really can have
no local rows — `GC_DISABLE_USAGE_METRICS=1`, or a city whose usage provider is
`exec:` or `discard`, both produce real spend with nothing in the local sink.

Exit codes:
  0  spend measured (and stamped unless --dry-run)
  1  unmetered — nothing to measure; the reason was recorded
  2  the join could not run (no pack context, no jq, unreadable sink)

Callers that must not fail on an unmetered session should append `|| true`.
Metering is an observation, never a gate on work changing hands.

Environment variables set by gc:
  GC_CITY_PATH   Absolute path to the city root
  GC_PACK_DIR    Absolute path to this pack's directory
  GC_PACK_NAME   Pack name ("gastown")
  GC_CITY_NAME   City workspace name
